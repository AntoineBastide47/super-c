#include "module/loader.h"

#include <dirent.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "ast/parser.h"
#include "lexer/lexer.h"

// Read a whole file into a NUL-terminated, heap-allocated buffer; NULL on any I/O error.
static char *read_file(const char *path, size_t *size) {
  FILE *const f = fopen(path, "rb");
  if (!f)
    return NULL;
  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    return NULL;
  }
  const long s = ftell(f);
  rewind(f);
  if (s < 0) {
    fclose(f);
    return NULL;
  }
  char *const buf = malloc((size_t)s + 1);
  if (!buf) {
    fclose(f);
    return NULL;
  }
  const size_t n = fread(buf, 1, (size_t)s, f);
  if (n != (size_t)s && ferror(f)) {
    free(buf);
    fclose(f);
    return NULL;
  }
  fclose(f);
  buf[n] = '\0';
  *size = n;
  return buf;
}

// The directory portion of `path` (without trailing slash), or "." when there is none.
static char *dir_of(const char *path) {
  const char *const slash = strrchr(path, '/');
  if (!slash)
    return strdup(".");
  const size_t n = (size_t)(slash - path);
  char *const d = malloc(n + 1);
  memcpy(d, path, n);
  d[n] = '\0';
  return d;
}

// The file stem (basename without extension): "dir/std/string.spc" -> "string".
static char *stem_of(const char *path) {
  const char *const slash = strrchr(path, '/');
  const char *const base = slash ? slash + 1 : path;
  const char *const dot = strrchr(base, '.');
  const size_t n = dot ? (size_t)(dot - base) : strlen(base);
  char *const s = malloc(n + 1);
  memcpy(s, base, n);
  s[n] = '\0';
  return s;
}

static const char *ident_text(const Ast *ast, const char *src, const NodeId id, size_t *len) {
  const Span sp = ast_at_const(ast, id)->as.name.text;
  *len = sp.end - sp.start;
  return src + sp.start;
}

// Join an import's path parts with `sep` ("::" for a module path, "/" for a file path).
static char *join_parts(const Ast *ast, const char *src, const NodeList parts, const char *sep) {
  const NodeId *const ids = ast_list(ast, parts);
  const size_t seplen = strlen(sep);
  size_t total = 0;
  for (uint32_t i = 0; i < parts.len; i++) {
    size_t l = 0;
    ident_text(ast, src, ids[i], &l);
    total += l + (i ? seplen : 0);
  }
  char *const out = malloc(total + 1);
  size_t at = 0;
  for (uint32_t i = 0; i < parts.len; i++) {
    if (i) {
      memcpy(out + at, sep, seplen);
      at += seplen;
    }
    size_t l = 0;
    const char *const t = ident_text(ast, src, ids[i], &l);
    memcpy(out + at, t, l);
    at += l;
  }
  out[at] = '\0';
  return out;
}

// "<root_dir>/<parts joined by '/'>.spc".
static char *module_file_path(const char *root_dir, const Ast *ast, const char *src, const NodeList parts) {
  char *const rel = join_parts(ast, src, parts, "/");
  const size_t n = strlen(root_dir) + 1 + strlen(rel) + 4 + 1;
  char *const out = malloc(n);
  snprintf(out, n, "%s/%s.spc", root_dir, rel);
  free(rel);
  return out;
}

// Resolve an import's file by searching the project root first, then the std root (so `import std::x;`
// finds <std_root>/std/x.spc), then the bundled `ffi/` bindings (so a bare `import stdio;` finds
// <std_root>/ffi/stdio.spc -- one module per C header, imported by the header's bare name). Returns the
// first path that exists, else the project-relative path (so a not-found error names the project
// location). Heap-allocated; caller owns it.
static char *resolve_import_file(const Package *p, const Ast *ast, const char *src, const NodeList parts) {
  char *const root_rel = module_file_path(p->root_dir, ast, src, parts);
  if (access(root_rel, F_OK) == 0 || !p->std_root)
    return root_rel;
  char *const std_rel = module_file_path(p->std_root, ast, src, parts);
  if (access(std_rel, F_OK) == 0) {
    free(root_rel);
    return std_rel;
  }
  free(std_rel);
  char ffi_base[PATH_MAX];
  snprintf(ffi_base, sizeof ffi_base, "%s/ffi", p->std_root);
  char *const ffi_rel = module_file_path(ffi_base, ast, src, parts);
  if (access(ffi_rel, F_OK) == 0) {
    free(root_rel);
    return ffi_rel;
  }
  free(ffi_rel);
  return root_rel;
}

// Lex + parse one module's source into an Ast, printing diagnostics; NULL on a lex/parse error.
// `file` is the source path, shown in diagnostics' `--> file:line:col` location.
static Ast *parse_source(const char *source, const size_t len, const char *file) {
  Lexer *lexer = lexer_new(source, len);
  lexer_set_file(lexer, file);
  lexer_scan_tokens(lexer);
  if (lexer_has_errors(lexer)) {
    lexer_log_errors(lexer);
    lexer_free(&lexer);
    return NULL;
  }
  Parser *parser = parser_new(lexer_take_tokens(lexer), source, len);
  parser_set_file(parser, file);
  lexer_free(&lexer);
  parser_build_ast(parser);
  if (parser_has_errors(parser)) {
    parser_log_errors(parser);
    parser_free(&parser);
    return NULL;
  }
  Ast *const ast = parser_take_ast(parser);
  parser_free(&parser);
  return ast;
}

