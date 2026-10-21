// Header types: a `struct` or `union` of an `extern "C"` block is the C header's type. The declaration
// lists every member in the header's order, so Super-C computes the C layout; the emitted C checks the
// size, the alignment, and each field's offset and type against the header with `_Static_assert`. A
// constant of an extern block with a value is a Super-C constant the C compile checks the same way.
import fmt::builder as fbld;
import tests::harness as h;
import tests::cli_harness as cli;

// `struct tm` of each target's C library, every member in its order.
const TM: str = M"(extern "C" "time.h" {
    @platform(macos | ios)
    struct tm {
        pub tm_sec: i32,
        pub tm_min: i32,
        pub tm_hour: i32,
        pub tm_mday: i32,
        pub tm_mon: i32,
        pub tm_year: i32,
        pub tm_wday: i32,
        pub tm_yday: i32,
        pub tm_isdst: i32,
        pub tm_gmtoff: i64,
        pub tm_zone: *mut char,
    }
    @platform(linux)
    struct tm {
        pub tm_sec: i32,
        pub tm_min: i32,
        pub tm_hour: i32,
        pub tm_mday: i32,
        pub tm_mon: i32,
        pub tm_year: i32,
        pub tm_wday: i32,
        pub tm_yday: i32,
        pub tm_isdst: i32,
        @import("__tm_gmtoff")
        pub tm_gmtoff: i64,
        @import("__tm_zone")
        pub tm_zone: *const char,
    }
    @platform(windows)
    struct tm {
        pub tm_sec: i32,
        pub tm_min: i32,
        pub tm_hour: i32,
        pub tm_mday: i32,
        pub tm_mon: i32,
        pub tm_year: i32,
        pub tm_wday: i32,
        pub tm_yday: i32,
        pub tm_isdst: i32,
    }
    @platform(wasm)
    struct tm {
        pub tm_sec: i32,
        pub tm_min: i32,
        pub tm_hour: i32,
        pub tm_mday: i32,
        pub tm_mon: i32,
        pub tm_year: i32,
        pub tm_wday: i32,
        pub tm_yday: i32,
        pub tm_isdst: i32,
        @import("__tm_gmtoff")
        pub tm_gmtoff: i32,
        @import("__tm_zone")
        pub tm_zone: *const char,
        @import("__tm_nsec")
        pub tm_nsec: i32,
    }
    fn strftime(dst: *mut char, max: usize, fmt: *const char, t: *const tm) usize;
}
)";

// `div_t`: the same members on every target.
const DIV: str = "extern \"C\" \"stdlib.h\" {\n    @import(\"div_t\")\n    struct div_t { pub quot: i32, pub rem: i32 }\n    fn div(n: i32, d: i32) div_t;\n}\n";

// The emitted C: the header's own type by its tag or typedef (by alias in a unit, for a header
// `super_rt.h` does not include), member access by name, the header's include, the size and alignment
// of the type, and each field's offset, size and signedness.
@test
fn header_type_emits_layout_checks() {
    let mut src = String::from_str(DIV);
    src.push_str(
        "extern \"C\" \"lib.h\" {\n    struct rec { pub a: i32, pub b: i64 }\n}\nfn main() i32 {\n    let mut r = rec { a: 3 };\n    r.b = 4;\n    let d = unsafe div(7, 2);\n    return r.a + r.b as i32 + d.rem - 8;\n}\n",
    );
    let c = h::compile_c(src.as_str());
    assert(c.ok(), "the program compiles");
    assert(c.code_has("#include <stdlib.h>"), "the header is included");
    assert(
        c.code_has("__sc_x_struct_rec r = (__sc_x_struct_rec){ .a = 3"),
        "a literal names the header's type by its alias",
    );
    assert(c.code_has("r.b = 4"), "a field is the C member by name");
    assert(c.code_has("div_t d = div("), "a typedef'd type is its typedef name");
    assert(
        c.code_has("_Static_assert(sizeof(div_t) != 0, \"super-c: 'div_t' must be a complete C type\");"),
        "the type is checked complete",
    );
    assert(
        c.code_has(
            "_Static_assert(sizeof(div_t) == 8u && _Alignof(div_t) == 4u, \"super-c: 'div_t' must have 8 bytes aligned to 4 in C: declare every member of the header's type, in its order\");",
        ),
        "the size and alignment are checked",
    );
    assert(
        c.code_has(
            "_Static_assert(offsetof(div_t, quot) == 0u, \"super-c: field 'div_t.quot' must sit at byte 0 in C: declare every member of the header's type, in its order\");",
        ),
        "the first field's offset is checked",
    );
    assert(c.code_has("_Static_assert(offsetof(div_t, rem) == 4u,"), "every field's offset is checked");
    assert(
        c.code_has(
            "_Static_assert(sizeof(((div_t *)0)->rem) == 4 && _Generic(((div_t *)0)->rem, signed char: 1, short: 1, int: 1, long: 1, long long: 1, default: 0), \"super-c: field 'div_t.rem' must be a signed integer of 4 bytes in C\");",
        ),
        "a field's size and signedness are checked",
    );
    assert(c.code_has("_Static_assert(sizeof(struct rec) == 16u && _Alignof(struct rec) == 8u,"), "a tagged type");
    assert(c.code_has("_Static_assert(offsetof(struct rec, b) == 8u,"), "the padding before a field");
    assert(!c.code_has("super-c layout model mismatch: div_t"), "one layout check per type");
}

