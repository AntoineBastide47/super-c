#ifndef TEST_HARNESS_H
#define TEST_HARNESS_H

// The Makefile compiles with strict -D_POSIX_C_SOURCE=200809L, which on macOS hides the BSD
// extensions mkdtemp/mkstemp/openpty the behavioral drivers need; re-enable the platform layer
// before any system header is pulled in. (Tests include this header first.)
#if defined(__APPLE__)
#  define _DARWIN_C_SOURCE
#elif !defined(_DEFAULT_SOURCE)
#  define _DEFAULT_SOURCE
#endif

// Shared test scaffolding: assertion macros, the lex->parse->resolve->typecheck->codegen
// pipeline drivers (so each test file stops duplicating the boilerplate), and the behavioral
// driver that compiles generated C with the sanitizing toolchain and runs it. Header-only, so
// the Makefile's tests/*_test.c glob needs no change; every entity is `static` and tagged
// TH_UNUSED so a test that uses only part of the API still builds clean under -Wall -Werror.
//
// Built dev profile (NDEBUG undefined), so *_take_errors is available. The NDEBUG-only
// ast_fprint lane (*_rtest.c) does NOT include this header.

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include "ast/ast.h"
#include "ast/parser.h"
#include "codegen/codegen.h"
#include "lexer/lexer.h"
#include "module/loader.h"
#include "resolver/resolver.h"
#include "typechecker/typechecker.h"

// The std prelude (str / String / SCslice) is auto-imported into every compiled snippet, exactly as the
// REPL/CLI do. The Makefile bakes in the absolute path; fall back to a repo-root-relative "std".
#ifndef SUPERC_STD_DIR
#  define SUPERC_STD_DIR "std"
#endif

#if defined(__GNUC__) || defined(__clang__)
#  define TH_UNUSED __attribute__((unused))
#else
#  define TH_UNUSED
#endif

static int failures TH_UNUSED;

// file:line + message, bumps `failures`. The whole suite's hard-assert primitive.
#define CHECK(condition, ...)                                                                                          \
  do {                                                                                                                 \
    if (!(condition)) {                                                                                                \
      fprintf(stderr, "%s:%d: ", __FILE__, __LINE__);                                                                  \
      fprintf(stderr, __VA_ARGS__);                                                                                    \
      fputc('\n', stderr);                                                                                             \
      failures++;                                                                                                      \
    }                                                                                                                  \
  } while (0)

// A documented expected-failure: prints the discrepancy but does NOT fail the suite. Used to
// pin known compiler bugs the harness surfaces, so re-enabling is a one-word edit once fixed.
#define XFAIL(condition, ...)                                                                                          \
  do {                                                                                                                 \
    if (!(condition)) {                                                                                                \
      fprintf(stderr, "[KNOWN-BUG] %s:%d: ", __FILE__, __LINE__);                                                      \
      fprintf(stderr, __VA_ARGS__);                                                                                    \
      fputc('\n', stderr);                                                                                             \
    }                                                                                                                  \
  } while (0)

#define CHECK_STR_CONTAINS(hay, needle)                                                                                \
  CHECK(strstr((hay), (needle)) != NULL, "expected to contain '%s':\n%s", (needle), (hay))
#define CHECK_STR_ABSENT(hay, needle)                                                                                  \
  CHECK(strstr((hay), (needle)) == NULL, "expected to NOT contain '%s':\n%s", (needle), (hay))
#define CHECK_STR_EQ(a, b) CHECK(strcmp((a), (b)) == 0, "expected '%s' == '%s'", (a), (b))
#define CHECK_EQ_U32(a, b)                                                                                             \
  do {                                                                                                                 \
    const uint32_t th_a_ = (uint32_t)(a), th_b_ = (uint32_t)(b);                                                       \
    CHECK(th_a_ == th_b_, "expected %u == %u", th_a_, th_b_);                                                          \
  } while (0)

TH_UNUSED static void free_errors(String_Vec *errors) {
  for (size_t i = 0; i < errors->len; i++)
    free(errors->data[i]);
  VEC_DEINIT_REF(errors);
}

typedef enum { ST_PARSE, ST_RESOLVE, ST_TYPECHECK, ST_CODEGEN } Stage;

