#include <stdlib.h>
#include <string.h>

#include "consteval.h"
#include "utils/errors.h"

#define CE_MAX_DEPTH 32 // expression + layout recursion cap (house style: fixed limit, loud failure)

// Compile-time function execution (implicit, Zig-style: no `const fn` marker). A call whose
// arguments fold is RUN by the interpreter below when the callee is a plain, non-generic Super-C
// function over scalars; anything else (extern/variadic/generic callees, aggregates, pointers,
// allocation, budget blowups) bails to CONST_NONE and the call stays a runtime call.
#define CE_MAX_STEPS (1u << 20) // interpreted statements + expressions per top-level evaluation
#define CE_MAX_FRAMES 48        // call depth; also breaks const<->fn reference cycles
#define CE_MAX_LOCALS 64        // scalar bindings per frame (params, lets, loop/pattern bindings)

struct ConstEval {
    const Package *pkg;
    ConstValue **vals; // [module][node] memo tables, allocated lazily per module
    size_t *caps;      // allocated length of each module's table
    size_t nmods;
    unsigned depth;   // shared recursion depth across expression eval and const-item chasing
    unsigned nframes; // live interpreter call frames
    uint32_t steps;   // interpreter work counter, reset per top-level evaluation
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

// One integer binary op: `rt`/`b` are the RESULT type, `ob` the operands' shared type (signedness
// for division/shifts/comparisons). Overflow/UB refuses to fold (the runtime value would differ).
static ConstValue ce_int_op(const TokenType op, const ConstValue l, const ConstValue r, const TypeId rt,
                            const BuiltinType b, const BuiltinType ob) {
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

// --- the CTFE interpreter (frames over the scalar folder) --------------------------------------

typedef struct {
    NodeId decl;  // the binding's decl node: NODE_PARAMETER / NODE_LET / NODE_FOR / NODE_PATTERN_NAME
    ConstValue v; // CONST_NONE = declared but unassigned on this path (`let x;`)
} CeLocal;

typedef struct {
    CeLocal locals[CE_MAX_LOCALS];
    uint32_t n;
    ConstValue ret;
} CeFrame;

enum { X_OK, X_RETURN, X_BREAK, X_CONTINUE, X_BAIL }; // statement outcomes

static CeLocal *ce_find(CeFrame *f, const NodeId decl) {
  for (uint32_t i = f->n; i-- > 0;)
    if (f->locals[i].decl == decl)
      return &f->locals[i];
  return NULL;
}

static CeLocal *ce_bind(CeFrame *f, const NodeId decl, const ConstValue v) {
  CeLocal *loc = ce_find(f, decl);
  if (!loc) {
    if (f->n >= CE_MAX_LOCALS)
      return NULL;
    loc = &f->locals[f->n++];
    loc->decl = decl;
  }
  loc->v = v;
  return loc;
}

static ConstValue eval_node(ConstEval *ce, CeFrame *f, ModuleId m, NodeId id);
static ConstValue eval_call(ConstEval *ce, CeFrame *f, ModuleId m, NodeId id);
static int exec_stmt(ConstEval *ce, CeFrame *f, ModuleId m, NodeId id);
static int exec_match(ConstEval *ce, CeFrame *f, ModuleId m, const Node *n, ConstValue *out);

// Evaluate an expression in frame `f` (NULL = the memoized top-level path). Frame results are
// NEVER memoized: the same node re-evaluates under different bindings on every call/iteration.
static ConstValue eval_in(ConstEval *ce, CeFrame *f, const ModuleId m, const NodeId id) {
  if (!f)
    return consteval_eval(ce, m, id);
  if (id == NODE_NONE || ++ce->steps > CE_MAX_STEPS || ce->depth > CE_MAX_DEPTH)
    return CE_NONE;
  ce->depth++;
  const ConstValue v = eval_node(ce, f, m, id);
  ce->depth--;
  return v;
}

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
  if (ce->depth == 0 && ce->nframes == 0)
    ce->steps = 0; // a fresh top-level evaluation gets a fresh interpreter budget
  ce->depth++;
  const ConstValue v = eval_node(ce, NULL, m, id);
  ce->depth--;
  if (v.kind != CONST_NONE)
    *slot = v;
  return v;
}

static ConstValue eval_node(ConstEval *ce, CeFrame *f, const ModuleId m, const NodeId id) {
  const Ast *const a = ce_ast(ce, m);
  if (!a)
    return CE_NONE;
  // Inside a frame every expression must be TYPED: width/signedness comes from the checked types,
  // and an un-checked body (a call folded before the checker reached the callee) must stay runtime.
  if (f && ce_type(a, id) == TYPE_NONE)
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
    case NODE_IDENTIFIER: { // a frame local, else a reference to a `const` item: chase its initializer
      DefId d = ast_resolution_def(a, id); // imports record a DefId; same-module refs the plain table
      if (d.node == NODE_NONE)
        d = (DefId){m, ast_resolution(a, id)};
      if (d.node == NODE_NONE || d.module >= ce->nmods)
        return CE_NONE;
      if (f && d.module == m) {
        const CeLocal *const loc = ce_find(f, d.node);
        if (loc) {
          if (loc->v.kind == CONST_NONE)
            return CE_NONE; // declared but unassigned on this path
          ConstValue v = loc->v;
          v.type = ce_type(a, id);
          return v;
        }
      }
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
        return eval_in(ce, f, m, n->as.unary.operand);
      const ConstValue o = eval_in(ce, f, m, n->as.unary.operand);
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
      const ConstValue o = eval_in(ce, f, m, n->as.cast.expression);
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
      const ConstValue l = eval_in(ce, f, m, n->as.binary.left);
      if (l.kind == CONST_NONE)
        return CE_NONE;
      const TokenType op = n->as.binary.op;
      // Short-circuit forms still require BOTH sides const (side effects can't fold away).
      const ConstValue r = eval_in(ce, f, m, n->as.binary.right);
      if (r.kind == CONST_NONE)
        return CE_NONE;
      const TypeId rt = ce_type(a, id);
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
      return ce_int_op(op, l, r, rt, type_builtin(a, rt), type_builtin(a, ce_type(a, n->as.binary.left)));
    }
    case NODE_CALL: // implicit CTFE: run the callee when everything about the call folds
      return eval_call(ce, f, m, id);
    case NODE_MATCH: { // a `switch` VALUE only folds inside a frame (pattern bindings need one)
      if (!f)
        return CE_NONE;
      ConstValue out = CE_NONE;
      return exec_match(ce, f, m, n, &out) == X_OK ? out : CE_NONE;
    }
    case NODE_BLOCK: { // a value block: `{ ..; e; }` yields `e` (the checker's block-value rule)
      if (!f || n->as.block.statements.len == 0)
        return CE_NONE;
      const NodeId *const ids = ast_list(a, n->as.block.statements);
      for (uint32_t i = 0; i + 1 < n->as.block.statements.len; i++)
        if (exec_stmt(ce, f, m, ids[i]) != X_OK)
          return CE_NONE; // control flow escaping a VALUE position: stay runtime
      const Node *const last = ast_at_const(a, ids[n->as.block.statements.len - 1]);
      if (last->kind != NODE_EXPRESSION_STATEMENT ||
          ast_at_const(a, last->as.single.value)->kind == NODE_ASSIGNMENT)
        return CE_NONE; // a `void` block has no value to fold
      return eval_in(ce, f, m, last->as.single.value);
    }
    case NODE_IF: { // `if` as a value: the taken branch's block value (`else` is mandatory here)
      if (!f)
        return CE_NONE;
      const ConstValue c = eval_in(ce, f, m, n->as.if_stmt.condition);
      if (c.kind != CONST_BOOL)
        return CE_NONE;
      return eval_in(ce, f, m, c.i ? n->as.if_stmt.then_branch : n->as.if_stmt.else_branch);
    }
    default:
      return CE_NONE; // places, allocation, everything effectful: not a constant expression
  }
}

