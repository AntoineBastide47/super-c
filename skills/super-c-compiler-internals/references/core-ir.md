# Core IR Reference

Source of truth: `src/ir/core.spc`. The Core IR is the typed, control-flow, **non-SSA**
executable form every body lowers to: one `CoreBody` per function, method, closure, or
constant initializer. Storage is dense append-only vectors of u32-indexed records with
**body-local pools**: no per-node heap allocation, no pointers into other stages. Types
are the owning module's TypeIds; syntax is referenced only through spans and the
optional origin NodeId kept for diagnostics.

## CoreBody

```superc
pub struct CoreBody {
    pub owner: DefId,          // the function/const decl this body lowers
    pub module: ModuleId,
    pub args: u32,
    pub returns: u32,
    pub is_generic: bool,      // may carry symbolic types
    pub has_reflect: bool,     // unexpanded reflection binder: instances must RE-LOWER
    pub has_zst_cond: bool,    // unfolded sizeof-vs-const branch: instances re-lower
    pub has_uninit_decl: bool, // some `let x: T;` had no value: init dataflow needed
    pub locals: Vector<LocalDecl>,
    pub blocks: Vector<BasicBlock>,
    pub statements: Vector<Statement>,
    pub places: Vector<Place>,
    pub projections: Vector<Projection>,
    pub operands: Vector<Operand>,
    pub rvalues: Vector<Rvalue>,
    pub constants: Vector<Constant>,
    pub oper_pool: Vector<OperandId>,  // argument/aggregate operand ranges
    pub dest_pool: Vector<PlaceId>,    // call destination ranges (multi-return)
    pub switch_pool: Vector<u64>,      // TM_SWITCH pairs: value<<32 | target
    pub targ_pool: Vector<TypeId>,     // generic-argument ranges
    pub user_moves: Vector<u64>,       // bit per operand: OP_MOVE is a USER consumption
    pub simd_aux: Vector<u32>,         // RV_SIMD index lists: the length, then u8 lanes four to a word
    pub demands: Vector<Terminator>,   // inlined calls whose instance the emitter still demands
    pub entry: BlockId,
}
```

`CoreBody::clear` re-seeds for a fresh body keeping every pool's capacity: one Lowerer
is reused across bodies.

## Locals

`LocalDecl { ty, storage, is_mutable, dkind, span, decl, name_off, name_len, item }`
(32 bytes; the analyses copy it by value) with storage classes. `dkind` is an `LK_*`
declaration kind, and `name()` is the binding's
name text (an offset and length inside `span`): what the emitter reads of a user local after
the body syntax is released.

| Constant | Meaning |
|----------|---------|
| `LS_ARG` | Argument |
| `LS_RET` | Return slot |
| `LS_USER` | User variable (`decl` = its binding node) |
| `LS_TEMP` | Compiler temporary |
| `LS_STATIC_REF` | Reference to an item (global/static); `item` names it |

## Places and Projections

A `Place` is a base local plus a projection **range** into `projections`
(`{ base: LocalId, proj_start, proj_len, ty }`), applied left to right:

| Kind | Meaning |
|------|---------|
| `PJ_DEREF` | Dereference |
| `PJ_FIELD` | `data` = stable field index, `sub` = field decl NodeId (`data == PJ_UNION_FIELD` marks a union member; fields alias) |
| `PJ_INDEX_CONST` | `data` = constant index |
| `PJ_INDEX_OP` | `data` = OperandId of the dynamic index |
| `PJ_DOWNCAST` | `data` = variant index, `sub` = variant decl NodeId |

Pattern lowering dereferences a place (`PJ_DEREF` through every reference and pointer
layer) before a downcast or a value test, and types each sub-place from its member
declaration. A by-reference binding is `RV_REF` of the matched place.

A guard-free match lowers through the decision tree of the pattern compiler
(`src/pattern/pattern.spc`). An integer column reads each value and range from the checker's
record (`TypedFacts::pat_value`, in the matched type) and tests the pieces its bounds split the
type's domain into: every edge keeps each row that holds its piece, and a piece equal to a written
pattern keeps that pattern's spelling. A column whose literals may spell one value (a float, an
escaped string, an integer with no record) keeps the arm-order chain. A builtin limit that
literal-only arithmetic or a pattern reads in another integer type lowers to that type's literal
of its value (`Lowerer::retyped_int_const`): the constant's C object has its own type.