int package_find(const Package *p, const char *path, const size_t path_len) {
  for (size_t i = 0; i < p->count; i++)
    if (strlen(p->modules[i].path) == path_len && memcmp(p->modules[i].path, path, path_len) == 0)
      return (int)i;
  return -1;
}

// Add a module slot (taking ownership of `path`/`file`/`source`/`ast`) and return its id.
static int add_module(Package *p, char *path, char *file, char *source, size_t source_len, Ast *ast) {
  if (p->count == p->cap) {
    p->cap = p->cap ? p->cap * 2 : 8;
    p->modules = realloc(p->modules, p->cap * sizeof *p->modules);
  }
  const int id = (int)p->count++;
  p->modules[id] = (Module){
      .path = path, .file = file, .source = source, .source_len = source_len, .ast = ast, .loading = true};
  return id;
}

// DFS load: takes ownership of `mod_path` and `file_path`. Returns the module's id (or -1 if unreadable).
static int load_module(Package *p, char *mod_path, char *file_path) {
  const int existing = package_find(p, mod_path, strlen(mod_path));
  if (existing >= 0) {
    if (p->modules[existing].loading) {
      fprintf(stderr, "error: import cycle through module '%s'\n", mod_path);
      p->ok = false;
    }
    free(mod_path);
    free(file_path);
    return existing;
  }

  size_t len = 0;
  char *const source = read_file(file_path, &len);
  if (!source) {
    fprintf(stderr, "error: cannot open module '%s' (%s)\n", mod_path, file_path);
    p->ok = false;
    free(mod_path);
    free(file_path);
    return -1;
  }

  Ast *const ast = parse_source(source, len, file_path);
  const int id = add_module(p, mod_path, file_path, source, len, ast);
  if (!ast) {
    p->ok = false;
    p->modules[id].loading = false;
    return id;
  }
  ast->module = (ModuleId)id;

  // Recurse into imports. The Ast is stable across recursion; p->modules may realloc, so re-index by id.
  const NodeList items = ast_at_const(ast, ast->root)->as.program.items;
  const NodeId *const ids = ast_list(ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(ast, ids[i]);
    if (n->kind != NODE_IMPORT)
      continue;
    char *const child_path = join_parts(ast, source, n->as.import_decl.path, "::");
    char *const child_file = resolve_import_file(p, ast, source, n->as.import_decl.path);
    load_module(p, child_path, child_file);
  }
  p->modules[id].loading = false;
  return id;
}

// True if `a` and `b` name the same file on disk (after symlink/.. resolution).
static bool same_file(const char *a, const char *b) {
  char ra[PATH_MAX], rb[PATH_MAX];
  return a && b && realpath(a, ra) && realpath(b, rb) && strcmp(ra, rb) == 0;
}

static int cmp_str(const void *a, const void *b) {
  return strcmp(*(const char *const *)a, *(const char *const *)b);
}

// Auto-import the prelude: every TOP-LEVEL `<std_dir>/*.spc` (not subdirectories) becomes a prelude
// module whose public items resolve unqualified. Subdir modules (e.g. std/net/tcp.spc) are NOT prelude --
// they need an explicit `import std::net::tcp;`. Only the directly-listed files are flagged; their
// transitive imports stay ordinary dependencies. A file already loaded (e.g. explicitly imported) is just
// flagged in place. No-op when std_dir is missing.
static void load_prelude(Package *p, const char *std_dir) {
  if (!std_dir)
    return;
  DIR *const dir = opendir(std_dir);
  if (!dir)
    return;
  char **names = NULL;
  size_t n = 0, cap = 0;
  for (struct dirent *e; (e = readdir(dir));) {
    const size_t l = strlen(e->d_name);
    if (l < 5 || strcmp(e->d_name + l - 4, ".spc") != 0)
      continue;
    if (n == cap) {
      cap = cap ? cap * 2 : 8;
      names = realloc(names, cap * sizeof *names);
    }
    names[n++] = strdup(e->d_name);
  }
  closedir(dir);
  qsort(names, n, sizeof *names, cmp_str); // deterministic module ids regardless of readdir order

  for (size_t k = 0; k < n; k++) {
    const size_t fl = strlen(std_dir) + 1 + strlen(names[k]) + 1;
    char *const file = malloc(fl);
    snprintf(file, fl, "%s/%s", std_dir, names[k]);
    struct stat st;
    if (stat(file, &st) == 0 && S_ISDIR(st.st_mode)) { // a dir literally named "*.spc" -- top level only
      free(file);
      free(names[k]);
      continue;
    }
    bool dup = false;
    for (size_t i = 0; i < p->count; i++)
      if (same_file(p->modules[i].file, file)) {
        p->modules[i].prelude = true; // already loaded via an explicit import -- just promote it
        dup = true;
        break;
      }
    if (!dup) {
      // Path the file under the reserved `__std::` namespace, so its build output lands in `build/__std/`
      // -- never colliding with a user's own `std/` project folder (`build/std/...`).
      char *const stem = stem_of(names[k]);
      const size_t pl = strlen("__std::") + strlen(stem) + 1;
      char *const modpath = malloc(pl);
      snprintf(modpath, pl, "__std::%s", stem);
      free(stem);
      const int id = load_module(p, modpath, file); // takes ownership of modpath + file
      if (id >= 0)
        p->modules[id].prelude = true;
    } else {
      free(file);
    }
    free(names[k]);
  }
  free(names);
}

