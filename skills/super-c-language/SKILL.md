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

See [operations.md](references/operations.md) for the normative result of every scalar,
conversion, float, pointer, atomic and control operation (wraps, traps, defined value, or
undefined), identical at compile time and at run time.

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

A parenthesized return list (`fn f() (A, B)`) is several results, not a tuple. To return a
tuple, name it through an alias: `type P = (A, B); fn f() P`.

## Structs and Methods

```superc
struct Counter { pub n: i32 }

extend Counter {
    fn get(self: &Counter) i32 { return self.n; }
    fn bump(self: &mut Counter) { self.n = self.n + 1; }
}
```

Fields are private by default: only the type's own `extend` blocks can name a private field, even
in the same module; `pub` exposes it everywhere. One `extend` block per
type at file end. Interface conformance blocks (`extend T as I { .. }`) stay separate.

A method or associated constant is defined once for any one instance of its type: a second item of
the name (a method or a constant, any signature) in a plain `extend` that applies to a common
instance, in any module, is "duplicate definition of 'f' for 'X'" at the later one. Disjoint extends
(`extend P<u8>`, `extend P<i32>`) and distinct conformances may each define the name (see the
generics section of [types.md](references/types.md)).

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

`switch` is exhaustive and usable as an expression. Arms combine alternatives with `|`. A pattern
names a variant bare (`Circle(r)`); a qualified variant (`Shape::Circle(r)`, `Shape::Unit`) is an
error. A qualified path without a payload is a constant pattern: a builtin limit (`i64::MAX`) takes
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
4-byte C enum otherwise. A payload-less variant of either kind may take an explicit
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
for deliberate leaks.

Assignment frees the old value first: `s.name = fresh;` never leaks.

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
- Indexing a fixed array `[T; N]` (also through a reference) with an index that is not a
  constant within `N`; a constant index is checked at compile time at every nesting level.
  Against a symbolic length a constant index is safe and every instance checks it: `a[2]` for
  `a: [i32; N]` is "index 2 is out of bounds for an array of length 2 for N = 2" where `N = 2`
  is instantiated; under `unsafe` the index is unchecked, as a raw pointer's. Slicing a symbolic length with constant bounds still needs `unsafe`
  ("slicing an array of unknown length"). A field of a concrete instance has the instance's
  length (`Buf<i32, 4>.d` is `[i32; 4]`)
- Every call to an `extern "C"` function
- Naming an `unsafe fn`, or an `extern "C"` function without `@unsafe(safe)`, as a value
  outside a call: a `fn` pointer is called without `unsafe`
- Casting `&T` to `*mut T` (except through `UnsafeCell::get`)

A `&mut` reference is exclusive also for unsafe code: reaching its referent through any
other path while it is live is undefined behavior (its C parameter is `restrict`, see
`types.md`).

There is no auto-dereference through a raw pointer (the Rust rule): for `p: *mut T`,
`p.f` and `p.m()` are errors; write `unsafe (*p).f` and `unsafe (*p).m()`. A method whose
`self` is the raw pointer type itself applies to `p` directly. The explicit form keeps the
receiver a place: `(unsafe (*p)).m()` calls a `&mut self` method on the pointee, never on a
copy. Auto-deref through references, `Box` and `Deref` is unchanged.

