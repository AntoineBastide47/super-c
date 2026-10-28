// Field order: `@ordered` keeps a struct's fields, or a leading run of them, in their declared order.
import tests::harness as h;

// `@ordered` is a struct's or a prefix of its fields', where the order is not kept already.
@test
fn ordered_tags_are_checked() {
    h::expect_err_msg(
        "a gap in the prefix",
        "struct S {\n    a: u8,\n    @ordered\n    b: u64,\n}\nfn main() i32 { return 0; }\n",
        "field 'b' is '@ordered', but field 'a' before it is not: ordered fields are a prefix of the struct",
    );
    h::expect_err_msg(
        "a field of an ordered struct",
        "@ordered\nstruct S {\n    @ordered\n    a: u8,\n    b: u64,\n}\nfn main() i32 { return 0; }\n",
        "'@ordered' on a field of an '@ordered' struct, whose fields keep their declared order already",
    );
    h::expect_err_msg(
        "a union",
        "@ordered\nunion U {\n    a: u8,\n    b: u64,\n}\nfn main() i32 { return 0; }\n",
        "'@ordered' on a union, whose fields keep their declared order already",
    );
    h::expect_err_msg(
        "a field of a packed struct",
        "@packed\nstruct S {\n    @ordered\n    a: u8,\n    b: u64,\n}\nfn main() i32 { return 0; }\n",
        "'@ordered' on a field of a '@packed' struct, whose fields keep their declared order already",
    );
    h::expect_err_msg(
        "a function",
        "@ordered\nfn f() {}\nfn main() i32 { return 0; }\n",
        "may only be applied to a struct or a field",
    );
}