// --- statement interpretation -------------------------------------------------------------------

static TokenType compound_op(const TokenType op) { // `+=` -> `+`, ...; Equal = plain assignment
  switch (op) {
    case PlusEqual: return Plus;
    case MinusEqual: return Minus;
    case StarEqual: return Star;
    case SlashEqual: return Slash;
    case PercentEqual: return Percent;
    case AmpersandEqual: return Ampersand;
    case PipeEqual: return Pipe;
    case CaretEqual: return Caret;
    case LeftShiftEqual: return LeftShift;
    case RightShiftEqual: return RightShift;
    default: return Equal;
  }
}

// `<local> op= <expr>`: only whole scalar frame locals -- fields, indices and derefs stay runtime.
static int exec_assign(ConstEval *ce, CeFrame *f, const ModuleId m, const Node *n) {
  const Ast *const a = ce_ast(ce, m);
  const NodeId lhs = n->as.binary.left;
  if (ast_at_const(a, lhs)->kind != NODE_IDENTIFIER)
    return X_BAIL;
  DefId d = ast_resolution_def(a, lhs);
  if (d.node == NODE_NONE)
    d = (DefId){m, ast_resolution(a, lhs)};
  if (d.module != m)
    return X_BAIL;
  CeLocal *const loc = ce_find(f, d.node);
  if (!loc)
    return X_BAIL; // not a frame local (a module-level place): stay runtime
  ConstValue r = eval_in(ce, f, m, n->as.binary.right);
  if (r.kind == CONST_NONE)
    return X_BAIL;
  if (n->as.binary.op != Equal) {
    if (loc->v.kind != CONST_INT || r.kind != CONST_INT)
      return X_BAIL;
    const BuiltinType tb = type_builtin(a, ce_type(a, lhs));
    r = ce_int_op(compound_op(n->as.binary.op), loc->v, r, ce_type(a, lhs), tb, tb);
    if (r.kind == CONST_NONE)
      return X_BAIL;
  }
  loc->v = r;
  return X_OK;
}

