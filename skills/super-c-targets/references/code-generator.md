# A code generator

A native backend turns the optimized, verified LIR of a package (`src/lir/ir.spc`, checked by
`src/lir/verify.spc`) into an object model (`src/codegen/obj.spc`): sections, symbols, relocations,
call frame rows and line rows. The register backends (`src/target/a64gen.spc`,
`src/target/x64gen.spc`) follow TPDE (Schwarz, Kamm and Engelke 2025): one analysis pass, then one code
pass per body. `src/target/wasmgen.spc` maps values to wasm locals and structures control flow
(`src/codegen/structure.spc`). Read the header comment of the backend nearest to the new instruction
set first: it states the value, register and frame model.

## Per body

1. Analysis: set `Live.fold_ops` to the `FOLD_*` patterns the backend fuses into their users, then
   `Live::run` (`Live::analyze`, then `Live::relayout`; arm64 runs the two apart, with `shrinkable`
   between them, so a body shrink-wrapped for its rare blocks is laid out once; one with a call
   outside them is laid out with no block last first, for the ranges `Live::around_cost` reads). It gives the block layout (reverse postorder, each loop contiguous, rare blocks last:
   `Live::rare`, a block the entry reaches only through a `BLOCK_RARE` one; none under `Live::in_place`,
   which wasm sets because its structured code emits each block where reverse postorder puts it), the loop nesting, each
   value's last live position, use count and next-use chain. `end_inst` calls `Live::advance`
   after emission, so unread current operands remain near uses during allocation. Eviction
   prefers no store, then the farthest next use. A folded instruction emits no code; its user reads its
   operands (`Live::uses_of`, the folded use lists `Live::ranges` records once). The warm code's values
   take the registers first; a call in a rare block, and each call of a shrink-wrapped body,
   saves around it the scratch registers whose values live past it (`save_scratch`), so it is no call
   for the homes. A value's range runs through the rare blocks before its last read, so the save
   leaves out an instruction's value that no path from the call reads (`Live::dead_past`, a liveness
   over the laid-out blocks made on first use), and arm64 saves two registers per `stp`.
