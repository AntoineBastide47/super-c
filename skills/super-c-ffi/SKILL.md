---
name: super-c-ffi
description: "Covers C interop in Super-C: extern blocks, header bindings, opaque types, variadics, prebuilt C libraries and @link, the ffi/ convention, str vs NUL-terminated strings, unsafe discipline at FFI boundaries, and the bindgen tool. Use when writing C bindings, integrating external libraries, or debugging FFI issues."
allowed-tools: Bash Read
---

# Super-C C FFI

## Agent checklist

- Confirm the C symbol, header, ownership, and string termination contract.
- Keep every extern call inside an explicit `unsafe` boundary, except a call of a function whose `@unsafe(...)` lists `safe`.
- Check whether a link flag is already declared.
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
linked with the generated code needs `-funsigned-char` (below).

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

## Opaque Types

```superc
extern "C" "dirent.h" {
    pub type DIR;                // C struct known only by pointer
}
```

Opaque types lower to `TYPE_OPAQUE` and render as their bare C name (not `void`), so the
declaring block must include the header that defines the name: an opaque type used
without its header fails in the C compile. An opaque type has no layout: it is valid only as the
direct target of a pointer or a reference, an `extend` target or a type alias's definition. A
value of it (a parameter, a result, a local, a field, an element, a generic argument such as
`zeroed::<T>()`) is "'T' is an opaque C type with no layout: a value of it needs one": give it
its layout with `@layout` (below) or bind the complete struct. No type of an extern block (an opaque type, a header type, an
extern `enum`) implements `Free`: it is a C value that copies, so its glue would never be the one
owner's ("'clock_t' is a type of an 'extern \"C\"' block: it cannot implement 'Free'"). Wrap it in a
struct that implements `Free` (`stdio::File` holds a `*mut FILE`).

### C values: `@layout(size, align)`

```superc
extern "C" "pthread.h" {
    @platform(macos)
    @layout(64, 8)
    pub type pthread_mutex_t;    // a C value whose members stay private
}
```

