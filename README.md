# Super-C

Super-C is a small, statically-typed systems language that **compiles to readable C**. It pairs a
modern frontend — features I liked from other languages (generics, enums with payloads, pattern matching, closures, modules)
— with C's portability and performance model — the compiler lowers everything to ordinary C99/C11 that Clang, GCC, or MSVC then turns into a native binary.

Super-C is not a C dialect. It is its own language that uses C as a compilation target.

## Pipeline

```text
Super-C source (.spc)
    -> lexer        (UTF-8, packed tokens)
    -> parser       (context-free LL(1), left-factored operators, no predicates/backtracking; flat AST arena)
    -> resolver     (name binding, scopes, modules)
    -> typechecker  (type inference, generics, monomorphization, borrow checking)
    -> codegen      (readable C: build/ tree of .h/.c)
    -> cc / clang / gcc
    -> native binary
```

## Quick start

Grab a `super-c` binary from the GitHub Releases (it ships with `std/` and `ffi/`), then:

```sh
# build an app straight to a native binary
./super-c build path/to/app.spc -o app
./app

# or emit the readable C into path/to/build/ and compile it yourself
./super-c path/to/app.spc
cc path/to/build/**/*.c -o app
```

The `std/` prelude (`String`, `str`, `Option`, `Result`, `Vector`, `Map`, ...) is
auto-imported, so those types are in scope without any `import`.

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
    for i in 0..=y {
        sum = sum + i;
    }
    return sum % 256;
}
```

Builtin scalar types: `bool`, `char`, `i8 i16 i32 i64 isize`, `u8 u16 u32 u64 usize`, `f32 f64`,
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

### Tuples

```superc
fn swap(p: (i32, bool)) (bool, i32) {
    return p.1, p.0;
}

fn main() i32 {
    let t = (1, true);         // (i32, bool) — sugar for the prelude's Tuple2<i32, bool>
    let (b, n) = swap(t);      // destructure (works on tuple values and multi-return calls)
    let pair: (u8, u8) = (2, 3);
    return n + (b as i32) + (pair.0 as i32) + (pair.1 as i32) - 7;  // t.0 / t.1 read elements
}
```

Tuples are first-class values (2-4 elements): store them in fields, pass them to functions, put
them in containers (`Vector<(i32, bool)>`). Nested element access needs parens: `(t.0).1`.

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

### Loops, labels, and `let` conditionals

```superc
fn main() i32 {
    let mut v = Vector::<i32>::new();
    v.push(3); v.push(8); v.push(5);

    // `loop` is an expression: `break <value>` yields it
    let mut n = 0;
    let seed = loop {
        n += 1;
        if n * n > 20 { break n; }
    };

    // labels route break/continue through nested loops (defers still run, innermost first)
    let mut pairs = 0;
    'outer: for i in 0..4 {
        for j in 0..4 {
            if i + j == seed { break 'outer; }
            pairs += 1;
        }
    }

    // `while let` drains a source; `if let` tests one pattern
    let mut last_even = 0;
    while let Some(x) = v.pop() {
        if let 8 = x { last_even = x; }
        println("popped {:>4}", x); // right-aligned in 4 columns
    }

    return seed + pairs + last_even - 24; // 5 + 11 + 8 - 24 = 0
}
```

`if let P = e { .. } else { .. }` and `while let P = e { .. }` desugar to two-arm switches, so any
switch pattern (payloads, or-patterns, literals) works. Format placeholders accept
`{:[fill][<^>][0][width][.precision][x|X|b]}` — `{:08.2}` zero-pads a float to width 8 with 2
decimals, `{:b}` prints binary — and `eprint` / `eprintln` mirror `print` / `println` onto stderr.

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
fn apply(f: fn(i32) i32, x: i32) i32 { return f(x); }            // a plain function pointer

fn scale<F: fn(i32) i32>(x: i32, f: F) i32 { return f(x) * 2; }  // any function value, incl. captures

fn main() i32 {
    let g = |x: i32| x * 2;                       // compact closure
    let h = fn(x: i32) i32 { return x + 1; };     // anonymous function
    let k = 10;
    let add_k = |x: i32| x + k;                   // captures k BY COPY at this point
    return apply(g, 20) + apply(h, 0) + scale(5, add_k) + add_k(1) - 40; // 42
}
```

