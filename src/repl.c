#define _POSIX_C_SOURCE 200809L // getline

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ast/ast.h"
#include "ast/parser.h"
#include "codegen/codegen.h"
#include "lexer/lexer.h"
#include "lexer/token.h"
#include "module/loader.h"
#include "repl.h"
#include "resolver/resolver.h"
#include "typechecker/typechecker.h"

// Mirror main.c's fallback so the banner is sane in standalone builds (the Makefile passes -DBIN_NAME).
#ifndef BIN_NAME
  #define BIN_NAME "super-c"
#endif

// Where each successful session compile lands; the user can `cc out.c` afterwards.
#define REPL_OUT "out.c"

// One pipeline stage over a single module (identical to main.c's package path): runs it, logs any
// diagnostics, and hands the Ast back via *pa. Returns false if the stage reported errors.
static bool resolve_one(const Package *p, Ast **pa, const char *src, const size_t len) {
  Resolver *r = resolver_new(*pa, src, len, p);
  resolver_resolve(r);
  const bool had = resolver_has_errors(r);
  if (had)
    resolver_log_errors(r);
  *pa = resolver_take_ast(r);
  resolver_free(&r);
  return !had;
}
static bool typecheck_one(const Package *p, Ast **pa, const char *src, const size_t len) {
  TypeChecker *t = typechecker_new(*pa, src, len, p);
  typechecker_check(t);
  const bool had = typechecker_has_errors(t);
  if (had)
    typechecker_log_errors(t);
  *pa = typechecker_take_ast(t);
  typechecker_free(&t);
  return !had;
}

// Compile one in-memory source against the std prelude under `std_dir`, emitting a single self-contained
// .c: the prelude modules first, then the user code. Returns 1 on any stage error (diagnostics printed).
static int compile_source(const char *source, const size_t len, const char *out_path, const char *std_dir) {
  Lexer *lexer = lexer_new(source, len);
  lexer_scan_tokens(lexer);
  ERRORS_CHECK(lexer);
  Parser *parser = parser_new(lexer_take_tokens(lexer), source, len);
  lexer_free(&lexer);
  parser_build_ast(parser);
  ERRORS_CHECK(parser);
  Ast *ast = parser_take_ast(parser);
  parser_free(&parser);

  Package *pp = package_prelude_only(std_dir);
  if (!pp->ok) {
    ast_free(&ast);
    package_free(&pp);
    return 1;
  }
  ast->module = (ModuleId)pp->count; // standalone: its own nodes resolve to `ast`, prelude via the package

  bool ok = true;
  for (size_t i = 0; i < pp->count; i++)
    ok = resolve_one(pp, &pp->modules[i].ast, pp->modules[i].source, pp->modules[i].source_len) && ok;
  ok = resolve_one(pp, &ast, source, len) && ok;
  if (ok)
    for (size_t i = 0; i < pp->count; i++)
      ok = typecheck_one(pp, &pp->modules[i].ast, pp->modules[i].source, pp->modules[i].source_len) && ok;
  ok = ok && typecheck_one(pp, &ast, source, len);
  if (!ok) {
    ast_free(&ast);
    package_free(&pp);
    return 1;
  }
  package_propagate_instances(pp, ast); // owners emit cross-module generic instances (prelude + user code)

  FILE *out = fopen(out_path, "w");
  if (!out) {
    perror(out_path);
    ast_free(&ast);
    package_free(&pp);
    return 1;
  }
  // Emit the prelude modules and the user code as one self-contained, phase-interleaved unit.
  const size_t total = pp->count + 1;
  Codegen **cs = malloc(total * sizeof *cs);
  for (size_t i = 0; i < pp->count; i++)
    cs[i] = codegen_new(pp->modules[i].ast, pp->modules[i].source, pp->modules[i].source_len, pp);
  cs[pp->count] = codegen_new(ast, source, len, pp);
  codegen_emit_unit(cs, total, out);
  fclose(out);
  bool err = false;
  for (size_t i = 0; i < total; i++) {
    if (codegen_has_errors(cs[i])) {
      codegen_log_errors(cs[i]);
      err = true;
    }
    Ast *const taken = codegen_take_ast(cs[i]);
    if (i < pp->count)
      pp->modules[i].ast = taken;
    else
      ast = taken;
    codegen_free(&cs[i]);
  }
  free(cs);
  ast_free(&ast);
  package_free(&pp);
  return err ? 1 : 0;
}

