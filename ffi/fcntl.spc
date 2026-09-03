// FFI bindings for <fcntl.h>. Import with `import fcntl;`. Every call site requires `unsafe`.
//
// The constants are `extern` (no initializer): each binds to the real `<fcntl.h>` macro, whose value the
// C compiler fills in from the backing header, so platform-specific numbers are never hardcoded here. They
// are runtime values only (usable as flag arguments like `open(p, O_RDONLY | O_CREAT)`), not Super-C
// constant expressions.

extern "C" "fcntl.h" {
    /// Open `path` with O_* flags (mode as the variadic third argument when creating); the descriptor, or
    /// -1 and errno.
    pub fn open(path: *const char, flags: i32, ...) i32;
    /// Create or truncate `path` for writing; the descriptor, or -1 and errno.
    pub fn creat(path: *const char, mode: u32) i32;
    /// Descriptor control (F_* command with an optional argument); -1 and errno on failure.
    pub fn fcntl(fd: i32, cmd: i32, ...) i32;

    /// Access mode (exactly one), OR'd with the open-time flags below.
    pub const O_RDONLY: i32;
    /// Open flags and fcntl commands, with the platform's values.
    pub const O_WRONLY: i32;
    pub const O_RDWR: i32;

    /// Open-time flags.
    pub const O_APPEND: i32;
    pub const O_CREAT: i32;
    pub const O_TRUNC: i32;
    pub const O_EXCL: i32;
    pub const O_NONBLOCK: i32;
    pub const O_CLOEXEC: i32;

    /// fcntl() commands and the close-on-exec descriptor flag.
    pub const F_GETFD: i32;
    pub const F_SETFD: i32;
    pub const F_GETFL: i32;
    pub const F_SETFL: i32;
    pub const FD_CLOEXEC: i32;
}
