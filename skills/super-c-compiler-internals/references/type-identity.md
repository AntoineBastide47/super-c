# Type identity: the package type table

One `TypePool` per package (`Package.tt`, `src/ast/ast.spc`) holds every type record,
instance record and const-expression form the package interns. A `TypeId` is an index
into that table: structurally equal types share one id in every module, so cross-module
identity is an integer compare and no stage re-lowers, translates or hashes a type to
find out whether two modules mean the same one. This is the record of the model, the
publication order, the validation switches and the measurements (plan v2/6, accepted
by the user over the plan's numeric gate: the earlier measurement is kept below).

## Ids

| Range | Meaning |
|-------|---------|
| `0` | `TYPE_ERROR` |
| `1 .. 18` | the builtins, in `BuiltinType` order (`TypePool::seed`) |
| final `< TYPE_MAX` | a published record of the package table |
| `TYPE_PROV` set (bit 29) | a provisional record in the interning module's own `Ast.pool`, index `id & TYPE_PROV_MASK` |

`Ast.gt` points at the package table (`Package::bind_types`, called by every loader);
an `Ast` without a package (`gt == null`, the unit tests) keeps module-local ids in its
pool and never tags them. `TYPE_MAX` (`0x1FFFFFF0`) is fatal: the inference terms keep
two tag bits above a 30-bit payload, so bit 29 is the last free tag bit.

`Ast::intern_type` (and `intern_instance`, `intern_dyn`, `intern_const_lin`) looks the
canonical record up in the package table first: a hit is the final id (`mark_used`
records it in the module's `used` list). A miss goes to the module pool under a
provisional id. Every retained per-module table (`types`, `mono`, `method_insts`,
`dyn_uses`, `coerces`, ...) may hold either kind until the next checkpoint;
`type_at`, `instance` and `const_lin_at` dispatch on the tag. `Ast.used` / `used_inst`
are the module's distinct final types in first-touch order (the enumeration the
liveness and instance scans read; there is no per-module type census any more). A
publication releases the module pool's chunks: a module that interns nothing after its
last checkpoint retains no pool at all.

## Publication

`Package::publish_types` (`src/module/loader.spc`) runs at two checkpoints through
`publish_checkpoint` (`src/driver/emit.spc`): the start of `borrowck_all` (the whole
package is typed) and the start of `cemit_package` (the whole package is borrow-checked).
Each checkpoint:

1. Collects one batch: every module's provisional records, in module order, children
   before parents (the pools are append-only, so a child's provisional index is smaller
   than its parent's); equal records from different modules collapse in the batch.
2. Computes each batch record's depth (leaves 0) and its class: **signature-reachable**
   (the closure, through `pub_children`, of every function and method parameter and
   return type of every item in the package index) or **body-only**.
3. Numbers the batch class-major, then depth-major, then by the structural key
   `PubKey` (kind, qualifier, module, then the payload words with children already
   final: element ids, array length, projection owner and binder, `(module, decl, n,
   args)` for an instance, the value of a const argument, the declaration node
   otherwise). Ties cannot occur: two records with one key are one record.
4. Remaps every module table (`Ast::publish_remap`), the constant engine (`Interp::
   remap_types`: objects, statics, substitutions, returns, lowered bodies; the call and
   item memos are cleared), the kept lowerings (`Keep::remap_types` over every
   `CoreBody`), and records `pub_map` / `pub_imap` / `pub_cmap` so `Package::map_type`
   can translate an id recorded before the checkpoint.

Final ids therefore depend only on the source: one worker, every core, a skewed task
schedule (`SC_TASK_DELAY`) and a degenerate hash (`SC_TYPE_COLLIDE`) publish the same
table byte for byte. Nominal payloads are declaration node ids, so a body-only edit
that adds no declaration node before the affected items keeps every signature-class id
and record (the cli test edits the last function of a module and checks the class-0
lines are unchanged; an edit that shifts declaration nodes moves the nominal records'
payloads, as any node-id-keyed table would).

The instance graph (`src/graph/instances.spc`) runs after the second checkpoint and
interns its substituted types straight into the package table (`intern_g`,
`intern_instance_g`, `intern_dyn_g`, `const_value_g`, `intern_clin_g`); its records are
keyed by `ArgKey { ty, val, has_val }` with final ids, and `noted` is one bitset over
final ids. `Package.tt_class` labels every final id for the dump: 0 signature class, 1
body class of the first batch, 2 a later batch, 3 interned by the instance graph.

**Rule for every array indexed by a type id:** index by `ty_dense(t)` (final ids on the
even slots, provisional ids on the odd ones), never by the raw id: a provisional id is
above `TYPE_PROV`, and a memo that grows to it costs 512 MB and half a second per
checker (`type_free_memo`, `carries_borrow_memo`, the ownership oracle's `cache_get`).
**Rule for every borrow pass outside the driver:** call `publish_checkpoint` first
(`tests/harness.spc`, `core_ir_test`, `borrow_diff_test`), as the driver does before
each borrow frontier. A harness that hands a module `Ast` out of a package
(`CompiledAst`) keeps the package alive beside it: the `Ast` reads its types through the
package table.

**Declaration types.** The owning checker records every declaration's type on its
node (`decl_type_in`: parameters, fields, constants, bindings, functions, generic
parameters, aggregates). After the first checkpoint those ids are final, so a foreign
reader takes the record of a parameter, field or constant instead of lowering its
syntax again (`decl_type_in`, and `node_type_in` for a member or return that may be a
declaration or a bare type node); before that, and for every other node, it lowers and
memoizes (`lower_memo`, `fdecl_memo`). This is what `TypeChecker` and the borrow checker
use for foreign parameters, fields and returns. Foreign lowerings of one transpile of
the compiler fell from 299,863 to 169,429, and the borrow-check phase lowers none. Only
declaration nodes carry their type in the node slot: a type node's slot holds other
facts and is never read as a type.

**Late modules.** `bind_types` binds the modules present when it runs; a module that an
import loads afterwards (`super-c lint` resolves the user closure on demand) is bound in
`add_module`. An unbound module in a bound package interns module-local ids that read
as arbitrary package records: the symptom was false owning-const lint errors on `str`
constants while the build output stayed byte-identical. `super-c lint` over the whole
tree is part of the identity protocol for that reason.

## Validation

| Switch | Checks |
|--------|--------|
| `SC_TYPE_VALIDATE=1` | after each checkpoint no module table names a provisional id (`Package::check_published`); exit 1 otherwise |
| `SC_TYPE_COLLIDE=1` | every `Ty` and `TyInstance` hashes to one bucket: identity rests on the comparisons alone |
| `SC_TASK_DELAY=1` | a deterministic per-module sleep at the start of every typecheck and borrow-check task |
| `SC_TYPE_TABLE=<path>` | the table at the end of emission, one line per id: `id class kind qualifier module payload` (children as final ids; `I module decl n args...` for an instance) |

`ci/gate.sh` runs the fixpoint and worker-identity builds under `SC_TYPE_VALIDATE` and
compares the `SC_TYPE_TABLE` dumps of one worker and every core (the many-worker build
also under `SC_TASK_DELAY`). Tests: `tests/cli_test.spc` `type_table_is_deterministic`
(one worker, four delayed workers and a colliding hash publish one table; no two
records read the same; a body-only edit keeps every signature-class line) and
`tests/ast_test.spc` `interner_survives_full_collisions` and
`interner_index_rebuilds_geometrically`.

## Measurements

`SC_TYPE_STATS=1` counts every identity path (`TS_*` in `src/ast/ast.spc`, reported by
`ty_stats_report` at the driver's phase marks and at the end of emission). Cycles come
from the sampled profile of the benchmark binary (`samply`, 100 self-transpile rounds),
not from the timers: the timed paths run 30 to 60 ns per call, the same order as two
clock reads.

Before the change, one transpile of the compiler (92 modules, release compiler,
`--jobs=1`):

| Path | Calls | Result |
|------|------:|--------|
| `intern_type` | 348k | 317k hits, 254k extra probe steps |
| `intern_instance` | 58k | 52k hits |
| structural keys (`type_skey` roots / `skey_subst` roots / nodes) | 57k / 35k / 128k | 3 ms |
| foreign type lowering (`lower_type_in` on another module's syntax) | 426k | 126k are `decl_type_in` of foreign fields, parameters and consts |
| instance graph `add` | 104k | 84% hits |

The 92 pools held 32,928 `Ty` and 6,471 `TyInstance` (814 KB, indexes 294 KB) for 8,257
structural types and 1,046 instance keys: 75% duplicates across pools. The plan's gate
asked for 5% of round cycles or 10% of allocations or memory; the sampled maximum was
2.2% of the round, so the plan's own rule rejected the interner. Two paths were
optimized under that decision and stay: `Ast::ix_rebuild` sizes the index strictly
under the 0.75 trigger (2,481 rebuilds per transpile became 432), and `fdecl_memo`
memoizes foreign declaration types. The user then asked for the table regardless of the
gate; the numbers of the accepted change are in the next section.

## Result

Three interleaved runs of the 100-round self-transpile benchmark, HEAD binary against
the package-table binary, both built by the same compiler on a quiet box (medians of
each run; the round transpiles the whole compiler and emits every module):

| Measure | HEAD | Package table | Delta |
|---------|-----:|--------------:|------:|
| CPU ms per round (three medians) | 469.6 / 450.2 / 451.5 | 460.2 / 463.0 / 461.2 | +1.0% |
| Mcyc per round | 1728 / 1685 / 1691 | 1725 / 1736 / 1728 | +1.7% |
| heap requested per round | 400.0 MiB | 418.5 MiB | +4.6% |
| peak RSS | 285.5 / 285.9 / 291.2 MiB | 258.9 / 254.6 / 254.8 MiB | -11% |
| type storage retained (one transpile) | 814 KB records + 294 KB indexes over 92 pools | 388 KB package table + 229 KB use lists | -45% |
| foreign type lowerings per transpile | 299,863 | 169,429 | -43% |
| engine build, one worker, `--cc=true` (total ms, three runs) | 2209 / 2402 / 2295 | 2161 / 2163 / 2192 | -6% |
| engine build, 14 workers | 638 / 590 / 601 | 607 / 640 / 619 | within noise |

Where the cycles went (sampled, 100 rounds, before the declaration-type table):
`publish_types` 0.6% of the round (the two checkpoints: 8,166 records batched, classed,
sorted and inserted; every module's tables remapped once), the intern path itself
cheaper than before, and the rest spread in small shares over the hot emitters and
analyses that read records through the package table (one more indirection per
`type_at`). The declaration-type table then removed 130k foreign lowerings per
transpile. Three costs were measured and removed on the way: memo arrays indexed by
the raw id grew to `TYPE_PROV` per checker (a 77 s, 8.4 GB dev build against 4.5 s,
643 MB), the module pools kept their 240 KB of chunks after publication (20.7 MB
retained, now released), and `init_types` ran twice per module.

The plan's gate (5% of cycles) is not met and was not expected to be: the user
accepted the design for its identity guarantee. The remaining levers are the
publication itself (about 3 ms per transpile), the `types` table walk of every module
at the first checkpoint, and the 131k foreign lowerings that the parallel typecheck
phase still performs before any publication.

## How to re-measure

```sh
./super-c build --profile=release -o build/sc-ts
SC_TYPE_STATS=1 SC_NO_TU_CACHE=1 build/sc-ts build --cc=true --jobs=1 --out-dir=build/tsout -o build/tsout/x
SC_TYPE_TABLE=build/tt.txt build/sc-ts build --cc=true --jobs=1 --out-dir=build/tsout2 -o build/tsout2/x
./super-c bench --no-run
samply record --save-only --unstable-presymbolicate -o build/ts.profile.json.gz build/bench-bin --filter=self_transpile
python3 skills/super-c-compiler-optimization/scripts/samply_top.py build/ts.profile.json.gz
```

The counters are process-global and not atomic: read them from a `--jobs=1` build. A
fresh `--out-dir` is required, or the emit stamp skips the transpile. Byte identity is
always the old binary against the new binary over the same current sources.
