# Core IR publication: the gate, the inventory and the release point

Publishing Core IR directly after typechecking needed a measured decision, a checked
inventory of every Core IR consumer, inline fields for the semantic facts a later pass still
recovers from an AST side table, and checked release points for body syntax. This is the
record: the measurement, why the publication point inside the typecheck frontier is
not reachable, the publication point that was built (the end of each module's borrow pass,
where the module's body syntax is freed), the facts that had to become records for it, the
inventory, the tape categories, and the results.

## Where lowering runs

`run_package_i` (`src/driver/emit.spc`) types every item (the item jobs), discharges
the cross-module obligations, publishes the provisional types (checkpoint 1) and then runs the
borrow jobs. `bc_fn` (`src/borrowck/borrowck.spc`) lowers each function and its closures
first (`bc_ir_lower`), replays the tape, runs the analyses over the lowered bodies, and hands
the lowerings to `irl::Keep`. When the module's pass ends, the driver records what later
passes read of its body syntax and frees the body arena (`Ast::release_bodies`); the passes
that follow read the kept bodies, the item index, the module arenas and the records below.

## Measurement

Compiler self-build (93 modules, 4,332 functions and 13 closures), release compiler, one
worker, `--cc=true`, fresh out-dir. Switches: `SC_BORROW_STATS=1 SC_BUILD_STATS=- SC_BUILD_MEM=1`
(the probe with allocation columns), `SC_SYNTAX_STATS=1`, `SC_TYPE_STATS=1`, `SC_CEMIT_STATS=1`.
The per-consumer read counts come from a counting build (every `Ast` accessor and the two
call-info maps counted per driver phase, split by arena) that is not kept: the accessors are
`const fn` on the hot path and a counter there costs every consumer.

| Measure | Value before the change |
|---------|------:|
| Core IR lowering | 24.7 ms serial (the `lower` probe region), 22,862 allocations, 35.8 MiB requested |
| mandatory call-site folds inside lowering | 315 evaluations, 103 folded, 5,034 allocations, 966 KiB |
| Core IR output | 40,098 KiB over 4,345 bodies (exact-size kept copies), 1,148,492 type slots |
| body syntax retained from typecheck to the release | nodes 57.7 to 13.9 MiB, children 1.5 to 0.6, resolutions 8.6 to 1.3, types 4.3 to 0.7, other tables 5.1 to 1.7: 57.7 MiB freed at the release, which ran after emission planning |
| live and RSS at the boundaries | live 105 MiB at the frontend, 131 MiB after borrowck (46.5 MiB of it the borrow frontier's: kept bodies and facts), 114 MiB at the plan boundary; RSS 84, 149, 187 (before the release), 190, 195 MiB |
| the replay tape | 454,035 entries recorded by 454k pushes into the pooled Lowerer's vector (no allocation in the steady state; a do-while splices its tail once), 3.5 MiB transient (a kept copy carries no tape), replay 16 to 18 ms, 6.3k allocations (the flow-state rows) |
| type publication | checkpoint 2 remapped 609 of 4,345 kept bodies in 0.30 to 0.36 ms; a full remap of every body at checkpoint 1 projects to 2.5 ms (1.15M slots) |
| the language server (compiler workspace, one document open) | initialize 239 + 174 ms, 43.8 + 62.4 MiB retained, RSS 233 MiB; didOpen round 43 ms; body edit round 21 to 23 ms; references 255 ms. The server resolves, desugars and typechecks; it never lowers a body |
| 14 workers | typecheck 57 ms, borrowck 51 ms, checks 56 ms (lint 17 ms serial, always-panics 39 ms), total 468 ms; serial 913 ms |
| syntax scans before the first lowering | coroutine and cancellation reachability 14.9 ms (`reach` region; 2.4M body node reads), the keep's body count scan |

Side-table reads by phase, module arena / body arena, before the change (the consumers that
read a body-arena table after lowering are what the earlier release had to move):

| Phase | node | type | resolution | call_info | other typed |
|-------|-----:|-----:|-----------:|----------:|------------:|
| frontend (parse, resolve, typecheck) | 9.65M / 9.10M | 398k / 351k | 1.66M / 1.85M | 0 | deref 3.4k / 35k, coerce 0.8k / 1.1k |
| lowering | 1.19M / 3.44M | 83k / 668k | 35k / 370k | 3.8k / 45k | targs 11k / 128k, coerce 27k / 250k, dyn 27k / 245k, deref 34k / 336k, wide 4.5k / 32k, op_method 5.9k / 38k |
| tape replay | 1.44M / 860k | 196k / 257k | 80k / 514k | 3.6k / 45k | deref 150 / 271 |
| borrow analyses | 501k / 11.5k | 47k / 0 | 31k / 0 | 0 | 0 |
| reachability scans, keep sizing | 1.02M / 2.42M | 26k / 0 | 17k / 45k | 0 | 0 |
| checks (unused-item lint, always-panics, flush) | 4.03M / 284k | 17k / 0 | 290k / 602k | 861 / 0 | targs 2.5k, coerce 4.6k, dyn 4.6k, deref 6.1k, op_method 759, all module arena |
| prepare (emission liveness, emit order, constants) | 183k / 457 | 2.5k / 0 | 3.25M / 627k | 0 | 0 |
| emission | 6.65M / 0 | 191k / 0 | 304k / 0 | 127 / 0 | body arena 0 |

## The publication point

Publishing a body inside the typecheck frontier, when its module's check ends, is not
reachable in this compiler: the lowerer places a safepoint in every loop and a cancellation
check after every statement-root call from the package-wide coroutine and cancellation
reachability (`Package::co_on`, `cancel_on`), and that reachability flows from the callers
(a body is on a coroutine stack when some launch site reaches it). Under the import-first
frontier the callers of a module are typed after it, so nearly every body would publish
provisionally and re-lower once the reachability is known. The cross-module obligations
(`discharge_obligations`) and the first type publication also follow the frontier; a body
published inside it would carry provisional type ids (2.5 ms of remap) and would fold with
`all_typed` unset (a silent `const fn` failure there is a definite trap later).

The reachable point is the end of each module's borrow pass: every choice is final, the
reachability is computed at the start of the frontier, the module's bodies are lowered, kept
and analyzed, and the syntax of the whole module can go. The driver releases it there
(`borrowck_all` serial loop, `bc_run_one` per task) when `Package.free_bodies` is set, which
`run_package_i` does for every batch build except the item-index measurement (its final graph
reads the bodies). The lint driver and the test harness keep the old point. The gate for this
point was the memory the release frees before the checks phase: 58 MiB of body syntax that
had stayed live through lint, always-panics, the constant flush and emission planning.

What read a released module's body syntax after its pass, and the record that replaces it:

| Reader | Record |
|--------|--------|
| the borrow replay of every caller: `relate_result_precision` scanned the callee's `return` statements (`tc_result_attributable`) | `ItemSched.ret_attr`, one byte per item, recorded by `bc_record_ret_attr` right after the module's type check (the driver calls it after `check()`; 2 = unrecorded, so the harness and the language server scan live syntax as before) |
| `emit_order`: the generic-call sites of the module's `mono` table name body nodes | `Package.emit_deps`, the module's dependency row (`emit_dep_row`) recorded before its release; `emit_order` reads the rows and computes them itself when none were recorded |
| `lint_unused_items`: every resolution slot, attributed to its item by span | the item index's post-typecheck edges (`ItemSched.fin_edges`: each module's `module_edges` run again at the end of its type check, when the checker has added the type-path call resolutions the resolver cannot make, laid out by `build_final` after the frontier), the same attribution the index makes from the id ranges; the `method_refs` table stays (its owner is the function node) |
| `compute_emit_live`: every resolution slot | the module arena's resolutions (declarations, signatures, constants, pinned bodies, import paths) plus the post-typecheck edges' target modules; the lint driver builds the index (`build_serial`) for the same reason |
| the evaluator's folds during the borrow frontier, and the always-panics check and flush after it: `body_of` lowered an ordinary body from syntax when no view was open | the keep's view opens before the frontier (`reserve_bodies` pins every slot; `put`/`absorb` accept bodies into that reserve under the view); a job publishes its bodies into the viewed keep under the evaluator's lock, and the module's last job releases its syntax |
| the evaluator's closure call (`Interp::call` read the callee node's kind) | a callable body-arena node is a closure: no read |
| the constant pre-pass before emission (the evaluator lowered the callees of every constant from syntax after the view closed) | the pre-pass runs with the view open and `Interp.copy_kept` set: every kept hit becomes an owned compact copy (`own_kept`), then the view closes |
| the deferred `static_assert` flush: a condition inside a function body | the module keeps its bodies until the flush (`Interp::pending_in_bodies`) |

