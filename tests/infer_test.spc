// Inference regression corpus: locks the CURRENT accept/reject behavior of the special-case
// inference paths before the constraint-engine rewrite. Cases marked "known gap" document behavior
// the rewrite is allowed to change (each names the replacing rule); every other case must keep its
// result through every phase of the rewrite.
import tests::harness as h;

@test
fn local_declarations() {
    h::expect_ok("annotated local", "fn main() i32 { let x: i32 = 1; return x - 1; }\n");
    h::expect_ok("inferred local", "fn main() i32 { let x = 1; let y: i32 = x; return y - 1; }\n");
    h::expect_ok(
        "inferred local from call",
        "fn f() i64 { return 7; }\nfn main() i32 { let x = f(); return (x - 7) as i32; }\n",
    );
    h::expect_ok("split init keeps annotation", "fn main() i32 { let x: u8; x = 250; return (x - 250) as i32; }\n");
    h::expect_err_msg(
        "annotation conflict",
        "fn main() i32 { let x: *const u8 = 1.5; return 0; }\n",
        "mismatched types",
    );
}

@test
fn literal_defaults() {
    // The current language rule: an unsuffixed integer literal defaults to i32, an unsuffixed
    // float literal to f32. Context adapts a literal only through `compatible` re-typing.
    h::expect_ok(
        "int default i32 float default f32",
        "fn main() i32 { let x = 5; static_assert(sizeof(x) == 4, \"i32\"); let f = 1.5; static_assert(sizeof(f) == 4, \"f32\"); return 0; }\n",
    );
    h::expect_ok(
        "literal adapts to annotated slot",
        "fn main() i32 { let x: u8 = 200; let y: i64 = 5; let f: f64 = 1.5; return (x as i64 + y - 205) as i32; }\n",
    );
    h::expect_ok("int literal initializes float slot", "fn main() i32 { let f: f64 = 3; return (f as i32) - 3; }\n");
    h::expect_err_msg("literal out of range", "fn main() i32 { let x: u8 = 300; return 0; }\n", "out of range");
    h::expect_ok(
        "wide literals through expected type",
        "fn main() i32 { let x: u128 = 340282366920938463463374607431768211455; let y: UInt<256> = 1; return 0; }\n",
    );
    h::expect_ok(
        "suffix pins the literal type",
        "fn main() i32 { let x = 5u64; static_assert(sizeof(x) == 8, \"u64\"); return 0; }\n",
    );
}

@test
fn repeated_generic_params() {
    h::expect_ok(
        "equal argument types bind once",
        "fn pick<T>(a: T, b: T) T { return a; }\nfn main() i32 { return pick(1, 2) - 1; }\n",
    );
    h::expect_err_msg(
        "conflicting argument types reported at the second use",
        "fn pick<T>(a: T, b: T) T { return a; }\nfn main() i32 { let x: i32 = 1; let y: f64 = 2.0; let z = pick(x, y); return 0; }\n",
        "mismatched types",
    );
    // Directional evidence joins under the safe-conversion oracle, so acceptance does not depend
    // on argument order. Both orders bind
    // T = &i32 and the `&mut` argument coerces.
    h::expect_exit(
        "shared ref first then mut ref coerces",
        "fn pick<T>(a: T, b: T) T { return a; }\nfn main() i32 { let mut x: i32 = 1; let y: i32 = 2; let r = pick(&y, &mut x); return *r; }\n",
        2,
    );
    h::expect_exit(
        "mut ref first joins to the shared ref",
        "fn pick<T>(a: T, b: T) T { return a; }\nfn main() i32 { let mut x: i32 = 1; let y: i32 = 2; let r = pick(&mut x, &y); return *r; }\n",
        1,
    );
    h::expect_exit(
        "typed generic operand sets an earlier literal type",
        "fn pick<T>(a: T, b: T) T { return a; }\nfn main() i32 { let y: u8 = 7; let x: u8 = pick(6, y); return (x - 6) as i32; }\n",
        0,
    );
}

