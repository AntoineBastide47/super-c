// Header types: a `struct` or `union` of an `extern "C"` block is the C header's type. The declaration
// lists some of its fields; the emitted C names them on the real C type and checks each one against the
// header with `_Static_assert`, and every size Super-C needs comes from the C compiler.
import fmt::builder as fbld;
import tests::harness as h;
import tests::cli_harness as cli;

const TM: str = "extern \"C\" \"time.h\" {\n    struct tm { pub tm_sec: i32, pub tm_min: i32, pub tm_hour: i32, pub tm_mday: i32 }\n    fn strftime(dst: *mut char, max: usize, fmt: *const char, t: *const tm) usize;\n}\n";

// The emitted C: the header's own type by its tag, member access by name, the header's include, and one
// check per declared field (size and signedness), with the order check between fields. No layout of its
// own: no whole-type size claim.
@test
fn header_type_emits_field_checks() {
    let src = "extern \"C\" \"time.h\" {\n    struct tm { pub tm_sec: i32, pub tm_min: i32 }\n}\nextern \"C\" \"stdlib.h\" {\n    @c.import(\"div_t\")\n    struct div_t { pub rem: i32 }\n    fn div(n: i32, d: i32) div_t;\n}\nfn main() i32 {\n    let mut t = tm { tm_sec: 3 };\n    t.tm_min = 4;\n    let d = unsafe div(7, 2);\n    return t.tm_sec + t.tm_min + d.rem - 8;\n}\n";
    let c = h::compile_c(src);
    assert(c.ok(), "the program compiles");
    assert(c.code_has("#include <time.h>"), "the header is included");
    assert(c.code_has("struct tm t = (struct tm){ .tm_sec = 3"), "a literal names the header's type by its tag");
    assert(c.code_has("t.tm_min = 4"), "a field is the C member by name");
    assert(c.code_has("div_t d = div("), "a typedef'd type is its typedef name");
    assert(
        c.code_has("_Static_assert(sizeof(struct tm) != 0, \"super-c: 'tm' must be a complete C type\");"),
        "the type is checked complete",
    );
    assert(
        c.code_has(
            "_Static_assert(sizeof(((struct tm *)0)->tm_sec) == 4 && _Generic(((struct tm *)0)->tm_sec, signed char: 1, short: 1, int: 1, long: 1, long long: 1, default: 0), \"super-c: field 'tm.tm_sec' must be a signed integer of 4 bytes in C\");",
        ),
        "a field's size and signedness are checked",
    );
    assert(
        c.code_has(
            "_Static_assert(offsetof(struct tm, tm_sec) + sizeof(((struct tm *)0)->tm_sec) <= offsetof(struct tm, tm_min), \"super-c: field 'tm.tm_min' must follow 'tm.tm_sec' in C without overlap: list the fields in the header's order\");",
        ),
        "the field order is checked",
    );
    assert(
        c.code_has("_Static_assert(sizeof(((div_t *)0)->rem) == 4 && _Generic(((div_t *)0)->rem"),
        "a typedef'd type's field is checked",
    );
    assert(!c.code_has("_Static_assert(sizeof(struct tm) =="), "no whole-type size claim");
    assert(!c.code_has("super-c layout model mismatch: struct tm"), "no layout model check");
}

// Every field type category spells its own check.
@test
fn header_type_check_per_field_kind() {
    let src = "extern \"C\" \"time.h\" {\n    struct tm { pub tm_sec: i32 }\n}\nextern \"C\" \"lib.h\" {\n    struct rec {\n        pub flag: bool,\n        pub c: char,\n        pub n: u16,\n        pub w: usize,\n        pub f: f32,\n        pub d: f64,\n        pub p: *const char,\n        pub cb: fn(i32) i32,\n        pub name: [[u8; 4]; 2],\n        pub t: tm,\n    }\n    union u { pub i: i32, pub f: f32 }\n}\nfn main() i32 {\n    let r = unsafe zeroed::<rec>();\n    let v = unsafe zeroed::<u>();\n    return r.n as i32 + unsafe v.i;\n}\n";
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
            "_Generic(((struct rec *)0)->t, struct tm: 1, default: 0), \"super-c: field 'rec.t' must be a 'struct tm' in C\"",
        ),
        "a header struct field",
    );
    assert(
        c.code_has(
            "_Static_assert(offsetof(union u, i) == 0, \"super-c: field 'u.i' must be a member of the C union\");",
        ),
        "a union member",
    );
    assert(c.code_has("_Static_assert(offsetof(union u, f) == 0,"), "every union member");
}

