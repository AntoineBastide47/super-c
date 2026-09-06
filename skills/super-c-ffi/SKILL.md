---
name: super-c-ffi
description: "Covers C interop in Super-C: extern blocks, header bindings, opaque types, variadics, @c.source/@c.link, the ffi/ convention, str vs NUL-terminated strings, unsafe discipline at FFI boundaries, and the bindgen tool. Use when writing C bindings, integrating external libraries, or debugging FFI issues."
allowed-tools: Bash Read
---

# Super-C C FFI

## Agent checklist

- Confirm the C symbol, header, ownership, and string termination contract.
- Keep every extern call inside an explicit `unsafe` boundary.
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

- Extern names match the C symbol exactly — never module-mangled. The same applies to an
  opaque `type`: it renders as its bare C name, so it must name a type some included
  header actually defines (`FILE` works headerless because `stdio.h` is auto-included;
  an invented name fails in the C compile).
- `pub` inside an extern block exports the binding cross-module.
- Calling any extern binding requires `unsafe` at the call site.

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
with one absolute `#include`, preceded by `#define SC_RT_LK_STATS 1`: the runtime API
level of the compiler that wrote the wrapper, which `ffi/sc_rt.c` tests to compile
stand-ins for runtime entry points an older bootstrap runtime lacks (plain definitions;
weak symbols do not resolve across objects on PE). Relative includes in the backing source
continue to resolve correctly.

### Link flags

```superc
@c.link("m")                     // -lm
@c.link("-framework CoreFoundation")  // value starting with - passes through verbatim
extern "C" {
    fn sqrt(x: f64) f64;
}
```

Link flags are written to `build/__ldflags` (one per line). Libraries declare their flag
once where the binding lives — importers never repeat it. Flags apply automatically to
`--test` builds.

## Opaque Types

```superc
extern "C" "dirent.h" {
    pub type DIR;                // C struct known only by pointer
}
```

Opaque types lower to `TYPE_OPAQUE` and render as their bare C name (not `void`), so the
declaring block must include the header that defines the name — an opaque type used
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
binding does not need `mut` (the lint flags it). Do not name such a helper `format` —
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

## str vs NUL-Terminated Strings

**`str` is NOT NUL-terminated.** `str` and `String::as_str()` are `{ptr, len}` views.

| Operation | Correct | Wrong |
|-----------|---------|-------|
| Pass to C `%s` | `%.*s` with `.len()`, `.ptr()` | `%s` with `.ptr()` (buffer overread) |
| Pass to C API expecting `const char*` | `String::cstr()` (writes trailing NUL) | `.ptr()` (no NUL) |
| Build from C string | `str::from_cstr(p)` | Direct cast |

`.cstr()` exists only on `String` and takes `&mut self` — a `str` view has no `cstr`;
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
goes on the `fn` declaration **inside** the extern block — placed before the block it
parses but does not rename the call sites.

## Unsafe Discipline at FFI Boundaries

Every `extern "C"` call requires `unsafe`:

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

## Attributes Summary

| Attribute | Scope | Effect |
|-----------|-------|--------|
| `@c.source("file.c")` | extern block | Name a backing C implementation |
| `@c.link("lib")` | extern block | Declare a link flag |
| `@c.export("sym")` | function | Pin exact C symbol (external linkage) |
| `@c.import("sym")` | extern fn | Import with exact C symbol |

## bindgen

```sh
super-c bindgen header.h -o out.spc     # --link=, --header=, -I, --from=, --cflag=, --cc=
```

Generates `.spc` bindings from C headers (`src/bindgen/bindgen.spc`). Use it for large C
APIs where hand-writing bindings is impractical. The generated output follows the `ffi/`
conventions.

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| Passing `str` to C `%s` | Use `%.*s` with `.len()` + `.ptr()` (`str` has no `.cstr()`) |
| Missing `unsafe` on extern call | Add `unsafe` prefix or block |
| Repeating `@c.link` in every importing module | Declare it once on the binding module |
| Using `void` for opaque types | Use `type X;` (with its defining header) — renders as the real C name |
| Assuming `String::ptr()` is NUL-terminated | It is not. Use `String::cstr()` |
| Inventing an opaque type name (`type CFile;`) | The name must be a real C type a header defines |
| `@c.import` before the extern block | Put it on the `fn` inside the block |
