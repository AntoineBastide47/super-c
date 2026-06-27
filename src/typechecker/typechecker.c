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
    NodeId current_impl;      // the enclosing NODE_IMPL, so a bare `Self` lowers to its full target type
                              // (`Wrap<T>`), not the bare struct -- otherwise generic field access loses the args
    NodeId current_fn;        // the function decl being checked, for `where`-clause bound lookup (NODE_NONE if none)
    const Package *package;   // to follow imported decls into their origin module (NULL = no imports)
    unsigned alias_depth;     // type-alias expansion depth, bounded so a cyclic alias diagnoses instead of recursing forever
    TypeId expected;          // target type of the expression being checked (let annotation / return / assignment RHS), or TYPE_NONE; consumed once by check_expr
    NodeId moved[256];        // Free-typed bindings moved out of the current function; using one again is an error
    uint32_t nmoved;          // (reset per function; best-effort linear move/use-after-move analysis)
    NodeId uninit[64];        // deferred-init bindings (`let mut x: T;`) not yet assigned on the current path
    uint32_t nuninit;         // (definite-initialization: reading one is an error; assigning it clears it)
    NodeId freed[64];         // bindings consumed by an explicit `.free()` -- using one is a use-after-free
    uint32_t nfreed;          // (vs an ordinary move; flavors the diagnostic, the `moved` set gates it)
    bool addr_ctx;            // the expression being checked is a place under address-of (&/&mut): its base is
                              // borrowed, not value-read, so the definite-init read check is suppressed for it
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
    "u16",  "u32",  "u64", "usize", "f32", "f64", "c32", "c64", "va_list", "void",
};

static TypeId check_expr(TypeChecker *t, NodeId id);
static void check_stmt(TypeChecker *t, NodeId id);
static TypeId resolve_type(TypeChecker *t, NodeId id);
static TypeId decl_type(TypeChecker *t, NodeId decl);
static TypeId decl_type_in(TypeChecker *t, ModuleId m, NodeId decl);
static TypeId named_type_of(TypeChecker *t, ModuleId m, NodeId decl);
static TypeId lower_type_in(TypeChecker *t, ModuleId m, NodeId id);
static TypeId subst_type(TypeChecker *t, TypeId ty, const DefId *params, const TypeId *args, int n);

// Fill trailing generic args from their declared `= <default>` (e.g. the `A=Global` of `Box<T, A=Global>`).
// `dmod`/`dn` is the generic aggregate; `ta`/`*tn` already holds the explicitly-supplied args. Each missing
// param's default is lowered in the owner module and substituted for any earlier params it names (`<T, U=T>`).
static void apply_default_args(TypeChecker *t, const ModuleId dmod, const Node *const dn, TypeId *const ta,
                               uint8_t *const tn) {
  const NodeList gens = dn->as.aggregate.generics;
  if (*tn >= gens.len)
    return;
  Ast *const da = mod_ast(t, dmod);
  const NodeId *const gids = ast_list(da, gens);
  for (uint32_t i = *tn; i < gens.len && *tn < 4; i++) {
    const NodeId dft = ast_at_const(da, gids[i])->as.generic_param.default_type;
    if (dft == NODE_NONE)
      break; // defaults must be trailing; a gap means the application is under-applied (caught by arity check)
    TypeId d = lower_type_in(t, dmod, dft);
    if (*tn > 0) {
      DefId params[4];
      for (uint8_t j = 0; j < *tn; j++)
        params[j] = (DefId){.module = dmod, .node = gids[j]};
      d = subst_type(t, d, params, ta, *tn);
    }
    ta[(*tn)++] = d;
  }
}

// Whether aggregate `dn` (in module `dmod`) can complete an application that supplied `from` explicit args
// from defaults -- i.e. the param at index `from` declares a `= <default>`. Lets a bare all-defaulted name
// (`String` where `String<A = Global>`) resolve to its defaulted instance (`String<Global>`).
static bool agg_has_default_at(TypeChecker *t, const ModuleId dmod, const Node *const dn, const uint32_t from) {
  const NodeList gens = dn->as.aggregate.generics;
  if (from >= gens.len)
    return false;
  const NodeId gid = ast_list(mod_ast(t, dmod), gens)[from];
  return ast_at_const(mod_ast(t, dmod), gid)->as.generic_param.default_type != NODE_NONE;
}

// `str` is no longer a builtin -- a string literal's type is the std prelude's `str` struct.
static TypeId prelude_str_type(TypeChecker *t) {
  if (!t->package)
    return TYPE_ERROR;
  ModuleId mid;
  const NodeId d = package_prelude_lookup(t->package, "str", 3, true, &mid);
  return d != NODE_NONE ? named_type_of(t, mid, d) : TYPE_ERROR;
}
static TypeId lower_type_in(TypeChecker *t, ModuleId m, NodeId id);
static TypeId prelude_slice_type(TypeChecker *t, TypeId elem, bool mut);
static int slice_kind(TypeChecker *t, TypeId tid, TypeId *elem);
static bool is_assignable(TypeChecker *t, NodeId node);
static bool is_place(TypeChecker *t, NodeId node);
// bind_ref: 0 = value (owned/move) bindings; 1 = `&T` bindings (matching `&Self`); 2 = `&mut T` bindings.
static void check_pattern(TypeChecker *t, NodeId id, TypeId expected, int bind_ref);
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

