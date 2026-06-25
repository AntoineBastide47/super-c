#include "typechecker.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "module/loader.h"

struct TypeChecker {
    Ast *ast;
    const uint8_t *source;
    size_t len;
    NodeList current_returns; // the enclosing function's `returns` list, for NODE_RETURN checking
    NodeId current_self;      // the struct decl whose `extend` we are inside (NODE_NONE at top level)
    NodeId current_fn;        // the function decl being checked, for `where`-clause bound lookup (NODE_NONE if none)
    const Package *package;   // to follow imported decls into their origin module (NULL = no imports)
    unsigned alias_depth;     // type-alias expansion depth, bounded so a cyclic alias diagnoses instead of recursing forever
    ERRORS_VARIABLES;
};

#define TYPE_ALIAS_MAX_DEPTH 64

// The Ast / source backing module `m`: the current module uses the in-flight Ast directly; an imported
// module is reached through the Package. With no package, everything is the current module.
ALWAYS_INLINE Ast *mod_ast(const TypeChecker *t, const ModuleId m) {
  return t->package && m != t->ast->module ? t->package->modules[m].ast : t->ast;
}
ALWAYS_INLINE const uint8_t *mod_src(const TypeChecker *t, const ModuleId m) {
  return t->package && m != t->ast->module ? (const uint8_t *)t->package->modules[m].source : t->source;
}

static const char *const BUILTIN_NAMES[BT_COUNT] = {
    "bool", "char", "i8",  "i16",   "i32", "i64", "isize", "u8",
    "u16",  "u32",  "u64", "usize", "f32", "f64", "void",
};

static TypeId check_expr(TypeChecker *t, NodeId id);
static void check_stmt(TypeChecker *t, NodeId id);
static TypeId resolve_type(TypeChecker *t, NodeId id);
static TypeId decl_type(TypeChecker *t, NodeId decl);
static TypeId decl_type_in(TypeChecker *t, ModuleId m, NodeId decl);
static TypeId named_type_of(TypeChecker *t, ModuleId m, NodeId decl);

// `str` is no longer a builtin -- a string literal's type is the std prelude's `str` struct.
static TypeId prelude_str_type(TypeChecker *t) {
  if (!t->package)
    return TYPE_ERROR;
  ModuleId mid;
  const NodeId d = package_prelude_lookup(t->package, "str", 3, true, &mid);
  return d != NODE_NONE ? named_type_of(t, mid, d) : TYPE_ERROR;
}
static TypeId lower_type_in(TypeChecker *t, ModuleId m, NodeId id);
static void check_pattern(TypeChecker *t, NodeId id, TypeId expected);
static void render_type(TypeChecker *t, TypeId tid, char *buf, size_t cap);
static TypeId check_member(TypeChecker *t, const Node *n, bool prefer_method);
static TypeId subst_type(TypeChecker *t, TypeId ty, const DefId *params, const TypeId *args, int n);
static bool aggregate_of(TypeChecker *t, TypeId ty, ModuleId *mod, NodeId *decl, DefId *params, TypeId *args, int *n);

TypeChecker *typechecker_new(Ast *ast, const char *source, const size_t len, const Package *package) {
  TypeChecker *const t = calloc(1, sizeof *t);
  if (!t) {
    fprintf(stderr, "fatal: out of memory\n");
    abort();
  }
  t->ast = ast;
  t->source = (const uint8_t *)source;
  t->len = len;
  t->package = package;
  ERRORS_INIT(t);
  return t;
}

void typechecker_free(TypeChecker **t) {
  if (!t || !*t)
    return;
  ast_free(&(*t)->ast);
  ERRORS_DEINIT(t);
  free(*t);
  *t = NULL;
}

Ast *typechecker_take_ast(TypeChecker *t) {
  Ast *const ast = t->ast;
  t->ast = NULL;
  return ast;
}

ALWAYS_INLINE Span name_span(const TypeChecker *t, const NodeId name_node) {
  return ast_at_const(t->ast, name_node)->as.name.text;
}

ALWAYS_INLINE bool span_is(const uint8_t *const src, const Span s, const char *const lit) {
  const size_t n = strlen(lit);
  return (size_t)(s.end - s.start) == n && memcmp(src + s.start, lit, n) == 0;
}

// Compare two spans that may index different source buffers (a cross-module name vs a local one).
ALWAYS_INLINE bool spans_eq2(const uint8_t *const sa, const Span a, const uint8_t *const sb, const Span b) {
  const uint32_t la = a.end - a.start;
  return la == b.end - b.start && memcmp(sa + a.start, sb + b.start, la) == 0;
}

// Returns the BuiltinType index for a builtin type name, or -1. Order matches BUILTIN_NAMES / the enum.
static int builtin_of(const uint8_t *const src, const Span s) {
  for (int i = 0; i < BT_COUNT; i++)
    if (span_is(src, s, BUILTIN_NAMES[i]))
      return i;
  return -1;
}

ALWAYS_INLINE bool bt_is_int(const BuiltinType b) {
  return b >= BT_I8 && b <= BT_USIZE;
}

ALWAYS_INLINE bool bt_is_float(const BuiltinType b) {
  return b == BT_F32 || b == BT_F64;
}

static bool is_bool(const TypeChecker *t, const TypeId x) {
  const Ty *const y = ast_type_at(t->ast, x);
  return y->kind == TYPE_BUILTIN && y->as.builtin == BT_BOOL;
}

static bool is_int(const TypeChecker *t, const TypeId x) {
  const Ty *const y = ast_type_at(t->ast, x);
  return y->kind == TYPE_BUILTIN && bt_is_int(y->as.builtin);
}

static bool is_numeric(const TypeChecker *t, const TypeId x) {
  const Ty *const y = ast_type_at(t->ast, x);
  return y->kind == TYPE_BUILTIN && (bt_is_int(y->as.builtin) || bt_is_float(y->as.builtin));
}

static bool is_void_type(const TypeChecker *t, const TypeId x) {
  const Ty *const y = ast_type_at(t->ast, x);
  return y->kind == TYPE_BUILTIN && y->as.builtin == BT_VOID;
}

static bool is_integer_literal_node(const Ast *a, NodeId id) {
  if (id == NODE_NONE)
    return false;
  const Node *n = ast_at_const(a, id);
  if (n->kind == NODE_UNARY && n->as.unary.op == Minus)
    n = ast_at_const(a, n->as.unary.operand);
  return n->kind == NODE_LITERAL && n->as.literal.token_type == IntegerLiteral;
}

// A payload-less enum is a plain C enum: its values are integers, so it casts to/from integers.
static bool is_plain_enum(const TypeChecker *t, const TypeId x) {
  const Ty *const y = ast_type_at(t->ast, x);
  if (y->kind != TYPE_ENUM)
    return false;
  Ast *const a = mod_ast(t, y->module);
  const NodeList ms = ast_at_const(a, y->as.decl)->as.aggregate.members;
  const NodeId *const ids = ast_list(a, ms);
  for (uint32_t i = 0; i < ms.len; i++)
    if (ast_at_const(a, ids[i])->as.variant.payload.len > 0)
      return false;
  return true;
}

// Peel pointer/reference layers to reach the underlying aggregate (for member access).
static TypeId strip(const TypeChecker *t, TypeId x) {
  const Ty *y = ast_type_at(t->ast, x);
  while (y->kind == TYPE_POINTER || y->kind == TYPE_REFERENCE) {
    x = y->as.elem;
    y = ast_type_at(t->ast, x);
  }
  return x;
}

static void render_type(TypeChecker *t, const TypeId tid, char *buf, const size_t cap) {
  const Ty *const ty = ast_type_at(t->ast, tid);
  switch (ty->kind) {
    case TYPE_BUILTIN:
      snprintf(buf, cap, "%s", BUILTIN_NAMES[ty->as.builtin]);
      break;
    case TYPE_POINTER:
    case TYPE_REFERENCE: {
      char in[96];
      render_type(t, ty->as.elem, in, sizeof in);
      snprintf(buf, cap, "%s%s%s", ty->kind == TYPE_POINTER ? "*" : "&", ty->qualifier == TYPE_QUAL_MUT ? "mut " : "", in);
      break;
    }
    case TYPE_SLICE: {
      char in[96];
      render_type(t, ty->as.elem, in, sizeof in);
      snprintf(buf, cap, "[]%s", in);
      break;
    }
    case TYPE_ARRAY: {
      char in[96];
      render_type(t, ty->as.elem, in, sizeof in);
      snprintf(buf, cap, "[%s]", in);
      break;
    }
    case TYPE_STRUCT:
    case TYPE_ENUM:
    case TYPE_GENERIC: {
      Ast *const a = mod_ast(t, ty->module);
      const Node *const d = ast_at_const(a, ty->as.decl);
      const NodeId nm = d->kind == NODE_GENERIC_PARAM ? d->as.generic_param.name : d->as.aggregate.name;
      const Span s = ast_at_const(a, nm)->as.name.text;
      snprintf(buf, cap, "%.*s", (int)(s.end - s.start), (const char *)mod_src(t, ty->module) + s.start);
      break;
    }
    case TYPE_FUNCTION:
      snprintf(buf, cap, "fn");
      break;
    default:
      snprintf(buf, cap, "?");
      break;
  }
}

// Emit a "mismatched types" diagnostic at `node`, comparing its computed type against `expected`.
static void err_mismatch(TypeChecker *t, const NodeId node, const TypeId expected) {
  char e[96], f[96];
  render_type(t, expected, e, sizeof e);
  render_type(t, ast_type(t->ast, node), f, sizeof f);
  const Span sp = ast_at_const(t->ast, node)->span;
  typechecker_errorf(t, sp.start, sp.end - sp.start, "mismatched types: expected '%s', found '%s'", e, f);
}

// Reads a TYPE_FUNCTION's signature into interned TypeIds, normalizing a named `NODE_FUNCTION` (params
// are NODE_PARAMETER) and an anonymous `fn(..) ..` NODE_FUNCTION_TYPE (params are bare type nodes) to
// the same shape. Returns the parameter count; `*ret` is the single return type, or TYPE_NONE for none.
static int fn_sig(TypeChecker *t, const Ty *const fty, TypeId *const params, const int cap, TypeId *const ret) {
  const ModuleId m = fty->module;
  Ast *const fa = mod_ast(t, m);
  const Node *const fn = ast_at_const(fa, fty->as.decl);
  NodeList ps, rs;
  switch (fn->kind) {
    case NODE_FUNCTION: ps = fn->as.function.params; rs = fn->as.function.returns; break;
    case NODE_CLOSURE: ps = fn->as.closure.params; rs = fn->as.closure.returns; break;
    default: ps = fn->as.function_type.params; rs = fn->as.function_type.returns; break; // NODE_FUNCTION_TYPE
  }
  const NodeId *const pid = ast_list(fa, ps);
  for (uint32_t i = 0; i < ps.len && (int)i < cap; i++) {
    const Node *const p = ast_at_const(fa, pid[i]);
    params[i] = lower_type_in(t, m, p->kind == NODE_PARAMETER ? p->as.parameter.type : pid[i]);
  }
  if (fn->kind == NODE_CLOSURE && fn->as.closure.expr_body) {
    *ret = ast_type(fa, fn->as.closure.body); // compact closure: return type inferred from the body
  } else if (rs.len == 1) {
    const NodeId r0 = ast_list(fa, rs)[0];
    const Node *const rn = ast_at_const(fa, r0);
    *ret = lower_type_in(t, m, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : r0);
  } else {
    *ret = TYPE_NONE;
  }
  return (int)ps.len;
}

// A function's return is void in two spellings: an explicit `void` (BT_VOID) and an omitted return type
// (TYPE_NONE, used by a no-annotation closure/fn body). Treat them as the same when matching signatures.
static bool ret_eq(const TypeId a, const TypeId b) {
  if (a == b)
    return true;
  const TypeId v = ast_builtin(BT_VOID);
  return (a == TYPE_NONE || a == v) && (b == TYPE_NONE || b == v);
}

// Two function types are compatible when their signatures match structurally (so a named function
// passes where a `fn(..) ..` pointer is expected, even though they intern to distinct Tys keyed on
// their decl node). C function-pointer types must match exactly, so params/return compare by identity.
static bool fn_compatible(TypeChecker *t, const Ty *const ex, const Ty *const ac) {
  TypeId ep[4], ap[4], er, ar;
  const int en = fn_sig(t, ex, ep, 4, &er), an = fn_sig(t, ac, ap, 4, &ar);
  if (en != an || en > 4 || !ret_eq(er, ar))
    return false;
  for (int i = 0; i < en; i++)
    if (ep[i] != ap[i])
      return false;
  return true;
}

