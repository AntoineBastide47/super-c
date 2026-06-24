#include "codegen.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "module/loader.h"
#include "types/hashmap.h"

// Lowers a resolved, type-checked Ast to a single C translation unit (see plan in
// src/codegen). Names are already bound (`ast_resolution`) and every expression typed
// (`ast_type`); codegen never re-derives scope. Type rendering walks either the AST type
// node (which still carries array lengths / qualifiers) or the interned `Ty` when only a
// `TypeId` is on hand. Output goes straight to a FILE* with fprintf, exactly like ast_fprint.
// NodeId(variant) -> NodeId(enum): built once so enclosing_enum is O(1), not a per-reference
// O(items x variants) scan of the whole program.
static inline size_t cg_nodeid_hash(const NodeId k) {
  return (size_t)k * 0x9E3779B1u;
}
#define CG_NODEID_EQ(a, b) ((a) == (b))
HM_DECLARE(NodeId, NodeId, CgEnumMap)
HM_DEFINE(NodeId, NodeId, CgEnumMap, cg_nodeid_hash, CG_NODEID_EQ)

// Every C standard library header, each behind __has_include so a toolchain that lacks an optional or
// C23 header (threads.h / uchar.h / stdbit.h on this macOS, etc.) silently skips it instead of failing.
#define RT_H(h) "#if __has_include(<" h ">)\n#include <" h ">\n#endif\n"
const char *const SUPER_RT_INCLUDES =
    RT_H("assert.h") RT_H("complex.h") RT_H("ctype.h") RT_H("errno.h") RT_H("fenv.h") RT_H("float.h")
    RT_H("inttypes.h") RT_H("iso646.h") RT_H("limits.h") RT_H("locale.h") RT_H("math.h") RT_H("setjmp.h")
    RT_H("signal.h") RT_H("stdalign.h") RT_H("stdarg.h") RT_H("stdatomic.h") RT_H("stdbit.h") RT_H("stdbool.h")
    RT_H("stdckdint.h") RT_H("stddef.h") RT_H("stdint.h") RT_H("stdio.h") RT_H("stdlib.h") RT_H("stdnoreturn.h")
    RT_H("string.h") RT_H("tgmath.h") RT_H("threads.h") RT_H("time.h") RT_H("uchar.h") RT_H("wchar.h")
    RT_H("wctype.h");
#undef RT_H

struct Codegen {
    Ast *ast;
    const uint8_t *source;
    size_t len;
    char *buf;                 // C output accumulated in memory, flushed in one write at the end
    size_t buf_len;            // bytes written
    size_t buf_cap;            // allocated capacity
    CgEnumMap enum_of_variant; // see build_enum_index
    unsigned depth;            // current C indentation level
    unsigned tmp;              // counter feeding fresh() unique `__sc<N>` names
    char current_ret[128];     // enclosing function's multi-return struct name, or ""
    const Package *package;    // for cross-module references / mangling (NULL = single file)
    bool mangle;               // true for >1 user module: prefix every symbol by its module
    bool multifile;            // emit as header + .c with includes (build/ tree), vs one self-contained .c
    // Monomorphization: while emitting a specialization, `subst` maps each generic param (DefId) to its
    // concrete type; `insts` is the dedup'd set of generic instantiations used by this module.
    struct {
        DefId param;
        TypeId concrete;
    } subst[8];
    int nsubst;
    struct {
        DefId fn;
        uint8_t n;
        TypeId args[4];
    } insts[256];
    int ninsts;
    ERRORS_VARIABLES;
};

// The Ast / source backing module `m`: the current module uses the in-flight Ast; any other module in
// the package is read through it. Independent of mangling, so cross-module refs (e.g. the prelude) also
// resolve in self-contained output. The standalone REPL/test Ast has module == package->count, so its
// own nodes take the `c->ast` branch and never index the package.
ALWAYS_INLINE Ast *cg_mod_ast(const Codegen *c, const ModuleId m) {
  return c->package && m != c->ast->module ? c->package->modules[m].ast : c->ast;
}
ALWAYS_INLINE const uint8_t *cg_mod_src(const Codegen *c, const ModuleId m) {
  return c->package && m != c->ast->module ? (const uint8_t *)c->package->modules[m].source : c->source;
}

// Render module `m`'s mangled prefix ("std::string" -> "std__string__") into buf; empty when not
// mangling. Returns the number of bytes the full prefix needs.
static size_t render_modpfx(const Codegen *c, const ModuleId m, char *buf, const size_t cap) {
  if (cap)
    buf[0] = '\0';
  if (!c->mangle)
    return 0;
  if (c->package->modules[m].prelude) // prelude symbols (str, String, ...) keep stable unmangled names
    return 0;
  const char *const path = c->package->modules[m].path;
  size_t at = 0;
  for (size_t i = 0; path[i]; i++) {
    if (path[i] == ':' && path[i + 1] == ':') {
      i++;
      if (at + 2 < cap) {
        buf[at] = '_';
        buf[at + 1] = '_';
      }
      at += 2;
    } else {
      if (at + 1 < cap)
        buf[at] = path[i];
      at += 1;
    }
  }
  if (at + 2 < cap) {
    buf[at] = '_';
    buf[at + 1] = '_';
  }
  at += 2;
  if (at < cap)
    buf[at] = '\0';
  return at;
}

// Super-C builtin names (for matching unresolved type paths) and their C spellings.
static const char *const BUILTIN_NAMES[BT_COUNT] = {
    "bool", "char", "i8",  "i16",   "i32", "i64", "isize", "u8",
    "u16",  "u32",  "u64", "usize", "f32", "f64", "void",
};
static const char *const BUILTIN_C[BT_COUNT] = {
    "bool",     "char",     "int8_t",   "int16_t", "int32_t", "int64_t", "intptr_t", "uint8_t",
    "uint16_t", "uint32_t", "uint64_t", "size_t",  "float",   "double",  "void",
};

static void emit_expr(Codegen *c, NodeId id);
static void emit_stmt(Codegen *c, NodeId id);
static void emit_block(Codegen *c, NodeId id);
static void emit_if(Codegen *c, const Node *n);
static void emit_if_expr(Codegen *c, NodeId id);
static void emit_array_braces(Codegen *c, const Node *n);
static void emit_condition(Codegen *c, NodeId id);
static void render_type_node(Codegen *c, NodeId tn, const char *decl, char *out, size_t cap);
static void render_type_id(Codegen *c, TypeId t, const char *decl, char *out, size_t cap);
static void emit_match_core(Codegen *c, NodeId id, int mode, const char *result);
static void emit_pattern_test(Codegen *c, NodeId pid, const char *scrut);
static void emit_pattern_binds(Codegen *c, NodeId pid, const char *scrut);
static bool aggregate_has_payload(Codegen *c, const Node *enum_node);
static bool aggregate_has_payload_in(Codegen *c, ModuleId m, const Node *enum_node);
static void inst_name(Codegen *c, const TyInstance *it, char *out, size_t cap);
static TypeId subst_lookup(Codegen *c, ModuleId m, NodeId decl);
static TypeId subst_resolve(Codegen *c, TypeId t);
static bool type_is_concrete(Codegen *c, TypeId t);
static size_t buf_append(char *out, size_t cap, size_t at, const char *text);

Codegen *codegen_new(Ast *ast, const char *source, const size_t len, const Package *package) {
  Codegen *const c = calloc(1, sizeof *c);
  if (!c) {
    fprintf(stderr, "fatal: out of memory\n");
    abort();
  }
  c->ast = ast;
  c->source = (const uint8_t *)source;
  c->len = len;
  c->package = package;
  // Mangle only when more than one *user* module is in play; the prelude is always emitted unmangled, and
  // a lone user module (+ prelude) stays a single self-contained .c with plain names.
  size_t user_mods = 0;
  if (package)
    for (size_t i = 0; i < package->count; i++)
      user_mods += !package->modules[i].prelude;
  c->mangle = user_mods > 1;
  c->multifile = c->mangle; // default; the CLI forces multifile so a lone module still gets a build/ tree
  c->buf_cap = len * 4 + 4096; // generated C runs a few x the source; reserve up front
  c->buf = malloc(c->buf_cap);
  if (!c->buf) {
    fprintf(stderr, "fatal: out of memory\n");
    abort();
  }
  ERRORS_INIT(c);
  return c;
}

void codegen_free(Codegen **c) {
  if (!c || !*c)
    return;
  ast_free(&(*c)->ast);
  CgEnumMap_deinit(&(*c)->enum_of_variant);
  free((*c)->buf);
  ERRORS_DEINIT(c);
  free(*c);
  *c = NULL;
}

Ast *codegen_take_ast(Codegen *c) {
  Ast *const ast = c->ast;
  c->ast = NULL;
  return ast;
}

void codegen_set_multifile(Codegen *c, const bool on) {
  c->multifile = on;
}

// --- low-level helpers ---------------------------------------------------------------------

static void emit_reserve(Codegen *c, const size_t extra) {
  if (c->buf_len + extra <= c->buf_cap)
    return;
  size_t cap = c->buf_cap ? c->buf_cap : 4096;
  while (cap < c->buf_len + extra)
    cap *= 2;
  char *const buf = realloc(c->buf, cap);
  if (!buf) {
    fprintf(stderr, "fatal: out of memory\n");
    abort();
  }
  c->buf = buf;
  c->buf_cap = cap;
}

// Raw append, no format parsing — the hot path for spans and fixed strings.
static void emit_bytes(Codegen *c, const char *const p, const size_t n) {
  emit_reserve(c, n);
  memcpy(c->buf + c->buf_len, p, n);
  c->buf_len += n;
}

#if defined(__GNUC__) || defined(__clang__)
# define EMIT_FORMAT __attribute__((format(printf, 2, 3)))
#else
# define EMIT_FORMAT
#endif

EMIT_FORMAT static void emit(Codegen *c, const char *fmt, ...) {
  const char *p = fmt;
  while (*p && *p != '%')
    p++;
  if (!*p) {
    emit_bytes(c, fmt, (size_t)(p - fmt));
    return;
  }

  va_list args;
  va_start(args, fmt);
  const size_t avail = c->buf_cap - c->buf_len;
  va_list copy;
  va_copy(copy, args);
  const int n = vsnprintf(c->buf + c->buf_len, avail, fmt, copy);
  va_end(copy);
  if (n > 0) {
    if ((size_t)n >= avail) { // didn't fit: grow and reformat
      emit_reserve(c, (size_t)n + 1);
      vsnprintf(c->buf + c->buf_len, (size_t)n + 1, fmt, args);
    }
    c->buf_len += (size_t)n;
  }
  va_end(args);
}

static void emit_indent(Codegen *c) {
  static const char spaces[33] = "                                ";
  for (unsigned n = c->depth * 2; n; ) {
    const unsigned k = n < 32 ? n : 32;
    emit_bytes(c, spaces, k);
    n -= k;
  }
}

ALWAYS_INLINE Span name_span(const Codegen *c, const NodeId name_node) {
  return ast_at_const(c->ast, name_node)->as.name.text;
}
// The name span of a node living in module `m` (for references that may cross a module boundary).
ALWAYS_INLINE Span name_span_in(const Codegen *c, const ModuleId m, const NodeId name_node) {
  return ast_at_const(cg_mod_ast(c, m), name_node)->as.name.text;
}

static void emit_span(Codegen *c, const Span s) {
  emit_bytes(c, (const char *)c->source + s.start, (size_t)(s.end - s.start));
}

ALWAYS_INLINE bool span_is(const uint8_t *const src, const Span s, const char *const lit) {
  const size_t n = strlen(lit);
  return (size_t)(s.end - s.start) == n && memcmp(src + s.start, lit, n) == 0;
}

static int builtin_of(const uint8_t *const src, const Span s) {
  for (int i = 0; i < BT_COUNT; i++)
    if (span_is(src, s, BUILTIN_NAMES[i]))
      return i;
  return -1;
}

// C keywords (and a few reserved identifiers) a user name might collide with. A matching name
// gets a trailing `_` at every declaration and reference so the two still agree.
static bool is_c_keyword(const uint8_t *src, const Span s) {
  const size_t n = s.end - s.start;
#define IS(lit) (n == sizeof(lit) - 1 && memcmp(src + s.start, lit, sizeof(lit) - 1) == 0)
  switch (n ? src[s.start] : 0) {
    case 'N': return IS("NULL");
    case '_':
      return IS("_Bool") || IS("_Complex") || IS("_Atomic") || IS("_Noreturn") || IS("_Generic") ||
             IS("_Static_assert") || IS("_Thread_local");
    case 'a': return IS("auto");
    case 'b': return IS("break") || IS("bool");
    case 'c': return IS("case") || IS("char") || IS("const") || IS("continue");
    case 'd': return IS("default") || IS("do") || IS("double");
    case 'e': return IS("else") || IS("enum") || IS("extern");
    case 'f': return IS("float") || IS("for") || IS("false");
    case 'g': return IS("goto");
    case 'i': return IS("if") || IS("inline") || IS("int");
    case 'l': return IS("long");
    case 'r': return IS("register") || IS("restrict") || IS("return");
    case 's': return IS("short") || IS("signed") || IS("sizeof") || IS("static") || IS("struct") || IS("switch");
    case 't': return IS("typedef") || IS("true");
    case 'u': return IS("union") || IS("unsigned");
    case 'v': return IS("void") || IS("volatile");
    case 'w': return IS("while");
    default: return false;
  }
#undef IS
}

static void emit_ident(Codegen *c, const Span s) {
  emit_span(c, s);
  if (is_c_keyword(c->source, s))
    emit_bytes(c, "_", 1);
}

// Render an identifier (keyword-mangled) from an explicit source buffer into `buf`.
static size_t render_ident_src(const uint8_t *src, const Span s, char *buf, const size_t cap) {
  const size_t source_len = s.end - s.start;
  const bool suffix = is_c_keyword(src, s);
  const size_t full_len = source_len + suffix;
  if (cap) {
    const size_t copied = source_len < cap - 1 ? source_len : cap - 1;
    memcpy(buf, src + s.start, copied);
    size_t written = copied;
    if (suffix && written + 1 < cap)
      buf[written++] = '_';
    buf[written] = '\0';
  }
  return full_len;
}

// Render an identifier (keyword-mangled) into a buffer, for building declarator/accessor strings.
static size_t render_ident(Codegen *c, const Span s, char *buf, const size_t cap) {
  return render_ident_src(c->source, s, buf, cap);
}

// Render `<module prefix><identifier>` for a symbol named by `name_node` defined in module `owner`
// (its name span is read from `owner`'s source). The prefix is empty unless mangling is active.
static size_t render_qualified(Codegen *c, const ModuleId owner, const NodeId name_node, char *buf, const size_t cap) {
  const size_t at = render_modpfx(c, owner, buf, cap);
  const size_t off = at < cap ? at : (cap ? cap - 1 : 0);
  const Span s = ast_at_const(cg_mod_ast(c, owner), name_node)->as.name.text;
  return at + render_ident_src(cg_mod_src(c, owner), s, buf + off, cap > off ? cap - off : 0);
}

// A C-identifier-safe spelling of a type, for monomorphization name mangling: i32, lib__Foo, ptr_i32,
// slice_u8, arr_f64. Nested types recurse so distinct instantiations get distinct symbol names.
static void mangle_type(Codegen *c, const TypeId t, char *out, const size_t cap) {
  const Ty *const ty = ast_type_at(c->ast, t);
  switch (ty->kind) {
    case TYPE_BUILTIN:
      buf_append(out, cap, 0, BUILTIN_NAMES[ty->as.builtin]);
      break;
    case TYPE_STRUCT:
    case TYPE_ENUM:
      render_qualified(c, ty->module, ast_at_const(cg_mod_ast(c, ty->module), ty->as.decl)->as.aggregate.name, out, cap);
      break;
    case TYPE_POINTER:
    case TYPE_REFERENCE: {
      char e[176];
      mangle_type(c, ty->as.elem, e, sizeof e);
      snprintf(out, cap, "ptr_%s", e);
      break;
    }
    case TYPE_SLICE: {
      char e[176];
      mangle_type(c, ty->as.elem, e, sizeof e);
      snprintf(out, cap, "slice_%s", e);
      break;
    }
    case TYPE_ARRAY: {
      char e[176];
      mangle_type(c, ty->as.elem, e, sizeof e);
      snprintf(out, cap, "arr_%s", e);
      break;
    }
    case TYPE_INSTANCE:
      inst_name(c, ast_instance(c->ast, ty->as.inst), out, cap);
      break;
    default:
      buf_append(out, cap, 0, "v");
      break;
  }
}

