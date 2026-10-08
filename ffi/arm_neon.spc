// FFI bindings for <arm_neon.h> (ACLE Advanced SIMD): the register types and the intrinsics
// std/simd/backend/aarch64.spc and std/simd/aarch64.spc call. Each needs its CPU feature; an access
// through a pointer states its range, and a lane index or an immediate must be a constant.
import std::cpu;

extern "C" "arm_neon.h" {
    /// A 128-bit register of 8 16-bit lanes.
    @arch(aarch64)
    @c.value(16, 16)
    pub type int16x8_t;
    /// A 128-bit register of 16 8-bit lanes.
    @arch(aarch64)
    @c.value(16, 16)
    pub type int8x16_t;
    /// A 64-bit register of 8 8-bit lanes.
    @arch(aarch64)
    @c.value(8, 8)
    pub type int8x8_t;
    /// A 128-bit register of 8 16-bit lanes.
    @arch(aarch64)
    @c.value(16, 16)
    pub type uint16x8_t;
    /// A 128-bit register of 16 8-bit lanes.
    @arch(aarch64)
    @c.value(16, 16)
    pub type uint8x16_t;
    /// A 64-bit register of 8 8-bit lanes.
    @arch(aarch64)
    @c.value(8, 8)
    pub type uint8x8_t;
    /// A 64-bit register of 2 32-bit lanes.
    @arch(aarch64)
    @c.value(8, 8)
    pub type float32x2_t;
    /// A 128-bit register of 4 32-bit lanes.
    @arch(aarch64)
    @c.value(16, 16)
    pub type float32x4_t;
    /// A 128-bit register of 2 64-bit lanes.
    @arch(aarch64)
    @c.value(16, 16)
    pub type float64x2_t;
    /// A 64-bit register of 4 16-bit lanes.
    @arch(aarch64)
    @c.value(8, 8)
    pub type int16x4_t;
    /// A 64-bit register of 2 32-bit lanes.
    @arch(aarch64)
    @c.value(8, 8)
    pub type int32x2_t;
    /// A 128-bit register of 4 32-bit lanes.
    @arch(aarch64)
    @c.value(16, 16)
    pub type int32x4_t;
    /// A 128-bit register of 2 64-bit lanes.
    @arch(aarch64)
    @c.value(16, 16)
    pub type int64x2_t;
    /// A 64-bit register of 4 16-bit lanes.
    @arch(aarch64)
    @c.value(8, 8)
    pub type uint16x4_t;
    /// A 64-bit register of 2 32-bit lanes.
    @arch(aarch64)
    @c.value(8, 8)
    pub type uint32x2_t;
    /// A 128-bit register of 4 32-bit lanes.
    @arch(aarch64)
    @c.value(16, 16)
    pub type uint32x4_t;
    /// A 128-bit register of 2 64-bit lanes.
    @arch(aarch64)
    @c.value(16, 16)
    pub type uint64x2_t;
    /// Two 128-bit registers of 16 lanes, in order.
    @arch(aarch64)
    @c.value(32, 16)
    pub type uint8x16x2_t;
    /// Three 128-bit registers of 16 lanes, in order.
    @arch(aarch64)
    @c.value(48, 16)
    pub type uint8x16x3_t;
    /// Four 128-bit registers of 16 lanes, in order.
    @arch(aarch64)
    @c.value(64, 16)
    pub type uint8x16x4_t;

    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabd_s16(a: int16x4_t, b: int16x4_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabd_s32(a: int32x2_t, b: int32x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabd_s8(a: int8x8_t, b: int8x8_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabd_u16(a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabd_u32(a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabd_u8(a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabdq_s16(a: int16x8_t, b: int16x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabdq_s32(a: int32x4_t, b: int32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabdq_s8(a: int8x16_t, b: int8x16_t) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabdq_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabdq_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabdq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabs_f32(a: float32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabs_s16(a: int16x4_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabs_s32(a: int32x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabs_s8(a: int8x8_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabsq_f32(a: float32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabsq_f64(a: float64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabsq_s16(a: int16x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabsq_s32(a: int32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabsq_s64(a: int64x2_t) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vabsq_s8(a: int8x16_t) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vadd_f32(a: float32x2_t, b: float32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vadd_u16(a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vadd_u32(a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vadd_u8(a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vaddq_f32(a: float32x4_t, b: float32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vaddq_f64(a: float64x2_t, b: float64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vaddq_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vaddq_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vaddq_u64(a: uint64x2_t, b: uint64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vaddq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vaddv_u16(a: uint16x4_t) u16;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vaddv_u32(a: uint32x2_t) u32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vaddv_u8(a: uint8x8_t) u8;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vaddvq_s32(a: int32x4_t) i32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vaddvq_u16(a: uint16x8_t) u16;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vaddvq_u32(a: uint32x4_t) u32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vaddvq_u64(a: uint64x2_t) u64;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vaddvq_u8(a: uint8x16_t) u8;
    @arch(aarch64)
    @target_feature([cpu::Feature::Aes])
    @unsafe(safe)
    pub fn vaesdq_u8(data: uint8x16_t, key: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Aes])
    @unsafe(safe)
    pub fn vaeseq_u8(data: uint8x16_t, key: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Aes])
    @unsafe(safe)
    pub fn vaesimcq_u8(data: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Aes])
    @unsafe(safe)
    pub fn vaesmcq_u8(data: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vand_s16(a: int16x4_t, b: int16x4_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vand_s32(a: int32x2_t, b: int32x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vand_s8(a: int8x8_t, b: int8x8_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vand_u16(a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vand_u32(a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vand_u8(a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vandq_s16(a: int16x8_t, b: int16x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vandq_s32(a: int32x4_t, b: int32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vandq_s64(a: int64x2_t, b: int64x2_t) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vandq_s8(a: int8x16_t, b: int8x16_t) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vandq_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vandq_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vandq_u64(a: uint64x2_t, b: uint64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vandq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Sha3])
    @unsafe(safe)
    pub fn vbcaxq_u8(a: uint8x16_t, b: uint8x16_t, c: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vbsl_f32(mask: uint32x2_t, a: float32x2_t, b: float32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vbsl_s16(mask: uint16x4_t, a: int16x4_t, b: int16x4_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vbsl_s32(mask: uint32x2_t, a: int32x2_t, b: int32x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vbsl_s8(mask: uint8x8_t, a: int8x8_t, b: int8x8_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vbsl_u16(mask: uint16x4_t, a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vbsl_u32(mask: uint32x2_t, a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vbsl_u8(mask: uint8x8_t, a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vbslq_f32(mask: uint32x4_t, a: float32x4_t, b: float32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vbslq_f64(mask: uint64x2_t, a: float64x2_t, b: float64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vbslq_s16(mask: uint16x8_t, a: int16x8_t, b: int16x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vbslq_s32(mask: uint32x4_t, a: int32x4_t, b: int32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vbslq_s64(mask: uint64x2_t, a: int64x2_t, b: int64x2_t) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vbslq_s8(mask: uint8x16_t, a: int8x16_t, b: int8x16_t) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vbslq_u16(mask: uint16x8_t, a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vbslq_u32(mask: uint32x4_t, a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vbslq_u64(mask: uint64x2_t, a: uint64x2_t, b: uint64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vbslq_u8(mask: uint8x16_t, a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vceq_f32(a: float32x2_t, b: float32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vceq_s16(a: int16x4_t, b: int16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vceq_s32(a: int32x2_t, b: int32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vceq_s8(a: int8x8_t, b: int8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vceq_u16(a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vceq_u32(a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vceq_u8(a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vceqq_f32(a: float32x4_t, b: float32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vceqq_f64(a: float64x2_t, b: float64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vceqq_s16(a: int16x8_t, b: int16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vceqq_s32(a: int32x4_t, b: int32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vceqq_s64(a: int64x2_t, b: int64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vceqq_s8(a: int8x16_t, b: int8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vceqq_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vceqq_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vceqq_u64(a: uint64x2_t, b: uint64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vceqq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcge_f32(a: float32x2_t, b: float32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcge_s16(a: int16x4_t, b: int16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcge_s32(a: int32x2_t, b: int32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcge_s8(a: int8x8_t, b: int8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcge_u16(a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcge_u32(a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcge_u8(a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgeq_f32(a: float32x4_t, b: float32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgeq_f64(a: float64x2_t, b: float64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgeq_s16(a: int16x8_t, b: int16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgeq_s32(a: int32x4_t, b: int32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgeq_s64(a: int64x2_t, b: int64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgeq_s8(a: int8x16_t, b: int8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgeq_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgeq_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgeq_u64(a: uint64x2_t, b: uint64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgeq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgt_f32(a: float32x2_t, b: float32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgt_s16(a: int16x4_t, b: int16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgt_s32(a: int32x2_t, b: int32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgt_s8(a: int8x8_t, b: int8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgt_u16(a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgt_u32(a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgt_u8(a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgtq_f32(a: float32x4_t, b: float32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgtq_f64(a: float64x2_t, b: float64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgtq_s16(a: int16x8_t, b: int16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgtq_s32(a: int32x4_t, b: int32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgtq_s64(a: int64x2_t, b: int64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgtq_s8(a: int8x16_t, b: int8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgtq_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgtq_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgtq_u64(a: uint64x2_t, b: uint64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcgtq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcle_f32(a: float32x2_t, b: float32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcle_s16(a: int16x4_t, b: int16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcle_s32(a: int32x2_t, b: int32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcle_s8(a: int8x8_t, b: int8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcle_u16(a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcle_u32(a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcle_u8(a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcleq_f32(a: float32x4_t, b: float32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcleq_f64(a: float64x2_t, b: float64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcleq_s16(a: int16x8_t, b: int16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcleq_s32(a: int32x4_t, b: int32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcleq_s64(a: int64x2_t, b: int64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcleq_s8(a: int8x16_t, b: int8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcleq_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcleq_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcleq_u64(a: uint64x2_t, b: uint64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcleq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclt_f32(a: float32x2_t, b: float32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclt_s16(a: int16x4_t, b: int16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclt_s32(a: int32x2_t, b: int32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclt_s8(a: int8x8_t, b: int8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclt_u16(a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclt_u32(a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclt_u8(a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcltq_f32(a: float32x4_t, b: float32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcltq_f64(a: float64x2_t, b: float64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcltq_s16(a: int16x8_t, b: int16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcltq_s32(a: int32x4_t, b: int32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcltq_s64(a: int64x2_t, b: int64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcltq_s8(a: int8x16_t, b: int8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcltq_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcltq_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcltq_u64(a: uint64x2_t, b: uint64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcltq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclz_s16(a: int16x4_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclz_s32(a: int32x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclz_s8(a: int8x8_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclz_u16(a: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclz_u32(a: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclz_u8(a: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclzq_s16(a: int16x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclzq_s32(a: int32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclzq_s8(a: int8x16_t) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclzq_u16(a: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclzq_u32(a: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vclzq_u8(a: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcnt_u8(a: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcntq_u8(a: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcombine_u8(low: uint8x8_t, high: uint8x8_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcvt_f32_f64(a: float64x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcvt_f32_s32(a: int32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcvt_f32_u32(a: uint32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcvt_f64_f32(a: float32x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcvt_high_f32_f64(r: float32x2_t, a: float64x2_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcvt_high_f64_f32(a: float32x4_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcvt_s32_f32(a: float32x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcvt_u32_f32(a: float32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcvtq_f32_s32(a: int32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcvtq_f32_u32(a: uint32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcvtq_f64_s64(a: int64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcvtq_f64_u64(a: uint64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcvtq_s32_f32(a: float32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcvtq_s64_f64(a: float64x2_t) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcvtq_u32_f32(a: float32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vcvtq_u64_f64(a: float64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdiv_f32(a: float32x2_t, b: float32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdivq_f32(a: float32x4_t, b: float32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdivq_f64(a: float64x2_t, b: float64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Dotprod])
    @unsafe(safe)
    pub fn vdotq_s32(r: int32x4_t, a: int8x16_t, b: int8x16_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Dotprod])
    @unsafe(safe)
    pub fn vdotq_u32(r: uint32x4_t, a: uint8x16_t, b: uint8x16_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdup_n_f32(value: f32) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdup_n_s16(value: i16) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdup_n_s32(value: i32) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdup_n_s8(value: i8) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdup_n_u16(value: u16) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdup_n_u32(value: u32) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdup_n_u8(value: u8) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdupq_n_f32(value: f32) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdupq_n_f64(value: f64) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdupq_n_s16(value: i16) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdupq_n_s32(value: i32) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdupq_n_s64(value: i64) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdupq_n_s8(value: i8) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdupq_n_u16(value: u16) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdupq_n_u32(value: u32) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdupq_n_u64(value: u64) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vdupq_n_u8(value: u8) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Sha3])
    @unsafe(safe)
    pub fn veor3q_u8(a: uint8x16_t, b: uint8x16_t, c: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn veor_s16(a: int16x4_t, b: int16x4_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn veor_s32(a: int32x2_t, b: int32x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn veor_s8(a: int8x8_t, b: int8x8_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn veor_u16(a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn veor_u32(a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn veor_u8(a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn veorq_s16(a: int16x8_t, b: int16x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn veorq_s32(a: int32x4_t, b: int32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn veorq_s64(a: int64x2_t, b: int64x2_t) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn veorq_s8(a: int8x16_t, b: int8x16_t) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn veorq_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn veorq_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn veorq_u64(a: uint64x2_t, b: uint64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn veorq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vfma_f32(a: float32x2_t, b: float32x2_t, c: float32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vfmaq_f32(a: float32x4_t, b: float32x4_t, c: float32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vfmaq_f64(a: float64x2_t, b: float64x2_t, c: float64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vget_high_f32(a: float32x4_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    pub fn vget_lane_f32(v: float32x2_t, lane: i32) f32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vget_low_f32(a: float32x4_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vget_low_s16(a: int16x8_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vget_low_s32(a: int32x4_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vget_low_s8(a: int8x16_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vget_low_u16(a: uint16x8_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vget_low_u32(a: uint32x4_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vget_low_u8(a: uint8x16_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    pub fn vgetq_lane_f64(v: float64x2_t, lane: i32) f64;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    pub fn vgetq_lane_u16(v: uint16x8_t, lane: i32) u16;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 8)
    pub fn vld1_f32(ptr: *const f32) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 4)
    pub fn vld1_lane_f32(ptr: *const f32, src: float32x2_t, lane: i32) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 2)
    pub fn vld1_lane_s16(ptr: *const i16, src: int16x4_t, lane: i32) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 4)
    pub fn vld1_lane_s32(ptr: *const i32, src: int32x2_t, lane: i32) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 1)
    pub fn vld1_lane_s8(ptr: *const i8, src: int8x8_t, lane: i32) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 2)
    pub fn vld1_lane_u16(ptr: *const u16, src: uint16x4_t, lane: i32) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 4)
    pub fn vld1_lane_u32(ptr: *const u32, src: uint32x2_t, lane: i32) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 1)
    pub fn vld1_lane_u8(ptr: *const u8, src: uint8x8_t, lane: i32) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 8)
    pub fn vld1_s16(ptr: *const i16) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 8)
    pub fn vld1_s32(ptr: *const i32) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 8)
    pub fn vld1_s8(ptr: *const i8) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 8)
    pub fn vld1_u16(ptr: *const u16) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 8)
    pub fn vld1_u32(ptr: *const u32) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 8)
    pub fn vld1_u8(ptr: *const u8) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 16)
    pub fn vld1q_f32(ptr: *const f32) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 16)
    pub fn vld1q_f64(ptr: *const f64) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 4)
    pub fn vld1q_lane_f32(ptr: *const f32, src: float32x4_t, lane: i32) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 8)
    pub fn vld1q_lane_f64(ptr: *const f64, src: float64x2_t, lane: i32) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 2)
    pub fn vld1q_lane_s16(ptr: *const i16, src: int16x8_t, lane: i32) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 4)
    pub fn vld1q_lane_s32(ptr: *const i32, src: int32x4_t, lane: i32) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 8)
    pub fn vld1q_lane_s64(ptr: *const i64, src: int64x2_t, lane: i32) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 1)
    pub fn vld1q_lane_s8(ptr: *const i8, src: int8x16_t, lane: i32) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 2)
    pub fn vld1q_lane_u16(ptr: *const u16, src: uint16x8_t, lane: i32) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 4)
    pub fn vld1q_lane_u32(ptr: *const u32, src: uint32x4_t, lane: i32) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 8)
    pub fn vld1q_lane_u64(ptr: *const u64, src: uint64x2_t, lane: i32) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 1)
    pub fn vld1q_lane_u8(ptr: *const u8, src: uint8x16_t, lane: i32) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 16)
    pub fn vld1q_s16(ptr: *const i16) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 16)
    pub fn vld1q_s32(ptr: *const i32) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 16)
    pub fn vld1q_s64(ptr: *const i64) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 16)
    pub fn vld1q_s8(ptr: *const i8) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 16)
    pub fn vld1q_u16(ptr: *const u16) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 16)
    pub fn vld1q_u32(ptr: *const u32) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 16)
    pub fn vld1q_u64(ptr: *const u64) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 16)
    pub fn vld1q_u8(ptr: *const u8) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 32)
    pub fn vld1q_u8_x2(ptr: *const u8) uint8x16x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 48)
    pub fn vld1q_u8_x3(ptr: *const u8) uint8x16x3_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.reads(ptr, 64)
    pub fn vld1q_u8_x4(ptr: *const u8) uint8x16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmax_f32(a: float32x2_t, b: float32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmax_s16(a: int16x4_t, b: int16x4_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmax_s32(a: int32x2_t, b: int32x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmax_s8(a: int8x8_t, b: int8x8_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmax_u16(a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmax_u32(a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmax_u8(a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxnm_f32(a: float32x2_t, b: float32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxnmq_f32(a: float32x4_t, b: float32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxnmq_f64(a: float64x2_t, b: float64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxnmv_f32(a: float32x2_t) f32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxnmvq_f32(a: float32x4_t) f32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxnmvq_f64(a: float64x2_t) f64;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxq_f32(a: float32x4_t, b: float32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxq_f64(a: float64x2_t, b: float64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxq_s16(a: int16x8_t, b: int16x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxq_s32(a: int32x4_t, b: int32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxq_s8(a: int8x16_t, b: int8x16_t) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxq_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxq_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxv_f32(a: float32x2_t) f32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxv_s16(a: int16x4_t) i16;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxv_s32(a: int32x2_t) i32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxv_s8(a: int8x8_t) i8;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxv_u16(a: uint16x4_t) u16;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxv_u32(a: uint32x2_t) u32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxv_u8(a: uint8x8_t) u8;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxvq_f32(a: float32x4_t) f32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxvq_f64(a: float64x2_t) f64;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxvq_s16(a: int16x8_t) i16;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxvq_s32(a: int32x4_t) i32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxvq_s8(a: int8x16_t) i8;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxvq_u16(a: uint16x8_t) u16;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxvq_u32(a: uint32x4_t) u32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmaxvq_u8(a: uint8x16_t) u8;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmin_f32(a: float32x2_t, b: float32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmin_s16(a: int16x4_t, b: int16x4_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmin_s32(a: int32x2_t, b: int32x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmin_s8(a: int8x8_t, b: int8x8_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmin_u16(a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmin_u32(a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmin_u8(a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminnm_f32(a: float32x2_t, b: float32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminnmq_f32(a: float32x4_t, b: float32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminnmq_f64(a: float64x2_t, b: float64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminnmv_f32(a: float32x2_t) f32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminnmvq_f32(a: float32x4_t) f32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminnmvq_f64(a: float64x2_t) f64;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminq_f32(a: float32x4_t, b: float32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminq_f64(a: float64x2_t, b: float64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminq_s16(a: int16x8_t, b: int16x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminq_s32(a: int32x4_t, b: int32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminq_s8(a: int8x16_t, b: int8x16_t) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminq_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminq_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminv_f32(a: float32x2_t) f32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminv_s16(a: int16x4_t) i16;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminv_s32(a: int32x2_t) i32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminv_s8(a: int8x8_t) i8;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminv_u16(a: uint16x4_t) u16;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminv_u32(a: uint32x2_t) u32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminv_u8(a: uint8x8_t) u8;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminvq_f32(a: float32x4_t) f32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminvq_f64(a: float64x2_t) f64;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminvq_s16(a: int16x8_t) i16;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminvq_s32(a: int32x4_t) i32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminvq_s8(a: int8x16_t) i8;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminvq_u16(a: uint16x8_t) u16;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminvq_u32(a: uint32x4_t) u32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vminvq_u8(a: uint8x16_t) u8;
    @arch(aarch64)
    @target_feature([cpu::Feature::I8mm])
    @unsafe(safe)
    pub fn vmmlaq_s32(r: int32x4_t, a: int8x16_t, b: int8x16_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::I8mm])
    @unsafe(safe)
    pub fn vmmlaq_u32(r: uint32x4_t, a: uint8x16_t, b: uint8x16_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovl_high_s16(a: int16x8_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovl_high_s32(a: int32x4_t) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovl_high_s8(a: int8x16_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovl_high_u16(a: uint16x8_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovl_high_u32(a: uint32x4_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovl_high_u8(a: uint8x16_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovl_s16(a: int16x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovl_s32(a: int32x2_t) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovl_s8(a: int8x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovl_u16(a: uint16x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovl_u32(a: uint32x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovl_u8(a: uint8x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovn_s16(a: int16x8_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovn_s32(a: int32x4_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovn_s64(a: int64x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovn_u16(a: uint16x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovn_u32(a: uint32x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmovn_u64(a: uint64x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmul_f32(a: float32x2_t, b: float32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmul_u16(a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmul_u32(a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmul_u8(a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmull_high_s16(a: int16x8_t, b: int16x8_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmull_high_s32(a: int32x4_t, b: int32x4_t) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmull_high_s8(a: int8x16_t, b: int8x16_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmull_high_u16(a: uint16x8_t, b: uint16x8_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmull_high_u32(a: uint32x4_t, b: uint32x4_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmull_high_u8(a: uint8x16_t, b: uint8x16_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmull_s16(a: int16x4_t, b: int16x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmull_s32(a: int32x2_t, b: int32x2_t) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmull_s8(a: int8x8_t, b: int8x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmull_u16(a: uint16x4_t, b: uint16x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmull_u32(a: uint32x2_t, b: uint32x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmull_u8(a: uint8x8_t, b: uint8x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmulq_f32(a: float32x4_t, b: float32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmulq_f64(a: float64x2_t, b: float64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmulq_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmulq_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmulq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmvn_u8(a: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vmvnq_u8(a: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vneg_f32(a: float32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vneg_s16(a: int16x4_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vneg_s32(a: int32x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vneg_s8(a: int8x8_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vnegq_f32(a: float32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vnegq_f64(a: float64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vnegq_s16(a: int16x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vnegq_s32(a: int32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vnegq_s64(a: int64x2_t) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vnegq_s8(a: int8x16_t) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vorr_s16(a: int16x4_t, b: int16x4_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vorr_s32(a: int32x2_t, b: int32x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vorr_s8(a: int8x8_t, b: int8x8_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vorr_u16(a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vorr_u32(a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vorr_u8(a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vorrq_s16(a: int16x8_t, b: int16x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vorrq_s32(a: int32x4_t, b: int32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vorrq_s64(a: int64x2_t, b: int64x2_t) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vorrq_s8(a: int8x16_t, b: int8x16_t) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vorrq_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vorrq_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vorrq_u64(a: uint64x2_t, b: uint64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vorrq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vpadalq_s16(a: int32x4_t, b: int16x8_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vpadalq_u16(a: uint32x4_t, b: uint16x8_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vpaddl_u16(a: uint16x4_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vpaddl_u8(a: uint8x8_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vpaddlq_s16(a: int16x8_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vpaddlq_u16(a: uint16x8_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vpaddlq_u32(a: uint32x4_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vpaddlq_u8(a: uint8x16_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vpaddq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqadd_s16(a: int16x4_t, b: int16x4_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqadd_s32(a: int32x2_t, b: int32x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqadd_s8(a: int8x8_t, b: int8x8_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqadd_u16(a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqadd_u32(a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqadd_u8(a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqaddq_s16(a: int16x8_t, b: int16x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqaddq_s32(a: int32x4_t, b: int32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqaddq_s64(a: int64x2_t, b: int64x2_t) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqaddq_s8(a: int8x16_t, b: int8x16_t) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqaddq_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqaddq_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqaddq_u64(a: uint64x2_t, b: uint64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqaddq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovn_high_s16(r: int8x8_t, a: int16x8_t) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovn_high_s32(r: int16x4_t, a: int32x4_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovn_high_s64(r: int32x2_t, a: int64x2_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovn_high_u16(r: uint8x8_t, a: uint16x8_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovn_high_u32(r: uint16x4_t, a: uint32x4_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovn_high_u64(r: uint32x2_t, a: uint64x2_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovn_s16(a: int16x8_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovn_s32(a: int32x4_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovn_s64(a: int64x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovn_u16(a: uint16x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovn_u32(a: uint32x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovn_u64(a: uint64x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovun_high_s16(r: uint8x8_t, a: int16x8_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovun_high_s32(r: uint16x4_t, a: int32x4_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovun_high_s64(r: uint32x2_t, a: int64x2_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovun_s16(a: int16x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovun_s32(a: int32x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqmovun_s64(a: int64x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Rdm])
    @unsafe(safe)
    pub fn vqrdmlahq_s16(a: int16x8_t, b: int16x8_t, c: int16x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Rdm])
    @unsafe(safe)
    pub fn vqrdmlahq_s32(a: int32x4_t, b: int32x4_t, c: int32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Rdm])
    @unsafe(safe)
    pub fn vqrdmlshq_s16(a: int16x8_t, b: int16x8_t, c: int16x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Rdm])
    @unsafe(safe)
    pub fn vqrdmlshq_s32(a: int32x4_t, b: int32x4_t, c: int32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqsub_s16(a: int16x4_t, b: int16x4_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqsub_s32(a: int32x2_t, b: int32x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqsub_s8(a: int8x8_t, b: int8x8_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqsub_u16(a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqsub_u32(a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqsub_u8(a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqsubq_s16(a: int16x8_t, b: int16x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqsubq_s32(a: int32x4_t, b: int32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqsubq_s64(a: int64x2_t, b: int64x2_t) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqsubq_s8(a: int8x16_t, b: int8x16_t) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqsubq_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqsubq_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqsubq_u64(a: uint64x2_t, b: uint64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqsubq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqtbl1_u8(t: uint8x16_t, idx: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqtbl1q_u8(t: uint8x16_t, idx: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqtbl2q_u8(t: uint8x16x2_t, idx: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqtbl3q_u8(t: uint8x16x3_t, idx: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqtbl4q_u8(t: uint8x16x4_t, idx: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vqtbx1q_u8(a: uint8x16_t, t: uint8x16_t, idx: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Sha3])
    @unsafe(safe)
    pub fn vrax1q_u64(a: uint64x2_t, b: uint64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrbit_u8(a: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrbitq_u8(a: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_f32_u8(a: uint8x8_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_s16_u16(a: uint16x4_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_s16_u8(a: uint8x8_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_s32_u32(a: uint32x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_s32_u8(a: uint8x8_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_s8_u8(a: uint8x8_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_u16_s16(a: int16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_u16_u8(a: uint8x8_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_u32_f32(a: float32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_u32_s32(a: int32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_u32_u16(a: uint16x4_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_u32_u8(a: uint8x8_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_u8_f32(a: float32x2_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_u8_s16(a: int16x4_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_u8_s32(a: int32x2_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_u8_s8(a: int8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_u8_u16(a: uint16x4_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpret_u8_u32(a: uint32x2_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_f32_u8(a: uint8x16_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_f64_u8(a: uint8x16_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_s16_u16(a: uint16x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_s16_u8(a: uint8x16_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_s32_u32(a: uint32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_s32_u8(a: uint8x16_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_s64_u64(a: uint64x2_t) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_s64_u8(a: uint8x16_t) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_s8_u8(a: uint8x16_t) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u16_s16(a: int16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u16_s32(a: int32x4_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u16_u32(a: uint32x4_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u16_u8(a: uint8x16_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u32_f32(a: float32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u32_s32(a: int32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u32_s64(a: int64x2_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u32_u16(a: uint16x8_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u32_u64(a: uint64x2_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u32_u8(a: uint8x16_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u64_f64(a: float64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u64_s64(a: int64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u64_u8(a: uint8x16_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u8_f32(a: float32x4_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u8_f64(a: float64x2_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u8_s16(a: int16x8_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u8_s32(a: int32x4_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u8_s64(a: int64x2_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u8_s8(a: int8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u8_u16(a: uint16x8_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u8_u32(a: uint32x4_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vreinterpretq_u8_u64(a: uint64x2_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrev16_u8(a: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrev16q_u8(a: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrev32_u8(a: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrev32q_u8(a: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrev64q_u8(a: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrnd_f32(a: float32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrndm_f32(a: float32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrndmq_f32(a: float32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrndmq_f64(a: float64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrndn_f32(a: float32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrndnq_f32(a: float32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrndnq_f64(a: float64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrndp_f32(a: float32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrndpq_f32(a: float32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrndpq_f64(a: float64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrndq_f32(a: float32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vrndq_f64(a: float64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Sha2])
    @unsafe(safe)
    pub fn vsha256h2q_u32(hash_efgh: uint32x4_t, hash_abcd: uint32x4_t, wk: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Sha2])
    @unsafe(safe)
    pub fn vsha256hq_u32(hash_abcd: uint32x4_t, hash_efgh: uint32x4_t, wk: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Sha2])
    @unsafe(safe)
    pub fn vsha256su0q_u32(w0_3: uint32x4_t, w4_7: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Sha2])
    @unsafe(safe)
    pub fn vsha256su1q_u32(tw0_3: uint32x4_t, w8_11: uint32x4_t, w12_15: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vshl_s16(a: int16x4_t, b: int16x4_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vshl_s32(a: int32x2_t, b: int32x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vshl_s8(a: int8x8_t, b: int8x8_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vshl_u16(a: uint16x4_t, b: int16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vshl_u32(a: uint32x2_t, b: int32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vshl_u8(a: uint8x8_t, b: int8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vshlq_s16(a: int16x8_t, b: int16x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vshlq_s32(a: int32x4_t, b: int32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vshlq_s64(a: int64x2_t, b: int64x2_t) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vshlq_s8(a: int8x16_t, b: int8x16_t) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vshlq_u16(a: uint16x8_t, b: int16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vshlq_u32(a: uint32x4_t, b: int32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vshlq_u64(a: uint64x2_t, b: int64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vshlq_u8(a: uint8x16_t, b: int8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsqrt_f32(a: float32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsqrtq_f32(a: float32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsqrtq_f64(a: float64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 8)
    pub fn vst1_f32(ptr: *mut f32, val: float32x2_t);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 4)
    pub fn vst1_lane_f32(ptr: *mut f32, val: float32x2_t, lane: i32);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 2)
    pub fn vst1_lane_s16(ptr: *mut i16, val: int16x4_t, lane: i32);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 4)
    pub fn vst1_lane_s32(ptr: *mut i32, val: int32x2_t, lane: i32);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 1)
    pub fn vst1_lane_s8(ptr: *mut i8, val: int8x8_t, lane: i32);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 2)
    pub fn vst1_lane_u16(ptr: *mut u16, val: uint16x4_t, lane: i32);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 4)
    pub fn vst1_lane_u32(ptr: *mut u32, val: uint32x2_t, lane: i32);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 1)
    pub fn vst1_lane_u8(ptr: *mut u8, val: uint8x8_t, lane: i32);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 8)
    pub fn vst1_s16(ptr: *mut i16, val: int16x4_t);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 8)
    pub fn vst1_s32(ptr: *mut i32, val: int32x2_t);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 8)
    pub fn vst1_s8(ptr: *mut i8, val: int8x8_t);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 8)
    pub fn vst1_u16(ptr: *mut u16, val: uint16x4_t);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 8)
    pub fn vst1_u32(ptr: *mut u32, val: uint32x2_t);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 8)
    pub fn vst1_u8(ptr: *mut u8, val: uint8x8_t);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 16)
    pub fn vst1q_f32(ptr: *mut f32, val: float32x4_t);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 16)
    pub fn vst1q_f64(ptr: *mut f64, val: float64x2_t);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 4)
    pub fn vst1q_lane_f32(ptr: *mut f32, val: float32x4_t, lane: i32);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 8)
    pub fn vst1q_lane_f64(ptr: *mut f64, val: float64x2_t, lane: i32);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 2)
    pub fn vst1q_lane_s16(ptr: *mut i16, val: int16x8_t, lane: i32);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 4)
    pub fn vst1q_lane_s32(ptr: *mut i32, val: int32x4_t, lane: i32);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 8)
    pub fn vst1q_lane_s64(ptr: *mut i64, val: int64x2_t, lane: i32);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 1)
    pub fn vst1q_lane_s8(ptr: *mut i8, val: int8x16_t, lane: i32);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 2)
    pub fn vst1q_lane_u16(ptr: *mut u16, val: uint16x8_t, lane: i32);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 4)
    pub fn vst1q_lane_u32(ptr: *mut u32, val: uint32x4_t, lane: i32);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 8)
    pub fn vst1q_lane_u64(ptr: *mut u64, val: uint64x2_t, lane: i32);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 1)
    pub fn vst1q_lane_u8(ptr: *mut u8, val: uint8x16_t, lane: i32);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 16)
    pub fn vst1q_s16(ptr: *mut i16, val: int16x8_t);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 16)
    pub fn vst1q_s32(ptr: *mut i32, val: int32x4_t);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 16)
    pub fn vst1q_s64(ptr: *mut i64, val: int64x2_t);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 16)
    pub fn vst1q_s8(ptr: *mut i8, val: int8x16_t);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 16)
    pub fn vst1q_u16(ptr: *mut u16, val: uint16x8_t);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 16)
    pub fn vst1q_u32(ptr: *mut u32, val: uint32x4_t);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 16)
    pub fn vst1q_u64(ptr: *mut u64, val: uint64x2_t);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @c.writes(ptr, 16)
    pub fn vst1q_u8(ptr: *mut u8, val: uint8x16_t);
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsub_f32(a: float32x2_t, b: float32x2_t) float32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsub_s16(a: int16x4_t, b: int16x4_t) int16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsub_s32(a: int32x2_t, b: int32x2_t) int32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsub_s8(a: int8x8_t, b: int8x8_t) int8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsub_u16(a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsub_u32(a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsub_u8(a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsubq_f32(a: float32x4_t, b: float32x4_t) float32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsubq_f64(a: float64x2_t, b: float64x2_t) float64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsubq_s16(a: int16x8_t, b: int16x8_t) int16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsubq_s32(a: int32x4_t, b: int32x4_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsubq_s64(a: int64x2_t, b: int64x2_t) int64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsubq_s8(a: int8x16_t, b: int8x16_t) int8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsubq_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsubq_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsubq_u64(a: uint64x2_t, b: uint64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vsubq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vtst_u16(a: uint16x4_t, b: uint16x4_t) uint16x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vtst_u32(a: uint32x2_t, b: uint32x2_t) uint32x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vtst_u8(a: uint8x8_t, b: uint8x8_t) uint8x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vtstq_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vtstq_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vtstq_u64(a: uint64x2_t, b: uint64x2_t) uint64x2_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vtstq_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::I8mm])
    @unsafe(safe)
    pub fn vusmmlaq_s32(r: int32x4_t, a: uint8x16_t, b: int8x16_t) int32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vuzp1q_u16(a: uint16x8_t, b: uint16x8_t) uint16x8_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vuzp1q_u32(a: uint32x4_t, b: uint32x4_t) uint32x4_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Neon])
    @unsafe(safe)
    pub fn vuzp1q_u8(a: uint8x16_t, b: uint8x16_t) uint8x16_t;
    @arch(aarch64)
    @target_feature([cpu::Feature::Sha3])
    pub fn vxarq_u64(a: uint64x2_t, b: uint64x2_t, imm6: i32) uint64x2_t;
}

// The CRC-32 instructions, scalar: <arm_acle.h>.
extern "C" "arm_acle.h" {
    @arch(aarch64)
    @target_feature([cpu::Feature::Crc])
    @unsafe(safe)
    pub fn __crc32b(a: u32, b: u8) u32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Crc])
    @unsafe(safe)
    pub fn __crc32cb(a: u32, b: u8) u32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Crc])
    @unsafe(safe)
    pub fn __crc32cd(a: u32, b: u64) u32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Crc])
    @unsafe(safe)
    pub fn __crc32ch(a: u32, b: u16) u32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Crc])
    @unsafe(safe)
    pub fn __crc32cw(a: u32, b: u32) u32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Crc])
    @unsafe(safe)
    pub fn __crc32d(a: u32, b: u64) u32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Crc])
    @unsafe(safe)
    pub fn __crc32h(a: u32, b: u16) u32;
    @arch(aarch64)
    @target_feature([cpu::Feature::Crc])
    @unsafe(safe)
    pub fn __crc32w(a: u32, b: u32) u32;
}