// Inject one synthetic decl per builtin into the core prelude module (`__std::core`), so builtins are nominal
// types that `extend i32 { .. }` can target and `find_method`/`type_satisfies` can match. The decls live in
// the node pool only (not program.items): they are never declared as names, only referenced as the resolution
// of an `extend`'s builtin target. Run after loading, before resolve (which sizes the resolution table).
static void package_seed_core(Package *p) {
  p->core_seeded = false;
  for (size_t i = 0; i < p->count; i++) {
    if (!p->modules[i].ast || strcmp(p->modules[i].path, "__std::core") != 0)
      continue;
    Ast *const a = p->modules[i].ast;
    for (BuiltinType b = 0; b < BT_COUNT; b++) {
      const Node decl = {.kind = NODE_STRUCT, .as.aggregate = {.name = NODE_NONE, .is_public = true}};
      p->builtin_decls[b] = ast_add(a, decl);
    }
    p->core_module = (ModuleId)i;
    p->core_seeded = true;
    return;
  }
}

NodeId package_builtin_decl(const Package *p, const BuiltinType b) {
  return p->core_seeded && b < BT_COUNT ? p->builtin_decls[b] : NODE_NONE;
}

int package_builtin_of_decl(const Package *p, const ModuleId module, const NodeId node) {
  if (!p->core_seeded || module != p->core_module || node == NODE_NONE)
    return -1;
  for (int b = 0; b < BT_COUNT; b++)
    if (p->builtin_decls[b] == node)
      return b;
  return -1;
}

Package *package_load(const char *root_file, const char *std_dir) {
  Package *const p = calloc(1, sizeof *p);
  p->ok = true;
  p->root_dir = dir_of(root_file);
  p->std_root = std_dir ? dir_of(std_dir) : NULL; // `import std::x;` -> <std_root>/std/x.spc
  load_module(p, stem_of(root_file), strdup(root_file));
  load_prelude(p, std_dir);
  package_seed_core(p);
  return p;
}

Package *package_prelude_only(const char *std_dir) {
  Package *const p = calloc(1, sizeof *p);
  p->ok = true;
  p->root_dir = strdup(std_dir ? std_dir : ".");
  p->std_root = std_dir ? dir_of(std_dir) : NULL;
  load_prelude(p, std_dir);
  package_seed_core(p);
  return p;
}

void package_mark_method_used(Package *p, const DefId d) {
  if (!p || d.node == NODE_NONE)
    return;
  if ((size_t)d.module >= p->method_used_mods) { // grow the per-module outer arrays
    const size_t nm = (size_t)d.module + 1 > p->count ? (size_t)d.module + 1 : p->count;
    bool **const na = realloc(p->method_used, nm * sizeof *na);
    if (!na)
      return; // OOM: a missed mark only over-prunes a never-otherwise-referenced method
    p->method_used = na;
    size_t *const nc = realloc(p->method_used_cap, nm * sizeof *nc);
    if (!nc)
      return;
    p->method_used_cap = nc;
    for (size_t i = p->method_used_mods; i < nm; i++) {
      na[i] = NULL;
      nc[i] = 0;
    }
    p->method_used_mods = nm;
  }
  if ((size_t)d.node >= p->method_used_cap[d.module]) { // grow this module's bit array to cover the node
    size_t ncap = p->method_used_cap[d.module] ? p->method_used_cap[d.module] : 256;
    while (ncap <= (size_t)d.node)
      ncap *= 2;
    bool *const nb = realloc(p->method_used[d.module], ncap * sizeof *nb);
    if (!nb)
      return;
    for (size_t i = p->method_used_cap[d.module]; i < ncap; i++)
      nb[i] = false;
    p->method_used[d.module] = nb;
    p->method_used_cap[d.module] = ncap;
  }
  p->method_used[d.module][d.node] = true;
}

bool package_method_used(const Package *p, const DefId d) {
  if (!p)
    return true; // no package (single-file / REPL): emit every method
  if (d.node == NODE_NONE || (size_t)d.module >= p->method_used_mods || (size_t)d.node >= p->method_used_cap[d.module])
    return false;
  return p->method_used[d.module][d.node];
}

void package_free(Package **p) {
  if (!p || !*p)
    return;
  for (size_t i = 0; i < (*p)->count; i++) {
    free((*p)->modules[i].path);
    free((*p)->modules[i].file);
    free((*p)->modules[i].source);
    if ((*p)->modules[i].ast)
      ast_free(&(*p)->modules[i].ast);
  }
  free((*p)->modules);
  free((*p)->root_dir);
  free((*p)->std_root);
  for (size_t i = 0; i < (*p)->method_used_mods; i++)
    free((*p)->method_used[i]);
  free((*p)->method_used);
  free((*p)->method_used_cap);
  free(*p);
  *p = NULL;
}

