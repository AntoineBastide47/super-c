# Analysis Inventory: Native Backend

The facts each backend phase computes, where the result lives, and what makes it stale.
Read the phase's table before you add a traversal, analysis, table, or pass
(`super-c-task-discipline` section 10). Reuse a fact while it is valid, extend its
producer, or keep it valid through your transform. Update this file in the same change
when you add, remove, or move an analysis. The source is authoritative for names; this
file is authoritative for where to look first.

## borrow (`borrowck_all`, before `cemit_package`)

| Fact | Producer | Stored in | Valid until |
|------|----------|-----------|-------------|
| The std modules only prelude modules import, directly or through each other (`std::spec::seq`): no program module, their symbols prefixed, emitted only where live code names them | `Package::index_pl_deps` (at each index build, from the import adjacency) | `PkgIndex.pl_dep`, read by `Package::prelude_dep` | the next index build |
| The lazy modules' bodies a build reaches: roots, call targets, function values, the conformance methods of a called interface member, every `free` conformance once a body drops | `bc_std_closure` (scans each kept body once, after the jobs) | `irl::Keep` (the bodies), a local queue per item | end of `borrowck_all` |
| The lazy modules' conformance methods by name hash | `bc_std_closure` (`fn_name_key`) | local map | end of `bc_std_closure` |
| Whether the instance graph seeds a lazy module's function | `InstGraph::seeds` (reads `Keep.ix`) | not stored | per call |

## prove (`prove::check_kept`, after the recursion check)

