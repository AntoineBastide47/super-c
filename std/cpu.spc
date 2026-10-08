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