// The mangled C name of a generic function specialization: `<fn>__<arg1>[__<arg2>...]` (e.g. `id__i32`).
static void spec_name(Codegen *c, const DefId fn, const TypeId *const args, const int n, char *out, const size_t cap) {
  size_t at = render_qualified(c, fn.module, ast_at_const(cg_mod_ast(c, fn.module), fn.node)->as.function.name, out, cap);
  for (int i = 0; i < n; i++) {
    at = buf_append(out, cap, at, "__");
    char e[176];
    mangle_type(c, args[i], e, sizeof e);
    at = buf_append(out, cap, at, e);
  }
}

// The mangled C name of a generic struct/enum instantiation: `<Type>__<arg1>[__<arg2>...]` (e.g. Box__i32).
// Args are resolved through the active specialization substitution, so a reference to Box<T> inside a
// specialization of T=i32 mangles to Box__i32 (matching the emitted struct).
static void inst_name(Codegen *c, const TyInstance *const it, char *out, const size_t cap) {
  size_t at = render_qualified(c, it->module, ast_at_const(cg_mod_ast(c, it->module), it->decl)->as.aggregate.name, out, cap);
  for (uint8_t i = 0; i < it->n; i++) {
    at = buf_append(out, cap, at, "__");
    char e[176];
    mangle_type(c, subst_resolve(c, it->args[i]), e, sizeof e);
    at = buf_append(out, cap, at, e);
  }
}

// Resolve a type through the active specialization substitution (TYPE_GENERIC param -> concrete),
// recursing through pointer/ref/slice/array layers and generic-instance args. Identity when not
// specializing (nsubst == 0). Re-interns rewritten compound types into the current pool.
static TypeId subst_resolve(Codegen *c, const TypeId t) {
  if (c->nsubst == 0)
    return t;
  const Ty *const y = ast_type_at(c->ast, t);
  switch (y->kind) {
    case TYPE_GENERIC: {
      const TypeId s = subst_lookup(c, y->module, y->as.decl);
      return s != TYPE_NONE ? s : t;
    }
    case TYPE_POINTER:
    case TYPE_REFERENCE:
    case TYPE_SLICE:
    case TYPE_ARRAY: {
      const TypeId e = subst_resolve(c, y->as.elem);
      if (e == y->as.elem)
        return t;
      Ty nt = *y;
      nt.as.elem = e;
      return ast_intern_type(c->ast, nt);
    }
    case TYPE_INSTANCE: {
      const TyInstance src = *ast_instance(c->ast, y->as.inst);
      TypeId na[4];
      bool changed = false;
      for (uint8_t i = 0; i < src.n; i++) {
        na[i] = subst_resolve(c, src.args[i]);
        changed |= na[i] != src.args[i];
      }
      return changed ? ast_intern_instance(c->ast, src.module, src.decl, na, src.n) : t;
    }
    default:
      return t;
  }
}

// Whether a type mentions no unresolved type parameter -- i.e. it is a real instantiation worth emitting
// (a specialization template like Box<T> or id::<T> is intermediate and must be skipped).
static bool type_is_concrete(Codegen *c, const TypeId t) {
  const Ty *const y = ast_type_at(c->ast, t);
  switch (y->kind) {
    case TYPE_GENERIC:
      return false;
    case TYPE_POINTER:
    case TYPE_REFERENCE:
    case TYPE_SLICE:
    case TYPE_ARRAY:
      return type_is_concrete(c, y->as.elem);
    case TYPE_INSTANCE: {
      const TyInstance *const it = ast_instance(c->ast, y->as.inst);
      for (uint8_t i = 0; i < it->n; i++)
        if (!type_is_concrete(c, it->args[i]))
          return false;
      return true;
    }
    default:
      return true;
  }
}

// If node `callId` is a call to a generic function (turbofish `f::<T..>(..)` or a bare `f(..)` whose type
// args were inferred), return the generic fn's DefId and fill `args`/`*n` with the concrete type-arg
// TypeIds (recorded by the type checker); otherwise return {_, NODE_NONE}.
static DefId generic_call_target(Codegen *c, const NodeId callId, TypeId *const args, int *const n) {
  *n = 0;
  const Node *const call = ast_at_const(c->ast, callId);
  if (call->kind != NODE_CALL)
    return (DefId){0, NODE_NONE};
  const Node *const callee = ast_at_const(c->ast, call->as.call.callee);
  const DefId fn = callee->kind == NODE_GENERIC_SPECIALIZATION
                       ? ast_resolution_def(c->ast, callee->as.specialization.expression)
                       : ast_resolution_def(c->ast, call->as.call.callee);
  if (fn.node == NODE_NONE)
    return (DefId){0, NODE_NONE};
  const Node *const fnnode = ast_at_const(cg_mod_ast(c, fn.module), fn.node);
  if (fnnode->kind != NODE_FUNCTION || !fnnode->as.function.generics.len)
    return (DefId){0, NODE_NONE};
  const MonoUse *const mu = ast_type_args(c->ast, callId);
  if (!mu)
    return (DefId){0, NODE_NONE};
  for (uint8_t i = 0; i < mu->n && *n < 4; i++)
    args[(*n)++] = mu->args[i];
  return fn;
}

// Record a generic instantiation for this module, deduplicated (same fn + same type args -> emitted once).
static void record_inst(Codegen *c, const DefId fn, const TypeId *const args, const int n) {
  for (int i = 0; i < c->ninsts; i++) {
    if (c->insts[i].fn.module != fn.module || c->insts[i].fn.node != fn.node || c->insts[i].n != n)
      continue;
    bool same = true;
    for (int j = 0; j < n; j++)
      if (c->insts[i].args[j] != args[j]) {
        same = false;
        break;
      }
    if (same)
      return;
  }
  if (c->ninsts >= (int)(sizeof c->insts / sizeof c->insts[0]))
    return;
  c->insts[c->ninsts].fn = fn;
  c->insts[c->ninsts].n = (uint8_t)n;
  for (int j = 0; j < n; j++)
    c->insts[c->ninsts].args[j] = args[j];
  c->ninsts++;
}

// Scan every node for turbofish generic calls and record the (deduplicated) instantiations this module
// needs. A linear scan over the node arena finds calls anywhere in any body.
static void collect_insts(Codegen *c) {
  c->ninsts = 0;
  for (uint32_t i = 0; i < c->ast->nodes.len; i++) {
    const Node *const node = ast_at_const(c->ast, i);
    if (node->kind != NODE_CALL)
      continue;
    TypeId args[4];
    int n;
    const DefId fn = generic_call_target(c, i, args, &n);
    if (fn.node != NODE_NONE)
      record_inst(c, fn, args, n);
  }
}

static void fresh(Codegen *c, char *buf, const size_t cap) {
  snprintf(buf, cap, "__sc%u", c->tmp++);
}

static size_t buf_append(char *out, const size_t cap, size_t at, const char *text) {
  const size_t n = strlen(text);
  if (at < cap) {
    const size_t room = cap - at - 1;
    const size_t copied = n < room ? n : room;
    memcpy(out + at, text, copied);
    out[at + copied] = '\0';
  }
  return at + n;
}

static size_t buf_append_bytes(char *out, const size_t cap, size_t at, const char *text, const size_t n) {
  if (at < cap) {
    const size_t room = cap - at - 1;
    const size_t copied = n < room ? n : room;
    memcpy(out + at, text, copied);
    out[at + copied] = '\0';
  }
  return at + n;
}

static void buf_join3(
    char *out, const size_t cap, const char *first, const char *second, const char *third) {
  size_t at = 0;
  if (cap)
    out[0] = '\0';
  at = buf_append(out, cap, at, first);
  at = buf_append(out, cap, at, second);
  buf_append(out, cap, at, third);
}

static void emit_cstr(Codegen *c, const char *text) {
  emit_bytes(c, text, strlen(text));
}

// Emit a keyword-mangled identifier named by `name_node` (an identifier node in module `m`).
static void emit_ident_mod(Codegen *c, const ModuleId m, const NodeId name_node) {
  char nm[160];
  render_ident_src(cg_mod_src(c, m), ast_at_const(cg_mod_ast(c, m), name_node)->as.name.text, nm, sizeof nm);
  emit_cstr(c, nm);
}

// Emit the mangled C name (`<mod>__Name`) of a struct/enum declared in the current module.
static void emit_local_type_name(Codegen *c, const NodeId aggregate_name) {
  char nm[160];
  render_qualified(c, c->ast->module, aggregate_name, nm, sizeof nm);
  emit_cstr(c, nm);
}

// Find the enum declaration that owns `variant` (to spell its `Enum_Variant` tag constant).
// Index every enum variant to its enclosing enum, once, so enclosing_enum is a hash lookup.
static void build_enum_index(Codegen *c) {
  const NodeList items = ast_at_const(c->ast, c->ast->root)->as.program.items;
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const it = ast_at_const(c->ast, ids[i]);
    if (it->kind != NODE_ENUM)
      continue;
    const NodeList ms = it->as.aggregate.members;
    const NodeId *const mids = ast_list(c->ast, ms);
    for (uint32_t j = 0; j < ms.len; j++)
      CgEnumMap_insert(&c->enum_of_variant, mids[j], ids[i]);
  }
}

static NodeId enclosing_enum(Codegen *c, const NodeId variant) {
  NodeId e;
  return CgEnumMap_get(&c->enum_of_variant, variant, &e) ? e : NODE_NONE;
}

// Like enclosing_enum but for a variant in any module `m`. The per-module index only covers the current
// module, so a cross-module variant (e.g. matching/constructing an imported or prelude enum) is found by
// scanning the owner module's enums -- rare and only on the cross-module path.
static NodeId enclosing_enum_in(Codegen *c, const ModuleId m, const NodeId variant) {
  if (m == c->ast->module)
    return enclosing_enum(c, variant);
  const Ast *const a = cg_mod_ast(c, m);
  const NodeList items = ast_at_const(a, a->root)->as.program.items;
  const NodeId *const ids = ast_list(a, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const it = ast_at_const(a, ids[i]);
    if (it->kind != NODE_ENUM)
      continue;
    const NodeList ms = it->as.aggregate.members;
    const NodeId *const mids = ast_list(a, ms);
    for (uint32_t j = 0; j < ms.len; j++)
      if (mids[j] == variant)
        return ids[i];
  }
  return NODE_NONE;
}

// Emit the C enum constant `<mod>__<Enum>_<Variant>` (kept identical at definition and use) for an enum
// in module `m`; spans are read from `m`'s ast/source so it is correct across module boundaries.
static void emit_tag_mod(Codegen *c, const ModuleId m, const NodeId enum_decl, const NodeId variant) {
  const Ast *const a = cg_mod_ast(c, m);
  const uint8_t *const src = cg_mod_src(c, m);
  char pfx[64];
  render_modpfx(c, m, pfx, sizeof pfx);
  emit_cstr(c, pfx);
  const Span es = name_span_in(c, m, ast_at_const(a, enum_decl)->as.aggregate.name);
  emit_bytes(c, (const char *)src + es.start, es.end - es.start);
  emit(c, "_");
  const Span vs = name_span_in(c, m, ast_at_const(a, variant)->as.variant.name);
  emit_bytes(c, (const char *)src + vs.start, vs.end - vs.start);
}
static void emit_tag(Codegen *c, const NodeId enum_decl, const NodeId variant) {
  emit_tag_mod(c, c->ast->module, enum_decl, variant);
}
// Render the (keyword-mangled) variant name of a variant in module `m` -- the C payload-union member.
static void render_variant_name(Codegen *c, const ModuleId m, const NodeId variant, char *buf, const size_t cap) {
  render_ident_src(cg_mod_src(c, m), name_span_in(c, m, ast_at_const(cg_mod_ast(c, m), variant)->as.variant.name), buf, cap);
}

// Peel pointer/reference layers to the underlying aggregate (for method-call mangling).
static TypeId strip_ptr(Codegen *c, TypeId t) {
  const Ty *y = ast_type_at(c->ast, t);
  while (y->kind == TYPE_POINTER || y->kind == TYPE_REFERENCE) {
    t = y->as.elem;
    y = ast_type_at(c->ast, t);
  }
  return t;
}

// --- numeric/literal emission --------------------------------------------------------------

// Emit an integer/float literal, dropping `_` separators and rewriting radix forms C can't read:
// `0b…` → decimal, `0o…` → C octal `0…`, leading-zero decimals → stripped (else C reads octal).
static void emit_number(Codegen *c, const Span s, const TokenType tt) {
  char buf[256];
  size_t n = 0;
  for (uint32_t i = s.start; i < s.end && n < sizeof buf - 1; i++)
    if (c->source[i] != '_')
      buf[n++] = (char)c->source[i];
  buf[n] = '\0';

  if (tt == IntegerLiteral && n >= 2 && buf[0] == '0') {
    const char k = buf[1];
    if (k == 'b' || k == 'B') {
      unsigned long long v = 0;
      for (size_t i = 2; i < n; i++)
        v = (v << 1) | (unsigned long long)(buf[i] - '0');
      emit(c, "%llu", v);
      return;
    }
    if (k == 'o' || k == 'O') {
      emit(c, "0%s", buf + 2);
      return;
    }
    if (k == 'x' || k == 'X') {
      emit_cstr(c, buf);
      return;
    }
    size_t i = 0; // decimal with leading zeros: strip them so C does not read octal
    while (i + 1 < n && buf[i] == '0')
      i++;
    emit_cstr(c, buf + i);
    return;
  }
  emit_cstr(c, buf);
}

static void emit_literal(Codegen *c, const Node *n) {
  const Span s = n->as.literal.raw;
  switch (n->as.literal.token_type) {
    case True:
      emit(c, "true");
      break;
    case False:
      emit(c, "false");
      break;
    case Null:
      emit(c, "NULL");
      break;
    case CharacterLiteral:
      emit_span(c, s);
      break;
    case StringLiteral:
      // A string literal is a `str` view: `(str){ (const uint8_t *)"...", sizeof("...") - 1 }`.
      // `sizeof - 1` is the byte length (escapes already decoded by the C compiler) minus the NUL.
      emit(c, "(str){ (const uint8_t *)");
      emit_span(c, s);
      emit(c, ", sizeof(");
      emit_span(c, s);
      emit(c, ") - 1 }");
      break;
    case ByteCharacterLiteral: // b'a' -> 'a'
      if (s.end > s.start && c->source[s.start] == 'b')
        emit(c, "%.*s", (int)(s.end - s.start - 1), c->source + s.start + 1);
      else
        emit_span(c, s);
      break;
    case RawStringLiteral:
      codegen_errorf(c, s.start, s.end - s.start, "codegen: raw string literals are not yet supported");
      emit_span(c, s);
      break;
    default:
      emit_number(c, s, n->as.literal.token_type);
      break;
  }
}

// --- type rendering ------------------------------------------------------------------------

#define SEP(decl) ((decl)[0] ? " " : "")

