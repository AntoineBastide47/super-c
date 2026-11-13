# Compiler Stages Reference

Each stage as `run_package` (`src/driver/emit.spc`) actually runs it, in execution
order. Env-gated verification passes are marked; they are no-ops in a normal build.

## 1. Load: Lex + Parse (`src/module/loader.spc`, `src/lexer/`, `src/ast/parser.spc`)

Module discovery from the root file's imports; import search roots are the project root,
an optional manifest `src/` root, then `std/` and `ffi/`. Directory names are sorted so
ModuleIds are deterministic regardless of readdir order. Parallel under `--jobs`
(`par_discover`): a module's file reads and parses in a task, its imports start as soon as it
is parsed, and a depth-first replay in import order then assigns the ids the serial loader
gives (`par_replay`); the prelude's files parse in one wave and take their ids in name order.

- Lexer: byte-driven scanner over a NUL-padded source `String` (`SOURCE_PAD`). Output
  `Vector<Token>`; tokens are packed `u64` `(kind, start, len)` spans, no text copied.
  Character-class table built by `const fn`, held by value per Lexer. A keyword of 2 to 8
  bytes is one multiply-shift hash of its bytes into a table built at compile time from
  `SHORT_KEYWORDS` (a new keyword goes there; when `KW_MUL` collides on the new set, the
  `static_assert` fails and a new multiplier is needed); longer ones are in `long_keyword`.
  Identifier and line-comment scans read 8-byte words, within `SOURCE_PAD`. Every error is
  recovered; the scan always completes. `keep_trivia` (formatter path) also emits
  comment tokens.
- Parser (`src/ast/parser.spc`; there is no `src/parser/`): context-free LL(1)
  structural cover grammar, no predicates or backtracking. Do not call it "predicated".
  Every fork decides on one peeked token; never add k>=2 lookahead. To share a prefix,
  parse the head, then continue from it in an `_after` function (`parse_cast_after`,
  `parse_struct_initializer_after`). Contextual words resolve from one token: the lexer
  fuses `inline`/`parallel` before `for` into one modifier token, and splits a lifetime
  `'a` from a character literal `'a'`. Output: two append-only arenas
  per module, the module arena (`Ast.nodes`) and the body arena (`Ast.b`, releasable bodies,
  ids tagged `NODE_BODY`; see syntax-ownership.md). Sugar keywords (`launch`,
  `select`, `parallel for`, ...) parse to marker nodes; `@derive` synthesis happens here
  at parse time. The parser records the build-constant sites (`Ast.bc_sites`: every `if`
  whose condition the build constants alone decide, every `switch` over PLATFORM, ARCH or
  ENDIAN with decided arms) and the unknown variants they name (`Ast.bc_errs`, reported
  by the resolver).
- Prelude: the std files, then the build-constant module `__std::build`, generated from
  the package's settings (`--target`, `arch`, `test_build`, `profile`, and `build_cfg`: the
  lockdep and wrapping bits `build_system::build::apply_profile` sets from the profile;
  `add_build_module`). `build_cfg` is part of the prelude image key and of every unit's cache key.
- The two build drivers (`run_file`, `emit_closure`) load in two stages. `prelude_stage`
  (`src/driver/emit.spc`) loads the prelude alone into a package with the same settings
  (`Package::settings_copy`, `load_prelude_stage`; imports looked up under the std root only),
  then `check_prelude` filters, resolves and type-checks it with the same functions the second
  stage uses, through the prelude gate's publication. `driver::prelude_image` saves that package
  (`utils::persist`: the modules with their ASTs and type pools, the index, the type table and
  publication maps, the method marks) with the engine's deferred checks, and the build loads the
  bytes back into its own package: a cached image (`<root>/prelude/`, see `super-c-binary`) is the
  same bytes. `Package.carry` keeps what the second stage's item schedule starts from: the
  prelude items' raw resolution and post-typecheck edges, readiness states, result verdicts and
  dynamic edges. `load_user` then loads the root's closure after the prelude
  (`Package.root_module` is its first module) and the vector backend when a module names a
  vector. When the stage checks the prelude under `--jobs`, the closure's files read and parse
  while `check_prelude` runs (`Package::spec_user`, against a copy of the prelude's module
  table), and `load_user` replays them into the package that loaded the image: the ids, the
  import errors and their order are those of a load after the image. Every later stage skips
  the work the prelude stage did: the platform filter and the resolution start at
  `root_module`, `index_append` extends the prelude's index, the item jobs skip the prelude's
  items, and the edges of `carry` join the new ones. Module and item ids are prelude-first. The batch lint, the LSP and the test harness still load with `load_root` or
  `prelude_package_arch` and run every stage over every module.

