// Platform glue for the benchmark library, backed by bench_sys.h and its same-stem sibling bench_sys.c
// (discovered and compiled automatically, the mechanism src/driver_shim.spc rides). Every platform split
// lives in the C file, so this surface is platform-neutral; every counter has an availability query, and an
// unavailable counter is reported as such, never as zero work. Import with
// `import std::testing::bench_sys as sys;`. Every call requires `unsafe`.
extern "C" "bench_sys.h" {
    /// Cumulative CPU cycles of the scope `sc_bs_cycles_scope` reports; 0 and meaningless when that is 0.
    pub fn sc_bs_cycles() i64;
    /// What the cycle counter covers, as `CYC_*` bits; 0 when there is no counter on this platform.
    pub fn sc_bs_cycles_scope() i32;
    /// User plus system CPU time of every thread, in nanoseconds; -1 when unavailable.
    pub fn sc_bs_cpu_ns() i64;
    /// Whether malloc-family calls are counted on this platform (see bench_sys.h for what is counted).
    pub fn sc_bs_alloc_supported() i32;
    /// Turn allocation accounting on or off. Off, a call costs one relaxed load and a branch.
    pub fn sc_bs_alloc_enable(on: i32) void;
    /// Whether accounting is on.
    pub fn sc_bs_alloc_enabled() i32;
    /// `out[0]` calls, `out[1]` bytes requested, `out[2]` threads that allocated, `out[3]` 1 when more
    /// threads allocated than have private lines.
    pub fn sc_bs_alloc_snapshot(out: *mut i64) void;
    /// Cumulative counted allocation calls.
    pub fn sc_bs_alloc_calls() i64;
    /// Cumulative bytes those calls requested.
    pub fn sc_bs_alloc_bytes() i64;
    /// Peak resident set, bytes; -1 when unavailable.
    pub fn sc_bs_rss_peak() i64;
    /// Current resident set, bytes; -1 when unavailable.
    pub fn sc_bs_rss_now() i64;
    /// The CPU model name into `buf`; 0 on success.
    pub fn sc_bs_cpu_model(buf: *mut char, cap: usize) i32;
    /// The operating system this binary runs on, as a short name.
    pub fn sc_bs_os() *const char;
    /// The architecture this binary was built for.
    pub fn sc_bs_arch() *const char;
    /// Fork: 0 in the child, the child's pid in the parent, -1 where there is no fork.
    pub fn sc_bs_fork() i64;
    /// Wait for `pid`: its exit code, 128 plus the killing signal, or -1 when the wait failed.
    pub fn sc_bs_wait(pid: i64) i32;
    /// Flush every stdio stream.
    pub fn sc_bs_flush() void;
    /// Optimisation barrier: store `v` where the compiler must assume it is read.
    pub fn sc_bs_sink(v: u64) void;
    /// The last value stored by `sc_bs_sink`.
    pub fn sc_bs_sunk() u64;
}

/// `sc_bs_cycles_scope` bit: every thread of the process is counted.
pub const CYC_ALL: i32 = 1;
/// `sc_bs_cycles_scope` bit: kernel-mode cycles are included.
pub const CYC_KERNEL: i32 = 2;
/// `sc_bs_cycles_scope` bit: threads alive before the first call are counted.
pub const CYC_EXISTING: i32 = 4;
