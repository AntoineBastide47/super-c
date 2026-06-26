#include "resolver.h"

#include <stdlib.h>
#include <stdint.h>
#include <string.h>

#include "module/loader.h"
#include "symbol.h"
#include "types/hashmap.h"

static inline size_t symbol_key_hash(const uint64_t key) {
  uint64_t x = key;
  x ^= x >> 30;
  x *= UINT64_C(0xbf58476d1ce4e5b9);
  x ^= x >> 27;
  x *= UINT64_C(0x94d049bb133111eb);
  x ^= x >> 31;
  return (size_t)x;
}
#define SYMBOL_KEY_EQ(a, b) ((a) == (b))
HM_DECLARE(uint64_t, uint32_t, SymbolIndex)
HM_DEFINE(uint64_t, uint32_t, SymbolIndex, symbol_key_hash, SYMBOL_KEY_EQ)

struct Resolver {
    Ast *ast;
    const uint8_t *source;
    size_t len;
    Symbol_Vec symbols;   // flat stack of live symbols across all open scopes
    U32_Vec symbol_previous; // chain links parallel to symbols, encoded as index + 1
    U32_Vec scope_starts; // stack of symbols.len at each scope entry
    SymbolIndex symbol_index; // (namespace, name hash) -> newest matching symbol index + 1
    NodeId current_self;  // type 'Self' refers to inside the current interface/extension (else NODE_NONE)
    bool in_closure;      // resolving inside a closure body: outer-local value refs are captures (rejected)
    bool in_generic;      // resolving inside a generic fn/impl: closures here can't be monomorphized yet
    uint32_t closure_floor; // symbols.len at the innermost closure entry; refs below it are captures
    const Package *package; // for resolving `import`ed module-qualified names (NULL = no imports)
    ERRORS_VARIABLES;
};

static void resolve_item(Resolver *r, NodeId id);
static void resolve_type(Resolver *r, NodeId id);
static void resolve_block(Resolver *r, NodeId id);
static void resolve_stmt(Resolver *r, NodeId id);
static void resolve_expr(Resolver *r, NodeId id);
static void resolve_pattern(Resolver *r, NodeId id);
static int import_target(const Resolver *r, NodeList parts);

Resolver *resolver_new(Ast *ast, const char *source, const size_t len, const Package *package) {
  Resolver *const r = calloc(1, sizeof *r);
  if (!r) {
    fprintf(stderr, "fatal: out of memory\n");
    abort();
  }
  r->ast = ast;
  r->source = (const uint8_t *)source;
  r->len = len;
  r->package = package;
  r->symbols = Symbol_Vec_init();
  r->symbol_previous = U32_Vec_init();
  r->scope_starts = U32_Vec_init();
  ERRORS_INIT(r);
  return r;
}

void resolver_free(Resolver **r) {
  if (!r || !*r)
    return;
  ast_free(&(*r)->ast);
  VEC_DEINIT((*r)->symbols);
  VEC_DEINIT((*r)->symbol_previous);
  VEC_DEINIT((*r)->scope_starts);
  SymbolIndex_deinit(&(*r)->symbol_index);
  ERRORS_DEINIT(r);
  free(*r);
  *r = NULL;
}

Ast *resolver_take_ast(Resolver *r) {
  Ast *const ast = r->ast;
  r->ast = NULL;
  return ast;
}

ALWAYS_INLINE uint32_t name_hash(const uint8_t *const src, const Span s) {
  uint32_t h = 2166136261u;
  for (uint32_t i = s.start; i < s.end; i++) {
    h ^= src[i];
    h *= 16777619u;
  }
  return h;
}

ALWAYS_INLINE bool span_eq(const uint8_t *const src, const Span a, const Span b) {
  const uint32_t la = a.end - a.start;
  return la == b.end - b.start && memcmp(src + a.start, src + b.start, la) == 0;
}

ALWAYS_INLINE bool span_is(const uint8_t *const src, const Span s, const char *const lit) {
  const size_t n = strlen(lit);
  return (size_t)(s.end - s.start) == n && memcmp(src + s.start, lit, n) == 0;
}

// The only predefined type names; see SuperC-Specs.html section 6.2. Pointer/reference
// forms (*void, &u8, ...) need no entry: they wrap one of these, which resolves on its own.
static bool is_builtin_type(const uint8_t *const src, const Span s) {
  static const char *const builtins[] = {
      "bool", "char", "i8",  "i16",   "i32", "i64", "isize", "u8",
      "u16",  "u32",  "u64", "usize", "f32", "f64", "c32", "c64", "va_list", "void",
  };
  for (size_t i = 0; i < sizeof builtins / sizeof builtins[0]; i++)
    if (span_is(src, s, builtins[i]))
      return true;
  return false;
}

ALWAYS_INLINE Span name_span(const Resolver *r, const NodeId name_node) {
  return ast_at_const(r->ast, name_node)->as.name.text;
}

ALWAYS_INLINE void scope_enter(Resolver *r) {
  U32_Vec_push(&r->scope_starts, (uint32_t)r->symbols.len);
}

