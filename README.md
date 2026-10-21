# Super-C

Super-C is a small, statically typed systems language that **compiles to readable C**.

It takes features I like from other languages (automatic cleanup, memory safety, coroutines,
code that runs at compile time, portable vector code) and keeps C's portability and performance.
The compiler turns your program into ordinary C11, and Clang or GCC (mingw-w64 GCC on Windows)
turns that into a native binary or a WebAssembly module. The compiler is written in Super-C and
compiles itself.

## Pipeline

```text
Super-C source (.spc)
    -> lexer            (UTF-8 source into tokens)
    -> parser           (tokens into a syntax tree; simple grammar, no backtracking)
    -> platform filter  (removes items that @platform, @arch and @when exclude for the target)
    -> resolver         (connects each name to what it refers to)
    -> HIR lowering     (rewrites `launch`, `select` and `parallel for` into plain code)
    -> typechecker      (types, generics, compile-time evaluation)
    -> borrow checker   (lowers each body to Core IR, checks moves, aliasing and lifetimes,
                         inserts cleanup, turns self tail calls into loops)
    -> program checks   (unbounded recursion, functions that always panic, lints)
    -> instance graph   (finds each generic instance the program uses: one copy per type)
    -> Core IR passes   (per function: inlining, then bounds-check elimination)
    -> C emitter        (readable C11; maps vector operations to the target's CPU features)
    -> cc / clang / gcc (incremental and parallel, with a precompiled header)
    -> native binary or WebAssembly module
```

## Installation

macOS (Apple Silicon) and Linux (x86_64): this installs the latest release into `~/.super-c` and
adds `~/.super-c/bin` to your PATH (zsh and bash; other shells get a note). The release contains
the `super-c` binary and the `std/` and `ffi/` folders it needs.

```sh
curl -fsSL https://raw.githubusercontent.com/AntoineBastide47/super-c/main/install.sh | sh
```

