# The item schedule index and the item scheduler

`src/graph/items.spc` builds the package-owned item records the item scheduler reads:
one record per package-index item (`PkgIndex.items`: every top-level and
associated declaration), stored as parallel arrays on `Package.sched` (`ItemSched`,
`src/module/loader.spc`). `src/driver/sched.spc` runs job graphs over them, and the driver's
three item stages (type check, borrow check, always-panics) are built on it. This is the
record of the measurement that gated the index, the records and the contracts every reader
and writer keeps, the scheduler, the visibility rule that replaced module-order visibility,
and the measured result.

## Measurement

`SC_ITEM_STATS=1` on a serial build (`--jobs=1 --cc=true --out-dir=<fresh>`) prints the
measurement: per-item typecheck costs (the checker times each `check_item`), per-body borrow
analysis costs (`BcStats.body_ns`), per-module always-panics and emission-seed costs, the
bodies the engine lowered from syntax during typecheck, the graph, and the schedule prediction.
The prediction is a list schedule over the precheck graph's components (the earliest-free
worker takes the earliest-ready component) with the measured costs and the measured cost of
one runtime task (0.7 to 1.0 us for launch, run and join over 20k empty tasks; the constant
`ITEM_TASK_NS` = 1000 ns), against the module-level schedule the type check ran before the
item scheduler (import-SCC levels, the prelude one sequential group).

The compiler self-build, release compiler, one worker (phase times from `SC_CEMIT_STATS`
without the measurement, `--jobs=1` / `--jobs=14`):

| Measure | Value |
|---------|------:|
| items, precheck edges, final edges, components (largest) | 6,370; 24,356; 49,485; 6,344 (5) |
| index bytes | 833 KiB with the final ranges, 440 KiB without |
| typecheck phase | 66 ms serial, 52 ms at 14 workers |
| per-item typecheck cost, summed | 58 ms; the prelude group 3 ms; the largest module (`typechecker`) 8.7 ms; the largest item (`cemit` node 6980) 4.7 ms |
| module-level schedule, predicted | 42 ms (measured 52 ms with the level barriers and the duplicate-conformance level) |
| item-level schedule, predicted | 32 ms at 2, 17 ms at 4, 9.9 ms at 8, 7.2 ms at 14 workers; critical path 4.9 ms |
| ready-job width of the item schedule (jobs ready when a worker picks) | max 1,372 to 1,545, mean 559 to 710 by worker count |
| scheduler overhead at 1 us per task | 6.3 ms over 6,347 jobs |
| resolve, per item: 3,169 items | 17 ms serial; largest item 1.1 ms; largest module 2.8 ms; 14 workers by module 2.8 ms, by item 1.5 ms |
| Core IR lowering, per body: 4,331 bodies | 21 ms serial; largest body 0.6 ms; largest module 2.9 ms; 14 workers by module 2.9 ms, by body 1.8 ms |
| bodies lowered from syntax during typecheck (dynamic edges) | 0 |
| borrow analysis: 3,762 bodies | 65 ms serial; largest body 6.3 ms; largest module (`driver::emit`) 11.5 ms; 14 workers by module 11.5 ms, by body 6.3 ms |
| always-panics, per module | 43 ms serial; `main` 27 ms (the first user of a body pays its lowering) |
| emission seed, per module | 207 ms serial; `typechecker` 29.7 ms |
| index build | 4.3 ms serial (3.5 ms of it the resolution scan, a branchy pass over 737k resolution slots); 0.7 ms at 14 workers (the scans run inside the resolve tasks); the serial self-transpile benchmark shows no measurable change (interleaved A/B: 1777 to 1786 Mcyc before, 1778 to 1780 after) |
| final ranges and hashes (on demand) | 8.3 ms and 0.9 ms serial |

The second workload, the test package (`super-c test`: 148 modules, 7,379 items, the test
functions large independent items): typecheck 59 ms serial, module levels 38.6 ms predicted,
item schedule 7.2 ms at 14 workers (ready width max 1,568, mean 753), index 925 KiB built in
4.5 ms; the always-panics frontier balances there (largest module 5.2 ms of 18 ms).

## Decision

