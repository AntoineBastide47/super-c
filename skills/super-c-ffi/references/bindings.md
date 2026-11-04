# Bindings and C Libraries

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
  the native build does not check the name, and an invented one fails when the `--emit-c` tree
  compiles).
- A header the runtime does not include reaches only the C files that use one of its items: the
  emitter spells each item by an alias, `__sc_x_<C name>`, which the header's generated file
  defines. Its macros (`near` and `far` of `<windows.h>`) do not rename the identifiers of other
  files, but they do in a file that uses the header: do not name a local or field like one of the
  header's macros in the module that calls it. A header may need another first (`<psapi.h>` after
  `<windows.h>`): bind the needed header in an earlier block of the same module. Every unit then
  includes them in that order, also when another module binds the later header first
  (`<ws2tcpip.h>` before `<windows.h>`). A unit that includes such a header compiles outside the
  unity build.
- A function of a block without a header gets a C prototype from its Super-C declaration, unless
  a header the runtime always includes declares it at the build's POSIX level (the C library) or its name starts
  with `__sc_` (the runtime's entry points). A BSD or GNU addition those headers hide at that level
  (`arc4random_buf`, `strlcpy`, `memmem`, `qsort_r`: `C_EXT_NAMES` in `src/emit/mangle.spc`) and a `_np` name
  get the prototype.
  Use such a block for a function whose header the build's feature macros
  (`-D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700`) cannot include, such as macOS `sysctlbyname`; never define a
  feature macro (`_DARWIN_C_SOURCE`) for it. A Win32 function binds in a `"windows.h"` block, its
  structs as header types (`@import("FILETIME")`): the runtime includes `<windows.h>`, and a
  prototype of its own with another pointee type is a C error ("conflicting types").
- `stdlib::c_ulong` spells `uint32_t` on Windows, which C does not convert to `unsigned long *`
  (`LPDWORD`): bind such a pointer parameter as `*mut void`.
- A C function pointer binds as a `fn(..)` type (a parameter, a result, a header type's field), never
  `*mut void`: C converts a function pointer to `void *` only as an extension, which
  `-pedantic-errors` rejects. A value that may be null or a sentinel (`SIG_DFL`, a null destructor)
  passes through a union of the `fn` type and `*mut void` (`HandlerBits`, `KeyDestructor`), since a
  `fn` value is never null. A Win32 function type whose C signature names `DWORD` or `LONG` (`C
  unsigned long`, `long`, which no Super-C type spells) binds as an opaque `@layout(8, 8)` type of its
  typedef (`PHANDLER_ROUTINE`, `FARPROC`, `PVECTORED_EXCEPTION_HANDLER`), reached through a union with
  the `fn` type.
- A typed pointer passed to a parameter declared `*mut void` or `*const void` is spelled
  `(void *)(arg)` in C, so the header may declare another pointee (Winsock's `char *` option
  values, `u_long *`).
- `pub` inside an extern block exports the binding cross-module.
- Calling an extern binding requires `unsafe` at the call site, unless its `@unsafe(...)` lists `safe`.
  So does naming it as a value (`let f: fn(i32) i32 = unsafe abs;`): a call through the `fn`
  pointer needs no `unsafe`.
- `char` is C `char`, and it is unsigned (0 to 255) everywhere: the build engine compiles
  every generated TU with `-funsigned-char`, on every target, so
  `200 as char as i32` is 200 at compile time and at run time. A C file compiled apart
  from the engine and linked with the generated code needs the flag too (the generated
  `super_rt.h` has a static assertion on it). The ABI is the same either way; only a
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

The header declares the functions of such a block, so a call converts each argument to a `*mut void` or
`*const void` parameter through `void *`: a binding may spell a pointer type no Super-C type matches
that way (Win32 `DWORD *`, C `unsigned long *`, in `std/platform/fs.spc`).

`setjmp.h` is banned: `longjmp` bypasses normal control flow (drops, defers, borrow scopes) and
breaks the memory-safety model. Never add it to the runtime includes or to `ffi/`.

A C header must not share its stem with a Super-C module: the emitted module header has that
name and one shadows the other (a module `time.spc` that binds `"time.h"` hides the C header). A
std file must not share its stem with an `ffi/` module it imports (`std/parallel/atomics.spc`
imports `ffi/atomic.spc`).

## C Libraries

The build compiles no C source of the program's tree: a C library comes prebuilt and reaches the
link through `@link` (Link flags below). A `.c` file beside a backing header is no part of the build.
`bench/simd_baseline` is the example: `kernels.sh` archives its hand-written C kernels into
`build/simd_baseline/<arch>/libsimd_baseline.a`, and `kernels.spc` links it with
`@link("-Lbuild/simd_baseline/<arch> -lsimd_baseline")`. A C file compiled apart from the engine and
linked with the generated code needs `-funsigned-char` (below). The own linker links such a static
library on every native target. It adds no C compiler runtime archive: a library that needs one
(libgcc.a, libgcc_eh.a or compiler-rt's builtins: `__cpu_model`, `_Unwind_Backtrace`) names it in
`@link`.

`ffi/sc_cpu.spc` is the example of per-OS bindings behind one interface, with no C file: the CPU
feature detector selects its query with `@platform` and `@arch` (`sysctlbyname` on Apple, `getauxval`
on Linux and Android, `IsProcessorFeaturePresent` on Windows aarch64, CPUID and XGETBV `asm` on
x86_64, none on wasm32), names the OS constants older headers lack by their documented values,
treats a failing query as "absent", and reads the build's own set from the build constant
`TARGET_FEATURES`. A `static mut` function pointer in the init-array section (`@unsafe(link_section =
...)`) runs it before `main`; atomics with acquire and release publish the answer, so two first
callers store equal words with no lock. `@export` gives the generated C its `sc_cpu_words`.

std, ffi and the compiler hold no C source: they are Super-C throughout. `@c.source` is removed
(an unknown attribute).

### Link flags

```superc
@link("m")                     // -lm
extern "C" {
    fn sqrt(x: f64) f64;
}

@link("-framework CoreFoundation")  // value starting with - passes through verbatim
extern "C" {
    fn CFAbsoluteTimeGetCurrent() f64;
}
```

One extern block takes at most one `@link` (a repeated attribute is a parse error). A value
starting with `-` may hold several whitespace-separated flags; a second library otherwise goes
on its own extern block.

Link flags are written to `build/<profile>/raw/__ldflags` (one per line). Libraries declare their flag
once where the binding lives. Importers never repeat it. Flags apply automatically to
`--test` builds.
