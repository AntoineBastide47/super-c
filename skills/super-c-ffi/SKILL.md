---
name: super-c-ffi
description: "Covers C interop in Super-C: extern blocks, header bindings, opaque types, variadics, @c.source/@c.link, the ffi/ convention, str vs NUL-terminated strings, unsafe discipline at FFI boundaries, and the bindgen tool. Use when writing C bindings, integrating external libraries, or debugging FFI issues."
allowed-tools: Bash Read
---

# Super-C C FFI

## Agent checklist

- Confirm the C symbol, header, ownership, and string termination contract.
- Keep every extern call inside an explicit `unsafe` boundary, except a call of a function whose `@unsafe(...)` lists `safe`.
- Check whether a backing source or link flag is already declared.
- Validate opaque types against a real included C declaration.

Super-C interoperates with C through `extern "C"` blocks. Bindings map directly to C
symbols with no wrapper or mangling.

## Basic Bindings

```superc
extern "C" {
    type FILE;                                           // opaque type (a real C type)
    fn fopen(path: *const char, mode: *const char) *mut FILE;
    fn fclose(file: *mut FILE) i32;
}
```

- Extern names match the C symbol exactly, never module-mangled. The same applies to an
  opaque `type`: it renders as its bare C name, so it must name a type some included
  header actually defines (`FILE` works headerless because `stdio.h` is auto-included;
  an invented name fails in the C compile).
- `pub` inside an extern block exports the binding cross-module.
- Calling an extern binding requires `unsafe` at the call site, unless its `@unsafe(...)` lists `safe`.
  So does naming it as a value (`let f: fn(i32) i32 = unsafe abs;`): a call through the `fn`
  pointer needs no `unsafe`.
- `char` is C `char`, and it is unsigned (0 to 255) everywhere: the build engine compiles
  every generated and `@c.source` TU with `-funsigned-char`, on every target, so
  `200 as char as i32` is 200 at compile time and at run time. A C file compiled apart
  from the engine and linked with the generated code needs the flag too (the generated
  `super_rt.c` has a static assertion on it). The ABI is the same either way; only a
  `char` value above 127 reads differently on the C side without the flag.

## Header Bindings

```superc
extern "C" "dirent.h" {          // system header -> #include <dirent.h>
    pub type DIR;                // opaque: layout lives in <dirent.h>
    fn opendir(path: *const char) *mut DIR;
    fn closedir(d: *mut DIR) i32;
}

extern "C" "./local.h" {         // local header -> #include "local.h"
    fn local_init() void;
}
```

The `#include` is emitted in the generated C. A locally-resolved header gets its path
rewritten to work from inside the `build/` tree. All 31 C standard headers are
auto-included via `super_rt.h`, so standard C functions need no explicit header.

`setjmp.h` is banned: `longjmp` bypasses normal control flow (drops, defers, borrow scopes) and
breaks the memory-safety model. Never add it to the runtime includes or to `ffi/`.

A C header must not share its stem with a Super-C module: the emitted module header has that
name and one shadows the other (`ffi/sc_runtime.spc` binds `sc_rt.h`, not `sc_runtime.h`). A
std file must not share its stem with an `ffi/` module it imports (`std/parallel/atomics.spc`
imports `ffi/atomic.spc`).

## Backing C Sources

### Auto-discovery

A header binding that resolves next to the `.spc` file auto-discovers a same-stem `.c`
sibling:

```superc
// src/native.spc
extern "C" "native.h" {         // native.c beside native.spc is compiled automatically
    fn native_mix(a: i32, b: i32) i32;
}
```

### Explicit source

```superc
@c.source("impl/engine.c")      // names a C file relative to this .spc file
extern "C" "engine.h" {
    fn engine_init() void;
}
```

Each backing source becomes a wrapper translation unit in `build/` (`__ext<N>_<stem>.c`)
with one absolute `#include`, preceded by `#define SC_RT_LK_STATS <level>`: the runtime
API level of the compiler that wrote the wrapper, which `ffi/sc_rt.c` tests to compile
stand-ins for runtime entry points an older runtime lacks (plain definitions; weak
symbols do not resolve across objects on PE). A new runtime entry point raises the level
in `extc.spc` and guards its stand-in with `#if SC_RT_LK_STATS < <level>`, so the
bootstrap release and a dev binary from the previous commit both still link the new
source. Relative includes in the backing source continue to resolve correctly.

### Link flags

```superc
@c.link("m")                     // -lm
extern "C" {
    fn sqrt(x: f64) f64;
}

@c.link("-framework CoreFoundation")  // value starting with - passes through verbatim
extern "C" {
    fn CFAbsoluteTimeGetCurrent() f64;
}
```

One extern block takes at most one `@c.link` and one `@c.source` (a repeated attribute is a
parse error). A value starting with `-` may hold several whitespace-separated flags; a second
library or source otherwise goes on its own extern block.

Link flags are written to `build/__ldflags` (one per line). Libraries declare their flag
once where the binding lives. Importers never repeat it. Flags apply automatically to
`--test` builds.

## Opaque Types

