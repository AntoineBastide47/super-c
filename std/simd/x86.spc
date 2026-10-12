// x86-64 operations with no portable meaning, over the portable vector types. Each needs the features
// it names: a call is valid in a function whose features hold them (`@target_feature`), else inside
// `unsafe` after a run-time check (`std::cpu::detect::has`). They have no memory effect; each calls a C
// intrinsic, so no constant has its value. An immediate operand is a const parameter, checked to fit
// in 8 bits.
import std::cpu;
import immintrin as *;

// Vectors in registers, and back.
@arch(x86_64)
@target_feature([cpu::Feature::Sse2])
fn xi<T: SimdElement, const N: usize>(x: Simd<T, N>) __m128i {
    return unsafe _mm_loadu_si128(((&x) as *const Simd<T, N>) as *const __m128i_u);
}

@arch(x86_64)
@target_feature([cpu::Feature::Sse2])
fn xiv<T: SimdElement, const N: usize>(r: __m128i) Simd<T, N> {
    let mut x = unsafe zeroed::<Simd<T, N>>();
    unsafe _mm_storeu_si128(((&mut x) as *mut Simd<T, N>) as *mut __m128i_u, r);
    return x;
}

@arch(x86_64)
@target_feature([cpu::Feature::Avx])
fn yi<T: SimdElement, const N: usize>(x: Simd<T, N>) __m256i {
    return unsafe _mm256_loadu_si256(((&x) as *const Simd<T, N>) as *const __m256i_u);
}

@arch(x86_64)
@target_feature([cpu::Feature::Avx])
fn yiv<T: SimdElement, const N: usize>(r: __m256i) Simd<T, N> {
    let mut x = unsafe zeroed::<Simd<T, N>>();
    unsafe _mm256_storeu_si256(((&mut x) as *mut Simd<T, N>) as *mut __m256i_u, r);
    return x;
}

@arch(x86_64)
@target_feature([cpu::Feature::Avx512f])
fn zi<T: SimdElement, const N: usize>(x: Simd<T, N>) __m512i {
    return unsafe _mm512_loadu_si512(&x);
}

@arch(x86_64)
@target_feature([cpu::Feature::Avx512f])
fn ziv<T: SimdElement, const N: usize>(r: __m512i) Simd<T, N> {
    let mut x = unsafe zeroed::<Simd<T, N>>();
    unsafe _mm512_storeu_si512(&mut x, r);
    return x;
}

/// The products of unsigned `a` and signed `b` bytes, adjacent pairs added with signed saturation
/// (`pmaddubsw`).
@arch(x86_64)
@target_feature([cpu::Feature::Ssse3])
pub fn maddubs(a: u8x16, b: i8x16) i16x8 {
    return xiv::<i16, 8>(_mm_maddubs_epi16(xi(a), xi(b)));
}

/// The products of `a` and `b`, adjacent pairs added, modulo 2^32 (`pmaddwd`).
@arch(x86_64)
@target_feature([cpu::Feature::Sse2])
pub fn madd(a: i16x8, b: i16x8) i32x4 {
    return xiv::<i32, 4>(_mm_madd_epi16(xi(a), xi(b)));
}

/// The sums of the absolute differences of the bytes of each 64-bit half (`psadbw`).
@arch(x86_64)
@target_feature([cpu::Feature::Sse2])
pub fn sad_u8(a: u8x16, b: u8x16) u64x2 {
    return xiv::<u64, 2>(_mm_sad_epu8(xi(a), xi(b)));
}

/// The carry-less product of a 64-bit lane of `a` and one of `b` (`pclmulqdq`): bit 0 of `IMM` selects
/// `a`'s lane, bit 4 `b`'s.
@arch(x86_64)
@target_feature([cpu::Feature::Pclmulqdq])
pub fn clmul<const IMM: i32>(a: u64x2, b: u64x2) u64x2 {
    static_assert(IMM >= 0 && IMM < 256, "clmul: the selector fits in 8 bits");
    return xiv::<u64, 2>(unsafe _mm_clmulepi64_si128(xi(a), xi(b), IMM));
}

/// One AES encryption round of `state` under `key` (`aesenc`).
@arch(x86_64)
@target_feature([cpu::Feature::Aesni])
pub fn aesenc(state: u8x16, key: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_aesenc_si128(xi(state), xi(key)));
}

/// The last AES encryption round (`aesenclast`).
@arch(x86_64)
@target_feature([cpu::Feature::Aesni])
pub fn aesenclast(state: u8x16, key: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_aesenclast_si128(xi(state), xi(key)));
}

/// One AES decryption round (`aesdec`).
@arch(x86_64)
@target_feature([cpu::Feature::Aesni])
pub fn aesdec(state: u8x16, key: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_aesdec_si128(xi(state), xi(key)));
}

/// The last AES decryption round (`aesdeclast`).
@arch(x86_64)
@target_feature([cpu::Feature::Aesni])
pub fn aesdeclast(state: u8x16, key: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_aesdeclast_si128(xi(state), xi(key)));
}

/// `aesenc` of two blocks at once, each under its own key (VAES).
@arch(x86_64)
@target_feature([cpu::Feature::Vaes])
pub fn aesenc_x2(state: u8x32, key: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_aesenc_epi128(yi(state), yi(key)));
}

/// `aesenc` of four blocks at once, each under its own key (VAES).
@arch(x86_64)
@target_feature([cpu::Feature::Vaes, cpu::Feature::Avx512f])
pub fn aesenc_x4(state: u8x64, key: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_aesenc_epi128(zi(state), zi(key)));
}

/// `aesenclast` of two blocks at once (VAES).
@arch(x86_64)
@target_feature([cpu::Feature::Vaes])
pub fn aesenclast_x2(state: u8x32, key: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_aesenclast_epi128(yi(state), yi(key)));
}

