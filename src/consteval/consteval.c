#include <stdlib.h>
#include <string.h>

#include "consteval.h"
#include "utils/errors.h"

#define CE_MAX_DEPTH 32 // expression + layout recursion cap (house style: fixed limit, loud failure)

struct ConstEval {
    const Package *pkg;
    ConstValue **vals; // [module][node] memo tables, allocated lazily per module
    size_t *caps;      // allocated length of each module's table
    size_t nmods;
    unsigned depth; // shared recursion depth across expression eval and const-item chasing
};

static const ConstValue CE_NONE = {0};

ConstEval *consteval_new(const Package *pkg) {
  ConstEval *const ce = calloc(1, sizeof *ce);
  if (!ce)
    oom();
  ce->pkg = pkg;
  ce->nmods = pkg->count;
  ce->vals = calloc(pkg->count ? pkg->count : 1, sizeof *ce->vals);
  ce->caps = calloc(pkg->count ? pkg->count : 1, sizeof *ce->caps);
  if (!ce->vals || !ce->caps)
    oom();
  return ce;
}

void consteval_free(ConstEval **pce) {
  if (!pce || !*pce)
    return;
  ConstEval *const ce = *pce;
  for (size_t i = 0; i < ce->nmods; i++)
    free(ce->vals[i]);
  free(ce->vals);
  free(ce->caps);
  free(ce);
  *pce = NULL;
}

static const Ast *ce_ast(const ConstEval *ce, const ModuleId m) {
  return m < ce->pkg->count ? ce->pkg->modules[m].ast : NULL;
}
static const uint8_t *ce_src(const ConstEval *ce, const ModuleId m) {
  return (const uint8_t *)ce->pkg->modules[m].source;
}

// ast_type, but safe on a module the typechecker has not reached yet (its types table may not
// exist: modules check in load order, and the prelude loads AFTER the root). TYPE_NONE = unknown,
// which every caller already treats as unfoldable.
static TypeId ce_type(const Ast *a, const NodeId id) {
  return a->types.len > id ? a->types.data[id] : TYPE_NONE;
}

// Memo slot for (module, node); grows the module table on demand (ASTs grow during checking).
static ConstValue *ce_slot(ConstEval *ce, const ModuleId m, const NodeId id) {
  if (m >= ce->nmods)
    return NULL;
  if (id >= ce->caps[m]) {
    size_t nc = ce->caps[m] ? ce->caps[m] : 256;
    while (nc <= id)
      nc *= 2;
    ConstValue *const g = realloc(ce->vals[m], nc * sizeof *g);
    if (!g)
      oom();
    memset(g + ce->caps[m], 0, (nc - ce->caps[m]) * sizeof *g);
    ce->vals[m] = g;
    ce->caps[m] = nc;
  }
  return &ce->vals[m][id];
}

// --- scalar helpers -------------------------------------------------------------------------

static bool bt_signed(const BuiltinType b) {
  return b == BT_I8 || b == BT_I16 || b == BT_I32 || b == BT_I64 || b == BT_ISIZE;
}
static bool bt_unsigned(const BuiltinType b) {
  return b == BT_U8 || b == BT_U16 || b == BT_U32 || b == BT_U64 || b == BT_USIZE || b == BT_CHAR;
}
static int bt_bits(const BuiltinType b) {
  switch (b) {
    case BT_BOOL: case BT_CHAR: case BT_I8: case BT_U8: return 8;
    case BT_I16: case BT_U16: return 16;
    case BT_I32: case BT_U32: return 32;
    default: return 64; // i64/u64/isize/usize (64-bit model)
  }
}

// Truncate value bits to the type's width, sign- or zero-extending back to 64 bits.
static int64_t wrap_to(const BuiltinType b, const int64_t v) {
  const int bits = bt_bits(b);
  if (bits == 64)
    return v;
  const uint64_t mask = ((uint64_t)1 << bits) - 1;
  uint64_t u = (uint64_t)v & mask;
  if (bt_signed(b) && (u >> (bits - 1)))
    u |= ~mask; // sign-extend
  return (int64_t)u;
}