ALWAYS_INLINE uint64_t symbol_key(const uint32_t hash, const Namespace ns) {
  return ((uint64_t)(uint32_t)ns << 32) | hash;
}

static void scope_exit(Resolver *r) {
  const size_t start = r->scope_starts.data[--r->scope_starts.len];
  while (r->symbols.len > start) {
    const size_t index = --r->symbols.len;
    const Symbol *const s = &r->symbols.data[index];
    const uint32_t previous = r->symbol_previous.data[index];
    const uint64_t key = symbol_key(s->hash, (Namespace)token_type(s->name));
    if (previous)
      SymbolIndex_insert(&r->symbol_index, key, previous);
    else
      SymbolIndex_remove(&r->symbol_index, key);
  }
  r->symbol_previous.len = start;
}

static void declare(Resolver *r, const NodeId name_node, const NodeId decl, const Namespace ns) {
  if (name_node == NODE_NONE)
    return;
  const Span name = name_span(r, name_node);
  const uint32_t hash = name_hash(r->source, name);
  const uint64_t key = symbol_key(hash, ns);
  uint32_t head = 0;
  SymbolIndex_get(&r->symbol_index, key, &head);
  const size_t scope_start = r->scope_starts.data[r->scope_starts.len - 1];
  for (uint32_t current = head; current; current = r->symbol_previous.data[current - 1]) {
    const size_t i = current - 1;
    if (i < scope_start)
      break;
    const Symbol *const s = &r->symbols.data[i];
    if (span_eq(r->source, token_span(s->name), name)) {
      resolver_errorf(
          r, name.start, name.end - name.start, "duplicate definition of '%.*s'", (int)(name.end - name.start),
          r->source + name.start);
      return;
    }
  }
  Symbol_Vec_push(
      &r->symbols,
      (Symbol){
          .hash = hash,
          .decl = decl,
          .name = token_new((TokenType)ns, name.start, name.end - name.start),
      });
  U32_Vec_push(&r->symbol_previous, head);
  SymbolIndex_insert(&r->symbol_index, key, (uint32_t)r->symbols.len);
}

// `out_idx` (nullable) receives the matched symbol's 1-based stack position -- used to tell whether a
// reference inside a closure binds to a variable declared OUTSIDE it (a capture).
static NodeId lookup(const Resolver *r, const Span name, const Namespace ns, uint32_t *const out_idx) {
  const uint32_t hash = name_hash(r->source, name);
  uint32_t current = 0;
  if (!SymbolIndex_get(&r->symbol_index, symbol_key(hash, ns), &current))
    return NODE_NONE;
  while (current) {
    const Symbol *const s = &r->symbols.data[current - 1];
    if (span_eq(r->source, token_span(s->name), name)) {
      if (out_idx)
        *out_idx = current;
      return s->decl;
    }
    current = r->symbol_previous.data[current - 1];
  }
  return NODE_NONE;
}

// Look up `name` among the modules this module glob-imports (`import P as *;`): their public items are in
// scope unqualified here. Returns the decl and sets *out_mid, or NODE_NONE.
static NodeId glob_lookup(const Resolver *r, const Span name, const bool want_type, ModuleId *const out_mid) {
  if (!r->package)
    return NODE_NONE;
  const NodeList items = ast_at_const(r->ast, r->ast->root)->as.program.items;
  const NodeId *const ids = ast_list(r->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(r->ast, ids[i]);
    if (n->kind != NODE_IMPORT || !n->as.import_decl.glob)
      continue;
    const int m = import_target(r, n->as.import_decl.path);
    if (m < 0)
      continue;
    const NodeId d =
        package_lookup(r->package, (ModuleId)m, (const char *)r->source + name.start, name.end - name.start, want_type);
    if (d != NODE_NONE) {
      *out_mid = (ModuleId)m;
      return d;
    }
  }
  return NODE_NONE;
}

static void resolve_ref(Resolver *r, const NodeId ref, const NodeId name_node, const Namespace ns, const char *kind) {
  if (name_node == NODE_NONE)
    return;
  const Span name = name_span(r, name_node);
  uint32_t idx = 0;
  const NodeId decl = lookup(r, name, ns, &idx);
  if (decl != NODE_NONE) {
    // A value binding declared outside the enclosing closure would have to be captured; Stage-1 closures
    // are non-capturing, so reject it with a precise diagnostic. Module-level items (functions/consts) are
    // never captures, so only flag the local binding kinds.
    if (ns == NS_VALUE && r->in_closure && idx && idx - 1 < r->closure_floor) {
      const NodeKind dk = ast_at_const(r->ast, decl)->kind;
      if (dk == NODE_LET || dk == NODE_PARAMETER || dk == NODE_FOR || dk == NODE_IDENTIFIER)
        resolver_errorf(
            r, name.start, name.end - name.start,
            "closures cannot capture local variable '%.*s' (capturing closures are not yet supported)",
            (int)(name.end - name.start), r->source + name.start);
    }
    ast_set_resolution(r->ast, ref, decl);
    return;
  }
  if (ns == NS_TYPE && is_builtin_type(r->source, name))
    return;
  // Unqualified fallback: the std prelude (str, String, Slice, ... -- in scope everywhere) and this
  // module's glob imports (`import P as *;`). Record the cross-module decl for the type checker to follow.
  if (r->package) {
    ModuleId mid;
    const char *const nm = (const char *)r->source + name.start;
    const uint32_t nl = name.end - name.start;
    NodeId d = package_prelude_lookup(r->package, nm, nl, ns == NS_TYPE, &mid);
    if (d == NODE_NONE)
      d = glob_lookup(r, name, ns == NS_TYPE, &mid);
    if (d != NODE_NONE) {
      ast_set_resolution_def(r->ast, ref, (DefId){mid, d});
      return;
    }
  }
  resolver_errorf(
      r, name.start, name.end - name.start, "cannot find %s '%.*s'", kind, (int)(name.end - name.start),
      r->source + name.start);
}