ALWAYS_INLINE bool bt_is_complex(const BuiltinType b) {
  return b == BT_C32 || b == BT_C64;
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
  return y->kind == TYPE_BUILTIN &&
         (bt_is_int(y->as.builtin) || bt_is_float(y->as.builtin) || bt_is_complex(y->as.builtin));
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

// A reference type `&elem` / `&mut elem` (for switch ref-binding-mode payloads). A non-mut reference uses
// TYPE_QUAL_NONE, matching how `&x` / a `&T` annotation are interned (so the two unify).
static TypeId tc_ref(TypeChecker *t, const TypeId elem, const bool mut) {
  return ast_intern_type(
      t->ast, (Ty){.kind = TYPE_REFERENCE, .qualifier = mut ? TYPE_QUAL_MUT : TYPE_QUAL_NONE, .as.elem = elem});
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
    case TYPE_OPAQUE: {
      Ast *const a = mod_ast(t, ty->module);
      const Span s = ast_at_const(a, ast_at_const(a, ty->as.decl)->as.type_alias.name)->as.name.text;
      snprintf(buf, cap, "%.*s", (int)(s.end - s.start), (const char *)mod_src(t, ty->module) + s.start);
      break;
    }
    case TYPE_INSTANCE: { // a generic application, e.g. `Slice<i32>` (what `[]i32` lowers to) or `Box<bool>`
      const TyInstance *const it = ast_instance(t->ast, ty->as.inst);
      Ast *const a = mod_ast(t, it->module);
      const Span s = ast_at_const(a, ast_at_const(a, it->decl)->as.aggregate.name)->as.name.text;
      size_t at = snprintf(buf, cap, "%.*s<", (int)(s.end - s.start), (const char *)mod_src(t, it->module) + s.start);
      for (uint8_t i = 0; i < it->n && at < cap; i++) {
        char arg[64];
        render_type(t, it->args[i], arg, sizeof arg);
        at += snprintf(buf + at, cap > at ? cap - at : 0, "%s%s", i ? ", " : "", arg);
      }
      if (at < cap)
        snprintf(buf + at, cap - at, ">");
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
// Takes a TypeId (not a `const Ty *`): lowering the signature interns types, which may realloc the type
// pool and dangle any `Ty *` the caller still holds. Re-fetching `fty` here from the id keeps fn_sig and
// its callers safe across that realloc.
static int fn_sig(TypeChecker *t, const TypeId fid, TypeId *const params, const int cap, TypeId *const ret) {
  const Ty *const fty = ast_type_at(t->ast, fid);
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
static bool fn_compatible(TypeChecker *t, const TypeId exid, const TypeId acid) {
  TypeId ep[4], ap[4], er, ar;
  const int en = fn_sig(t, exid, ep, 4, &er), an = fn_sig(t, acid, ap, 4, &ar);
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
    return fn_compatible(t, expected, actual);
  // Arrays compare by element: equal elements, or fn-typed elements that match structurally (a function
  // type is keyed on its decl, so `[fn(i32)i32]` from an annotation and from `[a, b]` are distinct TypeIds).
  if (ex->kind == TYPE_ARRAY && ac->kind == TYPE_ARRAY) {
    if (ex->as.elem == ac->as.elem)
      return true;
    const TypeId eel = ex->as.elem, ael = ac->as.elem;
    const Ty *const ee = ast_type_at(t->ast, eel), *const ae = ast_type_at(t->ast, ael);
    return ee->kind == TYPE_FUNCTION && ae->kind == TYPE_FUNCTION && fn_compatible(t, eel, ael);
  }
  // An array coerces to a slice over the same element: `[T; N]` -> `[]T` (Slice<T>), or `[]mut T`
  // (SliceMut<T>) when the source is a mutable place. Recording the node's coerced type makes codegen
  // materialize the {ptr, len} fat-pointer view (length recovered from the array's declaration).
  if (ac->kind == TYPE_ARRAY) {
    TypeId selem;
    const int sk = slice_kind(t, expected, &selem);
    if (sk && selem == ac->as.elem && (sk == 1 || is_assignable(t, node))) {
      ast_set_type(t->ast, node, expected);
      return true;
    }
  }
  const Node *v = ast_at_const(t->ast, node);
  if (v->kind == NODE_UNARY && v->as.unary.op == Minus) // -literal still counts as a literal
    v = ast_at_const(t->ast, v->as.unary.operand);
  if (v->kind != NODE_LITERAL)
    return false;
  const Ty *const et = ast_type_at(t->ast, expected);
  switch (v->as.literal.token_type) {
    case IntegerLiteral: // an integer literal fits any int *or* float/complex slot (`let f: f64 = 0;`)
      return et->kind == TYPE_BUILTIN &&
             (bt_is_int(et->as.builtin) || bt_is_float(et->as.builtin) || bt_is_complex(et->as.builtin));
    case CharacterLiteral: // an ASCII char literal fits any int slot too (`contains_byte('l')`), like `b'l'`
      return et->kind == TYPE_BUILTIN && bt_is_int(et->as.builtin);
    case FloatLiteral: // a float literal fits a float or complex slot (no implicit float->int truncation)
      return et->kind == TYPE_BUILTIN && (bt_is_float(et->as.builtin) || bt_is_complex(et->as.builtin));
    case StringLiteral: { // a string literal is a NUL-terminated C string: it coerces to a `*const char` /
      // `*const u8` FFI slot (e.g. printf's `fmt`), emitting the bare C literal instead of a `str` view.
      if (et->kind != TYPE_POINTER || et->qualifier != TYPE_QUAL_CONST)
        return false;
      const Ty *const pe = ast_type_at(t->ast, et->as.elem);
      if (pe->kind != TYPE_BUILTIN || (pe->as.builtin != BT_CHAR && pe->as.builtin != BT_U8))
        return false;
      ast_set_type(t->ast, node, expected); // record the coercion so codegen emits the raw pointer
      return true;
    }
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

// Like find_method, but matches a C-string method name (used by the built-in `.into()`/`.try_into()`
// conversions to reach a type's `from` / `try_from`). Searches the type's home module and the current one.
static DefId find_method_cstr(TypeChecker *t, const ModuleId m, const NodeId decl, const char *const lit) {
  const ModuleId scopes[2] = {m, t->ast->module};
  const int ns = m == t->ast->module ? 1 : 2;
  for (int s = 0; s < ns; s++) {
    const ModuleId mm = scopes[s];
    Ast *const a = mod_ast(t, mm);
    const NodeList items = ast_at_const(a, a->root)->as.program.items;
    const NodeId *const ids = ast_list(a, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const it = ast_at_const(a, ids[i]);
      if (it->kind != NODE_IMPL || it->as.impl_def.target_type == NODE_NONE)
        continue;
      const DefId tg = ast_resolution_def(a, it->as.impl_def.target_type);
      if (tg.module != m || tg.node != decl)
        continue;
      const NodeList ms = it->as.impl_def.items;
      const NodeId *const mids = ast_list(a, ms);
      for (uint32_t j = 0; j < ms.len; j++) {
        const Node *const mn = ast_at_const(a, mids[j]);
        if (mn->kind == NODE_FUNCTION && span_is(mod_src(t, mm), ast_at_const(a, mn->as.function.name)->as.name.text, lit))
          return (DefId){mm, mids[j]};
      }
    }
  }
  return (DefId){0, NODE_NONE};
}

// `x.into()` / `x.try_into()`: built-in conversions backed by the target type's `From` / `TryFrom` impl.
// Returns the `from` / `try_from` method to dispatch to (receiver passed as its value argument), or
// {_,NODE_NONE}. `want` is the expected result: `T` for into (-> `T::from`), `Result<U,E>` for try_into
// (-> `U::try_from`). The desugar rides the existing method-call machinery; codegen emits `Target::from(x)`.
static DefId resolve_conversion(TypeChecker *t, const Span name, const TypeId want) {
  const bool is_into = span_is(t->source, name, "into");
  const bool is_try = span_is(t->source, name, "try_into");
  if ((!is_into && !is_try) || want == TYPE_NONE)
    return (DefId){0, NODE_NONE};
  ModuleId m;
  NodeId decl;
  DefId gp[4];
  TypeId ga[4];
  int gn;
  if (!aggregate_of(t, strip(t, want), &m, &decl, gp, ga, &gn))
    return (DefId){0, NODE_NONE};
  if (is_try) { // Result<U, E>: convert to U via U::try_from
    if (gn < 1 || !aggregate_of(t, strip(t, ga[0]), &m, &decl, gp, ga, &gn))
      return (DefId){0, NODE_NONE};
  }
  return find_method_cstr(t, m, decl, is_try ? "try_from" : "from");
}

// A method named `name` declared by interface `trait` (module `m`) itself, or by one of its supertraits
// (`interface Ord: Eq`). Used to resolve `self.<m>()` inside an interface DEFAULT method body, where the
// receiver is the abstract `Self` and `<m>` is one of the trait family's own methods.
static DefId find_trait_method(TypeChecker *t, const ModuleId m, const NodeId trait, const Span name, const int depth) {
  if (depth > 8)
    return (DefId){0, NODE_NONE};
  Ast *const a = mod_ast(t, m);
  const Node *const tn = ast_at_const(a, trait);
  if (tn->kind != NODE_TRAIT)
    return (DefId){0, NODE_NONE};
  const NodeList items = tn->as.trait_def.items;
  const NodeId *const mids = ast_list(a, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const mn = ast_at_const(a, mids[i]);
    if (mn->kind == NODE_FUNCTION &&
        spans_eq2(t->source, name, mod_src(t, m), ast_at_const(a, mn->as.function.name)->as.name.text))
      return (DefId){m, mids[i]};
  }
  const NodeList bounds = tn->as.trait_def.bounds; // supertraits
  const NodeId *const bids = ast_list(a, bounds);
  for (uint32_t i = 0; i < bounds.len; i++) {
    const DefId sb = ast_resolution_def(a, bids[i]);
    if (sb.node != NODE_NONE) {
      const DefId r = find_trait_method(t, sb.module, sb.node, name, depth + 1);
      if (r.node != NODE_NONE)
        return r;
    }
  }
  return (DefId){0, NODE_NONE};
}

// A DEFAULT (bodied) interface method named `name` inherited by concrete type `tdecl` through one of its
// `extend tdecl as Iface` impls -- the fallback when `tdecl` provides no method of its own by that name.
// Restricted to interfaces in the CURRENT module: codegen synthesizes `tdecl__name` only for same-module
// interfaces (the default body lives in the current Ast), so resolving a cross-module default would dangle.
static DefId find_default_method(TypeChecker *t, const ModuleId tmod, const NodeId tdecl, const Span name) {
  const ModuleId scopes[2] = {tmod, t->ast->module};
  const int ns = tmod == t->ast->module ? 1 : 2;
  for (int s = 0; s < ns; s++) {
    const ModuleId m = scopes[s];
    Ast *const a = mod_ast(t, m);
    const NodeList items = ast_at_const(a, a->root)->as.program.items;
    const NodeId *const ids = ast_list(a, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const it = ast_at_const(a, ids[i]);
      if (it->kind != NODE_IMPL || it->as.impl_def.trait_type == NODE_NONE)
        continue;
      const DefId tg = ast_resolution_def(a, it->as.impl_def.target_type);
      if (tg.module != tmod || tg.node != tdecl)
        continue;
      const DefId iff = ast_resolution_def(a, it->as.impl_def.trait_type);
      if (iff.node == NODE_NONE || iff.module != t->ast->module)
        continue; // only same-module interface defaults are emittable
      const DefId mth = find_trait_method(t, iff.module, iff.node, name, 0);
      if (mth.node != NODE_NONE && ast_at_const(mod_ast(t, mth.module), mth.node)->as.function.body != NODE_NONE)
        return mth;
    }
  }
  return (DefId){0, NODE_NONE};
}

// Is generic param `gp` (in module `m`) bound by the `Free` interface (`<T: Free>`)?
static bool tc_param_has_free_bound(TypeChecker *t, const ModuleId m, const NodeId gp) {
  Ast *const a = mod_ast(t, m);
  const NodeList bs = ast_at_const(a, gp)->as.generic_param.bounds;
  const NodeId *const bids = ast_list(a, bs);
  for (uint32_t i = 0; i < bs.len; i++) {
    const DefId bd = ast_resolution_def(a, bids[i]);
    if (bd.node == NODE_NONE)
      continue;
    const Node *const bn = ast_at_const(mod_ast(t, bd.module), bd.node);
    if (bn->kind == NODE_TRAIT &&
        span_is(mod_src(t, bd.module), ast_at_const(mod_ast(t, bd.module), bn->as.trait_def.name)->as.name.text, "Free"))
      return true;
  }
  return false;
}

// Does `ty` implement the Free interface (`extend T as Free`)? Such values are move-tracked: once moved,
// a re-use is an error (and the value is not double-freed). Plain non-Free value types are not tracked,
// so ordinary value-semantics copies (`let p2 = p1` for a POD struct) stay legal. For a conditional impl
// (`extend<T: Free> Option<T> as Free`) the instance must satisfy the `Free` bounds (Option<i32> is NOT
// Free; Option<String> is) -- positional with the aggregate's type args.
static bool tc_type_is_free(TypeChecker *t, const TypeId ty) {
  ModuleId om;
  NodeId od;
  DefId gp[4];
  TypeId ga[4];
  int gn;
  if (ty == TYPE_NONE || !aggregate_of(t, strip(t, ty), &om, &od, gp, ga, &gn))
    return false;
  const ModuleId scopes[2] = {om, t->ast->module};
  const int ns = om == t->ast->module ? 1 : 2;
  for (int s = 0; s < ns; s++) {
    const ModuleId m = scopes[s];
    Ast *const a = mod_ast(t, m);
    const NodeList items = ast_at_const(a, a->root)->as.program.items;
    const NodeId *const ids = ast_list(a, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const it = ast_at_const(a, ids[i]);
      if (it->kind != NODE_IMPL || it->as.impl_def.trait_type == NODE_NONE || it->as.impl_def.target_type == NODE_NONE)
        continue;
      const DefId tg = ast_resolution_def(a, it->as.impl_def.target_type);
      if (tg.module != om || tg.node != od)
        continue;
      const DefId tr = ast_resolution_def(a, it->as.impl_def.trait_type);
      if (tr.node == NODE_NONE)
        continue;
      const Node *const trn = ast_at_const(mod_ast(t, tr.module), tr.node);
      if (trn->kind != NODE_TRAIT ||
          !span_is(mod_src(t, tr.module), ast_at_const(mod_ast(t, tr.module), trn->as.trait_def.name)->as.name.text,
                   "Free"))
        continue;
      // Every `Free`-bounded type parameter of the impl must map to a `Free` argument.
      const NodeList gens = it->as.impl_def.generics;
      const NodeId *const gids = ast_list(a, gens);
      for (uint32_t k = 0; k < gens.len && (int)k < gn; k++)
        if (tc_param_has_free_bound(t, m, gids[k]) && !tc_type_is_free(t, ga[k]))
          return false;
      return true;
    }
  }
  return false;
}

// Record `expr` as a move if it is a bare reference to a current-module Free-typed binding (a `let` or a
// by-value parameter): ownership transfers away, so a later use is flagged.
static void tc_mark_move(TypeChecker *t, const NodeId expr) {
  if (expr == NODE_NONE || ast_at_const(t->ast, expr)->kind != NODE_IDENTIFIER)
    return;
  const DefId d = ast_resolution_def(t->ast, expr);
  if (d.module != t->ast->module || d.node == NODE_NONE)
    return;
  const NodeKind dk = ast_at_const(t->ast, d.node)->kind;
  if ((dk != NODE_LET && dk != NODE_PARAMETER) || !tc_type_is_free(t, ast_type(t->ast, expr)))
    return;
  for (uint32_t i = 0; i < t->nmoved; i++)
    if (t->moved[i] == d.node)
      return; // already moved
  if (t->nmoved < (uint32_t)(sizeof t->moved / sizeof t->moved[0]))
    t->moved[t->nmoved++] = d.node;
}

// Definite-init set ops. A deferred binding starts uninitialized; an assignment to it (`x = ..`) is its
// initialization and clears it; reading it while still present is an error. Alternative branches union
// (uninit afterward iff uninit on any path), so a value initialized in only one arm stays uninit.
static bool tc_is_uninit(const TypeChecker *t, const NodeId decl) {
  for (uint32_t i = 0; i < t->nuninit; i++)
    if (t->uninit[i] == decl)
      return true;
  return false;
}
static void tc_add_uninit(TypeChecker *t, const NodeId decl) {
  if (!tc_is_uninit(t, decl) && t->nuninit < (uint32_t)(sizeof t->uninit / sizeof t->uninit[0]))
    t->uninit[t->nuninit++] = decl;
}
static void tc_init(TypeChecker *t, const NodeId decl) { // mark `decl` initialized on this path
  for (uint32_t i = 0; i < t->nuninit; i++)
    if (t->uninit[i] == decl) {
      t->uninit[i] = t->uninit[--t->nuninit]; // order is irrelevant: membership-only set
      return;
    }
}

// A captured snapshot of the flow-sensitive analysis state (moved + uninit), so alternative branches can
// each be checked from the same starting point and their results unioned. A binding moved OR left
// uninitialized on ANY path is so afterward (a later use is rejected); a sibling path's effect never
// leaks into another. `tc_flow_collect` accumulates the live state into an (initially empty) union.
typedef struct {
  NodeId moved[256];
  uint32_t nmoved;
  NodeId uninit[64];
  uint32_t nuninit;
  NodeId freed[64];
  uint32_t nfreed;
} FlowState;

static FlowState tc_flow_save(const TypeChecker *t) {
  FlowState s;
  s.nmoved = t->nmoved;
  for (uint32_t i = 0; i < t->nmoved; i++)
    s.moved[i] = t->moved[i];
  s.nuninit = t->nuninit;
  for (uint32_t i = 0; i < t->nuninit; i++)
    s.uninit[i] = t->uninit[i];
  s.nfreed = t->nfreed;
  for (uint32_t i = 0; i < t->nfreed; i++)
    s.freed[i] = t->freed[i];
  return s;
}

static void tc_flow_set(TypeChecker *t, const FlowState *s) {
  t->nmoved = s->nmoved;
  for (uint32_t i = 0; i < s->nmoved; i++)
    t->moved[i] = s->moved[i];
  t->nuninit = s->nuninit;
  for (uint32_t i = 0; i < s->nuninit; i++)
    t->uninit[i] = s->uninit[i];
  t->nfreed = s->nfreed;
  for (uint32_t i = 0; i < s->nfreed; i++)
    t->freed[i] = s->freed[i];
}

static void tc_flow_collect(FlowState *acc, const TypeChecker *t) { // union the live state into `acc`
  for (uint32_t i = 0; i < t->nmoved; i++) {
    bool seen = false;
    for (uint32_t j = 0; j < acc->nmoved; j++)
      seen |= acc->moved[j] == t->moved[i];
    if (!seen && acc->nmoved < (uint32_t)(sizeof acc->moved / sizeof acc->moved[0]))
      acc->moved[acc->nmoved++] = t->moved[i];
  }
  for (uint32_t i = 0; i < t->nuninit; i++) {
    bool seen = false;
    for (uint32_t j = 0; j < acc->nuninit; j++)
      seen |= acc->uninit[j] == t->uninit[i];
    if (!seen && acc->nuninit < (uint32_t)(sizeof acc->uninit / sizeof acc->uninit[0]))
      acc->uninit[acc->nuninit++] = t->uninit[i];
  }
  for (uint32_t i = 0; i < t->nfreed; i++) {
    bool seen = false;
    for (uint32_t j = 0; j < acc->nfreed; j++)
      seen |= acc->freed[j] == t->freed[i];
    if (!seen && acc->nfreed < (uint32_t)(sizeof acc->freed / sizeof acc->freed[0]))
      acc->freed[acc->nfreed++] = t->freed[i];
  }
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
      if (d->as.type_alias.type == NODE_NONE) // opaque `extern "C" { type X; }`: a sized, named C handle
        return ast_intern_type(t->ast, (Ty){.kind = TYPE_OPAQUE, .module = m, .as.decl = decl});
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
        if ((dn->kind == NODE_STRUCT || dn->kind == NODE_ENUM) && dn->as.aggregate.generics.len > 0 &&
            (args.len > 0 || agg_has_default_at(t, d.module, dn, args.len))) {
          const NodeId *const aids = ast_list(a, args); // a foreign generic application (Box<T>) -> an instance
          TypeId ta[4];
          uint8_t tn = 0;
          for (uint32_t i = 0; i < args.len && tn < 4; i++)
            ta[tn++] = lower_type_in(t, m, aids[i]);
          apply_default_args(t, d.module, dn, ta, &tn);
          return ast_intern_instance(t->ast, d.module, d.node, ta, tn);
        }
        return named_type_of(t, d.module, d.node);
      }
      const NodeList parts = n->as.type_path.parts;
      const int b = parts.len ? builtin_of(mod_src(t, m), ast_at_const(a, ast_list(a, parts)[0])->as.name.text) : -1;
      return b >= 0 ? ast_builtin((BuiltinType)b) : TYPE_ERROR;
    }
    case NODE_SLICE_TYPE:
      return prelude_slice_type(
          t, lower_type_in(t, m, n->as.indirect_type.type), n->as.indirect_type.qualifier == TYPE_QUAL_MUT);
    case NODE_POINTER_TYPE:
    case NODE_REFERENCE_TYPE: {
      const TypeKind k = n->kind == NODE_POINTER_TYPE ? TYPE_POINTER : TYPE_REFERENCE;
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

// `[]T` / `[]mut T` are sugar for the prelude's `Slice<T>` / `SliceMut<T>` fat-pointer structs, so a
// slice rides the whole generic-struct path (fields `.ptr`/`.len`, methods, monomorphization) for free.
static TypeId prelude_slice_type(TypeChecker *t, const TypeId elem, const bool mut) {
  if (!t->package)
    return TYPE_ERROR;
  ModuleId mid;
  const NodeId d = mut ? package_prelude_lookup(t->package, "SliceMut", 8, true, &mid)
                       : package_prelude_lookup(t->package, "Slice", 5, true, &mid);
  return d != NODE_NONE ? ast_intern_instance(t->ast, mid, d, &elem, 1) : TYPE_ERROR;
}

// `Range<E>`: the prelude type a `lo..hi` range value lowers to (the for/switch/index uses of `..` are
// handled structurally and never reach this).
static TypeId prelude_range_type(TypeChecker *t, const TypeId elem) {
  if (!t->package)
    return TYPE_ERROR;
  ModuleId mid;
  const NodeId d = package_prelude_lookup(t->package, "Range", 5, true, &mid);
  return d != NODE_NONE ? ast_intern_instance(t->ast, mid, d, &elem, 1) : TYPE_ERROR;
}

// E if `tid` is a prelude `Range<E>` instance, else TYPE_NONE (lets `for x in r` bind x to E).
static TypeId range_instance_elem(TypeChecker *t, const TypeId tid) {
  if (!t->package)
    return TYPE_NONE;
  const Ty *const ty = ast_type_at(t->ast, tid);
  if (ty->kind != TYPE_INSTANCE)
    return TYPE_NONE;
  const TyInstance *const it = ast_instance(t->ast, ty->as.inst);
  ModuleId rmid;
  const NodeId rd = package_prelude_lookup(t->package, "Range", 5, true, &rmid);
  return it->n == 1 && it->module == rmid && it->decl == rd ? it->args[0] : TYPE_NONE;
}

// If `tid` is the prelude enum `name` (e.g. "Option"/"Result"), copy its type args into `out` (up to
// `maxn`) and return the arg count; else -1. Used by the `?` operator to read Option<T> / Result<T,E>.
static int prelude_instance_args(TypeChecker *t, const TypeId tid, const char *const name, const size_t nl,
                                 TypeId *const out, const int maxn) {
  if (!t->package || tid == TYPE_NONE)
    return -1;
  const Ty *const ty = ast_type_at(t->ast, tid);
  if (ty->kind != TYPE_INSTANCE)
    return -1;
  const TyInstance *const it = ast_instance(t->ast, ty->as.inst);
  ModuleId mid;
  const NodeId d = package_prelude_lookup(t->package, name, nl, true, &mid);
  if (d == NODE_NONE || it->module != mid || it->decl != d)
    return -1;
  for (int i = 0; i < it->n && i < maxn; i++)
    out[i] = it->args[i];
  return it->n;
}

// Identify a prelude slice instance -- the lowered form of `[]E` / `[]mut E`. Returns 0 (not a slice),
// 1 (`Slice<E>`, read-only) or 2 (`SliceMut<E>`, writable); sets `*elem` to E for either slice kind.
static int slice_kind(TypeChecker *t, const TypeId tid, TypeId *const elem) {
  if (!t->package)
    return 0;
  const Ty *const ty = ast_type_at(t->ast, tid);
  if (ty->kind != TYPE_INSTANCE)
    return 0;
  const TyInstance *const it = ast_instance(t->ast, ty->as.inst);
  if (it->n != 1)
    return 0;
  ModuleId smid, mmid;
  const NodeId sd = package_prelude_lookup(t->package, "Slice", 5, true, &smid);
  const NodeId md = package_prelude_lookup(t->package, "SliceMut", 8, true, &mmid);
  const int kind = (it->module == smid && it->decl == sd) ? 1 : (it->module == mmid && it->decl == md) ? 2 : 0;
  if (kind && elem)
    *elem = it->args[0];
  return kind;
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
        // A bare `Self` (or the bare target name) inside `extend .. Target<T> { }` means the FULL target
        // type `Target<T>`, not the argless struct -- so member access carries the impl's generics and
        // a `T` field unifies with a `T` return. Lower it to the impl's target_type (an instance).
        if (generic_agg && args.len == 0 && t->current_impl != NODE_NONE && d.module == a->module &&
            d.node == t->current_self) {
          const NodeId target = ast_at_const(a, t->current_impl)->as.impl_def.target_type;
          if (target != id) // guard against self-reference (target is `Target<T>`, a different node)
            result = resolve_type(t, target);
          else
            result = named_type_of(t, d.module, d.node);
        } else if (generic_agg && (args.len > 0 || agg_has_default_at(t, d.module, dn, args.len))) {
          // `Vec<i32>` -> an interned instance; a bare all-defaulted name (`String`) -> `String<Global>`.
          TypeId ta[4];
          uint8_t tn = 0;
          for (uint32_t i = 0; i < args.len && tn < 4; i++)
            ta[tn++] = resolve_type(t, arg_ids[i]);
          apply_default_args(t, d.module, dn, ta, &tn);
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
    case NODE_SLICE_TYPE: // `[]T` / `[]mut T` -> the prelude's Slice<T> / SliceMut<T> instance
      result = prelude_slice_type(
          t, resolve_type(t, n->as.indirect_type.type), n->as.indirect_type.qualifier == TYPE_QUAL_MUT);
      break;
    case NODE_POINTER_TYPE:
    case NODE_REFERENCE_TYPE: {
      const TypeKind k = n->kind == NODE_POINTER_TYPE ? TYPE_POINTER : TYPE_REFERENCE;
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
  if (n->as.unary.op == Ampersand) // `&x`/`&mut x` borrows x; its base is not value-read (definite-init)
    t->addr_ctx = true;
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
      // A `&mut` borrow of a place needs that place to be mutable -- otherwise it would hand out write
      // access to an immutable binding. (An rvalue operand is a fresh temp, so it is left to codegen.)
      if (n->as.unary.qualifier == TYPE_QUAL_MUT && is_place(t, n->as.unary.operand) &&
          !is_assignable(t, n->as.unary.operand)) {
        const Span osp = ast_at_const(t->ast, n->as.unary.operand)->span;
        typechecker_errorf(t, osp.start, osp.end - osp.start,
                           "cannot take '&mut' of an immutable binding (bind it with 'mut')");
      }
      return ast_intern_type(t->ast, (Ty){.kind = TYPE_REFERENCE, .qualifier = n->as.unary.qualifier, .as.elem = opnd});
    case Question: { // `expr?`: unwrap Option<T>/Result<T,E>, else early-return None/Err from the function
      if (opnd == TYPE_NONE)
        return TYPE_NONE;
      const TypeId os = strip(t, opnd);
      TypeId oa[2], fa[2];
      const int nopt = prelude_instance_args(t, os, "Option", 6, oa, 2);
      const int nres = nopt >= 0 ? -1 : prelude_instance_args(t, os, "Result", 6, oa, 2);
      if (nopt < 0 && nres < 0) {
        typechecker_errorf(t, sp.start, sp.end - sp.start, "'?' requires an Option or Result operand");
        return TYPE_NONE;
      }
      TypeId fnret = TYPE_NONE; // the enclosing function's single declared return type
      if (t->current_returns.len == 1) {
        const NodeId r0 = ast_list(t->ast, t->current_returns)[0];
        const Node *const rnn = ast_at_const(t->ast, r0);
        fnret = resolve_type(t, rnn->kind == NODE_PARAMETER ? rnn->as.parameter.type : r0);
      }
      const TypeId frs = fnret == TYPE_NONE ? TYPE_NONE : strip(t, fnret);
      if (nopt >= 0) {
        if (prelude_instance_args(t, frs, "Option", 6, fa, 2) < 0)
          typechecker_errorf(t, sp.start, sp.end - sp.start, "'?' on an Option requires the function to return an Option");
        return oa[0]; // the Some payload type
      }
      if (prelude_instance_args(t, frs, "Result", 6, fa, 2) < 0)
        typechecker_errorf(t, sp.start, sp.end - sp.start, "'?' on a Result requires the function to return a Result");
      else if (oa[1] != fa[1]) { // the error types must match (convert explicitly with `.into()` before `?`)
        char a1[96], a2[96];
        render_type(t, oa[1], a1, sizeof a1);
        render_type(t, fa[1], a2, sizeof a2);
        typechecker_errorf(t, sp.start, sp.end - sp.start,
                           "'?' error type '%s' does not match the function's error type '%s'", a1, a2);
      }
      return oa[0]; // the Ok payload type
    }
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

// The single return type of method `md` called on a receiver of type `recv`, with the receiver instance's
// args substituted through the method's enclosing impl generics (so `fn index(self,..) T` -> the element).
static TypeId tc_method_ret(TypeChecker *t, const TypeId recv, const DefId md) {
  Ast *const fa = mod_ast(t, md.module);
  const Node *const fn = ast_at_const(fa, md.node);
  if (fn->kind != NODE_FUNCTION || fn->as.function.returns.len != 1)
    return TYPE_NONE;
  DefId rsubp[4];
  TypeId rsuba[4];
  int nrsub = 0;
  ModuleId rmod;
  NodeId rdecl;
  DefId sp[4];
  TypeId sa[4];
  int sn = 0;
  if (aggregate_of(t, strip(t, recv), &rmod, &rdecl, sp, sa, &sn) && sn > 0) {
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
  const NodeId r0 = ast_list(fa, fn->as.function.returns)[0];
  const Node *const rn = ast_at_const(fa, r0);
  const TypeId ret = lower_type_in(t, md.module, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : r0);
  return subst_type(t, ret, rsubp, rsuba, nrsub);
}

// The method name an arithmetic operator dispatches to when an operand is a user type, or NULL.
static const char *arith_method_name(const TokenType op) {
  switch (op) {
    case Plus: return "add";
    case Minus: return "sub";
    case Star: return "mul";
    case Slash: return "div";
    case Percent: return "rem";
    default: return NULL;
  }
}

// Operator overloading for `+ - * / %`: if the left operand is a struct/instance (or a generic param bound
// to the trait), dispatch to its add/sub/mul/div/rem method; the result is that method's return type.
// Sets `*out` and returns true when handled (so the caller skips the builtin numeric path).
static bool check_arith_overload(TypeChecker *t, const Node *const n, const NodeId id, const TypeId l, TypeId *const out) {
  const char *const m = arith_method_name(n->as.binary.op);
  if (!m)
    return false;
  const TypeId ls = l == TYPE_NONE ? TYPE_NONE : strip(t, l);
  const Ty *const lt = ls == TYPE_NONE ? NULL : ast_type_at(t->ast, ls);
  if (!lt)
    return false;
  if (lt->kind == TYPE_GENERIC) { // a bound `T: Add`; verified at instantiation, codegen dispatches
    *out = ls;
    return true;
  }
  if (lt->kind != TYPE_STRUCT && lt->kind != TYPE_INSTANCE)
    return false; // builtin numeric operands fall through to binary_numeric
  ModuleId om;
  NodeId od;
  DefId gp[4];
  TypeId ga[4];
  int gn;
  *out = ls;
  if (aggregate_of(t, ls, &om, &od, gp, ga, &gn)) {
    const DefId md = find_method_cstr(t, om, od, m);
    if (md.node == NODE_NONE) {
      const Span sp = ast_at_const(t->ast, id)->span;
      char ty[96];
      render_type(t, ls, ty, sizeof ty);
      typechecker_errorf(t, sp.start, sp.end - sp.start, "'%s' has no '%s' method for this operator", ty, m);
      *out = TYPE_NONE;
    } else {
      const TypeId ret = tc_method_ret(t, ls, md);
      if (ret != TYPE_NONE)
        *out = ret;
    }
  }
  return true;
}

static TypeId check_binary(TypeChecker *t, const Node *const n, const NodeId id) {
  const NodeId ln = n->as.binary.left, rn = n->as.binary.right;
  const TypeId l = check_expr(t, ln), r = check_expr(t, rn);
  const Span sp = ast_at_const(t->ast, id)->span;
  switch (n->as.binary.op) {
    case Plus:
    case Minus: {
      TypeId ov;
      if (check_arith_overload(t, n, id, l, &ov))
        return ov;
      bool handled;
      const TypeId pt = check_ptr_arith(t, n, id, l, r, &handled);
      if (handled)
        return pt;
      return binary_numeric(t, id, l, ln, r, rn, false);
    }
    case Star:
    case Slash:
    case Percent: {
      TypeId ov;
      if (check_arith_overload(t, n, id, l, &ov))
        return ov;
      return binary_numeric(t, id, l, ln, r, rn, false);
    }
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
    default: { // comparisons (==, !=, <, <=, >, >=)
      // Operator overloading: on a struct or generic-instance operand, `==`/`!=` dispatch to its `eq`
      // (Eq) and `<`/`<=`/`>`/`>=` to its `cmp` (Ord); codegen emits the call. A struct compared with C
      // `==` would otherwise miscompile silently, so the method is required.
      const TypeId ls = l == TYPE_NONE ? TYPE_NONE : strip(t, l);
      const Ty *const lt = ls == TYPE_NONE ? NULL : ast_type_at(t->ast, ls);
      if (lt && (lt->kind == TYPE_STRUCT || lt->kind == TYPE_INSTANCE)) {
        const bool ord = n->as.binary.op == LessThan || n->as.binary.op == LessThanEqual ||
                         n->as.binary.op == GreaterThan || n->as.binary.op == GreaterThanEqual;
        ModuleId om;
        NodeId od;
        DefId gp[4];
        TypeId ga[4];
        int gn;
        if (aggregate_of(t, ls, &om, &od, gp, ga, &gn) &&
            find_method_cstr(t, om, od, ord ? "cmp" : "eq").node == NODE_NONE) {
          char ty[96];
          render_type(t, ls, ty, sizeof ty);
          typechecker_errorf(t, sp.start, sp.end - sp.start, "'%s' has no '%s' method for this operator (implement %s)",
                             ty, ord ? "cmp" : "eq", ord ? "Ord" : "Eq");
        }
        return ast_builtin(BT_BOOL);
      }
      if (lt && lt->kind == TYPE_GENERIC) // a bound `T: Eq`/`T: Ord`; verified at instantiation, codegen dispatches
        return ast_builtin(BT_BOOL);
      if (l != TYPE_NONE && r != TYPE_NONE && l != r && !compatible(t, l, rn) && !compatible(t, r, ln))
        err_mismatch(t, rn, l);
      return ast_builtin(BT_BOOL);
    }
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
      if (dn->kind == NODE_PATTERN_NAME) // `Some(mut f) =>` makes the payload binding assignable
        return ast_at_const(t->ast, dn->as.pattern.name)->as.name.is_mutable;
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
      // Indexing a writable slice (`[]mut T` -> SliceMut<T>) yields an assignable element, however the
      // slice was bound -- its mutability lives in the type, not the binding.
      if (n->kind == NODE_INDEX && slice_kind(t, ast_type(t->ast, obj), NULL) == 2)
        return true;
      const Ty *const ot = ast_type_at(t->ast, ast_type(t->ast, obj)); // auto-deref through a mutable pointer
      return (ot->kind == TYPE_POINTER || ot->kind == TYPE_REFERENCE) && ot->qualifier == TYPE_QUAL_MUT;
    }
    default:
      return false;
  }
}

// A "place" (lvalue): an expression denoting a storage location, not a fresh value. Mirrors codegen's
// is_lvalue so the mutability check and the temp-materialization agree on what is a place vs an rvalue.
static bool is_place(TypeChecker *t, const NodeId id) {
  const Node *const n = ast_at_const(t->ast, id);
  switch (n->kind) {
    case NODE_IDENTIFIER:
    case NODE_INDEX:
      return true;
    case NODE_MEMBER:
      return !n->as.member.path; // a field/element access is a place; `Enum::Variant` is not
    case NODE_UNARY:
      return n->as.unary.op == Star; // `*p` deref
    default:
      return false;
  }
}

// Can `recv` be the receiver of a `&mut self` (or `*mut self`) method -- i.e. can a mutable borrow of it
// be taken? A `&mut`/`*mut` receiver auto-derefs and is mutable; a `&`/`*const` one is not. A value
// receiver must be a *mutable place* (so the mutation is observable); an rvalue is a fresh owned temp.
static bool receiver_mutable(TypeChecker *t, const NodeId recv) {
  const TypeId rt = ast_type(t->ast, recv);
  if (rt != TYPE_NONE) {
    const Ty *const rty = ast_type_at(t->ast, rt);
    if (rty->kind == TYPE_POINTER || rty->kind == TYPE_REFERENCE)
      return rty->qualifier == TYPE_QUAL_MUT;
  }
  return is_place(t, recv) ? is_assignable(t, recv) : true;
}

// `Enum::Variant` as an expression yields the enum type; `Type::method` yields the associated function
// type (normally consumed by check_call). Handles imports: a direct `mod::Name` (recorded on this node
// by the resolver) and a nested `(mod::Type)::method`.
static TypeId check_path_member(TypeChecker *t, const Node *const n, const NodeId id, const TypeId expected) {
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
    // A bare all-defaulted generic name as a `::` base (`String::from_str`) denotes its defaulted instance
    // (`String<Global>`): record that instance as the base's type so the assoc call substitutes the impl's
    // generics and codegen mangles it as `String__Global__from_str`.
    if (bdecl != NODE_NONE) {
      const Node *const bdn = ast_at_const(mod_ast(t, bmod), bdecl);
      if ((bdn->kind == NODE_STRUCT || bdn->kind == NODE_ENUM) && bdn->as.aggregate.generics.len > 0 &&
          agg_has_default_at(t, bmod, bdn, 0)) {
        TypeId ta[4];
        uint8_t tn = 0;
        apply_default_args(t, bmod, bdn, ta, &tn);
        if (tn == bdn->as.aggregate.generics.len) {
          inst_ty = ast_intern_instance(t->ast, bmod, bdecl, ta, tn);
          ast_set_type(t->ast, obj, inst_ty);
        }
      }
    }
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
  // `T::assoc()` -- a static (no-self) interface method on a type parameter, reached through its bounds
  // (`fn make<T: Default>() T { return T::default(); }`). `Self` in the return is substituted to T in
  // check_call; codegen redirects to the concrete impl once the param is monomorphized.
  if (bd && bd->kind == NODE_GENERIC_PARAM) {
    DefId iface;
    const DefId m = find_bound_method(t, bmod, bdecl, mname, &iface);
    if (m.node != NODE_NONE) {
      ast_set_resolution_def(t->ast, n->as.member.member, m);
      return decl_type_in(t, m.module, m.node);
    }
  }
  // `Trait::assoc()` resolved by the expected type: `let p: Point = Default::default();` picks the method
  // from the expected type's `extend ExpectedType as Trait` impl. Codegen uses the call's result type to
  // emit the concrete `ExpectedType__assoc`. (Generic targets via the trait name are deferred; use the
  // explicit `Type::<Args>::assoc()` form for those.)
  if (bd && bd->kind == NODE_TRAIT && expected != TYPE_NONE) {
    ModuleId emod;
    NodeId edecl;
    DefId egp[4];
    TypeId ega[4];
    int egn;
    if (aggregate_of(t, strip(t, expected), &emod, &edecl, egp, ega, &egn)) {
      const DefId m = find_method(t, emod, edecl, mname);
      if (m.node != NODE_NONE) {
        ast_set_resolution_def(t->ast, n->as.member.member, m);
        return decl_type_in(t, m.module, m.node); // result-type subst (for a generic target) happens in check_call
      }
    }
  }
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
    const int pn = fn_sig(t, param_ty, pp, 4, &pr), an = fn_sig(t, arg_ty, ap, 4, &ar);
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
static bool fn_compatible_subst(TypeChecker *t, const TypeId exid, const TypeId acid, const DefId *const gp,
                                const TypeId *const ga, const int gn, const DefId *const rp, const TypeId *const ra,
                                const int rn) {
  TypeId ep[4], ap[4], er, ar;
  const int en = fn_sig(t, exid, ep, 4, &er), an = fn_sig(t, acid, ap, 4, &ar);
  if (en != an || en > 4)
    return false;
  if (!ret_eq(subst_type(t, subst_type(t, er, gp, ga, gn), rp, ra, rn), ar))
    return false;
  for (int i = 0; i < en; i++)
    if (subst_type(t, subst_type(t, ep[i], gp, ga, gn), rp, ra, rn) != ap[i])
      return false;
  return true;
}

// The element type of an iterable that follows the Iterator protocol: a `next(&mut self) -> Option<T>`
// method. Returns T (so `for x in it` binds x to it), or TYPE_NONE if `it` is not such an iterator.
static TypeId iter_elem_type(TypeChecker *t, const TypeId it) {
  ModuleId im;
  NodeId idl;
  DefId gp[4];
  TypeId ga[4];
  int gn;
  if (!aggregate_of(t, it, &im, &idl, gp, ga, &gn))
    return TYPE_NONE;
  const DefId nx = find_method_cstr(t, im, idl, "next");
  if (nx.node == NODE_NONE)
    return TYPE_NONE;
  Ast *const na = mod_ast(t, nx.module);
  const NodeList rets = ast_at_const(na, nx.node)->as.function.returns;
  if (rets.len != 1)
    return TYPE_NONE;
  const NodeId r0 = ast_list(na, rets)[0];
  const Node *const rn = ast_at_const(na, r0);
  TypeId ret = lower_type_in(t, nx.module, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : r0);
  // Substitute the iterator impl's own generics by the receiver instance's type args (Option<T> -> Option<i32>).
  const NodeId impl = enclosing_impl(t, nx.module, nx.node);
  if (impl != NODE_NONE && gn > 0) {
    const NodeList ig = ast_at_const(na, impl)->as.impl_def.generics;
    const NodeId *const gids = ast_list(na, ig);
    DefId ip[4];
    TypeId ia[4];
    int in2 = 0;
    for (uint32_t i = 0; i < ig.len && (int)i < gn && in2 < 4; i++) {
      ip[in2] = (DefId){nx.module, gids[i]};
      ia[in2] = ga[i];
      in2++;
    }
    ret = subst_type(t, ret, ip, ia, in2);
  }
  const Ty *const rt = ast_type_at(t->ast, ret); // expect Option<Elem>
  if (rt->kind == TYPE_INSTANCE) {
    const TyInstance *const oi = ast_instance(t->ast, rt->as.inst);
    if (oi->n >= 1)
      return oi->args[0];
  }
  return TYPE_NONE;
}

static TypeId check_call(TypeChecker *t, const Node *const n, const NodeId id, const TypeId want) {
  // `Enum::Variant(args)` is construction, not a function call.
  const Node *const path_callee = ast_at_const(t->ast, n->as.call.callee);
  TypeId callee = TYPE_NONE;
  // `x.free()` as the destructor intrinsic: when `x.free()` does NOT resolve to a real method -- an
  // UNBOUNDED generic param (`self.ptr[i]` in `extend<T> Vector<T>`), a builtin, or a struct with no `free`
  // -- it is a void NO-OP (so generic container code can free each element uniformly; codegen resolves it
  // per monomorphization). A type that DOES have a `free` (concrete or via a `T: Free` bound) falls through
  // to normal resolution, which governs the real return type, auto-ref, and the consume below.
  if (path_callee->kind == NODE_MEMBER && !path_callee->as.member.path && n->as.call.args.len == 0 &&
      span_is(mod_src(t, t->ast->module), ast_at_const(t->ast, path_callee->as.member.member)->as.name.text, "free")) {
    const TypeId rt = check_expr(t, path_callee->as.member.object);
    const Span fname = name_span(t, path_callee->as.member.member);
    bool resolvable = false;
    if (rt != TYPE_NONE) {
      const Ty *const rty = ast_type_at(t->ast, strip(t, rt));
      if (rty->kind == TYPE_STRUCT || rty->kind == TYPE_INSTANCE) {
        ModuleId om;
        NodeId od;
        DefId gp[4];
        TypeId ga[4];
        int gn;
        if (aggregate_of(t, strip(t, rt), &om, &od, gp, ga, &gn))
          resolvable = find_method_cstr(t, om, od, "free").node != NODE_NONE;
      } else if (rty->kind == TYPE_GENERIC) {
        DefId iface;
        resolvable = find_bound_method(t, rty->module, rty->as.decl, fname, &iface).node != NODE_NONE;
      }
    }
    if (!resolvable)
      return ast_builtin(BT_VOID); // no real `free` -> destructor no-op
    // else fall through: a real `free` method governs (return type, receiver auto-ref, the consume below)
  }
  if (path_callee->kind == NODE_MEMBER && path_callee->as.member.path) {
    t->expected = want; // a `Trait::assoc()` callee resolves through the call's target type
    callee = check_expr(t, n->as.call.callee);
    const DefId vd = ast_resolution_def(t->ast, path_callee->as.member.member);
    if (vd.node != NODE_NONE && ast_at_const(mod_ast(t, vd.module), vd.node)->kind == NODE_VARIANT)
      return check_variant_call(t, n, id, vd.module, vd.node, callee);
  } else if (path_callee->kind == NODE_MEMBER) {
    t->expected = want;                          // `.into()`/`.try_into()` resolve through the call's target type
    callee = check_member(t, path_callee, true); // `obj.name(args)`: resolve `name` as a method, not a field
  } else {
    callee = check_expr(t, n->as.call.callee);
  }
  const NodeList args = n->as.call.args;
  const NodeId *const aids = ast_list(t->ast, args);
  for (uint32_t i = 0; i < args.len; i++)
    check_expr(t, aids[i]);
  for (uint32_t i = 0; i < args.len; i++)
    tc_mark_move(t, aids[i]); // a by-value Free argument is moved to the callee (which owns/frees it)

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

  // A resolved `x.free()` destructor on an owned (non-reference) Free value consumes it: a later use is a
  // use-after-free, and its scope-exit auto-free is elided (no double free). A `&mut`/`*` receiver only
  // borrows a value owned elsewhere, so it is left alone.
  if (skip && callee_node->as.member.object != NODE_NONE &&
      span_is(mod_src(t, t->ast->module), ast_at_const(t->ast, callee_node->as.member.member)->as.name.text, "free")) {
    const NodeId recv = callee_node->as.member.object;
    const Ty *const rty = ast_type_at(t->ast, ast_type(t->ast, recv));
    if (rty->kind != TYPE_POINTER && rty->kind != TYPE_REFERENCE && tc_type_is_free(t, ast_type(t->ast, recv))) {
      tc_mark_move(t, recv);
      if (ast_at_const(t->ast, recv)->kind == NODE_IDENTIFIER) { // record it as freed, for the use-after-free diagnostic
        const DefId rd = ast_resolution_def(t->ast, recv);
        if (rd.module == t->ast->module && rd.node != NODE_NONE && t->nfreed < (uint32_t)(sizeof t->freed / sizeof t->freed[0]))
          t->freed[t->nfreed++] = rd.node;
      }
    }
  } else if (skip && callee_node->as.member.object != NODE_NONE) {
    // A method whose `self` is taken BY VALUE (`fn unwrap_or(self: Option<T>, ..)`) consumes its receiver:
    // the receiver moves into the call, so a later use is a use-after-move (and it is not double-freed).
    const NodeId p0 = ast_list(fa, params)[0];
    const NodeId pt = ast_at_const(fa, p0)->as.parameter.type;
    const NodeKind ptk = pt != NODE_NONE ? ast_at_const(fa, pt)->kind : NODE_NONE_KIND;
    if (ptk != NODE_POINTER_TYPE && ptk != NODE_REFERENCE_TYPE)
      tc_mark_move(t, callee_node->as.member.object);
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
  // `T::assoc()` (a static interface method on a type param): substitute the interface's `Self` by the
  // param's type, so a `Self` return resolves to T inside the generic function.
  if (callee_node->kind == NODE_MEMBER && callee_node->as.member.path && nrsub < 4) {
    const DefId md = ast_resolution_def(t->ast, callee_node->as.member.member);
    const NodeId tr = md.node != NODE_NONE ? enclosing_trait(t, md.module, md.node) : NODE_NONE;
    const DefId ob = ast_resolution_def(t->ast, callee_node->as.member.object);
    if (tr != NODE_NONE && ob.node != NODE_NONE &&
        ast_at_const(mod_ast(t, ob.module), ob.node)->kind == NODE_GENERIC_PARAM) {
      rsubp[nrsub] = (DefId){md.module, tr};
      rsuba[nrsub] = named_type_of(t, ob.module, ob.node);
      nrsub++;
    }
    // `Trait::assoc()` on a generic instance target (`let v: Vector<String> = Default::default();`): the
    // resolved method's signature uses the IMPL's type params -- bind them to the target instance's args.
    if (ob.node != NODE_NONE && md.node != NODE_NONE &&
        ast_at_const(mod_ast(t, ob.module), ob.node)->kind == NODE_TRAIT) {
      ModuleId em;
      NodeId ed;
      DefId egp[4];
      TypeId ega[4];
      int egn;
      if (want != TYPE_NONE && aggregate_of(t, strip(t, want), &em, &ed, egp, ega, &egn) && egn > 0) {
        const NodeId impl = enclosing_impl(t, md.module, md.node);
        if (impl != NODE_NONE) {
          Ast *const ma = mod_ast(t, md.module);
          const NodeList ig = ast_at_const(ma, impl)->as.impl_def.generics;
          const NodeId *const gids = ast_list(ma, ig);
          for (uint32_t i = 0; i < ig.len && (int)i < egn && nrsub < 4; i++) {
            rsubp[nrsub] = (DefId){md.module, gids[i]};
            rsuba[nrsub] = ega[i];
            nrsub++;
          }
        }
      }
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

  // A C-variadic binding (`fn printf(fmt: *u8, ...)`) takes AT LEAST its fixed params; the extra trailing
  // args are already checked as plain expressions above and passed through verbatim (C default promotions).
  const bool variadic = named && fn->as.function.is_variadic;
  const uint32_t expected = params.len - skip; // `...` adds no param node, so params.len is the fixed count
  if (variadic ? args.len < expected : args.len != expected) {
    typechecker_errorf(
        t, sp.start, sp.end - sp.start, variadic ? "expected at least %u argument%s, found %u"
                                                  : "expected %u argument%s, found %u",
        expected, expected == 1 ? "" : "s", args.len);
  } else {
    const NodeId *const pids = ast_list(fa, params);
    for (uint32_t i = 0; i < expected; i++) {
      const TypeId raw = named ? decl_type_in(t, fmod, pids[i + skip]) : lower_type_in(t, fmod, pids[i + skip]);
      const TypeId pt = subst_type(t, subst_type(t, raw, gparams, gargs, gn), rsubp, rsuba, nrsub);
      // A `fn(..) ..` parameter carries generics inside the function type that plain subst_type can't
      // rewrite; compare it structurally with the call's substitutions applied per signature position.
      const Ty *const ptt = ast_type_at(t->ast, pt);
      if (ptt->kind == TYPE_FUNCTION) {
        const TypeId at = ast_type(t->ast, aids[i]);
        const Ty *const att = at == TYPE_NONE ? NULL : ast_type_at(t->ast, at);
        if (!att || att->kind != TYPE_FUNCTION ||
            !fn_compatible_subst(t, pt, at, gparams, gargs, gn, rsubp, rsuba, nrsub))
          err_mismatch(t, aids[i], pt);
        continue;
      }
      if (!compatible(t, pt, aids[i]))
        err_mismatch(t, aids[i], pt);
    }
  }
  // A string literal in a C-vararg slot has no `str` meaning to C: default it to `*const char` so codegen
  // emits the bare NUL-terminated literal (what `%s` expects), mirroring the fixed-param coercion.
  if (variadic && args.len >= expected) {
    const TypeId cstr =
        ast_intern_type(t->ast, (Ty){.kind = TYPE_POINTER, .qualifier = TYPE_QUAL_CONST, .as.elem = ast_builtin(BT_CHAR)});
    for (uint32_t i = expected; i < args.len; i++) {
      const Node *const a = ast_at_const(t->ast, aids[i]);
      if (a->kind == NODE_LITERAL && a->as.literal.token_type == StringLiteral)
        ast_set_type(t->ast, aids[i], cstr);
    }
  }
  // A `&mut self` / `*mut self` method needs a mutable receiver: an immutable binding/place cannot be
  // mutated through it (binding mutability is `let mut` / `mut`, NOT a property of the type's internals).
  if (skip == 1 && callee_node->kind == NODE_MEMBER && params.len > 0) {
    const Ty *const selfp = ast_type_at(t->ast, decl_type_in(t, fmod, ast_list(fa, params)[0]));
    if ((selfp->kind == TYPE_REFERENCE || selfp->kind == TYPE_POINTER) && selfp->qualifier == TYPE_QUAL_MUT) {
      const NodeId recv = callee_node->as.member.object;
      if (!receiver_mutable(t, recv)) {
        const Span rsp = ast_at_const(t->ast, recv)->span;
        typechecker_errorf(
            t, rsp.start, rsp.end - rsp.start,
            "cannot call a '&mut self' method on an immutable binding (bind it with 'mut')");
      }
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
  const TypeId want = t->expected; // target type for built-in `.into()`/`.try_into()` conversions
  t->expected = TYPE_NONE;         // captured before recursing so the object expr does not inherit it
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
    // No own method/field: inherit an interface DEFAULT method (`extend T as Ord` gets Ord's `lt` body).
    if (prefer_method) {
      const DefId dm = find_default_method(t, bmod, bdecl, name);
      if (dm.node != NODE_NONE) {
        ast_set_resolution_def(t->ast, mname, dm);
        return subst_type(t, decl_type_in(t, dm.module, dm.node), gp, ga, gn);
      }
    }
  }
  // A method on a value of generic-parameter type (`w: T` with `T: Writer`): resolve it through the
  // param's interface bounds. `Self` stays abstract (TYPE_GENERIC of the trait); check_call substitutes
  // it by the receiver, and codegen dispatches to the concrete impl once the param is monomorphized.
  const Ty *const bt = ast_type_at(t->ast, base);
  if (bt->kind == TYPE_GENERIC) {
    // `self` inside an interface default body has the abstract `Self` type (a TYPE_GENERIC keyed by the
    // trait): resolve `self.m()` against the trait's own methods + supertraits. A plain generic param
    // (`w: T`, `T: Writer`) instead resolves through its interface bounds.
    const Node *const gd = ast_at_const(mod_ast(t, bt->module), bt->as.decl);
    if (gd->kind == NODE_TRAIT) {
      const DefId m = find_trait_method(t, bt->module, bt->as.decl, name, 0);
      if (m.node != NODE_NONE) {
        ast_set_resolution_def(t->ast, mname, m);
        return decl_type_in(t, m.module, m.node);
      }
    } else {
      DefId iface;
      const DefId m = find_bound_method(t, bt->module, bt->as.decl, name, &iface);
      if (m.node != NODE_NONE) {
        ast_set_resolution_def(t->ast, mname, m);
        return decl_type_in(t, m.module, m.node);
      }
    }
  }
  // Built-in conversion fallback: `x.into()` / `x.try_into()` dispatch to the target type's `from`/`try_from`.
  // Resolve to that method and return its function type so check_call binds the receiver as the value arg.
  if (prefer_method) {
    const DefId conv = resolve_conversion(t, name, want);
    if (conv.node != NODE_NONE) {
      ast_set_resolution_def(t->ast, mname, conv);
      return decl_type_in(t, conv.module, conv.node);
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
    tc_mark_move(t, fi->as.field_initializer.value); // a Free value placed in a field is moved into the struct
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
  // The two branches are alternative paths: check each from the same pre-`if` state, then union their
  // effects -- so an else use of a value the then-branch moved (or vice versa) is not a false error, while
  // a value left moved/uninitialized on either path is so afterward.
  const FlowState pre = tc_flow_save(t);
  check_stmt(t, n->as.if_stmt.then_branch);
  FlowState acc = {.nmoved = 0, .nuninit = 0};
  tc_flow_collect(&acc, t);          // then-branch effects
  tc_flow_set(t, &pre);              // else branch starts fresh from the pre-if state
  check_stmt(t, n->as.if_stmt.else_branch);
  tc_flow_collect(&acc, t);          // ∪ else-branch effects
  tc_flow_set(t, &acc);              // post-if = union of both
}

static TypeId check_expr(TypeChecker *t, const NodeId id) {
  if (id == NODE_NONE)
    return TYPE_NONE;
  Ast *const a = t->ast;
  const Node *const n = ast_at_const(a, id);
  const TypeId expected = t->expected; // target type from the enclosing context (let / return / assignment)
  t->expected = TYPE_NONE;             // consumed here; do not leak into nested subexpressions
  const bool addr_ctx = t->addr_ctx;   // whether this expr is the place being borrowed (&/&mut); one-shot
  t->addr_ctx = false;
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
      if (d.module == t->ast->module && d.node != NODE_NONE) {
        for (uint32_t i = 0; i < t->nmoved; i++) // a moved/freed Free binding is dead
          if (t->moved[i] == d.node) {
            bool freed = false; // distinguish a value freed by `.free()` from one moved elsewhere
            for (uint32_t k = 0; k < t->nfreed; k++)
              freed |= t->freed[k] == d.node;
            typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                               freed ? "use after free" : "use of moved value");
            break;
          }
        if (!addr_ctx && tc_is_uninit(t, d.node)) // definite-init: a deferred binding read before assignment
          typechecker_errorf(t, n->span.start, n->span.end - n->span.start, "use of possibly uninitialized value");
      }
      break;
    }
    case NODE_UNARY:
      result = check_unary(t, n, id);
      break;
    case NODE_BINARY:
      result = check_binary(t, n, id);
      break;
    case NODE_ASSIGNMENT: {
      // A plain `x = ..` to a deferred binding is its initialization, not a read: clear it before the LHS is
      // checked so the read-of-uninitialized check below does not fire. (Compound `x += ..` does read x.)
      if (n->as.binary.op == Equal && ast_at_const(a, n->as.binary.left)->kind == NODE_IDENTIFIER) {
        const DefId ld = ast_resolution_def(a, n->as.binary.left);
        if (ld.module == t->ast->module && ld.node != NODE_NONE)
          tc_init(t, ld.node);
      }
      const TypeId l = check_expr(t, n->as.binary.left);
      t->expected = l; // hand the lvalue's type to the RHS for expected-type resolution
      check_expr(t, n->as.binary.right);
      tc_mark_move(t, n->as.binary.right); // `z = x` moves a Free x
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
      result = check_call(t, n, id, expected);
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
      t->addr_ctx = addr_ctx; // `&buf[i]` borrows buf -- propagate the address context to the base
      const TypeId obj = check_expr(t, n->as.index.object);
      const Ty *const ot = ast_type_at(a, obj);
      const Node *const idxn = ast_at_const(a, n->as.index.index);
      if (idxn->kind == NODE_RANGE) { // `a[lo..hi]` -> a `[]T` view of the element type
        TypeId elem = TYPE_NONE, selem;
        if (ot->kind == TYPE_ARRAY || ot->kind == TYPE_POINTER)
          elem = ot->as.elem;
        else if (slice_kind(t, obj, &selem))
          elem = selem;
        else if (obj != TYPE_NONE) {
          const Span sp = ast_at_const(a, n->as.index.object)->span;
          typechecker_errorf(t, sp.start, sp.end - sp.start, "cannot slice this expression");
        }
        const NodeId bounds[2] = {idxn->as.pattern_range.start, idxn->as.pattern_range.end};
        for (int b = 0; b < 2; b++) {
          if (bounds[b] == NODE_NONE)
            continue;
          const TypeId bt = check_expr(t, bounds[b]);
          if (bt != TYPE_NONE && !is_int(t, bt) && ast_at_const(a, bounds[b])->kind != NODE_LITERAL) {
            const Span sp = ast_at_const(a, bounds[b])->span;
            typechecker_errorf(t, sp.start, sp.end - sp.start, "range bound must be an integer");
          }
        }
        result = elem != TYPE_NONE ? prelude_slice_type(t, elem, false) : TYPE_NONE;
        break;
      }
      const TypeId idx = check_expr(t, n->as.index.index);
      bool overloaded = false;
      if (obj != TYPE_NONE) {
        TypeId selem;
        if (ot->kind == TYPE_ARRAY || ot->kind == TYPE_POINTER)
          result = ot->as.elem;
        else if (slice_kind(t, obj, &selem)) // `s[i]` on a `[]T` -> the element type
          result = selem;
        else if (ot->kind == TYPE_STRUCT || ot->kind == TYPE_INSTANCE) { // `obj[i]` -> its `index` method
          overloaded = true;
          ModuleId om;
          NodeId od;
          DefId gp[4];
          TypeId ga[4];
          int gn;
          const Span sp = ast_at_const(a, n->as.index.object)->span;
          if (aggregate_of(t, strip(t, obj), &om, &od, gp, ga, &gn)) {
            const DefId md = find_method_cstr(t, om, od, "index");
            if (md.node == NODE_NONE) {
              char ty[96];
              render_type(t, strip(t, obj), ty, sizeof ty);
              typechecker_errorf(t, sp.start, sp.end - sp.start, "'%s' has no 'index' method for '[]'", ty);
            } else {
              result = tc_method_ret(t, strip(t, obj), md);
            }
          }
        } else {
          const Span sp = ast_at_const(a, n->as.index.object)->span;
          typechecker_errorf(t, sp.start, sp.end - sp.start, "cannot index this expression");
        }
      }
      // The index key type is governed by an overloaded `index` method's own signature; only a builtin
      // array/slice/pointer index must be an integer.
      if (!overloaded && idx != TYPE_NONE && !is_int(t, idx) && ast_at_const(a, n->as.index.index)->kind != NODE_LITERAL) {
        const Span sp = ast_at_const(a, n->as.index.index)->span;
        typechecker_errorf(t, sp.start, sp.end - sp.start, "index must be an integer");
      }
      break;
    }
    case NODE_MEMBER:
      t->addr_ctx = addr_ctx; // `&x.f` borrows x -- propagate the address context to the receiver
      result = n->as.member.path ? check_path_member(t, n, id, expected) : check_member(t, n, false);
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
        // A complex has no C conversion to a real/int (use creal/cimag); real -> complex and c32<->c64 are fine.
        const bool complex_lossy =
            sk == TYPE_BUILTIN && bt_is_complex(ast_type_at(a, src)->as.builtin) && dk == TYPE_BUILTIN &&
            !bt_is_complex(ast_type_at(a, dst)->as.builtin);
        if ((aggregate && !enum_int) || complex_lossy) {
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
    case NODE_VA_EXPR: {
      // `va_start(ap, last)` / `va_arg(ap, T)` / `va_end(ap)`: `ap` must be a `va_list`. va_arg yields T;
      // va_start / va_end are void. The last named parameter (va_start) is checked for resolution only.
      if (n->as.va_op.op == VA_START && ast_at_const(a, n->as.va_op.ap)->kind == NODE_IDENTIFIER) {
        const DefId d = ast_resolution_def(a, n->as.va_op.ap); // va_start initializes a deferred `va_list`
        if (d.module == t->ast->module && d.node != NODE_NONE)
          tc_init(t, d.node);
      }
      const TypeId apt = check_expr(t, n->as.va_op.ap);
      const Ty *const ay = apt != TYPE_NONE ? ast_type_at(a, apt) : NULL;
      if (ay && !(ay->kind == TYPE_BUILTIN && ay->as.builtin == BT_VALIST)) {
        const Span sp = ast_at_const(a, n->as.va_op.ap)->span;
        char ty[96];
        render_type(t, apt, ty, sizeof ty);
        typechecker_errorf(t, sp.start, sp.end - sp.start, "expected a 'va_list', found '%s'", ty);
      }
      if (n->as.va_op.op == VA_ARG) {
        result = resolve_type(t, n->as.va_op.extra);
      } else {
        if (n->as.va_op.op == VA_START)
          check_expr(t, n->as.va_op.extra);
        result = ast_builtin(BT_VOID);
      }
      break;
    }
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
        apply_default_args(t, d.module, dn, ta, &tn);
        result = ast_intern_instance(t->ast, d.module, d.node, ta, tn);
      } else {
        result = check_expr(t, inner);
      }
      break;
    }
    case NODE_MATCH: {
      const TypeId scrut = check_expr(t, n->as.match_expr.value);
      // Binding mode (Rust match ergonomics): matching a reference binds each payload by reference
      // (`&T` / `&mut T`); matching an owned value moves it out and consumes the scrutinee.
      const Ty *const sy = ast_type_at(a, scrut);
      const int bind_ref = (sy->kind == TYPE_REFERENCE || sy->kind == TYPE_POINTER)
                               ? (sy->qualifier == TYPE_QUAL_MUT ? 2 : 1)
                               : 0;
      const NodeList arms = n->as.match_expr.arms;
      const NodeId *const ids = ast_list(a, arms);
      bool first = true;
      const FlowState mpre = tc_flow_save(t); // each arm is an alternative path; union their effects after
      FlowState acc = {.nmoved = 0, .nuninit = 0};
      for (uint32_t i = 0; i < arms.len; i++) {
        const Node *const arm = ast_at_const(a, ids[i]);
        tc_flow_set(t, &mpre); // this arm does not see another arm's moves/inits
        check_pattern(t, arm->as.match_arm.pattern, scrut, bind_ref);
        const TypeId g = check_expr(t, arm->as.match_arm.guard);
        if (arm->as.match_arm.guard != NODE_NONE && g != TYPE_NONE && !is_bool(t, g)) {
          const Span sp = ast_at_const(a, arm->as.match_arm.guard)->span;
          typechecker_errorf(t, sp.start, sp.end - sp.start, "match guard must be 'bool'");
        }
        const TypeId body = check_expr(t, arm->as.match_arm.body);
        tc_flow_collect(&acc, t); // ∪ this arm's effects
        if (first) {
          result = body;
          first = false;
        } else if (result != body && body != TYPE_NONE && result != TYPE_NONE) {
          err_mismatch(t, arm->as.match_arm.body, result);
          result = TYPE_NONE;
        }
      }
      if (arms.len)
        tc_flow_set(t, &acc); // post-match = union of every arm
      if (bind_ref == 0)
        tc_mark_move(t, n->as.match_expr.value); // destructuring an owned value consumes it (Free types tracked)
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
        const Node *const el = ast_at_const(a, ids[i]);
        TypeId et;
        if (el->kind == NODE_FIELD_INITIALIZER) { // designated `[index] = value`: index must be integral
          const TypeId it = check_expr(t, el->as.field_initializer.name);
          const Ty *const iy = it != TYPE_NONE ? ast_type_at(a, it) : NULL;
          if (iy && !(iy->kind == TYPE_BUILTIN && (bt_is_int(iy->as.builtin) || iy->as.builtin == BT_CHAR))) {
            const Span sp = ast_at_const(a, el->as.field_initializer.name)->span;
            typechecker_errorf(t, sp.start, sp.end - sp.start, "array designator index must be an integer");
          }
          et = check_expr(t, el->as.field_initializer.value);
        } else {
          et = check_expr(t, ids[i]);
        }
        if (i == 0)
          elem = et;
        else if (et != elem && et != TYPE_NONE && elem != TYPE_NONE) {
          // distinct fn decls intern to distinct TYPE_FUNCTION TypeIds; a homogeneous `[a, b]` of
          // matching-signature functions is still one element type, so unify those structurally.
          const Ty *const e0 = ast_type_at(a, elem), *const ei = ast_type_at(a, et);
          if (!(e0->kind == TYPE_FUNCTION && ei->kind == TYPE_FUNCTION && fn_compatible(t, elem, et))) {
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
        // A block's value is its final expression statement (`{ ..; e; }` yields `e`). An assignment is a
        // statement, not a value, so a block ending in one is `void` (`{ x = y; }` is not an `i32`).
        const NodeId lv = last->kind == NODE_EXPRESSION_STATEMENT ? last->as.single.value : NODE_NONE;
        result = (lv != NODE_NONE && ast_at_const(a, lv)->kind != NODE_ASSIGNMENT) ? ast_type(a, lv)
                                                                                   : ast_builtin(BT_VOID);
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
      const FlowState ifpre = tc_flow_save(t); // branches are alternative paths -> check independent, union after
      const TypeId then_ty = check_expr(t, n->as.if_stmt.then_branch);
      if (n->as.if_stmt.else_branch == NODE_NONE) {
        typechecker_errorf(
            t, n->span.start, n->span.end - n->span.start, "an 'if' used as a value must have an 'else' branch");
        result = TYPE_NONE;
      } else {
        FlowState acc = {.nmoved = 0, .nuninit = 0};
        tc_flow_collect(&acc, t);
        tc_flow_set(t, &ifpre);
        const TypeId else_ty = check_expr(t, n->as.if_stmt.else_branch);
        tc_flow_collect(&acc, t);
        tc_flow_set(t, &acc);
        if (then_ty != else_ty && then_ty != TYPE_NONE && else_ty != TYPE_NONE) {
          err_mismatch(t, n->as.if_stmt.else_branch, then_ty);
          result = TYPE_NONE;
        } else {
          result = then_ty;
        }
      }
      break;
    }
    case NODE_RANGE: { // a range used as a value lowers to `Range<T>` (for/index uses never reach here)
      const TypeId s = check_expr(t, n->as.pattern_range.start);
      const TypeId e = check_expr(t, n->as.pattern_range.end);
      const TypeId elem = range_type(t, n, s, e);
      if (n->as.pattern_range.start == NODE_NONE || n->as.pattern_range.end == NODE_NONE) {
        typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                           "a range value needs both a start and an end");
        result = TYPE_NONE;
      } else
        result = elem != TYPE_NONE ? prelude_range_type(t, elem) : TYPE_NONE;
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

// Escape analysis (v1): the address provenance of a syntactically-obvious address expression.
// 1 = address of a local binding, 2 = address of a parameter slot, 0 = anything else (global/heap, an
// address through a pointer, or not an address). Looks through casts (`&x as *T`, `&x as usize`) and the
// transparent Move/Unsafe wrappers; only a BARE identifier operand of `&`/`&mut` is classified, so
// `&x.field` / `&arr[i]` / `&*p` stay unflagged (those may point through a pointer, not into a local slot).
static int addr_escape(TypeChecker *t, NodeId e) {
  const Node *n = ast_at_const(t->ast, e);
  while (n->kind == NODE_CAST || (n->kind == NODE_UNARY && (n->as.unary.op == Move || n->as.unary.op == Unsafe))) {
    e = n->kind == NODE_CAST ? n->as.cast.expression : n->as.unary.operand;
    n = ast_at_const(t->ast, e);
  }
  if (n->kind != NODE_UNARY || n->as.unary.op != Ampersand)
    return 0;
  if (ast_at_const(t->ast, n->as.unary.operand)->kind != NODE_IDENTIFIER)
    return 0; // &x.field / &arr[i] / &*p -- a place expression, not a bare local slot
  const DefId d = ast_resolution_def(t->ast, n->as.unary.operand);
  if (d.node == NODE_NONE || d.module != t->ast->module)
    return 0;
  switch (ast_at_const(t->ast, d.node)->kind) {
    case NODE_PARAMETER:
      return 2;
    case NODE_LET:
    case NODE_PATTERN_NAME:
      return 1;
    default:
      return 0; // a module-level const/static outlives the function -- safe to return its address
  }
}

static void check_return(TypeChecker *t, const Node *const n, const NodeId id) {
  const NodeList values = n->as.return_stmt.values;
  const NodeId *const vids = ast_list(t->ast, values);
  const NodeList rets = t->current_returns;
  const bool returns_void = return_list_is_explicit_void(t, rets);
  // single-value return: hand the declared return type to the value for expected-type resolution
  if (values.len == 1 && !returns_void && rets.len == 1) {
    const Node *const rn = ast_at_const(t->ast, ast_list(t->ast, rets)[0]);
    t->expected = resolve_type(t, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : ast_list(t->ast, rets)[0]);
  }
  for (uint32_t i = 0; i < values.len; i++)
    check_expr(t, vids[i]);
  for (uint32_t i = 0; i < values.len; i++) { // escape analysis: a returned address of a local/param dangles
    const int esc = addr_escape(t, vids[i]);
    if (esc) {
      const Span sp = ast_at_const(t->ast, vids[i])->span;
      typechecker_errorf(
          t, sp.start, sp.end - sp.start, "returning a pointer/reference to a %s, which does not outlive the call",
          esc == 2 ? "function parameter" : "local variable");
    }
  }
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

// `static_assert(cond, ..)`: the condition must be a boolean expression. Its compile-time truth is
// enforced by the backend C `_Static_assert`, so const-folding is delegated to the C compiler.
static void check_static_assert(TypeChecker *t, const Node *const n) {
  const TypeId c = check_expr(t, n->as.binary.left);
  if (c != TYPE_NONE && !is_bool(t, c)) {
    const Span sp = ast_at_const(t->ast, n->as.binary.left)->span;
    char ty[96];
    render_type(t, c, ty, sizeof ty);
    typechecker_errorf(t, sp.start, sp.end - sp.start, "static_assert condition must be 'bool', found '%s'", ty);
  }
}

static void check_stmt(TypeChecker *t, const NodeId id) {
  if (id == NODE_NONE)
    return;
  Ast *const a = t->ast;
  const Node *const n = ast_at_const(a, id);
  switch (n->kind) {
    case NODE_STATIC_ASSERT:
      check_static_assert(t, n);
      break;
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
      if (valued) {
        t->expected = declared; // hand the annotation to the initializer for expected-type resolution
        check_expr(t, n->as.let_stmt.value);
        tc_mark_move(t, n->as.let_stmt.value); // `let y = x` moves a Free x into y
      }
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
      if (annotated && !valued) { // deferred initialization: usable only once definitely assigned
        if (tc_type_is_free(t, binding)) {
          const Span sp = name_span(t, n->as.let_stmt.name);
          typechecker_errorf(t, sp.start, sp.end - sp.start,
                             "a Free-typed binding must be initialized when declared (it is freed at scope exit)");
        } else {
          tc_add_uninit(t, id); // identifier uses resolve to this NODE_LET node
        }
      }
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
      const Node *const itn = ast_at_const(a, iter);
      TypeId elem;
      if (itn->kind == NODE_RANGE) { // a literal range -> counting loop; bounds checked, no Range<T> value built
        const TypeId s = check_expr(t, itn->as.pattern_range.start);
        const TypeId e = check_expr(t, itn->as.pattern_range.end);
        elem = range_type(t, itn, s, e);  // the loop variable's type
        ast_set_type(a, iter, elem);      // codegen reads the range node's type for the loop binding
      } else {
        const TypeId it = check_expr(t, iter);
        const Ty *const ity = ast_type_at(a, it);
        TypeId selem;
        elem = ity->kind == TYPE_ARRAY  ? ity->as.elem
               : slice_kind(t, it, &selem) ? selem
                                           : range_instance_elem(t, it); // iterate a bound `Range<T>` value
        if (elem == TYPE_NONE && it != TYPE_NONE) // Iterator protocol: `it.next() -> Option<T>` binds x to T
          elem = iter_elem_type(t, it);
        if (elem == TYPE_NONE && it != TYPE_NONE) {
          const Span sp = ast_at_const(a, iter)->span;
          typechecker_errorf(t, sp.start, sp.end - sp.start,
                             "cannot iterate over this value (need an array, slice, range, or an Iterator)");
        }
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

static void check_pattern(TypeChecker *t, const NodeId id, const TypeId expected, const int bind_ref) {
  if (id == NODE_NONE)
    return;
  Ast *const a = t->ast;
  const Node *const n = ast_at_const(a, id);
  switch (n->kind) {
    case NODE_IDENTIFIER: // shorthand struct-field binding
      ast_set_type(a, id, bind_ref ? tc_ref(t, expected, bind_ref == 2) : expected);
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
      ast_set_type(a, id, bind_ref ? tc_ref(t, expected, bind_ref == 2) : expected); // plain binding
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
            check_pattern(t, fcids[k], ft, bind_ref);
        }
      } else {
        if (agg && n->as.pattern.name != NODE_NONE)
          ast_set_resolution_def(a, n->as.pattern.name, (DefId){bmod, decl});
        for (uint32_t i = 0; i < children.len; i++)
          check_pattern(t, ids[i], base, bind_ref); // children are NODE_PATTERN_FIELD; pass the aggregate type
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
        check_pattern(t, ids[i], field_type, bind_ref);
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
        check_pattern(t, ids[i], pt, bind_ref);
      }
      break;
    }
    case NODE_PATTERN_OR: { // each alternative is matched against the same scrutinee type
      const NodeList children = n->as.pattern.children;
      const NodeId *const ids = ast_list(a, children);
      for (uint32_t i = 0; i < children.len; i++)
        check_pattern(t, ids[i], expected, bind_ref);
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
    case NODE_STATIC_ASSERT:
      check_static_assert(t, n);
      break;
    case NODE_FUNCTION: {
      const NodeList params = n->as.function.params;
      const NodeId *const pids = ast_list(t->ast, params);
      for (uint32_t i = 0; i < params.len; i++)
        decl_type(t, pids[i]); // type each parameter so references resolve
      // A Super-C-defined variadic function reads its args with `va_start`/`va_arg`, which need a last
      // named parameter to anchor on -- so `...` requires at least one fixed parameter here.
      if (n->as.function.is_variadic && !n->as.function.is_extern && params.len == 0) {
        const Span sp = name_span(t, n->as.function.name);
        typechecker_errorf(
            t, sp.start, sp.end - sp.start, "a variadic function needs at least one fixed parameter before '...'");
      }
      // The program entry point must be `fn main() i32` -- it lowers to C's `int main(void)`, so any
      // other return type or a parameter list would be silently freeped or miscompiled.
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
      t->nmoved = t->nuninit = t->nfreed = 0; // fresh move + definite-init + use-after-free scope per body
      if (n->as.function.body != NODE_NONE)
        check_stmt(t, n->as.function.body);
      t->nmoved = t->nuninit = t->nfreed = 0;
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
      const NodeId saved_impl = t->current_impl;
      t->current_self = ast_resolution(t->ast, n->as.impl_def.target_type);
      t->current_impl = id; // a bare `Self` here lowers to this impl's target type (with its generics)
      if (n->as.impl_def.trait_type != NODE_NONE)
        check_impl_conformance(t, n);
      check_associated(t, n->as.impl_def.items);
      t->current_self = saved;
      t->current_impl = saved_impl;
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
  errors_finalize(
      &t->errors, &t->errors_start, &t->errors_len, t->source, t->len,
      t->package && t->ast->module < t->package->count ? t->package->modules[t->ast->module].file : NULL);
}

ERRORS_BODY(TypeChecker, typechecker, t)