NodeId package_lookup(const Package *p, const ModuleId mid, const char *name, const size_t name_len,
                      const bool want_type) {
  const Ast *const ast = p->modules[mid].ast;
  if (!ast)
    return NODE_NONE;
  const char *const src = p->modules[mid].source;
  const NodeList items = ast_at_const(ast, ast->root)->as.program.items;
  const NodeId *const ids = ast_list(ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(ast, ids[i]);
    NodeId name_node;
    bool is_pub, is_type;
    if (n->kind == NODE_STRUCT || n->kind == NODE_ENUM) {
      name_node = n->as.aggregate.name;
      is_pub = n->as.aggregate.is_public;
      is_type = true;
    } else if (n->kind == NODE_TYPE_ALIAS) {
      name_node = n->as.type_alias.name;
      is_pub = n->as.type_alias.is_public;
      is_type = true;
    } else if (n->kind == NODE_INTERFACE) {
      name_node = n->as.interface_def.name;
      is_pub = n->as.interface_def.is_public;
      is_type = true;
    } else if (n->kind == NODE_FUNCTION) {
      name_node = n->as.function.name;
      is_pub = n->as.function.is_public;
      is_type = false;
    } else if (n->kind == NODE_CONST) {
      name_node = n->as.const_def.name;
      is_pub = n->as.const_def.is_public;
      is_type = false;
    } else if (n->kind == NODE_EXTERN_BLOCK) {
      // `pub` raw bindings / opaque handles live one level down, inside the extern block.
      const NodeList inner = n->as.extern_block.items;
      const NodeId *const iids = ast_list(ast, inner);
      for (uint32_t j = 0; j < inner.len; j++) {
        const Node *const it = ast_at_const(ast, iids[j]);
        NodeId nn;
        bool ip, it_type;
        if (it->kind == NODE_FUNCTION) {
          nn = it->as.function.name;
          ip = it->as.function.is_public;
          it_type = false;
        } else if (it->kind == NODE_TYPE_ALIAS) {
          nn = it->as.type_alias.name;
          ip = it->as.type_alias.is_public;
          it_type = true;
        } else if (it->kind == NODE_CONST) {
          nn = it->as.const_def.name;
          ip = it->as.const_def.is_public;
          it_type = false;
        } else {
          continue;
        }
        if (!ip || it_type != want_type)
          continue;
        size_t l = 0;
        const char *const t = ident_text(ast, src, nn, &l);
        if (l == name_len && memcmp(t, name, name_len) == 0)
          return iids[j];
      }
      continue;
    } else {
      continue;
    }
    if (!is_pub || is_type != want_type)
      continue;
    size_t l = 0;
    const char *const t = ident_text(ast, src, name_node, &l);
    if (l == name_len && memcmp(t, name, name_len) == 0)
      return ids[i];
  }
  return NODE_NONE;
}

NodeId package_prelude_lookup(const Package *p, const char *name, const size_t name_len, const bool want_type,
                             ModuleId *const out_mid) {
  for (size_t i = 0; i < p->count; i++) {
    if (!p->modules[i].prelude)
      continue;
    const NodeId d = package_lookup(p, (ModuleId)i, name, name_len, want_type);
    if (d != NODE_NONE) {
      if (out_mid)
        *out_mid = (ModuleId)i;
      return d;
    }
  }
  return NODE_NONE;
}

NodeId package_glob_lookup(const Package *p, const ModuleId mid, const char *name, const size_t name_len,
                           const bool want_type, ModuleId *const out_mid) {
  const size_t n = p->count;
  if ((size_t)mid >= n)
    return NODE_NONE;
  bool seen[n]; // each module enqueues once, so queue length is bounded by n
  ModuleId queue[n];
  memset(seen, 0, n);
  size_t head = 0, tail = 0;
  queue[tail++] = mid;
  seen[mid] = true;
  while (head < tail) {
    const ModuleId m = queue[head++];
    const NodeId d = package_lookup(p, m, name, name_len, want_type);
    if (d != NODE_NONE) {
      if (out_mid)
        *out_mid = m;
      return d;
    }
    const Ast *const ast = p->modules[m].ast;
    if (!ast)
      continue;
    const NodeList items = ast_at_const(ast, ast->root)->as.program.items;
    const NodeId *const ids = ast_list(ast, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const it = ast_at_const(ast, ids[i]);
      if (it->kind != NODE_IMPORT)
        continue;
      char *const path = join_parts(ast, p->modules[m].source, it->as.import_decl.path, "::");
      const int c = package_find(p, path, strlen(path));
      free(path);
      if (c >= 0 && !seen[c]) {
        seen[c] = true;
        queue[tail++] = (ModuleId)c;
      }
    }
  }
  return NODE_NONE;
}

#define MODULE_NONE ((ModuleId)0xFFFF)

// Is `m` a user (non-prelude) module? The standalone REPL/test Ast lives at module == p->count (outside
// p->modules) and is always user code.
static bool module_is_user(const Package *p, const ModuleId m) {
  return m >= p->count || !p->modules[m].prelude;
}

static ModuleId type_user_home(const Package *p, const Ast *a, TypeId t);

