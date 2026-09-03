# Compiler Stages Reference

Each stage as `run_package_i` (`src/driver/emit.spc`) actually runs it, in execution
order. Env-gated verification passes are marked; they are no-ops in a normal build.

## 1. Load: Lex + Parse (`src/module/loader.spc`, `src/lexer/`, `src/ast/parser.spc`)

Module discovery from the root file's imports; import search roots are the project root,
an optional manifest `src/` root, then `std/` and `ffi/`. Directory names are sorted so
ModuleIds are deterministic regardless of readdir order. Parallel under `--jobs`.

- Lexer: byte-driven scanner over a NUL-padded source `String` (`SOURCE_PAD`). Output
  `Vector<Token>`; tokens are packed `u64` `(kind, start, len)` spans — no text copied.
  Character-class table built by `const fn`, held by value per Lexer. Every error is
  recovered; the scan always completes. `keep_trivia` (formatter path) also emits
  comment tokens.
- Parser (`src/ast/parser.spc` — there is no `src/parser/`): context-free LL(1)
  structural cover grammar, no predicates or backtracking. Output: flat AST arena
  (`Ast.nodes: SplitVec<Node>`), append-only during parsing. Sugar keywords (`launch`,
  `select`, `parallel for`, ...) parse to marker nodes; `@derive` synthesis happens here
  at parse time.

## 2. Platform Filter (`platform_filter`)

`@platform` / `@arch` gating: items are compacted out of each AST by target mask before
resolution. `--target=` / `--arch=` and `--bootstrap-tags` feed the mask.

## 3. Resolve + HIR, per module (`src/resolver/`, `src/hir/lower.spc`)

One parallel frontier; for each module, `Resolver::resolve()` runs and then
`hirl::lower_module` runs **immediately after** (`resolve_module`).

- Resolver: name binding and scopes; fills the `Ast.resolutions: SplitVec<DefId>` side
  table. Resolver-level lints run here (they must see pre-HIR syntax).
- HIR lowering IS the desugar stage: sugar-keyword markers become core nodes
  (`launch` → the `SI_SUBMIT` shim call via `lower_to_core_call`; `select` via
  `lower_select`, which builds nodes with hand-seeded resolutions). Lowering is by MOVE
  — the parse arena becomes the HIR in place; `SC_KEEP_SYNTAX=1` retains a pristine
  snapshot in `Module.syntax`. Typecheck, borrowck, const-eval and codegen never see a
  sugar node.

## 4. Typecheck, per module (`src/typechecker/`)

Parallel frontier over import levels. Type inference with expected-type propagation,
interface obligations, dispatch. Records the typed facts (per-node types, resolutions,
`call_info`, `op_method`, coercion/deref chains, captures) that `ast::facts` exposes
read-only to everything downstream. `close_instances` records concrete generic
instantiations into the per-module `Ast.instances` pool. Format-string, compound-assign
and string-switch lowering happen here. Deferred `static_assert`s that cannot be decided
in module order are queued on the interpreter.

Then `discharge_obligations`: cross-module reflection-bound obligations, once every
module is typed.

**Freeze point:** at type-check completion every semantic decision table is final; only
append-only interning (`type_pool`, `instances`, `const_lins`) may grow later
(`src/ast/facts.spc`). Under `SC_FACTS_CHECK` the driver snapshots watermarks here.

## 5. Borrow Check (`borrowck_all`, `src/borrowck/`)

The other parallel frontier. Before it starts, the driver sets `cir.all_typed` and
`record_folds` — mandatory call-site folds must behave exactly as under the backend's
own lowering, because **this stage produces the lowerings the backend reuses**.

Per function (`bc_fn`, extending `TypeChecker`):
1. `bc_ir_lower`: lower the item's bodies to Core IR; the Lowerer records an event tape
   at the walk's AST sites.
2. `bc_replay`: replay the tape — the same helper calls the deleted AST walk made,
   without traversing the expression tree.
3. `bc_ir_analyze`: the loan analysis over the lowered bodies (facts generated in Core
   IR order by `borrowck/facts.spc`; solved by `loans.spc`/`dataflow.spc`);
   `bc_ir_emit` reports.
4. Spent Lowerers are recycled into the shared `irl::Keep` cache — one lowering per
   body, reused by emission.

Declaration-level lifetime analyses (return-type elision, aggregate lifetime naming, the
modular return-lifetime check) run alongside.

## 6. Verification Gates (env-gated; no-ops otherwise)