```superc
extern "C" "dirent.h" {
    pub type DIR;                // C struct known only by pointer
}
```

Opaque types lower to `TYPE_OPAQUE` and render as their bare C name (not `void`), so the
declaring block must include the header that defines the name: an opaque type used
without its header fails in the C compile. By-value handles (`clock_t`) also work when
the C type is a scalar.

## Variadics

### Calling variadic C functions

```superc
extern "C" { fn printf(fmt: *const char, ...) i32; }

unsafe printf("x = %d\n", x);
```

String literals coerce to `*const char` in variadic argument slots.

### Defining variadic Super-C functions

```superc
extern "C" { fn vsnprintf(buf: *mut char, n: usize, fmt: *const char, ap: va_list) i32; }

fn format_into(buf: *mut char, n: usize, fmt: *const char, ...) i32 {
    let ap: va_list;
    va_start(ap, fmt);
    let written = unsafe vsnprintf(buf, n, fmt, ap);
    va_end(ap);
    return written;
}
```

`va_list`, `va_start`, `va_arg(ap, T)`, and `va_end` are compiler intrinsics. The
binding does not need `mut` (the lint flags it). Do not name such a helper `format`:
that collides with the prelude's `format()` shim in the generated C.

## The ffi/ Convention

The `ffi/` directory ships one `.spc` per C header:

```
ffi/
  stdio.spc       # import stdio;
  stdlib.spc      # import stdlib;
  string.spc      # import string as cstring;
  pthread.spc     # import pthread;
  math.spc        # import math;    (@c.link("m") declared here)
  ...
```

The loader resolves `import X;` by searching: project root → `std/` → `ffi/X.spc`.
FFI modules include safe wrappers alongside raw bindings (e.g., `stdio` has an RAII
`File` type, `stdlib` has `get_env() Option<String>`).

The raw bindings carry the `@unsafe` claims their C contract supports (rules below):

| Claim | Bindings |
|-------|----------|
| `safe` | every `math` function except `lgamma`/`lgammaf` (they write the global `signgam`); `stdlib::abort`; `time::clock`, `difftime`; `unistd::getpid`, `getppid`, `sleep`; `stdio::getchar`, `putchar`; `pthread::pthread_self`; the `sc_runtime` queries and hints (`sc_rt_now_ns`, `cycles`, `page_size`, `ncpu`, `widx_get`, `cpu_relax`, `thread_yield`, `parked`, `sleep_ns`, `stack_bytes`, `ctx_inline_size`); `sc_io_errno`, `sc_io_would_block` |
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

## str vs NUL-Terminated Strings

**`str` is NOT NUL-terminated.** `str` and `String::as_str()` are `{ptr, len}` views.
The one exception is a string literal: the emitter spells it as a C literal, so a NUL
follows its `len` bytes, and `"lit".ptr() as *const char` is a C string. Compile-time
evaluation stores that NUL too, and reads a literal's bytes through `*const char` as
through `*const u8`, so a `const` model (`strlen`) sees what the C call sees.

| Operation | Correct | Wrong |
|-----------|---------|-------|
| Pass to C `%s` | `%.*s` with `.len()`, `.ptr()` | `%s` with `.ptr()` (buffer overread) |
| Pass to C API expecting `const char*` | `String::cstr()` (writes trailing NUL) | `.ptr()` (no NUL) |
| Build from C string | `str::from_cstr(p)` | Direct cast |

`.cstr()` exists only on `String` and takes `&mut self`: a `str` view has no `cstr`;
materialize it first with `.to_string()`.

```superc
// Correct: print a str
unsafe printf("%.*s\n", s.len() as i32, s.ptr());

// Correct: pass a str to a C API (via an owned String)
let mut owned = name.to_string();
unsafe some_c_api(owned.cstr());
```

## Symbol Pinning

```superc
@c.export("superc_init")        // pin exact C symbol at definition + all call sites
pub fn init() i32 { return 0; }

extern "C" "legacy.h" {
    @c.import("legacy_cleanup") // bind `cleanup` to a differently-named C symbol
    fn cleanup() void;
}
```

Exported functions get external linkage (non-`static` in the generated C). `@c.import`
goes on the `fn` declaration **inside** the extern block; placed before the block it
parses but does not rename the call sites.

## Pointers to Arrays

A pointer to an array whose element is a Super-C aggregate (`*const [S; 2]`) is a pointer to
the array's wrapper struct in the generated C (`const S__a2 *`, `struct S__a2 { S e[2]; }`): same
address, size, alignment and layout as C's `const S (*)[2]`. A call to an `extern "C"` function
converts such an argument and result through `void *`, so a header that declares the C pointer
type accepts it. An `@c.export` function keeps the wrapper pointer in its definition: C code
may declare it with `const S (*)[2]`, an ABI-identical but distinct C type (as a pointer
parameter of a shim prototype, which the generated C declares `const void *`). A pointer to an
array of scalars (`*const [i32; 2]`) is `int32_t (*)[2]`, with no qualifier on the element.

## Unsafe Discipline at FFI Boundaries