fn header_type_values_through_c(b: &mut h::ExitBatch) {
    let mut src = String::from_str(TM);
    src.push_str(
        "fn main() i32 {\n    let t = tm { tm_hour: 5, tm_min: 7, tm_sec: 9, tm_mday: 1 };\n    let mut buf: [char; 16] = [0 as char; 16];\n    let n = unsafe strftime(&mut buf[0], 16, \"%H:%M:%S\".ptr() as *const char, &t);\n    if n != 8 { return 1; }\n    if buf[1] as u8 != b'5' || buf[4] as u8 != b'7' || buf[7] as u8 != b'9' { return 2; }\n    return 0;\n}\n",
    );
    b.add("header struct fields reach the C members by name", src.as_str(), 0);
    b.add(
        "a field pinned to its C member",
        "extern \"C\" \"time.h\" {\n    struct tm {\n        pub tm_sec: i32,\n        @c.import(\"tm_min\")\n        pub minute: i32,\n    }\n}\nfn main() i32 {\n    let t = tm { tm_sec: 1, minute: 2 };\n    let mut u = t;\n    u.minute = u.minute + t.tm_sec;\n    return u.minute - 3;\n}\n",
        0,
    );
    b.add(
        "a partial typedef'd header struct returned by value",
        "extern \"C\" \"stdlib.h\" {\n    @c.import(\"div_t\")\n    struct div_t { pub rem: i32 }\n    fn div(n: i32, d: i32) div_t;\n}\nfn main() i32 {\n    let d = unsafe div(17, 5);\n    if d.rem != 2 { return 1; }\n    if sizeof(div_t) != 8 { return 2; }\n    return 0;\n}\n",
        0,
    );
}

fn header_type_sizes_from_c(b: &mut h::ExitBatch) {
    b.add(
        "a header struct that lists no field keeps the C type's storage",
        "extern \"C\" \"stdlib.h\" {\n    @c.import(\"div_t\")\n    struct div_t {}\n    fn div(n: i32, d: i32) div_t;\n}\nfn main() i32 {\n    let d = unsafe div(7, 2);\n    let two: [div_t; 2] = [d, d];\n    if sizeof(div_t) != 8 || sizeof([div_t; 2]) != 16 { return 1; }\n    return (sizeof(two) != 16) as i32;\n}\n",
        0,
    );
    b.add(
        "sizeof and alignof of a partial header struct are the C type's",
        "extern \"C\" \"time.h\" {\n    struct tm { pub tm_sec: i32 }\n}\nstruct W { pub t: tm, pub k: u8 }\nfn main() i32 {\n    if sizeof(tm) < 36 { return 1; }\n    if alignof(tm) < 4 || sizeof(tm) % alignof(tm) != 0 { return 2; }\n    if sizeof([tm; 3]) != 3 * sizeof(tm) { return 3; }\n    if sizeof(W) <= sizeof(tm) { return 4; }\n    return 0;\n}\n",
        0,
    );
}

fn header_type_value_uses(b: &mut h::ExitBatch) {
    b.add(
        "copies, arrays, slices, vectors, options, generics and holders of a header struct",
        "extern \"C\" \"time.h\" {\n    struct tm { pub tm_sec: i32, pub tm_min: i32 }\n}\nfn id<T>(x: T) T { return x; }\nstruct W { pub t: tm, pub k: i32 }\nfn main() i32 {\n    let a = tm { tm_min: 7 };\n    let mut b = a;\n    b.tm_min = 8;\n    if a.tm_min != 7 || a.tm_sec != 0 { return 1; }\n    let arr: [tm; 3] = [a, b, id(a)];\n    let s: []tm = arr;\n    if s[1].tm_min != 8 || s.len() != 3 { return 2; }\n    let mut v = Vector::<tm>::new();\n    for i in 0..s.len() { v.push(s[i]); }\n    if v.len() != 3 || v.at(2).tm_min != 7 { return 3; }\n    let o = Option::<tm>::Some(b);\n    let m = switch o { Some(x) => x.tm_min, None => 0 };\n    if m != 8 { return 4; }\n    let w = W { t: b, k: 4 };\n    if w.t.tm_min + w.k != 12 { return 5; }\n    let z = unsafe zeroed::<tm>();\n    if z.tm_sec != 0 || z.tm_min != 0 { return 6; }\n    let hz = W { k: 1 };\n    if hz.t.tm_min != 0 { return 7; }\n    return 0;\n}\n",
        0,
    );
}

