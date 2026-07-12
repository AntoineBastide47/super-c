// FFI bindings for <ctype.h>. Character classification/conversion. The raw C functions take and return
// `int` (a byte value or EOF); the `pub` bindings mirror that, and a thin layer of `u8`/`bool` wrappers
// makes the common cases ergonomic. Import with `import ctype;`.

extern "C" {
    pub fn isalpha(c: i32) i32;
    pub fn isdigit(c: i32) i32;
    pub fn isalnum(c: i32) i32;
    pub fn isspace(c: i32) i32;
    pub fn isupper(c: i32) i32;
    pub fn islower(c: i32) i32;
    pub fn ispunct(c: i32) i32;
    pub fn iscntrl(c: i32) i32;
    pub fn isprint(c: i32) i32;
    pub fn isgraph(c: i32) i32;
    pub fn isblank(c: i32) i32;
    pub fn isxdigit(c: i32) i32;
    pub fn toupper(c: i32) i32;
    pub fn tolower(c: i32) i32;
}

// Ergonomic byte-oriented wrappers.
pub fn is_alpha(b: u8) bool {
    return unsafe isalpha(b as i32) != 0;
}
pub fn is_digit(b: u8) bool {
    return unsafe isdigit(b as i32) != 0;
}
pub fn is_alnum(b: u8) bool {
    return unsafe isalnum(b as i32) != 0;
}
pub fn is_space(b: u8) bool {
    return unsafe isspace(b as i32) != 0;
}
pub fn is_upper(b: u8) bool {
    return unsafe isupper(b as i32) != 0;
}
pub fn is_lower(b: u8) bool {
    return unsafe islower(b as i32) != 0;
}
pub fn is_xdigit(b: u8) bool {
    return unsafe isxdigit(b as i32) != 0;
}
pub fn to_upper(b: u8) u8 {
    return (unsafe toupper(b as i32)) as u8;
}
pub fn to_lower(b: u8) u8 {
    return (unsafe tolower(b as i32)) as u8;
}