// Every field type category spells its own check; a union's members sit at 0; `@packed`, `@align` and
// an opaque type's `@layout` enter the computed layout.
@test
fn header_type_check_per_field_kind() {
    let src = "extern \"C\" \"lib.h\" {\n    struct tm { pub tm_sec: i32 }\n    @layout(16, 8)\n    type blob;\n    struct rec {\n        pub flag: bool,\n        pub c: char,\n        pub n: u16,\n        pub w: usize,\n        pub f: f32,\n        pub d: f64,\n        pub p: *const char,\n        pub cb: fn(i32) i32,\n        pub name: [[u8; 4]; 2],\n        pub t: tm,\n        pub b: blob,\n    }\n    union u { pub i: i32, pub f: f32 }\n    @packed\n    struct pk { pub tag: u8, pub v: i32 }\n    @align(16)\n    struct al { pub v: i32 }\n}\nfn main() i32 {\n    let r = unsafe zeroed::<rec>();\n    let v = unsafe zeroed::<u>();\n    let k = unsafe zeroed::<pk>();\n    let a = unsafe zeroed::<al>();\n    return r.n as i32 + unsafe v.i + k.v + a.v;\n}\n";
    let c = h::compile_c(src);
    assert(c.ok(), "the program compiles");
    assert(c.code_has("sizeof(((struct tm *)0)->tm_sec) == 4"), "an integer field");
    assert(
        c.code_has(
            "_Generic(((struct rec *)0)->flag, _Bool: 1, default: 0), \"super-c: field 'rec.flag' must be _Bool in C\"",
        ),
        "a bool field",
    );
    assert(
        c.code_has(
            "_Generic(((struct rec *)0)->c, char: 1, signed char: 1, unsigned char: 1, default: 0), \"super-c: field 'rec.c' must be a char in C\"",
        ),
        "a char field",
    );
    assert(
        c.code_has("\"super-c: field 'rec.n' must be an unsigned integer of 2 bytes in C\""),
        "an unsigned field's message",
    );
    assert(
        c.code_has(
            "sizeof(((struct rec *)0)->w) == sizeof(void *) && _Generic(((struct rec *)0)->w, char: 1, unsigned char: 1,",
        ),
        "a usize field is pointer-sized",
    );
    assert(
        c.code_has("\"super-c: field 'rec.w' must be an unsigned integer of pointer size in C\""),
        "a usize field's message",
    );
    assert(c.code_has("_Generic(((struct rec *)0)->f, float: 1, default: 0)"), "an f32 field");
    assert(c.code_has("_Generic(((struct rec *)0)->d, double: 1, default: 0)"), "an f64 field");
    assert(
        c.code_has("sizeof(((struct rec *)0)->p) == sizeof(void *) && _Generic(((struct rec *)0)->p, _Bool: 0,"),
        "a pointer field",
    );
    assert(c.code_has("\"super-c: field 'rec.cb' must be a pointer in C\""), "a function pointer field");
    assert(
        c.code_has(
            "sizeof(((struct rec *)0)->name) == 2 * sizeof((((struct rec *)0)->name)[0]) && sizeof((((struct rec *)0)->name)[0]) == 4 * sizeof(((((struct rec *)0)->name)[0])[0]) && sizeof(((((struct rec *)0)->name)[0])[0]) == 1",
        ),
        "a nested array field's extents",
    );
    assert(
        c.code_has(
            "\"super-c: field 'rec.name' must be an array of 2 elements, each an array of 4 elements, each an unsigned integer of 1 byte in C\"",
        ),
        "a nested array field's message",
    );
    assert(
        c.code_has(
            "_Generic(((struct rec *)0)->t, __sc_x_struct_tm: 1, default: 0), \"super-c: field 'rec.t' must be a 'struct tm' in C\"",
        ),
        "a header struct field",
    );
    assert(
        c.code_has(
            "_Static_assert(sizeof(blob) == 16u && _Alignof(blob) == 8u, \"super-c: 'blob' must have 16 bytes aligned to 8 in C\");",
        ),
        "an opaque type's layout",
    );
    assert(c.code_has("_Generic(((struct rec *)0)->b, __sc_x_blob: 1, default: 0)"), "an opaque field");
    assert(
        c.code_has(
            "_Static_assert(offsetof(union u, i) == 0u, \"super-c: field 'u.i' must sit at byte 0 in C: declare every member of the header's type, in its order\");",
        ),
        "a union member",
    );
    assert(c.code_has("_Static_assert(offsetof(union u, f) == 0u,"), "every union member");
    assert(c.code_has("_Static_assert(sizeof(union u) == 4u && _Alignof(union u) == 4u,"), "a union's layout");
    assert(c.code_has("_Static_assert(sizeof(struct pk) == 5u && _Alignof(struct pk) == 1u,"), "a packed struct");
    assert(c.code_has("_Static_assert(offsetof(struct pk, v) == 1u,"), "a packed field");
    assert(c.code_has("_Static_assert(sizeof(struct al) == 16u && _Alignof(struct al) == 16u,"), "an aligned struct");
}

// A zero-length array field is C's flexible array member (`char d_name[];`): only its element is
// checked, since `sizeof` rejects an incomplete array. A `*mut void` parameter of a function its header
// declares converts its argument through `void *`: the header may name another pointer type there.
@test
fn header_type_flexible_member_and_void_parameter() {
    let src = "extern \"C\" \"lib.h\" {\n    struct ent { pub ino: u64, pub kind: u8, pub name: [char; 0] }\n    fn fill(out: *mut void) i32;\n}\nfn main() i32 {\n    let e = unsafe zeroed::<ent>();\n    let mut code: u32 = 0;\n    return unsafe fill(&mut code) + e.kind as i32;\n}\n";
    let c = h::compile_c(src);
    assert(c.ok(), "the program compiles");
    assert(!c.code_has("sizeof(((struct ent *)0)->name) =="), "no extent check on a flexible member");
    assert(
        c.code_has("\"super-c: field 'ent.name' must be a flexible array, each element a char in C\""),
        "the element is checked",
    );
    assert(c.code_has("fill((void *)("), "the argument converts through void *");
}

fn header_type_values_through_c(b: &mut h::ExitBatch) {
    let mut src = String::from_str(TM);
    src.push_str(
        "fn main() i32 {\n    let t = tm { tm_hour: 5, tm_min: 7, tm_sec: 9, tm_mday: 1 };\n    let mut buf: [char; 16] = [0 as char; 16];\n    let n = unsafe strftime(&mut buf[0], 16, \"%H:%M:%S\".ptr() as *const char, &t);\n    if n != 8 { return 1; }\n    if buf[1] as u8 != b'5' || buf[4] as u8 != b'7' || buf[7] as u8 != b'9' { return 2; }\n    return 0;\n}\n",
    );
    b.add("header struct fields reach the C members by name", src.as_str(), 0);
    b.add(
        "a field pinned to its C member, returned by value",
        "extern \"C\" \"stdlib.h\" {\n    @import(\"div_t\")\n    struct div_t {\n        @import(\"quot\")\n        pub q: i32,\n        pub rem: i32,\n    }\n    fn div(n: i32, d: i32) div_t;\n}\nfn main() i32 {\n    let d = unsafe div(17, 5);\n    let mut e = d;\n    e.q = e.q + d.rem;\n    if d.q != 3 || d.rem != 2 || e.q != 5 { return 1; }\n    return 0;\n}\n",
        0,
    );
}

