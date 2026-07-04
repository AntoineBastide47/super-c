#include "ast.h"

#include <stdlib.h>
#include <string.h>

#include "utils/errors.h"

VEC_DEFINE(Node, Node_Vec)
VEC_DEFINE(Ty, Ty_Vec)
VEC_DEFINE(DefId, DefId_Vec)
VEC_DEFINE(TyInstance, TyInstance_Vec)
VEC_DEFINE(MonoUse, MonoUse_Vec)
VEC_DEFINE(MethodInst, MethodInst_Vec)
VEC_DEFINE(DynUse, DynUse_Vec)
VEC_DEFINE(Attr, Attr_Vec)

// FNV-1a over the padding-free bytes of Ty; equality is the same memcmp the pool already relied on.
static inline size_t ty_hash(const Ty t) {
  const unsigned char *const p = (const unsigned char *)&t;
  size_t h = 1469598103934665603ull;
  for (size_t i = 0; i < sizeof t; i++) {
    h ^= p[i];
    h *= 1099511628211ull;
  }
  return h;
}
static inline bool ty_eq(const Ty a, const Ty b) {
  return memcmp(&a, &b, sizeof a) == 0;
}
HM_DEFINE(Ty, TypeId, TyMap, ty_hash, ty_eq)

Ast *ast_new(const size_t token_count) {
  Ast *const a = calloc(1, sizeof *a);
  if (!a)
    oom();
  a->nodes = Node_Vec_init();
  a->children = U32_Vec_init();
  a->scratch = U32_Vec_init();
  a->resolutions = DefId_Vec_init();
  a->type_pool = Ty_Vec_init();
  a->types = U32_Vec_init();
  a->mono = MonoUse_Vec_init();
  a->mono_at = U32_Vec_init();
  a->instances = TyInstance_Vec_init();
  a->method_insts = MethodInst_Vec_init();
  a->dyn_uses = DynUse_Vec_init();
  a->dyn_at = U32_Vec_init();
  a->attrs = Attr_Vec_init();
  Node_Vec_reserve(&a->nodes, token_count);
  U32_Vec_reserve(&a->children, token_count / 2);
  Node_Vec_push(&a->nodes, (Node){.kind = NODE_NONE_KIND});
  return a;
}

void ast_free(Ast **a) {
  if (!a || !*a)
    return;
  VEC_DEINIT((*a)->nodes);
  VEC_DEINIT((*a)->children);
  VEC_DEINIT((*a)->scratch);
  VEC_DEINIT((*a)->resolutions);
  VEC_DEINIT((*a)->type_pool);
  TyMap_deinit(&(*a)->type_index);
  VEC_DEINIT((*a)->types);
  VEC_DEINIT((*a)->mono);
  VEC_DEINIT((*a)->mono_at);
  VEC_DEINIT((*a)->instances);
  VEC_DEINIT((*a)->method_insts);
  VEC_DEINIT((*a)->dyn_uses);
  VEC_DEINIT((*a)->dyn_at);
  VEC_DEINIT((*a)->attrs);
  free(*a);
  *a = NULL;
}

TypeId ast_intern_instance(Ast *a, const ModuleId module, const NodeId decl, const TypeId *const args,
                           const uint8_t n) {
  const uint8_t m = n > 4 ? 4 : n;
  uint32_t idx = (uint32_t)a->instances.len;
  for (size_t i = 0; i < a->instances.len; i++) { // dedup so equal applications share an index
    const TyInstance *const it = &a->instances.data[i];
    if (it->module != module || it->decl != decl || it->n != m)
      continue;
    bool same = true;
    for (uint8_t j = 0; j < m; j++)
      if (it->args[j] != args[j]) {
        same = false;
        break;
      }
    if (same) {
      idx = (uint32_t)i;
      break;
    }
  }
  if (idx == a->instances.len) {
    TyInstance it = {.module = module, .decl = decl, .n = m};
    for (uint8_t j = 0; j < m; j++)
      it.args[j] = args[j];
    TyInstance_Vec_push(&a->instances, it);
  }
  return ast_intern_type(a, (Ty){.kind = TYPE_INSTANCE, .module = module, .as.inst = idx});
}

const TyInstance *ast_instance(const Ast *a, const uint32_t index) {
  return &a->instances.data[index];
}

