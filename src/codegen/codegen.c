#include "codegen.h"
#include "consteval/consteval.h"

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
#define SC_LIBC_SHIM                                                                                                \
  "static inline __attribute__((unused)) FILE* __sc_stdin(void){return stdin;}\n"                                   \
  "static inline __attribute__((unused)) FILE* __sc_stdout(void){return stdout;}\n"                                 \
  "static inline __attribute__((unused)) FILE* __sc_stderr(void){return stderr;}\n"                                 \
  "static inline __attribute__((unused)) int* __sc_errno_location(void){return &errno;}\n"
const char *const SUPER_RT_INCLUDES =
    RT_H("assert.h") RT_H("complex.h") RT_H("ctype.h") RT_H("errno.h") RT_H("fenv.h") RT_H("float.h")
    RT_H("inttypes.h") RT_H("iso646.h") RT_H("limits.h") RT_H("locale.h") RT_H("math.h") RT_H("dlfcn.h")
    RT_H("signal.h") RT_H("stdalign.h") RT_H("stdarg.h") RT_H("stdatomic.h") RT_H("stdbit.h") RT_H("stdbool.h")
    RT_H("stdckdint.h") RT_H("stddef.h") RT_H("stdint.h") RT_H("stdio.h") RT_H("stdlib.h") RT_H("stdnoreturn.h")
    RT_H("string.h") RT_H("tgmath.h") RT_H("threads.h") RT_H("time.h") RT_H("uchar.h") RT_H("wchar.h")
    RT_H("wctype.h") SC_ATOMIC_SHIM SC_LIBC_SHIM
    // Runtime safety traps and the user-facing panic: abort with a message (no unwinding).
    "static _Noreturn __attribute__((unused)) void __sc_panic(const char *__m) {\n"
    "  fprintf(stderr, \"super-c: %s\\n\", __m); abort();\n"
    "}\n"
    "static _Noreturn __attribute__((unused)) void __sc_panic_str(const uint8_t *__p, size_t __n) {\n"
    "  fprintf(stderr, \"panic: %.*s\\n\", (int)__n, (const char *)__p); abort();\n"
    "}\n"
    "static __attribute__((unused)) inline size_t __sc_bounds(size_t __i, size_t __n) {\n"
    "  if (__i >= __n) __sc_panic(\"index out of bounds\");\n"
    "  return __i;\n"
    "}\n";
