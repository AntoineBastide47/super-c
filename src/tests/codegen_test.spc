// Self-hosted port of tests/codegen_test.c: structural codegen coverage (emitted-C substring assertions)
// driven in-process through tests::harness (compile_c).
import tests::harness as h;

const BROAD: str = "struct Point { pub x: i32, }\nextend Point { fn get(self: &Point) i32 { return self.x; } }\nfn add(a: i32, b: i32) i32 { return a + b; }\nfn main() i32 {\n  let p: Point = Point { x: 1, };\n  let y: i32 = p.get();\n  let z: i32 = add(1, 2);\n  if (true) { let w: i32 = 0; }\n  while (false) { }\n  let q: *i32 = new i32;\n}\n";

const CONTROL: str = "fn classify(c: u8) i32 { return switch c { 0 => 1, n => 2, _ => 0, }; }\nfn sum(xs: [i32; 3]) i32 {\n  let mut total: i32 = 0;\n  for x in xs { total = total + x; }\n  return total;\n}\n";

const RANGES: str = "fn f() i32 {\n  let mut s: i32 = 0;\n  for i in 0..10 { s = s + i; }\n  for i in 1..=5 { s = s + i; }\n  for i in ..4 { s = s + 1; }\n  for i in 100.. { if i >= 103 { break; } s = s + i; }\n  while s < 0 { s = s + 1; }\n  return s;\n}\n";

const SWITCH_RANGES: str = "fn classify(n: i32) i32 {\n  return switch n {\n    10..20 => 1,\n    20..=30 => 2,\n    ..5 => 3,\n    99.. => 4,\n    _ => 0,\n  };\n}\n";

const REFS: str = "struct P { pub x: i32, }\nfn reads(r: &P) i32 { return r.x; }\nfn writes(w: &mut P) void { w.x = 1; }\nfn raw_c(pc: *const i32) i32 { return unsafe *pc; }\nfn raw_m(pm: *mut i32) void { unsafe *pm = 1; }\n";

const EXTERN: str = "extern \"C\" {\n  fn putchar(c: i32) i32;\n}\nfn main() i32 { let r: i32 = unsafe putchar(72); }\n";

const STR: str = "fn f(s: str) usize { return s.len(); }\nfn main() i32 { let g: str = \"hi\"; return 0; }\n";

const CONSTNESS: str = "fn f(a: i32) i32 {\n  let x: i32 = a;\n  let mut y: i32 = a;\n  y = y + 1;\n  return x + y;\n}\n";

const BIND_CONST: str = "struct Buf { pub ptr: *mut u8, }\nfn main() i32 { let b: Buf = Buf { ptr: null, }; let mut m: Buf = Buf { ptr: null, };\n  let x: i32 = 5; let mut y: i32 = 6; return x; }\n";

@test
fn broad() {
    h::expect_c("function", BROAD, "int32_t add(");
    h::expect_c("struct decl", BROAD, "struct Point");
    h::expect_c("struct field", BROAD, "int32_t x;");
    h::expect_c("method proto", BROAD, "Point__get(");
    h::expect_c("method call self", BROAD, "Point__get(&p)");
    h::expect_c("associated new call", "struct String {}\nextend String { fn new() String { return String {}; } }\nfn f() String { return String::new(); }\n", "String__new()");
    h::expect_c("struct initializer", BROAD, "(Point){ .x = 1");
    h::expect_c("if statement", BROAD, "if (");
    h::expect_c("while statement", BROAD, "while (");
    h::expect_c("new", BROAD, "(int32_t*)malloc(sizeof(");
}

@test
fn control() {
    h::expect_c("for loop", CONTROL, "for (");
    h::expect_c("switch lowered to if", CONTROL, "if (");
    h::expect_c("switch literal test", CONTROL, " == ");
}