// Render a C declaration of AST type node `tn` with declarator `decl` (the variable name, with
// While emitting a generic specialization, the concrete type bound to a type param (a NODE_GENERIC_PARAM
// at DefId{m,decl}), or TYPE_NONE if not currently substituted.
static TypeId subst_lookup(Codegen *c, const ModuleId m, const NodeId decl) {
  for (int i = 0; i < c->nsubst; i++)
    if (c->subst[i].param.module == m && c->subst[i].param.node == decl)
      return c->subst[i].concrete;
  return TYPE_NONE;
}

// any leading `*` / trailing `[]` already threaded in) into `out`.
static void render_type_node(Codegen *c, const NodeId tn, const char *decl, char *out, const size_t cap) {
  if (tn == NODE_NONE) {
    buf_join3(out, cap, "void", SEP(decl), decl);
    return;
  }
  const Node *const n = ast_at_const(c->ast, tn);
  switch (n->kind) {
    case NODE_TYPE_PATH:
    case NODE_IDENTIFIER: {
      const DefId d = ast_resolution_def(c->ast, tn);
      if (d.node != NODE_NONE) {
        const TypeId nt = ast_type(c->ast, tn); // a generic application (Vec<i32>) -> its specialized name
        if (nt != TYPE_NONE && ast_type_at(c->ast, nt)->kind == TYPE_INSTANCE) {
          render_type_id(c, nt, decl, out, cap);
          break;
        }
        const Node *const dn = ast_at_const(cg_mod_ast(c, d.module), d.node);
        if (dn->kind == NODE_STRUCT || dn->kind == NODE_ENUM) {
          char nm[160];
          render_qualified(c, d.module, dn->as.aggregate.name, nm, sizeof nm);
          buf_join3(out, cap, nm, SEP(decl), decl);
        } else if (dn->kind == NODE_TYPE_ALIAS && d.module == c->ast->module) {
          render_type_node(c, dn->as.type_alias.type, decl, out, cap); // transparent (same module)
        } else if (dn->kind == NODE_TYPE_ALIAS) {
          render_type_id(c, ast_type(c->ast, tn), decl, out, cap); // imported alias: use the resolved type
        } else if (dn->kind == NODE_GENERIC_PARAM) {
          const TypeId s = subst_lookup(c, d.module, d.node); // a type param, concrete inside a specialization
          if (s != TYPE_NONE)
            render_type_id(c, s, decl, out, cap);
          else
            buf_join3(out, cap, "void", SEP(decl), decl);
        } else {
          codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: opaque type is not yet supported");
          buf_join3(out, cap, "void", SEP(decl), decl);
        }
        break;
      }
      const Span s = n->kind == NODE_TYPE_PATH
                         ? (n->as.type_path.parts.len ? name_span(c, ast_list(c->ast, n->as.type_path.parts)[0]) : n->span)
                         : n->as.name.text;
      const int b = builtin_of(c->source, s);
      if (b >= 0)
        buf_join3(out, cap, BUILTIN_C[b], SEP(decl), decl);
      else {
        codegen_errorf(c, s.start, s.end - s.start, "codegen: unresolved type '%.*s'", (int)(s.end - s.start), c->source + s.start);
        buf_join3(out, cap, "void", SEP(decl), decl);
      }
      break;
    }
    case NODE_POINTER_TYPE:
    case NODE_REFERENCE_TYPE: {
      char inner[480];
      buf_join3(inner, sizeof inner, "*", "", decl);
      const TypeQualifier q = n->as.indirect_type.qualifier;
      // `&T` -> `const T *`, `&mut T` -> `T *`; a raw pointer is const-pointee only for `*const`.
      const bool const_pointee = n->kind == NODE_REFERENCE_TYPE ? q != TYPE_QUAL_MUT : q == TYPE_QUAL_CONST;
      if (const_pointee) {
        char base[512];
        render_type_node(c, n->as.indirect_type.type, inner, base, sizeof base);
        buf_join3(out, cap, "const ", "", base);
      } else {
        render_type_node(c, n->as.indirect_type.type, inner, out, cap);
      }
      break;
    }
    case NODE_SLICE_TYPE:
      buf_join3(out, cap, "SCslice", SEP(decl), decl);
      break;
    case NODE_ARRAY_TYPE: {
      const Span ls = ast_at_const(c->ast, n->as.array_type.length)->span;
      char inner[480];
      size_t at = 0;
      inner[0] = '\0';
      at = buf_append(inner, sizeof inner, at, decl);
      at = buf_append(inner, sizeof inner, at, "[");
      at = buf_append_bytes(inner, sizeof inner, at, (const char *)c->source + ls.start, ls.end - ls.start);
      buf_append(inner, sizeof inner, at, "]");
      render_type_node(c, n->as.array_type.element, inner, out, cap);
      break;
    }
    case NODE_FUNCTION_TYPE: {
      char params[480];
      size_t k = 0;
      params[0] = '\0';
      const NodeList ps = n->as.function_type.params;
      const NodeId *const pid = ast_list(c->ast, ps);
      for (uint32_t i = 0; i < ps.len && k < sizeof params; i++) {
        char t[256];
        render_type_node(c, pid[i], "", t, sizeof t);
        if (i)
          k = buf_append(params, sizeof params, k, ", ");
        k = buf_append(params, sizeof params, k, t);
      }
      char inner[600];
      size_t at = 0;
      inner[0] = '\0';
      at = buf_append(inner, sizeof inner, at, "(*");
      at = buf_append(inner, sizeof inner, at, decl);
      at = buf_append(inner, sizeof inner, at, ")(");
      at = buf_append(inner, sizeof inner, at, ps.len ? params : "void");
      buf_append(inner, sizeof inner, at, ")");
      const NodeList rs = n->as.function_type.returns;
      if (rs.len == 1) {
        const NodeId r0 = ast_list(c->ast, rs)[0];
        const Node *const rn = ast_at_const(c->ast, r0);
        render_type_node(c, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : r0, inner, out, cap);
      } else if (rs.len == 0) {
        buf_join3(out, cap, "void ", "", inner);
      } else {
        codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: multi-return function pointer is not yet supported");
        buf_join3(out, cap, "void ", "", inner);
      }
      break;
    }
    default:
      codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: unsupported type");
      buf_join3(out, cap, "void", SEP(decl), decl);
      break;
  }
}

// Same as render_type_node but from an interned `Ty` (used where only a TypeId is available:
// slice-element casts, match scrutinee element types). Array length is lost in the pool, so an
// array decays to a pointer here — those sites never carry array element types in practice.
static void render_type_id(Codegen *c, const TypeId t, const char *decl, char *out, const size_t cap) {
  const Ty *const ty = ast_type_at(c->ast, t);
  switch (ty->kind) {
    case TYPE_BUILTIN:
      buf_join3(out, cap, BUILTIN_C[ty->as.builtin], SEP(decl), decl);
      break;
    case TYPE_STRUCT:
    case TYPE_ENUM: {
      char nm[160];
      render_qualified(c, ty->module, ast_at_const(cg_mod_ast(c, ty->module), ty->as.decl)->as.aggregate.name, nm, sizeof nm);
      buf_join3(out, cap, nm, SEP(decl), decl);
      break;
    }
    case TYPE_POINTER:
    case TYPE_REFERENCE: {
      char inner[480];
      buf_join3(inner, sizeof inner, "*", "", decl);
      // `&T` -> `const T *`, `&mut T` -> `T *`; a raw pointer is const-pointee only for `*const`.
      const bool const_pointee = ty->kind == TYPE_REFERENCE ? ty->qualifier != TYPE_QUAL_MUT : ty->qualifier == TYPE_QUAL_CONST;
      if (const_pointee) {
        char base[512];
        render_type_id(c, ty->as.elem, inner, base, sizeof base);
        buf_join3(out, cap, "const ", "", base);
      } else {
        render_type_id(c, ty->as.elem, inner, out, cap);
      }
      break;
    }
    case TYPE_SLICE:
      buf_join3(out, cap, "SCslice", SEP(decl), decl);
      break;
    case TYPE_ARRAY: {
      char inner[480];
      buf_join3(inner, sizeof inner, "*", "", decl);
      render_type_id(c, ty->as.elem, inner, out, cap);
      break;
    }
    case TYPE_GENERIC: {
      const TypeId s = subst_lookup(c, ty->module, ty->as.decl); // concrete inside a specialization
      if (s != TYPE_NONE)
        render_type_id(c, s, decl, out, cap);
      else
        buf_join3(out, cap, "void", SEP(decl), decl);
      break;
    }
    case TYPE_INSTANCE: { // a generic struct/enum applied -> its specialized C type name (e.g. Box__i32)
      char nm[200];
      inst_name(c, ast_instance(c->ast, ty->as.inst), nm, sizeof nm);
      buf_join3(out, cap, nm, SEP(decl), decl);
      break;
    }
    default:
      buf_join3(out, cap, "void", SEP(decl), decl);
      break;
  }
}

// Render the declaration of `name` (already keyword-mangled) with interned type `t`, const per
// `is_const`. Value/slice/array types take conventional west-const (`const T name`); pointers and
// references take east-const (`T *const name`), since west-const would const the pointee instead
// of the binding.
static void render_binding_id(Codegen *c, const TypeId t, const char *name, const bool is_const, char *out, const size_t cap) {
  const TypeKind k = ast_type_at(c->ast, t)->kind;
  if (is_const && (k == TYPE_POINTER || k == TYPE_REFERENCE)) {
    char nm[200];
    buf_join3(nm, sizeof nm, "const ", "", name);
    render_type_id(c, t, nm, out, cap);
  } else if (is_const) {
    char body[256];
    render_type_id(c, t, name, body, sizeof body);
    buf_join3(out, cap, "const ", "", body);
  } else {
    render_type_id(c, t, name, out, cap);
  }
}

// Same west/east const placement, but from an AST type node (preserves array lengths). Pointer,
// reference and function-pointer outer types take east-const; everything else west.
static void render_binding_node(Codegen *c, const NodeId tn, const char *name, const bool is_const, char *out, const size_t cap) {
  const NodeKind k = tn != NODE_NONE ? ast_at_const(c->ast, tn)->kind : NODE_NONE_KIND;
  if (is_const && (k == NODE_POINTER_TYPE || k == NODE_REFERENCE_TYPE || k == NODE_FUNCTION_TYPE)) {
    char nm[200];
    buf_join3(nm, sizeof nm, "const ", "", name);
    render_type_node(c, tn, nm, out, cap);
  } else if (is_const) {
    char body[256];
    render_type_node(c, tn, name, body, sizeof body);
    buf_join3(out, cap, "const ", "", body);
  } else {
    render_type_node(c, tn, name, out, cap);
  }
}

// Emit the declaration head for an inferred binding of name `name` and checker-computed type `t`,
// const-qualified unless mutable. Functions (decay to a pointer), generics and poison
// (multi-return calls, deferred `str`) have no faithful C declarator from the TypeId alone, so
// those defer to `__auto_type`; every other type is written concretely.
static void emit_binding(Codegen *c, const TypeId t, const Span name, const bool is_const) {
  const TypeKind k = ast_type_at(c->ast, t)->kind;
  if (k == TYPE_ERROR || k == TYPE_FUNCTION || k == TYPE_GENERIC) {
    emit(c, is_const ? "const __auto_type " : "__auto_type ");
    emit_ident(c, name);
    return;
  }
  char nm[128], decl[300];
  render_ident(c, name, nm, sizeof nm);
  render_binding_id(c, t, nm, is_const, decl, sizeof decl);
  emit_cstr(c, decl);
}

// Does `t` (a TypeId in module `m`'s pool) carry a writable (`*mut`) address -- directly, or through a
// struct field or array/slice element? Such a value owns mutable state, so a `let` binding of it must NOT
// be const-qualified in C: `const` would lock the owned pointer and reject the value's `&mut self` methods
// (e.g. `deinit`). Stops at the first pointer/reference. A struct field may live in another module (e.g.
// the prelude's `String`), so its decl/members/field-types are read from THAT module, not the current one.
static bool type_owns_mut_in(Codegen *c, const ModuleId m, const TypeId t) {
  const Ty *const ty = ast_type_at(cg_mod_ast(c, m), t);
  switch (ty->kind) {
    case TYPE_POINTER:
    case TYPE_REFERENCE:
      return ty->qualifier == TYPE_QUAL_MUT;
    case TYPE_ARRAY:
    case TYPE_SLICE:
      return type_owns_mut_in(c, m, ty->as.elem);
    case TYPE_STRUCT: {
      const ModuleId sm = ty->module; // the struct's owning module
      Ast *const sa = cg_mod_ast(c, sm);
      const NodeList members = ast_at_const(sa, ty->as.decl)->as.aggregate.members;
      const NodeId *const ids = ast_list(sa, members);
      for (uint32_t i = 0; i < members.len; i++) {
        const Node *const mn = ast_at_const(sa, ids[i]);
        if (mn->kind == NODE_FIELD && type_owns_mut_in(c, sm, ast_type(sa, mn->as.field.type)))
          return true;
      }
      return false;
    }
    default:
      return false;
  }
}

static bool type_owns_mut(Codegen *c, const TypeId t) {
  return type_owns_mut_in(c, c->ast->module, t);
}

// --- operators -----------------------------------------------------------------------------

static const char *c_op(const TokenType t) {
  switch (t) {
    case Plus: return "+";
    case Minus: return "-";
    case Star: return "*";
    case Slash: return "/";
    case Percent: return "%";
    case Ampersand: return "&";
    case Pipe: return "|";
    case Caret: return "^";
    case LeftShift: return "<<";
    case RightShift: return ">>";
    case AmpersandAmpersand: return "&&";
    case PipePipe: return "||";
    case EqualEqual: return "==";
    case BangEqual: return "!=";
    case LessThan: return "<";
    case LessThanEqual: return "<=";
    case GreaterThan: return ">";
    case GreaterThanEqual: return ">=";
    case Equal: return "=";
    case PlusEqual: return "+=";
    case MinusEqual: return "-=";
    case StarEqual: return "*=";
    case SlashEqual: return "/=";
    case PercentEqual: return "%=";
    case Bang: return "!";
    case Tilde: return "~";
    default: return "?";
  }
}

// --- expressions ---------------------------------------------------------------------------

// Emit `prefix` (`&` / `*`) then the operand, parenthesizing only when it is not already a
// primary, so simple receivers come out as `&p` rather than `&(p)`.
static void emit_prefixed(Codegen *c, const NodeId obj, const char *prefix) {
  const NodeKind k = ast_at_const(c->ast, obj)->kind;
  const bool primary = k == NODE_IDENTIFIER || k == NODE_MEMBER || k == NODE_INDEX || k == NODE_CALL;
  emit_cstr(c, prefix);
  if (primary)
    emit_expr(c, obj);
  else {
    emit(c, "(");
    emit_expr(c, obj);
    emit(c, ")");
  }
}

// Emit an `Enum::Variant` value. A payload-less enum lowers to its plain C tag constant; a unit
// variant of a tagged (payload-bearing) enum is a struct literal with only its tag set.
// Spell the C type name of variant `v`'s enum: a generic instance (`enum_ty` a TYPE_INSTANCE) -> its
// specialized name (`Opt__i32`); otherwise the plain qualified enum name.
static void render_enum_cname(Codegen *c, const DefId v, const NodeId en, const TypeId enum_ty, char *buf, const size_t cap) {
  if (enum_ty != TYPE_NONE && ast_type_at(c->ast, enum_ty)->kind == TYPE_INSTANCE)
    inst_name(c, ast_instance(c->ast, ast_type_at(c->ast, enum_ty)->as.inst), buf, cap);
  else
    render_qualified(c, v.module, ast_at_const(cg_mod_ast(c, v.module), en)->as.aggregate.name, buf, cap);
}

