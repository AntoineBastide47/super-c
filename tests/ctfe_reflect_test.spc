// Const-evaluation and compile-time reflection paths not covered elsewhere: typed signed const
// arithmetic and its overflow trap, enum variant counting through type_info, and the tuple-field
// binder (whose field names come from the tuple type_info).
import tests::harness as h;

@test
fn typed_const_arithmetic_folds() {
    // Typed signed add and subtract fold at compile time through the checked-arithmetic path.
    h::expect_exit(
        "typed const add/sub fold",
        "const A: i32 = 100i32 + 27i32;\nconst B: i32 = 200i32 - 58i32;\nfn main() i32 { return A + B - 269; }\n",
        0,
    );
}

@test
fn const_overflow_is_rejected() {
    // A signed const addition that overflows its type is undefined behavior and the build refuses it.
    let r = h::compile_and_run("const A: i32 = i32::MAX + 1i32;\nfn main() i32 { return A; }\n");
    assert(!r.built, "const overflow fails the build");
}

@test
fn enum_variant_count_through_type_info() {
    // type_info().variants.len counts an enum's declared variants at compile time.
    h::expect_exit(
        "variant count folds to 3",
        "enum Color { Red, Green, Blue }\nfn main() i32 { return type_info::<Color>().variants.len as i32 - 3; }\n",
        0,
    );
}

@test
fn tuple_field_binder_names_each_element() {
    // fields(&tuple) binds each element; the element names come from the tuple's type_info.
    h::expect_c(
        "tuple fields compile",
        "fn main() i32 {\n    let t = (10, true, 'x');\n    inline for f in fields(&t) { let _ = f.name; }\n    return 0;\n}\n",
        "main",
    );
}

@test
fn const_fn_memo_keeps_float_arguments_apart() {
    // Two calls whose float arguments share an integer part each fold to their own result.
    h::expect_exit(
        "float arguments memo apart",
        "const fn twice(x: f64) f64 { return x * 2.0; }\nconst A: f64 = twice(1.25);\nconst B: f64 = twice(1.75);\nfn main() i32 {\n    if A != 2.5 { return 1; }\n    if B != 3.5 { return 2; }\n    return 0;\n}\n",
        0,
    );
}

@test
fn const_fn_repeat_array_fills_every_element() {
    // `[v; N]` in a const fn builds N copies of v, not one copy followed by zeros.
    h::expect_exit(
        "repeat array folds whole",
        "const fn mk(v: i32) [i32; 3] { return [v; 3]; }\nconst R: [i32; 3] = mk(7);\nfn main() i32 { return R[0] + R[1] + R[2] - 21; }\n",
        0,
    );
}

@test
fn const_fn_memcmp_reads_an_inline_string_buffer() {
    // A short String keeps its bytes in an inline array inside the struct, not in a heap block:
    // `memcmp` over it folds like over heap bytes (the lexer's keyword match does exactly this).
    h::expect_exit(
        "memcmp over an inline buffer",
        "import string as cstring;\nconst fn same(a: str, b: str) bool { let s = String::from_str(a); return s.len() == b.len() && unsafe cstring::memcmp(s.as_str().ptr(), b.ptr(), b.len()) == 0; }\nstatic_assert(same(\"@bench()\", \"@bench()\"), \"equal bytes\");\nstatic_assert(!same(\"@bench()\", \"@bench]\"), \"a differing byte\");\nfn main() i32 { return 0; }\n",
        0,
    );
}