@test
fn ranges() {
    h::expect_c("exclusive range", RANGES, "for (int32_t i = 0; i < 10; i++)");
    h::expect_c("inclusive range", RANGES, "for (int32_t i = 1; i <= 5; i++)");
    h::expect_c("open-start range", RANGES, "for (int32_t i = 0; i < 4; i++)");
    h::expect_c("open-end range", RANGES, "for (int32_t i = 100; ; i++)");
    h::expect_c("usize end range", "fn f(n: usize) void { for i in 0..n { } }\n", "for (size_t i = 0ULL; i < n; i++)");
    h::expect_c("bare if lowers", RANGES, "if (i >= 103)");
    h::expect_c("bare while lowers", RANGES, "while (s < 0)");
}

@test
fn switch_ranges() {
    h::expect_c("exclusive arm lower bound", SWITCH_RANGES, ">= 10 && ");
    h::expect_c("exclusive arm upper bound", SWITCH_RANGES, "< 20");
    h::expect_c("inclusive arm upper bound", SWITCH_RANGES, "<= 30");
    h::expect_c("open-start arm is upper-only", SWITCH_RANGES, "< 5");
    h::expect_c_absent("open-start arm has no lower bound", SWITCH_RANGES, ">= 5");
    h::expect_c("open-end arm is lower-only", SWITCH_RANGES, ">= 99");
    h::expect_c_absent("open-end arm has no upper bound", SWITCH_RANGES, "< 99");
}

@test
fn pointer_arith() {
    h::expect_c("pointer offset", "fn f(p: *i32) i32 { return unsafe *(p + 1); }\n", "(p + 1)");
    h::expect_c("pointer difference", "fn f(a: *i32, b: *i32) isize { return unsafe (a - b); }\n", "(a - b)");
}

@test
fn references() {
    h::expect_c("&T is const pointee", REFS, "const P *const r");
    h::expect_c("&mut T is mutable pointee", REFS, "P *const w");
    h::expect_c_absent("&mut T is not const", REFS, "const P *const w");
    h::expect_c("*const T is const pointee", REFS, "const int32_t *const pc");
    h::expect_c("*mut T is mutable pointee", REFS, "int32_t *const pm");
    h::expect_c_absent("*mut T is not const", REFS, "const int32_t *const pm");
}

@test
fn externs() {
    h::expect_c_absent("extern prototype suppressed", EXTERN, "(putchar)(");
    h::expect_c("extern call site", EXTERN, "putchar(72)");

    h::expect_c("extern system header include", "extern \"C\" \"pthread.h\" { type pthread_t; fn pthread_self() pthread_t; }\nfn main() i32 { let t: pthread_t = unsafe pthread_self(); return 0; }\n", "#include <pthread.h>");
    h::expect_c("extern local header include", "extern \"C\" \"./lib.h\" { fn answer() i32; }\nfn main() i32 { return unsafe answer(); }\n", "#include \"./lib.h\"");

    h::expect_c("variadic call passes all args", "extern \"C\" { fn printf(fmt: *const char, ...) i32; }\nfn main() i32 { let f: char = '%'; unsafe printf(&f, 1, 2, 3); return 0; }\n", "1, 2, 3)");

    h::expect_c("string literal -> bare C string in fmt + vararg", "extern \"C\" { fn printf(fmt: *const char, ...) i32; }\nfn main() i32 { unsafe printf(\"%s\\n\", \"hi\"); return 0; }\n", "printf(\"%s\\n\", \"hi\")");
    h::expect_c("string literal -> *const u8 adds cast", "extern \"C\" { fn f(s: *const u8) i32; }\nfn main() i32 { return unsafe f(\"hi\"); }\n", "(const uint8_t *)\"hi\"");
    h::expect_c("string literal stays str view by default", "fn main() i32 { let s: str = \"zq9\"; return 0; }\n", "(str){ (const uint8_t *)\"zq9\"");

    h::expect_c("complex builtin renders to _Complex", "fn main() i32 { let z: c64 = 3.0; let w: c32 = 1.0; return 0; }\n", "double _Complex");
    h::expect_c("c32 renders to float _Complex", "fn main() i32 { let w: c32 = 1.0; return 0; }\n", "float _Complex");
    // NOTE(omitted): "__sc_atomic_fence" lives in the super_rt runtime header, not per-module codegen output.
}

