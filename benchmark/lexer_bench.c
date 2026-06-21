#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "lexer/lexer.h"
#include "lexer/token.h"

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

static void run_benchmark(const Benchmark *benchmark) {
  const Source source = repeat_source(benchmark->snippet);
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
      "%-20s %12zu %12zu %10.2f %10.2f %10.2f %10.2f\n", benchmark->name, sample.token_cap, sample.token_len,
      mb_per_second, ns_per_token, mtokens_per_second, bytes_per_token);
  free(source.data);
}

int main(void) {
  static const Benchmark benchmarks[] = {
      {
          "keywords",
          "as break case const continue defer else enum extern false fn for if impl in let match move mut new "
          "null return self Self struct trait true type unsafe where while\n",
      },
      {
          "identifiers",
          "a value counter_123 current_value write_all File HTTPServer point2d _ temporary_result "
          "very_long_identifier_name_with_multiple_segments\n",
      },
      {
          "declarations",
          "let mut counter_123: i64 = current_value;\n"
          "const limit_value: usize = 1_000;\n"
          "fn increment(value: i64) -> i64 { return value + 1; }\n",
      },
      {
          "operators",
          "a+b-c*d/e%f; a==b; a!=b; a<b; a<=b; a>b; a>=b; "
          "a&b|c^d; a&&b||c; a<<b; a>>b; "
          "a+=b; a-=b; a*=b; a/=b; a%=b; a&=b; a|=b; a^=b; a<<=b; a>>=b; "
          "a..b; a..=b; path::item; ptr->field; arm=>value; value??fallback; value?;\n",
      },
      {
          "numbers",
          "0 0123 42 1_000_000 0xCAFE_BABE 0b1010_0110 0o755 "
          "1. 3.14159265 123.456_789 1e9 1e-9 1.25e+10;\n",
      },
      {
          "text-literals",
          "\"plain UTF-8 λ 😀\" \"escaped\\n\\t\\xFF\\u{1F600}\" "
          "'a' '\\n' '\\x41' '\\u{03BB}' b'A' b'\\n' b'\\xFF' "
          "r\"C:\\Users\\name\\file.txt\" r#\"contains \"quotes\"\"# r##\"line one\nline \"# two\"##;\n",
      },
      {
          "comments-skipped",
          "let value = 42; // line comment λ\n"
          "/* outer comment /* nested comment */ outer continues */ "
          "value += 1; /** documentation */ value;\n",
      },
      {
          "mixed-source",
          "struct Point { x: f64, y: f64 }\n"
          "fn distance(a: *const Point, b: *const Point) -> f64 {\n"
          "  let dx = a->x - b->x;\n"
          "  let dy = a->y - b->y;\n"
          "  return sqrt(dx * dx + dy * dy);\n"
          "}\n"
          "// construct a point\n"
          "let origin = Point { x: 0.0, y: 0.0 };\n",
      },
  };

  printf(
      "%-20s %12s %12s %10s %10s %10s %10s\n", "Benchmark", "Tokens Cap", "Tokens Len", "MB/s", "ns/tok", "Mtok/s",
      "byte/tok");
  for (size_t i = 0; i < sizeof benchmarks / sizeof benchmarks[0]; i++)
    run_benchmark(&benchmarks[i]);

  return benchmark_sink == UINT64_MAX;
}
