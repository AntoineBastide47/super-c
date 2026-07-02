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
  expect_contains("pointer offset", "fn f(p: *i32) i32 { return unsafe *(p + 1); }\n", "(p + 1)");
  expect_contains("pointer difference", "fn f(a: *i32, b: *i32) isize { return unsafe (a - b); }\n", "(a - b)");
}

// Reference/pointer C lowering: `&T`->`const T *`, `&mut T`->`T *`; raw `*const T`->`const T *`,
// `*mut T`->`T *`. Distinct parameter names let the assertions pin const-pointee vs mutable.
static const char *const REFS =
    "struct P { pub x: i32, }\n"
    "fn reads(r: &P) i32 { return r.x; }\n"
    "fn writes(w: &mut P) void { w.x = 1; }\n"
    "fn raw_c(pc: *const i32) i32 { return unsafe *pc; }\n"
    "fn raw_m(pm: *mut i32) void { unsafe *pm = 1; }\n";

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
    "fn main() i32 { let r: i32 = unsafe putchar(72); }\n";

static void test_extern(void) {
  // `extern "C"` functions get NO emitted prototype -- every C standard-library header is already
  // included, so the real declaration is in scope and re-declaring it would clash on signatures we
  // cannot reproduce exactly (e.g. `FILE *fopen`). The call site emits the bare unmangled C name.
  expect_absent("extern prototype suppressed", EXTERN, "(putchar)(");
  expect_contains("extern call site", EXTERN, "putchar(72)");

  // `extern "C" "<header>"` emits an #include so bindings reach non-standard headers: a bare name -> a
  // system include `<...>`; a path starting with '.' or '/' -> a quote include "...".
  expect_contains(
      "extern system header include",
      "extern \"C\" \"pthread.h\" { type pthread_t; fn pthread_self() pthread_t; }\n"
      "fn main() i32 { let t: pthread_t = unsafe pthread_self(); return 0; }\n",
      "#include <pthread.h>");
  expect_contains(
      "extern local header include",
      "extern \"C\" \"./lib.h\" { fn answer() i32; }\nfn main() i32 { return unsafe answer(); }\n",
      "#include \"./lib.h\"");

  // A variadic call emits every argument verbatim (fixed + trailing); the binding keeps its C name.
  expect_contains(
      "variadic call passes all args",
      "extern \"C\" { fn printf(fmt: *const char, ...) i32; }\n"
      "fn main() i32 { let f: char = '%'; unsafe printf(&f, 1, 2, 3); return 0; }\n",
      "1, 2, 3)");

  // A string literal in a `*const char` slot (fixed fmt + `%s` vararg) emits the bare C string, not a
  // `str` view; a `*const u8` slot adds the cast; elsewhere it stays a `str`.
  expect_contains(
      "string literal -> bare C string in fmt + vararg",
      "extern \"C\" { fn printf(fmt: *const char, ...) i32; }\n"
      "fn main() i32 { unsafe printf(\"%s\\n\", \"hi\"); return 0; }\n",
      "printf(\"%s\\n\", \"hi\")");
  expect_contains(
      "string literal -> *const u8 adds cast",
      "extern \"C\" { fn f(s: *const u8) i32; }\nfn main() i32 { return unsafe f(\"hi\"); }\n",
      "(const uint8_t *)\"hi\"");
  expect_contains( // an uncoerced literal of "zq9" keeps the full str fat-pointer view
      "string literal stays str view by default", "fn main() i32 { let s: str = \"zq9\"; return 0; }\n",
      "(str){ (const uint8_t *)\"zq9\"");

  // `c64`/`c32` render to real C `_Complex` scalar types.
  expect_contains(
      "complex builtin renders to _Complex", "fn main() i32 { let z: c64 = 3.0; let w: c32 = 1.0; return 0; }\n",
      "double _Complex");
  expect_contains(
      "c32 renders to float _Complex", "fn main() i32 { let w: c32 = 1.0; return 0; }\n", "float _Complex");

  // The atomics runtime shim ships in the emitted output, ready for an `extern` binding to call.
  expect_contains("atomics runtime shim emitted", EXTERN, "__sc_atomic_fence");
}

static const char *const STR = "fn f(s: str) usize { return s.len; }\nfn main() i32 { let g: str = \"hi\"; return 0; }\n";

