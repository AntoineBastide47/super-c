# Super-C

Super-C is a small, statically typed systems language that **compiles to readable C**.

It takes features I like from other languages (automatic cleanup, memory safety, coroutines,
code that runs at compile time) and keeps C's portability and performance. The compiler turns your
program into ordinary C99/C11, and Clang, GCC or MSVC turns that into a native binary.

## Pipeline

```text
Super-C source (.spc)
    -> lexer          (UTF-8 source into tokens)
    -> parser         (tokens into a syntax tree; simple grammar, no backtracking)
    -> resolver       (connects each name to what it refers to)
    -> desugar        (rewrites shorthand like `launch` into plain code)
    -> typechecker    (types, generics, compile-time evaluation)
    -> borrow checker (moves, aliasing, lifetimes)
    -> Core IR        (a small control-flow form where cleanup is inserted and layouts are checked)
    -> C emitter      (writes one readable .h/.c pair per module)
    -> cc / clang / gcc
    -> native binary
```

## Installation

macOS and Linux: this installs the latest release into `~/.super-c` and adds `~/.super-c/bin` to
your PATH. The release contains the `super-c` binary and the `std/` and `ffi/` folders it needs.

```sh
curl -fsSL https://raw.githubusercontent.com/AntoineBastide47/super-c/main/install.sh | sh
```

