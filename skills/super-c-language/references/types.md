# Super-C Type System Reference

## Scalar Types

| Type | Size | Description |
|------|------|-------------|
| `bool` | 1 byte | `true` / `false` |
| `char` | 1 byte | C `char` (`'x'` is a `char` literal; `b'x'` is a `u8` byte literal) |
| `i8` `i16` `i32` `i64` `isize` | 1/2/4/8/ptr | Signed integers |
| `u8` `u16` `u32` `u64` `usize` | 1/2/4/8/ptr | Unsigned integers |
| `f32` `f64` | 4/8 | IEEE-754 floats |
| `c32` `c64` | 8/16 | C `_Complex` floats |
| `void` | 0 | Unit type |
| `never` | 0 | Bottom type (`@c.noreturn` calls) |

Builtin types are **nominal** — `i32` is not an alias for anything. `int` is not a
builtin; there is no implicit integer type. `str` is a prelude struct (a borrowed
`(ptr, len)` view), not a builtin.

## Numeric Literals

```superc
42              // i32 (default integer)
42u8            // u8 suffix
1.0             // f64 (default float)
1.0f32          // f32 suffix
0xFF            // hex
0b1010          // binary
0o77            // octal
0x1.8p3         // hex float
b"hello"        // []u8 (byte string)
```

Lossless widening is implicit (`i32 → i64`, `f32 → f64`). Explicit `as` for narrowing or
cross-kind casts.

## Arithmetic Semantics

- Unsigned arithmetic wraps **at width** (a `u8` wrapping around stays in 0–255).
- Shifts past the bit width and `MIN / -1` for signed types **trap** (undefined behavior
  in C is a defined compile error or runtime trap here).
- Division uses explicit rounding operations when the rule matters.

## Struct Layout

Standard C layout (not auto-rounded to power-of-2). Fields ordered as declared. Use
`@c.packed` for wire formats. Use `@c.align(N)` for cache-line alignment. Verify sizes
with `static_assert(sizeof(T) == N, "...")`.

## Pointers and References

| Syntax | Meaning |
|--------|---------|
| `*const T` | Immutable raw pointer |
| `*mut T` | Mutable raw pointer |
| `&T` | Shared reference (borrow-checked) |
| `&mut T` | Exclusive reference (borrow-checked) |
| `new T(expr)` | Heap allocate |
| `new T { .. }` | Heap allocate with struct literal |
| `sizeof(T)` | Byte size |
| `alignof(T)` | Alignment |

Raw-pointer operations require `unsafe`. Reference operations are safe. `&T` lowers to
`const T*` in C; `&mut T` lowers to `T*`.

## Generics

Monomorphized. Const generics work (`Array<T, const N>`).

```superc
fn id<T>(x: T) T { return x; }
struct Pair<A, B> { pub a: A, pub b: B }

// Turbofish for disambiguation
let p = Pair::<i32, bool> { a: 1, b: true };

// Const generic
let a = Array::<u8, 16>::new();
```

## Closures

| Form | Meaning |
|------|---------|
| `\|x: i32\| x * 2` | Compact closure |
| `fn(x: i32) i32 { return x + 1; }` | Anonymous function |
| `fn(i32) i32` | Function pointer type (no captures) |
| `F: fn(i32) i32` | Generic bound (any callable) |
| `F: fn move(i32) i32` | Ownership-marked bound |
| `dyn fn(i32) i32` | Structural trait object |
| `Box<dyn fn(i32) i32>` | Owned dyn closure |

Capture rules:
- **Read**: value copied at closure creation (default).
- **Mutated**: body assigns/borrows mutably → implicit `&mut` capture. Outer must be `mut`.
- **Owned**: body uses a `Free` value → moved into env. Closure becomes `Free`.

## Trait Objects (dyn)

```superc
fn total(a: &dyn Shape, b: &dyn Shape) i32 { return a.area() + b.area(); }

let mut v: Vector<Box<dyn Shape>> = Vector::<Box<dyn Shape>>::new();
v.push(Box::<Circle>::new(Circle { r: 1 }));
```

A `dyn` value is a 2-word fat pair `{data, vtable}`. Three spellings: `&dyn I` (borrowed),
`&mut dyn I` (mutable), `Box<dyn I>` (owned, drop glue deep-frees). One `static const`
vtable per (type, interface) per TU.

A container element dispatches directly: `v.at(i).area()` (a method call on
`&Box<dyn I>`) goes through the vtable, as does the explicit `(*v.at(i)).area()`.

Dyn-compatibility: every method takes `Self` by reference, no generics on interface or
methods.

## Enums

Payload-less enums lower to C `enum`. Payload-bearing enums lower to tagged unions.

```superc
enum Result<T, E> {
    Ok(T),
    Err(E),
}
```

## Tuples

First-class values, 2–4 elements. Lower to prelude `Tuple2`..`Tuple4`.

```superc
let t = ((1, true), 2);
let a = t.1;          // access by index
let b = (t.0).1;      // nested access needs parens
```

## Unions

Untagged, C-compatible.

```superc
union Value { pub i: i64, pub f: f64 }
```

Owning unions without an explicit `Free` impl are a compile error.

## Type Aliases

```superc
type CharClass = Array<u8, 256>;
```

Alias-extends are **nominal**: `extend CharClass { .. }` adds methods to the alias as a
distinct type.