@test
fn speculative_fold_of_a_plain_fn_stays_silent() {
    // `make` is not a `const fn`: folding `make(1)` is speculative, so a `const fn` it calls that the
    // evaluator cannot run (a value of a type with a user `Free` never folds) is no error there.
    h::expect_exit(
        "a plain fn over a const fn that cannot fold",
        "struct P { pub n: i32 }\nextend P as Free { fn free(self: &mut Self) {} }\nextend P { pub const fn new() P { return P { n: 0 }; } }\nfn make(x: i32) i32 { let p = P::new(); return p.n + x; }\nfn main() i32 { assert(make(1) == 1, \"one\"); return make(0); }\n",
        0,
    );
    // A chain of `const fn` frames keeps the guarantee: the same failure fails the build.
    let r = h::compile_and_run(
        "struct P { pub n: i32 }\nextend P as Free { fn free(self: &mut Self) {} }\nextend P { pub const fn new() P { return P { n: 0 }; } }\nconst fn make(x: i32) i32 { let p = P::new(); return p.n + x; }\nfn main() i32 { return make(0); }\n",
    );
    assert(!r.built, "a const fn over a const fn that cannot fold is an error");
}

// `n` scalar constants, each derived from the one before (C0 = 1, Ci = C(i-1) % 7 + 1), then `tail`.
fn const_chain(n: i32, tail: str) String {
    let mut s = String::from_str("const C0: i32 = 1;\n");
    for i in 1..n {
        s.push_str(format("const C{}: i32 = C{} % 7 + 1;\n", i, i - 1).as_str());
    }
    s.push_str(tail);
    return s;
}

@test
fn deep_constant_chain_evaluates_without_nesting() {
    // Each constant reads the previous one: evaluating the last must not nest 20000 evaluations
    // on the native stack. C19999 = 19999 % 7 + 1 = 1.
    let src = const_chain(20000, "static_assert(C19999 == 1);\nfn main() i32 { return C19999; }\n");
    h::expect_exit("a 20000-constant chain folds", src.as_str(), 1);
}

@test
fn deep_aggregate_constant_chain_evaluates_without_nesting() {
    // Aggregate values are never memoized: a 300-deep chain of them still evaluates dependency first.
    let mut s = String::from_str("struct P { pub x: i32, pub y: i32 }\nconst P0: P = P { x: 1, y: 2 };\n");
    for i in 1..300 {
        s.push_str(format("const P{}: P = P {{ x: P{}.y % 7 + 1, y: P{}.x }};\n", i, i - 1, i - 1).as_str());
    }
    s.push_str("fn main() i32 { return P299.x * 10 + P299.y; }\n");
    h::expect_exit("a 300-aggregate chain folds", s.as_str(), 53);
}

// A constant of a generic aggregate keeps every instance argument, up to the language's limit of
// eight: struct and enum constants, arrays of them and a `const fn` result all emit as static data.
@test
fn constants_keep_every_instance_argument() {
    h::expect_exit(
        "five and eight instance arguments",
        M"(struct S5<A, B, C, D, E> { pub a: A, pub b: B, pub c: C, pub d: D, pub e: E }
enum E5<A, B, C, D, E> { V(A, B, C, D, E), W }
struct S8<A, B, C, D, E, F, G, H> { pub a: A, pub b: B, pub c: C, pub d: D, pub e: E, pub f: F, pub g: G, pub h: H }
const K: S5<i32, u8, i16, i64, u16> = S5 { a: 1, b: 2, c: 3, d: 4, e: 5 };
const KE: E5<i32, u8, i16, i64, u16> = E5::V(1, 2, 3, 4, 5);
const KS: [S5<i32, u8, i16, i64, u16>; 2] = [S5 { a: 1, b: 2, c: 3, d: 4, e: 5 }, S5 { a: 1, b: 2, c: 3, d: 4, e: 6 }];
const K8: S8<u8, u16, u32, u64, i8, i16, i32, i64> = S8 { a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8 };
const fn mk() S5<i32, u8, i16, i64, u16> { return S5 { a: 10, b: 2, c: 3, d: 4, e: 5 }; }
const K2: i32 = mk().a;
fn main() i32 {
    let e = switch KE { V(a, b, c, d, x) => a + b as i32 + c as i32 + d as i32 + x as i32, W => 0 };
    return K.a + K.e as i32 + e + KS[1].e as i32 + K2 + K8.h as i32 + K8.a as i32 - 46;
}
)",
        0,
    );
}
