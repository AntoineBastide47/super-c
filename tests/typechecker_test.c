// Type-checker coverage. Beyond the original pass/fail checks, this asserts the *computed* type
// stored on representative expression nodes (ast_type): comparisons yield bool, arithmetic keeps
// the operand type, pointer offset stays a pointer, deref yields the pointee, address-of yields a
// reference, and a bare literal adapts to its annotated type.

#include "test_harness.h"

static void expect_ok(const char *name, const char *source) {
  Ast *ast = sc_typecheck(name, source);
  if (ast)
    ast_free(&ast);
}

static void expect_error(const char *name, const char *source, const char *needle) {
  char first[256];
  const size_t n = sc_stage_errors(name, source, ST_TYPECHECK, first, sizeof first);
  CHECK(n >= 1, "%s: expected a type error", name);
  if (n)
    CHECK(strstr(first, needle) != NULL, "%s: first error missing '%s':\n%s", name, needle, first);
}

static void test_ok(void) {
  expect_ok(
      "field access",
      "struct P { pub x: i32, }\n"
      "fn main() i32 { let p: P = P { x: 1, }; let y: i32 = p.x; }\n");
  expect_ok(
      "method call binds self",
      "struct P { pub x: i32, }\n"
      "extend P { fn get(self: P) i32 { return self.x; } }\n"
      "fn main() i32 { let p: P = P { x: 1, }; let y: i32 = p.get(); }\n");
  expect_ok("entry point fn main() i32", "fn main() i32 { return 0; }\n");
  expect_ok("string literal is str", "fn main() i32 { let s: str = \"hi\"; let n: usize = s.len; }\n");
  expect_ok("str ptr field indexes to u8", "fn first(s: str) u8 { return s.ptr[0]; }\n");
  expect_ok(
      "private field reachable via self",
      "struct S { v: i32, }\nextend S { fn get(self: &S) i32 { return self.v; } }\n");
  expect_ok(
      "private field constructible inside extend",
      "struct S { v: i32, }\nextend S { fn make() S { return S { v: 1, }; } }\n");
  expect_ok("pub field readable from outside", "struct S { pub v: i32, }\nfn f(s: S) i32 { return s.v; }\n");
  expect_ok(
      "field and same-named method coexist", // `s.len` is the field, `s.len()` is the method
      "struct S { pub len: i32, }\nextend S { pub fn len(self: &S) i32 { return self.len; } }\n"
      "fn use(s: S) i32 { return s.len + s.len(); }\n");
  expect_ok("literal coercion", "fn main() i32 { let x: u8 = 5; }\n");
  expect_ok("inferred binding", "fn main() i32 { let x = 1; let y: i32 = x; }\n");
  expect_ok("int literal initializes a float", "fn main() i32 { let f: f64 = 0; let g: f32 = 5; let h: f64 = -3; }\n");
  expect_ok(
      "call argument types",
      "fn add(a: i32, b: i32) i32 { return a; }\n"
      "fn main() i32 { let z: i32 = add(1, 2); }\n");
  expect_ok("bool condition", "fn main() i32 { if (true) { } }\n");
  expect_ok(
      "switch name binding",
      "fn classify(c: u8) i32 { return switch c { 0 => 1, n => 2, _ => 0, }; }\n");
  expect_ok(
      "struct pattern field",
      "struct P { pub x: i32, }\n"
      "fn f(p: P) i32 { return switch p { P { x: v } => v, }; }\n");
  expect_ok("pointer offset", "fn f(p: *i32) i32 { let q: *i32 = p + 1; return *q; }\n");
  expect_ok("pointer minus int", "fn f(p: *i32) i32 { let q: *i32 = p - 1; return *q; }\n");
  expect_ok("int plus pointer", "fn f(p: *i32) i32 { let q: *i32 = 1 + p; return *q; }\n");
  expect_ok("pointer difference", "fn f(a: *i32, b: *i32) isize { return a - b; }\n");
  expect_ok("explicit void bare return", "fn f() void { return; }\n");
  expect_ok("range adopts usize bound", "fn f(n: usize) void { for i in 0..n { let x: usize = i; } }\n");
  expect_ok("associated new call", "struct String {}\nextend String { fn new() String { return String {}; } }\nfn f() String { return String::new(); }\n");
  expect_ok(
      "reference coerces to const pointer",
      "fn take(p: *const i32) i32 { return *p; }\n"
      "fn give(x: i32) i32 { return take(&x); }\n");
}

