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

`ffi/sc_cpu.{spc,h,c}` is the example of per-OS C behind one interface: the CPU feature
detector selects its query with the preprocessor (`sysctlbyname` on Apple, `getauxval` on Linux
and Android, `IsProcessorFeaturePresent` on Windows, none elsewhere), names the OS constants
older headers lack by their documented values, treats a failing query as "absent", and reaches
the build's own set through the C compiler's `__ARM_FEATURE_*` macros. A C constructor runs it
before `main`; atomics with acquire and release publish the answer, so two first callers store
equal words with no lock. Every program that loads the binding module compiles the `.c`, so a
prelude module never imports it: `std::cpu::detect`, a module a program imports, does.

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
bootstrap release and a binary built from the previous commit both still link the new
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
the C type is a scalar. No type of an extern block (an opaque type, a header type, an extern
`enum`) implements `Free`: it is a C value that copies, so its glue would never be the one owner's
("'clock_t' is a type of an 'extern \"C\"' block: it cannot implement 'Free'"). Wrap it in a
struct that implements `Free` (`stdio::File` holds a `*mut FILE`).

### Register types: `@c.value(size, align)`

```superc
extern "C" "wasm_simd128.h" {
    @c.value(16, 16)
    pub type v128_t;             // a C vector register type, passed by value
}
```