static void emit_variant_value(Codegen *c, const DefId v, const TypeId enum_ty) {
  const NodeId en = enclosing_enum_in(c, v.module, v.node);
  if (en == NODE_NONE) {
    emit(c, "0");
    return;
  }
  if (!aggregate_has_payload_in(c, v.module, ast_at_const(cg_mod_ast(c, v.module), en))) {
    emit_tag_mod(c, v.module, en, v.node);
    return;
  }
  char enm[200];
  render_enum_cname(c, v, en, enum_ty, enm, sizeof enm);
  emit(c, "(%s){ .tag = ", enm);
  emit_tag_mod(c, v.module, en, v.node);
  emit(c, " }");
}

// Emit `Enum::Variant(args)` construction as a tagged-union compound literal.
static void emit_variant_construct(Codegen *c, const DefId v, const NodeList args, const NodeId *const aids,
                                   const TypeId enum_ty) {
  const NodeId en = enclosing_enum_in(c, v.module, v.node);
  if (en == NODE_NONE || !aggregate_has_payload_in(c, v.module, ast_at_const(cg_mod_ast(c, v.module), en))) {
    emit_variant_value(c, v, enum_ty); // payload-less: ignore (absent) args, emit the tag
    return;
  }
  char enm[200], vn[128];
  render_enum_cname(c, v, en, enum_ty, enm, sizeof enm);
  render_variant_name(c, v.module, v.node, vn, sizeof vn);
  emit(c, "(%s){ .tag = ", enm);
  emit_tag_mod(c, v.module, en, v.node);
  if (args.len) {
    emit(c, ", .payload.%s = { ", vn);
    for (uint32_t i = 0; i < args.len; i++) {
      if (i)
        emit(c, ", ");
      emit_expr(c, aids[i]);
    }
    emit(c, " }");
  }
  emit(c, " }");
}

static void emit_call(Codegen *c, const NodeId id, const Node *n) {
  const NodeId callee_id = n->as.call.callee;
  const Node *const callee = ast_at_const(c->ast, callee_id);
  const NodeList args = n->as.call.args;
  const NodeId *const aids = ast_list(c->ast, args);

  { // a call to a generic function (turbofish or inferred) -> the monomorphized specialization
    TypeId ga[4];
    int gn;
    const DefId g = generic_call_target(c, id, ga, &gn);
    if (g.node != NODE_NONE) {
      char nm[256];
      spec_name(c, g, ga, gn, nm, sizeof nm);
      emit_cstr(c, nm);
      emit(c, "(");
      for (uint32_t i = 0; i < args.len; i++) {
        if (i)
          emit(c, ", ");
        emit_expr(c, aids[i]);
      }
      emit(c, ")");
      return;
    }
  }

  if (callee->kind == NODE_MEMBER && callee->as.member.path) { // Enum::Variant(args) or Type::method(args)
    const DefId md = ast_resolution_def(c->ast, callee->as.member.member);
    if (md.node != NODE_NONE && ast_at_const(cg_mod_ast(c, md.module), md.node)->kind == NODE_VARIANT) {
      emit_variant_construct(c, md, args, aids, ast_type(c->ast, id));
      return;
    }
    if (md.node != NODE_NONE && ast_at_const(cg_mod_ast(c, md.module), md.node)->kind == NODE_FUNCTION) {
      const DefId td = ast_resolution_def(c->ast, callee->as.member.object); // the Target type (none = module fn)
      char pfx[64];
      render_modpfx(c, md.module, pfx, sizeof pfx);
      emit_cstr(c, pfx);
      if (td.node != NODE_NONE) { // `Type::method` -> `Target__method`; a `module::func` has no target type
        emit_ident_mod(c, td.module, ast_at_const(cg_mod_ast(c, td.module), td.node)->as.aggregate.name);
        emit(c, "__");
      }
      emit_ident_mod(c, md.module, ast_at_const(cg_mod_ast(c, md.module), md.node)->as.function.name);
      emit(c, "(");
      for (uint32_t i = 0; i < args.len; i++) {
        if (i)
          emit(c, ", ");
        emit_expr(c, aids[i]);
      }
      emit(c, ")");
      return;
    }
  }

  if (callee->kind == NODE_MEMBER && !callee->as.member.path) {
    const DefId md = ast_resolution_def(c->ast, callee->as.member.member);
    Ast *const ma = cg_mod_ast(c, md.module);
    if (md.node != NODE_NONE && ast_at_const(ma, md.node)->kind == NODE_FUNCTION) {
      const NodeId obj = callee->as.member.object;
      const TypeId obj_t = ast_type(c->ast, obj);
      const Ty *const base = ast_type_at(c->ast, strip_ptr(c, obj_t));
      if (base->kind == TYPE_STRUCT || base->kind == TYPE_ENUM) {
        char pfx[64];
        render_modpfx(c, md.module, pfx, sizeof pfx); // method's module: a local extension is mangled by it
        emit_cstr(c, pfx);
        emit_ident_mod(c, base->module, ast_at_const(cg_mod_ast(c, base->module), base->as.decl)->as.aggregate.name);
        emit(c, "__");
      } else {
        codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: method receiver is not a struct or enum");
      }
      emit_ident_mod(c, md.module, ast_at_const(ma, md.node)->as.function.name);
      emit(c, "(");

      const NodeList params = ast_at_const(ma, md.node)->as.function.params;
      bool wrote = false;
      if (params.len > 0) { // bind the receiver to the implicit self parameter
        // self-by-pointer is decided from the self parameter's own type node (in the method's module),
        // so it needs no interned type for a foreign decl.
        const NodeId self_type = ast_at_const(ma, ast_list(ma, params)[0])->as.parameter.type;
        const NodeKind sk = self_type != NODE_NONE ? ast_at_const(ma, self_type)->kind : NODE_NONE_KIND;
        const bool self_ptr = sk == NODE_POINTER_TYPE || sk == NODE_REFERENCE_TYPE;
        const Ty *const ot = ast_type_at(c->ast, obj_t);
        const bool obj_ptr = ot->kind == TYPE_POINTER || ot->kind == TYPE_REFERENCE;
        if (self_ptr && !obj_ptr)
          emit_prefixed(c, obj, "&");
        else if (!self_ptr && obj_ptr)
          emit_prefixed(c, obj, "*");
        else
          emit_expr(c, obj);
        wrote = true;
      }
      for (uint32_t i = 0; i < args.len; i++) {
        if (wrote || i)
          emit(c, ", ");
        emit_expr(c, aids[i]);
      }
      emit(c, ")");
      return;
    }
  }

  emit_expr(c, callee_id);
  emit(c, "(");
  for (uint32_t i = 0; i < args.len; i++) {
    if (i)
      emit(c, ", ");
    emit_expr(c, aids[i]);
  }
  emit(c, ")");
}

static void emit_struct_init(Codegen *c, const Node *n) {
  char t[256];
  render_type_node(c, n->as.struct_initializer.type, "", t, sizeof t);
  const NodeList fields = n->as.struct_initializer.fields;
  const NodeId *const ids = ast_list(c->ast, fields);
  if (fields.len == 0) {
    emit(c, "(%s){0}", t);
    return;
  }
  emit(c, "(%s){ ", t);
  for (uint32_t i = 0; i < fields.len; i++) {
    const Node *const fi = ast_at_const(c->ast, ids[i]);
    if (i)
      emit(c, ", ");
    emit(c, ".");
    emit_ident(c, name_span(c, fi->as.field_initializer.name));
    emit(c, " = ");
    emit_expr(c, fi->as.field_initializer.value);
  }
  emit(c, " }");
}

static void emit_new(Codegen *c, const Node *n) {
  char t[256];
  render_type_node(c, n->as.new_expr.type, "", t, sizeof t);
  if (n->as.new_expr.initializer == NODE_NONE) {
    emit(c, "((%s*)malloc(sizeof(%s)))", t, t);
    return;
  }
  char tmp[32];
  fresh(c, tmp, sizeof tmp);
  emit(c, "({ %s *%s = malloc(sizeof(%s)); *%s = ", t, tmp, t, tmp);
  emit_expr(c, n->as.new_expr.initializer);
  emit(c, "; %s; })", tmp);
}

// A match used as a value: wrap the if/else chain in a GNU statement-expression yielding `res`.
static void emit_match_expr(Codegen *c, const NodeId id) {
  const TypeId rt = ast_type(c->ast, id);
  char res[32];
  fresh(c, res, sizeof res);
  char decl[256];
  if (rt != TYPE_NONE)
    render_type_id(c, rt, res, decl, sizeof decl);
  else
    buf_join3(decl, sizeof decl, "int ", "", res);
  emit(c, "({\n");
  c->depth++;
  emit_indent(c);
  emit_cstr(c, decl);
  emit(c, ";\n");
  emit_match_core(c, id, 1, res);
  emit_indent(c);
  emit_cstr(c, res);
  emit(c, ";\n");
  c->depth--;
  emit_indent(c);
  emit(c, "})");
}

// Whether `node` is a top-level item of module `m` (vs a block-scoped local). Top-level consts are
// module-mangled like functions; locals keep their bare name. Only consulted when mangling is active.
static bool decl_is_toplevel(Codegen *c, const ModuleId m, const NodeId node) {
  const Ast *const a = cg_mod_ast(c, m);
  const NodeList items = ast_at_const(a, a->root)->as.program.items;
  const NodeId *const ids = ast_list(a, items);
  for (uint32_t i = 0; i < items.len; i++)
    if (ids[i] == node)
      return true;
  return false;
}

static void emit_ident_ref(Codegen *c, const NodeId id, const Node *n) {
  const DefId d = ast_resolution_def(c->ast, id);
  if (d.node != NODE_NONE) {
    Ast *const da = cg_mod_ast(c, d.module);
    const Node *const dn = ast_at_const(da, d.node);
    if (dn->kind == NODE_VARIANT) { // a bare (glob/prelude) payload-less variant -> its tag constant
      const NodeId en = enclosing_enum_in(c, d.module, d.node);
      if (en != NODE_NONE) {
        emit_tag_mod(c, d.module, en, d.node);
        return;
      }
    }
    // A bare reference to a module-level function (not extern -- those have no body -- and not `main`)
    // emits the OWNING module's mangled name, so glob / prelude / alias imports (which are pure source
    // sugar) still resolve to the real symbol exactly as a fully-qualified reference would.
    if (dn->kind == NODE_FUNCTION && dn->as.function.body != NODE_NONE &&
        !span_is(cg_mod_src(c, d.module), ast_at_const(da, dn->as.function.name)->as.name.text, "main")) {
      char nm[160];
      render_qualified(c, d.module, dn->as.function.name, nm, sizeof nm);
      emit_cstr(c, nm);
      return;
    }
    if (dn->kind == NODE_CONST && (!c->mangle || decl_is_toplevel(c, d.module, d.node))) {
      char nm[160]; // top-level const -> its mangled name (matches the mangled definition); locals stay bare
      render_qualified(c, d.module, dn->as.const_def.name, nm, sizeof nm);
      emit_cstr(c, nm);
      return;
    }
  }
  emit_ident(c, n->as.name.text);
}

// `{ e0, e1, .., e(n-1) }` — the element list of an array literal, no type prefix.
static void emit_array_braces(Codegen *c, const Node *n) {
  const NodeList elements = n->as.array_literal.elements;
  const NodeId *const ids = ast_list(c->ast, elements);
  emit(c, "{ ");
  for (uint32_t i = 0; i < elements.len; i++) {
    if (i)
      emit(c, ", ");
    emit_expr(c, ids[i]);
  }
  emit(c, " }");
}

static void emit_expr(Codegen *c, const NodeId id) {
  if (id == NODE_NONE)
    return;
  const Node *const n = ast_at_const(c->ast, id);
  switch (n->kind) {
    case NODE_LITERAL:
      emit_literal(c, n);
      break;
    case NODE_IDENTIFIER:
      emit_ident_ref(c, id, n);
      break;
    case NODE_UNARY: {
      const TokenType op = n->as.unary.op;
      if (op == Move || op == Unsafe) {
        emit_expr(c, n->as.unary.operand); // ownership/unsafe markers vanish
      } else {
        emit(c, "(%s", c_op(op));
        emit_expr(c, n->as.unary.operand);
        emit(c, ")");
      }
      break;
    }
    case NODE_BINARY:
      emit(c, "(");
      emit_expr(c, n->as.binary.left);
      emit(c, " %s ", c_op(n->as.binary.op));
      emit_expr(c, n->as.binary.right);
      emit(c, ")");
      break;
    case NODE_ASSIGNMENT:
      emit_expr(c, n->as.binary.left);
      emit(c, " %s ", c_op(n->as.binary.op));
      emit_expr(c, n->as.binary.right);
      break;
    case NODE_CALL:
      emit_call(c, id, n);
      break;
    case NODE_INDEX: {
      const Ty *const ot = ast_type_at(c->ast, ast_type(c->ast, n->as.index.object));
      if (ot->kind == TYPE_SLICE) {
        char et[256];
        render_type_id(c, ot->as.elem, "", et, sizeof et);
        emit(c, "((%s*)", et);
        emit_expr(c, n->as.index.object);
        emit(c, ".ptr)[");
        emit_expr(c, n->as.index.index);
        emit(c, "]");
      } else {
        emit_expr(c, n->as.index.object);
        emit(c, "[");
        emit_expr(c, n->as.index.index);
        emit(c, "]");
      }
      break;
    }
    case NODE_MEMBER: {
      if (n->as.member.path) { // a `::` path value: Enum::Variant, or a qualified const / function ref
        DefId d = ast_resolution_def(c->ast, id); // multi-segment module paths record on the outer node
        if (d.node == NODE_NONE)
          d = ast_resolution_def(c->ast, n->as.member.member); // local Type::Variant records on the member
        const Node *const dn = d.node != NODE_NONE ? ast_at_const(cg_mod_ast(c, d.module), d.node) : NULL;
        if (dn && dn->kind == NODE_CONST) {
          char nm[160];
          render_qualified(c, d.module, dn->as.const_def.name, nm, sizeof nm);
          emit_cstr(c, nm);
        } else if (dn && dn->kind == NODE_FUNCTION) {
          char nm[160];
          render_qualified(c, d.module, dn->as.function.name, nm, sizeof nm);
          emit_cstr(c, nm);
        } else {
          emit_variant_value(c, d, ast_type(c->ast, id)); // Enum::Variant (or unresolved -> 0)
        }
        break;
      }
      const Ty *const ot = ast_type_at(c->ast, ast_type(c->ast, n->as.member.object));
      const bool ptr = ot->kind == TYPE_POINTER || ot->kind == TYPE_REFERENCE;
      emit_expr(c, n->as.member.object);
      emit(c, ptr ? "->" : ".");
      emit_ident(c, name_span(c, n->as.member.member));
      break;
    }
    case NODE_CAST: {
      char t[256];
      render_type_node(c, n->as.cast.type, "", t, sizeof t);
      emit(c, "((%s)", t);
      emit_expr(c, n->as.cast.expression);
      emit(c, ")");
      break;
    }
    case NODE_GENERIC_SPECIALIZATION:
      emit_expr(c, n->as.specialization.expression); // type args erased
      break;
    case NODE_STRUCT_INITIALIZER:
      emit_struct_init(c, n);
      break;
    case NODE_NEW:
      emit_new(c, n);
      break;
    case NODE_ARRAY_LITERAL: {
      // `[e0, .., e(n-1)]` in a general value position (arg/field) -> a C compound literal
      // `(T[N]){ .. }`; N is the element count, T the interned element type. A let/const initializer
      // emits the brace list alone (see emit_stmt), since `const T a[N]` can't take a compound literal.
      const TypeId at = ast_type(c->ast, id);
      char et[256];
      if (at != TYPE_NONE)
        render_type_id(c, ast_type_at(c->ast, at)->as.elem, "", et, sizeof et);
      else
        snprintf(et, sizeof et, "int");
      emit(c, "(%s[%u])", et, n->as.array_literal.elements.len);
      emit_array_braces(c, n);
      break;
    }
    case NODE_MATCH:
      emit_match_expr(c, id);
      break;
    case NODE_IF:
      emit_if_expr(c, id);
      break;
    case NODE_BLOCK:
      emit(c, "(");
      emit(c, "{\n");
      c->depth++;
      {
        const NodeList stmts = n->as.block.statements;
        const NodeId *const ids = ast_list(c->ast, stmts);
        for (uint32_t i = 0; i < stmts.len; i++) {
          emit_indent(c);
          emit_stmt(c, ids[i]);
        }
      }
      c->depth--;
      emit_indent(c);
      emit(c, "})");
      break;
    default:
      codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: unsupported expression");
      break;
  }
}