// Join the first `count` identifier parts with "::" into `buf`; returns length, or -1 on overflow.
static int join_path(const Resolver *r, const NodeId *const parts, const uint32_t count, char *buf, const size_t cap) {
  size_t at = 0;
  for (uint32_t i = 0; i < count; i++) {
    const Span s = name_span(r, parts[i]);
    const size_t l = s.end - s.start;
    if (at + (i ? 2 : 0) + l >= cap)
      return -1;
    if (i) {
      buf[at++] = ':';
      buf[at++] = ':';
    }
    memcpy(buf + at, r->source + s.start, l);
    at += l;
  }
  buf[at] = '\0';
  return (int)at;
}

// The module id named by an import's path parts (its loaded "::"-joined path), or -1.
static int import_target(const Resolver *r, const NodeList parts) {
  char buf[512];
  const int n = join_path(r, ast_list(r->ast, parts), parts.len, buf, sizeof buf);
  return n < 0 ? -1 : package_find(r->package, buf, (size_t)n);
}

// True if `name` names an imported module usable as a single leading segment: its `as` alias, or a
// single-segment module path. Sets *mid to the target module.
static bool name_is_module(const Resolver *r, const Span name, ModuleId *const mid) {
  if (!r->package)
    return false;
  const NodeList items = ast_at_const(r->ast, r->ast->root)->as.program.items;
  const NodeId *const ids = ast_list(r->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(r->ast, ids[i]);
    if (n->kind != NODE_IMPORT)
      continue;
    const NodeId alias = n->as.import_decl.alias;
    const NodeList parts = n->as.import_decl.path;
    const bool hit = alias != NODE_NONE
                         ? span_eq(r->source, name_span(r, alias), name)
                         : parts.len == 1 && span_eq(r->source, name_span(r, ast_list(r->ast, parts)[0]), name);
    if (hit) {
      const int m = import_target(r, parts);
      if (m >= 0) {
        *mid = (ModuleId)m;
        return true;
      }
    }
  }
  return false;
}

// If a type path is module-qualified (`std::string::String` by full path, or `alias::Type`), return its
// module id and set *type_node to the final segment; otherwise -1.
static int module_qualified_type(const Resolver *r, const NodeList parts, NodeId *const type_node) {
  if (!r->package || parts.len < 2)
    return -1;
  const NodeId *const ids = ast_list(r->ast, parts);
  char buf[512];
  const int n = join_path(r, ids, parts.len - 1, buf, sizeof buf); // module = every segment but the last
  if (n >= 0) {
    const int m = package_find(r->package, buf, (size_t)n);
    if (m >= 0) {
      *type_node = ids[parts.len - 1];
      return m;
    }
  }
  ModuleId mid; // `alias::Type`
  if (parts.len == 2 && name_is_module(r, name_span(r, ids[0]), &mid)) {
    *type_node = ids[1];
    return (int)mid;
  }
  return -1;
}

// Resolve a public top-level decl `name` in module `mid` and record it (cross-module) on `ref`.
static void resolve_module_decl(Resolver *r, const NodeId ref, const ModuleId mid, const Span name,
                                const bool want_type, const char *const kind) {
  const NodeId decl = package_lookup(r->package, mid, (const char *)r->source + name.start, name.end - name.start, want_type);
  if (decl != NODE_NONE)
    ast_set_resolution_def(r->ast, ref, (DefId){mid, decl});
  else
    resolver_errorf(
        r, name.start, name.end - name.start, "no public %s '%.*s' in the imported module", kind,
        (int)(name.end - name.start), r->source + name.start);
}