static void test_str(void) {
  // `str` is now the std prelude's struct, emitted as a forward typedef + a body (so types can name it
  // in any order), not the old inline anonymous typedef.
  expect_contains("str forward typedef", STR, "typedef struct str str;");
  expect_contains("str struct body", STR, "struct str {\n  const uint8_t *ptr;\n  size_t len;\n};");
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

// Binding const-ness follows the binding's mutability ONLY (`let` vs `let mut`). A type owning a `*mut`
// internally (`Buf.ptr`) is an encapsulated detail and does NOT make an immutable binding non-const --
// mutating an immutable binding is rejected by the typechecker, not papered over in codegen.
static const char *const BIND_CONST =
    "struct Buf { pub ptr: *mut u8, }\n"
    "fn main() i32 { let b: Buf = Buf { ptr: null, }; let mut m: Buf = Buf { ptr: null, };\n"
    "  let x: i32 = 5; let mut y: i32 = 6; return x; }\n";

static void test_binding_constness(void) {
  expect_contains("immutable let of owning type is const", BIND_CONST, "const Buf b =");
  expect_absent("mut let of owning type is non-const", BIND_CONST, "const Buf m");
  expect_contains("scalar immutable let is const", BIND_CONST, "const int32_t x = 5");
  expect_absent("scalar mut let is non-const", BIND_CONST, "const int32_t y");
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

// `[]T` lowers to the prelude's monomorphized Slice<T> / SliceMut<T> fat-pointer struct (typed `.ptr`);
// fixed arrays keep their C array parameter form, and an array argument coerces to a slice view.
static void test_slices_and_arrays(void) {
  expect_contains("slice param is Slice__T", "fn first(s: []i32) i32 { return s[0]; }\n", "const Slice__i32 s");
  expect_contains("mut slice param is SliceMut__T", "fn set0(s: []mut i32) { s[0] = 1; }\n", "const SliceMut__i32 s");
  expect_contains("slice index uses typed ptr, bounds-checked", "fn first(s: []i32) i32 { return s[0]; }\n",
                  "s.ptr[__sc_bounds(0, s.len)]");
  expect_contains("array param keeps extent", "fn g(a: [i32; 3]) i32 { return a[0]; }\n", "const int32_t a[3]");
  expect_contains(
      "array arg coerces to slice view", "fn take(s: []i32) i32 { return s[0]; }\nfn m() i32 { let a: [i32; 2] = [4, 5]; return take(a); }\n",
      "(Slice__i32){ .ptr = a, .len = 2 }");
}

static void test_errors(void) {
  // `defer` now lowers: the deferred call is emitted at the block's exit, not at the defer site.
  expect_contains(
      "defer lowers to scope-exit call", "fn cleanup() void {}\nfn run() void { defer cleanup(); }\n", "cleanup()");
  // designated array initializer keeps the C `[index] = value` form.
  expect_contains(
      "designated array init", "fn m() i32 { let t: [i32; 4] = [[2] = 9]; return t[2]; }\n", "[2] = 9");
  // a block-local `const` table becomes a `static const`.
  expect_contains(
      "local const is static const", "fn m() i32 { const T: [i32; 2] = [1, 2]; return T[0]; }\n", "static const");
  // static_assert lowers to C `_Static_assert`.
  expect_contains("static_assert lowers", "static_assert(1 == 1);\nfn m() i32 { return 0; }\n", "_Static_assert(");
  // do/while keeps the post-tested loop form.
  expect_contains(
      "do/while form", "fn m() i32 { let mut i: i32 = 0; do { i = i + 1; } while i < 3; return i; }\n", "do {");
}

// `@c.*` attributes lower to portable C keywords + a combined GNU `__attribute__`; export/import pin the
// exact C symbol (no module mangling) at both the definition and call sites; packed/align ride the struct.
static void test_attributes(void) {
  expect_contains("noreturn", "@c.noreturn\nfn die() void {}\nfn main() i32 { return 0; }\n", "_Noreturn");
  expect_contains(
      "always_inline", "@c.always_inline\nfn a(x: i32) i32 { return x; }\nfn main() i32 { return a(0); }\n",
      "inline __attribute__((always_inline, unused))");
  expect_contains(
      "section + used", "@c.section(\"hot\")\n@c.used\nfn a() i32 { return 0; }\nfn main() i32 { return a(); }\n",
      "__attribute__((used, section(\"hot\")))");
  expect_contains(
      "packed struct", "@c.packed\nstruct H { pub x: u32 }\nfn main() i32 { let h = H { x: 1 }; return h.x as i32; }\n",
      "struct __attribute__((packed)) H");
  expect_contains(
      "aligned struct", "@c.align(64)\nstruct L { pub x: i64 }\nfn main() i32 { let l = L { x: 0 }; return l.x as i32; }\n",
      "__attribute__((aligned(64)))");
  // export renames the symbol AND every call site to it; no `static`.
  const char *const EX = "@c.export(\"sc_init\")\nfn init() i32 { return 0; }\nfn main() i32 { return init(); }\n";
  expect_contains("export defines the exact symbol", EX, "int32_t sc_init(void)");
  expect_contains("export rewrites the call site", EX, "return sc_init()");
  expect_absent("export elides the Super-C name", EX, " init(");
  // import renames an extern binding's symbol at the call site.
  expect_contains(
      "import binds to the C symbol",
      "extern \"C\" { @c.import(\"puts\") fn line(s: *const char) i32; }\nfn main() i32 { unsafe line(\"x\"); return 0; }\n",
      "puts(");
}

// A generic function emits no template; each turbofish instantiation emits a concrete `<fn>__<args>` copy
// with the type param substituted, and the call site references it.
static void test_generics(void) {
  const char *const ID = "fn id<T>(x: T) T { return x; }\n"
                         "fn main() i32 { let a: i32 = id::<i32>(5); let b: bool = id::<bool>(true); return a; }\n";
  expect_contains("generic specialization with substituted return", ID, "int32_t id__i32(");
  expect_contains("second instantiation", ID, "id__bool(");
  expect_absent("no generic template emitted", ID, " id(");
  // A payload-bearing generic enum's shared discriminant is emitted once AND wrapped in an include guard,
  // so even past the dedup table's bound a second emission can never be a C redefinition.
  const char *const ENUM = "enum Opt<T> { Some(T), None }\n"
                           "fn main() i32 { let a: Opt<i32> = Opt::<i32>::Some(1); let b: Opt<bool> = Opt::<bool>::None;\n"
                           "  return switch a { Some(v) => v, None => 0, } + switch b { Some(_) => 1, None => 0, }; }\n";
  expect_contains("generic enum tag is include-guarded", ENUM, "SUPER_ENUMTAG_Opt");
  expect_contains("generic enum tag emitted once", ENUM, "} OptTag;");
}

static void test_literals(void) {
  expect_contains("binary literal", "fn f() i32 { let a: i32 = 0b101; return a; }\n", "= 5;");
  expect_contains("digit separators", "fn f() i32 { let a: i32 = 1_000; return a; }\n", "= 1000;");
  expect_contains(
      "keyword identifier", "fn f() i32 { let register: i32 = 1; return register; }\n", "register_");
}

// Win 1: a free fn called with a statically-known callback is specialized (direct call, param elided);
// a runtime callback keeps the pointer original.
static void test_callback_specialization(void) {
  static const char KNOWN[] = "fn apply(x: i32, f: fn(i32) i32) i32 { return f(x); }\n"
                              "fn inc(x: i32) i32 { return x + 1; }\n"
                              "fn use() i32 { return apply(10, inc); }\n";
  expect_contains("callback specialization emitted", KNOWN, "apply__cb_inc(");
  expect_contains("callback call site elides the callback arg", KNOWN, "apply__cb_inc(10)");
  expect_absent("private specialized-away original elided", KNOWN,
                "int32_t apply(const int32_t x, int32_t (*const f)(int32_t))");

  static const char RUNTIME[] = "fn apply(x: i32, f: fn(i32) i32) i32 { return f(x); }\n"
                                "fn inc(x: i32) i32 { return x + 1; }\n"
                                "fn use() i32 { let k: fn(i32) i32 = inc; return apply(10, k); }\n";
  expect_contains("runtime callback keeps the pointer original", RUNTIME,
                  "int32_t apply(const int32_t x, int32_t (*const f)(int32_t))");
  expect_absent("runtime callback is not specialized", RUNTIME, "__cb_");
}

int main(void) {
  test_callback_specialization();
  test_broad();
  test_control();
  test_ranges();
  test_switch_ranges();
  test_pointer_arith();
  test_references();
  test_extern();
  test_str();
  test_constness();
  test_binding_constness();
  test_enums();
  test_if_expression();
  test_array_literals();
  test_multi_return();
  test_slices_and_arrays();
  test_errors();
  test_attributes();
  test_generics();
  test_literals();
  if (failures) {
    fprintf(stderr, "%d codegen test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("codegen tests passed");
  return 0;
}
