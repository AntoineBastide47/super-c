// The CPU features a build can enable (`--target-feature`, the `target-features` key of build.toml),
// and sets of them. A feature selects instructions only: no result of the language depends on it.
// `std::cpu::detect` reads the features of the machine a program runs on and of the build.

/// One CPU feature. A variant's discriminant is its row in the compiler's feature table, which is the
/// source of truth for the order and the names.
pub enum Feature {
    /// WebAssembly 128-bit SIMD (wasm32; spelled `simd128`).
    Simd128,
    /// WebAssembly relaxed SIMD (wasm32; `relaxed-simd`; implies `simd128`). Its results can differ
    /// between engines.
    RelaxedSimd,
    /// SSE2 (x86_64; `sse2`; every x86_64 build has it).
    Sse2,
    /// Advanced SIMD (aarch64; `neon`; every aarch64 build has it).
    Neon,
    /// Half-precision arithmetic (aarch64; `fp16`; every macOS build has it).
    Fp16,
    /// The 8-bit dot products `sdot`/`udot` (aarch64; `dotprod`; every macOS build has it).
    Dotprod,
    /// Rounding doubling multiply-accumulate `sqrdmlah`/`sqrdmlsh` (aarch64; `rdm`; every macOS build
    /// has it).
    Rdm,
    /// The 8-bit matrix multiplies `smmla`/`ummla`/`usmmla` (aarch64; `i8mm`).
    I8mm,
    /// Brain floating point (aarch64; `bf16`).
    Bf16,
    /// The AES rounds (aarch64; `aes`; every macOS and iOS build has it).
    Aes,
    /// The SHA-256 rounds (aarch64; `sha2`; every macOS and iOS build has it).
    Sha2,
    /// The SHA-3 helpers `eor3`/`rax1`/`xar`/`bcax` (aarch64; `sha3`; every macOS build has it).
    Sha3,
    /// The CRC-32 instructions (aarch64; `crc`; every macOS build has it).
    Crc,
    /// The Armv8.1 atomics (aarch64; `lse`; every macOS build has it).
    Lse,
    /// The Scalable Vector Extension (aarch64; `sve`; implies `fp16`): detected only.
    Sve,
    /// SVE2 (aarch64; `sve2`; implies `sve`): detected only.
    Sve2,
    /// SSE3 (x86_64; `sse3`).
    Sse3,
    /// SSSE3 (x86_64; `ssse3`).
    Ssse3,
    /// SSE4.1 (x86_64; `sse4.1`).
    Sse41,
    /// SSE4.2 (x86_64; `sse4.2`).
    Sse42,
    /// POPCNT (x86_64; `popcnt`).
    Popcnt,
    /// The 16-byte compare-exchange `cmpxchg16b` (x86_64; `cx16`).
    Cx16,
    /// LAHF and SAHF in 64-bit mode (x86_64; `lahf-sahf`).
    LahfSahf,
    /// AVX (x86_64; `avx`).
    Avx,
    /// AVX2 (x86_64; `avx2`).
    Avx2,
    /// The fused multiply-add FMA3 (x86_64; `fma`).
    Fma,
    /// BMI1 (x86_64; `bmi1`).
    Bmi1,
    /// BMI2 (x86_64; `bmi2`).
    Bmi2,
    /// The half-precision conversions F16C (x86_64; `f16c`).
    F16c,
    /// LZCNT (x86_64; `lzcnt`).
    Lzcnt,
    /// MOVBE (x86_64; `movbe`).
    Movbe,
    /// AVX-512 Foundation (x86_64; `avx512f`).
    Avx512f,
    /// AVX-512 byte and word lanes (x86_64; `avx512bw`).
    Avx512bw,
    /// AVX-512 conflict detection (x86_64; `avx512cd`).
    Avx512cd,
    /// AVX-512 doubleword and quadword (x86_64; `avx512dq`).
    Avx512dq,
    /// AVX-512 at 128 and 256 bits (x86_64; `avx512vl`).
    Avx512vl,
    /// AVX-512 byte permutes (x86_64; `avx512vbmi`).
    Avx512vbmi,
    /// AVX-512 compress and shift of bytes and words (x86_64; `avx512vbmi2`).
    Avx512vbmi2,
    /// AVX-512 bit algorithms (x86_64; `avx512bitalg`).
    Avx512bitalg,
    /// AVX-512 population count of 32 and 64-bit lanes (x86_64; `avx512vpopcntdq`).
    Avx512vpopcntdq,
    /// AVX-512 vector neural network instructions (x86_64; `avx512vnni`).
    Avx512vnni,
    /// AVX-512 half precision (x86_64; `avx512fp16`).
    Avx512fp16,
    /// Galois field instructions (x86_64; `gfni`).
    Gfni,
    /// The AES rounds on 256 and 512 bits (x86_64; `vaes`).
    Vaes,
    /// The carry-less multiply on 256 and 512 bits (x86_64; `vpclmulqdq`).
    Vpclmulqdq,
    /// The AES rounds AES-NI (x86_64; `aes`).
    Aesni,
    /// The carry-less multiply (x86_64; `pclmulqdq`).
    Pclmulqdq,
    /// AVX10.1: `x86-64-v4` and the AVX-512 extensions (x86_64; `avx10.1`).
    Avx101,
    /// AVX10.2 (x86_64; `avx10.2`).
    Avx102,
    /// The Scalable Matrix Extension: ZA tiles, outer products, streaming SVE mode (aarch64; `sme`).
    Sme,
    /// SME2: multi-vector forms over ZA (aarch64; `sme2`; implies `sme`).
    Sme2,
    /// SME outer products of `f64` lanes (aarch64; `sme-f64f64`; implies `sme`).
    SmeF64f64,
}