Each `Projection` carries the type **after** it applies.

## Operands and Constants

`Operand { kind, data, ty }`:

| Kind | Meaning |
|------|---------|
| `OP_COPY` | Read a place (`data` = PlaceId) |
| `OP_MOVE` | Read and consume (`user_moves` marks user-visible consumptions) |
| `OP_CONST` | `data` = ConstId |

`Constant` kinds: `CK_INT`, `CK_FLOAT` (raw span keeps the literal spelling), `CK_BOOL`,
`CK_STR`, `CK_UNIT`, `CK_ITEM` (resolved DefId + bound generic args in `targ_pool`; the range is packed into
`val`, read with `targ_start()`/`targ_len()`),
`CK_WIDE` (wide-literal record index), `CK_ERROR` (error recovery).

## Rvalues

`Rvalue { a, b, target, item, kind, c }`: packed to 24 bytes; one record per expression:

| Kind | Meaning |
|------|---------|
| `RV_USE` | `a` = OperandId; `b` = 1 (shared) or 2 (mutable) for an array's slice view, which borrows the array |
| `RV_REF` | `&place`; `b` = 1 when mutable |
| `RV_ADDR` | Raw address of place; `b` = 1 when `*mut` |
| `RV_UNARY` / `RV_BINARY` | Operand(s) + token op; over vector types the operator applies its scalar rule to each lane (a `<<`/`>>` count may be a scalar of the lane type) |
| `RV_CAST` | `b` = CastKind: `CAST_NUMERIC` (every `as` cast and every coercion with no library method: numeric, pointer, reference), `CAST_COERCE_FROM` (library `from`; `item` = selected method), `CAST_SIMD_ARRAY` (`[T; N]` to `Simd<T, N>` or back, the same lanes: an array literal with an expected vector type, and `std`'s casts; the emitter spells a `memcpy` statement, never an expression) or `CAST_MASK_BITS` (`Mask<N>` to `u64` or back, an integer conversion that truncates to the lane bits) |
| `RV_AGGREGATE` | Operand range; `c` = `AGG_STRUCT`/`AGG_TUPLE`/`AGG_ARRAY`/`AGG_VARIANT` |
| `RV_REPEAT` | `[elem; count]`: `a` = element OperandId, `b` = count OperandId |
| `RV_LEN` / `RV_DISCRIMINANT` | Of a place |
| `RV_DYN` | Dynamic-interface construction |
| `RV_CLOSURE` | Capture operand range; `item` = closure body owner |
| `RV_INTRINSIC` | `c` = IntrinsicKind: `IN_SIZEOF`, `IN_ALIGNOF`, `IN_VA_START/ARG/END`, `IN_TYPE_INFO`, `IN_ZEROED`, `IN_REFLECT`, `IN_ASM` (the rvalue's `item.node` indexes the body's `asms` text record), `IN_SAFEPOINT` / `IN_SAFEPOINT_C` (loop preemption tick, plain or with the cancellation check), `IN_CHUNK` (a strip-mined counted loop's chunk end: operands `(i, end)`, result `lim` with `i < lim <= end`; BCE reads `lim <= end`), `IN_DANGLING`, `IN_BOUNDS_GROUP` / `IN_BOUNDS_GROUP_PROVEN` (index, length, width: BCE coalescing's check of a run of element accesses, and a vector load's or store's, see `RV_SIMD`), `IN_BOUNDS` (an element check; on a vector lane index `item.node` is `CHECK_LANES` and the length operand is the lane count, a constant when known: the trap names the index and the count, through `__sc_lane`, which the vector's definition header carries, and BCE never groups it), `IN_DYN_TID`/`IN_DYN_DATA` (dyn_cast), `IN_NEW` (heap alloc through `__sc_new`, which panics "out of memory" on a null result; a zero-sized `T` allocates 1 byte and stores nothing), `IN_LIKELY` (the success test of `?`: returns its one bool operand; the emitter spells `__builtin_expect(x, 1)` and folds it into its branch, because clang drops a hint read through a variable) |
| `RV_SLICE` | Structural `base[lo..hi]` view, kept structural so end-openness survives |
| `RV_SIMD` | A named vector operation: `a`, `b` = operand range in `oper_pool`, `c` = the `SIMD_*` code, `target` = result type; `item.node` = the start of its index list in `simd_aux` (`SIMD_SWIZZLE`, `SIMD_SHUFFLE`), else `IR_NONE` |

`RV_SIMD` codes are indexes of `SIMD_OPS` (`core.spc`, append-only), one row per code: the
intrinsic name (`@intrinsic("simd.<name>")`), the operand count, the type rule (`SR_*`: the vector
operands and result alike, a mask result, `choose`, other lanes, a bitcast, halves, `concat`,
`iota`, a load, a store), the lane class (`SE_*`), the memory effect through operand 0 (`SM_NONE`,
`SM_READ`, `SM_WRITE`). One code covers every lane kind, as `RV_BINARY` does:
`SIMD_MIN`/`SIMD_MAX` are IEEE minimumNumber/maximumNumber on float lanes, `SIMD_ABS` clears a
float lane's sign bit. Lane-wise `as` (`cast`, `widen`, `narrow_wrapping`) is `RV_CAST`
`CAST_NUMERIC` over vectors; `checked_*` and `cast_checked` are std compositions of the wrapping
operation (or the cast) and `SIMD_OVF_*` (or `SIMD_CAST_CHANGED`, whose operands are the source and
the cast result). `SIMD_LOAD`/`SIMD_STORE` take the slice, then a start that is the result of an
`IN_BOUNDS_GROUP(start, len, N)` with `item.node` = `CHECK_VEC` (the verifier requires that kind;
`N` is the lane count, the const-generic parameter in a generic body): the second producer of group
checks, whose trap names the lanes, the start and the length (`__sc_bounds_vec`) and which BCE
proves like an element check of the last lane (`IN_BOUNDS_GROUP_PROVEN`) when `N` is a constant. A
proven or kept check records the fact of its last lane (of each lane up to 8), and a slice built by
a struct literal (`Slice { ptr, len: n }`) matches the facts of `n` (`ir::facts::Facts::view_len`). `SIMD_LOAD_RAW`/`SIMD_STORE_RAW` take a raw pointer; the aligned std
forms are the unaligned ones after a `static_assert`, so no record carries an alignment. The
effect query (`ir::facts::stmt_effect`) gives a store `EF_PTR` through operand 0; a load writes
only its result. The interpreter runs the lane loop over the scalar rules; the emitter writes a
lane loop with a constant trip count, or `memcpy`/`memmove` for the byte-moving codes. A trapping
operation writes a scratch result and ORs each lane's failure predicate into a flag (a form C
compilers vectorize, so no `__builtin_*_overflow` below 64-bit products); only a set flag runs a
second loop that collects the failure bit per lane and traps once at the lowest (`__sc_panic_lane`,
`lane <i>: <message>`, `ir::lane_trap_msg`), from the unchanged operands. The vector type's
definition header carries the lane runtime, so a program without vectors emits none of it. A call of an `@intrinsic`
function lowers to its operation (`Lowerer::lower_intrinsic`); its declaration's empty body lowers
to the same operation over the arguments, for a bound call or a function value. An argument of a
reference parameter (an operator's `&Self`) is read through; a reference passed to a pointer
parameter stays the address.

The rearranging, reducing and masked memory codes (rules `SR_INDEX` and up):

| Codes | Operands | Result |
|-------|----------|--------|
| `SIMD_SWIZZLE`, `SIMD_SHUFFLE` | `(v)`, `(a, b)` and the index list | `M` lanes of the element |
| `SIMD_SWIZZLE_ZERO`, `SIMD_SWIZZLE_OOB` | `(v, idx)`, `idx` `M` unsigned lanes | `M` lanes, or `Mask<M>` of the indexes past `N` |
| `SIMD_COMPRESS`, `SIMD_EXPAND` | `(m, v, fill)` | the vector |
| `SIMD_REDUCE_*`, `SIMD_ARG_*` | `(v)` | the element; `bool` for `SIMD_REDUCE_ADD_OVF`/`_MUL_OVF` (the exact result does not fit); `usize` for the `ARG` codes (`N` when every lane is NaN) |
| `SIMD_DOT` | `(a, b)` | a scalar of the lanes' kind at least as wide |
| `SIMD_LOAD_OR`, `SIMD_LOAD_MASKED`, `SIMD_GATHER` | `(slice, start or idx, [m,] fallback)` | the vector |
| `SIMD_STORE_MASKED`, `SIMD_SCATTER`, `SIMD_COMPRESS_STORE` | `(slice, start or idx, m, v)` | unit; `usize` count for `COMPRESS_STORE` |
| `SIMD_GATHER_PTR`, `SIMD_SCATTER_PTR` | `([*const T; N] or [*mut T; N], m, fallback or v)` | the vector, unit |
| `SIMD_LOAD_MASKED_PTR`, `SIMD_STORE_MASKED_PTR` | `(pointer, m, fallback or v)` | the vector, unit |

An index list is `simd_aux[start]` = its length `M`, then its lanes four `u8` to a word, low byte
first (`ir::aux_lane`); the lowering evaluates the list (`Interp::eval_lanes`) under the instance
env, holding the engine lock, and keeps each list per substitution. A shared generic lowering
whose list or lane count names a parameter keeps no list (`item.node` = `IR_NONE`) and sets
`CoreBody.has_lists`: every instance re-lowers where both are known, as for `has_reflect`, and the
inliner re-lowers such a callee under each call shape's bindings (`InlineCtx::relowered`, when the
kept body drops nothing). An instance's list that does not evaluate or names a lane past the
operands is `Lowerer::user_err` with `user_msg`: the lowering goes on (the lanes read lane 0), the
emitter reports it with the bindings (`cemit_inst_error`), and the evaluator traps with it. The inliner appends the callee's
`simd_aux` and shifts `item.node`; the printer prints the list after the operands. The verifier
checks the list against the result's lanes and the operands' lanes, the mask widths, unsigned
index lanes (`u32`/`u64` for a gather or scatter), and the pointer array's length.

The memory column: `SM_READ_LANES` (the masked loads and gathers) and `SM_WRITE_LANES` (the masked
stores, scatters and `compress_store`) touch one element per active lane at a lane-dependent
address; `ir::simd_writes` covers `SM_WRITE` and `SM_WRITE_LANES`, and the effect query gives every
writing code `EF_PTR` through operand 0. Their range checks are part of the operation (they depend
on the mask), not `IN_*` intrinsics: the interpreter and the emitter check every active lane first
and trap once at the lowest (`__sc_mem_oob`, or `__sc_bounds_vec` for `compress_store`), then access
each active lane's element alone, in lane order. Reductions fold in the order their definition
fixes; `SIMD_REDUCE_*_OVF` tests the exact result (a 128-bit sum; a product with no zero lane only
grows past 64 bits).
## Statements

`Statement { kind, place, rvalue, a, span }`:

| Kind | Meaning |
|------|---------|
| `ST_ASSIGN` | place = rvalue |
| `ST_STORAGE_LIVE` / `ST_STORAGE_DEAD` | `a` = LocalId; the DEAD markers at scope exits are the lexical drop points drop elaboration classifies |

## Terminators and Blocks

`BasicBlock { stmt_start, stmt_len, term, sealed }`: a statement range plus exactly one
terminator; the verifier rejects unsealed blocks. `Terminator` is 68 bytes and `BasicBlock` 80
(`static_assert`s in `core.spc`):

| Kind | Meaning |
|------|---------|
| `TM_GOTO` | `t0` = successor |
| `TM_SWITCH` | `a` = discriminant OperandId; (value, target) pairs in `switch_pool`; `t0` = otherwise |
| `TM_CALL` | `callee` DefId (node `NODE_NONE` for fn-value calls); args in `oper_pool`, destinations in `dest_pool` (multi-return), bound generic args in `targ_pool`; `iface` = `dyn I<args>` for a call of a generic interface's method through a bound, an operator through a bound, or an inherited default of a generic interface on a concrete receiver (the conformance each instance and the evaluator dispatch to), else `TYPE_NONE`; `recv` = the type parameter an interface's associated function is called through (`T::count()`: the implementor, whatever the result or first argument), else `TYPE_NONE`; `t0` = normal continuation |
| `TM_RETURN` | Return |
| `TM_DROP` | Drop a place; `t0` = successor (inserted by drop elaboration) |
| `TM_ASSERT` | `a` = condition OperandId; `t0` = success |
| `TM_UNREACHABLE` | Unreachable |

`Terminator.intr` (in the tail padding) tags a `TM_CALL` of a verified intrinsic: the lowering
(`Lowerer::call_intr`) sets it when the callee is an extern function `ir::ci_of_name` names, the
argument count is `ir::ci_arity` of the kind, and the first argument is a pointer (`CI_FENCE` has
no pointer). The kinds are append-only: `CI_NONE`, `CI_MEMCPY`, `CI_MEMMOVE`, `CI_MEMSET`,
`CI_ATOMIC_LOAD`, `CI_ATOMIC_STORE`, `CI_ATOMIC_RMW` (swap, add, sub, and, or, xor),
`CI_ATOMIC_CAS`, `CI_FENCE`. The call stays an ordinary call for the borrow replay, the inliner and
the C renderer. CTFE dispatches `memcpy`, `memmove` (overlap-safe) and `memset` on the tag (a call
through a function value names the routine); atomics are not evaluable. The verifier rejects a
tag on an unresolved call, with another arity, of an unknown kind, or on another terminator. The
printer writes ` intrinsic <kind>` after the call's arguments.

## Effects and Facts (`src/ir/facts.spc`)

The fact service over one final elaborated body; bounds-check elimination (`ir/bce.spc`) is its
first client and keeps only its proof rules (affine index facts, length identities, coalescing,
panic-guard folding).

- **Memory effects.** `stmt_effect` and `term_effect` are pure functions of the body:
  `EF_WRITE` (a place, through a deref or not), `EF_PTR` (a write through a pointer operand: a
  memory intrinsic, an atomic store, read-modify-write or compare-exchange), `EF_SYNC` (an atomic
  load or fence with a non-relaxed order: other threads' writes become visible), `EF_CALL` (an
  unknown call, with the locals it receives by mutable reference), `EF_DROP` (a drop whose type
  has glue), `EF_ASM` (inline assembly: an unknown heap write plus its output places), `EF_NONE`
  (a relaxed atomic load or fence, the prelude `len(&self)`, a drop without glue).
- **Versions and generations.** A value fact keys on (local, version); a length identity on
  (place, heap generation, base generation, path generation, buffer generation). A write into one
  subtree of a base logs a path kill; a place survives the logged kills that do not overlap it
  (different fields, different constant indexes). A write into a prelude view's element buffer
  (`ptr` field then index or deref) bumps only the buffer generation, which only places heap
  memory may hold compare. An unknown write cannot reach the deref-free storage of a local whose
  address never escaped (`reachable`). Versions and generations come from one clock that runs
  across bodies; each body and each `kill_all` raises a floor every older value reads as, so no
  per-local table is cleared. Entering a block gives a fresh version to every local written since
  its immediate dominator was left (a log of writes; the dominators come from the forward
  predecessors in the same pass as the predecessor lists); entering a loop header does the same
  for everything the loop's blocks can write (a summary per block, made once per body from single
  definitions and the same transparency rules), so one version names one value on every path.