`@c.value` gives an opaque type of an `extern "C"` block a layout: `size` a nonzero multiple of
`align`, both constant expressions of type `usize` ("'@c.value' needs a nonzero size that is a
multiple of the alignment"; on any other declaration "'@c.value' may only be applied to an
opaque type ('type T;') in an 'extern \"C\"' block"). The type is `Copy` and `sizeof`/`alignof`
read the layout; a `_Static_assert` beside the block's header include checks it against C. It may be a local, a parameter or a result, never storage: a struct field, an
array or slice element, a variant payload, a static or const, a pointer or reference target, a
closure capture, or a generic argument, written or inferred, is "`v128_t` is a register type;
store it through `Simd<T, N>`". It moves to and from a vector through memory
(`wasm_v128_load`, `wasm_v128_store`), which the C compiler keeps in registers.

## Header Types

```superc
extern "C" "sys/stat.h" {
    @platform(linux | wasm)
    pub struct stat { pub st_mode: u32, pub st_size: i64 }   // C `struct stat`
    @platform(macos | ios)
    pub struct stat { pub st_mode: u16, pub st_size: i64 }
    pub fn stat(path: *const char, buf: *mut stat) i32;
}

extern "C" "pthread.h" {
    @c.import("pthread_attr_t")                                 // a typedef name
    pub struct pthread_attr_t {}
}
```

A `struct` or `union` of an `extern "C"` block is a header type: its C header defines it and owns
its layout. Super-C emits no definition and no layout of its own. An extern `enum` is a header type
too: the header defines the type and its constants, which the emitted C names as the header does
(`RED`), and its layout check (`sizeof == 4`) stays. The block must name the header
("a struct of an 'extern \"C\"' block is its C header's type: the block needs that header"):
Super-C cannot see which headers define a type, and a type of the standard headers the runtime
includes is declared under its header too (`extern "C" "time.h" { struct tm { .. } }`).

- **Spelling.** `struct X`, `union X` and `enum X` are the C tag. `@c.import("name")` pins another
  spelling: a typedef name (`pthread_attr_t`, `div_t`, a `typedef enum { .. } mode;`), or MSVC's
  `struct _stat`. A typedef'd type declared without its pin spells a tag C does not define, and the
  C compile stops at its completeness check (below).
- **Fields.** The declaration lists some of the header's members, in the header's order; Super-C
  never names the others. A field type is a C scalar, a raw pointer, a `fn` pointer, a type of an
  `extern "C"` block, or an array of these ("field 'f' of 'S' has type 'T', which has no C
  equivalent"). A member named by a Super-C keyword binds under another name with
  `@c.import("select") pub select_: i32` (on a header type's field only). A field named by a C
  keyword or a standard-header macro (`errno`) gets a `_` suffix like every Super-C name: pin it
  the same way. An unknown field at a use is "no field 'f' on 'S'", with a note that the
  declaration lists the fields.
- **Checks.** The forward header (`__sc_fwd.h`, which every unit includes) holds, after every
  header include: `sizeof(T) != 0`; per field the member's kind and size (signedness by
  `_Generic` over the standard integer types, `_Bool`, `float`, `double`, the complex types, a
  pointer as no arithmetic type of a pointer's size, an extern type by exact type, an array by its
  length at each level and then its element); per two consecutive fields
  `offsetof(prev) + sizeof(prev) <= offsetof(next)`, and for a union each field at offset 0. A
  wrong declaration stops the C compile: "super-c: field 'stat.st_mode' must be an unsigned
  integer of 4 bytes in C"; a member the header lacks is a C error at its check. A header that
  does not define the type stops the C compile at the completeness check, the type's first use in
  every unit: C has no completeness test that does not stop the compile, so the first error is
  C's "incomplete type" on the line of "super-c: 'pt' must be a complete C type".
- **Layout.** Super-C knows no size, alignment or offset. A use whose size C computes is valid: a
  by-value local, parameter or result, a copy (the type is `Copy`), an array, a slice, `Vector`,
  `Option`, a field of a Super-C struct, a generic argument, `unsafe zeroed::<T>()`
  (`(struct stat){0}`), a struct literal (designated: every member it omits, listed or not, is
  zero), and run-time `sizeof`/`alignof` (`sizeof(struct stat)`). Compile-time evaluation holds a
  value field by field, so a `const` or `static mut` of the type works (designated static data). A
  compile-time size is an error: `const N = sizeof(stat)`, `static_assert`, an array length, a
  repeat count, `type_info` ("the size of 'stat' is its C header's: it has no compile-time
  value"). `@c.align`, `@c.packed` and `extend X as Free` are errors: the type has no drop glue.
- **Targets.** Gate a declaration with `@platform` where the members differ (`st_mode` is `u16`
  on macOS and Windows, `u32` on Linux and wasm; mingw's `st_size` is `i32`).

## Memory Annotations

```superc
extern "C" "wasm_simd128.h" {
    @c.reads(mem, 16)
    fn wasm_v128_load(mem: *const void) v128_t;
    @c.writes(mem, 16)
    fn wasm_v128_store(mem: *mut void, a: v128_t);
    @c.lane_access
    fn wasm_v128_load32_lane(mem: *const void, vec: v128_t, lane: i32) v128_t;
}
```

`@c.reads(p, bytes)` and `@c.writes(p, bytes)` state that the function reads or writes only
`bytes` bytes through raw pointer parameter `p` (`*mut` for a write) and has no other memory
effect; `bytes` is a `usize` constant or an expression over the function's other `usize`
parameters (`n * 4`; no call, no cast). A function may state both: the write is its effect.
`@c.lane_access` marks a function that touches memory lane by lane: a build under a memory
checker (`-fsanitize=` with `address`, `memory` or `thread`) never plans a vector entry that
calls one; it states no range, so it takes no `@c.reads` or `@c.writes`. The three
apply to a function of an `extern "C"` block or an `@intrinsic` function only, and do not
change the emitted C: the Core IR effect query (`ir::facts::call_access`) reads them, so a read
writes nothing and a write writes only through `p`. Errors: "'q' is not a parameter of this
function", "parameter 'n' of '@c.reads' must be a raw pointer", "parameter 'p' of '@c.writes'
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
  math.spc        # import math;    (@c.link("m") declared here)
  ...
```

The loader resolves `import X;` by searching: project root → `std/` → `ffi/X.spc`.
FFI modules include safe wrappers alongside raw bindings (e.g., `stdio` has an RAII
`File` type, `stdlib` has `get_env(name) Option<String>`, an owned copy, and `env_is(name, value)`).

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

An exported function keeps its declared C ABI: a `[]mut T` parameter stays the struct
`SliceMut__T` (`{ T *ptr; size_t len; }`) by value, as `[]T` stays `Slice__T`. Internally the
function's body is `<sym>__r`, which takes the view as `T *restrict` and a length; `<sym>` is a
one-call entry into it. C code that calls `<sym>` must pass a view no other argument or global
reaches while the call runs, as for a `&mut` parameter.

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
| `@c.import("sym")` | extern fn, extern type, header type field | Import with exact C symbol; the C spelling of an extern type; the C member of a field |
| `@unsafe(safe, const)` | extern fn | Claims, any order: `safe` = callable without `unsafe`, `const` = body is the compile-time model |
| `@c.value(size, align)` | opaque extern type | A C register type of that layout (Register types above) |
| `@c.reads(p, n)` / `@c.writes(p, n)` | extern fn | Reads or writes only `n` bytes through pointer parameter `p` (Memory Annotations above) |
| `@c.lane_access` | extern fn | Lane-by-lane memory access: no vector entry that calls it under a memory checker |

## bindgen

```sh
super-c bindgen header.h -o out.spc     # --link=, --header=, -I, --from=, --cflag=, --cc=
```

Generates `.spc` bindings from C headers (`src/bindgen/bindgen.spc`). Use it for large C
APIs where hand-writing bindings is impractical. The generated output follows the `ffi/`
conventions. A record whose every member has a field form becomes a header type with every
member, and a tagged enum an extern `enum`: a tagged record or enum spells as its tag, one that
only a typedef names pins that name, and a member named by a keyword pins its C name. Any other
record stays an opaque `pub type`.

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
`-funsigned-char -ffp-contract=off -Werror=incompatible-pointer-types` and the libm
`-fno-builtin-<f>` set (`LIBM_AS_WRITTEN` in `src/build_system/build.spc`: `sin(x)` in a
`@c.source` file is a libm call too, never a constant fold or a `sincos`) on every compile.

- macOS: strict `_POSIX_C_SOURCE` breaks `<sys/sysctl.h>` and hides `ru_maxrss`.
  src/driver_shim.c declares `sysctlbyname` locally and defines `_DARWIN_C_SOURCE` before
  its includes; std/testing/bench_sys.c defines `_DARWIN_C_SOURCE` too.
- Windows (mingw) fakes POSIX. `stat().st_ino` is 0, so a dev+ino identity test matches
  unrelated files (src/driver_shim.c uses `GetFileInformationByHandle`). Files and stdio
  default to text mode: CRLF breaks `\`-continued macros and byte framing, so open with
  `"wb"` and set stdio binary. `tmpfile()` writes to the drive root: use `GetTempPathA`
  (`%TEMP%`) and `fopen(.., "wb")`. There is no `open_memstream`.
- Arm SME keyword attributes (`__arm_new("za")`, `__arm_locally_streaming`) are C23 `[[arm::...]]`
  attributes under GCC 14: put them before any `__attribute__((...))` of the declaration, which
  otherwise makes GCC apply them to a type and reject them (ffi/sc_sme.c). Clang before 19 rejects
  SVE types in a function with SME and no SVE. Off Darwin, Clang saves VG for the unwinder of a
  function that changes streaming mode through `__arm_get_current_vg`, which libgcc lacks before
  GCC 16; from Clang 22, `__attribute__((nouwtable))` removes the call, and Clang 19 to 21 always make it.

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
| Mirroring a C struct as a Super-C `struct` | Declare it in the header's extern block: a header type uses the C layout and checks its fields |
| A typedef'd header type declared as `struct pthread_attr_t {}` | That spells `struct pthread_attr_t`: add `@c.import("pthread_attr_t")` |
| `@c.import` before the extern block | Put it on the `fn` inside the block |