Windows (x86_64): download `super-c-windows-x86_64.zip` from the
[GitHub Releases](https://github.com/AntoineBastide47/super-c/releases), unzip it, and add the
`super-c-windows-x86_64` folder inside it to your PATH.

Each release also contains `super-c-wasm32-wasip1.tar.gz`: the compiler as a WASI module. Give
wasmtime the current folder and the unpacked folder `D`, and name the module's absolute path as
`argv[0]` so that it finds `std/` beside it:

```sh
wasmtime run --dir=. --dir="$D" --argv0 "$D/super-c.wasm" "$D/super-c.wasm" lint app.spc
```

WASI cannot start processes, so this build can write C, format and lint; commands that run the C
compiler need the native binary.

Super-C needs a gcc-style C compiler: Clang or GCC, and mingw-w64 GCC on Windows. MSVC is not
supported. The compiler uses `--cc=`, else the `cc` key of `build.toml`, else `$CC`, else `cc`.
It finds `std/` and `ffi/` next to its own binary or up to two folders above it; set `SC_STD_DIR`
when you move the binary away from them.

## Quick start

```sh
# create a project and run it (`super-c init` does the same in the current folder)
super-c new hello
cd hello
super-c run

# write the C for one file into build/debug/raw/ next to it, without linking
super-c path/to/app.spc

# build one file into a binary
super-c build path/to/app.spc -o app
```

`super-c new NAME` writes `build.toml`, `src/main.spc` and `.gitignore`, and runs `git init` when
git is available.

## Building and testing

```sh
super-c build                     # debug build (-O0, debug info, frame pointers)
super-c build --sanitizers        # debug build with ASan and UBSan
super-c release                   # optimized build (-O3, link-time optimization)
super-c run                       # build the project, then run it
super-c test                      # run the tests (in tests/)
super-c bench                     # run the benchmarks (in bench/)
super-c clean                     # remove idle build outputs and every unused cache entry
super-c clean --full              # delete the build folders and the project's build cache
```

A project is described by a `build.toml` file. At minimum it names the binary (`bin`) and its entry
file (`root`). Project commands search upward for the nearest `build.toml`, and `super-c build DIR`
builds the project in `DIR`. The binary goes to `build/<profile>/<bin>`. From that, `super-c build`
gives you:

* build profiles: `debug` (the default), `release`, `bench`, `test` (`-O1`), `race`
  (ThreadSanitizer), and any you define;
* `--sanitizers` on any build: AddressSanitizer and UndefinedBehaviorSanitizer (not for Windows,
  iOS, Android or wasm);
* incremental, parallel C compilation that only rebuilds what changed. Small programs compile as
  one C file; larger ones compile in packs that share a precompiled header;
* a `compile_commands.json` for C tools;
* the `tests/` and `bench/` folder conventions.

Two builds of the same profile folder do not run at the same time: the second one waits.

Useful flags: `--profile=`, `--jobs=`, `--out-dir=`, `--cstd=`, `--cc=`, `--bin=`, `--lib`, `-o`.
`--cstd=` replaces the base C flags (default `-std=c11 -D_POSIX_C_SOURCE=200809L
-D_XOPEN_SOURCE=700`).

`--jobs=N` sets how many workers the whole build uses, both inside the compiler (parsing, type
checking, borrow checking, C generation) and for the C compiler processes. Nested `super-c`
processes share these slots. The default is one per CPU. `--jobs=1` runs everything serially and
gives byte-identical output.

`build.toml` can also declare:

* custom commands in `[command.NAME]` sections (`run`, `env`, `needs-build`), run with
  `super-c command NAME` (built-in command names are reserved);
* libraries in a `[lib]` section (`type = ["static", "shared"]`);
* extra binaries in `[bin.NAME]` sections;
* profiles in `[profile.NAME]` sections, new or changing a built-in one: `opt-level`, `cflags`,
  `ldflags`, `link-args`, `strip`, `lto`, `overflow-checks`, `target-features`;
* top-level settings: `cc`, `cstd`, `cflags`, `ldflags`, `ldlibs`, `out-dir`, `test-dir`,
  `bench-dir`, `jobs`, `default-profile`, `const-eval-steps`, `const-eval-memory`, and the CPU
  keys below.

### Targets and CPU features

```sh
super-c build --target=wasm                        # windows | macos | linux | ios | android | wasm
super-c build --target=linux --arch=aarch64        # x86_64 | aarch64 | wasm32
super-c build --target-feature=+i8mm,-sve          # enable or disable CPU features of the arch
super-c release --target-cpu=x86-64-v3             # x86_64 level: x86-64, x86-64-v2, -v3, -v4
super-c build --print-probes                       # show what the C toolchain accepts; builds nothing
```

* wasm uses the wasi-sdk (`WASI_SDK_PATH`, or `WASI_SYSROOT`), Android uses the NDK
  (`ANDROID_NDK_HOME` or `ANDROID_NDK_ROOT`), and iOS uses Xcode (`xcrun`).
* wasm32 vector code needs `--target-feature=+simd128` (and `+relaxed-simd` for those instructions).
* On x86_64, a build at optimization level 2 or more also makes a copy of each function with vector
  code for `x86-64-v3` and picks the copy at run time. `--simd-dispatch=` selects the levels
  (`x86-64-v2` to `x86-64-v4`, comma-separated) or `off`. `--simd-width=512` lets AVX-512 code use
  512-bit vectors.
* `build.toml` takes the same settings: `target-features`, `target-cpu`, `simd-width`,
  `simd-dispatch`.

### Other tools

* `super-c fmt [PATH...]`: the code formatter (lines up to 120 columns; `@fmt.skip` opts a piece of
  code out). `--check` writes nothing and exits 1 when a file needs formatting. `fmt -` formats
  stdin to stdout.
* `super-c lint [PATH...] [--fix]`: warnings for unused code, unneeded `mut` or `unsafe`,
  unreachable code, dead stores, and more. `--fix` applies the automatic fixes and repeats until
  nothing changes. `--const` lists functions that can be `const fn`. Builds run the lints too;
  `--no-lint` turns them off.
* With no path, `fmt` and `lint` use the whole project.
* `super-c lsp`: a language server. It gives errors as you type, hover, go to definition, type
  definition and implementation, references, document highlight, rename, completion, signature
  help, call and type hierarchy, document and workspace symbols, folding, selection ranges, inlay
  hints, semantic tokens, formatting and quick fixes. It also checks `build.toml`.
  `editors/vscode/` connects it to VS Code (`editors/vscode/install.sh` links it in on macOS).
* `super-c vendor SRC [NAME]`: copies a git repository or a local folder into `vendor/NAME`
  (`--ref=` pins a branch, tag or commit; `--force` replaces it). Import it as
  `vendor::NAME::module`.
* `super-c bindgen header.h -o out.spc`: makes an `extern "C"` module from a C header (`--link=`,
  `--header=`, `-I`, `--from=`, `--cflag=`, `--cc=`). A folder input recurses and needs `-o` to name
  an output folder. Generate the bindings again for each target.

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
`c32 c64` (C complex numbers), and `void`. The standard library adds wider numbers (see below).
Loops: `while`, `for`, `loop`, and `do { .. } while (cond);`.

`main` is either `fn main() i32` or `fn main(args: Vector<str>) i32`.

`fn f() (A, B)` returns two results, not a tuple. Tuples hold 2 to 4 values. They work anywhere
other values do: in fields, as arguments, in containers (`Vector<(i32, bool)>`). To return a
tuple, name its type with an alias (`type P = (A, B);`). To reach into a nested tuple, add
parentheses: `(t.0).1`.

Integer overflow traps in the `debug`, `test` and `race` profiles and wraps in `release` and
`bench` (`overflow-checks` in a profile changes this). Division by zero and shifts out of range
always trap. `wrapping_*`, `checked_*` and `saturating_*` methods choose the behavior explicitly.
Values widen automatically (`i32` to `i64`, `f32` to `f64`); other conversions use `as`.

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
with `|`. Enums without data become plain C `enum`s, and a `switch` over them becomes a C
`switch`; enums with data become tagged unions. A variant without data can take a value
(`enum Color { Red = 1, Green, Blue = 10 }`); only such enums cast to integers.

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
prints a float 8 wide with 2 decimals and leading zeros, and `{:b}` prints binary. `{{` and `}}`
print braces. `eprint` and `eprintln` work like `print` and `println` but write to stderr, and
`format(..)` returns a `String`.

### Interfaces and generics

```superc
interface Shape {
    fn area(self: &Self) i32;
    fn twice(self: &Self) i32 { return 2 * self.area(); }   // a default method
}

@derive(Format, Eq, Clone)
struct Sq { pub s: i32 }

extend Sq as Shape { pub fn area(self: &Sq) i32 { return self.s * self.s; } }

fn largest<T: Shape>(xs: []T) i32 {                         // any type that implements Shape
    let mut m = 0;
    for i in 0..xs.len() { if xs[i].area() > m { m = xs[i].area(); } }
    return m;
}

struct V<const N: usize> { pub d: [i32; N] }                 // a constant generic parameter

fn main() i32 {
    let a: [Sq; 2] = [Sq { s: 2 }, Sq { s: 3 }];
    let c = a[1].clone();
    println("{} {}", c, c == a[1]);                          // Sq { s: 3 } true
    let v = V::<3> { d: [1, 2, 3] };
    return largest(a) + a[0].twice() + v.d[2] - 20;          // 9 + 8 + 3 - 20 = 0
}
```

* Functions, structs, enums, interfaces and methods can be generic, and a method can have its own
  type parameters (for example `map<U>`). Bounds go in the parameter list (`T: Ord`) or in a
  `where` clause. A type parameter can have a default (`interface Add<Rhs = Self>`), and an
  interface can have associated types (`type Output;`).
* The compiler writes a separate copy of the code for each type you use, also across modules, so
  generic code is as fast as hand-written code.
* `extend<T: Shape> T as Twice { .. }` gives `Twice` to every type that implements `Shape`. An
  extend parameter can also come from the interface's arguments:
  `extend<const N: usize> f32 as Mul<V<N>>` makes `2.0 * v` work for every `V<N>`.
* `@derive(Format, Eq, Clone, Hash, ..)` implements those interfaces from the fields.
  `type_info::<T>()` describes a type at compile time, `@reflect(key = value)` adds metadata to a
  field, and `reflect_string(&v)` prints any struct.

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

A closure that captures variables stores them in a small struct, still without allocation. It
cannot be passed as a plain `fn(..)` pointer, but it can be passed to a generic parameter bounded
by `F: fn(..) ..`. The compiler then calls it directly. The standard library's higher-order
methods (`map`, `find`, `retain`, `and_then`, `filter`, ...) all take this kind of parameter, so
they accept functions, function pointers and closures.

How a closure captures each variable depends on how its body uses the variable:

* **Read only**: the closure keeps a copy. Later changes to the original are not seen. A
  fixed-size array is copied whole.
* **Changed**: if the body assigns to the variable or takes `&mut` of it, the closure keeps a
  pointer, and changes go to the original variable. The original must be `mut`. After
  `let mut n = 0; each(5, fn(x: i32) { n += x; });`, `n` is 10.
* **Owned**: a variable that owns memory (a `String`, a `Vector`, ...) is borrowed when the closure
  goes to an `F: fn(..)` bound. Under a bound written `F: fn move(..) ..`, it moves into the
  closure instead: the original can no longer be used, and the closure frees the value exactly
  once. You can call such a closure as often as you like, but you can pass it on only once.

A function type can bind its own lifetimes (`for<'a> fn(&'a i32) &'a i32`).

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
    return sum + total(&Circle { r: 1 }, &Sq { s: 1 }) - 4;                 // 7 + 4 - 4 = 7
}                                                                           // elements are freed
```

A `dyn` value is two pointers: the data and a table of its methods. There are three forms:

* `&dyn I`: a borrowed view;
* `&mut dyn I`: a mutable view, needed for methods that take `&mut self`;
* `Box<dyn I>`: an owned value that is freed automatically.

Creating a `&dyn` never allocates. Wherever a `&dyn I` is expected, you can pass a `&T` for any
`T` that implements `I`. An interface can be used with `dyn` only if every method takes `self` by
reference, does not mention `Self` anywhere else, and has no generic parameters. The compiler tells
you which rule is broken.

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

### Memory: pointers and references

```superc
fn main() i32 {
    let mut x = 41;
    let p = &mut x as *mut i32; // a raw pointer to x
    unsafe { *p = *p + 1; }     // using a raw pointer requires `unsafe`
    let r: &i32 = unsafe &*p;   // turn the raw pointer into a reference
    return *r;                  // 42 (references need no `unsafe`)
}
```

`*const T` and `*mut T` are raw pointers. `&T` and `&mut T` are references. `Box::<T>::new(v)`
allocates `v` on the heap and frees it when the box goes out of scope. `sizeof(T)` and `alignof(T)`
give a type's size and alignment in bytes.

The compiler cannot check raw pointers or C functions, so these need an `unsafe { ... }` block or
an expression that starts with `unsafe`:

* every raw-pointer operation: dereference, indexing and arithmetic. Raw pointers have no automatic
  dereference: write `(*p).field`;
* a call to an `extern "C"` function, unless its binding is marked `@unsafe(safe)`;
* a call to an `unsafe fn`, and naming an `unsafe fn` or an extern function as a value;
* indexing a fixed-size array with an index that is not a constant (slices and containers check
  their bounds at run time instead).

This marks exactly where the compiler's guarantees stop. Comparing pointers and using references
stay safe.

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

Structs that hold references declare lifetime parameters (`struct View<'a> { s: str<'a> }`), and a
function that returns a borrowed value with no borrowed input names `'static`
(`fn name() str<'static>`). Higher-ranked bounds (`for<'x> fn(&'x T) &'x U`) and generic
associated types are supported. Lifetimes are only used for checking; they do not appear in the
generated C.

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
extern "C" {
    fn malloc(n: usize) *mut void;
    fn free(p: *mut void) void;
}

