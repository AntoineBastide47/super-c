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