fn header_type_compile_time_values(b: &mut h::ExitBatch) {
    b.add(
        "constants and statics of a header struct hold its declared fields",
        "extern \"C\" \"time.h\" {\n    struct tm { pub tm_sec: i32, pub tm_min: i32 }\n}\nconst fn mk(n: i32) tm {\n    let mut t = tm { tm_sec: n };\n    t.tm_min = t.tm_sec + 1;\n    return t;\n}\nconst K: tm = mk(3);\nconst S: i32 = mk(5).tm_min;\nstatic mut G: tm = tm { tm_min: 9 };\nfn main() i32 {\n    let k = K;\n    let g = unsafe G;\n    if k.tm_sec != 3 || k.tm_min != 4 || S != 6 { return 1; }\n    if g.tm_min != 9 || g.tm_sec != 0 { return 2; }\n    return 0;\n}\n",
        0,
    );
}

@test
fn exit_cases_00() {
    let mut b = h::ExitBatch::new();
    header_type_values_through_c(&mut b);
    header_type_sizes_from_c(&mut b);
    header_type_value_uses(&mut b);
    header_type_compile_time_values(&mut b);
    b.run();
}

// A use that needs the layout at compile time is an error that names the header type: the C compiler
// alone knows it.
@test
fn header_type_rejects_compile_time_layout() {
    let d = "extern \"C\" \"time.h\" {\n    struct tm { pub tm_sec: i32 }\n}\n";
    let mut s = String::from_str(d);
    s.push_str("const N: usize = sizeof(tm);\nfn main() i32 { return N as i32; }\n");
    h::expect_err_msg("const sizeof", s.as_str(), "the size of 'tm' is its C header's: it has no compile-time value");
    s = String::from_str(d);
    s.push_str("const A: usize = alignof([tm; 2]);\nfn main() i32 { return A as i32; }\n");
    h::expect_err_msg("const alignof", s.as_str(), "the alignment of 'tm' is its C header's");
    s = String::from_str(d);
    s.push_str("struct W { pub t: tm }\nstatic_assert(sizeof(W) > 0, \"sized\");\nfn main() i32 { return 0; }\n");
    h::expect_err_msg("static_assert through a holder", s.as_str(), "the size of 'tm' is its C header's");
    s = String::from_str(d);
    s.push_str("fn main() i32 {\n    let b = [0u8; sizeof(tm)];\n    return b[0] as i32;\n}\n");
    h::expect_err_msg("repeat count", s.as_str(), "an array repeat count cannot be evaluated: the size of 'tm'");
    s = String::from_str(d);
    s.push_str(
        "fn main() i32 {\n    let b: [u8; sizeof(tm)] = unsafe zeroed::<[u8; sizeof(tm)]>();\n    return b[0] as i32;\n}\n",
    );
    h::expect_err_msg("array length", s.as_str(), "array length cannot be evaluated: the size of 'tm'");
    s = String::from_str(d);
    s.push_str("const Z: usize = type_info::<tm>().size;\nfn main() i32 { return Z as i32; }\n");
    h::expect_err_msg("reflection", s.as_str(), "the layout of 'tm' is its C header's");
}