| Fact | Producer | Stored in | Valid until |
|------|----------|-----------|-------------|
| The components of the direct calls among the kept bodies of the reported modules and of the modules that state a contract | `ir::recursion::kept_graph` (from `check_kept`; `kept_components` for the language server; reused: `Recur::components`, the graph widened by `graph`) | `comp` per kept slot, copied to `Shared.scc` | end of `check_kept` |
| Core CFG, RPO, loop headers, a loop's blocks | `ir::facts` `Facts::begin`, `is_header`, `loop_scan` (reused) | the prover's `Facts`, per body | the next body |
| The locals the walk models (all but a static's reference), and those a pointer, a reference to a value that is neither frozen nor a container, a slice view, a closure or a call's implicit borrow may reach (`is_mem`; not a `&mut` lent to one call); the temporaries lent to one call | `Prover::scan_tracked`, `autoref` | `Prover.tracked`, `is_mem`, `mem_list`, `scoped`, per body | the next body |
| The `&mut` parameters' slots past the locals, their types | `Prover::prove_body` | `slot_ty`, `slot_of`, `nlocals`, per body | the next body |
| A quantifier's closure (body, state, range, witness, triggers) and its instances | `Prover::quantifier` (at its `QuantSite`, `quant_at`), `instantiate`, `triggers` | `qclo`, `qof`, `qinst`, `qdef`, per body | the next body |
| The user triggers of the quantifier whose body the walk evaluates (`std::spec::quant::trigger` arguments) | `Prover::trigger_value` (from `call` and `chain_call`, while `utrig_on`) | `utrig`, then the closure's triggers | the closure's end |
| A trigger's match at a term, at any depth (`MATCH_WORK` steps), and whether a term holds another | `Prover::matched`, `match_at`, `mentions` | not stored | per call |
| The model-based instances of a failed check: the terms its model puts in a quantifier's range, one per value | `Prover::model_instances` (`instantiate` with `QI_MODEL`, `model_value`) | the instances in the check's facts | the obligation's end |
| The references to members of locals and slots | `Prover::place_ref` | `pref_tg`, `pref_tgty`, `pref_m`, `pref_at`, `pref_key`, `pref_ty`, per body | the next body |
| The locals and slots of a struct type with an invariant its module proves | `Prover::inv_scan` | `inv_locs`, `inv_end` (a `Free::free` receiver's slot), `inv_dead` (the locals whose storage starts in a loop: no value at its back edge), per body | the next body |
| A call's result and the members read from it (`Some(b)` of `v.pop()`): values that left a body, so in the struct's own file too they satisfy their invariant | `Prover::call`, `read_prefix` | `res_of`, per body | the next body |
| The locals and slots whose `@owned` field's pointer the body's code reads | `Prover::own_scan` (`own_mark`, `tailcall::rv_operands`) | `own_exp`, per body | the next body |
| The allocator calls of a path: kind, size, the block a `realloc` moves, its direction | `Prover::call` (`alloc_call`, `block_of_ptr`) | `alloc_of`, `alloc_rec`, per body | the next body |
| The `@owned` block accesses since the last check | `read_prefix`, `update` | `own_chk`, drained by `own_check` | the statement's or terminator's end |
| The facts of a member read by an unknown key, of a sequence's element and length, of a normalized index | `Prover::sel`, `seq_at`, `seq_make`, `seq_ext`, `index_key` | `seld` (made once), the facts in `defs` | the next body |
| Whether no value of a type holds a cell, per (module, type) and the struct whose generic parameters it may name | `Prover::cell_free_of` (over `no_cell`) | `Prover.cell_free`, per prover (one per worker chunk), for the build | never: the types do not change while the proofs run |
| The null and address facts of pointers: an offset (`p + n`, no wrap, null only from null), an address (`p as usize`, 0 only for null; the pointer at it is `p`, so a pointer at an equal address is `p`), `from_addr_mut` (its address is the argument; at `p as usize` it is `p`), a slice's `ptr` (not null where `len` is not 0), a reference or its pointer cast (not null); a type's alignment (the layout's, else a power of two at least each member's known alignment) | `Prover::ptr_offset`, `ptr_addr`, `ptr_at`, `align_term`, `slice_field`, `rvalue` | `ptrd` (made once), the facts in `defs` | the next body |
| The locals of member references made once outside every loop and used only to read or write a member (`let c = &mut self.f[i]`): their target escapes only where such a reference is passed on | `Prover::scan_lazy` (`Facts::loop_scan`, reused) | `lazy`, per body | the next body |
| The view a modeled method gave a container's value, or a slice in a memory epoch; the sequences a spec function's result may equal | `Prover::sq_effect`, `elem_write`, `slice_of`, `define` | `vdef`, `sdef`, `alias`, `alias_pool`, per body | the next body |
| The type arguments of the generic spec function being unfolded, and the constants its const parameters are bound to (a call's const argument, an instance's) | `Prover::call_value`, `const_arg`, `generic_local` | `subst`, during `define` | the unfolding's end |
| Whether every call of a function ends (no loop, each callee ends, a call to itself only under its `decreases`): ghost code assumes its `ensures`, and in a ghost block (`ghost_blk`) reads a `const fn`'s body as its definition (`define`; where the function's own proof does not show that it never panics, an overflow is a path condition, `OVF_PATH`, and the definition holds only where a path returns). For that reading only (`ends_k` with `dispatch`), a loop and a call of an interface's method count as ending: the walk of the definition stops after `DEF_BLOCKS` blocks and leaves out the paths still running, and an interface's call unfolds only into a conformance that ends | `Prover::ends`, `Prover::ends_k` | `ends_memo` (keyed apart per mode), per prover | none: the kept bodies do not change during the proofs |
| The conformance of an interface's method at a type: a declaration's, a built-in type's or a blanket `extend<T: B> T`'s whose bounds the type meets | `Prover::spec_conf`, `find_conf`, `extend_targets`, `conforms` | `conf_memo`, per prover | none |
| In the walk of a definition: the `&mut` parameters that hold their referents' values, the parameter whose final value the walk defines, and the values a call's `&mut` arguments refer to after it | `Prover::define`, `call_value`, `chain_call` | `byval`, `def_out`, `out_param`, `call_outs`, during `define` | the definition's end |
| The step budget of a body: build.toml's `prove-steps` outside std, else `STEP_BUDGET` | `Prover::set_budget` | `budget`, `Solver.limit`, per body | the next body |
| The locals a reference made on the path may reach, which a memory event forgets | `Prover::escape` | `Path.esc`, per path (the union where the merged walk joins two paths, `merge_paths`) | the path's end |
| A write to a local that no reference or pointer of the path reaches starts no memory epoch; a borrow through a raw pointer, also an auto-referenced receiver, reaches the memory, not the pointer's local | `Prover::reached`, `borrow_reach`, `raw_reach` | not stored | per write |
| The ownership versions of a body: kind (base, a call's REMOVE of the blocks it takes, an ADD of those it gives), previous version, the atoms and claim guards each changes; the held atoms `held(p, size, align, v)`, each defined from the version before | `Prover::ov_new`, `ov_remove`, `ov_close`, `held_atom`, `held_def` (lazily) | `ov_kind`, `ov_prev`, `ov_ps`, `ov_pst`, `ov_psn`, `held_p`, `ov_defd`, per body | the next body |
| The atoms a call takes (claim guards from `held_g`), the blocks a collecting version gives (`ov_seen`), and the sources whose claims are distinct | `Prover::ov_name_as`, `held_g`, `src_mark` (calls' `ensures`, a value's invariant, `mi_open`, `st_open`) | `ov_take`, `ov_seen`, `ov_col`, `src_tab`, per call | the call's end |
| That each block a removal took was held under its claim guard: a fallback stage of `holds_at` for goals that name held atoms | `Prover::ov_remove` | `ov_had`, per body | the next body |
| The blocks a shared parameter lends, re-assumed in each version | `Prover::lent_claims`, `lent_take` | `ent_ref`, per body | the next body |
| The distinctness of two held atoms' blocks from the versions that gave them, and of a check's compared pointers (`ptr_apart` facts) | `Prover::held_apart`, `apart_holds` | not stored | per check |
| Where a loop's invariants are established (its start, an iteration's end): their blocks are distinct, which the header assumes; whether the loop may take or give a block | `Prover::loop_apart` (claims marked `SRC_LOOP`), `loop_owns` | the claims' sources in `src_tab` | the loop's walk |
| `free`'s receiver value before the walked call or drop, whose invariant holds of its value after it | `Prover::recv_val` (in `call` and the drop) | `recv_pre` | the call's or drop's end |
| The `&mut` parameters' targets a call reborrows whose results can hold no borrow (`holds_no_borrow`: frozen, a type parameter of the body counting as frozen): they do not escape, and the call's event gives them new values | `Prover::param_reborrow`, `holds_no_borrow`, `forget_all` | `prb`, per call | the call's end |
| Counter fields (`@counter`): a struct's counters, cached per type for `needs_proof`; the members their guards read (the guard's kept body); the temporaries that hold a counter's address (copies and casts followed), each reaching only an atomic operation's first argument; each step's units and guard | `Prover::counters_of`, `counted`, `guard_fields`, `ctr_scan`, `count_step`, `count_start` | `ctr_ty` (per prover, for the build), `ctr_tmp` (per body) | `ctr_ty` never: the types do not change while the proofs run; `ctr_tmp` the next body |
| Whether a body holds a float's unchecked conversion (`CAST_UNCHECKED`, `to_int_unchecked`), whose precondition makes it need a proof as a call's `requires` does | `Lower::lower_intrinsic` | `CoreBody.has_unchecked` (kept by `compact_from`) | never: the body's lowering sets it |
| Counted shares: share atoms of `rc_share(p, k, n)`, the units count per counter and version (one unknown per entry), the units a call takes and a version gives | `Prover::share_atom`, `nsh`, `nsh_def`, `sh_give`, `sh_fit` (the sum checks) | `sh_p`, `sh_kn`, `sh_tk`, `sh_gv`, `sh_seen`, per body | the next body |
| The structs with an invariant the path wrote through a pointer and must prove again; their values in the write's epoch; the blocks of allocators' results not yet written whole | `Prover::mi_open`, `mi_forward`, `mi_close`, `mi_close_at` (at an assignment's read or write through another pointer, `wpc`), `mi_alloc_open`, `alloc_event` (kept across `Global` calls, `global_alloc`), `unfresh` | `mi_dirty` (`Path.mi`), `mi_fwd`, `mi_lds`, `mi_seen`, `mi_fresh` (`Path.fresh`), `mi_wrote` (`Path.wrote`: the pointers the path wrote such a struct through; a `dealloc` of a typed `*mut S` opens the struct unless the path wrote it, and ends its `mi_dirty` entry) | the path's end (`mi_fwd`: the body) |
| The statics with an invariant: address terms, types, writes from another file, references | `Prover::static_val`, `st_open`, `st_save`, `st_carry`, `st_report`, `static_ref` | `st_inv`, `st_list`, `st_err`, `st_decl`, per body | the next body |
| Function items named as values (item and type arguments), whose `requires` `pre_of` evaluates; the arguments that may be such items | `Prover::fn_item`, `pre_value`, `handoff_arg` | `fn_items`, `fn_defs`, `fn_binds`, per body | the next body |
| The contract site of each chain's first block and of each block that enters one | `Prover::begin_sites` | `site_of_chain`, `site_of_pred`, per body | the next body |
| A `@prove_exhaustive` function's inputs: each parameter's domain (kind, range narrowed by its `requires`, count) | `exhaustive_job`, `pdim` | `PJob.dims`, per function | end of the function's proof |
| The failed assertion of an evaluated run: contract kind, clause, owner, frame depth, span | `Interp::assert_failed` (on a failed `TM_ASSERT` while `pa_on`) | `Interp.pa_*`, per run | the next `prove_run` |
| The hash-consed terms of a body's values and formulas (commutative operands in index order) | `Terms::make` (`src/prove/terms.spc`) | `Prover.tm`, per body | the next body |
| The facts of the pattern types of a body's values (a range, a variant's `T_TAG`), anchored on the value's term; one unknown per const parameter | `Prover::pat_fact`, `param_var` | `Prover.defs`/`def_of` (as definitions), `pvars`, per body | the next body |
| The bounds checks that held on every path that reached them (facts for the build) | `Prover::note_check` | `chk_ok`, `chk_dead` per body, then `Prover.facts`; applied as PROVEN twins in `irl::Keep` and in the proof record (`p` lines) | the build |
| The range of each integer parameter a proved `requires` states | `irc::skip_contracts` (`note_requires`) | `CoreBody.entry_ranges`; the LIR's `Body.ranges` (`Lower::param_range`) | the body |
| Whether a term holds an operation the bits define and the arithmetic reads as an atom (a float operation or comparison too: a float is the integer of its encoding, `T_FADD` ..) | `Terms::make` | `Terms.bitty` | the next body |
| The format of a float type (width, fraction bits, FINITE_ONLY) of `Float<E, F, FAMILY>`, and the std `Float` method a call names | `Prover::soft_fmt`, `soft_kind` | not stored | per query |
| Each value made as a choice of two by a boolean (a float rewrite's alternatives): its condition and values, which a float comparison of it splits into and `may_fuse` reads | `Terms::choose` | `Terms.choices` | `Terms::clear` |
| Each value a float rewrite's model made, by the IEEE operation it stands for, which `may_fuse`, `may_chain` and `fused` read | `Terms::set_shape` (in `Prover::float_binary`, `float_call`) | `Terms.shapes` | `Terms::clear` |
| Each float operation of a bits encoding with the literal where it is NaN, and the facts of rounded operations against its operands and its kind's earlier operations | `Blaster::float_lemmas`, `pair_lemmas` (`nan_if`) | `Blaster.fterms`, `nan_of`, per encoding | `Blaster::reset` |
| The constants an encoding's terms compare each float term with, and the bounds (boxes) of each `f32`/`f64` operation built | `Blaster::cands_of` (one scan of the term table), `bounds_of`, `box_lemmas` | `Blaster.cands`, `boxes`, per encoding | `Blaster::reset` |
| A branch's theory literals: those a SAT model of the skeleton needs, the count before each choice, and the decision level that fixes each formula | `Solver::model_lits` (`model_val`, `model_level`, `forced`) | `lits`, `cuts` of `Solver::implies`; `memo`, `lv`, per model | the next model |
| The literal sets the walk's solvers did not refute (not for want of steps), each with its model; one comes back without the solvers | `Solver::lemma_with` (`lits_hash`) | `Solver.fails`, `fatom`, `fval`, `fstart` | `Solver::forget`, or past `FAILS_KEPT` |
| The value of each atom in the walk's last integer model, the start of an `implied` test's simplex | `Solver::bb` (an integer model) | `Solver.warm`, read by `Lp::load` | `Solver::forget` |
| What a branch's literals state: its rows, equalities, disequalities and literals | `Kernel::state` (`state_lit`) | `kernel::Built` (`Stated`), per branch | the branch's refutation |
| The literals that share unknowns with the goal's | `Solver::cone` (`unknowns`, `find`) | `Solver.uf`, `ufirst`, per branch | the next branch |
| The bits of a branch's cone: each term's bit vector, the gates, the clauses | `Kernel::blast` (`Blaster`, `src/prove/blast.spc`) | `Kernel.bl` (`vk`, `vecs`, `gates`, `cnf`) | the next blast |
| A SAT search: trail, watches, learned clauses, the LRAT proof | `Sat::solve` (`src/prove/sat.spc`) | `Solver.sat`, checked by `Lrat::check` | the next solve |
| The lemmas of a walk: each one the literals a checked proof read (`Kernel::core`, from `Built.ends` and the entries `check` marks), sorted, found by their least literal; a branch that holds one closes without the theories (`subsumed`) | `Kernel::lemma`, `blast_lemma` | `Kernel.lems`, `lend`, `lwatch`; `used`, per check | `Prover::clear_terms` (`Solver::forget`), or past `LEMMAS_KEPT` at `begin` |
| The skeleton of one refutation's formulas with the clauses of its lemmas and of the earlier lemmas it used | `Kernel::seal` | `sk`, `call0`, `lused` | the next `implies` |
| The closure's terms and their operands, indexed literal by literal (`Stated.ends`), and the roots they come from | `Solver::cc_build` (registers only the terms a set adds to the last one) | `Solver.cc_term`, `cc_ix`, `ostart`, `olist`, `cc_roots`, `cc_valid` | a set that does not extend the last, CC_MAX, `Solver::forget` |
| A branch's congruence classes, their signatures and the forest of merges | `Solver::cc_build`, `cc_run` | `Solver.rep`, `sig`, `edges`, per branch | the next branch |
| The buckets of the applications `suggest` pairs: per operand, its class joined with its model value and its linear form | `Solver::suggest` (`operand_nodes`, `app_key`, `KeyFind`) | local, per `suggest` | the call's end |
| A branch's simplex: tableau, bounds and their rows, assignment | `Lp::load`, `check`, `Solver::bb` | `Solver.lp`, per query | the next query |
| The product operands branch and bound set to a value, and their rows | `Solver::fix`, `fix_rows` (`Lp::add_row`) | `Solver.fixes`, the tableau's added rows | the next `bb` |
| The products of two rows of a retried obligation, and the tangent planes at its models | `Solver::nla_rows`, `tangent` (`nla_attempt`, while `nla_allowed`) | the tableau's added rows, `Proof.prods`, `Proof.monos`, `tangents` | the next branch |
| The cuts of a branch's integer equalities | `Solver::eliminate` | `Solver.crows`, per set of equality facts | a new equality fact |
| The Gomory cuts of the root's fractional points | `Solver::gomory`, `gomory_row` (`Lp::add_row`) | the tableau's added rows, `lrows` (`keep_row`), `pf.cuts` | the next `bb` |
| A branch's proof: facts, trees, cuts, multipliers | the solvers | `Solver.pf` (`kernel::Proof`), checked by `Kernel::check` | the next branch |
| The last unrefuted branch's integer model | `Solver::keep_model`, or the bits' model (`sat_model`) | `Solver.model`, `mval` | the next `implies` |
| The parameters a callee may change | `Prover::param_writes` | `Prover.pwrites`, per callee | end of `check_kept` |
| The contract sites of the interface methods without a body (the language server: of the modules the proved one can name) | `Prover::lower_shells` (`Lowerer::lower_fn`) | `Shared.shells`, `shell_ix` | end of `check_kept`, `check_module` |
| Whether a kept body has an integer type wider than the narrow numbers read | `Prover::needs_wide` (`wide_bits`) | `wide` per kept slot, in `check_kept` | end of `check_kept` |
| The facts derived for a division or shift by a constant (quotient bounds, remainder, product) | `Prover::derive` (`divided`, `quotient`, `shifted`) | `Prover.derived` | end of `check_kept` |
| The derived facts of the last tier: an unsigned value split at a bit (`x == (x >> c) * 2^c + (x & (2^c - 1))`), a left shift's kept bits, a disjoint `\|` or `^` as a sum, a product's constant bound and its expansion over split factors, a wrapping cast as its value less a multiple of `2^w`, a remainder by a constant of a multiple of it (`multiple_facts`); `holds` adds them after the others | `Prover::derive_late` (`split_of`, `bit_facts`, `product_facts`, `wrap_facts`, `multiple_facts`) | `Prover.late`, `splits`, `split_parts` | `clear_terms` |
| A goal's own facts, made at goal time: the last tier's facts of the operations it names, the path's equalities that give its terms other values and the products they make (`core`), tried alone before the stages; with the path's facts that share a product with it (`sharing`); then with the path's facts within `LATE_STEPS`, and where that attempt spends them, whether the facts prove the goal false (`refuted_goal`: no retry with products of rows) | `Prover::late_facts`, `late_first` | per goal, not kept; `Prover.refuted_goal` per obligation | each goal |
| The equalities of a predicate's application a goal of several parts names with one the path states of one other operand (`owns(p, n, 8)` beside `owns(p, m * 72, 8)`), proved once for every part | `Prover::stated_congruence` | per goal, not kept | each goal |
| Whether a memory event is a write through a parameter's pointer value at the entry, which reaches no local of the body | `Prover::write_at` | `Prover.spare_frame` | the end of each write (`write_place`, `havoc_write`) |
| `lint --proofs`: the solver steps of each obligation of the body under proof (its span), their sum over the bodies, and the lemma rewrites of the costly asserts | `Prover::oblige` (when `Package.lint_proofs`); read by `cost_warnings`, which proposes the rewrites (`hint`) | `Prover.costs`, `spent`, `hints`; `Package.proof_lint` (`ProofLint`); main's `proof_hints` proves each rewrite before it prints | `prove_kept` (each body) |
| The product terms by their factors: one product at two types is one value | `Prover::product_facts` | `Prover.prods` | `clear_terms` |
| Each module's proof key: its source, the shapes of its import and reference closure (`import_closure`, `mod_refs`, `tuc::shapes_early`), the prelude's sources, the compiler and the settings | `prove_keys` (`src/driver/emit.spc`) | the build tree's `__sc_prove` record, of the modules whose proofs held | a change of any input |
| The functions of other modules whose bodies a module's proofs read (`kept`, `param_writes`, `mutual`; the memos `ends`, `mentions_owns` replay theirs) | `Prover::note_read` (`Prover.rd`, `take_reads`, `memo_reads`), per module in `check_kept` | `@d` lines of `__sc_prove` and the shared records | an edit of a listed body |

## language server proofs (`lsp::analysis::borrowck_pending`, after an open module's borrow check)

| Fact | Producer | Stored in | Valid until |
|------|----------|-----------|-------------|
| The bodies the proofs of an open module read: its own (its borrow check lowers into the keep), the call targets and function values of every kept body, through the bodies they lower, and the `invariant` methods and `@counter` guards of the modules it can name | `prove_reach` (each kept body scanned once) | a per-check `irl::Keep` | the module's next check |
| The lowerings `prove_reach` made of other functions than the proved module's | `prove_reach` | `Package.prove_cache` | the next analysis or parse-back of their module (`recompile`'s affected and re-checked sets, `ensure_bodies`), a reachability change for a module that reads it (`reach_settle`) |
| The proofs a request stopped: the keep, the components, the next kept slot, the reports so far | `prove_module`, `prv::check_module` | `Package.prove_resume` | an analysis round with work, a parse-back of a module they read (`resume_reads`), the document's close, the module's next check |
| The modules whose last check did not finish their proofs: the module was closed, or a request stopped them | `borrowck_pending` | `Package.prove_owed` | the module's next check with its proofs, or a failed analysis |

