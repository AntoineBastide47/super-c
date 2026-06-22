#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "ast/parser.h"
#include "lexer/lexer.h"

#define SOURCE_BYTES (1024u * 1024u)
#define TARGET_SECONDS 0.25

typedef struct {
  const char *name;
  const char *snippet;
} Benchmark;

typedef struct {
  char *data;
  size_t len;
} Source;

typedef struct {
  size_t node_cap;
  size_t node_len;
  uint64_t checksum;
} ParseResult;

static volatile uint64_t benchmark_sink;

static double now_seconds(void) {
  struct timespec time;
  if (clock_gettime(CLOCK_MONOTONIC, &time) != 0) {
    perror("clock_gettime");
    exit(1);
  }
  return (double)time.tv_sec + (double)time.tv_nsec / 1e9;
}

static Source repeat_source(const char *snippet) {
  const size_t snippet_len = strlen(snippet);
  const size_t repetitions = (SOURCE_BYTES + snippet_len - 1) / snippet_len;
  const size_t len = repetitions * snippet_len;
  char *data = malloc(len);
  if (data == NULL) {
    fprintf(stderr, "fatal: out of memory\n");
    exit(1);
  }
  for (size_t i = 0; i < repetitions; i++)
    memcpy(data + i * snippet_len, snippet, snippet_len);
  return (Source){data, len};
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

static Token_Vec copy_tokens(const Token_Vec *source) {
  Token_Vec copy = Token_Vec_init();
  if (!Token_Vec_reserve(&copy, source->len)) {
    fprintf(stderr, "fatal: out of memory\n");
    exit(1);
  }
  memcpy(copy.data, source->data, source->len * sizeof *source->data);
  copy.len = source->len;
  return copy;
}

static ParseResult parse(const Source *source, const Token_Vec *tokens) {
  Parser *parser = parser_new(copy_tokens(tokens), source->data, source->len);
  parser_build_ast(parser);
  if (parser_has_errors(parser)) {
    parser_log_errors(parser);
    parser_free(&parser);
    exit(1);
  }

  Ast *ast = parser_take_ast(parser);
  const ParseResult result = {
      .node_cap = ast->nodes.cap,
      .node_len = ast->nodes.len,
      .checksum = (uint64_t)ast->root ^ (uint64_t)ast->nodes.len ^ ((uint64_t)ast->children.len << 32),
  };
  ast_free(&ast);
  parser_free(&parser);
  return result;
}

static size_t iteration_count(const Source *source, const Token_Vec *tokens) {
  const double start = now_seconds();
  const ParseResult result = parse(source, tokens);
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
  const ParseResult sample = parse(&source, &tokens);
  const size_t iterations = iteration_count(&source, &tokens);

  const double start = now_seconds();
  uint64_t checksum = 0;
  for (size_t i = 0; i < iterations; i++)
    checksum ^= parse(&source, &tokens).checksum + i;
  const double elapsed = now_seconds() - start;
  benchmark_sink ^= checksum;

  const double bytes = (double)source.len * (double)iterations;
  const double nodes = (double)sample.node_len * (double)iterations;
  const double mb_per_second = bytes / elapsed / 1e6;
  const double ns_per_node = elapsed * 1e9 / nodes;
  const double mnodes_per_second = nodes / elapsed / 1e6;
  const double bytes_per_node = (double)source.len / (double)sample.node_len;

  printf(
      "%-20s %12zu %12zu %10.2f %10.2f %10.2f %10.2f\n", name, sample.node_cap, sample.node_len,
      mb_per_second, ns_per_node, mnodes_per_second, bytes_per_node);
  VEC_DEINIT(tokens);
  free(source.data);
}

static void run_benchmark(const Benchmark *benchmark) {
  run_source(benchmark->name, repeat_source(benchmark->snippet));
}

int main(void) {
  static const Benchmark benchmarks[] = {
      {
          "declarations",
          "struct Pair<T> { left: T, right: T, }\n"
          "enum Result<T, E> { Ok(T), Err { error: E }, }\n"
          "type Callback = fn(*const u8, []u8) -> int;\n"
          "const LIMIT: usize = 1_024;\n",
      },
      {
          "functions",
          "fn calculate<T>(left: T, right: T) -> int where T: Add + Copy {\n"
          "  let mut value: int = 1 + 2 * 3;\n"
          "  value += (left as int) << 2;\n"
          "  if (value > 10 && value != 20) { value -= 1; } else { value = 0; }\n"
          "  return value;\n"
          "}\n",
      },
      {
          "interfaces-extends",
          "interface Writer<T> { type Output; fn write(self: *mut Self, value: T) -> Self::Output; }\n"
          "extend<T> Buffer<T> as Writer<T> {\n"
          "  type Output = usize;\n"
          "  fn write(self: *mut Self, value: T) -> usize { self.len += 1; return self.len; }\n"
          "}\n",
      },
      {
          "control-flow",
          "fn process(values: []int) -> int {\n"
          "  let mut total: int = 0;\n"
          "  for value in values { defer release(value); total += value; }\n"
          "  while (total > 100) { total -= 1; }\n"
          "  return total;\n"
          "}\n",
      },
      {
          "switch-patterns",
          "fn classify(value: Result<int, Error>) -> int {\n"
          "  return switch value {\n"
          "    Ok(number) if number > 0 => number,\n"
          "    case '0'..='9' => 1,\n"
          "    Err { error: err } => 2,\n"
          "    _ => 0,\n"
          "  };\n"
          "}\n",
      },
  };

  printf(
      "%-20s %12s %12s %10s %10s %10s %10s\n", "Benchmark", "Nodes Cap", "Nodes Len", "MB/s", "ns/node",
      "Mnode/s", "byte/node");
  for (size_t i = 0; i < sizeof benchmarks / sizeof benchmarks[0]; i++)
    run_benchmark(&benchmarks[i]);
  run_source("lexer-file", read_source("benchmark/files/lexer.spc"));

  return benchmark_sink == UINT64_MAX;
}