// Is the value at `node` assignable to a slot of type `expected`? Equal types, poison (suppress
// cascades), a numeric literal matching the expected numeric class, or `null` into a pointer/reference.
static bool compatible(TypeChecker *t, const TypeId expected, const NodeId node) {
  const TypeId actual = ast_type(t->ast, node);
  if (expected == TYPE_NONE || actual == TYPE_NONE || expected == actual)
    return true;
  // A reference coerces to a raw pointer of the same pointee: `&T`->`*const T`, `&mut T`->`*mut T`
  // or `*const T` (mut downgrades to const). One-way only, and `&T` never gains `*mut`. A raw
  // pointer carries no validity guarantee, so it never becomes a reference.
  const Ty *const ex = ast_type_at(t->ast, expected), *const ac = ast_type_at(t->ast, actual);
  if (ex->kind == TYPE_POINTER && ac->kind == TYPE_REFERENCE && ex->as.elem == ac->as.elem &&
      (ac->qualifier == TYPE_QUAL_MUT || ex->qualifier == TYPE_QUAL_CONST))
    return true;
  // Raw pointers of the same pointee: a writable source (`*T`/`*mut T`) fits any target; a
  // `*const T` source fits only a `*const T` target (so `new`'s `*mut T` flows into `*T`/`*const`).
  if (ex->kind == TYPE_POINTER && ac->kind == TYPE_POINTER && ex->as.elem == ac->as.elem &&
      (ex->qualifier == TYPE_QUAL_CONST || ac->qualifier != TYPE_QUAL_CONST))
    return true;
  // A named function (or another fn pointer) fits a `fn(..) ..` slot when signatures match structurally.
  if (ex->kind == TYPE_FUNCTION && ac->kind == TYPE_FUNCTION)
    return fn_compatible(t, ex, ac);
  // Arrays compare by element: equal elements, or fn-typed elements that match structurally (a function
  // type is keyed on its decl, so `[fn(i32)i32]` from an annotation and from `[a, b]` are distinct TypeIds).
  if (ex->kind == TYPE_ARRAY && ac->kind == TYPE_ARRAY) {
    if (ex->as.elem == ac->as.elem)
      return true;
    const Ty *const ee = ast_type_at(t->ast, ex->as.elem), *const ae = ast_type_at(t->ast, ac->as.elem);
    return ee->kind == TYPE_FUNCTION && ae->kind == TYPE_FUNCTION && fn_compatible(t, ee, ae);
  }
  const Node *v = ast_at_const(t->ast, node);
  if (v->kind == NODE_UNARY && v->as.unary.op == Minus) // -literal still counts as a literal
    v = ast_at_const(t->ast, v->as.unary.operand);
  if (v->kind != NODE_LITERAL)
    return false;
  const Ty *const et = ast_type_at(t->ast, expected);
  switch (v->as.literal.token_type) {
    case IntegerLiteral: // an integer literal fits any int *or* float slot (`let f: f64 = 0;`)
      return et->kind == TYPE_BUILTIN && (bt_is_int(et->as.builtin) || bt_is_float(et->as.builtin));
    case CharacterLiteral: // an ASCII char literal fits any int slot too (`contains_byte('l')`), like `b'l'`
      return et->kind == TYPE_BUILTIN && bt_is_int(et->as.builtin);
    case FloatLiteral: // a float literal stays float-only (no implicit float->int truncation)
      return et->kind == TYPE_BUILTIN && bt_is_float(et->as.builtin);
    case Null:
      return et->kind == TYPE_POINTER || et->kind == TYPE_REFERENCE;
    default:
      return false;
  }
}

static bool return_list_is_explicit_void(TypeChecker *t, const NodeList rets) {
  if (rets.len != 1)
    return false;
  const NodeId r0 = ast_list(t->ast, rets)[0];
  const Node *const rn = ast_at_const(t->ast, r0);
  return is_void_type(t, resolve_type(t, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : r0));
}

static TypeId range_type(TypeChecker *t, const Node *const n, const TypeId start, const TypeId end) {
  const bool has_start = n->as.pattern_range.start != NODE_NONE;
  const bool has_end = n->as.pattern_range.end != NODE_NONE;
  const bool start_ok = !has_start || start == TYPE_NONE || is_int(t, start);
  const bool end_ok = !has_end || end == TYPE_NONE || is_int(t, end);
  if (!start_ok || !end_ok) {
    typechecker_errorf(t, n->span.start, n->span.end - n->span.start, "range bounds must be integers");
    return TYPE_NONE;
  }
  if (!has_start)
    return end;
  if (!has_end)
    return start;
  if (start == TYPE_NONE)
    return end;
  if (end == TYPE_NONE || start == end)
    return start;
  if (is_integer_literal_node(t->ast, n->as.pattern_range.start) && compatible(t, end, n->as.pattern_range.start))
    return end;
  if (is_integer_literal_node(t->ast, n->as.pattern_range.end) && compatible(t, start, n->as.pattern_range.end))
    return start;
  err_mismatch(t, n->as.pattern_range.end, start);
  return TYPE_NONE;
}

// Find a NODE_FIELD / NODE_VARIANT member of struct/enum `decl` (which lives in module `m`) by name.
static NodeId find_member(TypeChecker *t, const ModuleId m, const NodeId decl, const Span name) {
  Ast *const a = mod_ast(t, m);
  const uint8_t *const src = mod_src(t, m);
  const Node *const d = ast_at_const(a, decl);
  if (d->kind != NODE_STRUCT && d->kind != NODE_ENUM)
    return NODE_NONE;
  const NodeList members = d->as.aggregate.members;
  const NodeId *const ids = ast_list(a, members);
  for (uint32_t i = 0; i < members.len; i++) {
    const Node *const mem = ast_at_const(a, ids[i]);
    const NodeId mname = mem->kind == NODE_FIELD ? mem->as.field.name : mem->as.variant.name;
    if (spans_eq2(t->source, name, src, ast_at_const(a, mname)->as.name.text))
      return ids[i];
  }
  return NODE_NONE;
}

// Find a method named `name` in any top-level impl of module `m` whose target type resolves to `decl`.
// `name` is a span into the *caller's* source; member names are compared against module `m`'s source.
// Find a method named `name` for type `decl` (declared in module `m`). Searches the type's home module,
// then the CURRENT module for a local extension of an imported type (`extend foreign::T`, visible only
// here and mangled by this module). Returns the method's real DefId, or {_, NODE_NONE} if not found.
static DefId find_method(TypeChecker *t, const ModuleId m, const NodeId decl, const Span name) {
  Ast *const a = mod_ast(t, m);
  const uint8_t *const src = mod_src(t, m);
  const NodeList items = ast_at_const(a, a->root)->as.program.items;
  const NodeId *const ids = ast_list(a, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const it = ast_at_const(a, ids[i]);
    if (it->kind != NODE_IMPL || it->as.impl_def.target_type == NODE_NONE)
      continue;
    if (ast_resolution(a, it->as.impl_def.target_type) != decl)
      continue;
    const NodeList methods = it->as.impl_def.items;
    const NodeId *const mids = ast_list(a, methods);
    for (uint32_t j = 0; j < methods.len; j++) {
      const Node *const mn = ast_at_const(a, mids[j]);
      if (mn->kind == NODE_FUNCTION &&
          spans_eq2(t->source, name, src, ast_at_const(a, mn->as.function.name)->as.name.text))
        return (DefId){m, mids[j]};
    }
  }
  if (m != t->ast->module) { // a local `extend foreign::T` in the current module
    Ast *const ca = t->ast;
    const NodeList citems = ast_at_const(ca, ca->root)->as.program.items;
    const NodeId *const cids = ast_list(ca, citems);
    for (uint32_t i = 0; i < citems.len; i++) {
      const Node *const it = ast_at_const(ca, cids[i]);
      if (it->kind != NODE_IMPL || it->as.impl_def.target_type == NODE_NONE)
        continue;
      const DefId td = ast_resolution_def(ca, it->as.impl_def.target_type);
      if (td.module != m || td.node != decl)
        continue;
      const NodeList methods = it->as.impl_def.items;
      const NodeId *const mids = ast_list(ca, methods);
      for (uint32_t j = 0; j < methods.len; j++) {
        const Node *const mn = ast_at_const(ca, mids[j]);
        if (mn->kind == NODE_FUNCTION &&
            spans_eq2(t->source, name, t->source, ast_at_const(ca, mn->as.function.name)->as.name.text))
          return (DefId){t->ast->module, mids[j]};
      }
    }
  }
  return (DefId){0, NODE_NONE};
}

// The top-level impl in module `m` whose items contain `method`, or NODE_NONE -- used to recover the
// impl's own generic params so a method on a generic instance receiver substitutes them by its args.
static NodeId enclosing_impl(TypeChecker *t, const ModuleId m, const NodeId method) {
  Ast *const a = mod_ast(t, m);
  const NodeList items = ast_at_const(a, a->root)->as.program.items;
  const NodeId *const ids = ast_list(a, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const it = ast_at_const(a, ids[i]);
    if (it->kind != NODE_IMPL)
      continue;
    const NodeList ms = it->as.impl_def.items;
    const NodeId *const mids = ast_list(a, ms);
    for (uint32_t j = 0; j < ms.len; j++)
      if (mids[j] == method)
        return ids[i];
  }
  return NODE_NONE;
}

// The interface (NODE_TRAIT) an interface method belongs to, or NODE_NONE -- recovers the trait so a
// method reached through a generic bound substitutes its `Self` by the receiver type.
static NodeId enclosing_trait(TypeChecker *t, const ModuleId m, const NodeId method) {
  Ast *const a = mod_ast(t, m);
  const NodeList items = ast_at_const(a, a->root)->as.program.items;
  const NodeId *const ids = ast_list(a, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const it = ast_at_const(a, ids[i]);
    if (it->kind != NODE_TRAIT)
      continue;
    const NodeList ms = it->as.trait_def.items;
    const NodeId *const mids = ast_list(a, ms);
    for (uint32_t j = 0; j < ms.len; j++)
      if (mids[j] == method)
        return ids[i];
  }
  return NODE_NONE;
}

// Append the interface DefIds named by `bounds` (type-paths resolved in ast `a`) to out[0..*n).
static void add_bound_ifaces(Ast *const a, const NodeList bounds, DefId *const out, int *const n, const int cap) {
  const NodeId *const ids = ast_list(a, bounds);
  for (uint32_t i = 0; i < bounds.len && *n < cap; i++) {
    const DefId d = ast_resolution_def(a, ids[i]);
    if (d.node != NODE_NONE)
      out[(*n)++] = d;
  }
}

// The interface bounds in effect for generic param (pmod, pdecl): its own inline bounds plus, when it is
// the enclosing function's own param, any matching `where` predicates.
static int collect_param_bounds(TypeChecker *t, const ModuleId pmod, const NodeId pdecl, DefId *const out, const int cap) {
  int n = 0;
  Ast *const pa = mod_ast(t, pmod);
  add_bound_ifaces(pa, ast_at_const(pa, pdecl)->as.generic_param.bounds, out, &n, cap);
  if (pmod == t->ast->module && t->current_fn != NODE_NONE) {
    const NodeList wc = ast_at_const(t->ast, t->current_fn)->as.function.where_clause;
    const NodeId *const wids = ast_list(t->ast, wc);
    for (uint32_t w = 0; w < wc.len; w++) {
      const Node *const wp = ast_at_const(t->ast, wids[w]);
      if (ast_resolution(t->ast, wp->as.where_predicate.type) == pdecl)
        add_bound_ifaces(t->ast, wp->as.where_predicate.bounds, out, &n, cap);
    }
  }
  return n;
}

// A method named `name` declared by an interface bound in effect for generic param `pdecl` (`<T: Writer>`,
// a `where` clause, or a conditional extension): the interface method's DefId, with the satisfying
// interface returned via *iface; {_,NODE_NONE} if none.
static DefId find_bound_method(TypeChecker *t, const ModuleId pmod, const NodeId pdecl, const Span name,
                               DefId *const iface) {
  DefId ifaces[8];
  const int ni = collect_param_bounds(t, pmod, pdecl, ifaces, 8);
  for (int b = 0; b < ni; b++) {
    const DefId id = ifaces[b];
    Ast *const ia = mod_ast(t, id.module);
    const Node *const idn = ast_at_const(ia, id.node);
    if (idn->kind != NODE_TRAIT)
      continue;
    const NodeList items = idn->as.trait_def.items;
    const NodeId *const mids = ast_list(ia, items);
    for (uint32_t j = 0; j < items.len; j++) {
      const Node *const mn = ast_at_const(ia, mids[j]);
      if (mn->kind == NODE_FUNCTION &&
          spans_eq2(t->source, name, mod_src(t, id.module), ast_at_const(ia, mn->as.function.name)->as.name.text)) {
        if (iface)
          *iface = id;
        return (DefId){id.module, mids[j]};
      }
    }
  }
  return (DefId){0, NODE_NONE};
}

// An `extend [<G>] <tdecl> as <iface>` impl in `tdecl`'s module or the current module (a local extension);
// NODE_NONE if absent. *imod receives the impl's module.
static NodeId find_impl_as(TypeChecker *t, const ModuleId tmod, const NodeId tdecl, const DefId iface,
                           ModuleId *const imod) {
  const ModuleId scopes[2] = {tmod, t->ast->module};
  const int ns = tmod == t->ast->module ? 1 : 2;
  for (int s = 0; s < ns; s++) {
    const ModuleId m = scopes[s];
    Ast *const a = mod_ast(t, m);
    const NodeList items = ast_at_const(a, a->root)->as.program.items;
    const NodeId *const ids = ast_list(a, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const it = ast_at_const(a, ids[i]);
      if (it->kind != NODE_IMPL || it->as.impl_def.trait_type == NODE_NONE || it->as.impl_def.target_type == NODE_NONE)
        continue;
      const DefId tr = ast_resolution_def(a, it->as.impl_def.trait_type);
      const DefId tg = ast_resolution_def(a, it->as.impl_def.target_type);
      if (tr.module == iface.module && tr.node == iface.node && tg.module == tmod && tg.node == tdecl) {
        *imod = m;
        return ids[i];
      }
    }
  }
  return NODE_NONE;
}

// Whether concrete type `ty` satisfies interface bound `iface`: there is an `extend ty as iface` (directly,
// or a conditional `extend<G> Ty<G> as iface` whose own bounds hold for ty's type arguments). A still-
// abstract type parameter is taken to satisfy -- it is re-checked when finally instantiated.
#define BOUND_MAX_DEPTH 8
static bool type_satisfies(TypeChecker *t, const TypeId ty, const DefId iface, const int depth) {
  if (ty == TYPE_NONE || ty == TYPE_ERROR || depth > BOUND_MAX_DEPTH)
    return true; // unknown / too deep: do not manufacture a false error
  const Ty *const y = ast_type_at(t->ast, ty);
  if (y->kind == TYPE_GENERIC)
    return true; // abstract param: verified at concrete instantiation
  ModuleId tmod;
  NodeId tdecl;
  TypeId iargs[4];
  int in = 0;
  if (y->kind == TYPE_STRUCT || y->kind == TYPE_ENUM) {
    tmod = y->module;
    tdecl = y->as.decl;
  } else if (y->kind == TYPE_INSTANCE) {
    const TyInstance *const inst = ast_instance(t->ast, y->as.inst);
    tmod = inst->module;
    tdecl = inst->decl;
    for (uint8_t k = 0; k < inst->n && in < 4; k++)
      iargs[in++] = inst->args[k];
  } else {
    return false; // a builtin/pointer/etc. with no `as iface` impl
  }
  ModuleId imod;
  const NodeId impl = find_impl_as(t, tmod, tdecl, iface, &imod);
  if (impl == NODE_NONE)
    return false;
  // Conditional extension: each impl generic param's bounds must hold for the matching instance arg.
  Ast *const ia = mod_ast(t, imod);
  const NodeList gens = ast_at_const(ia, impl)->as.impl_def.generics;
  const NodeId *const gids = ast_list(ia, gens);
  for (uint32_t g = 0; g < gens.len && (int)g < in; g++) {
    const NodeList gb = ast_at_const(ia, gids[g])->as.generic_param.bounds;
    const NodeId *const gbids = ast_list(ia, gb);
    for (uint32_t b = 0; b < gb.len; b++) {
      const DefId gbi = ast_resolution_def(ia, gbids[b]);
      if (gbi.node != NODE_NONE && !type_satisfies(t, iargs[g], gbi, depth + 1))
        return false;
    }
  }
  return true;
}

