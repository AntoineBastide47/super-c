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

// `failures` is shared across threads in the OpenMP-parallelized tests (raii_gen, codegen_run), so bump it
// atomically there. Every non-OpenMP test compiles with _OPENMP undefined and gets a plain increment.
#ifdef _OPENMP
#  define TH_FAILURES_INC _Pragma("omp atomic") failures++
#else
#  define TH_FAILURES_INC failures++
#endif

// file:line + message, bumps `failures`. The whole suite's hard-assert primitive.
#define CHECK(condition, ...)                                                                                          \
  do {                                                                                                                 \
    if (!(condition)) {                                                                                                \
      fprintf(stderr, "%s:%d: ", __FILE__, __LINE__);                                                                  \
      fprintf(stderr, __VA_ARGS__);                                                                                    \
      fputc('\n', stderr);                                                                                             \
      TH_FAILURES_INC;                                                                                                 \
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
    Ast *ast;          // owned by the caller (ast_free); NULL if lex/parse failed
    char *code;        // concatenated codegen output (caller frees); NULL unless ST_CODEGEN reached cleanly
    char build_dir[64]; // temp dir holding the emitted multi-file build/ tree (caller rm -rf's it); "" if none
    size_t errors;     // error count from the FIRST stage that erred (0 = clean through `stop`)
    Stage err_stage;   // which stage produced `errors`
    char first[256];   // that stage's first message
} ScResult;

// Build path "<root>/build/<modpath, '::' -> '/'><ext>" (heap-allocated), mirroring the CLI's tree layout.
TH_UNUSED static char *th_modfile(const char *root, const char *modpath, const char *ext) {
  const size_t n = strlen(root) + sizeof "/build/" + strlen(modpath) + strlen(ext);
  char *const out = (char *)malloc(n);
  size_t at = (size_t)snprintf(out, n, "%s/build/", root);
  for (const char *s = modpath; *s; s++) {
    if (s[0] == ':' && s[1] == ':') { out[at++] = '/'; s++; }
    else out[at++] = *s;
  }
  memcpy(out + at, ext, strlen(ext) + 1);
  return out;
}

// Write `n` bytes to `path`, then append the same bytes to the open `concat` stream (for strstr inspection).
TH_UNUSED static void th_emit_file(const char *path, const char *buf, const size_t n, FILE *concat) {
  FILE *const f = fopen(path, "w");
  if (f) { fwrite(buf, 1, n, f); fclose(f); }
  if (concat) fwrite(buf, 1, n, concat);
}

// Recursively remove a temp build dir (no-op for an empty path).
TH_UNUSED static void th_rmtree(const char *dir) {
  if (!dir || !dir[0])
    return;
  char cmd[128];
  snprintf(cmd, sizeof cmd, "rm -rf %s", dir);
  if (system(cmd)) { /* best-effort cleanup */
  }
}

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

  // Append the user snippet as a real (non-prelude) `main` module, then emit the whole package as one
  // build/ tree -- the single, uniform compilation path (identical to the CLI; no separate single-TU
  // emitter). The user nodes were resolved with module == pp->count, exactly the index they land at here.
  const ModuleId uidx = (ModuleId)pp->count;
  if (pp->count == pp->cap) {
    pp->cap = pp->cap ? pp->cap * 2 : 8;
    pp->modules = (Module *)realloc(pp->modules, pp->cap * sizeof *pp->modules);
  }
  pp->modules[uidx] = (Module){0};
  pp->modules[uidx].path = strdup("main");
  pp->modules[uidx].source = strdup(source);
  pp->modules[uidx].source_len = len;
  pp->modules[uidx].ast = r.ast;
  pp->count++;

  char tmpl[] = "/tmp/scgenXXXXXX";
  char *const dir = mkdtemp(tmpl);
  char *catbuf = NULL;
  size_t catsz = 0;
  FILE *const cat = open_memstream(&catbuf, &catsz); // all .h + .c concatenated, for strstr inspection
  if (dir) {
    char mk[160];
    snprintf(mk, sizeof mk, "mkdir -p %s/build/__std", dir); // prelude is __std::*; user `main` at build/ root
    if (system(mk)) { /* ignore: a write failure surfaces as a later compile error */
    }
    char *const rt = th_modfile(dir, "super_rt", ".h");
    const char *const g0 = "#ifndef SUPER_RT_H\n#define SUPER_RT_H\n";
    const char *const g1 = "#endif\n";
    FILE *rf = fopen(rt, "w");
    if (rf) { fputs(g0, rf); fputs(SUPER_RT_INCLUDES, rf); fputs(g1, rf); fclose(rf); }
    fputs(g0, cat); // the runtime header (atomics shim, ...) is part of the inspectable `code` too
    fputs(SUPER_RT_INCLUDES, cat);
    fputs(g1, cat);
    free(rt);
  }
  for (size_t i = 0; i < pp->count; i++) {
    Codegen *c = codegen_new(pp->modules[i].ast, pp->modules[i].source, pp->modules[i].source_len, pp);
    codegen_set_multifile(c, true);
    char *hb = NULL, *cb = NULL;
    size_t hn = 0, cn = 0;
    FILE *hf = open_memstream(&hb, &hn);
    codegen_emit_header(c, hf);
    fclose(hf);
    FILE *cf = open_memstream(&cb, &cn);
    codegen_emit(c, cf);
    fclose(cf);
    if (dir) {
      char *hp = th_modfile(dir, pp->modules[i].path, ".h");
      char *cp = th_modfile(dir, pp->modules[i].path, ".c");
      th_emit_file(hp, hb, hn, cat);
      th_emit_file(cp, cb, cn, cat);
      free(hp);
      free(cp);
    }
    free(hb);
    free(cb);
    if (i == uidx) { // user-module codegen diagnostics
      String_Vec e = codegen_take_errors(c);
      if (e.len) {
        r.errors = e.len;
        r.err_stage = ST_CODEGEN;
        snprintf(r.first, sizeof r.first, "%s", e.data[0]);
      }
      free_errors(&e);
    }
    pp->modules[i].ast = codegen_take_ast(c);
    codegen_free(&c);
  }
  fclose(cat);
  r.code = catbuf;
  if (dir)
    snprintf(r.build_dir, sizeof r.build_dir, "%s", dir);
  // Hand the user AST back to the caller; detach it from the package so package_free won't double-free it.
  r.ast = pp->modules[uidx].ast;
  pp->modules[uidx].ast = NULL;
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
  th_rmtree(r.build_dir);
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
  th_rmtree(r.build_dir); // the strstr callers only need the concatenated `code`
  return r.code;
}