// Does `v` round-trip through the type's width unchanged? (Folding refuses overflow: the value
// would not be what the runtime computes, and codegen's const-context checks diagnose it.)
static bool fits(const BuiltinType b, const int64_t v) {
  return wrap_to(b, v) == v;
}

static BuiltinType type_builtin(const Ast *a, const TypeId t) {
  if (t == TYPE_NONE)
    return BT_COUNT;
  const Ty *const y = ast_type_at(a, t);
  return y->kind == TYPE_BUILTIN ? y->as.builtin : BT_COUNT;
}

// --- literal parsing ------------------------------------------------------------------------

static ConstValue eval_int_literal(const Ast *a, const uint8_t *src, const Node *n, const NodeId id) {
  const Span sp = n->as.literal.raw;
  uint64_t v = 0;
  size_t i = sp.start;
  unsigned base = 10;
  if (sp.end - sp.start > 2 && src[i] == '0') {
    const uint8_t r = src[i + 1];
    if (r == 'x' || r == 'X') { base = 16; i += 2; }
    else if (r == 'b' || r == 'B') { base = 2; i += 2; }
    else if (r == 'o' || r == 'O') { base = 8; i += 2; }
  }
  for (; i < sp.end; i++) {
    const uint8_t ch = src[i];
    if (ch == '_')
      continue;
    unsigned d;
    if (ch >= '0' && ch <= '9') d = ch - '0';
    else if (ch >= 'a' && ch <= 'f') d = ch - 'a' + 10;
    else if (ch >= 'A' && ch <= 'F') d = ch - 'A' + 10;
    else return CE_NONE;
    if (d >= base)
      return CE_NONE;
    if (v > (UINT64_MAX - d) / base)
      return CE_NONE; // literal too large (already diagnosed by the typechecker)
    v = v * base + d;
  }
  const BuiltinType b = type_builtin(a, ce_type(a, id));
  const int64_t sv = (int64_t)v;
  if (b != BT_COUNT && !fits(b, sv))
    return CE_NONE;
  return (ConstValue){.kind = CONST_INT, .type = ce_type(a, id), .i = sv};
}

static ConstValue eval_char_literal(const Ast *a, const uint8_t *src, const Node *n, const NodeId id) {
  Span sp = n->as.literal.raw; // includes the quotes
  size_t i = sp.start + 1;     // past the opening '
  if (src[sp.start] == 'b')
    i++; // byte-char literal b'..'
  if (i >= sp.end)
    return CE_NONE;
  int64_t v;
  if (src[i] != '\\') {
    v = src[i]; // single byte (multi-byte scalars don't fit `char` and were rejected upstream)
  } else {
    switch (src[i + 1]) {
      case 'n': v = '\n'; break;
      case 't': v = '\t'; break;
      case 'r': v = '\r'; break;
      case '0': v = 0; break;
      case '\\': v = '\\'; break;
      case '\'': v = '\''; break;
      case '"': v = '"'; break;
      case 'x': {
        v = 0;
        for (size_t k = i + 2; k < sp.end - 1; k++) {
          const uint8_t ch = src[k];
          unsigned d;
          if (ch >= '0' && ch <= '9') d = ch - '0';
          else if (ch >= 'a' && ch <= 'f') d = ch - 'a' + 10;
          else if (ch >= 'A' && ch <= 'F') d = ch - 'A' + 10;
          else return CE_NONE;
          v = v * 16 + d;
        }
        break;
      }
      default:
        return CE_NONE; // \u{..} and friends: not needed by any const consumer
    }
  }
  return (ConstValue){.kind = CONST_INT, .type = ce_type(a, id), .i = v};
}

// --- layout engine (64-bit C data model) ------------------------------------------------------

// One instance frame: maps the generic aggregate's param decls onto concrete args (which live in
// `argm`'s type pool and may themselves be generics resolved by the PARENT frame).
typedef struct LayoutEnv {
    const struct LayoutEnv *parent;
    ModuleId pmod;         // module owning the generic param decl nodes
    const NodeId *params;  // generic param decl nodes
    ModuleId argm;         // pool the args below are interned in
    TypeId args[4];
    uint8_t n;
} LayoutEnv;