## 2. Platform Filter (`platform_filter`)

`@platform` / `@arch` / `@when` gating: items are compacted out of each AST by target mask (and,
for `@when`, by the truth table of its build condition) before
resolution (`Package::platform_filter` in `src/module/loader.spc`; the driver, the LSP and
`package_from_source` all apply it). An item carries at most one of each (the parser rejects a repeated attribute); an item with both needs both to hold. `--target=` / `--arch=` and `--bootstrap-tags` feed the mask.

The early prune runs here too (`prune_build_sites`, idempotent): each build-constant
site the settings decide is rewritten in place, an `if` into its taken block (an empty
block when none is), a `switch` into the body of its first matching arm (an expression
arm into a one-statement block). Sites are in parse order, so an `else if` is decided
before the `if` holding it. The removed nodes stay in the arena, unreachable, like the
items of a gated-out declaration. Each replaced site records its node and source span
(`Ast.bc_cuts`) and the hashes of the identifiers of its removed text (`Ast.bc_names`,
sorted): the use-counting lints treat those names as used (`Ast::bc_removed_name`; the
item, member and import lints take the package's union), skip the unnecessary-`unsafe`
lint on an `unsafe` holding a site, and never count a statement that is or holds a site as
diverging (`Ast::bc_cut_at`). The six build-constant names and the enum names `Platform`,
`Arch` and `Endian` (outside std's `target.spc`) are reserved (the resolver's `declare`), so
the prune needs no resolution. The LSP re-prunes a module whose bodies it parses back
and reparses a module with sites whole instead of splicing a body.

Conditions the filter does not decide (PROFILE, or a mix with other operands) fold in
the Core IR lowering: `Lowerer::bc_cond` evaluates a closed condition that reads a
build constant and lowers only the taken branch (`bc_profile_arm` does the same for a
`switch PROFILE` over string literals).

## 3. Resolve + HIR, per module (`src/resolver/`, `src/hir/lower.spc`)

One parallel frontier; for each module, `Resolver::resolve()` runs and then
`hirl::lower_module` runs **immediately after** (`resolve_module`).

- Resolver: name binding and scopes; fills the `Ast.resolutions: SplitVec<DefId>` side
  table. Resolver-level lints run here (they must see pre-HIR syntax). A type path's
  resolution names the declaration of its head segment, and `TypePathData.head` records that
  segment's index (the module path or `Self` before it). The checker reads the segments after
  it: a struct literal's target may name one enum variant there (`E::V { .. }`); in any other
  position they name no type and are an error (`tc_type_tail`); a generic argument for a const
  parameter reads them as an associated constant (`tc_value_path`).
- HIR lowering IS the desugar stage: sugar-keyword markers become core nodes
  (`launch` → the `SI_SUBMIT` shim call via `lower_to_core_call`; `select` via
  `lower_select`, which builds nodes with hand-seeded resolutions). Lowering is by MOVE:
  the parse arena becomes the HIR in place. Typecheck, borrowck, const-eval and codegen
  never see a sugar node.

## 4. Typecheck, per item (`typecheck_stage`, `src/typechecker/`)

Item jobs over the components of the schedule graph (`driver::sched`, item-index.md): a
job starts when its last dependency completes, every prelude component before any other,
and checks its top-level items under the module's lease (one checker per module, so a
module's side tables have one writer at a time). The serial path runs the same jobs in
their stable order. Type inference with expected-type propagation, interface obligations,
dispatch. Records the typed facts (per-node types, resolutions, `call_info`, `op_method` (the arithmetic
operators' methods, and a comparison's `eq` or `cmp` on a struct or enum with one), bound calls,
coercion/deref chains, captures, integer pattern values) that `ast::facts` exposes read-only to
everything downstream; a declaration's slot is written by the item that owns it, every other reader
lowers privately. What a check may read as checked follows the static visibility rule
(`graph::items::visible`), so one worker and every core see the same facts. A module's last
job checks its non-item nodes (`static_assert`), closes the module (the whole-module
lints) and records its post-typecheck item edges. Format-string,
compound-assign and string-switch lowering happen here. Each item's constant-expression
attribute arguments are checked and folded with the item (`tc_attr_exprs`). Deferred `static_assert`s and
constants a check could not fold are queued on the interpreter. Diagnostics and method
marks come out per item and publish in declaration order after the stage.

A rejected type or expression has `TYPE_ERROR` (`src/ast/ast.spc`), never `TYPE_NONE`:
compatibility, inference and bounds accept it without a diagnostic, and a type built over it is
itself `TYPE_ERROR`, so one root error reports once. The Core IR lowering refuses a node or a
generic argument of that type (`Lowerer::failed_on_error_type`), and the checker drops an
evaluation failure it causes (`Interp.err_refused`). A package the stage accepts holds no
`TYPE_ERROR` (`assert_no_error_type`, fatal).

Then `discharge_obligations`: the reflection-bound obligations (a `fields` loop's bound on a
still-generic owner) the call-time check could not run, once every module is typed: a foreign
callee's, and a same-module callee's checked after its caller (one dependency cycle, such as an
interface default calling a `fields` helper; `Ast.ob_seen` records what the call-time check ran).
An obligation that reaches an interface default holds for every conformance that inherits it.
Each call of a method whose obligations name `Self` or a generic extend's parameters records
what its receiver binds (`FrameUse`, `tc_note_frame`), and the discharge substitutes it with the
call's own arguments; a generic default reached with an open `Self` (through a bound or a
projection) becomes a demand (`ProjOb.demand`) that moves up the generic call chain and runs after
the fixpoint (`run_dmd_uses`), for the `Self` types that inherit the default. Bounds are proved per
loop kind (`ProjOb.mode`: `fields`, `variants`, `payloads`): struct fields, every payload of an
enum, a variant's first payload; per-copy guards (`p.index`, `v.index`, `v.tag`, metadata) fold as
the lowering folds them (`tc_binder_cond`), so a skipped copy owes nothing. Emission decides an
instance's static_asserts from the innermost binding of each of its own parameters, grounded
through the demand chain (`cemit_inst_asserts`, `Mangler::ground_l`).