static void test_computed_scalar_types(void) {
  // `a < b` is bool; `a + b` keeps i32.
  static const char src[] = "fn f(a: i32, b: i32) bool { let c: bool = a < b; let d: i32 = a + b; return c; }\n";
  Ast *a = sc_typecheck("scalar types", src);
  if (!a)
    return;
  const NodeId lt = th_nth_kind(a, NODE_BINARY, 0); // a < b (parsed first)
  const NodeId add = th_nth_kind(a, NODE_BINARY, 1); // a + b
  CHECK(ast_type(a, lt) == ast_builtin(BT_BOOL), "comparison is bool");
  CHECK(ast_type(a, add) == ast_builtin(BT_I32), "i32 + i32 is i32");
  ast_free(&a);
}

static void test_computed_pointer_types(void) {
  static const char src[] = "fn f(p: *i32) i32 { let q: *i32 = p + 1; return *q; }\n";
  Ast *a = sc_typecheck("pointer types", src);
  if (!a)
    return;
  const NodeId off = th_nth_kind(a, NODE_BINARY, 0); // p + 1
  const TypeId ot = ast_type(a, off);
  CHECK(ast_type_at(a, ot)->kind == TYPE_POINTER, "pointer offset stays a pointer");
  CHECK(ast_type_at(a, ot)->as.elem == ast_builtin(BT_I32), "pointee is i32");
  const NodeId deref = th_nth_kind(a, NODE_UNARY, 0); // *q
  CHECK(ast_type(a, deref) == ast_builtin(BT_I32), "deref yields the pointee type");
  ast_free(&a);
}

static void test_computed_reference_type(void) {
  // `*p` is unary[0] (in `take`), `&x` is unary[1] (in `give`, parsed second).
  static const char src[] = "fn take(p: *const i32) i32 { return *p; }\n"
                            "fn give(x: i32) i32 { return take(&x); }\n";
  Ast *a = sc_typecheck("reference type", src);
  if (!a)
    return;
  const NodeId addr = th_nth_kind(a, NODE_UNARY, 1); // &x
  CHECK(ast_type_at(a, ast_type(a, addr))->kind == TYPE_REFERENCE, "address-of yields a reference");
  ast_free(&a);
}

// Each literal carries its intrinsic type; an integer literal stays i32 and merely *adapts* (via
// compatibility) into a narrower annotated type, rather than being retyped on the node.
static void test_literal_types(void) {
  static const char src[] = "fn main() i32 { let i = 5; let c = 'a'; let b = true; let f = 0.0; }\n";
  Ast *a = sc_typecheck("literal types", src);
  if (!a)
    return;
  CHECK(ast_type(a, th_nth_kind(a, NODE_LITERAL, 0)) == ast_builtin(BT_I32), "integer literal is i32");
  CHECK(ast_type(a, th_nth_kind(a, NODE_LITERAL, 1)) == ast_builtin(BT_CHAR), "char literal is char");
  CHECK(ast_type(a, th_nth_kind(a, NODE_LITERAL, 2)) == ast_builtin(BT_BOOL), "bool literal is bool");
  CHECK(ast_type(a, th_nth_kind(a, NODE_LITERAL, 3)) == ast_builtin(BT_F32), "float literal defaults to f32");
  ast_free(&a);
}

// An un-annotated `let`/`let mut` takes the initializer's computed type (not just literals).
static void test_inferred_let_types(void) {
  static const char src[] = "fn f(n: usize) usize { let m = n + 1; let mut k = m; k = k + n; return k; }\n";
  Ast *a = sc_typecheck("inferred let", src);
  if (!a)
    return;
  CHECK(ast_type(a, th_nth_kind(a, NODE_LET, 0)) == ast_builtin(BT_USIZE), "let m = n + 1 infers usize");
  CHECK(ast_type(a, th_nth_kind(a, NODE_LET, 1)) == ast_builtin(BT_USIZE), "let mut k = m infers usize");
  ast_free(&a);
}