// Resolve a path-member expression `id` (node `n`) as `<module>::<decl>` where the module may be MANY
// segments (`test::test::func`, `std::net::tcp::Connect`, `foo::Type::method`). Flattens the `::` chain,
// matches the longest loaded-module prefix, and records the cross-module DefId so the type checker and
// codegen treat it exactly like any qualified reference. Returns true if a module prefix matched (it has
// then handled or errored on `n`); false to let the caller try alias / local `Type::` resolution.
static bool resolve_qualified_member(Resolver *r, const NodeId id) {
  if (!r->package)
    return false;
  NodeId chain[16]; // the `::` member nodes, outermost..innermost; must bottom out at a base identifier
  uint32_t cc = 0;
  NodeId base = NODE_NONE;
  for (NodeId curid = id;;) {
    const Node *const cn = ast_at_const(r->ast, curid);
    if (cn->kind != NODE_MEMBER || !cn->as.member.path || cc >= 16)
      return false;
    chain[cc++] = curid;
    const NodeId o = cn->as.member.object;
    const Node *const on = ast_at_const(r->ast, o);
    if (on->kind == NODE_IDENTIFIER) {
      base = o;
      break;
    }
    if (on->kind != NODE_MEMBER || !on->as.member.path)
      return false;
    curid = o;
  }
  const uint32_t N = cc + 1; // segment count: base + one per chain link
  NodeId seg[17];            // segment name nodes, base..outer; chain[N-1-i] introduces seg[i] (i>=1)
  seg[0] = base;
  for (uint32_t i = 1; i < N; i++)
    seg[i] = ast_at_const(r->ast, chain[N - 1 - i])->as.member.member;
  char buf[512];
  for (uint32_t m = N - 1; m >= 1; m--) { // longest module prefix leaving >=1 trailing segment
    const int len = join_path(r, seg, m, buf, sizeof buf);
    if (len < 0)
      continue;
    const int found = package_find(r->package, buf, (size_t)len);
    if (found < 0)
      continue;
    const ModuleId mid = (ModuleId)found;
    if (N - m == 1) { // module::decl -- a function (preferred) or type, recorded on the callee node
      const Span dn = name_span(r, seg[m]);
      NodeId decl = package_lookup(r->package, mid, (const char *)r->source + dn.start, dn.end - dn.start, false);
      if (decl == NODE_NONE)
        decl = package_lookup(r->package, mid, (const char *)r->source + dn.start, dn.end - dn.start, true);
      if (decl != NODE_NONE)
        ast_set_resolution_def(r->ast, id, (DefId){mid, decl});
      else
        resolver_errorf(r, dn.start, dn.end - dn.start, "no public item '%.*s' in module '%s'",
                        (int)(dn.end - dn.start), r->source + dn.start, buf);
      return true;
    }
    if (N - m == 2) { // module::Type::method -- record the Type; the type checker binds the method
      resolve_module_decl(r, chain[1], mid, name_span(r, seg[m]), true, "type");
      return true;
    }
    return false; // deeper than module::Type::method is not supported here
  }
  return false;
}

static void resolve_bounds(Resolver *r, const NodeList bounds) {
  const NodeId *const ids = ast_list(r->ast, bounds);
  for (uint32_t i = 0; i < bounds.len; i++)
    resolve_type(r, ids[i]);
}

static void declare_generics(Resolver *r, const NodeList generics) {
  const NodeId *const ids = ast_list(r->ast, generics);
  for (uint32_t i = 0; i < generics.len; i++)
    declare(r, ast_at_const(r->ast, ids[i])->as.generic_param.name, ids[i], NS_TYPE);
  // Bounds are resolved after every parameter is in scope so they may refer to each other.
  for (uint32_t i = 0; i < generics.len; i++)
    resolve_bounds(r, ast_at_const(r->ast, ids[i])->as.generic_param.bounds);
}

static void resolve_where(Resolver *r, const NodeList where_clause) {
  const NodeId *const ids = ast_list(r->ast, where_clause);
  for (uint32_t i = 0; i < where_clause.len; i++) {
    const Node *const w = ast_at_const(r->ast, ids[i]);
    resolve_type(r, w->as.where_predicate.type);
    resolve_bounds(r, w->as.where_predicate.bounds);
  }
}

static void resolve_type(Resolver *r, const NodeId id) {
  if (id == NODE_NONE)
    return;
  const Node *const n = ast_at_const(r->ast, id);
  switch (n->kind) {
    case NODE_TYPE_PATH: {
      const NodeList parts = n->as.type_path.parts;
      NodeId type_node;
      const int mid = module_qualified_type(r, parts, &type_node);
      if (mid >= 0) {
        resolve_module_decl(r, id, (ModuleId)mid, name_span(r, type_node), true, "type");
        const NodeList margs = n->as.type_path.args;
        const NodeId *const marg_ids = ast_list(r->ast, margs);
        for (uint32_t i = 0; i < margs.len; i++)
          resolve_type(r, marg_ids[i]);
        break;
      }
      if (parts.len > 0) {
        const NodeId first = ast_list(r->ast, parts)[0];
        const Span name = name_span(r, first);
        if (span_is(r->source, name, "Self")) {
          if (r->current_self != NODE_NONE)
            ast_set_resolution(r->ast, id, r->current_self);
          else
            resolver_errorf(
                r, name.start, name.end - name.start, "'Self' is only valid inside an interface or extension");
        } else {
          resolve_ref(r, id, first, NS_TYPE, "type"); // trailing path segments are resolved by the type checker
        }
      }
      const NodeList args = n->as.type_path.args;
      const NodeId *const arg_ids = ast_list(r->ast, args);
      for (uint32_t i = 0; i < args.len; i++)
        resolve_type(r, arg_ids[i]);
      break;
    }
    case NODE_POINTER_TYPE:
    case NODE_REFERENCE_TYPE:
    case NODE_SLICE_TYPE:
      resolve_type(r, n->as.indirect_type.type);
      break;
    case NODE_ARRAY_TYPE:
      resolve_type(r, n->as.array_type.element);
      resolve_expr(r, n->as.array_type.length);
      break;
    case NODE_FUNCTION_TYPE: {
      const NodeList params = n->as.function_type.params;
      const NodeId *const pids = ast_list(r->ast, params);
      for (uint32_t i = 0; i < params.len; i++)
        resolve_type(r, pids[i]);
      const NodeList returns = n->as.function_type.returns;
      const NodeId *const rids = ast_list(r->ast, returns);
      for (uint32_t i = 0; i < returns.len; i++)
        resolve_type(r, rids[i]);
      break;
    }
    default:
      break;
  }
}

