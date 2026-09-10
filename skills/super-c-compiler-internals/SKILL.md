---
name: super-c-compiler-internals
description: "How the Super-C compiler pipeline works: stages from lexing to linking, data structures between stages, Core IR surface, HIR layer, the freeze contract, identity model, and the package/module architecture. Use when modifying compiler passes, adding language features, or debugging compilation failures."
allowed-tools: Bash Read
---

# Super-C Compiler Internals

## Agent checklist

- Read the linked Core IR and stages reference only when the task needs them.
- Confirm pipeline order in `src/driver/emit.spc`.
- Treat typed facts and Core IR ownership rules as hard contracts.
- Run the self-hosting fixpoint procedure for compiler changes.

## Pipeline Overview

The compiler is a multi-stage transpiler: Super-C source to readable C99/C11, then an
external `cc` compiles and links the C. Every stage operates on per-module data within a
shared `Package`. The production pipeline is `run_package_i` in `src/driver/emit.spc`:

```
load                      -- module discovery, lex + parse per module (src/module/loader.spc)
  |
platform_filter           -- @platform/@arch gating: compact items by target mask
  |
resolve + HIR, per module -- resolver::resolve, then hir::lower_module immediately after
  |                          (parallel frontier under --jobs, serial below 256 KiB of user
  |                          source: Package::analysis_jobs; HIR = the sugar-keyword desugar)
typecheck, per item       -- type inference, obligations, instance recording; item jobs over
  |                          the schedule graph's components (driver::sched), one checker per
  |                          module under its lease, visibility by the static component rule
  |                          (item-index.md); the serial path runs the same jobs in order
discharge_obligations     -- cross-module reflection-bound obligations, once all modules typed
  |
borrowck_all              -- lowers every body to Core IR (kept in irl::Keep, viewed by the
  |                          evaluator from here), replays the event tape, runs the loan
  |                          analysis, then elaborates each kept body's drops over the same
  |                          facts (the keep holds elaborated bodies); one independent job
  |                          per module on the same runner (a body split contends on the
  |                          module's type-pool lock, item-index.md); a module's body syntax
  |                          is freed when its job ends (syntax-ownership.md)
[verification gates]      -- SC_FACTS_CHECK / SC_LAYOUT: each pass is a NO-OP unless its env
  |                          var is set
lint + panics + flush     -- lint_unused_items, check_always_panics (an error, every build;
  |                          one job per linted module, a private engine per worker), then
  |                          cir.flush_asserts / flush_consts (deferred static_asserts and
  |                          consts a check could not fold); the interpreter reads kept
  |                          bodies through a read-only Keep view here (see Core IR)
runtime + external C      -- write super_rt.h/.c; ext_c_collect (@c.source wrappers, __ldflags)
  |
emission planning         -- compute_emit_live (module-arena resolutions + item index edges);
  |                          Package::emit_order (Kahn over the recorded dependency rows);
  |                          every constant evaluated once more with the kept bodies it
  |                          touches copied into the evaluator, then the keep view closes
  |
cemit_package             -- InstGraph.collect() over the kept Core IR bodies of every module that
  |                          emits (dead prelude modules seed nothing), then per-module
  |                          TU emission (emit/tu.spc); per body: drop elaboration only for
  |                          a body emission lowered itself, the inliner, bounds-check
  |                          elimination (DropCtx::apply_drops); parallel frontier under --jobs
serial write-out          -- __sc_fwd.h, per-SCC <module>__types.h, per-module .h, then the
  |                          module TU shards (<module>.c, __p<k>), per-owner instance shards
  |                          (<module>__inst.c), __sc_registry.c and __sc_manifest (a shard
  |                          streams out as includes, head, its chunks, tail); then
  |                          prune_orphans drops stale outputs
cc + link                 -- external C compiler (parallel window under --jobs)
```

Order facts that surprise people:

- **HIR runs inside the resolve stage**, per module, immediately after that module's
  `resolve()` — not before resolution and not after typecheck (`resolve_module`,
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

## Identity Model

### NodeId (`u32`)

An index into one of a module's two syntax arenas. Bit 30 (`NODE_BODY`) set: the body arena
(`Ast.b`, the releasable bodies: every function body that is not generic, `const fn`, an
interface member or a member of a generic `extend`); clear: the module arena (`Ast.nodes`:
declarations, signatures, constant initializers, pinned bodies). Module-local. Every AST
item, expression, type annotation, and pattern is a node. The accessors dispatch on the bit;
a scan enumerates both arenas through `nnodes()` / `nth_id()`, and a per-node scratch table
is indexed by `dense(id)`. The driver frees the body arenas after emission planning, before
the C is planned and rendered; the driver frees each module's body arena when its borrow
pass ends; the language server frees a closed document's after every round and parses it
back on demand (`BodyArena.released`, `Interp.body_missing`); the model, the release contract
and the owned records the later passes read instead are in
[syntax-ownership.md](references/syntax-ownership.md).

### ItemId

An index into the package index's item table (`PkgIndex.items`: every top-level and associated
declaration), dense for one compilation. `Package.sched` (`ItemSched`) holds one record per
item: a stable key (module path and ordinals: no node id), a post-typecheck signature hash,
schedule and final dependency ranges, the schedule component and the component graph the
item scheduler runs, the item's own node ranges, and the monotone readiness state (Resolved,
Checking, Checked, IrReady). The constant engine and the checker decide what an item may read
as checked by the static visibility rule over the components (`graph::items::visible`: a
dependency component, an earlier item of the same component, a prelude item). Built by
`graph::items` after resolution (inside the resolve frontier's tasks); the scheduler, the
rule and the measurements are in [item-index.md](references/item-index.md).

### DefId

Cross-module identity (`src/ast/ast.spc:22`):

```superc
pub struct DefId { pub module: ModuleId, pub node: NodeId }
```

Used by the resolution side table (`Ast.resolutions: SplitVec<DefId>`) to record where a
name resolves.

### TypeId (`u32`)

An index into the package type table (`Package.tt`, a `TypePool`): structurally equal
types share one id across every module. A type interned before its publication
checkpoint gets a provisional id (bit `TYPE_PROV`) in the module's own `Ast.pool`;
`publish_types` renumbers every provisional record into the package table in a
canonical order at the start of borrow checking and again at the start of emission, and
remaps every retained table. Final ids are identical for one worker and every worker
count. The instance graph interns straight into the package table. An `Ast` without a
package (`gt == null`, unit tests) keeps module-local ids. The model, the ordering, the
validation switches and the measurements are in
[type-identity.md](references/type-identity.md).

### ModuleId (`u16`)

An index into `Package.modules`. Directory names are sorted at load so ids are
deterministic regardless of readdir order (`src/module/loader.spc`).

## Package and Module Architecture

`Package` owns all modules. One `.spc` file = one module. The prelude (`std/*.spc`) is
auto-loaded and its public decls resolve unqualified. Abridged from
`src/module/loader.spc:25`:

```superc
pub struct Module {
    pub path: String,   // "__std::string" (prelude) / "lexer::token"; root = its file stem
    pub file: String,   // filesystem path the source was read from
    pub source: String, // file contents (span offsets index into it)
    pub ast: Ast,       // parsed AST; after hir::lower runs it IS the module's HIR
    pub has_ast: bool,
    pub prelude: bool,
}

pub struct Package {
    pub modules: Vector<Module>,
    pub root_dir: String,  // imports resolve relative to it
    pub gen_root: String,  // where the emitted C tree goes (default <root>/build/raw)
    pub std_root: String,  // second import search root
    pub cir: *mut void,    // the Core IR interpreter (opaque to avoid a type cycle)
    pub jobs: u32,         // --jobs worker count (0/1 = serial)
    // ... plus demand/liveness tables: method_used, method_edges, inst_methods,
    // extern_privates, always_methods, co_spans (safepoint reachability), ...
}
```

**In-place mutation:** each stage mutates a module's Ast through a raw pointer into its
Package slot. There is no `override_ast` indirection (it was deleted); the Ast never
leaves its slot, so lookups that land back on the in-flight module read the live tree.

**Cross-module lookup:** `Package::lookup(mid, name, want_type)` finds a public top-level
decl. It is **O(1)** — a byte-exact symbol probe plus one name-map probe into the package
declaration index (`ensure_index`, built in deterministic module and source order).

**Mangling** (`src/emit/mangle.spc`, the frozen symbol-naming authority):

- Module prefixing is on only when the package holds **more than one non-prelude
  module**; single-file programs emit plain C names.
- A module prefixes with just its **last path segment** when no other non-prelude module
  shares it; the full `a__b__` path otherwise.
- Prelude modules are never prefixed. `main` is never prefixed. An extern function IS
  its C symbol: never prefixed, never suffixed.

## Core IR

The Core IR (`src/ir/core.spc`) is the typed, control-flow, non-SSA executable form
every body lowers to — one `CoreBody` per function, method, closure, or constant
initializer. Storage is dense append-only vectors of u32-indexed records with body-local
pools; no per-node heap allocation, no pointers into other stages.

It is consumed by the borrow-check loan analysis, drop elaboration, the CTFE
interpreter, the instance graph, and the C emitter. Full record layout, the statement /
terminator / rvalue kind tables, and the replay-tape events are in
[core-ir.md](references/core-ir.md). Lowering runs at the start of borrow checking, after the
whole-package typecheck, the obligation discharge and the first type publication; the
measurement that rejected an earlier publication point, the consumer inventory and the
replay-tape category table are in
[core-ir-publication.md](references/core-ir-publication.md).

**One lowering per body:** `irl::Keep` (`src/ir/lower.spc`) is a cache of spent
`Lowerer`s keyed by body. Borrowck's lowerings are recycled into it, and emission's
`InstGraph` walks those kept bodies instead of re-lowering. Bodies with `has_reflect` or
`has_zst_cond` are the exception: instances must re-lower those under their demand env.
A zero-size fold is symbolic (`has_zst_cond`) only when a generic parameter is unbound
(`Layout.unbound`); a bound type no env can lay out folds as material, the
`Mangler::is_zst` convention, so the fold never depends on which instantiation lowered a
shared variant first.

**Read-only Keep view:** between borrowck and `cemit_package` the interpreter holds
`Interp.keep_view` (`Keep.view(m, node)` resolves non-generic functions and closures);
`body_of` executes a kept `CoreBody` in place (`BODY_KEPT`-tagged slot) instead of
lowering a fresh boxed body. `Keep.viewers` counts live views; `absorb`/`put` and the
instance graph's take assert it is zero, and the driver clears the view before emission.
Per-task always-panics engines copy the view pointer and fold their counters back with
`st_absorb`. The scanner (`fx`) has no verdict that proves a body cannot reach a checked
operation, so the always-panics pass runs every candidate body.

## HIR Layer (the desugar stage)

`src/hir/lower.spc` runs **per module, after resolution, before typecheck**. The tree
everything downstream consumes is the HIR: the resolved arena with every sugar-keyword
marker lowered to core-language nodes. A sugar node is produced only by the parser and
seen otherwise only by the formatter and resolver; typecheck, borrowck, const-eval and
codegen never see one.

- `lower_to_core_call` turns a marker into a real `NODE_CALL` by seeding the callee's
  resolution to a std shim (a resolved `loader::SugarItem` from the package index — no
  name lookup) and flipping the node kind. `launch` → `SI_SUBMIT`, etc.
- `lower_select` builds nodes: every identifier it creates has its resolution seeded through
  `Ast::seed_resolution` (as do the typechecker's `format` and print rewrites). A seed is
  re-applied by `init_resolutions` and never looked up by text, so the LSP's re-resolve of a
  retained, already desugared arena keeps every synthesized binding.
- Batch builds lower **by move**: the parse arena becomes the HIR in place.
- Adding a sugar keyword = a lexer token, a parser marker, one lowering entry here, and
  a formatter arm.

Other sugar lives elsewhere: `@derive` synthesis is parse-time; `format()`, compound
assignment, and string-switch lowering happen in the typechecker.

## The Freeze Contract

From `src/ast/facts.spc` (the typed-facts boundary — the read-only interface Core IR
lowering and every later consumer reads instead of the Ast side tables):

At type-check completion every semantic **decision** table is final — nodes, children,
resolutions, per-node types, coercions, instance demands, method_refs, dyn/deref
selections, wide literals, attributes, lifetime declarations, `call_info`, `op_method`.
Every later stage reads this data frozen. The ONE sanctioned mutation is **interning**:
the module `pool` (provisional records) and the package table grow append-only when a
later stage interns a substituted type; a publication checkpoint renumbers provisional
ids into final ids and remaps every retained table in the same step, and a final id is
never removed or renumbered.

Enforcement is report-only and env-gated: under `SC_FACTS_CHECK` the driver snapshots
per-module watermarks after typecheck and verifies them **twice** — after borrowck and
after codegen.

## Borrow Checker

`src/borrowck/borrowck.spc` is a pipeline stage of its own, run after the whole package
is typed. It **extends `TypeChecker`** (same state, helpers, and diagnostics) rather
than defining a new context. Two layers:

1. **Declaration-level lifetime analyses** — elision rules on return types, aggregates
   naming the lifetime they borrow for, the modular return-lifetime check.
2. **The flow analysis**, per function (`bc_fn`):
   - `bc_ir_lower` lowers the item's bodies (closures included) to Core IR; each
     `Lowerer` also records an **event tape** at the walk's AST sites.
   - `bc_replay` replays that tape — the same helper calls the old AST walk made
     (`bc_let_post`, `bc_assign_pre`, `bc_scope_close`, ...), without traversing the
     expression tree. The AST walk itself was deleted.
   - `bc_ir_analyze` runs the analyses over the lowered bodies through one reusable
     `BorrowCtx` (`flow_ir.spc`): `body_features` reads the typed IR into feature bits
     (`FT_CARRIER`, `FT_BORROWED_PARAM`, `FT_BORROW_OP`, `FT_GENERIC`, `FT_OWNED`,
     `FT_UNINIT`, `FT_UNKNOWN`; locals' types through the ownership oracle, rvalue
     kinds, never syntax), and the two pure predicates `loan_skip` / `stage_skip` are
     the only skip decisions. A loan-skipped body gets a moves-only fact walk
     (`Owner::generate_into(.., loans=false)`: events and block ranges, no origins,
     loans, accesses, subsets, kills or liveness rows); otherwise `facts.spc` generates
     dense points/origins/loans/subset edges in Core IR order and
     `loans.spc`/`dataflow.spc` solve them. Every new loan source in `facts.spc` must
     be covered by a feature bit: `SC_BC_VALIDATE=1` runs every skipped stage anyway
     and asserts it found nothing (the gate's fixpoint and worker-identity builds run
     under it). `bc_ir_emit` reports.
   - `bc_elaborate` then classifies the body's storage markers against the same forest,
     facts and move/init solution (building the CFG and the solution when the analyses
     skipped them) and rewrites the body with `TM_DROP` terminators (`ir/drops.spc`), so
     the keep holds the elaborated body and emission never derives ownership for it
     again. `SC_BC_VALIDATE=1` also runs the structural verifier and `verify_drops` (the
     ownership verifier) over every elaborated body, checks every loan's source operation,
     every move path's parent, the init rows' sizes and each fixpoint's push bound.
   - Scratch is bounded: `BorrowCtx::trim_scratch` releases the analyses' and the
     elaboration's capacity after a body that pushed it past `BC_SCRATCH_BUDGET`.
     Published results never point into it (diagnostics are copied `FlowErr`s; kept
     bodies are `compact_from` copies).
   - Spent Lowerers are recycled into `ctx.lower_pool` and the shared `irl::Keep`.
   - Every borrow job (one per module) leases an `Owner` + `BorrowCtx` slot from a
     mutex-guarded pool (`bc_slot_take`/`bc_slot_give`: never hold the guard across the
     job), so at most one slot per concurrently running job ever exists; the serial
     path's single slot serves every body.

Callee resolution is never re-derived: the typechecker's `call_info` side table is the
bridge (`bc_call_info`).

## Drop Elaboration

`src/ir/drops.spc`: destruction is a Core IR property. The storage markers the lowerer
places at every scope exit ARE the lexical drop points; the pass classifies each against
the move/init dataflow. Five classifications:

| Kind | Meaning |
|------|---------|
| `DK_UNCOND` | Always initialized: unconditional free |
| `DK_COND` | Reachable with differing init states: one flag guards the free |
| `DK_FIELD` | Partial move upstream: drops one still-owned sub-place |
| `DK_OVER` | Assignment overwrites an initialized value: free it first |
| `DK_OVERC` | Overwrite of a maybe-moved value: the local's flag guards the free |

Production consumer: the borrow pass (`flow_ir::bc_elaborate`, `src/borrowck/flow_ir.spc`),
once per kept body, right after that body's analyses: the feature bits (an owning local) or
`ird::assign_may_schedule` (a store whose projected destination owns through auto-freeing
storage) decide whether anything can be scheduled; the rest is skipped. Otherwise the
forest, facts and move/init solution the analyses built (the CFG and the solution are
built here when a skip left them out) feed `elaborate_into` + `insert_drops(body, &mut
ElabCtx, forest)`, which rewrites the body with explicit `TM_DROP` terminators; the
scratch rides in `BorrowCtx.el` and survives across bodies. The keep holds the elaborated
body (`CoreBody.elaborated`), emission's `DropCtx::apply_drops` elaborates only a body it
lowered itself (a per-instance re-lowering, a macro wrapper) and does so BEFORE the
inliner, and the inliner's callees are elaborated bodies: a splice carries the callee's
drops, flag temps (`TM_DROP.args_start` rebases with the locals) and markers, so no
ownership analysis ever runs on a merged body. Elaboration runs once per kept lowering;
instances share it as they share the lowering. The inliner's callees come from the
package's `InlineStore` (`src/ir/inline.spc`): every kept env-free lowering is vetted once
at the start of `cemit_package` (the size gate reads `CoreBody.inline_size_ok`, recorded
before the rewrite), and the accepted ones are copied compact; no task lowers a callee
from syntax. The record of the migration, the analysis boundary and the validation
checks is [ownership-analysis.md](references/ownership-analysis.md).

## CTFE (Compile-Time Function Evaluation)

`src/ir/interp.spc` is the Core IR interpreter — the only evaluator (the AST-based one
was deleted). It serves typechecker folds (array lengths, const args, static_assert),
`const`/`static` emission, `type_info` rendering, the `fx` scanner (const-fn
eligibility, always-panics), and lint probes.

Driver protocol: `cir.all_typed` and `record_folds` are set **before the first body
lowers** (mandatory call-site folds must behave exactly as under the backend's own
lowering); `flush_asserts` / `flush_consts` re-evaluate the ones a check could not fold
(a callee outside the item's visibility) at the end; `report_fold_errs` surfaces
emission-time fold failures. During the type check the engine answers as the item under
check (`Interp::set_reader`): a body or a checked type of an item that item cannot see
(`graph::items::visible`) is a refusal, whatever a worker has done with it.

## Monomorphization

Full monomorphization is the only generic backend.

- **During typecheck:** `close_instances` records concrete generic instantiations into
  the per-module `Ast.instances` pool; demand tables (`method_used`, `inst_methods`,
  `always_methods`, `extern_privates`) gate what emits.
- **During emission:** `cemit_package` builds an `InstGraph` (`src/graph/instances.spc`)
  seeded with the `irl::Keep` cache and calls `collect()` — it discovers every concrete
  instantiation by walking lowered Core IR bodies from concrete roots, expanding generic
  bodies under substitution frames. Roots are the concrete bodies of every module that
  emits: a prelude module `compute_emit_live` marks dead seeds nothing, and the shared
  type header lists aggregates from live modules only. Keys are package ids (decl DefId +
  the final TypeId of every argument), so records from different modules compare by id.
  Only an aggregate record with a concrete pool anchor enters the planned type headers;
  every other aggregate a body names is defined by the late replay of the mangler's
  spellings, so the closure's breadth decides placement, not existence. The demand cross
  product pairs each declaration with its target's new instances only (`pair_cur`), and
  the collect line of `SC_CEMIT_STATS` reports records by kind, bodies walked, rounds
  and a budget stop; the census of per-instance re-lowerings, the decision against a
  symbolic generic IR and the measured closure blowup on width-generic code are in
  [instance-specialization.md](references/instance-specialization.md).
- **Emit order:** `Package::emit_order` — if module `a` re-homes a concrete instance of
  a generic owned by `b`, then `b` emits first. Kahn topo-sort, lowest-id tiebreak.

## Emission Buffers and Probes

`CemitOut` holds one geometrically grown buffer per TU (`TuBufs`: `tus[t]` plus
`tu_incs[t]`, `tu_heads[t][k]` per shard, `tu_tail[t]` and the chunk table
`ck_off`/`ck_end`/`ck_shard` indexed by `tu_chunks[t]`; `inst_c` with
`inst_incs`/`inst_heads`/`inst_chunks` per owner module; `fwd_h`, `types_h[m]`,
`protos_h[m]`, `registry_c`). A consumer that inspects the emitted C (the test harness,
the bench sink) must concatenate the headers, every shard head, the buffers and the
tail; the driver writes each shard piecewise (`OutFile`) and never assembles a file
image. The layout, ownership and shard rules are in
[output-layout.md](references/output-layout.md).
Symbols, type spellings and call strings render once and intern into pools
(`sym_memo`, `sx_nm_pool`, `sx_cs_pool`); a generic call's symbol interns under the
fingerprint of (callee, receiver instance, targs, env), the same key the demand dedup
uses, so only the first spelling per TU context constructs it. The recursive renderers
(`emit_operand` through inlined temporaries, `emit_region` through structured control
flow) share a nesting counter bounded by `RENDER_NEST_MAX` (256, clang's bracket depth);
past it the body fails with `nesting`.

A body renders straight into the TU buffer: `emit_body_core_cf` takes `self.out` out of
the emitter and threads it as `o: &mut String` through every statement, control-flow
and terminator renderer (the expression renderers already take `dst`), then asserts
`self.out` stayed empty before putting the buffer back. Wrappers such as `(*..)` insert
their opener at a mark (`String::insert_str`) instead of copying the text so far; a
spelling needed twice or after later text rides in the `sget`/`sput` scratch pool, never
in a fresh `String`. Rendering order is part of the contract: demands, sentinels and
static stubs record in spelling order, so a sub-expression must still spell where it
did before, only without the intermediate copy.

`src/emit/probe.spc` is the emission probe: per region (graph, acquire, relower-refl,
relower-zst, inline, drops, sym, decl, render, assemble, publish, sync) wall time, calls
and, with the allocation tracker on, allocation calls and requested bytes, plus
repeated-work tallies (bodies taken/lowered, per reason the re-lowering templates,
instances, re-lowerings, identical re-lowerings and retained bytes, rendered bytes; the
re-lowering census and the instance discovery total are in
[instance-specialization.md](references/instance-specialization.md)). Every context that
does the work (`CEmit`, `DropCtx`, the driver) carries one; shard probes merge into the
master's (the tallies always, the regions when on), and `SC_CEMIT_STATS` prints the
table. The build record (`SC_BUILD_STATS`) carries the two re-lowering counts. Off, each
operation is one branch.

## Output Tree

`gen_root` defaults to `<root_dir>/build/raw`; manifest builds point it into their
out-dir. Module paths map to nested directories (`::` → `/`):

```
<gen_root>/
  super_rt.h super_rt.c    # shared runtime (allocation interposition, leak tracker)
  __sc_fwd.h               # forward typedefs, enums, dyn/extern/const declarations, shared by every TU
  app__types.h             # complete by-value types owned by app (one header per type SCC)
  app.h  app.c             # per module: .h holds its prototypes and `_ret` typedefs, .c the TU body
  app__p1.c                # module shards (__p<k>, k from 1): the size policy's count, or the build.toml [shards] override
  app__inst.c              # generic instances, glue, constants and dyn tables app owns
                           # (+ app__inst__p<k>.c when the owner's instances need more than one shard)
  __std/string.h  __std/string.c  # prelude: loaded under the reserved __std:: namespace
                           # so output never collides with a user std/ directory
  __sc_registry.c          # ZST sentinels and the reflection registry
  __sc_manifest            # paths, content hashes, header dependencies, owners, shard counts
  __sc_shards              # the shard counts this build used; the next build starts from them
  __ext0_impl.c            # @c.source wrapper TUs (__ext<N>_<stem>.c)
  __ldflags                # one @c.link flag per line
  __test_main.c            # fork-per-test runner (--test only)
```

Dead modules are pruned transitively (scan-live plus everything a kept TU spells symbols
from), and `prune_orphans` deletes outputs a previous build wrote that this one no
longer emits.

## Key Invariants

1. **Determinism.** Two serial runs generate identical output, and `--jobs=N` is
   byte-identical to `--jobs=1`. Facts are integers in Core IR order; indexes are built
   in deterministic module and source order; hash-iteration order never leaks out.

2. **Freeze contract.** Semantic decision tables are final at type-check completion;
   append-only interning is the one sanctioned later mutation (see above).

3. **One owner.** Each mutable piece of state has one canonical owner. The package owns
   modules; a stage reaches the current module's Ast through its slot, in place.

4. **Near-zero global state.** Per-compile state lives in per-compile contexts (Lexer,
   Parser, Ast, TypeChecker, ...); const tables are built by `const fn` and held by
   value. The lone `static mut` in the compiler proper is the loader's `G_LOAD_JOBS`
   worker-count knob.