static bool layout_of(ConstEval *ce, ModuleId m, TypeId t, const LayoutEnv *env, int depth,
                      uint64_t *size, uint64_t *align);

static uint64_t round_up(const uint64_t v, const uint64_t a) {
  return a ? (v + a - 1) / a * a : v;
}

static const Attr *ce_attr(const ConstEval *ce, const ModuleId m, const NodeId owner, const AttrKind kind) {
  const Ast *const a = ce_ast(ce, m);
  for (size_t i = 0; i < a->attrs.len; i++)
    if (a->attrs.data[i].owner == owner && a->attrs.data[i].kind == kind)
      return &a->attrs.data[i];
  return NULL;
}

// Sequential C struct layout over a list of (module, TypeId) field types.
typedef struct {
    uint64_t size, align;
    bool packed;
    bool is_union;
} LayoutAcc;

static bool acc_field(ConstEval *ce, LayoutAcc *acc, const ModuleId m, const TypeId ft,
                      const LayoutEnv *env, const int depth) {
  uint64_t fs, fa;
  if (!layout_of(ce, m, ft, env, depth, &fs, &fa))
    return false;
  if (acc->packed)
    fa = 1;
  if (acc->is_union) {
    acc->size = acc->size > fs ? acc->size : fs;
  } else {
    acc->size = round_up(acc->size, fa) + fs;
  }
  acc->align = acc->align > fa ? acc->align : fa;
  return true;
}

// Layout of aggregate decl (dm, dn) instantiated by `env` (NULL for a plain struct/enum).
static bool aggregate_layout(ConstEval *ce, const ModuleId dm, const NodeId dn, const LayoutEnv *env,
                             const int depth, uint64_t *size, uint64_t *align) {
  const Ast *const a = ce_ast(ce, dm);
  const Node *const d = ast_at_const(a, dn);
  if (d->kind == NODE_ENUM) {
    const NodeList ms = d->as.aggregate.members;
    const NodeId *const mids = ast_list(a, ms);
    bool payload = false;
    for (uint32_t i = 0; i < ms.len; i++)
      payload |= ast_at_const(a, mids[i])->as.variant.payload.len > 0;
    if (!payload) { // a plain C enum: `int` on every mainstream ABI (verified by the emitted assert)
      *size = 4;
      *align = 4;
      return true;
    }
    // Tagged union: `struct { <Name>Tag tag; union { struct{..} v; .. } }` (mirrors codegen).
    LayoutAcc un = {.is_union = true};
    for (uint32_t i = 0; i < ms.len; i++) {
      const Node *const v = ast_at_const(a, mids[i]);
      const NodeList pl = v->as.variant.payload;
      if (pl.len == 0)
        continue;
      const NodeId *const pids = ast_list(a, pl);
      LayoutAcc vs = {0};
      for (uint32_t k = 0; k < pl.len; k++) {
        const Node *const pe = ast_at_const(a, pids[k]);
        const NodeId tn = v->as.variant.struct_payload ? pe->as.field.type : pids[k];
        if (!acc_field(ce, &vs, dm, ce_type(a, tn), env, depth))
          return false;
      }
      vs.size = round_up(vs.size, vs.align);
      if (vs.size > un.size)
        un.size = vs.size;
      if (vs.align > un.align)
        un.align = vs.align;
    }
    LayoutAcc s = {.size = 4, .align = 4}; // the tag (a C enum -> int)
    s.size = round_up(s.size, un.align) + un.size;
    s.align = s.align > un.align ? s.align : un.align;
    *size = round_up(s.size, s.align);
    *align = s.align;
    return true;
  }
  if (d->kind != NODE_STRUCT)
    return false;
  LayoutAcc acc = {.is_union = d->as.aggregate.is_union};
  acc.packed = ce_attr(ce, dm, dn, ATTR_PACKED) != NULL;
  const NodeList fs = d->as.aggregate.members;
  const NodeId *const fids = ast_list(a, fs);
  for (uint32_t i = 0; i < fs.len; i++) {
    const Node *const f = ast_at_const(a, fids[i]);
    if (f->kind != NODE_FIELD)
      continue;
    const TypeId ft = ce_type(a, f->as.field.type);
    if (ft == TYPE_NONE)
      return false; // the struct hasn't been type-checked yet; stay unfoldable rather than guess
    if (!acc_field(ce, &acc, dm, ft, env, depth))
      return false;
  }
  const Attr *const al = ce_attr(ce, dm, dn, ATTR_ALIGN);
  if (al && al->arg)
    acc.align = al->arg > acc.align ? al->arg : acc.align;
  if (acc.align == 0)
    acc.align = 1; // empty struct: C size is 0 here (GNU mode); the emitted assert verifies
  *size = round_up(acc.size, acc.align);
  *align = acc.align;
  return true;
}

