---
name: super-c-language
description: "Covers the Super-C language syntax, semantics, and style conventions: types, ownership, generics, closures, interfaces, FFI, testing, const-eval, and the canonical formatting and naming rules. Use when writing, reviewing, or explaining Super-C source files (.spc)."
allowed-tools: Bash Read
---

# Super-C Language

## Agent checklist

- Preserve binding mutability, ownership, and borrow rules.
- Check syntax and semantics in the type references before adding patterns.
- Use `@platform` for target selection and keep generated C portable.
- Format changed `.spc` files with `super-c fmt`.

Super-C is a statically-typed systems language that compiles to readable C99/C11. It
pairs a modern frontend (RAII, borrow checking, generics, closures, compile-time
evaluation, coroutines) with C's portability and performance model.

Source files use the `.spc` extension. The canonical formatter is `super-c fmt` (Wadler,
width 120, 4-space indent). Treat its output as authoritative.

## Quick Reference

See [types.md](references/types.md) for the full type system reference (scalars, structs,
enums, generics, closures, trait objects, slices, arrays, tuples, pointers, references).

See [style.md](references/style.md) for naming conventions, file organization, comment
rules, and the formatting contract.

See [inference.md](references/inference.md) for the local type-inference rules: literal
defaults, safe-conversion ranks, branch joins, generic-argument evidence, const generic
solving, closures, and overload ambiguity.

## Bindings and Mutability

Mutability is a property of the **binding**, not the type.

```superc
let x: i32 = 10;               // immutable binding, explicit type
let mut sum = 0;                // mutable binding, inferred type
let (div, mod) = divmod(p);     // destructuring
```

An immutable binding forbids reassignment, `&mut self` method calls, and `&mut` borrows.
Split initialization is legal: `let x: T; x = v;` (assign-once enforced, binding stays
non-`mut`).

## Functions

```superc
fn add(a: i32, b: i32) i32 { return a + b; }
```

The return type follows the parameter list with no arrow. `void` is the implicit return
type when omitted. The main function signature is `fn main() i32` or
`fn main(args: Vector<str>) i32`.

## Structs and Methods

```superc
struct Counter { pub n: i32 }

extend Counter {
    fn get(self: &Counter) i32 { return self.n; }
    fn bump(self: &mut Counter) { self.n = self.n + 1; }
}
```

Fields are private by default; `pub` exposes them cross-module. One `extend` block per
type at file end. Interface conformance blocks (`extend T as I { .. }`) stay separate.

## Enums and Pattern Matching

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
```

`switch` is exhaustive and usable as an expression. Arms combine alternatives with `|`.
Payload-less enums lower to C `enum`s; payload-bearing ones to tagged unions.

## Ownership and RAII

The destructor interface is `Free` with method `.free()`. Ownership is **derived**: a
struct whose members own memory auto-synthesizes `free`. Owning values move, not copy.

```superc
let a = String::from_str("owned");
let b = a;            // ownership moves to b
// a.len()            // error: use of moved value
```

**Never call `.free()` on a local binding.** RAII auto-drops at scope exit. Use `defer`
only for resources RAII does not manage (file descriptors, C allocations). Use `forget(x)`
for deliberate leaks.

Assignment frees the old value first: `s.name = fresh;` never leaks.

## References and Borrowing

`&T` (shared) and `&mut T` (exclusive) are borrow-checked statically. Non-lexical
lifetimes: a borrow ends at its last use. Field-precise overlap: `p.a` and `p.b` do not
conflict.

```superc
fn longer<'a>(a: &'a String, b: &'a String) &'a String {
    if a.len() > b.len() { return a; }
    return b;
}
```

Lifetime annotations are Rust-style and almost always elided.

## Unsafe

`unsafe` is **required** for:
- Raw-pointer dereference, indexing, arithmetic, field access
- Every call to an `extern "C"` function
- Casting `&T` to `*mut T` (except through `UnsafeCell::get`)

Prefix form (`unsafe expr`) or block form (`unsafe { .. }`). Use `.at()` for safe
bounds-checked container access.

## Generics

Monomorphized, Rust-style. Turbofish in expression position.

```superc
fn id<T>(x: T) T { return x; }
struct Pair<A, B> { pub a: A, pub b: B }
let p = Pair::<i32, bool> { a: id(41), b: true };
```

## Closures

Three capture flavors:
- **Read** — copy at creation (default)
- **Mutated** (`FnMut`) — implicit `&mut` capture, writes land on outer variable
- **Owned** (`FnOnce`) — moves value into env, closure becomes `Free`

```superc
let g = |x: i32| x * 2;                       // compact closure
let h = fn(x: i32) i32 { return x + 1; };     // anonymous function
```

Non-capturing closures lower to plain function pointers. Generic bounds use
`F: fn(..) ..` (or `where F: fn(..) ..`). Ownership-marked bound: `F: fn move(..) ..`.

## Interfaces

```superc
interface Shape {
    fn area(self: &Self) i32;
    fn tag(self: &Self) i32 { return 0; }    // default body
}