`@layout` gives an opaque type of an `extern "C"` block the exact layout of its C type: `size` a
nonzero multiple of `align`, both `usize` constant expressions ("'@layout' needs a nonzero size
that is a multiple of the alignment, a power of two"). The header's checks (below) hold:
`_Static_assert(sizeof(T) == size && _Alignof(T) == align, "super-c: 'T' must have <size> bytes
aligned to <align> in C")`, so its block needs a header ("an opaque type with a '@layout' of an
'extern \"C\"' block is checked against its C header: the block needs that header"). A
pointer-sized handle takes `@layout(sizeof(usize), sizeof(usize))` (`pthread::pthread_t`). The
type is then a value like any other: a field of a header struct,
an array element, a static, `sizeof` at compile time. A register type takes no `@layout` ("a
register type ('@value') states its layout: it takes no '@layout'"). The native backend passes such
a value as the scalar the header's typedef names (an integer or pointer, `float`, `double`), and a
struct or union of scalars as the C compiler does, from the header's members when their layout is the
declared one; a module that passes one of any other C type by value (a bitfield, a `packed` member)
goes through C, except on Windows x64, which passes every aggregate by its size.

### Register types: `@value(size, align)`

```superc
extern "C" "wasm_simd128.h" {
    @value(16, 16)
    pub type v128_t;             // a C vector register type, passed by value
}
```

`@value` gives an opaque type of an `extern "C"` block a layout: `size` a nonzero multiple of
`align`, both constant expressions of type `usize` ("'@value' needs a nonzero size that is a
multiple of the alignment"; on any other declaration "'@value' may only be applied to an
opaque type ('type T;') in an 'extern \"C\"' block"). The type is `Copy` and `sizeof`/`alignof`
read the layout; a `_Static_assert` beside the block's header include checks it against C. It may be a local, a parameter or a result, never storage: a struct field, an
array or slice element, a variant payload, a static or const, a pointer or reference target, a
closure capture, or a generic argument, written or inferred, is "`v128_t` is a register type;
store it through `Simd<T, N>`". It moves to and from a vector through memory
(`wasm_v128_load`, `wasm_v128_store`), which the C compiler keeps in registers.

## Header Types

```superc
extern "C" "sys/stat.h" {
    @platform(windows)
    pub struct stat {
        pub st_dev: u32,
        pub st_ino: u16,
        pub st_mode: u16,
        pub st_nlink: i16,
        pub st_uid: i16,
        pub st_gid: i16,
        pub st_rdev: u32,
        pub st_size: i32,
        pub st_atime: i64,
        pub st_mtime: i64,
        pub st_ctime: i64,
    }
    pub fn stat(path: *const char, buf: *mut stat) i32;
}

extern "C" "stdlib.h" {
    @import("div_t")                                          // a typedef name
    pub struct div_t { pub quot: i32, pub rem: i32 }
}
```

A `struct` or `union` of an `extern "C"` block is a header type: its C header defines it, and the
declaration lists EVERY member in the header's order. Super-C emits no definition; it computes the
layout from the declaration by the C rules, and the C compile checks that layout against the
header. An extern `enum` is a header type too: the header defines the type and its constants, which
the emitted C names as the header does (`RED`), and its layout check (`sizeof == 4`) stays. The
block must name the header ("a struct of an 'extern \"C\"' block is its C header's type: the
block needs that header"): Super-C cannot see which headers define a type, and a type of the
standard headers the runtime includes is declared under its header too (`extern "C" "time.h" {
struct tm { .. } }`). Read each member from the target's real headers (`clang -Xclang
-fdump-record-layouts` prints them): a guessed layout fails the C compile on that target.

- **Spelling.** `struct X`, `union X` and `enum X` are the C tag. `@import("name")` pins another
  spelling: a typedef name (`pthread_attr_t`, `div_t`, a `typedef enum { .. } mode;`), or MSVC's
  `struct _stat`. A typedef'd type declared without its pin spells a tag C does not define, and the
  C compile stops at its completeness check (below).
- **Fields.** Every member of the header's type, in its order, padding members included (glibc's
  `__pad0`: bind it as a private field pinned with `@import("__pad0") pad0: i32`). A field type
  is a C scalar, a raw pointer, a `fn` pointer, a header struct, union or enum, an opaque type with
  a `@layout`, or an array of these ("field 'f' of 'S' has type 'T', which has no C equivalent").
  A member named by a Super-C keyword binds under another name with `@import("select") pub
  select_: i32` (on a header type's field only). A field named by a C keyword or a standard-header
  macro (`errno`) gets a `_` suffix like every Super-C name: pin it the same way. An unknown field
  at a use is "no field 'f' on 'S'".
- **Checks.** The generated header of the C header (`__sc_t/__scx<k>.h`; `__sc_fwd.h` for a header
  `super_rt.h` includes, except in the runtime module) holds, after the include, and every unit that uses one of the header's
  items includes it, as does the registry unit when no unit does, so each check runs once even where
  no unit uses the header: `sizeof(T) != 0`; `sizeof(T) == S && _Alignof(T) == A` with Super-C's layout
  ("super-c: 'tm' must have 56 bytes aligned to 8 in C: declare every member of the header's type,
  in its order"); per field `offsetof(T, f) == O` ("super-c: field 'div_t.rem' must sit at byte 4
  in C: ...") and the member's kind and size (signedness by `_Generic` over the standard integer
  types, `_Bool`, `float`, `double`, the complex types, a pointer as no arithmetic type of a
  pointer's size, an extern type by exact type, an array by its length at each level and then its
  element, a length of 0 by its element alone: C's flexible array member, `char d_name[];`, has no
  size; `&e.d_name` addresses it at its offset in `e`): "super-c: field 'stat.st_mode' must be an unsigned integer of 4 bytes in C". A member
  the header lacks is a C error at its check. A header that does not define the type stops the C
  compile at the completeness check, the type's first use in a unit: C has no completeness
  test that does not stop the compile, so the first error is C's "incomplete type" on the line of
  "super-c: 'pt' must be a complete C type".
- **Layout.** Super-C knows the size, the alignment and every offset, at compile time too:
  `const N = sizeof(stat)`, `static_assert`, an array length, a repeat count and `type_info` work.
  `@packed` and `@align(N)` on the declaration match a packed or over-aligned C type. Every
  other use works as for a Super-C struct: a by-value local, parameter or result, a copy (the type
  is `Copy`), an array, a slice, `Vector`, `Option`, a field of a Super-C struct, a generic
  argument, `unsafe zeroed::<T>()` (`(struct stat){0}`), a struct literal (designated: every member
  it omits is zero), a `const` or `static mut` (designated static data). `extend X as Free` is an
  error: the type has no drop glue.
- **Targets.** Gate a declaration with `@platform` and `@arch` where the members differ (`struct
  stat` differs on every target; glibc's x86-64 and arm64 layouts differ; wasm32's `long` is 32
  bits; Windows is LLP64).

## Header Constants

```superc
extern "C" "fcntl.h" {
    @platform(macos | ios)
    pub const O_CREAT: i32 = 0x200;
    @platform(linux | android)
    pub const O_CREAT: i32 = 0o100;
    @platform(windows)
    pub const O_CREAT: i32 = 0x100;
    @platform(wasm)
    pub const O_CREAT: i32 = 0x1000;
    pub const O_RDONLY: i32;             // no value: the C name, read at run time
}
```

A constant of an `extern "C"` block with a value is a Super-C constant: it folds at compile time
(an array length, a `static_assert`, a `const fn`), and its C symbol is its own, never the header's
name. The header's checks (above) hold the check of the header's macro or enumerator against it:
`_Static_assert((O_CREAT) == 512ULL, "super-c: constant 'O_CREAT' must be 512 in C")`.
`@import("NAME")` checks another C name. The type is an integer or `bool` ("a constant of an
'extern \"C\"' block with a value is an integer or a 'bool': the C compile checks it"), and the
block needs its header ("a constant with a value of an 'extern \"C\"' block is checked against its
C header: the block needs that header"). A constant without a value is the C name itself, read at
run time. An extern `static mut` takes no value. Its block's header declares it; one of a block
without a header is declared by every unit that uses it (`extern T name;`), as a header-less
function gets its prototype.

A native build (super-c-compiler-internals, "Native backend") reads the value of a constant
without a value from its header with the compiler's own preprocessor, so the object holds it and
an edit of the header rebuilds the object. A call of a function the header defines `static` (no
object exports it) sends the calling module through C.

## C Integer Widths

C's `long` is 32 bits on Windows (LLP64) and on wasm32, 64 bits on the other targets: bind it as
`stdlib::c_long` / `stdlib::c_ulong`, never as `i64`. Other per-target typedefs get a per-target
alias beside their binding (`time::clock_t`: `u64` on Apple, `i64` on Linux and wasm, `i32` on
Windows). A Windows C runtime function that counts in `int` (`read`, `write`, `getcwd`) gets a
`@platform(windows)` binding with the C width and a wrapper that clamps the count.

## Macro Objects and Thread-Locals

A C macro that names an object is bound per target to what it expands to, never through a C shim:

- `errno`: `__error()` (Apple), `__errno_location()` (glibc), `__errno()` (Android), `_errno()`
  (Windows UCRT) return its address; wasi-libc's header declares `extern _Thread_local int errno`,
  bound as `@import("errno") @thread_local static mut c_errno: i32;` and defined by wasm's C library
  (`std::rt::libc`). `ffi/errno.spc` wraps them.
- `stdin`, `stdout`, `stderr`: `__stdinp` (Apple) or `stdin` (glibc, wasm) extern statics,
  `__acrt_iob_func(i)` on Windows. `ffi/stdio.spc` wraps them. On wasm the header declares them
  `const` objects, which the Super-C C library cannot define: `super_rt.h` turns the three names into
  calls of its `sc_stdio_stream(fd)`, so a binding reads them as on Linux.
- `CLOCK_REALTIME`, `CLOCK_MONOTONIC`: integer constants, except on wasm, where `clockid_t` points
  at a `const` object of the header; `super_rt.h` spells them as the WASI clock id plus one, cast to
  `clockid_t`, which the C library's `clock_gettime` reads. A binding declares them as constants.

wasm has no system C library: a wasm program links `std::rt::libc` and `std::rt::libm`, a subset of
C99 and POSIX over WASI (super-c-binary, Wasm C library). A binding to a C function outside the subset
fails to link on wasm.

`@thread_local` on an extern `static mut` binds a C `_Thread_local` object. Every access goes
through a non-inlined per-unit accessor (`sym__tls()`), so a coroutine that resumes on another
thread reads its new thread's object.

## Memory Annotations

```superc
extern "C" "wasm_simd128.h" {
    @reads(mem, 16)
    fn wasm_v128_load(mem: *const void) v128_t;
    @writes(mem, 16)
    fn wasm_v128_store(mem: *mut void, a: v128_t);
    @lane_access
    fn wasm_v128_load32_lane(mem: *const void, vec: v128_t, lane: i32) v128_t;
}
```

`@reads(p, bytes)` and `@writes(p, bytes)` state that the function reads or writes only
`bytes` bytes through raw pointer parameter `p` (`*mut` for a write) and has no other memory
effect; `bytes` is a `usize` constant or an expression over the function's other `usize`
parameters (`n * 4`; no call, no cast). A function may state both: the write is its effect.
`@lane_access` marks a function that touches memory lane by lane: a build under a memory
checker (`-fsanitize=` with `address`, `memory` or `thread`) never plans a vector entry that
calls one; it states no range, so it takes no `@reads` or `@writes`. The three
apply to a function of an `extern "C"` block or an `@intrinsic` function only, and do not
change the emitted C: the Core IR effect query (`ir::facts::call_access`) reads them, so a read
writes nothing and a write writes only through `p`. Errors: "'q' is not a parameter of this
function", "parameter 'n' of '@reads' must be a raw pointer", "parameter 'p' of '@writes'
must be a '*mut' pointer".

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
binding does not need `mut` (the lint flags it). `va_arg` needs `unsafe`: nothing checks the
caller passed a `T` ("reading a variadic argument with 'va_arg'"). It reads C's promoted type and
converts: `f32` reads a `double`, `bool`, `char`, `i8`, `u8`, `i16` and `u16` read an `int`. Do not name such a helper `format`:
that collides with the prelude's `format()` shim in the generated C.

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
| Build from C string | `unsafe str::from_cstr(p)` (C owns `p`), `str::from_cbuf(buf)` (a buffer the program owns) | Direct cast |

`.cstr()` exists only on `String` and takes `&mut self`: a `str` view has no `cstr`;
materialize it first with `.to_string()`.

A std function that turns a raw pointer into a view, or reads through one, is `unsafe fn`: its caller
promises what the function cannot check (`str::from_raw`, `str::from_cstr`, `String::from_cstr`,
`Array::copy_from`, and the `std::parallel` runtime's entry points). A program-owned buffer goes
through a checked view instead: `str::from_cbuf(buf)` stops at the first NUL or at the buffer's end
(`Array::as_slice()` views an `Array`), `String::push_bytes` takes `[]u8`, and the integer
out-parameters (`widening_mul`, `divmod`) take `&mut`. An environment value read through
`stdlib::get_env` is a copy, so a later `setenv` cannot change it under the reader.

```superc
// Correct: print a str
unsafe printf("%.*s\n", s.len() as i32, s.ptr());

// Correct: pass a str to a C API (via an owned String)
let mut owned = name.to_string();
unsafe some_c_api(owned.cstr());
```

## Symbol Pinning

```superc
@export("superc_init")        // pin exact C symbol at definition + all call sites
pub fn init() i32 { return 0; }

extern "C" "legacy.h" {
    @import("legacy_cleanup") // bind `cleanup` to a differently-named C symbol
    fn cleanup() void;
}
```

C code calls a Super-C function through `@export`: a program with `main` emits only the functions
it reaches from `main` (and the ones whose calls are not all inlined), so a function only C calls
needs `@export` (or `@used`) to have a definition. A build with no `main` emits every function of
the project; a `[lib]` build emits its exported (`pub`) functions and what they reach.

Exported functions get external linkage (non-`static` in the generated C). The definition and
its prototype spell the symbol parenthesized (`void *(malloc)(size_t n)`), so a function-like
macro of that name (super_rt.h's leak-tracker `malloc`, `calloc`, `realloc`, `free`) does not
expand; a call through a member or a local of one of those four names is parenthesized too
(`(z->malloc)(z, n)`). `@import`
goes on the `fn` declaration **inside** the extern block; placed before the block it
parses but does not rename the call sites.

An exported function keeps its declared C ABI: a `[]mut T` parameter stays the struct
`SliceMut__T` (`{ T *ptr; size_t len; }`) by value, as `[]T` stays `Slice__T`. Internally the
function's body is `<sym>__r`, which takes the view as `T *restrict` and a length; `<sym>` is a
one-call entry into it. C code that calls `<sym>` must pass a view no other argument or global
reaches while the call runs, as for a `&mut` parameter.

A fixed-array value parameter of an exported function is `T const name[N]` in C and the body
copies it on entry. A C prototype `T a[N]` has the same ABI. C code that declares the function or
stores its address must spell the parameter `T const *` (or `T const [N]`): `T *` is a different
parameter type (C11 6.7.6.3p15). Header-less `extern "C"` prototypes spell such a parameter
`T const [N]`. A call of an `extern "C"` function that takes a fixed array goes to a generated
wrapper (`__sc_blk_<module>__<name>`, the `@blocking` wrapper's name and place) that copies the
array into a local of its own and calls the C function with the copy, because the C callee may write
through its pointer. A use of such a function as a value (`let p: fn([i32; 4]) i32 = f;`) names the
wrapper, so a call through the value copies too.

## Pointers to Arrays

A pointer to an array whose element is a Super-C aggregate (`*const [S; 2]`) is a pointer to
the array's wrapper struct in the generated C (`const S__a2 *`, `struct S__a2 { S e[2]; }`): same
address, size, alignment and layout as C's `const S (*)[2]`. A call to an `extern "C"` function
converts such an argument and result through `void *`, so a header that declares the C pointer
type accepts it. An `@export` function keeps the wrapper pointer in its definition: C code
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
one `@unsafe(...)`. These two claims apply only to a function in an `extern "C"` block; the
placement claims `link_section` and `naked` apply only outside one (`super-c-language`, Unsafe
Placement).

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

A C intrinsic with an immediate operand (`_mm_shuffle_epi32(a, imm)`, `vextq_s8(a, b, n)`) is not
`safe` either: the C compiler rejects a non-constant or out-of-range operand, which Super-C cannot
check at the binding. The bindings in `ffi/immintrin.spc` and `ffi/arm_neon.spc` leave such
functions unsafe; a safe wrapper takes the operand as a const parameter and checks its range with
`static_assert` (`std::simd::x86::clmul::<IMM>`, `std::simd::aarch64::xar::<N>`).

A native build expands the intrinsics of `ffi/arm_neon.spc`, `ffi/immintrin.spc` and
`ffi/wasm_simd128.spc` in place of their calls, no C compile involved (super-c-compiler-internals,
"Native backend"). The immediate operand must then be a constant after constant folding; a call
whose immediate is not sends its module through C. A binding added to those files needs its
template: regenerate the tables with `scripts/intrin/`.

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
| `@link("lib")` | extern block | Declare a link flag |
| `@export("sym")` | function | Pin exact C symbol (external linkage) |
| `@import("sym")` | extern fn, extern type, header type field | Import with exact C symbol; the C spelling of an extern type; the C member of a field |
| `@unsafe(safe, const)` | extern fn | Claims, any order: `safe` = callable without `unsafe`, `const` = body is the compile-time model |
| `@value(size, align)` | opaque extern type | A C register type of that layout (Register types above) |
| `@layout(size, align)` | opaque extern type | A C value of that exact layout, checked in C (C values above) |
| `@thread_local` | `static mut`, extern `static mut` | One object per OS thread (Macro Objects and Thread-Locals above) |
| `@reads(p, n)` / `@writes(p, n)` | extern fn | Reads or writes only `n` bytes through pointer parameter `p` (Memory Annotations above) |
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
ones. The headers see the build's C environment (`push_c_env`): the `cstd` of the nearest
`build.toml` at or above the working directory (the default without one), `-funsigned-char` and,
for Windows, `-D_WIN32_WINNT=0x0A00`, so the output declares what the generated C compiles
against. `--cflag=` applies after them and takes only `-std=`, `-D`, `-U`, `-fsigned-char` and `-funsigned-char`; any other flag is an
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

The build compiles C with `-std=c11 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700` (the `cstd`
value: POSIX 2008 with the XSI extension, which declares `realpath` on glibc and wasi-libc), plus
`-funsigned-char -ffp-contract=off -Werror=incompatible-pointer-types` and the libm
`-fno-builtin-<f>` set (`LIBM_AS_WRITTEN` in `src/build_system/build.spc`: `sin(x)` is a libm
call, never a constant fold or a `sincos`) on every compile. A
Windows compile also gets `-D_WIN32_WINNT=0x0A00` (`push_c_env` in `src/driver/util.spc`):
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

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Passing `str` to C `%s` | Use `%.*s` with `.len()` + `.ptr()` (`str` has no `.cstr()`) |
| Missing `unsafe` on extern call | Add `unsafe` prefix or block |
| Repeating `@link` in every importing module | Declare it once on the binding module |
| Using `void` for opaque types | Use `type X;` (with its defining header): renders as the real C name |
| Assuming `String::ptr()` is NUL-terminated | It is not. Use `String::cstr()` |
| Passing a `str`'s `.ptr()` to a C path parameter | Use `.cstr()`, or `std::platform::path::native` inside std; a heap string whose allocation equals its length has no NUL after it, so failures depend on the length |
| Inventing an opaque type name (`type CFile;`) | The name must be a real C type a header defines |
| Mirroring a C struct as a Super-C `struct` | Declare it in the header's extern block: a header type uses the C layout and checks its fields |
| A typedef'd header type declared as `struct pthread_attr_t {}` | That spells `struct pthread_attr_t`: add `@import("pthread_attr_t")` |
| `@import` before the extern block | Put it on the `fn` inside the block |
