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

The compiler is a multi-stage transpiler: Super-C source to readable C11, then an
external `cc` compiles and links the C. Every stage operates on per-module data within a
shared `Package`. The production pipeline is `run_package` in `src/driver/emit.spc`:

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
  |                          and derived destructor to LIR (see LIR)
serial write-out          -- __sc_fwd.h, one __sc_t/<type>.h per type, per-module .h, then
  |                          (--emit-c) the module TU shards (<module>.c, __p<k>), per-owner
  |                          instance shards (<module>__inst.c), __sc_registry.c and
  |                          __sc_manifest (a shard streams out as includes, head, its chunks,
  |                          tail); then prune_orphans drops stale outputs
native objects + link     -- a linking build: the LIR optimizer (opt-level > 0), the generators
                             (x64gen, a64gen, wasmgen) in parallel under --jobs, then the own
                             linker (src/link/)
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

## Identity Model

### NodeId (`u32`)

An index into one of a module's two syntax arenas. Bit 30 (`NODE_BODY`) set: the body arena
(`Ast.b`, the releasable bodies: every function body that is not generic, `const fn`, an
interface member or a member of a generic `extend`); clear: the module arena (`Ast.nodes`:
declarations, signatures, constant initializers, pinned bodies). Module-local. Every AST
item, expression, type annotation, and pattern is a node. The accessors dispatch on the bit;
a scan enumerates both arenas through `nnodes()` / `nth_id()`, and a per-node scratch table
is indexed by `dense(id)`. Module-arena id 0 is the reserved empty sentinel, but body-arena id
0 is a real node, so a per-arena scan starts at 0. A batch build frees every body arena once,
in `cemit_package` after the instance graph and its per-instance `static_assert` check,
before the C is planned and rendered; the language server frees a closed document's after every round and parses it
back on demand (`BodyArena.released`, `Interp.body_missing`); the model, the release contract
and the owned records the later passes read instead are in
[syntax-ownership.md](references/syntax-ownership.md).

A node's payload is the `NodeAs` union (`src/ast/ast.spc`), at most 20 bytes, so a node is 32
bytes. The kinds with a larger payload (asm, function, struct and enum, interface, extend,
generic parameter, the three `for` forms, closure: `ext_kind`) keep it in the `ext` table of
the node's arena (`NodeExt`); the node holds its index and, for a declaration, a copy of its
name (`ExtRef`). Read the payload with `Ast::ext(id)`, the name with `Ast::ext_name(id)`, write
with `Ast::ext_mut(id)`, and create such a node with `Ast::add_ext` (the parser's
`mk_ext`/`fin_ext`). All three panic on a node of another kind: test the kind first, also
before a `pick`, which evaluates both values. A wrong-variant read of an inline payload returns
heap-dependent bytes, which passed on macOS and Linux and failed only on Windows, in LSP
completion, constant evaluation and `dyn fn` handling. Keep every `NodeAs` member at 20 bytes
or less (`static_assert(sizeof(Node) == 32)`); a larger payload joins `NodeExt`, and rare data
goes to an `Ast` side table (a type path's associated type bindings: `Ast::type_bindings`).

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
    pub gen_root: String,  // where the emitted C tree goes (default <root>/build/<profile>/raw)
    pub std_root: String,  // second import search root
    pub cir: *mut void,    // the Core IR interpreter (opaque to avoid a type cycle)
    pub jobs: u32,         // --jobs worker count (0/1 = serial)
    // ... plus demand/liveness tables: method_used, always_methods,
    // co_spans (safepoint reachability), ...
}
```

**In-place mutation:** each stage mutates a module's Ast through a raw pointer into its
Package slot. There is no `override_ast` indirection (it was deleted); the Ast never
leaves its slot, so lookups that land back on the in-flight module read the live tree.

**Cross-module lookup:** `Package::lookup(from, mid, name, want_type)` finds a top-level decl
of module `mid` that module `from` sees (`FROM_ANY`: the compiler's own lookups, every item
visible beyond its file). It is **O(1)**: a byte-exact symbol probe plus one name-map probe into
the package declaration index (`ensure_index`, built in deterministic module and source order),
whose name maps hold every item visible beyond its file with its level (`ItemMeta.vis`), then
`Package::vis_ok`: one level compare, then a package compare (`Module.pkg`) or a prefix compare of
the asking file's path with the owner's `Module.scope`. `Package::qual_lookup` is what `m::x`
names: `m`'s own item, else one its glob imports reach (`PkgIndex.globs`); an implicit directory
index (`Module.implicit_index`, file = the directory and a `/`, source synthesized by
`loader::read_module`) reaches its files' own items and reports an ambiguity. The resolver checks
signatures for less visible types (`check_leaks`) and the typechecker field and member levels
(`field_seen`, `member_seen`).

**Mangling** (`src/emit/mangle.spc`, the frozen symbol-naming authority):

- Module prefixing is on only when the package holds **more than one non-prelude
  module besides the runtime** (`Package::rt_module`, `std/rt/base.spc`, whose own symbols
  always take its prefix); single-file programs emit plain C names, except a top-level name that a prelude
  item also has (`PkgIndex.pl_names`, the shadow set), which `Mangler::ident` escapes with `_`
  (`format` becomes `format_`).
- A module prefixes with just its **last path segment** when no other non-prelude module
  shares it; the full `a__b__` path otherwise. A user module whose first prefix segment begins
  a prelude symbol (a prelude type, interface or generic function name, or a builtin type name:
  `PkgIndex.pl_stems`, `Mangler::prelude_stem`; bit 1 of `short_table`) takes one more `_`
  after that segment: `str___len`, `Vector___i32__push`.
- Prelude modules are never prefixed. The program entry (`Package::is_entry`: the root
  module's top-level `main`, `Package.root`; each listed file of a batch lint) is never prefixed,
  and the driver renames it `__sc_user_main` under the C `main` wrapper. Every other `main` (another
  module's, a method) is an ordinary function: prefixed, unchecked against the entry signatures,
  linted. An extern function IS its C symbol: never prefixed, never suffixed.

## Core IR

The Core IR (`src/ir/core.spc`) is the typed, control-flow, non-SSA executable form
every body lowers to: one `CoreBody` per function, method, closure, or constant
initializer. Storage is dense append-only vectors of u32-indexed records with body-local
pools; no per-node heap allocation, no pointers into other stages.

It is consumed by the borrow-check loan analysis, drop elaboration, the CTFE
interpreter, the instance graph, and the C emitter. Full record layout, the statement /
terminator / rvalue kind tables, and the replay-tape events are in
[core-ir.md](references/core-ir.md). Lowering runs at the start of borrow checking, after the
whole-package typecheck, the obligation discharge and the first type publication; the
measurement that rejected an earlier publication point, the consumer inventory and the
replay-tape category table are in
[core-ir-publication.md](references/core-ir-publication.md). Vector operations reach target
instructions through the CPU feature set, the `@simd_impl` backend table and the lowering
planner: [simd-backends.md](references/simd-backends.md).

**Index operands with effects:** lowering checks an element place's bounds where it projects
the index; when a later index operand stores to a place (`v[{ v = w; 0 }]`, `writes_since`),
`recheck_indices` checks the base's projected indexes again after it, so the access traps
instead of reading past the new length.

**Layout queries in the typechecker** (the type size limit, packed-field alignment) go through
`tc_layout`, which holds the engine lock: the layout service's cache is shared by the module
jobs. A type larger than the target's `isize::MAX` sets `Layout.big`. The service reads a member's
type from its record (`Ast::member_ty`: a field's own slot, which the declaration's check writes),
and a member the check has not recorded yet answers not-ok and caches nothing (`Svc.pending`), as
`@align` does below: a static_assert evaluated before that check is deferred and folds later.

**Field order:** `src/ir/layout.spc` owns it. `sort_members` puts members in layout order (the
first `prefix` in declared order, the rest stable by alignment, largest first) and
`place_members` gives their offsets. Every stage lays out through them: the service
(`offset_in`; `decl_members` for reflection's `f.offset`; `struct_members` for `layout_pass`), the
LIR lowering (`decl_fields` and `enum_shape` through `placed`) and the C emitter (`member_order` in
`src/emit/tu.spc`, so the emitted struct lists its members in layout order and C's
`_Static_assert` checks the service). `Svc::ordered_prefix` and `payload_prefix` give `prefix`:
every member (`ORDER_ALL`) for a union, a header type, a `@packed` or `@ordered` struct and a type of
`Package.c_shaped`, else the leading `@ordered` fields (`tc_ordered`, `tc_ordered_fields` check the
tags). `driver::emit::mark_c_shaped` fills `c_shaped` (keys `module << 32 | node`) at the end of
`resolve_stage`, from the signature types of the extern and `@export` functions of the modules from
`root_module` on; the prelude image holds the prelude's set. The typechecker adds the types an
`extern "C"` call's argument points to when the parameter is `*void` or the argument is a C variadic
one (`tc_c_arg`, through casts and `unsafe`; `tc_c_reads` walks pointers, arrays and instance
arguments to declarations), logged per item (`TcMarkLog` kind 3) into `Package.c_reads`;
`mark_c_reads` adds them with their field types at the end of `typecheck_stage`. The engine's layout
service records the declarations whose order it changed (`Svc.moved`), changed the size of
(`resized`), or read offsets of (`offsets`): a newly marked one that the typecheck's evaluation read
that way is an error asking for `@ordered`, so no folded constant disagrees with the final layout. A
signature or call can mark a type of a module outside its own import closure, so
`tuc::keys_compute` folds the `c_shaped` entries of a module's import closure into its per-TU cache
key. The LIR's `fields_of` keeps declared order (drop order and
operand matching read it); `leaves` sorts by offset for the calling conventions.

**Header types:** a `struct` or `union` of an `extern "C"` block lists every member of its C
type, so the service lays it out like any struct (`@packed` and `@align` included), and an
opaque type with `@layout(size, align)` like a register type. The type spells as its tag or its
`@import` pin (`Mangler::ctype`, `driver::emit::extern_c_name`), a field as its `@import` pin
when the module has one (`Ast.has_member_pins`, `Mangler::field_ident`), and
`driver::emit::header_type_checks` writes into the forward header, after every include
(`cemit_extern_includes`): the size and alignment from `Svc::decl_layout`, each field's offset
from `Svc::decl_field_offset`, the field kinds, the `@layout` checks, and the value check of each
constant with a value (`ConstData.c_macro`, `header_const_check`). Such a constant is an ordinary
constant to every pass; its C symbol takes the `__l<node>` suffix (`Mangler::const_sym`) so it
never meets the header's macro. An extern
`enum` spells as its tag (`enum color`) or pin the same way and gets the completeness check; its
layout stays the 4-byte C enum the service models. The parser rejects a header type (`struct`,
`union` or `enum`) in a block without a header (`Parser::need_header`); the checker restricts field types to C types
(`tc_header_field`) and rejects a `Free` conformance on every type of an extern block
(`tc_extern_type`), so none has drop glue.

**One lowering per body:** `irl::Keep` (`src/ir/lower.spc`) is a cache of `KeptBody`
records (the elaborated body and its closures) keyed by body. Borrowck's lowerings are recycled into it, and emission's
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
operation, so the always-panics pass runs every candidate body, except a zero-parameter function
a call already returned from (`Interp.ran0`: a run is deterministic).

## HIR Layer (the desugar stage)

`src/hir/lower.spc` runs **per module, after resolution, before typecheck**. The tree
everything downstream consumes is the HIR: the resolved arena with every sugar-keyword
marker lowered to core-language nodes. A sugar node is produced only by the parser and
seen otherwise only by the formatter and resolver; typecheck, borrowck, const-eval and
codegen never see one.

- `lower_to_core_call` turns a marker into a real `NODE_CALL` by seeding the callee's
  resolution to a std shim (a resolved `loader::SugarItem` from the package index; no
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

From `src/ast/facts.spc` (the typed-facts boundary, the read-only interface Core IR
lowering and every later consumer reads instead of the Ast side tables):

At type-check completion every semantic **decision** table is final: nodes, children,
resolutions, per-node types, coercions, instance demands, method_refs, dyn/deref
selections, wide literals, attributes, lifetime declarations, `call_info`, `op_method`, bound
calls (`bound_calls`: the conformance a call through a generic interface's bound, an operator
through a bound, or an inherited default of a generic interface on a concrete receiver, called as a
method or through a path, dispatches to; the member resolution picks it in `tc_pick_conf_method`,
or in `tc_pick_bound_conf` when a type parameter's bounds reach the interface with several arguments),
integer pattern values (`pat_vals`). Every later stage reads this data frozen. The ONE sanctioned mutation is **interning**:
the module `pool` (provisional records) and the package table grow append-only when a
later stage interns a substituted type; a publication checkpoint renumbers provisional
ids into final ids and remaps every retained table in the same step, and a final id is
never removed or renumbered.

A batch build frees four tables, or their body-arena part, at their last reader. Each release is
a named state, `Ast::Released` (`on`, and the table's length just before and just after the
release):

| Table | Freed | Release point |
|-------|-------|---------------|
| `call_info`, `mono` | the entries of body-arena nodes | with the module's body arena (`Ast::release_body_facts`, in `bc_job` and `Package::release_bodies`) |
| `method_refs` | the whole table | after the lints (`Ast::release_checked_tables` in `run_package`; the unused-item lint is the last reader) |
| `seeds` | the whole table | at the same point (a batch build never re-resolves after its type check) |

Every later read or write of a freed part is an assertion failure (`call_info_of`,
`set_call_info`, `type_args`, `mono_slot`, `set_type_args`, `method_refs_live`,
`push_method_ref`, `seed_resolution`, `init_resolutions`). The LSP and `super-c lint` never
call these releases.

Enforcement is env-gated: under `SC_FACTS_CHECK` the driver snapshots per-module watermarks
after typecheck and verifies them **twice**: after borrowck (a difference fails the build) and
after codegen (reported). A released table must match its snapshot up to its release and its
released length after it. The check also requires each release at its point: the body facts
exactly when the body arena is released, and `method_refs` and `seeds` by the codegen check.

## Borrow Checker

`src/borrowck/borrowck.spc` is a pipeline stage of its own, run after the whole package
is typed. It **extends `TypeChecker`** (same state, helpers, and diagnostics) rather
than defining a new context. Two layers:

1. **Declaration-level lifetime analyses**: elision rules on return types (references,
   slices and lifetime-generic paths are lifetime positions, inside tuples and every type
   argument too; `Self` is never elided; a slice node carries its `[]'a T` lifetime in
   `indirect_type.lifetime` like a reference; `tc_elision_source` names the parameter an
   elided output takes), aggregates naming a declared lifetime (or `'static`) at every
   field lifetime position, the modular return-lifetime check. That check and the call
   check treat an elided input lifetime as its own anonymous universal region: only
   `'static` outlives it, and it outlives nothing else. A call whose `&mut` argument and
   stored argument are both caller parameters maps each lifetime the callee's storage
   pointee names to the caller's lifetime at the same position (`tc_caller_lts_at`) and
   requires the stored argument's lifetimes there to outlive it (`relate_store_lts_ok`).
   Store escapes have no declaration-level check: the flow analysis judges them.