// A struct-initializer / new target may be written as a bare identifier or a full type path.
static void resolve_type_name(Resolver *r, const NodeId id) {
  if (id == NODE_NONE)
    return;
  if (ast_at_const(r->ast, id)->kind == NODE_IDENTIFIER)
    resolve_ref(r, id, id, NS_TYPE, "type");
  else
    resolve_type(r, id);
}

static void resolve_function(Resolver *r, const NodeId id) {
  const Node *const n = ast_at_const(r->ast, id);
  const NodeList generics = n->as.function.generics;
  const NodeList params = n->as.function.params;
  const NodeList returns = n->as.function.returns;
  const NodeList where_clause = n->as.function.where_clause;
  const NodeId body = n->as.function.body;

  const bool saved_generic = r->in_generic;
  r->in_generic = saved_generic || generics.len > 0;
  scope_enter(r);
  declare_generics(r, generics);
  const NodeId *const pids = ast_list(r->ast, params);
  for (uint32_t i = 0; i < params.len; i++) {
    const Node *const param = ast_at_const(r->ast, pids[i]);
    declare(r, param->as.parameter.name, pids[i], NS_VALUE);
    resolve_type(r, param->as.parameter.type);
  }
  const NodeId *const rids = ast_list(r->ast, returns);
  for (uint32_t i = 0; i < returns.len; i++) {
    const Node *const ret = ast_at_const(r->ast, rids[i]);
    resolve_type(r, ret->kind == NODE_PARAMETER ? ret->as.parameter.type : rids[i]);
  }
  resolve_where(r, where_clause);
  if (body != NODE_NONE)
    resolve_block(r, body);
  scope_exit(r);
  r->in_generic = saved_generic;
}

static void resolve_type_alias(Resolver *r, const NodeId id) {
  const Node *const n = ast_at_const(r->ast, id);
  scope_enter(r);
  declare_generics(r, n->as.type_alias.generics);
  resolve_type(r, n->as.type_alias.type);
  scope_exit(r);
}

static void resolve_members(Resolver *r, const NodeList members) {
  const NodeId *const ids = ast_list(r->ast, members);
  for (uint32_t i = 0; i < members.len; i++) {
    const Node *const m = ast_at_const(r->ast, ids[i]);
    if (m->kind == NODE_FIELD) {
      declare(r, m->as.field.name, ids[i], NS_VALUE); // catches duplicate field names within the aggregate
      resolve_type(r, m->as.field.type);
    } else { // NODE_VARIANT
      declare(r, m->as.variant.name, ids[i], NS_VALUE);
      resolve_expr(r, m->as.variant.value); // explicit discriminant (NODE_NONE when absent)
      const NodeList payload = m->as.variant.payload;
      const NodeId *const payload_ids = ast_list(r->ast, payload);
      for (uint32_t j = 0; j < payload.len; j++) {
        const Node *const pe = ast_at_const(r->ast, payload_ids[j]);
        resolve_type(r, pe->kind == NODE_FIELD ? pe->as.field.type : payload_ids[j]);
      }
    }
  }
}

static void resolve_associated_items(Resolver *r, const NodeList items) {
  const NodeId *const ids = ast_list(r->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const NodeKind kind = ast_at_const(r->ast, ids[i])->kind;
    if (kind == NODE_FUNCTION)
      resolve_function(r, ids[i]);
    else if (kind == NODE_TYPE_ALIAS)
      resolve_type_alias(r, ids[i]);
  }
}

