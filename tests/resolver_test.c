#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ast/parser.h"
#include "lexer/lexer.h"
#include "resolver/resolver.h"

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

// Lex and parse, returning the AST, or NULL (after a CHECK failure) on a lexer/parser error.
static Ast *parse(const char *name, const char *source) {
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
  return ast;
}

static size_t resolve(const char *name, const char *source, const char *needle) {
  Ast *ast = parse(name, source);
  if (!ast)
    return 0;
  Resolver *resolver = resolver_new(ast, source, strlen(source));
  resolver_resolve(resolver);
  String_Vec errors = resolver_take_errors(resolver);
  const size_t count = errors.len;
  if (needle && count)
    CHECK(strstr(errors.data[0], needle) != NULL, "%s: first error missing '%s':\n%s", name, needle, errors.data[0]);
  free_errors(&errors);
  resolver_free(&resolver);
  return count;
}

static void expect_ok(const char *name, const char *source) {
  CHECK(resolve(name, source, NULL) == 0, "%s: expected no resolution errors", name);
}

static void expect_error(const char *name, const char *source, const char *needle) {
  CHECK(resolve(name, source, needle) >= 1, "%s: expected a resolution error", name);
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

static void test_errors(void) {
  expect_error("undefined value", "fn main() void { bar(); }\n", "cannot find value 'bar'");
  expect_error("undefined type", "fn f(x: Widget) void {}\n", "cannot find type 'Widget'");
  expect_error("duplicate item", "struct P {}\nstruct P {}\n", "duplicate definition of 'P'");
  expect_error("duplicate parameter", "fn f(a: i32, a: i32) void {}\n", "duplicate definition of 'a'");
  expect_error("duplicate let", "fn f() void { let x: i32 = 1; let x: i32 = 2; }\n", "duplicate definition of 'x'");
  expect_error(
      "local escapes its block", "fn f() void { { let x: i32 = 1; } use_x(x); }\nfn use_x(n: i32) void {}\n",
      "cannot find value 'x'");
  expect_error("Self outside impl", "fn f(x: Self) void {}\n", "'Self' is only valid");
}

int main(void) {
  test_resolves();
  test_errors();
  if (failures) {
    fprintf(stderr, "%d resolver test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("resolver tests passed");
  return 0;
}
