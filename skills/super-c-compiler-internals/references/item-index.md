# The item schedule index

`src/graph/items.spc` builds the package-owned item records the semantic scheduler reads
(plan v2/8): one record per package-index item (`PkgIndex.items`: every top-level and
associated declaration), stored as parallel arrays on `Package.sched` (`ItemSched`,
`src/module/loader.spc`). This is the record of the measurement that gated it, the decision,
the records, and the contracts every reader and writer keeps.

## Measurement

`SC_ITEM_STATS=1` on a serial build (`--jobs=1 --cc=true --out-dir=<fresh>`) prints the
measurement: per-item typecheck costs (the checker times each `check_item`), per-body borrow
analysis costs (`BcStats.body_ns`), per-module always-panics and emission-seed costs, the
bodies the engine lowered from syntax during typecheck, the graph, and the schedule prediction.
The prediction is a list schedule over the precheck graph's components (the earliest-free
worker takes the earliest-ready component) with the measured costs and the measured cost of
one runtime task (0.7 to 1.0 us for launch, run and join over 20k empty tasks; the constant
`ITEM_TASK_NS` = 1000 ns), against the module schedule the typecheck frontier runs today
(import-SCC levels, the prelude one sequential group).

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
| `pre_off`, `pre_edges` | the precheck dependency ranges: CSR by owner, targets ascending, deduplicated |
| `fin_off`, `fin_edges` | the final ranges, filled by `finalize` |
| `comp`, `ncomp` | the precheck strongly connected component of each item, numbered dependency-first (a callee's component before its caller's; an import or recursion cycle is one component) |
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
   after, members with their extend (`set_item_state_deep`); `Package.cur_item` names the item
   under check for the engine.
4. The borrow check moves every item of a module to IrReady once the module's bodies are kept.
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

`module_edges` reads one module's resolution tables (both arenas, the contiguous prefix through
raw pointers) and attributes each resolved reference to its owner item by id range: a
parse-time item's nodes are contiguous in each arena and end at the item's node (post-order),
an extend's header (generics, target, interface) precedes its first member, and a function's
body is the run ending at its block node. A node past every range (a desugar appended later)
falls back to the declaration spans (`Spans`, built once per module). A reference to a
declaration inside the owner's own ranges (a local, a parameter, a generic) is no edge and
needs no lookup. The target is the item of the referenced declaration (`item_of`), or for a
nested declaration (a field, a variant) the item whose span holds it; a memo over (module,
node) serves the repeats. Ownership edges run from every member to its extend. Import paths
(before the first item) and synthesized nodes without a span produce no edge.

The precheck graph is conservative: a missing edge is a correctness failure, an extra edge only
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

## Readiness and the engine

States are monotone (`set_item_state` asserts it) and published with a release store after
the item's semantic writes; readers load with acquire. `Interp::body_of` interprets a function
body only when `item_state(module, container item) >= Checked` (the top-level item: a member's
container is its extend or interface), exactly the rule the per-module completion sets kept
before; an unchecked or failed callee is a silent refusal the deferred flush retries, never a
false value or diagnostic. On a refusal and on every fresh lowering the master engine records
the dynamic edge from `Package.cur_item` to the callee's item (`note_dyn_edge`, at most one
record per pair; task engines record nothing). The two signature states exist for a
signature-first scheduler and are not entered today.

## Deviations from the plan, with reasons

- Closures and generated bodies are not records of their own: they are checked, lowered and
  scheduled with the item that holds them, so their key is the item's and their edges are the
  item's (the plan's body ordinal is unused). A scheduler that splits a body would add them.
- An unresolved reference (a resolve error stops a batch build; the language server builds no
  ranges) adds no conservative module edge; the plan's rule has no case to apply to.
- The `NeedsItem` hook is the existing refusal path plus the dynamic edge record: the deferred
  fold records are the engine's pending constant and assertion lists, processed by the current
  flush in module order; no fold defers through typecheck today (0 dynamic edges), so no
  worker parks and no scratch is retained.
- Edge and record counts are bounded by construction (one per pair, pairs over the item table),
  so there is no limit to force and no diagnostic for exceeding one.

## Validation

`tests/item_index_test.spc`: edge coverage over cross-module and same-module calls, constants,
statics, generic templates, struct literals, field owners, methods (final graph), the generated
`format` body's prelude shim, ownership edges and no self edges; components collapse mutual
recursion and cross-module recursion, keep a `const fn` recursion inside one component and
order an interface before its conformer; keys, hashes and components survive a private body
edit; a signature edit changes that item's hash alone; states after analysis; a downward state
transition aborts (`should_panic`). `ci/gate.sh`'s worker
identity step compares the index digest (keys, hashes, edges, components, states) between one
worker and every core under randomized task timing. The emitted C and the two-generation
fixpoint are unchanged: the index reads the semantic tables and writes none.
