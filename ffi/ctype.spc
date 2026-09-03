// FFI bindings for <ctype.h>. Character classification/conversion. The raw C functions take and return
// `int` (a byte value or EOF); the `pub` bindings mirror that, and a thin layer of `u8`/`bool` wrappers
// makes the common cases ergonomic. Import with `import ctype;`. Calling the raw bindings requires
// `unsafe`; the wrappers below do not.

extern "C" {
    /// Nonzero for a letter. `c` must be an unsigned-char value or EOF (C ctype contract).
    pub fn isalpha(c: i32) i32;
    /// Nonzero for a decimal digit.
    pub fn isdigit(c: i32) i32;
    /// Nonzero for a letter or digit.
    pub fn isalnum(c: i32) i32;
    /// Nonzero for whitespace (space, \t, \n, \v, \f, \r).
    pub fn isspace(c: i32) i32;
    /// Nonzero for an uppercase letter.
    pub fn isupper(c: i32) i32;
    /// Nonzero for a lowercase letter.
    pub fn islower(c: i32) i32;
    /// Nonzero for printable punctuation.
    pub fn ispunct(c: i32) i32;
    /// Nonzero for a control character.
    pub fn iscntrl(c: i32) i32;
    /// Nonzero for a printable character, space included.
    pub fn isprint(c: i32) i32;
    /// Nonzero for a printable character other than space.
    pub fn isgraph(c: i32) i32;
    /// Nonzero for space or tab.
    pub fn isblank(c: i32) i32;
    /// Nonzero for a hexadecimal digit.
    pub fn isxdigit(c: i32) i32;
    /// The uppercase counterpart of a letter; other values unchanged.
    pub fn toupper(c: i32) i32;
    /// The lowercase counterpart of a letter; other values unchanged.
    pub fn tolower(c: i32) i32;
}

/// Ergonomic byte-oriented wrappers.
pub fn is_alpha(b: u8) bool {
    return unsafe isalpha(b) != 0;
}
/// True for an ASCII decimal digit.
pub fn is_digit(b: u8) bool {
    return unsafe isdigit(b) != 0;
}
/// True for an ASCII letter or digit.
pub fn is_alnum(b: u8) bool {
    return unsafe isalnum(b) != 0;
}
/// True for ASCII whitespace.
pub fn is_space(b: u8) bool {
    return unsafe isspace(b) != 0;
}
/// True for an ASCII uppercase letter.
pub fn is_upper(b: u8) bool {
    return unsafe isupper(b) != 0;
}
/// True for an ASCII lowercase letter.
pub fn is_lower(b: u8) bool {
    return unsafe islower(b) != 0;
}
/// True for a hexadecimal digit.
pub fn is_xdigit(b: u8) bool {
    return unsafe isxdigit(b) != 0;
}
/// The uppercase counterpart of an ASCII letter; other bytes unchanged.
pub fn to_upper(b: u8) u8 {
    return (unsafe toupper(b)) as u8;
}
/// The lowercase counterpart of an ASCII letter; other bytes unchanged.
pub fn to_lower(b: u8) u8 {
    return (unsafe tolower(b)) as u8;
}
