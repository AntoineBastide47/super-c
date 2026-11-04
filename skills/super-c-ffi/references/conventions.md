# Conventions and Tools

## The ffi/ Convention

The `ffi/` directory ships one `.spc` per C header:

```
ffi/
  stdio.spc       # import stdio;
  stdlib.spc      # import stdlib;
  string.spc      # import string as cstring;
  pthread.spc     # import pthread;
  math.spc        # import math;    (@link("m") declared here)
  ...
```

The loader resolves `import X;` by searching: project root → `std/` → `ffi/X.spc`.
FFI modules include safe wrappers alongside raw bindings (e.g., `stdio` has an RAII
`File` type, `stdlib` has `get_env(name) Option<String>`, an owned copy, and `env_is(name, value)`).

The raw bindings carry the `@unsafe` claims their C contract supports (rules below):

| Claim | Bindings |
|-------|----------|
| `safe` | every `math` function except `lgamma`/`lgammaf` (they write the global `signgam`); `stdlib::abort`; `time::clock`, `difftime`; `unistd::getpid`, `getppid`, `sleep`; `stdio::getchar`, `putchar`; `pthread::pthread_self` |
| `const` | `stdlib::abs`, `llabs`; `string::strlen`, `memchr`, `strchr`, `strrchr`, `strstr` |

A binding is `safe` only when every argument value is defined behavior in C, the call is
thread-safe, and it touches no resource another owner holds: `abs` (undefined at
`i32::MIN`), the `ctype` classifiers (undefined outside `unsigned char` and `EOF`),
`rand` (shared state), `close`/`dup2` (a descriptor someone else owns) and
`pthread_equal` (undefined on a joined handle) stay unsafe. A binding is `const` only
when C fully specifies its result: `strcmp`, `strncmp` and `memcmp` fix only the sign,
and locale-dependent functions differ by process. The evaluator computes libm,
`memcmp`, `memcpy`, `memset`, `malloc`, `realloc` and `free` itself (`Interp::intercept`),
so those take no model.

## Attributes Summary

| Attribute | Scope | Effect |
|-----------|-------|--------|
| `@link("lib")` | extern block | Declare a link flag |
| `@export("sym")` | function | Pin exact C symbol (external linkage) |
| `@import("sym")` | extern fn, extern type, header type field | Import with exact C symbol; the C spelling of an extern type; the C member of a field |
| `@unsafe(safe, const)` | extern fn | Claims, any order: `safe` = callable without `unsafe`, `const` = body is the compile-time model |
| `@value(size, align)` | opaque extern type | A C register type of that layout (Register types in [types.md](types.md)) |
| `@layout(size, align)` | opaque extern type | A C value of that exact layout, checked in C (C values in [types.md](types.md)) |
| `@thread_local` | `static mut`, extern `static mut` | One object per OS thread (Macro Objects and Thread-Locals in [types.md](types.md)) |
| `@reads(p, n)` / `@writes(p, n)` | extern fn | Reads or writes only `n` bytes through pointer parameter `p` (Memory Annotations in [functions.md](functions.md)) |
| `@lane_access` | extern fn | Lane-by-lane memory access: no vector entry that calls it under a memory checker |

## bindgen

```sh
super-c bindgen header.h -o out.spc     # --link=, --header=, -I, --from=, --cflag=, --target=, --arch=, --sysroot=
```