// Grow `*b` to hold `*len + n` bytes (plus a NUL) and append `s`. Geometric growth keeps the running
// session/entry buffers amortized-O(1) per append.
static void buf_append(char **b, size_t *len, size_t *cap, const char *s, size_t n) {
  if (*len + n + 1 > *cap) {
    size_t nc = *cap ? *cap * 2 : 256;
    while (nc < *len + n + 1)
      nc *= 2;
    *b = realloc(*b, nc);
    *cap = nc;
  }
  memcpy(*b + *len, s, n);
  *len += n;
  (*b)[*len] = '\0';
}

// True once every bracket in `buf` is balanced, skipping string/char literals and `//` / `/* */`
// comments so delimiters inside them don't confuse the count. A false return means the entry is still
// open and the loop should read continuation lines; over-closed input reads as complete so the parser
// reports the real error.
static bool input_complete(const char *buf, size_t len) {
  int depth = 0;
  for (size_t i = 0; i < len; i++) {
    const char c = buf[i];
    if (c == '/' && i + 1 < len && buf[i + 1] == '/') {
      i += 2;
      while (i < len && buf[i] != '\n')
        i++;
    } else if (c == '/' && i + 1 < len && buf[i + 1] == '*') {
      i += 2;
      while (i + 1 < len && !(buf[i] == '*' && buf[i + 1] == '/'))
        i++;
      i++; // skip the '*'; the loop's ++ skips the '/'
    } else if (c == '"' || c == '\'') {
      i++;
      while (i < len && buf[i] != c) {
        if (buf[i] == '\\' && i + 1 < len)
          i++;
        i++;
      }
    } else if (c == '{' || c == '(' || c == '[') {
      depth++;
    } else if (c == '}' || c == ')' || c == ']') {
      if (depth > 0)
        depth--;
    }
  }
  return depth <= 0;
}

// Compile `session` followed by `add` as one unit. The session keeps prior valid definitions in scope
// for the new entry; the caller commits `add` to the session only when this returns true.
static bool session_compile(const char *session, size_t slen, const char *add, size_t alen, const char *std_dir) {
  const size_t clen = slen + alen;
  char *combined = malloc(clen + 1);
  if (!combined)
    return false;
  if (slen)
    memcpy(combined, session, slen);
  memcpy(combined + slen, add, alen);
  combined[clen] = '\0';
  const int rc = compile_source(combined, clen, REPL_OUT, std_dir);
  free(combined);
  return rc == 0;
}

static void repl_banner(void) {
  printf("%s interactive REPL -- :help for commands, :quit to exit\n", BIN_NAME);
}

static void repl_help(void) {
  puts("Commands:");
  puts("  :help, :h, :?    show this help");
  puts("  :quit, :q        exit the REPL (also: exit, Ctrl-D)");
  puts("  :reset, :r       discard all accumulated definitions");
  puts("  :show, :s        print the current session source");
  puts("  :save <path>     write the session source to <path>");
  puts("  :load <path>     compile a source file into the session");
  puts("");
  puts("Anything else is Super-C: top-level declarations (fn, struct, enum, ...) accumulate into");
  puts("the session and recompile to " REPL_OUT " after each entry. A multi-line entry continues");
  puts("until its braces balance, or until you submit it with a blank line.");
}

// Read the whole file at `path` and compile it on top of the session; on success append it so its
// declarations stay in scope. Errors (open/compile) are reported and leave the session untouched.
static void repl_load(const char *path, char **session, size_t *slen, size_t *scap, const char *std_dir) {
  FILE *f = fopen(path, "rb");
  if (!f) {
    perror(path);
    return;
  }
  fseek(f, 0, SEEK_END);
  const long sz = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (sz < 0) {
    fclose(f);
    return;
  }
  char *buf = malloc((size_t)sz + 1);
  if (!buf) {
    fclose(f);
    return;
  }
  const size_t rd = fread(buf, 1, (size_t)sz, f);
  fclose(f);
  buf[rd] = '\0';
  if (session_compile(*session, *slen, buf, rd, std_dir)) {
    buf_append(session, slen, scap, buf, rd);
    printf("loaded %s (%zu bytes) into session\n", path, rd);
  }
  free(buf);
}