bool ast_add_method_inst(Ast *a, const TypeId instance, const NodeId method, const TypeId *const targs,
                         const uint8_t n) {
  const uint8_t m = n > 4 ? 4 : n;
  for (size_t i = 0; i < a->method_insts.len; i++) { // dedup: same instance + method + targs -> once
    const MethodInst *const mi = &a->method_insts.data[i];
    if (mi->instance != instance || mi->method != method || mi->n != m)
      continue;
    bool same = true;
    for (uint8_t j = 0; j < m; j++)
      if (mi->targs[j] != targs[j]) {
        same = false;
        break;
      }
    if (same)
      return false;
  }
  MethodInst mi = {.instance = instance, .method = method, .n = m};
  for (uint8_t j = 0; j < m; j++)
    mi.targs[j] = targs[j];
  MethodInst_Vec_push(&a->method_insts, mi);
  return true;
}

void ast_add_attr(Ast *a, const Attr attr) {
  Attr_Vec_push(&a->attrs, attr);
}

TypeId ast_reintern(Ast *dst, const Ast *src, const TypeId t) {
  if (t == TYPE_NONE || dst == src)
    return t;
  const Ty ty = *ast_type_at(src, t);
  switch (ty.kind) {
    case TYPE_POINTER:
    case TYPE_REFERENCE:
    case TYPE_SLICE:
    case TYPE_ARRAY: {
      Ty nt = ty;
      nt.as.elem = ast_reintern(dst, src, ty.as.elem);
      return ast_intern_type(dst, nt);
    }
    case TYPE_INSTANCE: {
      const TyInstance inst = *ast_instance(src, ty.as.inst);
      TypeId na[4];
      for (uint8_t i = 0; i < inst.n; i++)
        na[i] = ast_reintern(dst, src, inst.args[i]);
      return ast_intern_instance(dst, inst.module, inst.decl, na, inst.n);
    }
    default: // BUILTIN/STRUCT/ENUM/FUNCTION/GENERIC: identity (module+decl) is carried in the Ty itself
      return ast_intern_type(dst, ty);
  }
}

bool ast_type_concrete(const Ast *a, const TypeId t) {
  const Ty *const ty = ast_type_at(a, t);
  switch (ty->kind) {
    case TYPE_GENERIC:
      return false;
    case TYPE_POINTER:
    case TYPE_REFERENCE:
    case TYPE_SLICE:
    case TYPE_ARRAY:
      return ast_type_concrete(a, ty->as.elem);
    case TYPE_INSTANCE: {
      const TyInstance *const it = ast_instance(a, ty->as.inst);
      for (uint8_t i = 0; i < it->n; i++)
        if (!ast_type_concrete(a, it->args[i]))
          return false;
      return true;
    }
    default:
      return true;
  }
}

void ast_set_type_args(Ast *a, const NodeId node, const TypeId *const args, const uint8_t n) {
  MonoUse u = {.node = node, .n = n > 4 ? 4 : n};
  for (uint8_t i = 0; i < u.n; i++)
    u.args[i] = args[i];
  MonoUse_Vec_push(&a->mono, u);
  if (a->mono_at.len <= node) { // grow the node->mono index to cover this (and the final) node count, zeroed
    const size_t old = a->mono_at.len, want = a->nodes.len > (size_t)node + 1 ? a->nodes.len : (size_t)node + 1;
    U32_Vec_reserve(&a->mono_at, want);
    memset(a->mono_at.data + old, 0, (want - old) * sizeof *a->mono_at.data);
    a->mono_at.len = want;
  }
  a->mono_at.data[node] = (uint32_t)a->mono.len; // 1-based; a later record for `node` overwrites -> latest wins
}

const MonoUse *ast_type_args(const Ast *a, const NodeId node) {
  if (node >= a->mono_at.len)
    return NULL;
  const uint32_t idx = a->mono_at.data[node];
  return idx ? &a->mono.data[idx - 1] : NULL;
}

void ast_add_dyn_use(Ast *a, const NodeId node, const TypeId src, const TypeId dyn) {
  DynUse_Vec_push(&a->dyn_uses, (DynUse){.node = node, .src = src, .dyn = dyn});
  if (a->dyn_at.len <= node) {
    const size_t old = a->dyn_at.len, want = a->nodes.len > (size_t)node + 1 ? a->nodes.len : (size_t)node + 1;
    U32_Vec_reserve(&a->dyn_at, want);
    memset(a->dyn_at.data + old, 0, (want - old) * sizeof *a->dyn_at.data);
    a->dyn_at.len = want;
  }
  a->dyn_at.data[node] = (uint32_t)a->dyn_uses.len; // 1-based; latest record wins
}