fn main() i32 {
    let p = unsafe malloc(sizeof(i32)) as *mut i32;
    defer unsafe free(p);   // runs when main returns
    unsafe *p = 42;
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

fn scale(xs: []mut i32, k: i32) {    // []mut T is an exclusive mutable view
    for i in 0..xs.len() { xs[i] = xs[i] * k; }
}

fn main() i32 {
    let mut a: [i32; 4] = [10, 20, 30, 40];
    scale(a, 2);                                  // an array becomes a view of itself
    let t: [i32; 128] = [['a'] = 1, ['z'] = 2];   // set only the listed indexes
    return sum(a[1..3]) + t['a' as usize] - 101;  // 40 + 60 + 1 - 101 = 0
}
```

* `s[lo..hi]` takes a sub-view. `[e; n]` repeats one value `n` times.
* An array's length is part of its type: `[i32; 4]` and `[i32; 8]` are different types, and an
  array can be a generic argument (`Wrap<[i32; 4]>`) or a container element (`Vector<[i32; 4]>`).
* `[]mut T` works like `&mut`: it moves, and nothing else can reach its elements while it is in
  use. Its C parameter is a `restrict` pointer.

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

These are always available, with no import:

* `Box<T>`, `Option<T>`, `Result<T, E>`, `Error`, `Vector<T>`, `Map<K, V>`, `Set<T>`, `String` and
  `str`, ranges and iterators;
* `Array<T, N>` and `StaticVector<T, N>`, which hold their elements inline, with no heap;
* `UInt<N>` and `Int<N>` integers of any width, with the names `u128` to `u1024` and `i128` to
  `i1024`;
* `Float<E, F>` floats with any exponent and fraction width: `f16`, `bf16`, `f128`, `f256`,
  `f8e5m2`, `f8e4m3fn` (`f16::from_f64(1.5)`);
* `Simd<T, N>` and `Mask<N>` vectors (see [SIMD and vector math](#simd-and-vector-math));
* `print`, `println`, `eprint`, `eprintln`, `format`, the asserts, `likely` and `unlikely`, and
  the build constants (`PLATFORM`, `ARCH`, `ENDIAN`, `TEST`, `PROFILE`, ...).

A path that names one of these modules (`iter::count`) still needs `import std::iter;`; the plain
name (`count`) does not.

* `panic("msg")` stops the program with a message. `unwrap()`, `expect(msg)` and `unwrap_err()`
  panic when the value is missing.
* A function that never returns (such as `panic`) can be used where a value is expected, for
  example in one arm of a `switch`.
* Containers and `String` can use a custom allocator: implement the `Allocator` interface and pass
  it to `new_in`, `with_capacity_in` or `from_str_in`.

Iterators chain lazily: `map`, `filter`, `enumerate` and `zip` build a pipeline, and `for`, `fold`,
`for_each`, `count` or `collect` run it. The adapters allocate nothing, and the closures are called
directly. `v.iter()` yields `&T`, and `filter` passes its predicate a reference to that:

```superc
let doubled_sum = fold(map(v.iter(), |x: &i32| *x * 2), 0, |a: i32, x: i32| a + x);
let odd = count(filter(v.iter(), |x: &&i32| **x % 2 == 1));
for p in enumerate(v.iter()) { .. }   // p.0 = index, p.1 = &element
let picked: Vector<i32> = collect(map(v.iter(), |x: &i32| *x + 1));
```

`print`, `println` and `stdio::File` use C stdio, and file system access goes through C bindings
(`ffi/filesystem.spc`).

### SIMD and vector math

`Simd<T, N>` holds `N` lanes of `i8` to `u64`, `f32` or `f64`. `N` is a power of two, and a vector
is at most 512 bits. `Mask<N>` holds one bit per lane. The aliases `f32x4`, `i8x16`, `u64x8`, ...
are always available. An operator works on each lane by the scalar rule, so integer overflow traps
as it does for a scalar, and a scalar operand applies to every lane (`v * 2.0`). Comparisons give a
mask. Every operation gives the same lanes on every target, also at compile time.

```superc
import std::simd;
import std::simd::math as vm;          // precise class; also adds methods such as v.exp()
import std::simd::math::fast as fast;

// The sum of a[i] * b[i]: four lanes at a time, then the tail one by one.
fn dot(a: []f32, b: []f32) f32 {
    let mut acc = f32x4::splat(0.0);
    let n = a.len() - a.len() % 4;
    let mut i = 0usize;
    while i < n {
        acc = simd::load::<f32, 4>(a, i).fma(simd::load::<f32, 4>(b, i), acc);
        i += 4;
    }
    let mut s = simd::reduce_add_ordered(acc);
    for j in n..a.len() { s += a[j] * b[j]; }
    return s;
}

fn main() i32 {
    let a: [f32; 6] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0];
    let b: [f32; 6] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0];
    println("{}", dot(a, b));                    // 21

    let v: f32x4 = [0.0, 1.0, 2.0, 3.0];
    let e = v.exp();                             // precise: at most 1 ULP
    let f = fast::exp(v);                        // fast: relative error at most 2^-11
    let m = v.greater_than(f32x4::splat(1.5));   // Mask<4>: lanes 2 and 3
    println("{} {} {}", e[1], f[1], m.count());  // 2.71828 2.71829 2
    return 0;
}
```

* **Operations**: lane math (`min`, `max`, `abs`, `sqrt`, `fma`, saturating and wrapping forms, bit
  counts), conversions (`cast`, `widen`, `narrow`, `bitcast`), rearrangement (`swizzle`,
  `shuffle`, `reverse`, `interleave_low`, `compress`, `expand`) and reductions (`reduce_add`,
  `reduce_add_ordered`, `reduce_min`, `arg_max`, `simd::dot`). A float reduction names its order.
* **Memory**: `simd::load` and `store` check the slice bounds once. `load_masked`, `store_masked`,
  `gather`, `scatter` and `compress_store` never touch an inactive lane.
* **Vector math**: `std::simd::math` has `exp`, `log`, `pow`, `sin`, `atan2`, `erf` and more, in
  three accuracy classes: `math` (at most 1 ULP), `math::balanced` (at most 3.5 ULP) and
  `math::fast` (relative error 2^-11 for f32, 2^-22 for f64). A result has the same bits on every
  target.
* **Matrix products**: `std::simd::matrix::mul_f32`, `mul_f64`, `mul_i8`, `mul_f16` and
  `mul_bf16` multiply row-major matrices, with SME kernels on Arm CPUs that have SME2.
* **Backends**: the C uses SSE2 to AVX-512 on x86_64, Neon on aarch64, and simd128 on wasm32. An
  operation the target cannot do in one instruction becomes a loop over the lanes.
  `std::simd::x86`, `std::simd::aarch64` and `std::simd::wasm` hold operations that only one
  platform has (AES, CRC, `sdot`, relaxed-simd).
* **CPU detection**: `std::cpu::detect` reports the machine's features
  (`detect::has(cpu::Feature::Sme2)`, `has_level(cpu::Level::V3)`). `@target_feature([..])` lets
  one function use more features than the target baseline; a call to it from outside such a
  function needs `unsafe`, after a run-time check.

`import std::math::all as *;` gives a port of GLM 1.1 (MIT license, `std/math/LICENSE`):
`Vec<T, N>`, `Mat<T, C, R>`, `Quat<T>` and `DualQuat<T>` with aliases (`vec3`, `mat4`, `dvec2`,
`ivec4`), transforms and projections, noise, color, packing, easing, splines and random numbers.
The element type can be any built-in number, `Int<N>`, `UInt<N>` or `Float<E, F>`.
`std::math::fused` adds `LargeVec<T>` and `LargeMat<T>`, whose size is set at run time; their float
products are fused and use SME tiles where the CPU has them.

```superc
import std::math::all as *;

