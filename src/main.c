#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#if defined(__APPLE__)
#  include <mach-o/dyld.h> // _NSGetExecutablePath
#elif defined(__linux__)
#  include <unistd.h> // readlink("/proc/self/exe")
#endif

#include "ast/ast.h"
#include "ast/parser.h"
#include "codegen/codegen.h"
#include "lexer/lexer.h"
#include "lexer/token.h"
#include "module/loader.h"
#include "resolver/resolver.h"
#include "typechecker/typechecker.h"

// Set by the Makefile (-DBIN_NAME='"$(BIN)"'); fall back for standalone builds.
#ifndef BIN_NAME
  #define BIN_NAME "super-c"
#endif

// One pipeline stage over a single module: runs it, logs any diagnostics, and hands the Ast back via
// *pa (the pipeline stages take and return ownership). Returns false if the stage reported errors.
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

// Create `path` and any missing parent directories (like `mkdir -p`); existing dirs are ignored.
static void mkdir_p(const char *path) {
  char buf[4096];
  const size_t n = strlen(path);
  if (n == 0 || n >= sizeof buf)
    return;
  memcpy(buf, path, n + 1);
  for (char *q = buf + 1; *q; q++)
    if (*q == '/') {
      *q = '\0';
      mkdir(buf, 0775);
      *q = '/';
    }
  mkdir(buf, 0775);
}

// Generated output path: "<root>/build/<module path, '::' -> '/'><ext>", mirroring module paths as
// subdirectories (`std::string` -> `build/std/string.c`; the prelude is `__std::*` -> `build/__std/*`).
// Generated `#include`s are relative, so the tree builds with `cc build/**/*.c` and no -I. Heap-allocated.
static char *build_out_path(const char *root_dir, const char *mod_path, const char *ext) {
  const size_t n = strlen(root_dir) + sizeof "/build/" + strlen(mod_path) + strlen(ext);
  char *const out = malloc(n);
  if (!out)
    return NULL;
  size_t at = (size_t)snprintf(out, n, "%s/build/", root_dir);
  for (const char *s = mod_path; *s; s++) {
    if (s[0] == ':' && s[1] == ':') {
      out[at++] = '/';
      s++;
    } else {
      out[at++] = *s;
    }
  }
  memcpy(out + at, ext, strlen(ext) + 1);
  return out;
}

// Open `path` for writing, creating any missing parent directories first.
static FILE *open_out(char *path) {
  char *const slash = strrchr(path, '/');
  if (slash) {
    *slash = '\0';
    mkdir_p(path);
    *slash = '/';
  }
  return fopen(path, "w");
}

// The runtime header shared by every generated module: the C standard library includes. The string /
// slice view types are no longer builtins -- they come from the std `string` module (the prelude).
static void write_super_rt(const char *root_dir) {
  char *const path = build_out_path(root_dir, "super_rt", ".h");
  if (!path)
    return;
  FILE *const f = open_out(path);
  if (f) {
    fputs("#ifndef SUPER_RT_H\n#define SUPER_RT_H\n", f);
    fputs(SUPER_RT_INCLUDES, f);
    fputs("#endif\n", f);
    fclose(f);
  }
  free(path);
}

// Compile a loaded Package as global phases (resolve all -> type-check all -> emit all), so name
// resolution sees every module's declarations. Output is always a `<root>/build/` tree mirroring the
// module paths: a `super_rt.h` plus one `.c`/`.h` per module (the std prelude is its own unmangled
// module the others include). Symbols are mangled only when there is more than one user module.
static int run_package(Package *p) {
  for (size_t i = 0; i < p->count; i++)
    p->ok = resolve_one(p, &p->modules[i].ast, p->modules[i].source, p->modules[i].source_len) && p->ok;
  if (!p->ok)
    return 1;
  for (size_t i = 0; i < p->count; i++)
    p->ok = typecheck_one(p, &p->modules[i].ast, p->modules[i].source, p->modules[i].source_len) && p->ok;
  if (!p->ok)
    return 1;
  package_propagate_instances(p, NULL); // owners emit the generic instances used across module boundaries

  write_super_rt(p->root_dir);
  bool err = false;
  ModuleId *const order = malloc((p->count ? p->count : 1) * sizeof *order);
  package_emit_order(p, order); // dependency-first: a generic's owner is emitted before any user module
  for (size_t oi = 0; oi < p->count; oi++) {        // that re-homes its instances (see package_emit_order)
    const ModuleId i = order[oi];
    Module *const m = &p->modules[i];
    Codegen *c = codegen_new(m->ast, m->source, m->source_len, p);
    codegen_set_multifile(c, true); // always a build/ tree, even for a lone module
    char *const hpath = build_out_path(p->root_dir, m->path, ".h"); // public header alongside the .c
    FILE *const hout = hpath ? open_out(hpath) : NULL;
    if (hout) {
      codegen_emit_header(c, hout);
      fclose(hout);
    }
    free(hpath);
    char *const out_path = build_out_path(p->root_dir, m->path, ".c");
    FILE *const out = out_path ? open_out(out_path) : NULL;
    if (!out) {
      if (out_path)
        perror(out_path);
      free(out_path);
      m->ast = codegen_take_ast(c);
      codegen_free(&c);
      err = true;
      continue;
    }
    codegen_emit(c, out);
    fclose(out);
    if (codegen_has_errors(c)) {
      codegen_log_errors(c);
      err = true;
    }
    m->ast = codegen_take_ast(c);
    codegen_free(&c);
    free(out_path);
  }
  free(order);
  return err ? 1 : 0;
}

static int run_file(const char *path, const char *std_dir) {
  Package *p = package_load(path, std_dir);
  const int rc = p->ok ? run_package(p) : 1;
  package_free(&p);
  return rc;
}

// The std/ directory next to the running binary ("<exe dir>/std"); the prelude is resolved from here so
// it is found regardless of the working directory. Heap-allocated; caller frees.
static char *exe_std_dir(const char *argv0) {
  char buf[4096];
  const char *path = argv0;
#if defined(__APPLE__)
  uint32_t size = sizeof buf;
  if (_NSGetExecutablePath(buf, &size) == 0)
    path = buf;
#elif defined(__linux__)
  const ssize_t n = readlink("/proc/self/exe", buf, sizeof buf - 1);
  if (n > 0) {
    buf[n] = '\0';
    path = buf;
  }
#endif
  const char *const slash = strrchr(path, '/');
  const size_t dirlen = slash ? (size_t)(slash - path) : 1;
  char *const out = malloc(dirlen + sizeof "/std");
  if (!out)
    return NULL;
  memcpy(out, slash ? path : ".", dirlen);
  memcpy(out + dirlen, "/std", sizeof "/std");
  return out;
}

int main(const int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "Usage: %s <path/to/script>\n", BIN_NAME);
    return 1;
  }
  char *const std_dir = exe_std_dir(argv[0]);
  const int rc = run_file(argv[1], std_dir);
  free(std_dir);
  return rc;
}
