# Pipeline Overview

## Pipeline Overview

The compiler lowers Super-C through Core IR to LIR, optimizes LIR, emits native objects,
and links them with its own linker. `--emit-c` selects readable C11 output instead.
Stages operate on per-module data within a shared `Package`. The production pipeline
is `run_package` in `src/driver/emit.spc`:

```
prelude_stage             -- the std prelude alone: load, filter, resolve, typecheck through the
  |                          prelude gate (check_prelude), saved as an image and loaded back, or
  |                          the cached image (driver::prelude_image; stages.md)
load_user                 -- the root's module closure after the prelude (Package.root_module);
  |                          its files read and parse while the prelude checks (--jobs)
  |
platform_filter           -- @platform/@arch/@when gating: compact items by target mask; then
  |                          index_append indexes the new modules
  |
resolve + HIR, per module -- resolver::resolve, then hir::lower_module immediately after
  |                          (parallel frontier under --jobs, serial below 256 KiB of user
  |                          source: Package::analysis_jobs; HIR = the sugar-keyword desugar)
typecheck, per item       -- type inference, obligations, instance recording; item jobs over
  |                          the schedule graph's components (driver::sched), one checker per
  |                          module under its lease, visibility by the static component rule
  |                          (item-index.md); the prelude gate job publishes the prelude's
  |                          types (type-identity.md); the serial path runs the same jobs
  |                          in order
discharge_obligations     -- cross-module reflection-bound obligations, once all modules typed
  |
borrowck_all              -- lowers every body to Core IR (kept in irl::Keep, viewed by the
  |                          evaluator from here), replays the event tape, runs the loan
  |                          analysis, then elaborates each kept body's drops over the same
  |                          facts (the keep holds elaborated bodies); one independent job
  |                          per module on the same runner (a body split contends on the
  |                          module's type-pool lock, item-index.md); body syntax stays
  |                          until cemit_package releases it (syntax-ownership.md)
[verification gates]      -- SC_FACTS_CHECK / SC_LAYOUT: each pass is a NO-OP unless its env
  |                          var is set
lint + panics + flush     -- lint_unused_items, check_recursion (ir::recursion: unbounded
  |                          recursion over summaries of the kept bodies, an error, every build),
  |                          check_always_panics (an error, every build;
  |                          one job per linted module, a private engine per worker), then
  |                          cir.flush_asserts, flush_inst_asserts, cir.flush_consts
  |                          (deferred static_asserts, the per-instance asserts of generic
  |                          functions, consts a check could not fold); the interpreter reads
  |                          kept bodies through a read-only Keep view here (see Core IR)
runtime + external C      -- write super_rt.h (the runtime itself is std/rt/base.spc, a module);
  |                          ext_c_collect (@link flags into __ldflags)
  |
emission planning         -- compute_emit_live (module-arena resolutions + item index edges);
  |                          Package::emit_order (Kahn over dependency rows read from syntax);
  |                          every constant evaluated once more with the kept bodies it
  |                          touches copied into the evaluator, then the keep view closes
  |
cemit_package             -- InstGraph.collect() over the kept Core IR bodies of every module that
  |                          emits (dead prelude modules seed nothing), graph_inst_asserts
  |                          (the static_asserts of every demanded generic instance), then
  |                          Package::release_bodies frees the body syntax; then per-module
  |                          TU emission (emit/tu.spc); per body: drop elaboration only for
  |                          a body emission lowered itself, the inliner, bounds-check
  |                          elimination (DropCtx::apply_drops); parallel frontier under --jobs;
  |                          a module whose backend holds BK_LIR also lowers each body
  |                          and derived destructor to LIR (see LIR); it returns at S_LOWERED,
  |                          its emitters, lowerers, instance graph and inline store going with it
syntax_done               -- the front end's data after its last reader: the line tables, then
  |                          (unless a later stage reads them) every module's syntax and source,
  |                          the index, the item schedule and the build's evaluator, then
  |                          Global::trim gives the freed pages back (core-ir-publication.md)
lir_stage                 -- the LIR optimizer (opt-level > 0), each module's held record into the
  |                          next per-TU cache image, the LIR check (SC_LIR), the render boundary
serial write-out          -- __sc_fwd.h, one __sc_t/<type>.h per type, per-module .h, then
  |                          (--emit-c) the module TU shards (<module>.c, __p<k>), per-owner
  |                          instance shards (<module>__inst.c), __sc_registry.c and
  |                          __sc_manifest (a shard streams out as includes, head, its chunks,
  |                          tail); then prune_orphans drops stale outputs
native objects + link     -- a linking build: the generators (x64gen, a64gen, wasmgen) in
                             parallel under --jobs, then the own linker (src/link/)
```

Order facts that surprise people:

- **HIR runs inside the resolve stage**, per module, immediately after that module's
  `resolve()`, not before resolution and not after typecheck (`resolve_module`,
  `src/driver/emit.spc`).
- There is **no separate desugar pass or `src/desugar/`**: `src/hir/lower.spc` IS the
  desugar stage. The parser is `src/ast/parser.spc` (no `src/parser/` either).
- Core IR lowering happens **inside borrowck** (and again on demand during emission for
  instances); `core_ir_pass`, `layout_pass`, `cemit_pass` in the driver are env-gated
  verification reruns, not production stages.
- Drop elaboration is a **per-body step of the borrow pass** (`bc_elaborate`, right after
  the body's analyses): the keep holds elaborated bodies, the inliner splices elaborated
  callees, and emission elaborates only the bodies it lowers itself (per-instance
  re-lowerings, wrappers). It is not a pipeline stage.
- Self tail calls become jumps in the same per-body step, after drop elaboration
  (`flow_ir::bc_tail_calls`, `ir::tailcall::convert`; emission converts the bodies it
  lowers itself, before the inliner), in every profile. `@tail_recurse` errors come from
  the borrow pass; without a keep (the language server, the in-process `compile` harness) only
  a `@tail_recurse` function's bodies are elaborated and converted, for its errors.