**Freeze point:** at type-check completion every semantic decision table is final; only
append-only interning (the module `pool` and the package type table) may grow later
(`src/ast/facts.spc`), and the publication checkpoints renumber provisional ids in place.
Under `SC_FACTS_CHECK` the driver snapshots watermarks here.

## 5. Borrow Check (`borrowck_all`, `src/borrowck/`)

One independent job per module over its function, method and aggregate items in source
order, on the item job runner (`bc_jobs`; a body split of a module was measured and refused:
its bodies contend on the module's type-pool lock, item-index.md). Before it starts, the driver sets `cir.all_typed` and `record_folds`:
the constant contexts lowering evaluates must behave exactly as under the backend's own
lowering, because **this stage produces the lowerings the backend reuses**.

Per function (`bc_fn`, extending `TypeChecker`):
1. `bc_ir_lower`: lower the item's bodies to Core IR; the Lowerer records an event tape
   at the walk's AST sites.
2. `bc_replay`: replay the tape: the same helper calls the deleted AST walk made,
   without traversing the expression tree.
3. `bc_ir_analyze`: per body, `flow_ir::body_features` reads the typed IR into feature
   bits and `loan_skip` / `stage_skip` decide what runs: nothing, a moves-only fact walk
   plus the move/init dataflow, or the full pipeline (facts generated in Core IR order by
   `borrowck/facts.spc`; solved by `loans.spc`/`dataflow.spc`) inside one reusable,
   budget-bounded `BorrowCtx`; `bc_ir_emit` reports. `SC_BC_VALIDATE=1` runs every
   skipped stage and asserts it found nothing.
4. `bc_elaborate`, per body, over the analyses just built: when an owning local or an
   auto-freeing owning store exists, the move/init solution (built here if the analyses
   skipped it) classifies every storage marker and `ir/drops.spc` rewrites the body with
   `TM_DROP` terminators and flag temps; the inliner's size verdict is recorded first
   (`CoreBody.inline_size_ok`). Under `SC_BC_VALIDATE=1` the structural verifier and
   `verify_drops` check every elaborated body.
   Then `bc_tail_calls` converts the function body's calls to itself into jumps
   (`ir/tailcall.spc`, [core-ir.md](core-ir.md)) and, under `@tail_recurse`, reports each call
   that stays a call (one in a closure of the function too) and a function that never calls
   itself; a converted body is verified again under `SC_BC_VALIDATE=1`.
5. Each spent Lowerer's body and closures are kept as a `KeptBody` in the shared `irl::Keep`
   cache: one elaborated lowering per body, reused by emission (a parallel job keeps its own and absorbs it under the
   engine lock). Every job leases an oracle + context slot from a bounded pool; a module
   is Core IR ready when its job ends; its body syntax stays live until `cemit_package`.
   Diagnostics publish per item in declaration order.

Declaration-level lifetime analyses (return-type elision, aggregate lifetime naming, the
modular return-lifetime check) run alongside.

## 6. Verification Gates (env-gated; no-ops otherwise)

| Gate | Pass | What it checks |
|------|------|----------------|
| `SC_FACTS_CHECK` | `facts_verify("borrowck")` | No decision table changed since typecheck |
| `SC_LAYOUT` | `layout_pass` | Every concrete pool type vs the C layout invariants: a power-of-two alignment that divides the size; each struct field aligned, after the previous one in layout order and inside the struct; an enum's layout equal to `enum_layout` |
| `SC_CORE_IR` | `apply_drops_of` (emission) | Inlined bodies re-verify; every PROVEN bounds check re-proves |
| `SC_BC_VALIDATE` | `bc_elaborate` (borrow pass), `apply_drops_of` (emission) | Skipped analysis stages find nothing; loan sources, move-path parents, init rows and the tight liveness bound hold; every elaborated body verifies and `verify_drops` accepts it |

## 7. Lint, Panic Check, Const Flush

- `lint_unused_items` (when linting). An extend header is an entity of its own: the interfaces
  its conformance and its parameters' bounds name are used by it. Reachability runs over dense
  entry ids, each index item's owner entry found once, the edges bucketed by source. A lint `fix` attaches to the last warning emitted
  (`Errors::last_warn`, `src/utils/errors.spc`), so call it right after the warning it
  repairs. When a lint disagrees with the compiler, suspect the lint first.
- `check_recursion` (`src/ir/recursion.spc`): an **error**, run serially on every build of
  user modules (`lint_reported`: every module outside the std and ffi trees, which check.sh
  lints) and in `lint`, over a summary of each kept function body (`Summarizer`: its
  ends, its calls of reported functions, its branches; the blocks between them left out, so
  drop elaboration and tail-call conversion do not change the answer). The batch check
  summarizes only the members of a cyclic component of the direct-call graph of the kept
  bodies (`check_kept`), a superset of the summaries' calls. The language server
  runs the same `recur::check` over the summaries its borrow round records per module
  (`Package.recur`). A path ends at a return, an `assert`, an `unreachable` terminator, or a
  call of a `@noreturn` or extern C function (a verified intrinsic returns); every other
  call returns. The call graph has the direct calls between the reported functions and
  methods only (no fn-value, `dyn` or bound call). Tarjan gives the strongly connected
  components; one worklist walk per component parks a call of a member not yet known to end
  until that member ends, so each point is visited once. A member that cannot reach an end
  without such a call is reported at its first call, in source order, of a member that does not
  end either (`cannot return without calling itself`, or `... calling 'g', which cannot return
  either`). Unbounded recursion is an error also in tail position: a tail call made a jump
  loops forever. Traps inside a statement, panics or exits inside another function and task
  cancellations (the ladder after a cancellation check, cut at its `cancel_ladder_begin`
  call) are not ends, as in rustc's `unconditional_recursion`. About 4 ms on the compiler's
  own build with a release compiler (`SC_CEMIT_STATS`, `phase recursion`).
- `prove_cached` (`src/driver/emit.spc`) over `prv::check_kept` (`src/prove/prove.spc`): an
  **error**, after `check_recursion`, on every build whose modules state a contract or use a
  pattern type (`any_contracts`) unless `-fno-prove`. Its facts (`check_kept`'s `facts`): each
  bounds check of a body that held on every path the walk reached it (`note_check`), made its
  PROVEN twin in the kept body; the proof record keeps them (`p` lines) for a module it skips. It lowers the contracts of each interface method without a
  body (`lower_shells`), finds the components of the direct calls among the kept bodies that have a
  `decreases` (`components`), then walks each kept body: the paths of its CFG with hash-consed terms
  (`Terms`), the facts of each branch, assignment and callee `ensures` on the path, each obligation
  (a `requires` at a call, an `ensures` at a return, a loop's invariant and measure at its header, a
  checked operation) refuted by `Solver::implies` (`src/prove/solver.spc`, over the terms of
  `src/prove/terms.spc`), first without the facts the walk derives for a division or shift by a
  constant (`holds`), then with them, then without them and with bits (below): a case split into branches (`close`: each
  branch a list of theory literals, `blast::tlit`), then per branch a congruence closure over every
  term operation and a simplex over exact rationals with branch and bound over the integers, which
  exchange equalities (the closure's integer classes become rows; equalities the rows imply between
  operands of one operation merge in the closure); integer equality elimination adds
  Chvatal-Gomory cuts, and the root of branch and bound adds Gomory cuts of a fractional point
  from its tableau rows (`gomory`: a slab of rational points with no integer one, which splits of
  one atom never end); at an integer model that breaks a product, branch and bound splits an
  operand at its value and, below splits that fix it, adds the product's linear rows (`fix`). An obligation over a product of two unknowns that fails
  is tried once more (`oblige`, `has_product`, `nla_allowed`): its branches' simplex rows take
  products of two rows (`nla_rows`, `RW_PROD`: `-(L1 * L2) <= 0` of two rows `L1 <= 0`, `L2 <= 0`,
  at most `NLA_ROWS`), and branch and bound adds, at a model that breaks a product, a tangent plane
  at a corner of its factors' bounds (`tangent`, at most `TANGENTS_MAX`; `nla_attempt`). Each
  refuted branch writes a proof (equality facts, branch-and-bound trees
  with Farkas leaves, cuts, product rows the path's splits justify, products of two rows that
  `product_row` rebuilds from factor rows of the kinds `prod_base` names) that the kernel (`src/prove/kernel.spc`, its own checked arithmetic)
  accepts before the branch counts; the kernel builds the rows of the branch's literals itself
  (`Kernel::state`, `state_lit`, a `Built` only it constructs). With bits, a branch whose literals
  hold an operation the arithmetic reads as an atom (`Terms.bitty`: a bit operation, shift, cast,
  division, remainder, order, product of two unknowns) is first refuted on bits: the literals that
  share unknowns with the goal's (`cone`) become clauses (`src/prove/blast.spc`, trusted: each term
  the two's-complement bits of its exact value, each operation its circuit, an undefined one any
  value of its type), a CDCL solver (`src/prove/sat.spc`: two watched literals, first-UIP learning
  with minimization, activity order, saved phases, Luby restarts) refutes them with an LRAT proof,
  and the kernel checks it (`Lrat::check`, reverse unit propagation over the hints). Each refuted
  branch is a lemma; once every branch closes, the kernel encodes the skeleton of the formulas (each
  atom a variable, an integer equality also its two orders) with the negation of each lemma
  (`seal`), and the hypotheses imply the goal only when it checks an LRAT proof that these clauses
  have no model (`covered`): the case split is checked. Over domains of at most 65536 values the obligation is decided
  by enumeration with an exact evaluator (`Eval`), which also confirms a counterexample; the
  simplex's integer model or the bits' model seeds its candidates. A conformance's method walks again
  from its interface's `requires` (`refine`). Ghost code (language skill, basics.md, Ghost Code):
  in a spec function, a lemma and a ghost site every check is an obligation (`check_fact`), a ghost
  site is walked as code, recursion and loops there need measures (`loops_end`), and a callee's
  `ensures` holds there only for a callee that ends (`total`). `int` and `nat` terms have the exact
  widths `W_INT` and `W_NAT` (no upper bound; never bit-blasted). Each spec call term gets its
  definition once (`define`: the spec body walked without obligations, one disjunction over its
  paths to a return, guarded by its `requires`), anchored on the call and added to an obligation
  whose terms reach it (`add_defs`); a bodiless `@trusted` one is defined by its `ensures`, a generic one
unfolds with the call's type arguments (`subst`), and a sequence result's elements are those of
the sequences its body returns (`alias`). Specifications (language skill, basics.md,
Specifications): a quantifier is a bool atom with a closure and a skolem fact (`quantifier`, never
walked as its loop); a failed obligation adds instances (`instantiate`, `QUANT_ROUNDS` rounds) and
retries without the facts unrelated to the goal (`cone`). The stages: the terms a trigger matches
(`QI_TRIG`; a trigger is a body term that holds the binding, or the argument of each
`std::spec::quant::trigger` call the body's walk meets, `utrig`; `match_at` matches at any depth,
`MATCH_WORK` steps per match), then where the formulas hold more than `QUANT_TERMS` integer terms
the terms the failed check's model puts in range, one per value (`QI_MODEL`, `model_instances`,
`MODEL_ROUNDS` rounds), then every integer term (`QI_WIDE`).
`old` sites are values of the entry state, a callee's evaluated in the frame before the call; a
ghost `old` snapshot is an `LK_GHOST` local, which no code drops (`verify_drops` skips it). A `&mut` parameter's target
is a slot past the locals (`T_MREF`); a reference to a member of a local or slot is a `T_PREF` (the
local or slot and the member keys), so a call that borrows `&mut q.v` changes only `q.v`, and a loop
forgets every place it lends by `&mut`. `Seq` is native: `SQ_*` function
terms whose length and element facts are anchored on them (`seq_make`, `seq_at`), extensional
equality (`seq_ext`); `view()` of a vector or string is a function of its value, of a `[]mut T` of
its value and memory epoch, of a `[]T` of its value only (`slice_ep`), and `sq_kind`, `sq_value` and
`sq_effect` model the container methods' views (`vk_change`: `VK_SET` to `VK_SWAPREM`; `decided`
takes a case split's branch the path facts decide). A struct's invariant is `S::invariant(&v)` (`inv_of`, the extend's
parameters bound to the instance's arguments): a fact of every value of the type outside the struct's
module (`inv_fact`, from `pat_fact`); in it every non-ghost body that holds the type is walked
(`inv_body`), assumes the invariant at the entry and after each call (`inv_enter`, `inv_called`) and
proves it (OB_TYPE_INV) at returns, calls, drops and every point that may panic (`inv_unwind` over
`inv_locs`). The block of an `@owned` field is the value's ghost member (`own_key`), a `Seq`: an index
through the field is `seq_at`/`SQ_UPD` with a bounds obligation (OB_BLOCK, `own_check`); an index
through any other raw pointer is memory (a load in the epoch, a write a memory event: `ptr_index`); a
memory event forgets the blocks the body copies the pointer of (`own_scan`); an allocator's call keeps
them and its result sets the block it is stored as (`alloc_call`, `own_after`); `std::spec::seq::block`
reads it (SQ_BLOCK). `null` and `sizeof(T)` are one term each (`null_ptr`, `size_term`). A product is distributed over sums with its factors ordered
  (`Terms::product`); a hypothesis's split and the goal's integer disequality wait until the
  branch's other formulas are done, and the theories first try the literals so far. Every walk,
  search and elimination has a fixed budget;
  over one is not proved. The prover is generic over its numbers' width (`Prover<B>`,
  `terms::Num<B>`): a body proves with 256-bit numbers, or with 576-bit ones when a local's integer
  type is wider than 192 bits (`needs_wide`; `int_limit(B)` is the widest type a width reads, 512
  bits for 576), so wide numbers cost only the bodies that need them. `UInt<N>` and `Int<N>` are
  integers through their std conformances, read as the integer operations (`wide_kind`, `wide_op`),
  and the built-in integers' `wrapping_add`, `wrapping_sub`, `wrapping_mul` and `wrapping_neg` are
  the casts of the exact results, `rotate_left` and `rotate_right` their shifts (`rotated`).
  With more than one job, the bodies run on workers one at a time (`dpar`
  Dynamic schedule, grain 1; a narrow and a wide `Prover` each, the shells and components read from
  `Shared`),
  their reports merged by body and position, so the output equals the serial one. A
  `@prove_exhaustive` function skips its walk: `prove_exhaustive` sets up its inputs
  (`exhaustive_job`: a domain per parameter, `pdim`, narrowed by solver queries on its `requires`)
  and runs each through `Interp::prove_run` on the kept body, contract chains in place, within an
  equal share of `PE_STEPS`. The inputs run on the workers one at a time, one evaluator each; a
  worker skips an input after the least failed one found so far (`PJob.first`), and `report_part`
  reports the least, so the output equals the serial one. With several workers the stage locks are
  on while the proofs run (the runs lower callee bodies); the `used` records the runs mark are
  rolled back after `check_kept`. Modules whose key the build tree's proof record
  holds are skipped (binary skill, build-toml.md). Then `skip_kept_contracts` empties the chains
  the build does not check (core-ir.md, Contract sites).
