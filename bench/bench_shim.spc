// Bench-only platform glue, riding the same mechanism as src/driver_shim.spc: the backing
// "bench_shim.h" resolves next to this file and its same-stem sibling bench_shim.c is discovered
// and compiled automatically. Every platform split lives in the C file (#ifdef), so this surface
// is platform-neutral.
extern "C" "bench_shim.h" {
    /// Peak resident set size in bytes.
    pub fn sc_peak_rss() i64;
    /// CPU cycles consumed by this process so far (0 when unsupported).
    pub fn sc_cpu_cycles() i64;
    /// Heap allocations so far, from the counting allocator hooks.
    pub fn sc_alloc_count() i64;
    /// Heap bytes requested so far.
    pub fn sc_alloc_bytes() i64;
    /// The CPU model name into `buf`; 0 on success.
    pub fn sc_cpu_model(buf: *mut char, cap: usize) i32;
}
