#include "consteval/consteval.h"
#include "typechecker.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "module/loader.h"
#include "types/hashmap.h"

// A live borrow of a place, for the borrow checker (single-threaded aliasing rules). `root` is the borrowed
// place's root binding decl (a `let`/parameter/pattern-name); `place` is the borrowed place expression
// itself (field-precise overlap checks decompose it). `origin` is the expression to blame in diagnostics
// (the `&`/`&mut` node, or a method receiver whose call returns a reference) -- borrow checking is
// intraprocedural, so both always resolve in the current module's AST. `binding` is the reference binding
// this borrow is stored in (`r` in `let r = &x`) or NODE_NONE for a temporary; it drives NLL -- the borrow
// ends at its binding's last use, not at scope exit. `region` is the BINDING's block-scope depth (creation
// depth for a temporary), the lexical fallback drop point. Kind: shared (`&`) vs mutable (`&mut`).
enum { BORROW_SHARED = 0, BORROW_MUT = 1 };
typedef struct {
  NodeId root;
  NodeId place;
  NodeId origin;
  NodeId binding;
  uint16_t region;
  uint8_t kind;
} Borrow;

// Binding decl NodeId -> lexical scope depth at declaration. Drives a stored borrow's region (it must die
// with its BINDING's scope, not the scope the `&` happened in) and the does-not-live-long-enough check at
// scope exit (a root dying in a scope its borrower outlives).
static inline size_t tc_nodeid_hash(const NodeId k) {
  return (size_t)k * 0x9E3779B1u;
}
#define TC_NODEID_EQ(a, b) ((a) == (b))
HM_DECLARE(NodeId, uint32_t, TcDepthMap)
HM_DEFINE(NodeId, uint32_t, TcDepthMap, tc_nodeid_hash, TC_NODEID_EQ)

