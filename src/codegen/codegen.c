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
// Sequentially-consistent atomics over `__atomic_*` compiler builtins -- usable without <stdatomic.h>
// (whose API is macros/_Generic, not bindable symbols). Real, per-scalar-type `static inline` symbols an
// `extern "C"` binding can declare and call (`__sc_atomic_<op>_<suffix>`); unused ones cost nothing.
#define SC_ATOMIC_SHIM                                                                                              \
  "#if defined(__GNUC__) || defined(__clang__)\n"                                                                  \
  "#pragma GCC diagnostic push\n"                                                                                  \
  "#pragma GCC diagnostic ignored \"-Wunused-function\"\n"                                                         \
  "#define SC_AT(T,S) \\\n"                                                                                         \
  "static inline T __sc_atomic_load_##S(const T*p){return __atomic_load_n(p,__ATOMIC_SEQ_CST);} \\\n"              \
  "static inline void __sc_atomic_store_##S(T*p,T v){__atomic_store_n(p,v,__ATOMIC_SEQ_CST);} \\\n"                \
  "static inline T __sc_atomic_swap_##S(T*p,T v){return __atomic_exchange_n(p,v,__ATOMIC_SEQ_CST);} \\\n"          \
  "static inline T __sc_atomic_add_##S(T*p,T v){return __atomic_fetch_add(p,v,__ATOMIC_SEQ_CST);} \\\n"            \
  "static inline T __sc_atomic_sub_##S(T*p,T v){return __atomic_fetch_sub(p,v,__ATOMIC_SEQ_CST);} \\\n"            \
  "static inline T __sc_atomic_and_##S(T*p,T v){return __atomic_fetch_and(p,v,__ATOMIC_SEQ_CST);} \\\n"            \
  "static inline T __sc_atomic_or_##S(T*p,T v){return __atomic_fetch_or(p,v,__ATOMIC_SEQ_CST);} \\\n"              \
  "static inline T __sc_atomic_xor_##S(T*p,T v){return __atomic_fetch_xor(p,v,__ATOMIC_SEQ_CST);} \\\n"            \
  "static inline bool __sc_atomic_cas_##S(T*p,T e,T d){return "                                                    \
  "__atomic_compare_exchange_n(p,&e,d,0,__ATOMIC_SEQ_CST,__ATOMIC_SEQ_CST);}\n"                                    \
  "SC_AT(int8_t,i8) SC_AT(int16_t,i16) SC_AT(int32_t,i32) SC_AT(int64_t,i64) SC_AT(intptr_t,isize)\n"             \
  "SC_AT(uint8_t,u8) SC_AT(uint16_t,u16) SC_AT(uint32_t,u32) SC_AT(uint64_t,u64) SC_AT(size_t,usize)\n"           \
  "#undef SC_AT\n"                                                                                                 \
  "static inline bool __sc_atomic_load_bool(const bool*p){return __atomic_load_n(p,__ATOMIC_SEQ_CST);}\n"          \
  "static inline void __sc_atomic_store_bool(bool*p,bool v){__atomic_store_n(p,v,__ATOMIC_SEQ_CST);}\n"            \
  "static inline bool __sc_atomic_swap_bool(bool*p,bool v){return __atomic_exchange_n(p,v,__ATOMIC_SEQ_CST);}\n"   \
  "static inline bool __sc_atomic_cas_bool(bool*p,bool e,bool d){return "                                          \
  "__atomic_compare_exchange_n(p,&e,d,0,__ATOMIC_SEQ_CST,__ATOMIC_SEQ_CST);}\n"                                    \
  "static inline void __sc_atomic_fence(void){__atomic_thread_fence(__ATOMIC_SEQ_CST);}\n"                         \
  "#pragma GCC diagnostic pop\n"                                                                                   \
  "#endif\n"
const char *const SUPER_RT_INCLUDES =
    RT_H("assert.h") RT_H("complex.h") RT_H("ctype.h") RT_H("errno.h") RT_H("fenv.h") RT_H("float.h")
    RT_H("inttypes.h") RT_H("iso646.h") RT_H("limits.h") RT_H("locale.h") RT_H("math.h")
    RT_H("signal.h") RT_H("stdalign.h") RT_H("stdarg.h") RT_H("stdatomic.h") RT_H("stdbit.h") RT_H("stdbool.h")
    RT_H("stdckdint.h") RT_H("stddef.h") RT_H("stdint.h") RT_H("stdio.h") RT_H("stdlib.h") RT_H("stdnoreturn.h")
    RT_H("string.h") RT_H("tgmath.h") RT_H("threads.h") RT_H("time.h") RT_H("uchar.h") RT_H("wchar.h")
    RT_H("wctype.h") SC_ATOMIC_SHIM;
#undef RT_H
#undef SC_ATOMIC_SHIM

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
    bool insts_overflow; // set once if a module exceeds `insts` -> a loud diagnostic, never a silent drop
    // Win 1 — callback specialization: a same-module free fn called with a statically-known non-capturing
    // callback is specialized per callee, the callback param elided and the inner call made direct.
    struct {
        DefId fn;            // the specialized free function (this module)
        NodeId param;        // its elided callback parameter
        uint32_t cbidx;      // that parameter's position (so the matching argument is dropped)
        DefId callee;        // the statically-known callee bound to it (named fn / closure node)
        bool callee_closure; // callee.node is a NODE_CLOSURE
    } cb_insts[128];
    int n_cb_insts;
    NodeId cb_keep_fns[128]; // qualifying free fns that still need the pointer original (a runtime caller)
    int n_cb_keep;
    NodeId cb_param;         // while emitting a callback specialization: the elided param (else NODE_NONE)
    DefId cb_callee;         // ... its bound callee
    bool cb_callee_closure;  // ... callee is a closure node
    // Macro templating: while emitting a generic's `<G>_DECLARE`/`<G>_DEFINE` macro body, the generic
    // param renders as its name (the macro's type param), the self instance as `NAME`, and identifier
    // pastes mark a `\x01` sentinel (macro_finish -> `##`); see emit_generic_macro.
    bool macro;
    NodeId macro_self;       // the generic decl being templated (its instances render as `NAME`)
    ModuleId macro_self_mod; // that decl's module
    NodeId slice_raw;        // the array node currently emitted as the inner `.ptr` of an array->slice
                             // coercion wrap; suppresses re-entrant coercion so it emits as a bare array
    // `defer`: a stack of pending deferred statements. Each block scope runs the defers pushed within it,
    // in reverse, at its exit (fall-through, return, break, continue). `loop_defer_base` is the stack depth
    // at the innermost loop body's entry, so break/continue run only the defers registered inside the loop.
    NodeId defer_stack[256];
    uint8_t defer_kind[256]; // 0 = a `defer` statement expr; 1 = an automatic Drop of a local binding (RAII)
    uint32_t defer_top;
    uint32_t loop_defer_base;
    // RAII: locals of a `Drop`-implementing type are dropped at scope exit, UNLESS moved out (passed by
    // value, bound to another name, or returned) -- a moved value is owned (and dropped) elsewhere. `moved`
    // holds the decl nodes moved anywhere in the current function (a sound, if conservative, double-free guard).
    NodeId moved[512];
    uint32_t nmoved;
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

// Find a `@c.*` attribute of `kind` on item `owner` in module `mod`, or NULL. Attributes are few, so a
// linear scan of the owning module's table is cheap.
static const Attr *cg_attr(const Codegen *c, const ModuleId mod, const NodeId owner, const AttrKind kind) {
  const Ast *const a = cg_mod_ast(c, mod);
  for (size_t i = 0; i < a->attrs.len; i++)
    if (a->attrs.data[i].owner == owner && a->attrs.data[i].kind == kind)
      return &a->attrs.data[i];
  return NULL;
}

// If function `fn` (module `mod`) carries `@c.export`/`@c.import`, copy its literal C symbol (the bytes
// of the attribute's string, from that module's source) into `out` and return true.
static bool cg_symbol_override(const Codegen *c, const ModuleId mod, const NodeId fn, char *const out, const size_t cap) {
  const Attr *a = cg_attr(c, mod, fn, ATTR_EXPORT);
  if (!a)
    a = cg_attr(c, mod, fn, ATTR_IMPORT);
  if (!a || cap == 0)
    return false;
  size_t n = a->str.end - a->str.start;
  if (n >= cap)
    n = cap - 1;
  memcpy(out, cg_mod_src(c, mod) + a->str.start, n);
  out[n] = '\0';
  return true;
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
    "u16",  "u32",  "u64", "usize", "f32", "f64", "c32", "c64", "va_list", "void",
};
static const char *const BUILTIN_C[BT_COUNT] = {
    "bool",     "char",     "int8_t",   "int16_t", "int32_t", "int64_t",        "intptr_t",        "uint8_t",
    "uint16_t", "uint32_t", "uint64_t", "size_t",  "float",   "double",         "float _Complex",  "double _Complex",
    "va_list",  "void",
};

static void emit_expr(Codegen *c, NodeId id);
static NodeId array_length_of(Codegen *c, NodeId iter);
static void emit_stmt(Codegen *c, NodeId id);
static void cg_conv_suffix(Codegen *c, DefId target, const char *lit, TypeId srcTy, char *out, size_t cap);
static const char *cg_conv_lit(Codegen *c, ModuleId m, Span name);
static void emit_block(Codegen *c, NodeId id);
static void emit_if(Codegen *c, const Node *n);
static void emit_if_expr(Codegen *c, NodeId id);
static void emit_array_braces(Codegen *c, const Node *n);
static void emit_auto_drop(Codegen *c, NodeId letId);
static void emit_condition(Codegen *c, NodeId id);
static void render_type_node(Codegen *c, NodeId tn, const char *decl, char *out, size_t cap);
static void render_type_id(Codegen *c, TypeId t, const char *decl, char *out, size_t cap);
static size_t render_qualified(Codegen *c, ModuleId owner, NodeId name_node, char *buf, size_t cap);
static NodeId fn_array_return(Codegen *c, NodeId fn_id);
static void emit_match_core(Codegen *c, NodeId id, int mode, const char *result);
static void emit_pattern_test(Codegen *c, NodeId pid, const char *scrut);
static void emit_expr_stmt(Codegen *c, NodeId v);
static void emit_defers_to(Codegen *c, uint32_t base);
static void emit_pattern_binds(Codegen *c, NodeId pid, const char *scrut);
static bool aggregate_has_payload(Codegen *c, const Node *enum_node);
static bool aggregate_has_payload_in(Codegen *c, ModuleId m, const Node *enum_node);
static void inst_name(Codegen *c, const TyInstance *it, char *out, size_t cap);
static void closure_name(Codegen *c, NodeId id, char *out, size_t cap);
static bool cb_known_callee(Codegen *c, NodeId arg, DefId *out, bool *is_closure);
static void cb_spec_name(Codegen *c, DefId fn, DefId callee, bool is_closure, char *out, size_t cap);
static TypeId subst_lookup(Codegen *c, ModuleId m, NodeId decl);
static TypeId subst_resolve(Codegen *c, TypeId t);
static bool type_is_concrete(Codegen *c, TypeId t);
static size_t buf_append(char *out, size_t cap, size_t at, const char *text);
static NodeList program_items(Codegen *c);
static bool want_fn(int which, bool is_public);

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

// Token-paste marker emitted between a macro parameter and adjacent identifier text inside a macro body;
// macro_finish rewrites it to `##`. A no-op outside macro mode (names are concrete there).
#define CG_PASTE '\x01'
static void emit_paste(Codegen *c) {
  if (c->macro)
    emit_bytes(c, (const char[]){CG_PASTE}, 1);
}

// Finalize a generic macro body emitted into buf since `start`: turn each interior newline into a
// `\`-continued line and each CG_PASTE sentinel into `##`, so the whole multi-line template becomes one
// C `#define`. The single trailing newline is left as the macro's terminator.
static void macro_finish(Codegen *c, const size_t start) {
  if (c->buf_len <= start)
    return;
  size_t end = c->buf_len;
  while (end > start && c->buf[end - 1] == '\n')
    end--; // keep one plain newline after the body; drop trailing blanks
  const size_t n = end - start;
  char *const tmp = malloc(n);
  if (!tmp) {
    fprintf(stderr, "fatal: out of memory\n");
    abort();
  }
  memcpy(tmp, c->buf + start, n);
  c->buf_len = start;
  for (size_t i = 0; i < n; i++) {
    if (tmp[i] == '\n')
      emit_bytes(c, " \\\n", 3);
    else if (tmp[i] == CG_PASTE)
      emit_bytes(c, "##", 2);
    else
      emit_bytes(c, tmp + i, 1);
  }
  emit_bytes(c, "\n", 1);
  free(tmp);
}

