#define _POSIX_C_SOURCE 200809L

#include <dirent.h> // opendir/readdir, to prune stale outputs
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h> // WIFEXITED/WEXITSTATUS for the --test build/run child processes
#include <unistd.h>   // unlink/rmdir, to prune stale outputs
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
#include "consteval/consteval.h"
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

static void flush_emitf(String_Vec *errors, String_Vec *notes, U32_Vec *starts, U32_Vec *lens, const uint32_t at,
                        const uint32_t len, const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  errors_vemitf(errors, notes, starts, lens, at, len, fmt, args);
  va_end(args);
}

// A deferred static_assert that failed once the whole package was typed: render it
// with the compiler's usual source excerpt against the owning module.
static void flush_assert_err(void *ctx, const ModuleId m, const NodeId cond, const char *msg) {
  Package *const p = ctx;
  const Module *const mod = &p->modules[m];
  const Span sp = ast_at_const(mod->ast, cond)->span;
  String_Vec errors = VEC_INIT;
  String_Vec notes = VEC_INIT;
  U32_Vec starts = VEC_INIT;
  U32_Vec lens = VEC_INIT;
  if (msg)
    flush_emitf(&errors, &notes, &starts, &lens, sp.start, sp.end - sp.start,
                "static assertion cannot be evaluated: %s", msg);
  else
    flush_emitf(&errors, &notes, &starts, &lens, sp.start, sp.end - sp.start, "static assertion failed");
  errors_finalize(&errors, &notes, &starts, &lens, (const uint8_t *)mod->source, mod->source_len, mod->file);
  errors_log(&errors);
  for (size_t i = 0; i < errors.len; i++)
    free(errors.data[i]);
  for (size_t i = 0; i < notes.len; i++)
    free(notes.data[i]);
  VEC_DEINIT(errors)
  VEC_DEINIT(notes)
  VEC_DEINIT(starts)
  VEC_DEINIT(lens)
  p->ok = false;
}

// --- --test mode -----------------------------------------------------------------------------

typedef struct {
    bool enabled;
    int jobs;           // --test-jobs=N (0 = one per online core)
    bool no_fork;       // --test-no-fork: run in-process (first crash ends the run; should_panic skipped)
    const char *filter; // --test-filter=S: run only tests whose module::name contains S
} TestOpts;

typedef struct {
    ModuleId mod;
    NodeId fn;
    bool should_panic;
    uint8_t wants; // bit0 = module fixture param, bit1 = global env param
} TestCase;

typedef struct {
    TestCase *cases;
    size_t ncases, ccap;
    NodeId *fx_init, *fx_free; // per module ([package count]; NODE_NONE = absent)
    DefId *fx_type;
    bool *fx_is_enum;
    ModuleId genv_mod;
    NodeId genv_init, genv_free;
    DefId genv_type;
    bool genv_is_enum;
    bool ok;
} TestPlan;

// A test-plan validation error, rendered with the compiler's usual source excerpt.
static void test_err(Package *p, const ModuleId m, const Span sp, const char *fmt, ...) {
  const Module *const mod = &p->modules[m];
  String_Vec errors = VEC_INIT;
  String_Vec notes = VEC_INIT;
  U32_Vec starts = VEC_INIT;
  U32_Vec lens = VEC_INIT;
  va_list args;
  va_start(args, fmt);
  errors_vemitf(&errors, &notes, &starts, &lens, sp.start, sp.end - sp.start, fmt, args);
  va_end(args);
  errors_finalize(&errors, &notes, &starts, &lens, (const uint8_t *)mod->source, mod->source_len, mod->file);
  errors_log(&errors);
  for (size_t i = 0; i < errors.len; i++)
    free(errors.data[i]);
  VEC_DEINIT(errors)
  VEC_DEINIT(notes)
  VEC_DEINIT(starts)
  VEC_DEINIT(lens)
  p->ok = false;
}