2. Frame: the outgoing argument area (the largest call's stack arguments, from the calling convention),
   the LIR slots, then the spills; the callee-saved registers and the frame pointer last.
3. Homes: `Live::assign` gives each value that asks for one (`want`: `WANT_CALLEE`, `WANT_SCRATCH`,
   `WANT_V`, `WANT_UPPER`, `WANT_WHOLE`) a specific register per block. It weighs each value by the
   frequencies of its definition's and uses' blocks (`Live::frequencies`: a static estimate after
   LLVM's, propagated in reverse postorder, a branch split evenly but a rare successor's share 1 in
   16, a loop header 8 times its entering edges, an edge out of a loop 8 times less per loop left; a
   block that runs passes each successor a share of at least 1, so no chain of branches leaves the
   blocks after it a frequency of 0) and places the heaviest first. Constants and symbol and slot
   addresses rematerialize at each use.
   - Liveness is exact per value: the blocks it is live in (a backward walk from its reads), and in
     each block the positions from its definition to its last read. Two values hold one register when
     they are live at no common position. A block parameter takes the register of the argument an
     edge passes it, and a result that of its first operand when that ends there (`Live::over_inst`: a
     `step_op`, a checked sum or difference, an integer conversion, a pointer plus a constant, a
     widening sum over its accumulator), so those moves are not made. Set `Live.three` to let the
     result of a `three_op` take the register of any operand that ends there (a select's side, a
     commutative operation's second operand, an index): arm64 sets it alone (its instructions name
     their result apart from their operands, and every emitter reads all of them before it writes);
     x86-64 sets `Live.two` with it, so only an operand the instruction may be written over gives its
     register (`Live::two_op`: either operand of an operation that commutes, the accumulator of a sum
     with a carry, a select's side, the base or index of a pointer sum, a load's address). Without
     these rules a loop's stepped pointer or accumulator has a register of its own, the back edge
     copies it, and no access steps the pointer (arm64's post-indexed loads and stores). The planner prefers such registers
     (`Live::hints`: placed partners weighed by edge frequency, the register a parameter arrives in,
     the return register `Live.rhint`).
   - The heaviest value is placed first, but a block parameter is placed no later than the step that
     replaces it (`Live.kw`: a value of a block whose edge passes it to the parameter of that block
     or of an earlier one, nothing in its block reading the parameter after it). The parameter takes
     a register it may hold over all of its range and the step, which lives to the edge alone,
     follows it there; a step placed first takes one that another value may hold in the parameter's
     blocks, and the back edge copies it. When a call runs between the parameter's block and the
     step, only a step that may write over the parameter where its range ends: the parameter takes a
     callee-saved register, and the step, which alone could take a caller-saved one, follows it.
   - A callee-saved register the body does not save yet costs the value that takes it `SAVE_COST`,
     two entries (`Live::pick`, `Live::spans`): its save and its restore. A lower cost makes a body
     save the register at every entry for a path it seldom runs. Give `Sets.pair` the lower register
     of each two callee-saved registers the prologue saves together (arm64: x19/x20 to x27/x28,
     d8/d9 to d14/d15; x86-64: none, each has a push or a store of its own): a body that holds a
     value in one saves both, so the other costs nothing (`Sets::saved`).
   - Fill `Live.part_in` (and `part_quiet`) before `assign` for the loads that take the part
     registers of an aggregate the body receives in registers (`place::parts_taken`, which the entry
     decides the same way): the plan then leaves each load in the register it arrives in, as it
     leaves a parameter of the signature (`arr`).
   - Pass the register sets (`Sets`: callee-saved, caller-saved, the caller-saved ones that pass
     arguments too, the arrival registers a quiet parameter may keep, x86-64's upper vector registers,
     the ones to give out first), the counts each block may hold (`Caps`, `Live.jcap`, `scap`), per
     signature parameter the registers it arrives in (`arr`), and the call tables: fill `Live.cfirst`
     and `clast` before `assign` (per block, the first and last call that writes the caller-saved
     registers; `wfirst` and `wlast` for the argument registers). A caller-saved register holds a
     value only in the blocks where no such call runs while it lives (`Live::calm`), so a value that
     lives across a call may ask for both classes.
   - A value no register holds in all of its blocks takes the one that gains most over a part of them
     (`Live::spans`): it keeps a stack home (`Live.seg_mem`), written once where it is defined, and
     an edge into such a block from one that does not hold it loads it. A span is kept when the loads
     it saves run more often than the edges that enter it; a load on one of a terminator's several
     edges weighs `EDGE_BLOCK` times (a block of its own that jumps on), and a late edge's stub loads
     nothing, so no span starts there. A value that finds no register over all of its blocks may take
     one from a holder that is idle in those blocks (`Live::evict`: the holder lives through them and
     reads nothing there); the holder then keeps a stack home and is loaded on the edges back into
     its other blocks.
   - The plan is the segments (`Live.seg_x`, `seg_a`, `seg_b`, `seg_r`, `sin`, `sin_at`, `segd`,
     `seg_mem`) and, per layout position, the registers of the plan in that block (`Live.bmask`) and
     those of them one value alone holds there and no edge out of the block writes (`Live.solo`).
   The generator's contract (`place::Core`'s hooks and its own):
   - `seg_reset` after `assign`. At a block's start set `fixed_busy` to the pinned registers and
     `bmask` of the block: no temporary takes a register of the plan in that block, but a `solo`
     one after its value ends (`Core::release` clears it from `fixed_busy`; a result that only
     renames an operand that ends there takes it: arm64 `takes`, x86-64 `def_over`). Then `seg_leave`,
     and bind each listed segment whose value an earlier block defines (`seg_bind`: a temporary in the
     register leaves it first, `vacate_temp`); store a parameter that keeps a stack home and load one
     that arrived in memory or in a slot.
   - A definition takes the plan's register (`seg_take`). When an operand the instruction still
     reads holds that register, only an emitter that reads its operands before it writes its result
     may write it (arm64: `def_step` sets `stepping`; x86-64: `def_over` and `def_pass` name the
     operand the result is computed over, `def_read` marks one instruction that reads them all, a
     `lea`); another result is made in a temporary and moves there after the instruction
     (`settle` in `end_inst`: an operand that ended at the instruction leaves the register without a
     store, and a value that arrived in its plan register stays). A value made before its own instruction (a pair's second access, a
     call result's part, a conversion's home its operand is made in) takes the register only when no
     value holds it, but one of the plan with no read left in the block (the plan gives the register
     to the later value there), and nothing takes it in between (`early`). A flag
     is bound by the instruction that sets it.
   - After an instruction that defines a value with a stack home, store it (`seg_store`). Before a
     terminator's branch, for each edge: a temporary that lives on leaves the registers the edge
     writes (`seg_edge`, `param_home`: `vacate_live`); in the edge's moves, `seg_moves`. Read a target
     parameter's home through `Core::pva` at every edge site. Make no early edge move (before the
     branch) that writes a register of the plan on an edge that enters a segment (`keeps_test`).
   - An x86-64 emitter that may compute its result over either of two operands takes the one that
     holds the plan's register (`planned`: `swaps` for a commutative operation, the select's side
     with the condition inverted, the vector emitters' second operand).
   - A value that takes a parameter's register at its definition without a register of the plan (a
     step the back edge passes) owns the register as a temporary (`set_owner`), so a value the plan
     puts there later evicts it.
   - A value's zero-extended state (`Va.clean`) holds wherever the plan moves it (`Core::seg_in` keeps
     it for a value made before): reload a narrow value zero-extended, and extend one in place only
     where every later reader comes through (its defining block, or the block where it ends).
   - A range runs to the last block in the layout that reads the value. A block the layout puts after
     a block it branches to runs inside the ranges of the values live at that target: `Live::
     rare_entries` extends and keeps them for every such edge.
