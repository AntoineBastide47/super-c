# Ownership analysis from typed Core IR: the analysis boundary, the elaboration point, the checks

The borrow, move and drop analyses run from committed facts of the typed Core IR, with
shared control-flow facts built once per body, the cleanup elaborator fed from those
analyses instead of a second ownership pass, one reusable scratch per worker, and a set of
validation-mode checks. This is the record: what the analyses read, where the duplicate
work was, the elaboration point that removed it, what the inliner had to learn, the checks,
and the numbers.

## What each analysis reads

Every analysis input is a Core IR fact of the lowered body or an immutable type fact:

| Product | Built by | Input |
|---------|----------|-------|
| move paths (`MoveForest`, `borrowck/move_paths.spc`) | `build_into(body)` | locals, places, projections (field and downcast chains; a dereference or index cuts) |
| control-flow facts (`Cfg`, `borrowck/dataflow.spc`) | `build_into`, `build_preds` on demand | terminators; successors, predecessors, reverse postorder, the acyclic bit |
| facts (`BodyFacts`, `borrowck/facts.spc`) | `Owner::generate_into(.., loans)` | statements and terminators in order, callee signatures through the package, the ownership oracle over types; loans only when asked |
| loans (`Solver`, `borrowck/loans.spc`) | `build_into` | facts, CFG, liveness |
| move and init (`MoveFlow`, `borrowck/dataflow.spc`) | `build_into` | forest, the facts' event ranges, CFG |
| drop requirements (`Schedule`, `ir/drops.spc`) | `elaborate_into` | the move/init solution, the facts' events, the forest, the types' ownership |
| the rewrite (`insert_drops`) | | the schedule, the forest |

The replay tape (`bc_replay`) stays authoritative for the AST-side flow tracker (regions,
lifetimes, marks, loop rechecks, closure capture bits): no event category has a direct IR
replacement, as [core-ir-publication.md](core-ir-publication.md) records, and none is
claimed here.

## The duplicate pass and where it went

Before this change the borrow pass built the forest, the facts, the CFG and the move/init
solution for a body, and emission built the forest, moves-only facts, the CFG and the
solution again for the same body before elaborating its drops, because the inliner spliced
callees into the caller first and the merged body was elaborated as one. On the compiler's
own sources 2,112 of 3,746 emitted bodies receive inlined callees, so publishing a schedule
per body and consuming it only where no splice happened would have left most of the
duplicate work in place.

The elaboration point is now the end of each body's analyses in the borrow pass
(`flow_ir::bc_elaborate`, called by `bc_ir_analyze` after `bc_ir_body`, only when a keep
receives the bodies):

1. The size verdict for the inliner is recorded on the pre-elaboration shape
   (`CoreBody.inline_size_ok`, from `inline::callee_size_ok`; the two blocks, statements and
   locals each strip-mined loop chunk adds do not count).
2. The feature bits decide whether anything can be scheduled: an owning local
   (`FT_OWNED`), else a store into a projected place that owns through auto-freeing
   storage (`drops::assign_may_schedule`, which tests the storage class before the
   ownership oracle). Whole-local stores spelled with the local's type are never asked:
   the locals answered. A body outside the gate is left as lowered (`elaborated` set).
3. The CFG and the move/init solution are built when the analyses skipped them (a body
   with owned locals but no move event and no split-init declaration).
4. `elaborate_into` classifies every storage marker and store; `insert_drops` rewrites
   the body in place. The `ElabCtx` scratch lives in `BorrowCtx.el`, is counted by the
   scratch budget and reset by `trim_scratch` (which now runs after the elaboration).
5. Under `SC_BC_VALIDATE=1` the elaborated body passes `ir::verify` and `verify_drops`.

