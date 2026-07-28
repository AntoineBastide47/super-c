// FFI bindings for the concurrency substrate (backed by ffi/sc_rt.c, auto-discovered from ffi/sc_rt.h).
// These are the raw, unsafe building blocks the Super-C scheduler is built on -- monotonic clock, CPU count,
// the current-coroutine TLS slot, address-based parking, guard-paged stacks and a stackful context switch.
// Prefer `std/parallel/platform.spc` for the safe pieces; the rest are used only by the runtime internals.
// Import with `import sc_runtime;`. Every call requires `unsafe`.

// Parking is the one piece with a per-OS backing LIBRARY, so it is declared once per target: POSIX parks on
// a pthread condition-variable lot (libpthread), Windows on WaitOnAddress (which lives in the
// synchronization API set, not kernel32's import library -- omit the flag and the link fails on those three
// symbols alone). The signatures are identical; `platform_filter` leaves exactly one block standing, and the
// `-l` rides with it.
//
// Park while `*word == expected` until unparked or (timeout_ns >= 0) the deadline; < 0 waits forever.
// Wakeups may be spurious; the unparker publishes the new state to `*word` before unparking.
@platform(macos | linux)
@c.link("pthread")
extern "C" "sc_rt.h" {
    pub fn sc_rt_park(word: *mut i32, expected: i32, timeout_ns: i64) void;
    pub fn sc_rt_unpark_one(word: *mut i32) void;
    pub fn sc_rt_unpark_all(word: *mut i32) void;
}

@platform(windows)
@c.link("synchronization")
extern "C" "sc_rt.h" {
    pub fn sc_rt_park(word: *mut i32, expected: i32, timeout_ns: i64) void;
    pub fn sc_rt_unpark_one(word: *mut i32) void;
    pub fn sc_rt_unpark_all(word: *mut i32) void;
}

extern "C" "sc_rt.h" {
    pub fn sc_rt_now_ns() u64;
    pub fn sc_rt_ncpu() usize;

    pub fn sc_rt_tls_set(p: *mut void) void;
    pub fn sc_rt_tls_get() *mut void;

    // Which pool worker this thread is (-1 off the pool): how a push finds its own run deque.
    pub fn sc_rt_widx_set(i: i32) void;
    pub fn sc_rt_widx_get() i32;

    // One spin hint: what a worker runs between look-again attempts before it parks. It stays runnable.
    pub fn sc_rt_cpu_relax() void;

    // A spinlock over a plain i32 (0 free, 1 held), for critical sections too short to be worth a mutex --
    // a contended pthread mutex is two syscalls, this is a cache-line handoff. Never block while holding it.
    pub fn sc_rt_spin_lock(word: *mut i32) void;
    pub fn sc_rt_spin_unlock(word: *mut i32) void;

    // One 64-byte static bucket of the mutex parking lot, keyed by the lock's address. Static so a waker
    // may touch it after the mutex itself was freed; the queue discipline lives in std/parallel/sync.spc.
    pub fn sc_rt_lot_bucket(addr: *mut void) *mut void;

    // Sleep the calling OS thread. Only for a non-coroutine thread -- a coroutine must park on the
    // scheduler's timer list instead, or it would take its worker down with it.
    pub fn sc_rt_sleep_ns(ns: i64) void;

    // OS threads and their locks, as opaque handles: pthreads on POSIX, Win32 on Windows, one call site
    // either way. `thread_create` fills `out` and returns 0 on success; `join` consumes the handle.
    pub fn sc_rt_thread_create(out: *mut *mut void, entry: fn(*mut void) *mut void, arg: *mut void) i32;
    pub fn sc_rt_thread_join(handle: *mut void) i32;

    // A NON-recursive mutex, released by the thread that took it. Allocated and sized in C, so Super-C
    // never needs `sizeof(pthread_mutex_t)` (40 bytes on glibc, 64 on macOS) or of an SRWLOCK.
    pub fn sc_rt_mutex_new() *mut void;
    pub fn sc_rt_mutex_free(m: *mut void) void;
    pub fn sc_rt_mutex_lock(m: *mut void) void;
    pub fn sc_rt_mutex_unlock(m: *mut void) void;

    // Condition variable paired with a held `sc_rt_mutex_*`. `timedwait_ns` returns nonzero exactly when
    // the deadline (rather than a signal) woke it; `< 0` waits forever. Re-check the condition in a loop.
    pub fn sc_rt_cond_new() *mut void;
    pub fn sc_rt_cond_free(c: *mut void) void;
    pub fn sc_rt_cond_wait(c: *mut void, m: *mut void) void;
    pub fn sc_rt_cond_timedwait_ns(c: *mut void, m: *mut void, rel_ns: i64) i32;
    pub fn sc_rt_cond_signal(c: *mut void) void;
    pub fn sc_rt_cond_broadcast(c: *mut void) void;

    // A guard-paged stack: the usable low end, or null on failure. Free with the same size.
    pub fn sc_rt_stack_alloc(size: usize) *mut void;
    pub fn sc_rt_stack_free(usable: *mut void, size: usize) void;
    /// Arm this thread to report a stack overflow instead of dying on a bare fault; `note_size` supplies
    /// the size the message quotes. No-ops on Windows for now.
    pub fn sc_rt_stack_guard_install() void;
    pub fn sc_rt_stack_note_size(bytes: usize) void;

    // Stackful context switch. `alloc` makes an empty (root) context; `init` arms one to run `entry(arg)` on
    // `stack`; `switch` saves the running context into `from` and resumes `to`.
    pub fn sc_rt_ctx_alloc() *mut void;
    pub fn sc_rt_ctx_init(ctx: *mut void, stack: *mut void, size: usize, entry: fn(*mut void) void, arg: *mut void) void;
    pub fn sc_rt_ctx_switch(from: *mut void, to: *mut void) void;
    pub fn sc_rt_ctx_free(ctx: *mut void) void;
}