4. Blocks in layout order, each instruction emitted by its op. A value live past its block is in its
   home before the branch; an edge moves the block arguments (`edge_homes`). A two-way branch whose
   taken edge enters the block that follows, its moves made before the branch, falls into that block:
   the other edge alone branches (`branch2`). A block whose only
   predecessor falls into it keeps the register state (`Live::continues`); another, whose predecessors
   the layout all puts before it, starts with the instruction values every branch into it left in one
   register (`place::Core::join_note` at each branch, `join_in` at the block; an edge's moves write only
   its parameters' homes). A late stub's branch or one from code outside the blocks gives its target no
   such state (`jbad`).
5. `finish`: branch fixups, relocations into the object, call frame rows, line rows. arm64 retries a
   body whose conditional branch is out of range with every one of them over an unconditional branch.
   A retry (`again`: that one, or a shrink-wrap attempt that failed) keeps the relays, the canary, the
   operation flags and `Live`'s analysis, and redoes only the layout and the ranges (`Live::relayout`;
   arm64: after `shrinkable`).

A body the backend cannot compile fails with a reason (`refuse`): the build reports the function and
the reason. Never emit code for an unsupported case.

## Rare code

Shrink-wrapping (`shrinkable`): when every call is in a rare block, or the frame on the edges into the
blocks with a call costs less than one at the entry (`Live::frame_pays`: the save, the restore and the
stub's jump as often as those edges run, `Live::after_into`, plus the homes saved around the calls
outside rare blocks, `Live::around_cost`, at most `lv::WARM_CALLS` such calls, against a frame per
entry and a callee-saved register when a home lives past such a call), the warm code keeps no frame
and returns with `ret`; the blocks with a call,
the rare blocks joined by edges to one, and the blocks the entry reaches only through those set the
frame up (`Live::after`, laid out last), the prologue on each edge into them, the epilogue on each edge
out. Every call of a shrink-wrapped body saves the scratch homes live past it (`save_scratch`). x86-64:
the warm jumps into the first framed block take the prologue `relax` inserts before it (a jump table's
entry takes a stub); the other entries take stubs. After the call, a saved register is loaded back only
when it still holds the saved value (`csown`): a value whose segment ended at the call left its register
to the result. On arm64 a call right before the return of its
result (a sibling call's shape under `Package.tail`, `place::call_tail_shape`) needs no frame either: it is
the warm code's `b`; one that stays a call makes the try fail. Not with a canary, a slot aligned past 16 bytes, inline assembly, a return address or
variadic access; nor when the entry's code uses the frame (a parameter's register parts stored into its
slot): it runs in the warm entry block (`frame_use` at the entry's layout position). Microsoft x64: no
edge may leave them for the warm code (its unwinder reads an epilogue only where it ends in `ret` or a
jump out); the warm code has no function table entry (a leaf's rule), the framed code one from the
prologue before it (else with a prologue of 0 bytes), each entry stub one with its prologue
(`OFrame.off`). A `@cold` function's code goes to its own section (`cold_text`).

x86-64 branches: `Code::relax` gives each jump its 2-byte form where it reaches, drops the jumps no code
runs (`Code::unreached`: a block of one jump every branch went past) and each jump to the next byte, and
inserts the shrink-wrapped prologue. A dense switch is a jump table: a read-only table of 32-bit offsets
from its start, `lea`, `movsxd`, `add`, `jmp` (clang's), each entry a relocation through the code's
section symbol (`ob::ORel.part`: no global symbol a shared object could interpose).

## Values and ops

- Integers up to 64 bits and pointers live in general registers, floats in vector registers; an i128
  splits into its two words before (`split_pairs`, `Isa.pairs`), and a vector lives in a stack slot
  (wasm: frame memory) unless a register form keeps it in a vector register (below). The bits above
  an i8, i16 or i32 value are undefined in its register: an operation that reads them extends first.
- Every `O_*` of `src/lir/ir.spc` is emitted or refused. Groups: constants and addresses; integer and
  float arithmetic with the overflow forms (two results: the value and a flag); comparisons and
  `select`; conversions; `ptradd`, loads, stores, `memcpy`, `memset`; atomics and fences; calls (direct,
  indirect, variadic); `O_VOP` (vector operations by `ir::core` SIMD code); `O_SYS` (system operations:
  barriers, cycle counter, floating-point control state, the context switch); `O_ASM`; terminators.
- Vectors of a register's size may live in vector registers (`vec_homes`: a vector some instruction
  reads or defines in memory stays there). Register forms: lane-wise arithmetic, comparisons, selects,
  splats, wide constants, `vunzip`, `vziplo`/`vziphi`, lane extracts and inserts (`vlane`), the `O_VOP`s
  with a form (`vop_reg`, arm64: NEON lane rules, masks, choices, bitcasts, shifts by a scalar,
  unchecked gathers, masked loads and stores, absolute differences), conversions (`conv_reg`: arm64
  each `Isa.vector_ops` allows; x86-64 SSE2 for integers to twice or half their width, i32 and f32, f32
  and f64, AVX2 for those of 32-byte vectors) and shifts by vector amounts (x86-64 with AVX2,
  `shift_reg`), and lane high products (`mulhs`, `mulhu`; arm64 `vec_mulh`: SMULL or UMULL of the low
  and high lanes and UZP2, SHRN for 8 bytes; x86-64 `pmulhw`/`pmulhuw` for 16-bit lanes, `mulh_lanes32`
  for 32-bit ones: the even and odd lanes' `pmuludq` (signed `pmuldq` with SSE4.1, else a correction)
  merged by a mask, `vpblendd` with AVX2, `vpandq`/`vporq` with AVX-512). Any other form computes lane by
  lane through memory.
- Vector constants: x86-64 loads one from the body's read-only constants (`const_sym`, aligned to its
  size); a 16-byte one that lane operations of its block alone read, each as its second operand, is their
  memory operand (`lv::FOLD_VCMEM`: `pxor x, [rip + k]`). arm64 builds one of a repeating byte or
  element (MOVI, DUP) and loads any other of 16 bytes (ADRP, LDR q of `const_sym`'s data). A comparison
  with 0 of the `or` of a vector's lanes tests the register (`lv::FOLD_ANY`: `pmovmskb` of a lane mask;
  with SSE4.1 `ptest` of any integer vector, `lv::FOLD_ANY_BITS`). With SSE4.1 a product of 32-bit lanes
  reads such a constant or a folded load as its memory operand (`lv::FOLD_VMUL`, `pmulld x, [m]`).
- Further vector register forms: slides of two vectors' lanes in a row (`lv::lane_slide`: arm64 EXT;
  x86-64 PALIGNR with SSSE3, else PSLLDQ, PSRLDQ and POR, 32 bytes VPERM2I128 and VPALIGNR); widening
  products (`O_VMULW`: arm64 SMULL, UMULL and their `2` forms; x86-64 PMULUDQ, PMULDQ with SSE4.1, of
  4-byte lanes); byte lookups and shuffles of up to three vectors (arm64 TBL and TBX; x86-64 PSHUFB with
  SSSE3, `pshufb_shuffle`, each 16 bytes looked up in their own on 32 and 64 bytes); bit operations per
  `Isa.vector_bits` (arm64 CNT and UADDLP, CLZ, REV16, REV32, REV64; x86-64 a parallel bit count,
  PSHUFLW, PSHUFHW and word shifts for byte swaps, VPLZCNTD and VPLZCNTQ with AVX-512 CD and VL); the bits
  of a byte lane mask (x86-64 PMOVMSKB, `Isa.mask_bits`). Folds: `lv::FOLD_VMLA`, a product or widening
  product with one use that a sum or difference reads accumulates into it (arm64 MLA, MLS, SMLAL, UMLAL,
  SMLSL, UMLSL), and a right shift by an immediate into a sum (USRA, SSRA); `lv::FOLD_ADDSUB`, a lane
  select by an even-lanes mask of a float difference and sum is x86-64's `addsubps` or `addsubpd` (SSE3;
  `FOLD_ADDSUB_WIDE` of 32 bytes with AVX). An 8-byte vector moves to an integer register by FMOV (arm64)
  or MOVQ (x86-64).