Equivalence: the previous compiler and this one emit byte-identical C over the compiler's
own sources (one worker, and fourteen under `SC_TASK_DELAY`) and over the test package;
the corpus passes; the gate's fixpoint and worker-identity steps hold. The attribution
differences that were possible in principle (a synthesized node without a span attributed
by id range instead of dropped, an import-only module row) did not change a line. The
precheck edges alone are not enough for the lint: a private associated function called
through a type path (`Type::helper()`) is resolved by the checker, not the resolver, and the
first build on those edges reported 26 used functions unused; the post-typecheck edges carry
those calls.

## Results

Release compilers over the same sources, one worker, `--cc=true` (`SC_BUILD_STATS=-
SC_BUILD_MEM=1`, so the allocation tracker is on):

| Measure | Before | After |
|---------|-------:|------:|
| live after the borrow frontier (frontend survivors + the frontier's) | 131 MiB (84 + 47) | 73 MiB (27 + 47) |
| RSS after the borrow frontier, at the plan boundary, at the publish boundary | 149, 190, 195 MiB | 140, 178, 182 MiB |
| checks phase (unused-item lint, always-panics, flush) | 87 ms (lint 17) | 66 ms (lint 5) |
| borrow frontier | 158 ms | 147 ms |
| emission liveness (`live`) | 7 to 8 ms | 4 ms |
| `lower` region allocations and requested bytes | 22,862, 35.8 MiB | 18,364, 5.2 MiB |
| 14 workers: checks, borrowck | 56, 51 ms | 41, 49 ms |

The high-water mark now sits in the plan and publish phases (kept bodies, instance graph
and emission buffers); the checks phase runs 58 MiB lighter. The per-function lowering
vector (`bc_fn` took a fresh `Vector<Lowerer>` whose first push reserved eight slots) is
owned by the module's borrow entry; the probe gained the `reach` region and the
lowered-product line (Core IR bytes, type slots, tape entries per kind), the type stats print
the keep remap per publication, and the emission stats print the lint phase and the
evaluator's body counters after borrow checking.

## Consumer inventory

Every consumer of a lowered body, the record fields it reads, what it reads outside the Core
IR record, and the condition under which that outside read could go. A consumer marked
"module arena" reads declarations (fields, variants, parameters, extend targets, names), which
the release keeps; "body arena" is the releasable syntax, which no consumer after a module's
borrow pass reads any more.

| Consumer (owner) | Core IR fields read | Reads outside the record | Removal condition |
|------------------|--------------------|--------------------------|-------------------|
| Borrow, move and drop analysis (`borrowck/flow_ir.spc`, `facts.spc`, `dataflow.spc`, `loans.spc`, `move_paths.spc`) | locals (types through the ownership oracle), places, projections, operands, `user_moves`, rvalue kinds, statements, terminators, `has_uninit_decl` | body arena of the module under analysis: the closure node's parameter count (`bc_ir_free_rules`, 11.5k reads); module arena: declaration types for the oracle, a callee's name for the `free` wording, a constant's `const` kind; the callee verdict from `ret_attr` | a `params` count on `CoreBody` (no gate: 11.5k reads inside the module's own pass) |
| Event tape (`Lowerer::tp`, `bc_replay`) | none (the tape is walk structure) | body arena of the module under analysis: 860k nodes, 257k types, 514k resolutions, 45k call records per build; every replay helper reads the AST place model; foreign modules: signatures and `ret_attr` only | every category migrates together (below) |
| C planning and rendering (`emit/cemit.spc`, `cflow.spc`, `tu.spc`, `mangle.spc`) | everything, after drop elaboration and inlining | module arena only (field and variant names, parameter types, extend targets, attributes) | none needed |
| Generic instance discovery and specialization (`graph/instances.spc`) | calls, item constants, aggregates, casts, closures, intrinsics, `targ_pool`; re-lowers `has_reflect` and `has_zst_cond` bodies (14 per build, pinned syntax) | module arena: generic parameter lists, extend targets, interface members | none needed |
| Bounds-check elimination (`ir/bce.spc`) | check intrinsics, places, operands, constants | module arena: field and function names for the report | none needed |
| Core IR inliner (`ir/inline.spc`, `InlineStore`) | kept bodies, callee signatures, `LS_INL` locals | module arena: the callee's function node and extend generics for the vet | none needed |
| Constant and `const fn` evaluation (`ir/interp.spc`) | kept bodies through the view from the borrow frontier to the constant pre-pass (3,224 kept hits, 690 fresh lowerings: 675 generic instances and 15 bodies not yet kept when a fold in the frontier needed them) | module arena: constant initializers, `const fn` bodies (pinned), variant and field declarations; body arena: none (`body_avail` refuses a released arena; a closure call reads no node) | none needed |
| Static object capture and relocations (`interp.spc`, `IN_ZEROED`, `StaticObj`) | constants, aggregates, item operands | module arena: aggregate layouts | none needed |
| `type_info` (`interp.spc` `ti_*`, `cemit.spc` registry) | `IN_TYPE_INFO` operands and the type payload in `b` | module arena: declaration names and members | none needed |
| Effect scanning (`interp.spc` `fx_scan_*`) | none: scans the function's syntax spine | body arena, at typecheck time only (the def-site `const fn` check) and under `super-c lint` (the suggestion); a fold never consults a verdict | none needed |
| Lint and diagnostic probes (`lint_body`, `fn_const_suggest`, `lint_unused_*`) | `lint_body` runs kept bodies | `lint_unused_items`: the item index edges and `method_refs`; `lint_unused_members` and `lint_unused_imports` run under the lint driver, which keeps the syntax | none needed |
| Emission liveness and order (`compute_emit_live`, `emit_order`) | none | the module arena's resolutions, the index edges, the recorded dependency rows, the type and instance tables | none needed |
| Reflection and zero-size specialization (`lower.spc` binder frames, `layout.spc`) | `has_reflect`, `has_zst_cond`, `IN_SIZEOF`/`IN_ALIGNOF` | module arena: aggregate members, generic parameters | none needed |
| IR printer, verifier and tests (`ir/print.spc`, `ir/verify.spc`, `tests/core_ir_test.spc`) | every pool | module arena: names for the print | none needed |