// The module a concrete instance must be emitted in: the module of the first type argument that is a
// user (non-prelude) aggregate held by value -- there its full layout is visible, so an `Option<Bar>`-style
// by-value field is complete. All-builtin/all-prelude args -> the generic's own module (it->module), the
// classic owner-emits path. A pointer/ref/slice arg needs only a forward declaration, so it never re-homes.
// Does module `from`'s code reference anything in module `to` (a cross-module use edge)? Used to tell
// whether `from` already includes `to`'s header. A prelude instance arg (String<Global>, home = the base
// `string` module) must NOT pull the outer container down to its home if the container's owner can simply
// include it (owner -> string, no cycle); only re-home to a prelude arg-home that itself depends on the
// owner (vector -> option), where owner-emitting would form an include cycle.
static bool module_imports(const Package *p, const ModuleId from, const ModuleId to) {
  if (from >= p->count || !p->modules[from].ast)
    return false;
  const DefId_Vec *const r = &p->modules[from].ast->resolutions;
  for (size_t i = 0; i < r->len; i++)
    if (r->data[i].node != NODE_NONE && r->data[i].module == to)
      return true;
  return false;
}

static ModuleId instance_home(const Package *p, const Ast *a, const TyInstance *const it) {
  for (uint8_t i = 0; i < it->n; i++) {
    const ModuleId h = type_user_home(p, a, it->args[i]);
    // Re-home over a user type always; over a prelude arg-home only when that home depends on the owner
    // (so owner-emitting would cycle). Otherwise the owner can include the arg-home -> keep it owner-emitted.
    if (h != MODULE_NONE && (module_is_user(p, h) || module_imports(p, h, it->module)))
      return h;
  }
  return it->module;
}

static ModuleId type_user_home(const Package *p, const Ast *a, const TypeId t) {
  const Ty *const y = ast_type_at(a, t);
  switch (y->kind) {
    case TYPE_POINTER:
    case TYPE_REFERENCE:
      // A pointer/reference arg only needs its pointee forward-declared for layout, but the instance's
      // mangled NAME and the pointee-typed field must be rendered where the pointee is known. So re-home
      // to the pointee's user module (Option<&P> emits alongside P, exactly like Option<P>) -- otherwise
      // the generic's owner module would try to render a user type it cannot see.
      return type_user_home(p, a, y->as.elem);
    case TYPE_SLICE:
      return MODULE_NONE; // a fat pointer: self-contained, completes anywhere
    case TYPE_ARRAY:
      return type_user_home(p, a, y->as.elem); // an array embeds its element by value
    case TYPE_STRUCT:
    case TYPE_ENUM:
      return module_is_user(p, y->module) ? y->module : MODULE_NONE;
    case TYPE_FUNCTION:
      // A function VALUE arg (an `F: fn(..)` instantiation): a closure's static fn / env struct exists
      // only in its defining TU, so anything specialized over it must materialize there.
      return module_is_user(p, y->module) ? y->module : MODULE_NONE;
    case TYPE_INSTANCE:
      // A nested instance held by value re-homes the outer one to where the nested instance ITSELF is
      // emitted (its home) -- the only module where its layout is complete. That may be a prelude sibling
      // (Option<Vector<i32>> -> the vector module, where Vector__i32 is complete and which includes the
      // Option header), not the outer generic's owner; routing there is what makes the by-value field valid.
      return instance_home(p, a, ast_instance(a, y->as.inst));
    default:
      return MODULE_NONE;
  }
}

ModuleId package_instance_home(const Package *p, const Ast *a, const TyInstance *const it) {
  return instance_home(p, a, it);
}