| Gate | Pass | What it checks |
|------|------|----------------|
| `SC_FACTS_CHECK` | `facts_verify("borrowck")` | No decision table changed since typecheck |
| `SC_CORE_IR` | `core_ir_pass` | Core IR lowering coverage (`=print` dumps bodies) |
| `SC_BORROW_IR` | `borrow_ir_pass` | Borrow-IR shadow comparison |
| `SC_LAYOUT` | `layout_pass` | Every concrete pool type vs the C layout invariants |
| `SC_CEMIT` / `SC_CEMIT_TU` | `cemit_pass` / `cemit_tu_pass` | Emitter double-run hash comparison / per-TU stats |

## 7. Lint, Panic Check, Const Flush

- `lint_unused_items` (when linting).
- `check_always_panics` — an **error**, run on every build of user modules.
- `cir.flush_asserts` / `flush_consts`: the deferred static_asserts and consts
  re-evaluate now that every module is fully typed; failures carry the CTFE stack.
- Test plan construction (`--test` builds).

## 8. Runtime + External C (`write_super_rt`, `ext_c_collect`)

`super_rt.h` / `super_rt.c` are written into `gen_root` (default `<root>/build/raw`;
manifest builds point it into their out-dir). `@c.source` files and backing-header `.c`
siblings become wrapper TUs (`__ext<N>_<stem>.c`, one absolute `#include` each);
`@c.link` flags land in `__ldflags`.

## 9. Emission Planning

- `compute_emit_live`: reference scan for live modules.
- `Package::emit_order`: dependency-first module order — if module `a` re-homes a
  concrete instance of a generic owned by `b`, `b` emits first. Kahn topo-sort with a
  lowest-id tiebreak.

## 10. TU Emission (`cemit_package`, `src/emit/`)

- `ensure_sigs`, then `InstGraph` (`src/graph/instances.spc`) seeded with the `irl::Keep`
  cache; `collect()` discovers every concrete instantiation by walking the kept Core IR
  bodies from concrete roots (every concrete body of every module that emits; dead
  prelude modules seed nothing), expanding generics under substitution frames
  (package-stable keys: decl DefId + per-argument skey). Bodies flagged `has_reflect` or
  `has_zst_cond` re-lower per instance instead of sharing.
- `TuEmit` (`emit/tu.spc`) renders each module's TU into `CemitOut` buffers (`tus`,
  `tu_extra` split parts, the shared `inst_c` instance TU) — a parallel frontier under
  `--jobs`, gated by `SC_BUILD_MEM_BUDGET`.
- **Drop elaboration runs here, per body** (`DropCtx::apply_drops`): move-path forest,
  ownership facts, CFG and move dataflow, then `ird::elaborate_into` +
  `ird::insert_drops` rewrite the body with explicit `TM_DROP` terminators before
  rendering. Free-glue wrapping (`<sym>__fb`) covers user `free` bodies that skip owning
  fields.
- Symbol naming through `emit/mangle.spc` (the frozen authority): prefixing only with
  more than one non-prelude module; single-segment prefix when unique; prelude, `main`,
  and extern symbols never prefixed.

## 11. Write-Out (serial, in the driver)

Transitive TU pruning first: keep scan-live modules plus everything a kept TU spells
symbols from. Then, in emit order:

1. `__sc_types.h` (all shared type definitions) and `__sc_protos.h` (shared prototypes)
   — before any module file.
2. Per-module `.h` (an include shim) and `.c` (shim + TU body); oversized TUs split into
   `<module>__p<k>.c` parts. Module paths map to directories (`::` → `/`); the prelude
   loads under the reserved `__std::` namespace, so it lands in `__std/` and never
   collides with a user `std/` directory.
3. `__sc_inst.c` (+ `__sc_inst__p<k>.c`): the shared cross-module instance TU.
4. The per-TU cache image is published only after a fully successful emission.
5. `prune_orphans`: outputs from a previous build that this one no longer emits are
   deleted.

Under `SC_FACTS_CHECK`, `facts_verify("codegen")` runs at the end — emission must have
read the tables frozen (append-only interning is the one sanctioned growth).

## 12. Test Runner (`--test` only)

`write_test_main` synthesizes `__test_main.c`: extern wrapper prototypes, the test table
(display names `module::fn` / `module::Type::method`), and the fork-per-test runner.

## 13. C Compilation

External `cc` invocation over the emitted tree plus `$(cat __ldflags)`. Incremental,
parallel, content-fingerprinted, longest-job-first; the window is bounded by the same
`--jobs` count.