static void resolve_item(Resolver *r, const NodeId id) {
  const Node *const n = ast_at_const(r->ast, id);
  switch (n->kind) {
    case NODE_FUNCTION:
      resolve_function(r, id);
      break;
    case NODE_STRUCT:
    case NODE_ENUM:
      scope_enter(r);
      declare_generics(r, n->as.aggregate.generics);
      resolve_members(r, n->as.aggregate.members);
      scope_exit(r);
      break;
    case NODE_TRAIT: {
      scope_enter(r);
      declare_generics(r, n->as.trait_def.generics);
      resolve_bounds(r, n->as.trait_def.bounds);
      const NodeId old_self = r->current_self;
      r->current_self = id;
      resolve_associated_items(r, n->as.trait_def.items);
      r->current_self = old_self;
      scope_exit(r);
      break;
    }
    case NODE_IMPL: {
      const NodeId target = n->as.impl_def.target_type;
      scope_enter(r);
      declare_generics(r, n->as.impl_def.generics);
      resolve_type(r, target);
      resolve_type(r, n->as.impl_def.trait_type);
      const NodeId old_self = r->current_self;
      const NodeId resolved = target == NODE_NONE ? NODE_NONE : ast_resolution(r->ast, target);
      r->current_self = resolved != NODE_NONE ? resolved : id;
      const bool saved_generic = r->in_generic;
      r->in_generic = saved_generic || n->as.impl_def.generics.len > 0; // methods inherit the impl's generics
      resolve_associated_items(r, n->as.impl_def.items);
      r->in_generic = saved_generic;
      r->current_self = old_self;
      scope_exit(r);
      break;
    }
    case NODE_TYPE_ALIAS:
      resolve_type_alias(r, id);
      break;
    case NODE_CONST:
      resolve_type(r, n->as.const_def.type);
      resolve_expr(r, n->as.const_def.value);
      break;
    case NODE_EXTERN_BLOCK:
      resolve_associated_items(r, n->as.extern_block.items);
      break;
    case NODE_STATIC_ASSERT:
      resolve_expr(r, n->as.binary.left); // the message (right) is a string literal: nothing to resolve
      break;
    default:
      break;
  }
}

static void resolve_if(Resolver *r, const Node *const n) {
  resolve_expr(r, n->as.if_stmt.condition);
  resolve_stmt(r, n->as.if_stmt.then_branch);
  resolve_stmt(r, n->as.if_stmt.else_branch); // block, else-if, or NODE_NONE
}

static void resolve_block(Resolver *r, const NodeId id) {
  const NodeList stmts = ast_at_const(r->ast, id)->as.block.statements;
  scope_enter(r);
  const NodeId *const ids = ast_list(r->ast, stmts);
  for (uint32_t i = 0; i < stmts.len; i++)
    resolve_stmt(r, ids[i]);
  scope_exit(r);
}

static void resolve_stmt(Resolver *r, const NodeId id) {
  if (id == NODE_NONE)
    return;
  const Node *const n = ast_at_const(r->ast, id);
  switch (n->kind) {
    case NODE_BLOCK:
      resolve_block(r, id);
      break;
    case NODE_LET: {
      resolve_type(r, n->as.let_stmt.type);
      resolve_expr(r, n->as.let_stmt.value);
      const Node *const nm = ast_at_const(r->ast, n->as.let_stmt.name);
      if (nm->kind == NODE_PATTERN_TUPLE) { // `let (a, b) = ..`: each element declares itself
        const NodeId *const cids = ast_list(r->ast, nm->as.pattern.children);
        for (uint32_t i = 0; i < nm->as.pattern.children.len; i++) {
          declare(r, cids[i], cids[i], NS_VALUE);
          ast_set_resolution(r->ast, cids[i], id); // back-point to the let so mutability is recoverable
        }
      } else {
        declare(r, n->as.let_stmt.name, id, NS_VALUE); // bound only after its initializer
      }
      break;
    }
    case NODE_CONST:
      resolve_type(r, n->as.const_def.type);
      resolve_expr(r, n->as.const_def.value);
      declare(r, n->as.const_def.name, id, NS_VALUE);
      break;
    case NODE_RETURN: {
      const NodeList values = n->as.return_stmt.values;
      const NodeId *const ids = ast_list(r->ast, values);
      for (uint32_t i = 0; i < values.len; i++)
        resolve_expr(r, ids[i]);
      break;
    }
    case NODE_DEFER:
      resolve_expr(r, n->as.single.value); // block or expression
      break;
    case NODE_IF:
      resolve_if(r, n);
      break;
    case NODE_WHILE:
      resolve_expr(r, n->as.while_stmt.condition);
      resolve_block(r, n->as.while_stmt.body);
      break;
    case NODE_FOR:
      resolve_expr(r, n->as.for_stmt.iterable); // evaluated before the binding is in scope
      scope_enter(r);
      declare(r, n->as.for_stmt.binding, id, NS_VALUE);
      resolve_block(r, n->as.for_stmt.body);
      scope_exit(r);
      break;
    case NODE_EXPRESSION_STATEMENT:
      resolve_expr(r, n->as.single.value);
      break;
    case NODE_STATIC_ASSERT:
      resolve_expr(r, n->as.binary.left);
      break;
    default: // NODE_BREAK, NODE_CONTINUE
      break;
  }
}

