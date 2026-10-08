// The CPU feature table: one row per feature the compiler knows, the source of truth for
// `std::cpu::Feature` (same order: a variant's discriminant is its row, which is its bit in a
// `CpuFeatureSet`). A feature selects instructions only: no language result depends on it.

import ast::ast as ast;

/// A set of features: bit `i` is row `i` of `CPU_FEATURES`. 128 features at most.
pub struct CpuFeatureSet {
    pub w: [u64; 2],
}

/// One feature: the spelling of `--target-feature` and `target-features`, the `cpu::Feature`
/// variant, its instruction set (loader arch codes: 0 x86_64, 1 aarch64, 2 wasm32), the features
/// it implies (direct; `implied` closes them), the C compiler flag that enables it (on aarch64 the
/// `-march`/`-mcpu` extension, `push_c_flags`) and the toolchain probe that checks the flag (empty:
/// none), the platforms (bit `i`: `PLATFORM_NAMES[i]`) whose every build for the instruction set
/// has it, and for aarch64 its architecture level (`L_*`).
pub struct CpuFeature {
    pub name: str<'static>,
    pub variant: str<'static>,
    pub arch: i32,
    pub implies: CpuFeatureSet,
    pub c_flag: str<'static>,
    pub probe: str<'static>,
    pub base: u8,
    pub level: u8,
}

pub const FEATURE_COUNT: usize = 16;
pub const F_SIMD128: usize = 0;
pub const F_RELAXED_SIMD: usize = 1;
pub const F_NEON: usize = 3;
pub const F_DOTPROD: usize = 5;
pub const F_SVE: usize = 14;
pub const F_SVE2: usize = 15;

const NONE: CpuFeatureSet = CpuFeatureSet { w: [0, 0] };
// `base` masks: every platform; macOS, whose oldest aarch64 machine is the M1 (Apple clang's default
// CPU, `apple-m1`); iOS, whose default CPU is the A7 the iOS 13 floor still allows.
const ALL: u8 = 0x3F;
const MAC: u8 = 2;
const APPLE: u8 = 18;
const NEON: CpuFeatureSet = CpuFeatureSet { w: [8, 0] };
// `level`: part of Armv8.1-A (`-march=armv8.1-a` has it: `rdm`, `crc`, `lse`); needs Armv8.1-A (Clang
// guards `rdm`'s intrinsics with it); needs Armv8.2-A (binutils takes `dotprod`, `i8mm`, `sha3` only
// there, and only Armv8.2 cores have `fp16`, `dotprod`, `i8mm`, `bf16`, `sha3`, `sve`). A flag at a
// level enables the Armv8.1-A features, so each feature that needs one implies `rdm`, which implies
// `crc` and `lse`.
const L_IN81: u8 = 1;
const L_NEED81: u8 = 2;
const L_NEED82: u8 = 4;
const V81: CpuFeatureSet = CpuFeatureSet { w: [8 | 1 << 12 | 1 << 13, 0] };
const V82: CpuFeatureSet = CpuFeatureSet { w: [8 | 1 << 6, 0] };

