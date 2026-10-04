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
    h::expect_err_msg(
        "an int literal never initializes a float slot",
        "fn main() i32 { let f: f64 = 3; return (f as i32) - 3; }\n",
        "mismatched types: expected 'f64', found 'i32'",
    );
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

// Literal-only arithmetic takes the expected type into every operand, and without one widens to the best
// builtin type; values no type holds are errors at the expression.
@test
fn literal_arithmetic_types() {
    h::expect_ok(
        "expected type flows into literal arithmetic",
        "fn main() i32 { let a: u8 = 2 + 3; let b: usize = 1 + 2; let c: i64 = -(2000000000 * 2); static_assert(sizeof(a) == 1, \"u8\"); return (b as i32) - 3; }\n",
    );
    h::expect_ok(
        "undeclared literal arithmetic widens",
        "fn main() i32 { let a = 2000000000 * 2; let b = 1 << 40; let f = 1e30 * 1e10; static_assert(sizeof(a) == 8 && sizeof(b) == 8 && sizeof(f) == 8, \"64\"); return 0; }\n",
    );
    h::expect_ok(
        "a float literal past f32 is an f64",
        "fn main() i32 { let f = 1e39; static_assert(sizeof(f) == 8, \"f64\"); return 0; }\n",
    );
    h::expect_err_msg(
        "typed literal out of range",
        "fn main() i32 { let x: i32 = 0x80000000; return x; }\n",
        "integer literal is out of range for 'i32'",
    );
    h::expect_err_msg(
        "declared type reaches every operand",
        "fn main() i32 { let x: u8 = 300 - 100; return 0; }\n",
        "integer literal is out of range for 'u8'",
    );
    h::expect_err_msg(
        "past u64",
        "fn main() i32 { let x = 18446744073709551615 + 1; return 0; }\n",
        "integer constant expression does not fit in 'i32', 'i64' or 'u64'",
    );
    h::expect_err_msg(
        "negative past i64",
        "fn main() i32 { let x = -18446744073709551615; return 0; }\n",
        "integer constant expression does not fit in 'i32', 'i64' or 'u64'",
    );
    h::expect_err_msg(
        "declared f32 literal out of range",
        "fn main() i32 { let x: f32 = 1e39; return 0; }\n",
        "float literal is out of range for 'f32'",
    );
    h::expect_err_msg(
        "declared f32 expression out of range",
        "fn main() i32 { let x: f32 = 1e30 * 1e10; return 0; }\n",
        "float constant expression is out of range for 'f32'",
    );
    h::expect_err_msg(
        "suffixed float out of range",
        "fn main() i32 { let x = 1e39f32; return 0; }\n",
        "float literal does not fit in its suffixed type",
    );
    h::expect_err_msg(
        "float literal past f64",
        "fn main() i32 { let x = 1e400; return 0; }\n",
        "float literal is out of range for 'f64'",
    );
    h::expect_err_msg(
        "a float literal does not take an integer type",
        "fn main() i32 { let y: i32 = 3; let x = y + 2.5; return 0; }\n",
        "mismatched types: expected 'i32', found 'f32'",
    );
}

