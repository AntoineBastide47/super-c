// AArch64 Advanced SIMD and crypto operations with no portable meaning, over the portable vector
// types. Each needs the feature it names (`--target-feature=+i8mm`, ...; `neon`, and on macOS
// `dotprod`, `rdm`, `aes`, `sha2`, `sha3` and `crc`, are in every build): a call without it is a
// compile error. They have no memory effect; each calls a C intrinsic, so no constant has its value.
import std::cpu;
import arm_neon as *;

// Vectors in registers, and back.
@arch(aarch64)
@target_feature([cpu::Feature::Neon])
fn q_u8(x: u8x16) uint8x16_t {
    return unsafe vld1q_u8(((&x) as *const u8x16) as *const u8);
}

@arch(aarch64)
@target_feature([cpu::Feature::Neon])
fn v_u8(r: uint8x16_t) u8x16 {
    let mut x = unsafe zeroed::<u8x16>();
    unsafe vst1q_u8(((&mut x) as *mut u8x16) as *mut u8, r);
    return x;
}

@arch(aarch64)
@target_feature([cpu::Feature::Neon])
fn q_s8(x: i8x16) int8x16_t {
    return unsafe vld1q_s8(((&x) as *const i8x16) as *const i8);
}

@arch(aarch64)
@target_feature([cpu::Feature::Neon])
fn q_s16(x: i16x8) int16x8_t {
    return unsafe vld1q_s16(((&x) as *const i16x8) as *const i16);
}

@arch(aarch64)
@target_feature([cpu::Feature::Neon])
fn v_s16(r: int16x8_t) i16x8 {
    let mut x = unsafe zeroed::<i16x8>();
    unsafe vst1q_s16(((&mut x) as *mut i16x8) as *mut i16, r);
    return x;
}

@arch(aarch64)
@target_feature([cpu::Feature::Neon])
fn q_s32(x: i32x4) int32x4_t {
    return unsafe vld1q_s32(((&x) as *const i32x4) as *const i32);
}

@arch(aarch64)
@target_feature([cpu::Feature::Neon])
fn v_s32(r: int32x4_t) i32x4 {
    let mut x = unsafe zeroed::<i32x4>();
    unsafe vst1q_s32(((&mut x) as *mut i32x4) as *mut i32, r);
    return x;
}

@arch(aarch64)
@target_feature([cpu::Feature::Neon])
fn q_u32(x: u32x4) uint32x4_t {
    return unsafe vld1q_u32(((&x) as *const u32x4) as *const u32);
}

@arch(aarch64)
@target_feature([cpu::Feature::Neon])
fn v_u32(r: uint32x4_t) u32x4 {
    let mut x = unsafe zeroed::<u32x4>();
    unsafe vst1q_u32(((&mut x) as *mut u32x4) as *mut u32, r);
    return x;
}

@arch(aarch64)
@target_feature([cpu::Feature::Neon])
fn q_u64(x: u64x2) uint64x2_t {
    return unsafe vld1q_u64(((&x) as *const u64x2) as *const u64);
}

@arch(aarch64)
@target_feature([cpu::Feature::Neon])
fn v_u64(r: uint64x2_t) u64x2 {
    let mut x = unsafe zeroed::<u64x2>();
    unsafe vst1q_u64(((&mut x) as *mut u64x2) as *mut u64, r);
    return x;
}

/// `acc` plus, in each 32-bit lane, the sum of the products of the four bytes of `a` and `b` there (`sdot`).
@arch(aarch64)
@target_feature([cpu::Feature::Dotprod])
pub fn vdot_i32(a: i8x16, b: i8x16, acc: i32x4) i32x4 {
    return v_s32(vdotq_s32(q_s32(acc), q_s8(a), q_s8(b)));
}

