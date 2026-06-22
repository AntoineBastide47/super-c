#include "ast.h"

#include <stdlib.h>

VEC_DEFINE(Node, Node_Vec)

Ast *ast_new(const size_t token_count) {
  Ast *const a = calloc(1, sizeof *a);
  if (!a) {
    fprintf(stderr, "fatal: out of memory\n");
    abort();
  }
  a->nodes = Node_Vec_init();
  a->children = U32_Vec_init();
  a->scratch = U32_Vec_init();
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
  free(*a);
  *a = NULL;
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
      "Trait",
      "Impl",
      "TypeAlias",
      "Const",
      "ExternBlock",
      "GenericParam",
      "WherePredicate",
      "TypePath",
      "PointerType",
      "ReferenceType",
      "SliceType",
      "ArrayType",
      "FunctionType",
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
      "Index",
      "Member",
      "Cast",
      "GenericSpecialization",
      "Match",
      "MatchArm",
      "New",
      "StructInitializer",
      "FieldInitializer",
      "PatternWildcard",
      "PatternLiteral",
      "PatternName",
      "PatternTuple",
      "PatternStruct",
      "PatternField",
      "PatternRange",
  };
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
    case NODE_TRAIT:
      print_child(out, a, n->as.trait_def.name, source, depth + 1);
      print_list(out, a, n->as.trait_def.generics, source, depth + 1);
      print_list(out, a, n->as.trait_def.bounds, source, depth + 1);
      print_list(out, a, n->as.trait_def.items, source, depth + 1);
      break;
    case NODE_IMPL:
      print_list(out, a, n->as.impl_def.generics, source, depth + 1);
      print_child(out, a, n->as.impl_def.trait_type, source, depth + 1);
      print_child(out, a, n->as.impl_def.target_type, source, depth + 1);
      print_list(out, a, n->as.impl_def.items, source, depth + 1);
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
    case NODE_GENERIC_PARAM:
      print_child(out, a, n->as.generic_param.name, source, depth + 1);
      print_list(out, a, n->as.generic_param.bounds, source, depth + 1);
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
      print_child(out, a, n->as.binary.left, source, depth + 1);
      print_child(out, a, n->as.binary.right, source, depth + 1);
      break;
    case NODE_CALL:
      print_child(out, a, n->as.call.callee, source, depth + 1);
      print_list(out, a, n->as.call.args, source, depth + 1);
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
      print_child(out, a, n->as.pattern.name, source, depth + 1);
      print_list(out, a, n->as.pattern.children, source, depth + 1);
      break;
    case NODE_PATTERN_RANGE:
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