fn header_type_layout_at_compile_time(b: &mut h::ExitBatch) {
    let mut src = String::from_str(DIV);
    src.push_str(
        "const N: usize = sizeof(div_t);\nstatic_assert(N == 8 && alignof(div_t) == 4, \"div_t\");\nconst Z: usize = type_info::<div_t>().size;\nstruct W { pub d: div_t, pub k: u8 }\nfn main() i32 {\n    let b = [0u8; sizeof(div_t)];\n    let c: [u8; sizeof([div_t; 2])] = unsafe zeroed::<[u8; 16]>();\n    if sizeof(b) != 8 || sizeof(c) != 16 || Z != 8 || sizeof(W) != 12 { return 1; }\n    let d = unsafe div(7, 2);\n    let two: [div_t; 2] = [d, d];\n    return (sizeof(two) != 16) as i32;\n}\n",
    );
    b.add("sizeof, alignof and reflection of a header struct are compile-time values", src.as_str(), 0);
}

fn header_type_value_uses(b: &mut h::ExitBatch) {
    let mut src = String::from_str(DIV);
    src.push_str(
        "fn id<T>(x: T) T { return x; }\nstruct W { pub t: div_t, pub k: i32 }\nfn main() i32 {\n    let a = div_t { rem: 7 };\n    let mut b = a;\n    b.rem = 8;\n    if a.rem != 7 || a.quot != 0 { return 1; }\n    let arr: [div_t; 3] = [a, b, id(a)];\n    let s: []div_t = arr;\n    if s[1].rem != 8 || s.len() != 3 { return 2; }\n    let mut v = Vector::<div_t>::new();\n    for i in 0..s.len() { v.push(s[i]); }\n    if v.len() != 3 || v.at(2).rem != 7 { return 3; }\n    let o = Option::<div_t>::Some(b);\n    let m = switch o { Some(x) => x.rem, None => 0 };\n    if m != 8 { return 4; }\n    let w = W { t: b, k: 4 };\n    if w.t.rem + w.k != 12 { return 5; }\n    let z = unsafe zeroed::<div_t>();\n    if z.quot != 0 || z.rem != 0 { return 6; }\n    let hz = W { k: 1 };\n    if hz.t.rem != 0 { return 7; }\n    return 0;\n}\n",
    );
    b.add("copies, arrays, slices, vectors, options, generics and holders of a header struct", src.as_str(), 0);
}

fn header_type_compile_time_values(b: &mut h::ExitBatch) {
    let mut src = String::from_str(DIV);
    src.push_str(
        "const fn mk(n: i32) div_t {\n    let mut t = div_t { quot: n };\n    t.rem = t.quot + 1;\n    return t;\n}\nconst K: div_t = mk(3);\nconst S: i32 = mk(5).rem;\nstatic mut G: div_t = div_t { rem: 9 };\nfn main() i32 {\n    let k = K;\n    let g = unsafe G;\n    if k.quot != 3 || k.rem != 4 || S != 6 { return 1; }\n    if g.rem != 9 || g.quot != 0 { return 2; }\n    return 0;\n}\n",
    );
    b.add("constants and statics of a header struct", src.as_str(), 0);
}

// The constants span the integer range: the C check spells each value as C reads it.
fn header_constants(b: &mut h::ExitBatch) {
    b.add(
        "constants of an extern block with values per platform",
        M"(extern "C" "stdlib.h" {
    pub const EXIT_FAILURE: i32 = 1;
    @import("EXIT_SUCCESS")
    pub const SUCCESS_IS_TRUE: bool = false;
}
extern "C" "limits.h" {
    const CHAR_BIT: u32 = 8;
    const INT_MIN: i32 = -2147483648;
    const LLONG_MIN: i64 = -9223372036854775807 - 1;
    const ULLONG_MAX: u64 = 0xFFFFFFFFFFFFFFFF;
}
extern "C" "fcntl.h" {
    @platform(macos | ios)
    const O_CREAT: i32 = 0x200;
    @platform(linux | android)
    const O_CREAT: i32 = 0o100;
    @platform(windows)
    const O_CREAT: i32 = 0x100;
    @platform(wasm)
    const O_CREAT: i32 = 0x1000;
}
const BITS: [u8; CHAR_BIT as usize] = [0u8; CHAR_BIT as usize];
static_assert(INT_MIN == -2147483648 && LLONG_MIN + 1 == -9223372036854775807 && ULLONG_MAX == 0xFFFFFFFFFFFFFFFF, "limits");
static_assert((O_CREAT & (O_CREAT - 1)) == 0, "one flag bit");
fn get(p: &i32) i32 {
    return *p;
}
fn main() i32 {
    if get(&EXIT_FAILURE) != 1 || SUCCESS_IS_TRUE || sizeof(BITS) != 8 {
        return 1;
    }
    let flags: [i32; 2] = [O_CREAT, 1];
    return (get(&flags[0]) != O_CREAT) as i32;
}
)",
        0,
    );
}

@test
fn exit_cases_00() {
    let mut b = h::ExitBatch::new();
    header_type_values_through_c(&mut b);
    header_type_layout_at_compile_time(&mut b);
    header_type_value_uses(&mut b);
    header_type_compile_time_values(&mut b);
    header_constants(&mut b);
    b.run();
}