TH_UNUSED static const char *sc_stage_name(const Stage s) {
  switch (s) {
    case ST_PARSE: return "parser";
    case ST_RESOLVE: return "resolver";
    case ST_TYPECHECK: return "typechecker";
    case ST_CODEGEN: return "codegen";
  }
  return "?";
}

typedef struct {
    Ast *ast;        // owned by the caller (ast_free); NULL if lex/parse failed
    char *code;      // codegen output (caller frees); NULL unless ST_CODEGEN reached without earlier error
    size_t errors;   // error count from the FIRST stage that erred (0 = clean through `stop`)
    Stage err_stage; // which stage produced `errors`
    char first[256]; // that stage's first message
} ScResult;

// Run the pipeline lex..`stop`, halting at the first stage that errors. The AST (when one
// exists) is always handed back for the caller to free, even on error.
TH_UNUSED static ScResult sc_compile(const char *name, const char *source, const Stage stop) {
  (void)name;
  ScResult r = {0};
  const size_t len = strlen(source);

  Lexer *lexer = lexer_new(source, len);
  lexer_scan_tokens(lexer);
  if (lexer_has_errors(lexer)) {
    String_Vec e = lexer_take_errors(lexer);
    r.errors = e.len;
    r.err_stage = ST_PARSE; // lexer errors surface as a parse-stage failure to callers
    snprintf(r.first, sizeof r.first, "%s", e.data[0]);
    free_errors(&e);
    lexer_free(&lexer);
    return r;
  }
  Token_Vec tokens = lexer_take_tokens(lexer);
  lexer_free(&lexer);

  Parser *parser = parser_new(tokens, source, len);
  parser_build_ast(parser);
  if (parser_has_errors(parser)) {
    String_Vec e = parser_take_errors(parser);
    r.errors = e.len;
    r.err_stage = ST_PARSE;
    snprintf(r.first, sizeof r.first, "%s", e.data[0]);
    free_errors(&e);
    parser_free(&parser);
    return r;
  }
  r.ast = parser_take_ast(parser);
  parser_free(&parser);
  if (stop == ST_PARSE)
    return r;

  // Auto-import the std prelude: a fresh package per call (cheap, no shared state). The user Ast stays
  // standalone with module == pp->count, so its own nodes resolve to it and prelude refs go through pp.
  Package *pp = package_prelude_only(SUPERC_STD_DIR);
  for (size_t i = 0; i < pp->count; i++) {
    Resolver *pr = resolver_new(pp->modules[i].ast, pp->modules[i].source, pp->modules[i].source_len, pp);
    resolver_resolve(pr);
    pp->modules[i].ast = resolver_take_ast(pr);
    resolver_free(&pr);
  }
  r.ast->module = (ModuleId)pp->count;

  Resolver *resolver = resolver_new(r.ast, source, len, pp);
  resolver_resolve(resolver);
  if (resolver_has_errors(resolver)) {
    String_Vec e = resolver_take_errors(resolver);
    r.errors = e.len;
    r.err_stage = ST_RESOLVE;
    snprintf(r.first, sizeof r.first, "%s", e.data[0]);
    free_errors(&e);
  }
  r.ast = resolver_take_ast(resolver);
  resolver_free(&resolver);
  if (r.errors || stop == ST_RESOLVE) {
    package_free(&pp);
    return r;
  }

  for (size_t i = 0; i < pp->count; i++) {
    TypeChecker *pt = typechecker_new(pp->modules[i].ast, pp->modules[i].source, pp->modules[i].source_len, pp);
    typechecker_check(pt);
    pp->modules[i].ast = typechecker_take_ast(pt);
    typechecker_free(&pt);
  }
  TypeChecker *tc = typechecker_new(r.ast, source, len, pp);
  typechecker_check(tc);
  if (typechecker_has_errors(tc)) {
    String_Vec e = typechecker_take_errors(tc);
    r.errors = e.len;
    r.err_stage = ST_TYPECHECK;
    snprintf(r.first, sizeof r.first, "%s", e.data[0]);
    free_errors(&e);
  }
  r.ast = typechecker_take_ast(tc);
  typechecker_free(&tc);
  if (r.errors || stop == ST_TYPECHECK) {
    package_free(&pp);
    return r;
  }
  package_propagate_instances(pp, r.ast); // owners emit cross-module generic instances (matches the CLI)

  char *buf = NULL;
  size_t size = 0;
  FILE *f = open_memstream(&buf, &size);
  // Emit the prelude modules + the user snippet as one phase-interleaved unit (mutually dependent types
  // like str <-> String resolve: all forwards, then all types, then all bodies).
  const size_t total = pp->count + 1;
  Codegen **cs = (Codegen **)malloc(total * sizeof *cs);
  for (size_t i = 0; i < pp->count; i++)
    cs[i] = codegen_new(pp->modules[i].ast, pp->modules[i].source, pp->modules[i].source_len, pp);
  cs[pp->count] = codegen_new(r.ast, source, len, pp);
  codegen_emit_unit(cs, total, f);
  fclose(f);
  String_Vec e = codegen_take_errors(cs[pp->count]); // user-module diagnostics
  if (e.len) {
    r.errors = e.len;
    r.err_stage = ST_CODEGEN;
    snprintf(r.first, sizeof r.first, "%s", e.data[0]);
  }
  free_errors(&e);
  for (size_t i = 0; i < pp->count; i++) {
    pp->modules[i].ast = codegen_take_ast(cs[i]);
    codegen_free(&cs[i]);
  }
  r.ast = codegen_take_ast(cs[pp->count]);
  codegen_free(&cs[pp->count]);
  free(cs);
  r.code = buf;
  package_free(&pp);
  return r;
}