// The emit-order dependency relation (built inline in package_emit_order below): emitting module `a`
// full-monomorphizes a generic instance owned by module `b` -- codegen sources `b`'s template while
// transiently interning into `b`'s pools, so `b` must be emitted first (its own pass then never observes
// that transient state). That is the re-homing relation: a concrete instance in `a`'s table whose owner is
// `b` and whose home (where it materializes) is `a` itself.
void package_emit_order(const Package *p, ModuleId *const order) {
  const size_t n = p->count;
  if (n == 0)
    return;
  // Build the dependency edges ONCE -- `dep[a*n + b]` means module a re-homes a concrete instance owned by
  // b, so b must be emitted before a -- then Kahn topo-sort with a lowest-id tiebreak (matching the old
  // selection). O(instances + n^2) instead of the old O(n^3 * instances) emits_into rescans.
  bool *const done = calloc(n, 1);
  bool *const dep = calloc(n * n, 1);
  size_t *const indeg = calloc(n, sizeof *indeg);
  if (!done || !dep || !indeg) { // OOM: id order (correct output; loses the re-homed-pollution-timing opt)
    for (size_t i = 0; i < n; i++)
      order[i] = (ModuleId)i;
    free(done);
    free(dep);
    free(indeg);
    return;
  }
  for (size_t a = 0; a < n; a++) {
    const Ast *const aa = p->modules[a].ast;
    if (!aa)
      continue;
    for (size_t i = 0; i < aa->instances.len; i++) {
      const TyInstance *const it = &aa->instances.data[i];
      const ModuleId b = it->module;
      if ((size_t)b >= n || (size_t)b == a || dep[a * n + (size_t)b])
        continue;
      bool concrete = true;
      for (uint8_t k = 0; k < it->n; k++)
        concrete &= ast_type_concrete(aa, it->args[k]);
      if (concrete && instance_home(p, aa, it) == (ModuleId)a) {
        dep[a * n + (size_t)b] = true;
        indeg[a]++;
      }
    }
    // A generic-method use recorded here over a foreign instance (fn-value type args are kept in the
    // calling module) sources the owner's template the same way: the owner must emit first.
    for (size_t i = 0; i < aa->method_insts.len; i++) {
      const Ty *const y = ast_type_at(aa, aa->method_insts.data[i].instance);
      if (y->kind != TYPE_INSTANCE)
        continue;
      const ModuleId b = ast_instance(aa, y->as.inst)->module;
      if ((size_t)b >= n || (size_t)b == a || dep[a * n + (size_t)b])
        continue;
      dep[a * n + (size_t)b] = true;
      indeg[a]++;
    }
    // A call to a FOREIGN generic free function: the caller emits a static copy of the spec by sourcing
    // the owner's template (transiently interning into its pools) -- the owner must emit first too.
    for (size_t i = 0; i < aa->mono.len; i++) {
      const Node *const call = ast_at_const(aa, aa->mono.data[i].node);
      if (call->kind != NODE_CALL)
        continue;
      const Node *const callee = ast_at_const(aa, call->as.call.callee);
      const DefId fd = callee->kind == NODE_GENERIC_SPECIALIZATION
                           ? ast_resolution_def(aa, callee->as.specialization.expression)
                           : ast_resolution_def(aa, call->as.call.callee);
      const ModuleId b = fd.module;
      if (fd.node == NODE_NONE || (size_t)b >= n || (size_t)b == a || dep[a * n + (size_t)b])
        continue;
      if (!p->modules[b].ast || ast_at_const(p->modules[b].ast, fd.node)->kind != NODE_FUNCTION)
        continue;
      dep[a * n + (size_t)b] = true;
      indeg[a]++;
    }
  }
  for (size_t k = 0; k < n; k++) {
    size_t pick = n;
    for (size_t i = 0; i < n; i++) // lowest-id module whose every owner dependency is already emitted
      if (!done[i] && indeg[i] == 0) {
        pick = i;
        break;
      }
    if (pick == n) // residual cycle (mutually re-homing modules): take the next in id order
      for (size_t i = 0; i < n; i++)
        if (!done[i]) {
          pick = i;
          break;
        }
    order[k] = (ModuleId)pick;
    done[pick] = true;
    for (size_t x = 0; x < n; x++) // pick is emitted: drop it from every remaining dependent's indegree
      if (!done[x] && dep[x * n + pick] && indeg[x] > 0)
        indeg[x]--;
  }
  free(done);
  free(dep);
  free(indeg);
}

static TypeId subst_reintern_type(Ast *const dest, const Ast *const owner, const TypeId t, const ModuleId gmod,
                                  const NodeId *const gids, const TypeId *const args, const uint8_t nargs) {
  if (t == TYPE_NONE)
    return TYPE_NONE;
  const Ty ty = *ast_type_at(owner, t);
  switch (ty.kind) {
    case TYPE_GENERIC:
      for (uint8_t i = 0; i < nargs; i++)
        if (ty.module == gmod && ty.as.decl == gids[i])
          return args[i];
      return ast_reintern(dest, owner, t);
    case TYPE_POINTER:
    case TYPE_REFERENCE:
    case TYPE_SLICE:
    case TYPE_ARRAY: {
      Ty nt = ty;
      nt.as.elem = subst_reintern_type(dest, owner, ty.as.elem, gmod, gids, args, nargs);
      return ast_intern_type(dest, nt);
    }
    case TYPE_INSTANCE: {
      const TyInstance inst = *ast_instance(owner, ty.as.inst);
      TypeId na[4];
      const uint8_t n = inst.n < 4 ? inst.n : 4;
      for (uint8_t i = 0; i < n; i++)
        na[i] = subst_reintern_type(dest, owner, inst.args[i], gmod, gids, args, nargs);
      return ast_intern_instance(dest, inst.module, inst.decl, na, n);
    }
    default:
      return ast_reintern(dest, owner, t);
  }
}

static void reintern_nested_type(Package *p, Ast *const dest, const Ast *const owner, const TypeId t,
                                 const ModuleId gmod, const NodeId *const gids, const TypeId *const args,
                                 const uint8_t nargs, bool *const changed) {
  if (t == TYPE_NONE)
    return;
  const size_t before = dest->instances.len;
  TypeId st = subst_reintern_type(dest, owner, t, gmod, gids, args, nargs);
  const Ty *y = ast_type_at(dest, st);
  while (y->kind == TYPE_ARRAY) {
    st = y->as.elem;
    y = ast_type_at(dest, st);
  }
  if (y->kind != TYPE_INSTANCE)
    return;
  const TyInstance it = *ast_instance(dest, y->as.inst);
  bool concrete = true;
  for (uint8_t i = 0; i < it.n; i++)
    concrete &= ast_type_concrete(dest, it.args[i]);
  if (!concrete)
    return;
  const ModuleId home = instance_home(p, dest, &it);
  Ast *const hdst = home < p->count ? p->modules[home].ast : dest->module == home ? dest : NULL;
  if (hdst && hdst != dest) {
    TypeId na[4];
    const uint8_t n = it.n < 4 ? it.n : 4;
    const size_t hbefore = hdst->instances.len;
    for (uint8_t i = 0; i < n; i++)
      na[i] = ast_reintern(hdst, dest, it.args[i]);
    ast_intern_instance(hdst, it.module, it.decl, na, n);
    *changed |= hdst->instances.len != hbefore;
  }
  *changed |= dest->instances.len != before;
}

