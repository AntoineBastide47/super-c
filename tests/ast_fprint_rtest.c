// Coverage of ast/ast.c::ast_fprint, which is compiled in only under NDEBUG. This file is the
// release/NDEBUG test lane (Makefile `rtest`); it must NOT use *_take_errors (compiled out under
// NDEBUG), so it drives lex+parse directly and bails via has_errors on the clean input.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ast/ast.h"
#include "ast/parser.h"
#include "lexer/lexer.h"

static int failures;

#define CHECK(cond, ...)                                                                                               \
  do {                                                                                                                 \
    if (!(cond)) {                                                                                                     \
      fprintf(stderr, "%s:%d: ", __FILE__, __LINE__);                                                                  \
      fprintf(stderr, __VA_ARGS__);                                                                                    \
      fputc('\n', stderr);                                                                                             \
      failures++;                                                                                                      \
    }                                                                                                                  \
  } while (0)

#define CONTAINS(hay, needle) CHECK(strstr((hay), (needle)) != NULL, "dump missing '%s':\n%s", (needle), (hay))

int main(void) {
  static const char source[] = "fn add(a: i32, b: i32) i32 { return a + b; }\n";
  const size_t len = strlen(source);

  Lexer *lexer = lexer_new(source, len);
  lexer_scan_tokens(lexer);
  CHECK(!lexer_has_errors(lexer), "unexpected lexer error");
  Token_Vec tokens = lexer_take_tokens(lexer);
  lexer_free(&lexer);

  Parser *parser = parser_new(tokens, source, len);
  parser_build_ast(parser);
  CHECK(!parser_has_errors(parser), "unexpected parser error");
  Ast *ast = parser_take_ast(parser);
  parser_free(&parser);

  char *buf = NULL;
  size_t size = 0;
  FILE *f = open_memstream(&buf, &size);
  ast_fprint(f, ast, source);
  fclose(f);

  CONTAINS(buf, "Program");
  CONTAINS(buf, "Function");
  CONTAINS(buf, "Identifier `add`"); // identifier text rendered from the source span
  CONTAINS(buf, "Identifier `a`");
  CONTAINS(buf, "Parameter");
  CONTAINS(buf, "Return");
  CONTAINS(buf, "Binary Plus"); // operator name printed for binary nodes
  CONTAINS(buf, ".."); // node spans printed as [start..end]

  free(buf);
  ast_free(&ast);

  if (failures) {
    fprintf(stderr, "%d ast_fprint test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("ast_fprint tests passed");
  return 0;
}
