// FFI bindings for <errno.h> / <string.h>'s strerror. Import with `import errno;`.
//
// `errno` itself is a thread-local macro on most platforms, so the compiler runtime exposes a portable
// `__sc_errno_location()` helper returning the current thread's errno cell. Calling the raw bindings
// requires `unsafe`; the `errno`/`set_errno`/`error_string` wrappers do not.

extern "C" {
    /// Address of this thread's errno.
    pub fn __sc_errno_location() *mut i32;
    /// The human-readable message for error code `code`.
    pub fn strerror(code: i32) *const char;
}

/// This thread's current errno value.
pub fn errno() i32 {
    return unsafe __sc_errno_location()[0];
}

/// Overwrite this thread's errno.
pub fn set_errno(code: i32) {
    unsafe __sc_errno_location()[0] = code;
}

/// The error message for `code` (e.g. a negative return value's magnitude) as an owned string.
pub fn error_string(code: i32) String {
    return String::from_cstr(unsafe strerror(code));
}