// An expression in statement position: assignments and switches execute; anything else must fold
// (a pure value, discarded) or the whole call bails -- effects can never disappear into a fold.
static int exec_expr_stmt(ConstEval *ce, CeFrame *f, const ModuleId m, NodeId id) {
  const Ast *const a = ce_ast(ce, m);
  const Node *n = ast_at_const(a, id);
  while (n->kind == NODE_UNARY && (n->as.unary.op == Move || n->as.unary.op == Unsafe) &&
         ast_at_const(a, n->as.unary.operand)->kind != NODE_BLOCK) {
    id = n->as.unary.operand;
    n = ast_at_const(a, id);
  }
  if (n->kind == NODE_ASSIGNMENT)
    return exec_assign(ce, f, m, n);
  if (n->kind == NODE_MATCH)
    return exec_match(ce, f, m, n, NULL);
  return eval_in(ce, f, m, id).kind != CONST_NONE ? X_OK : X_BAIL;
}

// A `..`/`..=` pattern bound parses as a pattern atom: unwrap the literal wrapper, then evaluate.
// Pattern atoms are context-free constants the checker leaves UNTYPED, so they take the frameless
// memoized path (the frame's typed-node guard would reject them; comparison is by value bits).
static ConstValue eval_pat_bound(ConstEval *ce, const ModuleId m, const NodeId id) {
  const Node *const p = ast_at_const(ce_ast(ce, m), id);
  return consteval_eval(ce, m, p->kind == NODE_PATTERN_LITERAL ? p->as.single.value : id);
}

