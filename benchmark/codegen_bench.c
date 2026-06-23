#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "ast/ast.h"
#include "ast/parser.h"
#include "codegen/codegen.h"
#include "lexer/lexer.h"
#include "resolver/resolver.h"
#include "typechecker/typechecker.h"

#define TARGET_SECONDS 0.25

typedef struct {
    char *data;
    size_t len;
} Source;

typedef struct {
    size_t nodes;
    uint64_t checksum;
} CodegenResult;

static volatile uint64_t benchmark_sink;

static double now_seconds(void) {
  struct timespec time;
  if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) {
    perror("clock_gettime");
    exit(1);
  }
  return (double)time.tv_sec + (double)time.tv_nsec / 1e9;
}

static const char *base_name(const char *path) {
  const char *slash = strrchr(path, '/');
  return slash ? slash + 1 : path;
}

static Source read_source(const char *path) {
  FILE *file = fopen(path, "rb");
  if (file == NULL) {
    perror(path);
    exit(1);
  }
  if (fseek(file, 0, SEEK_END) != 0) {
    perror(path);
    exit(1);
  }
  const long size = ftell(file);
  if (size < 0) {
    perror(path);
    exit(1);
  }
  rewind(file);

  char *data = malloc((size_t)size);
  if (data == NULL) {
    fprintf(stderr, "fatal: out of memory\n");
    exit(1);
  }
  if (fread(data, 1, (size_t)size, file) != (size_t)size) {
    fprintf(stderr, "failed to read %s\n", path);
    exit(1);
  }
  fclose(file);
  return (Source){data, (size_t)size};
}

static Token_Vec lex(const Source *source) {
  Lexer *lexer = lexer_new(source->data, source->len);
  lexer_scan_tokens(lexer);
  if (lexer_has_errors(lexer)) {
    lexer_log_errors(lexer);
    lexer_free(&lexer);
    exit(1);
  }
  Token_Vec tokens = lexer_take_tokens(lexer);
  lexer_free(&lexer);
  return tokens;
}

// Parse, resolve and type-check once; the codegen bench reuses this checked AST across iterations
// (codegen only reads the AST, so re-emitting is idempotent). Corpus resolver/type diagnostics are
// expected and ignored: codegen degrades gracefully, and we measure throughput, not validity.
static Ast *build_checked_ast(const Source *source, const Token_Vec *tokens) {
  Token_Vec copy = Token_Vec_init();
  if (!Token_Vec_reserve(&copy, tokens->len)) {
    fprintf(stderr, "fatal: out of memory\n");
    exit(1);
  }
  memcpy(copy.data, tokens->data, tokens->len * sizeof *tokens->data);
  copy.len = tokens->len;

  Parser *parser = parser_new(copy, source->data, source->len);
  parser_build_ast(parser);
  if (parser_has_errors(parser)) {
    parser_log_errors(parser);
    parser_free(&parser);
    exit(1);
  }
  Ast *ast = parser_take_ast(parser);
  parser_free(&parser);

  Resolver *resolver = resolver_new(ast, source->data, source->len);
  resolver_resolve(resolver);
  ast = resolver_take_ast(resolver);
  resolver_free(&resolver);

  TypeChecker *tc = typechecker_new(ast, source->data, source->len);
  typechecker_check(tc);
  ast = typechecker_take_ast(tc);
  typechecker_free(&tc);
  return ast;
}

// One codegen pass over the (reused) checked AST, emitting to a sink. Ownership is reclaimed so
// the AST survives the pass.
static CodegenResult codegen_pass(Ast *ast, const Source *source, FILE *sink) {
  Codegen *codegen = codegen_new(ast, source->data, source->len);
  codegen_emit(codegen, sink);
  Ast *out = codegen_take_ast(codegen);
  codegen_free(&codegen);
  return (CodegenResult){
      .nodes = out->nodes.len,
      .checksum = (uint64_t)out->nodes.len ^ ((uint64_t)out->type_pool.len << 32),
  };
}

static size_t iteration_count(Ast *ast, const Source *source, FILE *sink) {
  const double start = now_seconds();
  const CodegenResult result = codegen_pass(ast, source, sink);
  const double elapsed = now_seconds() - start;
  benchmark_sink ^= result.checksum;
  if (elapsed <= 0.0)
    return 100;
  size_t iterations = (size_t)(TARGET_SECONDS / elapsed);
  if (iterations < 3)
    iterations = 3;
  if (iterations > 10000)
    iterations = 10000;
  return iterations;
}

static void run_source(const char *name, Source source) {
  Token_Vec tokens = lex(&source);
  Ast *ast = build_checked_ast(&source, &tokens);

  FILE *sink = fopen("/dev/null", "wb"); // measure lowering throughput, not disk I/O
  if (sink == NULL) {
    perror("/dev/null");
    exit(1);
  }

  const CodegenResult sample = codegen_pass(ast, &source, sink);
  const size_t iterations = iteration_count(ast, &source, sink);

  const double start = now_seconds();
  uint64_t checksum = 0;
  for (size_t i = 0; i < iterations; i++)
    checksum ^= codegen_pass(ast, &source, sink).checksum + i;
  const double elapsed = now_seconds() - start;
  benchmark_sink ^= checksum;

  const double bytes = (double)source.len * (double)iterations;
  const double nodes = (double)sample.nodes * (double)iterations;
  const double mb_per_second = bytes / elapsed / 1e6;
  const double ns_per_node = elapsed * 1e9 / nodes;
  const double mnodes_per_second = nodes / elapsed / 1e6;
  const double bytes_per_node = (double)source.len / (double)sample.nodes;

  printf(
      "%-20s %12zu %10.2f %10.2f %10.2f %10.2f\n", name, sample.nodes, mb_per_second, ns_per_node, mnodes_per_second,
      bytes_per_node);
  fclose(sink);
  ast_free(&ast);
  VEC_DEINIT(tokens);
  free(source.data);
}

int main(void) {
  static const char *const corpus[] = {
      "benchmark/files/lexer.spc",
      "benchmark/files/methods.spc",
  };

  printf(
      "%-20s %12s %10s %10s %10s %10s\n", "Benchmark", "Nodes", "MB/s", "ns/node", "Mnode/s", "byte/node");
  for (size_t i = 0; i < sizeof corpus / sizeof corpus[0]; i++)
    run_source(base_name(corpus[i]), read_source(corpus[i]));

  return benchmark_sink == UINT64_MAX;
}