Generates `.spc` bindings from C headers (`src/bindgen/bindgen.spc`). No C compiler runs: the
headers go through bindgen's own C preprocessor (`src/bindgen/cpp.spc`) under the target's C
environment (`src/bindgen/ctarget.spc`): clang's predefined macros and `__has_*` answers, its
built-in headers, and the system and framework directories of the target's sysroot. The sysroot
is found as the build finds it, or given by `--sysroot=`. `-I` directories come before the system
ones. The headers see the build's C environment (`push_c_env`): the dialect and the POSIX level,
`-funsigned-char` and, for Windows, `-D_WIN32_WINNT=0x0A00`, so the output declares what the build
reads from the same headers. `--cflag=` applies after them and takes only `-std=`, `-D`, `-U`, `-fsigned-char` and `-funsigned-char`; any other flag is an
error. Use it for large C
APIs where hand-writing bindings is impractical. The generated output follows the `ffi/`
conventions. A record whose every member has a field form becomes a header type with every
member, and a tagged enum an extern `enum`: a tagged record or enum spells as its tag, one that
only a typedef names pins that name, and a member named by a keyword pins its C name. Any other
record, and a record that holds an opaque type by value, stays an opaque `pub type`. An integer
macro or anonymous enumerator becomes a constant with a value inside the extern block (its C
compile checks the value). An integer macro takes the type C gives it, from the literal's suffix
and base and the usual conversions of its operators and casts (`u32`, `u64`, `i32`, `i64`); a
value outside `i64`'s range, or a signed overflow, leaves the macro out. A float or string macro
becomes a plain top-level constant. The output
is the build target's: generate it per target where the values differ.

## Atomics and Memory-Order Codes

`ffi/atomic.spc` binds the `__sc_atomic_*` helpers of `super_rt.h` (`src/emit/rt_h.spc`),
which lower to the C `__atomic_*` builtins. Each operation takes the order as an `i32` code;
`MemoryOrder as i32` in `std/parallel/atomics.spc` gives it:

| Code | Order | C constant |
|------|-------|------------|
| 0 | `Relaxed` | `__ATOMIC_RELAXED` |
| 1 | `Acquire` | `__ATOMIC_ACQUIRE` |
| 2 | `Release` | `__ATOMIC_RELEASE` |
| 3 | `AcqRel` | `__ATOMIC_ACQ_REL` |
| 4 | `SeqCst` | `__ATOMIC_SEQ_CST` |

| Operation | Valid codes |
|-----------|-------------|
| load, `cas` failure | 0, 1, 4 |
| store | 0, 2, 4 |
| swap, add, sub, and, or, xor, `cas` success, `fence` | 0 to 4 |

Any other code calls `__sc_trap_order`, which panics with "invalid memory order" (the
`__sc_panic` path: message on stderr, then `abort`). `SC_MO_CAS(so, fo)` strengthens the
success order to at least the failure order before the C call, as the C builtin requires:
`Relaxed` + `Acquire` runs as `Acquire`, `Release` + `Acquire` as `AcqRel`, and a `SeqCst`
failure as `SeqCst`. The checks are ternaries over the code, so a constant valid order
still folds to the one instruction at `-O1` and above.

## Platform C Pitfalls

The build reads the C headers with `-std=c11 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700`
(`push_c_env`: POSIX 2008 with the XSI extension, which declares `realpath` on glibc and
wasi-libc) and `-funsigned-char`; the C tree of `--emit-c` compiles with the same flags, plus
`-ffp-contract=off -Werror=incompatible-pointer-types` and the libm `-fno-builtin-<f>` set
(`LIBM_AS_WRITTEN` in `src/driver/emit.spc`: `sin(x)` is a libm call, never a constant fold or a
`sincos`). Windows also gets `-D_WIN32_WINNT=0x0A00` (`push_c_env` in `src/driver/util.spc`):
the Windows 10 API level on every mingw toolchain. MSYS2 defaults to it; llvm-mingw defaults to
Windows 7, whose headers hide the Windows 8 functions the runtime calls.

- macOS: strict `_POSIX_C_SOURCE` breaks `<sys/sysctl.h>`, `<libproc.h>` and
  `<malloc/malloc.h>`, hides `struct rusage_info_v4` and names `struct rusage`'s counters
  `ru_opaque`. std/platform/process.spc and std/testing/bench_sys.spc bind such functions in blocks without a
  header (each gets a prototype from its Super-C declaration) and mirrors the hidden records as
  Super-C structs with the header's layout.
- Windows (mingw) fakes POSIX. `stat().st_ino` is 0, so a dev+ino identity test matches
  unrelated files (std/platform/fs.spc uses `GetFileInformationByHandle`). Files and stdio
  default to text mode: CRLF breaks `\`-continued macros and byte framing, so open with
  `"wb"` and set stdio binary. `tmpfile()` writes to the drive root: use `GetTempPathA`
  (`%TEMP%`) and `fopen(.., "wb")`. There is no `open_memstream`.
