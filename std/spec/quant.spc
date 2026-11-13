// Triggers of quantifiers, for proofs. The prover adds the instances of a `forall` the facts state, or
// of an `exists` a goal states, at the terms the formulas name: by default at each term of the shape of
// a term of the body that holds the binding. `trigger(e)` in a body gives the shapes instead: the
// instances at each term of the shape of `e`, any term in place of the binding.

/// `x`. In the body of a quantifier, `x` is one of its triggers.
pub const fn trigger<T>(x: T) T {
    return x;
}