A non-capturing closure lowers to a hoisted static C function and a plain function pointer — no hidden
environment or allocation. A **capturing** closure copies the locals it uses into a per-closure
environment struct (its value IS that struct — still no allocation); it cannot be a bare `fn(..) ..`
pointer, but it satisfies an `F: fn(..) ..` generic bound (also spellable as `where F: fn(..) ..`),
which monomorphizes the function per closure and calls it directly. The std higher-order methods
(`Vector::map`/`find`/`retain`, `Option::map`/`and_then`/`filter`, `Result::map`/`map_err`/`and_then`,
`Box::map`) all take `F: fn(..) ..`, so they accept named functions, function pointers, and capturing
closures alike.

Captures come in three flavors, decided per variable by how the body uses it:

* **read** — captured by copy at creation (a later write to the original is invisible to the closure);
* **mutated** (`FnMut`-style) — a capture the body assigns to, `&mut`-borrows, or calls a `&mut self`
  method on becomes an implicit `&mut` capture: the env holds a pointer and writes land on the OUTER
  variable (`let mut n = 0; each(5, fn(x: i32) { n += x; });` leaves `n == 10`). The outer binding
  must be `mut`;
* **owned** (`FnOnce`-style) — capturing a destructor-owning (`Free`) value MOVES it into the env:
  the outer binding is spent, the closure value itself becomes `Free` (move-tracked; its env frees the
  value exactly once — at scope exit, or inside the generic that consumed it), and the body may use
  but not move the value out. An owning closure satisfies only the ownership-marked bound
  `F: fn move(..) ..` — under it the generic body move-tracks `f`, so passing it on twice is a
  use-after-move error, while *calling* it any number of times is fine (calls only borrow the env).

Capturing a fixed-size array by copy is rejected (capture a slice instead).

### Trait objects (`dyn`)

When the concrete type is a *runtime* choice — heterogeneous collections, plugin-style open
extension, closures stored in fields — a dyn-compatible interface can be dispatched dynamically:

```superc
interface Shape {
    fn area(self: &Self) i32;
    fn tag(self: &Self) i32 { return 0; }        // default bodies back vtable slots too
}
struct Circle { pub r: i32 }
struct Sq { pub s: i32 }
extend Circle as Shape { pub fn area(self: &Circle) i32 { return 3 * self.r * self.r; } }
extend Sq as Shape { pub fn area(self: &Sq) i32 { return self.s * self.s; } }

fn total(a: &dyn Shape, b: &dyn Shape) i32 { return a.area() + b.area(); }  // one fn, any Shapes

fn main() i32 {
    let mut v: Vector<Box<dyn Shape>> = Vector::<Box<dyn Shape>>::new();    // OWNED, mixed types
    v.push(Box::<Circle>::new(Circle { r: 1 }));
    v.push(Box::<Sq>::new(Sq { s: 2 }));
    let mut sum = 0;
    for i in 0..v.len() { sum = sum + v.at(i).area(); }                     // 3 + 4
    return sum;                                                             // elements auto-free
}
```

A `dyn` value is a 2-word fat pair `{data, vtable}` passed by value (the slice model — never a hidden
allocation). Three spellings: `&dyn I` (borrowed view), `&mut dyn I` (mutable view — required for
`&mut self` methods), and `Box<dyn I>` (owned: `Box<T>` moves in; the vtable's drop glue deep-frees
the pointee and releases the block, riding the same RAII/move analysis as everything else). `&T`
erases implicitly wherever `&dyn I` is expected when `T` implements `I`; one `static const` vtable
per (type, interface) is emitted in each using TU. Dyn-compatibility is checked with a reason: every
method takes `Self` by reference and mentions it nowhere else, no interface/method generics.