static bool layout_of(ConstEval *ce, const ModuleId m, const TypeId t, const LayoutEnv *env,
                      const int depth, uint64_t *size, uint64_t *align) {
  if (depth > CE_MAX_DEPTH || t == TYPE_NONE)
    return false;
  const Ast *const a = ce_ast(ce, m);
  if (!a)
    return false;
  const Ty *const y = ast_type_at(a, t);
  switch (y->kind) {
    case TYPE_BUILTIN:
      switch (y->as.builtin) {
        case BT_BOOL: case BT_CHAR: case BT_I8: case BT_U8: *size = 1; *align = 1; return true;
        case BT_I16: case BT_U16: *size = 2; *align = 2; return true;
        case BT_I32: case BT_U32: case BT_F32: *size = 4; *align = 4; return true;
        case BT_I64: case BT_U64: case BT_ISIZE: case BT_USIZE: case BT_F64: *size = 8; *align = 8; return true;
        case BT_C32: *size = 8; *align = 4; return true;   // float _Complex
        case BT_C64: *size = 16; *align = 8; return true;  // double _Complex
        default: return false; // va_list (wildly ABI-dependent), void
      }
    case TYPE_POINTER:
    case TYPE_REFERENCE:
    case TYPE_FUNCTION:
      *size = 8; // the declared 64-bit model; the emitted _Static_asserts verify per target
      *align = 8;
      return true;
    case TYPE_ARRAY: {
      if (y->as.arr.len == 0)
        return false; // unknown length (unfolded / VLA-style)
      uint64_t es, ea;
      if (!layout_of(ce, m, y->as.elem, env, depth + 1, &es, &ea))
        return false;
      *size = es * y->as.arr.len;
      *align = ea;
      return true;
    }
    case TYPE_GENERIC: {
      for (const LayoutEnv *e = env; e; e = e->parent)
        for (uint8_t i = 0; i < e->n; i++)
          if (e->pmod == y->module && e->params[i] == y->as.decl)
            return layout_of(ce, e->argm, e->args[i], e->parent, depth + 1, size, align);
      return false; // unbound param (interface Self, un-instantiated context)
    }
    case TYPE_STRUCT:
    case TYPE_ENUM:
      return aggregate_layout(ce, y->module, y->as.decl, NULL, depth + 1, size, align);
    case TYPE_INSTANCE: {
      const TyInstance *const it = ast_instance(a, y->as.inst);
      const Ast *const da = ce_ast(ce, it->module);
      if (!da)
        return false;
      const Node *const dn = ast_at_const(da, it->decl);
      const NodeList gens = dn->as.aggregate.generics;
      LayoutEnv frame = {.parent = env, .pmod = it->module, .params = ast_list(da, gens), .argm = m, .n = 0};
      for (uint32_t i = 0; i < gens.len && i < it->n && frame.n < 4; i++)
        frame.args[frame.n++] = it->args[i];
      return aggregate_layout(ce, it->module, it->decl, &frame, depth + 1, size, align);
    }
    default:
      return false; // OPAQUE (C-header-defined), SLICE (dead kind), NEVER, ERROR
  }
}

