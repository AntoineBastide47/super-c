#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "consteval.h"
#include "types/hashmap.h"
#include "utils/errors.h"

#define CE_MAX_DEPTH 32 // expression + layout recursion cap (house style: fixed limit, loud failure)

// Compile-time function execution. A call whose
// arguments fold is RUN by the interpreter below: frames of locals, an object store for
// aggregates and heap blocks (element-wise, never byte-wise), place handles for references, and
// interception of the C heap primitives. Anything unmodeled (un-intercepted externs, unions,
// byte-level reinterpretation, budget blowups) bails to CONST_NONE and stays a runtime call.
#define CE_DEFAULT_STEPS (1u << 21) // interpreted statements + expressions per top-level evaluation
#define CE_DEFAULT_SLOTS (1u << 22) // object slots per top-level evaluation (~96 MiB of values)
#define CE_MAX_FRAMES 48            // call depth; also breaks const<->fn reference cycles
#define CE_MAX_LOCALS 96            // bindings per frame (params, lets, loop/pattern bindings)
#define CE_MAX_DEFERS 24            // pending `defer`s per frame
#define CE_MAX_OBJS (1u << 16)      // objects per top-level evaluation

typedef struct CeObj CeObj;
typedef struct CeCalls CeCalls; // the (fn, args) -> results memo (defined with CeVal below)
typedef struct {
    ModuleId m;
    NodeId cond;
} CePending;

struct ConstEval {
    const Package *pkg;
    ConstValue **vals; // [module][node] memo tables, allocated lazily per module
    size_t *caps;      // allocated length of each module's table
    size_t nmods;
    unsigned depth;   // shared recursion depth across expression eval and const-item chasing
    unsigned nframes; // live interpreter call frames
    uint32_t steps;   // interpreter work counter, reset per top-level evaluation
    uint32_t max_steps; // per-evaluation budgets (--const-eval-steps / --const-eval-memory)
    uint64_t max_slots;
    CeObj *objs;      // the object store (frames' environments, aggregates, heap blocks)
    uint32_t nobjs, cobjs;
    uint64_t live_slots;
    const char *trap;   // why the last top-level evaluation trapped (would panic at runtime / budget)
    CePending *pending; // static_asserts deferred until the whole package has type-checked
    size_t npending, cpending;
    CeCalls *calls; // Zig-style CTFE call memoization; lives for the whole compile
};

static const ConstValue CE_NONE = {0};

static uint64_t ce_mem_to_slots(uint64_t bytes); // defined with CeVal (slots are CeVal-sized)

ConstEval *consteval_new(const Package *pkg, const uint32_t max_steps, const uint64_t max_mem_bytes) {
  ConstEval *const ce = calloc(1, sizeof *ce);
  if (!ce)
    oom();
  ce->pkg = pkg;
  ce->nmods = pkg->count;
  ce->max_steps = max_steps ? max_steps : CE_DEFAULT_STEPS;
  ce->max_slots = max_mem_bytes ? ce_mem_to_slots(max_mem_bytes) : CE_DEFAULT_SLOTS;
  ce->vals = calloc(pkg->count ? pkg->count : 1, sizeof *ce->vals);
  ce->caps = calloc(pkg->count ? pkg->count : 1, sizeof *ce->caps);
  if (!ce->vals || !ce->caps)
    oom();
  return ce;
}

static void ce_objs_reset(ConstEval *ce);
static void ce_calls_free(CeCalls **calls);

void consteval_free(ConstEval **pce) {
  if (!pce || !*pce)
    return;
  ConstEval *const ce = *pce;
  for (size_t i = 0; i < ce->nmods; i++)
    free(ce->vals[i]);
  ce_objs_reset(ce);
  ce_calls_free(&ce->calls);
  free(ce->objs);
  free(ce->pending);
  free(ce->vals);
  free(ce->caps);
  free(ce);
  *pce = NULL;
}

const char *consteval_trap(const ConstEval *ce) {
  return ce ? ce->trap : NULL;
}

void consteval_defer_assert(ConstEval *ce, const ModuleId m, const NodeId cond) {
  if (!ce)
    return;
  if (ce->npending == ce->cpending) {
    ce->cpending = ce->cpending ? ce->cpending * 2 : 16;
    ce->pending = realloc(ce->pending, ce->cpending * sizeof *ce->pending);
    if (!ce->pending)
      oom();
  }
  ce->pending[ce->npending++] = (CePending){m, cond};
}