// Positive-path drivers: return the AST after the named stage, or NULL after a CHECK failure if
// an unexpected error occurred earlier. The AST is owned by the caller (ast_free).
TH_UNUSED static Ast *sc_parse(const char *name, const char *source) {
  ScResult r = sc_compile(name, source, ST_PARSE);
  if (r.errors) {
    CHECK(false, "%s: unexpected %s error: %s", name, sc_stage_name(r.err_stage), r.first);
    ast_free(&r.ast);
    return NULL;
  }
  return r.ast;
}

TH_UNUSED static Ast *sc_resolve(const char *name, const char *source) {
  ScResult r = sc_compile(name, source, ST_RESOLVE);
  if (r.errors) {
    CHECK(false, "%s: unexpected %s error: %s", name, sc_stage_name(r.err_stage), r.first);
    ast_free(&r.ast);
    return NULL;
  }
  return r.ast;
}

TH_UNUSED static Ast *sc_typecheck(const char *name, const char *source) {
  ScResult r = sc_compile(name, source, ST_TYPECHECK);
  if (r.errors) {
    CHECK(false, "%s: unexpected %s error: %s", name, sc_stage_name(r.err_stage), r.first);
    ast_free(&r.ast);
    return NULL;
  }
  return r.ast;
}

// Negative-path driver: run up to `stage` and report the error count there; copy the first
// message into `first`. Frees any produced AST/code.
TH_UNUSED static size_t sc_stage_errors(const char *name, const char *source, const Stage stage, char *first,
                                        const size_t cap) {
  ScResult r = sc_compile(name, source, stage);
  if (first && cap)
    snprintf(first, cap, "%s", r.first);
  ast_free(&r.ast);
  free(r.code);
  return r.errors;
}

// Full pipeline to codegen. Returns the emitted C (caller frees) and the codegen-stage
// diagnostic count via *n_err. An earlier-stage error is CHECK-reported and yields NULL.
TH_UNUSED static char *sc_codegen(const char *name, const char *source, size_t *n_err, char *first, const size_t cap) {
  ScResult r = sc_compile(name, source, ST_CODEGEN);
  if (r.errors && r.err_stage != ST_CODEGEN) {
    CHECK(false, "%s: unexpected %s error: %s", name, sc_stage_name(r.err_stage), r.first);
    ast_free(&r.ast);
    free(r.code);
    if (n_err)
      *n_err = 0;
    return NULL;
  }
  if (n_err)
    *n_err = r.errors;
  if (first && cap)
    snprintf(first, cap, "%s", r.first);
  ast_free(&r.ast);
  return r.code;
}

