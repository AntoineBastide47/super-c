// The CPU features a build can enable (`--target-feature`, the `target-features` key of build.toml).
// A feature selects instructions only: no result of the language depends on it.

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
}
