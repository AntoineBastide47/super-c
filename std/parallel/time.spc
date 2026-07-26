// Durations, deadlines and suspension. Import with `import std::parallel::time as time;`.
//
// `sleep` is the reason this module exists in `parallel`: inside a coroutine it parks on the scheduler's
// timer list, so the worker thread keeps running other tasks for the duration, while on any other thread it
// sleeps outright. Deadlines are monotonic `platform::now_ns()` values -- the timed `sync` and `channel`
// waits take one, and `remaining_ns` is how a wait loop asks how much of its budget is left.

import std::parallel::runtime as runtime;
import std::parallel::platform as platform;

/// A span of time held as whole nanoseconds. Build one with `Duration::from_millis(50)` and friends.
pub struct Duration {
    pub ns: u64,
}

extend Duration {
    /// A duration of `n` nanoseconds.
    pub fn from_nanos(n: u64) Duration {
        return Duration { ns: n };
    }
    /// A duration of `n` microseconds.
    pub fn from_micros(n: u64) Duration {
        return Duration { ns: n * 1000 };
    }
    /// A duration of `n` milliseconds.
    pub fn from_millis(n: u64) Duration {
        return Duration { ns: n * 1000000 };
    }
    /// A duration of `n` seconds.
    pub fn from_secs(n: u64) Duration {
        return Duration { ns: n * 1000000000 };
    }
    /// The duration in whole nanoseconds.
    pub fn as_nanos(self: &Duration) u64 {
        return self.ns;
    }
    /// The duration truncated to whole milliseconds.
    pub fn as_millis(self: &Duration) u64 {
        return self.ns / 1000000;
    }
    /// The duration truncated to whole seconds.
    pub fn as_secs(self: &Duration) u64 {
        return self.ns / 1000000000;
    }
}

/// The monotonic deadline `d` from now, in the units every timed wait takes.
pub fn deadline_in(d: Duration) u64 {
    return platform::now_ns() + d.ns;
}

/// Nanoseconds left until `deadline`; `0` once it has passed. A wait loop stops when this reaches zero.
pub fn remaining_ns(deadline: u64) u64 {
    let now = platform::now_ns();
    if deadline <= now {
        return 0;
    }
    return deadline - now;
}

/// Suspend for `d`. A coroutine parks -- its worker runs other tasks meanwhile -- and any other thread
/// sleeps. Never blocks a worker thread inside a coroutine.
pub fn sleep(d: Duration) {
    runtime::sleep_ns(d.ns as i64);
}