Thresholds: accept when the predicted parallel wall-time gain of the typecheck frontier at the
reference worker count, net of the index build, is at least 5% of the parallel transpile wall
time, and the index holds under 4 MiB; reject otherwise. Predicted gain at 14 workers: 52 ms
measured minus about 8 ms predicted, minus the 0.7 ms build: about 43 ms of a 400 ms parallel
transpile (11%); 833 KiB. Accepted. The measurement also records what the index does not
change: the borrow frontier's imbalance is per body, not per item graph (a body split of the
largest module would take it from 45 ms to about 12 ms at 14 workers), the always-panics
frontier is bound by the serial first-use lowering under the engine lock, and the emission's
serial C write (160 ms) is the largest phase at 14 workers. No dynamic body edge arises during
typecheck: the deferred-constant flush and the always-panics probe are where bodies lower.

## Records

`ItemSched`, indexed by ItemId (dense, one compilation):

| Field | Content |
|-------|---------|
| `key` | stable item key: FNV over the module path, mixed with the top-level ordinal and the member ordinal (0 at top level). No node id, task order, address or type number enters, so a body edit renumbers nothing (`index_keys_and_hashes_survive_a_body_edit`) |
| `sig_hash` | the signature hash (below), filled by `finalize` |
| `pre_off`, `pre_edges` | the schedule dependency ranges: CSR by owner, targets ascending, deduplicated (the edges below) |
| `fin_off`, `fin_edges` | the final ranges, filled by `finalize` |
| `comp`, `ncomp` | the strongly connected component of each item in the schedule graph, numbered dependency-first (a callee's component before its caller's; an import or recursion cycle is one component; an extend and its members are one) |
| `cdep_off`, `cdep`; `csucc_off`, `csucc`; `citem_off`, `citem` | the component graph: per component the components it depends on, the components that depend on it, and its items ascending (CSR each) |
| `reach`, `reach_w` | per component a row of `reach_w` words: the bits of every component it depends on, transitively |
| `top_lo`, `body_hi` | the own ranges: per item the node of the top-level item before it in node order (the exclusive start of its module-arena range; a member carries its extend's), and per by_node position the largest function body block id so far (the body-arena owner search) |
| `state` | the readiness state |
| `dyn_edges` | the dynamic item edges the master engine recorded during this build (`caller << 32 \| callee`), consumed by `finalize` |
| `by_node` | each module's items ordered by declaration node, for `Package::item_of(module, node)` |
| `built`, `finalized`, `build_ns`, `final_ns`, `hash_ns` | lifecycle and timing |

The diagnostic owner of an item is its module (`ItemMeta.module`). The package owns the index
for one invocation and frees it with the package; workers read it and write disjoint states.

## Lifecycle

1. `open` after the package index exists: keys, `by_node`, the Resolved state. The resolve
   frontier opens before its tasks (each task computes its module's edges into its output);
   the serial path and the language server open after resolution.
2. `build` after resolution: `module_edges` per module, the CSR layout, the components.
   `build_serial` does both for the serial path.
3. The type checker moves each top-level item to Checking before `check_item` and to Checked
   after, members with their extend (`set_item_state_deep`); `TypeChecker.cur_item` names the
   item under check and the checker hands it to the engine per evaluation (`set_reader`).
4. The borrow check moves every item of a module to IrReady when the module's last job ends.
5. `finalize` on demand, after the checks and before the body release: the final ranges (the
   resolution tables again, now with the resolutions typecheck added, plus the dynamic edges)
   and the signature hashes. No production consumer asks yet (invalidation and instance work
   are later plans), so a build pays nothing for it; the measurement and the tests do.

The final ranges are filled a second way, without the hashes: each typecheck task runs
`module_edges` again when its module's check ends (the checker's type-path call resolutions
are in the tables by then) and `build_final` lays every module's edges out after the frontier
(`final_edges`). Those ranges serve the unused-item lint and the emission liveness scan in
place of the body arena's resolution tables, which a batch build frees after each module's
borrow pass; the lint driver builds the index for the same reason. The per-item `ret_attr` byte records the
result-attributability verdict the borrow pass reads for every call (core-ir-publication.md).
The language server opens the index after every resolve (its readiness states and node
lookup serve the engine); it builds no ranges. A round keeps every module outside the affected
set Checked and resets the set's modules to Resolved before each pass (`typecheck_set`).

## Edges

The schedule graph holds three edge kinds. `module_edges` reads one module's resolution
tables (both arenas, the contiguous prefix through raw pointers) and attributes each
resolved reference to its owner item by id range: a
parse-time item's nodes are contiguous in each arena and end at the item's node (post-order),
an extend's header (generics, target, interface) precedes its first member, and a function's
body is the run ending at its block node. A node past every range (a desugar appended later)
falls back to the declaration spans (`Spans`, built once per module). A reference to a
declaration inside the owner's own ranges (a local, a parameter, a generic) is no edge and
needs no lookup. The target is the item of the referenced declaration (`item_of`), or for a
nested declaration (a field, a variant) the item whose span holds it; a memo over (module,
node) serves the repeats. Ownership edges run from every member to its extend. Import paths
(before the first item) and synthesized nodes without a span produce no edge.

`build` adds two kinds the resolver cannot see: an edge from every extend to each of its
members (the members are checked with their extend, so its job is theirs and its component
holds them), and a dispatch edge from every item that references a type to every extend of
that type in the package (a method the checker resolves by name has no resolved reference,
and a constant fold in the referencing item may call it; the extend's target resolution, an
alias included, keys the lookup). Reachability is transitive, so an item that reaches a type
through a callee's signature reaches the extends too.

The schedule graph is conservative: a missing edge is a correctness failure, an extra edge only
costs parallelism. The final graph adds the method and field resolutions typecheck writes and
the engine's dynamic edges. Both are bounded by construction: at most one edge per (owner,
target) pair, at most one dynamic record per pair.