Two syntax consumers run before the first lowering and are not blockers: the coroutine and
cancellation reachability scans (`Package::co_compute`, `cancel_compute`, 14.9 ms, every node
of every module; lowering reads their marks to place safepoints) and `Keep::reserve_bodies`
(one pass over every node to count functions and closures).

## The semantic facts and their fields

| Fact | Where it lives in the current record |
|------|--------------------------------------|
| direct callee or indirect call | `Terminator.callee` (DefId; `NODE_NONE` marks a fn-value call with `a` the operand) |
| chosen method or operator implementation | the call's `callee` (operators lower to calls); `Rvalue.item` for `CAST_COERCE_FROM` |
| final generic and const arguments | `targ_pool` ranges on calls and item constants |
| source and destination type of a coercion | `RV_CAST` operand type and `target` |
| autoref, autoderef, reborrow, receiver mode | explicit `RV_REF` / `PJ_DEREF` chains; no adjustment record survives |
| place versus value form | `Place` versus `Operand` |
| move, copy, consume intent | `OP_MOVE` / `OP_COPY`, `user_moves` bit per operand |
| lexical scope and storage lifetime events | `ST_STORAGE_LIVE` / `ST_STORAGE_DEAD` (the drop points) |
| cleanup source origins | statement and terminator spans; the tape's scope events are the AST-side duplicate the replay needs |
| dependency record | the item index's post-typecheck edges per item (the two scans that needed a record read them) and the per-module emission row |
| feature summary | computed once per body by `body_features` from the locals' types and rvalue kinds |

