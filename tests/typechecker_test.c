#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ast/parser.h"
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

// Lex, parse and resolve, returning the resolved AST, or NULL (after a CHECK failure) on any
// earlier-stage error (those stages have their own tests).
static Ast *resolve(const char *name, const char *source) {
  Lexer *lexer = lexer_new(source, strlen(source));
  lexer_scan_tokens(lexer);
  if (lexer_has_errors(lexer)) {
    String_Vec errors = lexer_take_errors(lexer);
    CHECK(false, "%s: lexer error: %s", name, errors.data[0]);
    free_errors(&errors);
    lexer_free(&lexer);
    return NULL;
  }

  Token_Vec tokens = lexer_take_tokens(lexer);
  lexer_free(&lexer);
  Parser *parser = parser_new(tokens, source, strlen(source));
  parser_build_ast(parser);
  if (parser_has_errors(parser)) {
    String_Vec errors = parser_take_errors(parser);
    CHECK(false, "%s: parser error: %s", name, errors.data[0]);
    free_errors(&errors);
    parser_free(&parser);
    return NULL;
  }
  Ast *ast = parser_take_ast(parser);
  parser_free(&parser);

  Resolver *resolver = resolver_new(ast, source, strlen(source));
  resolver_resolve(resolver);
  if (resolver_has_errors(resolver)) {
    String_Vec errors = resolver_take_errors(resolver);
    CHECK(false, "%s: resolver error: %s", name, errors.data[0]);
    free_errors(&errors);
    resolver_free(&resolver);
    return NULL;
  }
  ast = resolver_take_ast(resolver);
  resolver_free(&resolver);
  return ast;
}

static size_t check(const char *name, const char *source, const char *needle) {
  Ast *ast = resolve(name, source);
  if (!ast)
    return 0;
  TypeChecker *tc = typechecker_new(ast, source, strlen(source));
  typechecker_check(tc);
  String_Vec errors = typechecker_take_errors(tc);
  const size_t count = errors.len;
  if (needle && count)
    CHECK(strstr(errors.data[0], needle) != NULL, "%s: first error missing '%s':\n%s", name, needle, errors.data[0]);
  free_errors(&errors);
  typechecker_free(&tc);
  return count;
}

static void expect_ok(const char *name, const char *source) {
  CHECK(check(name, source, NULL) == 0, "%s: expected no type errors", name);
}

static void expect_error(const char *name, const char *source, const char *needle) {
  CHECK(check(name, source, needle) >= 1, "%s: expected a type error", name);
}

static void test_ok(void) {
  expect_ok(
      "field access",
      "struct P { x: i32, }\n"
      "fn main() void { let p: P = P { x: 1, }; let y: i32 = p.x; }\n");
  expect_ok(
      "method call binds self",
      "struct P { x: i32, }\n"
      "extend P { fn get(self: P) i32 { return self.x; } }\n"
      "fn main() void { let p: P = P { x: 1, }; let y: i32 = p.get(); }\n");
  expect_ok("literal coercion", "fn main() void { let x: u8 = 5; }\n");
  expect_ok("inferred binding", "fn main() void { let x = 1; let y: i32 = x; }\n");
  expect_ok(
      "call argument types",
      "fn add(a: i32, b: i32) i32 { return a; }\n"
      "fn main() void { let z: i32 = add(1, 2); }\n");
  expect_ok("bool condition", "fn main() void { if (true) { } }\n");
  expect_ok(
      "switch name binding",
      "fn classify(c: u8) i32 { return switch c { 0 => 1, n => 2, _ => 0, }; }\n");
  expect_ok(
      "struct pattern field",
      "struct P { x: i32, }\n"
      "fn f(p: P) i32 { return switch p { P { x: v } => v, }; }\n");
}

static void test_errors(void) {
  expect_error("let mismatch", "fn main() void { let b: bool = 1; }\n", "mismatched types");
  expect_error(
      "argument type", "fn g(a: bool) void {}\nfn main() void { g(1); }\n", "mismatched types");
  expect_error("argument count", "fn g(a: i32) void {}\nfn main() void { g(1, 2); }\n", "expected 1 argument");
  expect_error(
      "unknown field", "struct P { x: i32, }\nfn main() void { let p: P = P { x: 1, }; p.y; }\n",
      "no field or method 'y'");
  expect_error("non-bool condition", "fn main() void { if (1) { } }\n", "must be 'bool'");
  expect_error("assign immutable", "fn main() void { let x: i32 = 1; x = 2; }\n", "cannot assign");
  expect_error("return mismatch", "fn f() i32 { return true; }\n", "mismatched types");
  expect_error("index non-array", "fn main() void { let x: i32 = 1; let y: i32 = x[0]; }\n", "cannot index");
  expect_error(
      "unknown init field", "struct P { x: i32, }\nfn main() void { let p: P = P { y: 1, }; }\n", "no field 'y'");
}

int main(void) {
  test_ok();
  test_errors();
  if (failures) {
    fprintf(stderr, "%d typechecker test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("typechecker tests passed");
  return 0;
}
