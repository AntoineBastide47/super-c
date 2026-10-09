# Super-C Type System Reference

## Scalar Types

| Type | Size | Description |
|------|------|-------------|
| `bool` | 1 byte | `true` / `false` |
| `char` | 1 byte | C `char`, unsigned (0 to 255) on every target (`'x'` is a `char` literal; `b'x'` is a `u8` byte literal) |
| `i8` `i16` `i32` `i64` `isize` | 1/2/4/8/ptr | Signed integers |
| `u8` `u16` `u32` `u64` `usize` | 1/2/4/8/ptr | Unsigned integers |
| `f32` `f64` | 4/8 | IEEE-754 floats |
| `c32` `c64` | 8/16 | C `_Complex` floats |
| `void` | 0 | Unit type |
| `never` | 0 | Bottom type (`@c.noreturn` calls) |

Every integer and float type has the associated constants `MIN` and `MAX` (Rust's values; a
float's are its most negative and largest finite values; `isize`/`usize` follow the target's
pointer width). They are usable in constants, `static_assert`, const generic arguments (`U<u64::MAX>`
as `U<{u64::MAX}>`), array lengths and patterns, and literal-only arithmetic and patterns read them as
the literal of their value: `let i = i32::MAX + 1;` is the `i64` 2147483648, `let i: i32 = i32::MAX +
1;` is an error, and `0..=i64::MAX` against a `u64` is a `u64` range.

Every segment of a path in a type position (a let, a parameter, a return, a field, a cast, a sizeof,
a type argument) names a type: `let x: u64::MAX` is "expected a type, found constant 'u64::MAX'",
`u64::FOO` and `m::Foo::U` are "no type 'FOO' in 'u64'" and "no type 'U' in 'm::Foo'", and a variant
is "expected a type, found variant 'E::A'". Only a struct literal names a variant after its enum
(`E::A { x: 1 }`).

Builtin types are **nominal**: `i32` is not an alias for anything. `int` is not a
builtin; there is no implicit integer type. `str` is a prelude struct (a borrowed
`(ptr, len)` view), not a builtin.

## Numeric Literals

```superc
42              // i32 (default integer; i64, then u64, when the value does not fit)
42u8            // u8 suffix
1.0             // f32 (default float; f64 when the value is past the f32 range)
1.0f32          // f32 suffix
0xFF            // hex
0b1010          // binary
0o77            // octal
0x1.8p3         // hex float
b"hello"        // []u8 (byte string)
```

Lossless widening is implicit (`i32 → i64`, `f32 → f64`). Explicit `as` for narrowing or
cross-kind casts.

Literal-only arithmetic (unsuffixed literals under `+ - * / %`, the integer-only `& | ^ << >>`,
unary `-` and parentheses) is computed in one type, at compile time and at run time alike:

- With an expected builtin type (a declared binding, a parameter, a return type, the other operand)
  every operand takes it: `let z: i64 = 2000000000 * 2;` is 4000000000, `let b: u8 = 2 + 3;` is a
  `u8`. A literal outside that type is an error (`let x: i32 = 0x80000000;`: "integer literal is out
  of range for 'i32'"); an overflowing step is the error of any integer overflow (`let i: i32 =
  2147483647 + 1;` and `let x: u32 = 0 - 231;`: "this operation is undefined behavior when executed:
  arithmetic overflow"), and a negation typed unsigned is rejected (`let x: u32 = -1;`: "cannot apply
  unary operator '-' to type 'u32'"). A suffix pins its literal the same way (`2000000000i32 * 2` is an
  error).
- Without one the type is the first of `i32`, `i64` and `u64` in which no step overflows
  (`2000000000 * 2` and `2147483647 + 1` are `i64`, `9223372036854775807 + 1` is `u64`, `1 << 40` is
  `i64`, `1 << 31` stays the `i32` -2147483648); a value none holds is an error ("integer constant
  expression does not fit in 'i32', 'i64' or 'u64'"). `-9223372036854775807 - 1` and
  `-9223372036854775808` are the `i64` minimum, `-2147483648` the `i32` one; a negated suffixed
  literal reaches its type's minimum too (`-128i8`, `-9223372036854775808i64`). Library integers (`Int<N>`, `UInt<N>`) are never
  selected; a declared one converts the builtin result.
- A float expression is `f32`, or `f64` when a step passes the f32 range (`1e39`, `1e30 * 1e10`); past
  the f64 range, or past a declared or suffixed type's, it is an error ("float literal is out of
  range for 'f32'", "float constant expression is out of range for 'f32'", "float literal does not
  fit in its suffixed type").
- An integer literal never becomes a float and a float literal never an integer (Rust's rule):
  `1 + 2.0`, `(1 / 2) * 2.0`, `1.5 * 2`, `y * 2` with `y: f64`, and `let f: f32 = 1;` are
  "mismatched types" errors; write `2.0`.

## Matchertext Literals

`M"(..)"`, `M"[..]"` and `M"{..}"` are raw string literals: the content between the outer
matchers is verbatim (no escapes, quotes allowed), and its ASCII matchers `()`, `[]`, `{}` must
match ("mismatched matchers in matchertext literal"). Without holes the literal is a `str`
(`M"(a<b)" == "a<b"`).

A delimiter chain of nested matcher pairs between `M` and `"` turns on interpolation: the
chain's openers start a hole and its closers end it (`M{}"(n={n})"`, `M[]"(a{b} [x])"`,
`M{{}}"(..{{x}}..)"`). Pick a chain the verbatim text does not contain. The literal becomes a
`String`, built as `format()` builds one. A hole whose value can carry matcher bytes (strings,
chars, `Format` values) goes through `sugar_mt_splice` (std/string.spc), which panics when the
value's ASCII matchers do not match, so no value can break the literal's structure. The check
is a byte scan with no UTF-8 validation. `format()` and `print` arguments are not checked.