Every fact is explicit in the record; the dependency record is package-owned
(the item index and the emission rows) rather than a per-body field, since both readers work
per item and per module and the index already held the edges. The verifier and printer are
unchanged.

## Tape categories

Recorded by the lowerer at the walk's AST sites, consumed by `bc_replay`. Counts per build of
the compiler; the consumer is the AST-side flow tracker (`borrowck.spc`: lexical borrows and
marks, regions and lifetimes, loop rechecks, closure capture bits), which the Core IR loan
analysis does not replace.

| Category | Entries | Replay consumer |
|----------|--------:|-----------------|
| `TP_SCOPE_PUSH` / `POP` | 25,676 each | scope depth, `bc_scope_close` |
| `TP_NLL` | 70,441 | `borrow_nll_drop` over the block's statements |
| `TP_MARK_PUSH` / `POP`, `TP_CALL_MARK` | 70,724 / 42,001 / 48,244 | borrow marks and releases |
| `TP_LET`, `TP_LET_TUPLE` | 19,359 / 6 | `bc_let_post`, `bc_let_tuple_post` |
| `TP_ASSIGN_PRE` / `POST` | 9,635 each | `bc_assign_pre`, `bc_assign_post` |
| `TP_RET_VAL`, `TP_RET_POST` | 8,121 / 8,991 | `tc_check_return_lifetime`, `bc_return_post` |
| `TP_CALL` | 48,278 | `bc_call_post`, the dyn `free` receiver |
| `TP_REF`, `TP_CAST_ERASE`, `TP_SLICE`, `TP_CLOSURE` | 5,229 / 115 / 21 / 13 | `borrow_create`, `borrow_erase_origin`, `tc_slice_result_borrows`, closure replay and `bc_closure_caps` |
| `TP_FLOW_SAVE` / `ELSE` / `JOIN` | 14,499 each | flow-state save and merge across `if` |
| `TP_LOOP_PUSH` / `POP`, `TP_BODY_START` / `END` | 3,765 each | loop push and pop, the loop recheck |
| `TP_MATCH_PRE`, `TP_ARM`, `TP_ARM_END`, `TP_MATCH_POST` | 367 / 1,238 / 1,238 / 367 | match flow and pattern depths |
| `TP_CONST_MOVE` | 103 | the argument a folded call consumed |