/// `aesenclast` of four blocks at once (VAES).
@arch(x86_64)
@target_feature([cpu::Feature::Vaes, cpu::Feature::Avx512f])
pub fn aesenclast_x4(state: u8x64, key: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_aesenclast_epi128(zi(state), zi(key)));
}

/// `aesdec` of two blocks at once (VAES).
@arch(x86_64)
@target_feature([cpu::Feature::Vaes])
pub fn aesdec_x2(state: u8x32, key: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_aesdec_epi128(yi(state), yi(key)));
}

/// `aesdec` of four blocks at once (VAES).
@arch(x86_64)
@target_feature([cpu::Feature::Vaes, cpu::Feature::Avx512f])
pub fn aesdec_x4(state: u8x64, key: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_aesdec_epi128(zi(state), zi(key)));
}

/// `aesdeclast` of two blocks at once (VAES).
@arch(x86_64)
@target_feature([cpu::Feature::Vaes])
pub fn aesdeclast_x2(state: u8x32, key: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_aesdeclast_epi128(yi(state), yi(key)));
}

/// `aesdeclast` of four blocks at once (VAES).
@arch(x86_64)
@target_feature([cpu::Feature::Vaes, cpu::Feature::Avx512f])
pub fn aesdeclast_x4(state: u8x64, key: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_aesdeclast_epi128(zi(state), zi(key)));
}

/// The affine transform of each byte of `x` in GF(2^8) by the 8x8 bit matrix of the 64-bit lane that
/// holds it, then XOR with `B` (`gf2p8affineqb`).
@arch(x86_64)
@target_feature([cpu::Feature::Gfni])
pub fn gf2p8affine<const B: i32>(x: u8x16, a: u64x2) u8x16 {
    static_assert(B >= 0 && B < 256, "gf2p8affine: the constant is a byte");
    return xiv::<u8, 16>(unsafe _mm_gf2p8affine_epi64_epi8(xi(x), xi(a), B));
}

/// The products of the bytes in GF(2^8) modulo x^8 + x^4 + x^3 + x + 1 (`gf2p8mulb`).
@arch(x86_64)
@target_feature([cpu::Feature::Gfni])
pub fn gf2p8mul(a: u8x16, b: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_gf2p8mul_epi8(xi(a), xi(b)));
}

/// `acc` plus, per 32-bit lane, the sum of the four products of unsigned bytes of `a` and signed bytes
/// of `b`, modulo 2^32 (`vpdpbusd`).
@arch(x86_64)
@target_feature([cpu::Feature::Avx512vnni])
pub fn dpbusd(acc: i32x16, a: u8x64, b: i8x64) i32x16 {
    return ziv::<i32, 16>(_mm512_dpbusd_epi32(zi(acc), zi(a), zi(b)));
}

/// `acc` plus, per 32-bit lane, the sum of the two products of `a` and `b`, modulo 2^32 (`vpdpwssd`).
@arch(x86_64)
@target_feature([cpu::Feature::Avx512vnni])
pub fn dpwssd(acc: i32x16, a: i16x32, b: i16x32) i32x16 {
    return ziv::<i32, 16>(_mm512_dpwssd_epi32(zi(acc), zi(a), zi(b)));
}

/// Lane `i`: `(a ++ b)[idx[i] % 32]` (`vpermt2d`).
@arch(x86_64)
@target_feature([cpu::Feature::Avx512f])
pub fn permutex2var_i32(a: i32x16, idx: u32x16, b: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_permutex2var_epi32(zi(a), zi(idx), zi(b)));
}

/// Lane `i`: `(a ++ b)[idx[i] % 16]` (`vpermt2q`).
@arch(x86_64)
@target_feature([cpu::Feature::Avx512f])
pub fn permutex2var_i64(a: i64x8, idx: u64x8, b: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_permutex2var_epi64(zi(a), zi(idx), zi(b)));
}

/// Lane `i`: `(a ++ b)[idx[i] % 64]` (`vpermt2w`).
@arch(x86_64)
@target_feature([cpu::Feature::Avx512bw])
pub fn permutex2var_i16(a: i16x32, idx: u16x32, b: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_permutex2var_epi16(zi(a), zi(idx), zi(b)));
}

/// Lane `i`: `(a ++ b)[idx[i] % 128]` (`vpermt2b`).
@arch(x86_64)
@target_feature([cpu::Feature::Avx512vbmi])
pub fn permutex2var_u8(a: u8x64, idx: u8x64, b: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_permutex2var_epi8(zi(a), zi(idx), zi(b)));
}

/// Each bit: bit `(a << 2) | (b << 1) | c` of `IMM`, the truth table of any function of three inputs
/// (`vpternlogd`).
@arch(x86_64)
@target_feature([cpu::Feature::Avx512f])
pub fn ternarylogic<const IMM: i32>(a: u32x16, b: u32x16, c: u32x16) u32x16 {
    static_assert(IMM >= 0 && IMM < 256, "ternarylogic: the truth table fits in 8 bits");
    return ziv::<u32, 16>(unsafe _mm512_ternarylogic_epi32(zi(a), zi(b), zi(c), IMM));
}

/// Lane `i`: the bits of the lanes below `i` equal to lane `i` (`vpconflictd`).
@arch(x86_64)
@target_feature([cpu::Feature::Avx512cd])
pub fn conflict_u32(a: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_conflict_epi32(zi(a)));
}

/// Lane `i`: the bits of the lanes below `i` equal to lane `i` (`vpconflictq`).
@arch(x86_64)
@target_feature([cpu::Feature::Avx512cd])
pub fn conflict_u64(a: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_conflict_epi64(zi(a)));
}
