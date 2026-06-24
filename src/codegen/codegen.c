#include "codegen.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
    ERRORS_VARIABLES;
};

// Super-C builtin names (for matching unresolved type paths) and their C spellings.
static const char *const BUILTIN_NAMES[BT_COUNT] = {
    "bool", "char", "i8",  "i16",   "i32", "i64", "isize", "u8",
    "u16",  "u32",  "u64", "usize", "f32", "f64", "void", "str",
};
static const char *const BUILTIN_C[BT_COUNT] = {
    "bool",     "char",     "int8_t",   "int16_t", "int32_t", "int64_t", "intptr_t", "uint8_t",
    "uint16_t", "uint32_t", "uint64_t", "size_t",  "float",   "double",  "void",     "str",
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

Codegen *codegen_new(Ast *ast, const char *source, const size_t len) {
  Codegen *const c = calloc(1, sizeof *c);
  if (!c) {
    fprintf(stderr, "fatal: out of memory\n");
    abort();
  }
  c->ast = ast;
  c->source = (const uint8_t *)source;
  c->len = len;
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

// Render an identifier (keyword-mangled) into a buffer, for building declarator/accessor strings.
static size_t render_ident(Codegen *c, const Span s, char *buf, const size_t cap) {
  const size_t source_len = s.end - s.start;
  const bool suffix = is_c_keyword(c->source, s);
  const size_t full_len = source_len + suffix;
  if (cap) {
    const size_t copied = source_len < cap - 1 ? source_len : cap - 1;
    memcpy(buf, c->source + s.start, copied);
    size_t written = copied;
    if (suffix && written + 1 < cap)
      buf[written++] = '_';
    buf[written] = '\0';
  }
  return full_len;
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

// Emit the C enum constant `<Enum>_<Variant>` (raw spans, kept identical at definition and use).
static void emit_tag(Codegen *c, const NodeId enum_decl, const NodeId variant) {
  emit_span(c, name_span(c, ast_at_const(c->ast, enum_decl)->as.aggregate.name));
  emit(c, "_");
  emit_span(c, name_span(c, ast_at_const(c->ast, variant)->as.variant.name));
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
      const NodeId d = ast_resolution(c->ast, tn);
      if (d != NODE_NONE) {
        const Node *const dn = ast_at_const(c->ast, d);
        if (dn->kind == NODE_STRUCT || dn->kind == NODE_ENUM) {
          char nm[128];
          render_ident(c, name_span(c, dn->as.aggregate.name), nm, sizeof nm);
          buf_join3(out, cap, nm, SEP(decl), decl);
        } else if (dn->kind == NODE_TYPE_ALIAS) {
          render_type_node(c, dn->as.type_alias.type, decl, out, cap); // transparent
        } else {
          codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: generic or opaque type is not yet supported");
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
      char nm[128];
      render_ident(c, name_span(c, ast_at_const(c->ast, ty->as.decl)->as.aggregate.name), nm, sizeof nm);
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

// Does `t` carry a writable (`*mut`) address -- directly, or through a struct field or array/slice
// element? Such a value owns mutable state, so a `let` binding of it must NOT be const-qualified in C:
// `const` would lock the owned pointer and reject the value's `&mut self` methods (e.g. `deinit`).
// Stops at the first pointer/reference (a `*const`/`*mut` to a struct doesn't recurse into the pointee).
static bool type_owns_mut(Codegen *c, const TypeId t) {
  const Ty *const ty = ast_type_at(c->ast, t);
  switch (ty->kind) {
    case TYPE_POINTER:
    case TYPE_REFERENCE:
      return ty->qualifier == TYPE_QUAL_MUT;
    case TYPE_ARRAY:
    case TYPE_SLICE:
      return type_owns_mut(c, ty->as.elem);
    case TYPE_STRUCT: {
      const NodeList members = ast_at_const(c->ast, ty->as.decl)->as.aggregate.members;
      const NodeId *const ids = ast_list(c->ast, members);
      for (uint32_t i = 0; i < members.len; i++) {
        const Node *const m = ast_at_const(c->ast, ids[i]);
        if (m->kind == NODE_FIELD && type_owns_mut(c, ast_type(c->ast, m->as.field.type)))
          return true;
      }
      return false;
    }
    default:
      return false;
  }
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
static void emit_variant_value(Codegen *c, const NodeId variant) {
  const NodeId en = enclosing_enum(c, variant);
  if (en == NODE_NONE) {
    emit(c, "0");
    return;
  }
  if (!aggregate_has_payload(c, ast_at_const(c->ast, en))) {
    emit_tag(c, en, variant);
    return;
  }
  char enm[128];
  render_ident(c, name_span(c, ast_at_const(c->ast, en)->as.aggregate.name), enm, sizeof enm);
  emit(c, "(%s){ .tag = ", enm);
  emit_tag(c, en, variant);
  emit(c, " }");
}

// Emit `Enum::Variant(args)` construction as a tagged-union compound literal.
static void emit_variant_construct(Codegen *c, const NodeId variant, const NodeList args, const NodeId *const aids) {
  const NodeId en = enclosing_enum(c, variant);
  if (en == NODE_NONE || !aggregate_has_payload(c, ast_at_const(c->ast, en))) {
    emit_variant_value(c, variant); // payload-less: ignore (absent) args, emit the tag
    return;
  }
  char enm[128], vn[128];
  render_ident(c, name_span(c, ast_at_const(c->ast, en)->as.aggregate.name), enm, sizeof enm);
  render_ident(c, name_span(c, ast_at_const(c->ast, variant)->as.variant.name), vn, sizeof vn);
  emit(c, "(%s){ .tag = ", enm);
  emit_tag(c, en, variant);
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

static void emit_call(Codegen *c, const Node *n) {
  const NodeId callee_id = n->as.call.callee;
  const Node *const callee = ast_at_const(c->ast, callee_id);
  const NodeList args = n->as.call.args;
  const NodeId *const aids = ast_list(c->ast, args);

  if (callee->kind == NODE_MEMBER && callee->as.member.path) { // Enum::Variant(args)
    const NodeId member = ast_resolution(c->ast, callee->as.member.member);
    if (member != NODE_NONE && ast_at_const(c->ast, member)->kind == NODE_VARIANT) {
      emit_variant_construct(c, member, args, aids);
      return;
    }
    if (member != NODE_NONE && ast_at_const(c->ast, member)->kind == NODE_FUNCTION) {
      const NodeId target = ast_resolution(c->ast, callee->as.member.object);
      if (target == NODE_NONE) {
        codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: associated method target is unresolved");
      } else {
        emit_ident(c, name_span(c, ast_at_const(c->ast, target)->as.aggregate.name));
        emit(c, "__");
      }
      emit_ident(c, name_span(c, callee->as.member.member));
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
    const NodeId method = ast_resolution(c->ast, callee->as.member.member);
    if (method != NODE_NONE && ast_at_const(c->ast, method)->kind == NODE_FUNCTION) {
      const NodeId obj = callee->as.member.object;
      const TypeId obj_t = ast_type(c->ast, obj);
      const Ty *const base = ast_type_at(c->ast, strip_ptr(c, obj_t));
      if (base->kind == TYPE_STRUCT || base->kind == TYPE_ENUM) {
        emit_ident(c, name_span(c, ast_at_const(c->ast, base->as.decl)->as.aggregate.name));
        emit(c, "__");
      } else {
        codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: method receiver is not a struct or enum");
      }
      emit_ident(c, name_span(c, callee->as.member.member));
      emit(c, "(");

      const NodeList params = ast_at_const(c->ast, method)->as.function.params;
      bool wrote = false;
      if (params.len > 0) { // bind the receiver to the implicit self parameter
        const Ty *const self = ast_type_at(c->ast, ast_type(c->ast, ast_list(c->ast, params)[0]));
        const Ty *const ot = ast_type_at(c->ast, obj_t);
        const bool self_ptr = self->kind == TYPE_POINTER || self->kind == TYPE_REFERENCE;
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

static void emit_ident_ref(Codegen *c, const NodeId id, const Node *n) {
  const NodeId d = ast_resolution(c->ast, id);
  if (d != NODE_NONE && ast_at_const(c->ast, d)->kind == NODE_VARIANT) {
    const NodeId en = enclosing_enum(c, d);
    if (en != NODE_NONE) {
      emit_tag(c, en, d);
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
      emit_call(c, n);
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
      if (n->as.member.path) { // Enum::Variant used as a value
        emit_variant_value(c, ast_resolution(c->ast, n->as.member.member));
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
      // catch-all binding that matches anything.
      const NodeId vd = ast_resolution(c->ast, p->as.pattern.name);
      if (vd != NODE_NONE && ast_at_const(c->ast, vd)->kind == NODE_VARIANT) {
        const NodeId en = enclosing_enum(c, vd);
        const bool payload = en != NODE_NONE && aggregate_has_payload(c, ast_at_const(c->ast, en));
        emit(c, payload ? "%s.tag == " : "%s == ", scrut);
        if (en != NODE_NONE)
          emit_tag(c, en, vd);
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
      const NodeId vd = p->as.pattern.name != NODE_NONE ? ast_resolution(c->ast, p->as.pattern.name) : NODE_NONE;
      const NodeList ch = p->as.pattern.children;
      const NodeId *const ids = ast_list(c->ast, ch);
      if (vd != NODE_NONE && ast_at_const(c->ast, vd)->kind == NODE_VARIANT) {
        const NodeId en = enclosing_enum(c, vd);
        // A payload-bearing enum is a tagged union (test `.tag`); a payload-less one is a plain
        // C enum whose value is the tag itself.
        const bool payload = en != NODE_NONE && aggregate_has_payload(c, ast_at_const(c->ast, en));
        emit(c, payload ? "%s.tag == " : "%s == ", scrut);
        if (en != NODE_NONE)
          emit_tag(c, en, vd);
        else
          emit(c, "0");
        char vn[128];
        render_ident(c, name_span(c, ast_at_const(c->ast, vd)->as.variant.name), vn, sizeof vn);
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
      const NodeId vd = ast_resolution(c->ast, p->as.pattern.name);
      if (vd != NODE_NONE && ast_at_const(c->ast, vd)->kind == NODE_VARIANT)
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
      const NodeId vd = p->as.pattern.name != NODE_NONE ? ast_resolution(c->ast, p->as.pattern.name) : NODE_NONE;
      const NodeList ch = p->as.pattern.children;
      const NodeId *const ids = ast_list(c->ast, ch);
      char vn[128] = "";
      if (vd != NODE_NONE && ast_at_const(c->ast, vd)->kind == NODE_VARIANT)
        render_ident(c, name_span(c, ast_at_const(c->ast, vd)->as.variant.name), vn, sizeof vn);
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

// Build a function's C name: `name`, or `Target__name` for an impl method.
static void function_name(Codegen *c, const NodeId fn, const NodeId target, char *out, const size_t cap) {
  size_t k = 0;
  if (target != NODE_NONE) {
    k = render_ident(c, name_span(c, ast_at_const(c->ast, target)->as.aggregate.name), out, cap);
    if (k >= cap)
      k = cap ? cap - 1 : 0;
    if (k + 2 < cap) {
      out[k++] = '_';
      out[k++] = '_';
    }
  }
  render_ident(c, name_span(c, ast_at_const(c->ast, fn)->as.function.name), out + k, cap - k);
}

// Emit a function signature; with_body emits the block, otherwise a prototype `;`. `extern_q`
// prefixes `extern`. Sets current_ret for multi-return so NODE_RETURN can build the struct.
static void emit_function(Codegen *c, const NodeId fn_id, const NodeId target, const bool extern_q, const bool with_body) {
  const Node *const fn = ast_at_const(c->ast, fn_id);
  char nm[256];
  function_name(c, fn_id, target, nm, sizeof nm);
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

  const NodeList rets = fn->as.function.returns;
  c->current_ret[0] = '\0';
  // C requires `int main(void)`; a Super-C `fn main() i32` maps onto it (implicit 0 on fall-through).
  if (target == NODE_NONE && !extern_q && span_is(c->source, name_span(c, fn->as.function.name), "main")) {
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

// Emit the `<fn>_ret` struct backing a multi-return function (fields `_0`, `_1`, …).
static void emit_ret_struct(Codegen *c, const NodeId fn_id, const NodeId target) {
  const Node *const fn = ast_at_const(c->ast, fn_id);
  const NodeList rets = fn->as.function.returns;
  if (rets.len <= 1)
    return;
  char nm[256];
  function_name(c, fn_id, target, nm, sizeof nm);
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

static bool aggregate_has_payload(Codegen *c, const Node *enum_node) {
  const NodeList members = enum_node->as.aggregate.members;
  const NodeId *const ids = ast_list(c->ast, members);
  for (uint32_t i = 0; i < members.len; i++)
    if (ast_at_const(c->ast, ids[i])->as.variant.payload.len > 0)
      return true;
  return false;
}

static NodeList program_items(Codegen *c) {
  return ast_at_const(c->ast, c->ast->root)->as.program.items;
}

// Phase 1: forward typedefs so any type can name any struct/payload-enum regardless of order.
// Payload-less enums are self-contained, so they are emitted in full here.
static void phase_forward(Codegen *c) {
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (n->kind == NODE_STRUCT) {
      if (n->as.aggregate.generics.len) {
        codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: generic struct is not yet supported");
        continue;
      }
      emit(c, "typedef struct ");
      emit_ident(c, name_span(c, n->as.aggregate.name));
      emit(c, " ");
      emit_ident(c, name_span(c, n->as.aggregate.name));
      emit(c, ";\n");
    } else if (n->kind == NODE_ENUM) {
      if (n->as.aggregate.generics.len) {
        codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: generic enum is not yet supported");
        continue;
      }
      const NodeList ms = n->as.aggregate.members;
      const NodeId *const mids = ast_list(c->ast, ms);
      const bool payload = aggregate_has_payload(c, n);
      emit(c, "typedef enum { ");
      for (uint32_t j = 0; j < ms.len; j++) {
        if (j)
          emit(c, ", ");
        emit_tag(c, ids[i], mids[j]);
        const NodeId disc = ast_at_const(c->ast, mids[j])->as.variant.value;
        if (disc != NODE_NONE) { // explicit discriminant `= <int>`
          emit(c, " = ");
          emit_expr(c, disc);
        }
      }
      emit(c, " } ");
      emit_ident(c, name_span(c, n->as.aggregate.name));
      if (payload)
        emit(c, "Tag");
      emit(c, ";\n");
      if (payload) {
        emit(c, "typedef struct ");
        emit_ident(c, name_span(c, n->as.aggregate.name));
        emit(c, " ");
        emit_ident(c, name_span(c, n->as.aggregate.name));
        emit(c, ";\n");
      }
    }
  }
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
      emit_ident(c, name_span(c, n->as.aggregate.name));
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
      const NodeList ms = n->as.aggregate.members;
      const NodeId *const mids = ast_list(c->ast, ms);
      emit(c, "struct ");
      emit_ident(c, name_span(c, n->as.aggregate.name));
      emit(c, " {\n");
      c->depth++;
      emit_indent(c);
      emit_ident(c, name_span(c, n->as.aggregate.name));
      emit(c, "Tag tag;\n");
      emit_indent(c);
      emit(c, "union {\n");
      c->depth++;
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
      emit(c, "};\n");
    }
  }
}

// Multi-return structs, after all type definitions (they reference parameter/return types).
static void phase_ret_structs(Codegen *c) {
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (n->kind == NODE_FUNCTION && !n->as.function.generics.len) {
      emit_ret_struct(c, ids[i], NODE_NONE);
    } else if (n->kind == NODE_IMPL && !n->as.impl_def.generics.len) {
      const NodeId target = ast_resolution(c->ast, n->as.impl_def.target_type);
      const NodeList ms = n->as.impl_def.items;
      const NodeId *const mids = ast_list(c->ast, ms);
      for (uint32_t j = 0; j < ms.len; j++)
        if (ast_at_const(c->ast, mids[j])->kind == NODE_FUNCTION)
          emit_ret_struct(c, mids[j], target);
    }
  }
}

// Phase 3: prototypes for every top-level function, impl method and extern function.
static void phase_prototypes(Codegen *c) {
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (n->kind == NODE_FUNCTION) {
      if (n->as.function.generics.len) {
        codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: generic function is not yet supported");
        continue;
      }
      emit_function(c, ids[i], NODE_NONE, false, false);
    } else if (n->kind == NODE_IMPL) {
      if (n->as.impl_def.generics.len) {
        codegen_errorf(c, n->span.start, n->span.end - n->span.start, "codegen: generic impl is not yet supported");
        continue;
      }
      const NodeId target = ast_resolution(c->ast, n->as.impl_def.target_type);
      const NodeList ms = n->as.impl_def.items;
      const NodeId *const mids = ast_list(c->ast, ms);
      for (uint32_t j = 0; j < ms.len; j++)
        if (ast_at_const(c->ast, mids[j])->kind == NODE_FUNCTION)
          emit_function(c, mids[j], target, false, false);
    } else if (n->kind == NODE_EXTERN_BLOCK) {
      const NodeList ms = n->as.extern_block.items;
      const NodeId *const mids = ast_list(c->ast, ms);
      for (uint32_t j = 0; j < ms.len; j++)
        if (ast_at_const(c->ast, mids[j])->kind == NODE_FUNCTION && !ast_at_const(c->ast, mids[j])->as.function.generics.len)
          emit_function(c, mids[j], NODE_NONE, true, false);
    }
  }
}

// Phase 4: top-level consts, then function / method bodies.
static void phase_bodies(Codegen *c) {
  const NodeList items = program_items(c);
  const NodeId *const ids = ast_list(c->ast, items);
  for (uint32_t i = 0; i < items.len; i++)
    if (ast_at_const(c->ast, ids[i])->kind == NODE_CONST)
      emit_stmt(c, ids[i]);

  for (uint32_t i = 0; i < items.len; i++) {
    const Node *const n = ast_at_const(c->ast, ids[i]);
    if (n->kind == NODE_FUNCTION && !n->as.function.generics.len && n->as.function.body != NODE_NONE) {
      emit_function(c, ids[i], NODE_NONE, false, true);
    } else if (n->kind == NODE_IMPL && !n->as.impl_def.generics.len) {
      const NodeId target = ast_resolution(c->ast, n->as.impl_def.target_type);
      const NodeList ms = n->as.impl_def.items;
      const NodeId *const mids = ast_list(c->ast, ms);
      for (uint32_t j = 0; j < ms.len; j++)
        if (ast_at_const(c->ast, mids[j])->kind == NODE_FUNCTION && ast_at_const(c->ast, mids[j])->as.function.body != NODE_NONE)
          emit_function(c, mids[j], target, false, true);
    }
  }
}

void codegen_emit(Codegen *c, FILE *out) {
  build_enum_index(c);
  emit(c, "#include <stdint.h>\n#include <stdbool.h>\n#include <stdlib.h>\n#include <string.h>\n\n");
  emit(c, "typedef struct { void *ptr; size_t len; } SCslice;\n");
  emit(c, "typedef struct { const uint8_t *ptr; size_t len; } str;\n\n");
  phase_forward(c);
  emit(c, "\n");
  phase_types(c);
  phase_ret_structs(c);
  emit(c, "\n");
  phase_prototypes(c);
  emit(c, "\n");
  phase_bodies(c);
  errors_finalize(&c->errors, &c->errors_start, &c->errors_len, c->source, c->len);
  if (c->buf_len)
    fwrite(c->buf, 1, c->buf_len, out);
}

ERRORS_BODY(Codegen, codegen, c)