// Literal-only arithmetic takes the type of every context form; a negated literal reaches its type's
// minimum, suffixed or not, and the C form of the i64 minimum is a valid C expression.
@test
fn literal_contexts_and_signed_minimum() {
    h::expect_exit(
        "every context types literal arithmetic",
        "struct P { pub a: i64, pub b: u64 }\nfn take(x: i64) i64 { return x; }\nfn ret() i64 { return 2147483647 + 1; }\nfn main() i32 {\n    let a: i64 = 2147483647 + 1;\n    let p = P { a: 2147483647 + 1, b: 1 << 40 };\n    let x: i64 = 5;\n    let mut f: i64 = 0;\n    f += 2147483647 + 1;\n    let g: [u64; 2] = [1 << 40, 1 << 33];\n    if a != 2147483648 || take(2147483647 + 1) != a || ret() != a || p.a != a || p.b != 1099511627776 { return 1; }\n    if x + (2147483647 + 1) != a + 5 || (2147483647 + 1) + x != a + 5 || f != a || g[1] != 8589934592 { return 2; }\n    return 0;\n}\n",
        0,
    );
    h::expect_exit(
        "a u64 constant shifts past 32 bits",
        "const S: u64 = 1 << 40;\nfn main() i32 { return (S >> 40) as i32 - 1; }\n",
        0,
    );
    h::expect_exit(
        "negated literals reach the signed minimum",
        "fn main() i32 {\n    let a = -128i8;\n    let b = -32768i16;\n    let c = -2147483648i32;\n    let d = -9223372036854775808i64;\n    let e = -2147483648;\n    let f = -9223372036854775808;\n    static_assert(sizeof(e) == 4 && sizeof(f) == 8, \"i32, i64\");\n    let g: i8 = -128;\n    if a != i8::MIN || g != a || b != i16::MIN || c != i32::MIN || e != c || d != i64::MIN || f != d { return 1; }\n    return 0;\n}\n",
        0,
    );
    h::expect_c(
        "the i64 minimum is a valid C expression",
        "fn main() i32 { let d = -9223372036854775808i64; return (d + 9223372036854775807 + 1) as i32; }\n",
        "(-9223372036854775807LL - 1)",
    );
    h::expect_err_msg(
        "past the minimum",
        "fn main() i32 { let a = -129i8; return 0; }\n",
        "integer literal does not fit in its suffixed type",
    );
    h::expect_err_msg(
        "a float operand in an integer context",
        "fn main() i32 { let a: i32 = 2.5 + 1; return a; }\n",
        "mismatched types",
    );
    h::expect_ok(
        "an array of tuples holding a function pointer",
        "fn p(x: []u8) usize { return x.len(); }\nfn main() i32 { let u: [(i32, fn([]u8) usize); 1] = [(1, p)]; return u[0].0 - 1; }\n",
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
fn literal_adopts_generic_sibling() {
    // An unpinned literal argument (decimal, based, or negated) takes the type the other arguments
    // or the expected result give the parameter; only a suffix pins it.
    h::expect_exit(
        "hex literal adopts a typed sibling",
        "fn pick<T>(c: bool, a: T, b: T) T { if c { return a; } return b; }\nfn main() i32 { let x: i32 = 5; let v: u32 = pick(x < 3, x as u32, 0xFFFFFFFF); return (v - 0xFFFFFFFE) as i32; }\n",
        1,
    );
    h::expect_exit(
        "literals adopt the expected result",
        "fn pick<T>(c: bool, a: T, b: T) T { if c { return a; } return b; }\nfn main() i32 { let b: u8 = pick(true, 1, 0); static_assert(sizeof(b) == 1, \"u8\"); return b as i32; }\n",
        1,
    );
    h::expect_exit(
        "negated literal adopts a typed sibling",
        "fn pick<T>(c: bool, a: T, b: T) T { if c { return a; } return b; }\nfn main() i32 { let x: i64 = 5; let n = pick(false, x, -1); static_assert(sizeof(n) == 8, \"i64\"); return (n + 2) as i32; }\n",
        1,
    );
    h::expect_err_msg(
        "adopted literal is range-checked",
        "fn pick<T>(c: bool, a: T, b: T) T { if c { return a; } return b; }\nfn main() i32 { let x: i32 = 5; let a = pick(true, x as u8, 300); return a as i32; }\n",
        "out of range for 'u8'",
    );
}

@test
fn array_literal_adopts_slice_element() {
    h::expect_exit(
        "array literal fills a usize slice",
        "fn sum(s: []usize) usize { let mut t: usize = 0; for x in s { t += x; } return t; }\nfn main() i32 { let s: []usize = [1, 2]; let r: []usize = [4; 2]; return (sum(s) + sum([3, 4]) + sum(r) + sum([1; 3])) as i32 - 21; }\n",
        0,
    );
    h::expect_exit(
        "array literal argument widens to an array parameter",
        "fn s2(a: [i64; 2]) i64 { return a[0] + a[1]; }\nfn main() i32 { return s2([3, 4]) as i32 - 7; }\n",
        0,
    );
    h::expect_err_msg(
        "slice element range-checks literals",
        "fn main() i32 { let s: []u8 = [1, 256]; return s.len() as i32; }\n",
        "mismatched types",
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
    h::expect_exit(
        "generic call inside a postponed closure body keeps the outer session",
        "fn apply<T, U>(x: T, f: fn(T) U) U { return f(x); }\nfn id<A>(a: A) A { return a; }\nfn main() i32 { let r = apply(5, |v| id(v) + 1); return r - 6; }\n",
        0,
    );
    h::expect_exit(
        "five-parameter closure through a generic fn type",
        "fn ap5<T: Copy>(f: fn(T, T, T, T, T) T, x: T) T { return f(x, x, x, x, x); }\nfn main() i32 { return ap5(|a, b, c, d, e| a + b + c + d + e, 2) - 10; }\n",
        0,
    );
    h::expect_exit(
        "generic fn item coerces to a five-parameter fn type",
        "fn s5<T>(a: T, b: T, c: T, d: T, e: T) T { return e; }\nfn main() i32 { let f: fn(i32, i32, i32, i32, i32) i32 = s5; return f(1, 2, 3, 4, 5) - 5; }\n",
        0,
    );
    h::expect_exit(
        "nine-parameter closure from an expected fn type",
        "fn main() i32 { let f: fn(i32, i32, i32, i32, i32, i32, i32, i32, i32) i32 = |a, b, c, d, e, g, k, m, n| a + n; return f(1, 0, 0, 0, 0, 0, 0, 0, 2) - 3; }\n",
        0,
    );
    h::expect_err_msg(
        "a closure bound to a plain local still needs annotations",
        "fn ap<T>(f: fn(T) T, x: T) T { return f(x); }\nfn main() i32 { let f2 = |v| v * 2; return ap(f2, 10) - 20; }\n",
        "closure parameter needs a type annotation",
    );
    // A closure passed for a generic parameter takes its parameter types from that parameter's fn
    // bound, once an earlier argument solves the bound's own parameters: here `T` comes from the
    // iterator argument's `Iterator<T>` conformance.
    h::expect_exit(
        "closure parameters from a generic fn bound solved by a conformance",
        "import std::iter as iter;\nstruct Down { pub n: i32 }\nextend Down as Iterator<i32> {\n    pub fn next(self: &mut Down) Option<i32> {\n        if self.n == 0 { return Option::<i32>::None; }\n        self.n = self.n - 1;\n        return Option::<i32>::Some(self.n);\n    }\n}\nfn main() i32 { let mut s: i32 = 0; iter::for_each(Down { n: 3 }, |x| { s = s + x; }); return s - 3; }\n",
        0,
    );
    h::expect_exit(
        "closure parameters from generic fn bounds across an adapter pipeline",
        "import std::iter as iter;\nfn main() i32 {\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    v.push(2);\n    let s = iter::fold(iter::map(v.iter(), |x| *x * 2), 0, |a, x| a + x);\n    let c = iter::count(iter::filter(v.iter(), |x| **x > 1));\n    return s + c as i32 - 7;\n}\n",
        0,
    );
    h::expect_exit(
        "closure parameters from a direct generic fn bound",
        "fn apply<F: fn(i32) i32>(f: F) i32 { return f(4); }\nfn main() i32 { return apply(|y| y + 1) - 5; }\n",
        0,
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
    h::expect_exit(
        "exactly the candidate limit is still weighed",
        "struct V {}\ninterface C0 { fn m(self: &Self, x: i32) i32; }\ninterface C1 { fn m(self: &Self, x: i64) i32; }\ninterface C2 { fn m(self: &Self, x: u8) i32; }\ninterface C3 { fn m(self: &Self, x: u16) i32; }\ninterface C4 { fn m(self: &Self, x: u32) i32; }\ninterface C5 { fn m(self: &Self, x: u64) i32; }\ninterface C6 { fn m(self: &Self, x: i8) i32; }\ninterface C7 { fn m(self: &Self, x: i16) i32; }\nextend V as C0 { pub fn m(self: &V, x: i32) i32 { return 0; } }\nextend V as C1 { pub fn m(self: &V, x: i64) i32 { return 1; } }\nextend V as C2 { pub fn m(self: &V, x: u8) i32 { return 2; } }\nextend V as C3 { pub fn m(self: &V, x: u16) i32 { return 3; } }\nextend V as C4 { pub fn m(self: &V, x: u32) i32 { return 4; } }\nextend V as C5 { pub fn m(self: &V, x: u64) i32 { return 5; } }\nextend V as C6 { pub fn m(self: &V, x: i8) i32 { return 6; } }\nextend V as C7 { pub fn m(self: &V, x: i16) i32 { return 7; } }\nfn main() i32 { let v = V {}; let k: u16 = 3; return v.m(k) - 3; }\n",
        0,
    );
    h::expect_err_msg(
        "candidate budget stops adversarial overload sets",
        "struct V {}\ninterface C0 { fn m(self: &Self, x: i32) i32; }\ninterface C1 { fn m(self: &Self, x: i64) i32; }\ninterface C2 { fn m(self: &Self, x: u8) i32; }\ninterface C3 { fn m(self: &Self, x: u16) i32; }\ninterface C4 { fn m(self: &Self, x: u32) i32; }\ninterface C5 { fn m(self: &Self, x: u64) i32; }\ninterface C6 { fn m(self: &Self, x: i8) i32; }\ninterface C7 { fn m(self: &Self, x: i16) i32; }\nextend V as C0 { pub fn m(self: &V, x: i32) i32 { return 0; } }\nextend V as C1 { pub fn m(self: &V, x: i64) i32 { return 1; } }\nextend V as C2 { pub fn m(self: &V, x: u8) i32 { return 2; } }\nextend V as C3 { pub fn m(self: &V, x: u16) i32 { return 3; } }\nextend V as C4 { pub fn m(self: &V, x: u32) i32 { return 4; } }\nextend V as C5 { pub fn m(self: &V, x: u64) i32 { return 5; } }\nextend V as C6 { pub fn m(self: &V, x: i8) i32 { return 6; } }\nextend V as C7 { pub fn m(self: &V, x: i16) i32 { return 7; } }\ninterface C8 { fn m(self: &Self, x: bool) i32; }\nextend V as C8 { pub fn m(self: &V, x: bool) i32 { return 8; } }\nfn main() i32 { let v = V {}; let k: u16 = 3; return v.m(k) - 3; }\n",
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
    h::expect_exit(
        "a bound interface's five generic arguments all substitute",
        "interface I<A, B, C, D, E> { fn get(self: &Self, a: A, b: B, c: C, d: D) E; }\nstruct S {}\nextend S as I<i32, i32, i32, i32, i64> { pub fn get(self: &S, a: i32, b: i32, c: i32, d: i32) i64 { let r: i64 = a + b + c + d; return r; } }\nfn f<T: I<i32, i32, i32, i32, i64>>(t: &T) i64 { return t.get(1, 2, 3, 4); }\nfn main() i32 { let s = S {}; return (f(&s) - 10) as i32; }\n",
        0,
    );
    h::expect_err_msg(
        "turbofish conflict with argument",
        "fn id<T>(x: T) T { return x; }\nfn main() i32 { let s: str = \"hi\"; return id::<i32>(s); }\n",
        "mismatched types",
    );
}

// A generic enum's variant written without type arguments takes its instance from the expected
// type (a declared result, an annotation, a parameter, a comparison's other operand), else from
// its payload arguments. Variant constructors are qualified in value position: a bare `Some` is
// only a pattern.
@test
fn generic_variant_constructors() {
    h::expect_exit(
        "expected result instance",
        "struct J { pub v: i32 }\nfn pick(x: &J, k: i32) Option<&J> { if k > 0 { return Option::Some(x); } return Option::None; }\nfn main() i32 { let j = J { v: 7 }; if pick(&j, 0).is_some() { return 1; } return pick(&j, 1).unwrap().v; }\n",
        7,
    );
    h::expect_exit(
        "annotation adapts a literal payload",
        "fn main() i32 { let o: Option<u8> = Option::Some(200); return (o.unwrap() - 197) as i32; }\n",
        3,
    );
    h::expect_exit(
        "parameter and comparison operand",
        "fn g(o: Option<i32>) i32 { return o.unwrap_or(1); }\nfn main() i32 { let a: Option<i32> = Option::Some(2); if a == Option::None || a != Option::Some(2) { return 9; } return g(Option::None) + g(Option::Some(3)); }\n",
        4,
    );
    h::expect_exit(
        "payload arguments bind the parameters",
        "enum Opt<T> { Val(T), Nil }\nfn main() i32 { let j = 5; let o = Opt::Val(&j); return switch o { Val(r) => *r, Nil => 0, }; }\n",
        5,
    );
    h::expect_exit(
        "a literal payload is not evidence",
        "enum Two<T> { Both(T, T), Nil }\nfn main() i32 { let o = Two::Both(3, 4u8); static_assert(sizeof(o) <= 4, \"u8 payload\"); return switch o { Both(a, b) => (a + b) as i32, Nil => 0, }; }\n",
        7,
    );
    h::expect_err_msg(
        "an unbound parameter is reported at the constructor",
        "fn main() i32 { let o = Result::Ok(3); return 0; }\n",
        "cannot infer the generic argument 'E'",
    );
    h::expect_err_msg(
        "a unit variant without an expected instance names no type",
        "fn main() i32 { let o = Option::None; return 0; }\n",
        "cannot infer the generic argument 'T' of this variant",
    );
    h::expect_resolve_err_msg(
        "a bare variant is not a value",
        "fn main() i32 { let o = Some(3); return 0; }\n",
        "cannot find value 'Some'",
    );
}

// A struct-payload variant of a generic enum takes its instance like a tuple variant: explicit
// arguments after the enum name, else an expected instance (annotation, parameter, result, array
// element), else the field values, then the defaults. Arguments after the variant are rejected.
@test
fn generic_struct_variant_literals() {
    h::expect_exit(
        "every source of the instance",
        "enum Sh<T> { Pt { x: T, y: T }, No }\nenum D<T = u8> { P { x: T }, E }\nextend<T: Copy> Sh<T> {\n    fn mk(a: T) Self { return Sh::Pt { x: a, y: a }; }\n}\nfn sum(s: Sh<i64>) i64 { return switch s { Pt { x, y } => x + y, No => 0 }; }\nfn back() Sh<u16> { return Sh::Pt { x: 300, y: 1 }; }\nfn main() i32 {\n    let a: Sh<i16> = Sh::Pt { x: 2, y: 5 };\n    let b = Sh::Pt { x: 2u8, y: 5 };\n    static_assert(sizeof(b) == 3, \"u8 payload\");\n    let c = Sh::<i16>::Pt { x: 1, y: 2 };\n    let d = D::P { x: 300u16 };\n    let e = D::P { x: 3 };\n    static_assert(sizeof(e) == 2, \"u8 default\");\n    let f = Sh::mk(4i8);\n    let g: [Sh<u32>; 2] = [Sh::Pt { x: 1, y: 2 }, Sh::No];\n    let mut t: i32 = switch a { Pt { x, y } => x + y, No => 0 };\n    t += switch b { Pt { x, y } => x + y, No => 0 };\n    t += switch c { Pt { x, y } => x + y, No => 0 };\n    t += switch d { P { x } => x, E => 0 };\n    t += switch e { P { x } => x, E => 0 };\n    t += switch f { Pt { x, y } => x + y, No => 0 };\n    t += sum(Sh::Pt { x: 1, y: 2 }) as i32;\n    t += switch back() { Pt { x, y } => x + y, No => 0 };\n    t += switch g[0] { Pt { x, y } => (x + y) as i32, No => 0 };\n    return t - 635;\n}\n",
        0,
    );
    h::expect_err_msg(
        "type arguments after a struct-payload variant",
        "enum Q<T> { V { a: T }, W(T) }\nfn main() i32 { let q = Q::V::<i16> { a: 2 }; return 0; }\n",
        "type arguments of a generic enum follow the enum name: write 'Q::<..>::V'",
    );
    h::expect_err_msg(
        "type arguments after a tuple variant",
        "enum Q<T> { V { a: T }, W(T) }\nfn main() i32 { let q = Q::W::<i16>(3); return 0; }\n",
        "type arguments of a generic enum follow the enum name: write 'Q::<..>::W'",
    );
    h::expect_err_msg(
        "type arguments on both segments",
        "enum Q<T> { V { a: T }, W(T) }\nfn main() i32 { let q = Q::<i16>::V::<u8> { a: 2 }; return 0; }\n",
        "a path takes type arguments only once",
    );
    h::expect_err_msg(
        "a parameter no field gives",
        "enum E<T> { P { n: i32 }, Q(T) }\nfn main() i32 { let e = E::P { n: 1 }; return 0; }\n",
        "cannot infer the generic argument 'T' of this struct literal; give it an expected type or explicit type arguments",
    );
    h::expect_err_msg(
        "conflicting field values",
        "enum Sh<T> { Pt { x: T, y: T }, No }\nfn main() i32 { let s = Sh::Pt { x: 1u8, y: true }; return 0; }\n",
        "generic parameter was constrained to both 'u8' and 'bool'",
    );
    h::expect_err_msg(
        "an unknown field",
        "enum Sh<T> { Pt { x: T, y: T }, No }\nfn main() i32 { let s = Sh::Pt { x: 1, z: 2 }; return 0; }\n",
        "no field 'z' on 'Sh'",
    );
}

// A generic struct named without type arguments takes its instance like a generic call: an
// expected instance of the same struct, else the field values, then declared defaults, then
// literal defaults.
@test
fn generic_struct_literals() {
    h::expect_exit(
        "annotation, return type and parameter",
        "struct Pair<A, B> { pub a: A, pub b: B }\nfn mk() Pair<u8, bool> { return Pair { a: 200, b: true }; }\nfn take(p: Pair<u16, i64>) i64 { return p.a as i64 + p.b; }\nfn main() i32 {\n    let q: Pair<i32, i32> = Pair { a: 1, b: 2 };\n    let m = mk();\n    if !m.b { return 1; }\n    return q.a + q.b + (m.a - 190) as i32 + (take(Pair { a: 60000, b: -59990 }) as i32);\n}\n",
        23,
    );
    h::expect_exit(
        "nested literal and reference parameter",
        "struct Pair<A, B> { pub a: A, pub b: B }\nfn sum(p: &Pair<u16, u16>) u16 { return p.a + p.b; }\nfn main() i32 {\n    let n: Pair<Pair<u8, u8>, i64> = Pair { a: Pair { a: 250, b: 4 }, b: 5 };\n    return (n.a.a - 240) as i32 + n.a.b as i32 + n.b as i32 + (sum(&Pair { a: 30000, b: 30000 }) - 59999) as i32;\n}\n",
        20,
    );
    h::expect_exit(
        "field values alone",
        "struct Pair<A, B> { pub a: A, pub b: B }\nstruct S<T> { pub a: T, pub b: T }\nfn main() i32 {\n    let p = Pair { a: 1u8, b: true };\n    static_assert(sizeof(p) == 2, \"u8, bool\");\n    let l = Pair { a: 7, b: 2.5 };\n    static_assert(sizeof(l) == 8, \"i32, f32\");\n    let r = Pair { a: S { a: 2, b: 1u16 }, b: l };\n    let ra = r.a;\n    static_assert(sizeof(ra) == 4, \"the literal adopts u16\");\n    if !p.b { return 1; }\n    return p.a as i32 + ra.a as i32 + r.b.a;\n}\n",
        10,
    );
    h::expect_exit(
        "generic alias as the expected type",
        "struct Pair<A, B> { pub a: A, pub b: B }\ntype Q1<T> = Pair<T, T>;\ntype Q2<T> = Q1<Q1<T>>;\nfn main() i32 {\n    let z: Q2<u8> = Pair { a: Pair { a: 1, b: 2 }, b: Pair { a: 3, b: 250 } };\n    return (z.a.a + z.a.b + z.b.a) as i32 + (z.b.b - 250) as i32;\n}\n",
        6,
    );
    h::expect_exit(
        "new with an expected pointer",
        "extern \"C\" { fn free(p: *mut void) void; }\nstruct Pair<A, B> { pub a: A, pub b: B }\nfn main() i32 {\n    let h: *mut Pair<u64, u8> = new Pair { a: 9, b: 10 };\n    let v = unsafe (*h).a as i32 + unsafe (*h).b as i32;\n    unsafe free(h);\n    return v;\n}\n",
        19,
    );
    h::expect_exit(
        "declared default before the literal default",
        "struct D<T = i64> { pub v: T }\nfn main() i32 {\n    let d = D { v: 3 };\n    static_assert(sizeof(d) == 8, \"i64\");\n    let e = D { v: 4u8 };\n    static_assert(sizeof(e) == 1, \"u8\");\n    return d.v as i32 + e.v as i32;\n}\n",
        7,
    );
    h::expect_exit(
        "const argument from an array field",
        "struct Buf<T, const N: usize> { pub d: [T; N] }\nfn main() i32 {\n    let b = Buf { d: [1u8, 2, 3] };\n    static_assert(sizeof(b) == 3, \"N = 3\");\n    return b.d[2] as i32;\n}\n",
        3,
    );
    h::expect_err_msg(
        "an unresolvable parameter is reported at the literal",
        "struct W<T> { pub n: i32 }\nfn main() i32 { let w = W { n: 1 }; return w.n; }\n",
        "cannot infer the generic argument 'T' of this struct literal; give it an expected type or explicit type arguments",
    );
    h::expect_err_msg(
        "a field value conflicts with the expected instance",
        "struct Pair<A, B> { pub a: A, pub b: B }\nfn main() i32 { let q: Pair<i32, bool> = Pair { a: 1, b: 2 }; return q.a; }\n",
        "mismatched types: expected 'bool', found 'i32'",
    );
    h::expect_err_msg(
        "conflicting field values",
        "struct S<T> { pub a: T, pub b: T }\nfn main() i32 { let x: i32 = 1; let y: bool = true; let s = S { a: x, b: y }; return 0; }\n",
        "mismatched types: generic parameter was constrained to both 'i32' and 'bool'",
    );
    h::expect_err_msg(
        "an unknown field is still reported",
        "struct Pair<A, B> { pub a: A, pub b: B }\nfn main() i32 { let p = Pair { a: 1, c: 2 }; return 0; }\n",
        "no field 'c' on 'Pair'",
    );
}

// An unsuffixed literal under `&` or `&mut` adopts the expected pointee type, and is not evidence
// for the generic parameter its reference reaches.
@test
fn literals_under_references() {
    h::expect_exit(
        "reference to a literal adopts the pointee",
        "fn g(x: &u64) u64 { return *x; }\nfn neg(x: &i64) i64 { return *x; }\nfn main() i32 {\n    let r: &u64 = &5000000000;\n    let rr: &&u8 = &&250;\n    let m: &mut u64 = &mut 6;\n    return (g(&1) + (*r - 5000000000) + (**rr - 240) as u64 + *m) as i32 + neg(&-3) as i32;\n}\n",
        14,
    );
    h::expect_exit(
        "a literal the value rules widen is exact under a reference",
        "fn g(x: &i64) i64 { return *x; }\nfn h(x: &f64) f64 { return *x; }\nfn main() i32 { return (g(&3) + g(&-1)) as i32 + (h(&1.5) * 2.0) as i32; }\n",
        5,
    );
    h::expect_exit(
        "map lookup with a literal key",
        "fn main() i32 {\n    let mut m = Map::<u64, i32>::new();\n    m.insert(1, 5);\n    return *m.get(&1).unwrap();\n}\n",
        5,
    );
    h::expect_exit(
        "a literal under a reference is not generic evidence",
        "fn h<T>(x: &T, y: T) T { return y; }\nfn main() i32 {\n    let k = h(&4, 5u16);\n    static_assert(sizeof(k) == 2, \"u16\");\n    let d = h(&4, 3);\n    static_assert(sizeof(d) == 4, \"i32\");\n    return (k as i32) + d;\n}\n",
        8,
    );
    h::expect_err_msg(
        "a literal under a reference is range checked",
        "fn p(x: &u8) u8 { return *x; }\nfn main() i32 { return p(&300) as i32; }\n",
        "integer literal is out of range for 'u8'",
    );
    h::expect_err_msg(
        "a typed value under a reference does not widen",
        "fn g(x: &u64) u64 { return *x; }\nfn main() i32 { let x: u8 = 1; return g(&x) as i32; }\n",
        "mismatched types: expected '&u64', found '&u8'",
    );
    h::expect_err_msg(
        "a shared reference to a literal is not mutable",
        "fn mm(x: &mut u64) u64 { return *x; }\nfn main() i32 { return mm(&6) as i32; }\n",
        "mismatched types: expected '&mut u64', found '&i32'",
    );
}

// A const parameter used as an array length binds from the argument's length, through references
// and at every nesting level; an array literal argument takes the element type from the parameter.
@test
fn const_lengths_from_arguments() {
    h::expect_exit(
        "literal, reference, nested and mutable arguments",
        "fn third<const N: usize>(a: [i32; N]) i32 { return unsafe a[2]; }\nfn len<const N: usize>(a: &[i32; N]) usize { return N; }\nfn dims<const R: usize, const C: usize>(a: &[[u8; C]; R]) usize { return R * 10 + C; }\nfn sum<const N: usize>(a: &mut [i64; N]) i64 { let mut s: i64 = 0; for i in 0..N { s += unsafe a[i]; } return s; }\nfn main() i32 {\n    let x: [i32; 3] = [1, 2, 3];\n    let m: [[u8; 2]; 3] = [[1, 2], [3, 4], [5, 6]];\n    let mut w = [10i64, 20, 30, 40];\n    if third([7, 8, 9]) != 9 { return 1; }\n    if len(&x) != 3 || len(&[1, 2, 3, 4, 5]) != 5 { return 2; }\n    if dims(&m) != 32 { return 3; }\n    if sum(&mut w) != 100 { return 4; }\n    return 0;\n}\n",
        0,
    );
    h::expect_exit(
        "an array literal argument adopts the element type",
        "fn f<const N: usize>(a: [u8; N]) u8 { return unsafe a[1]; }\nfn main() i32 { let x: [u8; 3] = [1, 2, 3]; return f(x) as i32 + f([1, 2, 3]) as i32 - 4; }\n",
        0,
    );
    h::expect_err_msg(
        "two lengths for one parameter conflict",
        "fn f<const N: usize>(a: [i32; N], b: [i32; N]) i32 { return 0; }\nfn main() i32 { let x: [i32; 2] = [1, 2]; let y: [i32; 3] = [1, 2, 3]; return f(x, y); }\n",
        "conflicting const generic arguments: inferred both 2 and 3",
    );
    h::expect_err_msg(
        "the element type still has to match through a reference",
        "fn f<const N: usize>(a: &[i32; N]) usize { return N; }\nfn main() i32 { let x: [i64; 3] = [1, 2, 3]; return f(&x) as i32; }\n",
        "mismatched types: expected '&[i32; 3]', found '&[i64; 3]'",
    );
}

// A generic alias named without type arguments in a struct literal infers its arguments like a
// generic struct: from the expected type, else from the field values.
@test
fn generic_alias_literals() {
    h::expect_exit(
        "expected type and field values",
        "struct Pair<A, B> { pub a: A, pub b: B }\ntype Q1<T> = Pair<T, T>;\ntype Q2<T> = Q1<Q1<T>>;\nfn main() i32 {\n    let q: Q1<i64> = Q1 { a: 5000000000, b: 2 };\n    let r = Q1 { a: 1u8, b: 2u8 };\n    static_assert(sizeof(r) == 2, \"u8\");\n    let z: Q2<u8> = Q2 { a: Q1 { a: 1, b: 2 }, b: Q1 { a: 3, b: 4 } };\n    return (q.a - 4999999990) as i32 + r.b as i32 + z.b.b as i32;\n}\n",
        16,
    );
    h::expect_err_msg(
        "an argument no value gives",
        "struct W<T> { pub n: i32 }\ntype K<T> = W<T>;\nfn main() i32 { let w = K { n: 1 }; return w.n; }\n",
        "cannot infer the generic argument 'T' of this struct literal; give it an expected type or explicit type arguments",
    );
    h::expect_err_msg(
        "an expected type the alias cannot spell",
        "struct Pair<A, B> { pub a: A, pub b: B }\ntype Q1<T> = Pair<T, T>;\nfn main() i32 { let r: Pair<i32, u8> = Q1 { a: 1, b: 2 }; return r.a; }\n",
        "mismatched types: expected 'Pair<i32, u8>', found 'Pair<i32, i32>'",
    );
}
