// Structural codegen coverage: asserts the *shape* of the emitted C for things not observable at
// runtime, or not constructible in surface syntax (const placement, name mangling, extern
// prototypes, literal rewriting, tagged-union/multi-return/slice lowering, "not yet supported"
// diagnostics). Behavioral correctness of runnable programs lives in codegen_run_test.c.

#include "test_harness.h"

static void expect_contains(const char *name, const char *source, const char *needle) {
  size_t n_err = 0;
  char first[256];
  char *code = sc_codegen(name, source, &n_err, first, sizeof first);
  if (!code)
    return;
  CHECK(n_err == 0, "%s: unexpected codegen error: %s", name, first);
  CHECK(strstr(code, needle) != NULL, "%s: emitted C missing '%s':\n%s", name, needle, code);
  free(code);
}

static void expect_absent(const char *name, const char *source, const char *needle) {
  size_t n_err = 0;
  char first[256];
  char *code = sc_codegen(name, source, &n_err, first, sizeof first);
  if (!code)
    return;
  CHECK(n_err == 0, "%s: unexpected codegen error: %s", name, first);
  CHECK(strstr(code, needle) == NULL, "%s: emitted C should not contain '%s':\n%s", name, needle, code);
  free(code);
}

static void expect_codegen_error(const char *name, const char *source, const char *needle) {
  size_t n_err = 0;
  char first[256];
  char *code = sc_codegen(name, source, &n_err, first, sizeof first);
  if (!code)
    return;
  CHECK(n_err >= 1, "%s: expected a codegen diagnostic", name);
  if (n_err)
    CHECK(strstr(first, needle) != NULL, "%s: diagnostic missing '%s':\n%s", name, needle, first);
  free(code);
}

static const char *const BROAD =
    "struct Point { pub x: i32, }\n"
    "extend Point { fn get(self: &Point) i32 { return self.x; } }\n"
    "fn add(a: i32, b: i32) i32 { return a + b; }\n"
    "fn main() i32 {\n"
    "  let p: Point = Point { x: 1, };\n"
    "  let y: i32 = p.get();\n"
    "  let z: i32 = add(1, 2);\n"
    "  if (true) { let w: i32 = 0; }\n"
    "  while (false) { }\n"
    "  let q: *i32 = new i32;\n"
    "}\n";

static void test_broad(void) {
  expect_contains("function", BROAD, "int32_t add(");
  expect_contains("struct decl", BROAD, "struct Point");
  expect_contains("struct field", BROAD, "int32_t x;");
  expect_contains("method proto", BROAD, "Point__get(");
  expect_contains("method call self", BROAD, "Point__get(&p)");
  expect_contains(
      "associated new call", "struct String {}\nextend String { fn new() String { return String {}; } }\nfn f() String { return String::new(); }\n",
      "String__new()");
  expect_contains("struct initializer", BROAD, "(Point){ .x = 1");
  expect_contains("if statement", BROAD, "if (");
  expect_contains("while statement", BROAD, "while (");
  expect_contains("new", BROAD, "(int32_t*)malloc(sizeof(");
}

static const char *const CONTROL =
    "fn classify(c: u8) i32 { return switch c { 0 => 1, n => 2, _ => 0, }; }\n"
    "fn sum(xs: [i32; 3]) i32 {\n"
    "  let mut total: i32 = 0;\n"
    "  for x in xs { total = total + x; }\n"
    "  return total;\n"
    "}\n";

static void test_control(void) {
  expect_contains("for loop", CONTROL, "for (");
  expect_contains("switch lowered to if", CONTROL, "if (");
  expect_contains("switch literal test", CONTROL, " == ");
}

// Bare `if`/`while` (no parens) plus the four for-range forms lowered to counting loops.
static const char *const RANGES =
    "fn f() i32 {\n"
    "  let mut s: i32 = 0;\n"
    "  for i in 0..10 { s = s + i; }\n"
    "  for i in 1..=5 { s = s + i; }\n"
    "  for i in ..4 { s = s + 1; }\n"
    "  for i in 100.. { if i >= 103 { break; } s = s + i; }\n"
    "  while s < 0 { s = s + 1; }\n"
    "  return s;\n"
    "}\n";