// `extend T as Iface { ... }` must provide every method the interface requires (a body-less declaration);
// interface methods that carry a default body are optional. Reports each missing method.
static void check_impl_conformance(TypeChecker *t, const Node *const n) {
  const DefId iface = ast_resolution_def(t->ast, n->as.impl_def.trait_type);
  if (iface.node == NODE_NONE)
    return;
  Ast *const ia = mod_ast(t, iface.module);
  const Node *const idn = ast_at_const(ia, iface.node);
  if (idn->kind != NODE_TRAIT)
    return;
  const NodeList req = idn->as.trait_def.items;
  const NodeId *const rids = ast_list(ia, req);
  const NodeList have = n->as.impl_def.items;
  const NodeId *const hids = ast_list(t->ast, have);
  for (uint32_t i = 0; i < req.len; i++) {
    const Node *const rm = ast_at_const(ia, rids[i]);
    if (rm->kind != NODE_FUNCTION || rm->as.function.body != NODE_NONE)
      continue; // only required (body-less) methods must be provided
    const Span rn = ast_at_const(ia, rm->as.function.name)->as.name.text;
    bool found = false;
    for (uint32_t j = 0; j < have.len && !found; j++) {
      const Node *const hm = ast_at_const(t->ast, hids[j]);
      found = hm->kind == NODE_FUNCTION &&
              spans_eq2(mod_src(t, iface.module), rn, t->source, ast_at_const(t->ast, hm->as.function.name)->as.name.text);
    }
    if (!found) {
      const Span at = ast_at_const(t->ast, n->as.impl_def.trait_type)->span;
      typechecker_errorf(
          t, at.start, at.end - at.start, "missing method '%.*s' required by this interface",
          (int)(rn.end - rn.start), (const char *)mod_src(t, iface.module) + rn.start);
    }
  }
}

// The interned type a struct/enum/alias/generic decl names, where the decl lives in module `m`. The
// module is carried into the Ty so the same named type unifies across modules.
static TypeId named_type_of(TypeChecker *t, const ModuleId m, const NodeId decl) {
  const Node *const d = ast_at_const(mod_ast(t, m), decl);
  switch (d->kind) {
    case NODE_STRUCT:
      return ast_intern_type(t->ast, (Ty){.kind = TYPE_STRUCT, .module = m, .as.decl = decl});
    case NODE_ENUM:
      return ast_intern_type(t->ast, (Ty){.kind = TYPE_ENUM, .module = m, .as.decl = decl});
    case NODE_TYPE_ALIAS: { // aliases are transparent; bound expansion so `type T = T;` (or A=B;B=A) diagnoses
      if (t->alias_depth >= TYPE_ALIAS_MAX_DEPTH) {
        typechecker_errorf(t, d->span.start, d->span.end - d->span.start, "type alias is cyclic");
        return TYPE_ERROR;
      }
      t->alias_depth++;
      const TypeId aliased = lower_type_in(t, m, d->as.type_alias.type);
      t->alias_depth--;
      return aliased;
    }
    case NODE_GENERIC_PARAM:
      return ast_intern_type(t->ast, (Ty){.kind = TYPE_GENERIC, .module = m, .as.decl = decl});
    case NODE_TRAIT: // `Self` inside an interface: an abstract type, substituted to the receiver at use
      return ast_intern_type(t->ast, (Ty){.kind = TYPE_GENERIC, .module = m, .as.decl = decl});
    default:
      return TYPE_ERROR;
  }
}

// Lower a type node living in module `m` to a TypeId interned in the current pool. For the current
// module this is exactly resolve_type (memoised, with array-length checks and Enum::Variant binding);
// for an imported module it reads that module's own nodes and resolutions.
static TypeId lower_type_in(TypeChecker *t, const ModuleId m, const NodeId id) {
  if (!t->package || m == t->ast->module)
    return resolve_type(t, id);
  if (id == NODE_NONE)
    return TYPE_NONE;
  Ast *const a = mod_ast(t, m);
  const Node *const n = ast_at_const(a, id);
  switch (n->kind) {
    case NODE_TYPE_PATH: {
      const DefId d = ast_resolution_def(a, id);
      if (d.node != NODE_NONE) {
        const Node *const dn = ast_at_const(mod_ast(t, d.module), d.node);
        const NodeList args = n->as.type_path.args;
        if ((dn->kind == NODE_STRUCT || dn->kind == NODE_ENUM) && dn->as.aggregate.generics.len > 0 && args.len > 0) {
          const NodeId *const aids = ast_list(a, args); // a foreign generic application (Box<T>) -> an instance
          TypeId ta[4];
          uint8_t tn = 0;
          for (uint32_t i = 0; i < args.len && tn < 4; i++)
            ta[tn++] = lower_type_in(t, m, aids[i]);
          return ast_intern_instance(t->ast, d.module, d.node, ta, tn);
        }
        return named_type_of(t, d.module, d.node);
      }
      const NodeList parts = n->as.type_path.parts;
      const int b = parts.len ? builtin_of(mod_src(t, m), ast_at_const(a, ast_list(a, parts)[0])->as.name.text) : -1;
      return b >= 0 ? ast_builtin((BuiltinType)b) : TYPE_ERROR;
    }
    case NODE_POINTER_TYPE:
    case NODE_REFERENCE_TYPE:
    case NODE_SLICE_TYPE: {
      const TypeKind k =
          n->kind == NODE_POINTER_TYPE ? TYPE_POINTER : n->kind == NODE_REFERENCE_TYPE ? TYPE_REFERENCE : TYPE_SLICE;
      return ast_intern_type(
          t->ast, (Ty){.kind = k, .qualifier = n->as.indirect_type.qualifier, .as.elem = lower_type_in(t, m, n->as.indirect_type.type)});
    }
    case NODE_ARRAY_TYPE:
      return ast_intern_type(t->ast, (Ty){.kind = TYPE_ARRAY, .as.elem = lower_type_in(t, m, n->as.array_type.element)});
    case NODE_FUNCTION_TYPE:
      return ast_intern_type(t->ast, (Ty){.kind = TYPE_FUNCTION, .module = m, .as.decl = id});
    default:
      return TYPE_ERROR;
  }
}

// Lower an AST type node to an interned TypeId (memoized in the `types` side table).
static TypeId resolve_type(TypeChecker *t, const NodeId id) {
  if (id == NODE_NONE)
    return TYPE_NONE;
  const TypeId cached = ast_type(t->ast, id);
  if (cached != TYPE_NONE)
    return cached;
  Ast *const a = t->ast;
  const Node *const n = ast_at_const(a, id);
  TypeId result = TYPE_ERROR;
  switch (n->kind) {
    case NODE_TYPE_PATH: {
      const NodeList parts = n->as.type_path.parts;
      const NodeList args = n->as.type_path.args;
      const NodeId *const arg_ids = ast_list(a, args);
      for (uint32_t i = 0; i < args.len; i++)
        resolve_type(t, arg_ids[i]); // resolve type args first so their TypeIds exist
      const DefId d = ast_resolution_def(a, id);
      if (d.node != NODE_NONE) {
        const Node *const dn = ast_at_const(mod_ast(t, d.module), d.node);
        const bool generic_agg =
            (dn->kind == NODE_STRUCT || dn->kind == NODE_ENUM) && dn->as.aggregate.generics.len > 0;
        if (generic_agg && args.len > 0) { // `Vec<i32>` -> an interned generic instance
          TypeId ta[4];
          uint8_t tn = 0;
          for (uint32_t i = 0; i < args.len && tn < 4; i++)
            ta[tn++] = resolve_type(t, arg_ids[i]);
          result = ast_intern_instance(t->ast, d.module, d.node, ta, tn);
        } else {
          result = named_type_of(t, d.module, d.node);
          // Resolve trailing path segments (e.g. local Enum::Variant) against the base's members. A
          // module-qualified path's final segment is already the type, so it has no trailing members.
          if (d.module == a->module) {
            const NodeId *const pids = ast_list(a, parts);
            for (uint32_t i = 1; i < parts.len; i++) {
              const NodeId member = find_member(t, d.module, d.node, name_span(t, pids[i]));
              if (member != NODE_NONE)
                ast_set_resolution(a, pids[i], member);
            }
          }
        }
      } else if (parts.len > 0) {
        const int b = builtin_of(t->source, name_span(t, ast_list(a, parts)[0]));
        result = b >= 0 ? ast_builtin((BuiltinType)b) : TYPE_ERROR;
      }
      break;
    }
    case NODE_POINTER_TYPE:
    case NODE_REFERENCE_TYPE:
    case NODE_SLICE_TYPE: {
      const TypeKind k =
          n->kind == NODE_POINTER_TYPE ? TYPE_POINTER : n->kind == NODE_REFERENCE_TYPE ? TYPE_REFERENCE : TYPE_SLICE;
      result = ast_intern_type(
          a, (Ty){.kind = k, .qualifier = n->as.indirect_type.qualifier,
                    .as.elem = resolve_type(t, n->as.indirect_type.type)});
      break;
    }
    case NODE_ARRAY_TYPE:
      check_expr(t, n->as.array_type.length); // length is checked but its value is not used yet
      result = ast_intern_type(a, (Ty){.kind = TYPE_ARRAY, .as.elem = resolve_type(t, n->as.array_type.element)});
      break;
    case NODE_FUNCTION_TYPE:
      result = ast_intern_type(a, (Ty){.kind = TYPE_FUNCTION, .module = a->module, .as.decl = id});
      break;
    default:
      break;
  }
  ast_set_type(a, id, result);
  return result;
}

// A struct-initializer / new target may be a bare identifier or a full type path.
static TypeId type_of_type_node(TypeChecker *t, const NodeId id) {
  if (id == NODE_NONE)
    return TYPE_NONE;
  const Node *const n = ast_at_const(t->ast, id);
  if (n->kind != NODE_IDENTIFIER)
    return resolve_type(t, id);
  const DefId d = ast_resolution_def(t->ast, id);
  if (d.node != NODE_NONE)
    return named_type_of(t, d.module, d.node);
  const int b = builtin_of(t->source, name_span(t, id));
  return b >= 0 ? ast_builtin((BuiltinType)b) : TYPE_ERROR;
}

// Type of a resolved declaration `decl` living in module `m`, memoized for the current module. Locals
// (let/for/pattern) already have their type stored by the time they are referenced, so the cached read
// returns it. Imported decls (m != current) are computed fresh against their own module's Ast.
static TypeId decl_type_in(TypeChecker *t, const ModuleId m, const NodeId decl) {
  if (decl == NODE_NONE)
    return TYPE_NONE;
  const bool local = !t->package || m == t->ast->module;
  if (local) {
    const TypeId cached = ast_type(t->ast, decl);
    if (cached != TYPE_NONE)
      return cached;
  }
  const Node *const d = ast_at_const(mod_ast(t, m), decl);
  TypeId result = TYPE_NONE;
  switch (d->kind) {
    case NODE_PARAMETER:
      result = lower_type_in(t, m, d->as.parameter.type);
      break;
    case NODE_FIELD:
      result = lower_type_in(t, m, d->as.field.type);
      break;
    case NODE_CONST:
      result = lower_type_in(t, m, d->as.const_def.type);
      break;
    case NODE_LET:
      result = lower_type_in(t, m, d->as.let_stmt.type);
      break;
    case NODE_FUNCTION:
      result = ast_intern_type(t->ast, (Ty){.kind = TYPE_FUNCTION, .module = m, .as.decl = decl});
      break;
    case NODE_STRUCT:
    case NODE_ENUM:
    case NODE_GENERIC_PARAM:
      result = named_type_of(t, m, decl);
      break;
    default:
      break;
  }
  if (local)
    ast_set_type(t->ast, decl, result);
  return result;
}

static TypeId decl_type(TypeChecker *t, const NodeId decl) {
  return decl_type_in(t, t->ast->module, decl);
}

// Result type of a unary operator applied to an operand of type `opnd`.
static TypeId check_unary(TypeChecker *t, const Node *const n, const NodeId id) {
  const TypeId opnd = check_expr(t, n->as.unary.operand);
  const Span sp = ast_at_const(t->ast, id)->span;
  switch (n->as.unary.op) {
    case Minus:
      if (opnd != TYPE_NONE && !is_numeric(t, opnd))
        typechecker_errorf(t, sp.start, sp.end - sp.start, "unary '-' requires a numeric operand");
      return opnd;
    case Bang:
      if (opnd != TYPE_NONE && !is_bool(t, opnd))
        typechecker_errorf(t, sp.start, sp.end - sp.start, "unary '!' requires a 'bool' operand");
      return ast_builtin(BT_BOOL);
    case Tilde:
      if (opnd != TYPE_NONE && !is_int(t, opnd))
        typechecker_errorf(t, sp.start, sp.end - sp.start, "unary '~' requires an integer operand");
      return opnd;
    case Star: { // dereference
      if (opnd == TYPE_NONE)
        return TYPE_NONE;
      const Ty *const ot = ast_type_at(t->ast, opnd);
      if (ot->kind == TYPE_POINTER || ot->kind == TYPE_REFERENCE)
        return ot->as.elem;
      typechecker_errorf(t, sp.start, sp.end - sp.start, "cannot dereference a non-pointer");
      return TYPE_NONE;
    }
    case Ampersand: // address-of: `&x` -> `&T`, `&mut x` -> `&mut T`
      return ast_intern_type(t->ast, (Ty){.kind = TYPE_REFERENCE, .qualifier = n->as.unary.qualifier, .as.elem = opnd});
    default: // Move, Unsafe (and any future prefix) pass the operand's type through
      return opnd;
  }
}