// Declaration errors: a field type with no C equivalent, a duplicate field, an unknown field at a use, a
// destructor, and a layout attribute.
@test
fn header_type_declaration_errors() {
    h::expect_err_msg(
        "owning field",
        "extern \"C\" \"time.h\" {\n    struct tm { pub tm_sec: String }\n}\nfn main() i32 { return 0; }\n",
        "field 'tm_sec' of 'tm' has type 'String<Global>', which has no C equivalent",
    );
    h::expect_err_msg(
        "reference field",
        "extern \"C\" \"time.h\" {\n    struct tm { pub tm_sec: &i32 }\n}\nfn main() i32 { return 0; }\n",
        "field 'tm_sec' of 'tm' has type '&i32', which has no C equivalent",
    );
    h::expect_err_msg(
        "super-c struct field",
        "struct P { pub x: i32 }\nextern \"C\" \"time.h\" {\n    struct tm { pub tm_sec: P }\n}\nfn main() i32 { return 0; }\n",
        "field 'tm_sec' of 'tm' has type 'P', which has no C equivalent",
    );
    h::expect_err_msg(
        "slice field",
        "extern \"C\" \"time.h\" {\n    struct tm { pub tm_sec: []u8 }\n}\nfn main() i32 { return 0; }\n",
        "which has no C equivalent",
    );
    h::expect_err_msg(
        "member pin outside an extern block",
        "struct P {\n    @c.import(\"x\")\n    pub y: i32,\n}\nfn main() i32 { return 0; }\n",
        "only '@reflect' applies to a field declaration, and '@c.import' to a field of an 'extern \"C\"' struct or union",
    );
    h::expect_err_msg(
        "duplicate field",
        "extern \"C\" \"time.h\" {\n    struct tm { pub tm_sec: i32, pub tm_sec: i32 }\n}\nfn main() i32 { return 0; }\n",
        "duplicate definition of 'tm_sec'",
    );
    h::expect_err_msg(
        "unknown field read",
        "extern \"C\" \"time.h\" {\n    struct tm { pub tm_sec: i32 }\n}\nfn main() i32 {\n    let t = unsafe zeroed::<tm>();\n    return t.tm_year;\n}\n",
        "no field or method 'tm_year' on 'tm'",
    );
    h::expect_err_msg(
        "unknown field in a literal",
        "extern \"C\" \"time.h\" {\n    struct tm { pub tm_sec: i32 }\n}\nfn main() i32 {\n    let t = tm { tm_year: 1 };\n    return t.tm_sec;\n}\n",
        "no field 'tm_year' on 'tm'",
    );
    h::expect_err_msg(
        "destructor",
        "extern \"C\" \"time.h\" {\n    struct tm { pub tm_sec: i32 }\n}\nextend tm as Free {\n    fn free(self: &mut tm) {}\n}\nfn main() i32 { return 0; }\n",
        "'tm' is a type of an 'extern \"C\"' block: it cannot implement 'Free'",
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
        "alignment attribute",
        "extern \"C\" \"time.h\" {\n    @c.align(16)\n    struct tm { pub tm_sec: i32 }\n}\nfn main() i32 { return 0; }\n",
        "'@c.align' may only be applied to a struct, a union or a 'static mut' outside an 'extern \"C\"' block",
    );
    h::expect_err_msg(
        "packed attribute",
        "extern \"C\" \"time.h\" {\n    @c.packed\n    struct tm { pub tm_sec: i32 }\n}\nfn main() i32 { return 0; }\n",
        "'@c.packed' may only be applied to a struct or a union outside an 'extern \"C\"' block",
    );
}

