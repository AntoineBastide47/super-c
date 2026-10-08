// The CPU features of the machine the program runs on, detected once (ffi/sc_cpu.c): `sysctlbyname` on
// macOS and iOS, `getauxval` on Linux and Android, `IsProcessorFeaturePresent` on Windows, none on
// wasm32 (an engine rejects a module whose features it lacks). A feature the build enables is present
// by definition. Detection selects code only: no language result depends on it.
import std::cpu;
import sc_cpu;

/// The features of this machine: the detected ones and the build's.
pub fn features() cpu::CpuFeatures {
    let mut w: [u64; 2] = [0, 0];
    unsafe sc_cpu::sc_cpu_words(&mut w[0]);
    return cpu::CpuFeatures { bits: w };
}

/// The features the OS reports, without the build's: a new query on each call (`features` keeps the
/// first answer).
pub fn detected() cpu::CpuFeatures {
    let mut w: [u64; 2] = [0, 0];
    unsafe sc_cpu::sc_cpu_detected_words(&mut w[0]);
    return cpu::CpuFeatures { bits: w };
}

/// The features the build's C flags enable, as the C compiler reports them (its `__ARM_FEATURE_*`
/// macros): the platform's baseline, `target-features`, `--target-feature`, what they imply, and what
/// the flag's architecture level brings. Every machine that runs the program has them.
pub fn static_features() cpu::CpuFeatures {
    let mut w: [u64; 2] = [0, 0];
    unsafe sc_cpu::sc_cpu_static_words(&mut w[0]);
    return cpu::CpuFeatures { bits: w };
}

/// Whether this machine has feature `f`.
pub fn has(f: cpu::Feature) bool {
    return sc_cpu::sc_cpu_has(f as i32) != 0;
}