typedef enum { REPL_OK, REPL_QUIT } ReplAction;

static bool cmd_is(const char *s, size_t n, const char *name) {
  return strlen(name) == n && memcmp(s, name, n) == 0;
}

// Dispatch a `:`-prefixed meta-command. May mutate the session (`:reset`, `:load`). Returns REPL_QUIT
// only for `:quit`.
static ReplAction repl_command(const char *line, char **session, size_t *slen, size_t *scap, const char *std_dir) {
  const char *cmd = line + 1; // skip ':'
  while (*cmd == ' ')
    cmd++;
  const char *arg = cmd;
  while (*arg && *arg != ' ')
    arg++;
  const size_t clen = (size_t)(arg - cmd);
  while (*arg == ' ')
    arg++; // arg now points at the argument (empty string if none)

  if (cmd_is(cmd, clen, "help") || cmd_is(cmd, clen, "h") || cmd_is(cmd, clen, "?")) {
    repl_help();
  } else if (cmd_is(cmd, clen, "quit") || cmd_is(cmd, clen, "q")) {
    return REPL_QUIT;
  } else if (cmd_is(cmd, clen, "reset") || cmd_is(cmd, clen, "r")) {
    *slen = 0;
    if (*session)
      (*session)[0] = '\0';
    puts("session cleared");
  } else if (cmd_is(cmd, clen, "show") || cmd_is(cmd, clen, "s")) {
    if (*slen)
      fputs(*session, stdout);
    else
      puts("(empty session)");
  } else if (cmd_is(cmd, clen, "save")) {
    if (!*arg) {
      puts("usage: :save <path>");
    } else {
      FILE *f = fopen(arg, "w");
      if (!f) {
        perror(arg);
      } else {
        if (*slen)
          fwrite(*session, 1, *slen, f);
        fclose(f);
        printf("saved %zu bytes to %s\n", *slen, arg);
      }
    }
  } else if (cmd_is(cmd, clen, "load")) {
    if (!*arg)
      puts("usage: :load <path>");
    else
      repl_load(arg, session, slen, scap, std_dir);
  } else {
    printf("unknown command: :%.*s  (try :help)\n", (int)clen, cmd);
  }
  return REPL_OK;
}

int repl_run(const char *std_dir) {
  repl_banner();
  char *line = NULL;
  size_t cap = 0;
  char *session = NULL; // accumulated, validated source
  size_t slen = 0, scap = 0;
  char *entry = NULL; // the multi-line entry currently being typed
  size_t elen = 0, ecap = 0;
  bool cont = false;

  for (;;) {
    fputs(cont ? "... " : "> ", stdout);
    fflush(stdout); // printf/fputs do not auto-flush without a newline

    const ssize_t n0 = getline(&line, &cap, stdin);
    if (n0 < 0) { // EOF / Ctrl-D
      fputc('\n', stdout);
      break;
    }
    ssize_t n = n0;
    while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r'))
      line[--n] = '\0';

    bool submit = false;
    if (cont) {
      if (n == 0) {
        submit = true; // blank line ends a multi-line entry
      } else {
        buf_append(&entry, &elen, &ecap, line, (size_t)n);
        buf_append(&entry, &elen, &ecap, "\n", 1);
        submit = input_complete(entry, elen);
      }
    } else {
      if (n == 0)
        continue;
      if (line[0] == ':') {
        if (repl_command(line, &session, &slen, &scap, std_dir) == REPL_QUIT)
          break;
        continue;
      }
      if (strcmp(line, "exit") == 0)
        break; // legacy alias
      buf_append(&entry, &elen, &ecap, line, (size_t)n);
      buf_append(&entry, &elen, &ecap, "\n", 1);
      submit = input_complete(entry, elen);
    }

    if (!submit) {
      cont = true;
      continue;
    }
    cont = false;
    if (elen == 0)
      continue;

    if (session_compile(session, slen, entry, elen, std_dir)) {
      buf_append(&session, &slen, &scap, entry, elen); // commit only entries that compile
      printf("ok -- wrote %s\n", REPL_OUT);
    }
    elen = 0;
    if (entry)
      entry[0] = '\0';
  }

  free(line);
  free(session);
  free(entry);
  return 0;
}
