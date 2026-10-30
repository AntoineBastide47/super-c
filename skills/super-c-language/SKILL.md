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

Super-C is a statically-typed systems language that compiles to readable C11. It
pairs a modern frontend (RAII, borrow checking, generics, closures, compile-time
evaluation, coroutines) with C's portability and performance model.

Source files use the `.spc` extension. The canonical formatter is `super-c fmt` (Wadler,
width 120, 4-space indent). Treat its output as authoritative.

## Quick Reference

See [types.md](references/types.md) for the full type system reference (scalars, structs,
enums, generics, closures, trait objects, slices, arrays, tuples, pointers, references).

See [operations.md](references/operations.md) for the normative result of every scalar,
conversion, float, pointer, atomic and control operation (wraps, traps, defined value, or
undefined), identical at compile time and at run time.

See [style.md](references/style.md) for naming conventions, file organization, comment
rules, and the formatting contract.

See [inference.md](references/inference.md) for the local type-inference rules: literal
defaults, safe-conversion ranks, branch joins, generic-argument evidence, const generic
solving, closures, and overload ambiguity.

See [simd.md](references/simd.md) for the vector and mask types `Simd<T, N>` and `Mask<N>`:
their rules, layout, lane access, mask operations and diagnostics, and for CPU features,
`@target_feature`, the `@simd_impl` backend files, run-time detection and `detect::dispatch`, and
the architecture modules `std::simd::x86`, `std::simd::aarch64` and `std::simd::wasm`.

## Bindings and Mutability

Mutability is a property of the **binding**, not the type.

```superc
let x: i32 = 10;               // immutable binding, explicit type
let mut sum = 0;                // mutable binding, inferred type
let (div, mod) = divmod(p);     // destructuring
```

An annotation on a destructuring binding types its names: `let (x, y): (i32, i32) = (a, b);`
widens `i16` values as `let t: (i32, i32) = (a, b);` does. A tuple a call returns does not convert:
its annotation must name its element types (`mismatched types: expected '(i32, i16)', found '(i16,
i16)'`).

A local whose initializer leaves generic arguments open keeps them open, and its later uses in the
same body fill them in: `let mut v = Vector::new(); v.push(x);`, `let mut o = None; o = Some(3);`,
`let c = |a| a + 1; c(2);` (a closure parameter takes its type from the first call). An unsuffixed
literal gives no evidence and takes the final type (`v.push(1); v.push(2u8);` is `Vector<u8>`), else
its default. Two typed uses that disagree are "conflicting types for 'T' of 'v'" at the second, a
member of a value whose whole type no use has given yet is "the type of 'x' must be known here", and
a parameter no use fixes stays "cannot infer the generic argument". `_` leaves one type to this
inference in a local's annotation (`let v: Vector<_> = ..`) and in a call's type arguments
(`f::<_, u8>(..)`) only. Parameters, results, fields and constants are never inferred.

An immutable binding forbids reassignment, `&mut self` method calls, and `&mut` borrows.
The rule reaches through a user `Deref`: `*b` is an assignable place when `b`'s type defines
`deref_mut` (`Box<T>`); `*b = v` and `&mut *b` call `deref_mut` and need `b` mutable. A type
with `deref` only gives a read-only `*b`.
Split initialization is legal: `let x: T; x = v;` (assign-once enforced, binding stays
non-`mut`).

## Functions

```superc
fn add(a: i32, b: i32) i32 { return a + b; }
```

The return type follows the parameter list with no arrow. `void` is the implicit return
type when omitted. The program entry is the root module's top-level `main`, declared
`fn main() i32` or `fn main(args: Vector<str>) i32`. A `main` in another module, or a method
named `main`, is an ordinary function of any signature.

A parenthesized return list (`fn f() (A, B)`) returns the tuple `(A, B)`: a call is an ordinary
value (`let t = f();`, `assert_eq(pair(), (1, 2))`, `f().0`), and `let (a, b) = f();` destructures
it. `return (a, b);` returns the tuple, and so does its sugar `return a, b;`. Named results (`(a: i64, b: i64)`) bind
`a` and `b` in the body, and a bare `return;` returns their tuple. A register type (`@value`) is no
tuple element, so it is never one of several results.

A block in value position (an `if` or `else` branch, a `switch` arm block, `{ .. }`, `unsafe { ..
}`) is a value block: its value is its last expression, written without `;` (`{ x + 1 }`); an
assignment there is no value. A value block's last `if` with an `else`, `switch` or block is its
value too (`{ prep(); if c { 1 } else { 2 } }`). A block whose last statement is no such expression
(`{ x + 1; }`) is `void`. Where a value is expected (a context type, a `let` initializer, a branch or
arm the others give a value) such a last `;` is "this block ends in ';', so it has no value: remove
the ';'".

A function or closure body gives its results with `return`: a last expression without `;`
(`fn k() i32 { x + 1 }`) is "a function body gives its result with 'return': write 'return x +
1;'".

A direct call of a function to itself whose result the function returns as it is becomes a
jump in every profile, so the recursion runs in one frame. It stays a call when a drop, a
`defer` block or a cancellation check runs after it, when it calls another instance (other
generic arguments), when an argument may hold a borrow of a local of the call, or when the
function takes a raw address of a local. `@tail_recurse` on the function makes each such call
an error that names the reason; a call to the function from one of its closures and a function
that never calls itself are errors too. A function returning a tuple converts when it returns the
call's tuple, also rebuilt from its elements in order (`let (a, b) = f(..); return (a, b);`).

