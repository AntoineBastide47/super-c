#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "lexer/lexer.h"
#include "lexer/token.h"

#define TARGET_SECONDS 0.25

typedef struct {
    char *data;
    size_t len;
} Source;

typedef struct {
    size_t token_cap;
    size_t token_len;
    uint64_t checksum;
} ScanResult;

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

static ScanResult scan(const Source *source) {
  Lexer *lexer = lexer_new(source->data, source->len);
  lexer_scan_tokens(lexer);
  if (lexer_has_errors(lexer)) {
    lexer_log_errors(lexer);
    lexer_free(&lexer);
    exit(1);
  }

  Token_Vec tokens = lexer_take_tokens(lexer);
  uint64_t checksum = tokens.len;
  if (tokens.len > 0) {
    checksum ^= tokens.data[0];
    checksum ^= tokens.data[tokens.len - 1];
  }

  const ScanResult result = {
      .token_cap = tokens.cap,
      .token_len = tokens.len,
      .checksum = checksum,
  };
  VEC_DEINIT(tokens);
  lexer_free(&lexer);
  return result;
}

static size_t iteration_count(const Source *source) {
  const double start = now_seconds();
  const ScanResult result = scan(source);
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
  const ScanResult sample = scan(&source);
  const size_t iterations = iteration_count(&source);

  const double start = now_seconds();
  uint64_t checksum = 0;
  for (size_t i = 0; i < iterations; i++)
    checksum ^= scan(&source).checksum + i;
  const double elapsed = now_seconds() - start;
  benchmark_sink ^= checksum;

  const double bytes = (double)source.len * (double)iterations;
  const double tokens = (double)sample.token_len * (double)iterations;
  const double mb_per_second = bytes / elapsed / 1e6;
  const double ns_per_token = elapsed * 1e9 / tokens;
  const double mtokens_per_second = tokens / elapsed / 1e6;
  const double bytes_per_token = (double)source.len / (double)sample.token_len;

  printf(
      "%-20s %12zu %12zu %10.2f %10.2f %10.2f %10.2f\n", name, sample.token_cap, sample.token_len, mb_per_second,
      ns_per_token, mtokens_per_second, bytes_per_token);
  free(source.data);
}

int main(void) {
  static const char *const corpus[] = {
      "benchmark/files/lexer.spc",
  };

  printf(
      "%-20s %12s %12s %10s %10s %10s %10s\n", "Benchmark", "Tokens Cap", "Tokens Len", "MB/s", "ns/tok", "Mtok/s",
      "byte/tok");
  for (size_t i = 0; i < sizeof corpus / sizeof corpus[0]; i++)
    run_source(base_name(corpus[i]), read_source(corpus[i]));

  return benchmark_sink == UINT64_MAX;
}
