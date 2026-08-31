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
  |                          (parallel frontier under --jobs; HIR = the sugar-keyword desugar)
typecheck, per module     -- type inference, obligations, instance recording (parallel frontier)
  |
discharge_obligations     -- cross-module reflection-bound obligations, once all modules typed
  |
borrowck_all              -- lowers every body to Core IR (kept in irl::Keep), replays the
  |                          event tape, runs the loan analysis (the one other parallel stage)
[verification gates]      -- SC_FACTS_CHECK / SC_CORE_IR / SC_BORROW_IR / SC_LAYOUT / SC_CEMIT:
  |                          each pass is a NO-OP unless its env var is set
lint + panics + flush     -- lint_unused_items, check_always_panics (an error, every build),
  |                          then cir.flush_asserts / flush_consts (deferred static_asserts
  |                          and consts undecidable in module order)
runtime + external C      -- write super_rt.h/.c; ext_c_collect (@c.source wrappers, __ldflags)
  |
emission planning         -- compute_emit_live scan; Package::emit_order (Kahn, owner-first)
  |
cemit_package             -- InstGraph.collect() over the kept Core IR bodies, then per-module
  |                          TU emission (emit/tu.spc); drop elaboration runs per body here
  |                          (DropCtx::apply_drops); parallel frontier under --jobs
serial write-out          -- __sc_types.h, __sc_protos.h, per-module .h/.c, __p<k> parts,
  |                          __sc_inst.c; then prune_orphans drops stale outputs
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
- Drop elaboration is a **per-body step of emission**, not a pipeline stage.

## Identity Model

### NodeId (`u32`)

An index into a module's AST arena (`Ast.nodes: SplitVec<Node>`). Module-local. Every AST
item, expression, type annotation, and pattern is a node.

### DefId

Cross-module identity (`src/ast/ast.spc:22`):

```superc
pub struct DefId { pub module: ModuleId, pub node: NodeId }
```

Used by the resolution side table (`Ast.resolutions: SplitVec<DefId>`) to record where a
name resolves.

### TypeId (`u32`)

An index into a module's type pool. Types carry `Ty.module` (a `ModuleId`), so
`(module, TypeId)` is a global identity. `Ast::intern_type` interns: structurally equal
types share a TypeId within a module.

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
    pub syntax: Ast,    // pristine pre-lowering snapshot, only under SC_KEEP_SYNTAX=1
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

**Mangling** (`src/emit/mangle.spc`, the frozen symbol-naming authority, replay-verified
under SC_MANGLE):

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
[core-ir.md](references/core-ir.md).

**One lowering per body:** `irl::Keep` (`src/ir/lower.spc`) is a cache of spent
`Lowerer`s keyed by body. Borrowck's lowerings are recycled into it, and emission's
`InstGraph` walks those kept bodies instead of re-lowering. Bodies with `has_reflect` or
`has_zst_cond` are the exception: instances must re-lower those under their demand env.

## HIR Layer (the desugar stage)

`src/hir/lower.spc` runs **per module, after resolution, before typecheck**. The tree
everything downstream consumes is the HIR: the resolved arena with every sugar-keyword
marker lowered to core-language nodes. A sugar node is produced only by the parser and
seen otherwise only by the formatter and resolver; typecheck, borrowck, const-eval and
codegen never see one.

- `lower_to_core_call` turns a marker into a real `NODE_CALL` by seeding the callee's
  resolution to a std shim (a resolved `loader::SugarItem` from the package index — no
  name lookup) and flipping the node kind. `launch` → `SI_SUBMIT`, etc.
- `lower_select` builds nodes: every identifier it creates has its resolution seeded by
  hand.
- Batch builds lower **by move**: the parse arena becomes the HIR in place. Under
  `SC_KEEP_SYNTAX=1` the module keeps a pristine pre-lowering snapshot in
  `Module.syntax`.
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
`type_pool`, `instances`, and `const_lins` grow append-only when a later stage interns a
substituted type; an entry is never removed or renumbered.

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
   - `bc_ir_analyze` runs the loan analysis over the lowered bodies
     (`src/borrowck/facts.spc` generates dense points/origins/loans/subset edges in Core
     IR order; `loans.spc`/`dataflow.spc` solve them); `bc_ir_emit` reports.
   - Spent Lowerers are recycled into `ctx.lower_pool` and the shared `irl::Keep`.

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

Production consumer: emission's `DropCtx::apply_drops` (`src/driver/emit.spc`) builds
the move-path forest, ownership facts, CFG and move dataflow, then `elaborate_into` +
`insert_drops` rewrites the body with explicit `TM_DROP` terminators before the C
emitter renders it.

## CTFE (Compile-Time Function Evaluation)

`src/ir/interp.spc` is the Core IR interpreter — the only evaluator (the AST-based one
was deleted). It serves typechecker folds (array lengths, const args, static_assert),
`const`/`static` emission, `type_info` rendering, the `fx` scanner (const-fn
eligibility, always-panics), and lint probes.

Driver protocol: `cir.all_typed` and `record_folds` are set **before the first body
lowers** (mandatory call-site folds must behave exactly as under the backend's own
lowering); `flush_asserts` / `flush_consts` re-evaluate the deferred, module-order-
undecidable ones at the end; `report_fold_errs` surfaces emission-time fold failures.

## Monomorphization

Full monomorphization is the only generic backend.

- **During typecheck:** `close_instances` records concrete generic instantiations into
  the per-module `Ast.instances` pool; demand tables (`method_used`, `inst_methods`,
  `always_methods`, `extern_privates`) gate what emits.
- **During emission:** `cemit_package` builds an `InstGraph` (`src/graph/instances.spc`)
  seeded with the `irl::Keep` cache and calls `collect()` — it discovers every concrete
  instantiation by walking lowered Core IR bodies from concrete roots, expanding generic
  bodies under substitution frames. Keys are package-stable (decl DefId + skey per
  argument), so records from different module pools compare equal without touching any
  pool.
- **Emit order:** `Package::emit_order` — if module `a` re-homes a concrete instance of
  a generic owned by `b`, then `b` emits first. Kahn topo-sort, lowest-id tiebreak.

## Output Tree

`gen_root` defaults to `<root_dir>/build/raw`; manifest builds point it into their
out-dir. Module paths map to nested directories (`::` → `/`):

```
<gen_root>/
  super_rt.h super_rt.c    # shared runtime (allocation interposition, leak tracker)
  __sc_types.h             # ALL shared type definitions, written before any module file
  __sc_protos.h            # shared prototypes
  app.h  app.c             # per module: .h is an include shim, .c the TU body
  app__p1.c                # oversized-TU split parts (__p<k>, k from 1)
  __std/string.h  __std/string.c  # prelude: loaded under the reserved __std:: namespace
                           # so output never collides with a user std/ directory
  __sc_inst.c              # the shared cross-module instance TU (+ __sc_inst__p<k>.c)
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
