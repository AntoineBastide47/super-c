# Functions at the Boundary

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
`@lane_access` marks a function that touches memory lane by lane at lane-dependent addresses: the
effect query treats its access as unknown; it states no range, so it takes no `@reads` or `@writes`. The three
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
`safe` either: the operand must be a constant in range, which Super-C cannot check at the
binding. The bindings in `ffi/immintrin.spc` and `ffi/arm_neon.spc` leave such
functions unsafe; a safe wrapper takes the operand as a const parameter and checks its range with
`static_assert` (`std::simd::x86::clmul::<IMM>`, `std::simd::aarch64::xar::<N>`).

A native build expands the intrinsics of `ffi/arm_neon.spc`, `ffi/immintrin.spc` and
`ffi/wasm_simd128.spc` in place of their calls, no C compile involved (super-c-compiler-internals,
"Native backend"). The immediate operand must then be a constant after constant folding; a call
whose immediate is not fails the build. A binding added to those files needs its
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
