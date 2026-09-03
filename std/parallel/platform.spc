// Safe wrappers over the platform substrate (ffi/sc_runtime.c). The raw parking, guarded-stack and
// context-switch primitives stay in `sc_runtime`: they are inherently unsafe and used only by the
// scheduler. This exposes the two that are safe on their own: the CPU count and the monotonic clock.
// Import with `import std::parallel::platform;`.

import sc_runtime;

/// Number of logical CPUs (always >= 1). The default worker-thread count for the scheduler.
pub fn ncpu() usize {
    return unsafe sc_runtime::sc_rt_ncpu();
}

/// Monotonic time in nanoseconds since an unspecified epoch. Only differences are meaningful; it never runs
/// backwards, so it is the right clock for timing and deadlines.
pub fn now_ns() u64 {
    return unsafe sc_runtime::sc_rt_now_ns();
}