// Numeric binary operator (arithmetic/bitwise/shift): operands must be numeric (integer if
// `require_int`) and agree, with a literal adapting to the concrete side. Returns the result type.
static TypeId binary_numeric(
    TypeChecker *t, const NodeId id, const TypeId l, const NodeId ln, const TypeId r, const NodeId rn,
    const bool require_int) {
  if (l == TYPE_NONE || r == TYPE_NONE)
    return TYPE_NONE;
  const Span sp = ast_at_const(t->ast, id)->span;
  const bool ok = require_int ? (is_int(t, l) && is_int(t, r)) : (is_numeric(t, l) && is_numeric(t, r));
  if (!ok) {
    typechecker_errorf(
        t, sp.start, sp.end - sp.start, "operator requires %s operands", require_int ? "integer" : "numeric");
    return TYPE_NONE;
  }
  if (l == r)
    return l;
  if (ast_at_const(t->ast, ln)->kind == NODE_LITERAL) // l adapts to r
    return r;
  if (ast_at_const(t->ast, rn)->kind == NODE_LITERAL) // r adapts to l
    return l;
  err_mismatch(t, rn, l);
  return l;
}

// Pointer arithmetic for + / -: `ptr ± int → ptr`, `int + ptr → ptr`, `ptr − ptr → isize`. Sets
// `*handled` when at least one operand is a pointer (so the caller skips the numeric rules),
// emitting a diagnostic for ill-formed combinations.
static TypeId check_ptr_arith(
    TypeChecker *t, const Node *const n, const NodeId id, const TypeId l, const TypeId r, bool *const handled) {
  *handled = false;
  if (l == TYPE_NONE || r == TYPE_NONE)
    return TYPE_NONE;
  const bool lp = ast_type_at(t->ast, l)->kind == TYPE_POINTER, rp = ast_type_at(t->ast, r)->kind == TYPE_POINTER;
  if (!lp && !rp)
    return TYPE_NONE; // ordinary numeric operands
  *handled = true;
  const Span sp = ast_at_const(t->ast, id)->span;
  const bool minus = n->as.binary.op == Minus;
  if (lp && rp) {
    if (minus && l == r)
      return ast_builtin(BT_ISIZE); // pointer difference
    typechecker_errorf(t, sp.start, sp.end - sp.start, "invalid pointer arithmetic");
    return TYPE_NONE;
  }
  if (lp && is_int(t, r))
    return l; // ptr ± int
  if (rp && !minus && is_int(t, l))
    return r; // int + ptr
  typechecker_errorf(t, sp.start, sp.end - sp.start, "pointer arithmetic requires an integer offset");
  return TYPE_NONE;
}

static TypeId check_binary(TypeChecker *t, const Node *const n, const NodeId id) {
  const NodeId ln = n->as.binary.left, rn = n->as.binary.right;
  const TypeId l = check_expr(t, ln), r = check_expr(t, rn);
  const Span sp = ast_at_const(t->ast, id)->span;
  switch (n->as.binary.op) {
    case Plus:
    case Minus: {
      bool handled;
      const TypeId pt = check_ptr_arith(t, n, id, l, r, &handled);
      if (handled)
        return pt;
      return binary_numeric(t, id, l, ln, r, rn, false);
    }
    case Star:
    case Slash:
    case Percent:
      return binary_numeric(t, id, l, ln, r, rn, false);
    case Ampersand:
    case Pipe:
    case Caret:
    case LeftShift:
    case RightShift:
      return binary_numeric(t, id, l, ln, r, rn, true);
    case AmpersandAmpersand:
    case PipePipe:
      if ((l != TYPE_NONE && !is_bool(t, l)) || (r != TYPE_NONE && !is_bool(t, r)))
        typechecker_errorf(t, sp.start, sp.end - sp.start, "logical operator requires 'bool' operands");
      return ast_builtin(BT_BOOL);
    default: // comparisons (==, !=, <, <=, >, >=)
      if (l != TYPE_NONE && r != TYPE_NONE && l != r && !compatible(t, l, rn) && !compatible(t, r, ln))
        err_mismatch(t, rn, l);
      return ast_builtin(BT_BOOL);
  }
}

// Can the lvalue at `node` be assigned to? A mutable `let`, a deref/index/member reached through
// something mutable. Parameters and consts are immutable.
static bool is_assignable(TypeChecker *t, const NodeId node) {
  const Node *const n = ast_at_const(t->ast, node);
  switch (n->kind) {
    case NODE_IDENTIFIER: {
      const NodeId d = ast_resolution(t->ast, node);
      if (d == NODE_NONE)
        return false;
      const Node *const dn = ast_at_const(t->ast, d);
      if (dn->kind == NODE_LET)
        return dn->as.let_stmt.is_mutable;
      if (dn->kind == NODE_PARAMETER) // `fn f(mut p: T)` makes the by-value parameter assignable
        return dn->as.parameter.is_mutable;
      if (dn->kind == NODE_IDENTIFIER) { // a tuple-let element: its resolution back-points to the let
        const NodeId let = ast_resolution(t->ast, d);
        return let != NODE_NONE && ast_at_const(t->ast, let)->kind == NODE_LET &&
               ast_at_const(t->ast, let)->as.let_stmt.is_mutable;
      }
      return false;
    }
    case NODE_UNARY: {
      if (n->as.unary.op != Star)
        return false;
      const Ty *const ot = ast_type_at(t->ast, ast_type(t->ast, n->as.unary.operand));
      return (ot->kind == TYPE_POINTER || ot->kind == TYPE_REFERENCE) && ot->qualifier == TYPE_QUAL_MUT;
    }
    case NODE_INDEX:
    case NODE_MEMBER: {
      const NodeId obj = n->kind == NODE_INDEX ? n->as.index.object : n->as.member.object;
      if (is_assignable(t, obj))
        return true;
      const Ty *const ot = ast_type_at(t->ast, ast_type(t->ast, obj)); // auto-deref through a mutable pointer
      return (ot->kind == TYPE_POINTER || ot->kind == TYPE_REFERENCE) && ot->qualifier == TYPE_QUAL_MUT;
    }
    default:
      return false;
  }
}

// `Enum::Variant` as an expression yields the enum type; `Type::method` yields the associated function
// type (normally consumed by check_call). Handles imports: a direct `mod::Name` (recorded on this node
// by the resolver) and a nested `(mod::Type)::method`.
static TypeId check_path_member(TypeChecker *t, const Node *const n, const NodeId id) {
  // Direct module-qualified reference recorded by the resolver: `mod::Name` -> a type or a free function.
  const DefId direct = ast_resolution_def(t->ast, id);
  if (direct.node != NODE_NONE) {
    if (ast_at_const(mod_ast(t, direct.module), direct.node)->kind == NODE_FUNCTION) {
      ast_set_resolution_def(t->ast, n->as.member.member, direct);
      return decl_type_in(t, direct.module, direct.node);
    }
    return named_type_of(t, direct.module, direct.node); // a type, used as the base of a further `::`
  }

  const NodeId obj = n->as.member.object;
  const Node *const on = ast_at_const(t->ast, obj);
  ModuleId bmod;
  NodeId bdecl;
  TypeId inst_ty = TYPE_NONE; // set when the base is a generic instance (`Opt::<i32>`): variants yield it
  if (on->kind == NODE_IDENTIFIER) {
    const DefId b = ast_resolution_def(t->ast, obj); // carries the module too (a prelude type isn't local)
    bmod = b.module;
    bdecl = b.node;
  } else { // nested base, e.g. `(mod::Type)::method` or `Opt::<i32>::Variant`
    const TypeId bt = check_expr(t, obj);
    const Ty *const ty = ast_type_at(t->ast, bt);
    if (ty->kind == TYPE_INSTANCE) {
      const TyInstance *const it = ast_instance(t->ast, ty->as.inst);
      bmod = it->module;
      bdecl = it->decl;
      inst_ty = bt;
    } else {
      bmod = ty->module;
      bdecl = bt != TYPE_NONE && (ty->kind == TYPE_STRUCT || ty->kind == TYPE_ENUM) ? ty->as.decl : NODE_NONE;
    }
  }
  const Span mname = name_span(t, n->as.member.member);
  const Node *const bd = bdecl == NODE_NONE ? NULL : ast_at_const(mod_ast(t, bmod), bdecl);
  if (!bd || (bd->kind != NODE_STRUCT && bd->kind != NODE_ENUM)) {
    typechecker_errorf(t, n->span.start, n->span.end - n->span.start, "'::' base must be a struct or enum type");
    return TYPE_NONE;
  }
  if (bd->kind == NODE_ENUM) {
    const NodeId variant = find_member(t, bmod, bdecl, mname);
    if (variant != NODE_NONE && ast_at_const(mod_ast(t, bmod), variant)->kind == NODE_VARIANT) {
      ast_set_resolution_def(t->ast, n->as.member.member, (DefId){bmod, variant});
      return inst_ty != TYPE_NONE ? inst_ty : named_type_of(t, bmod, bdecl);
    }
  }
  const DefId method = find_method(t, bmod, bdecl, mname);
  if (method.node != NODE_NONE) {
    ast_set_resolution_def(t->ast, n->as.member.member, method);
    return decl_type_in(t, method.module, method.node);
  }
  typechecker_errorf(
      t, mname.start, mname.end - mname.start, "no %s '%.*s' on this %s",
      bd->kind == NODE_ENUM ? "variant or method" : "associated method", (int)(mname.end - mname.start),
      t->source + mname.start, bd->kind == NODE_ENUM ? "enum" : "struct");
  return TYPE_NONE;
}

// `Enum::Variant(args)` construction: arity- and type-check the payload, yield the enum type. The
// variant (and its payload type nodes) live in module `vmod`; the argument expressions are local.
static TypeId check_variant_call(
    TypeChecker *t, const Node *const n, const NodeId id, const ModuleId vmod, const NodeId variant,
    const TypeId enum_ty) {
  const NodeList args = n->as.call.args;
  const NodeId *const aids = ast_list(t->ast, args);
  for (uint32_t i = 0; i < args.len; i++)
    check_expr(t, aids[i]);
  Ast *const va = mod_ast(t, vmod);
  const NodeList payload = ast_at_const(va, variant)->as.variant.payload;
  const NodeId *const pl = ast_list(va, payload);
  const Span sp = ast_at_const(t->ast, id)->span;
  // A generic enum instance (`Opt<i32>`) substitutes its type args into the (generic) payload types.
  ModuleId amod;
  NodeId adecl;
  DefId gp[4];
  TypeId ga[4];
  int gn = 0;
  const bool inst = aggregate_of(t, enum_ty, &amod, &adecl, gp, ga, &gn);
  if (args.len != payload.len) {
    typechecker_errorf(
        t, sp.start, sp.end - sp.start, "variant expects %u argument%s, found %u", payload.len,
        payload.len == 1 ? "" : "s", args.len);
  } else {
    for (uint32_t i = 0; i < args.len; i++) {
      const Node *const pe = ast_at_const(va, pl[i]);
      const TypeId raw = lower_type_in(t, vmod, pe->kind == NODE_FIELD ? pe->as.field.type : pl[i]);
      const TypeId pt = inst ? subst_type(t, raw, gp, ga, gn) : raw;
      if (!compatible(t, pt, aids[i]))
        err_mismatch(t, aids[i], pt);
    }
  }
  return enum_ty;
}

// Rewrite `ty`, replacing each generic type param (matched by DefId against `params[i]`) with the
// concrete `args[i]`, recursing through pointer/reference/slice/array layers. Used to monomorphize a
// generic call's parameter and return types from its (turbofish or inferred) type arguments.
static TypeId subst_type(TypeChecker *t, const TypeId ty, const DefId *const params, const TypeId *const args,
                         const int n) {
  if (ty == TYPE_NONE || n == 0)
    return ty;
  const Ty *const y = ast_type_at(t->ast, ty);
  switch (y->kind) {
    case TYPE_GENERIC:
      for (int i = 0; i < n; i++)
        if (params[i].module == y->module && params[i].node == y->as.decl)
          return args[i];
      return ty;
    case TYPE_POINTER:
    case TYPE_REFERENCE:
    case TYPE_SLICE:
    case TYPE_ARRAY: {
      const TypeId e = subst_type(t, y->as.elem, params, args, n);
      if (e == y->as.elem)
        return ty;
      Ty nt = *y;
      nt.as.elem = e;
      return ast_intern_type(t->ast, nt);
    }
    case TYPE_INSTANCE: { // substitute inside a generic application, e.g. Box<T> -> Box<i32>
      const TyInstance src = *ast_instance(t->ast, y->as.inst); // copy: interning below may grow the table
      TypeId na[4];
      bool changed = false;
      for (uint8_t i = 0; i < src.n; i++) {
        na[i] = subst_type(t, src.args[i], params, args, n);
        changed |= na[i] != src.args[i];
      }
      return changed ? ast_intern_instance(t->ast, src.module, src.decl, na, src.n) : ty;
    }
    default:
      return ty;
  }
}

// Infer generic type args by matching a declared (possibly generic) parameter type against an actual
// argument type: a bare `T` binds to the argument; pointer/ref/slice/array layers recurse. Fills
// `bound[i]` (by param index) the first time each param is seen.
static void unify_infer(TypeChecker *t, const TypeId param_ty, const TypeId arg_ty, const DefId *const params,
                        TypeId *const bound, const int n) {
  if (param_ty == TYPE_NONE || arg_ty == TYPE_NONE)
    return;
  const Ty *const p = ast_type_at(t->ast, param_ty);
  if (p->kind == TYPE_GENERIC) {
    for (int i = 0; i < n; i++)
      if (params[i].module == p->module && params[i].node == p->as.decl) {
        if (bound[i] == TYPE_NONE)
          bound[i] = arg_ty;
        return;
      }
    return;
  }
  const Ty *const aT = ast_type_at(t->ast, arg_ty);
  if (aT->kind == p->kind &&
      (p->kind == TYPE_POINTER || p->kind == TYPE_REFERENCE || p->kind == TYPE_SLICE || p->kind == TYPE_ARRAY))
    unify_infer(t, p->as.elem, aT->as.elem, params, bound, n);
  else if (p->kind == TYPE_INSTANCE && aT->kind == TYPE_INSTANCE) { // Box<T> against Box<i32> -> T = i32
    const TyInstance *const pi = ast_instance(t->ast, p->as.inst);
    const TyInstance *const ai = ast_instance(t->ast, aT->as.inst);
    if (pi->decl == ai->decl && pi->module == ai->module && pi->n == ai->n)
      for (uint8_t i = 0; i < pi->n; i++)
        unify_infer(t, pi->args[i], ai->args[i], params, bound, n);
  } else if (p->kind == TYPE_FUNCTION && aT->kind == TYPE_FUNCTION) { // fn(T) U against fn(i32) i32 -> U = i32
    TypeId pp[4], ap[4], pr, ar;
    const int pn = fn_sig(t, p, pp, 4, &pr), an = fn_sig(t, aT, ap, 4, &ar);
    if (pn == an && pn <= 4) {
      for (int i = 0; i < pn; i++)
        unify_infer(t, pp[i], ap[i], params, bound, n);
      unify_infer(t, pr, ar, params, bound, n);
    }
  }
}