- Extension folds (arm64, `lv::FOLD_XUSE`): a 64-bit zero or sign extension of a 32-bit value that only
  comparisons with a register and the indices of address sums read takes no register: each use extends
  the narrow register (`cmp x, w, uxtw`, `add x, x, w, uxtw #2`, and a load or store that takes the sum
  extends its index as under `lv::FOLD_XIDX`; an address sum of a scale that is no power of two up to
  16 multiplies the narrow register by the scale and adds the base in one `umaddl` or `smaddl`).
  x86-64 has no such operand form and keeps its copy.
- Load folds (`lv::FOLD_LDOP`): a load of a call's aggregate result right after the call stays a load
  only when registers may return that result (`Live::ret_regs`, the largest such result: 16 bytes on
  x86-64), whose registers the generator then takes; a slot copied to the stack as a by-value argument is
  read at its offset from the stack pointer.
- Inline copies: arm64 moves 32 bytes at a time by LDP and STP of two q registers where the pair forms
  reach both offsets (`qpair_fits`; an overlapping copy loads every chunk first). Load folds of an
  aggregate parameter (`lv::FOLD_LDOP`) read only one the body's own convention passes in memory
  (`Live::mem_params`): Super-C's convention on Windows passes 16 bytes in two registers.
- Sibling calls: a call right before the return whose result is the body's (or nothing), with every
  argument in registers; also a call that writes the body's own aggregate result (its result pointer
  passed on, both results in memory), which returns as the body would. Before a sibling call only the
  values the call reads go to their homes (`spill_around_call`, `back`): no code of the body runs after
  it. arm64: a parameter a call of the entry block takes before any instruction ran is read in the
  register it arrived in (`arrived_in`), not in its home; not where a branch enters the entry block. arm64 joins up to 8 integer
  comparisons into one conditional-comparison chain (`lv::FOLD_CCMP`); each comparison's extensions and
  operand locks end after its `ccmp` (`conj_flags`), so a chain of spilled values needs no more than the
  16 registers `alloc` has.