// --- match lowering ------------------------------------------------------------------------

static bool pat_trivial(const NodeKind k) {
  return k == NODE_PATTERN_WILDCARD || k == NODE_PATTERN_NAME || k == NODE_IDENTIFIER;
}

static void emit_pattern_test(Codegen *c, const NodeId pid, const char *scrut) {
  const Node *const p = ast_at_const(c->ast, pid);
  switch (p->kind) {
    case NODE_PATTERN_NAME: {
      // A name bound to a unit variant (by the type checker) is a tag test; otherwise it is a
      // catch-all binding that matches anything. The variant may live in another module.
      const DefId vd = ast_resolution_def(c->ast, p->as.pattern.name);
      if (vd.node != NODE_NONE && ast_at_const(cg_mod_ast(c, vd.module), vd.node)->kind == NODE_VARIANT) {
        const NodeId en = enclosing_enum_in(c, vd.module, vd.node);
        const bool payload = en != NODE_NONE && aggregate_has_payload_in(c, vd.module, ast_at_const(cg_mod_ast(c, vd.module), en));
        emit(c, payload ? "%s.tag == " : "%s == ", scrut);
        if (en != NODE_NONE)
          emit_tag_mod(c, vd.module, en, vd.node);
        else
          emit(c, "0");
      } else {
        emit(c, "1");
      }
      break;
    }
    case NODE_PATTERN_WILDCARD:
    case NODE_IDENTIFIER:
      emit(c, "1");
      break;
    case NODE_PATTERN_LITERAL:
      emit(c, "%s == ", scrut);
      emit_expr(c, p->as.single.value);
      break;
    case NODE_PATTERN_RANGE: {
      const NodeId lo = p->as.pattern_range.start; // either bound may be absent (half-open range)
      const NodeId hi = p->as.pattern_range.end;
      if (lo != NODE_NONE) {
        const Node *const lon = ast_at_const(c->ast, lo);
        emit(c, "%s >= ", scrut);
        emit_expr(c, lon->kind == NODE_PATTERN_LITERAL ? lon->as.single.value : lo);
      }
      if (hi != NODE_NONE) {
        const Node *const hin = ast_at_const(c->ast, hi);
        emit(c, "%s%s %s ", lo != NODE_NONE ? " && " : "", scrut, p->as.pattern_range.inclusive ? "<=" : "<");
        emit_expr(c, hin->kind == NODE_PATTERN_LITERAL ? hin->as.single.value : hi);
      }
      break;
    }
    case NODE_PATTERN_TUPLE: {
      const DefId vd = p->as.pattern.name != NODE_NONE ? ast_resolution_def(c->ast, p->as.pattern.name)
                                                       : (DefId){0, NODE_NONE};
      const NodeList ch = p->as.pattern.children;
      const NodeId *const ids = ast_list(c->ast, ch);
      if (vd.node != NODE_NONE && ast_at_const(cg_mod_ast(c, vd.module), vd.node)->kind == NODE_VARIANT) {
        const NodeId en = enclosing_enum_in(c, vd.module, vd.node);
        // A payload-bearing enum is a tagged union (test `.tag`); a payload-less one is a plain
        // C enum whose value is the tag itself.
        const bool payload = en != NODE_NONE && aggregate_has_payload_in(c, vd.module, ast_at_const(cg_mod_ast(c, vd.module), en));
        emit(c, payload ? "%s.tag == " : "%s == ", scrut);
        if (en != NODE_NONE)
          emit_tag_mod(c, vd.module, en, vd.node);
        else
          emit(c, "0");
        char vn[128];
        render_variant_name(c, vd.module, vd.node, vn, sizeof vn);
        for (uint32_t i = 0; i < ch.len; i++) {
          if (pat_trivial(ast_at_const(c->ast, ids[i])->kind))
            continue;
          char sub[256];
          snprintf(sub, sizeof sub, "%s.payload.%s._%u", scrut, vn, i);
          emit(c, " && ");
          emit_pattern_test(c, ids[i], sub);
        }
      } else if (ch.len == 1) { // parenthesized group pattern
        emit_pattern_test(c, ids[0], scrut);
      } else {
        emit(c, "1");
      }
      break;
    }
    case NODE_PATTERN_STRUCT: {
      const NodeList ch = p->as.pattern.children;
      const NodeId *const ids = ast_list(c->ast, ch);
      bool wrote = false;
      for (uint32_t i = 0; i < ch.len; i++) {
        const Node *const f = ast_at_const(c->ast, ids[i]);
        const NodeList sub = f->as.pattern.children;
        const NodeId subpat = sub.len ? ast_list(c->ast, sub)[0] : NODE_NONE;
        if (subpat == NODE_NONE || pat_trivial(ast_at_const(c->ast, subpat)->kind))
          continue;
        char m[128];
        render_ident(c, name_span(c, f->as.pattern.name), m, sizeof m);
        char acc[256];
        snprintf(acc, sizeof acc, "%s.%s", scrut, m);
        emit(c, wrote ? " && " : "");
        emit_pattern_test(c, subpat, acc);
        wrote = true;
      }
      if (!wrote)
        emit(c, "1");
      break;
    }
    default:
      emit(c, "1");
      break;
  }
}

static void emit_pattern_binds(Codegen *c, const NodeId pid, const char *scrut) {
  const Node *const p = ast_at_const(c->ast, pid);
  switch (p->kind) {
    case NODE_PATTERN_NAME: {
      const DefId vd = ast_resolution_def(c->ast, p->as.pattern.name);
      if (vd.node != NODE_NONE && ast_at_const(cg_mod_ast(c, vd.module), vd.node)->kind == NODE_VARIANT)
        break; // a unit-variant tag pattern binds nothing
      emit_indent(c);
      emit_binding(c, ast_type(c->ast, pid), name_span(c, p->as.pattern.name), true);
      emit(c, " = %s;\n", scrut);
      break;
    }
    case NODE_IDENTIFIER:
      emit_indent(c);
      emit_binding(c, ast_type(c->ast, pid), p->as.name.text, true);
      emit(c, " = %s;\n", scrut);
      break;
    case NODE_PATTERN_TUPLE: {
      const DefId vd = p->as.pattern.name != NODE_NONE ? ast_resolution_def(c->ast, p->as.pattern.name)
                                                       : (DefId){0, NODE_NONE};
      const NodeList ch = p->as.pattern.children;
      const NodeId *const ids = ast_list(c->ast, ch);
      char vn[128] = "";
      if (vd.node != NODE_NONE && ast_at_const(cg_mod_ast(c, vd.module), vd.node)->kind == NODE_VARIANT)
        render_variant_name(c, vd.module, vd.node, vn, sizeof vn);
      for (uint32_t i = 0; i < ch.len; i++) {
        char sub[256];
        if (vn[0])
          snprintf(sub, sizeof sub, "%s.payload.%s._%u", scrut, vn, i);
        else
          snprintf(sub, sizeof sub, "%s", scrut);
        emit_pattern_binds(c, ids[i], sub);
      }
      break;
    }
    case NODE_PATTERN_STRUCT: {
      const NodeList ch = p->as.pattern.children;
      const NodeId *const ids = ast_list(c->ast, ch);
      for (uint32_t i = 0; i < ch.len; i++) {
        const Node *const f = ast_at_const(c->ast, ids[i]);
        char m[128];
        render_ident(c, name_span(c, f->as.pattern.name), m, sizeof m);
        char acc[256];
        snprintf(acc, sizeof acc, "%s.%s", scrut, m);
        const NodeList sub = f->as.pattern.children;
        if (sub.len)
          emit_pattern_binds(c, ast_list(c->ast, sub)[0], acc);
      }
      break;
    }
    default:
      break; // wildcard / literal / range bind nothing
  }
}

// Emit `__auto_type scrut = <value>;` then an if/else-if chain over the arms. mode: 0 statement,
// 1 assign each body to `result`, 2 `return` each body.
static void emit_match_core(Codegen *c, const NodeId id, const int mode, const char *result) {
  const Node *const n = ast_at_const(c->ast, id);
  char scrut[32];
  fresh(c, scrut, sizeof scrut);
  // Bind the scrutinee to a value temp, dereferencing through any pointer/reference layers so
  // patterns can use `.tag` / `.field` (the type checker matched against the stripped type).
  unsigned derefs = 0;
  TypeId base = ast_type(c->ast, n->as.match_expr.value);
  for (const Ty *y = ast_type_at(c->ast, base); y->kind == TYPE_POINTER || y->kind == TYPE_REFERENCE;
       y = ast_type_at(c->ast, base))
    base = y->as.elem, derefs++;
  emit_indent(c);
  const TypeKind bk = ast_type_at(c->ast, base)->kind;
  if (bk == TYPE_ERROR || bk == TYPE_FUNCTION || bk == TYPE_GENERIC) {
    emit(c, "const __auto_type %s = ", scrut); // scrutinee temp is only read
  } else {
    char d[300];
    render_binding_id(c, base, scrut, true, d, sizeof d);
    emit_cstr(c, d);
    emit(c, " = ");
  }
  for (unsigned i = 0; i < derefs; i++)
    emit(c, "(*");
  emit_expr(c, n->as.match_expr.value);
  for (unsigned i = 0; i < derefs; i++)
    emit(c, ")");
  emit(c, ";\n");

  const NodeList arms = n->as.match_expr.arms;
  const NodeId *const ids = ast_list(c->ast, arms);
  for (uint32_t i = 0; i < arms.len; i++) {
    const Node *const arm = ast_at_const(c->ast, ids[i]);
    emit_indent(c);
    emit(c, i ? "else if (" : "if (");
    emit_pattern_test(c, arm->as.match_arm.pattern, scrut);
    if (arm->as.match_arm.guard != NODE_NONE) {
      emit(c, " && ");
      emit_condition(c, arm->as.match_arm.guard);
    }
    emit(c, ") {\n");
    c->depth++;
    emit_pattern_binds(c, arm->as.match_arm.pattern, scrut);
    const NodeId body = arm->as.match_arm.body;
    if (mode == 2) {
      emit_indent(c);
      emit(c, "return ");
      emit_expr(c, body);
      emit(c, ";\n");
    } else if (mode == 1) {
      emit_indent(c);
      emit(c, "%s = ", result);
      emit_expr(c, body);
      emit(c, ";\n");
    } else if (ast_at_const(c->ast, body)->kind == NODE_BLOCK) {
      emit_indent(c);
      emit_block(c, body);
      emit(c, "\n");
    } else {
      emit_indent(c);
      emit_expr(c, body);
      emit(c, ";\n");
    }
    c->depth--;
    emit_indent(c);
    emit(c, "}\n");
  }
  // In value/return position the match must yield a value, so an unmatched fallthrough is a bug:
  // tell C the chain is exhaustive (matches the language's exhaustiveness rule) and silence
  // -Wreturn-type for the enclosing function. (A trailing `_`/binding arm makes this else dead.)
  if (mode != 0 && arms.len > 0) {
    emit_indent(c);
    emit(c, "else { __builtin_unreachable(); }\n");
  }
}

static void emit_match_stmt(Codegen *c, const NodeId id) {
  emit(c, "{\n");
  c->depth++;
  emit_match_core(c, id, 0, NULL);
  c->depth--;
  emit_indent(c);
  emit(c, "}\n");
}

// --- statements ----------------------------------------------------------------------------

static void emit_block(Codegen *c, const NodeId id) {
  const Node *const n = ast_at_const(c->ast, id);
  emit(c, "{\n");
  c->depth++;
  const NodeList stmts = n->as.block.statements;
  const NodeId *const ids = ast_list(c->ast, stmts);
  for (uint32_t i = 0; i < stmts.len; i++) {
    emit_indent(c);
    emit_stmt(c, ids[i]);
  }
  c->depth--;
  emit_indent(c);
  emit(c, "}");
}

// True when emit_expr already surrounds the expression with parentheses, so a condition context
// needn't add its own — avoiding `if ((a == b))`, which clang flags under -Wparentheses-equality.
static bool emits_own_parens(Codegen *c, const NodeId id) {
  const Node *const n = ast_at_const(c->ast, id);
  switch (n->kind) {
    case NODE_BINARY:
    case NODE_CAST:
      return true;
    case NODE_UNARY: // Move/Unsafe are transparent — look through to the operand
      return n->as.unary.op != Move && n->as.unary.op != Unsafe ? true : emits_own_parens(c, n->as.unary.operand);
    case NODE_NEW:
      return n->as.new_expr.initializer == NODE_NONE; // ((T*)malloc(...))
    default:
      return false;
  }
}

// Emit a controlling condition wrapped in exactly one pair of parentheses.
static void emit_condition(Codegen *c, const NodeId id) {
  if (emits_own_parens(c, id)) {
    emit_expr(c, id);
  } else {
    emit(c, "(");
    emit_expr(c, id);
    emit(c, ")");
  }
}

static void emit_if(Codegen *c, const Node *n) {
  emit(c, "if ");
  emit_condition(c, n->as.if_stmt.condition);
  emit(c, " ");
  emit_block(c, n->as.if_stmt.then_branch);
  if (n->as.if_stmt.else_branch != NODE_NONE) {
    const Node *const e = ast_at_const(c->ast, n->as.if_stmt.else_branch);
    emit(c, " else ");
    if (e->kind == NODE_IF)
      emit_if(c, e);
    else
      emit_block(c, n->as.if_stmt.else_branch);
  }
}

// Emit a branch block of an `if`-expression: every statement verbatim, but the tail expression
// statement assigns its value to `result` (the GNU statement-expression's yielded slot).
static void emit_block_value(Codegen *c, const NodeId id, const char *result) {
  const Node *const n = ast_at_const(c->ast, id);
  emit(c, "{\n");
  c->depth++;
  const NodeList stmts = n->as.block.statements;
  const NodeId *const ids = ast_list(c->ast, stmts);
  for (uint32_t i = 0; i < stmts.len; i++) {
    const Node *const s = ast_at_const(c->ast, ids[i]);
    emit_indent(c);
    if (i + 1 == stmts.len && s->kind == NODE_EXPRESSION_STATEMENT) {
      emit(c, "%s = ", result);
      emit_expr(c, s->as.single.value);
      emit(c, ";\n");
    } else {
      emit_stmt(c, ids[i]);
    }
  }
  c->depth--;
  emit_indent(c);
  emit(c, "}");
}

// The if/else chain of an `if`-expression, each arm assigning its tail value to `result`.
static void emit_if_value(Codegen *c, const Node *n, const char *result) {
  emit(c, "if ");
  emit_condition(c, n->as.if_stmt.condition);
  emit(c, " ");
  emit_block_value(c, n->as.if_stmt.then_branch, result);
  const NodeId e = n->as.if_stmt.else_branch; // the type checker requires an else in value position
  emit(c, " else ");
  if (ast_at_const(c->ast, e)->kind == NODE_IF)
    emit_if_value(c, ast_at_const(c->ast, e), result);
  else
    emit_block_value(c, e, result);
}