// Declaration errors: a field type with no C equivalent, a duplicate field, an unknown field at a use, a
// destructor, a missing header, a misplaced or invalid `@layout`, and an extern constant's value.
@test
fn header_type_declaration_errors() {
    h::expect_err_msg(
        "owning field",
        "extern \"C\" \"lib.h\" {\n    struct rec { pub a: String }\n}\nfn main() i32 { return 0; }\n",
        "field 'a' of 'rec' has type 'String<Global>', which has no C equivalent",
    );
    h::expect_err_msg(
        "reference field",
        "extern \"C\" \"lib.h\" {\n    struct rec { pub a: &i32 }\n}\nfn main() i32 { return 0; }\n",
        "field 'a' of 'rec' has type '&i32', which has no C equivalent",
    );
    h::expect_err_msg(
        "super-c struct field",
        "struct P { pub x: i32 }\nextern \"C\" \"lib.h\" {\n    struct rec { pub a: P }\n}\nfn main() i32 { return 0; }\n",
        "field 'a' of 'rec' has type 'P', which has no C equivalent",
    );
    h::expect_err_msg(
        "slice field",
        "extern \"C\" \"lib.h\" {\n    struct rec { pub a: []u8 }\n}\nfn main() i32 { return 0; }\n",
        "which has no C equivalent",
    );
    h::expect_err_msg(
        "opaque field without a layout",
        "extern \"C\" \"lib.h\" {\n    type h;\n    struct rec { pub a: h }\n}\nfn main() i32 { return 0; }\n",
        "'h' is an opaque C type with no layout: a value of it needs one",
    );
    h::expect_err_msg(
        "member pin outside an extern block",
        "struct P {\n    @import(\"x\")\n    pub y: i32,\n}\nfn main() i32 { return 0; }\n",
        "only '@reflect' applies to a field declaration, and '@import' to a field of an 'extern \"C\"' struct or union",
    );
    h::expect_err_msg(
        "duplicate field",
        "extern \"C\" \"lib.h\" {\n    struct rec { pub a: i32, pub a: i32 }\n}\nfn main() i32 { return 0; }\n",
        "duplicate definition of 'a'",
    );
    h::expect_err_msg(
        "unknown field read",
        "extern \"C\" \"lib.h\" {\n    struct rec { pub a: i32 }\n}\nfn main() i32 {\n    let t = unsafe zeroed::<rec>();\n    return t.b;\n}\n",
        "no field or method 'b' on 'rec'",
    );
    h::expect_err_msg(
        "unknown field in a literal",
        "extern \"C\" \"lib.h\" {\n    struct rec { pub a: i32 }\n}\nfn main() i32 {\n    let t = rec { b: 1 };\n    return t.a;\n}\n",
        "no field 'b' on 'rec'",
    );
    h::expect_err_msg(
        "destructor",
        "extern \"C\" \"lib.h\" {\n    struct rec { pub a: i32 }\n}\nextend rec as Free {\n    fn free(self: &mut rec) {}\n}\nfn main() i32 { return 0; }\n",
        "'rec' is a type of an 'extern \"C\"' block: it cannot implement 'Free'",
    );
    h::expect_err_msg(
        "no header",
        "extern \"C\" {\n    pub struct pt { pub x: i32, pub y: i32 }\n}\nfn main() i32 {\n    let p = pt { x: 1, y: 2 };\n    return p.x + p.y - 3;\n}\n",
        "a struct of an 'extern \"C\"' block is its C header's type: the block needs that header",
    );
    h::expect_err_msg(
        "an enum with no header",
        "extern \"C\" {\n    enum color { RED, GREEN }\n}\nfn main() i32 { return 0; }\n",
        "an enum of an 'extern \"C\"' block is its C header's type: the block needs that header",
    );
    h::expect_err_msg(
        "an empty header",
        "extern \"C\" \"\" {\n    union u { pub i: i32 }\n}\nfn main() i32 { return 0; }\n",
        "a union of an 'extern \"C\"' block is its C header's type: the block needs that header",
    );
    h::expect_err_msg(
        "a layout on a struct",
        "extern \"C\" \"lib.h\" {\n    @layout(4, 4)\n    struct rec { pub a: i32 }\n}\nfn main() i32 { return 0; }\n",
        "'@layout' may only be applied to an opaque type ('type T;') in an 'extern \"C\"' block",
    );
    h::expect_err_msg(
        "an invalid layout",
        "extern \"C\" \"lib.h\" {\n    @layout(6, 4)\n    type h;\n}\nfn main() i32 { return 0; }\n",
        "'@layout' needs a nonzero size that is a multiple of the alignment, a power of two; found (6, 4)",
    );
    h::expect_err_msg(
        "a layout on a register type",
        "extern \"C\" \"lib.h\" {\n    @value(16, 16)\n    @layout(16, 16)\n    type h;\n}\nfn main() i32 { return 0; }\n",
        "a register type ('@value') states its layout: it takes no '@layout'",
    );
    h::expect_err_msg(
        "a layout with no header",
        "extern \"C\" {\n    @layout(8, 8)\n    type h;\n}\nfn main() i32 { return 0; }\n",
        "an opaque type with a '@layout' of an 'extern \"C\"' block is checked against its C header: the block needs that header",
    );
    h::expect_err_msg(
        "an opaque value",
        "extern \"C\" \"lib.h\" {\n    type h;\n    fn get() h;\n}\nfn main() i32 { return 0; }\n",
        "'h' is an opaque C type with no layout: a value of it needs one",
    );
    h::expect_err_msg(
        "a float constant",
        "extern \"C\" \"math.h\" {\n    const HUGE_VAL: f64 = 1.0;\n}\nfn main() i32 { return 0; }\n",
        "a constant of an 'extern \"C\"' block with a value is an integer or a 'bool': the C compile checks it",
    );
    h::expect_err_msg(
        "a constant with no header",
        "extern \"C\" {\n    const K: i32 = 1;\n}\nfn main() i32 { return K; }\n",
        "a constant with a value of an 'extern \"C\"' block is checked against its C header: the block needs that header",
    );
    h::expect_err_msg(
        "an extern static with a value",
        "extern \"C\" \"lib.h\" {\n    static mut g: i32 = 1;\n}\nfn main() i32 { return 0; }\n",
        "an extern static takes no initializer: the C side defines it",
    );
}