@test
fn str() {
    h::expect_c("str forward typedef", STR, "typedef struct str str;");
    h::expect_c("str struct body", STR, "struct str {\n  const uint8_t *ptr;\n  size_t len;\n};");
    h::expect_c("str param", STR, "size_t f(str const s)");
    h::expect_c("str len() emits method call", STR, "str__len(&s)");
    h::expect_c("str literal", STR, "(str){ (const uint8_t *)\"hi\", sizeof(\"hi\") - 1 }");
}

@test
fn constness() {
    h::expect_c("immutable param is const", CONSTNESS, "int32_t const a");
    h::expect_c("immutable let is const", CONSTNESS, "int32_t const x = a;");
    h::expect_c_absent("mutable let is not const", CONSTNESS, "int32_t const y");
    h::expect_c("mutable let stays plain", CONSTNESS, "int32_t y = a;");
}

@test
fn binding_constness() {
    h::expect_c("immutable let of owning type is const", BIND_CONST, "Buf const b =");
    h::expect_c_absent("mut let of owning type is non-const", BIND_CONST, "Buf const m");
    h::expect_c("scalar immutable let is const", BIND_CONST, "int32_t const x = 5");
    h::expect_c_absent("scalar mut let is non-const", BIND_CONST, "int32_t const y");
}

@test
fn alias_extend() {
    let A: str = "pub type Token = u64;\nextend Token {\n  pub fn new(v: u32) Token { return v as u64; }\n  pub fn start(self: Self) u32 { return self as u32; }\n  pub fn next(self: Self) Token { return Token::new(self.start() + 1); }\n}\nfn main() i32 { let t = Token::new(3); let u = t.next(); return u.start() as i32; }\n";
    h::expect_c("value alias emits a named typedef", A, "typedef uint64_t Token;");
    h::expect_c("alias method mangles by the alias name", A, "Token Token__new(");
    h::expect_c("Self return spells the alias", A, "uint32_t Token__start(Token const self)");
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
    h::expect_c("plain enum arm tests the tag", MATCH, "== C_Red");
    h::expect_c_absent("plain enum arm is not a binding", MATCH, "C Red =");
    h::expect_c("exhaustive match is closed", MATCH, "__builtin_unreachable");

    h::expect_c("explicit discriminant", "enum Code { Ok = 0, Bad = 404, }\nfn f(c: Code) i32 { return c as i32; }\n", "Code_Bad = 404");
}

@test
fn if_expression() {
    let SRC: str = "fn f(n: i32) i32 { let x: i32 = if n > 0 { 1; } else { 2; }; return x; }\n";
    h::expect_c("if-expr is a statement-expression", SRC, "({");
    h::expect_c("if-expr arm assigns the result temp", SRC, " = 1;");
    h::expect_c("if-expr lowers the chain", SRC, "else {");
}

@test
fn array_literals() {
    h::expect_c("array literal let is a brace list", "fn f() void { let a: [i32; 3] = [1, 2, 3]; }\n", "= { 1, 2, 3 }");
    h::expect_c_absent("array literal let is not a compound literal", "fn f() void { let a: [i32; 3] = [1, 2, 3]; }\n", "(int32_t[3]){ 1, 2, 3 }");
    h::expect_c("array literal argument is a compound literal", "extern \"C\" { fn putchar(c: i32) i32; }\nfn g(a: [i32; 3]) i32 { unsafe putchar(0); return a[0]; }\nfn f() i32 { return g([1, 2, 3]); }\n", "(int32_t[3]){ 1, 2, 3 }");
}