// Does scalar `v` match pattern `pid`? 1 = yes (bindings applied), 0 = no, -1 = unfoldable.
static int pat_match(ConstEval *ce, CeFrame *f, const ModuleId m, const NodeId pid, const ConstValue *v,
                     const bool uns) {
  const Ast *const a = ce_ast(ce, m);
  const Node *const p = ast_at_const(a, pid);
  switch (p->kind) {
    case NODE_PATTERN_WILDCARD:
      return 1;
    case NODE_PATTERN_NAME: { // a payload-less variant is a tag TEST; any other name BINDS the value
      const DefId d = ast_resolution_def(a, p->as.pattern.name);
      if (d.node != NODE_NONE && d.module < ce->nmods &&
          ast_at_const(ce_ast(ce, d.module), d.node)->kind == NODE_VARIANT) {
        const ConstValue tv = variant_value(ce, d.module, d.node);
        return tv.kind == CONST_INT ? tv.i == v->i : -1;
      }
      return ce_bind(f, pid, *v) ? 1 : -1; // body refs resolve to the pattern node (see resolver)
    }
    case NODE_PATTERN_LITERAL: {
      const ConstValue lv = consteval_eval(ce, m, p->as.single.value); // untyped atom: frameless path
      return lv.kind != CONST_NONE ? lv.i == v->i : -1;
    }
    case NODE_PATTERN_RANGE: {
      if (p->as.pattern_range.start != NODE_NONE) {
        const ConstValue s = eval_pat_bound(ce, m, p->as.pattern_range.start);
        if (s.kind != CONST_INT)
          return -1;
        if (uns ? (uint64_t)v->i < (uint64_t)s.i : v->i < s.i)
          return 0;
      }
      if (p->as.pattern_range.end != NODE_NONE) {
        const ConstValue e = eval_pat_bound(ce, m, p->as.pattern_range.end);
        if (e.kind != CONST_INT)
          return -1;
        if (p->as.pattern_range.inclusive ? (uns ? (uint64_t)v->i > (uint64_t)e.i : v->i > e.i)
                                          : (uns ? (uint64_t)v->i >= (uint64_t)e.i : v->i >= e.i))
          return 0;
      }
      return 1;
    }
    case NODE_PATTERN_OR: {
      const NodeId *const ids = ast_list(a, p->as.pattern.children);
      for (uint32_t i = 0; i < p->as.pattern.children.len; i++) {
        const int r = pat_match(ce, f, m, ids[i], v, uns);
        if (r)
          return r; // matched, or unfoldable
      }
      return 0;
    }
    default:
      return -1; // payload/struct/tuple patterns destructure aggregates: not scalar-foldable
  }
}

// A `switch` over a folded scalar. `out` != NULL is VALUE mode (arm bodies must be expressions);
// NULL is statement mode (arm bodies execute). Returns a statement outcome.
static int exec_match(ConstEval *ce, CeFrame *f, const ModuleId m, const Node *n, ConstValue *out) {
  const Ast *const a = ce_ast(ce, m);
  const ConstValue v = eval_in(ce, f, m, n->as.match_expr.value);
  if (v.kind == CONST_NONE)
    return X_BAIL;
  const BuiltinType sb = type_builtin(a, ce_type(a, n->as.match_expr.value));
  const bool uns = sb != BT_COUNT && bt_unsigned(sb);
  const NodeId *const ids = ast_list(a, n->as.match_expr.arms);
  for (uint32_t i = 0; i < n->as.match_expr.arms.len; i++) {
    const Node *const arm = ast_at_const(a, ids[i]);
    const int hit = pat_match(ce, f, m, arm->as.match_arm.pattern, &v, uns);
    if (hit < 0)
      return X_BAIL;
    if (!hit)
      continue;
    if (arm->as.match_arm.guard != NODE_NONE) {
      const ConstValue g = eval_in(ce, f, m, arm->as.match_arm.guard);
      if (g.kind != CONST_BOOL)
        return X_BAIL;
      if (!g.i)
        continue;
    }
    const NodeId body = arm->as.match_arm.body;
    if (out) { // value mode: expression or value-block arm bodies both evaluate
      *out = eval_in(ce, f, m, body);
      return out->kind != CONST_NONE ? X_OK : X_BAIL;
    }
    return ast_at_const(a, body)->kind == NODE_BLOCK ? exec_stmt(ce, f, m, body) : exec_expr_stmt(ce, f, m, body);
  }
  return X_BAIL; // no arm matched: exhaustiveness says we mis-evaluated somewhere -- stay runtime
}

