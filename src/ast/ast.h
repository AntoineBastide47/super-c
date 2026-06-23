#ifndef AST_H
#define AST_H

#include <stdbool.h>
#include <stdio.h>

#include "lexer/token.h"
#include "types/hashmap.h"
#include "types/vector.h"

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
  NODE_ARRAY_LITERAL,
  NODE_STRUCT_INITIALIZER,
  NODE_FIELD_INITIALIZER,

  NODE_PATTERN_WILDCARD,
  NODE_PATTERN_LITERAL,
  NODE_PATTERN_NAME,
  NODE_PATTERN_TUPLE,
  NODE_PATTERN_STRUCT,
  NODE_PATTERN_FIELD,
  NODE_PATTERN_RANGE,

  NODE_RANGE, // `lo..hi` / `lo..=hi` expression (for-loop iterable only); reuses `pattern_range`

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
            NodeId value; // explicit discriminant `= <int>` (payload-less variants only), or NODE_NONE
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
            TypeQualifier qualifier; // `&mut` address-of (TYPE_QUAL_MUT); TYPE_QUAL_NONE otherwise
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
            bool path; // `Enum::Variant` path (object names a type) vs a `.`/`->` value member
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
            NodeList elements;
        } array_literal;
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
            NodeId start, end; // either may be NODE_NONE for a half-open range (NODE_RANGE)
            bool inclusive;
        } pattern_range; // shared by NODE_PATTERN_RANGE and NODE_RANGE
    } as;
} Node;

VEC_DECLARE(Node, Node_Vec)

typedef uint32_t TypeId;
#define TYPE_NONE ((TypeId)0) // unknown / not-yet-computed / poison (suppresses cascading errors)

// Order matches resolver.c's is_builtin_type[] table so a name lookup maps straight to an index.
typedef enum {
  BT_BOOL, BT_CHAR, BT_I8, BT_I16, BT_I32, BT_I64, BT_ISIZE,
  BT_U8, BT_U16, BT_U32, BT_U64, BT_USIZE, BT_F32, BT_F64, BT_VOID,
  BT_COUNT,
} BuiltinType;

typedef enum {
  TYPE_ERROR = 0,
  TYPE_BUILTIN,
  TYPE_POINTER,
  TYPE_REFERENCE,
  TYPE_SLICE,
  TYPE_ARRAY,
  TYPE_FUNCTION,
  TYPE_STRUCT,
  TYPE_ENUM,
  TYPE_GENERIC,
} TypeKind;

// Named `Ty`, not `Type`: a `Type` token-keyword enum constant already occupies that identifier.
typedef struct {
    TypeKind kind;
    TypeQualifier qualifier; // POINTER/REFERENCE/SLICE only
    union {
        BuiltinType builtin; // BUILTIN
        TypeId elem;         // POINTER/REFERENCE/SLICE/ARRAY pointee/element
        NodeId decl;         // STRUCT/ENUM/GENERIC decl node; FUNCTION = NODE_FUNCTION/NODE_FUNCTION_TYPE node
    } as;
} Ty;

VEC_DECLARE(Ty, Ty_Vec)
HM_DECLARE(Ty, TypeId, TyMap) // Ty -> TypeId, so ast_intern_type dedups in O(1) not O(pool)

typedef struct {
    Node_Vec nodes;
    U32_Vec children;
    U32_Vec scratch;
    U32_Vec resolutions;
    Ty_Vec type_pool;   // interned types; index 0 is TYPE_ERROR, 1..BT_COUNT are the builtins
    TyMap type_index;   // reverse of type_pool: interned Ty -> its TypeId
    U32_Vec types;      // side table: index = NodeId, value = TypeId (0 = unknown)
    NodeId root;
} Ast;

Ast *ast_new(const size_t token_count);
void ast_free(Ast **a);
NodeId ast_add(Ast *a, const Node node);
uint32_t ast_mark(const Ast *a);
void ast_push(Ast *a, const NodeId id);
NodeList ast_commit(Ast *a, const uint32_t mark);
void ast_init_resolutions(Ast *a);
void ast_init_types(Ast *a);
TypeId ast_intern_type(Ast *a, const Ty t);

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

ALWAYS_INLINE TypeId ast_builtin(const BuiltinType b) {
  return (TypeId)b + 1;
}

ALWAYS_INLINE void ast_set_type(Ast *a, const NodeId n, const TypeId t) {
  a->types.data[n] = t;
}

ALWAYS_INLINE TypeId ast_type(const Ast *a, const NodeId n) {
  return a->types.data[n];
}

ALWAYS_INLINE const Ty *ast_type_at(const Ast *a, const TypeId t) {
  return &a->type_pool.data[t];
}

#endif