static void resolve_expr(Resolver *r, const NodeId id) {
  if (id == NODE_NONE)
    return;
  const Node *const n = ast_at_const(r->ast, id);
  switch (n->kind) {
    case NODE_IDENTIFIER:
      resolve_ref(r, id, id, NS_VALUE, "value"); // also covers 'self'
      break;
    case NODE_UNARY:
      resolve_expr(r, n->as.unary.operand);
      break;
    case NODE_BINARY:
    case NODE_ASSIGNMENT:
      resolve_expr(r, n->as.binary.left);
      resolve_expr(r, n->as.binary.right);
      break;
    case NODE_CALL: {
      resolve_expr(r, n->as.call.callee);
      const NodeList args = n->as.call.args;
      const NodeId *const ids = ast_list(r->ast, args);
      for (uint32_t i = 0; i < args.len; i++)
        resolve_expr(r, ids[i]);
      break;
    }
    case NODE_INDEX:
      resolve_expr(r, n->as.index.object);
      resolve_expr(r, n->as.index.index);
      break;
    case NODE_MEMBER: {
      // A full module-PATH qualifier (`mod::f`, `a::b::f`, `a::b::Type::method`) -- possibly many
      // segments -- is resolved here against the loaded modules. `Enum::Variant` / local `Type::method` /
      // an `as`-alias fall through to the cases below; a `.`/`->` access resolves its object as a value.
      if (n->as.member.path && resolve_qualified_member(r, id))
        break;
      const NodeId obj = n->as.member.object;
      ModuleId mid;
      if (n->as.member.path && ast_at_const(r->ast, obj)->kind == NODE_IDENTIFIER &&
          name_is_module(r, name_span(r, obj), &mid)) {
        const Span mn = name_span(r, n->as.member.member);
        // A value (function) export takes priority; otherwise a type (e.g. `mod::Type::method`).
        const char *const nm = (const char *)r->source + mn.start;
        const uint32_t nl = mn.end - mn.start;
        NodeId decl = package_lookup(r->package, mid, nm, nl, false);
        if (decl != NODE_NONE)
          ast_set_resolution_def(r->ast, id, (DefId){mid, decl});
        else
          resolve_module_decl(r, id, mid, mn, true, "item");
      } else if (n->as.member.path && ast_at_const(r->ast, obj)->kind == NODE_IDENTIFIER) {
        resolve_ref(r, obj, obj, NS_TYPE, "type");
      } else {
        resolve_expr(r, obj); // member name needs a type; deferred to the type checker
      }
      break;
    }
    case NODE_CAST:
      resolve_expr(r, n->as.cast.expression);
      resolve_type(r, n->as.cast.type);
      break;
    case NODE_SIZEOF:
      resolve_type(r, n->as.single.value);
      break;
    case NODE_VA_EXPR:
      resolve_expr(r, n->as.va_op.ap);
      if (n->as.va_op.op == VA_ARG)
        resolve_type(r, n->as.va_op.extra); // the read-out type
      else if (n->as.va_op.op == VA_START)
        resolve_expr(r, n->as.va_op.extra); // the last named parameter
      break;
    case NODE_GENERIC_SPECIALIZATION: {
      // A turbofish base is a generic FUNCTION (value, `f::<T>()`) or a generic TYPE
      // (`Opt::<i32>::Some(..)`, possibly a prelude type). Only a generic function is a local value, so
      // anything else (local type, builtin, or prelude/glob type) resolves in the type namespace.
      const NodeId inner = n->as.specialization.expression;
      if (ast_at_const(r->ast, inner)->kind == NODE_IDENTIFIER && lookup(r, name_span(r, inner), NS_VALUE, NULL) == NODE_NONE)
        resolve_ref(r, inner, inner, NS_TYPE, "type");
      else
        resolve_expr(r, inner);
      const NodeList types = n->as.specialization.types;
      const NodeId *const ids = ast_list(r->ast, types);
      for (uint32_t i = 0; i < types.len; i++)
        resolve_type(r, ids[i]);
      break;
    }
    case NODE_MATCH: {
      resolve_expr(r, n->as.match_expr.value);
      const NodeList arms = n->as.match_expr.arms;
      const NodeId *const ids = ast_list(r->ast, arms);
      for (uint32_t i = 0; i < arms.len; i++) {
        const Node *const arm = ast_at_const(r->ast, ids[i]);
        scope_enter(r);
        resolve_pattern(r, arm->as.match_arm.pattern);
        resolve_expr(r, arm->as.match_arm.guard);
        resolve_expr(r, arm->as.match_arm.body);
        scope_exit(r);
      }
      break;
    }
    case NODE_NEW:
      if (n->as.new_expr.initializer != NODE_NONE)
        resolve_expr(r, n->as.new_expr.initializer); // resolves the shared type node
      else
        resolve_type(r, n->as.new_expr.type);
      break;
    case NODE_ARRAY_LITERAL: {
      const NodeList elements = n->as.array_literal.elements;
      const NodeId *const ids = ast_list(r->ast, elements);
      for (uint32_t i = 0; i < elements.len; i++)
        resolve_expr(r, ids[i]);
      break;
    }
    case NODE_STRUCT_INITIALIZER: {
      resolve_type_name(r, n->as.struct_initializer.type);
      const NodeList fields = n->as.struct_initializer.fields;
      const NodeId *const ids = ast_list(r->ast, fields);
      for (uint32_t i = 0; i < fields.len; i++)
        resolve_expr(r, ast_at_const(r->ast, ids[i])->as.field_initializer.value); // field names deferred
      break;
    }
    case NODE_BLOCK:
      resolve_block(r, id);
      break;
    case NODE_CLOSURE: {
      if (r->in_generic)
        resolver_errorf(
            r, n->span.start, n->span.end - n->span.start,
            "closures inside generic functions are not yet supported");
      const bool saved_in = r->in_closure;
      const uint32_t saved_floor = r->closure_floor;
      scope_enter(r);
      r->in_closure = true;
      r->closure_floor = (uint32_t)r->symbols.len; // params declared next are local to the closure
      const NodeList params = n->as.closure.params;
      const NodeId *const pids = ast_list(r->ast, params);
      for (uint32_t i = 0; i < params.len; i++) {
        const Node *const param = ast_at_const(r->ast, pids[i]);
        declare(r, param->as.parameter.name, pids[i], NS_VALUE);
        resolve_type(r, param->as.parameter.type);
      }
      if (n->as.closure.expr_body)
        resolve_expr(r, n->as.closure.body);
      else
        resolve_block(r, n->as.closure.body);
      r->in_closure = saved_in;
      r->closure_floor = saved_floor;
      scope_exit(r);
      break;
    }
    case NODE_IF:
      resolve_if(r, n);
      break;
    case NODE_RANGE: // for-loop range bounds (either may be NODE_NONE)
      resolve_expr(r, n->as.pattern_range.start);
      resolve_expr(r, n->as.pattern_range.end);
      break;
    default: // NODE_LITERAL and other leaves
      break;
  }
}

