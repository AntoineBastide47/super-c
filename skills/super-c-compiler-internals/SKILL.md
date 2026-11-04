---
name: super-c-compiler-internals
description: "How the Super-C compiler pipeline works: stages from lexing to linking, data structures between stages, Core IR surface, HIR layer, the freeze contract, identity model, and the package/module architecture. Use when modifying compiler passes, adding language features, or debugging compilation failures."
allowed-tools: Bash Read
---

# Super-C Compiler Internals

## Agent checklist

- Read the linked Core IR and stages reference only when the task needs them.
- Confirm pipeline order in `src/driver/emit.spc`.
- Before you add an analysis, traversal, table, or pass, read the phase's facts in
  [analyses.md](references/analyses.md) and reuse or extend the producer
  (`super-c-task-discipline` section 10). Keep the inventory current in the same change.
- Treat typed facts and Core IR ownership rules as hard contracts.
- Run the self-hosting fixpoint procedure for compiler changes.

## Key Invariants

1. **Determinism.** Two serial runs generate identical output, and `--jobs=N` is
   byte-identical to `--jobs=1`. Facts are integers in Core IR order; indexes are built
   in deterministic module and source order; hash-iteration order never leaks out.

2. **Freeze contract.** Semantic decision tables are final at type-check completion;
   append-only interning is the one sanctioned later mutation (The Freeze Contract in
   [ir-layers.md](references/ir-layers.md)).

3. **One owner.** Each mutable piece of state has one canonical owner. The package owns
   modules; a stage reaches the current module's Ast through its slot, in place.

4. **Near-zero global state.** Per-compile state lives in per-compile contexts (Lexer,
   Parser, Ast, TypeChecker, ...); const tables are built by `const fn` and held by
   value. The `static mut`s of the compiler proper are process-wide settings, diagnostics and
   one cache: the loader's settings (`G_LOAD_JOBS`, `G_ARCH`, `G_FEATURES`), the build record
   (`driver::stats`), the type-stats counters (`TS_*` in `src/ast/ast.spc`) and the emission
   phase's `DropCtx` pool (`G_DPOOL`, freed at the end of the drain). No semantic decision
   lives in one. List them with `grep -rn 'static mut' src`.

5. **Direct C.** The emitted C moves a value with an assignment, a compound literal or a lane
   loop, never `memcpy` into a temporary, and declares no temporary that only copies a value.
   The per-body decisions in `src/emit/cemit.spc`:
   - A copy shares one C variable with its source. `setup_locals` merges a single-use
     temporary into its copy's destination, except a retyping (`same_c_cast`) into a temporary
     read once: both fold into that read instead, since a merged destination never folds (a
     reference made a raw pointer for an argument spells `f((void *)(&x))`); `coalesce_copies` does it over the CFG when the
     source is dead after the copy and the destination holds no value the source's live range
     can reach (`copy_range`, `live_from`): an `if` or `switch` value and a short-circuit result
     write the binding in each arm, through chains of copies. A temporary copy of an immutable
     binding or parameter spells the binding. An array literal's element value writes `d[k]` at
     its definition (`compute_elems`). A vector result writes its local (`vec_forward`).
   - A local declares at its initializing write when that write dominates every access
     (`compute_fusion`): a drop flag at the entry (`bool _5 = false;`), a local of a loop when
     every access lies inside the loop's braces (no do-loop test, no exit), any local in the goto
     layout. A borrowed local's storage ends must lie in that scope too.
   - A single-use pure value is spelled at its read (`sx_inline`): in its block, along a goto
     chain (`sx_gpred`), past a guard whose other edges only panic (`sx_spred`) and past a call
     (`sx_cpred`) when the value cannot panic and reads no memory and no local a pointer
     reaches; as the base of a place read through a pointer; as a value argument (`by_value_arg`).
     A constant temporary is spelled at every read (`const_folds`). A binding the source names
     folds only inside its block. C orders no operands: a reader, a call's arguments included,
     holds at most one folded expression that can panic (`one_panic_per_reader`). A spliced
     callee's parameter reads its argument in place unless the callee can reach the argument's
     storage (`ir::inline::param_facts`, `exposed`); `vec_literals`, `vec_fusion` fold vectors.
   - A pointer local defined once by the address of a place that stays where it is, and read
     only through a dereference, spells that place at each use (`fold_addresses`): the path
     dereferences at most its base, a local never written whole, and indexes only an array held
     in place, by a constant, a temporary written once or an argument never written, none of them
     addressed (`fixed_index`). An inlined `Array::index` writes `pad.data[7] = n`.
   - A single-use call result is spelled at its read (`compute_call_fwd`): along the same goto
     chains, through copies folded at their read, into a literal's member and into a field or
     element of a local's own storage, when nothing between emits and no other operand can
     change in the call (`fwd_keeps`).
   - A value nothing reads has no variable: a call's result or a check's index is a statement
     of its own (`compute_discards`; an external C function keeps its result, since its header
     may declare it `warn_unused_result`), and a proven check's other operands are no reads.
     A copy into the result slot moves past the drops to its `return` (`compute_ret_defer`).
   - A zero value inside another literal is left out: C zero-fills the member, and gcc's
     `-Wmissing-braces` rejects a nested `{ 0 }` (`zero_lit_d`).
   - A temporary remains where an effect between would change its value: a call result held
     while the destination's old value is read or dropped (an inlined `replace`, `x = f()` over
     an owning `x`), a value read before a write to its inputs, several calls in one literal (C11
     6.7.9p23 leaves their order unspecified), an `if` value passed as an argument, a value
     merged at a join and returned.
   `memcpy` and `memmove` remain where C has no other legal spelling: an array copy, a bitcast (a
   type pun), and a raw pointer that may overlap its operand.

## Reference files

Read only the file the task needs. Section names are kept, so a pointer such as
"see Header Types" names a heading in one of these files.

- [pipeline.md](references/pipeline.md): stage order from lexing to linking, the data each stage hands on.
- [identity-and-modules.md](references/identity-and-modules.md): NodeId, ItemId, DefId, TypeId, ModuleId; packages and modules.
- [ir-layers.md](references/ir-layers.md): the Core IR surface, the desugar stage, what is frozen when.
- [borrow-checker.md](references/borrow-checker.md): regions, loans, facts and diagnostics of the borrow check.
- [drop-elaboration.md](references/drop-elaboration.md): where drops and frees are inserted.
- [ctfe.md](references/ctfe.md): the constant evaluator.
- [monomorphization.md](references/monomorphization.md): instances of generic code.
- [lir.md](references/lir.md): the low-level IR and its optimizer.
- [native-backend.md](references/native-backend.md): instruction selection, registers, encoders, objects.
- [emission.md](references/emission.md): emission buffers, probes, the build output tree.
