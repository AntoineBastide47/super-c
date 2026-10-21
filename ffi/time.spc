// FFI bindings for <time.h>. Import with `import time;`.
//
// C's `time_t` is a 64-bit integer on every target, exposed here as `i64`; `clock_t` differs per target
// (`clock_t` below). The `time_t*` out-parameter of `time` is taken as `*mut void` (pass `null` to ignore
// it). Calendar APIs use `*mut void` for `struct tm*` to avoid assuming a non-standard `tm` typedef;
// callers that need field access declare it as a header type (`struct tm` in an `extern "C" "time.h"`
// block, every member listed). Calling the raw bindings requires `unsafe` except `clock` and `difftime`;
// `now`/`cpu_seconds` do not. The Windows C runtime's `clock` counts wall time since the process started,
// so `cpu_seconds` reads the process times there.

/// C's `clock_t`: `unsigned long` on Apple targets, `long` on Linux and Windows, `long long` on wasm.
@platform(macos | ios)
pub type clock_t = u64;
@platform(linux | android)
pub type clock_t = i64;
@platform(windows)
pub type clock_t = i32;
@platform(wasm)
pub type clock_t = i64;

extern "C" "time.h" {
    /// Ticks per second of `clock()`.
    @platform(macos | ios | linux | android)
    pub const CLOCKS_PER_SEC: clock_t = 1000000;
    @platform(windows)
    pub const CLOCKS_PER_SEC: clock_t = 1000;
    @platform(wasm)
    pub const CLOCKS_PER_SEC: clock_t = 1000000000;
}

extern "C" {
    /// Seconds since the Unix epoch. Pass `null` to ignore the out-parameter.
    pub fn time(out: *mut void) i64;
    /// Processor time consumed so far, in clock ticks (divide by CLOCKS_PER_SEC for seconds). On Windows:
    /// wall time since the process started.
    @unsafe(safe)
    pub fn clock() clock_t;
    /// Difference `end - start` in seconds.
    @unsafe(safe)
    pub fn difftime(end: i64, start: i64) f64;

    /// Break a Unix time into local calendar fields (a platform tm, owned by libc); null on failure.
    pub fn localtime(t: *const i64) *mut void;
    /// Break a Unix time into UTC calendar fields (owned by libc); null on failure.
    pub fn gmtime(t: *const i64) *mut void;
    /// Calendar fields (local time) back to a Unix time; -1 on failure.
    pub fn mktime(t: *mut void) i64;
    /// Format calendar fields into `dst` (at most `max` bytes with NUL); the length, or 0 when it did not
    /// fit.
    pub fn strftime(dst: *mut char, max: usize, fmt: *const char, t: *const void) usize;
}

/// Current wall-clock time as seconds since the Unix epoch.
pub fn now() i64 {
    return unsafe time(null);
}

// The header declares the calls: a prototype of its own would conflict with <windows.h>, which the
// runtime includes. `FILETIME` counts 100 ns units in two 32-bit halves.
@platform(windows)
extern "C" "windows.h" {
    @import("FILETIME")
    struct FileTime {
        @import("dwLowDateTime")
        pub low: u32,
        @import("dwHighDateTime")
        pub high: u32,
    }
    fn GetCurrentProcess() *mut void;
    fn GetProcessTimes(
        process: *mut void,
        creation: *mut FileTime,
        exit: *mut FileTime,
        kernel: *mut FileTime,
        user: *mut FileTime,
    ) i32;
}

// User plus kernel time of every thread of the process, in nanoseconds; -1 when the query fails.
@platform(windows)
fn cpu_ns() i64 {
    let mut c = FileTime { low: 0, high: 0 };
    let mut e = FileTime { low: 0, high: 0 };
    let mut k = FileTime { low: 0, high: 0 };
    let mut u = FileTime { low: 0, high: 0 };
    if unsafe GetProcessTimes(GetCurrentProcess(), &mut c, &mut e, &mut k, &mut u) == 0 {
        return -1;
    }
    let t = (k.high as u64 << 32 | k.low as u64) + (u.high as u64 << 32 | u.low as u64);
    return (t * 100) as i64;
}

/// Processor time consumed by the program so far (user and kernel time of every thread), in seconds;
/// negative when the platform cannot report it. wasm has no process clock: wasi emulates it with the
/// wall clock.
@platform(!windows)
pub fn cpu_seconds() f64 {
    return clock() as f64 / CLOCKS_PER_SEC as f64;
}

/// Processor time consumed by the program so far (user and kernel time of every thread), in seconds;
/// negative when the platform cannot report it.
@platform(windows)
pub fn cpu_seconds() f64 {
    return cpu_ns() as f64 / 1e9;
}