static void reintern_nested_instance_deps(Package *p, Ast *const dest, const TyInstance *const it,
                                          const TypeId *const args, const uint8_t nargs, bool *const changed) {
  if (it->module >= p->count || !p->modules[it->module].ast)
    return;
  Ast *const owner = p->modules[it->module].ast;
  const Node *const dn = ast_at_const(owner, it->decl);
  if ((dn->kind != NODE_STRUCT && dn->kind != NODE_ENUM) || dn->as.aggregate.generics.len == 0)
    return;
  const NodeId *const gids = ast_list(owner, dn->as.aggregate.generics);
  const NodeId *const mids = ast_list(owner, dn->as.aggregate.members);
  for (uint32_t m = 0; m < dn->as.aggregate.members.len; m++) {
    const Node *const mn = ast_at_const(owner, mids[m]);
    if (dn->kind == NODE_STRUCT && mn->kind == NODE_FIELD) {
      reintern_nested_type(p, dest, owner, ast_type(owner, mn->as.field.type), it->module, gids, args, nargs, changed);
    } else if (dn->kind == NODE_ENUM && mn->kind == NODE_VARIANT) {
      const NodeId *const pids = ast_list(owner, mn->as.variant.payload);
      for (uint32_t k = 0; k < mn->as.variant.payload.len; k++) {
        const Node *const pf = ast_at_const(owner, pids[k]);
        const NodeId tn = pf->kind == NODE_FIELD ? pf->as.field.type : pids[k];
        reintern_nested_type(p, dest, owner, ast_type(owner, tn), it->module, gids, args, nargs, changed);
      }
    }
  }
}

static void reintern_method_signature_deps(Package *p, Ast *const dest, const TyInstance *const it,
                                           const TypeId *const args, const uint8_t nargs, bool *const changed) {
  if (it->module >= p->count || !p->modules[it->module].ast)
    return;
  Ast *const owner = p->modules[it->module].ast;
  const NodeList items = ast_at_const(owner, owner->root)->as.program.items;
  const NodeId *const ids = ast_list(owner, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const extend = ast_at_const(owner, ids[i]);
    if (extend->kind != NODE_EXTEND || !extend->as.extend_def.generics.len)
      continue;
    if (ast_resolution(owner, extend->as.extend_def.target_type) != it->decl)
      continue;
    const NodeId *const gids = ast_list(owner, extend->as.extend_def.generics);
    const NodeList ms = extend->as.extend_def.items;
    const NodeId *const mids = ast_list(owner, ms);
    for (uint32_t m = 0; m < ms.len; m++) {
      const Node *const fn = ast_at_const(owner, mids[m]);
      if (fn->kind != NODE_FUNCTION || fn->as.function.generics.len || fn->as.function.returns.len > 1)
        continue;
      const NodeList ps = fn->as.function.params;
      const NodeId *const pids = ast_list(owner, ps);
      for (uint32_t k = 0; k < ps.len; k++) {
        const Node *const pn = ast_at_const(owner, pids[k]);
        reintern_nested_type(p, dest, owner, ast_type(owner, pn->as.parameter.type), owner->module, gids, args, nargs,
                             changed);
      }
      const NodeList rs = fn->as.function.returns;
      const NodeId *const rids = ast_list(owner, rs);
      for (uint32_t k = 0; k < rs.len; k++) {
        const Node *const rn = ast_at_const(owner, rids[k]);
        const NodeId tn = rn->kind == NODE_PARAMETER ? rn->as.parameter.type : rids[k];
        reintern_nested_type(p, dest, owner, ast_type(owner, tn), owner->module, gids, args, nargs, changed);
      }
    }
  }
}

// True when `t` mentions a function VALUE type anywhere (a TYPE_FUNCTION, possibly nested): such a type
// names a specific fn/closure, whose C symbol (and env struct) is local to the module defining it.
static bool type_mentions_fnval(const Ast *a, const TypeId t) {
  const Ty *const y = ast_type_at(a, t);
  switch (y->kind) {
    case TYPE_FUNCTION:
      return true;
    case TYPE_POINTER:
    case TYPE_REFERENCE:
    case TYPE_SLICE:
    case TYPE_ARRAY:
      return type_mentions_fnval(a, y->as.elem);
    case TYPE_INSTANCE: {
      const TyInstance *const it = ast_instance(a, y->as.inst);
      for (uint8_t i = 0; i < it->n; i++)
        if (type_mentions_fnval(a, it->args[i]))
          return true;
      return false;
    }
    default:
      return false;
  }
}