## Signature hash

`sig_hash` covers the item key, kind, visibility and attributes, then by kind: a function's
`extern`/variadic/`const`/`unsafe` flags, generic parameters and bounds, where clauses, the
parameter and return types from the signature metadata (`ensure_sigs`), and its owner's key; an
aggregate's member types; an extend's target and interface; a constant's, alias's or
interface's own type. Types hash structurally (`ty_hash`): kind and qualifier, then elements,
array lengths, instance bases and arguments, builtin kinds, constant values; a nominal
declaration hashes as its item key, a nested declaration (a generic parameter, a function type
node) as its owner's key with the node's offset inside the owner's text. Node ids, type
numbering, bodies, diagnostics and timing never enter. There is no signature-only pass: the
hashes read the whole-package typecheck's metadata.

## Visibility

What an item under check may read as checked is a static rule over the schedule graph
(`gitems::visible`), so one worker and every core read the same facts whatever their
interleaving. Item `target` is visible to item `reader` when it is a transitive dependency
(`ItemSched.reach`: one bit row per component, built by `build` in one pass over the
dependency-first numbering, each dependency's finished row folded in), when both share a
component and `target` precedes `reader` in index order (a component's items are checked in
index order in one job), or when `target` is a prelude item and `reader` is not (every
prelude component completes before any other job starts). Anything else is unchecked to the
reader: the engine refuses its body (`body_of`) and reads its types as unknown (`tof`, the
lowerer's `unchecked_view`), and the checker's one foreign checked-type read (a foreign
closure's capture types) answers `TYPE_NONE`. A refusal is retried by the deferred flush
after the stage, never a false value or diagnostic. The checker names the reader on the
engine under the engine lock for every evaluation it requests (`Interp::set_reader`: the item
and its reach bits; `ev`, `ev_static`, `fn_recheck_as`) and clears it after; every stage
after the type check evaluates as no item (everything visible). The language server opens
the index without the component graph, and there the readiness state decides, as its
module-order passes require.

The rule replaced module-order visibility (a lower-indexed module fully checked, a
higher-indexed one unchecked, workers waiting for a module's completion): the waits could
deadlock against item-level dependencies across an import cycle, and a live readiness read
would make a fold's outcome depend on worker order. Two consequences on the corpus: an item's
constant fold now reaches a callee in a higher-indexed module of an import cycle (the
`item_jobs_fold_across_an_import_cycle` test: an array length folds where it was refused),
and a non-item node (`static_assert`) is checked after the module's items, seeing every item
the module depends on and the module's own.

A declaration's type slot has one writer, the item that owns the declaration (`decl_is_own`:
the item's module-arena range, its bodies, and any node appended after parsing);
`check_item` fills its parameters, fields and constants. Every other reader lowers the
declaration privately, memoized and without diagnostics (the owner reports a bad
declaration once, where it is written), so the readers' answers never depend on whether the
owner ran first.

## Readiness and the engine

States are monotone (`set_item_state` asserts it) and published with a release store after
the item's semantic writes; readers load with acquire. The batch build reads visibility, not
states (above); the language server's engine gate is `item_state(module, container item)
>= Checked`. On a refusal and on every fresh lowering the master engine records the dynamic
edge from the reader to the callee's item (`note_dyn_edge`, at most one record per pair; task
engines record nothing). The two signature states exist for a signature-first scheduler and
are not entered today.

## The scheduler

`driver::sched::Jobs` is a job graph: per job the count of dependencies still pending, the
dependents (CSR) and an estimated byte size; `run_jobs` executes it. One worker runs the
jobs in the graph's stable order on the calling thread; more run them on the production
runtime: every job whose count is zero is launched, and the job that takes a dependent's
count to zero launches it (an acquire-release decrement, so the dependency's writes are
visible to the dependent). The memory controller (`taskctl::Ctl`, `SC_BUILD_MEM_BUDGET`)
gates the estimate before a launch and releases it when the job ends; `SC_TASK_DELAY`
staggers every job by its index. There is no cancellation source in the driver: a failed
item publishes its diagnostics and the stage's result stops the build after the barrier.

Three stages run on it (`src/driver/emit.spc`):

- **Type check** (`typecheck_stage`): one job per component, edges from the component graph
  plus a virtual gate job after every prelude component and before every other one. A job
  checks its component's top-level items in index order; each item runs under its module's
  lease (a task-aware mutex: one job checks a module at a time, so the module's side tables
  have one writer), with the module's single checker, created at the module's first item
  and freed at its last. Per item the checker's diagnostics and method-mark log are swapped
  out into the item's output slot. The module's last job checks the non-item nodes, closes
  the module (`check_close`: the instance closure, the whole-module lints), records the
  result-attributability verdicts and the post-typecheck item edges. After the stage the
  coordinator publishes in module order: each module's top-level nodes in declaration
  order (an item's output, or the next non-item node's), the whole-module lints, then
  `finalize` and the log; the method marks replay in the same order through the real
  visibility checks; the edges become the final ranges. The duplicate-conformance sweep
  and `discharge_obligations` follow as before. The serial path runs the same jobs in
  order, so both paths execute one code path.
- **Borrow check** (`borrowck_all`): one independent job per module over its function,
  method, struct and enum items in source order. The pass writes diagnostics (per item),
  lowered bodies (a private keep per job, absorbed into the package keep under the engine
  lock; the serial path lowers into the package keep directly) and each closure's own
  capture facts. A job leases an oracle and pipeline slot from a bounded pool; at its end
  the module's items are IrReady, its emission dependencies recorded and its body syntax
  released. A per-body split of a module was built and measured (jobs of 2,048 estimated
  nodes, a checker pool per module, the last-use table shared per module): the bodies of
  one module intern into one type pool under one lock, and the concurrent jobs of a module
  spent forty times the lowering CPU on it (the `lower` probe region 262 ms to 10,366 ms
  of CPU at fourteen workers), so the phase took twice as long (70 ms to 142 ms) and peak
  RSS rose by 120 MiB. The module job keeps the measured phase.
- **Always-panics** (`check_always_panics`): the same jobs over the function and method
  items of the linted modules, a private engine leased per worker (budgets and the keep
  view copied from the master, statistics absorbed back), the master engine on the serial
  path. Diagnostics publish per item in declaration order.

## Design decisions, with reasons

- The type check's jobs are module-exclusive (one checker, one job at a time per module):
  the checker writes the module's side tables (the type pool under its lock, the node lists
  through a module-wide scratch, the instance, coercion, dyn, deref, call-info and operator
  records, the synthesized nodes of the format rewrite) from every item, so items of one
  module cannot check concurrently without staging every table per job. The measured item
  costs (largest item 4.7 ms, largest module 8.7 ms serial) bound what that would gain.
- The type check and the body stage keep a barrier between them: the borrow stage's lowering
  runs mandatory call-site folds under `all_typed`, and a fold's callee resolved by name
  has no schedule edge before the type check, so a fused per-body job could not decide
  deterministically what to fold.
- Closures and generated bodies are not records of their own: they are checked, lowered and
  scheduled with the item that holds them, so their key is the item's and their edges are the
  item's (there is no body ordinal). A scheduler that splits a body would add them.
- An unresolved reference (a resolve error stops a batch build; the language server builds no
  ranges) adds no conservative module edge; there is no case for one.
- The `NeedsItem` hook is the existing refusal path plus the dynamic edge record: the deferred
  fold records are the engine's pending constant and assertion lists, processed by the current
  flush in module order; no fold defers through typecheck today (0 dynamic edges), so no
  worker parks and no scratch is retained.
- Edge and record counts are bounded by construction (one per pair, pairs over the item table),
  so there is no limit to force and no diagnostic for exceeding one.

## Measured result

Release compilers built by one compiler from the same sources, `--cc=true`, medians of three
interleaved runs, the compiler's own sources (self) and the test package (tests), one and
fourteen workers; the type-check stage's rows from `SC_CEMIT_STATS` (`typecheck-stage jobs` /
`publish`); the memory rows from the allocation tracker (`SC_BUILD_MEM`, one worker).

| Measure | Before | After |
|---------|-------:|------:|
| self: typecheck phase, 1 / 14 workers | 84 / 66 ms | 86 / 43 ms (the jobs 36 ms, the publication 4 ms) |
| self: borrowck phase, 1 / 14 | 148 / 70 ms | 141 / 71 ms |
| self: resolve phase (holds the index build), 1 / 14 | 33 / 9 ms | 38 / 18 ms |
| self: transpile (stamp to sync), 1 / 14 | 704 / 580 ms | 690 / 546 ms |
| self: peak RSS, 1 / 14 | 188 / 217 MiB | 192 / 231 MiB |
| self: at the frontend boundary, 1 worker: live, requested | 109 MiB, 151 MiB | 114 MiB, 175 MiB |
| tests: typecheck phase, 1 / 14 | 85 / 60 ms | 89 / 41 ms (the jobs 33 ms) |
| tests: borrowck phase, 1 / 14 | 169 / 91 ms | 157 / 88 ms |
| tests: resolve phase, 1 / 14 | 28 / 7 ms | 34 / 15 ms |
| tests: transpile, 1 / 14 | 1,215 / 1,190 ms | 1,159 / 1,121 ms |
| tests: peak RSS, 1 / 14 | 378 / 419 MiB | 428 / 424 MiB |
| tests: at the frontend boundary, 1 worker: live, requested | 127 MiB, 711 MiB | 133 MiB, 763 MiB |
| self: schedule graph | 6,370 items, 24,356 edges, 6,344 components (largest 5), 833 KiB | 6,448 items, 61,010 edges (the dispatch and member edges), 3,107 components (largest 301: the `TypeChecker` extend with its members), 1,651 KiB plus 1.2 MiB of reachability rows freed after the stage, built in 10.7 ms |
| self: predicted item schedule at 14 workers (critical path) | 7.2 ms (4.9 ms) | 15.5 ms (17.4 ms: the largest extend is one job) |
| self: module checkers open at once in the serial order | 1 | 7 (both corpora) |

The type-check stage's fourteen-worker wall (36 ms) is above its prediction (15.5 ms): a
module's lease serializes its jobs behind its largest one, and the prediction charges no
lease waits. The serial type check pays about 2 to 4 ms for the per-item publication and the
larger index; the resolve phase pays the index build (the dispatch edges, three component
CSRs, the reachability rows). The retained memory at the frontend rises by 5 to 6 MiB (the
larger index, the shared last-use tables until the borrow pass, one open checker per pulled
module); the requested bytes by 24 to 52 MiB and the serial peak RSS by 4 MiB (self) and 50
MiB (tests), a transient of the type-check stage that the tracker's boundaries do not place
(the module checkers alive across the item order and their memo tables are the candidates).

## Validation

`tests/cli_test.spc`: `item_jobs_publish_diagnostics_in_declaration_order` (one worker and
four delayed workers print one text, a module-level `static_assert` between the items around
it) and `item_jobs_fold_across_an_import_cycle`. `tests/item_index_test.spc`: edge coverage
over cross-module and same-module calls, constants,
statics, generic templates, struct literals, field owners, methods (final graph), the generated
`format` body's prelude shim, ownership edges and no self edges; components collapse mutual
recursion and cross-module recursion, keep a `const fn` recursion inside one component and
order an interface before its conformer; keys, hashes and components survive a private body
edit; a signature edit changes that item's hash alone; states after analysis; a downward state
transition aborts (`should_panic`). `ci/gate.sh`'s worker
identity step compares the index digest (keys, hashes, edges, components, states) between one
worker and every core under randomized task timing. The emitted C and the two-generation
fixpoint are unchanged: the index reads the semantic tables and writes none.