// A string literal is a `str` view; `.len` is usize and `.ptr` is `*const u8` (indexes to u8).
static void test_str_member_types(void) {
  // The string literal is created first, so it is NODE_LITERAL[0]; the member accesses follow in
  // source order: g.len is NODE_MEMBER[0], g.ptr is NODE_MEMBER[1].
  static const char src[] = "fn main() i32 { let g: str = \"hi\"; let n: usize = g.len; let b: u8 = g.ptr[0]; return 0; }\n";
  Ast *a = sc_typecheck("str member types", src);
  if (!a)
    return;
  CHECK(ast_type(a, th_nth_kind(a, NODE_LITERAL, 0)) == ast_builtin(BT_STR), "string literal is str");
  const NodeId len_access = th_nth_kind(a, NODE_MEMBER, 0); // g.len
  CHECK(ast_type(a, len_access) == ast_builtin(BT_USIZE), "str.len is usize");
  const NodeId ptr_access = th_nth_kind(a, NODE_MEMBER, 1); // g.ptr
  const Ty *const pt = ast_type_at(a, ast_type(a, ptr_access));
  CHECK(pt->kind == TYPE_POINTER && pt->as.elem == ast_builtin(BT_U8), "str.ptr is *const u8");
  CHECK(pt->qualifier == TYPE_QUAL_CONST, "str.ptr is const-qualified");
  ast_free(&a);
}

static void test_errors(void) {
  expect_error("let mismatch", "fn main() i32 { let b: bool = 1; }\n", "mismatched types");
  expect_error("float literal not assignable to int", "fn main() i32 { let i: i32 = 0.0; }\n", "mismatched types");
  expect_error(
      "argument type", "fn g(a: bool) void {}\nfn main() i32 { g(1); }\n", "mismatched types");
  expect_error("argument count", "fn g(a: i32) void {}\nfn main() i32 { g(1, 2); }\n", "expected 1 argument");
  expect_error(
      "unknown field", "struct P { pub x: i32, }\nfn main() i32 { let p: P = P { x: 1, }; p.y; }\n",
      "no field or method 'y'");
  expect_error(
      "unknown str field", "fn f(s: str) i32 { return s.bogus as i32; }\n", "no field or method 'bogus'");
  // A non-pub field is private outside its struct's own extend: neither readable nor initializable.
  expect_error(
      "private field read outside", "struct S { v: i32, }\nfn f(s: S) i32 { return s.v; }\n", "field 'v' is private");
  expect_error(
      "private field init outside",
      "struct S { v: i32, }\nfn main() i32 { let s: S = S { v: 1, }; return 0; }\n", "field 'v' is private");
  expect_error(
      "private field of another struct inside extend",
      "struct A { v: i32, }\nstruct B {}\nextend B { fn peek(a: A) i32 { return a.v; } }\n", "field 'v' is private");
  expect_error("non-bool condition", "fn main() i32 { if (1) { } }\n", "must be 'bool'");
  expect_error("assign immutable", "fn main() i32 { let x: i32 = 1; x = 2; }\n", "cannot assign");
  // A `let` of a `*mut`-owning struct is non-const in C, but still an immutable *binding*: no rebinding.
  expect_error(
      "owning-mut let still not reassignable",
      "struct Buf { pub p: *mut u8, }\nfn f(b: Buf, c: Buf) { let x: Buf = b; x = c; }\n", "cannot assign");
  expect_error("return mismatch", "fn f() i32 { return true; }\n", "mismatched types");
  expect_error("index non-array", "fn main() i32 { let x: i32 = 1; let y: i32 = x[0]; }\n", "cannot index");
  expect_error(
      "unknown init field", "struct P { pub x: i32, }\nfn main() i32 { let p: P = P { y: 1, }; }\n", "no field 'y'");
  expect_error(
      "pointer plus pointer", "fn f(a: *i32, b: *i32) void { let c = a + b; }\n", "invalid pointer arithmetic");
  expect_error(
      "non-integer pointer offset", "fn f(p: *i32, y: f64) void { let q = p + y; }\n",
      "pointer arithmetic requires an integer offset");
  expect_error(
      "const pointer does not coerce to reference",
      "fn take(r: &i32) i32 { return *r; }\n"
      "fn give(p: *const i32) i32 { return take(p); }\n",
      "mismatched types");
  // The entry point must be exactly `fn main() i32` (it lowers to C's `int main(void)`).
  expect_error("main returning void", "fn main() void { }\n", "'main' must be declared 'fn main() i32'");
  expect_error("main with no return type", "fn main() { return; }\n", "'main' must be declared 'fn main() i32'");
  expect_error(
      "main with a wrong return type", "fn main() bool { return true; }\n", "'main' must be declared 'fn main() i32'");
  expect_error(
      "main with parameters", "fn main(x: i32) i32 { return 0; }\n", "'main' must be declared 'fn main() i32'");
}

int main(void) {
  test_ok();
  test_computed_scalar_types();
  test_computed_pointer_types();
  test_computed_reference_type();
  test_literal_types();
  test_inferred_let_types();
  test_str_member_types();
  test_errors();
  if (failures) {
    fprintf(stderr, "%d typechecker test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("typechecker tests passed");
  return 0;
}