Closures get the same treatment — `dyn fn(..) ..` is a one-method trait object with **structural**
identity, unlocking heterogeneous handler lists and closure storage:

```superc
fn make_adder(k: i32) Box<dyn fn(i32) i32> { return |x: i32| x + k; }  // env moves to the heap

let mut on_event: Vector<Box<dyn fn(i32) i32>> = Vector::<Box<dyn fn(i32) i32>>::new();
on_event.push(make_adder(10));
on_event.push(double_it);              // a named fn erases too (no allocation)
let r = (*on_event.at(0))(5);          // 15 — dispatched through the vtable
```

A capturing closure is borrowed into a view (`&f` → `&dyn fn(..) ..`) or moved into a `Box<dyn fn>`
(its env is heap-copied; owning captures are deep-freed by the drop glue). Static dispatch through
`F: fn(..) ..` bounds stays the zero-cost default — `dyn` is the opt-in for the places
monomorphization cannot reach.

### Memory: pointers, references, `new`

```superc
fn main() i32 {
    let p = new i32(41);        // heap-allocated *mut i32
    unsafe { *p = *p + 1; }     // raw-pointer access must carry the `unsafe` marker
    let r: &i32 = unsafe &*p;   // reborrow the raw pointer as a reference (&T -> const T*)
    return *r;                  // 42 (reference operations need no unsafe)
}
```

`*const T` / `*mut T` are raw pointers; `&T` / `&mut T` are references. `new T(expr)` and `new T { .. }`
allocate; `sizeof(T)` and `alignof(T)` give the byte size and alignment.

Raw-pointer manipulation — dereference, indexing, arithmetic, field access through a pointer — and
every call to an `extern "C"` function must sit inside an `unsafe { ... }` block or be prefixed with
`unsafe`: the compiler cannot vouch for those operations, so the marker delimits exactly where its
guarantees stop. Pointer comparison and reference operations stay safe.

References are borrow-checked statically: a place admits many `&` or one `&mut` (overlap is
field-precise — `p.a` and `p.b` don't conflict), a place can't be read or moved while an overlapping
`&mut` is live, a stored borrow ends at its last use (non-lexical), and returning a reference that
traces to a local is rejected.

### Deferred cleanup

```superc
extern "C" { fn free(p: *mut void) void; }

fn main() i32 {
    let p = new i32(42);
    defer unsafe free(p as *mut void);   // runs at scope exit, even on an early return
    return unsafe *p;                    // the value is read before the defer runs
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

    let o = Option::<i32>::some(v.len() as i32);
    return o.unwrap_or(0);   // 3
}
```

`Box<T>`, `Option<T>`, `Result<T, E>`, `Vector<T>`, `Map<K, V>`, `Set<T>`, `String`, and `str` ship in
`std/` and are auto-imported, along with iterators and the algorithms built on them. `panic("msg")`
aborts with a message (no unwinding); `Option`/`Result` provide the panicking accessors `unwrap()` /
`expect(msg)` (+ `unwrap_err()`), and a `@c.noreturn` call types as `never`, so a panicking arm
unifies with value-producing siblings in a `switch` or `if`. The containers and
`String` are allocator-parameterized: implement the `Allocator` interface and pass it via the `*_in`
constructors (`new_in`, `with_capacity_in`, `from_str_in`).

Anything implementing `Iterator<T>` composes into lazy adapter pipelines — `map` / `filter` /
`enumerate` / `zip` build one, and `for x in ..`, `fold`, `for_each`, `count`, or `collect` drain it.
The closure's signature (or the source's conformance) pins the element types, so no turbofish is
needed; adapters are plain monomorphized structs holding the closure by value (no allocation,
direct calls):

