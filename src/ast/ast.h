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

// A module index within a Package; 0 is the single-file / REPL path. Kept to uint16_t so it packs
// into both DefId and Ty.module without growing them (<= 65535 modules).
typedef uint16_t ModuleId;

// A program-wide declaration handle: NodeId is local to one module's Ast, DefId is global. Same-module
// refs are {own module, node}; imported refs are {origin module, node}. The all-zero value is "unresolved".
typedef struct {
    ModuleId module;
    NodeId node;
} DefId;

VEC_DECLARE(DefId, DefId_Vec)

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
  NODE_IMPORT,
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
  NODE_CLOSURE, // an anonymous `fn(..) .. { .. }` or compact `|..| expr` function value
  NODE_INDEX,
  NODE_MEMBER,
  NODE_CAST,
  NODE_GENERIC_SPECIALIZATION,
  NODE_MATCH,
  NODE_MATCH_ARM,
  NODE_NEW,
  NODE_SIZEOF, // `sizeof(T)` -> usize; the type node is `as.single.value`
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
            bool is_mutable; // transient: set on a parameter name preceded by `mut`, read when building NODE_PARAMETER
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
            bool is_public;   // `pub fn` -- stored for visibility (field privacy is what's enforced today)
            bool is_extern;   // declared in an `extern "C"` block: keep the real C symbol name (never mangled)
            bool is_variadic; // trailing `...` C variadic (extern only): a call may pass extra trailing args
        } function;
        struct {
            NodeId name, type;
            bool is_mutable; // `fn f(mut p: T)` -- a by-value parameter assignable in the body (emitted non-const)
        } parameter;
        struct {
            NodeId name;
            NodeList generics, members;
            bool is_public; // `pub struct`
            bool is_union;  // `union` (untagged): a NODE_STRUCT whose fields overlap; emitted as a C `union`
        } aggregate;
        struct {
            NodeId name, type, value;
            bool is_public; // `pub` field; private fields are reachable only inside the struct's own extend
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
            bool is_public; // `pub interface` -- exported for cross-module bounds/impls
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
            bool is_public; // `pub type`
        } type_alias;
        struct {
            NodeId name, type, value;
            bool is_public; // `pub const`
        } const_def;
        struct {
            NodeId abi;
            NodeId header; // optional `extern "C" "pthread.h" { .. }`: the backing C header to #include, or NODE_NONE
            NodeList items;
        } extern_block;
        struct {
            NodeList path;  // `::`-separated identifier segments, e.g. `std::string`
            NodeId alias;   // `as <name>` module alias, or NODE_NONE
            bool glob;      // `as *`: bring the module's public items into scope unqualified
        } import_decl;
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
            NodeList params;  // NODE_PARAMETER nodes (always type-annotated)
            NodeList returns; // explicit return type(s); empty for a compact closure (return inferred from body)
            NodeId body;      // a NODE_BLOCK (anonymous `fn`), or the body expression (compact `|..|`)
            bool expr_body;   // true: `body` is an expression to be returned; false: `body` is a block
        } closure;
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
// Every entry is a scalar, complex (`c32`/`c64` -> C `_Complex`), or void. The string view `str` and the
// slice views `Slice<T>`/`SliceMut<T>`
// (what `[]T`/`[]mut T` lower to) are not builtins -- they are ordinary prelude structs (auto-imported).
typedef enum {
  BT_BOOL, BT_CHAR, BT_I8, BT_I16, BT_I32, BT_I64, BT_ISIZE,
  BT_U8, BT_U16, BT_U32, BT_U64, BT_USIZE, BT_F32, BT_F64, BT_C32, BT_C64, BT_VOID,
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
  TYPE_INSTANCE, // a generic struct/enum applied to concrete type args (e.g. Vec<i32>); `as.inst` indexes
                 // the Ast's interned instance table, so Vec<i32> and Vec<bool> are distinct interned types
  TYPE_OPAQUE,   // an `extern "C" { type X; }` handle: a real, sized C type named by the header. `as.decl`
                 // is the NODE_TYPE_ALIAS (in `module`); renders to its own unmangled C name, never `void`
} TypeKind;

// Named `Ty`, not `Type`: a `Type` token-keyword enum constant already occupies that identifier.
typedef struct {
    uint8_t kind;
    uint8_t qualifier; // POINTER/REFERENCE/SLICE only
    ModuleId module;   // STRUCT/ENUM/FUNCTION/GENERIC: module owning `as.decl`, so (module, decl) is a
                       // global DefId and named types unify across modules. 0 for builtins/single-file.
    union {
        BuiltinType builtin; // BUILTIN
        TypeId elem;         // POINTER/REFERENCE/SLICE/ARRAY pointee/element
        NodeId decl;         // STRUCT/ENUM/GENERIC decl node; FUNCTION = NODE_FUNCTION/NODE_FUNCTION_TYPE node
        uint32_t inst;       // INSTANCE: index into the Ast's instance table
    } as;
} Ty;

_Static_assert(sizeof(Ty) == 8, "Ty must stay cache-compact");

