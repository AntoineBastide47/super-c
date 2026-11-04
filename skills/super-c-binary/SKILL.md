---
name: super-c-binary
description: "Documents the super-c compiler binary: subcommands, flags, build.toml manifest, environment variables, and the two-stage bootstrap. Use when invoking the compiler, configuring a build, running tests or benchmarks, or setting up a project."
allowed-tools: Bash Read
---

# Super-C Binary

## Agent checklist

- Read `skills/README.md` for precedence and the verification tag.
- Check `src/main.spc` before trusting a CLI flag claim.
- Check `src/build_system/` before trusting manifest or profile behavior.
- Report undocumented flags or environment variables as stale documentation.

## Run an Old or Copied Compiler

A compiler copied out of its tree (a saved generation, a release binary, a private build) and a
compiler older than the sources it builds need two settings:

```sh
cd <tree> && SC_STD_DIR=$PWD/std <compiler> build --bootstrap-tags -o <out>
```

- `SC_STD_DIR`: the binary looks for `std/` only beside itself and in its two parent directories.
  A copy elsewhere fails with "cannot find the standard library: '...' is not a directory", or loses
  the prelude ("cannot find type 'Vector'"). Name the `std/` of the tree it builds.
- `--bootstrap-tags`: a compiler older than the tree rejects attributes, intrinsics and build.toml keys
  the tree added ("unknown attribute '@x'; pass --bootstrap-tags to accept unknown attributes").
- Run the copy by its own path, not as `./super-c`: another session can replace `./super-c`. Before
  any test, fixpoint or commit claim, `cmp` the binary you ran with the one you name.

Super-C is a self-hosting compiler for macOS arm64, Linux x86-64, Linux arm64, Windows x86-64 and
wasm32. A build compiles each module to a Mach-O, ELF, COFF or wasm object itself and links the objects
with its own linker (`src/link/`): Mach-O executables and dylibs on arm64 (chained fixups, ad-hoc
signature), ELF executables and shared libraries on x86-64 and arm64 (glibc 2.34 or later), PE
executables and DLLs on x86-64 (the UCRT), and wasm32 modules; the own archiver writes every static
library. Each own linker also links static libraries (`.a`, `.lib`, positional or `-l<name>` from a `-L`
directory) a C compiler built: it takes a member for each symbol still undefined, as LLD does. No C
compiler takes part. A module the native backend refuses (a header's `static` function, an intrinsic it
has no template for) and a target without a native backend are build errors; `--emit-c` writes the
program's readable C11 instead (Generated Output in [generated-output.md](references/generated-output.md)). A build at an `opt-level` above 0 (the
`release`, `bench` and `test` profiles) runs the LIR optimizer first: inlining, value numbering, load and
store forwarding, loop transforms, constant and branch folding (`SC_LIR_OPT` overrides the
choice; Optimization levels and code-generation flags in [build-toml.md](references/build-toml.md)). The objects carry DWARF line tables when the profile's `debug` key is set (`debug`, `bench`),
and unwind data always. The extern blocks read the target's C headers (`native_header_facts`): the C
library's development package on Linux, the macOS SDK, mingw-w64's tree on Windows (found beside a
mingw `gcc` or `clang` in PATH), a WASI sysroot (`WASI_SDK_PATH`, else `WASI_SYSROOT`) for wasm, or the
tree `--sysroot=DIR` names. The single binary `super-c` drives every stage of the workflow.

## Two-Stage Bootstrap

The self-hosting contract requires a byte-identical two-generation fixpoint:

```sh
super-c command bootstrap
# 1. Current compiler builds stage1 (with bootstrap tags)
# 2. Stage1 builds stage2 (the new compiler)
# 3. Stage1 is removed
# Any diff between stage1's output and stage2's output is a semantic regression.
```

## Reference files

Read only the file the task needs. Section names are kept, so a pointer such as
"see Header Types" names a heading in one of these files.

- [commands.md](references/commands.md): compile, build system, external transpiler, test, bench, gates, fmt, lint, scaffolding, custom commands, bindgen and vendor.
- [build-toml.md](references/build-toml.md): manifest keys, built-in profiles, optimization levels, build cache, wasm C library, CPU features, common flags.
- [environment.md](references/environment.md): build and cache variables, validation switches, LSP and runtime variables.
- [generated-output.md](references/generated-output.md): what a build writes and where.