@test
fn const_generic_inference() {
    h::expect_ok(
        "array length from argument",
        "fn len_of<const N: usize>(a: [i32; N]) usize { return N; }\nfn main() i32 { let a: [i32; 3] = [1, 2, 3]; return len_of(a) as i32 - 3; }\n",
    );
    h::expect_ok(
        "array literal argument counts its elements",
        "fn len_of<const N: usize>(a: [i32; N]) usize { return N; }\nfn main() i32 { return len_of([1, 2]) as i32 - 2; }\n",
    );
    // Bounded exact linear solving (plan section 10.5): a single-unknown undivided linear form
    // solves against an exact value; a remainder leaves the parameter unresolved with a clean
    // call-site error.
    h::expect_exit(
        "scaled const length solves by exact division",
        "fn half<const N: usize>(a: [i32; N * 2]) usize { return N; }\nfn main() i32 { let a: [i32; 4] = [1, 2, 3, 4]; return half(a) as i32 - 2; }\n",
        0,
    );
    h::expect_exit(
        "offset const length solves linearly",
        "fn off<const N: usize>(a: [i32; N + 1]) usize { return N; }\nfn main() i32 { let a: [i32; 4] = [1, 2, 3, 4]; return off(a) as i32 - 3; }\n",
        0,
    );
    h::expect_exit(
        "linear const form in a generic type argument solves",
        "fn wid<const N: usize>(v: &UInt<{N * 2}>) usize { return N; }\nfn main() i32 { let x: UInt<128> = 1; return wid(&x) as i32 - 64; }\n",
        0,
    );
    h::expect_err_msg(
        "division with a remainder is rejected",
        "fn half<const N: usize>(a: [i32; N * 2]) usize { return N; }\nfn main() i32 { let a: [i32; 5] = [1, 2, 3, 4, 5]; return half(a) as i32; }\n",
        "cannot infer the generic argument",
    );
    // Fixed by the phase-2 engine (plan section 10.5): a later use whose exact const value
    // disagrees with the existing binding is a conflict, not a silent first-binding win.
    h::expect_err_msg(
        "conflicting const lengths are a conflict",
        "fn same<const N: usize>(a: [i32; N], b: [i32; N]) usize { return N; }\nfn main() i32 { let a: [i32; 2] = [1, 2]; let b: [i32; 3] = [1, 2, 3]; return same(a, b) as i32; }\n",
        "conflicting const generic arguments",
    );
}

@test
fn bound_dependency_chains() {
    // The changed-slot worklist: a bound-dependency chain resolves to a fixed
    // point in any declaration order. The replaced two-pass repair resolved this chain only when
    // its parameters were declared in chain order.
    h::expect_exit(
        "reverse-order depth-3 bound chain resolves",
        "interface Conv<T> { fn to(self: &Self) T; }\nstruct A {}\nstruct B {}\nstruct C {}\nstruct D {}\nextend A as Conv<B> { pub fn to(self: &A) B { return B {}; } }\nextend B as Conv<C> { pub fn to(self: &B) C { return C {}; } }\nextend C as Conv<D> { pub fn to(self: &C) D { return D {}; } }\nextend D { pub fn ok(self: &D) i32 { return 3; } }\nfn chain<Z, Y: Conv<Z>, X: Conv<Y>, W: Conv<X>>(w: &W) Z { let x = w.to(); let y = x.to(); return y.to(); }\nfn main() i32 { let a = A {}; let d = chain(&a); return d.ok() - 3; }\n",
        0,
    );
    h::expect_exit(
        "in-order depth-3 bound chain still resolves",
        "interface Conv<T> { fn to(self: &Self) T; }\nstruct A {}\nstruct B {}\nstruct C {}\nstruct D {}\nextend A as Conv<B> { pub fn to(self: &A) B { return B {}; } }\nextend B as Conv<C> { pub fn to(self: &B) C { return C {}; } }\nextend C as Conv<D> { pub fn to(self: &C) D { return D {}; } }\nextend D { pub fn ok(self: &D) i32 { return 3; } }\nfn chain<W: Conv<X>, X: Conv<Y>, Y: Conv<Z>, Z>(w: &W) Z { let x = w.to(); let y = x.to(); return y.to(); }\nfn main() i32 { let a = A {}; let d = chain(&a); return d.ok() - 3; }\n",
        0,
    );
}

