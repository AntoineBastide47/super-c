// FFI bindings for <errno.h> / <string.h>'s strerror. Import with `import errno;`.
//
// `errno` itself is a thread-local macro on most platforms, so the compiler runtime exposes a portable
// `__sc_errno_location()` helper returning the current thread's errno cell.

extern "C" {
    pub fn __sc_errno_location() *mut i32;
    // The human-readable message for error code `code`.
    pub fn strerror(code: i32) *const char;
}

pub fn errno() i32 {
    return __sc_errno_location()[0];
}

pub fn set_errno(code: i32) {
    __sc_errno_location()[0] = code;
}

// The error message for `code` (e.g. a negative return value's magnitude) as an owned string.
pub fn error_string(code: i32) String {
    return String::from_cstr(strerror(code));
}
