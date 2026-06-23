#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#include "ast/ast.h"
#include "ast/parser.h"
#include "codegen/codegen.h"
#include "lexer/lexer.h"
#include "lexer/token.h"
#include "resolver/resolver.h"
#include "typechecker/typechecker.h"

// Set by the Makefile (-DBIN_NAME='"$(BIN)"'); fall back for standalone builds.
#ifndef BIN_NAME
  #define BIN_NAME "super-c"
#endif

// Returns 0 on success, 1 if any stage reported errors or the output file could not be opened.
static int run(const char *source, const size_t len, const char *out_path) {
  Lexer *lexer = lexer_new(source, len);
  lexer_scan_tokens(lexer);
  ERRORS_CHECK(lexer);

  Parser *parser = parser_new(lexer_take_tokens(lexer), source, len);
  lexer_free(&lexer);
  parser_build_ast(parser);
  ERRORS_CHECK(parser);

  Resolver *resolver = resolver_new(parser_take_ast(parser), source, len);
  parser_free(&parser);
  resolver_resolve(resolver);
  ERRORS_CHECK(resolver);

  TypeChecker *typechecker = typechecker_new(resolver_take_ast(resolver), source, len);
  resolver_free(&resolver);
  typechecker_check(typechecker);
  ERRORS_CHECK(typechecker);

  FILE *out = fopen(out_path, "w");
  if (!out) {
    typechecker_free(&typechecker);
    perror(out_path);
    return 1;
  }

  Codegen *codegen = codegen_new(typechecker_take_ast(typechecker), source, len);
  typechecker_free(&typechecker);
  codegen_emit(codegen, out);
  fclose(out);
  ERRORS_CHECK(codegen);

  codegen_free(&codegen);
  return 0;
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

// Derive the C output path from the input: replace a trailing extension with ".c", appending it
// if there is none. The result is heap-allocated and must be freed by the caller.
static char *derive_out_path(const char *path) {
  const char *const slash = strrchr(path, '/');
  const char *const base = slash ? slash + 1 : path;
  const char *const dot = strrchr(base, '.');
  const size_t stem = dot ? (size_t)(dot - path) : strlen(path);
  char *const out = malloc(stem + 3);
  if (!out)
    return NULL;
  memcpy(out, path, stem);
  memcpy(out + stem, ".c", 3);
  return out;
}

static int run_file(const char *path) {
  size_t size = 0;
  char *const source = read_to_string(path, &size);
  if (!source) {
    perror(path);
    return 1;
  }
  char *const out_path = derive_out_path(path);
  if (!out_path) {
    fprintf(stderr, "fatal: out of memory\n");
    free(source);
    return 1;
  }
  const int rc = run(source, size, out_path);
  free(out_path);
  free(source);
  return rc;
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

    run(line, (size_t)read, "out.c");
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
