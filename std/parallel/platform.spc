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

/// Bytes currently mapped for coroutine stacks, guard pages included: every stack a live or pooled task
/// block holds. Mapped, not resident: a page counts here from the map and in the resident set only once
/// the task has touched it, which is why neither the allocator counters nor RSS can report this.
pub fn stack_bytes() usize {
    return unsafe sc_runtime::sc_rt_stack_bytes();
}

/// The page size of this machine: the granularity of every stack mapping and reclaim.
pub fn page_size() usize {
    return unsafe sc_runtime::sc_rt_page_size();
}