```superc
let doubled_sum = fold(map(v.iter(), |x: &i32| *x * 2), 0, |a: i32, x: i32| a + x);
let odd = count(filter(v.iter(), |x: &i32| *x % 2 == 1));
for p in enumerate(v.iter()) { .. }   // p.0 = index, p.1 = &element
let picked: Vector<i32> = collect(map(v.iter(), |x: &i32| *x + 1));
```

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
Imports are public, C-style: a glob import of a facade module also exposes everything the facade
itself imports, and any transitively loaded module stays reachable by its qualified path (`b::foo()`)
without a direct import. Import cycles are legal — mutually-recursive modules (pointer-linked types,
mutually-recursive functions) resolve order-independently; only a mutual *by-value* embedding is
rejected (the type would have infinite size).

### C interop (FFI)

```superc
extern "C" {
    type CFile;
    fn fopen(path: *const char, mode: *const char) *mut CFile;
    fn fclose(file: *mut CFile) i32;
}
```

`extern "C"` declarations bind directly to C symbols with no wrapper or mangling, so existing C
libraries can be used as-is. `extern "C" "header.h" { .. }` emits the matching `#include`: a header
that exists relative to the declaring `.spc` file is rewritten to the right path from inside the
generated `build/` tree (you never reason about the build layout), anything else is included as
written (`<...>` for bare names). Calling any extern binding requires an `unsafe` block or prefix at
the call site.

Whole C sources and libraries come along automatically: a backing header that resolves next to the
`.spc` file pulls in its same-stem `.c` sibling with no ceremony —

```superc
extern "C" "native.h" {      // native.c beside it is discovered and compiled into the build
    fn native_mix(a: i32, b: i32) i32;
}
```

— while `@c.source("impl.c")` names an implementation that lives elsewhere, and `@c.link("m")`
declares a library (a value starting with `-` passes through verbatim). Each source becomes a
wrapper translation unit in `build/` (an absolute `#include`, so the file's own relative includes
keep resolving), meaning `cc build/**/*.c` picks everything up; paths resolve relative to the
declaring `.spc` file. Link flags are written to `build/__ldflags` (one per line —
`cc ... $(cat build/__ldflags)`) and applied automatically to `--test` builds. A library declares
its flag once where its bindings live — the bundled `math`/`pthread`/`dlfcn` ffi modules already
do, so importing them is all it takes.

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
    let written = unsafe vsnprintf(buf, n, fmt, ap);
    va_end(ap);
    return written;
}
```

### Attributes

`@c.*` attributes annotate an item (before any `pub`) and lower to portable C keywords or GNU
`__attribute__`s:

```superc
@c.noreturn
fn panic() { /* ... */ }

@c.packed
struct Header { pub magic: u32, pub version: u16 }

@c.align(64)
struct CacheLine { pub data: [u8; 64] }

@c.export("superc_init")     // pin the exact C symbol (no module mangling)
pub fn init() i32 { return 0; }
```

Supported: `inline`, `always_inline`, `noinline`, `noreturn`, `align(N)`, `packed`, `export("sym")`,
`import("sym")`, `section("s")`, `used`, `unused`. `export`/`import` set a function's exact C symbol at
both its definition and every call site. Bare `@emit_macro` on a generic struct or enum additionally
exports it as a reusable C macro for consumption from plain C.

### Testing

```superc
struct Fx { pub v: Vector<i32> }

@test_init
fn setup() Fx {                       // per-module fixture: built fresh for each test that asks
    let mut v = Vector::<i32>::new();
    v.push(1); v.push(2);
    return Fx { v: v };
}

@test
fn drains(fx: &mut Fx) {              // declare the parameter to receive the fixture
    let mut s = 0;
    while let Some(x) = fx.v.pop() { s += x; }
    assert_eq(s, 3);
}

