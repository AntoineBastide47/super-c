---
name: super-c-targets
description: "Covers adding or changing a Super-C compilation target: a target table row, an operating system, an instruction set (code generator, encoder, instruction table, assembler, calling convention, intrinsics), an object format, a linker, and the std platform layer under them. Use when porting Super-C to a new platform, architecture, object format or linker, or when changing one of those layers."
allowed-tools: Bash Read
---

# Super-C targets

## Agent checklist

- Name the layers the change touches (Layers below) and read only their references.
- Read a target as one row of `TARGETS` in `src/target/table.spc`: shared code reads a row or a part,
  never a target name or index.
- Give each new layer its unit test before the first end-to-end build on the target.
- Make the backend refuse a body it cannot compile (`refuse`, an error naming the function) instead of
  emitting wrong code.
- Keep every output a function of its inputs: no time, host path or worker count in an object or image.
- Keep the two-generation fixpoint (`super-c-self-hosting`); it covers a backend only on its host.

## Layers

A build runs: the front end, the LIR optimizer (`src/lir/`), then per object the native backend of the
target (`src/target/native.spc`), then the link (`src/link/link.spc`). A target needs every layer:

| Layer | Holds | Files | Reference |
|---|---|---|---|
| Target table | the facts of each target: instruction set, calling convention, object format, OS, debug format, C data model, CPU features | `src/target/table.spc`, `src/ir/cpu_features.spc`, `src/bindgen/ctarget_data.spc` | [target-row.md](references/target-row.md) |
| Platform layer | std's OS calls, the runtime, the SIMD backend | `std/platform/`, `std/rt/`, `ffi/sc_runtime.spc`, `std/simd/backend/` | [platform-layer.md](references/platform-layer.md) |
| Code generator | LIR bodies to machine code, one pass per body | `src/codegen/live.spc`, `src/codegen/abi.spc`, `src/target/a64gen.spc`, `src/target/x64gen.spc`, `src/target/wasmgen.spc` | [code-generator.md](references/code-generator.md) |
| Instruction set | encoder, instruction table, assembler and disassembler, intrinsics, context switch | `src/target/a64.spc`, `src/target/a64tab.spc`, `src/target/a64asm.spc`, `src/target/assembler.spc`, `src/target/intrin.spc`, `src/target/ctxswitch.spc` | [code-generator.md](references/code-generator.md) |
| Object format | sections, symbols, relocations, unwind and debug data | `src/codegen/obj.spc`, `src/target/macho.spc`, `src/target/elf.spc`, `src/target/coff.spc`, `src/target/wasmobj.spc`, `src/codegen/dwarf.spc` | [object-and-linker.md](references/object-and-linker.md) |
| Linker | objects and system libraries into an executable or a shared library; archives | `src/link/` | [object-and-linker.md](references/object-and-linker.md) |
| Dispatch | which backend, object writer and linker serve `(os, isa)` | `src/target/native.spc` (`supported`, `own_linker`, `obj_kind`, `object`), `src/link/link.spc` (`link_args`) | below |

## A new target, in order

1. The table: a row of each new part (`Os`, `Isa`, `CallConv`, `ObjFormat`), then the `Target` row and
   its C environment row ([target-row.md](references/target-row.md)). `--target=` and `--arch=` take the
   new names; `@platform` and `@arch` gate on them.
2. The platform layer: every `std/platform/` module compiles for the new `@platform`, or says
   Unsupported ([platform-layer.md](references/platform-layer.md)).
3. The backend: a new instruction set needs its calling convention module, encoder, instruction table,
   assembler and code generator; a known one needs its calling convention and its object format's
   relocation kinds ([code-generator.md](references/code-generator.md)).
4. The object writer and the linker ([object-and-linker.md](references/object-and-linker.md)).
5. Dispatch: `supported`, `own_linker`, `obj_kind`, `asm_native` and `object` in `src/target/native.spc`
   name the new pair by its parts (`tgt::callconv_of(os, isa).name`, `tgt::obj_of(os).name`), as the
   existing predicates do.
6. The tests (Validation), then a CI lane that builds and runs on the target.

A target that differs only in its OS (a new ELF system on a known instruction set) reuses steps 3 and 4
and changes the OS row, the platform layer, the dynamic loader and C library names the linker writes,
and the dispatch.

## Hard constraints

- The compiler depends on libc only: no third-party assembler, object library or linker code. A
  system library is linked, never parsed by a dependency.
- Determinism: an object or image is byte-identical for one input under any `--jobs` value (the gate
  checks native objects) and carries no timestamp.
- A host-specific output difference is a defect where the bytes are produced; tests never normalize it.
- Do not add a target-name branch in shared code: add a field to the part's row and read it.
- Run heavy verification (`sh ci/gate.sh`, the full suite) once, at the end.

## Validation

- `tests/codegen/target_table_test.spc`: the rows against the C environments and std's axis enums.
- `tests/codegen/native_test.spc`: LIR text compiled for the host (`run_native`) and for wasm32
  (`run_wasm`, with `WASI_SDK_PATH`), linked with a C driver and run. Add a runner for a new pair.
- `tests/codegen/asm_test.spc`: every instruction-table row encodes, decodes and disassembles back.
- `tests/codegen/link_test.spc`, `tests/codegen/debug_info_test.spc`: the linker, line tables and unwind.
- `tests/codegen/cross_target_helpers_test.spc`: SDK flags and artifact names per target.
- The end-to-end suites (`tests/codegen/codegen_run_test.spc` and the corpus) on the target's CI lane.
