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

// A structured `@c.*` attribute on an item, classified at parse time. `arg` carries `@c.align(N)`'s N;
// `str` is the content span (no quotes, into the owning module's source) of an export/import/section name.
typedef enum {
  ATTR_INLINE, ATTR_ALWAYS_INLINE, ATTR_NOINLINE, ATTR_NORETURN,
  ATTR_ALIGN, ATTR_PACKED, ATTR_EXPORT, ATTR_IMPORT, ATTR_SECTION, ATTR_USED, ATTR_UNUSED,
  ATTR_EMIT_MACRO, // `@emit_macro` (bare, no `c.`): emit this generic type as reusable C DECLARE/DEFINE macros
  ATTR_TEST,       // `@test` / `@test(should_panic)` (arg = 1): a test function (compiled/run under --test)
  ATTR_TEST_INIT,  // `@test_init` (per-module fixture producer) / `@test_init(global)` (arg = 1: suite setup)
  ATTR_TEST_FREE,  // `@test_free` / `@test_free(global)`: optional out-of-band teardown (memory is RAII's job)
  ATTR_C_SOURCE,   // `@c.source("path.c")` on an extern block: compile that C file into the build
  ATTR_C_LINK,     // `@c.link("m")` / `@c.link("-framework X")`: a library / raw flag for the link line
} AttrKind;

typedef struct {
    NodeId owner;  // the item this attribute decorates
    uint8_t kind;  // AttrKind
    uint32_t arg;  // ATTR_ALIGN: the alignment N
    Span str;      // ATTR_EXPORT / ATTR_IMPORT / ATTR_SECTION: the name's content span (else empty)
} Attr;
VEC_DECLARE(Attr, Attr_Vec)

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
  NODE_INTERFACE,
  NODE_EXTEND,
  NODE_TYPE_ALIAS,
  NODE_CONST,
  NODE_STATIC_ASSERT, // `static_assert(cond, "msg")`: compile-time check, lowered to C `_Static_assert`
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
  NODE_DYN_TYPE, // `dyn Iface` (only behind `&`/`&mut` or as `Box<dyn I>`); reuses `indirect_type` --
                 // `type` is the interface path, `qualifier` the flavor (CONST=&dyn, MUT=&mut dyn, NONE=owned)

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
  NODE_ALIGNOF, // `alignof(T)` -> usize byte alignment; the type node is `as.single.value`
  NODE_VA_EXPR, // `va_start(ap, last)` / `va_arg(ap, T)` / `va_end(ap)`; see `as.va_op`
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
  NODE_PATTERN_OR, // `A | B | C` in a switch arm: matches if any alternative matches (`as.pattern.children`)

  NODE_RANGE, // `lo..hi` / `lo..=hi` expression (for-loop iterable only); reuses `pattern_range`

  NODE_TUPLE,      // `(a, b, ..)` tuple literal (2-4 elements); lowers to the prelude Tuple<n> struct
  NODE_TUPLE_TYPE, // `(T1, T2, ..)` tuple type; lowers to a Tuple<n> instance. Both reuse `array_literal`.

  NODE_KIND_COUNT,
} NodeKind;