// Run a shell command, drain its stdout, and return its exit status (-1 if it didn't exit normally).
// Used for the cc compile/link steps instead of system(): on macOS system() serializes across threads
// (a process-wide lock), which would defeat OpenMP-parallelized tests -- popen() runs concurrently.
TH_UNUSED static int th_run_cmd(const char *cmd) {
  FILE *p = popen(cmd, "r");
  if (!p)
    return -1;
  char buf[4096];
  while (fread(buf, 1, sizeof buf, p) > 0) { /* discard stdout; the commands redirect stderr to a file */
  }
  const int st = pclose(p);
  return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

// Behavioral soundness driver: compile every .c in the already-emitted `build_dir` tree warning-clean
// under the sanitizers, link, and run it. Returns 0 with stdout in `out` and the process exit code in
// *exit_code; returns -1 (compile/link failed) with the compiler's stderr copied into `out`.
//
// Each .c is compiled to a content-addressed object in a shared cache: the prelude C is byte-identical
// across most snippets (only the user's `main.c` and any module emitting snippet-specific monomorphized
// instances vary), so those objects are compiled once and reused -- otherwise the unified multi-file path
// would re-parse the heavy runtime header in ~17 units per test. The generated #includes are relative, so
// each .c compiles standalone (no -I) and the cache key is just the .c's own bytes.
TH_UNUSED static int sc_run_built(const char *build_dir, char *out, const size_t out_cap, int *exit_code) {
  if (!build_dir || !build_dir[0])
    return -1;
  static bool cache_ready = false;
  if (!cache_ready) {
    if (system("mkdir -p /tmp/sc_ocache")) { /* a failure surfaces as a compile error below */
    }
    cache_ready = true;
  }
  char bpath[96], epath[96], findcmd[192];
  snprintf(bpath, sizeof bpath, "%s/p", build_dir);
  snprintf(epath, sizeof epath, "%s/e", build_dir);
  // A digest of every header in the tree, mixed into each object's cache key: a `.c` may be byte-identical
  // across runs yet include a changed prelude header (a new struct layout), so keying on the `.c` alone would
  // reuse a stale `.o` compiled against the old ABI. XOR of per-file FNV-1a is order-independent (find order
  // is not stable) and changes whenever any header changes.
  uint64_t hdr_digest = 0;
  snprintf(findcmd, sizeof findcmd, "find %s/build -name '*.h'", build_dir);
  FILE *hp = popen(findcmd, "r");
  if (hp) {
    char hline[512];
    while (fgets(hline, sizeof hline, hp)) {
      hline[strcspn(hline, "\n")] = '\0';
      if (!hline[0])
        continue;
      uint64_t fh = 1469598103934665603ULL;
      FILE *hf = fopen(hline, "rb");
      if (hf) {
        int ch;
        while ((ch = fgetc(hf)) != EOF) {
          fh ^= (uint64_t)(unsigned char)ch;
          fh *= 1099511628211ULL;
        }
        fclose(hf);
      }
      hdr_digest ^= fh;
    }
    pclose(hp);
  }
  snprintf(findcmd, sizeof findcmd, "find %s/build -name '*.c'", build_dir);
  FILE *lp = popen(findcmd, "r");
  if (!lp)
    return -1;
  char link[16384];
  size_t lat = 0;
  link[0] = '\0';
  char line[512];
  int rc = 0;
  while (fgets(line, sizeof line, lp)) {
    line[strcspn(line, "\n")] = '\0';
    if (!line[0])
      continue;
    uint64_t h = 1469598103934665603ULL ^ hdr_digest; // FNV-1a over the .c bytes, seeded by the header digest
    FILE *cf = fopen(line, "rb");
    if (cf) {
      int ch;
      while ((ch = fgetc(cf)) != EOF) {
        h ^= (uint64_t)(unsigned char)ch;
        h *= 1099511628211ULL;
      }
      fclose(cf);
    }
    char opath[96];
    snprintf(opath, sizeof opath, "/tmp/sc_ocache/%016llx.o", (unsigned long long)h);
    if (access(opath, F_OK) != 0) {
      // Compile to a per-build temp, then atomically rename into the shared cache. When several threads
      // (OpenMP-parallelized tests) or processes (`make -j`) build the byte-identical object at once,
      // last-writer-wins on identical content -- a half-written .o can never be read by a parallel linker.
      char tmpo[160], cc[1024];
      snprintf(tmpo, sizeof tmpo, "%s/cache.tmp.o", build_dir);
      // -Wno-unused-function: a snippet may define a private helper it never calls (in multi-file output
      // such a fn is `static`, so it would warn -- the old single-TU emitted user fns non-static). All
      // other warnings stay hard errors, alongside the UBSan/ASan instrumentation.
      snprintf(cc, sizeof cc,
               "cc -std=c11 -Wall -Wextra -Werror -Wno-unused-function -fsanitize=undefined,address -c '%s' -o '%s' "
               "2>>'%s'",
               line, tmpo, epath);
      if (th_run_cmd(cc) != 0) {
        rc = -1;
        break;
      }
      if (rename(tmpo, opath) != 0) { /* a lost publish surfaces as a later link error */
      }
    }
    lat += (size_t)snprintf(link + lat, lat < sizeof link ? sizeof link - lat : 0, " '%s'", opath);
  }
  pclose(lp);
  if (rc == 0) {
    char lcmd[16800];
    snprintf(lcmd, sizeof lcmd, "cc -fsanitize=undefined,address%s -o '%s' 2>>'%s'", link, bpath, epath);
    if (th_run_cmd(lcmd) != 0)
      rc = -1;
  }
  if (rc != 0) {
    FILE *ef = fopen(epath, "r");
    size_t n = (ef && out && out_cap) ? fread(out, 1, out_cap - 1, ef) : 0;
    if (out && out_cap)
      out[n] = '\0';
    if (ef)
      fclose(ef);
    return -1;
  }
  FILE *p = popen(bpath, "r");
  if (!p)
    return -1;
  size_t n = (out && out_cap) ? fread(out, 1, out_cap - 1, p) : 0;
  if (out && out_cap)
    out[n] = '\0';
  const int st = pclose(p);
  if (exit_code) // a signal-killed program reports the shell convention 128+sig (SIGABRT -> 134)
    *exit_code = WIFEXITED(st) ? WEXITSTATUS(st) : WIFSIGNALED(st) ? 128 + WTERMSIG(st) : -1;
  return 0;
}

// End-to-end: transpile `sc_src`, compile+run the C, assert the exit code and (when non-NULL)
// the exact stdout. The single strongest soundness assertion in the suite.
TH_UNUSED static void sc_run_program(const char *name, const char *sc_src, const int expected_exit,
                                     const char *expected_stdout) {
  ScResult r = sc_compile(name, sc_src, ST_CODEGEN);
  if (r.errors && r.err_stage != ST_CODEGEN) // an earlier-stage failure
    CHECK(false, "%s: unexpected %s error: %s", name, sc_stage_name(r.err_stage), r.first);
  else
    CHECK(r.errors == 0, "%s: unexpected codegen error: %s", name, r.first);
  if (r.errors || !r.code) {
    ast_free(&r.ast);
    free(r.code);
    th_rmtree(r.build_dir);
    return;
  }
  char out[8192];
  int ec = -1;
  if (sc_run_built(r.build_dir, out, sizeof out, &ec) != 0)
    CHECK(false, "%s: generated C failed to compile:\n%s\n----- generated C -----\n%s", name, out, r.code);
  else {
    CHECK(ec == expected_exit, "%s: expected exit %d, got %d\n----- generated C -----\n%s", name, expected_exit, ec, r.code);
    if (expected_stdout)
      CHECK(strcmp(out, expected_stdout) == 0, "%s: expected stdout [%s], got [%s]", name, expected_stdout, out);
  }
  ast_free(&r.ast);
  free(r.code);
  th_rmtree(r.build_dir);
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
