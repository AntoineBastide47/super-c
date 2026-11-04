# Generics, Closures and Interfaces

## Generics

Monomorphized, Rust-style. Turbofish in expression position, on a method call too
(`x.m::<u8>(3)`, as `X::m::<u8>(&x, 3)`): its arguments bind the leading generic parameters,
lifetimes bind none, and more arguments than the function declares are an error ("'m' takes 1
generic argument but 2 were supplied"); a field, a function pointer and a closure take none. A
struct, enum or alias takes as many type arguments as it declares, fewer only down to its defaults,
in every type and expression position: `P<i32, u8>`, `P::<i32, u8> { .. }` and a bare `P` outside
a literal's target are "'P' takes 1 generic argument but 2 were supplied" ("takes at most" / "at
least" with defaults).

```superc
fn id<T>(x: T) T { return x; }
struct Pair<A, B> { pub a: A, pub b: B }
let p = Pair::<i32, bool> { a: id(41), b: true };
```

An unbounded type parameter OWNS (Rust's rule): each by-value use moves it, a `T` value left at a
scope exit, an early return, `?` or a cancellation is dropped, and `*r = v` through `r: &mut T`
drops the old value. A second use is "use of moved value"; copying out of `&T` is rejected. A
`T: Copy` bound (inline, in a `where` clause, or through a bound's superinterfaces, as
`Allocator: Copy`) makes `T` copyable. A plain `F: fn(..)` bound copies, `F: fn move(..)` owns.
The instance whose concrete type owns nothing emits no drop code (`f::<i64>` costs nothing).
Raw-pointer reads (`unsafe *p`, `unsafe p[i]`) hand out an owned bitwise copy and raw-pointer
writes never drop the old value, so container internals move slots explicitly.
An array owns what its elements own. `for x in arr` over an owned array consumes it: each element
moves into `x` and is freed at the end of its iteration, and `break`, `return` or an outer exit
frees the elements the loop did not reach. A by-value `for` over a slice, a view or `*r` cannot
move a `Free` element out. A `for` binding is a name or an irrefutable pattern (`for (k, v) in ..`,
`for ((a, _), mut c) in ..`, `for P { x, .. } in ..`, `for _ in ..`): each element destructures like
a `let`, parts no name takes are freed with the element, and elements behind a reference bind by
reference. `for mut i in a..b` makes the induction variable itself mutable: a write to `i` changes
the next iteration. A range loop evaluates its bounds once: a loop over a worklist that grows while
it runs must be `while i < v.len()`, with the increment before any `continue`.

```superc
fn twice<T: Copy>(x: T) (T, T) { return (x, x); }
fn keep<T>(slot: &mut T, v: T) T { return replace(slot, v); }  // move out through a reference
```

## Closures

Capture flavors:
- **Read**: copy at creation (default). A copied `&mut` or `[]mut T` is a unique reborrow the
  closure holds while it lives: the outer binding is unusable until the closure's last use
- **Mutated** (`FnMut`): a non-owning capture the body assigns, borrows `&mut` or calls a
  `&mut self` method on: implicit `&mut` capture, writes land on the outer variable. The
  capture is an exclusive borrow: until the closure's last use, the outer binding cannot be
  read, borrowed, assigned or moved
- **Owned** (`FnOnce`): a `Free` capture moves into the env, closure becomes `Free`; the body
  mutates its own copy
- **Borrowed**: when a closure meets a plain `F: fn(..)` bound, its `Free` captures are borrowed
  instead of owned (implicit `&`, or `&mut` for the ones the body mutates), so the closure owns
  nothing; the outer binding stays borrowed while the closure lives. A captured reference or pointer
  never owns what it points at.

```superc
let g = |x: i32| x * 2;                       // compact closure
let h = fn(x: i32) i32 { return x + 1; };     // anonymous function
```

Non-capturing closures lower to plain function pointers. Generic bounds use
`F: fn(..) ..` (or `where F: fn(..) ..`). Ownership-marked bound: `F: fn move(..) ..`.
Any closure or function, with or without captures, erases to `&dyn fn(..)` or `Box<dyn fn(..)>`
(`Box::new(closure)` too; a boxed env frees its owned captures once). `move` before a closure literal is the closure itself.
A runtime `fn(..)` pointer value does not erase (`&p` included): wrap it in a closure. A call
through a reference to a `dyn fn` value or a function pointer calls the pointee (`v.at(0)()` for
`Vector<Box<dyn fn() i32>>`). A closure that writes its environment (an owned capture it mutates)
and any value of an `F: fn move` bound cannot be called through a shared reference (`f: &F`) or
viewed as `&dyn fn(..)`: take it by value or by `&mut`. A read-only closure and a plain `fn` bound
are callable through `&`.

A block-bodied closure with no written result type takes it from the expected function type when
that is concrete (`let f: fn(i32) i32 = |x: i32| { return x + 1; };`), else from its `return`
values; a path that can reach the end without returning is an error.

A closure parameter's type may name lifetimes, with a function type's meaning
([types.md](types.md)): `|x: &'static i32|` takes only `'static` borrows, and
`|y: &'a i32| v.push(y)` (`'a` the enclosing function's) stores its argument into `v`, so a call's
argument must outlive what `v` points at (a call stores each argument only into the captures the body
stores it into; one the closure owns holds it while the closure lives). Destroying a closure reads
only what the captures it owns hold: a capture taken by reference stays borrowed until the
closure's last call. A reference to the closure's own copy of a capture cannot be stored into a
capture. An unannotated parameter goes into no capture,
`'static` or other argument, and an annotated one into no other argument but one naming the same
lifetime ("a closure argument is stored where it must outlive the closure"). A closure holds its captures by copy: `|| &x` returns a
reference into the closure's own copy and is rejected; capture a reference instead (`let r = &x;
|| r`). The lifetimes of function types are in [types.md](types.md).

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

A conformance block defines only members of its interface: another method is "'helper' is not a
member of interface 'Eq': define it in a plain 'extend' of the type". A superinterface's methods
go in that superinterface's own conformance block.

`Self::f()`, `Self::K` and `Self { .. }` name the implementing type inside an extend or an
interface default body. A call on a concrete receiver chooses by its arguments among the methods
its extends define and the defaults its conformances inherit (see the generics section of
[types.md](types.md)). An interface-qualified call (`Shape::area(&c)`, `Twice::base(&x)`)
takes its implementing type from the receiver argument, a type parameter's bound included; among
several conformances of the receiver to one generic interface the expected result type chooses
("ambiguous call to 'conv': 'P' conforms to 'Conv' with several arguments that fit" without one).

`@derive(I, J)` on a struct or enum declaration expands to `extend<params> T<params> as I {}` per
interface, with the declaration's lifetime and generic parameters, their bounds, and its `@platform`,
`@arch` and `@when` gates; it takes any interface, markers (`Copy`, `Send`) included. Use it for every
empty conformance (references/style.md). A union cannot take it.

The prelude defaults of `Clone`, `Default`, `Eq`, `Ord`, `Format` and `Hash` (what `@derive` and an
empty `extend` use) work field by field, or by an enum's active variant and its payloads. An enum
must define `clone` and `default` itself, and a union also `eq` and `cmp`; inheriting one of those
defaults is a compile error at the conformance. Each field, or each payload of each variant, must
meet the interface the default walks with: the build names the one that does not ("payload 1 of
variant 'A' of 'E' is 'NoD', which does not satisfy the bound"), however the default is reached
(directly, through a bound, or through another type's default). A copy a guard skips
(`if p.index > 0`, a variant-tag test) owes nothing. The `Hash` default is consistent only with
the `Eq` default: a type that writes its own `eq` must write `hash_into`.

Bounds are enforced at instantiation, with a generic interface's arguments: `T: I<bool>` needs a
conformance as `I<bool>`, a type parameter meets a bound only through its own bounds, and a call
through the bound runs that conformance's methods, operators included (`t + 5` for
`T: Add<i32>`), with its associated types as `T::Output` and a bound able to fix them
(`T: Add<Output = T>`; see the generics section of [types.md](types.md)). `where` clauses
supported. Dyn dispatch:
`&dyn I`, `&mut dyn I`, `Box<dyn I>` (2-word fat pair; `dyn I<T>` erases only through the
conformance with exactly those arguments, whose methods its vtable calls; a superinterface's
methods, `B: A<i32>` included, are in the vtable under their arguments, and a dyn value upcasts to
a superinterface). A
`Box<T, A>` erases to `Box<dyn I>` when `A: Default`; its table frees through `A::default()`.
The erasure applies to each element of an array, repeat or tuple literal against the element type
its context writes (`let ds: [&dyn I; 2] = [&a, &b]`, `[]&dyn I` and `([&dyn I; 2], i32)` included).
A tuple takes the types its context writes for its elements, also as a call argument, a method
argument or a struct field: a literal widens (`(1, 2)` for `(i64, u8)`), a closure becomes the
written `fn`, and a nested array or tuple erases. `&dyn I`
and `&mut dyn I` borrow their payload and are never freed; only `Box<dyn I>` owns it. An array
converts to a slice implicitly; `a as []T` is an error.