- **Escapes.** The escape set (raw addresses, mutable borrows stored or used past derefs, copies
  and calls, references cast to raw pointers) comes from one scan of the body before the walk,
  resolved through single definitions; an unresolved one disables call transparency for the body.
  BCE walks each body once.
- **Integer facts.** Per tracked integer local: an interval in exact sign-magnitude arithmetic
  at the target width (a possible wrap gives the type's range), a stride and phase (the value is
  `phase + k * stride`), known-zero and known-one bits. Transfer functions cover `+ - * / %`,
  masks, shifts by a constant, numeric casts, lengths of fixed arrays, the checks and `IN_CHUNK`;
  a comparison refines both operands on each branch edge. One worklist in reverse postorder solves
  block-entry states (sparse, sorted lists of tracked locals) with a dense scratch per visit, joins
  keep the hull, a loop header widens a bound that grows after two back-edge changes, and one
  narrowing pass follows the fixed point. The facts solve on demand: only in a body with a fixed
  array checked, a length compared with a constant of 2 or more, or a remainder by a constant
  (`want_ints`), at the first check the earlier rules leave unproven whose length is such a length
  (or an alignment is bound); the walk then replays the current block. The tracked locals are the
  checks' operands, what their definitions read, and the sides of comparisons with a tracked side.