@test(should_panic)
fn rejects_bad_input() { panic("boom"); }
```

```sh
./super-c --test app.spc                      # collect @test fns, build, run (fork-isolated, parallel)
./super-c --test --test-filter=drains app.spc # substring selection
./super-c --test --test-jobs=4 app.spc        # bound the process pool (default: one per core)
./super-c --test --test-no-fork app.spc       # in-process, for debuggers (should_panic is skipped)
```

Each test runs in a forked child, so a panic, a failed assertion, or a crash fails just that test —
and `@test(should_panic)` passes only when the body aborts. `@test_init` returns a fixture value the
test takes by parameter (torn down by the optional `@test_free`, then RAII); `@test_init(global)` /
`@test_free(global)` build a suite-wide env once in the parent, passed to tests as a shared `&` —
fork's copy-on-write makes cross-test mutation impossible by construction. `assert(cond[, "msg"])`,
`assert_eq(a, b)`, and `assert_ne(a, b)` are compiler builtins: a failure prints the expression's
source text, the left/right values, and its `file:line`, and the arguments are only read (asserting
on an owned `String` leaves it usable). In a normal (non-`--test`) build, test functions are not
emitted at all.

Tests can also be grouped as **method suites** on a type — the receiver *is* the fixture, produced
by a `@test_init` method in the same (non-generic, inherent) `extend`:

```superc
extend Counter {
    @test_init
    fn setup() Counter { return Counter { n: 0 }; }

    @test
    fn starts_at_zero(self: &Counter) { assert_eq(self.n, 0); }

    @test
    fn bump_increments(self: &mut Counter) { self.bump(); assert_eq(self.n, 1); }
}
```

Suite tests report as `module::Counter::starts_at_zero`, may take the global env as a second
parameter, and follow the same lifecycle (setup → test → `@test_free` method → RAII). A module may
host several suites (one per type), and a local extension of an imported type can define its own —
each module's suite uses its own `@test_init`.

### Compile-time assertions

```superc
struct Header { magic: u32, version: u16 }
static_assert(sizeof(Header) == 8, "Header must stay 8 bytes");
```

`static_assert(cond, "msg")` is valid at item or statement scope and lowers to C `_Static_assert`, so
the C compiler evaluates it.

### Compile-time evaluation

Always on. A constant evaluator, a layout engine (64-bit C data model), and a CTFE interpreter run
as part of every compile; two flags bound how much work a single compile-time evaluation may do
(exhausting a budget is never an error for plain functions -- the expression simply stays a runtime
one; `const fn` calls and const initializers are held to a stricter standard, below):

```sh
./super-c app.spc                                          # defaults: ~2M steps, ~96 MiB
./super-c --const-eval-steps=100000 --const-eval-memory=16M app.spc
```

* `static_assert` conditions that fold are decided by Super-C itself, with source spans —
  including `sizeof`/`alignof` over structs, enums, tuples, and generic instances. Unfoldable
  conditions (e.g. involving opaque `extern "C"` types or `va_list`) still lower to C
  `_Static_assert` as before.
* Array designator indices may be any constant expression (`[K] = v`, `[K + 1] = v`); non-constant
  indices become a Super-C error instead of invalid C. An array length that cannot be evaluated is
  likewise a named error ("array length must be a constant expression") instead of silently
  becoming length 0.
* Array lengths become part of the type — `[i32; 4]` and `[i32; 8]` are distinct — which makes
  fixed-size arrays legal as generic type arguments (`Wrap<[i32; 4]>` embeds the array by value).
  Passing bare arrays through the std containers is not supported; wrap them in a struct.
* Every layout the compiler computes is verified in the generated C by an emitted
  `_Static_assert(sizeof(T) == N, ...)`, so the downstream C compiler proves the layout model on
  the actual target — a mismatch is a named compile error, never silent.
* Implicit CTFE: a call whose arguments are compile-time constants is RUN
  by an interpreter — loops, recursion, structs, arrays, payload enums, generic methods, floats
  (including the libm externs), and even heap code (`malloc`/`realloc`/`free` are intercepted into
  an abstract compile-time heap, so a `Vector`-building function folds to its result). For a plain
  function anything unmodeled, or over budget, stays a runtime call. A `static_assert` may call
  functions defined anywhere (undecidable asserts are re-checked once the whole package has
  type-checked), and one that would trap reports the reason (`division by zero`, `use after
  free`, ...) together with the CTFE call stack and steps consumed.
* Diagnosed misuse: a constant-dependency cycle (`const A = B; const B = A;`) is reported as
  `cyclic constant dependency` instead of burning the step budget, and an emitted expression whose
  evaluation *proves* undefined behavior (division by zero, out-of-bounds access, use after free)
  fails the build even where folding is otherwise optional — a short-circuited `&&`/`||` operand
  that never executes is exempt.

### `const fn` and mandatory evaluation

```superc
const fn table_size(bits: u32) usize { return (1u32 << bits) as usize; }