// A wrong declaration fails the C compile with the check's message, on every target: a pointer for an
// int, two fields out of the header's order, a missing member, a float for an integer, a wrong
// constant, and a wrong opaque layout.
@test
fn header_type_wrong_declaration_fails_the_c_compile() {
    let src = "extern \"C\" \"time.h\" {\n    struct tm { pub tm_sec: *mut void }\n}\nextern \"C\" \"stdlib.h\" {\n    @import(\"div_t\")\n    struct div_t { pub rem: i32, pub quot: i32 }\n    @import(\"ldiv_t\")\n    struct ldiv_t { pub quot: i64 }\n    @import(\"lldiv_t\")\n    struct lldiv_t { pub quot: f64, pub rem: i64 }\n    const EXIT_FAILURE: i32 = 2;\n}\nextern \"C\" \"wchar.h\" {\n    @layout(2, 2)\n    type mbstate_t;\n}\nfn main() i32 {\n    let t = unsafe zeroed::<tm>();\n    let d = unsafe zeroed::<div_t>();\n    let l = unsafe zeroed::<ldiv_t>();\n    let q = unsafe zeroed::<lldiv_t>();\n    let s = unsafe zeroed::<mbstate_t>();\n    let ss = s;\n    return d.rem + l.quot as i32 + q.quot as i32 + (t.tm_sec == null) as i32 + EXIT_FAILURE + sizeof(mbstate_t) as i32;\n}\n";
    let b = h::diff_build(src, []);
    let d = b.diag.as_str();
    if b.built || !d.contains("super-c: field 'tm.tm_sec' must be a pointer in C") {
        eprintln("{}", d);
    }
    assert(!b.built, "the C compile fails");
    assert(d.contains("super-c: field 'tm.tm_sec' must be a pointer in C"), "a pointer for an int");
    assert(d.contains("super-c: field 'div_t.rem' must sit at byte 0 in C"), "the order");
    assert(d.contains("super-c: 'ldiv_t' must have 8 bytes aligned to 8 in C"), "a missing member");
    assert(d.contains("super-c: field 'lldiv_t.quot' must be double in C"), "a float for an integer");
    assert(d.contains("super-c: constant 'EXIT_FAILURE' must be 2 in C"), "a wrong constant");
    assert(d.contains("super-c: 'mbstate_t' must have 2 bytes aligned to 2 in C"), "a wrong opaque layout");
}

// A header that does not define the declared type: Super-C cannot see into the header, so the C
// compile stops at the type's completeness check, the first use of the type in every unit. Its line
// holds the message, which the C compiler prints with the error.
@test
fn header_type_missing_from_its_header() {
    let src = "extern \"C\" \"stdio.h\" {\n    pub struct pt { pub x: i32, pub y: i32 }\n}\nfn main() i32 {\n    let p = pt { x: 1, y: 2 };\n    return p.x + p.y - 3;\n}\n";
    let b = h::diff_build(src, ["--jobs=1"]);
    let d = b.diag.as_str();
    let first = d.find("error:");
    let msg = d.find("super-c: 'pt' must be a complete C type");
    if b.built || first < 0 || msg < first {
        eprintln("{}", d);
    }
    assert(!b.built, "the C compile fails");
    assert(first >= 0, "the C compile reports an error");
    assert(msg > first, "the completeness check's message follows the first error");
    let next = d.slice(first as usize + 6, d.len()).find("error:");
    assert(next < 0 || msg < first + 6 + next, "the first error shows the completeness check");
}

// Every type of an extern block is a C value: none implements 'Free', whose glue would never run on
// a value C copies.
@test
fn extern_types_reject_free() {
    h::expect_err_msg(
        "opaque type",
        "extern \"C\" {\n    type clock_t;\n}\nextend clock_t as Free {\n    fn free(self: &mut clock_t) {}\n}\nfn main() i32 { return 0; }\n",
        "'clock_t' is a type of an 'extern \"C\"' block: it cannot implement 'Free'",
    );
    h::expect_err_msg(
        "extern enum",
        "extern \"C\" \"stdio.h\" {\n    @import(\"int\")\n    enum mode { A, B }\n}\nextend mode as Free {\n    fn free(self: &mut mode) {}\n}\nfn main() i32 { return 0; }\n",
        "'mode' is a type of an 'extern \"C\"' block: it cannot implement 'Free'",
    );
}

const ENUM_H: str = "#ifndef LIB_H\n#define LIB_H\nenum color { RED, GREEN = 5, BLUE };\ntypedef enum { SMALL, LARGE } size_kind;\nstruct pen { enum color c; size_kind k; int w; };\nint pen_code(struct pen p, enum color c, size_kind k);\n#endif\n";

// An extern enum is its C tag (`enum color`); a typedef'd one pins the typedef name. Both pass by
// value through C, as a parameter and as a member of a header struct, under the strict warning set.
@test
fn header_enum_tag_and_typedef() {
    let p = cli::proj_new();
    p.mkfile("lib.h", ENUM_H);
    p.mkfile(
        "lib.c",
        "#include \"lib.h\"\nint pen_code(struct pen p, enum color c, size_kind k) { return (int)p.c * 100 + (int)p.k * 10 + (int)c + (int)k + p.w; }\n",
    );
    p.mkfile(
        "main.spc",
        "extern \"C\" \"lib.h\" {\n    enum color { RED, GREEN = 5, BLUE }\n    @import(\"size_kind\")\n    enum size_kind { SMALL, LARGE }\n    struct pen { pub c: color, pub k: size_kind, pub w: i32 }\n    fn pen_code(p: pen, c: color, k: size_kind) i32;\n}\n\nfn main() i32 {\n    let p = pen { c: color::BLUE, k: size_kind::LARGE, w: 1 };\n    let n = unsafe pen_code(p, color::GREEN, size_kind::SMALL);\n    return n - 616;\n}\n",
    );
    let r = p.compile("main.spc");
    if !r.ok() {
        eprintln("{}", r.text());
    }
    assert(r.ok(), "the program compiles");
    assert(
        p.xhdr_has("_Static_assert(sizeof(enum color) != 0, \"super-c: 'color' must be a complete C type\");"),
        "an enum is its C tag",
    );
    assert(p.xhdr_has("_Static_assert(sizeof(size_kind) != 0,"), "a typedef'd enum is its typedef");
    assert(
        p.xhdr_has("_Generic(((struct pen *)0)->c, __sc_x_enum_color: 1, default: 0)"),
        "an enum member is checked by its tag",
    );
    assert(
        p.xhdr_has("_Generic(((struct pen *)0)->k, __sc_x_size_kind: 1, default: 0)"),
        "a typedef'd enum member is checked by its typedef",
    );
    assert(
        p.xhdr_has("_Static_assert(sizeof(struct pen) == 12u && _Alignof(struct pen) == 4u,"),
        "a struct of enums has the C layout",
    );
    let cc = p.cc_build("");
    if !cc.ok() {
        eprintln("{}", cc.text());
    }
    assert(cc.ok(), "the emitted C compiles under the strict warning set");
    assert_eq(p.run_bin(), 0);
}