static int exec_stmt(ConstEval *ce, CeFrame *f, const ModuleId m, const NodeId id) {
  if (++ce->steps > CE_MAX_STEPS)
    return X_BAIL;
  const Ast *const a = ce_ast(ce, m);
  const Node *const n = ast_at_const(a, id);
  switch (n->kind) {
    case NODE_BLOCK: { // locals stay bound past their scope: decl nodes are unique, reads can't leak
      const NodeId *const ids = ast_list(a, n->as.block.statements);
      for (uint32_t i = 0; i < n->as.block.statements.len; i++) {
        const int st = exec_stmt(ce, f, m, ids[i]);
        if (st != X_OK)
          return st;
      }
      return X_OK;
    }
    case NODE_LET: { // refs resolve to the LET node itself; re-binding per iteration overwrites
      if (ast_at_const(a, n->as.let_stmt.name)->kind != NODE_IDENTIFIER)
        return X_BAIL; // tuple/destructuring lets carry aggregates
      ConstValue v = CE_NONE; // `let x;`: definite-init has proven every read follows an assignment
      if (n->as.let_stmt.value != NODE_NONE) {
        v = eval_in(ce, f, m, n->as.let_stmt.value);
        if (v.kind == CONST_NONE)
          return X_BAIL;
      }
      return ce_bind(f, id, v) ? X_OK : X_BAIL;
    }
    case NODE_IF: {
      const ConstValue c = eval_in(ce, f, m, n->as.if_stmt.condition);
      if (c.kind != CONST_BOOL)
        return X_BAIL;
      if (c.i)
        return exec_stmt(ce, f, m, n->as.if_stmt.then_branch);
      return n->as.if_stmt.else_branch == NODE_NONE ? X_OK : exec_stmt(ce, f, m, n->as.if_stmt.else_branch);
    }
    case NODE_WHILE: {
      bool first = n->as.while_stmt.is_do; // `do {} while`: the body runs before the first test
      for (;;) {
        if (!first) {
          const ConstValue c = eval_in(ce, f, m, n->as.while_stmt.condition);
          if (c.kind != CONST_BOOL)
            return X_BAIL;
          if (!c.i)
            return X_OK;
        }
        first = false;
        const int st = exec_stmt(ce, f, m, n->as.while_stmt.body);
        if (st == X_BREAK)
          return X_OK;
        if (st == X_RETURN || st == X_BAIL)
          return st;
        if (++ce->steps > CE_MAX_STEPS)
          return X_BAIL; // the budget is the ONLY brake on `while true`
      }
    }
    case NODE_FOR: { // a literal-range counting loop; refs to the binding resolve to this FOR node
      const Node *const it = ast_at_const(a, n->as.for_stmt.iterable);
      if (it->kind != NODE_RANGE || it->as.pattern_range.start == NODE_NONE || it->as.pattern_range.end == NODE_NONE)
        return X_BAIL; // arrays/slices/Iterators are aggregate iteration: runtime
      const ConstValue s = eval_in(ce, f, m, it->as.pattern_range.start);
      const ConstValue e = eval_in(ce, f, m, it->as.pattern_range.end);
      if (s.kind != CONST_INT || e.kind != CONST_INT)
        return X_BAIL;
      const BuiltinType eb = type_builtin(a, ce_type(a, n->as.for_stmt.iterable));
      const bool uns = eb != BT_COUNT && bt_unsigned(eb);
      const bool inc = it->as.pattern_range.inclusive;
      const TypeId et = ce_type(a, id); // the checker typed the for-node with the element type
      CeLocal *const loc = ce_bind(f, id, CE_NONE);
      if (!loc)
        return X_BAIL;
      for (int64_t v = s.i;; v++) {
        const bool last = v == e.i;
        if (uns ? (uint64_t)v > (uint64_t)e.i || (!inc && last) : v > e.i || (!inc && last))
          return X_OK;
        loc->v = (ConstValue){.kind = CONST_INT, .type = et, .i = v};
        const int st = exec_stmt(ce, f, m, n->as.for_stmt.body);
        if (st == X_BREAK)
          return X_OK;
        if (st == X_RETURN || st == X_BAIL)
          return st;
        if (++ce->steps > CE_MAX_STEPS)
          return X_BAIL;
        if (inc && last)
          return X_OK; // don't step past the type's maximum
      }
    }
    case NODE_RETURN: {
      if (n->as.return_stmt.values.len != 1)
        return X_BAIL; // multi-return carries an aggregate; bare `return` never reaches here (scalar fns)
      const ConstValue v = eval_in(ce, f, m, ast_list(a, n->as.return_stmt.values)[0]);
      if (v.kind == CONST_NONE)
        return X_BAIL;
      f->ret = v;
      return X_RETURN;
    }
    case NODE_BREAK:
      return X_BREAK;
    case NODE_CONTINUE:
      return X_CONTINUE;
    case NODE_EXPRESSION_STATEMENT:
      return exec_expr_stmt(ce, f, m, n->as.single.value);
    default:
      return X_BAIL; // defer/unsafe-block/... : effects the interpreter does not model
  }
}

