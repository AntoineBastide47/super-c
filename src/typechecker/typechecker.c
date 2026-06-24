#include "typechecker.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct TypeChecker {
    Ast *ast;
    const uint8_t *source;
    size_t len;
    NodeList current_returns; // the enclosing function's `returns` list, for NODE_RETURN checking
    NodeId current_self;      // the struct decl whose `extend` we are inside (NODE_NONE at top level)
    ERRORS_VARIABLES;
};

static const char *const BUILTIN_NAMES[BT_COUNT] = {
    "bool", "char", "i8",  "i16",   "i32", "i64", "isize", "u8",
    "u16",  "u32",  "u64", "usize", "f32", "f64", "void", "str",
};

static TypeId check_expr(TypeChecker *t, NodeId id);
static void check_stmt(TypeChecker *t, NodeId id);
static TypeId resolve_type(TypeChecker *t, NodeId id);
static TypeId decl_type(TypeChecker *t, NodeId decl);
static void check_pattern(TypeChecker *t, NodeId id, TypeId expected);
static void render_type(TypeChecker *t, TypeId tid, char *buf, size_t cap);
static TypeId check_member(TypeChecker *t, const Node *n, bool prefer_method);

TypeChecker *typechecker_new(Ast *ast, const char *source, const size_t len) {
  TypeChecker *const t = calloc(1, sizeof *t);
  if (!t) {
    fprintf(stderr, "fatal: out of memory\n");
    abort();
  }
  t->ast = ast;
  t->source = (const uint8_t *)source;
  t->len = len;
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

ALWAYS_INLINE bool span_eq(const uint8_t *const src, const Span a, const Span b) {
  const uint32_t la = a.end - a.start;
  return la == b.end - b.start && memcmp(src + a.start, src + b.start, la) == 0;
}

ALWAYS_INLINE bool span_is(const uint8_t *const src, const Span s, const char *const lit) {
  const size_t n = strlen(lit);
  return (size_t)(s.end - s.start) == n && memcmp(src + s.start, lit, n) == 0;
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
  const NodeList ms = ast_at_const(t->ast, y->as.decl)->as.aggregate.members;
  const NodeId *const ids = ast_list(t->ast, ms);
  for (uint32_t i = 0; i < ms.len; i++)
    if (ast_at_const(t->ast, ids[i])->as.variant.payload.len > 0)
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
      const Node *const d = ast_at_const(t->ast, ty->as.decl);
      const NodeId nm = d->kind == NODE_GENERIC_PARAM ? d->as.generic_param.name : d->as.aggregate.name;
      const Span s = name_span(t, nm);
      snprintf(buf, cap, "%.*s", (int)(s.end - s.start), (const char *)t->source + s.start);
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
  const Node *v = ast_at_const(t->ast, node);
  if (v->kind == NODE_UNARY && v->as.unary.op == Minus) // -literal still counts as a literal
    v = ast_at_const(t->ast, v->as.unary.operand);
  if (v->kind != NODE_LITERAL)
    return false;
  const Ty *const et = ast_type_at(t->ast, expected);
  switch (v->as.literal.token_type) {
    case IntegerLiteral: // an integer literal fits any int *or* float slot (`let f: f64 = 0;`)
      return et->kind == TYPE_BUILTIN && (bt_is_int(et->as.builtin) || bt_is_float(et->as.builtin));
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

// Find a NODE_FIELD / NODE_VARIANT member of a struct/enum decl by name.
static NodeId find_member(TypeChecker *t, const NodeId decl, const Span name) {
  const Node *const d = ast_at_const(t->ast, decl);
  if (d->kind != NODE_STRUCT && d->kind != NODE_ENUM)
    return NODE_NONE;
  const NodeList members = d->as.aggregate.members;
  const NodeId *const ids = ast_list(t->ast, members);
  for (uint32_t i = 0; i < members.len; i++) {
    const Node *const m = ast_at_const(t->ast, ids[i]);
    const NodeId mname = m->kind == NODE_FIELD ? m->as.field.name : m->as.variant.name;
    if (span_eq(t->source, name_span(t, mname), name))
      return ids[i];
  }
  return NODE_NONE;
}

// Find a method named `name` in any top-level impl whose target type resolves to `decl`.
static NodeId find_method(TypeChecker *t, const NodeId decl, const Span name) {
  const NodeList items = ast_at_const(t->ast, t->ast->root)->as.program.items;
  const NodeId *const ids = ast_list(t->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const it = ast_at_const(t->ast, ids[i]);
    if (it->kind != NODE_IMPL || it->as.impl_def.target_type == NODE_NONE)
      continue;
    if (ast_resolution(t->ast, it->as.impl_def.target_type) != decl)
      continue;
    const NodeList methods = it->as.impl_def.items;
    const NodeId *const mids = ast_list(t->ast, methods);
    for (uint32_t j = 0; j < methods.len; j++) {
      const Node *const m = ast_at_const(t->ast, mids[j]);
      if (m->kind == NODE_FUNCTION && span_eq(t->source, name_span(t, m->as.function.name), name))
        return mids[j];
    }
  }
  return NODE_NONE;
}

// Map a resolved declaration node to its TypeId (the struct/enum/alias/generic it names).
static TypeId decl_to_type(TypeChecker *t, const NodeId decl) {
  const Node *const d = ast_at_const(t->ast, decl);
  switch (d->kind) {
    case NODE_STRUCT:
      return ast_intern_type(t->ast, (Ty){.kind = TYPE_STRUCT, .as.decl = decl});
    case NODE_ENUM:
      return ast_intern_type(t->ast, (Ty){.kind = TYPE_ENUM, .as.decl = decl});
    case NODE_TYPE_ALIAS:
      return resolve_type(t, d->as.type_alias.type); // aliases are transparent
    case NODE_GENERIC_PARAM:
      return ast_intern_type(t->ast, (Ty){.kind = TYPE_GENERIC, .as.decl = decl});
    default: // NODE_TRAIT used as a type, Self->impl, etc. — opaque for now
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
      const NodeId decl = ast_resolution(a, id);
      if (decl != NODE_NONE) {
        result = decl_to_type(t, decl);
        // Resolve trailing path segments (e.g. Enum::Variant) against the base's members.
        const NodeId *const pids = ast_list(a, parts);
        for (uint32_t i = 1; i < parts.len; i++) {
          const NodeId member = find_member(t, decl, name_span(t, pids[i]));
          if (member != NODE_NONE)
            ast_set_resolution(a, pids[i], member);
        }
      } else if (parts.len > 0) {
        const int b = builtin_of(t->source, name_span(t, ast_list(a, parts)[0]));
        result = b >= 0 ? ast_builtin((BuiltinType)b) : TYPE_ERROR;
      }
      const NodeList args = n->as.type_path.args;
      const NodeId *const arg_ids = ast_list(a, args);
      for (uint32_t i = 0; i < args.len; i++)
        resolve_type(t, arg_ids[i]);
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
      result = ast_intern_type(a, (Ty){.kind = TYPE_FUNCTION, .as.decl = id});
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
  const NodeId decl = ast_resolution(t->ast, id);
  if (decl != NODE_NONE)
    return decl_to_type(t, decl);
  const int b = builtin_of(t->source, name_span(t, id));
  return b >= 0 ? ast_builtin((BuiltinType)b) : TYPE_ERROR;
}

// Type of a resolved declaration, memoized. Locals (let/for/pattern) already have their type
// stored by the time they are referenced, so the cached read returns it.
static TypeId decl_type(TypeChecker *t, const NodeId decl) {
  if (decl == NODE_NONE)
    return TYPE_NONE;
  const TypeId cached = ast_type(t->ast, decl);
  if (cached != TYPE_NONE)
    return cached;
  const Node *const d = ast_at_const(t->ast, decl);
  TypeId result = TYPE_NONE;
  switch (d->kind) {
    case NODE_PARAMETER:
      result = resolve_type(t, d->as.parameter.type);
      break;
    case NODE_FIELD:
      result = resolve_type(t, d->as.field.type);
      break;
    case NODE_CONST:
      result = resolve_type(t, d->as.const_def.type);
      break;
    case NODE_LET:
      result = resolve_type(t, d->as.let_stmt.type);
      break;
    case NODE_FUNCTION:
      result = ast_intern_type(t->ast, (Ty){.kind = TYPE_FUNCTION, .as.decl = decl});
      break;
    case NODE_STRUCT:
    case NODE_ENUM:
    case NODE_GENERIC_PARAM:
      result = decl_to_type(t, decl);
      break;
    default:
      break;
  }
  ast_set_type(t->ast, decl, result);
  return result;
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

// `Enum::Variant` as an expression yields the enum type; `Type::method` yields the associated
// function type and is normally consumed by check_call.
static TypeId check_path_member(TypeChecker *t, const Node *const n) {
  const NodeId obj = n->as.member.object;
  const NodeId decl = ast_at_const(t->ast, obj)->kind == NODE_IDENTIFIER ? ast_resolution(t->ast, obj) : NODE_NONE;
  const Span mname = name_span(t, n->as.member.member);
  if (decl == NODE_NONE || (ast_at_const(t->ast, decl)->kind != NODE_STRUCT && ast_at_const(t->ast, decl)->kind != NODE_ENUM)) {
    typechecker_errorf(t, n->span.start, n->span.end - n->span.start, "'::' base must be a struct or enum type");
    return TYPE_NONE;
  }
  if (ast_at_const(t->ast, decl)->kind == NODE_ENUM) {
    const NodeId variant = find_member(t, decl, mname);
    if (variant != NODE_NONE && ast_at_const(t->ast, variant)->kind == NODE_VARIANT) {
      ast_set_resolution(t->ast, n->as.member.member, variant);
      return decl_to_type(t, decl);
    }
  }
  const NodeId method = find_method(t, decl, mname);
  if (method != NODE_NONE) {
    ast_set_resolution(t->ast, n->as.member.member, method);
    return decl_type(t, method);
  }
  if (ast_at_const(t->ast, decl)->kind == NODE_ENUM) {
    typechecker_errorf(
        t, mname.start, mname.end - mname.start, "no variant or method '%.*s' on this enum", (int)(mname.end - mname.start),
        t->source + mname.start);
  } else {
    typechecker_errorf(
        t, mname.start, mname.end - mname.start, "no associated method '%.*s' on this struct",
        (int)(mname.end - mname.start), t->source + mname.start);
  }
  return TYPE_NONE;
}

// `Enum::Variant(args)` construction: arity- and type-check the payload, yield the enum type.
static TypeId check_variant_call(
    TypeChecker *t, const Node *const n, const NodeId id, const NodeId variant, const TypeId enum_ty) {
  const NodeList args = n->as.call.args;
  const NodeId *const aids = ast_list(t->ast, args);
  for (uint32_t i = 0; i < args.len; i++)
    check_expr(t, aids[i]);
  const NodeList payload = ast_at_const(t->ast, variant)->as.variant.payload;
  const NodeId *const pl = ast_list(t->ast, payload);
  const Span sp = ast_at_const(t->ast, id)->span;
  if (args.len != payload.len) {
    typechecker_errorf(
        t, sp.start, sp.end - sp.start, "variant expects %u argument%s, found %u", payload.len,
        payload.len == 1 ? "" : "s", args.len);
  } else {
    for (uint32_t i = 0; i < args.len; i++) {
      const Node *const pe = ast_at_const(t->ast, pl[i]);
      const TypeId pt = resolve_type(t, pe->kind == NODE_FIELD ? pe->as.field.type : pl[i]);
      if (!compatible(t, pt, aids[i]))
        err_mismatch(t, aids[i], pt);
    }
  }
  return enum_ty;
}

static TypeId check_call(TypeChecker *t, const Node *const n, const NodeId id) {
  // `Enum::Variant(args)` is construction, not a function call.
  const Node *const path_callee = ast_at_const(t->ast, n->as.call.callee);
  TypeId callee = TYPE_NONE;
  if (path_callee->kind == NODE_MEMBER && path_callee->as.member.path) {
    callee = check_expr(t, n->as.call.callee);
    const NodeId variant = ast_resolution(t->ast, path_callee->as.member.member);
    if (variant != NODE_NONE && ast_at_const(t->ast, variant)->kind == NODE_VARIANT)
      return check_variant_call(t, n, id, variant, callee);
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

  const Node *const fn = ast_at_const(t->ast, ct->as.decl);
  const bool named = fn->kind == NODE_FUNCTION;
  const NodeList params = named ? fn->as.function.params : fn->as.function_type.params;
  const NodeList returns = named ? fn->as.function.returns : fn->as.function_type.returns;

  // A method call `obj.m(args)` binds the receiver to the first (self) parameter implicitly.
  uint32_t skip = 0;
  const Node *const callee_node = ast_at_const(t->ast, n->as.call.callee);
  if (named && callee_node->kind == NODE_MEMBER && !callee_node->as.member.path && params.len > 0) {
    const NodeId m = ast_resolution(t->ast, callee_node->as.member.member);
    if (m != NODE_NONE && ast_at_const(t->ast, m)->kind == NODE_FUNCTION)
      skip = 1;
  }

  const uint32_t expected = params.len - skip;
  if (args.len != expected) {
    typechecker_errorf(
        t, sp.start, sp.end - sp.start, "expected %u argument%s, found %u", expected, expected == 1 ? "" : "s",
        args.len);
  } else {
    const NodeId *const pids = ast_list(t->ast, params);
    for (uint32_t i = 0; i < args.len; i++) {
      const TypeId pt = named ? decl_type(t, pids[i + skip]) : resolve_type(t, pids[i + skip]);
      if (!compatible(t, pt, aids[i]))
        err_mismatch(t, aids[i], pt);
    }
  }
  if (returns.len != 1)
    return TYPE_NONE; // 0 or multiple returns: no single value type yet
  const NodeId r0 = ast_list(t->ast, returns)[0];
  const Node *const rn = ast_at_const(t->ast, r0);
  return resolve_type(t, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : r0);
}

// A non-`pub` struct field of `owner` may only be named from inside `owner`'s own `extend` blocks
// (where current_self == owner). `at` is the access span (the field name); enum variants are exempt.
static void check_field_visibility(TypeChecker *t, const NodeId field, const NodeId owner, const Span at) {
  const Node *const f = ast_at_const(t->ast, field);
  if (f->kind == NODE_FIELD && !f->as.field.is_public && owner != t->current_self)
    typechecker_errorf(
        t, at.start, at.end - at.start, "field '%.*s' is private", (int)(at.end - at.start), t->source + at.start);
}

// `prefer_method` is set when this member is the callee of a call (`obj.name(...)`): a method then wins
// over a same-named field, since `s.len()` (method call) and `s.len` (field read) are different things.
static TypeId check_member(TypeChecker *t, const Node *const n, const bool prefer_method) {
  const TypeId obj = check_expr(t, n->as.member.object);
  if (obj == TYPE_NONE)
    return TYPE_NONE;
  const NodeId mname = n->as.member.member;
  const Span name = name_span(t, mname);
  const TypeId base = strip(t, obj);
  const Ty *const bt = ast_type_at(t->ast, base);
  if (bt->kind == TYPE_BUILTIN && bt->as.builtin == BT_STR) {
    // `str` exposes two read-only fields: `ptr: *const u8` and `len: usize`.
    if (span_is(t->source, name, "ptr"))
      return ast_intern_type(
          t->ast, (Ty){.kind = TYPE_POINTER, .qualifier = TYPE_QUAL_CONST, .as.elem = ast_builtin(BT_U8)});
    if (span_is(t->source, name, "len"))
      return ast_builtin(BT_USIZE);
  }
  if (bt->kind == TYPE_STRUCT || bt->kind == TYPE_ENUM) {
    // Look up the preferred namespace first (method for a call, field for a bare access), then the other.
    NodeId hit = prefer_method ? find_method(t, bt->as.decl, name) : find_member(t, bt->as.decl, name);
    if (hit == NODE_NONE)
      hit = prefer_method ? find_member(t, bt->as.decl, name) : find_method(t, bt->as.decl, name);
    if (hit != NODE_NONE) {
      ast_set_resolution(t->ast, mname, hit);
      if (ast_at_const(t->ast, hit)->kind == NODE_FIELD)
        check_field_visibility(t, hit, bt->as.decl, name);
      return decl_type(t, hit);
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
  const Ty *const st = ast_type_at(t->ast, sty);
  const NodeId decl = st->kind == TYPE_STRUCT ? st->as.decl : NODE_NONE;
  const NodeList fields = n->as.struct_initializer.fields;
  const NodeId *const ids = ast_list(t->ast, fields);
  for (uint32_t i = 0; i < fields.len; i++) {
    const Node *const fi = ast_at_const(t->ast, ids[i]);
    check_expr(t, fi->as.field_initializer.value);
    if (decl == NODE_NONE)
      continue;
    const Span fname = name_span(t, fi->as.field_initializer.name);
    const NodeId field = find_member(t, decl, fname);
    if (field == NODE_NONE) {
      char ty[96];
      render_type(t, sty, ty, sizeof ty);
      typechecker_errorf(
          t, fname.start, fname.end - fname.start, "no field '%.*s' on '%s'", (int)(fname.end - fname.start),
          t->source + fname.start, ty);
      continue;
    }
    ast_set_resolution(t->ast, fi->as.field_initializer.name, field);
    check_field_visibility(t, field, decl, fname); // can't initialize a private field from outside the struct
    if (!compatible(t, decl_type(t, field), fi->as.field_initializer.value))
      err_mismatch(t, fi->as.field_initializer.value, decl_type(t, field));
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
        case StringLiteral: result = ast_builtin(BT_STR); break; // a `str` view over the literal bytes
        default: result = TYPE_NONE; break; // Null, RawString (deferred)
      }
      break;
    case NODE_IDENTIFIER:
      result = decl_type(t, ast_resolution(a, id));
      break;
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
      result = n->as.member.path ? check_path_member(t, n) : check_member(t, n, false);
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
    case NODE_GENERIC_SPECIALIZATION: {
      result = check_expr(t, n->as.specialization.expression);
      const NodeList types = n->as.specialization.types;
      const NodeId *const ids = ast_list(a, types);
      for (uint32_t i = 0; i < types.len; i++)
        resolve_type(t, ids[i]);
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
          err_mismatch(t, ids[i], elem);
          elem = TYPE_NONE;
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
    const TypeId callee = ast_type(a, ast_at_const(a, value)->as.call.callee);
    if (callee != TYPE_NONE) {
      const Ty *const ct = ast_type_at(a, callee);
      if (ct->kind == TYPE_FUNCTION) {
        const Node *const fn = ast_at_const(a, ct->as.decl);
        returns = fn->kind == NODE_FUNCTION ? fn->as.function.returns : fn->as.function_type.returns;
        ok = true;
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
      const Ty *const bt = ast_type_at(a, strip(t, expected));
      if (bt->kind == TYPE_ENUM) {
        const NodeId v = find_member(t, bt->as.decl, name_span(t, n->as.pattern.name));
        if (v != NODE_NONE && ast_at_const(a, v)->kind == NODE_VARIANT &&
            ast_at_const(a, v)->as.variant.payload.len == 0) {
          ast_set_resolution(a, n->as.pattern.name, v);
          break;
        }
      }
      ast_set_type(a, id, expected); // plain binding
      break;
    }
    case NODE_PATTERN_STRUCT: {
      const TypeId base = strip(t, expected);
      const Ty *const bt = ast_type_at(a, base);
      const NodeId decl = bt->kind == TYPE_STRUCT || bt->kind == TYPE_ENUM ? bt->as.decl : NODE_NONE;
      if (n->as.pattern.name != NODE_NONE && decl != NODE_NONE)
        ast_set_resolution(a, n->as.pattern.name, decl);
      const NodeList children = n->as.pattern.children;
      const NodeId *const ids = ast_list(a, children);
      for (uint32_t i = 0; i < children.len; i++)
        check_pattern(t, ids[i], base); // children are NODE_PATTERN_FIELD; pass the aggregate type
      break;
    }
    case NODE_PATTERN_FIELD: {
      const TypeId base = strip(t, expected);
      const Ty *const bt = ast_type_at(a, base);
      const NodeId decl = bt->kind == TYPE_STRUCT || bt->kind == TYPE_ENUM ? bt->as.decl : NODE_NONE;
      TypeId field_type = TYPE_NONE;
      if (decl != NODE_NONE && n->as.pattern.name != NODE_NONE) {
        const Span fname = name_span(t, n->as.pattern.name);
        const NodeId field = find_member(t, decl, fname);
        if (field != NODE_NONE) {
          ast_set_resolution(a, n->as.pattern.name, field);
          field_type = decl_type(t, field);
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
    case NODE_PATTERN_TUPLE: { // enum-variant constructor pattern
      const TypeId base = strip(t, expected);
      const Ty *const bt = ast_type_at(a, base);
      const NodeId decl = bt->kind == TYPE_ENUM ? bt->as.decl : NODE_NONE;
      NodeId variant = NODE_NONE;
      if (decl != NODE_NONE && n->as.pattern.name != NODE_NONE) {
        const Span vname = name_span(t, n->as.pattern.name);
        variant = find_member(t, decl, vname);
        if (variant != NODE_NONE)
          ast_set_resolution(a, n->as.pattern.name, variant);
        else {
          char ty[96];
          render_type(t, base, ty, sizeof ty);
          typechecker_errorf(
              t, vname.start, vname.end - vname.start, "no variant '%.*s' on '%s'", (int)(vname.end - vname.start),
              t->source + vname.start, ty);
        }
      }
      const NodeList children = n->as.pattern.children;
      const NodeId *const ids = ast_list(a, children);
      const NodeList payload = variant != NODE_NONE ? ast_at_const(a, variant)->as.variant.payload : (NodeList){0, 0};
      const NodeId *const pl = ast_list(a, payload);
      for (uint32_t i = 0; i < children.len; i++) {
        TypeId pt = TYPE_NONE;
        if (i < payload.len) {
          const Node *const pe = ast_at_const(a, pl[i]);
          pt = resolve_type(t, pe->kind == NODE_FIELD ? pe->as.field.type : pl[i]);
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
      t->current_returns = n->as.function.returns;
      if (n->as.function.body != NODE_NONE)
        check_stmt(t, n->as.function.body);
      t->current_returns = saved;
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

void typechecker_check(TypeChecker *t) {
  ast_init_types(t->ast);
  const NodeList items = ast_at_const(t->ast, t->ast->root)->as.program.items;
  const NodeId *const ids = ast_list(t->ast, items);
  for (uint32_t i = 0; i < items.len; i++)
    check_item(t, ids[i]);
  errors_finalize(&t->errors, &t->errors_start, &t->errors_len, t->source, t->len);
}

ERRORS_BODY(TypeChecker, typechecker, t)
