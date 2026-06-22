#ifndef AST_H
#define AST_H

#include <stdbool.h>
#include <stdio.h>

#include "lexer/token.h"
#include "types/vectors.h"

typedef uint32_t NodeId;
#define NODE_NONE ((NodeId)0)

typedef struct {
    uint32_t start;
    uint32_t len;
} NodeList;

typedef enum {
  TYPE_QUAL_NONE,
  TYPE_QUAL_CONST,
  TYPE_QUAL_MUT,
} TypeQualifier;

typedef enum {
  NODE_NONE_KIND = 0,
  NODE_PROGRAM,
  NODE_IDENTIFIER,
  NODE_LITERAL,

  NODE_FUNCTION,
  NODE_PARAMETER,
  NODE_STRUCT,
  NODE_FIELD,
  NODE_ENUM,
  NODE_VARIANT,
  NODE_TRAIT,
  NODE_IMPL,
  NODE_TYPE_ALIAS,
  NODE_CONST,
  NODE_EXTERN_BLOCK,
  NODE_GENERIC_PARAM,
  NODE_WHERE_PREDICATE,

  NODE_TYPE_PATH,
  NODE_POINTER_TYPE,
  NODE_REFERENCE_TYPE,
  NODE_SLICE_TYPE,
  NODE_ARRAY_TYPE,
  NODE_FUNCTION_TYPE,

  NODE_BLOCK,
  NODE_LET,
  NODE_RETURN,
  NODE_BREAK,
  NODE_CONTINUE,
  NODE_DEFER,
  NODE_IF,
  NODE_WHILE,
  NODE_FOR,
  NODE_EXPRESSION_STATEMENT,

  NODE_UNARY,
  NODE_BINARY,
  NODE_ASSIGNMENT,
  NODE_CALL,
  NODE_INDEX,
  NODE_MEMBER,
  NODE_CAST,
  NODE_GENERIC_SPECIALIZATION,
  NODE_MATCH,
  NODE_MATCH_ARM,
  NODE_NEW,
  NODE_STRUCT_INITIALIZER,
  NODE_FIELD_INITIALIZER,

  NODE_PATTERN_WILDCARD,
  NODE_PATTERN_LITERAL,
  NODE_PATTERN_NAME,
  NODE_PATTERN_TUPLE,
  NODE_PATTERN_STRUCT,
  NODE_PATTERN_FIELD,
  NODE_PATTERN_RANGE,

  NODE_KIND_COUNT,
} NodeKind;

typedef struct {
    NodeKind kind;
    Span span;
    union {
        struct {
            NodeList items;
        } program;
        struct {
            Span text;
        } name;
        struct {
            Span raw;
            TokenType token_type;
        } literal;

        struct {
            NodeId name;
            NodeList generics;
            NodeList params;
            NodeList returns;
            NodeList where_clause;
            NodeId body;
        } function;
        struct {
            NodeId name, type;
        } parameter;
        struct {
            NodeId name;
            NodeList generics, members;
        } aggregate;
        struct {
            NodeId name, type, value;
        } field;
        struct {
            NodeId name;
            NodeList payload;
            bool struct_payload;
        } variant;
        struct {
            NodeId name;
            NodeList generics, bounds, items;
        } trait_def;
        struct {
            NodeList generics;
            NodeId trait_type, target_type;
            NodeList items;
        } impl_def;
        struct {
            NodeId name;
            NodeList generics;
            NodeId type;
        } type_alias;
        struct {
            NodeId name, type, value;
        } const_def;
        struct {
            NodeId abi;
            NodeList items;
        } extern_block;
        struct {
            NodeId name;
            NodeList bounds;
        } generic_param;
        struct {
            NodeId type;
            NodeList bounds;
        } where_predicate;

        struct {
            NodeList parts, args;
        } type_path;
        struct {
            NodeId type;
            TypeQualifier qualifier;
        } indirect_type;
        struct {
            NodeId element, length;
        } array_type;
        struct {
            NodeList params;
            NodeList returns;
        } function_type;

        struct {
            NodeList statements;
        } block;
        struct {
            NodeId name, type, value;
            bool is_mutable;
        } let_stmt;
        struct {
            NodeId value;
        } single;
        struct {
            NodeList values;
        } return_stmt;
        struct {
            NodeId condition, then_branch, else_branch;
        } if_stmt;
        struct {
            NodeId condition, body;
        } while_stmt;
        struct {
            NodeId binding, iterable, body;
        } for_stmt;

        struct {
            TokenType op;
            NodeId operand;
        } unary;
        struct {
            TokenType op;
            NodeId left, right;
        } binary;
        struct {
            NodeId callee;
            NodeList args;
        } call;
        struct {
            NodeId object, index;
        } index;
        struct {
            NodeId object, member;
            bool pointer;
        } member;
        struct {
            NodeId expression, type;
        } cast;
        struct {
            NodeId expression;
            NodeList types;
        } specialization;
        struct {
            NodeId value;
            NodeList arms;
        } match_expr;
        struct {
            NodeId pattern, guard, body;
        } match_arm;
        struct {
            NodeId type, initializer;
        } new_expr;
        struct {
            NodeId type;
            NodeList fields;
        } struct_initializer;
        struct {
            NodeId name, value;
        } field_initializer;
        struct {
            NodeId name;
            NodeList children;
        } pattern;
        struct {
            NodeId start, end;
            bool inclusive;
        } pattern_range;
    } as;
} Node;

VEC_DECLARE(Node, Node_Vec)

typedef struct {
    Node_Vec nodes;
    U32_Vec children;
    U32_Vec scratch;
    U32_Vec resolutions;
    NodeId root;
} Ast;

Ast *ast_new(const size_t token_count);
void ast_free(Ast **a);
NodeId ast_add(Ast *a, const Node node);
uint32_t ast_mark(const Ast *a);
void ast_push(Ast *a, const NodeId id);
NodeList ast_commit(Ast *a, const uint32_t mark);
void ast_init_resolutions(Ast *a);

#ifdef NDEBUG
void ast_fprint(FILE *out, const Ast *a, const char *source);
#endif

ALWAYS_INLINE Node *ast_at(Ast *a, const NodeId id) {
  return &a->nodes.data[id];
}

ALWAYS_INLINE const Node *ast_at_const(const Ast *a, const NodeId id) {
  return &a->nodes.data[id];
}

ALWAYS_INLINE const NodeId *ast_list(const Ast *a, const NodeList list) {
  return a->children.data + list.start;
}

ALWAYS_INLINE void ast_set_resolution(Ast *a, const NodeId ref, const NodeId decl) {
  a->resolutions.data[ref] = decl;
}

ALWAYS_INLINE NodeId ast_resolution(const Ast *a, const NodeId ref) {
  return a->resolutions.data[ref];
}

#endif