static void test_ranges(void) {
  expect_contains("exclusive range", RANGES, "for (int32_t i = 0; i < 10; i++)");
  expect_contains("inclusive range", RANGES, "for (int32_t i = 1; i <= 5; i++)");
  expect_contains("open-start range", RANGES, "for (int32_t i = 0; i < 4; i++)");
  expect_contains("open-end range", RANGES, "for (int32_t i = 100; ; i++)");
  expect_contains("usize end range", "fn f(n: usize) void { for i in 0..n { } }\n", "for (size_t i = 0; i < n; i++)");
  expect_contains("bare if lowers", RANGES, "if (i >= 103)");
  expect_contains("bare while lowers", RANGES, "while (s < 0)");
}

// switch arms reuse the for-loop range grammar; half-open arms lower to a single comparison.
static const char *const SWITCH_RANGES =
    "fn classify(n: i32) i32 {\n"
    "  return switch n {\n"
    "    10..20 => 1,\n"
    "    20..=30 => 2,\n"
    "    ..5 => 3,\n"
    "    99.. => 4,\n"
    "    _ => 0,\n"
    "  };\n"
    "}\n";

static void test_switch_ranges(void) {
  expect_contains("exclusive arm lower bound", SWITCH_RANGES, ">= 10 && ");
  expect_contains("exclusive arm upper bound", SWITCH_RANGES, "< 20");
  expect_contains("inclusive arm upper bound", SWITCH_RANGES, "<= 30");
  expect_contains("open-start arm is upper-only", SWITCH_RANGES, "< 5");
  expect_absent("open-start arm has no lower bound", SWITCH_RANGES, ">= 5");
  expect_contains("open-end arm is lower-only", SWITCH_RANGES, ">= 99");
  expect_absent("open-end arm has no upper bound", SWITCH_RANGES, "< 99");
}

static void test_pointer_arith(void) {
  expect_contains("pointer offset", "fn f(p: *i32) i32 { return *(p + 1); }\n", "(p + 1)");
  expect_contains("pointer difference", "fn f(a: *i32, b: *i32) isize { return a - b; }\n", "(a - b)");
}

// Reference/pointer C lowering: `&T`->`const T *`, `&mut T`->`T *`; raw `*const T`->`const T *`,
// `*mut T`->`T *`. Distinct parameter names let the assertions pin const-pointee vs mutable.
static const char *const REFS =
    "struct P { pub x: i32, }\n"
    "fn reads(r: &P) i32 { return r.x; }\n"
    "fn writes(w: &mut P) void { w.x = 1; }\n"
    "fn raw_c(pc: *const i32) i32 { return *pc; }\n"
    "fn raw_m(pm: *mut i32) void { *pm = 1; }\n";

static void test_references(void) {
  expect_contains("&T is const pointee", REFS, "const P *const r");
  expect_contains("&mut T is mutable pointee", REFS, "P *const w");
  expect_absent("&mut T is not const", REFS, "const P *const w");
  expect_contains("*const T is const pointee", REFS, "const int32_t *const pc");
  expect_contains("*mut T is mutable pointee", REFS, "int32_t *const pm");
  expect_absent("*mut T is not const", REFS, "const int32_t *const pm");
}

static const char *const EXTERN =
    "extern \"C\" {\n"
    "  fn putchar(c: i32) i32;\n"
    "}\n"
    "fn main() i32 { let r: i32 = putchar(72); }\n";

static void test_extern(void) {
  // The name is parenthesized so a fortified libc macro (macOS memcpy/etc.) cannot expand at the
  // declaration; the call site keeps the bare name so it still expands to the fortified builtin.
  expect_contains("extern prototype", EXTERN, "extern int32_t (putchar)(const int32_t c);");
  expect_contains("extern call site", EXTERN, "putchar(72)");
}

static const char *const STR = "fn f(s: str) usize { return s.len; }\nfn main() i32 { let g: str = \"hi\"; return 0; }\n";

static void test_str(void) {
  expect_contains("str typedef", STR, "typedef struct { const uint8_t *ptr; size_t len; } str;");
  expect_contains("str param", STR, "size_t f(const str s)");
  expect_contains("str member access", STR, "s.len");
  // a string literal lowers to a `str` compound literal carrying the byte pointer and `sizeof - 1` length
  expect_contains("str literal", STR, "(str){ (const uint8_t *)\"hi\", sizeof(\"hi\") - 1 }");
}

