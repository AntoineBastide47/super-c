// The <ctype.h> functions in Super-C: character classification and conversion as C's "C" locale defines
// them, on every target and at compile time. Import with `import ctype;`. The C forms take and return
// `int`, a byte value or EOF (-1): a value outside 0 to 255 is in no class and converts to itself. The
// `u8` and `bool` forms below them cover the common cases.

/// Whether `c` is a byte value.
const fn byte(c: i32) bool {
    return c >= 0 && c <= 255;
}

/// Nonzero for a letter.
pub const fn isalpha(c: i32) i32 {
    return (byte(c) && (c as u8).is_ascii_alphabetic()) as i32;
}

/// Nonzero for a decimal digit.
pub const fn isdigit(c: i32) i32 {
    return (byte(c) && (c as u8).is_ascii_digit()) as i32;
}

/// Nonzero for a letter or digit.
pub const fn isalnum(c: i32) i32 {
    return (byte(c) && (c as u8).is_ascii_alphanumeric()) as i32;
}

/// Nonzero for whitespace (space, \t, \n, \v, \f, \r).
pub const fn isspace(c: i32) i32 {
    return (c == 0x20 || c >= 0x09 && c <= 0x0D) as i32;
}

/// Nonzero for an uppercase letter.
pub const fn isupper(c: i32) i32 {
    return (byte(c) && (c as u8).is_ascii_uppercase()) as i32;
}

/// Nonzero for a lowercase letter.
pub const fn islower(c: i32) i32 {
    return (byte(c) && (c as u8).is_ascii_lowercase()) as i32;
}

/// Nonzero for printable punctuation.
pub const fn ispunct(c: i32) i32 {
    return (byte(c) && (c as u8).is_ascii_punctuation()) as i32;
}

/// Nonzero for a control character.
pub const fn iscntrl(c: i32) i32 {
    return (byte(c) && (c as u8).is_ascii_control()) as i32;
}

/// Nonzero for a printable character, space included.
pub const fn isprint(c: i32) i32 {
    return (c >= 0x20 && c <= 0x7E) as i32;
}

/// Nonzero for a printable character other than space.
pub const fn isgraph(c: i32) i32 {
    return (byte(c) && (c as u8).is_ascii_graphic()) as i32;
}

/// Nonzero for space or tab.
pub const fn isblank(c: i32) i32 {
    return (c == 0x20 || c == 0x09) as i32;
}

/// Nonzero for a hexadecimal digit.
pub const fn isxdigit(c: i32) i32 {
    return (byte(c) && (c as u8).is_ascii_hexdigit()) as i32;
}

/// The uppercase counterpart of a letter; other values unchanged.
pub const fn toupper(c: i32) i32 {
    if !byte(c) {
        return c;
    }
    return (c as u8).to_ascii_uppercase();
}

/// The lowercase counterpart of a letter; other values unchanged.
pub const fn tolower(c: i32) i32 {
    if !byte(c) {
        return c;
    }
    return (c as u8).to_ascii_lowercase();
}

/// True for an ASCII letter.
pub const fn is_alpha(b: u8) bool {
    return b.is_ascii_alphabetic();
}

/// True for an ASCII decimal digit.
pub const fn is_digit(b: u8) bool {
    return b.is_ascii_digit();
}

/// True for an ASCII letter or digit.
pub const fn is_alnum(b: u8) bool {
    return b.is_ascii_alphanumeric();
}

/// True for ASCII whitespace (space, \t, \n, \v, \f, \r).
pub const fn is_space(b: u8) bool {
    return isspace(b) != 0;
}

/// True for an ASCII uppercase letter.
pub const fn is_upper(b: u8) bool {
    return b.is_ascii_uppercase();
}

/// True for an ASCII lowercase letter.
pub const fn is_lower(b: u8) bool {
    return b.is_ascii_lowercase();
}

/// True for a hexadecimal digit.
pub const fn is_xdigit(b: u8) bool {
    return b.is_ascii_hexdigit();
}

/// The uppercase counterpart of an ASCII letter; other bytes unchanged.
pub const fn to_upper(b: u8) u8 {
    return b.to_ascii_uppercase();
}

/// The lowercase counterpart of an ASCII letter; other bytes unchanged.
pub const fn to_lower(b: u8) u8 {
    return b.to_ascii_lowercase();
}
