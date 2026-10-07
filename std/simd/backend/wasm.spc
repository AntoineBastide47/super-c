// The WebAssembly SIMD128 entries of the portable vector operations (`@simd_impl`), one per
// operation, lane type and lane count: 128 bits, and for a cast the 64 or 256 bits whose other
// side is 128. The lowering planner splits a wider vector into these; an operation without an
// entry keeps its lane loop. Each entry gives the operation's exact result for every input: a
// trapping operator's `Overflow` entry, or its count check, runs before its wrapping twin.
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

@arch(wasm32)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Simd128])
fn wrapping_add_i8x16(a: i8x16, b: i8x16) i8x16 {
    return vec::<i8, 16>(wasm_i8x16_add(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Simd128])
fn wrapping_sub_i8x16(a: i8x16, b: i8x16) i8x16 {
    return vec::<i8, 16>(wasm_i8x16_sub(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Simd128])
fn wrapping_neg_i8x16(a: i8x16) i8x16 {
    return vec::<i8, 16>(wasm_i8x16_neg(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Simd128])
fn wrapping_add_u8x16(a: u8x16, b: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_i8x16_add(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Simd128])
fn wrapping_sub_u8x16(a: u8x16, b: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_i8x16_sub(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Simd128])
fn wrapping_neg_u8x16(a: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_i8x16_neg(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Simd128])
fn wrapping_add_i16x8(a: i16x8, b: i16x8) i16x8 {
    return vec::<i16, 8>(wasm_i16x8_add(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Simd128])
fn wrapping_sub_i16x8(a: i16x8, b: i16x8) i16x8 {
    return vec::<i16, 8>(wasm_i16x8_sub(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Simd128])
fn wrapping_mul_i16x8(a: i16x8, b: i16x8) i16x8 {
    return vec::<i16, 8>(wasm_i16x8_mul(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Simd128])
fn wrapping_neg_i16x8(a: i16x8) i16x8 {
    return vec::<i16, 8>(wasm_i16x8_neg(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Simd128])
fn wrapping_add_u16x8(a: u16x8, b: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_i16x8_add(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Simd128])
fn wrapping_sub_u16x8(a: u16x8, b: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_i16x8_sub(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Simd128])
fn wrapping_mul_u16x8(a: u16x8, b: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_i16x8_mul(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Simd128])
fn wrapping_neg_u16x8(a: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_i16x8_neg(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Simd128])
fn wrapping_add_i32x4(a: i32x4, b: i32x4) i32x4 {
    return vec::<i32, 4>(wasm_i32x4_add(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Simd128])
fn wrapping_sub_i32x4(a: i32x4, b: i32x4) i32x4 {
    return vec::<i32, 4>(wasm_i32x4_sub(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Simd128])
fn wrapping_mul_i32x4(a: i32x4, b: i32x4) i32x4 {
    return vec::<i32, 4>(wasm_i32x4_mul(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Simd128])
fn wrapping_neg_i32x4(a: i32x4) i32x4 {
    return vec::<i32, 4>(wasm_i32x4_neg(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Simd128])
fn wrapping_add_u32x4(a: u32x4, b: u32x4) u32x4 {
    return vec::<u32, 4>(wasm_i32x4_add(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Simd128])
fn wrapping_sub_u32x4(a: u32x4, b: u32x4) u32x4 {
    return vec::<u32, 4>(wasm_i32x4_sub(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Simd128])
fn wrapping_mul_u32x4(a: u32x4, b: u32x4) u32x4 {
    return vec::<u32, 4>(wasm_i32x4_mul(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Simd128])
fn wrapping_neg_u32x4(a: u32x4) u32x4 {
    return vec::<u32, 4>(wasm_i32x4_neg(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Simd128])
fn wrapping_add_i64x2(a: i64x2, b: i64x2) i64x2 {
    return vec::<i64, 2>(wasm_i64x2_add(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Simd128])
fn wrapping_sub_i64x2(a: i64x2, b: i64x2) i64x2 {
    return vec::<i64, 2>(wasm_i64x2_sub(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Simd128])
fn wrapping_mul_i64x2(a: i64x2, b: i64x2) i64x2 {
    return vec::<i64, 2>(wasm_i64x2_mul(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Simd128])
fn wrapping_neg_i64x2(a: i64x2) i64x2 {
    return vec::<i64, 2>(wasm_i64x2_neg(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Simd128])
fn wrapping_add_u64x2(a: u64x2, b: u64x2) u64x2 {
    return vec::<u64, 2>(wasm_i64x2_add(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Simd128])
fn wrapping_sub_u64x2(a: u64x2, b: u64x2) u64x2 {
    return vec::<u64, 2>(wasm_i64x2_sub(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Simd128])
fn wrapping_mul_u64x2(a: u64x2, b: u64x2) u64x2 {
    return vec::<u64, 2>(wasm_i64x2_mul(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Simd128])
fn wrapping_neg_u64x2(a: u64x2) u64x2 {
    return vec::<u64, 2>(wasm_i64x2_neg(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Add, [cpu::Feature::Simd128])
fn add_f32x4(a: f32x4, b: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_add(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Sub, [cpu::Feature::Simd128])
fn sub_f32x4(a: f32x4, b: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_sub(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Mul, [cpu::Feature::Simd128])
fn mul_f32x4(a: f32x4, b: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_mul(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Div, [cpu::Feature::Simd128])
fn div_f32x4(a: f32x4, b: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_div(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Neg, [cpu::Feature::Simd128])
fn neg_f32x4(a: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_neg(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Abs, [cpu::Feature::Simd128])
fn abs_f32x4(a: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_abs(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Sqrt, [cpu::Feature::Simd128])
fn sqrt_f32x4(a: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_sqrt(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Ceil, [cpu::Feature::Simd128])
fn ceil_f32x4(a: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_ceil(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Floor, [cpu::Feature::Simd128])
fn floor_f32x4(a: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_floor(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Trunc, [cpu::Feature::Simd128])
fn trunc_f32x4(a: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_trunc(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::RoundEven, [cpu::Feature::Simd128])
fn round_even_f32x4(a: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_nearest(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Minimum, [cpu::Feature::Simd128])
fn minimum_f32x4(a: f32x4, b: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_min(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Maximum, [cpu::Feature::Simd128])
fn maximum_f32x4(a: f32x4, b: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_max(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Min, [cpu::Feature::Simd128])
fn min_f32x4(a: f32x4, b: f32x4) f32x4 {
    let x = reg(a);
    let y = reg(b);
    let m = wasm_v128_bitselect(y, wasm_f32x4_min(x, y), wasm_f32x4_ne(x, x));
    return vec::<f32, 4>(wasm_v128_bitselect(x, m, wasm_f32x4_ne(y, y)));
}

@arch(wasm32)
@simd_impl(simd::Op::Max, [cpu::Feature::Simd128])
fn max_f32x4(a: f32x4, b: f32x4) f32x4 {
    let x = reg(a);
    let y = reg(b);
    let m = wasm_v128_bitselect(y, wasm_f32x4_max(x, y), wasm_f32x4_ne(x, x));
    return vec::<f32, 4>(wasm_v128_bitselect(x, m, wasm_f32x4_ne(y, y)));
}

@arch(wasm32)
@simd_impl(simd::Op::Copysign, [cpu::Feature::Simd128])
fn copysign_f32x4(a: f32x4, b: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_v128_bitselect(reg(b), reg(a), reg::<f32, 4>([-0.0, -0.0, -0.0, -0.0])));
}

@arch(wasm32)
@simd_impl(simd::Op::Add, [cpu::Feature::Simd128])
fn add_f64x2(a: f64x2, b: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_add(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Sub, [cpu::Feature::Simd128])
fn sub_f64x2(a: f64x2, b: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_sub(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Mul, [cpu::Feature::Simd128])
fn mul_f64x2(a: f64x2, b: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_mul(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Div, [cpu::Feature::Simd128])
fn div_f64x2(a: f64x2, b: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_div(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Neg, [cpu::Feature::Simd128])
fn neg_f64x2(a: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_neg(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Abs, [cpu::Feature::Simd128])
fn abs_f64x2(a: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_abs(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Sqrt, [cpu::Feature::Simd128])
fn sqrt_f64x2(a: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_sqrt(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Ceil, [cpu::Feature::Simd128])
fn ceil_f64x2(a: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_ceil(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Floor, [cpu::Feature::Simd128])
fn floor_f64x2(a: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_floor(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Trunc, [cpu::Feature::Simd128])
fn trunc_f64x2(a: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_trunc(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::RoundEven, [cpu::Feature::Simd128])
fn round_even_f64x2(a: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_nearest(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Minimum, [cpu::Feature::Simd128])
fn minimum_f64x2(a: f64x2, b: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_min(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Maximum, [cpu::Feature::Simd128])
fn maximum_f64x2(a: f64x2, b: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_max(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Min, [cpu::Feature::Simd128])
fn min_f64x2(a: f64x2, b: f64x2) f64x2 {
    let x = reg(a);
    let y = reg(b);
    let m = wasm_v128_bitselect(y, wasm_f64x2_min(x, y), wasm_f64x2_ne(x, x));
    return vec::<f64, 2>(wasm_v128_bitselect(x, m, wasm_f64x2_ne(y, y)));
}

@arch(wasm32)
@simd_impl(simd::Op::Max, [cpu::Feature::Simd128])
fn max_f64x2(a: f64x2, b: f64x2) f64x2 {
    let x = reg(a);
    let y = reg(b);
    let m = wasm_v128_bitselect(y, wasm_f64x2_max(x, y), wasm_f64x2_ne(x, x));
    return vec::<f64, 2>(wasm_v128_bitselect(x, m, wasm_f64x2_ne(y, y)));
}

@arch(wasm32)
@simd_impl(simd::Op::Copysign, [cpu::Feature::Simd128])
fn copysign_f64x2(a: f64x2, b: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_v128_bitselect(reg(b), reg(a), reg::<f64, 2>([-0.0, -0.0])));
}

@arch(wasm32)
@simd_impl(simd::Op::SaturatingAdd, [cpu::Feature::Simd128])
fn saturating_add_i8x16(a: i8x16, b: i8x16) i8x16 {
    return vec::<i8, 16>(wasm_i8x16_add_sat(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::SaturatingSub, [cpu::Feature::Simd128])
fn saturating_sub_i8x16(a: i8x16, b: i8x16) i8x16 {
    return vec::<i8, 16>(wasm_i8x16_sub_sat(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Min, [cpu::Feature::Simd128])
fn min_i8x16(a: i8x16, b: i8x16) i8x16 {
    return vec::<i8, 16>(wasm_i8x16_min(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Max, [cpu::Feature::Simd128])
fn max_i8x16(a: i8x16, b: i8x16) i8x16 {
    return vec::<i8, 16>(wasm_i8x16_max(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Simd128])
fn abs_diff_i8x16(a: i8x16, b: i8x16) u8x16 {
    let x = reg(a);
    let y = reg(b);
    return vec::<u8, 16>(wasm_i8x16_sub(wasm_i8x16_max(x, y), wasm_i8x16_min(x, y)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Simd128])
fn wrapping_abs_i8x16(a: i8x16) i8x16 {
    return vec::<i8, 16>(wasm_i8x16_abs(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Simd128])
fn count_ones_i8x16(a: i8x16) i8x16 {
    return vec::<i8, 16>(wasm_i8x16_popcnt(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Simd128])
fn shl_scalar_i8x16(a: i8x16, n: i8) i8x16 {
    return vec::<i8, 16>(wasm_i8x16_shl(reg(a), n as u32));
}

@arch(wasm32)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Simd128])
fn shr_scalar_i8x16(a: i8x16, n: i8) i8x16 {
    return vec::<i8, 16>(wasm_i8x16_shr(reg(a), n as u32));
}

@arch(wasm32)
@simd_impl(simd::Op::SaturatingAdd, [cpu::Feature::Simd128])
fn saturating_add_u8x16(a: u8x16, b: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_u8x16_add_sat(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::SaturatingSub, [cpu::Feature::Simd128])
fn saturating_sub_u8x16(a: u8x16, b: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_u8x16_sub_sat(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Min, [cpu::Feature::Simd128])
fn min_u8x16(a: u8x16, b: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_u8x16_min(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Max, [cpu::Feature::Simd128])
fn max_u8x16(a: u8x16, b: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_u8x16_max(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Simd128])
fn abs_diff_u8x16(a: u8x16, b: u8x16) u8x16 {
    let x = reg(a);
    let y = reg(b);
    return vec::<u8, 16>(wasm_i8x16_sub(wasm_u8x16_max(x, y), wasm_u8x16_min(x, y)));
}

@arch(wasm32)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Simd128])
fn count_ones_u8x16(a: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_i8x16_popcnt(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Simd128])
fn shl_scalar_u8x16(a: u8x16, n: u8) u8x16 {
    return vec::<u8, 16>(wasm_i8x16_shl(reg(a), n));
}

@arch(wasm32)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Simd128])
fn shr_scalar_u8x16(a: u8x16, n: u8) u8x16 {
    return vec::<u8, 16>(wasm_u8x16_shr(reg(a), n));
}

@arch(wasm32)
@simd_impl(simd::Op::SaturatingAdd, [cpu::Feature::Simd128])
fn saturating_add_i16x8(a: i16x8, b: i16x8) i16x8 {
    return vec::<i16, 8>(wasm_i16x8_add_sat(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::SaturatingSub, [cpu::Feature::Simd128])
fn saturating_sub_i16x8(a: i16x8, b: i16x8) i16x8 {
    return vec::<i16, 8>(wasm_i16x8_sub_sat(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Min, [cpu::Feature::Simd128])
fn min_i16x8(a: i16x8, b: i16x8) i16x8 {
    return vec::<i16, 8>(wasm_i16x8_min(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Max, [cpu::Feature::Simd128])
fn max_i16x8(a: i16x8, b: i16x8) i16x8 {
    return vec::<i16, 8>(wasm_i16x8_max(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Simd128])
fn abs_diff_i16x8(a: i16x8, b: i16x8) u16x8 {
    let x = reg(a);
    let y = reg(b);
    return vec::<u16, 8>(wasm_i16x8_sub(wasm_i16x8_max(x, y), wasm_i16x8_min(x, y)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Simd128])
fn wrapping_abs_i16x8(a: i16x8) i16x8 {
    return vec::<i16, 8>(wasm_i16x8_abs(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Simd128])
fn shl_scalar_i16x8(a: i16x8, n: i16) i16x8 {
    return vec::<i16, 8>(wasm_i16x8_shl(reg(a), n as u32));
}

@arch(wasm32)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Simd128])
fn shr_scalar_i16x8(a: i16x8, n: i16) i16x8 {
    return vec::<i16, 8>(wasm_i16x8_shr(reg(a), n as u32));
}

@arch(wasm32)
@simd_impl(simd::Op::SaturatingAdd, [cpu::Feature::Simd128])
fn saturating_add_u16x8(a: u16x8, b: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_u16x8_add_sat(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::SaturatingSub, [cpu::Feature::Simd128])
fn saturating_sub_u16x8(a: u16x8, b: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_u16x8_sub_sat(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Min, [cpu::Feature::Simd128])
fn min_u16x8(a: u16x8, b: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_u16x8_min(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Max, [cpu::Feature::Simd128])
fn max_u16x8(a: u16x8, b: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_u16x8_max(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Simd128])
fn abs_diff_u16x8(a: u16x8, b: u16x8) u16x8 {
    let x = reg(a);
    let y = reg(b);
    return vec::<u16, 8>(wasm_i16x8_sub(wasm_u16x8_max(x, y), wasm_u16x8_min(x, y)));
}

@arch(wasm32)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Simd128])
fn shl_scalar_u16x8(a: u16x8, n: u16) u16x8 {
    return vec::<u16, 8>(wasm_i16x8_shl(reg(a), n));
}

@arch(wasm32)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Simd128])
fn shr_scalar_u16x8(a: u16x8, n: u16) u16x8 {
    return vec::<u16, 8>(wasm_u16x8_shr(reg(a), n));
}

@arch(wasm32)
@simd_impl(simd::Op::Min, [cpu::Feature::Simd128])
fn min_i32x4(a: i32x4, b: i32x4) i32x4 {
    return vec::<i32, 4>(wasm_i32x4_min(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Max, [cpu::Feature::Simd128])
fn max_i32x4(a: i32x4, b: i32x4) i32x4 {
    return vec::<i32, 4>(wasm_i32x4_max(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Simd128])
fn abs_diff_i32x4(a: i32x4, b: i32x4) u32x4 {
    let x = reg(a);
    let y = reg(b);
    return vec::<u32, 4>(wasm_i32x4_sub(wasm_i32x4_max(x, y), wasm_i32x4_min(x, y)));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Simd128])
fn wrapping_abs_i32x4(a: i32x4) i32x4 {
    return vec::<i32, 4>(wasm_i32x4_abs(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Simd128])
fn shl_scalar_i32x4(a: i32x4, n: i32) i32x4 {
    return vec::<i32, 4>(wasm_i32x4_shl(reg(a), n as u32));
}

@arch(wasm32)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Simd128])
fn shr_scalar_i32x4(a: i32x4, n: i32) i32x4 {
    return vec::<i32, 4>(wasm_i32x4_shr(reg(a), n as u32));
}

@arch(wasm32)
@simd_impl(simd::Op::Min, [cpu::Feature::Simd128])
fn min_u32x4(a: u32x4, b: u32x4) u32x4 {
    return vec::<u32, 4>(wasm_u32x4_min(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Max, [cpu::Feature::Simd128])
fn max_u32x4(a: u32x4, b: u32x4) u32x4 {
    return vec::<u32, 4>(wasm_u32x4_max(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Simd128])
fn abs_diff_u32x4(a: u32x4, b: u32x4) u32x4 {
    let x = reg(a);
    let y = reg(b);
    return vec::<u32, 4>(wasm_i32x4_sub(wasm_u32x4_max(x, y), wasm_u32x4_min(x, y)));
}

@arch(wasm32)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Simd128])
fn shl_scalar_u32x4(a: u32x4, n: u32) u32x4 {
    return vec::<u32, 4>(wasm_i32x4_shl(reg(a), n));
}

@arch(wasm32)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Simd128])
fn shr_scalar_u32x4(a: u32x4, n: u32) u32x4 {
    return vec::<u32, 4>(wasm_u32x4_shr(reg(a), n));
}

@arch(wasm32)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Simd128])
fn wrapping_abs_i64x2(a: i64x2) i64x2 {
    return vec::<i64, 2>(wasm_i64x2_abs(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Simd128])
fn shl_scalar_i64x2(a: i64x2, n: i64) i64x2 {
    return vec::<i64, 2>(wasm_i64x2_shl(reg(a), n as u32));
}

@arch(wasm32)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Simd128])
fn shr_scalar_i64x2(a: i64x2, n: i64) i64x2 {
    return vec::<i64, 2>(wasm_i64x2_shr(reg(a), n as u32));
}

@arch(wasm32)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Simd128])
fn shl_scalar_u64x2(a: u64x2, n: u64) u64x2 {
    return vec::<u64, 2>(wasm_i64x2_shl(reg(a), n as u32));
}

@arch(wasm32)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Simd128])
fn shr_scalar_u64x2(a: u64x2, n: u64) u64x2 {
    return vec::<u64, 2>(wasm_u64x2_shr(reg(a), n as u32));
}

@arch(wasm32)
@simd_impl(simd::Op::Min, [cpu::Feature::Simd128])
fn min_i64x2(a: i64x2, b: i64x2) i64x2 {
    return vec::<i64, 2>(wasm_v128_bitselect(reg(a), reg(b), wasm_i64x2_lt(reg(a), reg(b))));
}

@arch(wasm32)
@simd_impl(simd::Op::Max, [cpu::Feature::Simd128])
fn max_i64x2(a: i64x2, b: i64x2) i64x2 {
    return vec::<i64, 2>(wasm_v128_bitselect(reg(a), reg(b), wasm_i64x2_lt(reg(b), reg(a))));
}

@arch(wasm32)
@simd_impl(simd::Op::Min, [cpu::Feature::Simd128])
fn min_u64x2(a: u64x2, b: u64x2) u64x2 {
    let s = reg::<u64, 2>([0x8000000000000000, 0x8000000000000000]);
    return vec::<u64, 2>(
        wasm_v128_bitselect(reg(a), reg(b), wasm_i64x2_lt(wasm_v128_xor(reg(a), s), wasm_v128_xor(reg(b), s))),
    );
}

@arch(wasm32)
@simd_impl(simd::Op::Max, [cpu::Feature::Simd128])
fn max_u64x2(a: u64x2, b: u64x2) u64x2 {
    let s = reg::<u64, 2>([0x8000000000000000, 0x8000000000000000]);
    return vec::<u64, 2>(
        wasm_v128_bitselect(reg(a), reg(b), wasm_i64x2_lt(wasm_v128_xor(reg(b), s), wasm_v128_xor(reg(a), s))),
    );
}

@arch(wasm32)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Simd128])
fn cmp_eq_lanes_i8x16(a: i8x16, b: i8x16) u8x16 {
    return vec::<u8, 16>(wasm_i8x16_eq(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Simd128])
fn cmp_ne_lanes_i8x16(a: i8x16, b: i8x16) u8x16 {
    return vec::<u8, 16>(wasm_i8x16_ne(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Simd128])
fn cmp_lt_lanes_i8x16(a: i8x16, b: i8x16) u8x16 {
    return vec::<u8, 16>(wasm_i8x16_lt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Simd128])
fn cmp_le_lanes_i8x16(a: i8x16, b: i8x16) u8x16 {
    return vec::<u8, 16>(wasm_i8x16_le(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Simd128])
fn cmp_gt_lanes_i8x16(a: i8x16, b: i8x16) u8x16 {
    return vec::<u8, 16>(wasm_i8x16_gt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Simd128])
fn cmp_ge_lanes_i8x16(a: i8x16, b: i8x16) u8x16 {
    return vec::<u8, 16>(wasm_i8x16_ge(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Simd128])
fn choose_lanes_i8x16(m: u8x16, a: i8x16, b: i8x16) i8x16 {
    return vec::<i8, 16>(wasm_v128_bitselect(reg(a), reg(b), reg(m)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Simd128])
fn cmp_eq_lanes_u8x16(a: u8x16, b: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_i8x16_eq(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Simd128])
fn cmp_ne_lanes_u8x16(a: u8x16, b: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_i8x16_ne(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Simd128])
fn cmp_lt_lanes_u8x16(a: u8x16, b: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_u8x16_lt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Simd128])
fn cmp_le_lanes_u8x16(a: u8x16, b: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_u8x16_le(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Simd128])
fn cmp_gt_lanes_u8x16(a: u8x16, b: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_u8x16_gt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Simd128])
fn cmp_ge_lanes_u8x16(a: u8x16, b: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_u8x16_ge(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Simd128])
fn choose_lanes_u8x16(m: u8x16, a: u8x16, b: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_v128_bitselect(reg(a), reg(b), reg(m)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Simd128])
fn cmp_eq_lanes_i16x8(a: i16x8, b: i16x8) u16x8 {
    return vec::<u16, 8>(wasm_i16x8_eq(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Simd128])
fn cmp_ne_lanes_i16x8(a: i16x8, b: i16x8) u16x8 {
    return vec::<u16, 8>(wasm_i16x8_ne(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Simd128])
fn cmp_lt_lanes_i16x8(a: i16x8, b: i16x8) u16x8 {
    return vec::<u16, 8>(wasm_i16x8_lt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Simd128])
fn cmp_le_lanes_i16x8(a: i16x8, b: i16x8) u16x8 {
    return vec::<u16, 8>(wasm_i16x8_le(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Simd128])
fn cmp_gt_lanes_i16x8(a: i16x8, b: i16x8) u16x8 {
    return vec::<u16, 8>(wasm_i16x8_gt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Simd128])
fn cmp_ge_lanes_i16x8(a: i16x8, b: i16x8) u16x8 {
    return vec::<u16, 8>(wasm_i16x8_ge(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Simd128])
fn choose_lanes_i16x8(m: u16x8, a: i16x8, b: i16x8) i16x8 {
    return vec::<i16, 8>(wasm_v128_bitselect(reg(a), reg(b), reg(m)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Simd128])
fn cmp_eq_lanes_u16x8(a: u16x8, b: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_i16x8_eq(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Simd128])
fn cmp_ne_lanes_u16x8(a: u16x8, b: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_i16x8_ne(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Simd128])
fn cmp_lt_lanes_u16x8(a: u16x8, b: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_u16x8_lt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Simd128])
fn cmp_le_lanes_u16x8(a: u16x8, b: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_u16x8_le(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Simd128])
fn cmp_gt_lanes_u16x8(a: u16x8, b: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_u16x8_gt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Simd128])
fn cmp_ge_lanes_u16x8(a: u16x8, b: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_u16x8_ge(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Simd128])
fn choose_lanes_u16x8(m: u16x8, a: u16x8, b: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_v128_bitselect(reg(a), reg(b), reg(m)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Simd128])
fn cmp_eq_lanes_i32x4(a: i32x4, b: i32x4) u32x4 {
    return vec::<u32, 4>(wasm_i32x4_eq(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Simd128])
fn cmp_ne_lanes_i32x4(a: i32x4, b: i32x4) u32x4 {
    return vec::<u32, 4>(wasm_i32x4_ne(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Simd128])
fn cmp_lt_lanes_i32x4(a: i32x4, b: i32x4) u32x4 {
    return vec::<u32, 4>(wasm_i32x4_lt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Simd128])
fn cmp_le_lanes_i32x4(a: i32x4, b: i32x4) u32x4 {
    return vec::<u32, 4>(wasm_i32x4_le(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Simd128])
fn cmp_gt_lanes_i32x4(a: i32x4, b: i32x4) u32x4 {
    return vec::<u32, 4>(wasm_i32x4_gt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Simd128])
fn cmp_ge_lanes_i32x4(a: i32x4, b: i32x4) u32x4 {
    return vec::<u32, 4>(wasm_i32x4_ge(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Simd128])
fn choose_lanes_i32x4(m: u32x4, a: i32x4, b: i32x4) i32x4 {
    return vec::<i32, 4>(wasm_v128_bitselect(reg(a), reg(b), reg(m)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Simd128])
fn cmp_eq_lanes_u32x4(a: u32x4, b: u32x4) u32x4 {
    return vec::<u32, 4>(wasm_i32x4_eq(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Simd128])
fn cmp_ne_lanes_u32x4(a: u32x4, b: u32x4) u32x4 {
    return vec::<u32, 4>(wasm_i32x4_ne(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Simd128])
fn cmp_lt_lanes_u32x4(a: u32x4, b: u32x4) u32x4 {
    return vec::<u32, 4>(wasm_u32x4_lt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Simd128])
fn cmp_le_lanes_u32x4(a: u32x4, b: u32x4) u32x4 {
    return vec::<u32, 4>(wasm_u32x4_le(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Simd128])
fn cmp_gt_lanes_u32x4(a: u32x4, b: u32x4) u32x4 {
    return vec::<u32, 4>(wasm_u32x4_gt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Simd128])
fn cmp_ge_lanes_u32x4(a: u32x4, b: u32x4) u32x4 {
    return vec::<u32, 4>(wasm_u32x4_ge(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Simd128])
fn choose_lanes_u32x4(m: u32x4, a: u32x4, b: u32x4) u32x4 {
    return vec::<u32, 4>(wasm_v128_bitselect(reg(a), reg(b), reg(m)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Simd128])
fn cmp_eq_lanes_i64x2(a: i64x2, b: i64x2) u64x2 {
    return vec::<u64, 2>(wasm_i64x2_eq(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Simd128])
fn cmp_ne_lanes_i64x2(a: i64x2, b: i64x2) u64x2 {
    return vec::<u64, 2>(wasm_i64x2_ne(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Simd128])
fn cmp_lt_lanes_i64x2(a: i64x2, b: i64x2) u64x2 {
    return vec::<u64, 2>(wasm_i64x2_lt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Simd128])
fn cmp_le_lanes_i64x2(a: i64x2, b: i64x2) u64x2 {
    return vec::<u64, 2>(wasm_i64x2_le(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Simd128])
fn cmp_gt_lanes_i64x2(a: i64x2, b: i64x2) u64x2 {
    return vec::<u64, 2>(wasm_i64x2_gt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Simd128])
fn cmp_ge_lanes_i64x2(a: i64x2, b: i64x2) u64x2 {
    return vec::<u64, 2>(wasm_i64x2_ge(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Simd128])
fn choose_lanes_i64x2(m: u64x2, a: i64x2, b: i64x2) i64x2 {
    return vec::<i64, 2>(wasm_v128_bitselect(reg(a), reg(b), reg(m)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Simd128])
fn cmp_eq_lanes_u64x2(a: u64x2, b: u64x2) u64x2 {
    return vec::<u64, 2>(wasm_i64x2_eq(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Simd128])
fn cmp_ne_lanes_u64x2(a: u64x2, b: u64x2) u64x2 {
    return vec::<u64, 2>(wasm_i64x2_ne(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Simd128])
fn cmp_lt_lanes_u64x2(a: u64x2, b: u64x2) u64x2 {
    let s = reg::<u64, 2>([0x8000000000000000, 0x8000000000000000]);
    return vec::<u64, 2>(wasm_i64x2_lt(wasm_v128_xor(reg(a), s), wasm_v128_xor(reg(b), s)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Simd128])
fn cmp_le_lanes_u64x2(a: u64x2, b: u64x2) u64x2 {
    let s = reg::<u64, 2>([0x8000000000000000, 0x8000000000000000]);
    return vec::<u64, 2>(wasm_i64x2_le(wasm_v128_xor(reg(a), s), wasm_v128_xor(reg(b), s)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Simd128])
fn cmp_gt_lanes_u64x2(a: u64x2, b: u64x2) u64x2 {
    let s = reg::<u64, 2>([0x8000000000000000, 0x8000000000000000]);
    return vec::<u64, 2>(wasm_i64x2_gt(wasm_v128_xor(reg(a), s), wasm_v128_xor(reg(b), s)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Simd128])
fn cmp_ge_lanes_u64x2(a: u64x2, b: u64x2) u64x2 {
    let s = reg::<u64, 2>([0x8000000000000000, 0x8000000000000000]);
    return vec::<u64, 2>(wasm_i64x2_ge(wasm_v128_xor(reg(a), s), wasm_v128_xor(reg(b), s)));
}

@arch(wasm32)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Simd128])
fn choose_lanes_u64x2(m: u64x2, a: u64x2, b: u64x2) u64x2 {
    return vec::<u64, 2>(wasm_v128_bitselect(reg(a), reg(b), reg(m)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Simd128])
fn cmp_eq_lanes_f32x4(a: f32x4, b: f32x4) u32x4 {
    return vec::<u32, 4>(wasm_f32x4_eq(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Simd128])
fn cmp_ne_lanes_f32x4(a: f32x4, b: f32x4) u32x4 {
    return vec::<u32, 4>(wasm_f32x4_ne(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Simd128])
fn cmp_lt_lanes_f32x4(a: f32x4, b: f32x4) u32x4 {
    return vec::<u32, 4>(wasm_f32x4_lt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Simd128])
fn cmp_le_lanes_f32x4(a: f32x4, b: f32x4) u32x4 {
    return vec::<u32, 4>(wasm_f32x4_le(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Simd128])
fn cmp_gt_lanes_f32x4(a: f32x4, b: f32x4) u32x4 {
    return vec::<u32, 4>(wasm_f32x4_gt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Simd128])
fn cmp_ge_lanes_f32x4(a: f32x4, b: f32x4) u32x4 {
    return vec::<u32, 4>(wasm_f32x4_ge(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Simd128])
fn choose_lanes_f32x4(m: u32x4, a: f32x4, b: f32x4) f32x4 {
    return vec::<f32, 4>(wasm_v128_bitselect(reg(a), reg(b), reg(m)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Simd128])
fn cmp_eq_lanes_f64x2(a: f64x2, b: f64x2) u64x2 {
    return vec::<u64, 2>(wasm_f64x2_eq(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Simd128])
fn cmp_ne_lanes_f64x2(a: f64x2, b: f64x2) u64x2 {
    return vec::<u64, 2>(wasm_f64x2_ne(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Simd128])
fn cmp_lt_lanes_f64x2(a: f64x2, b: f64x2) u64x2 {
    return vec::<u64, 2>(wasm_f64x2_lt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Simd128])
fn cmp_le_lanes_f64x2(a: f64x2, b: f64x2) u64x2 {
    return vec::<u64, 2>(wasm_f64x2_le(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Simd128])
fn cmp_gt_lanes_f64x2(a: f64x2, b: f64x2) u64x2 {
    return vec::<u64, 2>(wasm_f64x2_gt(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Simd128])
fn cmp_ge_lanes_f64x2(a: f64x2, b: f64x2) u64x2 {
    return vec::<u64, 2>(wasm_f64x2_ge(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Simd128])
fn choose_lanes_f64x2(m: u64x2, a: f64x2, b: f64x2) f64x2 {
    return vec::<f64, 2>(wasm_v128_bitselect(reg(a), reg(b), reg(m)));
}

@arch(wasm32)
@simd_impl(simd::Op::LanesToMask, [cpu::Feature::Simd128])
fn lanes_to_mask_u8x16(m: u8x16) mask16 {
    return (wasm_i8x16_bitmask(reg(m)) as u64) as mask16;
}

@arch(wasm32)
@simd_impl(simd::Op::AnyLanes, [cpu::Feature::Simd128])
fn any_lanes_u8x16(m: u8x16) bool {
    return wasm_v128_any_true(reg(m));
}

@arch(wasm32)
@simd_impl(simd::Op::AllLanes, [cpu::Feature::Simd128])
fn all_lanes_u8x16(m: u8x16) bool {
    return wasm_i8x16_all_true(reg(m));
}

@arch(wasm32)
@simd_impl(simd::Op::MaskToLanes, [cpu::Feature::Simd128])
fn mask_to_lanes_u8x16(m: mask16) u8x16 {
    let b = reg::<u8, 16>([1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128]);
    return vec::<u8, 16>(
        wasm_i8x16_eq(
            wasm_v128_and(
                wasm_i8x16_swizzle(
                    wasm_i16x8_splat((m as u64) as i16),
                    reg::<u8, 16>([0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1]),
                ),
                b,
            ),
            b,
        ),
    );
}

@arch(wasm32)
@simd_impl(simd::Op::LanesToMask, [cpu::Feature::Simd128])
fn lanes_to_mask_u16x8(m: u16x8) mask8 {
    return (wasm_i16x8_bitmask(reg(m)) as u64) as mask8;
}

@arch(wasm32)
@simd_impl(simd::Op::AnyLanes, [cpu::Feature::Simd128])
fn any_lanes_u16x8(m: u16x8) bool {
    return wasm_v128_any_true(reg(m));
}

@arch(wasm32)
@simd_impl(simd::Op::AllLanes, [cpu::Feature::Simd128])
fn all_lanes_u16x8(m: u16x8) bool {
    return wasm_i16x8_all_true(reg(m));
}

@arch(wasm32)
@simd_impl(simd::Op::MaskToLanes, [cpu::Feature::Simd128])
fn mask_to_lanes_u16x8(m: mask8) u16x8 {
    let b = reg::<u16, 8>([1, 2, 4, 8, 16, 32, 64, 128]);
    return vec::<u16, 8>(wasm_i16x8_eq(wasm_v128_and(wasm_i16x8_splat((m as u64) as i16), b), b));
}

@arch(wasm32)
@simd_impl(simd::Op::LanesToMask, [cpu::Feature::Simd128])
fn lanes_to_mask_u32x4(m: u32x4) mask4 {
    return (wasm_i32x4_bitmask(reg(m)) as u64) as mask4;
}

@arch(wasm32)
@simd_impl(simd::Op::AnyLanes, [cpu::Feature::Simd128])
fn any_lanes_u32x4(m: u32x4) bool {
    return wasm_v128_any_true(reg(m));
}

@arch(wasm32)
@simd_impl(simd::Op::AllLanes, [cpu::Feature::Simd128])
fn all_lanes_u32x4(m: u32x4) bool {
    return wasm_i32x4_all_true(reg(m));
}

@arch(wasm32)
@simd_impl(simd::Op::MaskToLanes, [cpu::Feature::Simd128])
fn mask_to_lanes_u32x4(m: mask4) u32x4 {
    let b = reg::<u32, 4>([1, 2, 4, 8]);
    return vec::<u32, 4>(wasm_i32x4_eq(wasm_v128_and(wasm_i32x4_splat((m as u64) as i32), b), b));
}

@arch(wasm32)
@simd_impl(simd::Op::LanesToMask, [cpu::Feature::Simd128])
fn lanes_to_mask_u64x2(m: u64x2) mask2 {
    return (wasm_i64x2_bitmask(reg(m)) as u64) as mask2;
}

@arch(wasm32)
@simd_impl(simd::Op::AnyLanes, [cpu::Feature::Simd128])
fn any_lanes_u64x2(m: u64x2) bool {
    return wasm_v128_any_true(reg(m));
}

@arch(wasm32)
@simd_impl(simd::Op::AllLanes, [cpu::Feature::Simd128])
fn all_lanes_u64x2(m: u64x2) bool {
    return wasm_i64x2_all_true(reg(m));
}

@arch(wasm32)
@simd_impl(simd::Op::MaskToLanes, [cpu::Feature::Simd128])
fn mask_to_lanes_u64x2(m: mask2) u64x2 {
    let b = reg::<u64, 2>([1, 2]);
    return vec::<u64, 2>(wasm_i64x2_eq(wasm_v128_and(wasm_i64x2_splat((m as u64) as i64), b), b));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_f32x4_i32x4(a: f32x4) i32x4 {
    return vec::<i32, 4>(wasm_i32x4_trunc_sat_f32x4(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_f32x4_u32x4(a: f32x4) u32x4 {
    return vec::<u32, 4>(wasm_u32x4_trunc_sat_f32x4(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_i32x4_f32x4(a: i32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_convert_i32x4(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_u32x4_f32x4(a: u32x4) f32x4 {
    return vec::<f32, 4>(wasm_f32x4_convert_u32x4(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_f64x2_i32x2(a: f64x2) Simd<i32, 2> {
    return simd::swizzle(vec::<i32, 4>(wasm_i32x4_trunc_sat_f64x2_zero(reg(a))), [0, 1]);
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_f64x2_u32x2(a: f64x2) Simd<u32, 2> {
    return simd::swizzle(vec::<u32, 4>(wasm_u32x4_trunc_sat_f64x2_zero(reg(a))), [0, 1]);
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_i32x2_f64x2(a: Simd<i32, 2>) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_convert_low_i32x4(reg(simd::concat(a, a))));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_u32x2_f64x2(a: Simd<u32, 2>) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_convert_low_u32x4(reg(simd::concat(a, a))));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_f32x2_f64x2(a: Simd<f32, 2>) f64x2 {
    return vec::<f64, 2>(wasm_f64x2_promote_low_f32x4(reg(simd::concat(a, a))));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_f64x2_f32x2(a: f64x2) Simd<f32, 2> {
    return simd::swizzle(vec::<f32, 4>(wasm_f32x4_demote_f64x2_zero(reg(a))), [0, 1]);
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_i8x16_i16x16(a: i8x16) i16x16 {
    let x = reg(a);
    return simd::concat(vec::<i16, 8>(wasm_i16x8_extend_low_i8x16(x)), vec::<i16, 8>(wasm_i16x8_extend_high_i8x16(x)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_u8x16_u16x16(a: u8x16) u16x16 {
    let x = reg(a);
    return simd::concat(vec::<u16, 8>(wasm_u16x8_extend_low_u8x16(x)), vec::<u16, 8>(wasm_u16x8_extend_high_u8x16(x)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_i16x8_i32x8(a: i16x8) i32x8 {
    let x = reg(a);
    return simd::concat(vec::<i32, 4>(wasm_i32x4_extend_low_i16x8(x)), vec::<i32, 4>(wasm_i32x4_extend_high_i16x8(x)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_u16x8_u32x8(a: u16x8) u32x8 {
    let x = reg(a);
    return simd::concat(vec::<u32, 4>(wasm_u32x4_extend_low_u16x8(x)), vec::<u32, 4>(wasm_u32x4_extend_high_u16x8(x)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_i32x4_i64x4(a: i32x4) i64x4 {
    let x = reg(a);
    return simd::concat(vec::<i64, 2>(wasm_i64x2_extend_low_i32x4(x)), vec::<i64, 2>(wasm_i64x2_extend_high_i32x4(x)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_u32x4_u64x4(a: u32x4) u64x4 {
    let x = reg(a);
    return simd::concat(vec::<u64, 2>(wasm_u64x2_extend_low_u32x4(x)), vec::<u64, 2>(wasm_u64x2_extend_high_u32x4(x)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_f32x4_f64x4(a: f32x4) f64x4 {
    let x = reg(a);
    return simd::concat(
        vec::<f64, 2>(wasm_f64x2_promote_low_f32x4(x)),
        vec::<f64, 2>(wasm_f64x2_promote_low_f32x4(unsafe wasm_i64x2_shuffle(x, x, 1, 1))),
    );
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_i32x4_f64x4(a: i32x4) f64x4 {
    let x = reg(a);
    return simd::concat(
        vec::<f64, 2>(wasm_f64x2_convert_low_i32x4(x)),
        vec::<f64, 2>(wasm_f64x2_convert_low_i32x4(unsafe wasm_i64x2_shuffle(x, x, 1, 1))),
    );
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_u32x4_f64x4(a: u32x4) f64x4 {
    let x = reg(a);
    return simd::concat(
        vec::<f64, 2>(wasm_f64x2_convert_low_u32x4(x)),
        vec::<f64, 2>(wasm_f64x2_convert_low_u32x4(unsafe wasm_i64x2_shuffle(x, x, 1, 1))),
    );
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_f64x4_f32x4(a: f64x4) f32x4 {
    let lo = wasm_f32x4_demote_f64x2_zero(reg(simd::swizzle(a, [0, 1])));
    let hi = wasm_f32x4_demote_f64x2_zero(reg(simd::swizzle(a, [2, 3])));
    return vec::<f32, 4>(unsafe wasm_i64x2_shuffle(lo, hi, 0, 2));
}

@arch(wasm32)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Simd128])
fn narrow_saturating_i16x16_i8x16(a: i16x16) i8x16 {
    return vec::<i8, 16>(
        wasm_i8x16_narrow_i16x8(
            reg(simd::swizzle(a, [0, 1, 2, 3, 4, 5, 6, 7])),
            reg(simd::swizzle(a, [8, 9, 10, 11, 12, 13, 14, 15])),
        ),
    );
}

@arch(wasm32)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Simd128])
fn narrow_saturating_i16x16_u8x16(a: i16x16) u8x16 {
    return vec::<u8, 16>(
        wasm_u8x16_narrow_i16x8(
            reg(simd::swizzle(a, [0, 1, 2, 3, 4, 5, 6, 7])),
            reg(simd::swizzle(a, [8, 9, 10, 11, 12, 13, 14, 15])),
        ),
    );
}

@arch(wasm32)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Simd128])
fn narrow_saturating_i32x8_i16x8(a: i32x8) i16x8 {
    return vec::<i16, 8>(
        wasm_i16x8_narrow_i32x4(reg(simd::swizzle(a, [0, 1, 2, 3])), reg(simd::swizzle(a, [4, 5, 6, 7]))),
    );
}

@arch(wasm32)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Simd128])
fn narrow_saturating_i32x8_u16x8(a: i32x8) u16x8 {
    return vec::<u16, 8>(
        wasm_u16x8_narrow_i32x4(reg(simd::swizzle(a, [0, 1, 2, 3])), reg(simd::swizzle(a, [4, 5, 6, 7]))),
    );
}

@arch(wasm32)
@simd_impl(simd::Op::Load, [cpu::Feature::Simd128])
fn load_i8x16(p: *const i8) i8x16 {
    return vec::<i8, 16>(unsafe wasm_v128_load(p));
}

@arch(wasm32)
@simd_impl(simd::Op::Store, [cpu::Feature::Simd128])
fn store_i8x16(p: *mut i8, v: i8x16) {
    unsafe wasm_v128_store(p, reg(v));
}

@arch(wasm32)
@simd_impl(simd::Op::Load, [cpu::Feature::Simd128])
fn load_u8x16(p: *const u8) u8x16 {
    return vec::<u8, 16>(unsafe wasm_v128_load(p));
}

@arch(wasm32)
@simd_impl(simd::Op::Store, [cpu::Feature::Simd128])
fn store_u8x16(p: *mut u8, v: u8x16) {
    unsafe wasm_v128_store(p, reg(v));
}

@arch(wasm32)
@simd_impl(simd::Op::Load, [cpu::Feature::Simd128])
fn load_i16x8(p: *const i16) i16x8 {
    return vec::<i16, 8>(unsafe wasm_v128_load(p));
}

@arch(wasm32)
@simd_impl(simd::Op::Store, [cpu::Feature::Simd128])
fn store_i16x8(p: *mut i16, v: i16x8) {
    unsafe wasm_v128_store(p, reg(v));
}

@arch(wasm32)
@simd_impl(simd::Op::Load, [cpu::Feature::Simd128])
fn load_u16x8(p: *const u16) u16x8 {
    return vec::<u16, 8>(unsafe wasm_v128_load(p));
}

@arch(wasm32)
@simd_impl(simd::Op::Store, [cpu::Feature::Simd128])
fn store_u16x8(p: *mut u16, v: u16x8) {
    unsafe wasm_v128_store(p, reg(v));
}

@arch(wasm32)
@simd_impl(simd::Op::Load, [cpu::Feature::Simd128])
fn load_i32x4(p: *const i32) i32x4 {
    return vec::<i32, 4>(unsafe wasm_v128_load(p));
}

@arch(wasm32)
@simd_impl(simd::Op::Store, [cpu::Feature::Simd128])
fn store_i32x4(p: *mut i32, v: i32x4) {
    unsafe wasm_v128_store(p, reg(v));
}

@arch(wasm32)
@simd_impl(simd::Op::Load, [cpu::Feature::Simd128])
fn load_u32x4(p: *const u32) u32x4 {
    return vec::<u32, 4>(unsafe wasm_v128_load(p));
}

@arch(wasm32)
@simd_impl(simd::Op::Store, [cpu::Feature::Simd128])
fn store_u32x4(p: *mut u32, v: u32x4) {
    unsafe wasm_v128_store(p, reg(v));
}

@arch(wasm32)
@simd_impl(simd::Op::Load, [cpu::Feature::Simd128])
fn load_i64x2(p: *const i64) i64x2 {
    return vec::<i64, 2>(unsafe wasm_v128_load(p));
}

@arch(wasm32)
@simd_impl(simd::Op::Store, [cpu::Feature::Simd128])
fn store_i64x2(p: *mut i64, v: i64x2) {
    unsafe wasm_v128_store(p, reg(v));
}

@arch(wasm32)
@simd_impl(simd::Op::Load, [cpu::Feature::Simd128])
fn load_u64x2(p: *const u64) u64x2 {
    return vec::<u64, 2>(unsafe wasm_v128_load(p));
}

@arch(wasm32)
@simd_impl(simd::Op::Store, [cpu::Feature::Simd128])
fn store_u64x2(p: *mut u64, v: u64x2) {
    unsafe wasm_v128_store(p, reg(v));
}

@arch(wasm32)
@simd_impl(simd::Op::Load, [cpu::Feature::Simd128])
fn load_f32x4(p: *const f32) f32x4 {
    return vec::<f32, 4>(unsafe wasm_v128_load(p));
}

@arch(wasm32)
@simd_impl(simd::Op::Store, [cpu::Feature::Simd128])
fn store_f32x4(p: *mut f32, v: f32x4) {
    unsafe wasm_v128_store(p, reg(v));
}

@arch(wasm32)
@simd_impl(simd::Op::Load, [cpu::Feature::Simd128])
fn load_f64x2(p: *const f64) f64x2 {
    return vec::<f64, 2>(unsafe wasm_v128_load(p));
}

@arch(wasm32)
@simd_impl(simd::Op::Store, [cpu::Feature::Simd128])
fn store_f64x2(p: *mut f64, v: f64x2) {
    unsafe wasm_v128_store(p, reg(v));
}

@arch(wasm32)
@simd_impl(simd::Op::SwizzleOrZero, [cpu::Feature::Simd128])
fn swizzle_or_zero_i8x16(a: i8x16, idx: u8x16) i8x16 {
    return vec::<i8, 16>(wasm_i8x16_swizzle(reg(a), reg(idx)));
}

@arch(wasm32)
@simd_impl(simd::Op::SwizzleOrZero, [cpu::Feature::Simd128])
fn swizzle_or_zero_u8x16(a: u8x16, idx: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_i8x16_swizzle(reg(a), reg(idx)));
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceAddTree, [cpu::Feature::Simd128])
fn reduce_add_tree_f32x4(v: f32x4) f32 {
    let mut x = reg(v);
    x = wasm_f32x4_add(x, unsafe wasm_i32x4_shuffle(x, x, 2, 3, 2, 3));
    x = wasm_f32x4_add(x, unsafe wasm_i32x4_shuffle(x, x, 1, 1, 2, 3));
    return unsafe wasm_f32x4_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceMulTree, [cpu::Feature::Simd128])
fn reduce_mul_tree_f32x4(v: f32x4) f32 {
    let mut x = reg(v);
    x = wasm_f32x4_mul(x, unsafe wasm_i32x4_shuffle(x, x, 2, 3, 2, 3));
    x = wasm_f32x4_mul(x, unsafe wasm_i32x4_shuffle(x, x, 1, 1, 2, 3));
    return unsafe wasm_f32x4_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceAddTree, [cpu::Feature::Simd128])
fn reduce_add_tree_f64x2(v: f64x2) f64 {
    let mut x = reg(v);
    x = wasm_f64x2_add(x, unsafe wasm_i64x2_shuffle(x, x, 1, 1));
    return unsafe wasm_f64x2_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceMulTree, [cpu::Feature::Simd128])
fn reduce_mul_tree_f64x2(v: f64x2) f64 {
    let mut x = reg(v);
    x = wasm_f64x2_mul(x, unsafe wasm_i64x2_shuffle(x, x, 1, 1));
    return unsafe wasm_f64x2_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceAdd, [cpu::Feature::Simd128])
fn reduce_add_i8x16(v: i8x16) i8 {
    let mut x = reg(v);
    x = wasm_i8x16_add(x, unsafe wasm_i8x16_shuffle(x, x, 8, 9, 10, 11, 12, 13, 14, 15, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_i8x16_add(x, unsafe wasm_i8x16_shuffle(x, x, 4, 5, 6, 7, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_i8x16_add(x, unsafe wasm_i8x16_shuffle(x, x, 2, 3, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_i8x16_add(x, unsafe wasm_i8x16_shuffle(x, x, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    return unsafe wasm_i8x16_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceMin, [cpu::Feature::Simd128])
fn reduce_min_i8x16(v: i8x16) i8 {
    let mut x = reg(v);
    x = wasm_i8x16_min(x, unsafe wasm_i8x16_shuffle(x, x, 8, 9, 10, 11, 12, 13, 14, 15, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_i8x16_min(x, unsafe wasm_i8x16_shuffle(x, x, 4, 5, 6, 7, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_i8x16_min(x, unsafe wasm_i8x16_shuffle(x, x, 2, 3, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_i8x16_min(x, unsafe wasm_i8x16_shuffle(x, x, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    return unsafe wasm_i8x16_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceMax, [cpu::Feature::Simd128])
fn reduce_max_i8x16(v: i8x16) i8 {
    let mut x = reg(v);
    x = wasm_i8x16_max(x, unsafe wasm_i8x16_shuffle(x, x, 8, 9, 10, 11, 12, 13, 14, 15, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_i8x16_max(x, unsafe wasm_i8x16_shuffle(x, x, 4, 5, 6, 7, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_i8x16_max(x, unsafe wasm_i8x16_shuffle(x, x, 2, 3, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_i8x16_max(x, unsafe wasm_i8x16_shuffle(x, x, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    return unsafe wasm_i8x16_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceAdd, [cpu::Feature::Simd128])
fn reduce_add_u8x16(v: u8x16) u8 {
    let mut x = reg(v);
    x = wasm_i8x16_add(x, unsafe wasm_i8x16_shuffle(x, x, 8, 9, 10, 11, 12, 13, 14, 15, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_i8x16_add(x, unsafe wasm_i8x16_shuffle(x, x, 4, 5, 6, 7, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_i8x16_add(x, unsafe wasm_i8x16_shuffle(x, x, 2, 3, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_i8x16_add(x, unsafe wasm_i8x16_shuffle(x, x, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    return unsafe wasm_u8x16_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceMin, [cpu::Feature::Simd128])
fn reduce_min_u8x16(v: u8x16) u8 {
    let mut x = reg(v);
    x = wasm_u8x16_min(x, unsafe wasm_i8x16_shuffle(x, x, 8, 9, 10, 11, 12, 13, 14, 15, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_u8x16_min(x, unsafe wasm_i8x16_shuffle(x, x, 4, 5, 6, 7, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_u8x16_min(x, unsafe wasm_i8x16_shuffle(x, x, 2, 3, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_u8x16_min(x, unsafe wasm_i8x16_shuffle(x, x, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    return unsafe wasm_u8x16_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceMax, [cpu::Feature::Simd128])
fn reduce_max_u8x16(v: u8x16) u8 {
    let mut x = reg(v);
    x = wasm_u8x16_max(x, unsafe wasm_i8x16_shuffle(x, x, 8, 9, 10, 11, 12, 13, 14, 15, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_u8x16_max(x, unsafe wasm_i8x16_shuffle(x, x, 4, 5, 6, 7, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_u8x16_max(x, unsafe wasm_i8x16_shuffle(x, x, 2, 3, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    x = wasm_u8x16_max(x, unsafe wasm_i8x16_shuffle(x, x, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15));
    return unsafe wasm_u8x16_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceAdd, [cpu::Feature::Simd128])
fn reduce_add_i16x8(v: i16x8) i16 {
    let mut x = reg(v);
    x = wasm_i16x8_add(x, unsafe wasm_i16x8_shuffle(x, x, 4, 5, 6, 7, 4, 5, 6, 7));
    x = wasm_i16x8_add(x, unsafe wasm_i16x8_shuffle(x, x, 2, 3, 2, 3, 4, 5, 6, 7));
    x = wasm_i16x8_add(x, unsafe wasm_i16x8_shuffle(x, x, 1, 1, 2, 3, 4, 5, 6, 7));
    return unsafe wasm_i16x8_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceMin, [cpu::Feature::Simd128])
fn reduce_min_i16x8(v: i16x8) i16 {
    let mut x = reg(v);
    x = wasm_i16x8_min(x, unsafe wasm_i16x8_shuffle(x, x, 4, 5, 6, 7, 4, 5, 6, 7));
    x = wasm_i16x8_min(x, unsafe wasm_i16x8_shuffle(x, x, 2, 3, 2, 3, 4, 5, 6, 7));
    x = wasm_i16x8_min(x, unsafe wasm_i16x8_shuffle(x, x, 1, 1, 2, 3, 4, 5, 6, 7));
    return unsafe wasm_i16x8_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceMax, [cpu::Feature::Simd128])
fn reduce_max_i16x8(v: i16x8) i16 {
    let mut x = reg(v);
    x = wasm_i16x8_max(x, unsafe wasm_i16x8_shuffle(x, x, 4, 5, 6, 7, 4, 5, 6, 7));
    x = wasm_i16x8_max(x, unsafe wasm_i16x8_shuffle(x, x, 2, 3, 2, 3, 4, 5, 6, 7));
    x = wasm_i16x8_max(x, unsafe wasm_i16x8_shuffle(x, x, 1, 1, 2, 3, 4, 5, 6, 7));
    return unsafe wasm_i16x8_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceAdd, [cpu::Feature::Simd128])
fn reduce_add_u16x8(v: u16x8) u16 {
    let mut x = reg(v);
    x = wasm_i16x8_add(x, unsafe wasm_i16x8_shuffle(x, x, 4, 5, 6, 7, 4, 5, 6, 7));
    x = wasm_i16x8_add(x, unsafe wasm_i16x8_shuffle(x, x, 2, 3, 2, 3, 4, 5, 6, 7));
    x = wasm_i16x8_add(x, unsafe wasm_i16x8_shuffle(x, x, 1, 1, 2, 3, 4, 5, 6, 7));
    return unsafe wasm_u16x8_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceMin, [cpu::Feature::Simd128])
fn reduce_min_u16x8(v: u16x8) u16 {
    let mut x = reg(v);
    x = wasm_u16x8_min(x, unsafe wasm_i16x8_shuffle(x, x, 4, 5, 6, 7, 4, 5, 6, 7));
    x = wasm_u16x8_min(x, unsafe wasm_i16x8_shuffle(x, x, 2, 3, 2, 3, 4, 5, 6, 7));
    x = wasm_u16x8_min(x, unsafe wasm_i16x8_shuffle(x, x, 1, 1, 2, 3, 4, 5, 6, 7));
    return unsafe wasm_u16x8_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceMax, [cpu::Feature::Simd128])
fn reduce_max_u16x8(v: u16x8) u16 {
    let mut x = reg(v);
    x = wasm_u16x8_max(x, unsafe wasm_i16x8_shuffle(x, x, 4, 5, 6, 7, 4, 5, 6, 7));
    x = wasm_u16x8_max(x, unsafe wasm_i16x8_shuffle(x, x, 2, 3, 2, 3, 4, 5, 6, 7));
    x = wasm_u16x8_max(x, unsafe wasm_i16x8_shuffle(x, x, 1, 1, 2, 3, 4, 5, 6, 7));
    return unsafe wasm_u16x8_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceAdd, [cpu::Feature::Simd128])
fn reduce_add_i32x4(v: i32x4) i32 {
    let mut x = reg(v);
    x = wasm_i32x4_add(x, unsafe wasm_i32x4_shuffle(x, x, 2, 3, 2, 3));
    x = wasm_i32x4_add(x, unsafe wasm_i32x4_shuffle(x, x, 1, 1, 2, 3));
    return unsafe wasm_i32x4_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceMin, [cpu::Feature::Simd128])
fn reduce_min_i32x4(v: i32x4) i32 {
    let mut x = reg(v);
    x = wasm_i32x4_min(x, unsafe wasm_i32x4_shuffle(x, x, 2, 3, 2, 3));
    x = wasm_i32x4_min(x, unsafe wasm_i32x4_shuffle(x, x, 1, 1, 2, 3));
    return unsafe wasm_i32x4_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceMax, [cpu::Feature::Simd128])
fn reduce_max_i32x4(v: i32x4) i32 {
    let mut x = reg(v);
    x = wasm_i32x4_max(x, unsafe wasm_i32x4_shuffle(x, x, 2, 3, 2, 3));
    x = wasm_i32x4_max(x, unsafe wasm_i32x4_shuffle(x, x, 1, 1, 2, 3));
    return unsafe wasm_i32x4_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceAdd, [cpu::Feature::Simd128])
fn reduce_add_u32x4(v: u32x4) u32 {
    let mut x = reg(v);
    x = wasm_i32x4_add(x, unsafe wasm_i32x4_shuffle(x, x, 2, 3, 2, 3));
    x = wasm_i32x4_add(x, unsafe wasm_i32x4_shuffle(x, x, 1, 1, 2, 3));
    return unsafe wasm_u32x4_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceMin, [cpu::Feature::Simd128])
fn reduce_min_u32x4(v: u32x4) u32 {
    let mut x = reg(v);
    x = wasm_u32x4_min(x, unsafe wasm_i32x4_shuffle(x, x, 2, 3, 2, 3));
    x = wasm_u32x4_min(x, unsafe wasm_i32x4_shuffle(x, x, 1, 1, 2, 3));
    return unsafe wasm_u32x4_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceMax, [cpu::Feature::Simd128])
fn reduce_max_u32x4(v: u32x4) u32 {
    let mut x = reg(v);
    x = wasm_u32x4_max(x, unsafe wasm_i32x4_shuffle(x, x, 2, 3, 2, 3));
    x = wasm_u32x4_max(x, unsafe wasm_i32x4_shuffle(x, x, 1, 1, 2, 3));
    return unsafe wasm_u32x4_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceAdd, [cpu::Feature::Simd128])
fn reduce_add_i64x2(v: i64x2) i64 {
    let mut x = reg(v);
    x = wasm_i64x2_add(x, unsafe wasm_i64x2_shuffle(x, x, 1, 1));
    return unsafe wasm_i64x2_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::ReduceAdd, [cpu::Feature::Simd128])
fn reduce_add_u64x2(v: u64x2) u64 {
    let mut x = reg(v);
    x = wasm_i64x2_add(x, unsafe wasm_i64x2_shuffle(x, x, 1, 1));
    return unsafe wasm_u64x2_extract_lane(x, 0);
}

@arch(wasm32)
@simd_impl(simd::Op::And, [cpu::Feature::Simd128])
fn and_i8x16(a: i8x16, b: i8x16) i8x16 {
    return vec::<i8, 16>(wasm_v128_and(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Or, [cpu::Feature::Simd128])
fn or_i8x16(a: i8x16, b: i8x16) i8x16 {
    return vec::<i8, 16>(wasm_v128_or(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Xor, [cpu::Feature::Simd128])
fn xor_i8x16(a: i8x16, b: i8x16) i8x16 {
    return vec::<i8, 16>(wasm_v128_xor(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Not, [cpu::Feature::Simd128])
fn not_i8x16(a: i8x16) i8x16 {
    return vec::<i8, 16>(wasm_v128_not(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_i8x16_u8x16(a: i8x16) u8x16 {
    return vec::<u8, 16>(reg(a));
}

@arch(wasm32)
@simd_impl(simd::Op::And, [cpu::Feature::Simd128])
fn and_u8x16(a: u8x16, b: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_v128_and(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Or, [cpu::Feature::Simd128])
fn or_u8x16(a: u8x16, b: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_v128_or(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Xor, [cpu::Feature::Simd128])
fn xor_u8x16(a: u8x16, b: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_v128_xor(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Not, [cpu::Feature::Simd128])
fn not_u8x16(a: u8x16) u8x16 {
    return vec::<u8, 16>(wasm_v128_not(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_u8x16_i8x16(a: u8x16) i8x16 {
    return vec::<i8, 16>(reg(a));
}

@arch(wasm32)
@simd_impl(simd::Op::And, [cpu::Feature::Simd128])
fn and_i16x8(a: i16x8, b: i16x8) i16x8 {
    return vec::<i16, 8>(wasm_v128_and(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Or, [cpu::Feature::Simd128])
fn or_i16x8(a: i16x8, b: i16x8) i16x8 {
    return vec::<i16, 8>(wasm_v128_or(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Xor, [cpu::Feature::Simd128])
fn xor_i16x8(a: i16x8, b: i16x8) i16x8 {
    return vec::<i16, 8>(wasm_v128_xor(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Not, [cpu::Feature::Simd128])
fn not_i16x8(a: i16x8) i16x8 {
    return vec::<i16, 8>(wasm_v128_not(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_i16x8_u16x8(a: i16x8) u16x8 {
    return vec::<u16, 8>(reg(a));
}

@arch(wasm32)
@simd_impl(simd::Op::And, [cpu::Feature::Simd128])
fn and_u16x8(a: u16x8, b: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_v128_and(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Or, [cpu::Feature::Simd128])
fn or_u16x8(a: u16x8, b: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_v128_or(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Xor, [cpu::Feature::Simd128])
fn xor_u16x8(a: u16x8, b: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_v128_xor(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Not, [cpu::Feature::Simd128])
fn not_u16x8(a: u16x8) u16x8 {
    return vec::<u16, 8>(wasm_v128_not(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_u16x8_i16x8(a: u16x8) i16x8 {
    return vec::<i16, 8>(reg(a));
}

@arch(wasm32)
@simd_impl(simd::Op::And, [cpu::Feature::Simd128])
fn and_i32x4(a: i32x4, b: i32x4) i32x4 {
    return vec::<i32, 4>(wasm_v128_and(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Or, [cpu::Feature::Simd128])
fn or_i32x4(a: i32x4, b: i32x4) i32x4 {
    return vec::<i32, 4>(wasm_v128_or(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Xor, [cpu::Feature::Simd128])
fn xor_i32x4(a: i32x4, b: i32x4) i32x4 {
    return vec::<i32, 4>(wasm_v128_xor(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Not, [cpu::Feature::Simd128])
fn not_i32x4(a: i32x4) i32x4 {
    return vec::<i32, 4>(wasm_v128_not(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_i32x4_u32x4(a: i32x4) u32x4 {
    return vec::<u32, 4>(reg(a));
}

@arch(wasm32)
@simd_impl(simd::Op::And, [cpu::Feature::Simd128])
fn and_u32x4(a: u32x4, b: u32x4) u32x4 {
    return vec::<u32, 4>(wasm_v128_and(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Or, [cpu::Feature::Simd128])
fn or_u32x4(a: u32x4, b: u32x4) u32x4 {
    return vec::<u32, 4>(wasm_v128_or(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Xor, [cpu::Feature::Simd128])
fn xor_u32x4(a: u32x4, b: u32x4) u32x4 {
    return vec::<u32, 4>(wasm_v128_xor(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Not, [cpu::Feature::Simd128])
fn not_u32x4(a: u32x4) u32x4 {
    return vec::<u32, 4>(wasm_v128_not(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_u32x4_i32x4(a: u32x4) i32x4 {
    return vec::<i32, 4>(reg(a));
}

@arch(wasm32)
@simd_impl(simd::Op::And, [cpu::Feature::Simd128])
fn and_i64x2(a: i64x2, b: i64x2) i64x2 {
    return vec::<i64, 2>(wasm_v128_and(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Or, [cpu::Feature::Simd128])
fn or_i64x2(a: i64x2, b: i64x2) i64x2 {
    return vec::<i64, 2>(wasm_v128_or(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Xor, [cpu::Feature::Simd128])
fn xor_i64x2(a: i64x2, b: i64x2) i64x2 {
    return vec::<i64, 2>(wasm_v128_xor(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Not, [cpu::Feature::Simd128])
fn not_i64x2(a: i64x2) i64x2 {
    return vec::<i64, 2>(wasm_v128_not(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_i64x2_u64x2(a: i64x2) u64x2 {
    return vec::<u64, 2>(reg(a));
}

@arch(wasm32)
@simd_impl(simd::Op::And, [cpu::Feature::Simd128])
fn and_u64x2(a: u64x2, b: u64x2) u64x2 {
    return vec::<u64, 2>(wasm_v128_and(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Or, [cpu::Feature::Simd128])
fn or_u64x2(a: u64x2, b: u64x2) u64x2 {
    return vec::<u64, 2>(wasm_v128_or(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Xor, [cpu::Feature::Simd128])
fn xor_u64x2(a: u64x2, b: u64x2) u64x2 {
    return vec::<u64, 2>(wasm_v128_xor(reg(a), reg(b)));
}

@arch(wasm32)
@simd_impl(simd::Op::Not, [cpu::Feature::Simd128])
fn not_u64x2(a: u64x2) u64x2 {
    return vec::<u64, 2>(wasm_v128_not(reg(a)));
}

@arch(wasm32)
@simd_impl(simd::Op::Cast, [cpu::Feature::Simd128])
fn cast_u64x2_i64x2(a: u64x2) i64x2 {
    return vec::<i64, 2>(reg(a));
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Simd128])
fn overflow_add_i8x16(a: i8x16, b: i8x16) mask16 {
    let x = reg(a);
    let y = reg(b);
    let r = wasm_i8x16_add(x, y);
    return (wasm_i8x16_bitmask(wasm_v128_and(wasm_v128_xor(x, r), wasm_v128_xor(y, r))) as u64) as mask16;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Simd128])
fn overflow_sub_i8x16(a: i8x16, b: i8x16) mask16 {
    let x = reg(a);
    let y = reg(b);
    let r = wasm_i8x16_sub(x, y);
    return (wasm_i8x16_bitmask(wasm_v128_and(wasm_v128_xor(x, y), wasm_v128_xor(x, r))) as u64) as mask16;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowMul, [cpu::Feature::Simd128])
fn overflow_mul_i8x16(a: i8x16, b: i8x16) mask16 {
    let x = reg(a);
    let y = reg(b);
    let l = wasm_i16x8_extmul_low_i8x16(x, y);
    let lb = wasm_i16x8_bitmask(wasm_i16x8_ne(l, wasm_i16x8_shr(wasm_i16x8_shl(l, 8), 8))) as u64;
    let h = wasm_i16x8_extmul_high_i8x16(x, y);
    let hb = wasm_i16x8_bitmask(wasm_i16x8_ne(h, wasm_i16x8_shr(wasm_i16x8_shl(h, 8), 8))) as u64;
    return (lb | hb << 8) as mask16;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Simd128])
fn overflow_add_u8x16(a: u8x16, b: u8x16) mask16 {
    let x = reg(a);
    let y = reg(b);
    let r = wasm_i8x16_add(x, y);
    return (wasm_i8x16_bitmask(wasm_v128_or(wasm_v128_and(x, y), wasm_v128_andnot(wasm_v128_or(x, y), r))) as u64) as mask16;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Simd128])
fn overflow_sub_u8x16(a: u8x16, b: u8x16) mask16 {
    let x = reg(a);
    let y = reg(b);
    let r = wasm_i8x16_sub(x, y);
    return (wasm_i8x16_bitmask(wasm_v128_or(wasm_v128_andnot(y, x), wasm_v128_andnot(r, wasm_v128_xor(x, y)))) as u64) as mask16;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowMul, [cpu::Feature::Simd128])
fn overflow_mul_u8x16(a: u8x16, b: u8x16) mask16 {
    let x = reg(a);
    let y = reg(b);
    let l = wasm_u16x8_extmul_low_u8x16(x, y);
    let lb = wasm_i16x8_bitmask(wasm_i16x8_ne(wasm_u16x8_shr(l, 8), wasm_i16x8_splat(0))) as u64;
    let h = wasm_u16x8_extmul_high_u8x16(x, y);
    let hb = wasm_i16x8_bitmask(wasm_i16x8_ne(wasm_u16x8_shr(h, 8), wasm_i16x8_splat(0))) as u64;
    return (lb | hb << 8) as mask16;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Simd128])
fn overflow_add_i16x8(a: i16x8, b: i16x8) mask8 {
    let x = reg(a);
    let y = reg(b);
    let r = wasm_i16x8_add(x, y);
    return (wasm_i16x8_bitmask(wasm_v128_and(wasm_v128_xor(x, r), wasm_v128_xor(y, r))) as u64) as mask8;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Simd128])
fn overflow_sub_i16x8(a: i16x8, b: i16x8) mask8 {
    let x = reg(a);
    let y = reg(b);
    let r = wasm_i16x8_sub(x, y);
    return (wasm_i16x8_bitmask(wasm_v128_and(wasm_v128_xor(x, y), wasm_v128_xor(x, r))) as u64) as mask8;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowMul, [cpu::Feature::Simd128])
fn overflow_mul_i16x8(a: i16x8, b: i16x8) mask8 {
    let x = reg(a);
    let y = reg(b);
    let l = wasm_i32x4_extmul_low_i16x8(x, y);
    let lb = wasm_i32x4_bitmask(wasm_i32x4_ne(l, wasm_i32x4_shr(wasm_i32x4_shl(l, 16), 16))) as u64;
    let h = wasm_i32x4_extmul_high_i16x8(x, y);
    let hb = wasm_i32x4_bitmask(wasm_i32x4_ne(h, wasm_i32x4_shr(wasm_i32x4_shl(h, 16), 16))) as u64;
    return (lb | hb << 4) as mask8;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Simd128])
fn overflow_add_u16x8(a: u16x8, b: u16x8) mask8 {
    let x = reg(a);
    let y = reg(b);
    let r = wasm_i16x8_add(x, y);
    return (wasm_i16x8_bitmask(wasm_v128_or(wasm_v128_and(x, y), wasm_v128_andnot(wasm_v128_or(x, y), r))) as u64) as mask8;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Simd128])
fn overflow_sub_u16x8(a: u16x8, b: u16x8) mask8 {
    let x = reg(a);
    let y = reg(b);
    let r = wasm_i16x8_sub(x, y);
    return (wasm_i16x8_bitmask(wasm_v128_or(wasm_v128_andnot(y, x), wasm_v128_andnot(r, wasm_v128_xor(x, y)))) as u64) as mask8;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowMul, [cpu::Feature::Simd128])
fn overflow_mul_u16x8(a: u16x8, b: u16x8) mask8 {
    let x = reg(a);
    let y = reg(b);
    let l = wasm_u32x4_extmul_low_u16x8(x, y);
    let lb = wasm_i32x4_bitmask(wasm_i32x4_ne(wasm_u32x4_shr(l, 16), wasm_i32x4_splat(0))) as u64;
    let h = wasm_u32x4_extmul_high_u16x8(x, y);
    let hb = wasm_i32x4_bitmask(wasm_i32x4_ne(wasm_u32x4_shr(h, 16), wasm_i32x4_splat(0))) as u64;
    return (lb | hb << 4) as mask8;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Simd128])
fn overflow_add_i32x4(a: i32x4, b: i32x4) mask4 {
    let x = reg(a);
    let y = reg(b);
    let r = wasm_i32x4_add(x, y);
    return (wasm_i32x4_bitmask(wasm_v128_and(wasm_v128_xor(x, r), wasm_v128_xor(y, r))) as u64) as mask4;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Simd128])
fn overflow_sub_i32x4(a: i32x4, b: i32x4) mask4 {
    let x = reg(a);
    let y = reg(b);
    let r = wasm_i32x4_sub(x, y);
    return (wasm_i32x4_bitmask(wasm_v128_and(wasm_v128_xor(x, y), wasm_v128_xor(x, r))) as u64) as mask4;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowMul, [cpu::Feature::Simd128])
fn overflow_mul_i32x4(a: i32x4, b: i32x4) mask4 {
    let x = reg(a);
    let y = reg(b);
    let l = wasm_i64x2_extmul_low_i32x4(x, y);
    let lb = wasm_i64x2_bitmask(wasm_i64x2_ne(l, wasm_i64x2_shr(wasm_i64x2_shl(l, 32), 32))) as u64;
    let h = wasm_i64x2_extmul_high_i32x4(x, y);
    let hb = wasm_i64x2_bitmask(wasm_i64x2_ne(h, wasm_i64x2_shr(wasm_i64x2_shl(h, 32), 32))) as u64;
    return (lb | hb << 2) as mask4;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Simd128])
fn overflow_add_u32x4(a: u32x4, b: u32x4) mask4 {
    let x = reg(a);
    let y = reg(b);
    let r = wasm_i32x4_add(x, y);
    return (wasm_i32x4_bitmask(wasm_v128_or(wasm_v128_and(x, y), wasm_v128_andnot(wasm_v128_or(x, y), r))) as u64) as mask4;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Simd128])
fn overflow_sub_u32x4(a: u32x4, b: u32x4) mask4 {
    let x = reg(a);
    let y = reg(b);
    let r = wasm_i32x4_sub(x, y);
    return (wasm_i32x4_bitmask(wasm_v128_or(wasm_v128_andnot(y, x), wasm_v128_andnot(r, wasm_v128_xor(x, y)))) as u64) as mask4;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowMul, [cpu::Feature::Simd128])
fn overflow_mul_u32x4(a: u32x4, b: u32x4) mask4 {
    let x = reg(a);
    let y = reg(b);
    let l = wasm_u64x2_extmul_low_u32x4(x, y);
    let lb = wasm_i64x2_bitmask(wasm_i64x2_ne(wasm_u64x2_shr(l, 32), wasm_i64x2_splat(0))) as u64;
    let h = wasm_u64x2_extmul_high_u32x4(x, y);
    let hb = wasm_i64x2_bitmask(wasm_i64x2_ne(wasm_u64x2_shr(h, 32), wasm_i64x2_splat(0))) as u64;
    return (lb | hb << 2) as mask4;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Simd128])
fn overflow_add_i64x2(a: i64x2, b: i64x2) mask2 {
    let x = reg(a);
    let y = reg(b);
    let r = wasm_i64x2_add(x, y);
    return (wasm_i64x2_bitmask(wasm_v128_and(wasm_v128_xor(x, r), wasm_v128_xor(y, r))) as u64) as mask2;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Simd128])
fn overflow_sub_i64x2(a: i64x2, b: i64x2) mask2 {
    let x = reg(a);
    let y = reg(b);
    let r = wasm_i64x2_sub(x, y);
    return (wasm_i64x2_bitmask(wasm_v128_and(wasm_v128_xor(x, y), wasm_v128_xor(x, r))) as u64) as mask2;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Simd128])
fn overflow_add_u64x2(a: u64x2, b: u64x2) mask2 {
    let x = reg(a);
    let y = reg(b);
    let r = wasm_i64x2_add(x, y);
    return (wasm_i64x2_bitmask(wasm_v128_or(wasm_v128_and(x, y), wasm_v128_andnot(wasm_v128_or(x, y), r))) as u64) as mask2;
}

@arch(wasm32)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Simd128])
fn overflow_sub_u64x2(a: u64x2, b: u64x2) mask2 {
    let x = reg(a);
    let y = reg(b);
    let r = wasm_i64x2_sub(x, y);
    return (wasm_i64x2_bitmask(wasm_v128_or(wasm_v128_andnot(y, x), wasm_v128_andnot(r, wasm_v128_xor(x, y)))) as u64) as mask2;
}

@arch(wasm32)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Simd128])
fn load_masked_i8x16(p: *const i8, m: mask16, fb: i8x16) i8x16 {
    let bits = m as u64;
    if bits == 65535 {
        return vec::<i8, 16>(unsafe wasm_v128_load(p));
    }
    let mut r = reg(fb);
    if (bits >> 0 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p, r, 0);
    }
    if (bits >> 1 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 1, r, 1);
    }
    if (bits >> 2 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 2, r, 2);
    }
    if (bits >> 3 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 3, r, 3);
    }
    if (bits >> 4 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 4, r, 4);
    }
    if (bits >> 5 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 5, r, 5);
    }
    if (bits >> 6 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 6, r, 6);
    }
    if (bits >> 7 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 7, r, 7);
    }
    if (bits >> 8 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 8, r, 8);
    }
    if (bits >> 9 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 9, r, 9);
    }
    if (bits >> 10 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 10, r, 10);
    }
    if (bits >> 11 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 11, r, 11);
    }
    if (bits >> 12 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 12, r, 12);
    }
    if (bits >> 13 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 13, r, 13);
    }
    if (bits >> 14 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 14, r, 14);
    }
    if (bits >> 15 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 15, r, 15);
    }
    return vec::<i8, 16>(r);
}

@arch(wasm32)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Simd128])
fn store_masked_i8x16(p: *mut i8, m: mask16, v: i8x16) {
    let bits = m as u64;
    if bits == 65535 {
        unsafe wasm_v128_store(p, reg(v));
        return;
    }
    let x = reg(v);
    if (bits >> 0 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p, x, 0);
    }
    if (bits >> 1 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 1, x, 1);
    }
    if (bits >> 2 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 2, x, 2);
    }
    if (bits >> 3 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 3, x, 3);
    }
    if (bits >> 4 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 4, x, 4);
    }
    if (bits >> 5 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 5, x, 5);
    }
    if (bits >> 6 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 6, x, 6);
    }
    if (bits >> 7 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 7, x, 7);
    }
    if (bits >> 8 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 8, x, 8);
    }
    if (bits >> 9 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 9, x, 9);
    }
    if (bits >> 10 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 10, x, 10);
    }
    if (bits >> 11 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 11, x, 11);
    }
    if (bits >> 12 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 12, x, 12);
    }
    if (bits >> 13 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 13, x, 13);
    }
    if (bits >> 14 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 14, x, 14);
    }
    if (bits >> 15 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 15, x, 15);
    }
}

@arch(wasm32)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Simd128])
fn load_masked_u8x16(p: *const u8, m: mask16, fb: u8x16) u8x16 {
    let bits = m as u64;
    if bits == 65535 {
        return vec::<u8, 16>(unsafe wasm_v128_load(p));
    }
    let mut r = reg(fb);
    if (bits >> 0 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p, r, 0);
    }
    if (bits >> 1 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 1, r, 1);
    }
    if (bits >> 2 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 2, r, 2);
    }
    if (bits >> 3 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 3, r, 3);
    }
    if (bits >> 4 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 4, r, 4);
    }
    if (bits >> 5 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 5, r, 5);
    }
    if (bits >> 6 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 6, r, 6);
    }
    if (bits >> 7 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 7, r, 7);
    }
    if (bits >> 8 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 8, r, 8);
    }
    if (bits >> 9 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 9, r, 9);
    }
    if (bits >> 10 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 10, r, 10);
    }
    if (bits >> 11 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 11, r, 11);
    }
    if (bits >> 12 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 12, r, 12);
    }
    if (bits >> 13 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 13, r, 13);
    }
    if (bits >> 14 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 14, r, 14);
    }
    if (bits >> 15 & 1) != 0 {
        r = unsafe wasm_v128_load8_lane(p + 15, r, 15);
    }
    return vec::<u8, 16>(r);
}

@arch(wasm32)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Simd128])
fn store_masked_u8x16(p: *mut u8, m: mask16, v: u8x16) {
    let bits = m as u64;
    if bits == 65535 {
        unsafe wasm_v128_store(p, reg(v));
        return;
    }
    let x = reg(v);
    if (bits >> 0 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p, x, 0);
    }
    if (bits >> 1 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 1, x, 1);
    }
    if (bits >> 2 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 2, x, 2);
    }
    if (bits >> 3 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 3, x, 3);
    }
    if (bits >> 4 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 4, x, 4);
    }
    if (bits >> 5 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 5, x, 5);
    }
    if (bits >> 6 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 6, x, 6);
    }
    if (bits >> 7 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 7, x, 7);
    }
    if (bits >> 8 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 8, x, 8);
    }
    if (bits >> 9 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 9, x, 9);
    }
    if (bits >> 10 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 10, x, 10);
    }
    if (bits >> 11 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 11, x, 11);
    }
    if (bits >> 12 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 12, x, 12);
    }
    if (bits >> 13 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 13, x, 13);
    }
    if (bits >> 14 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 14, x, 14);
    }
    if (bits >> 15 & 1) != 0 {
        unsafe wasm_v128_store8_lane(p + 15, x, 15);
    }
}

@arch(wasm32)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Simd128])
fn load_masked_i16x8(p: *const i16, m: mask8, fb: i16x8) i16x8 {
    let bits = m as u64;
    if bits == 255 {
        return vec::<i16, 8>(unsafe wasm_v128_load(p));
    }
    let mut r = reg(fb);
    if (bits >> 0 & 1) != 0 {
        r = unsafe wasm_v128_load16_lane(p, r, 0);
    }
    if (bits >> 1 & 1) != 0 {
        r = unsafe wasm_v128_load16_lane(p + 1, r, 1);
    }
    if (bits >> 2 & 1) != 0 {
        r = unsafe wasm_v128_load16_lane(p + 2, r, 2);
    }
    if (bits >> 3 & 1) != 0 {
        r = unsafe wasm_v128_load16_lane(p + 3, r, 3);
    }
    if (bits >> 4 & 1) != 0 {
        r = unsafe wasm_v128_load16_lane(p + 4, r, 4);
    }
    if (bits >> 5 & 1) != 0 {
        r = unsafe wasm_v128_load16_lane(p + 5, r, 5);
    }
    if (bits >> 6 & 1) != 0 {
        r = unsafe wasm_v128_load16_lane(p + 6, r, 6);
    }
    if (bits >> 7 & 1) != 0 {
        r = unsafe wasm_v128_load16_lane(p + 7, r, 7);
    }
    return vec::<i16, 8>(r);
}

@arch(wasm32)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Simd128])
fn store_masked_i16x8(p: *mut i16, m: mask8, v: i16x8) {
    let bits = m as u64;
    if bits == 255 {
        unsafe wasm_v128_store(p, reg(v));
        return;
    }
    let x = reg(v);
    if (bits >> 0 & 1) != 0 {
        unsafe wasm_v128_store16_lane(p, x, 0);
    }
    if (bits >> 1 & 1) != 0 {
        unsafe wasm_v128_store16_lane(p + 1, x, 1);
    }
    if (bits >> 2 & 1) != 0 {
        unsafe wasm_v128_store16_lane(p + 2, x, 2);
    }
    if (bits >> 3 & 1) != 0 {
        unsafe wasm_v128_store16_lane(p + 3, x, 3);
    }
    if (bits >> 4 & 1) != 0 {
        unsafe wasm_v128_store16_lane(p + 4, x, 4);
    }
    if (bits >> 5 & 1) != 0 {
        unsafe wasm_v128_store16_lane(p + 5, x, 5);
    }
    if (bits >> 6 & 1) != 0 {
        unsafe wasm_v128_store16_lane(p + 6, x, 6);
    }
    if (bits >> 7 & 1) != 0 {
        unsafe wasm_v128_store16_lane(p + 7, x, 7);
    }
}

@arch(wasm32)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Simd128])
fn load_masked_u16x8(p: *const u16, m: mask8, fb: u16x8) u16x8 {
    let bits = m as u64;
    if bits == 255 {
        return vec::<u16, 8>(unsafe wasm_v128_load(p));
    }
    let mut r = reg(fb);
    if (bits >> 0 & 1) != 0 {
        r = unsafe wasm_v128_load16_lane(p, r, 0);
    }
    if (bits >> 1 & 1) != 0 {
        r = unsafe wasm_v128_load16_lane(p + 1, r, 1);
    }
    if (bits >> 2 & 1) != 0 {
        r = unsafe wasm_v128_load16_lane(p + 2, r, 2);
    }
    if (bits >> 3 & 1) != 0 {
        r = unsafe wasm_v128_load16_lane(p + 3, r, 3);
    }
    if (bits >> 4 & 1) != 0 {
        r = unsafe wasm_v128_load16_lane(p + 4, r, 4);
    }
    if (bits >> 5 & 1) != 0 {
        r = unsafe wasm_v128_load16_lane(p + 5, r, 5);
    }
    if (bits >> 6 & 1) != 0 {
        r = unsafe wasm_v128_load16_lane(p + 6, r, 6);
    }
    if (bits >> 7 & 1) != 0 {
        r = unsafe wasm_v128_load16_lane(p + 7, r, 7);
    }
    return vec::<u16, 8>(r);
}

@arch(wasm32)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Simd128])
fn store_masked_u16x8(p: *mut u16, m: mask8, v: u16x8) {
    let bits = m as u64;
    if bits == 255 {
        unsafe wasm_v128_store(p, reg(v));
        return;
    }
    let x = reg(v);
    if (bits >> 0 & 1) != 0 {
        unsafe wasm_v128_store16_lane(p, x, 0);
    }
    if (bits >> 1 & 1) != 0 {
        unsafe wasm_v128_store16_lane(p + 1, x, 1);
    }
    if (bits >> 2 & 1) != 0 {
        unsafe wasm_v128_store16_lane(p + 2, x, 2);
    }
    if (bits >> 3 & 1) != 0 {
        unsafe wasm_v128_store16_lane(p + 3, x, 3);
    }
    if (bits >> 4 & 1) != 0 {
        unsafe wasm_v128_store16_lane(p + 4, x, 4);
    }
    if (bits >> 5 & 1) != 0 {
        unsafe wasm_v128_store16_lane(p + 5, x, 5);
    }
    if (bits >> 6 & 1) != 0 {
        unsafe wasm_v128_store16_lane(p + 6, x, 6);
    }
    if (bits >> 7 & 1) != 0 {
        unsafe wasm_v128_store16_lane(p + 7, x, 7);
    }
}

@arch(wasm32)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Simd128])
fn load_masked_i32x4(p: *const i32, m: mask4, fb: i32x4) i32x4 {
    let bits = m as u64;
    if bits == 15 {
        return vec::<i32, 4>(unsafe wasm_v128_load(p));
    }
    let mut r = reg(fb);
    if (bits >> 0 & 1) != 0 {
        r = unsafe wasm_v128_load32_lane(p, r, 0);
    }
    if (bits >> 1 & 1) != 0 {
        r = unsafe wasm_v128_load32_lane(p + 1, r, 1);
    }
    if (bits >> 2 & 1) != 0 {
        r = unsafe wasm_v128_load32_lane(p + 2, r, 2);
    }
    if (bits >> 3 & 1) != 0 {
        r = unsafe wasm_v128_load32_lane(p + 3, r, 3);
    }
    return vec::<i32, 4>(r);
}

@arch(wasm32)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Simd128])
fn store_masked_i32x4(p: *mut i32, m: mask4, v: i32x4) {
    let bits = m as u64;
    if bits == 15 {
        unsafe wasm_v128_store(p, reg(v));
        return;
    }
    let x = reg(v);
    if (bits >> 0 & 1) != 0 {
        unsafe wasm_v128_store32_lane(p, x, 0);
    }
    if (bits >> 1 & 1) != 0 {
        unsafe wasm_v128_store32_lane(p + 1, x, 1);
    }
    if (bits >> 2 & 1) != 0 {
        unsafe wasm_v128_store32_lane(p + 2, x, 2);
    }
    if (bits >> 3 & 1) != 0 {
        unsafe wasm_v128_store32_lane(p + 3, x, 3);
    }
}

@arch(wasm32)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Simd128])
fn load_masked_u32x4(p: *const u32, m: mask4, fb: u32x4) u32x4 {
    let bits = m as u64;
    if bits == 15 {
        return vec::<u32, 4>(unsafe wasm_v128_load(p));
    }
    let mut r = reg(fb);
    if (bits >> 0 & 1) != 0 {
        r = unsafe wasm_v128_load32_lane(p, r, 0);
    }
    if (bits >> 1 & 1) != 0 {
        r = unsafe wasm_v128_load32_lane(p + 1, r, 1);
    }
    if (bits >> 2 & 1) != 0 {
        r = unsafe wasm_v128_load32_lane(p + 2, r, 2);
    }
    if (bits >> 3 & 1) != 0 {
        r = unsafe wasm_v128_load32_lane(p + 3, r, 3);
    }
    return vec::<u32, 4>(r);
}

@arch(wasm32)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Simd128])
fn store_masked_u32x4(p: *mut u32, m: mask4, v: u32x4) {
    let bits = m as u64;
    if bits == 15 {
        unsafe wasm_v128_store(p, reg(v));
        return;
    }
    let x = reg(v);
    if (bits >> 0 & 1) != 0 {
        unsafe wasm_v128_store32_lane(p, x, 0);
    }
    if (bits >> 1 & 1) != 0 {
        unsafe wasm_v128_store32_lane(p + 1, x, 1);
    }
    if (bits >> 2 & 1) != 0 {
        unsafe wasm_v128_store32_lane(p + 2, x, 2);
    }
    if (bits >> 3 & 1) != 0 {
        unsafe wasm_v128_store32_lane(p + 3, x, 3);
    }
}

@arch(wasm32)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Simd128])
fn load_masked_i64x2(p: *const i64, m: mask2, fb: i64x2) i64x2 {
    let bits = m as u64;
    if bits == 3 {
        return vec::<i64, 2>(unsafe wasm_v128_load(p));
    }
    let mut r = reg(fb);
    if (bits >> 0 & 1) != 0 {
        r = unsafe wasm_v128_load64_lane(p, r, 0);
    }
    if (bits >> 1 & 1) != 0 {
        r = unsafe wasm_v128_load64_lane(p + 1, r, 1);
    }
    return vec::<i64, 2>(r);
}

@arch(wasm32)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Simd128])
fn store_masked_i64x2(p: *mut i64, m: mask2, v: i64x2) {
    let bits = m as u64;
    if bits == 3 {
        unsafe wasm_v128_store(p, reg(v));
        return;
    }
    let x = reg(v);
    if (bits >> 0 & 1) != 0 {
        unsafe wasm_v128_store64_lane(p, x, 0);
    }
    if (bits >> 1 & 1) != 0 {
        unsafe wasm_v128_store64_lane(p + 1, x, 1);
    }
}

@arch(wasm32)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Simd128])
fn load_masked_u64x2(p: *const u64, m: mask2, fb: u64x2) u64x2 {
    let bits = m as u64;
    if bits == 3 {
        return vec::<u64, 2>(unsafe wasm_v128_load(p));
    }
    let mut r = reg(fb);
    if (bits >> 0 & 1) != 0 {
        r = unsafe wasm_v128_load64_lane(p, r, 0);
    }
    if (bits >> 1 & 1) != 0 {
        r = unsafe wasm_v128_load64_lane(p + 1, r, 1);
    }
    return vec::<u64, 2>(r);
}

@arch(wasm32)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Simd128])
fn store_masked_u64x2(p: *mut u64, m: mask2, v: u64x2) {
    let bits = m as u64;
    if bits == 3 {
        unsafe wasm_v128_store(p, reg(v));
        return;
    }
    let x = reg(v);
    if (bits >> 0 & 1) != 0 {
        unsafe wasm_v128_store64_lane(p, x, 0);
    }
    if (bits >> 1 & 1) != 0 {
        unsafe wasm_v128_store64_lane(p + 1, x, 1);
    }
}

@arch(wasm32)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Simd128])
fn load_masked_f32x4(p: *const f32, m: mask4, fb: f32x4) f32x4 {
    let bits = m as u64;
    if bits == 15 {
        return vec::<f32, 4>(unsafe wasm_v128_load(p));
    }
    let mut r = reg(fb);
    if (bits >> 0 & 1) != 0 {
        r = unsafe wasm_v128_load32_lane(p, r, 0);
    }
    if (bits >> 1 & 1) != 0 {
        r = unsafe wasm_v128_load32_lane(p + 1, r, 1);
    }
    if (bits >> 2 & 1) != 0 {
        r = unsafe wasm_v128_load32_lane(p + 2, r, 2);
    }
    if (bits >> 3 & 1) != 0 {
        r = unsafe wasm_v128_load32_lane(p + 3, r, 3);
    }
    return vec::<f32, 4>(r);
}

@arch(wasm32)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Simd128])
fn store_masked_f32x4(p: *mut f32, m: mask4, v: f32x4) {
    let bits = m as u64;
    if bits == 15 {
        unsafe wasm_v128_store(p, reg(v));
        return;
    }
    let x = reg(v);
    if (bits >> 0 & 1) != 0 {
        unsafe wasm_v128_store32_lane(p, x, 0);
    }
    if (bits >> 1 & 1) != 0 {
        unsafe wasm_v128_store32_lane(p + 1, x, 1);
    }
    if (bits >> 2 & 1) != 0 {
        unsafe wasm_v128_store32_lane(p + 2, x, 2);
    }
    if (bits >> 3 & 1) != 0 {
        unsafe wasm_v128_store32_lane(p + 3, x, 3);
    }
}

@arch(wasm32)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Simd128])
fn load_masked_f64x2(p: *const f64, m: mask2, fb: f64x2) f64x2 {
    let bits = m as u64;
    if bits == 3 {
        return vec::<f64, 2>(unsafe wasm_v128_load(p));
    }
    let mut r = reg(fb);
    if (bits >> 0 & 1) != 0 {
        r = unsafe wasm_v128_load64_lane(p, r, 0);
    }
    if (bits >> 1 & 1) != 0 {
        r = unsafe wasm_v128_load64_lane(p + 1, r, 1);
    }
    return vec::<f64, 2>(r);
}

@arch(wasm32)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Simd128])
fn store_masked_f64x2(p: *mut f64, m: mask2, v: f64x2) {
    let bits = m as u64;
    if bits == 3 {
        unsafe wasm_v128_store(p, reg(v));
        return;
    }
    let x = reg(v);
    if (bits >> 0 & 1) != 0 {
        unsafe wasm_v128_store64_lane(p, x, 0);
    }
    if (bits >> 1 & 1) != 0 {
        unsafe wasm_v128_store64_lane(p + 1, x, 1);
    }
}