bool consteval_layout(ConstEval *ce, const ModuleId m, const TypeId t, uint64_t *size, uint64_t *align) {
  return layout_of(ce, m, t, NULL, 0, size, align);
}

// --- expression evaluation --------------------------------------------------------------------

// The discriminant of payload-less enum variant (vm, vd): its explicit `= <int>` else previous+1.
static ConstValue variant_value(ConstEval *ce, const ModuleId vm, const NodeId vd) {
  const Ast *const a = ce_ast(ce, vm);
  // Find the enclosing enum by scanning top-level items (variants carry no back-pointer).
  const NodeList items = ast_at_const(a, a->root)->as.program.items;
  const NodeId *const iids = ast_list(a, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const it = ast_at_const(a, iids[i]);
    if (it->kind != NODE_ENUM)
      continue;
    const NodeList ms = it->as.aggregate.members;
    const NodeId *const mids = ast_list(a, ms);
    int64_t next = 0;
    for (uint32_t k = 0; k < ms.len; k++) {
      const Node *const v = ast_at_const(a, mids[k]);
      if (v->as.variant.payload.len > 0)
        return CE_NONE; // tagged enums have struct values, not integer ones
      if (v->as.variant.value != NODE_NONE) {
        const ConstValue e = consteval_eval(ce, vm, v->as.variant.value);
        if (e.kind != CONST_INT)
          return CE_NONE;
        next = e.i;
      }
      if (mids[k] == vd)
        return (ConstValue){.kind = CONST_INT, .type = TYPE_NONE, .i = next};
      next++;
    }
  }
  return CE_NONE;
}

static ConstValue eval_node(ConstEval *ce, const ModuleId m, const NodeId id);

ConstValue consteval_eval(ConstEval *ce, const ModuleId m, const NodeId id) {
  if (!ce || id == NODE_NONE || m >= ce->nmods)
    return CE_NONE;
  ConstValue *const slot = ce_slot(ce, m, id);
  if (!slot)
    return CE_NONE;
  if (slot->kind != CONST_NONE)
    return *slot; // memoized (CONST_NONE misses re-evaluate; harmless, they terminate identically)
  if (ce->depth > CE_MAX_DEPTH)
    return CE_NONE;
  ce->depth++;
  const ConstValue v = eval_node(ce, m, id);
  ce->depth--;
  if (v.kind != CONST_NONE)
    *slot = v;
  return v;
}

