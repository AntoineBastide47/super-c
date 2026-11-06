# Drop Elaboration

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
instances share it as they share the lowering. A native build whose LIR optimizer runs
skips this inliner (`DropCtx.lir_inlines`: the LIR inliner inlines) but for a backend file's entry. The
inliner's callees come from the package's `InlineStore` (`src/ir/inline.spc`): every kept env-free lowering is vetted once
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
checks is [ownership-analysis.md](ownership-analysis.md).