#undef RT_H
#undef SC_ATOMIC_SHIM
#undef SC_LIBC_SHIM

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
    NodeId current_fn_ret_node; // the enclosing function's single return TYPE node, for the `?` operator's
                                // early-return construction; NODE_NONE for void / multi-return
    const Package *package;    // for cross-module references / mangling (NULL = single file)
    bool mangle;               // true for >1 user module: prefix every symbol by its module
    bool multifile;            // emit as header + .c with includes (build/ tree), vs one self-contained .c
    bool const_ctx;            // emitting a C constant expression (const init / enum discriminant / static_assert):
                               // checked arithmetic must stay a constant expression (no runtime trap wrapper)
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
    bool insts_overflow; // set once if a module exceeds `insts` -> a loud diagnostic, never a silent omission
    // Win 1 — callback specialization: a same-module free fn called with a statically-known non-capturing
    // callback is specialized per callee, the callback param elided and the inner call made direct.
    struct {
        DefId fn;            // the specialized free function (this module)
        NodeId param;        // its elided callback parameter
        uint32_t cbidx;      // that parameter's position (so the matching argument is elided)
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
    bool borrowed;           // true while emitting a re-homed instance with c->ast swapped to the owner
                             // module: the per-module enum index belongs to the home module, so enum-tag
                             // lookups must scan the owner's enums instead of trusting the stale index
    NodeId slice_raw;        // the array node currently emitted as the inner `.ptr` of an array->slice
                             // coercion wrap; suppresses re-entrant coercion so it emits as a bare array
    // `defer`: a stack of pending deferred statements. Each block scope runs the defers pushed within it,
    // in reverse, at its exit (fall-through, return, break, continue). `loop_defer_base` is the stack depth
    // at the innermost loop body's entry, so break/continue run only the defers registered inside the loop.
    NodeId defer_stack[256];
    uint8_t defer_kind[256]; // 0 = a `defer` statement expr; 1 = an automatic Free of a local binding (RAII)
    uint32_t defer_top;
    uint32_t loop_defer_base;
    // RAII: locals of a `Free`-implementing type are freed at scope exit, UNLESS moved out (passed by
    // value, bound to another name, or returned) -- a moved value is owned (and freed) elsewhere. `moved`
    // holds bindings moved UNCONDITIONALLY (on every path), whose auto-free is elided outright.
    NodeId moved[512];
    uint32_t nmoved;
    // A binding moved on only SOME paths (inside an if/match/loop branch) can't be elided outright (the
    // no-move path would leak): it gets a runtime `bool __mv<decl>` set true at each move site, and its
    // scope-exit free is guarded `if (!__mv<decl>)`. `cond_moved` are those bindings; `cond_sites` are the
    // identifier expressions that move them (where the flag is set).
    NodeId cond_moved[256];
    uint32_t ncond_moved;
    NodeId cond_sites[256];
    uint32_t ncond_sites;
    // Conditionally-moved by-value Free parameters: their free flags are declared at the function body's
    // top (a parameter has no `let` site to attach them to). Consumed once by emit_block_from.
    NodeId param_flags[32];
    uint32_t nparam_flags;
    // Parameters the function body never references: cast to void at the body top so an intentionally
    // ignored parameter (e.g. an allocator's unused `self`/`align`) stays `-Werror,-Wunused-parameter`
    // clean. Set by emit_function, consumed once at the function body's open by emit_block_from.
    NodeId unused_params[32];
    uint32_t nunused_params;
    // True while emitting the value-yielding tail statement of a value-block (`({ ..; VALUE })`): there the
    // expression's value IS the block's result, so the discarded-temporary free must NOT fire (it would
    // consume the value the statement-expression must yield).
    bool no_temp_free;
    // Per-aggregate DFS emission state (0 unvisited / 1 on-path / 2 emitted), keyed by decl NodeId. Persists
    // across phase_types so the single-TU path can pre-emit a concrete struct (an instance's by-value arg
    // living in a later module) before any instance, and the owning module's phase_types then skips it.
    uint8_t *type_state;
    // Body-pass generic-instance emission state (0/1/2 like type_state, indexed by instance table position),
    // valid only during phase_types' body emission (NULL otherwise). Shared between emit_type_dfs and
    // emit_aggregate_specializations so a user struct and the instances it embeds by value (and the user types
    // those embed) are emitted in ONE unified topological order, each exactly once.
    uint8_t *inst_emit_state;
    size_t inst_emit_n;
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

// The package's opt-in const evaluator (--const-eval), or NULL (all consumers degrade gracefully).
static ConstEval *cg_ceval(const Codegen *c) {
  return c->package ? c->package->ceval : NULL;
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
static long array_literal_count(Codegen *c, NodeId obj);
static bool cg_int_lit(Codegen *c, NodeId e, long *out);
static bool cg_emit_checked_arith(Codegen *c, const Node *n, NodeId id);

// The runtime free-flag name for a conditionally-moved Free binding (decl node `decl`): `__mv<decl>`.
static inline void cg_move_flag(char *out, const size_t cap, const NodeId decl) {
  snprintf(out, cap, "__mv%u", decl);
}
static bool cg_is_cond_moved(const Codegen *c, NodeId decl);
// Is the identifier expression `expr` a conditional-move site (set its binding's free flag when emitting it)?
static inline bool cg_is_cond_site(const Codegen *c, const NodeId expr) {
  for (uint32_t i = 0; i < c->ncond_sites; i++)
    if (c->cond_sites[i] == expr)
      return true;
  return false;
}
static void emit_stmt(Codegen *c, NodeId id);
static void cg_conv_suffix(Codegen *c, DefId target, const char *lit, TypeId srcTy, char *out, size_t cap);
static const char *cg_conv_lit(Codegen *c, ModuleId m, Span name);
static void emit_block(Codegen *c, NodeId id);
static void emit_if(Codegen *c, const Node *n);
static void emit_if_expr(Codegen *c, NodeId id);
static void emit_array_braces(Codegen *c, const Node *n);
static void emit_auto_free(Codegen *c, NodeId letId);
static bool cg_type_is_free(Codegen *c, TypeId ty);
static bool cg_is_moved(const Codegen *c, NodeId decl);
static bool emit_free_target(Codegen *c, TypeId bt);
static void emit_try(Codegen *c, const Node *n);
static void emit_condition(Codegen *c, NodeId id);
static void render_type_node(Codegen *c, NodeId tn, const char *decl, char *out, size_t cap);
static void render_type_id(Codegen *c, TypeId t, const char *decl, char *out, size_t cap);
static size_t render_qualified(Codegen *c, ModuleId owner, NodeId name_node, char *buf, size_t cap);
static NodeId fn_array_return(Codegen *c, NodeId fn_id);
static void emit_ret_struct_named(Codegen *c, NodeId fn_id, const char *nm);
static void emit_ret_struct(Codegen *c, NodeId fn_id, DefId target);
static void emit_match_core(Codegen *c, NodeId id, int mode, const char *result);
static void emit_pattern_test(Codegen *c, NodeId pid, const char *scrut);
static void emit_expr_stmt(Codegen *c, NodeId v);
static void emit_defers_to(Codegen *c, uint32_t base);
static void emit_pattern_binds(Codegen *c, NodeId pid, const char *scrut, bool by_ref);
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
  if (!c)
    oom();
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
  if (!c->buf)
    oom();
  ERRORS_INIT(c);
  return c;
}

void codegen_free(Codegen **c) {
  if (!c || !*c)
    return;
  ast_free(&(*c)->ast);
  CgEnumMap_deinit(&(*c)->enum_of_variant);
  free((*c)->type_state);
  free((*c)->inst_emit_state);
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
  if (!buf)
    oom();
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
    end--; // keep one plain newline after the body; trim trailing blanks
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
      if (ty->as.arr.len)
        snprintf(out, cap, "arr%u_%s", ty->as.arr.len, e);
      else
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
  // A pointer/reference/slice/array over a (possibly generic) element: emit the prefix then a paste
  // sentinel, so a generic inner element stays a substitutable `_SCM_<T>` token (`ptr_ ## _SCM_T`).
  if (y->kind == TYPE_POINTER || y->kind == TYPE_REFERENCE || y->kind == TYPE_SLICE || y->kind == TYPE_ARRAY) {
    const char *const pfx = y->kind == TYPE_SLICE ? "slice_" : y->kind == TYPE_ARRAY ? "arr_" : "ptr_";
    size_t at = buf_append(out, cap, 0, pfx);
    if (at < cap)
      out[at++] = CG_PASTE;
    if (at < cap)
      out[at] = '\0';
    macro_arg_token(c, y->as.elem, out + at, cap > at ? cap - at : 0);
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
      const Ty saved = *y; // copy before recursing: subst_resolve may intern -> realloc the pool, freeing y
      const TypeId e = subst_resolve(c, saved.as.elem);
      if (e == saved.as.elem)
        return t;
      Ty nt = saved;
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
    if (!c->insts_overflow) { // never omit silently: one diagnostic instead of a missing symbol at link time
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

static size_t buf_append_bytes(char *out, const size_t cap, size_t at, const char *text, const size_t n) {
  if (at < cap) {
    const size_t room = cap - at - 1;
    const size_t copied = n < room ? n : room;
    memcpy(out + at, text, copied);
    out[at + copied] = '\0';
  }
  return at + n;
}

static size_t buf_append(char *out, const size_t cap, size_t at, const char *text) {
  return buf_append_bytes(out, cap, at, text, strlen(text));
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
  if (m == c->ast->module && !c->borrowed) // borrowed: c->ast is a swapped-in owner; its index is the home's
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

// Peel REFERENCE layers only, stopping at a raw pointer: `*const S + i` / `p == q` are plain C pointer
// arithmetic/comparison, never operator dispatch on the pointee (mirrors the typechecker's routing).
// Returns TYPE_NONE for a pointer so overload emitters bail.
static TypeId strip_ref_only(Codegen *c, TypeId t) {
  const Ty *y = ast_type_at(c->ast, t);
  while (y->kind == TYPE_REFERENCE) {
    t = y->as.elem;
    y = ast_type_at(c->ast, t);
  }
  return y->kind == TYPE_POINTER ? TYPE_NONE : t;
}

// --- numeric/literal emission --------------------------------------------------------------

// Emit an integer/float literal, removing `_` separators and rewriting radix forms C can't read:
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
      if (is_char && src[i] >= 0x80) { // a non-ASCII char (lexer-checked to fit one byte): emit its codepoint
        const uint32_t cp = ((uint32_t)(src[i] & 0x1F) << 6) | (uint32_t)(src[i + 1] & 0x3F); // 2-byte UTF-8
        emit(c, "\\%03o", cp & 0xFFu); // value, not the raw multi-byte sequence (which is invalid C in 'x')
        i += 2;
        continue;
      }
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
    case ByteCharacterLiteral: // b'a' -> (uint8_t)'a': a byte literal is `u8`, so the cast yields 255 for
      emit(c, "(uint8_t)");   // b'\xFF' rather than the signed C char constant's -1
      if (s.end > s.start && c->source[s.start] == 'b')
        emit(c, "%.*s", (int)(s.end - s.start - 1), c->source + s.start + 1);
      else
        emit_span(c, s);
      break;
    case RawStringLiteral:
      codegen_errorf(c, s.start, s.end - s.start, "codegen: raw string literals are not yet supported");
      codegen_notef(c, "use a normal escaped string literal for now");
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
        } else if (dn->kind == NODE_GENERIC_PARAM || dn->kind == NODE_INTERFACE) {
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
          codegen_notef(c, "opaque extern types are supported through 'extern \"C\" { type Name; }' aliases");
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
      // A pointee that resolves to a known-length array (`&T` with T = [i32; N] in a spec, or a
      // written `&[T; N]`) needs the C pointer-to-array declarator: `T (*decl)[N]`.
      const TypeId pt = ast_type(c->ast, n->as.indirect_type.type);
      const TypeId ptr = pt == TYPE_NONE ? TYPE_NONE : subst_resolve(c, pt);
      if (ptr != TYPE_NONE && ast_type_at(c->ast, ptr)->kind == TYPE_ARRAY && ast_type_at(c->ast, ptr)->as.arr.len) {
        const Ty *const ay = ast_type_at(c->ast, ptr);
        char spiral[480];
        snprintf(spiral, sizeof spiral, "(*%s)[%u]", decl, ay->as.arr.len);
        const bool cp = n->kind == NODE_REFERENCE_TYPE ? n->as.indirect_type.qualifier != TYPE_QUAL_MUT
                                                       : n->as.indirect_type.qualifier == TYPE_QUAL_CONST;
        char base[512];
        render_type_id(c, ay->as.elem, spiral, base, sizeof base);
        buf_join3(out, cap, cp && strncmp(base, "const ", 6) != 0 ? "const " : "", "", base);
        break;
      }
      buf_join3(inner, sizeof inner, "*", "", decl);
      const TypeQualifier q = n->as.indirect_type.qualifier;
      // `&T` -> `const T *`, `&mut T` -> `T *`; a raw pointer is const-pointee only for `*const`.
      const bool const_pointee = n->kind == NODE_REFERENCE_TYPE ? q != TYPE_QUAL_MUT : q == TYPE_QUAL_CONST;
      if (const_pointee) {
        char base[512];
        render_type_node(c, n->as.indirect_type.type, inner, base, sizeof base);
        // A reference-to-reference (`&&T`) already renders its pointee `const` -- don't double the keyword.
        buf_join3(out, cap, strncmp(base, "const ", 6) == 0 ? "" : "const ", "", base);
      } else {
        render_type_node(c, n->as.indirect_type.type, inner, out, cap);
      }
      break;
    }
    case NODE_SLICE_TYPE:  // `[]T` -> the prelude Slice<T> / SliceMut<T> instance C name
    case NODE_TUPLE_TYPE:  // `(T1, T2)` -> the prelude Tuple<n> instance C name
      render_type_id(c, ast_type(c->ast, tn), decl, out, cap);
      break;
    case NODE_ARRAY_TYPE: {
      char inner[480];
      const TypeId att = ast_type(c->ast, tn);
      const uint32_t flen = // --const-eval: a folded length renders as a number (a `static const`
          att != TYPE_NONE && ast_type_at(c->ast, att)->kind == TYPE_ARRAY // C name would be a VLA)
              ? ast_type_at(c->ast, att)->as.arr.len
              : 0;
      if (flen) {
        snprintf(inner, sizeof inner, "%s[%u]", decl, flen);
      } else {
        const Span ls = ast_at_const(c->ast, n->as.array_type.length)->span;
        size_t at = 0;
        inner[0] = '\0';
        at = buf_append(inner, sizeof inner, at, decl);
        at = buf_append(inner, sizeof inner, at, "[");
        at = buf_append_bytes(inner, sizeof inner, at, (const char *)c->source + ls.start, ls.end - ls.start);
        buf_append(inner, sizeof inner, at, "]");
      }
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
        codegen_notef(c, "wrap multiple return values in a struct when using a function pointer type");
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
    case TYPE_NEVER: // a diverging call's type: C has no spelling for it, and no value ever exists
      buf_join3(out, cap, "void", SEP(decl), decl);
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
      const Ty *const el = ast_type_at(c->ast, ty->as.elem);
      if (el->kind == TYPE_ARRAY && el->as.arr.len) { // `&[T; N]` -> `const T (*decl)[N]`
        char inner[480];
        snprintf(inner, sizeof inner, "(*%s)[%u]", decl, el->as.arr.len);
        const bool cp = ty->kind == TYPE_REFERENCE ? ty->qualifier != TYPE_QUAL_MUT : ty->qualifier == TYPE_QUAL_CONST;
        char base[512];
        render_type_id(c, el->as.elem, inner, base, sizeof base);
        buf_join3(out, cap, cp && strncmp(base, "const ", 6) != 0 ? "const " : "", "", base);
        break;
      }
      char inner[480];
      buf_join3(inner, sizeof inner, "*", "", decl);
      // `&T` -> `const T *`, `&mut T` -> `T *`; a raw pointer is const-pointee only for `*const`.
      const bool const_pointee = ty->kind == TYPE_REFERENCE ? ty->qualifier != TYPE_QUAL_MUT : ty->qualifier == TYPE_QUAL_CONST;
      if (const_pointee) {
        char base[512];
        render_type_id(c, ty->as.elem, inner, base, sizeof base);
        // A reference-to-reference (`&&T`) already renders its pointee `const` -- don't double the keyword.
        buf_join3(out, cap, strncmp(base, "const ", 6) == 0 ? "" : "const ", "", base);
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
      if (ty->as.arr.len) { // --const-eval: the length lives in the type -> a real C array declarator
        char lenb[16];
        snprintf(lenb, sizeof lenb, "[%u]", ty->as.arr.len);
        buf_join3(inner, sizeof inner, decl, "", lenb);
      } else {
        buf_join3(inner, sizeof inner, "*", "", decl); // unknown length: decays to a pointer as before
      }
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

// True if `tid` is a prelude `Range<E>` instance (the lowered form of a `lo..hi` value); sets `*elem` to E.
static bool cg_range_elem(Codegen *c, const TypeId tid, TypeId *const elem) {
  if (!c->package)
    return false;
  const Ty *const ty = ast_type_at(c->ast, tid);
  if (ty->kind != TYPE_INSTANCE)
    return false;
  const TyInstance *const it = ast_instance(c->ast, ty->as.inst);
  ModuleId rmid;
  const NodeId rd = package_prelude_lookup(c->package, "Range", 5, true, &rmid);
  const bool is_range = it->n == 1 && it->module == rmid && it->decl == rd;
  if (is_range && elem)
    *elem = it->args[0];
  return is_range;
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

// A type node that, after generic substitution, is a pointer/reference (e.g. a param `value: T` in a
// specialization where `T = &U`). Such a node renders pointee-const already (`const U *`), so it must
// take east-const too — west-const would emit a duplicate leading `const`.
static bool cg_binding_subst_indirect(Codegen *c, const NodeId tn) {
  if (tn == NODE_NONE)
    return false;
  const Node *const n = ast_at_const(c->ast, tn);
  if (n->kind != NODE_TYPE_PATH && n->kind != NODE_IDENTIFIER)
    return false;
  const DefId d = ast_resolution_def(c->ast, tn);
  if (d.node == NODE_NONE)
    return false;
  const Node *const dn = ast_at_const(cg_mod_ast(c, d.module), d.node);
  if (dn->kind != NODE_GENERIC_PARAM && dn->kind != NODE_INTERFACE)
    return false;
  const TypeId s = subst_lookup(c, d.module, d.node);
  if (s == TYPE_NONE)
    // Inside a macro template the concrete arg is unknown -- it may be a reference (`const P *`), so a
    // west-const param `const T` would double the const. East-const (`T const`) is safe for any C type.
    return c->macro && dn->kind == NODE_GENERIC_PARAM;
  const TypeKind sk = ast_type_at(c->ast, s)->kind;
  return sk == TYPE_POINTER || sk == TYPE_REFERENCE;
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
  if (is_const && (k == NODE_POINTER_TYPE || k == NODE_REFERENCE_TYPE || k == NODE_FUNCTION_TYPE || east_array_fn || cg_binding_subst_indirect(c, tn))) {
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

// Render a function-pointer declarator `<ret> (*<decl>)(<params>)` for a function VALUE whose interned type
// (TYPE_FUNCTION) is backed by a NODE_FUNCTION / NODE_CLOSURE / NODE_FUNCTION_TYPE in THIS module -- so a
// `let f = some_fn;` or `let f = |x| ..;` binding gets a concrete C type instead of `__auto_type`. Mirrors
// render_type_node's NODE_FUNCTION_TYPE spelling but reads params/returns from whichever node backs the
// type; a compact closure's inferred return comes from its body's checked type.
static void render_fn_value(Codegen *c, const NodeId fn, const char *decl, char *out, const size_t cap) {
  const Node *const n = ast_at_const(c->ast, fn);
  if (n->kind == NODE_FUNCTION_TYPE) { // a fn-typed param used as a value: node already spells the pointer
    render_type_node(c, fn, decl, out, cap);
    return;
  }
  NodeList ps, rs;
  NodeId body = NODE_NONE; // compact closure `|x| e`: return type is inferred from `e`, not in `rs`
  if (n->kind == NODE_FUNCTION) {
    ps = n->as.function.params;
    rs = n->as.function.returns;
  } else if (n->kind == NODE_CLOSURE) {
    ps = n->as.closure.params;
    rs = n->as.closure.returns;
    if (n->as.closure.expr_body)
      body = n->as.closure.body;
  } else {
    buf_join3(out, cap, "void", SEP(decl), decl);
    return;
  }
  char params[480];
  size_t k = 0;
  params[0] = '\0';
  const NodeId *const pid = ast_list(c->ast, ps);
  for (uint32_t i = 0; i < ps.len && k < sizeof params; i++) {
    const Node *const pn = ast_at_const(c->ast, pid[i]);
    char tt[256];
    render_type_node(c, pn->kind == NODE_PARAMETER ? pn->as.parameter.type : pid[i], "", tt, sizeof tt);
    if (i)
      k = buf_append(params, sizeof params, k, ", ");
    k = buf_append(params, sizeof params, k, tt);
  }
  char inner[600];
  size_t at = 0;
  inner[0] = '\0';
  at = buf_append(inner, sizeof inner, at, "(*");
  at = buf_append(inner, sizeof inner, at, decl);
  at = buf_append(inner, sizeof inner, at, ")(");
  at = buf_append(inner, sizeof inner, at, ps.len ? params : "void");
  buf_append(inner, sizeof inner, at, ")");
  if (rs.len == 1) {
    const NodeId r0 = ast_list(c->ast, rs)[0];
    const Node *const rn = ast_at_const(c->ast, r0);
    render_type_node(c, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : r0, inner, out, cap);
  } else if (rs.len == 0 && body != NODE_NONE) {
    render_type_id(c, ast_type(c->ast, body), inner, out, cap);
  } else {
    buf_join3(out, cap, "void ", "", inner); // no return, or (unsupported) multi-return -> void
  }
}

// Emit the declaration head for an inferred binding of name `name` and checker-computed type `t`,
// const-qualified unless mutable. A function value defined in THIS module renders as a concrete function
// pointer (east-const: `T (*const name)(..)`); cross-module function values, generics and poison
// (multi-return calls, deferred `str`) have no faithful C declarator from the TypeId here, so those defer
// to `__auto_type`; every other type is written concretely.
static void emit_binding(Codegen *c, const TypeId t, const Span name, const bool is_const) {
  const Ty *const ty = ast_type_at(c->ast, t);
  const TypeKind k = ty->kind;
  if (k == TYPE_FUNCTION && ty->module == c->ast->module) {
    char nm[128], cnm[160], decl[400];
    render_ident(c, name, nm, sizeof nm);
    if (is_const)
      buf_join3(cnm, sizeof cnm, "const ", "", nm); // the pointer is const, not the pointee
    render_fn_value(c, ty->as.decl, is_const ? cnm : nm, decl, sizeof decl);
    emit_cstr(c, decl);
    return;
  }
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
      if (n->as.unary.op == Move || n->as.unary.op == Unsafe)
        return is_lvalue(c, n->as.unary.operand); // transparent wrappers: `&unsafe p[i]` addresses the place
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
// to dispatch a bound method on a now-monomorphized generic receiver to the real extend. Matches the method
// name by span (`name` in `nsrc`) when `lit` is NULL, else against the C-string `lit`. {_,NODE_NONE} if none.
static DefId cg_find_method_impl(
    Codegen *c, const ModuleId tmod, const NodeId tdecl, const uint8_t *const nsrc, const Span name, const char *const lit) {
  const ModuleId scopes[2] = {tmod, c->ast->module};
  const int ns = tmod == c->ast->module ? 1 : 2;
  for (int s = 0; s < ns; s++) {
    const ModuleId m = scopes[s];
    Ast *const a = cg_mod_ast(c, m);
    const NodeList items = ast_at_const(a, a->root)->as.program.items;
    const NodeId *const ids = ast_list(a, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const it = ast_at_const(a, ids[i]);
      if (it->kind != NODE_EXTEND || it->as.extend_def.target_type == NODE_NONE)
        continue;
      const DefId tg = ast_resolution_def(a, it->as.extend_def.target_type);
      if (tg.module != tmod || tg.node != tdecl)
        continue;
      const NodeList ms = it->as.extend_def.items;
      const NodeId *const mids = ast_list(a, ms);
      for (uint32_t j = 0; j < ms.len; j++) {
        const Node *const mn = ast_at_const(a, mids[j]);
        if (mn->kind != NODE_FUNCTION)
          continue;
        const Span mname = ast_at_const(a, mn->as.function.name)->as.name.text;
        if (lit ? span_is(cg_mod_src(c, m), mname, lit) : cg_span_eq(nsrc, name, cg_mod_src(c, m), mname))
          return (DefId){m, mids[j]};
      }
    }
  }
  return (DefId){0, NODE_NONE};
}

static DefId cg_find_method(Codegen *c, const ModuleId tmod, const NodeId tdecl, const uint8_t *const nsrc, const Span name) {
  return cg_find_method_impl(c, tmod, tdecl, nsrc, name, NULL);
}

// Like cg_find_method but matches a C-string method name (for operator overloading -> `eq`/`cmp`).
static DefId cg_find_method_cstr(Codegen *c, const ModuleId tmod, const NodeId tdecl, const char *const lit) {
  return cg_find_method_impl(c, tmod, tdecl, NULL, (Span){0}, lit);
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
  lt = strip_ref_only(c, subst_resolve(c, lt));
  if (lt == TYPE_NONE)
    return false; // a raw-pointer operand: plain C pointer arithmetic/comparison
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

// Emit the C symbol of method `mth` (`Type__<method>`) for a struct / generic-instance type `bt` (owner
// om/od). Shared by the arithmetic and index operator-overload emitters.
static void emit_op_method(Codegen *c, const Ty *const bt, const ModuleId om, const NodeId od, const DefId mth) {
  if (bt->kind == TYPE_INSTANCE) {
    char inm[200];
    inst_name(c, ast_instance(c->ast, bt->as.inst), inm, sizeof inm);
    emit_cstr(c, inm);
    emit_paste(c);
    emit(c, "__");
  } else {
    char pfx[64];
    render_modpfx(c, mth.module, pfx, sizeof pfx);
    emit_cstr(c, pfx);
    emit_ident_mod(c, om, ast_at_const(cg_mod_ast(c, om), od)->as.aggregate.name);
    emit(c, "__");
  }
  emit_ident_mod(c, mth.module, ast_at_const(cg_mod_ast(c, mth.module), mth.node)->as.function.name);
}

// The method name for an arithmetic operator dispatched on a user-type operand, or NULL.
static const char *cg_arith_op_method(const TokenType op) {
  switch (op) {
    case Plus: return "add";
    case Minus: return "sub";
    case Star: return "mul";
    case Slash: return "div";
    case Percent: return "rem";
    default: return NULL;
  }
}

// Emit an overloaded arithmetic op (`a + b`, ...) on a struct / generic-instance operand as a call to its
// add/sub/mul/div/rem method. Operands are spilled to temps so taking `&` is valid even for a temporary.
// Returns false (not a struct/instance operand, or no such method) to fall back to a plain C operator.
static bool emit_arith_overload(Codegen *c, const Node *const n) {
  const char *const m = cg_arith_op_method(n->as.binary.op);
  if (!m)
    return false;
  TypeId lt = ast_type(c->ast, n->as.binary.left);
  if (lt == TYPE_NONE)
    return false;
  lt = strip_ref_only(c, subst_resolve(c, lt));
  if (lt == TYPE_NONE)
    return false; // a raw-pointer operand: plain C pointer arithmetic/comparison
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
  const DefId mth = cg_find_method_cstr(c, om, od, m);
  if (mth.node == NODE_NONE)
    return false;
  char l[32], r[32];
  fresh(c, l, sizeof l);
  fresh(c, r, sizeof r);
  emit(c, "({ __auto_type %s = ", l);
  emit_expr(c, n->as.binary.left);
  emit(c, "; __auto_type %s = ", r);
  emit_expr(c, n->as.binary.right);
  emit(c, "; ");
  emit_op_method(c, bt, om, od, mth);
  emit(c, "(&%s, &%s); })", l, r);
  return true;
}

// True if type `y` is the prelude struct named `lit` (used to spot `str` / `String` arguments to format).
static bool cg_struct_name_is(Codegen *c, const Ty *const y, const char *const lit) {
  ModuleId m;
  NodeId decl;
  if (y->kind == TYPE_STRUCT) {
    m = y->module;
    decl = y->as.decl;
  } else if (y->kind == TYPE_INSTANCE) { // a generic instance (`String<Global>`) matches its decl's name ("String")
    const TyInstance *const it = ast_instance(c->ast, y->as.inst);
    m = it->module;
    decl = it->decl;
  } else {
    return false;
  }
  const Node *const dn = ast_at_const(cg_mod_ast(c, m), decl);
  return span_is(cg_mod_src(c, m), ast_at_const(cg_mod_ast(c, m), dn->as.aggregate.name)->as.name.text, lit);
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
// spec: 0 = default; 'x'/'X' = lowercase/uppercase hex (integer args only).
static bool emit_format_arg(Codegen *c, const char *const f, const NodeId arg, const char spec) {
  const TypeId t = subst_resolve(c, ast_type(c->ast, arg));
  const Ty *const y = ast_type_at(c->ast, t);
  if (spec == 'x' || spec == 'X') { // hex: integers only
    const bool up = spec == 'X';
    if (y->kind != TYPE_BUILTIN)
      return false;
    switch (y->as.builtin) {
      case BT_I8: case BT_I16: case BT_I32: case BT_I64: case BT_ISIZE:
        emit(c, "String__Global__push_hex_i64(&%s, (int64_t)(", f);
        emit_expr(c, arg);
        emit(c, "), %s);\n", up ? "true" : "false");
        return true;
      case BT_U8: case BT_U16: case BT_U32: case BT_U64: case BT_USIZE: case BT_CHAR:
        emit(c, "String__Global__push_hex(&%s, (uint64_t)(", f);
        emit_expr(c, arg);
        emit(c, "), %s);\n", up ? "true" : "false");
        return true;
      default:
        return false;
    }
  }
  if (y->kind == TYPE_BUILTIN) {
    switch (y->as.builtin) {
      case BT_BOOL:
        emit(c, "if (");
        emit_expr(c, arg);
        emit(c, ") String__Global__push_str(&%s, (str){ .ptr = (const uint8_t*)\"true\", .len = 4 });", f);
        emit(c, " else String__Global__push_str(&%s, (str){ .ptr = (const uint8_t*)\"false\", .len = 5 });\n", f);
        return true;
      case BT_CHAR:
        emit(c, "String__Global__push_byte(&%s, (uint8_t)(", f);
        emit_expr(c, arg);
        emit(c, "));\n");
        return true;
      case BT_I8: case BT_I16: case BT_I32: case BT_I64: case BT_ISIZE:
        emit(c, "String__Global__push_i64(&%s, (int64_t)(", f);
        emit_expr(c, arg);
        emit(c, "));\n");
        return true;
      case BT_U8: case BT_U16: case BT_U32: case BT_U64: case BT_USIZE:
        emit(c, "String__Global__push_u64(&%s, (uint64_t)(", f);
        emit_expr(c, arg);
        emit(c, "));\n");
        return true;
      case BT_F32: case BT_F64:
        emit(c, "String__Global__push_f64(&%s, (double)(", f);
        emit_expr(c, arg);
        emit(c, "));\n");
        return true;
      default:
        return false;
    }
  }
  if (cg_struct_name_is(c, y, "str")) {
    emit(c, "String__Global__push_str(&%s, ", f);
    emit_expr(c, arg);
    emit(c, ");\n");
    return true;
  }
  if (cg_struct_name_is(c, y, "String")) {
    // The format builder is a `String<Global>`, but the argument may be a `String` over a different
    // allocator (`String<MyAlloc>`); push its bytes through the allocator-agnostic `str` view (`as_str`),
    // mangled for the argument's own instance, so a custom-allocator String interpolates correctly.
    char sm[200];
    render_type_id(c, t, "", sm, sizeof sm); // the arg's concrete instance: String__Global / String__MyAlloc
    if (is_lvalue(c, arg)) { // borrow a named String (the caller still owns it)
      emit(c, "String__Global__push_str(&%s, %s__as_str(&(", f, sm);
      emit_expr(c, arg);
      emit(c, ")));\n");
    } else { // a temporary (e.g. `v.fmt()`): materialize, append, then free it (no leak)
      char tmp[32];
      fresh(c, tmp, sizeof tmp);
      emit(c, "{ %s %s = ", sm, tmp);
      emit_expr(c, arg);
      emit(c, "; String__Global__push_str(&%s, %s__as_str(&%s)); %s__free(&%s); }\n", f, sm, tmp, sm, tmp);
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
    codegen_notef(c, "format strings are parsed at compile time so placeholders can be checked");
    return true;
  }
  char f[32];
  fresh(c, f, sizeof f);
  emit(c, "({ String__Global %s = String__Global__new();\n", f);
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
    if (src[i] == '{') { // a placeholder `{}` or `{:x}` / `{:X}` (hex). Scan to the closing `}`.
      char spec = 0;
      size_t j = i + 1;
      if (j < end && src[j] == ':' && j + 1 < end) {
        spec = (char)src[j + 1];
        j += 2;
      }
      if (j < end && src[j] == '}' && (spec == 0 || spec == 'x' || spec == 'X')) {
        if (i > seg) {
          emit(c, "String__Global__push_str(&%s, (str){ .ptr = (const uint8_t*)", f);
          emit_fmt_cstr(c, seg, i);
          emit(c, ", .len = sizeof(");
          emit_fmt_cstr(c, seg, i);
          emit(c, ") - 1 });\n");
        }
        if (ai >= args.len) {
          codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: more `{}` placeholders than arguments");
          codegen_notef(c, "add an argument for each placeholder or escape literal braces as '{{' and '}}'");
          emit(c, "%s; })", f);
          return true;
        }
        if (!emit_format_arg(c, f, aids[ai], spec)) {
          const Span as = ast_at_const(c->ast, aids[ai])->span;
          codegen_errorf(c, as.start, as.end - as.start,
                         spec ? "codegen: `{:x}`/`{:X}` hex format requires an integer argument"
                              : "codegen: argument is not directly formattable (call its .fmt())");
          if (spec)
            codegen_notef(c, "hex formatting is currently implemented only for integer types");
          else
            codegen_notef(c, "implement Format for this type or pass a value that already formats directly");
        }
        ai++;
        i = j + 1;
        seg = i;
        continue;
      }
    }
    i++;
  }
  if (end > seg) {
    emit(c, "String__Global__push_str(&%s, (str){ .ptr = (const uint8_t*)", f);
    emit_fmt_cstr(c, seg, end);
    emit(c, ", .len = sizeof(");
    emit_fmt_cstr(c, seg, end);
    emit(c, ") - 1 });\n");
  }
  if (ai < args.len) {
    codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: more arguments than `{}` placeholders");
    codegen_notef(c, "remove the extra argument or add a matching '{}' placeholder");
  }
  if (kind == 3)
    emit(c, "String__Global__push_byte(&%s, 10);\n", f);
  if (kind == 1) {
    emit(c, "%s; })", f); // format: yield the built String
  } else {
    emit(c, "String__Global__print(&%s); String__Global__free(&%s); })", f, f); // print/println: write to stdout, then free
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

  // `x.free()` Free intrinsic: only when the type checker left it unresolved (an unbounded generic
  // receiver, monomorphized here) -- emit x's Free extend when the concrete type is Free, else a no-op. This
  // is what lets one generic container conformance free its elements (`Vector<String>` frees its Strings,
  // `Vector<i32>` skips them). A resolved `.free()` (concrete type or `T: Free` bound) falls through to the
  // normal call path, which handles its real return type and receiver auto-ref.
  if (callee->kind == NODE_MEMBER && !callee->as.member.path && args.len == 0 &&
      ast_resolution_def(c->ast, callee->as.member.member).node == NODE_NONE &&
      span_is(cg_mod_src(c, c->ast->module), ast_at_const(c->ast, callee->as.member.member)->as.name.text, "free")) {
    const NodeId recv = callee->as.member.object;
    const Ty *const raw = ast_type_at(c->ast, ast_type(c->ast, recv));
    const bool isref = raw->kind == TYPE_POINTER || raw->kind == TYPE_REFERENCE; // receiver already a pointer
    const Ty *const rt = ast_type_at(c->ast, subst_resolve(c, strip_ptr(c, ast_type(c->ast, recv))));
    ModuleId om = 0;
    NodeId od = NODE_NONE;
    if (rt->kind == TYPE_INSTANCE) {
      const TyInstance *const it = ast_instance(c->ast, rt->as.inst);
      om = it->module;
      od = it->decl;
    } else if (rt->kind == TYPE_STRUCT) {
      om = rt->module;
      od = rt->as.decl;
    }
    const DefId fm = od != NODE_NONE ? cg_find_method_cstr(c, om, od, "free") : (DefId){0, NODE_NONE};
    if (fm.node != NODE_NONE) {
      emit_op_method(c, rt, om, od, fm);
      emit(c, isref ? "(" : "(&");
      emit_expr(c, recv);
      emit(c, ")");
    } else if (c->macro && rt->kind == TYPE_GENERIC) {
      // Inside a macro template the receiver's concrete type is unknown: paste `_SCM_<T> ## __free` so the
      // invocation supplies the arg type's `free`. Every type has one -- a real destructor for a Free type,
      // an empty `<builtin>__free` for a scalar (std/core.spc) -- so deep-free reaches user Free elements.
      char pp[64];
      emit(c, "_SCM_");
      render_macro_param(c, rt->module, rt->as.decl, pp, sizeof pp);
      emit_cstr(c, pp);
      emit_paste(c);
      emit(c, "__free");
      emit(c, isref ? "(" : "(&");
      emit_expr(c, recv);
      emit(c, ")");
    } else { // no `free` method (e.g. a builtin, or a generic param resolved to a POD type): free nothing
      emit(c, "(void)(");
      emit_expr(c, recv);
      emit(c, ")");
    }
    return;
  }

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
  // specialization (`fn__cb_<callee>`), with the callback argument elided.
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
      // and dispatch to that type's `as`-extend method instead of the abstract interface method.
      TypeId param_tgt = TYPE_NONE;
      if (td.node != NODE_NONE && ast_at_const(cg_mod_ast(c, td.module), td.node)->kind == NODE_GENERIC_PARAM) {
        const TypeId r = subst_resolve(c, ast_intern_type(c->ast, (Ty){.kind = TYPE_GENERIC, .module = td.module, .as.decl = td.node}));
        if (type_is_concrete(c, r))
          param_tgt = r;
      } else if (td.node != NODE_NONE && ast_at_const(cg_mod_ast(c, td.module), td.node)->kind == NODE_INTERFACE) {
        const TypeId r = subst_resolve(c, ast_type(c->ast, id)); // `Interface::assoc()`: the call's result type is the concrete target
        if (type_is_concrete(c, r))
          param_tgt = r;
      }
      if (base_t != TYPE_NONE && ast_type_at(c->ast, base_t)->kind == TYPE_INSTANCE) {
        char inm[200]; // a generic instance assoc fn -> `Inst__method` (inst_name is already module-qualified)
        inst_name(c, ast_instance(c->ast, ast_type_at(c->ast, base_t)->as.inst), inm, sizeof inm);
        emit_cstr(c, inm);
        emit_paste(c); // in a macro body `NAME ## __method`
        emit(c, "__");
      } else if (param_tgt != TYPE_NONE && ast_type_at(c->ast, param_tgt)->kind == TYPE_BUILTIN && c->package) {
        // `T::default()` with T monomorphized to a builtin -> `i32__default_` (the core conformance).
        const BuiltinType bt = ast_type_at(c->ast, param_tgt)->as.builtin;
        const NodeId bd = package_builtin_decl(c->package, bt);
        if (bd != NODE_NONE) {
          const DefId cm = cg_find_method(c, c->package->core_module, bd, c->source, name_span(c, callee->as.member.member));
          if (cm.node != NODE_NONE)
            emd = cm;
        }
        char pfx[64];
        render_modpfx(c, emd.module, pfx, sizeof pfx);
        emit_cstr(c, pfx);
        emit_cstr(c, BUILTIN_NAMES[bt]);
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
        const DefId cm = cg_find_method(c, omod, odecl, c->source, name_span(c, callee->as.member.member));
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
      } else if (c->macro && td.node != NODE_NONE &&
                 ast_at_const(cg_mod_ast(c, td.module), td.node)->kind == NODE_GENERIC_PARAM) {
        // `T::assoc()` on a generic param inside a macro template (e.g. `T::default()` in `Box<T> as Default`):
        // the concrete arg is unknown here, so paste the param's mangle token to form the extend symbol at
        // invocation time (`_SCM_T ## __default_` -> `Option__Tr__default_`). Covers every interface's
        // associated functions uniformly, mirroring the bound-method receiver path above.
        char pp[64];
        emit(c, "_SCM_");
        render_macro_param(c, td.module, td.node, pp, sizeof pp);
        emit_cstr(c, pp);
        emit_paste(c);
        emit(c, "__");
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
      // once the param is monomorphized, dispatch to the concrete type's `as`-extend method (`File__write`).
      if (ast_type_at(c->ast, pointee)->kind == TYPE_GENERIC) {
        const Ty *const rb = ast_type_at(c->ast, subst_resolve(c, pointee));
        if (rb->kind == TYPE_STRUCT || rb->kind == TYPE_ENUM) {
          const DefId cm = cg_find_method(
              c, rb->module, rb->as.decl, cg_mod_src(c, c->ast->module), name_span(c, callee->as.member.member));
          if (cm.node != NODE_NONE)
            md = cm;
        } else if (rb->kind == TYPE_BUILTIN && c->package) { // K: Hash monomorphized to a builtin -> i32__hash
          const NodeId bd = package_builtin_decl(c->package, rb->as.builtin);
          if (bd != NODE_NONE) {
            const DefId cm = cg_find_method(
                c, c->package->core_module, bd, cg_mod_src(c, c->ast->module), name_span(c, callee->as.member.member));
            if (cm.node != NODE_NONE)
              md = cm;
          }
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
      // A materialized Free temporary (e.g. `make_string().len()`) must be freed after the call or it
      // leaks -- unless the result borrows INTO it (a reference/pointer return), in which case freeing it
      // would dangle the result, so it is left alone.
      const TypeId crt = ast_type(c->ast, id);
      const Ty *const crty = crt != TYPE_NONE ? ast_type_at(c->ast, crt) : NULL;
      const bool void_ret = !crty || (crty->kind == TYPE_BUILTIN && crty->as.builtin == BT_VOID);
      const bool ref_ret = crty && (crty->kind == TYPE_POINTER || crty->kind == TYPE_REFERENCE);
      const bool free_tmp = materialize && !ref_ret && cg_type_is_free(c, obj_t);
      char tmp[32], tres[32];
      if (materialize) {
        fresh(c, tmp, sizeof tmp);
        emit(c, "({ __auto_type %s = ", tmp);
        emit_expr(c, obj);
        emit(c, "; ");
        if (free_tmp && !void_ret) {
          fresh(c, tres, sizeof tres);
          emit(c, "__auto_type %s = ", tres); // capture the result, then free the temp, then yield it
        }
      }
      if (c->macro && base->kind == TYPE_GENERIC) {
        // A bound-method call on a generic param inside a generic macro template (`elem.clone()` where
        // `T: Clone`): the concrete arg is unknown here, so paste the param's mangle token with the method
        // to form the extend symbol at invocation time (`_SCM_T ## __clone` -> `Bar__clone`). The method must
        // live in the arg type's own module (coherent extend), so its symbol prefix matches the arg's mangle.
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
      } else if (base->kind == TYPE_BUILTIN) { // `extend i32 { .. }` method -> i32__<method>
        char pfx[64];
        render_modpfx(c, md.module, pfx, sizeof pfx);
        emit_cstr(c, pfx);
        emit_cstr(c, BUILTIN_NAMES[base->as.builtin]);
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
      if (materialize) {
        if (free_tmp) {
          emit(c, "; ");
          emit_free_target(c, obj_t);
          emit(c, "(&%s);", tmp);
          if (!void_ret)
            emit(c, " %s;", tres);
          emit(c, " })");
        } else {
          emit(c, "; })");
        }
      }
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
    // `T {}` zero-initializes; a struct WITH fields wants `(T){0}`, but a genuinely empty struct
    // (a ZST allocator tag) has no members, so `(T){0}` would be an excess initializer -> emit `(T){}`.
    bool zero_fields = false;
    const DefId d = ast_resolution_def(c->ast, stn); // a NODE_TYPE_PATH carries its resolution on the whole node
    if (d.node != NODE_NONE) {
      const Node *const dn = ast_at_const(cg_mod_ast(c, d.module), d.node);
      zero_fields = dn->kind == NODE_STRUCT && dn->as.aggregate.members.len == 0;
    }
    emit(c, zero_fields ? "(%s){}" : "(%s){0}", t);
    return;
  }
  // A C array member can't be initialized from an array lvalue in a compound literal (and re-subscripting
  // would evaluate the value N times). If any field is array-typed and not a brace list, build the struct in
  // a statement-expression and memcpy those fields, each value evaluated once via its address.
  bool arr_copy = false;
  for (uint32_t i = 0; i < fields.len; i++) {
    const NodeId fv = ast_at_const(c->ast, ids[i])->as.field_initializer.value;
    const TypeId fvt = ast_type(c->ast, fv);
    if (ast_at_const(c->ast, fv)->kind != NODE_ARRAY_LITERAL && fvt != TYPE_NONE &&
        ast_type_at(c->ast, fvt)->kind == TYPE_ARRAY)
      arr_copy = true;
  }
  char st[32];
  if (arr_copy) {
    fresh(c, st, sizeof st);
    emit(c, "({ %s %s = ", t, st);
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
    const TypeId fvt = ast_type(c->ast, fv);
    const bool arr_field = ast_at_const(c->ast, fv)->kind != NODE_ARRAY_LITERAL && fvt != TYPE_NONE &&
                           ast_type_at(c->ast, fvt)->kind == TYPE_ARRAY;
    if (ast_at_const(c->ast, fv)->kind == NODE_ARRAY_LITERAL) // a C array member takes a brace list, not an expr
      emit_array_braces(c, ast_at_const(c->ast, fv));
    else if (arr_field)
      emit(c, "{0}"); // filled by the memcpy below
    else
      emit_expr(c, fv);
  }
  emit(c, " }");
  if (!arr_copy)
    return;
  emit(c, ";");
  for (uint32_t i = 0; i < fields.len; i++) {
    const Node *const fi = ast_at_const(c->ast, ids[i]);
    const NodeId fv = fi->as.field_initializer.value;
    const TypeId fvt = ast_type(c->ast, fv);
    if (ast_at_const(c->ast, fv)->kind == NODE_ARRAY_LITERAL || fvt == TYPE_NONE ||
        ast_type_at(c->ast, fvt)->kind != TYPE_ARRAY)
      continue;
    emit(c, " memcpy(&%s.", st);
    emit_ident(c, name_span(c, fi->as.field_initializer.name));
    emit(c, ", &(");
    emit_expr(c, fv);
    emit(c, "), sizeof %s.", st);
    emit_ident(c, name_span(c, fi->as.field_initializer.name));
    emit(c, ");");
  }
  emit(c, " %s; })", st);
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
    if (dn->kind == NODE_CONST && dn->as.const_def.is_extern) {
      char ov[160]; // extern const: emit the real C macro name (e.g. O_RDONLY) from the backing header
      if (cg_symbol_override(c, d.module, d.node, ov, sizeof ov))
        emit_cstr(c, ov);
      else
        emit_ident_mod(c, d.module, dn->as.const_def.name);
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
      const ConstValue iv = consteval_eval(cg_ceval(c), c->ast->module, el->as.field_initializer.name);
      if (iv.kind == CONST_INT) // folded: C requires an integer constant expression here
        emit(c, "%lld", (long long)iv.i);
      else
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
  // --const-eval: a folded PURE COMPUTATION emits as its value, so constant chains collapse in the
  // generated C. Only computation kinds fold here -- identifiers/members/places keep their names
  // (`&K` must stay addressable, and named constants read better than magic numbers).
  if (cg_ceval(c))
    switch (n->kind) {
      case NODE_BINARY:
      case NODE_UNARY:
      case NODE_CAST:
      case NODE_SIZEOF:
      case NODE_ALIGNOF: {
        const ConstValue v = consteval_eval(cg_ceval(c), c->ast->module, id);
        if (v.kind == CONST_BOOL) {
          emit(c, v.i ? "true" : "false");
          return;
        }
        if (v.kind == CONST_INT) {
          const Ty *const vt = v.type != TYPE_NONE ? ast_type_at(c->ast, v.type) : NULL;
          const BuiltinType vb = vt && vt->kind == TYPE_BUILTIN ? vt->as.builtin : BT_COUNT;
          const bool uns = vb == BT_U8 || vb == BT_U16 || vb == BT_U32 || vb == BT_U64 || vb == BT_USIZE;
          if (uns)
            emit(c, (uint64_t)v.i > 0x7fffffffull ? "%lluull" : "%llu", (unsigned long long)v.i);
          else
            emit(c, v.i > 0x7fffffffll || v.i < -0x80000000ll ? "%lldll" : "%lld", (long long)v.i);
          return;
        }
        break;
      }
      default:
        break;
    }
  switch (n->kind) {
    case NODE_LITERAL:
      emit_literal(c, id, n);
      break;
    case NODE_IDENTIFIER:
      if (cg_is_cond_site(c, id)) { // a conditional move: set the free flag, then yield the value
        char fl[32];
        cg_move_flag(fl, sizeof fl, ast_resolution_def(c->ast, id).node);
        emit(c, "(%s = true, ", fl);
        emit_ident_ref(c, id, n);
        emit(c, ")");
      } else {
        emit_ident_ref(c, id, n);
      }
      break;
    case NODE_UNARY: {
      const TokenType op = n->as.unary.op;
      if (op == Question) {
        emit_try(c, n); // `expr?`: unwrap or early-return None/Err
      } else if (op == Move || op == Unsafe) {
        emit_expr(c, n->as.unary.operand); // ownership/unsafe markers vanish
      } else if (op == Ampersand && !is_lvalue(c, n->as.unary.operand) &&
                 ast_type_at(c->ast, ast_type(c->ast, n->as.unary.operand))->kind == TYPE_BUILTIN) {
        // `&<scalar rvalue>` (e.g. a default `opt.unwrap_or(&9)`): C can't take a literal's address, so
        // materialize a compound literal -- it has block lifetime, so the borrow is valid for the statement.
        char ty[128];
        render_type_id(c, ast_type(c->ast, n->as.unary.operand), "", ty, sizeof ty);
        emit(c, "(&(%s){", ty);
        emit_expr(c, n->as.unary.operand);
        emit(c, "})");
      } else {
        emit(c, "(%s", c_op(op));
        emit_expr(c, n->as.unary.operand);
        emit(c, ")");
      }
      break;
    }
    case NODE_BINARY: {
      // Operator overloading: a comparison on a struct / generic-instance operand -> its eq/cmp method,
      // an arithmetic op -> its add/sub/mul/div/rem method.
      if (emit_cmp_overload(c, n))
        break;
      if (emit_arith_overload(c, n))
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
      if (cg_emit_checked_arith(c, n, id)) // signed +,-,* overflow / integer /,% by zero
        break;
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
      const TypeId ltr = lt == TYPE_NONE ? TYPE_NONE : subst_resolve(c, lt); // T = [i32; N] in a spec body
      if (n->as.binary.op == Equal && ltr != TYPE_NONE && ast_type_at(c->ast, ltr)->kind == TYPE_ARRAY) {
        emit(c, "memcpy(");
        emit_expr(c, n->as.binary.left);
        emit(c, ", ");
        emit_expr(c, n->as.binary.right);
        emit(c, ", sizeof(");
        emit_expr(c, n->as.binary.left);
        emit(c, "))");
        break;
      }
      // Reassigning a Free BINDING (`x = new`) frees the old value first -- a Free binding is always
      // initialized (the type checker forbids deferred init), and not freeing the old buffer would leak.
      // (Field/index places like `m.vals[i] = v` are managed manually -- they may be uninitialized.)
      NodeId lhsId = n->as.binary.left;
      const Node *lhs = ast_at_const(c->ast, lhsId);
      while (lhs->kind == NODE_UNARY && (lhs->as.unary.op == Move || lhs->as.unary.op == Unsafe)) {
        lhsId = lhs->as.unary.operand; // transparent wrappers: store-form detection needs the real place
        lhs = ast_at_const(c->ast, lhsId);
      }
      const DefId ld = lhs->kind == NODE_IDENTIFIER ? ast_resolution_def(c->ast, lhsId) : (DefId){0, NODE_NONE};
      if (n->as.binary.op == Equal && lhs->kind == NODE_IDENTIFIER && cg_type_is_free(c, lt) && ld.node != NODE_NONE &&
          !cg_is_moved(c, ld.node)) {
        char r[32];
        fresh(c, r, sizeof r);
        emit(c, "({ __auto_type %s = ", r); // evaluate the new value, free the old binding, then move in
        emit_expr(c, n->as.binary.right);
        emit(c, "; ");
        emit_free_target(c, lt);
        emit(c, "(&");
        emit_expr(c, n->as.binary.left);
        emit(c, "); (");
        emit_expr(c, n->as.binary.left);
        emit(c, " = %s); })", r);
        break;
      }
      // Overloaded index-assignment (the IndexMut interface): `obj[i] = v` stores through the element
      // pointer `index_mut` returns; a compound op reads and writes through it. A plain `=` over a Free
      // element frees the replaced value first (mirroring a Free binding reassignment), with the RHS
      // evaluated BEFORE the free so `v[i] = f(v[i])` reads the old element safely.
      if (lhs->kind == NODE_INDEX && ast_at_const(c->ast, lhs->as.index.index)->kind != NODE_RANGE &&
          !cg_slice_elem(c, ast_type(c->ast, lhs->as.index.object), NULL)) {
        const TypeId iot = ast_type(c->ast, lhs->as.index.object); // NOT pointer-peeled (see the read path)
        const Ty *const ibt = iot == TYPE_NONE ? NULL : ast_type_at(c->ast, subst_resolve(c, iot));
        if (ibt && (ibt->kind == TYPE_STRUCT || ibt->kind == TYPE_INSTANCE)) {
          ModuleId om;
          NodeId od;
          if (ibt->kind == TYPE_INSTANCE) {
            const TyInstance *const it = ast_instance(c->ast, ibt->as.inst);
            om = it->module;
            od = it->decl;
          } else {
            om = ibt->module;
            od = ibt->as.decl;
          }
          const DefId mth = cg_find_method_cstr(c, om, od, "index_mut");
          if (mth.node != NODE_NONE) {
            if (n->as.binary.op == Equal && lt != TYPE_NONE && cg_type_is_free(c, lt)) {
              char r[32], p[32];
              fresh(c, r, sizeof r);
              fresh(c, p, sizeof p);
              emit(c, "({ __auto_type %s = ", r);
              emit_expr(c, n->as.binary.right);
              emit(c, "; __auto_type %s = ", p);
              emit_op_method(c, ibt, om, od, mth);
              emit(c, "(");
              emit_prefixed(c, lhs->as.index.object, "&");
              emit(c, ", ");
              emit_expr(c, lhs->as.index.index);
              emit(c, "); ");
              emit_free_target(c, lt);
              emit(c, "(%s); (*%s = %s); })", p, p, r);
            } else {
              emit(c, "(*");
              emit_op_method(c, ibt, om, od, mth);
              emit(c, "(");
              emit_prefixed(c, lhs->as.index.object, "&");
              emit(c, ", ");
              emit_expr(c, lhs->as.index.index);
              emit(c, ") %s ", c_op(n->as.binary.op));
              emit_expr(c, n->as.binary.right);
              emit(c, ")");
            }
            break;
          }
        }
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
      // A conditional `x.free()` sets x's free flag AROUND the call (the receiver is taken by address, so
      // it can't be wrapped as a comma-expr); the scope-exit auto-free is then `if (!flag)`.
      const Node *const cn = ast_at_const(c->ast, n->as.call.callee);
      char freeflag[32];
      freeflag[0] = '\0';
      if (cn->kind == NODE_MEMBER && !cn->as.member.path && cn->as.member.object != NODE_NONE &&
          ast_at_const(c->ast, cn->as.member.object)->kind == NODE_IDENTIFIER &&
          span_is(cg_mod_src(c, c->ast->module), ast_at_const(c->ast, cn->as.member.member)->as.name.text, "free")) {
        const DefId rd = ast_resolution_def(c->ast, cn->as.member.object);
        if (rd.module == c->ast->module && cg_is_cond_moved(c, rd.node)) {
          cg_move_flag(freeflag, sizeof freeflag, rd.node);
          emit(c, "(%s = true, ", freeflag);
        }
      }
      if (arr_ret)
        emit(c, "(");
      emit_call(c, id, n);
      if (arr_ret)
        emit(c, ")._");
      if (freeflag[0])
        emit(c, ")");
      break;
    }
    case NODE_CLOSURE: { // a closure value is just the address of its hoisted static function
      char nm[200];
      closure_name(c, id, nm, sizeof nm);
      emit_cstr(c, nm);
      break;
    }
    case NODE_TUPLE: { // `(a, b, ..)` -> a Tuple<n> struct literal (fields `_0`..)
      char styp[200];
      render_type_id(c, ast_type(c->ast, id), "", styp, sizeof styp);
      emit(c, "(%s){ ", styp);
      const NodeId *const eids = ast_list(c->ast, n->as.array_literal.elements);
      for (uint32_t i = 0; i < n->as.array_literal.elements.len; i++) {
        emit(c, i ? ", ._%u = " : "._%u = ", i);
        emit_expr(c, eids[i]);
      }
      emit(c, " }");
      break;
    }
    case NODE_RANGE: { // a range value -> a `Range<T>` struct literal (for/index uses are lowered elsewhere)
      char styp[200];
      render_type_id(c, ast_type(c->ast, id), "", styp, sizeof styp);
      emit(c, "(%s){ .start = ", styp);
      emit_expr(c, n->as.pattern_range.start);
      emit(c, ", .end = ");
      emit_expr(c, n->as.pattern_range.end);
      emit(c, ", .inclusive = %s }", n->as.pattern_range.inclusive ? "true" : "false");
      break;
    }
    case NODE_INDEX: {
      const Node *const idxn = ast_at_const(c->ast, n->as.index.index);
      if (idxn->kind == NODE_RANGE) { // `a[lo..hi]` -> a `[]T` view: { .ptr = base + lo, .len = hi - lo }
        const NodeId obj = n->as.index.object;
        const NodeId lo = idxn->as.pattern_range.start, hi = idxn->as.pattern_range.end;
        const bool incl = idxn->as.pattern_range.inclusive;
        // Range-index operator overloading (the Index interface): `obj[lo..hi]` on a struct / generic
        // instance -> its `index_range` method, the written bounds packed into a `Range<usize>`. A
        // missing start is 0; a missing end is the receiver's `len()` (the typechecker required it).
        // Built-in slices keep their inline `{ptr,len}` lowering below (mirrors the typechecker's order).
        if (c->package && !cg_slice_elem(c, ast_type(c->ast, obj), NULL)) {
          const TypeId ot = ast_type(c->ast, obj); // NOT pointer-peeled: `p[a..b]` on a raw pointer is a C view
          const Ty *const bt = ot == TYPE_NONE ? NULL : ast_type_at(c->ast, subst_resolve(c, ot));
          if (bt && (bt->kind == TYPE_STRUCT || bt->kind == TYPE_INSTANCE)) {
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
            const DefId mth = cg_find_method_cstr(c, om, od, "index_range");
            if (mth.node != NODE_NONE) {
              ModuleId rm;
              const NodeId rd = package_prelude_lookup(c->package, "Range", 5, true, &rm);
              char rn[200]; // the Range<usize> C name the bounds are packed into
              render_type_id(c, ast_intern_instance(c->ast, rm, rd, (TypeId[]){ast_builtin(BT_USIZE)}, 1), "", rn,
                             sizeof rn);
              // An LVALUE receiver is passed by ADDRESS (the returned view aliases its storage, which must
              // outlive the statement-expression); a temporary receiver is spilled by value first.
              char o[32], v[32];
              fresh(c, o, sizeof o);
              if (is_lvalue(c, obj)) {
                emit(c, "({ __auto_type %s = ", o);
                emit_prefixed(c, obj, "&");
              } else {
                fresh(c, v, sizeof v);
                emit(c, "({ __auto_type %s = ", v);
                emit_expr(c, obj);
                emit(c, "; __auto_type %s = &%s", o, v);
              }
              emit(c, "; ");
              emit_op_method(c, bt, om, od, mth);
              emit(c, "(%s, (%s){ .start = ", o, rn);
              if (lo != NODE_NONE)
                emit_expr(c, lo);
              else
                emit(c, "0");
              emit(c, ", .end = ");
              if (hi != NODE_NONE) {
                emit_expr(c, hi);
              } else { // open end: the receiver's length
                const DefId lm = cg_find_method_cstr(c, om, od, "len");
                if (lm.node != NODE_NONE) {
                  emit_op_method(c, bt, om, od, lm);
                  emit(c, "(%s)", o);
                } else {
                  emit(c, "0"); // unreachable: the typechecker required a `len` method
                }
              }
              emit(c, ", .inclusive = %s }); })", incl ? "true" : "false");
              break;
            }
          }
        }
        char styp[200];
        render_type_id(c, ast_type(c->ast, id), "", styp, sizeof styp); // the Slice<elem> result type
        const bool isslice = cg_slice_elem(c, ast_type(c->ast, obj), NULL);
        const NodeId arrlen = isslice ? NODE_NONE : array_length_of(c, obj); // open-ended hi -> the array length
        char b[32];
        fresh(c, b, sizeof b);
        emit(c, "({ __auto_type %s = ", b); // materialize the base once (array decays to a pointer)
        emit_expr(c, obj);
        emit(c, "; (%s){ .ptr = %s%s + ", styp, b, isslice ? ".ptr" : "");
        if (lo != NODE_NONE) {
          emit(c, "(");
          emit_expr(c, lo);
          emit(c, ")");
        } else {
          emit(c, "0");
        }
        emit(c, ", .len = ");
        if (hi != NODE_NONE) {
          emit(c, "(");
          emit_expr(c, hi);
          emit(c, incl ? ") + 1" : ")");
        } else if (isslice) {
          emit(c, "%s.len", b);
        } else if (arrlen != NODE_NONE) {
          emit_expr(c, arrlen);
        } else {
          const long cnt = array_literal_count(c, obj); // inferred-length array: count from the initializer
          emit(c, "%ld", cnt >= 0 ? cnt : 0);
        }
        emit(c, " - ");
        if (lo != NODE_NONE) {
          emit(c, "(");
          emit_expr(c, lo);
          emit(c, ")");
        } else {
          emit(c, "0");
        }
        emit(c, " }; })");
        break;
      }
      { // operator overloading: `obj[i]` on a struct / generic-instance -> its `index` method.
        // The object type is NOT pointer-peeled (mirrors the typechecker): `self.ptr[i]` on a raw
        // `*mut T` is C indexing, never a dispatch to the pointee's own `index`. Prelude slices keep
        // their inline `.ptr[__sc_bounds(..)]` lowering below (also mirroring the typechecker's order).
        const TypeId ot = ast_type(c->ast, n->as.index.object);
        const Ty *const bt = ot == TYPE_NONE ? NULL : ast_type_at(c->ast, subst_resolve(c, ot));
        if (bt && (bt->kind == TYPE_STRUCT || bt->kind == TYPE_INSTANCE) && !cg_slice_elem(c, ot, NULL)) {
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
          const DefId mth = cg_find_method_cstr(c, om, od, "index");
          if (mth.node != NODE_NONE) {
            // A reference-returning `index` makes `obj[i]` the ELEMENT place: deref the returned pointer
            // (the typechecker typed the expression as the element). A value-returning `index` stays a value.
            Ast *const mam = cg_mod_ast(c, mth.module);
            const NodeList mrets = ast_at_const(mam, mth.node)->as.function.returns;
            bool retref = false;
            if (mrets.len == 1) {
              const NodeId mr0 = ast_list(mam, mrets)[0];
              const Node *const mrn = ast_at_const(mam, mr0);
              const NodeId mtn = mrn->kind == NODE_PARAMETER ? mrn->as.parameter.type : mr0;
              retref = mtn != NODE_NONE && ast_at_const(mam, mtn)->kind == NODE_REFERENCE_TYPE;
            }
            // An LVALUE receiver is passed by ADDRESS (never copied into the statement-expression: a
            // reference-returning index would then point into storage that dies at the `})`); only a
            // temporary receiver is spilled by value first.
            char o[32], v[32];
            fresh(c, o, sizeof o);
            if (retref)
              emit(c, "(*");
            if (is_lvalue(c, n->as.index.object)) {
              emit(c, "({ __auto_type %s = ", o);
              emit_prefixed(c, n->as.index.object, "&");
            } else {
              fresh(c, v, sizeof v);
              emit(c, "({ __auto_type %s = ", v);
              emit_expr(c, n->as.index.object);
              emit(c, "; __auto_type %s = &%s", o, v);
            }
            emit(c, "; ");
            emit_op_method(c, bt, om, od, mth);
            emit(c, "(%s, ", o);
            emit_expr(c, n->as.index.index);
            emit(c, retref ? "); }))" : "); })");
            break;
          }
        }
      }
      {
        const NodeId obj = n->as.index.object, idx = n->as.index.index;
        // Bounds checks: the index is wrapped in `__sc_bounds(i, len)` (preserving lvalue-ness of `a[i]`),
        // which aborts on out-of-range. Slices carry a runtime `.len`; fixed arrays use their compile-time
        // length (and a constant index is checked at COMPILE time). Raw pointers stay unchecked (unsafe).
        if (cg_slice_elem(c, ast_type(c->ast, obj), NULL)) { // `s[i]` on `[]T`
          emit_expr(c, obj);
          emit(c, ".ptr[__sc_bounds(");
          emit_expr(c, idx);
          emit(c, ", ");
          emit_expr(c, obj);
          emit(c, ".len)]");
          break;
        }
        const Ty *const oty = ast_type_at(c->ast, subst_resolve(c, ast_type(c->ast, obj)));
        const NodeId lenN = oty->kind == TYPE_ARRAY ? array_length_of(c, obj) : NODE_NONE;
        const long licnt = oty->kind == TYPE_ARRAY && lenN == NODE_NONE ? array_literal_count(c, obj) : -1;
        if (lenN != NODE_NONE || licnt >= 0) { // a fixed array with a known length
          long iv = 0, nv = licnt;
          const bool nconst = lenN != NODE_NONE ? cg_int_lit(c, lenN, &nv) : licnt >= 0;
          if (cg_int_lit(c, idx, &iv) && nconst) { // both constant -> compile-time bounds check
            if (iv < 0 || iv >= nv) {
              const Span sp = ast_at_const(c->ast, idx)->span;
              codegen_errorf(c, sp.start, sp.end - sp.start, "index %ld is out of bounds for an array of length %ld",
                             iv, nv);
            }
            emit_expr(c, obj);
            emit(c, "[");
            emit_expr(c, idx);
            emit(c, "]");
            break;
          }
          emit_expr(c, obj); // runtime check against the array's length
          emit(c, "[__sc_bounds(");
          emit_expr(c, idx);
          emit(c, ", ");
          if (lenN != NODE_NONE)
            emit_expr(c, lenN);
          else
            emit(c, "%ld", licnt);
          emit(c, ")]");
          break;
        }
        emit_expr(c, obj); // raw pointer / unknown-length: no check
        emit(c, "[");
        emit_expr(c, idx);
        emit(c, "]");
        break;
      }
    }
    case NODE_MEMBER: {
      if (n->as.member.path) { // a `::` path value: Enum::Variant, or a qualified const / function ref
        DefId d = ast_resolution_def(c->ast, id); // multi-segment module paths record on the outer node
        if (d.node == NODE_NONE)
          d = ast_resolution_def(c->ast, n->as.member.member); // local Type::Variant records on the member
        const Node *const dn = d.node != NODE_NONE ? ast_at_const(cg_mod_ast(c, d.module), d.node) : NULL;
        if (dn && dn->kind == NODE_CONST && dn->as.const_def.is_extern) {
          char ov[160]; // extern const: the real C macro name from the backing header, not a mangled symbol
          if (cg_symbol_override(c, d.module, d.node, ov, sizeof ov))
            emit_cstr(c, ov);
          else
            emit_ident_mod(c, d.module, dn->as.const_def.name);
        } else if (dn && dn->kind == NODE_CONST) {
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
      const Span msp = name_span(c, n->as.member.member);
      if (c->source[msp.start] >= '0' && c->source[msp.start] <= '9')
        emit(c, "_"); // tuple element `t.0` reads the Tuple<n> field `_0`
      emit_ident(c, msp);
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
    case NODE_SIZEOF:
    case NODE_ALIGNOF: {
      char ty[256];
      render_type_node(c, n->as.single.value, "", ty, sizeof ty); // substitutes T inside a specialization
      emit(c, n->kind == NODE_ALIGNOF ? "_Alignof(%s)" : "sizeof(%s)", ty);
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
        const bool saved = c->no_temp_free;
        for (uint32_t i = 0; i < stmts.len; i++) {
          c->no_temp_free = i + 1 == stmts.len; // the last statement yields the block's value -- don't free it
          emit_indent(c);
          emit_stmt(c, ids[i]);
        }
        c->no_temp_free = saved;
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

// Emit one leaf pattern binding. Value mode: `<T> name = <scrut>;`. Ref mode: `<const?>__auto_type name =
// &(<scrut>);` -- `__auto_type` lets C infer the exact qualified pointer type of `&payload` (which may be a
// reference-to-reference, e.g. `Option<&T>`), sidestepping nested-const placement in the renderer.
static void emit_bind(Codegen *c, const NodeId pid, const Span name, const bool is_mut, const char *scrut,
                      const bool by_ref) {
  emit_indent(c);
  if (by_ref) {
    char nm[128];
    render_ident(c, name, nm, sizeof nm);
    emit(c, "%s__auto_type %s = &(%s);\n", is_mut ? "" : "const ", nm, scrut);
  } else {
    // A Free payload may be freed (or `.free()`d) at arm exit, which takes `&mut`, so it is non-const.
    emit_binding(c, ast_type(c->ast, pid), name, !is_mut && !cg_type_is_free(c, ast_type(c->ast, pid)));
    emit(c, " = %s;\n", scrut);
  }
}

// by_ref: bind each payload by reference (`&payload`) rather than by copy -- set when matching through a
// `&`/`&mut` scrutinee (the binding's type is then `&T`/`&mut T`, set by the type checker).
static void emit_pattern_binds(Codegen *c, const NodeId pid, const char *scrut, const bool by_ref) {
  const Node *const p = ast_at_const(c->ast, pid);
  switch (p->kind) {
    case NODE_PATTERN_NAME: {
      const DefId vd = ast_resolution_def(c->ast, p->as.pattern.name);
      if (vd.node != NODE_NONE && ast_at_const(cg_mod_ast(c, vd.module), vd.node)->kind == NODE_VARIANT)
        break; // a unit-variant tag pattern binds nothing
      // const iff immutable: `Some(mut x)` binds non-const (reassignment / `&mut self` methods); a plain
      // `Some(x)` is immutable, and the typechecker rejects mutating it.
      const bool is_mut = ast_at_const(c->ast, p->as.pattern.name)->as.name.is_mutable;
      emit_bind(c, pid, name_span(c, p->as.pattern.name), is_mut, scrut, by_ref);
      break;
    }
    case NODE_IDENTIFIER:
      emit_bind(c, pid, p->as.name.text, p->as.name.is_mutable, scrut, by_ref);
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
        emit_pattern_binds(c, ids[i], sub, by_ref);
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
          emit_pattern_binds(c, ast_list(c->ast, sub)[0], acc, by_ref);
      }
      break;
    }
    case NODE_PATTERN_OR: { // alternatives must bind the same names; emit the first alternative's binds
      const NodeList alts = p->as.pattern.children;
      if (alts.len)
        emit_pattern_binds(c, ast_list(c->ast, alts)[0], scrut, by_ref);
      break;
    }
    default:
      break; // wildcard / literal / range bind nothing
  }
}

// Free elaboration: a move-mode `switch` arm OWNS the matched payload. Any payload binding NOT moved out of
// the arm (bound but only borrowed, or `_`-ignored as part of a deeper bind) must be freed at arm exit, or
// it leaks. Walk the pattern's leaf bindings and, for each Free one that was not moved out, free it. A
// binding that WAS moved (unconditionally or on some path) is skipped -- its new owner frees it. `do_emit`
// false just counts (so the caller knows whether the arm needs the free). Returns the leaf-free count.
static int cg_arm_frees(Codegen *c, const NodeId pid, const bool do_emit) {
  const Node *const p = ast_at_const(c->ast, pid);
  switch (p->kind) {
    case NODE_PATTERN_NAME:
    case NODE_IDENTIFIER: {
      const Span nm = p->kind == NODE_PATTERN_NAME ? name_span(c, p->as.pattern.name) : p->as.name.text;
      if (p->kind == NODE_PATTERN_NAME) {
        const DefId vd = ast_resolution_def(c->ast, p->as.pattern.name);
        if (vd.node != NODE_NONE && ast_at_const(cg_mod_ast(c, vd.module), vd.node)->kind == NODE_VARIANT)
          return 0; // a unit-variant tag pattern binds nothing
      }
      const TypeId t = ast_type(c->ast, pid);
      if (!cg_type_is_free(c, t) || cg_is_moved(c, pid) || cg_is_cond_moved(c, pid))
        return 0; // not Free, or moved out (its new owner frees it)
      if (do_emit) {
        emit_indent(c);
        emit_free_target(c, t);
        char b[128];
        render_ident(c, nm, b, sizeof b);
        emit(c, "(&%s);\n", b);
      }
      return 1;
    }
    case NODE_PATTERN_TUPLE: {
      const NodeList ch = p->as.pattern.children;
      const NodeId *const ids = ast_list(c->ast, ch);
      int n = 0;
      for (uint32_t i = 0; i < ch.len; i++)
        n += cg_arm_frees(c, ids[i], do_emit);
      return n;
    }
    case NODE_PATTERN_STRUCT: {
      const NodeList ch = p->as.pattern.children;
      const NodeId *const ids = ast_list(c->ast, ch);
      int n = 0;
      for (uint32_t i = 0; i < ch.len; i++) {
        const NodeList sub = ast_at_const(c->ast, ids[i])->as.pattern.children;
        if (sub.len)
          n += cg_arm_frees(c, ast_list(c->ast, sub)[0], do_emit);
      }
      return n;
    }
    case NODE_PATTERN_OR: {
      const NodeList alts = p->as.pattern.children;
      return alts.len ? cg_arm_frees(c, ast_list(c->ast, alts)[0], do_emit) : 0;
    }
    default:
      return 0;
  }
}

// Emit one arm's body per mode: 0 statement, 1 assign to `result`, 2 `return`. In move mode (by_ref false)
// the arm's not-moved-out Free payloads are freed after the body value is taken (for `return`, captured
// into a temp so the free runs before the function returns).
static void emit_arm_body(Codegen *c, const NodeId body, const int mode, const char *result, const NodeId pattern,
                          const bool by_ref) {
  // A diverging arm (`None => panic(..)`): the _Noreturn call IS the whole body -- no value to
  // assign or return, no frees to run (control never continues past it).
  const TypeId bt0 = ast_type(c->ast, body);
  if (bt0 != TYPE_NONE && ast_type_at(c->ast, bt0)->kind == TYPE_NEVER) {
    emit_indent(c);
    emit_expr(c, body);
    emit(c, ";\n");
    return;
  }
  const int frees = by_ref ? 0 : cg_arm_frees(c, pattern, false);
  if (mode == 2) {
    emit_indent(c);
    if (!frees) {
      emit(c, "return ");
      emit_expr(c, body);
      emit(c, ";\n");
      return;
    }
    const TypeId rt = ast_type(c->ast, body);
    const Ty *const rty = rt != TYPE_NONE ? ast_type_at(c->ast, rt) : NULL;
    const bool voidret = !rty || (rty->kind == TYPE_BUILTIN && rty->as.builtin == BT_VOID);
    char r[32];
    if (voidret) {
      emit(c, "{ ");
      emit_expr(c, body);
      emit(c, ";\n");
    } else {
      fresh(c, r, sizeof r);
      emit(c, "{ __auto_type %s = ", r);
      emit_expr(c, body);
      emit(c, ";\n");
    }
    cg_arm_frees(c, pattern, true);
    emit_indent(c);
    emit(c, voidret ? "return; }\n" : "return %s; }\n", r);
    return;
  }
  if (mode == 1) {
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
  if (frees)
    cg_arm_frees(c, pattern, true);
}

// Emit `__auto_type scrut = <value>;` then an if/else-if chain over the arms. mode: 0 statement,
// 1 assign each body to `result`, 2 `return` each body.
static void emit_match_core(Codegen *c, const NodeId id, const int mode, const char *result) {
  const Node *const n = ast_at_const(c->ast, id);
  char scrut[32];
  fresh(c, scrut, sizeof scrut);
  // Binding mode: through a `&`/`&mut`/pointer scrutinee, bind `scrut` to a POINTER to the aggregate (no
  // whole-value copy) so payloads can be borrowed in place (`&scrut->payload...`); for an owned value,
  // copy it into a temp and bind payloads by value. The type checker set each binding's type to match.
  const TypeId outer = ast_type(c->ast, n->as.match_expr.value);
  unsigned derefs = 0;
  TypeId base = outer;
  for (const Ty *y = ast_type_at(c->ast, base); y->kind == TYPE_POINTER || y->kind == TYPE_REFERENCE;
       y = ast_type_at(c->ast, base))
    base = y->as.elem, derefs++;
  const bool by_ref = derefs > 0;
  const bool mut_ref = by_ref && ast_type_at(c->ast, outer)->qualifier == TYPE_QUAL_MUT;
  const TypeKind bk = ast_type_at(c->ast, base)->kind;
  char access[40];
  emit_indent(c);
  if (by_ref) {
    char aggr[256];
    render_type_id(c, base, "", aggr, sizeof aggr);
    emit(c, "%s%s *const %s = ", mut_ref ? "" : "const ", aggr, scrut); // pointer to the matched aggregate
    for (unsigned i = 0; i + 1 < derefs; i++) // leave one indirection: `&*v == v`, so derefs-1 derefs
      emit(c, "(*");
    emit_expr(c, n->as.match_expr.value);
    for (unsigned i = 0; i + 1 < derefs; i++)
      emit(c, ")");
    snprintf(access, sizeof access, "(*%s)", scrut); // patterns read/borrow through the pointer
  } else if (bk == TYPE_ERROR || bk == TYPE_FUNCTION || bk == TYPE_GENERIC) {
    emit(c, "const __auto_type %s = ", scrut); // scrutinee temp is only read
    emit_expr(c, n->as.match_expr.value);
    snprintf(access, sizeof access, "%s", scrut);
  } else {
    char d[300];
    render_binding_id(c, base, scrut, true, d, sizeof d);
    emit_cstr(c, d);
    emit(c, " = ");
    emit_expr(c, n->as.match_expr.value);
    snprintf(access, sizeof access, "%s", scrut);
  }
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
      emit_pattern_test(c, arm->as.match_arm.pattern, access);
      emit(c, ") {\n");
      c->depth++;
      emit_pattern_binds(c, arm->as.match_arm.pattern, access, by_ref);
      emit_arm_body(c, arm->as.match_arm.body, mode, result, arm->as.match_arm.pattern, by_ref);
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
    emit_pattern_test(c, arm->as.match_arm.pattern, access);
    emit(c, ") {\n");
    c->depth++;
    emit_pattern_binds(c, arm->as.match_arm.pattern, access, by_ref);
    if (guard != NODE_NONE) {
      emit_indent(c);
      emit(c, "if (");
      emit_condition(c, guard);
      emit(c, ") {\n");
      c->depth++;
    }
    emit_arm_body(c, arm->as.match_arm.body, mode, result, arm->as.match_arm.pattern, by_ref);
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

// Emit a block whose fall-through cleanup runs the defers/frees registered down to `dbase`. The function
// body passes dbase=0 so its owned parameters (registered before the block) are torn down at its close.
// True when control cannot fall through past this statement (it always returns/breaks/continues), so an
// enclosing block's fall-through cleanup after it would be unreachable, duplicate code -- the diverting
// path (emit_return / break / continue) has already run every pending free.
static bool cg_stmt_diverges(Codegen *c, const NodeId id) {
  const Node *const n = ast_at_const(c->ast, id);
  switch (n->kind) {
    case NODE_RETURN:
    case NODE_BREAK:
    case NODE_CONTINUE:
      return true;
    case NODE_BLOCK: {
      const NodeList s = n->as.block.statements;
      return s.len > 0 && cg_stmt_diverges(c, ast_list(c->ast, s)[s.len - 1]);
    }
    case NODE_IF: // an if diverges only when it has an else and BOTH branches diverge
      return n->as.if_stmt.else_branch != NODE_NONE && cg_stmt_diverges(c, n->as.if_stmt.then_branch) &&
             cg_stmt_diverges(c, n->as.if_stmt.else_branch);
    default:
      return false;
  }
}

static void emit_block_from(Codegen *c, const NodeId id, const uint32_t dbase) {
  const Node *const n = ast_at_const(c->ast, id);
  emit(c, "{\n");
  c->depth++;
  for (uint32_t i = 0; i < c->nparam_flags; i++) { // cond-moved Free params: free flags at function-body top
    char fl[32];
    cg_move_flag(fl, sizeof fl, c->param_flags[i]);
    emit_indent(c);
    emit(c, "bool %s = false;\n", fl);
  }
  c->nparam_flags = 0; // consumed -- nested blocks must not re-emit them
  for (uint32_t i = 0; i < c->nunused_params; i++) { // unused parameters: cast to void at function-body top
    char pn[128];
    render_ident(c, name_span(c, ast_at_const(c->ast, c->unused_params[i])->as.parameter.name), pn, sizeof pn);
    emit_indent(c);
    emit(c, "(void)%s;\n", pn);
  }
  c->nunused_params = 0; // consumed -- nested blocks must not re-emit them
  const NodeList stmts = n->as.block.statements;
  const NodeId *const ids = ast_list(c->ast, stmts);
  for (uint32_t i = 0; i < stmts.len; i++) {
    emit_indent(c);
    emit_stmt(c, ids[i]);
  }
  // Fall-through cleanup -- skipped when the block always diverges (its last statement returns/breaks/
  // continues), since that path already ran every pending free and the code here is unreachable.
  if (!(stmts.len > 0 && cg_stmt_diverges(c, ids[stmts.len - 1])))
    emit_defers_to(c, dbase);
  c->defer_top = dbase;
  c->depth--;
  emit_indent(c);
  emit(c, "}");
}

static void emit_block(Codegen *c, const NodeId id) {
  emit_block_from(c, id, c->defer_top); // defers/frees registered in this block run, reversed, at its close
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
      const TypeId vt = ast_type(c->ast, s->as.single.value);
      if (vt == TYPE_NONE || ast_type_at(c->ast, vt)->kind != TYPE_NEVER)
        emit(c, "%s = ", result); // a diverging tail (`else { panic(..) }`) emits the call alone
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

// Static element count of an array binding inferred from its array-literal initializer
// (an unannotated `let a = [..]` decays to a pointer, so the length lives only in the AST).
// -1 when not statically determinable.
static long array_literal_count(Codegen *c, NodeId obj) {
  const Node *o = ast_at_const(c->ast, obj);
  if (o->kind == NODE_ARRAY_LITERAL)
    return (long)o->as.array_literal.elements.len;
  if (o->kind != NODE_IDENTIFIER)
    return -1;
  const NodeId d = ast_resolution(c->ast, obj);
  if (d == NODE_NONE)
    return -1;
  const Node *const dn = ast_at_const(c->ast, d);
  const NodeId v = dn->kind == NODE_LET ? dn->as.let_stmt.value : NODE_NONE;
  return v != NODE_NONE && ast_at_const(c->ast, v)->kind == NODE_ARRAY_LITERAL
             ? (long)ast_at_const(c->ast, v)->as.array_literal.elements.len
             : -1;
}

// Parse a non-negative integer literal node's value (decimal / 0x / 0b / 0o, `_` separators and any type
// suffix tolerated). Returns true with *out set; false if `e` is not a plain integer literal.
static bool cg_int_lit(Codegen *c, const NodeId e, long *out) {
  const Node *const n = ast_at_const(c->ast, e);
  if (n->kind != NODE_LITERAL || n->as.literal.token_type != IntegerLiteral)
    return false;
  char buf[32];
  size_t k = 0;
  for (uint32_t i = n->as.literal.raw.start; i < n->as.literal.raw.end && k + 1 < sizeof buf; i++) {
    const uint8_t ch = c->source[i];
    if (ch == '_')
      continue;
    if (k == 0 && (ch == '0') && i + 1 < n->as.literal.raw.end) { // keep base prefix
      buf[k++] = (char)ch;
      continue;
    }
    const bool hexish = (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F') ||
                        ch == 'x' || ch == 'X' || ch == 'b' || ch == 'B' || ch == 'o' || ch == 'O';
    if (!hexish)
      break; // a type suffix (e.g. `5usize`) -- stop
    buf[k++] = (char)ch;
  }
  buf[k] = '\0';
  if (k == 0)
    return false;
  char *end = NULL;
  const long v = strtol(buf, &end, 0);
  if (end == buf)
    return false;
  *out = v;
  return true;
}

// The inclusive range of a signed integer builtin, as long long.
static void cg_int_range(const BuiltinType b, long long *mn, long long *mx) {
  switch (b) {
    case BT_I8: *mn = -128; *mx = 127; break;
    case BT_I16: *mn = -32768; *mx = 32767; break;
    case BT_I32: *mn = INT32_MIN; *mx = INT32_MAX; break;
    default: *mn = INT64_MIN; *mx = INT64_MAX; break; // i64 / isize
  }
}

// Checked integer arithmetic for `+ - * / %`. Returns true if it emitted a (possibly checked) form; false
// to let the caller emit the plain operator. Signed `+ - *` trap on overflow; integer `/ %` trap on
// divide-by-zero; UNSIGNED WRAPS (no check -- the prelude's hashing/probing rely on it). In a constant
// context the plain operator is emitted (kept a constant expression) and a literal-operand overflow /
// divide-by-zero is a COMPILE-TIME error.
static bool cg_emit_checked_arith(Codegen *c, const Node *const n, const NodeId id) {
  const TokenType op = n->as.binary.op;
  const bool add = op == Plus, sub = op == Minus, mul = op == Star, dv = op == Slash, rm = op == Percent;
  if (!(add || sub || mul || dv || rm))
    return false;
  const TypeId rt = subst_resolve(c, ast_type(c->ast, id));
  const Ty *const ry = rt == TYPE_NONE ? NULL : ast_type_at(c->ast, rt);
  if (!ry || ry->kind != TYPE_BUILTIN)
    return false;
  const BuiltinType b = ry->as.builtin;
  const bool sgn = b == BT_I8 || b == BT_I16 || b == BT_I32 || b == BT_I64 || b == BT_ISIZE;
  const bool uns = b == BT_U8 || b == BT_U16 || b == BT_U32 || b == BT_U64 || b == BT_USIZE;
  if (!sgn && !uns)
    return false; // floats etc.: caller emits plain

  const NodeId L = n->as.binary.left, R = n->as.binary.right;
  // Both operands must be integers too: pointer difference `p - q` also yields a signed integer but is not
  // integer arithmetic, and pointer arithmetic `p + i` must not be overflow-trapped as integers.
  const Ty *const lt = ast_type_at(c->ast, subst_resolve(c, ast_type(c->ast, L)));
  const Ty *const rtt = ast_type_at(c->ast, subst_resolve(c, ast_type(c->ast, R)));
  if (lt->kind != TYPE_BUILTIN || rtt->kind != TYPE_BUILTIN)
    return false;
  long lv, rv;
  if (cg_int_lit(c, L, &lv) && cg_int_lit(c, R, &rv)) { // both literal -> evaluate at compile time
    const char *bad = NULL;
    if ((dv || rm) && rv == 0) {
      bad = "constant division by zero";
    } else if (sgn) {
      long long res = 0;
      bool ov = add   ? __builtin_saddll_overflow(lv, rv, &res)
                : sub ? __builtin_ssubll_overflow(lv, rv, &res)
                : mul ? __builtin_smulll_overflow(lv, rv, &res)
                : (res = dv ? lv / rv : lv % rv, false);
      long long mn, mx;
      cg_int_range(b, &mn, &mx);
      if (ov || res < mn || res > mx)
        bad = "constant arithmetic overflow";
    }
    if (bad) {
      const Span sp = ast_at_const(c->ast, id)->span;
      codegen_errorf(c, sp.start, sp.end - sp.start, "%s", bad);
    }
  }
  if (c->const_ctx) // must remain a constant expression: no runtime-trap wrapper here
    return false;

  char rts[64];
  render_type_id(c, rt, "", rts, sizeof rts);
  if (sgn && (add || sub || mul)) {
    emit(c, "({ %s __sc_r; if (__builtin_%s_overflow(", rts, add ? "add" : sub ? "sub" : "mul");
    emit_expr(c, L);
    emit(c, ", ");
    emit_expr(c, R);
    emit(c, ", &__sc_r)) { __sc_panic(\"arithmetic overflow\"); } __sc_r; })");
    return true;
  }
  if (dv || rm) { // divide-by-zero trap for both signed and unsigned
    char a[32], d[32];
    fresh(c, a, sizeof a);
    fresh(c, d, sizeof d);
    emit(c, "({ %s %s = ", rts, a);
    emit_expr(c, L);
    emit(c, "; %s %s = ", rts, d);
    emit_expr(c, R);
    emit(c, "; if (%s == 0) { __sc_panic(\"divide by zero\"); } (%s %s %s); })", d, a, dv ? "/" : "%", d);
    return true;
  }
  return false; // unsigned + - * : plain (wraps)
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
  TypeId relem;
  if (cg_range_elem(c, ast_type(c->ast, n->as.for_stmt.iterable), &relem)) { // `for x in r` over a Range value
    char r[32], styp[200], nm[128];
    fresh(c, r, sizeof r);
    render_type_id(c, ast_type(c->ast, n->as.for_stmt.iterable), r, styp, sizeof styp);
    render_ident(c, name_span(c, n->as.for_stmt.binding), nm, sizeof nm);
    emit(c, "{\n");
    c->depth++;
    emit_indent(c);
    emit_cstr(c, styp); // `Range__T __scN = <iterable>;`
    emit(c, " = ");
    emit_expr(c, n->as.for_stmt.iterable);
    emit(c, ";\n");
    emit_indent(c);
    emit(c, "for (");
    emit_binding(c, relem, name_span(c, n->as.for_stmt.binding), false); // mutable: `x++` advances it
    emit(c, " = %s.start; %s.inclusive ? %s <= %s.end : %s < %s.end; %s++) {\n", r, r, nm, r, nm, r, nm);
    c->depth++;
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
        const TypeId rvt0 = ast_type(c->ast, vids[0]);
        if (rvt0 != TYPE_NONE && ast_type_at(c->ast, rvt0)->kind == TYPE_NEVER) {
          emit_expr(c, vids[0]); // diverging: the call alone; pending defers never run (abort)
          emit(c, ";\n");
          c->depth--;
          emit_indent(c);
          emit(c, "}\n");
          return;
        }
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
    const TypeId rvt = ast_type(c->ast, vids[0]);
    if (rvt != TYPE_NONE && ast_type_at(c->ast, rvt)->kind == TYPE_NEVER) {
      emit_expr(c, vids[0]); // `return panic(..);`: the _Noreturn call alone (C rejects returning void)
      emit(c, ";\n");
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

// The variant of enum `enumDecl` (in module `m`) named `lit`, or NODE_NONE (so `?` can tell Option from
// Result by probing for a "None" variant).
static NodeId cg_enum_variant(Codegen *c, const ModuleId m, const NodeId enumDecl, const char *const lit) {
  const Ast *const a = cg_mod_ast(c, m);
  const Node *const e = ast_at_const(a, enumDecl);
  if (e->kind != NODE_ENUM)
    return NODE_NONE;
  const NodeList ms = e->as.aggregate.members;
  const NodeId *const ids = ast_list(a, ms);
  for (uint32_t i = 0; i < ms.len; i++) {
    const Node *const v = ast_at_const(a, ids[i]);
    if (v->kind == NODE_VARIANT && span_is(cg_mod_src(c, m), ast_at_const(a, v->as.variant.name)->as.name.text, lit))
      return ids[i];
  }
  return NODE_NONE;
}

// `expr?`: unwrap an Option<T> / Result<T,E>, or run the pending defers and early-return None / Err from the
// enclosing function (which the type checker has verified returns the matching family). A GNU statement-expr
// yields the Some/Ok payload on the fall-through path.
static void emit_try(Codegen *c, const Node *const n) {
  const NodeId operand = n->as.unary.operand;
  const Ty *const bt = ast_type_at(c->ast, subst_resolve(c, strip_ptr(c, ast_type(c->ast, operand))));
  if (bt->kind != TYPE_INSTANCE) { // defensive: the type checker should have rejected this
    emit_expr(c, operand);
    return;
  }
  const TyInstance *const it = ast_instance(c->ast, bt->as.inst);
  const ModuleId om = it->module;
  const NodeId od = it->decl;
  const NodeId noneV = cg_enum_variant(c, om, od, "None");
  const bool is_option = noneV != NODE_NONE;
  const NodeId failV = is_option ? noneV : cg_enum_variant(c, om, od, "Err");
  const NodeId okV = cg_enum_variant(c, om, od, is_option ? "Some" : "Ok");
  char okName[128], failName[128];
  render_variant_name(c, om, okV, okName, sizeof okName);
  render_variant_name(c, om, failV, failName, sizeof failName);
  char rtn[200];
  rtn[0] = '\0';
  if (c->current_fn_ret_node != NODE_NONE)
    render_type_node(c, c->current_fn_ret_node, "", rtn, sizeof rtn);
  char tmp[32];
  fresh(c, tmp, sizeof tmp);
  emit(c, "({ __auto_type %s = ", tmp);
  emit_expr(c, operand);
  emit(c, "; if (%s.tag == ", tmp);
  emit_tag_mod(c, om, od, failV);
  emit(c, ") {\n");
  c->depth++;
  emit_defers_to(c, 0); // like a return: run every live defer / scope-exit free first (defer_top is untouched)
  emit_indent(c);
  emit(c, "return (%s){ .tag = ", rtn);
  emit_tag_mod(c, om, od, failV);
  if (!is_option) // carry the error payload through (same error type; cross-type conversion is rejected upstream)
    emit(c, ", .payload.%s._0 = %s.payload.%s._0", failName, tmp, failName);
  emit(c, " };\n");
  c->depth--;
  emit_indent(c);
  emit(c, "} %s.payload.%s._0; })", tmp, okName);
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
  // A discarded owning temporary (`make_string();`, `v.pop();`) is never bound, so it would leak. If the
  // value is a Free-typed rvalue (not a place -- a place is still owned by its binding, and an assignment
  // stores into one), materialize and free it. Places/assignments fall through to their own cleanup.
  const TypeId vt = ast_type(c->ast, v);
  if (vt != TYPE_NONE && !c->no_temp_free && n->kind != NODE_ASSIGNMENT && !is_lvalue(c, v) && cg_type_is_free(c, vt)) {
    char tmp[32];
    fresh(c, tmp, sizeof tmp);
    emit(c, "{ __auto_type %s = ", tmp);
    emit_expr(c, v);
    emit(c, "; ");
    emit_free_target(c, vt);
    emit(c, "(&%s); }\n", tmp);
    return;
  }
  emit_expr(c, v);
  emit(c, ";\n");
}

static void emit_defers_to(Codegen *c, const uint32_t base) {
  for (uint32_t i = c->defer_top; i-- > base;) {
    emit_indent(c);
    if (c->defer_kind[i] == 1) // an automatic RAII free of a local binding
      emit_auto_free(c, c->defer_stack[i]);
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
    // const iff the binding is immutable AND not Free -- a Free element's scope-exit free takes `&mut self`,
    // so it must be non-const (mutability is otherwise a binding property only).
    const bool element_const = !n->as.let_stmt.is_mutable && !cg_type_is_free(c, ast_type(c->ast, nids[i]));
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
  const bool sc = c->const_ctx;
  c->const_ctx = true; // the condition must stay a constant expression (no runtime-trap wrapper)
  emit_expr(c, n->as.binary.left);
  c->const_ctx = sc;
  emit(c, ", ");
  if (n->as.binary.right != NODE_NONE)
    emit_reescaped(c, ast_at_const(c->ast, n->as.binary.right)->as.literal.raw, false);
  else
    emit(c, "\"static assertion failed\"");
  emit(c, ");\n");
}

// The `free` method of a type that implements the Free interface (`extend T as Free`), or {_,NODE_NONE}.
// Only an explicit `as Free` extend opts a type into RAII auto-free. Searches the type's home + current module.
// The `as Free` extend on `(tmod, tdecl)` (its module or the current module), or {_,NODE_NONE}. Returns
// (module, extend-node-id) of the first matching `extend T as Free` block.
static DefId cg_free_extend(Codegen *c, const ModuleId tmod, const NodeId tdecl) {
  const ModuleId scopes[2] = {tmod, c->ast->module};
  const int ns = tmod == c->ast->module ? 1 : 2;
  for (int s = 0; s < ns; s++) {
    const ModuleId m = scopes[s];
    Ast *const a = cg_mod_ast(c, m);
    const NodeList items = ast_at_const(a, a->root)->as.program.items;
    const NodeId *const ids = ast_list(a, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const it = ast_at_const(a, ids[i]);
      if (it->kind != NODE_EXTEND || it->as.extend_def.interface_type == NODE_NONE || it->as.extend_def.target_type == NODE_NONE)
        continue;
      const DefId tg = ast_resolution_def(a, it->as.extend_def.target_type);
      if (tg.module != tmod || tg.node != tdecl)
        continue;
      const DefId tr = ast_resolution_def(a, it->as.extend_def.interface_type);
      if (tr.node == NODE_NONE)
        continue;
      const Node *const trn = ast_at_const(cg_mod_ast(c, tr.module), tr.node);
      if (trn->kind == NODE_INTERFACE &&
          span_is(cg_mod_src(c, tr.module), ast_at_const(cg_mod_ast(c, tr.module), trn->as.interface_def.name)->as.name.text,
                  "Free"))
        return (DefId){m, ids[i]};
    }
  }
  return (DefId){0, NODE_NONE};
}

// The `free` method inside `(tmod, tdecl)`'s `as Free` extend, or {_,NODE_NONE} when there is no such extend.
static DefId cg_free_method(Codegen *c, const ModuleId tmod, const NodeId tdecl) {
  const DefId ext = cg_free_extend(c, tmod, tdecl);
  if (ext.node == NODE_NONE)
    return (DefId){0, NODE_NONE};
  Ast *const a = cg_mod_ast(c, ext.module);
  const NodeList ms = ast_at_const(a, ext.node)->as.extend_def.items;
  const NodeId *const mids = ast_list(a, ms);
  for (uint32_t j = 0; j < ms.len; j++) {
    const Node *const mn = ast_at_const(a, mids[j]);
    if (mn->kind == NODE_FUNCTION && span_is(cg_mod_src(c, ext.module), ast_at_const(a, mn->as.function.name)->as.name.text, "free"))
      return (DefId){ext.module, mids[j]};
  }
  return (DefId){0, NODE_NONE};
}

// Is generic param `gp` (in module `m`) bound by the `Free` interface (`<T: Free>`)?
static bool cg_param_has_free_bound(Codegen *c, const ModuleId m, const NodeId gp) {
  Ast *const a = cg_mod_ast(c, m);
  const NodeList bs = ast_at_const(a, gp)->as.generic_param.bounds;
  const NodeId *const bids = ast_list(a, bs);
  for (uint32_t i = 0; i < bs.len; i++) {
    const DefId bd = ast_resolution_def(a, bids[i]);
    if (bd.node == NODE_NONE)
      continue;
    const Node *const bn = ast_at_const(cg_mod_ast(c, bd.module), bd.node);
    if (bn->kind == NODE_INTERFACE &&
        span_is(cg_mod_src(c, bd.module), ast_at_const(cg_mod_ast(c, bd.module), bn->as.interface_def.name)->as.name.text,
                "Free"))
      return true;
  }
  return false;
}

// Does the (subst-resolved) type implement the Free interface? Such a value owns resources -> it gets an
// RAII Free call at scope exit, and a binding/param of it is emitted non-`const` (free takes `&mut self`).
// For a conditional extend (`extend<T: Free> Option<T> as Free`) the instance must satisfy the `Free` bounds
// (Option<i32> is NOT Free -- its `free` is never monomorphized -- but Option<String> is).
static bool cg_type_is_free(Codegen *c, const TypeId ty) {
  const Ty *const y = ast_type_at(c->ast, subst_resolve(c, ty));
  if (y->kind == TYPE_STRUCT)
    return cg_free_method(c, y->module, y->as.decl).node != NODE_NONE;
  if (y->kind != TYPE_INSTANCE)
    return false;
  const TyInstance *const ii = ast_instance(c->ast, y->as.inst);
  const DefId extend = cg_free_extend(c, ii->module, ii->decl);
  if (extend.node == NODE_NONE)
    return false;
  // Every `Free`-bounded type parameter must map to a `Free` argument (positional with the target's args).
  Ast *const ia = cg_mod_ast(c, extend.module);
  const NodeList gens = ast_at_const(ia, extend.node)->as.extend_def.generics;
  const NodeId *const gids = ast_list(ia, gens);
  for (uint32_t i = 0; i < gens.len && i < ii->n; i++)
    if (cg_param_has_free_bound(c, extend.module, gids[i]) && !cg_type_is_free(c, ii->args[i]))
      return false;
  return true;
}

// Was the local `decl` moved out somewhere in the current function (so it must not be auto-freed)?
static bool cg_is_moved(const Codegen *c, const NodeId decl) {
  for (uint32_t i = 0; i < c->nmoved; i++)
    if (c->moved[i] == decl)
      return true;
  return false;
}

static bool cg_is_cond_moved(const Codegen *c, const NodeId decl) {
  for (uint32_t i = 0; i < c->ncond_moved; i++)
    if (c->cond_moved[i] == decl)
      return true;
  return false;
}

// Identifier `expr` is a move site (a `let`/`return`/assignment RHS, struct field, or by-value call arg
// reference to a current-module owned Free binding). `pass`/`cond` drive the two-pass classification:
//  pass 0 records UNCONDITIONAL moves (cond==false) into `moved` -- those skip auto-free outright;
//  pass 1 records the move SITES of bindings moved only conditionally (cond==true and not unconditional),
//          into `cond_moved` + `cond_sites`, so each gets a runtime free flag instead.
// `site`: record `expr` as a flag-set site (`(flag=true, expr)` wraps the value at emit). False for an
// `x.free()` receiver -- there the value is taken by ADDRESS (`&x`), which a comma-expr can't be, so the
// flag is set around the whole call instead (emit_call); the binding still joins cond_moved for its flag.
static void cg_mark_move(Codegen *c, NodeId expr, const bool cond, const int pass, const bool site) {
  if (expr == NODE_NONE)
    return;
  // `move x` / `unsafe x` are transparent wrappers: the move is of the wrapped binding. Without
  // peeling, `let t = move s;` would leave s untracked -- both s and t auto-freed, a double free.
  const Node *me = ast_at_const(c->ast, expr);
  while (me->kind == NODE_UNARY && (me->as.unary.op == Move || me->as.unary.op == Unsafe)) {
    expr = me->as.unary.operand;
    me = ast_at_const(c->ast, expr);
  }
  // A partial move of a Free field (`let x = s.field`) hands the resource to `x`, but the owning binding `s`
  // would still free that field at scope exit -- a double free. Record it as a move of `s` itself so its
  // auto-free is elided (the moved-out value now owns the resource). Walks to the root binding.
  if (me->kind == NODE_MEMBER && !me->as.member.path && cg_type_is_free(c, ast_type(c->ast, expr))) {
    cg_mark_move(c, me->as.member.object, cond, pass, false);
    return;
  }
  if (me->kind != NODE_IDENTIFIER)
    return;
  const DefId d = ast_resolution_def(c->ast, expr);
  if (d.module != c->ast->module || d.node == NODE_NONE)
    return;
  const NodeKind dk = ast_at_const(c->ast, d.node)->kind;
  // A tuple-let element binds under an identifier node that back-points to its `let`; accept it so a move
  // of `a` in `let (a, b) = ..` is recorded (otherwise it would be both moved out and auto-freed -> double free).
  bool tuple_elem = false;
  if (dk == NODE_IDENTIFIER) {
    const NodeId let = ast_resolution(c->ast, d.node);
    tuple_elem = let != NODE_NONE && ast_at_const(c->ast, let)->kind == NODE_LET &&
                 ast_at_const(c->ast, ast_at_const(c->ast, let)->as.let_stmt.name)->kind == NODE_PATTERN_TUPLE;
  }
  // `let`/param bindings and `switch` payload bindings (so move-out of a matched payload is recorded, and
  // a payload NOT moved out can be freed at arm exit -- see cg_arm_frees), plus tuple-let elements.
  if (dk != NODE_LET && dk != NODE_PARAMETER && dk != NODE_PATTERN_NAME && !tuple_elem)
    return;
  if (!cg_type_is_free(c, ast_type(c->ast, expr))) // only Free bindings are tracked (others need no free)
    return;
  if (pass == 0) {
    // A `switch` payload binding lives only within its arm, so a move of it is effectively unconditional
    // (no runtime free flag needed) -- record it directly. Other bindings need a guaranteed (cond==false) path.
    if ((!cond || dk == NODE_PATTERN_NAME) && c->nmoved < (uint32_t)(sizeof c->moved / sizeof c->moved[0]))
      c->moved[c->nmoved++] = d.node; // moved -> elide its free / arm-free entirely
    return;
  }
  if (dk == NODE_PATTERN_NAME) // payload bindings are handled in pass 0; they never use the flag machinery
    return;
  if (!cond || cg_is_moved(c, d.node)) // pass 1: only conditional moves of not-already-elided bindings
    return;
  if (!cg_is_cond_moved(c, d.node) && c->ncond_moved < (uint32_t)(sizeof c->cond_moved / sizeof c->cond_moved[0]))
    c->cond_moved[c->ncond_moved++] = d.node;
  if (site && c->ncond_sites < (uint32_t)(sizeof c->cond_sites / sizeof c->cond_sites[0]))
    c->cond_sites[c->ncond_sites++] = expr;
}

// A value in move position (`return e`, `let x = e`, a call arg, ...) may itself be a match/if/block whose
// VALUE flows out through its arm/branch/tail expressions -- those tail bindings are the ones really moved.
// Propagate the move to them so a tail binding/param is not also auto-freed (a double-free).
static void cg_mark_move_tail(Codegen *c, const NodeId e, const bool cond, const int pass) {
  if (e == NODE_NONE)
    return;
  const Node *const n = ast_at_const(c->ast, e);
  switch (n->kind) {
    case NODE_MATCH: {
      const NodeList arms = n->as.match_expr.arms;
      const NodeId *const ids = ast_list(c->ast, arms);
      for (uint32_t i = 0; i < arms.len; i++)
        cg_mark_move_tail(c, ast_at_const(c->ast, ids[i])->as.match_arm.body, true, pass); // arms are alternatives
      break;
    }
    case NODE_IF:
      cg_mark_move_tail(c, n->as.if_stmt.then_branch, true, pass);
      cg_mark_move_tail(c, n->as.if_stmt.else_branch, true, pass);
      break;
    case NODE_BLOCK: {
      const NodeList ss = n->as.block.statements; // a block's value is its final non-assignment expr statement
      if (ss.len) {
        const Node *const last = ast_at_const(c->ast, ast_list(c->ast, ss)[ss.len - 1]);
        if (last->kind == NODE_EXPRESSION_STATEMENT &&
            ast_at_const(c->ast, last->as.single.value)->kind != NODE_ASSIGNMENT)
          cg_mark_move_tail(c, last->as.single.value, cond, pass);
      }
      break;
    }
    default:
      cg_mark_move(c, e, cond, pass, true); // a bare binding (else a no-op)
  }
}

// Pre-pass over a function body classifying moved Free bindings (so RAII elides or guards their free). A
// move is a bare binding used as a `let` initializer, assignment RHS, returned value, struct field value,
// or by-value call argument. `cond` is true once inside an if/match/loop branch (a not-always-taken path).
static void cg_scan_moves(Codegen *c, const NodeId id, const bool cond, const int pass) {
  if (id == NODE_NONE)
    return;
  const Node *const n = ast_at_const(c->ast, id);
  switch (n->kind) {
    case NODE_BLOCK: {
      const NodeList ss = n->as.block.statements;
      const NodeId *const ids = ast_list(c->ast, ss);
      for (uint32_t i = 0; i < ss.len; i++)
        cg_scan_moves(c, ids[i], cond, pass);
      break;
    }
    case NODE_LET:
      cg_mark_move_tail(c, n->as.let_stmt.value, cond, pass);
      cg_scan_moves(c, n->as.let_stmt.value, cond, pass);
      break;
    case NODE_RETURN: {
      const NodeList vs = n->as.return_stmt.values;
      const NodeId *const ids = ast_list(c->ast, vs);
      for (uint32_t i = 0; i < vs.len; i++) {
        cg_mark_move_tail(c, ids[i], cond, pass);
        cg_scan_moves(c, ids[i], cond, pass);
      }
      break;
    }
    case NODE_ASSIGNMENT:
      cg_mark_move_tail(c, n->as.binary.right, cond, pass);
      cg_scan_moves(c, n->as.binary.left, cond, pass);
      cg_scan_moves(c, n->as.binary.right, cond, pass);
      break;
    case NODE_STRUCT_INITIALIZER: {
      const NodeList fs = n->as.struct_initializer.fields;
      const NodeId *const ids = ast_list(c->ast, fs);
      for (uint32_t i = 0; i < fs.len; i++) {
        const NodeId v = ast_at_const(c->ast, ids[i])->as.field_initializer.value;
        cg_mark_move_tail(c, v, cond, pass);
        cg_scan_moves(c, v, cond, pass);
      }
      break;
    }
    case NODE_IF: // the branches are conditional paths; the condition always runs
      cg_scan_moves(c, n->as.if_stmt.condition, cond, pass);
      cg_scan_moves(c, n->as.if_stmt.then_branch, true, pass);
      cg_scan_moves(c, n->as.if_stmt.else_branch, true, pass);
      break;
    case NODE_WHILE: // the body may run zero or many times -> conditional
      cg_scan_moves(c, n->as.while_stmt.condition, cond, pass);
      cg_scan_moves(c, n->as.while_stmt.body, true, pass);
      break;
    case NODE_FOR:
      cg_scan_moves(c, n->as.for_stmt.iterable, cond, pass);
      cg_scan_moves(c, n->as.for_stmt.body, true, pass);
      break;
    case NODE_MATCH: { // each arm body is one of several alternative paths
      cg_mark_move(c, n->as.match_expr.value, cond, pass, true); // destructuring an owned Free value consumes it
      cg_scan_moves(c, n->as.match_expr.value, cond, pass);
      const NodeList arms = n->as.match_expr.arms;
      const NodeId *const ids = ast_list(c->ast, arms);
      for (uint32_t i = 0; i < arms.len; i++)
        cg_scan_moves(c, ast_at_const(c->ast, ids[i])->as.match_arm.body, true, pass);
      break;
    }
    case NODE_EXPRESSION_STATEMENT:
    case NODE_DEFER:
      cg_scan_moves(c, n->as.single.value, cond, pass);
      break;
    case NODE_CALL: {
      cg_scan_moves(c, n->as.call.callee, cond, pass);
      const Node *const callee = ast_at_const(c->ast, n->as.call.callee);
      if (callee->kind == NODE_MEMBER && !callee->as.member.path && // `x.free()` consumes the owned receiver
          span_is(cg_mod_src(c, c->ast->module), ast_at_const(c->ast, callee->as.member.member)->as.name.text, "free")) {
        const TypeKind rk = ast_type_at(c->ast, ast_type(c->ast, callee->as.member.object))->kind;
        if (rk != TYPE_POINTER && rk != TYPE_REFERENCE)
          cg_mark_move(c, callee->as.member.object, cond, pass, false); // flag set around the call, not the receiver
      } else if (callee->kind == NODE_MEMBER && !callee->as.member.path) {
        // A method whose `self` is taken BY VALUE (`fn unwrap_or(self: Option<T>, ..)`) consumes its
        // receiver -- the receiver moves into the call, so it must not also be auto-freed at scope exit.
        const DefId md = ast_resolution_def(c->ast, callee->as.member.member);
        if (md.node != NODE_NONE) {
          Ast *const ma = cg_mod_ast(c, md.module);
          const Node *const mn = ast_at_const(ma, md.node);
          if (mn->kind == NODE_FUNCTION && mn->as.function.params.len > 0) {
            const NodeId p0 = ast_list(ma, mn->as.function.params)[0];
            const NodeId pt = ast_at_const(ma, p0)->as.parameter.type;
            const NodeKind ptk = pt != NODE_NONE ? ast_at_const(ma, pt)->kind : NODE_NONE_KIND;
            if (ptk != NODE_POINTER_TYPE && ptk != NODE_REFERENCE_TYPE)
              cg_mark_move(c, callee->as.member.object, cond, pass, true); // by-value self -> receiver moves
          }
        }
      }
      const NodeList args = n->as.call.args;
      const NodeId *const ids = ast_list(c->ast, args);
      for (uint32_t i = 0; i < args.len; i++) {
        cg_mark_move(c, ids[i], cond, pass, true); // a by-value argument moves the binding to the callee
        cg_scan_moves(c, ids[i], cond, pass);
      }
      break;
    }
    case NODE_BINARY: // `&&`/`||` short-circuit: the right operand is a conditional path
      cg_scan_moves(c, n->as.binary.left, cond, pass);
      cg_scan_moves(c, n->as.binary.right,
                    cond || n->as.binary.op == AmpersandAmpersand || n->as.binary.op == PipePipe, pass);
      break;
    case NODE_UNARY:
      cg_scan_moves(c, n->as.unary.operand, cond, pass);
      break;
    case NODE_MEMBER:
      cg_scan_moves(c, n->as.member.object, cond, pass);
      break;
    case NODE_INDEX:
      cg_scan_moves(c, n->as.index.object, cond, pass);
      cg_scan_moves(c, n->as.index.index, cond, pass);
      break;
    case NODE_CAST:
      cg_scan_moves(c, n->as.cast.expression, cond, pass);
      break;
    default:
      break;
  }
}

// Whether the binding at `id` (a `let` or a by-value parameter) holds a Free-implementing, not-moved value
// -- i.e. it gets a scope-exit RAII free. Such a let is emitted non-`const` (its Free call takes `&mut self`).
static bool cg_will_auto_free(Codegen *c, const NodeId id) {
  const Node *const n = ast_at_const(c->ast, id);
  if (n->kind == NODE_LET && ast_at_const(c->ast, n->as.let_stmt.name)->kind == NODE_PATTERN_TUPLE)
    return false;
  if (cg_is_moved(c, id))
    return false;
  return cg_type_is_free(c, ast_type(c->ast, id));
}

// Register an automatic free on the scope-exit cleanup stack (RAII), in the same reverse-order sequence
// as `defer`. Caller has already confirmed cg_will_auto_free.
static void cg_register_auto_free(Codegen *c, const NodeId id) {
  if (c->defer_top >= (uint32_t)(sizeof c->defer_stack / sizeof c->defer_stack[0]))
    return;
  c->defer_stack[c->defer_top] = id; // the let node; emit_defers_to reads its binding name + type
  c->defer_kind[c->defer_top] = 1;
  c->defer_top++;
}

// Emit the RAII Free call for the binding (`let` or by-value param) at `bid`: `Type__free(&name)`.
// Emit the C symbol of `bt`'s Free method (without the `(&recv)` args), or return false if `bt` is not a
// Free type. Works in macro mode (`Inst ## __free`) and normal mode (paste is a no-op there).
static bool emit_free_target(Codegen *c, const TypeId bt) {
  const Ty *const y = ast_type_at(c->ast, subst_resolve(c, bt));
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
    return false;
  }
  const DefId dm = cg_free_method(c, om, od);
  if (dm.node == NODE_NONE)
    return false;
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
  return true;
}

static void emit_auto_free(Codegen *c, const NodeId bid) {
  const TypeId bt = ast_type(c->ast, bid);
  if (!cg_type_is_free(c, bt))
    return;
  if (cg_is_cond_moved(c, bid)) { // conditionally moved: free only on the path that did NOT move it out
    char fl[32];
    cg_move_flag(fl, sizeof fl, bid);
    emit(c, "if (!%s) ", fl);
  }
  emit_free_target(c, bt);
  const Node *const ln = ast_at_const(c->ast, bid);
  char nm[128];
  const NodeId nameNode = ln->kind == NODE_PARAMETER     ? ln->as.parameter.name
                          : ln->kind == NODE_IDENTIFIER  ? bid // a tuple-let element binds under its own name
                                                         : ln->as.let_stmt.name;
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
        // RAII for the destructured elements: each owning element that is not moved out is freed at scope
        // exit (a conditionally-moved one gets a runtime flag, like a regular Free `let`).
        const Node *const pat = ast_at_const(c->ast, n->as.let_stmt.name);
        const NodeId *const eids = ast_list(c->ast, pat->as.pattern.children);
        for (uint32_t i = 0; i < pat->as.pattern.children.len; i++) {
          if (!cg_type_is_free(c, ast_type(c->ast, eids[i])) || cg_is_moved(c, eids[i]))
            continue;
          if (cg_is_cond_moved(c, eids[i])) {
            char fl[32];
            cg_move_flag(fl, sizeof fl, eids[i]);
            emit_indent(c);
            emit(c, "bool %s = false;\n", fl);
          }
          cg_register_auto_free(c, eids[i]);
        }
        break;
      }
      // const iff the binding is immutable (`let` without `mut`). Calling a `&mut self` method on an
      // immutable binding is rejected by the typechecker (receiver_mutable), so const never blocks a valid one.
      // A Free-managed binding is emitted non-const, since its scope-exit Free call takes `&mut self`.
      const bool autofree = cg_will_auto_free(c, id);
      const bool is_const = !n->as.let_stmt.is_mutable && !autofree;
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
      if (autofree && cg_is_cond_moved(c, id)) { // a fresh free flag per execution (resets each loop pass)
        char fl[32];
        cg_move_flag(fl, sizeof fl, id);
        emit_indent(c);
        emit(c, "bool %s = false;\n", fl);
      }
      if (autofree)
        cg_register_auto_free(c, id); // RAII: schedule a scope-exit free
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
        const bool sc = c->const_ctx;
        c->const_ctx = true; // a `static const` initializer must be a constant expression
        emit_initializer(c, n->as.const_def.type, n->as.const_def.value);
        c->const_ctx = sc;
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
    // `mut p` -> non-const; a by-value Free param is also non-const (it is owned and `free` mutates it).
    const bool pconst = !p->as.parameter.is_mutable && !cg_type_is_free(c, ast_type(c->ast, ids[i]));
    render_binding_node(c, p->as.parameter.type, nm, pconst, d, sizeof d);
    if (any)
      k = buf_append(out, cap, k, ", ");
    k = buf_append(out, cap, k, d);
    any = true;
  }
  if (!any)
    buf_join3(out, cap, "void", "", "");
}

// Build a function's C name: `<mod>__name`, or `<mod>__Target__name` for an extend method. `prefixed`
// is false for extern (FFI) functions; the program entry `main` is never prefixed either.
// `target` is the receiver type (a DefId; .node == NODE_NONE for a free function). The module prefix is
// always this (the emitting) module, so a local `extend foreign::T` method is mangled by the module that
// declares it (`extender__T__m`); the type-name segment is read from the target type's own module.
// The number of `from` (or `try_from`) methods across all extends targeting (tmod,tdecl). A type with more
// than one `From`/`TryFrom` extend needs each symbol disambiguated by its source type (Celsius__from__u8).
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
      if (it->kind != NODE_EXTEND || it->as.extend_def.target_type == NODE_NONE)
        continue;
      const DefId tg = ast_resolution_def(a, it->as.extend_def.target_type);
      if (tg.module != tmod || tg.node != tdecl)
        continue;
      const NodeList ms = it->as.extend_def.items;
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

// If `lit` ("from"/"try_from") names an overloaded conversion of `target` (several such extends), append
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
    const int bb = c->package ? package_builtin_of_decl(c->package, target.module, target.node) : -1;
    if (bb >= 0) { // `extend i32 { .. }`: the target is a builtin, mangled by its own name (i32__<method>)
      k = buf_append(out, cap, k, BUILTIN_NAMES[bb]);
    } else {
      const Span ts = name_span_in(c, target.module, ast_at_const(cg_mod_ast(c, target.module), target.node)->as.aggregate.name);
      k += render_ident_src(cg_mod_src(c, target.module), ts, out + k, cap - k);
    }
    if (k + 2 < cap) {
      out[k++] = '_';
      out[k++] = '_';
    }
  }
  k += render_ident(c, fname, out + k, cap - k);
  // Overloaded `from`/`try_from`: disambiguate by the value-param's type so the extends get distinct symbols.
  const NodeList params = ast_at_const(c->ast, fn)->as.function.params;
  const char *const lit = cg_conv_lit(c, c->ast->module, fname);
  if (lit && target.node != NODE_NONE && params.len) {
    const NodeId p0 = ast_list(c->ast, params)[0];
    cg_conv_suffix(c, target, lit, ast_type(c->ast, ast_at_const(c->ast, p0)->as.parameter.type), out + k, cap - k);
  }
}

// Emit a function signature; with_body emits the block, otherwise a prototype `;`. `extern_q`
// prefixes `extern`. Sets current_ret for multi-return so NODE_RETURN can build the struct.
// Does the subtree rooted at `id` reference parameter `param` (a NODE_PARAMETER of the current module)?
// Drives the `(void)param;` cast for genuinely-unused parameters. Over-reporting "unused" is harmless (a
// redundant cast before a real use still compiles), so any unhandled node kind just stops that branch.
static bool cg_subtree_uses(Codegen *c, const NodeId id, const NodeId param) {
  if (id == NODE_NONE)
    return false;
  const Node *const n = ast_at_const(c->ast, id);
  switch (n->kind) {
    case NODE_IDENTIFIER: {
      const DefId d = ast_resolution_def(c->ast, id);
      return d.module == c->ast->module && d.node == param;
    }
    case NODE_BLOCK: {
      const NodeId *const ids = ast_list(c->ast, n->as.block.statements);
      for (uint32_t i = 0; i < n->as.block.statements.len; i++)
        if (cg_subtree_uses(c, ids[i], param))
          return true;
      return false;
    }
    case NODE_LET:
      return cg_subtree_uses(c, n->as.let_stmt.value, param);
    case NODE_RETURN: {
      const NodeId *const ids = ast_list(c->ast, n->as.return_stmt.values);
      for (uint32_t i = 0; i < n->as.return_stmt.values.len; i++)
        if (cg_subtree_uses(c, ids[i], param))
          return true;
      return false;
    }
    case NODE_DEFER:
    case NODE_EXPRESSION_STATEMENT:
      return cg_subtree_uses(c, n->as.single.value, param);
    case NODE_IF:
      return cg_subtree_uses(c, n->as.if_stmt.condition, param) || cg_subtree_uses(c, n->as.if_stmt.then_branch, param) ||
             cg_subtree_uses(c, n->as.if_stmt.else_branch, param);
    case NODE_WHILE:
      return cg_subtree_uses(c, n->as.while_stmt.condition, param) || cg_subtree_uses(c, n->as.while_stmt.body, param);
    case NODE_FOR:
      return cg_subtree_uses(c, n->as.for_stmt.iterable, param) || cg_subtree_uses(c, n->as.for_stmt.body, param);
    case NODE_MATCH: {
      if (cg_subtree_uses(c, n->as.match_expr.value, param))
        return true;
      const NodeId *const ids = ast_list(c->ast, n->as.match_expr.arms);
      for (uint32_t i = 0; i < n->as.match_expr.arms.len; i++) {
        const Node *const arm = ast_at_const(c->ast, ids[i]);
        if (cg_subtree_uses(c, arm->as.match_arm.guard, param) || cg_subtree_uses(c, arm->as.match_arm.body, param))
          return true;
      }
      return false;
    }
    case NODE_ASSIGNMENT:
    case NODE_BINARY:
      return cg_subtree_uses(c, n->as.binary.left, param) || cg_subtree_uses(c, n->as.binary.right, param);
    case NODE_UNARY:
      return cg_subtree_uses(c, n->as.unary.operand, param);
    case NODE_CALL: {
      if (cg_subtree_uses(c, n->as.call.callee, param))
        return true;
      const NodeId *const ids = ast_list(c->ast, n->as.call.args);
      for (uint32_t i = 0; i < n->as.call.args.len; i++)
        if (cg_subtree_uses(c, ids[i], param))
          return true;
      return false;
    }
    case NODE_INDEX:
      return cg_subtree_uses(c, n->as.index.object, param) || cg_subtree_uses(c, n->as.index.index, param);
    case NODE_MEMBER:
      return cg_subtree_uses(c, n->as.member.object, param);
    case NODE_CAST:
      return cg_subtree_uses(c, n->as.cast.expression, param);
    case NODE_GENERIC_SPECIALIZATION:
      return cg_subtree_uses(c, n->as.specialization.expression, param);
    case NODE_NEW:
      return cg_subtree_uses(c, n->as.new_expr.initializer, param);
    case NODE_VA_EXPR:
      return cg_subtree_uses(c, n->as.va_op.ap, param) || cg_subtree_uses(c, n->as.va_op.extra, param);
    case NODE_ARRAY_LITERAL: {
      const NodeId *const ids = ast_list(c->ast, n->as.array_literal.elements);
      for (uint32_t i = 0; i < n->as.array_literal.elements.len; i++)
        if (cg_subtree_uses(c, ids[i], param))
          return true;
      return false;
    }
    case NODE_STRUCT_INITIALIZER: {
      const NodeId *const ids = ast_list(c->ast, n->as.struct_initializer.fields);
      for (uint32_t i = 0; i < n->as.struct_initializer.fields.len; i++)
        if (cg_subtree_uses(c, ast_at_const(c->ast, ids[i])->as.field_initializer.value, param))
          return true;
      return false;
    }
    case NODE_CLOSURE:
      return cg_subtree_uses(c, n->as.closure.body, param);
    case NODE_RANGE:
      return cg_subtree_uses(c, n->as.pattern_range.start, param) || cg_subtree_uses(c, n->as.pattern_range.end, param);
    default:
      return false;
  }
}

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
    if (is_static && !cg_attr(c, fmod, fn_id, ATTR_USED))
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
  c->current_fn_ret_node = NODE_NONE;
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
    c->current_fn_ret_node = rn->kind == NODE_PARAMETER ? rn->as.parameter.type : r0; // for `?`
    char out[1400];
    render_type_node(c, c->current_fn_ret_node, decl, out, sizeof out);
    emit_cstr(c, out);
  } else {
    emit(c, "void ");
    emit_cstr(c, decl);
  }

  if (with_body && fn->as.function.body != NODE_NONE) {
    emit(c, " ");
    c->defer_top = 0; // each function body is a fresh defer scope
    c->loop_defer_base = 0;
    c->nmoved = c->ncond_moved = c->ncond_sites = 0; // RAII move analysis, fresh per function body
    cg_scan_moves(c, fn->as.function.body, false, 0);  // pass 0: bindings moved on every path (free elided)
    cg_scan_moves(c, fn->as.function.body, false, 1);  // pass 1: conditional move sites (free flag-guarded)
    // A by-value Free parameter is owned by this function -> free it at scope exit (unless moved). Pushed
    // first so params are torn down LAST (after locals), preserving reverse-construction order.
    const NodeList ps = fn->as.function.params;
    const NodeId *const pids = ast_list(c->ast, ps);
    c->nparam_flags = 0;
    c->nunused_params = 0;
    for (uint32_t i = 0; i < ps.len; i++) {
      if (cg_will_auto_free(c, pids[i])) {
        cg_register_auto_free(c, pids[i]);
        if (cg_is_cond_moved(c, pids[i]) && c->nparam_flags < (uint32_t)(sizeof c->param_flags / sizeof c->param_flags[0]))
          c->param_flags[c->nparam_flags++] = pids[i]; // declared at body top by emit_block_from
      } else if (!cg_subtree_uses(c, fn->as.function.body, pids[i]) &&
                 c->nunused_params < (uint32_t)(sizeof c->unused_params / sizeof c->unused_params[0])) {
        // A parameter the body never reads (e.g. an allocator's ignored `self`/`align`, or a builtin's
        // no-op `free(self: &mut Self) {}`) is cast to void at the body top by emit_block_from -- keeps
        // generated C `-Werror,-Wunused-parameter` clean. (An owned Free param IS used -- freed at close.)
        c->unused_params[c->nunused_params++] = pids[i];
      }
    }
    emit_block_from(c, fn->as.function.body, 0); // base 0: the body's close also frees owned parameters
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
  emit(c, "static __attribute__((unused)) ");
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
    if (!with_body) // the spec's `<name>_ret` typedef (multi-return / array-by-value), under the same subst
      emit_ret_struct_named(c, fn.node, nm);
    emit_function(c, fn.node, (DefId){0, NODE_NONE}, false, with_body, nm, true);
    c->nsubst = 0;
  }
}

// Codegen mirror of the typechecker's type_satisfies, for gating conditional-conformance emission: does the
// concrete type `ty` have an `extend ty as iface` extend -- directly, or a conditional `extend<G> Ty<G> as iface`
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
  } else if (y->kind == TYPE_BUILTIN && c->package) {
    const NodeId bd = package_builtin_decl(c->package, y->as.builtin); // builtins conform via `extend i32 as iface`
    if (bd == NODE_NONE)
      return false;
    tmod = c->package->core_module;
    tdecl = bd;
  } else {
    return false; // a pointer / etc.: no `as iface` extend
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
      if (it->kind != NODE_EXTEND || it->as.extend_def.interface_type == NODE_NONE || it->as.extend_def.target_type == NODE_NONE)
        continue;
      const DefId tr = ast_resolution_def(a, it->as.extend_def.interface_type);
      const DefId tg = ast_resolution_def(a, it->as.extend_def.target_type);
      if (tr.module != iface.module || tr.node != iface.node || tg.module != tmod || tg.node != tdecl)
        continue;
      const NodeList gens = it->as.extend_def.generics; // conditional extension: each param bound must hold for the arg
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

// An extend's interface as a DefId, or {_,NODE_NONE} for an inherent (non-conformance) extend. A conditional
// conformance (`extend<T: Clone> Vector<T> as Clone`) is emitted for an instance ONLY when the instance
// satisfies it (cg_type_satisfies), so e.g. `Vector<i32>` -- whose i32 is not Clone -- gets no clone method.
static DefId extend_interface(Ast *const a, const Node *const extend) {
  if (extend->as.extend_def.interface_type == NODE_NONE)
    return (DefId){0, NODE_NONE};
  return ast_resolution_def(a, extend->as.extend_def.interface_type);
}

// True if every interface bound on extend `extend`'s generic params is satisfied by the instance's args, so the
// block's methods may be specialized for it. A method on `extend<A: Allocator + Default> Box<T, A>` must NOT
// be emitted for an instance whose A lacks `Default` -- its body would call `A::default()`, an undefined
// symbol. (Conformance extends are additionally gated by extend_interface/cg_type_satisfies above.)
static bool cg_extend_bounds_hold(Codegen *c, const Node *const extend, const TypeId *const args, const uint8_t n) {
  const NodeList gens = extend->as.extend_def.generics;
  const NodeId *const gids = ast_list(c->ast, gens);
  for (uint32_t g = 0; g < gens.len && g < n; g++) {
    const NodeList gb = ast_at_const(c->ast, gids[g])->as.generic_param.bounds;
    const NodeId *const gbids = ast_list(c->ast, gb);
    for (uint32_t b = 0; b < gb.len; b++) {
      const DefId gbi = ast_resolution_def(c->ast, gbids[b]);
      if (gbi.node != NODE_NONE && !cg_type_satisfies(c, args[g], gbi, 0))
        return false;
    }
  }
  return true;
}

static bool seed_type_instances_from_type(Codegen *c, TypeId ty) {
  if (ty == TYPE_NONE)
    return false;
  ty = subst_resolve(c, ty);
  const Ty *const y = ast_type_at(c->ast, ty);
  bool changed = false;
  switch (y->kind) {
    case TYPE_INSTANCE: {
      const TyInstance it = *ast_instance(c->ast, y->as.inst);
      bool concrete = true;
      for (uint8_t i = 0; i < it.n; i++)
        concrete &= type_is_concrete(c, it.args[i]);
      if (!concrete)
        break;
      const size_t before = c->ast->instances.len;
      ast_intern_instance(c->ast, it.module, it.decl, it.args, it.n);
      changed |= c->ast->instances.len != before;
      for (uint8_t i = 0; i < it.n; i++)
        changed |= seed_type_instances_from_type(c, it.args[i]);
      break;
    }
    case TYPE_POINTER:
    case TYPE_REFERENCE:
    case TYPE_ARRAY:
      changed |= seed_type_instances_from_type(c, y->as.elem);
      break;
    default:
      break;
  }
  return changed;
}

static bool seed_type_instances_from_type_node(Codegen *c, const NodeId type_node) {
  if (type_node == NODE_NONE)
    return false;
  const TypeId ty = ast_type(c->ast, type_node);
  return ty != TYPE_NONE && seed_type_instances_from_type(c, ty);
}

static bool seed_type_instances_from_fn_signature(Codegen *c, const NodeId fn_id) {
  const Node *const fn = ast_at_const(c->ast, fn_id);
  bool changed = false;
  const NodeList ps = fn->as.function.params;
  const NodeId *const pids = ast_list(c->ast, ps);
  for (uint32_t i = 0; i < ps.len; i++)
    changed |= seed_type_instances_from_type_node(c, ast_at_const(c->ast, pids[i])->as.parameter.type);
  const NodeList rs = fn->as.function.returns;
  const NodeId *const rids = ast_list(c->ast, rs);
  for (uint32_t i = 0; i < rs.len; i++) {
    const Node *const rn = ast_at_const(c->ast, rids[i]);
    changed |= seed_type_instances_from_type_node(c, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : rids[i]);
  }
  return changed;
}

static bool seed_emitted_generic_method_signature_instances(Codegen *c) {
  bool changed = false;
  for (size_t ii = 0; ii < c->ast->instances.len; ii++) {
    const TyInstance it = c->ast->instances.data[ii];
    if (it.module != c->ast->module)
      continue;
    bool concrete = true;
    for (uint8_t k = 0; k < it.n; k++)
      concrete &= type_is_concrete(c, it.args[k]);
    if (!concrete)
      continue;
    const NodeList items = program_items(c);
    const NodeId *const iids = ast_list(c->ast, items);
    for (uint32_t i = 0; i < items.len; i++) {
      const Node *const n = ast_at_const(c->ast, iids[i]);
      if (n->kind != NODE_EXTEND || !n->as.extend_def.generics.len)
        continue;
      if (ast_resolution(c->ast, n->as.extend_def.target_type) != it.decl)
        continue;
      const DefId itrait = extend_interface(c->ast, n);
      if (itrait.node != NODE_NONE &&
          !cg_type_satisfies(c, ast_intern_instance(c->ast, it.module, it.decl, it.args, it.n), itrait, 0))
        continue;
      if (!cg_extend_bounds_hold(c, n, it.args, it.n))
        continue;
      const NodeList gens = n->as.extend_def.generics;
      const NodeId *const gids = ast_list(c->ast, gens);
      const int saved = c->nsubst;
      c->nsubst = 0;
      for (uint32_t g = 0; g < gens.len && g < it.n && c->nsubst < 8; g++) {
        c->subst[c->nsubst].param = (DefId){c->ast->module, gids[g]};
        c->subst[c->nsubst].concrete = it.args[g];
        c->nsubst++;
      }
      const NodeList ms = n->as.extend_def.items;
      const NodeId *const mids = ast_list(c->ast, ms);
      for (uint32_t j = 0; j < ms.len; j++) {
        const Node *const mn = ast_at_const(c->ast, mids[j]);
        if (mn->kind != NODE_FUNCTION || mn->as.function.generics.len)
          continue;
        changed |= seed_type_instances_from_fn_signature(c, mids[j]);
      }
      c->nsubst = saved;
    }
  }
  return changed;
}

static void seed_emitted_type_instances(Codegen *c) {
  for (int pass = 0; pass < 32; pass++) {
    if (!seed_emitted_generic_method_signature_instances(c))
      return;
  }
}

// Emit specialized methods for every concrete generic instance OWNED by this module (moved here by
// package_propagate_instances): for each extend targeting the instance's generic decl, emit each method as
// `<Inst>__<method>` with the extend's type params bound to the instance args. Unlike free-function specs
// (per-module-static), methods are emitted once by the owner, so a `pub` method becomes a real
// cross-module symbol (prototype in the header). `which`/`with_body` mirror phase_prototypes/phase_bodies.
// Emit one concrete instance's methods (ordinary + generic map<U>). `it`'s args live in the CURRENT
// c->ast pool, and extends are scanned from c->ast (the generic's owner -- equal to c->ast for a same-module
// instance, the temporarily swapped-in owner for a re-homed one). Generic-method instantiations are read
// from `mi_src->method_insts` keyed by `mi_inst` (the receiver instance's TypeId in mi_src's pool), so a
// re-homed instance still finds the uses recorded in its home module while its template reads from owner.
static void emit_inst_methods(Codegen *c, const TyInstance *const it, Ast *const mi_src, const TypeId mi_inst,
                              const int which, const bool with_body) {
  const NodeList items = program_items(c);
  const NodeId *const iids = ast_list(c->ast, items);
  char inm[200];
  inst_name(c, it, inm, sizeof inm);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, iids[i]);
    if (n->kind != NODE_EXTEND || !n->as.extend_def.generics.len)
      continue;
    if (ast_resolution(c->ast, n->as.extend_def.target_type) != it->decl)
      continue;
    const DefId itrait = extend_interface(c->ast, n); // a conditional conformance emits only for satisfying instances
    if (itrait.node != NODE_NONE &&
        !cg_type_satisfies(c, ast_intern_instance(c->ast, it->module, it->decl, it->args, it->n), itrait, 0))
      continue;
    if (!cg_extend_bounds_hold(c, n, it->args, it->n)) // a block whose param bounds the args don't meet (e.g.
      continue;                                      // `A: Default` for a non-Default allocator) emits nothing
    const NodeList gens = n->as.extend_def.generics;
    const NodeId *const gids = ast_list(c->ast, gens);
    const NodeList ms = n->as.extend_def.items;
    const NodeId *const mids = ast_list(c->ast, ms);
    for (uint32_t j = 0; j < ms.len; j++) {
      const Node *const mn = ast_at_const(c->ast, mids[j]);
      if (mn->kind != NODE_FUNCTION)
        continue;
      if (with_body ? mn->as.function.body == NODE_NONE : !want_fn(which, mn->as.function.is_public))
        continue;
      // Bind the extend's generics (e.g. T) from the instance's args -- shared by every spec below.
      c->nsubst = 0;
      for (uint32_t g = 0; g < gens.len && g < it->n && c->nsubst < 8; g++) {
        c->subst[c->nsubst].param = (DefId){c->ast->module, gids[g]};
        c->subst[c->nsubst].concrete = it->args[g];
        c->nsubst++;
      }
      char nm[320];
      size_t at = buf_append(nm, sizeof nm, 0, inm);
      at = buf_append(nm, sizeof nm, at, "__");
      render_ident(c, name_span(c, mn->as.function.name), nm + at, sizeof nm - at);
      const bool stat = c->multifile && !mn->as.function.is_public;
      if (mn->as.function.generics.len == 0) { // ordinary method: one spec per instance
        // Demand-driven emission: an INHERENT method (itrait unset) of a non-`@emit_macro` type that the
        // type-checker never resolved is dead -- skip it (no call site can reference it, so this is sound).
        // Conformance methods (reached via operators / RAII / a generic bound) and `@emit_macro` types
        // (full C-reuse export) always emit. Single-file builds (no package) emit everything.
        if (c->multifile && itrait.node == NODE_NONE && !cg_attr(c, c->ast->module, it->decl, ATTR_EMIT_MACRO) &&
            !package_method_used(c->package, (DefId){c->ast->module, mids[j]})) {
          c->nsubst = 0;
          continue;
        }
        if (!with_body) // the method spec's `<name>_ret` typedef, under the extend's subst
          emit_ret_struct_named(c, mids[j], nm);
        emit_function(c, mids[j], (DefId){0, NODE_NONE}, false, with_body, nm, stat);
        c->nsubst = 0;
        continue;
      }
      // Generic method (map<U>): one spec per recorded (instance, method, targs) tuple, layering the
      // method's own generics atop the extend subst and suffixing the name with the mangled type args.
      const int nimpl = c->nsubst;
      const NodeList mg = mn->as.function.generics;
      const NodeId *const mgids = ast_list(c->ast, mg);
      for (size_t mk = 0; mk < mi_src->method_insts.len; mk++) {
        const MethodInst inst = mi_src->method_insts.data[mk]; // copy: emit may grow pools
        if (inst.method != mids[j] || inst.instance != mi_inst)
          continue;
        c->nsubst = nimpl;
        for (uint32_t g = 0; g < mg.len && g < inst.n && c->nsubst < 8; g++) {
          c->subst[c->nsubst].param = (DefId){c->ast->module, mgids[g]};
          c->subst[c->nsubst].concrete = mi_src == c->ast ? inst.targs[g] : ast_reintern(c->ast, mi_src, inst.targs[g]);
          c->nsubst++;
        }
        char snm[400];
        size_t a2 = buf_append(snm, sizeof snm, 0, nm);
        for (uint8_t g = 0; g < inst.n; g++) {
          a2 = buf_append(snm, sizeof snm, a2, "__");
          char e[176];
          mangle_type(c, mi_src == c->ast ? inst.targs[g] : ast_reintern(c->ast, mi_src, inst.targs[g]), e, sizeof e);
          a2 = buf_append(snm, sizeof snm, a2, e);
        }
        if (!with_body)
          emit_ret_struct_named(c, mids[j], snm);
        emit_function(c, mids[j], (DefId){0, NODE_NONE}, false, with_body, snm, stat);
      }
      c->nsubst = 0;
    }
  }
}

static void emit_method_specializations(Codegen *c, const int which, const bool with_body) {
  for (size_t ii = 0; ii < c->ast->instances.len; ii++) {
    const TyInstance it = c->ast->instances.data[ii]; // copy: emit_function below may grow the pool
    if (it.module != c->ast->module)
      continue;
    bool concrete = true;
    for (uint8_t k = 0; k < it.n; k++)
      concrete &= type_is_concrete(c, it.args[k]);
    if (!concrete)
      continue;
    const TypeId itTy = ast_intern_instance(c->ast, it.module, it.decl, it.args, it.n);
    emit_inst_methods(c, &it, c->ast, itTy, which, with_body);
    c->nsubst = 0;
  }
}

// Emit interface DEFAULT method bodies inherited by `extend T as Iface` extends in this module that do not
// override them: synthesize `T__<name>` with the interface's abstract `Self` substituted to T, so a call
// resolved to the default (`x.lt(y)`) links. Same-module interfaces only (emit_function reads the current
// Ast); generic extends and generic defaults are skipped. `which`/`with_body` mirror the
// prototype vs body split of phase_prototypes / phase_bodies.
static void emit_default_methods(Codegen *c, const int which, const bool with_body) {
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (n->kind != NODE_EXTEND || n->as.extend_def.interface_type == NODE_NONE || n->as.extend_def.target_type == NODE_NONE ||
        n->as.extend_def.generics.len)
      continue;
    const DefId iface = ast_resolution_def(c->ast, n->as.extend_def.interface_type);
    const DefId target = ast_resolution_def(c->ast, n->as.extend_def.target_type);
    if (iface.node == NODE_NONE || iface.module != c->ast->module || target.node == NODE_NONE)
      continue; // only same-module interface defaults are emittable here
    const Node *const tn = ast_at_const(c->ast, target.node);
    const TypeId tty = ast_intern_type(
        c->ast, (Ty){.kind = tn->kind == NODE_ENUM ? TYPE_ENUM : TYPE_STRUCT, .module = target.module, .as.decl = target.node});
    const NodeList req = ast_at_const(c->ast, iface.node)->as.interface_def.items;
    const NodeId *const rids = ast_list(c->ast, req);
    const NodeList have = n->as.extend_def.items;
    const NodeId *const hids = ast_list(c->ast, have);
    for (uint32_t r = 0; r < req.len; r++) {
      const Node *const rm = ast_at_const(c->ast, rids[r]);
      if (rm->kind != NODE_FUNCTION || rm->as.function.body == NODE_NONE) // only DEFAULT (bodied) methods
        continue;
      if (rm->as.function.generics.len)
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
      c->subst[0].param = iface; // the interface's `Self` is a TYPE_GENERIC keyed by (iface.module, interface node)
      c->subst[0].concrete = tty;
      if (!with_body) // the default's `<T__name>_ret` typedef (multi-return), under the Self subst
        emit_ret_struct(c, rids[r], target);
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

// Core with an explicit struct-name stem: specializations pass their mangled spec name so the typedef
// matches the `<override>_ret` return type emit_function produces; runs under the caller's c->subst.
static void emit_ret_struct_named(Codegen *c, const NodeId fn_id, const char *const nm) {
  const Node *const fn = ast_at_const(c->ast, fn_id);
  const NodeList rets = fn->as.function.returns;
  const NodeId arr = fn_array_return(c, fn_id);
  if (arr != NODE_NONE) { // single array-by-value return -> `struct { T _[N]; } <fn>_ret;`
    char d[256];
    render_type_node(c, arr, "_", d, sizeof d); // the array member, e.g. `int32_t _[3]`
    emit(c, "typedef struct { %s; } %s_ret;\n", d, nm);
    return;
  }
  if (rets.len <= 1)
    return;
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

static void emit_ret_struct(Codegen *c, const NodeId fn_id, const DefId target) {
  const Node *const fn = ast_at_const(c->ast, fn_id);
  if (fn->as.function.returns.len <= 1 && fn_array_return(c, fn_id) == NODE_NONE)
    return;
  char nm[256];
  function_name(c, fn_id, target, nm, sizeof nm, true);
  emit_ret_struct_named(c, fn_id, nm);
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
      const bool sc = c->const_ctx;
      c->const_ctx = true; // a C enum discriminant must be a constant expression
      emit_expr(c, disc);
      c->const_ctx = sc;
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
      const bool sc = c->const_ctx;
      c->const_ctx = true; // a C enum discriminant must be a constant expression
      emit_expr(c, disc);
      c->const_ctx = sc;
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

static const char *agg_kw(const Node *const n);

// Emit a generic struct instantiation's C definition (forward typedef when !with_body), with the type
// params bound to the instance's concrete args. Same-module only (the generic struct is in this ast).
static void emit_struct_inst(Codegen *c, const TyInstance *const it, const bool with_body) {
  const Node *const dn = ast_at_const(c->ast, it->decl);
  char nm[200];
  inst_name(c, it, nm, sizeof nm);
  if (!with_body) {
    emit(c, "typedef %s %s %s;\n", agg_kw(dn), nm, nm); // `union` for an instance of an untagged union (SSO String)
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
  emit(c, "%s %s {\n", agg_kw(dn), nm);
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
  // A public generic enum whose only instances are re-homed into other modules has no same-module instance
  // above, yet those re-homed bodies (full-monomorphized in user modules that include this header) name the
  // shared tag. Emit it here in the owner's header for every public generic enum, deduped against the set.
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const NodeId did = ids[i];
    const Node *const dn = ast_at_const(c->ast, did);
    if (dn->kind != NODE_ENUM || !dn->as.aggregate.generics.len || !dn->as.aggregate.is_public)
      continue;
    bool dup = false;
    for (int s = 0; s < ns; s++)
      dup |= seen[s] == did;
    if (dup)
      continue;
    if (ns < 64)
      seen[ns++] = did;
    if (aggregate_has_payload(c, dn))
      emit_enum_tag_decl(c, did, dn);
    else
      emit_enum_full(c, dn, did);
  }
}

// Emit every same-module generic-aggregate instantiation (forward typedefs, then full bodies).
static void emit_type_dfs(Codegen *c, const NodeId declId, uint8_t *const state);
static bool type_emittable(Codegen *c, const Node *const n);
static void emit_inst_dfs(Codegen *c, const uint32_t idx, uint8_t *const state, const size_t nstate, const bool with_body);
static void emit_rehomed_struct_dfs(Codegen *c, const uint32_t idx, uint8_t *const state, const size_t nstate,
                                    const bool with_body);

// Record an already-resolved (home-pool) type `st` as a by-value layout dependency: unwrap arrays (which embed
// their element by value), keep only aggregates -- struct/enum/instance, since pointers/references/builtins
// need only a forward typedef -- and dedup. `deps` caps at 32 distinct entries (no real aggregate approaches it).
static void push_home_dep(Codegen *c, TypeId st, TypeId *const deps, int *const nh) {
  if (*nh >= 32 || st == TYPE_NONE)
    return;
  const Ty *y = ast_type_at(c->ast, st);
  while (y->kind == TYPE_ARRAY) {
    st = y->as.elem;
    y = ast_type_at(c->ast, st);
  }
  if (y->kind != TYPE_STRUCT && y->kind != TYPE_ENUM && y->kind != TYPE_INSTANCE)
    return;
  for (int i = 0; i < *nh; i++)
    if (deps[i] == st)
      return;
  deps[(*nh)++] = st;
}

// Emit the full body of whatever type-unit a home-pool type `st` denotes BEFORE the unit that embeds it by
// value, so the C struct laying it out sees a complete type. `st` may be a same-module user struct/enum
// (emit_type_dfs), or a generic instance -- same-module (emit_inst_dfs) or re-homed here
// (emit_rehomed_struct_dfs). The two instance DFSs share c->inst_emit_state, so each instance emits exactly
// once and the wrong-kind call is an immediate no-op; emit_inst_dfs is tried first so a same-module instance
// is never consumed (marked done) by the re-homed pass. A cross-module user type is completed by a full
// #include (emit_header_includes), not emitted here. Each branch is gated on its state buffer, so outside the
// body pass (forward typedefs, whose order is irrelevant) this is inert.
static void emit_home_dep(Codegen *c, const TypeId st) {
  if (st == TYPE_NONE)
    return;
  const Ty *y = ast_type_at(c->ast, st);
  if ((y->kind == TYPE_STRUCT || y->kind == TYPE_ENUM) && y->module == c->ast->module && c->type_state) {
    const Node *const dn = ast_at_const(c->ast, y->as.decl);
    if (type_emittable(c, dn))
      emit_type_dfs(c, y->as.decl, c->type_state);
  } else if (y->kind == TYPE_INSTANCE && c->inst_emit_state) {
    emit_inst_dfs(c, y->as.inst, c->inst_emit_state, c->inst_emit_n, true);
    emit_rehomed_struct_dfs(c, y->as.inst, c->inst_emit_state, c->inst_emit_n, true);
  }
}

// Emit generic instance `idx` after the type-units it embeds BY VALUE (post-order DFS), so a by-value
// field/payload is a complete type at its point of use: Option<String<Global>> embeds String__Global (another
// instance), Option<Account> embeds Account (a user struct). `state`: 0 unvisited / 1 on-path / 2 emitted;
// shared with the re-homed DFS, so a cross-module / non-concrete instance is LEFT for that pass (not marked).
static void emit_inst_dfs(Codegen *c, const uint32_t idx, uint8_t *const state, const size_t nstate, const bool with_body) {
  if (idx >= nstate || state[idx])
    return;
  const TyInstance it = c->ast->instances.data[idx]; // copy: emitting below may grow the table
  bool concrete = true;
  for (uint8_t k = 0; k < it.n; k++)
    concrete &= type_is_concrete(c, it.args[k]);
  if (it.module != c->ast->module || !concrete) // cross-module / intermediate (Box<T>): the re-homed pass owns it
    return;
  state[idx] = 1;
  const Node *const dn = ast_at_const(c->ast, it.decl);
  TypeId deps[32];
  int nh = 0;
  { // resolve by-value field/payload types under this instance's arg subst, BEFORE recursing (which resets subst)
    const NodeList gens = dn->as.aggregate.generics;
    const NodeId *const gids = ast_list(c->ast, gens);
    const int saved = c->nsubst;
    c->nsubst = 0;
    for (uint32_t g = 0; g < gens.len && g < it.n && c->nsubst < 8; g++) {
      c->subst[c->nsubst].param = (DefId){it.module, gids[g]};
      c->subst[c->nsubst].concrete = it.args[g];
      c->nsubst++;
    }
    const NodeId *const mids = ast_list(c->ast, dn->as.aggregate.members);
    for (uint32_t m = 0; m < dn->as.aggregate.members.len; m++) {
      const Node *const mn = ast_at_const(c->ast, mids[m]);
      if (dn->kind == NODE_STRUCT && mn->kind == NODE_FIELD) {
        push_home_dep(c, subst_resolve(c, ast_type(c->ast, mn->as.field.type)), deps, &nh);
      } else if (dn->kind == NODE_ENUM && mn->kind == NODE_VARIANT) {
        const NodeId *const pids = ast_list(c->ast, mn->as.variant.payload);
        for (uint32_t k = 0; k < mn->as.variant.payload.len; k++) {
          const Node *const pf = ast_at_const(c->ast, pids[k]);
          push_home_dep(c, subst_resolve(c, ast_type(c->ast, pf->kind == NODE_FIELD ? pf->as.field.type : pids[k])), deps, &nh);
        }
      }
    }
    c->nsubst = saved;
  }
  for (int d = 0; d < nh; d++)
    emit_home_dep(c, deps[d]);
  if (dn->kind == NODE_STRUCT)
    emit_struct_inst(c, &it, with_body);
  else if (dn->kind == NODE_ENUM)
    emit_enum_inst(c, &it, with_body);
  state[idx] = 2;
}

static void emit_aggregate_specializations(Codegen *c, const bool with_body) {
  if (!with_body)
    emit_generic_enum_shared(c); // shared tag/plain enums, before any instance struct names them
  const size_t n = c->ast->instances.len;
  // Body pass: reuse the shared state phase_types also drives via emit_type_dfs, so instances pulled in early
  // (embedded by value in a user struct) are not re-emitted here. Forward pass / OOM: a private state.
  uint8_t *const shared = with_body ? c->inst_emit_state : NULL;
  uint8_t *const state = shared ? shared : calloc(n ? n : 1, 1);
  const size_t nstate = shared ? c->inst_emit_n : n;
  if (!state) { // OOM: fall back to insertion order (correct unless an instance embeds a later one by value)
    for (size_t i = 0; i < c->ast->instances.len; i++) {
      const TyInstance *const it = &c->ast->instances.data[i];
      bool concrete = true;
      for (uint8_t k = 0; k < it->n; k++)
        concrete &= type_is_concrete(c, it->args[k]);
      if (it->module != c->ast->module || !concrete)
        continue;
      const NodeKind dk = ast_at_const(c->ast, it->decl)->kind;
      if (dk == NODE_STRUCT)
        emit_struct_inst(c, it, with_body);
      else if (dk == NODE_ENUM)
        emit_enum_inst(c, it, with_body);
    }
    return;
  }
  for (size_t i = 0; i < n && i < nstate; i++)
    emit_inst_dfs(c, (uint32_t)i, state, nstate, with_body);
  if (state != shared)
    free(state);
}

// --- generic macros: a cross-module instance over a user type by value (Option<Bar>) cannot be emitted by
// the generic's own module (it can only forward-declare Bar -> an incomplete by-value field). Instead the
// generic's module exports `<G>_DECLARE`/`<G>_DEFINE` C macros (parameterized by each type arg's C spelling
// + mangle token, then the instance NAME), and the type's module invokes them so the instance materializes
// where its args are complete. The macros also let a plain-C project reuse the type without Super-C. ----

// Non-generic methods of every generic extend on `declId` (in this module), as macro prototypes
// (define=false) or bodies (define=true), each named `NAME ## __<method>`. Generic methods (map<U>) and
// multi-return methods cannot be a fixed macro and are skipped (emitted concretely for builtin instances).
static void emit_generic_macro_methods(Codegen *c, const NodeId declId, const bool define) {
  const NodeList items = program_items(c);
  const NodeId *const iids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, iids[i]);
    if (n->kind != NODE_EXTEND || !n->as.extend_def.generics.len)
      continue;
    if (ast_resolution(c->ast, n->as.extend_def.target_type) != declId)
      continue;
    if (n->as.extend_def.interface_type != NODE_NONE)
      continue; // a conditional conformance: emitted via its own gated per-conformance macro, not the core one
    const NodeList ms = n->as.extend_def.items;
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

// The macro-name fragment for a conditional conformance extend: the interface's source name (`Clone`), so a
// type's conformance macros are `<STEM>_as_Clone_DECLARE/DEFINE`. Distinct interfaces -> distinct macros.
static size_t conformance_tag(Codegen *c, const Node *const extend, char *out, const size_t cap) {
  const DefId tr = ast_resolution_def(c->ast, extend->as.extend_def.interface_type);
  size_t at = buf_append(out, cap, 0, "as_");
  if (tr.node == NODE_NONE)
    return at;
  const Node *const trn = ast_at_const(cg_mod_ast(c, tr.module), tr.node);
  return at + render_ident_src(cg_mod_src(c, tr.module),
                               ast_at_const(cg_mod_ast(c, tr.module), trn->as.interface_def.name)->as.name.text,
                               out + at, cap > at ? cap - at : 0);
}

// One conditional conformance extend as `#define <STEM>_as_<Iface>_DECLARE(T,_SCM_T,..,NAME) <protos>` /
// `_DEFINE` (bodies), in macro mode. The home invokes it (after the core DECLARE/DEFINE) ONLY for instances
// that satisfy the conformance, so different element types get different subsets (Clone-but-not-Hash, etc.).
static void emit_generic_conformance_macro(Codegen *c, const NodeId declId, const NodeId implId, const bool define) {
  const Node *const dn = ast_at_const(c->ast, declId);
  const Node *const extend = ast_at_const(c->ast, implId);
  char stem[160], tag[80];
  macro_stem(c, c->ast->module, dn->as.aggregate.name, stem, sizeof stem);
  conformance_tag(c, extend, tag, sizeof tag);
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
  const NodeList ms = extend->as.extend_def.items;
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

// Every conditional conformance extend on `declId`, as DECLARE + DEFINE macros (gated per-instance at the home).
static void emit_generic_conformance_macros(Codegen *c, const NodeId declId) {
  const NodeList items = program_items(c);
  const NodeId *const iids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, iids[i]);
    if (n->kind != NODE_EXTEND || !n->as.extend_def.generics.len || n->as.extend_def.interface_type == NODE_NONE)
      continue;
    if (ast_resolution(c->ast, n->as.extend_def.target_type) != declId)
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
      const char *const kw = agg_kw(dn); // `union` for an untagged-union aggregate (SSO String)
      emit(c, "typedef %s NAME NAME;\n", kw);
      emit(c, "%s NAME {\n", kw);
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

// Every generic method of the generic extends on `declId`, as DECLARE + DEFINE macros.
static void emit_generic_method_macros(Codegen *c, const NodeId declId) {
  const NodeList items = program_items(c);
  const NodeId *const iids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, iids[i]);
    if (n->kind != NODE_EXTEND || !n->as.extend_def.generics.len)
      continue;
    if (ast_resolution(c->ast, n->as.extend_def.target_type) != declId)
      continue;
    const NodeList ms = n->as.extend_def.items;
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
// Emit the opt-in C-reuse macro templates (<G>_DECLARE/<G>_DEFINE) for every generic struct/enum carrying
// the `@emit_macro` attribute, so a plain-C project can instantiate the type over its own C types. Purely
// additive: Super-C's own instances are full-monomorphized (these templates are never invoked internally).
static void emit_generic_macros(Codegen *c) {
  if (!c->package)
    return;
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if ((n->kind != NODE_STRUCT && n->kind != NODE_ENUM) || !n->as.aggregate.generics.len)
      continue;
    if (!cg_attr(c, c->ast->module, ids[i], ATTR_EMIT_MACRO)) // opt-in, per generic type
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
      emit(c, "typedef %s %s %s;\n", agg_kw(dn), inm, inm); // `union` for an SSO-union instance
    } else { // payload-less enum instance: alias the shared plain enum (from the generic's header)
      char en[160];
      render_qualified(c, it.module, dn->as.aggregate.name, en, sizeof en);
      emit(c, "typedef %s %s;\n", en, inm);
    }
  }
}

// Full-monomorphize a cross-module generic instance re-homed to this module (its args are user types defined
// here, which the generic's own module could only forward-declare -> an incomplete by-value field). Source
// the generic's template (decl, fields/extends/method bodies) from its owner module via a temporary c->ast
// swap, reinterning the instance's args into the owner pool so the substitution stays self-consistent.
// Output (c->buf) and the home instance table are unaffected -- c->buf is independent of c->ast, and the
// owner's codegen pass has already run (deps emit first), so interning into the owner pool here is inert.
static void emit_rehomed_struct(Codegen *c, const TyInstance *const it, const bool with_body) {
  Ast *const home = c->ast;
  const uint8_t *const hsrc = c->source;
  const size_t hlen = c->len;
  Ast *const owner = cg_mod_ast(c, it->module);          // capture owner ast/source BEFORE swapping c->ast,
  const uint8_t *const osrc = cg_mod_src(c, it->module); // else cg_mod_src would resolve against the new module
  const size_t oninst = owner->instances.len;            // instances interned into the owner during this emit
  TyInstance oit = *it;                                  // (arg reinterns, satisfies-checks) are transient
  for (uint8_t k = 0; k < it->n; k++)
    oit.args[k] = ast_reintern(owner, home, it->args[k]);
  c->ast = owner;
  c->source = osrc;
  c->len = c->package->modules[it->module].source_len;
  c->borrowed = true;
  const NodeKind dk = ast_at_const(owner, oit.decl)->kind;
  if (dk == NODE_STRUCT)
    emit_struct_inst(c, &oit, with_body);
  else if (dk == NODE_ENUM)
    emit_enum_inst(c, &oit, with_body);
  owner->instances.len = oninst; // drop transient instances so the owner's own pass never re-emits them
  c->borrowed = false;
  c->ast = home;
  c->source = hsrc;
  c->len = hlen;
  c->nsubst = 0;
}

static TypeId rehome_subst_type(Codegen *c, Ast *const owner, Ast *const home, const TyInstance *const it,
                                const TypeId t) {
  if (t == TYPE_NONE)
    return TYPE_NONE;
  const Ty ty = *ast_type_at(owner, t);
  switch (ty.kind) {
    case TYPE_GENERIC: {
      const Node *const dn = ast_at_const(owner, it->decl);
      const NodeId *const gids = ast_list(owner, dn->as.aggregate.generics);
      for (uint32_t i = 0; i < dn->as.aggregate.generics.len && i < it->n; i++)
        if (ty.module == it->module && ty.as.decl == gids[i])
          return it->args[i];
      return ast_reintern(home, owner, t);
    }
    case TYPE_POINTER:
    case TYPE_REFERENCE:
    case TYPE_SLICE:
    case TYPE_ARRAY: {
      Ty nt = ty;
      nt.as.elem = rehome_subst_type(c, owner, home, it, ty.as.elem);
      return ast_intern_type(home, nt);
    }
    case TYPE_INSTANCE: {
      const TyInstance inst = *ast_instance(owner, ty.as.inst);
      TypeId na[4];
      const uint8_t n = inst.n < 4 ? inst.n : 4;
      for (uint8_t i = 0; i < n; i++)
        na[i] = rehome_subst_type(c, owner, home, it, inst.args[i]);
      return ast_intern_instance(home, inst.module, inst.decl, na, n);
    }
    default:
      return ast_reintern(home, owner, t);
  }
}

// Emit a re-homed instance `idx` after the type-units it embeds BY VALUE, like emit_inst_dfs but for an
// instance whose template lives in another module: members are read from the owner ast and each field type
// is mapped into the home pool via rehome_subst_type, then dispatched through emit_home_dep -- which may pull
// another re-homed instance, a same-module instance, or a user struct (Option<Account> embeds Account). The
// shared state means a non-re-homed instance is simply consumed here once the instance pass has emitted it.
static void emit_rehomed_struct_dfs(Codegen *c, const uint32_t idx, uint8_t *const state, const size_t nstate,
                                    const bool with_body) {
  if (idx >= nstate || state[idx])
    return;
  const TyInstance it = c->ast->instances.data[idx];
  if (!inst_rehomed_here(c, &it)) { // same-module (already emitted by the instance pass) or another module's: consume
    state[idx] = 2;
    return;
  }
  state[idx] = 1;
  Ast *const owner = cg_mod_ast(c, it.module);
  const Node *const dn = ast_at_const(owner, it.decl);
  TypeId deps[32];
  int nh = 0;
  const NodeId *const mids = ast_list(owner, dn->as.aggregate.members);
  for (uint32_t m = 0; m < dn->as.aggregate.members.len; m++) {
    const Node *const mn = ast_at_const(owner, mids[m]);
    if (dn->kind == NODE_STRUCT && mn->kind == NODE_FIELD) {
      push_home_dep(c, rehome_subst_type(c, owner, c->ast, &it, ast_type(owner, mn->as.field.type)), deps, &nh);
    } else if (dn->kind == NODE_ENUM && mn->kind == NODE_VARIANT) {
      const NodeId *const pids = ast_list(owner, mn->as.variant.payload);
      for (uint32_t k = 0; k < mn->as.variant.payload.len; k++) {
        const Node *const pf = ast_at_const(owner, pids[k]);
        const NodeId tn = pf->kind == NODE_FIELD ? pf->as.field.type : pids[k];
        push_home_dep(c, rehome_subst_type(c, owner, c->ast, &it, ast_type(owner, tn)), deps, &nh);
      }
    }
  }
  for (int d = 0; d < nh; d++)
    emit_home_dep(c, deps[d]);
  emit_rehomed_struct(c, &it, with_body);
  state[idx] = 2;
}

static void emit_rehomed_structs(Codegen *c, const bool with_body) {
  if (!c->package)
    return;
  const size_t n = c->ast->instances.len;
  // Body pass: share phase_types' instance state, so an instance already emitted (by the instance pass, or
  // pulled in early by a user struct that embeds it) is skipped here. Forward pass / OOM: a private state.
  uint8_t *const shared = with_body ? c->inst_emit_state : NULL;
  uint8_t *const state = shared ? shared : calloc(n ? n : 1, 1);
  const size_t nstate = shared ? c->inst_emit_n : n;
  if (!state) {
    for (size_t ii = 0; ii < n; ii++) {
      const TyInstance it = c->ast->instances.data[ii];
      if (inst_rehomed_here(c, &it))
        emit_rehomed_struct(c, &it, with_body);
    }
    return;
  }
  for (size_t ii = 0; ii < n && ii < nstate; ii++)
    emit_rehomed_struct_dfs(c, (uint32_t)ii, state, nstate, with_body);
  if (state != shared)
    free(state);
}

// Methods of every cross-module instance re-homed here: template (extends + method bodies) sourced from the
// owner via the c->ast swap, while generic-method uses (map<U>) are still read from this (home) module's
// method_insts (keyed by the receiver's home-pool TypeId), since that is where the uses were recorded.
static void emit_rehomed_methods(Codegen *c, const int which, const bool with_body) {
  if (!c->package)
    return;
  Ast *const home = c->ast;
  const uint8_t *const hsrc = c->source;
  const size_t hlen = c->len;
  for (size_t ii = 0; ii < home->instances.len; ii++) {
    const TyInstance it = home->instances.data[ii];
    if (!inst_rehomed_here(c, &it))
      continue;
    const TypeId itTy = ast_intern_instance(home, it.module, it.decl, it.args, it.n); // home-pool key for map<U>
    Ast *const owner = cg_mod_ast(c, it.module);          // capture owner ast/source BEFORE swapping c->ast
    const uint8_t *const osrc = cg_mod_src(c, it.module);
    const size_t oninst = owner->instances.len;
    TyInstance oit = it;
    for (uint8_t k = 0; k < it.n; k++)
      oit.args[k] = ast_reintern(owner, home, it.args[k]);
    c->ast = owner;
    c->source = osrc;
    c->len = c->package->modules[it.module].source_len;
    c->borrowed = true;
    emit_inst_methods(c, &oit, home, itTy, which, with_body);
    owner->instances.len = oninst; // drop transient instances so the owner's own pass never re-emits them
    c->borrowed = false;
    c->ast = home;
    c->source = hsrc;
    c->len = hlen;
    c->nsubst = 0;
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
// --const-eval layout verification: for every type whose size/align the const evaluator computed,
// emit a C _Static_assert next to the module's code so the DOWNSTREAM compiler proves the 64-bit
// layout model on the actual target (a mismatch is a named compile error, never a silent one).
static void emit_layout_asserts(Codegen *c) {
  ConstEval *const ce = cg_ceval(c);
  if (!ce)
    return;
  bool any = false;
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if ((n->kind != NODE_STRUCT && n->kind != NODE_ENUM) || n->as.aggregate.generics.len)
      continue;
    if (n->kind == NODE_ENUM && !aggregate_has_payload(c, n))
      continue; // payload-less enums may only exist as guarded copies; their `int` size is universal
    const TypeId t = ast_intern_type(
        c->ast, (Ty){.kind = n->kind == NODE_ENUM ? TYPE_ENUM : TYPE_STRUCT, .module = c->ast->module, .as.decl = ids[i]});
    uint64_t size, align;
    if (!consteval_layout(ce, c->ast->module, t, &size, &align))
      continue;
    char nm[256];
    render_type_id(c, t, "", nm, sizeof nm);
    emit(c, "_Static_assert(sizeof(%s) == %llu && _Alignof(%s) == %llu, \"super-c layout model mismatch: %s\");\n",
         nm, (unsigned long long)size, nm, (unsigned long long)align, nm);
    any = true;
  }
  for (size_t ii = 0; ii < c->ast->instances.len; ii++) {
    const TyInstance it = c->ast->instances.data[ii];
    if (it.module != c->ast->module)
      continue; // owned instances only: exactly the set this module's header defines
    bool concrete = true;
    for (uint8_t k = 0; k < it.n; k++)
      concrete &= type_is_concrete(c, it.args[k]);
    if (!concrete)
      continue;
    const TypeId t = ast_intern_instance(c->ast, it.module, it.decl, it.args, it.n);
    uint64_t size, align;
    if (!consteval_layout(ce, c->ast->module, t, &size, &align))
      continue;
    char nm[256];
    render_type_id(c, t, "", nm, sizeof nm);
    emit(c, "_Static_assert(sizeof(%s) == %llu && _Alignof(%s) == %llu, \"super-c layout model mismatch: %s\");\n",
         nm, (unsigned long long)size, nm, (unsigned long long)align, nm);
    any = true;
  }
  if (any)
    emit(c, "\n");
}

static bool type_emittable(Codegen *c, const Node *const n) {
  return (n->kind == NODE_STRUCT && !n->as.aggregate.generics.len) ||
         (n->kind == NODE_ENUM && !n->as.aggregate.generics.len && aggregate_has_payload(c, n));
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

// Emit a user struct/enum after the type-units it embeds BY VALUE (post-order DFS): another user type, a
// same-module generic instance (Vector<Account> in a field), or one re-homed here -- all dispatched through
// emit_home_dep so layout always sees a complete type. `state`: 0 unvisited, 1 on the current path (a cycle --
// the type checker rejects by-value cycles, so just stop), 2 emitted.
static void emit_type_dfs(Codegen *c, const NodeId declId, uint8_t *const state) {
  if (state[declId])
    return;
  state[declId] = 1;
  const Node *const n = ast_at_const(c->ast, declId);
  const NodeId *const mids = ast_list(c->ast, n->as.aggregate.members);
  TypeId deps[32];
  int nh = 0;
  for (uint32_t i = 0; i < n->as.aggregate.members.len; i++) { // (no subst active: a user type's fields are concrete)
    const Node *const m = ast_at_const(c->ast, mids[i]);
    if (n->kind == NODE_STRUCT && m->kind == NODE_FIELD) {
      push_home_dep(c, ast_type(c->ast, m->as.field.type), deps, &nh);
    } else if (n->kind == NODE_ENUM && m->kind == NODE_VARIANT) {
      const NodeId *const plids = ast_list(c->ast, m->as.variant.payload);
      for (uint32_t k = 0; k < m->as.variant.payload.len; k++) {
        const Node *const pf = ast_at_const(c->ast, plids[k]);
        push_home_dep(c, ast_type(c->ast, pf->kind == NODE_FIELD ? pf->as.field.type : plids[k]), deps, &nh);
      }
    }
  }
  for (int d = 0; d < nh; d++)
    emit_home_dep(c, deps[d]);
  emit_type_decl(c, declId);
  state[declId] = 2;
}

// The persistent per-Codegen DFS state (lazily allocated, sized to the node count); NULL on OOM.
static uint8_t *cg_type_state(Codegen *c) {
  if (!c->type_state)
    c->type_state = calloc(c->ast->nodes.len, 1);
  return c->type_state;
}

static void phase_types(Codegen *c) {
  seed_emitted_type_instances(c);
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  // Emit struct/enum bodies in value-containment dependency order: a by-value field of a struct defined
  // later in source must still be complete at the point of use. Forward typedefs already exist. The DFS
  // state persists (cg_type_state), so a concrete struct the single-TU pre-pass already emitted is skipped.
  uint8_t *const state = cg_type_state(c);
  // Shared instance state so emit_type_dfs (a user struct pulling in a by-value instance) and
  // emit_aggregate_specializations agree on what's already emitted. NULL on OOM -> insertion order (the prior
  // behavior). Sized now: nothing between here and emit_aggregate_specializations grows the instance table.
  const size_t ni = c->ast->instances.len;
  c->inst_emit_state = calloc(ni ? ni : 1, 1);
  c->inst_emit_n = c->inst_emit_state ? ni : 0;
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (type_emittable(c, n)) {
      if (state)
        emit_type_dfs(c, ids[i], state);
      else
        emit_type_decl(c, ids[i]); // out of memory: fall back to source order
    }
  }
  emit_aggregate_specializations(c, true); // full bodies for generic struct instantiations
  emit_rehomed_structs(c, true);           // full bodies for cross-module instances homed here (after their args)
  emit_generic_macros(c);                  // @emit_macro generics as <G>_DECLARE/<G>_DEFINE C-reuse templates
  free(c->inst_emit_state);
  c->inst_emit_state = NULL;
  c->inst_emit_n = 0;
}

// Multi-return structs, after all type definitions (they reference parameter/return types).
static void phase_ret_structs(Codegen *c) {
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (n->kind == NODE_FUNCTION && !n->as.function.generics.len) {
      emit_ret_struct(c, ids[i], (DefId){0, NODE_NONE});
    } else if (n->kind == NODE_EXTEND && !n->as.extend_def.generics.len) {
      const DefId target = ast_resolution_def(c->ast, n->as.extend_def.target_type);
      const NodeList ms = n->as.extend_def.items;
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

// Phase 3: prototypes for top-level functions, extend methods and extern functions (filtered by `which`).
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
    } else if (n->kind == NODE_EXTEND) {
      if (n->as.extend_def.generics.len)
        continue; // a generic extend emits no template; its methods are specialized per instance below
      const DefId target = ast_resolution_def(c->ast, n->as.extend_def.target_type);
      const NodeList ms = n->as.extend_def.items;
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
  emit_rehomed_methods(c, which, false);         // method protos for cross-module instances homed here
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
  if (cg_ceval(c)) // folding may replace every use of a const with its value -- keep -Werror clean
    emit(c, "__attribute__((unused)) ");
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

  emit_default_methods(c, PROTO_ALL, true);  // inherited interface default-method bodies
  emit_specializations(c, true);            // concrete generic free-function instantiations
  emit_method_specializations(c, PROTO_ALL, true); // concrete generic method instantiations
  emit_rehomed_methods(c, PROTO_ALL, true);  // method bodies for cross-module instances homed here
  emit_closures(c, true);                    // hoisted closure / anonymous-fn bodies
  emit_callback_specializations(c, true);    // callback-specialized free functions (Win 1)

  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (n->kind == NODE_FUNCTION && !n->as.function.generics.len && n->as.function.body != NODE_NONE &&
        !cb_specialized_away(c, ids[i]) && !cg_is_format_builtin(c, c->ast->module, ids[i])) {
      emit_function(c, ids[i], (DefId){0, NODE_NONE}, false, true, NULL, false);
    } else if (n->kind == NODE_EXTEND && !n->as.extend_def.generics.len) {
      const DefId target = ast_resolution_def(c->ast, n->as.extend_def.target_type);
      const NodeList ms = n->as.extend_def.items;
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

// A grow-on-demand set of forward-declared C names. Many distinct type-pool entries can mangle to the same
// C name (every concrete String<T> -> String__Global, but also each abstract String<T> -> String__v), so the
// pass declares each name once instead of flooding the header with identical (if legal) typedefs.
typedef struct {
  char (*names)[256];
  size_t len, cap;
} FwdSeen;
static bool fwd_seen_add(FwdSeen *const s, const char *const name) {
  for (size_t i = 0; i < s->len; i++)
    if (!strcmp(s->names[i], name))
      return true;
  if (s->len == s->cap) {
    s->cap = s->cap ? s->cap * 2 : 16;
    s->names = realloc(s->names, s->cap * sizeof *s->names);
    if (!s->names)
      oom();
  }
  memcpy(s->names[s->len++], name, strlen(name) + 1);
  return false;
}

// Forward-declare every referenced cross-module STRUCT, so this header's prototypes can name them even
// under a mutual include cycle (e.g. str <-> string via str.to_string() / String.from_str()). A prototype
// needs only the name; the full type still arrives via the includes below (needed for by-value fields) and
// in the .c. Duplicate `typedef struct X X;` is legal C, so this is safe even when an include re-declares it.
static void emit_referenced_fwd(Codegen *c) {
  const ModuleId cur = c->ast->module;
  FwdSeen seen = {0};
  for (size_t i = 0; i < c->ast->type_pool.len; i++) {
    const Ty t = c->ast->type_pool.data[i];
    if (t.kind == TYPE_INSTANCE) { // a cross-module generic instance used by value (`str.to_string() -> String<Global>`)
      const TyInstance *const it = ast_instance(c->ast, t.as.inst);
      if (it->module == cur || it->module >= c->package->count)
        continue;
      bool concrete = true; // an abstract template (String<T>) is never named by an emitted prototype, and
      for (uint8_t k = 0; k < it->n; k++) // every arg mangles to the same `__v` -- skip it, else the pool
        concrete &= type_is_concrete(c, it->args[k]); // floods the header with bogus String__v typedefs.
      if (!concrete)
        continue;
      const Node *const idn = ast_at_const(cg_mod_ast(c, it->module), it->decl);
      if (idn->kind == NODE_STRUCT || aggregate_has_payload_in(c, it->module, idn)) {
        char inm[200];
        inst_name(c, it, inm, sizeof inm);
        if (!fwd_seen_add(&seen, inm))
          emit(c, "typedef %s %s %s;\n", agg_kw(idn), inm, inm); // `union` for an SSO-union instance
      }
      continue;
    }
    if (t.module == cur || t.module >= c->package->count)
      continue;
    if (package_builtin_of_decl(c->package, t.module, t.as.decl) >= 0)
      continue;
    const Node *const dn = ast_at_const(cg_mod_ast(c, t.module), t.as.decl);
    // A struct, or a payload enum (struct-shaped in C), forward-declares as `typedef struct X X;` --
    // enough for a prototype that names it. A payload-less enum lowers to a C `enum`, which C11 cannot
    // forward-declare, so emit its guarded full definition (self-contained: only integer discriminants).
    if (t.kind == TYPE_STRUCT || (t.kind == TYPE_ENUM && aggregate_has_payload_in(c, t.module, dn))) {
      char nm[160];
      render_qualified(c, t.module, dn->as.aggregate.name, nm, sizeof nm);
      if (!fwd_seen_add(&seen, nm))
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
  free(seen.names);
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
  if (ast_at_const(a, node)->kind == NODE_INTERFACE)
    return true;
  if (ast_at_const(a, node)->kind != NODE_FUNCTION)
    return false;
  const NodeList items = ast_at_const(a, a->root)->as.program.items;
  const NodeId *const ids = ast_list(a, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const it = ast_at_const(a, ids[i]);
    if (it->kind != NODE_INTERFACE)
      continue;
    const NodeList ms = it->as.interface_def.items;
    const NodeId *const mids = ast_list(a, ms);
    for (uint32_t j = 0; j < ms.len; j++)
      if (mids[j] == node)
        return true;
  }
  return false;
}

static bool type_mentions_builtin(Codegen *c, const TypeId t) {
  if (t == TYPE_NONE)
    return false;
  const Ty *const y = ast_type_at(c->ast, t);
  switch (y->kind) {
    case TYPE_BUILTIN:
      return true;
    case TYPE_POINTER:
    case TYPE_REFERENCE:
    case TYPE_SLICE:
    case TYPE_ARRAY:
      return type_mentions_builtin(c, y->as.elem);
    case TYPE_INSTANCE: {
      const TyInstance *const it = ast_instance(c->ast, y->as.inst);
      for (uint8_t i = 0; i < it->n; i++)
        if (type_mentions_builtin(c, it->args[i]))
          return true;
      return false;
    }
    default:
      return false;
  }
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
    // An interface, or an interface METHOD, has NO C representation: a interface bound, a conformance's
    // `as Iface`, and a bound-method call (`v.fmt()` resolved to `Format::fmt`) all reference the interface
    // module but generate no use of its header (codegen dispatches to the concrete extend in the value's own
    // module). Pulling the interface header here would re-form a cycle (a value type that conforms to a prelude
    // interface would include the interface module, which references that very type by value).
    if (cg_decl_is_interface_member(c, d.module, d.node))
      continue;
    want[d.module] = true;
  }
  for (size_t i = 0; i < c->ast->type_pool.len; i++) {
    const Ty t = c->ast->type_pool.data[i]; // named types reach modules a literal/inference uses w/o a ref
    if ((t.kind != TYPE_STRUCT && t.kind != TYPE_ENUM && t.kind != TYPE_FUNCTION) || t.module == cur || t.module >= nmod)
      continue; // (TYPE_GENERIC is a param / Self -- never an emittable type, so never an include)
    if (package_builtin_of_decl(c->package, t.module, t.as.decl) >= 0)
      continue; // synthetic builtin nominal decls live in core's pool, but C spells them as scalars
    if (t.kind == TYPE_FUNCTION && cg_decl_is_interface_member(c, t.module, t.as.decl))
      continue; // an interface method's function type (e.g. `Format::fmt`) -- no C symbol, no header needed
    want[t.module] = true;
  }
  // A generic instance materialized in another module needs that module's header. An instance over a user
  // type is re-homed to the type's module (the generic's macros build it there); an instance over only
  // builtin/prelude args is owner-emitted in the generic's own module. Either way, if it lives elsewhere we
  // must include its header -- an instance used only as a field/param/return type (e.g. a `[]i32` slice, or
  // a `Vector<i32>`) has no ordinary resolution / named-type entry to pull it in otherwise.
  for (size_t i = 0; i < c->ast->instances.len; i++) {
    const TyInstance *const it = &c->ast->instances.data[i];
    bool concrete = it->module < nmod || it->module == cur;
    for (uint8_t k = 0; k < it->n && concrete; k++)
      concrete = type_is_concrete(c, it->args[k]);
    if (!concrete)
      continue;
    const ModuleId home = package_instance_home(c->package, c->ast, it);
    if (it->module != cur && it->module < nmod)
      want[it->module] = true; // the generic's owner (its struct/enum body, or its macros + shared tag)
    if (home != cur && home < nmod)
      want[home] = true; // where the instance is materialized (== owner for builtin/prelude args)
  }
  // Builtin conformances (i32__hash, i32__eq, ...) live in core; a generic instance over a builtin arg
  // (Map<i32,_>) can call them from its method bodies. Plain scalar use does not need core.h.
  if (c->package->core_seeded && c->package->core_module != cur && c->package->core_module < nmod) {
    bool need_core = false;
    for (size_t i = 0; i < c->ast->instances.len && !need_core; i++) {
      const TyInstance *const it = &c->ast->instances.data[i];
      bool concrete = it->module < nmod || it->module == cur;
      for (uint8_t k = 0; k < it->n && concrete; k++)
        concrete = type_is_concrete(c, it->args[k]);
      for (uint8_t k = 0; k < it->n && concrete && !need_core; k++)
        need_core = type_mentions_builtin(c, it->args[k]);
    }
    for (int i = 0; i < c->ninsts && !need_core; i++)
      for (uint8_t k = 0; k < c->insts[i].n && !need_core; k++)
        need_core = type_mentions_builtin(c, c->insts[i].args[k]);
    if (need_core)
      want[c->package->core_module] = true;
  }
  for (size_t m = 0; m < nmod; m++)
    if (want[m])
      emit_modpath_include(c, c->package->modules[m].path);
  free(want);
}

// Mark the module whose COMPLETE type a by-value field/array/payload of resolved type `ft` needs. A
// pointer/reference (and the box/slice indirections that lower to one) needs only a forward declaration,
// so it marks nothing. This drives a HEADER's #includes purely from layout: a header pulls another
// module's full `.h` only when it lays a type out by value, never for a prototype's by-value return/param
// (legal C with an incomplete type). That is what stops two Super-C modules that name each other --
// `option` lays out `Option<str>` (needs `str`), `str` only returns `Option<..>` from prototypes -- from
// forming a generated C header cycle: `option.h` includes `str.h`, but `str.h` forward-declares `Option`.
static void mark_layout_module(Codegen *c, const TypeId ft, bool *const want, const size_t nmod) {
  if (ft == TYPE_NONE)
    return;
  TypeId cft = subst_resolve(c, ft);
  const Ty *y = ast_type_at(c->ast, cft);
  while (y->kind == TYPE_ARRAY) { // an array embeds its element by value
    cft = y->as.elem;
    y = ast_type_at(c->ast, cft);
  }
  const ModuleId cur = c->ast->module;
  if (y->kind == TYPE_STRUCT || y->kind == TYPE_ENUM) {
    if (y->module != cur && y->module < nmod && package_builtin_of_decl(c->package, y->module, y->as.decl) < 0)
      want[y->module] = true;
  } else if (y->kind == TYPE_INSTANCE) {
    const TyInstance *const it = ast_instance(c->ast, y->as.inst);
    const ModuleId home = package_instance_home(c->package, c->ast, it); // the instance body lives in its home
    if (home != cur && home < nmod)
      want[home] = true;
  }
}

// Walk the by-value fields/payloads of one (possibly generic, under `subst`) aggregate decl, marking the
// modules their layout needs. Shared by a module's own non-generic types and its materialized instances.
static void mark_aggregate_layout(Codegen *c, const Node *const dn, bool *const want, const size_t nmod) {
  const NodeList ms = dn->as.aggregate.members;
  const NodeId *const mids = ast_list(c->ast, ms);
  for (uint32_t m = 0; m < ms.len; m++) {
    const Node *const mn = ast_at_const(c->ast, mids[m]);
    if (dn->kind == NODE_STRUCT && mn->kind == NODE_FIELD) {
      mark_layout_module(c, ast_type(c->ast, mn->as.field.type), want, nmod);
    } else if (dn->kind == NODE_ENUM && mn->kind == NODE_VARIANT) {
      const NodeList pl = mn->as.variant.payload;
      const NodeId *const plids = ast_list(c->ast, pl);
      for (uint32_t k = 0; k < pl.len; k++) {
        const Node *const pf = ast_at_const(c->ast, plids[k]);
        mark_layout_module(c, ast_type(c->ast, pf->kind == NODE_FIELD ? pf->as.field.type : plids[k]), want, nmod);
      }
    }
  }
}

// A module's public HEADER #includes: only the modules whose complete types this header lays out by value
// (its own non-generic aggregates, the generic instances materialized here, multi-return bundles, and
// by-value consts). Everything else a header names -- prototype params/returns, pointer/reference fields --
// is satisfied by the forward declarations emitted just above (emit_referenced_fwd) and by the full
// includes in the .c. Restricting header includes to layout needs is what keeps mutually-importing modules
// (option <-> str) from forming a C include cycle while still completing every by-value field.
static void emit_header_includes(Codegen *c) {
  const size_t nmod = c->package->count;
  const ModuleId cur = c->ast->module;
  bool *const want = calloc(nmod ? nmod : 1, sizeof *want);
  if (!want)
    return;
  const int saved = c->nsubst;
  c->nsubst = 0;
  bool pub_const_expr = false; // a public const whose initializer (emitted verbatim in the header) is more
  const NodeList items = program_items(c); // than a bare literal -- it may name a cross-module type/value
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if ((n->kind == NODE_STRUCT || n->kind == NODE_ENUM) && n->as.aggregate.generics.len == 0) {
      mark_aggregate_layout(c, n, want, nmod); // this module's own concrete struct/enum bodies
    } else if (n->kind == NODE_FUNCTION && n->as.function.returns.len > 1) {
      const NodeId *const rids = ast_list(c->ast, n->as.function.returns); // multi-return bundle struct
      for (uint32_t r = 0; r < n->as.function.returns.len; r++) {
        const Node *const rn = ast_at_const(c->ast, rids[r]);
        mark_layout_module(c, ast_type(c->ast, rn->kind == NODE_PARAMETER ? rn->as.parameter.type : rids[r]), want, nmod);
      }
    } else if (n->kind == NODE_CONST && !n->as.const_def.is_extern) {
      mark_layout_module(c, ast_type(c->ast, n->as.const_def.type), want, nmod);
      if (n->as.const_def.is_public && n->as.const_def.value != NODE_NONE &&
          ast_at_const(c->ast, n->as.const_def.value)->kind != NODE_LITERAL)
        pub_const_expr = true; // e.g. `pub const N: usize = sizeof(other::T);` -- needs other complete here
    }
  }
  for (size_t i = 0; i < c->ast->instances.len; i++) { // generic instances materialized in THIS header
    const TyInstance it = c->ast->instances.data[i];
    bool concrete = it.module < nmod || it.module == cur;
    for (uint8_t k = 0; k < it.n && concrete; k++)
      concrete = type_is_concrete(c, it.args[k]);
    if (!concrete || package_instance_home(c->package, c->ast, &c->ast->instances.data[i]) != cur)
      continue; // not materialized here -> only forward-declared, so no layout include
    if (it.module == cur) { // same-module generic: walk its decl fields under this instance's args
      const Node *const dn = ast_at_const(c->ast, it.decl);
      const NodeList gens = dn->as.aggregate.generics;
      const NodeId *const gids = ast_list(c->ast, gens);
      c->nsubst = 0;
      for (uint32_t g = 0; g < gens.len && g < it.n && c->nsubst < 8; g++) {
        c->subst[c->nsubst].param = (DefId){it.module, gids[g]};
        c->subst[c->nsubst].concrete = it.args[g];
        c->nsubst++;
      }
      mark_aggregate_layout(c, dn, want, nmod);
      c->nsubst = 0;
    } else { // re-homed instance owned elsewhere (only ever a std generic over a user type, so no prelude
      // cycle): needs the owner's full header for the instance's internal by-value types -- the shared tag
      // enum of a payload enum, a String's `StringRepr` union -- plus the modules of its concrete args.
      if (it.module != cur && it.module < nmod)
        want[it.module] = true;
      for (uint8_t k = 0; k < it.n; k++)
        mark_layout_module(c, it.args[k], want, nmod);
    }
  }
  c->nsubst = saved;
  // A public const initializer beyond a literal is emitted verbatim into the header and may reference a
  // cross-module type (`sizeof(other::T)` -> needs the complete type) or value (`other::X` -> needs its
  // declaration). These are not by-value layout fields, so pull in every module this one references (the
  // same set the .c uses). Gated on such a const existing, so the common layout-only path is unaffected.
  if (pub_const_expr) {
    for (size_t i = 0; i < c->ast->resolutions.len; i++) {
      const DefId d = c->ast->resolutions.data[i];
      if (d.node == NODE_NONE || d.module == cur || d.module >= nmod || cg_decl_is_interface_member(c, d.module, d.node))
        continue;
      want[d.module] = true;
    }
    for (size_t i = 0; i < c->ast->type_pool.len; i++) {
      const Ty t = c->ast->type_pool.data[i];
      if ((t.kind == TYPE_STRUCT || t.kind == TYPE_ENUM) && t.module != cur && t.module < nmod &&
          package_builtin_of_decl(c->package, t.module, t.as.decl) < 0)
        want[t.module] = true;
    }
  }
  for (size_t m = 0; m < nmod; m++)
    if (m != cur && want[m])
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
  emit_header_includes(c);     // full headers ONLY for types this header lays out by value (no cycles)
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
    emit_layout_asserts(c); // type definitions came in via the headers just included
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
    emit_layout_asserts(c);
    phase_prototypes(c, PROTO_ALL);
    emit(c, "\n");
    phase_bodies(c);
  }
  errors_finalize(
      &c->errors, &c->errors_notes, &c->errors_start, &c->errors_len, c->source, c->len,
      c->package && c->ast->module < c->package->count ? c->package->modules[c->ast->module].file : NULL);
  if (c->buf_len)
    fwrite(c->buf, 1, c->buf_len, out);
}

ERRORS_BODY(Codegen, codegen, c)
