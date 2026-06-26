# Super-C

Super-C is a small, statically-typed systems language that **compiles to readable C**. It pairs a
modern, frontend containing features I liked from multiple different programming languages I have encountered (generics, enums with payloads, pattern matching, closures, modules, )
with C's portability and performance model — the compiler lowers everything to ordinary C99/C11 that Clang, GCC, or MSVC then turns into a native binary.

Super-C is not a C dialect. It is its own language that uses C as a compilation target.

## Pipeline

```text
Super-C source (.spc)
    -> lexer        (UTF-8, packed tokens)
    -> parser       (LL(1)-friendly, flat AST arena)
    -> resolver     (name binding, scopes, modules)
    -> typechecker  (type inference, generics, monomorphization)
    -> codegen      (readable C: build/ tree of .h/.c)
    -> cc / clang / gcc
    -> native binary
```

## Quick start

```sh
make                      # build the compiler -> ./super-c
./super-c path/to/app.spc # emit C into  path/to/build/
cc path/to/build/**/*.c -o app   # compile the generated C (no -I needed; includes are relative)
./app
```

Run with no arguments for a REPL that compiles one line at a time:

```sh
./super-c
> fn main() i32 { return 21 + 21; }
```

The `std/` prelude (`String`, `str`, `Box`, `Option`, `Result`, `Vector`, slices) is auto-imported, so
those types are in scope without any `import`.

## Language tour

### Bindings and functions

```superc
fn add(a, b: i32) i32 {
    return a + b;
}

fn main() i32 {
    let x: i32 = 10;     // explicit type
    let y = add(x, 20);  // inferred
    let mut sum = 0;     // mutable binding
    for i in 0..=y { sum = sum + i; }
    return sum % 256;
}
```

Builtin scalar types: `bool`, `char`, `i8 i16 i32 i64 isize`, `u8 u16 u32 u64 usize`, `f32`, `f64`,
`c32`, `c64` (C `_Complex`), `void`. (`main` must be `fn main() i32`.) `while`, `for`, and `do { .. }
while (cond);` loops are all available.

### Multiple return values

```superc
fn divmod(a, b: i32) (i32, i32) {
    return a / b, a % b;
}

fn main() i32 {
    let (q, r) = divmod(17, 5);   // tuple destructuring
    return q * 10 + r;            // 32
}
```

### Structs, methods, and visibility

```superc
struct Counter { pub n: i32 }    // fields are private by default; `pub` exposes them

extend Counter {
    fn get(self: &Counter) i32 { return self.n; }
    fn bump(self: &mut Counter) { self.n = self.n + 1; }
}

fn main() i32 {
    let mut c = Counter { n: 0 };
    c.bump();
    c.bump();
    return c.get();   // 2
}
```

### Enums and pattern matching

```superc
enum Shape {
    Circle(i32),
    Rect { w: i32, h: i32 },
    Unit,
}

fn area(s: Shape) i32 {
    return switch s {
        Circle(r)     => r * r * 3,
        Rect { w, h } => w * h,
        Unit          => 0,
    };
}

fn classify(n: i32) i32 {
    return switch n {
        0          => 0,
        1 | 2 | 3  => 1,    // or-pattern: any alternative matches
        4..=9      => 1,
        n if n < 0 => -1,   // guards can use the bound value
        _          => 2,
    };
}
```

`switch` is exhaustive and usable as an expression. Arms may combine alternatives with `|` (literals,
ranges, or variants). Payload-less enums lower to plain C `enum`s; payload-bearing ones lower to tagged
unions.

### Generics (monomorphized)

```superc
fn id<T>(x: T) T { return x; }

struct Pair<A, B> { pub a: A, pub b: B }

fn main() i32 {
    let p = Pair::<i32, bool> { a: id(41), b: true };
    return p.a + 1;   // 42
}
```

Generic functions, structs, enums, and methods (including methods with their own type parameters, e.g.
`map<U>`) are specialized per instantiation, across module boundaries.

### Closures and function pointers

```superc
fn apply(f: fn(i32) i32, x: i32) i32 { return f(x); }

fn main() i32 {
    let g = |x: i32| x * 2;                       // compact closure
    let h = fn(x: i32) i32 { return x + 1; };     // anonymous function
    return apply(g, 20) + apply(h, 0);            // 41
}
```

Closures are non-capturing (Stage 1): they lower to hoisted static C functions and plain function
pointers — no hidden environment or allocation.

### Memory: pointers, references, `new`

```superc
fn main() i32 {
    let p = new i32(41);     // heap-allocated *mut i32
    *p = *p + 1;
    let r: &i32 = p;         // reference (&T -> const T*, &mut T -> T*)
    return *r;               // 42
}
```

`*const T` / `*mut T` are raw pointers; `&T` / `&mut T` are references. `new T(expr)` and `new T { .. }`
allocate; `sizeof(T)` gives the byte size.

### Deferred cleanup

```superc
extern "C" { fn free(p: *mut void) void; }

fn main() i32 {
    let p = new i32(42);
    defer free(p as *mut void);   // runs at scope exit, even on an early return
    return *p;                    // the value is read before the defer runs
}
```

`defer` runs its statement when the enclosing block exits — on fall-through, `return`, `break`, or
`continue` — in last-in-first-out order. On a `return`, the return value is evaluated first, then the
deferred statements run.

### Slices and arrays

```superc
fn sum(xs: []i32) i32 {              // []T is a (ptr, len) fat-pointer view
    let mut t = 0;
    for x in xs { t = t + x; }
    return t;
}

fn main() i32 {
    let a: [i32; 4] = [10, 20, 30, 40];
    let t: [i32; 128] = [['a'] = 1, ['z'] = 2];   // designated (sparse) initializers
    return a[0] + a[3] + t['a'];
}
```