// A typedef'd enum declared without its pin spells `enum size_kind`, which C does not define: the
// first error of the C compile is at the type's completeness check, whose line holds the message.
@test
fn header_enum_wrong_spelling() {
    let p = h::diff_proj();
    p.mkfile("lib.h", ENUM_H);
    p.mkfile(
        "main.spc",
        "extern \"C\" \"lib.h\" {\n    enum size_kind { SMALL, LARGE }\n}\n\nfn main() i32 {\n    let k = size_kind::LARGE;\n    return k as i32 - 1;\n}\n",
    );
    let b = h::diff_build_in(p, ["--jobs=1"]);
    let d = b.diag.as_str();
    let first = d.find("error:");
    let msg = d.find("super-c: 'size_kind' must be a complete C type");
    if b.built || first < 0 || msg < first {
        eprintln("{}", d);
    }
    assert(!b.built, "the C compile fails");
    assert(first >= 0, "the C compile reports an error");
    assert(msg > first, "the completeness check's message follows the first error");
    let next = d.slice(first as usize + 6, d.len()).find("error:");
    assert(next < 0 || msg < first + 6 + next, "the first error shows the completeness check");
}

// `struct stat` of each target's C library, every member in its order, as the build's feature macros
// (`_POSIX_C_SOURCE=200809L`) define it.
const STAT: str = M"(extern "C" "sys/stat.h" {
    @platform(macos | ios)
    struct stat {
        pub st_dev: i32,
        pub st_mode: u16,
        pub st_nlink: u16,
        pub st_ino: u64,
        pub st_uid: u32,
        pub st_gid: u32,
        pub st_rdev: i32,
        pub st_atime: i64,
        pub st_atimensec: i64,
        pub st_mtime: i64,
        pub st_mtimensec: i64,
        pub st_ctime: i64,
        pub st_ctimensec: i64,
        pub st_birthtime: i64,
        pub st_birthtimensec: i64,
        pub st_size: i64,
        pub st_blocks: i64,
        pub st_blksize: i32,
        pub st_flags: u32,
        pub st_gen: u32,
        pub st_lspare: i32,
        pub st_qspare: [i64; 2],
    }
    @platform(linux | wasm)
    struct timespec { pub tv_sec: i64, pub tv_nsec: isize }
    @platform(linux)
    @arch(x86_64)
    struct stat {
        pub st_dev: u64,
        pub st_ino: u64,
        pub st_nlink: u64,
        pub st_mode: u32,
        pub st_uid: u32,
        pub st_gid: u32,
        @import("__pad0")
        pad0: i32,
        pub st_rdev: u64,
        pub st_size: i64,
        pub st_blksize: i64,
        pub st_blocks: i64,
        pub st_atim: timespec,
        pub st_mtim: timespec,
        pub st_ctim: timespec,
        @import("__glibc_reserved")
        reserved: [i64; 3],
    }
    @platform(linux)
    @arch(aarch64)
    struct stat {
        pub st_dev: u64,
        pub st_ino: u64,
        pub st_mode: u32,
        pub st_nlink: u32,
        pub st_uid: u32,
        pub st_gid: u32,
        pub st_rdev: u64,
        @import("__pad1")
        pad1: u64,
        pub st_size: i64,
        pub st_blksize: i32,
        @import("__pad2")
        pad2: i32,
        pub st_blocks: i64,
        pub st_atim: timespec,
        pub st_mtim: timespec,
        pub st_ctim: timespec,
        @import("__glibc_reserved")
        reserved: [i32; 2],
    }
    @platform(windows)
    struct stat {
        pub st_dev: u32,
        pub st_ino: u16,
        pub st_mode: u16,
        pub st_nlink: i16,
        pub st_uid: i16,
        pub st_gid: i16,
        pub st_rdev: u32,
        pub st_size: i32,
        pub st_atime: i64,
        pub st_mtime: i64,
        pub st_ctime: i64,
    }
    @platform(wasm)
    struct stat {
        pub st_dev: u64,
        pub st_ino: u64,
        pub st_nlink: u64,
        pub st_mode: u32,
        pub st_uid: u32,
        pub st_gid: u32,
        @import("__pad0")
        pad0: u32,
        pub st_rdev: u64,
        pub st_size: i64,
        pub st_blksize: i32,
        pub st_blocks: i64,
        pub st_atim: timespec,
        pub st_mtim: timespec,
        pub st_ctim: timespec,
        @import("__reserved")
        reserved: [i64; 3],
    }
    fn stat(path: *const char, buf: *mut stat) i32;
}
)";

// `stat` of a file the test writes: `struct stat` differs per target, and its computed layout is the
// C library's.
@test
fn header_type_reads_stat_of_a_file() {
    let p = cli::proj_new();
    p.mkfile("data.bin", "hello");
    let mut path = String::new();
    let root = p.dir();
    for i in 0..root.len() {
        let c = root.byte_at(i);
        path.push_byte(
            if c == b'\\' {
                b'/';
            } else {
                c;
            },
        );
    }
    let mut src = String::from_str(STAT);
    src.push_str("\nfn main() i32 {\n    let mut s = unsafe zeroed::<stat>();\n    if unsafe stat(\"");
    src.push_string(&path);
    src.push_str(
        "/data.bin\".ptr() as *const char, &mut s) != 0 {\n        return 1;\n    }\n    let mode: u32 = s.st_mode;\n    if (mode & 0o170000) != 0o100000 {\n        return 2;\n    }\n    if s.st_size != 5 {\n        return 3;\n    }\n    return 0;\n}\n",
    );
    p.mkfile("main.spc", src.as_str());
    let r = p.compile("main.spc");
    if !r.ok() {
        eprintln("{}", r.text());
    }
    assert(r.ok(), "the program compiles");
    assert(p.xhdr_has("_Static_assert(sizeof(struct stat) == "), "the platform's layout is checked");
    let cc = p.cc_build("");
    if !cc.ok() {
        eprintln("{}", cc.text());
    }
    assert(cc.ok(), "the emitted C compiles under the strict warning set");
    assert_eq(p.run_bin(), 0);
}

