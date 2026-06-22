#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ast/parser.h"
#include "lexer/lexer.h"

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

static void test_items_and_types(void) {
  static const char source[] =
      "struct Pair<T> { left: T, right: T, }\n"
      "enum Result<T, E> { Ok(T), Err { error: E }, }\n"
      "type Callback = fn(*const u8, []u8, [u8; 16]) -> int;\n"
      "const LIMIT: usize = 16;\n"
      "extern \"C\" { type CFile; fn fclose(file: *mut CFile) -> int; }\n";
  Ast *ast = parse("items and types", source);
  if (!ast)
    return;
  const Node *root = ast_at_const(ast, ast->root);
  CHECK(root->kind == NODE_PROGRAM, "items and types: expected program root");
  CHECK(root->as.program.items.len == 5, "items and types: expected 5 items, got %u", root->as.program.items.len);
  const NodeId *items = ast_list(ast, root->as.program.items);
  CHECK(ast_at_const(ast, items[0])->kind == NODE_STRUCT, "items and types: item 0 should be struct");
  CHECK(ast_at_const(ast, items[1])->kind == NODE_ENUM, "items and types: item 1 should be enum");
  CHECK(ast_at_const(ast, items[2])->kind == NODE_TYPE_ALIAS, "items and types: item 2 should be type alias");
  CHECK(ast_at_const(ast, items[3])->kind == NODE_CONST, "items and types: item 3 should be const");
  CHECK(ast_at_const(ast, items[4])->kind == NODE_EXTERN_BLOCK, "items and types: item 4 should be extern");
  ast_free(&ast);
}

static void test_functions_and_expressions(void) {
  static const char source[] =
      "fn transform<T: Copy>(input: Result<Vec<T>, Error>, out: *mut T) -> int where T: Copy + Drop {\n"
      "  let mut value: int = 1 + 2 * 3;\n"
      "  let item = input.unwrap()[0] as int;\n"
      "  if (item >= value && value != 0) { value += item; } else { value = 0; }\n"
      "  while (value > 0) { value -= 1; }\n"
      "  for entry in input { defer consume(move entry); }\n"
      "  return value;\n"
      "}\n";
  Ast *ast = parse("functions and expressions", source);
  if (!ast)
    return;
  const Node *root = ast_at_const(ast, ast->root);
  const Node *fn = ast_at_const(ast, ast_list(ast, root->as.program.items)[0]);
  CHECK(fn->kind == NODE_FUNCTION, "functions and expressions: expected function");
  CHECK(fn->as.function.generics.len == 1, "functions and expressions: expected one generic");
  CHECK(fn->as.function.params.len == 2, "functions and expressions: expected two parameters");
  CHECK(fn->as.function.where_clause.len == 1, "functions and expressions: expected one where predicate");
  const Node *body = ast_at_const(ast, fn->as.function.body);
  CHECK(body->kind == NODE_BLOCK, "functions and expressions: expected function block");
  CHECK(body->as.block.statements.len == 6, "functions and expressions: expected 6 statements, got %u",
        body->as.block.statements.len);
  ast_free(&ast);
}

static void test_traits_impls_match_and_new(void) {
  static const char source[] =
      "interface Factory<T> { type Output; fn make(value: T) -> Self::Output; }\n"
      "extend<T> Box<T> as Factory<T> {\n"
      "  type Output = Box<T>;\n"
      "  fn make(value: T) -> Box<T> { return new Box<T> { value: value }; }\n"
      "}\n"
      "fn classify(c: u8) -> int {\n"
      "  return switch c { case '0'..='9' => 1, Value(x) if x > 0 => x, _ => 0, };\n"
      "}\n";
  Ast *ast = parse("interfaces extensions switch and new", source);
  if (!ast)
    return;
  const Node *root = ast_at_const(ast, ast->root);
  CHECK(root->as.program.items.len == 3, "interfaces extensions switch and new: expected 3 items");
  const NodeId *items = ast_list(ast, root->as.program.items);
  CHECK(ast_at_const(ast, items[0])->kind == NODE_TRAIT, "expected interface");
  CHECK(ast_at_const(ast, items[1])->kind == NODE_IMPL, "expected extension");
  CHECK(ast_at_const(ast, items[2])->kind == NODE_FUNCTION, "expected function");
  ast_free(&ast);
}

int main(void) {
  test_items_and_types();
  test_functions_and_expressions();
  test_traits_impls_match_and_new();
  if (failures) {
    fprintf(stderr, "%d parser test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("parser tests passed");
  return 0;
}