static ConstValue eval_node(ConstEval *ce, const ModuleId m, const NodeId id) {
  const Ast *const a = ce_ast(ce, m);
  if (!a)
    return CE_NONE;
  const Node *const n = ast_at_const(a, id);
  const uint8_t *const src = ce_src(ce, m);
  switch (n->kind) {
    case NODE_LITERAL:
      switch (n->as.literal.token_type) {
        case IntegerLiteral:
          return eval_int_literal(a, src, n, id);
        case CharacterLiteral:
        case ByteCharacterLiteral:
          return eval_char_literal(a, src, n, id);
        case True:
          return (ConstValue){.kind = CONST_BOOL, .type = ce_type(a, id), .i = 1};
        case False:
          return (ConstValue){.kind = CONST_BOOL, .type = ce_type(a, id), .i = 0};
        default:
          return CE_NONE; // floats/strings: no const consumer needs them
      }
    case NODE_IDENTIFIER: { // a reference to a `const` item (possibly imported): chase its initializer
      DefId d = ast_resolution_def(a, id); // imports record a DefId; same-module refs the plain table
      if (d.node == NODE_NONE)
        d = (DefId){m, ast_resolution(a, id)};
      if (d.node == NODE_NONE || d.module >= ce->nmods)
        return CE_NONE;
      const Node *const dn = ast_at_const(ce_ast(ce, d.module), d.node);
      if (dn->kind != NODE_CONST || dn->as.const_def.value == NODE_NONE)
        return CE_NONE; // not a const (or an extern const whose value lives in a C header)
      ConstValue v = consteval_eval(ce, d.module, dn->as.const_def.value);
      v.type = ce_type(a, id); // report in the referencing node's type
      return v;
    }
    case NODE_MEMBER: { // `Enum::Variant` of a payload-less enum folds to its discriminant
      if (!n->as.member.path)
        return CE_NONE;
      DefId d = ast_resolution_def(a, id);
      if (d.node == NODE_NONE)
        d = ast_resolution_def(a, n->as.member.member);
      if (d.node == NODE_NONE || d.module >= ce->nmods)
        return CE_NONE;
      const Node *const dn = ast_at_const(ce_ast(ce, d.module), d.node);
      if (dn->kind == NODE_CONST && dn->as.const_def.value != NODE_NONE) { // `mod::CONST`
        ConstValue v = consteval_eval(ce, d.module, dn->as.const_def.value);
        v.type = ce_type(a, id);
        return v;
      }
      if (dn->kind != NODE_VARIANT)
        return CE_NONE;
      ConstValue v = variant_value(ce, d.module, d.node);
      v.type = ce_type(a, id);
      return v;
    }
    case NODE_UNARY: {
      const TokenType op = n->as.unary.op;
      if (op == Move || op == Unsafe) // transparent wrappers
        return consteval_eval(ce, m, n->as.unary.operand);
      const ConstValue o = consteval_eval(ce, m, n->as.unary.operand);
      if (o.kind == CONST_NONE)
        return CE_NONE;
      const BuiltinType b = type_builtin(a, ce_type(a, id));
      switch (op) {
        case Minus: {
          if (o.kind != CONST_INT || o.i == INT64_MIN)
            return CE_NONE;
          const int64_t r = -o.i;
          if (b != BT_COUNT && !fits(b, r))
            return CE_NONE;
          return (ConstValue){.kind = CONST_INT, .type = ce_type(a, id), .i = r};
        }
        case Tilde:
          if (o.kind != CONST_INT)
            return CE_NONE;
          return (ConstValue){.kind = CONST_INT, .type = ce_type(a, id), .i = wrap_to(b == BT_COUNT ? BT_I64 : b, ~o.i)};
        case Bang:
          if (o.kind != CONST_BOOL)
            return CE_NONE;
          return (ConstValue){.kind = CONST_BOOL, .type = ce_type(a, id), .i = !o.i};
        default:
          return CE_NONE;
      }
    }
    case NODE_CAST: { // int -> int casts wrap to the target width; everything else stays runtime
      const ConstValue o = consteval_eval(ce, m, n->as.cast.expression);
      if (o.kind != CONST_INT)
        return CE_NONE;
      const BuiltinType b = type_builtin(a, ce_type(a, id));
      if (b == BT_COUNT || b == BT_F32 || b == BT_F64 || b == BT_C32 || b == BT_C64 || b == BT_BOOL)
        return CE_NONE;
      return (ConstValue){.kind = CONST_INT, .type = ce_type(a, id), .i = wrap_to(b, o.i)};
    }
    case NODE_SIZEOF:
    case NODE_ALIGNOF: {
      uint64_t size, align;
      const TypeId ty = ce_type(a, n->as.single.value); // the type node's resolved TypeId
      if (!consteval_layout(ce, m, ty, &size, &align))
        return CE_NONE;
      const uint64_t v = n->kind == NODE_SIZEOF ? size : align;
      return (ConstValue){.kind = CONST_INT, .type = ce_type(a, id), .i = (int64_t)v};
    }
    case NODE_BINARY: {
      const ConstValue l = consteval_eval(ce, m, n->as.binary.left);
      if (l.kind == CONST_NONE)
        return CE_NONE;
      const TokenType op = n->as.binary.op;
      // Short-circuit forms still require BOTH sides const (side effects can't fold away).
      const ConstValue r = consteval_eval(ce, m, n->as.binary.right);
      if (r.kind == CONST_NONE)
        return CE_NONE;
      const TypeId rt = ce_type(a, id);
      const BuiltinType b = type_builtin(a, rt);
      if (l.kind == CONST_BOOL && r.kind == CONST_BOOL) {
        switch (op) {
          case AmpersandAmpersand: return (ConstValue){.kind = CONST_BOOL, .type = rt, .i = l.i && r.i};
          case PipePipe: return (ConstValue){.kind = CONST_BOOL, .type = rt, .i = l.i || r.i};
          case EqualEqual: return (ConstValue){.kind = CONST_BOOL, .type = rt, .i = l.i == r.i};
          case BangEqual: return (ConstValue){.kind = CONST_BOOL, .type = rt, .i = l.i != r.i};
          default: return CE_NONE;
        }
      }
      if (l.kind != CONST_INT || r.kind != CONST_INT)
        return CE_NONE;
      // The operands' shared type decides signedness for division/shifts/comparisons.
      const BuiltinType ob = type_builtin(a, ce_type(a, n->as.binary.left));
      const bool uns = ob != BT_COUNT && bt_unsigned(ob);
      switch (op) {
        case EqualEqual: return (ConstValue){.kind = CONST_BOOL, .type = rt, .i = l.i == r.i};
        case BangEqual: return (ConstValue){.kind = CONST_BOOL, .type = rt, .i = l.i != r.i};
        case LessThan:
          return (ConstValue){.kind = CONST_BOOL, .type = rt, .i = uns ? (uint64_t)l.i < (uint64_t)r.i : l.i < r.i};
        case LessThanEqual:
          return (ConstValue){.kind = CONST_BOOL, .type = rt, .i = uns ? (uint64_t)l.i <= (uint64_t)r.i : l.i <= r.i};
        case GreaterThan:
          return (ConstValue){.kind = CONST_BOOL, .type = rt, .i = uns ? (uint64_t)l.i > (uint64_t)r.i : l.i > r.i};
        case GreaterThanEqual:
          return (ConstValue){.kind = CONST_BOOL, .type = rt, .i = uns ? (uint64_t)l.i >= (uint64_t)r.i : l.i >= r.i};
        default:
          break;
      }
      int64_t v;
      switch (op) {
        case Plus:
          if (__builtin_add_overflow(l.i, r.i, &v)) return CE_NONE;
          break;
        case Minus:
          if (__builtin_sub_overflow(l.i, r.i, &v)) return CE_NONE;
          break;
        case Star:
          if (__builtin_mul_overflow(l.i, r.i, &v)) return CE_NONE;
          break;
        case Slash:
          if (r.i == 0 || (!uns && l.i == INT64_MIN && r.i == -1)) return CE_NONE;
          v = uns ? (int64_t)((uint64_t)l.i / (uint64_t)r.i) : l.i / r.i;
          break;
        case Percent:
          if (r.i == 0 || (!uns && l.i == INT64_MIN && r.i == -1)) return CE_NONE;
          v = uns ? (int64_t)((uint64_t)l.i % (uint64_t)r.i) : l.i % r.i;
          break;
        case Ampersand: v = l.i & r.i; break;
        case Pipe: v = l.i | r.i; break;
        case Caret: v = l.i ^ r.i; break;
        case LeftShift: {
          const int bits = ob == BT_COUNT ? 64 : bt_bits(ob);
          if (r.i < 0 || r.i >= bits) return CE_NONE;
          v = (int64_t)((uint64_t)l.i << r.i);
          break;
        }
        case RightShift: {
          const int bits = ob == BT_COUNT ? 64 : bt_bits(ob);
          if (r.i < 0 || r.i >= bits) return CE_NONE;
          v = uns ? (int64_t)((uint64_t)l.i >> r.i) : l.i >> r.i;
          break;
        }
        default:
          return CE_NONE;
      }
      if (b != BT_COUNT && !fits(b, v))
        return CE_NONE; // would not match the runtime value (wrap/trap) -- stay runtime
      return (ConstValue){.kind = CONST_INT, .type = rt, .i = v};
    }
    default:
      return CE_NONE; // calls, places, everything effectful: not a constant expression
  }
}