- A saturating float-to-integer conversion reads the float's sign with `movq`/`movd`, which EVEX
  encodes on xmm16..xmm31 (`movmskpd` has no EVEX form).
- arm64 pairs loads or stores at adjacent offsets in either order across up to seven pure
  scalar instructions (`pair_next`). It never crosses another memory operation or control
  flow. A store source must already exist; a second load can take its planned register home,
  but cannot already have an assigned fixed home.
- x86-64 folds single-use f32/f64 loads into the right memory operand of scalar arithmetic
  (`FOLD_LDOP`). Preserve operand order and reject intervening memory writes.
- `O_ASM` and module-level assembly assemble through the instruction table (`src/target/assembler.spc`
  for directives, labels and sections; the instruction set's assembler for instructions).

## Calling convention

A module per convention fills the layout of `src/codegen/abi.spc` for a signature: the location of each
parameter part and of the result (a register of a file, the stack, or memory the caller provides).
`src/target/sysv.spc`, `src/target/win64.spc`, `src/target/aapcs64.spc` (with Apple's variant) and
`src/target/wasmabi.spc` are the models. The code generator only moves the bytes each location names.
Under Microsoft x64, a call of a function no C code reaches by name takes Super-C's own convention
(`w64::classify`'s `sc`): an aggregate of 9 to 16 bytes whose last 8 or fewer bytes pass as an integer
(a slice, a `str`) passes in two integer registers and returns in rax and rdx, as System V passes it.
Where the program takes such a function's address, the address names a local thunk with C's convention
(`w64::thunks`, from `native::prepare`), in the object of the code that takes it.
Check every rule against the C compiler with a C driver (`tests/codegen/native_test.spc`): aggregates
of each size class, floats in aggregates, i128, vectors, variadic calls, results in memory.

## Instruction set parts

| Part | Models | Role |
|---|---|---|
| Encoder | `src/target/a64.spc`, `src/target/x64.spc`, `src/target/wasm.spc` | one function per instruction form; the relocation kinds `R_*` |
| Instruction table | `src/target/a64tab.spc`, `src/target/x64tab.spc`, `src/target/wasmtab.spc` | one row per form, read by the assembler and the disassembler |
| Assembler, disassembler | `src/target/a64asm.spc`, `src/target/x64asm.spc`, `src/target/wasmasm.spc` | one instruction in the platform's syntax, from the table |
| Intrinsics | `src/target/intrin.spc`, `src/target/a64intrin.spc`, `src/target/x64intrin.spc`, `src/target/wasmintrin.spc` | C intrinsic calls expanded in place; the templates come from `scripts/intrin/gen.py` |
| Context switch | `src/target/ctxswitch.spc` | the coroutine switch and its entry trampoline, as assembly per target |
| Runtime routines | `std/rt/builtins.spc` | compiler-rt's 128-bit routines where the C library lacks them |

`tests/codegen/asm_test.spc` encodes, decodes and disassembles every table row; add the new table to it.

## Order of work for a new instruction set

1. Encoder and table, with the asm test.
2. The calling convention module.
3. The code generator: integer arithmetic, branches and a loop; then calls across the C ABI; loads,
   stores and slots; floats; i128; the overflow forms; atomics; vectors; system operations; inline
   assembly. One `native_test` case per group, each linked with a C driver that checks edge values.
4. The object format's relocation kinds for the new encoder (`object-and-linker.md`).
5. The end-to-end corpus on the target, then the target's CI lane.
