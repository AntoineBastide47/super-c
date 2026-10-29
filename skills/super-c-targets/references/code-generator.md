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
   `Live::run`. It gives the block layout (reverse postorder, each loop contiguous, rare blocks last:
   `Live::rare`, a block the entry reaches only through a `BLOCK_RARE` one), the loop nesting, each
   value's last live position and use count. A folded instruction emits no code; its user reads its
   operands (`Live::uses_at`). The warm code's values take the registers first; a call in a rare block
   saves around it the scratch registers whose values live past it (`save_scratch`), so it is no call
   for the homes.
2. Frame: the outgoing argument area (the largest call's stack arguments, from the calling convention),
   the LIR slots, then the spills; the callee-saved registers and the frame pointer last.
3. Homes: `Live::plan` gives each value a home class per register file (none, callee-saved for a value
   a loop keeps, caller-saved); constants and symbol and slot addresses rematerialize at each use.
4. Blocks in layout order, each instruction emitted by its op. A value live past its block is in its
   home before the branch; an edge moves the block arguments (`edge_homes`).
5. `finish`: branch fixups, relocations into the object, call frame rows, line rows. arm64 retries a
   body whose conditional branch is out of range with every one of them over an unconditional branch.

A body the backend cannot compile fails with a reason (`refuse`): the build reports the function and
the reason. Never emit code for an unsupported case.

## Rare code

Shrink-wrapping (`shrinkable`): when every call is in a rare block, the warm code keeps no frame and
returns with `ret`; the rare blocks joined by edges to one with a call set the frame up
(`Live::after`, laid out last), the prologue on each edge into them, the epilogue on each edge out.
Not with a canary, a slot aligned past 16 bytes, inline assembly, a return address or variadic
access. Microsoft x64: no edge may leave them for the warm code (its unwinder reads an epilogue only
where it ends in `ret` or a jump out); the warm code has no function table entry (a leaf's rule), the
framed code one with a prologue of 0 bytes, each entry stub one with its prologue (`OFrame.off`). A
`@cold` function's code goes to its own section (`cold_text`).

## Values and ops

- Integers up to 64 bits and pointers live in general registers, floats in vector registers; an i128
  splits into its two words before (`split_pairs`, `Isa.pairs`), and a vector lives in a stack slot
  (wasm: frame memory) unless it lives in a vector register (`vec_homes`). The bits above
  an i8, i16 or i32 value are undefined in its register: an operation that reads them extends first.
- Every `O_*` of `src/lir/ir.spc` is emitted or refused. Groups: constants and addresses; integer and
  float arithmetic with the overflow forms (two results: the value and a flag); comparisons and
  `select`; conversions; `ptradd`, loads, stores, `memcpy`, `memset`; atomics and fences; calls (direct,
  indirect, variadic); `O_VOP` (vector operations by `ir::core` SIMD code); `O_SYS` (system operations:
  barriers, cycle counter, floating-point control state, the context switch); `O_ASM`; terminators.
- `O_ASM` and module-level assembly assemble through the instruction table (`src/target/assembler.spc`
  for directives, labels and sections; the instruction set's assembler for instructions).

## Calling convention

A module per convention fills the layout of `src/codegen/abi.spc` for a signature: the location of each
parameter part and of the result (a register of a file, the stack, or memory the caller provides).
`src/target/sysv.spc`, `src/target/win64.spc`, `src/target/aapcs64.spc` (with Apple's variant) and
`src/target/wasmabi.spc` are the models. The code generator only moves the bytes each location names.
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
