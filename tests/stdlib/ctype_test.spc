// The <ctype.h> functions of `ffi/ctype.spc`, in Super-C, against the platform's own in the "C" locale
// over every byte and EOF. wasm's C library is std's own: it has no oracle.

import ctype;

@platform(!wasm)
extern "C" {
    @import("isalpha")
    fn c_isalpha(c: i32) i32;
    @import("isdigit")
    fn c_isdigit(c: i32) i32;
    @import("isalnum")
    fn c_isalnum(c: i32) i32;
    @import("isspace")
    fn c_isspace(c: i32) i32;
    @import("isupper")
    fn c_isupper(c: i32) i32;
    @import("islower")
    fn c_islower(c: i32) i32;
    @import("ispunct")
    fn c_ispunct(c: i32) i32;
    @import("iscntrl")
    fn c_iscntrl(c: i32) i32;
    @import("isprint")
    fn c_isprint(c: i32) i32;
    @import("isgraph")
    fn c_isgraph(c: i32) i32;
    @import("isblank")
    fn c_isblank(c: i32) i32;
    @import("isxdigit")
    fn c_isxdigit(c: i32) i32;
    @import("toupper")
    fn c_toupper(c: i32) i32;
    @import("tolower")
    fn c_tolower(c: i32) i32;
}

@platform(!wasm)
@test
fn ctype_matches_the_c_locale() {
    for c in -1..256 {
        assert_eq(ctype::isalpha(c) != 0, unsafe c_isalpha(c) != 0);
        assert_eq(ctype::isdigit(c) != 0, unsafe c_isdigit(c) != 0);
        assert_eq(ctype::isalnum(c) != 0, unsafe c_isalnum(c) != 0);
        assert_eq(ctype::isspace(c) != 0, unsafe c_isspace(c) != 0);
        assert_eq(ctype::isupper(c) != 0, unsafe c_isupper(c) != 0);
        assert_eq(ctype::islower(c) != 0, unsafe c_islower(c) != 0);
        assert_eq(ctype::ispunct(c) != 0, unsafe c_ispunct(c) != 0);
        assert_eq(ctype::iscntrl(c) != 0, unsafe c_iscntrl(c) != 0);
        assert_eq(ctype::isprint(c) != 0, unsafe c_isprint(c) != 0);
        assert_eq(ctype::isgraph(c) != 0, unsafe c_isgraph(c) != 0);
        assert_eq(ctype::isblank(c) != 0, unsafe c_isblank(c) != 0);
        assert_eq(ctype::isxdigit(c) != 0, unsafe c_isxdigit(c) != 0);
        assert_eq(ctype::toupper(c), unsafe c_toupper(c));
        assert_eq(ctype::tolower(c), unsafe c_tolower(c));
    }
}