/// `acc` plus, in each 32-bit lane, the sum of the products of the four bytes of `a` and `b` there (`udot`).
@arch(aarch64)
@target_feature([cpu::Feature::Dotprod])
pub fn vdot_u32(a: u8x16, b: u8x16, acc: u32x4) u32x4 {
    return v_u32(vdotq_u32(q_u32(acc), q_u8(a), q_u8(b)));
}

/// `acc` plus the 2x2 product of `a` as a 2x8 matrix (rows of 8 bytes) and `b` as the transpose of one (`mmla`): lane `2 * i + j` adds row `i` of `a` times row `j` of `b`.
@arch(aarch64)
@target_feature([cpu::Feature::I8mm])
pub fn vmmla_i32(acc: i32x4, a: i8x16, b: i8x16) i32x4 {
    return v_s32(vmmlaq_s32(q_s32(acc), q_s8(a), q_s8(b)));
}

/// `acc` plus the 2x2 product of `a` as a 2x8 matrix (rows of 8 bytes) and `b` as the transpose of one (`mmla`): lane `2 * i + j` adds row `i` of `a` times row `j` of `b`.
@arch(aarch64)
@target_feature([cpu::Feature::I8mm])
pub fn vmmla_u32(acc: u32x4, a: u8x16, b: u8x16) u32x4 {
    return v_u32(vmmlaq_u32(q_u32(acc), q_u8(a), q_u8(b)));
}

/// `acc` plus the 2x2 product of `a` as a 2x8 matrix (rows of 8 bytes) and `b` as the transpose of one (`usmmla`): lane `2 * i + j` adds row `i` of `a` times row `j` of `b`.
@arch(aarch64)
@target_feature([cpu::Feature::I8mm])
pub fn vusmmla_i32(acc: i32x4, a: u8x16, b: i8x16) i32x4 {
    return v_s32(vusmmlaq_s32(q_s32(acc), q_u8(a), q_s8(b)));
}

/// `a` plus the high half of `2 * b * c`, rounded and saturated (`sqrdmlah`).
@arch(aarch64)
@target_feature([cpu::Feature::Rdm])
pub fn vqrdmlah_i16(a: i16x8, b: i16x8, c: i16x8) i16x8 {
    return v_s16(vqrdmlahq_s16(q_s16(a), q_s16(b), q_s16(c)));
}

/// `a` minus the high half of `2 * b * c`, rounded and saturated (`sqrdmlsh`).
@arch(aarch64)
@target_feature([cpu::Feature::Rdm])
pub fn vqrdmlsh_i16(a: i16x8, b: i16x8, c: i16x8) i16x8 {
    return v_s16(vqrdmlshq_s16(q_s16(a), q_s16(b), q_s16(c)));
}

/// `a` plus the high half of `2 * b * c`, rounded and saturated (`sqrdmlah`).
@arch(aarch64)
@target_feature([cpu::Feature::Rdm])
pub fn vqrdmlah_i32(a: i32x4, b: i32x4, c: i32x4) i32x4 {
    return v_s32(vqrdmlahq_s32(q_s32(a), q_s32(b), q_s32(c)));
}

/// `a` minus the high half of `2 * b * c`, rounded and saturated (`sqrdmlsh`).
@arch(aarch64)
@target_feature([cpu::Feature::Rdm])
pub fn vqrdmlsh_i32(a: i32x4, b: i32x4, c: i32x4) i32x4 {
    return v_s32(vqrdmlshq_s32(q_s32(a), q_s32(b), q_s32(c)));
}

/// One AES round without MixColumns: AddRoundKey, SubBytes, ShiftRows (`aese`).
@arch(aarch64)
@target_feature([cpu::Feature::Aes])
pub fn aese(data: u8x16, key: u8x16) u8x16 {
    return v_u8(vaeseq_u8(q_u8(data), q_u8(key)));
}

/// One AES decryption round without InvMixColumns: AddRoundKey, InvShiftRows, InvSubBytes (`aesd`).
@arch(aarch64)
@target_feature([cpu::Feature::Aes])
pub fn aesd(data: u8x16, key: u8x16) u8x16 {
    return v_u8(vaesdq_u8(q_u8(data), q_u8(key)));
}