// The plain struct/enum decl a type NODE names, or {0, NODE_NONE} (fixtures must be nominal and
// non-generic so wrappers can render and compare them across modules).
static DefId test_type_decl(const Package *p, const Ast *a, const NodeId tnode, bool *is_enum) {
  if (tnode == NODE_NONE)
    return (DefId){0, NODE_NONE};
  const Node *const tn = ast_at_const(a, tnode);
  if (tn->kind != NODE_TYPE_PATH && tn->kind != NODE_IDENTIFIER)
    return (DefId){0, NODE_NONE};
  const DefId d = ast_resolution_def(a, tnode);
  if (d.node == NODE_NONE || d.module >= p->count)
    return (DefId){0, NODE_NONE};
  const Node *const dn = ast_at_const(p->modules[d.module].ast, d.node);
  if ((dn->kind != NODE_STRUCT && dn->kind != NODE_ENUM) || dn->as.aggregate.generics.len)
    return (DefId){0, NODE_NONE};
  *is_enum = dn->kind == NODE_ENUM;
  return d;
}

// A function's single return type node (unwrapping a named return), or NODE_NONE.
static NodeId test_fn_ret_node(const Ast *a, const Node *fn) {
  if (fn->as.function.returns.len != 1)
    return NODE_NONE;
  const NodeId r0 = ast_list(a, fn->as.function.returns)[0];
  const Node *const rn = ast_at_const(a, r0);
  return rn->kind == NODE_PARAMETER ? rn->as.parameter.type : r0;
}

static bool test_fn_returns_nothing(const Ast *a, const char *src, const Node *fn) {
  if (fn->as.function.returns.len == 0)
    return true;
  const NodeId rn = test_fn_ret_node(a, fn);
  if (rn == NODE_NONE)
    return false;
  const Node *const n = ast_at_const(a, rn);
  return n->kind == NODE_IDENTIFIER && n->as.name.text.end - n->as.name.text.start == 4 &&
         memcmp(src + n->as.name.text.start, "void", 4) == 0;
}

// Classify one @test parameter against the module fixture / global env types. Returns the `wants` bit
// (1 = fixture, 2 = genv) or 0 with an error emitted.
static uint8_t test_param_bit(Package *p, const ModuleId m, const NodeId pnode, const DefId fx, const DefId genv) {
  const Ast *const a = p->modules[m].ast;
  const Node *const pn = ast_at_const(a, pnode);
  const Span sp = pn->span;
  const NodeId tnode = pn->as.parameter.type;
  const Node *const tn = tnode != NODE_NONE ? ast_at_const(a, tnode) : NULL;
  if (!tn || tn->kind != NODE_REFERENCE_TYPE) {
    test_err(p, m, sp, "a '@test' parameter must be a reference to the module fixture or the global env");
    return 0;
  }
  bool is_enum = false;
  const DefId d = test_type_decl(p, a, tn->as.indirect_type.type, &is_enum);
  if (fx.node != NODE_NONE && d.module == fx.module && d.node == fx.node)
    return 1;
  if (genv.node != NODE_NONE && d.module == genv.module && d.node == genv.node) {
    if (tn->as.indirect_type.qualifier == TYPE_QUAL_MUT) {
      test_err(p, m, sp, "the global test env is shared: take it as '&', not '&mut'");
      return 0;
    }
    return 2;
  }
  test_err(p, m, sp, "this parameter matches neither the module's '@test_init' fixture nor the global env");
  return 0;
}

static void test_plan_free(TestPlan *plan) {
  free(plan->cases);
  free(plan->fx_init);
  free(plan->fx_free);
  free(plan->fx_type);
  free(plan->fx_is_enum);
}