// A header of the project with every field kind, a typedef'd anonymous struct and union, an opaque
// type with a `@layout`, a packed and an aligned struct, and a self pointer: C fills the record,
// Super-C reads it, under the strict warning set.
@test
fn header_type_local_header_round_trip() {
    let p = cli::proj_new();
    p.mkfile(
        "lib.h",
        "#ifndef LIB_H\n#define LIB_H\n#include <stdbool.h>\ntypedef struct { int id; } lib_anon;\ntypedef union { int i; float f; } lib_u;\ntypedef struct { char bytes[20]; long long al; } lib_blob;\nstruct __attribute__((packed)) lib_pk { char tag; int v; };\nstruct __attribute__((aligned(16))) lib_al { int v; };\nstruct lib_rec {\n    bool flag;\n    char name[8];\n    unsigned short port;\n    long long big;\n    double ratio;\n    const char *label;\n    int (*cb)(int);\n    lib_anon anon;\n    lib_u u;\n    int hidden;\n    lib_blob blob;\n    struct lib_pk pk;\n    struct lib_al al;\n    struct lib_rec *next;\n};\nint lib_fill(struct lib_rec *r);\n#endif\n",
    );
    p.mkfile(
        "lib.c",
        "#include \"lib.h\"\n#include <string.h>\nint lib_fill(struct lib_rec *r) {\n    r->flag = true;\n    strcpy(r->name, \"hi\");\n    r->port = 8080;\n    r->big = -5000000000LL;\n    r->ratio = 0.25;\n    r->label = \"lbl\";\n    r->anon.id = 42;\n    r->u.i = 7;\n    r->hidden = 99;\n    r->blob.al = 11;\n    r->pk.tag = 'k';\n    r->pk.v = 0x01020304;\n    r->al.v = 5;\n    r->next = r;\n    return r->hidden + r->cb(0);\n}\n",
    );
    p.mkfile(
        "main.spc",
        "extern \"C\" \"lib.h\" {\n    @import(\"lib_anon\")\n    struct lib_anon { pub id: i32 }\n    @import(\"lib_u\")\n    union lib_u { pub i: i32, pub f: f32 }\n    @import(\"lib_blob\")\n    @layout(32, 8)\n    type lib_blob;\n    @packed\n    struct lib_pk { pub tag: char, pub v: i32 }\n    @align(16)\n    struct lib_al { pub v: i32 }\n    struct lib_rec {\n        pub flag: bool,\n        pub name: [char; 8],\n        pub port: u16,\n        pub big: i64,\n        pub ratio: f64,\n        pub label: *const char,\n        pub cb: fn(i32) i32,\n        pub anon: lib_anon,\n        pub u: lib_u,\n        pub hidden: i32,\n        pub blob: lib_blob,\n        pub pk: lib_pk,\n        pub al: lib_al,\n        pub next: *mut lib_rec,\n    }\n    fn lib_fill(r: *mut lib_rec) i32;\n}\n\nfn twice(x: i32) i32 {\n    return x * 2;\n}\n\nfn main() i32 {\n    let mut r = unsafe zeroed::<lib_rec>();\n    r.cb = twice;\n    let n = unsafe lib_fill(&mut r);\n    let me = &mut r as *mut lib_rec;\n    if !r.flag || r.name[0] as u8 != b'h' || r.name[2] as u8 != 0 {\n        return 1;\n    }\n    if r.port != 8080 || r.big != -5000000000 || r.ratio != 0.25 {\n        return 2;\n    }\n    if r.anon.id != 42 || unsafe r.u.i != 7 || r.next != me || n != 99 || r.hidden != 99 {\n        return 3;\n    }\n    if (r.cb)(21) != 42 || (unsafe *r.label) as u8 != b'l' {\n        return 4;\n    }\n    if r.pk.tag as u8 != b'k' || r.pk.v != 0x01020304 || r.al.v != 5 || alignof(lib_al) != 16 {\n        return 5;\n    }\n    return 0;\n}\n",
    );
    let r = p.compile("main.spc");
    if !r.ok() {
        eprintln("{}", r.text());
    }
    assert(r.ok(), "the program compiles");
    assert(p.xhdr_has("_Generic(((lib_u *)0)->f, float: 1, default: 0)"), "a typedef'd union");
    assert(
        p.xhdr_has("_Generic(((struct lib_rec *)0)->anon, __sc_x_lib_anon: 1, default: 0)"),
        "a typedef'd anonymous struct member",
    );
    assert(p.xhdr_has("_Static_assert(sizeof(lib_blob) == 32u && _Alignof(lib_blob) == 8u,"), "a layout");
    let cc = p.cc_build("");
    if !cc.ok() {
        eprintln("{}", cc.text());
    }
    assert(cc.ok(), "the emitted C compiles under the strict warning set");
    assert_eq(p.run_bin(), 0);
}

// The formatter keeps a header type's declaration: attributes, field lists, unions, layouts and
// constants with values.
@test
fn header_type_formats_canonically() {
    let src = "extern \"C\"   \"sys/stat.h\" {\n  @platform(linux)\n    pub struct stat { pub st_mode : u32 ,pub st_size: i64 }\n    @import(\"div_t\") struct div_t{ pub quot:i32, pub rem:i32 }\n    union sigval{pub sival_int:i32}\n  @layout( 8,8 ) type h;\n    pub const S_IFMT:u32=0o170000 ;\n}\n";
    let want = "extern \"C\" \"sys/stat.h\" {\n    @platform(linux)\n    pub struct stat {\n        pub st_mode: u32,\n        pub st_size: i64,\n    }\n    @import(\"div_t\")\n    struct div_t {\n        pub quot: i32,\n        pub rem: i32,\n    }\n    union sigval {\n        pub sival_int: i32,\n    }\n    @layout(8, 8)\n    type h;\n    pub const S_IFMT: u32 = 0o170000;\n}\n";
    let pa = h::parse_ast_for_fmt(src);
    assert(pa.errors == 0, "the input parses");
    let mut out = String::new();
    fbld::format_program(&pa.ast, src, 120, &mut out);
    if out.as_str() != want {
        eprintln("{}", out.as_str());
    }
    assert(out.as_str() == want, "the declaration formats canonically");
    let pb = h::parse_ast_for_fmt(want);
    assert(pb.errors == 0, "the canonical form parses");
    let mut again = String::new();
    fbld::format_program(&pb.ast, want, 120, &mut again);
    assert(again.as_str() == want, "the canonical form is a fixed point");
}