static const char *const CONSTNESS =
    "fn f(a: i32) i32 {\n"
    "  let x: i32 = a;\n"
    "  let mut y: i32 = a;\n"
    "  y = y + 1;\n"
    "  return x + y;\n"
    "}\n";

// A `let` of a value that owns a `*mut` (here `Buf.ptr`) drops `const`; a scalar `let` keeps it.
static const char *const OWNS_MUT =
    "struct Buf { pub ptr: *mut u8, }\n"
    "fn main() i32 { let b: Buf = Buf { ptr: null, }; let x: i32 = 5; return x; }\n";

static void test_owning_mut_constness(void) {
  expect_contains("owning-mut let is non-const", OWNS_MUT, "Buf b =");
  expect_absent("owning-mut let is not const", OWNS_MUT, "const Buf b");
  expect_contains("scalar let still const", OWNS_MUT, "const int32_t x = 5");
}

// One corpus of struct shapes; each `let aN: T;` (annotated, no initializer) lets us assert the
// const-ness of T's binding purely from its type. A `*mut` reachable through value fields / array
// elements makes the binding non-const; a `*const`/`*mut`-to-an-owner stops at the pointer.
static const char *const OWNS_MUT_ZOO =
    "struct Scalars { a: i32, b: i64, }\n"
    "struct HasMut { p: *mut u8, }\n"
    "struct HasConstPtr { p: *const u8, }\n"
    "struct HasMutRef { r: &mut u8, }\n"
    "struct HasRef { r: &u8, }\n"
    "struct Empty {}\n"
    "struct WrapMut { inner: HasMut, tag: i32, }\n"
    "struct WrapScalar { inner: Scalars, }\n"
    "struct HoldsConstToMut { q: *const HasMut, }\n"
    "struct HoldsMutToMut { q: *mut HasMut, }\n"
    "struct ArrMut { buf: [*mut u8; 3], }\n"
    "struct ArrOwner { items: [HasMut; 4], }\n"
    "struct ArrScalar { xs: [i32; 8], }\n"
    "struct ListMut { next: *mut ListMut, v: i32, }\n"
    "struct ListConst { next: *const ListConst, v: i32, }\n"
    "struct D10 { p: *mut u8, }\nstruct D9 { x: D10, }\nstruct D8 { x: D9, }\nstruct D7 { x: D8, }\n"
    "struct D6 { x: D7, }\nstruct D5 { x: D6, }\nstruct D4 { x: D5, }\nstruct D3 { x: D4, }\n"
    "struct D2 { x: D3, }\nstruct D1 { x: D2, }\n"
    "struct S10 { p: i32, }\nstruct S9 { x: S10, }\nstruct S8 { x: S9, }\nstruct S7 { x: S8, }\n"
    "struct S6 { x: S7, }\nstruct S5 { x: S6, }\nstruct S4 { x: S5, }\nstruct S3 { x: S4, }\n"
    "struct S2 { x: S3, }\nstruct S1 { x: S2, }\n"
    "fn main() i32 {\n"
    "  let a1: Scalars; let a2: HasMut; let a3: HasConstPtr; let a4: HasMutRef; let a5: HasRef;\n"
    "  let a6: Empty; let a7: WrapMut; let a8: WrapScalar; let a9: HoldsConstToMut; let a10: HoldsMutToMut;\n"
    "  let a11: ArrMut; let a12: ArrOwner; let a13: ArrScalar; let a14: ListMut; let a15: ListConst;\n"
    "  let a16: D1; let a17: S1;\n"
    "  return 0;\n"
    "}\n";

// Non-const is proven by the absence of `const <Type> <name>`; const by its presence.
static void test_owns_mut_simple(void) {
  expect_contains("scalar struct -> const", OWNS_MUT_ZOO, "const Scalars a1;");
  expect_absent("direct *mut field -> non-const", OWNS_MUT_ZOO, "const HasMut a2");
  expect_contains("*const field -> const", OWNS_MUT_ZOO, "const HasConstPtr a3;");
}

