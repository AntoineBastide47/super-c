// FFI bindings for <immintrin.h> (Intel's SSE to AVX-512 intrinsics): the register types and the
// intrinsics std/simd/backend/x86_64.spc and std/simd/x86.spc call, each with the instruction set the
// header enables it under. An access through a pointer states its range, or for a masked or indexed
// one that it touches its active lanes only; an immediate operand must be a constant (its binding is
// unsafe).
import std::cpu;

extern "C" "immintrin.h" {
    /// A 128-bit register of integer lanes.
    @arch(x86_64)
    @c.value(16, 16)
    pub type __m128i;
    /// A 128-bit register of f32 lanes.
    @arch(x86_64)
    @c.value(16, 16)
    pub type __m128;
    /// A 128-bit register of f64 lanes.
    @arch(x86_64)
    @c.value(16, 16)
    pub type __m128d;
    /// The 128 bits a register load or store addresses, at any alignment.
    @arch(x86_64)
    pub type __m128i_u;
    /// A 256-bit register of integer lanes.
    @arch(x86_64)
    @c.value(32, 16)
    pub type __m256i;
    /// A 256-bit register of f32 lanes.
    @arch(x86_64)
    @c.value(32, 16)
    pub type __m256;
    /// A 256-bit register of f64 lanes.
    @arch(x86_64)
    @c.value(32, 16)
    pub type __m256d;
    /// The 256 bits a register load or store addresses, at any alignment.
    @arch(x86_64)
    pub type __m256i_u;
    /// A 512-bit register of integer lanes.
    @arch(x86_64)
    @c.value(64, 16)
    pub type __m512i;
    /// A 512-bit register of f32 lanes.
    @arch(x86_64)
    @c.value(64, 16)
    pub type __m512;
    /// A 512-bit register of f64 lanes.
    @arch(x86_64)
    @c.value(64, 16)
    pub type __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_abs_epi16(a: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_abs_epi32(a: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_abs_epi64(a: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_add_epi16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_add_epi32(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_add_epi64(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_add_epi8(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_add_pd(a: __m256d, b: __m256d) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_add_ps(a: __m256, b: __m256) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_adds_epi16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_adds_epi8(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_adds_epu16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_adds_epu8(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Vaes, cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_aesdec_epi128(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Vaes, cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_aesdeclast_epi128(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Vaes, cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_aesenc_epi128(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Vaes, cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_aesenclast_epi128(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_and_pd(a: __m256d, b: __m256d) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_and_ps(a: __m256, b: __m256) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_and_si256(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_andnot_pd(a: __m256d, b: __m256d) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_andnot_ps(a: __m256, b: __m256) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_andnot_si256(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_blendv_epi8(a: __m256i, b: __m256i, c: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_blendv_pd(a: __m256d, b: __m256d, c: __m256d) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_blendv_ps(a: __m256, b: __m256, c: __m256) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_castpd_si256(a: __m256d) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_castps_pd(a: __m256) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_castps_si256(a: __m256) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_castsi256_pd(a: __m256i) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_castsi256_ps(a: __m256i) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_castsi256_si128(a: __m256i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    pub fn _mm256_cmp_epi16_mask(a: __m256i, b: __m256i, c: i32) u16;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    pub fn _mm256_cmp_epi32_mask(a: __m256i, b: __m256i, c: i32) u8;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    pub fn _mm256_cmp_epi64_mask(a: __m256i, b: __m256i, c: i32) u8;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    pub fn _mm256_cmp_epi8_mask(a: __m256i, b: __m256i, c: i32) u32;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    pub fn _mm256_cmp_epu16_mask(a: __m256i, b: __m256i, c: i32) u16;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    pub fn _mm256_cmp_epu32_mask(a: __m256i, b: __m256i, c: i32) u8;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    pub fn _mm256_cmp_epu64_mask(a: __m256i, b: __m256i, c: i32) u8;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    pub fn _mm256_cmp_epu8_mask(a: __m256i, b: __m256i, c: i32) u32;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    pub fn _mm256_cmp_pd(a: __m256d, b: __m256d, c: i32) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    pub fn _mm256_cmp_pd_mask(a: __m256d, b: __m256d, c: i32) u8;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    pub fn _mm256_cmp_ps(a: __m256, b: __m256, c: i32) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    pub fn _mm256_cmp_ps_mask(a: __m256, b: __m256, c: i32) u8;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cmpeq_epi16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cmpeq_epi32(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cmpeq_epi64(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cmpeq_epi8(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cmpgt_epi16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cmpgt_epi32(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cmpgt_epi64(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cmpgt_epi8(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cvtepi16_epi32(a: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cvtepi16_epi64(a: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cvtepi32_epi64(a: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_cvtepi32_ps(a: __m256i) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512dq])
    @unsafe(safe)
    pub fn _mm256_cvtepi64_pd(a: __m256i) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cvtepi8_epi16(a: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cvtepi8_epi32(a: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cvtepu16_epi32(a: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cvtepu16_epi64(a: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cvtepu32_epi64(a: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_cvtepu32_ps(a: __m256i) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512dq])
    @unsafe(safe)
    pub fn _mm256_cvtepu64_pd(a: __m256i) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cvtepu8_epi16(a: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_cvtepu8_epi32(a: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_cvtpd_ps(a: __m256d) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_cvtps_pd(a: __m128) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_cvttps_epi32(a: __m256) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_div_pd(a: __m256d, b: __m256d) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_div_ps(a: __m256, b: __m256) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    pub fn _mm256_extracti128_si256(a: __m256i, b: i32) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Fma])
    @unsafe(safe)
    pub fn _mm256_fmadd_pd(a: __m256d, b: __m256d, c: __m256d) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Fma])
    @unsafe(safe)
    pub fn _mm256_fmadd_ps(a: __m256, b: __m256, c: __m256) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @c.reads(p, 32)
    pub fn _mm256_loadu_pd(p: *const f64) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @c.reads(p, 32)
    pub fn _mm256_loadu_ps(p: *const f32) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @c.reads(p, 32)
    pub fn _mm256_loadu_si256(p: *const __m256i_u) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512cd])
    @unsafe(safe)
    pub fn _mm256_lzcnt_epi32(a: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512cd])
    @unsafe(safe)
    pub fn _mm256_lzcnt_epi64(a: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm256_mask_blend_epi16(a: u16, b: __m256i, c: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_mask_blend_epi32(a: u8, b: __m256i, c: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_mask_blend_epi64(a: u8, b: __m256i, c: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm256_mask_blend_epi8(a: u32, b: __m256i, c: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_mask_blend_pd(a: u8, b: __m256d, c: __m256d) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_mask_blend_ps(a: u8, b: __m256, c: __m256) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_mask_compress_epi16(a: __m256i, b: u16, c: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_mask_compress_epi32(a: __m256i, b: u8, c: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_mask_compress_epi64(a: __m256i, b: u8, c: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm256_mask_compress_epi8(a: __m256i, b: u32, c: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_mask_compress_pd(a: __m256d, b: u8, c: __m256d) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_mask_compress_ps(a: __m256, b: u8, c: __m256) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_mask_expand_epi16(a: __m256i, b: u16, c: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_mask_expand_epi32(a: __m256i, b: u8, c: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_mask_expand_epi64(a: __m256i, b: u8, c: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm256_mask_expand_epi8(a: __m256i, b: u32, c: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_mask_expand_pd(a: __m256d, b: u8, c: __m256d) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_mask_expand_ps(a: __m256, b: u8, c: __m256) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @c.lane_access
    pub fn _mm256_mask_i64gather_epi32(a: __m128i, p: *const i32, c: __m256i, d: __m128i, e: i32) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @c.lane_access
    pub fn _mm256_mask_i64gather_epi64(a: __m256i, p: *const void, c: __m256i, d: __m256i, e: i32) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @c.lane_access
    pub fn _mm256_mask_i64gather_pd(a: __m256d, p: *const f64, c: __m256i, d: __m256d, e: i32) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @c.lane_access
    pub fn _mm256_mask_i64gather_ps(a: __m128, p: *const f32, c: __m256i, d: __m128, e: i32) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @c.lane_access
    pub fn _mm256_mask_loadu_epi16(a: __m256i, b: u16, p: *const void) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @c.lane_access
    pub fn _mm256_mask_loadu_epi32(a: __m256i, b: u8, p: *const void) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @c.lane_access
    pub fn _mm256_mask_loadu_epi64(a: __m256i, b: u8, p: *const void) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @c.lane_access
    pub fn _mm256_mask_loadu_epi8(a: __m256i, b: u32, p: *const void) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @c.lane_access
    pub fn _mm256_mask_loadu_pd(a: __m256d, b: u8, p: *const void) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @c.lane_access
    pub fn _mm256_mask_loadu_ps(a: __m256, b: u8, p: *const void) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @c.lane_access
    pub fn _mm256_mask_storeu_epi16(p: *mut void, b: u16, c: __m256i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @c.lane_access
    pub fn _mm256_mask_storeu_epi32(p: *mut void, b: u8, c: __m256i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @c.lane_access
    pub fn _mm256_mask_storeu_epi64(p: *mut void, b: u8, c: __m256i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @c.lane_access
    pub fn _mm256_mask_storeu_epi8(p: *mut void, b: u32, c: __m256i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @c.lane_access
    pub fn _mm256_mask_storeu_pd(p: *mut void, b: u8, c: __m256d);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @c.lane_access
    pub fn _mm256_mask_storeu_ps(p: *mut void, b: u8, c: __m256);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @c.lane_access
    pub fn _mm256_maskload_epi32(p: *const i32, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @c.lane_access
    pub fn _mm256_maskload_epi64(p: *const void, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @c.lane_access
    pub fn _mm256_maskload_pd(p: *const f64, b: __m256i) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @c.lane_access
    pub fn _mm256_maskload_ps(p: *const f32, b: __m256i) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @c.lane_access
    pub fn _mm256_maskstore_epi32(p: *mut i32, b: __m256i, c: __m256i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @c.lane_access
    pub fn _mm256_maskstore_epi64(p: *mut void, b: __m256i, c: __m256i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @c.lane_access
    pub fn _mm256_maskstore_pd(p: *mut f64, b: __m256i, c: __m256d);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @c.lane_access
    pub fn _mm256_maskstore_ps(p: *mut f32, b: __m256i, c: __m256);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_max_epi16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_max_epi32(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_max_epi64(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_max_epi8(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_max_epu16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_max_epu32(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_max_epu64(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_max_epu8(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_max_pd(a: __m256d, b: __m256d) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_max_ps(a: __m256, b: __m256) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_min_epi16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_min_epi32(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_min_epi64(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_min_epi8(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_min_epu16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_min_epu32(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_min_epu64(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_min_epu8(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_min_pd(a: __m256d, b: __m256d) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_min_ps(a: __m256, b: __m256) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx102])
    pub fn _mm256_minmax_pd(a: __m256d, b: __m256d, c: i32) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx102])
    pub fn _mm256_minmax_ps(a: __m256, b: __m256, c: i32) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_movemask_epi8(a: __m256i) i32;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_movemask_pd(a: __m256d) i32;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_movemask_ps(a: __m256) i32;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_mul_epu32(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_mul_pd(a: __m256d, b: __m256d) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_mul_ps(a: __m256, b: __m256) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_mulhi_epi16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_mulhi_epu16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_mullo_epi16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_mullo_epi32(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512dq])
    @unsafe(safe)
    pub fn _mm256_mullo_epi64(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_or_pd(a: __m256d, b: __m256d) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_or_ps(a: __m256, b: __m256) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_or_si256(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_permutevar8x32_epi32(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bitalg, cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_popcnt_epi16(a: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vpopcntdq, cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_popcnt_epi32(a: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vpopcntdq, cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_popcnt_epi64(a: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bitalg, cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_popcnt_epi8(a: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_rolv_epi32(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_rolv_epi64(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_rorv_epi32(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_rorv_epi64(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    pub fn _mm256_round_pd(a: __m256d, b: i32) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    pub fn _mm256_round_ps(a: __m256, b: i32) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_sad_epu8(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_set1_epi16(a: i16) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_set1_epi32(a: i32) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_set1_epi64x(a: i64) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_set1_epi8(a: i8) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_set1_pd(a: f64) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_set1_ps(a: f32) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_set_epi64x(a: i64, b: i64, c: i64, d: i64) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_set_m128(a: __m128, b: __m128) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_set_m128i(a: __m128i, b: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_setr_epi16(
        a: i16,
        b: i16,
        c: i16,
        d: i16,
        e: i16,
        f: i16,
        g: i16,
        h: i16,
        i: i16,
        j: i16,
        k: i16,
        l: i16,
        m: i16,
        n: i16,
        o: i16,
        p: i16,
    ) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_setr_epi32(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32, g: i32, h: i32) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_setr_epi8(
        a: i8,
        b: i8,
        c: i8,
        d: i8,
        e: i8,
        f: i8,
        g: i8,
        h: i8,
        i: i8,
        j: i8,
        k: i8,
        l: i8,
        m: i8,
        n: i8,
        o: i8,
        p: i8,
        q: i8,
        r: i8,
        s: i8,
        t: i8,
        u: i8,
        v: i8,
        w: i8,
        x: i8,
        y: i8,
        z: i8,
        a26: i8,
        a27: i8,
        a28: i8,
        a29: i8,
        a30: i8,
        a31: i8,
    ) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_setzero_ps() __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_setzero_si256() __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_shuffle_epi8(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_sign_epi8(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_sll_epi16(a: __m256i, b: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_sll_epi32(a: __m256i, b: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_sll_epi64(a: __m256i, b: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_slli_epi16(a: __m256i, b: i32) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_slli_epi64(a: __m256i, b: i32) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm256_sllv_epi16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_sllv_epi32(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_sllv_epi64(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_sqrt_pd(a: __m256d) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_sqrt_ps(a: __m256) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_sra_epi16(a: __m256i, b: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_sra_epi32(a: __m256i, b: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_sra_epi64(a: __m256i, b: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_srai_epi16(a: __m256i, b: i32) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm256_srav_epi16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_srav_epi32(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm256_srav_epi64(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_srl_epi16(a: __m256i, b: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_srl_epi32(a: __m256i, b: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_srl_epi64(a: __m256i, b: __m128i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_srli_epi16(a: __m256i, b: i32) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_srli_epi32(a: __m256i, b: i32) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_srli_epi64(a: __m256i, b: i32) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm256_srlv_epi16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_srlv_epi32(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_srlv_epi64(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @c.writes(p, 32)
    pub fn _mm256_storeu_pd(p: *mut f64, b: __m256d);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @c.writes(p, 32)
    pub fn _mm256_storeu_ps(p: *mut f32, b: __m256);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @c.writes(p, 32)
    pub fn _mm256_storeu_si256(p: *mut __m256i_u, b: __m256i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_sub_epi16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_sub_epi32(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_sub_epi64(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_sub_epi8(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_sub_pd(a: __m256d, b: __m256d) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_sub_ps(a: __m256, b: __m256) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_subs_epi16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_subs_epi8(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_subs_epu16(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_subs_epu8(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_xor_pd(a: __m256d, b: __m256d) __m256d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @unsafe(safe)
    pub fn _mm256_xor_ps(a: __m256, b: __m256) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm256_xor_si256(a: __m256i, b: __m256i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_abs_epi16(a: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_abs_epi32(a: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_abs_epi64(a: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_add_epi16(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_add_epi32(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_add_epi64(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_add_epi8(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_add_pd(a: __m512d, b: __m512d) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_add_ps(a: __m512, b: __m512) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_adds_epi16(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_adds_epi8(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_adds_epu16(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_adds_epu8(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Vaes, cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_aesdec_epi128(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Vaes, cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_aesdeclast_epi128(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Vaes, cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_aesenc_epi128(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Vaes, cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_aesenclast_epi128(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_and_si512(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_andnot_si512(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_castpd_ps(a: __m512d) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_castpd_si512(a: __m512d) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_castps256_ps512(a: __m256) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_castps_pd(a: __m512) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_castps_si512(a: __m512) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_castsi256_si512(a: __m256i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_castsi512_pd(a: __m512i) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_castsi512_ps(a: __m512i) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_castsi512_si256(a: __m512i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    pub fn _mm512_cmp_epi16_mask(a: __m512i, b: __m512i, c: i32) u32;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    pub fn _mm512_cmp_epi32_mask(a: __m512i, b: __m512i, c: i32) u16;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    pub fn _mm512_cmp_epi64_mask(a: __m512i, b: __m512i, c: i32) u8;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    pub fn _mm512_cmp_epi8_mask(a: __m512i, b: __m512i, c: i32) u64;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    pub fn _mm512_cmp_epu16_mask(a: __m512i, b: __m512i, c: i32) u32;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    pub fn _mm512_cmp_epu32_mask(a: __m512i, b: __m512i, c: i32) u16;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    pub fn _mm512_cmp_epu64_mask(a: __m512i, b: __m512i, c: i32) u8;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    pub fn _mm512_cmp_epu8_mask(a: __m512i, b: __m512i, c: i32) u64;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    pub fn _mm512_cmp_pd_mask(a: __m512d, b: __m512d, c: i32) u8;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    pub fn _mm512_cmp_ps_mask(a: __m512, b: __m512, c: i32) u16;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512cd])
    @unsafe(safe)
    pub fn _mm512_conflict_epi32(a: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512cd])
    @unsafe(safe)
    pub fn _mm512_conflict_epi64(a: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtepi16_epi32(a: __m256i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtepi16_epi64(a: __m128i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_cvtepi16_epi8(a: __m512i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtepi32_epi16(a: __m512i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtepi32_epi64(a: __m256i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtepi32_epi8(a: __m512i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtepi32_ps(a: __m512i) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtepi64_epi16(a: __m512i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtepi64_epi32(a: __m512i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtepi64_epi8(a: __m512i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512dq])
    @unsafe(safe)
    pub fn _mm512_cvtepi64_pd(a: __m512i) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_cvtepi8_epi16(a: __m256i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtepi8_epi32(a: __m128i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtepi8_epi64(a: __m128i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtepu16_epi32(a: __m256i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtepu16_epi64(a: __m128i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtepu32_epi64(a: __m256i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtepu32_ps(a: __m512i) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512dq])
    @unsafe(safe)
    pub fn _mm512_cvtepu64_pd(a: __m512i) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_cvtepu8_epi16(a: __m256i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtepu8_epi32(a: __m128i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtepu8_epi64(a: __m128i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtpd_ps(a: __m512d) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtps_pd(a: __m256) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_cvtsepi16_epi8(a: __m512i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtsepi32_epi16(a: __m512i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtsepi32_epi8(a: __m512i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtsepi64_epi16(a: __m512i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtsepi64_epi32(a: __m512i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtsepi64_epi8(a: __m512i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvttps_epi32(a: __m512) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvttps_epu32(a: __m512) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_cvtusepi16_epi8(a: __m512i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtusepi32_epi16(a: __m512i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtusepi32_epi8(a: __m512i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtusepi64_epi16(a: __m512i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtusepi64_epi32(a: __m512i) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_cvtusepi64_epi8(a: __m512i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_div_pd(a: __m512d, b: __m512d) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_div_ps(a: __m512, b: __m512) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vnni])
    @unsafe(safe)
    pub fn _mm512_dpbusd_epi32(a: __m512i, b: __m512i, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vnni])
    @unsafe(safe)
    pub fn _mm512_dpwssd_epi32(a: __m512i, b: __m512i, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    pub fn _mm512_extracti64x4_epi64(a: __m512i, b: i32) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_fmadd_pd(a: __m512d, b: __m512d, c: __m512d) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_fmadd_ps(a: __m512, b: __m512, c: __m512) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    pub fn _mm512_insertf64x4(a: __m512d, b: __m256d, c: i32) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    pub fn _mm512_inserti64x4(a: __m512i, b: __m256i, c: i32) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.reads(p, 64)
    pub fn _mm512_loadu_pd(p: *const void) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.reads(p, 64)
    pub fn _mm512_loadu_ps(p: *const void) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.reads(p, 64)
    pub fn _mm512_loadu_si512(p: *const void) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512cd])
    @unsafe(safe)
    pub fn _mm512_lzcnt_epi32(a: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512cd])
    @unsafe(safe)
    pub fn _mm512_lzcnt_epi64(a: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_mask_blend_epi16(a: u32, b: __m512i, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mask_blend_epi32(a: u16, b: __m512i, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mask_blend_epi64(a: u8, b: __m512i, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_mask_blend_epi8(a: u64, b: __m512i, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mask_blend_pd(a: u8, b: __m512d, c: __m512d) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mask_blend_ps(a: u16, b: __m512, c: __m512) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_mask_compress_epi16(a: __m512i, b: u32, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mask_compress_epi32(a: __m512i, b: u16, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mask_compress_epi64(a: __m512i, b: u8, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_mask_compress_epi8(a: __m512i, b: u64, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mask_compress_pd(a: __m512d, b: u8, c: __m512d) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mask_compress_ps(a: __m512, b: u16, c: __m512) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_mask_expand_epi16(a: __m512i, b: u32, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mask_expand_epi32(a: __m512i, b: u16, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mask_expand_epi64(a: __m512i, b: u8, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_mask_expand_epi8(a: __m512i, b: u64, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mask_expand_pd(a: __m512d, b: u8, c: __m512d) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mask_expand_ps(a: __m512, b: u16, c: __m512) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.lane_access
    pub fn _mm512_mask_i64gather_epi32(a: __m256i, b: u8, c: __m512i, p: *const void, e: i32) __m256i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.lane_access
    pub fn _mm512_mask_i64gather_epi64(a: __m512i, b: u8, c: __m512i, p: *const void, e: i32) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.lane_access
    pub fn _mm512_mask_i64gather_pd(a: __m512d, b: u8, c: __m512i, p: *const void, e: i32) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.lane_access
    pub fn _mm512_mask_i64gather_ps(a: __m256, b: u8, c: __m512i, p: *const void, e: i32) __m256;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.lane_access
    pub fn _mm512_mask_i64scatter_epi32(p: *mut void, b: u8, c: __m512i, d: __m256i, e: i32);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.lane_access
    pub fn _mm512_mask_i64scatter_epi64(p: *mut void, b: u8, c: __m512i, d: __m512i, e: i32);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.lane_access
    pub fn _mm512_mask_i64scatter_pd(p: *mut void, b: u8, c: __m512i, d: __m512d, e: i32);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.lane_access
    pub fn _mm512_mask_i64scatter_ps(p: *mut void, b: u8, c: __m512i, d: __m256, e: i32);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @c.lane_access
    pub fn _mm512_mask_loadu_epi16(a: __m512i, b: u32, p: *const void) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.lane_access
    pub fn _mm512_mask_loadu_epi32(a: __m512i, b: u16, p: *const void) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.lane_access
    pub fn _mm512_mask_loadu_epi64(a: __m512i, b: u8, p: *const void) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @c.lane_access
    pub fn _mm512_mask_loadu_epi8(a: __m512i, b: u64, p: *const void) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.lane_access
    pub fn _mm512_mask_loadu_pd(a: __m512d, b: u8, p: *const void) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.lane_access
    pub fn _mm512_mask_loadu_ps(a: __m512, b: u16, p: *const void) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mask_mov_epi32(a: __m512i, b: u16, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mask_or_epi32(a: __m512i, b: u16, c: __m512i, d: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mask_or_epi64(a: __m512i, b: u8, c: __m512i, d: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @c.lane_access
    pub fn _mm512_mask_storeu_epi16(p: *mut void, b: u32, c: __m512i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.lane_access
    pub fn _mm512_mask_storeu_epi32(p: *mut void, b: u16, c: __m512i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.lane_access
    pub fn _mm512_mask_storeu_epi64(p: *mut void, b: u8, c: __m512i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @c.lane_access
    pub fn _mm512_mask_storeu_epi8(p: *mut void, b: u64, c: __m512i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.lane_access
    pub fn _mm512_mask_storeu_pd(p: *mut void, b: u8, c: __m512d);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.lane_access
    pub fn _mm512_mask_storeu_ps(p: *mut void, b: u16, c: __m512);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_maskz_mov_epi32(a: u16, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_max_epi16(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_max_epi32(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_max_epi64(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_max_epi8(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_max_epu16(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_max_epu32(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_max_epu64(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_max_epu8(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_max_pd(a: __m512d, b: __m512d) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_max_ps(a: __m512, b: __m512) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_min_epi16(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_min_epi32(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_min_epi64(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_min_epi8(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_min_epu16(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_min_epu32(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_min_epu64(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_min_epu8(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_min_pd(a: __m512d, b: __m512d) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_min_ps(a: __m512, b: __m512) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx102])
    pub fn _mm512_minmax_pd(a: __m512d, b: __m512d, c: i32) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx102])
    pub fn _mm512_minmax_ps(a: __m512, b: __m512, c: i32) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mul_epu32(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mul_pd(a: __m512d, b: __m512d) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mul_ps(a: __m512, b: __m512) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_mullo_epi16(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_mullo_epi32(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512dq])
    @unsafe(safe)
    pub fn _mm512_mullo_epi64(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_or_si512(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_permutex2var_epi16(a: __m512i, b: __m512i, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_permutex2var_epi32(a: __m512i, b: __m512i, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_permutex2var_epi64(a: __m512i, b: __m512i, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vbmi])
    @unsafe(safe)
    pub fn _mm512_permutex2var_epi8(a: __m512i, b: __m512i, c: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bitalg])
    @unsafe(safe)
    pub fn _mm512_popcnt_epi16(a: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vpopcntdq])
    @unsafe(safe)
    pub fn _mm512_popcnt_epi32(a: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vpopcntdq])
    @unsafe(safe)
    pub fn _mm512_popcnt_epi64(a: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bitalg])
    @unsafe(safe)
    pub fn _mm512_popcnt_epi8(a: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_rolv_epi32(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_rolv_epi64(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_rorv_epi32(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_rorv_epi64(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    pub fn _mm512_roundscale_pd(a: __m512d, b: i32) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    pub fn _mm512_roundscale_ps(a: __m512, b: i32) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_set1_epi16(a: i16) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_set1_epi32(a: i32) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_set1_epi64(a: i64) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_set1_epi8(a: i8) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_setzero_ps() __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_setzero_si512() __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_sll_epi16(a: __m512i, b: __m128i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_sll_epi32(a: __m512i, b: __m128i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_sll_epi64(a: __m512i, b: __m128i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    pub fn _mm512_slli_epi16(a: __m512i, b: i32) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_slli_epi64(a: __m512i, b: u32) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_sllv_epi16(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_sllv_epi32(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_sllv_epi64(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_sqrt_pd(a: __m512d) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_sqrt_ps(a: __m512) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_sra_epi16(a: __m512i, b: __m128i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_sra_epi32(a: __m512i, b: __m128i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_sra_epi64(a: __m512i, b: __m128i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_srav_epi16(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_srav_epi32(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_srav_epi64(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_srl_epi16(a: __m512i, b: __m128i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_srl_epi32(a: __m512i, b: __m128i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_srl_epi64(a: __m512i, b: __m128i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    pub fn _mm512_srli_epi16(a: __m512i, b: i32) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_srli_epi64(a: __m512i, b: u32) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_srlv_epi16(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_srlv_epi32(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_srlv_epi64(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.writes(p, 64)
    pub fn _mm512_storeu_pd(p: *mut void, b: __m512d);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.writes(p, 64)
    pub fn _mm512_storeu_ps(p: *mut void, b: __m512);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @c.writes(p, 64)
    pub fn _mm512_storeu_si512(p: *mut void, b: __m512i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_sub_epi16(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_sub_epi32(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_sub_epi64(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_sub_epi8(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_sub_pd(a: __m512d, b: __m512d) __m512d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_sub_ps(a: __m512, b: __m512) __m512;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_subs_epi16(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_subs_epi8(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_subs_epu16(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm512_subs_epu8(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    pub fn _mm512_ternarylogic_epi32(a: __m512i, b: __m512i, c: __m512i, d: i32) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512f])
    @unsafe(safe)
    pub fn _mm512_xor_si512(a: __m512i, b: __m512i) __m512i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Ssse3])
    @unsafe(safe)
    pub fn _mm_abs_epi16(a: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Ssse3])
    @unsafe(safe)
    pub fn _mm_abs_epi32(a: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_abs_epi64(a: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_add_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_add_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_add_epi64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_add_epi8(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_add_pd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_add_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_add_sd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_add_ss(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_adds_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_adds_epi8(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_adds_epu16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_adds_epu8(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Aesni])
    @unsafe(safe)
    pub fn _mm_aesdec_si128(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Aesni])
    @unsafe(safe)
    pub fn _mm_aesdeclast_si128(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Aesni])
    @unsafe(safe)
    pub fn _mm_aesenc_si128(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Aesni])
    @unsafe(safe)
    pub fn _mm_aesenclast_si128(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_and_pd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_and_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_and_si128(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_andnot_pd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_andnot_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_andnot_si128(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_blendv_epi8(a: __m128i, b: __m128i, c: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_blendv_pd(a: __m128d, b: __m128d, c: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_blendv_ps(a: __m128, b: __m128, c: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_castpd_si128(a: __m128d) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_castps_si128(a: __m128) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_castsi128_pd(a: __m128i) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_castsi128_ps(a: __m128i) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Pclmulqdq])
    pub fn _mm_clmulepi64_si128(a: __m128i, b: __m128i, c: i32) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    pub fn _mm_cmp_epi16_mask(a: __m128i, b: __m128i, c: i32) u8;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    pub fn _mm_cmp_epi32_mask(a: __m128i, b: __m128i, c: i32) u8;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    pub fn _mm_cmp_epi64_mask(a: __m128i, b: __m128i, c: i32) u8;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    pub fn _mm_cmp_epi8_mask(a: __m128i, b: __m128i, c: i32) u16;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    pub fn _mm_cmp_epu16_mask(a: __m128i, b: __m128i, c: i32) u8;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    pub fn _mm_cmp_epu32_mask(a: __m128i, b: __m128i, c: i32) u8;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    pub fn _mm_cmp_epu64_mask(a: __m128i, b: __m128i, c: i32) u8;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    pub fn _mm_cmp_epu8_mask(a: __m128i, b: __m128i, c: i32) u16;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    pub fn _mm_cmp_pd_mask(a: __m128d, b: __m128d, c: i32) u8;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    pub fn _mm_cmp_ps_mask(a: __m128, b: __m128, c: i32) u8;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmpeq_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmpeq_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_cmpeq_epi64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmpeq_epi8(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmpeq_pd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmpeq_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmpge_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmpgt_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmpgt_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse42])
    @unsafe(safe)
    pub fn _mm_cmpgt_epi64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmpgt_epi8(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmple_pd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmple_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmplt_pd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmplt_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmpneq_pd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmpneq_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmpord_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmpunord_pd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cmpunord_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_cvtepi16_epi32(a: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_cvtepi32_epi64(a: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cvtepi32_ps(a: __m128i) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512dq])
    @unsafe(safe)
    pub fn _mm_cvtepi64_pd(a: __m128i) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_cvtepi8_epi16(a: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_cvtepu16_epi32(a: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_cvtepu32_epi64(a: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_cvtepu32_ps(a: __m128i) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512dq])
    @unsafe(safe)
    pub fn _mm_cvtepu64_pd(a: __m128i) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_cvtepu8_epi16(a: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cvtpd_ps(a: __m128d) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cvtps_pd(a: __m128) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cvtsd_f64(a: __m128d) f64;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cvtsi128_si32(a: __m128i) i32;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cvtsi128_si64(a: __m128i) i64;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cvtsi32_si128(a: i32) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cvtss_f32(a: __m128) f32;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_cvttps_epi32(a: __m128) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_div_pd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_div_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Fma])
    @unsafe(safe)
    pub fn _mm_fmadd_pd(a: __m128d, b: __m128d, c: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Fma])
    @unsafe(safe)
    pub fn _mm_fmadd_ps(a: __m128, b: __m128, c: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Gfni])
    pub fn _mm_gf2p8affine_epi64_epi8(a: __m128i, b: __m128i, c: i32) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Gfni])
    @unsafe(safe)
    pub fn _mm_gf2p8mul_epi8(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @c.reads(p, 8)
    pub fn _mm_loadl_epi64(p: *const __m128i_u) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @c.reads(p, 16)
    pub fn _mm_loadu_pd(p: *const f64) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @c.reads(p, 16)
    pub fn _mm_loadu_ps(p: *const f32) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @c.reads(p, 16)
    pub fn _mm_loadu_si128(p: *const __m128i_u) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512cd])
    @unsafe(safe)
    pub fn _mm_lzcnt_epi32(a: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512cd])
    @unsafe(safe)
    pub fn _mm_lzcnt_epi64(a: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_madd_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Ssse3])
    @unsafe(safe)
    pub fn _mm_maddubs_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm_mask_blend_epi16(a: u8, b: __m128i, c: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_mask_blend_epi32(a: u8, b: __m128i, c: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_mask_blend_epi64(a: u8, b: __m128i, c: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm_mask_blend_epi8(a: u16, b: __m128i, c: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_mask_blend_pd(a: u8, b: __m128d, c: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_mask_blend_ps(a: u8, b: __m128, c: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_mask_compress_epi16(a: __m128i, b: u8, c: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_mask_compress_epi32(a: __m128i, b: u8, c: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_mask_compress_epi64(a: __m128i, b: u8, c: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_mask_compress_epi8(a: __m128i, b: u16, c: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_mask_compress_pd(a: __m128d, b: u8, c: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_mask_compress_ps(a: __m128, b: u8, c: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_mask_expand_epi16(a: __m128i, b: u8, c: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_mask_expand_epi32(a: __m128i, b: u8, c: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_mask_expand_epi64(a: __m128i, b: u8, c: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_mask_expand_epi8(a: __m128i, b: u16, c: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_mask_expand_pd(a: __m128d, b: u8, c: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_mask_expand_ps(a: __m128, b: u8, c: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @c.lane_access
    pub fn _mm_mask_i64gather_epi64(a: __m128i, p: *const void, c: __m128i, d: __m128i, e: i32) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @c.lane_access
    pub fn _mm_mask_i64gather_pd(a: __m128d, p: *const f64, c: __m128i, d: __m128d, e: i32) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @c.lane_access
    pub fn _mm_mask_loadu_epi16(a: __m128i, b: u8, p: *const void) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @c.lane_access
    pub fn _mm_mask_loadu_epi32(a: __m128i, b: u8, p: *const void) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @c.lane_access
    pub fn _mm_mask_loadu_epi64(a: __m128i, b: u8, p: *const void) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @c.lane_access
    pub fn _mm_mask_loadu_epi8(a: __m128i, b: u16, p: *const void) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @c.lane_access
    pub fn _mm_mask_loadu_pd(a: __m128d, b: u8, p: *const void) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @c.lane_access
    pub fn _mm_mask_loadu_ps(a: __m128, b: u8, p: *const void) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @c.lane_access
    pub fn _mm_mask_storeu_epi16(p: *mut void, b: u8, c: __m128i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @c.lane_access
    pub fn _mm_mask_storeu_epi32(p: *mut void, b: u8, c: __m128i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @c.lane_access
    pub fn _mm_mask_storeu_epi64(p: *mut void, b: u8, c: __m128i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @c.lane_access
    pub fn _mm_mask_storeu_epi8(p: *mut void, b: u16, c: __m128i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @c.lane_access
    pub fn _mm_mask_storeu_pd(p: *mut void, b: u8, c: __m128d);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @c.lane_access
    pub fn _mm_mask_storeu_ps(p: *mut void, b: u8, c: __m128);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @c.lane_access
    pub fn _mm_maskload_epi32(p: *const i32, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @c.lane_access
    pub fn _mm_maskload_epi64(p: *const void, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @c.lane_access
    pub fn _mm_maskload_pd(p: *const f64, b: __m128i) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @c.lane_access
    pub fn _mm_maskload_ps(p: *const f32, b: __m128i) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @c.lane_access
    pub fn _mm_maskstore_epi32(p: *mut i32, b: __m128i, c: __m128i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @c.lane_access
    pub fn _mm_maskstore_epi64(p: *mut void, b: __m128i, c: __m128i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @c.lane_access
    pub fn _mm_maskstore_pd(p: *mut f64, b: __m128i, c: __m128d);
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx])
    @c.lane_access
    pub fn _mm_maskstore_ps(p: *mut f32, b: __m128i, c: __m128);
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_max_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_max_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_max_epi64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_max_epi8(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_max_epu16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_max_epu32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_max_epu64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_max_epu8(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_max_pd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_max_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_min_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_min_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_min_epi64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_min_epi8(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_min_epu16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_min_epu32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_min_epu64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_min_epu8(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_min_pd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_min_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx102])
    pub fn _mm_minmax_pd(a: __m128d, b: __m128d, c: i32) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx102])
    pub fn _mm_minmax_ps(a: __m128, b: __m128, c: i32) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_minpos_epu16(a: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_movehl_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_movemask_epi8(a: __m128i) i32;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_movemask_pd(a: __m128d) i32;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_movemask_ps(a: __m128) i32;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_mul_epu32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_mul_pd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_mul_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_mul_sd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_mul_ss(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_mulhi_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_mulhi_epu16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_mullo_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_mullo_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512dq])
    @unsafe(safe)
    pub fn _mm_mullo_epi64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_or_pd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_or_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_or_si128(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_packs_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_packs_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_packus_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    @unsafe(safe)
    pub fn _mm_packus_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bitalg, cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_popcnt_epi16(a: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vpopcntdq, cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_popcnt_epi32(a: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vpopcntdq, cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_popcnt_epi64(a: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512bitalg, cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_popcnt_epi8(a: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_rolv_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_rolv_epi64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_rorv_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_rorv_epi64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    pub fn _mm_round_pd(a: __m128d, b: i32) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse41])
    pub fn _mm_round_ps(a: __m128, b: i32) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_sad_epu8(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_set1_epi16(a: i16) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_set1_epi32(a: i32) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_set1_epi64x(a: i64) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_set1_epi8(a: i8) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_set1_pd(a: f64) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_set1_ps(a: f32) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_set_epi32(a: i32, b: i32, c: i32, d: i32) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_set_epi64x(a: i64, b: i64) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_setr_epi16(a: i16, b: i16, c: i16, d: i16, e: i16, f: i16, g: i16, h: i16) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_setr_epi32(a: i32, b: i32, c: i32, d: i32) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_setr_epi8(
        a: i8,
        b: i8,
        c: i8,
        d: i8,
        e: i8,
        f: i8,
        g: i8,
        h: i8,
        i: i8,
        j: i8,
        k: i8,
        l: i8,
        m: i8,
        n: i8,
        o: i8,
        p: i8,
    ) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_setzero_ps() __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_setzero_si128() __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_shuffle_epi32(a: __m128i, b: i32) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Ssse3])
    @unsafe(safe)
    pub fn _mm_shuffle_epi8(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_shuffle_ps(a: __m128, b: __m128, c: i32) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Ssse3])
    @unsafe(safe)
    pub fn _mm_sign_epi8(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_sll_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_sll_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_sll_epi64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_slli_epi16(a: __m128i, b: i32) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_slli_epi64(a: __m128i, b: i32) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm_sllv_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm_sllv_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm_sllv_epi64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_sqrt_pd(a: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_sqrt_ps(a: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_sra_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_sra_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_sra_epi64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_srai_epi16(a: __m128i, b: i32) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_srai_epi32(a: __m128i, b: i32) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm_srav_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm_srav_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl])
    @unsafe(safe)
    pub fn _mm_srav_epi64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_srl_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_srl_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_srl_epi64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_srli_epi16(a: __m128i, b: i32) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_srli_epi32(a: __m128i, b: i32) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_srli_epi64(a: __m128i, b: i32) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
    @unsafe(safe)
    pub fn _mm_srlv_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm_srlv_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Avx2])
    @unsafe(safe)
    pub fn _mm_srlv_epi64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @c.writes(p, 8)
    pub fn _mm_storel_epi64(p: *mut __m128i_u, b: __m128i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @c.writes(p, 16)
    pub fn _mm_storeu_pd(p: *mut f64, b: __m128d);
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @c.writes(p, 16)
    pub fn _mm_storeu_ps(p: *mut f32, b: __m128);
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @c.writes(p, 16)
    pub fn _mm_storeu_si128(p: *mut __m128i_u, b: __m128i);
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_sub_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_sub_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_sub_epi64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_sub_epi8(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_sub_pd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_sub_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_subs_epi16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_subs_epi8(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_subs_epu16(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_subs_epu8(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_unpackhi_epi64(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_unpackhi_pd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_unpacklo_epi32(a: __m128i, b: __m128i) __m128i;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_xor_pd(a: __m128d, b: __m128d) __m128d;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_xor_ps(a: __m128, b: __m128) __m128;
    @arch(x86_64)
    @target_feature([cpu::Feature::Sse2])
    @unsafe(safe)
    pub fn _mm_xor_si128(a: __m128i, b: __m128i) __m128i;
}
