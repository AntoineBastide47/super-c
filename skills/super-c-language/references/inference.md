# Type Inference Rules

The language rules for local type inference. These rules are normative: the checker
implements them, and a checker behavior that contradicts them is a compiler bug.
`tests/infer_test.spc` locks the observable behavior; its "known gap" cases name the
places where the current engine still deviates from a rule here.

## Scope

Inference is local to one function, method, constant initializer, or closure body.

Inferred inside a body:

- A local binding's type from its initializer.
- An expression's type from its operands and its expected type.
- Integer and float literal types from their uses.
- Generic call arguments from explicit arguments, the receiver, value arguments, the
  expected result, and declared bounds.
- Generic struct literal arguments (`Pair { a: 1, b: 2 }`) from the expected type and the
  field values.
- Closure parameter and result types when the surrounding call or expected function
  type provides them.
- Array lengths and other const generic values from exact linear equalities.

Never inferred (the signature barrier):

- Function and method parameter and result types.
- Struct, enum, interface, extend, and global declaration types.
- Generic parameter lists and their bounds.

## Literal defaults

- An unsuffixed integer literal defaults to `i32`, or to the first of `i64` and `u64` that
  holds its value when `i32` does not (`let x = 3000000000;` is an `i64`).
- An unsuffixed float literal defaults to `f32`, or to `f64` when its value is past the f32
  range (`let f = 1e39;` is an `f64`). The `f32` default is a deliberate choice, parallel to
  the `i32` integer default; do not change it to `f64`.
- Literal-only arithmetic (unsuffixed literals under `+ - * / %`, `& | ^ << >>`, unary `-`
  and parentheses) is typed as one expression. An expected builtin type of its kind (from a
  declaration, a parameter, a return, a struct field, an array element, a compound assignment, or
  the other operand of an enclosing operator) types every operand: `let z: i64 = 2000000000 * 2;` computes in `i64`. Without one it takes the first of
  `i32`, `i64` and `u64` in which no step overflows (`2000000000 * 2` and `1 + 3000000000` are
  `i64`), never a library integer; a float expression takes `f32`, or `f64` past the f32 range.
  Integer and float literals never mix: an integer literal never takes a float type (`1 + 2.0`,
  `let f: f32 = 1;` are errors). types.md, "Numeric Literals", has the errors.
- A suffix (`5u64`, `1.5f64`) pins the literal type; context cannot change it. A base
  prefix (`0xFF`) or a minus sign does not pin it.
- A typed context adapts an unsuffixed literal before the default applies: typed
  operands win over defaults, and the default applies only after all other
  information is exhausted.
- A literal under `&` or `&mut` (at any depth: `&1`, `&&1`) adapts to the expected
  pointee type: `map.get(&1)` with `Map<u64, V>` passes a `&u64`. A typed value under
  a reference never converts: `&x` with `x: u8` does not become `&u64`.
- A literal that does not fit its selected type is an error, whether the type came
  from a suffix or from context; so is a float literal that meets an integer type.
  A negated literal never takes an unsigned type (`let x: u32 = -1;` and `z - -1` with
  `z: usize` are "cannot apply unary operator '-'" errors). A negated literal reaches its signed
  type's minimum: `-128i8` and `let x: i8 = -128;` are accepted, `-2147483648` is an `i32` and
  `-9223372036854775808` an `i64`.
- A literal wider than 64 bits requires a wide expected type (`u128`, `Int<N>`,
  `UInt<N>`) or a width suffix; it never defaults.

## Safe conversions

Assignability admits exactly the conversions below. Inference selects only these; a
selected conversion is recorded once as a typed fact, and later stages never infer
another one. A conversion cannot remove `const`, add mutation rights, widen a
lifetime, change ownership, or manufacture a raw pointer from a safe reference.

Ranked from best to worst for candidate comparison:

1. Exact type equality.
2. Reference adjustment: `&mut T` to `&T`; auto-deref steps through a declared
   `deref` (through `deref_mut` when the use mutates: assignment, `&mut`, a
   `&mut self` receiver, or a `&mut W` to `&mut Target` coercion).
3. Built-in widening between scalars (the `bt_widens` lattice: smaller to larger
   same-signedness integers, unsigned to a wider signed integer, `f32` to `f64`; no integer
   converts to a float implicitly).
4. Unsized coercions: array to slice, `&T` to `*const T`, pointer to `*void`,
   concrete to `dyn` erasure, `Box<T>` to `Box<dyn I>`.
5. Literal adaptation (an unsuffixed literal re-typed by context).
6. User conversions through `From`/`widen` (explicit conformances only).

