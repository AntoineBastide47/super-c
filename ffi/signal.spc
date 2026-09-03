// FFI bindings for <signal.h>. Import with `import signal;`. Every call site requires `unsafe`.
// The SIG* values are hardcoded constants, not bindings to the platform's macros.

extern "C" {
    /// Install `handler` for `sig`; the previous handler, or SIG_ERR.
    pub fn signal(sig: i32, handler: fn(i32) void) *mut void;
    /// Deliver `sig` to this process; 0 on success.
    pub fn raise(sig: i32) i32;
}

/// Signal numbers, POSIX values.
pub const SIGINT: i32 = 2;
pub const SIGILL: i32 = 4;
pub const SIGABRT: i32 = 6;
pub const SIGFPE: i32 = 8;
pub const SIGSEGV: i32 = 11;
pub const SIGTERM: i32 = 15;