// An `if` used as a value: wrap the chain in a GNU statement-expression yielding `res`.
static void emit_if_expr(Codegen *c, const NodeId id) {
  const Node *const n = ast_at_const(c->ast, id);
  const TypeId rt = ast_type(c->ast, id);
  char res[32];
  fresh(c, res, sizeof res);
  char decl[256];
  if (rt != TYPE_NONE)
    render_type_id(c, rt, res, decl, sizeof decl);
  else
    buf_join3(decl, sizeof decl, "int ", "", res);
  emit(c, "({\n");
  c->depth++;
  emit_indent(c);
  emit_cstr(c, decl);
  emit(c, ";\n");
  emit_indent(c);
  emit_if_value(c, n, res);
  emit(c, "\n");
  emit_indent(c);
  emit_cstr(c, res);
  emit(c, ";\n");
  c->depth--;
  emit_indent(c);
  emit(c, "})");
}

// Recover an array's element count from the iterable's declared type node (an array parameter
// decays to a pointer in C, so sizeof can't be trusted). NODE_NONE if it can't be determined.
static NodeId array_length_of(Codegen *c, const NodeId iter) {
  if (ast_at_const(c->ast, iter)->kind != NODE_IDENTIFIER)
    return NODE_NONE;
  const NodeId d = ast_resolution(c->ast, iter);
  if (d == NODE_NONE)
    return NODE_NONE;
  const Node *const dn = ast_at_const(c->ast, d);
  const NodeId tn = dn->kind == NODE_PARAMETER ? dn->as.parameter.type
                    : dn->kind == NODE_LET     ? dn->as.let_stmt.type
                    : dn->kind == NODE_FIELD   ? dn->as.field.type
                                               : NODE_NONE;
  return tn != NODE_NONE && ast_at_const(c->ast, tn)->kind == NODE_ARRAY_TYPE
             ? ast_at_const(c->ast, tn)->as.array_type.length
             : NODE_NONE;
}

// `for i in lo..hi` -> a counting loop. A missing start counts from 0; a missing end runs
// unbounded (the body must `break`); `..=` includes the end.
static void emit_for_range(Codegen *c, const Node *n) {
  const Node *const r = ast_at_const(c->ast, n->as.for_stmt.iterable);
  const NodeId lo = r->as.pattern_range.start;
  const NodeId hi = r->as.pattern_range.end;
  const Span name = name_span(c, n->as.for_stmt.binding);
  char nm[128];
  render_ident(c, name, nm, sizeof nm);
  emit(c, "for (");
  emit_binding(c, ast_type(c->ast, n->as.for_stmt.iterable), name, false);
  emit(c, " = ");
  if (lo != NODE_NONE)
    emit_expr(c, lo);
  else
    emit(c, "0");
  emit(c, "; ");
  if (hi != NODE_NONE) {
    emit(c, "%s %s ", nm, r->as.pattern_range.inclusive ? "<=" : "<");
    emit_expr(c, hi);
  }
  emit(c, "; %s++) ", nm);
  emit_block(c, n->as.for_stmt.body);
  emit(c, "\n");
}

static void emit_for(Codegen *c, const Node *n) {
  if (ast_at_const(c->ast, n->as.for_stmt.iterable)->kind == NODE_RANGE) {
    emit_for_range(c, n);
    return;
  }
  const Ty *const it = ast_type_at(c->ast, ast_type(c->ast, n->as.for_stmt.iterable));
  const NodeId body = n->as.for_stmt.body;
  const NodeList stmts = ast_at_const(c->ast, body)->as.block.statements;
  const NodeId *const sids = ast_list(c->ast, stmts);
  char idx[32];
  fresh(c, idx, sizeof idx);

  if (it->kind == TYPE_ARRAY) {
    const NodeId len = array_length_of(c, n->as.for_stmt.iterable);
    emit(c, "for (size_t %s = 0; %s < ", idx, idx);
    if (len != NODE_NONE) {
      emit_expr(c, len);
    } else {
      emit(c, "sizeof(");
      emit_expr(c, n->as.for_stmt.iterable);
      emit(c, ")/sizeof((");
      emit_expr(c, n->as.for_stmt.iterable);
      emit(c, ")[0])");
    }
    emit(c, "; %s++) {\n", idx);
    c->depth++;
    emit_indent(c);
    emit_binding(c, it->as.elem, name_span(c, n->as.for_stmt.binding), true);
    emit(c, " = (");
    emit_expr(c, n->as.for_stmt.iterable);
    emit(c, ")[%s];\n", idx);
    for (uint32_t i = 0; i < stmts.len; i++) {
      emit_indent(c);
      emit_stmt(c, sids[i]);
    }
    c->depth--;
    emit_indent(c);
    emit(c, "}\n");
    return;
  }
  if (it->kind == TYPE_SLICE) {
    char et[256];
    render_type_id(c, it->as.elem, "", et, sizeof et);
    char s[32];
    fresh(c, s, sizeof s);
    emit(c, "{\n");
    c->depth++;
    emit_indent(c);
    emit(c, "SCslice %s = ", s);
    emit_expr(c, n->as.for_stmt.iterable);
    emit(c, ";\n");
    emit_indent(c);
    emit(c, "for (size_t %s = 0; %s < %s.len; %s++) {\n", idx, idx, s, idx);
    c->depth++;
    emit_indent(c);
    emit_binding(c, it->as.elem, name_span(c, n->as.for_stmt.binding), true);
    emit(c, " = ((%s*)%s.ptr)[%s];\n", et, s, idx);
    for (uint32_t i = 0; i < stmts.len; i++) {
      emit_indent(c);
      emit_stmt(c, sids[i]);
    }
    c->depth--;
    emit_indent(c);
    emit(c, "}\n");
    c->depth--;
    emit_indent(c);
    emit(c, "}\n");
    return;
  }
  codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: cannot iterate over a non-array/slice value");
}

static void emit_return(Codegen *c, const Node *n) {
  const NodeList vals = n->as.return_stmt.values;
  const NodeId *const vids = ast_list(c->ast, vals);
  if (vals.len == 0) {
    emit(c, "return;\n");
    return;
  }
  if (vals.len == 1) {
    if (ast_at_const(c->ast, vids[0])->kind == NODE_MATCH) { // return switch …
      emit(c, "{\n");
      c->depth++;
      emit_match_core(c, vids[0], 2, NULL);
      c->depth--;
      emit_indent(c);
      emit(c, "}\n");
      return;
    }
    emit(c, "return ");
    emit_expr(c, vids[0]);
    emit(c, ";\n");
    return;
  }
  emit(c, "return (%s){ ", c->current_ret);
  for (uint32_t i = 0; i < vals.len; i++) {
    if (i)
      emit(c, ", ");
    emit_expr(c, vids[i]);
  }
  emit(c, " };\n");
}

// An expression-statement: peel transparent unsafe/move wrappers, then render block/if/match as
// real statements (no stray stmt-expr or semicolon), everything else as `<expr>;`.
static void emit_expr_stmt(Codegen *c, NodeId v) {
  const Node *n = ast_at_const(c->ast, v);
  while (n->kind == NODE_UNARY && (n->as.unary.op == Move || n->as.unary.op == Unsafe)) {
    v = n->as.unary.operand;
    n = ast_at_const(c->ast, v);
  }
  if (n->kind == NODE_BLOCK) {
    emit_block(c, v);
    emit(c, "\n");
    return;
  }
  if (n->kind == NODE_IF) {
    emit_if(c, n);
    emit(c, "\n");
    return;
  }
  if (n->kind == NODE_MATCH) {
    emit_match_stmt(c, v);
    return;
  }
  emit_expr(c, v);
  emit(c, ";\n");
}

// `let (a, b, ..) = call` -> a hidden temp holding the multi-return struct, then one binding per
// element reading its `_i` field. `__auto_type` sidesteps naming the synthesized `<fn>_ret` type.
static void emit_tuple_let(Codegen *c, const Node *n) {
  char tmp[32];
  fresh(c, tmp, sizeof tmp);
  emit(c, "const __auto_type %s = ", tmp);
  emit_expr(c, n->as.let_stmt.value);
  emit(c, ";\n");
  const Node *const nm = ast_at_const(c->ast, n->as.let_stmt.name);
  const NodeList names = nm->as.pattern.children;
  const NodeId *const nids = ast_list(c->ast, names);
  for (uint32_t i = 0; i < names.len; i++) {
    emit_indent(c);
    char bn[128];
    render_ident(c, name_span(c, nids[i]), bn, sizeof bn);
    // const unless mutable or the element owns a `*mut` (see type_owns_mut).
    const bool element_const = !n->as.let_stmt.is_mutable && !type_owns_mut(c, ast_type(c->ast, nids[i]));
    emit(c, "%s__auto_type %s = %s._%u;\n", element_const ? "const " : "", bn, tmp, i);
  }
}

// A binding initializer. An array literal whose declarator is a real C array (`T name[N]`, from an
// array-type annotation) emits a brace list, since a `const`-qualified array can't take a compound
// literal; every other value (incl. an array literal bound to a decayed pointer) goes through emit_expr.
static void emit_initializer(Codegen *c, const NodeId type, const NodeId value) {
  const Node *const val = ast_at_const(c->ast, value);
  if (val->kind == NODE_ARRAY_LITERAL && type != NODE_NONE &&
      ast_at_const(c->ast, type)->kind == NODE_ARRAY_TYPE)
    emit_array_braces(c, val);
  else
    emit_expr(c, value);
}

static void emit_stmt(Codegen *c, const NodeId id) {
  if (id == NODE_NONE)
    return;
  const Node *const n = ast_at_const(c->ast, id);
  switch (n->kind) {
    case NODE_BLOCK:
      emit_block(c, id);
      emit(c, "\n");
      break;
    case NODE_LET: {
      if (ast_at_const(c->ast, n->as.let_stmt.name)->kind == NODE_PATTERN_TUPLE) {
        emit_tuple_let(c, n);
        break;
      }
      // A `let` of a type that owns a `*mut` stays non-const, so its `&mut self` methods stay callable.
      const bool is_const = !n->as.let_stmt.is_mutable && !type_owns_mut(c, ast_type(c->ast, id));
      if (n->as.let_stmt.type != NODE_NONE) {
        char nm[128], decl[300];
        render_ident(c, name_span(c, n->as.let_stmt.name), nm, sizeof nm);
        render_binding_node(c, n->as.let_stmt.type, nm, is_const, decl, sizeof decl);
        emit_cstr(c, decl);
      } else {
        emit_binding(c, ast_type(c->ast, id), name_span(c, n->as.let_stmt.name), is_const);
      }
      if (n->as.let_stmt.value != NODE_NONE) {
        emit(c, " = ");
        emit_initializer(c, n->as.let_stmt.type, n->as.let_stmt.value);
      }
      emit(c, ";\n");
      break;
    }
    case NODE_CONST: {
      char nm[128], decl[256];
      render_ident(c, name_span(c, n->as.const_def.name), nm, sizeof nm);
      render_type_node(c, n->as.const_def.type, nm, decl, sizeof decl);
      emit(c, "static const ");
      emit_cstr(c, decl);
      if (n->as.const_def.value != NODE_NONE) {
        emit(c, " = ");
        emit_initializer(c, n->as.const_def.type, n->as.const_def.value);
      }
      emit(c, ";\n");
      break;
    }
    case NODE_RETURN:
      emit_return(c, n);
      break;
    case NODE_IF:
      emit_if(c, n);
      emit(c, "\n");
      break;
    case NODE_WHILE:
      emit(c, "while ");
      emit_condition(c, n->as.while_stmt.condition);
      emit(c, " ");
      emit_block(c, n->as.while_stmt.body);
      emit(c, "\n");
      break;
    case NODE_FOR:
      emit_for(c, n);
      break;
    case NODE_BREAK:
      emit(c, "break;\n");
      break;
    case NODE_CONTINUE:
      emit(c, "continue;\n");
      break;
    case NODE_DEFER:
      codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: defer is not yet supported");
      break;
    case NODE_EXPRESSION_STATEMENT:
      emit_expr_stmt(c, n->as.single.value);
      break;
    default:
      break;
  }
}

// --- declarations --------------------------------------------------------------------------

// "void" / "T0 p0, T1 p1" — a function's C parameter list.
static void render_params(Codegen *c, const NodeList params, char *out, const size_t cap) {
  if (params.len == 0) {
    buf_join3(out, cap, "void", "", "");
    return;
  }
  const NodeId *const ids = ast_list(c->ast, params);
  size_t k = 0;
  out[0] = '\0';
  for (uint32_t i = 0; i < params.len && k < cap; i++) {
    const Node *const p = ast_at_const(c->ast, ids[i]);
    char nm[128], d[300];
    render_ident(c, name_span(c, p->as.parameter.name), nm, sizeof nm);
    render_binding_node(c, p->as.parameter.type, nm, true, d, sizeof d); // parameters are never mut
    if (i)
      k = buf_append(out, cap, k, ", ");
    k = buf_append(out, cap, k, d);
  }
}

// Build a function's C name: `<mod>__name`, or `<mod>__Target__name` for an impl method. `prefixed`
// is false for extern (FFI) functions; the program entry `main` is never prefixed either.
// `target` is the receiver type (a DefId; .node == NODE_NONE for a free function). The module prefix is
// always this (the emitting) module, so a local `extend foreign::T` method is mangled by the module that
// declares it (`extender__T__m`); the type-name segment is read from the target type's own module.
static void function_name(Codegen *c, const NodeId fn, const DefId target, char *out, const size_t cap, const bool prefixed) {
  const Span fname = name_span(c, ast_at_const(c->ast, fn)->as.function.name);
  const bool is_main = target.node == NODE_NONE && span_is(c->source, fname, "main");
  size_t k = prefixed && !is_main ? render_modpfx(c, c->ast->module, out, cap) : 0;
  if (k >= cap)
    k = cap ? cap - 1 : 0;
  if (target.node != NODE_NONE) {
    const Span ts = name_span_in(c, target.module, ast_at_const(cg_mod_ast(c, target.module), target.node)->as.aggregate.name);
    k += render_ident_src(cg_mod_src(c, target.module), ts, out + k, cap - k);
    if (k + 2 < cap) {
      out[k++] = '_';
      out[k++] = '_';
    }
  }
  render_ident(c, fname, out + k, cap - k);
}

// Emit a function signature; with_body emits the block, otherwise a prototype `;`. `extern_q`
// prefixes `extern`. Sets current_ret for multi-return so NODE_RETURN can build the struct.
static void emit_function(Codegen *c, const NodeId fn_id, const DefId target, const bool extern_q,
                          const bool with_body, const char *const name_override) {
  const Node *const fn = ast_at_const(c->ast, fn_id);
  char nm[256];
  if (name_override)
    buf_append(nm, sizeof nm, 0, name_override); // a monomorphized specialization's mangled name
  else
    function_name(c, fn_id, target, nm, sizeof nm, !extern_q);
  // In a multi-module package a non-`pub` function is module-private: emit it `static` so it never
  // gets external linkage (its prototype is kept in the .c, not the public header). `main` and FFI
  // declarations are never static. A specialization is always file-local (each module emits its own).
  const bool is_main = target.node == NODE_NONE && !name_override && span_is(c->source, name_span(c, fn->as.function.name), "main");
  const bool is_static = name_override ? c->multifile : (c->multifile && !extern_q && !is_main && !fn->as.function.is_public);
  char ps[1024];
  render_params(c, fn->as.function.params, ps, sizeof ps);
  char decl[1320];
  size_t at = 0;
  decl[0] = '\0';
  // Parenthesize the name in FFI prototypes -- `void *(memcpy)(...)`. A function-like libc macro
  // (macOS fortifies memcpy/memset/strcpy/... in <string.h>) only expands when its name is directly
  // followed by `(`, so `(memcpy)` declares the real function instead of expanding mid-declaration.
  if (extern_q)
    at = buf_append(decl, sizeof decl, at, "(");
  at = buf_append(decl, sizeof decl, at, nm);
  if (extern_q)
    at = buf_append(decl, sizeof decl, at, ")");
  at = buf_append(decl, sizeof decl, at, "(");
  at = buf_append(decl, sizeof decl, at, ps);
  buf_append(decl, sizeof decl, at, ")");

  if (extern_q)
    emit(c, "extern ");
  if (is_static)
    emit(c, "static ");

  const NodeList rets = fn->as.function.returns;
  c->current_ret[0] = '\0';
  // C requires `int main(void)`; a Super-C `fn main() i32` maps onto it (implicit 0 on fall-through).
  if (target.node == NODE_NONE && !extern_q && span_is(c->source, name_span(c, fn->as.function.name), "main")) {
    emit(c, "int %s", decl);
  } else if (rets.len > 1) {
    buf_join3(c->current_ret, sizeof c->current_ret, nm, "", "_ret");
    emit_cstr(c, c->current_ret);
    emit(c, " ");
    emit_cstr(c, decl);
  } else if (rets.len == 1) {
    const NodeId r0 = ast_list(c->ast, rets)[0];
    const Node *const rn = ast_at_const(c->ast, r0);
    char out[1400];
    render_type_node(c, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : r0, decl, out, sizeof out);
    emit_cstr(c, out);
  } else {
    emit(c, "void ");
    emit_cstr(c, decl);
  }

  if (with_body && fn->as.function.body != NODE_NONE) {
    emit(c, " ");
    emit_block(c, fn->as.function.body);
    emit(c, "\n\n");
  } else {
    emit(c, ";\n");
  }
}