VEC_DECLARE(Ty, Ty_Vec)
HM_DECLARE(Ty, TypeId, TyMap) // Ty -> TypeId, so ast_intern_type dedups in O(1) not O(pool)

// A generic struct/enum applied to concrete type args. `module`/`decl` name the generic aggregate; `args`
// are its type arguments (interned TypeIds in the SAME Ast). Interned (deduped) so equal applications
// share one index -> equal TYPE_INSTANCE Tys. Up to 4 type params.
typedef struct {
    ModuleId module;
    NodeId decl;
    uint8_t n;
    TypeId args[4];
} TyInstance;
VEC_DECLARE(TyInstance, TyInstance_Vec)

// Per-call generic type arguments (monomorphization): the concrete types a generic call instantiates
// (turbofish-explicit or inferred), recorded by the type checker and read by codegen. Up to 4 params.
typedef struct {
    NodeId node;
    uint8_t n;
    TypeId args[4];
} MonoUse;
VEC_DECLARE(MonoUse, MonoUse_Vec)

// A monomorphized use of a generic method that has its OWN extra generic params (e.g. `map<U>`): the
// concrete instance it's called on plus the method's own type args. Propagated into the method's owning
// module (where the instance is emitted) so the owner emits the matching `Inst__method__targs` spec.
typedef struct {
    TypeId instance; // TYPE_INSTANCE the method is invoked on, interned in THIS Ast's pool
    NodeId method;   // the method decl node, local to this (owning) Ast
    uint8_t n;
    TypeId targs[4]; // the method's own generic args, interned in THIS Ast's pool
} MethodInst;
VEC_DECLARE(MethodInst, MethodInst_Vec)

typedef struct {
    Node_Vec nodes;
    U32_Vec children;
    U32_Vec scratch;
    DefId_Vec resolutions; // side table: index = NodeId, value = DefId (all-zero = unresolved)
    Ty_Vec type_pool;   // interned types; index 0 is TYPE_ERROR, 1..BT_COUNT are the builtins
    TyMap type_index;   // reverse of type_pool: interned Ty -> its TypeId
    U32_Vec types;      // side table: index = NodeId, value = TypeId (0 = unknown)
    MonoUse_Vec mono;   // per-call generic type arguments, append-only (latest record for a node wins)
    U32_Vec mono_at;    // side table: index = NodeId, value = 1-based index into `mono` (0 = none) -> O(1) lookup
    TyInstance_Vec instances; // interned generic instantiations referenced by TYPE_INSTANCE Tys
    MethodInst_Vec method_insts; // generic-method instantiations to emit here (owner); linear scan
    NodeId root;
    ModuleId module;    // this Ast's module index within its Package (0 for single-file / REPL)
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

// Intern a generic instantiation `decl<args...>` (deduped), returning a TYPE_INSTANCE TypeId. `ast_instance`
// recovers the (decl, args) record from an interned TYPE_INSTANCE's `as.inst` index.
TypeId ast_intern_instance(Ast *a, ModuleId module, NodeId decl, const TypeId *args, uint8_t n);
const TyInstance *ast_instance(const Ast *a, uint32_t index);
// Record a generic-method instantiation to be emitted by this (owning) Ast, deduplicated. Returns true
// if it was newly added (drives the propagation fixpoint).
bool ast_add_method_inst(Ast *a, TypeId instance, NodeId method, const TypeId *targs, uint8_t n);

// Deep-copy an interned type from `src`'s pool into `dst`'s, returning the equivalent TypeId in `dst`.
// Used to move a generic instantiation referenced in one module into its template module's pool.
TypeId ast_reintern(Ast *dst, const Ast *src, TypeId t);
// True if `t` mentions no unresolved type parameter (a real instantiation, not a template like Box<T>).
bool ast_type_concrete(const Ast *a, TypeId t);

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

// Same-module resolution: the common path. `decl` is a node in this Ast, tagged with this module.
ALWAYS_INLINE void ast_set_resolution(Ast *a, const NodeId ref, const NodeId decl) {
  a->resolutions.data[ref] = (DefId){a->module, decl};
}

// The resolved node id. Valid as a local NodeId only when the ref resolves within this module; use
// ast_resolution_def when a reference may cross a module boundary (imports).
ALWAYS_INLINE NodeId ast_resolution(const Ast *a, const NodeId ref) {
  return a->resolutions.data[ref].node;
}

// The full global handle, including the owning module -- for cross-module-aware code.
ALWAYS_INLINE DefId ast_resolution_def(const Ast *a, const NodeId ref) {
  return a->resolutions.data[ref];
}

// Record a resolution that may point into another module (an imported decl).
ALWAYS_INLINE void ast_set_resolution_def(Ast *a, const NodeId ref, const DefId decl) {
  a->resolutions.data[ref] = decl;
}

// Record / fetch a generic call's concrete type arguments (monomorphization). `ast_type_args` returns
// NULL when the call has none recorded (not a generic call, or no instantiation determined).
void ast_set_type_args(Ast *a, NodeId node, const TypeId *args, uint8_t n);
const MonoUse *ast_type_args(const Ast *a, NodeId node);

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
