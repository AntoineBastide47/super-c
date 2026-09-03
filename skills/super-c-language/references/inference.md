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
- Closure parameter and result types when the surrounding call or expected function
  type provides them.
- Array lengths and other const generic values from exact linear equalities.

Never inferred (the signature barrier):

- Function and method parameter and result types.
- Struct, enum, interface, extend, and global declaration types.
- Generic parameter lists and their bounds.

## Literal defaults

- An unsuffixed integer literal defaults to `i32`.
- An unsuffixed float literal defaults to `f32`.
- A suffix (`5u64`, `1.5f64`) pins the literal type; context cannot change it.
- A typed context adapts an unsuffixed literal before the default applies: typed
  operands win over defaults, and the default applies only after all other
  information is exhausted.
- A literal that does not fit its selected type is an error, whether the type came
  from a suffix, from context, or from the default.
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
   same-signedness integers, integer to float, `f32` to `f64`, float to complex).
4. Unsized coercions: array to slice, `&T` to `*const T`, pointer to `*void`,
   concrete to `dyn` erasure, `Box<T>` to `Box<dyn I>`.
5. Literal adaptation (an unsuffixed literal re-typed by context).
6. User conversions through `From`/`widen` (explicit conformances only).

Nested type positions require equality, not conversion, unless the declared variance
of the position says otherwise. A top-level safe conversion never makes a nested
generic argument convert.

## Branch joins

- With an expected type, each branch of `if`/`switch` coerces to it independently.
- Without one, all branch result types must be equal after `Never` absorption
  (a diverging branch adopts the other branch's type).
- There is no implicit least-upper-bound: `if c { 1i32; } else { 2i64; }` without an
  expected type is an error.
- `break value` joins under the same rule: all break values of one loop must agree
  or coerce to the loop's expected type.

## Generic argument inference

Evidence binds a generic parameter in this order, and all evidence must agree:

1. Explicit turbofish arguments.
2. The receiver's instance arguments (owner substitution).
3. Value argument types against declared parameter types, structurally.
4. The expected result type.
5. Declared interface bounds (arguments of a proven conformance).
6. Declared defaults, then literal defaults, only after everything above reaches a
   fixed point.

A repeated generic parameter must unify with every use: an existing binding that
disagrees with a later use is a conflict error, never silently kept. Acceptance
never depends on argument order. An unresolved parameter after defaults is a type
error at the call, not a downstream failure.

## Const generic inference

- A bare const parameter in a parameter position (`[T; N]`) binds from the
  argument's length exactly as a type parameter binds.
- A linear const expression with one unknown solves when exact integer division
  gives one value; division with a remainder, overflow, or a cycle is an error.
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
this lexicographic score, best first:

1. Fewer safe conversions (by the rank list above).
2. Fewer reference adjustments or dereferences.
3. Fewer literal defaults.
4. Fewer generic defaults.
5. More exact parameter matches.
6. A more specific receiver or interface relation, where the language defines one.

Two candidates with equal best scores are an ambiguity error. Source order and
declaration order never break a tie. An error type never satisfies a bound, never
makes a candidate viable, and never selects an overload.

## Limits

- A generic item declares at most 8 type parameters (a declaration error beyond).
- Candidate search, solver recursion, and constraint counts have fixed compiler
  budgets; exceeding one reports the limit and the source expression.

## Current engine deviations

The engine still deviates from the rules above in these known ways, each locked by a
regression case in `tests/infer_test.spc`:

- Top-level directional evidence joins order-independently under the modeled
  conversions (identity, integer widening, `f32` to `f64`, `&mut T` to `&T`). An
  unmodeled conversion still falls back to the first use's binding, so acceptance
  can depend on argument order there. Nested invariant conflicts keep the first
  binding and are reported by the argument-compatibility pass.
- Candidate scores use the arity, reference-adjustment, and exact-match components
  only; literal-default and generic-default counts do not participate yet, and a
  tie between candidates whose argument types are not all known falls back to the
  first candidate instead of an ambiguity error.
- A generic item still declares at most 8 type parameters; there is no spill
  storage above eight generic arguments.
- An unsuffixed literal argument types eagerly (its class default), so it joins as
  its default type instead of adapting before the join.
