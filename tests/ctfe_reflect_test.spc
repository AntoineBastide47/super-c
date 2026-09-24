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
    let r = h::compile_and_run("const A: i32 = 2147483647i32 + 1i32;\nfn main() i32 { return A; }\n");
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
