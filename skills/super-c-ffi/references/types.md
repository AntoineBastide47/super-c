# C Types

## Opaque Types

```superc
extern "C" "dirent.h" {
    pub type DIR;                // C struct known only by pointer
}
```

Opaque types lower to `TYPE_OPAQUE` and render as their bare C name (not `void`), so the
declaring block must include the header that defines the name: an opaque type used
without its header fails when the `--emit-c` tree compiles. An opaque type has no layout: it is valid only as the
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
fails the build with the reason, except on Windows x64, which passes every aggregate by its size.

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
read the layout; the build checks it against the header (`check_type`: the size the header's, the
alignment at least the header's). It may be a local, a parameter or a result, never storage: a struct field, an
array or slice element, a variant payload, a static or const, a pointer or reference target, a
closure capture, or a generic argument, written or inferred, is "`v128_t` is a register type;
store it through `Simd<T, N>`". It moves to and from a vector through memory
(`wasm_v128_load`, `wasm_v128_store`).

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
layout from the declaration by the C rules, and the build checks it against the header's
(`check_agg` in `src/driver/emit.spc`: the size, the alignment, and each member's offset and type;
"field 'stat.st_size' must sit at byte N in C, but sys/stat.h puts it at byte M: declare every
member of the header's type, in its order"). An extern `enum` is a header type too: the header
defines the type and its constants, which the emitted C names as the header does (`RED`), and the
build checks each enumerator's value against the header's. The
block must name the header ("a struct of an 'extern \"C\"' block is its C header's type: the
block needs that header"): Super-C cannot see which headers define a type, and a type of the
standard headers the runtime includes is declared under its header too (`extern "C" "time.h" {
struct tm { .. } }`). Read each member from the target's real headers (`clang -Xclang
-fdump-record-layouts` prints them): a guessed layout fails the build on that target.

- **Spelling.** `struct X`, `union X` and `enum X` are the C tag. `@import("name")` pins another
  spelling: a typedef name (`pthread_attr_t`, `div_t`, a `typedef enum { .. } mode;`), or MSVC's
  `struct _stat`. A typedef'd type declared without its pin spells a tag C does not define, and the
  build stops ("'tm' must be a complete C type, but time.h does not define it").
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

## Field Order

Super-C orders the fields of a struct, a tuple and an enum payload by alignment, largest first
(super-c-language, `references/types.md`, "Struct Layout"). C reads fields at their declared
offsets, so these keep the declared order:

- header types, unions and `@packed` structs;
- every struct and enum that the signature of an `extern "C"` function or an `@export` function
  reaches by value or through a pointer, a reference, a slice, an array, a function type, a tuple, a
  type alias or a generic argument, with the types of their fields and payloads;
- every struct and enum an argument of an `extern "C"` call points to when the parameter is a pointer
  (`*void`, `**void`, or a pointer a cast argument hides the struct behind) or the argument is a C
  variadic one, with the types of their fields and payloads. The compiler looks through casts and
  `unsafe` to the argument's pointer or reference type;
- `@ordered` structs.

A type of a module the std prelude loads keeps the layout the prelude gives it: user code does not
change it.

```superc
struct Req { pub flags: u8, pub len: u32, pub addr: u64 }
extern "C" { fn dev_submit(fd: i32, arg: *mut void) i32; }
unsafe dev_submit(fd, &mut r);            // Req keeps flags @0, len @4, addr @8
```

A reference or pointer converts to `*void` implicitly; a reference does not cast to `*mut void`
directly ("cast to '*mut Req' first"). The compiler does not follow an untyped pointer stored in a
variable or passed through a Super-C function first, and does not resolve a type parameter (a generic
wrapper's `T`): tag such a type `@ordered`, or declare it in its header's extern block when a C header
defines it. The same holds for a struct written as bytes (a file, a socket) and for memory read as
another type: use `@packed` for a wire format, `@ordered` for a shared prefix. A pointer C only stores
and gives back to Super-C (a callback context) needs nothing.

Marks from call arguments are known only when the typecheck ends. If a compile-time evaluation (a
`static_assert`, a constant, `sizeof` in an array length) already used the reordered layout, and the
declared order changes what it read (the size, or a field offset), the build fails: "'Req' reaches C
through a pointer argument, so its fields keep their declared order, but a compile-time
evaluation already used its reordered layout: tag it '@ordered'".

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
name. The build checks the header's macro or enumerator against it (`check_const`: "constant
'O_CREAT' must be 512 in C, but fcntl.h gives N"); a value the preprocessor does not evaluate (a
cast to a pointer) is not checked.
`@import("NAME")` checks another C name. The type is an integer or `bool` ("a constant of an
'extern \"C\"' block with a value is an integer or a 'bool': the C compile checks it"), and the
block needs its header ("a constant with a value of an 'extern \"C\"' block is checked against its
C header: the block needs that header"). A constant without a value is the C name itself, read at
run time. An extern `static mut` takes no value. Its block's header declares it; one of a block
without a header is declared by every unit that uses it (`extern T name;`), as a header-less
function gets its prototype.

A native build (super-c-compiler-internals, "Native backend") reads the value of a constant
without a value from its header with the compiler's own preprocessor, so the object holds it and
an edit of the header rebuilds the object. A constant whose expansion names an `extern` object the
header declares (`extern const int limit;`) reads that object, and its type must have the object's
("constant 'limit' must be a signed integer of 8 bytes in C, but \"lib.h\" declares a signed integer
of 4 bytes"). A constant that is neither, and a call of a function the header defines `static` (no
object exports it), fail the build (a constant: "module 'm' does not compile: a function `f` reads a
C header's constant: `__sc_x_NAME`").

A call of an extern declaration's function goes through the procedure linkage table on ELF (the
function may be in a shared library); under `-fno-plt` it loads the address from the function's GOT
slot, which the loader fills at start (x86-64 `call *f@GOTPCREL(%rip)`, arm64 `adrp`/`ldr`/`blr`),
and the own x86-64 linker turns a call of a function the output defines into a direct call. Mach-O,
COFF and wasm ignore the flag.

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

## Pointers to Arrays

A pointer to an array whose element is a Super-C aggregate (`*const [S; 2]`) is a pointer to
the array's wrapper struct in the generated C (`const S__a2 *`, `struct S__a2 { S e[2]; }`): same
address, size, alignment and layout as C's `const S (*)[2]`. A call to an `extern "C"` function
converts such an argument and result through `void *`, so a header that declares the C pointer
type accepts it. An `@export` function keeps the wrapper pointer in its definition: C code
may declare it with `const S (*)[2]`, an ABI-identical but distinct C type (as a pointer
parameter of a shim prototype, which the generated C declares `const void *`). A pointer to an
array of scalars (`*const [i32; 2]`) is `int32_t (*)[2]`, with no qualifier on the element.