static void test_owns_mut_complex(void) {
  expect_absent("&mut field -> non-const", OWNS_MUT_ZOO, "const HasMutRef a4");
  expect_contains("&T (shared) field -> const", OWNS_MUT_ZOO, "const HasRef a5;");
  expect_absent("nested struct owning *mut -> non-const", OWNS_MUT_ZOO, "const WrapMut a7");
  expect_contains("nested scalar struct -> const", OWNS_MUT_ZOO, "const WrapScalar a8;");
  expect_absent("array of *mut -> non-const", OWNS_MUT_ZOO, "const ArrMut a11");
  expect_absent("array of mut-owners -> non-const", OWNS_MUT_ZOO, "const ArrOwner a12");
  expect_contains("array of scalars -> const", OWNS_MUT_ZOO, "const ArrScalar a13;");
}

static void test_owns_mut_nested_deep(void) {
  expect_absent("10-level value nest ending in *mut -> non-const", OWNS_MUT_ZOO, "const D1 a16");
  expect_contains("10-level value nest ending in scalar -> const", OWNS_MUT_ZOO, "const S1 a17;");
}

static void test_owns_mut_edge_cases(void) {
  expect_contains("empty struct -> const", OWNS_MUT_ZOO, "const Empty a6;");
  // a `*const` pointer to a mut-owner does NOT propagate (recursion stops at the pointer)...
  expect_contains("*const to a mut-owner -> const", OWNS_MUT_ZOO, "const HoldsConstToMut a9;");
  // ...but a `*mut` pointer is itself a writable address.
  expect_absent("*mut to a mut-owner -> non-const", OWNS_MUT_ZOO, "const HoldsMutToMut a10");
  // self-referential structs must not loop forever: the recursion halts at the pointer field.
  expect_absent("self-ref via *mut -> non-const", OWNS_MUT_ZOO, "const ListMut a14");
  expect_contains("self-ref via *const -> const", OWNS_MUT_ZOO, "const ListConst a15;");
}

static void test_constness(void) {
  expect_contains("immutable param is const", CONSTNESS, "const int32_t a");
  expect_contains("immutable let is const", CONSTNESS, "const int32_t x = a;");
  expect_absent("mutable let is not const", CONSTNESS, "const int32_t y");
  expect_contains("mutable let stays plain", CONSTNESS, "int32_t y = a;");
}

// Enum lowering: payload-less -> a plain C enum; a payload-bearing enum -> a tagged union.
static void test_enums(void) {
  static const char *const PLAIN = "enum Color { Red, Green, Blue, }\nfn f(c: Color) i32 { return 0; }\n";
  expect_contains("payload-less enum is a C enum", PLAIN, "Color_Red");
  expect_contains("payload-less enum typedef", PLAIN, "} Color;");

  static const char *const TAGGED = "enum Shape { Dot, Circle(i32), }\nfn f(s: Shape) i32 { return 0; }\n";
  expect_contains("tagged enum: tag type", TAGGED, "ShapeTag");
  expect_contains("tagged enum: tag constant", TAGGED, "Shape_Circle");
  expect_contains("tagged enum: union member", TAGGED, "union {");
  expect_contains("tagged enum: discriminant field", TAGGED, "tag;");

  // Enum::Variant construction lowers to a tagged-union compound literal.
  static const char *const CTOR = "enum E { A, B(i32), }\nfn f() E { return E::B(7); }\n";
  expect_contains("variant construct: tag", CTOR, ".tag = E_B");
  expect_contains("variant construct: payload", CTOR, ".payload.B = {");
  // A payload-less variant value is its plain C enum constant.
  expect_contains("plain variant value", "enum C { Red, Green, }\nfn f() C { return C::Green; }\n", "C_Green");

  // A bare unit-variant pattern is a tag test, NOT a catch-all binding (the fixed bug).
  static const char *const MATCH = "enum C { Red, Green, }\nfn f(c: C) i32 { return switch c { Red => 1, Green => 2, }; }\n";
  expect_contains("plain enum arm tests the tag", MATCH, "== C_Red");
  expect_absent("plain enum arm is not a binding", MATCH, "C Red =");
  expect_contains("exhaustive match is closed", MATCH, "__builtin_unreachable");

  // Explicit discriminants are emitted into the C enum.
  expect_contains(
      "explicit discriminant", "enum Code { Ok = 0, Bad = 404, }\nfn f(c: Code) i32 { return c as i32; }\n",
      "Code_Bad = 404");
}

