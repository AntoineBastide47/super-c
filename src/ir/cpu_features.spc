// The CPU feature table: one row per feature the compiler knows, the source of truth for
// `std::cpu::Feature` (same order: a variant's discriminant is its row, which is its bit in a
// `CpuFeatureSet`). A feature selects instructions only: no language result depends on it.

import ast::ast as ast;
import utils::persist as *;

/// A set of features: bit `i` is row `i` of `CPU_FEATURES`. 128 features at most.
pub struct CpuFeatureSet {
    pub w: [u64; 2],
}

extend CpuFeatureSet as Persist {
    fn plain() bool {
        return true;
    }

    fn save(self: &CpuFeatureSet, w: &mut Writer) {
        save_bytes(self, w);
    }

    fn load(self: &mut CpuFeatureSet, r: &mut Reader) {
        load_bytes(self, r);
    }
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

pub const FEATURE_COUNT: usize = 52;
pub const F_SIMD128: usize = 0;
pub const F_RELAXED_SIMD: usize = 1;
pub const F_SSE2: usize = 2;
pub const F_NEON: usize = 3;
pub const F_DOTPROD: usize = 5;
pub const F_SVE: usize = 14;
pub const F_SVE2: usize = 15;
pub const F_AVX: usize = 23;
pub const F_AVX512F: usize = 31;

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
// The x86-64 psABI levels beyond the baseline (`x86-64`, SSE2): `x86-64-v2` adds rows 16 to 22,
// `x86-64-v3` rows 23 to 30, `x86-64-v4` rows 31 to 35 (AVX-512 F, BW, CD, DQ, VL).
const X2: u64 = 0x7F << 16;
const X3: u64 = X2 | 0xFF << 23;
const X4: u64 = X3 | 0x1F << 31;
const X_LEVELS: [u64; 4] = [0, X2, X3, X4];
// The x86 platform baselines: macOS and the iOS simulator (`core2`: Apple clang's default `penryn` adds
// SSE4.1, but GCC on Darwin and clang for deployment targets before 10.12 stop at `core2`), and Android
// (its ABI: SSE4.2 and POPCNT).
const XMI: u8 = 50;
const XA: u8 = 32;
const fn x(m: u64) CpuFeatureSet {
    return CpuFeatureSet { w: [m, 0] };
}

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
    CpuFeature {
        name: "sse3",
        variant: "Sse3",
        arch: 0,
        implies: x(1 << 2),
        c_flag: "-msse3",
        probe: "x86-features",
        base: XMI,
        level: 0,
    },
    CpuFeature {
        name: "ssse3",
        variant: "Ssse3",
        arch: 0,
        implies: x(1 << 16),
        c_flag: "-mssse3",
        probe: "x86-features",
        base: XMI,
        level: 0,
    },
    CpuFeature {
        name: "sse4.1",
        variant: "Sse41",
        arch: 0,
        implies: x(1 << 17),
        c_flag: "-msse4.1",
        probe: "x86-features",
        base: XA,
        level: 0,
    },
    CpuFeature {
        name: "sse4.2",
        variant: "Sse42",
        arch: 0,
        implies: x(1 << 18 | 1 << 20), // GCC's `-msse4.2` enables `popcnt` too
        c_flag: "-msse4.2",
        probe: "x86-features",
        base: XA,
        level: 0,
    },
    CpuFeature {
        name: "popcnt",
        variant: "Popcnt",
        arch: 0,
        implies: NONE,
        c_flag: "-mpopcnt",
        probe: "x86-features",
        base: XA,
        level: 0,
    },
    CpuFeature {
        name: "cx16",
        variant: "Cx16",
        arch: 0,
        implies: NONE,
        c_flag: "-mcx16",
        probe: "x86-features",
        base: XMI,
        level: 0,
    },
    CpuFeature {
        name: "lahf-sahf",
        variant: "LahfSahf",
        arch: 0,
        implies: NONE,
        c_flag: "-msahf",
        probe: "x86-features",
        base: APPLE,
        level: 0,
    },
    CpuFeature {
        name: "avx",
        variant: "Avx",
        arch: 0,
        implies: x(1 << 19),
        c_flag: "-mavx",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "avx2",
        variant: "Avx2",
        arch: 0,
        implies: x(1 << 23),
        c_flag: "-mavx2",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "fma",
        variant: "Fma",
        arch: 0,
        implies: x(1 << 23),
        c_flag: "-mfma",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "bmi1",
        variant: "Bmi1",
        arch: 0,
        implies: NONE,
        c_flag: "-mbmi",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "bmi2",
        variant: "Bmi2",
        arch: 0,
        implies: NONE,
        c_flag: "-mbmi2",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "f16c",
        variant: "F16c",
        arch: 0,
        implies: x(1 << 23),
        c_flag: "-mf16c",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "lzcnt",
        variant: "Lzcnt",
        arch: 0,
        implies: NONE,
        c_flag: "-mlzcnt",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "movbe",
        variant: "Movbe",
        arch: 0,
        implies: NONE,
        c_flag: "-mmovbe",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "avx512f",
        variant: "Avx512f",
        arch: 0,
        implies: x(1 << 24 | 1 << 25 | 1 << 28),
        c_flag: "-mavx512f",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "avx512bw",
        variant: "Avx512bw",
        arch: 0,
        implies: x(1u64 << 31),
        c_flag: "-mavx512bw",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "avx512cd",
        variant: "Avx512cd",
        arch: 0,
        implies: x(1u64 << 31),
        c_flag: "-mavx512cd",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "avx512dq",
        variant: "Avx512dq",
        arch: 0,
        implies: x(1u64 << 31),
        c_flag: "-mavx512dq",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "avx512vl",
        variant: "Avx512vl",
        arch: 0,
        implies: x(1u64 << 31),
        c_flag: "-mavx512vl",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "avx512vbmi",
        variant: "Avx512vbmi",
        arch: 0,
        implies: x(1u64 << 32),
        c_flag: "-mavx512vbmi",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "avx512vbmi2",
        variant: "Avx512vbmi2",
        arch: 0,
        implies: x(1u64 << 32),
        c_flag: "-mavx512vbmi2",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "avx512bitalg",
        variant: "Avx512bitalg",
        arch: 0,
        implies: x(1u64 << 32),
        c_flag: "-mavx512bitalg",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "avx512vpopcntdq",
        variant: "Avx512vpopcntdq",
        arch: 0,
        implies: x(1u64 << 31),
        c_flag: "-mavx512vpopcntdq",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "avx512vnni",
        variant: "Avx512vnni",
        arch: 0,
        implies: x(1u64 << 31),
        c_flag: "-mavx512vnni",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "avx512fp16",
        variant: "Avx512fp16",
        arch: 0,
        implies: x(1u64 << 32),
        c_flag: "-mavx512fp16",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "gfni",
        variant: "Gfni",
        arch: 0,
        implies: x(1 << 2),
        c_flag: "-mgfni",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "vaes",
        variant: "Vaes",
        arch: 0,
        implies: x(1u64 << 24 | 1u64 << 45),
        c_flag: "-mvaes",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "vpclmulqdq",
        variant: "Vpclmulqdq",
        arch: 0,
        implies: x(1u64 << 23 | 1u64 << 46),
        c_flag: "-mvpclmulqdq",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "aes",
        variant: "Aesni",
        arch: 0,
        implies: x(1 << 2),
        c_flag: "-maes",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "pclmulqdq",
        variant: "Pclmulqdq",
        arch: 0,
        implies: x(1 << 2),
        c_flag: "-mpclmul",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    // AVX10 has no 256-bit-only form: `avx10.1` is `x86-64-v4` with the AVX-512 extensions above.
    CpuFeature {
        name: "avx10.1",
        variant: "Avx101",
        arch: 0,
        implies: x(X4 | 0x3Fu64 << 36),
        c_flag: "-mavx10.1",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    CpuFeature {
        name: "avx10.2",
        variant: "Avx102",
        arch: 0,
        implies: x(1u64 << 47),
        c_flag: "-mavx10.2",
        probe: "x86-features",
        base: 0,
        level: 0,
    },
    // The Scalable Matrix Extension: the ZA tiles, outer products and streaming SVE mode. Code that
    // uses it enters streaming mode itself (a C kernel's `__arm_locally_streaming`); outside it, a core
    // may have no SVE at all (Apple M4 and M5).
    CpuFeature {
        name: "sme",
        variant: "Sme",
        arch: 1,
        implies: V82,
        c_flag: "+sme",
        probe: "aarch64-features",
        base: 0,
        level: L_NEED82,
    },
    CpuFeature {
        name: "sme2",
        variant: "Sme2",
        arch: 1,
        implies: CpuFeatureSet { w: [1u64 << 49, 0] },
        c_flag: "+sme2",
        probe: "aarch64-features",
        base: 0,
        level: L_NEED82,
    },
    CpuFeature {
        name: "sme-f64f64",
        variant: "SmeF64f64",
        arch: 1,
        implies: CpuFeatureSet { w: [1u64 << 49, 0] },
        c_flag: "+sme-f64f64",
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

/// The row named `name`, of instruction set `arch` when one is (`aes` names one on x86_64 and one on
/// aarch64), or -1.
pub const fn find(name: str, arch: i32) i32 {
    let t: []CpuFeature = CPU_FEATURES;
    let mut r: i32 = -1;
    for i in 0..FEATURE_COUNT {
        if t[i].name == name && (r < 0 || t[i].arch == arch) {
            r = i as i32;
        }
    }
    return r;
}

/// Add the features of x86-64 level `name` (`x86-64`, `x86-64-v2`, `x86-64-v3`, `x86-64-v4`; empty:
/// none) to `s` (`--target-cpu`, the `target-cpu` key, a level in a feature list). Another instruction
/// set skips a level, unless `strict` (the command line); another name is an error. On an error the
/// diagnostic goes to `err` and the result is false.
pub fn level(name: str, arch: i32, strict: bool, s: &mut CpuFeatureSet, err: &mut String) bool {
    let ns: []str<'static> = ["x86-64", "x86-64-v2", "x86-64-v3", "x86-64-v4"];
    let xl: []u64 = X_LEVELS;
    for i in 0..4 {
        if ns[i] == name {
            if arch == 0 {
                *s = join(*s, x(xl[i]));
            } else if strict {
                err.format_into(
                    "target CPU '{}' is an x86_64 level; the build is for {}",
                    name,
                    unsafe ARCH_NAMES[arch as usize],
                );
                return false;
            }
            return true;
        }
    }
    if name.len() == 0 {
        return true;
    }
    err.format_into("unknown target CPU '{}'; the x86_64 levels are: x86-64, x86-64-v2, x86-64-v3, x86-64-v4", name);
    return false;
}

/// Whether `spec` is a `--simd-dispatch` / `simd-dispatch` value: `off`, or x86-64 level names
/// separated by commas; else the diagnostic goes to `err`.
pub fn dispatch_ok(spec: str, err: &mut String) bool {
    if spec == "off" {
        return true;
    }
    let mut at: usize = 0;
    while at <= spec.len() {
        let mut end = at;
        while end < spec.len() && spec[end] != b',' {
            end += 1;
        }
        let mut s = CpuFeatureSet { w: [0, 0] };
        if end == at || !level(spec.slice(at, end), 0, true, &mut s, err) {
            if err.len() == 0 {
                err.push_str("an empty level");
            }
            err.insert_str(0, "simd dispatch: ");
            err.push_str(" (or `off`)");
            return false;
        }
        at = end + 1;
    }
    return true;
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

/// Apply the comma list `spec` to `s` in order: `+name` or `name` enables, `-name` disables, a level
/// name (`x86-64-v3`) enables the level's features, for
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
        if item.starts_with("x86-64") {
            // A level: its features.
            if !level(item, arch, strict, s, err) {
                return false;
            }
            continue;
        }
        let off = item.byte_at(0) == b'-';
        let name = item.slice(ast::pick(off || item.byte_at(0) == b'+', 1usize, 0), item.len());
        let k = find(name, arch);
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
/// x86_64 features beyond the platform's baseline make `-march=x86-64-vN` for the largest level they
/// hold, then `-m<feature>` for each other one. The
/// aarch64 features beyond the platform's baseline make one flag: on macOS `-mcpu=apple-m1` (a plain
/// `-march` lowers the tuning) and each extra extension; elsewhere `-march=` the lowest architecture
/// every feature's `level` allows (`armv8.2-a`, `armv8.1-a` or `armv8-a`), then each enabled extension
/// that architecture lacks.
pub fn push_c_flags(s: CpuFeatureSet, target: i32, out: &mut String) {
    let t: []CpuFeature = CPU_FEATURES;
    let b = baseline(target, 1);
    // x86_64: `-march=` the largest psABI level the features beyond the baseline reach, then the
    // flag of each other feature beyond it.
    let xb = baseline(target, 0).w[0];
    let xl: []u64 = X_LEVELS;
    let mut lv: usize = 3;
    while lv > 0 && ((s.w[0] & xl[lv]) != xl[lv] || (xl[lv] & ~xb) == 0) {
        lv -= 1;
    }
    if lv > 0 {
        out.format_into(" -march=x86-64-v{}", lv + 1);
    }
    let mut extra = false;
    let mut need: u8 = 0;
    for i in 0..FEATURE_COUNT {
        if !has(s, i) || t[i].c_flag.len() == 0 || t[i].arch == 0 && has(x(xb | xl[lv]), i) {
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

/// The C `target` attribute argument of a function whose effective features are `s` (closed) in a
/// build of features `build` for platform `target`, for each of `s`'s features the build lacks;
/// nothing when it lacks none. x86_64: `target("sse4.2,avx,avx2")`, the flags' names. aarch64:
/// clang adds `+dotprod`; GCC names the architecture level of the build flag for `s` too
/// (binutils assembles an extension only at its level; `SC_TGT_A64` of the runtime header chooses).
pub fn push_target_attr(s: CpuFeatureSet, build: CpuFeatureSet, target: i32, out: &mut String) {
    let t: []CpuFeature = CPU_FEATURES;
    let mut a64 = false;
    let mut names = String::new();
    for i in 0..FEATURE_COUNT {
        if !has(s, i) || has(build, i) || t[i].c_flag.len() == 0 {
            continue;
        }
        a64 = t[i].arch == 1;
        if !a64 && names.len() != 0 {
            names.push_byte(b',');
        }
        names.push_str(t[i].c_flag.slice(ast::pick(a64, 0usize, 2usize), t[i].c_flag.len()));
    }
    if names.len() == 0 {
        return;
    }
    if !a64 {
        out.format_into("target(\"{}\")", names.as_str());
        return;
    }
    let mut g = String::new();
    push_c_flags(CpuFeatureSet { w: [s.w[0] & arch_mask(1), s.w[1]] }, target, &mut g);
    out.format_into("target(SC_TGT_A64(\"{}\", \"{}\"))", names.as_str(), g.as_str().slice(3, g.len()));
}

// The rows of instruction set `arch`, as a mask of the first word.
const fn arch_mask(arch: i32) u64 {
    let t: []CpuFeature = CPU_FEATURES;
    let mut m: u64 = 0;
    for i in 0..FEATURE_COUNT {
        if t[i].arch == arch {
            m |= 1u64 << i as u64;
        }
    }
    return m;
}

/// One row of a package's backend table: a `@simd_impl` function `module`/`node` and its key, `op |
/// T << 16 | R << 24 | N << 32` (`ir::OP_*`, the vector operand's lane builtin `T` and lanes `N`,
/// the result's lane or scalar builtin `R`, the index lanes' for a run-time index), with the
/// feature set it needs, closed under `implies`.
pub struct SimdEntry {
    pub key: u64,
    pub fs: CpuFeatureSet,
    pub module: u16,
    pub node: u32,
    /// The entry calls a `@c.lane_access` binding: a build under a memory checker never plans it.
    pub lanes: bool,
}