The integer widening matrix and the reference, pointer and void-pointer coercion matrices are
user decisions, pinned by `int_widening_matrix`, `ref_pointer_coalescing` and
`void_pointer_coalescing` (tests/typechecker_test.spc); do not change them without asking.

Nested type positions require equality, not conversion, unless the declared variance
of the position says otherwise. A top-level safe conversion never makes a nested
generic argument convert.

## Branch joins

- With an expected type, each branch of `if`/`switch` coerces to it independently.
- Without one, all branch result types must be equal after `Never` absorption
  (a diverging branch adopts the other branch's type) and literal adoption (an
  unsuffixed literal branch takes the other branches' numeric type).
- A block that ends in `return`, `break`, `continue` or a diverging call has type `Never`.
- There is no implicit least-upper-bound: `if c { 1i32; } else { 2i64; }` without an
  expected type is an error.
- `break value` joins under the same rule: all break values of one loop must agree
  or coerce to the loop's expected type.

## Generic argument inference

Evidence binds a generic parameter in this order, and all evidence must agree:

1. Explicit turbofish arguments (`f::<T>(..)`, `X::m::<T>(..)`, `x.m::<T>(..)`), bound to the leading
   parameters in order; a lifetime argument binds none.
2. The receiver's instance arguments (owner substitution).
3. Value argument types against declared parameter types, structurally.
4. The expected result type.
5. Declared interface bounds (arguments of a proven conformance): with `T` known, a bound
   `T: I<A>` gives `A` the arguments of the one conformance of `T` to `I` (a type parameter's own
   bounds are its conformances) whose arguments fit what the other evidence already fixed. When
   several fit and differ where a parameter is still open after every other obligation, the call is
   "cannot infer 'A': 'P' conforms to 'I' with several arguments"; later evidence (a literal
   default) may still decide it first.
6. Declared defaults, then literal defaults, only after everything above reaches a
   fixed point. An unsuffixed literal argument, also under `&` or `&mut`, is not
   evidence: it adopts the type the other evidence gives its parameter (`h(&4, 5u16)`
   with `h<T>(x: &T, y: T)` binds `T = u16`).

A repeated generic parameter must unify with every use: an existing binding that
disagrees with a later use is a conflict error, never silently kept. Acceptance
never depends on argument order. An unresolved parameter after defaults is a type
error at the call, not a downstream failure.

A generic enum variant constructor (`Option::Some(x)`, `Option::None`, `Result::Ok(x)`)
infers its instance the same way: from an expected instance of the same enum (a return
type, a declared binding, a parameter, the other side of `==`/`!=`, the element type an
array literal's context gives it), then from its payload
arguments, then from declared defaults. A unit variant with nothing to infer from is an
error; write the instance (`Option::<T>::None`). A struct-payload variant literal
(`Sh::Pt { x: 2, y: 5 }`) infers its instance the same way, from its field values as a
struct literal does; the type arguments follow the enum name (`Sh::<i16>::Pt { .. }`), and
`Sh::Pt::<i16> { .. }` or `Option::Some::<i32>(1)` is an error. An array literal passes its expected element
type (from an annotation or an array or slice parameter) to such constructors, to closures,
to nested array literals, and to generic functions named as values (`[twice, id]` for
`[fn(i32) i32; 2]`). A generic function named as a value takes its arguments from a turbofish
(`id::<i32>`, a value with no annotation) or from the expected function-pointer type (an
annotation, a parameter, a struct field, an array element). Elements with no type of their
own (`null`) take the other elements' type or the expected element type (`[null, null]` as
`[*mut i32; 2]`), and `[]` takes the element type of an expected array or slice. A tuple-struct constructor or enum tuple variant gives each argument its
element type as the expected type when that type is concrete, as a struct literal field does
(`TC([7, 8])` for `struct TC([i64; 2])`).

A generic struct literal written without type arguments (`Pair { a: 1, b: 2 }`, also
after `new`, or through a generic alias: `Q1 { a: 1u8, b: 2u8 }` for
`type Q1<T> = Pair<T, T>` infers the alias's `T`) infers its instance the same way. An expected instance of the same struct
(an annotation, a return type, a parameter, a `&` operand's expected pointee, the
pointee of `new`'s expected pointer, a field of an enclosing literal; a generic alias
expands first, so `Q2<i32>` expects `Pair<Pair<i32, i32>, Pair<i32, i32>>`) gives the
instance, and each field value is checked against its field type under it. Without one,
the field values are checked first (a field whose declared type names no parameter
gives its value that expected type), then non-literal values bind the parameters (an
array value binds a const length, `Buf { d: [1u8, 2, 3] }` is `Buf<u8, 3>`), then
declared defaults, then literal defaults. Conflicting field values are an error; a
parameter still open is an error at the literal: `cannot infer the generic argument 'T'
of this struct literal; give it an expected type or explicit type arguments`.

## Const generic inference

- A bare const parameter in a parameter position (`[T; N]`) binds from the
  argument's length exactly as a type parameter binds, also through references and at
  every nesting level (`&[[u8; C]; R]`). An array literal argument takes its element type
  from a parameter whose only open part is its length (`f([1, 2])` for `a: [u8; N]`).
- A linear const expression with one unknown solves when exact integer division
  gives one value; division with a remainder, overflow, or a cycle is an error.
- An inferred value takes the parameter's type: an array count binding a `u8` length
  parameter is a `u8`, and a value that type does not hold is "const generic argument
  300 is out of range for 'u8'".
- Conflicting solved values for one const parameter are an error.
- A multi-variable or non-linear equation is never solved; it requires an explicit
  const argument.

## Closures

- An expected function type (from an annotation, a declared parameter, or a generic
  call whose parameter resolved) supplies untyped closure parameters and the result.
- Explicit annotations always win and bind immediately.
- A closure whose parameter types depend on generic arguments still being solved is
  checked once, after those arguments resolve; it is never re-checked per overload
  candidate.
- A standalone closure with untyped parameters and no expected function type is an
  error that asks for the annotation.

## Overloads and ambiguity

When several declarations match a call or member use, one candidate is selected by
this lexicographic score, best first. On a concrete receiver the candidates are the methods its
extends define and the interface defaults its conformances inherit, each default read under its
conformance's arguments. Through a generic type written without arguments (`W::f(..)`) they are the
methods of every extend of the type, each extend's parameters inferred with the candidate's own. A
call's turbofish binds each candidate's leading parameters first; a candidate with fewer parameters
than the turbofish names is not viable:

1. Fewer safe conversions (by the rank list above).
2. Fewer reference adjustments or dereferences.
3. Fewer literal defaults.
4. Fewer generic defaults.
5. More exact parameter matches.
6. A more specific receiver or interface relation, where the language defines one.

Two candidates with equal best scores are an ambiguity error; its notes name each candidate (or the
conformances, or the bounds of a type parameter) at its source location. Source order and
declaration order never break a tie. An error type never makes a candidate viable and never
selects an overload.

## Error types

A rejected type (an annotation, a signature or a generic argument that does not lower) and a
rejected expression (an unknown field or method, a failed call, an invalid operand) have the
error type, and the error is reported once, where it is. The error type is compatible with
every type and satisfies every bound; as evidence it binds every generic parameter it meets to
itself; a type built over it (`Vector<error>`, `&error`) is the error type. Nothing that uses
it reports another diagnostic: a mismatch, an unresolved generic argument, an operator, a
condition, a pattern, a loop, a format argument, or a constant evaluation that needs it.

## Limits

- A generic item declares at most 8 type parameters (a declaration error beyond).
- Candidate search (8 candidates) and constraint counts have fixed compiler limits;
  exceeding one reports the limit and the source expression. The solver worklist needs no
  budget: every round binds a new slot, so it ends after at most one round per slot.

## Current engine deviations

The engine still deviates from the rules above in these known ways, each locked by a
regression case in `tests/infer_test.spc`:

- Top-level directional evidence joins order-independently under the modeled
  conversions (identity, integer widening, `f32` to `f64`, `&mut T` to `&T`). An
  unmodeled conversion still falls back to the first use's binding, so acceptance
  can depend on argument order there. Nested invariant conflicts keep the first
  binding and are reported by the argument-compatibility pass.
- Candidate scores use the arity, reference-adjustment, and exact-match components
  only; literal-default and generic-default counts do not participate yet.
- Method candidates are first scored on argument types read without checking (a
  name, a struct literal, a reference to either, a numeric literal's class). On a
  tie, the arguments the argument pass checks without an expected type (all but
  closures, ranges, array literals, bare generic functions and variants, interface
  associated calls) are checked then, once, and the candidates are scored again; a
  tie that remains is an ambiguity error, and an argument that failed its check
  suppresses it. The expected result type decides a remaining tie first (the one
  candidate whose result it is), also for a call without arguments.
- A generic item still declares at most 8 type parameters; there is no spill
  storage above eight generic arguments.
