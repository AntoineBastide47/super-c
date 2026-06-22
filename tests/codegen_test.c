#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ast/parser.h"
#include "codegen/codegen.h"
#include "lexer/lexer.h"
#include "resolver/resolver.h"
#include "typechecker/typechecker.h"

static int failures;

#define CHECK(condition, ...)                                                                                          \
  do {                                                                                                                 \
    if (!(condition)) {                                                                                                \
      fprintf(stderr, "%s:%d: ", __FILE__, __LINE__);                                                                  \
      fprintf(stderr, __VA_ARGS__);                                                                                    \
      fputc('\n', stderr);                                                                                             \
      failures++;                                                                                                      \
    }                                                                                                                  \
  } while (0)

static void free_errors(String_Vec *errors) {
  for (size_t i = 0; i < errors->len; i++)
    free(errors->data[i]);
  VEC_DEINIT_REF(errors);
}

// Lex, parse, resolve and type-check; returns the type-checked AST, or NULL (after a CHECK
// failure) if any earlier stage erred (those stages own their own test suites).
static Ast *check_pipeline(const char *name, const char *source) {
  const size_t len = strlen(source);
  Lexer *lexer = lexer_new(source, len);
  lexer_scan_tokens(lexer);
  if (lexer_has_errors(lexer)) {
    String_Vec e = lexer_take_errors(lexer);
    CHECK(false, "%s: lexer error: %s", name, e.data[0]);
    free_errors(&e);
    lexer_free(&lexer);
    return NULL;
  }
  Token_Vec tokens = lexer_take_tokens(lexer);
  lexer_free(&lexer);

  Parser *parser = parser_new(tokens, source, len);
  parser_build_ast(parser);
  if (parser_has_errors(parser)) {
    String_Vec e = parser_take_errors(parser);
    CHECK(false, "%s: parser error: %s", name, e.data[0]);
    free_errors(&e);
    parser_free(&parser);
    return NULL;
  }
  Ast *ast = parser_take_ast(parser);
  parser_free(&parser);

  Resolver *resolver = resolver_new(ast, source, len);
  resolver_resolve(resolver);
  if (resolver_has_errors(resolver)) {
    String_Vec e = resolver_take_errors(resolver);
    CHECK(false, "%s: resolver error: %s", name, e.data[0]);
    free_errors(&e);
    resolver_free(&resolver);
    return NULL;
  }
  ast = resolver_take_ast(resolver);
  resolver_free(&resolver);

  TypeChecker *tc = typechecker_new(ast, source, len);
  typechecker_check(tc);
  if (typechecker_has_errors(tc)) {
    String_Vec e = typechecker_take_errors(tc);
    CHECK(false, "%s: type error: %s", name, e.data[0]);
    free_errors(&e);
    typechecker_free(&tc);
    return NULL;
  }
  ast = typechecker_take_ast(tc);
  typechecker_free(&tc);
  return ast;
}

typedef struct {
    char *code;
    size_t errors;
    char first[256];
} Gen;

// Run the full pipeline through codegen into an in-memory FILE*. `code` is heap-allocated (free
// it); `first` holds the first codegen diagnostic, if any.
static Gen gen(const char *name, const char *source) {
  Gen g = {NULL, 0, {0}};
  Ast *ast = check_pipeline(name, source);
  if (!ast)
    return g;

  char *buf = NULL;
  size_t size = 0;
  FILE *f = open_memstream(&buf, &size);
  Codegen *cg = codegen_new(ast, source, strlen(source));
  codegen_emit(cg, f);
  fclose(f);

  String_Vec errs = codegen_take_errors(cg);
  g.errors = errs.len;
  if (errs.len)
    snprintf(g.first, sizeof g.first, "%s", errs.data[0]);
  free_errors(&errs);
  codegen_free(&cg);
  g.code = buf;
  return g;
}

static void expect_contains(const char *name, const char *source, const char *needle) {
  Gen g = gen(name, source);
  if (!g.code)
    return;
  CHECK(g.errors == 0, "%s: unexpected codegen error: %s", name, g.first);
  CHECK(strstr(g.code, needle) != NULL, "%s: emitted C missing '%s':\n%s", name, needle, g.code);
  free(g.code);
}

static void expect_absent(const char *name, const char *source, const char *needle) {
  Gen g = gen(name, source);
  if (!g.code)
    return;
  CHECK(g.errors == 0, "%s: unexpected codegen error: %s", name, g.first);
  CHECK(strstr(g.code, needle) == NULL, "%s: emitted C should not contain '%s':\n%s", name, needle, g.code);
  free(g.code);
}

static void expect_codegen_error(const char *name, const char *source, const char *needle) {
  Gen g = gen(name, source);
  if (!g.code)
    return;
  CHECK(g.errors >= 1, "%s: expected a codegen diagnostic", name);
  if (g.errors)
    CHECK(strstr(g.first, needle) != NULL, "%s: diagnostic missing '%s':\n%s", name, needle, g.first);
  free(g.code);
}

static const char *const BROAD =
    "struct Point { x: i32, }\n"
    "extend Point { fn get(self: &Point) i32 { return self.x; } }\n"
    "fn add(a: i32, b: i32) i32 { return a + b; }\n"
    "fn main() void {\n"
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

static void test_pointer_arith(void) {
  expect_contains("pointer offset", "fn f(p: *i32) i32 { return *(p + 1); }\n", "(p + 1)");
  expect_contains("pointer difference", "fn f(a: *i32, b: *i32) isize { return a - b; }\n", "(a - b)");
}

// Reference/pointer C lowering: `&T`->`const T *`, `&mut T`->`T *`; raw `*const T`->`const T *`,
// `*mut T`->`T *`. Distinct parameter names let the assertions pin const-pointee vs mutable.
static const char *const REFS =
    "struct P { x: i32, }\n"
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
    "fn main() void { let r: i32 = putchar(72); }\n";

static void test_extern(void) {
  expect_contains("extern prototype", EXTERN, "extern int32_t putchar(const int32_t c);");
  expect_contains("extern call site", EXTERN, "putchar(72)");
}

static const char *const CONSTNESS =
    "fn f(a: i32) i32 {\n"
    "  let x: i32 = a;\n"
    "  let mut y: i32 = a;\n"
    "  y = y + 1;\n"
    "  return x + y;\n"
    "}\n";

static void test_constness(void) {
  expect_contains("immutable param is const", CONSTNESS, "const int32_t a");
  expect_contains("immutable let is const", CONSTNESS, "const int32_t x = a;");
  expect_absent("mutable let is not const", CONSTNESS, "const int32_t y");
  expect_contains("mutable let stays plain", CONSTNESS, "int32_t y = a;");
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
  test_pointer_arith();
  test_references();
  test_extern();
  test_constness();
  test_errors();
  test_literals();
  if (failures) {
    fprintf(stderr, "%d codegen test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("codegen tests passed");
  return 0;
}