@test
fn multi_return() {
    let MR: str = "fn dm(a: i32, b: i32) (i32, i32) { return a + b, a - b; }\n";
    h::expect_c("multi-return struct typedef", MR, "dm_ret");
    h::expect_c("multi-return field", MR, "int32_t _0;");
    h::expect_c("multi-return compound literal", MR, "(dm_ret){");

    let DESTR: str = "fn dm(a: i32, b: i32) (i32, i32) { return a + b, a - b; }\nfn f() i32 { let (x, y) = dm(3, 1); return x + y; }\n";
    h::expect_c("destructure temp", DESTR, "const __auto_type");
    h::expect_c("destructure field 0", DESTR, "x = ");
    h::expect_c("destructure reads _0", DESTR, "._0;");
    h::expect_c("destructure reads _1", DESTR, "._1;");
}

@test
fn slices_and_arrays() {
    h::expect_c("slice param is Slice__T", "fn first(s: []i32) i32 { return s[0]; }\n", "Slice__i32 const s");
    h::expect_c("mut slice param is SliceMut__T", "fn set0(s: []mut i32) { s[0] = 1; }\n", "SliceMut__i32 const s");
    h::expect_c("slice index uses typed ptr, bounds-checked", "fn first(s: []i32) i32 { return s[0]; }\n", "s.ptr[__sc_bounds(0, s.len)]");
    h::expect_c("array param keeps extent", "fn g(a: [i32; 3]) i32 { return a[0]; }\n", "int32_t const a[3]");
    h::expect_c("array arg coerces to slice view", "fn take(s: []i32) i32 { return s[0]; }\nfn m() i32 { let a: [i32; 2] = [4, 5]; return take(a); }\n", "(Slice__i32){ .ptr = a, .len = 2 }");
}

@test
fn errors() {
    h::expect_c("defer lowers to scope-exit call", "fn cleanup() void {}\nfn run() void { defer cleanup(); }\n", "cleanup()");
    h::expect_c("designated array init", "fn m() i32 { let t: [i32; 4] = [[2] = 9]; return t[2]; }\n", "[2] = 9");
    h::expect_c("local const is static const", "fn m() i32 { const T: [i32; 2] = [1, 2]; return T[0]; }\n", "static const");
    h::expect_c("static_assert lowers", "static_assert(1 == 1);\nfn m() i32 { return 0; }\n", "_Static_assert(");
    h::expect_c("do/while form", "fn m() i32 { let mut i: i32 = 0; do { i = i + 1; } while i < 3; return i; }\n", "do {");
}

@test
fn attributes() {
    h::expect_c("noreturn", "@c.noreturn\nfn die() void {}\nfn main() i32 { return 0; }\n", "_Noreturn");
    h::expect_c("always_inline", "@c.always_inline\nfn a(x: i32) i32 { return x; }\nfn main() i32 { return a(0); }\n", "inline __attribute__((always_inline, unused))");
    h::expect_c("section + used", "@c.section(\"hot\")\n@c.used\nfn a() i32 { return 0; }\nfn main() i32 { return a(); }\n", "__attribute__((used, section(\"hot\")))");
    h::expect_c("packed struct", "@c.packed\nstruct H { pub x: u32 }\nfn main() i32 { let h = H { x: 1 }; return h.x as i32; }\n", "struct __attribute__((packed)) H");
    h::expect_c("aligned struct", "@c.align(64)\nstruct L { pub x: i64 }\nfn main() i32 { let l = L { x: 0 }; return l.x as i32; }\n", "__attribute__((aligned(64)))");

    let EX: str = "extern \"C\" { fn putchar(c: i32) i32; }\n@c.export(\"sc_init\")\nfn init() i32 { unsafe putchar(0); return 0; }\nfn main() i32 { return init(); }\n";
    h::expect_c("export defines the exact symbol", EX, "int32_t sc_init(void)");
    h::expect_c("export rewrites the call site", EX, "return sc_init()");
    h::expect_c_absent("export elides the Super-C name", EX, " init(");

    h::expect_c("import binds to the C symbol", "extern \"C\" { @c.import(\"puts\") fn line(s: *const char) i32; }\nfn main() i32 { unsafe line(\"x\"); return 0; }\n", "puts(");
}