/// Append-only, in step with `std::cpu::Feature`.
pub const CPU_FEATURES: [CpuFeature; FEATURE_COUNT] = [
    CpuFeature {
        name: "simd128",
        variant: "Simd128",
        arch: 2,
        implies: NONE,
        c_flag: "-msimd128",
        probe: "wasm-simd128",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "relaxed-simd",
        variant: "RelaxedSimd",
        arch: 2,
        implies: CpuFeatureSet { w: [1, 0] },
        c_flag: "-mrelaxed-simd",
        probe: "wasm-relaxed-simd",
        base: 0,
        level: 0,
    },
    CpuFeature { name: "sse2", variant: "Sse2", arch: 0, implies: NONE, c_flag: "", probe: "", base: ALL, level: 0 },
    CpuFeature { name: "neon", variant: "Neon", arch: 1, implies: NONE, c_flag: "", probe: "", base: ALL, level: 0 },
    CpuFeature {
        name: "fp16",
        variant: "Fp16",
        arch: 1,
        implies: V82,
        c_flag: "+fp16",
        probe: "aarch64-features",
        base: MAC,
        level: L_NEED82,
    },
    CpuFeature {
        name: "dotprod",
        variant: "Dotprod",
        arch: 1,
        implies: V82,
        c_flag: "+dotprod",
        probe: "aarch64-features",
        base: MAC,
        level: L_NEED82,
    },
    CpuFeature {
        name: "rdm",
        variant: "Rdm",
        arch: 1,
        implies: V81,
        c_flag: "+rdm",
        probe: "aarch64-features",
        base: MAC,
        level: L_IN81 | L_NEED81,
    },
    CpuFeature {
        name: "i8mm",
        variant: "I8mm",
        arch: 1,
        implies: V82,
        c_flag: "+i8mm",
        probe: "aarch64-features",
        base: 0,
        level: L_NEED82,
    },
    CpuFeature {
        name: "bf16",
        variant: "Bf16",
        arch: 1,
        implies: V82,
        c_flag: "+bf16",
        probe: "aarch64-features",
        base: 0,
        level: L_NEED82,
    },
    CpuFeature {
        name: "aes",
        variant: "Aes",
        arch: 1,
        implies: NEON,
        c_flag: "+aes",
        probe: "aarch64-features",
        base: APPLE,
        level: 0,
    },
    CpuFeature {
        name: "sha2",
        variant: "Sha2",
        arch: 1,
        implies: NEON,
        c_flag: "+sha2",
        probe: "aarch64-features",
        base: APPLE,
        level: 0,
    },
    CpuFeature {
        name: "sha3",
        variant: "Sha3",
        arch: 1,
        implies: CpuFeatureSet { w: [8 | 1 << 6 | 1 << 10, 0] },
        c_flag: "+sha3",
        probe: "aarch64-features",
        base: MAC,
        level: L_NEED82,
    },
    CpuFeature {
        name: "crc",
        variant: "Crc",
        arch: 1,
        implies: NONE,
        c_flag: "+crc",
        probe: "aarch64-features",
        base: MAC,
        level: L_IN81,
    },
    CpuFeature {
        name: "lse",
        variant: "Lse",
        arch: 1,
        implies: NONE,
        c_flag: "+lse",
        probe: "aarch64-features",
        base: MAC,
        level: L_IN81,
    },
    // GCC and Clang enable `fp16` with `sve`.
    CpuFeature {
        name: "sve",
        variant: "Sve",
        arch: 1,
        implies: CpuFeatureSet { w: [8 | 1 << 4 | 1 << 6, 0] },
        c_flag: "+sve",
        probe: "aarch64-features",
        base: 0,
        level: L_NEED82,
    },
    CpuFeature {
        name: "sve2",
        variant: "Sve2",
        arch: 1,
        implies: CpuFeatureSet { w: [1u64 << 14, 0] },
        c_flag: "+sve2",
        probe: "aarch64-features",
        base: 0,
        level: L_NEED82,
    },
];

// Each row's implied set closed under `implies`, the row itself included: each pass joins the sets of
// the members; a pass that changes nothing ends it (at most FEATURE_COUNT passes reach any chain).
const fn closure() [CpuFeatureSet; FEATURE_COUNT] {
    let t: []CpuFeature = CPU_FEATURES;
    let mut c: [CpuFeatureSet; FEATURE_COUNT] = [NONE; FEATURE_COUNT];
    for i in 0..FEATURE_COUNT {
        unsafe c[i] = with(t[i].implies, i);
    }
    for _ in 0..FEATURE_COUNT {
        let mut changed = false;
        for i in 0..FEATURE_COUNT {
            for j in 0..FEATURE_COUNT {
                if j != i && has(unsafe c[i], j) && !contains(unsafe c[i], unsafe c[j]) {
                    unsafe c[i] = join(unsafe c[i], unsafe c[j]);
                    changed = true;
                }
            }
        }
        if !changed {
            break;
        }
    }
    return c;
}

const IMPLIED: [CpuFeatureSet; FEATURE_COUNT] = closure();

/// Row `i` of the table.
pub const fn row(i: usize) CpuFeature {
    let t: []CpuFeature = CPU_FEATURES;
    return t[i];
}

