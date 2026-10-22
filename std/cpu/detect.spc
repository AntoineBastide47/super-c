// The CPU features of the machine the program runs on, detected once (ffi/sc_cpu.spc): CPUID and XGETBV on
// x86_64, `sysctlbyname` on macOS and iOS (aarch64, and x86_64's AVX-512 state), `getauxval` on Linux
// and Android, `IsProcessorFeaturePresent` on Windows aarch64, none on wasm32 (an engine rejects a
// module whose features it lacks). `dispatch` chooses a function once by them. A feature the build enables is present
// by definition. Detection selects code only: no language result depends on it.
import atomic;
import std::cpu;
import sc_cpu;
import string;

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

/// The features the build enables (`TARGET_FEATURES`): the platform's baseline, `target-features`,
/// `--target-feature`, and what they imply. Every machine that runs the program has them.
pub const fn static_features() cpu::CpuFeatures {
    let mut w: [u64; 2] = [0, 0];
    unsafe sc_cpu::sc_cpu_static_words(&mut w[0]);
    return cpu::CpuFeatures { bits: w };
}

/// Whether this machine has feature `f`.
pub fn has(f: cpu::Feature) bool {
    return sc_cpu::sc_cpu_has(f as i32) != 0;
}

/// Whether this machine has every feature of x86-64 level `l`.
pub fn has_level(l: cpu::Level) bool {
    let fs = l.features();
    for i in 0..fs.len() {
        if !has(fs[i]) {
            return false;
        }
    }
    return true;
}

/// The cached choice of one dispatching entry point (`dispatch`): the chosen function's address, 0 until
/// the first call. One object serves one entry point and its one table: a second table read through it
/// gets the first table's choice. The slot is its only field: a `*mut Dispatch` addresses it.
pub struct Dispatch {
    slot: usize,
}

extend Dispatch {
    pub const fn new() Dispatch {
        return Dispatch { slot: 0 };
    }
}

/// The first function of `table` whose feature this machine has (`has`), in table order, else
/// `fallback`, chosen once per `d`: the first call reads the machine's features and publishes the
/// choice with a release store; every later call is one acquire load, which the optimizing inliner
/// splices into the caller. Two first callers store the same address. `unsafe`: the table's functions
/// may need features the caller lacks (`@target_feature`), which only the check here makes valid to
/// call, so each row's feature must imply every feature its function needs (key a level's function
/// with a feature only that level's machines have, or check `has_level` first); `d` serves this table
/// alone.
pub unsafe fn dispatch<F: FnPtr, const K: usize>(d: *mut Dispatch, table: [(cpu::Feature, F); K], fallback: F) F {
    let s = atomic::load_usize(d as *mut usize, 1);
    if s != 0 {
        return s as F;
    }
    // A copy the first call reads: the argument's address never escapes, so the steady state does not
    // write it.
    let rows = table;
    return dispatch_first(d, (&rows) as *const cpu::Feature, K, fallback as usize) as F;
}

/// The first call of `dispatch` on `d` over the `k` rows of its table at `rows`, each a feature and a
/// function pointer laid out as `(cpu::Feature, usize)`: the chosen address, published. The address is
/// copied out as bytes (a function pointer is no `usize` object). Call `dispatch` instead.
@noinline
pub unsafe fn dispatch_first(d: *mut Dispatch, rows: *const cpu::Feature, k: usize, fallback: usize) usize {
    let fs = features();
    let stride = sizeof((cpu::Feature, usize));
    let mut f = fallback;
    for i in 0..k {
        let r = rows as *const u8 + i * stride;
        if fs.has(*(r as *const cpu::Feature)) {
            string::memcpy(&mut f, r + stride - sizeof(usize), sizeof(usize));
            break;
        }
    }
    atomic::store_usize(d as *mut usize, f, 2);
    return f;
}