// Emit each collected generic instantiation as a concrete `static` function (a copy of the generic body
// with its type params bound to the instantiation's concrete types). `with_body` false emits prototypes.
// Same-module only for now: the generic function lives in this module's ast.
static void emit_specializations(Codegen *c, const bool with_body) {
  for (int i = 0; i < c->ninsts; i++) {
    const DefId fn = c->insts[i].fn;
    if (fn.module != c->ast->module)
      continue; // cross-module generic definitions not yet specialized (per-Ast TypeId pools differ)
    bool concrete = true;
    for (uint8_t k = 0; k < c->insts[i].n; k++)
      concrete &= type_is_concrete(c, c->insts[i].args[k]);
    if (!concrete) // skip an intermediate instantiation (e.g. id::<T> called inside another generic)
      continue;
    const Node *const fnnode = ast_at_const(c->ast, fn.node);
    if (fnnode->as.function.returns.len > 1)
      continue; // multi-return generic not yet supported
    const NodeList gens = fnnode->as.function.generics;
    const NodeId *const gids = ast_list(c->ast, gens);
    c->nsubst = 0;
    for (uint32_t g = 0; g < gens.len && g < c->insts[i].n && c->nsubst < 8; g++) {
      c->subst[c->nsubst].param = (DefId){fn.module, gids[g]};
      c->subst[c->nsubst].concrete = c->insts[i].args[g];
      c->nsubst++;
    }
    char nm[256];
    spec_name(c, fn, c->insts[i].args, c->insts[i].n, nm, sizeof nm);
    emit_function(c, fn.node, (DefId){0, NODE_NONE}, false, with_body, nm);
    c->nsubst = 0;
  }
}

// Emit the `<fn>_ret` struct backing a multi-return function (fields `_0`, `_1`, …).
static void emit_ret_struct(Codegen *c, const NodeId fn_id, const DefId target) {
  const Node *const fn = ast_at_const(c->ast, fn_id);
  const NodeList rets = fn->as.function.returns;
  if (rets.len <= 1)
    return;
  char nm[256];
  function_name(c, fn_id, target, nm, sizeof nm, true);
  const NodeId *const ids = ast_list(c->ast, rets);
  emit(c, "typedef struct { ");
  for (uint32_t i = 0; i < rets.len; i++) {
    const Node *const rn = ast_at_const(c->ast, ids[i]);
    char fld[16], d[256];
    snprintf(fld, sizeof fld, "_%u", i);
    render_type_node(c, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : ids[i], fld, d, sizeof d);
    emit_cstr(c, d);
    emit(c, "; ");
  }
  emit(c, "} %s_ret;\n", nm);
}

static bool aggregate_has_payload_in(Codegen *c, const ModuleId m, const Node *enum_node) {
  const Ast *const a = cg_mod_ast(c, m);
  const NodeList members = enum_node->as.aggregate.members;
  const NodeId *const ids = ast_list(a, members);
  for (uint32_t i = 0; i < members.len; i++)
    if (ast_at_const(a, ids[i])->as.variant.payload.len > 0)
      return true;
  return false;
}
static bool aggregate_has_payload(Codegen *c, const Node *enum_node) {
  return aggregate_has_payload_in(c, c->ast->module, enum_node);
}

// Full definition of a payload-less enum, wrapped in a per-enum include guard keyed on its mangled name.
// C11 cannot forward-declare an `enum`, so when a header must name a cross-module payload-less enum but
// cannot include its owner's header (that would re-enter a mutual cycle), it emits this guarded copy.
// The guard makes the same enum emittable from several headers (owner's + referrers') without a
// duplicate-definition error; every copy is byte-identical, so the constants agree across translation
// units. Reads c->ast, so cross-module callers swap c->ast/source to the owner first.
static void emit_enum_full(Codegen *c, const Node *n, const NodeId enum_id) {
  char nm[160];
  render_qualified(c, c->ast->module, n->as.aggregate.name, nm, sizeof nm);
  emit(c, "#ifndef SUPER_ENUM_%s\n#define SUPER_ENUM_%s\n", nm, nm);
  emit(c, "typedef enum { ");
  const NodeList ms = n->as.aggregate.members;
  const NodeId *const mids = ast_list(c->ast, ms);
  for (uint32_t j = 0; j < ms.len; j++) {
    if (j)
      emit(c, ", ");
    emit_tag(c, enum_id, mids[j]);
    const NodeId disc = ast_at_const(c->ast, mids[j])->as.variant.value;
    if (disc != NODE_NONE) { // explicit discriminant `= <int>`
      emit(c, " = ");
      emit_expr(c, disc);
    }
  }
  emit(c, " } ");
  emit_local_type_name(c, n->as.aggregate.name);
  emit(c, ";\n#endif\n");
}

static NodeList program_items(Codegen *c) {
  return ast_at_const(c->ast, c->ast->root)->as.program.items;
}

// `typedef enum { Name_A, Name_B = 3, .. } NameTag;` -- discriminant enum of a payload-bearing enum.
static void emit_enum_tag_decl(Codegen *c, const NodeId enum_id, const Node *const dn) {
  emit(c, "typedef enum { ");
  const NodeList ms = dn->as.aggregate.members;
  const NodeId *const mids = ast_list(c->ast, ms);
  for (uint32_t j = 0; j < ms.len; j++) {
    if (j)
      emit(c, ", ");
    emit_tag(c, enum_id, mids[j]);
    const NodeId disc = ast_at_const(c->ast, mids[j])->as.variant.value;
    if (disc != NODE_NONE) { // explicit discriminant `= <int>`
      emit(c, " = ");
      emit_expr(c, disc);
    }
  }
  emit(c, " } ");
  emit_local_type_name(c, dn->as.aggregate.name);
  emit(c, "Tag;\n");
}

// The body (between `{` and `}`) of a payload-bearing enum's tagged-union C struct: a `<Name>Tag tag;`
// discriminant plus a `union` of per-variant payload structs. With the active subst map, payload member
// types are specialized (so a generic enum instance gets concrete fields). Reads c->ast.
static void emit_enum_struct_body(Codegen *c, const Node *const dn) {
  c->depth++;
  emit_indent(c);
  emit_local_type_name(c, dn->as.aggregate.name);
  emit(c, "Tag tag;\n");
  emit_indent(c);
  emit(c, "union {\n");
  c->depth++;
  const NodeList ms = dn->as.aggregate.members;
  const NodeId *const mids = ast_list(c->ast, ms);
  for (uint32_t j = 0; j < ms.len; j++) {
    const Node *const v = ast_at_const(c->ast, mids[j]);
    const NodeList payload = v->as.variant.payload;
    if (payload.len == 0)
      continue;
    const NodeId *const pids = ast_list(c->ast, payload);
    emit_indent(c);
    emit(c, "struct { ");
    for (uint32_t k = 0; k < payload.len; k++) {
      const Node *const pe = ast_at_const(c->ast, pids[k]);
      char fld[24], d[256];
      if (v->as.variant.struct_payload) {
        char m[128];
        render_ident(c, name_span(c, pe->as.field.name), m, sizeof m);
        render_type_node(c, pe->as.field.type, m, d, sizeof d);
      } else {
        snprintf(fld, sizeof fld, "_%u", k);
        render_type_node(c, pids[k], fld, d, sizeof d);
      }
      emit_cstr(c, d);
      emit(c, "; ");
    }
    emit(c, "} ");
    emit_span(c, name_span(c, v->as.variant.name));
    emit(c, ";\n");
  }
  c->depth--;
  emit_indent(c);
  emit(c, "} payload;\n");
  c->depth--;
}

// Emit a generic struct instantiation's C definition (forward typedef when !with_body), with the type
// params bound to the instance's concrete args. Same-module only (the generic struct is in this ast).
static void emit_struct_inst(Codegen *c, const TyInstance *const it, const bool with_body) {
  const Node *const dn = ast_at_const(c->ast, it->decl);
  char nm[200];
  inst_name(c, it, nm, sizeof nm);
  if (!with_body) {
    emit(c, "typedef struct %s %s;\n", nm, nm);
    return;
  }
  const NodeList gens = dn->as.aggregate.generics;
  const NodeId *const gids = ast_list(c->ast, gens);
  c->nsubst = 0;
  for (uint32_t i = 0; i < gens.len && i < it->n && c->nsubst < 8; i++) {
    c->subst[c->nsubst].param = (DefId){it->module, gids[i]};
    c->subst[c->nsubst].concrete = it->args[i];
    c->nsubst++;
  }
  emit(c, "struct %s {\n", nm);
  c->depth++;
  const NodeList fs = dn->as.aggregate.members;
  const NodeId *const fids = ast_list(c->ast, fs);
  for (uint32_t j = 0; j < fs.len; j++) {
    const Node *const f = ast_at_const(c->ast, fids[j]);
    char fnm[128], d[256];
    render_ident(c, name_span(c, f->as.field.name), fnm, sizeof fnm);
    render_type_node(c, f->as.field.type, fnm, d, sizeof d);
    emit_indent(c);
    emit_cstr(c, d);
    emit(c, ";\n");
  }
  c->depth--;
  emit(c, "};\n");
  c->nsubst = 0;
}

// Emit a generic enum instantiation. Payload-bearing -> a tagged-union struct named `Opt__i32` whose tag
// reuses the generic enum's shared `<Name>Tag` (emitted once by emit_generic_enum_shared); union member
// types are the variant payloads with the instance's args substituted. Payload-less -> a typedef alias to
// the shared plain C enum. Same-module only.
static void emit_enum_inst(Codegen *c, const TyInstance *const it, const bool with_body) {
  const Node *const dn = ast_at_const(c->ast, it->decl);
  char nm[200];
  inst_name(c, it, nm, sizeof nm);
  if (!aggregate_has_payload(c, dn)) { // phantom type param: alias the shared plain enum
    if (with_body) {
      emit(c, "typedef ");
      emit_local_type_name(c, dn->as.aggregate.name);
      emit(c, " %s;\n", nm);
    }
    return;
  }
  if (!with_body) {
    emit(c, "typedef struct %s %s;\n", nm, nm);
    return;
  }
  const NodeList gens = dn->as.aggregate.generics;
  const NodeId *const gids = ast_list(c->ast, gens);
  c->nsubst = 0;
  for (uint32_t i = 0; i < gens.len && i < it->n && c->nsubst < 8; i++) {
    c->subst[c->nsubst].param = (DefId){it->module, gids[i]};
    c->subst[c->nsubst].concrete = it->args[i];
    c->nsubst++;
  }
  emit(c, "struct %s {\n", nm);
  emit_enum_struct_body(c, dn);
  emit(c, "};\n");
  c->nsubst = 0;
}

// Emit, once per generic enum with a concrete instance, its type-arg-independent shared parts (in the
// forward pass, before any instance struct references them): a payload enum's `<Name>Tag` discriminant,
// or a payload-less enum's plain C enum (its instances alias it).
static void emit_generic_enum_shared(Codegen *c) {
  NodeId seen[64];
  int ns = 0;
  for (size_t i = 0; i < c->ast->instances.len; i++) {
    const TyInstance *const it = &c->ast->instances.data[i];
    if (it->module != c->ast->module)
      continue;
    const Node *const dn = ast_at_const(c->ast, it->decl);
    if (dn->kind != NODE_ENUM)
      continue;
    bool concrete = true;
    for (uint8_t k = 0; k < it->n; k++)
      concrete &= type_is_concrete(c, it->args[k]);
    if (!concrete)
      continue;
    bool dup = false;
    for (int s = 0; s < ns; s++)
      dup |= seen[s] == it->decl;
    if (dup)
      continue;
    if (ns < 64)
      seen[ns++] = it->decl;
    if (aggregate_has_payload(c, dn))
      emit_enum_tag_decl(c, it->decl, dn);
    else
      emit_enum_full(c, dn, it->decl); // shared plain enum (instances alias it)
  }
}

// Emit every same-module generic-aggregate instantiation (forward typedefs, then full bodies).
static void emit_aggregate_specializations(Codegen *c, const bool with_body) {
  if (!with_body)
    emit_generic_enum_shared(c); // shared tag/plain enums, before any instance struct names them
  for (size_t i = 0; i < c->ast->instances.len; i++) {
    const TyInstance *const it = &c->ast->instances.data[i];
    if (it->module != c->ast->module) // cross-module generic aggregate definitions not yet specialized
      continue;
    bool concrete = true;
    for (uint8_t k = 0; k < it->n; k++)
      concrete &= type_is_concrete(c, it->args[k]);
    if (!concrete) // skip an intermediate application like Box<T> (only real instantiations are emitted)
      continue;
    const NodeKind dk = ast_at_const(c->ast, it->decl)->kind;
    if (dk == NODE_STRUCT)
      emit_struct_inst(c, it, with_body);
    else if (dk == NODE_ENUM)
      emit_enum_inst(c, it, with_body);
  }
}

// Phase 1: forward typedefs so any type can name any struct/payload-enum regardless of order.
// Payload-less enums are self-contained, so they are emitted in full here.
static void phase_forward(Codegen *c) {
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (n->kind == NODE_STRUCT) {
      if (n->as.aggregate.generics.len)
        continue; // a generic template emits nothing; its instantiations are emitted separately
      emit(c, "typedef struct ");
      emit_local_type_name(c, n->as.aggregate.name);
      emit(c, " ");
      emit_local_type_name(c, n->as.aggregate.name);
      emit(c, ";\n");
    } else if (n->kind == NODE_ENUM) {
      if (n->as.aggregate.generics.len)
        continue; // generic enum template emits nothing (instantiation of generic enums is not yet emitted)
      if (!aggregate_has_payload(c, n)) {
        emit_enum_full(c, n, ids[i]); // self-contained, guarded (so referrers can re-emit it)
        continue;
      }
      // Payload enum: the discriminant tag enum, then a forward typedef for the tagged-union struct.
      emit_enum_tag_decl(c, ids[i], n);
      emit(c, "typedef struct ");
      emit_local_type_name(c, n->as.aggregate.name);
      emit(c, " ");
      emit_local_type_name(c, n->as.aggregate.name);
      emit(c, ";\n");
    }
  }
  emit_aggregate_specializations(c, false); // forward typedefs for generic struct instantiations
}

