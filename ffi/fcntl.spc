// FFI bindings for <fcntl.h>. Import with `import fcntl;`. Every call site requires `unsafe`.
//
// The constants are `extern` (no initializer): each binds to the real `<fcntl.h>` macro, whose value the
// C compiler fills in from the backing header, so platform-specific numbers are never hardcoded here. They
// are runtime values only (usable as flag arguments like `open(p, O_RDONLY | O_CREAT)`), not Super-C
// constant expressions.

extern "C" "fcntl.h" {
    pub fn open(path: *const char, flags: i32, ...) i32;
    pub fn creat(path: *const char, mode: u32) i32;
    pub fn fcntl(fd: i32, cmd: i32, ...) i32;

    // Access mode (exactly one), OR'd with the open-time flags below.
    pub const O_RDONLY: i32;
    pub const O_WRONLY: i32;
    pub const O_RDWR: i32;

    // Open-time flags.
    pub const O_APPEND: i32;
    pub const O_CREAT: i32;
    pub const O_TRUNC: i32;
    pub const O_EXCL: i32;
    pub const O_NONBLOCK: i32;
    pub const O_CLOEXEC: i32;

    // fcntl() commands and the close-on-exec descriptor flag.
    pub const F_GETFD: i32;
    pub const F_SETFD: i32;
    pub const F_GETFL: i32;
    pub const F_SETFL: i32;
    pub const FD_CLOEXEC: i32;
}