// A wrong declaration fails the C compile with the check's message, on every target: a pointer for an
// int, a size, a float for an integer, and two fields out of the header's order.
@test
fn header_type_wrong_declaration_fails_the_c_compile() {
    let src = "extern \"C\" \"time.h\" {\n    struct tm { pub tm_sec: *mut void }\n}\nextern \"C\" \"stdlib.h\" {\n    @c.import(\"div_t\")\n    struct div_t { pub rem: i32, pub quot: i32 }\n    @c.import(\"ldiv_t\")\n    struct ldiv_t { pub rem: u8 }\n    @c.import(\"lldiv_t\")\n    struct lldiv_t { pub quot: f64 }\n}\nfn main() i32 {\n    let t = unsafe zeroed::<tm>();\n    let d = unsafe zeroed::<div_t>();\n    let l = unsafe zeroed::<ldiv_t>();\n    let q = unsafe zeroed::<lldiv_t>();\n    return d.rem + l.rem as i32 + q.quot as i32 + (t.tm_sec == null) as i32;\n}\n";
    let b = h::diff_build(src, []);
    let d = b.diag.as_str();
    if b.built || !d.contains("super-c: field 'tm.tm_sec' must be a pointer in C") {
        eprintln("{}", d);
    }
    assert(!b.built, "the C compile fails");
    assert(d.contains("super-c: field 'tm.tm_sec' must be a pointer in C"), "a pointer for an int");
    assert(d.contains("super-c: field 'div_t.quot' must follow 'div_t.rem' in C without overlap"), "the order");
    assert(d.contains("super-c: field 'ldiv_t.rem' must be an unsigned integer of 1 byte in C"), "a size");
    assert(d.contains("super-c: field 'lldiv_t.quot' must be double in C"), "a float for an integer");
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
        "extern \"C\" \"stdio.h\" {\n    @c.import(\"int\")\n    enum mode { A, B }\n}\nextend mode as Free {\n    fn free(self: &mut mode) {}\n}\nfn main() i32 { return 0; }\n",
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
        "extern \"C\" \"lib.h\" {\n    enum color { RED, GREEN = 5, BLUE }\n    @c.import(\"size_kind\")\n    enum size_kind { SMALL, LARGE }\n    struct pen { pub c: color, pub k: size_kind, pub w: i32 }\n    fn pen_code(p: pen, c: color, k: size_kind) i32;\n}\n\nfn main() i32 {\n    let p = pen { c: color::BLUE, k: size_kind::LARGE, w: 1 };\n    let n = unsafe pen_code(p, color::GREEN, size_kind::SMALL);\n    return n - 616;\n}\n",
    );
    let r = p.compile("main.spc");
    if !r.ok() {
        eprintln("{}", r.text());
    }
    assert(r.ok(), "the program compiles");
    assert(
        p.gen_has(
            "__sc_fwd.h",
            "_Static_assert(sizeof(enum color) != 0, \"super-c: 'color' must be a complete C type\");",
        ),
        "an enum is its C tag",
    );
    assert(p.gen_has("__sc_fwd.h", "_Static_assert(sizeof(size_kind) != 0,"), "a typedef'd enum is its typedef");
    assert(
        p.gen_has("__sc_fwd.h", "_Generic(((struct pen *)0)->c, enum color: 1, default: 0)"),
        "an enum member is checked by its tag",
    );
    assert(
        p.gen_has("__sc_fwd.h", "_Generic(((struct pen *)0)->k, size_kind: 1, default: 0)"),
        "a typedef'd enum member is checked by its typedef",
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

// `stat` of a file the test writes: the header owns `struct stat`, whose members differ per platform.
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
    let mut src = String::from_str(
        "extern \"C\" \"sys/stat.h\" {\n    @platform(macos | ios)\n    struct stat { pub st_mode: u16, pub st_size: i64 }\n    @platform(windows)\n    struct stat { pub st_mode: u16, pub st_size: i32 }\n    @platform(linux | android | wasm)\n    struct stat { pub st_mode: u32, pub st_size: i64 }\n    fn stat(path: *const char, buf: *mut stat) i32;\n}\n\nfn main() i32 {\n    let mut s = unsafe zeroed::<stat>();\n    if unsafe stat(\"",
    );
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
    assert(
        p.gen_has("__sc_fwd.h", "\"super-c: field 'stat.st_size' must be a signed integer of"),
        "the platform's declaration is checked",
    );
    let cc = p.cc_build("");
    if !cc.ok() {
        eprintln("{}", cc.text());
    }
    assert(cc.ok(), "the emitted C compiles under the strict warning set");
    assert_eq(p.run_bin(), 0);
}