// Structural fn-type compatibility for a `fn(..) ..` parameter at a generic call: the expected (param)
// side's positions are first substituted through the call's generic + receiver-instance maps (so a
// param `fn(T) U` becomes `fn(i32) i32` before matching the concrete argument function).
static bool fn_compatible_subst(TypeChecker *t, const Ty *const ex, const Ty *const ac, const DefId *const gp,
                                const TypeId *const ga, const int gn, const DefId *const rp, const TypeId *const ra,
                                const int rn) {
  TypeId ep[4], ap[4], er, ar;
  const int en = fn_sig(t, ex, ep, 4, &er), an = fn_sig(t, ac, ap, 4, &ar);
  if (en != an || en > 4)
    return false;
  if (!ret_eq(subst_type(t, subst_type(t, er, gp, ga, gn), rp, ra, rn), ar))
    return false;
  for (int i = 0; i < en; i++)
    if (subst_type(t, subst_type(t, ep[i], gp, ga, gn), rp, ra, rn) != ap[i])
      return false;
  return true;
}

static TypeId check_call(TypeChecker *t, const Node *const n, const NodeId id) {
  // `Enum::Variant(args)` is construction, not a function call.
  const Node *const path_callee = ast_at_const(t->ast, n->as.call.callee);
  TypeId callee = TYPE_NONE;
  if (path_callee->kind == NODE_MEMBER && path_callee->as.member.path) {
    callee = check_expr(t, n->as.call.callee);
    const DefId vd = ast_resolution_def(t->ast, path_callee->as.member.member);
    if (vd.node != NODE_NONE && ast_at_const(mod_ast(t, vd.module), vd.node)->kind == NODE_VARIANT)
      return check_variant_call(t, n, id, vd.module, vd.node, callee);
  } else if (path_callee->kind == NODE_MEMBER) {
    callee = check_member(t, path_callee, true); // `obj.name(args)`: resolve `name` as a method, not a field
  } else {
    callee = check_expr(t, n->as.call.callee);
  }
  const NodeList args = n->as.call.args;
  const NodeId *const aids = ast_list(t->ast, args);
  for (uint32_t i = 0; i < args.len; i++)
    check_expr(t, aids[i]);

  if (callee == TYPE_NONE)
    return TYPE_NONE;
  const Ty *const ct = ast_type_at(t->ast, callee);
  const Span sp = ast_at_const(t->ast, id)->span;
  if (ct->kind != TYPE_FUNCTION) {
    typechecker_errorf(t, sp.start, sp.end - sp.start, "called value is not a function");
    return TYPE_NONE;
  }

  const ModuleId fmod = ct->module;        // the called function lives in this module
  Ast *const fa = mod_ast(t, fmod);
  const Node *const fn = ast_at_const(fa, ct->as.decl);
  const bool named = fn->kind == NODE_FUNCTION;
  const bool clos = fn->kind == NODE_CLOSURE;
  const NodeList params = named ? fn->as.function.params : clos ? fn->as.closure.params : fn->as.function_type.params;
  const NodeList returns = named ? fn->as.function.returns : clos ? fn->as.closure.returns : fn->as.function_type.returns;

  // A method call `obj.m(args)` binds the receiver to the first (self) parameter implicitly.
  uint32_t skip = 0;
  const Node *const callee_node = ast_at_const(t->ast, n->as.call.callee);
  if (named && callee_node->kind == NODE_MEMBER && !callee_node->as.member.path && params.len > 0) {
    const DefId md = ast_resolution_def(t->ast, callee_node->as.member.member);
    if (md.node != NODE_NONE && ast_at_const(mod_ast(t, md.module), md.node)->kind == NODE_FUNCTION)
      skip = 1;
  }

  // A method or associated fn reached through a generic instance (`b.get()`, `Box::<i32>::make()`)
  // substitutes the instance's type args into the signature via the impl's own generics. The instance is
  // the member's object type (the receiver, or the `Type::<Args>` base); the impl declares its generics
  // bound positionally to the instance args by its target type (`extend<T> Box<T>`).
  DefId rsubp[4];
  TypeId rsuba[4];
  int nrsub = 0;
  if (callee_node->kind == NODE_MEMBER) {
    const DefId md = ast_resolution_def(t->ast, callee_node->as.member.member);
    ModuleId rmod;
    NodeId rdecl;
    DefId sp[4];
    TypeId sa[4];
    int sn = 0;
    if (md.node != NODE_NONE && ast_at_const(mod_ast(t, md.module), md.node)->kind == NODE_FUNCTION &&
        aggregate_of(t, strip(t, ast_type(t->ast, callee_node->as.member.object)), &rmod, &rdecl, sp, sa, &sn) && sn > 0) {
      const NodeId impl = enclosing_impl(t, md.module, md.node);
      if (impl != NODE_NONE) {
        const NodeList ig = ast_at_const(mod_ast(t, md.module), impl)->as.impl_def.generics;
        const NodeId *const gids = ast_list(mod_ast(t, md.module), ig);
        const int g = (int)ig.len < sn ? (int)ig.len : sn;
        for (int i = 0; i < g && nrsub < 4; i++) {
          rsubp[nrsub] = (DefId){md.module, gids[i]};
          rsuba[nrsub] = sa[i];
          nrsub++;
        }
      }
    }
  }

  // A method reached through a generic bound (`w.write()`, `w: T`, `T: Writer`) is the interface's method;
  // substitute its `Self` (a TYPE_GENERIC of the trait) by the receiver type so the signature resolves.
  if (callee_node->kind == NODE_MEMBER && !callee_node->as.member.path && nrsub < 4) {
    const DefId md = ast_resolution_def(t->ast, callee_node->as.member.member);
    const NodeId tr = md.node != NODE_NONE ? enclosing_trait(t, md.module, md.node) : NODE_NONE;
    if (tr != NODE_NONE) {
      rsubp[nrsub] = (DefId){md.module, tr};
      rsuba[nrsub] = strip(t, ast_type(t->ast, callee_node->as.member.object));
      nrsub++;
    }
  }

  // Generic call: bind the function's type params from explicit turbofish args or by inferring them from
  // the argument types, then substitute into the parameter/return types so `fn id<T>(x: T) T` checks and
  // yields a concrete type. The bound args are recorded on the call so codegen emits the matching
  // specialization (`id__i32`).
  DefId gparams[8];
  TypeId gargs[8];
  int gn = 0;
  const Node *const callee_n = ast_at_const(t->ast, n->as.call.callee);
  if (named && fn->as.function.generics.len) {
    const NodeList gens = fn->as.function.generics;
    const NodeId *const gids = ast_list(fa, gens);
    const int g = gens.len < 8 ? (int)gens.len : 8;
    for (int i = 0; i < g; i++)
      gparams[i] = (DefId){fmod, gids[i]};
    if (callee_n->kind == NODE_GENERIC_SPECIALIZATION) { // explicit turbofish
      const NodeList tas = callee_n->as.specialization.types;
      const NodeId *const taids = ast_list(t->ast, tas);
      for (uint32_t i = 0; i < tas.len && gn < g; i++)
        gargs[gn++] = ast_type(t->ast, taids[i]);
    } else if (args.len == params.len - skip) { // infer from argument types
      TypeId bound[8];
      for (int i = 0; i < g; i++)
        bound[i] = TYPE_NONE;
      const NodeId *const pids = ast_list(fa, params);
      for (uint32_t i = 0; i < args.len; i++)
        unify_infer(t, decl_type_in(t, fmod, pids[i + skip]), ast_type(t->ast, aids[i]), gparams, bound, g);
      for (int i = 0; i < g; i++)
        gargs[i] = bound[i]; // may stay TYPE_NONE if a param couldn't be inferred
      gn = g;
    }
    if (gn == g) { // fully determined: record for codegen's specialization, then enforce interface bounds
      ast_set_type_args(t->ast, id, gargs, (uint8_t)gn);
      for (int i = 0; i < g; i++) {
        const NodeList pb = ast_at_const(fa, gids[i])->as.generic_param.bounds;
        const NodeId *const pbids = ast_list(fa, pb);
        for (uint32_t b = 0; b < pb.len; b++) {
          const DefId bi = ast_resolution_def(fa, pbids[b]);
          if (bi.node != NODE_NONE && !type_satisfies(t, gargs[i], bi, 0)) {
            char tn[96];
            render_type(t, gargs[i], tn, sizeof tn);
            const Span bsp = ast_at_const(fa, pbids[b])->span;
            typechecker_errorf(
                t, sp.start, sp.end - sp.start, "type '%s' does not satisfy bound '%.*s'", tn,
                (int)(bsp.end - bsp.start), (const char *)mod_src(t, fmod) + bsp.start);
          }
        }
      }
      // `where T: Bound` predicates: lower each predicate type with the type args applied, then check it.
      const NodeList wc = fn->as.function.where_clause;
      const NodeId *const wids = ast_list(fa, wc);
      for (uint32_t w = 0; w < wc.len; w++) {
        const Node *const wp = ast_at_const(fa, wids[w]);
        const TypeId wt = subst_type(t, lower_type_in(t, fmod, wp->as.where_predicate.type), gparams, gargs, gn);
        const NodeList wb = wp->as.where_predicate.bounds;
        const NodeId *const wbids = ast_list(fa, wb);
        for (uint32_t b = 0; b < wb.len; b++) {
          const DefId bi = ast_resolution_def(fa, wbids[b]);
          if (bi.node != NODE_NONE && !type_satisfies(t, wt, bi, 0)) {
            char tn[96];
            render_type(t, wt, tn, sizeof tn);
            const Span bsp = ast_at_const(fa, wbids[b])->span;
            typechecker_errorf(
                t, sp.start, sp.end - sp.start, "type '%s' does not satisfy bound '%.*s'", tn,
                (int)(bsp.end - bsp.start), (const char *)mod_src(t, fmod) + bsp.start);
          }
        }
      }
    }
  }

  const uint32_t expected = params.len - skip;
  if (args.len != expected) {
    typechecker_errorf(
        t, sp.start, sp.end - sp.start, "expected %u argument%s, found %u", expected, expected == 1 ? "" : "s",
        args.len);
  } else {
    const NodeId *const pids = ast_list(fa, params);
    for (uint32_t i = 0; i < args.len; i++) {
      const TypeId raw = named ? decl_type_in(t, fmod, pids[i + skip]) : lower_type_in(t, fmod, pids[i + skip]);
      const TypeId pt = subst_type(t, subst_type(t, raw, gparams, gargs, gn), rsubp, rsuba, nrsub);
      // A `fn(..) ..` parameter carries generics inside the function type that plain subst_type can't
      // rewrite; compare it structurally with the call's substitutions applied per signature position.
      const Ty *const ptt = ast_type_at(t->ast, pt);
      if (ptt->kind == TYPE_FUNCTION) {
        const TypeId at = ast_type(t->ast, aids[i]);
        const Ty *const att = at == TYPE_NONE ? NULL : ast_type_at(t->ast, at);
        if (!att || att->kind != TYPE_FUNCTION ||
            !fn_compatible_subst(t, ptt, att, gparams, gargs, gn, rsubp, rsuba, nrsub))
          err_mismatch(t, aids[i], pt);
        continue;
      }
      if (!compatible(t, pt, aids[i]))
        err_mismatch(t, aids[i], pt);
    }
  }
  if (clos && fn->as.closure.expr_body)
    return ast_type(fa, fn->as.closure.body); // compact closure callee: return type inferred from its body
  if (returns.len != 1)
    return TYPE_NONE; // 0 or multiple returns: no single value type yet
  const NodeId r0 = ast_list(fa, returns)[0];
  const Node *const rn = ast_at_const(fa, r0);
  const TypeId ret = lower_type_in(t, fmod, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : r0);
  return subst_type(t, subst_type(t, ret, gparams, gargs, gn), rsubp, rsuba, nrsub);
}

// A non-`pub` struct field of `owner` (in module `m`) may only be named from inside `owner`'s own
// `extend` blocks (same module, current_self == owner). A private field of an imported struct is always
// inaccessible. `at` is the access span (the field name); enum variants are exempt.
static void check_field_visibility(TypeChecker *t, const ModuleId m, const NodeId field, const NodeId owner, const Span at) {
  const Node *const f = ast_at_const(mod_ast(t, m), field);
  const bool inside_owner = (!t->package || m == t->ast->module) && owner == t->current_self;
  if (f->kind == NODE_FIELD && !f->as.field.is_public && !inside_owner)
    typechecker_errorf(
        t, at.start, at.end - at.start, "field '%.*s' is private", (int)(at.end - at.start), t->source + at.start);
}

// `prefer_method` is set when this member is the callee of a call (`obj.name(...)`): a method then wins
// over a same-named field, since `s.len()` (method call) and `s.len` (field read) are different things.
// Unwrap a struct/enum type -- plain or a generic instance -- to its owning module + decl, and (for an
// instance) the type-param -> concrete-arg substitution to apply to member types. Returns false otherwise.
static bool aggregate_of(TypeChecker *t, const TypeId ty, ModuleId *const mod, NodeId *const decl,
                         DefId *const params, TypeId *const args, int *const n) {
  *n = 0;
  const Ty *const y = ast_type_at(t->ast, ty);
  if (y->kind == TYPE_STRUCT || y->kind == TYPE_ENUM) {
    *mod = y->module;
    *decl = y->as.decl;
    return true;
  }
  if (y->kind == TYPE_INSTANCE) {
    const TyInstance *const it = ast_instance(t->ast, y->as.inst);
    *mod = it->module;
    *decl = it->decl;
    const Ast *const da = mod_ast(t, it->module);
    const NodeList gens = ast_at_const(da, it->decl)->as.aggregate.generics;
    const NodeId *const gids = ast_list(da, gens);
    for (uint32_t i = 0; i < gens.len && i < it->n && *n < 4; i++) {
      params[*n] = (DefId){it->module, gids[i]};
      args[*n] = it->args[i];
      (*n)++;
    }
    return true;
  }
  return false;
}

