// Durations, deadlines and suspension. Import with `import std::parallel::time as time;`.
//
// `sleep` is the reason this module exists in `parallel`: inside a coroutine it parks on the scheduler's
// timer heap, so the worker thread keeps running other tasks for the duration, while on any other thread it
// sleeps outright. Deadlines are monotonic `platform::now_ns()` values; the timed `sync` and `channel`
// waits take one, and `remaining_ns` is how a wait loop asks how much of its budget is left.

import std::parallel::runtime as runtime;
import std::parallel::platform as platform;

/// A span of time held as whole nanoseconds. Build one with `Duration::from_millis(50)` and friends.
pub struct Duration {
    pub ns: u64,
}

extend Duration {
    /// A duration of `n` nanoseconds.
    pub const fn from_nanos(n: u64) Duration {
        return Duration { ns: n };
    }
    /// A duration of `n` microseconds, saturating at the largest duration.
    pub const fn from_micros(n: u64) Duration {
        return Duration::scaled(n, 1000);
    }
    /// A duration of `n` milliseconds, saturating at the largest duration.
    pub const fn from_millis(n: u64) Duration {
        return Duration::scaled(n, 1000000);
    }
    /// A duration of `n` seconds, saturating at the largest duration.
    pub const fn from_secs(n: u64) Duration {
        return Duration::scaled(n, 1000000000);
    }
    // `n` units of `unit` nanoseconds. Saturates rather than wrapping, as deadlines do
    // (`runtime::deadline_after`): a wrapped duration would be a short one.
    const fn scaled(n: u64, unit: u64) Duration {
        if n > 18446744073709551615u64 / unit {
            return Duration { ns: 18446744073709551615u64 };
        }
        return Duration { ns: n * unit };
    }
    /// The duration in whole nanoseconds.
    pub const fn as_nanos(self: &Duration) u64 {
        return self.ns;
    }
    /// The duration truncated to whole milliseconds.
    pub const fn as_millis(self: &Duration) u64 {
        return self.ns / 1000000;
    }
    /// The duration truncated to whole seconds.
    pub const fn as_secs(self: &Duration) u64 {
        return self.ns / 1000000000;
    }
}

/// The monotonic deadline `d` from now, in the units every timed wait takes.
pub fn deadline_in(d: Duration) u64 {
    return runtime::deadline_after(d.ns);
}

/// Nanoseconds left until `deadline`; `0` once it has passed. A wait loop stops when this reaches zero.
pub fn remaining_ns(deadline: u64) u64 {
    let now = platform::now_ns();
    if deadline <= now {
        return 0;
    }
    return deadline - now;
}

/// Suspend for `d`. A coroutine parks (its worker runs other tasks meanwhile) and any other thread
/// sleeps. Never blocks a worker thread inside a coroutine.
pub fn sleep(d: Duration) {
    // Clamped to the largest `i64`: the cast alone turns a huge duration negative, which sleeps not at all.
    let ns = if d.ns > 9223372036854775807u64 {
        9223372036854775807i64;
    } else {
        d.ns as i64;
    };
    runtime::sleep_ns(ns);
}
