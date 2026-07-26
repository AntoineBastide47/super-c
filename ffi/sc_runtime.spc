// FFI bindings for the concurrency substrate (backed by ffi/sc_rt.c, auto-discovered from ffi/sc_rt.h).
// These are the raw, unsafe building blocks the Super-C scheduler is built on -- monotonic clock, CPU count,
// the current-coroutine TLS slot, address-based parking, guard-paged stacks and a stackful context switch.
// Prefer `std/parallel/platform.spc` for the safe pieces; the rest are used only by the runtime internals.
// pthread (used by the POSIX parking lot) is linked transitively through `std/parallel/thread.spc`.
// Import with `import sc_runtime;`. Every call requires `unsafe`.

extern "C" "sc_rt.h" {
    pub fn sc_rt_now_ns() u64;
    pub fn sc_rt_ncpu() usize;

    pub fn sc_rt_tls_set(p: *mut void) void;
    pub fn sc_rt_tls_get() *mut void;

    // Park while `*word == expected` until unparked or (timeout_ns >= 0) the deadline; < 0 waits forever.
    // Wakeups may be spurious; the unparker publishes the new state to `*word` before unparking.
    pub fn sc_rt_park(word: *mut i32, expected: i32, timeout_ns: i64) void;
    pub fn sc_rt_unpark_one(word: *mut i32) void;
    pub fn sc_rt_unpark_all(word: *mut i32) void;

    // Sleep the calling OS thread. Only for a non-coroutine thread -- a coroutine must park on the
    // scheduler's timer list instead, or it would take its worker down with it.
    pub fn sc_rt_sleep_ns(ns: i64) void;

    // A guard-paged stack: the usable low end, or null on failure. Free with the same size.
    pub fn sc_rt_stack_alloc(size: usize) *mut void;
    pub fn sc_rt_stack_free(usable: *mut void, size: usize) void;

    // Stackful context switch. `alloc` makes an empty (root) context; `init` arms one to run `entry(arg)` on
    // `stack`; `switch` saves the running context into `from` and resumes `to`.
    pub fn sc_rt_ctx_alloc() *mut void;
    pub fn sc_rt_ctx_init(ctx: *mut void, stack: *mut void, size: usize, entry: fn(*mut void) void, arg: *mut void) void;
    pub fn sc_rt_ctx_switch(from: *mut void, to: *mut void) void;
    pub fn sc_rt_ctx_free(ctx: *mut void) void;
}