static TypeId check_member(TypeChecker *t, const Node *const n, const bool prefer_method) {
  const TypeId obj = check_expr(t, n->as.member.object);
  if (obj == TYPE_NONE)
    return TYPE_NONE;
  const NodeId mname = n->as.member.member;
  const Span name = name_span(t, mname);
  const TypeId base = strip(t, obj);
  ModuleId bmod;
  NodeId bdecl;
  DefId gp[4];
  TypeId ga[4];
  int gn;
  if (aggregate_of(t, base, &bmod, &bdecl, gp, ga, &gn)) {
    // Look up the preferred namespace first (method for a call, field for a bare access), then the other.
    // A method may live in another module (a local extension of an imported type); a field is always in bmod.
    // For a generic instance, member types are substituted by the instance's type args.
    DefId mhit = {0, NODE_NONE};
    NodeId fhit = NODE_NONE;
    if (prefer_method) {
      mhit = find_method(t, bmod, bdecl, name);
      if (mhit.node == NODE_NONE)
        fhit = find_member(t, bmod, bdecl, name);
    } else {
      fhit = find_member(t, bmod, bdecl, name);
      if (fhit == NODE_NONE)
        mhit = find_method(t, bmod, bdecl, name);
    }
    if (mhit.node != NODE_NONE) {
      ast_set_resolution_def(t->ast, mname, mhit);
      return subst_type(t, decl_type_in(t, mhit.module, mhit.node), gp, ga, gn);
    }
    if (fhit != NODE_NONE) {
      ast_set_resolution_def(t->ast, mname, (DefId){bmod, fhit});
      if (ast_at_const(mod_ast(t, bmod), fhit)->kind == NODE_FIELD)
        check_field_visibility(t, bmod, fhit, bdecl, name);
      return subst_type(t, decl_type_in(t, bmod, fhit), gp, ga, gn);
    }
  }
  // A method on a value of generic-parameter type (`w: T` with `T: Writer`): resolve it through the
  // param's interface bounds. `Self` stays abstract (TYPE_GENERIC of the trait); check_call substitutes
  // it by the receiver, and codegen dispatches to the concrete impl once the param is monomorphized.
  const Ty *const bt = ast_type_at(t->ast, base);
  if (bt->kind == TYPE_GENERIC) {
    DefId iface;
    const DefId m = find_bound_method(t, bt->module, bt->as.decl, name, &iface);
    if (m.node != NODE_NONE) {
      ast_set_resolution_def(t->ast, mname, m);
      return decl_type_in(t, m.module, m.node);
    }
  }
  char ty[96];
  render_type(t, base, ty, sizeof ty);
  typechecker_errorf(
      t, name.start, name.end - name.start, "no field or method '%.*s' on '%s'", (int)(name.end - name.start),
      t->source + name.start, ty);
  return TYPE_NONE;
}

static TypeId check_struct_init(TypeChecker *t, const Node *const n) {
  const TypeId sty = type_of_type_node(t, n->as.struct_initializer.type);
  ModuleId smod;
  NodeId decl = NODE_NONE;
  DefId gp[4];
  TypeId ga[4];
  int gn = 0;
  if (!aggregate_of(t, sty, &smod, &decl, gp, ga, &gn))
    decl = NODE_NONE;
  // `Enum::Variant { f: .. }` constructs a struct-payload variant: its fields live in the variant's
  // payload (set as the type path's last segment's resolution), and the value's type is the enum.
  NodeId variant = NODE_NONE;
  ModuleId vmod = smod;
  const NodeId stn = n->as.struct_initializer.type;
  if (ast_at_const(t->ast, stn)->kind == NODE_TYPE_PATH) {
    const NodeList parts = ast_at_const(t->ast, stn)->as.type_path.parts;
    if (parts.len >= 2) {
      const DefId vd = ast_resolution_def(t->ast, ast_list(t->ast, parts)[parts.len - 1]);
      if (vd.node != NODE_NONE && ast_at_const(mod_ast(t, vd.module), vd.node)->kind == NODE_VARIANT) {
        variant = vd.node;
        vmod = vd.module;
      }
    }
  }
  const NodeList fields = n->as.struct_initializer.fields;
  const NodeId *const ids = ast_list(t->ast, fields);
  for (uint32_t i = 0; i < fields.len; i++) {
    const Node *const fi = ast_at_const(t->ast, ids[i]);
    check_expr(t, fi->as.field_initializer.value);
    const Span fname = name_span(t, fi->as.field_initializer.name);
    if (variant != NODE_NONE) { // resolve the field against the variant's struct payload
      Ast *const va = mod_ast(t, vmod);
      const NodeList vpl = ast_at_const(va, variant)->as.variant.payload;
      const NodeId *const vplids = ast_list(va, vpl);
      NodeId field = NODE_NONE;
      for (uint32_t j = 0; j < vpl.len; j++) {
        const Node *const pf = ast_at_const(va, vplids[j]);
        if (pf->kind == NODE_FIELD &&
            spans_eq2(t->source, fname, mod_src(t, vmod), ast_at_const(va, pf->as.field.name)->as.name.text)) {
          field = vplids[j];
          break;
        }
      }
      if (field == NODE_NONE) {
        char ty[96];
        render_type(t, sty, ty, sizeof ty);
        typechecker_errorf(
            t, fname.start, fname.end - fname.start, "no field '%.*s' on '%s'", (int)(fname.end - fname.start),
            t->source + fname.start, ty);
        continue;
      }
      ast_set_resolution_def(t->ast, fi->as.field_initializer.name, (DefId){vmod, field});
      const TypeId ft = subst_type(t, lower_type_in(t, vmod, ast_at_const(va, field)->as.field.type), gp, ga, gn);
      if (!compatible(t, ft, fi->as.field_initializer.value))
        err_mismatch(t, fi->as.field_initializer.value, ft);
      continue;
    }
    if (decl == NODE_NONE)
      continue;
    const NodeId field = find_member(t, smod, decl, fname);
    if (field == NODE_NONE) {
      char ty[96];
      render_type(t, sty, ty, sizeof ty);
      typechecker_errorf(
          t, fname.start, fname.end - fname.start, "no field '%.*s' on '%s'", (int)(fname.end - fname.start),
          t->source + fname.start, ty);
      continue;
    }
    ast_set_resolution_def(t->ast, fi->as.field_initializer.name, (DefId){smod, field});
    check_field_visibility(t, smod, field, decl, fname); // can't initialize a private field from outside the struct
    const TypeId ft = subst_type(t, decl_type_in(t, smod, field), gp, ga, gn);
    if (!compatible(t, ft, fi->as.field_initializer.value))
      err_mismatch(t, fi->as.field_initializer.value, ft);
  }
  return sty;
}

static void check_if(TypeChecker *t, const Node *const n) {
  const TypeId c = check_expr(t, n->as.if_stmt.condition);
  if (c != TYPE_NONE && !is_bool(t, c)) {
    const Span sp = ast_at_const(t->ast, n->as.if_stmt.condition)->span;
    char ty[96];
    render_type(t, c, ty, sizeof ty);
    typechecker_errorf(t, sp.start, sp.end - sp.start, "if condition must be 'bool', found '%s'", ty);
  }
  check_stmt(t, n->as.if_stmt.then_branch);
  check_stmt(t, n->as.if_stmt.else_branch);
}

static TypeId check_expr(TypeChecker *t, const NodeId id) {
  if (id == NODE_NONE)
    return TYPE_NONE;
  Ast *const a = t->ast;
  const Node *const n = ast_at_const(a, id);
  TypeId result = TYPE_NONE;
  switch (n->kind) {
    case NODE_LITERAL:
      switch (n->as.literal.token_type) {
        case IntegerLiteral: result = ast_builtin(BT_I32); break;
        case FloatLiteral: result = ast_builtin(BT_F32); break; // default float; `compatible` still adapts it to f64
        case CharacterLiteral: result = ast_builtin(BT_CHAR); break;
        case ByteCharacterLiteral: result = ast_builtin(BT_U8); break;
        case True:
        case False: result = ast_builtin(BT_BOOL); break;
        case StringLiteral: result = prelude_str_type(t); break; // a `str` view over the literal bytes
        default: result = TYPE_NONE; break; // Null, RawString (deferred)
      }
      break;
    case NODE_IDENTIFIER: {
      // The decl may live in another module (a prelude / glob-imported function), so read its type from
      // the owning module via the full DefId -- `decl_type` alone would read the current module's pool.
      const DefId d = ast_resolution_def(a, id);
      result = decl_type_in(t, d.module, d.node);
      break;
    }
    case NODE_UNARY:
      result = check_unary(t, n, id);
      break;
    case NODE_BINARY:
      result = check_binary(t, n, id);
      break;
    case NODE_ASSIGNMENT: {
      const TypeId l = check_expr(t, n->as.binary.left);
      check_expr(t, n->as.binary.right);
      if (!is_assignable(t, n->as.binary.left)) {
        const Span sp = ast_at_const(a, n->as.binary.left)->span;
        typechecker_errorf(t, sp.start, sp.end - sp.start, "cannot assign to this expression");
      } else if (!compatible(t, l, n->as.binary.right)) {
        err_mismatch(t, n->as.binary.right, l);
      }
      result = l;
      break;
    }
    case NODE_CALL:
      result = check_call(t, n, id);
      break;
    case NODE_CLOSURE: {
      const NodeList params = n->as.closure.params;
      const NodeId *const pids = ast_list(a, params);
      for (uint32_t i = 0; i < params.len; i++)
        decl_type(t, pids[i]); // type each parameter so its body references resolve
      if (n->as.closure.expr_body) {
        check_expr(t, n->as.closure.body); // its type IS the closure's return type
      } else {
        const NodeList saved = t->current_returns; // a `return` inside an anon `fn` targets the closure
        t->current_returns = n->as.closure.returns;
        check_stmt(t, n->as.closure.body);
        t->current_returns = saved;
      }
      // The closure is a function value keyed on its own node, like a `fn(..) ..` pointer type.
      result = ast_intern_type(a, (Ty){.kind = TYPE_FUNCTION, .module = a->module, .as.decl = id});
      break;
    }
    case NODE_INDEX: {
      const TypeId obj = check_expr(t, n->as.index.object);
      const TypeId idx = check_expr(t, n->as.index.index);
      const Ty *const ot = ast_type_at(a, obj);
      if (obj != TYPE_NONE) {
        if (ot->kind == TYPE_ARRAY || ot->kind == TYPE_SLICE || ot->kind == TYPE_POINTER)
          result = ot->as.elem;
        else {
          const Span sp = ast_at_const(a, n->as.index.object)->span;
          typechecker_errorf(t, sp.start, sp.end - sp.start, "cannot index this expression");
        }
      }
      if (idx != TYPE_NONE && !is_int(t, idx) && ast_at_const(a, n->as.index.index)->kind != NODE_LITERAL) {
        const Span sp = ast_at_const(a, n->as.index.index)->span;
        typechecker_errorf(t, sp.start, sp.end - sp.start, "index must be an integer");
      }
      break;
    }
    case NODE_MEMBER:
      result = n->as.member.path ? check_path_member(t, n, id) : check_member(t, n, false);
      break;
    case NODE_CAST: {
      const TypeId src = check_expr(t, n->as.cast.expression);
      const TypeId dst = resolve_type(t, n->as.cast.type);
      if (src != TYPE_NONE && dst != TYPE_NONE && src != dst) {
        const TypeKind sk = ast_type_at(a, src)->kind, dk = ast_type_at(a, dst)->kind;
        const bool aggregate = sk == TYPE_STRUCT || sk == TYPE_ENUM || sk == TYPE_FUNCTION || dk == TYPE_STRUCT ||
                               dk == TYPE_ENUM || dk == TYPE_FUNCTION;
        // A payload-less enum and an integer are interconvertible (the discriminant value).
        const bool enum_int = (is_plain_enum(t, src) && is_int(t, dst)) || (is_plain_enum(t, dst) && is_int(t, src));
        if (aggregate && !enum_int) {
          char s[96], d[96];
          render_type(t, src, s, sizeof s);
          render_type(t, dst, d, sizeof d);
          const Span sp = n->span;
          typechecker_errorf(t, sp.start, sp.end - sp.start, "invalid cast from '%s' to '%s'", s, d);
        }
      }
      result = dst;
      break;
    }
    case NODE_SIZEOF:
      resolve_type(t, n->as.single.value); // validate the type; its byte size is a usize
      result = ast_builtin(BT_USIZE);
      break;
    case NODE_GENERIC_SPECIALIZATION: {
      const NodeId inner = n->as.specialization.expression;
      const NodeList types = n->as.specialization.types;
      const NodeId *const ids = ast_list(a, types);
      for (uint32_t i = 0; i < types.len; i++)
        resolve_type(t, ids[i]);
      // `Type::<Args>` over a generic enum/struct -> the interned instance type (so `Opt::<i32>::Variant`
      // and field access carry the concrete args); `f::<T>` over a function keeps the function type.
      const DefId d = ast_resolution_def(a, inner);
      const Node *const dn = d.node != NODE_NONE ? ast_at_const(mod_ast(t, d.module), d.node) : NULL;
      if (dn && (dn->kind == NODE_ENUM || dn->kind == NODE_STRUCT) && dn->as.aggregate.generics.len > 0 && types.len > 0) {
        TypeId ta[4];
        uint8_t tn = 0;
        for (uint32_t i = 0; i < types.len && tn < 4; i++)
          ta[tn++] = resolve_type(t, ids[i]);
        result = ast_intern_instance(t->ast, d.module, d.node, ta, tn);
      } else {
        result = check_expr(t, inner);
      }
      break;
    }
    case NODE_MATCH: {
      const TypeId scrut = check_expr(t, n->as.match_expr.value);
      const NodeList arms = n->as.match_expr.arms;
      const NodeId *const ids = ast_list(a, arms);
      bool first = true;
      for (uint32_t i = 0; i < arms.len; i++) {
        const Node *const arm = ast_at_const(a, ids[i]);
        check_pattern(t, arm->as.match_arm.pattern, scrut);
        const TypeId g = check_expr(t, arm->as.match_arm.guard);
        if (arm->as.match_arm.guard != NODE_NONE && g != TYPE_NONE && !is_bool(t, g)) {
          const Span sp = ast_at_const(a, arm->as.match_arm.guard)->span;
          typechecker_errorf(t, sp.start, sp.end - sp.start, "match guard must be 'bool'");
        }
        const TypeId body = check_expr(t, arm->as.match_arm.body);
        if (first) {
          result = body;
          first = false;
        } else if (result != body && body != TYPE_NONE && result != TYPE_NONE) {
          err_mismatch(t, arm->as.match_arm.body, result);
          result = TYPE_NONE;
        }
      }
      break;
    }
    case NODE_NEW: {
      const TypeId declared = resolve_type(t, n->as.new_expr.type);
      TypeId inner = declared;
      const NodeId init = n->as.new_expr.initializer;
      if (init != NODE_NONE) {
        const TypeId it = check_expr(t, init);
        if (ast_at_const(a, init)->kind == NODE_STRUCT_INITIALIZER)
          inner = it; // `new T { .. }`: the initializer already carries the new type
        else if (!compatible(t, declared, init)) // `new T(expr)`: expr must fit T
          err_mismatch(t, init, declared);
      }
      // `new` yields an owning `*mut T`: the freshly allocated pointee is writable.
      result = ast_intern_type(a, (Ty){.kind = TYPE_POINTER, .qualifier = TYPE_QUAL_MUT, .as.elem = inner});
      break;
    }
    case NODE_ARRAY_LITERAL: {
      // All elements must share one type T; the literal's type is `[T; N]` (N is recovered from
      // the element count at codegen, since the interned `Ty` does not carry the length).
      const NodeList elements = n->as.array_literal.elements;
      const NodeId *const ids = ast_list(a, elements);
      if (elements.len == 0) {
        typechecker_errorf(
            t, n->span.start, n->span.end - n->span.start, "cannot infer the element type of an empty array literal");
        break;
      }
      TypeId elem = TYPE_NONE;
      for (uint32_t i = 0; i < elements.len; i++) {
        const TypeId et = check_expr(t, ids[i]);
        if (i == 0)
          elem = et;
        else if (et != elem && et != TYPE_NONE && elem != TYPE_NONE) {
          // distinct fn decls intern to distinct TYPE_FUNCTION TypeIds; a homogeneous `[a, b]` of
          // matching-signature functions is still one element type, so unify those structurally.
          const Ty *const e0 = ast_type_at(a, elem), *const ei = ast_type_at(a, et);
          if (!(e0->kind == TYPE_FUNCTION && ei->kind == TYPE_FUNCTION && fn_compatible(t, e0, ei))) {
            err_mismatch(t, ids[i], elem);
            elem = TYPE_NONE;
          }
        }
      }
      if (elem != TYPE_NONE)
        result = ast_intern_type(a, (Ty){.kind = TYPE_ARRAY, .as.elem = elem});
      break;
    }
    case NODE_STRUCT_INITIALIZER:
      result = check_struct_init(t, n);
      break;
    case NODE_BLOCK: {
      const NodeList stmts = n->as.block.statements;
      const NodeId *const ids = ast_list(a, stmts);
      for (uint32_t i = 0; i < stmts.len; i++)
        check_stmt(t, ids[i]);
      if (stmts.len > 0) {
        const Node *const last = ast_at_const(a, ids[stmts.len - 1]);
        result = last->kind == NODE_EXPRESSION_STATEMENT ? ast_type(a, last->as.single.value) : ast_builtin(BT_VOID);
      } else {
        result = ast_builtin(BT_VOID);
      }
      break;
    }
    case NODE_IF: {
      // An `if` used as a value: both arms must agree, and an `else` is mandatory (a missing arm
      // would leave the value undefined). The arms are blocks whose tail expression is the value.
      const TypeId c = check_expr(t, n->as.if_stmt.condition);
      if (c != TYPE_NONE && !is_bool(t, c)) {
        const Span sp = ast_at_const(a, n->as.if_stmt.condition)->span;
        char ty[96];
        render_type(t, c, ty, sizeof ty);
        typechecker_errorf(t, sp.start, sp.end - sp.start, "if condition must be 'bool', found '%s'", ty);
      }
      const TypeId then_ty = check_expr(t, n->as.if_stmt.then_branch);
      if (n->as.if_stmt.else_branch == NODE_NONE) {
        typechecker_errorf(
            t, n->span.start, n->span.end - n->span.start, "an 'if' used as a value must have an 'else' branch");
        result = TYPE_NONE;
      } else {
        const TypeId else_ty = check_expr(t, n->as.if_stmt.else_branch);
        if (then_ty != else_ty && then_ty != TYPE_NONE && else_ty != TYPE_NONE) {
          err_mismatch(t, n->as.if_stmt.else_branch, then_ty);
          result = TYPE_NONE;
        } else {
          result = then_ty;
        }
      }
      break;
    }
    case NODE_RANGE: { // for-loop range; its type is the loop-variable type
      const TypeId s = check_expr(t, n->as.pattern_range.start);
      const TypeId e = check_expr(t, n->as.pattern_range.end);
      result = range_type(t, n, s, e);
      break;
    }
    default:
      break;
  }
  ast_set_type(a, id, result);
  return result;
}