fn evens(n: u32) Vector<u32> {                 // plain functions work too
    let mut v = Vector::<u32>::new();
    for i in 0..n { v.push(i * 2); }
    return v;
}

const N: usize = table_size(8);                // mandatory: must evaluate, or compile error
const V: Vector<u32> = evens(5);               // materialized as static C data (relocations included)
```

`const fn` marks a function as compile-time evaluable and is validated at the definition: a
`const fn` that certainly cannot evaluate (calls a non-intercepted extern, touches a `static mut`,
is variadic — directly or transitively) is a compile error naming the disqualifier. Calls through
function values, dyn, or generic bounds are permitted at the definition and enforced where they are
used. A `const fn` is still a normal C function at runtime.

The strictness rules:

* A call to a `const fn` whose arguments are compile-time known MUST evaluate — any failure
  (unsupported operation, budget exhaustion, trap) is a compile error, in every context. Only
  plain (non-`const`) functions keep the silent runtime fallback.
* A const declaration whose initializer contains a call must evaluate at compile time; failure is
  an error carrying the trap reason and CTFE call stack. Call-free initializers keep best-effort
  folding (they are already valid C constant expressions). Local consts inside generic functions
  are exempt until instantiation.
* Aggregate results materialize: structs, arrays, strings, `Vector`s, shared and even cyclic
  pointer graphs built at compile time are emitted as deterministic `static const` C data, with
  auxiliary objects (`NAME__ct0`, ...) and pointer relocations. A const that points at freed
  compile-time memory is rejected.

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
./super-c build                     # two-stage dev self-build (ASan/UBSan) -> ./super-c
./super-c build --profile=release   # optimized build (-O3 -flto)
./super-c test                      # run the full test suite (tests/ by convention)
./super-c bench                     # run the benchmarks (bench/ by convention)
./super-c clean                     # drop build outputs
```

The build is driven by `build.toml` and works for any project, not just the compiler: declare
`bin` and `root`, and `super-c build` gives you profiles (`debug`/`dev`/`release`/`bench`, plus your
own), incremental parallel C compilation with dependency tracking, and the `tests/` + `bench/`
conventions. Flags: `--profile=`, `--jobs=`, `--out-dir=`, `--cstd=`, `-o`. Custom `[command.NAME]`
entries run via `super-c run NAME` and may shadow the built-in `build`/`test`/`bench`/`clean` (this
repo's `build` is overridden to the two-stage self-hosting bootstrap). `super-c fmt` (canonical
formatter) and `super-c lint [--fix]` (default-on lints) round out the toolchain.

## Status and roadmap