- **Limits.** Every table is bounded (64 exposed scalars, 16 escaped roots, 256 path kills, 64
  facts per block-entry state, a pool of 65536 entries, 8 visits per block plus 64, the loop-scan
  work); past a bound the fact becomes unknown, `ilimited` is set and BCE records
  `BR_RESOURCE_LIMIT`. A body with no check, or none that needs them, allocates no solver state.

## The Borrowck Replay Tape (`TP_*`)

Recorded by the Lowerer at the walk's AST sites (synthetic/desugared lowering never
records); consumed by `bc_replay`. Entry encoding: `kind << 56 | aux << 32 | node`.

Events: `TP_SCOPE_PUSH/POP`, `TP_NLL` (non-lexical borrow end point), `TP_MARK_PUSH/POP`,
`TP_LET`, `TP_LET_TUPLE`, `TP_ASSIGN_PRE/POST`, `TP_RET_VAL`, `TP_RET_POST`,
`TP_CALL_MARK`, `TP_CALL`, `TP_REF`, `TP_CAST_ERASE`, `TP_SLICE`, `TP_CLOSURE`,
`TP_FLOW_SAVE/ELSE/JOIN`, `TP_LOOP_PUSH/POP`, `TP_BODY_START/END`, `TP_MATCH_PRE`,
`TP_ARM`, `TP_ARM_END` and `TP_MATCH_POST`.