- `check_always_panics`: an **error**, run on every build of user modules: one job per
  linted module on the item job runner, a private engine leased per worker (the serial
  path scans with the master engine; a private one starts with the master's `ran0`),
  diagnostics published in declaration order.
- `cir.flush_asserts` / `flush_consts`: the deferred static_asserts and consts
  re-evaluate now that every module is fully typed; failures carry the CTFE stack. A
  `static_assert` outside a generic body (top level, or the body of a non-generic function or
  method) that still does not fold is an error (asserts inside generic bodies depend on the
  generics and stay deferred). Between the two, `flush_inst_asserts` evaluates the
  static_asserts of the generic-function instances the checker's concrete calls queued
  (`Interp.inst_asserts`; the per-instance asserts of the CTFE section of the skill). The
  instances that only other generic bodies reach are checked after the instance graph
  (section 10).
- Test plan construction (`--test` builds).

## 8. Runtime + External C (`write_super_rt`, `ext_c_collect`)

`super_rt.h` is written into `gen_root` (default `<root>/build/<profile>/raw`; manifest builds point
it into their out-dir). The C emitter owns it (`src/emit/rt_h.spc`): the libc includes, the atomic
shims, the prototypes of the runtime entry points the emitted code calls (`std/rt/base.spc` defines
them), and
the integer arithmetic helpers the emitter calls where a C operator lacks the language's
meaning (`CEmit::arith_fn`): `__sc_<op>_<type>` for `+ - *` of every integer type and signed
negation (checked through `__builtin_*_overflow`, or wrapping under `-DSC_ARITH_WRAP`; a narrow
unsigned result truncates), signed and narrow unsigned `<<`, narrow unsigned `~`, `/ % << >>`
whose right operand is not a constant that rules out the trap, and `__sc_f2i_<type>` for the
saturating float-to-integer cast; a float `%` emits `fmod`/`fmodf`. The checker rejects unsigned
negation, so no unsigned `__sc_neg_*` exists. std's `Int<N>` and `UInt<N>` operators call the runtime's `sc_int_overflow` on overflow: it
traps, or returns under `-DSC_ARITH_WRAP` and the operator keeps the wrapped value; the IR
interpreter intercepts it as the built-in "arithmetic overflow" trap, and `sc_has_i128` and
`sc_has_f128` (the runtime's 128-bit probes) as 0, so 128-bit integers and the 64x64
products and 2-by-1 divisions of the wide integers evaluate through the limb code at compile time,
and so do the `Float<E, F>` formats. The interpreter reads a union through the member last written,
or through another scalar member of its width (`f64_bits`: the bits retyped, `Interp::repun`); any
other member is no compile-time value, so a `String` past its inline bytes (23 on a 64-bit target),
whose union shares its length byte with the heap capacity, does not fold. A call's frame and every
object it allocates belong to the call's region (`IObj.lvl`) and are released when it returns,
except what it returns or stores into older storage; constant frames, heap blocks, literal bytes
and item cells live to the end of the evaluation, and `free` returns a block's slots to the
budget. The memory budget (`--const-eval-memory`, bytes over 24-byte `IVal` slots) charges slots
and each object's header (`OBJ_SLOTS`), and no object or call count limits an evaluation. The copies
a frame overwrites stay charged until the frame returns, so a long loop in one frame (a wide
float's text) can still meet the budget. A pointer into a returned call's storage
that outlives the call keeps the object as a dead header: reading through it traps "use after
return". The
interpreter also models the runtime's bit helpers (`sc_ctz64`, `sc_clz64`, `sc_popcount64`, the
wrapping `sc_w*64` and `sc_mulo_*64`), evaluates an f32 libm function as the f32 function the
program links (`libm1f`, `libm2f`: `acosf` for an f32 `acos`, never the f64 result narrowed), so a
constant equals the run-time call bit for bit where the compiler and the program use one libm. Where
the target's C library comes from std (wasm: `Package::rt_libm`), an extern call whose C symbol (its
`@import` string, else its name) `std::rt::libm` exports runs that function's body instead
(`libm_def`), so a cross build's constant equals the program's call too. It folds the cancellation probe
(`SI_CANCEL_PROBE`) to 0, as it folds `IN_SAFEPOINT_C` (no task exists at compile time; see the
concurrency skill). An integer loop step renders as `for (..; i++)` (or `i--`)
only when it cannot overflow (`CEmit::step_bounded`): the header tests `i < e` (`i > e` for `--`)
with `e` of `i`'s type, and nothing else in the loop writes `i` or takes its address; every other
step keeps its checked helper and renders as `while`. `@link` flags land in `__ldflags`; the
build compiles no C source of the program's tree.

## 9. Emission Planning

- `compute_emit_live`: reference scan for live modules. The runtime module's type marks are
  skipped: it names no prelude item, and the `str` type of its literals (which lower to C strings)
  would make the prelude live in every program.
- `Package::emit_order`: dependency-first module order: if module `a` re-homes a
  concrete instance of a generic owned by `b`, `b` emits first. Kahn topo-sort with a
  lowest-id tiebreak. Each module's row (`emit_dep_row`) reads its live body syntax.

## 10. TU Emission (`cemit_package`, `src/emit/`)

- `ensure_sigs` (which also groups the conformances by interface, `PkgIndex.confs`, for
  `conf_holds`), then `InstGraph` (`src/graph/instances.spc`) seeded with the `irl::Keep`
  cache; `collect()` discovers every concrete instantiation by walking the kept Core IR
  bodies from concrete roots (every concrete body of every module that emits; dead
  prelude modules seed nothing), expanding generics under substitution frames
  (package-stable keys: decl DefId + the final TypeId of every argument). Bodies flagged
  `has_reflect` or `has_zst_cond` re-lower per instance instead of sharing; the census
  and the decision that keeps it so are in
  [instance-specialization.md](instance-specialization.md).
- `graph_inst_asserts`: the static_asserts of every demanded instance of a generic function
  or method the graph found (`InstGraph::assert_binds`). Then `Package::release_bodies`
  frees every module's body arena: the one release point of a batch build
  ([syntax-ownership.md](syntax-ownership.md)).
- `TuEmit` (`emit/tu.spc`) renders each module's TU into `CemitOut` buffers (one
  geometrically grown `tus[t]` per module, a chunk table with the shard each chunk landed
  in, `inst_c` for every owner module's instance shards), a parallel frontier under
  `--jobs`, gated by `SC_BUILD_MEM_BUDGET`. A body renders straight into its TU buffer
  (`emit_body_core_cf` threads it through the statement renderers; expression renderers
  spell into their `dst`), and the driver writes each shard piecewise, never a file
  image. Every module-prefix spelling records a (context -> owner module) edge, typed as
  a type name or another symbol; those rows select each shard's include list
  ([output-layout.md](output-layout.md)).
- **Per-body preparation** (`DropCtx::apply_drops`): a kept body arrives elaborated by
  the borrow pass; a body emission lowered itself (a per-instance re-lowering, a macro
  wrapper) is elaborated here first (`ird::may_schedule`, forest, moves-only facts, CFG,
  move dataflow, `ird::elaborate_into` + `ird::insert_drops`) and its calls to itself become
  jumps (`irt::convert`; the borrow pass converted the kept bodies). Then the inliner splices
  elaborated callees (their drops, flag temps and markers come along; no ownership
  analysis runs on the merged body), then bounds-check elimination, then rendering. Rendering
  first decides each local's C spelling: `setup_locals` (coalescing, folds), then
  `emit_body_core_o` over the CFG (copy coalescing, array elements, discarded results, deferred
  result copies, loop bounds, declarations at their initializing writes, call forwarding; see
  Direct C in [SKILL.md](../SKILL.md)).
  Free-glue wrapping (`<sym>__fb`) covers user `free` bodies that skip owning fields.
- A designated array literal (`[[i] = v]`) has the type of its spelled count, not the
  destination's length. A store of a shorter source zero-fills the destination, then
  copies `sizeof` the source (`short_src` in `src/emit/cemit.spc`); every consumer sizes
  copies by the source.
- Symbol naming through `emit/mangle.spc` (the frozen authority): prefixing only with
  more than one non-prelude module besides the runtime (whose symbols always take its prefix);
  single-segment prefix when unique; prelude, `main`, and extern symbols never prefixed.

## 11. Write-Out (serial, in the driver)

Transitive TU pruning first: keep scan-live modules plus everything a kept TU spells
symbols from. Then, in emit order:

1. `__sc_fwd.h`, every definition header `__sc_t/<type>.h` (one per emitted type) and
   every `<module>.h` (prototypes, `_ret` typedefs, constant and descriptor
   declarations), before any source file.
2. Per-module `.c` shards (`<module>.c`, then `<module>__p<k>.c` under the build.toml
   `[shards]` count: a chunk's shard is its stable symbol hash modulo the count). Module
   paths map to directories (`::` → `/`); the prelude loads under the reserved `__std::`
   namespace, so it lands in `__std/` and never collides with a user `std/` directory.
3. Per-owner instance shards `<module>__inst.c` (+ `__inst__p<k>.c` under
   `[instance-shards]`): generic instances, glue, constants, descriptors and dyn tables
   the module owns; then `__sc_registry.c` in every program (the external definitions of the runtime header's inline
   helpers, ZST sentinels, reflection registry).
4. The per-TU cache image is published only after a fully successful emission, then
   `__sc_manifest` (atomically: temporary + rename).
5. `prune_orphans`: outputs from a previous build that this one no longer emits are
   deleted.

Under `SC_FACTS_CHECK`, `facts_verify("codegen")` runs at the end: emission must have
read the tables frozen (append-only interning is the one sanctioned growth).

## 12. Test Runner (`--test` only)

`write_test_main` synthesizes `__test_main.c`: extern wrapper prototypes, the test table
(display names `module::fn` / `module::Type::method`, wrappers, `should_panic` flags, timeouts),
the global-env hooks, and a `main` that passes them to `sc_test_main`. The runner is the module
`std::rt::test` (`std/rt/test.spc`), which the loader adds to test builds only
(`Package::rt_test`): a runtime module like `std::rt::base` (`Package::is_rt`), so its symbols
keep their module prefix and the program's own mangling does not change. A `--target=wasm` build
loads wasm's C library the same way: `std::rt::libc` and `std::rt::libm` (`Package::rt_libc`,
`rt_libm`, `Package::is_libc`), runtime modules whose `@export` functions are the C library's
functions. It selects the tests
(filter, shards balanced by recorded durations), runs each in its own process (POSIX: a fork
pool; Windows: the binary again with `--run-one`), enforces the timeouts, and reports.

## 13. C Compilation

External `cc` invocation over the emitted tree plus `$(cat __ldflags)`. Incremental,
parallel, content-fingerprinted, longest-job-first; the window is bounded by the same
`--jobs` count.