static void resolve_pattern(Resolver *r, const NodeId id) {
  if (id == NODE_NONE)
    return;
  const Node *const n = ast_at_const(r->ast, id);
  switch (n->kind) {
    case NODE_IDENTIFIER: // shorthand struct-pattern field binding
      declare(r, id, id, NS_VALUE);
      break;
    case NODE_PATTERN_NAME:
      declare(r, n->as.pattern.name, id, NS_VALUE);
      break;
    case NODE_PATTERN_TUPLE:   // constructor name deferred to the type checker
    case NODE_PATTERN_STRUCT:  // type name deferred
    case NODE_PATTERN_FIELD: { // field name deferred
      const NodeList children = n->as.pattern.children;
      const NodeId *const ids = ast_list(r->ast, children);
      for (uint32_t i = 0; i < children.len; i++)
        resolve_pattern(r, ids[i]);
      break;
    }
    default: // NODE_PATTERN_WILDCARD, NODE_PATTERN_LITERAL, NODE_PATTERN_RANGE
      break;
  }
}

// Top-level items are visible regardless of order, so declare them all before resolving bodies.
static void collect_items(Resolver *r, const NodeList items) {
  const NodeId *const ids = ast_list(r->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const NodeId id = ids[i];
    const Node *const n = ast_at_const(r->ast, id);
    switch (n->kind) {
      case NODE_FUNCTION:
        declare(r, n->as.function.name, id, NS_VALUE);
        break;
      case NODE_CONST:
        declare(r, n->as.const_def.name, id, NS_VALUE);
        break;
      case NODE_STRUCT:
      case NODE_ENUM:
        declare(r, n->as.aggregate.name, id, NS_TYPE);
        break;
      case NODE_TRAIT:
        declare(r, n->as.trait_def.name, id, NS_TYPE);
        break;
      case NODE_TYPE_ALIAS:
        declare(r, n->as.type_alias.name, id, NS_TYPE);
        break;
      case NODE_EXTERN_BLOCK: {
        const NodeList inner = n->as.extern_block.items;
        const NodeId *const iids = ast_list(r->ast, inner);
        for (uint32_t j = 0; j < inner.len; j++) {
          const Node *const it = ast_at_const(r->ast, iids[j]);
          if (it->kind == NODE_FUNCTION)
            declare(r, it->as.function.name, iids[j], NS_VALUE);
          else if (it->kind == NODE_TYPE_ALIAS)
            declare(r, it->as.type_alias.name, iids[j], NS_TYPE);
        }
        break;
      }
      default: // NODE_IMPL has no module-scope name
        break;
    }
  }
}

void resolver_resolve(Resolver *r) {
  const NodeList items = ast_at_const(r->ast, r->ast->root)->as.program.items;
  ast_init_resolutions(r->ast);

  scope_enter(r);
  collect_items(r, items);
  const NodeId *const ids = ast_list(r->ast, items);
  for (uint32_t i = 0; i < items.len; i++)
    resolve_item(r, ids[i]);
  scope_exit(r);

  errors_finalize(&r->errors, &r->errors_start, &r->errors_len, r->source, r->len);
}

VEC_DEFINE(Symbol, Symbol_Vec)

ERRORS_BODY(Resolver, resolver, r)
