# Leak Detection

## Leak Detection

Every compiled binary carries a built-in leak tracker, controlled by environment
variables:

```sh
SC_LEAK_CHECK=1 ./app           # report leaks at exit with their allocation site
SC_LEAK_CHECK=fatal ./app       # report + exit 23 on leaks (CI gate)
```

The tracker is part of the runtime every program links (`std/rt/base.spc`). The emitter spells
every extern C `malloc`/`calloc`/`realloc`/`free` call (std's, ffi's or the program's own binding) as
the tracker's `sc_lk_*` entry (`Mangler::tracked_alloc`), and std's `Global` allocator calls
`sc_lk_aligned_alloc` / `sc_lk_aligned_free` for over-aligned blocks. It:
- Reports every allocation that survives to exit
- Detects **double frees** with both allocation and free stacks (freed blocks stay allocated
  in a bounded history, so an address in it is always a real double free, never a reused block)
- Detects **use-after-free** on `realloc` of a freed pointer
- Works everywhere, including Apple Silicon (where LeakSanitizer does not exist)

### CI integration

The CI suite runs all tests under `SC_LEAK_CHECK=fatal`. Leak-freedom is enforced by
construction, not by audit.

```sh
SC_LEAK_CHECK=fatal super-c test --quiet
```

Every process a harness helper starts (`cli::run_with`, under each run, build and compile helper)
gets `SC_LEAK_CHECK=fatal` unless the test sets `SC_LEAK_CHECK` on it itself (`run_bin_env`,
`compile_flags_env`, `compile_and_run_env`), so a leak in a program or compiler a test runs fails
the test with or without the gate. Only a leak in the test process itself needs the gate.

The platform layer's tests (`tests/platform/platform_*_test.spc`, helper `tests/platform/platform_harness.spc`) run each
`std::platform` module on the host; `platform_wasi_test` builds one program with `--target=wasm`, runs it under
wasmtime and checks every WASI `Unsupported` path, and returns early without `WASI_SDK_PATH`. Windows-only paths
compile there and run on the Windows runner. `tests/cli/std_packages_test.spc` builds `tools/std_packages` and runs
it on fixture trees (an upward import, a forbidden `extern "C"` function, a cross-package cycle, the text of a
matchertext literal). `tests/codegen/wasm_libc_test.spc` checks wasm's C library against the one it replaces: a program
on `std::rt::libc` and `std::rt::libm` and the same program in C on wasi-libc (the wasi-sdk's clang) print the
same 27,100 lines under wasmtime (the bits of every math function at 300 arguments, printf, strtod, strtol,
qsort), and the program's name section holds no wasi-libc function; a second pair prints the same 873 lines
(the scanf family over strings, files and stdin, setlocale with UTF-8, the time functions, signals, `sbrk`
beside malloc, creat, setvbuf, environ, pthread_self and pthread_exit). Both return early without
`WASI_SDK_PATH`. `every_c_symbol_a_wasm_build_binds_is_defined` needs no SDK: every C function and static
that ffi, std and src bind for wasm (`tools/std_packages/scan.spc` reads the gates) is defined by the C
library, the runtime or the intrinsics header, or is on its list of functions WASI has no call for. The
local `check.sh` does not run the `SC_SIMD_LANE=wasm` lane; a change to wasm linking needs it run
(the `wasm checks` job's commands).

The wasm lane runs the same suite with `SC_TEST_SUPERC=ci/wasm-superc.sh`: the wrapper runs
every transpile-class command (a script, `fmt`, `lint`, the transpile form an engine's
`--transpiler` runs) inside wasmtime and sends the commands that spawn processes (`build`,
`test`, `bindgen` and the rest) to the native binary. A CLI test that needs the working
directory of a guest command or runs a shell line returns early under `cli::on_wasm()`.

The guest has no stable working directory (wasmtime ignores the test's `chdir`) and no
subprocesses, so guest command lines use absolute paths. The wrapper passes
`--argv0` with the module's absolute path, and the compiler finds `std/` and `ffi/` beside
argv0, or where the forwarded `SC_STD_DIR` names `std/`: the module must sit beside them (the
repo root by default, else `SC_WASM_MODULE`) when that variable is unset, or every compile fails
with "cannot find type 'str'". The wrapper forwards every `SC_*`
variable into the guest except its own plumbing (`SC_WASM_MODULE`, `SC_WASM_NATIVE`,
`SC_TEST_SUPERC`); a new plumbing variable for the wrapper must join that exclusion. Run
one test locally with `SC_TEST_SUPERC=$PWD/ci/wasm-superc.sh ./super-c test --quiet
--filter=NAME`. To find a wasm-only miscompile, bisect at object level: compile every
TU with both toolchains, link mixed sets, and binary-search the TU set.
`WASMTIME_BACKTRACE_DETAILS=1` gives file and line in traps. A single-flag fix
(`-fno-strict-aliasing`, `-fno-vectorize`) that makes a failure go away names the pass to bisect,
not the fix: find the code the pass mistreats (a type pun breaks the strict-aliasing rule; an
optimizer defect is a miscompile).

## Lint-Based Leak Detection

```sh
super-c lint                    # statically detect missing frees (error-level by default)
```

The `missing-free` lint is an error. It flags only a non-generic union with an owning
field (pointer, reference and bare type-parameter fields excepted) and no `Free`
conformance: structs and enums derive `Free`, but a union cannot, since only its author
knows the active member (`tc_lint_missing_free` in `src/typechecker/typechecker.spc`). It
does not track owning values in general; the runtime leak tracker covers those. A test
that leaks on purpose uses `forget(..)`.

A lint test that imports a sibling fixture file must run the lint from the fixture root
(`cli::superc_env_in(root, ..)`, as `lint_reports_cross_module_duplicate_conformance` in
`tests/tooling/lint_test.spc` does); otherwise use a prelude-loaded ffi module such as `stdio`.