// `let (a, b, ..) = call`: bind each name to the matching return type of a multi-value function call.
// The names carry their own types (each element identifier is its own decl); the let node has none.
static void check_tuple_let(TypeChecker *t, const Node *const n) {
  Ast *const a = t->ast;
  const Node *const nm = ast_at_const(a, n->as.let_stmt.name);
  const NodeList names = nm->as.pattern.children;
  const NodeId *const nids = ast_list(a, names);
  const NodeId value = n->as.let_stmt.value;
  check_expr(t, value); // types the callee even though a multi-return call yields no single value

  NodeList returns = {0, 0};
  bool ok = false;
  if (value != NODE_NONE && ast_at_const(a, value)->kind == NODE_CALL) {
    const NodeId calleeId = ast_at_const(a, value)->as.call.callee;
    const TypeId callee = ast_type(a, calleeId);
    if (callee != TYPE_NONE) {
      const Ty *const ct = ast_type_at(a, callee);
      if (ct->kind == TYPE_FUNCTION) {
        const Node *const fn = ast_at_const(a, ct->as.decl);
        returns = fn->kind == NODE_FUNCTION ? fn->as.function.returns : fn->as.function_type.returns;
        ok = true;
      }
    } else { // a method-call callee (NODE_MEMBER) caches no type; recover the method's returns via its resolution
      const Node *const cn = ast_at_const(a, calleeId);
      if (cn->kind == NODE_MEMBER) {
        const DefId md = ast_resolution_def(a, cn->as.member.member);
        if (md.node != NODE_NONE && md.module == a->module && ast_at_const(a, md.node)->kind == NODE_FUNCTION) {
          returns = ast_at_const(a, md.node)->as.function.returns;
          ok = true;
        }
      }
    }
  }
  if (!ok) {
    typechecker_errorf(
        t, n->span.start, n->span.end - n->span.start, "a tuple binding requires a multi-value function call");
    return;
  }
  if (names.len != returns.len) {
    typechecker_errorf(
        t, n->span.start, n->span.end - n->span.start, "expected %u binding%s, the call returns %u value%s",
        names.len, names.len == 1 ? "" : "s", returns.len, returns.len == 1 ? "" : "s");
  }
  const NodeId *const rids = ast_list(a, returns);
  for (uint32_t i = 0; i < names.len; i++) {
    TypeId et = TYPE_NONE;
    if (i < returns.len) {
      const Node *const rn = ast_at_const(a, rids[i]);
      et = resolve_type(t, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : rids[i]);
    }
    ast_set_type(a, nids[i], et); // each element identifier carries its field's type
  }
}

static void check_return(TypeChecker *t, const Node *const n, const NodeId id) {
  const NodeList values = n->as.return_stmt.values;
  const NodeId *const vids = ast_list(t->ast, values);
  for (uint32_t i = 0; i < values.len; i++)
    check_expr(t, vids[i]);
  const NodeList rets = t->current_returns;
  const bool returns_void = return_list_is_explicit_void(t, rets);
  const uint32_t expected = returns_void ? 0 : rets.len;
  if (values.len != expected) {
    const Span sp = ast_at_const(t->ast, id)->span;
    typechecker_errorf(
        t, sp.start, sp.end - sp.start, "expected %u return value%s, found %u", expected, expected == 1 ? "" : "s",
        values.len);
    return;
  }
  if (returns_void)
    return;
  const NodeId *const rids = ast_list(t->ast, rets);
  for (uint32_t i = 0; i < values.len; i++) {
    const Node *const rn = ast_at_const(t->ast, rids[i]);
    const TypeId rt = resolve_type(t, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : rids[i]);
    if (!compatible(t, rt, vids[i]))
      err_mismatch(t, vids[i], rt);
  }
}

static void check_stmt(TypeChecker *t, const NodeId id) {
  if (id == NODE_NONE)
    return;
  Ast *const a = t->ast;
  const Node *const n = ast_at_const(a, id);
  switch (n->kind) {
    case NODE_BLOCK: {
      const NodeList stmts = n->as.block.statements;
      const NodeId *const ids = ast_list(a, stmts);
      for (uint32_t i = 0; i < stmts.len; i++)
        check_stmt(t, ids[i]);
      break;
    }
    case NODE_LET: {
      if (ast_at_const(a, n->as.let_stmt.name)->kind == NODE_PATTERN_TUPLE) {
        check_tuple_let(t, n);
        break;
      }
      const bool annotated = n->as.let_stmt.type != NODE_NONE;
      const bool valued = n->as.let_stmt.value != NODE_NONE;
      const TypeId declared = annotated ? resolve_type(t, n->as.let_stmt.type) : TYPE_NONE;
      if (valued)
        check_expr(t, n->as.let_stmt.value);
      TypeId binding;
      if (annotated) {
        if (valued && !compatible(t, declared, n->as.let_stmt.value))
          err_mismatch(t, n->as.let_stmt.value, declared);
        binding = declared;
      } else if (valued) {
        binding = ast_type(a, n->as.let_stmt.value);
      } else {
        const Span sp = name_span(t, n->as.let_stmt.name);
        typechecker_errorf(
            t, sp.start, sp.end - sp.start, "cannot infer type of '%.*s'", (int)(sp.end - sp.start),
            t->source + sp.start);
        binding = TYPE_NONE;
      }
      ast_set_type(a, id, binding); // referenced via decl_type's cached read
      break;
    }
    case NODE_CONST: {
      const TypeId declared = resolve_type(t, n->as.const_def.type);
      if (n->as.const_def.value != NODE_NONE) {
        check_expr(t, n->as.const_def.value);
        if (!compatible(t, declared, n->as.const_def.value))
          err_mismatch(t, n->as.const_def.value, declared);
      }
      ast_set_type(a, id, declared);
      break;
    }
    case NODE_RETURN:
      check_return(t, n, id);
      break;
    case NODE_DEFER:
      check_expr(t, n->as.single.value);
      break;
    case NODE_IF:
      check_if(t, n);
      break;
    case NODE_WHILE: {
      const TypeId c = check_expr(t, n->as.while_stmt.condition);
      if (c != TYPE_NONE && !is_bool(t, c)) {
        const Span sp = ast_at_const(a, n->as.while_stmt.condition)->span;
        char ty[96];
        render_type(t, c, ty, sizeof ty);
        typechecker_errorf(t, sp.start, sp.end - sp.start, "while condition must be 'bool', found '%s'", ty);
      }
      check_stmt(t, n->as.while_stmt.body);
      break;
    }
    case NODE_FOR: {
      const NodeId iter = n->as.for_stmt.iterable;
      const TypeId it = check_expr(t, iter);
      TypeId elem;
      if (ast_at_const(a, iter)->kind == NODE_RANGE) {
        elem = it; // a range's value type is exactly the loop-variable type
      } else {
        const Ty *const ity = ast_type_at(a, it);
        elem = ity->kind == TYPE_ARRAY || ity->kind == TYPE_SLICE ? ity->as.elem : TYPE_NONE;
      }
      ast_set_type(a, id, elem); // the loop binding resolves to this for-node (see resolver)
      check_stmt(t, n->as.for_stmt.body);
      break;
    }
    case NODE_EXPRESSION_STATEMENT:
      check_expr(t, n->as.single.value);
      break;
    default: // NODE_BREAK, NODE_CONTINUE
      break;
  }
}