@test
fn generics() {
    let ID: str = "fn id<T>(x: T) T { return x; }\nfn main() i32 { let a: i32 = id::<i32>(5); let b: bool = id::<bool>(true); return a; }\n";
    h::expect_c("generic specialization with substituted return", ID, "int32_t id__i32(");
    h::expect_c("second instantiation", ID, "id__bool(");
    h::expect_c_absent("no generic template emitted", ID, " id(");

    let ENUM: str = "enum Opt<T> { Some(T), None }\nfn main() i32 { let a: Opt<i32> = Opt::<i32>::Some(1); let b: Opt<bool> = Opt::<bool>::None;\n  return switch a { Some(v) => v, None => 0, } + switch b { Some(_) => 1, None => 0, }; }\n";
    h::expect_c("generic enum tag is include-guarded", ENUM, "SUPER_ENUMTAG_Opt");
    h::expect_c("generic enum tag emitted once", ENUM, "} OptTag;");
}

@test
fn literals() {
    h::expect_c("binary literal", "fn f() i32 { let a: i32 = 0b101; return a; }\n", "= 5;");
    h::expect_c("digit separators", "fn f() i32 { let a: i32 = 1_000; return a; }\n", "= 1000;");
    h::expect_c("keyword identifier", "fn f() i32 { let register: i32 = 1; return register; }\n", "register_");
}

@test
fn const_generics() {
    let CG: str = "struct Buff<T, const N: usize> { pub b: [T; N] }\nextend<T, const N: usize> Buff<T, N> { fn cap(self: &Self) usize { return N; } }\nfn main() i32 { let a = Buff::<i32, 4> { b: [1, 2, 3, 4] }; let c = Buff::<u8, 2> { b: [1u8, 2u8] }; return a.b[0] + c.b[1] as i32 + a.cap() as i32; }\n";
    // Distinct (type-arg, const-arg) tuples monomorphize to distinct C types...
    h::expect_c("const-generic instance name (i32, 4)", CG, "Buff__i32__4");
    h::expect_c("const-generic instance name (u8, 2)", CG, "Buff__u8__2");
    // ...whose array field is sized by the const value (not the identifier `N`)...
    h::expect_c("const-generic array field sized (i32)", CG, "int32_t b[4]");
    h::expect_c("const-generic array field sized (u8)", CG, "uint8_t b[2]");
    h::expect_c_absent("const param does not leak as `N` into C", CG, "b[N]");
    // ...and the const param folds to its value in expression position.
    h::expect_c("const param value in method body (4)", CG, "return 4;");
    h::expect_c("const param value in method body (2)", CG, "return 2;");
}

@test
fn callback_specialization() {
    let KNOWN: str = "extern \"C\" { fn putchar(c: i32) i32; }\nfn apply(x: i32, f: fn(i32) i32) i32 { return f(x); }\nfn inc(x: i32) i32 { unsafe putchar(0); return x + 1; }\nfn use() i32 { return apply(10, inc); }\n";
    h::expect_c("callback specialization emitted", KNOWN, "apply__cb_inc(");
    h::expect_c("callback call site elides the callback arg", KNOWN, "apply__cb_inc(10)");
    h::expect_c_absent("private specialized-away original elided", KNOWN, "int32_t apply(int32_t const x, int32_t (*const f)(int32_t))");

    let RUNTIME: str = "fn apply(x: i32, f: fn(i32) i32) i32 { return f(x); }\nfn inc(x: i32) i32 { return x + 1; }\nfn use() i32 { let k: fn(i32) i32 = inc; return apply(10, k); }\n";
    h::expect_c("runtime callback keeps the pointer original", RUNTIME, "int32_t apply(int32_t const x, int32_t (*const f)(int32_t))");
    h::expect_c_absent("runtime callback is not specialized", RUNTIME, "__cb_");
}
