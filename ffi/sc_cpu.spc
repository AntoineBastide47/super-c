// FFI bindings for the CPU feature detector in ffi/sc_cpu.c (auto-discovered from "sc_cpu.h"): the
// project's one detector, on every OS. Prefer `std::cpu::detect`. A feature is bit `i` of a word, `i`
// its `cpu::Feature` discriminant.

extern "C" "sc_cpu.h" {
    /// Detect the features once; a constructor already did before `main`.
    @unsafe(safe)
    pub fn sc_cpu_init();
    /// 1 when feature `feature` is present (detected, or enabled by the build), else 0.
    @unsafe(safe)
    pub fn sc_cpu_has(feature: i32) i32;
    /// The present features, two words.
    @c.writes(out, 16)
    pub fn sc_cpu_words(out: *mut u64);
    /// The features the OS query reports, without the build's: a new query on each call.
    @c.writes(out, 16)
    pub fn sc_cpu_detected_words(out: *mut u64);
    /// The features the build's flags enable, two words.
    @c.writes(out, 16)
    pub fn sc_cpu_static_words(out: *mut u64);
}