/// AES MixColumns (`aesmc`).
@arch(aarch64)
@target_feature([cpu::Feature::Aes])
pub fn aesmc(data: u8x16) u8x16 {
    return v_u8(vaesmcq_u8(q_u8(data)));
}

/// AES InvMixColumns (`aesimc`).
@arch(aarch64)
@target_feature([cpu::Feature::Aes])
pub fn aesimc(data: u8x16) u8x16 {
    return v_u8(vaesimcq_u8(q_u8(data)));
}

/// Four SHA-256 rounds: the new `a, b, c, d` from `abcd`, `efgh` and the round inputs `wk` (`sha256h`).
@arch(aarch64)
@target_feature([cpu::Feature::Sha2])
pub fn sha256h(abcd: u32x4, efgh: u32x4, wk: u32x4) u32x4 {
    return v_u32(vsha256hq_u32(q_u32(abcd), q_u32(efgh), q_u32(wk)));
}

/// Four SHA-256 rounds: the new `e, f, g, h` (`sha256h2`).
@arch(aarch64)
@target_feature([cpu::Feature::Sha2])
pub fn sha256h2(efgh: u32x4, abcd: u32x4, wk: u32x4) u32x4 {
    return v_u32(vsha256h2q_u32(q_u32(efgh), q_u32(abcd), q_u32(wk)));
}

/// The first half of four SHA-256 schedule words: `w[t - 16] + sigma0(w[t - 15])` (`sha256su0`).
@arch(aarch64)
@target_feature([cpu::Feature::Sha2])
pub fn sha256su0(w0_3: u32x4, w4_7: u32x4) u32x4 {
    return v_u32(vsha256su0q_u32(q_u32(w0_3), q_u32(w4_7)));
}

/// Four SHA-256 schedule words from the first halves `tw0_3` (`sha256su1`).
@arch(aarch64)
@target_feature([cpu::Feature::Sha2])
pub fn sha256su1(tw0_3: u32x4, w8_11: u32x4, w12_15: u32x4) u32x4 {
    return v_u32(vsha256su1q_u32(q_u32(tw0_3), q_u32(w8_11), q_u32(w12_15)));
}

/// `a ^ b ^ c` (`eor3`).
@arch(aarch64)
@target_feature([cpu::Feature::Sha3])
pub fn eor3(a: u8x16, b: u8x16, c: u8x16) u8x16 {
    return v_u8(veor3q_u8(q_u8(a), q_u8(b), q_u8(c)));
}

/// `a ^ b.rotate_left(1)` per lane (`rax1`).
@arch(aarch64)
@target_feature([cpu::Feature::Sha3])
pub fn rax1(a: u64x2, b: u64x2) u64x2 {
    return v_u64(vrax1q_u64(q_u64(a), q_u64(b)));
}

/// `a ^ (b & !c)` (`bcax`).
@arch(aarch64)
@target_feature([cpu::Feature::Sha3])
pub fn bcax(a: u8x16, b: u8x16, c: u8x16) u8x16 {
    return v_u8(vbcaxq_u8(q_u8(a), q_u8(b), q_u8(c)));
}

/// Byte `idx[i]` of `t`, or 0 for an index of 16 or more (`tbl`).
@arch(aarch64)
@target_feature([cpu::Feature::Neon])
pub fn table_lookup(t: u8x16, idx: u8x16) u8x16 {
    return v_u8(vqtbl1q_u8(q_u8(t), q_u8(idx)));
}

/// Byte `idx[i]` of `t`, or 0 for an index of 32 or more (`tbl`).
@arch(aarch64)
@target_feature([cpu::Feature::Neon])
pub fn table_lookup_2(t: Simd<u8, 32>, idx: u8x16) u8x16 {
    let r = unsafe vld1q_u8_x2(((&t) as *const Simd<u8, 32>) as *const u8);
    return v_u8(vqtbl2q_u8(r, q_u8(idx)));
}

