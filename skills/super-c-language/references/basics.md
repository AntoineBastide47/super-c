# Bindings, Functions, Structs and Enums

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
Contract checks kept at run time (`-fcontract-checks`) make an `ensures` check follow the call, so
it stays a call, unless the build proved the clause: a proved check after the call is dropped.

A function or closure with results cannot reach the end of its body ("function 'f' can reach the
end of its body without returning a value"): every path ends in a `return`, a call of a `!` or
`@noreturn` function, a `loop` no `break` leaves, or an `if`, `switch`, block or `unsafe` block
whose every way out is one of these. A `while` or a `for` can run no iteration, so it does not end
a path.

`return pair();` returns the call's tuple: its type must be the function's result type exactly (no
widening: "mismatched types: expected '(i32, i32)', found '(i32, i64)'").

### Contracts

```superc
fn add_mod(a: u32, b: u32, m: u32) u32
    requires m > 0, m <= 1000, a < m, b < m
    ensures |r| r < m
{
    let s = a + b;
    return if s >= m { s - m } else { s };
}
```

Clauses follow the signature, before the body: `requires C` (each caller proves it), `ensures C` or
`ensures |r| C` (`r` names the single result; a function with none or several has no binder, error
534) and `decreases E` (an integer measure, error 535). A comma list is several clauses. A `while`,
a `loop` and a `for` over a range written in place (`for i in a..n`) take `invariant C` and
`decreases E` after the header; another `for` takes none (error 536). The words are contextual
keywords. A clause only computes its condition: it calls only `const fn`s, drops nothing and writes
nothing (error 537). An extern or intrinsic function has no clause.

The compiler proves every clause in every build; one it cannot prove fails the build (error 538,
"cannot prove ..."), and the note gives the parameters of a counterexample the evaluator confirms
when it finds one (`for example: x = 0, y = 3`). It proves:

- a callee's `requires` at each call, from the facts on the path to it;
- each `ensures` at each return;
- an `invariant` when the loop starts and after each iteration (a counted range loop knows its
  binding lies from the start up to the end);
- each operation that can trap (overflow, a division by zero, a shift count, a narrowing) does not,
  in a function with clauses;
- `decreases`: at each call of the function to itself, and at each call to a function of the same
  cycle of calls, the measure is at least 0 and below its value at the caller's start; every
  function of a cycle needs a measure; in a function with one, each loop needs its own unless it
  counts over a range with an end or over a collection. A loop's measure is at least 0 and below
  its value at the iteration's start, at each iteration's end.

`@prove_exhaustive` on a function with a body proves it by evaluation instead: the compiler runs the
body at compile time once for each value of its parameters, at most 65536 inputs, in order with the
first parameter most significant. A parameter is a `bool`, an integer, an enum without payloads, or
a shared reference to one of them; an integer ranges over the bounds its `requires` implies
(`requires i < 300` on a `usize` gives 300 values). Each run checks each `ensures` at its return,
each loop `invariant`, each callee's `requires`, each `assert`, that no operation traps or panics
(also without clauses), and that the run ends within its equal share of 2^26 steps; an input whose
own `requires` fails is skipped. The first failing input is reported at the clause, the call or the
statement (`for example: c = Color::Blue, b = true`). Another parameter type, more inputs, or a
generic function is error 540; a `decreases` on the function or on a loop in it is error 541 (each
run ended), and a cycle of calls needs no measure on such a function. A lemma with an empty body
proves a table: `@prove_exhaustive lemma inv(x: u8) ensures g(f(x)) == x {}`. The evaluator nests at most
48 calls: a deeper recursion fails with "const-eval call depth exceeded"; narrow the inputs with
`requires`.

A call assumes the callee's `ensures`, never its body. An interface's method may state `requires`
and `ensures` without a body (a `decreases` needs a body, error 539): a call through a bound or a
`dyn` proves the interface's `requires` and assumes its `ensures`; each conformance's method proves
its own `requires` from the interface's and the interface's `ensures` at its returns. A function
with a `requires` clause cannot be a value: a call through the value would prove nothing.

The proofs model integers exactly, `u128`, `i128` and `UInt<N>` or `Int<N>` of up to 512 bits too
(their comparisons, `+ - * / %`, bit operations, shifts, conversions and literals): a product of two
unknowns lies within the products of its operands' ranges and is linear where the facts fix one
operand (`requires k == 3` makes `a * k` the value `3 * a`), and a division or shift by a constant
bounds its quotient (`requires a < 1000` proves `a / 2 < 500`). A goal over bit operations, shifts,
casts, divisions or products that the arithmetic cannot decide is decided on the bits of its values
(a SAT refutation): `x ^ y ^ y == x`, `x & (x - 1) < x` for `x > 0`, and the built-in integers'
`wrapping_add`, `wrapping_sub`, `wrapping_mul`, `wrapping_neg`, `rotate_left` and `rotate_right`
(`x.rotate_left(n).rotate_right(n) == x`); its counterexample comes from the bits' model. A wider integer and a float are
values the proofs do not take apart. They also model struct fields, arrays of a constant length and
their views (an element read by an index the path proves in bounds), and references; a call that
may write memory, a drop and a write through a pointer forget the values a reference reaches. Equal
operands give equal results: `requires i == j` proves `a[i] == a[j]`, `half(x) == half(y)` for a
`const fn`, `x / 3 == y / 3`, also where the rows imply the equality (`x <= y, y <= x`). A
proof that goes over its fixed budget is not proved. `-fno-prove` skips the proofs;
`-fcontract-checks` also checks the clauses at run time (binary skill, build-toml.md). Without it a
build emits no check: the output is the same as without the clauses.

### Ghost Code

```superc
spec fn pow2(n: nat) nat
    decreases n
{
    return if n == 0 { 1 } else { 2 * pow2(n - 1) };
}

lemma pow2_pos(n: nat)
    ensures pow2(n) > 0
    decreases n
{
    if n > 0 {
        pow2_pos(n - 1); // the induction hypothesis
    }
}

fn shifted(x: u32) u64
    ensures |r| r as int == x as int * pow2(8)
{
    assert pow2(8) == 256 by {};
    return x as u64 << 8;
}
```

Ghost code is proved and never runs: no build emits it, `-fcontract-checks` neither. It is the body
of a `spec fn` or a `lemma`, every clause, an `assert P by { B };` block, a lemma call
statement with its arguments, and a `ghost` statement. `spec` and `lemma` are contextual words at item scope (top level and
in an `extend`). A lemma has no return type; its `requires` and `ensures` are the theorem, its body
the proof: a recursive call with `decreases` is induction, an `if` or `switch` a case split, a lemma
call applies that lemma. A spec function is a mathematical function: the proofs read its body as
its definition, one unfolding per call (a call over constants unfolds further); it cannot loop.

- `int` and `nat` are exact integers (`nat` at least 0) that only ghost code names (error 542).
  Literals take them, `nat` converts to `int` implicitly, `x as int` and `x as nat` from every
  integer (`as nat` must be proved at least 0). They have `+ - * / %` and comparisons, no bit
  operations; a `nat` below 0 is an overflow to prove absent.
- Only ghost code calls a spec function (error 543). A lemma call is a statement of its own (error
  544). An `assert .. by` block cannot return or use `?` (error 546), and a `break` or
  `continue` in it names only a loop inside it. It writes only its own
  locals and calls only `const fn`s, spec functions and lemmas (error 537).
- In ghost code every check is an obligation: an `assert`, an index, a division, a shift count, a
  panic. A spec function and a lemma must end: recursion needs `decreases`, each loop in a lemma
  needs a measure. Ghost code assumes a callee's `ensures` only when the callee ends (a spec
  function, a lemma, a `@prove_exhaustive` function).