extend Circle as Shape {
    pub fn area(self: &Circle) i32 { return 3 * self.r * self.r; }
}
```

Bounds are enforced at instantiation. `where` clauses supported. Dyn dispatch:
`&dyn I`, `&mut dyn I`, `Box<dyn I>` (2-word fat pair, one vtable per TU per type).

## Imports and Modules

```superc
import geom;                 // qualified access: geom::Point
import geom as *;            // unqualified glob
import geom as g;            // alias
```

Imports are public and C-style transitive. Cycles are legal. Prelude types (`String`,
`Option`, `Vector`, `Box`, `Result`, `Map`, `Set`, `str`) resolve unqualified.

## Visibility

Private by default. `pub` on structs, enums, functions, fields, constants, type aliases.
Field privacy is enforced cross-module.

## Slices and Arrays

```superc
fn sum(xs: []i32) i32 {       // []T is a (ptr, len) view
    let mut t = 0;
    for x in xs { t = t + x; }
    return t;
}

let a: [i32; 4] = [10, 20, 30, 40];
```

`[]T` / `[]mut T` lower to prelude `Slice<T>` / `SliceMut<T>`. Arrays coerce to slices.
`[T; N]` is a distinct type.

## Compile-Time Evaluation

Always on. Any call with constant arguments is interpreted at compile time. `const fn`
marks mandatory evaluation.

```superc
const fn table_size(bits: u32) usize { return (1u32 << bits) as usize; }
const N: usize = table_size(8);

static_assert(sizeof(Header) == 8, "Header must stay 8 bytes");
```

## Platform Gating

```superc
@platform(macos)
fn platform_init() { /* macOS-specific */ }

@platform(windows)
fn platform_init() { /* Windows-specific */ }
```

No `#ifdef` in Super-C. Use `@platform(windows|macos|linux)` on items. `--target=` for
cross-compilation.

## C FFI

```superc
extern "C" {
    type FILE;
    fn fopen(path: *const char, mode: *const char) *mut FILE;
    fn fclose(file: *mut FILE) i32;
}

extern "C" "native.h" {     // discovers native.c beside the .spc file
    fn native_mix(a: i32, b: i32) i32;
}
```

An opaque `type X;` renders as its bare C name, so it must name a type some included
header actually defines (`FILE` works because stdio.h is auto-included; an invented name
fails in the C compile). `@c.source("impl.c")` names an implementation elsewhere.
`@c.link("m")` declares a library. Variadics work in both directions (`...`, `va_list`,
`va_start`, `va_arg`, `va_end`).

## Testing

```superc
@test_init
fn setup() Fx {
    let mut v = Vector::<i32>::new();
    v.push(1); v.push(2);
    return Fx { v: v };
}

@test
fn drains(fx: &mut Fx) {
    let mut s = 0;
    while let Some(x) = fx.v.pop() { s += x; }
    assert_eq(s, 3);
}

@test(should_panic)
fn rejects_bad() { panic("boom"); }
```

`assert(cond)`, `assert_eq(a, b)`, `assert_ne(a, b)` are compiler builtins that print
source text, values, and file:line on failure.

## Attributes

| Attribute | Effect |
|-----------|--------|
| `@c.inline` | Suggest inlining |
| `@c.always_inline` | Force inlining |
| `@c.noinline` | Prevent inlining |
| `@c.noreturn` | Mark non-returning |
| `@c.align(N)` | Set alignment |
| `@c.packed` | Pack struct |
| `@c.export("sym")` | Pin exact C symbol |
| `@c.import("sym")` | Import exact C symbol |
| `@c.section("s")` | Place in section |
| `@c.used` | Prevent dead-code elimination |
| `@c.unused` | Suppress unused warnings |
| `@emit_macro` | Export generic as reusable C macro |
| `@fmt.skip` | Exempt from formatter |
| `@platform(P)` | Platform gate |
| `@test` / `@test_init` / `@test_free` | Test harness |
| `@blocking` | Run extern on blocking pool |

## Concurrency

`launch || { .. };` spawns a stackful coroutine on a work-stealing pool. `Arc<T>` for
shared ownership across threads. `Mutex<T>`, `RwLock<T>`, `Channel<T>`, atomics, and
`parallel::range`/`each`/`reduce` for data parallelism. `Send`/`Sync` marker interfaces
enforced at spawn boundaries.

## Standard Library Highlights

| Type | Description |
|------|-------------|
| `String` | Owned growable UTF-8 string |
| `str` | Borrowed string view (non-NUL-terminated; print via `%.*s`, or `.to_string()` then `String::cstr()`) |
| `Vector<T>` | Growable array |
| `Box<T>` | Heap-allocated single value |
| `Option<T>` | `Some(T)` or `None` |
| `Result<T, E>` | `Ok(T)` or `Err(E)` |
| `Map<K, V>` | Hash map |
| `Set<T>` | Hash set |
| `Array<T, N>` | Fixed-size const-generic array |
| `Slice<T>` / `SliceMut<T>` | Fat-pointer views |
| `Tuple2<A, B>` ... `Tuple4` | Tuples (access: `.0`, `.1`) |
| `Arc<T>` | Atomic reference counting |
| `Mutex<T>` / `RwLock<T>` | Synchronization |
| `Channel<T>` | Bounded/unbounded channels |