There are no `TP_BORROW`/`TP_MOVE`/`TP_DROP` events: borrows and moves are ordinary IR
operands (`RV_REF`, `OP_MOVE`); the tape carries the *walk structure* the flow helpers
need.

## Lowering Contract (`src/ir/lower.spc`)

- Consumes ONLY the typed-facts boundary (`ast::facts`) plus syntax and spans: every
  semantic decision is read from recorded facts, never re-derived.
- Documented evaluation order: receiver before arguments, arguments left to right;
  short-circuit `&&`/`||` evaluate the right operand only on the deciding path;
  assignment evaluates the target place FIRST, then the value; aggregate fields in
  source order; match scrutinee once, arm tests in order, guard after bindings; `defer`
  bodies run LIFO at every scope exit; multi-return destinations written in declaration
  order.
- A method call passes its receiver as the value the call site wrote; a reference `self`
  parameter makes the implicit borrow: the emitter spells `&x` (`emit_call_arg`), the
  evaluator passes a pointer to the operand's place, or to a new cell for a temporary
  (`autoref_args`), so `x.get()` on a builtin runs at compile time as it runs in C.
- A body that reaches a construct the lowering cannot handle fails with a reason string.
- **One lowering per body:** `irl::Keep` caches `KeptBody` records (body plus closures) keyed by body; borrowck
  fills it, emission's InstGraph walks it. Bodies with `has_reflect` / `has_zst_cond`
  re-lower per instance.
- Deterministic: two serial runs produce identical vectors; borrowck facts are integers
  in Core IR order.

## Consumers

| Consumer | What it reads |
|----------|---------------|
| Borrow checker | The tape (replay) + the lowered bodies (loan analysis via `borrowck/facts.spc`) |
| Drop elaboration | Storage markers + move/init dataflow → `TM_DROP` rewrite |
| CTFE (`ir/interp.spc`) | Executes bodies directly (the only evaluator) |
| Instance graph | Walks bodies from concrete roots to discover instantiations |
| C emitter | Renders bodies to readable C |
| Verifier (`ir/verify.spc`) | Structural rules (sealed blocks, type agreement, intrinsic tags) |
| Fact service (`ir/facts.spc`) and BCE (`ir/bce.spc`) | Effects, versions, integer facts; check proofs |
| Printer (`ir/print.spc`) | The IR expected-output tests |

The checked inventory (every consumer, the fields it reads, what it still reads outside the
record and under which condition that read could go), the measured decision that keeps
lowering at the start of borrow checking instead of publishing inside the typecheck frontier,
and the tape categories with their counts are in
[core-ir-publication.md](core-ir-publication.md).