@test
fn expected_result_flow() {
    h::expect_ok(
        "branches coerce to the expected type independently",
        "fn main() i32 { let c = true; let x: i64 = if c { 1i32; } else { 2i64; }; return x as i32 - 1; }\n",
    );
    h::expect_err_msg(
        "branch mismatch without an expected type",
        "fn main() i32 { let c = true; let x = if c { 1i32; } else { 2i64; }; return 0; }\n",
        "mismatched types",
    );
    h::expect_ok(
        "interface assoc call takes the destination type",
        "fn main() i32 { let v: Vector<i32> = Default::default(); return v.len() as i32; }\n",
    );
    // Phase-4 expected-result inference (plan section 11 step 5): a parameter the arguments left
    // unresolved binds from the destination type, before declared and literal defaults.
    h::expect_exit(
        "generic result inferred from destination",
        "fn make<T: Default>() T { return T::default(); }\nfn main() i32 { let x: i32 = make(); return x; }\n",
        0,
    );
    h::expect_exit(
        "constructor generics inferred from destination",
        "fn main() i32 { let v: Vector<i32> = Vector::new(); return v.len() as i32; }\n",
        0,
    );
    h::expect_exit(
        "inferred constructor instance is usable",
        "fn main() i32 { let mut v: Vector<i64> = Vector::new(); v.push(7); return (*v.at(0) - 7) as i32; }\n",
        0,
    );
    h::expect_err_msg(
        "constructor with no context still needs the turbofish",
        "fn main() i32 { let v = Vector::new(); return v.len() as i32; }\n",
        "cannot infer the generic argument",
    );
    h::expect_err_msg(
        "fully unresolved generic call is a call-site error",
        "fn nothing<T: Default>() T { return T::default(); }\nfn main() i32 { let x = nothing(); return 0; }\n",
        "cannot infer the generic argument",
    );
    // Argument, expected-result, and bound evidence together infer one call's parameters
    // at once.
    h::expect_exit(
        "argument and destination evidence combine in one call",
        "struct Pair<A, B> { pub a: A, pub b: B }\nfn wrap<A, B: Default>(a: A) Pair<A, B> { return Pair::<A, B> { a: a, b: B::default() }; }\nfn main() i32 { let p: Pair<i32, i64> = wrap(1); return (p.a as i64 + p.b) as i32 - 1; }\n",
        0,
    );
}

@test
fn closure_inference() {
    h::expect_ok(
        "closure parameters from an expected fn type",
        "fn main() i32 { let f: fn(i32) i32 = |x| x + 1; return f(1) - 2; }\n",
    );
    h::expect_err_msg(
        "standalone closure needs annotations",
        "fn main() i32 { let f = |x| x + 1; return f(1) - 2; }\n",
        "closure parameter needs a type annotation",
    );
    h::expect_ok(
        "annotated closure through a generic call",
        "fn ap<T>(f: fn(T) T, x: T) T { return f(x); }\nfn main() i32 { return ap(|v: i32| v * 2, 10) - 20; }\n",
    );
    // Phase-5 postponed closure (plan section 12): an unannotated closure argument of a generic
    // call is checked once, after the other arguments bind the call's parameters.
    h::expect_exit(
        "unannotated closure parameters from a generic call",
        "fn ap<T>(f: fn(T) T, x: T) T { return f(x); }\nfn main() i32 { return ap(|v| v * 2, 10) - 20; }\n",
        0,
    );
    h::expect_exit(
        "postponed closure result binds a call parameter",
        "fn map1<T, U>(f: fn(T) U, x: T) U { return f(x); }\nfn main() i32 { let r = map1(|v| (v * 2) as i64, 10); return (r - 20) as i32; }\n",
        0,
    );
    h::expect_err_msg(
        "a closure bound to a plain local still needs annotations",
        "fn ap<T>(f: fn(T) T, x: T) T { return f(x); }\nfn main() i32 { let f2 = |v| v * 2; return ap(f2, 10) - 20; }\n",
        "closure parameter needs a type annotation",
    );
}

@test
fn generic_argument_limits() {
    h::expect_err_msg(
        "nine type parameters rejected at the declaration",
        "fn many<A, B, C, D, E, F, G, H, I>(a: A) A { return a; }\nfn main() i32 { return 0; }\n",
        "at most 8 type parameters",
    );
    h::expect_ok(
        "eight type parameters accepted",
        "fn many<A, B, C, D, E, F, G, H>(a: A, b: B, c: C, d: D, e: E, f: F, g: G, h2: H) A { return a; }\nfn main() i32 { return many(9, 2u8, 3i64, 4u32, 5i16, true, 'c', 8usize) - 9; }\n",
    );
}