// Behavioral soundness driver: write `c_src` to a temp dir, compile it warning-clean under the
// sanitizers, run it. Returns 0 with stdout in `out` and the process exit code in *exit_code;
// returns -1 (compile failed) with the compiler's stderr copied into `out`.
TH_UNUSED static int sc_compile_and_run(const char *c_src, char *out, const size_t out_cap, int *exit_code) {
  char dir[] = "/tmp/scrunXXXXXX";
  if (!mkdtemp(dir))
    return -1;
  char cpath[64], bpath[64], epath[64], cmd[512];
  snprintf(cpath, sizeof cpath, "%s/p.c", dir);
  snprintf(bpath, sizeof bpath, "%s/p", dir);
  snprintf(epath, sizeof epath, "%s/e", dir);

  FILE *cf = fopen(cpath, "w");
  if (!cf) {
    rmdir(dir);
    return -1;
  }
  fputs(c_src, cf);
  fclose(cf);

  snprintf(
      cmd, sizeof cmd, "cc -std=c11 -Wall -Wextra -Werror -fsanitize=undefined,address %s -o %s 2>%s", cpath, bpath,
      epath);
  const int crc = system(cmd);

  int rc = 0;
  if (crc != 0) {
    FILE *ef = fopen(epath, "r");
    size_t n = (ef && out && out_cap) ? fread(out, 1, out_cap - 1, ef) : 0;
    if (out && out_cap)
      out[n] = '\0';
    if (ef)
      fclose(ef);
    rc = -1;
  } else {
    FILE *p = popen(bpath, "r");
    if (!p) {
      rc = -1;
    } else {
      size_t n = (out && out_cap) ? fread(out, 1, out_cap - 1, p) : 0;
      if (out && out_cap)
        out[n] = '\0';
      const int st = pclose(p);
      if (exit_code)
        *exit_code = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    }
  }

  unlink(cpath);
  unlink(bpath);
  unlink(epath);
  rmdir(dir);
  return rc;
}

// End-to-end: transpile `sc_src`, compile+run the C, assert the exit code and (when non-NULL)
// the exact stdout. The single strongest soundness assertion in the suite.
TH_UNUSED static void sc_run_program(const char *name, const char *sc_src, const int expected_exit,
                                     const char *expected_stdout) {
  size_t n_err = 0;
  char first[256];
  char *code = sc_codegen(name, sc_src, &n_err, first, sizeof first);
  if (!code)
    return; // earlier-stage failure already reported
  CHECK(n_err == 0, "%s: unexpected codegen error: %s", name, first);
  if (n_err) {
    free(code);
    return;
  }
  char out[8192];
  int ec = -1;
  if (sc_compile_and_run(code, out, sizeof out, &ec) != 0) {
    CHECK(false, "%s: generated C failed to compile:\n%s\n----- generated C -----\n%s", name, out, code);
    free(code);
    return;
  }
  CHECK(ec == expected_exit, "%s: expected exit %d, got %d\n----- generated C -----\n%s", name, expected_exit, ec, code);
  if (expected_stdout)
    CHECK(strcmp(out, expected_stdout) == 0, "%s: expected stdout [%s], got [%s]", name, expected_stdout, out);
  free(code);
}

// Arena scan helpers: the whole AST lives in one node vector in creation order, so locating
// nodes is a linear filter, no tree walk. `n` is 0-based among matches.
TH_UNUSED static NodeId th_nth_kind(const Ast *a, const NodeKind kind, size_t n) {
  for (NodeId id = 1; id < (NodeId)a->nodes.len; id++)
    if (ast_at_const(a, id)->kind == kind && n-- == 0)
      return id;
  return NODE_NONE;
}

TH_UNUSED static bool th_ident_is(const Ast *a, const char *src, const NodeId id, const char *name) {
  const Node *n = ast_at_const(a, id);
  if (n->kind != NODE_IDENTIFIER)
    return false;
  const uint32_t s = n->as.name.text.start, e = n->as.name.text.end;
  const size_t l = strlen(name);
  return (size_t)(e - s) == l && memcmp(src + s, name, l) == 0;
}

#endif // TEST_HARNESS_H