/// The x86-64 psABI level `x86-64-v2` beyond the baseline (`@target_feature(cpu::X86_64_V2)`).
pub const X86_64_V2: [Feature; 7] = [
    Feature::Sse3,
    Feature::Ssse3,
    Feature::Sse41,
    Feature::Sse42,
    Feature::Popcnt,
    Feature::Cx16,
    Feature::LahfSahf,
];
/// `x86-64-v3`: `x86-64-v2` and AVX2.
pub const X86_64_V3: [Feature; 15] = [
    Feature::Sse3,
    Feature::Ssse3,
    Feature::Sse41,
    Feature::Sse42,
    Feature::Popcnt,
    Feature::Cx16,
    Feature::LahfSahf,
    Feature::Avx,
    Feature::Avx2,
    Feature::Fma,
    Feature::Bmi1,
    Feature::Bmi2,
    Feature::F16c,
    Feature::Lzcnt,
    Feature::Movbe,
];
/// `x86-64-v4`: `x86-64-v3` and the AVX-512 F, BW, CD, DQ and VL subsets.
pub const X86_64_V4: [Feature; 20] = [
    Feature::Sse3,
    Feature::Ssse3,
    Feature::Sse41,
    Feature::Sse42,
    Feature::Popcnt,
    Feature::Cx16,
    Feature::LahfSahf,
    Feature::Avx,
    Feature::Avx2,
    Feature::Fma,
    Feature::Bmi1,
    Feature::Bmi2,
    Feature::F16c,
    Feature::Lzcnt,
    Feature::Movbe,
    Feature::Avx512f,
    Feature::Avx512bw,
    Feature::Avx512cd,
    Feature::Avx512dq,
    Feature::Avx512vl,
];

/// An x86-64 psABI level (`std::cpu::detect::has_level`).
pub enum Level {
    V2,
    V3,
    V4,
}

extend Level {
    /// The level's features beyond the baseline.
    pub const fn features(self: Level) []'static Feature {
        return switch self {
            V2 => X86_64_V2,
            V3 => X86_64_V3,
            V4 => X86_64_V4,
        };
    }
}

/// A set of features: bit `i` of `bits` is the variant of discriminant `i`.
pub struct CpuFeatures {
    pub bits: [u64; 2],
}

extend CpuFeatures {
    /// Whether the set holds `f`.
    pub const fn has(self: &Self, f: Feature) bool {
        let i = f as u64;
        return (unsafe self.bits[(i / 64) as usize] >> i % 64 & 1) != 0;
    }

    /// Whether the set holds every feature of `o`.
    pub const fn contains(self: &Self, o: CpuFeatures) bool {
        return (o.bits[0] & ~self.bits[0]) == 0 && (o.bits[1] & ~self.bits[1]) == 0;
    }
}