const DynUse *ast_dyn_use_at(const Ast *a, const NodeId node) {
  if (node >= a->dyn_at.len)
    return NULL;
  const uint32_t idx = a->dyn_at.data[node];
  return idx ? &a->dyn_uses.data[idx - 1] : NULL;
}

NodeId ast_add(Ast *a, const Node node) {
  const NodeId id = (NodeId)a->nodes.len;
  Node_Vec_push(&a->nodes, node);
  return id;
}

uint32_t ast_mark(const Ast *a) {
  return (uint32_t)a->scratch.len;
}

void ast_push(Ast *a, const NodeId id) {
  U32_Vec_push(&a->scratch, id);
}

NodeList ast_commit(Ast *a, const uint32_t mark) {
  const NodeList list = {(uint32_t)a->children.len, (uint32_t)a->scratch.len - mark};
  for (uint32_t i = mark; i < a->scratch.len; i++)
    U32_Vec_push(&a->children, a->scratch.data[i]);
  a->scratch.len = mark;
  return list;
}

void ast_init_resolutions(Ast *a) {
  DefId_Vec_reserve(&a->resolutions, a->nodes.len);
  a->resolutions.len = a->nodes.len;
  memset(a->resolutions.data, 0, a->nodes.len * sizeof *a->resolutions.data); // all-zero DefId = unresolved
}

void ast_init_types(Ast *a) {
  U32_Vec_reserve(&a->types, a->nodes.len);
  a->types.len = a->nodes.len;
  memset(a->types.data, TYPE_NONE, a->nodes.len * sizeof *a->types.data);
  a->type_pool.len = 0;
  TyMap_deinit(&a->type_index); // re-seed the index cleanly if init runs more than once
  Ty_Vec_push(&a->type_pool, (Ty){.kind = TYPE_ERROR}); // index 0 == TYPE_NONE
  TyMap_insert(&a->type_index, (Ty){.kind = TYPE_ERROR}, 0);
  for (BuiltinType b = 0; b < BT_COUNT; b++) { // indices 1..BT_COUNT
    const Ty t = {.kind = TYPE_BUILTIN, .as.builtin = b};
    Ty_Vec_push(&a->type_pool, t);
    TyMap_insert(&a->type_index, t, (TypeId)(b + 1));
  }
}

TypeId ast_intern_type(Ast *a, const Ty t) {
  TypeId id;
  if (TyMap_get(&a->type_index, t, &id))
    return id;
  id = (TypeId)a->type_pool.len;
  Ty_Vec_push(&a->type_pool, t);
  TyMap_insert(&a->type_index, t, id);
  return id;
}

BuiltinType ast_numeric_suffix(const uint8_t *src, const uint32_t start, const uint32_t end, uint32_t *sfx_start) {
  static const struct {
      char s[6];
      uint8_t len, bt;
  } SFX[] = {
      {"isize", 5, BT_ISIZE}, {"usize", 5, BT_USIZE}, {"i16", 3, BT_I16}, {"i32", 3, BT_I32},
      {"i64", 3, BT_I64},     {"u16", 3, BT_U16},     {"u32", 3, BT_U32}, {"u64", 3, BT_U64},
      {"f32", 3, BT_F32},     {"f64", 3, BT_F64},     {"i8", 2, BT_I8},   {"u8", 2, BT_U8},
  };
  const bool hex = end - start > 2 && src[start] == '0' && (src[start + 1] | 0x20) == 'x';
  for (size_t k = 0; k < sizeof SFX / sizeof *SFX; k++) {
    const uint32_t n = SFX[k].len;
    if (end - start <= n || memcmp(src + end - n, SFX[k].s, n) != 0)
      continue;
    if (hex && SFX[k].s[0] == 'f')
      continue; // 0x..f32: that 'f' is a hex digit, not a suffix
    if (sfx_start)
      *sfx_start = end - n;
    return (BuiltinType)SFX[k].bt;
  }
  return BT_COUNT;
}

