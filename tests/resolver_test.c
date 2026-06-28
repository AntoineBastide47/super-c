// Resolver coverage. Beyond the original error-count checks, this asserts actual resolution
// *targets* (ast_resolution(ref) == the expected decl node): nearest-shadow wins, and the
// value/type namespaces are independent. Value uses resolve on their NODE_IDENTIFIER; type uses
// resolve on the NODE_TYPE_PATH -- so the two are unambiguous to locate via an arena scan.

#include "test_harness.h"

static void expect_ok(const char *name, const char *source) {
  Ast *ast = sc_resolve(name, source);
  if (ast)
    ast_free(&ast);
}

static void expect_error(const char *name, const char *source, const char *needle) {
  char first[256];
  const size_t n = sc_stage_errors(name, source, ST_RESOLVE, first, sizeof first);
  CHECK(n >= 1, "%s: expected a resolution error", name);
  if (n)
    CHECK(strstr(first, needle) != NULL, "%s: first error missing '%s':\n%s", name, needle, first);
}

// All NODE_IDENTIFIER value-uses named `name` that the resolver bound, in creation order.
static size_t value_uses(const Ast *a, const char *src, const char *name, NodeId *out, const size_t cap) {
  size_t n = 0;
  for (NodeId id = 1; id < (NodeId)a->nodes.len; id++)
    if (th_ident_is(a, src, id, name) && ast_resolution(a, id) != NODE_NONE && n < cap)
      out[n++] = id;
  return n;
}

static void test_resolves(void) {
  expect_ok(
      "forward references",
      "fn use_it(p: Pair) void { make(p); }\n"
      "fn make(p: Pair) void {}\n"
      "struct Pair { left: i32, right: i32, }\n");
  expect_ok(
      "nested shadowing",
      "fn f() void {\n"
      "  let x: i32 = 1;\n"
      "  { let x: i32 = 2; g(x); }\n"
      "  g(x);\n"
      "}\n"
      "fn g(n: i32) void {}\n");
  expect_ok(
      "generics self and Self",
      "struct Wrap<T> { value: T, }\n"
      "interface Show { fn show(self: u8) void; }\n"
      "extend<T> Wrap<T> { fn get(self: Self) T { return self.value; } }\n");
  expect_ok(
      "loop match and let scopes",
      "struct List {}\n"
      "fn each(items: List) void { for x in items { take(x); } }\n"
      "fn classify(c: u8) i32 { return switch c { 0 => 1, n => n, _ => 0, }; }\n"
      "fn take(n: i32) void {}\n");
}

// Two uses of `x` must bind to the two different `let x` declarations: the inner use to the inner
// let (nearest shadow), the outer use to the outer let.
static void test_nearest_shadow(void) {
  static const char src[] = "fn g(n: i32) void {}\n"
                            "fn f() void {\n"
                            "  let x: i32 = 1;\n"
                            "  { let x: i32 = 2; g(x); }\n"
                            "  g(x);\n"
                            "}\n";
  Ast *a = sc_resolve("nearest shadow", src);
  if (!a)
    return;
  const NodeId outer_let = th_nth_kind(a, NODE_LET, 0); // created first
  const NodeId inner_let = th_nth_kind(a, NODE_LET, 1);
  NodeId uses[4];
  const size_t n = value_uses(a, src, "x", uses, 4);
  CHECK(n == 2, "two bound uses of x, got %zu", n);
  if (n == 2) {
    CHECK(ast_resolution(a, uses[0]) == inner_let, "inner g(x) binds to the inner let");
    CHECK(ast_resolution(a, uses[1]) == outer_let, "outer g(x) binds to the outer let");
    CHECK(inner_let != outer_let, "the two lets are distinct declarations");
  }
  ast_free(&a);
}

// The same spelling in the value and type namespaces resolves to different decls.
static void test_namespace_separation(void) {
  static const char src[] = "struct Foo {}\n"
                            "const Foo: i32 = 5;\n"
                            "fn main() i32 { let x: Foo = Foo; }\n";
  Ast *a = sc_resolve("namespace separation", src);
  if (!a)
    return;
  const NodeId struct_decl = th_nth_kind(a, NODE_STRUCT, 0);
  const NodeId const_decl = th_nth_kind(a, NODE_CONST, 0);

  NodeId uses[4];
  const size_t n = value_uses(a, src, "Foo", uses, 4); // value use is the let initializer
  CHECK(n == 1, "one value use of Foo, got %zu", n);
  if (n == 1)
    CHECK(ast_resolution(a, uses[0]) == const_decl, "value Foo binds to the const, not the struct");

  NodeId type_path = NODE_NONE; // type use is the `: Foo` annotation, resolved on the NODE_TYPE_PATH
  for (NodeId id = 1; id < (NodeId)a->nodes.len; id++)
    if (ast_at_const(a, id)->kind == NODE_TYPE_PATH && ast_resolution(a, id) != NODE_NONE)
      type_path = id;
  CHECK(type_path != NODE_NONE && ast_resolution(a, type_path) == struct_decl, "type Foo binds to the struct");
  ast_free(&a);
}

static void test_errors(void) {
  expect_error("undefined value", "fn main() i32 { bar(); }\n", "cannot find value 'bar'");
  expect_error("undefined type", "fn f(x: Widget) void {}\n", "cannot find type 'Widget'");
  expect_error("duplicate item", "struct P {}\nstruct P {}\n", "duplicate definition of 'P'");
  expect_error("duplicate parameter", "fn f(a: i32, a: i32) void {}\n", "duplicate definition of 'a'");
  expect_error("duplicate let", "fn f() void { let x: i32 = 1; let x: i32 = 2; }\n", "duplicate definition of 'x'");
  expect_error(
      "local escapes its block", "fn f() void { { let x: i32 = 1; } use_x(x); }\nfn use_x(n: i32) void {}\n",
      "cannot find value 'x'");
  expect_error("Self outside extend", "fn f(x: Self) void {}\n", "'Self' is only valid");
}

static void test_closures(void) {
  // A closure may use its own params, module-level functions and consts -- none of those is a capture.
  expect_ok(
      "closure uses params and module items",
      "const K: i32 = 3;\n"
      "fn helper(n: i32) i32 { return n; }\n"
      "fn main() i32 { let f = |x: i32| helper(x) + K; return f(1); }\n");
  // Referencing an outer local from inside a closure is a capture -- rejected in Stage 1.
  expect_error(
      "closure captures outer let", "fn main() i32 { let base = 10; let f = |x: i32| x + base; return f(1); }\n",
      "cannot capture local variable 'base'");
  expect_error(
      "closure captures outer param", "fn add(b: i32) i32 { let f = |x: i32| x + b; return f(1); }\n",
      "cannot capture local variable 'b'");
}

int main(void) {
  test_resolves();
  test_nearest_shadow();
  test_namespace_separation();
  test_errors();
  test_closures();
  if (failures) {
    fprintf(stderr, "%d resolver test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("resolver tests passed");
  return 0;
}
