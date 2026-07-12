// FFI bindings for <time.h>. Import with `import time;`.
//
// C's `time_t`/`clock_t` are integer typedefs, exposed here as `i64` values; the `time_t*` out-parameter
// of `time` is taken as `*mut void` (pass `null` to ignore it). Calendar APIs use `*mut void` for
// `struct tm*` to avoid assuming a non-standard `tm` typedef; callers that need field access should provide
// platform-specific layout glue. `CLOCKS_PER_SEC` is the POSIX value.

extern "C" {
    // Seconds since the Unix epoch. Pass `null` to ignore the out-parameter.
    pub fn time(out: *mut void) i64;
    // Processor time consumed so far, in clock ticks (divide by CLOCKS_PER_SEC for seconds).
    pub fn clock() i64;
    // Difference `end - start` in seconds.
    pub fn difftime(end: i64, start: i64) f64;

    pub fn localtime(t: *const i64) *mut void;
    pub fn gmtime(t: *const i64) *mut void;
    pub fn mktime(t: *mut void) i64;
    pub fn strftime(dst: *mut char, max: usize, fmt: *const char, t: *const void) usize;
}

pub const CLOCKS_PER_SEC: i64 = 1000000;

// Current wall-clock time as seconds since the Unix epoch.
pub fn now() i64 {
    return unsafe time(null);
}

// Processor time consumed by the program so far, in seconds.
pub fn cpu_seconds() f64 {
    return (unsafe clock()) as f64 / CLOCKS_PER_SEC as f64;
}