## Arithmetic Semantics

[operations.md](operations.md) is the normative table of every scalar, conversion, float, pointer,
atomic and control operation: whether it wraps, traps, gives a defined value, or is undefined, and
the explicit `wrapping_*`, `checked_*`, `overflowing_*` and `saturating_*` methods.

## Struct Layout

Standard C layout (not auto-rounded to power-of-2). Fields ordered as declared. Use
`@c.packed` for wire formats. Use `@c.align(N)` for cache-line alignment. Verify sizes
with `static_assert(sizeof(T) == N, "...")`.

## Pointers and References

| Syntax | Meaning |
|--------|---------|
| `*const T` | Immutable raw pointer |
| `*mut T` | Mutable raw pointer |
| `*T` | The same type as `*const T` |
| `&T` | Shared reference (borrow-checked) |
| `&mut T` | Exclusive reference (borrow-checked) |
| `new T(expr)` | Heap allocate (`*mut T`); "out of memory" panics on a failed allocation |
| `new T { .. }` | Heap allocate with struct literal |
| `sizeof(T)` | Byte size |
| `alignof(T)` | Alignment |

Raw-pointer operations require `unsafe`. Reference operations are safe. `&T` and `*const T`
lower to `const T*` in C; `&mut T` and `*mut T` lower to `T*`, and a `&mut T` parameter to `T *restrict`: the
C compiler assumes nothing else reaches the referent during the call. Unsafe code that
reaches a live `&mut` referent through another path (a raw pointer, a second reference)
while the call runs is undefined behavior. `&T` parameters stay plain `const T*`, because
writing through a const-cast `&Self` is allowed. `&&T` and `&&x` are two references (`& &T`,
`&(&x)`). Indexing a reference to an array (`r[i]` for `r: &[T; N]`) indexes the array, with
the array's rules; it assigns only through `&mut`.

## Generics

Monomorphized. Const generics work (`Array<T, const N>`).

```superc
fn id<T>(x: T) T { return x; }
struct Pair<A, B> { pub a: A, pub b: B }

// Turbofish for disambiguation
let p = Pair::<i32, bool> { a: 1, b: true };
// Inferred from the expected type or the field values (see inference.md)
let q: Pair<u8, bool> = Pair { a: 1, b: true };

// Const generic
let a = Array::<u8, 16>::new();
```

A symbolic array length is part of the type: `[T; N]` is a generic argument like any type
(`W<[T; N]>`), and an instance folds `N` (also `{N * 2}` or `(BITS + 63) / 64` forms) wherever
the array appears.