2. **The flow analysis**, per function (`bc_fn`):
   - `bc_ir_lower` lowers the item's bodies (closures included) to Core IR; each
     `Lowerer` also records an **event tape** at the walk's AST sites.
   - `bc_replay` replays that tape: the same helper calls the old AST walk made
     (`bc_let_post`, `bc_assign_pre`, `tc_scope_exit`, ...), without traversing the
     expression tree. The AST walk itself was deleted.
   - `bc_ir_analyze` runs the analyses over the lowered bodies, a closure's before every body
     that can call it (children first, in source order), through one reusable
     `BorrowCtx` (`flow_ir.spc`): `body_features` reads the typed IR into feature bits
     (`FT_CARRIER`, `FT_BORROWED_PARAM`, `FT_BORROW_OP`, `FT_GENERIC`, `FT_OWNED`,
     `FT_UNINIT`, `FT_UNKNOWN`; locals' types through the ownership oracle, rvalue
     kinds, never syntax), and the two pure predicates `loan_skip` / `stage_skip` are
     the only skip decisions. A loan-skipped body gets a moves-only fact walk
     (`Owner::generate_into(.., loans=false)`: events and block ranges, no origins,
     loans, accesses, subsets, kills or liveness rows); otherwise `facts.spc` generates
     dense points/origins/loans/subset edges in Core IR order and
     `loans.spc`/`dataflow.spc` solve them. The solver keeps origin liveness, required
     points and the flood's visited set as dense bitsets over the body's points, or,
     above `SPARSE_MIN_CELLS` (2^20 origin x point cells), as sorted interval and point
     lists queried by binary search plus a hashed visited set (`Solver.sparse`); the
     block x loan scope matrix stays dense in both. Every new loan source in `facts.spc` must
     be covered by a feature bit: `SC_BC_VALIDATE=1` runs every skipped stage anyway
     and asserts it found nothing (the gate's fixpoint and worker-identity builds run
     under it). `bc_ir_emit` reports.
   - Call loans follow the callee signature: a result pins the autoref'd receiver place,
     or the pointee of a `&mut` argument (`Loan.deref`), only when the signature ties
     that parameter's lifetime to the return (`reborrow_ties`, `has_elided_lt`; elision
     rules 2 and 3), whether or not the pointee type carries borrows. The loan is exclusive
     (`LK_MUT`) when the parameter is `&mut` (or the callee a fn value) and the result grants
     write, as an autoref's is (`implicit_borrow`), else shared: `let d = r.index_mut(0);
     r.len(); *d = 1` conflicts as `(*r).index_mut(0)` does. Loans carry a
     reference level (`Loan.level`: 0 own, 1 behind one reference, 2 behind two or more, which
     saturates), so a reference's own loans and what its referents hold stay apart. A subset edge
     is a table of where it sends levels 0 and 1 (`sd_level`; `SD_KEEP`, `SD_DEREF`,
     `SD_DEREF2`, `SD_REF`, `SD_SAT`, `SD_KEEP_SAT`), composed exactly by `sd_then`; reads
     through k references are `sd_sink(k)`, stores through k are `sd_lift(k)`, and an edge
     whose depth is unknown (a fn value without lifetime classes, an undeclared parameter)
     saturates, which reproduces the two-level model and stays sound. A by-value argument tied to
     the result only through tokens behind its references (`Option<&'a K>` tied through `K`) feeds
     the result by `SD_DEREF`, not by a level-keeping edge, and a store into a `&mut` container
     follows the same rule (`Gen::own_range`, `own_walk`, `own_ties`, widened by the call's
     outlives relation; a view's type argument lies behind the view, as an index into it is a
     dereference): the argument's own references stay out of the result (`tie_depth`). Only the
     levels from the shallowest position whose token lies behind a reference of the result
     saturate (`tie_lift`: `SD_SAT` or `SD_KEEP_SAT`), so `Slice::index(&s, i)` keeps the view's
     own loan at level 0 while `[]str` elements saturate. A function-type bound (`F: fn() &'a T`) ties through the lifetimes it names
     outside its own `for<..>` (`fn_type_tokens`). As the source of a store into another
     argument, a closure passed as such an `F` brings only `F` and its bounds' result tokens when
     none of its own parameters can take a store (`callable_out_tokens`, `takes_store`: a `&mut`
     to a borrow-carrying pointee, a raw pointer, a shared reference reaching an `UnsafeCell`,
     `Owner::decl_has_cell`), so a counting comparator over references stores nothing. `&x` of a local is an ordinary loan, checked at its storage death and
     escape, and so is an array's or an owned container's slice view (`RV_SLICE` of an owned
     container is `borrow_place`): an index into a `[]T`, `[]mut T` or `str` value is a
     dereference (`Gen::behind`, `ref_steps`), and `Loan.through` marks a loan reached through
     a deref reborrow or behind a reference or view. No loan forms on a
     place reached through a raw-pointer deref (`behind_raw`). A call-entry claim or a
     two-phase activation conflicts with loans live at the claim's successor point, so
     an argument's borrow carried into the call conflicts and a copied-out value does
     not. The claims of one call share its entry point, so no loan orders them:
     `Gen::arg_clashes` compares the call's arguments pairwise (`arg_share`: 2 for a
     `&mut` or `[]mut` handed over or a `&mut` autoref, 1 for another borrow-carrying copy
     or a shared autoref, 0 for a raw-pointer erasure) and records a `BodyFacts.clashes`
     row for two overlapping places (`places_conflict`) when one of them is 2;
     `bc_ir_body` reports it. A `&mut` or `[]mut T` (`mut_view_place`) copied whole into a
     local of its own kind moves (`plain_copy`); one stored into a field, a literal member or a
     copied closure capture issues a `LK_MUT` loan on it with `deref` set (`reborrow_store`),
     held by the destination's origin, which a fn-value call passes on to its result. Only a type with an explicit `Free` (itself or a member) reads its stored
     borrows at destruction (`Owner::observes`); a closure, through the captures it owns. A
     by-reference capture (shared or mutable) also flows the captured place's origin into the
     closure origin behind the capture's reference, as `&p` does (`Gen::cap_contents`), so a call
     through the closure value returns what the place holds. A
     destruction applies only where the local may still hold a value: the walk records it as a
     `DropUse`, `bc_run_stages` solves moves before liveness when any was recorded, and
     `MoveFlow::holds_at` decides each (`BodyFacts.drop_use`, else `BodyFacts.dead_free`): a path of
     the local's subtree that may be initialized and is a leaf or not `MoveForest.covered` (a struct
     or tuple whose every member has a tracked child, `Owner::mark_covered`), so a local emptied
     member by member holds nothing. Such a
     closure local gets a drop origin (`BodyFacts.drop_origin`) with its own liveness slot past the
     locals (`drop_slot`, `nlive`): its destruction keeps that origin live, not the closure's own,
     and every flow into the closure value reaches it but the loans and copies of captures the
     destruction cannot read (`Gen::no_drop`, `Owner::cap_keep` from the closure body,
     `bc_closure_keep`). `Access.def` marks true stores for origin liveness.
   - The signature walks (`lt_tokens`, `behind_walk`, `names_static`) read a `Self` of the
     callee's signature as its extend's target type (`Gen::enter_callee`, `unself`), so a
     `Self` result, a `&mut Self` store target or a `Self` argument ties to the extend's
     lifetimes. A parameter naming `'static` flows its argument's origin into origin 0
     (`'static`; `CallSig::fl` bits from 8, the per-callee signature summary `Gen::call_sig` memoizes). An argument taken by implicit autoref for a
     `&'static` parameter gets an origin of its own holding a shared loan on the place and
     flowing into origin 0; `body_features` sets `FT_BORROW_OP` for a call to such a callee
     (`Owner::takes_static_ref`), so the body is never loan-skipped.
   - An array coerced to a slice is an explicit view temp: `RV_USE` of the array place at
     the `Slice`/`SliceMut` type, `b` = 1 (shared) or 2 (mutable). The facts treat it as
     `&a` / `&mut a` (`Gen::borrow_place`, shared with `RV_REF`): an access, an init use and
     a loan on the array place held by the view's origin, never a move. Lowering builds a
     literal coerced to a slice as an array temp, and registers an unregistered array temp
     in its scope (`own_temp`): its storage ends, and an owning one drops, at the block's end.
     The object of an index through `Index` (`mk()[1]`, `mk()[1..3]`) registers alike, as an
     operator's left operand does (`own_operand`).
     The value of an `if`, `switch` or value-block arm (`lower_value_into`) takes the conversions
     the checker recorded on the arm (`apply_adjust` on the arm block, `arm_view` when the whole
     expression is typed as the slice of the arms' arrays). A temporary that value borrows (an
     array viewed as a slice, a `&` operand: the nodes of `Lowerer.ext`, `ExtCx`) is registered in
     the scope around the whole expression (`ext_depth_for`, nested value expressions in arm-value
     position share the outermost one), so its storage ends there; an arm's own locals end with the
     arm and the loan analysis rejects a value borrowing one. A block in value position is a
     build-constant `if` or `switch` the early prune (`Package::prune_build_sites`) replaced by its
     taken arm; it lowers with the arm's extension (`ExtCx` at `ext_depth_for`), so its value's
     temporaries live as long as under a run-time condition. The emitter declares a local at its
     initializing write only when that block also dominates the storage ends of a borrowed local
     (`compute_fusion`), so the C scope holds every read through the borrow. A local read only
     through its borrows counts as read: declared apart, a struct a call returns would pass
     through a second stack slot at -O0.
   - Stores through a `&mut` argument (a signature tie to the parameter's pointee, or a
     `&mut self` receiver whose pointee holds borrows) flow into a frame-owned container at
     once; through a reference they are recorded (`StoreVia`) and `resolve_stores` resolves
     them after the walk, flow-insensitively like NLL's outlives constraints: the reference's
     origin reaches the places its loans borrow (through a reborrow's reference, what that
     reference reaches) and what its KEEP sources reach; an argument placeholder is caller
     storage. An assignment through a reference records its stores the same way
     (`store_through`: each edge the statement added into the reference's origin). A local's
     borrow reaching a placeholder is reported at the borrow (`bc_ir_escape`): through the
     return when a return carries it, else as a store into caller-visible data.
   - `bc_ir_universal` is Rust's check of universal regions: `'static`, the signature's named
     lifetimes and elided input positions, related by declared and implied bounds (`rel_widen`).
     It is per position: each origin's value has one slot per lifetime position of its type
     (`bc_uni_len`, at most `UNI_SLOTS_MAX`; the walk `bc_uni_walk` visits references, arrays,
     declarations' lifetime and type arguments, a type parameter as one slot, a function pointer
     as one slot per outer lifetime class, a `dyn fn` as its captures plus its outer classes, a
     `Box<dyn ..>` as the owned `dyn`). `UniSt` holds per slot its regions (`st`), the declared
     region (`sk`), whether caller storage holds it (`cv`), whether it is a type parameter's
     (`gen`) and its variance (`vr`). The regions flow over the subset edges,
     flow-insensitively, slot to slot along each edge's map (`bc_uni_map`, cached in `emap`): a
     copy or projection by place, a call through the callee's signature keys (`bc_uni_call_keys`,
     with Rust's elision rule, an outlives relation widened at the call, variadic arguments
     keyless), a function value's call through its class slots (`bc_uni_map_call`). An edge whose
     operation the map cannot follow is `EM_COARSE`: every region of the source reaches every
     slot of the target; the compiler and std build with none. A region arriving at a slot must
     satisfy its declared region by variance (`fails_at`: covariant outlives it, contravariant is
     outlived, invariant both); at a coarse slot it must outlive every region the slot declares.
     An edge into `'static` checks the slots of the places the operation reads (`bc_uni_static`);
     it keeps only positions behind a reference when the edge drops the value's own level and
     the place does not itself read through a reference or view (`bc_uni_through`), since the
     place's projection already left that position. Stores into a parameter's local check only its caller-visible slots (`vis`); the edge a
     mutable borrow adds back into the borrowed parameter is skipped, since the store through it
     reports where it happens. A whole assignment to a by-value parameter keeps its declared
     regions (Rust's fixed type: `x = y` between distinct elided lifetimes behind a view is an
     error), since later stores through it check those regions.
   - `bc_elaborate` then classifies the body's storage markers against the same forest,
     facts and move/init solution (building the CFG and the solution when the analyses
     skipped them) and rewrites the body with `TM_DROP` terminators (`ir/drops.spc`), so
     the keep holds the elaborated body and emission never derives ownership for it
     again. `SC_BC_VALIDATE=1` also runs the structural verifier and `verify_drops` (the
     ownership verifier) over every elaborated body, checks every loan's source operation,
     every move path's parent, the init rows' sizes and each fixpoint's push bound.
   - The AST lifetime walks take a lifetime position from every node `Node::has_lt_slot` (a
     reference, a slice, a borrowed `dyn`) and a reference's from `Node::is_ref_type` (a
     reference or a borrowed `dyn`): `&'a dyn I` is a reference to every rule.
   - `&mut` of a moved or uninitialized place is a use (`Gen::borrow_place`).
   - A store through more than one reference level (`**mm = &x`, a `&mut` field, a callee
     storing into `**x`) keeps the remaining `&mut` levels (`StoreVia.more`, `store_more`);
     `resolve_stores` follows them, and past its bound the store reaches `'static`.
   - A `dyn` or generic receiver whose interface (or bound) names a lifetime is a store target
     (`bound_tokens`: a generic parameter carries its bounds' arguments; an interface's `Self`
     carries the interface's lifetime and type arguments). So is a by-value argument whose type
     holds a `&mut` or a `[]mut` (`holds_mut`: a store reaches its referent; a `[]mut E` taken
     whole only where `E` can hold a borrow, since only its elements are written) and a reference to a
     type parameter with bounds (`bounded_param`). A shared reference is a store target
     where its pointee keeps a type argument behind an `UnsafeCell` (`Owner::interior_mask`,
     `interior_tokens`); `resolve_interior` ties the stored borrows of a channel, its
     endpoints and a `Mutex` to each other (`Gen::ties`, `istores`).
   - A closure body may not flow a parameter's placeholder into `'static`, a capture's
     placeholder or storage, or another parameter's placeholder (`bc_closure_escape`), which also
     records per parameter the captures it reaches (`Owner::cap_reach`). It also records whether the
     closure's results hold only what lies behind its by-reference captures (`Owner::res_deep`,
     `bc_closure_result`): no origin reaching a return slot is a by-value capture's, and no loan
     reaching one borrows a capture's own storage. A call through a known closure value tied only
     by a function-type bound (a type parameter with only function-type bounds that the return
     does not name) then takes what lies behind the value's references, so the capture's own
     storage stays out of the result (`Gen::closure_result_tie`); a closure not known at the call
     (`dyn fn`, a function pointer, a parameter) keeps the whole value. A capture the body writes
     into (taken by `&mut`, or held by value: the closure value keeps it across calls) maps to its
     placeholder (`Gen::cap_ph`), so a reference to the body's own copy of a capture cannot be
     stored into one. A closure whose body names a lifetime of the
     enclosing item (`Ast.closure_lts`) carries a borrow (`carries_go`), and that region seeds
     `bc_ir_universal` (`BodyFacts.named`).
   - A call through a function value follows its type's lifetime classes (`TyInstance.lts`,
     [type-identity.md](references/type-identity.md)): `Gen::value_sig` takes the signature of
     a function pointer, a `dyn fn` or a generic parameter's `fn(..)` bound (`Owner::gen_sigs`,
     which `bc_gen_sigs` fills per body), and `Gen::sig_call` flows `'static` positions into
     origin 0, stores an argument sharing a group with what a `&mut` argument (or a shared
     one's interior) points at, stores an argument at a fixed lifetime (`LC_OUTER`) through the
     callee value (`store(.., through)`: a parameter's caller storage; for a closure only the
     captures its body stores that parameter into, `StoreVia.caps`, through the loans and copy
     edges its creation tags per capture, `Gen::cap_tags`, `cap_skip`, and the closure value
     itself for a capture it owns), and
     ties the result to the callee value and the arguments in its groups. A function pointer
     with a fixed lifetime carries an origin (`carries_go`); `bc_uni_fn` gives a parameter of
     such a type (or `dyn fn`, or `F: fn(..)` bound) those regions, and `Gen::fn_type_names`
     links a `let` annotated with one to the named universal origin (`fn_type_names`: names no
     enclosing function type's `for<..>` binds; its universal origins precede every inference
     origin). A closure whose parameters name lifetimes gets
     its own signature and its classes, unpacked, for its calls (`tc_closure_sig`, in
     `Owner::gen_sigs` and `Owner::gen_cls`), and `bc_closure_escape` lets such a parameter reach
     the captures (and a `'static` one anything). With no classes the result takes the callee
     value and every argument. A call through a local holding a function item analyzes as a call
     of that function (`Gen::call_term`).
   - The typechecker checks a function value against a function type where it converts
     (`tc_lt_value_fits`): `tc_lt_pair` walks the value's own signature (`tc_own_sig` and
     `tc_item_classes` for a function or closure) beside the type's, of one shape but for
     lifetimes (`tc_same_shape`, `tc_erase_lts`), into outlives constraints (`LtSys`); a nested
     function type is compared under its own binder (`tc_lt_pair_fn`: the subtype's binder
     chooses, the supertype's gives, invariant needs one type), and `ls_solve` checks them.
     Classes are canonical in `Vector<u8>` (`LC_OUTER` = 128) and encoded into a type by
     `Ast::lts_encode` (packed, `LP_OUTER`, or class slots, `LTS_EXT`); read them with
     `Ast::sig_lt_len` and `sig_lt_class`. Two lifetimes the target type takes from outside it
     (`LS_FIXED`) that the value ties must be one, or named by the type node that writes the
     target and related by the function's bounds (`tc_lt_declared`): `TypeChecker::lt_env` holds a
     frame per expression whose context writes its type (a `let`, a return, an assignment's target
     or `*r`, a struct, variant, tuple or array literal's member, a called value's parameter, and a
     generic call's parameter its receiver's or result's written type gives, `tc_frame_call`), each
     naming an aggregate's lifetime and type parameters through the instance path of the frame
     above (`tc_frame_member`, `tc_frame_tok`); `lt_conv` is the expression a conversion is for
     (`check_expr_w`, `compatible_in`), and `tc_ann_names` reads its frame. The value's side is
     named by its declaration (`tc_frame_value`, `tc_value_names`, `LS_VNAMED`), also where both
     sides are one type (`compatible_in`: a type keeps no lifetime names). An unannotated `let` of a
     literal is pending (`LtPend`): its lifetime parameters are inference variables (`LT_VAR`
     tokens) whose pairs `lt_pool` keeps and every later conversion takes in (`tc_pool_ok`), and a
     conversion of the local binds them to the written type's lifetimes (`tc_pend_bind`); a
     target of a function's own type takes its signature's lifetimes. At a call (`TypeChecker::lt_call`), the callee's
     lifetimes are `LS_CALLEE`: chosen to fit, and what they must outlive is exported per call
     span (`Ast::call_lts`) as token pairs, which `Gen` reads (`call_lt_pairs`): a direct call
     extends its relation (`Owner::rel_extend`, then the `'static` parameters), a call through
     a value its classes (`call_lt_classes`, `tc::lt_class_tok`). The lifetime positions of a
     type come from `Package::lt_walk` (flags `LTF_*`), which reads a declaration's lifetime
     parameters from its module (`decl_nlt`) and holds one per lifetime a nested function type
     takes from outside it (`sig_outer`); `tc_lt_walk` spells them from the type node, expanding
     an alias (`tc_lt_alias`), a `Box<dyn ..>`'s argument and a nested function type
     (`tc_lt_nested` replays its walk; `LtWalk.recs` records what spells each position), and
     `tc_lt_subst_nested` carries them through substitution. A struct, enum or instance position
     takes its slot's inferred variance (`TypeChecker::variance_infer`, passed as
     `loader::SlotVariance`; a `*mut T` field is invariant in `T`, a bivariant slot counts as
     invariant). Past the last class (`LC_TOO_MANY`: 126 groups chosen at each call, 127 fixed
     outside) a type or a function value is an error, and a substitution gives `LTS_WIDE`, which
     no call or conversion accepts. A mismatch prints a type as a declaration writes it
     (`tc_type_text`, `tc_value_text` through an unannotated `let` and a field with its base's
     lifetime arguments, `render_slot_str`), since a type keeps no lifetime names; else
     `render_sig_lts` names a lifetime from outside the type `'1`, `'2`, .., and a nested
     function type's own under a `for<..>`.
   - Scratch is bounded: `BorrowCtx::trim_scratch` releases the analyses' and the
     elaboration's capacity after a body that pushed it past `BC_SCRATCH_BUDGET`.
     Published results never point into it (diagnostics are copied `FlowErr`s; kept
     bodies are `compact_from` copies).
   - Spent Lowerers are recycled into `ctx.lower_pool` and the shared `irl::Keep`.
   - Every borrow job (one per module) leases an `Owner` + `BorrowCtx` slot from a
     mutex-guarded pool (`bc_slot_take`/`bc_slot_give`: never hold the guard across the
     job), so at most one slot per concurrently running job ever exists; the serial
     path's single slot serves every body. A slot returned after every job has leased one
     has no next lease and is freed at once (`BcPool.unleased`), except under
     `SC_BORROW_STATS` or `SC_ITEM_STATS`, whose reports read every slot after the stage.
     The always-panics engines follow the same rule: an engine returned after the last
     lease folds its counters and fold failures into the master (`st_absorb`) and is freed.

Callee resolution is never re-derived: the typechecker's `call_info` side table is the
bridge (`bc_call_info`).

Lifetimes are erased structurally: no `Ty` or `TyInstance` carries a region, except a
function-pointer signature's lifetime classes (`TyInstance.lts`, 0 on every other record;
[type-identity.md](references/type-identity.md)). The parser keeps a declaration's
lifetime parameters in a separate list (`Ast::set_lifetimes`, `lifetimes_of`), so
`generics` holds only mono-relevant parameters. Variance has little to act on, because
aggregate lifetime arguments are erased.

Rules for a new borrow or region rule:

- Measure over-rejection on the compiler and `std` first. Receiver-level heuristics ("any
  `&` argument to a borrow-carrying receiver is stored") rejected the compiler's own
  source and were reverted. The fixes that held changed the model (where a borrow is
  rooted, reborrow versus fresh borrow), not the engine.
- `str` is a long-lived field type (`self.source: str`). A rule that pins every `str`
  producer over-rejects. A borrow-carrying result of a method pins its receiver only when the
  receiver carries no borrow (`String::as_str` pins the `String`); a borrow-carrying receiver
  passes its region through (the result-pin step in `src/borrowck/borrowck.spc`,
  `pin_view` in `src/borrowck/facts.spc`). Structural slicing (`RV_SLICE`) of an owned
  container always borrows the container.
- A point-set (MIR-style) region engine was measured: about 15 NLL divergence cases, all
  accepted already. Do not build one without a concrete over-rejection.

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

A guard flag is true while its local holds a value: set at entry for an argument only, after a
whole-local store and before a call that writes the whole local; cleared at entry for every other
local, at its storage-live and after every whole-value move. A temporary of a short-circuit operand
(`c || mk().ok()`) is therefore freed only when that operand ran.

Type parameters own: the ownership oracle (`Owner::owns` / `param_owns` in
`borrowck/facts.spc`, mirrored by the checker's `tc_type_is_free` / `tc_param_owns`) answers
true for a type parameter unless its bounds reach `Copy` (inline, through the function's
`where` clause recorded at parse time in `Ast.where_bounds`, or through a superinterface) or it
has a plain `fn` bound; a generic aggregate judges its members under the argument frame. So a
generic body gets moves and `TM_DROP`s for its `T` values once, and every instance shares that
elaborated body. Emission decides per instance: `CEmit::drop_emits_nothing` resolves the dropped
place's type under the instance substitution and emits nothing when it owns nothing (a scalar,
a reference, a plain struct); the fold scans skip such drops too, so a scalar instance compiles
to the same C as before. A zero-length array of an owning element (`[String; 0]`, or a struct
whose only owning member is one) moves like its element but frees nothing: `is_destructible`
answers false for it, so its drop and its glue emit no code over storage that does not exist.
A `&dyn I` or `&mut dyn I` owns nothing (`Ty::dyn_owns`, which the checker's `tc_type_is_free_impl`,
the borrow checker's `owns_raw` and the emitter's `is_destructible_raw` share). A drop of a pointer
to an array (`Box<[T; N]>`) frees the elements in a loop over the pointee (`array_free`, through the
wrapper struct's `.e` when `ptr_wraps`). A local never takes a spelling the generated C owns
(`CEmit::generated_spelling`: `__` anywhere, `_` and an uppercase letter, `str`, `size_t`, `intN_t`):
it is spelled `_<id>`.

The emitter spells an integer comparison that the range of an operand's C type decides against a
constant (`u < 0`, `i8 >= -128`, `u64 <= u64::MAX`, a const-generic bound, a folded array length,
seen through inlined copies and value-preserving casts) as its result with the operand still
evaluated, `((void)(x), false)` (`CEmit::cmp_fold`), and only where C compares exact values.
gcc's and clang's `-Wtype-limits` (in `-Wextra`) reject the tautology otherwise; every other
comparison keeps its spelling. A constant is every operand C reads as an integer constant
expression: a literal, a folded count or parameter, `~c`, a cast of a constant (converted to the
target width as C converts it) and a plain C operator over two constants (`(intptr_t)(~0ULL >>
1)`; `c_const_op`), evaluated from the constants' values. A named constant item (`isize::MAX`)
spells its global symbol, which C does not read as a constant. A `const` of a scalar, a
payload-free enum, `str` or an array of them is a read-only C object: its definition and every
`extern` declaration say `const` (`CEmit::stat_specs`, `stat_ro`), so the C compiler keeps its
loads out of the alias analysis (a non-LTO MinGW lexer object: 111 to 62 loads of
`TOKEN_MAX_LEN`); a constant of any other type (a struct may hold an `UnsafeCell`) and every
`static mut` stay writable. A literal's exact value comes from
`Constant::int_value` (`val` holds only the plain decimal case); `arith_fn` reads a constant shift
count or divisor the same way, so a hex count past the width reaches the checked helper. `Copy` itself is derived in the checker (`tc_copy_marker`, answered in
`type_satisfies`); an explicit `extend X as Copy {}` is checked against the derivation
(`check_copy_conformance`).

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
before the rewrite; an `@always_inline` callee passes it, as std's view `index_range` methods do so
their guards fold against the caller's facts), and the accepted ones are copied compact; no task
lowers a callee from syntax. The store also vets every conformance's method (a call through its interface
reaches it). A callee generic over a const parameter splices with each read of the parameter
(and each `{N / 2}` form in its types) replaced by the bound value, or by a read of the caller's
own parameter when the binding is that parameter; a switch on such a parameter then reads a
constant and `CFlow` lays out its one arm, and a callee past the size gate with such a switch is
sized per call by the arms its bindings take (`live_size`). A callee with a vector parameter or
result takes four times the size limits, and a caller that holds a vector four times the splice
budget (`VEC_SCALE`). The splice translates every type, type
argument, receiver and interface, so an inner call to a generic, private or interface function
spells and demands in the caller's unit; an associated function of a generic extend whose call
names its receiver by no type stays out (`env_receiver`), and a module's constants and statics
splice as the caller's own static references. A callee that needs either (an inner call another
than a concrete public or non-variadic extern function, or a static reference) inlines only
into a caller that holds a vector (`CalleeInfo.vec_only`, `inl::holds_vector`): the compiler's own
emitted C keeps its size, and vector kernels inline their helpers. A generic callee with a per-instantiation
`static_assert` (`Ast.assert_fns`) splices too, and the caller's `CoreBody.demands` keeps the call, whose symbol the
emitter still demands so the assert runs. A multi-return call's member reads of its result temp
(and of the temps copied from it) become reads of the return slots.

A generic instance that calls an interface method through a type parameter
has a bound variant (`driver::emit::bound_variant`, in the serial and the parallel drain alike): when, under the
instance's bindings, the receiver's conformance by target defines the method (of a generic interface,
the conformance with the bound's arguments, `conf_for_args`) and the store keeps it
(`CEmit::bound_target`; not a keyed or blanket conformance, or a default
body), the shared lowering is copied, grounded for the instance (`inl::ground_body`: every type
substituted, each const-parameter read a constant, its switches folded), the call made direct, and
the inliner run again for up to `inl::MAX_DEPTH` rounds while it inlines (`bind_calls`). In a body
without vectors those rounds bind and splice only a callee whose result the instance fixes
(`InlineCtx::fixed_result`, set by `only_fixed`: no parameter, no call, no static read but its
const-generic parameters, so `G::len()` of `Vec<T, 3>` becomes a constant); the C compiler inlines
the rest after the link, where an earlier splice made some loops slower. The inliner binds the
parameters of a generic extend's function called through its receiver type (`V::<3>::len()`, a
bound call made direct) from `Terminator.recv`. The variant
serves that demand only. A concrete body that holds a vector runs the same rounds after its own
inlining (`cemit_seed_module`): a generic callee spliced into it brings interface calls the splice
already translated to concrete receivers. A per-caller table of each local's writes (`Writes`: count
and one whole assignment; built at the first splice, then kept by rescanning each splice's new blocks
and removing the spliced call's results, as the exposure counts are) answers which argument a struct
aggregate built once (`once_aggregate`) and which field operand keeps its value (`agg_field`), so a
splice reads no whole caller body. The record of the migration, the analysis boundary and the validation
checks is [ownership-analysis.md](references/ownership-analysis.md).

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

## Monomorphization

Full monomorphization is the only generic backend.

- **During typecheck:** each module records the concrete generic instantiations its checked
  code names in its instance list (`Ast::ninstances`); no step closes over the signatures of
  every instance's methods, so a method that returns a wider instance of its own type
  instantiates only where the instance graph demands it. Demand tables (`method_used`,
  `always_methods`) gate what emits.
- **During emission:** `cemit_package` builds an `InstGraph` (`src/graph/instances.spc`)
  seeded with the `irl::Keep` cache and calls `collect()`; it discovers every concrete
  instantiation by walking lowered Core IR bodies from concrete roots, expanding generic
  bodies under substitution frames. Roots are the concrete bodies of every module that
  emits: a prelude module `compute_emit_live` marks dead seeds nothing, and the
  definition headers list aggregates from live modules only. Keys are package ids (decl DefId +
  the final TypeId of every argument), so records from different modules compare by id.
  Only an aggregate record with a concrete pool anchor enters the planned definition headers;
  every other aggregate a body names is defined by the late replay of the mangler's
  spellings, so the closure's breadth decides an aggregate's placement, not its existence. The
  demand cross product pairs each declaration with its target's new instances only (`pair_cur`).
- **Function reachability:** a concrete function is emitted only when the program uses it. Each
  walk runs in a unit (a concrete function or constant `U_FN`, a record, a concrete aggregate
  `U_TY`, a memoized type walk, a concrete conformance's inherited default `U_DEF`, the roots)
  and records what it references (`InstGraph::edge`): direct calls (`U_CALL`), function values,
  interface calls
  that land on a concrete conformance (`edge_conf`), `dyn` vtables (`edge_vtable`), operators on an
  aggregate (`note_binop`: `eq`, `cmp`, the operator methods), the records it creates, and the
  `free` and members a value's destruction runs (`ty_targets`). A constant initializer records only
  its function values (its calls run at compile time); a pairing of the cross product and the
  unconditional default walks record nothing (`UNIT_DEAD`). `InstGraph::reach` closes the
  references from `reach_roots` (`src/driver/emit.spc`): the program entry, the runtime modules,
  test items under `--test`, a `[lib]` build's exported functions, every project function of a
  build with no entry, `@export`/`@used`/link-section items, and the methods the emitter's fixed
  text calls (`Global::alloc`, `Global::dealloc`, `str::from_cstr`). The result predicts the seeds
  (`Mangler.fn_pred`). A direct call of an inline candidate (`InlineStore::keeps`) reaches what the
  callee references, not the callee, since the call splices its body. Every other concrete function
  the rendered text spells (`Mangler::fn_ref`, inside `fn_sym`; journaled as `RK_FNREF`), such as a
  candidate a call site does not splice (budget, depth, features), is rendered late, between full
  instance drains (`cemit_seed_fn`). A name spelled after the graph freed its bodies is an internal
  error. The per-TU cache keys each module on its predicted set.
  A speculative walk (signature propagation, the demand cross product and the expansion of a
  record they created) creates no aggregate record through a computed const argument
  (`folds_const`: `{N + 1}`, `{BITS * 2}`; an identity `{N}` in `N`'s own type does not count, `lin_identity`), and the collect line
  of `SC_CEMIT_STATS` reports records by kind, bodies walked, rounds and a budget stop; the
  census of per-instance re-lowerings, the decision against a symbolic generic IR and the
  closure's bound on width-generic code are in
  [instance-specialization.md](references/instance-specialization.md).
- **Bounds:** a record whose arguments nest more than 256 levels is not expanded, and a
  body whose instantiation nests deeper than 256 levels is refused with a located error ("a
  generic function or type reaches itself with a growing type argument"). A substitution
  payload is read under its binding's env: the mangler hides the frames above it
  (`MSub.lim`), so `T := W<T>` never substitutes into itself. A depth refusal inside a std
  body is reported at the outermost user-declared generic parameter of the chain. Layout
  and ZST queries under substitution read each binding's argument under its own env
  (`LayoutEnv.penv`, built per `MSub` by `Mangler::layout_sub`), so a generic body and its
  concrete caller agree on sizes.
- **Path calls:** an associated function of a generic extend called through its type
  (`W::<u8>::f()`, with or without the function's own turbofish) has no receiver value; the
  lowering puts the qualifying instance in `Terminator.recv`, and the instance graph's
  `note_method_of` binds the extend from it (a method's receiver is its first argument).
  `recv_binds` keeps such a call, and every method call of a non-keyed generic extend, out of
  `note_call`: its record is an `IG_METHOD` (receiver arguments, then the member's own), never an
  `IG_FN`. A keyed extend's member is an `IG_FN` record whose leading arguments are the extend's,
  expanded through `expand_method`.
- **Generic interface methods:** a call terminator whose callee is an interface method with its own
  generic parameters carries them as its trailing type arguments. `InstGraph::note_iface_call`
  resolves the receiver's conformance under the frame and records the implementation's method
  (`IG_FN`, or `IG_METHOD` with the receiver's arguments first), or, for an inherited default
  body, records an `IG_METHOD` record of the interface method keyed by `Self`, the conformance's
  interface arguments, then the method's own arguments (`bind_default` reads that layout for
  `expand` and `assert_binds`), so the default is walked, its steps checked and its static_asserts
  decided as for any instance, also when only a bound reaches it; the emitter
  (`iface_target_sym`, `IfTargs`) spells the same instance (`C__conv__u8`) and demands it
  (`demand_impl_targs`); the evaluator binds them in `call_in`. The demand's bindings of the method's
  own parameters read the call's arguments under the caller's env (`bind_targs`' `lim`), below the
  receiver's extend bindings: a method of `P<A, B>` calling another instance of `P` names the
  caller's `A`, which the callee's extend binds too.
- **Keyed extends:** a generic extend (`ext_blanket`: its target is its own parameter) and an
  extend with parameters only its interface's arguments name (`ext_free_params`) are keyed
  (`ext_keyed`): no receiver instance binds them, so the checker records every argument of the
  extend, in declaration order, ahead of the method's own on each call and operator node
  (`tc_record_keyed`, `tc_record_op_keyed`; the lowering copies them, `lower_op_call_from`
  included). The checker indexes generic extends apart (`ext_blankets`; `ext_next` yields them
  after a target's own) and binds them from the receiver type (`tc_ext_bind`); its candidate
  scoring and conformance matching solve the free parameters (`tc_solve_open`). The instance graph
  binds a keyed extend's keys by position (`ExtShape.keyed`) and pairs no target instance with
  it; the emitter spells `keyed_sym` and each argument (`[mod]<Interface>__<method>__<args>` for a
  generic extend; another keyed extend spells its target's method symbol with each generic
  parameter as `_P<name>` and each const form as `_E..`, never through the substitution stack, so a
  call and the instance body spell one stem) and, through a bound or `dyn`, finds the conformance
  by target or among the generic ones and binds it (`bind_keyed`, `unify_bind`); the evaluator
  (`conf_by_args`, `keyed_conf`, `iunify`) and `Package::assoc_norm` (`lunify`) do the same.
  Several conformances whose interface arguments all fit (`i32 as Count<T>` with `T: Num` and
  `i32 as Count<W<T>>`) are told apart by the bounds of their parameters: the checker tries
  every argument-matching conformance (`tc_conform_ext_args`' `skip`) for the one whose bounds
  hold, and the backend decides the same with `Package::conf_holds` and `ext_bounds_concrete`
  (`src/module/loader.spc`; true for the marker interfaces, a type parameter and a nesting past
  its depth bound), in `assoc_norm` (by-target conformances before generic ones), the emitter's
  keyed choice (`keyed_bounds_hold`), `Mangler::conform_ext`, the instance graph's `conf_bind`
  (`frame_bounds_hold`) and the evaluator's `keyed_conf` and `conf_by_args`
  (`isub_bounds_hold`). Several by-target conformances that apply to one instance
  (`W<T: Num> as Key` and `W<bool> as Key` for `W<bool>`) are told apart the same way, never by
  declaration order: the checker keeps the ones whose bounds hold when any does
  (`tc_pick_conf_method`, `tc_assoc_norm`, `type_satisfies_in`), and the evaluator's `conf_ext_of`
  takes the first whose parameter bounds hold, else the first that fits. The overlap check (`tc_check_blanket_overlap`) applies the bounds of the
  parameters the interface arguments solve. On an instance receiver a conformance method whose
  name several methods of its target share spells its interface and the interface's arguments as
  patterns after `__<method>` (`Mangler::inst_method`), so `Vec as Mul` and `Vec as Mul<T>` give
  two symbols. Every unifier binds a const parameter from an array length too (`[f32; N]`
  against `[f32; 4]`). The instance graph reaches the generic conformances a bound call
  (`note_iface_call`: `blanks`, `conf_bind`, `gunify`) and a `dyn` erasure (`note_dyn`, `WalkCache.dyns`) demand, so their length faults are
  located errors at the interface call (`iface_demand_site`). `type_info::<T>().methods` appends
  the methods of each generic conformance whose bounds `T` satisfies (`rt_blanket_confs`,
  `rt_satisfies`: conformances, `Copy`/`Send`/`Sync` structurally, `Free` through ownership facts).
- **Emit order:** `Package::emit_order`: if module `a` re-homes a concrete instance of
  a generic owned by `b`, then `b` emits first. Kahn topo-sort, lowest-id tiebreak.

## LIR

`src/lir/` is the IR below Core IR, the input of a native backend: SSA with block parameters,
machine types only (integers, floats, a pointer, vectors of 2 to 64 lanes), stack slots, calls
above the C ABI (an aggregate passes by address, its layout record in the body's pool), one
16-byte instruction, dense `u32` ids. A body holds its instructions, blocks, parameter types,
pool, slots, symbols, messages and one location entry per instruction.

| File | Content |
|------|---------|
| `ir.spc` | The data, the opcode table (`splat`: a scalar in every lane of a vector of its type), type helpers (`type_bytes`, `type_align`: a vector aligns to its size up to 16 bytes, as the C layout does), and the tool calls (`Package::add_symbol`, `add_message`, `add_file`, `define`; `Body::add_block`, `begin`, `emit`, `edge`, `signature`, `layout`). `Sym.noinline` (`@noinline`); `Sym.ext`, an extern declaration's symbol (its address, and under `Package.no_plt` its calls, go through the GOT); `Body.inl`, per instruction the location of the outermost call an inlined copy came from (the text's `!line:col@line:col`). A load or store carries its alignment, `MEM_VOLATILE` and a type tag (`MEM_TBAA`, the text's `tbaa N`: `tbaa_of` the access's lane scalar type, 0 for bytes and untagged accesses). `SH_EXACT` on a `lshr` (the text's `lshr.exact`): it shifts out only zero bits. Block flags: `BLOCK_COLD` (a failure path; the text's `cold`), `BLOCK_UNLIKELY` (a rare block that is no failure path: the side an `unlikely` or `likely` branch makes rare, a block that calls a `@cold` function, a block only rare blocks reach or lead to; the text's `unlikely`; `BLOCK_RARE` is either), `BLOCK_NOVEC` (a loop the vectorizer left its rest to, and a vector loop; the text's `novec`). `Sym.cold` (`@cold`: a cold section, inlined only within `SHRINK`). `Package.vector`: the bytes of a vector the backend computes in one register (`Isa.vector_bytes`: 16 on arm64 and x86-64, 32 or 64 on x86-64 whose build features hold AVX2 or AVX-512, 0 on wasm32); `Package.vops` (`Isa.vector_ops`): how the backend converts vectors and shifts lanes by vector amounts, 0 lane by lane, `VOPS_SOME` (x86-64: in registers but 64-bit integer and f64, unsigned and float, and shifts without AVX2) or `VOPS_ALL` (arm64). Lane operations: `vunzip` (even lanes), `vziplo` and `vziphi` (low or high halves interleaved), `vextract.<k>` and `vinsert.<k>` (one lane), `fsqrt`. `Body.refs`: `REF_NOALIAS` (a `&mut`, with `REF_INNER` a `[]mut T` view), `REF_READONLY` (a `&T`, with `REF_INNER` a `[]T`, whose `T` holds no `UnsafeCell`, `Lower::frozen`; the text's `readonly`): its loads take alias class `CL_FROZEN`, which no write takes; `Sym.sig`, a function's signature as its definition has it (`Package.decls`), which the lowering records where it takes a non-generic function's address: wasm types an import of a function the package holds no body or call of with it |
| `verify.spc` | `Verifier::check`: dominance, block-parameter arity and types, machine types, slot accesses inside the slot and aligned as slot and offset allow, a type tag of 0 or the accessed type's, layout leaves inside their size, reducibility. `check_calls`: each direct call takes its callee's signature |
| `print.spc`, `parse.spc` | The text form; print, parse and print gives the same bytes |
| `eval.spc` | The evaluator (its arithmetic, `int_fold` and `int128_fold`, is the optimizer's folding): byte-addressed memory with the target's data model; models the C heap, memory routines, traps, the runtime's arithmetic and bit-count primitives, libm and `std::testing::bench_sys`'s allocation accounting; stops with `EV_FFI` at any other external function |
| `lower.spc` | Core IR to LIR (`Lower::body`, `Lower::glue` for derived destructors, static data; a variant's construction zeroes its payload bytes past the members when the payload is at most `ENUM_ZERO_MAX` bytes, so a whole-payload load reads defined bytes): blocks lower in reverse postorder; a block whose one predecessor ended in a `jmp` to it continues that LIR block (`join_last`); a variable read in a merge block takes the value at its immediate dominator when no block between them in that order is a loop header or writes it (`through_idom`), else a phi; then `tidy` (drops unused pure values, threads jumps through blocks that only jump, merges single-predecessor blocks, hoists and deduplicates constants into the entry, deduplicates layout records; then `forward_slots`: a slot filled in one block and copied whole into another slot as its last use becomes that slot when nothing touches the destination in between, and a second pass drops the copy; then unused slots go); `check_all`. Vectors: a lane-wise or reducing operation one `@simd_impl` entry computes whole calls that entry (`CEmit::lir_simd_entry`, `__sc_si_<symbol>`), which the inliner splices; a vector load or store of a slice is a plain unaligned access after its bounds checks, one compare-and-branch per bound into one cold failure block; an intrinsic that only loads or stores one vector (`intrin::mem_form`) is that access, and one with an empty template (a reinterpretation, a low half) is a bitcast or goes through a slot. Under `-fstrict-aliasing` (`Lower.strict`) a load or store of a typed place outside a union, and the pointer loads of its projections, carry the type tag; a union member's path (`PlaceRef.in_union`) and every other access stay untagged. A direct call of an extern declaration's function marks its symbol `ext` |
| `opt.spc` | The optimizer of a build whose C flags optimize (`Package.lir_opt`, `SC_LIR_OPT`), on the finished package (every constant's data is defined): `Run::new(pk, sealed, cf)` takes the bodies and plans a job graph (`edges`: a body waits for its direct callees of a lower call-graph level, the only ones it may inline; `levels` walks the call graph from the functions in symbol-name order, so a call cycle's levels do not depend on the emission's body numbering), the driver runs `Run::job` per body with `driver::sched::run_jobs` (inline, then optimize; scratch from a free list), and `finish` gives the bodies back; the bodies from `Package.held` on are held (`hold.spc`): a replayed unit's, which their record gives (walk facts, inlinable optimized bodies, data), the walk and the inliner read and no job optimizes, and `Package::drop_held` removes them before the emission; `optimize` runs the same jobs serially (tests); `sealed` marks the modules with module-level assembly, whose bodies inline only within their own module (the assembly may name their symbols). `Opt::run`: one walk of the dominator tree with scoped value numbering (Fallin's aegraph notes), memory states for load and store forwarding, folds by the evaluator's arithmetic (`le::int_fold`, `icmp`, `scalar_convert`, `float_op`), read-only data folding, loop-invariant motion to preheaders, branch folding, parameter forwarding, if-conversion of an empty diamond into at most 2 selects (`diamond`: `min`, `max`; the walk appends them, `hoisted` places them, and `slot_reads` counts their uses), unsigned order facts through minimums (`rel`: `i <u min(a, b)` decides `i <u a`); memory states per type tag (`tstate`: a store tagged g starts a state for tag g and the untagged accesses, an untagged write for all, so a tagged load forwards across stores of other tags, and `tags` per loop lets it leave a loop that writes only other tags); private memory (a slot or an aggregate argument whose address does not escape, `slot_writes`): a load no write touches is the same in every memory state and leaves loops, a load the one store of its bytes dominates takes the stored value (`private_load`, LLVM's single-store promotion); a slot whose address only addresses loads, stores, copies and fills has its own memory state (`privates`, `pstate`), so its writes keep other loads and leave other loads' loops. Effects (`Sym.fx`, inferred over the call graph before the jobs): `FX_READ`, `FX_WRITE`, and `FX_ARG`, a write only through the pointer arguments, which a caller passing its own slots does not see (per parameter, LLVM's `argmemonly`); a call that writes nothing is numbered like a pure value and, first in a loop header that writes no memory with arguments from outside, leaves the loop (`hoist_call`). A copy of 1, 2, 4 or 8 bytes becomes a load and a store. A join's parameter takes its one live edge's argument only when that argument's block dominates the join. A thread-local address is never one value across code (a coroutine may resume on another thread). Folds take 128-bit constants (`simplify_wide`), cancel a term of a sum (`(x + y) - x`), pick a side of an equality's select (`x != y ? x : y` is `x`), and number wide constants by their words. A load that may fault leaves only the innermost loop whose header runs it before anything that may leave or trap (`runs_first`). The rebuild removes dead code, unread slot stores, unreached blocks and parameters, merges blocks and drops the slots nothing addresses. A body with slots then runs `promote.spc` and a second walk (`SC_LIR_PROMOTE=0` skips it). `Run::job` order: `estimate` (the rare marks: `BLOCK_COLD` on a panicking block, `BLOCK_UNLIKELY` on one that calls a `@cold` function or ends in `unreachable`, then the blocks whose successors are all rare and those the entry reaches only through rare blocks), inlining, `run`, `tail_self` (a self tail call becomes a loop), `split_pairs` (a 128-bit integer as its two words), `split_wide` (`wide.spc`), the loop rounds, rotation, `split_wide` again when a plan made vectors two registers wide (`LoopOpt.wide`), `slp`, `promote_places`, `split_exits`, `estimate` again. After loop rotation, `slp.spc` packs straight-line values into vectors (`Opt::slp`), kept when the instruction count weighted by loop depth drops. A rare side of a warm branch keeps its branch (`diamond` makes no select of it). Jump threading (`thread`) takes an edge past a branch its source's facts decide: the edge's arguments, a comparison of a value with a constant that each predecessor of the source decides (`entry_fact`, at most `IMPLY_FAN` of them), constants masked to the type's width; every branch the edges agree on is decided first (`settled`, `settle`), then the edges move. The walk folds an equality of a value from another block with a constant the same way. Constants leave every loop (`hoist`). A load of an exclusive parameter's class leaves a loop whose writes of that class are all plain stores through the same address value at byte ranges apart from its own (`fields_apart`, `lst`, `imprecise`: another field of `self`). Upper bounds (`ubound`, `ub`, `UB_DEPTH`): a branch on `x <u k` in scope, an `and` with a constant, a right shift, a remainder or quotient by a constant, a zero extension; `range_fold` turns a remainder or quotient by a constant above the bound into its dividend or 0, a shift past the bound into 0, an `and` with a low mask that covers it into its operand, an unsigned comparison into a constant. A store a later store in its block writes all bytes of through the same address goes when no instruction between reads memory, may trap or was put before one (`overwrite`, `pend`, at most `PEND_MAX`). A vector load of a private slot whose lanes one same-value store each writes, all dominating it, is a `splat` (`private_splat`) |
| `hold.spc` | Held records (in the per-TU cache image, `driver::tuc::held_put`): per unit, its own object's part in the optimization of the other units, so a build that replays the object optimizes the rest byte for byte as one that renders it: per function the shape test and direct calls before optimization and, when its callers may inline it, its optimized body with the kind, `Sym.ext` and `Sym.sig` of each symbol it names; per data definition its definition; the free data (no unit, a string literal) an inlinable body names, which stays defined for the emission. `save` after the jobs, `read` in `nat_trust` (a module without a valid record emits again), `add_free` then `add` before `Run::new` |
| `promote.spc` | Promotion of private slots to values (scalar replacement and mem2reg): a slot whose address only feeds constant-offset loads and stores, constant-size copies and fills becomes one value per field (offset and type; accesses of one offset whose types convert share one, with `bitcast`, `ptrtoint` or `inttoptr`); block parameters at the iterated dominance frontier of the stores, pruned by liveness, renamed in one dominator-tree walk; a read no store reaches takes the zero of its type. Before that, a copy between two slots of its size merges them when the source is dead after it, the destination unused before it, the copy in no cycle, the source's address kept nowhere and the destination not itself promotable; a call writing its aggregate result into a slot uses it, not lets it escape. An address at a constant index of a slot is a constant offset. A slot only copies touch stays when the other side of each copy stays. At most 64 fields per slot, 256 merge attempts per body, and fields times blocks below 2^22 |
| `loops.spc` | The loop transforms the optimizer's rounds run (`Budgets`, per level `loop_budgets` in `src/driver/emit.spc`): final values (`final_values`, at every optimizing level: a loop of no effect and no trap that leaves only by a counted test goes when each value it leaves with is a polynomial of the iteration; `Poly` facts per value, header parameters resolved in rounds through their linear form `lin`, intervals that decide selects; the body copied for iterations 0 to the degree, their differences times the binomials of the trip count, `lshr.exact` in a type twice as wide; a guard when the bound could let the counter wrap; nested loops go in later rounds), full unrolling (peeling) of known trip counts, vectorization (`vplan`, `vectorize`: a counted loop of a test header and one body block over `base[i]` loads and stores, lane-wise integer and float arithmetic, splats, add/and/or/xor/min/max reductions, mul (integer lanes below 8 bytes; float under `FM_ASSOC`), float add and mul in order without `FM_ASSOC` (`vord`: a scalar accumulator through each lane's extract, when the lanes compute more than a load), float min and max with signed zeros (`vzr`: the loop runs again in order when the result is a zero), vectors of `Package.vector` bytes, `vector` interleaved; a guard checks the count and that each stored range overlaps no range read or written through another base, the original loop runs the rest and is `BLOCK_NOVEC`. The counter may step by a power of 2 up to 16 (`vqk`), count down (`vrev`), test `!=` as `<u` (`vne`); a body with one branch linearizes into selects (`linearize`), a store on one side becomes a masked store (`store_masked_ptr`, the loop keeping its branch for the rest), an early exit tests every lane before the rest of its iteration, which runs only when no lane leaves (`vexit`, `lsplit`: a gather or a store past a bounds check); a load through `base + lane * size` gathers and a store scatters lane by lane (`vgather`; a scattered store apart from every other access); loads of every 2nd or 4th element unzip (`vunzip`), such stores interleave (`store_group`); with `Package.vops` lanes of 2 or 4 times another's width mix (`plan_lanes`: past 2 the vectors hold 8 bytes of the narrowest, the widest two registers, `lir::wide` splits them; conversions in steps of 2, `vconv`) and lanes shift by vector amounts; a load ahead of a store through its base, or behind by at least a vector iteration's elements, keeps its order (`distance_ok`); a map whose last vector iteration may overlap one before ends at `n - k` (`vtail`); a load of a slice at least as long as the bound may run past an early exit (`counted_slice`). The cost model (`cheaper`) keeps a plan whose vector iteration runs fewer instructions than its lanes' scalar iterations: a gather 2 per lane, a scatter 3, a load or store of every s-th element 2s - 1, a masked store 1 + 1 per lane, a lane-by-lane conversion or shift of `VOPS_SOME` 3 per lane, an ordered update 2 per lane), bounds-check versioning with a dominating guard, unswitching, and after the rounds rotation (`rotate`: a header of at most `rotate` instructions copied to the latch, its values entering the body as parameters), then one more final-values round (a load each iteration starts with leaves a rotated loop). The vectorizer also takes loads of one place the stores keep apart from (`VK_INV`, loaded once before the copies) and, for a body of up to `ILV_SIZE` instructions that does not vectorize, runs `vector` scalar copies (a lane each); its copies come instruction by instruction, so their loads and stores pair. Final values of a loop with effects (a store, a call, a failure path) replace the polynomial values it leaves with in a block on its exit, the loop staying. A counted test needs no wrap guard when the bound's unsigned maximum (`top_of`: a constant, a zero extension, an `and` or right shift by a constant) leaves the counter's last value in range. The vectorizer's splats are `splat` instructions (`vsplat`) |
| `wide.spc` | Splitting of vectors wider than a register (`Package.vector`) into register-wide parts (LLVM's type legalization by splitting): lane-wise arithmetic, comparisons, selects, splats, constants, loads, stores, block parameters, lane extracts and inserts (one part), `vop`s that trap in no lane (lane rules, shifts by a scalar, bitcasts, absolute differences, mask comparisons and choices, unchecked gathers, masked loads and stores through a pointer), lane masks (`and`, `or`, `xor` by parts; a whole use joins them by shifts), and conversions (one width by parts; an integer of a register widened to two parts by `vziplo`/`vziphi` with zeros or its sign, two parts narrowed by `vunzip`). Anything else keeps the vector whole through a slot |
| `slp.spc` | Superword-level parallelism (Larsen and Amarasinghe; bottom-up as LLVM's SLP vectorizer): seeds are stores to consecutive addresses, block parameters whose arguments on an edge are consecutive loads, and the terms of a sum (a tree of integer adds, or float adds under `FM_ASSOC`, each inner add of one use: one `reduce_add`); a pack is as wide as the register (`Package.vector`, up to 64 bytes), or the widest power of two of 16 bytes or more a seed fills; operand lanes pack as one operation's instructions, consecutive loads, a block's parameters (one vector parameter: a loop's carried values stay in a register), a splat, or a gather through memory. `plan` estimates the gain without changing the body; `emit` places the vectors (`pre`, `tail`) and reads a vector parameter's lanes through memory for scalar uses |
| `inline.spc` | The inliner (a body of a sealed module, see `opt.spc`, takes and gives copies only within it): a callee within the level's `Budget` (`warm` instructions outside rare blocks, `all` in all: `SHRINK` 8 and 24, `SIZE` 12 and 48, `SPEED` 40 and 160, `FAST` 60 and 240), a `@cold` one only within `SHRINK`, a rare call site only for a forwarder, not `noinline`, naked, variadic, self-calling, with no inline assembly, `va_start` or `retaddr`, and no body the evaluator models (`le::modeled`), copies into each warm call site of a caller below 8000 instructions; the call's block jumps to the copy's entry, each `ret` to a continuation block |

The backend switch is per module: `cbe::backends_of` gives each module BK_C, plus BK_LIR for the
modules `SC_LIR` names, or for every module in a native build (`Package.native`). The C renderer
runs for every module (for a body whose module renders no C, only its signature, which the prototypes
need: `setup_locals` names the locals and skips the analysis of their uses); LIR lowers beside it from
the bindings the rendering used (`CEmit::lir_on`,
`CEmit::callee_binds` for a generic callee's parameter types), so the shared planning (liveness,
emit order, the instance graph, demand) stays in `cemit_package`. Locations come from the shared
line starts `Package.lines` (`driver::emit::lir_lines`). The lowering folds a constant
non-negative index into a `ptradd` offset only when the element stays inside the base slot: a
bounds check guards any other.

## Native backend

A native build compiles each module's LIR to a machine object in place of its C units.

| File | Content |
|------|---------|
| `src/codegen/live.spc` | The analysis pass (TPDE): block layout in reverse postorder with each loop contiguous, a loop's cold blocks after its warm ones and the other cold blocks last, loop nesting, each value's live range and use count. A cold block that branches into a block before it runs inside the ranges live there: each value live at its target lives to the cold block's position and is kept (`cold_entries`). `plan`: which values hold a register for their whole range, by a linear scan in range order where a value of more weight (use frequency, 8 per loop level) takes the register of the lightest active one; the generators ask per value (`want`: a callee-saved register for a value a call runs in the range of, either kind for one that lives past its block). `folds` (arm64 and x86-64, `fold_max`): a load or store at a single-use `ptradd` with an index, no offset and a scale of 1 or the access's size addresses through the base and index registers (`ldr x0, [x1, x2, lsl #3]`, `(%rax,%rcx,8)`); the `ptradd` emits nothing (`pfold`) and `uses_at` moves its operands' uses to the access. `back_param`: the parameter a back edge passes a value to, whose register the generators define that value in (`def_step`, `step_reg`), so the edge moves nothing; a branch's other edge must leave the loop, and when the parameter lives past the loop no path from that exit may read it before the header (`reads_before`, at most `BACK_SCAN` blocks, those past the range's end skipped); `reduces`: a vector reduction, which calls nothing |
| `src/codegen/structure.spc` | What structured control flow needs (Ramsey, "Beyond Relooper"): reverse postorder, immediate dominators, forward in-edges, loop headers, dominator-tree children |
| `src/codegen/obj.spc` | The format-neutral object: sections, symbols, relocations, each function's unwind rules (`OFrame`: CFI and a compact encoding) and line rows (`OLine`, `OFunc`); `own_section` adds a writer's unwind or debug section from room `named` keeps |
| `src/codegen/dwarf.spc` | DWARF 4 line tables: one unit per object, a subprogram, an address range and a line sequence per function, from the rows the generators record per change of LIR location; `attach` adds them to a Mach-O (`__DWARF`, offsets unrelocated), ELF or COFF object (offsets relocate against local symbols at the sections' starts, `R_SECOFF32`), the wasm writer to custom sections |
| `src/codegen/abi.spc` | The calling conventions' shared records: `Part`, `ALoc`, `CallLayout` |
| `src/target/a64.spc` | The arm64 encoder, one function per instruction form |
| `src/target/a64gen.spc` | One code generation pass per body: the homes `Live::plan` gives (x19..x28 and v8..v15; x9..x15 and v16..v29 for values no call runs in the range of), temporaries in the others, stack slots for the rest, far-branch retry. Vectors of 8 or 16 bytes live in v registers, their slot written (`sync`) before an instruction whose code may branch past a lane (a masked access) reads it there; a 16-byte vector that lives past its block, crosses no call and only lane-wise operations with a Neon form, loads, stores and edges use (`vec_homes`) takes a caller-saved v register home. `def_step`: a one-instruction result a back edge passes to a parameter is defined in the parameter's register; one that outlives the loop (a rotated loop's exit reads it) takes the register over as its home when the parameter's range ends in its block. Two loads or stores of consecutive bytes through one address value, next to each other in a block, pair into one `ldp` or `stp` (`pairs`, `pair`: the second defined early, so neither result takes a fixed home); an aggregate argument at a frame address loads its two 8-byte parts with one `ldp` through sp or fp (`frame_addr`). A register-passed aggregate parameter read only by entry-block loads of whole parts, before any instruction that may call, gives those loads its registers and takes no memory (`parts_taken`, `taken`; x64gen too). A product by 2^s + 1 is `add x, x, x, lsl s`, by 2^s - 1 a shift and a subtraction; a zero extension of a `clean` value reuses its register; a select's integer 0 is `xzr`, and its result takes the back-edge register (`def_step`). A `splat` is one `dup`. Homes: a leaf (no call but to a path that does not return, no system operation, variadic access or thread-local address) has 10 scratch homes from x0..x15 (`leaf`, `XSCR_LEAF`), not 6 from x9..x15, an entry parameter keeping its arrival register (`take_home` `prefer`); an entry parameter that dies in the entry block keeps its register too. A loop header's parameter and the value its back edge passes share one register or slot (`back_share`, `shared`, `is_shared`; `edge_moves` skips a move to itself), and a forward jump's argument is defined in its target parameter's register (`def_fwd`). An extern function's call under `no_plt` on ELF is `adrp/ldr/blr x16` through its GOT slot. For ELF (`Gen.elf`): TLS descriptors, a shared object's global symbols through the GOT, each frame's `.eh_frame` rules; for Mach-O its compact unwind encoding. Callee-saved registers are saved in whole pairs (x19/x20 to x27/x28, d8/d9 to d14/d15), each pair below the last with its lower register 8 bytes higher, the layout compact unwind's frame mode states; under the standard convention a variadic body saves x0..x7 and q0..q7 for its `va_list` |
| `src/target/aapcs64.spc` | AAPCS64 and Apple's variant; `va_place` places a variadic argument of the standard one |
| `src/target/macho.spc` | The Mach-O object writer, thread-locals included; `__LD,__compact_unwind` from the frames' compact encodings; a `__DWARF` address holds the object's own address and relocates against its section, as `dsymutil` maps it |
| `src/target/x64.spc` | The x86-64 encoder; `Code::relax` gives each jump that reaches its 2-byte form |
| `src/target/x64gen.spc` | `a64gen`'s design on x86-64 at the SSE2 baseline, for System V or Microsoft x64 (`Gen.win`): shift counts in cl and divisions in rdx:rax vacated per instruction, a callee-saved register when an instruction needs more than the caller-saved ones; at most 4 integer homes (8 registers stay for one instruction, all scratch ones in a leaf, as on arm64) and 4 xmm homes, no xmm home across a call under System V; under Microsoft x64 6 callee-saved xmm homes (xmm14, xmm15, xmm8..xmm13, `VFIX_WIN`; the intrinsic templates name only xmm0..xmm7) that may cross calls; a product by 3, 5 or 9 times 2^k is a `lea` and a shift, by 2^s - 1 a shift and a subtraction; a zero extension of a `clean` value reuses its register; a `splat` is `movq`/`movd` and shuffles (`unpcklpd`, `shufps`, `punpcklqdq`, `punpcklbw`, `pshuflw`, `pshufd`); a System V leaf with no slot aligned past 8 skips the 16-byte stack pad (`called`); vector homes, back-edge registers (`step_reg`, forward jumps `fwd_reg`) and shared loop homes as on arm64; an aggregate call argument at a frame address loads through rsp or the frame base (`frame_addr`); an extern function's call under `no_plt` on ELF is `call *x@GOTPCREL(%rip)` |
| `src/target/sysv.spc` | The System V eightbyte classification, from the layout leaves |
| `src/target/win64.spc` | The Microsoft x64 classification, as mingw-w64 gcc applies it |
| `src/target/a64tab.spc`, `x64tab.spc`, `wasmtab.spc` | The instruction tables: one row per instruction form (x86-64: legacy, VEX and EVEX forms with W, L, the EVEX displacement scale, masking and the operand swaps LLVM takes for a 2-byte VEX prefix), each with its encoder and a canonical decoder |
| `src/target/a64asm.spc`, `x64asm.spc` (AT&T), `wasmasm.spc` (LLVM text) | One instruction's assembler and disassembler from the table |
| `src/target/assembler.spc` | Module-level assembly into Mach-O, ELF, COFF (SEH directives) and wasm objects; inline templates (`inline_a64`, `inline_x64`) |
| `src/target/intrin.spc` | The intrinsics a backend expands in place of a call: `find` (the row of an instruction set's table), `has` (a row with a template), `expand` (the constant arguments into `@k` and `@(k*a+b)`), `mem_form` (an intrinsic that only loads or stores one vector), and the template's registers: `vnames`, `vwrites`, `vlisted` (in an arm64 register list, which keeps its consecutive registers) and `vrename`, with which the generators rename the template's fixed registers to the operands' own and bind the result where the template leaves it |
| `src/target/a64intrin.spc`, `x64intrin.spc`, `wasmintrin.spc` | The templates of `arm_neon.h`/`arm_acle.h`, `immintrin.h` and `wasm_simd128.h`, generated by `scripts/intrin/` from clang's code for a one-call wrapper of each; `tests/codegen/asm_test.spc` assembles every row to clang's bytes |
| `src/target/elf.spc` | The ELF object writer for x86-64 and arm64: `.eh_frame` against section symbols, `.note.GNU-stack`, thread-locals; an arm64 page offset's type follows its instruction's access size. Under `-ffunction-sections`/`-fdata-sections` (`Package.split`, `obj::SPLIT_*`, `obj::parts_of`) a section per symbol (`<base>.<symbol>`) with its own relocations, `SHF_GNU_RETAIN` for a `@used` one |
| `src/target/coff.spc` | The COFF object writer: `.pdata` and `.xdata` from the frames' UNWIND_INFO; `.debug_*` discardable. Split, each part is a `NODUPLICATES` COMDAT section with associative `.pdata`/`.xdata` |
| `src/target/wasm.spc` | The wasm instruction encoder: LEB128 forms (padded 5-byte fields where a relocation writes), value types, opcodes |
| `src/target/wasmabi.spc` | The basic C ABI of wasm32 (BasicCABI.md): scalars as wasm values, i128 as two i64, a one-leaf aggregate as its scalar, other aggregates and i128 results through pointers, variadic arguments in a caller's buffer |
| `src/target/wasmobj.spc` | The relocatable wasm object `wasm-ld` links (Linking.md): types, imports, functions, data segments, the `linking` symbol table, relocations; with debug information `.debug_*` custom sections whose addresses are offsets from a body's entry (`R_WASM_FUNCTION_OFFSET_I32`, section symbols for `R_WASM_SECTION_OFFSET_I32`), as clang writes them |
| `src/target/wasmgen.spc` | One LIR body into one wasm function: scalars in locals shared by live range (a result may take a local its operands free), i128 and vectors in frame homes (a result's home is never one its operands free at it: a lane loop may write result lanes before it reads every operand lane), the frame below `__stack_pointer`, Ramsey's structured control flow from an explicit task stack, dense switches as `br_table`, vector operations lane by lane as the evaluator defines them. A C `main` with two parameters is `__main_argc_argv`, as wasi-libc's start calls it |
| `src/target/native.spc` | The entry: `supported` (macOS arm64, Linux x86-64, Linux arm64, Windows x86-64, wasm32-wasip1), `object`, `own_linker` (the own linker's format for a target), `obj_kind` |
| `src/link/link.spc` | The own linker's entry: `link_args` reads a link command in the C compiler driver's spelling (objects, `-l`, `-L`, `-o`, `-shared`, `--sysroot=`, the known `-Wl,` options; `-dead_strip` and `--gc-sections` turn GC on) and routes it to a format's linker, or answers NOT_SERVED with the reason (a flag or input it does not know), which fails the build; `archive` |
| `src/link/macho.spc` | Mach-O arm64 executables and dylibs: `.tbd` stubs (`tbd.spc`) and dylibs, chained fixups, `__unwind_info`, the exports trie, the debug map, an ad-hoc signature (`sha256.spc`, pages hashed in parallel; the UUID is the hash of the page hashes) |
| `src/link/elf.spc` | ELF executables and shared libraries for x86-64 and arm64 (`--gc-sections`: kept from the entry, the init and fini arrays, the notes and the retained sections; dead frame entries leave `.eh_frame`, debug relocations into dropped sections tombstone; an x86-64 `call *x@GOTPCREL` to a function the output defines becomes `addr32 call x`): glibc's `.so` and GNU ld scripts (every file a `GROUP` names: `libc.so.6`, `libc_nonshared.a`, the loader) read for symbols and versions, PLT and GOT (BIND_NOW), TLS relaxed to local-exec (executable) or initial-exec (shared library), arm64 initial-exec and local-exec relocations of C objects, `.eh_frame_hdr`, a `_start` that calls `__libc_start_main@GLIBC_2.34` |
| `src/link/pe.spc` | PE executables and DLLs for x86-64 (with GC, the COMDAT sections nothing reaches go; a `NODUPLICATES` duplicate is an error): DLL exports read from `-L` directories or the system directory, the UCRT with mingw-w64's renames and old POSIX names (`getcwd` binds `_getcwd`), static libraries (`lib<name>.a`, `<name>.lib`; an import library stands for its DLL), COMDAT sections folded with their associative ones, weak externals, GCC's `.ctors` run with `.CRT$XC*` by priority (`.dtors` is an error), an entry that configures the C runtime, the TLS directory, base relocations, `.pdata`, an export directory for a DLL |
| `src/link/wasm.spc` | wasm32 WASI command modules from relocatable objects and archives (with GC, the bodies and segments nothing reaches go, indices renumbered): WASI imports, the table, `__wasm_call_ctors` (`.init_array`, then clang's init functions by priority), `__tls_base` when an object names it, the stack placement, the name and debug sections |
| `src/link/ar.spc` | The archiver: BSD layout with a sorted `__.SYMDEF` for Mach-O, System V layout for the others, deterministic; the reader (`read`, BSD and System V long names) and `Archives`, the static libraries of a link with the first member that defines each symbol (LLD's rule), which each linker takes from while a strong reference stays undefined |
| `std/rt/builtins.spc` | compiler-rt's 128-bit routines for the targets whose C library lacks them (Linux, Windows, wasm), in each target's calling convention |

`driver::emit` sets `Package.native` for every linking build; a linking build for a target `nat::supported`
does not name fails ("no native backend for ..."), and an emission alone (`--emit-c`) writes C.
`native_header_facts` reads the constants of the
scoped C headers with the own preprocessor (in parallel, cached in `__sc_hfacts` by file size and
mtime; its first line names its format) under `--sysroot` or the discovered one, and the scalar class
of each `@layout` opaque type through its typedefs (`Package.opaque_cls`, `bindgen::scalar_class`).
Lowering gives such a type that LIR scalar type, not an aggregate: Microsoft x64 passes a one-field
struct of a `double` in an integer register, the `double` itself in xmm. A typedef of a struct or union
of scalars is `bindgen::SC_REC`: `bindgen::c_layout` computes its size, alignment and leaves from the
header's members (`Package.opaque_lay`), and lowering takes those leaves when the size and alignment
equal the declared `@layout` (a bitfield, a vector member, a `packed` or `aligned` attribute or a
`#pragma pack` leaves it unknown). Without a C environment for the target (no sysroot) a header has no
facts: its functions are the library's exports. The calling conventions classify an aggregate by its
layout leaves (scalars at offsets; an enum's tag and a capture by reference are leaves). A layout of 1
to 64 bytes whose leaves are unknown keeps none (`abi::unknown_class`), so the LIR stays complete; the
System V and AAPCS64 generators refuse a body whose signature or call passes one
(`CallLayout.unknown`), and the build fails with the refusal. Microsoft x64 passes an aggregate by its size alone. A dyn table a body's
lowering demands while it holds the lowering lowers when that body ends (`CEmit.dyn_due`). Float
arithmetic on two constants folds (`lir::eval::float_op`, also the interpreter's rule): a NaN result is
the first NaN operand quieted, else the positive quiet NaN, as LLVM folds it, since wasm leaves a new
NaN's sign to the host. A shared-library build sets `Package.pic`: x86-64 code then reaches every
global symbol through the GOT. A call moves its scalar register arguments, and a vector one register
takes whole, in one parallel move from where they are; a vector result one register returns stays
there. Windows thread-locals are native TLS (`.tls$`, SECREL), as clang and gcc 16 emit them.

An intrinsic with a row in its instruction set's table (`intrin::find`) is a plain LIR call; the
backend puts its arguments where its template expects them (`abi::intrinsic_layout`: vectors and floats
in v0/xmm0 and on, integers in x0.. or rdi, rsi, rdx, rcx, r8, r9, r10, r11, the result in v0/xmm0 or
x0/rax; on wasm the operand stack, through locals when the template reads its arguments in another
order) and expands the template in place of the call, its constant arguments substituted (a
non-constant one where the template needs an immediate refuses the body). The expansion clobbers what a
call does; on Windows the values in rdi and rsi, which Microsoft x64 saves, go to slots around it.
`native_header_facts` reads the headers under the target's sysroot (`Package.sysroot`, from
`--sysroot=`, else discovered by `bindgen::ctarget`).

A module the backend cannot compile (module-level assembly the target's assembler does not take, a
body the lowering or the backend refuses, a call of a header's `static` function or of an intrinsic
without a template) is a build error that names the module and why (`native_plan`); `SC_NATIVE_STATS`
reports each module. Each native module gives `m.o` (its own items, reused by the emission cache) and
`m__inst.o` (the rest). The record `__sc_native` holds, per module, the key its own part was compiled
under (`nat_key`, which mixes in the build configuration, the CPU features, the LIR optimizer's
switches, the header facts and, with debug information, the compile directory), its low bit `NAT_OBJ`
when that part has an object; `nat_trust` turns an emission cache hit into a miss when the record does
not hold the module under the current key.

Debug information follows the profile's `debug` key (`loader::Package.debug_info`), which sets
`lir::ir::Package.debug` and its `comp_dir` (the compiler's working directory). Each
generator records a row per change of LIR location at the instruction's code offset (x86-64 maps them
through jump relaxation), the prologue taking the first row's location; `codegen::dwarf` writes them.
The code and data sections are the same bytes with and without it (`tests/codegen/debug_info_test.spc`).

A native build renders no C body (`cemit::backends_of`: no `BK_C` for any module; `emit_body_core`
returns at once); the declarations still render, and so does every body of the vector backend entries'
emitter (`CEmit.render_all`: a header's `static inline` C, no object's). Where a body renders no C, its
lowering journals for the TU cache what it demands (`rec_on` stays on: statics through `lir_stat_need`,
type descriptors through `CEmit::ti_need`), which the renderer journals otherwise. The registry is a
native object too (`__sc_registry_n.o`); `__sc_registry.c` is still written, and no C compiles it.
The vector bounds-check helpers live in `std/rt/lanes.spc`, loaded only when a
program names a vector type.

`check_all` (end of `cemit_package`, under `SC_LIR`) verifies every body the build lowered (the
per-TU cache keys on `SC_LIR`, so a replayed module passed it before), and under `SC_LIR_EVAL` in a
test build runs each test without fixture arguments in the evaluator, the tests spread over
`--jobs` workers with an evaluator each: against the CTFE run (`lw::probe_tests`, before the body
syntax is released, 1<<18 steps; trap kind and location must match), or, where CTFE stops at a
construct it does not support, against the test's expectation (it passes, or with `should_panic` it
traps). A test that calls FFI (CTFE's `Interp.ffi`, or the evaluator's `EV_FFI`) or passes a budget
(CTFE's, or the evaluator's 1<<21 steps) is not compared. The test build then ends: `run_package`
returns after the emission, and `manifest_test` builds no project binary and runs no test.

## Emission Buffers and Probes

`CemitOut` holds one geometrically grown buffer per TU (`TuBufs`: `tus[t]` plus
`tu_incs[t]`, `tu_heads[t][k]` per shard, `tu_tail[t]` and the chunk table
`ck_off`/`ck_end`/`ck_shard` indexed by `tu_chunks[t]`; `inst_c` with
`inst_incs`/`inst_heads`/`inst_chunks` per owner module; `fwd_h`, `defs_h[d]` (one
definition header per type, file `__sc_t/<defs_stem[d]>.h`), `protos_h[m]`, `registry_c`). A consumer that inspects the emitted C (the test harness,
the bench sink) must concatenate the headers, every shard head, the buffers and the
tail; the driver assembles each shard into one reused buffer (`shard_text`, reserved to the
shard's length) and publishes it with `publish_file`: one compare, and one write call
when the content changed. The layout, ownership and shard rules are in
[output-layout.md](references/output-layout.md).
Symbols, type spellings and call strings render once and intern into pools
(`sym_memo`, `sx_nm_pool`, `sx_cs_pool`); a generic call's symbol interns under the
fingerprint of (callee, receiver instance, targs, env), the same key the demand dedup
uses, so only the first spelling per TU context constructs it. The recursive renderers
(`emit_operand` through inlined temporaries, `emit_region` through structured control
flow) share a nesting counter bounded by `RENDER_NEST_MAX` (256, clang's bracket depth).
An `else if` chain renders flat (`} else if (..) {` in a loop), and a region that follows
arms that do not fall through continues in the caller's loop instead of recursing, so only
a falling chain whose tests need statements first still nests per arm. A body whose
structured regions pass the bound fails the dry planning pass and takes the flat goto
layout (`plan_structured`).
A `TM_SWITCH` of two or more cases on a non-boolean discriminant is a native C `switch`
in both layouts, so the C compiler builds a jump table (an `if` chain gets none from MinGW
gcc): each target's case labels together (`SWITCH_LINE_CASES` to a line; a range lists
every value, as ISO C has no case ranges), a case of the otherwise target left to
`default`, which the switch always has (`-Wswitch` on an enum discriminant). The goto layout
spells each case as `goto bb_N;` (`emit_switch_gotos`); the structured one
(`emit_native_switch`) emits each target's region once, also inside a loop, where an arm's
loop break is a forward `goto` (`sx_sw_brk`: a C `break` would only leave the switch) and
`continue` stays. In a loop, a switch whose arms continue or leave it joins where its other
arms reconverge (`CFlow::compute_follows`). A bounds check `bce` folds keeps its condition
operand on the goto for the IR re-proof; `count_all` does not count it, so the condition's
store is dead.
C11 guarantees string literals of 4095 bytes only (`STR_LIT_MAX`; `-pedantic-errors` rejects a
longer one). A string constant whose bytes (`str_const_bytes`: frame stripped, escapes decoded)
pass it spells as a block-scope `static const uint8_t __sc_lit<constant id>[]` of its bytes and a
terminating 0 (`long_lit`, declared once per body in `lit_decls` and inserted ahead of the body's
statements), read as `sizeof(__sc_lit<id>) - 1` bytes like a literal; a file-scope constant
(`push_c_str_data`) uses a compound literal array, which has static storage there. An assertion
message spells at most `ASSERT_SRC_MAX` (1000) bytes of each expression's source.
A fold chain of inlined temporaries keeps every link past `INLINE_CHAIN_MAX` (64) as a
declared temporary, so long expressions stay under that depth. A body that still passes it
is refused and reported as a located error (`CEmit.refused`, merged from the shards by
`report_refusals`).

A by-value `[]mut T` parameter splits the definition (`split_abi`, `emit_fn_inner`): the body is
`<sym>__r`, which takes the view as `<T> *restrict __sc_sp<l>, size_t __sc_sn<l>` (without `restrict` when the function has a fixed-array value parameter) and rebuilds the
local, and `split_entry` writes ahead of it the prototype of `<sym>__r` and the struct-ABI entry
`<sym>` on the chunk's first line, so `proto_of` yields both prototypes on one line (the driver
pairs prototype line k with chunk k). A direct call (`split_callee`, `split_arg`) spells
`<sym>__r` and `x.ptr, x.len` for each view argument (`split_views`), unless the callee is
extern, variadic, `@blocking` or a vector-backend entry, or a view argument spells a forwarded call
(`fwd_spelled`), which would then run twice; such a call reaches `<sym>`. Vector-backend entries
(`CEmit.no_split`) and `@emit_macro` templates keep the struct ABI.

A fixed-array value parameter is the C parameter `T const __sc_ap<l>[N]` (`param_ctype`, a pointer to
the caller's array; `ap_name`): `arr_param_copies` copies it into the local named as the parameter
before the body. Every spelling of the signature uses `param_ctype` (definition, prototype, function
value, vtable slot, thunk, `split_entry`). A function with such a parameter declares no `restrict`
on its `&mut` parameters or its split views (`has_arr` in `emit_fn_inner`): the copy reads bytes a
`restrict` pointer of the call may write (C11 6.7.3.1). A call casts a nested array argument to
`T const (*)[M]`. In a backtrace the parameter shows as `__sc_ap<l>`.

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

`gen_root` defaults to `<root_dir>/build/<profile>/raw`; manifest builds point it into
their target's profile directory (`<out-dir>/<profile>/raw`). Module paths map to nested directories (`::` → `/`):

```
<gen_root>/
  super_rt.h               # C backend header (src/emit/rt_h.spc): libc includes, arithmetic helpers, runtime prototypes
  std/
    rt/base.c              # the runtime module (traps, leak tracker, overflow report), as every module
    rt/libc.c  rt/libm.c   # wasm only: the C library (std/rt/libc.spc, std/rt/libm.spc), with -fno-builtin
  __sc_fwd.h               # runtime and extern-block includes, dyn/extern declarations, shared by every TU
  __sc_t/app__Point.h      # one definition header per type: its typedef, definition and layout check
  app.h  app.c             # per module: .h holds its prototypes and `_ret` typedefs, .c the TU body
  app__p1.c                # module shards (__p<k>, k from 1): the size policy's count, or the build.toml [shards] override
  app__inst.c              # generic instances, glue, constants and dyn tables app owns
                           # (+ app__inst__p<k>.c when the owner's instances need more than one shard)
  __std/string.h  __std/string.c  # prelude: loaded under the reserved __std:: namespace
                           # so output never collides with a user std/ directory
  __sc_registry.c          # ZST sentinels and the reflection registry
  __sc_manifest            # paths, content hashes, header dependencies, owners, shard counts
  __sc_shards              # the shard counts this build used; the next build starts from them
  __ldflags                # one @link flag per line
  __test_main.c            # the test table and the `main` that calls std/rt/test.spc (--test only)
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
   value. The `static mut`s of the compiler proper are process-wide settings, diagnostics and
   one cache: the loader's settings (`G_LOAD_JOBS`, `G_ARCH`, `G_FEATURES`), the build record
   (`driver::stats`), the type-stats counters (`TS_*` in `src/ast/ast.spc`) and the emission
   phase's `DropCtx` pool (`G_DPOOL`, freed at the end of the drain). No semantic decision
   lives in one. List them with `grep -rn 'static mut' src`.

5. **Direct C.** The emitted C moves a value with an assignment, a compound literal or a lane
   loop, never `memcpy` into a temporary, and declares no temporary that only copies a value.
   The per-body decisions in `src/emit/cemit.spc`:
   - A copy shares one C variable with its source. `setup_locals` merges a single-use
     temporary into its copy's destination, except a retyping (`same_c_cast`) into a temporary
     read once: both fold into that read instead, since a merged destination never folds (a
     reference made a raw pointer for an argument spells `f((void *)(&x))`); `coalesce_copies` does it over the CFG when the
     source is dead after the copy and the destination holds no value the source's live range
     can reach (`copy_range`, `live_from`): an `if` or `switch` value and a short-circuit result
     write the binding in each arm, through chains of copies. A temporary copy of an immutable
     binding or parameter spells the binding. An array literal's element value writes `d[k]` at
     its definition (`compute_elems`). A vector result writes its local (`vec_forward`).
   - A local declares at its initializing write when that write dominates every access
     (`compute_fusion`): a drop flag at the entry (`bool _5 = false;`), a local of a loop when
     every access lies inside the loop's braces (no do-loop test, no exit), any local in the goto
     layout. A borrowed local's storage ends must lie in that scope too.
   - A single-use pure value is spelled at its read (`sx_inline`): in its block, along a goto
     chain (`sx_gpred`), past a guard whose other edges only panic (`sx_spred`) and past a call
     (`sx_cpred`) when the value cannot panic and reads no memory and no local a pointer
     reaches; as the base of a place read through a pointer; as a value argument (`by_value_arg`).
     A constant temporary is spelled at every read (`const_folds`). A binding the source names
     folds only inside its block. C orders no operands: a reader, a call's arguments included,
     holds at most one folded expression that can panic (`one_panic_per_reader`). A spliced
     callee's parameter reads its argument in place unless the callee can reach the argument's
     storage (`ir::inline::param_facts`, `exposed`); `vec_literals`, `vec_fusion` fold vectors.
   - A pointer local defined once by the address of a place that stays where it is, and read
     only through a dereference, spells that place at each use (`fold_addresses`): the path
     dereferences at most its base, a local never written whole, and indexes only an array held
     in place, by a constant, a temporary written once or an argument never written, none of them
     addressed (`fixed_index`). An inlined `Array::index` writes `pad.data[7] = n`.
   - A single-use call result is spelled at its read (`compute_call_fwd`): along the same goto
     chains, through copies folded at their read, into a literal's member and into a field or
     element of a local's own storage, when nothing between emits and no other operand can
     change in the call (`fwd_keeps`).
   - A value nothing reads has no variable: a call's result or a check's index is a statement
     of its own (`compute_discards`; an external C function keeps its result, since its header
     may declare it `warn_unused_result`), and a proven check's other operands are no reads.
     A copy into the result slot moves past the drops to its `return` (`compute_ret_defer`).
   - A zero value inside another literal is left out: C zero-fills the member, and gcc's
     `-Wmissing-braces` rejects a nested `{ 0 }` (`zero_lit_d`).
   - A temporary remains where an effect between would change its value: a call result held
     while the destination's old value is read or dropped (an inlined `replace`, `x = f()` over
     an owning `x`), a value read before a write to its inputs, several calls in one literal (C11
     6.7.9p23 leaves their order unspecified), an `if` value passed as an argument, a value
     merged at a join and returned.
   `memcpy` and `memmove` remain where C has no other legal spelling: an array copy, a bitcast (a
   type pun), and a raw pointer that may overlap its operand.