The keep receives the elaborated body (`Keep::put` copies it compact, flags included). The
evaluator reads a `TM_DROP` as a jump, so kept bodies evaluate as before. Emission's
`DropCtx::apply_drops` elaborates only a body it lowered itself (a per-instance
re-lowering for reflection or zero-size conditions, a macro-template wrapper), and does so
before the inliner. The inliner (`ir/inline.spc`) splices elaborated callees: the callee's
drop terminators, flag temps and markers come along, a guarded drop's flag local rebases
with the callee locals (`TM_DROP.args_start`), and no ownership analysis runs on a merged
body; the `has_uninit_decl` propagation that served the merged elaboration is gone.
`InlineStore::build` and `vet_body` read `inline_size_ok`, so the accepted callee set is
the one the limits were tuned for.

What this changes in the emitted C: a body that inlines callees numbers its blocks and
locals differently (the caller's cut blocks and flag temps precede the spliced callee's),
and an inlined callee's flag temps initialize at the callee's entry instead of the caller's.
The label-normalized diff of the compiler's own C against the previous compiler over the same
sources is confined to those bodies; the two-generation fixpoint and the worker-count
identity hold.

## Validation-mode checks

`SC_BC_VALIDATE=1` (the gate's fixpoint and worker-identity builds run under it) adds,
per body, in `bc_validate_facts` and `bc_elaborate`:

- every move path has a valid parent (a root per local, a child after its parent on the
  same local);
- the init rows are sized by the path count and there is one per block;
- every loan issues at a borrow operation: a reference, a carrying projected copy or view,
  an array's slice view, a closure capture, a call's implicit autoref, or a call's reborrow
  of a `&mut` argument;
- every borrow error names a loan and a point of the body;
- the loan solver runs in both row representations (dense bitsets and sparse lists) and
  `Solver::assert_agrees` compares errors, required points, origin liveness, prepass
  columns and in-scope bits (`BorrowCtx::new` reads the switch, so harness-driven borrow
  tests are compared too);
- the liveness queue stayed within its tight bound (seeds plus two pushes per edge and
  local); every build asserts the looser monotone bound of each fixpoint queue at each push
  (`Liveness.pushes`, `MoveFlow.pushes`, `Solver.flow_pushes`: the seeds plus one push per
  row change, a row changing at most once per lattice bit);
- a body outside the schedule gate schedules nothing;
- the elaborated body passes the structural verifier (`ir::verify`, which walks the
  blocks' live statement runs) and the ownership verifier. A body the checker rejected skips
  both (`bc_elaborate`'s `verify`): it never reaches emission, and its elaboration has no
  correct schedule (a field moved out of a `Free` value cannot be released). The flag materialization
  re-copies every run and then removes the superseded entries: the emitter's per-local
  counts read the whole statement pool.

`drops::verify_drops` is the independent check of an elaborated body. It recomputes the
move/init state of every move path from the elaborated body's own events
(`df::apply_event`, the one transfer function) with its own fixpoint, then judges every
drop terminator and storage marker: an unguarded drop releases a value the path definitely
holds (a second release, or a value that was never initialized, fails), a guarded drop
releases a value the path may hold and never a partially moved whole, a marker's chain of
cut drop blocks is judged from the state before the marker and must release every path the
local may still hold, a marker with no drop must find nothing held, and a return must find
nothing held by any declared owning local. "Held" counts only the paths that need a release
(`dv_owned_paths`): the type owns memory, and the path is a leaf or a value some member of
which has no path of its own; a struct or tuple whose every member has a path is released
member by member. A definite move below one variant of an enum path proves the variant it
holds (`dv_prove_variants`): the enum path and its other variants then hold nothing beyond
that variant's members. Closure captures are excluded (the env owns them across calls). A failure
prints the body, the failing block and local, and the local's events.

A partially moved struct or tuple (a destructuring `let`, switch arm or `for` pattern moved
some members out) drops each still-owned member at its marker (`DK_FIELD`). Ownership is
judged on the member path's concrete type, never on the declared member type, which may be
a type parameter (`Tuple2<i32, String>` declares `_0: T0`). A member no place names drops
through its declared type and index, which must be concrete; so a by-value destructuring
names every member (`Lowerer::mention_members`). Member places use one key per storage: a
named field (a tuple's `_0` included) is `sub` = the FIELD decl with `data` = IR_NONE, as a
member access spells it; only a positional member (an `is_tuple` struct, a variant payload)
keys by index. A partially moved enum drops the still-owned members of the variant that a
definite move below it proves (a payload member moves only after its tag test passed, and
only a whole store changes the tag); a member only partly held releases its own parts, at
any depth (`drops::part_drops`, drops placed by the path's projection chain). So a by-value
pattern names every member of each struct, tuple and variant payload it destructures
(`Lowerer::mention_parts`). A part only maybe held (no flag guards a part) leaves the
flag-guarded whole drop, which the verifier rejects.

A by-value `switch` spills its scrutinee into a temporary declared at the match node and
registered in every arm's scope: each arm's exits end its storage after the arm's
bindings, so the elaboration frees there what that arm did not move out. A guarded arm
binds before its guard; the guard's failure edge stores each binding back into its
scrutinee place, so the next arm and the arm-end drop see the whole value.
The emission-side elaboration runs the same checks under the switch.

## Numbers

Compiler self-build, release compilers built from the same sources, one worker,
`--cc=true`, fresh out-dir, three interleaved runs each (medians; allocation columns from a
separate `SC_BUILD_MEM=1` run). Bodies: 4,369 lowered (closures included), 3,762 emitted;
532 bodies rewritten with 2,927 drops.

| Measure | Before | After |
|---------|-------:|------:|
| emission `drops` region (bounds-check elimination included) | 50.6 ms, 11,697 allocations, 18.6 MiB requested | 15.7 ms, 8,387 allocations, 4.4 MiB |
| borrow probe `drops` region (new: the elaboration of every kept body) | | 5.5 ms, 748 allocations, 0.5 MiB |
| borrow probe total | 118.4 ms | 124.9 ms |
| driver `borrowck` phase | 135.8 ms | 142.5 ms |
| driver `render` phase (emission preparation and rendering) | 215.1 ms | 182.4 ms |
| RSS at the borrowck / plan / publish boundaries | 141 / 180 / 185 MiB | 143 / 180 / 183 MiB |
| inline splices | 14,383 | 14,479 (the compiler's own sources grew) |

Bench lane (`super-c bench --bench-filter=self_transpile`, the benchmark binary built from
a checkout of the previous commit with its own compiler against the current one, three
interleaved runs each, medians):

| Row | Before | After |
|-----|-------:|------:|
| serial self-transpile | 1,812 Mcyc, 484 CPU ms, 322.4 Kalloc | 1,711 Mcyc, 459 CPU ms, 320.5 Kalloc |
| borrowck phase | 492 Mcyc, 115.1 Kalloc | 520 Mcyc, 116.2 Kalloc |
| codegen phase | 914 Mcyc, 171.4 Kalloc | 782 Mcyc, 168.4 Kalloc |
| typecheck phase | 219 Mcyc | 221 Mcyc |
| heap / peak RSS | 411 / 283 MiB | 401 / 276 MiB |

The borrow-pass row grows by the elaboration it now owns (5.7 percent of the row); the
emission row loses the duplicated forest, facts, CFG and solution for every kept body, and
the whole run is 5.6 percent cheaper in cycles and 2.5 percent in heap. The first cut of the
schedule gate asked the ownership oracle for every store destination and cost 7,228
allocations in the new region (a generic type's answer is not memoized); testing the
storage class first and skipping whole-local stores spelled with the local's type brought
it to 748.

## What is retained, and why

- The replay tape and the AST-side tracker (see the publication record).
- The emission-side elaboration for the bodies emission lowers itself: a per-instance
  re-lowering is a new body, elaborated once, before its splices.
- The inliner's `LS_INL` conversion of declared callee locals: the merged body's consumers
  still ask whether a local is declared.