Gate for a category: its removal must cut a measured cost (the replay's 16 to 18 ms and 6.3k
allocations, or a retained byte count) by a numeric share and leave every consumer on the
committed IR fact. No category meets it alone: every category feeds one tracker whose state
(the lexical borrow list, the region table, the AST move sets) lives in the AST place model,
so removing one category leaves the tracker reading the same syntax for the rest. The tape
retains nothing (3.5 MiB of transient capacity in the pooled Lowerers) and runs inside the
module's own pass, before its release; it stays authoritative.

## Validation

`ci/gate.sh` (the corpus, the sanitizer lanes, the bootstrap, the two-generation fixpoint,
the worker-count identity under `SC_TASK_DELAY` with the type table and item digest, the
strict C set, every target and profile, the benchmark). The measurement runs again with the
switches above. The read table needs a counting build: a static counter array indexed by
(phase, accessor, arena) incremented in `Ast::at_const`, `list`, `type_of`, `resolution_def`,
`type_args`, `coerce_of`, `dyn_use_at`, `deref_use_at`, `wide_lit_of` and the two map reads
of `TypedFacts`, with the phase index set at the driver's phase marks and around lowering,
replay and analysis in `bc_fn`; the accessors lose `const` for that build. A body read after
a module's release is a bounds abort in `Vector::at`, so the corpus and the self-build are the
running check that no reader was missed.