A function or closure with results cannot reach the end of its body ("function 'f' can reach the
end of its body without returning a value"): every path ends in a `return`, a call of a `!` or
`@noreturn` function, a `loop` no `break` leaves, or an `if`, `switch`, block or `unsafe` block
whose every way out is one of these. A `while` or a `for` can run no iteration, so it does not end
a path.

`return pair();` returns the call's tuple: its type must be the function's result type exactly (no
widening: "mismatched types: expected '(i32, i32)', found '(i32, i64)'").

## Structs and Methods

```superc
struct Counter { pub n: i32 }

extend Counter {
    fn get(self: &Counter) i32 { return self.n; }
    fn bump(self: &mut Counter) { self.n = self.n + 1; }
}
```

Fields are private to their file by default, as items are: code in the declaring file names them, code in
another file does not; `pub` exposes them everywhere. One `extend` block per
type at file end. Interface conformance blocks (`extend T as I { .. }`) stay separate. A method's
`self` is the extend's target (`Self`), a reference to it, or a raw pointer to it.

A method or associated constant is defined once for any one instance of its type: a second item of
the name (a method or a constant, any signature) in a plain `extend` that applies to a common
instance, in any module, is "duplicate definition of 'f' for 'X'" at the later one. Disjoint extends
(`extend P<u8>`, `extend P<i32>`) and distinct conformances may each define the name (see the
generics section of [types.md](references/types.md)).

A struct literal names each field once ("field 'x' is initialized twice"). A field it omits is
zero-filled, so it must be visible at the literal and its type valid as zero bytes: scalars, raw
pointers, vectors, arrays, unions and structs of such, an enum without payloads or written
discriminants, an extern opaque type with a layout (`@layout`, `@value`: C's static
initialization), and a type asserting `Zeroable` (`unsafe extend T as Zeroable {}`: its private fields
hold no invariant at zero, each field's type still checked), as std's `str`, `String`, `Vector`, `Array`,
`Map` and `Set` do ("asserting 'Zeroable' requires 'unsafe extend'"). Else it is "missing field 'f': an
omitted field is zero-filled, and zero is not a valid value of its type here" (a `&T`, `Box`, `fn`
field, ...). A union literal sets one member.
`unsafe zeroed::<T>()` is the all-zero value of any type. The address of a zero-sized field
(`&s.tail` of a `[T; 0]` field) is its offset inside `s`; the address of any other zero-sized value
is a shared sentinel.

An item name may not contain `__` after its leading underscores or start with `__sc`, and a type
name may not start with `ptr_`, `ptrm_`, `slice_`, `dyn_`, `dynm_`, `dynb_`, `arr<N>`, `fn<N>`,
`fnm<N>` or `fnt<N>`: the generated C symbols use these spellings ("the name '..' is reserved for
the symbols the compiler generates").

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

`switch` is exhaustive and usable as an expression. A `switch` that starts a statement ends at its
`}`, as `if` and `loop` do (a `;` after it is "a 'switch' statement ends at its '}': remove the
';'"): its arms are statements, so arm values
of different types do not join, and `switch x { .. }.len()` there does not continue as an
expression. Arms combine alternatives with `|`.

A variant is written bare (`Circle(r)`, `None`) or qualified (`Shape::Circle(r)`, `Option::None`)
in values and in patterns. A bare value resolves through the expected type (a return, an annotated
`let`, an argument, a field, an array element, the other side of `==` or `!=`, an assignment
target); without one only the prelude's `Some`, `None`, `Ok` and `Err` resolve, and a variant of
another enum is "cannot find value". A local or an item that a bare variant in scope also names is
an error that names both ("'Unit' names both a local and the variant 'Shape::Unit': rename one"). A
pattern's bare variant resolves through the matched type; a qualified one must name a variant of
the matched type ("pattern 'F::A' does not name a variant of the matched type 'E'"). A variant has
priority over an associated constant of the same name. A qualified variant value whose bare name
resolves to it is a lint warning with a fix ("write 'Some': the variant resolves without its enum
here"); a unit-variant pattern (`None =>`) binds no local, so `None => None` is the variant. A qualified path without a payload that
names no variant is a constant pattern: a builtin limit (`i64::MAX`) takes
the matched type like a literal, and an associated constant (`Lim::HI`) keeps its type, which must be
the matched type or widen to it; a range bound may name a constant (`0..=LIMIT`). Integer values and
ranges cover their type: `i64::MIN..=-1` and `0..=i64::MAX` make an `i64` switch exhaustive, and a
`_` after such a cover is an unreachable arm. A tuple
pattern (`(a, _)`, `(Some(x), mut n)`) destructures a tuple in arms, `if let` and `while let`.
A pattern matched against a reference (`&T` or `&mut T`, at the top or nested, as in
`Option<&E>`) reads the referent: literal and range sub-patterns test the value, and
names bound inside bind by `&` (or `&mut` through a `&mut` with no `&` above it), so
nothing is moved out through the reference. A literal pattern and each range bound take the
matched value's type like `let x: T = lit` does: `9223372036854775808..` against a `u64` is a `u64`,
and `300` against a `u8` is "integer literal is out of range for 'u8'". A method name without a call
(`v.m`) is an error; `Type::m` is a function value.
Payload-less enums lower to C `enum`s; payload-bearing ones to tagged unions whose tag is
one byte when the enum has at most 256 variants and no explicit discriminant, and the
4-byte C enum otherwise. A niche enum has no tag: see Enums in `references/types.md`. A payload-less variant of either kind may take an explicit
discriminant (`enum P { A(i32), B = 9, C }`: tags 0, 9, 10); the stored tag, matches,
`type_info` and the derived `Ord` (discriminant first, then payloads) use it. Discriminants
of one enum must differ and fit i32; an `extern` enum is exempt. Only a payload-less
enum casts to an integer.

## Ownership and RAII

The destructor interface is `Free` with method `.free()`. Ownership is **derived**: a
struct whose members own memory auto-synthesizes `free`. Owning values move, not copy. A
conditional `extend<T: Free> X<T> as Free` covers only the instances whose `Free`-bounded
arguments own memory (`X<String>`); any other instance (`X<i32>`) still derives its `free` from
its owning members, and an explicit `.free()` on it runs that derived destructor.

```superc
let a = String::from_str("owned");
let b = a;            // ownership moves to b
// a.len()            // error: use of moved value
```

**Never call `.free()` on a local binding.** RAII auto-drops at scope exit. Use `defer`
only for resources RAII does not manage (file descriptors, C allocations). Use `forget(x)`
for deliberate leaks. At a scope exit the defers run (LIFO) before the scope's locals drop,
also locals declared after the `defer` (a `let _ = f()` result is one): a deferred signal
(`defer wg.done()`) fires before them, so put locals that must drop first in an inner block.

A `Box` is never null, as in Rust. `zeroed` cannot build a value that holds one by value ("'zeroed'
cannot build a value that holds a Box"; in generic code the instance panics), and a struct literal
cannot omit a field that holds one. An explicit `.free()` (the `Free` destructor) of a value that
may hold a Box, which includes any type parameter, is an error through a reference outside a
`free` method ("cannot free a value that holds a Box through a reference: its owner frees it
again"). Free an owned value (`fn release<T>(x: T) {}` frees `x` on return), assign a new value
(`*r = fresh;` frees the old one), or free through a raw pointer in `unsafe` code. Build a value part by part in an
`Uninit<T>` (raw stores into `u.value`, then `unsafe u.value`), as the derived `Clone` and
`Default` do.

Assignment frees the old value first: `s.name = fresh;` never leaks. A store through a raw
pointer (`unsafe *p = v`, also into an element `p[i]`) frees nothing: it may write into fresh,
uninitialized storage. To replace an initialized value there, store through a reference
(`*unsafe &mut *p = v`).

A by-value pattern cannot move an owning part out of a value whose type has a user `free`
(`switch v { W { s } => .. }` for `extend W as Free`): "cannot move a part out of a value whose
type implements Free: its 'free' would not run; bind by reference or move the whole value". A
`free` that can accept a task cancellation runs with cancellation masked, so it completes.

`Copy` (a marker interface) names the values a use copies instead of moving. It is derived from
the type's shape: scalars, `str`, raw pointers, `&T`, `&dyn I`, `fn` pointers and closures that own
nothing, arrays of Copy, and aggregates that are not `Free` whose members are all Copy. `&mut T`,
`Box<dyn I>` and every owning value are not Copy. A written `extend X as Copy {}` is accepted only
where the derivation holds (`extend String as Copy {}` is rejected). A type parameter is Copy
when its bounds reach `Copy`. A method's `where T: Copy` on its extend's `T` holds in that
method only, closures included.

## References and Borrowing

`&T` (shared) and `&mut T` (exclusive) are borrow-checked statically. Non-lexical
lifetimes: a borrow ends at its last use. Field-precise overlap: `p.a` and `p.b` do not
conflict, and a method call may pass `&mut self.field` next to its `&mut self` receiver
(`self.mg.ctype(m, t, decl, &mut self.out)`); the callee must then not reach that field
through the receiver. Borrowing one value twice in one call (`s.push_str(s.as_str())`)
is rejected.

```superc
fn longer<'a>(a: &'a String, b: &'a String) &'a String {
    if a.len() > b.len() { return a; }
    return b;
}
```

Lifetime annotations are Rust-style and almost always elided. Lifetime parameters come first
in a generic list (`<'a, T>`; `<T, 'a>` is "lifetime parameters must come before type
parameters"). A result whose lifetime
the signature ties to an input (a named lifetime, or elision to `self` or to the single
borrowing input) keeps that input borrowed while the result is live, through a `&mut`
parameter and for receivers whose type holds borrows too: `let r = a.get(0); a.put(5);
use(r)` is rejected. An accessor that returns data reached through a raw-pointer field is
not tied to `self`; it names an unbounded lifetime:

```superc
fn p<'a>(self: &Self) &'a Package { return unsafe &*self.pkg; }
```

The `str` sub-view methods (`slice`, `trim`, `split`, `lines`, ...) return `str<'a>` of
the viewed text, not of the `&str` receiver.

A returned slice (`[]T`, `str`, any lifetime-generic aggregate) elides like `&T`: with no
`self` receiver and not exactly one input lifetime position, the result must name its
lifetime (`fn pick<'a>(a: []'a u8, b: []u8) []'a u8`, `fn names() []'static str<'static>`).
Positions inside tuples and type arguments count (`Option<(i32, &i32)>`); `Self` names its
extend's lifetimes and is never elided, in the method's own body and at every call: in
`extend<'a> W<'a>`, `fn new(r: &'a i32) Self` keeps `r`'s referent borrowed by the result,
and `fn put(self: &mut Self, x: &'a i32)` stores `x` into the receiver. An elided input
lifetime is its own region: returning `b: &u8` as `&'a u8`, or as a `self` method's elided
result, is rejected.

A parameter's regions flow through the body like Rust's region constraints, flow-insensitively:
a local of a struct or tuple type keeps one region set per member, so `let t = (a, b); return
t.0;` returns `a`'s region, and a struct built or copied member by member is checked member by
member against a struct result or a struct stored through a parameter (`P { x: b, y: a }` as
`P<'a, 'b>` is rejected). A member written twice holds both values' regions, as a Rust local's
type does. A `&'static` parameter keeps its argument borrowed for the whole program, an
implicit autoref for a `self: &'static Self` receiver included: `s.k()` on a local is rejected,
on a constant it is accepted.

A field names a lifetime its type declares (or `'static`) at every lifetime position: `&'a T`,
`[]'a T`, `str<'a>`, `Slice<'a, T>`, inside tuples and type arguments too.

`&mut x` needs `x` initialized and not moved: it is a use of `x` ("use of possibly uninitialized
value", "use of moved value"). There are no out-parameters through `&mut`: initialize first.

A `dyn` value holds borrows its type does not show. `&'a dyn I` (and `&'a mut dyn I`) is a
reference for every lifetime rule: elision, `'static`, named ties, variance (covariant in `'a`,
invariant in the interface's arguments), and a field of that type names its lifetime. An owned
`dyn I` (`Box<dyn I>`) in a signature holds only `'static` borrows, Rust's default object
lifetime: a returned or stored `Box<dyn fn()>` cannot capture a borrow of a local.

A store through any reference to a container records the stored borrow in the container: a
`&mut` held in a local, a reborrow of it (`let r2 = &mut *r;`), or a copy of either. After
`let r = &mut v; put(r, &a);`, `a` stays borrowed while `v` is live. A borrow of a local
stored into storage a `&mut` parameter reaches is rejected: it outlives the call. A call that
stores one parameter into another's data follows the callee's signature: the stored parameter's
lifetime must be declared to outlive the storage's (`fn fill<'x>(w: &mut Vector<&'x i32>, a: &'x i32)
{ put(w, a); }`; with `a: &i32` it is rejected).

## Unsafe

`unsafe` is **required** for:
- Raw-pointer dereference, indexing, arithmetic
- An unchecked index of a fixed array `[T; N]`: outside `unsafe` a run-time index is checked and
  panics when out of bounds ("index out of bounds", as `[]T` indexing), and under `unsafe` it is
  unchecked, as a raw pointer's. A constant index is checked at compile time at every nesting
  level; against a symbolic length every instance checks it: `a[2]` for `a: [i32; N]` is "index 2
  is out of bounds for an array of length 2 for N = 2" where `N = 2` is instantiated. Slicing an
  array (`a[lo..hi]`) checks its bounds at run time ("range out of bounds") and needs no `unsafe`.
  A field of a concrete instance has the instance's length (`Buf<i32, 4>.d` is `[i32; 4]`)
- Every call to an `extern "C"` function
- A `Slice`/`SliceMut` literal (`unsafe SliceMut::<T> { ptr: p, len: n }`, Rust's
  `from_raw_parts`), and a write or `&mut` of a view's `ptr` or `len` field ("writing a field of a
  slice view")
- Naming an `unsafe fn`, or an `extern "C"` function without `@unsafe(safe)`, as a value
  outside a call: a `fn` pointer is called without `unsafe`
- Casting `&T` to `*mut T` (except through `UnsafeCell::get`)
- Reading a variadic argument with `va_arg`

A `&mut` reference is exclusive also for unsafe code: reaching its referent through any
other path while it is live is undefined behavior (its C parameter is `restrict`, see
`types.md`). A `[]mut T` view is exclusive the same way (Rust's `&mut [T]`). A `&T`, a `[]T` and a
`str` are read-only the same way: while one is live, changing its referent's or elements' bytes
outside an `UnsafeCell` is undefined behavior, also through `&T as *const T as *mut T` (the
optimizer keeps their loads across every write). Lazy state a `&self` method fills goes in a cell
(`std::mem::cell::Cell`, `UnsafeCell`). A `&mut` or a
`[]mut T` copied into a local of its own kind moves (`let t = s;`); passed to a call it is
reborrowed for the call, and for as long as the result lives when the signature ties them
(`let d = r.index_mut(0); let n = r.len(); *d = 1` is "cannot use this value while it is
mutably borrowed"); stored into a field, a struct, tuple or variant literal, or a closure, it
is reborrowed for as long as that holder lives, so the source is unusable until then
(`let w = S { a: r }; h(r, w.a)` is "cannot use this value while it is mutably borrowed"). Two
arguments of one call cannot reach the same storage when one of them hands it over mutably (a `&mut`, a `[]mut T`, or a `&mut` autoref): `h(r, r)`, `h2(r, r)` with
`h2(a: &mut i32, b: &i32)`, `f(s, s)` for one `[]mut` view and `(*r).m(r)` are "cannot borrow this
value as mutable while it is already borrowed as ..." errors. A reference erased to a raw pointer
in the same call (`h4(r, r as *mut i32)`) is not checked. A reference going into a raw-pointer slot
(an argument, a struct field, an array or tuple element) becomes the pointer there: the borrow is
checked where it is made (it reads the place, so the place must be initialized) and ends at once, so
`f(&mut a[0], &mut a[1])` with `*mut` parameters is accepted.

A reference casts only to a pointer to its own referent type (`&x as *const T` for `x: T`).
Viewing the memory as another type is a second cast, from that pointer:
`(&mut x as *mut i32) as *mut usize`, `(&a as *const [u8; 4]) as *const u8`, or the element's own
address `&a[0] as *const u8`. A single cast that changes the type is "a reference to 'i32' casts only
to a pointer to 'i32': cast to '*mut i32' first, then to '*mut usize'": a reinterpretation, and the
undefined behavior a wrong one causes, is always written out.

There is no auto-dereference through a raw pointer (the Rust rule): for `p: *mut T`,
`p.f` and `p.m()` are errors; write `unsafe (*p).f` and `unsafe (*p).m()`. A method whose
`self` is the raw pointer type itself applies to `p` directly. The explicit form keeps the
receiver a place: `(unsafe (*p)).m()` calls a `&mut self` method on the pointee, never on a
copy. Auto-deref through references, `Box` and `Deref` is unchanged.

Prefix form (`unsafe expr`) or block form (`unsafe { .. }`); the prefix covers the whole
postfix chain after it, so `unsafe (*p).a.b()` needs one `unsafe`, and its operand takes the
expected type of the whole (`let t: (i32, i32) = unsafe (a[i], a[j]);`). Use `.at()` for safe
bounds-checked container access.

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
([types.md](references/types.md)): `|x: &'static i32|` takes only `'static` borrows, and
`|y: &'a i32| v.push(y)` (`'a` the enclosing function's) stores its argument into `v`, so a call's
argument must outlive what `v` points at (a call stores each argument only into the captures the body
stores it into; one the closure owns holds it while the closure lives). Destroying a closure reads
only what the captures it owns hold: a capture taken by reference stays borrowed until the
closure's last call. A reference to the closure's own copy of a capture cannot be stored into a
capture. An unannotated parameter goes into no capture,
`'static` or other argument, and an annotated one into no other argument but one naming the same
lifetime ("a closure argument is stored where it must outlive the closure"). A closure holds its captures by copy: `|| &x` returns a
reference into the closure's own copy and is rejected; capture a reference instead (`let r = &x;
|| r`). The lifetimes of function types are in [types.md](references/types.md).

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
[types.md](references/types.md)). An interface-qualified call (`Shape::area(&c)`, `Twice::base(&x)`)
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
(`T: Add<Output = T>`; see the generics section of [types.md](references/types.md)). `where` clauses
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

## Imports and Modules

```superc
import geom;                 // qualified access: geom::Point
import geom as *;            // unqualified glob
import geom as g;            // alias
```

Imports are public and C-style transitive, so there is no `pub import`. Cycles are legal. Prelude types (`String`,
`Option`, `Vector`, `Box`, `Result`, `Map`, `Set`, `str`) resolve unqualified.

`import a::b;` loads `<root>/a/b.spc`, else the directory index `<root>/a/b/b.spc`, through the import roots (the
project, its `src/`, std, `ffi/`); when neither exists and `<root>/a/b/` is a directory, the import is an implicit
index: a module that glob-imports every `.spc` file directly in the directory (in name order; subdirectories stay
modules of their own). An explicit index decides what its module exposes through its own imports. A name that two
files of an implicit index declare is "'x' is ambiguous: two files of directory module 'a::b' declare it" where it
is used, not where the directory is imported.

A glob import re-exports: `m::x` names `m`'s own item `x`, else the first `x` that a module `m` glob-imports (or one
of that module's imports) declares. The unused-import lint reports a glob import only in a module no other module imports.

An unqualified name the module does not declare is looked up in its glob imports first, then in
the prelude: a glob-imported `String` or `dot` shadows the prelude's, as a declaration does. A
glob import without an alias (`import m::qq as *;`) also makes its last segment a module
qualifier, but a type in scope of that name (declared, imported or glob-imported) wins: when
module `m::qq` declares `pub type qq = Q;`, `qq::one()` calls `Q::one`. An explicit `as` alias
always names the module.

## Visibility

| Spelling | Item visible to | Field visible to |
| --- | --- | --- |
| none | its file | its file |
| `pub(module)` | the files whose path is the declaring file's path minus its last segment, or starts with it and `::` (a directory index's whole path; a root-level file's: its package) | the same |
| `pub(package)` | the files of its package: the project (root, `src/`, `tests/`, `bench/`), std, `ffi/`, or one `vendor/<name>` | the same |
| `pub` | every file | every file |

The modifier applies to structs, unions, enums, functions, methods, constants, statics, type aliases, interfaces and
fields. A project whose `build.toml` sets `std_internals = true` sees std's `pub(package)` items (unstable
internals such as `std::platform`); without it naming one is an error whose note names the key. Enum variants and
interface members take the visibility of their declaration; a conformance (`extend T as I`) has none. A method or
associated constant is at most as visible as its type. A signature, field type, alias target or bound of an item
visible beyond its file names no type less visible than the item ("'T' is less visible than the pub item that names
it"); an associated type has its interface's visibility. A call that lowering synthesizes (format sugar, `launch`)
reaches its target whatever its level. The levels are source rules: `pub(module)`, `pub(package)` and `pub` emit the
same C.
[migration.md](references/migration.md) maps the levels and the std contracts to their Go, Rust, Odin and C++
names.

## Slices and Arrays

```superc
fn sum(xs: []i32) i32 {       // []T is a (ptr, len) view
    let mut t = 0;
    for x in xs { t = t + x; }
    return t;
}

let a: [i32; 4] = [10, 20, 30, 40];
```

`[]T` / `[]mut T` lower to prelude `Slice<T>` / `SliceMut<T>`; `[]'a T` / `[]'a mut T` name
the lifetime (`Slice<'a, T>` / `SliceMut<'a, T>`), which binds right after `[]` and before
`mut`, as after `&`. `[]mut T` follows Rust's `&mut [T]`: it is not `Copy`, it moves, reborrows
and conflicts as a `&mut` does (see Unsafe), and building a view from raw parts or writing its
`ptr` or `len` needs `unsafe`. A by-value `[]mut T` parameter reaches C as a `restrict` element
pointer and a length (`types.md`). The compiler's own sources (`src/`, `std/`, `ffi/`) spell the named form
`Slice<'a, T>` until a release parses the sugar. Arrays coerce to slices; the view borrows the
array like `&a` (`&mut a` for `[]mut`) and never moves it: the array must outlive the view and
cannot be written, moved or viewed mutably while the view is live. A `[]mut T` coerces to `[]T` (a
generic `[]T` parameter infers `T` from it); the `[]T` borrows the `[]mut T` shared, and a `[]mut T`
passed to a call is a mutable use of it, as a `&mut` argument is. `&mut x[a..b]` on an array, a
`[]mut T` or a container with `index_range_mut` is a `[]mut T`, and `&x[a..b]` a `[]T`. A literal coerced to a slice
(`let s: []u8 = [x, y];`, `f([x, y])`) builds its array in a temporary that lives to the end of
its block, so its view cannot leave the block or be returned. An `if` or `switch` arm whose value
borrows a temporary of the arm (an array viewed as a slice, `&S { .. }`) keeps the temporary to
the end of the block around the whole expression, as if the value stood in place of the
expression: `f(if c { [x] } else { [y, z] })` is valid. A local declared in the arm dies with the
arm, so its view or reference cannot be the arm's value. An `if` or `switch` argument converts
each arm to the parameter's type, as a `let`'s annotation does.

A call or method argument `&x` passes as the view the prelude view interface of `x`'s type gives:
`str` through `AsStr` (`String`), `[]T` through `AsSlice<T>` and, from `&mut x`, `[]mut T` through
`AsSliceMut<T>` (`Vector`, `Array`, `StaticVector`). A user container gets the coercion by
conforming. The view borrows `x` as `x.as_str()` does, a `[]T` parameter infers `T` through the
conformance, and the coercion ranks with the array-to-slice one in overload selection. A `let`'s
annotation, an operand and a `return` keep the explicit method, and an argument `x` without `&`
stays an error whose note names the borrow (passing `x` would move it). An argument `x.as_str()`
(`as_slice`, `as_mut_slice`) on a place is a lint warning with a fix to `&x` (`&mut x`).
`[T; N]` is a distinct type and a value: assignment, an argument, a struct field, a variant payload, a tuple
element, a closure capture and a return copy it. An array literal has its own length; against
an expected `[T; n]` it must have exactly `n` elements (a designated literal may have fewer and
zero-fills the rest), and a nested literal is checked against the element type at every level.
Without an expected type, the first element's type is the one the later elements are checked
against, as an annotation would give it (`[(1u8, 2u8), (3, 4)]`, `[Some(1u8), Some(2)]`), except
by a nested array literal of another length, which reports "array literal element has length 3,
but the first element has length 2". A
repeat `[e; n]` evaluates `e` once and copies the value into every element (`[f(); 4]` calls `f`
once). A
nested literal without an annotation takes its inner length from its elements
(`[[1, 2], [3, 4]]` is `[[i32; 2]; 2]`), and its elements must agree on that length. A symbolic
length (`[T; N]`, `[T; N * 2]` in the generic that declares `N`) is a type of its own: it equals
only the same length, never a count, and an instance folds it at every nesting level
(`G<3>.g` is `[[i32; 3]; 2]` for `g: [[i32; N]; 2]`). `[T; 0]` is a real length, and a zero-length
array is zero-sized like any ZST: it has no storage in C, keeps its element's alignment in an
enclosing struct, and a pointer to one moves by 0 bytes. A zero-length array of an owning element
moves like its element and frees nothing. An array has no `==` or ordering ("does not implement
`Eq`; compare elements"): C would compare addresses.

## Compile-Time Evaluation

Always on, in constant contexts: `const` and `static` initializers (local constants too),
array lengths, const generic arguments, `static_assert`, enum discriminants, `type_info` and
`type_info::<T>().qualified_name` (`T` spelled with its trailing defaulted arguments dropped:
`Vector<i32>`; read alone it folds to a string constant and builds no descriptor). `panic_parts(head,
tail)` panics with `head` then `tail` without allocating, so a message can name a type
(`panic_parts(type_info::<Self>().qualified_name, "[i]: index out of bounds")`).
A failed evaluation there is an error, and a local constant's initializer cannot read a
variable. A constant context can call any function. Outside one, a `const fn` call whose
arguments are constant (literals, constants, `sizeof`, operators, aggregates and `const fn`
calls over them) runs at compile time and its value replaces it, when the value is an integer,
`bool`, `char`, float, `str`, bare enum, or a struct, tuple struct or array of them (at most
256 scalars). A call whose evaluation fails runs at run time, without an error; every other
call runs at run time. `const fn` adds a declaration check that rejects a function certain to
fail at compile time.

```superc
const fn table_size(bits: u32) usize { return (1u32 << bits) as usize; }
const N: usize = table_size(8);

static_assert(sizeof(Header) == 8, "Header must stay 8 bytes");
```

- A `const` of an owning (`Free`) type lives in static storage. Moving out of it is "cannot
  move a value out of a 'const' binding"; borrow it instead (`K.v.len()`).
- Every task shares a `const`: one holding an `UnsafeCell` must be `Sync` ("a constant of type
  '..' holds an 'UnsafeCell' but is not 'Sync'").
- A constant whose type embeds a stateful allocator is "a constant cannot use the stateful
  allocator '...'". A `static mut` cannot hold an owning type (raw pointers and references are
  allowed).
- A union reads at compile time through the member last written, or through another scalar member
  of its width (`f64_bits`); any other member read does not fold. So a `String` folds only up to its
  inline bytes (23 on a 64-bit target).
- Allocation is valid at compile time. A `@no_const` type (see Attributes) is not: a `const fn`
  whose signature names one, or that fails on every path (it constructs one), is an error at
  its declaration ("function 'f' is declared 'const fn' but ..."). A `const fn` that fails only
  on some paths (a branch, a loop, recursion) is accepted.
- A header type (a `struct` or `union` of an `extern "C"` block) lists every member, so its size,
  alignment, offsets and `type_info` are compile-time values like a Super-C struct's; the build
  checks them against the header (`super-c-ffi`). A constant of an extern block with a value folds
  like any constant.
- A `const fn` cannot call an extern function or a variadic one ("... but calls a variadic
  function"). `assert`, `assert_eq` and `assert_ne` are variadic (`std/test.spc`), so a function
  that checks an invariant with `assert` is a plain `fn`.
- A `static_assert` in a non-generic body must fold, as a top-level one must ("static
  assertion cannot be evaluated: the condition does not fold to a constant").
- A `static_assert` in the body of a generic function (one with its own generic parameters,
  or a method of an extend with parameters) holds per instance:
  `static_assert(T::is_signed(), "only signed types")` fails the build at
  `only_signed(3u32)`, with a note that names the bindings. The check runs for each concrete
  call the type check records, once every module is typed, and for every other instance the
  build uses, also one reached only through another generic body. Each failure is reported
  once.

## Build Constants and Platform Gating

```superc
@platform(macos)
fn platform_init() { /* macOS-specific */ }

@platform(windows)
fn platform_init() { /* Windows-specific */ }

fn page_size() usize {
    if PLATFORM == Platform::Windows {
        return win_page_size(); // a @platform(windows) item: the call is removed on other platforms
    } else if ARCH == Arch::AArch64 {
        return 16384;
    }
    return 4096;
}
```

No `#ifdef` in Super-C. Use `@platform(windows|macos|linux|wasm|ios|android)` and
`@arch(x86_64|aarch64|wasm32)` on items and on the members of an `extend` or an `extern` block
(an interface member takes no attribute); `|` inside the attribute is a union, `!x` the
complement. An item with both `@platform` and `@arch` compiles only where both hold, and a gate
that fails removes the item or member before name resolution.
`--target=` and `--arch=` select the target.

`@when(C)` gates an item, a member or an import on the boolean build constants the same way:
`C` names `TEST`, `LOCKDEP` and `OVERFLOW_CHECKS` with `!`, `&&`, `||` and parentheses
(`@when(LOCKDEP && !TEST)`); any other name or form is "'@when' takes a condition over TEST, LOCKDEP
and OVERFLOW_CHECKS ...". It combines with `@platform` and `@arch`: the item exists only where every
gate holds. Use it where a definition must not exist at all in some builds; inside a body,
`if LOCKDEP { .. }` is enough.

The prelude defines the build settings as constants usable in any expression:

| Constant | Type | Value |
|----------|------|-------|
| `PLATFORM` | `Platform` (`Windows`, `MacOS`, `Linux`, `Wasm`, `IOS`, `Android`) | `--target` (default: the host) |
| `ARCH` | `Arch` (`X86_64`, `AArch64`, `Wasm32`) | `--arch` (default: the host's; `--target=wasm`, `ios` and `android` set theirs) |
| `TEST` | `bool` | true in a test build (`super-c test`, `super-c test <file>`) |
| `POINTER_WIDTH` | `u32` | 64; 32 on `wasm32` |
| `ENDIAN` | `Endian` (`Little`, `Big`) | `Little` on every supported target |
| `PROFILE` | `str<'static>` | the build profile name (`debug` when none is named) |
| `LOCKDEP` | `bool` | the profile sets `lockdep = true` (lock-order checking) |
| `OVERFLOW_CHECKS` | `bool` | false when the profile wraps integer overflow (`overflow-checks`, else `opt-level` 2 and up) |

The compiler generates their module (`__std::build`) from the build's settings; std declares only
the enums (`std/target.spc`). The eight names are reserved: an item or binding with one of
them is an error, and so is a type, item, binding or generic parameter named `Platform`,
`Arch` or `Endian` outside `std/target.spc` (the filter reads `Platform::X` as std's
variant before name resolution). ARCH and POINTER_WIDTH are absent when the host
instruction set is unknown and no `--arch` names one.

The platform filter decides a condition over PLATFORM, ARCH, POINTER_WIDTH, ENDIAN and the
bool constants alone before name resolution: a bare bool constant (`TEST`, `LOCKDEP`), `!`, `&&`, `||`, parentheses, and `==`
or `!=` against `Platform::X` / `Arch::X` / `Endian::X`, `true` / `false`, or a decimal
integer. Such an `if` / `else if` / `else` chain (statement or value) becomes its taken
block (with its own scope), and a `switch PLATFORM { Windows => .., _ => .. }` (or over
ARCH or ENDIAN; arms of bare variant names, `|` and `_`, no guard) becomes its taken arm.
The removed code is parsed but never resolved or checked, like a gated-out item: it may
call items of another platform. A variant name these forms spell that does not exist
(`Platform::Macos`) is an error, in removed code too. A condition that mixes the
constants with anything else is an ordinary constant expression: both branches are
checked, and the dead one is not emitted when the condition folds.

A user `const bool` gate (`if STATS { .. }`) trips the constant-condition lint ("condition is
always false"); gate through a `pub const fn` instead (`sched_stats_on()` in
std/parallel/runtime.spc).

PROFILE is an ordinary constant: both branches of `if PROFILE == "release"` are checked,
and only the taken one is emitted (`switch PROFILE` over string literals too). A string
literal compared with PROFILE must name a built-in profile or a `[profile.*]` of the
package (a single-file build knows the built-ins only). The constant-condition and
unreachable lints never fire on these conditions. Removed code may hold the only use of a
name, so the lints that count uses treat every identifier its text spells as used, by
name: a binding, item, field, variant or import that removed code names is not reported
unused (nor a `mut` binding not mutable, nor a store dead), in any module for items,
fields and variants; a glob import of a module with removed code is kept. An `unsafe` that
holds removed code is not reported unnecessary, and a statement that is or holds a decided
site does not make the next one unreachable. Everything else is linted as usual. The name
match is textual: a removed use of `x` also covers an unrelated `x`. The LSP loads and
filters with the configured `--target` and does not analyze removed code (no hover or
navigation inside it); hover on a constant shows its value.

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
fails when the `--emit-c` tree compiles). A `struct`, `union` or `enum` in the block is a header
type: the C type (`struct stat`, `enum color`, or a typedef name through `@import`), with the fields
the declaration lists and the header's layout, which the build checks field by field; the block
must name that header. It has no drop glue (see `super-c-ffi`, Header Types). No type of an extern
block implements `Free`: wrap it in a struct that does. C code comes in as a library (`@link`).
`@link("m")` declares a library. Variadics work in both directions (`...`, `va_list`,
`va_start`, `va_arg`, `va_end`); `va_arg` needs `unsafe` (see `super-c-ffi`).

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

@test(should_panic, timeout = 5) // a list: should_panic and timeout = N seconds, each at most once
fn rejects_quickly() { panic("boom"); }
```

`assert(cond)`, `assert_eq(a, b)`, `assert_ne(a, b)` are compiler builtins that print
source text, values, and file:line on failure.

## Attributes

| Attribute | Effect |
|-----------|--------|
| `@inline` | Suggest inlining |
| `@always_inline` | Force inlining |
| `@noinline` | Prevent inlining |
| `@cold` | Mark rarely called: under `--emit-c` C `cold`, which implies `noinline`, and the C compiler lays out the branches that call it as unlikely. The native build marks each block that calls it unlikely (laid out after the warm code, as `unlikely` does), inlines it only when it is no bigger than its call, and puts its code in a cold section (ELF `.text.unlikely`, Mach-O `__text_cold`, COFF `.text$u`) |
| `@noreturn` | Mark non-returning |
| `@align(N)` | Set alignment of a struct or a union (a header type of an `extern "C"` block too), or of a `static mut` outside an `extern "C"` block (an error on any other item): a power of two from 1 to 4096 (a page: a larger one is misaligned on some hosts and could move a task's frame past its guard page); `N` is an integer literal or a constant expression of type `u32`. An emitted struct or union definition takes `__attribute__((aligned(N)))`; a static whose `N` is above its type's own alignment takes `_Alignas(N)` on its definition and every declaration (C rejects a weaker specifier) |
| `@packed` | Pack a struct or a union, a header type of an `extern "C"` block too (an error on any other item). A reference or autoref to a field whose alignment exceeds 1 is "cannot borrow a field of a '@packed' struct" (copy it into a local first), and such a field cannot need a `free` |
| `@export("sym")` | Pin exact C symbol; a constant or `static mut` is defined also when no code names it |
| `@import("sym")` | Import exact C symbol; on an extern type, its C spelling; on a header type's field, its C member |
| `@used` | Prevent dead-code elimination: the function, constant or `static mut` is emitted also when no code names it, with C `used`. Without it (or `@export`), a function a program with `main` never reaches, or whose every call is inlined, has no C definition |
| `@unused` | Suppress unused warnings |
| `@emit_macro` | Export generic as reusable C macro |
| `@fmt.skip` | Exempt from formatter |
| `@platform(P)` | Platform gate |
| `@arch(A)` | Instruction-set gate: `x86_64`, `aarch64`, `wasm32` (see Build Constants and Platform Gating) |
| `@when(C)` | Build-condition gate over `TEST`, `LOCKDEP`, `OVERFLOW_CHECKS` (see Build Constants and Platform Gating) |
| `@target_feature([cpu::Feature::X, ..])` | The function needs CPU features (a list, or a level such as `cpu::X86_64_V3`): safe to call where the build or the caller holds them, else inside `unsafe` after a run-time check (an error on wasm32); its vector code uses them (references/simd.md) |
| `@simd_impl(simd::Op::X, [cpu::Feature::Y, ..])` | `std` only: a backend entry of vector operation `X` (references/simd.md) |
| `@value(size, align)` | An opaque `extern "C"` type is a C register type of that layout (see `super-c-ffi`) |
| `@layout(size, align)` | An opaque `extern "C"` type is a C value of that exact layout, checked in C (see `super-c-ffi`) |
| `@thread_local` | A `static mut` (an extern one too) has one object per OS thread. Every access calls a non-inlined accessor, so a coroutine that moves to another thread reads that thread's object. A constant or a `static mut` initializer cannot read one ("a thread-local has one object per thread: ...") |
| `@owned` | On a raw pointer field (`*mut T`, `*const T`; an error elsewhere): the user promises that while a reference to the struct lives, the buffer the field points to is reached only through the field. Through a `&mut` the buffer is then apart from other memory, through a `&` read-only, so loops over such buffers need no run-time overlap check. Breaking the promise is undefined behavior. User code only: `std` and the compiler write such loops over views (`references/style.md`, Loops Over Buffers) |
| `@reads(p, bytes)` / `@writes(p, bytes)` / `@lane_access` | The memory an extern function reads or writes through pointer parameter `p` (see `super-c-ffi`) |
| `@test` / `@test_init` / `@test_free` | Test harness; `@test(should_panic, timeout = N)` takes either argument or both |
| `@blocking` | Run extern on blocking pool |
| `@tail_recurse` | Every call of the function to itself must become a jump (see Functions); a function with a body only |
| `@no_const` | Struct, union or enum whose values never exist at compile time; a function that is never a `const fn` (an error on one; `lint --const` skips it) |
| `@intrinsic("<name>")` | `std` only: a function without a body whose call is the operation the name gives: a vector operation `simd.<name>` (references/simd.md), `float.to_int_unchecked` (references/operations.md), the branch hints `hint.likely` and `hint.unlikely` (Branch Hints below), `frame.return_address` (the running function's return address, null on wasm; the leak tracker's allocation sites), or `mem.volatile_load` / `mem.volatile_store` (one access the C compiler keeps, orders and never merges: `std::mem::volatile` wraps them as `read_volatile`, `write_volatile` and `zeroize`) |
| `@unsafe(safe, const)` | Unverified claims on an extern function, any order, at least one: `safe` = callable without `unsafe`, `const` = its body models it at compile time (see `super-c-ffi`) |
| `@unsafe(link_section = "s")` | Place a function with a body or a `static mut` in object-file section `s`; a `static mut` in a section is defined also when no code names it (Unsafe Placement below) |
| `@unsafe(naked)` | The function's `asm` statements are its whole machine code: no prologue or epilogue (Unsafe Placement below) |

A constant-expression attribute argument (`@align(LINE * 2)`) is an ordinary expression: names
resolve at module scope (in the `extend` scope for a member; `@reads`/`@writes` also see the
function's parameters), the argument checks against the type the attribute declares and folds at
compile time like a `const` initializer. An attribute with several arguments checks each against
its own type and arity ("attribute '@reads' takes 2 arguments"). A misspelled name, a
type mismatch or an argument that does not fold is an error at the argument. The formatter prints
the argument as an expression, and the language server completes, hovers, renames and finds names
inside it. A lone integer literal keeps the literal form and emits the same C.

`@no_const` does not pass through fields: the type author tags each type. std tags its OS and
runtime handles (`Atomic`, `Arc`, locks, channels, threads, sockets, the scheduler); value
helpers (`Duration`, `IoError`) stay untagged.

An attribute appears at most once on one declaration (item, method, field, variant, extern
item), whatever its arguments: a second `@align`, `@platform`, `@derive`, `@reflect`,
`@link`, or any other is the parse error `duplicate attribute '@NAME'`. Put several values in
one occurrence (`@derive(Format, Hash)`, `@reflect(a, b = 1)`, `@platform(linux | macos)`).

### Branch Hints

`likely(c)` and `unlikely(c)` (prelude, `std/core.spc`) return `c`, also in a constant. The `if`
or loop condition that tests the call tells the C compiler of an `--emit-c` tree which way the
branch usually goes: `if (__builtin_expect(c, 1))` or `(c, 0)`. The native build marks the rare
side unlikely: its blocks go after the warm code, the branch stays a branch (no select), the warm
code gets the registers first, and a body whose calls are all on rare sides sets its frame up only
there (shrink-wrapping). Wrap the WHOLE condition: a hint on one operand of
`||` or `&&` stays inside the lowered short circuit and the final branch has none.

```superc
for x in xs {
    if unlikely(x < lo || x == lo && x.is_sign_negative()) {
        lo = x;
    }
}
```

Use a hint where the branch is predictable and its taken side is rare: an error or slow path, a
new minimum in a scan. There it also stops the compiler from turning the branch into selects,
which chain each iteration to the previous one: Apple clang does this to the loop above without
the hint (3.06 ns per element on an M5 Pro, 0.55 with it). A wrong hint costs the mispredicted
side; leave unpredictable branches unhinted.

### Unsafe Placement

`@unsafe(...)` lists claims the compiler cannot check, in any order, each once, in one
attribute per declaration (`@unsafe(link_section = "__TEXT,__boot,regular,pure_instructions", naked)`).
A section is written only as `@unsafe(link_section = ...)`: it changes what the linker and the loader
assume about the symbol. The C definition carries `__attribute__((used, section("s")))`: `used`
keeps link-time optimization from inlining or dropping the symbol, and its section with it.

- `link_section = "s"`: on a function with a body or a `static mut`, neither in an extern block. The
  name holds letters, digits, `_`, `.` and `$`. On macOS and iOS (Mach-O) it is
  `segment,section[,type[,attributes[,stub size]]]`, segment and section 1 to 16 bytes each, `+`
  between attributes; on the other targets one name. On wasm32 only a `static mut` takes one (a data
  segment name): every function is in the code section.
- `naked`: on a function with a body outside an extern block; the C definition is
  `__attribute__((naked, noinline))`. The body holds only `asm("...");` statements without operands
  or clobbers (basic assembly, at least one), which need no `unsafe` block; the assembly reads the
  parameters where the C calling convention puts them and returns itself. Every parameter and the
  result is an integer, float, `bool`, `char` or raw pointer (one result at most, or `!`). Not generic,
  not in a generic extend, not a `const fn`, not `@inline` or `@always_inline`. A call needs no
  `unsafe`. wasm32 is an error. The native generators emit the templates alone (`Body.naked`); the
  `--emit-c` tree stops with `#error` unless its C compiler is Clang, or GCC 8 or later on x86-64
  (GCC has no naked functions on aarch64).
  The unused-parameter lint skips a naked function.

### Module-Level Assembly

`asm("...");` at module level is file-scope basic assembly: the template alone, a string or a
matchertext literal (`asm(M"(...)");`), in the module's unit ("a module-level 'asm' takes only its
template: no operands or clobbers"). Gate it with `@platform` and `@arch`. It defines symbols that
only an `extern "C"` declaration names, so a module that holds one is always emitted, also when no
Super-C item of it is used. Spell each symbol as the target's object format does (a leading `_`
on Apple targets).

## Concurrency

`launch || { .. };` spawns a stackful coroutine on a work-stealing pool. `Arc<T>` for
shared ownership across threads. `Mutex<T>`, `RwLock<T>`, `Channel<T>`, atomics, and
`parallel::range`/`each`/`reduce` for data parallelism. `Send`/`Sync` marker interfaces
enforced at spawn boundaries.

## Standard Library Highlights

| Type | Description |
|------|-------------|
| `String` | Owned growable UTF-8 string |
| `str` | Borrowed string view (non-NUL-terminated except a literal, whose C spelling ends in a NUL; print via `%.*s`, or `.to_string()` then `String::cstr()`) |
| `Vector<T>` | Growable array |
| `Box<T>` | Heap-allocated single value |
| `Option<T>` | `Some(x)` / `None`, bare or qualified (`Option::Some(x)`), in values and patterns |
| `Result<T, E>` | `Ok(T)` or `Err(E)` |
| `Map<K, V, A = Global, S = DefaultHash>` | Hash map; `S: BuildHasher` turns a key into its hash (`DefaultHash` is unkeyed and deterministic, `std::hash::keyed::KeyedHash` keyed); `entry(k)` (`or_insert`, `or_default`, `and_modify`, `Occupied`/`Vacant`), `iter()`, `iter_mut()`, `keys()`, `values()`, `drain()`, `retain`; the cursors borrow the map, double-ended with an exact `size_hint` |
| `Set<T, A = Global, S = DefaultHash>` | Hash set; `iter()` borrows it; `set_union`, `intersection`, `difference`, `symmetric_difference` iterate both sets lazily |
| `Array<T, N>` | Fixed-size const-generic array, a type distinct from `[T; N]`. `new()` needs `T: Default`; for raw pointers write `Array::<*mut T, N> {}` |
| `Slice<T>` / `SliceMut<T>` | Fat-pointer views, and the one implementation of the sequence algorithms `Vector`, `Array` and `StaticVector` reach through `as_slice()`/`as_mut_slice()`: `sort` (unstable), `sort_stable` (a scratch block of `len` elements; `_in(alloc)` names its allocator), `sort_stable_in_place` (no heap memory, a 4 KiB stack buffer; about 1.25x the time of `sort_stable` on large inputs), `select_nth_unstable`, the heap operations, `binary_search`, `partition_point`, `partition`, `partition_dedup`, `rotate_left`; comparators return a negative, zero or positive `i32`. A `SliceMut` method takes the view by value: it is reborrowed for the call and conflicts with a live element borrow |
| `(A, B)` ... 8 elements | Tuples (`Tuple2`..`Tuple8`, built by the compiler; access: `.0`, `.1`); `Eq`, `Ord` (lexicographic), `Hash`, `Clone`, `Default` and `Format` when every element has them |
| `Iterator<T>` / `DoubleEndedIterator<T>` | `next`, `size_hint` (bounds; equal bounds are an exact size), `next_back`; the adapters of the prelude `iter` module (`map`, `filter`, `take`, `skip`, `chain`, `rev`, `zip`, `enumerate`, `flat_map`, `step_by`, `peekable`, ..) and consumers (`fold`, `any`, `all`, `find`, `min`, `max`, `collect`, `try_collect`, ..) are free functions; a `Range<T>` of a builtin integer is a double-ended iterator |
| `Hash` / `Hasher` / `BuildHasher` | One method, `hash_into(h)`: feeds the value into a `Hasher` (derived: field by field, consistent only with the derived `Eq`; a type that writes its own `eq` must write `hash_into`, else a static assertion stops the build). Conforming is explicit (`@derive(Hash)`): interior-mutable types (`Cell`, `RefCell`, atomics, locks) are not `Hash`. `hash(&v)` is the prelude's 64-bit hash (`DefaultHasher`), the one `DefaultHash` maps use |
| `Arc<T>` / `arc::Weak<T>` | Atomic reference counting; `downgrade`, `Weak::upgrade`, `get_mut`, `try_unwrap` |
| `Mutex<T>` / `RwLock<T>` | Synchronization |
| `Channel<T>` | Bounded/unbounded channels |
| `Unit` | The zero-sized success value of a status-only operation (`Result<Unit, IoError>`) |
| `IoError` | `kind: IoErrorKind` (the stable category), `code` (the native error number, 0 when none), `op: IoOp` (the failed operation) |
| `Reader` / `Writer` | `read(buf) Result<usize, IoError>`, `write(bytes) Result<usize, IoError>`: `Ok(n)` once a byte moved, a fault after a partial transfer on the next call, `Ok(0)` from `read` only at the end or for an empty buffer |
| `TryFrom<T>` / `TryInto<T>` | Fallible conversion with an associated `type Error`; `x.try_into()` returns `Result<U, U::Error>` |
| `std::time`, `std::net` | Durations, deadlines and task-aware `sleep`; task-aware TCP and UDP |
| `std::text::utf16` | `encode`, `encode_into`, `decode` between UTF-8 and UTF-16 code units, with the offset of ill-formed input |
| `std::collections` | `deque::Deque`, `deque::RingBuffer`, `heap::BinaryHeap` with `heap::Reverse`, `btree::BTreeMap` and `BTreeSet`, `hive::Hive` (stable addresses through `HiveHandle`), `bits::BitSet`, `BitVec` and `BitField`, `mdspan::MdSpan` and `MdSpanMut`, `packed::PackedEnums` (enum values stored at the size of their own variant, read in order); each module's header states its complexity, invalidation and allocator use |
| `std::alloc` | `Arena`, `Pool` and `NoAlloc` (C++ `<memory_resource>`): an owning resource and a `Copy` handle that implements `Allocator`; `Stack`, a zero-sized allocator like `Global` over a region of the running task, neither `Send` nor `Sync` (`Vector::<T, Stack>::new()`); `std::parallel::pool::SyncPool` is the shared pool |
| `std::mem` | `layout::Layout`, `ptr` (unaligned and raw copies, `bit_cast`), `endian` (byte-order reads and writes), `cell::Cell`, `RefCell`, `OnceCell`, `rc::Rc` and `rc::Weak`, `volatile` (volatile access and zeroization) |
| `std::hash::keyed` | `KeyedHash` (SipHash-1-3 under a 128-bit key from `with_key` or the process's entropy, `random`), `SipHasher13`, `SipHasher24`: the builder for maps whose keys come from untrusted input |
| `std::platform::*` | std's internal operating-system layer (files, paths, clocks, entropy, memory, threads, processes, environment, signals, sockets, libraries): unstable, for std and projects with `std_internals = true` |

Every std package declares its tier and target support in `std/packages.toml` (0 prelude; 1 portable, no
operating system; 2 allocating; 3 operating system, I/O and concurrency; 4 encodings and protocols; 5 tooling).
A module imports no module of a higher tier and joins no import cycle across packages; platform FFI stays in
`std::platform` and the substrate modules the file exempts (`ci/gate.sh` checks it with `tools/std_packages`).
