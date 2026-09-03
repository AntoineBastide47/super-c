# Core IR Reference

Source of truth: `src/ir/core.spc`. The Core IR is the typed, control-flow, **non-SSA**
executable form every body lowers to — one `CoreBody` per function, method, closure, or
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
    pub entry: BlockId,
}
```

`CoreBody::clear` re-seeds for a fresh body keeping every pool's capacity — one Lowerer
is reused across bodies.

## Locals

`LocalDecl { ty, storage, is_mutable, span, decl, item }` with storage classes:

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
| `PJ_FIELD` | `data` = stable field index, `sub` = field decl NodeId (`data == PJ_UNION_FIELD` marks a union member — fields alias) |
| `PJ_INDEX_CONST` | `data` = constant index |
| `PJ_INDEX_OP` | `data` = OperandId of the dynamic index |
| `PJ_DOWNCAST` | `data` = variant index, `sub` = variant decl NodeId |

Each `Projection` carries the type **after** it applies.

## Operands and Constants

`Operand { kind, data, ty }`:

| Kind | Meaning |
|------|---------|
| `OP_COPY` | Read a place (`data` = PlaceId) |
| `OP_MOVE` | Read and consume (`user_moves` marks user-visible consumptions) |
| `OP_CONST` | `data` = ConstId |
| `OP_ITEM` | A function/constant item value (ConstId carrying the DefId) |

`Constant` kinds: `CK_INT`, `CK_FLOAT` (raw span keeps the literal spelling), `CK_BOOL`,
`CK_STR`, `CK_UNIT`, `CK_ITEM` (resolved DefId + bound generic args in `targ_pool`),
`CK_WIDE` (wide-literal record index), `CK_ERROR` (error recovery).

## Rvalues

`Rvalue { a, b, target, item, kind, c }` — packed to 24 bytes; one record per expression:

| Kind | Meaning |
|------|---------|
| `RV_USE` | `a` = OperandId |
| `RV_REF` | `&place`; `b` = 1 when mutable |
| `RV_ADDR` | Raw address of place; `b` = 1 when `*mut` |
| `RV_UNARY` / `RV_BINARY` | Operand(s) + token op |
| `RV_CAST` | `b` = CastKind: `CAST_NUMERIC`, `CAST_POINTER`, `CAST_COERCE_FROM` (library `from`; `item` = selected method), `CAST_NEVER`, `CAST_ARRAY_SLICE` |
| `RV_AGGREGATE` | Operand range; `c` = `AGG_STRUCT`/`AGG_TUPLE`/`AGG_ARRAY`/`AGG_VARIANT` |
| `RV_REPEAT` | `[elem; count]` |
| `RV_LEN` / `RV_DISCRIMINANT` | Of a place |
| `RV_DYN` | Dynamic-interface construction |
| `RV_CLOSURE` | Capture operand range; `item` = closure body owner |
| `RV_INTRINSIC` | `c` = IntrinsicKind: `IN_SIZEOF`, `IN_ALIGNOF`, `IN_VA_START/ARG/END`, `IN_TYPE_INFO`, `IN_ZEROED`, `IN_REFLECT`, `IN_ASM`, `IN_SAFEPOINT` (loop preemption tick), `IN_DANGLING`, `IN_DYN_TID`/`IN_DYN_DATA` (dyn_cast), `IN_NEW` (heap alloc) |
| `RV_SLICE` | Structural `base[lo..hi]` view — kept structural so end-openness survives |

## Statements

`Statement { kind, place, rvalue, a, b, span }`:

| Kind | Meaning |
|------|---------|
| `ST_ASSIGN` | place = rvalue |
| `ST_STORAGE_LIVE` / `ST_STORAGE_DEAD` | `a` = LocalId; the DEAD markers at scope exits are the lexical drop points drop elaboration classifies |
| `ST_SET_DISCR` | Set enum discriminant (`a` = variant index) |
| `ST_DEINIT` | Deinitialize a place |
| `ST_ASM` | Inline assembly |
| `ST_NOP` | Placeholder |

## Terminators and Blocks

`BasicBlock { stmt_start, stmt_len, term, sealed }` — a statement range plus exactly one
terminator; the verifier rejects unsealed blocks. `Terminator` packs to 64 bytes (one
per cache line):

| Kind | Meaning |
|------|---------|
| `TM_GOTO` | `t0` = successor |
| `TM_SWITCH` | `a` = discriminant OperandId; (value, target) pairs in `switch_pool`; `t0` = otherwise |
| `TM_CALL` | `callee` DefId (node `NODE_NONE` for fn-value calls); args in `oper_pool`, destinations in `dest_pool` (multi-return), bound generic args in `targ_pool`; `t0` = normal continuation |
| `TM_RETURN` | Return |
| `TM_DROP` | Drop a place; `t0` = successor (inserted by drop elaboration) |
| `TM_ASSERT` | `a` = condition OperandId; `t0` = success |
| `TM_UNREACHABLE` | Unreachable |

## The Borrowck Replay Tape (`TP_*`)

Recorded by the Lowerer at the walk's AST sites (synthetic/desugared lowering never
records); consumed by `bc_replay`. Entry encoding: `kind << 56 | aux << 32 | node`.

Events: `TP_SCOPE_PUSH/POP`, `TP_NLL` (non-lexical borrow end point), `TP_MARK_PUSH/POP`,
`TP_LET`, `TP_LET_TUPLE`, `TP_ASSIGN_PRE/POST`, `TP_RET_VAL`, `TP_RET_POST`,
`TP_CALL_MARK`, `TP_CALL`, `TP_REF`, `TP_CAST_ERASE`, `TP_SLICE`, `TP_CLOSURE`,
`TP_FLOW_SAVE/ELSE/JOIN`, `TP_LOOP_PUSH/POP`, `TP_BODY_START/END`, `TP_MATCH_PRE`,
`TP_ARM`, `TP_ARM_END`, `TP_MATCH_POST`, and `TP_CONST_MOVE` (an argument a **folded**
call consumed — no IR op survives, so the replay marks the move directly).

There are no `TP_BORROW`/`TP_MOVE`/`TP_DROP` events: borrows and moves are ordinary IR
operands (`RV_REF`, `OP_MOVE`); the tape carries the *walk structure* the flow helpers
need.

## Lowering Contract (`src/ir/lower.spc`)

- Consumes ONLY the typed-facts boundary (`ast::facts`) plus syntax and spans — every
  semantic decision is read from recorded facts, never re-derived.
- Documented evaluation order: receiver before arguments, arguments left to right;
  short-circuit `&&`/`||` evaluate the right operand only on the deciding path;
  assignment evaluates the target place FIRST, then the value; aggregate fields in
  source order; match scrutinee once, arm tests in order, guard after bindings; `defer`
  bodies run LIFO at every scope exit; multi-return destinations written in declaration
  order.
- A body that reaches a construct the lowering cannot handle fails with a reason string.
- **One lowering per body:** `irl::Keep` caches spent Lowerers keyed by body; borrowck
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
| Verifier (`ir/verify.spc`) | Structural rules (sealed blocks, type agreement) |
| Printer (`ir/print.spc`) | The IR expected-output tests |
