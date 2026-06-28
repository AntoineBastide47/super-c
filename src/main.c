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

static bool mark_live(bool *const live, const size_t n, const ModuleId m) {
  if (m >= n || live[m])
    return false;
  live[m] = true;
  return true;
}

static bool ast_type_mentions_builtin(const Ast *const a, const TypeId t) {
  if (t == TYPE_NONE)
    return false;
  const Ty *const y = ast_type_at(a, t);
  switch (y->kind) {
    case TYPE_BUILTIN:
      return true;
    case TYPE_POINTER:
    case TYPE_REFERENCE:
    case TYPE_SLICE:
    case TYPE_ARRAY:
      return ast_type_mentions_builtin(a, y->as.elem);
    case TYPE_INSTANCE: {
      const TyInstance *const it = ast_instance(a, y->as.inst);
      for (uint8_t i = 0; i < it->n; i++)
        if (ast_type_mentions_builtin(a, it->args[i]))
          return true;
      return false;
    }
    default:
      return false;
  }
}

static bool mark_type_modules(const Package *const p, const Ast *const a, const TypeId t, bool *const live) {
  if (t == TYPE_NONE)
    return false;
  const Ty *const y = ast_type_at(a, t);
  bool changed = false;
  switch (y->kind) {
    case TYPE_POINTER:
    case TYPE_REFERENCE:
    case TYPE_SLICE:
    case TYPE_ARRAY:
      changed |= mark_type_modules(p, a, y->as.elem, live);
      break;
    case TYPE_STRUCT:
    case TYPE_ENUM:
    case TYPE_FUNCTION:
      if (package_builtin_of_decl(p, y->module, y->as.decl) < 0)
        changed |= mark_live(live, p->count, y->module);
      break;
    case TYPE_INSTANCE: {
      const TyInstance *const it = ast_instance(a, y->as.inst);
      if (it->module < p->count)
        changed |= mark_live(live, p->count, it->module);
      const ModuleId home = package_instance_home(p, a, it);
      if (home < p->count)
        changed |= mark_live(live, p->count, home);
      for (uint8_t i = 0; i < it->n; i++) {
        changed |= mark_type_modules(p, a, it->args[i], live);
        if (p->core_seeded && ast_type_mentions_builtin(a, it->args[i]))
          changed |= mark_live(live, p->count, p->core_module);
      }
      break;
    }
    default:
      break;
  }
  return changed;
}

static bool *compute_emit_live(const Package *const p) {
  bool *const live = calloc(p->count ? p->count : 1, sizeof *live);
  if (!live)
    return NULL;
  for (size_t i = 0; i < p->count; i++)
    if (!p->modules[i].prelude)
      live[i] = true;
  bool changed = true;
  while (changed) {
    changed = false;
    for (size_t m = 0; m < p->count; m++) {
      if (!live[m] || !p->modules[m].ast)
        continue;
      const Ast *const a = p->modules[m].ast;
      for (size_t i = 0; i < a->resolutions.len; i++) {
        const DefId d = a->resolutions.data[i];
        if (d.node == NODE_NONE || d.module >= p->count || d.module == m)
          continue;
        if (package_builtin_of_decl(p, d.module, d.node) >= 0)
          continue;
        changed |= mark_live(live, p->count, d.module);
      }
      for (size_t i = 0; i < a->type_pool.len; i++)
        changed |= mark_type_modules(p, a, (TypeId)i, live);
      for (size_t i = 0; i < a->instances.len; i++) {
        const TyInstance *const it = &a->instances.data[i];
        if (it->module < p->count)
          changed |= mark_live(live, p->count, it->module);
        const ModuleId home = package_instance_home(p, a, it);
        if (home < p->count)
          changed |= mark_live(live, p->count, home);
        for (uint8_t k = 0; k < it->n; k++) {
          changed |= mark_type_modules(p, a, it->args[k], live);
          if (p->core_seeded && ast_type_mentions_builtin(a, it->args[k]))
            changed |= mark_live(live, p->count, p->core_module);
        }
      }
      for (size_t i = 0; i < a->mono.len; i++) {
        const MonoUse *const mu = &a->mono.data[i];
        for (uint8_t k = 0; k < mu->n; k++) {
          changed |= mark_type_modules(p, a, mu->args[k], live);
          if (p->core_seeded && ast_type_mentions_builtin(a, mu->args[k]))
            changed |= mark_live(live, p->count, p->core_module);
        }
      }
      for (size_t i = 0; i < a->method_insts.len; i++) {
        const MethodInst *const mi = &a->method_insts.data[i];
        changed |= mark_type_modules(p, a, mi->instance, live);
        for (uint8_t k = 0; k < mi->n; k++) {
          changed |= mark_type_modules(p, a, mi->targs[k], live);
          if (p->core_seeded && ast_type_mentions_builtin(a, mi->targs[k]))
            changed |= mark_live(live, p->count, p->core_module);
        }
      }
    }
  }
  return live;
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
  bool *const live = compute_emit_live(p);
  ModuleId *const order = malloc((p->count ? p->count : 1) * sizeof *order);
  package_emit_order(p, order); // dependency-first: a generic's owner is emitted before any user module
  for (size_t oi = 0; oi < p->count; oi++) {        // that re-homes its instances (see package_emit_order)
    const ModuleId i = order[oi];
    if (live && !live[i])
      continue;
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
  free(live);
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
