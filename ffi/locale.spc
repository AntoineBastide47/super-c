// FFI bindings for <locale.h>. Import with `import locale;`.
// `struct lconv` is returned as an opaque pointer because its layout is platform-specific.

extern "C" {
    pub fn setlocale(category: i32, locale: *const char) *mut char;
    pub fn localeconv() *mut void;
}

pub const LC_ALL: i32 = 0;
pub const LC_COLLATE: i32 = 1;
pub const LC_CTYPE: i32 = 2;
pub const LC_MONETARY: i32 = 3;
pub const LC_NUMERIC: i32 = 4;
pub const LC_TIME: i32 = 5;