/// Byte `idx[i]` of `t`, or 0 for an index of 48 or more (`tbl`).
@arch(aarch64)
@target_feature([cpu::Feature::Neon])
pub fn table_lookup_3(t: [u8; 48], idx: u8x16) u8x16 {
    let r = unsafe vld1q_u8_x3(((&t) as *const [u8; 48]) as *const u8);
    return v_u8(vqtbl3q_u8(r, q_u8(idx)));
}

/// Byte `idx[i]` of `t`, or 0 for an index of 64 or more (`tbl`).
@arch(aarch64)
@target_feature([cpu::Feature::Neon])
pub fn table_lookup_4(t: Simd<u8, 64>, idx: u8x16) u8x16 {
    let r = unsafe vld1q_u8_x4(((&t) as *const Simd<u8, 64>) as *const u8);
    return v_u8(vqtbl4q_u8(r, q_u8(idx)));
}

/// `crc` updated with `data` by CRC-32 (polynomial 0x04C11DB7, bits reflected, no final inversion) (`crc32b`).
@arch(aarch64)
@target_feature([cpu::Feature::Crc])
pub fn crc32b(crc: u32, data: u8) u32 {
    return __crc32b(crc, data);
}

/// `crc` updated with `data` by CRC-32 (polynomial 0x04C11DB7, bits reflected, no final inversion) (`crc32h`).
@arch(aarch64)
@target_feature([cpu::Feature::Crc])
pub fn crc32h(crc: u32, data: u16) u32 {
    return __crc32h(crc, data);
}

/// `crc` updated with `data` by CRC-32 (polynomial 0x04C11DB7, bits reflected, no final inversion) (`crc32w`).
@arch(aarch64)
@target_feature([cpu::Feature::Crc])
pub fn crc32w(crc: u32, data: u32) u32 {
    return __crc32w(crc, data);
}

/// `crc` updated with `data` by CRC-32 (polynomial 0x04C11DB7, bits reflected, no final inversion) (`crc32x`).
@arch(aarch64)
@target_feature([cpu::Feature::Crc])
pub fn crc32x(crc: u32, data: u64) u32 {
    return __crc32d(crc, data);
}

/// `crc` updated with `data` by CRC-32C (polynomial 0x1EDC6F41, bits reflected, no final inversion) (`crc32cb`).
@arch(aarch64)
@target_feature([cpu::Feature::Crc])
pub fn crc32cb(crc: u32, data: u8) u32 {
    return __crc32cb(crc, data);
}

/// `crc` updated with `data` by CRC-32C (polynomial 0x1EDC6F41, bits reflected, no final inversion) (`crc32ch`).
@arch(aarch64)
@target_feature([cpu::Feature::Crc])
pub fn crc32ch(crc: u32, data: u16) u32 {
    return __crc32ch(crc, data);
}

/// `crc` updated with `data` by CRC-32C (polynomial 0x1EDC6F41, bits reflected, no final inversion) (`crc32cw`).
@arch(aarch64)
@target_feature([cpu::Feature::Crc])
pub fn crc32cw(crc: u32, data: u32) u32 {
    return __crc32cw(crc, data);
}

/// `crc` updated with `data` by CRC-32C (polynomial 0x1EDC6F41, bits reflected, no final inversion) (`crc32cx`).
@arch(aarch64)
@target_feature([cpu::Feature::Crc])
pub fn crc32cx(crc: u32, data: u64) u32 {
    return __crc32cd(crc, data);
}

/// `(a ^ b).rotate_right(N)` per lane, `N` below 64 (`xar`).
@arch(aarch64)
@target_feature([cpu::Feature::Sha3])
pub fn xar<const N: i32>(a: u64x2, b: u64x2) u64x2 {
    static_assert(N >= 0 && N < 64, "xar: the rotation is below 64");
    return v_u64(unsafe vxarq_u64(q_u64(a), q_u64(b), N));
}