// `va_op.op` discriminants for NODE_VA_EXPR.
enum { VA_START, VA_ARG, VA_END };

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
            bool is_public; // `pub interface` -- exported for cross-module bounds/extends
        } interface_def;
        struct {
            NodeList generics;
            NodeId interface_type, target_type;
            NodeList items;
        } extend_def;
        struct {
            NodeId name;
            NodeList generics;
            NodeId type;
            bool is_public; // `pub type`
        } type_alias;
        struct {
            NodeId name, type, value;
            bool is_public;     // `pub const`
            bool is_extern;     // `extern "C"` const (no initializer): value resolved from the backing C header
            bool is_static_mut; // `static mut`: a module-level mutable global -- assignable, never CTFE-folded
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
            NodeId default_type;  // `= <type>` default, or NODE_NONE
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
            bool is_move; // `fn move(..) ..` BOUND form: the callable may OWN captured values, so the
                          // generic body must move-track it (only such bounds accept owning closures)
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
            uint8_t op;   // VA_START / VA_ARG / VA_END
            NodeId ap;    // the `va_list` operand
            NodeId extra; // VA_START: last named param (expr); VA_ARG: the type node; VA_END: NODE_NONE
        } va_op;
        struct {
            NodeList values;
        } return_stmt;
        struct {
            NodeId condition, then_branch, else_branch;
        } if_stmt;
        struct {
            NodeId condition, body; // condition == NODE_NONE: an infinite `loop { .. }`
            bool is_do;    // `do { } while (cond)`: body runs before the condition is first tested
            Span label;    // `'name:` prefix ({0,0} = unlabeled); text includes the leading quote
        } while_stmt;
        struct {
            NodeId binding, iterable, body;
            Span label; // `'name:` prefix ({0,0} = unlabeled)
        } for_stmt;
        struct {
            NodeId value; // `break <expr>` (NODE_NONE for a bare break; always NODE_NONE on continue)
            Span label;   // `break 'name` / `continue 'name` target ({0,0} = innermost loop)
        } flow;

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
            NodeList captures; // outer-local decls captured by copy (resolver-filled); empty = a bare fn pointer
            uint64_t mut_caps; // typechecker-filled bitmask over `captures`: bit i set = the body MUTATES
                               // capture i, so it is captured by `&mut` (env holds a pointer, writes are
                               // outer-visible); clear = by copy (a Free copy-capture MOVES in: env owns it)
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
  BT_U8, BT_U16, BT_U32, BT_U64, BT_USIZE, BT_F32, BT_F64, BT_C32, BT_C64, BT_VALIST, BT_VOID,
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
  TYPE_DYN,      // trait object: a sized 2-word fat value {data, vtable}. (module, as.decl) = the interface
                 // DefId; `qualifier` is the flavor: CONST = `&dyn I`, MUT = `&mut dyn I`, NONE = `Box<dyn I>`
                 // (owned -- Free, drop-glue vtable slot). Never wrapped in TYPE_REFERENCE.
  TYPE_NEVER,    // the type of a diverging call (`@c.noreturn`, e.g. panic): unifies with every type,
                 // since control never returns to observe a value. Not nameable in source.
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
        struct {
            TypeId elem;     // aliases `as.elem` (same offset), so every existing ARRAY read still works
            uint32_t len;    // element count under --const-eval (0 = unknown/unfolded: identity as before)
        } arr;               // ARRAY only; folded lengths make [i32;4] and [i32;8] DISTINCT interned types
    } as;
} Ty;

_Static_assert(sizeof(Ty) == 12, "Ty must stay cache-compact"); // 8 -> 12 when ARRAY grew a length

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

// A `&T` -> `&dyn I` erasure site: `node` is the coerced expression, `src` the concrete pointee type,
// `dyn` the trait-object type (both in this Ast's pool). Codegen materializes the {data, vtable} fat
// pair at `node` and emits one static vtable + glue set per distinct (src, interface) in the TU.
typedef struct {
    NodeId node;
    TypeId src, dyn;
} DynUse;
VEC_DECLARE(DynUse, DynUse_Vec)

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
    DynUse_Vec dyn_uses; // dyn-erasure sites recorded by the type checker (drives vtable emission)
    U32_Vec dyn_at;      // side table: index = NodeId, value = 1-based index into `dyn_uses` (0 = none)
    Attr_Vec attrs;     // `@c.*` attributes on items, each tagged with its owner NodeId (linear scan; few)
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
void ast_add_attr(Ast *a, const Attr attr); // record a classified `@c.*` attribute (attr.owner is set)
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

// Record / fetch a dyn-erasure site (`&T` value coerced to `&dyn I` at `node`).
void ast_add_dyn_use(Ast *a, NodeId node, TypeId src, TypeId dyn);
const DynUse *ast_dyn_use_at(const Ast *a, NodeId node);

ALWAYS_INLINE TypeId ast_builtin(const BuiltinType b) {
  return (TypeId)b + 1;
}

// If the numeric literal in src[start,end) carries a type suffix (`1u8`, `1.0f32`, `0xFFu64`), returns
// the named builtin and stores the suffix's start offset in *sfx_start (left untouched otherwise);
// else BT_COUNT. In a hex literal a trailing [a-fA-F] run is digits, so an f32/f64 tail never counts
// there (suffixes in hex must start with a non-hex letter: u8/i32/usize/...).
BuiltinType ast_numeric_suffix(const uint8_t *src, uint32_t start, uint32_t end, uint32_t *sfx_start);

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
