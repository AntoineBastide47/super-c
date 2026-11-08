# Core IR, HIR and the Freeze Contract

## Core IR

The Core IR (`src/ir/core.spc`) is the typed, control-flow, non-SSA executable form
every body lowers to: one `CoreBody` per function, method, closure, or constant
initializer. Storage is dense append-only vectors of u32-indexed records with body-local
pools; no per-node heap allocation, no pointers into other stages.

It is consumed by the borrow-check loan analysis, drop elaboration, the CTFE
interpreter, the instance graph, and the C emitter. Full record layout, the statement /
terminator / rvalue kind tables, and the replay-tape events are in
[core-ir.md](core-ir.md). Lowering runs at the start of borrow checking, after the
whole-package typecheck, the obligation discharge and the first type publication; the
measurement that rejected an earlier publication point, the consumer inventory and the
replay-tape category table are in
[core-ir-publication.md](core-ir-publication.md). Vector operations reach target
instructions through the CPU feature set, the `@simd_impl` backend table and the lowering
planner: [simd-backends.md](simd-backends.md).

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
after codegen (reported), or where the tables go when the build releases its syntax after the
lowering (`syntax_done`), the tables' last state; the codegen check then skips them. A released
table must match its snapshot up to its release and its released length after it. The check also requires each release at its point: the body facts
exactly when the body arena is released, and `method_refs` and `seeds` by the codegen check.