// Collect and validate every @test/@test_init/@test_free in the package into a runnable plan.
static void test_plan_build(Package *p, TestPlan *plan) {
  memset(plan, 0, sizeof *plan);
  plan->ok = true;
  plan->genv_init = plan->genv_free = NODE_NONE;
  const size_t nm = p->count ? p->count : 1;
  plan->fx_init = malloc(nm * sizeof *plan->fx_init);
  plan->fx_free = malloc(nm * sizeof *plan->fx_free);
  plan->fx_type = calloc(nm, sizeof *plan->fx_type);
  plan->fx_is_enum = calloc(nm, sizeof *plan->fx_is_enum);
  if (!plan->fx_init || !plan->fx_free || !plan->fx_type || !plan->fx_is_enum) {
    plan->ok = false;
    return;
  }
  for (size_t i = 0; i < nm; i++) {
    plan->fx_init[i] = plan->fx_free[i] = NODE_NONE;
    plan->fx_type[i] = (DefId){0, NODE_NONE};
  }
  // Pass 1: fixture producers/teardowns (module + global), so pass 2 can classify test params.
  for (size_t m = 0; m < p->count; m++) {
    const Ast *const a = p->modules[m].ast;
    if (!a || p->modules[m].prelude)
      continue;
    for (size_t i = 0; i < a->attrs.len; i++) {
      const Attr *const at = &a->attrs.data[i];
      if (at->kind != ATTR_TEST_INIT && at->kind != ATTR_TEST_FREE)
        continue;
      const Node *const fn = ast_at_const(a, at->owner);
      const Span sp = fn->span;
      if (at->kind == ATTR_TEST_INIT) {
        if (fn->as.function.params.len != 0) {
          test_err(p, m, sp, "'@test_init' takes no parameters");
          continue;
        }
        bool is_enum = false;
        const DefId d = test_type_decl(p, a, test_fn_ret_node(a, fn), &is_enum);
        if (d.node == NODE_NONE) {
          test_err(p, m, sp, "'@test_init' must return a plain (non-generic) struct or enum fixture");
          continue;
        }
        if (at->arg) { // global
          if (plan->genv_init != NODE_NONE) {
            test_err(p, m, sp, "duplicate '@test_init(global)' (one per test tree)");
            continue;
          }
          plan->genv_mod = (ModuleId)m;
          plan->genv_init = at->owner;
          plan->genv_type = d;
          plan->genv_is_enum = is_enum;
        } else {
          if (plan->fx_init[m] != NODE_NONE) {
            test_err(p, m, sp, "duplicate '@test_init' (one per module)");
            continue;
          }
          plan->fx_init[m] = at->owner;
          plan->fx_type[m] = d;
          plan->fx_is_enum[m] = is_enum;
        }
      }
    }
  }
  for (size_t m = 0; m < p->count; m++) { // @test_free after every init is known
    const Ast *const a = p->modules[m].ast;
    if (!a || p->modules[m].prelude)
      continue;
    for (size_t i = 0; i < a->attrs.len; i++) {
      const Attr *const at = &a->attrs.data[i];
      if (at->kind != ATTR_TEST_FREE)
        continue;
      const Node *const fn = ast_at_const(a, at->owner);
      const Span sp = fn->span;
      const bool global = at->arg != 0;
      const DefId want = global ? plan->genv_type : plan->fx_type[m];
      if ((global ? plan->genv_init : plan->fx_init[m]) == NODE_NONE || (global && plan->genv_mod != (ModuleId)m)) {
        test_err(p, m, sp, "'@test_free%s' has no matching '@test_init%s' in this module", global ? "(global)" : "",
                 global ? "(global)" : "");
        continue;
      }
      bool ok = fn->as.function.params.len == 1 && test_fn_returns_nothing(a, p->modules[m].source, fn);
      if (ok) {
        const Node *const pn = ast_at_const(a, ast_list(a, fn->as.function.params)[0]);
        const Node *const tn = pn->as.parameter.type != NODE_NONE ? ast_at_const(a, pn->as.parameter.type) : NULL;
        bool is_enum = false;
        const DefId d = tn && tn->kind == NODE_REFERENCE_TYPE ? test_type_decl(p, a, tn->as.indirect_type.type, &is_enum)
                                                              : (DefId){0, NODE_NONE};
        ok = tn && tn->kind == NODE_REFERENCE_TYPE && tn->as.indirect_type.qualifier == TYPE_QUAL_MUT &&
             d.module == want.module && d.node == want.node;
      }
      if (!ok) {
        test_err(p, m, sp, "'@test_free%s' must be 'fn(&mut <fixture>)' returning nothing", global ? "(global)" : "");
        continue;
      }
      if (global) {
        if (plan->genv_free != NODE_NONE) {
          test_err(p, m, sp, "duplicate '@test_free(global)'");
          continue;
        }
        plan->genv_free = at->owner;
      } else {
        if (plan->fx_free[m] != NODE_NONE) {
          test_err(p, m, sp, "duplicate '@test_free' (one per module)");
          continue;
        }
        plan->fx_free[m] = at->owner;
      }
    }
  }
  // Pass 2: the tests themselves.
  for (size_t m = 0; m < p->count; m++) {
    const Ast *const a = p->modules[m].ast;
    if (!a || p->modules[m].prelude)
      continue;
    for (size_t i = 0; i < a->attrs.len; i++) {
      const Attr *const at = &a->attrs.data[i];
      if (at->kind != ATTR_TEST)
        continue;
      const Node *const fn = ast_at_const(a, at->owner);
      const Span sp = fn->span;
      if (!test_fn_returns_nothing(a, p->modules[m].source, fn)) {
        test_err(p, m, sp, "a '@test' function returns nothing");
        continue;
      }
      const NodeList params = fn->as.function.params;
      if (params.len > 2) {
        test_err(p, m, sp, "a '@test' function takes at most the module fixture and the global env");
        continue;
      }
      uint8_t wants = 0;
      bool bad = false;
      const NodeId *const pids = ast_list(a, params);
      for (uint32_t k = 0; k < params.len && !bad; k++) {
        const uint8_t bit = test_param_bit(p, (ModuleId)m, pids[k], plan->fx_type[m],
                                           plan->genv_init != NODE_NONE ? plan->genv_type : (DefId){0, NODE_NONE});
        if (!bit) {
          bad = true;
        } else if (wants & bit) {
          test_err(p, m, sp, "duplicate '@test' parameter kind");
          bad = true;
        } else if (bit == 1 && (wants & 2)) {
          test_err(p, m, sp, "the module fixture parameter must come before the global env");
          bad = true;
        }
        wants |= bit;
      }
      if (bad)
        continue;
      if (plan->ncases == plan->ccap) {
        const size_t nc = plan->ccap ? plan->ccap * 2 : 32;
        TestCase *const g = realloc(plan->cases, nc * sizeof *g);
        if (!g) {
          plan->ok = false;
          return;
        }
        plan->cases = g;
        plan->ccap = nc;
      }
      plan->cases[plan->ncases++] =
          (TestCase){.mod = (ModuleId)m, .fn = at->owner, .should_panic = at->arg != 0, .wants = wants};
    }
  }
  plan->ok &= p->ok;
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

// Record a build-output path this run emitted (ownership transferred), growing the keep-list. Returns false
// on allocation failure: the caller then skips pruning, so a transient OOM can never delete a live output.
static bool keep_push(char ***list, size_t *n, size_t *cap, char *path) {
  if (!path)
    return true; // a failed build_out_path: nothing to track (and nothing was written)
  if (*n == *cap) {
    const size_t nc = *cap ? *cap * 2 : 16;
    char **const g = realloc(*list, nc * sizeof **list);
    if (!g) {
      free(path);
      return false;
    }
    *list = g;
    *cap = nc;
  }
  (*list)[(*n)++] = path;
  return true;
}

// Recursively delete every .c/.h under `dir` that is NOT in `keep` (the files this run wrote), then drop any
// directory left empty. The compiler overwrites build/ in place but never removed outputs that the program no
// longer produces, so a stale per-module .c lingered and broke `cc build/**/*.c` -- it could reference a
// generic instance the regenerated shared headers no longer emit (incomplete type). Pruning keeps the tree
// matching the current program. Comparison is exact: walk paths are built like build_out_path's (`dir/name`).
static void prune_orphans(const char *dir, char *const *keep, const size_t nkeep) {
  DIR *const d = opendir(dir);
  if (!d)
    return;
  for (const struct dirent *e; (e = readdir(d));) {
    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
      continue;
    char path[4096];
    if ((size_t)snprintf(path, sizeof path, "%s/%s", dir, e->d_name) >= sizeof path)
      continue;
    struct stat st;
    if (stat(path, &st) != 0)
      continue;
    if (S_ISDIR(st.st_mode)) {
      prune_orphans(path, keep, nkeep);
      rmdir(path); // no-op unless the recursion just emptied it
      continue;
    }
    const size_t L = strlen(e->d_name); // only generated translation units are ours to prune
    if (!(L >= 2 && e->d_name[L - 2] == '.' && (e->d_name[L - 1] == 'c' || e->d_name[L - 1] == 'h')))
      continue;
    bool kept = false;
    for (size_t i = 0; i < nkeep && !kept; i++)
      kept = !strcmp(keep[i], path);
    if (!kept)
      unlink(path);
  }
  closedir(d);
}

// The fixed part of the generated test runner: option parsing, fork-per-test isolation with a
// waitpid job pool (--jobs), an in-process fallback (--no-fork, should_panic skipped), substring
// selection (--filter), per-test reporting, and the summary/exit code.
static const char *const TEST_RUNNER_MAIN =
    "static int sc_match(const char *name, const char *filter) {\n"
    "  return !filter || strstr(name, filter) != NULL;\n"
    "}\n"
    "int main(int argc, char **argv) {\n"
    "  setvbuf(stdout, NULL, _IOLBF, 0); /* forked children must not inherit (and re-flush) buffered lines */\n"
    "  int jobs = 0, no_fork = 0;\n"
    "  const char *filter = NULL;\n"
    "  for (int i = 1; i < argc; i++) {\n"
    "    if (!strncmp(argv[i], \"--jobs=\", 7)) jobs = atoi(argv[i] + 7);\n"
    "    else if (!strcmp(argv[i], \"--no-fork\")) no_fork = 1;\n"
    "    else if (!strncmp(argv[i], \"--filter=\", 9)) filter = argv[i] + 9;\n"
    "  }\n"
    "  if (jobs < 1) { long n = sysconf(_SC_NPROCESSORS_ONLN); jobs = n > 0 ? (int)n : 1; }\n"
    "  int sel[SC_NTESTS > 0 ? SC_NTESTS : 1];\n"
    "  int nsel = 0;\n"
    "  for (int i = 0; i < SC_NTESTS; i++)\n"
    "    if (sc_match(SC_TESTS[i].name, filter)) sel[nsel++] = i;\n"
    "  printf(\"running %d test%s\\n\", nsel, nsel == 1 ? \"\" : \"s\");\n"
    "  void *genv = NULL;\n"
    "  if (nsel > 0) genv = sc_genv_init();\n"
    "  int passed = 0, failed = 0, skipped = 0;\n"
    "  if (no_fork) {\n"
    "    for (int k = 0; k < nsel; k++) {\n"
    "      const int i = sel[k];\n"
    "      if (SC_TESTS[i].should_panic) {\n"
    "        printf(\"test %s ... skipped (should_panic needs fork)\\n\", SC_TESTS[i].name);\n"
    "        skipped++;\n"
    "        continue;\n"
    "      }\n"
    "      SC_TESTS[i].fn(genv);\n"
    "      printf(\"test %s ... ok\\n\", SC_TESTS[i].name);\n"
    "      passed++;\n"
    "    }\n"
    "  } else {\n"
    "    pid_t pid_of[SC_NTESTS > 0 ? SC_NTESTS : 1];\n"
    "    int active = 0, next = 0;\n"
    "    while (next < nsel || active > 0) {\n"
    "      while (active < jobs && next < nsel) {\n"
    "        const pid_t pid = fork();\n"
    "        if (pid == 0) { SC_TESTS[sel[next]].fn(genv); _exit(0); }\n"
    "        if (pid < 0) { perror(\"fork\"); return 101; }\n"
    "        pid_of[next++] = pid;\n"
    "        active++;\n"
    "      }\n"
    "      int st = 0;\n"
    "      const pid_t done = wait(&st);\n"
    "      if (done < 0) break;\n"
    "      active--;\n"
    "      int ti = -1;\n"
    "      for (int k = 0; k < next; k++)\n"
    "        if (pid_of[k] == done) { ti = sel[k]; pid_of[k] = -1; break; }\n"
    "      if (ti < 0) continue;\n"
    "      const int crashed = !(WIFEXITED(st) && WEXITSTATUS(st) == 0);\n"
    "      if (crashed == SC_TESTS[ti].should_panic) {\n"
    "        printf(\"test %s ... ok%s\\n\", SC_TESTS[ti].name, SC_TESTS[ti].should_panic ? \" (panicked as expected)\" : \"\");\n"
    "        passed++;\n"
    "      } else {\n"
    "        printf(\"test %s ... FAILED%s\\n\", SC_TESTS[ti].name, SC_TESTS[ti].should_panic ? \" (expected a panic)\" : \"\");\n"
    "        failed++;\n"
    "      }\n"
    "      fflush(stdout);\n"
    "    }\n"
    "  }\n"
    "  if (genv) sc_genv_free(genv);\n"
    "  if (skipped)\n"
    "    printf(\"\\n%d passed, %d failed, %d skipped\\n\", passed, failed, skipped);\n"
    "  else\n"
    "    printf(\"\\n%d passed, %d failed\\n\", passed, failed);\n"
    "  return failed > 100 ? 100 : failed;\n"
    "}\n";

// Write build/__test_main.c: extern wrapper prototypes, the test table (display names are
// `module::fn`), the global-env hooks (stubs when absent), and the fixed runner above.
static char *write_test_main(Package *p, const TestPlan *plan) {
  char *const path = build_out_path(p->root_dir, "__test_main", ".c");
  if (!path)
    return NULL;
  FILE *const f = open_out(path);
  if (!f) {
    perror(path);
    free(path);
    return NULL;
  }
  fputs("/* generated by super-c --test */\n"
        "#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n#include <unistd.h>\n"
        "#include <sys/wait.h>\n\n",
        f);
  for (size_t i = 0; i < plan->ncases; i++)
    fprintf(f, "extern void __sc_test_w_%u_%u(void *);\n", (unsigned)plan->cases[i].mod, (unsigned)plan->cases[i].fn);
  fputs("\ntypedef void (*sc_test_fn)(void *);\n"
        "static const struct { const char *name; sc_test_fn fn; int should_panic; } SC_TESTS[] = {\n",
        f);
  for (size_t i = 0; i < plan->ncases; i++) {
    const TestCase *const tc = &plan->cases[i];
    const Ast *const a = p->modules[tc->mod].ast;
    const Span nm = ast_at_const(a, ast_at_const(a, tc->fn)->as.function.name)->as.name.text;
    fprintf(f, "  { \"%s::%.*s\", __sc_test_w_%u_%u, %d },\n", p->modules[tc->mod].path, (int)(nm.end - nm.start),
            p->modules[tc->mod].source + nm.start, (unsigned)tc->mod, (unsigned)tc->fn, tc->should_panic ? 1 : 0);
  }
  fprintf(f, "};\nenum { SC_NTESTS = %zu };\n\n", plan->ncases);
  if (plan->genv_init != NODE_NONE) {
    fputs("extern void *__sc_test_genv_init(void);\nextern void __sc_test_genv_free(void *);\n"
          "static void *sc_genv_init(void) { return __sc_test_genv_init(); }\n"
          "static void sc_genv_free(void *p) { __sc_test_genv_free(p); }\n\n",
          f);
  } else {
    fputs("static void *sc_genv_init(void) { return NULL; }\n"
          "static void sc_genv_free(void *p) { (void)p; }\n\n",
          f);
  }
  fputs(TEST_RUNNER_MAIN, f);
  fclose(f);
  return path;
}

// Compile the emitted build tree (+ the runner) with $CC and execute the test binary, forwarding the
// runner options. Returns the runner's exit code (the failure count), or 1 on a build failure.
static int test_build_and_run(Package *p, const TestOpts *to, char *const *cfiles, const size_t nc) {
  const char *cc = getenv("CC");
  if (!cc || !*cc)
    cc = "cc";
  size_t cap = 4096, at = 0;
  char *cmd = malloc(cap);
  if (!cmd)
    return 1;
#define CMD_APPEND(...)                                                                                                \
  do {                                                                                                                 \
    const int need = snprintf(NULL, 0, __VA_ARGS__);                                                                   \
    if (at + (size_t)need + 1 > cap) {                                                                                 \
      while (at + (size_t)need + 1 > cap)                                                                              \
        cap *= 2;                                                                                                      \
      char *const g = realloc(cmd, cap);                                                                               \
      if (!g) {                                                                                                        \
        free(cmd);                                                                                                     \
        return 1;                                                                                                      \
      }                                                                                                                \
      cmd = g;                                                                                                         \
    }                                                                                                                  \
    at += (size_t)snprintf(cmd + at, cap - at, __VA_ARGS__);                                                           \
  } while (0)
  CMD_APPEND("%s -std=c11 -o '%s/build/__tests'", cc, p->root_dir);
  for (size_t i = 0; i < nc; i++)
    if (cfiles[i] && strlen(cfiles[i]) > 2 && !strcmp(cfiles[i] + strlen(cfiles[i]) - 2, ".c"))
      CMD_APPEND(" '%s'", cfiles[i]);
  const int brc = system(cmd);
  if (brc != 0) {
    fprintf(stderr, "%s: test build failed (%s)\n", BIN_NAME, cc);
    free(cmd);
    return 1;
  }
  at = 0;
  CMD_APPEND("'%s/build/__tests'", p->root_dir);
  if (to->jobs > 0)
    CMD_APPEND(" --jobs=%d", to->jobs);
  if (to->no_fork)
    CMD_APPEND(" --no-fork");
  if (to->filter)
    CMD_APPEND(" '--filter=%s'", to->filter);
#undef CMD_APPEND
  const int rrc = system(cmd);
  free(cmd);
  if (rrc < 0)
    return 1;
  return WIFEXITED(rrc) ? WEXITSTATUS(rrc) : 1;
}

// Compile a loaded Package as global phases (resolve all -> type-check all -> emit all), so name
// resolution sees every module's declarations. Output is always a `<root>/build/` tree mirroring the
// module paths: a `super_rt.h` plus one `.c`/`.h` per module (the std prelude is its own unmangled
// module the others include). Symbols are mangled only when there is more than one user module.
static int run_package(Package *p, const TestOpts *topts) {
  for (size_t i = 0; i < p->count; i++)
    p->ok = resolve_one(p, &p->modules[i].ast, p->modules[i].source, p->modules[i].source_len) && p->ok;
  if (!p->ok)
    return 1;
  for (size_t i = 0; i < p->count; i++)
    p->ok = typecheck_one(p, &p->modules[i].ast, p->modules[i].source, p->modules[i].source_len) && p->ok;
  if (!p->ok)
    return 1;
  // static_asserts that were undecidable in module order (calling functions the checker had
  // not reached yet) re-evaluate now that every module is fully typed.
  consteval_flush_asserts(p->ceval, flush_assert_err, p);
  if (!p->ok)
    return 1;
  package_propagate_instances(p, NULL); // owners emit the generic instances used across module boundaries

  TestPlan plan = {0};
  const bool testing = topts && topts->enabled;
  if (testing) {
    test_plan_build(p, &plan);
    if (!plan.ok) {
      test_plan_free(&plan);
      return 1;
    }
  }

  write_super_rt(p->root_dir);
  bool err = false;
  char **kept = NULL; // every output written this run; stale .c/.h not in here are pruned below
  size_t nkept = 0, kcap = 0;
  bool keep_ok = keep_push(&kept, &nkept, &kcap, build_out_path(p->root_dir, "super_rt", ".h"));
  bool *const live = compute_emit_live(p);
  ModuleId *const order = malloc((p->count ? p->count : 1) * sizeof *order);
  if (!order) { // OOM: package_emit_order writes through `order` -- bail with an error instead of segfaulting
    free(live);
    return 1;
  }
  package_emit_order(p, order); // dependency-first: a generic's owner is emitted before any user module
  for (size_t oi = 0; oi < p->count; oi++) {        // that re-homes its instances (see package_emit_order)
    const ModuleId i = order[oi];
    if (live && !live[i])
      continue;
    Module *const m = &p->modules[i];
    Codegen *c = codegen_new(m->ast, m->source, m->source_len, p);
    codegen_set_multifile(c, true); // always a build/ tree, even for a lone module
    NodeId tids[512];   // this module's test-plan slice; must outlive codegen_emit below
    uint8_t wants[512]; // (CgTestInfo keeps pointers into these)
    if (testing) {
      uint32_t nt = 0;
      for (size_t k = 0; k < plan.ncases && nt < 512; k++)
        if (plan.cases[k].mod == i) {
          tids[nt] = plan.cases[k].fn;
          wants[nt++] = plan.cases[k].wants;
        }
      const CgTestInfo ti = {
          .enabled = true,
          .tests = tids,
          .wants = wants,
          .ntests = nt,
          .fx_init = plan.fx_init[i],
          .fx_free = plan.fx_free[i],
          .fx_type = plan.fx_type[i],
          .fx_is_enum = plan.fx_is_enum[i],
          .genv_init = plan.genv_mod == i ? plan.genv_init : NODE_NONE,
          .genv_free = plan.genv_mod == i ? plan.genv_free : NODE_NONE,
          .genv_type = plan.genv_type,
          .genv_is_enum = plan.genv_is_enum,
      };
      codegen_set_test_info(c, &ti);
    }
    char *const hpath = build_out_path(p->root_dir, m->path, ".h"); // public header alongside the .c
    FILE *const hout = hpath ? open_out(hpath) : NULL;
    if (hout) {
      codegen_emit_header(c, hout);
      fclose(hout);
    }
    keep_ok &= keep_push(&kept, &nkept, &kcap, hpath);
    char *const out_path = build_out_path(p->root_dir, m->path, ".c");
    FILE *const out = out_path ? open_out(out_path) : NULL;
    if (!out) {
      if (out_path)
        perror(out_path);
      keep_ok &= keep_push(&kept, &nkept, &kcap, out_path);
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
    keep_ok &= keep_push(&kept, &nkept, &kcap, out_path);
  }
  free(order);
  free(live);
  // Drop outputs from a previous build that this program no longer emits (a removed module/instance), so the
  // tree always matches the current sources. Skip on a keep-list OOM -- never risk deleting a live output.
  char broot[4096];
  if (keep_ok && (size_t)snprintf(broot, sizeof broot, "%s/build", p->root_dir) < sizeof broot)
    prune_orphans(broot, kept, nkept);
  int rc = err ? 1 : 0;
  if (testing && !err) { // synthesize the runner, then compile + execute the whole tree
    if (plan.ncases == 0) {
      fprintf(stderr, "%s: no '@test' functions found\n", BIN_NAME);
      rc = 1;
    } else {
      char *const runner = write_test_main(p, &plan);
      if (!runner) {
        rc = 1;
      } else {
        keep_push(&kept, &nkept, &kcap, runner); // owned by kept[] now
        rc = test_build_and_run(p, topts, kept, nkept);
      }
    }
  }
  for (size_t i = 0; i < nkept; i++)
    free(kept[i]);
  free(kept);
  if (testing)
    test_plan_free(&plan);
  return rc;
}

static int run_file(const char *path, const char *std_dir, const uint32_t ce_steps, const uint64_t ce_mem,
                    const TestOpts *topts) {
  Package *p = package_load(path, std_dir);
  if (p->ok)
    p->ceval = consteval_new(p, ce_steps, ce_mem); // always on; the flags only bound its budgets
  const int rc = p->ok ? run_package(p, topts) : 1;
  consteval_free(&p->ceval);
  package_free(&p);
  return rc;
}

// "1024", "64K", "16M", "1G" -> bytes; 0 on malformed input.
static uint64_t parse_size(const char *s) {
  char *end = NULL;
  const unsigned long long v = strtoull(s, &end, 10);
  if (end == s || v == 0)
    return 0;
  uint64_t mul = 1;
  if (*end == 'K' || *end == 'k')
    mul = 1024, end++;
  else if (*end == 'M' || *end == 'm')
    mul = 1024 * 1024, end++;
  else if (*end == 'G' || *end == 'g')
    mul = 1024ull * 1024 * 1024, end++;
  return *end == '\0' ? v * mul : 0;
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
  uint32_t ce_steps = 0; // 0 = the evaluator's defaults
  uint64_t ce_mem = 0;
  const char *file = NULL;
  TestOpts topts = {0};
  bool bad = false;
  for (int i = 1; i < argc; i++) {
    if (strncmp(argv[i], "--const-eval-steps=", 19) == 0) {
      const uint64_t v = parse_size(argv[i] + 19);
      if (!v || v > UINT32_MAX)
        bad = true;
      else
        ce_steps = (uint32_t)v;
    } else if (strncmp(argv[i], "--const-eval-memory=", 20) == 0) {
      ce_mem = parse_size(argv[i] + 20);
      bad |= ce_mem == 0;
    } else if (strcmp(argv[i], "--test") == 0) {
      topts.enabled = true;
    } else if (strncmp(argv[i], "--test-jobs=", 12) == 0) {
      topts.jobs = atoi(argv[i] + 12);
      bad |= topts.jobs < 1;
    } else if (strcmp(argv[i], "--test-no-fork") == 0) {
      topts.no_fork = true;
    } else if (strncmp(argv[i], "--test-filter=", 14) == 0) {
      topts.filter = argv[i] + 14;
    } else if (argv[i][0] == '-' && argv[i][1] == '-') {
      bad = true; // unknown flag
    } else if (!file) {
      file = argv[i];
    } else {
      file = ""; // more than one input: fall through to usage
    }
  }
  bad |= !topts.enabled && (topts.jobs || topts.no_fork || topts.filter); // --test-* imply --test
  if (bad || !file || !*file) {
    fprintf(stderr,
            "Usage: %s [--const-eval-steps=N] [--const-eval-memory=BYTES[K|M|G]]\n"
            "       %*s [--test [--test-jobs=N] [--test-no-fork] [--test-filter=S]] <path/to/script>\n",
            BIN_NAME, (int)strlen(BIN_NAME), "");
    return 1;
  }
  char *const std_dir = exe_std_dir(argv[0]);
  const int rc = run_file(file, std_dir, ce_steps, ce_mem, &topts);
  free(std_dir);
  return rc;
}