Implemented and working: the full lexer→parser→resolver→typechecker→codegen pipeline, type inference,
structs/methods/visibility, enums with payloads and pattern matching (including or-patterns and
guards), untagged `union`s, monomorphized generics (functions, structs, enums, methods — same- and
cross-module), interfaces with enforced generic bounds and method dispatch, operator overloading
(`+ - * / %`, `==`, `<`, indexing, `into` / `try_into`), first-class tuples, the `?` early-return
operator, compile-time evaluation (constant folding, layout, and full CTFE with an abstract heap; `const fn`
with definition-site validation, mandatory evaluation of call-bearing const initializers, aggregate consts
materialized as static C data with relocations, cycle detection, and proven-UB fold errors), `panic` /
`unwrap` / `expect` with a `never` type for diverging calls, RAII-style
automatic cleanup (a `Free` trait run at scope exit) with move analysis (use-after-move,
use-after-free, and double-free prevention), a static borrow checker (`&`/`&mut` aliasing with
field-precise overlap, use-while-borrowed, non-lexical borrow lifetimes, dangling-reference returns),
closures (copy / `&mut` / owning captures, monomorphized through `F: fn(..) ..` and `fn move` bounds)
and function pointers, trait objects (`&dyn I` / `&mut dyn I` / `Box<dyn I>` with per-TU static
vtables and drop glue, plus structural `dyn fn(..) ..` for stored closures and heterogeneous handler
lists), references/pointers/`new`, slices and arrays (including
designated initializers), first-class ranges and slicing (`a[lo..hi]`), `for` over user iterators (an
`Iterator` interface), multi-return + tuple destructuring, `while` / `for` / `do`-`while` / `loop`
(a value-yielding expression via `break <expr>`), labeled loops with labeled `break` / `continue`
(`'outer: for .. { break 'outer; }`, defer-correct unwinding), `if let` / `while let`, `defer`,
raw strings (`r"…"` / `r#"…"#`), hex floats (`0x1.8p3`) and byte strings (`b"…"` → `[]u8`), numeric
literal suffixes (`1u8`, `0xFFu64`, `1.0f32`) with implicit
lossless widening (`i32 → i64`, `u8 → i32`, `f32 → f64`), module-level mutable globals (`static mut`),
`?` error conversion through `From` conformances, `_` discard bindings, `sizeof`/`alignof` on values, unit and tuple structs (`struct S;`,
`struct Pair(i32, str);` with `p.0` access and `Pair(1, "a")` construction), associated constants
(`extend T { const N: i32 = ..; }` → `T::N`), `x @ pat` bindings and rest patterns (`V(a, ..)`,
`S { f, .. }`), `Deref`/`DerefMut` auto-deref for method calls (`box_of_string.len()`; up to 8 hops,
cycle-checked, wrapper methods shadow the pointee's, `&mut self` targets need `deref_mut` and a `mut`
binding), float `Eq`/`Ord`/`Hash` via the IEEE-754 total order (`total_cmp`; floats sort and
key Maps), `Vector::sort_by`/`sort_by_key`, string→number parsing (`"ff".parse_u64_radix(16)`,
`"3.5".parse_f64()`), formatted printing with width / alignment / fill / zero-pad / precision / hex /
binary specifiers (`{:>8}`, `{:08.2}`, `{:b}`) plus `eprint` / `eprintln` to stderr, a test pipeline
(`--test` with `@test` / `@test(should_panic)` / `@test_init` / `@test_free` fixtures incl. a global
suite env, fork-isolated parallel execution, and assert builtins that report expression text, values,
and `file:line`), `static_assert`, `@c.*` attributes, the module system with an auto-imported `std`
prelude (containers,
iterators/algorithms, pluggable allocators), `extern "C"` FFI (custom header includes, variadics in
both directions via `va_list`, `_Complex`), and `sizeof` / `alignof`.

The compiler is **fully self-hosted**: it is written in Super-C, compiles itself through a two-stage
bootstrap to a byte-identical fixpoint, and ships with its own toolchain — the `build.toml` build
system (profiles, incremental parallel C compilation, `test`/`bench` conventions), a canonical
formatter (`super-c fmt`), and machine-fixable lints (`super-c lint --fix`).

Roadmap, in priority order:

1. **Parallel transpilation** — the emit pipeline is single-threaded today; the phases are
   embarrassingly parallel per module.
2. **Self-contained std** — port the breadth of a Go/Odin/Rust-style standard library to Super-C
   (file/console IO is currently FFI-only; this subsumes it). Unblocked, and the largest item.
3. **Threading** — a proper kernel/user threading API: today atomics and threads are C shims via
   FFI, with no std types and no `Send`/`Sync` markers (the borrow checker is single-threaded).
4. **Coroutines** — `launch f(args)`: uncolored spawn on stackful coroutines with `Chan<T>`, staged
   from a single-threaded scheduler to M:N work stealing.
5. **Tooling** — an LSP server, then syntax highlighting.