- `assert P by { B };` proves P after B (a lemma call, a case split) and then assumes it.
- Under `-fcontract-checks` a clause that calls a spec function or converts into `int` or `nat` is
  error 545: it has no run-time form.

- A spec function or a lemma without a body ends its clauses with `;` and must be `@trusted`
  (error 557): an axiom, which no proof checks. Its `ensures` define its calls.
- In ghost code `==` and `!=` compare any two values of one type without an `eq` method (a `Seq`, an
  array, a type parameter): the proofs' equality, error 545 under `-fcontract-checks`.

### Specifications

```superc
fn find(xs: []u32, v: u32) usize
    requires exists k in 0..xs.len() { xs[k] == v }
    ensures |r| r < xs.len() && xs[r] == v
{
    for i in 0..xs.len()
        invariant forall k in 0..i { xs[k] != v }
    {
        if xs[i] == v {
            return i;
        }
    }
    return 0; // no index is left: the invariant and the requires exclude this end
}

fn bump(x: &mut u32)
    requires *x < 100
    ensures *x == old(*x) + 1
{
    *x += 1;
}
```

`==>`, `forall`, `exists` and `old` are valid only in ghost code (error 551).

- `a ==> b` is `!a || b`; it binds weakest of the operators and groups to the right
  (`a ==> b ==> c` is `a ==> (b ==> c)`).
