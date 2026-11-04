# CTFE (Compile-Time Function Evaluation)

## CTFE (Compile-Time Function Evaluation)

`src/ir/interp.spc` is the Core IR interpreter, the only evaluator (the AST-based one
was deleted). It serves typechecker folds (array lengths, const args, static_assert,
`const`/`static mut` initializers, the constant-trap scan), `const`/`static` emission,
`type_info` rendering, the `fx` scanner (const-fn eligibility, always-panics), and lint probes.
A scalar read from or written to a place takes the place's checked type (`place_typed`): the literal
stored by `let e: i64 = 0` is an `i64` in its slot, so a pointer view of the slot (`&mut e` as a
`*mut i64` argument) passes the slot type check (`scalar_view`).

A pointer into an array that an object holds by value (a member array, an element of an array
of structs) moves on past that array through the scalars of the outermost holding object in
member order (`flat_elem`), as in C memory, while every scalar it crosses has the type of the
array's first one; past the holder it traps out of bounds, and where a crossed scalar's type does
not resolve the evaluation fails (no fold) instead. A body found in the engine's cache still
records the item edge from the item under check to the body's item (`note_body_edge`), so the
final item edges do not depend on which item lowered the body first.

The constant-trap scan (`tc_ct_check`, after each binary, unary and assignment node in
`check_expr_w`) folds the integer operations over closed operands and reports a trap at the
operation (operations.md); a mandatory evaluation (`tc_mandatory_const`,
static_assert, a discriminant, an array length or repeat count) whose expression it reported
(`ct_n` moved) reports nothing more. The always-panics pass runs only when type checking passed,
so it never repeats one; each probe (`Interp::lint_body`) runs at most `IT_PROBE_STEPS` (65536)
steps. The engine's hash-keyed caches (`body_ix`, `lane_memo`, the call memo) compare the whole
key on a hit: a hash two keys share is a miss.

Driver protocol: `cir.all_typed` and `record_folds` are set **before the first body
lowers** (the constant contexts lowering evaluates, such as build conditions, repeat counts
and range bounds, must behave exactly as under the backend's own lowering); lowering never
folds a call outside a constant context; `flush_asserts` / `flush_consts` re-evaluate the ones a check could not fold
(a callee outside the item's visibility) at the end, and a top-level `static_assert`
that still does not fold then is an error; `report_fold_errs` surfaces
emission-time fold failures. After the always-panics pass and `flush_consts`,
`Interp::release_pass` frees the callee bodies lowered since `Interp::body_mark` (taken
before the pass), except those lowered from a body arena, and the retained dead-object
storage; the constant pass before emission lowers again the few it needs (from live syntax,
so with the same result). That pass runs only the constants whose initializer did not evaluate
whole before the keep's view opened (`Interp.whole`): a whole evaluation reached only the
engine's own boxes, which stay. A call-bearing constant initializer evaluates once in the type
check: its static capture runs first, and a scalar result answers the fold from the memo.
A `static_assert` in a generic function's body holds per
instance. The resolver records each function whose body holds one and that has its own
generic parameters or sits in an extend with parameters (`Ast.assert_fns`); a checked call
with concrete arguments queues the instance (`tc_defer_inst_asserts`,
`Interp::defer_inst_assert` into `Interp.inst_asserts`), and the driver's
`flush_inst_asserts`, after `flush_asserts`, evaluates the queue through
`cemit_inst_asserts` while the kept bodies are readable. After `InstGraph::collect`,
`graph_inst_asserts` runs `cemit_inst_asserts` for every non-speculative `IG_FN` and
`IG_METHOD` record whose declaration is in `Ast.assert_fns` (`InstGraph::assert_binds`
gives the bindings), so an instance reached only through another generic body is checked
too, while the body syntax is still live. Emission runs `cemit_inst_asserts` again for every
instance it demands, once per instance; after a failure in the graph's check
(`Interp.inst_asserts_failed`) it reports nothing more, so each failure is reported once.
`SC_CEMIT_STATS` prints `cemit-stage inst-asserts: <ms> ms, <n> instances`. During the type check the engine answers as the item under
check (`Interp::set_reader`): a body or a checked type of an item that item cannot see
(`graph::items::visible`) is a refusal, whatever a worker has done with it.

A constant's result depends on that constant alone, never on which constants were
evaluated before it. The call memo lives for one evaluation. A referenced constant and a
fold a lowering asks for inside a run (`eval_g`, `eval_lanes`) evaluate isolated
(`Interp::iso_enter`): their own steps, call depth, instance nesting, memory and call
memo; their objects are released after, except the storage a pointer-holding result
points into, which stays outside the referrer's budget. Each reference is charged a copy
of the value. A fold's trap is dropped: the evaluation that asked for it reports its own.
A nested fold's failure holds for the rest of the evaluation (`fold_fail`, `lane_fail`).

Constant dependencies do not nest on the native stack: an evaluation that reaches
`IT_ITEM_NEST` (16) nested constants evaluates the requester's remaining constant
dependencies dependency-first from an explicit work stack (`prefetch_items`), keeping
scalar results in `item_memo`, pointer-free aggregates in `item_aggs` (a frozen copy each
reference thaws), aggregates with pointers in `item_objs` (cloned per reference) and
failures in `item_fail` (replayed with the trap they raised). Across evaluations,
`item_memo`, `item_aggs` and `item_dead` (each constant that failed with a trap no budget
caused) persist. A constant or fold the work stack cannot see (through a function body or a
lowering) nests at most `IT_DEFER_DEPTH` (64) native levels above the outermost nested
evaluation: past that the attempt is dropped, the outermost evaluation evaluates the deep
one first (`Interp::defer_retry`, one at a time) and runs again, so neither a dependency
chain nor the call stack a fold starts under decides a result, and a long cycle still
reports "cyclic constant dependency".
Generic-constant instances nest up to `IT_ITEM_MAX_NEST` (64) inside one constant's
evaluation ("constant evaluation nests too deeply").

Every const initializer evaluates during the type check: a trap is an error at the
constant (a call-free initializer leaves a trap raised in a referenced constant to that
constant, except a cycle), and a refusal defers to `flush_consts`. A constant-expression
attribute argument (`Attr.expr`: the attribute table `ATTR_EXPR_KINDS` / `attr_expr_type` in
`src/ast/ast.spc` names the attributes and each argument's type) is checked and folded by its
owner's `check_item` (`tc_attr_exprs`); a failure, a refusal included, is an error at the
argument, and the value goes to `Ast.attr_vals` (`Ast::attr_value`). The layout service reads
`@align` from there: before the owner's check it answers not-ok and caches nothing
(`Svc.pending`). An explicit enum discriminant must fold there too; `Interp::discr` is the one discriminant rule the
lowering, the emitted C enum, constant evaluation, static data and `type_info` share, for
payload enums as for bare ones. The checker rejects a duplicate value or one outside the
i32 range in a non-extern enum. A discriminant read has type i32 when a tag of the enum is
negative, else u32; the emitter sign-extends switch cases on an i32 discriminant. In
constant evaluation, a payload-less variant of a payload enum is an enum object (tag slot
only), and a static `SS_ENUM` stores the active variant's ordinal in slot 0.