// Re-intern `src`'s concrete cross-module generic instantiations into their HOME module's table (see
// instance_home): an all-builtin instance lands in the generic's owner (owner-emits), while one over a
// user type by value lands in that type's module, which emits it via the generic's DECLARE/DEFINE macros.
// Returns true if any table grew (drives the fixpoint in package_propagate_instances).
static bool reintern_cross_module(Package *p, Ast *const src, Ast *const standalone) {
  bool changed = false;
  const size_t n = src->instances.len; // snapshot: entries added this pass are caught next round
  for (size_t i = 0; i < n; i++) {
    const TyInstance it = src->instances.data[i]; // copy: the dest table may realloc below
    bool concrete = true;
    for (uint8_t k = 0; k < it.n; k++)
      concrete &= ast_type_concrete(src, it.args[k]);
    if (!concrete)
      continue;
    const ModuleId home = instance_home(p, src, &it);
    Ast *const dest = home < p->count                            ? p->modules[home].ast
                      : standalone && standalone->module == home ? standalone
                                                                 : NULL;
    if (!dest)
      continue;
    const uint8_t n = it.n < 4 ? it.n : 4; // a TyInstance holds at most 4 args (ast_intern_instance clamps)
    TypeId na[4];
    for (uint8_t k = 0; k < n; k++)
      na[k] = dest == src ? it.args[k] : ast_reintern(dest, src, it.args[k]);
    if (dest != src) {
      const size_t before = dest->instances.len;
      ast_intern_instance(dest, it.module, it.decl, na, n);
      changed |= dest->instances.len != before;
    }
    reintern_nested_instance_deps(p, dest, &it, na, n, &changed);
    reintern_method_signature_deps(p, dest, &it, na, n, &changed);
  }
  return changed;
}

// Record `src`'s generic-method calls (a method with its own generic params, e.g. `map<U>`) into the
// method's OWNING module, so that owner emits the matching `Inst__method__targs` specialization. The
// receiver instance and the method's own type args are reinterned across pools. Returns true on growth.
static bool reintern_method_insts(Package *p, Ast *const src, Ast *const standalone) {
  bool changed = false;
  const size_t n = src->nodes.len;
  for (NodeId i = 0; i < n; i++) {
    const Node *const call = ast_at_const(src, i);
    if (call->kind != NODE_CALL)
      continue;
    const Node *const callee = ast_at_const(src, call->as.call.callee);
    if (callee->kind != NODE_MEMBER)
      continue;
    const DefId md = ast_resolution_def(src, callee->as.member.member);
    if (md.node == NODE_NONE)
      continue;
    Ast *const owner = md.module < p->count && p->modules[md.module].ast ? p->modules[md.module].ast
                       : md.module == src->module                        ? src
                                                                         : NULL;
    if (!owner)
      continue;
    const Node *const mn = ast_at_const(owner, md.node);
    if (mn->kind != NODE_FUNCTION || mn->as.function.generics.len == 0)
      continue;
    const MonoUse *const mu = ast_type_args(src, i);
    if (!mu || mu->n == 0)
      continue;
    TypeId rty = ast_type(src, callee->as.member.object); // receiver / `Type::<Args>` base type
    for (const Ty *y = ast_type_at(src, rty); y->kind == TYPE_POINTER || y->kind == TYPE_REFERENCE;
         y = ast_type_at(src, rty))
      rty = y->as.elem;
    if (ast_type_at(src, rty)->kind != TYPE_INSTANCE || !ast_type_concrete(src, rty))
      continue;
    const uint8_t mtn = mu->n < 4 ? mu->n : 4; // MonoUse carries at most 4 method type args
    bool concrete = true;
    for (uint8_t k = 0; k < mtn; k++)
      concrete &= ast_type_concrete(src, mu->args[k]);
    if (!concrete)
      continue;
    // Emit the specialization where the receiver instance lives: its home (a user module for an instance
    // over a user type by value, else the owner). This keeps map<U> over Option<Bar> with the re-homed
    // Option<Bar> instead of re-adding it to the owner (which can only forward-declare Bar).
    const TyInstance recv = *ast_instance(src, ast_type_at(src, rty)->as.inst);
    const ModuleId home = instance_home(p, src, &recv);
    Ast *dest = home < p->count                            ? p->modules[home].ast
                : standalone && standalone->module == home ? standalone
                                                           : owner;
    if (!dest)
      continue;
    // A method type arg naming a function VALUE (a closure bound to an `F: fn(..)` param) exists only in
    // the calling module's TU: keep the use HERE, where codegen emits the spec static
    // (emit_local_method_insts) instead of asking the owner to reference a foreign static symbol.
    for (uint8_t k = 0; k < mtn; k++)
      if (type_mentions_fnval(src, mu->args[k])) {
        dest = src;
        break;
      }
    const TypeId rinst = dest == src ? rty : ast_reintern(dest, src, rty);
    TypeId targs[4];
    for (uint8_t k = 0; k < mtn; k++)
      targs[k] = dest == src ? mu->args[k] : ast_reintern(dest, src, mu->args[k]);
    changed |= ast_add_method_inst(dest, rinst, md.node, targs, mtn);
  }
  return changed;
}

void package_propagate_instances(Package *p, Ast *const standalone) {
  bool changed = true;
  while (changed) {
    changed = false;
    for (size_t u = 0; u < p->count; u++)
      if (p->modules[u].ast) {
        changed |= reintern_cross_module(p, p->modules[u].ast, standalone);
        changed |= reintern_method_insts(p, p->modules[u].ast, standalone);
      }
    if (standalone) {
      changed |= reintern_cross_module(p, standalone, standalone);
      changed |= reintern_method_insts(p, standalone, standalone);
    }
  }
}
