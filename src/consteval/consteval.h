#ifndef CONSTEVAL_H
#define CONSTEVAL_H

// Opt-in (--const-eval) compile-time constant evaluation, in two layers:
//   1. A memoized, demand-driven scalar folder over TYPED expression nodes (bottom-up: children
//      evaluate first; results land in a per-module NodeId -> ConstValue side table). The AST is
//      never mutated -- the typechecker and codegen consult the table where a constant is required
//      (array lengths, designated indices, static_assert) or useful (folded C output).
//   2. A layout engine under the declared 64-bit C data model (pointers are 8 bytes, scalar
//      alignment == size), which makes sizeof(T)/alignof(T) foldable leaves. Every layout the
//      compiler computes is verified in the GENERATED C by an emitted _Static_assert, so the
//      downstream C compiler proves the model matches the real target.
// Both layers are PARTIAL by design: anything unfoldable (opaque extern types, va_list, unresolved
// generics, non-const expressions) reports "not const" and keeps today's delegate-to-C behavior.

#include "ast/ast.h"
#include "module/loader.h"

typedef enum {
  CONST_NONE = 0, // not const-evaluable (the universal fallback -- never an error by itself)
  CONST_INT,      // an integer/char value; signedness/width come from `type`
  CONST_BOOL,
} ConstKind;

typedef struct {
    uint8_t kind; // ConstKind
    TypeId type;  // the node's checked type, in the EVALUATING module's pool (informational)
    int64_t i;    // value bits (unsigned values are the same 64 bits reinterpreted)
} ConstValue;

typedef struct ConstEval ConstEval;

ConstEval *consteval_new(const Package *pkg);
void consteval_free(ConstEval **ce);

// Evaluate expression `id` of module `m`. Requires the subtree to be TYPED (ast_type set by the
// typechecker); returns kind CONST_NONE when the expression is not a compile-time constant.
ConstValue consteval_eval(ConstEval *ce, ModuleId m, NodeId id);

// Size/alignment of interned type `t` (in module `m`'s pool) under the 64-bit layout model.
// False = unfoldable (opaque extern type, va_list, unresolved generic, unknown array length, ...).
bool consteval_layout(ConstEval *ce, ModuleId m, TypeId t, uint64_t *size, uint64_t *align);

#endif
