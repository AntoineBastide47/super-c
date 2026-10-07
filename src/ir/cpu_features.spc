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
/// it implies (direct; `implied` closes them), the C compiler flag that enables it and the toolchain
/// probe that checks the flag (empty: none), and whether every build for the instruction set has it.
pub struct CpuFeature {
    pub name: str<'static>,
    pub variant: str<'static>,
    pub arch: i32,
    pub implies: CpuFeatureSet,
    pub c_flag: str<'static>,
    pub probe: str<'static>,
    pub baseline: bool,
}

pub const FEATURE_COUNT: usize = 4;
pub const F_SIMD128: usize = 0;
pub const F_RELAXED_SIMD: usize = 1;

const NONE: CpuFeatureSet = CpuFeatureSet { w: [0, 0] };

/// Append-only, in step with `std::cpu::Feature`.
pub const CPU_FEATURES: [CpuFeature; FEATURE_COUNT] = [
    CpuFeature {
        name: "simd128",
        variant: "Simd128",
        arch: 2,
        implies: NONE,
        c_flag: "-msimd128",
        probe: "wasm-simd128",
        baseline: false,
    },
    CpuFeature {
        name: "relaxed-simd",
        variant: "RelaxedSimd",
        arch: 2,
        implies: CpuFeatureSet { w: [1, 0] },
        c_flag: "-mrelaxed-simd",
        probe: "wasm-relaxed-simd",
        baseline: false,
    },
    CpuFeature { name: "sse2", variant: "Sse2", arch: 0, implies: NONE, c_flag: "", probe: "", baseline: true },
    CpuFeature { name: "neon", variant: "Neon", arch: 1, implies: NONE, c_flag: "", probe: "", baseline: true },
];

// Each row's implied set closed under `implies`, the row itself included: every pass adds the
// direct implications of the members, and FEATURE_COUNT passes reach any chain.
const fn closure() [CpuFeatureSet; FEATURE_COUNT] {
    let t: []CpuFeature = CPU_FEATURES;
    let mut c: [CpuFeatureSet; FEATURE_COUNT] = [NONE; FEATURE_COUNT];
    for i in 0..FEATURE_COUNT {
        unsafe c[i] = with(t[i].implies, i);
    }
    for _ in 0..FEATURE_COUNT {
        for i in 0..FEATURE_COUNT {
            for j in 0..FEATURE_COUNT {
                if has(unsafe c[i], j) {
                    unsafe c[i] = join(unsafe c[i], unsafe c[j]);
                }
            }
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

/// The features every build for instruction set `arch` has.
pub const fn baseline(arch: i32) CpuFeatureSet {
    let t: []CpuFeature = CPU_FEATURES;
    let mut s = NONE;
    for i in 0..FEATURE_COUNT {
        if t[i].arch == arch && t[i].baseline {
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
/// instruction set `arch` (loader arch codes, -1 unknown). An unknown name, the disabling of a
/// baseline feature, or (when `strict`) a feature of another instruction set puts the diagnostic in
/// `err` and returns false; a lenient list skips another instruction set's features.
pub fn apply(spec: str, arch: i32, strict: bool, s: &mut CpuFeatureSet, err: &mut String) bool {
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
        if off && t[k as usize].baseline {
            err.format_into("target feature '{}' is part of every {} build", name, aname);
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

/// The C flags of the features of `s`, in table order, each after a space.
pub fn push_c_flags(s: CpuFeatureSet, out: &mut String) {
    let t: []CpuFeature = CPU_FEATURES;
    for i in 0..FEATURE_COUNT {
        if has(s, i) && t[i].c_flag.len() != 0 {
            out.push_byte(b' ');
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