// A typed pointer passed where an extern function declares `*mut void` is cast to `void *` in the C call:
// the header may declare another pointee (Winsock's `char *` option values), which C does not convert to.
@test
fn extern_void_pointer_argument_spells_the_conversion() {
    let src = "extern \"C\" \"string.h\" {\n    fn memset(p: *mut void, c: i32, n: usize) *mut void;\n}\nfn main() i32 {\n    let mut x: i32 = 7;\n    let v: *mut void = &mut x;\n    unsafe memset(&mut x, 0, 4);\n    unsafe memset(v, 0, 4);\n    return x;\n}\n";
    let c = h::compile_c(src);
    assert(c.ok(), "the program compiles");
    assert(c.code_has("memset((void *)(&x)"), "a typed pointer converts to void *");
    assert(c.code_has("memset(v, 0, 4ULL)"), "a void pointer passes as it is");
}

// A header's macros reach only the units that use one of its items: `<windows.h>` defines `near` and
// `far` empty, which would break every other unit's identifiers of those names. The binding unit spells
// the header's function by its alias; a parameter of the same name elsewhere brings no header. The
// binding unit compiles outside the unity build, whose later members would see the macros too.
@test
fn header_macros_stay_in_the_units_that_use_the_header() {
    let p = cli::proj_new();
    p.mkfile("lib.h", "#ifndef LIB_H\n#define LIB_H\n#define near\n#define far\nint twice(int x);\n#endif\n");
    p.mkfile("lib.c", "#include \"lib.h\"\nint twice(int x) { return 2 * x; }\n");
    p.mkfile(
        "bind.spc",
        "extern \"C\" \"lib.h\" {\n    fn twice(x: i32) i32;\n}\n\npub fn doubled(x: i32) i32 {\n    return unsafe twice(x);\n}\n",
    );
    p.mkfile("other.spc", "pub fn gap(near: i32, far: i32, twice: i32) i32 {\n    return far - near + twice;\n}\n");
    p.mkfile(
        "main.spc",
        "import bind;\nimport other;\n\nfn span(near: i32, far: i32) i32 {\n    return far - near;\n}\n\nfn main() i32 {\n    return span(1, bind::doubled(2)) + other::gap(1, 1, 0) - 3;\n}\n",
    );
    let r = p.compile("main.spc");
    if !r.ok() {
        eprintln("{}", r.text());
    }
    assert(r.ok(), "the program compiles");
    assert(p.xhdr_has("lib.h\""), "the header has its own generated file");
    assert(!p.gen_has("__sc_fwd.h", "lib.h"), "the forward header does not include it");
    assert(p.gen_has("bind.c", "__sc_x_twice(x)"), "the binding unit calls the function by its alias");
    assert(p.gen_has("bind.c", "__sc_t/__scx"), "the binding unit includes the header");
    assert(!p.gen_has("other.c", "__sc_t/__scx"), "a parameter named like the function brings no header");
    assert(!p.gen_has("main.c", "__sc_t/__scx"), "the other unit includes no header");
    // The build's own C compile: the units of a small program compile as one, but the binding's.
    p.mkfile("build.toml", "bin = \"bin\"\nroot = \"main.spc\"\n");
    let b = cli::superc_in(p.dir(), "build -o bin");
    if !b.ok() {
        eprintln("{}", b.text());
    }
    assert(b.ok(), "the build compiles and links");
    assert(p.gen_has("__sc_unity.c", "main.c"), "the other units are in the unity build");
    assert(!p.gen_has("__sc_unity.c", "bind.c"), "the binding unit compiles alone");
    assert_eq(p.run_bin(), 0);
}

// A module's header order holds in every file, also when an earlier module declares the later
// header first: `<ws2tcpip.h>` must come before `<windows.h>`, which `a.h` and `b.h` model.
@test
fn header_order_of_a_module_holds_across_modules() {
    let p = cli::proj_new();
    p.mkfile("a.h", "#ifndef A_H\n#define A_H\n#ifdef B_H\n#error a.h after b.h\n#endif\nint a_one(void);\n#endif\n");
    p.mkfile("b.h", "#ifndef B_H\n#define B_H\nint b_two(void);\nint b_three(void);\n#endif\n");
    p.mkfile("a.c", "#include \"a.h\"\nint a_one(void) { return 1; }\n");
    p.mkfile("b.c", "#include \"b.h\"\nint b_two(void) { return 2; }\nint b_three(void) { return 3; }\n");
    p.mkfile(
        "early.spc",
        "extern \"C\" \"b.h\" {\n    fn b_two() i32;\n}\n\npub fn two() i32 {\n    return unsafe b_two();\n}\n",
    );
    p.mkfile(
        "net.spc",
        "extern \"C\" \"a.h\" {\n    fn a_one() i32;\n}\n\nextern \"C\" \"b.h\" {\n    fn b_three() i32;\n}\n\npub fn both() i32 {\n    return unsafe a_one() + unsafe b_three();\n}\n",
    );
    p.mkfile(
        "main.spc",
        "import early;\nimport net;\n\nfn main() i32 {\n    return early::two() + net::both() - 6;\n}\n",
    );
    p.mkfile("build.toml", "bin = \"bin\"\nroot = \"main.spc\"\n");
    let b = cli::superc_in(p.dir(), "build -o bin");
    if !b.ok() {
        eprintln("{}", b.text());
    }
    assert(b.ok(), "the build compiles and links");
    assert_eq(p.run_bin(), 0);
}