// A header of the project with every field kind, a typedef'd anonymous struct and union, a member the
// declaration leaves out, and a self pointer: C fills the record, Super-C reads it, under the strict
// warning set.
@test
fn header_type_local_header_round_trip() {
    let p = cli::proj_new();
    p.mkfile(
        "lib.h",
        "#ifndef LIB_H\n#define LIB_H\n#include <stdbool.h>\ntypedef struct { int id; } lib_anon;\ntypedef union { int i; float f; } lib_u;\nstruct lib_rec {\n    bool flag;\n    char name[8];\n    unsigned short port;\n    long long big;\n    double ratio;\n    const char *label;\n    int (*cb)(int);\n    lib_anon anon;\n    lib_u u;\n    int hidden;\n    struct lib_rec *next;\n};\nint lib_fill(struct lib_rec *r);\n#endif\n",
    );
    p.mkfile(
        "lib.c",
        "#include \"lib.h\"\n#include <string.h>\nint lib_fill(struct lib_rec *r) {\n    r->flag = true;\n    strcpy(r->name, \"hi\");\n    r->port = 8080;\n    r->big = -5000000000LL;\n    r->ratio = 0.25;\n    r->label = \"lbl\";\n    r->anon.id = 42;\n    r->u.i = 7;\n    r->hidden = 99;\n    r->next = r;\n    return r->hidden + r->cb(0);\n}\n",
    );
    p.mkfile(
        "main.spc",
        "extern \"C\" \"lib.h\" {\n    @c.import(\"lib_anon\")\n    struct lib_anon { pub id: i32 }\n    @c.import(\"lib_u\")\n    union lib_u { pub i: i32, pub f: f32 }\n    struct lib_rec {\n        pub flag: bool,\n        pub name: [char; 8],\n        pub port: u16,\n        pub big: i64,\n        pub ratio: f64,\n        pub label: *const char,\n        pub cb: fn(i32) i32,\n        pub anon: lib_anon,\n        pub u: lib_u,\n        pub next: *mut lib_rec,\n    }\n    fn lib_fill(r: *mut lib_rec) i32;\n}\n\nfn twice(x: i32) i32 {\n    return x * 2;\n}\n\nfn main() i32 {\n    let mut r = lib_rec { cb: twice };\n    let n = unsafe lib_fill(&mut r);\n    let me = &mut r as *mut lib_rec;\n    if !r.flag || r.name[0] as u8 != b'h' || r.name[2] as u8 != 0 {\n        return 1;\n    }\n    if r.port != 8080 || r.big != -5000000000 || r.ratio != 0.25 {\n        return 2;\n    }\n    if r.anon.id != 42 || unsafe r.u.i != 7 || r.next != me || n != 99 {\n        return 3;\n    }\n    if (r.cb)(21) != 42 || (unsafe *r.label) as u8 != b'l' {\n        return 4;\n    }\n    return 0;\n}\n",
    );
    let r = p.compile("main.spc");
    if !r.ok() {
        eprintln("{}", r.text());
    }
    assert(r.ok(), "the program compiles");
    assert(p.gen_has("__sc_fwd.h", "_Generic(((lib_u *)0)->f, float: 1, default: 0)"), "a typedef'd union");
    assert(
        p.gen_has("__sc_fwd.h", "_Generic(((struct lib_rec *)0)->anon, lib_anon: 1, default: 0)"),
        "a typedef'd anonymous struct member",
    );
    let cc = p.cc_build("");
    if !cc.ok() {
        eprintln("{}", cc.text());
    }
    assert(cc.ok(), "the emitted C compiles under the strict warning set");
    assert_eq(p.run_bin(), 0);
}

// The formatter keeps a header type's declaration: attributes, partial field lists and unions.
@test
fn header_type_formats_canonically() {
    let src = "extern \"C\"   \"sys/stat.h\" {\n  @platform(linux)\n    pub struct stat { pub st_mode : u32 ,pub st_size: i64 }\n    @c.import(\"div_t\") struct div_t{ pub rem:i32 }\n    union sigval{pub sival_int:i32}\n}\n";
    let want = "extern \"C\" \"sys/stat.h\" {\n    @platform(linux)\n    pub struct stat {\n        pub st_mode: u32,\n        pub st_size: i64,\n    }\n    @c.import(\"div_t\")\n    struct div_t {\n        pub rem: i32,\n    }\n    union sigval {\n        pub sival_int: i32,\n    }\n}\n";
    let pa = h::parse_ast_for_fmt(src);
    assert(pa.errors == 0, "the input parses");
    let mut out = String::new();
    fbld::format_program(&pa.ast, src, 120, &mut out);
    assert(out.as_str() == want, "the declaration formats canonically");
    let pb = h::parse_ast_for_fmt(want);
    assert(pb.errors == 0, "the canonical form parses");
    let mut again = String::new();
    fbld::format_program(&pb.ast, want, 120, &mut again);
    assert(again.as_str() == want, "the canonical form is a fixed point");
}