// Run callee (fm, fn) when the call is a plain, non-generic Super-C function returning one scalar
// and every argument folds. Anything else stays a runtime call.
static ConstValue eval_call(ConstEval *ce, CeFrame *f, const ModuleId m, const NodeId id) {
  const Ast *const a = ce_ast(ce, m);
  const Node *const n = ast_at_const(a, id);
  const BuiltinType rb = type_builtin(a, ce_type(a, id)); // scalar result required
  if (rb == BT_COUNT || rb == BT_F32 || rb == BT_F64 || rb == BT_C32 || rb == BT_C64 || rb == BT_VALIST ||
      rb == BT_VOID)
    return CE_NONE;
  const NodeId callee = n->as.call.callee;
  const Node *const cn = ast_at_const(a, callee);
  DefId d = {0};
  if (cn->kind == NODE_IDENTIFIER) { // direct call; `v.f(..)` methods have a receiver -> runtime
    d = ast_resolution_def(a, callee);
    if (d.node == NODE_NONE)
      d = (DefId){m, ast_resolution(a, callee)};
  } else if (cn->kind == NODE_MEMBER && cn->as.member.path) { // `mod::f(..)` / `Type::assoc(..)`
    d = ast_resolution_def(a, callee);
    if (d.node == NODE_NONE)
      d = ast_resolution_def(a, cn->as.member.member);
  } else {
    return CE_NONE;
  }
  if (d.node == NODE_NONE || d.module >= ce->nmods)
    return CE_NONE;
  const Ast *const fa = ce_ast(ce, d.module);
  const Node *const fn = ast_at_const(fa, d.node);
  if (fn->kind != NODE_FUNCTION || fn->as.function.body == NODE_NONE || fn->as.function.is_extern ||
      fn->as.function.is_variadic || fn->as.function.generics.len > 0 || fn->as.function.returns.len != 1 ||
      ast_type_args(a, id) != NULL) // a monomorphized call: the body's types are per-instance
    return CE_NONE;
  const NodeList params = fn->as.function.params;
  if (params.len != n->as.call.args.len || params.len > CE_MAX_LOCALS || ce->nframes >= CE_MAX_FRAMES)
    return CE_NONE;
  CeFrame g = {.n = 0, .ret = CE_NONE}; // ~1.5 KiB; CE_MAX_FRAMES bounds the C stack
  const NodeId *const pids = ast_list(fa, params);
  const NodeId *const aids = ast_list(a, n->as.call.args);
  for (uint32_t i = 0; i < params.len; i++) { // arguments evaluate in the CALLER's frame
    const ConstValue av = eval_in(ce, f, m, aids[i]);
    if (av.kind == CONST_NONE)
      return CE_NONE;
    g.locals[g.n++] = (CeLocal){.decl = pids[i], .v = av};
  }
  ce->nframes++;
  const unsigned saved = ce->depth; // expression nesting is per-frame; CE_MAX_FRAMES caps the total
  ce->depth = 0;
  const int st = exec_stmt(ce, &g, d.module, fn->as.function.body);
  ce->depth = saved;
  ce->nframes--;
  if (st != X_RETURN)
    return CE_NONE;
  ConstValue v = g.ret;
  if (rb == BT_BOOL ? v.kind != CONST_BOOL : (v.kind != CONST_INT || !fits(rb, v.i)))
    return CE_NONE;
  v.type = ce_type(a, id);
  return v;
}