let model = translate(mat4::identity(), vec3::new(2.0, 0.0, 0.0));
let p = model * vec4::new(1.0, 1.0, 1.0, 1.0);                          // vec4(3, 1, 1, 1)
let c = LargeMat::<f32>::identity(64) * LargeMat::<f32>::identity(64);
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

### Platforms and build constants

There is no `#ifdef`. Attributes keep an item only in the builds where it applies:

```superc
@platform(macos | linux)
fn os_name() str<'static> { return "unix"; }

@platform(windows)
fn os_name() str<'static> { return "windows"; }
```

* `@platform(windows|macos|linux|wasm|ios|android)` and `@arch(x86_64|aarch64|wasm32)` work on
  items and on the members of an `extend` or an `extern` block. `|` is a union, `!x` the complement.
* `@when(C)` gates an item, a member or an import on the build flags `TEST`, `THREAD_SANITIZER`,
  `ADDRESS_SANITIZER`, `LOCKDEP` and `OVERFLOW_CHECKS`, with `!`, `&&`, `||` and parentheses.
* The build constants (`PLATFORM`, `ARCH`, `TEST`, `PROFILE`, ...) work in any expression, and an
  `if` on them keeps only the branch that is taken.

### C interop (FFI)

```superc
extern "C" "stdio.h" {
    type FILE;
    fn fopen(path: *const char, mode: *const char) *mut FILE;
    fn fclose(file: *mut FILE) i32;
}
```

