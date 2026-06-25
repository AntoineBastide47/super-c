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
// finds <std_root>/std/x.spc). Returns the first path that exists, else the project-relative path (so a
// not-found error names the project location). Heap-allocated; caller owns it.
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
  return root_rel;
}

// Lex + parse one module's source into an Ast, printing diagnostics; NULL on a lex/parse error.
static Ast *parse_source(const char *source, const size_t len) {
  Lexer *lexer = lexer_new(source, len);
  lexer_scan_tokens(lexer);
  if (lexer_has_errors(lexer)) {
    lexer_log_errors(lexer);
    lexer_free(&lexer);
    return NULL;
  }
  Parser *parser = parser_new(lexer_take_tokens(lexer), source, len);
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

  Ast *const ast = parse_source(source, len);
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

Package *package_load(const char *root_file, const char *std_dir) {
  Package *const p = calloc(1, sizeof *p);
  p->ok = true;
  p->root_dir = dir_of(root_file);
  p->std_root = std_dir ? dir_of(std_dir) : NULL; // `import std::x;` -> <std_root>/std/x.spc
  load_module(p, stem_of(root_file), strdup(root_file));
  load_prelude(p, std_dir);
  return p;
}

Package *package_prelude_only(const char *std_dir) {
  Package *const p = calloc(1, sizeof *p);
  p->ok = true;
  p->root_dir = strdup(std_dir ? std_dir : ".");
  p->std_root = std_dir ? dir_of(std_dir) : NULL;
  load_prelude(p, std_dir);
  return p;
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
    } else if (n->kind == NODE_FUNCTION) {
      name_node = n->as.function.name;
      is_pub = n->as.function.is_public;
      is_type = false;
    } else if (n->kind == NODE_CONST) {
      name_node = n->as.const_def.name;
      is_pub = n->as.const_def.is_public;
      is_type = false;
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

// Re-intern `src`'s concrete cross-module generic instantiations into their owning modules' tables.
// Returns true if any owner table grew (drives the fixpoint in package_propagate_instances).
static bool reintern_cross_module(Package *p, Ast *const src) {
  bool changed = false;
  const size_t n = src->instances.len; // snapshot: entries added this pass are caught next round
  for (size_t i = 0; i < n; i++) {
    const TyInstance it = src->instances.data[i]; // copy: the owner table may realloc below
    if (it.module == src->module || it.module >= p->count || !p->modules[it.module].ast)
      continue;
    bool concrete = true;
    for (uint8_t k = 0; k < it.n; k++)
      concrete &= ast_type_concrete(src, it.args[k]);
    if (!concrete)
      continue;
    Ast *const owner = p->modules[it.module].ast;
    if (owner == src)
      continue;
    const size_t before = owner->instances.len;
    TypeId na[4];
    for (uint8_t k = 0; k < it.n; k++)
      na[k] = ast_reintern(owner, src, it.args[k]);
    ast_intern_instance(owner, it.module, it.decl, na, it.n);
    changed |= owner->instances.len != before;
  }
  return changed;
}

// Record `src`'s generic-method calls (a method with its own generic params, e.g. `map<U>`) into the
// method's OWNING module, so that owner emits the matching `Inst__method__targs` specialization. The
// receiver instance and the method's own type args are reinterned across pools. Returns true on growth.
static bool reintern_method_insts(Package *p, Ast *const src) {
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
    bool concrete = true;
    for (uint8_t k = 0; k < mu->n; k++)
      concrete &= ast_type_concrete(src, mu->args[k]);
    if (!concrete)
      continue;
    const TypeId rinst = owner == src ? rty : ast_reintern(owner, src, rty);
    TypeId targs[4];
    for (uint8_t k = 0; k < mu->n && k < 4; k++)
      targs[k] = owner == src ? mu->args[k] : ast_reintern(owner, src, mu->args[k]);
    changed |= ast_add_method_inst(owner, rinst, md.node, targs, mu->n);
  }
  return changed;
}

void package_propagate_instances(Package *p, Ast *const standalone) {
  bool changed = true;
  while (changed) {
    changed = false;
    for (size_t u = 0; u < p->count; u++)
      if (p->modules[u].ast) {
        changed |= reintern_cross_module(p, p->modules[u].ast);
        changed |= reintern_method_insts(p, p->modules[u].ast);
      }
    if (standalone) {
      changed |= reintern_cross_module(p, standalone);
      changed |= reintern_method_insts(p, standalone);
    }
  }
}