#ifdef NDEBUG
static const char *kind_name(const NodeKind kind) {
  static const char *const names[] = {
      "None",
      "Program",
      "Identifier",
      "Literal",
      "Function",
      "Parameter",
      "Struct",
      "Field",
      "Enum",
      "Variant",
      "Interface",
      "Extend",
      "TypeAlias",
      "Const",
      "StaticAssert",
      "ExternBlock",
      "Import",
      "GenericParam",
      "WherePredicate",
      "TypePath",
      "PointerType",
      "ReferenceType",
      "SliceType",
      "ArrayType",
      "FunctionType",
      "DynType",
      "Block",
      "Let",
      "Return",
      "Break",
      "Continue",
      "Defer",
      "If",
      "While",
      "For",
      "ExpressionStatement",
      "Unary",
      "Binary",
      "Assignment",
      "Call",
      "Closure",
      "Index",
      "Member",
      "Cast",
      "GenericSpecialization",
      "Match",
      "MatchArm",
      "New",
      "Sizeof",
      "Alignof",
      "VaExpr",
      "ArrayLiteral",
      "StructInitializer",
      "FieldInitializer",
      "PatternWildcard",
      "PatternLiteral",
      "PatternName",
      "PatternTuple",
      "PatternStruct",
      "PatternField",
      "PatternRange",
      "PatternOr",
      "Range",
      "Tuple",
      "TupleType",
  };
  _Static_assert(sizeof names / sizeof names[0] == NODE_KIND_COUNT, "kind_name names[] out of sync with NodeKind");
  return (unsigned)kind < sizeof names / sizeof names[0] ? names[kind] : "Invalid";
}

static void indent(FILE *out, const unsigned depth) {
  for (unsigned i = 0; i < depth; i++)
    fputs("  ", out);
}

static void print_node(FILE *out, const Ast *a, const NodeId id, const char *source, const unsigned depth);

static void print_list(FILE *out, const Ast *a, const NodeList list, const char *source, const unsigned depth) {
  const NodeId *const ids = ast_list(a, list);
  for (uint32_t i = 0; i < list.len; i++)
    print_node(out, a, ids[i], source, depth);
}

static void print_child(FILE *out, const Ast *a, const NodeId id, const char *source, const unsigned depth) {
  if (id != NODE_NONE)
    print_node(out, a, id, source, depth);
}

