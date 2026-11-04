# Borrow Checker

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
     [type-identity.md](type-identity.md)): `Gen::value_sig` takes the signature of
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
[type-identity.md](type-identity.md)). The parser keeps a declaration's
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