// `OPTION` / `LIB__FOO`: the macro-name stem of a generic decl -- its module-qualified C name uppercased
// (non-alphanumerics -> '_'), shared by the macro definition and every invocation.
static void macro_stem(Codegen *c, const ModuleId m, const NodeId aggregate_name, char *out, const size_t cap) {
  const size_t n = render_qualified(c, m, aggregate_name, out, cap);
  for (size_t i = 0; i < n && i < cap; i++) {
    char ch = out[i];
    if (ch >= 'a' && ch <= 'z')
      ch = (char)(ch - 32);
    else if (!((ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9')))
      ch = '_';
    out[i] = ch;
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
// A generic param's source name (the macro's C-spelling type parameter, e.g. `T`).
static size_t render_macro_param(Codegen *c, const ModuleId m, const NodeId decl, char *buf, const size_t cap) {
  const Node *const gp = ast_at_const(cg_mod_ast(c, m), decl);
  return render_ident_src(cg_mod_src(c, m), name_span_in(c, m, gp->as.generic_param.name), buf, cap);
}

// Inside a macro body, the C-identifier token naming a type argument for instance-name pasting: a generic
// param renders as its mangle macro-parameter `_SCM_<name>` (so the invocation substitutes the arg's
// mangle), any concrete type as its plain mangle.
static void macro_arg_token(Codegen *c, const TypeId arg, char *out, const size_t cap) {
  const Ty *const y = ast_type_at(c->ast, arg);
  if (y->kind == TYPE_GENERIC) {
    const size_t at = buf_append(out, cap, 0, "_SCM_");
    render_macro_param(c, y->module, y->as.decl, out + at, cap - at);
    return;
  }
  mangle_type(c, arg, out, cap);
}

// In a macro body, is `it` the template's OWN self instance (`Option<T>` while templating Option) -- as
// opposed to the same generic over a different arg (`Option<U>` inside map<U>, a sibling)? Only the former
// renders as the macro's NAME parameter; the latter pastes its arg token like any other instance.
static bool is_self_instance(Codegen *c, const TyInstance *const it) {
  if (!c->macro || it->decl != c->macro_self || it->module != c->macro_self_mod)
    return false;
  const Ast *const sa = cg_mod_ast(c, c->macro_self_mod);
  const NodeList gens = ast_at_const(sa, c->macro_self)->as.aggregate.generics;
  if (gens.len != it->n)
    return false;
  const NodeId *const gids = ast_list(sa, gens);
  for (uint8_t i = 0; i < it->n; i++) {
    const Ty *const y = ast_type_at(c->ast, it->args[i]);
    if (y->kind != TYPE_GENERIC || y->as.decl != gids[i] || y->module != c->macro_self_mod)
      return false;
  }
  return true;
}

static void inst_name(Codegen *c, const TyInstance *const it, char *out, const size_t cap) {
  if (is_self_instance(c, it)) {
    buf_append(out, cap, 0, "NAME"); // the self instance -> the macro's NAME parameter
    return;
  }
  size_t at = render_qualified(c, it->module, ast_at_const(cg_mod_ast(c, it->module), it->decl)->as.aggregate.name, out, cap);
  const char sent[2] = {CG_PASTE, 0};
  for (uint8_t i = 0; i < it->n; i++) {
    if (c->macro) {
      // sibling instance inside a macro: `Base__ ## tok0 ## __ ## tok1` so mangle-param tokens glue.
      at = buf_append(out, cap, at, i ? sent : "__");
      at = buf_append(out, cap, at, i ? "__" : sent);
      if (i)
        at = buf_append(out, cap, at, sent);
      char e[176];
      macro_arg_token(c, it->args[i], e, sizeof e);
      at = buf_append(out, cap, at, e);
      continue;
    }
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
static void record_inst(Codegen *c, const DefId fn, const TypeId *const args, const int n, const NodeId site) {
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
  if (c->ninsts >= (int)(sizeof c->insts / sizeof c->insts[0])) {
    if (!c->insts_overflow) { // never drop silently: one diagnostic instead of a missing symbol at link time
      c->insts_overflow = true;
      const Span sp = ast_at_const(c->ast, site)->span;
      codegen_errorf(
          c, sp.start, sp.end - sp.start, "codegen: too many distinct generic instantiations in one module (max %d)",
          (int)(sizeof c->insts / sizeof c->insts[0]));
    }
    return;
  }
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
      record_inst(c, fn, args, n, i);
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

static int hex_val(const uint8_t ch) {
  if (ch >= '0' && ch <= '9')
    return ch - '0';
  if (ch >= 'a' && ch <= 'f')
    return ch - 'a' + 10;
  if (ch >= 'A' && ch <= 'F')
    return ch - 'A' + 10;
  return 0;
}

// Encode a Unicode scalar as UTF-8 into `out` (1-4 bytes), returning the byte count.
static int utf8_encode(const uint32_t cp, uint8_t out[4]) {
  if (cp < 0x80) {
    out[0] = (uint8_t)cp;
    return 1;
  }
  if (cp < 0x800) {
    out[0] = (uint8_t)(0xC0 | (cp >> 6));
    out[1] = (uint8_t)(0x80 | (cp & 0x3F));
    return 2;
  }
  if (cp < 0x10000) {
    out[0] = (uint8_t)(0xE0 | (cp >> 12));
    out[1] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
    out[2] = (uint8_t)(0x80 | (cp & 0x3F));
    return 3;
  }
  out[0] = (uint8_t)(0xF0 | (cp >> 18));
  out[1] = (uint8_t)(0x80 | ((cp >> 12) & 0x3F));
  out[2] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
  out[3] = (uint8_t)(0x80 | (cp & 0x3F));
  return 4;
}

// Re-emit a string/char literal with escapes translated into C's own syntax. Super-C's `\xNN` is
// exactly two hex digits and `\u{..}` is a Unicode scalar -- C reads both differently -- so each becomes
// a fixed-width octal `\NNN` (a string's `\u{}` is UTF-8 encoded first; `\0` is padded so a following
// digit can't be absorbed). Ordinary escapes (\n \t \r \\ \" \') pass through unchanged.
static void emit_reescaped(Codegen *c, const Span s, const bool is_char) {
  const uint8_t *const src = c->source;
  const char q = is_char ? '\'' : '"';
  emit(c, "%c", q);
  size_t i = s.start + 1;       // skip opening quote
  const size_t end = s.end - 1; // closing quote
  while (i < end) {
    if (src[i] != '\\') {
      emit(c, "%c", src[i]);
      i++;
      continue;
    }
    i++; // past backslash
    if (i >= end)
      break;
    const uint8_t e = src[i++];
    switch (e) {
      case 'n':
      case 'r':
      case 't':
      case '\\':
      case '"':
      case '\'':
        emit(c, "\\%c", e);
        break;
      case '0':
        emit(c, "\\000"); // single NUL, padded so a trailing octal digit isn't absorbed
        break;
      case 'x': { // exactly two hex digits -> the byte, as fixed-width octal
        const uint32_t v = (uint32_t)((hex_val(src[i]) << 4) | hex_val(src[i + 1]));
        i += 2;
        emit(c, "\\%03o", v & 0xFFu);
        break;
      }
      case 'u': { // \u{HEX}: a Unicode scalar value
        if (i < end && src[i] == '{')
          i++;
        uint32_t cp = 0;
        while (i < end && src[i] != '}') {
          cp = (cp << 4) | (uint32_t)hex_val(src[i]);
          i++;
        }
        if (i < end && src[i] == '}')
          i++;
        if (is_char) {
          emit(c, "\\%03o", cp & 0xFFu); // a char is one byte
        } else {
          uint8_t b[4];
          const int n = utf8_encode(cp, b);
          for (int k = 0; k < n; k++)
            emit(c, "\\%03o", b[k]);
        }
        break;
      }
      default:
        emit(c, "\\%c", e); // lexer-validated; copy through
        break;
    }
  }
  emit(c, "%c", q);
}

static void emit_literal(Codegen *c, const NodeId id, const Node *n) {
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
      emit_reescaped(c, s, true);
      break;
    case StringLiteral: {
      // When the typechecker coerced the literal to a `*const char` / `*const u8` (an FFI C-string slot,
      // e.g. printf's `fmt`), emit the bare C string literal -- it is already a NUL-terminated `const char*`
      // (cast for `u8` to dodge -Wpointer-sign). Otherwise it is a `str` view: `(str){ ptr, len }`.
      const TypeId tid = ast_type(c->ast, id);
      const Ty *const ty = tid == TYPE_NONE ? NULL : ast_type_at(c->ast, tid);
      if (ty && ty->kind == TYPE_POINTER) {
        const Ty *const pe = ast_type_at(c->ast, ty->as.elem);
        if (pe->kind == TYPE_BUILTIN && pe->as.builtin == BT_U8)
          emit(c, "(const uint8_t *)");
        emit_reescaped(c, s, false);
        break;
      }
      // A string literal is a `str` view: `(str){ (const uint8_t *)"...", sizeof("...") - 1 }`.
      // `sizeof - 1` is the byte length (C-decoded escapes) minus the NUL; escapes are re-emitted in C
      // syntax so `\u{..}`/`\xNN` mean the same bytes Super-C's lexer decoded.
      emit(c, "(str){ (const uint8_t *)");
      emit_reescaped(c, s, false);
      emit(c, ", sizeof(");
      emit_reescaped(c, s, false);
      emit(c, ") - 1 }");
      break;
    }
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
        } else if (dn->kind == NODE_TYPE_ALIAS && dn->as.type_alias.type == NODE_NONE) {
          char nm[160]; // opaque extern "C" handle: its real (unmangled) C name from the header, never `void`
          render_ident_src(cg_mod_src(c, d.module), ast_at_const(cg_mod_ast(c, d.module), dn->as.type_alias.name)->as.name.text, nm, sizeof nm);
          buf_join3(out, cap, nm, SEP(decl), decl);
        } else if (dn->kind == NODE_TYPE_ALIAS && d.module == c->ast->module) {
          render_type_node(c, dn->as.type_alias.type, decl, out, cap); // transparent (same module)
        } else if (dn->kind == NODE_TYPE_ALIAS) {
          render_type_id(c, ast_type(c->ast, tn), decl, out, cap); // imported alias: use the resolved type
        } else if (dn->kind == NODE_GENERIC_PARAM || dn->kind == NODE_TRAIT) {
          // A type param (concrete inside a specialization) or `Self` inside a synthesized interface
          // default method (substituted to the implementing type via the same subst stack).
          const TypeId s = subst_lookup(c, d.module, d.node);
          if (s != TYPE_NONE) {
            render_type_id(c, s, decl, out, cap);
          } else if (c->macro && dn->kind == NODE_GENERIC_PARAM) {
            char p[64]; // a macro template: the param renders as the macro's C-spelling type parameter
            render_macro_param(c, d.module, d.node, p, sizeof p);
            buf_join3(out, cap, p, SEP(decl), decl);
          } else {
            buf_join3(out, cap, "void", SEP(decl), decl);
          }
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
    case NODE_SLICE_TYPE: // `[]T` -> the prelude Slice<T> / SliceMut<T> instance C name
      render_type_id(c, ast_type(c->ast, tn), decl, out, cap);
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
      if (s != TYPE_NONE) {
        render_type_id(c, s, decl, out, cap);
      } else if (c->macro) {
        char p[64];
        render_macro_param(c, ty->module, ty->as.decl, p, sizeof p);
        buf_join3(out, cap, p, SEP(decl), decl);
      } else {
        buf_join3(out, cap, "void", SEP(decl), decl);
      }
      break;
    }
    case TYPE_INSTANCE: { // a generic struct/enum applied -> its specialized C type name (e.g. Box__i32)
      char nm[200];
      inst_name(c, ast_instance(c->ast, ty->as.inst), nm, sizeof nm);
      buf_join3(out, cap, nm, SEP(decl), decl);
      break;
    }
    case TYPE_OPAQUE: { // an extern "C" handle: its real (unmangled) C name, supplied by the header
      char nm[160];
      const Node *const dn = ast_at_const(cg_mod_ast(c, ty->module), ty->as.decl);
      render_ident_src(cg_mod_src(c, ty->module), ast_at_const(cg_mod_ast(c, ty->module), dn->as.type_alias.name)->as.name.text, nm, sizeof nm);
      buf_join3(out, cap, nm, SEP(decl), decl);
      break;
    }
    default:
      buf_join3(out, cap, "void", SEP(decl), decl);
      break;
  }
}

// True (and yields `*elem`) when `tid` is a prelude `Slice<E>` / `SliceMut<E>` instance -- the lowered
// form of `[]E` / `[]mut E`. Slice intrinsics (indexing, for-iteration) read the element type via this.
static bool cg_slice_elem(Codegen *c, const TypeId tid, TypeId *const elem) {
  if (!c->package)
    return false;
  const Ty *const ty = ast_type_at(c->ast, tid);
  if (ty->kind != TYPE_INSTANCE)
    return false;
  const TyInstance *const it = ast_instance(c->ast, ty->as.inst);
  ModuleId smid, mmid;
  const NodeId sd = package_prelude_lookup(c->package, "Slice", 5, true, &smid);
  const NodeId md = package_prelude_lookup(c->package, "SliceMut", 8, true, &mmid);
  const bool is_slice = (it->module == smid && it->decl == sd) || (it->module == mmid && it->decl == md);
  if (is_slice && it->n == 1 && elem)
    *elem = it->args[0];
  return is_slice && it->n == 1;
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
  // An array of function pointers also needs east-const: west-const would const the fn's return type
  // (`const int32_t (*a[2])(int32_t)`), which then rejects the assigned functions.
  const bool east_array_fn =
      k == NODE_ARRAY_TYPE &&
      ast_at_const(c->ast, ast_at_const(c->ast, tn)->as.array_type.element)->kind == NODE_FUNCTION_TYPE;
  if (is_const && (k == NODE_POINTER_TYPE || k == NODE_REFERENCE_TYPE || k == NODE_FUNCTION_TYPE || east_array_fn)) {
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
    case AmpersandEqual: return "&=";
    case PipeEqual: return "|=";
    case CaretEqual: return "^=";
    case LeftShiftEqual: return "<<=";
    case RightShiftEqual: return ">>=";
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

// Whether `id` denotes a C lvalue whose address can be taken directly. A by-ref method on a non-lvalue
// receiver (a call result, struct literal, ...) needs the receiver materialized into a temp first.
static bool is_lvalue(Codegen *c, const NodeId id) {
  const Node *const n = ast_at_const(c->ast, id);
  switch (n->kind) {
    case NODE_IDENTIFIER:
    case NODE_INDEX:
      return true;
    case NODE_MEMBER:
      return !n->as.member.path; // a field/element access is an lvalue; an `Enum::Variant` value is not
    case NODE_UNARY:
      return n->as.unary.op == Star; // `*p` deref
    default:
      return false;
  }
}

// Append `__<arg1>[__<arg2>]` for a method call whose method declares its own generic params (map<U>),
// reading the recorded instantiation off the call node so the call matches the emitted spec name.
static void emit_method_targs(Codegen *c, const NodeId callId, const DefId md) {
  const Node *const mn = ast_at_const(cg_mod_ast(c, md.module), md.node);
  if (mn->kind != NODE_FUNCTION || !mn->as.function.generics.len)
    return;
  const MonoUse *const mu = ast_type_args(c->ast, callId);
  for (uint8_t i = 0; mu && i < mu->n; i++) {
    char e[176];
    mangle_type(c, subst_resolve(c, mu->args[i]), e, sizeof e);
    emit(c, "__%s", e);
  }
}

static bool cg_span_eq(const uint8_t *const sa, const Span a, const uint8_t *const sb, const Span b) {
  const size_t la = a.end - a.start;
  return la == (size_t)(b.end - b.start) && memcmp(sa + a.start, sb + b.start, la) == 0;
}

// The concrete `extend <tdecl> { fn <name> }` method for a type (its module or the current module), used
// to dispatch a bound method on a now-monomorphized generic receiver to the real impl. {_,NODE_NONE} if none.
static DefId cg_find_method(Codegen *c, const ModuleId tmod, const NodeId tdecl, const uint8_t *const nsrc, const Span name) {
  const ModuleId scopes[2] = {tmod, c->ast->module};
  const int ns = tmod == c->ast->module ? 1 : 2;
  for (int s = 0; s < ns; s++) {
    const ModuleId m = scopes[s];
    Ast *const a = cg_mod_ast(c, m);
    const NodeList items = ast_at_const(a, a->root)->as.program.items;
    const NodeId *const ids = ast_list(a, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const it = ast_at_const(a, ids[i]);
      if (it->kind != NODE_IMPL || it->as.impl_def.target_type == NODE_NONE)
        continue;
      const DefId tg = ast_resolution_def(a, it->as.impl_def.target_type);
      if (tg.module != tmod || tg.node != tdecl)
        continue;
      const NodeList ms = it->as.impl_def.items;
      const NodeId *const mids = ast_list(a, ms);
      for (uint32_t j = 0; j < ms.len; j++) {
        const Node *const mn = ast_at_const(a, mids[j]);
        if (mn->kind == NODE_FUNCTION &&
            cg_span_eq(nsrc, name, cg_mod_src(c, m), ast_at_const(a, mn->as.function.name)->as.name.text))
          return (DefId){m, mids[j]};
      }
    }
  }
  return (DefId){0, NODE_NONE};
}

// Like cg_find_method but matches a C-string method name (for operator overloading -> `eq`/`cmp`).
static DefId cg_find_method_cstr(Codegen *c, const ModuleId tmod, const NodeId tdecl, const char *const lit) {
  const ModuleId scopes[2] = {tmod, c->ast->module};
  const int ns = tmod == c->ast->module ? 1 : 2;
  for (int s = 0; s < ns; s++) {
    const ModuleId m = scopes[s];
    Ast *const a = cg_mod_ast(c, m);
    const NodeList items = ast_at_const(a, a->root)->as.program.items;
    const NodeId *const ids = ast_list(a, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const it = ast_at_const(a, ids[i]);
      if (it->kind != NODE_IMPL || it->as.impl_def.target_type == NODE_NONE)
        continue;
      const DefId tg = ast_resolution_def(a, it->as.impl_def.target_type);
      if (tg.module != tmod || tg.node != tdecl)
        continue;
      const NodeList ms = it->as.impl_def.items;
      const NodeId *const mids = ast_list(a, ms);
      for (uint32_t j = 0; j < ms.len; j++) {
        const Node *const mn = ast_at_const(a, mids[j]);
        if (mn->kind == NODE_FUNCTION && span_is(cg_mod_src(c, m), ast_at_const(a, mn->as.function.name)->as.name.text, lit))
          return (DefId){m, mids[j]};
      }
    }
  }
  return (DefId){0, NODE_NONE};
}

// Emit an overloaded comparison (`a == b`, `a < b`, ...) on a struct / generic-instance operand as a call
// to its `eq` / `cmp` method. Operands are spilled to temps so taking `&` is always valid (even for a
// temporary). Returns false (operands not a struct/instance, or no method) to fall back to a plain C op.
static bool emit_cmp_overload(Codegen *c, const Node *const n) {
  const TokenType op = n->as.binary.op;
  if (op != EqualEqual && op != BangEqual && op != LessThan && op != LessThanEqual && op != GreaterThan &&
      op != GreaterThanEqual)
    return false;
  TypeId lt = ast_type(c->ast, n->as.binary.left);
  if (lt == TYPE_NONE)
    return false;
  lt = subst_resolve(c, strip_ptr(c, lt));
  const Ty *const bt = ast_type_at(c->ast, lt);
  if (bt->kind != TYPE_STRUCT && bt->kind != TYPE_INSTANCE)
    return false;
  ModuleId om;
  NodeId od;
  if (bt->kind == TYPE_INSTANCE) {
    const TyInstance *const it = ast_instance(c->ast, bt->as.inst);
    om = it->module;
    od = it->decl;
  } else {
    om = bt->module;
    od = bt->as.decl;
  }
  const bool ord = op != EqualEqual && op != BangEqual;
  const DefId m = cg_find_method_cstr(c, om, od, ord ? "cmp" : "eq");
  if (m.node == NODE_NONE)
    return false;
  char l[32], r[32];
  fresh(c, l, sizeof l);
  fresh(c, r, sizeof r);
  // Outer parens so the whole thing is a grouped expression: a bare statement-expr as an `if` condition
  // (`if ({...})`) reads the `{` as a block, but `if (({...}))` is fine.
  emit(c, "(({ __auto_type %s = ", l);
  emit_expr(c, n->as.binary.left);
  emit(c, "; __auto_type %s = ", r);
  emit_expr(c, n->as.binary.right);
  emit(c, "; ");
  if (op == BangEqual)
    emit(c, "!");
  if (ord)
    emit(c, "(");
  if (bt->kind == TYPE_INSTANCE) {
    char inm[200];
    inst_name(c, ast_instance(c->ast, bt->as.inst), inm, sizeof inm);
    emit_cstr(c, inm);
    emit_paste(c);
    emit(c, "__");
  } else {
    char pfx[64];
    render_modpfx(c, m.module, pfx, sizeof pfx);
    emit_cstr(c, pfx);
    emit_ident_mod(c, om, ast_at_const(cg_mod_ast(c, om), od)->as.aggregate.name);
    emit(c, "__");
  }
  emit_ident_mod(c, m.module, ast_at_const(cg_mod_ast(c, m.module), m.node)->as.function.name);
  emit(c, "(&%s, &%s)", l, r);
  if (ord)
    emit(c, " %s 0)", c_op(op));
  emit(c, "; }))");
  return true;
}

// True if type `y` is the prelude struct named `lit` (used to spot `str` / `String` arguments to format).
static bool cg_struct_name_is(Codegen *c, const Ty *const y, const char *const lit) {
  if (y->kind != TYPE_STRUCT)
    return false;
  const Node *const dn = ast_at_const(cg_mod_ast(c, y->module), y->as.decl);
  return span_is(cg_mod_src(c, y->module), ast_at_const(cg_mod_ast(c, y->module), dn->as.aggregate.name)->as.name.text, lit);
}

// Emit (into the format builder named `f`) a C string-literal for the raw format bytes [a, b): re-escapes
// exactly like a normal string literal, and collapses `{{`/`}}` to one brace. Emitted twice per segment --
// once for `.ptr`, once inside `sizeof` -- so the runtime length counts escapes correctly.
static void emit_fmt_cstr(Codegen *c, const size_t a, const size_t b) {
  const uint8_t *const src = c->source;
  emit(c, "\"");
  size_t i = a;
  while (i < b) {
    if ((src[i] == '{' || src[i] == '}') && i + 1 < b && src[i + 1] == src[i]) {
      emit(c, "%c", src[i]); // `{{` / `}}` -> one literal brace
      i += 2;
      continue;
    }
    if (src[i] == '\\' && i + 1 < b) {
      const uint8_t e = src[i + 1];
      if (e == 'x' && i + 3 < b) { // \xNN -> fixed-width octal (so a following digit isn't absorbed)
        emit(c, "\\%03o", (unsigned)((hex_val(src[i + 2]) << 4) | hex_val(src[i + 3])) & 0xFFu);
        i += 4;
      } else if (e == '0') {
        emit(c, "\\000");
        i += 2;
      } else { // n / r / t / \\ / " / ' (and others) copy through verbatim -- already valid C
        emit(c, "\\%c", e);
        i += 2;
      }
      continue;
    }
    emit(c, "%c", src[i]);
    i++;
  }
  emit(c, "\"");
}

// Append one format argument to the builder `f`, by its static type: any integer/float, bool, char, str, or
// String. Anything else (e.g. a Vector) is rejected -- call its `.fmt()` and pass the resulting String.
static bool emit_format_arg(Codegen *c, const char *const f, const NodeId arg) {
  const TypeId t = subst_resolve(c, ast_type(c->ast, arg));
  const Ty *const y = ast_type_at(c->ast, t);
  if (y->kind == TYPE_BUILTIN) {
    switch (y->as.builtin) {
      case BT_BOOL:
        emit(c, "if (");
        emit_expr(c, arg);
        emit(c, ") String__push_str(&%s, (str){ .ptr = (const uint8_t*)\"true\", .len = 4 });", f);
        emit(c, " else String__push_str(&%s, (str){ .ptr = (const uint8_t*)\"false\", .len = 5 });\n", f);
        return true;
      case BT_CHAR:
        emit(c, "String__push_byte(&%s, (uint8_t)(", f);
        emit_expr(c, arg);
        emit(c, "));\n");
        return true;
      case BT_I8: case BT_I16: case BT_I32: case BT_I64: case BT_ISIZE:
        emit(c, "String__push_i64(&%s, (int64_t)(", f);
        emit_expr(c, arg);
        emit(c, "));\n");
        return true;
      case BT_U8: case BT_U16: case BT_U32: case BT_U64: case BT_USIZE:
        emit(c, "String__push_u64(&%s, (uint64_t)(", f);
        emit_expr(c, arg);
        emit(c, "));\n");
        return true;
      case BT_F32: case BT_F64:
        emit(c, "String__push_f64(&%s, (double)(", f);
        emit_expr(c, arg);
        emit(c, "));\n");
        return true;
      default:
        return false;
    }
  }
  if (cg_struct_name_is(c, y, "str")) {
    emit(c, "String__push_str(&%s, ", f);
    emit_expr(c, arg);
    emit(c, ");\n");
    return true;
  }
  if (cg_struct_name_is(c, y, "String")) {
    if (is_lvalue(c, arg)) { // borrow a named String (the caller still owns it)
      emit(c, "String__push_string(&%s, &(", f);
      emit_expr(c, arg);
      emit(c, "));\n");
    } else { // a temporary (e.g. `v.fmt()`): materialize, append, then drop it (no leak)
      char tmp[32];
      fresh(c, tmp, sizeof tmp);
      emit(c, "{ String %s = ", tmp);
      emit_expr(c, arg);
      emit(c, "; String__push_string(&%s, &%s); String__drop(&%s); }\n", f, tmp, tmp);
    }
    return true;
  }
  return false;
}

// True if (m, node) is the prelude `format`/`print`/`println` builtin. Their calls are always desugared
// (emit_format_builtin), so the declarations themselves emit no C (the stub bodies are never used).
static bool cg_is_format_builtin(Codegen *c, const ModuleId m, const NodeId node) {
  if (!c->package || m >= c->package->count || !c->package->modules[m].prelude)
    return false;
  const Ast *const a = cg_mod_ast(c, m);
  if (ast_at_const(a, node)->kind != NODE_FUNCTION)
    return false;
  const Span fn = ast_at_const(a, ast_at_const(a, node)->as.function.name)->as.name.text;
  return span_is(cg_mod_src(c, m), fn, "format") || span_is(cg_mod_src(c, m), fn, "print") ||
         span_is(cg_mod_src(c, m), fn, "println");
}

// `format`/`print`/`println`: a string-literal first arg with `{}` placeholders + matching trailing args.
// Build a String with per-argument appends, then yield it (format) / write it to stdout (print/println).
// Returns false (fall through to a normal call) if this is not one of the builtins.
static bool emit_format_builtin(Codegen *c, const Node *const n) {
  if (!c->package)
    return false;
  const Node *const callee = ast_at_const(c->ast, n->as.call.callee);
  if (callee->kind != NODE_IDENTIFIER)
    return false;
  const DefId d = ast_resolution_def(c->ast, n->as.call.callee);
  if (d.node == NODE_NONE || d.module >= c->package->count || !c->package->modules[d.module].prelude)
    return false;
  const Ast *const da = cg_mod_ast(c, d.module);
  if (ast_at_const(da, d.node)->kind != NODE_FUNCTION)
    return false;
  const Span fn = ast_at_const(da, ast_at_const(da, d.node)->as.function.name)->as.name.text;
  const int kind = span_is(cg_mod_src(c, d.module), fn, "format") ? 1 : span_is(cg_mod_src(c, d.module), fn, "print") ? 2
                   : span_is(cg_mod_src(c, d.module), fn, "println") ? 3 : 0;
  if (!kind)
    return false;
  const NodeList args = n->as.call.args;
  const NodeId *const aids = ast_list(c->ast, args);
  const Node *const fmtn = args.len ? ast_at_const(c->ast, aids[0]) : NULL;
  if (!fmtn || fmtn->kind != NODE_LITERAL || fmtn->as.literal.token_type != StringLiteral) {
    codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: format string must be a string literal");
    return true;
  }
  char f[32];
  fresh(c, f, sizeof f);
  emit(c, "({ String %s = String__new();\n", f);
  const Span raw = fmtn->as.literal.raw;
  const uint8_t *const src = c->source;
  size_t i = raw.start + 1;
  const size_t end = raw.end - 1;
  size_t seg = i;
  uint32_t ai = 1;
  while (i < end) {
    if ((src[i] == '{' || src[i] == '}') && i + 1 < end && src[i + 1] == src[i]) {
      i += 2;
      continue;
    }
    if (src[i] == '{' && i + 1 < end && src[i + 1] == '}') {
      if (i > seg) {
        emit(c, "String__push_str(&%s, (str){ .ptr = (const uint8_t*)", f);
        emit_fmt_cstr(c, seg, i);
        emit(c, ", .len = sizeof(");
        emit_fmt_cstr(c, seg, i);
        emit(c, ") - 1 });\n");
      }
      if (ai >= args.len) {
        codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: more `{}` placeholders than arguments");
        emit(c, "%s; })", f);
        return true;
      }
      if (!emit_format_arg(c, f, aids[ai])) {
        const Span as = ast_at_const(c->ast, aids[ai])->span;
        codegen_errorf(c, as.start, as.end - as.start, "codegen: argument is not directly formattable (call its .fmt())");
      }
      ai++;
      i += 2;
      seg = i;
      continue;
    }
    i++;
  }
  if (end > seg) {
    emit(c, "String__push_str(&%s, (str){ .ptr = (const uint8_t*)", f);
    emit_fmt_cstr(c, seg, end);
    emit(c, ", .len = sizeof(");
    emit_fmt_cstr(c, seg, end);
    emit(c, ") - 1 });\n");
  }
  if (ai < args.len)
    codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: more arguments than `{}` placeholders");
  if (kind == 3)
    emit(c, "String__push_byte(&%s, 10);\n", f);
  if (kind == 1) {
    emit(c, "%s; })", f); // format: yield the built String
  } else {
    emit(c, "String__print(&%s); String__drop(&%s); })", f, f); // print/println: write to stdout, then free
  }
  return true;
}

static void emit_call(Codegen *c, const NodeId id, const Node *n) {
  const NodeId callee_id = n->as.call.callee;
  const Node *const callee = ast_at_const(c->ast, callee_id);
  const NodeList args = n->as.call.args;
  const NodeId *const aids = ast_list(c->ast, args);

  if (emit_format_builtin(c, n)) // format/print/println: split the literal + per-arg appends
    return;

  // Win 1, inside a callback specialization: a call to the elided callback parameter becomes a direct
  // call to the bound callee (no indirection).
  if (c->cb_param != NODE_NONE && callee->kind == NODE_IDENTIFIER) {
    const DefId d = ast_resolution_def(c->ast, callee_id);
    if (d.module == c->ast->module && d.node == c->cb_param) {
      char sym[200];
      if (c->cb_callee_closure)
        closure_name(c, c->cb_callee.node, sym, sizeof sym);
      else
        render_qualified(
            c, c->cb_callee.module,
            ast_at_const(cg_mod_ast(c, c->cb_callee.module), c->cb_callee.node)->as.function.name, sym, sizeof sym);
      emit_cstr(c, sym);
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

  // Win 1, at a call site: a free fn called with a statically-known non-capturing callback -> its
  // specialization (`fn__cb_<callee>`), with the callback argument dropped.
  if (callee->kind == NODE_IDENTIFIER) {
    const DefId fn = ast_resolution_def(c->ast, callee_id);
    for (int k = 0; k < c->n_cb_insts; k++) {
      if (c->cb_insts[k].fn.node != fn.node || c->cb_insts[k].fn.module != fn.module)
        continue;
      const uint32_t cbidx = c->cb_insts[k].cbidx;
      DefId ac;
      bool acclo;
      if (cbidx >= args.len || !cb_known_callee(c, aids[cbidx], &ac, &acclo) ||
          ac.node != c->cb_insts[k].callee.node || ac.module != c->cb_insts[k].callee.module)
        continue;
      char nm[260];
      cb_spec_name(c, fn, ac, acclo, nm, sizeof nm);
      emit_cstr(c, nm);
      emit(c, "(");
      bool wrote = false;
      for (uint32_t i = 0; i < args.len; i++) {
        if (i == cbidx)
          continue; // the callback argument is baked into the specialization
        if (wrote)
          emit(c, ", ");
        emit_expr(c, aids[i]);
        wrote = true;
      }
      emit(c, ")");
      return;
    }
  }

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
      // `@c.export`/`@c.import` pin the exact C symbol regardless of module mangling.
      char ov[160];
      const bool override = cg_symbol_override(c, md.module, md.node, ov, sizeof ov);
      // A raw binding reached as `mod::f(..)` keeps its real C symbol name -- never module-mangled.
      if (override || ast_at_const(cg_mod_ast(c, md.module), md.node)->as.function.is_extern) {
        if (override)
          emit_cstr(c, ov);
        else
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
      const TypeId base_t = ast_type(c->ast, callee->as.member.object); // `Type::<Args>` base -> instance
      const DefId td = ast_resolution_def(c->ast, callee->as.member.object); // the Target type (none = module fn)
      DefId emd = md;
      // `T::assoc()` on a type parameter: resolve T to the concrete type (we are emitting a specialization)
      // and dispatch to that type's `as`-impl method instead of the abstract interface method.
      TypeId param_tgt = TYPE_NONE;
      if (td.node != NODE_NONE && ast_at_const(cg_mod_ast(c, td.module), td.node)->kind == NODE_GENERIC_PARAM) {
        const TypeId r = subst_resolve(c, ast_intern_type(c->ast, (Ty){.kind = TYPE_GENERIC, .module = td.module, .as.decl = td.node}));
        if (type_is_concrete(c, r))
          param_tgt = r;
      } else if (td.node != NODE_NONE && ast_at_const(cg_mod_ast(c, td.module), td.node)->kind == NODE_TRAIT) {
        const TypeId r = subst_resolve(c, ast_type(c->ast, id)); // `Trait::assoc()`: the call's result type is the concrete target
        if (type_is_concrete(c, r))
          param_tgt = r;
      }
      if (base_t != TYPE_NONE && ast_type_at(c->ast, base_t)->kind == TYPE_INSTANCE) {
        char inm[200]; // a generic instance assoc fn -> `Inst__method` (inst_name is already module-qualified)
        inst_name(c, ast_instance(c->ast, ast_type_at(c->ast, base_t)->as.inst), inm, sizeof inm);
        emit_cstr(c, inm);
        emit_paste(c); // in a macro body `NAME ## __method`
        emit(c, "__");
      } else if (param_tgt != TYPE_NONE) {
        const Ty *const rb = ast_type_at(c->ast, param_tgt);
        ModuleId omod;
        NodeId odecl;
        if (rb->kind == TYPE_INSTANCE) {
          const TyInstance *const it = ast_instance(c->ast, rb->as.inst);
          omod = it->module;
          odecl = it->decl;
        } else {
          omod = rb->module;
          odecl = rb->as.decl;
        }
        const DefId cm = cg_find_method(c, omod, odecl, cg_mod_src(c, md.module), name_span(c, callee->as.member.member));
        if (cm.node != NODE_NONE)
          emd = cm;
        if (rb->kind == TYPE_INSTANCE) {
          char inm[200];
          inst_name(c, ast_instance(c->ast, rb->as.inst), inm, sizeof inm);
          emit_cstr(c, inm);
          emit_paste(c);
          emit(c, "__");
        } else if (rb->kind == TYPE_STRUCT || rb->kind == TYPE_ENUM) {
          char pfx[64];
          render_modpfx(c, emd.module, pfx, sizeof pfx);
          emit_cstr(c, pfx);
          emit_ident_mod(c, omod, ast_at_const(cg_mod_ast(c, omod), odecl)->as.aggregate.name);
          emit(c, "__");
        }
      } else {
        char pfx[64];
        render_modpfx(c, md.module, pfx, sizeof pfx);
        emit_cstr(c, pfx);
        if (td.node != NODE_NONE) { // `Type::method` -> `Target__method`; a `module::func` has no target type
          emit_ident_mod(c, td.module, ast_at_const(cg_mod_ast(c, td.module), td.node)->as.aggregate.name);
          emit(c, "__");
        }
      }
      emit_ident_mod(c, emd.module, ast_at_const(cg_mod_ast(c, emd.module), emd.node)->as.function.name);
      if (td.node != NODE_NONE && args.len) { // overloaded `Type::from(x)` -> `Type__from__<argType>`
        char sfx[200];
        cg_conv_suffix(c, td, cg_conv_lit(c, c->ast->module, name_span(c, callee->as.member.member)), ast_type(c->ast, aids[0]), sfx, sizeof sfx);
        emit_cstr(c, sfx);
      }
      emit_method_targs(c, id, emd);
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
    DefId md = ast_resolution_def(c->ast, callee->as.member.member);
    if (md.node != NODE_NONE && ast_at_const(cg_mod_ast(c, md.module), md.node)->kind == NODE_FUNCTION) {
      const NodeId obj = callee->as.member.object;
      // Built-in conversion: `x.into()`/`x.try_into()` resolved (by the typechecker) to `Target::from` /
      // `U::try_from`. The member name (`into`/`try_into`) differs from the dispatched method (`from`/
      // `try_from`), which is the signal; emit `Target__from(x)` with the receiver passed as the value arg.
      const Span memn = name_span(c, callee->as.member.member);
      const Span mdn = ast_at_const(cg_mod_ast(c, md.module), ast_at_const(cg_mod_ast(c, md.module), md.node)->as.function.name)->as.name.text;
      const bool conv = (span_is(cg_mod_src(c, c->ast->module), memn, "into") && span_is(cg_mod_src(c, md.module), mdn, "from")) ||
                        (span_is(cg_mod_src(c, c->ast->module), memn, "try_into") && span_is(cg_mod_src(c, md.module), mdn, "try_from"));
      if (conv) {
        TypeId tgt = subst_resolve(c, ast_type(c->ast, id)); // into: result = Target; try_into: Result<U,E>
        const Ty *rt = ast_type_at(c->ast, tgt);
        if (span_is(cg_mod_src(c, md.module), mdn, "try_from") && rt->kind == TYPE_INSTANCE)
          tgt = subst_resolve(c, ast_instance(c->ast, rt->as.inst)->args[0]); // unwrap to U
        const Ty *const tb = ast_type_at(c->ast, tgt);
        if (tb->kind == TYPE_INSTANCE) {
          char inm[200];
          inst_name(c, ast_instance(c->ast, tb->as.inst), inm, sizeof inm);
          emit_cstr(c, inm);
          emit_paste(c);
          emit(c, "__");
        } else {
          char pfx[64];
          render_modpfx(c, md.module, pfx, sizeof pfx);
          emit_cstr(c, pfx);
          emit_ident_mod(c, tb->module, ast_at_const(cg_mod_ast(c, tb->module), tb->as.decl)->as.aggregate.name);
          emit(c, "__");
        }
        emit_ident_mod(c, md.module, ast_at_const(cg_mod_ast(c, md.module), md.node)->as.function.name);
        { // overloaded `from`/`try_from`: disambiguate by the source value's type (`x.into()` -> `T__from__<src>`)
          const DefId ct = tb->kind == TYPE_INSTANCE
                               ? (DefId){ast_instance(c->ast, tb->as.inst)->module, ast_instance(c->ast, tb->as.inst)->decl}
                               : (DefId){tb->module, tb->as.decl};
          char sfx[200];
          cg_conv_suffix(c, ct, cg_conv_lit(c, md.module, mdn), ast_type(c->ast, obj), sfx, sizeof sfx);
          emit_cstr(c, sfx);
        }
        emit(c, "(");
        emit_expr(c, obj);
        emit(c, ")");
        return;
      }
      const TypeId obj_t = ast_type(c->ast, obj);
      const TypeId pointee = strip_ptr(c, obj_t);
      // A method on a generic-parameter receiver (`w: T`, `T: Writer`) resolved to the interface method;
      // once the param is monomorphized, dispatch to the concrete type's `as`-impl method (`File__write`).
      if (ast_type_at(c->ast, pointee)->kind == TYPE_GENERIC) {
        const Ty *const rb = ast_type_at(c->ast, subst_resolve(c, pointee));
        if (rb->kind == TYPE_STRUCT || rb->kind == TYPE_ENUM) {
          const DefId cm = cg_find_method(
              c, rb->module, rb->as.decl, cg_mod_src(c, c->ast->module), name_span(c, callee->as.member.member));
          if (cm.node != NODE_NONE)
            md = cm;
        }
      }
      Ast *const ma = cg_mod_ast(c, md.module);
      const Ty *const base = ast_type_at(c->ast, subst_resolve(c, pointee));
      // self-by-pointer is decided from the self parameter's own type node (in the method's module).
      const NodeList params = ast_at_const(ma, md.node)->as.function.params;
      const NodeId self_type = params.len ? ast_at_const(ma, ast_list(ma, params)[0])->as.parameter.type : NODE_NONE;
      const NodeKind sk = self_type != NODE_NONE ? ast_at_const(ma, self_type)->kind : NODE_NONE_KIND;
      const bool self_ptr = sk == NODE_POINTER_TYPE || sk == NODE_REFERENCE_TYPE;
      const bool obj_ptr = ast_type_at(c->ast, obj_t)->kind == TYPE_POINTER || ast_type_at(c->ast, obj_t)->kind == TYPE_REFERENCE;
      // `&self` on a temporary (call result, literal, ...): C cannot take its address, so materialize the
      // receiver into a statement-expression temp and pass `&temp`. Mutations to a temporary are moot.
      const bool materialize = self_ptr && !obj_ptr && !is_lvalue(c, obj);
      char tmp[32];
      if (materialize) {
        fresh(c, tmp, sizeof tmp);
        emit(c, "({ __auto_type %s = ", tmp);
        emit_expr(c, obj);
        emit(c, "; ");
      }
      if (c->macro && base->kind == TYPE_GENERIC) {
        // A bound-method call on a generic param inside a generic macro template (`elem.clone()` where
        // `T: Clone`): the concrete arg is unknown here, so paste the param's mangle token with the method
        // to form the impl symbol at invocation time (`_SCM_T ## __clone` -> `Bar__clone`). The method must
        // live in the arg type's own module (coherent impl), so its symbol prefix matches the arg's mangle.
        char pp[64];
        emit(c, "_SCM_");
        render_macro_param(c, base->module, base->as.decl, pp, sizeof pp);
        emit_cstr(c, pp);
        emit_paste(c);
        emit(c, "__");
      } else if (base->kind == TYPE_INSTANCE) { // a generic instance receiver -> monomorphized `Inst__method`
        char inm[200];
        inst_name(c, ast_instance(c->ast, base->as.inst), inm, sizeof inm); // already module-qualified
        emit_cstr(c, inm);
        emit_paste(c); // in a macro body `NAME ## __method`
        emit(c, "__");
      } else if (base->kind == TYPE_STRUCT || base->kind == TYPE_ENUM) {
        char pfx[64];
        render_modpfx(c, md.module, pfx, sizeof pfx); // method's module: a local extension is mangled by it
        emit_cstr(c, pfx);
        emit_ident_mod(c, base->module, ast_at_const(cg_mod_ast(c, base->module), base->as.decl)->as.aggregate.name);
        emit(c, "__");
      } else {
        codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: method receiver is not a struct or enum");
      }
      emit_ident_mod(c, md.module, ast_at_const(ma, md.node)->as.function.name);
      emit_method_targs(c, id, md);
      emit(c, "(");

      bool wrote = false;
      if (params.len > 0) { // bind the receiver to the implicit self parameter
        if (materialize)
          emit(c, "&%s", tmp);
        else if (self_ptr && !obj_ptr)
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
      if (materialize)
        emit(c, "; })");
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
  render_type_node(c, n->as.struct_initializer.type, "", t, sizeof t); // for `Enum::Variant` this is the enum's C name
  const NodeList fields = n->as.struct_initializer.fields;
  const NodeId *const ids = ast_list(c->ast, fields);
  // `Enum::Variant { f: .. }` -> (Enum){ .tag = Enum_Variant, .payload.Variant = { .f = .. } }
  const NodeId stn = n->as.struct_initializer.type;
  if (ast_at_const(c->ast, stn)->kind == NODE_TYPE_PATH) {
    const NodeList parts = ast_at_const(c->ast, stn)->as.type_path.parts;
    if (parts.len >= 2) {
      const DefId vd = ast_resolution_def(c->ast, ast_list(c->ast, parts)[parts.len - 1]);
      if (vd.node != NODE_NONE && ast_at_const(cg_mod_ast(c, vd.module), vd.node)->kind == NODE_VARIANT) {
        const NodeId en = enclosing_enum_in(c, vd.module, vd.node);
        char vn[128];
        render_variant_name(c, vd.module, vd.node, vn, sizeof vn);
        emit(c, "(%s){ .tag = ", t);
        if (en != NODE_NONE)
          emit_tag_mod(c, vd.module, en, vd.node);
        else
          emit(c, "0");
        emit(c, ", .payload.%s = {", vn);
        for (uint32_t i = 0; i < fields.len; i++) {
          const Node *const fi = ast_at_const(c->ast, ids[i]);
          emit(c, i ? ", ." : " .");
          emit_ident(c, name_span(c, fi->as.field_initializer.name));
          emit(c, " = ");
          const NodeId fv = fi->as.field_initializer.value;
          if (ast_at_const(c->ast, fv)->kind == NODE_ARRAY_LITERAL)
            emit_array_braces(c, ast_at_const(c->ast, fv));
          else
            emit_expr(c, fv);
        }
        emit(c, fields.len ? " } }" : "0 } }");
        return;
      }
    }
  }
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
    const NodeId fv = fi->as.field_initializer.value;
    if (ast_at_const(c->ast, fv)->kind == NODE_ARRAY_LITERAL) // a C array member takes a brace list, not an expr
      emit_array_braces(c, ast_at_const(c->ast, fv));
    else
      emit_expr(c, fv);
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
    // `@c.export`/`@c.import` pin the exact C symbol (covers a bare `f()` to an exported fn or an
    // imported binding reached by its Super-C name).
    if (dn->kind == NODE_FUNCTION) {
      char ov[160];
      if (cg_symbol_override(c, d.module, d.node, ov, sizeof ov)) {
        emit_cstr(c, ov);
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
    const Node *const el = ast_at_const(c->ast, ids[i]);
    if (el->kind == NODE_FIELD_INITIALIZER) { // designated element `[index] = value`
      emit(c, "[");
      emit_expr(c, el->as.field_initializer.name);
      emit(c, "] = ");
      const Node *const v = ast_at_const(c->ast, el->as.field_initializer.value);
      if (v->kind == NODE_ARRAY_LITERAL)
        emit_array_braces(c, v);
      else
        emit_expr(c, el->as.field_initializer.value);
    } else if (el->kind == NODE_ARRAY_LITERAL) { // a nested array member needs a brace list, not a `(T[N]){..}` expr
      emit_array_braces(c, el);
    } else {
      emit_expr(c, ids[i]);
    }
  }
  emit(c, " }");
}

// If `id`'s (coerced) type is a prelude slice but its value is an array -- a `[T; N]` literal or an
// array-typed binding -- materialize the `(Slice__T){ .ptr = <array>, .len = N }` fat-pointer view and
// return true. Length is the literal's element count or the binding's declared `[T; N]`. A genuine slice
// value (struct literal, call, slice binding) has no recoverable array length here, so it falls through.
static bool emit_slice_coercion(Codegen *c, const NodeId id) {
  TypeId selem;
  const TypeId st = ast_type(c->ast, id);
  if (!cg_slice_elem(c, st, &selem))
    return false;
  const Node *const n = ast_at_const(c->ast, id);
  const bool is_lit = n->kind == NODE_ARRAY_LITERAL;
  const NodeId lenN = is_lit ? NODE_NONE : array_length_of(c, id);
  if (!is_lit && lenN == NODE_NONE)
    return false; // a real slice value, not an array source
  char styp[200];
  render_type_id(c, st, "", styp, sizeof styp);
  emit(c, "(%s){ .ptr = ", styp);
  if (is_lit) { // a typed compound literal `(T[N]){..}`; T is the slice element (the node's type is the slice)
    char et[256];
    render_type_id(c, selem, "", et, sizeof et);
    emit(c, "(%s[%u])", et, n->as.array_literal.elements.len);
    emit_array_braces(c, n);
    emit(c, ", .len = %u }", n->as.array_literal.elements.len);
    return true;
  }
  c->slice_raw = id; // re-entry guard: emit the array binding bare (it decays to its element pointer)
  emit_expr(c, id);
  c->slice_raw = NODE_NONE;
  emit(c, ", .len = ");
  emit_expr(c, lenN);
  emit(c, " }");
  return true;
}

static void emit_expr(Codegen *c, const NodeId id) {
  if (id == NODE_NONE)
    return;
  if (id != c->slice_raw && emit_slice_coercion(c, id)) // array -> slice fat-pointer view
    return;
  const Node *const n = ast_at_const(c->ast, id);
  switch (n->kind) {
    case NODE_LITERAL:
      emit_literal(c, id, n);
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
    case NODE_BINARY: {
      // Operator overloading: a comparison on a struct / generic-instance operand -> its eq/cmp method.
      if (emit_cmp_overload(c, n))
        break;
      // C's `%` is integer-only; on floats lower to fmodf/fmod (the type checker allows float `%`).
      if (n->as.binary.op == Percent) {
        const Ty *const lt = ast_type_at(c->ast, ast_type(c->ast, n->as.binary.left));
        if (lt->kind == TYPE_BUILTIN && (lt->as.builtin == BT_F32 || lt->as.builtin == BT_F64)) {
          emit(c, "%s(", lt->as.builtin == BT_F32 ? "fmodf" : "fmod");
          emit_expr(c, n->as.binary.left);
          emit(c, ", ");
          emit_expr(c, n->as.binary.right);
          emit(c, ")");
          break;
        }
      }
      emit(c, "(");
      emit_expr(c, n->as.binary.left);
      emit(c, " %s ", c_op(n->as.binary.op));
      emit_expr(c, n->as.binary.right);
      emit(c, ")");
      break;
    }
    case NODE_ASSIGNMENT: {
      // C arrays aren't assignable, so `arr = [..]` / `arr = other` lowers to memcpy (value semantics).
      // The RHS array literal emits as a `(T[N]){..}` compound literal that decays to a pointer here.
      const TypeId lt = ast_type(c->ast, n->as.binary.left);
      if (n->as.binary.op == Equal && lt != TYPE_NONE && ast_type_at(c->ast, lt)->kind == TYPE_ARRAY) {
        emit(c, "memcpy(");
        emit_expr(c, n->as.binary.left);
        emit(c, ", ");
        emit_expr(c, n->as.binary.right);
        emit(c, ", sizeof(");
        emit_expr(c, n->as.binary.left);
        emit(c, "))");
        break;
      }
      emit(c, "("); // parenthesized like NODE_BINARY: C's `=`/`+=` bind looser, so a sub-expression
      emit_expr(c, n->as.binary.left); // assignment (`(a = 5) + 1`, `if (a = 3) == 3`) must keep its grouping
      emit(c, " %s ", c_op(n->as.binary.op));
      emit_expr(c, n->as.binary.right);
      emit(c, ")");
      break;
    }
    case NODE_CALL: {
      // A call returning an array by value yields its wrapper struct; `._` recovers the array (so it
      // can be indexed, passed (decaying to a pointer), or memcpy-copied into a binding).
      const TypeId ct = ast_type(c->ast, id);
      const bool arr_ret = ct != TYPE_NONE && ast_type_at(c->ast, ct)->kind == TYPE_ARRAY;
      if (arr_ret)
        emit(c, "(");
      emit_call(c, id, n);
      if (arr_ret)
        emit(c, ")._");
      break;
    }
    case NODE_CLOSURE: { // a closure value is just the address of its hoisted static function
      char nm[200];
      closure_name(c, id, nm, sizeof nm);
      emit_cstr(c, nm);
      break;
    }
    case NODE_INDEX: {
      if (cg_slice_elem(c, ast_type(c->ast, n->as.index.object), NULL)) { // `s[i]` on `[]T`: its typed `.ptr`
        emit_expr(c, n->as.index.object);
        emit(c, ".ptr[");
      } else {
        emit_expr(c, n->as.index.object);
        emit(c, "[");
      }
      emit_expr(c, n->as.index.index);
      emit(c, "]");
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
    case NODE_SIZEOF: {
      char ty[256];
      render_type_node(c, n->as.single.value, "", ty, sizeof ty); // substitutes T inside a specialization
      emit(c, "sizeof(%s)", ty);
      break;
    }
    case NODE_VA_EXPR:
      if (n->as.va_op.op == VA_ARG) {
        char ty[256];
        render_type_node(c, n->as.va_op.extra, "", ty, sizeof ty);
        emit(c, "va_arg(");
        emit_expr(c, n->as.va_op.ap);
        emit(c, ", %s)", ty);
      } else if (n->as.va_op.op == VA_START) {
        emit(c, "va_start(");
        emit_expr(c, n->as.va_op.ap);
        emit(c, ", ");
        emit_expr(c, n->as.va_op.extra);
        emit(c, ")");
      } else { // VA_END
        emit(c, "va_end(");
        emit_expr(c, n->as.va_op.ap);
        emit(c, ")");
      }
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
      // A struct-payload variant pattern (`Rect { w, h }`) first tests the tag, then reads fields via
      // `.payload.Variant.field`; a plain struct pattern reads `.field` directly.
      const DefId vd =
          p->as.pattern.name != NODE_NONE ? ast_resolution_def(c->ast, p->as.pattern.name) : (DefId){0, NODE_NONE};
      const bool is_variant = vd.node != NODE_NONE && ast_at_const(cg_mod_ast(c, vd.module), vd.node)->kind == NODE_VARIANT;
      const NodeList ch = p->as.pattern.children;
      const NodeId *const ids = ast_list(c->ast, ch);
      char prefix[300];
      bool wrote = false;
      if (is_variant) {
        const NodeId en = enclosing_enum_in(c, vd.module, vd.node);
        const bool payload =
            en != NODE_NONE && aggregate_has_payload_in(c, vd.module, ast_at_const(cg_mod_ast(c, vd.module), en));
        emit(c, payload ? "%s.tag == " : "%s == ", scrut);
        if (en != NODE_NONE)
          emit_tag_mod(c, vd.module, en, vd.node);
        else
          emit(c, "0");
        wrote = true;
        char vn[128];
        render_variant_name(c, vd.module, vd.node, vn, sizeof vn);
        snprintf(prefix, sizeof prefix, "%s.payload.%s", scrut, vn);
      } else {
        snprintf(prefix, sizeof prefix, "%s", scrut);
      }
      for (uint32_t i = 0; i < ch.len; i++) {
        const Node *const f = ast_at_const(c->ast, ids[i]);
        const NodeList sub = f->as.pattern.children;
        const NodeId subpat = sub.len ? ast_list(c->ast, sub)[0] : NODE_NONE;
        if (subpat == NODE_NONE || pat_trivial(ast_at_const(c->ast, subpat)->kind))
          continue;
        char m[128];
        render_ident(c, name_span(c, f->as.pattern.name), m, sizeof m);
        char acc[440];
        snprintf(acc, sizeof acc, "%s.%s", prefix, m);
        emit(c, wrote ? " && " : "");
        emit_pattern_test(c, subpat, acc);
        wrote = true;
      }
      if (!wrote)
        emit(c, "1");
      break;
    }
    case NODE_PATTERN_OR: { // matches if any alternative matches: `(t0) || (t1) || ...`
      const NodeList alts = p->as.pattern.children;
      const NodeId *const ids = ast_list(c->ast, alts);
      if (alts.len == 0) {
        emit(c, "1");
        break;
      }
      for (uint32_t i = 0; i < alts.len; i++) {
        emit(c, i ? " || (" : "(");
        emit_pattern_test(c, ids[i], scrut);
        emit(c, ")");
      }
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
      // const iff immutable: `Some(mut x)` binds non-const (reassignment / `&mut self` methods); a plain
      // `Some(x)` is immutable, and the typechecker rejects mutating it.
      const bool is_mut = ast_at_const(c->ast, p->as.pattern.name)->as.name.is_mutable;
      emit_binding(c, ast_type(c->ast, pid), name_span(c, p->as.pattern.name), !is_mut);
      emit(c, " = %s;\n", scrut);
      break;
    }
    case NODE_IDENTIFIER:
      emit_indent(c);
      emit_binding(c, ast_type(c->ast, pid), p->as.name.text, !p->as.name.is_mutable);
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
      const DefId vd =
          p->as.pattern.name != NODE_NONE ? ast_resolution_def(c->ast, p->as.pattern.name) : (DefId){0, NODE_NONE};
      char prefix[300];
      if (vd.node != NODE_NONE && ast_at_const(cg_mod_ast(c, vd.module), vd.node)->kind == NODE_VARIANT) {
        char vn[128];
        render_variant_name(c, vd.module, vd.node, vn, sizeof vn);
        snprintf(prefix, sizeof prefix, "%s.payload.%s", scrut, vn); // struct-payload variant field access
      } else {
        snprintf(prefix, sizeof prefix, "%s", scrut);
      }
      const NodeList ch = p->as.pattern.children;
      const NodeId *const ids = ast_list(c->ast, ch);
      for (uint32_t i = 0; i < ch.len; i++) {
        const Node *const f = ast_at_const(c->ast, ids[i]);
        char m[128];
        render_ident(c, name_span(c, f->as.pattern.name), m, sizeof m);
        char acc[440];
        snprintf(acc, sizeof acc, "%s.%s", prefix, m);
        const NodeList sub = f->as.pattern.children;
        if (sub.len)
          emit_pattern_binds(c, ast_list(c->ast, sub)[0], acc);
      }
      break;
    }
    case NODE_PATTERN_OR: { // alternatives must bind the same names; emit the first alternative's binds
      const NodeList alts = p->as.pattern.children;
      if (alts.len)
        emit_pattern_binds(c, ast_list(c->ast, alts)[0], scrut);
      break;
    }
    default:
      break; // wildcard / literal / range bind nothing
  }
}

// Emit one arm's body per mode: 0 statement, 1 assign to `result`, 2 `return`.
static void emit_arm_body(Codegen *c, const NodeId body, const int mode, const char *result) {
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
  bool has_guard = false;
  for (uint32_t i = 0; i < arms.len; i++)
    if (ast_at_const(c->ast, ids[i])->as.match_arm.guard != NODE_NONE)
      has_guard = true;

  if (!has_guard) { // a flat else-if chain; each arm's bindings live inside its own block
    for (uint32_t i = 0; i < arms.len; i++) {
      const Node *const arm = ast_at_const(c->ast, ids[i]);
      emit_indent(c);
      emit(c, i ? "else if (" : "if (");
      emit_pattern_test(c, arm->as.match_arm.pattern, scrut);
      emit(c, ") {\n");
      c->depth++;
      emit_pattern_binds(c, arm->as.match_arm.pattern, scrut);
      emit_arm_body(c, arm->as.match_arm.body, mode, result);
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
    return;
  }

  // A guard references the pattern's bindings, which are only in scope *after* emit_pattern_binds, so a
  // flat else-if (guard in the condition) can't see them. Lower to a fallthrough chain inside a
  // do/while(0): `if (test) { binds; if (guard) { body; break; } }`. A failing guard simply falls
  // through to the next arm -- exactly match semantics -- and `break` stops once an arm is taken.
  emit_indent(c);
  emit(c, "do {\n");
  c->depth++;
  for (uint32_t i = 0; i < arms.len; i++) {
    const Node *const arm = ast_at_const(c->ast, ids[i]);
    const NodeId guard = arm->as.match_arm.guard;
    emit_indent(c);
    emit(c, "if (");
    emit_pattern_test(c, arm->as.match_arm.pattern, scrut);
    emit(c, ") {\n");
    c->depth++;
    emit_pattern_binds(c, arm->as.match_arm.pattern, scrut);
    if (guard != NODE_NONE) {
      emit_indent(c);
      emit(c, "if (");
      emit_condition(c, guard);
      emit(c, ") {\n");
      c->depth++;
    }
    emit_arm_body(c, arm->as.match_arm.body, mode, result);
    if (mode != 2) { // a `return` body already exited; otherwise stop scanning further arms
      emit_indent(c);
      emit(c, "break;\n");
    }
    if (guard != NODE_NONE) {
      c->depth--;
      emit_indent(c);
      emit(c, "}\n");
    }
    c->depth--;
    emit_indent(c);
    emit(c, "}\n");
  }
  if (mode != 0) { // value/return position: a guard-only fallthrough would be a bug (typechecker requires a catch-all)
    emit_indent(c);
    emit(c, "__builtin_unreachable();\n");
  }
  c->depth--;
  emit_indent(c);
  emit(c, "} while (0);\n");
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

// Emit a block whose fall-through cleanup runs the defers/drops registered down to `dbase`. The function
// body passes dbase=0 so its owned parameters (registered before the block) are torn down at its close.
static void emit_block_from(Codegen *c, const NodeId id, const uint32_t dbase) {
  const Node *const n = ast_at_const(c->ast, id);
  emit(c, "{\n");
  c->depth++;
  const NodeList stmts = n->as.block.statements;
  const NodeId *const ids = ast_list(c->ast, stmts);
  for (uint32_t i = 0; i < stmts.len; i++) {
    emit_indent(c);
    emit_stmt(c, ids[i]);
  }
  emit_defers_to(c, dbase); // fall-through cleanup
  c->defer_top = dbase;
  c->depth--;
  emit_indent(c);
  emit(c, "}");
}

static void emit_block(Codegen *c, const NodeId id) {
  emit_block_from(c, id, c->defer_top); // defers/drops registered in this block run, reversed, at its close
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
  const uint32_t dbase = c->defer_top; // defers run after the branch's value is computed
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
  emit_defers_to(c, dbase);
  c->defer_top = dbase;
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

static void emit_for(Codegen *c, const NodeId id, const Node *n) {
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
    const uint32_t dbase = c->defer_top;
    for (uint32_t i = 0; i < stmts.len; i++) {
      emit_indent(c);
      emit_stmt(c, sids[i]);
    }
    emit_defers_to(c, dbase);
    c->defer_top = dbase;
    c->depth--;
    emit_indent(c);
    emit(c, "}\n");
    return;
  }
  TypeId selem;
  if (cg_slice_elem(c, ast_type(c->ast, n->as.for_stmt.iterable), &selem)) {
    char s[32], styp[200];
    fresh(c, s, sizeof s);
    render_type_id(c, ast_type(c->ast, n->as.for_stmt.iterable), s, styp, sizeof styp);
    emit(c, "{\n");
    c->depth++;
    emit_indent(c);
    emit_cstr(c, styp); // `Slice__T __scN = <iterable>;`
    emit(c, " = ");
    emit_expr(c, n->as.for_stmt.iterable);
    emit(c, ";\n");
    emit_indent(c);
    emit(c, "for (size_t %s = 0; %s < %s.len; %s++) {\n", idx, idx, s, idx);
    c->depth++;
    emit_indent(c);
    emit_binding(c, selem, name_span(c, n->as.for_stmt.binding), true);
    emit(c, " = %s.ptr[%s];\n", s, idx); // the `.ptr` field is already typed `*const T`
    const uint32_t dbase = c->defer_top;
    for (uint32_t i = 0; i < stmts.len; i++) {
      emit_indent(c);
      emit_stmt(c, sids[i]);
    }
    emit_defers_to(c, dbase);
    c->defer_top = dbase;
    c->depth--;
    emit_indent(c);
    emit(c, "}\n");
    c->depth--;
    emit_indent(c);
    emit(c, "}\n");
    return;
  }
  // Iterator protocol: `for x in it` where `it.next() -> Option<T>`. Lower to a loop calling next() and
  // breaking on the None tag, binding x to the Some payload.
  {
    const Ty *const bt = ast_type_at(c->ast, subst_resolve(c, ast_type(c->ast, n->as.for_stmt.iterable)));
    ModuleId om = 0;
    NodeId od = NODE_NONE;
    if (bt->kind == TYPE_STRUCT) {
      om = bt->module;
      od = bt->as.decl;
    } else if (bt->kind == TYPE_INSTANCE) {
      const TyInstance *const ii = ast_instance(c->ast, bt->as.inst);
      om = ii->module;
      od = ii->decl;
    }
    const DefId nx = od == NODE_NONE ? (DefId){0, NODE_NONE} : cg_find_method_cstr(c, om, od, "next");
    if (nx.node != NODE_NONE) {
      Ast *const na = cg_mod_ast(c, nx.module);
      const NodeList rets = ast_at_const(na, nx.node)->as.function.returns;
      const NodeId r0 = ast_list(na, rets)[0];
      const Node *const rn = ast_at_const(na, r0);
      const DefId opt = ast_resolution_def(na, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : r0); // Option enum
      const TypeId elem = subst_resolve(c, ast_type(c->ast, id));
      if (opt.node != NODE_NONE && elem != TYPE_NONE) {
        // Find Some (payload) and None (unit) variants of Option.
        Ast *const oa = cg_mod_ast(c, opt.module);
        const NodeList mem = ast_at_const(oa, opt.node)->as.aggregate.members;
        const NodeId *const mids = ast_list(oa, mem);
        NodeId some = NODE_NONE, none = NODE_NONE;
        for (uint32_t i = 0; i < mem.len; i++) {
          const Node *const v = ast_at_const(oa, mids[i]);
          if (v->kind != NODE_VARIANT)
            continue;
          const Span vs = ast_at_const(oa, v->as.variant.name)->as.name.text;
          if (span_is(cg_mod_src(c, opt.module), vs, "Some"))
            some = mids[i];
          else if (span_is(cg_mod_src(c, opt.module), vs, "None"))
            none = mids[i];
        }
        if (some != NODE_NONE && none != NODE_NONE) {
          const TypeId optTy = ast_intern_instance(c->ast, opt.module, opt.node, (TypeId[]){elem}, 1);
          char it[32], ov[32], odecl[256], vn[128];
          fresh(c, it, sizeof it);
          fresh(c, ov, sizeof ov);
          render_variant_name(c, opt.module, some, vn, sizeof vn);
          emit(c, "{\n");
          c->depth++;
          emit_indent(c);
          emit(c, "__auto_type %s = ", it); // the iterator (mutable; next is &mut self)
          emit_expr(c, n->as.for_stmt.iterable);
          emit(c, ";\n");
          emit_indent(c);
          emit(c, "for (;;) {\n");
          c->depth++;
          emit_indent(c);
          render_type_id(c, optTy, ov, odecl, sizeof odecl);
          emit_cstr(c, odecl); // `Option__T __o = `
          emit(c, " = ");
          if (bt->kind == TYPE_INSTANCE) {
            char inm[200];
            inst_name(c, ast_instance(c->ast, bt->as.inst), inm, sizeof inm);
            emit_cstr(c, inm);
            emit_paste(c);
            emit(c, "__");
          } else {
            char pfx[64];
            render_modpfx(c, nx.module, pfx, sizeof pfx);
            emit_cstr(c, pfx);
            emit_ident_mod(c, om, ast_at_const(cg_mod_ast(c, om), od)->as.aggregate.name);
            emit(c, "__");
          }
          emit_ident_mod(c, nx.module, ast_at_const(na, nx.node)->as.function.name);
          emit(c, "(&%s);\n", it);
          emit_indent(c);
          emit(c, "if (%s.tag == ", ov);
          emit_tag_mod(c, opt.module, opt.node, none);
          emit(c, ") break;\n");
          emit_indent(c);
          emit_binding(c, elem, name_span(c, n->as.for_stmt.binding), true);
          emit(c, " = %s.payload.%s._0;\n", ov, vn);
          const uint32_t dbase = c->defer_top;
          for (uint32_t i = 0; i < stmts.len; i++) {
            emit_indent(c);
            emit_stmt(c, sids[i]);
          }
          emit_defers_to(c, dbase);
          c->defer_top = dbase;
          c->depth--;
          emit_indent(c);
          emit(c, "}\n");
          c->depth--;
          emit_indent(c);
          emit(c, "}\n");
          return;
        }
      }
    }
  }
  codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: cannot iterate over a non-array/slice value");
}

static void emit_return(Codegen *c, const Node *n) {
  const NodeList vals = n->as.return_stmt.values;
  const NodeId *const vids = ast_list(c->ast, vals);
  // With pending defers, evaluate the return value first, run every live defer (innermost-out), then
  // return -- so a `defer x.close()` runs after `return x.read()` is computed (Go-style ordering).
  if (c->defer_top > 0) {
    emit(c, "{\n");
    c->depth++;
    if (vals.len == 0) {
      emit_defers_to(c, 0);
      emit_indent(c);
      emit(c, "return;\n");
    } else {
      char rv[32];
      fresh(c, rv, sizeof rv);
      emit_indent(c);
      if (c->current_ret[0]) { // multi-return struct, or array-by-value wrapper
        emit(c, "%s %s = (%s){ ", c->current_ret, rv, c->current_ret);
        if (vals.len == 1 && ast_at_const(c->ast, vids[0])->kind == NODE_ARRAY_LITERAL) {
          emit_array_braces(c, ast_at_const(c->ast, vids[0]));
        } else {
          for (uint32_t i = 0; i < vals.len; i++) {
            if (i)
              emit(c, ", ");
            emit_expr(c, vids[i]);
          }
        }
        emit(c, " };\n");
      } else { // single value (a `return switch` lowers to a stmt-expression via emit_expr)
        emit(c, "__auto_type %s = ", rv);
        emit_expr(c, vids[0]);
        emit(c, ";\n");
      }
      emit_defers_to(c, 0);
      emit_indent(c);
      emit(c, "return %s;\n", rv);
    }
    c->depth--;
    emit_indent(c);
    emit(c, "}\n");
    return;
  }
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
    if (c->current_ret[0]) { // array-by-value return: pack the value into the wrapper struct
      emit(c, "return (%s){ ", c->current_ret);
      if (ast_at_const(c->ast, vids[0])->kind == NODE_ARRAY_LITERAL)
        emit_array_braces(c, ast_at_const(c->ast, vids[0]));
      else
        emit_expr(c, vids[0]);
      emit(c, " };\n");
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

static void emit_defers_to(Codegen *c, const uint32_t base) {
  for (uint32_t i = c->defer_top; i-- > base;) {
    emit_indent(c);
    if (c->defer_kind[i] == 1) // an automatic RAII drop of a local binding
      emit_auto_drop(c, c->defer_stack[i]);
    else
      emit_expr_stmt(c, c->defer_stack[i]);
  }
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
    // const iff the binding is immutable (`let` without `mut`); mutability is a binding property only.
    const bool element_const = !n->as.let_stmt.is_mutable;
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

// `static_assert(cond, "msg")` -> C `_Static_assert(cond, "msg")`. The C compiler evaluates the
// constant condition; the message is a bare C string literal (C11 requires one, so synthesize a default).
static void emit_static_assert(Codegen *c, const Node *const n) {
  emit(c, "_Static_assert(");
  emit_expr(c, n->as.binary.left);
  emit(c, ", ");
  if (n->as.binary.right != NODE_NONE)
    emit_reescaped(c, ast_at_const(c->ast, n->as.binary.right)->as.literal.raw, false);
  else
    emit(c, "\"static assertion failed\"");
  emit(c, ");\n");
}

// The `drop` method of a type that implements the Drop interface (`extend T as Drop`), or {_,NODE_NONE}.
// Only an explicit `as Drop` impl opts a type into RAII auto-drop. Searches the type's home + current module.
static DefId cg_drop_method(Codegen *c, const ModuleId tmod, const NodeId tdecl) {
  const ModuleId scopes[2] = {tmod, c->ast->module};
  const int ns = tmod == c->ast->module ? 1 : 2;
  for (int s = 0; s < ns; s++) {
    const ModuleId m = scopes[s];
    Ast *const a = cg_mod_ast(c, m);
    const NodeList items = ast_at_const(a, a->root)->as.program.items;
    const NodeId *const ids = ast_list(a, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const it = ast_at_const(a, ids[i]);
      if (it->kind != NODE_IMPL || it->as.impl_def.trait_type == NODE_NONE || it->as.impl_def.target_type == NODE_NONE)
        continue;
      const DefId tg = ast_resolution_def(a, it->as.impl_def.target_type);
      if (tg.module != tmod || tg.node != tdecl)
        continue;
      const DefId tr = ast_resolution_def(a, it->as.impl_def.trait_type);
      if (tr.node == NODE_NONE)
        continue;
      const Node *const trn = ast_at_const(cg_mod_ast(c, tr.module), tr.node);
      if (trn->kind != NODE_TRAIT ||
          !span_is(cg_mod_src(c, tr.module), ast_at_const(cg_mod_ast(c, tr.module), trn->as.trait_def.name)->as.name.text, "Drop"))
        continue;
      const NodeList ms = it->as.impl_def.items;
      const NodeId *const mids = ast_list(a, ms);
      for (uint32_t j = 0; j < ms.len; j++) {
        const Node *const mn = ast_at_const(a, mids[j]);
        if (mn->kind == NODE_FUNCTION && span_is(cg_mod_src(c, m), ast_at_const(a, mn->as.function.name)->as.name.text, "drop"))
          return (DefId){m, mids[j]};
      }
    }
  }
  return (DefId){0, NODE_NONE};
}

// Does the (subst-resolved) type implement the Drop interface? Such a value owns resources -> it gets an
// RAII destructor at scope exit, and a binding/param of it is emitted non-`const` (drop takes `&mut self`).
static bool cg_type_is_drop(Codegen *c, const TypeId ty) {
  const Ty *const y = ast_type_at(c->ast, subst_resolve(c, ty));
  ModuleId om;
  NodeId od;
  if (y->kind == TYPE_STRUCT) {
    om = y->module;
    od = y->as.decl;
  } else if (y->kind == TYPE_INSTANCE) {
    const TyInstance *const ii = ast_instance(c->ast, y->as.inst);
    om = ii->module;
    od = ii->decl;
  } else {
    return false;
  }
  return cg_drop_method(c, om, od).node != NODE_NONE;
}

// Was the local `decl` moved out somewhere in the current function (so it must not be auto-dropped)?
static bool cg_is_moved(const Codegen *c, const NodeId decl) {
  for (uint32_t i = 0; i < c->nmoved; i++)
    if (c->moved[i] == decl)
      return true;
  return false;
}

// Record `expr` as a move if it is a bare reference to a current-module owned binding (a `let` or a
// by-value parameter) -- ownership transfers to another owner (`let`, `return`, assignment, struct field,
// or a by-value call argument), so the source must not be auto-dropped here.
static void cg_mark_move(Codegen *c, const NodeId expr) {
  if (expr == NODE_NONE || ast_at_const(c->ast, expr)->kind != NODE_IDENTIFIER)
    return;
  const DefId d = ast_resolution_def(c->ast, expr);
  if (d.module != c->ast->module || d.node == NODE_NONE)
    return;
  const NodeKind dk = ast_at_const(c->ast, d.node)->kind;
  if (dk != NODE_LET && dk != NODE_PARAMETER)
    return;
  if (c->nmoved < (uint32_t)(sizeof c->moved / sizeof c->moved[0]))
    c->moved[c->nmoved++] = d.node;
}

// Pre-pass over a function body collecting moved local bindings (so RAII skips dropping them). A move is a
// bare binding used as a `let` initializer, an assignment RHS, a returned value, or a struct field value.
static void cg_scan_moves(Codegen *c, const NodeId id) {
  if (id == NODE_NONE)
    return;
  const Node *const n = ast_at_const(c->ast, id);
  switch (n->kind) {
    case NODE_BLOCK: {
      const NodeList ss = n->as.block.statements;
      const NodeId *const ids = ast_list(c->ast, ss);
      for (uint32_t i = 0; i < ss.len; i++)
        cg_scan_moves(c, ids[i]);
      break;
    }
    case NODE_LET:
      cg_mark_move(c, n->as.let_stmt.value);
      cg_scan_moves(c, n->as.let_stmt.value);
      break;
    case NODE_RETURN: {
      const NodeList vs = n->as.return_stmt.values;
      const NodeId *const ids = ast_list(c->ast, vs);
      for (uint32_t i = 0; i < vs.len; i++) {
        cg_mark_move(c, ids[i]);
        cg_scan_moves(c, ids[i]);
      }
      break;
    }
    case NODE_ASSIGNMENT:
      cg_mark_move(c, n->as.binary.right);
      cg_scan_moves(c, n->as.binary.left);
      cg_scan_moves(c, n->as.binary.right);
      break;
    case NODE_STRUCT_INITIALIZER: {
      const NodeList fs = n->as.struct_initializer.fields;
      const NodeId *const ids = ast_list(c->ast, fs);
      for (uint32_t i = 0; i < fs.len; i++) {
        const NodeId v = ast_at_const(c->ast, ids[i])->as.field_initializer.value;
        cg_mark_move(c, v);
        cg_scan_moves(c, v);
      }
      break;
    }
    case NODE_IF:
      cg_scan_moves(c, n->as.if_stmt.condition);
      cg_scan_moves(c, n->as.if_stmt.then_branch);
      cg_scan_moves(c, n->as.if_stmt.else_branch);
      break;
    case NODE_WHILE:
      cg_scan_moves(c, n->as.while_stmt.condition);
      cg_scan_moves(c, n->as.while_stmt.body);
      break;
    case NODE_FOR:
      cg_scan_moves(c, n->as.for_stmt.iterable);
      cg_scan_moves(c, n->as.for_stmt.body);
      break;
    case NODE_MATCH: {
      cg_scan_moves(c, n->as.match_expr.value);
      const NodeList arms = n->as.match_expr.arms;
      const NodeId *const ids = ast_list(c->ast, arms);
      for (uint32_t i = 0; i < arms.len; i++)
        cg_scan_moves(c, ast_at_const(c->ast, ids[i])->as.match_arm.body);
      break;
    }
    case NODE_EXPRESSION_STATEMENT:
    case NODE_DEFER:
      cg_scan_moves(c, n->as.single.value);
      break;
    case NODE_CALL: {
      cg_scan_moves(c, n->as.call.callee);
      const NodeList args = n->as.call.args;
      const NodeId *const ids = ast_list(c->ast, args);
      for (uint32_t i = 0; i < args.len; i++) {
        cg_mark_move(c, ids[i]); // a by-value argument moves the binding to the callee (which owns/drops it)
        cg_scan_moves(c, ids[i]);
      }
      break;
    }
    case NODE_BINARY:
      cg_scan_moves(c, n->as.binary.left);
      cg_scan_moves(c, n->as.binary.right);
      break;
    case NODE_UNARY:
      cg_scan_moves(c, n->as.unary.operand);
      break;
    case NODE_MEMBER:
      cg_scan_moves(c, n->as.member.object);
      break;
    case NODE_INDEX:
      cg_scan_moves(c, n->as.index.object);
      cg_scan_moves(c, n->as.index.index);
      break;
    case NODE_CAST:
      cg_scan_moves(c, n->as.cast.expression);
      break;
    default:
      break;
  }
}

// Whether the binding at `id` (a `let` or a by-value parameter) holds a Drop-implementing, not-moved value
// -- i.e. it gets a scope-exit RAII drop. Such a let is emitted non-`const` (its destructor takes `&mut self`).
static bool cg_will_auto_drop(Codegen *c, const NodeId id) {
  const Node *const n = ast_at_const(c->ast, id);
  if (n->kind == NODE_LET && ast_at_const(c->ast, n->as.let_stmt.name)->kind == NODE_PATTERN_TUPLE)
    return false;
  if (cg_is_moved(c, id))
    return false;
  return cg_type_is_drop(c, ast_type(c->ast, id));
}

// Register an automatic drop on the scope-exit cleanup stack (RAII), in the same reverse-order sequence
// as `defer`. Caller has already confirmed cg_will_auto_drop.
static void cg_register_auto_drop(Codegen *c, const NodeId id) {
  if (c->defer_top >= (uint32_t)(sizeof c->defer_stack / sizeof c->defer_stack[0]))
    return;
  c->defer_stack[c->defer_top] = id; // the let node; emit_defers_to reads its binding name + type
  c->defer_kind[c->defer_top] = 1;
  c->defer_top++;
}

// Emit the RAII destructor call for the binding (`let` or by-value param) at `bid`: `Type__drop(&name)`.
static void emit_auto_drop(Codegen *c, const NodeId bid) {
  const Node *const ln = ast_at_const(c->ast, bid);
  const TypeId bt = subst_resolve(c, ast_type(c->ast, bid));
  const Ty *const y = ast_type_at(c->ast, bt);
  ModuleId om;
  NodeId od;
  if (y->kind == TYPE_INSTANCE) {
    const TyInstance *const ii = ast_instance(c->ast, y->as.inst);
    om = ii->module;
    od = ii->decl;
  } else if (y->kind == TYPE_STRUCT) {
    om = y->module;
    od = y->as.decl;
  } else {
    return;
  }
  const DefId dm = cg_drop_method(c, om, od);
  if (dm.node == NODE_NONE)
    return;
  if (y->kind == TYPE_INSTANCE) {
    char inm[200];
    inst_name(c, ast_instance(c->ast, y->as.inst), inm, sizeof inm);
    emit_cstr(c, inm);
    emit_paste(c);
    emit(c, "__");
  } else {
    char pfx[64];
    render_modpfx(c, dm.module, pfx, sizeof pfx);
    emit_cstr(c, pfx);
    emit_ident_mod(c, om, ast_at_const(cg_mod_ast(c, om), od)->as.aggregate.name);
    emit(c, "__");
  }
  emit_ident_mod(c, dm.module, ast_at_const(cg_mod_ast(c, dm.module), dm.node)->as.function.name);
  char nm[128];
  const NodeId nameNode = ln->kind == NODE_PARAMETER ? ln->as.parameter.name : ln->as.let_stmt.name;
  render_ident(c, name_span(c, nameNode), nm, sizeof nm);
  emit(c, "(&%s);\n", nm);
}

static void emit_stmt(Codegen *c, const NodeId id) {
  if (id == NODE_NONE)
    return;
  const Node *const n = ast_at_const(c->ast, id);
  switch (n->kind) {
    case NODE_STATIC_ASSERT:
      emit_static_assert(c, n);
      break;
    case NODE_BLOCK:
      emit_block(c, id);
      emit(c, "\n");
      break;
    case NODE_LET: {
      if (ast_at_const(c->ast, n->as.let_stmt.name)->kind == NODE_PATTERN_TUPLE) {
        emit_tuple_let(c, n);
        break;
      }
      // const iff the binding is immutable (`let` without `mut`). Calling a `&mut self` method on an
      // immutable binding is rejected by the typechecker (receiver_mutable), so const never blocks a valid one.
      // A Drop-managed binding is emitted non-const, since its scope-exit destructor takes `&mut self`.
      const bool autodrop = cg_will_auto_drop(c, id);
      const bool is_const = !n->as.let_stmt.is_mutable && !autodrop;
      // Value-semantics array copy: an array bound from a non-literal source (another array, or an
      // array-returning call) can't use C array initialization -> declare, then memcpy. The length comes
      // from the annotation, or from the source call's return type (the binding's TypeId has lost it).
      const TypeId lbt = ast_type(c->ast, id);
      const NodeId lval = n->as.let_stmt.value;
      if (lval != NODE_NONE && lbt != TYPE_NONE && ast_type_at(c->ast, lbt)->kind == TYPE_ARRAY &&
          ast_at_const(c->ast, lval)->kind != NODE_ARRAY_LITERAL) {
        NodeId arrtn = n->as.let_stmt.type;
        if (arrtn == NODE_NONE && ast_at_const(c->ast, lval)->kind == NODE_CALL) {
          const DefId fd = ast_resolution_def(c->ast, ast_at_const(c->ast, lval)->as.call.callee);
          if (fd.node != NODE_NONE && fd.module == c->ast->module && ast_at_const(c->ast, fd.node)->kind == NODE_FUNCTION)
            arrtn = fn_array_return(c, fd.node);
        }
        if (arrtn != NODE_NONE) {
          char nm[128], decl[300];
          render_ident(c, name_span(c, n->as.let_stmt.name), nm, sizeof nm);
          render_binding_node(c, arrtn, nm, false, decl, sizeof decl); // non-const: memcpy writes it next
          emit_cstr(c, decl);
          emit(c, "; memcpy(%s, ", nm);
          emit_expr(c, lval);
          emit(c, ", sizeof(%s));\n", nm);
          break;
        }
      }
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
      if (autodrop)
        cg_register_auto_drop(c, id); // RAII: schedule a scope-exit drop
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
    case NODE_WHILE: {
      const uint32_t saved_ldb = c->loop_defer_base; // break/continue run defers down to here
      c->loop_defer_base = c->defer_top;
      if (n->as.while_stmt.is_do) {
        emit(c, "do ");
        emit_block(c, n->as.while_stmt.body);
        emit(c, " while ");
        emit_condition(c, n->as.while_stmt.condition);
        emit(c, ";\n");
      } else {
        emit(c, "while ");
        emit_condition(c, n->as.while_stmt.condition);
        emit(c, " ");
        emit_block(c, n->as.while_stmt.body);
        emit(c, "\n");
      }
      c->loop_defer_base = saved_ldb;
      break;
    }
    case NODE_FOR: {
      const uint32_t saved_ldb = c->loop_defer_base;
      c->loop_defer_base = c->defer_top;
      emit_for(c, id, n);
      c->loop_defer_base = saved_ldb;
      break;
    }
    case NODE_BREAK:
    case NODE_CONTINUE: {
      const char *const kw = n->kind == NODE_BREAK ? "break" : "continue";
      // run only the defers registered inside the innermost loop, then jump
      if (c->defer_top > c->loop_defer_base) {
        emit(c, "{\n");
        c->depth++;
        emit_defers_to(c, c->loop_defer_base);
        emit_indent(c);
        emit(c, "%s;\n", kw);
        c->depth--;
        emit_indent(c);
        emit(c, "}\n");
      } else {
        emit(c, "%s;\n", kw);
      }
      break;
    }
    case NODE_DEFER:
      // Registered, not emitted here: the enclosing scope runs it (reversed) at every exit path.
      if (c->defer_top >= (uint32_t)(sizeof c->defer_stack / sizeof c->defer_stack[0]))
        codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: too many nested 'defer' statements");
      else {
        c->defer_kind[c->defer_top] = 0;
        c->defer_stack[c->defer_top++] = n->as.single.value;
      }
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
  const NodeId *const ids = ast_list(c->ast, params);
  size_t k = 0;
  out[0] = '\0';
  bool any = false;
  for (uint32_t i = 0; i < params.len && k < cap; i++) {
    if (ids[i] == c->cb_param) // an elided callback parameter (inside a Win-1 specialization)
      continue;
    const Node *const p = ast_at_const(c->ast, ids[i]);
    char nm[128], d[300];
    render_ident(c, name_span(c, p->as.parameter.name), nm, sizeof nm);
    // `mut p` -> non-const; a by-value Drop param is also non-const (it is owned and its destructor mutates it).
    const bool pconst = !p->as.parameter.is_mutable && !cg_type_is_drop(c, ast_type(c->ast, ids[i]));
    render_binding_node(c, p->as.parameter.type, nm, pconst, d, sizeof d);
    if (any)
      k = buf_append(out, cap, k, ", ");
    k = buf_append(out, cap, k, d);
    any = true;
  }
  if (!any)
    buf_join3(out, cap, "void", "", "");
}

// Build a function's C name: `<mod>__name`, or `<mod>__Target__name` for an impl method. `prefixed`
// is false for extern (FFI) functions; the program entry `main` is never prefixed either.
// `target` is the receiver type (a DefId; .node == NODE_NONE for a free function). The module prefix is
// always this (the emitting) module, so a local `extend foreign::T` method is mangled by the module that
// declares it (`extender__T__m`); the type-name segment is read from the target type's own module.
// The number of `from` (or `try_from`) methods across all impls targeting (tmod,tdecl). A type with more
// than one `From`/`TryFrom` impl needs each symbol disambiguated by its source type (Celsius__from__u8).
static int cg_conv_count(Codegen *c, const ModuleId tmod, const NodeId tdecl, const char *const lit) {
  int n = 0;
  const ModuleId scopes[2] = {tmod, c->ast->module};
  const int ns = tmod == c->ast->module ? 1 : 2;
  for (int s = 0; s < ns; s++) {
    const ModuleId m = scopes[s];
    Ast *const a = cg_mod_ast(c, m);
    const NodeList items = ast_at_const(a, a->root)->as.program.items;
    const NodeId *const ids = ast_list(a, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const it = ast_at_const(a, ids[i]);
      if (it->kind != NODE_IMPL || it->as.impl_def.target_type == NODE_NONE)
        continue;
      const DefId tg = ast_resolution_def(a, it->as.impl_def.target_type);
      if (tg.module != tmod || tg.node != tdecl)
        continue;
      const NodeList ms = it->as.impl_def.items;
      const NodeId *const mids = ast_list(a, ms);
      for (uint32_t j = 0; j < ms.len; j++) {
        const Node *const mn = ast_at_const(a, mids[j]);
        if (mn->kind == NODE_FUNCTION && span_is(cg_mod_src(c, m), ast_at_const(a, mn->as.function.name)->as.name.text, lit))
          n++;
      }
    }
  }
  return n;
}

// If `lit` ("from"/"try_from") names an overloaded conversion of `target` (several such impls), append
// `__<srcMangle>` so the overloads get distinct C symbols. `srcTy` is the source type to mangle (the method's
// value-param type at a definition; the call's source/arg type at a call site) -- equal for an exact-source
// match, which is how the def and the call agree on the symbol. A no-op otherwise.
static void cg_conv_suffix(Codegen *c, const DefId target, const char *const lit, const TypeId srcTy, char *out,
                           const size_t cap) {
  if (cap)
    out[0] = '\0';
  if (target.node == NODE_NONE || srcTy == TYPE_NONE || !lit || cg_conv_count(c, target.module, target.node, lit) < 2)
    return;
  size_t at = buf_append(out, cap, 0, "__");
  char e[176];
  mangle_type(c, subst_resolve(c, srcTy), e, sizeof e);
  buf_append(out, cap, at, e);
}

// "from"/"try_from"/NULL for a method-name span, in its own module's source.
static const char *cg_conv_lit(Codegen *c, const ModuleId m, const Span name) {
  if (span_is(cg_mod_src(c, m), name, "from"))
    return "from";
  if (span_is(cg_mod_src(c, m), name, "try_from"))
    return "try_from";
  return NULL;
}

static void function_name(Codegen *c, const NodeId fn, const DefId target, char *out, const size_t cap, const bool prefixed) {
  if (cg_symbol_override(c, c->ast->module, fn, out, cap)) // `@c.export`/`@c.import`: the exact C symbol
    return;
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
  k += render_ident(c, fname, out + k, cap - k);
  // Overloaded `from`/`try_from`: disambiguate by the value-param's type so the impls get distinct symbols.
  const NodeList params = ast_at_const(c->ast, fn)->as.function.params;
  const char *const lit = cg_conv_lit(c, c->ast->module, fname);
  if (lit && target.node != NODE_NONE && params.len) {
    const NodeId p0 = ast_list(c->ast, params)[0];
    cg_conv_suffix(c, target, lit, ast_type(c->ast, ast_at_const(c->ast, p0)->as.parameter.type), out + k, cap - k);
  }
}

// Emit a function signature; with_body emits the block, otherwise a prototype `;`. `extern_q`
// prefixes `extern`. Sets current_ret for multi-return so NODE_RETURN can build the struct.
static void emit_function(Codegen *c, const NodeId fn_id, const DefId target, const bool extern_q,
                          const bool with_body, const char *const name_override, const bool spec_static) {
  const Node *const fn = ast_at_const(c->ast, fn_id);
  char nm[256];
  if (name_override)
    buf_append(nm, sizeof nm, 0, name_override); // a monomorphized specialization's mangled name
  else
    function_name(c, fn_id, target, nm, sizeof nm, !extern_q);
  // In a multi-module package a non-`pub` function is module-private: emit it `static` so it never
  // gets external linkage (its prototype is kept in the .c, not the public header). `main` and FFI
  // declarations are never static. A specialization's linkage is decided by the caller (`spec_static`):
  // a free-function spec is file-local (per-module-static), a public method spec is a real owned symbol.
  const bool is_main = target.node == NODE_NONE && !name_override && span_is(c->source, name_span(c, fn->as.function.name), "main");
  const bool exported = cg_attr(c, c->ast->module, fn_id, ATTR_EXPORT) != NULL; // external linkage, never static
  const bool is_static = name_override ? spec_static
                                       : (c->multifile && !extern_q && !is_main && !exported && !fn->as.function.is_public);
  char ps[1024];
  render_params(c, fn->as.function.params, ps, sizeof ps);
  if (fn->as.function.is_variadic && strcmp(ps, "void") != 0) // a defined variadic fn keeps its C `...`
    buf_append(ps, sizeof ps, strlen(ps), ", ...");
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

  // `@c.*` qualifiers: portable C keywords (`_Noreturn` / `inline`) plus a combined GNU `__attribute__`.
  const ModuleId fmod = c->ast->module;
  if (cg_attr(c, fmod, fn_id, ATTR_NORETURN))
    emit(c, "_Noreturn ");
  if (cg_attr(c, fmod, fn_id, ATTR_INLINE) || cg_attr(c, fmod, fn_id, ATTR_ALWAYS_INLINE))
    emit(c, "inline ");
  {
    char g[256];
    g[0] = '\0';
    size_t gn = 0;
#define ADDG(s)                                                                                                        \
  do {                                                                                                                 \
    if (gn)                                                                                                            \
      gn = buf_append(g, sizeof g, gn, ", ");                                                                          \
    gn = buf_append(g, sizeof g, gn, (s));                                                                             \
  } while (0)
    if (cg_attr(c, fmod, fn_id, ATTR_ALWAYS_INLINE))
      ADDG("always_inline");
    if (cg_attr(c, fmod, fn_id, ATTR_NOINLINE))
      ADDG("noinline");
    if (cg_attr(c, fmod, fn_id, ATTR_USED))
      ADDG("used");
    if (cg_attr(c, fmod, fn_id, ATTR_UNUSED))
      ADDG("unused");
    const Attr *const sec = cg_attr(c, fmod, fn_id, ATTR_SECTION);
    if (sec) {
      char sb[160];
      char nm2[128];
      size_t nl = sec->str.end - sec->str.start;
      if (nl >= sizeof nm2)
        nl = sizeof nm2 - 1;
      memcpy(nm2, cg_mod_src(c, fmod) + sec->str.start, nl);
      nm2[nl] = '\0';
      snprintf(sb, sizeof sb, "section(\"%s\")", nm2);
      ADDG(sb);
    }
#undef ADDG
    if (gn)
      emit(c, "__attribute__((%s)) ", g);
  }

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
  } else if (fn_array_return(c, fn_id) != NODE_NONE) {
    // array-by-value return: emit the wrapper struct as the return type; current_ret makes RETURN wrap it.
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
    c->defer_top = 0; // each function body is a fresh defer scope
    c->loop_defer_base = 0;
    c->nmoved = 0; // RAII: collect bindings moved out of this body, so their auto-drop is elided
    cg_scan_moves(c, fn->as.function.body);
    // A by-value Drop parameter is owned by this function -> drop it at scope exit (unless moved). Pushed
    // first so params are torn down LAST (after locals), preserving reverse-construction order.
    const NodeList ps = fn->as.function.params;
    const NodeId *const pids = ast_list(c->ast, ps);
    for (uint32_t i = 0; i < ps.len; i++)
      if (cg_will_auto_drop(c, pids[i]))
        cg_register_auto_drop(c, pids[i]);
    emit_block_from(c, fn->as.function.body, 0); // base 0: the body's close also drops owned parameters
    emit(c, "\n\n");
  } else {
    emit(c, ";\n");
  }
}

// `<mod>__closure_<nodeid>`: a hoisted closure's C symbol. The NodeId is unique within the module, so the
// name is stable across the prototype, the definition and every value reference to the closure.
static void closure_name(Codegen *c, const NodeId id, char *out, const size_t cap) {
  size_t k = render_modpfx(c, c->ast->module, out, cap);
  k = buf_append(out, cap, k, "closure_");
  char idb[16];
  snprintf(idb, sizeof idb, "%u", (unsigned)id);
  buf_append(out, cap, k, idb);
}

// Emit a hoisted closure as a file-local `static` function: a prototype when !with_body, else the body. A
// compact closure (`expr_body`) returns its body expression; an anonymous `fn` emits its block verbatim.
static void emit_closure_fn(Codegen *c, const NodeId id, const bool with_body) {
  const Node *const n = ast_at_const(c->ast, id);
  char nm[200];
  closure_name(c, id, nm, sizeof nm);
  char ps[1024];
  render_params(c, n->as.closure.params, ps, sizeof ps);
  char decl[1300];
  size_t at = buf_append(decl, sizeof decl, 0, nm);
  at = buf_append(decl, sizeof decl, at, "(");
  at = buf_append(decl, sizeof decl, at, ps);
  buf_append(decl, sizeof decl, at, ")");

  const NodeId body = n->as.closure.body;
  const bool expr_body = n->as.closure.expr_body;
  const TypeId rt = expr_body ? ast_type(c->ast, body) : TYPE_NONE;
  emit(c, "static ");
  char out[1400];
  if (expr_body) {
    render_type_id(c, rt, decl, out, sizeof out);
  } else {
    const NodeList rets = n->as.closure.returns;
    if (rets.len == 1) {
      const NodeId r0 = ast_list(c->ast, rets)[0];
      const Node *const rn = ast_at_const(c->ast, r0);
      render_type_node(c, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : r0, decl, out, sizeof out);
    } else {
      buf_join3(out, sizeof out, "void ", "", decl);
    }
  }
  emit_cstr(c, out);
  if (!with_body) {
    emit(c, ";\n");
    return;
  }
  c->current_ret[0] = '\0';
  if (expr_body) {
    const Ty *const rty = rt != TYPE_NONE ? ast_type_at(c->ast, rt) : NULL;
    const bool is_void = rty && rty->kind == TYPE_BUILTIN && rty->as.builtin == BT_VOID;
    emit(c, " {\n");
    c->depth++;
    emit_indent(c);
    if (!is_void)
      emit(c, "return ");
    emit_expr(c, body);
    emit(c, ";\n");
    c->depth--;
    emit(c, "}\n\n");
  } else {
    emit(c, " ");
    c->defer_top = 0; // a closure body is its own defer scope
    c->loop_defer_base = 0;
    emit_block(c, body);
    emit(c, "\n\n");
  }
}

// Hoist every closure in this module to a top-level static function (prototypes, then definitions). The
// flat node scan finds closures at any nesting depth; they are emitted in the module that defines them.
static void emit_closures(Codegen *c, const bool with_body) {
  for (size_t i = 0; i < c->ast->nodes.len; i++)
    if (c->ast->nodes.data[i].kind == NODE_CLOSURE)
      emit_closure_fn(c, (NodeId)i, with_body);
}

// --- Win 1: callback specialization ---------------------------------------------------------------
// A same-module free function called with a statically-known non-capturing callback is specialized per
// callee: the callback parameter is elided and the inner indirect call becomes a direct call. The
// pointer original is kept only when still needed (the fn is `pub`, or some call passes a runtime value).

// Is `arg` a statically-known non-capturing callee (a defined named fn, or a closure literal)? Fills its
// DefId and whether it is a closure node. Extern/prototype-only fns and runtime values are not "known".
static bool cb_known_callee(Codegen *c, const NodeId arg, DefId *const out, bool *const is_closure) {
  const Node *const a = ast_at_const(c->ast, arg);
  if (a->kind == NODE_CLOSURE) {
    *out = (DefId){c->ast->module, arg};
    *is_closure = true;
    return true;
  }
  if (a->kind == NODE_IDENTIFIER) {
    const DefId d = ast_resolution_def(c->ast, arg);
    if (d.node != NODE_NONE) {
      const Node *const dn = ast_at_const(cg_mod_ast(c, d.module), d.node);
      if (dn->kind == NODE_FUNCTION && dn->as.function.body != NODE_NONE) {
        *out = d;
        *is_closure = false;
        return true;
      }
    }
  }
  return false;
}

// `<fn>__cb_<callee>`: a specialization's C name, stable across its prototype, body and every call site.
static void cb_spec_name(Codegen *c, const DefId fn, const DefId callee, const bool is_closure, char *out, const size_t cap) {
  function_name(c, fn.node, (DefId){0, NODE_NONE}, out, cap, true);
  size_t at = buf_append(out, cap, strlen(out), "__cb_");
  char sym[200];
  if (is_closure)
    closure_name(c, callee.node, sym, sizeof sym);
  else
    render_qualified(c, callee.module, ast_at_const(cg_mod_ast(c, callee.module), callee.node)->as.function.name, sym, sizeof sym);
  buf_append(out, cap, at, sym);
}

// A function qualifies for callback specialization when it has exactly one `fn(..) ..`-typed parameter;
// `*cbidx`/`*param` name it. (Zero or multiple callback params keep the pointer form.)
static bool cb_single_callback_param(Codegen *c, const Node *const fnnode, uint32_t *const cbidx, NodeId *const param) {
  const NodeList ps = fnnode->as.function.params;
  const NodeId *const pids = ast_list(c->ast, ps);
  int found = -1;
  for (uint32_t i = 0; i < ps.len; i++) {
    const NodeId tn = ast_at_const(c->ast, pids[i])->as.parameter.type;
    if (tn != NODE_NONE && ast_at_const(c->ast, tn)->kind == NODE_FUNCTION_TYPE) {
      if (found >= 0)
        return false;
      found = (int)i;
    }
  }
  if (found < 0)
    return false;
  *cbidx = (uint32_t)found;
  *param = pids[found];
  return true;
}

// Is the callback parameter referenced ONLY as the callee of a call? (If it is stored, returned or passed
// on, eliding it would be unsound, so such a function keeps the pointer form.) The param decl is unique
// and only referenced inside its own function, so a whole-module count is exact.
static bool param_only_callee(Codegen *c, const NodeId param) {
  uint32_t uses = 0, callees = 0;
  for (uint32_t i = 0; i < c->ast->nodes.len; i++) {
    const Node *const n = ast_at_const(c->ast, i);
    if (n->kind == NODE_IDENTIFIER) {
      const DefId d = ast_resolution_def(c->ast, i);
      if (d.module == c->ast->module && d.node == param)
        uses++;
    } else if (n->kind == NODE_CALL) {
      const NodeId ce = n->as.call.callee;
      if (ast_at_const(c->ast, ce)->kind == NODE_IDENTIFIER) {
        const DefId d = ast_resolution_def(c->ast, ce);
        if (d.module == c->ast->module && d.node == param)
          callees++;
      }
    }
  }
  return uses == callees;
}

static void cb_record(Codegen *c, const DefId fn, const NodeId param, const uint32_t cbidx, const DefId callee, const bool is_closure) {
  for (int i = 0; i < c->n_cb_insts; i++)
    if (c->cb_insts[i].fn.node == fn.node && c->cb_insts[i].fn.module == fn.module &&
        c->cb_insts[i].callee.node == callee.node && c->cb_insts[i].callee.module == callee.module &&
        c->cb_insts[i].callee_closure == is_closure)
      return;
  if (c->n_cb_insts >= (int)(sizeof c->cb_insts / sizeof c->cb_insts[0]))
    return;
  c->cb_insts[c->n_cb_insts].fn = fn;
  c->cb_insts[c->n_cb_insts].param = param;
  c->cb_insts[c->n_cb_insts].cbidx = cbidx;
  c->cb_insts[c->n_cb_insts].callee = callee;
  c->cb_insts[c->n_cb_insts].callee_closure = is_closure;
  c->n_cb_insts++;
}

static void cb_keep(Codegen *c, const NodeId fn) {
  for (int i = 0; i < c->n_cb_keep; i++)
    if (c->cb_keep_fns[i] == fn)
      return;
  if (c->n_cb_keep < (int)(sizeof c->cb_keep_fns / sizeof c->cb_keep_fns[0]))
    c->cb_keep_fns[c->n_cb_keep++] = fn;
}

// Scan this module's call sites for specializable callback calls (deduplicated). A call whose callback is
// a runtime value marks the function as still needing its pointer original.
static void collect_callbacks(Codegen *c) {
  c->n_cb_insts = 0;
  c->n_cb_keep = 0;
  for (uint32_t i = 0; i < c->ast->nodes.len; i++) {
    const Node *const call = ast_at_const(c->ast, i);
    if (call->kind != NODE_CALL)
      continue;
    const NodeId callee_id = call->as.call.callee;
    if (ast_at_const(c->ast, callee_id)->kind != NODE_IDENTIFIER)
      continue;
    const DefId fn = ast_resolution_def(c->ast, callee_id);
    if (fn.module != c->ast->module || fn.node == NODE_NONE)
      continue;
    const Node *const fnnode = ast_at_const(c->ast, fn.node);
    if (fnnode->kind != NODE_FUNCTION || fnnode->as.function.generics.len || fnnode->as.function.body == NODE_NONE)
      continue;
    if (!decl_is_toplevel(c, fn.module, fn.node)) // free functions only; methods keep the pointer form
      continue;
    uint32_t cbidx;
    NodeId param;
    if (!cb_single_callback_param(c, fnnode, &cbidx, &param) || !param_only_callee(c, param))
      continue;
    const NodeList args = call->as.call.args;
    const NodeId *const aids = ast_list(c->ast, args);
    DefId callee;
    bool isclo;
    if (cbidx < args.len && cb_known_callee(c, aids[cbidx], &callee, &isclo))
      cb_record(c, fn, param, cbidx, callee, isclo);
    else
      cb_keep(c, fn.node); // a runtime / unknown callback -> the pointer original is still needed
  }
}

// A private free function whose every same-module call was specialized away: its pointer original would be
// unused, so it is not emitted. (`pub` fns keep external linkage; any runtime caller keeps the original.)
static bool cb_specialized_away(Codegen *c, const NodeId fnId) {
  const Node *const fn = ast_at_const(c->ast, fnId);
  if (fn->kind != NODE_FUNCTION || fn->as.function.is_public)
    return false;
  bool any = false;
  for (int i = 0; i < c->n_cb_insts && !any; i++)
    any = c->cb_insts[i].fn.node == fnId && c->cb_insts[i].fn.module == c->ast->module;
  if (!any)
    return false;
  for (int i = 0; i < c->n_cb_keep; i++)
    if (c->cb_keep_fns[i] == fnId)
      return false;
  return true;
}

// Emit each callback specialization as a file-local `static` function: the callback parameter elided
// (render_params skips `c->cb_param`) and its calls made direct (emit_call redirects through `c->cb_*`).
static void emit_callback_specializations(Codegen *c, const bool with_body) {
  for (int i = 0; i < c->n_cb_insts; i++) {
    if (c->cb_insts[i].fn.module != c->ast->module)
      continue;
    c->cb_param = c->cb_insts[i].param;
    c->cb_callee = c->cb_insts[i].callee;
    c->cb_callee_closure = c->cb_insts[i].callee_closure;
    char nm[260];
    cb_spec_name(c, c->cb_insts[i].fn, c->cb_callee, c->cb_callee_closure, nm, sizeof nm);
    emit_function(c, c->cb_insts[i].fn.node, (DefId){0, NODE_NONE}, false, with_body, nm, true);
    c->cb_param = NODE_NONE;
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
    emit_function(c, fn.node, (DefId){0, NODE_NONE}, false, with_body, nm, true);
    c->nsubst = 0;
  }
}

// Codegen mirror of the typechecker's type_satisfies, for gating conditional-conformance emission: does the
// concrete type `ty` have an `extend ty as iface` impl -- directly, or a conditional `extend<G> Ty<G> as iface`
// whose own generic bounds hold for ty's args? A generic param is taken to satisfy (re-checked at instantiation).
static bool cg_type_satisfies(Codegen *c, const TypeId ty, const DefId iface, const int depth) {
  if (ty == TYPE_NONE || depth > 8)
    return true; // unknown / too deep: do not manufacture a false miss
  const Ty *const y = ast_type_at(c->ast, ty);
  if (y->kind == TYPE_GENERIC)
    return true;
  ModuleId tmod;
  NodeId tdecl;
  TypeId iargs[4];
  int in = 0;
  if (y->kind == TYPE_STRUCT || y->kind == TYPE_ENUM) {
    tmod = y->module;
    tdecl = y->as.decl;
  } else if (y->kind == TYPE_INSTANCE) {
    const TyInstance *const it = ast_instance(c->ast, y->as.inst);
    tmod = it->module;
    tdecl = it->decl;
    for (uint8_t k = 0; k < it->n && in < 4; k++)
      iargs[in++] = it->args[k];
  } else {
    return false; // a builtin / pointer / etc.: no `as iface` impl
  }
  const ModuleId scopes[2] = {tmod, c->ast->module};
  const int ns = tmod == c->ast->module ? 1 : 2;
  for (int s = 0; s < ns; s++) {
    const ModuleId m = scopes[s];
    Ast *const a = cg_mod_ast(c, m);
    const NodeList items = ast_at_const(a, a->root)->as.program.items;
    const NodeId *const ids = ast_list(a, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const it = ast_at_const(a, ids[i]);
      if (it->kind != NODE_IMPL || it->as.impl_def.trait_type == NODE_NONE || it->as.impl_def.target_type == NODE_NONE)
        continue;
      const DefId tr = ast_resolution_def(a, it->as.impl_def.trait_type);
      const DefId tg = ast_resolution_def(a, it->as.impl_def.target_type);
      if (tr.module != iface.module || tr.node != iface.node || tg.module != tmod || tg.node != tdecl)
        continue;
      const NodeList gens = it->as.impl_def.generics; // conditional extension: each param bound must hold for the arg
      const NodeId *const gids = ast_list(a, gens);
      bool ok = true;
      for (uint32_t g = 0; g < gens.len && (int)g < in && ok; g++) {
        const NodeList gb = ast_at_const(a, gids[g])->as.generic_param.bounds;
        const NodeId *const gbids = ast_list(a, gb);
        for (uint32_t b = 0; b < gb.len && ok; b++) {
          const DefId gbi = ast_resolution_def(a, gbids[b]);
          if (gbi.node != NODE_NONE && !cg_type_satisfies(c, iargs[g], gbi, depth + 1))
            ok = false;
        }
      }
      if (ok)
        return true;
    }
  }
  return false;
}

// An impl's trait as a DefId, or {_,NODE_NONE} for an inherent (non-conformance) impl. A conditional
// conformance (`extend<T: Clone> Vector<T> as Clone`) is emitted for an instance ONLY when the instance
// satisfies it (cg_type_satisfies), so e.g. `Vector<i32>` -- whose i32 is not Clone -- gets no clone method.
static DefId impl_trait(Ast *const a, const Node *const impl) {
  if (impl->as.impl_def.trait_type == NODE_NONE)
    return (DefId){0, NODE_NONE};
  return ast_resolution_def(a, impl->as.impl_def.trait_type);
}

// Emit specialized methods for every concrete generic instance OWNED by this module (moved here by
// package_propagate_instances): for each impl targeting the instance's generic decl, emit each method as
// `<Inst>__<method>` with the impl's type params bound to the instance args. Unlike free-function specs
// (per-module-static), methods are emitted once by the owner, so a `pub` method becomes a real
// cross-module symbol (prototype in the header). `which`/`with_body` mirror phase_prototypes/phase_bodies.
static void emit_method_specializations(Codegen *c, const int which, const bool with_body) {
  const NodeList items = program_items(c);
  const NodeId *const iids = ast_list(c->ast, items);
  for (size_t ii = 0; ii < c->ast->instances.len; ii++) {
    const TyInstance it = c->ast->instances.data[ii]; // copy: emit_function below may grow the pool
    if (it.module != c->ast->module)
      continue;
    bool concrete = true;
    for (uint8_t k = 0; k < it.n; k++)
      concrete &= type_is_concrete(c, it.args[k]);
    if (!concrete)
      continue;
    char inm[200];
    inst_name(c, &it, inm, sizeof inm);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const n = ast_at_const(c->ast, iids[i]);
      if (n->kind != NODE_IMPL || !n->as.impl_def.generics.len)
        continue;
      if (ast_resolution(c->ast, n->as.impl_def.target_type) != it.decl)
        continue;
      const DefId itrait = impl_trait(c->ast, n); // a conditional conformance emits only for satisfying instances
      if (itrait.node != NODE_NONE &&
          !cg_type_satisfies(c, ast_intern_instance(c->ast, it.module, it.decl, it.args, it.n), itrait, 0))
        continue;
      const NodeList gens = n->as.impl_def.generics;
      const NodeId *const gids = ast_list(c->ast, gens);
      const NodeList ms = n->as.impl_def.items;
      const NodeId *const mids = ast_list(c->ast, ms);
      for (uint32_t j = 0; j < ms.len; j++) {
        const Node *const mn = ast_at_const(c->ast, mids[j]);
        if (mn->kind != NODE_FUNCTION || mn->as.function.returns.len > 1) // multi-return method: unsupported
          continue;
        if (with_body ? mn->as.function.body == NODE_NONE : !want_fn(which, mn->as.function.is_public))
          continue;
        // Bind the impl's generics (e.g. T) from the instance's args -- shared by every spec below.
        c->nsubst = 0;
        for (uint32_t g = 0; g < gens.len && g < it.n && c->nsubst < 8; g++) {
          c->subst[c->nsubst].param = (DefId){c->ast->module, gids[g]};
          c->subst[c->nsubst].concrete = it.args[g];
          c->nsubst++;
        }
        char nm[320];
        size_t at = buf_append(nm, sizeof nm, 0, inm);
        at = buf_append(nm, sizeof nm, at, "__");
        render_ident(c, name_span(c, mn->as.function.name), nm + at, sizeof nm - at);
        const bool stat = c->multifile && !mn->as.function.is_public;
        if (mn->as.function.generics.len == 0) { // ordinary method: one spec per instance
          emit_function(c, mids[j], (DefId){0, NODE_NONE}, false, with_body, nm, stat);
          c->nsubst = 0;
          continue;
        }
        // Generic method (map<U>): one spec per recorded (instance, method, targs) tuple, layering the
        // method's own generics atop the impl subst and suffixing the name with the mangled type args.
        const TypeId itTy = ast_intern_instance(c->ast, it.module, it.decl, it.args, it.n);
        const int nimpl = c->nsubst;
        const NodeList mg = mn->as.function.generics;
        const NodeId *const mgids = ast_list(c->ast, mg);
        for (size_t mi = 0; mi < c->ast->method_insts.len; mi++) {
          const MethodInst inst = c->ast->method_insts.data[mi]; // copy: emit may grow pools
          if (inst.method != mids[j] || inst.instance != itTy)
            continue;
          c->nsubst = nimpl;
          for (uint32_t g = 0; g < mg.len && g < inst.n && c->nsubst < 8; g++) {
            c->subst[c->nsubst].param = (DefId){c->ast->module, mgids[g]};
            c->subst[c->nsubst].concrete = inst.targs[g];
            c->nsubst++;
          }
          char snm[400];
          size_t a2 = buf_append(snm, sizeof snm, 0, nm);
          for (uint8_t g = 0; g < inst.n; g++) {
            a2 = buf_append(snm, sizeof snm, a2, "__");
            char e[176];
            mangle_type(c, inst.targs[g], e, sizeof e);
            a2 = buf_append(snm, sizeof snm, a2, e);
          }
          emit_function(c, mids[j], (DefId){0, NODE_NONE}, false, with_body, snm, stat);
        }
        c->nsubst = 0;
      }
    }
  }
}

// Emit interface DEFAULT method bodies inherited by `extend T as Iface` impls in this module that do not
// override them: synthesize `T__<name>` with the interface's abstract `Self` substituted to T, so a call
// resolved to the default (`x.lt(y)`) links. Same-module interfaces only (emit_function reads the current
// Ast); generic impls and generic / multi-return defaults are skipped. `which`/`with_body` mirror the
// prototype vs body split of phase_prototypes / phase_bodies.
static void emit_default_methods(Codegen *c, const int which, const bool with_body) {
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (n->kind != NODE_IMPL || n->as.impl_def.trait_type == NODE_NONE || n->as.impl_def.target_type == NODE_NONE ||
        n->as.impl_def.generics.len)
      continue;
    const DefId iface = ast_resolution_def(c->ast, n->as.impl_def.trait_type);
    const DefId target = ast_resolution_def(c->ast, n->as.impl_def.target_type);
    if (iface.node == NODE_NONE || iface.module != c->ast->module || target.node == NODE_NONE)
      continue; // only same-module interface defaults are emittable here
    const Node *const tn = ast_at_const(c->ast, target.node);
    const TypeId tty = ast_intern_type(
        c->ast, (Ty){.kind = tn->kind == NODE_ENUM ? TYPE_ENUM : TYPE_STRUCT, .module = target.module, .as.decl = target.node});
    const NodeList req = ast_at_const(c->ast, iface.node)->as.trait_def.items;
    const NodeId *const rids = ast_list(c->ast, req);
    const NodeList have = n->as.impl_def.items;
    const NodeId *const hids = ast_list(c->ast, have);
    for (uint32_t r = 0; r < req.len; r++) {
      const Node *const rm = ast_at_const(c->ast, rids[r]);
      if (rm->kind != NODE_FUNCTION || rm->as.function.body == NODE_NONE) // only DEFAULT (bodied) methods
        continue;
      if (rm->as.function.generics.len || rm->as.function.returns.len > 1)
        continue;
      if (!with_body && !want_fn(which, rm->as.function.is_public))
        continue;
      const Span rmn = ast_at_const(c->ast, rm->as.function.name)->as.name.text;
      bool overridden = false;
      for (uint32_t h = 0; h < have.len && !overridden; h++) {
        const Node *const hm = ast_at_const(c->ast, hids[h]);
        overridden = hm->kind == NODE_FUNCTION &&
                     cg_span_eq(c->source, ast_at_const(c->ast, hm->as.function.name)->as.name.text, c->source, rmn);
      }
      if (overridden)
        continue;
      c->nsubst = 1;
      c->subst[0].param = iface; // the interface's `Self` is a TYPE_GENERIC keyed by (iface.module, trait node)
      c->subst[0].concrete = tty;
      emit_function(c, rids[r], target, false, with_body, NULL, c->multifile && !rm->as.function.is_public);
      c->nsubst = 0;
    }
  }
}

// Emit the `<fn>_ret` struct backing a multi-return function (fields `_0`, `_1`, …).
// The array-type node a function returns by value (`fn f() [T; N]`), else NODE_NONE. C cannot return
// an array, so such a return is wrapped in a `<fn>_ret { T _[N]; }` struct (like a multi-return tuple).
static NodeId fn_array_return(Codegen *c, const NodeId fn_id) {
  const NodeList rets = ast_at_const(c->ast, fn_id)->as.function.returns;
  if (rets.len != 1)
    return NODE_NONE;
  const NodeId r0 = ast_list(c->ast, rets)[0];
  const Node *const rn = ast_at_const(c->ast, r0);
  const NodeId tn = rn->kind == NODE_PARAMETER ? rn->as.parameter.type : r0;
  return ast_at_const(c->ast, tn)->kind == NODE_ARRAY_TYPE ? tn : NODE_NONE;
}

static void emit_ret_struct(Codegen *c, const NodeId fn_id, const DefId target) {
  const Node *const fn = ast_at_const(c->ast, fn_id);
  const NodeList rets = fn->as.function.returns;
  char nm[256];
  const NodeId arr = fn_array_return(c, fn_id);
  if (arr != NODE_NONE) { // single array-by-value return -> `struct { T _[N]; } <fn>_ret;`
    function_name(c, fn_id, target, nm, sizeof nm, true);
    char d[256];
    render_type_node(c, arr, "_", d, sizeof d); // the array member, e.g. `int32_t _[3]`
    emit(c, "typedef struct { %s; } %s_ret;\n", d, nm);
    return;
  }
  if (rets.len <= 1)
    return;
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
  char nm[160]; // guard like emit_enum_full: idempotent, so a duplicate emission can never be a C redefinition
  render_qualified(c, c->ast->module, dn->as.aggregate.name, nm, sizeof nm);
  emit(c, "#ifndef SUPER_ENUMTAG_%s\n#define SUPER_ENUMTAG_%s\n", nm, nm);
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
  emit(c, "Tag;\n#endif\n");
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

// --- generic macros: a cross-module instance over a user type by value (Option<Bar>) cannot be emitted by
// the generic's own module (it can only forward-declare Bar -> an incomplete by-value field). Instead the
// generic's module exports `<G>_DECLARE`/`<G>_DEFINE` C macros (parameterized by each type arg's C spelling
// + mangle token, then the instance NAME), and the type's module invokes them so the instance materializes
// where its args are complete. The macros also let a plain-C project reuse the type without Super-C. ----

// Non-generic methods of every generic impl on `declId` (in this module), as macro prototypes
// (define=false) or bodies (define=true), each named `NAME ## __<method>`. Generic methods (map<U>) and
// multi-return methods cannot be a fixed macro and are skipped (emitted concretely for builtin instances).
static void emit_generic_macro_methods(Codegen *c, const NodeId declId, const bool define) {
  const NodeList items = program_items(c);
  const NodeId *const iids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, iids[i]);
    if (n->kind != NODE_IMPL || !n->as.impl_def.generics.len)
      continue;
    if (ast_resolution(c->ast, n->as.impl_def.target_type) != declId)
      continue;
    if (n->as.impl_def.trait_type != NODE_NONE)
      continue; // a conditional conformance: emitted via its own gated per-conformance macro, not the core one
    const NodeList ms = n->as.impl_def.items;
    const NodeId *const mids = ast_list(c->ast, ms);
    for (uint32_t j = 0; j < ms.len; j++) {
      const Node *const mn = ast_at_const(c->ast, mids[j]);
      if (mn->kind != NODE_FUNCTION || mn->as.function.generics.len || mn->as.function.returns.len > 1)
        continue;
      if (define && mn->as.function.body == NODE_NONE)
        continue;
      char nm[320];
      size_t at = buf_append(nm, sizeof nm, 0, "NAME");
      nm[at++] = CG_PASTE; // NAME ## __<method>
      at = buf_append(nm, sizeof nm, at, "__");
      render_ident(c, name_span(c, mn->as.function.name), nm + at, sizeof nm - at);
      emit_function(c, mids[j], (DefId){0, NODE_NONE}, false, define, nm, false);
    }
  }
}

// The macro-name fragment for a conditional conformance impl: the interface's source name (`Clone`), so a
// type's conformance macros are `<STEM>_as_Clone_DECLARE/DEFINE`. Distinct interfaces -> distinct macros.
static size_t conformance_tag(Codegen *c, const Node *const impl, char *out, const size_t cap) {
  const DefId tr = ast_resolution_def(c->ast, impl->as.impl_def.trait_type);
  size_t at = buf_append(out, cap, 0, "as_");
  if (tr.node == NODE_NONE)
    return at;
  const Node *const trn = ast_at_const(cg_mod_ast(c, tr.module), tr.node);
  return at + render_ident_src(cg_mod_src(c, tr.module),
                               ast_at_const(cg_mod_ast(c, tr.module), trn->as.trait_def.name)->as.name.text,
                               out + at, cap > at ? cap - at : 0);
}

// One conditional conformance impl as `#define <STEM>_as_<Iface>_DECLARE(T,_SCM_T,..,NAME) <protos>` /
// `_DEFINE` (bodies), in macro mode. The home invokes it (after the core DECLARE/DEFINE) ONLY for instances
// that satisfy the conformance, so different element types get different subsets (Clone-but-not-Hash, etc.).
static void emit_generic_conformance_macro(Codegen *c, const NodeId declId, const NodeId implId, const bool define) {
  const Node *const dn = ast_at_const(c->ast, declId);
  const Node *const impl = ast_at_const(c->ast, implId);
  char stem[160], tag[80];
  macro_stem(c, c->ast->module, dn->as.aggregate.name, stem, sizeof stem);
  conformance_tag(c, impl, tag, sizeof tag);
  const NodeList gens = dn->as.aggregate.generics;
  const NodeId *const gids = ast_list(c->ast, gens);
  emit(c, "#define %s_%s_%s(", stem, tag, define ? "DEFINE" : "DECLARE");
  for (uint32_t i = 0; i < gens.len; i++) {
    char p[64];
    render_macro_param(c, c->ast->module, gids[i], p, sizeof p);
    emit(c, "%s, _SCM_%s, ", p, p);
  }
  emit(c, "NAME) ");
  c->macro = true;
  c->macro_self = declId;
  c->macro_self_mod = c->ast->module;
  c->nsubst = 0;
  const size_t start = c->buf_len;
  const NodeList ms = impl->as.impl_def.items;
  const NodeId *const mids = ast_list(c->ast, ms);
  for (uint32_t j = 0; j < ms.len; j++) {
    const Node *const mn = ast_at_const(c->ast, mids[j]);
    if (mn->kind != NODE_FUNCTION || mn->as.function.generics.len || mn->as.function.returns.len > 1)
      continue;
    if (define && mn->as.function.body == NODE_NONE)
      continue;
    char nm[320];
    size_t at = buf_append(nm, sizeof nm, 0, "NAME");
    nm[at++] = CG_PASTE;
    at = buf_append(nm, sizeof nm, at, "__");
    render_ident(c, name_span(c, mn->as.function.name), nm + at, sizeof nm - at);
    emit_function(c, mids[j], (DefId){0, NODE_NONE}, false, define, nm, false);
  }
  c->macro = false;
  c->macro_self = NODE_NONE;
  macro_finish(c, start);
  emit(c, "\n");
}

// Every conditional conformance impl on `declId`, as DECLARE + DEFINE macros (gated per-instance at the home).
static void emit_generic_conformance_macros(Codegen *c, const NodeId declId) {
  const NodeList items = program_items(c);
  const NodeId *const iids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, iids[i]);
    if (n->kind != NODE_IMPL || !n->as.impl_def.generics.len || n->as.impl_def.trait_type == NODE_NONE)
      continue;
    if (ast_resolution(c->ast, n->as.impl_def.target_type) != declId)
      continue;
    emit_generic_conformance_macro(c, declId, iids[i], false);
    emit_generic_conformance_macro(c, declId, iids[i], true);
  }
}

// Emit `#define <STEM>_DECLARE(T, _SCM_T, .., NAME) <typedef+struct+protos>` (define=false) or the matching
// `_DEFINE` (method bodies). The body is emitted in macro mode (params render as names, the self instance as
// NAME, instance-name pastes as `##`) then folded onto continued lines by macro_finish.
static void emit_generic_macro(Codegen *c, const NodeId declId, const bool define) {
  const Node *const dn = ast_at_const(c->ast, declId);
  char stem[160];
  macro_stem(c, c->ast->module, dn->as.aggregate.name, stem, sizeof stem);
  const NodeList gens = dn->as.aggregate.generics;
  const NodeId *const gids = ast_list(c->ast, gens);
  emit(c, "#define %s_%s(", stem, define ? "DEFINE" : "DECLARE");
  for (uint32_t i = 0; i < gens.len; i++) {
    char p[64];
    render_macro_param(c, c->ast->module, gids[i], p, sizeof p);
    emit(c, "%s, _SCM_%s, ", p, p);
  }
  emit(c, "NAME) ");
  c->macro = true;
  c->macro_self = declId;
  c->macro_self_mod = c->ast->module;
  c->nsubst = 0;
  const size_t start = c->buf_len;
  if (!define) {
    if (dn->kind == NODE_STRUCT) {
      emit(c, "typedef struct NAME NAME;\n");
      emit(c, "struct NAME {\n");
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
    } else if (aggregate_has_payload(c, dn)) {
      emit(c, "typedef struct NAME NAME;\n");
      emit(c, "struct NAME {\n");
      emit_enum_struct_body(c, dn); // uses the shared `<Enum>Tag` (emitted once by emit_generic_macros)
      emit(c, "};\n");
    } else {
      emit(c, "typedef "); // payload-less generic enum: every instance aliases the shared plain C enum
      emit_local_type_name(c, dn->as.aggregate.name);
      emit(c, " NAME;\n");
    }
  }
  emit_generic_macro_methods(c, declId, define);
  c->macro = false;
  c->macro_self = NODE_NONE;
  macro_finish(c, start);
  emit(c, "\n");
}

// A generic method's macro-mode C name: `NAME ## __<method>__ ## _SCM_<targ0>[ ## __ ## _SCM_<targ1>]`,
// i.e. the concrete `Inst__method__targ0[__targ1]` with NAME and the targ-mangle params left to paste.
static void macro_method_name(Codegen *c, const NodeId methodId, char *out, const size_t cap) {
  const Node *const mn = ast_at_const(c->ast, methodId);
  size_t at = buf_append(out, cap, 0, "NAME");
  if (at < cap)
    out[at++] = CG_PASTE;
  at = buf_append(out, cap, at, "__");
  at += render_ident(c, name_span(c, mn->as.function.name), out + at, cap - at);
  at = buf_append(out, cap, at, "__");
  const NodeList mg = mn->as.function.generics;
  const NodeId *const mgids = ast_list(c->ast, mg);
  for (uint32_t k = 0; k < mg.len; k++) {
    if (k) {
      if (at < cap)
        out[at++] = CG_PASTE;
      at = buf_append(out, cap, at, "__");
    }
    if (at < cap)
      out[at++] = CG_PASTE;
    at = buf_append(out, cap, at, "_SCM_");
    at += render_macro_param(c, c->ast->module, mgids[k], out + at, cap - at);
  }
}

// A generic method (`map<U>`): `#define <STEM>_<method>_DECLARE(T,_SCM_T,..,NAME,U,_SCM_U,..) <proto>` and the
// matching `_DEFINE` (body). The method's own type params become extra macro params after NAME; the home
// invokes one per recorded (instance, targs) use, so each concrete `Inst__method__targs` materializes there.
static void emit_generic_method_macro(Codegen *c, const NodeId declId, const NodeId methodId, const bool define) {
  const Node *const dn = ast_at_const(c->ast, declId);
  const Node *const mn = ast_at_const(c->ast, methodId);
  char stem[160], mnm[64];
  macro_stem(c, c->ast->module, dn->as.aggregate.name, stem, sizeof stem);
  render_ident(c, name_span(c, mn->as.function.name), mnm, sizeof mnm);
  emit(c, "#define %s_%s_%s(", stem, mnm, define ? "DEFINE" : "DECLARE");
  const NodeList gens = dn->as.aggregate.generics;
  const NodeId *const gids = ast_list(c->ast, gens);
  for (uint32_t i = 0; i < gens.len; i++) {
    char p[64];
    render_macro_param(c, c->ast->module, gids[i], p, sizeof p);
    emit(c, "%s, _SCM_%s, ", p, p);
  }
  emit(c, "NAME");
  const NodeList mg = mn->as.function.generics;
  const NodeId *const mgids = ast_list(c->ast, mg);
  for (uint32_t k = 0; k < mg.len; k++) {
    char p[64];
    render_macro_param(c, c->ast->module, mgids[k], p, sizeof p);
    emit(c, ", %s, _SCM_%s", p, p);
  }
  emit(c, ") ");
  c->macro = true;
  c->macro_self = declId;
  c->macro_self_mod = c->ast->module;
  c->nsubst = 0;
  const size_t start = c->buf_len;
  char ov[400];
  macro_method_name(c, methodId, ov, sizeof ov);
  emit_function(c, methodId, (DefId){0, NODE_NONE}, false, define, ov, false);
  c->macro = false;
  c->macro_self = NODE_NONE;
  macro_finish(c, start);
  emit(c, "\n");
}

// Every generic method of the generic impls on `declId`, as DECLARE + DEFINE macros.
static void emit_generic_method_macros(Codegen *c, const NodeId declId) {
  const NodeList items = program_items(c);
  const NodeId *const iids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, iids[i]);
    if (n->kind != NODE_IMPL || !n->as.impl_def.generics.len)
      continue;
    if (ast_resolution(c->ast, n->as.impl_def.target_type) != declId)
      continue;
    const NodeList ms = n->as.impl_def.items;
    const NodeId *const mids = ast_list(c->ast, ms);
    for (uint32_t j = 0; j < ms.len; j++) {
      const Node *const mn = ast_at_const(c->ast, mids[j]);
      if (mn->kind != NODE_FUNCTION || !mn->as.function.generics.len || mn->as.function.returns.len > 1)
        continue;
      emit_generic_method_macro(c, declId, mids[j], false);
      emit_generic_method_macro(c, declId, mids[j], true);
    }
  }
}

// In this module's header: for each pub generic struct/enum, the shared (instance-independent) enum tag and
// the DECLARE + DEFINE macros. Both are `#define`s (DEFINE expands only where invoked, in the home .c), so
// a module that includes this header can invoke either.
static void emit_generic_macros(Codegen *c) {
  if (!c->package)
    return;
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if ((n->kind != NODE_STRUCT && n->kind != NODE_ENUM) || !n->as.aggregate.generics.len ||
        !n->as.aggregate.is_public)
      continue;
    // A self-contained translation unit (REPL / inline tests) only needs the macros for generics actually
    // re-homed over a user type; the multi-file build emits every pub generic's macros for plain-C reuse.
    if (!c->multifile && !package_generic_needs_macro(c->package, c->ast->module, ids[i]))
      continue;
    if (n->kind == NODE_ENUM) { // the tag is shared across instances; macro structs name it
      if (aggregate_has_payload(c, n))
        emit_enum_tag_decl(c, ids[i], n);
      else
        emit_enum_full(c, n, ids[i]);
    }
    emit_generic_macro(c, ids[i], false);
    emit_generic_macro(c, ids[i], true);
    emit_generic_method_macros(c, ids[i]);      // map<U> etc.: one DECLARE/DEFINE per generic method
    emit_generic_conformance_macros(c, ids[i]); // each `as Iface` conformance: a gated DECLARE/DEFINE
  }
}

// True if instance `it` (from c->ast->instances) is a concrete instantiation whose home is THIS module but
// whose generic is declared elsewhere -- i.e. one to emit here via the generic's macros.
static bool inst_rehomed_here(Codegen *c, const TyInstance *const it) {
  if (!c->package || it->module == c->ast->module)
    return false;
  for (uint8_t k = 0; k < it->n; k++)
    if (!type_is_concrete(c, it->args[k]))
      return false;
  return package_instance_home(c->package, c->ast, it) == c->ast->module;
}

// Forward typedef for every instance re-homed here, so the DECLARE invocations' prototypes can name them
// in any order (a by-value field still needs the full definition, emitted by DECLARE below).
static void emit_rehomed_forwards(Codegen *c) {
  if (!c->package)
    return;
  for (size_t i = 0; i < c->ast->instances.len; i++) {
    const TyInstance it = c->ast->instances.data[i];
    if (!inst_rehomed_here(c, &it))
      continue;
    const Node *const dn = ast_at_const(cg_mod_ast(c, it.module), it.decl);
    char inm[200];
    inst_name(c, &it, inm, sizeof inm);
    if (dn->kind == NODE_STRUCT || aggregate_has_payload_in(c, it.module, dn)) {
      emit(c, "typedef struct %s %s;\n", inm, inm);
    } else { // payload-less enum instance: alias the shared plain enum (from the generic's header)
      char en[160];
      render_qualified(c, it.module, dn->as.aggregate.name, en, sizeof en);
      emit(c, "typedef %s %s;\n", en, inm);
    }
  }
}

// After the core DECLARE/DEFINE, invoke each SATISFIED conditional conformance's macro for a re-homed
// instance: `<STEM>_as_<Iface>_DECLARE/DEFINE(args.., NAME)`. Gated by cg_type_satisfies, so an element type
// implementing only some of Clone/Eq/Hash gets only those (and e.g. `Vector<i32>` gets none of them).
static void emit_conformance_invocations(Codegen *c, const TyInstance *const it, const bool define) {
  Ast *const oa = cg_mod_ast(c, it->module);
  const Node *const dn = ast_at_const(oa, it->decl);
  const NodeList items = ast_at_const(oa, oa->root)->as.program.items;
  const NodeId *const iids = ast_list(oa, items);
  const TypeId instTy = ast_intern_instance(c->ast, it->module, it->decl, it->args, it->n);
  char stem[160];
  macro_stem(c, it->module, dn->as.aggregate.name, stem, sizeof stem);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(oa, iids[i]);
    if (n->kind != NODE_IMPL || !n->as.impl_def.generics.len || n->as.impl_def.trait_type == NODE_NONE)
      continue;
    if (ast_resolution(oa, n->as.impl_def.target_type) != it->decl)
      continue;
    const DefId tr = ast_resolution_def(oa, n->as.impl_def.trait_type);
    if (tr.node == NODE_NONE || !cg_type_satisfies(c, instTy, tr, 0))
      continue;
    char tag[80];
    size_t at = buf_append(tag, sizeof tag, 0, "as_");
    const Node *const trn = ast_at_const(cg_mod_ast(c, tr.module), tr.node);
    render_ident_src(cg_mod_src(c, tr.module),
                     ast_at_const(cg_mod_ast(c, tr.module), trn->as.trait_def.name)->as.name.text, tag + at,
                     sizeof tag > at ? sizeof tag - at : 0);
    emit(c, "%s_%s_%s(", stem, tag, define ? "DEFINE" : "DECLARE");
    for (uint8_t k = 0; k < it->n; k++) {
      char csp[256], mng[176];
      render_type_id(c, it->args[k], "", csp, sizeof csp);
      mangle_type(c, it->args[k], mng, sizeof mng);
      emit(c, "%s, %s, ", csp, mng);
    }
    char inm[200];
    inst_name(c, it, inm, sizeof inm);
    emit(c, "%s)\n", inm);
  }
}

// Invoke `<G>_DECLARE(...)` (define=false) / `<G>_DEFINE(...)` for every instance re-homed here, passing each
// arg's C spelling + mangle token and the instance's mangled name; then each satisfied conformance's macro.
static void emit_instance_macro_invocations(Codegen *c, const bool define) {
  if (!c->package)
    return;
  for (size_t i = 0; i < c->ast->instances.len; i++) {
    const TyInstance it = c->ast->instances.data[i];
    if (!inst_rehomed_here(c, &it))
      continue;
    const Node *const dn = ast_at_const(cg_mod_ast(c, it.module), it.decl);
    char stem[160];
    macro_stem(c, it.module, dn->as.aggregate.name, stem, sizeof stem);
    emit(c, "%s_%s(", stem, define ? "DEFINE" : "DECLARE");
    for (uint8_t k = 0; k < it.n; k++) {
      char csp[256], mng[176];
      render_type_id(c, it.args[k], "", csp, sizeof csp);
      mangle_type(c, it.args[k], mng, sizeof mng);
      emit(c, "%s, %s, ", csp, mng);
    }
    char inm[200];
    inst_name(c, &it, inm, sizeof inm);
    emit(c, "%s)\n", inm);
    emit_conformance_invocations(c, &it, define);
  }
}

// Invoke `<STEM>_<method>_DECLARE/DEFINE(...)` for every recorded generic-method use (map<U> etc.) whose
// receiver instance is re-homed here -- one per (instance, method, targs) tuple. The method decl lives in
// the generic's owner module (reached via the instance's module), so its name/params read from there.
static void emit_method_macro_invocations(Codegen *c, const bool define) {
  if (!c->package)
    return;
  for (size_t i = 0; i < c->ast->method_insts.len; i++) {
    const MethodInst mi = c->ast->method_insts.data[i];
    const Ty *const ity = ast_type_at(c->ast, mi.instance);
    if (ity->kind != TYPE_INSTANCE)
      continue;
    const TyInstance recv = *ast_instance(c->ast, ity->as.inst);
    if (!inst_rehomed_here(c, &recv))
      continue;
    bool ok = true;
    for (uint8_t k = 0; k < mi.n; k++)
      ok &= type_is_concrete(c, mi.targs[k]);
    if (!ok)
      continue;
    const Ast *const oa = cg_mod_ast(c, recv.module);
    const Node *const mn = ast_at_const(oa, mi.method);
    char stem[160], mnm[64];
    macro_stem(c, recv.module, ast_at_const(oa, recv.decl)->as.aggregate.name, stem, sizeof stem);
    render_ident_src(cg_mod_src(c, recv.module), name_span_in(c, recv.module, mn->as.function.name), mnm, sizeof mnm);
    emit(c, "%s_%s_%s(", stem, mnm, define ? "DEFINE" : "DECLARE");
    for (uint8_t k = 0; k < recv.n; k++) {
      char csp[256], mng[176];
      render_type_id(c, recv.args[k], "", csp, sizeof csp);
      mangle_type(c, recv.args[k], mng, sizeof mng);
      emit(c, "%s, %s, ", csp, mng);
    }
    char inm[200];
    inst_name(c, &recv, inm, sizeof inm);
    emit(c, "%s", inm);
    for (uint8_t k = 0; k < mi.n; k++) {
      char csp[256], mng[176];
      render_type_id(c, mi.targs[k], "", csp, sizeof csp);
      mangle_type(c, mi.targs[k], mng, sizeof mng);
      emit(c, ", %s, %s", csp, mng);
    }
    emit(c, ")\n");
  }
}

// The C aggregate keyword for a struct decl: `union` for an untagged union, else `struct`.
static const char *agg_kw(const Node *const n) {
  return n->kind == NODE_STRUCT && n->as.aggregate.is_union ? "union" : "struct";
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
      emit(c, "typedef %s ", agg_kw(n));
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
  emit_rehomed_forwards(c);                  // forward typedefs for cross-module instances emitted here via macros
}

// Phase 2: full struct / payload-enum definitions (source order; pointer cycles use phase 1).
// Does phase_types emit a full C body for this decl? (non-generic struct, or non-generic payload enum.)
static bool type_emittable(Codegen *c, const Node *const n) {
  return (n->kind == NODE_STRUCT && !n->as.aggregate.generics.len) ||
         (n->kind == NODE_ENUM && !n->as.aggregate.generics.len && aggregate_has_payload(c, n));
}

// The local struct/enum a field embeds BY VALUE (so its full definition must precede this one), or
// NODE_NONE. Pointers/references only need a forward typedef; an array embeds its element by value.
static NodeId struct_dep(Codegen *c, const NodeId tn) {
  if (tn == NODE_NONE)
    return NODE_NONE;
  const Node *const t = ast_at_const(c->ast, tn);
  if (t->kind == NODE_ARRAY_TYPE)
    return struct_dep(c, t->as.array_type.element);
  if (t->kind == NODE_POINTER_TYPE || t->kind == NODE_REFERENCE_TYPE)
    return NODE_NONE;
  if (t->kind == NODE_TYPE_PATH || t->kind == NODE_IDENTIFIER) {
    const DefId d = ast_resolution_def(c->ast, tn);
    if (d.node != NODE_NONE && d.module == c->ast->module) {
      const Node *const dn = ast_at_const(c->ast, d.node);
      if (dn->kind == NODE_STRUCT || dn->kind == NODE_ENUM)
        return d.node;
    }
  }
  return NODE_NONE;
}

static void emit_type_decl(Codegen *c, const NodeId declId) {
  const Node *const n = ast_at_const(c->ast, declId);
  emit(c, "%s ", agg_kw(n));
  // `@c.packed` / `@c.align(N)` apply to the aggregate's layout: `struct __attribute__((packed)) Name {..}`.
  const Attr *const pk = cg_attr(c, c->ast->module, declId, ATTR_PACKED);
  const Attr *const al = cg_attr(c, c->ast->module, declId, ATTR_ALIGN);
  if (pk || al) {
    char g[64];
    size_t gn = 0;
    g[0] = '\0';
    if (pk)
      gn = buf_append(g, sizeof g, gn, "packed");
    if (al) {
      if (gn)
        gn = buf_append(g, sizeof g, gn, ", ");
      char a[32];
      snprintf(a, sizeof a, "aligned(%u)", al->arg);
      buf_append(g, sizeof g, gn, a);
    }
    emit(c, "__attribute__((%s)) ", g);
  }
  emit_local_type_name(c, n->as.aggregate.name);
  emit(c, " {\n");
  if (n->kind == NODE_ENUM) {
    emit_enum_struct_body(c, n);
  } else {
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
  }
  emit(c, "};\n");
}

// Emit a type's by-value dependencies before itself (post-order DFS). `state`: 0 unvisited, 1 on the
// current path (a cycle -- the type checker rejects by-value cycles, so just stop), 2 emitted.
static void emit_type_dfs(Codegen *c, const NodeId declId, uint8_t *const state) {
  if (state[declId])
    return;
  state[declId] = 1;
  const Node *const n = ast_at_const(c->ast, declId);
  const NodeList members = n->as.aggregate.members;
  const NodeId *const mids = ast_list(c->ast, members);
  for (uint32_t i = 0; i < members.len; i++) {
    const Node *const m = ast_at_const(c->ast, mids[i]);
    if (n->kind == NODE_STRUCT && m->kind == NODE_FIELD) {
      const NodeId dep = struct_dep(c, m->as.field.type);
      if (dep != NODE_NONE && type_emittable(c, ast_at_const(c->ast, dep)))
        emit_type_dfs(c, dep, state);
    } else if (n->kind == NODE_ENUM && m->kind == NODE_VARIANT) {
      const NodeList pl = m->as.variant.payload;
      const NodeId *const plids = ast_list(c->ast, pl);
      for (uint32_t k = 0; k < pl.len; k++) {
        const Node *const pf = ast_at_const(c->ast, plids[k]);
        const NodeId dep = struct_dep(c, pf->kind == NODE_FIELD ? pf->as.field.type : plids[k]);
        if (dep != NODE_NONE && type_emittable(c, ast_at_const(c->ast, dep)))
          emit_type_dfs(c, dep, state);
      }
    }
  }
  emit_type_decl(c, declId);
  state[declId] = 2;
}

static void phase_types(Codegen *c) {
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  // Emit struct/enum bodies in value-containment dependency order: a by-value field of a struct defined
  // later in source must still be complete at the point of use. Forward typedefs already exist.
  uint8_t *const state = calloc(c->ast->nodes.len, 1);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (type_emittable(c, n)) {
      if (state)
        emit_type_dfs(c, ids[i], state);
      else
        emit_type_decl(c, ids[i]); // out of memory: fall back to source order
    }
  }
  free(state);
  emit_aggregate_specializations(c, true); // full bodies for generic struct instantiations
  emit_generic_macros(c);                  // this module's generics as <G>_DECLARE/<G>_DEFINE macros
  emit_instance_macro_invocations(c, false); // DECLARE cross-module instances homed here (after their args)
  emit_method_macro_invocations(c, false);   // DECLARE their generic-method (map<U>) specializations
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
      if (cb_specialized_away(c, ids[i]) || cg_is_format_builtin(c, c->ast->module, ids[i]))
        continue; // its pointer original is unused (every caller took the specialized path) / a format builtin
      if (want_fn(which, n->as.function.is_public))
        emit_function(c, ids[i], (DefId){0, NODE_NONE}, false, false, NULL, false);
    } else if (n->kind == NODE_IMPL) {
      if (n->as.impl_def.generics.len)
        continue; // a generic impl emits no template; its methods are specialized per instance below
      const DefId target = ast_resolution_def(c->ast, n->as.impl_def.target_type);
      const NodeList ms = n->as.impl_def.items;
      const NodeId *const mids = ast_list(c->ast, ms);
      for (uint32_t j = 0; j < ms.len; j++)
        if (ast_at_const(c->ast, mids[j])->kind == NODE_FUNCTION && want_fn(which, ast_at_const(c->ast, mids[j])->as.function.is_public))
          emit_function(c, mids[j], target, false, false, NULL, false);
    }
    // `extern "C"` block functions get NO emitted prototype: every C standard-library header is already
    // included (super_rt.h), so the real declaration is in scope -- and re-declaring it would clash on any
    // signature we cannot reproduce exactly (e.g. `FILE *fopen`, where our opaque `type` lowers to `void`).
    // Calls emit the unmangled C name and bind through the included header; `void`-typed pointers (opaque
    // extern types) convert freely, so `*mut CFile = fopen(...)` and `fclose(h)` type-check in C.
  }
  if (which != PROTO_PUBLIC) { // free-function specs, closures and callback specs are static -> .c only
    emit_specializations(c, false);
    emit_closures(c, false);
    emit_callback_specializations(c, false);
  }
  emit_method_specializations(c, which, false); // method specs: pub -> header (PUBLIC), private -> .c (PRIVATE)
  emit_default_methods(c, which, false);         // inherited interface default-method prototypes
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
    else if (n->kind == NODE_STATIC_ASSERT) // file-scope check, after phase_types so sizeof(struct) is defined
      emit_static_assert(c, n);
  }

  emit_instance_macro_invocations(c, true); // DEFINE bodies of cross-module instances homed here
  emit_method_macro_invocations(c, true);   // DEFINE their generic-method (map<U>) specializations
  emit_default_methods(c, PROTO_ALL, true);  // inherited interface default-method bodies
  emit_specializations(c, true);            // concrete generic free-function instantiations
  emit_method_specializations(c, PROTO_ALL, true); // concrete generic method instantiations
  emit_closures(c, true);                    // hoisted closure / anonymous-fn bodies
  emit_callback_specializations(c, true);    // callback-specialized free functions (Win 1)

  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (n->kind == NODE_FUNCTION && !n->as.function.generics.len && n->as.function.body != NODE_NONE &&
        !cb_specialized_away(c, ids[i]) && !cg_is_format_builtin(c, c->ast->module, ids[i])) {
      emit_function(c, ids[i], (DefId){0, NODE_NONE}, false, true, NULL, false);
    } else if (n->kind == NODE_IMPL && !n->as.impl_def.generics.len) {
      const DefId target = ast_resolution_def(c->ast, n->as.impl_def.target_type);
      const NodeList ms = n->as.impl_def.items;
      const NodeId *const mids = ast_list(c->ast, ms);
      for (uint32_t j = 0; j < ms.len; j++)
        if (ast_at_const(c->ast, mids[j])->kind == NODE_FUNCTION && ast_at_const(c->ast, mids[j])->as.function.body != NODE_NONE)
          emit_function(c, mids[j], target, false, true, NULL, false);
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
      emit(c, "typedef %s %s %s;\n", agg_kw(dn), nm, nm); // `union` for a cross-module untagged union
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
// True if (m, node) is an interface itself, or a method declared inside one -- neither has a C
// representation, so a reference to it never needs the defining module's header.
static bool cg_decl_is_interface_member(Codegen *c, const ModuleId m, const NodeId node) {
  Ast *const a = cg_mod_ast(c, m);
  if (ast_at_const(a, node)->kind == NODE_TRAIT)
    return true;
  if (ast_at_const(a, node)->kind != NODE_FUNCTION)
    return false;
  const NodeList items = ast_at_const(a, a->root)->as.program.items;
  const NodeId *const ids = ast_list(a, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const it = ast_at_const(a, ids[i]);
    if (it->kind != NODE_TRAIT)
      continue;
    const NodeList ms = it->as.trait_def.items;
    const NodeId *const mids = ast_list(a, ms);
    for (uint32_t j = 0; j < ms.len; j++)
      if (mids[j] == node)
        return true;
  }
  return false;
}

static void emit_referenced_includes(Codegen *c) {
  const size_t nmod = c->package->count;
  const ModuleId cur = c->ast->module;
  bool *const want = calloc(nmod, sizeof *want);
  if (!want)
    return;
  for (size_t i = 0; i < c->ast->resolutions.len; i++) {
    const DefId d = c->ast->resolutions.data[i];
    if (d.node == NODE_NONE || d.module == cur || d.module >= nmod)
      continue;
    // An interface, or an interface METHOD, has NO C representation: a trait bound, a conformance's
    // `as Iface`, and a bound-method call (`v.fmt()` resolved to `Format::fmt`) all reference the trait
    // module but generate no use of its header (codegen dispatches to the concrete impl in the value's own
    // module). Pulling the trait header here would re-form a cycle (a value type that conforms to a prelude
    // interface would include the interface module, which references that very type by value).
    if (cg_decl_is_interface_member(c, d.module, d.node))
      continue;
    want[d.module] = true;
  }
  for (size_t i = 0; i < c->ast->type_pool.len; i++) {
    const Ty t = c->ast->type_pool.data[i]; // named types reach modules a literal/inference uses w/o a ref
    if ((t.kind != TYPE_STRUCT && t.kind != TYPE_ENUM && t.kind != TYPE_FUNCTION) || t.module == cur || t.module >= nmod)
      continue; // (TYPE_GENERIC is a param / Self -- never an emittable type, so never an include)
    if (t.kind == TYPE_FUNCTION && cg_decl_is_interface_member(c, t.module, t.as.decl))
      continue; // an interface method's function type (e.g. `Format::fmt`) -- no C symbol, no header needed
    want[t.module] = true;
  }
  // A generic instance re-homed over a user type lives in that type's module and is built by the generic's
  // macros: pull the generic's header (the macros + shared tag) and the home's header (the instance itself).
  for (size_t i = 0; i < c->ast->instances.len; i++) {
    const TyInstance *const it = &c->ast->instances.data[i];
    bool concrete = it->module < nmod || it->module == cur;
    for (uint8_t k = 0; k < it->n && concrete; k++)
      concrete = type_is_concrete(c, it->args[k]);
    if (!concrete)
      continue;
    const ModuleId home = package_instance_home(c->package, c->ast, it);
    if (home == it->module)
      continue; // builtin/prelude args -> owner-emitted, already covered by ordinary refs
    if (it->module != cur && it->module < nmod)
      want[it->module] = true; // the generic's macros + shared tag
    if (home != cur && home < nmod)
      want[home] = true; // where the instance is materialized
  }
  for (size_t m = 0; m < nmod; m++)
    if (want[m])
      emit_modpath_include(c, c->package->modules[m].path);
  free(want);
}

// Emit `#include` for each `extern "C" "<header>" { .. }` backing header in this module, so bindings to
// non-standard / third-party / local C headers resolve (standard headers are auto-included via super_rt).
// A leading '.' or '/' (relative or absolute path) -> a quote include; anything else -> a system include.
// Dedup'd by content so repeated headers across blocks emit once; idempotent across .h/.c (header guards).
static void emit_extern_includes(Codegen *c) {
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (n->kind != NODE_EXTERN_BLOCK || n->as.extern_block.header == NODE_NONE)
      continue;
    const Span hs = ast_at_const(c->ast, n->as.extern_block.header)->span;
    const uint32_t s = hs.start + 1, e = hs.end - 1; // strip the string-literal quotes
    if (e <= s)
      continue;
    bool dup = false; // skip if an earlier block named the same header
    for (uint32_t j = 0; j < i && !dup; j++) {
      const Node *const m = ast_at_const(c->ast, ids[j]);
      if (m->kind != NODE_EXTERN_BLOCK || m->as.extern_block.header == NODE_NONE)
        continue;
      const Span ms = ast_at_const(c->ast, m->as.extern_block.header)->span;
      dup = ms.end - ms.start == hs.end - hs.start &&
            memcmp(c->source + ms.start, c->source + hs.start, hs.end - hs.start) == 0;
    }
    if (dup)
      continue;
    const bool local = c->source[s] == '.' || c->source[s] == '/';
    emit(c, local ? "#include \"" : "#include <");
    emit_bytes(c, (const char *)c->source + s, e - s);
    emit(c, local ? "\"\n" : ">\n");
  }
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
  emit_extern_includes(c);     // backing C headers named by this module's `extern "C" "..."` blocks
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
  collect_callbacks(c); // Win 1: free fns called with statically-known callbacks (callback specializations)
  if (c->multifile) {
    // Multi-file .c: types/public prototypes live in the included headers; here go the private
    // (static) prototypes and every body (private functions are emitted `static`).
    emit_includes(c);
    phase_prototypes(c, PROTO_PRIVATE);
    emit(c, "\n");
    phase_bodies(c);
  } else {
    emit_cstr(c, SUPER_RT_INCLUDES);
    emit_extern_includes(c);
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
  for (size_t i = 0; i < n; i++)
    emit_extern_includes(cs[i]); // backing C headers from any module's `extern "C" "..."` blocks
  cg_flush(cs[0], out);
  for (size_t i = 0; i < n; i++) {
    build_enum_index(cs[i]);
    collect_insts(cs[i]);
    collect_callbacks(cs[i]);
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