pub const fn has(s: CpuFeatureSet, i: usize) bool {
    return (unsafe s.w[i / 64] >> (i % 64) as u64 & 1) != 0;
}

pub const fn with(s: CpuFeatureSet, i: usize) CpuFeatureSet {
    let mut r = s;
    unsafe r.w[i / 64] |= 1u64 << (i % 64) as u64;
    return r;
}

pub const fn join(a: CpuFeatureSet, b: CpuFeatureSet) CpuFeatureSet {
    return CpuFeatureSet { w: [a.w[0] | b.w[0], a.w[1] | b.w[1]] };
}

/// Whether `a` holds every feature of `b`.
pub const fn contains(a: CpuFeatureSet, b: CpuFeatureSet) bool {
    return (b.w[0] & ~a.w[0]) == 0 && (b.w[1] & ~a.w[1]) == 0;
}

pub const fn is_empty(s: CpuFeatureSet) bool {
    return (s.w[0] | s.w[1]) == 0;
}

/// The number of features in `s`.
pub const fn count(s: CpuFeatureSet) u32 {
    return (s.w[0].count_ones() + s.w[1].count_ones()) as u32;
}

/// `s` with every feature its members imply.
pub const fn close(s: CpuFeatureSet) CpuFeatureSet {
    let mut r = s;
    for i in 0..FEATURE_COUNT {
        if has(s, i) {
            r = join(r, unsafe IMPLIED[i]);
        }
    }
    return r;
}

/// The features of `s` beyond what every build for platform `target` has, on any instruction set: the
/// ones whose C flag the build passes.
pub const fn beyond_baseline(s: CpuFeatureSet, target: i32) CpuFeatureSet {
    let b = join(join(baseline(target, 0), baseline(target, 1)), baseline(target, 2));
    return CpuFeatureSet { w: [s.w[0] & ~b.w[0], s.w[1] & ~b.w[1]] };
}

/// The features every build for platform `target` (`PLATFORM_NAMES` index) and instruction set `arch`
/// has.
pub const fn baseline(target: i32, arch: i32) CpuFeatureSet {
    let t: []CpuFeature = CPU_FEATURES;
    let mut s = NONE;
    for i in 0..FEATURE_COUNT {
        if t[i].arch == arch && target >= 0 && (t[i].base >> target as u8 & 1) != 0 {
            s = with(s, i);
        }
    }
    return s;
}

/// The row named `name`, or -1.
pub const fn find(name: str) i32 {
    let t: []CpuFeature = CPU_FEATURES;
    for i in 0..FEATURE_COUNT {
        if t[i].name == name {
            return i as i32;
        }
    }
    return -1;
}