Every `extern "C"` call requires `unsafe`, unless the function's `@unsafe(...)` lists `safe`:

```superc
// Prefix form
let f = unsafe fopen("data.bin", "rb");

// Block form
unsafe {
    let f = fopen("data.bin", "rb");
    if f == null { return -1; }
    fclose(f);
}
```

The `unsafe` marker delimits exactly where the compiler's guarantees stop. Raw-pointer
operations (dereference, indexing, arithmetic, field access) also require `unsafe`.

### `@unsafe(safe, const)`

Two claims about an extern function that the compiler cannot verify, so they are spelled
`@unsafe(...)` and the binding author answers for them. The attribute lists one or both claims,
in any order (`@unsafe(safe, const)` = `@unsafe(const, safe)`), each once; a declaration takes
one `@unsafe(...)`. It applies only to a function in an `extern "C"` block.

```superc
extern "C" {
    @unsafe(safe) fn fabs(x: f64) f64;                // callable without `unsafe`
    @unsafe(const) fn llabs(x: i64) i64 {
        if x < 0 { return -x; }                       // the compile-time model; i64::MIN traps
        return x;
    }
}
const A: i64 = unsafe llabs(-7);                      // evaluates the model
```

`llabs` is not `safe`: `llabs(i64::MIN)` is undefined behavior in C.

- `safe`: a call needs no `unsafe`. The declaration is rejected when a safe call
  could hand C an unchecked value: a variadic function, a parameter that is or names a raw
  pointer (through a reference, slice, array or generic argument), or a returned borrow
  (a reference, slice, or type with a lifetime parameter). Struct fields are the struct's
  own contract and are not searched: a `str` or slice parameter is allowed.
- `const`: the function takes a body, which compile-time evaluation runs. Run-time
  calls still go to the C symbol and the body is never emitted. The body gets the
  `const fn` definition-site check ("is declared '@unsafe(const)' but ..."). The claim is
  that the body returns what the C function returns: annotate only functions whose results
  are fully specified (correctly rounded IEEE operations, `strlen`, `memcmp`), never `sin`
  or `exp`, whose libm results differ between platforms. Without `safe` a call
  still needs `unsafe`.
- Any other extern function takes no body.

## Attributes Summary

| Attribute | Scope | Effect |
|-----------|-------|--------|
| `@c.source("file.c")` | extern block | Name a backing C implementation |
| `@c.link("lib")` | extern block | Declare a link flag |
| `@c.export("sym")` | function | Pin exact C symbol (external linkage) |
| `@c.import("sym")` | extern fn | Import with exact C symbol |
| `@unsafe(safe, const)` | extern fn | Claims, any order: `safe` = callable without `unsafe`, `const` = body is the compile-time model |

## bindgen

```sh
super-c bindgen header.h -o out.spc     # --link=, --header=, -I, --from=, --cflag=, --cc=
```

Generates `.spc` bindings from C headers (`src/bindgen/bindgen.spc`). Use it for large C
APIs where hand-writing bindings is impractical. The generated output follows the `ffi/`
conventions.

## Atomics and Memory-Order Codes

`ffi/atomic.spc` binds the `__sc_atomic_*` helpers of `super_rt.h` (`src/driver/rt_c.spc`),
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

The build compiles C with `-std=c11 -D_POSIX_C_SOURCE=200809L` (the `cstd` value), plus
`-funsigned-char -ffp-contract=off -Werror=incompatible-pointer-types` on every compile.

- macOS: strict `_POSIX_C_SOURCE` breaks `<sys/sysctl.h>` and hides `ru_maxrss`.
  src/driver_shim.c declares `sysctlbyname` locally and defines `_DARWIN_C_SOURCE` before
  its includes; std/testing/bench_sys.c defines `_DARWIN_C_SOURCE` too.
- Windows (mingw) fakes POSIX. `stat().st_ino` is 0, so a dev+ino identity test matches
  unrelated files (src/driver_shim.c uses `GetFileInformationByHandle`). Files and stdio
  default to text mode: CRLF breaks `\`-continued macros and byte framing, so open with
  `"wb"` and set stdio binary. `tmpfile()` writes to the drive root: use `GetTempPathA`
  (`%TEMP%`) and `fopen(.., "wb")`. There is no `open_memstream`.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Passing `str` to C `%s` | Use `%.*s` with `.len()` + `.ptr()` (`str` has no `.cstr()`) |
| Missing `unsafe` on extern call | Add `unsafe` prefix or block |
| Repeating `@c.link` in every importing module | Declare it once on the binding module |
| Using `void` for opaque types | Use `type X;` (with its defining header): renders as the real C name |
| Assuming `String::ptr()` is NUL-terminated | It is not. Use `String::cstr()` |
| Passing `.ptr()` to an `sc_*` path call (`sc_mkdir`, `sc_stat_isdir` in src/driver_shim.spc) | Use `.cstr()` as for any C call; a heap string whose allocation equals its length has no NUL after it, so failures depend on the length |
| Inventing an opaque type name (`type CFile;`) | The name must be a real C type a header defines |
| `@c.import` before the extern block | Put it on the `fn` inside the block |