// Phase 2: full struct / payload-enum definitions (source order; pointer cycles use phase 1).
static void phase_types(Codegen *c) {
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (n->kind == NODE_STRUCT) {
      if (n->as.aggregate.generics.len)
        continue;
      emit(c, "struct ");
      emit_local_type_name(c, n->as.aggregate.name);
      emit(c, " {\n");
      c->depth++;
      const NodeList fs = n->as.aggregate.members;
      const NodeId *const fids = ast_list(c->ast, fs);
      for (uint32_t j = 0; j < fs.len; j++) {
        const Node *const f = ast_at_const(c->ast, fids[j]);
        char nm[128], d[256];
        render_ident(c, name_span(c, f->as.field.name), nm, sizeof nm);
        render_type_node(c, f->as.field.type, nm, d, sizeof d);
        emit_indent(c);
        emit_cstr(c, d);
        emit(c, ";\n");
      }
      c->depth--;
      emit(c, "};\n");
    } else if (n->kind == NODE_ENUM && !n->as.aggregate.generics.len && aggregate_has_payload(c, n)) {
      emit(c, "struct ");
      emit_local_type_name(c, n->as.aggregate.name);
      emit(c, " {\n");
      emit_enum_struct_body(c, n);
      emit(c, "};\n");
    }
  }
  emit_aggregate_specializations(c, true); // full bodies for generic struct instantiations
}

// Multi-return structs, after all type definitions (they reference parameter/return types).
static void phase_ret_structs(Codegen *c) {
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (n->kind == NODE_FUNCTION && !n->as.function.generics.len) {
      emit_ret_struct(c, ids[i], (DefId){0, NODE_NONE});
    } else if (n->kind == NODE_IMPL && !n->as.impl_def.generics.len) {
      const DefId target = ast_resolution_def(c->ast, n->as.impl_def.target_type);
      const NodeList ms = n->as.impl_def.items;
      const NodeId *const mids = ast_list(c->ast, ms);
      for (uint32_t j = 0; j < ms.len; j++)
        if (ast_at_const(c->ast, mids[j])->kind == NODE_FUNCTION)
          emit_ret_struct(c, mids[j], target);
    }
  }
}

// Which prototypes a pass emits: everything (single file), only public + extern (a module's header),
// or only private (a module's own .c, where they are `static`).
enum { PROTO_ALL, PROTO_PUBLIC, PROTO_PRIVATE };

static bool want_fn(const int which, const bool is_public) {
  return which == PROTO_ALL || (which == PROTO_PUBLIC) == is_public;
}

// Phase 3: prototypes for top-level functions, impl methods and extern functions (filtered by `which`).
static void phase_prototypes(Codegen *c, const int which) {
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (n->kind == NODE_FUNCTION) {
      if (n->as.function.generics.len)
        continue; // a generic template emits nothing; its specializations are emitted separately
      if (want_fn(which, n->as.function.is_public))
        emit_function(c, ids[i], (DefId){0, NODE_NONE}, false, false, NULL);
    } else if (n->kind == NODE_IMPL) {
      if (n->as.impl_def.generics.len) {
        codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: generic impl is not yet supported");
        continue;
      }
      const DefId target = ast_resolution_def(c->ast, n->as.impl_def.target_type);
      const NodeList ms = n->as.impl_def.items;
      const NodeId *const mids = ast_list(c->ast, ms);
      for (uint32_t j = 0; j < ms.len; j++)
        if (ast_at_const(c->ast, mids[j])->kind == NODE_FUNCTION && want_fn(which, ast_at_const(c->ast, mids[j])->as.function.is_public))
          emit_function(c, mids[j], target, false, false, NULL);
    } else if (n->kind == NODE_EXTERN_BLOCK && which != PROTO_PRIVATE) {
      const NodeList ms = n->as.extern_block.items;
      const NodeId *const mids = ast_list(c->ast, ms);
      for (uint32_t j = 0; j < ms.len; j++)
        if (ast_at_const(c->ast, mids[j])->kind == NODE_FUNCTION && !ast_at_const(c->ast, mids[j])->as.function.generics.len)
          emit_function(c, mids[j], (DefId){0, NODE_NONE}, true, false, NULL);
    }
  }
  if (which != PROTO_PUBLIC) // specializations are static -> their prototypes live in the .c, not the header
    emit_specializations(c, false);
}

// A top-level const, module-mangled (so refs across modules agree and names never collide). `static const`
// is per-TU internal linkage, so a public one lives in the header (each includer gets its own copy, no ODR
// issue) and a private one stays in the .c. Distinct from a block-local const (emit_stmt, kept bare).
static void emit_toplevel_const(Codegen *c, const NodeId id) {
  const Node *const n = ast_at_const(c->ast, id);
  char nm[160], decl[256];
  render_qualified(c, c->ast->module, n->as.const_def.name, nm, sizeof nm);
  render_type_node(c, n->as.const_def.type, nm, decl, sizeof decl);
  emit(c, "static const ");
  emit_cstr(c, decl);
  if (n->as.const_def.value != NODE_NONE) {
    emit(c, " = ");
    emit_initializer(c, n->as.const_def.type, n->as.const_def.value);
  }
  emit(c, ";\n");
}

// The module's public consts -- emitted into the header (multi-file build) so other modules can name them.
static void emit_public_consts(Codegen *c) {
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (n->kind == NODE_CONST && n->as.const_def.is_public)
      emit_toplevel_const(c, ids[i]);
  }
}

// Phase 4: top-level consts, then function / method bodies.
static void phase_bodies(Codegen *c) {
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    // Public consts go in the header when emitting a multi-file build; otherwise (and for private ones)
    // they go here in the .c (or the single self-contained unit).
    if (n->kind == NODE_CONST && !(c->multifile && n->as.const_def.is_public))
      emit_toplevel_const(c, ids[i]);
  }

  emit_specializations(c, true); // concrete generic instantiations, before the bodies that call them

  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (n->kind == NODE_FUNCTION && !n->as.function.generics.len && n->as.function.body != NODE_NONE) {
      emit_function(c, ids[i], (DefId){0, NODE_NONE}, false, true, NULL);
    } else if (n->kind == NODE_IMPL && !n->as.impl_def.generics.len) {
      const DefId target = ast_resolution_def(c->ast, n->as.impl_def.target_type);
      const NodeList ms = n->as.impl_def.items;
      const NodeId *const mids = ast_list(c->ast, ms);
      for (uint32_t j = 0; j < ms.len; j++)
        if (ast_at_const(c->ast, mids[j])->kind == NODE_FUNCTION && ast_at_const(c->ast, mids[j])->as.function.body != NODE_NONE)
          emit_function(c, mids[j], target, false, true, NULL);
    }
  }
}

// Subdir depth of the current module under build/ (number of `::` in its path).
static size_t module_depth(const Codegen *c) {
  const char *const p = c->package->modules[c->ast->module].path;
  size_t d = 0;
  for (size_t i = 0; p[i]; i++)
    if (p[i] == ':' && p[i + 1] == ':') {
      d++;
      i++;
    }
  return d;
}

// "../" repeated to climb from the current module's subdir back to the build root.
static void emit_rel_prefix(Codegen *c) {
  for (size_t i = 0, d = module_depth(c); i < d; i++)
    emit(c, "../");
}

// Emit `#include "<rel><path>.h"`: a path RELATIVE to the current file's dir (so the build/ tree compiles
// with `cc build/**/*.c` and no -I), where `path` is the "::"-joined module path rewritten with '/'.
static void emit_modpath_include(Codegen *c, const char *path) {
  emit(c, "#include \"");
  emit_rel_prefix(c);
  for (size_t i = 0; path[i]; i++) {
    if (path[i] == ':' && path[i + 1] == ':') {
      emit(c, "/");
      i++;
    } else {
      emit_bytes(c, path + i, 1);
    }
  }
  emit(c, ".h\"\n");
}

// Forward-declare every referenced cross-module STRUCT, so this header's prototypes can name them even
// under a mutual include cycle (e.g. str <-> string via str.to_string() / String.from_str()). A prototype
// needs only the name; the full type still arrives via the includes below (needed for by-value fields) and
// in the .c. Duplicate `typedef struct X X;` is legal C, so this is safe even when an include re-declares it.
static void emit_referenced_fwd(Codegen *c) {
  const ModuleId cur = c->ast->module;
  for (size_t i = 0; i < c->ast->type_pool.len; i++) {
    const Ty t = c->ast->type_pool.data[i];
    if (t.module == cur || t.module >= c->package->count)
      continue;
    const Node *const dn = ast_at_const(cg_mod_ast(c, t.module), t.as.decl);
    // A struct, or a payload enum (struct-shaped in C), forward-declares as `typedef struct X X;` --
    // enough for a prototype that names it. A payload-less enum lowers to a C `enum`, which C11 cannot
    // forward-declare, so emit its guarded full definition (self-contained: only integer discriminants).
    if (t.kind == TYPE_STRUCT || (t.kind == TYPE_ENUM && aggregate_has_payload_in(c, t.module, dn))) {
      char nm[160];
      render_qualified(c, t.module, dn->as.aggregate.name, nm, sizeof nm);
      emit(c, "typedef struct %s %s;\n", nm, nm);
    } else if (t.kind == TYPE_ENUM) {
      Ast *const sa = c->ast;
      const uint8_t *const ss = c->source;
      const size_t sl = c->len;
      Ast *const oa = cg_mod_ast(c, t.module); // capture owner ast/source BEFORE swapping c->ast,
      const uint8_t *const os = cg_mod_src(c, t.module); // else cg_mod_src would see the new module
      c->ast = oa;
      c->source = os;
      c->len = c->package->modules[t.module].source_len;
      emit_enum_full(c, ast_at_const(c->ast, t.as.decl), t.as.decl);
      c->ast = sa;
      c->source = ss;
      c->len = sl;
    }
  }
}

// Include the header of every OTHER module this one actually references -- via a recorded cross-module
// resolution (types, functions, idents) or an interned named type. Dependency-precise: it pulls exactly
// what this module's types/prototypes/bodies name, so auto-imported prelude modules don't cross-include
// in a cycle (str.h never pulls string.h) yet `String`'s header still gets str.h. Covers explicit
// imports and glob/prelude refs uniformly (an unused import contributes no include).
static void emit_referenced_includes(Codegen *c) {
  const size_t nmod = c->package->count;
  const ModuleId cur = c->ast->module;
  bool *const want = calloc(nmod, sizeof *want);
  if (!want)
    return;
  for (size_t i = 0; i < c->ast->resolutions.len; i++) {
    const DefId d = c->ast->resolutions.data[i];
    if (d.node != NODE_NONE && d.module != cur && d.module < nmod)
      want[d.module] = true;
  }
  for (size_t i = 0; i < c->ast->type_pool.len; i++) {
    const Ty t = c->ast->type_pool.data[i]; // named types reach modules a literal/inference uses w/o a ref
    if ((t.kind == TYPE_STRUCT || t.kind == TYPE_ENUM || t.kind == TYPE_FUNCTION || t.kind == TYPE_GENERIC) &&
        t.module != cur && t.module < nmod)
      want[t.module] = true;
  }
  for (size_t m = 0; m < nmod; m++)
    if (want[m])
      emit_modpath_include(c, c->package->modules[m].path);
  free(want);
}

// A multi-file .c includes its own header (which transitively brings in the runtime + every type and
// public prototype) plus the header of every module it references.
static void emit_includes(Codegen *c) {
  emit_modpath_include(c, c->package->modules[c->ast->module].path);
  emit_referenced_includes(c);
  emit(c, "\n");
}

// A module's public header: include guard, the shared runtime, imported headers (public signatures may
// name imported types), every type definition, multi-return structs, and public/extern prototypes only.
void codegen_emit_header(Codegen *c, FILE *out) {
  build_enum_index(c);
  // Guard from the module PATH (not the mangled prefix, which is empty for an unmangled single module --
  // that would collide across modules). "std::string" -> SUPER_STD__STRING_H.
  char guard[160];
  size_t at = buf_append(guard, sizeof guard, 0, "SUPER_");
  const char *const mp = c->package->modules[c->ast->module].path;
  for (size_t i = 0; mp[i] && at + 2 < sizeof guard; i++) {
    if (mp[i] == ':' && mp[i + 1] == ':') {
      guard[at++] = '_';
      guard[at++] = '_';
      i++;
    } else {
      guard[at++] = mp[i];
    }
  }
  guard[at] = '\0';
  buf_append(guard, sizeof guard, at, "_H");
  for (size_t i = 0; guard[i]; i++)
    if (guard[i] >= 'a' && guard[i] <= 'z')
      guard[i] = (char)(guard[i] - 32);
  emit(c, "#ifndef %s\n#define %s\n\n", guard, guard);
  emit(c, "#include \"");
  emit_rel_prefix(c); // super_rt.h lives at the build root
  emit(c, "super_rt.h\"\n");
  emit_referenced_fwd(c);      // forward-decl referenced cross-module structs (breaks mutual include cycles)
  emit_referenced_includes(c); // headers of the modules this one's public signatures / types name
  emit(c, "\n");
  phase_forward(c);
  emit(c, "\n");
  phase_types(c);
  phase_ret_structs(c);
  emit(c, "\n");
  phase_prototypes(c, PROTO_PUBLIC);
  emit(c, "\n");
  emit_public_consts(c); // public consts: in the header so other modules can name them
  emit(c, "\n#endif\n");
  if (c->buf_len)
    fwrite(c->buf, 1, c->buf_len, out);
  c->buf_len = 0; // reuse the buffer for the .c
}

void codegen_emit(Codegen *c, FILE *out) {
  build_enum_index(c);
  collect_insts(c); // generic instantiations needed by this module (emitted as static specializations)
  if (c->multifile) {
    // Multi-file .c: types/public prototypes live in the included headers; here go the private
    // (static) prototypes and every body (private functions are emitted `static`).
    emit_includes(c);
    phase_prototypes(c, PROTO_PRIVATE);
    emit(c, "\n");
    phase_bodies(c);
  } else {
    emit_cstr(c, SUPER_RT_INCLUDES);
    emit(c, "\n");
    phase_forward(c);
    emit(c, "\n");
    phase_types(c);
    phase_ret_structs(c);
    emit(c, "\n");
    phase_prototypes(c, PROTO_ALL);
    emit(c, "\n");
    phase_bodies(c);
  }
  errors_finalize(&c->errors, &c->errors_start, &c->errors_len, c->source, c->len);
  if (c->buf_len)
    fwrite(c->buf, 1, c->buf_len, out);
}

static void cg_flush(Codegen *c, FILE *out) {
  if (c->buf_len)
    fwrite(c->buf, 1, c->buf_len, out);
  c->buf_len = 0;
}

// Emit several modules as ONE self-contained translation unit, interleaved BY PHASE so cross-module
// (even mutually dependent) types resolve: all forward typedefs first, then all type definitions +
// prototypes, then all bodies. Used for the REPL/test inline build where the prelude + user code share a
// single .c (str <-> String interconversion works because every struct is forward-declared, then every
// struct is defined, before any function body). Each Codegen keeps its own AST for the caller to reclaim.
void codegen_emit_unit(Codegen **cs, const size_t n, FILE *out) {
  if (!n)
    return;
  emit_cstr(cs[0], SUPER_RT_INCLUDES);
  emit(cs[0], "\n");
  cg_flush(cs[0], out);
  for (size_t i = 0; i < n; i++) {
    build_enum_index(cs[i]);
    collect_insts(cs[i]);
  }
  for (size_t i = 0; i < n; i++) { // every struct/enum forward typedef
    phase_forward(cs[i]);
    cg_flush(cs[i], out);
  }
  for (size_t i = 0; i < n; i++) { // every full type + multi-return struct + prototype
    phase_types(cs[i]);
    phase_ret_structs(cs[i]);
    phase_prototypes(cs[i], PROTO_ALL);
    cg_flush(cs[i], out);
  }
  for (size_t i = 0; i < n; i++) { // every body (all types are complete by now)
    phase_bodies(cs[i]);
    cg_flush(cs[i], out);
  }
  for (size_t i = 0; i < n; i++)
    errors_finalize(&cs[i]->errors, &cs[i]->errors_start, &cs[i]->errors_len, cs[i]->source, cs[i]->len);
}

ERRORS_BODY(Codegen, codegen, c)