A const argument has its parameter's type and must fit it (`U::<{0 - 1}>` for `const N: u64` is
an error), and every integer type keeps its full range (`U<{u64::MAX}>` and
`U<18446744073709551615>` are one type). A braced expression computes step by step as it is
written, and every step must fit: a closed one (`{u64::MAX / 2}`) in the parameter's type, a
form over parameters in their type (literals take it; `{N + 300}` for `N: u8` is "integer
literal is out of range for 'u8'"), so `{N - 1}` for `N: u64` bound to u64::MAX is
18446744073709551614 and bound to 0 is the error `const expression {N - 1} overflows u64 for N =
0`. Spellings of one value are one type (`{N * 2 - N}` is `N`), but the steps still compute:
`{N * 2 - N}` bound to u64::MAX is `const expression {N * 2} overflows u64 for N = ..`, at the
step, and so is a closed `{K * 2 - K}` for a `u64::MAX` constant `K`. A shift that loses bits
overflows. Between constants `/` truncates and `>>` floors, as at run time; a form over
parameters floors, so an instantiation that divides a negative dividend inexactly is an error
(`const expression {(N - 10) / 4} truncates the negative quotient -9 / 4 for N = 1: ..`). A type
alias's steps are its user's: `type A<const M: u64> = F<{M * 2 - M}>` fails where `A<N>` is
instantiated with `N = u64::MAX`, and at `A<18446744073709551615>` directly. The constant
evaluator refuses such an instantiation too ("arithmetic overflow in a const-generic
expression"). An enum-typed const parameter takes a value of its own enum only: a variant
(`F<{D::Y}>` and `F::<{D::Y}>` alike, its discriminant, an explicit one included), a constant or a
const parameter of that enum (`F<K>`, `F<{K}>`); an integer or another enum's value is
"mismatched types", and so is an enum value for an integer parameter. A narrower parameter (or form) passes to
a wider parameter's position (`U<N>` for `N: u8` is `U<7>` at `N = 7`); a wider one to a narrower
position is "mismatched types". A local constant of a generic function may use its parameters
(`const S: usize = sizeof(T);`): each instance has its own value. A qualified constant is an argument
unbraced as braced, like a named one: a builtin limit (`F<u64::MAX>`, read as the literal of its
value), an associated constant of a builtin, a struct or an enum from a non-generic extend
(`F<Foo::K>`, in its own type) and a variant (`F<D::Y>`). With disjoint extends of a generic type
each defining the constant (`extend W<u8>`, `extend W<i32>`), `F<W::K>` takes the one whose type is
the parameter's, and a path names the instance, bare or braced (`F<W::<u8>::K>`, `F<{W::<u8>::K}>`;
the `<` after a `::` tells it from the type `W<u8>`, and `fmt` keeps the spelling), also a generic
extend's constant for a concrete instance (`F<{G::<u16>::S * 2}>`); otherwise it is "cannot infer the generic
arguments of associated constant 'K'; give explicit type arguments", with a note at each candidate. A module may qualify each of them
(`F<m::B>`, `F<{m::B}>`, `F<m::Foo::K>`, `F<m::D::Y>`, `g::<m::B>()`, and a builtin limit through
an alias, `F<m::U::MAX>`); only a `pub` constant is visible ("no public type or constant 'P' in the
imported module", "no associated constant 'Q' on 'm::Foo'"). A type for a const parameter is "expected a
constant for const parameter 'N', found type 'u64'", a value for a type parameter is "expected a
type for generic parameter 'T', found a constant", and a qualified path naming no constant is "no
associated constant 'FOO' on 'u64'".

An extend's generic parameters are solved from its target's arguments and, for a conformance, from
its interface's arguments, as an impl's are in Rust: `extend<const N: usize> f32 as Mul<V<N>>`
gives `2.0 * v` with `v: V<3>` the instance `N = 3`, which the right operand's type solves at each
use. A parameter that neither names is an error at the extend: "the generic parameter 'M' of this
extend appears neither in its target nor in its interface's arguments" (for an extend without an
interface, "the generic parameter 'U' of this extend does not appear in its target").

A conformance whose target is one of its own parameters is generic: `extend<T: Lane> T as Twice
{ .. }` conforms every type that satisfies `Lane`, a type parameter whose bounds entail `Lane`
included, with `T` the type itself. Its methods, inherited defaults and associated types reach
those types through a method call, an operator, a bound, a `dyn` value, a path call (`f32::twice(&x)`)
and a constant alike; a type outside the bounds has none of them ("cannot call 'i32::twice':
unsatisfied interface bounds" with a note at the generic conformance, "type 'u8' does not satisfy
bound 'Twice'" with the same note). `type_info::<T>().methods` lists the methods of the generic
conformances whose bounds `T` satisfies after its own. Only a conformance may be generic ("an extend
whose target is one of its generic parameters must be a conformance"), and not `Free`'s ("'Free'
cannot be implemented for every type that satisfies a bound"). A type conforms to an interface with
given arguments once: two generic conformances of one interface whose arguments meet for a type,
and a conformance of a type that also satisfies a generic one's bounds with arguments that meet, are
"conflicting conformances to 'Twice': a generic conformance also applies to this type", with a note
at the generic one.

An extend's target arguments solve its parameters as follows.
A bare parameter takes the instance's argument; a const form of one parameter without a division
(`extend<const N: u64> F<{N + 3}>`, `F<{2 * N}>`) gives it the value that inverts the form, which
must be an integer in the parameter's type; an argument that names no parameter (`extend P<u8>`,
`extend<T> P<i64, T>`) must equal the instance's. The extend applies only to the instances that
solve: `F<{N + 3}>` gives `F<10>` its methods with `N = 7`, and `F<2>` has none of them ("no field or
method 'get' on 'F<2>'"), nor its conformances. An argument that is itself a form or a parameter
solves when every value it takes does (`F<{M + 3}>` in a generic of `M`, not `F<M>`). A target
argument that places a parameter inside another type (`W<Vector<T>>`), a form of several parameters
or with a division and a parameter written in two arguments are errors at the extend. Only the arguments the target writes constrain it (an alias constrains all
of its instance's); `Free` is implemented for every instance, so its extend writes its parameters
in order.

A method or associated constant is defined once for any one instance. Two items of one name (two
methods, two constants, or a method and a constant, whatever their signatures) in plain extends of
one type that apply to a common instance are a duplicate definition, reported at the later one with
a note at the first: "duplicate definition of 'get' for 'P<u8>'". The later one is the later item of
the module; across modules, the item of the module that extends another module's type (a std item
comes first): "duplicate definition of 'len' for 'String': module '__std::string' also defines it".
Two extends apply to a common instance when every argument position their targets write unifies,
as the method lookup decides it, bounds aside: a parameter meets anything, two fixed arguments must
be equal, a form meets a constant it solves and another form whose values it shares (`F<{2 * N}>`
and `F<{3 * N + 1}>` meet at 4, `F<{2 * N}>` and `F<{2 * N + 1}>` never do); an alias target is its
type. So disjoint extends define one name each (`extend P<u8>` and `extend P<i32>`, `extend<A> Q<A,
u8>` and `extend<B> Q<B, i32>`), with symbols of their own for methods and constants alike, and a
conformance may define a name a plain extend also defines: a call through a bound or a `dyn` value
runs the conformance's own method (or the default it inherits), never the plain one.

An interface default body sees the interface's parameters bound to the arguments of the
conformance that supplies it, which may name the implementor's parameters
(`extend<const N: u64> G<{N + 1}> as I<{N * 2}>`); its written const-generic steps hold for
each implementing instance, the conformance's arguments included.

An associated constant of a generic extend has a value per instance and is named through one
(`W::<u8>::K`, `W::<T>::K` inside generic code; bare `W::K` cannot infer the arguments). Its
initializer may use the extend's parameters (`pub const S: usize = sizeof(T);`); each instance
is its own static datum. With disjoint extends each defining `K` (`extend W<u8>`, `extend W<i32>`),
`W::<u8>::K` names the one whose extend applies, and a bare `W::K` the only one whose type is the
expected type ("cannot infer the generic arguments of associated constant 'K'; give explicit type
arguments" otherwise, with a note at each candidate).

An unbounded `T` owns: uses move, leftovers drop. `T: Copy` (derived structurally, see the
ownership section of the skill) makes it copyable.

A bound on a generic interface requires a conformance with the bound's own arguments (written or
defaulted, `Self` read as the bounded type): `T: I<bool>` rejects a type that conforms only as
`I<i32>` ("type 'F' does not satisfy bound 'I<bool>': 'F' conforms to this interface only with
other arguments", with a note at that conformance). A type parameter satisfies a bound only through
its own bounds, `where` predicates and their superinterfaces, with the same arguments: an unbounded
`U` passed on to `g<T: K>` is "type 'U' does not satisfy bound 'K'". The same holds for a `where`
predicate, a superinterface a conformance requires, the bounds of an extend's parameters and those
of a struct's or enum's parameters, checked where an instance is written (`S<F>`) or inferred (a
literal). A call through a bound runs the method, or the default it inherits, of the conformance
with the bound's arguments in every instance and at compile time, and its signature reads the
interface's parameters as those arguments, also through a superinterface (`T: J<bool>` with
`J<B>: I<B>` calls `I<bool>`'s methods).

An operator whose left operand has a builtin type and whose right operand has a struct, enum or
vector type calls the conformance of the builtin type that accepts the right operand
(`extend f32 as Mul<V>` makes `s * v` and `2.0 * v` legal). An unsuffixed literal or literal-only
arithmetic on the left takes the one integer or float type with such a conformance; two such types
are "the literal's type is ambiguous: 2 types provide 'mul' for this right operand" with the note
"give the literal a type suffix". Without a conformance the builtin operator reports the operands.

An operator on a type parameter dispatches through its bound the same way: `t + 5` for
`T: Add<i32>` calls the `Add<i32>` conformance's `add` (with several bounds on the interface, the
one whose parameter takes the right operand), and so do the other operator interfaces (`-`, `*`,
`/`, `%`, `&`, `|`, `^`, `<<`, `>>`, unary `~`), their compound forms and indexing (`t[i]` through
`Index`, a written element through `IndexMut`). An associated type is read through the bound that
declares it: `T::Output` (also through a superinterface) is the conformance's `type Output = ..`
in each instance, and `Self::Output` in an interface signature or default body is the
implementor's. A bound may fix it: `T: Add<i32, Output = T>` (the binding follows the arguments;
only a generic parameter's or `where` predicate's bound may carry one), and a type argument must
then have that `Output` ("type 'M' does not satisfy bound 'Add<i32, Output = T>': its 'Output' is
'i64'"). A compound assignment through a bound needs the result to be `T` ("mismatched types: the
operator's result 'T::Output' is not 'T'" without the binding). `T::Output` names nothing no bound
declares ("no type 'Foo' in 'T'"), and two bounds declaring it differently are "ambiguous associated
type 'Output': several bounds of 'T' declare it". A value of an unbound `T::Output` owns and moves
as an unbounded `T` does.

An interface's associated function called through a type parameter (`T::count()` for
`T: I<bool>`) runs the conformance the parameter names, whatever its result or first argument, in
every instance and at compile time. A call on a concrete receiver (`k.sum(true, false)`, the path
form `K::sum(&k, true, false)`, through auto-deref too) chooses among every method of that name
an extend of the receiver defines and every default a conformance without its own inherits, each
bound to its conformance, by the overload score of [inference.md](inference.md): with
`extend K as Make<i32>` overriding `sum` and `extend K as Make<bool>` inheriting it,
`k.sum(true, false)` runs the default under `Make<bool>` and `k.sum(3, 4)` the override. The chosen
body runs directly, through a bound, through dyn and at compile time alike. Candidates that fit
equally are an error: "ambiguous call to 'make2': 'K' conforms to 'Mk' with several arguments that
fit" when they are one default under several conformances (`k.make2(1, 2)` with `Mk<i64>` and
`Mk<u64>`), else "ambiguous call: two candidates for 'sum' fit equally well"; an unsuffixed literal
prefers its default type (`Mk<i32>` over `Mk<i64>`). Without arguments, only the expected result
chooses: with `Conv<i32>` and `Conv<bool>` each defining `conv`, `let b: bool = x.conv();` runs the
`Conv<bool>` one and `let d = x.conv();` is ambiguous. A call through a type parameter whose bounds
reach the interface with several arguments (`u.conv()`, `U::mk()` for `U: Conv<i32> + Conv<bool>`)
chooses among those conformances the same way ("ambiguous call to 'conv': 'U' conforms to 'Conv'
with several arguments that fit"), and a method named as a function value (`K::conv`) is the one
whose function type is the expected type.

A path through a generic type written without its arguments (`W::f()`, `W::f(3u8)`) chooses among
the methods of that name every extend of the type defines the same way, each candidate's extend
parameters open and bound by the call's evidence: `W::f(1u8)` runs `extend W<u8>`'s `f` and
`W::f(-1)` `extend W<i32>`'s, `let a: W<i32> = W::mk();` the one whose result is `W<i32>`, and the
chosen extend's parameters bind from the arguments and the expected type. Candidates that fit
equally are "ambiguous call: two candidates for 'mk' fit equally well"; an inherited interface
default, which names no instance, is "cannot infer the generic argument 'T' for this call; add an
explicit argument".

An interface method may declare generic parameters (`fn conv<U: Num>(self: &Self, n: i32) U;`). An
implementation matches it by position: the same number and kinds of parameters (a const parameter's
type too), bounds equal as sets once renamed (inline or in `where`, in any order), and the parameter
and result types read with the interface method's parameters as the implementation's; anything else
is "method 'conv' does not match interface signature". A call through a bound (`t.conv::<u8>(3)`,
`T::conv::<u8>(t, 3)`, or inferred from the expected result), on a concrete receiver and from a
default body runs the implementation's instance for those arguments (`C__conv__u8` in C) or the
default body's, at run time and at compile time. Such an interface is not dyn-compatible.

A method call takes a turbofish as its path form does: `x.m::<u8>(3)` is `X::m::<u8>(&x, 3)`, through
autoref, auto-deref and `Box` alike. Its type-level arguments bind the
method's leading generic parameters in overload selection (a candidate with fewer is not viable),
inference, bounds and compile-time evaluation; a lifetime argument binds none. More arguments than
the function declares are "'m' takes 1 generic argument but 2 were supplied" at the first extra one,
for a call and a function value (`id::<i32, u8>`) alike; a field ("field 'f' takes no generic
arguments"), a function pointer and a closure take none. A method of a `dyn` value has no generic
parameters (dyn-compatibility), so its turbofish is always too long.

`Self::` in an expression names the implementing type as its name does: `Self::f()`,
`Self::f::<T>()`, `Self::K` and `Self { .. }` inside an extend (in a generic extend, its target
instance `W<T>`), and in an interface default body the implementor (`Self::count()` calls the
conformance's associated function, as `T::count()` does through a bound). Outside an interface or
extension it is "'Self' is only valid inside an interface or extension". A path may name both the
type's and the function's arguments: `W::<u8>::conv::<i64>(6)`.

## Closures

| Form | Meaning |
|------|---------|
| `\|x: i32\| x * 2` | Compact closure |
| `fn(x: i32) i32 { return x + 1; }` | Anonymous function |
| `fn(i32) i32` | Function pointer type (no captures) |
| `F: fn(i32) i32` | Generic bound (any callable) |
| `F: fn move(i32) i32` | Ownership-marked bound |
| `dyn fn(i32) i32` | Structural trait object |
| `Box<dyn fn(i32) i32>` | Owned dyn closure (from a closure or function value, or `Box::new` of one) |

A function-pointer type is its signature, structurally: two spellings of one signature are
one type (`fn(i32)` and `fn(i32) void` too, in `Option`, `Vector` and array elements alike),
and substitution reaches its parameters and result, so a generic struct's `fn(T) T` field is
`fn(i32) i32` in `W<i32>` and inference takes `W`'s arguments from it. A plain function, a
non-capturing closure and a turbofished generic function (`let f = id::<i32>;`) are values of
it; naming an `unsafe fn`, or an extern function without `@unsafe(safe)`, as one needs `unsafe`. `dyn fn(..)` may name generic parameters (`struct D<T> { pub f: Box<dyn fn(T) T> }`) and
substitutes the same way.

Capture rules:
- **Read**: value copied at closure creation (default); a fixed-size array copies whole.
- **Mutated**: body assigns, borrows mutably or calls a `&mut self` method on a non-`Free`
  capture → implicit `&mut` capture. Outer must be `mut`. The outer binding stays mutably
  borrowed while the closure lives.
- **Owned**: body uses a `Free` value → moved into env. Closure becomes `Free`.
- **Borrowed**: the closure meets a plain `F: fn(..)` bound → its `Free` captures are borrowed
  (`&`, or `&mut` when mutated) and the closure owns nothing. The outer binding stays borrowed
  (not moved) while the closure lives. A closure with a `&mut` capture is not `Sync`.

## Trait Objects (dyn)

```superc
fn total(a: &dyn Shape, b: &dyn Shape) i32 { return a.area() + b.area(); }

let mut v: Vector<Box<dyn Shape>> = Vector::<Box<dyn Shape>>::new();
v.push(Box::<Circle>::new(Circle { r: 1 }));
```

A `dyn` value is a 2-word fat pair `{data, vtable}`. Three spellings: `&dyn I` (borrowed),
`&mut dyn I` (mutable), `Box<dyn I>` (owned, drop glue deep-frees). One vtable per source
type, dyn type and erasure kind: a borrowed erasure's table has no `__free`, an owned one's
frees the payload (per allocator for `Box<T, A>`).

A generic interface erases with its arguments: `&dyn I<bool>` needs a conformance whose
interface arguments (type and const) are exactly `I<bool>`, at every coercion site; a
conformance with other arguments is "cannot erase 'F' to '&dyn I<bool>': 'F' conforms to
this interface only with other arguments". With several conformances (`extend P as I<i32>`,
`extend P as I<bool>`), the vtable calls the methods of the one with the dyn type's
arguments, and a default body it inherits is instantiated under those arguments.

A container element dispatches directly: `v.at(i).area()` (a method call on
`&Box<dyn I>`) goes through the vtable, as does the explicit `(*v.at(i)).area()`.

A superinterface's methods are in the vtable too, under the arguments the hierarchy gives it: for
`interface B: A<i32>`, `b.get()` on a `&dyn B` runs the `A<i32>` conformance's `get` (or the default
it inherits) even when the type also conforms as `A<bool>`, and `dyn B<T>` with `B<T>: A<T>` reads
`A<T>` for the dyn type's `T`. A dyn value upcasts to a superinterface with exactly those arguments,
borrowed or owned (`&dyn B` to `&dyn A<i32>`, `Box<dyn C>` to `Box<dyn A<bool>>`); other arguments
are a type mismatch. `e as &dyn I` is the same erasure or upcast as the implicit coercion, and a
cast no coercion allows is "invalid cast from '&T' to '&dyn N'".

Dyn-compatibility: every method takes `Self` by reference, no generics on methods, and `Self`
appears only as the receiver; each interface of the hierarchy is reached with one argument list
("a superinterface is reached with two different argument lists") that names no `Self` ("a
superinterface argument names 'Self'"), and no two methods of the hierarchy share a name. A method may return several results or a
fixed array (`fn dims(self: &Self) (i32, String)`, `fn corners(self: &Self) [i32; 2]`): its vtable
slot returns the shared result carrier, and a call through `&dyn`, `&mut dyn` or `Box<dyn>`
destructures it as a direct call does, for an inherited default as for an override.

A `dyn fn(..)` erasure and a `fn(..)` value compare the whole signature: every parameter and
every result, so a function with several results never matches other results or none.

A function pointer or `dyn fn` may have several results (`fn(i32) (i32, String)`) or a fixed-array
result (`fn(i32) [i32; 2]`): a function, a closure (capturing ones through `dyn fn` or a `F: fn(..)`
bound) or a turbofished generic function converts to it, fields and containers hold it, and a call
through it destructures as a direct call does. In C every function and function value with one
result list returns one carrier struct (`__sc_ret<n>__<types>`, `__sc_reta__<array>`).

## Enums

Payload-less enums lower to C `enum`. Payload-bearing enums lower to tagged unions.
A payload-less variant may take an explicit discriminant, a constant expression that may
name constants and other enums' variants; a variant without one takes the previous
discriminant plus one. The discriminant is the tag in memory and in the C tag enum, and
matches, reflection (`VariantInfo.tag`) and the derived `Ord` use it. Two variants of one
enum with the same discriminant, or a discriminant outside the i32 range, are errors
(an `extern "C"` enum is C's and is exempt).

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
let c = switch t {    // tuple patterns: nested patterns, literals, `_`, `mut` bindings
    ((1, true), n) => n,
    ((_, _), _) => 0,
};
```

A tuple pattern `(p0, p1, ..)` also works in `if let` and `while let`; the element count must
match the tuple's arity.

`t.0.1` lexes `0.1` as a float ("nested tuple access needs parentheses: write '(t.0).1'"). This
is deliberate: do not add dot-number lexing. A return list `(A, B)` is several results, not a
tuple; return a tuple through an alias (`type P = (A, B);`).

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

A generic alias expands with its arguments substituted, at any nesting depth and across
modules; defaults, const parameters and lifetimes apply as on a struct:

```superc
type Q1<T> = Pair<T, T>;
type Q2<T> = Q1<Q1<T>>;        // Q2<i32> is Pair<Pair<i32, i32>, Pair<i32, i32>>
type Arr3<T> = Array<T, 3>;
```

The argument count must match the alias's parameters (after defaults): "'Q' takes 1 generic argument
but 2 were supplied", as for a struct or an enum. A generic alias
cannot be an `extend` target; extend the aliased type. A cyclic alias is an error.
