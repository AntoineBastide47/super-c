# The platform layer

The operating system enters through std, gated by `@platform(...)` on the `OSES` names:

| Part | Files | Holds |
|---|---|---|
| OS services | `std/platform/` (`fs`, `process`, `thread`, `clock`, `env`, `socket`, `signal`, `vm`, `dylib`, `entropy`, `cpu`, `path`, `error`) | POSIX through libc, Windows through Win32, WASI through `std::rt::libc` |
| Runtime substrate | `ffi/sc_runtime.spc` | threads, synchronization and the coroutine context the concurrency runtime uses |
| Runtime | `std/rt/base.spc` | traps, the scheduler hooks, the allocation tracker, crash reports |
| Own C library | `std/rt/libc.spc`, `std/rt/libm.spc` | a target with `own_libc` (wasm32) links these in place of a system C library |
| Compiler routines | `std/rt/builtins.spc` | 128-bit division, conversions and multiplication where the C library lacks them |
| SIMD | `std/simd/backend/` | the vector operations of an instruction set (`Isa.simd_backend` names the file) |

## Porting std to a new OS

1. Every `std/platform/` module compiles for the new name: add it to the `@platform` gate of the
   matching implementation (a POSIX system usually joins `macos | ios | linux | android`), or give it an
   implementation, or return `Unsupported` (as WASI does for threads and permissions).
2. The C bindings of each module declare the system's own types and constants; check every layout
   against the system headers (`struct stat` differs between systems).
3. The runtime substrate and the context switch (`src/target/ctxswitch.spc`) for the system's calling
   convention and its thread model.
4. A system without a C library sets `own_libc` and extends `std/rt/libc.spc`
   (`tests/codegen/wasm_libc_test.spc` checks that it defines what std binds).

Platform FFI stays inside the modules `std/packages.toml` exempts (the gate's std package rules).
