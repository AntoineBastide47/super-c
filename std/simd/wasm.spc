// WebAssembly SIMD operations with no portable meaning, over the portable vector types. Each needs
// the feature it names (`--target-feature=+relaxed-simd` or `+simd128`): a call without it is a
// compile error. The relaxed operations' results can differ between engines; std's portable
// operations never use them. Each calls a C intrinsic, so no constant has its value.
import std::cpu;
import std::simd;
import wasm_simd128 as *;

// The register a vector's 128 bits fill.
@arch(wasm32)
@target_feature([cpu::Feature::Simd128])
fn reg<T: SimdElement, const N: usize>(x: Simd<T, N>) v128_t {
    return unsafe wasm_v128_load((&x) as *const Simd<T, N>);
}

// The vector of a register's 128 bits.
@arch(wasm32)
@target_feature([cpu::Feature::Simd128])
fn vec<T: SimdElement, const N: usize>(r: v128_t) Simd<T, N> {
    let mut x = unsafe zeroed::<Simd<T, N>>();
    unsafe wasm_v128_store((&mut x) as *mut Simd<T, N>, r);
    return x;
}

/// `a * b + c` per lane, rounded once or twice as the engine chooses.
@arch(wasm32)
@target_feature([cpu::Feature::RelaxedSimd])
pub fn relaxed_madd_f32x4(a: f32x4, b: f32x4, c: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_relaxed_madd(reg(a), reg(b), reg(c)));
}

/// `a * b + c` per lane, rounded once or twice as the engine chooses.
@arch(wasm32)
@target_feature([cpu::Feature::RelaxedSimd])
pub fn relaxed_madd_f64x2(a: f64x2, b: f64x2, c: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_relaxed_madd(reg(a), reg(b), reg(c)));
}

/// `-(a * b) + c` per lane, rounded once or twice as the engine chooses.
@arch(wasm32)
@target_feature([cpu::Feature::RelaxedSimd])
pub fn relaxed_nmadd_f32x4(a: f32x4, b: f32x4, c: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_relaxed_nmadd(reg(a), reg(b), reg(c)));
}

/// `-(a * b) + c` per lane, rounded once or twice as the engine chooses.
@arch(wasm32)
@target_feature([cpu::Feature::RelaxedSimd])
pub fn relaxed_nmadd_f64x2(a: f64x2, b: f64x2, c: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_relaxed_nmadd(reg(a), reg(b), reg(c)));
}

/// The smaller lane; with a NaN or two zeros of different signs, either operand's lane.
@arch(wasm32)
@target_feature([cpu::Feature::RelaxedSimd])
pub fn relaxed_min_f32x4(a: f32x4, b: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_relaxed_min(reg(a), reg(b)));
}

/// The smaller lane; with a NaN or two zeros of different signs, either operand's lane.
@arch(wasm32)
@target_feature([cpu::Feature::RelaxedSimd])
pub fn relaxed_min_f64x2(a: f64x2, b: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_relaxed_min(reg(a), reg(b)));
}

/// The larger lane; with a NaN or two zeros of different signs, either operand's lane.
@arch(wasm32)
@target_feature([cpu::Feature::RelaxedSimd])
pub fn relaxed_max_f32x4(a: f32x4, b: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_relaxed_max(reg(a), reg(b)));
}

/// The larger lane; with a NaN or two zeros of different signs, either operand's lane.
@arch(wasm32)
@target_feature([cpu::Feature::RelaxedSimd])
pub fn relaxed_max_f64x2(a: f64x2, b: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_relaxed_max(reg(a), reg(b)));
}

/// Lane `i` is `a[idx[i]]` for an index below 16, 0 for one from 128, either for the others.
@arch(wasm32)
@target_feature([cpu::Feature::RelaxedSimd])
pub fn relaxed_swizzle(a: u8x16, idx: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_i8x16_relaxed_swizzle(reg(a), reg(idx)));
}

/// Each lane truncated toward zero; a NaN or a lane past `i32` gives an engine's choice.
@arch(wasm32)
@target_feature([cpu::Feature::RelaxedSimd])
pub fn relaxed_trunc(a: f32x4) i32x4 {
    return vec::<i32, 4>(wasm_i32x4_relaxed_trunc_f32x4(reg(a)));
}

/// Lane `i` is `c[i]` plus the products of lanes `4i` to `4i + 3` of `a` and `b`, `b`'s lanes from 0
/// to 127 (a lane with its top bit set gives an engine's choice).
@arch(wasm32)
@target_feature([cpu::Feature::RelaxedSimd])
pub fn relaxed_dot_i8x16_i7x16_add(a: i8x16, b: i8x16, c: i32x4) i32x4 {
    return vec::<i32, 4>(wasm_i32x4_relaxed_dot_i8x16_i7x16_add(reg(a), reg(b), reg(c)));
}

/// `b[i] < a[i] ? b[i] : a[i]`: WebAssembly's pseudo-minimum.
@arch(wasm32)
@target_feature([cpu::Feature::Simd128])
pub fn pmin_f32x4(a: f32x4, b: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_pmin(reg(a), reg(b)));
}

/// `b[i] < a[i] ? b[i] : a[i]`: WebAssembly's pseudo-minimum.
@arch(wasm32)
@target_feature([cpu::Feature::Simd128])
pub fn pmin_f64x2(a: f64x2, b: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_pmin(reg(a), reg(b)));
}

/// `a[i] < b[i] ? b[i] : a[i]`: WebAssembly's pseudo-maximum.
@arch(wasm32)
@target_feature([cpu::Feature::Simd128])
pub fn pmax_f32x4(a: f32x4, b: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_pmax(reg(a), reg(b)));
}

/// `a[i] < b[i] ? b[i] : a[i]`: WebAssembly's pseudo-maximum.
@arch(wasm32)
@target_feature([cpu::Feature::Simd128])
pub fn pmax_f64x2(a: f64x2, b: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_pmax(reg(a), reg(b)));
}

/// The Q15 product of each lane pair, rounded: `(a * b + 0x4000) >> 15`, saturated to `i16`.
@arch(wasm32)
@target_feature([cpu::Feature::Simd128])
pub fn q15mulr_sat(a: i16x8, b: i16x8) i16x8 {
    return vec::<i16, 8>(wasm_i16x8_q15mulr_sat(reg(a), reg(b)));
}

/// Lane `i` is `a[2i] * b[2i] + a[2i + 1] * b[2i + 1]`, wrapped to `i32`.
@arch(wasm32)
@target_feature([cpu::Feature::Simd128])
pub fn dot_i16x8(a: i16x8, b: i16x8) i32x4 {
    return vec::<i32, 4>(wasm_i32x4_dot_i16x8(reg(a), reg(b)));
}