// An `if` in value position lowers to a GNU statement-expression: a result temp, the if/else
// chain assigning each arm's tail to it, then the temp as the yielded value.
static void test_if_expression(void) {
  static const char *const SRC =
      "fn f(n: i32) i32 { let x: i32 = if n > 0 { 1; } else { 2; }; return x; }\n";
  expect_contains("if-expr is a statement-expression", SRC, "({");
  expect_contains("if-expr arm assigns the result temp", SRC, " = 1;");
  expect_contains("if-expr lowers the chain", SRC, "else {");
}

// Array literals: a brace list when initializing a real C array binding, a compound literal when in
// a general value position (so it can be passed by value).
static void test_array_literals(void) {
  expect_contains(
      "array literal let is a brace list", "fn f() void { let a: [i32; 3] = [1, 2, 3]; }\n", "= { 1, 2, 3 }");
  expect_absent(
      "array literal let is not a compound literal", "fn f() void { let a: [i32; 3] = [1, 2, 3]; }\n",
      "(int32_t[3]){ 1, 2, 3 }");
  expect_contains(
      "array literal argument is a compound literal",
      "fn g(a: [i32; 3]) i32 { return a[0]; }\nfn f() i32 { return g([1, 2, 3]); }\n", "(int32_t[3]){ 1, 2, 3 }");
}

// Multiple returns lower to a generated `<fn>_ret` struct and a compound-literal return.
static void test_multi_return(void) {
  static const char *const MR = "fn dm(a: i32, b: i32) (i32, i32) { return a + b, a - b; }\n";
  expect_contains("multi-return struct typedef", MR, "dm_ret");
  expect_contains("multi-return field", MR, "int32_t _0;");
  expect_contains("multi-return compound literal", MR, "(dm_ret){");

  // `let (x, y) = dm(..)` lowers to a temp plus one `._i` field read per binding.
  static const char *const DESTR =
      "fn dm(a: i32, b: i32) (i32, i32) { return a + b, a - b; }\n"
      "fn f() i32 { let (x, y) = dm(3, 1); return x + y; }\n";
  expect_contains("destructure temp", DESTR, "const __auto_type");
  expect_contains("destructure field 0", DESTR, "x = ");
  expect_contains("destructure reads _0", DESTR, "._0;");
  expect_contains("destructure reads _1", DESTR, "._1;");
}

// Slices lower to the SCslice fat pointer; fixed arrays keep their C array parameter form.
static void test_slices_and_arrays(void) {
  expect_contains("slice param is SCslice", "fn first(s: []i32) i32 { return s[0]; }\n", "const SCslice s");
  expect_contains("slice index casts ptr", "fn first(s: []i32) i32 { return s[0]; }\n", "((int32_t*)s.ptr)[0]");
  expect_contains("array param keeps extent", "fn g(a: [i32; 3]) i32 { return a[0]; }\n", "const int32_t a[3]");
}

static void test_errors(void) {
  expect_codegen_error("generic function", "fn id<T>(x: T) T { return x; }\n", "not yet supported");
  expect_codegen_error(
      "defer", "fn cleanup() void {}\nfn run() void { defer cleanup(); }\n", "not yet supported");
}

static void test_literals(void) {
  expect_contains("binary literal", "fn f() i32 { let a: i32 = 0b101; return a; }\n", "= 5;");
  expect_contains("digit separators", "fn f() i32 { let a: i32 = 1_000; return a; }\n", "= 1000;");
  expect_contains(
      "keyword identifier", "fn f() i32 { let register: i32 = 1; return register; }\n", "register_");
}

int main(void) {
  test_broad();
  test_control();
  test_ranges();
  test_switch_ranges();
  test_pointer_arith();
  test_references();
  test_extern();
  test_str();
  test_constness();
  test_owning_mut_constness();
  test_owns_mut_simple();
  test_owns_mut_complex();
  test_owns_mut_nested_deep();
  test_owns_mut_edge_cases();
  test_enums();
  test_if_expression();
  test_array_literals();
  test_multi_return();
  test_slices_and_arrays();
  test_errors();
  test_literals();
  if (failures) {
    fprintf(stderr, "%d codegen test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("codegen tests passed");
  return 0;
}
