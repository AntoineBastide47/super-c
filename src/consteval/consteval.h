#ifndef CONSTEVAL_H
#define CONSTEVAL_H

// Compile-time constant evaluation (always on; --const-eval-steps/--const-eval-memory bound it), in two layers:
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
  CONST_FLOAT, // an f32/f64 value in `f` (always finite when reported through this interface)
} ConstKind;

typedef struct {
    uint8_t kind; // ConstKind
    TypeId type;  // the node's checked type, in the EVALUATING module's pool (informational)
    union {
        int64_t i; // value bits (unsigned values are the same 64 bits reinterpreted)
        double f;  // CONST_FLOAT (an f32 value is stored pre-rounded to float precision)
    };
} ConstValue;

typedef struct ConstEval ConstEval;

// `max_steps` bounds interpreted statements/expressions and `max_mem_bytes` the object storage,
// both PER top-level evaluation (so folding stays order-independent); 0 picks the default. An
// exhausted budget is not an error -- the expression simply stays a runtime one.
ConstEval *consteval_new(const Package *pkg, uint32_t max_steps, uint64_t max_mem_bytes);
void consteval_free(ConstEval **ce);

// The reason the LAST consteval_eval could not fold, when that reason was a would-be runtime trap
// (panic/abort, division by zero, out-of-bounds, use-after-free) or a blown budget; NULL otherwise.
// Cleared at each top-level evaluation.
const char *consteval_trap(const ConstEval *ce);

// Deferred static_asserts: a condition not yet decidable when its module checks (e.g. calling a
// function defined later, or in a later module) is recorded and re-evaluated by
// consteval_flush_asserts AFTER the whole package has type-checked. The callback receives each
// assert that folded FALSE (msg = NULL) or hit a compile-time trap (msg = the trap).
void consteval_defer_assert(ConstEval *ce, ModuleId m, NodeId cond);
typedef void (*CeAssertErr)(void *ctx, ModuleId m, NodeId cond, const char *msg);
void consteval_flush_asserts(ConstEval *ce, CeAssertErr err, void *ctx);

// Evaluate expression `id` of module `m`. Requires the subtree to be TYPED (ast_type set by the
// typechecker); returns kind CONST_NONE when the expression is not a compile-time constant.
ConstValue consteval_eval(ConstEval *ce, ModuleId m, NodeId id);

// Size/alignment of interned type `t` (in module `m`'s pool) under the 64-bit layout model.
// False = unfoldable (opaque extern type, va_list, unresolved generic, unknown array length, ...).
bool consteval_layout(ConstEval *ce, ModuleId m, TypeId t, uint64_t *size, uint64_t *align);

#endif
