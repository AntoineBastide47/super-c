// FFI bindings for <signal.h>. Import with `import signal;`. Every call site requires `unsafe`.
// The SIG* constants are `extern`: each binds to the real `<signal.h>` macro (the Windows CRT numbers
// SIGABRT 22, POSIX 6), so they are runtime values only, not Super-C constant expressions.

extern "C" "signal.h" {
    /// Install `handler` for `sig`; the previous handler, or SIG_ERR.
    pub fn signal(sig: i32, handler: fn(i32) void) *mut void;
    /// Deliver `sig` to this process; 0 on success.
    pub fn raise(sig: i32) i32;

    /// Signal numbers, with the platform's values.
    pub const SIGINT: i32;
    pub const SIGILL: i32;
    pub const SIGABRT: i32;
    pub const SIGFPE: i32;
    pub const SIGSEGV: i32;
    pub const SIGTERM: i32;
}
