// Bench-only platform glue, riding the same mechanism as src/driver_shim.spc: the backing
// "bench_shim.h" resolves next to this file and its same-stem sibling bench_shim.c is discovered
// and compiled automatically. Every platform split lives in the C file (#ifdef), so this surface
// is platform-neutral -- except sc_memstream_open, which returns null on Windows (no open_memstream
// there; callers are @platform-gated away).
extern "C" "bench_shim.h" {
    pub fn sc_peak_rss() i64;
    pub fn sc_cpu_cycles() i64;
    pub fn sc_alloc_count() i64;
    pub fn sc_alloc_bytes() i64;
    pub fn sc_cpu_model(buf: *mut char, cap: usize) i32;
    pub fn sc_memstream_open(buf: *mut *mut char, size: *mut usize) *mut void;
}
