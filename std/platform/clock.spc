// Clocks of std::platform: the monotonic clock for durations and deadlines, the wall clock (UTC) for
// timestamps, and an OS-thread sleep. A coroutine sleeps through `std::time::sleep` instead, which parks it
// without blocking its worker. Unstable, internal to std and the compiler.
import sc_runtime;

// WASI's `clockid_t` is a pointer, whose value `std::rt::libc`'s `clock_gettime` reads as the WASI clock id
// plus one.
@platform(wasm)
type clockid = usize;
@platform(macos | ios | linux | android)
type clockid = i32;

@platform(!windows)
extern "C" "time.h" {
    struct timespec {
        pub tv_sec: i64,
        pub tv_nsec: isize,
    }
    fn clock_gettime(clock: clockid, ts: *mut timespec) i32;
}

@platform(macos | ios | linux | android)
extern "C" "time.h" {
    const CLOCK_REALTIME: i32;
}

// The header's `CLOCK_REALTIME` on WASI is the address of a `const` object; the runtime spells it as the
// WASI realtime clock's id (0) plus one, as for C (`src/emit/rt_h.spc`).
@platform(wasm)
const CLOCK_REALTIME: clockid = 1;

@platform(windows)
extern "C" "windows.h" {
    @import("FILETIME")
    struct FILETIME {
        pub dwLowDateTime: u32,
        pub dwHighDateTime: u32,
    }
    fn GetSystemTimePreciseAsFileTime(ft: *mut FILETIME);
}

/// Nanoseconds since an unspecified start; never runs backwards. Only differences mean anything.
pub fn monotonic_ns() u64 {
    return sc_runtime::sc_rt_now_ns();
}

/// Nanoseconds since 1970-01-01 00:00:00 UTC, negative before it. Steps when the system time is set.
@platform(!windows)
pub fn wall_ns() i64 {
    let mut ts = timespec { tv_sec: 0, tv_nsec: 0 };
    // CLOCK_REALTIME and a valid pointer: the call cannot fail.
    unsafe clock_gettime(CLOCK_REALTIME, &mut ts);
    return ts.tv_sec * 1000000000 + ts.tv_nsec as i64;
}
/// Nanoseconds since 1970-01-01 00:00:00 UTC, negative before it. Steps when the system time is set.
@platform(windows)
pub fn wall_ns() i64 {
    let mut ft = FILETIME { dwLowDateTime: 0, dwHighDateTime: 0 };
    unsafe GetSystemTimePreciseAsFileTime(&mut ft);
    return filetime_unix_ns(ft.dwHighDateTime as u64 << 32 | ft.dwLowDateTime as u64);
}

/// Nanoseconds since the Unix epoch of a Windows FILETIME value (100 ns ticks since 1601-01-01 UTC).
pub const fn filetime_unix_ns(t: u64) i64 {
    return (t as i64 - 116444736000000000) * 100;
}

/// Block the calling OS thread for at least `ns` nanoseconds; a signal does not shorten the sleep.
pub fn sleep_ns(ns: u64) {
    sc_runtime::sc_rt_sleep_ns(ns.min(9223372036854775807) as i64);
}
