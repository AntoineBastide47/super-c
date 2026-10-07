// FFI bindings for <wasm_simd128.h>: the WebAssembly SIMD128 register type and the intrinsics
// std/simd/backend/wasm.spc and std/simd/wasm.spc call, and every lane load and store. Each needs
// SIMD128 (`--target-feature=+simd128`), a relaxed one relaxed SIMD; an access through a pointer
// states its range.
import std::cpu;

extern "C" "wasm_simd128.h" {
    /// A 128-bit SIMD register.
    @arch(wasm32)
    @c.value(16, 16)
    pub type v128_t;

    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_abs(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_add(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_ceil(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_convert_i32x4(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_convert_u32x4(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_demote_f64x2_zero(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_div(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_eq(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    pub fn wasm_f32x4_extract_lane(a: v128_t, i: i32) f32;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_floor(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_ge(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_gt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_le(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_lt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_max(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_min(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_mul(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_ne(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_nearest(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_neg(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_pmax(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_pmin(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::RelaxedSimd])
    @unsafe(safe)
    pub fn wasm_f32x4_relaxed_madd(a: v128_t, b: v128_t, c: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::RelaxedSimd])
    @unsafe(safe)
    pub fn wasm_f32x4_relaxed_max(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::RelaxedSimd])
    @unsafe(safe)
    pub fn wasm_f32x4_relaxed_min(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::RelaxedSimd])
    @unsafe(safe)
    pub fn wasm_f32x4_relaxed_nmadd(a: v128_t, b: v128_t, c: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_sqrt(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_sub(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f32x4_trunc(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_abs(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_add(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_ceil(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_convert_low_i32x4(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_convert_low_u32x4(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_div(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_eq(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    pub fn wasm_f64x2_extract_lane(a: v128_t, i: i32) f64;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_floor(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_ge(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_gt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_le(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_lt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_max(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_min(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_mul(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_ne(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_nearest(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_neg(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_pmax(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_pmin(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_promote_low_f32x4(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::RelaxedSimd])
    @unsafe(safe)
    pub fn wasm_f64x2_relaxed_madd(a: v128_t, b: v128_t, c: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::RelaxedSimd])
    @unsafe(safe)
    pub fn wasm_f64x2_relaxed_max(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::RelaxedSimd])
    @unsafe(safe)
    pub fn wasm_f64x2_relaxed_min(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::RelaxedSimd])
    @unsafe(safe)
    pub fn wasm_f64x2_relaxed_nmadd(a: v128_t, b: v128_t, c: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_sqrt(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_sub(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_f64x2_trunc(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_abs(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_add(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_add_sat(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_all_true(a: v128_t) bool;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_bitmask(a: v128_t) u32;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_eq(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_extend_high_i8x16(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_extend_low_i8x16(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_extmul_high_i8x16(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_extmul_low_i8x16(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    pub fn wasm_i16x8_extract_lane(a: v128_t, i: i32) i16;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_ge(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_gt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_le(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_lt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_max(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_min(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_mul(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_narrow_i32x4(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_ne(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_neg(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_q15mulr_sat(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_shl(a: v128_t, b: u32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_shr(a: v128_t, b: u32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    pub fn wasm_i16x8_shuffle(
        a: v128_t,
        b: v128_t,
        c0: i32,
        c1: i32,
        c2: i32,
        c3: i32,
        c4: i32,
        c5: i32,
        c6: i32,
        c7: i32,
    ) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_splat(a: i16) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_sub(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i16x8_sub_sat(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_abs(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_add(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_all_true(a: v128_t) bool;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_bitmask(a: v128_t) u32;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_dot_i16x8(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_eq(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_extend_high_i16x8(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_extend_low_i16x8(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_extmul_high_i16x8(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_extmul_low_i16x8(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    pub fn wasm_i32x4_extract_lane(a: v128_t, i: i32) i32;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_ge(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_gt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_le(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_lt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_max(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_min(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_mul(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_ne(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_neg(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::RelaxedSimd])
    @unsafe(safe)
    pub fn wasm_i32x4_relaxed_dot_i8x16_i7x16_add(a: v128_t, b: v128_t, c: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::RelaxedSimd])
    @unsafe(safe)
    pub fn wasm_i32x4_relaxed_trunc_f32x4(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_shl(a: v128_t, b: u32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_shr(a: v128_t, b: u32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    pub fn wasm_i32x4_shuffle(a: v128_t, b: v128_t, c0: i32, c1: i32, c2: i32, c3: i32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_splat(a: i32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_sub(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_trunc_sat_f32x4(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i32x4_trunc_sat_f64x2_zero(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_abs(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_add(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_all_true(a: v128_t) bool;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_bitmask(a: v128_t) u32;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_eq(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_extend_high_i32x4(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_extend_low_i32x4(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_extmul_high_i32x4(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_extmul_low_i32x4(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    pub fn wasm_i64x2_extract_lane(a: v128_t, i: i32) i64;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_ge(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_gt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_le(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_lt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_mul(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_ne(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_neg(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_shl(a: v128_t, b: u32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_shr(a: v128_t, b: u32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    pub fn wasm_i64x2_shuffle(a: v128_t, b: v128_t, c0: i32, c1: i32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_splat(a: i64) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i64x2_sub(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_abs(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_add(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_add_sat(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_all_true(a: v128_t) bool;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_bitmask(a: v128_t) u32;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_eq(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    pub fn wasm_i8x16_extract_lane(a: v128_t, i: i32) i8;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_ge(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_gt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_le(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_lt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_max(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_min(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_narrow_i16x8(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_ne(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_neg(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_popcnt(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::RelaxedSimd])
    @unsafe(safe)
    pub fn wasm_i8x16_relaxed_swizzle(a: v128_t, s: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_shl(a: v128_t, b: u32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_shr(a: v128_t, b: u32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    pub fn wasm_i8x16_shuffle(
        a: v128_t,
        b: v128_t,
        c0: i32,
        c1: i32,
        c2: i32,
        c3: i32,
        c4: i32,
        c5: i32,
        c6: i32,
        c7: i32,
        c8: i32,
        c9: i32,
        c10: i32,
        c11: i32,
        c12: i32,
        c13: i32,
        c14: i32,
        c15: i32,
    ) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_sub(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_sub_sat(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_i8x16_swizzle(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u16x8_add_sat(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u16x8_extend_high_u8x16(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u16x8_extend_low_u8x16(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u16x8_extmul_high_u8x16(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u16x8_extmul_low_u8x16(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    pub fn wasm_u16x8_extract_lane(a: v128_t, i: i32) u16;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u16x8_ge(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u16x8_gt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u16x8_le(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u16x8_lt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u16x8_max(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u16x8_min(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u16x8_narrow_i32x4(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u16x8_shr(a: v128_t, b: u32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u16x8_sub_sat(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u32x4_extend_high_u16x8(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u32x4_extend_low_u16x8(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u32x4_extmul_high_u16x8(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u32x4_extmul_low_u16x8(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    pub fn wasm_u32x4_extract_lane(a: v128_t, i: i32) u32;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u32x4_ge(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u32x4_gt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u32x4_le(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u32x4_lt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u32x4_max(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u32x4_min(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u32x4_shr(a: v128_t, b: u32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u32x4_trunc_sat_f32x4(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u32x4_trunc_sat_f64x2_zero(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u64x2_extend_high_u32x4(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u64x2_extend_low_u32x4(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u64x2_extmul_high_u32x4(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u64x2_extmul_low_u32x4(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    pub fn wasm_u64x2_extract_lane(a: v128_t, i: i32) u64;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u64x2_shr(a: v128_t, b: u32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u8x16_add_sat(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    pub fn wasm_u8x16_extract_lane(a: v128_t, i: i32) u8;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u8x16_ge(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u8x16_gt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u8x16_le(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u8x16_lt(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u8x16_max(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u8x16_min(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u8x16_narrow_i16x8(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u8x16_shr(a: v128_t, b: u32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_u8x16_sub_sat(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_v128_and(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_v128_andnot(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_v128_any_true(a: v128_t) bool;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_v128_bitselect(a: v128_t, b: v128_t, mask: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @c.reads(mem, 16)
    pub fn wasm_v128_load(mem: *const void) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @c.reads(mem, 2)
    pub fn wasm_v128_load16_lane(mem: *const void, vec: v128_t, i: i32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @c.reads(mem, 4)
    pub fn wasm_v128_load32_lane(mem: *const void, vec: v128_t, i: i32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @c.reads(mem, 8)
    pub fn wasm_v128_load64_lane(mem: *const void, vec: v128_t, i: i32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @c.reads(mem, 1)
    pub fn wasm_v128_load8_lane(mem: *const void, vec: v128_t, i: i32) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_v128_not(a: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_v128_or(a: v128_t, b: v128_t) v128_t;
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @c.writes(mem, 16)
    pub fn wasm_v128_store(mem: *mut void, a: v128_t);
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @c.writes(mem, 2)
    pub fn wasm_v128_store16_lane(mem: *mut void, vec: v128_t, i: i32);
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @c.writes(mem, 4)
    pub fn wasm_v128_store32_lane(mem: *mut void, vec: v128_t, i: i32);
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @c.writes(mem, 8)
    pub fn wasm_v128_store64_lane(mem: *mut void, vec: v128_t, i: i32);
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @c.writes(mem, 1)
    pub fn wasm_v128_store8_lane(mem: *mut void, vec: v128_t, i: i32);
    @arch(wasm32)
    @target_feature([cpu::Feature::Simd128])
    @unsafe(safe)
    pub fn wasm_v128_xor(a: v128_t, b: v128_t) v128_t;
}