Windows: download `super-c-windows-*.zip` from the
[GitHub Releases](https://github.com/AntoineBastide47/super-c/releases), unzip it anywhere, and add
that folder to your PATH.

## Quick start

```sh
# create a project and run it
super-c new hello
cd hello
super-c run

# write the C for one file into build/, without linking
super-c path/to/app.spc

# build one file into a binary
super-c build path/to/app.spc -o app
```

## Building and testing

```sh
super-c build                     # dev build (with ASan/UBSan)
super-c release                   # optimized build (-O3, link-time optimization)
super-c run                       # build the project, then run it
super-c test                      # run the tests (in tests/)
super-c bench                     # run the benchmarks (in bench/)
super-c clean                     # delete build outputs
```

A project is described by a `build.toml` file. At minimum it names the binary (`bin`) and its entry
file (`root`). From that, `super-c build` gives you:

* build profiles: `debug`, `dev`, `release`, `bench`, and any you define;
* incremental, parallel C compilation that only rebuilds what changed;
* the `tests/` and `bench/` folder conventions.

Useful flags: `--profile=`, `--jobs=`, `--out-dir=`, `--cstd=`, `--cc=`, `--bin=`, `--lib`, `-o`.

`--jobs=N` sets how many workers the whole build uses, both inside the compiler (parsing, type
checking, borrow checking) and for the C compiler processes. The default is one per CPU.
`--jobs=1` runs everything serially and gives byte-identical output.

`build.toml` can also declare:

* custom commands in `[command.NAME]` sections, run with `super-c command NAME` (built-in command
  names are reserved);
* libraries in a `[lib]` section (`type = ["static", "shared"]`);
* extra binaries in `[bin.NAME]` sections.

Other tools:

* `super-c fmt`: the code formatter (lines up to 120 columns; `@fmt.skip` opts a piece of code out).
* `super-c lint [--fix]`: warnings for unused code, unneeded `mut` or `unsafe`, unreachable code,
  dead stores, and more. `--fix` applies the automatic fixes and repeats until nothing changes.
  `--const` lists functions that can always run at compile time.
* `super-c lsp`: a language server (errors as you type, hover, go to definition, references, rename,
  completion, formatting, quick fixes). `editors/vscode/` connects it to VS Code.

## Language tour

### Bindings, functions, tuples and multiple return values

```superc
fn divmod(p: (i32, i32)) (i32, i32) {
    return p.1 / p.0, p.1 % p.0;
}

fn main() i32 {
    let x: i32 = 10;                   // explicit type
    let (div, mod) = divmod((x, 20));  // inferred type, unpacked into two names
    let mut sum = 0;                   // `mut` makes a binding changeable
    for i in 0..=mod {
        sum = sum + i;
    }
    return sum % 256;
}
```

Built-in types: `bool`, `char`, `i8 i16 i32 i64 isize`, `u8 u16 u32 u64 usize`, `f32 f64`,
`c32 c64` (C complex numbers), and `void`. Loops: `while`, `for`, and `do { .. } while (cond);`.

`main` is either `fn main() i32` or `fn main(args: Vector<str>) i32`.

Tuples hold 2 to 4 values. They work anywhere other values do: in fields, as arguments, in
containers (`Vector<(i32, bool)>`). To reach into a nested tuple, add parentheses: `(t.0).1`.

### Structs, methods, and visibility

```superc
struct Counter { pub n: i32 }    // fields are private unless marked `pub`

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
        1 | 2 | 3  => 1,    // any of these values
        4..=9      => 1,
        n if n < 0 => -1,   // a guard can test the matched value
        _          => 2,
    };
}
```

A `switch` must cover every case, and it can produce a value. One arm can list several patterns
with `|`. Enums without data become plain C `enum`s; enums with data become tagged unions.

### Loops, labels, and `let` conditionals

```superc
fn main() i32 {
    let mut v = Vector::<i32>::new();
    v.push(3); v.push(8); v.push(5);

    // `loop` produces a value: `break <value>` returns it
    let mut n = 0;
    let seed = loop {
        n += 1;
        if n * n > 20 { break n; }
    };

    // a label lets break/continue leave several loops at once
    let mut pairs = 0;
    'outer: for i in 0..4 {
        for j in 0..4 {
            if i + j == seed { break 'outer; }
            pairs += 1;
        }
    }

    // `while let` repeats while the pattern matches; `if let` tests it once
    let mut last_even = 0;
    while let Some(x) = v.pop() {
        if let 8 = x { last_even = x; }
        println("popped {:>4}", x); // right-aligned in 4 columns
    }

    return seed + pairs + last_even - 24; // 5 + 11 + 8 - 24 = 0
}
```

Format placeholders follow `{:[fill][<^>][0][width][.precision][x|X|b]}`. For example `{:08.2}`
prints a float 8 wide with 2 decimals and leading zeros, and `{:b}` prints binary. `eprint` and
`eprintln` work like `print` and `println` but write to stderr.

### Generics

```superc
fn id<T>(x: T) T { return x; }

struct Pair<A, B> { pub a: A, pub b: B }

fn main() i32 {
    let p = Pair::<i32, bool> { a: id(41), b: true };
    return p.a + 1;   // 42
}
```

Functions, structs, enums and methods can be generic, and a method can have its own type
parameters (for example `map<U>`). The compiler writes a separate copy of the code for each type
you use, also across modules, so generic code is as fast as hand-written code.

### Closures and function pointers

```superc
fn apply(f: fn(i32) i32, x: i32) i32 { return f(x); }            // takes a plain function pointer

fn scale<F: fn(i32) i32>(x: i32, f: F) i32 { return f(x) * 2; }  // takes any function, closures too

fn main() i32 {
    let g = |x: i32| x * 2;                       // short closure
    let h = fn(x: i32) i32 { return x + 1; };     // anonymous function
    let k = 10;
    let add_k = |x: i32| x + k;                   // copies k in at this point
    return apply(g, 20) + apply(h, 0) + scale(5, add_k) + add_k(1) - 40; // 42
}
```

A closure that captures nothing becomes a normal C function: no hidden data, no allocation.

A closure that captures variables stores copies of them in a small struct, still without
allocation. It cannot be passed as a plain `fn(..)` pointer, but it can be passed to a generic
parameter bounded by `F: fn(..) ..`. The compiler then calls it directly. The standard library's
higher-order methods (`map`, `find`, `retain`, `and_then`, `filter`, ...) all take this kind of
parameter, so they accept functions, function pointers and closures.

How a closure captures each variable depends on how its body uses the variable:

* **Read only**: the closure keeps a copy. Later changes to the original are not seen.
* **Changed**: if the body assigns to the variable or takes `&mut` of it, the closure keeps a
  pointer, and changes go to the original variable. The original must be `mut`. After
  `let mut n = 0; each(5, fn(x: i32) { n += x; });`, `n` is 10.
* **Owned**: if the variable owns memory (a `String`, a `Vector`, ...), it moves into the closure.
  The original can no longer be used, and the closure frees the value exactly once. Such a
  closure only fits a bound written `F: fn move(..) ..`. You can call it as often as you like,
  but you can pass it on only once.

A closure cannot capture a fixed-size array by copy; capture a slice instead.

### Trait objects (`dyn`)

Sometimes the concrete type is only known at run time: a list of different shapes, plugins, or
closures stored in a field. For those cases an interface can be called through `dyn`:

```superc
interface Shape {
    fn area(self: &Self) i32;
    fn tag(self: &Self) i32 { return 0; }        // default methods work through dyn too
}
struct Circle { pub r: i32 }
struct Sq { pub s: i32 }
extend Circle as Shape { pub fn area(self: &Circle) i32 { return 3 * self.r * self.r; } }
extend Sq as Shape { pub fn area(self: &Sq) i32 { return self.s * self.s; } }

fn total(a: &dyn Shape, b: &dyn Shape) i32 { return a.area() + b.area(); }  // one fn, any Shapes

fn main() i32 {
    let mut v: Vector<Box<dyn Shape>> = Vector::<Box<dyn Shape>>::new();    // owns mixed types
    v.push(Box::<Circle>::new(Circle { r: 1 }));
    v.push(Box::<Sq>::new(Sq { s: 2 }));
    let mut sum = 0;
    for i in 0..v.len() { sum = sum + v.at(i).area(); }                     // 3 + 4
    return sum;                                                             // elements are freed
}
```

A `dyn` value is two pointers: the data and a table of its methods. Creating one never allocates.
There are three forms:

* `&dyn I`: a borrowed view;
* `&mut dyn I`: a mutable view, needed for methods that take `&mut self`;
* `Box<dyn I>`: an owned value that is freed automatically.

Wherever a `&dyn I` is expected, you can pass a `&T` for any `T` that implements `I`. An interface
can be used with `dyn` only if every method takes `self` by reference, does not mention `Self`
anywhere else, and has no generic parameters. The compiler tells you which rule is broken.

Closures work the same way. `dyn fn(..) ..` stores any function or closure with that signature:

```superc
fn make_adder(k: i32) Box<dyn fn(i32) i32> { return |x: i32| x + k; }  // captures move to the heap

let mut on_event: Vector<Box<dyn fn(i32) i32>> = Vector::<Box<dyn fn(i32) i32>>::new();
on_event.push(make_adder(10));
on_event.push(double_it);              // a named function works too, with no allocation
let r = (*on_event.at(0))(5);          // 15
```

A capturing closure is borrowed as `&dyn fn(..)` with `&f`, or moved into a `Box<dyn fn>`. Generic
`F: fn(..)` parameters stay the zero-cost default; use `dyn` only where generics cannot help.

### Memory: pointers, references, `new`

```superc
fn main() i32 {
    let p = new i32(41);        // allocate an i32 on the heap: p is a *mut i32
    unsafe { *p = *p + 1; }     // using a raw pointer requires `unsafe`
    let r: &i32 = unsafe &*p;   // turn the raw pointer into a reference
    return *r;                  // 42 (references need no `unsafe`)
}
```

`*const T` and `*mut T` are raw pointers. `&T` and `&mut T` are references. `new T(expr)` and
`new T { .. }` allocate. `sizeof(T)` and `alignof(T)` give a type's size and alignment in bytes.

The compiler cannot check raw pointers or C functions. So every raw-pointer operation
(dereference, indexing, arithmetic, field access) and every call to an `extern "C"` function must
be inside an `unsafe { ... }` block or start with `unsafe`. This marks exactly where the compiler's
guarantees stop. Comparing pointers and using references stay safe.

References are checked at compile time:

* a value can have many `&` references or one `&mut` reference at a time (fields count
  separately, so `p.a` and `p.b` do not conflict);
* a value cannot be read or moved while a `&mut` to it is in use;
* a borrow ends at its last use, not at the end of the block;
* returning a reference to a local variable is an error.

Lifetimes connect a returned reference to the arguments it came from. You rarely write them; when
you do, the syntax is the same as Rust's:

```superc
fn longer<'a>(a: &'a String, b: &'a String) &'a String {
    if a.len() > b.len() {
        return a;
    }
    return b;
}
```

Structs that hold references declare lifetime parameters (`struct View<'a> { s: str<'a> }`).
Higher-ranked bounds (`for<'x> fn(&'x T) &'x U`) and generic associated types are supported.
Lifetimes are only used for checking; they do not appear in the generated C.

### Ownership and automatic cleanup

Values that own memory are freed automatically, exactly once, when they go out of scope. You do not
write the cleanup code:

```superc
struct Session {
    pub name: String,
    pub log: Vector<String>,
}

fn main() i32 {
    let s = Session { name: String::from_str("alice"), log: Vector::<String>::new() };
    let n = s.name.len() as i32;
    return n - 5;
}   // s.log and s.name are freed here, with no code written for it
```

The cleanup hook is the `Free` interface (`fn free(self: &mut Self)`). A struct or enum that
contains owning values (a `String`, a container, another owning struct) becomes owning itself, and
the compiler writes its `free` for you. Write `extend T as Free` only when you need custom cleanup;
any owning field your code does not free is still freed for you, so a custom `free` cannot leak a
field by mistake.

Two special cases:

* A `union` that owns memory must have a hand-written `Free`, because only you know which member is
  active.
* Pointers and references never own. To own memory, use a type with a `free`, like `Box<T>`,
  `Vector<T>` or `String`.

Owning values **move** instead of being copied, and the compiler rejects any use after a move:

```superc
let a = String::from_str("owned");
let b = a;              // a's value moves to b
// a.len()              // error: use of moved value
```

More rules:

* Assigning to a place frees its old value first, so `s.name = fresh;` does not leak.
* You cannot move a field out of an owning value or out of a reference, because the owner would
  free it a second time. Use `replace` to swap a value out instead.
* `forget(value)` leaks a value on purpose. The leak tracker still reports it, so deliberate leaks
  stay easy to find.

```superc
fn retitle(s: &mut Session) String {
    return replace(&mut s.name, String::from_str("bob"));  // take the old name, put a new one in
}

forget(expensive);      // never freed, still visible to the leak tracker
```

Inside an `unsafe` block you may move a field out of a reference directly. You then take
responsibility for the ownership, as with raw pointers.

For cleanup that automatic freeing does not cover, such as a raw pointer or a C handle, `defer`
runs a statement when the block ends:

```superc
extern "C" { fn free(p: *mut void) void; }

fn main() i32 {
    let p = new i32(42);
    defer unsafe free(p);   // runs when main returns
    return unsafe *p;       // the return value is computed before the defer runs
}
```

A `defer` runs on every exit from its block (normal end, `return`, `break`, `continue`). Several
defers run in reverse order.

### Slices and arrays

```superc
fn sum(xs: []i32) i32 {              // []T is a view: a pointer and a length
    let mut t = 0;
    for x in xs { t = t + x; }
    return t;
}

fn main() i32 {
    let a: [i32; 4] = [10, 20, 30, 40];
    let t: [i32; 128] = [['a'] = 1, ['z'] = 2];   // set only the listed indexes
    return a[0] + a[3] + t['a'];
}
```

### The standard library

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

These types are always available, with no import: `Box<T>`, `Option<T>`, `Result<T, E>`,
`Vector<T>`, `Map<K, V>`, `Set<T>`, `String` and `str`, plus iterators.

* `panic("msg")` stops the program with a message. `unwrap()`, `expect(msg)` and `unwrap_err()`
  panic when the value is missing.
* A function that never returns (such as `panic`) can be used where a value is expected, for
  example in one arm of a `switch`.
* Containers and `String` can use a custom allocator: implement the `Allocator` interface and pass
  it to `new_in`, `with_capacity_in` or `from_str_in`.

Iterators chain lazily: `map`, `filter`, `enumerate` and `zip` build a pipeline, and `for`, `fold`,
`for_each`, `count` or `collect` run it. No allocation happens, and the closures are called
directly:

```superc
let doubled_sum = fold(map(v.iter(), |x: &i32| *x * 2), 0, |a: i32, x: i32| a + x);
let odd = count(filter(v.iter(), |x: &i32| *x % 2 == 1));
for p in enumerate(v.iter()) { .. }   // p.0 = index, p.1 = &element
let picked: Vector<i32> = collect(map(v.iter(), |x: &i32| *x + 1));
```

### Modules

A project is a folder tree of `.spc` files. `import` loads another module, and `pub` decides what
other modules can see.

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

* `import P as Q;` gives a module a shorter name.
* `import P as *;` makes its public items usable without the `P::` prefix.
* Imports pass through: if module A imports B, code that imports A can also use B (as `B::foo()`
  or through a glob).
* Two modules may import each other. The only error is two types that contain each other by value,
  because their size would be infinite.

### C interop (FFI)

```superc
extern "C" {
    type CFile;
    fn fopen(path: *const char, mode: *const char) *mut CFile;
    fn fclose(file: *mut CFile) i32;
}
```

`extern "C"` declarations call C functions directly, with no wrapper, so existing C libraries work
as they are. Every call to them needs `unsafe`.

`extern "C" "header.h" { .. }` also includes that header in the generated C. If the header is next
to your `.spc` file, the compiler fixes the include path for you; otherwise it is included as
written.

C source files come along automatically. If `native.h` sits next to the `.spc` file, its `native.c`
is found and compiled too:

```superc
extern "C" "native.h" {      // native.c next to it is compiled into the build
    fn native_mix(a: i32, b: i32) i32;
}
```

* `@c.source("impl.c")` names a C file stored somewhere else.
* `@c.link("m")` links a library (a value that starts with `-` is passed as is).
* Link flags are collected in `build/<profile>/raw/__ldflags`, one per line, and applied automatically.
* The bundled `math`, `pthread` and `dlfcn` modules already declare their libraries, so importing
  them is enough.

Variadic functions work in both directions. You can call a C function that takes `...`:

```superc
extern "C" { fn printf(fmt: *const char, ...) i32; }
```

and you can write one, reading its arguments with `va_list`, `va_start`, `va_arg(ap, T)` and
`va_end`:

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

`@c.*` attributes go before an item (and before `pub`). They become C keywords or GNU
`__attribute__`s:

```superc
@c.noreturn
fn panic() { /* ... */ }

@c.packed
struct Header { pub magic: u32, pub version: u16 }

@c.align(64)
struct CacheLine { pub data: [u8; 64] }

@c.export("superc_init")     // use exactly this C symbol name
pub fn init() i32 { return 0; }
```

Supported: `inline`, `always_inline`, `noinline`, `noreturn`, `align(N)`, `packed`, `export("sym")`,
`import("sym")`, `section("s")`, `used`, `unused`. `export` and `import` fix a function's C name.
`@emit_macro` on a generic struct or enum also writes it as a C macro, for use from plain C.

### Testing

```superc
struct Fx { pub v: Vector<i32> }

@test_init
fn setup() Fx {                       // a fresh fixture for each test that asks for one
    let mut v = Vector::<i32>::new();
    v.push(1); v.push(2);
    return Fx { v: v };
}

@test
fn drains(fx: &mut Fx) {              // add a parameter to receive the fixture
    let mut s = 0;
    while let Some(x) = fx.v.pop() { s += x; }
    assert_eq(s, 3);
}

@test(should_panic)
fn rejects_bad_input() { panic("boom"); }
```

```sh
super-c --test app.spc                      # find the @test functions, build, run them in parallel
super-c --test --filter=drains app.spc      # only tests whose name contains "drains"
super-c --test --test-shard=1/2 app.spc     # run half of the tests (for CI)
super-c --test --test-jobs=4 app.spc        # at most 4 test processes at once
super-c --test --test-timeout=120 app.spc   # fail a test that runs past 120 s (default 90, 0: none)
super-c --test --test-no-fork app.spc       # run in one process, for a debugger
super-c --test --quiet app.spc              # print only failures and the totals
```

* Each test runs in its own process, so a crash or a failed assertion fails only that test.
* `@test(should_panic)` passes only if the test panics.
* A test's output is shown only when it fails. At the end, a `failures:` section repeats each
  failed test's output and how it ended.
* `@test_init` builds a fixture that the test receives as a parameter. `@test_free` (optional)
  tears it down. `@test_init(global)` and `@test_free(global)` build one shared environment for the
  whole run; each test gets it as a read-only `&`.
* `assert(cond[, "msg"])`, `assert_eq(a, b)` and `assert_ne(a, b)` print the failing expression,
  both values, and the file and line.
* Tests are left out of normal builds.

You can also group tests as methods on a type. The type's `@test_init` method creates the value,
and each test receives it as `self`:

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

These tests show up as `module::Counter::starts_at_zero`. A module can have one such group per
type.

### Finding leaks and double frees

Every compiled program includes a leak checker. It is off until you turn it on, and it works
everywhere, including Apple Silicon where LeakSanitizer is not available:

```sh
super-c lint                   # finds many leaks at compile time
SC_LEAK_CHECK=1 ./app          # at exit, report memory that was never freed, with call stacks
SC_LEAK_CHECK=fatal ./app      # same, and exit with code 23 if anything leaked (for CI)
```

```text
== super-c leaks: 1 allocation(s), 46 byte(s) ==
leak: 1 allocation(s), 46 byte(s)
    2   app    Global__alloc + 32
    3   app    String__from_str + 44
    4   app    main + 64
```

The checker tracks every `malloc`, `calloc`, `realloc` and `free` in the generated code. It also
catches a **double free**: it prints both call stacks and skips the second free, so you get a report
instead of a crash. A `realloc` of a freed pointer is reported as a use after free. When the checker
is off, it costs one branch per allocation. This repository runs its whole test suite with
`SC_LEAK_CHECK=fatal`, so the compiler and standard library have no leaks.

### Compile-time evaluation

The compiler can run your code while it compiles. This is always on. Two flags limit how much work
one evaluation may do. When a normal function runs out of budget, it simply runs at run time
instead; `const fn` and constants have stricter rules (below).

```sh
super-c app.spc                                          # defaults: about 2M steps, 96 MiB
super-c --const-eval-steps=100000 --const-eval-memory=16M app.spc
```

```superc
struct Header { magic: u32, version: u16 }
static_assert(sizeof(Header) == 8, "Header must stay 8 bytes");
```

* `static_assert(cond, "msg")` works at the top level and inside functions. If the compiler can
  compute the condition, it checks it right away (including `sizeof` and `alignof` of any type).
  Otherwise it becomes a C `_Static_assert`.
* Array indexes in initializers and array lengths may be any constant expression. A length that
  is not constant is a clear error.
* An array's length is part of its type: `[i32; 4]` and `[i32; 8]` are different types. That is
  why an array can be a generic argument (`Wrap<[i32; 4]>`). To store arrays in the standard
  containers, wrap them in a struct.
* Every struct layout the compiler computes is double-checked in the C output with
  `_Static_assert(sizeof(T) == N, ...)`, so the real C compiler confirms it on the real target.
* A call whose arguments are all known at compile time runs at compile time. This covers loops,
  recursion, structs, arrays, enums, generics, floating point (including math functions) and heap
  memory: a function that builds a `Vector` can run at compile time. If something is not supported
  or runs over budget, a normal function simply runs at run time.
* A failing `static_assert` explains why (for example `division by zero` or `use after free`) and
  shows the compile-time call stack.
* Constants that depend on each other in a loop (`const A = B; const B = A;`) are reported as
  `cyclic constant dependency`. Code that would certainly divide by zero, read out of bounds or use
  freed memory is a compile error.

#### `const fn` and required evaluation

```superc
const fn table_size(bits: u32) usize { return (1u32 << bits) as usize; }

fn evens() Array<u32, 5> {                     // normal functions work too (Vectors, loops, ...)
    let mut v = Vector::<u32>::new();
    for i in 0..5u32 { v.push(i * 2); }
    let mut a = Array::<u32, 5>::new();
    for i in 0..a.len() { a.set(i, *v.at(i)); }
    return a;
}

const N: usize = table_size(8);                // must be computed at compile time, or it is an error
const V: Array<u32, 5> = evens();              // stored as static data in the C output
```

`const fn` marks a function that must be able to run at compile time. The compiler checks it where
it is defined: if it calls an unsupported C function, touches a `static mut`, or is variadic, you
get an error naming the reason. A `const fn` is still an ordinary function at run time.

The rules:

* A `const fn` call with constant arguments **must** run at compile time. Any failure is a compile
  error. Only normal functions fall back to run time.
* A constant whose value contains a call must be computed at compile time. If that fails, the
  error shows why and where.
* Complex results (structs, arrays, strings, even linked structures) are written into the C output
  as static data. A constant that points to freed memory is an error.
* A constant can have an owning type (`const V: Vector<i32> = [1, 2].into();`). Its data lives in
  static storage, and the compiler rejects moving it out, so it is never freed. Its allocator must
  not keep state; the default one does not.

`super-c lint --const` lists the functions that can always run at compile time. With `--fix`, it
marks them `const fn`, which also saves the compiler from proving it again.

## Concurrency

The `std::parallel` modules provide a full concurrency toolkit on top of OS threads:

* **Atomics**: `Atomic<T>` for integers, with an explicit memory order on every operation
  (`Relaxed` to `SeqCst`).
* **Threads**: `thread::spawn` returns a `JoinHandle<T>`. `Arc<T>` shares a value between threads.
* **`Send` and `Sync`**: the compiler checks that only thread-safe values cross threads. A raw
  pointer is neither, so it cannot. Share through `Arc`; change through an atomic or a lock.
* **Synchronization**: `Mutex<T>`, `RwLock<T>`, `Condvar`, `Once`, `WaitGroup`, `Barrier`,
  `Semaphore`. Locks unlock automatically at the end of the scope. A coroutine that waits does not
  block its thread: the thread runs other work meanwhile. Timed waits and `time::sleep` are
  available.
* **Channels**: `Channel<T>::bounded(n)` or `unbounded()`, with cloneable `Sender<T>` and
  `Receiver<T>`. Sends and receives can wait, time out, or return right away. The channel closes
  when the last sender is dropped.
* **`select`**: waits on several channel operations at once and runs the first one that is ready,
  with optional `timeout(d)` and `default` arms.
* **Fair scheduling**: a coroutine that never waits cannot hog its thread. In programs that use
  `launch`, the compiler adds a yield check to every loop.
* **Async I/O**: TCP (`net::TcpStream`) and UDP sockets, IPv4 and IPv6. A coroutine waiting on the
  network is parked, so a hundred connections cost a hundred parked coroutines, not a hundred
  threads. Errors come back as `Result<T, IoError>`. POSIX only.
* **Blocking calls**: `blocking::call` (or `@blocking` on a C function) runs code that blocks on a
  separate thread pool. Each task has an id that panic messages show, `SC_TASK_TRACE=1` traces the
  scheduler, and `runtime::live_tasks()` reports tasks that never finished.
* **Data parallelism**: `parallel::range`, `each`, `each_mut`, `chunks_mut`, `reduce` and `sections`
  split work across all cores and return when it is done. The compiler rejects a closure that could
  cause a data race.
* **`launch`**: `launch || { … };` starts a task in the background on a worker pool (one thread
  per CPU by default, or `runtime::set_worker_count(n)`). Each task is a coroutine with its own
  stack, and idle workers steal work from busy ones. A task cannot borrow data from the function
  that launched it, and it can only hold thread-safe values. `runtime::shutdown()` waits for
  the pool to finish.

## Generated output

`super-c app.spc` writes a `build/dev/raw/` folder next to the source (`build/<profile>/raw/`
under `--profile`):

```text
build/dev/raw/
  super_rt.h  super_rt.c   # small runtime: standard includes and the leak checker
  __sc_fwd.h               # forward declarations shared by all files
  app.h  app.c             # one .h/.c pair per module
  __ldflags                # link flags, one per line
```

Includes are relative, so the folder builds with no `-I` flags:
`cc $(find build/dev/raw -name '*.c') $(cat build/dev/raw/__ldflags) -o app`. With a single module, the C names stay plain (no module prefix).

## Environment variables

Every setting is an environment variable starting with `SC_`. None is needed for normal use.

### Build system and caches

| Variable | Effect |
| --- | --- |
| `SC_CACHE_DIR` | where the build cache lives |
| `SC_NO_CACHE` | turn off the build cache |
| `SC_NO_EMIT_CACHE` | always regenerate the C, even when no source changed |
| `SC_NO_TU_CACHE` | turn off the per-file C cache |
| `SC_BUILD_MEM_BUDGET` | limit the memory the parallel C generation may use (`64M`, `2G`; unset means no limit) |
| `SC_TIMINGS` | print how long each build phase takes |

### Extra checks (for compiler development; each runs only when set)

| Variable | Effect |
| --- | --- |
| `SC_FACTS_CHECK` | check that no stage after type checking changes type-checking results |
| `SC_CORE_IR` | re-check every inlined function and every removed bounds check |
| `SC_LAYOUT` | check every type layout against the C layout rules |
| `SC_CEMIT_STATS` | print the time of each compiler phase and constant statistics |

### Debug output

| Variable | Effect |
| --- | --- |
| `SC_INLINE_STATS` | counts of the inliner's decisions per function |
| `SC_BCE_STATS` | counts of removed bounds checks per function |

### Language server

| Variable | Effect |
| --- | --- |
| `SC_LSP_NO_INCR` | recompile everything on each edit instead of only what changed |
| `SC_LSP_BUDGET_MB` | memory limit for the analysis cache |

### Test harness

| Variable | Effect |
| --- | --- |
| `SC_TEST_SUPERC` | path of the compiler to test (the WebAssembly CI lane points it at a wasmtime wrapper) |

### Runtime (read by every compiled program, including the compiler itself)

| Variable | Effect |
| --- | --- |
| `SC_LEAK_CHECK` | the leak and double-free checker (it also reports a `realloc` of a freed pointer; other reads and writes of freed memory are not checked): any value except `0` reports at exit; a value starting with `f`/`F` (like `fatal`) also exits with code 23 |
| `SC_TASK_TRACE` | trace coroutines and tasks |
| `SC_SCHED_SEED` | fix the scheduler's random seed, to replay a race without rebuilding |
| `SC_LOCK_ORDER` | check lock ordering: any value except `0` reports violations; `f...`/`F...` aborts |

## Status and roadmap

Everything above is implemented and works. Super-C also has:

* operator overloading (`+ - * / %`, `==`, `<`, indexing, `into` / `try_into`)
* untagged `union`s
* the `?` operator for early return on errors, with automatic error conversion through `From`
* global `static mut` variables
* `_` to discard a value
* unit and tuple structs (`struct S;`, `struct Pair(i32, str)` with `p.0` and `Pair(1, "a")`)
* associated constants (`T::N`)
* `x @ pat` bindings and `..` in patterns (`V(a, ..)`, `S { f, .. }`)
* automatic dereference through `Deref` / `DerefMut`
* float `Eq` / `Ord` / `Hash` (floats can be sorted and used as `Map` keys), plus
  `Vector::sort_by` / `sort_by_key`
* matchertext strings that need no escapes: `M"(say "hi")"`, with `{expr}` placeholders in the
  `M{}"(...)"` form
* hex floats (`0x1.8p3`)
* byte strings (`b"…"`, of type `[]u8`)
* number suffixes (`1u8`, `1.0f32`) and automatic widening (`i32` to `i64`, `f32` to `f64`)

Next, in priority order:

1. **Benchmark against the state of the art**: compare the concurrency runtime with Go, Rust and C,
   and close the gaps.
2. **A self-contained standard library**: port a Go/Odin/Rust-style standard library to Super-C.
   File and console I/O currently go through C.