void consteval_flush_asserts(ConstEval *ce, const CeAssertErr err, void *ctx) {
  if (!ce)
    return;
  for (size_t i = 0; i < ce->npending; i++) {
    const ConstValue v = consteval_eval(ce, ce->pending[i].m, ce->pending[i].cond);
    if (v.kind == CONST_BOOL && !v.i)
      err(ctx, ce->pending[i].m, ce->pending[i].cond, NULL);
    else if (v.kind == CONST_NONE && ce->trap)
      err(ctx, ce->pending[i].m, ce->pending[i].cond, ce->trap);
  }
  ce->npending = 0;
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
  uint32_t end = sp.end; // a type suffix (`1u8`) is not digits; the checker already typed the node from it
  ast_numeric_suffix(src, sp.start, sp.end, &end);
  uint64_t v = 0;
  size_t i = sp.start;
  unsigned base = 10;
  if (sp.end - sp.start > 2 && src[i] == '0') {
    const uint8_t r = src[i + 1];
    if (r == 'x' || r == 'X') { base = 16; i += 2; }
    else if (r == 'b' || r == 'B') { base = 2; i += 2; }
    else if (r == 'o' || r == 'O') { base = 8; i += 2; }
  }
  for (; i < end; i++) {
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
    const bool tuple_member = d->as.aggregate.is_tuple; // a tuple struct's member IS its type node
    if (!tuple_member && f->kind != NODE_FIELD)
      continue;
    const TypeId ft = ce_type(a, tuple_member ? fids[i] : f->as.field.type);
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

#include <math.h>

// ================================================================================================
// The CTFE interpreter: CeVal values (scalars, floats, pointers, aggregates, function refs) over
// an object store (frame environments, structs/arrays/enums/tuples, heap blocks). Everything is
// ELEMENT-wise -- a slot holds one typed value; byte-level reinterpretation never folds. Every
// bail returns CV_NIL and the expression stays a runtime one; would-be runtime traps additionally
// record `ce->trap` so a required-const consumer (static_assert) can explain the failure.
// ================================================================================================

typedef enum { CV_NIL_K = 0, CV_INT, CV_BOOL, CV_FLOAT, CV_PTR, CV_AGG, CV_FN } CvKind;

typedef struct {
    uint8_t kind; // CvKind
    ModuleId tm;  // pool `type` is interned in (values cross module boundaries); informational
    TypeId type;
    union {
        int64_t i; // CV_INT / CV_BOOL (bits; unsigned reinterpreted)
        double f;  // CV_FLOAT (f32 values kept rounded to float precision)
        struct {
            uint32_t obj, off; // CV_PTR: slot address (obj 0 = null); CV_AGG: obj (off unused)
        } p;
        struct {
            ModuleId m;
            NodeId fn; // CV_FN: a NODE_FUNCTION or NODE_CLOSURE
        } fnv;
    } as;
} CeVal;

static const CeVal CV_NIL = {0};

static uint64_t ce_mem_to_slots(const uint64_t bytes) {
  const uint64_t slots = bytes / sizeof(CeVal);
  return slots ? slots : 1;
}

// Zig-style CTFE call memoization: a call with NO type substitutions whose arguments are all
// scalars is provably pure (no pointer in = no reachable caller state, no receiver), and when its
// results are all scalars too they reference no interpreter objects -- so (callee, arg bits) ->
// results holds for the WHOLE compile. This is what makes naive recursion (fib) linear in its
// distinct arguments instead of exponential. Failures/traps are never cached (a fresh evaluation
// gets a fresh budget and a later one may see newly-typed bodies).
#define CE_CALLS_MAX (1u << 16) // entries; past this, hits keep working but nothing new is added

typedef struct {
    ModuleId m;
    NodeId fn;
    uint8_t nargs;
    uint8_t kinds[8]; // CvKind per argument
    int64_t bits[8];  // the value bits (floats alias through the union)
} CeCallKey;

typedef struct {
    uint8_t nrets;
    CeVal rets[8]; // scalars only
} CeCallHit;

static inline uint64_t ce_callkey_hash(const CeCallKey k) {
  const uint8_t *const p = (const uint8_t *)&k;
  uint64_t h = 1469598103934665603ull;
  for (size_t i = 0; i < sizeof k; i++) {
    h ^= p[i];
    h *= 1099511628211ull;
  }
  return h;
}
static inline bool ce_callkey_eq(const CeCallKey a, const CeCallKey b) {
  return memcmp(&a, &b, sizeof a) == 0;
}
HM_DECLARE(CeCallKey, CeCallHit, CeCallMap)
HM_DEFINE(CeCallKey, CeCallHit, CeCallMap, ce_callkey_hash, ce_callkey_eq)

struct CeCalls {
    CeCallMap map;
};

static void ce_calls_free(CeCalls **calls) {
  if (!*calls)
    return;
  CeCallMap_deinit(&(*calls)->map);
  free(*calls);
  *calls = NULL;
}

static bool cv_is_scalar(const CeVal v) {
  return v.kind == CV_INT || v.kind == CV_BOOL || v.kind == CV_FLOAT;
}

// One store object. `dm`/`dn` name the aggregate decl (field lookup, method dispatch); heap blocks
// carry their byte size and element type (assigned by the first typed pointer cast).
struct CeObj {
    CeVal *slots;
    uint32_t len;
    uint8_t dead;    // freed heap block: any further access is a use-after-free trap
    uint8_t is_enum; // slots[0] = variant index, slots[1..] = the active variant's payload
    uint8_t heap;    // an intercepted-malloc block
    ModuleId dm;
    NodeId dn;
    uint8_t nargs; // concrete generic args of the aggregate instance (per-arg pools)
    ModuleId am[4];
    TypeId at[4];
    uint64_t bytes; // heap: allocated byte size
    ModuleId em;    // heap: element type; TYPE_NONE until the first cast to *mut T
    TypeId et;
    uint64_t esz; // heap: sizeof(element)
};

// The receiver identity a method dispatches on: an aggregate decl + concrete args, or a builtin.
typedef struct {
    ModuleId dm;
    NodeId dn; // NODE_NONE => builtin receiver
    BuiltinType b;
    uint8_t n;
    ModuleId am[4];
    TypeId at[4];
} CeRecv;

struct CeFrame {
    uint32_t env; // object holding this frame's locals (one slot each)
    struct {
        NodeId decl;
        uint32_t slot;
    } locals[CE_MAX_LOCALS];
    uint32_t n;
    CeVal rets[8];
    uint8_t nrets;
    uint8_t returned;
    uint8_t early; // a `?` early-return in flight: nil results unwind as X_RETURN, not X_BAIL
    // concrete type substitution: params_g[i] (a generic param decl owned by pmod) -> (am[i], at[i])
    ModuleId pmod;
    NodeId params_g[8];
    ModuleId am[8];
    TypeId at[8];
    uint8_t ng;
    NodeId defers[CE_MAX_DEFERS];
    uint8_t ndefers;
};

enum { X_OK, X_RETURN, X_BREAK, X_CONTINUE, X_BAIL }; // statement outcomes

typedef struct CeFrame CeFrame;

// A nil value normally poisons the whole fold -- unless a `?` set the frame's early-return, in
// which case the failure IS a return and must unwind as one.
static int xfail(const CeFrame *f) {
  return f && f->early ? X_RETURN : X_BAIL;
}

static void ce_trap(ConstEval *ce, const char *msg) {
  if (!ce->trap)
    ce->trap = msg; // first cause wins
}

static bool ce_tick(ConstEval *ce) {
  if (++ce->steps > ce->max_steps) {
    ce_trap(ce, "const-eval step budget exceeded");
    return false;
  }
  return true;
}

// --- object store -------------------------------------------------------------------------------

static void ce_objs_reset(ConstEval *ce) {
  for (uint32_t i = 0; i < ce->nobjs; i++)
    free(ce->objs[i].slots);
  ce->nobjs = 0;
  ce->live_slots = 0;
}

static CeObj *ce_obj(ConstEval *ce, const uint32_t id) {
  return id && id <= ce->nobjs ? &ce->objs[id - 1] : NULL;
}

// New object with `len` zeroed (CV_NIL = uninitialized) slots; 0 on budget exhaustion.
static uint32_t ce_obj_new(ConstEval *ce, const uint32_t len) {
  if (ce->nobjs >= CE_MAX_OBJS || ce->live_slots + len > ce->max_slots) {
    ce_trap(ce, "const-eval memory budget exceeded");
    return 0;
  }
  if (ce->nobjs == ce->cobjs) {
    ce->cobjs = ce->cobjs ? ce->cobjs * 2 : 128;
    ce->objs = realloc(ce->objs, ce->cobjs * sizeof *ce->objs);
    if (!ce->objs)
      oom();
  }
  CeObj *const o = &ce->objs[ce->nobjs];
  memset(o, 0, sizeof *o);
  if (len) {
    o->slots = calloc(len, sizeof *o->slots);
    if (!o->slots)
      oom();
  }
  o->len = len;
  ce->live_slots += len;
  return ++ce->nobjs;
}

// Resize an object's slot array (heap realloc, frame environments); keeps existing values.
static bool ce_obj_resize(ConstEval *ce, CeObj *o, const uint32_t len) {
  if (len > o->len && ce->live_slots + (len - o->len) > ce->max_slots) {
    ce_trap(ce, "const-eval memory budget exceeded");
    return false;
  }
  CeVal *const s = realloc(o->slots, (len ? len : 1) * sizeof *s);
  if (!s)
    oom();
  if (len > o->len)
    memset(s + o->len, 0, (len - o->len) * sizeof *s);
  ce->live_slots += len > o->len ? len - o->len : 0;
  o->slots = s;
  o->len = len;
  return true;
}

// --- type utilities -----------------------------------------------------------------------------

static bool ce_spans_eq(const ConstEval *ce, const ModuleId ma, const Span a, const ModuleId mb, const Span b) {
  const size_t la = a.end - a.start, lb = b.end - b.start;
  return la == lb && memcmp(ce_src(ce, ma) + a.start, ce_src(ce, mb) + b.start, la) == 0;
}

static bool ce_span_is(const ConstEval *ce, const ModuleId m, const Span s, const char *lit) {
  const size_t n = strlen(lit);
  return s.end - s.start == n && memcmp(ce_src(ce, m) + s.start, lit, n) == 0;
}

// Resolve (m, t) through the frame's substitution while it names a generic param. Frame
// substitutions are stored CONCRETE, so one hop resolves; the loop guard is paranoia.
static bool ce_rtype(const ConstEval *ce, const CeFrame *f, ModuleId m, TypeId t, ModuleId *om, TypeId *ot) {
  for (int guard = 0; guard < 8; guard++) {
    if (t == TYPE_NONE)
      return false;
    const Ty *const y = ast_type_at(ce_ast(ce, m), t);
    if (y->kind != TYPE_GENERIC) {
      *om = m;
      *ot = t;
      return true;
    }
    if (!f)
      return false;
    bool found = false;
    for (uint8_t i = 0; i < f->ng; i++)
      if (f->pmod == y->module && f->params_g[i] == y->as.decl) {
        m = f->am[i];
        t = f->at[i];
        found = true;
        break;
      }
    if (!found)
      return false;
  }
  return false;
}

static BuiltinType ce_builtin_of(const ConstEval *ce, const CeFrame *f, const ModuleId m, const TypeId t) {
  ModuleId rm;
  TypeId rt;
  if (!ce_rtype(ce, f, m, t, &rm, &rt))
    return BT_COUNT;
  return type_builtin(ce_ast(ce, rm), rt);
}

// A LayoutEnv chain over the frame's substitutions (one link per arg: the pools differ per arg).
static const LayoutEnv *ce_frame_lenv(const CeFrame *f, LayoutEnv envs[8]) {
  if (!f)
    return NULL;
  const LayoutEnv *parent = NULL;
  for (uint8_t i = 0; i < f->ng; i++) {
    envs[i] = (LayoutEnv){.parent = parent, .pmod = f->pmod, .params = &f->params_g[i], .argm = f->am[i], .n = 1};
    envs[i].args[0] = f->at[i];
    parent = &envs[i];
  }
  return parent;
}

static bool ce_layout_f(ConstEval *ce, const CeFrame *f, const ModuleId m, const TypeId t, uint64_t *size,
                        uint64_t *align) {
  LayoutEnv envs[8];
  return layout_of(ce, m, t, ce_frame_lenv(f, envs), 0, size, align);
}

// Structural cross-pool type equality.
static bool ce_teq(const ConstEval *ce, const ModuleId ma, const TypeId ta, const ModuleId mb, const TypeId tb) {
  if (ta == TYPE_NONE || tb == TYPE_NONE)
    return false;
  const Ty *const a = ast_type_at(ce_ast(ce, ma), ta);
  const Ty *const b = ast_type_at(ce_ast(ce, mb), tb);
  if (a->kind != b->kind)
    return false;
  switch (a->kind) {
    case TYPE_BUILTIN:
      return a->as.builtin == b->as.builtin;
    case TYPE_POINTER:
    case TYPE_REFERENCE:
      return a->qualifier == b->qualifier && ce_teq(ce, ma, a->as.elem, mb, b->as.elem);
    case TYPE_ARRAY:
      return a->as.arr.len == b->as.arr.len && ce_teq(ce, ma, a->as.elem, mb, b->as.elem);
    case TYPE_STRUCT:
    case TYPE_ENUM:
    case TYPE_GENERIC:
    case TYPE_OPAQUE:
      return a->module == b->module && a->as.decl == b->as.decl;
    case TYPE_INSTANCE: {
      const TyInstance *const ia = ast_instance(ce_ast(ce, ma), a->as.inst);
      const TyInstance *const ib = ast_instance(ce_ast(ce, mb), b->as.inst);
      if (ia->module != ib->module || ia->decl != ib->decl || ia->n != ib->n)
        return false;
      for (uint8_t i = 0; i < ia->n; i++)
        if (!ce_teq(ce, ma, ia->args[i], mb, ib->args[i]))
          return false;
      return true;
    }
    default:
      return false;
  }
}

// Peel reference AND pointer layers, resolving generics along the way.
static bool ce_strip_refptr(const ConstEval *ce, const CeFrame *f, ModuleId m, TypeId t, ModuleId *om, TypeId *ot) {
  for (int guard = 0; guard < 8; guard++) {
    if (!ce_rtype(ce, f, m, t, &m, &t))
      return false;
    const Ty *const y = ast_type_at(ce_ast(ce, m), t);
    if (y->kind != TYPE_REFERENCE && y->kind != TYPE_POINTER) {
      *om = m;
      *ot = t;
      return true;
    }
    t = y->as.elem;
  }
  return false;
}

// The Asts are mutable in reality (the loader owns them; ConstEval only holds a const view).
// Deep substitution must INTERN rebuilt types, exactly like the typechecker and codegen do.
static Ast *ce_mut_ast(const ConstEval *ce, const ModuleId m) {
  return (Ast *)ce_ast(ce, m);
}

// Substitute every generic mentioned in (m, t) through the frame, re-interning the result into
// m's pool so the outcome is a single-pool, fully concrete TypeId. TYPE_NONE = an unbound generic
// remains. (One-hop ce_rtype cannot reach generics EMBEDDED in instance args like `Option<&V>`.)
static TypeId ce_subst_deep(const ConstEval *ce, const CeFrame *f, const ModuleId m, const TypeId t, const int depth) {
  if (t == TYPE_NONE || depth > CE_MAX_DEPTH)
    return TYPE_NONE;
  Ast *const a = ce_mut_ast(ce, m);
  const Ty y = *ast_type_at(a, t); // by value: interning below may realloc the pool
  switch (y.kind) {
    case TYPE_GENERIC: {
      if (!f)
        return TYPE_NONE;
      for (uint8_t i = 0; i < f->ng; i++)
        if (f->pmod == y.module && f->params_g[i] == y.as.decl)
          return f->am[i] == m ? f->at[i] : ast_reintern(a, ce_ast(ce, f->am[i]), f->at[i]);
      return TYPE_NONE;
    }
    case TYPE_POINTER:
    case TYPE_REFERENCE:
    case TYPE_ARRAY: {
      const TypeId e = ce_subst_deep(ce, f, m, y.as.elem, depth + 1);
      if (e == TYPE_NONE)
        return TYPE_NONE;
      if (e == y.as.elem)
        return t;
      Ty ny = y;
      ny.as.elem = e; // ARRAY: `arr.len` aliases past `elem`, preserved by the struct copy
      if (y.kind == TYPE_ARRAY)
        ny.as.arr.len = y.as.arr.len;
      return ast_intern_type(a, ny);
    }
    case TYPE_INSTANCE: {
      const TyInstance it = *ast_instance(a, y.as.inst);
      TypeId na[4];
      bool changed = false;
      for (uint8_t i = 0; i < it.n; i++) {
        na[i] = ce_subst_deep(ce, f, m, it.args[i], depth + 1);
        if (na[i] == TYPE_NONE)
          return TYPE_NONE;
        changed |= na[i] != it.args[i];
      }
      return changed ? ast_intern_instance(a, it.module, it.decl, na, it.n) : t;
    }
    default:
      return t; // builtins / nominal types carry no generics of their own
  }
}

// The receiver identity of (m, t): aggregate decl + concrete args, or a builtin.
static bool ce_recv_of(const ConstEval *ce, const CeFrame *f, ModuleId m, TypeId t, CeRecv *out) {
  memset(out, 0, sizeof *out);
  out->b = BT_COUNT;
  if (!ce_rtype(ce, f, m, t, &m, &t))
    return false;
  const Ty *const y = ast_type_at(ce_ast(ce, m), t);
  switch (y->kind) {
    case TYPE_BUILTIN:
      out->dn = NODE_NONE;
      out->b = y->as.builtin;
      return true;
    case TYPE_STRUCT:
    case TYPE_ENUM:
      out->dm = y->module;
      out->dn = y->as.decl;
      return true;
    case TYPE_INSTANCE: {
      const TyInstance it = *ast_instance(ce_ast(ce, m), y->as.inst); // by value: deep-subst interns
      out->dm = it.module;
      out->dn = it.decl;
      out->n = it.n;
      for (uint8_t i = 0; i < it.n; i++) {
        out->am[i] = m;
        out->at[i] = ce_subst_deep(ce, f, m, it.args[i], 0);
        if (out->at[i] == TYPE_NONE || !ast_type_concrete(ce_ast(ce, m), out->at[i]))
          return false;
      }
      return true;
    }
    default:
      return false;
  }
}

// --- decl lookups -------------------------------------------------------------------------------

// Count of NODE_FIELD members; fields map to slots in declaration order.
static uint32_t ce_field_count(const ConstEval *ce, const ModuleId dm, const NodeId dn) {
  const Ast *const a = ce_ast(ce, dm);
  const Node *const d = ast_at_const(a, dn);
  const NodeId *const ids = ast_list(a, d->as.aggregate.members);
  uint32_t n = 0;
  for (uint32_t i = 0; i < d->as.aggregate.members.len; i++)
    n += ast_at_const(a, ids[i])->kind == NODE_FIELD;
  return n;
}

// Slot index of field `name` (source in module nm); also outputs the field decl node.
static int ce_field_index(const ConstEval *ce, const ModuleId dm, const NodeId dn, const ModuleId nm, const Span name,
                          NodeId *field_out) {
  const Ast *const a = ce_ast(ce, dm);
  const Node *const d = ast_at_const(a, dn);
  const NodeId *const ids = ast_list(a, d->as.aggregate.members);
  int idx = 0;
  for (uint32_t i = 0; i < d->as.aggregate.members.len; i++) {
    const Node *const fnode = ast_at_const(a, ids[i]);
    if (fnode->kind != NODE_FIELD)
      continue;
    if (ce_spans_eq(ce, dm, ast_at_const(a, fnode->as.field.name)->as.name.text, nm, name)) {
      if (field_out)
        *field_out = ids[i];
      return idx;
    }
    idx++;
  }
  return -1;
}

// Does this enum carry any payload (tagged union at runtime) or is it a plain C enum?
static bool ce_enum_tagged(const ConstEval *ce, const ModuleId dm, const NodeId dn) {
  const Ast *const a = ce_ast(ce, dm);
  const Node *const d = ast_at_const(a, dn);
  const NodeId *const ids = ast_list(a, d->as.aggregate.members);
  for (uint32_t i = 0; i < d->as.aggregate.members.len; i++)
    if (ast_at_const(a, ids[i])->as.variant.payload.len > 0)
      return true;
  return false;
}

// Position of variant (vm, vd) within its enum; also outputs the enum decl. -1 if not found.
static int ce_variant_pos(const ConstEval *ce, const ModuleId vm, const NodeId vd, NodeId *enum_out) {
  const Ast *const a = ce_ast(ce, vm);
  const NodeList items = ast_at_const(a, a->root)->as.program.items;
  const NodeId *const iids = ast_list(a, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const it = ast_at_const(a, iids[i]);
    if (it->kind != NODE_ENUM)
      continue;
    const NodeId *const mids = ast_list(a, it->as.aggregate.members);
    for (uint32_t k = 0; k < it->as.aggregate.members.len; k++)
      if (mids[k] == vd) {
        if (enum_out)
          *enum_out = iids[i];
        return (int)k;
      }
  }
  return -1;
}

// Index of the variant named `lit` within enum (dm, dn); -1 when absent.
static int ce_variant_named(const ConstEval *ce, const ModuleId dm, const NodeId dn, const char *lit) {
  const Ast *const a = ce_ast(ce, dm);
  const Node *const d = ast_at_const(a, dn);
  const NodeId *const mids = ast_list(a, d->as.aggregate.members);
  for (uint32_t i = 0; i < d->as.aggregate.members.len; i++) {
    const Node *const v = ast_at_const(a, mids[i]);
    if (ce_span_is(ce, dm, ast_at_const(a, v->as.variant.name)->as.name.text, lit))
      return (int)i;
  }
  return -1;
}

// The TypeId of plain nominal decl (dm, dn) in ITS OWN pool (interned when the module checked);
// TYPE_NONE if the pool holds none. Used to bind an interface default body's `Self`.
static TypeId ce_pool_find_type(const ConstEval *ce, const ModuleId dm, const NodeId dn) {
  const Ast *const a = ce_ast(ce, dm);
  for (TypeId t = 1; t < a->type_pool.len; t++) {
    const Ty *const y = ast_type_at(a, t);
    if ((y->kind == TYPE_STRUCT || y->kind == TYPE_ENUM) && y->module == dm && y->as.decl == dn)
      return t;
  }
  return TYPE_NONE;
}

// The item (extend or interface) containing method (fm, fn): 0 = free fn, 1 = extend, 2 = interface.
static int ce_container_of(const ConstEval *ce, const ModuleId fm, const NodeId fn, NodeId *out) {
  const Ast *const a = ce_ast(ce, fm);
  const NodeList items = ast_at_const(a, a->root)->as.program.items;
  const NodeId *const iids = ast_list(a, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const it = ast_at_const(a, iids[i]);
    NodeList ms;
    if (it->kind == NODE_EXTEND)
      ms = it->as.extend_def.items;
    else if (it->kind == NODE_INTERFACE)
      ms = it->as.interface_def.items;
    else
      continue;
    const NodeId *const mids = ast_list(a, ms);
    for (uint32_t k = 0; k < ms.len; k++)
      if (mids[k] == fn) {
        if (out)
          *out = iids[i];
        return it->kind == NODE_EXTEND ? 1 : 2;
      }
  }
  return 0;
}

// Find method `name`/`lit` on the receiver: scan extends whose target resolves to the receiver's
// decl (or builtin) in the decl's module, then the calling scope's module, then (builtins) all.
static DefId ce_find_method(const ConstEval *ce, const CeRecv *r, const ModuleId scope, const ModuleId nm,
                            const Span name, const char *lit, NodeId *extend_out) {
  const ModuleId first = r->dn != NODE_NONE ? r->dm : scope;
  for (size_t s = 0; s < ce->nmods + 2; s++) {
    ModuleId mm;
    if (s == 0)
      mm = first;
    else if (s == 1)
      mm = scope;
    else if (r->dn == NODE_NONE)
      mm = (ModuleId)(s - 2); // builtin receivers: their extends live in the prelude, scan all
    else
      break;
    if (s == 1 && mm == first)
      continue;
    const Ast *const a = ce_ast(ce, mm);
    if (!a || !a->nodes.len)
      continue;
    const NodeList items = ast_at_const(a, a->root)->as.program.items;
    const NodeId *const iids = ast_list(a, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const it = ast_at_const(a, iids[i]);
      if (it->kind != NODE_EXTEND || it->as.extend_def.target_type == NODE_NONE)
        continue;
      if (r->dn != NODE_NONE) {
        const DefId tg = ast_resolution_def(a, it->as.extend_def.target_type);
        if (tg.module != r->dm || tg.node != r->dn)
          continue;
      } else {
        const TypeId tt = ce_type(a, it->as.extend_def.target_type);
        if (tt == TYPE_NONE || ast_type_at(a, tt)->kind != TYPE_BUILTIN || ast_type_at(a, tt)->as.builtin != r->b)
          continue;
      }
      const NodeId *const mids = ast_list(a, it->as.extend_def.items);
      for (uint32_t k = 0; k < it->as.extend_def.items.len; k++) {
        const Node *const mn = ast_at_const(a, mids[k]);
        if (mn->kind != NODE_FUNCTION)
          continue;
        const Span mname = ast_at_const(a, mn->as.function.name)->as.name.text;
        const bool hit = lit ? ce_span_is(ce, mm, mname, lit) : ce_spans_eq(ce, mm, mname, nm, name);
        if (hit) {
          if (extend_out)
            *extend_out = iids[i];
          return (DefId){mm, mids[k]};
        }
      }
    }
  }
  return (DefId){0, NODE_NONE};
}

// --- frames and values --------------------------------------------------------------------------

static CeVal ce_clone(ConstEval *ce, const CeVal v, const int depth);

static int ce_local_find(const CeFrame *f, const NodeId decl) {
  for (uint32_t i = f->n; i-- > 0;)
    if (f->locals[i].decl == decl)
      return (int)i;
  return -1;
}

// The env slot of a binding, creating it on first use. NULL on budget/limit failures.
static CeVal *ce_bind_slot(ConstEval *ce, CeFrame *f, const NodeId decl) {
  const int i = ce_local_find(f, decl);
  CeObj *const env = ce_obj(ce, f->env);
  if (!env)
    return NULL;
  if (i >= 0)
    return &env->slots[f->locals[i].slot];
  if (f->n >= CE_MAX_LOCALS)
    return NULL;
  if (!ce_obj_resize(ce, env, env->len + 1))
    return NULL;
  f->locals[f->n].decl = decl;
  f->locals[f->n].slot = env->len - 1;
  f->n++;
  return &env->slots[env->len - 1];
}

static bool ce_bind(ConstEval *ce, CeFrame *f, const NodeId decl, const CeVal v) {
  CeVal *const s = ce_bind_slot(ce, f, decl);
  if (!s)
    return false;
  *s = ce_clone(ce, v, 0);
  return v.kind == CV_NIL_K || s->kind != CV_NIL_K;
}

// Deep copy: aggregates get fresh objects (pointer members stay shared, exactly like a C struct
// copy); scalars/pointers/fn refs copy by value.
static CeVal ce_clone(ConstEval *ce, const CeVal v, const int depth) {
  if (v.kind != CV_AGG || depth > CE_MAX_DEPTH)
    return v.kind == CV_AGG && depth > CE_MAX_DEPTH ? CV_NIL : v;
  const CeObj *const src = ce_obj(ce, v.as.p.obj);
  if (!src || src->dead)
    return CV_NIL;
  const uint32_t id = ce_obj_new(ce, src->len);
  if (!id)
    return CV_NIL;
  const CeObj s = *ce_obj(ce, v.as.p.obj); // re-read: ce_obj_new may move the array
  CeObj *const dst = ce_obj(ce, id);
  CeVal *const slots = dst->slots;
  *dst = s;
  dst->slots = slots;
  dst->len = s.len;
  for (uint32_t i = 0; i < s.len; i++) {
    dst->slots[i] = ce_clone(ce, s.slots[i], depth + 1);
    if (s.slots[i].kind != CV_NIL_K && dst->slots[i].kind == CV_NIL_K)
      return CV_NIL;
  }
  CeVal out = v;
  out.as.p.obj = id;
  return out;
}

static bool ce_loadp(ConstEval *ce, const CeVal p, CeVal *out) {
  if (p.kind != CV_PTR)
    return false;
  if (p.as.p.obj == 0) {
    ce_trap(ce, "null dereference");
    return false;
  }
  const CeObj *const o = ce_obj(ce, p.as.p.obj);
  if (!o)
    return false;
  if (o->dead) {
    ce_trap(ce, "use after free");
    return false;
  }
  if (p.as.p.off >= o->len) {
    ce_trap(ce, "out-of-bounds access");
    return false;
  }
  *out = o->slots[p.as.p.off];
  return out->kind != CV_NIL_K; // reading uninitialized storage never folds
}

static bool ce_storep(ConstEval *ce, const CeVal p, const CeVal v) {
  if (p.kind != CV_PTR || v.kind == CV_NIL_K)
    return false;
  if (p.as.p.obj == 0) {
    ce_trap(ce, "null dereference");
    return false;
  }
  const CeVal cv = ce_clone(ce, v, 0);
  if (cv.kind == CV_NIL_K)
    return false;
  CeObj *const o = ce_obj(ce, p.as.p.obj);
  if (!o)
    return false;
  if (o->dead) {
    ce_trap(ce, "use after free");
    return false;
  }
  if (p.as.p.off >= o->len) {
    ce_trap(ce, "out-of-bounds access");
    return false;
  }
  o->slots[p.as.p.off] = cv;
  return true;
}

// Materialize a value into a fresh single-slot object, yielding its address (method receivers on
// temporaries, operator operands).
static bool ce_temp_place(ConstEval *ce, const CeVal v, CeVal *out) {
  const uint32_t id = ce_obj_new(ce, 1);
  if (!id || v.kind == CV_NIL_K)
    return false;
  ce_obj(ce, id)->slots[0] = v;
  *out = (CeVal){.kind = CV_PTR, .tm = 0, .type = TYPE_NONE, .as.p = {id, 0}};
  return true;
}

// Zero value of a resolved concrete type (C zero-initialization for partial array literals).
static CeVal ce_zero(ConstEval *ce, const ModuleId m, const TypeId t, const int depth);
static CeVal ce_zero(ConstEval *ce, const ModuleId m, const TypeId t, const int depth) {
  if (depth > CE_MAX_DEPTH || t == TYPE_NONE)
    return CV_NIL;
  const Ty *const y = ast_type_at(ce_ast(ce, m), t);
  switch (y->kind) {
    case TYPE_BUILTIN:
      switch (y->as.builtin) {
        case BT_BOOL: return (CeVal){.kind = CV_BOOL, .tm = m, .type = t, .as.i = 0};
        case BT_F32: case BT_F64: return (CeVal){.kind = CV_FLOAT, .tm = m, .type = t, .as.f = 0.0};
        case BT_C32: case BT_C64: case BT_VALIST: case BT_VOID: return CV_NIL;
        default: return (CeVal){.kind = CV_INT, .tm = m, .type = t, .as.i = 0};
      }
    case TYPE_POINTER:
      return (CeVal){.kind = CV_PTR, .tm = m, .type = t, .as.p = {0, 0}};
    case TYPE_ARRAY: {
      if (y->as.arr.len == 0)
        return CV_NIL;
      const uint32_t id = ce_obj_new(ce, y->as.arr.len);
      if (!id)
        return CV_NIL;
      const CeVal ez = ce_zero(ce, m, y->as.elem, depth + 1);
      if (ez.kind == CV_NIL_K)
        return CV_NIL;
      CeObj *const o = ce_obj(ce, id);
      for (uint32_t i = 0; i < o->len; i++)
        o->slots[i] = ce_clone(ce, ez, depth + 1);
      return (CeVal){.kind = CV_AGG, .tm = m, .type = t, .as.p = {id, 0}};
    }
    default:
      return CV_NIL; // zero structs/enums: not needed by any modeled construct
  }
}

// --- forward declarations -----------------------------------------------------------------------

static CeVal ev(ConstEval *ce, CeFrame *f, ModuleId m, NodeId id);
static CeVal ev_in(ConstEval *ce, CeFrame *f, ModuleId m, NodeId id);
static CeVal ev_rval(ConstEval *ce, CeFrame *f, ModuleId m, NodeId id);
static bool ev_place(ConstEval *ce, CeFrame *f, ModuleId m, NodeId id, CeVal *out);
static int exec_stmt(ConstEval *ce, CeFrame *f, ModuleId m, NodeId id);
static int exec_expr_stmt(ConstEval *ce, CeFrame *f, ModuleId m, NodeId id);
static int exec_match(ConstEval *ce, CeFrame *f, ModuleId m, const Node *n, CeVal *out);
static bool ce_call(ConstEval *ce, CeFrame *f, ModuleId m, NodeId id, CeVal rets[8], uint8_t *nrets);
static bool ce_invoke(ConstEval *ce, ModuleId fm, NodeId fnode, NodeId extend_node, const CeRecv *recv,
                      const ModuleId *monom, const TypeId *monot, uint8_t nmono, const CeVal *args, uint32_t nargs,
                      ModuleId self_pm, NodeId self_decl, ModuleId self_am, TypeId self_at, CeVal rets[8],
                      uint8_t *nrets);

// Dispatch a named method on a receiver identity with pre-evaluated args (operators, iterators,
// index). Returns false when the method is missing or the invocation bails.
static bool ce_dispatch(ConstEval *ce, const CeRecv *r, const ModuleId scope, const char *lit, const CeVal *args,
                        const uint32_t nargs, CeVal *out) {
  NodeId extend = NODE_NONE;
  const DefId md = ce_find_method(ce, r, scope, 0, (Span){0}, lit, &extend);
  if (md.node == NODE_NONE)
    return false;
  CeVal rets[8];
  uint8_t nrets = 0;
  if (!ce_invoke(ce, md.module, md.node, extend, r, NULL, NULL, 0, args, nargs, 0, NODE_NONE, 0, TYPE_NONE, rets,
                 &nrets))
    return false;
  *out = nrets ? rets[0] : CV_NIL;
  return true;
}

// --- scalar operations --------------------------------------------------------------------------

// One integer binary op. `rt`/`b` describe the RESULT, `ob` the operands' shared type. Unsigned
// arithmetic of width >= 32 wraps exactly like the emitted C (u8/u16 promote to int in C, so their
// overflow refuses to fold); signed overflow refuses (the runtime traps) and records why.
static CeVal ce_int_op(ConstEval *ce, const TokenType op, const CeVal l, const CeVal r, const ModuleId tm,
                       const TypeId rt, const BuiltinType b, const BuiltinType ob) {
  const bool uns = ob != BT_COUNT && bt_unsigned(ob);
  switch (op) {
    case EqualEqual: return (CeVal){.kind = CV_BOOL, .tm = tm, .type = rt, .as.i = l.as.i == r.as.i};
    case BangEqual: return (CeVal){.kind = CV_BOOL, .tm = tm, .type = rt, .as.i = l.as.i != r.as.i};
    case LessThan:
      return (CeVal){.kind = CV_BOOL, .tm = tm, .type = rt, .as.i = uns ? (uint64_t)l.as.i < (uint64_t)r.as.i : l.as.i < r.as.i};
    case LessThanEqual:
      return (CeVal){.kind = CV_BOOL, .tm = tm, .type = rt, .as.i = uns ? (uint64_t)l.as.i <= (uint64_t)r.as.i : l.as.i <= r.as.i};
    case GreaterThan:
      return (CeVal){.kind = CV_BOOL, .tm = tm, .type = rt, .as.i = uns ? (uint64_t)l.as.i > (uint64_t)r.as.i : l.as.i > r.as.i};
    case GreaterThanEqual:
      return (CeVal){.kind = CV_BOOL, .tm = tm, .type = rt, .as.i = uns ? (uint64_t)l.as.i >= (uint64_t)r.as.i : l.as.i >= r.as.i};
    default:
      break;
  }
  const int bits = ob == BT_COUNT ? 64 : bt_bits(ob);
  int64_t v;
  if (uns && bits >= 32) { // C unsigned arithmetic: mod 2^bits, no trap
    const uint64_t ul = (uint64_t)l.as.i, ur = (uint64_t)r.as.i;
    uint64_t u;
    switch (op) {
      case Plus: u = ul + ur; break;
      case Minus: u = ul - ur; break;
      case Star: u = ul * ur; break;
      case Slash:
        if (ur == 0) { ce_trap(ce, "division by zero"); return CV_NIL; }
        u = ul / ur;
        break;
      case Percent:
        if (ur == 0) { ce_trap(ce, "division by zero"); return CV_NIL; }
        u = ul % ur;
        break;
      case Ampersand: u = ul & ur; break;
      case Pipe: u = ul | ur; break;
      case Caret: u = ul ^ ur; break;
      case LeftShift:
        if (r.as.i < 0 || r.as.i >= bits) return CV_NIL;
        u = ul << r.as.i;
        break;
      case RightShift:
        if (r.as.i < 0 || r.as.i >= bits) return CV_NIL;
        u = ul >> r.as.i;
        break;
      default:
        return CV_NIL;
    }
    v = wrap_to(ob, (int64_t)u);
    return (CeVal){.kind = CV_INT, .tm = tm, .type = rt, .as.i = v};
  }
  switch (op) {
    case Plus:
      if (__builtin_add_overflow(l.as.i, r.as.i, &v)) { ce_trap(ce, "arithmetic overflow"); return CV_NIL; }
      break;
    case Minus:
      if (__builtin_sub_overflow(l.as.i, r.as.i, &v)) { ce_trap(ce, "arithmetic overflow"); return CV_NIL; }
      break;
    case Star:
      if (__builtin_mul_overflow(l.as.i, r.as.i, &v)) { ce_trap(ce, "arithmetic overflow"); return CV_NIL; }
      break;
    case Slash:
      if (r.as.i == 0) { ce_trap(ce, "division by zero"); return CV_NIL; }
      if (l.as.i == INT64_MIN && r.as.i == -1) { ce_trap(ce, "arithmetic overflow"); return CV_NIL; }
      v = l.as.i / r.as.i;
      break;
    case Percent:
      if (r.as.i == 0) { ce_trap(ce, "division by zero"); return CV_NIL; }
      if (l.as.i == INT64_MIN && r.as.i == -1) { ce_trap(ce, "arithmetic overflow"); return CV_NIL; }
      v = l.as.i % r.as.i;
      break;
    case Ampersand: v = l.as.i & r.as.i; break;
    case Pipe: v = l.as.i | r.as.i; break;
    case Caret: v = l.as.i ^ r.as.i; break;
    case LeftShift:
      if (r.as.i < 0 || r.as.i >= bits) return CV_NIL;
      v = (int64_t)((uint64_t)l.as.i << r.as.i);
      break;
    case RightShift:
      if (r.as.i < 0 || r.as.i >= bits) return CV_NIL;
      v = uns ? (int64_t)((uint64_t)l.as.i >> r.as.i) : l.as.i >> r.as.i;
      break;
    default:
      return CV_NIL;
  }
  if (b != BT_COUNT && !fits(b, v)) {
    if (bt_signed(b))
      ce_trap(ce, "arithmetic overflow");
    return CV_NIL; // would not match the runtime value -- stay runtime
  }
  return (CeVal){.kind = CV_INT, .tm = tm, .type = rt, .as.i = v};
}

// IEEE arithmetic folds unconditionally (inf/nan are the runtime's values too); an f32 result is
// rounded to float precision so compile time matches what the target computes.
static CeVal ce_float_op(const TokenType op, const CeVal l, const CeVal r, const ModuleId tm, const TypeId rt,
                         const BuiltinType b) {
  switch (op) {
    case EqualEqual: return (CeVal){.kind = CV_BOOL, .tm = tm, .type = rt, .as.i = l.as.f == r.as.f};
    case BangEqual: return (CeVal){.kind = CV_BOOL, .tm = tm, .type = rt, .as.i = l.as.f != r.as.f};
    case LessThan: return (CeVal){.kind = CV_BOOL, .tm = tm, .type = rt, .as.i = l.as.f < r.as.f};
    case LessThanEqual: return (CeVal){.kind = CV_BOOL, .tm = tm, .type = rt, .as.i = l.as.f <= r.as.f};
    case GreaterThan: return (CeVal){.kind = CV_BOOL, .tm = tm, .type = rt, .as.i = l.as.f > r.as.f};
    case GreaterThanEqual: return (CeVal){.kind = CV_BOOL, .tm = tm, .type = rt, .as.i = l.as.f >= r.as.f};
    default: break;
  }
  double v;
  switch (op) {
    case Plus: v = l.as.f + r.as.f; break;
    case Minus: v = l.as.f - r.as.f; break;
    case Star: v = l.as.f * r.as.f; break;
    case Slash: v = l.as.f / r.as.f; break;
    default: return CV_NIL;
  }
  if (b == BT_F32)
    v = (double)(float)v;
  return (CeVal){.kind = CV_FLOAT, .tm = tm, .type = rt, .as.f = v};
}

static CeVal cv_scalar_of(const ConstValue v, const ModuleId m) {
  switch (v.kind) {
    case CONST_INT: return (CeVal){.kind = CV_INT, .tm = m, .type = v.type, .as.i = v.i};
    case CONST_BOOL: return (CeVal){.kind = CV_BOOL, .tm = m, .type = v.type, .as.i = v.i};
    default: return CV_NIL;
  }
}

static CeVal eval_float_literal(const Ast *a, const uint8_t *src, const Node *n, const NodeId id, const ModuleId m) {
  const Span sp = n->as.literal.raw;
  char buf[64];
  size_t k = 0;
  for (size_t i = sp.start; i < sp.end && k + 1 < sizeof buf; i++)
    if (src[i] != '_')
      buf[k++] = (char)src[i];
  buf[k] = '\0';
  double v = strtod(buf, NULL);
  const BuiltinType b = type_builtin(a, ce_type(a, id));
  if (b == BT_F32)
    v = (double)(float)v;
  else if (b != BT_F64 && b != BT_COUNT)
    return CV_NIL;
  return (CeVal){.kind = CV_FLOAT, .tm = m, .type = ce_type(a, id), .as.f = v};
}

// A string literal: a read-only u8 block + a `str { ptr, len }` struct object over it.
static CeVal eval_str_literal(ConstEval *ce, const CeFrame *f, const ModuleId m, const Node *n, const NodeId id) {
  const Ast *const a = ce_ast(ce, m);
  const uint8_t *const src = ce_src(ce, m);
  Span sp = n->as.literal.raw;
  const bool raw = n->as.literal.token_type == RawStringLiteral;
  size_t i = sp.start, hashes = 0;
  while (i < sp.end && src[i] != '"')
    hashes += src[i] == '#', i++; // past r / b prefixes and the raw `#` run
  if (i >= sp.end)
    return CV_NIL;
  i++; // past the opening quote
  const size_t end = sp.end - 1 - (raw ? hashes : 0); // the closing quote (raw: minus the trailing `#` run)
  uint8_t bytes[4096];
  uint32_t nb = 0;
  while (i < end) {
    if (nb >= sizeof bytes)
      return CV_NIL;
    uint8_t c = src[i++];
    if (!raw && c == '\\' && i < end) {
      const uint8_t e = src[i++];
      switch (e) {
        case 'n': c = '\n'; break;
        case 't': c = '\t'; break;
        case 'r': c = '\r'; break;
        case '0': c = 0; break;
        case '\\': c = '\\'; break;
        case '"': c = '"'; break;
        case '\'': c = '\''; break;
        default: return CV_NIL; // \x/\u: not needed by any const consumer yet
      }
    }
    bytes[nb++] = c;
  }
  CeRecv r;
  if (!ce_recv_of(ce, f, m, ce_type(a, id), &r) || r.dn == NODE_NONE)
    return CV_NIL; // `str` is a prelude struct { ptr, len }
  const uint32_t block = ce_obj_new(ce, nb);
  if (!block && nb)
    return CV_NIL;
  if (nb) {
    CeObj *const bo = ce_obj(ce, block);
    bo->heap = 1;
    bo->bytes = nb;
    bo->em = 0;
    bo->et = ast_builtin(BT_U8);
    bo->esz = 1;
    for (uint32_t k = 0; k < nb; k++)
      bo->slots[k] = (CeVal){.kind = CV_INT, .tm = 0, .type = ast_builtin(BT_U8), .as.i = bytes[k]};
  }
  const uint32_t so = ce_obj_new(ce, ce_field_count(ce, r.dm, r.dn));
  if (!so)
    return CV_NIL;
  CeObj *const s = ce_obj(ce, so);
  s->dm = r.dm;
  s->dn = r.dn;
  const int pi = ce_field_index(ce, r.dm, r.dn, r.dm, (Span){0}, NULL);
  (void)pi;
  int ptr_i = -1, len_i = -1;
  { // locate the ptr/len fields by name
    const Ast *const da = ce_ast(ce, r.dm);
    const Node *const d = ast_at_const(da, r.dn);
    const NodeId *const ids = ast_list(da, d->as.aggregate.members);
    int idx = 0;
    for (uint32_t k = 0; k < d->as.aggregate.members.len; k++) {
      const Node *const fd = ast_at_const(da, ids[k]);
      if (fd->kind != NODE_FIELD)
        continue;
      const Span fn = ast_at_const(da, fd->as.field.name)->as.name.text;
      if (ce_span_is(ce, r.dm, fn, "ptr"))
        ptr_i = idx;
      else if (ce_span_is(ce, r.dm, fn, "len"))
        len_i = idx;
      idx++;
    }
  }
  if (ptr_i < 0 || len_i < 0)
    return CV_NIL;
  s->slots[ptr_i] = (CeVal){.kind = CV_PTR, .tm = 0, .type = TYPE_NONE, .as.p = {block, 0}};
  s->slots[len_i] = (CeVal){.kind = CV_INT, .tm = 0, .type = ast_builtin(BT_USIZE), .as.i = nb};
  return (CeVal){.kind = CV_AGG, .tm = m, .type = ce_type(a, id), .as.p = {so, 0}};
}

// --- expression evaluation ----------------------------------------------------------------------

// The prelude's `Range` struct decl (one module declares it).
static bool ce_range_decl(const ConstEval *ce, ModuleId *dm, NodeId *dn) {
  for (ModuleId mm = 0; mm < (ModuleId)ce->nmods; mm++) {
    const Ast *const a = ce_ast(ce, mm);
    if (!a || !a->nodes.len)
      continue;
    const NodeList items = ast_at_const(a, a->root)->as.program.items;
    const NodeId *const iids = ast_list(a, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const it = ast_at_const(a, iids[i]);
      if (it->kind == NODE_STRUCT && !it->as.aggregate.is_union &&
          ce_span_is(ce, mm, ast_at_const(a, it->as.aggregate.name)->as.name.text, "Range")) {
        *dm = mm;
        *dn = iids[i];
        return true;
      }
    }
  }
  return false;
}

// Build a `Range { start, end, inclusive }` value from a NODE_RANGE. The node is untyped in index
// position, so bounds evaluate in-frame first and fall back to the context-free path (literals).
static CeVal ce_range_obj(ConstEval *ce, CeFrame *f, const ModuleId m, const NodeId id) {
  const Node *const n = ast_at_const(ce_ast(ce, m), id);
  if (n->as.pattern_range.start == NODE_NONE || n->as.pattern_range.end == NODE_NONE)
    return CV_NIL; // open ranges get their bounds at the consuming site
  ModuleId dm;
  NodeId dn;
  if (!ce_range_decl(ce, &dm, &dn))
    return CV_NIL;
  CeVal sv = ev_in(ce, f, m, n->as.pattern_range.start);
  if (sv.kind == CV_NIL_K)
    sv = ev_in(ce, NULL, m, n->as.pattern_range.start);
  CeVal e = ev_in(ce, f, m, n->as.pattern_range.end);
  if (e.kind == CV_NIL_K)
    e = ev_in(ce, NULL, m, n->as.pattern_range.end);
  if (sv.kind == CV_PTR && ce_loadp(ce, sv, &sv) == false)
    return CV_NIL;
  if (e.kind == CV_PTR && ce_loadp(ce, e, &e) == false)
    return CV_NIL;
  if (sv.kind != CV_INT || e.kind != CV_INT)
    return CV_NIL;
  const uint32_t o = ce_obj_new(ce, ce_field_count(ce, dm, dn));
  if (!o)
    return CV_NIL;
  CeObj *const ro = ce_obj(ce, o);
  ro->dm = dm;
  ro->dn = dn;
  ro->nargs = 1;
  ro->am[0] = 0;
  ro->at[0] = ast_builtin(BT_USIZE);
  if (ro->len < 3)
    return CV_NIL;
  ro->slots[0] = sv; // Range { start, end, inclusive } in declaration order
  ro->slots[1] = e;
  ro->slots[2] = (CeVal){.kind = CV_BOOL, .tm = 0, .type = ast_builtin(BT_BOOL), .as.i = n->as.pattern_range.inclusive};
  return (CeVal){.kind = CV_AGG, .tm = m, .type = ce_type(ce_ast(ce, m), id), .as.p = {o, 0}};
}

static CeVal ev_in(ConstEval *ce, CeFrame *f, const ModuleId m, const NodeId id) {
  if (id == NODE_NONE || !ce_tick(ce) || ce->depth > CE_MAX_DEPTH)
    return CV_NIL;
  ce->depth++;
  const CeVal v = ev(ce, f, m, id);
  ce->depth--;
  return v;
}

// ev + auto-deref: an expression statically typed as a REFERENCE loads through to its value.
static CeVal ev_rval(ConstEval *ce, CeFrame *f, const ModuleId m, const NodeId id) {
  CeVal v = ev_in(ce, f, m, id);
  if (v.kind != CV_PTR)
    return v;
  ModuleId tm = m;
  TypeId t = ce_type(ce_ast(ce, m), id);
  for (int guard = 0; guard < 4 && v.kind == CV_PTR; guard++) {
    if (!ce_rtype(ce, f, tm, t, &tm, &t))
      return v;
    const Ty *const y = ast_type_at(ce_ast(ce, tm), t);
    if (y->kind != TYPE_REFERENCE)
      return v;
    if (!ce_loadp(ce, v, &v))
      return CV_NIL;
    t = y->as.elem;
  }
  return v;
}

// Coerce a value to a wanted (already resolved) type at a binding boundary: loads a reference
// when a value is wanted, keeps pointers for pointer/reference targets, and pads a short array
// literal (designators leave gaps; C zero-fills to the declared length). NIL = does not fit.
static CeVal ce_coerce(ConstEval *ce, const CeVal v, const ModuleId wm, const TypeId wt) {
  if (v.kind == CV_NIL_K)
    return CV_NIL;
  if (wt == TYPE_NONE)
    return v;
  const Ty *const y = ast_type_at(ce_ast(ce, wm), wt);
  if (y->kind == TYPE_REFERENCE || y->kind == TYPE_POINTER || y->kind == TYPE_FUNCTION)
    return v.kind == CV_PTR || v.kind == CV_FN ? v : CV_NIL;
  if (v.kind == CV_PTR) { // a reference where a value is wanted: load through
    CeVal out;
    if (!ce_loadp(ce, v, &out))
      return CV_NIL;
    return ce_coerce(ce, out, wm, wt);
  }
  if (y->kind == TYPE_INSTANCE && v.kind == CV_AGG && v.type != TYPE_NONE &&
      ast_type_at(ce_ast(ce, v.tm), v.type)->kind == TYPE_ARRAY) {
    // array -> slice coercion at a binding boundary: build the `Slice<T>`/`SliceMut<T>` fat pointer
    const TyInstance *const it = ast_instance(ce_ast(ce, wm), y->as.inst);
    const Ast *const da = ce_ast(ce, it->module);
    const Span dn = ast_at_const(da, ast_at_const(da, it->decl)->as.aggregate.name)->as.name.text;
    if (!ce_span_is(ce, it->module, dn, "Slice") && !ce_span_is(ce, it->module, dn, "SliceMut"))
      return CV_NIL;
    if (!ce_obj(ce, v.as.p.obj))
      return CV_NIL;
    const uint32_t so = ce_obj_new(ce, 2);
    if (!so)
      return CV_NIL;
    CeObj *const sl = ce_obj(ce, so);
    sl->dm = it->module;
    sl->dn = it->decl;
    sl->slots[0] = (CeVal){.kind = CV_PTR, .tm = 0, .type = TYPE_NONE, .as.p = {v.as.p.obj, 0}}; // ptr
    sl->slots[1] = (CeVal){.kind = CV_INT, .tm = 0, .type = ast_builtin(BT_USIZE), .as.i = ce_obj(ce, v.as.p.obj)->len}; // len
    return (CeVal){.kind = CV_AGG, .tm = wm, .type = wt, .as.p = {so, 0}};
  }
  if (y->kind == TYPE_ARRAY && v.kind == CV_AGG && y->as.arr.len) {
    CeObj *const o = ce_obj(ce, v.as.p.obj);
    if (o && o->len < y->as.arr.len) {
      const uint32_t from = o->len;
      ModuleId em;
      TypeId et;
      if (!ce_rtype(ce, NULL, wm, y->as.elem, &em, &et))
        return CV_NIL;
      const CeVal z = ce_zero(ce, em, et, 0);
      if (z.kind == CV_NIL_K || !ce_obj_resize(ce, ce_obj(ce, v.as.p.obj), y->as.arr.len))
        return CV_NIL;
      CeObj *const o2 = ce_obj(ce, v.as.p.obj);
      for (uint32_t i = from; i < o2->len; i++)
        o2->slots[i] = ce_clone(ce, z, 0);
    }
  }
  return v;
}

// The object behind an aggregate-valued expression (arrays, structs), through references.
static bool ce_base_obj(ConstEval *ce, CeFrame *f, const ModuleId m, const NodeId id, uint32_t *out) {
  CeVal v = ev_in(ce, f, m, id);
  for (int guard = 0; guard < 4 && v.kind == CV_PTR; guard++)
    if (!ce_loadp(ce, v, &v))
      return false;
  if (v.kind != CV_AGG)
    return false;
  *out = v.as.p.obj;
  return true;
}

static bool ev_place(ConstEval *ce, CeFrame *f, const ModuleId m, NodeId id, CeVal *out) {
  const Ast *const a = ce_ast(ce, m);
  const Node *n = ast_at_const(a, id);
  while (n->kind == NODE_UNARY && (n->as.unary.op == Move || n->as.unary.op == Unsafe)) {
    id = n->as.unary.operand;
    n = ast_at_const(a, id);
  }
  switch (n->kind) {
    case NODE_IDENTIFIER: {
      if (!f)
        return false;
      DefId d = ast_resolution_def(a, id);
      if (d.node == NODE_NONE)
        d = (DefId){m, ast_resolution(a, id)};
      if (d.module != m)
        return false; // module-level consts are not assignable places
      const int i = ce_local_find(f, d.node);
      if (i < 0)
        return false;
      *out = (CeVal){.kind = CV_PTR, .tm = 0, .type = TYPE_NONE, .as.p = {f->env, f->locals[i].slot}};
      return true;
    }
    case NODE_MEMBER: {
      if (n->as.member.path)
        return false;
      const Span mname = ast_at_const(a, n->as.member.member)->as.name.text;
      uint32_t obj;
      if (!ce_base_obj(ce, f, m, n->as.member.object, &obj))
        return false;
      const CeObj *const o = ce_obj(ce, obj);
      if (!o || o->dead)
        return false;
      uint32_t idx;
      const uint8_t c0 = ce_src(ce, m)[mname.start];
      if (c0 >= '0' && c0 <= '9') { // tuple access `.N` -> field N
        idx = (uint32_t)(c0 - '0');
      } else {
        if (o->dn == NODE_NONE)
          return false;
        const int fi = ce_field_index(ce, o->dm, o->dn, m, mname, NULL);
        if (fi < 0)
          return false;
        idx = (uint32_t)fi;
      }
      if (idx >= o->len)
        return false;
      *out = (CeVal){.kind = CV_PTR, .tm = 0, .type = TYPE_NONE, .as.p = {obj, idx}};
      return true;
    }
    case NODE_INDEX: {
      ModuleId bm = m;
      TypeId bt = ce_type(a, n->as.index.object);
      // peel reference layers only: a raw pointer indexes its block, an array indexes its object
      for (int guard = 0; guard < 4; guard++) {
        if (!ce_rtype(ce, f, bm, bt, &bm, &bt))
          return false;
        const Ty *const y = ast_type_at(ce_ast(ce, bm), bt);
        if (y->kind != TYPE_REFERENCE)
          break;
        bt = y->as.elem;
      }
      const Ty *const y = ast_type_at(ce_ast(ce, bm), bt);
      const CeVal iv = ev_rval(ce, f, m, n->as.index.index);
      if (iv.kind != CV_INT)
        return false;
      if (y->kind == TYPE_POINTER) {
        const CeVal p = ev_rval(ce, f, m, n->as.index.object);
        if (p.kind != CV_PTR)
          return false;
        *out = p;
        out->as.p.off += (uint32_t)iv.as.i;
        return true;
      }
      if (y->kind == TYPE_ARRAY) {
        uint32_t obj;
        if (!ce_base_obj(ce, f, m, n->as.index.object, &obj))
          return false;
        const CeObj *const o = ce_obj(ce, obj);
        if (!o || iv.as.i < 0 || (uint64_t)iv.as.i >= o->len) {
          ce_trap(ce, "out-of-bounds access");
          return false;
        }
        *out = (CeVal){.kind = CV_PTR, .tm = 0, .type = TYPE_NONE, .as.p = {obj, (uint32_t)iv.as.i}};
        return true;
      }
      if (y->kind == TYPE_STRUCT || y->kind == TYPE_INSTANCE) { // user IndexMut -> &mut T place
        CeRecv r;
        if (!ce_recv_of(ce, f, bm, bt, &r))
          return false;
        CeVal recv;
        if (!ev_place(ce, f, m, n->as.index.object, &recv))
          return false;
        const CeVal args[2] = {recv, iv};
        CeVal res;
        if (!ce_dispatch(ce, &r, m, "index_mut", args, 2, &res) || res.kind != CV_PTR)
          return false;
        *out = res;
        return true;
      }
      return false;
    }
    case NODE_UNARY:
      if (n->as.unary.op == Star) { // *p = ...
        const CeVal p = ev_in(ce, f, m, n->as.unary.operand);
        if (p.kind != CV_PTR)
          return false;
        *out = p;
        return true;
      }
      return false;
    default:
      return false;
  }
}

static CeVal ev(ConstEval *ce, CeFrame *f, const ModuleId m, const NodeId id) {
  const Ast *const a = ce_ast(ce, m);
  if (!a)
    return CV_NIL;
  // Inside a frame every expression must be TYPED: width/signedness comes from the checked types,
  // and an un-checked body (a call folded before the checker reached the callee) must stay runtime.
  const Node *const n = ast_at_const(a, id);
  if (f && ce_type(a, id) == TYPE_NONE &&
      !(n->kind == NODE_LITERAL && n->as.literal.token_type == Null)) // `null` adapts: never typed
    return CV_NIL;
  const uint8_t *const src = ce_src(ce, m);
  switch (n->kind) {
    case NODE_LITERAL:
      switch (n->as.literal.token_type) {
        case IntegerLiteral:
          return cv_scalar_of(eval_int_literal(a, src, n, id), m);
        case CharacterLiteral:
        case ByteCharacterLiteral:
          return cv_scalar_of(eval_char_literal(a, src, n, id), m);
        case FloatLiteral:
          return eval_float_literal(a, src, n, id, m);
        case True:
          return (CeVal){.kind = CV_BOOL, .tm = m, .type = ce_type(a, id), .as.i = 1};
        case False:
          return (CeVal){.kind = CV_BOOL, .tm = m, .type = ce_type(a, id), .as.i = 0};
        case Null:
          return (CeVal){.kind = CV_PTR, .tm = m, .type = ce_type(a, id), .as.p = {0, 0}};
        case StringLiteral:
        case RawStringLiteral:
          return eval_str_literal(ce, f, m, n, id);
        default:
          return CV_NIL;
      }
    case NODE_IDENTIFIER: { // a frame local, a `const` item, or a function used as a value
      DefId d = ast_resolution_def(a, id);
      if (d.node == NODE_NONE)
        d = (DefId){m, ast_resolution(a, id)};
      if (d.node == NODE_NONE || d.module >= ce->nmods)
        return CV_NIL;
      if (f && d.module == m) {
        const int i = ce_local_find(f, d.node);
        if (i >= 0) {
          const CeObj *const env = ce_obj(ce, f->env);
          if (!env || f->locals[i].slot >= env->len)
            return CV_NIL;
          CeVal v = env->slots[f->locals[i].slot];
          if (v.kind == CV_NIL_K)
            return CV_NIL; // declared but unassigned on this path
          if (v.kind == CV_INT || v.kind == CV_BOOL || v.kind == CV_FLOAT) {
            v.tm = m;
            v.type = ce_type(a, id);
          }
          return v;
        }
      }
      const Node *const dn = ast_at_const(ce_ast(ce, d.module), d.node);
      if (dn->kind == NODE_FUNCTION)
        return (CeVal){.kind = CV_FN, .tm = m, .type = ce_type(a, id), .as.fnv = {d.module, d.node}};
      if (dn->kind != NODE_CONST || dn->as.const_def.value == NODE_NONE || dn->as.const_def.is_static_mut)
        return CV_NIL; // a `static mut` global changes at runtime: reading it never folds
      CeVal v = ev_in(ce, NULL, d.module, dn->as.const_def.value);
      if (v.kind == CV_INT || v.kind == CV_BOOL || v.kind == CV_FLOAT) {
        v.tm = m;
        v.type = ce_type(a, id);
      }
      return v;
    }
    case NODE_MEMBER: {
      if (n->as.member.path) { // Enum::Variant / mod::CONST / a path value
        DefId d = ast_resolution_def(a, id);
        if (d.node == NODE_NONE)
          d = ast_resolution_def(a, n->as.member.member);
        if (d.node == NODE_NONE || d.module >= ce->nmods)
          return CV_NIL;
        const Node *const dn = ast_at_const(ce_ast(ce, d.module), d.node);
        if (dn->kind == NODE_CONST && dn->as.const_def.value != NODE_NONE && !dn->as.const_def.is_static_mut) {
          CeVal v = ev_in(ce, NULL, d.module, dn->as.const_def.value);
          if (v.kind == CV_INT || v.kind == CV_BOOL || v.kind == CV_FLOAT) {
            v.tm = m;
            v.type = ce_type(a, id);
          }
          return v;
        }
        if (dn->kind == NODE_FUNCTION)
          return (CeVal){.kind = CV_FN, .tm = m, .type = ce_type(a, id), .as.fnv = {d.module, d.node}};
        if (dn->kind != NODE_VARIANT)
          return CV_NIL;
        NodeId edecl = NODE_NONE;
        const int pos = ce_variant_pos(ce, d.module, d.node, &edecl);
        if (pos < 0)
          return CV_NIL;
        if (!ce_enum_tagged(ce, d.module, edecl)) { // a plain C enum: its discriminant
          CeVal v = cv_scalar_of(variant_value(ce, d.module, d.node), m);
          v.type = ce_type(a, id);
          return v;
        }
        if (dn->as.variant.payload.len > 0)
          return CV_NIL; // a payload variant used as a value must be CALLED
        const uint32_t o = ce_obj_new(ce, 1);
        if (!o)
          return CV_NIL;
        CeObj *const eo = ce_obj(ce, o);
        eo->is_enum = 1;
        eo->dm = d.module;
        eo->dn = edecl;
        eo->slots[0] = (CeVal){.kind = CV_INT, .tm = 0, .type = TYPE_NONE, .as.i = pos};
        return (CeVal){.kind = CV_AGG, .tm = m, .type = ce_type(a, id), .as.p = {o, 0}};
      }
      // a value member: field read (with auto-deref through references/pointers)
      const Span mname = ast_at_const(a, n->as.member.member)->as.name.text;
      uint32_t obj;
      if (!ce_base_obj(ce, f, m, n->as.member.object, &obj))
        return CV_NIL;
      const CeObj *const o = ce_obj(ce, obj);
      if (!o || o->dead)
        return CV_NIL;
      uint32_t idx;
      const uint8_t c0 = src[mname.start];
      if (c0 >= '0' && c0 <= '9') {
        idx = (uint32_t)(c0 - '0');
      } else {
        if (o->dn == NODE_NONE)
          return CV_NIL;
        const int fi = ce_field_index(ce, o->dm, o->dn, m, mname, NULL);
        if (fi < 0)
          return CV_NIL;
        idx = (uint32_t)fi;
      }
      if (idx >= o->len || o->slots[idx].kind == CV_NIL_K)
        return CV_NIL;
      return o->slots[idx];
    }
    case NODE_UNARY: {
      const TokenType op = n->as.unary.op;
      if (op == Move || op == Unsafe)
        return ev_in(ce, f, m, n->as.unary.operand);
      if (op == Ampersand) { // &x / &mut x
        CeVal p;
        if (ev_place(ce, f, m, n->as.unary.operand, &p)) {
          p.tm = m;
          p.type = ce_type(a, id);
          return p;
        }
        const CeVal v = ev_in(ce, f, m, n->as.unary.operand); // a temporary: materialize
        CeVal out;
        if (v.kind == CV_NIL_K || !ce_temp_place(ce, v, &out))
          return CV_NIL;
        out.tm = m;
        out.type = ce_type(a, id);
        return out;
      }
      if (op == Star) { // *p: evaluate WITHOUT the reference auto-load (that load IS this deref)
        const CeVal p = ev_in(ce, f, m, n->as.unary.operand);
        CeVal out;
        if (p.kind != CV_PTR || !ce_loadp(ce, p, &out))
          return CV_NIL;
        return out;
      }
      if (op == Question) { // `expr?`: unwrap Some/Ok, or early-return the None/Err through defers
        if (!f)
          return CV_NIL;
        const CeVal v = ev_rval(ce, f, m, n->as.unary.operand);
        if (v.kind != CV_AGG)
          return CV_NIL;
        const CeObj *const o = ce_obj(ce, v.as.p.obj);
        if (!o || !o->is_enum)
          return CV_NIL;
        int okv = ce_variant_named(ce, o->dm, o->dn, "Some");
        if (okv < 0)
          okv = ce_variant_named(ce, o->dm, o->dn, "Ok");
        if (okv < 0)
          return CV_NIL;
        if (o->slots[0].as.i == okv) {
          if (o->len < 2 || o->slots[1].kind == CV_NIL_K)
            return CV_NIL;
          return o->slots[1];
        }
        // the fail value carries through unchanged (same enum decl, same tag, same error payload);
        // block-scope defers replay as the X_RETURN unwinds, exactly like the emitted C
        f->rets[0] = v;
        f->nrets = 1;
        f->returned = 1;
        f->early = 1;
        return CV_NIL;
      }
      const CeVal o = ev_rval(ce, f, m, n->as.unary.operand);
      if (o.kind == CV_NIL_K)
        return CV_NIL;
      const BuiltinType b = ce_builtin_of(ce, f, m, ce_type(a, id));
      switch (op) {
        case Minus: {
          if (o.kind == CV_FLOAT) {
            double v = -o.as.f;
            if (b == BT_F32)
              v = (double)(float)v;
            return (CeVal){.kind = CV_FLOAT, .tm = m, .type = ce_type(a, id), .as.f = v};
          }
          if (o.kind != CV_INT || o.as.i == INT64_MIN)
            return CV_NIL;
          const int64_t r = -o.as.i;
          if (b != BT_COUNT && !fits(b, r))
            return CV_NIL;
          return (CeVal){.kind = CV_INT, .tm = m, .type = ce_type(a, id), .as.i = r};
        }
        case Tilde:
          if (o.kind != CV_INT)
            return CV_NIL;
          return (CeVal){.kind = CV_INT, .tm = m, .type = ce_type(a, id), .as.i = wrap_to(b == BT_COUNT ? BT_I64 : b, ~o.as.i)};
        case Bang:
          if (o.kind != CV_BOOL)
            return CV_NIL;
          return (CeVal){.kind = CV_BOOL, .tm = m, .type = ce_type(a, id), .as.i = !o.as.i};
        default:
          return CV_NIL;
      }
    }
    case NODE_CAST: {
      const CeVal o = ev_rval(ce, f, m, n->as.cast.expression);
      if (o.kind == CV_NIL_K)
        return CV_NIL;
      ModuleId tm2;
      TypeId t2;
      if (!ce_rtype(ce, f, m, ce_type(a, id), &tm2, &t2))
        return CV_NIL;
      const Ty *const y = ast_type_at(ce_ast(ce, tm2), t2);
      if (y->kind == TYPE_POINTER) {
        if (o.kind != CV_PTR)
          return CV_NIL;
        CeVal v = o;
        v.tm = m;
        v.type = ce_type(a, id);
        ModuleId em;
        TypeId et;
        if (!ce_rtype(ce, f, tm2, y->as.elem, &em, &et))
          return CV_NIL;
        if (type_builtin(ce_ast(ce, em), et) == BT_VOID)
          return v; // pointer erasure keeps the handle
        CeObj *const blk = ce_obj(ce, o.as.p.obj);
        if (!blk)
          return v; // null: retype freely
        if (blk->heap && blk->et == TYPE_NONE && o.as.p.off == 0) {
          uint64_t sz, al; // the first typed view sizes the block's slots
          if (!ce_layout_f(ce, f, em, et, &sz, &al) || sz == 0 || blk->bytes % sz)
            return CV_NIL;
          if (!ce_obj_resize(ce, blk, (uint32_t)(blk->bytes / sz)))
            return CV_NIL;
          blk->em = em;
          blk->et = et;
          blk->esz = sz;
          return v;
        }
        if (blk->et != TYPE_NONE && !ce_teq(ce, blk->em, blk->et, em, et))
          return CV_NIL; // byte-level reinterpretation of a typed block: not modeled
        return v;
      }
      const BuiltinType b = y->kind == TYPE_BUILTIN ? y->as.builtin : BT_COUNT;
      if (b == BT_COUNT || b == BT_C32 || b == BT_C64 || b == BT_BOOL || b == BT_VALIST || b == BT_VOID)
        return CV_NIL;
      if (b == BT_F32 || b == BT_F64) {
        double v;
        if (o.kind == CV_FLOAT)
          v = o.as.f;
        else if (o.kind == CV_INT) {
          const BuiltinType ob = ce_builtin_of(ce, f, m, ce_type(a, n->as.cast.expression));
          v = ob != BT_COUNT && bt_unsigned(ob) ? (double)(uint64_t)o.as.i : (double)o.as.i;
        } else
          return CV_NIL;
        if (b == BT_F32)
          v = (double)(float)v;
        return (CeVal){.kind = CV_FLOAT, .tm = m, .type = ce_type(a, id), .as.f = v};
      }
      // integer target
      if (o.kind == CV_FLOAT) { // trunc toward zero; out-of-range is UB in C -> refuse
        if (!isfinite(o.as.f))
          return CV_NIL;
        const double t = trunc(o.as.f);
        if (t < -9.3e18 || t > 1.8e19)
          return CV_NIL;
        const int64_t iv = bt_unsigned(b) ? (int64_t)(uint64_t)t : (int64_t)t;
        if (!fits(b, iv) && bt_bits(b) < 64)
          return CV_NIL;
        return (CeVal){.kind = CV_INT, .tm = m, .type = ce_type(a, id), .as.i = wrap_to(b, iv)};
      }
      if (o.kind == CV_BOOL || o.kind == CV_INT)
        return (CeVal){.kind = CV_INT, .tm = m, .type = ce_type(a, id), .as.i = wrap_to(b, o.as.i)};
      return CV_NIL;
    }
    case NODE_SIZEOF:
    case NODE_ALIGNOF: {
      uint64_t size, align;
      const TypeId ty = ce_type(a, n->as.single.value);
      if (!ce_layout_f(ce, f, m, ty, &size, &align))
        return CV_NIL;
      return (CeVal){.kind = CV_INT, .tm = m, .type = ce_type(a, id), .as.i = (int64_t)(n->kind == NODE_SIZEOF ? size : align)};
    }
    case NODE_BINARY: {
      const TokenType op = n->as.binary.op;
      // operator overloading: a struct/instance left operand dispatches to its method
      ModuleId lm;
      TypeId lt;
      if (ce_strip_refptr(ce, f, m, ce_type(a, n->as.binary.left), &lm, &lt)) {
        const Ty *const ly = ast_type_at(ce_ast(ce, lm), lt);
        if (ly->kind == TYPE_STRUCT || ly->kind == TYPE_INSTANCE) {
          const char *mn = NULL;
          switch (op) {
            case Plus: mn = "add"; break;
            case Minus: mn = "sub"; break;
            case Star: mn = "mul"; break;
            case Slash: mn = "div"; break;
            case Percent: mn = "rem"; break;
            case EqualEqual: case BangEqual: mn = "eq"; break;
            case LessThan: case LessThanEqual: case GreaterThan: case GreaterThanEqual: mn = "cmp"; break;
            default: break;
          }
          if (mn) {
            CeRecv r;
            if (!ce_recv_of(ce, f, lm, lt, &r))
              return CV_NIL;
            CeVal lhs;
            if (!ev_place(ce, f, m, n->as.binary.left, &lhs)) {
              const CeVal lv = ev_in(ce, f, m, n->as.binary.left);
              if (lv.kind == CV_NIL_K || !ce_temp_place(ce, lv, &lhs))
                return CV_NIL;
            }
            CeVal rhs;
            if (!ev_place(ce, f, m, n->as.binary.right, &rhs)) {
              const CeVal rv = ev_rval(ce, f, m, n->as.binary.right);
              if (rv.kind == CV_NIL_K || !ce_temp_place(ce, rv, &rhs))
                return CV_NIL;
            }
            const CeVal args[2] = {lhs, rhs};
            CeVal res;
            if (!ce_dispatch(ce, &r, m, mn, args, 2, &res))
              return CV_NIL;
            const TypeId rt = ce_type(a, id);
            if (op == EqualEqual || op == BangEqual) {
              if (res.kind != CV_BOOL)
                return CV_NIL;
              res.as.i = op == BangEqual ? !res.as.i : res.as.i;
              res.tm = m;
              res.type = rt;
              return res;
            }
            if (mn[0] == 'c') { // cmp -> i32, compare against 0
              if (res.kind != CV_INT)
                return CV_NIL;
              int64_t c = res.as.i;
              int64_t v = op == LessThan ? c < 0 : op == LessThanEqual ? c <= 0 : op == GreaterThan ? c > 0 : c >= 0;
              return (CeVal){.kind = CV_BOOL, .tm = m, .type = rt, .as.i = v};
            }
            return res;
          }
        }
      }
      const CeVal l = ev_rval(ce, f, m, n->as.binary.left);
      if (l.kind == CV_NIL_K)
        return CV_NIL;
      // short-circuit forms still require BOTH sides const (side effects can't fold away)
      const CeVal r = ev_rval(ce, f, m, n->as.binary.right);
      if (r.kind == CV_NIL_K)
        return CV_NIL;
      const TypeId rt = ce_type(a, id);
      if (l.kind == CV_PTR || r.kind == CV_PTR) {
        if (op == EqualEqual || op == BangEqual) {
          if (l.kind != CV_PTR || r.kind != CV_PTR)
            return CV_NIL;
          const bool eq = l.as.p.obj == r.as.p.obj && l.as.p.off == r.as.p.off;
          return (CeVal){.kind = CV_BOOL, .tm = m, .type = rt, .as.i = op == EqualEqual ? eq : !eq};
        }
        if ((op == Plus || op == Minus) && l.kind == CV_PTR && r.kind == CV_INT) {
          CeVal v = l;
          v.tm = m;
          v.type = rt;
          v.as.p.off = op == Plus ? v.as.p.off + (uint32_t)r.as.i : v.as.p.off - (uint32_t)r.as.i;
          return v;
        }
        if (op == Plus && r.kind == CV_PTR && l.kind == CV_INT) {
          CeVal v = r;
          v.tm = m;
          v.type = rt;
          v.as.p.off += (uint32_t)l.as.i;
          return v;
        }
        return CV_NIL;
      }
      if (l.kind == CV_BOOL && r.kind == CV_BOOL) {
        switch (op) {
          case AmpersandAmpersand: return (CeVal){.kind = CV_BOOL, .tm = m, .type = rt, .as.i = l.as.i && r.as.i};
          case PipePipe: return (CeVal){.kind = CV_BOOL, .tm = m, .type = rt, .as.i = l.as.i || r.as.i};
          case EqualEqual: return (CeVal){.kind = CV_BOOL, .tm = m, .type = rt, .as.i = l.as.i == r.as.i};
          case BangEqual: return (CeVal){.kind = CV_BOOL, .tm = m, .type = rt, .as.i = l.as.i != r.as.i};
          default: return CV_NIL;
        }
      }
      if (l.kind == CV_FLOAT && r.kind == CV_FLOAT)
        return ce_float_op(op, l, r, m, rt, ce_builtin_of(ce, f, m, rt));
      if (l.kind != CV_INT || r.kind != CV_INT)
        return CV_NIL;
      return ce_int_op(ce, op, l, r, m, rt, ce_builtin_of(ce, f, m, rt),
                       ce_builtin_of(ce, f, m, ce_type(a, n->as.binary.left)));
    }
    case NODE_CALL: {
      CeVal rets[8];
      uint8_t nrets = 0;
      // Exactly ONE return value can be an expression value: collapsing a multi-return call to its
      // first value here would silently drop the rest (tuple-lets consume all of them in exec_stmt).
      if (!ce_call(ce, f, m, id, rets, &nrets) || nrets != 1)
        return CV_NIL;
      return rets[0];
    }
    case NODE_MATCH: {
      if (!f)
        return CV_NIL; // pattern bindings need a frame
      CeVal out = CV_NIL;
      return exec_match(ce, f, m, n, &out) == X_OK ? out : CV_NIL;
    }
    case NODE_BLOCK: { // a value block: `{ ..; e; }` yields `e` (the checker's block-value rule)
      if (!f || n->as.block.statements.len == 0)
        return CV_NIL;
      const NodeId *const ids = ast_list(a, n->as.block.statements);
      const uint8_t dbase = f->ndefers;
      CeVal out = CV_NIL;
      bool ok = true;
      for (uint32_t i = 0; ok && i + 1 < n->as.block.statements.len; i++)
        ok = exec_stmt(ce, f, m, ids[i]) == X_OK;
      if (ok) {
        const Node *const last = ast_at_const(a, ids[n->as.block.statements.len - 1]);
        if (last->kind == NODE_EXPRESSION_STATEMENT &&
            ast_at_const(a, last->as.single.value)->kind != NODE_ASSIGNMENT)
          out = ev_in(ce, f, m, last->as.single.value);
      }
      for (uint32_t i = f->ndefers; i-- > dbase;) { // scope exit runs this block's defers (LIFO)
        const Node *const dv = ast_at_const(a, f->defers[i]);
        if ((dv->kind == NODE_BLOCK ? exec_stmt(ce, f, m, f->defers[i]) : exec_expr_stmt(ce, f, m, f->defers[i])) != X_OK)
          out = CV_NIL;
      }
      f->ndefers = dbase;
      return out;
    }
    case NODE_IF: { // `if` as a value: the taken branch's block value
      if (!f)
        return CV_NIL;
      const CeVal c = ev_rval(ce, f, m, n->as.if_stmt.condition);
      if (c.kind != CV_BOOL)
        return CV_NIL;
      return ev_in(ce, f, m, c.as.i ? n->as.if_stmt.then_branch : n->as.if_stmt.else_branch);
    }
    case NODE_INDEX: {
      ModuleId bm;
      TypeId bt;
      { // peel reference layers of the object's static type
        bm = m;
        bt = ce_type(a, n->as.index.object);
        for (int guard = 0; guard < 4; guard++) {
          if (!ce_rtype(ce, f, bm, bt, &bm, &bt))
            return CV_NIL;
          const Ty *const y = ast_type_at(ce_ast(ce, bm), bt);
          if (y->kind != TYPE_REFERENCE)
            break;
          bt = y->as.elem;
        }
      }
      const Ty *const y = ast_type_at(ce_ast(ce, bm), bt);
      if (y->kind == TYPE_STRUCT || y->kind == TYPE_INSTANCE) { // user Index -> &T, loaded
        CeRecv r;
        if (!ce_recv_of(ce, f, bm, bt, &r))
          return CV_NIL;
        CeVal recv;
        if (!ev_place(ce, f, m, n->as.index.object, &recv)) {
          const CeVal rv = ev_in(ce, f, m, n->as.index.object);
          if (rv.kind == CV_NIL_K || !ce_temp_place(ce, rv, &recv))
            return CV_NIL;
        }
        CeVal iv;
        if (ast_at_const(a, n->as.index.index)->kind == NODE_RANGE) {
          // `x[a..b]` slicing: the checker leaves the range node untyped here, so build the
          // prelude Range value directly and dispatch index_range
          iv = ce_range_obj(ce, f, m, n->as.index.index);
          if (iv.kind != CV_AGG)
            return CV_NIL;
          const CeVal args[2] = {recv, iv};
          CeVal res;
          if (!ce_dispatch(ce, &r, m, "index_range", args, 2, &res) || res.kind != CV_AGG)
            return CV_NIL;
          return res;
        }
        iv = ev_rval(ce, f, m, n->as.index.index);
        if (iv.kind != CV_INT)
          return CV_NIL;
        const CeVal args[2] = {recv, iv};
        CeVal res, out;
        if (!ce_dispatch(ce, &r, m, "index", args, 2, &res) || res.kind != CV_PTR || !ce_loadp(ce, res, &out))
          return CV_NIL;
        return out;
      }
      CeVal p, out;
      if (!ev_place(ce, f, m, id, &p) || !ce_loadp(ce, p, &out))
        return CV_NIL;
      return out;
    }
    case NODE_STRUCT_INITIALIZER: {
      { // `Variant { field: v, .. }`: a struct-payload enum variant builds an enum object
        const NodeId tn = n->as.struct_initializer.type;
        DefId vd = ast_resolution_def(a, tn);
        if (vd.node == NODE_NONE)
          vd = (DefId){m, ast_resolution(a, tn)};
        if (vd.node != NODE_NONE && vd.module < ce->nmods &&
            ast_at_const(ce_ast(ce, vd.module), vd.node)->kind == NODE_ENUM &&
            ast_at_const(a, tn)->kind == NODE_TYPE_PATH && ast_at_const(a, tn)->as.type_path.parts.len >= 2) {
          // `Shape::Rect { .. }` resolves to the ENUM; the last path part names the variant
          const NodeId *const parts = ast_list(a, ast_at_const(a, tn)->as.type_path.parts);
          const Span vn = ast_at_const(a, parts[ast_at_const(a, tn)->as.type_path.parts.len - 1])->as.name.text;
          const Ast *const ea = ce_ast(ce, vd.module);
          const Node *const ed = ast_at_const(ea, vd.node);
          const NodeId *const mids = ast_list(ea, ed->as.aggregate.members);
          NodeId hit = NODE_NONE;
          for (uint32_t k = 0; k < ed->as.aggregate.members.len; k++)
            if (ce_spans_eq(ce, vd.module, ast_at_const(ea, ast_at_const(ea, mids[k])->as.variant.name)->as.name.text,
                            m, vn)) {
              hit = mids[k];
              break;
            }
          if (hit != NODE_NONE)
            vd.node = hit;
        }
        if (vd.node != NODE_NONE && vd.module < ce->nmods &&
            ast_at_const(ce_ast(ce, vd.module), vd.node)->kind == NODE_VARIANT) {
          NodeId edecl = NODE_NONE;
          const int pos = ce_variant_pos(ce, vd.module, vd.node, &edecl);
          const Node *const var = ast_at_const(ce_ast(ce, vd.module), vd.node);
          if (pos < 0 || !var->as.variant.struct_payload)
            return CV_NIL;
          const NodeId *const pfids = ast_list(ce_ast(ce, vd.module), var->as.variant.payload);
          const uint32_t o = ce_obj_new(ce, 1 + var->as.variant.payload.len);
          if (!o)
            return CV_NIL;
          {
            CeObj *const eo = ce_obj(ce, o);
            eo->is_enum = 1;
            eo->dm = vd.module;
            eo->dn = edecl;
            eo->slots[0] = (CeVal){.kind = CV_INT, .tm = 0, .type = TYPE_NONE, .as.i = pos};
          }
          const NodeId *const fids = ast_list(a, n->as.struct_initializer.fields);
          for (uint32_t i = 0; i < n->as.struct_initializer.fields.len; i++) {
            const Node *const fi = ast_at_const(a, fids[i]);
            if (fi->kind != NODE_FIELD_INITIALIZER || fi->as.field_initializer.name == NODE_NONE)
              return CV_NIL;
            int slot = -1;
            for (uint32_t j = 0; j < var->as.variant.payload.len; j++) {
              const Node *const fd = ast_at_const(ce_ast(ce, vd.module), pfids[j]);
              if (fd->kind == NODE_FIELD &&
                  ce_spans_eq(ce, vd.module, ast_at_const(ce_ast(ce, vd.module), fd->as.field.name)->as.name.text, m,
                              ast_at_const(a, fi->as.field_initializer.name)->as.name.text)) {
                slot = (int)j;
                break;
              }
            }
            const CeVal v = ev_rval(ce, f, m, fi->as.field_initializer.value);
            if (slot < 0 || v.kind == CV_NIL_K)
              return CV_NIL;
            CeObj *const eo = ce_obj(ce, o);
            eo->slots[1 + slot] = ce_clone(ce, v, 0);
            if (eo->slots[1 + slot].kind == CV_NIL_K)
              return CV_NIL;
          }
          return (CeVal){.kind = CV_AGG, .tm = m, .type = ce_type(a, id), .as.p = {o, 0}};
        }
      }
      CeRecv r;
      if (!ce_recv_of(ce, f, m, ce_type(a, id), &r) || r.dn == NODE_NONE)
        return CV_NIL;
      const Ast *const da = ce_ast(ce, r.dm);
      const Node *const d = ast_at_const(da, r.dn);
      if (d->kind != NODE_STRUCT || d->as.aggregate.is_union)
        return CV_NIL; // untagged unions overlap: not element-representable
      const uint32_t o = ce_obj_new(ce, ce_field_count(ce, r.dm, r.dn));
      if (!o)
        return CV_NIL;
      {
        CeObj *const so = ce_obj(ce, o);
        so->dm = r.dm;
        so->dn = r.dn;
        so->nargs = r.n;
        memcpy(so->am, r.am, sizeof so->am);
        memcpy(so->at, r.at, sizeof so->at);
      }
      const NodeId *const fids = ast_list(a, n->as.struct_initializer.fields);
      for (uint32_t i = 0; i < n->as.struct_initializer.fields.len; i++) {
        const Node *const fi = ast_at_const(a, fids[i]);
        if (fi->kind != NODE_FIELD_INITIALIZER || fi->as.field_initializer.name == NODE_NONE)
          return CV_NIL;
        const Span fname = ast_at_const(a, fi->as.field_initializer.name)->as.name.text;
        const int idx = ce_field_index(ce, r.dm, r.dn, m, fname, NULL);
        if (idx < 0)
          return CV_NIL;
        const CeVal v = ev_rval(ce, f, m, fi->as.field_initializer.value);
        if (v.kind == CV_NIL_K)
          return CV_NIL;
        CeObj *const so = ce_obj(ce, o);
        so->slots[idx] = ce_clone(ce, v, 0);
        if (so->slots[idx].kind == CV_NIL_K)
          return CV_NIL;
      }
      { // any remaining field must have a decl-side default
        const NodeId *const mids = ast_list(da, d->as.aggregate.members);
        int idx = 0;
        for (uint32_t k = 0; k < d->as.aggregate.members.len; k++) {
          const Node *const fd = ast_at_const(da, mids[k]);
          if (fd->kind != NODE_FIELD)
            continue;
          CeObj *so = ce_obj(ce, o);
          if (so->slots[idx].kind == CV_NIL_K) {
            if (fd->as.field.value == NODE_NONE)
              return CV_NIL;
            const CeVal v = ev_in(ce, NULL, r.dm, fd->as.field.value);
            if (v.kind == CV_NIL_K)
              return CV_NIL;
            so = ce_obj(ce, o);
            so->slots[idx] = ce_clone(ce, v, 0);
          }
          idx++;
        }
      }
      return (CeVal){.kind = CV_AGG, .tm = m, .type = ce_type(a, id), .as.p = {o, 0}};
    }
    case NODE_ARRAY_LITERAL: {
      ModuleId tm2;
      TypeId t2;
      if (!ce_rtype(ce, f, m, ce_type(a, id), &tm2, &t2))
        return CV_NIL;
      const Ty *const y = ast_type_at(ce_ast(ce, tm2), t2);
      if (y->kind != TYPE_ARRAY)
        return CV_NIL;
      const NodeId *const eids = ast_list(a, n->as.array_literal.elements);
      const uint32_t count = n->as.array_literal.elements.len;
      uint32_t len = y->as.arr.len;
      if (len == 0) { // the literal's own type is unsized: designators define the reach
        len = count;
        uint32_t cur = 0;
        for (uint32_t i = 0; i < count; i++) {
          const Node *const el = ast_at_const(a, eids[i]);
          if (el->kind == NODE_FIELD_INITIALIZER) {
            const CeVal iv = ev_in(ce, NULL, m, el->as.field_initializer.name);
            if (iv.kind != CV_INT || iv.as.i < 0)
              return CV_NIL;
            cur = (uint32_t)iv.as.i;
          }
          if (++cur > len)
            len = cur;
        }
      }
      const uint32_t o = ce_obj_new(ce, len);
      if (!o)
        return CV_NIL;
      if (count < len) { // C zero-fills the tail of a partial initializer
        ModuleId em;
        TypeId et;
        if (!ce_rtype(ce, f, tm2, y->as.elem, &em, &et))
          return CV_NIL;
        const CeVal z = ce_zero(ce, em, et, 0);
        if (z.kind == CV_NIL_K)
          return CV_NIL;
        for (uint32_t i = 0; i < len; i++) {
          CeObj *const ao = ce_obj(ce, o);
          ao->slots[i] = ce_clone(ce, z, 0);
        }
      }
      uint32_t cursor = 0;
      for (uint32_t i = 0; i < count; i++) {
        const Node *const el = ast_at_const(a, eids[i]);
        NodeId value = eids[i];
        if (el->kind == NODE_FIELD_INITIALIZER) { // `[idx] = v` designator moves the cursor
          const CeVal iv = ev_in(ce, NULL, m, el->as.field_initializer.name);
          if (iv.kind != CV_INT || iv.as.i < 0)
            return CV_NIL;
          cursor = (uint32_t)iv.as.i;
          value = el->as.field_initializer.value;
        }
        if (cursor >= len)
          return CV_NIL;
        const CeVal v = ev_rval(ce, f, m, value);
        if (v.kind == CV_NIL_K)
          return CV_NIL;
        CeObj *const ao = ce_obj(ce, o);
        ao->slots[cursor] = ce_clone(ce, v, 0);
        if (ao->slots[cursor].kind == CV_NIL_K)
          return CV_NIL;
        cursor++;
      }
      return (CeVal){.kind = CV_AGG, .tm = m, .type = ce_type(a, id), .as.p = {o, 0}};
    }
    case NODE_TUPLE: { // lowers to a TupleN struct: positional fields _0.._N
      CeRecv r;
      if (!ce_recv_of(ce, f, m, ce_type(a, id), &r) || r.dn == NODE_NONE)
        return CV_NIL;
      const NodeId *const eids = ast_list(a, n->as.array_literal.elements);
      const uint32_t count = n->as.array_literal.elements.len;
      const uint32_t o = ce_obj_new(ce, count);
      if (!o)
        return CV_NIL;
      {
        CeObj *const to = ce_obj(ce, o);
        to->dm = r.dm;
        to->dn = r.dn;
        to->nargs = r.n;
        memcpy(to->am, r.am, sizeof to->am);
        memcpy(to->at, r.at, sizeof to->at);
      }
      for (uint32_t i = 0; i < count; i++) {
        const CeVal v = ev_rval(ce, f, m, eids[i]);
        if (v.kind == CV_NIL_K)
          return CV_NIL;
        CeObj *const to = ce_obj(ce, o);
        to->slots[i] = ce_clone(ce, v, 0);
        if (to->slots[i].kind == CV_NIL_K)
          return CV_NIL;
      }
      return (CeVal){.kind = CV_AGG, .tm = m, .type = ce_type(a, id), .as.p = {o, 0}};
    }
    case NODE_CLOSURE:
      return (CeVal){.kind = CV_FN, .tm = m, .type = ce_type(a, id), .as.fnv = {m, id}};
    case NODE_RANGE: // a first-class range value: the prelude `Range<T>` struct
      return ce_range_obj(ce, f, m, id);
    default:
      return CV_NIL; // slices are built at coercion sites; unions/va_* are not modeled
  }
}

// --- patterns and switch ------------------------------------------------------------------------

// Does scalar/enum value `v` match `pid`? 1 = yes (bindings applied), 0 = no, -1 = unfoldable.
// `refobj` != 0: a by-reference match; payload bindings become pointers into that enum object.
static int pat_match(ConstEval *ce, CeFrame *f, const ModuleId m, const NodeId pid, const CeVal *v, const bool uns,
                     const uint32_t refobj) {
  const Ast *const a = ce_ast(ce, m);
  const Node *const p = ast_at_const(a, pid);
  switch (p->kind) {
    case NODE_PATTERN_WILDCARD:
      return 1;
    case NODE_PATTERN_NAME: {
      const DefId d = ast_resolution_def(a, p->as.pattern.name);
      if (d.node != NODE_NONE && d.module < ce->nmods &&
          ast_at_const(ce_ast(ce, d.module), d.node)->kind == NODE_VARIANT) {
        if (v->kind == CV_INT || v->kind == CV_BOOL) { // plain C enum: discriminant test
          const ConstValue tv = variant_value(ce, d.module, d.node);
          return tv.kind == CONST_INT ? tv.i == v->as.i : -1;
        }
        if (v->kind == CV_AGG) { // tagged enum: variant-index test
          const CeObj *const o = ce_obj(ce, v->as.p.obj);
          const int pos = ce_variant_pos(ce, d.module, d.node, NULL);
          return o && o->is_enum && pos >= 0 ? o->slots[0].as.i == pos : -1;
        }
        return -1;
      }
      if (!(f && ce_bind(ce, f, pid, *v)))
        return -1;
      if (p->as.pattern.children.len) { // `x @ pat`: the sub-pattern decides the match
        const NodeId *const subs = ast_list(a, p->as.pattern.children);
        return pat_match(ce, f, m, subs[0], v, uns, refobj);
      }
      return 1; // a plain binding: always matches
    }
    case NODE_PATTERN_LITERAL: {
      const CeVal lv = ev_in(ce, NULL, m, p->as.single.value); // untyped atom: context-free
      if (lv.kind != CV_INT && lv.kind != CV_BOOL)
        return -1;
      return lv.as.i == v->as.i && (v->kind == CV_INT || v->kind == CV_BOOL);
    }
    case NODE_PATTERN_RANGE: {
      if (v->kind != CV_INT)
        return -1;
      if (p->as.pattern_range.start != NODE_NONE) {
        const Node *const bnode = ast_at_const(a, p->as.pattern_range.start);
        const CeVal s = ev_in(ce, NULL, m, bnode->kind == NODE_PATTERN_LITERAL ? bnode->as.single.value : p->as.pattern_range.start);
        if (s.kind != CV_INT)
          return -1;
        if (uns ? (uint64_t)v->as.i < (uint64_t)s.as.i : v->as.i < s.as.i)
          return 0;
      }
      if (p->as.pattern_range.end != NODE_NONE) {
        const Node *const bnode = ast_at_const(a, p->as.pattern_range.end);
        const CeVal e = ev_in(ce, NULL, m, bnode->kind == NODE_PATTERN_LITERAL ? bnode->as.single.value : p->as.pattern_range.end);
        if (e.kind != CV_INT)
          return -1;
        if (p->as.pattern_range.inclusive ? (uns ? (uint64_t)v->as.i > (uint64_t)e.as.i : v->as.i > e.as.i)
                                          : (uns ? (uint64_t)v->as.i >= (uint64_t)e.as.i : v->as.i >= e.as.i))
          return 0;
      }
      return 1;
    }
    case NODE_PATTERN_OR: {
      const NodeId *const ids = ast_list(a, p->as.pattern.children);
      for (uint32_t i = 0; i < p->as.pattern.children.len; i++) {
        const int r = pat_match(ce, f, m, ids[i], v, uns, refobj);
        if (r)
          return r; // matched, or unfoldable
      }
      return 0;
    }
    case NODE_PATTERN_TUPLE: { // Variant(p0, p1, ..) over a tagged enum value
      if (p->as.pattern.name == NODE_NONE) { // parenthesized pattern
        const NodeId *const ids = ast_list(a, p->as.pattern.children);
        return p->as.pattern.children.len == 1 ? pat_match(ce, f, m, ids[0], v, uns, refobj) : -1;
      }
      if (v->kind != CV_AGG)
        return -1;
      const DefId d = ast_resolution_def(a, p->as.pattern.name);
      if (d.node == NODE_NONE || ast_at_const(ce_ast(ce, d.module), d.node)->kind != NODE_VARIANT)
        return -1;
      const CeObj *const o = ce_obj(ce, v->as.p.obj);
      const int pos = ce_variant_pos(ce, d.module, d.node, NULL);
      if (!o || !o->is_enum || pos < 0)
        return -1;
      if (o->slots[0].as.i != pos)
        return 0;
      const NodeId *const ids = ast_list(a, p->as.pattern.children);
      for (uint32_t k = 0; k < p->as.pattern.children.len; k++) {
        if (1 + k >= o->len)
          return -1;
        if (refobj && ast_at_const(a, ids[k])->kind == NODE_PATTERN_NAME &&
            ast_resolution_def(a, ast_at_const(a, ids[k])->as.pattern.name).node == NODE_NONE) {
          // by-reference match: a name binding aliases the payload slot
          const CeVal pv = {.kind = CV_PTR, .tm = 0, .type = TYPE_NONE, .as.p = {refobj, 1 + k}};
          if (!f || !ce_bind(ce, f, ids[k], pv))
            return -1;
          continue;
        }
        const CeVal sv = o->slots[1 + k];
        if (sv.kind == CV_NIL_K)
          return -1;
        const int r = pat_match(ce, f, m, ids[k], &sv, uns, 0);
        if (r != 1)
          return r;
      }
      return 1;
    }
    case NODE_PATTERN_STRUCT: { // Variant { field: pat, shorthand } over a tagged enum
      if (v->kind != CV_AGG || p->as.pattern.name == NODE_NONE)
        return -1;
      const DefId d = ast_resolution_def(a, p->as.pattern.name);
      if (d.node == NODE_NONE || ast_at_const(ce_ast(ce, d.module), d.node)->kind != NODE_VARIANT)
        return -1;
      const CeObj *const o = ce_obj(ce, v->as.p.obj);
      const int pos = ce_variant_pos(ce, d.module, d.node, NULL);
      if (!o || !o->is_enum || pos < 0)
        return -1;
      if (o->slots[0].as.i != pos)
        return 0;
      const Node *const vd = ast_at_const(ce_ast(ce, d.module), d.node);
      if (!vd->as.variant.struct_payload)
        return -1;
      const NodeId *const pfids = ast_list(ce_ast(ce, d.module), vd->as.variant.payload);
      const NodeId *const ids = ast_list(a, p->as.pattern.children);
      for (uint32_t k = 0; k < p->as.pattern.children.len; k++) {
        const Node *const pf = ast_at_const(a, ids[k]);
        if (pf->kind != NODE_PATTERN_FIELD || pf->as.pattern.name == NODE_NONE)
          return -1;
        int slot = -1; // the named field's position within the variant's payload
        for (uint32_t j = 0; j < vd->as.variant.payload.len; j++) {
          const Node *const fd = ast_at_const(ce_ast(ce, d.module), pfids[j]);
          if (fd->kind == NODE_FIELD &&
              ce_spans_eq(ce, d.module, ast_at_const(ce_ast(ce, d.module), fd->as.field.name)->as.name.text, m,
                          ast_at_const(a, pf->as.pattern.name)->as.name.text)) {
            slot = (int)j;
            break;
          }
        }
        if (slot < 0 || 1 + (uint32_t)slot >= o->len)
          return -1;
        const NodeId child = ast_list(a, pf->as.pattern.children)[0];
        if (refobj && ast_at_const(a, child)->kind == NODE_IDENTIFIER) { // shorthand bind, by reference
          const CeVal pv = {.kind = CV_PTR, .tm = 0, .type = TYPE_NONE, .as.p = {refobj, 1 + (uint32_t)slot}};
          if (!f || !ce_bind(ce, f, child, pv))
            return -1;
          continue;
        }
        const CeVal sv = o->slots[1 + slot];
        if (sv.kind == CV_NIL_K)
          return -1;
        if (ast_at_const(a, child)->kind == NODE_IDENTIFIER) { // shorthand bind, by value
          if (!f || !ce_bind(ce, f, child, sv))
            return -1;
          continue;
        }
        const int r = pat_match(ce, f, m, child, &sv, uns, 0);
        if (r != 1)
          return r;
      }
      return 1;
    }
    default:
      return -1; // slice/rest patterns: not modeled
  }
}

// A `switch` over a folded value. `out` != NULL is VALUE mode; NULL executes the taken arm.
static int exec_match(ConstEval *ce, CeFrame *f, const ModuleId m, const Node *n, CeVal *out) {
  const Ast *const a = ce_ast(ce, m);
  CeVal v = ev_in(ce, f, m, n->as.match_expr.value);
  uint32_t refobj = 0;
  { // a by-reference scrutinee (`switch &x` / a &self payload) derefs for the tag test
    for (int guard = 0; guard < 4 && v.kind == CV_PTR; guard++) {
      const CeVal pv = v;
      if (!ce_loadp(ce, pv, &v))
        return X_BAIL;
      if (v.kind == CV_AGG)
        refobj = v.as.p.obj;
    }
  }
  if (v.kind == CV_NIL_K)
    return xfail(f);
  const BuiltinType sb = ce_builtin_of(ce, f, m, ce_type(a, n->as.match_expr.value));
  const bool uns = sb != BT_COUNT && bt_unsigned(sb);
  const NodeId *const ids = ast_list(a, n->as.match_expr.arms);
  for (uint32_t i = 0; i < n->as.match_expr.arms.len; i++) {
    const Node *const arm = ast_at_const(a, ids[i]);
    const int hit = pat_match(ce, f, m, arm->as.match_arm.pattern, &v, uns, refobj);
    if (hit < 0)
      return X_BAIL;
    if (!hit)
      continue;
    if (arm->as.match_arm.guard != NODE_NONE) {
      const CeVal g = ev_rval(ce, f, m, arm->as.match_arm.guard);
      if (g.kind != CV_BOOL)
        return xfail(f);
      if (!g.as.i)
        continue;
    }
    const NodeId body = arm->as.match_arm.body;
    if (out) {
      *out = ev_in(ce, f, m, body);
      return out->kind != CV_NIL_K ? X_OK : xfail(f);
    }
    return ast_at_const(a, body)->kind == NODE_BLOCK ? exec_stmt(ce, f, m, body) : exec_expr_stmt(ce, f, m, body);
  }
  return X_BAIL; // no arm matched: we mis-evaluated somewhere -- stay runtime
}

// --- statements ---------------------------------------------------------------------------------

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

static int exec_assign(ConstEval *ce, CeFrame *f, const ModuleId m, const Node *n) {
  const Ast *const a = ce_ast(ce, m);
  CeVal place;
  if (!ev_place(ce, f, m, n->as.binary.left, &place))
    return xfail(f);
  CeVal r = ev_rval(ce, f, m, n->as.binary.right);
  if (r.kind == CV_NIL_K)
    return xfail(f);
  if (n->as.binary.op != Equal) {
    CeVal cur;
    if (!ce_loadp(ce, place, &cur))
      return X_BAIL;
    const TokenType op = compound_op(n->as.binary.op);
    const TypeId lt = ce_type(a, n->as.binary.left);
    const BuiltinType tb = ce_builtin_of(ce, f, m, lt);
    if (cur.kind == CV_FLOAT && r.kind == CV_FLOAT)
      r = ce_float_op(op, cur, r, m, lt, tb);
    else if (cur.kind == CV_INT && r.kind == CV_INT)
      r = ce_int_op(ce, op, cur, r, m, lt, tb, tb);
    else
      return X_BAIL;
    if (r.kind == CV_NIL_K)
      return X_BAIL;
  }
  return ce_storep(ce, place, r) ? X_OK : X_BAIL;
}

// An expression in statement position: assignments, switches and calls execute; anything else
// must fold to a pure value (discarded) -- effects can never disappear into a fold.
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
  if (n->kind == NODE_CALL) {
    CeVal rets[8];
    uint8_t nrets = 0;
    return ce_call(ce, f, m, id, rets, &nrets) ? X_OK : xfail(f); // result (if any) is discarded
  }
  return ev_in(ce, f, m, id).kind != CV_NIL_K ? X_OK : xfail(f);
}

static int exec_stmt(ConstEval *ce, CeFrame *f, const ModuleId m, const NodeId id) {
  if (!ce_tick(ce))
    return X_BAIL;
  const Ast *const a = ce_ast(ce, m);
  const Node *const n = ast_at_const(a, id);
  switch (n->kind) {
    case NODE_BLOCK: {
      const NodeId *const ids = ast_list(a, n->as.block.statements);
      const uint8_t dbase = f->ndefers;
      int st = X_OK;
      for (uint32_t i = 0; st == X_OK && i < n->as.block.statements.len; i++)
        st = exec_stmt(ce, f, m, ids[i]);
      for (uint32_t i = f->ndefers; i-- > dbase;) { // every exit path replays this scope's defers
        const Node *const dv = ast_at_const(a, f->defers[i]);
        const int ds = dv->kind == NODE_BLOCK ? exec_stmt(ce, f, m, f->defers[i]) : exec_expr_stmt(ce, f, m, f->defers[i]);
        if (ds != X_OK)
          st = X_BAIL;
      }
      f->ndefers = dbase;
      return st;
    }
    case NODE_LET: {
      const Node *const nm = ast_at_const(a, n->as.let_stmt.name);
      if (nm->kind == NODE_PATTERN_TUPLE) { // multi-return / tuple destructuring
        const NodeId *const eids = ast_list(a, nm->as.pattern.children);
        const uint32_t nbind = nm->as.pattern.children.len;
        if (n->as.let_stmt.value == NODE_NONE)
          return X_BAIL;
        const Node *const vn = ast_at_const(a, n->as.let_stmt.value);
        CeVal vals[8];
        uint32_t nvals = 0;
        if (vn->kind == NODE_CALL) {
          uint8_t nr = 0;
          if (!ce_call(ce, f, m, n->as.let_stmt.value, vals, &nr))
            return xfail(f);
          nvals = nr;
        }
        if (nvals <= 1) { // a tuple VALUE destructures by field
          const CeVal tv = nvals == 1 ? vals[0] : ev_rval(ce, f, m, n->as.let_stmt.value);
          if (tv.kind != CV_AGG)
            return xfail(f);
          const CeObj *const o = ce_obj(ce, tv.as.p.obj);
          if (!o || o->len < nbind)
            return X_BAIL;
          for (uint32_t i = 0; i < nbind; i++)
            vals[i] = o->slots[i];
          nvals = nbind;
        }
        if (nvals != nbind)
          return X_BAIL;
        for (uint32_t i = 0; i < nbind; i++)
          if (vals[i].kind == CV_NIL_K || !ce_bind(ce, f, eids[i], vals[i]))
            return xfail(f);
        return X_OK;
      }
      if (nm->kind != NODE_IDENTIFIER)
        return X_BAIL;
      CeVal v = CV_NIL; // `let x;`: definite-init has proven every read follows an assignment
      if (n->as.let_stmt.value != NODE_NONE) {
        // an annotated scalar wants the value; an unannotated one keeps references as references
        if (n->as.let_stmt.type != NODE_NONE) {
          ModuleId wm;
          TypeId wt;
          if (!ce_rtype(ce, f, m, ce_type(a, n->as.let_stmt.type), &wm, &wt))
            return X_BAIL;
          v = ce_coerce(ce, ev_in(ce, f, m, n->as.let_stmt.value), wm, wt);
        } else {
          v = ev_in(ce, f, m, n->as.let_stmt.value);
        }
        if (v.kind == CV_NIL_K)
          return xfail(f);
      }
      return ce_bind(ce, f, id, v) ? X_OK : X_BAIL; // refs resolve to the LET node itself
    }
    case NODE_IF: {
      const CeVal c = ev_rval(ce, f, m, n->as.if_stmt.condition);
      if (c.kind != CV_BOOL)
        return xfail(f);
      if (c.as.i)
        return exec_stmt(ce, f, m, n->as.if_stmt.then_branch);
      return n->as.if_stmt.else_branch == NODE_NONE ? X_OK : exec_stmt(ce, f, m, n->as.if_stmt.else_branch);
    }
    case NODE_WHILE: {
      bool first = n->as.while_stmt.is_do; // `do {} while`: the body runs before the first test
      for (;;) {
        if (!first && n->as.while_stmt.condition != NODE_NONE) { // condition-less `loop`: only break exits
          const CeVal c = ev_rval(ce, f, m, n->as.while_stmt.condition);
          if (c.kind != CV_BOOL)
            return xfail(f);
          if (!c.as.i)
            return X_OK;
        }
        first = false;
        const int st = exec_stmt(ce, f, m, n->as.while_stmt.body);
        if (st == X_BREAK)
          return X_OK;
        if (st == X_RETURN || st == X_BAIL)
          return st;
        if (!ce_tick(ce))
          return X_BAIL; // the budget is the ONLY brake on `while true`
      }
    }
    case NODE_FOR: {
      const Node *const it = ast_at_const(a, n->as.for_stmt.iterable);
      if (it->kind == NODE_RANGE) { // a counting loop; the END re-evaluates every iteration (like the C)
        if (it->as.pattern_range.start == NODE_NONE || it->as.pattern_range.end == NODE_NONE)
          return X_BAIL;
        const CeVal s = ev_rval(ce, f, m, it->as.pattern_range.start);
        if (s.kind != CV_INT)
          return xfail(f);
        const BuiltinType eb = ce_builtin_of(ce, f, m, ce_type(a, n->as.for_stmt.iterable));
        const bool uns = eb != BT_COUNT && bt_unsigned(eb);
        const bool inc = it->as.pattern_range.inclusive;
        const TypeId et = ce_type(a, id); // the checker typed the for-node with the element type
        CeVal *const slot = ce_bind_slot(ce, f, id);
        if (!slot)
          return X_BAIL;
        for (int64_t v = s.as.i;; v++) {
          const CeVal e = ev_rval(ce, f, m, it->as.pattern_range.end);
          if (e.kind != CV_INT)
            return xfail(f);
          const bool last = v == e.as.i;
          if (uns ? (uint64_t)v > (uint64_t)e.as.i || (!inc && last) : v > e.as.i || (!inc && last))
            return X_OK;
          *ce_bind_slot(ce, f, id) = (CeVal){.kind = CV_INT, .tm = m, .type = et, .as.i = v};
          const int st = exec_stmt(ce, f, m, n->as.for_stmt.body);
          if (st == X_BREAK)
            return X_OK;
          if (st == X_RETURN || st == X_BAIL)
            return st;
          if (!ce_tick(ce))
            return X_BAIL;
          if (inc && last)
            return X_OK; // don't step past the type's maximum
        }
      }
      { // an array iterates its slots by value
        ModuleId im;
        TypeId itT;
        if (!ce_rtype(ce, f, m, ce_type(a, n->as.for_stmt.iterable), &im, &itT))
          return X_BAIL;
        if (ast_type_at(ce_ast(ce, im), itT)->kind == TYPE_ARRAY) {
          uint32_t obj;
          if (!ce_base_obj(ce, f, m, n->as.for_stmt.iterable, &obj))
            return X_BAIL;
          const uint32_t len = ce_obj(ce, obj)->len;
          for (uint32_t i = 0; i < len; i++) {
            const CeVal sv = ce_obj(ce, obj)->slots[i];
            if (sv.kind == CV_NIL_K || !ce_bind(ce, f, id, sv))
              return X_BAIL;
            const int st = exec_stmt(ce, f, m, n->as.for_stmt.body);
            if (st == X_BREAK)
              return X_OK;
            if (st == X_RETURN || st == X_BAIL)
              return st;
            if (!ce_tick(ce))
              return X_BAIL;
          }
          return X_OK;
        }
      }
      { // the Iterator protocol: the iterable IS the iterator; loop on next() until None
        const CeVal iv = ev_in(ce, f, m, n->as.for_stmt.iterable);
        if (iv.kind == CV_NIL_K)
          return xfail(f);
        CeVal itp;
        if (!ce_temp_place(ce, iv, &itp))
          return X_BAIL;
        CeRecv r;
        if (!ce_recv_of(ce, f, m, ce_type(a, n->as.for_stmt.iterable), &r) || r.dn == NODE_NONE)
          return X_BAIL;
        for (;;) {
          CeVal opt;
          if (!ce_dispatch(ce, &r, m, "next", &itp, 1, &opt) || opt.kind != CV_AGG)
            return X_BAIL;
          const CeObj *const oo = ce_obj(ce, opt.as.p.obj);
          if (!oo || !oo->is_enum)
            return X_BAIL;
          // Some = the variant WITH a payload; None carries none
          if (oo->len < 2 || oo->slots[1].kind == CV_NIL_K) {
            if (oo->len >= 2)
              return X_BAIL; // a Some without a folded payload
            return X_OK;     // None: done
          }
          if (!ce_bind(ce, f, id, oo->slots[1]))
            return X_BAIL;
          const int st = exec_stmt(ce, f, m, n->as.for_stmt.body);
          if (st == X_BREAK)
            return X_OK;
          if (st == X_RETURN || st == X_BAIL)
            return st;
          if (!ce_tick(ce))
            return X_BAIL;
        }
      }
    }
    case NODE_RETURN: {
      const NodeId *const vids = ast_list(a, n->as.return_stmt.values);
      if (n->as.return_stmt.values.len > 8)
        return X_BAIL;
      f->nrets = 0;
      for (uint32_t i = 0; i < n->as.return_stmt.values.len; i++) {
        const CeVal v = ev_in(ce, f, m, vids[i]);
        if (v.kind == CV_NIL_K)
          return xfail(f); // a `?` inside the return value already staged the early result
        f->rets[f->nrets++] = v;
      }
      f->returned = 1;
      return X_RETURN;
    }
    case NODE_BREAK:
      if (n->as.flow.label.end > n->as.flow.label.start || n->as.flow.value != NODE_NONE)
        return X_BAIL; // labeled / value-carrying breaks route beyond the innermost loop: stay runtime
      return X_BREAK;
    case NODE_CONTINUE:
      if (n->as.flow.label.end > n->as.flow.label.start)
        return X_BAIL;
      return X_CONTINUE;
    case NODE_DEFER:
      if (f->ndefers >= CE_MAX_DEFERS)
        return X_BAIL;
      f->defers[f->ndefers++] = n->as.single.value;
      return X_OK;
    case NODE_EXPRESSION_STATEMENT:
      return exec_expr_stmt(ce, f, m, n->as.single.value);
    default:
      return X_BAIL;
  }
}

// --- calls --------------------------------------------------------------------------------------

// Add one concrete substitution (param decl in pmod -> (am, at)); re-binding must agree.
static bool ce_subst_add(const ConstEval *ce, CeFrame *g, const ModuleId pmod, const NodeId param, const ModuleId am,
                         const TypeId at) {
  for (uint8_t i = 0; i < g->ng; i++)
    if (g->pmod == pmod && g->params_g[i] == param)
      return ce_teq(ce, g->am[i], g->at[i], am, at);
  if (g->ng >= 8 || (g->ng && g->pmod != pmod))
    return false;
  g->pmod = pmod;
  g->params_g[g->ng] = param;
  g->am[g->ng] = am;
  g->at[g->ng] = at;
  g->ng++;
  return true;
}

// Bind an extend's generic params by unifying its target type against the receiver identity.
static bool ce_bind_extend(const ConstEval *ce, CeFrame *g, const ModuleId xm, const NodeId extend,
                           const CeRecv *recv) {
  const Ast *const xa = ce_ast(ce, xm);
  const Node *const x = ast_at_const(xa, extend);
  const NodeList gens = x->as.extend_def.generics;
  if (gens.len == 0)
    return true;
  if (!recv || recv->dn == NODE_NONE)
    return false;
  // Walk the target's type-path SYNTACTICALLY (extend target nodes carry no cached TypeId): each
  // arg that resolves to a generic param binds the receiver's arg at that position.
  const Node *const tp = ast_at_const(xa, x->as.extend_def.target_type);
  if (tp->kind != NODE_TYPE_PATH || tp->as.type_path.args.len != recv->n)
    return false;
  const NodeId *const aids = ast_list(xa, tp->as.type_path.args);
  for (uint8_t i = 0; i < recv->n; i++) {
    const DefId ad = ast_resolution_def(xa, aids[i]);
    if (ad.node != NODE_NONE && ad.module < ce->nmods &&
        ast_at_const(ce_ast(ce, ad.module), ad.node)->kind == NODE_GENERIC_PARAM) {
      if (!ce_subst_add(ce, g, ad.module, ad.node, recv->am[i], recv->at[i]))
        return false;
    } else {
      const TypeId at2 = ce_type(xa, aids[i]);
      if (at2 == TYPE_NONE || !ce_teq(ce, xm, at2, recv->am[i], recv->at[i]))
        return false;
    }
  }
  const NodeId *const gids = ast_list(xa, gens);
  for (uint32_t i = 0; i < gens.len; i++) { // every extend param must now be bound
    bool bound = false;
    for (uint8_t k = 0; k < g->ng; k++)
      bound |= g->pmod == xm && g->params_g[k] == gids[i];
    if (!bound)
      return false;
  }
  return true;
}

// Intercepted extern calls: the C heap, the trap runtime, and libm.
static bool ce_intercept(ConstEval *ce, const ModuleId fm, const Node *fn, const CeVal *args, const uint32_t nargs,
                         const ModuleId m, const NodeId callId, CeVal rets[8], uint8_t *nrets) {
  const Span nm = ast_at_const(ce_ast(ce, fm), fn->as.function.name)->as.name.text;
  const Ast *const a = ce_ast(ce, m);
  *nrets = 0;
  if (ce_span_is(ce, fm, nm, "malloc")) {
    if (nargs != 1 || args[0].kind != CV_INT || args[0].as.i < 0)
      return false;
    const uint32_t o = ce_obj_new(ce, 0);
    if (!o)
      return false;
    CeObj *const b = ce_obj(ce, o);
    b->heap = 1;
    b->bytes = (uint64_t)args[0].as.i;
    b->et = TYPE_NONE;
    rets[(*nrets)++] = (CeVal){.kind = CV_PTR, .tm = m, .type = ce_type(a, callId), .as.p = {o, 0}};
    return true;
  }
  if (ce_span_is(ce, fm, nm, "realloc")) {
    if (nargs != 2 || args[0].kind != CV_PTR || args[1].kind != CV_INT || args[1].as.i < 0)
      return false;
    const uint64_t nbytes = (uint64_t)args[1].as.i;
    if (args[0].as.p.obj == 0) { // realloc(NULL, n) == malloc(n)
      const uint32_t o = ce_obj_new(ce, 0);
      if (!o)
        return false;
      CeObj *const b = ce_obj(ce, o);
      b->heap = 1;
      b->bytes = nbytes;
      b->et = TYPE_NONE;
      rets[(*nrets)++] = (CeVal){.kind = CV_PTR, .tm = m, .type = ce_type(a, callId), .as.p = {o, 0}};
      return true;
    }
    CeObj *const b = ce_obj(ce, args[0].as.p.obj);
    if (!b || !b->heap || args[0].as.p.off != 0)
      return false;
    if (b->dead) {
      ce_trap(ce, "use after free");
      return false;
    }
    if (b->et != TYPE_NONE) { // typed: resize the slot view (realloc-in-place keeps the handle)
      if (b->esz == 0 || nbytes % b->esz)
        return false;
      if (!ce_obj_resize(ce, b, (uint32_t)(nbytes / b->esz)))
        return false;
    }
    b->bytes = nbytes;
    rets[(*nrets)++] = (CeVal){.kind = CV_PTR, .tm = m, .type = ce_type(a, callId), .as.p = {args[0].as.p.obj, 0}};
    return true;
  }
  if (ce_span_is(ce, fm, nm, "free")) {
    if (nargs != 1 || args[0].kind != CV_PTR)
      return false;
    if (args[0].as.p.obj == 0)
      return true; // free(NULL) is a no-op
    CeObj *const b = ce_obj(ce, args[0].as.p.obj);
    if (!b || !b->heap || args[0].as.p.off != 0)
      return false;
    if (b->dead) {
      ce_trap(ce, "double free");
      return false;
    }
    b->dead = 1;
    return true;
  }
  if (ce_span_is(ce, fm, nm, "memset")) { // element-wise fill; Map zeroes its slot bitmap this way
    if (nargs != 3 || args[0].kind != CV_PTR || args[1].kind != CV_INT || args[2].kind != CV_INT || args[2].as.i < 0)
      return false;
    const uint64_t n = (uint64_t)args[2].as.i;
    if (args[0].as.p.obj == 0)
      return n == 0; // memset(NULL, _, 0) is technically UB but harmless; nonzero traps below
    CeObj *const b = ce_obj(ce, args[0].as.p.obj);
    if (!b || !b->heap)
      return false;
    if (b->dead) {
      ce_trap(ce, "use after free");
      return false;
    }
    if (b->et == TYPE_NONE && args[0].as.p.off == 0) { // an untyped block: memset gives it a byte view
      if (!ce_obj_resize(ce, b, (uint32_t)b->bytes))
        return false;
      b->em = 0;
      b->et = ast_builtin(BT_U8);
      b->esz = 1;
    }
    if (b->esz == 0 || n % b->esz)
      return false;
    const uint64_t count = n / b->esz;
    if (args[0].as.p.off + count > b->len) {
      ce_trap(ce, "out-of-bounds access");
      return false;
    }
    CeVal fill;
    if (b->esz == 1) {
      fill = (CeVal){.kind = CV_INT, .tm = 0, .type = ast_builtin(BT_U8), .as.i = args[1].as.i & 0xff};
    } else {
      if (args[1].as.i != 0)
        return false; // a non-zero pattern over multi-byte elements is byte-level reinterpretation
      fill = ce_zero(ce, b->em, b->et, 0);
      if (fill.kind == CV_NIL_K)
        return false;
    }
    for (uint64_t i = 0; i < count; i++)
      b->slots[args[0].as.p.off + i] = ce_clone(ce, fill, 0);
    rets[(*nrets)++] = args[0]; // memset returns dst
    return true;
  }
  if (ce_span_is(ce, fm, nm, "abort")) {
    ce_trap(ce, "abort reached at compile time");
    return false;
  }
  if (ce_span_is(ce, fm, nm, "__sc_panic_str") || ce_span_is(ce, fm, nm, "__sc_panic")) {
    ce_trap(ce, "panic reached at compile time");
    return false;
  }
  { // libm: fold through the host's IEEE doubles/floats
    char name[24];
    const size_t ln = nm.end - nm.start;
    if (ln >= sizeof name || nargs < 1 || nargs > 3)
      return false;
    memcpy(name, ce_src(ce, fm) + nm.start, ln);
    name[ln] = '\0';
    const bool f32 = ln > 1 && name[ln - 1] == 'f';
    if (f32)
      name[ln - 1] = '\0';
    double in[3];
    for (uint32_t i = 0; i < nargs; i++) {
      if (args[i].kind != CV_FLOAT)
        return false;
      in[i] = args[i].as.f;
    }
    double v;
    static const struct { const char *n; double (*fn)(double); } one[] = {
        {"sqrt", sqrt}, {"cbrt", cbrt}, {"exp", exp}, {"exp2", exp2}, {"expm1", expm1}, {"log", log},
        {"log2", log2}, {"log10", log10}, {"log1p", log1p}, {"sin", sin}, {"cos", cos}, {"tan", tan},
        {"asin", asin}, {"acos", acos}, {"atan", atan}, {"sinh", sinh}, {"cosh", cosh}, {"tanh", tanh},
        {"asinh", asinh}, {"acosh", acosh}, {"atanh", atanh}, {"floor", floor}, {"ceil", ceil},
        {"round", round}, {"trunc", trunc}, {"fabs", fabs},
    };
    static const struct { const char *n; double (*fn)(double, double); } two[] = {
        {"pow", pow}, {"hypot", hypot}, {"atan2", atan2}, {"fmod", fmod}, {"copysign", copysign},
        {"fmin", fmin}, {"fmax", fmax},
    };
    if (nargs == 1) {
      for (size_t i = 0;; i++) {
        if (i >= sizeof one / sizeof one[0])
          return false;
        if (strcmp(one[i].n, name) == 0) {
          v = one[i].fn(in[0]);
          break;
        }
      }
    } else if (nargs == 2) {
      for (size_t i = 0;; i++) {
        if (i >= sizeof two / sizeof two[0])
          return false;
        if (strcmp(two[i].n, name) == 0) {
          v = two[i].fn(in[0], in[1]);
          break;
        }
      }
    } else {
      if (strcmp(name, "fma") != 0)
        return false;
      v = fma(in[0], in[1], in[2]);
    }
    if (f32)
      v = (double)(float)((float)v); // the f-suffixed libm entry computes in float
    rets[(*nrets)++] = (CeVal){.kind = CV_FLOAT, .tm = m, .type = ce_type(a, callId), .as.f = v};
    return true;
  }
}

// Run a resolved concrete function/closure body in a fresh frame.
static bool ce_invoke(ConstEval *ce, const ModuleId fm, const NodeId fnode, const NodeId extend_node,
                      const CeRecv *recv, const ModuleId *monom, const TypeId *monot, const uint8_t nmono,
                      const CeVal *args, const uint32_t nargs, const ModuleId self_pm, const NodeId self_decl,
                      const ModuleId self_am, const TypeId self_at, CeVal rets[8], uint8_t *nrets) {
  const Ast *const fa = ce_ast(ce, fm);
  const Node *const fn = ast_at_const(fa, fnode);
  const bool closure = fn->kind == NODE_CLOSURE;
  if (!closure && fn->kind != NODE_FUNCTION)
    return false;
  const NodeList params = closure ? fn->as.closure.params : fn->as.function.params;
  const NodeId body = closure ? fn->as.closure.body : fn->as.function.body;
  if (body == NODE_NONE || params.len != nargs)
    return false;
  if (!closure && (fn->as.function.is_variadic))
    return false;
  if (ce->nframes >= CE_MAX_FRAMES) {
    ce_trap(ce, "const-eval call depth exceeded");
    return false;
  }
  CeFrame g;
  memset(&g, 0, sizeof g);
  if (self_decl != NODE_NONE && !ce_subst_add(ce, &g, self_pm, self_decl, self_am, self_at))
    return false; // an interface default body: Self -> the receiver's concrete type
  if (extend_node != NODE_NONE) {
    const NodeList xg = ast_at_const(fa, extend_node)->as.extend_def.generics;
    bool bound = xg.len == 0;
    if (!bound && recv && recv->dn != NODE_NONE && recv->n)
      bound = ce_bind_extend(ce, &g, fm, extend_node, recv);
    if (!bound) { // a path call (`Type::<..>::assoc(..)`): the mono record LEADS with the extend's args
      if (nmono < xg.len)
        return false;
      const NodeId *const gids = ast_list(fa, xg);
      for (uint32_t i = 0; i < xg.len; i++) {
        if (monot[i] == TYPE_NONE || !ast_type_concrete(ce_ast(ce, monom[i]), monot[i]))
          return false;
        if (!ce_subst_add(ce, &g, fm, gids[i], monom[i], monot[i]))
          return false;
      }
    }
  }
  if (!closure) {
    const NodeList fg = fn->as.function.generics;
    if (fg.len) { // the fn's OWN args are the LAST of the record (extras name the extend/instance)
      if (nmono < fg.len)
        return false;
      const uint8_t skip = (uint8_t)(nmono - fg.len);
      const NodeId *const gids = ast_list(fa, fg);
      for (uint32_t i = 0; i < fg.len; i++) {
        if (monot[skip + i] == TYPE_NONE || !ast_type_concrete(ce_ast(ce, monom[skip + i]), monot[skip + i]))
          return false;
        if (!ce_subst_add(ce, &g, fm, gids[i], monom[skip + i], monot[skip + i]))
          return false;
      }
    }
  }
  // memoization: a substitution-free call over scalar arguments may already have a cached result
  bool cacheable = !closure && g.ng == 0 && nargs <= 8;
  for (uint32_t i = 0; cacheable && i < nargs; i++)
    cacheable = cv_is_scalar(args[i]);
  CeCallKey ck;
  if (cacheable) {
    memset(&ck, 0, sizeof ck);
    ck.m = fm;
    ck.fn = fnode;
    ck.nargs = (uint8_t)nargs;
    for (uint32_t i = 0; i < nargs; i++) {
      ck.kinds[i] = args[i].kind;
      ck.bits[i] = args[i].as.i; // float bits alias through the union
    }
    CeCallHit hit;
    if (ce->calls && CeCallMap_get(&ce->calls->map, ck, &hit)) {
      *nrets = hit.nrets;
      for (uint8_t i = 0; i < hit.nrets; i++)
        rets[i] = hit.rets[i];
      return true;
    }
  }
  g.env = ce_obj_new(ce, 0);
  if (!g.env)
    return false;
  const NodeId *const pids = ast_list(fa, params);
  for (uint32_t i = 0; i < nargs; i++) {
    ModuleId wm = fm;
    TypeId wt = ce_type(fa, ast_at_const(fa, pids[i])->as.parameter.type);
    CeVal v = args[i];
    if (ce_rtype(ce, &g, fm, wt, &wm, &wt))
      v = ce_coerce(ce, v, wm, wt);
    if (v.kind == CV_NIL_K || !ce_bind(ce, &g, pids[i], v))
      return false;
  }
  ce->nframes++;
  const unsigned saved = ce->depth; // expression nesting is per-frame; CE_MAX_FRAMES caps the total
  ce->depth = 0;
  int st;
  if (closure && fn->as.closure.expr_body) {
    const CeVal v = ev_in(ce, &g, fm, body);
    st = v.kind == CV_NIL_K ? X_BAIL : X_RETURN;
    g.rets[0] = v;
    g.nrets = 1;
    g.returned = 1;
  } else {
    st = exec_stmt(ce, &g, fm, body);
  }
  ce->depth = saved;
  ce->nframes--;
  if (st == X_BAIL || st == X_BREAK || st == X_CONTINUE)
    return false;
  uint32_t wantret = closure ? 1 : fn->as.function.returns.len;
  if (wantret == 1 && !closure) { // an explicit `void` return type still lists one entry
    const NodeId r0 = ast_list(fa, fn->as.function.returns)[0];
    if (type_builtin(fa, ce_type(fa, r0)) == BT_VOID)
      wantret = 0;
  }
  if (!g.returned) {
    if (wantret > 0 && st != X_RETURN)
      return false; // fell off the end of a value-returning body
    g.nrets = 0;
  }
  *nrets = g.nrets;
  for (uint8_t i = 0; i < g.nrets; i++)
    rets[i] = g.rets[i];
  if (cacheable && g.nrets <= 8) { // scalar results hold for the whole compile
    bool pure = true;
    for (uint8_t i = 0; pure && i < g.nrets; i++)
      pure = cv_is_scalar(g.rets[i]);
    if (pure) {
      if (!ce->calls)
        ce->calls = calloc(1, sizeof *ce->calls);
      if (ce->calls && ce->calls->map.len < CE_CALLS_MAX) {
        CeCallHit hit = {.nrets = g.nrets};
        for (uint8_t i = 0; i < g.nrets; i++)
          hit.rets[i] = g.rets[i];
        CeCallMap_insert(&ce->calls->map, ck, hit);
      }
    }
  }
  return true;
}

static bool ce_call(ConstEval *ce, CeFrame *f, const ModuleId m, const NodeId id, CeVal rets[8], uint8_t *nrets) {
  const Ast *const a = ce_ast(ce, m);
  const Node *const n = ast_at_const(a, id);
  NodeId callee = n->as.call.callee;
  const Node *cn = ast_at_const(a, callee);
  if (cn->kind == NODE_GENERIC_SPECIALIZATION) { // `foo::<T>(..)`: the turbofish rides the callee
    callee = cn->as.specialization.expression;
    cn = ast_at_const(a, callee);
  }
  const NodeId *const aids = ast_list(a, n->as.call.args);
  const uint32_t nargs = n->as.call.args.len;
  if (nargs + 1 > 8)
    return false;
  *nrets = 0;

  // resolve the callee
  DefId fd = {0, NODE_NONE};
  NodeId recv_expr = NODE_NONE; // a method receiver
  const DerefUse *du = NULL;    // the typechecker's recorded auto-deref chain (consumed verbatim)
  bool have_recv_type = false;
  DefId recv_syn = {0, NODE_NONE}; // a path receiver that is a bare TYPE name (no cached TypeId)
  ModuleId rtm = 0;
  TypeId rtt = TYPE_NONE;
  if (cn->kind == NODE_IDENTIFIER) {
    fd = ast_resolution_def(a, callee);
    if (fd.node == NODE_NONE)
      fd = (DefId){m, ast_resolution(a, callee)};
    if (fd.node != NODE_NONE && fd.module < ce->nmods &&
        ast_at_const(ce_ast(ce, fd.module), fd.node)->kind != NODE_FUNCTION) {
      const CeVal v = ev_rval(ce, f, m, callee); // a local/const holding a fn value
      if (v.kind != CV_FN)
        return false;
      fd = (DefId){v.as.fnv.m, v.as.fnv.fn};
    }
  } else if (cn->kind == NODE_MEMBER) {
    fd = ast_resolution_def(a, callee);
    if (fd.node == NODE_NONE)
      fd = ast_resolution_def(a, cn->as.member.member);
    if (cn->as.member.path) {
      if (cn->as.member.object != NODE_NONE && ce_type(a, cn->as.member.object) != TYPE_NONE) {
        have_recv_type = true;
        rtm = m;
        rtt = ce_type(a, cn->as.member.object);
      } else if (cn->as.member.object != NODE_NONE) {
        recv_syn = ast_resolution_def(a, cn->as.member.object); // a bare type name: `A::default()`
        if (recv_syn.node == NODE_NONE)
          recv_syn = (DefId){m, ast_resolution(a, cn->as.member.object)};
      }
    } else {
      recv_expr = cn->as.member.object;
      have_recv_type = true;
      rtm = m;
      rtt = ce_type(a, recv_expr);
      du = ast_deref_use_at(a, cn->as.member.member);
      if (fd.node == NODE_NONE) { // the `.free()` intrinsic: no-op unless the concrete type is Free
        const Span mname = ast_at_const(a, cn->as.member.member)->as.name.text;
        if (!ce_span_is(ce, m, mname, "free") || nargs != 0)
          return false;
        CeRecv r;
        ModuleId sm;
        TypeId st;
        if (!ce_strip_refptr(ce, f, rtm, rtt, &sm, &st) || !ce_recv_of(ce, f, sm, st, &r))
          return false;
        if (r.dn == NODE_NONE)
          return true; // a scalar owns nothing
        NodeId extend = NODE_NONE;
        const DefId md = ce_find_method(ce, &r, m, 0, (Span){0}, "free", &extend);
        if (md.node == NODE_NONE)
          return true; // no Free conformance: no-op
        CeVal recv;
        if (!ev_place(ce, f, m, recv_expr, &recv)) {
          const CeVal rv = ev_in(ce, f, m, recv_expr);
          if (rv.kind == CV_PTR)
            recv = rv;
          else if (rv.kind == CV_NIL_K || !ce_temp_place(ce, rv, &recv))
            return false;
        }
        return ce_invoke(ce, md.module, md.node, extend, &r, NULL, NULL, 0, &recv, 1, 0, NODE_NONE, 0, TYPE_NONE,
                         rets, nrets);
      }
    }
  } else {
    return false;
  }
  if (fd.node == NODE_NONE || fd.module >= ce->nmods)
    return false;
  const Ast *fa = ce_ast(ce, fd.module);
  const Node *fn = ast_at_const(fa, fd.node);

  // enum variant construction: Some(x)
  if (fn->kind == NODE_VARIANT) {
    NodeId edecl = NODE_NONE;
    const int pos = ce_variant_pos(ce, fd.module, fd.node, &edecl);
    if (pos < 0 || !ce_enum_tagged(ce, fd.module, edecl))
      return false;
    if (fn->as.variant.payload.len != nargs)
      return false;
    const uint32_t o = ce_obj_new(ce, 1 + nargs);
    if (!o)
      return false;
    {
      CeObj *const eo = ce_obj(ce, o);
      eo->is_enum = 1;
      eo->dm = fd.module;
      eo->dn = edecl;
      eo->slots[0] = (CeVal){.kind = CV_INT, .tm = 0, .type = TYPE_NONE, .as.i = pos};
    }
    for (uint32_t i = 0; i < nargs; i++) {
      const CeVal v = ev_in(ce, f, m, aids[i]);
      if (v.kind == CV_NIL_K)
        return false;
      CeObj *const eo = ce_obj(ce, o);
      eo->slots[1 + i] = ce_clone(ce, v, 0);
      if (eo->slots[1 + i].kind == CV_NIL_K)
        return false;
    }
    rets[(*nrets)++] = (CeVal){.kind = CV_AGG, .tm = m, .type = ce_type(a, id), .as.p = {o, 0}};
    return true;
  }
  if (fn->kind != NODE_FUNCTION && fn->kind != NODE_CLOSURE)
    return false;

  // an interface method resolves against the CONCRETE receiver (bound dispatch, monomorphized here)
  CeRecv recv_id;
  bool have_recv_id = false;
  if (have_recv_type) {
    ModuleId sm;
    TypeId st;
    // An auto-deref'd call's dispatch identity (extend-generic binding) is the chain's FINAL type.
    if (ce_strip_refptr(ce, f, rtm, du ? du->target : rtt, &sm, &st))
      have_recv_id = ce_recv_of(ce, f, sm, st, &recv_id);
  } else if (recv_syn.node != NODE_NONE && recv_syn.module < ce->nmods) {
    const Node *const od = ast_at_const(ce_ast(ce, recv_syn.module), recv_syn.node);
    if (od->kind == NODE_GENERIC_PARAM && f) { // `A::default()` inside a generic body
      for (uint8_t i = 0; i < f->ng; i++)
        if (f->pmod == recv_syn.module && f->params_g[i] == recv_syn.node) {
          have_recv_id = ce_recv_of(ce, NULL, f->am[i], f->at[i], &recv_id);
          break;
        }
    } else if (od->kind == NODE_STRUCT || od->kind == NODE_ENUM) { // `Pt::make(..)` / `Vector::new()`
      memset(&recv_id, 0, sizeof recv_id);
      recv_id.dm = recv_syn.module;
      recv_id.dn = recv_syn.node;
      recv_id.b = BT_COUNT;
      have_recv_id = true; // n == 0: a generic type's args then come from the call's mono record
    }
  }
  NodeId container = NODE_NONE;
  int ckind = fn->kind == NODE_CLOSURE ? 0 : ce_container_of(ce, fd.module, fd.node, &container);
  ModuleId self_pm = 0; // an interface DEFAULT body runs with `Self` bound to the receiver
  NodeId self_decl = NODE_NONE;
  ModuleId self_am = 0;
  TypeId self_at = TYPE_NONE;
  if (ckind == 2) { // re-dispatch through the concrete type
    if (!have_recv_id)
      return false;
    const Span mname = ast_at_const(fa, fn->as.function.name)->as.name.text;
    NodeId extend = NODE_NONE;
    const DefId md = ce_find_method(ce, &recv_id, m, fd.module, mname, NULL, &extend);
    if (md.node != NODE_NONE) {
      fd = md;
      fa = ce_ast(ce, fd.module);
      fn = ast_at_const(fa, fd.node);
      container = extend;
      ckind = 1;
    } else if (fn->as.function.body != NODE_NONE) {
      // no impl: the interface's default body, with Self = the receiver (single-pool types only)
      self_at = recv_id.dn == NODE_NONE ? ast_builtin(recv_id.b)
                : recv_id.n == 0        ? ce_pool_find_type(ce, recv_id.dm, recv_id.dn)
                                        : TYPE_NONE; // a generic instance has no one-pool TypeId
      if (self_at == TYPE_NONE)
        return false;
      self_am = recv_id.dn == NODE_NONE ? 0 : recv_id.dm;
      self_pm = fd.module;
      self_decl = container; // `Self` lowers to TYPE_GENERIC{module, decl = the interface node}
      ckind = 0;
    } else {
      return false;
    }
  }

  // extern: intercept the modeled runtime, refuse everything else
  if (fn->kind == NODE_FUNCTION && fn->as.function.is_extern) {
    CeVal argv[8];
    for (uint32_t i = 0; i < nargs; i++) {
      argv[i] = ev_rval(ce, f, m, aids[i]);
      if (argv[i].kind == CV_NIL_K)
        return false;
    }
    return ce_intercept(ce, fd.module, fn, argv, nargs, m, id, rets, nrets);
  }

  // arguments; a method's receiver is parameter 0
  CeVal argv[9];
  uint32_t na = 0;
  const NodeList params = fn->kind == NODE_CLOSURE ? fn->as.closure.params : fn->as.function.params;
  if (recv_expr != NODE_NONE) {
    if (params.len != nargs + 1)
      return false;
    const NodeId p0 = ast_list(fa, params)[0];
    const TypeId p0t = ce_type(fa, ast_at_const(fa, p0)->as.parameter.type);
    const bool want_ref = p0t != TYPE_NONE && ast_type_at(fa, p0t)->kind == TYPE_REFERENCE;
    if (want_ref || du) { // an auto-deref chain always starts from the wrapper's address
      ModuleId sm;
      TypeId st;
      const bool recv_is_ptr = ce_rtype(ce, f, m, rtt, &sm, &st) &&
                               (ast_type_at(ce_ast(ce, sm), st)->kind == TYPE_REFERENCE ||
                                ast_type_at(ce_ast(ce, sm), st)->kind == TYPE_POINTER);
      if (recv_is_ptr) {
        argv[na] = ev_in(ce, f, m, recv_expr);
        if (argv[na].kind != CV_PTR)
          return false;
      } else if (!ev_place(ce, f, m, recv_expr, &argv[na])) {
        const CeVal rv = ev_in(ce, f, m, recv_expr); // a temporary receiver
        if (rv.kind == CV_NIL_K || !ce_temp_place(ce, rv, &argv[na]))
          return false;
      }
    } else {
      argv[na] = ev_rval(ce, f, m, recv_expr);
      if (argv[na].kind == CV_NIL_K)
        return false;
    }
    if (du) { // walk the recorded auto-deref chain: each hop's deref call yields the next receiver pointer
      for (uint8_t i = 0; i < du->n; i++) {
        CeRecv hr;
        NodeId hext = NODE_NONE;
        if (!ce_recv_of(ce, f, m, du->recv[i], &hr) ||
            ce_container_of(ce, du->method[i].module, du->method[i].node, &hext) != 1)
          return false;
        CeVal hret[8];
        uint8_t hn = 0;
        if (!ce_invoke(ce, du->method[i].module, du->method[i].node, hext, &hr, NULL, NULL, 0, &argv[na], 1, 0,
                       NODE_NONE, 0, TYPE_NONE, hret, &hn) ||
            hn != 1 || hret[0].kind != CV_PTR)
          return false;
        argv[na] = hret[0];
      }
      // a by-value final self (a scalar pointee, `boxed_int.abs()`): copy out of the last pointer
      if (!want_ref && !ce_loadp(ce, argv[na], &argv[na]))
        return false;
    }
    na++;
  } else if (params.len != nargs) {
    return false;
  }
  for (uint32_t i = 0; i < nargs; i++) {
    argv[na] = ev_in(ce, f, m, aids[i]);
    if (argv[na].kind == CV_NIL_K)
      return false;
    na++;
  }

  // the generic args recorded on the call, best-effort resolved concrete through the calling frame
  // (ce_invoke only requires the slots it actually consumes)
  ModuleId monom[4];
  TypeId monot[4];
  uint8_t nmono = 0;
  const MonoUse *const mu = ast_type_args(a, id);
  if (mu)
    for (uint8_t i = 0; i < mu->n && i < 4; i++) {
      monom[nmono] = m;
      monot[nmono] = ce_subst_deep(ce, f, m, mu->args[i], 0);
      nmono++;
    }

  return ce_invoke(ce, fd.module, fd.node, ckind == 1 ? container : NODE_NONE, have_recv_id ? &recv_id : NULL,
                   monom, monot, nmono, argv, na, self_pm, self_decl, self_am, self_at, rets, nrets);
}

// --- the public boundary ------------------------------------------------------------------------

static ConstValue cv_pub(const CeVal v) {
  switch (v.kind) {
    case CV_INT:
      return (ConstValue){.kind = CONST_INT, .type = v.type, .i = v.as.i};
    case CV_BOOL:
      return (ConstValue){.kind = CONST_BOOL, .type = v.type, .i = v.as.i};
    case CV_FLOAT:
      if (!isfinite(v.as.f))
        return CE_NONE; // inf/nan have no portable C literal: stay runtime
      return (ConstValue){.kind = CONST_FLOAT, .type = v.type, .f = v.as.f};
    default:
      return CE_NONE; // aggregates/pointers never escape the interpreter
  }
}

ConstValue consteval_eval(ConstEval *ce, const ModuleId m, const NodeId id) {
  if (!ce || id == NODE_NONE || m >= ce->nmods)
    return CE_NONE;
  ConstValue *const slot = ce_slot(ce, m, id);
  if (!slot)
    return CE_NONE;
  if (slot->kind != CONST_NONE)
    return *slot; // memoized (CONST_NONE misses re-evaluate; they terminate identically)
  if (ce->depth > CE_MAX_DEPTH)
    return CE_NONE;
  const bool top = ce->depth == 0 && ce->nframes == 0;
  if (top) { // a fresh top-level evaluation: fresh budgets, no stale trap, empty store
    ce->steps = 0;
    ce->trap = NULL;
    ce_objs_reset(ce);
  }
  ce->depth++;
  const CeVal v = ev(ce, NULL, m, id);
  ce->depth--;
  const ConstValue pub = cv_pub(v);
  if (top)
    ce_objs_reset(ce); // interpreter storage never outlives one top-level evaluation
  if (pub.kind != CONST_NONE)
    *slot = pub;
  return pub;
}