## lower (`cemit_package`, `B_PLAN` to `S_LOWERED`)

| Fact | Producer | Stored in | Valid until |
|------|----------|-----------|-------------|
| Core CFG, RPO, idom | `ir::facts` `build_cfg` (bce) | facts state, per body | bce folds an edge |
| The reference and pointer parameters each kept body may let outlive a call, and what each result may point into | `ir::capture` `CaptureStore::build` (one scan per kept lowering, then one worklist over the call edges), in `cemit_package` | `Package.cap_store` (`ir::facts` `callee_keeps`, `callee_returns_none` read it) | end of `cemit_package` |
| The parameter whose value every view a kept body returns has as its length (`fn view(p, n) []T` of length `n`) | `ir::capture` `CaptureStore::build` (`view_len_param`, at most `RET_SCANS` rounds after the result fixpoint) | `CaptureStore.rlen`, per entry (`returns_len`; `ir::facts` `call_view_len` reads the argument's value before the call, `bind_view_len` binds the result's length to it when the call left the argument's local unchanged) | end of `cemit_package` |
| The version of a place's one dynamic index local | `Facts::index_ver` | not stored | per call |
| C control-flow shape (RPO, idom, postdominators, loops) | `emit::cflow` `build_into` | `cem.cf_ext` | read only by the C renderer; not built in a native build |
| LIR lowering CFG (every core block's successors, which `share_plan` reads too) and dominators | `Lower::cfg`, `Lower::dominators` | `Lower` (`sat`, `sl`, `order`, `preds`, `idom`), per body | end of `Lower::body` |
| Storage-marker liveness, one step per block (`live & keep \| born`) | `Lower::share_plan` | locals, per body | end of `share_plan` |
| Address exposure, argument modes | `Lower::scan` (`arg_mode`) | `Lower`, per body | end of `Lower::body` |
| Type classes | `Lower::ty` | `Lower.cc.tcache` (`Lower::tkey`: a final type id alone, a provisional one with its module) | whole build |
| Field lists | `Lower::fields_of` (`member` reads `fpool` in place) | `cc.fcache`, `cc.fpool` | whole build |
| Shapes of payload enums | `Lower::enum_of`; `fields_of` stores the shape its `decl_fields` placed | `cc.ecache` | whole build |
| Register leaves of an aggregate | `Lower::layout_of` (`leaves`) | `cc.lcache`, `cc.lpool` | whole build |
| Static asserts of a module; instances checked | `cemit_inst_asserts` (graph, checker queue, drain) | `Interp` (`sa_list`, `sa_done`) | whole build |
| Layouts (size, align, offsets) | `ir::layout` `Svc` | one cache per `Svc` owner (each `Mangler`, `Lowerer`, interpreter) | whole build |
| `@owned` fields of a concrete referent | `owned_of` (`owned_fields`) | `cc.ocache`, `cc.opool` | whole build |
| Frozen (no `UnsafeCell`) of a concrete type | `frozen_top` (`frozen`) | `cc.zcache` | whole build |
| The caches above (`lw::LCaches`) in a parallel emission | each shard task takes the set of its pooled task context and gives it back (`CEmit::swap_caches`) | `DropCtx.lc` | whole build |
| Package constants of an emitter (backends, `names_vectors`, the mangler's prelude lookups, niche declarations and C library names) | `CEmit::new`, `Mangler::new`; a shard copies the master's (`CEmit::new_like`, `Mangler::new_like`) | each emitter; the C library names one `Arc` | whole build |
| Uses of each instruction during slot forwarding | `forward_slots` (`lir::verify::uses_edges`) | `Tidy.uat`, `Tidy.ul` | the forwarding; `drop_unused_slots` reads its slot use counts (`snuse`) when nothing forwarded |
| Package part of the native cache key | `nat_base` | a local per loop (a module's key: its emission key xor it) | per loop |
| What other modules read of each module (per-TU cache key): the kinds of its declaration nodes (below `Ast.decl_end`), the tokens of its text outside the blocks of its body-arena and pinned functions, and those blocks' spans | `tuc::shapes` (before `release_bodies`), `shapes_finish` (in `tuc_setup`: a module's token hash is the previous image's when its text outside the blocks is the same) | `Tuc.sh` (`Shapes`); the image keeps each module's text and token hashes | end of `cemit_package` |
| What each module's functions reach, per reachability unit: a Merkle hash over the instance graph's strongly connected components (unit content: text, closure shapes, declaration id and line) | `InstGraph::reach_hashes` (iterative Tarjan over `esrc`/`edst` and the implicit type and call edges), summed per module with the runtime's roots by `tuc::reach_mix` | mixed into the module keys of a build whose LIR optimizer runs | `tuc_setup` |
| The functions whose evaluations' results reach the build (a constant's value, in a type too): each body the evaluator runs in the body arena or past the declarations, a closure there as its whole module; a memoized value replays the functions it ran (`rd_enter`, `rd_leave`, `note_deps`), each under its site: the innermost memoized value's module, else the running evaluation's (`eval_reset`), else the item under check's (`read_site`) | `Interp::note_read` (`body_of`), on the master engine and the emission's constants pass; paused for the always-panics probes | `Package.ce_reads` (`site << 48 \| module << 32 \| node`), the prelude image keeps the prelude check's; hashed per site by `tuc::ce_sites` into the per-TU keys, `dep_hash` and the proof keys | whole build |
| The bounds checks the prover proved, per function (a hash) | `prove_cached` (from its facts) | `Package.prove_fd`, in the module keys and `tuc::dep_hash` | per build |
| The class of a type that names a parameter, per set of bindings | `Lower::ty` (`env_of`: the bindings and the macro mode by content, found again when `Mangler::subs_gen` changes) | `Lower.tg`, one map per binding set (`tg_envs`) | whole build |
| The content key of each native object | `nat_piece_key` (`nat_sym_hash`, `nat_sym_ref`, `nat_body_hash`, `nat_data_hash`), in each object's task | `NatObj.key`, with the hash of the object's bytes (`nat_bytes_hash`); the tree's `__sc_native_keys` | a change of its input |
| The functions a module's seed bodies call, before and after the Core IR inliner (the dependencies of its section) | `DropCtx::apply_drops_i` and `ir::inline::run` while `deps_on` | `DropCtx.deps`, then `SeedShard.deps`; the section holds each one's `tuc::dep_hash` | the section's record |
| The processor facts of a body compiled for more features than the build's (`lir::ir::Cpu`: register bytes, instruction flags) | `CEmit::body_cpu` (`cpu_facts` of `CEmit.fs`), at `Lower::body_i` | `lir::ir::Body.cpu` (carried by `copy_into`, `compact`, `pairs`, `promote`, `wide`, the inliner and the held records; read through `Package::cpu_of`) | the body's end |
| The widest vector register any body of the program compiles for | `cemit` at the lowering context's setup (`cpu_facts` of the build's features, `Package.fn_union` and each `simd_levels` entry); the text parser from the `cpu` lines | `lir::ir::Package.vec_max` (read by `Run::job` to keep a body's form before `split_wide` for its callers) | never (a changed feature set changes the TU cache header) |

## optimize (`lir::opt` `Run`, `S_LOWERED` to the end of the `lir_opt` block)

Per package, in `Run::new`; `calls_of`, the shape test and `effects`' own facts of each body (`own_effects`,
`own_escapes`) run by chunks of bodies on worker threads (`utils::par::chunks`, `Config.jobs`), each chunk's lists
then appended in body order, so the facts do not depend on the workers; `effects`' fixed point stays serial:

| Fact | Producer | Stored in | Valid until |
|------|----------|-----------|-------------|
| Calls of each body: callee, argument roots; the functions whose address it takes and the functions of the read-only tables it names, which `effects` does not count | `calls_of` | `Calls` | `Run::new` |
| Classes of identical instance bodies: the same instructions (`Body::same`), level, shape, unit and function attributes | `duplicates` | `Run.dup` | end of the run |
| Memory effects, written and escaping parameters | `effects` (over `Calls`; a worklist over the callers of each body, `rc`, and the bodies that pass to its parameters, `rp`), `own_effects`, `own_escapes`, `stalls` (counts over `rc`) | `Sym.fx`, `Sym.esc`, `Run.wargs` | end of the build |
| Call-graph levels and job edges; the bodies whose job finished | `levels`; each job's end | `Run.level`, `Run.edges`, `Run.order`; `Run.fin` (`await_marked` waits on it) | end of the build |
| Inliner shape test; a finished body's inliner facts (inlinable, `small` within `SHRINK` and the run's budget, `forwarder`, computes with floats) | `Run::new`; `il::facts` after the job (a held body's in `Run::new`) | `Run.shape`; `Run.ok` (`IL_*`) | end of the build |
| arm64 per-block scratch-home cap: per instruction the x0..x15 registers it holds besides the homes, per block their most | `a64gen` `need`, `plan_homes` | `Live.scap`, its sparse table `smin` (`min_table`, as `jcap`'s `jmin`) | the body's plan |
| A call site's slot arguments: the callee's parameters whose argument is a slot's address and that it uses only as access, copy, fill and constant-offset addresses, and per callee instruction the parameter it offsets | `il::slot_params`, per call site `folds_small` tests (a callee over its budget) | `Inliner.der` (scratch) | the next site |

Per body, on `Opt` (`Run::job` runs the passes in order). `Opt::tables(pk, b, want)` computes
only the levels `kept` lacks (`K_GRAPH` < `K_DOM` < `K_NEST` < `K_MEM` < `K_SLOTS`); every change to
the body sets `kept = K_NONE`, and `forget` runs at a job's start, after inlining, after `direct_known`
makes calls direct, and when a job takes a scratch back after its wait (`Run::ready`). `thread`, which
moves edges alone, keeps `K_GRAPH` (`cfg` and the predecessors again, the operands of the terminators
and of its rewrites spliced in, `splice_ops`); `estimate` computes `cfg` alone. `preheaders`
keeps `K_NEST` (`enter_tables` gives the tables a fresh computation gives), and in `loop_opts`
`unpreheaders` takes back the block tables `save_tables` copied and the operand lists the spares of
`splice_ops` hold, and cuts the block of each instruction and parameter to its saved length:

| Fact | Producer | Stored in | Valid until |
|------|----------|-----------|-------------|
| Successors, RPO, predecessors; block of each instruction; operand lists (CSR) | `Opt::graph` (`block_map`, `operands`) | `Opt` (`pred_at`, `preds`, `pblock`, `blk_of`, `ops_at`, `ops`, `ops_dst`) | `K_GRAPH`: any change |
| Per instruction, its readers up to 2, and whether an `or` reads it | `thread`'s walk over `ops`, or `Opt::readers` (from `ops`) where the walk first reads them | `Opt` (`icount`, `in_or`; `counted`) | the next `operands` or `splice_ops` |
| Dominator tree and its pre/post numbers | `Opt::dominators` | `Opt` (`dpre`, `dpost`) | `K_DOM`: any change |
| Loop nesting, preheaders, loop blocks in block order | `Opt::nest` | `Opt` (`inner`, `lparent`, `preh`, `lb_at`, `lbs`) | `K_NEST`: any change |
| Private slots and the slot each address derives, alias classes (the slots' too, `slot_seeds`: per slot its class `sclass`, `sloop`) and their scope roots' bases, slot escapes, frozen memory, per-block and per-loop writes and tags | `Opt::memory` (`privates`, `classes`, `slot_escapes`, `root_bases`, `frozen`, `bw`, `bt`, `bpw`, `bst`) | `Opt` (`pder`, which `slot_escapes` and `slot_apart` read through `der_slot`; `cbase` among them; per scope class its roots' base value `sroot` and `smulti`) | `K_MEM`: any change |
| The parameter offsets of pointer loads, the owned fields' classes, the scopes' roots | `Opt::owned_seeds`, `scope_seeds` (in `Opt::memory`) | `Opt` (`okeys`, `obits`, `sroots`) | `K_MEM`: any change |
| Slot base, offset, escape; per write the copy it is (`SlotWrite.copy`) | `Opt::slot_writes` | `Opt` | `K_SLOTS`: any change |
| Slots an instruction still addresses | `Opt::rebuild`, `emit` | `Opt.sused` | the next rebuild |
| The pool records and `lines` entries a body names (dead ones dropped; `compact_lines` keeps equal entries apart) | `Body::compact_pool`, at the end of `Run::job`; `lines` also in `Lower::body` before `Package::define` | `Body.pool`, `Body.lines` | the next pass that adds records |
| Rare blocks | `Opt::estimate` | `BLOCK_RARE` flags on the body | any block change; codegen reads them too |
| Loop weights | `Opt::weigh` | `Opt` | any edge or block change |
| Unsigned upper bound, lower bound and signed range of a value | `Opt::ubound`, `lbound`, `srange` (`no_srange` skips a value no rule bounds) | not stored | per call |
| Order facts of the branches in scope: `x <u y`, the values `y` is at most, signed bounds | `Opt::order_facts` (`upper_parts`), `note_signed`; read by `order_decided` | the walk's scoped tables `rel`, `ub` (signed bounds under `SLO_KEY`, `SHI_KEY`, counted in `nsigned`) | the scope's end |
| Bounds of a loop header's parameters: at most an outside value, a signed counter's range | `Opt::param_bounds` (`edge_bound`, `note_le`), `signed_counter` | the walk's scoped tables | the loop's scope |
| What the edges into a join block give its integer parameters: unsigned and signed ranges, values from before the join they are at most | `Opt::join_out` per edge, `join_in` at the join | `Opt` (`jat`, `jcnt`, `jfacts`: `JoinFact`) | the walk (cleared at its start) |
| A loop's blocks and the block of each instruction for the loop transforms | `LoopOpt::shape` (from `Opt`'s `lb_at`, `lbs`), `LoopOpt::candidates` (a copy of `blk_of`, `pblock`, which the transforms extend) | `LoopOpt` (`inl`, `lblocks`, `owner`, `powner`) | the loop's transform |
| Loop counter, trip count, exit test | `LoopOpt::counted_by`, `trip`, `cf_test` (`lir::loops`) | `LoopOpt`, per loop | the loop's transform |
| The constant a back edge adds to a header parameter (`steps_by_one` asks it for 1, `up_step` for one that steps up: partial unrolling), and whether an integer is a multiple of a power of 2 (`mult_of`: by its form alone; `Opt::low_zeros` reads the walk's replacement maps, which the loop transforms do not hold), and the bound and offset a bound of `opt`'s `offset_test` stands for (`offset_bound`) | `LoopOpt::step_of`, `mult_of`, `offset_bound` (`lir::loops`) | not stored (`checks` keeps the guard's reduction in `gred`) | per call |
| The bounds checks a versioned loop drops and their count (a check against the lesser of two lengths counts two) | `LoopOpt::checks` | `LoopOpt` (`gchecks`, `cap_len`, `cap_v`) | the loop's transform |
| Header counts and shape test of a loop | `LoopOpt::header_counts` | caller | the loop's transform |
| Per candidate loop, the blocks that read its values | `LoopOpt::close_index` (one walk of the body over the blocks a candidate header dominates), `close_scan` | `LoopOpt` (`xs_at`, `xs`, `xdone`, `xof`) | the loop's transform |
| Closed form's leaving values and their targets | `LoopOpt::close_plan` (no change), then `close_apply` | `LoopOpt` (`lout`, `tgt_of`, `tused`, `cf_leave`) | `close_apply` |
| Promotion candidates, the slots addresses derive (`collect`, for `merges` too) | `Promoter::collect`, `Promoter::merges` (`lir::promote`; graph and operand lists from `Opt`) | `Promoter` | the promotion |
| The loads made before a copy for the loads of the slot it feeds (copy, offset, type -> value) | `Opt::copy_fed`, from `slot_writes`' tables | `Opt` (`fed_key`, `fed_ty`, `fed_v`) | each walk |
| Per header parameter of a loop that unrolls partially, how the copies keep it (a reduction: an accumulator per copy, from the operation's identity or, for an idempotent one, from the parameter's start; any other: the value the copy before passes back), and the copies the target's registers hold: the accumulators of every copy, the chained values and the float and vector values from before the loop that the body reads, against the generator's registers for values that live past their block (`Package.vec_homes`, `vec_homes_call` in a body with a returning call), and one copy's own values against those for a block's own (`Package.vec_temps`) | `LoopOpt::split_plan` (`reduction`, which asks the vectorizer's `minmax` for a select and its `FM_ASSOC` test for a float sum or product; `body_regs`, `vregs`; `Opt::writes_homes` sets `LoopOpt.vhomes` per body), from `unroll_factor` | `LoopOpt` (`ured`; `ucur` while `unroll` copies) | the loop's unrolling |
| A loop's carried modulo accumulators: the accesses through a `VK_MADDR` address whose copies cover all `K` lanes, of a slot only accesses and offsets read | `LoopOpt::carry` (`slot_root`, `slot_private`), in `vectorize` | `LoopOpt` (`vcar`, `vcur`) | the loop's vectorization |
| A vector loop's aligned-block loads: contiguous loads before an early exit through no counted slice (`vblk`), and the loads of a branch's side through no counted slice with their condition and side (`lcl`, `lclc`, `lclw`, from `linearize`) | `LoopOpt::vplan_with`, `linearize` | `LoopOpt` | the loop's vectorization |
| A loop's loads through one pointer after stores through another: both bases, scales and byte ranges | `LoopOpt::apart_plan` | `LoopOpt` (`abase`, `ascale`, `alo`, `ahi`) | the loop's `version` (`apart_guard`, `copy_at`) |
| A minimumNumber or maximumNumber reduction's select chain, its sign test any form (`ir::sign_test`, shared with `Opt::simplify`'s copysign fold) | `LoopOpt::num_red` | `LoopOpt` (`vfr`, `vk` VK_RCMP) | the loop's vectorization |
| Whether the bits of a multi-register lane mask have a reader besides a count of them | `Opt::bits_kept` (one walk of the body's operand lists) | not stored | per call |
| SLP predecessor tables | `Slp::plan` (`lir::slp`; block map and use counts from `Opt`'s `blk_of`, `pblock`, `ops`) | `Slp` | the packing |
| Operand lists of one instruction | `lir::verify` `uses`, `uses_into` | caller's vector | per call |

A pass that returns false must leave the body unchanged; the next pass then reuses the facts
above. Recompute a fact only after a change that the "Valid until" column names.

After the optimizer, `lir::ct` computes the secret values of each `@constant_time` body
(`Check::violations`, a fixpoint over the block parameters) into `Check.taint`, valid for that body
alone, and the replacement of each mark (`Check::strip`) into `Check.rep`; nothing after reads
either.
| What a float value holds: no signaling NaN (`FC_QUIET`) or no NaN (`FC_NUMBER`); a block parameter's by induction over its edges | `Opt::fclass`, `param_fclass` (the walk's predecessors and replacement maps; `UB_DEPTH` operations deep) | not stored (`float_known` writes `VOP_NUMBER` on the minimum or maximum) | per call |
| The CPU-level check a body opens with: its run-time copies, the block it starts in | `lir::inline` `dispatch_of`, `check_block` (`exact` for the x86-64 generator's stub, `Gen::func`; without it for `Inliner::run`, which strips a callee's copied check) | `Gen.disp`, `Inliner.disp` | per body |

## codegen (`native_plan` to `S_GENERATED`)

| Fact | Producer | Stored in | Valid until |
|------|----------|-----------|-------------|
| RPO, predecessors of reached blocks (CSR), loop nesting, rare blocks, fold decisions, use counts | `Live::analyze` (`reverse_postorder`, `loops`, `rare_blocks`, `folds`; `Live::run` adds `relayout`) | `Live` (`rpo`, `npred`, `pat`, `preds`, `inner`, `pfold`, `count`) | end of the function, retries included |
| Block layout, live ranges, last uses, folded use lists (CSR) | `Live::relayout` (`layout`, `ranges`; `uses_of`) | `Live` (`pos`, `end`, `ua`, `un`, `uv`) | a change of the layout (`after`) |
| Block frequencies (static: reverse postorder propagation, rare successors' small share, loop headers' factor, loop exits' divisor, a share of at least 1 from a block that runs) | `Live::frequencies`, called by `Live::analyze` (reads `rpo`, `inner`, `parent`, `rare`) | `Live.freq`; the value weights `wt`, `assign` (`saves_cost`, `frame_put`, `save`) and the generators' `shrinkable` (`after_into`, `around_cost`) read it | a block or edge change (the layout does not change it) |
| Register state a join block takes from its branches | `place::Core::join_tables` (per block, the predecessors the layout puts before it), `join_note` at each branch, `join_in` at the block | `Core` (`jneed`, `jat`, `jpool`, `jcnt`, `jlast`, `jbad`) | each compilation of the body (`join_tables`) |
| Rare blocks | `Live::rare_blocks` (none under `Live::in_place`: wasm) | `Live` | end of the function; the optimizer's `BLOCK_RARE` holds the same fact only when `lir_opt` ran |
| Next use of each folded operand | `Live::ranges`, reverse walk of the existing operand CSR; `Live::advance` consumes it | `Live.next`, `use_next`; native eviction scoring reads `next` | layout change; cursors advance once per instruction |
| Per block, the first layout position of a block it reaches | `Live::reach_min` (for `entry_partner`) | `Live.ep_min` (`ep_min_ok`) | a change of the layout |
| The register plan: per value that asks for one, a register per block where it is live (exact liveness per value and position; a parameter in its argument's register, a result in its first operand's, or in any ending operand's on a `three` target (one it may be written over on a `two` target); a part load in the register it arrives in; a part of the blocks with a stack home when no register is free in all; an idle holder gives way) | `Live::assign` (reads `want`, `Caps`, `Sets`, the arrival registers, `freq`, `pat`, `preds`, the operand CSR, `cfirst`, `clast`, `wfirst`, `wlast`, `jcap`, `scap`, `rhint`, `three`, `two`, `part_in`, `part_quiet`; helpers `spread`, `ends`, `over`, `room`, `arrival`, `hints`, `pick`, `spans`, `evict`, `seg_put`, `seg_lists`) | `Live.seg_x`, `seg_a`, `seg_b`, `seg_r`, `sin`, `sin_at`, `segd`, `seg_mem`, `bmask`, `solo`; per candidate, the blocks that read it and the last reader in each (`su`, `sul`: `read_last`, which the generators' `early` reads too) | next plan or layout change |
| Per block, its first and last instruction that writes the caller-saved registers (a call that returns), and that writes an argument register (arm64); per instruction, how many of each come before it | `a64gen` and `x64gen` `plan_homes`, from `cpre`, `cret`, `rarec` (`call_tables`; arm64 `wide`) | `Live.cfirst`, `clast`, `wfirst`, `wlast`, `ccount`, `wcount` (arm64), `vfirst`, `vlast` (x86-64: the calls that write the vector homes, `vclob`) | the body's plan |
| Per value, the last layout position of a block that reads it | `Live::ranges` (the uses walk) | `Live.rlast` | each layout |
| Per instruction with a segment whose range holds a rare block or a block laid out last (`after`), the layout positions it is live into (precise: a range also runs through such blocks no path joins to a read) | `Live::pasts`, on the first `Live::dead_past` after `assign` (reads `ua`, `un`, `uv`, `segd`, `rare`) | `Live.past_id`, `past_in`, `past_def`; the generators' `save_scratch` reads them | each `ranges` and each `plan` (`past_ok`) |
| Per instruction, a truncation to 8 or 16 bits that several comparisons read alone and that does not fold (`FOLD_TRUNC_ONCE`) | `Live::folds` | `Live.xtrunc` | each analysis of the body |
| Per instruction, the value it is a view of (`FOLD_VIEW`: a conversion that keeps its operand's bits), and per instruction whether a zero extension is a view of it | `Live::views`, last in `Live::folds` | `Live.view`, `Live.wide`; `Live::seen`, `Live::vix` and `Live::arg` read them | each analysis of the body |
| A segment's register (the plan's), and a segment value's stack home | `place::Core::seg_reset` (copies `Live.seg_r`), `Core::seg_in`, `seg_out`, `seg_slot` | `Core` (`seg_reg`, `sv_home`, `sv_off`) | each compilation of the body (`seg_reset`) |
| Operand list of one instruction (edge arguments included) | `live::each_use` (over `lir::verify::uses_edges`, which the LIR passes call too); folded: `Live::uses_of` | caller's vector; `Live` | per call |
| Special operations of the body | `lv::op_flags` | `Gen.opf` | end of the function, retries included |
| Stack canary | `lver::protected` | `Gen.prot` | end of the function, retries included |
| Wasm structure (idom, loop headers, forward edges) | `codegen::structure` `Shape::run` (reads `Live`'s `rpo`, `pat`, `preds`) | `Shape` | end of the function |
| Call layout of a signature | `call_layout` (a64gen, x64gen), `cc::classify` | `Gen` (`lays`, `lay_at`) | end of the function |
| Intrinsic template of each body symbol | `intrin::of_symbols` | `Gen.itpl` | end of the function |
| Per intrinsic call, the argument whose register its template writes the result into (arm64, x86-64) | `a64gen`, `x64gen` `call_over`, before `assign` | `Live.cover` (read by `Live::over`) | each plan of the body |
| Calls that return, clobber, dead ends | `call_tables` | `Gen` (`cret`, `cpre`, `rarec`) | end of the function |
| Object symbol of a package symbol | `osym_of` (wasm `pkg_osym`) | `Gen.osym` (`place::Osyms`, from the native objects' pool) | end of the object |
| Object sections, symbols, relocations | `codegen::obj` `Obj` | `Obj`, then the object bytes | the object write |

## publish, sync, link

| Fact | Producer | Stored in | Valid until |
|------|----------|-----------|-------------|
| Object bytes | `nat::object` | `NatObj.bytes`, then the `.o` file and the link's `lu::Mem` | the link reads them (memory) |
| Output file hash, manifest line | `out_hash`, `man_line` | manifest | end of the build |
| Per-TU cache image | `driver::tuc` | `.tu_cache` | next emitting build |
| Parsed input objects | `parse_object` (`link::macho`, `elf`, `pe`, `wasm`) | linker state | end of the link |
| Function parts of a section | `split_sections` | linker state | end of the link |
| Part of a symbol | `part` (binary search) | not stored | per call (COFF writer: once per symbol) |
| Relocations of each section | Mach-O writer, one pass | `rat`, `rix` (writer locals) | the object write |
| Live relocations, their resolved globals | `mark_live`, `scan_relocations`, `apply_relocations` | linker state | end of the link |
| Parts whose address the input takes (`--icf=safe`) | the GC walk: `mark_live` (Mach-O), `collect` (ELF, PE, wasm) | `taken` (the walk's local) | the folding |
| Classes of identical code parts | `fold_code` (each linker) over `lu::fold_hashes`, `lu::fold` | `ISec.fold`, `IFunc.fold` | end of the link |

## Known recomputations

These recompute a fact the compiler already holds. Remove each line when it is fixed. Do
not copy their pattern into new code.

- borrow, prove, lower: each reader of a contract site's blocks marks them again (`ir::site_mark`:
  `ghost_blocks` in the borrow facts and in the flow conversion, the prover's `begin_sites` and
  `own_scan`, `skip_contracts` per site); the walk visits only the site's blocks.
- lower: a native build still renders the C text of its constants and statics, of its aggregates'
  definitions and of the extern headers' checks, which only the C backend reads, and spells each
  callee's symbol again per calling module for the cross-unit edges (which choose the objects too);
  `Svc` holds one copy per owner.
- lower: `dead_stores` scans back from the block's end for each storage end (about one
  instruction per call in the self-build).
- optimize: `LoopOpt` analyses a rejected loop again in each round; the exit test has four
  decoders (`cf_test`, `trip`, `counted_by`, `checks`), and `top_of` repeats part of `ubound`;
  `Slp::plan` builds every block's in-edges (`graph`'s predecessors hold no edge ids and cover the
  reached blocks only); `return_slot` builds operand lists after a `run`'s rebuild left no tables;
  `thread`'s header test repeats `nest`'s; `only_use`, `only_in` and `only_step` scan the whole body
  per query.
- codegen: `Live::rare_blocks` repeats the optimizer's `BLOCK_RARE` when `lir_opt` ran; each
  object compiles its own copy of the unowned package data it names (string literals; weak with
  `-fdata-sections`, so the link keeps one); a64gen and x64gen hold parallel copies of the
  target-dependent parts of the register allocation (`edge_moves`, `continues`, `entry_reg`,
  `param_home`, `call_tables`, `plan_homes` and more).
- publish, sync, link: the linker parses again the objects the build had in memory, and reads the
  replayed ones from their files; the four linkers repeat `global` and `out_section`; the Mach-O, ELF and
  COFF linkers copy and relocate the input sections by chunks on worker threads (`lu::Img`,
  `utils::par::chunks`), then add the fixups, dynamic and base relocations they found in section order;
  `fold_code` resolves the relocation targets of the parts that share a hash again (the GC walk stores
  none: a stored target for each of the image's relocations costs more than the about 10% it reads).