@test
fn candidate_selection() {
    // Phase-6 bounded candidate solving (plan section 13): a fully informed tie between distinct
    // candidates is an ambiguity error; a unique fit wins in any declaration order; an adversarial
    // overload set stops at the documented candidate limit.
    h::expect_err_msg(
        "equal best candidates are an ambiguity error",
        "interface A { fn m(self: &Self, x: i32) i32; }\ninterface B { fn m(self: &Self, x: i32) i32; }\nstruct V {}\nextend V as A { pub fn m(self: &V, x: i32) i32 { return x + 1; } }\nextend V as B { pub fn m(self: &V, x: i32) i32 { return x + 2; } }\nfn main() i32 { let v = V {}; let k: i32 = 5; return v.m(k); }\n",
        "ambiguous call",
    );
    h::expect_exit(
        "unique fit wins in declaration order",
        "interface A { fn m(self: &Self, x: i32) i32; }\ninterface B { fn m(self: &Self, x: str) i32; }\nstruct V {}\nextend V as A { pub fn m(self: &V, x: i32) i32 { return 1; } }\nextend V as B { pub fn m(self: &V, x: str) i32 { return 2; } }\nfn main() i32 { let v = V {}; let s: str = \"hi\"; return v.m(s) - 2; }\n",
        0,
    );
    h::expect_exit(
        "unique fit wins in reversed declaration order",
        "interface A { fn m(self: &Self, x: i32) i32; }\ninterface B { fn m(self: &Self, x: str) i32; }\nstruct V {}\nextend V as B { pub fn m(self: &V, x: str) i32 { return 2; } }\nextend V as A { pub fn m(self: &V, x: i32) i32 { return 1; } }\nfn main() i32 { let v = V {}; let s: str = \"hi\"; return v.m(s) - 2; }\n",
        0,
    );
    // Full lexicographic score: a literal argument scores by its adaptability class,
    // so an inseparable tie errors even though the literal's exact type is not yet known, and the
    // literal's default type is the preferred exact match.
    h::expect_err_msg(
        "identical candidates tie on a literal argument",
        "interface A { fn m(self: &Self, x: i32) i32; }\ninterface B { fn m(self: &Self, x: i32) i32; }\nstruct V {}\nextend V as A { pub fn m(self: &V, x: i32) i32 { return x + 1; } }\nextend V as B { pub fn m(self: &V, x: i32) i32 { return x + 2; } }\nfn main() i32 { let v = V {}; return v.m(5); }\n",
        "ambiguous call",
    );
    h::expect_exit(
        "a literal argument prefers its default type",
        "interface A { fn m(self: &Self, x: i32) i32; }\ninterface B { fn m(self: &Self, x: i64) i32; }\nstruct V {}\nextend V as A { pub fn m(self: &V, x: i32) i32 { return 1; } }\nextend V as B { pub fn m(self: &V, x: i64) i32 { return 2; } }\nfn main() i32 { let v = V {}; return v.m(5) - 1; }\n",
        0,
    );
    h::expect_err_msg(
        "candidate budget stops adversarial overload sets",
        "struct V {}\ninterface C0 { fn m(self: &Self, x: i32) i32; }\ninterface C1 { fn m(self: &Self, x: i64) i32; }\ninterface C2 { fn m(self: &Self, x: u8) i32; }\ninterface C3 { fn m(self: &Self, x: u16) i32; }\ninterface C4 { fn m(self: &Self, x: u32) i32; }\ninterface C5 { fn m(self: &Self, x: u64) i32; }\ninterface C6 { fn m(self: &Self, x: i8) i32; }\ninterface C7 { fn m(self: &Self, x: i16) i32; }\nextend V as C0 { pub fn m(self: &V, x: i32) i32 { return 0; } }\nextend V as C1 { pub fn m(self: &V, x: i64) i32 { return 1; } }\nextend V as C2 { pub fn m(self: &V, x: u8) i32 { return 2; } }\nextend V as C3 { pub fn m(self: &V, x: u16) i32 { return 3; } }\nextend V as C4 { pub fn m(self: &V, x: u32) i32 { return 4; } }\nextend V as C5 { pub fn m(self: &V, x: u64) i32 { return 5; } }\nextend V as C6 { pub fn m(self: &V, x: i8) i32 { return 6; } }\nextend V as C7 { pub fn m(self: &V, x: i16) i32 { return 7; } }\nfn main() i32 { let v = V {}; let k: u16 = 3; return v.m(k) - 3; }\n",
        "candidate limit",
    );
}

@test
fn overload_and_receiver() {
    h::expect_ok(
        "owner generics inferred from constructor arguments",
        "fn main() i32 { let b = Box::new(41); return *b.get() - 41; }\n",
    );
    h::expect_ok(
        "receiver instance substitutes method generics",
        "fn main() i32 { let mut v = Vector::<i64>::new(); v.push(9); return (*v.at(0) - 9) as i32; }\n",
    );
    h::expect_ok(
        "turbofish binds explicitly",
        "fn id<T>(x: T) T { return x; }\nfn main() i32 { return id::<i32>(3) - 3; }\n",
    );
    h::expect_err_msg(
        "turbofish conflict with argument",
        "fn id<T>(x: T) T { return x; }\nfn main() i32 { let s: str = \"hi\"; return id::<i32>(s); }\n",
        "mismatched types",
    );
}
