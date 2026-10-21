// FFI bindings for <errno.h> / <string.h>'s strerror. Import with `import errno;`.
//
// `errno` is a macro over a per-thread object, which each C library reaches its own way: a function
// that returns its address, or a thread-local (wasi-libc). Calling the raw bindings requires `unsafe`;
// the `errno`/`set_errno`/`error_string` wrappers do not.

@platform(macos | ios)
extern "C" "errno.h" {
    @import("__error")
    fn errno_cell() *mut i32;
}
@platform(linux)
extern "C" "errno.h" {
    @import("__errno_location")
    fn errno_cell() *mut i32;
}
@platform(android)
extern "C" "errno.h" {
    @import("__errno")
    fn errno_cell() *mut i32;
}
@platform(windows)
extern "C" "errno.h" {
    @import("_errno")
    fn errno_cell() *mut i32;
}
@platform(wasm)
extern "C" "errno.h" {
    @import("errno")
    @thread_local
    static mut c_errno: i32;
}

extern "C" "string.h" {
    /// The human-readable message for error code `code`.
    pub fn strerror(code: i32) *const char;
}

/// Address of this thread's errno.
@platform(wasm)
pub unsafe fn errno_location() *mut i32 {
    return unsafe &mut c_errno;
}
/// Address of this thread's errno.
@platform(!wasm)
pub unsafe fn errno_location() *mut i32 {
    return unsafe errno_cell();
}

/// This thread's current errno value.
pub fn errno() i32 {
    return unsafe errno_location()[0];
}

/// Overwrite this thread's errno.
pub fn set_errno(code: i32) {
    unsafe errno_location()[0] = code;
}

/// The error message for `code` (e.g. a negative return value's magnitude) as an owned string.
pub fn error_string(code: i32) String {
    return unsafe String::from_cstr(strerror(code));
}