Prefix form (`unsafe expr`) or block form (`unsafe { .. }`); the prefix covers the whole
postfix chain after it, so `unsafe (*p).a.b()` needs one `unsafe`. Use `.at()` for safe
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
fn twice<T: Copy>(x: T) (T, T) { return x, x; }
fn keep<T>(slot: &mut T, v: T) T { return replace(slot, v); }  // move out through a reference
```

## Closures

Capture flavors:
- **Read**: copy at creation (default)
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

`Self::f()`, `Self::K` and `Self { .. }` name the implementing type inside an extend or an
interface default body. A call on a concrete receiver chooses by its arguments among the methods
its extends define and the defaults its conformances inherit (see the generics section of
[types.md](references/types.md)).

The prelude defaults of `Clone`, `Default`, `Eq` and `Ord` (what `@derive` and an empty `extend`
use) work field by field. An enum must define `clone` and `default` itself, and a union also `eq`
and `cmp`; inheriting one of those defaults is a compile error at the conformance.

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

## Imports and Modules

```superc
import geom;                 // qualified access: geom::Point
import geom as *;            // unqualified glob
import geom as g;            // alias
```

Imports are public and C-style transitive, so there is no `pub import`. Cycles are legal. Prelude types (`String`,
`Option`, `Vector`, `Box`, `Result`, `Map`, `Set`, `str`) resolve unqualified.

## Visibility

Private by default. `pub` on structs, enums, functions, fields, constants, type aliases.
A private field is visible only inside its type's own `extend` blocks (member access, struct
literals and struct patterns), in the declaring module too.

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
`mut`, as after `&`. The compiler's own sources (`src/`, `std/`, `ffi/`) spell the named form
`Slice<'a, T>` until a release parses the sugar. Arrays coerce to slices; the view borrows the
array like `&a` (`&mut a` for `[]mut`) and never moves it: the array must outlive the view and
cannot be written, moved or viewed mutably while the view is live. A literal coerced to a slice
(`let s: []u8 = [x, y];`, `f([x, y])`) builds its array in a temporary that lives to the end of
its block, so its view cannot leave the block or be returned.
`[T; N]` is a distinct type and a value: assignment, a struct field, a variant payload, a tuple
element, a closure capture and a return copy it. An array literal has its own length; against
an expected `[T; n]` it must have exactly `n` elements (a designated literal may have fewer and
zero-fills the rest), and a nested literal is checked against the element type at every level. A
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
array lengths, const generic arguments, `static_assert`, enum discriminants and `type_info`.
A failed evaluation there is an error, and a local constant's initializer cannot read a
variable. A constant context can call any function. Outside one, every call runs at run
time, `const fn` calls with known arguments included. `const fn` adds a declaration check
that rejects a function certain to fail at compile time.

```superc
const fn table_size(bits: u32) usize { return (1u32 << bits) as usize; }
const N: usize = table_size(8);

static_assert(sizeof(Header) == 8, "Header must stay 8 bytes");
```

- A `const` of an owning (`Free`) type lives in static storage. Moving out of it is "cannot
  move a value out of a 'const' binding"; borrow it instead (`K.v.len()`).
- A constant whose type embeds a stateful allocator is "a constant cannot use the stateful
  allocator '...'". A `static mut` cannot hold an owning type (raw pointers and references are
  allowed).
- Allocation is valid at compile time. A `@no_const` type (see Attributes) is not: a `const fn`
  whose signature names one, or that fails on every path (it constructs one), is an error at
  its declaration ("function 'f' is declared 'const fn' but ..."). A `const fn` that fails only
  on some paths (a branch, a loop, recursion) is accepted.

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
`@arch(x86_64|aarch64|wasm32)` on items; `|` inside the attribute is a union, `!x` the
complement. An item with both `@platform` and `@arch` compiles only where both hold.
`--target=` and `--arch=` select the target.

The prelude defines the build settings as constants usable in any expression:

| Constant | Type | Value |
|----------|------|-------|
| `PLATFORM` | `Platform` (`Windows`, `MacOS`, `Linux`, `Wasm`, `IOS`, `Android`) | `--target` (default: the host) |
| `ARCH` | `Arch` (`X86_64`, `AArch64`, `Wasm32`) | `--arch` (default: the host's; `--target=wasm`, `ios` and `android` set theirs) |
| `TEST` | `bool` | true in a `--test` build (`super-c test`, `super-c --test`) |
| `POINTER_WIDTH` | `u32` | 64; 32 on `wasm32` |
| `ENDIAN` | `Endian` (`Little`, `Big`) | `Little` on every supported target |
| `PROFILE` | `str<'static>` | the build profile name (`dev` when none is named) |

The compiler generates their module (`__std::build`) from its flags; std declares only
the enums (`std/target.spc`). The six names are reserved: an item or binding with one of
them is an error, and so is a type, item, binding or generic parameter named `Platform`,
`Arch` or `Endian` outside `std/target.spc` (the filter reads `Platform::X` as std's
variant before name resolution). ARCH and POINTER_WIDTH are absent when the host
instruction set is unknown and no `--arch` names one.

The platform filter decides a condition over PLATFORM, ARCH, TEST, POINTER_WIDTH and
ENDIAN alone before name resolution: bare `TEST`, `!`, `&&`, `||`, parentheses, and `==`
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

@test(should_panic, timeout = 5) // a list: should_panic and timeout = N seconds, each at most once
fn rejects_quickly() { panic("boom"); }
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
| `@c.align(N)` | Set alignment: a power of two from 1 to 2^28 (268435456); `N` is an integer literal or a constant expression of type `u32` |
| `@c.packed` | Pack struct |
| `@c.export("sym")` | Pin exact C symbol |
| `@c.import("sym")` | Import exact C symbol |
| `@c.section("s")` | Place in section |
| `@c.used` | Prevent dead-code elimination |
| `@c.unused` | Suppress unused warnings |
| `@emit_macro` | Export generic as reusable C macro |
| `@fmt.skip` | Exempt from formatter |
| `@platform(P)` | Platform gate |
| `@test` / `@test_init` / `@test_free` | Test harness; `@test(should_panic, timeout = N)` takes either argument or both |
| `@blocking` | Run extern on blocking pool |
| `@no_const` | Struct, union or enum whose values never exist at compile time |
| `@unsafe(safe, const)` | Unverified claims on an extern function, any order, at least one: `safe` = callable without `unsafe`, `const` = its body models it at compile time (see `super-c-ffi`) |

A constant-expression attribute argument (`@c.align(LINE * 2)`) is an ordinary expression: names
resolve at module scope (in the `extend` scope for a member), the argument checks against the type
the attribute declares and folds at compile time like a `const` initializer. A misspelled name, a
type mismatch or an argument that does not fold is an error at the argument. The formatter prints
the argument as an expression, and the language server completes, hovers, renames and finds names
inside it. A lone integer literal keeps the literal form and emits the same C.

`@no_const` does not pass through fields: the type author tags each type. std tags its OS and
runtime handles (`Atomic`, `Arc`, locks, channels, threads, sockets, the scheduler); value
helpers (`Duration`, `IoError`) stay untagged.

An attribute appears at most once on one declaration (item, method, field, variant, extern
item), whatever its arguments: a second `@c.align`, `@platform`, `@derive`, `@reflect`,
`@c.link`, or any other is the parse error `duplicate attribute '@NAME'`. Put several values in
one occurrence (`@derive(Format, Hash)`, `@reflect(a, b = 1)`, `@platform(linux | macos)`).

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
| `Option<T>` | `Option::Some(x)` / `Option::None` in values; bare `Some(..)`/`None` in patterns only |
| `Result<T, E>` | `Ok(T)` or `Err(E)` |
| `Map<K, V>` | Hash map |
| `Set<T>` | Hash set |
| `Array<T, N>` | Fixed-size const-generic array, a type distinct from `[T; N]`. `new()` needs `T: Default`; for raw pointers write `Array::<*mut T, N> {}` |
| `Slice<T>` / `SliceMut<T>` | Fat-pointer views |
| `Tuple2<A, B>` ... `Tuple4` | Tuples (access: `.0`, `.1`) |
| `Arc<T>` | Atomic reference counting |
| `Mutex<T>` / `RwLock<T>` | Synchronization |
| `Channel<T>` | Bounded/unbounded channels |
