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
   between them, so a shrink-wrapped body is laid out once). It gives the block layout (reverse postorder, each loop contiguous, rare blocks last:
   `Live::rare`, a block the entry reaches only through a `BLOCK_RARE` one; none under `Live::in_place`,
   which wasm sets because its structured code emits each block where reverse postorder puts it), the loop nesting, each
   value's last live position, use count and next-use chain. `end_inst` calls `Live::advance`
   after emission, so unread current operands remain near uses during allocation. Eviction
   prefers no store, then the farthest next use. A folded instruction emits no code; its user reads its
   operands (`Live::uses_of`, the folded use lists `Live::ranges` records once). The warm code's values
   take the registers first; a call in a rare block
   saves around it the scratch registers whose values live past it (`save_scratch`), so it is no call
   for the homes.
2. Frame: the outgoing argument area (the largest call's stack arguments, from the calling convention),
   the LIR slots, then the spills; the callee-saved registers and the frame pointer last.
3. Homes: `Live::plan` gives each value a home class per register file (none, callee-saved for a value
   a loop keeps, caller-saved); constants and symbol and slot addresses rematerialize at each use.
   A displaced interval can keep its register prefix up to a block boundary no backward edge
   crosses. `cut` and sorted `splits` describe these prefixes; `home_at` selects the class at
   the current layout position. Shared homes, aggregate entry pointers and shrink-wrapped
   functions do not split. Reserve the suffix stack slots before emission. Every edge that
   leaves a prefix for a block that reads the value, including one that skips the cut block, writes
   the suffix slot (`save_splits`).
4. Blocks in layout order, each instruction emitted by its op. A value live past its block is in its
   home before the branch; an edge moves the block arguments (`edge_homes`).
5. `finish`: branch fixups, relocations into the object, call frame rows, line rows. arm64 retries a
   body whose conditional branch is out of range with every one of them over an unconditional branch.
   A retry (`again`: that one, or a shrink-wrap attempt that failed) keeps the relays, the canary, the
   operation flags and `Live`'s analysis, and redoes only the layout and the ranges (`Live::relayout`;
   arm64: after `shrinkable`).

A body the backend cannot compile fails with a reason (`refuse`): the build reports the function and
the reason. Never emit code for an unsupported case.

## Rare code

Shrink-wrapping (`shrinkable`): when every call is in a rare block (x86-64: or in a block outside loops
that no value lives across a call of, `Live::lives_across`, at most `lv::WARM_CALLS` such calls, with a
return in the warm code), the warm code keeps no frame and returns with `ret`; the blocks with a call,
the rare blocks joined by edges to one, and the blocks the entry reaches only through those set the
frame up (`Live::after`, laid out last), the prologue on each edge into them, the epilogue on each edge
out. Every call of a shrink-wrapped body saves the scratch homes live past it (`save_scratch`). x86-64:
the warm jumps into the first framed block take the prologue `relax` inserts before it (a jump table's
entry takes a stub); the other entries take stubs. arm64 keeps the frame in rare blocks alone: there a
warm return between the entry and the framed code writes x0, which would move the parameters off their
registers. On arm64 a call right before the return of its
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
  comparisons into one conditional-comparison chain (`lv::FOLD_CCMP`); each leaf's extension frees after
  its `ccmp`.
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