`extern "C"` declarations call C functions directly, with no wrapper, so existing C libraries work
as they are. Every call to them needs `unsafe`, unless the binding is marked `@unsafe(safe)`. An
opaque `type` must name a real C type that an included header defines; `@layout(size, align)`
gives it a size and alignment.

`extern "C" "header.h" { .. }` also includes that header in the generated C. If the header is next
to your `.spc` file, the compiler fixes the include path for you; otherwise it is included as
written.

C source files come along automatically. If `native.h` sits next to the `.spc` file, its `native.c`
is found and compiled too:

```superc
extern "C" "native.h" {      // native.c next to it is compiled into the build
    fn native_mix(a: i32, b: i32) i32;
    @import("pt") pub struct pt { pub x: i32, pub y: i32 }   // a struct the header defines
    pub const NATIVE_MAX: i32 = 7;                           // a constant the header defines
}
```

* A `struct`, `union` or `enum` in such a block names the header's C type. List every member in
  the header's order; the C compile checks each size, offset and constant value.
* `@unsafe(const)` on a binding lets constants call it.
* `@blocking` on a binding runs its calls on a separate thread pool (see Concurrency).
* `String::cstr()`, `unsafe str::from_cstr(p)` and `str::from_cbuf(buf)` convert C strings.
* `@c.source("impl.c")` names a C file stored somewhere else.
* `@link("m")` links a library (a value that starts with `-` is passed as is).
* Link flags are collected in `build/<profile>/raw/__ldflags`, one per line, and applied
  automatically.
* The bundled `math`, `pthread` and `dlfcn` modules already declare their libraries, so importing
  them is enough.