struct TypeChecker {
    Ast *ast;
    const uint8_t *source;
    size_t len;
    NodeList current_returns; // the enclosing function's `returns` list, for NODE_RETURN checking
    NodeId current_self;      // the struct decl whose `extend` we are inside (NODE_NONE at top level)
    NodeId current_extend;      // the enclosing NODE_EXTEND, so a bare `Self` lowers to its full target type
                              // (`Wrap<T>`), not the bare struct -- otherwise generic field access loses the args
    NodeId current_fn;        // the function decl being checked, for `where`-clause bound lookup (NODE_NONE if none)
    NodeId clos_stack[8];     // the NODE_CLOSUREs whose bodies are being checked, innermost last: a
    uint32_t nclos;           // mutated capture is recorded (as `&mut`) on EVERY enclosing closure
    const Package *package;   // to follow imported decls into their origin module (NULL = no imports)
    unsigned alias_depth;     // type-alias expansion depth, bounded so a cyclic alias diagnoses instead of recursing forever
    TypeId expected;          // target type of the expression being checked (let annotation / return / assignment RHS), or TYPE_NONE; consumed once by check_expr
    NodeId moved[256];        // Free-typed bindings moved out of the current function; using one again is an error
    uint32_t nmoved;          // (reset per function; best-effort linear move/use-after-move analysis)
    NodeId uninit[64];        // deferred-init bindings (`let mut x: T;`) not yet assigned on the current path
    uint32_t nuninit;         // (definite-initialization: reading one is an error; assigning it clears it)
    NodeId freed[64];         // bindings consumed by an explicit `.free()` -- using one is a use-after-free
    uint32_t nfreed;          // (vs an ordinary move; flavors the diagnostic, the `moved` set gates it)
    Borrow borrows[64];       // live `&`/`&mut` borrows on the current path; the aliasing rule is checked
    uint32_t nborrows;        // against these (borrow checker); reset per function, part of the flow state
    uint32_t scope_depth;     // lexical block nesting; a borrow is dropped when its binding's scope exits
    uint32_t loop_depth;      // inside a loop condition/body: node-id order no longer implies execution
                              // order (back edges), so last-use borrow expiry is disabled there
    TcDepthMap binding_depth; // binding decl -> its declaring scope depth (params are depth 0)
    NodeId defer_stack[256];  // pending `defer` expressions, replayed (LIFO) at their block's close so
    uint32_t defer_depth[256];// their moves/frees apply where they EXECUTE, not where they are written
    uint32_t ndefers;
    bool in_loop_recheck;     // re-checking a loop body for back-edge use-after-move; bounds nested re-checks
    bool place_use;           // the expression is the base of an enclosing place whose read-borrow check has
                              // already run (`x` in a read of `x.f`); suppresses its own whole-value read check
    bool addr_ctx;            // the expression being checked is a place under address-of (&/&mut): its base is
                              // borrowed, not value-read, so the definite-init read check is suppressed for it
    NodeId mret_call;         // the multi-return CALL whose element types are stashed below (check_call ->
    TypeId mret_types[8];     // check_tuple_let), already substituted with the call's generic/instance args;
    uint8_t mret_n;           // stashed element count (capped at 8; the rest fall back to the raw decl types)
    uint32_t mret_total;      // the callee's true return count, for the binding-arity check
    uint32_t unsafe_depth;    // > 0 inside `unsafe { .. }` / `unsafe expr`: raw-pointer operations and
                              // extern "C" calls are only legal there (the compiler cannot vouch for them)
    struct {
        Span label;      // the loop's `'name:` label ({0,0} = unlabeled); text includes the quote
        NodeId node;     // the loop node (break/continue record it as their resolution for codegen)
        TypeId break_ty; // unified `break <expr>` type (TYPE_NONE until the first value break)
        bool value_loop; // a condition-less `loop`: the only loop `break <expr>` may target
        bool saw_value;  // >= 1 `break <expr>` targeted this loop
        bool saw_bare;   // >= 1 bare `break` targeted this loop (mixing with value breaks is an error)
    } loop_stack[32];    // enclosing loops, innermost last (per function; closures reset the floor)
    uint32_t nloops;
    uint32_t loop_floor;      // break/continue may only target entries >= this (a closure body starts fresh)
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
static TypeId prelude_tuple_type(TypeChecker *t, const TypeId *args, uint32_t n);
static int slice_kind(TypeChecker *t, TypeId tid, TypeId *elem);
static bool is_assignable(TypeChecker *t, NodeId node);
static bool is_place(TypeChecker *t, NodeId node);
static void check_loop_body(TypeChecker *t, NodeId body);
// bind_ref: 0 = value (owned/move) bindings; 1 = `&T` bindings (matching `&Self`); 2 = `&mut T` bindings.
static void check_pattern(TypeChecker *t, NodeId id, TypeId expected, int bind_ref);
static void render_type(TypeChecker *t, TypeId tid, char *buf, size_t cap);
static TypeId check_member(TypeChecker *t, const Node *n, bool prefer_method);
static TypeId subst_type(TypeChecker *t, TypeId ty, const DefId *params, const TypeId *args, int n);
static bool aggregate_of(TypeChecker *t, TypeId ty, ModuleId *mod, NodeId *decl, DefId *params, TypeId *args, int *n);
static bool dyn_coerce(TypeChecker *t, NodeId node, TypeId src, TypeId dyn_ty);
static bool tc_box_of(TypeChecker *t, const Ty *y, TypeId *inner, bool *global_alloc);
static bool fn_compatible_subst(TypeChecker *t, TypeId exid, TypeId acid, const DefId *gp, const TypeId *ga, int gn,
                                const DefId *rp, const TypeId *ra, int rn);
static TypeId tc_intern_dynfn(TypeChecker *t, ModuleId m, NodeId sig, TypeQualifier qual);

// The TYPE_FUNCTION signature behind a `dyn fn(..) ..` (TYPE_NONE when the dyn wraps an interface).
static TypeId tc_dyn_fn_sig(TypeChecker *t, const Ty *const y) {
  if (y->kind != TYPE_DYN)
    return TYPE_NONE;
  if (ast_at_const(mod_ast(t, y->module), y->as.decl)->kind != NODE_FUNCTION_TYPE)
    return TYPE_NONE;
  return lower_type_in(t, y->module, y->as.decl);
}

TypeChecker *typechecker_new(Ast *ast, const char *source, const size_t len, const Package *package) {
  TypeChecker *const t = calloc(1, sizeof *t);
  if (!t)
    oom();
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
  TcDepthMap_deinit(&(*t)->binding_depth);
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

// The largest magnitude a suffixed literal of type `b` may spell (signed max: `-min` needs a cast), or
// 0 for the two full-range 64-bit types (no check needed; the u64 overflow scan already ran).
static uint64_t bt_int_max(const BuiltinType b) {
  switch (b) {
    case BT_I8: return INT8_MAX;
    case BT_I16: return INT16_MAX;
    case BT_I32: return INT32_MAX;
    case BT_I64: case BT_ISIZE: return INT64_MAX;
    case BT_U8: return UINT8_MAX;
    case BT_U16: return UINT16_MAX;
    case BT_U32: return UINT32_MAX;
    default: return 0; // u64/usize (and non-int suffixes never reach here)
  }
}

// Implicit LOSSLESS numeric widening: same-signedness to a strictly wider integer, unsigned to a
// strictly wider signed integer, and f32 -> f64. usize/isize stay explicit (platform-width), as do
// narrowing, same-width sign changes, and int<->float (`as`).
ALWAYS_INLINE bool bt_widens(const BuiltinType from, const BuiltinType to) {
  if (from == BT_F32 && to == BT_F64)
    return true;
  const bool fs = from >= BT_I8 && from <= BT_I64, fu = from >= BT_U8 && from <= BT_U64;
  const bool ts = to >= BT_I8 && to <= BT_I64, tu = to >= BT_U8 && to <= BT_U64;
  if (!(fs || fu) || !(ts || tu))
    return false;
  const int fw = fs ? from - BT_I8 : from - BT_U8, tw = ts ? to - BT_I8 : to - BT_U8; // 0..3 = 8..64 bits
  return fu ? tw > fw : (ts && tw > fw); // u<N> fits any strictly wider slot; i<N> only a wider signed one
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

// Push an enclosing loop for break/continue targeting; returns its stack index (fixed while nested
// loops push above it), or -1 when the nesting limit is hit (further break checks degrade gracefully).
static int tc_loop_push(TypeChecker *t, const Span label, const NodeId node, const bool value_loop) {
  if (t->nloops >= sizeof t->loop_stack / sizeof t->loop_stack[0])
    return -1;
  t->loop_stack[t->nloops].label = label;
  t->loop_stack[t->nloops].node = node;
  t->loop_stack[t->nloops].break_ty = TYPE_NONE;
  t->loop_stack[t->nloops].value_loop = value_loop;
  t->loop_stack[t->nloops].saw_value = false;
  t->loop_stack[t->nloops].saw_bare = false;
  return (int)t->nloops++;
}

// Pop entry `le`, diagnosing a value-yielding loop that also has a bare `break` (its type would be
// undefined on that path).
static void tc_loop_pop(TypeChecker *t, const int le, const Span sp) {
  if (le < 0)
    return;
  if (t->loop_stack[le].saw_value && t->loop_stack[le].saw_bare)
    typechecker_errorf(t, sp.start, sp.end - sp.start,
                       "every 'break' in a value-yielding 'loop' must carry a value");
  t->nloops = (uint32_t)le;
}

// The loop a break/continue targets: `'name` -> the innermost matching entry, bare -> the innermost.
// Entries below loop_floor belong to an outer function/closure and are unreachable. -1 = no target.
static int tc_find_loop(TypeChecker *t, const Span label) {
  for (uint32_t i = t->nloops; i > t->loop_floor; i--) {
    const uint32_t k = i - 1;
    if (label.end == label.start)
      return (int)k;
    const Span ls = t->loop_stack[k].label;
    if (ls.end - ls.start == label.end - label.start &&
        memcmp(t->source + ls.start, t->source + label.start, ls.end - ls.start) == 0)
      return (int)k;
  }
  return -1;
}

static BuiltinType bt_of(const TypeChecker *t, const TypeId x) {
  const Ty *const y = ast_type_at(t->ast, x);
  return y->kind == TYPE_BUILTIN ? y->as.builtin : BT_COUNT;
}

// A numeric literal whose type suffix pins it: it never adapts to a context type (only widens).
static bool tc_literal_pinned(const TypeChecker *t, const Node *n) {
  return n->kind == NODE_LITERAL &&
         (n->as.literal.token_type == IntegerLiteral || n->as.literal.token_type == FloatLiteral) &&
         ast_numeric_suffix(t->source, n->as.literal.raw.start, n->as.literal.raw.end, NULL) != BT_COUNT;
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

static unsigned hex_digit(const uint8_t c) { return c <= '9' ? (unsigned)(c - '0') : (unsigned)((c | 0x20) - 'a' + 10); }

// The Unicode scalar of a character-literal source span (between the quotes): a raw byte/UTF-8 scalar, or a
// `\xNN` / `\u{..}` escape. `char` is one C byte, so the type checker rejects a scalar above 0xFF here.
static uint32_t char_literal_cp(const uint8_t *const src, const Span s) {
  size_t i = s.start + 1; // past the opening quote
  if (i >= s.end)
    return 0;
  if (src[i] != '\\') {
    const uint8_t b = src[i];
    if (b < 0x80)
      return b;
    if (b <= 0xDF)
      return ((uint32_t)(b & 0x1F) << 6) | (src[i + 1] & 0x3F);
    if (b <= 0xEF)
      return ((uint32_t)(b & 0x0F) << 12) | ((uint32_t)(src[i + 1] & 0x3F) << 6) | (src[i + 2] & 0x3F);
    return ((uint32_t)(b & 0x07) << 18) | ((uint32_t)(src[i + 1] & 0x3F) << 12) | ((uint32_t)(src[i + 2] & 0x3F) << 6) |
           (src[i + 3] & 0x3F);
  }
  i++; // past backslash
  const uint8_t e = src[i++];
  if (e == 'x')
    return ((uint32_t)hex_digit(src[i]) << 4) | hex_digit(src[i + 1]);
  if (e == 'u') {
    if (i < s.end && src[i] == '{')
      i++;
    uint32_t cp = 0;
    while (i < s.end && src[i] != '}')
      cp = (cp << 4) | hex_digit(src[i++]);
    return cp;
  }
  return 0; // simple escapes (\n, \t, \\, ...) are all < 0x80
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
    case TYPE_NEVER:
      snprintf(buf, cap, "never");
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
    case TYPE_DYN: {
      Ast *const a = mod_ast(t, ty->module);
      const char *const pfx = ty->qualifier == TYPE_QUAL_MUT    ? "&mut dyn "
                              : ty->qualifier == TYPE_QUAL_CONST ? "&dyn "
                                                                  : "Box<dyn ";
      const char *const sfx = ty->qualifier == TYPE_QUAL_NONE ? ">" : "";
      if (ast_at_const(a, ty->as.decl)->kind == NODE_FUNCTION_TYPE) {
        snprintf(buf, cap, "%sfn(..) ..%s", pfx, sfx);
        break;
      }
      const Span s = ast_at_const(a, ast_at_const(a, ty->as.decl)->as.interface_def.name)->as.name.text;
      snprintf(buf, cap, "%s%.*s%s", pfx, (int)(s.end - s.start), (const char *)mod_src(t, ty->module) + s.start, sfx);
      break;
    }
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

// An operation the compiler cannot vouch for (raw-pointer memory access / extern "C" call) outside
// an `unsafe` context. The borrow checker's guarantees stop at these; the block is the audit marker.
static void err_unsafe(TypeChecker *t, const Span sp, const char *const what) {
  typechecker_errorf(t, sp.start, sp.end - sp.start, "%s requires an 'unsafe' block", what);
  typechecker_notef(t, "wrap the operation in 'unsafe { ... }' or prefix the expression with 'unsafe'");
}

// The package's opt-in const evaluator (--const-eval), or NULL: every consumer below degrades to
// today's delegate-to-C behavior when it is absent.
static ConstEval *tc_ceval(const TypeChecker *t) {
  return t->package ? t->package->ceval : NULL;
}

// Find a `@c.*` attribute of `kind` on item `owner` in module `mod`, or NULL (mirrors codegen's
// cg_attr; attributes are few, so a linear scan of the owning module's table is cheap).
static const Attr *tc_attr(TypeChecker *t, const ModuleId mod, const NodeId owner, const AttrKind kind) {
  const Ast *const a = mod_ast(t, mod);
  for (size_t i = 0; i < a->attrs.len; i++)
    if (a->attrs.data[i].owner == owner && a->attrs.data[i].kind == kind)
      return &a->attrs.data[i];
  return NULL;
}

// `move` / `unsafe` prefixes are transparent wrappers around their operand: every place-shaped
// analysis (assignability, place tests, borrow decomposition) sees through them.
static NodeId peel_wrappers(const TypeChecker *t, NodeId id) {
  const Node *n = ast_at_const(t->ast, id);
  while (n->kind == NODE_UNARY && (n->as.unary.op == Move || n->as.unary.op == Unsafe)) {
    id = n->as.unary.operand;
    n = ast_at_const(t->ast, id);
  }
  return id;
}

// Does this type reach memory through a RAW-POINTER layer (`*T`, possibly under references)?
// Reference layers alone are borrow-checked and safe; any `*` layer is not.
static bool through_raw_pointer(TypeChecker *t, TypeId ty) {
  const Ty *y = ast_type_at(t->ast, ty);
  while (y->kind == TYPE_REFERENCE || y->kind == TYPE_POINTER) {
    if (y->kind == TYPE_POINTER)
      return true;
    ty = y->as.elem;
    y = ast_type_at(t->ast, ty);
  }
  return false;
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

static bool receiver_type_eq(TypeChecker *t, const TypeId a, const TypeId b) {
  if (a == b)
    return true;
  const Ty *const at = ast_type_at(t->ast, a);
  const Ty *const bt = ast_type_at(t->ast, b);
  const bool ap = at->kind == TYPE_POINTER || at->kind == TYPE_REFERENCE;
  const bool bp = bt->kind == TYPE_POINTER || bt->kind == TYPE_REFERENCE;
  return ap && bp && at->qualifier == bt->qualifier && at->as.elem == bt->as.elem;
}

// The `fn(..) ..` bound on a generic param decl (module `m`), or NODE_NONE. Such a bound makes the
// param CALLABLE with the bound's signature, and is satisfied by any matching function value --
// a named fn, a `fn(..) ..` pointer, or a (capturing) closure.
static NodeId generic_fn_bound(TypeChecker *t, const ModuleId m, const NodeId decl) {
  Ast *const a = mod_ast(t, m);
  const Node *const gp = ast_at_const(a, decl);
  if (gp->kind != NODE_GENERIC_PARAM)
    return NODE_NONE;
  const NodeId *const bids = ast_list(a, gp->as.generic_param.bounds);
  for (uint32_t i = 0; i < gp->as.generic_param.bounds.len; i++)
    if (ast_at_const(a, bids[i])->kind == NODE_FUNCTION_TYPE)
      return bids[i];
  // `where F: fn(..) ..` on the enclosing function binds the param too (same module only: a where
  // clause names its own function's params).
  if (t->current_fn != NODE_NONE && (!t->package || m == t->ast->module)) {
    const NodeList wc = ast_at_const(t->ast, t->current_fn)->as.function.where_clause;
    const NodeId *const wids = ast_list(t->ast, wc);
    for (uint32_t w = 0; w < wc.len; w++) {
      const Node *const wp = ast_at_const(t->ast, wids[w]);
      if (ast_resolution(t->ast, wp->as.where_predicate.type) != decl)
        continue;
      const NodeId *const wb = ast_list(t->ast, wp->as.where_predicate.bounds);
      for (uint32_t b = 0; b < wp->as.where_predicate.bounds.len; b++)
        if (ast_at_const(t->ast, wb[b])->kind == NODE_FUNCTION_TYPE)
          return wb[b];
    }
  }
  return NODE_NONE;
}

// True when `fid` (a TYPE_FUNCTION) is backed by a closure that captures locals: its runtime value is
// its environment struct, NOT a function pointer, so it never coerces into a bare `fn(..) ..` slot --
// it only satisfies an `F: fn(..) ..` generic bound (monomorphized per closure).
static bool fn_is_capturing(TypeChecker *t, const TypeId fid) {
  const Ty *const fy = ast_type_at(t->ast, fid);
  if (fy->kind != TYPE_FUNCTION)
    return false;
  const Node *const fn = ast_at_const(mod_ast(t, fy->module), fy->as.decl);
  return fn->kind == NODE_CLOSURE && fn->as.closure.captures.len != 0;
}

static bool tc_type_is_free(TypeChecker *t, TypeId ty);

// The position of `decl` in closure `clos`'s capture list, or -1. Captures are same-module locals,
// so a plain NodeId comparison suffices.
static int tc_capture_index(TypeChecker *t, const NodeId clos, const NodeId decl) {
  const NodeList caps = ast_at_const(t->ast, clos)->as.closure.captures;
  const NodeId *const cids = ast_list(t->ast, caps);
  for (uint32_t i = 0; i < caps.len; i++)
    if (cids[i] == decl)
      return (int)i;
  return -1;
}

// True when `fid` is a closure that OWNS a captured value: a Free-typed capture taken by copy MOVES
// into the env at creation, making the closure value itself Free (freed at scope exit, move-tracked).
// A MUTATED Free capture is a `&mut` borrow instead (bit set in mut_caps) -- the outer binding keeps
// ownership. Owning closures satisfy only `fn move(..) ..` bounds, so generic code move-tracks them.
static bool fn_owns(TypeChecker *t, const TypeId fid) {
  const Ty *const fy = ast_type_at(t->ast, fid);
  if (fy->kind != TYPE_FUNCTION)
    return false;
  Ast *const fa = mod_ast(t, fy->module);
  const Node *const fn = ast_at_const(fa, fy->as.decl);
  if (fn->kind != NODE_CLOSURE)
    return false;
  const NodeId *const cids = ast_list(fa, fn->as.closure.captures);
  for (uint32_t i = 0; i < fn->as.closure.captures.len; i++) // capture types live in the CLOSURE's pool
    if (!(fn->as.closure.mut_caps >> i & 1) && tc_type_is_free(t, ast_reintern(t->ast, fa, ast_type(fa, cids[i]))))
      return true;
  return false;
}

// Record that the body of every enclosing closure capturing the root binding of place `expr` MUTATES
// it: that capture switches to `&mut` (env holds a pointer; the write lands on the OUTER variable).
// A deref (`*p = ..`) stops the walk -- the mutation goes through the pointee, the binding is only read.
static void tc_mark_capture_mut(TypeChecker *t, NodeId expr) {
  if (!t->nclos)
    return;
  const Node *n = ast_at_const(t->ast, expr);
  for (;;) {
    if (n->kind == NODE_UNARY && (n->as.unary.op == Move || n->as.unary.op == Unsafe))
      expr = n->as.unary.operand;
    else if (n->kind == NODE_MEMBER && !n->as.member.path)
      expr = n->as.member.object;
    else if (n->kind == NODE_INDEX)
      expr = n->as.index.object;
    else
      break;
    n = ast_at_const(t->ast, expr);
  }
  if (n->kind != NODE_IDENTIFIER)
    return;
  const DefId d = ast_resolution_def(t->ast, expr);
  if (d.module != t->ast->module || d.node == NODE_NONE)
    return;
  for (uint32_t f = 0; f < t->nclos; f++) {
    const int idx = tc_capture_index(t, t->clos_stack[f], d.node);
    if (idx >= 0)
      ast_at(t->ast, t->clos_stack[f])->as.closure.mut_caps |= (uint64_t)1 << idx;
  }
}

// Two function types are compatible when their signatures match structurally (so a named function
// passes where a `fn(..) ..` pointer is expected, even though they intern to distinct Tys keyed on
// their decl node). C function-pointer types must match exactly, so params/return compare by identity.
static bool fn_compatible(TypeChecker *t, const TypeId exid, const TypeId acid) {
  if (exid != acid && fn_is_capturing(t, acid))
    return false; // a capturing closure's value is an env struct -- never a bare fn pointer
  TypeId ep[4], ap[4], er, ar;
  const int en = fn_sig(t, exid, ep, 4, &er), an = fn_sig(t, acid, ap, 4, &ar);
  if (en != an || en > 4 || !ret_eq(er, ar))
    return false;
  for (int i = 0; i < en; i++)
    if (ep[i] != ap[i])
      return false;
  return true;
}

// A dyn-fn erasure's signature check: fn_compatible WITHOUT the capturing/`fn move` gates -- a
// capturing closure's env rides the trait object itself (borrowed via `&f`, or heap-copied into a
// `Box<dyn fn>` that owns it), so the bound-tier ownership rules don't apply here.
static bool dynfn_sig_ok(TypeChecker *t, const TypeId exid, const TypeId acid) {
  TypeId ep[4], ap[4], er, ar;
  const int en = fn_sig(t, exid, ep, 4, &er), an = fn_sig(t, acid, ap, 4, &ar);
  if (en != an || en > 4 || !ret_eq(er, ar))
    return false;
  for (int i = 0; i < en; i++)
    if (ep[i] != ap[i])
      return false;
  return true;
}

// Are two trait-object types the SAME dyn? The `dyn fn` flavor compares SIGNATURES (fn types intern
// per node, so two annotations of one signature must still unify); interfaces compare by DefId.
static bool tc_dyn_same(TypeChecker *t, const Ty *const a, const Ty *const b) {
  const TypeId as = tc_dyn_fn_sig(t, a), bs = tc_dyn_fn_sig(t, b);
  if ((as != TYPE_NONE) != (bs != TYPE_NONE))
    return false;
  if (as != TYPE_NONE)
    return as == bs || fn_compatible(t, as, bs);
  return a->module == b->module && a->as.decl == b->as.decl;
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
  // A diverging expression (`panic(..)`, any `@c.noreturn` call) fits every slot: control never
  // returns to observe the value, so `switch o { Some(v) => v, None => panic("..") }` type-checks.
  if (ac->kind == TYPE_NEVER)
    return true;
  if (ex->kind == TYPE_POINTER && ac->kind == TYPE_REFERENCE && ex->as.elem == ac->as.elem &&
      (ac->qualifier == TYPE_QUAL_MUT || ex->qualifier == TYPE_QUAL_CONST))
    return true;
  // A mutable reference satisfies a shared-reference slot: `&mut T` -> `&T` (a reborrow; the stronger borrow
  // covers the weaker requirement). One-way only -- a shared `&T` never becomes `&mut T`.
  if (ex->kind == TYPE_REFERENCE && ac->kind == TYPE_REFERENCE && ex->as.elem == ac->as.elem &&
      ex->qualifier != TYPE_QUAL_MUT && ac->qualifier == TYPE_QUAL_MUT)
    return true;
  // Raw pointers of the same pointee, or ERASED into a void-pointer slot (`*mut T` -> `*mut void`:
  // a `*void` cannot be dereferenced, so erasing is harmless; the inventing direction
  // `*mut void` -> `*mut T` stays an explicit `as` cast). Qualifiers: a writable source
  // (`*T`/`*mut T`) fits any target; a `*const T` source fits only a `*const` target.
  if (ex->kind == TYPE_POINTER && ac->kind == TYPE_POINTER &&
      (ex->as.elem == ac->as.elem || ex->as.elem == ast_builtin(BT_VOID)) &&
      (ex->qualifier == TYPE_QUAL_CONST || ac->qualifier != TYPE_QUAL_CONST))
    return true;
  // A named function (or another fn pointer) fits a `fn(..) ..` slot when signatures match structurally.
  if (ex->kind == TYPE_FUNCTION && ac->kind == TYPE_FUNCTION)
    return fn_compatible(t, expected, actual);
  // Arrays compare by element: equal elements, or fn-typed elements that match structurally (a function
  // type is keyed on its decl, so `[fn(i32)i32]` from an annotation and from `[a, b]` are distinct TypeIds).
  if (ex->kind == TYPE_ARRAY && ac->kind == TYPE_ARRAY) {
    if (ex->as.arr.len && ac->as.arr.len && ex->as.arr.len != ac->as.arr.len)
      return false; // both lengths known and different (--const-eval); unknown (0) matches anything
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
  // ---- trait objects ----
  if (ex->kind == TYPE_DYN) {
    const TypeId exsig = tc_dyn_fn_sig(t, ex); // TYPE_NONE = interface flavor, else the `dyn fn` signature
    const Span sp = ast_at_const(t->ast, node)->span;
    // dyn == dyn: structural for `dyn fn`, DefId for interfaces; `&mut dyn I` weakens to `&dyn I`.
    if (ac->kind == TYPE_DYN)
      return tc_dyn_same(t, ex, ac) &&
             (ex->qualifier == ac->qualifier ||
              (ex->qualifier == TYPE_QUAL_CONST && ac->qualifier == TYPE_QUAL_MUT));
    // Borrowed flavors from an explicit `&`/`&mut`: an erasing reference, a reborrowed owned dyn, or
    // a borrowed closure (`&f` -> `&dyn fn(..) ..` -- the env stays on the creator's frame).
    if (ex->qualifier != TYPE_QUAL_NONE && ac->kind == TYPE_REFERENCE) {
      const Ty *const rel = ast_type_at(t->ast, ac->as.elem);
      if (rel->kind == TYPE_DYN) { // `&b` over `Box<dyn ..>`: layout-identical, codegen derefs
        if (rel->qualifier != TYPE_QUAL_NONE || !tc_dyn_same(t, ex, rel))
          return false;
        ast_add_dyn_use(t->ast, node, TYPE_NONE, expected);
        return true;
      }
      if (exsig != TYPE_NONE) {
        if (rel->kind != TYPE_FUNCTION || !dynfn_sig_ok(t, exsig, ac->as.elem))
          return false;
        ast_add_dyn_use(t->ast, node, ac->as.elem, expected);
        return true;
      }
      if (ex->qualifier == TYPE_QUAL_MUT && ac->qualifier != TYPE_QUAL_MUT)
        return false;
      return dyn_coerce(t, node, ac->as.elem, expected);
    }
    // A function VALUE erases to `dyn fn`: a named fn / non-capturing closure for any flavor (data
    // stays NULL); `Box<dyn fn ..>` additionally heap-copies a capturing closure's env (an OWNING
    // closure is Free, so the by-value move machinery already consumes it).
    if (exsig != TYPE_NONE && ac->kind == TYPE_FUNCTION) {
      if (ast_at_const(mod_ast(t, ac->module), ac->as.decl)->kind == NODE_FUNCTION_TYPE) {
        typechecker_errorf(t, sp.start, sp.end - sp.start,
                           "a runtime 'fn(..)' pointer cannot erase to 'dyn fn'; wrap it in a closure");
        return true; // reported
      }
      if (!dynfn_sig_ok(t, exsig, actual))
        return false;
      if (ex->qualifier != TYPE_QUAL_NONE && fn_is_capturing(t, actual)) {
        typechecker_errorf(t, sp.start, sp.end - sp.start,
                           "a capturing closure must be borrowed to view it as '&dyn fn': write '&f'");
        return true; // reported
      }
      ast_add_dyn_use(t->ast, node, actual, expected);
      return true;
    }
    // `Box<T>` erases to the OWNED trait object `Box<dyn I>`: a MOVE of the box (the by-value move
    // machinery already fires -- the source is a Free value in a move position). Only the default
    // allocator: a stateful allocator cannot live in the per-type const vtable whose drop glue frees.
    if (ex->qualifier == TYPE_QUAL_NONE && ac->kind == TYPE_INSTANCE && exsig == TYPE_NONE) {
      TypeId inner;
      bool galloc;
      if (tc_box_of(t, ac, &inner, &galloc)) {
        if (!galloc) {
          typechecker_errorf(t, sp.start, sp.end - sp.start,
                             "only a default-allocated 'Box<T>' can be erased to 'Box<dyn I>'");
          return true; // reported
        }
        return dyn_coerce(t, node, inner, expected);
      }
    }
    return false;
  }
  // Implicit lossless widening: `i32 -> i64`, `u8 -> u32`, `u16 -> i32`, `f32 -> f64`, ...
  if (ex->kind == TYPE_BUILTIN && ac->kind == TYPE_BUILTIN && bt_widens(ac->as.builtin, ex->as.builtin))
    return true;
  const Node *v = ast_at_const(t->ast, node);
  if (v->kind == NODE_UNARY && v->as.unary.op == Minus) // -literal still counts as a literal
    v = ast_at_const(t->ast, v->as.unary.operand);
  if (v->kind != NODE_LITERAL)
    return false;
  const Ty *const et = ast_type_at(t->ast, expected);
  switch (v->as.literal.token_type) {
    case IntegerLiteral: // an integer literal fits any int *or* float/complex slot (`let f: f64 = 0;`)
      if (tc_literal_pinned(t, v))
        return false; // a suffixed literal is its named type: only exact match or widening (above)
      return et->kind == TYPE_BUILTIN &&
             (bt_is_int(et->as.builtin) || bt_is_float(et->as.builtin) || bt_is_complex(et->as.builtin));
    case CharacterLiteral: // an ASCII char literal fits any int slot too (`contains_byte('l')`), like `b'l'`
      return et->kind == TYPE_BUILTIN && bt_is_int(et->as.builtin);
    case FloatLiteral: // a float literal fits a float or complex slot (no implicit float->int truncation)
      if (tc_literal_pinned(t, v))
        return false; // pinned: `1.5f64` never narrows into an f32 slot
      return et->kind == TYPE_BUILTIN && (bt_is_float(et->as.builtin) || bt_is_complex(et->as.builtin));
    case StringLiteral:
    case RawStringLiteral: { // a string literal is a NUL-terminated C string: it coerces to a `*const char` /
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

// find_member with a C-string name the caller synthesized (tuple `.0` -> field `_0`).
static NodeId find_member_cstr(TypeChecker *t, const ModuleId m, const NodeId decl, const char *const name) {
  Ast *const a = mod_ast(t, m);
  const uint8_t *const src = mod_src(t, m);
  const Node *const d = ast_at_const(a, decl);
  if (d->kind != NODE_STRUCT && d->kind != NODE_ENUM)
    return NODE_NONE;
  const NodeList members = d->as.aggregate.members;
  const NodeId *const ids = ast_list(a, members);
  const size_t nl = strlen(name);
  for (uint32_t i = 0; i < members.len; i++) {
    const Node *const mem = ast_at_const(a, ids[i]);
    const NodeId mname = mem->kind == NODE_FIELD ? mem->as.field.name : mem->as.variant.name;
    const Span sp = ast_at_const(a, mname)->as.name.text;
    if (sp.end - sp.start == nl && memcmp(src + sp.start, name, nl) == 0)
      return ids[i];
  }
  return NODE_NONE;
}

// Find a method named `name` in any top-level extend of module `m` whose target type resolves to `decl`.
// `name` is a span into the *caller's* source; member names are compared against each searched module's
// source. Find a method for type `decl` (declared in module `m`): searches the type's home module, then the
// CURRENT module for a local extension of an imported type (`extend foreign::T`, visible only here and
// mangled by this module). Matches the method name by span (`name`) when `lit` is NULL, else against the
// C-string `lit`. Marks the resolved method used (demand-driven emission). {_, NODE_NONE} if not found.
static DefId find_method_impl(TypeChecker *t, const ModuleId m, const NodeId decl, const Span name, const char *const lit) {
  const ModuleId scopes[2] = {m, t->ast->module};
  const int ns = m == t->ast->module ? 1 : 2;
  for (int s = 0; s < ns; s++) {
    const ModuleId mm = scopes[s];
    Ast *const a = mod_ast(t, mm);
    const NodeList items = ast_at_const(a, a->root)->as.program.items;
    const NodeId *const ids = ast_list(a, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const it = ast_at_const(a, ids[i]);
      if (it->kind != NODE_EXTEND || it->as.extend_def.target_type == NODE_NONE)
        continue;
      const DefId tg = ast_resolution_def(a, it->as.extend_def.target_type);
      if (tg.module != m || tg.node != decl)
        continue;
      const NodeList ms = it->as.extend_def.items;
      const NodeId *const mids = ast_list(a, ms);
      for (uint32_t j = 0; j < ms.len; j++) {
        const Node *const mn = ast_at_const(a, mids[j]);
        if (mn->kind != NODE_FUNCTION)
          continue;
        const Span mname = ast_at_const(a, mn->as.function.name)->as.name.text;
        if (lit ? span_is(mod_src(t, mm), mname, lit) : spans_eq2(t->source, name, mod_src(t, mm), mname)) {
          package_mark_method_used((Package *)t->package, (DefId){mm, mids[j]}); // reached -> emit (demand-driven)
          return (DefId){mm, mids[j]};
        }
      }
    }
  }
  return (DefId){0, NODE_NONE};
}

static DefId find_method(TypeChecker *t, const ModuleId m, const NodeId decl, const Span name) {
  return find_method_impl(t, m, decl, name, NULL);
}

// Like find_method, but matches a C-string method name (used by the built-in `.into()`/`.try_into()`
// conversions to reach a type's `from` / `try_from`).
static DefId find_method_cstr(TypeChecker *t, const ModuleId m, const NodeId decl, const char *const lit) {
  return find_method_impl(t, m, decl, (Span){0}, lit);
}

// The `format`/`print`/`println` builtins are lowered in codegen to direct `String<Global>` appends
// (push_i64 / push_hex / push_str / ...) and an interpolated argument's `as_str`, with no source-level
// method call -- so demand-driven emission would prune those helpers. Resolve them here (via the marking
// find_method_cstr) whenever a format builtin is type-checked, so they are always emitted when used.
static void mark_format_helpers(TypeChecker *t) {
  if (!t->package)
    return;
  ModuleId sm;
  const NodeId sd = package_prelude_lookup(t->package, "String", 6, true, &sm);
  if (sd == NODE_NONE)
    return;
  // Keep in sync with the String<Global> methods that emit_format_arg / emit_format_builtin synthesize
  // (src/codegen/codegen.c): the per-arg appenders, the `new` builder constructor, the `print` writer, and
  // an interpolated String argument's `as_str`. A missing entry only surfaces as a link error in a format
  // test, so the codegen-run format cases guard this list.
  static const char *const helpers[] = {"new",          "print",    "eprint",    "push_i64",      "push_u64",
                                        "push_f64",     "push_hex_i64", "push_hex", "push_byte", "push_str",
                                        "as_str",       "push_bin", "push_f64_prec", "push_padded"};
  for (size_t i = 0; i < sizeof helpers / sizeof helpers[0]; i++)
    find_method_cstr(t, sm, sd, helpers[i]); // a successful lookup marks the method used (see find_method_cstr)
}

// `x.into()` / `x.try_into()`: built-in conversions backed by the target type's `From` / `TryFrom` extend.
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

// A `from` method on `target`'s aggregate whose single parameter takes exactly `src` -- the From
// conformance backing `?`'s implicit error conversion (callee error -> caller error). Only plain
// struct/enum targets participate (a generic-instance error type keeps the exact-match rule).
static DefId tc_find_from_for(TypeChecker *t, const TypeId target, const TypeId src) {
  const Ty *const ty = ast_type_at(t->ast, strip(t, target));
  if (ty->kind != TYPE_STRUCT && ty->kind != TYPE_ENUM)
    return (DefId){0, NODE_NONE};
  const ModuleId m = ty->module;
  const NodeId decl = ty->as.decl;
  const ModuleId scopes[2] = {m, t->ast->module};
  const int ns = m == t->ast->module ? 1 : 2;
  for (int s = 0; s < ns; s++) {
    const ModuleId mm = scopes[s];
    Ast *const a = mod_ast(t, mm);
    const NodeList items = ast_at_const(a, a->root)->as.program.items;
    const NodeId *const ids = ast_list(a, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const it = ast_at_const(a, ids[i]);
      if (it->kind != NODE_EXTEND || it->as.extend_def.target_type == NODE_NONE || it->as.extend_def.generics.len)
        continue;
      const DefId tg = ast_resolution_def(a, it->as.extend_def.target_type);
      if (tg.module != m || tg.node != decl)
        continue;
      const NodeList ms = it->as.extend_def.items;
      const NodeId *const mids = ast_list(a, ms);
      for (uint32_t j = 0; j < ms.len; j++) {
        const Node *const mn = ast_at_const(a, mids[j]);
        if (mn->kind != NODE_FUNCTION ||
            !span_is(mod_src(t, mm), ast_at_const(a, mn->as.function.name)->as.name.text, "from"))
          continue;
        const NodeList ps = mn->as.function.params;
        if (ps.len != 1 || decl_type_in(t, mm, ast_list(a, ps)[0]) != src)
          continue;
        package_mark_method_used((Package *)t->package, (DefId){mm, mids[j]}); // demand-driven emission
        return (DefId){mm, mids[j]};
      }
    }
  }
  return (DefId){0, NODE_NONE};
}

// A method named `name` declared by interface `interface` (module `m`) itself, or by one of its superinterfaces
// (`interface Ord: Eq`). Used to resolve `self.<m>()` inside an interface DEFAULT method body, where the
// receiver is the abstract `Self` and `<m>` is one of the interface family's own methods.
static DefId find_interface_method(TypeChecker *t, const ModuleId m, const NodeId interface, const Span name, const int depth) {
  if (depth > 8)
    return (DefId){0, NODE_NONE};
  Ast *const a = mod_ast(t, m);
  const Node *const tn = ast_at_const(a, interface);
  if (tn->kind != NODE_INTERFACE)
    return (DefId){0, NODE_NONE};
  const NodeList items = tn->as.interface_def.items;
  const NodeId *const mids = ast_list(a, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const mn = ast_at_const(a, mids[i]);
    if (mn->kind == NODE_FUNCTION &&
        spans_eq2(t->source, name, mod_src(t, m), ast_at_const(a, mn->as.function.name)->as.name.text))
      return (DefId){m, mids[i]};
  }
  const NodeList bounds = tn->as.interface_def.bounds; // superinterfaces
  const NodeId *const bids = ast_list(a, bounds);
  for (uint32_t i = 0; i < bounds.len; i++) {
    const DefId sb = ast_resolution_def(a, bids[i]);
    if (sb.node != NODE_NONE) {
      const DefId r = find_interface_method(t, sb.module, sb.node, name, depth + 1);
      if (r.node != NODE_NONE)
        return r;
    }
  }
  return (DefId){0, NODE_NONE};
}

// A DEFAULT (bodied) interface method named `name` inherited by concrete type `tdecl` through one of its
// `extend tdecl as Iface` extends -- the fallback when `tdecl` provides no method of its own by that name.
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
      if (it->kind != NODE_EXTEND || it->as.extend_def.interface_type == NODE_NONE)
        continue;
      const DefId tg = ast_resolution_def(a, it->as.extend_def.target_type);
      if (tg.module != tmod || tg.node != tdecl)
        continue;
      const DefId iff = ast_resolution_def(a, it->as.extend_def.interface_type);
      if (iff.node == NODE_NONE || iff.module != t->ast->module)
        continue; // only same-module interface defaults are emittable
      const DefId mth = find_interface_method(t, iff.module, iff.node, name, 0);
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
    if (bn->kind == NODE_INTERFACE &&
        span_is(mod_src(t, bd.module), ast_at_const(mod_ast(t, bd.module), bn->as.interface_def.name)->as.name.text, "Free"))
      return true;
  }
  return false;
}

// Does `ty` implement the Free interface (`extend T as Free`)? Such values are move-tracked: once moved,
// a re-use is an error (and the value is not double-freed). Plain non-Free value types are not tracked,
// so ordinary value-semantics copies (`let p2 = p1` for a POD struct) stay legal. For a conditional extend
// (`extend<T: Free> Option<T> as Free`) the instance must satisfy the `Free` bounds (Option<i32> is NOT
// Free; Option<String> is) -- positional with the aggregate's type args.
static bool tc_type_is_free(TypeChecker *t, const TypeId ty) {
  ModuleId om;
  NodeId od;
  DefId gp[4];
  TypeId ga[4];
  int gn;
  if (ty == TYPE_NONE)
    return false;
  const Ty *const y0 = ast_type_at(t->ast, ty);
  if (y0->kind == TYPE_FUNCTION) // an owning closure value frees its env's captures at scope exit
    return fn_owns(t, ty);
  if (y0->kind == TYPE_DYN) // only the owned form (`Box<dyn I>`) frees, through its vtable's drop glue
    return y0->qualifier == TYPE_QUAL_NONE;
  if (y0->kind == TYPE_GENERIC) {
    // An `F: fn move(..) ..` param MAY be an owning closure: the generic body move-tracks it (the
    // concrete spec then frees it, or skips the free entirely for a plain fn / borrowing closure).
    const NodeId fb = generic_fn_bound(t, y0->module, y0->as.decl);
    if (fb != NODE_NONE)
      return ast_at_const(mod_ast(t, y0->module), fb)->as.function_type.is_move;
  }
  if (!aggregate_of(t, strip(t, ty), &om, &od, gp, ga, &gn))
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
      if (it->kind != NODE_EXTEND || it->as.extend_def.interface_type == NODE_NONE || it->as.extend_def.target_type == NODE_NONE)
        continue;
      const DefId tg = ast_resolution_def(a, it->as.extend_def.target_type);
      if (tg.module != om || tg.node != od)
        continue;
      const DefId tr = ast_resolution_def(a, it->as.extend_def.interface_type);
      if (tr.node == NODE_NONE)
        continue;
      const Node *const trn = ast_at_const(mod_ast(t, tr.module), tr.node);
      if (trn->kind != NODE_INTERFACE ||
          !span_is(mod_src(t, tr.module), ast_at_const(mod_ast(t, tr.module), trn->as.interface_def.name)->as.name.text,
                   "Free"))
        continue;
      // Every `Free`-bounded type parameter of the extend must map to a `Free` argument.
      const NodeList gens = it->as.extend_def.generics;
      const NodeId *const gids = ast_list(a, gens);
      for (uint32_t k = 0; k < gens.len && (int)k < gn; k++)
        if (tc_param_has_free_bound(t, m, gids[k]) && !tc_type_is_free(t, ga[k]))
          return false;
      return true;
    }
  }
  return false;
}

static bool borrow_dead_after(TypeChecker *t, const Borrow *b, NodeId after);
static void borrow_tombstone(Borrow *b);
static NodeId place_through_binding(const TypeChecker *t, NodeId place);

// The lexical scope depth a binding was declared at (recorded when its declaration is checked;
// parameters live at function scope, depth 0). A miss falls back to 0 -- the borrow then just lives
// longer (conservative for aliasing, and never manufactures a does-not-live-long-enough error).
static uint32_t tc_binding_depth(TypeChecker *t, const NodeId decl) {
  if (decl == NODE_NONE || ast_at_const(t->ast, decl)->kind == NODE_PARAMETER)
    return 0;
  uint32_t d;
  return TcDepthMap_get(&t->binding_depth, decl, &d) ? d : 0;
}
static void tc_record_binding_depth(TypeChecker *t, const NodeId decl) {
  if (decl != NODE_NONE)
    TcDepthMap_insert(&t->binding_depth, decl, t->scope_depth);
}

// Inside a closure body, a captured Free value in MOVE position (a by-value arg, a `let` init, a
// returned value -- including a compact closure's body expression) would leave the env's copy dangling
// when the env is freed: reject it. Returns true when it errored (the caller skips its move marking).
static bool tc_capture_move_guard(TypeChecker *t, NodeId expr) {
  if (!t->nclos)
    return false;
  const Node *n = ast_at_const(t->ast, expr);
  while (n->kind == NODE_UNARY && (n->as.unary.op == Move || n->as.unary.op == Unsafe)) {
    expr = n->as.unary.operand;
    n = ast_at_const(t->ast, expr);
  }
  if (n->kind != NODE_IDENTIFIER)
    return false;
  const DefId d = ast_resolution_def(t->ast, expr);
  if (d.module != t->ast->module || d.node == NODE_NONE ||
      tc_capture_index(t, t->clos_stack[t->nclos - 1], d.node) < 0 ||
      !tc_type_is_free(t, ast_type(t->ast, expr)))
    return false;
  const Span sp = ast_at_const(t->ast, expr)->span;
  typechecker_errorf(t, sp.start, sp.end - sp.start,
                     "cannot move a captured value out of a closure (the closure's env owns it)");
  return true;
}

// Record `expr` as a move if it is a bare reference to a current-module Free-typed binding (a `let` or a
// by-value parameter): ownership transfers away, so a later use is flagged. `move`/`unsafe` wrappers are
// transparent -- the move is of the wrapped binding.
static void tc_mark_move(TypeChecker *t, NodeId expr) {
  if (expr == NODE_NONE)
    return;
  const Node *n = ast_at_const(t->ast, expr);
  while (n->kind == NODE_UNARY && (n->as.unary.op == Move || n->as.unary.op == Unsafe)) {
    expr = n->as.unary.operand;
    n = ast_at_const(t->ast, expr);
  }
  if (n->kind != NODE_IDENTIFIER)
    return;
  const DefId d = ast_resolution_def(t->ast, expr);
  if (d.module != t->ast->module || d.node == NODE_NONE)
    return;
  const NodeKind dk = ast_at_const(t->ast, d.node)->kind;
  if ((dk != NODE_LET && dk != NODE_PARAMETER) || !tc_type_is_free(t, ast_type(t->ast, expr)))
    return;
  // Inside a closure body, a captured Free value belongs to (or is borrowed into) the closure's env:
  // the body may use it, but moving it OUT would leave the env's copy dangling when the env is freed.
  if (tc_capture_move_guard(t, expr))
    return;
  // Borrow checker: moving the whole binding out from under a live shared borrow of it (or any sub-place) is
  // illegal. (A `&mut` borrow already blocks the read of `expr` that precedes the move, diagnosed there; here
  // we catch the shared case -- the move reads all of `expr`, so any shared borrow of its root overlaps.)
  // A stored borrow whose binding has no use after this point has already expired (NLL) -- drop, not conflict.
  for (uint32_t i = 0; i < t->nborrows; i++) {
    Borrow *const b = &t->borrows[i];
    if (b->root != d.node || b->kind != BORROW_SHARED)
      continue;
    if (borrow_dead_after(t, b, expr)) {
      borrow_tombstone(b);
      continue;
    }
    const Span sp = ast_at_const(t->ast, expr)->span;
    typechecker_errorf(t, sp.start, sp.end - sp.start, "cannot move this value while it is borrowed");
    break;
  }
  for (uint32_t i = 0; i < t->nmoved; i++)
    if (t->moved[i] == d.node)
      return; // already moved
  if (t->nmoved < (uint32_t)(sizeof t->moved / sizeof t->moved[0])) {
    t->moved[t->nmoved++] = d.node;
  } else { // never drop a fact silently: a lost move would hide use-after-move AND double frees downstream
    const Span sp = ast_at_const(t->ast, expr)->span;
    typechecker_errorf(t, sp.start, sp.end - sp.start,
                       "too many moved values in one function (move-analysis limit)");
  }
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
  if (tc_is_uninit(t, decl))
    return;
  if (t->nuninit < (uint32_t)(sizeof t->uninit / sizeof t->uninit[0])) {
    t->uninit[t->nuninit++] = decl;
  } else { // never drop a fact silently: an untracked deferred binding would skip the definite-init check
    const Span sp = ast_at_const(t->ast, decl)->span;
    typechecker_errorf(t, sp.start, sp.end - sp.start,
                       "too many uninitialized bindings in one function (definite-init analysis limit)");
  }
}
static void tc_init(TypeChecker *t, const NodeId decl) { // mark `decl` initialized on this path
  for (uint32_t i = 0; i < t->nuninit; i++)
    if (t->uninit[i] == decl) {
      t->uninit[i] = t->uninit[--t->nuninit]; // order is irrelevant: membership-only set
      return;
    }
}
// Reassigning a binding (`x = ..`) gives it a fresh owned value, so it is no longer moved-out or freed: a
// later use is valid again. (The old value's cleanup is codegen's concern -- a reassign frees it.)
static void tc_unmark_move(TypeChecker *t, const NodeId decl) {
  for (uint32_t i = 0; i < t->nmoved; i++)
    if (t->moved[i] == decl) {
      t->moved[i] = t->moved[--t->nmoved];
      break;
    }
  for (uint32_t i = 0; i < t->nfreed; i++)
    if (t->freed[i] == decl) {
      t->freed[i] = t->freed[--t->nfreed];
      break;
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
  Borrow borrows[64]; // a borrow live on ANY path is live afterward (conservative), like moved/uninit
  uint32_t nborrows;
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
  s.nborrows = t->nborrows;
  for (uint32_t i = 0; i < t->nborrows; i++)
    s.borrows[i] = t->borrows[i];
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
  t->nborrows = s->nborrows;
  for (uint32_t i = 0; i < s->nborrows; i++)
    t->borrows[i] = s->borrows[i];
}

// Does this statement RETURN from the function on every path through it (a trailing `return`, possibly
// inside nested blocks / an if with both branches returning, or a diverging `never`-typed call)? Such a
// branch's flow effects never reach the join after its enclosing `if` -- merging them would manufacture
// false use-after-move errors on the other path. `break`/`continue` do NOT count: they re-join inside
// the function (at the loop boundary), carrying their effects with them.
static bool tc_stmt_returns(TypeChecker *t, const NodeId id) {
  if (id == NODE_NONE)
    return false;
  const Node *const n = ast_at_const(t->ast, id);
  switch (n->kind) {
    case NODE_RETURN:
      return true;
    case NODE_BLOCK: {
      const NodeList ss = n->as.block.statements;
      return ss.len && tc_stmt_returns(t, ast_list(t->ast, ss)[ss.len - 1]);
    }
    case NODE_IF:
      return n->as.if_stmt.else_branch != NODE_NONE && tc_stmt_returns(t, n->as.if_stmt.then_branch) &&
             tc_stmt_returns(t, n->as.if_stmt.else_branch);
    case NODE_EXPRESSION_STATEMENT: { // a `@c.noreturn` call (panic) diverges too
      const TypeId ty = ast_type(t->ast, n->as.single.value);
      return ty != TYPE_NONE && ast_type_at(t->ast, ty)->kind == TYPE_NEVER;
    }
    default:
      return false;
  }
}

// Two borrow records name the same borrow event (for merge dedup) when their root, kind, region and origin
// node all match -- a borrow present before an `if` appears identically in both arms.
static bool borrow_same(const Borrow *a, const Borrow *b) {
  return a->root == b->root && a->kind == b->kind && a->region == b->region && a->origin == b->origin;
}

// Union the live state into `acc`. Returns true if any fact was dropped for capacity (the caller
// diagnoses -- a silently lost fact would disable a later use-after-move / definite-init check).
static bool tc_flow_collect(FlowState *acc, const TypeChecker *t) {
  bool overflow = false;
  for (uint32_t i = 0; i < t->nmoved; i++) {
    bool seen = false;
    for (uint32_t j = 0; j < acc->nmoved; j++)
      seen |= acc->moved[j] == t->moved[i];
    if (seen)
      continue;
    if (acc->nmoved < (uint32_t)(sizeof acc->moved / sizeof acc->moved[0]))
      acc->moved[acc->nmoved++] = t->moved[i];
    else
      overflow = true;
  }
  for (uint32_t i = 0; i < t->nuninit; i++) {
    bool seen = false;
    for (uint32_t j = 0; j < acc->nuninit; j++)
      seen |= acc->uninit[j] == t->uninit[i];
    if (seen)
      continue;
    if (acc->nuninit < (uint32_t)(sizeof acc->uninit / sizeof acc->uninit[0]))
      acc->uninit[acc->nuninit++] = t->uninit[i];
    else
      overflow = true;
  }
  for (uint32_t i = 0; i < t->nfreed; i++) {
    bool seen = false;
    for (uint32_t j = 0; j < acc->nfreed; j++)
      seen |= acc->freed[j] == t->freed[i];
    if (seen)
      continue;
    if (acc->nfreed < (uint32_t)(sizeof acc->freed / sizeof acc->freed[0]))
      acc->freed[acc->nfreed++] = t->freed[i];
    else
      overflow = true;
  }
  for (uint32_t i = 0; i < t->nborrows; i++) {
    bool seen = false;
    for (uint32_t j = 0; j < acc->nborrows; j++)
      seen |= borrow_same(&acc->borrows[j], &t->borrows[i]);
    if (seen)
      continue;
    if (acc->nborrows < (uint32_t)(sizeof acc->borrows / sizeof acc->borrows[0]))
      acc->borrows[acc->nborrows++] = t->borrows[i];
    else
      overflow = true;
  }
  return overflow;
}

// Diagnose a lossy branch-state union once per construct (`at` anchors the span).
static void tc_flow_overflow(TypeChecker *t, const NodeId at) {
  const Span sp = ast_at_const(t->ast, at)->span;
  typechecker_errorf(t, sp.start, sp.end - sp.start,
                     "too many flow facts to merge across branches in one function (analysis limit)");
}

// Enter/leave a lexical block scope. On exit, drop every borrow whose BINDING's scope is the departing
// one (or a nested one, defensively): the reference dies with its binding. A borrow whose binding
// OUTLIVES the scope but whose borrowed root dies here is a dangling reference -- there are no lifetime
// annotations to say otherwise, so it is always an error (`let mut r = &x; { let y = 2; r = &y; }`).
static void tc_scope_enter(TypeChecker *t) {
  t->scope_depth++;
}
static void tc_scope_exit(TypeChecker *t) {
  const uint32_t d = t->scope_depth;
  uint32_t w = 0;
  for (uint32_t i = 0; i < t->nborrows; i++) {
    const Borrow *const b = &t->borrows[i];
    if (b->region >= d)
      continue; // the binding (or temporary) dies with this scope: the borrow ends silently
    if (b->binding != NODE_NONE && b->root != NODE_NONE && tc_binding_depth(t, b->root) >= d) {
      const Span sp = ast_at_const(t->ast, b->origin)->span;
      typechecker_errorf(t, sp.start, sp.end - sp.start,
                         "borrowed value does not live long enough: it is destroyed at the end of this "
                         "block while a reference to it is still stored");
      continue; // diagnosed; drop it so the stale record cannot cascade
    }
    t->borrows[w++] = t->borrows[i];
  }
  t->nborrows = w;
  if (t->scope_depth)
    t->scope_depth--;
}

// The access steps of a place, leaf-first, for field-precise borrow tracking. A field step records the field
// name span (compared by text); an index step records a constant literal value when it has one (distinct
// constant slots `a[0]`/`a[1]` are disjoint; a variable index matches any, since i == j cannot be disproved);
// a deref step marks an access THROUGH a reference (`*r`, `r.f`), which roots the place at the reference.
enum { PS_FIELD = 0, PS_INDEX, PS_DEREF };
typedef struct {
  uint8_t kind;
  bool index_const;  // (PS_INDEX) the index is a compile-time constant literal
  int64_t index_val; // (PS_INDEX) its value, valid iff index_const
  Span name;         // (PS_FIELD) the field-name text span
} PStep;
#define PLACE_MAX_STEPS 16

// A non-negative integer-literal index's value, for disambiguating distinct constant array slots (`a[0]` vs
// `a[1]`). Returns false for anything not a plain integer literal (a variable/computed index stays conservative).
static bool place_index_const(const TypeChecker *t, const NodeId idx, int64_t *const out) {
  const Node *const n = ast_at_const(t->ast, idx);
  if (n->kind != NODE_LITERAL || n->as.literal.token_type != IntegerLiteral)
    return false;
  const Span lr = n->as.literal.raw;
  const uint8_t *p = t->source + lr.start;
  size_t len = lr.end - lr.start;
  unsigned base = 10;
  if (len >= 2 && p[0] == '0' && (p[1] | 0x20) == 'x') { base = 16, p += 2, len -= 2; }
  else if (len >= 2 && p[0] == '0' && (p[1] | 0x20) == 'b') { base = 2, p += 2, len -= 2; }
  else if (len >= 2 && p[0] == '0' && (p[1] | 0x20) == 'o') { base = 8, p += 2, len -= 2; }
  uint64_t acc = 0;
  for (size_t i = 0; i < len; i++) {
    const uint8_t ch = p[i];
    if (ch == '_')
      continue;
    const unsigned d = ch <= '9' ? (unsigned)(ch - '0') : (unsigned)((ch | 0x20) - 'a' + 10);
    if (d >= base || acc > (uint64_t)(INT64_MAX - (int64_t)d) / base)
      return false; // a suffix, a non-digit, or an out-of-range value -> not a usable constant
    acc = acc * base + d;
  }
  *out = (int64_t)acc;
  return true;
}

// Is `ty` an untagged union (a `union` decl, or an instance of a generic one)? Its members alias.
static bool tc_type_is_union(TypeChecker *t, const TypeId ty) {
  ModuleId m;
  NodeId d;
  DefId gp[4];
  TypeId ga[4];
  int gn;
  if (ty == TYPE_NONE || !aggregate_of(t, ty, &m, &d, gp, ga, &gn))
    return false;
  const Node *const dn = ast_at_const(mod_ast(t, m), d);
  return dn->kind == NODE_STRUCT && dn->as.aggregate.is_union;
}

// Decompose a place `&x.f[i]…` into its root binding + access steps (leaf-first, up to `cap`). Returns the
// root decl if it is a local binding (let / parameter / payload pattern / tuple-let element / loop
// binding) in THIS module, else NODE_NONE for anything the borrow model does not track -- a raw-pointer/
// global root, a slice element, or a non-place. A place reached THROUGH a reference (`*r`, `r.f`, r a
// reference binding OR parameter) roots at the reference itself with a DEREF step, so uses of `r` and
// reborrows of the same sub-place conflict, while r's own borrow (which roots at what r points at) stays
// distinct. Raw-pointer derefs stay untracked (unsafe). A UNION member access collapses everything
// leafward of the union (its fields overlap, so field-name disjointness would be wrong there). Steps past
// `cap` are dropped (root still returned), so an absurdly deep path compares on its recorded prefix.
static NodeId place_decompose(TypeChecker *t, NodeId place, PStep *const steps, int *const nsteps, const int cap) {
  *nsteps = 0;
  for (;;) {
    const Node *const pn = ast_at_const(t->ast, place);
    if (pn->kind == NODE_UNARY && (pn->as.unary.op == Move || pn->as.unary.op == Unsafe)) {
      place = pn->as.unary.operand; // transparent wrappers add no place step
      continue;
    }
    if (pn->kind == NODE_UNARY && pn->as.unary.op == Star) { // `*r`: an explicit deref
      const NodeId op = pn->as.unary.operand;
      const TypeId ot = ast_type(t->ast, op);
      const Ty *const otk = ot == TYPE_NONE ? NULL : ast_type_at(t->ast, ot);
      if (!otk || otk->kind != TYPE_REFERENCE)
        return NODE_NONE; // a raw-pointer / unknown deref -- untracked
      if (*nsteps < cap)
        steps[(*nsteps)++] = (PStep){.kind = PS_DEREF};
      place = op;
      continue;
    }
    NodeId base;
    PStep step = {0};
    if (pn->kind == NODE_MEMBER && !pn->as.member.path) {
      base = pn->as.member.object;
      step.kind = PS_FIELD;
      step.name = name_span(t, pn->as.member.member); // the field-name text span (compared by bytes below)
    } else if (pn->kind == NODE_INDEX) {
      base = pn->as.index.object;
      step.kind = PS_INDEX;
      int64_t v;
      if (place_index_const(t, pn->as.index.index, &v)) {
        step.index_const = true;
        step.index_val = v;
      }
    } else {
      break;
    }
    const TypeId bt = ast_type(t->ast, base);
    const Ty *const btk = bt == TYPE_NONE ? NULL : ast_type_at(t->ast, bt);
    if (!btk)
      return NODE_NONE;
    // A union's members overlap: drop the leafward refinements and skip the field step itself, so any
    // two places inside the same union compare as overlapping (`&u.a` conflicts with `&mut u.b`).
    const bool base_union = pn->kind == NODE_MEMBER &&
                            tc_type_is_union(t, btk->kind == TYPE_REFERENCE ? btk->as.elem : bt);
    if (base_union)
      *nsteps = 0;
    if (btk->kind == TYPE_REFERENCE) {
      // `r.f` / `r[i]` on a reference binding: the field/index access is applied through an implicit deref, so
      // record the step, then a deref, and continue decomposing `r` itself -- the place roots at `r`.
      if (pn->kind == NODE_INDEX)
        return NODE_NONE; // indexing through a reference is untracked (out of scope)
      if (!base_union && *nsteps < cap)
        steps[(*nsteps)++] = step;
      if (*nsteps < cap)
        steps[(*nsteps)++] = (PStep){.kind = PS_DEREF};
      place = base;
      continue;
    }
    if (btk->kind == TYPE_POINTER)
      return NODE_NONE; // behind a raw pointer -- names storage that is not the local binding (untracked)
    if (pn->kind == NODE_INDEX && btk->kind != TYPE_ARRAY)
      return NODE_NONE; // a slice/other element, not an array slot within the local
    if (!base_union && *nsteps < cap)
      steps[(*nsteps)++] = step;
    place = base;
  }
  if (ast_at_const(t->ast, place)->kind != NODE_IDENTIFIER)
    return NODE_NONE;
  const DefId d = ast_resolution_def(t->ast, place);
  if (d.node == NODE_NONE || d.module != t->ast->module)
    return NODE_NONE;
  switch (ast_at_const(t->ast, d.node)->kind) {
    case NODE_PARAMETER: // deref'd places (`*p`, `self.f`) root at the param like a local reference binding
    case NODE_LET:
    case NODE_PATTERN_NAME:
    case NODE_IDENTIFIER: // a tuple-let element / struct-pattern shorthand binding (declared as itself)
    case NODE_FOR:        // a loop binding (uses resolve to the for node)
      return d.node;
    default:
      return NODE_NONE;
  }
}

// The root binding a place borrows from, or NODE_NONE if untracked. Shared by borrow creation, the use
// checks, and `addr_escape` (a returned address of such a root dangles).
static NodeId borrow_place_root(TypeChecker *t, const NodeId place) {
  PStep steps[PLACE_MAX_STEPS];
  int n;
  return place_decompose(t, place, steps, &n, PLACE_MAX_STEPS);
}

// Do two value-places name overlapping storage? They must reduce to the same root binding; then one access
// path must be a prefix of the other. Field steps overlap iff they name the same field; an index step
// overlaps any index. So `&mut x.a` and `&x.b` are disjoint, but `&mut x` and `&x.a` overlap.
static bool places_overlap(TypeChecker *t, const NodeId a, const NodeId b) {
  PStep sa[PLACE_MAX_STEPS], sb[PLACE_MAX_STEPS];
  int na, nb;
  const NodeId ra = place_decompose(t, a, sa, &na, PLACE_MAX_STEPS);
  const NodeId rb = place_decompose(t, b, sb, &nb, PLACE_MAX_STEPS);
  if (ra == NODE_NONE || rb == NODE_NONE || ra != rb)
    return false;
  const int common = na < nb ? na : nb;
  for (int i = 0; i < common; i++) { // steps are leaf-first: compare from the shared root outward
    const PStep *const pa = &sa[na - 1 - i];
    const PStep *const pb = &sb[nb - 1 - i];
    if (pa->kind != pb->kind)
      return true; // access-kind mismatch at a shared level (should not happen) -- err toward overlap
    if (pa->kind == PS_FIELD) {
      const uint32_t la = pa->name.end - pa->name.start, lb = pb->name.end - pb->name.start;
      if (la != lb || memcmp(t->source + pa->name.start, t->source + pb->name.start, la) != 0)
        return false; // different fields at this level -> disjoint
    } else if (pa->kind == PS_INDEX && pa->index_const && pb->index_const && pa->index_val != pb->index_val) {
      return false; // distinct constant array slots -> disjoint (a variable index still matches any)
    }
  }
  return true; // one path is a prefix of the other -> overlap
}

// The live-borrow count on entry to an expression context; `borrow_release_to` drops the TEMPORARIES created
// since. A temporary borrow (an `&`/`&mut` not bound to a name) lives only for the context it appears in --
// an expression statement, an initializer, a condition, or a return -- so sequential statements do not
// falsely conflict. A borrow bound to a name (a stored reference, e.g. from a reference reassignment `r = &y`
// nested in an expression statement) is scope/NLL-lived, so it is KEPT (compacted down) across the release.
static uint32_t borrow_mark(const TypeChecker *t) {
  return t->nborrows;
}
static void borrow_release_to(TypeChecker *t, const uint32_t mark) {
  if (t->nborrows <= mark)
    return; // everything above the mark is already gone (a rebind tombstoned + released below it)
  uint32_t w = mark;
  for (uint32_t i = mark; i < t->nborrows; i++)
    if (t->borrows[i].binding != NODE_NONE)
      t->borrows[w++] = t->borrows[i];
  t->nborrows = w;
}

// Neutralize a borrow record IN PLACE (never compact mid-expression: outstanding borrow_mark snapshots
// index into the array, and shifting entries below a mark corrupts the next release). A tombstone's
// root never matches a conflict query, and binding == NONE lets release/scope-exit reap it normally.
static void borrow_tombstone(Borrow *const b) {
  b->root = NODE_NONE;
  b->binding = NODE_NONE;
}

// Sub-statement NLL: a STORED borrow whose binding has no use at any node past `after` has already
// expired, so it never conflicts (`f(*r, &mut x)` is fine when `*r` is r's last use). Identifier uses are
// created in source order, so a scan of the resolution side table past `after` is exact for straight-line
// and branching code; a loop body re-executes earlier nodes, so this is disabled inside loops
// (conservative: the borrow stays live there). A live reborrow THROUGH the binding keeps it live too.
static bool borrow_dead_after(TypeChecker *t, const Borrow *const b, const NodeId after) {
  if (b->binding == NODE_NONE || t->loop_depth)
    return false;
  // A borrow bound to a TUPLE-let is lexical, not NLL: its destructured elements resolve to their own
  // identifiers, not to the let node, so the use scan below cannot see them (same carve-out as
  // borrow_nll_drop). It lives until tc_scope_exit.
  const Node *const bn = ast_at_const(t->ast, b->binding);
  if (bn->kind == NODE_LET && ast_at_const(t->ast, bn->as.let_stmt.name)->kind == NODE_PATTERN_TUPLE)
    return false;
  for (uint32_t i = 0; i < t->nborrows; i++)
    if (&t->borrows[i] != b && place_through_binding(t, t->borrows[i].place) == b->binding)
      return false; // `let q = &mut *r`: q aliases through r, so r's borrow must outlive q
  const size_t n = t->ast->nodes.len;
  for (NodeId nid = after + 1; nid < n; nid++) {
    const DefId rd = ast_resolution_def(t->ast, nid);
    if (rd.node == b->binding && rd.module == t->ast->module)
      return false;
  }
  return true;
}

// Report (once) an aliasing conflict for borrowing `place` with `kind` against live borrows that OVERLAP it:
// a `&mut` is exclusive (conflicts with any overlapping borrow) and a `&` conflicts only with an overlapping
// `&mut`; `&` + `&` is allowed, and disjoint fields (`&mut x.a` vs `&x.b`) do not conflict. `origin` gives
// the error span. Returns true iff a conflict was reported (so the caller skips registering the borrow). Used
// both to register a real borrow (`borrow_create`) and to check a transient implicit method-receiver borrow.
static bool borrow_report_conflict(TypeChecker *t, const NodeId place, const uint8_t kind, const NodeId origin) {
  const NodeId root = borrow_place_root(t, place);
  if (root == NODE_NONE)
    return false;
  for (uint32_t i = 0; i < t->nborrows; i++) {
    Borrow *const b = &t->borrows[i];
    if (b->root != root || (kind == BORROW_SHARED && b->kind == BORROW_SHARED) ||
        !places_overlap(t, place, b->place))
      continue; // different binding, the compatible shared+shared pair, or disjoint sub-places
    if (borrow_dead_after(t, b, origin)) {
      borrow_tombstone(b); // its binding's last use has passed: the borrow expired (NLL)
      continue;
    }
    const Span sp = ast_at_const(t->ast, origin)->span;
    typechecker_errorf(t, sp.start, sp.end - sp.start,
                       "cannot borrow this value as %s while it is already borrowed as %s",
                       kind == BORROW_MUT ? "mutable" : "immutable", b->kind == BORROW_MUT ? "mutable" : "immutable");
    typechecker_notef(t, "a value may have many '&' borrows or a single '&mut', not both; the earlier borrow must end first");
    return true;
  }
  return false;
}

// Append a borrow of `place` (rooted at `root`) to the live set, or fail safe if the fixed set is full
// (rather than silently untracking it, which would miss real conflicts against it).
static void borrow_push(TypeChecker *t, const NodeId root, const uint8_t kind, const NodeId place, const NodeId origin) {
  if (t->nborrows < (uint32_t)(sizeof t->borrows / sizeof t->borrows[0]))
    t->borrows[t->nborrows++] = (Borrow){
        .root = root, .place = place, .kind = kind, .region = (uint16_t)t->scope_depth, .origin = origin,
        .binding = NODE_NONE};
  else
    typechecker_errorf(t, ast_at_const(t->ast, origin)->span.start, 1,
                       "too many simultaneous borrows in one function (borrow-checker limit)");
}

// Register a borrow of `place` (kind shared/mut) made by expression `origin`, enforcing the aliasing rule. A
// reborrow `&[mut] *r` roots at `r` (via place_decompose), so it does not collide with r's own borrow (which
// roots at what r points at) yet does conflict with another reborrow of the same sub-place through r.
static void borrow_create(TypeChecker *t, const NodeId place, const uint8_t kind, const NodeId origin) {
  const NodeId root = borrow_place_root(t, place);
  if (root == NODE_NONE)
    return; // a raw-pointer/global/unresolved place or a non-place -- untracked by the borrow model
  if (!borrow_report_conflict(t, place, kind, origin))
    borrow_push(t, root, kind, place, origin);
}

// A live `&mut` borrow whose place overlaps the value-place `place`, or NULL. Reading `place` while it is
// exclusively borrowed is illegal; a disjoint field (reading x.b while only x.a is `&mut`-borrowed) is fine.
// A stored borrow whose binding has no later use has expired (NLL): dropped here, never a conflict.
static const Borrow *borrow_conflicting_read(TypeChecker *t, const NodeId place) {
  const NodeId root = borrow_place_root(t, place);
  if (root == NODE_NONE)
    return NULL;
  for (uint32_t i = 0; i < t->nborrows; i++) {
    Borrow *const b = &t->borrows[i];
    if (b->root != root || b->kind != BORROW_MUT || !places_overlap(t, place, b->place))
      continue;
    if (borrow_dead_after(t, b, place)) {
      borrow_tombstone(b);
      continue;
    }
    return b;
  }
  return NULL;
}

// A live STORED shared borrow overlapping the assignment target `place`, or NULL. Assigning through the owner
// while such a borrow is live is illegal. A `&mut` stored borrow is already caught by the LHS read check; a
// same-statement TEMPORARY (the `&x` in `x = f(&x)`, which has no binding) is excluded, matching NLL -- that
// borrow ends before the store -- so only borrows bound to a name (`binding != NONE`) trigger this. `after`
// is the last-use anchor: the whole ASSIGNMENT node, since the RHS (`x = *r + 1` -- r's last use) evaluates
// before the store yet parses after the LHS place.
static const Borrow *borrow_conflicting_write(TypeChecker *t, const NodeId place, const NodeId after) {
  const NodeId root = borrow_place_root(t, place);
  if (root == NODE_NONE)
    return NULL;
  for (uint32_t i = 0; i < t->nborrows; i++) {
    Borrow *const b = &t->borrows[i];
    if (b->root != root || b->kind != BORROW_SHARED || b->binding == NODE_NONE ||
        !places_overlap(t, place, b->place))
      continue;
    if (borrow_dead_after(t, b, after)) {
      borrow_tombstone(b);
      continue;
    }
    return b;
  }
  return NULL;
}

// `let r2 = r1` / `r2 = r1` where the initializer is a bare read of a reference binding r1: a `&mut` is
// non-Copy so this MOVES it (rebind r1's borrow(s) to r2, then invalidate r1 -- a later use is use-after-move);
// a `&` is Copy so this DUPLICATES it (r1 stays live too). Does nothing unless `init` resolves to a local
// reference binding with live borrows -- an `&`/`&mut`/call initializer creates its own borrow, handled elsewhere.
static void borrow_transfer_ref(TypeChecker *t, const NodeId init, const NodeId binding) {
  NodeId e = init;
  const Node *n = ast_at_const(t->ast, e);
  while (n->kind == NODE_UNARY && (n->as.unary.op == Move || n->as.unary.op == Unsafe)) {
    e = n->as.unary.operand;
    n = ast_at_const(t->ast, e);
  }
  if (n->kind != NODE_IDENTIFIER)
    return;
  const DefId rd = ast_resolution_def(t->ast, e);
  if (rd.node == NODE_NONE || rd.module != t->ast->module)
    return;
  const uint32_t n0 = t->nborrows;
  const uint16_t region = (uint16_t)tc_binding_depth(t, binding); // the borrow now dies with ITS binding's scope
  bool moved = false;
  for (uint32_t i = 0; i < n0; i++) {
    if (t->borrows[i].binding != rd.node)
      continue;
    if (t->borrows[i].kind == BORROW_MUT) {
      t->borrows[i].binding = binding; // the exclusive borrow moves to r2
      t->borrows[i].region = region;
      moved = true;
    } else if (t->nborrows < (uint32_t)(sizeof t->borrows / sizeof t->borrows[0])) {
      t->borrows[t->nborrows] = t->borrows[i]; // the shared borrow duplicates: both r1 and r2 alias it
      t->borrows[t->nborrows].region = region;
      t->borrows[t->nborrows++].binding = binding;
    }
  }
  if (moved) { // a `&mut` is consumed by the copy; reading r1 afterward is a use-after-move
    bool seen = false;
    for (uint32_t i = 0; i < t->nmoved; i++)
      seen |= t->moved[i] == rd.node;
    if (!seen && t->nmoved < (uint32_t)(sizeof t->moved / sizeof t->moved[0]))
      t->moved[t->nmoved++] = rd.node;
  }
}

// The reference binding a place is reached THROUGH (`r` in `*r`, `r.f`, `r.f.g`), or NODE_NONE if it is not
// through a local reference. A reborrow's origin operand names such a place; used to extend r's borrow.
static NodeId place_through_binding(const TypeChecker *t, NodeId place) {
  for (;;) {
    const Node *const pn = ast_at_const(t->ast, place);
    NodeId base;
    if (pn->kind == NODE_UNARY && pn->as.unary.op == Star)
      base = pn->as.unary.operand;
    else if (pn->kind == NODE_MEMBER && !pn->as.member.path)
      base = pn->as.member.object;
    else if (pn->kind == NODE_INDEX)
      base = pn->as.index.object;
    else
      return NODE_NONE;
    const TypeId bt = ast_type(t->ast, base);
    const Ty *const btk = bt == TYPE_NONE ? NULL : ast_type_at(t->ast, bt);
    if ((pn->kind == NODE_UNARY || (btk && btk->kind == TYPE_REFERENCE)) &&
        ast_at_const(t->ast, base)->kind == NODE_IDENTIFIER) {
      const DefId d = ast_resolution_def(t->ast, base); // reached `r` -- the reference we deref through
      return d.node != NODE_NONE && d.module == t->ast->module ? d.node : NODE_NONE;
    }
    place = base; // an access on a value aggregate -- keep walking toward the reference (or the local root)
  }
}

// NLL: after finishing statement `ids[si]` of the block node `block_id`, drop any stored borrow made in THIS
// block whose reference binding is not used in a LATER statement -- its region ends at its last use, not at
// scope exit. A reference binding is in scope only within this block, so every use of it has a node id in
// (ids[si], block_id) (later statements are parsed after, hence have higher ids); scanning that range over
// the resolution side table finds all later uses with no generic AST walk. Over-counting (a late-numbered
// node inside statement si) only keeps the borrow longer, so this is always sound.
static void borrow_nll_drop(TypeChecker *t, const NodeId block_id, const NodeId *const ids, const uint32_t si) {
  bool keep[sizeof t->borrows / sizeof t->borrows[0]];
  for (uint32_t k = 0; k < t->nborrows; k++) {
    const Borrow *const b = &t->borrows[k];
    keep[k] = true;
    if (b->binding != NODE_NONE && b->region == (uint16_t)t->scope_depth) {
      // A borrow bound to a TUPLE-let is lexical, not NLL: its destructured elements resolve to their own
      // identifiers, not to the let node, so the id-range scan cannot see their uses. tc_scope_exit ends it.
      const Node *const bn = ast_at_const(t->ast, b->binding);
      const bool tuple =
          bn->kind == NODE_LET && ast_at_const(t->ast, bn->as.let_stmt.name)->kind == NODE_PATTERN_TUPLE;
      if (!tuple) {
        keep[k] = false;
        for (NodeId nid = ids[si] + 1; nid < block_id && !keep[k]; nid++) {
          const DefId rd = ast_resolution_def(t->ast, nid);
          keep[k] = rd.node == b->binding && rd.module == t->ast->module;
        }
      }
    }
  }
  // A reborrow `let r2 = &mut *r` borrows r for r2's life, so r's own borrow must outlive r2 even if r has no
  // later textual use. Reborrows go THROUGH earlier references, so a reverse pass propagates the extension in
  // one sweep: a kept borrow reborrowing through r keeps every borrow bound to r (which may itself chain on).
  for (int k = (int)t->nborrows - 1; k >= 0; k--) {
    if (!keep[k])
      continue;
    const NodeId thru = place_through_binding(t, t->borrows[k].place);
    if (thru == NODE_NONE)
      continue;
    for (uint32_t j = 0; j < t->nborrows; j++)
      if (t->borrows[j].binding == thru)
        keep[j] = true;
  }
  uint32_t w = 0;
  for (uint32_t k = 0; k < t->nborrows; k++)
    if (keep[k])
      t->borrows[w++] = t->borrows[k];
  t->nborrows = w;
}

// True if any element of a tuple-let pattern `name` binds a reference type -- the destructured references may
// then alias the initializer's reference arguments, so their borrows must outlive the statement.
static bool tuple_binds_reference(TypeChecker *t, const NodeId name) {
  const NodeList names = ast_at_const(t->ast, name)->as.pattern.children;
  const NodeId *const nids = ast_list(t->ast, names);
  for (uint32_t i = 0; i < names.len; i++) {
    const TypeId et = ast_type(t->ast, nids[i]);
    if (et != TYPE_NONE && ast_type_at(t->ast, et)->kind == TYPE_REFERENCE)
      return true;
  }
  return false;
}

// The top-level extend in module `m` whose items contain `method`, or NODE_NONE -- used to recover the
// extend's own generic params so a method on a generic instance receiver substitutes them by its args.
static NodeId enclosing_extend(TypeChecker *t, const ModuleId m, const NodeId method) {
  Ast *const a = mod_ast(t, m);
  const NodeList items = ast_at_const(a, a->root)->as.program.items;
  const NodeId *const ids = ast_list(a, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const it = ast_at_const(a, ids[i]);
    if (it->kind != NODE_EXTEND)
      continue;
    const NodeList ms = it->as.extend_def.items;
    const NodeId *const mids = ast_list(a, ms);
    for (uint32_t j = 0; j < ms.len; j++)
      if (mids[j] == method)
        return ids[i];
  }
  return NODE_NONE;
}

// The interface (NODE_INTERFACE) an interface method belongs to, or NODE_NONE -- recovers the interface so a
// method reached through a generic bound substitutes its `Self` by the receiver type.
static NodeId enclosing_trait(TypeChecker *t, const ModuleId m, const NodeId method) {
  Ast *const a = mod_ast(t, m);
  const NodeList items = ast_at_const(a, a->root)->as.program.items;
  const NodeId *const ids = ast_list(a, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const it = ast_at_const(a, ids[i]);
    if (it->kind != NODE_INTERFACE)
      continue;
    const NodeList ms = it->as.interface_def.items;
    const NodeId *const mids = ast_list(a, ms);
    for (uint32_t j = 0; j < ms.len; j++)
      if (mids[j] == method)
        return ids[i];
  }
  return NODE_NONE;
}

typedef struct {
    DefId iface;
    uint8_t n;
    TypeId args[4];
} BoundIface;

static void add_bound_ifaces_full(TypeChecker *t, const ModuleId m, const NodeList bounds, BoundIface *const out,
                                  int *const n, const int cap) {
  Ast *const a = mod_ast(t, m);
  const NodeId *const ids = ast_list(a, bounds);
  for (uint32_t i = 0; i < bounds.len && *n < cap; i++) {
    const DefId d = ast_resolution_def(a, ids[i]);
    if (d.node == NODE_NONE)
      continue;
    BoundIface b = {.iface = d};
    const Node *const bn = ast_at_const(a, ids[i]);
    if (bn->kind == NODE_TYPE_PATH) {
      const NodeId *const aids = ast_list(a, bn->as.type_path.args);
      for (uint32_t k = 0; k < bn->as.type_path.args.len && b.n < 4; k++)
        b.args[b.n++] = lower_type_in(t, m, aids[k]);
    }
    out[(*n)++] = b;
  }
}

static int collect_param_bounds_full(TypeChecker *t, const ModuleId pmod, const NodeId pdecl, BoundIface *const out,
                                     const int cap) {
  int n = 0;
  Ast *const pa = mod_ast(t, pmod);
  add_bound_ifaces_full(t, pmod, ast_at_const(pa, pdecl)->as.generic_param.bounds, out, &n, cap);
  if (pmod == t->ast->module && t->current_fn != NODE_NONE) {
    const NodeList wc = ast_at_const(t->ast, t->current_fn)->as.function.where_clause;
    const NodeId *const wids = ast_list(t->ast, wc);
    for (uint32_t w = 0; w < wc.len; w++) {
      const Node *const wp = ast_at_const(t->ast, wids[w]);
      if (ast_resolution(t->ast, wp->as.where_predicate.type) == pdecl)
        add_bound_ifaces_full(t, t->ast->module, wp->as.where_predicate.bounds, out, &n, cap);
    }
  }
  return n;
}

static bool trait_contains_method(TypeChecker *t, const DefId iface, const DefId method, const int depth) {
  if (iface.node == NODE_NONE || depth > 8)
    return false;
  Ast *const ia = mod_ast(t, iface.module);
  const Node *const idn = ast_at_const(ia, iface.node);
  if (idn->kind != NODE_INTERFACE)
    return false;
  const NodeId *const mids = ast_list(ia, idn->as.interface_def.items);
  for (uint32_t i = 0; i < idn->as.interface_def.items.len; i++)
    if (iface.module == method.module && mids[i] == method.node)
      return true;
  const NodeId *const bids = ast_list(ia, idn->as.interface_def.bounds);
  for (uint32_t i = 0; i < idn->as.interface_def.bounds.len; i++)
    if (trait_contains_method(t, ast_resolution_def(ia, bids[i]), method, depth + 1))
      return true;
  return false;
}

static int bound_method_subst(TypeChecker *t, const ModuleId pmod, const NodeId pdecl, const DefId method,
                              DefId *const outp, TypeId *const outa, const int cap) {
  BoundIface ifaces[8];
  const int ni = collect_param_bounds_full(t, pmod, pdecl, ifaces, 8);
  for (int i = 0; i < ni; i++) {
    if (!trait_contains_method(t, ifaces[i].iface, method, 0))
      continue;
    Ast *const ia = mod_ast(t, ifaces[i].iface.module);
    const Node *const idn = ast_at_const(ia, ifaces[i].iface.node);
    const NodeId *const gids = ast_list(ia, idn->as.interface_def.generics);
    int n = 0;
    for (uint32_t g = 0; g < idn->as.interface_def.generics.len && g < ifaces[i].n && n < cap; g++) {
      outp[n] = (DefId){ifaces[i].iface.module, gids[g]};
      outa[n] = ifaces[i].args[g];
      n++;
    }
    return n;
  }
  return 0;
}

// A method named `name` declared by an interface bound in effect for generic param `pdecl` (`<T: Writer>`,
// a `where` clause, or a conditional extension): the interface method's DefId, with the satisfying
// interface returned via *iface; {_,NODE_NONE} if none.
static DefId find_bound_method(TypeChecker *t, const ModuleId pmod, const NodeId pdecl, const Span name,
                               DefId *const iface) {
  BoundIface ifaces[8];
  const int ni = collect_param_bounds_full(t, pmod, pdecl, ifaces, 8);
  for (int b = 0; b < ni; b++) {
    const DefId id = ifaces[b].iface;
    const DefId m = find_interface_method(t, id.module, id.node, name, 0);
    if (m.node != NODE_NONE) {
      if (iface)
        *iface = id;
      return m;
    }
  }
  return (DefId){0, NODE_NONE};
}

// Does interface `iface` (or one of its superinterfaces) declare a method named `m`?
static bool interface_declares_cstr(TypeChecker *t, const DefId iface, const char *const m, const int depth) {
  if (depth > 8 || iface.node == NODE_NONE)
    return false;
  Ast *const a = mod_ast(t, iface.module);
  const Node *const idn = ast_at_const(a, iface.node);
  if (idn->kind != NODE_INTERFACE)
    return false;
  const NodeId *const mids = ast_list(a, idn->as.interface_def.items);
  for (uint32_t i = 0; i < idn->as.interface_def.items.len; i++) {
    const Node *const mn = ast_at_const(a, mids[i]);
    if (mn->kind == NODE_FUNCTION && span_is(mod_src(t, iface.module), ast_at_const(a, mn->as.function.name)->as.name.text, m))
      return true;
  }
  const NodeId *const bids = ast_list(a, idn->as.interface_def.bounds);
  for (uint32_t i = 0; i < idn->as.interface_def.bounds.len; i++)
    if (interface_declares_cstr(t, ast_resolution_def(a, bids[i]), m, depth + 1))
      return true;
  return false;
}

// Does generic param (pmod, pdecl) carry a bound whose interface provides a method named `m`? This gates
// operator use on a type parameter: `a + b` / `a < b` on a bare `<T>` is only sound when T: Add / T: Ord.
static bool tc_param_bound_provides(TypeChecker *t, const ModuleId pmod, const NodeId pdecl, const char *const m) {
  BoundIface ifaces[8];
  const int ni = collect_param_bounds_full(t, pmod, pdecl, ifaces, 8);
  for (int b = 0; b < ni; b++)
    if (interface_declares_cstr(t, ifaces[b].iface, m, 0))
      return true;
  return false;
}

// An `extend [<G>] <tdecl> as <iface>` extend in `tdecl`'s module or the current module (a local extension);
// NODE_NONE if absent. *imod receives the extend's module.
static NodeId find_extend_as(TypeChecker *t, const ModuleId tmod, const NodeId tdecl, const DefId iface,
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
      if (it->kind != NODE_EXTEND || it->as.extend_def.interface_type == NODE_NONE || it->as.extend_def.target_type == NODE_NONE)
        continue;
      const DefId tr = ast_resolution_def(a, it->as.extend_def.interface_type);
      const DefId tg = ast_resolution_def(a, it->as.extend_def.target_type);
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
  if (y->kind == TYPE_DYN) // a trait object satisfies exactly its own interface bound
    return y->module == iface.module && y->as.decl == iface.node;
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
  } else if (y->kind == TYPE_BUILTIN && t->package) {
    const NodeId bd = package_builtin_decl(t->package, y->as.builtin); // a builtin conforms via `extend i32 as iface`
    if (bd == NODE_NONE)
      return false;
    tmod = t->package->core_module;
    tdecl = bd;
  } else {
    return false; // a pointer/etc. with no `as iface` extend
  }
  ModuleId imod;
  const NodeId extend = find_extend_as(t, tmod, tdecl, iface, &imod);
  if (extend == NODE_NONE)
    return false;
  // Conditional extension: each extend generic param's bounds must hold for the matching instance arg.
  Ast *const ia = mod_ast(t, imod);
  const NodeList gens = ast_at_const(ia, extend)->as.extend_def.generics;
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

// Is interface item `m` a vtable entry: a method taking `self`? Self-less (static) methods are not
// dispatchable through a value, so they stay out of the vtable without blocking dyn-compatibility.
static bool dyn_method(const Ast *ia, const uint8_t *const isrc, const Node *const m) {
  if (m->kind != NODE_FUNCTION || !m->as.function.params.len)
    return false;
  const Node *const p0 = ast_at_const(ia, ast_list(ia, m->as.function.params)[0]);
  return span_is(isrc, ast_at_const(ia, p0->as.parameter.name)->as.name.text, "self");
}

// Does type node `tn` (in interface module `ia`) mention the interface's own `Self` (a path resolving
// to `iface`)? A vtable-dispatched signature cannot name the erased type outside the receiver.
static bool tc_mentions_self(const Ast *ia, const NodeId tn, const DefId iface) {
  if (tn == NODE_NONE)
    return false;
  const Node *const n = ast_at_const(ia, tn);
  switch (n->kind) {
    case NODE_TYPE_PATH: {
      const DefId d = ast_resolution_def(ia, tn);
      if (d.module == iface.module && d.node == iface.node)
        return true;
      const NodeId *const aid = ast_list(ia, n->as.type_path.args);
      for (uint32_t i = 0; i < n->as.type_path.args.len; i++)
        if (tc_mentions_self(ia, aid[i], iface))
          return true;
      return false;
    }
    case NODE_POINTER_TYPE:
    case NODE_REFERENCE_TYPE:
    case NODE_SLICE_TYPE:
    case NODE_DYN_TYPE:
      return tc_mentions_self(ia, n->as.indirect_type.type, iface);
    case NODE_ARRAY_TYPE:
      return tc_mentions_self(ia, n->as.array_type.element, iface);
    case NODE_TUPLE_TYPE: {
      const NodeId *const eid = ast_list(ia, n->as.array_literal.elements);
      for (uint32_t i = 0; i < n->as.array_literal.elements.len; i++)
        if (tc_mentions_self(ia, eid[i], iface))
          return true;
      return false;
    }
    case NODE_FUNCTION_TYPE: {
      const NodeId *const pid = ast_list(ia, n->as.function_type.params);
      for (uint32_t i = 0; i < n->as.function_type.params.len; i++)
        if (tc_mentions_self(ia, pid[i], iface))
          return true;
      const NodeId *const rid = ast_list(ia, n->as.function_type.returns);
      for (uint32_t i = 0; i < n->as.function_type.returns.len; i++)
        if (tc_mentions_self(ia, rid[i], iface))
          return true;
      return false;
    }
    default:
      return false;
  }
}

// A dyn-compatible interface can be dispatched through a vtable: no interface generics or
// superinterfaces (v1), and every self-taking method takes `Self` by reference, mentions `Self`
// nowhere else, has no own generics, and returns at most one value. Reports the reason at `at`.
static bool dyn_compatible(TypeChecker *t, const DefId iface, const Span at) {
  Ast *const ia = mod_ast(t, iface.module);
  const uint8_t *const isrc = mod_src(t, iface.module);
  const Node *const idn = ast_at_const(ia, iface.node);
  const char *why = NULL;
  Span mn = {0, 0};
  if (idn->as.interface_def.generics.len)
    why = "the interface has generic parameters";
  else if (idn->as.interface_def.bounds.len)
    why = "the interface has superinterfaces";
  const NodeId *const mids = ast_list(ia, idn->as.interface_def.items);
  for (uint32_t i = 0; !why && i < idn->as.interface_def.items.len; i++) {
    const Node *const m = ast_at_const(ia, mids[i]);
    if (!dyn_method(ia, isrc, m))
      continue;
    mn = ast_at_const(ia, m->as.function.name)->as.name.text;
    const NodeId st = ast_at_const(ia, ast_list(ia, m->as.function.params)[0])->as.parameter.type;
    const NodeKind sk = st != NODE_NONE ? ast_at_const(ia, st)->kind : NODE_NONE_KIND;
    if (m->as.function.generics.len)
      why = "a method has its own generic parameters";
    else if (sk != NODE_REFERENCE_TYPE && sk != NODE_POINTER_TYPE)
      why = "a method takes 'Self' by value";
    else if (m->as.function.returns.len > 1)
      why = "a method has multiple return values";
    const NodeId *const pids = ast_list(ia, m->as.function.params);
    for (uint32_t p = 1; !why && p < m->as.function.params.len; p++)
      if (tc_mentions_self(ia, ast_at_const(ia, pids[p])->as.parameter.type, iface))
        why = "a method mentions 'Self' outside the receiver";
    const NodeId *const rids = ast_list(ia, m->as.function.returns);
    for (uint32_t r = 0; !why && r < m->as.function.returns.len; r++) {
      const Node *const rn = ast_at_const(ia, rids[r]);
      if (tc_mentions_self(ia, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : rids[r], iface))
        why = "a method mentions 'Self' outside the receiver";
    }
  }
  if (!why)
    return true;
  const Span in = ast_at_const(ia, idn->as.interface_def.name)->as.name.text;
  typechecker_errorf(t, at.start, at.end - at.start, "interface '%.*s' is not dyn-compatible: %s",
                     (int)(in.end - in.start), (const char *)isrc + in.start, why);
  if (mn.end > mn.start)
    typechecker_notef(t, "offending method: '%.*s'", (int)(mn.end - mn.start), (const char *)isrc + mn.start);
  return false;
}

// `&T` -> `&dyn I` erasure at `node`: T must implement I and every vtable method must resolve to an
// emittable concrete symbol. Records the site for codegen (fat-pair materialization + vtable emission).
static bool dyn_coerce(TypeChecker *t, const NodeId node, const TypeId src, const TypeId dyn_ty) {
  const Ty *const dy = ast_type_at(t->ast, dyn_ty);
  const DefId iface = {dy->module, dy->as.decl};
  const Ty *const sy = ast_type_at(t->ast, src);
  const Span sp = ast_at_const(t->ast, node)->span;
  if (sy->kind == TYPE_GENERIC) {
    typechecker_errorf(t, sp.start, sp.end - sp.start, "cannot erase a generic type parameter to 'dyn'");
    return true; // reported; suppress the cascading mismatch
  }
  if (!type_satisfies(t, src, iface, 0))
    return false; // plain mismatch: T does not implement I
  ModuleId tmod;
  NodeId tdecl;
  DefId gp[4];
  TypeId ga[4];
  int gn;
  if (!aggregate_of(t, src, &tmod, &tdecl, gp, ga, &gn)) {
    if (sy->kind == TYPE_BUILTIN && t->package && package_builtin_decl(t->package, sy->as.builtin) != NODE_NONE) {
      tmod = t->package->core_module;
      tdecl = package_builtin_decl(t->package, sy->as.builtin);
    } else {
      return false;
    }
  }
  // Every vtable method needs a concrete symbol: the type's own extend method or a same-module default.
  Ast *const ia = mod_ast(t, iface.module);
  const uint8_t *const isrc = mod_src(t, iface.module);
  const Node *const idn = ast_at_const(ia, iface.node);
  const NodeId *const mids = ast_list(ia, idn->as.interface_def.items);
  for (uint32_t i = 0; i < idn->as.interface_def.items.len; i++) {
    const Node *const m = ast_at_const(ia, mids[i]);
    if (!dyn_method(ia, isrc, m))
      continue;
    const Span mn = ast_at_const(ia, m->as.function.name)->as.name.text;
    char nm[96];
    snprintf(nm, sizeof nm, "%.*s", (int)(mn.end - mn.start), (const char *)isrc + mn.start);
    if (find_method_cstr(t, tmod, tdecl, nm).node != NODE_NONE)
      continue;
    // No override: a default body is emittable only when the `extend .. as I` lives in I's own
    // module (emit_default_methods synthesizes `T__method` there; its symbol is what glue calls).
    ModuleId emod = 0;
    if (m->as.function.body != NODE_NONE && find_extend_as(t, tmod, tdecl, iface, &emod) != NODE_NONE &&
        emod == iface.module)
      continue;
    char tn[96];
    render_type(t, src, tn, sizeof tn);
    typechecker_errorf(t, sp.start, sp.end - sp.start,
                       "cannot erase '%s' to 'dyn': method '%s' has no emittable implementation", tn, nm);
    typechecker_notef(t, "a default method body of a cross-module interface cannot back a vtable; override it");
    return true; // reported
  }
  ast_add_dyn_use(t->ast, node, src, dyn_ty);
  return true;
}

static bool method_extend_bounds_hold(TypeChecker *t, const TypeId target, const DefId md) {
  if (target == TYPE_NONE || md.node == NODE_NONE)
    return true;
  const NodeId extend = enclosing_extend(t, md.module, md.node);
  if (extend == NODE_NONE)
    return true;
  Ast *const ia = mod_ast(t, md.module);
  const Node *const in = ast_at_const(ia, extend);
  const NodeList gens = in->as.extend_def.generics;
  if (gens.len == 0)
    return true;
  ModuleId tm;
  NodeId td;
  DefId gp[4];
  TypeId ga[4];
  int gn = 0;
  if (!aggregate_of(t, strip(t, target), &tm, &td, gp, ga, &gn))
    return true;
  const NodeId *const gids = ast_list(ia, gens);
  for (uint32_t g = 0; g < gens.len; g++) {
    if ((int)g >= gn)
      return false;
    const NodeList gb = ast_at_const(ia, gids[g])->as.generic_param.bounds;
    const NodeId *const gbids = ast_list(ia, gb);
    for (uint32_t b = 0; b < gb.len; b++) {
      const DefId bi = ast_resolution_def(ia, gbids[b]);
      if (bi.node != NODE_NONE && !type_satisfies(t, ga[g], bi, 0))
        return false;
    }
  }
  return true;
}

static void err_method_extend_bounds(TypeChecker *t, const Span at, const TypeId target, const DefId md) {
  char ty[96];
  render_type(t, strip(t, target), ty, sizeof ty);
  Ast *const ma = mod_ast(t, md.module);
  const Node *const fn = ast_at_const(ma, md.node);
  const Span mn = ast_at_const(ma, fn->as.function.name)->as.name.text;
  typechecker_errorf(t, at.start, at.end - at.start, "cannot call '%s::%.*s': unsatisfied interface bounds", ty,
                     (int)(mn.end - mn.start), (const char *)mod_src(t, md.module) + mn.start);

  const NodeId impl_id = enclosing_extend(t, md.module, md.node);
  if (impl_id == NODE_NONE)
    return;
  const Node *const extend = ast_at_const(ma, impl_id);
  const NodeList gens = extend->as.extend_def.generics;
  if (gens.len == 0)
    return;
  ModuleId tm;
  NodeId td;
  DefId gp[4];
  TypeId ga[4];
  int gn = 0;
  if (!aggregate_of(t, strip(t, target), &tm, &td, gp, ga, &gn))
    return;

  char missing[512] = "";
  const NodeId *const gids = ast_list(ma, gens);
  for (uint32_t g = 0; g < gens.len && (int)g < gn; g++) {
    const NodeList gb = ast_at_const(ma, gids[g])->as.generic_param.bounds;
    const NodeId *const gbids = ast_list(ma, gb);
    for (uint32_t b = 0; b < gb.len; b++) {
      const DefId bi = ast_resolution_def(ma, gbids[b]);
      if (bi.node == NODE_NONE || type_satisfies(t, ga[g], bi, 0))
        continue;
      char arg[96], item[160];
      render_type(t, ga[g], arg, sizeof arg);
      const Span bs = ast_at_const(ma, gbids[b])->span;
      snprintf(item, sizeof item, "`%s: %.*s`", arg, (int)(bs.end - bs.start), (const char *)mod_src(t, md.module) + bs.start);
      if (strstr(missing, item))
        continue;
      if (missing[0])
        strncat(missing, ", ", sizeof missing - strlen(missing) - 1);
      strncat(missing, item, sizeof missing - strlen(missing) - 1);
    }
  }
  if (missing[0])
    typechecker_notef(t, "missing bounds: %s", missing);
  typechecker_notef(t, "these bounds come from the extend block that defines '%.*s'",
                    (int)(mn.end - mn.start), (const char *)mod_src(t, md.module) + mn.start);
}

static NodeId find_extend_item_named(TypeChecker *t, const Node *const extend, const Span name, const ModuleId nmod) {
  const NodeList have = extend->as.extend_def.items;
  const NodeId *const hids = ast_list(t->ast, have);
  for (uint32_t j = 0; j < have.len; j++) {
    const Node *const hm = ast_at_const(t->ast, hids[j]);
    if (hm->kind == NODE_FUNCTION &&
        spans_eq2(mod_src(t, nmod), name, t->source, ast_at_const(t->ast, hm->as.function.name)->as.name.text))
      return hids[j];
  }
  return NODE_NONE;
}

static bool extend_method_signature_matches(TypeChecker *t, const DefId req, const NodeId have, const DefId *const subp,
                                          const TypeId *const suba, const int nsub) {
  Ast *const ra = mod_ast(t, req.module);
  const Node *const rf = ast_at_const(ra, req.node);
  const Node *const hf = ast_at_const(t->ast, have);
  if (rf->as.function.params.len != hf->as.function.params.len)
    return false;
  const NodeId *const rp = ast_list(ra, rf->as.function.params);
  const NodeId *const hp = ast_list(t->ast, hf->as.function.params);
  for (uint32_t i = 0; i < rf->as.function.params.len; i++) {
    TypeId rt = lower_type_in(t, req.module, ast_at_const(ra, rp[i])->as.parameter.type);
    rt = subst_type(t, rt, subp, suba, nsub);
    const TypeId ht = lower_type_in(t, t->ast->module, ast_at_const(t->ast, hp[i])->as.parameter.type);
    if (rt != ht && (i != 0 || !receiver_type_eq(t, rt, ht)))
      return false;
  }
  if (rf->as.function.returns.len != hf->as.function.returns.len) {
    if (rf->as.function.returns.len > 1 || hf->as.function.returns.len > 1)
      return false;
    TypeId rt = TYPE_NONE, ht = TYPE_NONE;
    if (rf->as.function.returns.len == 1) {
      const NodeId rr = ast_list(ra, rf->as.function.returns)[0];
      const Node *const rn = ast_at_const(ra, rr);
      rt = lower_type_in(t, req.module, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : rr);
      rt = subst_type(t, rt, subp, suba, nsub);
    }
    if (hf->as.function.returns.len == 1) {
      const NodeId hr = ast_list(t->ast, hf->as.function.returns)[0];
      const Node *const hn = ast_at_const(t->ast, hr);
      ht = lower_type_in(t, t->ast->module, hn->kind == NODE_PARAMETER ? hn->as.parameter.type : hr);
    }
    return ret_eq(rt, ht);
  }
  const NodeId *const rr = ast_list(ra, rf->as.function.returns);
  const NodeId *const hr = ast_list(t->ast, hf->as.function.returns);
  for (uint32_t i = 0; i < rf->as.function.returns.len; i++) {
    const Node *const rn = ast_at_const(ra, rr[i]);
    const Node *const hn = ast_at_const(t->ast, hr[i]);
    TypeId rt = lower_type_in(t, req.module, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : rr[i]);
    rt = subst_type(t, rt, subp, suba, nsub);
    const TypeId ht = lower_type_in(t, t->ast->module, hn->kind == NODE_PARAMETER ? hn->as.parameter.type : hr[i]);
    if (!ret_eq(rt, ht))
      return false;
  }
  return true;
}

static void check_interface_requirements(TypeChecker *t, const Node *const extend, const DefId iface, const TypeId self_ty,
                                     const DefId *const subp, const TypeId *const suba, const int nsub, const int depth) {
  if (iface.node == NODE_NONE || depth > 8)
    return;
  Ast *const ia = mod_ast(t, iface.module);
  const Node *const idn = ast_at_const(ia, iface.node);
  if (idn->kind != NODE_INTERFACE)
    return;
  const NodeList req = idn->as.interface_def.items;
  const NodeId *const rids = ast_list(ia, req);
  for (uint32_t i = 0; i < req.len; i++) {
    const Node *const rm = ast_at_const(ia, rids[i]);
    if (rm->kind != NODE_FUNCTION || rm->as.function.body != NODE_NONE)
      continue; // only required (body-less) methods must be provided
    const Span rn = ast_at_const(ia, rm->as.function.name)->as.name.text;
    const NodeId hm = find_extend_item_named(t, extend, rn, iface.module);
    if (hm == NODE_NONE) {
      const Span at = ast_at_const(t->ast, extend->as.extend_def.interface_type)->span;
      typechecker_errorf(t, at.start, at.end - at.start, "missing method '%.*s' required by this interface",
                         (int)(rn.end - rn.start), (const char *)mod_src(t, iface.module) + rn.start);
      const Span in = ast_at_const(ia, idn->as.interface_def.name)->as.name.text;
      typechecker_notef(t, "required by interface '%.*s'", (int)(in.end - in.start), (const char *)mod_src(t, iface.module) + in.start);
    } else if (!extend_method_signature_matches(t, (DefId){iface.module, rids[i]}, hm, subp, suba, nsub)) {
      const Span at = ast_at_const(t->ast, hm)->span;
      typechecker_errorf(t, at.start, at.end - at.start, "method '%.*s' does not match interface signature",
                         (int)(rn.end - rn.start), (const char *)mod_src(t, iface.module) + rn.start);
      const Span in = ast_at_const(ia, idn->as.interface_def.name)->as.name.text;
      typechecker_notef(t, "expected the signature declared by interface '%.*s'", (int)(in.end - in.start),
                        (const char *)mod_src(t, iface.module) + in.start);
    }
  }
  const NodeList bounds = idn->as.interface_def.bounds;
  const NodeId *const bids = ast_list(ia, bounds);
  for (uint32_t i = 0; i < bounds.len; i++) {
    const DefId sb = ast_resolution_def(ia, bids[i]);
    if (sb.node != NODE_NONE && !type_satisfies(t, self_ty, sb, 0)) {
      const Span at = ast_at_const(t->ast, extend->as.extend_def.interface_type)->span;
      const Span sn = ast_at_const(mod_ast(t, sb.module), ast_at_const(mod_ast(t, sb.module), sb.node)->as.interface_def.name)->as.name.text;
      typechecker_errorf(t, at.start, at.end - at.start, "type does not satisfy required superinterface '%.*s'",
                         (int)(sn.end - sn.start), (const char *)mod_src(t, sb.module) + sn.start);
      const Span in = ast_at_const(ia, idn->as.interface_def.name)->as.name.text;
      typechecker_notef(t, "implement '%.*s' for this type before or alongside '%.*s'",
                        (int)(sn.end - sn.start), (const char *)mod_src(t, sb.module) + sn.start,
                        (int)(in.end - in.start), (const char *)mod_src(t, iface.module) + in.start);
    }
  }
}

// `extend T as Iface { ... }` must provide every required method with the full required signature.
static void check_extend_conformance(TypeChecker *t, const Node *const n) {
  const DefId iface = ast_resolution_def(t->ast, n->as.extend_def.interface_type);
  if (iface.node == NODE_NONE)
    return;
  const TypeId self_ty = resolve_type(t, n->as.extend_def.target_type);
  DefId subp[8];
  TypeId suba[8];
  int nsub = 0;
  subp[nsub] = (DefId){iface.module, iface.node};
  suba[nsub++] = self_ty;
  Ast *const ia = mod_ast(t, iface.module);
  const Node *const idn = ast_at_const(ia, iface.node);
  const Node *const tt = ast_at_const(t->ast, n->as.extend_def.interface_type);
  if (idn->kind == NODE_INTERFACE && tt->kind == NODE_TYPE_PATH) {
    const NodeId *const gids = ast_list(ia, idn->as.interface_def.generics);
    const NodeId *const aids = ast_list(t->ast, tt->as.type_path.args);
    for (uint32_t i = 0; i < idn->as.interface_def.generics.len && i < tt->as.type_path.args.len && nsub < 8; i++) {
      subp[nsub] = (DefId){iface.module, gids[i]};
      suba[nsub] = resolve_type(t, aids[i]);
      nsub++;
    }
  }
  check_interface_requirements(t, n, iface, self_ty, subp, suba, nsub, 0);
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
    case NODE_INTERFACE: // `Self` inside an interface: an abstract type, substituted to the receiver at use
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
        const int bb = package_builtin_of_decl(t->package, d.module, d.node);
        if (bb >= 0)
          return ast_builtin((BuiltinType)bb);
        const Node *const dn = ast_at_const(mod_ast(t, d.module), d.node);
        const NodeList args = n->as.type_path.args;
        // A foreign signature's `Box<dyn I>`: the intercepted owned trait object, not a Box instance.
        if (args.len == 1 && t->package) {
          const Node *const an = ast_at_const(a, ast_list(a, args)[0]);
          if (an->kind == NODE_DYN_TYPE && an->as.indirect_type.qualifier == TYPE_QUAL_NONE) {
            ModuleId bm;
            const NodeId bx = package_prelude_lookup(t->package, "Box", 3, true, &bm);
            if (d.module == bm && d.node == bx)
              return lower_type_in(t, m, ast_list(a, args)[0]);
          }
        }
        if ((dn->kind == NODE_STRUCT || dn->kind == NODE_ENUM) && dn->as.aggregate.generics.len > 0 &&
            (args.len > 0 || agg_has_default_at(t, d.module, dn, args.len))) {
          const NodeId *const aids = ast_list(a, args); // a foreign generic application (Box<T>) -> an instance
          TypeId ta[4];
          uint8_t tn = 0;
          for (uint32_t i = 0; i < args.len && tn < 4; i++) {
            ta[tn] = lower_type_in(t, m, aids[i]);
            // A fixed-size array carries no length in the interned `Ty` (8 bytes, no room), so it cannot be a
            // generic type argument -- it would mangle without its length and lower to a decayed pointer field.
            if (ta[tn] != TYPE_NONE && ast_type_at(t->ast, ta[tn])->kind == TYPE_ARRAY &&
                ast_type_at(t->ast, ta[tn])->as.arr.len == 0) { // --const-eval folded lengths are allowed
              const Span asp = ast_at_const(a, aids[i])->span;
              typechecker_errorf(t, asp.start, asp.end - asp.start,
                                 "a fixed-size array cannot be a generic type argument; use a slice '[]T' or wrap it in a struct");
              ta[tn] = TYPE_NONE;
            }
            tn++;
          }
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
    case NODE_TUPLE_TYPE: { // `(T1, T2, ..)` -> Tuple<n>, lowered in the signature's own module
      const NodeList elems = n->as.array_literal.elements;
      const NodeId *const eids = ast_list(a, elems);
      if (elems.len > 4)
        return TYPE_ERROR; // diagnosed where the type is written (resolve_type)
      TypeId targs[4];
      for (uint32_t i = 0; i < elems.len; i++)
        targs[i] = lower_type_in(t, m, eids[i]);
      return prelude_tuple_type(t, targs, elems.len);
    }
    case NODE_POINTER_TYPE:
    case NODE_REFERENCE_TYPE: {
      const TypeKind k = n->kind == NODE_POINTER_TYPE ? TYPE_POINTER : TYPE_REFERENCE;
      return ast_intern_type(
          t->ast, (Ty){.kind = k, .qualifier = n->as.indirect_type.qualifier, .as.elem = lower_type_in(t, m, n->as.indirect_type.type)});
    }
    case NODE_ARRAY_TYPE: {
      uint32_t alen = 0;
      const ConstValue lv = consteval_eval(tc_ceval(t), m, n->as.array_type.length);
      if (lv.kind == CONST_INT && lv.i > 0 && lv.i <= UINT32_MAX)
        alen = (uint32_t)lv.i;
      return ast_intern_type(
          t->ast, (Ty){.kind = TYPE_ARRAY, .as.arr = {.elem = lower_type_in(t, m, n->as.array_type.element), .len = alen}});
    }
    case NODE_FUNCTION_TYPE:
      return ast_intern_type(t->ast, (Ty){.kind = TYPE_FUNCTION, .module = m, .as.decl = id});
    case NODE_DYN_TYPE: { // a foreign signature's `&[mut] dyn ..` (its own module already validated it)
      const NodeId inner = n->as.indirect_type.type;
      if (ast_at_const(a, inner)->kind == NODE_FUNCTION_TYPE)
        return tc_intern_dynfn(t, m, inner, n->as.indirect_type.qualifier);
      const DefId d = ast_at_const(a, inner)->kind == NODE_TYPE_PATH ? ast_resolution_def(a, inner)
                                                                     : (DefId){0, NODE_NONE};
      if (d.node == NODE_NONE || ast_at_const(mod_ast(t, d.module), d.node)->kind != NODE_INTERFACE)
        return TYPE_ERROR;
      return ast_intern_type(
          t->ast, (Ty){.kind = TYPE_DYN, .qualifier = n->as.indirect_type.qualifier, .module = d.module, .as.decl = d.node});
    }
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

static int prelude_instance_args(TypeChecker *t, TypeId tid, const char *name, size_t nl, TypeId *out, int maxn);

// `(T1, .., Tn)` -> the prelude's `Tuple<n>` instance (mirrors slices/ranges: a tuple is an ordinary
// prelude struct with fields `_0`.. so all downstream machinery is the plain generic-instance path).
static TypeId prelude_tuple_type(TypeChecker *t, const TypeId *const args, const uint32_t n) {
  if (!t->package || n < 2 || n > 4)
    return TYPE_ERROR;
  const char *const names[3] = {"Tuple2", "Tuple3", "Tuple4"};
  ModuleId mid;
  const NodeId d = package_prelude_lookup(t->package, names[n - 2], 6, true, &mid);
  return d != NODE_NONE ? ast_intern_instance(t->ast, mid, d, args, (uint8_t)n) : TYPE_ERROR;
}

// The element types of a tuple-instance type, or -1 (mirrors slice_kind for `Tuple2`/`Tuple3`/`Tuple4`).
static int tuple_args_of(TypeChecker *t, const TypeId tid, TypeId *const out, const int maxn) {
  static const char *const names[3] = {"Tuple2", "Tuple3", "Tuple4"};
  for (int k = 0; k < 3; k++) {
    const int n = prelude_instance_args(t, tid, names[k], 6, out, maxn);
    if (n >= 0)
      return n;
  }
  return -1;
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

// Canonicalize a `dyn fn` identity within this pool: fn types intern per annotation NODE, but every
// same-signature `dyn fn` must yield ONE TypeId or generic instances over it (Vector<Box<dyn fn..>>)
// would never unify. The first-seen signature's (module, node) becomes the pool's canonical identity.
static TypeId tc_intern_dynfn(TypeChecker *t, const ModuleId m, const NodeId sig, const TypeQualifier qual) {
  Ast *const a = t->ast;
  const TypeId mysig = lower_type_in(t, m, sig);
  for (TypeId i = 1; i < (TypeId)a->type_pool.len; i++) {
    const Ty e = a->type_pool.data[i]; // by value: the lowering below may grow (realloc) the pool
    if (e.kind != TYPE_DYN || ast_at_const(mod_ast(t, e.module), e.as.decl)->kind != NODE_FUNCTION_TYPE)
      continue;
    const TypeId esig = lower_type_in(t, e.module, e.as.decl);
    if (esig == mysig || fn_compatible(t, esig, mysig))
      return ast_intern_type(a, (Ty){.kind = TYPE_DYN, .qualifier = qual, .module = e.module, .as.decl = e.as.decl});
  }
  return ast_intern_type(a, (Ty){.kind = TYPE_DYN, .qualifier = qual, .module = m, .as.decl = sig});
}

// The TYPE_DYN behind a `dyn I` node, with `qual` as the flavor: the node's own for `&[mut] dyn I`,
// forced TYPE_QUAL_NONE by the intercepted owned `Box<dyn I>` spelling. Memoizes onto the node.
static TypeId resolve_dyn_node(TypeChecker *t, const NodeId id, const TypeQualifier qual) {
  Ast *const a = t->ast;
  const Node *const n = ast_at_const(a, id);
  const NodeId inner = n->as.indirect_type.type;
  TypeId result = TYPE_ERROR;
  // `dyn fn(..) ..`: a one-method anonymous interface over the signature (structural identity).
  // Calls only ever read the env, so there is no `&mut` flavor to spell.
  if (ast_at_const(a, inner)->kind == NODE_FUNCTION_TYPE) {
    const Node *const fn = ast_at_const(a, inner);
    bool concrete = qual != TYPE_QUAL_MUT;
    if (!concrete)
      typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                         "a 'dyn fn' is always called through a shared view; write '&dyn fn(..) ..'");
    const NodeId *const pid = ast_list(a, fn->as.function_type.params);
    for (uint32_t i = 0; concrete && i < fn->as.function_type.params.len; i++)
      concrete = ast_type_at(a, resolve_type(t, pid[i]))->kind != TYPE_GENERIC;
    const NodeId *const rid = ast_list(a, fn->as.function_type.returns);
    for (uint32_t i = 0; concrete && i < fn->as.function_type.returns.len; i++) {
      const Node *const rn = ast_at_const(a, rid[i]);
      concrete = ast_type_at(a, resolve_type(t, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : rid[i]))->kind !=
                 TYPE_GENERIC;
    }
    if (concrete)
      result = tc_intern_dynfn(t, a->module, inner, qual);
    else if (qual != TYPE_QUAL_MUT)
      typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                         "a 'dyn fn' signature cannot name a generic parameter");
    ast_set_type(a, id, result);
    return result;
  }
  const DefId d = ast_at_const(a, inner)->kind == NODE_TYPE_PATH ? ast_resolution_def(a, inner)
                                                                 : (DefId){0, NODE_NONE};
  if (d.node == NODE_NONE || ast_at_const(mod_ast(t, d.module), d.node)->kind != NODE_INTERFACE)
    typechecker_errorf(t, n->span.start, n->span.end - n->span.start, "'dyn' requires an interface");
  else if (dyn_compatible(t, d, n->span))
    result = ast_intern_type(a, (Ty){.kind = TYPE_DYN, .qualifier = qual, .module = d.module, .as.decl = d.node});
  ast_set_type(a, id, result);
  return result;
}

// Is `y` a prelude `Box<T, A>` instance? Yields T and whether A is the default `Global` allocator.
static bool tc_box_of(TypeChecker *t, const Ty *const y, TypeId *const inner, bool *const global_alloc) {
  if (y->kind != TYPE_INSTANCE || !t->package)
    return false;
  const TyInstance *const it = ast_instance(t->ast, y->as.inst);
  ModuleId bm;
  const NodeId bx = package_prelude_lookup(t->package, "Box", 3, true, &bm);
  if (it->module != bm || it->decl != bx || it->n < 1)
    return false;
  *inner = it->args[0];
  ModuleId gm;
  const NodeId gd = package_prelude_lookup(t->package, "Global", 6, true, &gm);
  const Ty *const ay = it->n >= 2 ? ast_type_at(t->ast, it->args[1]) : NULL;
  *global_alloc = ay && ay->kind == TYPE_STRUCT && ay->module == gm && ay->as.decl == gd;
  return true;
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
      // `Box<dyn I>` is intercepted: the OWNED trait object, NOT a Box instance (a per-type const
      // vtable cannot carry a stateful allocator, so only the default Box spelling erases). A bare
      // `dyn I` (qualifier NONE) under any other generic head has no meaning.
      for (uint32_t i = 0; i < args.len && t->package; i++) {
        const Node *const an = ast_at_const(a, arg_ids[i]);
        if (an->kind != NODE_DYN_TYPE || an->as.indirect_type.qualifier != TYPE_QUAL_NONE)
          continue;
        ModuleId bm;
        const NodeId bx = package_prelude_lookup(t->package, "Box", 3, true, &bm);
        const DefId hd = ast_resolution_def(a, id);
        if (args.len == 1 && hd.module == bm && hd.node == bx) {
          result = resolve_dyn_node(t, arg_ids[0], TYPE_QUAL_NONE);
        } else {
          typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                             "a bare 'dyn' type can only be the generic argument of 'Box'");
        }
        ast_set_type(a, id, result);
        return result;
      }
      for (uint32_t i = 0; i < args.len; i++)
        resolve_type(t, arg_ids[i]); // resolve type args first so their TypeIds exist
      const DefId d = ast_resolution_def(a, id);
      if (d.node != NODE_NONE) {
        // A builtin's synthetic core decl (the target of `extend i32`, or a bare `Self` inside it) is still
        // the builtin value type, never a struct -- lower it back to the builtin.
        const int bb = t->package ? package_builtin_of_decl(t->package, d.module, d.node) : -1;
        if (bb >= 0) {
          result = ast_builtin((BuiltinType)bb);
          break;
        }
        const Node *const dn = ast_at_const(mod_ast(t, d.module), d.node);
        const bool generic_agg =
            (dn->kind == NODE_STRUCT || dn->kind == NODE_ENUM) && dn->as.aggregate.generics.len > 0;
        // A bare `Self` (or the bare target name) inside `extend .. Target<T> { }` means the FULL target
        // type `Target<T>`, not the argless struct -- so member access carries the extend's generics and
        // a `T` field unifies with a `T` return. Lower it to the extend's target_type (an instance).
        if (generic_agg && args.len == 0 && t->current_extend != NODE_NONE && d.module == a->module &&
            d.node == t->current_self) {
          const NodeId target = ast_at_const(a, t->current_extend)->as.extend_def.target_type;
          if (target != id) // guard against self-reference (target is `Target<T>`, a different node)
            result = resolve_type(t, target);
          else
            result = named_type_of(t, d.module, d.node);
        } else if (generic_agg && (args.len > 0 || agg_has_default_at(t, d.module, dn, args.len))) {
          // `Vec<i32>` -> an interned instance; a bare all-defaulted name (`String`) -> `String<Global>`.
          TypeId ta[4];
          uint8_t tn = 0;
          for (uint32_t i = 0; i < args.len && tn < 4; i++) {
            ta[tn] = resolve_type(t, arg_ids[i]);
            // A fixed-size array carries no length in the interned `Ty`, so it cannot be a generic type
            // argument -- it would mangle without its length and lower to a decayed pointer field.
            if (ta[tn] != TYPE_NONE && ast_type_at(t->ast, ta[tn])->kind == TYPE_ARRAY &&
                ast_type_at(t->ast, ta[tn])->as.arr.len == 0) { // --const-eval folded lengths are allowed
              const Span asp = ast_at_const(a, arg_ids[i])->span;
              typechecker_errorf(t, asp.start, asp.end - asp.start,
                                 "a fixed-size array cannot be a generic type argument; use a slice '[]T' or wrap it in a struct");
              ta[tn] = TYPE_NONE;
            }
            tn++;
          }
          apply_default_args(t, d.module, dn, ta, &tn);
          result = ast_intern_instance(t->ast, d.module, d.node, ta, tn);
        } else {
          result = named_type_of(t, d.module, d.node);
          // A bare interface is not a value type (it used to silently render as C `void`); only the
          // `Self` spelling inside an interface/extend legitimately lowers to the abstract type.
          if (dn->kind == NODE_INTERFACE && parts.len &&
              !span_is(t->source, name_span(t, ast_list(a, parts)[0]), "Self")) {
            const Span isp = name_span(t, ast_list(a, parts)[0]);
            typechecker_errorf(
                t, isp.start, isp.end - isp.start,
                "an interface is not a type; use '&dyn %.*s', 'Box<dyn %.*s>', or a generic bound",
                (int)(isp.end - isp.start), t->source + isp.start, (int)(isp.end - isp.start), t->source + isp.start);
          }
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
    case NODE_TUPLE_TYPE: { // `(T1, T2, ..)` -> the prelude's Tuple<n> instance
      const NodeList elems = n->as.array_literal.elements;
      const NodeId *const eids = ast_list(a, elems);
      if (elems.len > 4) {
        typechecker_errorf(t, n->span.start, n->span.end - n->span.start, "tuple arity is limited to 4 elements");
        break;
      }
      TypeId targs[4];
      for (uint32_t i = 0; i < elems.len; i++)
        targs[i] = resolve_type(t, eids[i]);
      result = prelude_tuple_type(t, targs, elems.len);
      break;
    }
    case NODE_POINTER_TYPE:
    case NODE_REFERENCE_TYPE: {
      const TypeKind k = n->kind == NODE_POINTER_TYPE ? TYPE_POINTER : TYPE_REFERENCE;
      result = ast_intern_type(
          a, (Ty){.kind = k, .qualifier = n->as.indirect_type.qualifier,
                    .as.elem = resolve_type(t, n->as.indirect_type.type)});
      break;
    }
    case NODE_ARRAY_TYPE: {
      check_expr(t, n->as.array_type.length);
      // A folded length becomes part of the TYPE ([i32;4] != [i32;8]); an
      // unfoldable length keeps len 0 (identity and rendering exactly as before).
      uint32_t alen = 0;
      const ConstValue lv = consteval_eval(tc_ceval(t), t->ast->module, n->as.array_type.length);
      if (lv.kind == CONST_INT && lv.i > 0 && lv.i <= UINT32_MAX)
        alen = (uint32_t)lv.i;
      result = ast_intern_type(
          a, (Ty){.kind = TYPE_ARRAY, .as.arr = {.elem = resolve_type(t, n->as.array_type.element), .len = alen}});
      break;
    }
    case NODE_FUNCTION_TYPE:
      result = ast_intern_type(a, (Ty){.kind = TYPE_FUNCTION, .module = a->module, .as.decl = id});
      break;
    case NODE_DYN_TYPE: {
      if (n->as.indirect_type.qualifier == TYPE_QUAL_NONE) {
        // Reached only OUTSIDE the `Box<dyn I>` interception: a bare `dyn I` is not a value type.
        typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                           "a 'dyn' type must be '&dyn I', '&mut dyn I', or 'Box<dyn I>'");
        break;
      }
      result = resolve_dyn_node(t, id, n->as.indirect_type.qualifier);
      break;
    }
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
  if (n->as.unary.op == Unsafe) // `unsafe expr` / `unsafe { .. }`: raw ops are legal inside the operand
    t->unsafe_depth++;
  const uint32_t bm = borrow_mark(t); // temporaries the operand creates (a ref-returning method's receiver)
  const TypeId opnd = check_expr(t, n->as.unary.operand);
  if (n->as.unary.op == Unsafe)
    t->unsafe_depth--;
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
      if (ot->kind == TYPE_POINTER || ot->kind == TYPE_REFERENCE) {
        if (ot->kind == TYPE_POINTER && !t->unsafe_depth)
          err_unsafe(t, sp, "dereferencing a raw pointer");
        // Dereferencing an RVALUE reference copies the value out and ENDS the reference: the shared
        // temporaries its computation registered (e.g. `v.at(2)`'s receiver borrow) expire here, so
        // `*v.at(2) + v.pop()` does not conflict (NLL). Mutable ones persist to the statement's end --
        // `*v.at_mut(2) = v.pop()` still stores through v while mutating it, and must conflict.
        if (!is_place(t, n->as.unary.operand))
          for (uint32_t i = bm; i < t->nborrows; i++)
            if (t->borrows[i].binding == NODE_NONE && t->borrows[i].kind == BORROW_SHARED)
              borrow_tombstone(&t->borrows[i]);
        return ot->as.elem;
      }
      typechecker_errorf(t, sp.start, sp.end - sp.start, "cannot dereference a non-pointer");
      return TYPE_NONE;
    }
    case Ampersand: { // address-of: `&x` -> `&T`, `&mut x` -> `&mut T`
      const bool mut = n->as.unary.qualifier == TYPE_QUAL_MUT;
      // A `&mut` borrow of a place needs that place to be mutable -- otherwise it would hand out write
      // access to an immutable binding. (An rvalue operand is a fresh temp, so it is left to codegen.)
      if (mut && is_place(t, n->as.unary.operand) && !is_assignable(t, n->as.unary.operand)) {
        const Span osp = ast_at_const(t->ast, n->as.unary.operand)->span;
        typechecker_errorf(t, osp.start, osp.end - osp.start,
                           "cannot take '&mut' of an immutable binding (bind it with 'mut')");
      }
      if (mut)
        tc_mark_capture_mut(t, n->as.unary.operand); // `&mut` of a capture -> a `&mut` capture
      {
        // Peel the transparent move/unsafe wrappers so the checks below see the real operand.
        NodeId op = n->as.unary.operand;
        const Node *on = ast_at_const(t->ast, op);
        while (on->kind == NODE_UNARY && (on->as.unary.op == Move || on->as.unary.op == Unsafe)) {
          op = on->as.unary.operand;
          on = ast_at_const(t->ast, op);
        }
        // `&mut x` on a deferred (`let mut x: T;`) binding hands it out as an out-parameter: the callee
        // is assumed to write it, so it counts as initialized (the borrow itself never reads it).
        if (mut && on->kind == NODE_IDENTIFIER) {
          const DefId od = ast_resolution_def(t->ast, op);
          if (od.module == t->ast->module && od.node != NODE_NONE)
            tc_init(t, od.node);
        }
        // The address of a value that codegen cannot materialize (a call/if/switch/block result, or an
        // operator result of aggregate type) has no C spelling -- `&(f())` is invalid C. Scalar rvalues
        // and compound-literal forms (struct/array/string literals, ranges) materialize fine.
        if (!is_place(t, op) && opnd != TYPE_NONE && ast_type_at(t->ast, opnd)->kind != TYPE_BUILTIN &&
            (on->kind == NODE_CALL || on->kind == NODE_IF || on->kind == NODE_MATCH || on->kind == NODE_BLOCK ||
             on->kind == NODE_BINARY || on->kind == NODE_ASSIGNMENT || on->kind == NODE_CAST)) {
          const Span osp = ast_at_const(t->ast, op)->span;
          typechecker_errorf(t, osp.start, osp.end - osp.start,
                             "cannot take the address of a temporary value; bind it to a 'let' first");
        }
      }
      // Borrow checker: register the borrow of the operand place and enforce the aliasing rule against
      // overlapping borrows already live in this expression context (shared XOR mutable). `id` is the origin.
      borrow_create(t, n->as.unary.operand, mut ? BORROW_MUT : BORROW_SHARED, id);
      return ast_intern_type(t->ast, (Ty){.kind = TYPE_REFERENCE, .qualifier = n->as.unary.qualifier, .as.elem = opnd});
    }
    case Question: { // `expr?`: unwrap Option<T>/Result<T,E>, else early-return None/Err from the function
      if (opnd == TYPE_NONE)
        return TYPE_NONE;
      const TypeId os = strip(t, opnd);
      TypeId oa[2], fa[2];
      const int nopt = prelude_instance_args(t, os, "Option", 6, oa, 2);
      const int nres = nopt >= 0 ? -1 : prelude_instance_args(t, os, "Result", 6, oa, 2);
      if (nopt < 0 && nres < 0) {
        typechecker_errorf(t, sp.start, sp.end - sp.start, "'?' requires an Option or Result operand");
        typechecker_notef(t, "the operand must be an Option<T> or Result<T, E> value");
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
        if (prelude_instance_args(t, frs, "Option", 6, fa, 2) < 0) {
          typechecker_errorf(t, sp.start, sp.end - sp.start, "'?' on an Option requires the function to return an Option");
          typechecker_notef(t, "change the function return type or handle None explicitly");
        }
        return oa[0]; // the Some payload type
      }
      if (prelude_instance_args(t, frs, "Result", 6, fa, 2) < 0) {
        typechecker_errorf(t, sp.start, sp.end - sp.start, "'?' on a Result requires the function to return a Result");
        typechecker_notef(t, "the function must return Result<_, E> with the same error type");
      }
      else if (oa[1] != fa[1]) { // differing error types: allowed when the caller's error has From<callee's>
        const DefId conv = tc_find_from_for(t, fa[1], oa[1]);
        if (conv.node != NODE_NONE) {
          ast_set_resolution_def(t->ast, id, conv); // codegen wraps the Err payload in Target__from(..)
        } else {
          char a1[96], a2[96];
          render_type(t, oa[1], a1, sizeof a1);
          render_type(t, fa[1], a2, sizeof a2);
          typechecker_errorf(t, sp.start, sp.end - sp.start,
                             "'?' error type '%s' does not match the function's error type '%s'", a1, a2);
          typechecker_notef(t, "convert with '.into()' before '?', or provide 'extend %s as From<%s>'", a2, a1);
        }
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
  if (ast_at_const(t->ast, ln)->kind == NODE_LITERAL && !tc_literal_pinned(t, ast_at_const(t->ast, ln)))
    return r; // l adapts to r (a suffixed literal is pinned and never adapts)
  if (ast_at_const(t->ast, rn)->kind == NODE_LITERAL && !tc_literal_pinned(t, ast_at_const(t->ast, rn)))
    return l; // r adapts to l
  if (bt_widens(bt_of(t, l), bt_of(t, r)))
    return r; // lossless widening also applies between operands: `x_u8 + y_i32` computes as i32
  if (bt_widens(bt_of(t, r), bt_of(t, l)))
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
  if (!t->unsafe_depth) // offsetting/differencing raw pointers escapes the borrow checker's view
    err_unsafe(t, sp, "raw pointer arithmetic");
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

// Build the substitution mapping method `md`'s enclosing extend generics onto receiver `recv`'s type args
// (so `fn f(self,..) T` reads T as the instance's element). Returns the substitution length (<= 4).
static int method_recv_subst(TypeChecker *t, const TypeId recv, const DefId md, DefId *const rsubp, TypeId *const rsuba) {
  int nrsub = 0;
  ModuleId rmod;
  NodeId rdecl;
  DefId sp[4];
  TypeId sa[4];
  int sn = 0;
  if (aggregate_of(t, strip(t, recv), &rmod, &rdecl, sp, sa, &sn) && sn > 0) {
    const NodeId extend = enclosing_extend(t, md.module, md.node);
    if (extend != NODE_NONE) {
      const NodeList ig = ast_at_const(mod_ast(t, md.module), extend)->as.extend_def.generics;
      const NodeId *const gids = ast_list(mod_ast(t, md.module), ig);
      const int g = (int)ig.len < sn ? (int)ig.len : sn;
      for (int i = 0; i < g && nrsub < 4; i++) {
        rsubp[nrsub] = (DefId){md.module, gids[i]};
        rsuba[nrsub] = sa[i];
        nrsub++;
      }
    }
  }
  return nrsub;
}

// The single return type of method `md` called on a receiver of type `recv`, with the receiver instance's
// args substituted through the method's enclosing extend generics (so `fn index(self,..) T` -> the element).
static TypeId tc_method_ret(TypeChecker *t, const TypeId recv, const DefId md) {
  Ast *const fa = mod_ast(t, md.module);
  const Node *const fn = ast_at_const(fa, md.node);
  if (fn->kind != NODE_FUNCTION || fn->as.function.returns.len != 1)
    return TYPE_NONE;
  DefId rsubp[4];
  TypeId rsuba[4];
  const int nrsub = method_recv_subst(t, recv, md, rsubp, rsuba);
  const NodeId r0 = ast_list(fa, fn->as.function.returns)[0];
  const Node *const rn = ast_at_const(fa, r0);
  const TypeId ret = lower_type_in(t, md.module, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : r0);
  return subst_type(t, ret, rsubp, rsuba, nrsub);
}

// The substituted type of method `md`'s parameter at position `idx` (0 = self), or TYPE_NONE if absent.
static TypeId tc_method_param(TypeChecker *t, const TypeId recv, const DefId md, const int idx) {
  Ast *const fa = mod_ast(t, md.module);
  const Node *const fn = ast_at_const(fa, md.node);
  if (fn->kind != NODE_FUNCTION || (int)fn->as.function.params.len <= idx)
    return TYPE_NONE;
  DefId rsubp[4];
  TypeId rsuba[4];
  const int nrsub = method_recv_subst(t, recv, md, rsubp, rsuba);
  const NodeId p = ast_list(fa, fn->as.function.params)[idx];
  const Node *const pn = ast_at_const(fa, p);
  const TypeId pt = lower_type_in(t, md.module, pn->kind == NODE_PARAMETER ? pn->as.parameter.type : p);
  return subst_type(t, pt, rsubp, rsuba, nrsub);
}

// Does the value at `operand` fit operator method parameter type `pt`? An operator auto-borrows its operand,
// so a value fits a `&T`/`&mut T` parameter when it fits the pointee. A TYPE_NONE param is unconstrained.
static bool operand_fits_param(TypeChecker *t, const TypeId pt, const NodeId operand) {
  if (pt == TYPE_NONE || compatible(t, pt, operand))
    return true;
  const Ty *const p = ast_type_at(t->ast, pt);
  return p->kind == TYPE_REFERENCE && compatible(t, p->as.elem, operand);
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
// to the interface), dispatch to its add/sub/mul/div/rem method; the result is that method's return type.
// Sets `*out` and returns true when handled (so the caller skips the builtin numeric path).
static bool check_arith_overload(TypeChecker *t, const Node *const n, const NodeId id, const TypeId l, TypeId *const out) {
  const char *const m = arith_method_name(n->as.binary.op);
  if (!m)
    return false;
  // Peel REFERENCE layers only (auto-deref receivers). A RAW-POINTER operand is pointer arithmetic
  // (`self.ptr + i` -- including a generic pointee `*const T`), never operator dispatch.
  TypeId ls = l;
  while (ls != TYPE_NONE && ast_type_at(t->ast, ls)->kind == TYPE_REFERENCE)
    ls = ast_type_at(t->ast, ls)->as.elem;
  if (ls != TYPE_NONE && ast_type_at(t->ast, ls)->kind == TYPE_POINTER)
    return false;
  const Ty *const lt = ls == TYPE_NONE ? NULL : ast_type_at(t->ast, ls);
  if (!lt)
    return false;
  if (lt->kind == TYPE_GENERIC) { // a bound `T: Add`; verified at instantiation, codegen dispatches
    if (!tc_param_bound_provides(t, lt->module, lt->as.decl, m)) {
      const Span sp = ast_at_const(t->ast, id)->span;
      char ty[96];
      render_type(t, ls, ty, sizeof ty);
      typechecker_errorf(t, sp.start, sp.end - sp.start,
                         "type parameter '%s' has no '%s' method for this operator (add a bound that provides it)", ty, m);
      *out = TYPE_NONE;
    }
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
      if (!method_extend_bounds_hold(t, ls, md)) {
        const Span sp = ast_at_const(t->ast, id)->span;
        err_method_extend_bounds(t, sp, ls, md);
        *out = TYPE_NONE;
        return true;
      }
      const TypeId p1 = tc_method_param(t, ls, md, 1); // the operator's right operand must match `add`'s 2nd param
      if (!operand_fits_param(t, p1, n->as.binary.right))
        err_mismatch(t, n->as.binary.right, p1);
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
      const bool ord = n->as.binary.op == LessThan || n->as.binary.op == LessThanEqual ||
                       n->as.binary.op == GreaterThan || n->as.binary.op == GreaterThanEqual;
      // Peel REFERENCE layers only: raw-pointer comparisons (`self.ptr == null`, `p < q` -- including a
      // generic pointee `*const T`) are plain C pointer comparisons, never eq/cmp dispatch.
      TypeId ls = l;
      while (ls != TYPE_NONE && ast_type_at(t->ast, ls)->kind == TYPE_REFERENCE)
        ls = ast_type_at(t->ast, ls)->as.elem;
      if (ls != TYPE_NONE && ast_type_at(t->ast, ls)->kind == TYPE_POINTER) {
        if (l != TYPE_NONE && r != TYPE_NONE && l != r && !compatible(t, l, rn) && !compatible(t, r, ln))
          err_mismatch(t, rn, l);
        return ast_builtin(BT_BOOL);
      }
      const Ty *const lt = ls == TYPE_NONE ? NULL : ast_type_at(t->ast, ls);
      if (lt && (lt->kind == TYPE_STRUCT || lt->kind == TYPE_INSTANCE)) {
        ModuleId om;
        NodeId od;
        DefId gp[4];
        TypeId ga[4];
        int gn;
        if (aggregate_of(t, ls, &om, &od, gp, ga, &gn)) {
          const DefId md = find_method_cstr(t, om, od, ord ? "cmp" : "eq");
          if (md.node == NODE_NONE) {
            char ty[96];
            render_type(t, ls, ty, sizeof ty);
            typechecker_errorf(t, sp.start, sp.end - sp.start, "'%s' has no '%s' method for this operator (implement %s)",
                               ty, ord ? "cmp" : "eq", ord ? "Ord" : "Eq");
            typechecker_notef(t, "operator overloads are resolved through interface-style methods");
          } else if (!method_extend_bounds_hold(t, ls, md)) {
            err_method_extend_bounds(t, sp, ls, md);
          } else {
            const TypeId p1 = tc_method_param(t, ls, md, 1); // the RHS must match eq/cmp's `other` parameter
            if (!operand_fits_param(t, p1, rn))
              err_mismatch(t, rn, p1);
          }
        }
        return ast_builtin(BT_BOOL);
      }
      if (lt && lt->kind == TYPE_GENERIC) { // requires a `T: Eq`/`T: Ord` bound; codegen dispatches at instantiation
        if (!tc_param_bound_provides(t, lt->module, lt->as.decl, ord ? "cmp" : "eq"))
          typechecker_errorf(t, sp.start, sp.end - sp.start,
                             "type parameter has no '%s' method for this operator (add a `%s` bound)", ord ? "cmp" : "eq",
                             ord ? "Ord" : "Eq");
        return ast_builtin(BT_BOOL);
      }
      if (l != TYPE_NONE && r != TYPE_NONE && l != r && !compatible(t, l, rn) && !compatible(t, r, ln))
        err_mismatch(t, rn, l);
      return ast_builtin(BT_BOOL);
    }
  }
}

// Can the lvalue at `node` be assigned to? A mutable `let`, a deref/index/member reached through
// something mutable. Parameters and consts are immutable.
// Does a `::` path value (`mod::NAME`) name a `static mut` global -- the one path form that is an
// assignable place?
static bool tc_path_static_mut(TypeChecker *t, const NodeId id) {
  const Node *const n = ast_at_const(t->ast, id);
  DefId d = ast_resolution_def(t->ast, id); // multi-segment module paths record on the outer node
  if (d.node == NODE_NONE)
    d = ast_resolution_def(t->ast, n->as.member.member); // local Type::X records on the member
  if (d.node == NODE_NONE)
    return false;
  const Node *const dn = ast_at_const(mod_ast(t, d.module), d.node);
  return dn->kind == NODE_CONST && dn->as.const_def.is_static_mut;
}

static bool is_assignable(TypeChecker *t, const NodeId node_in) {
  const NodeId node = peel_wrappers(t, node_in); // `unsafe p[0] = v` assigns through the wrapper
  const Node *const n = ast_at_const(t->ast, node);
  switch (n->kind) {
    case NODE_IDENTIFIER: {
      const DefId dd = ast_resolution_def(t->ast, node); // a `static mut` may live in another module
      if (dd.node != NODE_NONE && dd.module != t->ast->module) {
        const Node *const fdn = ast_at_const(mod_ast(t, dd.module), dd.node);
        return fdn->kind == NODE_CONST && fdn->as.const_def.is_static_mut;
      }
      const NodeId d = ast_resolution(t->ast, node);
      if (d == NODE_NONE)
        return false;
      const Node *const dn = ast_at_const(t->ast, d);
      if (dn->kind == NODE_CONST) // `static mut` is assignable; a plain const never is
        return dn->as.const_def.is_static_mut;
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
      if (n->kind == NODE_MEMBER && n->as.member.path)
        return tc_path_static_mut(t, node); // `mod::STATIC = v`
      const NodeId obj = n->kind == NODE_INDEX ? n->as.index.object : n->as.member.object;
      TypeId oty = ast_type(t->ast, obj);
      // Auto-deref (INDEX only, mirroring the read path): a store through a reference base is governed by
      // the innermost reference's qualifier -- `(&mut v)[i] = x` is fine, through a `&v` it is not.
      bool via_ref = false, ref_mut = false;
      if (n->kind == NODE_INDEX) {
        const Ty *y = ast_type_at(t->ast, oty);
        while (y->kind == TYPE_REFERENCE) {
          via_ref = true;
          ref_mut = y->qualifier == TYPE_QUAL_MUT;
          oty = y->as.elem;
          y = ast_type_at(t->ast, oty);
        }
      }
      // Indexing a writable slice (`[]mut T` -> SliceMut<T>) yields an assignable element, however the
      // slice was bound -- its mutability lives in the type, not the binding.
      const int sk = n->kind == NODE_INDEX ? slice_kind(t, oty, NULL) : 0;
      if (sk)
        return sk == 2; // a read-only `[]T` element is never assignable
      const Ty *const ot = ast_type_at(t->ast, oty);
      // Overloaded index-assignment (the IndexMut interface): `obj[i] = v` stores through the type's
      // `index_mut` method, so the type must provide one AND the receiver must be mutable.
      if (n->kind == NODE_INDEX && (ot->kind == TYPE_STRUCT || ot->kind == TYPE_INSTANCE)) {
        ModuleId om;
        NodeId od;
        DefId gp[4];
        TypeId ga[4];
        int gn;
        if (!aggregate_of(t, oty, &om, &od, gp, ga, &gn))
          return false;
        const DefId im = find_method_cstr(t, om, od, "index_mut");
        if (im.node == NODE_NONE)
          return false;
        // The store goes THROUGH index_mut's returned reference, so it must return exactly one `&mut T`.
        Ast *const ia = mod_ast(t, im.module);
        const NodeList irs = ast_at_const(ia, im.node)->as.function.returns;
        if (irs.len != 1)
          return false;
        const NodeId ir0 = ast_list(ia, irs)[0];
        const Node *const irn = ast_at_const(ia, ir0);
        const NodeId itn = irn->kind == NODE_PARAMETER ? irn->as.parameter.type : ir0;
        if (itn == NODE_NONE || ast_at_const(ia, itn)->kind != NODE_REFERENCE_TYPE)
          return false;
        // index_mut takes `&mut self`: through a reference base the reference's own qualifier is the
        // receiver mutability; a value base needs a mutable place.
        return via_ref ? ref_mut : is_assignable(t, obj);
      }
      // Auto-deref: when the base is a reference/pointer, write-through is governed by the POINTEE
      // qualifier, not the binding -- a `let mut r: &T` may be rebound but `*r` / `r.f` stays read-only.
      if (ot->kind == TYPE_POINTER || ot->kind == TYPE_REFERENCE)
        return ot->qualifier == TYPE_QUAL_MUT;
      return is_assignable(t, obj); // a value-typed place: writability flows from the base place
    }
    default:
      return false;
  }
}

// A "place" (lvalue): an expression denoting a storage location, not a fresh value. Mirrors codegen's
// is_lvalue so the mutability check and the temp-materialization agree on what is a place vs an rvalue.
static bool is_place(TypeChecker *t, const NodeId id) {
  const Node *const n = ast_at_const(t->ast, peel_wrappers(t, id));
  switch (n->kind) {
    case NODE_IDENTIFIER:
    case NODE_INDEX:
      return true;
    case NODE_MEMBER: // a field/element access is a place; of `::` paths only `mod::STATIC` is
      return !n->as.member.path || tc_path_static_mut(t, peel_wrappers(t, id));
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
    // (`String<Global>`): record that instance as the base's type so the assoc call substitutes the extend's
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
  // check_call; codegen redirects to the concrete extend once the param is monomorphized.
  if (bd && bd->kind == NODE_GENERIC_PARAM) {
    DefId iface;
    const DefId m = find_bound_method(t, bmod, bdecl, mname, &iface);
    if (m.node != NODE_NONE) {
      ast_set_resolution_def(t->ast, n->as.member.member, m);
      return decl_type_in(t, m.module, m.node);
    }
  }
  // `Interface::assoc()` resolved by the expected type: `let p: Point = Default::default();` picks the method
  // from the expected type's `extend ExpectedType as Interface` extend. Codegen uses the call's result type to
  // emit the concrete `ExpectedType__assoc`. (Generic targets via the interface name are deferred; use the
  // explicit `Type::<Args>::assoc()` form for those.)
  if (bd && bd->kind == NODE_INTERFACE && expected != TYPE_NONE) {
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
  // An OWNING closure (a Free value moved into its env) requires a `fn move(..) ..` bound: only under
  // that marker does the generic body move-track the param (and free it), so a plain bound taking one
  // would double-free the env's captures on the second use.
  if (exid != acid && fn_owns(t, acid)) {
    const Ty *const exy = ast_type_at(t->ast, exid);
    const Node *const exn = ast_at_const(mod_ast(t, exy->module), exy->as.decl);
    if (exn->kind != NODE_FUNCTION_TYPE || !exn->as.function_type.is_move)
      return false;
  }
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
  // Substitute the iterator extend's own generics by the receiver instance's type args (Option<T> -> Option<i32>).
  const NodeId extend = enclosing_extend(t, nx.module, nx.node);
  if (extend != NODE_NONE && gn > 0) {
    const NodeList ig = ast_at_const(na, extend)->as.extend_def.generics;
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

// `assert` / `assert_eq` / `assert_ne` (prelude builtins, desugared in codegen): arguments are checked
// with BORROW semantics -- the desugar only reads them, so no moves are marked and an owned value stays
// usable after the assertion. kind: 1 = assert, 2 = assert_eq, 3 = assert_ne.
static TypeId tc_check_assert(TypeChecker *t, const Node *const n, const int kind) {
  const NodeList args = n->as.call.args;
  const NodeId *const aids = ast_list(t->ast, args);
  const Span sp = n->span;
  if (kind == 1) { // assert(cond [, msg: str])
    if (args.len < 1 || args.len > 2) {
      typechecker_errorf(t, sp.start, sp.end - sp.start, "'assert' takes a condition and an optional str message");
      for (uint32_t i = 0; i < args.len; i++)
        check_expr(t, aids[i]);
      return ast_builtin(BT_VOID);
    }
    const TypeId ct = check_expr(t, aids[0]);
    if (ct != TYPE_NONE && !is_bool(t, ct))
      typechecker_errorf(t, sp.start, sp.end - sp.start, "'assert' condition must be 'bool'");
    if (args.len == 2) {
      const TypeId mt = check_expr(t, aids[1]);
      if (mt != TYPE_NONE && strip(t, mt) != prelude_str_type(t))
        typechecker_errorf(t, sp.start, sp.end - sp.start, "'assert' message must be a 'str'");
    }
    return ast_builtin(BT_VOID);
  }
  const char *const nm = kind == 2 ? "assert_eq" : "assert_ne";
  if (args.len != 2) {
    typechecker_errorf(t, sp.start, sp.end - sp.start, "'%s' takes exactly two arguments", nm);
    for (uint32_t i = 0; i < args.len; i++)
      check_expr(t, aids[i]);
    return ast_builtin(BT_VOID);
  }
  const TypeId lt = check_expr(t, aids[0]);
  t->expected = lt; // the right side adapts to the left (`assert_eq(x_u8, 3)`)
  const TypeId rt = check_expr(t, aids[1]);
  if (lt == TYPE_NONE || rt == TYPE_NONE)
    return ast_builtin(BT_VOID);
  if (lt != rt && !compatible(t, lt, aids[1]) && !compatible(t, rt, aids[0]))
    err_mismatch(t, aids[1], lt);
  // Comparability of the (ref-stripped) operand type: builtins, `str`, payload-less enums, and any
  // aggregate with an `eq` method (its lookup here also marks it used for demand-driven emission).
  const TypeId base = strip(t, lt);
  const Ty *const y = ast_type_at(t->ast, base);
  bool comparable = y->kind == TYPE_BUILTIN && y->as.builtin != BT_VOID && y->as.builtin != BT_VALIST;
  comparable |= base == prelude_str_type(t);
  if (!comparable && (y->kind == TYPE_STRUCT || y->kind == TYPE_INSTANCE || y->kind == TYPE_ENUM)) {
    ModuleId om;
    NodeId od;
    DefId gp[4];
    TypeId ga[4];
    int gn;
    if (aggregate_of(t, base, &om, &od, gp, ga, &gn)) {
      comparable = find_method_cstr(t, om, od, "eq").node != NODE_NONE;
      if (!comparable && is_plain_enum(t, base))
        comparable = true; // a payload-less enum compares by tag (a plain C enum)
      // a String argument's failure message prints through as_str -- keep it emitted
      if (comparable)
        find_method_cstr(t, om, od, "as_str");
    }
  }
  if (!comparable) {
    char ty[96];
    render_type(t, lt, ty, sizeof ty);
    typechecker_errorf(t, sp.start, sp.end - sp.start, "'%s' cannot compare values of type '%s'", nm, ty);
    typechecker_notef(t, "implement 'Eq' (an 'eq' method) for the type, or compare a field/element instead");
  }
  return ast_builtin(BT_VOID);
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
      } else if (rty->kind == TYPE_DYN && rty->qualifier == TYPE_QUAL_NONE) {
        // An OWNED trait object: `.free()` runs the vtable's drop glue and consumes the binding
        // (codegen emits the `<Iface>__dyn_free` helper; a borrowed dyn stays the no-op below).
        tc_mark_move(t, path_callee->as.member.object);
        return ast_builtin(BT_VOID);
      }
    }
    if (!resolvable)
      return ast_builtin(BT_VOID); // no real `free` -> destructor no-op
    // else fall through: a real `free` method governs (return type, receiver auto-ref, the consume below)
  }
  if (path_callee->kind == NODE_MEMBER && path_callee->as.member.path) {
    t->expected = want; // a `Interface::assoc()` callee resolves through the call's target type
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
  // The assert builtins divert BEFORE the argument loop: their args are read, never moved.
  if (path_callee->kind == NODE_IDENTIFIER && t->package) {
    const DefId ad = ast_resolution_def(t->ast, n->as.call.callee);
    if (ad.node != NODE_NONE && ad.module < t->package->count && t->package->modules[ad.module].prelude &&
        ast_at_const(mod_ast(t, ad.module), ad.node)->kind == NODE_FUNCTION) {
      const Span anm =
          ast_at_const(mod_ast(t, ad.module), ast_at_const(mod_ast(t, ad.module), ad.node)->as.function.name)->as.name.text;
      const int akind = span_is(mod_src(t, ad.module), anm, "assert")      ? 1
                        : span_is(mod_src(t, ad.module), anm, "assert_eq") ? 2
                        : span_is(mod_src(t, ad.module), anm, "assert_ne") ? 3
                                                                           : 0;
      if (akind)
        return tc_check_assert(t, n, akind);
    }
  }
  const NodeList args = n->as.call.args;
  const NodeId *const aids = ast_list(t->ast, args);
  for (uint32_t i = 0; i < args.len; i++) {
    check_expr(t, aids[i]);
    // A by-value Free argument is moved to the callee (which owns/frees it) -- marked IMMEDIATELY so a
    // later argument reusing the same value (`f(s, s)`, `f(s, &mut s)`) is flagged by its own check.
    tc_mark_move(t, aids[i]);
  }

  if (callee == TYPE_NONE)
    return TYPE_NONE;
  const Ty *ct = ast_type_at(t->ast, callee);
  const Span sp = ast_at_const(t->ast, id)->span;
  if (ct->kind == TYPE_GENERIC) {
    // An `F: fn(..) ..`-bounded param is callable: read the signature from the bound (its only power),
    // so `f(x)` type-checks inside the generic body and yields the bound's return type.
    const NodeId fb = generic_fn_bound(t, ct->module, ct->as.decl);
    if (fb != NODE_NONE) {
      callee = lower_type_in(t, ct->module, fb);
      ct = ast_type_at(t->ast, callee);
    }
  }
  if (ct->kind == TYPE_DYN) {
    // A `dyn fn(..) ..` value is callable with its signature (codegen dispatches through the vtable).
    const TypeId ds = tc_dyn_fn_sig(t, ct);
    if (ds != TYPE_NONE) {
      callee = ds;
      ct = ast_type_at(t->ast, callee);
    }
  }
  if (ct->kind != TYPE_FUNCTION) {
    typechecker_errorf(t, sp.start, sp.end - sp.start, "called value is not a function");
    return TYPE_NONE;
  }

  const ModuleId fmod = ct->module;        // the called function lives in this module
  const NodeId fdecl = ct->as.decl;        // copied out: `ct` dangles once interning grows the type pool
  Ast *const fa = mod_ast(t, fmod);
  const Node *const fn = ast_at_const(fa, fdecl);
  const bool named = fn->kind == NODE_FUNCTION;
  // An extern "C" function body is invisible to the compiler: no borrow/move/bounds guarantees
  // survive the call, so the call site must carry the `unsafe` audit marker.
  if (named && fn->as.function.is_extern && !t->unsafe_depth)
    err_unsafe(t, sp, "calling an extern \"C\" function");
  const bool clos = fn->kind == NODE_CLOSURE;
  const NodeList params = named ? fn->as.function.params : clos ? fn->as.closure.params : fn->as.function_type.params;
  const NodeList returns = named ? fn->as.function.returns : clos ? fn->as.closure.returns : fn->as.function_type.returns;

  // A format builtin call (`format`/`print`/`println`/`eprint`/`eprintln`): its codegen-synthesized
  // String<Global> helpers must survive demand-driven pruning, so mark them used now (harmless if it is
  // the String `.print()`/`.println()` method).
  bool fmt_builtin = false;
  if (named && t->package && fmod < t->package->count && t->package->modules[fmod].prelude) {
    const Span fnm = ast_at_const(fa, fn->as.function.name)->as.name.text;
    fmt_builtin = span_is(mod_src(t, fmod), fnm, "format") || span_is(mod_src(t, fmod), fnm, "print") ||
                  span_is(mod_src(t, fmod), fnm, "println") || span_is(mod_src(t, fmod), fnm, "eprint") ||
                  span_is(mod_src(t, fmod), fnm, "eprintln");
    if (fmt_builtin)
      mark_format_helpers(t);
  }

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
  // borrows a value owned elsewhere -- but if that ELSEWHERE is a live borrow rooted at a binding of THIS
  // function (`let r = &mut s; r.free();`), the owner's scope-exit free still runs: a double free, rejected.
  // Through a parameter the referent is caller-owned (the normal destructor pattern) and stays allowed.
  if (skip && callee_node->as.member.object != NODE_NONE &&
      span_is(mod_src(t, t->ast->module), ast_at_const(t->ast, callee_node->as.member.member)->as.name.text, "free")) {
    const NodeId recv = callee_node->as.member.object;
    const Ty *const rty = ast_type_at(t->ast, ast_type(t->ast, recv));
    NodeId thru = NODE_NONE; // the local reference binding the free reaches through, if any
    if (rty->kind == TYPE_REFERENCE && ast_at_const(t->ast, recv)->kind == NODE_IDENTIFIER) {
      const DefId rd = ast_resolution_def(t->ast, recv);
      if (rd.module == t->ast->module)
        thru = rd.node; // `r.free()`
    } else if (rty->kind != TYPE_POINTER) {
      thru = place_through_binding(t, recv); // `(*r).free()` / `r.field.free()`
    }
    bool through_owner = false;
    for (uint32_t i = 0; thru != NODE_NONE && i < t->nborrows && !through_owner; i++) {
      const Borrow *const b = &t->borrows[i];
      if (b->binding != thru || b->root == NODE_NONE)
        continue;
      const NodeKind rk = ast_at_const(t->ast, b->root)->kind;
      if (rk == NODE_LET || rk == NODE_PATTERN_NAME || rk == NODE_IDENTIFIER || rk == NODE_FOR) {
        const Span rsp = ast_at_const(t->ast, recv)->span;
        typechecker_errorf(t, rsp.start, rsp.end - rsp.start,
                           "cannot free a borrowed value: its owning binding frees it again at scope exit");
        typechecker_notef(t, "call 'free' on the owning binding itself, or let it be freed automatically");
        through_owner = true;
      }
    }
    if (!through_owner && rty->kind != TYPE_POINTER && rty->kind != TYPE_REFERENCE &&
        tc_type_is_free(t, ast_type(t->ast, recv))) {
      tc_mark_move(t, recv);
      if (ast_at_const(t->ast, recv)->kind == NODE_IDENTIFIER) { // record it as freed, for the use-after-free diagnostic
        const DefId rd = ast_resolution_def(t->ast, recv);
        if (rd.module == t->ast->module && rd.node != NODE_NONE) {
          if (t->nfreed < (uint32_t)(sizeof t->freed / sizeof t->freed[0])) {
            t->freed[t->nfreed++] = rd.node;
          } else { // never drop a fact silently: an untracked free would hide a use-after-free
            const Span rsp = ast_at_const(t->ast, recv)->span;
            typechecker_errorf(t, rsp.start, rsp.end - rsp.start,
                               "too many freed values in one function (free-analysis limit)");
          }
        }
      }
    }
  } else if (skip && callee_node->as.member.object != NODE_NONE) {
    const NodeId p0 = ast_list(fa, params)[0];
    const NodeId pt = ast_at_const(fa, p0)->as.parameter.type;
    const NodeKind ptk = pt != NODE_NONE ? ast_at_const(fa, pt)->kind : NODE_NONE_KIND;
    if (ptk != NODE_POINTER_TYPE && ptk != NODE_REFERENCE_TYPE) {
      // `self` taken BY VALUE (`fn unwrap_or(self: Option<T>, ..)`) consumes its receiver: the receiver moves
      // into the call, so a later use is a use-after-move (and it is not double-freed).
      tc_mark_move(t, callee_node->as.member.object);
    } else {
      // A `&self` / `&mut self` (or `*const`/`*mut self`) method implicitly borrows its receiver for the
      // call's duration. This is a two-phase borrow: the args (evaluated above, so `v.len()` inside
      // `v.push(v.len())` already ran) precede the receiver borrow, so it only conflicts with borrows that
      // OUTLIVE those reads. When the method RETURNS a reference, the result conservatively borrows the
      // receiver for as long as it is held, so the borrow is REGISTERED (`let r = h.get(); h.set(..);`
      // conflicts); otherwise it is transient (the method returned) -- checked, never registered.
      const uint8_t bk =
          ast_at_const(fa, pt)->as.indirect_type.qualifier == TYPE_QUAL_MUT ? BORROW_MUT : BORROW_SHARED;
      bool ret_ref = false;
      if (returns.len == 1) {
        const NodeId rr0 = ast_list(fa, returns)[0];
        const Node *const rrn = ast_at_const(fa, rr0);
        const NodeId rtn = rrn->kind == NODE_PARAMETER ? rrn->as.parameter.type : rr0;
        ret_ref = rtn != NODE_NONE && ast_at_const(fa, rtn)->kind == NODE_REFERENCE_TYPE;
      }
      if (ret_ref)
        borrow_create(t, callee_node->as.member.object, bk, callee_node->as.member.object);
      else
        borrow_report_conflict(t, callee_node->as.member.object, bk, callee_node->as.member.object);
    }
  }

  // A method or associated fn reached through a generic instance (`b.get()`, `Box::<i32>::make()`)
  // substitutes the instance's type args into the signature via the extend's own generics. The instance is
  // the member's object type (the receiver, or the `Type::<Args>` base); the extend declares its generics
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
      const NodeId extend = enclosing_extend(t, md.module, md.node);
      if (extend != NODE_NONE) {
        const NodeList ig = ast_at_const(mod_ast(t, md.module), extend)->as.extend_def.generics;
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
  // substitute its `Self` (a TYPE_GENERIC of the interface) by the receiver type so the signature resolves.
  if (callee_node->kind == NODE_MEMBER && !callee_node->as.member.path && nrsub < 4) {
    const DefId md = ast_resolution_def(t->ast, callee_node->as.member.member);
    const NodeId tr = md.node != NODE_NONE ? enclosing_trait(t, md.module, md.node) : NODE_NONE;
    if (tr != NODE_NONE) {
      rsubp[nrsub] = (DefId){md.module, tr};
      rsuba[nrsub] = strip(t, ast_type(t->ast, callee_node->as.member.object));
      nrsub++;
      const Ty *const ro = ast_type_at(t->ast, strip(t, ast_type(t->ast, callee_node->as.member.object)));
      if (ro->kind == TYPE_GENERIC && nrsub < 4)
        nrsub += bound_method_subst(t, ro->module, ro->as.decl, md, rsubp + nrsub, rsuba + nrsub, 4 - nrsub);
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
      if (nrsub < 4)
        nrsub += bound_method_subst(t, ob.module, ob.node, md, rsubp + nrsub, rsuba + nrsub, 4 - nrsub);
    }
    // `Interface::assoc()` on a generic instance target (`let v: Vector<String> = Default::default();`): the
    // resolved method's signature uses the EXTEND's type params -- bind them to the target instance's args.
    if (ob.node != NODE_NONE && md.node != NODE_NONE &&
        ast_at_const(mod_ast(t, ob.module), ob.node)->kind == NODE_INTERFACE) {
      ModuleId em;
      NodeId ed;
      DefId egp[4];
      TypeId ega[4];
      int egn;
      if (want != TYPE_NONE && aggregate_of(t, strip(t, want), &em, &ed, egp, ega, &egn) && egn > 0) {
        const NodeId extend = enclosing_extend(t, md.module, md.node);
        if (extend != NODE_NONE) {
          Ast *const ma = mod_ast(t, md.module);
          const NodeList ig = ast_at_const(ma, extend)->as.extend_def.generics;
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

  if (callee_node->kind == NODE_MEMBER) {
    const DefId md = ast_resolution_def(t->ast, callee_node->as.member.member);
    TypeId mt = TYPE_NONE;
    if (md.node != NODE_NONE && ast_at_const(mod_ast(t, md.module), md.node)->kind == NODE_FUNCTION) {
      if (!callee_node->as.member.path) {
        mt = strip(t, ast_type(t->ast, callee_node->as.member.object));
      } else {
        const DefId ob = ast_resolution_def(t->ast, callee_node->as.member.object);
        if (ob.node != NODE_NONE && ast_at_const(mod_ast(t, ob.module), ob.node)->kind == NODE_INTERFACE && want != TYPE_NONE)
          mt = strip(t, want);
        else
          mt = strip(t, ast_type(t->ast, callee_node->as.member.object));
      }
      if (mt != TYPE_NONE && !method_extend_bounds_hold(t, mt, md)) {
        err_method_extend_bounds(t, sp, mt, md);
        return TYPE_NONE;
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
    TypeId bound[8];
    int nexplicit = 0;
    for (int i = 0; i < g; i++)
      bound[i] = TYPE_NONE;
    if (callee_n->kind == NODE_GENERIC_SPECIALIZATION) { // explicit turbofish (possibly partial)
      const NodeList tas = callee_n->as.specialization.types;
      const NodeId *const taids = ast_list(t->ast, tas);
      for (uint32_t i = 0; i < tas.len && nexplicit < g; i++)
        bound[nexplicit++] = ast_type(t->ast, taids[i]);
    }
    if (nexplicit < g && args.len == params.len - skip) { // infer the remaining params from the args
      const NodeId *const pids = ast_list(fa, params);
      for (uint32_t i = 0; i < args.len; i++)
        unify_infer(t, decl_type_in(t, fmod, pids[i + skip]), ast_type(t->ast, aids[i]), gparams, bound, g);
      // A param bound to F (`fn(..) ..`-bounded generic) fixes F but not the generics inside the bound's
      // signature (`map<U, F: fn(T) U>` gets U only from F): unify the bound against the inferred F.
      for (int i = 0; i < g; i++) {
        if (bound[i] == TYPE_NONE || ast_type_at(t->ast, bound[i])->kind != TYPE_FUNCTION)
          continue;
        const NodeId fb = generic_fn_bound(t, fmod, gids[i]);
        if (fb != NODE_NONE)
          unify_infer(t, lower_type_in(t, fmod, fb), bound[i], gparams, bound, g);
      }
      nexplicit = g;
    }
    for (int i = 0; i < nexplicit; i++)
      gargs[i] = bound[i]; // may stay TYPE_NONE if a param couldn't be inferred
    gn = nexplicit;
    if (gn == g) { // fully determined: record for codegen's specialization, then enforce interface bounds
      ast_set_type_args(t->ast, id, gargs, (uint8_t)gn);
      for (int i = 0; i < g; i++) {
        const NodeList pb = ast_at_const(fa, gids[i])->as.generic_param.bounds;
        const NodeId *const pbids = ast_list(fa, pb);
        for (uint32_t b = 0; b < pb.len; b++) {
          // An `fn(..) ..` bound: the arg must be a function value whose signature matches the bound
          // with the call's generic + receiver substitutions applied. A still-abstract param passes
          // (re-checked at its own instantiation), like interface bounds below.
          if (ast_at_const(fa, pbids[b])->kind == NODE_FUNCTION_TYPE) {
            const TypeId bt = lower_type_in(t, fmod, pbids[b]);
            const Ty *const gy = gargs[i] == TYPE_NONE ? NULL : ast_type_at(t->ast, gargs[i]);
            if (gy && gy->kind != TYPE_GENERIC &&
                (gy->kind != TYPE_FUNCTION ||
                 !fn_compatible_subst(t, bt, gargs[i], gparams, gargs, gn, rsubp, rsuba, nrsub))) {
              char tn[96];
              render_type(t, gargs[i], tn, sizeof tn);
              const Span bsp = ast_at_const(fa, pbids[b])->span;
              typechecker_errorf(
                  t, sp.start, sp.end - sp.start, "type '%s' does not satisfy bound '%.*s'", tn,
                  (int)(bsp.end - bsp.start), (const char *)mod_src(t, fmod) + bsp.start);
              if (gy->kind == TYPE_FUNCTION && fn_owns(t, gargs[i]) &&
                  !ast_at_const(fa, pbids[b])->as.function_type.is_move)
                typechecker_notef(t, "this closure owns a captured value; the bound must be 'fn move(..) ..'");
              else
                typechecker_notef(t, "the argument must be a function or closure with this exact signature");
            }
            continue;
          }
          const DefId bi = ast_resolution_def(fa, pbids[b]);
          if (bi.node != NODE_NONE && !type_satisfies(t, gargs[i], bi, 0)) {
            char tn[96];
            render_type(t, gargs[i], tn, sizeof tn);
            const Span bsp = ast_at_const(fa, pbids[b])->span;
            typechecker_errorf(
                t, sp.start, sp.end - sp.start, "type '%s' does not satisfy bound '%.*s'", tn,
                (int)(bsp.end - bsp.start), (const char *)mod_src(t, fmod) + bsp.start);
            const Span gpname = ast_at_const(fa, ast_at_const(fa, gids[i])->as.generic_param.name)->as.name.text;
            typechecker_notef(t, "required by generic parameter '%.*s' on this function",
                              (int)(gpname.end - gpname.start), (const char *)mod_src(t, fmod) + gpname.start);
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
          if (ast_at_const(fa, wbids[b])->kind == NODE_FUNCTION_TYPE) { // `where F: fn(..) ..`
            const TypeId bt = lower_type_in(t, fmod, wbids[b]);
            const Ty *const wy = wt == TYPE_NONE ? NULL : ast_type_at(t->ast, wt);
            if (wy && wy->kind != TYPE_GENERIC &&
                (wy->kind != TYPE_FUNCTION ||
                 !fn_compatible_subst(t, bt, wt, gparams, gargs, gn, rsubp, rsuba, nrsub))) {
              char tn[96];
              render_type(t, wt, tn, sizeof tn);
              const Span bsp = ast_at_const(fa, wbids[b])->span;
              typechecker_errorf(
                  t, sp.start, sp.end - sp.start, "type '%s' does not satisfy bound '%.*s'", tn,
                  (int)(bsp.end - bsp.start), (const char *)mod_src(t, fmod) + bsp.start);
              typechecker_notef(t, "required by this function's where-clause");
            }
            continue;
          }
          const DefId bi = ast_resolution_def(fa, wbids[b]);
          if (bi.node != NODE_NONE && !type_satisfies(t, wt, bi, 0)) {
            char tn[96];
            render_type(t, wt, tn, sizeof tn);
            const Span bsp = ast_at_const(fa, wbids[b])->span;
            typechecker_errorf(
                t, sp.start, sp.end - sp.start, "type '%s' does not satisfy bound '%.*s'", tn,
                (int)(bsp.end - bsp.start), (const char *)mod_src(t, fmod) + bsp.start);
            typechecker_notef(t, "required by this function's where-clause");
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
    if (named) {
      const Span fnn = ast_at_const(fa, fn->as.function.name)->as.name.text;
      typechecker_notef(t, "while calling '%.*s'", (int)(fnn.end - fnn.start), (const char *)mod_src(t, fmod) + fnn.start);
    }
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
        if (pt != at && att && fn_is_capturing(t, at)) {
          // Its value is an env struct, not a pointer -- only an `F: fn(..) ..` generic can take it.
          const Span asp = ast_at_const(t->ast, aids[i])->span;
          typechecker_errorf(t, asp.start, asp.end - asp.start,
                             "a capturing closure cannot be passed as a bare 'fn' pointer");
          typechecker_notef(t, "make the parameter generic instead: fn f<F: fn(..) ..>(callback: F)");
        } else if (!att || att->kind != TYPE_FUNCTION ||
                   !fn_compatible_subst(t, pt, at, gparams, gargs, gn, rsubp, rsuba, nrsub)) {
          err_mismatch(t, aids[i], pt);
        }
        continue;
      }
      if (!compatible(t, pt, aids[i]))
        err_mismatch(t, aids[i], pt);
    }
  }
  // A string literal in a C-vararg slot has no `str` meaning to C: default it to `*const char` so codegen
  // emits the bare NUL-terminated literal (what `%s` expects), mirroring the fixed-param coercion.
  // NOT for the format builtins: their args are Super-C values (a literal formats as a `str` view).
  if (variadic && !fmt_builtin && args.len >= expected) {
    const TypeId cstr =
        ast_intern_type(t->ast, (Ty){.kind = TYPE_POINTER, .qualifier = TYPE_QUAL_CONST, .as.elem = ast_builtin(BT_CHAR)});
    for (uint32_t i = expected; i < args.len; i++) {
      const Node *const a = ast_at_const(t->ast, aids[i]);
      if (a->kind == NODE_LITERAL &&
          (a->as.literal.token_type == StringLiteral || a->as.literal.token_type == RawStringLiteral))
        ast_set_type(t->ast, aids[i], cstr);
    }
  }
  // A `&mut self` / `*mut self` method needs a mutable receiver: an immutable binding/place cannot be
  // mutated through it (binding mutability is `let mut` / `mut`, NOT a property of the type's internals).
  if (skip == 1 && callee_node->kind == NODE_MEMBER && params.len > 0) {
    const Ty *const selfp = ast_type_at(t->ast, decl_type_in(t, fmod, ast_list(fa, params)[0]));
    if ((selfp->kind == TYPE_REFERENCE || selfp->kind == TYPE_POINTER) && selfp->qualifier == TYPE_QUAL_MUT) {
      const NodeId recv = callee_node->as.member.object;
      // An explicit `.free()` on an OWNED value is a consuming destructor call -- the same call the
      // compiler emits at scope exit, which never needed `mut`. The binding's life ends here (freed /
      // moved above), so its mutability is irrelevant; `free` through a `&`/`*const` receiver still
      // requires the mutable receiver its signature demands.
      const Ty *const rvt = ast_type_at(t->ast, ast_type(t->ast, recv));
      const TypeKind rvk = rvt->kind;
      if (rvk == TYPE_DYN) {
        // Borrowed: the data pointer's mutability is the TYPE's (`&dyn` vs `&mut dyn`), not the
        // binding's. Owned (`Box<dyn I>`): the binding's, like any owned value.
        if (rvt->qualifier == TYPE_QUAL_CONST) {
          const Span rsp = ast_at_const(t->ast, recv)->span;
          typechecker_errorf(t, rsp.start, rsp.end - rsp.start,
                             "cannot call a '&mut self' method through '&dyn' (use '&mut dyn')");
        } else if (rvt->qualifier == TYPE_QUAL_NONE && !receiver_mutable(t, recv)) {
          const Span rsp = ast_at_const(t->ast, recv)->span;
          typechecker_errorf(t, rsp.start, rsp.end - rsp.start,
                             "cannot call a '&mut self' method on an immutable binding (bind it with 'mut')");
        }
      } else {
        const bool consuming_free =
            rvk != TYPE_REFERENCE && rvk != TYPE_POINTER &&
            span_is(mod_src(t, t->ast->module), ast_at_const(t->ast, callee_node->as.member.member)->as.name.text,
                    "free");
        if (!consuming_free) {
          tc_mark_capture_mut(t, recv); // a `&mut self` method mutates through the capture
          if (!receiver_mutable(t, recv)) {
            const Span rsp = ast_at_const(t->ast, recv)->span;
            typechecker_errorf(
                t, rsp.start, rsp.end - rsp.start,
                "cannot call a '&mut self' method on an immutable binding (bind it with 'mut')");
          }
        }
      }
    }
  }
  if (clos && fn->as.closure.expr_body)
    return ast_type(fa, fn->as.closure.body); // compact closure callee: return type inferred from its body
  // A `@c.noreturn` function never returns: the call's type is `never`, which unifies with any
  // expected type (so a panicking switch/if arm coexists with value-producing siblings).
  if (named && tc_attr(t, fmod, fdecl, ATTR_NORETURN))
    return ast_intern_type(t->ast, (Ty){.kind = TYPE_NEVER});
  if (returns.len != 1) {
    if (returns.len > 1) { // multi-return: stash the SUBSTITUTED element types for check_tuple_let
      const NodeId *const mrids = ast_list(fa, returns);
      t->mret_n = returns.len < 8 ? (uint8_t)returns.len : 8;
      t->mret_total = returns.len;
      for (uint8_t i = 0; i < t->mret_n; i++) {
        const Node *const mrn = ast_at_const(fa, mrids[i]);
        const TypeId mrt = lower_type_in(t, fmod, mrn->kind == NODE_PARAMETER ? mrn->as.parameter.type : mrids[i]);
        t->mret_types[i] = subst_type(t, subst_type(t, mrt, gparams, gargs, gn), rsubp, rsuba, nrsub);
      }
      t->mret_call = id;
    }
    return TYPE_NONE; // 0 or multiple returns: no single value type yet
  }
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
    // Tuple element access `t.0`: an all-digit member maps to the prelude Tuple<n> field `_0`/`_1`/..
    bool digits = name.end > name.start && name.end - name.start <= 2;
    for (uint32_t i = name.start; i < name.end && digits; i++)
      digits = t->source[i] >= '0' && t->source[i] <= '9';
    if (digits) {
      char fld[8];
      snprintf(fld, sizeof fld, "_%.*s", (int)(name.end - name.start), (const char *)t->source + name.start);
      fhit = find_member_cstr(t, bmod, bdecl, fld);
    }
    if (fhit == NODE_NONE && prefer_method) {
      mhit = find_method(t, bmod, bdecl, name);
      if (mhit.node == NODE_NONE)
        fhit = find_member(t, bmod, bdecl, name);
    } else if (fhit == NODE_NONE) {
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
      if (ast_at_const(mod_ast(t, bmod), fhit)->kind == NODE_FIELD) {
        check_field_visibility(t, bmod, fhit, bdecl, name);
        // A field READ/WRITE through a raw pointer (`p.f` / `p->f`) dereferences it; a method call
        // through one stays safe here -- the method body's own raw accesses are checked in its scope.
        if (!t->unsafe_depth && through_raw_pointer(t, obj))
          err_unsafe(t, n->span, "accessing a field through a raw pointer"); // whole `p.f`, not just `.f`
      }
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
  // A method on a builtin value (`x.abs()`, `key.hash()`): builtins are nominal types anchored in core, so
  // look the method up on the builtin's synthetic decl (including inherited interface default bodies).
  {
    const Ty *const bty = ast_type_at(t->ast, base);
    if (bty->kind == TYPE_BUILTIN && t->package) {
      const NodeId bd = package_builtin_decl(t->package, bty->as.builtin);
      if (bd != NODE_NONE) {
        DefId mhit = find_method(t, t->package->core_module, bd, name);
        if (mhit.node == NODE_NONE)
          mhit = find_default_method(t, t->package->core_module, bd, name);
        if (mhit.node != NODE_NONE) {
          ast_set_resolution_def(t->ast, mname, mhit);
          return decl_type_in(t, mhit.module, mhit.node);
        }
      }
    }
  }
  // A method on a value of generic-parameter type (`w: T` with `T: Writer`): resolve it through the
  // param's interface bounds. `Self` stays abstract (TYPE_GENERIC of the interface); check_call substitutes
  // it by the receiver, and codegen dispatches to the concrete extend once the param is monomorphized.
  const Ty *const bt = ast_type_at(t->ast, base);
  if (bt->kind == TYPE_GENERIC || bt->kind == TYPE_DYN) {
    // `self` inside an interface default body has the abstract `Self` type (a TYPE_GENERIC keyed by the
    // interface): resolve `self.m()` against the interface's own methods + superinterfaces. A plain generic param
    // (`w: T`, `T: Writer`) instead resolves through its interface bounds. A `dyn I` receiver is the same
    // shape as the first: its decl IS the interface, and codegen dispatches through the vtable.
    const Node *const gd = ast_at_const(mod_ast(t, bt->module), bt->as.decl);
    if (gd->kind == NODE_INTERFACE) {
      const DefId m = find_interface_method(t, bt->module, bt->as.decl, name, 0);
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
  typechecker_notef(t, "fields are accessed as 'value.name'; methods must be declared in an 'extend' block or provided by a bound");
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
  const uint32_t bm = borrow_mark(t);
  const TypeId c = check_expr(t, n->as.if_stmt.condition);
  if (c != TYPE_NONE && !is_bool(t, c)) {
    const Span sp = ast_at_const(t->ast, n->as.if_stmt.condition)->span;
    char ty[96];
    render_type(t, c, ty, sizeof ty);
    typechecker_errorf(t, sp.start, sp.end - sp.start, "if condition must be 'bool', found '%s'", ty);
  }
  borrow_release_to(t, bm); // the condition's temporary borrows end before the branches run
  // The two branches are alternative paths: check each from the same pre-`if` state, then union their
  // effects -- so an else use of a value the then-branch moved (or vice versa) is not a false error, while
  // a value left moved/uninitialized on either path is so afterward. A branch that RETURNS on every path
  // through it contributes nothing to the join (control never flows from it to the code after the `if`),
  // so `if c { let f = |x| ..owns s..; return f(1); } return s.id;` is not a false use-after-move.
  const FlowState pre = tc_flow_save(t);
  check_stmt(t, n->as.if_stmt.then_branch);
  FlowState acc = {.nmoved = 0, .nuninit = 0};
  bool ovf = false;
  if (!tc_stmt_returns(t, n->as.if_stmt.then_branch))
    ovf |= tc_flow_collect(&acc, t); // then-branch effects
  tc_flow_set(t, &pre);              // else branch starts fresh from the pre-if state
  check_stmt(t, n->as.if_stmt.else_branch);
  if (!tc_stmt_returns(t, n->as.if_stmt.else_branch))
    ovf |= tc_flow_collect(&acc, t); // ∪ else-branch effects
  tc_flow_set(t, &acc);              // post-if = union of the fall-through paths
  if (ovf)
    tc_flow_overflow(t, n->as.if_stmt.condition);
}

// --- switch exhaustiveness ------------------------------------------------------------------
// Is this pattern irrefutable (matches every value of its type)? Wildcards and plain bindings are;
// a tuple/struct destructure is iff it tests no enum variant tag and every sub-pattern is. Runs
// AFTER check_pattern, which resolved each tag-testing pattern name to its NODE_VARIANT.
static bool pattern_irrefutable(TypeChecker *t, const NodeId id) {
  if (id == NODE_NONE)
    return true; // an absent sub-pattern constrains nothing
  const Node *const p = ast_at_const(t->ast, id);
  switch (p->kind) {
    case NODE_PATTERN_WILDCARD:
    case NODE_IDENTIFIER: // shorthand struct-field binding
      return true;
    case NODE_PATTERN_NAME:
    case NODE_PATTERN_TUPLE:
    case NODE_PATTERN_STRUCT: {
      const NodeId nameId = p->as.pattern.name;
      if (nameId != NODE_NONE) {
        const DefId d = ast_resolution_def(t->ast, nameId);
        if (d.node != NODE_NONE && ast_at_const(mod_ast(t, d.module), d.node)->kind == NODE_VARIANT)
          return false; // tests a tag
      }
      if (p->kind == NODE_PATTERN_NAME)
        return true; // a plain binding
      const NodeId *const ids = ast_list(t->ast, p->as.pattern.children);
      for (uint32_t i = 0; i < p->as.pattern.children.len; i++)
        if (!pattern_irrefutable(t, ids[i]))
          return false;
      return true;
    }
    case NODE_PATTERN_FIELD: {
      const NodeId *const ids = ast_list(t->ast, p->as.pattern.children);
      for (uint32_t i = 0; i < p->as.pattern.children.len; i++)
        if (!pattern_irrefutable(t, ids[i]))
          return false;
      return true;
    }
    case NODE_PATTERN_OR: {
      const NodeId *const ids = ast_list(t->ast, p->as.pattern.children);
      for (uint32_t i = 0; i < p->as.pattern.children.len; i++)
        if (pattern_irrefutable(t, ids[i]))
          return true; // one always-matching alternative makes the whole `|` irrefutable
      return false;
    }
    default:
      return false; // literal / range: matches specific values only
  }
}

// The enum variant this pattern FULLY covers (its tag with irrefutable payload sub-patterns), or
// NODE_NONE. `Some(x)` covers Some; `Some(5)` does not (5 can fail).
static NodeId pattern_covered_variant(TypeChecker *t, const Node *const p) {
  if (p->kind != NODE_PATTERN_NAME && p->kind != NODE_PATTERN_TUPLE && p->kind != NODE_PATTERN_STRUCT)
    return NODE_NONE;
  const NodeId nameId = p->as.pattern.name;
  if (nameId == NODE_NONE)
    return NODE_NONE;
  const DefId d = ast_resolution_def(t->ast, nameId);
  if (d.node == NODE_NONE || ast_at_const(mod_ast(t, d.module), d.node)->kind != NODE_VARIANT)
    return NODE_NONE;
  const NodeId *const ids = ast_list(t->ast, p->as.pattern.children);
  for (uint32_t i = 0; i < p->as.pattern.children.len; i++)
    if (!pattern_irrefutable(t, ids[i]))
      return NODE_NONE;
  return d.node;
}

#define MATCH_MAX_VARIANTS 256
// One no-guard arm pattern's contribution: a catch-all, a fully-covered enum variant bit, or a
// `true`/`false` literal. Or-pattern alternatives each contribute on their own.
static void match_arm_coverage(TypeChecker *t, const NodeId pid, const Ast *const ea, const NodeList variants,
                               uint64_t *const covered, bool *const catchall, bool *const tcov, bool *const fcov) {
  if (pid == NODE_NONE)
    return;
  const Node *const p = ast_at_const(t->ast, pid);
  if (p->kind == NODE_PATTERN_OR) {
    const NodeId *const ids = ast_list(t->ast, p->as.pattern.children);
    for (uint32_t i = 0; i < p->as.pattern.children.len; i++)
      match_arm_coverage(t, ids[i], ea, variants, covered, catchall, tcov, fcov);
    return;
  }
  if (pattern_irrefutable(t, pid)) {
    *catchall = true;
    return;
  }
  if (p->kind == NODE_PATTERN_LITERAL) { // `true` / `false` literals enumerate bool completely
    const Node *const v = ast_at_const(t->ast, p->as.single.value);
    if (v->kind == NODE_LITERAL && v->as.literal.token_type == True)
      *tcov = true;
    else if (v->kind == NODE_LITERAL && v->as.literal.token_type == False)
      *fcov = true;
    return;
  }
  const NodeId var = pattern_covered_variant(t, p);
  if (var == NODE_NONE || ea == NULL)
    return;
  const NodeId *const vids = ast_list(ea, variants);
  for (uint32_t i = 0; i < variants.len && i < MATCH_MAX_VARIANTS; i++)
    if (vids[i] == var) {
      covered[i >> 6] |= (uint64_t)1 << (i & 63);
      return;
    }
}

// The language rule README/codegen already rely on (`__builtin_unreachable` fall-through): every
// switch must cover its scrutinee. Enums must match every variant (or `_`); `true`+`false` cover
// bool; anything else needs an irrefutable arm. Guarded arms cover nothing (a guard can fail).
static void check_match_exhaustive(TypeChecker *t, const Node *const n, const TypeId scrut) {
  if (scrut == TYPE_NONE)
    return; // the scrutinee already failed to type; don't cascade
  Ast *const a = t->ast;
  const TypeId base = strip(t, scrut);
  ModuleId emod = 0;
  NodeId edecl = NODE_NONE;
  DefId gp[4];
  TypeId ga[4];
  int gn;
  const bool is_enum = aggregate_of(t, base, &emod, &edecl, gp, ga, &gn) &&
                       ast_at_const(mod_ast(t, emod), edecl)->kind == NODE_ENUM;
  const Ast *const ea = is_enum ? mod_ast(t, emod) : NULL;
  const NodeList variants = is_enum ? ast_at_const(ea, edecl)->as.aggregate.members : (NodeList){0, 0};
  uint64_t covered[MATCH_MAX_VARIANTS / 64] = {0};
  bool catchall = false, tcov = false, fcov = false;
  const NodeId *const ids = ast_list(a, n->as.match_expr.arms);
  for (uint32_t i = 0; i < n->as.match_expr.arms.len; i++) {
    const Node *const arm = ast_at_const(a, ids[i]);
    if (arm->as.match_arm.guard != NODE_NONE)
      continue;
    match_arm_coverage(t, arm->as.match_arm.pattern, ea, variants, covered, &catchall, &tcov, &fcov);
  }
  if (catchall)
    return;
  const Span sp = ast_at_const(a, n->as.match_expr.value)->span;
  if (is_enum && variants.len <= MATCH_MAX_VARIANTS) {
    char miss[128];
    size_t at = 0;
    uint32_t nmiss = 0;
    const NodeId *const vids = ast_list(ea, variants);
    for (uint32_t i = 0; i < variants.len; i++) {
      if (covered[i >> 6] & ((uint64_t)1 << (i & 63)))
        continue;
      nmiss++;
      if (nmiss <= 3 && at < sizeof miss) { // name the first few; count the rest
        const Span vn = ast_at_const(ea, ast_at_const(ea, vids[i])->as.variant.name)->as.name.text;
        const int w = snprintf(miss + at, sizeof miss - at, "%s'%.*s'", nmiss > 1 ? ", " : "",
                               (int)(vn.end - vn.start), (const char *)mod_src(t, emod) + vn.start);
        at = w > 0 && at + (size_t)w < sizeof miss ? at + (size_t)w : sizeof miss;
      }
    }
    if (!nmiss)
      return; // every variant matched
    if (nmiss > 3 && at < sizeof miss)
      snprintf(miss + at, sizeof miss - at, " and %u more", nmiss - 3);
    typechecker_errorf(
        t, sp.start, sp.end - sp.start, "switch is not exhaustive: missing variant%s %s", nmiss == 1 ? "" : "s", miss);
    typechecker_notef(t, "match every variant or add a '_' arm");
    return;
  }
  if (base == ast_builtin(BT_BOOL) && tcov && fcov)
    return;
  typechecker_errorf(t, sp.start, sp.end - sp.start, "switch is not exhaustive");
  typechecker_notef(t, "add a '_' arm to cover the remaining values");
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
  const bool place_use = t->place_use; // whether this expr is a place base whose read check already ran; one-shot
  t->place_use = false;
  TypeId result = TYPE_NONE;
  switch (n->kind) {
    case NODE_LITERAL:
      switch (n->as.literal.token_type) {
        case IntegerLiteral: {
          // A type suffix (`1u8`, `0xFFu64`) pins the literal's type; otherwise the i32 default adapts
          // through `compatible`. Digit parsing below excludes the suffix.
          const Span lr = n->as.literal.raw;
          uint32_t sfx = lr.end;
          const BuiltinType sb = ast_numeric_suffix(t->source, lr.start, lr.end, &sfx);
          result = ast_builtin(sb == BT_COUNT ? BT_I32 : sb);
          // Reject a literal that exceeds 64 bits: it has no representable type and would otherwise leak a
          // confusing C-level "integer literal too large" error with no Super-C diagnostic.
          const uint8_t *p = t->source + lr.start;
          size_t len = sfx - lr.start;
          unsigned base = 10;
          if (len >= 2 && p[0] == '0' && (p[1] | 0x20) == 'x') {
            base = 16, p += 2, len -= 2;
          } else if (len >= 2 && p[0] == '0' && (p[1] | 0x20) == 'b') {
            base = 2, p += 2, len -= 2;
          } else if (len >= 2 && p[0] == '0' && (p[1] | 0x20) == 'o') {
            base = 8, p += 2, len -= 2;
          }
          uint64_t acc = 0;
          bool overflow = false;
          for (size_t i = 0; i < len && !overflow; i++) {
            const uint8_t ch = p[i];
            if (ch == '_')
              continue;
            const unsigned d = ch <= '9' ? (unsigned)(ch - '0') : (unsigned)((ch | 0x20) - 'a' + 10);
            if (acc > (UINT64_MAX - d) / base)
              overflow = true;
            else
              acc = acc * base + d;
          }
          if (overflow) {
            typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                               "integer literal is too large to fit in a 64-bit integer");
          } else if (sb != BT_COUNT && bt_int_max(sb) && acc > bt_int_max(sb)) {
            typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                               "integer literal does not fit in its suffixed type");
          }
          break;
        }
        case FloatLiteral: { // default f32 (`compatible` still adapts an unsuffixed one to f64)
          const Span lr = n->as.literal.raw;
          const BuiltinType sb = ast_numeric_suffix(t->source, lr.start, lr.end, NULL);
          result = ast_builtin(sb == BT_F64 ? BT_F64 : BT_F32);
          break;
        }
        case CharacterLiteral:
          result = ast_builtin(BT_CHAR);
          if (char_literal_cp(t->source, n->as.literal.raw) > 0xFF) // `char` is one byte
            typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                               "character literal does not fit in 'char' (one byte); use a string or an integer");
          break;
        case ByteCharacterLiteral: result = ast_builtin(BT_U8); break;
        case True:
        case False: result = ast_builtin(BT_BOOL); break;
        case StringLiteral:
        case RawStringLiteral: result = prelude_str_type(t); break; // a `str` view over the literal bytes
        default: result = TYPE_NONE; break; // Null
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
        // Borrow checker: reading a value while it is mutably borrowed is illegal (the `&mut` is exclusive).
        // Suppressed under `addr_ctx` (the base of a further `&`/`&mut` is reborrowed, not read) and under
        // `place_use` (this is a place base like `x` in `x.f`, whose read was already checked precisely).
        if (!addr_ctx && !place_use && borrow_conflicting_read(t, id))
          typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                             "cannot use this value while it is mutably borrowed");
      }
      break;
    }
    case NODE_UNARY:
      result = check_unary(t, n, id);
      // A bare deref `*r` reads/writes the storage r points at. If a live reborrow holds it exclusively (a
      // borrow rooted at r), the access conflicts. Suppressed as a borrow target (`&*r`, addr_ctx) or as a
      // checked place base (`(*r).f`, place_use) -- those run their own precise check at the outer place.
      if (n->as.unary.op == Star && !addr_ctx && !place_use && borrow_conflicting_read(t, id))
        typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                           "cannot use this value while it is mutably borrowed");
      break;
    case NODE_BINARY:
      result = check_binary(t, n, id);
      break;
    case NODE_ASSIGNMENT: {
      // A plain `x = ..` to a deferred binding is its initialization, not a read: clear it before the LHS is
      // checked so the read-of-uninitialized check below does not fire. (Compound `x += ..` does read x.)
      const bool plain = n->as.binary.op == Equal;
      DefId ld = {.node = NODE_NONE};
      if (plain && ast_at_const(a, n->as.binary.left)->kind == NODE_IDENTIFIER)
        ld = ast_resolution_def(a, n->as.binary.left);
      const bool lhs_local = ld.node != NODE_NONE && ld.module == t->ast->module;
      if (lhs_local) {
        tc_init(t, ld.node);        // a plain `x = ..` initializes x ...
        tc_unmark_move(t, ld.node); // ... and gives it a fresh owned value (no longer moved / freed)
      }
      // Reassigning a reference binding (`r = &mut y` / `r = r1`) rebinds the borrow it stores. Drop r's
      // previous borrow BEFORE the RHS is checked (so `r = &mut x` while r already borrows x does not
      // self-conflict against the stale record), then bind the RHS's new borrow to r afterward.
      const TypeId lt = lhs_local ? decl_type_in(t, ld.module, ld.node) : TYPE_NONE;
      const bool ref_rebind = lt != TYPE_NONE && ast_type_at(a, lt)->kind == TYPE_REFERENCE;
      if (ref_rebind) {
        // Tombstone in place, never compact: an enclosing context's borrow_mark indexes into the array,
        // and shifting/shrinking below it would make the next release resurrect or misclassify records.
        for (uint32_t i = 0; i < t->nborrows; i++)
          if (t->borrows[i].binding == ld.node)
            borrow_tombstone(&t->borrows[i]);
      }
      const uint32_t bm = borrow_mark(t);
      const TypeId l = check_expr(t, n->as.binary.left);
      tc_mark_capture_mut(t, n->as.binary.left); // writing through a capture -> it becomes a `&mut` capture
      t->expected = l; // hand the lvalue's type to the RHS for expected-type resolution
      check_expr(t, n->as.binary.right);
      tc_mark_move(t, n->as.binary.right); // `z = x` moves a Free x
      if (ref_rebind) {
        if (t->nborrows > bm) {
          // The RHS produced a borrow (`&y`, or `f(&y)`) -- store it in r. The borrow lives for r's
          // scope, NOT the (possibly deeper) scope this assignment sits in: `{ r = &x; }` must keep the
          // borrow alive after the block when r is an outer binding (and tc_scope_exit flags the
          // dangling case where the borrowed root itself dies with the block).
          const uint16_t region = (uint16_t)tc_binding_depth(t, ld.node);
          for (uint32_t k = bm; k < t->nborrows; k++) {
            t->borrows[k].binding = ld.node;
            t->borrows[k].region = region;
          }
        } else { // `r = r1`: copy (`&`) or move (`&mut`) r1's stored borrow
          borrow_transfer_ref(t, n->as.binary.right, ld.node);
        }
      }
      if (!is_assignable(t, n->as.binary.left)) {
        const Span sp = ast_at_const(a, n->as.binary.left)->span;
        typechecker_errorf(t, sp.start, sp.end - sp.start, "cannot assign to this expression");
      } else if (borrow_conflicting_write(t, n->as.binary.left, id)) { // assigning through the owner while borrowed
        const Span sp = ast_at_const(a, n->as.binary.left)->span;
        typechecker_errorf(t, sp.start, sp.end - sp.start, "cannot assign to this value while it is borrowed");
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
      if (t->nclos >= sizeof t->clos_stack / sizeof t->clos_stack[0]) {
        typechecker_errorf(t, n->span.start, n->span.end - n->span.start, "closures nested too deeply (max 8)");
        result = TYPE_NONE;
        break;
      }
      t->clos_stack[t->nclos++] = id; // body mutations of captures record onto this node's mut_caps
      const uint32_t saved_lf = t->loop_floor; // a break/continue inside the body cannot target outer loops
      t->loop_floor = t->nloops;
      if (n->as.closure.expr_body) {
        check_expr(t, n->as.closure.body); // its type IS the closure's return type
        tc_capture_move_guard(t, n->as.closure.body); // the body expr is returned: no capture move-out
      } else {
        const NodeList saved = t->current_returns; // a `return` inside an anon `fn` targets the closure
        t->current_returns = n->as.closure.returns;
        check_stmt(t, n->as.closure.body);
        t->current_returns = saved;
      }
      t->loop_floor = saved_lf;
      t->nclos--;
      // Capture validation, AFTER the body so mut_caps is settled. A MUTATED capture is a `&mut` borrow
      // (env holds a pointer; outer keeps ownership -- so it also requires a mutable outer binding). A
      // COPY capture of a Free value MOVES ownership into the env (the closure value becomes Free and
      // frees it); the outer binding is moved, like any by-value transfer. Arrays cannot be captured by
      // copy at all (a C struct member cannot be initialized from an array value).
      const NodeList caps = n->as.closure.captures;
      const NodeId *const cids = ast_list(a, caps);
      const uint64_t mut_caps = ast_at_const(a, id)->as.closure.mut_caps;
      for (uint32_t i = 0; i < caps.len; i++) {
        const TypeId cty = decl_type(t, cids[i]);
        const bool is_mut = (mut_caps >> i & 1) != 0;
        if (cty != TYPE_NONE && !is_mut && ast_type_at(a, cty)->kind == TYPE_ARRAY) {
          typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                             "closure cannot capture a fixed-size array by copy; capture a slice instead");
          continue;
        }
        if (cty == TYPE_NONE || is_mut || !tc_type_is_free(t, cty))
          continue;
        // An OWNED Free capture: creation moves the value in, exactly like passing it by value.
        for (uint32_t m = 0; m < t->nmoved; m++)
          if (t->moved[m] == cids[i]) {
            typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                               "closure captures a moved value (use of moved value)");
            break;
          }
        // An enclosing closure capturing the same value (by copy or `&mut`) would be left holding a
        // stale view of something this closure now owns.
        for (uint32_t f = 0; f < t->nclos; f++)
          if (tc_capture_index(t, t->clos_stack[f], cids[i]) >= 0) {
            typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                               "cannot take ownership of a value also captured by an enclosing closure");
            break;
          }
        for (uint32_t b = 0; b < t->nborrows; b++) { // moving out from under a live borrow dangles it
          Borrow *const br = &t->borrows[b];
          if (br->root != cids[i])
            continue;
          if (borrow_dead_after(t, br, id)) {
            borrow_tombstone(br);
            continue;
          }
          typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                             "cannot capture this value while it is borrowed");
          break;
        }
        if (t->nmoved < (uint32_t)(sizeof t->moved / sizeof t->moved[0])) {
          t->moved[t->nmoved++] = cids[i];
        } else {
          typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                             "too many moved values in one function (move-analysis limit)");
        }
      }
      // The closure is a function value keyed on its own node, like a `fn(..) ..` pointer type.
      result = ast_intern_type(a, (Ty){.kind = TYPE_FUNCTION, .module = a->module, .as.decl = id});
      break;
    }
    case NODE_INDEX: {
      t->addr_ctx = addr_ctx; // `&buf[i]` borrows buf -- propagate the address context to the base
      t->place_use = !addr_ctx; // value index read: suppress the base's whole read (checked precisely below)
      TypeId obj = check_expr(t, n->as.index.object);
      // The base is type-resolved now, so the place decomposes; field-precise read check like NODE_MEMBER.
      // (The index expression, checked further below, is a separate value -- place_use was reset by the base.)
      if (!addr_ctx && !place_use && borrow_conflicting_read(t, id))
        typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                           "cannot use this value while it is mutably borrowed");
      // Auto-deref: `r[i]` / `r[lo..hi]` on a `&T` base indexes the referent, like member access. Raw
      // pointers keep C index semantics (unsafe, no dispatch), and a reference to an ARRAY stays an error:
      // its length lives outside the type, so neither bounds checks nor slicing could be lowered.
      if (ast_type_at(a, obj)->kind == TYPE_REFERENCE) {
        TypeId p = obj;
        const Ty *y = ast_type_at(a, p);
        while (y->kind == TYPE_REFERENCE) {
          p = y->as.elem;
          y = ast_type_at(a, p);
        }
        if (y->kind != TYPE_ARRAY)
          obj = p;
      }
      const Ty *const ot = ast_type_at(a, obj);
      const Node *const idxn = ast_at_const(a, n->as.index.index);
      if (idxn->kind == NODE_RANGE) { // `a[lo..hi]` -> a `[]T` view of the element type
        TypeId elem = TYPE_NONE, selem;
        TypeId user_result = TYPE_NONE; // set when a struct/instance dispatches to its `index_range` method
        if (ot->kind == TYPE_ARRAY || ot->kind == TYPE_POINTER) {
          if (ot->kind == TYPE_POINTER && !t->unsafe_depth)
            err_unsafe(t, ast_at_const(a, n->as.index.object)->span, "slicing a raw pointer");
          elem = ot->as.elem;
        }
        else if (slice_kind(t, obj, &selem))
          elem = selem;
        else if (ot->kind == TYPE_STRUCT || ot->kind == TYPE_INSTANCE) {
          // Range-index operator overloading (the Index interface): `obj[lo..hi]` -- any of `lo..hi`,
          // `lo..=hi`, `lo..`, `..hi`, `..=hi` -- dispatches to `obj.index_range(r)` with the written
          // bounds packed into a `Range<usize>`. A missing start is 0; a missing end is the value's
          // `len()`, so an open-ended range additionally requires a `len` method.
          ModuleId om;
          NodeId od;
          DefId gp[4];
          TypeId ga[4];
          int gn;
          const Span sp = ast_at_const(a, n->as.index.object)->span;
          if (aggregate_of(t, strip(t, obj), &om, &od, gp, ga, &gn)) {
            const DefId md = find_method_cstr(t, om, od, "index_range");
            if (md.node == NODE_NONE) {
              char ty[96];
              render_type(t, strip(t, obj), ty, sizeof ty);
              typechecker_errorf(t, sp.start, sp.end - sp.start, "'%s' has no 'index_range' method for '[..]'", ty);
              typechecker_notef(t, "implement the Index interface (an 'index_range' method) or slice a built-in array/slice");
            } else if (!method_extend_bounds_hold(t, strip(t, obj), md)) {
              err_method_extend_bounds(t, sp, strip(t, obj), md);
            } else {
              if (idxn->as.pattern_range.end == NODE_NONE && find_method_cstr(t, om, od, "len").node == NODE_NONE) {
                char ty[96];
                render_type(t, strip(t, obj), ty, sizeof ty);
                typechecker_errorf(t, sp.start, sp.end - sp.start,
                                   "an open-ended range index needs a 'len' method on '%s' to supply the end", ty);
              }
              prelude_range_type(t, ast_builtin(BT_USIZE)); // intern Range<usize>: the argument codegen builds
              user_result = tc_method_ret(t, strip(t, obj), md);
            }
          }
        } else if (obj != TYPE_NONE) {
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
        result = user_result != TYPE_NONE ? user_result
                 : elem != TYPE_NONE      ? prelude_slice_type(t, elem, false)
                                          : TYPE_NONE;
        break;
      }
      const TypeId idx = check_expr(t, n->as.index.index);
      bool overloaded = false;
      if (obj != TYPE_NONE) {
        TypeId selem;
        if (ot->kind == TYPE_ARRAY || ot->kind == TYPE_POINTER) {
          if (ot->kind == TYPE_POINTER && !t->unsafe_depth) // unchecked memory access (no length to bound it)
            err_unsafe(t, ast_at_const(a, n->as.index.object)->span, "indexing a raw pointer");
          result = ot->as.elem;
        } else if (slice_kind(t, obj, &selem)) // `s[i]` on a `[]T` -> the element type
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
              typechecker_notef(t, "define an 'index' method or use a built-in array/slice/pointer type");
            } else if (!method_extend_bounds_hold(t, strip(t, obj), md)) {
              err_method_extend_bounds(t, sp, strip(t, obj), md);
              result = TYPE_NONE;
            } else {
              const TypeId p1 = tc_method_param(t, strip(t, obj), md, 1); // the key must match `index`'s 2nd param
              if (!operand_fits_param(t, p1, n->as.index.index))
                err_mismatch(t, n->as.index.index, p1);
              result = tc_method_ret(t, strip(t, obj), md);
              // A reference-returning `index` makes `obj[i]` the ELEMENT PLACE (the compiler inserts the
              // deref, mirrored in codegen), so containers hand out borrowed elements, never copies. A
              // value-returning `index` keeps its rvalue behavior.
              if (result != TYPE_NONE && ast_type_at(a, result)->kind == TYPE_REFERENCE)
                result = ast_type_at(a, result)->as.elem;
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
    case NODE_MEMBER: {
      const bool value_read = !n->as.member.path && !addr_ctx;
      t->addr_ctx = addr_ctx;  // `&x.f` borrows x -- propagate the address context to the receiver
      t->place_use = value_read; // value member read: suppress the base's whole read (checked precisely below)
      result = n->as.member.path ? check_path_member(t, n, id, expected) : check_member(t, n, false);
      // The object is type-resolved now, so the place decomposes. Field-precise read check at the outermost
      // place: reading `x.f` conflicts with a `&mut` overlapping x.f, not with a disjoint `&mut x.g`.
      if (value_read && !place_use && borrow_conflicting_read(t, id))
        typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                           "cannot use this value while it is mutably borrowed");
      break;
    }
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
    case NODE_ALIGNOF:
      resolve_type(t, n->as.single.value); // validate the type; its byte size/alignment is a usize
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
      const uint32_t bm = borrow_mark(t);
      const TypeId scrut = check_expr(t, n->as.match_expr.value);
      // Binding mode (Rust match ergonomics): matching a reference binds each payload by reference
      // (`&T` / `&mut T`); matching an owned value moves it out and consumes the scrutinee.
      const Ty *const sy = ast_type_at(a, scrut);
      const int bind_ref = (sy->kind == TYPE_REFERENCE || sy->kind == TYPE_POINTER)
                               ? (sy->qualifier == TYPE_QUAL_MUT ? 2 : 1)
                               : 0;
      // For a BY-REFERENCE match (`switch &mut x`/`switch &x`) the payload bindings alias the scrutinee, so
      // its borrow must stay live THROUGH the arms -- mutating (or, under `&mut`, even reading) the scrutinee
      // in an arm then conflicts. A by-value match's scrutinee borrows nothing, so its temporaries end here
      // -- and destructuring it CONSUMES it, marked BEFORE the arms so an arm body reusing the consumed
      // value (`switch s { A => use(s) }`) is flagged as a use-after-move.
      if (bind_ref == 0) {
        borrow_release_to(t, bm);
        tc_mark_move(t, n->as.match_expr.value);
      }
      const NodeList arms = n->as.match_expr.arms;
      const NodeId *const ids = ast_list(a, arms);
      bool first = true;
      bool ovf = false;
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
        ovf |= tc_flow_collect(&acc, t); // ∪ this arm's effects
        // A diverging arm (`None => panic(..)`) constrains nothing: skip it in the unification,
        // and let a later value-producing arm replace a diverging `result`.
        const bool body_never = body != TYPE_NONE && ast_type_at(a, body)->kind == TYPE_NEVER;
        if (first) {
          result = body;
          first = false;
        } else if (result != TYPE_NONE && ast_type_at(a, result)->kind == TYPE_NEVER) {
          result = body;
        } else if (!body_never && result != body && body != TYPE_NONE && result != TYPE_NONE) {
          err_mismatch(t, arm->as.match_arm.body, result);
          result = TYPE_NONE;
        }
      }
      if (arms.len)
        tc_flow_set(t, &acc); // post-match = union of every arm
      if (ovf)
        tc_flow_overflow(t, id);
      borrow_release_to(t, bm); // arm-body temporaries end with the match expression
      check_match_exhaustive(t, n, scrut); // after the arms: check_pattern has resolved every tag pattern
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
          } else if (tc_ceval(t) && consteval_eval(tc_ceval(t), t->ast->module, el->as.field_initializer.name).kind == CONST_NONE) {
            // C requires an integer constant expression here; without the fold this emits invalid C.
            const Span sp = ast_at_const(a, el->as.field_initializer.name)->span;
            typechecker_errorf(t, sp.start, sp.end - sp.start, "array designator index must be a constant expression");
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
      tc_scope_enter(t);
      for (uint32_t i = 0; i < stmts.len; i++) {
        check_stmt(t, ids[i]);
        borrow_nll_drop(t, id, ids, i); // NLL: a stored borrow ends after its binding's last use
      }
      while (t->ndefers && t->defer_depth[t->ndefers - 1] == t->scope_depth) { // replay defers (see check_stmt)
        const NodeId dv = t->defer_stack[--t->ndefers];
        const uint32_t dbm = borrow_mark(t);
        check_expr(t, dv);
        borrow_release_to(t, dbm);
      }
      tc_scope_exit(t); // borrows made in this value-block end here (its value type is read below)
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
    case NODE_WHILE: { // a `loop { .. }` expression: yields the type its `break <expr>`s agree on
      t->loop_depth++;
      const int le = tc_loop_push(t, (Span){0, 0}, id, true);
      check_loop_body(t, n->as.while_stmt.body);
      if (le >= 0) {
        result = t->loop_stack[le].break_ty;
        tc_loop_pop(t, le, n->span);
      }
      if (result == TYPE_NONE) // no `break <expr>` ever runs: the expression never yields
        result = ast_intern_type(t->ast, (Ty){.kind = TYPE_NEVER});
      t->loop_depth--;
      break;
    }
    case NODE_IF: {
      // An `if` used as a value: both arms must agree, and an `else` is mandatory (a missing arm
      // would leave the value undefined). The arms are blocks whose tail expression is the value.
      const uint32_t bm = borrow_mark(t);
      const TypeId c = check_expr(t, n->as.if_stmt.condition);
      if (c != TYPE_NONE && !is_bool(t, c)) {
        const Span sp = ast_at_const(a, n->as.if_stmt.condition)->span;
        char ty[96];
        render_type(t, c, ty, sizeof ty);
        typechecker_errorf(t, sp.start, sp.end - sp.start, "if condition must be 'bool', found '%s'", ty);
      }
      borrow_release_to(t, bm); // condition temporaries end before the branches
      const FlowState ifpre = tc_flow_save(t); // branches are alternative paths -> check independent, union after
      const TypeId then_ty = check_expr(t, n->as.if_stmt.then_branch);
      if (n->as.if_stmt.else_branch == NODE_NONE) {
        typechecker_errorf(
            t, n->span.start, n->span.end - n->span.start, "an 'if' used as a value must have an 'else' branch");
        result = TYPE_NONE;
      } else {
        FlowState acc = {.nmoved = 0, .nuninit = 0};
        bool ovf = tc_flow_collect(&acc, t);
        tc_flow_set(t, &ifpre);
        const TypeId else_ty = check_expr(t, n->as.if_stmt.else_branch);
        ovf |= tc_flow_collect(&acc, t);
        tc_flow_set(t, &acc);
        if (ovf)
          tc_flow_overflow(t, id);
        // A diverging branch (`else { panic(..) }`) constrains nothing: the value is the other side's.
        const bool then_never = then_ty != TYPE_NONE && ast_type_at(a, then_ty)->kind == TYPE_NEVER;
        const bool else_never = else_ty != TYPE_NONE && ast_type_at(a, else_ty)->kind == TYPE_NEVER;
        if (then_never || else_never) {
          result = then_never ? else_ty : then_ty;
        } else if (then_ty != else_ty && then_ty != TYPE_NONE && else_ty != TYPE_NONE) {
          err_mismatch(t, n->as.if_stmt.else_branch, then_ty);
          result = TYPE_NONE;
        } else {
          result = then_ty;
        }
      }
      break;
    }
    case NODE_TUPLE: { // `(a, b, ..)` -> the prelude's Tuple<n> instance (fields `_0`..)
      const NodeList elems = n->as.array_literal.elements;
      const NodeId *const eids = ast_list(a, elems);
      if (elems.len > 4) {
        typechecker_errorf(t, n->span.start, n->span.end - n->span.start, "tuple arity is limited to 4 elements");
        break;
      }
      TypeId wargs[4]; // the expected tuple's element types, so literal elements adapt to their slot
      const int wn = expected != TYPE_NONE ? tuple_args_of(t, strip(t, expected), wargs, 4) : -1;
      TypeId targs[4];
      for (uint32_t i = 0; i < elems.len; i++) {
        const TypeId et = check_expr(t, eids[i]);
        targs[i] = et;
        if ((int)i < wn && et != wargs[i] && compatible(t, wargs[i], eids[i])) {
          targs[i] = wargs[i]; // `let t: (u8, bool) = (1, true)`: the literal takes the slot's type
          ast_set_type(a, eids[i], wargs[i]);
        }
        tc_mark_move(t, eids[i]); // a Free element is moved into the tuple (like a struct-init field)
      }
      result = prelude_tuple_type(t, targs, elems.len);
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
  t->mret_call = NODE_NONE;
  check_expr(t, value); // types the callee even though a multi-return call yields no single value
  // check_call stashed the substituted element types (generic / instance-method calls included).
  const bool stashed = value != NODE_NONE && t->mret_call == value;
  // A tuple-typed value (`let (a, b) = pair;`) destructures by element; the source is consumed.
  TypeId targs[4];
  int tn = -1;
  if (!stashed && value != NODE_NONE) {
    tn = tuple_args_of(t, strip(t, ast_type(a, value)), targs, 4);
    if (tn >= 0)
      tc_mark_move(t, value);
  }

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
  if (!ok && !stashed && tn < 0) {
    typechecker_errorf(
        t, n->span.start, n->span.end - n->span.start,
        "a tuple binding requires a multi-value function call or a tuple value");
    return;
  }
  const uint32_t nret = stashed ? t->mret_total : tn >= 0 ? (uint32_t)tn : returns.len;
  if (names.len != nret) {
    typechecker_errorf(
        t, n->span.start, n->span.end - n->span.start, "expected %u binding%s, the call returns %u value%s",
        names.len, names.len == 1 ? "" : "s", nret, nret == 1 ? "" : "s");
  }
  const NodeId *const rids = ast_list(a, returns);
  for (uint32_t i = 0; i < names.len; i++) {
    TypeId et = TYPE_NONE;
    if (stashed && i < t->mret_n) { // substituted by check_call (generic args / receiver instance / Self)
      et = t->mret_types[i];
    } else if (tn >= 0) {
      et = i < (uint32_t)tn ? targs[i] : TYPE_NONE; // tuple elements
    } else if (i < returns.len) {
      const Node *const rn = ast_at_const(a, rids[i]);
      et = resolve_type(t, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : rids[i]);
    }
    ast_set_type(a, nids[i], et); // each element identifier carries its field's type
  }
}

// The escape rank of one borrowed place: 1 = frame-local storage (a `let`/pattern/loop binding),
// 2 = a by-value parameter slot, 0 = storage that outlives the call. A place with a DEREF step lives
// behind another reference: safe through a reference PARAMETER (caller-owned), else it follows THAT
// binding's own live borrows (a reborrow chain), bounded by `depth`.
static int borrow_escape_of_binding(TypeChecker *t, NodeId binding, unsigned depth);
static int place_escape(TypeChecker *t, const NodeId place, const unsigned depth) {
  PStep steps[PLACE_MAX_STEPS];
  int ns;
  const NodeId root = place_decompose(t, place, steps, &ns, PLACE_MAX_STEPS);
  if (root == NODE_NONE)
    return 0; // raw pointer / heap / untracked -- assumed to outlive the call
  bool thru = false;
  for (int i = 0; i < ns; i++)
    thru |= steps[i].kind == PS_DEREF;
  if (thru)
    return ast_at_const(t->ast, root)->kind == NODE_PARAMETER ? 0 : borrow_escape_of_binding(t, root, depth + 1);
  return ast_at_const(t->ast, root)->kind == NODE_PARAMETER ? 2 : 1;
}
static int borrow_escape_of_binding(TypeChecker *t, const NodeId binding, const unsigned depth) {
  if (depth > 8)
    return 0;
  int esc = 0;
  for (uint32_t i = 0; i < t->nborrows; i++) {
    if (t->borrows[i].binding != binding)
      continue;
    const int e = place_escape(t, t->borrows[i].place, depth);
    if (e == 1)
      return 1; // a frame-local referent is the worst case; report it
    if (e)
      esc = e;
  }
  return esc;
}

// Escape analysis: the address provenance of a returned reference/pointer expression.
// 1 = derives from a local binding, 2 = from a by-value parameter slot, 0 = anything that outlives the call
// (global/heap, an address through a pointer, or a reference parameter -- the caller owns its referent).
// Looks through casts (`&x as *T`, `&x as usize`) and the transparent Move/Unsafe wrappers. A returned
// REFERENCE binding is judged by its LIVE BORROWS (assignments rebind those, so `let mut r = &x; r = p;
// return r;` is safe while `let mut r = p; r = &x; return r;` dangles); a pointer-typed local still
// follows its `let` initializer (raw pointers carry no borrows).
#define BORROW_ESCAPE_MAX_DEPTH 64
static int addr_escape_at(TypeChecker *t, NodeId e, const unsigned depth) {
  const Node *n = ast_at_const(t->ast, e);
  while (n->kind == NODE_CAST || (n->kind == NODE_UNARY && (n->as.unary.op == Move || n->as.unary.op == Unsafe))) {
    e = n->kind == NODE_CAST ? n->as.cast.expression : n->as.unary.operand;
    n = ast_at_const(t->ast, e);
  }
  if (n->kind == NODE_UNARY && n->as.unary.op == Ampersand) {
    // A field of a value struct / element of a value array shares storage with its base, so it dangles too; a
    // place reached THROUGH a reference/pointer (`&*r`, `&r.f`, `&*p`) names the referent's storage, which
    // outlives the call (or follows the reference's own borrows). place_decompose records the DEREF steps.
    return place_escape(t, n->as.unary.operand, depth);
  }
  if (n->kind == NODE_IDENTIFIER && depth < BORROW_ESCAPE_MAX_DEPTH) {
    const DefId d = ast_resolution_def(t->ast, e);
    if (d.module == t->ast->module && d.node != NODE_NONE) {
      const Node *const dn = ast_at_const(t->ast, d.node);
      const TypeId dt = ast_type(t->ast, d.node);
      if (dt != TYPE_NONE && ast_type_at(t->ast, dt)->kind == TYPE_REFERENCE)
        return borrow_escape_of_binding(t, d.node, depth); // flow-accurate: live borrows, not the initializer
      if (dn->kind == NODE_LET && dn->as.let_stmt.value != NODE_NONE)
        return addr_escape_at(t, dn->as.let_stmt.value, depth + 1); // pointer chains keep the old behavior
    }
  }
  return 0;
}
static int addr_escape(TypeChecker *t, const NodeId e) {
  return addr_escape_at(t, e, 0);
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
  for (uint32_t i = 0; i < values.len; i++) {
    check_expr(t, vids[i]);
    tc_capture_move_guard(t, vids[i]); // `return s` inside a closure must not move a capture out
  }
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
    return;
  }
  // A foldable condition is decided HERE (with this span). An unfoldable one
  // either TRAPPED (it would panic/overflow at runtime: a hard error, with the reason), or is not
  // yet decidable (e.g. it calls a function the checker has not reached) and is DEFERRED: the
  // driver re-evaluates it after the whole package checks. Still-undecidable conditions (an opaque
  // type's sizeof) lower to C _Static_assert as before.
  const ConstValue v = consteval_eval(tc_ceval(t), t->ast->module, n->as.binary.left);
  const Span sp = ast_at_const(t->ast, n->as.binary.left)->span;
  if (v.kind == CONST_BOOL && !v.i) {
    typechecker_errorf(t, sp.start, sp.end - sp.start, "static assertion failed");
  } else if (v.kind == CONST_NONE && tc_ceval(t)) {
    const char *const trap = consteval_trap(tc_ceval(t));
    if (trap)
      typechecker_errorf(t, sp.start, sp.end - sp.start, "static assertion cannot be evaluated: %s", trap);
    else
      consteval_defer_assert(tc_ceval(t), t->ast->module, n->as.binary.left);
  }
}

// Check a loop body, then -- if it moved a binding out (so a SECOND iteration would re-use it), or left a
// borrow live past its own end (one stored in an OUTER binding, so a second iteration's earlier statements
// run against it), and we are not already inside such a re-check -- check it AGAIN from the post-iteration
// state, catching back-edge use-after-move and back-edge aliasing (`while c { x += 1; r = &x; }`). The
// `in_loop_recheck` guard bounds this to one extra pass per outermost loop (no exponential blowup on
// nesting). A body that reassigns what it moved (tc_unmark_move) leaves nmoved unchanged, and body-local
// borrows die with the body's scope, so the common loop re-checks nothing.
static void check_loop_body(TypeChecker *t, const NodeId body) {
  const uint32_t nm0 = t->nmoved;
  const uint32_t nb0 = t->nborrows;
  check_stmt(t, body);
  if ((t->nmoved > nm0 || t->nborrows > nb0) && !t->in_loop_recheck) {
    t->in_loop_recheck = true;
    check_stmt(t, body);
    t->in_loop_recheck = false;
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
      tc_scope_enter(t);
      for (uint32_t i = 0; i < stmts.len; i++) {
        check_stmt(t, ids[i]);
        borrow_nll_drop(t, id, ids, i); // a stored borrow ends after its binding's last use, not at scope exit
      }
      // Replay this block's defers (LIFO) so their moves/frees land where they EXECUTE -- at scope exit,
      // after every statement above. Their first (registration-time) check was rolled back, so a use
      // between the `defer` and here is not a use-after-free; two defers freeing the same value still
      // collide here. Re-emitted identical diagnostics are dropped by errors_finalize.
      while (t->ndefers && t->defer_depth[t->ndefers - 1] == t->scope_depth) {
        const NodeId dv = t->defer_stack[--t->ndefers];
        const uint32_t dbm = borrow_mark(t);
        check_expr(t, dv);
        borrow_release_to(t, dbm);
      }
      tc_scope_exit(t); // borrows still live at block end (their last use was the final statement) end here
      break;
    }
    case NODE_LET: {
      // A stored reference (`let r = &x`) keeps its borrow alive for r's scope: the borrow is bound to
      // this binding (region = this block's depth), so the block's tc_scope_exit drops it exactly when r
      // goes out of scope. Any other initializer's borrows are temporaries, released at the end of the let.
      const uint32_t bm = borrow_mark(t);
      if (ast_at_const(a, n->as.let_stmt.name)->kind == NODE_PATTERN_TUPLE) {
        check_tuple_let(t, n);
        { // each element is a binding at this depth (borrow roots + regions + outlives checks key off it)
          const Node *const pat = ast_at_const(a, n->as.let_stmt.name);
          const NodeId *const eids = ast_list(a, pat->as.pattern.children);
          for (uint32_t k = 0; k < pat->as.pattern.children.len; k++)
            tc_record_binding_depth(t, eids[k]);
          tc_record_binding_depth(t, id);
        }
        // If any destructured element is a reference, the tuple's references may (conservatively) borrow the
        // initializer's reference arguments; keep those borrows alive for the tuple-let's scope. They are
        // lexical (bound to the tuple-let, which borrow_nll_drop leaves to tc_scope_exit) since element uses
        // do not resolve to the let node. Otherwise the initializer's borrows are temporaries.
        if (tuple_binds_reference(t, n->as.let_stmt.name) && t->nborrows > bm)
          for (uint32_t k = bm; k < t->nborrows; k++) {
            t->borrows[k].binding = id;
            t->borrows[k].region = (uint16_t)t->scope_depth;
          }
        else
          borrow_release_to(t, bm);
        break;
      }
      tc_record_binding_depth(t, id); // the binding's scope depth: borrow regions + outlives checks key off it
      const bool annotated = n->as.let_stmt.type != NODE_NONE;
      const bool valued = n->as.let_stmt.value != NODE_NONE;
      const TypeId declared = annotated ? resolve_type(t, n->as.let_stmt.type) : TYPE_NONE;
      if (valued) {
        t->expected = declared; // hand the annotation to the initializer for expected-type resolution
        check_expr(t, n->as.let_stmt.value);
        tc_mark_move(t, n->as.let_stmt.value); // `let y = x` moves a Free x into y
        tc_unmark_move(t, id); // this binding gets a fresh value -- clear any stale moved/freed state a prior
                               // loop iteration left on the same decl (so a re-declared loop-local is not
                               // seen as used-after-free/move on the back-edge re-check)
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
      // A reference-typed binding stores the borrow(s) its initializer created: `let r = &x` (r borrows x),
      // or -- conservatively -- `let r = f(&x)` where f returns a reference (r is taken to borrow f's
      // reference arguments, since we have no lifetime annotations to say otherwise). Keep them alive bound to
      // `id`; NLL ends them at this binding's last use. Any other initializer's borrows are temporaries.
      const bool binding_is_ref = binding != TYPE_NONE && ast_type_at(a, binding)->kind == TYPE_REFERENCE;
      const bool stores_borrow = binding_is_ref && t->nborrows > bm;
      if (stores_borrow)
        for (uint32_t k = bm; k < t->nborrows; k++) {
          t->borrows[k].binding = id;
          t->borrows[k].region = (uint16_t)t->scope_depth; // the borrow dies with ITS binding's scope
        }
      else {
        borrow_release_to(t, bm); // temporaries end with the statement
        if (binding_is_ref && valued) // `let r2 = r1`: copy (`&`) or move (`&mut`) r1's stored borrow
          borrow_transfer_ref(t, n->as.let_stmt.value, id);
      }
      break;
    }
    case NODE_CONST: {
      const uint32_t bm = borrow_mark(t);
      const TypeId declared = resolve_type(t, n->as.const_def.type);
      if (n->as.const_def.value != NODE_NONE) {
        check_expr(t, n->as.const_def.value);
        if (!compatible(t, declared, n->as.const_def.value))
          err_mismatch(t, n->as.const_def.value, declared);
      }
      ast_set_type(a, id, declared);
      borrow_release_to(t, bm);
      break;
    }
    case NODE_RETURN: {
      const uint32_t bm = borrow_mark(t);
      check_return(t, n, id);
      borrow_release_to(t, bm); // borrows of the returned values end with the statement
      break;
    }
    case NODE_DEFER: {
      // The deferred expression runs at scope EXIT, not here: check it now (type/name/borrow errors),
      // then roll its flow effects back -- a use between the `defer` and the block's end is NOT
      // after-free -- and register it for replay at the block's close (see NODE_BLOCK).
      const FlowState pre = tc_flow_save(t);
      const uint32_t bm = borrow_mark(t);
      check_expr(t, n->as.single.value);
      borrow_release_to(t, bm);
      tc_flow_set(t, &pre);
      if (t->ndefers < (uint32_t)(sizeof t->defer_stack / sizeof t->defer_stack[0])) {
        t->defer_stack[t->ndefers] = n->as.single.value;
        t->defer_depth[t->ndefers++] = t->scope_depth;
      } else {
        typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                           "too many pending 'defer' statements in one function (analysis limit)");
      }
      break;
    }
    case NODE_IF:
      check_if(t, n);
      break;
    case NODE_WHILE: {
      t->loop_depth++; // node-id order stops implying execution order (the back edge re-runs earlier nodes)
      // Statement position: even a condition-less `loop` yields nothing here, so `break <expr>` is
      // rejected (value_loop = false); `loop` as an expression is checked in check_expr instead.
      const int le = tc_loop_push(t, n->as.while_stmt.label, id, false);
      const uint32_t bm = borrow_mark(t);
      const TypeId c = check_expr(t, n->as.while_stmt.condition);
      if (c != TYPE_NONE && !is_bool(t, c)) {
        const Span sp = ast_at_const(a, n->as.while_stmt.condition)->span;
        char ty[96];
        render_type(t, c, ty, sizeof ty);
        typechecker_errorf(t, sp.start, sp.end - sp.start, "while condition must be 'bool', found '%s'", ty);
      }
      borrow_release_to(t, bm); // condition temporaries end before the body (re-evaluated each iteration)
      if (n->as.while_stmt.is_do || n->as.while_stmt.condition == NODE_NONE) {
        check_loop_body(t, n->as.while_stmt.body); // a do-while / infinite-loop body runs at least once
      } else {
        // The body runs zero or more times: union the post-body state with the pre-body one, so an
        // initialization/move inside the loop does not count as definite on the zero-iteration path.
        const FlowState pre = tc_flow_save(t);
        check_loop_body(t, n->as.while_stmt.body);
        FlowState acc = {.nmoved = 0, .nuninit = 0};
        bool ovf = tc_flow_collect(&acc, t);
        tc_flow_set(t, &pre);
        ovf |= tc_flow_collect(&acc, t);
        tc_flow_set(t, &acc);
        if (ovf)
          tc_flow_overflow(t, n->as.while_stmt.condition);
      }
      tc_loop_pop(t, le, n->span);
      t->loop_depth--;
      break;
    }
    case NODE_FOR: {
      t->loop_depth++; // see NODE_WHILE
      const int le = tc_loop_push(t, n->as.for_stmt.label, id, false);
      const uint32_t bm = borrow_mark(t);
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
      // The loop binding lives per-iteration, INSIDE the body's scope: a reference to it stored in an
      // outer binding must be flagged as outliving it (tc_scope_exit), so record it at body depth.
      if (id != NODE_NONE)
        TcDepthMap_insert(&t->binding_depth, id, t->scope_depth + 1);
      borrow_release_to(t, bm); // iterable temporaries end before the body
      {
        const FlowState pre = tc_flow_save(t); // zero-or-more iterations: union with the skip path
        check_loop_body(t, n->as.for_stmt.body);
        FlowState acc = {.nmoved = 0, .nuninit = 0};
        bool ovf = tc_flow_collect(&acc, t);
        tc_flow_set(t, &pre);
        ovf |= tc_flow_collect(&acc, t);
        tc_flow_set(t, &acc);
        if (ovf)
          tc_flow_overflow(t, iter);
      }
      tc_loop_pop(t, le, n->span);
      t->loop_depth--;
      break;
    }
    case NODE_EXPRESSION_STATEMENT: {
      const uint32_t bm = borrow_mark(t);
      check_expr(t, n->as.single.value);
      borrow_release_to(t, bm); // temporaries (`f(&x)`, an assignment's `&y`) end with the statement
      break;
    }
    case NODE_BREAK:
    case NODE_CONTINUE: {
      const Span lb = n->as.flow.label;
      const int le = tc_find_loop(t, lb);
      if (le < 0) {
        if (lb.end > lb.start) // the label span already includes its leading quote
          typechecker_errorf(t, n->span.start, n->span.end - n->span.start, "no enclosing loop is labeled %.*s",
                             (int)(lb.end - lb.start), t->source + lb.start);
        else
          typechecker_errorf(t, n->span.start, n->span.end - n->span.start, "'%s' outside of a loop",
                             n->kind == NODE_BREAK ? "break" : "continue");
        if (n->as.flow.value != NODE_NONE)
          check_expr(t, n->as.flow.value); // still check it (avoid cascades)
        break;
      }
      ast_set_resolution(a, id, t->loop_stack[le].node); // codegen routes labels/defers through this
      if (n->kind != NODE_BREAK)
        break;
      if (n->as.flow.value == NODE_NONE) {
        t->loop_stack[le].saw_bare = true;
        break;
      }
      const NodeId v = n->as.flow.value;
      t->expected = t->loop_stack[le].break_ty; // later breaks adapt their literals to the first's type
      const TypeId vt = check_expr(t, v);
      if (!t->loop_stack[le].value_loop) {
        typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                           "'break' can only carry a value inside a 'loop' expression");
      } else if (t->loop_stack[le].break_ty == TYPE_NONE) {
        t->loop_stack[le].break_ty = vt;
      } else if (!compatible(t, t->loop_stack[le].break_ty, v)) {
        err_mismatch(t, v, t->loop_stack[le].break_ty);
      }
      t->loop_stack[le].saw_value = true;
      tc_mark_move(t, v); // the value leaves the loop, like a return
      break;
    }
    default:
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
      tc_record_binding_depth(t, id);
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
      tc_record_binding_depth(t, id);
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
      t->nborrows = t->scope_depth = 0;       // fresh borrow-check state per body
      t->loop_depth = 0;
      t->ndefers = 0;
      if (n->as.function.body != NODE_NONE)
        check_stmt(t, n->as.function.body);
      t->nmoved = t->nuninit = t->nfreed = 0;
      t->nborrows = t->scope_depth = 0;
      t->loop_depth = 0;
      t->ndefers = 0;
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
    case NODE_INTERFACE:
      check_associated(t, n->as.interface_def.items);
      break;
    case NODE_EXTEND: {
      // Inside `extend S { ... }`, S's private fields are reachable (current_self == S).
      const NodeId saved = t->current_self;
      const NodeId saved_impl = t->current_extend;
      t->current_self = ast_resolution(t->ast, n->as.extend_def.target_type);
      t->current_extend = id; // a bare `Self` here lowers to this extend's target type (with its generics)
      if (n->as.extend_def.interface_type != NODE_NONE)
        check_extend_conformance(t, n);
      check_associated(t, n->as.extend_def.items);
      t->current_self = saved;
      t->current_extend = saved_impl;
      break;
    }
    case NODE_CONST: {
      const TypeId declared = resolve_type(t, n->as.const_def.type);
      if (n->as.const_def.value != NODE_NONE) {
        check_expr(t, n->as.const_def.value);
        if (!compatible(t, declared, n->as.const_def.value))
          err_mismatch(t, n->as.const_def.value, declared);
      }
      // A `static mut` global has no owning scope, so nothing would ever run its destructor.
      if (n->as.const_def.is_static_mut && tc_type_is_free(t, declared)) {
        typechecker_errorf(t, n->span.start, n->span.end - n->span.start,
                           "a 'static mut' cannot hold an owning (Free) type");
        typechecker_notef(t, "no scope ever frees a global; store a scalar/view or manage the value locally");
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
      if (n->kind != NODE_EXTEND || !n->as.extend_def.generics.len ||
          ast_resolution(ma, n->as.extend_def.target_type) != it.decl)
        continue;
      const NodeList gens = n->as.extend_def.generics;
      const NodeId *const gids = ast_list(ma, gens);
      DefId ip[4];
      TypeId ia[4];
      int ipn = 0;
      for (uint32_t g = 0; g < gens.len && g < it.n && ipn < 4; g++) {
        ip[ipn] = (DefId){it.module, gids[g]};
        ia[ipn] = it.args[g];
        ipn++;
      }
      const NodeList ms = n->as.extend_def.items;
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
      &t->errors, &t->errors_notes, &t->errors_start, &t->errors_len, t->source, t->len,
      t->package && t->ast->module < t->package->count ? t->package->modules[t->ast->module].file : NULL);
}

ERRORS_BODY(TypeChecker, typechecker, t)