static void check_pattern(TypeChecker *t, const NodeId id, const TypeId expected) {
  if (id == NODE_NONE)
    return;
  Ast *const a = t->ast;
  const Node *const n = ast_at_const(a, id);
  switch (n->kind) {
    case NODE_IDENTIFIER: // shorthand struct-field binding
      ast_set_type(a, id, expected);
      break;
    case NODE_PATTERN_NAME: {
      // A bare name matching a *unit* variant of the scrutinee enum is a tag pattern, not a
      // binding (so `switch e { A => .., B => .. }` tests the tag instead of always matching).
      ModuleId bmod;
      NodeId decl;
      DefId gp[4];
      TypeId ga[4];
      int gn;
      if (aggregate_of(t, strip(t, expected), &bmod, &decl, gp, ga, &gn) &&
          ast_at_const(mod_ast(t, bmod), decl)->kind == NODE_ENUM) {
        const NodeId v = find_member(t, bmod, decl, name_span(t, n->as.pattern.name));
        if (v != NODE_NONE && ast_at_const(mod_ast(t, bmod), v)->kind == NODE_VARIANT &&
            ast_at_const(mod_ast(t, bmod), v)->as.variant.payload.len == 0) {
          ast_set_resolution_def(a, n->as.pattern.name, (DefId){bmod, v});
          break;
        }
      }
      ast_set_type(a, id, expected); // plain binding
      break;
    }
    case NODE_PATTERN_STRUCT: {
      const TypeId base = strip(t, expected);
      ModuleId bmod;
      NodeId decl;
      DefId gp[4];
      TypeId ga[4];
      int gn;
      const bool agg = aggregate_of(t, base, &bmod, &decl, gp, ga, &gn);
      // `Variant { f, .. }` matching a struct-payload enum variant: bind fields from the variant's payload.
      NodeId variant = NODE_NONE;
      if (agg && n->as.pattern.name != NODE_NONE && ast_at_const(mod_ast(t, bmod), decl)->kind == NODE_ENUM) {
        const NodeId v = find_member(t, bmod, decl, name_span(t, n->as.pattern.name));
        if (v != NODE_NONE && ast_at_const(mod_ast(t, bmod), v)->kind == NODE_VARIANT) {
          variant = v;
          ast_set_resolution_def(a, n->as.pattern.name, (DefId){bmod, variant});
        }
      }
      const NodeList children = n->as.pattern.children;
      const NodeId *const ids = ast_list(a, children);
      if (variant != NODE_NONE) {
        Ast *const va = mod_ast(t, bmod);
        const NodeList vpl = ast_at_const(va, variant)->as.variant.payload;
        const NodeId *const vplids = ast_list(va, vpl);
        for (uint32_t i = 0; i < children.len; i++) {
          const Node *const fld = ast_at_const(a, ids[i]); // NODE_PATTERN_FIELD
          const Span fn = name_span(t, fld->as.pattern.name);
          TypeId ft = TYPE_NONE;
          NodeId match = NODE_NONE;
          for (uint32_t j = 0; j < vpl.len; j++) {
            const Node *const pf = ast_at_const(va, vplids[j]);
            if (pf->kind == NODE_FIELD &&
                spans_eq2(t->source, fn, mod_src(t, bmod), ast_at_const(va, pf->as.field.name)->as.name.text)) {
              match = vplids[j];
              ft = subst_type(t, lower_type_in(t, bmod, pf->as.field.type), gp, ga, gn);
              break;
            }
          }
          if (match != NODE_NONE)
            ast_set_resolution_def(a, fld->as.pattern.name, (DefId){bmod, match});
          else {
            char ty[96];
            render_type(t, base, ty, sizeof ty);
            typechecker_errorf(
                t, fn.start, fn.end - fn.start, "no field '%.*s' on '%s'", (int)(fn.end - fn.start), t->source + fn.start,
                ty);
          }
          const NodeList fc = fld->as.pattern.children;
          const NodeId *const fcids = ast_list(a, fc);
          for (uint32_t k = 0; k < fc.len; k++)
            check_pattern(t, fcids[k], ft);
        }
      } else {
        if (agg && n->as.pattern.name != NODE_NONE)
          ast_set_resolution_def(a, n->as.pattern.name, (DefId){bmod, decl});
        for (uint32_t i = 0; i < children.len; i++)
          check_pattern(t, ids[i], base); // children are NODE_PATTERN_FIELD; pass the aggregate type
      }
      break;
    }
    case NODE_PATTERN_FIELD: {
      const TypeId base = strip(t, expected);
      ModuleId bmod;
      NodeId decl;
      DefId gp[4];
      TypeId ga[4];
      int gn;
      const bool agg = aggregate_of(t, base, &bmod, &decl, gp, ga, &gn);
      TypeId field_type = TYPE_NONE;
      if (agg && n->as.pattern.name != NODE_NONE) {
        const Span fname = name_span(t, n->as.pattern.name);
        const NodeId field = find_member(t, bmod, decl, fname);
        if (field != NODE_NONE) {
          ast_set_resolution_def(a, n->as.pattern.name, (DefId){bmod, field});
          field_type = subst_type(t, decl_type_in(t, bmod, field), gp, ga, gn);
        } else {
          char ty[96];
          render_type(t, base, ty, sizeof ty);
          typechecker_errorf(
              t, fname.start, fname.end - fname.start, "no field '%.*s' on '%s'", (int)(fname.end - fname.start),
              t->source + fname.start, ty);
        }
      }
      const NodeList children = n->as.pattern.children;
      const NodeId *const ids = ast_list(a, children);
      for (uint32_t i = 0; i < children.len; i++)
        check_pattern(t, ids[i], field_type);
      break;
    }
    case NODE_PATTERN_TUPLE: { // enum-variant constructor pattern (named), or a parenthesized pattern (unnamed)
      const TypeId base = strip(t, expected);
      ModuleId bmod = a->module; // safe default; aggregate_of only writes it on success (else the read below is garbage)
      NodeId decl0;
      DefId gp[4];
      TypeId ga[4];
      int gn;
      const bool agg = aggregate_of(t, base, &bmod, &decl0, gp, ga, &gn) &&
                       ast_at_const(mod_ast(t, bmod), decl0)->kind == NODE_ENUM;
      const NodeId decl = agg ? decl0 : NODE_NONE;
      NodeId variant = NODE_NONE;
      if (n->as.pattern.name != NODE_NONE) {
        const Span vname = name_span(t, n->as.pattern.name);
        if (decl == NODE_NONE) { // a variant constructor pattern against a non-enum value (was a BUS crash)
          char ty[96];
          render_type(t, base, ty, sizeof ty);
          typechecker_errorf(
              t, vname.start, vname.end - vname.start, "pattern '%.*s(..)' expects an enum, but the value has type '%s'",
              (int)(vname.end - vname.start), t->source + vname.start, ty);
        } else if ((variant = find_member(t, bmod, decl, vname)) != NODE_NONE) {
          ast_set_resolution_def(a, n->as.pattern.name, (DefId){bmod, variant});
        } else {
          char ty[96];
          render_type(t, base, ty, sizeof ty);
          typechecker_errorf(
              t, vname.start, vname.end - vname.start, "no variant '%.*s' on '%s'", (int)(vname.end - vname.start),
              t->source + vname.start, ty);
        }
      }
      const NodeList children = n->as.pattern.children;
      const NodeId *const ids = ast_list(a, children);
      NodeList payload = (NodeList){0, 0};
      Ast *va = a;
      const NodeId *pl = NULL;
      if (variant != NODE_NONE) { // only read the variant's payload when we actually resolved one
        va = mod_ast(t, bmod);
        payload = ast_at_const(va, variant)->as.variant.payload;
        pl = ast_list(va, payload);
      }
      for (uint32_t i = 0; i < children.len; i++) {
        TypeId pt = TYPE_NONE;
        if (i < payload.len) {
          const Node *const pe = ast_at_const(va, pl[i]);
          pt = subst_type(t, lower_type_in(t, bmod, pe->kind == NODE_FIELD ? pe->as.field.type : pl[i]), gp, ga, gn);
        }
        check_pattern(t, ids[i], pt);
      }
      break;
    }
    default: // NODE_PATTERN_WILDCARD, NODE_PATTERN_LITERAL, NODE_PATTERN_RANGE
      break;
  }
}

static void check_associated(TypeChecker *t, const NodeList items);

static void check_item(TypeChecker *t, const NodeId id) {
  const Node *const n = ast_at_const(t->ast, id);
  switch (n->kind) {
    case NODE_FUNCTION: {
      const NodeList params = n->as.function.params;
      const NodeId *const pids = ast_list(t->ast, params);
      for (uint32_t i = 0; i < params.len; i++)
        decl_type(t, pids[i]); // type each parameter so references resolve
      // The program entry point must be `fn main() i32` -- it lowers to C's `int main(void)`, so any
      // other return type or a parameter list would be silently dropped or miscompiled.
      if (span_is(t->source, name_span(t, n->as.function.name), "main")) {
        const NodeList rets = n->as.function.returns;
        TypeId rt = TYPE_NONE;
        if (rets.len == 1) {
          const NodeId r0 = ast_list(t->ast, rets)[0];
          const Node *const rn = ast_at_const(t->ast, r0);
          rt = resolve_type(t, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : r0);
        }
        if (params.len != 0 || rets.len != 1 || rt != ast_builtin(BT_I32)) {
          const Span sp = name_span(t, n->as.function.name);
          typechecker_errorf(t, sp.start, sp.end - sp.start, "'main' must be declared 'fn main() i32'");
        }
      }
      const NodeList saved = t->current_returns;
      const NodeId savedfn = t->current_fn;
      t->current_returns = n->as.function.returns;
      t->current_fn = id;
      if (n->as.function.body != NODE_NONE)
        check_stmt(t, n->as.function.body);
      t->current_returns = saved;
      t->current_fn = savedfn;
      break;
    }
    case NODE_STRUCT:
    case NODE_ENUM: {
      const NodeList members = n->as.aggregate.members;
      const NodeId *const ids = ast_list(t->ast, members);
      for (uint32_t i = 0; i < members.len; i++) {
        const Node *const m = ast_at_const(t->ast, ids[i]);
        if (m->kind == NODE_FIELD) {
          resolve_type(t, m->as.field.type);
        } else { // NODE_VARIANT
          if (m->as.variant.value != NODE_NONE) { // explicit discriminant must be an integer
            const TypeId vt = check_expr(t, m->as.variant.value);
            if (vt != TYPE_NONE && !is_int(t, vt)) {
              const Span sp = ast_at_const(t->ast, m->as.variant.value)->span;
              typechecker_errorf(t, sp.start, sp.end - sp.start, "enum discriminant must be an integer");
            }
          }
          const NodeList payload = m->as.variant.payload;
          const NodeId *const pl = ast_list(t->ast, payload);
          for (uint32_t j = 0; j < payload.len; j++) {
            const Node *const pe = ast_at_const(t->ast, pl[j]);
            resolve_type(t, pe->kind == NODE_FIELD ? pe->as.field.type : pl[j]);
          }
        }
      }
      break;
    }
    case NODE_TRAIT:
      check_associated(t, n->as.trait_def.items);
      break;
    case NODE_IMPL: {
      // Inside `extend S { ... }`, S's private fields are reachable (current_self == S).
      const NodeId saved = t->current_self;
      t->current_self = ast_resolution(t->ast, n->as.impl_def.target_type);
      if (n->as.impl_def.trait_type != NODE_NONE)
        check_impl_conformance(t, n);
      check_associated(t, n->as.impl_def.items);
      t->current_self = saved;
      break;
    }
    case NODE_CONST: {
      const TypeId declared = resolve_type(t, n->as.const_def.type);
      if (n->as.const_def.value != NODE_NONE) {
        check_expr(t, n->as.const_def.value);
        if (!compatible(t, declared, n->as.const_def.value))
          err_mismatch(t, n->as.const_def.value, declared);
      }
      break;
    }
    case NODE_TYPE_ALIAS:
      resolve_type(t, n->as.type_alias.type);
      break;
    case NODE_EXTERN_BLOCK:
      check_associated(t, n->as.extern_block.items);
      break;
    default:
      break;
  }
}

static void check_associated(TypeChecker *t, const NodeList items) {
  const NodeId *const ids = ast_list(t->ast, items);
  for (uint32_t i = 0; i < items.len; i++)
    check_item(t, ids[i]);
}

// Transitive instance closure. The owner always emits every NON-generic method of a concrete instance,
// and those methods' signatures may name OTHER generic instances (`Vector<i32>::pop -> Option<i32>`,
// `Result<i32,E>::get_ok -> Option<i32>`). Intern those concrete instances here so propagation emits
// them even when the program never names them directly. Generic methods are emitted on demand, so they
// are skipped. The growing loop is the fixpoint -- a freshly interned instance is itself closed in turn.
static void close_instances(TypeChecker *t) {
  for (size_t ii = 0; ii < t->ast->instances.len; ii++) {
    const TyInstance it = t->ast->instances.data[ii]; // copy: subst below may grow the table
    bool concrete = true;
    for (uint8_t k = 0; k < it.n; k++)
      concrete &= ast_type_concrete(t->ast, it.args[k]);
    if (!concrete)
      continue;
    Ast *const ma = mod_ast(t, it.module);
    const NodeList items = ast_at_const(ma, ma->root)->as.program.items;
    const NodeId *const iids = ast_list(ma, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const n = ast_at_const(ma, iids[i]);
      if (n->kind != NODE_IMPL || !n->as.impl_def.generics.len ||
          ast_resolution(ma, n->as.impl_def.target_type) != it.decl)
        continue;
      const NodeList gens = n->as.impl_def.generics;
      const NodeId *const gids = ast_list(ma, gens);
      DefId ip[4];
      TypeId ia[4];
      int ipn = 0;
      for (uint32_t g = 0; g < gens.len && g < it.n && ipn < 4; g++) {
        ip[ipn] = (DefId){it.module, gids[g]};
        ia[ipn] = it.args[g];
        ipn++;
      }
      const NodeList ms = n->as.impl_def.items;
      const NodeId *const mids = ast_list(ma, ms);
      for (uint32_t j = 0; j < ms.len; j++) {
        const Node *const mn = ast_at_const(ma, mids[j]);
        if (mn->kind != NODE_FUNCTION || mn->as.function.generics.len) // generic methods emit on demand
          continue;
        const NodeList ps = mn->as.function.params;
        const NodeId *const pids = ast_list(ma, ps);
        for (uint32_t p = 0; p < ps.len; p++) // intern (side effect) any concrete instance in a param type
          subst_type(t, lower_type_in(t, it.module, ast_at_const(ma, pids[p])->as.parameter.type), ip, ia, ipn);
        const NodeList rs = mn->as.function.returns;
        if (rs.len == 1) {
          const NodeId r0 = ast_list(ma, rs)[0];
          const Node *const rn = ast_at_const(ma, r0);
          subst_type(t, lower_type_in(t, it.module, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : r0), ip, ia, ipn);
        }
      }
    }
  }
}

void typechecker_check(TypeChecker *t) {
  ast_init_types(t->ast);
  const NodeList items = ast_at_const(t->ast, t->ast->root)->as.program.items;
  const NodeId *const ids = ast_list(t->ast, items);
  for (uint32_t i = 0; i < items.len; i++)
    check_item(t, ids[i]);
  close_instances(t);
  errors_finalize(&t->errors, &t->errors_start, &t->errors_len, t->source, t->len);
}

ERRORS_BODY(TypeChecker, typechecker, t)
