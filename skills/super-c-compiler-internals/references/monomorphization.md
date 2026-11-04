# Monomorphization

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
  [instance-specialization.md](instance-specialization.md).
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