### The standard prelude

```superc
fn main() i32 {
    let mut v = Vector::<i32>::new();
    v.push(1); v.push(2); v.push(3);

    let mut s = String::from_str("hi");
    s.push_str("!");
    s.println();
    s.drop();

    let o = Option::<i32>::some(v.len() as i32);
    return o.unwrap_or(0);   // 3
}
```

`Box<T>`, `Option<T>`, `Result<T, E>`, `Vector<T>`, `String`, and `str` ship in `std/` and are
auto-imported.

### Modules

A project is a tree of `.spc` files. `import` pulls another module in; `pub` controls what crosses the
boundary.

```superc
// geom.spc
pub struct Point { pub x: i32, pub y: i32 }
pub fn manhattan(p: Point) i32 { return p.x + p.y; }
```

```superc
// app.spc
import geom;

fn main() i32 {
    let p = geom::Point { x: 3, y: 4 };
    return geom::manhattan(p);   // 7
}
```

`import P as Q;` aliases a module and `import P as *;` brings its public items into scope unqualified.

### C interop (FFI)

```superc
extern "C" {
    type CFile;
    fn fopen(path: *const char, mode: *const char) *mut CFile;
    fn fclose(file: *mut CFile) i32;
}
```

`extern "C"` declarations bind directly to C symbols with no wrapper or mangling, so existing C
libraries can be used as-is. `extern "C" "header.h" { .. }` emits the matching `#include`.

Variadics work in both directions. A binding can take `...`:

```superc
extern "C" { fn printf(fmt: *const char, ...) i32; }
```

and a Super-C function can *define* one, reading its arguments with the `va_list` type and the
`va_start` / `va_arg(ap, T)` / `va_end` intrinsics:

```superc
extern "C" { fn vsnprintf(buf: *mut char, n: usize, fmt: *const char, ap: va_list) i32; }

fn format(buf: *mut char, n: usize, fmt: *const char, ...) i32 {
    let mut ap: va_list;
    va_start(ap, fmt);
    let written = vsnprintf(buf, n, fmt, ap);
    va_end(ap);
    return written;
}
```

### Attributes

`@c.*` attributes annotate an item (before any `pub`) and lower to portable C keywords or GNU
`__attribute__`s:

```superc
@c.noreturn
fn panic() void { /* ... */ }

@c.packed
struct Header { pub magic: u32, pub version: u16 }

@c.align(64)
struct CacheLine { pub data: [u8; 64] }

@c.export("superc_init")     // pin the exact C symbol (no module mangling)
pub fn init() i32 { return 0; }
```

Supported: `inline`, `always_inline`, `noinline`, `noreturn`, `align(N)`, `packed`, `export("sym")`,
`import("sym")`, `section("s")`, `used`, `unused`. `export`/`import` set a function's exact C symbol at
both its definition and every call site.

### Compile-time assertions

```superc
struct Header { magic: u32, version: u16 }
static_assert(sizeof(Header) == 8, "Header must stay 8 bytes");
```

`static_assert(cond, "msg")` is valid at item or statement scope and lowers to C `_Static_assert`, so
the C compiler evaluates it.

## Generated output

`./super-c app.spc` writes a `build/` tree next to the source that mirrors the module paths:

```text
build/
  super_rt.h        # shared runtime (C standard-library includes)
  app.h  app.c      # one .h/.c per module
  __std/            # the prelude modules
    string.h string.c  option.h option.c  ...
```

Includes are relative, so the whole tree builds with `cc build/**/*.c` and no `-I` flags. Symbols are
module-mangled only when more than one user module is present, so single-file programs emit plain C
names. The output is meant to be read.

## Project layout

```text
src/
  lexer/        token scanning
  ast/          parser + flat AST arena
  resolver/     name resolution and scopes
  typechecker/  type inference, generics, monomorphization
  codegen/      C emission
  module/       package loader / imports / prelude
  types/        generic vector + hashmap containers
  utils/        diagnostics (rustc-style), attributes
std/            the auto-imported prelude
tests/          unit + compile-and-run tests
benchmark/      per-stage microbenchmarks
examples/       sample programs
```

## Building and testing

```sh
make             # dev build (ASan/UBSan) -> ./super-c
make release     # optimized build (-O3 -flto)
make test        # run the full test suite
make bench       # run the benchmarks
```

## Status and roadmap

Implemented and working: the full lexer→parser→resolver→typechecker→codegen pipeline, type inference,
structs/methods/visibility, enums with payloads and pattern matching (including or-patterns and
guards), untagged `union`s, monomorphized generics (functions, structs, enums, methods — same- and
cross-module), interfaces with enforced generic bounds and method dispatch, non-capturing closures and
function pointers, references/pointers/`new`, slices and arrays (including designated initializers),
multi-return + tuple destructuring, `while` / `for` / `do`-`while`, `defer`, `static_assert`, `@c.*`
attributes, the module system with an auto-imported `std` prelude, `extern "C"` FFI (custom header
includes, variadics in both directions via `va_list`, `_Complex`), and `sizeof`.

Planned / not yet implemented:

* RAII-style automatic cleanup (a `Drop` trait invoked at scope exit; `defer` is the manual form today)
* move/borrow analysis and double-drop prevention
* capturing closures
* the `?` early-return operator
* operator overloading via traits
* dynamic dispatch / trait objects — **TBD / undecided**: heterogeneous collections + open extension
  across modules.