static void print_node(FILE *out, const Ast *a, const NodeId id, const char *source, const unsigned depth) {
  const Node *const n = ast_at_const(a, id);
  indent(out, depth);
  fprintf(out, "%s", kind_name(n->kind));
  if (n->kind == NODE_IDENTIFIER) {
    fprintf(out, " `%.*s`", (int)(n->as.name.text.end - n->as.name.text.start), source + n->as.name.text.start);
  } else if (n->kind == NODE_LITERAL) {
    fprintf(out, " %.*s", (int)(n->as.literal.raw.end - n->as.literal.raw.start), source + n->as.literal.raw.start);
  } else if (n->kind == NODE_UNARY || n->kind == NODE_BINARY || n->kind == NODE_ASSIGNMENT) {
    fprintf(out, " %s", token_type_name(n->kind == NODE_UNARY ? n->as.unary.op : n->as.binary.op));
  }
  fprintf(out, " [%u..%u]\n", n->span.start, n->span.end);

  switch (n->kind) {
    case NODE_PROGRAM:
      print_list(out, a, n->as.program.items, source, depth + 1);
      break;
    case NODE_FUNCTION:
      print_child(out, a, n->as.function.name, source, depth + 1);
      print_list(out, a, n->as.function.generics, source, depth + 1);
      print_list(out, a, n->as.function.params, source, depth + 1);
      print_list(out, a, n->as.function.returns, source, depth + 1);
      print_list(out, a, n->as.function.where_clause, source, depth + 1);
      print_child(out, a, n->as.function.body, source, depth + 1);
      break;
    case NODE_PARAMETER:
      print_child(out, a, n->as.parameter.name, source, depth + 1);
      print_child(out, a, n->as.parameter.type, source, depth + 1);
      break;
    case NODE_FIELD:
      print_child(out, a, n->as.field.name, source, depth + 1);
      print_child(out, a, n->as.field.type, source, depth + 1);
      print_child(out, a, n->as.field.value, source, depth + 1);
      break;
    case NODE_STRUCT:
    case NODE_ENUM:
      print_child(out, a, n->as.aggregate.name, source, depth + 1);
      print_list(out, a, n->as.aggregate.generics, source, depth + 1);
      print_list(out, a, n->as.aggregate.members, source, depth + 1);
      break;
    case NODE_VARIANT:
      print_child(out, a, n->as.variant.name, source, depth + 1);
      print_list(out, a, n->as.variant.payload, source, depth + 1);
      break;
    case NODE_INTERFACE:
      print_child(out, a, n->as.interface_def.name, source, depth + 1);
      print_list(out, a, n->as.interface_def.generics, source, depth + 1);
      print_list(out, a, n->as.interface_def.bounds, source, depth + 1);
      print_list(out, a, n->as.interface_def.items, source, depth + 1);
      break;
    case NODE_EXTEND:
      print_list(out, a, n->as.extend_def.generics, source, depth + 1);
      print_child(out, a, n->as.extend_def.interface_type, source, depth + 1);
      print_child(out, a, n->as.extend_def.target_type, source, depth + 1);
      print_list(out, a, n->as.extend_def.items, source, depth + 1);
      break;
    case NODE_TYPE_ALIAS:
      print_child(out, a, n->as.type_alias.name, source, depth + 1);
      print_list(out, a, n->as.type_alias.generics, source, depth + 1);
      print_child(out, a, n->as.type_alias.type, source, depth + 1);
      break;
    case NODE_CONST:
      print_child(out, a, n->as.const_def.name, source, depth + 1);
      print_child(out, a, n->as.const_def.type, source, depth + 1);
      print_child(out, a, n->as.const_def.value, source, depth + 1);
      break;
    case NODE_EXTERN_BLOCK:
      print_child(out, a, n->as.extern_block.abi, source, depth + 1);
      print_list(out, a, n->as.extern_block.items, source, depth + 1);
      break;
    case NODE_IMPORT:
      print_list(out, a, n->as.import_decl.path, source, depth + 1);
      print_child(out, a, n->as.import_decl.alias, source, depth + 1);
      break;
    case NODE_GENERIC_PARAM:
      print_child(out, a, n->as.generic_param.name, source, depth + 1);
      print_list(out, a, n->as.generic_param.bounds, source, depth + 1);
      print_child(out, a, n->as.generic_param.default_type, source, depth + 1);
      break;
    case NODE_WHERE_PREDICATE:
      print_child(out, a, n->as.where_predicate.type, source, depth + 1);
      print_list(out, a, n->as.where_predicate.bounds, source, depth + 1);
      break;
    case NODE_TYPE_PATH:
      print_list(out, a, n->as.type_path.parts, source, depth + 1);
      print_list(out, a, n->as.type_path.args, source, depth + 1);
      break;
    case NODE_POINTER_TYPE:
    case NODE_REFERENCE_TYPE:
    case NODE_SLICE_TYPE:
    case NODE_DYN_TYPE:
      print_child(out, a, n->as.indirect_type.type, source, depth + 1);
      break;
    case NODE_ARRAY_TYPE:
      print_child(out, a, n->as.array_type.element, source, depth + 1);
      print_child(out, a, n->as.array_type.length, source, depth + 1);
      break;
    case NODE_FUNCTION_TYPE:
      print_list(out, a, n->as.function_type.params, source, depth + 1);
      print_list(out, a, n->as.function_type.returns, source, depth + 1);
      break;
    case NODE_BLOCK:
      print_list(out, a, n->as.block.statements, source, depth + 1);
      break;
    case NODE_LET:
      print_child(out, a, n->as.let_stmt.name, source, depth + 1);
      print_child(out, a, n->as.let_stmt.type, source, depth + 1);
      print_child(out, a, n->as.let_stmt.value, source, depth + 1);
      break;
    case NODE_RETURN:
      print_list(out, a, n->as.return_stmt.values, source, depth + 1);
      break;
    case NODE_DEFER:
    case NODE_EXPRESSION_STATEMENT:
      print_child(out, a, n->as.single.value, source, depth + 1);
      break;
    case NODE_IF:
      print_child(out, a, n->as.if_stmt.condition, source, depth + 1);
      print_child(out, a, n->as.if_stmt.then_branch, source, depth + 1);
      print_child(out, a, n->as.if_stmt.else_branch, source, depth + 1);
      break;
    case NODE_WHILE:
      print_child(out, a, n->as.while_stmt.condition, source, depth + 1);
      print_child(out, a, n->as.while_stmt.body, source, depth + 1);
      break;
    case NODE_FOR:
      print_child(out, a, n->as.for_stmt.binding, source, depth + 1);
      print_child(out, a, n->as.for_stmt.iterable, source, depth + 1);
      print_child(out, a, n->as.for_stmt.body, source, depth + 1);
      break;
    case NODE_UNARY:
      print_child(out, a, n->as.unary.operand, source, depth + 1);
      break;
    case NODE_BINARY:
    case NODE_ASSIGNMENT:
    case NODE_STATIC_ASSERT:
      print_child(out, a, n->as.binary.left, source, depth + 1);
      print_child(out, a, n->as.binary.right, source, depth + 1);
      break;
    case NODE_CALL:
      print_child(out, a, n->as.call.callee, source, depth + 1);
      print_list(out, a, n->as.call.args, source, depth + 1);
      break;
    case NODE_CLOSURE:
      print_list(out, a, n->as.closure.params, source, depth + 1);
      print_list(out, a, n->as.closure.returns, source, depth + 1);
      print_child(out, a, n->as.closure.body, source, depth + 1);
      break;
    case NODE_INDEX:
      print_child(out, a, n->as.index.object, source, depth + 1);
      print_child(out, a, n->as.index.index, source, depth + 1);
      break;
    case NODE_MEMBER:
      print_child(out, a, n->as.member.object, source, depth + 1);
      print_child(out, a, n->as.member.member, source, depth + 1);
      break;
    case NODE_CAST:
      print_child(out, a, n->as.cast.expression, source, depth + 1);
      print_child(out, a, n->as.cast.type, source, depth + 1);
      break;
    case NODE_GENERIC_SPECIALIZATION:
      print_child(out, a, n->as.specialization.expression, source, depth + 1);
      print_list(out, a, n->as.specialization.types, source, depth + 1);
      break;
    case NODE_MATCH:
      print_child(out, a, n->as.match_expr.value, source, depth + 1);
      print_list(out, a, n->as.match_expr.arms, source, depth + 1);
      break;
    case NODE_MATCH_ARM:
      print_child(out, a, n->as.match_arm.pattern, source, depth + 1);
      print_child(out, a, n->as.match_arm.guard, source, depth + 1);
      print_child(out, a, n->as.match_arm.body, source, depth + 1);
      break;
    case NODE_NEW:
      print_child(out, a, n->as.new_expr.type, source, depth + 1);
      print_child(out, a, n->as.new_expr.initializer, source, depth + 1);
      break;
    case NODE_VA_EXPR:
      print_child(out, a, n->as.va_op.ap, source, depth + 1);
      print_child(out, a, n->as.va_op.extra, source, depth + 1);
      break;
    case NODE_ARRAY_LITERAL:
    case NODE_TUPLE:
    case NODE_TUPLE_TYPE:
      print_list(out, a, n->as.array_literal.elements, source, depth + 1);
      break;
    case NODE_STRUCT_INITIALIZER:
      print_child(out, a, n->as.struct_initializer.type, source, depth + 1);
      print_list(out, a, n->as.struct_initializer.fields, source, depth + 1);
      break;
    case NODE_FIELD_INITIALIZER:
      print_child(out, a, n->as.field_initializer.name, source, depth + 1);
      print_child(out, a, n->as.field_initializer.value, source, depth + 1);
      break;
    case NODE_PATTERN_NAME:
    case NODE_PATTERN_TUPLE:
    case NODE_PATTERN_STRUCT:
    case NODE_PATTERN_FIELD:
    case NODE_PATTERN_OR:
      print_child(out, a, n->as.pattern.name, source, depth + 1);
      print_list(out, a, n->as.pattern.children, source, depth + 1);
      break;
    case NODE_PATTERN_RANGE:
    case NODE_RANGE:
      print_child(out, a, n->as.pattern_range.start, source, depth + 1);
      print_child(out, a, n->as.pattern_range.end, source, depth + 1);
      break;
    default:
      break;
  }
}

void ast_fprint(FILE *out, const Ast *a, const char *source) {
  if (a && a->root)
    print_node(out, a, a->root, source, 0);
}
#endif
