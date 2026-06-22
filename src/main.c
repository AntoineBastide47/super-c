#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#include "ast/ast.h"
#include "ast/parser.h"
#include "lexer/lexer.h"
#include "lexer/token.h"

// Set by the Makefile (-DBIN_NAME='"$(BIN)"'); fall back for standalone builds.
#ifndef BIN_NAME
  #define BIN_NAME "super-c"
#endif

static void run(const char *source, const size_t len) {
  Lexer *lexer = lexer_new(source, len);
  lexer_scan_tokens(lexer);
  ERRORS_CHECK(lexer);

  Parser *parser = parser_new(lexer_take_tokens(lexer), source, len);
  lexer_free(&lexer);
  parser_build_ast(parser);
  ERRORS_CHECK(parser);

  Ast *ast = parser_take_ast(parser);
  ast_fprint(stdout, ast, source);
  ast_free(&ast);
  parser_free(&parser);
}

// Read a whole file into a NUL-terminated, heap-allocated buffer.
static char *read_to_string(const char *path, size_t *size) {
  FILE *const f = fopen(path, "rb");
  if (!f)
    return NULL;

  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    return NULL;
  }
  const long s = ftell(f);
  rewind(f);
  if (s < 0) {
    fclose(f);
    return NULL;
  }

  *size = (size_t)s;

  char *const buf = malloc(*size + 1);
  if (!buf) {
    fclose(f);
    return NULL;
  }

  const size_t n = fread(buf, 1, *size, f);
  if (n != *size && ferror(f)) {
    free(buf);
    fclose(f);
    return NULL;
  }

  fclose(f);
  buf[n] = '\0';
  *size = n;
  return buf;
}

static int run_file(const char *path) {
  size_t size = 0;
  char *const source = read_to_string(path, &size);
  if (!source) {
    perror(path);
    return 1;
  }
  run(source, size);
  free(source);
  return 0;
}

static int run_prompt(void) {
  char *line = NULL;
  size_t cap = 0;

  for (;;) {
    printf("> ");
    fflush(stdout); // needed because printf does not auto-flush

    ssize_t read = getline(&line, &cap, stdin);
    if (read <= 0)
      break;

    // trim trailing \r and \n
    while (read > 0 && (line[read - 1] == '\n' || line[read - 1] == '\r')) {
      line[--read] = '\0';
    }

    if (read == 4 && memcmp(line, "exit", 4) == 0)
      break;

    run(line, (size_t)read);
  }

  free(line);
  return 0;
}

int main(const int argc, char **argv) {
  if (argc > 2) {
    printf("Usage: %s [<path/to/script>]\n", BIN_NAME);
    return 1;
  } else if (argc == 2) {
    return run_file(argv[1]);
  } else {
    return run_prompt();
  }
}