- `forall i in a..b { E }` and `exists i in a..=b { E }` range over an integer range with both ends
  (error 552); `i` has the range's type. The proofs instantiate a `forall` they assume at the terms
  of the goal and the facts (a bounded number of rounds), and an `exists` they assume gives a
  witness; a needed instance at a term the formulas do not name needs an `assert` of it.
  `-fcontract-checks` runs them as loops.
- `old(e)` is `e` at the function's entry: in an `ensures`, a loop's `invariant` and ghost code of
  a function (error 553), of a `Copy` value over the parameters (`old(*x)`, `old(self.n)`,
  `old(v.len())`). A call's `ensures` reads the callee's `old` at the call.
- `ghost let mut seen: int = 0;` declares a ghost variable, of a `Copy` type (error 556), that only
  ghost code reads or writes (error 554); `ghost seen = seen + 1;` writes it, and writes nothing
  else (error 555). The proofs read it like a local; no build has it.

`std::spec::seq` gives `Seq<T>`, a finite sequence, equal to another of the same length and
elements: `Seq::<T>::empty()`, `s.len()` (a `nat`), `s[i]` (`i: int`), `s.push(x)`,
`s.update(i, x)`, `s.subrange(lo, hi)`, `s.concat(t)`, `s.take(n)`, `s.skip(n)`, and `utf8(c)`, the
bytes of a `char`. `view()` is the sequence a `Vector`, `String` (its bytes), `str`, `[]T` or
`[]mut T` holds: `v[i]` is `v.view()[i]` and `v.len()` its length. The proofs know how `Vector`'s
`push`, `pop`, `clear`, `new`, `with_capacity`, `as_slice` and `v[i] = x`, `String`'s `push`,
`push_str`, `clear`, `new` and `as_bytes`, and a write `xs[i] = x` through a `[]mut T` change the
view; another method that takes a container's `&mut` makes its view unknown.

`std::spec::arith` holds proved lemmas: products (`mul_eq`, `mul_nonneg`, `mul_pos`, `mul_le`,
`mul_lt`), powers of two (`pow2`, `pow2_pos`, `pow2_add`, `pow2_le`), division and remainders
(`div_mod`, `mod_unique`, `mod_mod`, `mod_add_multiple`, `mod_add`, `mod_mul`). A call
`mod_mul(a as int, b as int, m as int);` proves `a * b % m == (a % m) * (b % m) % m` at that
point.

### Constant-Time Code

```superc
import std::crypto::secret as *;

@constant_time
fn same(a: []Secret<u8>, b: []Secret<u8>) bool {
    if a.len() != b.len() {
        return false; // the lengths are public
    }
    let mut d = Secret::<u8>::new(0);
    for i in 0..a.len() {
        d = d | (a[i] ^ b[i]);
    }
    return d.eq(Secret::new(0)).declassify();
}
```

`std::crypto::secret::Secret<T>` (`T` is `u8`, `u16`, `u32`, `u64`, `usize` or `bool`) holds a value
whose bits no timing may reveal. Its methods are the only operations on it, each without a branch:
`new`, `declassify` (the one way out), `+ - * -x` (wrapping), `& | ^ ~`, `<<` and `>>` by a public
count below the width, `rotate_left`, `rotate_right`, `eq`, `ne`, `lt`, `le`, `gt`, `ge` (each a
`Secret<bool>`), `Secret::pick(c, a, b)` (`a` where `c`, else `b`) and `cast::<U>()`. So the type
checker rejects a branch on a secret, an index by one, a division, `==` and `<` (its `eq` gives no
`bool`), a cast and a read of the field. A buffer of secret bytes is `[]Secret<u8>`: its length
and its indexes are public.

`@constant_time` on a function with a body (error 56 elsewhere) makes the build check the code it
generates for it, after the optimizer (error 558), also when nothing calls it: no branch, memory
address or size, division or remainder, float operation, atomic or vector operation, system call,
indirect call or select of a float or a vector depends on a secret, and no secret passes to a call or
returns other than inside a `Secret` in memory. Only such a function reads a secret (std's `Secret`
methods are `@constant_time`), so a helper that only passes a `Secret` on, a generic function such as
`Vector<Secret<u8>>::push`, a closure and a `dyn` call need no attribute. No function may call a C
function that takes a `Secret` (through a reference, a slice or a field too) or take its address. A
value `declassify` gives is public from there. A `@constant_time` function is inlined only into another
one, so the code the check sees is the code that runs; loops over secrets vectorize. `--emit-c` puts the
checked machine code in the C tree (`__sc_ct.o`, a unit): no C compiler compiles these functions, and a
target without a native backend is an error. On wasm32 the engine compiles the checked wasm
instructions: it is part of what the guarantee trusts, as the processor is.

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
generics section of [types.md](types.md)).

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