const ARCH_NAMES: [str<'static>; 3] = ["x86_64", "aarch64", "wasm32"];
const PLATFORM_NAMES: [str<'static>; 6] = ["windows", "macos", "linux", "wasm", "ios", "android"];

/// The row whose `cpu::Feature` variant is `name`, or -1.
pub const fn find_variant(name: str) i32 {
    let t: []CpuFeature = CPU_FEATURES;
    for i in 0..FEATURE_COUNT {
        if t[i].variant == name {
            return i as i32;
        }
    }
    return -1;
}

/// The feature names of instruction set `arch`, comma-separated, for a diagnostic.
fn names_of(arch: i32) String {
    let t: []CpuFeature = CPU_FEATURES;
    let mut out = String::new();
    for i in 0..FEATURE_COUNT {
        if t[i].arch == arch {
            if out.len() != 0 {
                out.push_str(", ");
            }
            out.push_str(t[i].name);
        }
    }
    return out;
}

/// Apply the comma list `spec` to `s` in order: `+name` or `name` enables, `-name` disables, for
/// platform `target` and instruction set `arch` (loader arch codes, -1 unknown). An unknown name, the
/// disabling of a baseline feature, or (when `strict`) a feature of another instruction set puts the
/// diagnostic in `err` and returns false; a lenient list skips another instruction set's features.
pub fn apply(spec: str, target: i32, arch: i32, strict: bool, s: &mut CpuFeatureSet, err: &mut String) bool {
    let t: []CpuFeature = CPU_FEATURES;
    let an: []str<'static> = ARCH_NAMES;
    let aname = if arch >= 0 {
        an[arch as usize];
    } else {
        "this instruction set";
    };
    let mut a: usize = 0;
    for i in 0..spec.len() + 1 {
        if i < spec.len() && spec.byte_at(i) != b',' {
            continue;
        }
        let item = spec.slice(a, i).trim();
        a = i + 1;
        if item.len() == 0 {
            continue;
        }
        let off = item.byte_at(0) == b'-';
        let name = item.slice(ast::pick(off || item.byte_at(0) == b'+', 1usize, 0), item.len());
        let k = find(name);
        if k >= 0 && t[k as usize].arch != arch && !strict {
            continue;
        }
        if k < 0 || t[k as usize].arch != arch {
            err.format_into("{} target feature '{}' for {}; ", ast::pick(k < 0, "unknown", "no"), name, aname);
            let names = names_of(arch);
            if names.len() == 0 {
                err.push_str("it has none");
            } else {
                err.format_into("the {} features are: {}", aname, names.as_str());
            }
            return false;
        }
        if !off && (target == 1 || target == 4) && (k as usize == F_SVE || k as usize == F_SVE2) {
            let pn: []str<'static> = PLATFORM_NAMES;
            err.format_into("target feature '{}' exists on no {} machine", name, pn[target as usize]);
            return false;
        }
        if off && has(baseline(target, arch), k as usize) {
            err.format_into("target feature '{}' is part of every {} build", name, aname);
            if t[k as usize].base != ALL {
                let pn: []str<'static> = PLATFORM_NAMES;
                err.format_into(" for {}", pn[target as usize]);
            }
            return false;
        }
        if off {
            unsafe s.w[k as usize / 64] &= ~(1u64 << (k % 64) as u64);
        } else {
            *s = with(*s, k as usize);
        }
    }
    return true;
}

/// The C flags of the features of `s` for platform `target`, in table order, each after a space. The
/// aarch64 features beyond the platform's baseline make one flag: on macOS `-mcpu=apple-m1` (a plain
/// `-march` lowers the tuning) and each extra extension; elsewhere `-march=` the lowest architecture
/// every feature's `level` allows (`armv8.2-a`, `armv8.1-a` or `armv8-a`), then each enabled extension
/// that architecture lacks.
pub fn push_c_flags(s: CpuFeatureSet, target: i32, out: &mut String) {
    let t: []CpuFeature = CPU_FEATURES;
    let b = baseline(target, 1);
    let mut extra = false;
    let mut need: u8 = 0;
    for i in 0..FEATURE_COUNT {
        if !has(s, i) || t[i].c_flag.len() == 0 {
            continue;
        }
        if t[i].arch != 1 {
            out.push_byte(b' ');
            out.push_str(t[i].c_flag);
            continue;
        }
        extra = extra || !has(b, i);
        need |= t[i].level;
    }
    if !extra {
        return;
    }
    let mac = target == 1;
    let v81 = !mac && (need & (L_NEED81 | L_NEED82)) != 0;
    out.push_str(
        if mac {
            " -mcpu=apple-m1";
        } else if (need & L_NEED82) != 0 {
            " -march=armv8.2-a";
        } else if v81 {
            " -march=armv8.1-a";
        } else {
            " -march=armv8-a";
        },
    );
    for i in 0..FEATURE_COUNT {
        let in_arch = mac && has(b, i) || v81 && (t[i].level & L_IN81) != 0;
        if has(s, i) && t[i].arch == 1 && t[i].c_flag.len() != 0 && !in_arch {
            out.push_str(t[i].c_flag);
        }
    }
}

/// One row of a package's backend table: a `@simd_impl` function `module`/`node` and its key, `op |
/// T << 16 | R << 24 | N << 32` (`ir::OP_*`, the vector operand's lane builtin `T` and lanes `N`,
/// the result's lane or scalar builtin `R`, the index lanes' for a run-time index), with the
/// feature set it needs.
pub struct SimdEntry {
    pub key: u64,
    pub fs: CpuFeatureSet,
    pub module: u16,
    pub node: u32,
    /// The entry calls a `@c.lane_access` binding: a build under a memory checker never plans it.
    pub lanes: bool,
}
