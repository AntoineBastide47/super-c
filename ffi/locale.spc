// FFI bindings for <locale.h>. Import with `import locale;`.
// `struct lconv` is returned as an opaque pointer because its layout is platform-specific.
// Every call site requires `unsafe`. The LC_* category values are hardcoded constants, not bindings to
// the platform's macros.

extern "C" {
    /// Set (non-null `locale`) or query the locale of `category`; the resulting locale name (owned by libc)
    /// or null on failure.
    pub fn setlocale(category: i32, locale: *const char) *mut char;
    /// The current numeric/monetary formatting conventions (a platform lconv, owned by libc).
    pub fn localeconv() *mut void;
}

/// Locale categories, with the platform's values.
pub const LC_ALL: i32 = 0;
pub const LC_COLLATE: i32 = 1;
pub const LC_CTYPE: i32 = 2;
pub const LC_MONETARY: i32 = 3;
pub const LC_NUMERIC: i32 = 4;
pub const LC_TIME: i32 = 5;