* `super-c bindgen` writes these declarations from a C header (see [Other tools](#other-tools)).

Variadic functions work in both directions. You can call a C function that takes `...`:

```superc
extern "C" { fn printf(fmt: *const char, ...) i32; }
```

and you can write one, reading its arguments with `va_list`, `va_start`, `unsafe va_arg(ap, T)`
and `va_end`:

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

### Attributes

C-facing attributes go before an item (and before `pub`). They become C keywords or GNU
`__attribute__`s. The older `@c.` spelling (`@c.noreturn`) is still accepted; only `@c.source` keeps
the prefix:

```superc
@noreturn
fn fail() { /* ... */ }

@packed
struct Header { pub magic: u32, pub version: u16 }

@align(64)
struct CacheLine { pub data: [u8; 64] }

@export("superc_init")     // use exactly this C symbol name
pub fn init() i32 { return 0; }
```

Supported: `inline`, `always_inline`, `noinline`, `cold`, `noreturn`, `align(N)`, `packed`,
`export("sym")`, `import("sym")`, `used`, `unused`. `export` and `import` fix a function's C name.
`@emit_macro` on a generic struct or enum also writes it as a C macro, for use from plain C.

Other attributes:

* `@thread_local` on a `static mut`: one object per OS thread.
* `@tail_recurse`: a function that returns a call to itself becomes a loop in every profile; this
  attribute makes it an error when such a call cannot become a jump.
* `@no_const`: a type whose values never exist at compile time (such as an OS handle), or a
  function that is never `const fn`.
* `@derive(..)`, `@reflect(..)`, `@platform(..)`, `@arch(..)`, `@when(..)`, `@target_feature(..)`,
  `@test`, `@bench`, `@blocking`, `@link`, `@layout` and `@fmt.skip` are described in their
  sections.

```superc
@thread_local
static mut CALLS: u32 = 0;

@tail_recurse
fn gcd(a: u64, b: u64) u64 {
    if b == 0 { return a; }
    return gcd(b, a % b);               // compiled as a jump
}

fn check(err: i32) i32 {
    unsafe { CALLS += 1; }
    if unlikely(err != 0) { return -1; }   // branch hint for the C compiler
    return gcd(48, 18) as i32;              // 6
}
```

`asm("template" : outputs : inputs : clobbers);` inside `unsafe` is GCC extended assembly, and
`asm("...");` at module level is file-scope assembly (gate it with `@platform` and `@arch`). Two
placements break what the compiler can check, so they are written `@unsafe(...)`:
`@unsafe(link_section = "s")` puts a function or a `static mut` in object-file section `s`
(`"segment,section"` on macOS and iOS), and `@unsafe(naked)` makes a function's `asm("...");`
statements its whole machine code, with no prologue or epilogue:

```superc
@arch(aarch64)
@unsafe(naked)
fn add_one(x: i64) i64 {
    asm("add x0, x0, #1\n\tret");
}
```

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
super-c --test --quiet app.spc              # print the failures, the totals and the slowest tests
```

* Each test runs in its own process, so a crash or a failed assertion fails only that test.
  `--test-no-fork` skips `should_panic` tests, because they need their own process.
* `@test(should_panic)` passes only if the test panics. `@test(timeout = 5)` sets the time limit
  of one test. A test that runs out of time prints the stack of every thread.
* A test's output is shown only when it fails. At the end, a `failures:` section repeats each
  failed test's output and how it ended, and a `slowest tests:` list follows.
* `@test_init` builds a fixture that the test receives as a parameter. `@test_free` (optional)
  tears it down. `@test_init(global)` and `@test_free(global)` build one shared environment for the
  whole run; each test gets it as a read-only `&`.
* `assert(cond[, "msg"])`, `assert_eq(a, b)` and `assert_ne(a, b)` print the failing expression,
  both values, and the file and line.
* Tests are left out of normal builds.
* `super-c test --filter=S` builds only the files that hold matching tests.
  `--test-record-durations[=F]` saves each test's time, and `--test-durations=F` names the file
  that `--test-shard` uses to balance the shards (default `tests/durations.tsv`).

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

Benchmarks are `@bench` functions in `bench/`, run with `super-c bench`:

```superc
import std::testing::bench;

@bench
pub fn sum_to_1000(b: &mut bench::Bencher) {
    while b.running() {
        let mut s = 0u64;
        for i in 0..1000u64 { s += i; }
        bench::black_box(s);
    }
}
```

### Finding leaks and double frees

Every compiled program includes a leak checker. It is off until you turn it on, and it works
everywhere, including Apple Silicon where LeakSanitizer is not available:

```sh
super-c lint                   # finds many leaks at compile time
SC_LEAK_CHECK=1 ./app          # at exit, report memory that was never freed, with the allocation site
SC_LEAK_CHECK=fatal ./app      # same, and exit with code 23 if anything leaked (for CI)
```

```text
== super-c leaks: 1 allocation(s), 44 byte(s) ==
leak: 1 allocation(s), 44 byte(s)
    0   app      0x0000000104c8a1a0 String__with_capacity_in__Global + 228
```

Each leak shows one site: the first function outside the allocator that asked for the memory
(after inlining, in an optimized build, the function it was inlined into).

The checker tracks every `malloc`, `calloc`, `realloc`, `free` and aligned allocation in the
generated code. It also catches a **double free**: it prints where the block was first freed and
where it was freed again. With `SC_LEAK_CHECK=1` it skips the second free, so you get a report
instead of a crash; with `fatal` it aborts (exit 134). A `realloc` of a freed pointer is reported
the same way. When the checker is off, it costs one branch per allocation. This repository runs its
whole test suite with `SC_LEAK_CHECK=fatal`, so the compiler and standard library have no leaks.

A program also reports a stack overflow (`super-c: stack overflow`, with the stack size; for a
task, a hint to use `runtime::set_stack_size`) and an illegal instruction (`super-c: illegal
instruction at 0x...`) before it exits.

### Compile-time evaluation

The compiler runs code while it compiles, in constant contexts: `const` and `static` initializers
(local constants too), array lengths, constant generic arguments, `static_assert`, enum values and
`type_info`. A constant context can call any function, and a failure there is a compile error.
Outside a constant context, every call runs at run time. Two flags limit how much work one
evaluation may do:

```sh
super-c app.spc                                          # defaults: about 2M steps, 96 MiB
super-c --const-eval-steps=100000 --const-eval-memory=16M app.spc
```

```superc
struct Header { magic: u32, version: u16 }
static_assert(sizeof(Header) == 8, "Header must stay 8 bytes");
```

* `static_assert(cond, "msg")` works at the top level and inside functions (also per instance of a
  generic function). Its condition must be a constant, and it can use `sizeof` and `alignof` of
  any type that has a size.
* Array indexes in initializers and array lengths may be any constant expression. A length that
  is not constant is a clear error.
* Every struct layout the compiler computes is double-checked in the C output with
  `_Static_assert(sizeof(T) == N, ...)`, so the real C compiler confirms it on the real target.
* Evaluation covers loops, recursion, structs, arrays, enums, generics, floating point (including
  math functions) and heap memory: a function that builds a `Vector` can run at compile time.
* A failed evaluation explains why (for example `division by zero` or `use after free`) and shows
  the compile-time call stack.
* Constants that depend on each other in a loop (`const A = B; const B = A;`) are reported as
  `cyclic constant dependency`. Code that would certainly divide by zero, read out of bounds or use
  freed memory is a compile error.

#### `const fn`

```superc
const fn table_size(bits: u32) usize { return (1u32 << bits) as usize; }

fn evens() Array<u32, 5> {                     // normal functions work too (Vectors, loops, ...)
    let mut v = Vector::<u32>::new();
    for i in 0..5u32 { v.push(i * 2); }
    let mut a = Array::<u32, 5>::new();
    for i in 0..a.len() { a.set(i, *v.at(i)); }
    return a;
}

const N: usize = table_size(8);                // computed at compile time
const V: Array<u32, 5> = evens();              // stored as static data in the C output
```

`const fn` marks a function that must be able to run at compile time. The compiler checks it where
it is defined: if it calls an extern function (one without `@unsafe(const)`), touches a
`static mut`, is variadic (`assert` is), names a `@no_const` type, or fails on every path, you get
an error naming the reason. A `const fn` that fails only on some paths is accepted. A `const fn`
is still an ordinary function at run time, and in a constant context it follows the same rules as
any other function.

* Complex results (structs, arrays, strings, even linked structures) are written into the C output
  as static data. A constant that points to freed memory is an error.
* A constant can have an owning type (`const V: Vector<i32> = [1, 2].into();`). Its data lives in
  static storage, and the compiler rejects moving it out, so it is never freed. Its allocator must
  not keep state; the default one does not.

`super-c lint --const` lists the functions that can be `const fn`. With `--fix`, it marks them.

## Concurrency

The `std::parallel` modules provide a full concurrency toolkit on top of OS threads:

```superc
import std::parallel::atomics as *;
import std::parallel::channel as *;
import std::parallel::runtime as runtime;

fn main() i32 {
    let ch = Channel::<i32>::bounded(8);
    let rx = ch.receiver();                      // a send with no receiver is rejected
    for i in 0..4 {
        let tx = ch.sender();
        launch || { let _ = tx.send(i * i); };   // a coroutine on the worker pool
    }
    let mut sum = 0;
    for _ in 0..4 { sum += rx.recv().unwrap_or(0); }

    let total = Atomic::<u64>::new(0);
    let t = &total;
    parallel for i in 0..1000 {                  // split across all cores
        let _ = t.fetch_add(i as u64, MemoryOrder::Relaxed);
    }
    println("{} {}", sum, total.load(MemoryOrder::SeqCst));   // 14 499500
    runtime::shutdown();
    return 0;
}
```

* **Atomics**: `Atomic<T>` for `i32`, `i64`, `u32`, `u64`, `isize` and `usize`, with an explicit
  memory order on every operation (`Relaxed` to `SeqCst`), and `fence(order)`.
* **Threads**: `thread::spawn` returns a `JoinHandle<T>` (`join`, `is_finished`). `Arc<T>` shares a
  value between threads.
* **`Send` and `Sync`**: the compiler checks that only thread-safe values cross threads. A raw
  pointer is neither, so it cannot. Share through `Arc`; change through an atomic or a lock.
* **Synchronization**: `Mutex<T>`, `RwLock<T>`, `Condvar`, `Once`, `WaitGroup`, `Barrier`,
  `Semaphore`. Locks unlock automatically at the end of the scope. A coroutine that waits does not
  block its thread: the thread runs other work meanwhile. Timed waits and `time::sleep` are
  available.
* **Channels**: `Channel::<T>::bounded(n)` or `unbounded()` makes `sender()` and `receiver()`
  handles, which can be cloned. Sends and receives can wait, time out, or return right away. A
  receive returns `None` when no sender is left and the buffer is empty; a send is rejected when no
  receiver is left. `Sender::close()` closes the channel explicitly.
* **`select`**: waits on up to 16 channel operations at once and runs the first one that is ready,
  with an optional `timeout(d)` or `default` arm.
* **Fair scheduling**: a coroutine that never waits cannot hog its thread. The compiler adds a
  yield check to the loops that a task can reach (a counted loop checks once per 2048 iterations).
* **Async I/O**: TCP (`net::TcpStream`) and UDP sockets, IPv4 and IPv6, on kqueue (macOS), epoll
  (Linux) and `select()` (Windows). A coroutine waiting on the network is parked, so a hundred
  connections cost a hundred parked coroutines, not a hundred threads. `bind`, `connect`, `accept`
  and the UDP calls return `Result<T, IoError>`; `read` and `write` return a byte count (0: the peer
  closed, negative: an error). `io::wait_readable` and `wait_writable` park on a raw descriptor.
  WASI has no sockets.
* **Blocking calls**: `blocking::call` (or `@blocking` on a C function) runs code that blocks on a
  separate thread pool. Each task has an id that panic messages show, `SC_TASK_TRACE=1` traces the
  scheduler, and `runtime::live_tasks()` reports tasks that never finished.
* **Data parallelism**: `parallel for i in a..b { .. }`, `parallel::range`, `each`, `each_mut`,
  `chunks_mut`, `reduce` and `sections` split work across all cores and return when it is done.
  The `_with` forms take `parallel::Options` (`Static`, `Dynamic` or `Guided` schedule, grain
  size). The compiler rejects a closure that could cause a data race. `inline for` copies its body
  once per index of a constant range, at compile time.
* **`launch`**: `launch || { … };` starts a task in the background on a worker pool (one thread
  per CPU by default, or `runtime::set_worker_count(n)`). Each task is a coroutine with its own
  guarded 256 KiB stack (`runtime::set_stack_size`), and idle workers steal work from busy ones. A
  task cannot borrow data from the function that launched it, and it can only hold thread-safe
  values.
* **Cancellation**: `task::CancelSource`, `CancelToken::bind_current()` and `task::TaskGroup`
  (`spawn`, `join`). `lock_c`, `read_c`, `write_c` and `blocking::call_c` are the forms that a
  cancellation interrupts.
* **Shutdown**: a program that uses `launch` or data parallelism calls `runtime::shutdown()`
  before `main` returns. It cancels the tasks that are still live, waits up to 1 s for their
  cleanup, and aborts if one does not respond; `runtime::try_shutdown(..)` returns a
  `ShutdownResult` instead. Call `blocking::shutdown()` and `io::shutdown()` first when you use
  them.
* **Race detection**: `--profile=race` builds with ThreadSanitizer and checks lock order
  (`SC_LOCK_ORDER`). `runtime::set_deterministic(seed)` and `SC_SCHED_SEED` replay a schedule.

## Generated output

`super-c app.spc` writes the C for `app.spc` into `build/debug/raw/` next to the source.
`super-c build` and `super-c release` write `build/<profile>/raw/`.

```text
build/debug/raw/
  super_rt.h  super_rt.c      # runtime: C includes, checked arithmetic, traps, leak checker
  __sc_fwd.h                  # declarations that every generated file includes first
  __sc_t/<type>.h             # one header per type: its definition and a layout check
  app.c                       # one C file per module (a large module also gets app__p1.c, ...)
  app.h                       # the module's prototypes, for C code that calls it
  app__inst.c                 # generic instances the module owns, when it has some
  __std/                      # the standard library modules the program uses
  __sc_registry.c             # reflection table, when needed
  __sc_unity.c                # small program: includes every unit, compiled as one unit
  __sc_pack<k>.c              # larger program: groups of small units, compiled as one unit each
  __ldflags                   # link flags, one per line
  __sc_shards  __sc_manifest  # split counts for the next build, and the list of outputs
```

Includes are relative, so the folder builds with no `-I` flags. `__sc_unity.c` and
`__sc_pack<k>.c` include other units: compile them or their members, not both. The generated C
needs `-funsigned-char`, and `-ffp-contract=off` keeps floating-point results equal to the values
computed at compile time:

```sh
cc -std=c11 -D_POSIX_C_SOURCE=200809L -D_XOPEN_SOURCE=700 -funsigned-char -ffp-contract=off \
  $(find build/debug/raw -name '*.c' ! -name '__sc_unity.c' ! -name '__sc_pack*.c') \
  $(cat build/debug/raw/__ldflags) -o app
```

With a single module, the C names stay plain (no module prefix).

## Environment variables

None is needed for normal use.

### Toolchain

| Variable | Effect |
| --- | --- |
| `SC_STD_DIR` | the `std/` folder to use (`ffi/` is found next to it) |
| `CC` | the C compiler, when neither `--cc=` nor `build.toml` names one |
| `WASI_SDK_PATH`, `WASI_SYSROOT` | the wasi-sdk or WASI sysroot for `--target=wasm` |
| `ANDROID_NDK_HOME`, `ANDROID_NDK_ROOT` | the Android NDK for `--target=android` |

### Build system and caches

| Variable | Effect |
| --- | --- |
| `SC_CACHE_DIR` | where the shared build cache lives (default `~/.super-c/cache`) |
| `SC_NO_CACHE` | turn off the build cache |
| `SC_NO_EMIT_CACHE` | always regenerate the C, even when no source changed |
| `SC_NO_TU_CACHE` | turn off the per-file C cache |
| `SC_BUILD_MEM_BUDGET` | limit the memory that type checking, borrow checking and C generation may use in parallel (`64M`, `2G`; unset means no limit) |
| `SC_LTO` | link-time optimization for one build: `none`, `full`, `auto` or `thin` |
| `SC_NO_LTO_CACHE` | ThinLTO without the linker cache |
| `SC_UNITY_MAX` | the largest program that compiles as one C file (`0`: compile each unit alone) |
| `SC_TIMINGS` | print how long each build phase takes |
| `SC_BUILD_STATS` | append one JSON record per build to this file (`-`: stderr) |

### Extra checks (for compiler development; each runs only when set)

| Variable | Effect |
| --- | --- |
| `SC_FACTS_CHECK` | check that no stage after type checking changes type-checking results |
| `SC_CORE_IR` | re-check every inlined function and every removed bounds check |
| `SC_LAYOUT` | check every type layout against the C layout rules |

### Debug output and switches

| Variable | Effect |
| --- | --- |
| `SC_CEMIT_STATS` | print the time of each compiler phase and constant statistics |
| `SC_INLINE_STATS` | counts of the inliner's decisions per function |
| `SC_BCE_STATS` | counts of removed bounds checks per function |
| `SC_INLINE=0` | turn off the inliner |
| `SC_BCE=0` | turn off bounds-check elimination |
| `SC_SIMD_SCALAR=1` | write every vector operation as a loop over its lanes |
| `SC_SIMD_TRACE=1` | report how each vector operation is written |

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
| `SC_LEAK_CHECK` | the leak and double-free checker: any value except `0` reports at exit; a value starting with `f`/`F` (like `fatal`) also exits with code 23 on a leak and aborts on a double free |
| `SC_TASK_TRACE` | trace coroutines and tasks (`0`: off) |
| `SC_SCHED_SEED` | fix the scheduler's random seed, to replay a race without rebuilding |
| `SC_LOCK_ORDER` | in the `race` profile, check lock ordering: any value except `0` reports violations; `f...`/`F...` aborts |
| `SC_SIMD_LEVEL` | on x86_64, use run-time copy `k` of the vector functions (1-based, in `--simd-dispatch` order; `0`: the baseline) |
| `SC_BENCH_LOG` | a benchmark program also appends its results to this file |

## Status and roadmap

Everything above is implemented and works. Super-C also has:

* operator overloading (`+ - * / %`, `& | ^ << >>`, unary `-` and `~`, compound assignment, `==`,
  `<`, indexing and range indexing, `into` / `try_into`)
* untagged `union`s
* the `?` operator for early return on errors, with automatic error conversion through `From`
* global `static mut` variables
* `_` to discard a value
* unit and tuple structs (`struct S;`, `struct Pair(i32, bool)` with `p.0` and `Pair(1, true)`)
* associated constants (`T::N`)
* `x @ pat` bindings and `..` in patterns (`V(a, ..)`, `S { f, .. }`)
* automatic dereference through `Deref` / `DerefMut`
* float `Eq` / `Ord` / `Hash` (floats can be sorted and used as `Map` keys), plus
  `Vector::sort_by` / `sort_by_key`
* matchertext strings that need no escapes: `M"(say "hi")"`, with `{expr}` placeholders in the
  `M{}"(...)"` form
* hex floats (`0x1.8p3`)
* byte strings (`b"…"`, of type `[]u8`)
* number suffixes (`1u8`, `1.0f32`)

Next, in priority order:

1. **Benchmark against the state of the art**: compare the concurrency runtime with Go, Rust and C,
   and close the gaps.
2. **A self-contained standard library**: port a Go/Odin/Rust-style standard library to Super-C.
   File and console I/O currently go through C.
