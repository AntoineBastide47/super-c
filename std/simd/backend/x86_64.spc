// The x86-64 entries of the portable vector operations (`@simd_impl`): SSE2 to SSE4.2 at 128 bits,
// AVX and AVX2 at 256, AVX-512 at 512 and, through AVX-512VL, its mask-register forms at 128 and 256.
// One entry per operation, lane type, lane count and feature set that has a sequence; the planner
// takes the one with the largest feature set the function enables and splits a wider vector into
// the widest chunk the preferred width allows. An operation without an entry keeps its lane loop.
// Each entry gives the operation's exact result for every input: a trapping operator's `Overflow`
// entry, or its count check, runs before its wrapping twin. Storage is read and written with the
// unaligned forms: a vector's alignment is at most 16.
import std::cpu;
import std::simd;
import immintrin as *;

// Vector `x` in a 128-bit register, and back.
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

// Vector `x` in a 128-bit register, and back.
@arch(x86_64)
@target_feature([cpu::Feature::Sse2])
fn xf<T: SimdElement, const N: usize>(x: Simd<T, N>) __m128 {
    return unsafe _mm_loadu_ps(((&x) as *const Simd<T, N>) as *const f32);
}

@arch(x86_64)
@target_feature([cpu::Feature::Sse2])
fn xfv<T: SimdElement, const N: usize>(r: __m128) Simd<T, N> {
    let mut x = unsafe zeroed::<Simd<T, N>>();
    unsafe _mm_storeu_ps(((&mut x) as *mut Simd<T, N>) as *mut f32, r);
    return x;
}

// Vector `x` in a 128-bit register, and back.
@arch(x86_64)
@target_feature([cpu::Feature::Sse2])
fn xd<T: SimdElement, const N: usize>(x: Simd<T, N>) __m128d {
    return unsafe _mm_loadu_pd(((&x) as *const Simd<T, N>) as *const f64);
}

@arch(x86_64)
@target_feature([cpu::Feature::Sse2])
fn xdv<T: SimdElement, const N: usize>(r: __m128d) Simd<T, N> {
    let mut x = unsafe zeroed::<Simd<T, N>>();
    unsafe _mm_storeu_pd(((&mut x) as *mut Simd<T, N>) as *mut f64, r);
    return x;
}

// Vector `x` in a 256-bit register, and back.
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

// Vector `x` in a 256-bit register, and back.
@arch(x86_64)
@target_feature([cpu::Feature::Avx])
fn yf<T: SimdElement, const N: usize>(x: Simd<T, N>) __m256 {
    return unsafe _mm256_loadu_ps(((&x) as *const Simd<T, N>) as *const f32);
}

@arch(x86_64)
@target_feature([cpu::Feature::Avx])
fn yfv<T: SimdElement, const N: usize>(r: __m256) Simd<T, N> {
    let mut x = unsafe zeroed::<Simd<T, N>>();
    unsafe _mm256_storeu_ps(((&mut x) as *mut Simd<T, N>) as *mut f32, r);
    return x;
}

// Vector `x` in a 256-bit register, and back.
@arch(x86_64)
@target_feature([cpu::Feature::Avx])
fn yd<T: SimdElement, const N: usize>(x: Simd<T, N>) __m256d {
    return unsafe _mm256_loadu_pd(((&x) as *const Simd<T, N>) as *const f64);
}

@arch(x86_64)
@target_feature([cpu::Feature::Avx])
fn ydv<T: SimdElement, const N: usize>(r: __m256d) Simd<T, N> {
    let mut x = unsafe zeroed::<Simd<T, N>>();
    unsafe _mm256_storeu_pd(((&mut x) as *mut Simd<T, N>) as *mut f64, r);
    return x;
}

// Vector `x` in a 512-bit register, and back.
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

// Vector `x` in a 512-bit register, and back.
@arch(x86_64)
@target_feature([cpu::Feature::Avx512f])
fn zf<T: SimdElement, const N: usize>(x: Simd<T, N>) __m512 {
    return unsafe _mm512_loadu_ps(&x);
}

@arch(x86_64)
@target_feature([cpu::Feature::Avx512f])
fn zfv<T: SimdElement, const N: usize>(r: __m512) Simd<T, N> {
    let mut x = unsafe zeroed::<Simd<T, N>>();
    unsafe _mm512_storeu_ps(&mut x, r);
    return x;
}

// Vector `x` in a 512-bit register, and back.
@arch(x86_64)
@target_feature([cpu::Feature::Avx512f])
fn zd<T: SimdElement, const N: usize>(x: Simd<T, N>) __m512d {
    return unsafe _mm512_loadu_pd(&x);
}

@arch(x86_64)
@target_feature([cpu::Feature::Avx512f])
fn zdv<T: SimdElement, const N: usize>(r: __m512d) Simd<T, N> {
    let mut x = unsafe zeroed::<Simd<T, N>>();
    unsafe _mm512_storeu_pd(&mut x, r);
    return x;
}

// Vector `x` of 64 bits in the low half of a register, and back.
@arch(x86_64)
@target_feature([cpu::Feature::Sse2])
fn xli<T: SimdElement, const N: usize>(x: Simd<T, N>) __m128i {
    return unsafe _mm_loadl_epi64(((&x) as *const Simd<T, N>) as *const __m128i_u);
}

@arch(x86_64)
@target_feature([cpu::Feature::Sse2])
fn xliv<T: SimdElement, const N: usize>(r: __m128i) Simd<T, N> {
    let mut x = unsafe zeroed::<Simd<T, N>>();
    unsafe _mm_storel_epi64(((&mut x) as *mut Simd<T, N>) as *mut __m128i_u, r);
    return x;
}

// A pointer as `void *`, which C converts to the `long long *` some intrinsics take (an
// `int64_t *` is `long *` on LP64).
@arch(x86_64)
fn vc<T>(p: *const T) *const void {
    return p;
}

@arch(x86_64)
fn vm<T>(p: *mut T) *mut void {
    return p;
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Sse2])
fn load_i8x16(p: *const i8) i8x16 {
    return xiv::<i8, 16>(unsafe _mm_loadu_si128(p as *const __m128i_u));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Sse2])
fn store_i8x16(p: *mut i8, v: i8x16) {
    unsafe _mm_storeu_si128(p as *mut __m128i_u, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Sse2])
fn load_u8x16(p: *const u8) u8x16 {
    return xiv::<u8, 16>(unsafe _mm_loadu_si128(p as *const __m128i_u));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Sse2])
fn store_u8x16(p: *mut u8, v: u8x16) {
    unsafe _mm_storeu_si128(p as *mut __m128i_u, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Sse2])
fn load_i16x8(p: *const i16) i16x8 {
    return xiv::<i16, 8>(unsafe _mm_loadu_si128(p as *const __m128i_u));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Sse2])
fn store_i16x8(p: *mut i16, v: i16x8) {
    unsafe _mm_storeu_si128(p as *mut __m128i_u, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Sse2])
fn load_u16x8(p: *const u16) u16x8 {
    return xiv::<u16, 8>(unsafe _mm_loadu_si128(p as *const __m128i_u));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Sse2])
fn store_u16x8(p: *mut u16, v: u16x8) {
    unsafe _mm_storeu_si128(p as *mut __m128i_u, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Sse2])
fn load_i32x4(p: *const i32) i32x4 {
    return xiv::<i32, 4>(unsafe _mm_loadu_si128(p as *const __m128i_u));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Sse2])
fn store_i32x4(p: *mut i32, v: i32x4) {
    unsafe _mm_storeu_si128(p as *mut __m128i_u, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Sse2])
fn load_u32x4(p: *const u32) u32x4 {
    return xiv::<u32, 4>(unsafe _mm_loadu_si128(p as *const __m128i_u));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Sse2])
fn store_u32x4(p: *mut u32, v: u32x4) {
    unsafe _mm_storeu_si128(p as *mut __m128i_u, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Sse2])
fn load_i64x2(p: *const i64) i64x2 {
    return xiv::<i64, 2>(unsafe _mm_loadu_si128(p as *const __m128i_u));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Sse2])
fn store_i64x2(p: *mut i64, v: i64x2) {
    unsafe _mm_storeu_si128(p as *mut __m128i_u, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Sse2])
fn load_u64x2(p: *const u64) u64x2 {
    return xiv::<u64, 2>(unsafe _mm_loadu_si128(p as *const __m128i_u));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Sse2])
fn store_u64x2(p: *mut u64, v: u64x2) {
    unsafe _mm_storeu_si128(p as *mut __m128i_u, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Sse2])
fn load_f32x4(p: *const f32) f32x4 {
    return xfv::<f32, 4>(unsafe _mm_loadu_ps(p));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Sse2])
fn store_f32x4(p: *mut f32, v: f32x4) {
    unsafe _mm_storeu_ps(p, xf(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Sse2])
fn load_f64x2(p: *const f64) f64x2 {
    return xdv::<f64, 2>(unsafe _mm_loadu_pd(p));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Sse2])
fn store_f64x2(p: *mut f64, v: f64x2) {
    unsafe _mm_storeu_pd(p, xd(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx])
fn load_i8x32(p: *const i8) i8x32 {
    return yiv::<i8, 32>(unsafe _mm256_loadu_si256(p as *const __m256i_u));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx])
fn store_i8x32(p: *mut i8, v: i8x32) {
    unsafe _mm256_storeu_si256(p as *mut __m256i_u, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx])
fn load_u8x32(p: *const u8) u8x32 {
    return yiv::<u8, 32>(unsafe _mm256_loadu_si256(p as *const __m256i_u));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx])
fn store_u8x32(p: *mut u8, v: u8x32) {
    unsafe _mm256_storeu_si256(p as *mut __m256i_u, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx])
fn load_i16x16(p: *const i16) i16x16 {
    return yiv::<i16, 16>(unsafe _mm256_loadu_si256(p as *const __m256i_u));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx])
fn store_i16x16(p: *mut i16, v: i16x16) {
    unsafe _mm256_storeu_si256(p as *mut __m256i_u, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx])
fn load_u16x16(p: *const u16) u16x16 {
    return yiv::<u16, 16>(unsafe _mm256_loadu_si256(p as *const __m256i_u));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx])
fn store_u16x16(p: *mut u16, v: u16x16) {
    unsafe _mm256_storeu_si256(p as *mut __m256i_u, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx])
fn load_i32x8(p: *const i32) i32x8 {
    return yiv::<i32, 8>(unsafe _mm256_loadu_si256(p as *const __m256i_u));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx])
fn store_i32x8(p: *mut i32, v: i32x8) {
    unsafe _mm256_storeu_si256(p as *mut __m256i_u, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx])
fn load_u32x8(p: *const u32) u32x8 {
    return yiv::<u32, 8>(unsafe _mm256_loadu_si256(p as *const __m256i_u));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx])
fn store_u32x8(p: *mut u32, v: u32x8) {
    unsafe _mm256_storeu_si256(p as *mut __m256i_u, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx])
fn load_i64x4(p: *const i64) i64x4 {
    return yiv::<i64, 4>(unsafe _mm256_loadu_si256(p as *const __m256i_u));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx])
fn store_i64x4(p: *mut i64, v: i64x4) {
    unsafe _mm256_storeu_si256(p as *mut __m256i_u, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx])
fn load_u64x4(p: *const u64) u64x4 {
    return yiv::<u64, 4>(unsafe _mm256_loadu_si256(p as *const __m256i_u));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx])
fn store_u64x4(p: *mut u64, v: u64x4) {
    unsafe _mm256_storeu_si256(p as *mut __m256i_u, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx])
fn load_f32x8(p: *const f32) f32x8 {
    return yfv::<f32, 8>(unsafe _mm256_loadu_ps(p));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx])
fn store_f32x8(p: *mut f32, v: f32x8) {
    unsafe _mm256_storeu_ps(p, yf(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx])
fn load_f64x4(p: *const f64) f64x4 {
    return ydv::<f64, 4>(unsafe _mm256_loadu_pd(p));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx])
fn store_f64x4(p: *mut f64, v: f64x4) {
    unsafe _mm256_storeu_pd(p, yd(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx512f])
fn load_i8x64(p: *const i8) i8x64 {
    return ziv::<i8, 64>(unsafe _mm512_loadu_si512(p));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx512f])
fn store_i8x64(p: *mut i8, v: i8x64) {
    unsafe _mm512_storeu_si512(p, zi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx512f])
fn load_u8x64(p: *const u8) u8x64 {
    return ziv::<u8, 64>(unsafe _mm512_loadu_si512(p));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx512f])
fn store_u8x64(p: *mut u8, v: u8x64) {
    unsafe _mm512_storeu_si512(p, zi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx512f])
fn load_i16x32(p: *const i16) i16x32 {
    return ziv::<i16, 32>(unsafe _mm512_loadu_si512(p));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx512f])
fn store_i16x32(p: *mut i16, v: i16x32) {
    unsafe _mm512_storeu_si512(p, zi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx512f])
fn load_u16x32(p: *const u16) u16x32 {
    return ziv::<u16, 32>(unsafe _mm512_loadu_si512(p));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx512f])
fn store_u16x32(p: *mut u16, v: u16x32) {
    unsafe _mm512_storeu_si512(p, zi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx512f])
fn load_i32x16(p: *const i32) i32x16 {
    return ziv::<i32, 16>(unsafe _mm512_loadu_si512(p));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx512f])
fn store_i32x16(p: *mut i32, v: i32x16) {
    unsafe _mm512_storeu_si512(p, zi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx512f])
fn load_u32x16(p: *const u32) u32x16 {
    return ziv::<u32, 16>(unsafe _mm512_loadu_si512(p));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx512f])
fn store_u32x16(p: *mut u32, v: u32x16) {
    unsafe _mm512_storeu_si512(p, zi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx512f])
fn load_i64x8(p: *const i64) i64x8 {
    return ziv::<i64, 8>(unsafe _mm512_loadu_si512(p));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx512f])
fn store_i64x8(p: *mut i64, v: i64x8) {
    unsafe _mm512_storeu_si512(p, zi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx512f])
fn load_u64x8(p: *const u64) u64x8 {
    return ziv::<u64, 8>(unsafe _mm512_loadu_si512(p));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx512f])
fn store_u64x8(p: *mut u64, v: u64x8) {
    unsafe _mm512_storeu_si512(p, zi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx512f])
fn load_f32x16(p: *const f32) f32x16 {
    return zfv::<f32, 16>(unsafe _mm512_loadu_ps(p));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx512f])
fn store_f32x16(p: *mut f32, v: f32x16) {
    unsafe _mm512_storeu_ps(p, zf(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Load, [cpu::Feature::Avx512f])
fn load_f64x8(p: *const f64) f64x8 {
    return zdv::<f64, 8>(unsafe _mm512_loadu_pd(p));
}

@arch(x86_64)
@simd_impl(simd::Op::Store, [cpu::Feature::Avx512f])
fn store_f64x8(p: *mut f64, v: f64x8) {
    unsafe _mm512_storeu_pd(p, zd(v));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Sse2])
fn wrapping_add_i8x16(a: i8x16, b: i8x16) i8x16 {
    return xiv::<i8, 16>(_mm_add_epi8(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Sse2])
fn wrapping_sub_i8x16(a: i8x16, b: i8x16) i8x16 {
    return xiv::<i8, 16>(_mm_sub_epi8(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Sse2])
fn wrapping_neg_i8x16(a: i8x16) i8x16 {
    return xiv::<i8, 16>(_mm_sub_epi8(_mm_setzero_si128(), xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Sse2])
fn and_i8x16(a: i8x16, b: i8x16) i8x16 {
    return xiv::<i8, 16>(_mm_and_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Sse2])
fn or_i8x16(a: i8x16, b: i8x16) i8x16 {
    return xiv::<i8, 16>(_mm_or_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Sse2])
fn xor_i8x16(a: i8x16, b: i8x16) i8x16 {
    return xiv::<i8, 16>(_mm_xor_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Sse2])
fn not_i8x16(a: i8x16) i8x16 {
    return xiv::<i8, 16>(_mm_xor_si128(xi(a), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Sse2])
fn wrapping_add_u8x16(a: u8x16, b: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_add_epi8(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Sse2])
fn wrapping_sub_u8x16(a: u8x16, b: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_sub_epi8(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Sse2])
fn wrapping_neg_u8x16(a: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_sub_epi8(_mm_setzero_si128(), xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Sse2])
fn and_u8x16(a: u8x16, b: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_and_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Sse2])
fn or_u8x16(a: u8x16, b: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_or_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Sse2])
fn xor_u8x16(a: u8x16, b: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_xor_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Sse2])
fn not_u8x16(a: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_xor_si128(xi(a), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Sse2])
fn wrapping_add_i16x8(a: i16x8, b: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_add_epi16(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Sse2])
fn wrapping_sub_i16x8(a: i16x8, b: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_sub_epi16(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Sse2])
fn wrapping_neg_i16x8(a: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_sub_epi16(_mm_setzero_si128(), xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Sse2])
fn and_i16x8(a: i16x8, b: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_and_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Sse2])
fn or_i16x8(a: i16x8, b: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_or_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Sse2])
fn xor_i16x8(a: i16x8, b: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_xor_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Sse2])
fn not_i16x8(a: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_xor_si128(xi(a), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Sse2])
fn wrapping_add_u16x8(a: u16x8, b: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_add_epi16(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Sse2])
fn wrapping_sub_u16x8(a: u16x8, b: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_sub_epi16(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Sse2])
fn wrapping_neg_u16x8(a: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_sub_epi16(_mm_setzero_si128(), xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Sse2])
fn and_u16x8(a: u16x8, b: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_and_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Sse2])
fn or_u16x8(a: u16x8, b: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_or_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Sse2])
fn xor_u16x8(a: u16x8, b: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_xor_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Sse2])
fn not_u16x8(a: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_xor_si128(xi(a), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Sse2])
fn wrapping_add_i32x4(a: i32x4, b: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_add_epi32(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Sse2])
fn wrapping_sub_i32x4(a: i32x4, b: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_sub_epi32(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Sse2])
fn wrapping_neg_i32x4(a: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_sub_epi32(_mm_setzero_si128(), xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Sse2])
fn and_i32x4(a: i32x4, b: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_and_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Sse2])
fn or_i32x4(a: i32x4, b: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_or_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Sse2])
fn xor_i32x4(a: i32x4, b: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_xor_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Sse2])
fn not_i32x4(a: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_xor_si128(xi(a), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Sse2])
fn wrapping_add_u32x4(a: u32x4, b: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_add_epi32(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Sse2])
fn wrapping_sub_u32x4(a: u32x4, b: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_sub_epi32(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Sse2])
fn wrapping_neg_u32x4(a: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_sub_epi32(_mm_setzero_si128(), xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Sse2])
fn and_u32x4(a: u32x4, b: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_and_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Sse2])
fn or_u32x4(a: u32x4, b: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_or_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Sse2])
fn xor_u32x4(a: u32x4, b: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_xor_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Sse2])
fn not_u32x4(a: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_xor_si128(xi(a), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Sse2])
fn wrapping_add_i64x2(a: i64x2, b: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_add_epi64(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Sse2])
fn wrapping_sub_i64x2(a: i64x2, b: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_sub_epi64(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Sse2])
fn wrapping_neg_i64x2(a: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_sub_epi64(_mm_setzero_si128(), xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Sse2])
fn and_i64x2(a: i64x2, b: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_and_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Sse2])
fn or_i64x2(a: i64x2, b: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_or_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Sse2])
fn xor_i64x2(a: i64x2, b: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_xor_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Sse2])
fn not_i64x2(a: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_xor_si128(xi(a), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Sse2])
fn wrapping_add_u64x2(a: u64x2, b: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_add_epi64(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Sse2])
fn wrapping_sub_u64x2(a: u64x2, b: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_sub_epi64(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Sse2])
fn wrapping_neg_u64x2(a: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_sub_epi64(_mm_setzero_si128(), xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Sse2])
fn and_u64x2(a: u64x2, b: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_and_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Sse2])
fn or_u64x2(a: u64x2, b: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_or_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Sse2])
fn xor_u64x2(a: u64x2, b: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_xor_si128(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Sse2])
fn not_u64x2(a: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_xor_si128(xi(a), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Avx2])
fn wrapping_add_i8x32(a: i8x32, b: i8x32) i8x32 {
    return yiv::<i8, 32>(_mm256_add_epi8(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Avx2])
fn wrapping_sub_i8x32(a: i8x32, b: i8x32) i8x32 {
    return yiv::<i8, 32>(_mm256_sub_epi8(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Avx2])
fn wrapping_neg_i8x32(a: i8x32) i8x32 {
    return yiv::<i8, 32>(_mm256_sub_epi8(_mm256_setzero_si256(), yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Avx2])
fn and_i8x32(a: i8x32, b: i8x32) i8x32 {
    return yiv::<i8, 32>(_mm256_and_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Avx2])
fn or_i8x32(a: i8x32, b: i8x32) i8x32 {
    return yiv::<i8, 32>(_mm256_or_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Avx2])
fn xor_i8x32(a: i8x32, b: i8x32) i8x32 {
    return yiv::<i8, 32>(_mm256_xor_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Avx2])
fn not_i8x32(a: i8x32) i8x32 {
    return yiv::<i8, 32>(_mm256_xor_si256(yi(a), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Avx2])
fn wrapping_add_u8x32(a: u8x32, b: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_add_epi8(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Avx2])
fn wrapping_sub_u8x32(a: u8x32, b: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_sub_epi8(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Avx2])
fn wrapping_neg_u8x32(a: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_sub_epi8(_mm256_setzero_si256(), yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Avx2])
fn and_u8x32(a: u8x32, b: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_and_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Avx2])
fn or_u8x32(a: u8x32, b: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_or_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Avx2])
fn xor_u8x32(a: u8x32, b: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_xor_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Avx2])
fn not_u8x32(a: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_xor_si256(yi(a), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Avx2])
fn wrapping_add_i16x16(a: i16x16, b: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_add_epi16(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Avx2])
fn wrapping_sub_i16x16(a: i16x16, b: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_sub_epi16(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Avx2])
fn wrapping_neg_i16x16(a: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_sub_epi16(_mm256_setzero_si256(), yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Avx2])
fn and_i16x16(a: i16x16, b: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_and_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Avx2])
fn or_i16x16(a: i16x16, b: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_or_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Avx2])
fn xor_i16x16(a: i16x16, b: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_xor_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Avx2])
fn not_i16x16(a: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_xor_si256(yi(a), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Avx2])
fn wrapping_add_u16x16(a: u16x16, b: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_add_epi16(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Avx2])
fn wrapping_sub_u16x16(a: u16x16, b: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_sub_epi16(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Avx2])
fn wrapping_neg_u16x16(a: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_sub_epi16(_mm256_setzero_si256(), yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Avx2])
fn and_u16x16(a: u16x16, b: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_and_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Avx2])
fn or_u16x16(a: u16x16, b: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_or_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Avx2])
fn xor_u16x16(a: u16x16, b: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_xor_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Avx2])
fn not_u16x16(a: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_xor_si256(yi(a), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Avx2])
fn wrapping_add_i32x8(a: i32x8, b: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_add_epi32(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Avx2])
fn wrapping_sub_i32x8(a: i32x8, b: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_sub_epi32(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Avx2])
fn wrapping_neg_i32x8(a: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_sub_epi32(_mm256_setzero_si256(), yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Avx2])
fn and_i32x8(a: i32x8, b: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_and_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Avx2])
fn or_i32x8(a: i32x8, b: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_or_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Avx2])
fn xor_i32x8(a: i32x8, b: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_xor_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Avx2])
fn not_i32x8(a: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_xor_si256(yi(a), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Avx2])
fn wrapping_add_u32x8(a: u32x8, b: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_add_epi32(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Avx2])
fn wrapping_sub_u32x8(a: u32x8, b: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_sub_epi32(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Avx2])
fn wrapping_neg_u32x8(a: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_sub_epi32(_mm256_setzero_si256(), yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Avx2])
fn and_u32x8(a: u32x8, b: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_and_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Avx2])
fn or_u32x8(a: u32x8, b: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_or_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Avx2])
fn xor_u32x8(a: u32x8, b: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_xor_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Avx2])
fn not_u32x8(a: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_xor_si256(yi(a), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Avx2])
fn wrapping_add_i64x4(a: i64x4, b: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_add_epi64(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Avx2])
fn wrapping_sub_i64x4(a: i64x4, b: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_sub_epi64(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Avx2])
fn wrapping_neg_i64x4(a: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_sub_epi64(_mm256_setzero_si256(), yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Avx2])
fn and_i64x4(a: i64x4, b: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_and_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Avx2])
fn or_i64x4(a: i64x4, b: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_or_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Avx2])
fn xor_i64x4(a: i64x4, b: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_xor_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Avx2])
fn not_i64x4(a: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_xor_si256(yi(a), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Avx2])
fn wrapping_add_u64x4(a: u64x4, b: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_add_epi64(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Avx2])
fn wrapping_sub_u64x4(a: u64x4, b: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_sub_epi64(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Avx2])
fn wrapping_neg_u64x4(a: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_sub_epi64(_mm256_setzero_si256(), yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Avx2])
fn and_u64x4(a: u64x4, b: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_and_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Avx2])
fn or_u64x4(a: u64x4, b: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_or_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Avx2])
fn xor_u64x4(a: u64x4, b: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_xor_si256(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Avx2])
fn not_u64x4(a: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_xor_si256(yi(a), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Avx512bw])
fn wrapping_add_i8x64(a: i8x64, b: i8x64) i8x64 {
    return ziv::<i8, 64>(_mm512_add_epi8(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Avx512bw])
fn wrapping_sub_i8x64(a: i8x64, b: i8x64) i8x64 {
    return ziv::<i8, 64>(_mm512_sub_epi8(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Avx512bw])
fn wrapping_neg_i8x64(a: i8x64) i8x64 {
    return ziv::<i8, 64>(_mm512_sub_epi8(_mm512_setzero_si512(), zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Avx512f])
fn and_i8x64(a: i8x64, b: i8x64) i8x64 {
    return ziv::<i8, 64>(_mm512_and_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Avx512f])
fn or_i8x64(a: i8x64, b: i8x64) i8x64 {
    return ziv::<i8, 64>(_mm512_or_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Avx512f])
fn xor_i8x64(a: i8x64, b: i8x64) i8x64 {
    return ziv::<i8, 64>(_mm512_xor_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Avx512f])
fn not_i8x64(a: i8x64) i8x64 {
    return ziv::<i8, 64>(_mm512_xor_si512(zi(a), _mm512_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Avx512bw])
fn wrapping_add_u8x64(a: u8x64, b: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_add_epi8(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Avx512bw])
fn wrapping_sub_u8x64(a: u8x64, b: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_sub_epi8(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Avx512bw])
fn wrapping_neg_u8x64(a: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_sub_epi8(_mm512_setzero_si512(), zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Avx512f])
fn and_u8x64(a: u8x64, b: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_and_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Avx512f])
fn or_u8x64(a: u8x64, b: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_or_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Avx512f])
fn xor_u8x64(a: u8x64, b: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_xor_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Avx512f])
fn not_u8x64(a: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_xor_si512(zi(a), _mm512_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Avx512bw])
fn wrapping_add_i16x32(a: i16x32, b: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_add_epi16(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Avx512bw])
fn wrapping_sub_i16x32(a: i16x32, b: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_sub_epi16(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Avx512bw])
fn wrapping_neg_i16x32(a: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_sub_epi16(_mm512_setzero_si512(), zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Avx512f])
fn and_i16x32(a: i16x32, b: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_and_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Avx512f])
fn or_i16x32(a: i16x32, b: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_or_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Avx512f])
fn xor_i16x32(a: i16x32, b: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_xor_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Avx512f])
fn not_i16x32(a: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_xor_si512(zi(a), _mm512_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Avx512bw])
fn wrapping_add_u16x32(a: u16x32, b: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_add_epi16(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Avx512bw])
fn wrapping_sub_u16x32(a: u16x32, b: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_sub_epi16(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Avx512bw])
fn wrapping_neg_u16x32(a: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_sub_epi16(_mm512_setzero_si512(), zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Avx512f])
fn and_u16x32(a: u16x32, b: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_and_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Avx512f])
fn or_u16x32(a: u16x32, b: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_or_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Avx512f])
fn xor_u16x32(a: u16x32, b: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_xor_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Avx512f])
fn not_u16x32(a: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_xor_si512(zi(a), _mm512_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Avx512f])
fn wrapping_add_i32x16(a: i32x16, b: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_add_epi32(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Avx512f])
fn wrapping_sub_i32x16(a: i32x16, b: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_sub_epi32(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Avx512f])
fn wrapping_neg_i32x16(a: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_sub_epi32(_mm512_setzero_si512(), zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Avx512f])
fn and_i32x16(a: i32x16, b: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_and_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Avx512f])
fn or_i32x16(a: i32x16, b: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_or_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Avx512f])
fn xor_i32x16(a: i32x16, b: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_xor_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Avx512f])
fn not_i32x16(a: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_xor_si512(zi(a), _mm512_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Avx512f])
fn wrapping_add_u32x16(a: u32x16, b: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_add_epi32(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Avx512f])
fn wrapping_sub_u32x16(a: u32x16, b: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_sub_epi32(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Avx512f])
fn wrapping_neg_u32x16(a: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_sub_epi32(_mm512_setzero_si512(), zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Avx512f])
fn and_u32x16(a: u32x16, b: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_and_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Avx512f])
fn or_u32x16(a: u32x16, b: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_or_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Avx512f])
fn xor_u32x16(a: u32x16, b: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_xor_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Avx512f])
fn not_u32x16(a: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_xor_si512(zi(a), _mm512_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Avx512f])
fn wrapping_add_i64x8(a: i64x8, b: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_add_epi64(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Avx512f])
fn wrapping_sub_i64x8(a: i64x8, b: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_sub_epi64(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Avx512f])
fn wrapping_neg_i64x8(a: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_sub_epi64(_mm512_setzero_si512(), zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Avx512f])
fn and_i64x8(a: i64x8, b: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_and_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Avx512f])
fn or_i64x8(a: i64x8, b: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_or_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Avx512f])
fn xor_i64x8(a: i64x8, b: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_xor_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Avx512f])
fn not_i64x8(a: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_xor_si512(zi(a), _mm512_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAdd, [cpu::Feature::Avx512f])
fn wrapping_add_u64x8(a: u64x8, b: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_add_epi64(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingSub, [cpu::Feature::Avx512f])
fn wrapping_sub_u64x8(a: u64x8, b: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_sub_epi64(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingNeg, [cpu::Feature::Avx512f])
fn wrapping_neg_u64x8(a: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_sub_epi64(_mm512_setzero_si512(), zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::And, [cpu::Feature::Avx512f])
fn and_u64x8(a: u64x8, b: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_and_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Or, [cpu::Feature::Avx512f])
fn or_u64x8(a: u64x8, b: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_or_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Xor, [cpu::Feature::Avx512f])
fn xor_u64x8(a: u64x8, b: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_xor_si512(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Not, [cpu::Feature::Avx512f])
fn not_u64x8(a: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_xor_si512(zi(a), _mm512_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Sse2])
fn wrapping_mul_i8x16(a: i8x16, b: i8x16) i8x16 {
    let x = xi(a);
    let y = xi(b);
    let ev = _mm_and_si128(_mm_mullo_epi16(x, y), _mm_set1_epi16(255));
    let od = _mm_slli_epi16(_mm_mullo_epi16(_mm_srli_epi16(x, 8), _mm_srli_epi16(y, 8)), 8);
    return xiv::<i8, 16>(_mm_or_si128(ev, od));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Sse2])
fn wrapping_mul_u8x16(a: u8x16, b: u8x16) u8x16 {
    let x = xi(a);
    let y = xi(b);
    let ev = _mm_and_si128(_mm_mullo_epi16(x, y), _mm_set1_epi16(255));
    let od = _mm_slli_epi16(_mm_mullo_epi16(_mm_srli_epi16(x, 8), _mm_srli_epi16(y, 8)), 8);
    return xiv::<u8, 16>(_mm_or_si128(ev, od));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Sse2])
fn wrapping_mul_i16x8(a: i16x8, b: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_mullo_epi16(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Sse2])
fn wrapping_mul_u16x8(a: u16x8, b: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_mullo_epi16(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Sse41])
fn wrapping_mul_i32x4(a: i32x4, b: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_mullo_epi32(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Sse2])
fn wrapping_mul_i32x4_sse2(a: i32x4, b: i32x4) i32x4 {
    let x = xi(a);
    let y = xi(b);
    let ev = _mm_mul_epu32(x, y);
    let od = _mm_mul_epu32(_mm_srli_epi64(x, 32), _mm_srli_epi64(y, 32));
    return xiv::<i32, 4>(_mm_unpacklo_epi32(_mm_shuffle_epi32(ev, 8), _mm_shuffle_epi32(od, 8)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Sse41])
fn wrapping_mul_u32x4(a: u32x4, b: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_mullo_epi32(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Sse2])
fn wrapping_mul_u32x4_sse2(a: u32x4, b: u32x4) u32x4 {
    let x = xi(a);
    let y = xi(b);
    let ev = _mm_mul_epu32(x, y);
    let od = _mm_mul_epu32(_mm_srli_epi64(x, 32), _mm_srli_epi64(y, 32));
    return xiv::<u32, 4>(_mm_unpacklo_epi32(_mm_shuffle_epi32(ev, 8), _mm_shuffle_epi32(od, 8)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx512dq, cpu::Feature::Avx512vl])
fn wrapping_mul_i64x2(a: i64x2, b: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_mullo_epi64(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Sse2])
fn wrapping_mul_i64x2_sse2(a: i64x2, b: i64x2) i64x2 {
    let x = xi(a);
    let y = xi(b);
    let lo = _mm_mul_epu32(x, y);
    let c = _mm_add_epi64(_mm_mul_epu32(_mm_srli_epi64(x, 32), y), _mm_mul_epu32(x, _mm_srli_epi64(y, 32)));
    return xiv::<i64, 2>(_mm_add_epi64(lo, _mm_slli_epi64(c, 32)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx512dq, cpu::Feature::Avx512vl])
fn wrapping_mul_u64x2(a: u64x2, b: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_mullo_epi64(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Sse2])
fn wrapping_mul_u64x2_sse2(a: u64x2, b: u64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    let lo = _mm_mul_epu32(x, y);
    let c = _mm_add_epi64(_mm_mul_epu32(_mm_srli_epi64(x, 32), y), _mm_mul_epu32(x, _mm_srli_epi64(y, 32)));
    return xiv::<u64, 2>(_mm_add_epi64(lo, _mm_slli_epi64(c, 32)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx2])
fn wrapping_mul_i8x32(a: i8x32, b: i8x32) i8x32 {
    let x = yi(a);
    let y = yi(b);
    let ev = _mm256_and_si256(_mm256_mullo_epi16(x, y), _mm256_set1_epi16(255));
    let od = _mm256_slli_epi16(_mm256_mullo_epi16(_mm256_srli_epi16(x, 8), _mm256_srli_epi16(y, 8)), 8);
    return yiv::<i8, 32>(_mm256_or_si256(ev, od));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx2])
fn wrapping_mul_u8x32(a: u8x32, b: u8x32) u8x32 {
    let x = yi(a);
    let y = yi(b);
    let ev = _mm256_and_si256(_mm256_mullo_epi16(x, y), _mm256_set1_epi16(255));
    let od = _mm256_slli_epi16(_mm256_mullo_epi16(_mm256_srli_epi16(x, 8), _mm256_srli_epi16(y, 8)), 8);
    return yiv::<u8, 32>(_mm256_or_si256(ev, od));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx2])
fn wrapping_mul_i16x16(a: i16x16, b: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_mullo_epi16(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx2])
fn wrapping_mul_u16x16(a: u16x16, b: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_mullo_epi16(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx2])
fn wrapping_mul_i32x8(a: i32x8, b: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_mullo_epi32(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx2])
fn wrapping_mul_u32x8(a: u32x8, b: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_mullo_epi32(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx512dq, cpu::Feature::Avx512vl])
fn wrapping_mul_i64x4(a: i64x4, b: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_mullo_epi64(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx2])
fn wrapping_mul_i64x4_avx2(a: i64x4, b: i64x4) i64x4 {
    let x = yi(a);
    let y = yi(b);
    let lo = _mm256_mul_epu32(x, y);
    let c = _mm256_add_epi64(
        _mm256_mul_epu32(_mm256_srli_epi64(x, 32), y),
        _mm256_mul_epu32(x, _mm256_srli_epi64(y, 32)),
    );
    return yiv::<i64, 4>(_mm256_add_epi64(lo, _mm256_slli_epi64(c, 32)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx512dq, cpu::Feature::Avx512vl])
fn wrapping_mul_u64x4(a: u64x4, b: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_mullo_epi64(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx2])
fn wrapping_mul_u64x4_avx2(a: u64x4, b: u64x4) u64x4 {
    let x = yi(a);
    let y = yi(b);
    let lo = _mm256_mul_epu32(x, y);
    let c = _mm256_add_epi64(
        _mm256_mul_epu32(_mm256_srli_epi64(x, 32), y),
        _mm256_mul_epu32(x, _mm256_srli_epi64(y, 32)),
    );
    return yiv::<u64, 4>(_mm256_add_epi64(lo, _mm256_slli_epi64(c, 32)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx512bw])
fn wrapping_mul_i8x64(a: i8x64, b: i8x64) i8x64 {
    let x = zi(a);
    let y = zi(b);
    let ev = _mm512_and_si512(_mm512_mullo_epi16(x, y), _mm512_set1_epi16(255));
    let od = unsafe _mm512_slli_epi16(
        _mm512_mullo_epi16(unsafe _mm512_srli_epi16(x, 8), unsafe _mm512_srli_epi16(y, 8)),
        8,
    );
    return ziv::<i8, 64>(_mm512_or_si512(ev, od));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx512bw])
fn wrapping_mul_u8x64(a: u8x64, b: u8x64) u8x64 {
    let x = zi(a);
    let y = zi(b);
    let ev = _mm512_and_si512(_mm512_mullo_epi16(x, y), _mm512_set1_epi16(255));
    let od = unsafe _mm512_slli_epi16(
        _mm512_mullo_epi16(unsafe _mm512_srli_epi16(x, 8), unsafe _mm512_srli_epi16(y, 8)),
        8,
    );
    return ziv::<u8, 64>(_mm512_or_si512(ev, od));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx512bw])
fn wrapping_mul_i16x32(a: i16x32, b: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_mullo_epi16(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx512bw])
fn wrapping_mul_u16x32(a: u16x32, b: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_mullo_epi16(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx512f])
fn wrapping_mul_i32x16(a: i32x16, b: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_mullo_epi32(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx512f])
fn wrapping_mul_u32x16(a: u32x16, b: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_mullo_epi32(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx512dq])
fn wrapping_mul_i64x8(a: i64x8, b: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_mullo_epi64(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx512f])
fn wrapping_mul_i64x8_avx512f(a: i64x8, b: i64x8) i64x8 {
    let x = zi(a);
    let y = zi(b);
    let lo = _mm512_mul_epu32(x, y);
    let c = _mm512_add_epi64(
        _mm512_mul_epu32(_mm512_srli_epi64(x, 32), y),
        _mm512_mul_epu32(x, _mm512_srli_epi64(y, 32)),
    );
    return ziv::<i64, 8>(_mm512_add_epi64(lo, _mm512_slli_epi64(c, 32)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx512dq])
fn wrapping_mul_u64x8(a: u64x8, b: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_mullo_epi64(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingMul, [cpu::Feature::Avx512f])
fn wrapping_mul_u64x8_avx512f(a: u64x8, b: u64x8) u64x8 {
    let x = zi(a);
    let y = zi(b);
    let lo = _mm512_mul_epu32(x, y);
    let c = _mm512_add_epi64(
        _mm512_mul_epu32(_mm512_srli_epi64(x, 32), y),
        _mm512_mul_epu32(x, _mm512_srli_epi64(y, 32)),
    );
    return ziv::<u64, 8>(_mm512_add_epi64(lo, _mm512_slli_epi64(c, 32)));
}

@arch(x86_64)
@simd_impl(simd::Op::Add, [cpu::Feature::Sse2])
fn add_f32x4(a: f32x4, b: f32x4) f32x4 {
    return xfv::<f32, 4>(_mm_add_ps(xf(a), xf(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Sub, [cpu::Feature::Sse2])
fn sub_f32x4(a: f32x4, b: f32x4) f32x4 {
    return xfv::<f32, 4>(_mm_sub_ps(xf(a), xf(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Mul, [cpu::Feature::Sse2])
fn mul_f32x4(a: f32x4, b: f32x4) f32x4 {
    return xfv::<f32, 4>(_mm_mul_ps(xf(a), xf(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Div, [cpu::Feature::Sse2])
fn div_f32x4(a: f32x4, b: f32x4) f32x4 {
    return xfv::<f32, 4>(_mm_div_ps(xf(a), xf(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Sqrt, [cpu::Feature::Sse2])
fn sqrt_f32x4(a: f32x4) f32x4 {
    return xfv::<f32, 4>(_mm_sqrt_ps(xf(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Fma, [cpu::Feature::Fma])
fn fma_f32x4(a: f32x4, b: f32x4, c: f32x4) f32x4 {
    return xfv::<f32, 4>(_mm_fmadd_ps(xf(a), xf(b), xf(c)));
}

@arch(x86_64)
@simd_impl(simd::Op::Neg, [cpu::Feature::Sse2])
fn neg_f32x4(a: f32x4) f32x4 {
    return xfv::<f32, 4>(_mm_xor_ps(xf(a), _mm_set1_ps(-0.0)));
}

@arch(x86_64)
@simd_impl(simd::Op::Abs, [cpu::Feature::Sse2])
fn abs_f32x4(a: f32x4) f32x4 {
    return xfv::<f32, 4>(_mm_andnot_ps(_mm_set1_ps(-0.0), xf(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Copysign, [cpu::Feature::Sse2])
fn copysign_f32x4(a: f32x4, b: f32x4) f32x4 {
    let s = _mm_set1_ps(-0.0);
    return xfv::<f32, 4>(_mm_or_ps(_mm_andnot_ps(s, xf(a)), _mm_and_ps(s, xf(b))));
}

@arch(x86_64)
@simd_impl(simd::Op::RoundEven, [cpu::Feature::Sse41])
fn round_even_f32x4(a: f32x4) f32x4 {
    return xfv::<f32, 4>(unsafe _mm_round_ps(xf(a), 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Floor, [cpu::Feature::Sse41])
fn floor_f32x4(a: f32x4) f32x4 {
    return xfv::<f32, 4>(unsafe _mm_round_ps(xf(a), 9));
}

@arch(x86_64)
@simd_impl(simd::Op::Ceil, [cpu::Feature::Sse41])
fn ceil_f32x4(a: f32x4) f32x4 {
    return xfv::<f32, 4>(unsafe _mm_round_ps(xf(a), 10));
}

@arch(x86_64)
@simd_impl(simd::Op::Trunc, [cpu::Feature::Sse41])
fn trunc_f32x4(a: f32x4) f32x4 {
    return xfv::<f32, 4>(unsafe _mm_round_ps(xf(a), 11));
}

@arch(x86_64)
@simd_impl(simd::Op::Add, [cpu::Feature::Sse2])
fn add_f64x2(a: f64x2, b: f64x2) f64x2 {
    return xdv::<f64, 2>(_mm_add_pd(xd(a), xd(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Sub, [cpu::Feature::Sse2])
fn sub_f64x2(a: f64x2, b: f64x2) f64x2 {
    return xdv::<f64, 2>(_mm_sub_pd(xd(a), xd(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Mul, [cpu::Feature::Sse2])
fn mul_f64x2(a: f64x2, b: f64x2) f64x2 {
    return xdv::<f64, 2>(_mm_mul_pd(xd(a), xd(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Div, [cpu::Feature::Sse2])
fn div_f64x2(a: f64x2, b: f64x2) f64x2 {
    return xdv::<f64, 2>(_mm_div_pd(xd(a), xd(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Sqrt, [cpu::Feature::Sse2])
fn sqrt_f64x2(a: f64x2) f64x2 {
    return xdv::<f64, 2>(_mm_sqrt_pd(xd(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Fma, [cpu::Feature::Fma])
fn fma_f64x2(a: f64x2, b: f64x2, c: f64x2) f64x2 {
    return xdv::<f64, 2>(_mm_fmadd_pd(xd(a), xd(b), xd(c)));
}

@arch(x86_64)
@simd_impl(simd::Op::Neg, [cpu::Feature::Sse2])
fn neg_f64x2(a: f64x2) f64x2 {
    return xdv::<f64, 2>(_mm_xor_pd(xd(a), _mm_set1_pd(-0.0)));
}

@arch(x86_64)
@simd_impl(simd::Op::Abs, [cpu::Feature::Sse2])
fn abs_f64x2(a: f64x2) f64x2 {
    return xdv::<f64, 2>(_mm_andnot_pd(_mm_set1_pd(-0.0), xd(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Copysign, [cpu::Feature::Sse2])
fn copysign_f64x2(a: f64x2, b: f64x2) f64x2 {
    let s = _mm_set1_pd(-0.0);
    return xdv::<f64, 2>(_mm_or_pd(_mm_andnot_pd(s, xd(a)), _mm_and_pd(s, xd(b))));
}

@arch(x86_64)
@simd_impl(simd::Op::RoundEven, [cpu::Feature::Sse41])
fn round_even_f64x2(a: f64x2) f64x2 {
    return xdv::<f64, 2>(unsafe _mm_round_pd(xd(a), 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Floor, [cpu::Feature::Sse41])
fn floor_f64x2(a: f64x2) f64x2 {
    return xdv::<f64, 2>(unsafe _mm_round_pd(xd(a), 9));
}

@arch(x86_64)
@simd_impl(simd::Op::Ceil, [cpu::Feature::Sse41])
fn ceil_f64x2(a: f64x2) f64x2 {
    return xdv::<f64, 2>(unsafe _mm_round_pd(xd(a), 10));
}

@arch(x86_64)
@simd_impl(simd::Op::Trunc, [cpu::Feature::Sse41])
fn trunc_f64x2(a: f64x2) f64x2 {
    return xdv::<f64, 2>(unsafe _mm_round_pd(xd(a), 11));
}

@arch(x86_64)
@simd_impl(simd::Op::Add, [cpu::Feature::Avx])
fn add_f32x8(a: f32x8, b: f32x8) f32x8 {
    return yfv::<f32, 8>(_mm256_add_ps(yf(a), yf(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Sub, [cpu::Feature::Avx])
fn sub_f32x8(a: f32x8, b: f32x8) f32x8 {
    return yfv::<f32, 8>(_mm256_sub_ps(yf(a), yf(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Mul, [cpu::Feature::Avx])
fn mul_f32x8(a: f32x8, b: f32x8) f32x8 {
    return yfv::<f32, 8>(_mm256_mul_ps(yf(a), yf(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Div, [cpu::Feature::Avx])
fn div_f32x8(a: f32x8, b: f32x8) f32x8 {
    return yfv::<f32, 8>(_mm256_div_ps(yf(a), yf(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Sqrt, [cpu::Feature::Avx])
fn sqrt_f32x8(a: f32x8) f32x8 {
    return yfv::<f32, 8>(_mm256_sqrt_ps(yf(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Fma, [cpu::Feature::Fma])
fn fma_f32x8(a: f32x8, b: f32x8, c: f32x8) f32x8 {
    return yfv::<f32, 8>(_mm256_fmadd_ps(yf(a), yf(b), yf(c)));
}

@arch(x86_64)
@simd_impl(simd::Op::Neg, [cpu::Feature::Avx])
fn neg_f32x8(a: f32x8) f32x8 {
    return yfv::<f32, 8>(_mm256_xor_ps(yf(a), _mm256_set1_ps(-0.0)));
}

@arch(x86_64)
@simd_impl(simd::Op::Abs, [cpu::Feature::Avx])
fn abs_f32x8(a: f32x8) f32x8 {
    return yfv::<f32, 8>(_mm256_andnot_ps(_mm256_set1_ps(-0.0), yf(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Copysign, [cpu::Feature::Avx])
fn copysign_f32x8(a: f32x8, b: f32x8) f32x8 {
    let s = _mm256_set1_ps(-0.0);
    return yfv::<f32, 8>(_mm256_or_ps(_mm256_andnot_ps(s, yf(a)), _mm256_and_ps(s, yf(b))));
}

@arch(x86_64)
@simd_impl(simd::Op::RoundEven, [cpu::Feature::Avx])
fn round_even_f32x8(a: f32x8) f32x8 {
    return yfv::<f32, 8>(unsafe _mm256_round_ps(yf(a), 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Floor, [cpu::Feature::Avx])
fn floor_f32x8(a: f32x8) f32x8 {
    return yfv::<f32, 8>(unsafe _mm256_round_ps(yf(a), 9));
}

@arch(x86_64)
@simd_impl(simd::Op::Ceil, [cpu::Feature::Avx])
fn ceil_f32x8(a: f32x8) f32x8 {
    return yfv::<f32, 8>(unsafe _mm256_round_ps(yf(a), 10));
}

@arch(x86_64)
@simd_impl(simd::Op::Trunc, [cpu::Feature::Avx])
fn trunc_f32x8(a: f32x8) f32x8 {
    return yfv::<f32, 8>(unsafe _mm256_round_ps(yf(a), 11));
}

@arch(x86_64)
@simd_impl(simd::Op::Add, [cpu::Feature::Avx])
fn add_f64x4(a: f64x4, b: f64x4) f64x4 {
    return ydv::<f64, 4>(_mm256_add_pd(yd(a), yd(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Sub, [cpu::Feature::Avx])
fn sub_f64x4(a: f64x4, b: f64x4) f64x4 {
    return ydv::<f64, 4>(_mm256_sub_pd(yd(a), yd(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Mul, [cpu::Feature::Avx])
fn mul_f64x4(a: f64x4, b: f64x4) f64x4 {
    return ydv::<f64, 4>(_mm256_mul_pd(yd(a), yd(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Div, [cpu::Feature::Avx])
fn div_f64x4(a: f64x4, b: f64x4) f64x4 {
    return ydv::<f64, 4>(_mm256_div_pd(yd(a), yd(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Sqrt, [cpu::Feature::Avx])
fn sqrt_f64x4(a: f64x4) f64x4 {
    return ydv::<f64, 4>(_mm256_sqrt_pd(yd(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Fma, [cpu::Feature::Fma])
fn fma_f64x4(a: f64x4, b: f64x4, c: f64x4) f64x4 {
    return ydv::<f64, 4>(_mm256_fmadd_pd(yd(a), yd(b), yd(c)));
}

@arch(x86_64)
@simd_impl(simd::Op::Neg, [cpu::Feature::Avx])
fn neg_f64x4(a: f64x4) f64x4 {
    return ydv::<f64, 4>(_mm256_xor_pd(yd(a), _mm256_set1_pd(-0.0)));
}

@arch(x86_64)
@simd_impl(simd::Op::Abs, [cpu::Feature::Avx])
fn abs_f64x4(a: f64x4) f64x4 {
    return ydv::<f64, 4>(_mm256_andnot_pd(_mm256_set1_pd(-0.0), yd(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Copysign, [cpu::Feature::Avx])
fn copysign_f64x4(a: f64x4, b: f64x4) f64x4 {
    let s = _mm256_set1_pd(-0.0);
    return ydv::<f64, 4>(_mm256_or_pd(_mm256_andnot_pd(s, yd(a)), _mm256_and_pd(s, yd(b))));
}

@arch(x86_64)
@simd_impl(simd::Op::RoundEven, [cpu::Feature::Avx])
fn round_even_f64x4(a: f64x4) f64x4 {
    return ydv::<f64, 4>(unsafe _mm256_round_pd(yd(a), 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Floor, [cpu::Feature::Avx])
fn floor_f64x4(a: f64x4) f64x4 {
    return ydv::<f64, 4>(unsafe _mm256_round_pd(yd(a), 9));
}

@arch(x86_64)
@simd_impl(simd::Op::Ceil, [cpu::Feature::Avx])
fn ceil_f64x4(a: f64x4) f64x4 {
    return ydv::<f64, 4>(unsafe _mm256_round_pd(yd(a), 10));
}

@arch(x86_64)
@simd_impl(simd::Op::Trunc, [cpu::Feature::Avx])
fn trunc_f64x4(a: f64x4) f64x4 {
    return ydv::<f64, 4>(unsafe _mm256_round_pd(yd(a), 11));
}

@arch(x86_64)
@simd_impl(simd::Op::Add, [cpu::Feature::Avx512f])
fn add_f32x16(a: f32x16, b: f32x16) f32x16 {
    return zfv::<f32, 16>(_mm512_add_ps(zf(a), zf(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Sub, [cpu::Feature::Avx512f])
fn sub_f32x16(a: f32x16, b: f32x16) f32x16 {
    return zfv::<f32, 16>(_mm512_sub_ps(zf(a), zf(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Mul, [cpu::Feature::Avx512f])
fn mul_f32x16(a: f32x16, b: f32x16) f32x16 {
    return zfv::<f32, 16>(_mm512_mul_ps(zf(a), zf(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Div, [cpu::Feature::Avx512f])
fn div_f32x16(a: f32x16, b: f32x16) f32x16 {
    return zfv::<f32, 16>(_mm512_div_ps(zf(a), zf(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Sqrt, [cpu::Feature::Avx512f])
fn sqrt_f32x16(a: f32x16) f32x16 {
    return zfv::<f32, 16>(_mm512_sqrt_ps(zf(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Fma, [cpu::Feature::Avx512f])
fn fma_f32x16(a: f32x16, b: f32x16, c: f32x16) f32x16 {
    return zfv::<f32, 16>(_mm512_fmadd_ps(zf(a), zf(b), zf(c)));
}

@arch(x86_64)
@simd_impl(simd::Op::Neg, [cpu::Feature::Avx512f])
fn neg_f32x16(a: f32x16) f32x16 {
    return zfv::<f32, 16>(
        _mm512_castsi512_ps(_mm512_xor_si512(_mm512_castps_si512(zf(a)), _mm512_set1_epi32(-2147483648))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Abs, [cpu::Feature::Avx512f])
fn abs_f32x16(a: f32x16) f32x16 {
    return zfv::<f32, 16>(
        _mm512_castsi512_ps(_mm512_andnot_si512(_mm512_set1_epi32(-2147483648), _mm512_castps_si512(zf(a)))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Copysign, [cpu::Feature::Avx512f])
fn copysign_f32x16(a: f32x16, b: f32x16) f32x16 {
    let s = _mm512_set1_epi32(-2147483648);
    return zfv::<f32, 16>(
        _mm512_castsi512_ps(
            _mm512_or_si512(
                _mm512_andnot_si512(s, _mm512_castps_si512(zf(a))),
                _mm512_and_si512(s, _mm512_castps_si512(zf(b))),
            ),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::RoundEven, [cpu::Feature::Avx512f])
fn round_even_f32x16(a: f32x16) f32x16 {
    return zfv::<f32, 16>(unsafe _mm512_roundscale_ps(zf(a), 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Floor, [cpu::Feature::Avx512f])
fn floor_f32x16(a: f32x16) f32x16 {
    return zfv::<f32, 16>(unsafe _mm512_roundscale_ps(zf(a), 9));
}

@arch(x86_64)
@simd_impl(simd::Op::Ceil, [cpu::Feature::Avx512f])
fn ceil_f32x16(a: f32x16) f32x16 {
    return zfv::<f32, 16>(unsafe _mm512_roundscale_ps(zf(a), 10));
}

@arch(x86_64)
@simd_impl(simd::Op::Trunc, [cpu::Feature::Avx512f])
fn trunc_f32x16(a: f32x16) f32x16 {
    return zfv::<f32, 16>(unsafe _mm512_roundscale_ps(zf(a), 11));
}

@arch(x86_64)
@simd_impl(simd::Op::Add, [cpu::Feature::Avx512f])
fn add_f64x8(a: f64x8, b: f64x8) f64x8 {
    return zdv::<f64, 8>(_mm512_add_pd(zd(a), zd(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Sub, [cpu::Feature::Avx512f])
fn sub_f64x8(a: f64x8, b: f64x8) f64x8 {
    return zdv::<f64, 8>(_mm512_sub_pd(zd(a), zd(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Mul, [cpu::Feature::Avx512f])
fn mul_f64x8(a: f64x8, b: f64x8) f64x8 {
    return zdv::<f64, 8>(_mm512_mul_pd(zd(a), zd(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Div, [cpu::Feature::Avx512f])
fn div_f64x8(a: f64x8, b: f64x8) f64x8 {
    return zdv::<f64, 8>(_mm512_div_pd(zd(a), zd(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Sqrt, [cpu::Feature::Avx512f])
fn sqrt_f64x8(a: f64x8) f64x8 {
    return zdv::<f64, 8>(_mm512_sqrt_pd(zd(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Fma, [cpu::Feature::Avx512f])
fn fma_f64x8(a: f64x8, b: f64x8, c: f64x8) f64x8 {
    return zdv::<f64, 8>(_mm512_fmadd_pd(zd(a), zd(b), zd(c)));
}

@arch(x86_64)
@simd_impl(simd::Op::Neg, [cpu::Feature::Avx512f])
fn neg_f64x8(a: f64x8) f64x8 {
    return zdv::<f64, 8>(
        _mm512_castsi512_pd(_mm512_xor_si512(_mm512_castpd_si512(zd(a)), _mm512_set1_epi64(-9223372036854775807 - 1))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Abs, [cpu::Feature::Avx512f])
fn abs_f64x8(a: f64x8) f64x8 {
    return zdv::<f64, 8>(
        _mm512_castsi512_pd(
            _mm512_andnot_si512(_mm512_set1_epi64(-9223372036854775807 - 1), _mm512_castpd_si512(zd(a))),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Copysign, [cpu::Feature::Avx512f])
fn copysign_f64x8(a: f64x8, b: f64x8) f64x8 {
    let s = _mm512_set1_epi64(-9223372036854775807 - 1);
    return zdv::<f64, 8>(
        _mm512_castsi512_pd(
            _mm512_or_si512(
                _mm512_andnot_si512(s, _mm512_castpd_si512(zd(a))),
                _mm512_and_si512(s, _mm512_castpd_si512(zd(b))),
            ),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::RoundEven, [cpu::Feature::Avx512f])
fn round_even_f64x8(a: f64x8) f64x8 {
    return zdv::<f64, 8>(unsafe _mm512_roundscale_pd(zd(a), 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Floor, [cpu::Feature::Avx512f])
fn floor_f64x8(a: f64x8) f64x8 {
    return zdv::<f64, 8>(unsafe _mm512_roundscale_pd(zd(a), 9));
}

@arch(x86_64)
@simd_impl(simd::Op::Ceil, [cpu::Feature::Avx512f])
fn ceil_f64x8(a: f64x8) f64x8 {
    return zdv::<f64, 8>(unsafe _mm512_roundscale_pd(zd(a), 10));
}

@arch(x86_64)
@simd_impl(simd::Op::Trunc, [cpu::Feature::Avx512f])
fn trunc_f64x8(a: f64x8) f64x8 {
    return zdv::<f64, 8>(unsafe _mm512_roundscale_pd(zd(a), 11));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Sse41])
fn min_i8x16(a: i8x16, b: i8x16) i8x16 {
    return xiv::<i8, 16>(_mm_min_epi8(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Sse2])
fn min_i8x16_sse2(a: i8x16, b: i8x16) i8x16 {
    let x = xi(a);
    let y = xi(b);
    let g = _mm_cmpgt_epi8(x, y);
    return xiv::<i8, 16>(_mm_or_si128(_mm_and_si128(g, y), _mm_andnot_si128(g, x)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Sse41])
fn max_i8x16(a: i8x16, b: i8x16) i8x16 {
    return xiv::<i8, 16>(_mm_max_epi8(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Sse2])
fn max_i8x16_sse2(a: i8x16, b: i8x16) i8x16 {
    let x = xi(a);
    let y = xi(b);
    let g = _mm_cmpgt_epi8(x, y);
    return xiv::<i8, 16>(_mm_or_si128(_mm_and_si128(g, x), _mm_andnot_si128(g, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Ssse3])
fn wrapping_abs_i8x16(a: i8x16) i8x16 {
    let x = xi(a);
    return xiv::<i8, 16>(_mm_sign_epi8(x, x));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Sse2])
fn wrapping_abs_i8x16_sse2(a: i8x16) i8x16 {
    let x = xi(a);
    let s = _mm_cmpgt_epi8(_mm_setzero_si128(), x);
    return xiv::<i8, 16>(_mm_sub_epi8(_mm_xor_si128(x, s), s));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingAdd, [cpu::Feature::Sse2])
fn saturating_add_i8x16(a: i8x16, b: i8x16) i8x16 {
    return xiv::<i8, 16>(_mm_adds_epi8(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingSub, [cpu::Feature::Sse2])
fn saturating_sub_i8x16(a: i8x16, b: i8x16) i8x16 {
    return xiv::<i8, 16>(_mm_subs_epi8(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Sse41])
fn abs_diff_i8x16(a: i8x16, b: i8x16) u8x16 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u8, 16>(_mm_sub_epi8(_mm_max_epi8(x, y), _mm_min_epi8(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Sse2])
fn min_u8x16(a: u8x16, b: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_min_epu8(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Sse2])
fn max_u8x16(a: u8x16, b: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_max_epu8(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingAdd, [cpu::Feature::Sse2])
fn saturating_add_u8x16(a: u8x16, b: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_adds_epu8(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingSub, [cpu::Feature::Sse2])
fn saturating_sub_u8x16(a: u8x16, b: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_subs_epu8(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Sse2])
fn abs_diff_u8x16(a: u8x16, b: u8x16) u8x16 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u8, 16>(_mm_sub_epi8(_mm_max_epu8(x, y), _mm_min_epu8(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Sse2])
fn min_i16x8(a: i16x8, b: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_min_epi16(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Sse2])
fn max_i16x8(a: i16x8, b: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_max_epi16(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Ssse3])
fn wrapping_abs_i16x8(a: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_abs_epi16(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Sse2])
fn wrapping_abs_i16x8_sse2(a: i16x8) i16x8 {
    let x = xi(a);
    let s = _mm_srai_epi16(x, 15);
    return xiv::<i16, 8>(_mm_sub_epi16(_mm_xor_si128(x, s), s));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingAdd, [cpu::Feature::Sse2])
fn saturating_add_i16x8(a: i16x8, b: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_adds_epi16(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingSub, [cpu::Feature::Sse2])
fn saturating_sub_i16x8(a: i16x8, b: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_subs_epi16(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Sse2])
fn abs_diff_i16x8(a: i16x8, b: i16x8) u16x8 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u16, 8>(_mm_sub_epi16(_mm_max_epi16(x, y), _mm_min_epi16(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Sse41])
fn min_u16x8(a: u16x8, b: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_min_epu16(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Sse2])
fn min_u16x8_sse2(a: u16x8, b: u16x8) u16x8 {
    let x = xi(a);
    let d = _mm_subs_epu16(x, xi(b));
    return xiv::<u16, 8>(_mm_sub_epi16(x, d));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Sse41])
fn max_u16x8(a: u16x8, b: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_max_epu16(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Sse2])
fn max_u16x8_sse2(a: u16x8, b: u16x8) u16x8 {
    let x = xi(a);
    let d = _mm_subs_epu16(x, xi(b));
    return xiv::<u16, 8>(_mm_add_epi16(xi(b), d));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingAdd, [cpu::Feature::Sse2])
fn saturating_add_u16x8(a: u16x8, b: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_adds_epu16(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingSub, [cpu::Feature::Sse2])
fn saturating_sub_u16x8(a: u16x8, b: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_subs_epu16(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Sse41])
fn abs_diff_u16x8(a: u16x8, b: u16x8) u16x8 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u16, 8>(_mm_sub_epi16(_mm_max_epu16(x, y), _mm_min_epu16(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Sse41])
fn min_i32x4(a: i32x4, b: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_min_epi32(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Sse2])
fn min_i32x4_sse2(a: i32x4, b: i32x4) i32x4 {
    let x = xi(a);
    let y = xi(b);
    let g = _mm_cmpgt_epi32(x, y);
    return xiv::<i32, 4>(_mm_or_si128(_mm_and_si128(g, y), _mm_andnot_si128(g, x)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Sse41])
fn max_i32x4(a: i32x4, b: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_max_epi32(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Sse2])
fn max_i32x4_sse2(a: i32x4, b: i32x4) i32x4 {
    let x = xi(a);
    let y = xi(b);
    let g = _mm_cmpgt_epi32(x, y);
    return xiv::<i32, 4>(_mm_or_si128(_mm_and_si128(g, x), _mm_andnot_si128(g, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Ssse3])
fn wrapping_abs_i32x4(a: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_abs_epi32(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Sse2])
fn wrapping_abs_i32x4_sse2(a: i32x4) i32x4 {
    let x = xi(a);
    let s = _mm_srai_epi32(x, 31);
    return xiv::<i32, 4>(_mm_sub_epi32(_mm_xor_si128(x, s), s));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Sse41])
fn abs_diff_i32x4(a: i32x4, b: i32x4) u32x4 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u32, 4>(_mm_sub_epi32(_mm_max_epi32(x, y), _mm_min_epi32(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Sse41])
fn min_u32x4(a: u32x4, b: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_min_epu32(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Sse2])
fn min_u32x4_sse2(a: u32x4, b: u32x4) u32x4 {
    let x = xi(a);
    let y = xi(b);
    let g = _mm_cmpgt_epi32(
        _mm_xor_si128(x, _mm_set1_epi32(-2147483648)),
        _mm_xor_si128(y, _mm_set1_epi32(-2147483648)),
    );
    return xiv::<u32, 4>(_mm_or_si128(_mm_and_si128(g, y), _mm_andnot_si128(g, x)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Sse41])
fn max_u32x4(a: u32x4, b: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_max_epu32(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Sse2])
fn max_u32x4_sse2(a: u32x4, b: u32x4) u32x4 {
    let x = xi(a);
    let y = xi(b);
    let g = _mm_cmpgt_epi32(
        _mm_xor_si128(x, _mm_set1_epi32(-2147483648)),
        _mm_xor_si128(y, _mm_set1_epi32(-2147483648)),
    );
    return xiv::<u32, 4>(_mm_or_si128(_mm_and_si128(g, x), _mm_andnot_si128(g, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Sse41])
fn abs_diff_u32x4(a: u32x4, b: u32x4) u32x4 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u32, 4>(_mm_sub_epi32(_mm_max_epu32(x, y), _mm_min_epu32(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn min_i64x2(a: i64x2, b: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_min_epi64(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Sse42])
fn min_i64x2_sse42(a: i64x2, b: i64x2) i64x2 {
    let x = xi(a);
    let y = xi(b);
    let g = _mm_cmpgt_epi64(x, y);
    return xiv::<i64, 2>(_mm_or_si128(_mm_and_si128(g, y), _mm_andnot_si128(g, x)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn max_i64x2(a: i64x2, b: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_max_epi64(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Sse42])
fn max_i64x2_sse42(a: i64x2, b: i64x2) i64x2 {
    let x = xi(a);
    let y = xi(b);
    let g = _mm_cmpgt_epi64(x, y);
    return xiv::<i64, 2>(_mm_or_si128(_mm_and_si128(g, x), _mm_andnot_si128(g, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn wrapping_abs_i64x2(a: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_abs_epi64(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn abs_diff_i64x2(a: i64x2, b: i64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u64, 2>(_mm_sub_epi64(_mm_max_epi64(x, y), _mm_min_epi64(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn min_u64x2(a: u64x2, b: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_min_epu64(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Sse42])
fn min_u64x2_sse42(a: u64x2, b: u64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    let g = _mm_cmpgt_epi64(
        _mm_xor_si128(x, _mm_set1_epi64x(-9223372036854775807 - 1)),
        _mm_xor_si128(y, _mm_set1_epi64x(-9223372036854775807 - 1)),
    );
    return xiv::<u64, 2>(_mm_or_si128(_mm_and_si128(g, y), _mm_andnot_si128(g, x)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn max_u64x2(a: u64x2, b: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_max_epu64(xi(a), xi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Sse42])
fn max_u64x2_sse42(a: u64x2, b: u64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    let g = _mm_cmpgt_epi64(
        _mm_xor_si128(x, _mm_set1_epi64x(-9223372036854775807 - 1)),
        _mm_xor_si128(y, _mm_set1_epi64x(-9223372036854775807 - 1)),
    );
    return xiv::<u64, 2>(_mm_or_si128(_mm_and_si128(g, x), _mm_andnot_si128(g, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn abs_diff_u64x2(a: u64x2, b: u64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u64, 2>(_mm_sub_epi64(_mm_max_epu64(x, y), _mm_min_epu64(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx2])
fn min_i8x32(a: i8x32, b: i8x32) i8x32 {
    return yiv::<i8, 32>(_mm256_min_epi8(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx2])
fn max_i8x32(a: i8x32, b: i8x32) i8x32 {
    return yiv::<i8, 32>(_mm256_max_epi8(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Avx2])
fn wrapping_abs_i8x32(a: i8x32) i8x32 {
    let x = yi(a);
    return yiv::<i8, 32>(_mm256_sign_epi8(x, x));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingAdd, [cpu::Feature::Avx2])
fn saturating_add_i8x32(a: i8x32, b: i8x32) i8x32 {
    return yiv::<i8, 32>(_mm256_adds_epi8(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingSub, [cpu::Feature::Avx2])
fn saturating_sub_i8x32(a: i8x32, b: i8x32) i8x32 {
    return yiv::<i8, 32>(_mm256_subs_epi8(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx2])
fn abs_diff_i8x32(a: i8x32, b: i8x32) u8x32 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u8, 32>(_mm256_sub_epi8(_mm256_max_epi8(x, y), _mm256_min_epi8(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx2])
fn min_u8x32(a: u8x32, b: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_min_epu8(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx2])
fn max_u8x32(a: u8x32, b: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_max_epu8(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingAdd, [cpu::Feature::Avx2])
fn saturating_add_u8x32(a: u8x32, b: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_adds_epu8(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingSub, [cpu::Feature::Avx2])
fn saturating_sub_u8x32(a: u8x32, b: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_subs_epu8(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx2])
fn abs_diff_u8x32(a: u8x32, b: u8x32) u8x32 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u8, 32>(_mm256_sub_epi8(_mm256_max_epu8(x, y), _mm256_min_epu8(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx2])
fn min_i16x16(a: i16x16, b: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_min_epi16(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx2])
fn max_i16x16(a: i16x16, b: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_max_epi16(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Avx2])
fn wrapping_abs_i16x16(a: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_abs_epi16(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingAdd, [cpu::Feature::Avx2])
fn saturating_add_i16x16(a: i16x16, b: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_adds_epi16(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingSub, [cpu::Feature::Avx2])
fn saturating_sub_i16x16(a: i16x16, b: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_subs_epi16(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx2])
fn abs_diff_i16x16(a: i16x16, b: i16x16) u16x16 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u16, 16>(_mm256_sub_epi16(_mm256_max_epi16(x, y), _mm256_min_epi16(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx2])
fn min_u16x16(a: u16x16, b: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_min_epu16(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx2])
fn max_u16x16(a: u16x16, b: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_max_epu16(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingAdd, [cpu::Feature::Avx2])
fn saturating_add_u16x16(a: u16x16, b: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_adds_epu16(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingSub, [cpu::Feature::Avx2])
fn saturating_sub_u16x16(a: u16x16, b: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_subs_epu16(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx2])
fn abs_diff_u16x16(a: u16x16, b: u16x16) u16x16 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u16, 16>(_mm256_sub_epi16(_mm256_max_epu16(x, y), _mm256_min_epu16(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx2])
fn min_i32x8(a: i32x8, b: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_min_epi32(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx2])
fn max_i32x8(a: i32x8, b: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_max_epi32(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Avx2])
fn wrapping_abs_i32x8(a: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_abs_epi32(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx2])
fn abs_diff_i32x8(a: i32x8, b: i32x8) u32x8 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u32, 8>(_mm256_sub_epi32(_mm256_max_epi32(x, y), _mm256_min_epi32(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx2])
fn min_u32x8(a: u32x8, b: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_min_epu32(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx2])
fn max_u32x8(a: u32x8, b: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_max_epu32(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx2])
fn abs_diff_u32x8(a: u32x8, b: u32x8) u32x8 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u32, 8>(_mm256_sub_epi32(_mm256_max_epu32(x, y), _mm256_min_epu32(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn min_i64x4(a: i64x4, b: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_min_epi64(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx2])
fn min_i64x4_avx2(a: i64x4, b: i64x4) i64x4 {
    let x = yi(a);
    let y = yi(b);
    let g = _mm256_cmpgt_epi64(x, y);
    return yiv::<i64, 4>(_mm256_or_si256(_mm256_and_si256(g, y), _mm256_andnot_si256(g, x)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn max_i64x4(a: i64x4, b: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_max_epi64(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx2])
fn max_i64x4_avx2(a: i64x4, b: i64x4) i64x4 {
    let x = yi(a);
    let y = yi(b);
    let g = _mm256_cmpgt_epi64(x, y);
    return yiv::<i64, 4>(_mm256_or_si256(_mm256_and_si256(g, x), _mm256_andnot_si256(g, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn wrapping_abs_i64x4(a: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_abs_epi64(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn abs_diff_i64x4(a: i64x4, b: i64x4) u64x4 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u64, 4>(_mm256_sub_epi64(_mm256_max_epi64(x, y), _mm256_min_epi64(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn min_u64x4(a: u64x4, b: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_min_epu64(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx2])
fn min_u64x4_avx2(a: u64x4, b: u64x4) u64x4 {
    let x = yi(a);
    let y = yi(b);
    let g = _mm256_cmpgt_epi64(
        _mm256_xor_si256(x, _mm256_set1_epi64x(-9223372036854775807 - 1)),
        _mm256_xor_si256(y, _mm256_set1_epi64x(-9223372036854775807 - 1)),
    );
    return yiv::<u64, 4>(_mm256_or_si256(_mm256_and_si256(g, y), _mm256_andnot_si256(g, x)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn max_u64x4(a: u64x4, b: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_max_epu64(yi(a), yi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx2])
fn max_u64x4_avx2(a: u64x4, b: u64x4) u64x4 {
    let x = yi(a);
    let y = yi(b);
    let g = _mm256_cmpgt_epi64(
        _mm256_xor_si256(x, _mm256_set1_epi64x(-9223372036854775807 - 1)),
        _mm256_xor_si256(y, _mm256_set1_epi64x(-9223372036854775807 - 1)),
    );
    return yiv::<u64, 4>(_mm256_or_si256(_mm256_and_si256(g, x), _mm256_andnot_si256(g, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn abs_diff_u64x4(a: u64x4, b: u64x4) u64x4 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u64, 4>(_mm256_sub_epi64(_mm256_max_epu64(x, y), _mm256_min_epu64(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx512bw])
fn min_i8x64(a: i8x64, b: i8x64) i8x64 {
    return ziv::<i8, 64>(_mm512_min_epi8(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx512bw])
fn max_i8x64(a: i8x64, b: i8x64) i8x64 {
    return ziv::<i8, 64>(_mm512_max_epi8(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Avx512bw])
fn wrapping_abs_i8x64(a: i8x64) i8x64 {
    let x = zi(a);
    return ziv::<i8, 64>(_mm512_min_epu8(x, _mm512_sub_epi8(_mm512_setzero_si512(), x)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingAdd, [cpu::Feature::Avx512bw])
fn saturating_add_i8x64(a: i8x64, b: i8x64) i8x64 {
    return ziv::<i8, 64>(_mm512_adds_epi8(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingSub, [cpu::Feature::Avx512bw])
fn saturating_sub_i8x64(a: i8x64, b: i8x64) i8x64 {
    return ziv::<i8, 64>(_mm512_subs_epi8(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx512bw])
fn abs_diff_i8x64(a: i8x64, b: i8x64) u8x64 {
    let x = zi(a);
    let y = zi(b);
    return ziv::<u8, 64>(_mm512_sub_epi8(_mm512_max_epi8(x, y), _mm512_min_epi8(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx512bw])
fn min_u8x64(a: u8x64, b: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_min_epu8(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx512bw])
fn max_u8x64(a: u8x64, b: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_max_epu8(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingAdd, [cpu::Feature::Avx512bw])
fn saturating_add_u8x64(a: u8x64, b: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_adds_epu8(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingSub, [cpu::Feature::Avx512bw])
fn saturating_sub_u8x64(a: u8x64, b: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_subs_epu8(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx512bw])
fn abs_diff_u8x64(a: u8x64, b: u8x64) u8x64 {
    let x = zi(a);
    let y = zi(b);
    return ziv::<u8, 64>(_mm512_sub_epi8(_mm512_max_epu8(x, y), _mm512_min_epu8(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx512bw])
fn min_i16x32(a: i16x32, b: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_min_epi16(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx512bw])
fn max_i16x32(a: i16x32, b: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_max_epi16(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Avx512bw])
fn wrapping_abs_i16x32(a: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_abs_epi16(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingAdd, [cpu::Feature::Avx512bw])
fn saturating_add_i16x32(a: i16x32, b: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_adds_epi16(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingSub, [cpu::Feature::Avx512bw])
fn saturating_sub_i16x32(a: i16x32, b: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_subs_epi16(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx512bw])
fn abs_diff_i16x32(a: i16x32, b: i16x32) u16x32 {
    let x = zi(a);
    let y = zi(b);
    return ziv::<u16, 32>(_mm512_sub_epi16(_mm512_max_epi16(x, y), _mm512_min_epi16(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx512bw])
fn min_u16x32(a: u16x32, b: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_min_epu16(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx512bw])
fn max_u16x32(a: u16x32, b: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_max_epu16(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingAdd, [cpu::Feature::Avx512bw])
fn saturating_add_u16x32(a: u16x32, b: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_adds_epu16(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::SaturatingSub, [cpu::Feature::Avx512bw])
fn saturating_sub_u16x32(a: u16x32, b: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_subs_epu16(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx512bw])
fn abs_diff_u16x32(a: u16x32, b: u16x32) u16x32 {
    let x = zi(a);
    let y = zi(b);
    return ziv::<u16, 32>(_mm512_sub_epi16(_mm512_max_epu16(x, y), _mm512_min_epu16(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx512f])
fn min_i32x16(a: i32x16, b: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_min_epi32(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx512f])
fn max_i32x16(a: i32x16, b: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_max_epi32(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Avx512f])
fn wrapping_abs_i32x16(a: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_abs_epi32(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx512f])
fn abs_diff_i32x16(a: i32x16, b: i32x16) u32x16 {
    let x = zi(a);
    let y = zi(b);
    return ziv::<u32, 16>(_mm512_sub_epi32(_mm512_max_epi32(x, y), _mm512_min_epi32(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx512f])
fn min_u32x16(a: u32x16, b: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_min_epu32(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx512f])
fn max_u32x16(a: u32x16, b: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_max_epu32(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx512f])
fn abs_diff_u32x16(a: u32x16, b: u32x16) u32x16 {
    let x = zi(a);
    let y = zi(b);
    return ziv::<u32, 16>(_mm512_sub_epi32(_mm512_max_epu32(x, y), _mm512_min_epu32(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx512f])
fn min_i64x8(a: i64x8, b: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_min_epi64(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx512f])
fn max_i64x8(a: i64x8, b: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_max_epi64(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Avx512f])
fn wrapping_abs_i64x8(a: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_abs_epi64(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx512f])
fn abs_diff_i64x8(a: i64x8, b: i64x8) u64x8 {
    let x = zi(a);
    let y = zi(b);
    return ziv::<u64, 8>(_mm512_sub_epi64(_mm512_max_epi64(x, y), _mm512_min_epi64(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx512f])
fn min_u64x8(a: u64x8, b: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_min_epu64(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx512f])
fn max_u64x8(a: u64x8, b: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_max_epu64(zi(a), zi(b)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx512f])
fn abs_diff_u64x8(a: u64x8, b: u64x8) u64x8 {
    let x = zi(a);
    let y = zi(b);
    return ziv::<u64, 8>(_mm512_sub_epi64(_mm512_max_epu64(x, y), _mm512_min_epu64(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Sse2])
fn cmp_eq_lanes_i8x16(a: i8x16, b: i8x16) u8x16 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u8, 16>(_mm_cmpeq_epi8(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Sse2])
fn cmp_ne_lanes_i8x16(a: i8x16, b: i8x16) u8x16 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u8, 16>(_mm_xor_si128(_mm_cmpeq_epi8(x, y), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Sse2])
fn cmp_lt_lanes_i8x16(a: i8x16, b: i8x16) u8x16 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u8, 16>(_mm_cmpgt_epi8(y, x));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Sse2])
fn cmp_le_lanes_i8x16(a: i8x16, b: i8x16) u8x16 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u8, 16>(_mm_xor_si128(_mm_cmpgt_epi8(x, y), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Sse2])
fn cmp_gt_lanes_i8x16(a: i8x16, b: i8x16) u8x16 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u8, 16>(_mm_cmpgt_epi8(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Sse2])
fn cmp_ge_lanes_i8x16(a: i8x16, b: i8x16) u8x16 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u8, 16>(_mm_xor_si128(_mm_cmpgt_epi8(y, x), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse41])
fn choose_lanes_i8x16(m: u8x16, a: i8x16, b: i8x16) i8x16 {
    return xiv::<i8, 16>(_mm_blendv_epi8(xi(b), xi(a), xi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse2])
fn choose_lanes_i8x16_sse2(m: u8x16, a: i8x16, b: i8x16) i8x16 {
    let k = xi(m);
    return xiv::<i8, 16>(_mm_or_si128(_mm_and_si128(k, xi(a)), _mm_andnot_si128(k, xi(b))));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_eq_i8x16(a: i8x16, b: i8x16) mask16 {
    return ((unsafe _mm_cmp_epi8_mask(xi(a), xi(b), 0)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_ne_i8x16(a: i8x16, b: i8x16) mask16 {
    return ((unsafe _mm_cmp_epi8_mask(xi(a), xi(b), 4)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_lt_i8x16(a: i8x16, b: i8x16) mask16 {
    return ((unsafe _mm_cmp_epi8_mask(xi(a), xi(b), 1)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_le_i8x16(a: i8x16, b: i8x16) mask16 {
    return ((unsafe _mm_cmp_epi8_mask(xi(a), xi(b), 2)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_gt_i8x16(a: i8x16, b: i8x16) mask16 {
    return ((unsafe _mm_cmp_epi8_mask(xi(a), xi(b), 6)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_ge_i8x16(a: i8x16, b: i8x16) mask16 {
    return ((unsafe _mm_cmp_epi8_mask(xi(a), xi(b), 5)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn choose_i8x16(m: mask16, a: i8x16, b: i8x16) i8x16 {
    return xiv::<i8, 16>(_mm_mask_blend_epi8((m as u64) as u16, xi(b), xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Sse2])
fn cmp_eq_lanes_u8x16(a: u8x16, b: u8x16) u8x16 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u8, 16>(_mm_cmpeq_epi8(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Sse2])
fn cmp_ne_lanes_u8x16(a: u8x16, b: u8x16) u8x16 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u8, 16>(_mm_xor_si128(_mm_cmpeq_epi8(x, y), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Sse2])
fn cmp_lt_lanes_u8x16(a: u8x16, b: u8x16) u8x16 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u8, 16>(_mm_cmpgt_epi8(_mm_xor_si128(y, _mm_set1_epi8(-128)), _mm_xor_si128(x, _mm_set1_epi8(-128))));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Sse2])
fn cmp_le_lanes_u8x16(a: u8x16, b: u8x16) u8x16 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u8, 16>(
        _mm_xor_si128(
            _mm_cmpgt_epi8(_mm_xor_si128(x, _mm_set1_epi8(-128)), _mm_xor_si128(y, _mm_set1_epi8(-128))),
            _mm_set1_epi32(-1),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Sse2])
fn cmp_gt_lanes_u8x16(a: u8x16, b: u8x16) u8x16 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u8, 16>(_mm_cmpgt_epi8(_mm_xor_si128(x, _mm_set1_epi8(-128)), _mm_xor_si128(y, _mm_set1_epi8(-128))));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Sse2])
fn cmp_ge_lanes_u8x16(a: u8x16, b: u8x16) u8x16 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u8, 16>(
        _mm_xor_si128(
            _mm_cmpgt_epi8(_mm_xor_si128(y, _mm_set1_epi8(-128)), _mm_xor_si128(x, _mm_set1_epi8(-128))),
            _mm_set1_epi32(-1),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse41])
fn choose_lanes_u8x16(m: u8x16, a: u8x16, b: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_blendv_epi8(xi(b), xi(a), xi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse2])
fn choose_lanes_u8x16_sse2(m: u8x16, a: u8x16, b: u8x16) u8x16 {
    let k = xi(m);
    return xiv::<u8, 16>(_mm_or_si128(_mm_and_si128(k, xi(a)), _mm_andnot_si128(k, xi(b))));
}

@arch(x86_64)
@simd_impl(simd::Op::LanesToMask, [cpu::Feature::Sse2])
fn lanes_to_mask_u8x16(m: u8x16) mask16 {
    return (_mm_movemask_epi8(xi(m)) as u64 & 65535) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::AnyLanes, [cpu::Feature::Sse2])
fn any_lanes_u8x16(m: u8x16) bool {
    return _mm_movemask_epi8(xi(m)) != 0;
}

@arch(x86_64)
@simd_impl(simd::Op::AllLanes, [cpu::Feature::Sse2])
fn all_lanes_u8x16(m: u8x16) bool {
    return _mm_movemask_epi8(xi(m)) == 65535;
}

@arch(x86_64)
@simd_impl(simd::Op::MaskToLanes, [cpu::Feature::Ssse3])
fn mask_to_lanes_u8x16(m: mask16) u8x16 {
    let b = _mm_set1_epi64x(-9205322385119247871);
    return xiv::<u8, 16>(
        _mm_cmpeq_epi8(
            _mm_and_si128(
                _mm_shuffle_epi8(
                    _mm_set1_epi16((m as u64) as i16),
                    _mm_setr_epi8(0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1),
                ),
                b,
            ),
            b,
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_eq_u8x16(a: u8x16, b: u8x16) mask16 {
    return ((unsafe _mm_cmp_epu8_mask(xi(a), xi(b), 0)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_ne_u8x16(a: u8x16, b: u8x16) mask16 {
    return ((unsafe _mm_cmp_epu8_mask(xi(a), xi(b), 4)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_lt_u8x16(a: u8x16, b: u8x16) mask16 {
    return ((unsafe _mm_cmp_epu8_mask(xi(a), xi(b), 1)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_le_u8x16(a: u8x16, b: u8x16) mask16 {
    return ((unsafe _mm_cmp_epu8_mask(xi(a), xi(b), 2)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_gt_u8x16(a: u8x16, b: u8x16) mask16 {
    return ((unsafe _mm_cmp_epu8_mask(xi(a), xi(b), 6)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_ge_u8x16(a: u8x16, b: u8x16) mask16 {
    return ((unsafe _mm_cmp_epu8_mask(xi(a), xi(b), 5)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn choose_u8x16(m: mask16, a: u8x16, b: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_mask_blend_epi8((m as u64) as u16, xi(b), xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Sse2])
fn cmp_eq_lanes_i16x8(a: i16x8, b: i16x8) u16x8 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u16, 8>(_mm_cmpeq_epi16(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Sse2])
fn cmp_ne_lanes_i16x8(a: i16x8, b: i16x8) u16x8 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u16, 8>(_mm_xor_si128(_mm_cmpeq_epi16(x, y), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Sse2])
fn cmp_lt_lanes_i16x8(a: i16x8, b: i16x8) u16x8 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u16, 8>(_mm_cmpgt_epi16(y, x));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Sse2])
fn cmp_le_lanes_i16x8(a: i16x8, b: i16x8) u16x8 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u16, 8>(_mm_xor_si128(_mm_cmpgt_epi16(x, y), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Sse2])
fn cmp_gt_lanes_i16x8(a: i16x8, b: i16x8) u16x8 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u16, 8>(_mm_cmpgt_epi16(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Sse2])
fn cmp_ge_lanes_i16x8(a: i16x8, b: i16x8) u16x8 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u16, 8>(_mm_xor_si128(_mm_cmpgt_epi16(y, x), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse41])
fn choose_lanes_i16x8(m: u16x8, a: i16x8, b: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_blendv_epi8(xi(b), xi(a), xi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse2])
fn choose_lanes_i16x8_sse2(m: u16x8, a: i16x8, b: i16x8) i16x8 {
    let k = xi(m);
    return xiv::<i16, 8>(_mm_or_si128(_mm_and_si128(k, xi(a)), _mm_andnot_si128(k, xi(b))));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_eq_i16x8(a: i16x8, b: i16x8) mask8 {
    return ((unsafe _mm_cmp_epi16_mask(xi(a), xi(b), 0)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_ne_i16x8(a: i16x8, b: i16x8) mask8 {
    return ((unsafe _mm_cmp_epi16_mask(xi(a), xi(b), 4)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_lt_i16x8(a: i16x8, b: i16x8) mask8 {
    return ((unsafe _mm_cmp_epi16_mask(xi(a), xi(b), 1)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_le_i16x8(a: i16x8, b: i16x8) mask8 {
    return ((unsafe _mm_cmp_epi16_mask(xi(a), xi(b), 2)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_gt_i16x8(a: i16x8, b: i16x8) mask8 {
    return ((unsafe _mm_cmp_epi16_mask(xi(a), xi(b), 6)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_ge_i16x8(a: i16x8, b: i16x8) mask8 {
    return ((unsafe _mm_cmp_epi16_mask(xi(a), xi(b), 5)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn choose_i16x8(m: mask8, a: i16x8, b: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_mask_blend_epi16((m as u64) as u8, xi(b), xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Sse2])
fn cmp_eq_lanes_u16x8(a: u16x8, b: u16x8) u16x8 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u16, 8>(_mm_cmpeq_epi16(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Sse2])
fn cmp_ne_lanes_u16x8(a: u16x8, b: u16x8) u16x8 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u16, 8>(_mm_xor_si128(_mm_cmpeq_epi16(x, y), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Sse2])
fn cmp_lt_lanes_u16x8(a: u16x8, b: u16x8) u16x8 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u16, 8>(
        _mm_cmpgt_epi16(_mm_xor_si128(y, _mm_set1_epi16(-32768)), _mm_xor_si128(x, _mm_set1_epi16(-32768))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Sse2])
fn cmp_le_lanes_u16x8(a: u16x8, b: u16x8) u16x8 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u16, 8>(
        _mm_xor_si128(
            _mm_cmpgt_epi16(_mm_xor_si128(x, _mm_set1_epi16(-32768)), _mm_xor_si128(y, _mm_set1_epi16(-32768))),
            _mm_set1_epi32(-1),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Sse2])
fn cmp_gt_lanes_u16x8(a: u16x8, b: u16x8) u16x8 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u16, 8>(
        _mm_cmpgt_epi16(_mm_xor_si128(x, _mm_set1_epi16(-32768)), _mm_xor_si128(y, _mm_set1_epi16(-32768))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Sse2])
fn cmp_ge_lanes_u16x8(a: u16x8, b: u16x8) u16x8 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u16, 8>(
        _mm_xor_si128(
            _mm_cmpgt_epi16(_mm_xor_si128(y, _mm_set1_epi16(-32768)), _mm_xor_si128(x, _mm_set1_epi16(-32768))),
            _mm_set1_epi32(-1),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse41])
fn choose_lanes_u16x8(m: u16x8, a: u16x8, b: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_blendv_epi8(xi(b), xi(a), xi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse2])
fn choose_lanes_u16x8_sse2(m: u16x8, a: u16x8, b: u16x8) u16x8 {
    let k = xi(m);
    return xiv::<u16, 8>(_mm_or_si128(_mm_and_si128(k, xi(a)), _mm_andnot_si128(k, xi(b))));
}

@arch(x86_64)
@simd_impl(simd::Op::LanesToMask, [cpu::Feature::Sse2])
fn lanes_to_mask_u16x8(m: u16x8) mask8 {
    return (_mm_movemask_epi8(_mm_packs_epi16(xi(m), _mm_setzero_si128())) as u64 & 255) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::AnyLanes, [cpu::Feature::Sse2])
fn any_lanes_u16x8(m: u16x8) bool {
    return _mm_movemask_epi8(xi(m)) != 0;
}

@arch(x86_64)
@simd_impl(simd::Op::AllLanes, [cpu::Feature::Sse2])
fn all_lanes_u16x8(m: u16x8) bool {
    return _mm_movemask_epi8(xi(m)) == 65535;
}

@arch(x86_64)
@simd_impl(simd::Op::MaskToLanes, [cpu::Feature::Sse2])
fn mask_to_lanes_u16x8(m: mask8) u16x8 {
    let b = _mm_setr_epi16(1, 2, 4, 8, 16, 32, 64, 128);
    return xiv::<u16, 8>(_mm_cmpeq_epi16(_mm_and_si128(_mm_set1_epi16((m as u64) as i16), b), b));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_eq_u16x8(a: u16x8, b: u16x8) mask8 {
    return ((unsafe _mm_cmp_epu16_mask(xi(a), xi(b), 0)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_ne_u16x8(a: u16x8, b: u16x8) mask8 {
    return ((unsafe _mm_cmp_epu16_mask(xi(a), xi(b), 4)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_lt_u16x8(a: u16x8, b: u16x8) mask8 {
    return ((unsafe _mm_cmp_epu16_mask(xi(a), xi(b), 1)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_le_u16x8(a: u16x8, b: u16x8) mask8 {
    return ((unsafe _mm_cmp_epu16_mask(xi(a), xi(b), 2)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_gt_u16x8(a: u16x8, b: u16x8) mask8 {
    return ((unsafe _mm_cmp_epu16_mask(xi(a), xi(b), 6)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_ge_u16x8(a: u16x8, b: u16x8) mask8 {
    return ((unsafe _mm_cmp_epu16_mask(xi(a), xi(b), 5)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn choose_u16x8(m: mask8, a: u16x8, b: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_mask_blend_epi16((m as u64) as u8, xi(b), xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Sse2])
fn cmp_eq_lanes_i32x4(a: i32x4, b: i32x4) u32x4 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u32, 4>(_mm_cmpeq_epi32(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Sse2])
fn cmp_ne_lanes_i32x4(a: i32x4, b: i32x4) u32x4 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u32, 4>(_mm_xor_si128(_mm_cmpeq_epi32(x, y), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Sse2])
fn cmp_lt_lanes_i32x4(a: i32x4, b: i32x4) u32x4 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u32, 4>(_mm_cmpgt_epi32(y, x));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Sse2])
fn cmp_le_lanes_i32x4(a: i32x4, b: i32x4) u32x4 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u32, 4>(_mm_xor_si128(_mm_cmpgt_epi32(x, y), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Sse2])
fn cmp_gt_lanes_i32x4(a: i32x4, b: i32x4) u32x4 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u32, 4>(_mm_cmpgt_epi32(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Sse2])
fn cmp_ge_lanes_i32x4(a: i32x4, b: i32x4) u32x4 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u32, 4>(_mm_xor_si128(_mm_cmpgt_epi32(y, x), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse41])
fn choose_lanes_i32x4(m: u32x4, a: i32x4, b: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_blendv_epi8(xi(b), xi(a), xi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse2])
fn choose_lanes_i32x4_sse2(m: u32x4, a: i32x4, b: i32x4) i32x4 {
    let k = xi(m);
    return xiv::<i32, 4>(_mm_or_si128(_mm_and_si128(k, xi(a)), _mm_andnot_si128(k, xi(b))));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_eq_i32x4(a: i32x4, b: i32x4) mask4 {
    return ((unsafe _mm_cmp_epi32_mask(xi(a), xi(b), 0)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ne_i32x4(a: i32x4, b: i32x4) mask4 {
    return ((unsafe _mm_cmp_epi32_mask(xi(a), xi(b), 4)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_lt_i32x4(a: i32x4, b: i32x4) mask4 {
    return ((unsafe _mm_cmp_epi32_mask(xi(a), xi(b), 1)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_le_i32x4(a: i32x4, b: i32x4) mask4 {
    return ((unsafe _mm_cmp_epi32_mask(xi(a), xi(b), 2)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_gt_i32x4(a: i32x4, b: i32x4) mask4 {
    return ((unsafe _mm_cmp_epi32_mask(xi(a), xi(b), 6)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ge_i32x4(a: i32x4, b: i32x4) mask4 {
    return ((unsafe _mm_cmp_epi32_mask(xi(a), xi(b), 5)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn choose_i32x4(m: mask4, a: i32x4, b: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_mask_blend_epi32((m as u64) as u8, xi(b), xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Sse2])
fn cmp_eq_lanes_u32x4(a: u32x4, b: u32x4) u32x4 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u32, 4>(_mm_cmpeq_epi32(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Sse2])
fn cmp_ne_lanes_u32x4(a: u32x4, b: u32x4) u32x4 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u32, 4>(_mm_xor_si128(_mm_cmpeq_epi32(x, y), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Sse2])
fn cmp_lt_lanes_u32x4(a: u32x4, b: u32x4) u32x4 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u32, 4>(
        _mm_cmpgt_epi32(_mm_xor_si128(y, _mm_set1_epi32(-2147483648)), _mm_xor_si128(x, _mm_set1_epi32(-2147483648))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Sse2])
fn cmp_le_lanes_u32x4(a: u32x4, b: u32x4) u32x4 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u32, 4>(
        _mm_xor_si128(
            _mm_cmpgt_epi32(
                _mm_xor_si128(x, _mm_set1_epi32(-2147483648)),
                _mm_xor_si128(y, _mm_set1_epi32(-2147483648)),
            ),
            _mm_set1_epi32(-1),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Sse2])
fn cmp_gt_lanes_u32x4(a: u32x4, b: u32x4) u32x4 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u32, 4>(
        _mm_cmpgt_epi32(_mm_xor_si128(x, _mm_set1_epi32(-2147483648)), _mm_xor_si128(y, _mm_set1_epi32(-2147483648))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Sse2])
fn cmp_ge_lanes_u32x4(a: u32x4, b: u32x4) u32x4 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u32, 4>(
        _mm_xor_si128(
            _mm_cmpgt_epi32(
                _mm_xor_si128(y, _mm_set1_epi32(-2147483648)),
                _mm_xor_si128(x, _mm_set1_epi32(-2147483648)),
            ),
            _mm_set1_epi32(-1),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse41])
fn choose_lanes_u32x4(m: u32x4, a: u32x4, b: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_blendv_epi8(xi(b), xi(a), xi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse2])
fn choose_lanes_u32x4_sse2(m: u32x4, a: u32x4, b: u32x4) u32x4 {
    let k = xi(m);
    return xiv::<u32, 4>(_mm_or_si128(_mm_and_si128(k, xi(a)), _mm_andnot_si128(k, xi(b))));
}

@arch(x86_64)
@simd_impl(simd::Op::LanesToMask, [cpu::Feature::Sse2])
fn lanes_to_mask_u32x4(m: u32x4) mask4 {
    return (_mm_movemask_ps(_mm_castsi128_ps(xi(m))) as u64 & 15) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::AnyLanes, [cpu::Feature::Sse2])
fn any_lanes_u32x4(m: u32x4) bool {
    return _mm_movemask_epi8(xi(m)) != 0;
}

@arch(x86_64)
@simd_impl(simd::Op::AllLanes, [cpu::Feature::Sse2])
fn all_lanes_u32x4(m: u32x4) bool {
    return _mm_movemask_epi8(xi(m)) == 65535;
}

@arch(x86_64)
@simd_impl(simd::Op::MaskToLanes, [cpu::Feature::Sse2])
fn mask_to_lanes_u32x4(m: mask4) u32x4 {
    let b = _mm_setr_epi32(1, 2, 4, 8);
    return xiv::<u32, 4>(_mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64) as i32), b), b));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_eq_u32x4(a: u32x4, b: u32x4) mask4 {
    return ((unsafe _mm_cmp_epu32_mask(xi(a), xi(b), 0)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ne_u32x4(a: u32x4, b: u32x4) mask4 {
    return ((unsafe _mm_cmp_epu32_mask(xi(a), xi(b), 4)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_lt_u32x4(a: u32x4, b: u32x4) mask4 {
    return ((unsafe _mm_cmp_epu32_mask(xi(a), xi(b), 1)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_le_u32x4(a: u32x4, b: u32x4) mask4 {
    return ((unsafe _mm_cmp_epu32_mask(xi(a), xi(b), 2)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_gt_u32x4(a: u32x4, b: u32x4) mask4 {
    return ((unsafe _mm_cmp_epu32_mask(xi(a), xi(b), 6)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ge_u32x4(a: u32x4, b: u32x4) mask4 {
    return ((unsafe _mm_cmp_epu32_mask(xi(a), xi(b), 5)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn choose_u32x4(m: mask4, a: u32x4, b: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_mask_blend_epi32((m as u64) as u8, xi(b), xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Sse41])
fn cmp_eq_lanes_i64x2(a: i64x2, b: i64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u64, 2>(_mm_cmpeq_epi64(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Sse41])
fn cmp_ne_lanes_i64x2(a: i64x2, b: i64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u64, 2>(_mm_xor_si128(_mm_cmpeq_epi64(x, y), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Sse42])
fn cmp_lt_lanes_i64x2(a: i64x2, b: i64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u64, 2>(_mm_cmpgt_epi64(y, x));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Sse42])
fn cmp_le_lanes_i64x2(a: i64x2, b: i64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u64, 2>(_mm_xor_si128(_mm_cmpgt_epi64(x, y), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Sse42])
fn cmp_gt_lanes_i64x2(a: i64x2, b: i64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u64, 2>(_mm_cmpgt_epi64(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Sse42])
fn cmp_ge_lanes_i64x2(a: i64x2, b: i64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u64, 2>(_mm_xor_si128(_mm_cmpgt_epi64(y, x), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse41])
fn choose_lanes_i64x2(m: u64x2, a: i64x2, b: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_blendv_epi8(xi(b), xi(a), xi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse2])
fn choose_lanes_i64x2_sse2(m: u64x2, a: i64x2, b: i64x2) i64x2 {
    let k = xi(m);
    return xiv::<i64, 2>(_mm_or_si128(_mm_and_si128(k, xi(a)), _mm_andnot_si128(k, xi(b))));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_eq_i64x2(a: i64x2, b: i64x2) mask2 {
    return ((unsafe _mm_cmp_epi64_mask(xi(a), xi(b), 0)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ne_i64x2(a: i64x2, b: i64x2) mask2 {
    return ((unsafe _mm_cmp_epi64_mask(xi(a), xi(b), 4)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_lt_i64x2(a: i64x2, b: i64x2) mask2 {
    return ((unsafe _mm_cmp_epi64_mask(xi(a), xi(b), 1)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_le_i64x2(a: i64x2, b: i64x2) mask2 {
    return ((unsafe _mm_cmp_epi64_mask(xi(a), xi(b), 2)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_gt_i64x2(a: i64x2, b: i64x2) mask2 {
    return ((unsafe _mm_cmp_epi64_mask(xi(a), xi(b), 6)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ge_i64x2(a: i64x2, b: i64x2) mask2 {
    return ((unsafe _mm_cmp_epi64_mask(xi(a), xi(b), 5)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn choose_i64x2(m: mask2, a: i64x2, b: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_mask_blend_epi64((m as u64) as u8, xi(b), xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Sse41])
fn cmp_eq_lanes_u64x2(a: u64x2, b: u64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u64, 2>(_mm_cmpeq_epi64(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Sse41])
fn cmp_ne_lanes_u64x2(a: u64x2, b: u64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u64, 2>(_mm_xor_si128(_mm_cmpeq_epi64(x, y), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Sse42])
fn cmp_lt_lanes_u64x2(a: u64x2, b: u64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u64, 2>(
        _mm_cmpgt_epi64(
            _mm_xor_si128(y, _mm_set1_epi64x(-9223372036854775807 - 1)),
            _mm_xor_si128(x, _mm_set1_epi64x(-9223372036854775807 - 1)),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Sse42])
fn cmp_le_lanes_u64x2(a: u64x2, b: u64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u64, 2>(
        _mm_xor_si128(
            _mm_cmpgt_epi64(
                _mm_xor_si128(x, _mm_set1_epi64x(-9223372036854775807 - 1)),
                _mm_xor_si128(y, _mm_set1_epi64x(-9223372036854775807 - 1)),
            ),
            _mm_set1_epi32(-1),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Sse42])
fn cmp_gt_lanes_u64x2(a: u64x2, b: u64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u64, 2>(
        _mm_cmpgt_epi64(
            _mm_xor_si128(x, _mm_set1_epi64x(-9223372036854775807 - 1)),
            _mm_xor_si128(y, _mm_set1_epi64x(-9223372036854775807 - 1)),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Sse42])
fn cmp_ge_lanes_u64x2(a: u64x2, b: u64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    return xiv::<u64, 2>(
        _mm_xor_si128(
            _mm_cmpgt_epi64(
                _mm_xor_si128(y, _mm_set1_epi64x(-9223372036854775807 - 1)),
                _mm_xor_si128(x, _mm_set1_epi64x(-9223372036854775807 - 1)),
            ),
            _mm_set1_epi32(-1),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse41])
fn choose_lanes_u64x2(m: u64x2, a: u64x2, b: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_blendv_epi8(xi(b), xi(a), xi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse2])
fn choose_lanes_u64x2_sse2(m: u64x2, a: u64x2, b: u64x2) u64x2 {
    let k = xi(m);
    return xiv::<u64, 2>(_mm_or_si128(_mm_and_si128(k, xi(a)), _mm_andnot_si128(k, xi(b))));
}

@arch(x86_64)
@simd_impl(simd::Op::LanesToMask, [cpu::Feature::Sse2])
fn lanes_to_mask_u64x2(m: u64x2) mask2 {
    return (_mm_movemask_pd(_mm_castsi128_pd(xi(m))) as u64 & 3) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::AnyLanes, [cpu::Feature::Sse2])
fn any_lanes_u64x2(m: u64x2) bool {
    return _mm_movemask_epi8(xi(m)) != 0;
}

@arch(x86_64)
@simd_impl(simd::Op::AllLanes, [cpu::Feature::Sse2])
fn all_lanes_u64x2(m: u64x2) bool {
    return _mm_movemask_epi8(xi(m)) == 65535;
}

@arch(x86_64)
@simd_impl(simd::Op::MaskToLanes, [cpu::Feature::Sse41])
fn mask_to_lanes_u64x2(m: mask2) u64x2 {
    let b = _mm_set_epi64x(2, 1);
    return xiv::<u64, 2>(_mm_cmpeq_epi64(_mm_and_si128(_mm_set1_epi64x((m as u64) as i64), b), b));
}

@arch(x86_64)
@simd_impl(simd::Op::MaskToLanes, [cpu::Feature::Sse2])
fn mask_to_lanes_u64x2_sse2(m: mask2) u64x2 {
    let b = _mm_set_epi32(0, 2, 0, 1);
    return xiv::<u64, 2>(
        _mm_shuffle_epi32(_mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64) as i32), b), b), 160),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_eq_u64x2(a: u64x2, b: u64x2) mask2 {
    return ((unsafe _mm_cmp_epu64_mask(xi(a), xi(b), 0)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ne_u64x2(a: u64x2, b: u64x2) mask2 {
    return ((unsafe _mm_cmp_epu64_mask(xi(a), xi(b), 4)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_lt_u64x2(a: u64x2, b: u64x2) mask2 {
    return ((unsafe _mm_cmp_epu64_mask(xi(a), xi(b), 1)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_le_u64x2(a: u64x2, b: u64x2) mask2 {
    return ((unsafe _mm_cmp_epu64_mask(xi(a), xi(b), 2)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_gt_u64x2(a: u64x2, b: u64x2) mask2 {
    return ((unsafe _mm_cmp_epu64_mask(xi(a), xi(b), 6)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ge_u64x2(a: u64x2, b: u64x2) mask2 {
    return ((unsafe _mm_cmp_epu64_mask(xi(a), xi(b), 5)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn choose_u64x2(m: mask2, a: u64x2, b: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_mask_blend_epi64((m as u64) as u8, xi(b), xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Sse2])
fn cmp_eq_lanes_f32x4(a: f32x4, b: f32x4) u32x4 {
    let x = xf(a);
    let y = xf(b);
    return xiv::<u32, 4>(_mm_castps_si128(_mm_cmpeq_ps(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Sse2])
fn cmp_ne_lanes_f32x4(a: f32x4, b: f32x4) u32x4 {
    let x = xf(a);
    let y = xf(b);
    return xiv::<u32, 4>(_mm_castps_si128(_mm_cmpneq_ps(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Sse2])
fn cmp_lt_lanes_f32x4(a: f32x4, b: f32x4) u32x4 {
    let x = xf(a);
    let y = xf(b);
    return xiv::<u32, 4>(_mm_castps_si128(_mm_cmplt_ps(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Sse2])
fn cmp_le_lanes_f32x4(a: f32x4, b: f32x4) u32x4 {
    let x = xf(a);
    let y = xf(b);
    return xiv::<u32, 4>(_mm_castps_si128(_mm_cmple_ps(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Sse2])
fn cmp_gt_lanes_f32x4(a: f32x4, b: f32x4) u32x4 {
    let x = xf(a);
    let y = xf(b);
    return xiv::<u32, 4>(_mm_castps_si128(_mm_cmplt_ps(y, x)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Sse2])
fn cmp_ge_lanes_f32x4(a: f32x4, b: f32x4) u32x4 {
    let x = xf(a);
    let y = xf(b);
    return xiv::<u32, 4>(_mm_castps_si128(_mm_cmple_ps(y, x)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse41])
fn choose_lanes_f32x4(m: u32x4, a: f32x4, b: f32x4) f32x4 {
    return xfv::<f32, 4>(_mm_castsi128_ps(_mm_blendv_epi8(_mm_castps_si128(xf(b)), _mm_castps_si128(xf(a)), xi(m))));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse2])
fn choose_lanes_f32x4_sse2(m: u32x4, a: f32x4, b: f32x4) f32x4 {
    let k = xi(m);
    return xiv::<f32, 4>(_mm_or_si128(_mm_and_si128(k, xi(a)), _mm_andnot_si128(k, xi(b))));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_eq_f32x4(a: f32x4, b: f32x4) mask4 {
    return ((unsafe _mm_cmp_ps_mask(xf(a), xf(b), 0)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ne_f32x4(a: f32x4, b: f32x4) mask4 {
    return ((unsafe _mm_cmp_ps_mask(xf(a), xf(b), 4)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_lt_f32x4(a: f32x4, b: f32x4) mask4 {
    return ((unsafe _mm_cmp_ps_mask(xf(a), xf(b), 17)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_le_f32x4(a: f32x4, b: f32x4) mask4 {
    return ((unsafe _mm_cmp_ps_mask(xf(a), xf(b), 18)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_gt_f32x4(a: f32x4, b: f32x4) mask4 {
    return ((unsafe _mm_cmp_ps_mask(xf(a), xf(b), 30)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ge_f32x4(a: f32x4, b: f32x4) mask4 {
    return ((unsafe _mm_cmp_ps_mask(xf(a), xf(b), 29)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn choose_f32x4(m: mask4, a: f32x4, b: f32x4) f32x4 {
    return xfv::<f32, 4>(_mm_mask_blend_ps((m as u64) as u8, xf(b), xf(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Sse2])
fn cmp_eq_lanes_f64x2(a: f64x2, b: f64x2) u64x2 {
    let x = xd(a);
    let y = xd(b);
    return xiv::<u64, 2>(_mm_castpd_si128(_mm_cmpeq_pd(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Sse2])
fn cmp_ne_lanes_f64x2(a: f64x2, b: f64x2) u64x2 {
    let x = xd(a);
    let y = xd(b);
    return xiv::<u64, 2>(_mm_castpd_si128(_mm_cmpneq_pd(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Sse2])
fn cmp_lt_lanes_f64x2(a: f64x2, b: f64x2) u64x2 {
    let x = xd(a);
    let y = xd(b);
    return xiv::<u64, 2>(_mm_castpd_si128(_mm_cmplt_pd(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Sse2])
fn cmp_le_lanes_f64x2(a: f64x2, b: f64x2) u64x2 {
    let x = xd(a);
    let y = xd(b);
    return xiv::<u64, 2>(_mm_castpd_si128(_mm_cmple_pd(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Sse2])
fn cmp_gt_lanes_f64x2(a: f64x2, b: f64x2) u64x2 {
    let x = xd(a);
    let y = xd(b);
    return xiv::<u64, 2>(_mm_castpd_si128(_mm_cmplt_pd(y, x)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Sse2])
fn cmp_ge_lanes_f64x2(a: f64x2, b: f64x2) u64x2 {
    let x = xd(a);
    let y = xd(b);
    return xiv::<u64, 2>(_mm_castpd_si128(_mm_cmple_pd(y, x)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse41])
fn choose_lanes_f64x2(m: u64x2, a: f64x2, b: f64x2) f64x2 {
    return xdv::<f64, 2>(_mm_castsi128_pd(_mm_blendv_epi8(_mm_castpd_si128(xd(b)), _mm_castpd_si128(xd(a)), xi(m))));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Sse2])
fn choose_lanes_f64x2_sse2(m: u64x2, a: f64x2, b: f64x2) f64x2 {
    let k = xi(m);
    return xiv::<f64, 2>(_mm_or_si128(_mm_and_si128(k, xi(a)), _mm_andnot_si128(k, xi(b))));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_eq_f64x2(a: f64x2, b: f64x2) mask2 {
    return ((unsafe _mm_cmp_pd_mask(xd(a), xd(b), 0)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ne_f64x2(a: f64x2, b: f64x2) mask2 {
    return ((unsafe _mm_cmp_pd_mask(xd(a), xd(b), 4)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_lt_f64x2(a: f64x2, b: f64x2) mask2 {
    return ((unsafe _mm_cmp_pd_mask(xd(a), xd(b), 17)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_le_f64x2(a: f64x2, b: f64x2) mask2 {
    return ((unsafe _mm_cmp_pd_mask(xd(a), xd(b), 18)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_gt_f64x2(a: f64x2, b: f64x2) mask2 {
    return ((unsafe _mm_cmp_pd_mask(xd(a), xd(b), 30)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ge_f64x2(a: f64x2, b: f64x2) mask2 {
    return ((unsafe _mm_cmp_pd_mask(xd(a), xd(b), 29)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn choose_f64x2(m: mask2, a: f64x2, b: f64x2) f64x2 {
    return xdv::<f64, 2>(_mm_mask_blend_pd((m as u64) as u8, xd(b), xd(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Avx2])
fn cmp_eq_lanes_i8x32(a: i8x32, b: i8x32) u8x32 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u8, 32>(_mm256_cmpeq_epi8(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Avx2])
fn cmp_ne_lanes_i8x32(a: i8x32, b: i8x32) u8x32 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u8, 32>(_mm256_xor_si256(_mm256_cmpeq_epi8(x, y), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Avx2])
fn cmp_lt_lanes_i8x32(a: i8x32, b: i8x32) u8x32 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u8, 32>(_mm256_cmpgt_epi8(y, x));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Avx2])
fn cmp_le_lanes_i8x32(a: i8x32, b: i8x32) u8x32 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u8, 32>(_mm256_xor_si256(_mm256_cmpgt_epi8(x, y), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Avx2])
fn cmp_gt_lanes_i8x32(a: i8x32, b: i8x32) u8x32 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u8, 32>(_mm256_cmpgt_epi8(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Avx2])
fn cmp_ge_lanes_i8x32(a: i8x32, b: i8x32) u8x32 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u8, 32>(_mm256_xor_si256(_mm256_cmpgt_epi8(y, x), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Avx2])
fn choose_lanes_i8x32(m: u8x32, a: i8x32, b: i8x32) i8x32 {
    return yiv::<i8, 32>(_mm256_blendv_epi8(yi(b), yi(a), yi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_eq_i8x32(a: i8x32, b: i8x32) mask32 {
    return ((unsafe _mm256_cmp_epi8_mask(yi(a), yi(b), 0)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_ne_i8x32(a: i8x32, b: i8x32) mask32 {
    return ((unsafe _mm256_cmp_epi8_mask(yi(a), yi(b), 4)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_lt_i8x32(a: i8x32, b: i8x32) mask32 {
    return ((unsafe _mm256_cmp_epi8_mask(yi(a), yi(b), 1)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_le_i8x32(a: i8x32, b: i8x32) mask32 {
    return ((unsafe _mm256_cmp_epi8_mask(yi(a), yi(b), 2)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_gt_i8x32(a: i8x32, b: i8x32) mask32 {
    return ((unsafe _mm256_cmp_epi8_mask(yi(a), yi(b), 6)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_ge_i8x32(a: i8x32, b: i8x32) mask32 {
    return ((unsafe _mm256_cmp_epi8_mask(yi(a), yi(b), 5)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn choose_i8x32(m: mask32, a: i8x32, b: i8x32) i8x32 {
    return yiv::<i8, 32>(_mm256_mask_blend_epi8((m as u64) as u32, yi(b), yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Avx2])
fn cmp_eq_lanes_u8x32(a: u8x32, b: u8x32) u8x32 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u8, 32>(_mm256_cmpeq_epi8(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Avx2])
fn cmp_ne_lanes_u8x32(a: u8x32, b: u8x32) u8x32 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u8, 32>(_mm256_xor_si256(_mm256_cmpeq_epi8(x, y), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Avx2])
fn cmp_lt_lanes_u8x32(a: u8x32, b: u8x32) u8x32 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u8, 32>(
        _mm256_cmpgt_epi8(_mm256_xor_si256(y, _mm256_set1_epi8(-128)), _mm256_xor_si256(x, _mm256_set1_epi8(-128))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Avx2])
fn cmp_le_lanes_u8x32(a: u8x32, b: u8x32) u8x32 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u8, 32>(
        _mm256_xor_si256(
            _mm256_cmpgt_epi8(_mm256_xor_si256(x, _mm256_set1_epi8(-128)), _mm256_xor_si256(y, _mm256_set1_epi8(-128))),
            _mm256_set1_epi32(-1),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Avx2])
fn cmp_gt_lanes_u8x32(a: u8x32, b: u8x32) u8x32 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u8, 32>(
        _mm256_cmpgt_epi8(_mm256_xor_si256(x, _mm256_set1_epi8(-128)), _mm256_xor_si256(y, _mm256_set1_epi8(-128))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Avx2])
fn cmp_ge_lanes_u8x32(a: u8x32, b: u8x32) u8x32 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u8, 32>(
        _mm256_xor_si256(
            _mm256_cmpgt_epi8(_mm256_xor_si256(y, _mm256_set1_epi8(-128)), _mm256_xor_si256(x, _mm256_set1_epi8(-128))),
            _mm256_set1_epi32(-1),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Avx2])
fn choose_lanes_u8x32(m: u8x32, a: u8x32, b: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_blendv_epi8(yi(b), yi(a), yi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::LanesToMask, [cpu::Feature::Avx2])
fn lanes_to_mask_u8x32(m: u8x32) mask32 {
    return (_mm256_movemask_epi8(yi(m)) as u64 & 4294967295) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::AnyLanes, [cpu::Feature::Avx2])
fn any_lanes_u8x32(m: u8x32) bool {
    return _mm256_movemask_epi8(yi(m)) != 0;
}

@arch(x86_64)
@simd_impl(simd::Op::AllLanes, [cpu::Feature::Avx2])
fn all_lanes_u8x32(m: u8x32) bool {
    return _mm256_movemask_epi8(yi(m)) == -1;
}

@arch(x86_64)
@simd_impl(simd::Op::MaskToLanes, [cpu::Feature::Avx2])
fn mask_to_lanes_u8x32(m: mask32) u8x32 {
    let b = _mm256_set1_epi64x(-9205322385119247871);
    return yiv::<u8, 32>(
        _mm256_cmpeq_epi8(
            _mm256_and_si256(
                _mm256_shuffle_epi8(
                    _mm256_set1_epi32((m as u64) as i32),
                    _mm256_setr_epi8(
                        0,
                        0,
                        0,
                        0,
                        0,
                        0,
                        0,
                        0,
                        1,
                        1,
                        1,
                        1,
                        1,
                        1,
                        1,
                        1,
                        2,
                        2,
                        2,
                        2,
                        2,
                        2,
                        2,
                        2,
                        3,
                        3,
                        3,
                        3,
                        3,
                        3,
                        3,
                        3,
                    ),
                ),
                b,
            ),
            b,
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_eq_u8x32(a: u8x32, b: u8x32) mask32 {
    return ((unsafe _mm256_cmp_epu8_mask(yi(a), yi(b), 0)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_ne_u8x32(a: u8x32, b: u8x32) mask32 {
    return ((unsafe _mm256_cmp_epu8_mask(yi(a), yi(b), 4)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_lt_u8x32(a: u8x32, b: u8x32) mask32 {
    return ((unsafe _mm256_cmp_epu8_mask(yi(a), yi(b), 1)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_le_u8x32(a: u8x32, b: u8x32) mask32 {
    return ((unsafe _mm256_cmp_epu8_mask(yi(a), yi(b), 2)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_gt_u8x32(a: u8x32, b: u8x32) mask32 {
    return ((unsafe _mm256_cmp_epu8_mask(yi(a), yi(b), 6)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_ge_u8x32(a: u8x32, b: u8x32) mask32 {
    return ((unsafe _mm256_cmp_epu8_mask(yi(a), yi(b), 5)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn choose_u8x32(m: mask32, a: u8x32, b: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_mask_blend_epi8((m as u64) as u32, yi(b), yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Avx2])
fn cmp_eq_lanes_i16x16(a: i16x16, b: i16x16) u16x16 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u16, 16>(_mm256_cmpeq_epi16(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Avx2])
fn cmp_ne_lanes_i16x16(a: i16x16, b: i16x16) u16x16 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u16, 16>(_mm256_xor_si256(_mm256_cmpeq_epi16(x, y), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Avx2])
fn cmp_lt_lanes_i16x16(a: i16x16, b: i16x16) u16x16 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u16, 16>(_mm256_cmpgt_epi16(y, x));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Avx2])
fn cmp_le_lanes_i16x16(a: i16x16, b: i16x16) u16x16 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u16, 16>(_mm256_xor_si256(_mm256_cmpgt_epi16(x, y), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Avx2])
fn cmp_gt_lanes_i16x16(a: i16x16, b: i16x16) u16x16 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u16, 16>(_mm256_cmpgt_epi16(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Avx2])
fn cmp_ge_lanes_i16x16(a: i16x16, b: i16x16) u16x16 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u16, 16>(_mm256_xor_si256(_mm256_cmpgt_epi16(y, x), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Avx2])
fn choose_lanes_i16x16(m: u16x16, a: i16x16, b: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_blendv_epi8(yi(b), yi(a), yi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_eq_i16x16(a: i16x16, b: i16x16) mask16 {
    return ((unsafe _mm256_cmp_epi16_mask(yi(a), yi(b), 0)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_ne_i16x16(a: i16x16, b: i16x16) mask16 {
    return ((unsafe _mm256_cmp_epi16_mask(yi(a), yi(b), 4)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_lt_i16x16(a: i16x16, b: i16x16) mask16 {
    return ((unsafe _mm256_cmp_epi16_mask(yi(a), yi(b), 1)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_le_i16x16(a: i16x16, b: i16x16) mask16 {
    return ((unsafe _mm256_cmp_epi16_mask(yi(a), yi(b), 2)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_gt_i16x16(a: i16x16, b: i16x16) mask16 {
    return ((unsafe _mm256_cmp_epi16_mask(yi(a), yi(b), 6)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_ge_i16x16(a: i16x16, b: i16x16) mask16 {
    return ((unsafe _mm256_cmp_epi16_mask(yi(a), yi(b), 5)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn choose_i16x16(m: mask16, a: i16x16, b: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_mask_blend_epi16((m as u64) as u16, yi(b), yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Avx2])
fn cmp_eq_lanes_u16x16(a: u16x16, b: u16x16) u16x16 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u16, 16>(_mm256_cmpeq_epi16(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Avx2])
fn cmp_ne_lanes_u16x16(a: u16x16, b: u16x16) u16x16 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u16, 16>(_mm256_xor_si256(_mm256_cmpeq_epi16(x, y), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Avx2])
fn cmp_lt_lanes_u16x16(a: u16x16, b: u16x16) u16x16 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u16, 16>(
        _mm256_cmpgt_epi16(
            _mm256_xor_si256(y, _mm256_set1_epi16(-32768)),
            _mm256_xor_si256(x, _mm256_set1_epi16(-32768)),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Avx2])
fn cmp_le_lanes_u16x16(a: u16x16, b: u16x16) u16x16 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u16, 16>(
        _mm256_xor_si256(
            _mm256_cmpgt_epi16(
                _mm256_xor_si256(x, _mm256_set1_epi16(-32768)),
                _mm256_xor_si256(y, _mm256_set1_epi16(-32768)),
            ),
            _mm256_set1_epi32(-1),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Avx2])
fn cmp_gt_lanes_u16x16(a: u16x16, b: u16x16) u16x16 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u16, 16>(
        _mm256_cmpgt_epi16(
            _mm256_xor_si256(x, _mm256_set1_epi16(-32768)),
            _mm256_xor_si256(y, _mm256_set1_epi16(-32768)),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Avx2])
fn cmp_ge_lanes_u16x16(a: u16x16, b: u16x16) u16x16 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u16, 16>(
        _mm256_xor_si256(
            _mm256_cmpgt_epi16(
                _mm256_xor_si256(y, _mm256_set1_epi16(-32768)),
                _mm256_xor_si256(x, _mm256_set1_epi16(-32768)),
            ),
            _mm256_set1_epi32(-1),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Avx2])
fn choose_lanes_u16x16(m: u16x16, a: u16x16, b: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_blendv_epi8(yi(b), yi(a), yi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::LanesToMask, [cpu::Feature::Avx2])
fn lanes_to_mask_u16x16(m: u16x16) mask16 {
    let r = yi(m);
    return (_mm_movemask_epi8(_mm_packs_epi16(_mm256_castsi256_si128(r), unsafe _mm256_extracti128_si256(r, 1))) as u64 & 65535) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::AnyLanes, [cpu::Feature::Avx2])
fn any_lanes_u16x16(m: u16x16) bool {
    return _mm256_movemask_epi8(yi(m)) != 0;
}

@arch(x86_64)
@simd_impl(simd::Op::AllLanes, [cpu::Feature::Avx2])
fn all_lanes_u16x16(m: u16x16) bool {
    return _mm256_movemask_epi8(yi(m)) == -1;
}

@arch(x86_64)
@simd_impl(simd::Op::MaskToLanes, [cpu::Feature::Avx2])
fn mask_to_lanes_u16x16(m: mask16) u16x16 {
    let b = _mm256_setr_epi16(1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, -32768);
    return yiv::<u16, 16>(_mm256_cmpeq_epi16(_mm256_and_si256(_mm256_set1_epi16((m as u64) as i16), b), b));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_eq_u16x16(a: u16x16, b: u16x16) mask16 {
    return ((unsafe _mm256_cmp_epu16_mask(yi(a), yi(b), 0)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_ne_u16x16(a: u16x16, b: u16x16) mask16 {
    return ((unsafe _mm256_cmp_epu16_mask(yi(a), yi(b), 4)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_lt_u16x16(a: u16x16, b: u16x16) mask16 {
    return ((unsafe _mm256_cmp_epu16_mask(yi(a), yi(b), 1)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_le_u16x16(a: u16x16, b: u16x16) mask16 {
    return ((unsafe _mm256_cmp_epu16_mask(yi(a), yi(b), 2)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_gt_u16x16(a: u16x16, b: u16x16) mask16 {
    return ((unsafe _mm256_cmp_epu16_mask(yi(a), yi(b), 6)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn cmp_ge_u16x16(a: u16x16, b: u16x16) mask16 {
    return ((unsafe _mm256_cmp_epu16_mask(yi(a), yi(b), 5)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn choose_u16x16(m: mask16, a: u16x16, b: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_mask_blend_epi16((m as u64) as u16, yi(b), yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Avx2])
fn cmp_eq_lanes_i32x8(a: i32x8, b: i32x8) u32x8 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u32, 8>(_mm256_cmpeq_epi32(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Avx2])
fn cmp_ne_lanes_i32x8(a: i32x8, b: i32x8) u32x8 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u32, 8>(_mm256_xor_si256(_mm256_cmpeq_epi32(x, y), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Avx2])
fn cmp_lt_lanes_i32x8(a: i32x8, b: i32x8) u32x8 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u32, 8>(_mm256_cmpgt_epi32(y, x));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Avx2])
fn cmp_le_lanes_i32x8(a: i32x8, b: i32x8) u32x8 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u32, 8>(_mm256_xor_si256(_mm256_cmpgt_epi32(x, y), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Avx2])
fn cmp_gt_lanes_i32x8(a: i32x8, b: i32x8) u32x8 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u32, 8>(_mm256_cmpgt_epi32(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Avx2])
fn cmp_ge_lanes_i32x8(a: i32x8, b: i32x8) u32x8 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u32, 8>(_mm256_xor_si256(_mm256_cmpgt_epi32(y, x), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Avx2])
fn choose_lanes_i32x8(m: u32x8, a: i32x8, b: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_blendv_epi8(yi(b), yi(a), yi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_eq_i32x8(a: i32x8, b: i32x8) mask8 {
    return ((unsafe _mm256_cmp_epi32_mask(yi(a), yi(b), 0)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ne_i32x8(a: i32x8, b: i32x8) mask8 {
    return ((unsafe _mm256_cmp_epi32_mask(yi(a), yi(b), 4)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_lt_i32x8(a: i32x8, b: i32x8) mask8 {
    return ((unsafe _mm256_cmp_epi32_mask(yi(a), yi(b), 1)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_le_i32x8(a: i32x8, b: i32x8) mask8 {
    return ((unsafe _mm256_cmp_epi32_mask(yi(a), yi(b), 2)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_gt_i32x8(a: i32x8, b: i32x8) mask8 {
    return ((unsafe _mm256_cmp_epi32_mask(yi(a), yi(b), 6)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ge_i32x8(a: i32x8, b: i32x8) mask8 {
    return ((unsafe _mm256_cmp_epi32_mask(yi(a), yi(b), 5)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn choose_i32x8(m: mask8, a: i32x8, b: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_mask_blend_epi32((m as u64) as u8, yi(b), yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Avx2])
fn cmp_eq_lanes_u32x8(a: u32x8, b: u32x8) u32x8 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u32, 8>(_mm256_cmpeq_epi32(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Avx2])
fn cmp_ne_lanes_u32x8(a: u32x8, b: u32x8) u32x8 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u32, 8>(_mm256_xor_si256(_mm256_cmpeq_epi32(x, y), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Avx2])
fn cmp_lt_lanes_u32x8(a: u32x8, b: u32x8) u32x8 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u32, 8>(
        _mm256_cmpgt_epi32(
            _mm256_xor_si256(y, _mm256_set1_epi32(-2147483648)),
            _mm256_xor_si256(x, _mm256_set1_epi32(-2147483648)),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Avx2])
fn cmp_le_lanes_u32x8(a: u32x8, b: u32x8) u32x8 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u32, 8>(
        _mm256_xor_si256(
            _mm256_cmpgt_epi32(
                _mm256_xor_si256(x, _mm256_set1_epi32(-2147483648)),
                _mm256_xor_si256(y, _mm256_set1_epi32(-2147483648)),
            ),
            _mm256_set1_epi32(-1),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Avx2])
fn cmp_gt_lanes_u32x8(a: u32x8, b: u32x8) u32x8 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u32, 8>(
        _mm256_cmpgt_epi32(
            _mm256_xor_si256(x, _mm256_set1_epi32(-2147483648)),
            _mm256_xor_si256(y, _mm256_set1_epi32(-2147483648)),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Avx2])
fn cmp_ge_lanes_u32x8(a: u32x8, b: u32x8) u32x8 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u32, 8>(
        _mm256_xor_si256(
            _mm256_cmpgt_epi32(
                _mm256_xor_si256(y, _mm256_set1_epi32(-2147483648)),
                _mm256_xor_si256(x, _mm256_set1_epi32(-2147483648)),
            ),
            _mm256_set1_epi32(-1),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Avx2])
fn choose_lanes_u32x8(m: u32x8, a: u32x8, b: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_blendv_epi8(yi(b), yi(a), yi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::LanesToMask, [cpu::Feature::Avx])
fn lanes_to_mask_u32x8(m: u32x8) mask8 {
    return (_mm256_movemask_ps(_mm256_castsi256_ps(yi(m))) as u64 & 255) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::AnyLanes, [cpu::Feature::Avx2])
fn any_lanes_u32x8(m: u32x8) bool {
    return _mm256_movemask_epi8(yi(m)) != 0;
}

@arch(x86_64)
@simd_impl(simd::Op::AllLanes, [cpu::Feature::Avx2])
fn all_lanes_u32x8(m: u32x8) bool {
    return _mm256_movemask_epi8(yi(m)) == -1;
}

@arch(x86_64)
@simd_impl(simd::Op::MaskToLanes, [cpu::Feature::Avx2])
fn mask_to_lanes_u32x8(m: mask8) u32x8 {
    let b = _mm256_setr_epi32(1, 2, 4, 8, 16, 32, 64, 128);
    return yiv::<u32, 8>(_mm256_cmpeq_epi32(_mm256_and_si256(_mm256_set1_epi32((m as u64) as i32), b), b));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_eq_u32x8(a: u32x8, b: u32x8) mask8 {
    return ((unsafe _mm256_cmp_epu32_mask(yi(a), yi(b), 0)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ne_u32x8(a: u32x8, b: u32x8) mask8 {
    return ((unsafe _mm256_cmp_epu32_mask(yi(a), yi(b), 4)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_lt_u32x8(a: u32x8, b: u32x8) mask8 {
    return ((unsafe _mm256_cmp_epu32_mask(yi(a), yi(b), 1)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_le_u32x8(a: u32x8, b: u32x8) mask8 {
    return ((unsafe _mm256_cmp_epu32_mask(yi(a), yi(b), 2)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_gt_u32x8(a: u32x8, b: u32x8) mask8 {
    return ((unsafe _mm256_cmp_epu32_mask(yi(a), yi(b), 6)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ge_u32x8(a: u32x8, b: u32x8) mask8 {
    return ((unsafe _mm256_cmp_epu32_mask(yi(a), yi(b), 5)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn choose_u32x8(m: mask8, a: u32x8, b: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_mask_blend_epi32((m as u64) as u8, yi(b), yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Avx2])
fn cmp_eq_lanes_i64x4(a: i64x4, b: i64x4) u64x4 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u64, 4>(_mm256_cmpeq_epi64(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Avx2])
fn cmp_ne_lanes_i64x4(a: i64x4, b: i64x4) u64x4 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u64, 4>(_mm256_xor_si256(_mm256_cmpeq_epi64(x, y), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Avx2])
fn cmp_lt_lanes_i64x4(a: i64x4, b: i64x4) u64x4 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u64, 4>(_mm256_cmpgt_epi64(y, x));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Avx2])
fn cmp_le_lanes_i64x4(a: i64x4, b: i64x4) u64x4 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u64, 4>(_mm256_xor_si256(_mm256_cmpgt_epi64(x, y), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Avx2])
fn cmp_gt_lanes_i64x4(a: i64x4, b: i64x4) u64x4 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u64, 4>(_mm256_cmpgt_epi64(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Avx2])
fn cmp_ge_lanes_i64x4(a: i64x4, b: i64x4) u64x4 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u64, 4>(_mm256_xor_si256(_mm256_cmpgt_epi64(y, x), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Avx2])
fn choose_lanes_i64x4(m: u64x4, a: i64x4, b: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_blendv_epi8(yi(b), yi(a), yi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_eq_i64x4(a: i64x4, b: i64x4) mask4 {
    return ((unsafe _mm256_cmp_epi64_mask(yi(a), yi(b), 0)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ne_i64x4(a: i64x4, b: i64x4) mask4 {
    return ((unsafe _mm256_cmp_epi64_mask(yi(a), yi(b), 4)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_lt_i64x4(a: i64x4, b: i64x4) mask4 {
    return ((unsafe _mm256_cmp_epi64_mask(yi(a), yi(b), 1)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_le_i64x4(a: i64x4, b: i64x4) mask4 {
    return ((unsafe _mm256_cmp_epi64_mask(yi(a), yi(b), 2)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_gt_i64x4(a: i64x4, b: i64x4) mask4 {
    return ((unsafe _mm256_cmp_epi64_mask(yi(a), yi(b), 6)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ge_i64x4(a: i64x4, b: i64x4) mask4 {
    return ((unsafe _mm256_cmp_epi64_mask(yi(a), yi(b), 5)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn choose_i64x4(m: mask4, a: i64x4, b: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_mask_blend_epi64((m as u64) as u8, yi(b), yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Avx2])
fn cmp_eq_lanes_u64x4(a: u64x4, b: u64x4) u64x4 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u64, 4>(_mm256_cmpeq_epi64(x, y));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Avx2])
fn cmp_ne_lanes_u64x4(a: u64x4, b: u64x4) u64x4 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u64, 4>(_mm256_xor_si256(_mm256_cmpeq_epi64(x, y), _mm256_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Avx2])
fn cmp_lt_lanes_u64x4(a: u64x4, b: u64x4) u64x4 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u64, 4>(
        _mm256_cmpgt_epi64(
            _mm256_xor_si256(y, _mm256_set1_epi64x(-9223372036854775807 - 1)),
            _mm256_xor_si256(x, _mm256_set1_epi64x(-9223372036854775807 - 1)),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Avx2])
fn cmp_le_lanes_u64x4(a: u64x4, b: u64x4) u64x4 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u64, 4>(
        _mm256_xor_si256(
            _mm256_cmpgt_epi64(
                _mm256_xor_si256(x, _mm256_set1_epi64x(-9223372036854775807 - 1)),
                _mm256_xor_si256(y, _mm256_set1_epi64x(-9223372036854775807 - 1)),
            ),
            _mm256_set1_epi32(-1),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Avx2])
fn cmp_gt_lanes_u64x4(a: u64x4, b: u64x4) u64x4 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u64, 4>(
        _mm256_cmpgt_epi64(
            _mm256_xor_si256(x, _mm256_set1_epi64x(-9223372036854775807 - 1)),
            _mm256_xor_si256(y, _mm256_set1_epi64x(-9223372036854775807 - 1)),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Avx2])
fn cmp_ge_lanes_u64x4(a: u64x4, b: u64x4) u64x4 {
    let x = yi(a);
    let y = yi(b);
    return yiv::<u64, 4>(
        _mm256_xor_si256(
            _mm256_cmpgt_epi64(
                _mm256_xor_si256(y, _mm256_set1_epi64x(-9223372036854775807 - 1)),
                _mm256_xor_si256(x, _mm256_set1_epi64x(-9223372036854775807 - 1)),
            ),
            _mm256_set1_epi32(-1),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Avx2])
fn choose_lanes_u64x4(m: u64x4, a: u64x4, b: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_blendv_epi8(yi(b), yi(a), yi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::LanesToMask, [cpu::Feature::Avx])
fn lanes_to_mask_u64x4(m: u64x4) mask4 {
    return (_mm256_movemask_pd(_mm256_castsi256_pd(yi(m))) as u64 & 15) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::AnyLanes, [cpu::Feature::Avx2])
fn any_lanes_u64x4(m: u64x4) bool {
    return _mm256_movemask_epi8(yi(m)) != 0;
}

@arch(x86_64)
@simd_impl(simd::Op::AllLanes, [cpu::Feature::Avx2])
fn all_lanes_u64x4(m: u64x4) bool {
    return _mm256_movemask_epi8(yi(m)) == -1;
}

@arch(x86_64)
@simd_impl(simd::Op::MaskToLanes, [cpu::Feature::Avx2])
fn mask_to_lanes_u64x4(m: mask4) u64x4 {
    let b = _mm256_set_epi64x(8, 4, 2, 1);
    return yiv::<u64, 4>(_mm256_cmpeq_epi64(_mm256_and_si256(_mm256_set1_epi64x((m as u64) as i64), b), b));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_eq_u64x4(a: u64x4, b: u64x4) mask4 {
    return ((unsafe _mm256_cmp_epu64_mask(yi(a), yi(b), 0)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ne_u64x4(a: u64x4, b: u64x4) mask4 {
    return ((unsafe _mm256_cmp_epu64_mask(yi(a), yi(b), 4)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_lt_u64x4(a: u64x4, b: u64x4) mask4 {
    return ((unsafe _mm256_cmp_epu64_mask(yi(a), yi(b), 1)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_le_u64x4(a: u64x4, b: u64x4) mask4 {
    return ((unsafe _mm256_cmp_epu64_mask(yi(a), yi(b), 2)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_gt_u64x4(a: u64x4, b: u64x4) mask4 {
    return ((unsafe _mm256_cmp_epu64_mask(yi(a), yi(b), 6)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ge_u64x4(a: u64x4, b: u64x4) mask4 {
    return ((unsafe _mm256_cmp_epu64_mask(yi(a), yi(b), 5)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn choose_u64x4(m: mask4, a: u64x4, b: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_mask_blend_epi64((m as u64) as u8, yi(b), yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Avx])
fn cmp_eq_lanes_f32x8(a: f32x8, b: f32x8) u32x8 {
    let x = yf(a);
    let y = yf(b);
    return yiv::<u32, 8>(_mm256_castps_si256(unsafe _mm256_cmp_ps(x, y, 0)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Avx])
fn cmp_ne_lanes_f32x8(a: f32x8, b: f32x8) u32x8 {
    let x = yf(a);
    let y = yf(b);
    return yiv::<u32, 8>(_mm256_castps_si256(unsafe _mm256_cmp_ps(x, y, 4)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Avx])
fn cmp_lt_lanes_f32x8(a: f32x8, b: f32x8) u32x8 {
    let x = yf(a);
    let y = yf(b);
    return yiv::<u32, 8>(_mm256_castps_si256(unsafe _mm256_cmp_ps(x, y, 17)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Avx])
fn cmp_le_lanes_f32x8(a: f32x8, b: f32x8) u32x8 {
    let x = yf(a);
    let y = yf(b);
    return yiv::<u32, 8>(_mm256_castps_si256(unsafe _mm256_cmp_ps(x, y, 18)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Avx])
fn cmp_gt_lanes_f32x8(a: f32x8, b: f32x8) u32x8 {
    let x = yf(a);
    let y = yf(b);
    return yiv::<u32, 8>(_mm256_castps_si256(unsafe _mm256_cmp_ps(x, y, 30)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Avx])
fn cmp_ge_lanes_f32x8(a: f32x8, b: f32x8) u32x8 {
    let x = yf(a);
    let y = yf(b);
    return yiv::<u32, 8>(_mm256_castps_si256(unsafe _mm256_cmp_ps(x, y, 29)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Avx2])
fn choose_lanes_f32x8(m: u32x8, a: f32x8, b: f32x8) f32x8 {
    return yiv::<f32, 8>(_mm256_blendv_epi8(yi(b), yi(a), yi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_eq_f32x8(a: f32x8, b: f32x8) mask8 {
    return ((unsafe _mm256_cmp_ps_mask(yf(a), yf(b), 0)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ne_f32x8(a: f32x8, b: f32x8) mask8 {
    return ((unsafe _mm256_cmp_ps_mask(yf(a), yf(b), 4)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_lt_f32x8(a: f32x8, b: f32x8) mask8 {
    return ((unsafe _mm256_cmp_ps_mask(yf(a), yf(b), 17)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_le_f32x8(a: f32x8, b: f32x8) mask8 {
    return ((unsafe _mm256_cmp_ps_mask(yf(a), yf(b), 18)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_gt_f32x8(a: f32x8, b: f32x8) mask8 {
    return ((unsafe _mm256_cmp_ps_mask(yf(a), yf(b), 30)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ge_f32x8(a: f32x8, b: f32x8) mask8 {
    return ((unsafe _mm256_cmp_ps_mask(yf(a), yf(b), 29)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn choose_f32x8(m: mask8, a: f32x8, b: f32x8) f32x8 {
    return yfv::<f32, 8>(_mm256_mask_blend_ps((m as u64) as u8, yf(b), yf(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Avx])
fn cmp_eq_lanes_f64x4(a: f64x4, b: f64x4) u64x4 {
    let x = yd(a);
    let y = yd(b);
    return yiv::<u64, 4>(_mm256_castpd_si256(unsafe _mm256_cmp_pd(x, y, 0)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Avx])
fn cmp_ne_lanes_f64x4(a: f64x4, b: f64x4) u64x4 {
    let x = yd(a);
    let y = yd(b);
    return yiv::<u64, 4>(_mm256_castpd_si256(unsafe _mm256_cmp_pd(x, y, 4)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Avx])
fn cmp_lt_lanes_f64x4(a: f64x4, b: f64x4) u64x4 {
    let x = yd(a);
    let y = yd(b);
    return yiv::<u64, 4>(_mm256_castpd_si256(unsafe _mm256_cmp_pd(x, y, 17)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Avx])
fn cmp_le_lanes_f64x4(a: f64x4, b: f64x4) u64x4 {
    let x = yd(a);
    let y = yd(b);
    return yiv::<u64, 4>(_mm256_castpd_si256(unsafe _mm256_cmp_pd(x, y, 18)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Avx])
fn cmp_gt_lanes_f64x4(a: f64x4, b: f64x4) u64x4 {
    let x = yd(a);
    let y = yd(b);
    return yiv::<u64, 4>(_mm256_castpd_si256(unsafe _mm256_cmp_pd(x, y, 30)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Avx])
fn cmp_ge_lanes_f64x4(a: f64x4, b: f64x4) u64x4 {
    let x = yd(a);
    let y = yd(b);
    return yiv::<u64, 4>(_mm256_castpd_si256(unsafe _mm256_cmp_pd(x, y, 29)));
}

@arch(x86_64)
@simd_impl(simd::Op::ChooseLanes, [cpu::Feature::Avx2])
fn choose_lanes_f64x4(m: u64x4, a: f64x4, b: f64x4) f64x4 {
    return yiv::<f64, 4>(_mm256_blendv_epi8(yi(b), yi(a), yi(m)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_eq_f64x4(a: f64x4, b: f64x4) mask4 {
    return ((unsafe _mm256_cmp_pd_mask(yd(a), yd(b), 0)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ne_f64x4(a: f64x4, b: f64x4) mask4 {
    return ((unsafe _mm256_cmp_pd_mask(yd(a), yd(b), 4)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_lt_f64x4(a: f64x4, b: f64x4) mask4 {
    return ((unsafe _mm256_cmp_pd_mask(yd(a), yd(b), 17)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_le_f64x4(a: f64x4, b: f64x4) mask4 {
    return ((unsafe _mm256_cmp_pd_mask(yd(a), yd(b), 18)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_gt_f64x4(a: f64x4, b: f64x4) mask4 {
    return ((unsafe _mm256_cmp_pd_mask(yd(a), yd(b), 30)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cmp_ge_f64x4(a: f64x4, b: f64x4) mask4 {
    return ((unsafe _mm256_cmp_pd_mask(yd(a), yd(b), 29)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn choose_f64x4(m: mask4, a: f64x4, b: f64x4) f64x4 {
    return ydv::<f64, 4>(_mm256_mask_blend_pd((m as u64) as u8, yd(b), yd(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512bw])
fn cmp_eq_i8x64(a: i8x64, b: i8x64) mask64 {
    return (unsafe _mm512_cmp_epi8_mask(zi(a), zi(b), 0)) as mask64;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512bw])
fn cmp_ne_i8x64(a: i8x64, b: i8x64) mask64 {
    return (unsafe _mm512_cmp_epi8_mask(zi(a), zi(b), 4)) as mask64;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512bw])
fn cmp_lt_i8x64(a: i8x64, b: i8x64) mask64 {
    return (unsafe _mm512_cmp_epi8_mask(zi(a), zi(b), 1)) as mask64;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512bw])
fn cmp_le_i8x64(a: i8x64, b: i8x64) mask64 {
    return (unsafe _mm512_cmp_epi8_mask(zi(a), zi(b), 2)) as mask64;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512bw])
fn cmp_gt_i8x64(a: i8x64, b: i8x64) mask64 {
    return (unsafe _mm512_cmp_epi8_mask(zi(a), zi(b), 6)) as mask64;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512bw])
fn cmp_ge_i8x64(a: i8x64, b: i8x64) mask64 {
    return (unsafe _mm512_cmp_epi8_mask(zi(a), zi(b), 5)) as mask64;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512bw])
fn choose_i8x64(m: mask64, a: i8x64, b: i8x64) i8x64 {
    return ziv::<i8, 64>(_mm512_mask_blend_epi8(m as u64, zi(b), zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512bw])
fn cmp_eq_u8x64(a: u8x64, b: u8x64) mask64 {
    return (unsafe _mm512_cmp_epu8_mask(zi(a), zi(b), 0)) as mask64;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512bw])
fn cmp_ne_u8x64(a: u8x64, b: u8x64) mask64 {
    return (unsafe _mm512_cmp_epu8_mask(zi(a), zi(b), 4)) as mask64;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512bw])
fn cmp_lt_u8x64(a: u8x64, b: u8x64) mask64 {
    return (unsafe _mm512_cmp_epu8_mask(zi(a), zi(b), 1)) as mask64;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512bw])
fn cmp_le_u8x64(a: u8x64, b: u8x64) mask64 {
    return (unsafe _mm512_cmp_epu8_mask(zi(a), zi(b), 2)) as mask64;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512bw])
fn cmp_gt_u8x64(a: u8x64, b: u8x64) mask64 {
    return (unsafe _mm512_cmp_epu8_mask(zi(a), zi(b), 6)) as mask64;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512bw])
fn cmp_ge_u8x64(a: u8x64, b: u8x64) mask64 {
    return (unsafe _mm512_cmp_epu8_mask(zi(a), zi(b), 5)) as mask64;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512bw])
fn choose_u8x64(m: mask64, a: u8x64, b: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_mask_blend_epi8(m as u64, zi(b), zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512bw])
fn cmp_eq_i16x32(a: i16x32, b: i16x32) mask32 {
    return ((unsafe _mm512_cmp_epi16_mask(zi(a), zi(b), 0)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512bw])
fn cmp_ne_i16x32(a: i16x32, b: i16x32) mask32 {
    return ((unsafe _mm512_cmp_epi16_mask(zi(a), zi(b), 4)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512bw])
fn cmp_lt_i16x32(a: i16x32, b: i16x32) mask32 {
    return ((unsafe _mm512_cmp_epi16_mask(zi(a), zi(b), 1)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512bw])
fn cmp_le_i16x32(a: i16x32, b: i16x32) mask32 {
    return ((unsafe _mm512_cmp_epi16_mask(zi(a), zi(b), 2)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512bw])
fn cmp_gt_i16x32(a: i16x32, b: i16x32) mask32 {
    return ((unsafe _mm512_cmp_epi16_mask(zi(a), zi(b), 6)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512bw])
fn cmp_ge_i16x32(a: i16x32, b: i16x32) mask32 {
    return ((unsafe _mm512_cmp_epi16_mask(zi(a), zi(b), 5)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512bw])
fn choose_i16x32(m: mask32, a: i16x32, b: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_mask_blend_epi16((m as u64) as u32, zi(b), zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512bw])
fn cmp_eq_u16x32(a: u16x32, b: u16x32) mask32 {
    return ((unsafe _mm512_cmp_epu16_mask(zi(a), zi(b), 0)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512bw])
fn cmp_ne_u16x32(a: u16x32, b: u16x32) mask32 {
    return ((unsafe _mm512_cmp_epu16_mask(zi(a), zi(b), 4)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512bw])
fn cmp_lt_u16x32(a: u16x32, b: u16x32) mask32 {
    return ((unsafe _mm512_cmp_epu16_mask(zi(a), zi(b), 1)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512bw])
fn cmp_le_u16x32(a: u16x32, b: u16x32) mask32 {
    return ((unsafe _mm512_cmp_epu16_mask(zi(a), zi(b), 2)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512bw])
fn cmp_gt_u16x32(a: u16x32, b: u16x32) mask32 {
    return ((unsafe _mm512_cmp_epu16_mask(zi(a), zi(b), 6)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512bw])
fn cmp_ge_u16x32(a: u16x32, b: u16x32) mask32 {
    return ((unsafe _mm512_cmp_epu16_mask(zi(a), zi(b), 5)) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512bw])
fn choose_u16x32(m: mask32, a: u16x32, b: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_mask_blend_epi16((m as u64) as u32, zi(b), zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f])
fn cmp_eq_i32x16(a: i32x16, b: i32x16) mask16 {
    return ((unsafe _mm512_cmp_epi32_mask(zi(a), zi(b), 0)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f])
fn cmp_ne_i32x16(a: i32x16, b: i32x16) mask16 {
    return ((unsafe _mm512_cmp_epi32_mask(zi(a), zi(b), 4)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f])
fn cmp_lt_i32x16(a: i32x16, b: i32x16) mask16 {
    return ((unsafe _mm512_cmp_epi32_mask(zi(a), zi(b), 1)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f])
fn cmp_le_i32x16(a: i32x16, b: i32x16) mask16 {
    return ((unsafe _mm512_cmp_epi32_mask(zi(a), zi(b), 2)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f])
fn cmp_gt_i32x16(a: i32x16, b: i32x16) mask16 {
    return ((unsafe _mm512_cmp_epi32_mask(zi(a), zi(b), 6)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f])
fn cmp_ge_i32x16(a: i32x16, b: i32x16) mask16 {
    return ((unsafe _mm512_cmp_epi32_mask(zi(a), zi(b), 5)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f])
fn choose_i32x16(m: mask16, a: i32x16, b: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_mask_blend_epi32((m as u64) as u16, zi(b), zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f])
fn cmp_eq_u32x16(a: u32x16, b: u32x16) mask16 {
    return ((unsafe _mm512_cmp_epu32_mask(zi(a), zi(b), 0)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f])
fn cmp_ne_u32x16(a: u32x16, b: u32x16) mask16 {
    return ((unsafe _mm512_cmp_epu32_mask(zi(a), zi(b), 4)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f])
fn cmp_lt_u32x16(a: u32x16, b: u32x16) mask16 {
    return ((unsafe _mm512_cmp_epu32_mask(zi(a), zi(b), 1)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f])
fn cmp_le_u32x16(a: u32x16, b: u32x16) mask16 {
    return ((unsafe _mm512_cmp_epu32_mask(zi(a), zi(b), 2)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f])
fn cmp_gt_u32x16(a: u32x16, b: u32x16) mask16 {
    return ((unsafe _mm512_cmp_epu32_mask(zi(a), zi(b), 6)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f])
fn cmp_ge_u32x16(a: u32x16, b: u32x16) mask16 {
    return ((unsafe _mm512_cmp_epu32_mask(zi(a), zi(b), 5)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f])
fn choose_u32x16(m: mask16, a: u32x16, b: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_mask_blend_epi32((m as u64) as u16, zi(b), zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f])
fn cmp_eq_i64x8(a: i64x8, b: i64x8) mask8 {
    return ((unsafe _mm512_cmp_epi64_mask(zi(a), zi(b), 0)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f])
fn cmp_ne_i64x8(a: i64x8, b: i64x8) mask8 {
    return ((unsafe _mm512_cmp_epi64_mask(zi(a), zi(b), 4)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f])
fn cmp_lt_i64x8(a: i64x8, b: i64x8) mask8 {
    return ((unsafe _mm512_cmp_epi64_mask(zi(a), zi(b), 1)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f])
fn cmp_le_i64x8(a: i64x8, b: i64x8) mask8 {
    return ((unsafe _mm512_cmp_epi64_mask(zi(a), zi(b), 2)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f])
fn cmp_gt_i64x8(a: i64x8, b: i64x8) mask8 {
    return ((unsafe _mm512_cmp_epi64_mask(zi(a), zi(b), 6)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f])
fn cmp_ge_i64x8(a: i64x8, b: i64x8) mask8 {
    return ((unsafe _mm512_cmp_epi64_mask(zi(a), zi(b), 5)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f])
fn choose_i64x8(m: mask8, a: i64x8, b: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_mask_blend_epi64((m as u64) as u8, zi(b), zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f])
fn cmp_eq_u64x8(a: u64x8, b: u64x8) mask8 {
    return ((unsafe _mm512_cmp_epu64_mask(zi(a), zi(b), 0)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f])
fn cmp_ne_u64x8(a: u64x8, b: u64x8) mask8 {
    return ((unsafe _mm512_cmp_epu64_mask(zi(a), zi(b), 4)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f])
fn cmp_lt_u64x8(a: u64x8, b: u64x8) mask8 {
    return ((unsafe _mm512_cmp_epu64_mask(zi(a), zi(b), 1)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f])
fn cmp_le_u64x8(a: u64x8, b: u64x8) mask8 {
    return ((unsafe _mm512_cmp_epu64_mask(zi(a), zi(b), 2)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f])
fn cmp_gt_u64x8(a: u64x8, b: u64x8) mask8 {
    return ((unsafe _mm512_cmp_epu64_mask(zi(a), zi(b), 6)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f])
fn cmp_ge_u64x8(a: u64x8, b: u64x8) mask8 {
    return ((unsafe _mm512_cmp_epu64_mask(zi(a), zi(b), 5)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f])
fn choose_u64x8(m: mask8, a: u64x8, b: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_mask_blend_epi64((m as u64) as u8, zi(b), zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f])
fn cmp_eq_f32x16(a: f32x16, b: f32x16) mask16 {
    return ((unsafe _mm512_cmp_ps_mask(zf(a), zf(b), 0)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f])
fn cmp_ne_f32x16(a: f32x16, b: f32x16) mask16 {
    return ((unsafe _mm512_cmp_ps_mask(zf(a), zf(b), 4)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f])
fn cmp_lt_f32x16(a: f32x16, b: f32x16) mask16 {
    return ((unsafe _mm512_cmp_ps_mask(zf(a), zf(b), 17)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f])
fn cmp_le_f32x16(a: f32x16, b: f32x16) mask16 {
    return ((unsafe _mm512_cmp_ps_mask(zf(a), zf(b), 18)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f])
fn cmp_gt_f32x16(a: f32x16, b: f32x16) mask16 {
    return ((unsafe _mm512_cmp_ps_mask(zf(a), zf(b), 30)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f])
fn cmp_ge_f32x16(a: f32x16, b: f32x16) mask16 {
    return ((unsafe _mm512_cmp_ps_mask(zf(a), zf(b), 29)) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f])
fn choose_f32x16(m: mask16, a: f32x16, b: f32x16) f32x16 {
    return zfv::<f32, 16>(_mm512_mask_blend_ps((m as u64) as u16, zf(b), zf(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEq, [cpu::Feature::Avx512f])
fn cmp_eq_f64x8(a: f64x8, b: f64x8) mask8 {
    return ((unsafe _mm512_cmp_pd_mask(zd(a), zd(b), 0)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNe, [cpu::Feature::Avx512f])
fn cmp_ne_f64x8(a: f64x8, b: f64x8) mask8 {
    return ((unsafe _mm512_cmp_pd_mask(zd(a), zd(b), 4)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLt, [cpu::Feature::Avx512f])
fn cmp_lt_f64x8(a: f64x8, b: f64x8) mask8 {
    return ((unsafe _mm512_cmp_pd_mask(zd(a), zd(b), 17)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLe, [cpu::Feature::Avx512f])
fn cmp_le_f64x8(a: f64x8, b: f64x8) mask8 {
    return ((unsafe _mm512_cmp_pd_mask(zd(a), zd(b), 18)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGt, [cpu::Feature::Avx512f])
fn cmp_gt_f64x8(a: f64x8, b: f64x8) mask8 {
    return ((unsafe _mm512_cmp_pd_mask(zd(a), zd(b), 30)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGe, [cpu::Feature::Avx512f])
fn cmp_ge_f64x8(a: f64x8, b: f64x8) mask8 {
    return ((unsafe _mm512_cmp_pd_mask(zd(a), zd(b), 29)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::Choose, [cpu::Feature::Avx512f])
fn choose_f64x8(m: mask8, a: f64x8, b: f64x8) f64x8 {
    return zdv::<f64, 8>(_mm512_mask_blend_pd((m as u64) as u8, zd(b), zd(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Sse2])
fn overflow_add_i8x16(a: i8x16, b: i8x16) mask16 {
    let x = xi(a);
    let y = xi(b);
    let r = _mm_add_epi8(x, y);
    let o = _mm_and_si128(_mm_xor_si128(x, r), _mm_xor_si128(y, r));
    return (_mm_movemask_epi8(o) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Sse2])
fn overflow_sub_i8x16(a: i8x16, b: i8x16) mask16 {
    let x = xi(a);
    let y = xi(b);
    let r = _mm_sub_epi8(x, y);
    let o = _mm_and_si128(_mm_xor_si128(x, y), _mm_xor_si128(x, r));
    return (_mm_movemask_epi8(o) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Sse2])
fn overflow_add_u8x16(a: u8x16, b: u8x16) mask16 {
    let x = xi(a);
    let y = xi(b);
    let o = _mm_cmpgt_epi8(
        _mm_xor_si128(x, _mm_set1_epi8(-128)),
        _mm_xor_si128(_mm_add_epi8(x, y), _mm_set1_epi8(-128)),
    );
    return (_mm_movemask_epi8(o) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Sse2])
fn overflow_sub_u8x16(a: u8x16, b: u8x16) mask16 {
    let x = xi(a);
    let y = xi(b);
    let o = _mm_cmpgt_epi8(_mm_xor_si128(y, _mm_set1_epi8(-128)), _mm_xor_si128(x, _mm_set1_epi8(-128)));
    return (_mm_movemask_epi8(o) as u64) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Sse2])
fn overflow_add_i16x8(a: i16x8, b: i16x8) mask8 {
    let x = xi(a);
    let y = xi(b);
    let r = _mm_add_epi16(x, y);
    let o = _mm_and_si128(_mm_xor_si128(x, r), _mm_xor_si128(y, r));
    return (_mm_movemask_epi8(_mm_packs_epi16(o, _mm_setzero_si128())) as u64 & 255) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Sse2])
fn overflow_sub_i16x8(a: i16x8, b: i16x8) mask8 {
    let x = xi(a);
    let y = xi(b);
    let r = _mm_sub_epi16(x, y);
    let o = _mm_and_si128(_mm_xor_si128(x, y), _mm_xor_si128(x, r));
    return (_mm_movemask_epi8(_mm_packs_epi16(o, _mm_setzero_si128())) as u64 & 255) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowMul, [cpu::Feature::Sse2])
fn overflow_mul_i16x8(a: i16x8, b: i16x8) mask8 {
    let x = xi(a);
    let y = xi(b);
    let o = _mm_xor_si128(_mm_mulhi_epi16(x, y), _mm_srai_epi16(_mm_mullo_epi16(x, y), 15));
    return (_mm_movemask_epi8(_mm_packs_epi16(_mm_cmpeq_epi16(o, _mm_setzero_si128()), _mm_setzero_si128())) as u64 & 255 ^ 255) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Sse2])
fn overflow_add_u16x8(a: u16x8, b: u16x8) mask8 {
    let x = xi(a);
    let y = xi(b);
    let o = _mm_cmpgt_epi16(
        _mm_xor_si128(x, _mm_set1_epi16(-32768)),
        _mm_xor_si128(_mm_add_epi16(x, y), _mm_set1_epi16(-32768)),
    );
    return (_mm_movemask_epi8(_mm_packs_epi16(o, _mm_setzero_si128())) as u64 & 255) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Sse2])
fn overflow_sub_u16x8(a: u16x8, b: u16x8) mask8 {
    let x = xi(a);
    let y = xi(b);
    let o = _mm_cmpgt_epi16(_mm_xor_si128(y, _mm_set1_epi16(-32768)), _mm_xor_si128(x, _mm_set1_epi16(-32768)));
    return (_mm_movemask_epi8(_mm_packs_epi16(o, _mm_setzero_si128())) as u64 & 255) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowMul, [cpu::Feature::Sse2])
fn overflow_mul_u16x8(a: u16x8, b: u16x8) mask8 {
    let o = _mm_mulhi_epu16(xi(a), xi(b));
    return (_mm_movemask_epi8(_mm_packs_epi16(_mm_cmpeq_epi16(o, _mm_setzero_si128()), _mm_setzero_si128())) as u64 & 255 ^ 255) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Sse2])
fn overflow_add_i32x4(a: i32x4, b: i32x4) mask4 {
    let x = xi(a);
    let y = xi(b);
    let r = _mm_add_epi32(x, y);
    let o = _mm_and_si128(_mm_xor_si128(x, r), _mm_xor_si128(y, r));
    return (_mm_movemask_ps(_mm_castsi128_ps(o)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Sse2])
fn overflow_sub_i32x4(a: i32x4, b: i32x4) mask4 {
    let x = xi(a);
    let y = xi(b);
    let r = _mm_sub_epi32(x, y);
    let o = _mm_and_si128(_mm_xor_si128(x, y), _mm_xor_si128(x, r));
    return (_mm_movemask_ps(_mm_castsi128_ps(o)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Sse2])
fn overflow_add_u32x4(a: u32x4, b: u32x4) mask4 {
    let x = xi(a);
    let y = xi(b);
    let o = _mm_cmpgt_epi32(
        _mm_xor_si128(x, _mm_set1_epi32(-2147483648)),
        _mm_xor_si128(_mm_add_epi32(x, y), _mm_set1_epi32(-2147483648)),
    );
    return (_mm_movemask_ps(_mm_castsi128_ps(o)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Sse2])
fn overflow_sub_u32x4(a: u32x4, b: u32x4) mask4 {
    let x = xi(a);
    let y = xi(b);
    let o = _mm_cmpgt_epi32(
        _mm_xor_si128(y, _mm_set1_epi32(-2147483648)),
        _mm_xor_si128(x, _mm_set1_epi32(-2147483648)),
    );
    return (_mm_movemask_ps(_mm_castsi128_ps(o)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Sse2])
fn overflow_add_i64x2(a: i64x2, b: i64x2) mask2 {
    let x = xi(a);
    let y = xi(b);
    let r = _mm_add_epi64(x, y);
    let o = _mm_and_si128(_mm_xor_si128(x, r), _mm_xor_si128(y, r));
    return (_mm_movemask_pd(_mm_castsi128_pd(o)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Sse2])
fn overflow_sub_i64x2(a: i64x2, b: i64x2) mask2 {
    let x = xi(a);
    let y = xi(b);
    let r = _mm_sub_epi64(x, y);
    let o = _mm_and_si128(_mm_xor_si128(x, y), _mm_xor_si128(x, r));
    return (_mm_movemask_pd(_mm_castsi128_pd(o)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Sse42])
fn overflow_add_u64x2(a: u64x2, b: u64x2) mask2 {
    let x = xi(a);
    let y = xi(b);
    let o = _mm_cmpgt_epi64(
        _mm_xor_si128(x, _mm_set1_epi64x(-9223372036854775807 - 1)),
        _mm_xor_si128(_mm_add_epi64(x, y), _mm_set1_epi64x(-9223372036854775807 - 1)),
    );
    return (_mm_movemask_pd(_mm_castsi128_pd(o)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Sse42])
fn overflow_sub_u64x2(a: u64x2, b: u64x2) mask2 {
    let x = xi(a);
    let y = xi(b);
    let o = _mm_cmpgt_epi64(
        _mm_xor_si128(y, _mm_set1_epi64x(-9223372036854775807 - 1)),
        _mm_xor_si128(x, _mm_set1_epi64x(-9223372036854775807 - 1)),
    );
    return (_mm_movemask_pd(_mm_castsi128_pd(o)) as u64) as mask2;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Avx2])
fn overflow_add_i8x32(a: i8x32, b: i8x32) mask32 {
    let x = yi(a);
    let y = yi(b);
    let r = _mm256_add_epi8(x, y);
    let o = _mm256_and_si256(_mm256_xor_si256(x, r), _mm256_xor_si256(y, r));
    return (_mm256_movemask_epi8(o) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Avx2])
fn overflow_sub_i8x32(a: i8x32, b: i8x32) mask32 {
    let x = yi(a);
    let y = yi(b);
    let r = _mm256_sub_epi8(x, y);
    let o = _mm256_and_si256(_mm256_xor_si256(x, y), _mm256_xor_si256(x, r));
    return (_mm256_movemask_epi8(o) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Avx2])
fn overflow_add_u8x32(a: u8x32, b: u8x32) mask32 {
    let x = yi(a);
    let y = yi(b);
    let o = _mm256_cmpgt_epi8(
        _mm256_xor_si256(x, _mm256_set1_epi8(-128)),
        _mm256_xor_si256(_mm256_add_epi8(x, y), _mm256_set1_epi8(-128)),
    );
    return (_mm256_movemask_epi8(o) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Avx2])
fn overflow_sub_u8x32(a: u8x32, b: u8x32) mask32 {
    let x = yi(a);
    let y = yi(b);
    let o = _mm256_cmpgt_epi8(_mm256_xor_si256(y, _mm256_set1_epi8(-128)), _mm256_xor_si256(x, _mm256_set1_epi8(-128)));
    return (_mm256_movemask_epi8(o) as u64) as mask32;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Avx2])
fn overflow_add_i16x16(a: i16x16, b: i16x16) mask16 {
    let x = yi(a);
    let y = yi(b);
    let r = _mm256_add_epi16(x, y);
    let o = _mm256_and_si256(_mm256_xor_si256(x, r), _mm256_xor_si256(y, r));
    return (_mm_movemask_epi8(_mm_packs_epi16(_mm256_castsi256_si128(o), unsafe _mm256_extracti128_si256(o, 1))) as u64 & 65535) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Avx2])
fn overflow_sub_i16x16(a: i16x16, b: i16x16) mask16 {
    let x = yi(a);
    let y = yi(b);
    let r = _mm256_sub_epi16(x, y);
    let o = _mm256_and_si256(_mm256_xor_si256(x, y), _mm256_xor_si256(x, r));
    return (_mm_movemask_epi8(_mm_packs_epi16(_mm256_castsi256_si128(o), unsafe _mm256_extracti128_si256(o, 1))) as u64 & 65535) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowMul, [cpu::Feature::Avx2])
fn overflow_mul_i16x16(a: i16x16, b: i16x16) mask16 {
    let x = yi(a);
    let y = yi(b);
    let o = _mm256_xor_si256(_mm256_mulhi_epi16(x, y), _mm256_srai_epi16(_mm256_mullo_epi16(x, y), 15));
    return (_mm_movemask_epi8(
        _mm_packs_epi16(
            _mm256_castsi256_si128(_mm256_cmpeq_epi16(o, _mm256_setzero_si256())),
            unsafe _mm256_extracti128_si256(_mm256_cmpeq_epi16(o, _mm256_setzero_si256()), 1),
        ),
    ) as u64 & 65535 ^ 65535) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Avx2])
fn overflow_add_u16x16(a: u16x16, b: u16x16) mask16 {
    let x = yi(a);
    let y = yi(b);
    let o = _mm256_cmpgt_epi16(
        _mm256_xor_si256(x, _mm256_set1_epi16(-32768)),
        _mm256_xor_si256(_mm256_add_epi16(x, y), _mm256_set1_epi16(-32768)),
    );
    return (_mm_movemask_epi8(_mm_packs_epi16(_mm256_castsi256_si128(o), unsafe _mm256_extracti128_si256(o, 1))) as u64 & 65535) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Avx2])
fn overflow_sub_u16x16(a: u16x16, b: u16x16) mask16 {
    let x = yi(a);
    let y = yi(b);
    let o = _mm256_cmpgt_epi16(
        _mm256_xor_si256(y, _mm256_set1_epi16(-32768)),
        _mm256_xor_si256(x, _mm256_set1_epi16(-32768)),
    );
    return (_mm_movemask_epi8(_mm_packs_epi16(_mm256_castsi256_si128(o), unsafe _mm256_extracti128_si256(o, 1))) as u64 & 65535) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowMul, [cpu::Feature::Avx2])
fn overflow_mul_u16x16(a: u16x16, b: u16x16) mask16 {
    let o = _mm256_mulhi_epu16(yi(a), yi(b));
    return (_mm_movemask_epi8(
        _mm_packs_epi16(
            _mm256_castsi256_si128(_mm256_cmpeq_epi16(o, _mm256_setzero_si256())),
            unsafe _mm256_extracti128_si256(_mm256_cmpeq_epi16(o, _mm256_setzero_si256()), 1),
        ),
    ) as u64 & 65535 ^ 65535) as mask16;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Avx2])
fn overflow_add_i32x8(a: i32x8, b: i32x8) mask8 {
    let x = yi(a);
    let y = yi(b);
    let r = _mm256_add_epi32(x, y);
    let o = _mm256_and_si256(_mm256_xor_si256(x, r), _mm256_xor_si256(y, r));
    return (_mm256_movemask_ps(_mm256_castsi256_ps(o)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Avx2])
fn overflow_sub_i32x8(a: i32x8, b: i32x8) mask8 {
    let x = yi(a);
    let y = yi(b);
    let r = _mm256_sub_epi32(x, y);
    let o = _mm256_and_si256(_mm256_xor_si256(x, y), _mm256_xor_si256(x, r));
    return (_mm256_movemask_ps(_mm256_castsi256_ps(o)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Avx2])
fn overflow_add_u32x8(a: u32x8, b: u32x8) mask8 {
    let x = yi(a);
    let y = yi(b);
    let o = _mm256_cmpgt_epi32(
        _mm256_xor_si256(x, _mm256_set1_epi32(-2147483648)),
        _mm256_xor_si256(_mm256_add_epi32(x, y), _mm256_set1_epi32(-2147483648)),
    );
    return (_mm256_movemask_ps(_mm256_castsi256_ps(o)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Avx2])
fn overflow_sub_u32x8(a: u32x8, b: u32x8) mask8 {
    let x = yi(a);
    let y = yi(b);
    let o = _mm256_cmpgt_epi32(
        _mm256_xor_si256(y, _mm256_set1_epi32(-2147483648)),
        _mm256_xor_si256(x, _mm256_set1_epi32(-2147483648)),
    );
    return (_mm256_movemask_ps(_mm256_castsi256_ps(o)) as u64) as mask8;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Avx2])
fn overflow_add_i64x4(a: i64x4, b: i64x4) mask4 {
    let x = yi(a);
    let y = yi(b);
    let r = _mm256_add_epi64(x, y);
    let o = _mm256_and_si256(_mm256_xor_si256(x, r), _mm256_xor_si256(y, r));
    return (_mm256_movemask_pd(_mm256_castsi256_pd(o)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Avx2])
fn overflow_sub_i64x4(a: i64x4, b: i64x4) mask4 {
    let x = yi(a);
    let y = yi(b);
    let r = _mm256_sub_epi64(x, y);
    let o = _mm256_and_si256(_mm256_xor_si256(x, y), _mm256_xor_si256(x, r));
    return (_mm256_movemask_pd(_mm256_castsi256_pd(o)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowAdd, [cpu::Feature::Avx2])
fn overflow_add_u64x4(a: u64x4, b: u64x4) mask4 {
    let x = yi(a);
    let y = yi(b);
    let o = _mm256_cmpgt_epi64(
        _mm256_xor_si256(x, _mm256_set1_epi64x(-9223372036854775807 - 1)),
        _mm256_xor_si256(_mm256_add_epi64(x, y), _mm256_set1_epi64x(-9223372036854775807 - 1)),
    );
    return (_mm256_movemask_pd(_mm256_castsi256_pd(o)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::OverflowSub, [cpu::Feature::Avx2])
fn overflow_sub_u64x4(a: u64x4, b: u64x4) mask4 {
    let x = yi(a);
    let y = yi(b);
    let o = _mm256_cmpgt_epi64(
        _mm256_xor_si256(y, _mm256_set1_epi64x(-9223372036854775807 - 1)),
        _mm256_xor_si256(x, _mm256_set1_epi64x(-9223372036854775807 - 1)),
    );
    return (_mm256_movemask_pd(_mm256_castsi256_pd(o)) as u64) as mask4;
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Sse2])
fn shl_scalar_i8x16(a: i8x16, n: i8) i8x16 {
    return xiv::<i8, 16>(
        _mm_and_si128(_mm_sll_epi16(xi(a), _mm_cvtsi32_si128(n)), _mm_set1_epi8(((255u32 << n as u32) as u8) as i8)),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Sse2])
fn shr_scalar_i8x16(a: i8x16, n: i8) i8x16 {
    let m = _mm_set1_epi8(((128u32 >> n as u32) as u8) as i8);
    return xiv::<i8, 16>(
        _mm_sub_epi8(
            _mm_xor_si128(
                _mm_and_si128(
                    _mm_srl_epi16(xi(a), _mm_cvtsi32_si128(n)),
                    _mm_set1_epi8(((255u32 >> n as u32) as u8) as i8),
                ),
                m,
            ),
            m,
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Sse2])
fn shl_scalar_u8x16(a: u8x16, n: u8) u8x16 {
    return xiv::<u8, 16>(
        _mm_and_si128(_mm_sll_epi16(xi(a), _mm_cvtsi32_si128(n)), _mm_set1_epi8(((255u32 << n as u32) as u8) as i8)),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Sse2])
fn shr_scalar_u8x16(a: u8x16, n: u8) u8x16 {
    return xiv::<u8, 16>(
        _mm_and_si128(_mm_srl_epi16(xi(a), _mm_cvtsi32_si128(n)), _mm_set1_epi8(((255u32 >> n as u32) as u8) as i8)),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Sse2])
fn shl_scalar_i16x8(a: i16x8, n: i16) i16x8 {
    return xiv::<i16, 8>(_mm_sll_epi16(xi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Sse2])
fn shr_scalar_i16x8(a: i16x8, n: i16) i16x8 {
    return xiv::<i16, 8>(_mm_sra_epi16(xi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx512bw, cpu::Feature::Avx512vl])
fn wrapping_shl_i16x8(a: i16x8, n: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_sllv_epi16(xi(a), _mm_and_si128(xi(n), _mm_set1_epi16(15))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx512bw, cpu::Feature::Avx512vl])
fn wrapping_shr_i16x8(a: i16x8, n: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_srav_epi16(xi(a), _mm_and_si128(xi(n), _mm_set1_epi16(15))));
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Sse2])
fn shl_scalar_u16x8(a: u16x8, n: u16) u16x8 {
    return xiv::<u16, 8>(_mm_sll_epi16(xi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Sse2])
fn shr_scalar_u16x8(a: u16x8, n: u16) u16x8 {
    return xiv::<u16, 8>(_mm_srl_epi16(xi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx512bw, cpu::Feature::Avx512vl])
fn wrapping_shl_u16x8(a: u16x8, n: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_sllv_epi16(xi(a), _mm_and_si128(xi(n), _mm_set1_epi16(15))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx512bw, cpu::Feature::Avx512vl])
fn wrapping_shr_u16x8(a: u16x8, n: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_srlv_epi16(xi(a), _mm_and_si128(xi(n), _mm_set1_epi16(15))));
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Sse2])
fn shl_scalar_i32x4(a: i32x4, n: i32) i32x4 {
    return xiv::<i32, 4>(_mm_sll_epi32(xi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Sse2])
fn shr_scalar_i32x4(a: i32x4, n: i32) i32x4 {
    return xiv::<i32, 4>(_mm_sra_epi32(xi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx2])
fn wrapping_shl_i32x4(a: i32x4, n: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_sllv_epi32(xi(a), _mm_and_si128(xi(n), _mm_set1_epi32(31))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx2])
fn wrapping_shr_i32x4(a: i32x4, n: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_srav_epi32(xi(a), _mm_and_si128(xi(n), _mm_set1_epi32(31))));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateLeft, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn rotate_left_i32x4(a: i32x4, n: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_rolv_epi32(xi(a), xi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateRight, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn rotate_right_i32x4(a: i32x4, n: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_rorv_epi32(xi(a), xi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Sse2])
fn shl_scalar_u32x4(a: u32x4, n: u32) u32x4 {
    return xiv::<u32, 4>(_mm_sll_epi32(xi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Sse2])
fn shr_scalar_u32x4(a: u32x4, n: u32) u32x4 {
    return xiv::<u32, 4>(_mm_srl_epi32(xi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx2])
fn wrapping_shl_u32x4(a: u32x4, n: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_sllv_epi32(xi(a), _mm_and_si128(xi(n), _mm_set1_epi32(31))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx2])
fn wrapping_shr_u32x4(a: u32x4, n: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_srlv_epi32(xi(a), _mm_and_si128(xi(n), _mm_set1_epi32(31))));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateLeft, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn rotate_left_u32x4(a: u32x4, n: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_rolv_epi32(xi(a), xi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateRight, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn rotate_right_u32x4(a: u32x4, n: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_rorv_epi32(xi(a), xi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Sse2])
fn shl_scalar_i64x2(a: i64x2, n: i64) i64x2 {
    return xiv::<i64, 2>(_mm_sll_epi64(xi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn shr_scalar_i64x2(a: i64x2, n: i64) i64x2 {
    return xiv::<i64, 2>(_mm_sra_epi64(xi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Sse2])
fn shr_scalar_i64x2_sse2(a: i64x2, n: i64) i64x2 {
    let m = _mm_set1_epi64x((1u64 << (63 - n) as u64) as i64);
    return xiv::<i64, 2>(_mm_sub_epi64(_mm_xor_si128(_mm_srl_epi64(xi(a), _mm_cvtsi32_si128(n as i32)), m), m));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx2])
fn wrapping_shl_i64x2(a: i64x2, n: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_sllv_epi64(xi(a), _mm_and_si128(xi(n), _mm_set1_epi64x(63))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn wrapping_shr_i64x2(a: i64x2, n: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_srav_epi64(xi(a), _mm_and_si128(xi(n), _mm_set1_epi64x(63))));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateLeft, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn rotate_left_i64x2(a: i64x2, n: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_rolv_epi64(xi(a), xi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateRight, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn rotate_right_i64x2(a: i64x2, n: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_rorv_epi64(xi(a), xi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Sse2])
fn shl_scalar_u64x2(a: u64x2, n: u64) u64x2 {
    return xiv::<u64, 2>(_mm_sll_epi64(xi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Sse2])
fn shr_scalar_u64x2(a: u64x2, n: u64) u64x2 {
    return xiv::<u64, 2>(_mm_srl_epi64(xi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx2])
fn wrapping_shl_u64x2(a: u64x2, n: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_sllv_epi64(xi(a), _mm_and_si128(xi(n), _mm_set1_epi64x(63))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx2])
fn wrapping_shr_u64x2(a: u64x2, n: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_srlv_epi64(xi(a), _mm_and_si128(xi(n), _mm_set1_epi64x(63))));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateLeft, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn rotate_left_u64x2(a: u64x2, n: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_rolv_epi64(xi(a), xi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateRight, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn rotate_right_u64x2(a: u64x2, n: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_rorv_epi64(xi(a), xi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Avx2])
fn shl_scalar_i8x32(a: i8x32, n: i8) i8x32 {
    return yiv::<i8, 32>(
        _mm256_and_si256(
            _mm256_sll_epi16(yi(a), _mm_cvtsi32_si128(n)),
            _mm256_set1_epi8(((255u32 << n as u32) as u8) as i8),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx2])
fn shr_scalar_i8x32(a: i8x32, n: i8) i8x32 {
    let m = _mm256_set1_epi8(((128u32 >> n as u32) as u8) as i8);
    return yiv::<i8, 32>(
        _mm256_sub_epi8(
            _mm256_xor_si256(
                _mm256_and_si256(
                    _mm256_srl_epi16(yi(a), _mm_cvtsi32_si128(n)),
                    _mm256_set1_epi8(((255u32 >> n as u32) as u8) as i8),
                ),
                m,
            ),
            m,
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Avx2])
fn shl_scalar_u8x32(a: u8x32, n: u8) u8x32 {
    return yiv::<u8, 32>(
        _mm256_and_si256(
            _mm256_sll_epi16(yi(a), _mm_cvtsi32_si128(n)),
            _mm256_set1_epi8(((255u32 << n as u32) as u8) as i8),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx2])
fn shr_scalar_u8x32(a: u8x32, n: u8) u8x32 {
    return yiv::<u8, 32>(
        _mm256_and_si256(
            _mm256_srl_epi16(yi(a), _mm_cvtsi32_si128(n)),
            _mm256_set1_epi8(((255u32 >> n as u32) as u8) as i8),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Avx2])
fn shl_scalar_i16x16(a: i16x16, n: i16) i16x16 {
    return yiv::<i16, 16>(_mm256_sll_epi16(yi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx2])
fn shr_scalar_i16x16(a: i16x16, n: i16) i16x16 {
    return yiv::<i16, 16>(_mm256_sra_epi16(yi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx512bw, cpu::Feature::Avx512vl])
fn wrapping_shl_i16x16(a: i16x16, n: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_sllv_epi16(yi(a), _mm256_and_si256(yi(n), _mm256_set1_epi16(15))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx512bw, cpu::Feature::Avx512vl])
fn wrapping_shr_i16x16(a: i16x16, n: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_srav_epi16(yi(a), _mm256_and_si256(yi(n), _mm256_set1_epi16(15))));
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Avx2])
fn shl_scalar_u16x16(a: u16x16, n: u16) u16x16 {
    return yiv::<u16, 16>(_mm256_sll_epi16(yi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx2])
fn shr_scalar_u16x16(a: u16x16, n: u16) u16x16 {
    return yiv::<u16, 16>(_mm256_srl_epi16(yi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx512bw, cpu::Feature::Avx512vl])
fn wrapping_shl_u16x16(a: u16x16, n: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_sllv_epi16(yi(a), _mm256_and_si256(yi(n), _mm256_set1_epi16(15))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx512bw, cpu::Feature::Avx512vl])
fn wrapping_shr_u16x16(a: u16x16, n: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_srlv_epi16(yi(a), _mm256_and_si256(yi(n), _mm256_set1_epi16(15))));
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Avx2])
fn shl_scalar_i32x8(a: i32x8, n: i32) i32x8 {
    return yiv::<i32, 8>(_mm256_sll_epi32(yi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx2])
fn shr_scalar_i32x8(a: i32x8, n: i32) i32x8 {
    return yiv::<i32, 8>(_mm256_sra_epi32(yi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx2])
fn wrapping_shl_i32x8(a: i32x8, n: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_sllv_epi32(yi(a), _mm256_and_si256(yi(n), _mm256_set1_epi32(31))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx2])
fn wrapping_shr_i32x8(a: i32x8, n: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_srav_epi32(yi(a), _mm256_and_si256(yi(n), _mm256_set1_epi32(31))));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateLeft, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn rotate_left_i32x8(a: i32x8, n: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_rolv_epi32(yi(a), yi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateRight, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn rotate_right_i32x8(a: i32x8, n: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_rorv_epi32(yi(a), yi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Avx2])
fn shl_scalar_u32x8(a: u32x8, n: u32) u32x8 {
    return yiv::<u32, 8>(_mm256_sll_epi32(yi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx2])
fn shr_scalar_u32x8(a: u32x8, n: u32) u32x8 {
    return yiv::<u32, 8>(_mm256_srl_epi32(yi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx2])
fn wrapping_shl_u32x8(a: u32x8, n: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_sllv_epi32(yi(a), _mm256_and_si256(yi(n), _mm256_set1_epi32(31))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx2])
fn wrapping_shr_u32x8(a: u32x8, n: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_srlv_epi32(yi(a), _mm256_and_si256(yi(n), _mm256_set1_epi32(31))));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateLeft, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn rotate_left_u32x8(a: u32x8, n: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_rolv_epi32(yi(a), yi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateRight, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn rotate_right_u32x8(a: u32x8, n: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_rorv_epi32(yi(a), yi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Avx2])
fn shl_scalar_i64x4(a: i64x4, n: i64) i64x4 {
    return yiv::<i64, 4>(_mm256_sll_epi64(yi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn shr_scalar_i64x4(a: i64x4, n: i64) i64x4 {
    return yiv::<i64, 4>(_mm256_sra_epi64(yi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx2])
fn shr_scalar_i64x4_avx2(a: i64x4, n: i64) i64x4 {
    let m = _mm256_set1_epi64x((1u64 << (63 - n) as u64) as i64);
    return yiv::<i64, 4>(_mm256_sub_epi64(_mm256_xor_si256(_mm256_srl_epi64(yi(a), _mm_cvtsi32_si128(n as i32)), m), m));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx2])
fn wrapping_shl_i64x4(a: i64x4, n: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_sllv_epi64(yi(a), _mm256_and_si256(yi(n), _mm256_set1_epi64x(63))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn wrapping_shr_i64x4(a: i64x4, n: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_srav_epi64(yi(a), _mm256_and_si256(yi(n), _mm256_set1_epi64x(63))));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateLeft, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn rotate_left_i64x4(a: i64x4, n: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_rolv_epi64(yi(a), yi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateRight, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn rotate_right_i64x4(a: i64x4, n: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_rorv_epi64(yi(a), yi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Avx2])
fn shl_scalar_u64x4(a: u64x4, n: u64) u64x4 {
    return yiv::<u64, 4>(_mm256_sll_epi64(yi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx2])
fn shr_scalar_u64x4(a: u64x4, n: u64) u64x4 {
    return yiv::<u64, 4>(_mm256_srl_epi64(yi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx2])
fn wrapping_shl_u64x4(a: u64x4, n: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_sllv_epi64(yi(a), _mm256_and_si256(yi(n), _mm256_set1_epi64x(63))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx2])
fn wrapping_shr_u64x4(a: u64x4, n: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_srlv_epi64(yi(a), _mm256_and_si256(yi(n), _mm256_set1_epi64x(63))));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateLeft, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn rotate_left_u64x4(a: u64x4, n: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_rolv_epi64(yi(a), yi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateRight, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn rotate_right_u64x4(a: u64x4, n: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_rorv_epi64(yi(a), yi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Avx512bw])
fn shl_scalar_i8x64(a: i8x64, n: i8) i8x64 {
    return ziv::<i8, 64>(
        _mm512_and_si512(
            _mm512_sll_epi16(zi(a), _mm_cvtsi32_si128(n)),
            _mm512_set1_epi8(((255u32 << n as u32) as u8) as i8),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx512bw])
fn shr_scalar_i8x64(a: i8x64, n: i8) i8x64 {
    let m = _mm512_set1_epi8(((128u32 >> n as u32) as u8) as i8);
    return ziv::<i8, 64>(
        _mm512_sub_epi8(
            _mm512_xor_si512(
                _mm512_and_si512(
                    _mm512_srl_epi16(zi(a), _mm_cvtsi32_si128(n)),
                    _mm512_set1_epi8(((255u32 >> n as u32) as u8) as i8),
                ),
                m,
            ),
            m,
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Avx512bw])
fn shl_scalar_u8x64(a: u8x64, n: u8) u8x64 {
    return ziv::<u8, 64>(
        _mm512_and_si512(
            _mm512_sll_epi16(zi(a), _mm_cvtsi32_si128(n)),
            _mm512_set1_epi8(((255u32 << n as u32) as u8) as i8),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx512bw])
fn shr_scalar_u8x64(a: u8x64, n: u8) u8x64 {
    return ziv::<u8, 64>(
        _mm512_and_si512(
            _mm512_srl_epi16(zi(a), _mm_cvtsi32_si128(n)),
            _mm512_set1_epi8(((255u32 >> n as u32) as u8) as i8),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Avx512bw])
fn shl_scalar_i16x32(a: i16x32, n: i16) i16x32 {
    return ziv::<i16, 32>(_mm512_sll_epi16(zi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx512bw])
fn shr_scalar_i16x32(a: i16x32, n: i16) i16x32 {
    return ziv::<i16, 32>(_mm512_sra_epi16(zi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx512bw])
fn wrapping_shl_i16x32(a: i16x32, n: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_sllv_epi16(zi(a), _mm512_and_si512(zi(n), _mm512_set1_epi16(15))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx512bw])
fn wrapping_shr_i16x32(a: i16x32, n: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_srav_epi16(zi(a), _mm512_and_si512(zi(n), _mm512_set1_epi16(15))));
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Avx512bw])
fn shl_scalar_u16x32(a: u16x32, n: u16) u16x32 {
    return ziv::<u16, 32>(_mm512_sll_epi16(zi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx512bw])
fn shr_scalar_u16x32(a: u16x32, n: u16) u16x32 {
    return ziv::<u16, 32>(_mm512_srl_epi16(zi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx512bw])
fn wrapping_shl_u16x32(a: u16x32, n: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_sllv_epi16(zi(a), _mm512_and_si512(zi(n), _mm512_set1_epi16(15))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx512bw])
fn wrapping_shr_u16x32(a: u16x32, n: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_srlv_epi16(zi(a), _mm512_and_si512(zi(n), _mm512_set1_epi16(15))));
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Avx512f])
fn shl_scalar_i32x16(a: i32x16, n: i32) i32x16 {
    return ziv::<i32, 16>(_mm512_sll_epi32(zi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx512f])
fn shr_scalar_i32x16(a: i32x16, n: i32) i32x16 {
    return ziv::<i32, 16>(_mm512_sra_epi32(zi(a), _mm_cvtsi32_si128(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx512f])
fn wrapping_shl_i32x16(a: i32x16, n: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_sllv_epi32(zi(a), _mm512_and_si512(zi(n), _mm512_set1_epi32(31))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx512f])
fn wrapping_shr_i32x16(a: i32x16, n: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_srav_epi32(zi(a), _mm512_and_si512(zi(n), _mm512_set1_epi32(31))));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateLeft, [cpu::Feature::Avx512f])
fn rotate_left_i32x16(a: i32x16, n: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_rolv_epi32(zi(a), zi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateRight, [cpu::Feature::Avx512f])
fn rotate_right_i32x16(a: i32x16, n: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_rorv_epi32(zi(a), zi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Avx512f])
fn shl_scalar_u32x16(a: u32x16, n: u32) u32x16 {
    return ziv::<u32, 16>(_mm512_sll_epi32(zi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx512f])
fn shr_scalar_u32x16(a: u32x16, n: u32) u32x16 {
    return ziv::<u32, 16>(_mm512_srl_epi32(zi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx512f])
fn wrapping_shl_u32x16(a: u32x16, n: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_sllv_epi32(zi(a), _mm512_and_si512(zi(n), _mm512_set1_epi32(31))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx512f])
fn wrapping_shr_u32x16(a: u32x16, n: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_srlv_epi32(zi(a), _mm512_and_si512(zi(n), _mm512_set1_epi32(31))));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateLeft, [cpu::Feature::Avx512f])
fn rotate_left_u32x16(a: u32x16, n: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_rolv_epi32(zi(a), zi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateRight, [cpu::Feature::Avx512f])
fn rotate_right_u32x16(a: u32x16, n: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_rorv_epi32(zi(a), zi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Avx512f])
fn shl_scalar_i64x8(a: i64x8, n: i64) i64x8 {
    return ziv::<i64, 8>(_mm512_sll_epi64(zi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx512f])
fn shr_scalar_i64x8(a: i64x8, n: i64) i64x8 {
    return ziv::<i64, 8>(_mm512_sra_epi64(zi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx512f])
fn wrapping_shl_i64x8(a: i64x8, n: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_sllv_epi64(zi(a), _mm512_and_si512(zi(n), _mm512_set1_epi64(63))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx512f])
fn wrapping_shr_i64x8(a: i64x8, n: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_srav_epi64(zi(a), _mm512_and_si512(zi(n), _mm512_set1_epi64(63))));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateLeft, [cpu::Feature::Avx512f])
fn rotate_left_i64x8(a: i64x8, n: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_rolv_epi64(zi(a), zi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateRight, [cpu::Feature::Avx512f])
fn rotate_right_i64x8(a: i64x8, n: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_rorv_epi64(zi(a), zi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShlScalar, [cpu::Feature::Avx512f])
fn shl_scalar_u64x8(a: u64x8, n: u64) u64x8 {
    return ziv::<u64, 8>(_mm512_sll_epi64(zi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::ShrScalar, [cpu::Feature::Avx512f])
fn shr_scalar_u64x8(a: u64x8, n: u64) u64x8 {
    return ziv::<u64, 8>(_mm512_srl_epi64(zi(a), _mm_cvtsi32_si128(n as i32)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShl, [cpu::Feature::Avx512f])
fn wrapping_shl_u64x8(a: u64x8, n: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_sllv_epi64(zi(a), _mm512_and_si512(zi(n), _mm512_set1_epi64(63))));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx512f])
fn wrapping_shr_u64x8(a: u64x8, n: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_srlv_epi64(zi(a), _mm512_and_si512(zi(n), _mm512_set1_epi64(63))));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateLeft, [cpu::Feature::Avx512f])
fn rotate_left_u64x8(a: u64x8, n: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_rolv_epi64(zi(a), zi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::RotateRight, [cpu::Feature::Avx512f])
fn rotate_right_u64x8(a: u64x8, n: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_rorv_epi64(zi(a), zi(n)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512bitalg, cpu::Feature::Avx512vl])
fn count_ones_i8x16(a: i8x16) i8x16 {
    return xiv::<i8, 16>(_mm_popcnt_epi8(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Ssse3])
fn count_ones_i8x16_ssse3(a: i8x16) i8x16 {
    let x = xi(a);
    let lo = _mm_set1_epi8(15);
    let tab = _mm_setr_epi8(0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4);
    let c = _mm_add_epi8(
        _mm_shuffle_epi8(tab, _mm_and_si128(x, lo)),
        _mm_shuffle_epi8(tab, _mm_and_si128(_mm_srli_epi16(x, 4), lo)),
    );
    return xiv::<i8, 16>(c);
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512bitalg, cpu::Feature::Avx512vl])
fn count_ones_u8x16(a: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_popcnt_epi8(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Ssse3])
fn count_ones_u8x16_ssse3(a: u8x16) u8x16 {
    let x = xi(a);
    let lo = _mm_set1_epi8(15);
    let tab = _mm_setr_epi8(0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4);
    let c = _mm_add_epi8(
        _mm_shuffle_epi8(tab, _mm_and_si128(x, lo)),
        _mm_shuffle_epi8(tab, _mm_and_si128(_mm_srli_epi16(x, 4), lo)),
    );
    return xiv::<u8, 16>(c);
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512bitalg, cpu::Feature::Avx512vl])
fn count_ones_i16x8(a: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_popcnt_epi16(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Ssse3])
fn count_ones_i16x8_ssse3(a: i16x8) i16x8 {
    let x = xi(a);
    let lo = _mm_set1_epi8(15);
    let tab = _mm_setr_epi8(0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4);
    let c = _mm_add_epi8(
        _mm_shuffle_epi8(tab, _mm_and_si128(x, lo)),
        _mm_shuffle_epi8(tab, _mm_and_si128(_mm_srli_epi16(x, 4), lo)),
    );
    return xiv::<i16, 8>(_mm_add_epi16(_mm_and_si128(c, _mm_set1_epi16(255)), _mm_srli_epi16(c, 8)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512bitalg, cpu::Feature::Avx512vl])
fn count_ones_u16x8(a: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_popcnt_epi16(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Ssse3])
fn count_ones_u16x8_ssse3(a: u16x8) u16x8 {
    let x = xi(a);
    let lo = _mm_set1_epi8(15);
    let tab = _mm_setr_epi8(0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4);
    let c = _mm_add_epi8(
        _mm_shuffle_epi8(tab, _mm_and_si128(x, lo)),
        _mm_shuffle_epi8(tab, _mm_and_si128(_mm_srli_epi16(x, 4), lo)),
    );
    return xiv::<u16, 8>(_mm_add_epi16(_mm_and_si128(c, _mm_set1_epi16(255)), _mm_srli_epi16(c, 8)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512vpopcntdq, cpu::Feature::Avx512vl])
fn count_ones_i32x4(a: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_popcnt_epi32(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::LeadingZeros, [cpu::Feature::Avx512cd, cpu::Feature::Avx512vl])
fn leading_zeros_i32x4(a: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_lzcnt_epi32(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Ssse3])
fn count_ones_i32x4_ssse3(a: i32x4) i32x4 {
    let x = xi(a);
    let lo = _mm_set1_epi8(15);
    let tab = _mm_setr_epi8(0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4);
    let c = _mm_add_epi8(
        _mm_shuffle_epi8(tab, _mm_and_si128(x, lo)),
        _mm_shuffle_epi8(tab, _mm_and_si128(_mm_srli_epi16(x, 4), lo)),
    );
    let h = _mm_add_epi16(_mm_and_si128(c, _mm_set1_epi16(255)), _mm_srli_epi16(c, 8));
    return xiv::<i32, 4>(_mm_add_epi32(_mm_and_si128(h, _mm_set1_epi32(65535)), _mm_srli_epi32(h, 16)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512vpopcntdq, cpu::Feature::Avx512vl])
fn count_ones_u32x4(a: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_popcnt_epi32(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::LeadingZeros, [cpu::Feature::Avx512cd, cpu::Feature::Avx512vl])
fn leading_zeros_u32x4(a: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_lzcnt_epi32(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Ssse3])
fn count_ones_u32x4_ssse3(a: u32x4) u32x4 {
    let x = xi(a);
    let lo = _mm_set1_epi8(15);
    let tab = _mm_setr_epi8(0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4);
    let c = _mm_add_epi8(
        _mm_shuffle_epi8(tab, _mm_and_si128(x, lo)),
        _mm_shuffle_epi8(tab, _mm_and_si128(_mm_srli_epi16(x, 4), lo)),
    );
    let h = _mm_add_epi16(_mm_and_si128(c, _mm_set1_epi16(255)), _mm_srli_epi16(c, 8));
    return xiv::<u32, 4>(_mm_add_epi32(_mm_and_si128(h, _mm_set1_epi32(65535)), _mm_srli_epi32(h, 16)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512vpopcntdq, cpu::Feature::Avx512vl])
fn count_ones_i64x2(a: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_popcnt_epi64(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::LeadingZeros, [cpu::Feature::Avx512cd, cpu::Feature::Avx512vl])
fn leading_zeros_i64x2(a: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_lzcnt_epi64(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Ssse3])
fn count_ones_i64x2_ssse3(a: i64x2) i64x2 {
    let x = xi(a);
    let lo = _mm_set1_epi8(15);
    let tab = _mm_setr_epi8(0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4);
    let c = _mm_add_epi8(
        _mm_shuffle_epi8(tab, _mm_and_si128(x, lo)),
        _mm_shuffle_epi8(tab, _mm_and_si128(_mm_srli_epi16(x, 4), lo)),
    );
    return xiv::<i64, 2>(_mm_sad_epu8(c, _mm_setzero_si128()));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512vpopcntdq, cpu::Feature::Avx512vl])
fn count_ones_u64x2(a: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_popcnt_epi64(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::LeadingZeros, [cpu::Feature::Avx512cd, cpu::Feature::Avx512vl])
fn leading_zeros_u64x2(a: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_lzcnt_epi64(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Ssse3])
fn count_ones_u64x2_ssse3(a: u64x2) u64x2 {
    let x = xi(a);
    let lo = _mm_set1_epi8(15);
    let tab = _mm_setr_epi8(0, 1, 1, 2, 1, 2, 2, 3, 1, 2, 2, 3, 2, 3, 3, 4);
    let c = _mm_add_epi8(
        _mm_shuffle_epi8(tab, _mm_and_si128(x, lo)),
        _mm_shuffle_epi8(tab, _mm_and_si128(_mm_srli_epi16(x, 4), lo)),
    );
    return xiv::<u64, 2>(_mm_sad_epu8(c, _mm_setzero_si128()));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512bitalg, cpu::Feature::Avx512vl])
fn count_ones_i8x32(a: i8x32) i8x32 {
    return yiv::<i8, 32>(_mm256_popcnt_epi8(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx2])
fn count_ones_i8x32_avx2(a: i8x32) i8x32 {
    let x = yi(a);
    let lo = _mm256_set1_epi8(15);
    let tab = _mm256_setr_epi8(
        0,
        1,
        1,
        2,
        1,
        2,
        2,
        3,
        1,
        2,
        2,
        3,
        2,
        3,
        3,
        4,
        0,
        1,
        1,
        2,
        1,
        2,
        2,
        3,
        1,
        2,
        2,
        3,
        2,
        3,
        3,
        4,
    );
    let c = _mm256_add_epi8(
        _mm256_shuffle_epi8(tab, _mm256_and_si256(x, lo)),
        _mm256_shuffle_epi8(tab, _mm256_and_si256(_mm256_srli_epi16(x, 4), lo)),
    );
    return yiv::<i8, 32>(c);
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512bitalg, cpu::Feature::Avx512vl])
fn count_ones_u8x32(a: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_popcnt_epi8(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx2])
fn count_ones_u8x32_avx2(a: u8x32) u8x32 {
    let x = yi(a);
    let lo = _mm256_set1_epi8(15);
    let tab = _mm256_setr_epi8(
        0,
        1,
        1,
        2,
        1,
        2,
        2,
        3,
        1,
        2,
        2,
        3,
        2,
        3,
        3,
        4,
        0,
        1,
        1,
        2,
        1,
        2,
        2,
        3,
        1,
        2,
        2,
        3,
        2,
        3,
        3,
        4,
    );
    let c = _mm256_add_epi8(
        _mm256_shuffle_epi8(tab, _mm256_and_si256(x, lo)),
        _mm256_shuffle_epi8(tab, _mm256_and_si256(_mm256_srli_epi16(x, 4), lo)),
    );
    return yiv::<u8, 32>(c);
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512bitalg, cpu::Feature::Avx512vl])
fn count_ones_i16x16(a: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_popcnt_epi16(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx2])
fn count_ones_i16x16_avx2(a: i16x16) i16x16 {
    let x = yi(a);
    let lo = _mm256_set1_epi8(15);
    let tab = _mm256_setr_epi8(
        0,
        1,
        1,
        2,
        1,
        2,
        2,
        3,
        1,
        2,
        2,
        3,
        2,
        3,
        3,
        4,
        0,
        1,
        1,
        2,
        1,
        2,
        2,
        3,
        1,
        2,
        2,
        3,
        2,
        3,
        3,
        4,
    );
    let c = _mm256_add_epi8(
        _mm256_shuffle_epi8(tab, _mm256_and_si256(x, lo)),
        _mm256_shuffle_epi8(tab, _mm256_and_si256(_mm256_srli_epi16(x, 4), lo)),
    );
    return yiv::<i16, 16>(_mm256_add_epi16(_mm256_and_si256(c, _mm256_set1_epi16(255)), _mm256_srli_epi16(c, 8)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512bitalg, cpu::Feature::Avx512vl])
fn count_ones_u16x16(a: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_popcnt_epi16(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx2])
fn count_ones_u16x16_avx2(a: u16x16) u16x16 {
    let x = yi(a);
    let lo = _mm256_set1_epi8(15);
    let tab = _mm256_setr_epi8(
        0,
        1,
        1,
        2,
        1,
        2,
        2,
        3,
        1,
        2,
        2,
        3,
        2,
        3,
        3,
        4,
        0,
        1,
        1,
        2,
        1,
        2,
        2,
        3,
        1,
        2,
        2,
        3,
        2,
        3,
        3,
        4,
    );
    let c = _mm256_add_epi8(
        _mm256_shuffle_epi8(tab, _mm256_and_si256(x, lo)),
        _mm256_shuffle_epi8(tab, _mm256_and_si256(_mm256_srli_epi16(x, 4), lo)),
    );
    return yiv::<u16, 16>(_mm256_add_epi16(_mm256_and_si256(c, _mm256_set1_epi16(255)), _mm256_srli_epi16(c, 8)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512vpopcntdq, cpu::Feature::Avx512vl])
fn count_ones_i32x8(a: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_popcnt_epi32(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::LeadingZeros, [cpu::Feature::Avx512cd, cpu::Feature::Avx512vl])
fn leading_zeros_i32x8(a: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_lzcnt_epi32(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx2])
fn count_ones_i32x8_avx2(a: i32x8) i32x8 {
    let x = yi(a);
    let lo = _mm256_set1_epi8(15);
    let tab = _mm256_setr_epi8(
        0,
        1,
        1,
        2,
        1,
        2,
        2,
        3,
        1,
        2,
        2,
        3,
        2,
        3,
        3,
        4,
        0,
        1,
        1,
        2,
        1,
        2,
        2,
        3,
        1,
        2,
        2,
        3,
        2,
        3,
        3,
        4,
    );
    let c = _mm256_add_epi8(
        _mm256_shuffle_epi8(tab, _mm256_and_si256(x, lo)),
        _mm256_shuffle_epi8(tab, _mm256_and_si256(_mm256_srli_epi16(x, 4), lo)),
    );
    let h = _mm256_add_epi16(_mm256_and_si256(c, _mm256_set1_epi16(255)), _mm256_srli_epi16(c, 8));
    return yiv::<i32, 8>(_mm256_add_epi32(_mm256_and_si256(h, _mm256_set1_epi32(65535)), _mm256_srli_epi32(h, 16)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512vpopcntdq, cpu::Feature::Avx512vl])
fn count_ones_u32x8(a: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_popcnt_epi32(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::LeadingZeros, [cpu::Feature::Avx512cd, cpu::Feature::Avx512vl])
fn leading_zeros_u32x8(a: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_lzcnt_epi32(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx2])
fn count_ones_u32x8_avx2(a: u32x8) u32x8 {
    let x = yi(a);
    let lo = _mm256_set1_epi8(15);
    let tab = _mm256_setr_epi8(
        0,
        1,
        1,
        2,
        1,
        2,
        2,
        3,
        1,
        2,
        2,
        3,
        2,
        3,
        3,
        4,
        0,
        1,
        1,
        2,
        1,
        2,
        2,
        3,
        1,
        2,
        2,
        3,
        2,
        3,
        3,
        4,
    );
    let c = _mm256_add_epi8(
        _mm256_shuffle_epi8(tab, _mm256_and_si256(x, lo)),
        _mm256_shuffle_epi8(tab, _mm256_and_si256(_mm256_srli_epi16(x, 4), lo)),
    );
    let h = _mm256_add_epi16(_mm256_and_si256(c, _mm256_set1_epi16(255)), _mm256_srli_epi16(c, 8));
    return yiv::<u32, 8>(_mm256_add_epi32(_mm256_and_si256(h, _mm256_set1_epi32(65535)), _mm256_srli_epi32(h, 16)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512vpopcntdq, cpu::Feature::Avx512vl])
fn count_ones_i64x4(a: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_popcnt_epi64(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::LeadingZeros, [cpu::Feature::Avx512cd, cpu::Feature::Avx512vl])
fn leading_zeros_i64x4(a: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_lzcnt_epi64(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx2])
fn count_ones_i64x4_avx2(a: i64x4) i64x4 {
    let x = yi(a);
    let lo = _mm256_set1_epi8(15);
    let tab = _mm256_setr_epi8(
        0,
        1,
        1,
        2,
        1,
        2,
        2,
        3,
        1,
        2,
        2,
        3,
        2,
        3,
        3,
        4,
        0,
        1,
        1,
        2,
        1,
        2,
        2,
        3,
        1,
        2,
        2,
        3,
        2,
        3,
        3,
        4,
    );
    let c = _mm256_add_epi8(
        _mm256_shuffle_epi8(tab, _mm256_and_si256(x, lo)),
        _mm256_shuffle_epi8(tab, _mm256_and_si256(_mm256_srli_epi16(x, 4), lo)),
    );
    return yiv::<i64, 4>(_mm256_sad_epu8(c, _mm256_setzero_si256()));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512vpopcntdq, cpu::Feature::Avx512vl])
fn count_ones_u64x4(a: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_popcnt_epi64(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::LeadingZeros, [cpu::Feature::Avx512cd, cpu::Feature::Avx512vl])
fn leading_zeros_u64x4(a: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_lzcnt_epi64(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx2])
fn count_ones_u64x4_avx2(a: u64x4) u64x4 {
    let x = yi(a);
    let lo = _mm256_set1_epi8(15);
    let tab = _mm256_setr_epi8(
        0,
        1,
        1,
        2,
        1,
        2,
        2,
        3,
        1,
        2,
        2,
        3,
        2,
        3,
        3,
        4,
        0,
        1,
        1,
        2,
        1,
        2,
        2,
        3,
        1,
        2,
        2,
        3,
        2,
        3,
        3,
        4,
    );
    let c = _mm256_add_epi8(
        _mm256_shuffle_epi8(tab, _mm256_and_si256(x, lo)),
        _mm256_shuffle_epi8(tab, _mm256_and_si256(_mm256_srli_epi16(x, 4), lo)),
    );
    return yiv::<u64, 4>(_mm256_sad_epu8(c, _mm256_setzero_si256()));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512bitalg])
fn count_ones_i8x64(a: i8x64) i8x64 {
    return ziv::<i8, 64>(_mm512_popcnt_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512bitalg])
fn count_ones_u8x64(a: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_popcnt_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512bitalg])
fn count_ones_i16x32(a: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_popcnt_epi16(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512bitalg])
fn count_ones_u16x32(a: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_popcnt_epi16(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512vpopcntdq])
fn count_ones_i32x16(a: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_popcnt_epi32(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::LeadingZeros, [cpu::Feature::Avx512cd])
fn leading_zeros_i32x16(a: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_lzcnt_epi32(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512vpopcntdq])
fn count_ones_u32x16(a: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_popcnt_epi32(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::LeadingZeros, [cpu::Feature::Avx512cd])
fn leading_zeros_u32x16(a: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_lzcnt_epi32(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512vpopcntdq])
fn count_ones_i64x8(a: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_popcnt_epi64(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::LeadingZeros, [cpu::Feature::Avx512cd])
fn leading_zeros_i64x8(a: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_lzcnt_epi64(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::CountOnes, [cpu::Feature::Avx512vpopcntdq])
fn count_ones_u64x8(a: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_popcnt_epi64(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::LeadingZeros, [cpu::Feature::Avx512cd])
fn leading_zeros_u64x8(a: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_lzcnt_epi64(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Sse2])
fn min_f32x4(a: f32x4, b: f32x4) f32x4 {
    let x = xf(a);
    let y = xf(b);
    let r = _mm_or_ps(
        _mm_and_ps(_mm_cmpeq_ps(x, y), _mm_or_ps(x, y)),
        _mm_andnot_ps(_mm_cmpeq_ps(x, y), _mm_min_ps(x, y)),
    );
    let xq = _mm_or_ps(x, _mm_and_ps(_mm_cmpunord_ps(x, x), _mm_castsi128_ps(_mm_set1_epi32(0x00400000))));
    return xfv::<f32, 4>(_mm_or_ps(_mm_and_ps(_mm_cmpunord_ps(y, y), xq), _mm_andnot_ps(_mm_cmpunord_ps(y, y), r)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Sse2])
fn max_f32x4(a: f32x4, b: f32x4) f32x4 {
    let x = xf(a);
    let y = xf(b);
    let r = _mm_or_ps(
        _mm_and_ps(_mm_cmpeq_ps(x, y), _mm_and_ps(x, y)),
        _mm_andnot_ps(_mm_cmpeq_ps(x, y), _mm_max_ps(x, y)),
    );
    let xq = _mm_or_ps(x, _mm_and_ps(_mm_cmpunord_ps(x, x), _mm_castsi128_ps(_mm_set1_epi32(0x00400000))));
    return xfv::<f32, 4>(_mm_or_ps(_mm_and_ps(_mm_cmpunord_ps(y, y), xq), _mm_andnot_ps(_mm_cmpunord_ps(y, y), r)));
}

@arch(x86_64)
@simd_impl(simd::Op::Minimum, [cpu::Feature::Sse2])
fn minimum_f32x4(a: f32x4, b: f32x4) f32x4 {
    let x = xf(a);
    let y = xf(b);
    let r = _mm_or_ps(
        _mm_and_ps(_mm_cmpeq_ps(x, y), _mm_or_ps(x, y)),
        _mm_andnot_ps(_mm_cmpeq_ps(x, y), _mm_min_ps(x, y)),
    );
    return xfv::<f32, 4>(_mm_or_ps(r, _mm_cmpunord_ps(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Maximum, [cpu::Feature::Sse2])
fn maximum_f32x4(a: f32x4, b: f32x4) f32x4 {
    let x = xf(a);
    let y = xf(b);
    let r = _mm_or_ps(
        _mm_and_ps(_mm_cmpeq_ps(x, y), _mm_and_ps(x, y)),
        _mm_andnot_ps(_mm_cmpeq_ps(x, y), _mm_max_ps(x, y)),
    );
    return xfv::<f32, 4>(_mm_or_ps(r, _mm_cmpunord_ps(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Sse2])
fn min_f64x2(a: f64x2, b: f64x2) f64x2 {
    let x = xd(a);
    let y = xd(b);
    let r = _mm_or_pd(
        _mm_and_pd(_mm_cmpeq_pd(x, y), _mm_or_pd(x, y)),
        _mm_andnot_pd(_mm_cmpeq_pd(x, y), _mm_min_pd(x, y)),
    );
    let xq = _mm_or_pd(x, _mm_and_pd(_mm_cmpunord_pd(x, x), _mm_castsi128_pd(_mm_set1_epi64x(0x0008000000000000))));
    return xdv::<f64, 2>(_mm_or_pd(_mm_and_pd(_mm_cmpunord_pd(y, y), xq), _mm_andnot_pd(_mm_cmpunord_pd(y, y), r)));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Sse2])
fn max_f64x2(a: f64x2, b: f64x2) f64x2 {
    let x = xd(a);
    let y = xd(b);
    let r = _mm_or_pd(
        _mm_and_pd(_mm_cmpeq_pd(x, y), _mm_and_pd(x, y)),
        _mm_andnot_pd(_mm_cmpeq_pd(x, y), _mm_max_pd(x, y)),
    );
    let xq = _mm_or_pd(x, _mm_and_pd(_mm_cmpunord_pd(x, x), _mm_castsi128_pd(_mm_set1_epi64x(0x0008000000000000))));
    return xdv::<f64, 2>(_mm_or_pd(_mm_and_pd(_mm_cmpunord_pd(y, y), xq), _mm_andnot_pd(_mm_cmpunord_pd(y, y), r)));
}

@arch(x86_64)
@simd_impl(simd::Op::Minimum, [cpu::Feature::Sse2])
fn minimum_f64x2(a: f64x2, b: f64x2) f64x2 {
    let x = xd(a);
    let y = xd(b);
    let r = _mm_or_pd(
        _mm_and_pd(_mm_cmpeq_pd(x, y), _mm_or_pd(x, y)),
        _mm_andnot_pd(_mm_cmpeq_pd(x, y), _mm_min_pd(x, y)),
    );
    return xdv::<f64, 2>(_mm_or_pd(r, _mm_cmpunord_pd(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Maximum, [cpu::Feature::Sse2])
fn maximum_f64x2(a: f64x2, b: f64x2) f64x2 {
    let x = xd(a);
    let y = xd(b);
    let r = _mm_or_pd(
        _mm_and_pd(_mm_cmpeq_pd(x, y), _mm_and_pd(x, y)),
        _mm_andnot_pd(_mm_cmpeq_pd(x, y), _mm_max_pd(x, y)),
    );
    return xdv::<f64, 2>(_mm_or_pd(r, _mm_cmpunord_pd(x, y)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx])
fn min_f32x8(a: f32x8, b: f32x8) f32x8 {
    let x = yf(a);
    let y = yf(b);
    let r = _mm256_or_ps(
        _mm256_and_ps(unsafe _mm256_cmp_ps(x, y, 0), _mm256_or_ps(x, y)),
        _mm256_andnot_ps(unsafe _mm256_cmp_ps(x, y, 0), _mm256_min_ps(x, y)),
    );
    let xq = _mm256_or_ps(
        x,
        _mm256_and_ps(unsafe _mm256_cmp_ps(x, x, 3), _mm256_castsi256_ps(_mm256_set1_epi32(0x00400000))),
    );
    return yfv::<f32, 8>(
        _mm256_or_ps(
            _mm256_and_ps(unsafe _mm256_cmp_ps(y, y, 3), xq),
            _mm256_andnot_ps(unsafe _mm256_cmp_ps(y, y, 3), r),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx])
fn max_f32x8(a: f32x8, b: f32x8) f32x8 {
    let x = yf(a);
    let y = yf(b);
    let r = _mm256_or_ps(
        _mm256_and_ps(unsafe _mm256_cmp_ps(x, y, 0), _mm256_and_ps(x, y)),
        _mm256_andnot_ps(unsafe _mm256_cmp_ps(x, y, 0), _mm256_max_ps(x, y)),
    );
    let xq = _mm256_or_ps(
        x,
        _mm256_and_ps(unsafe _mm256_cmp_ps(x, x, 3), _mm256_castsi256_ps(_mm256_set1_epi32(0x00400000))),
    );
    return yfv::<f32, 8>(
        _mm256_or_ps(
            _mm256_and_ps(unsafe _mm256_cmp_ps(y, y, 3), xq),
            _mm256_andnot_ps(unsafe _mm256_cmp_ps(y, y, 3), r),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Minimum, [cpu::Feature::Avx])
fn minimum_f32x8(a: f32x8, b: f32x8) f32x8 {
    let x = yf(a);
    let y = yf(b);
    let r = _mm256_or_ps(
        _mm256_and_ps(unsafe _mm256_cmp_ps(x, y, 0), _mm256_or_ps(x, y)),
        _mm256_andnot_ps(unsafe _mm256_cmp_ps(x, y, 0), _mm256_min_ps(x, y)),
    );
    return yfv::<f32, 8>(_mm256_or_ps(r, unsafe _mm256_cmp_ps(x, y, 3)));
}

@arch(x86_64)
@simd_impl(simd::Op::Maximum, [cpu::Feature::Avx])
fn maximum_f32x8(a: f32x8, b: f32x8) f32x8 {
    let x = yf(a);
    let y = yf(b);
    let r = _mm256_or_ps(
        _mm256_and_ps(unsafe _mm256_cmp_ps(x, y, 0), _mm256_and_ps(x, y)),
        _mm256_andnot_ps(unsafe _mm256_cmp_ps(x, y, 0), _mm256_max_ps(x, y)),
    );
    return yfv::<f32, 8>(_mm256_or_ps(r, unsafe _mm256_cmp_ps(x, y, 3)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx])
fn min_f64x4(a: f64x4, b: f64x4) f64x4 {
    let x = yd(a);
    let y = yd(b);
    let r = _mm256_or_pd(
        _mm256_and_pd(unsafe _mm256_cmp_pd(x, y, 0), _mm256_or_pd(x, y)),
        _mm256_andnot_pd(unsafe _mm256_cmp_pd(x, y, 0), _mm256_min_pd(x, y)),
    );
    let xq = _mm256_or_pd(
        x,
        _mm256_and_pd(unsafe _mm256_cmp_pd(x, x, 3), _mm256_castsi256_pd(_mm256_set1_epi64x(0x0008000000000000))),
    );
    return ydv::<f64, 4>(
        _mm256_or_pd(
            _mm256_and_pd(unsafe _mm256_cmp_pd(y, y, 3), xq),
            _mm256_andnot_pd(unsafe _mm256_cmp_pd(y, y, 3), r),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx])
fn max_f64x4(a: f64x4, b: f64x4) f64x4 {
    let x = yd(a);
    let y = yd(b);
    let r = _mm256_or_pd(
        _mm256_and_pd(unsafe _mm256_cmp_pd(x, y, 0), _mm256_and_pd(x, y)),
        _mm256_andnot_pd(unsafe _mm256_cmp_pd(x, y, 0), _mm256_max_pd(x, y)),
    );
    let xq = _mm256_or_pd(
        x,
        _mm256_and_pd(unsafe _mm256_cmp_pd(x, x, 3), _mm256_castsi256_pd(_mm256_set1_epi64x(0x0008000000000000))),
    );
    return ydv::<f64, 4>(
        _mm256_or_pd(
            _mm256_and_pd(unsafe _mm256_cmp_pd(y, y, 3), xq),
            _mm256_andnot_pd(unsafe _mm256_cmp_pd(y, y, 3), r),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Minimum, [cpu::Feature::Avx])
fn minimum_f64x4(a: f64x4, b: f64x4) f64x4 {
    let x = yd(a);
    let y = yd(b);
    let r = _mm256_or_pd(
        _mm256_and_pd(unsafe _mm256_cmp_pd(x, y, 0), _mm256_or_pd(x, y)),
        _mm256_andnot_pd(unsafe _mm256_cmp_pd(x, y, 0), _mm256_min_pd(x, y)),
    );
    return ydv::<f64, 4>(_mm256_or_pd(r, unsafe _mm256_cmp_pd(x, y, 3)));
}

@arch(x86_64)
@simd_impl(simd::Op::Maximum, [cpu::Feature::Avx])
fn maximum_f64x4(a: f64x4, b: f64x4) f64x4 {
    let x = yd(a);
    let y = yd(b);
    let r = _mm256_or_pd(
        _mm256_and_pd(unsafe _mm256_cmp_pd(x, y, 0), _mm256_and_pd(x, y)),
        _mm256_andnot_pd(unsafe _mm256_cmp_pd(x, y, 0), _mm256_max_pd(x, y)),
    );
    return ydv::<f64, 4>(_mm256_or_pd(r, unsafe _mm256_cmp_pd(x, y, 3)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx512f])
fn min_f32x16(a: f32x16, b: f32x16) f32x16 {
    let x = zf(a);
    let y = zf(b);
    let z = _mm512_castsi512_ps(_mm512_or_si512(_mm512_castps_si512(x), _mm512_castps_si512(y)));
    let r = _mm512_mask_blend_ps(unsafe _mm512_cmp_ps_mask(x, y, 0), _mm512_min_ps(x, y), z);
    let xq = _mm512_castsi512_ps(
        _mm512_mask_or_epi32(
            _mm512_castps_si512(x),
            unsafe _mm512_cmp_ps_mask(x, x, 3),
            _mm512_castps_si512(x),
            _mm512_set1_epi32(0x00400000),
        ),
    );
    return zfv::<f32, 16>(_mm512_mask_blend_ps(unsafe _mm512_cmp_ps_mask(y, y, 3), r, xq));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx512f])
fn max_f32x16(a: f32x16, b: f32x16) f32x16 {
    let x = zf(a);
    let y = zf(b);
    let z = _mm512_castsi512_ps(_mm512_and_si512(_mm512_castps_si512(x), _mm512_castps_si512(y)));
    let r = _mm512_mask_blend_ps(unsafe _mm512_cmp_ps_mask(x, y, 0), _mm512_max_ps(x, y), z);
    let xq = _mm512_castsi512_ps(
        _mm512_mask_or_epi32(
            _mm512_castps_si512(x),
            unsafe _mm512_cmp_ps_mask(x, x, 3),
            _mm512_castps_si512(x),
            _mm512_set1_epi32(0x00400000),
        ),
    );
    return zfv::<f32, 16>(_mm512_mask_blend_ps(unsafe _mm512_cmp_ps_mask(y, y, 3), r, xq));
}

@arch(x86_64)
@simd_impl(simd::Op::Minimum, [cpu::Feature::Avx512f])
fn minimum_f32x16(a: f32x16, b: f32x16) f32x16 {
    let x = zf(a);
    let y = zf(b);
    let z = _mm512_castsi512_ps(_mm512_or_si512(_mm512_castps_si512(x), _mm512_castps_si512(y)));
    let r = _mm512_mask_blend_ps(unsafe _mm512_cmp_ps_mask(x, y, 0), _mm512_min_ps(x, y), z);
    return zfv::<f32, 16>(
        _mm512_mask_blend_ps(unsafe _mm512_cmp_ps_mask(x, y, 3), r, _mm512_castsi512_ps(_mm512_set1_epi32(-1))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Maximum, [cpu::Feature::Avx512f])
fn maximum_f32x16(a: f32x16, b: f32x16) f32x16 {
    let x = zf(a);
    let y = zf(b);
    let z = _mm512_castsi512_ps(_mm512_and_si512(_mm512_castps_si512(x), _mm512_castps_si512(y)));
    let r = _mm512_mask_blend_ps(unsafe _mm512_cmp_ps_mask(x, y, 0), _mm512_max_ps(x, y), z);
    return zfv::<f32, 16>(
        _mm512_mask_blend_ps(unsafe _mm512_cmp_ps_mask(x, y, 3), r, _mm512_castsi512_ps(_mm512_set1_epi32(-1))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx512f])
fn min_f64x8(a: f64x8, b: f64x8) f64x8 {
    let x = zd(a);
    let y = zd(b);
    let z = _mm512_castsi512_pd(_mm512_or_si512(_mm512_castpd_si512(x), _mm512_castpd_si512(y)));
    let r = _mm512_mask_blend_pd(unsafe _mm512_cmp_pd_mask(x, y, 0), _mm512_min_pd(x, y), z);
    let xq = _mm512_castsi512_pd(
        _mm512_mask_or_epi64(
            _mm512_castpd_si512(x),
            unsafe _mm512_cmp_pd_mask(x, x, 3),
            _mm512_castpd_si512(x),
            _mm512_set1_epi64(0x0008000000000000),
        ),
    );
    return zdv::<f64, 8>(_mm512_mask_blend_pd(unsafe _mm512_cmp_pd_mask(y, y, 3), r, xq));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx512f])
fn max_f64x8(a: f64x8, b: f64x8) f64x8 {
    let x = zd(a);
    let y = zd(b);
    let z = _mm512_castsi512_pd(_mm512_and_si512(_mm512_castpd_si512(x), _mm512_castpd_si512(y)));
    let r = _mm512_mask_blend_pd(unsafe _mm512_cmp_pd_mask(x, y, 0), _mm512_max_pd(x, y), z);
    let xq = _mm512_castsi512_pd(
        _mm512_mask_or_epi64(
            _mm512_castpd_si512(x),
            unsafe _mm512_cmp_pd_mask(x, x, 3),
            _mm512_castpd_si512(x),
            _mm512_set1_epi64(0x0008000000000000),
        ),
    );
    return zdv::<f64, 8>(_mm512_mask_blend_pd(unsafe _mm512_cmp_pd_mask(y, y, 3), r, xq));
}

@arch(x86_64)
@simd_impl(simd::Op::Minimum, [cpu::Feature::Avx512f])
fn minimum_f64x8(a: f64x8, b: f64x8) f64x8 {
    let x = zd(a);
    let y = zd(b);
    let z = _mm512_castsi512_pd(_mm512_or_si512(_mm512_castpd_si512(x), _mm512_castpd_si512(y)));
    let r = _mm512_mask_blend_pd(unsafe _mm512_cmp_pd_mask(x, y, 0), _mm512_min_pd(x, y), z);
    return zdv::<f64, 8>(
        _mm512_mask_blend_pd(unsafe _mm512_cmp_pd_mask(x, y, 3), r, _mm512_castsi512_pd(_mm512_set1_epi64(-1))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Maximum, [cpu::Feature::Avx512f])
fn maximum_f64x8(a: f64x8, b: f64x8) f64x8 {
    let x = zd(a);
    let y = zd(b);
    let z = _mm512_castsi512_pd(_mm512_and_si512(_mm512_castpd_si512(x), _mm512_castpd_si512(y)));
    let r = _mm512_mask_blend_pd(unsafe _mm512_cmp_pd_mask(x, y, 0), _mm512_max_pd(x, y), z);
    return zdv::<f64, 8>(
        _mm512_mask_blend_pd(unsafe _mm512_cmp_pd_mask(x, y, 3), r, _mm512_castsi512_pd(_mm512_set1_epi64(-1))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_i8x16_u8x16(a: i8x16) u8x16 {
    return xiv::<u8, 16>(xi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_u8x16_i8x16(a: u8x16) i8x16 {
    return xiv::<i8, 16>(xi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_i16x8_u16x8(a: i16x8) u16x8 {
    return xiv::<u16, 8>(xi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_u16x8_i16x8(a: u16x8) i16x8 {
    return xiv::<i16, 8>(xi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_i32x4_u32x4(a: i32x4) u32x4 {
    return xiv::<u32, 4>(xi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_u32x4_i32x4(a: u32x4) i32x4 {
    return xiv::<i32, 4>(xi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_i64x2_u64x2(a: i64x2) u64x2 {
    return xiv::<u64, 2>(xi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_u64x2_i64x2(a: u64x2) i64x2 {
    return xiv::<i64, 2>(xi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_i32x4_f32x4(a: i32x4) f32x4 {
    return xfv::<f32, 4>(_mm_cvtepi32_ps(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_f32x4_i32x4(a: f32x4) i32x4 {
    let x = xf(a);
    let r = _mm_cvttps_epi32(x);
    let big = _mm_castps_si128(_mm_cmpge_ps(x, _mm_castsi128_ps(_mm_set1_epi32(1325400064))));
    let ord = _mm_castps_si128(_mm_cmpord_ps(x, x));
    return xiv::<i32, 4>(_mm_and_si128(_mm_xor_si128(r, big), ord));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_f32x4_u32x4(a: f32x4) u32x4 {
    let x = _mm_max_ps(xf(a), _mm_setzero_ps());
    let h = _mm_castsi128_ps(_mm_set1_epi32(1325400064));
    let big = _mm_castps_si128(_mm_cmpge_ps(x, h));
    let lo = _mm_cvttps_epi32(x);
    let up = _mm_xor_si128(_mm_cvttps_epi32(_mm_sub_ps(x, h)), _mm_set1_epi32(-2147483648));
    let r = _mm_or_si128(_mm_and_si128(big, up), _mm_andnot_si128(big, lo));
    return xiv::<u32, 4>(
        _mm_or_si128(r, _mm_castps_si128(_mm_cmpge_ps(x, _mm_castsi128_ps(_mm_set1_epi32(1333788672))))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_u32x4_f32x4(a: u32x4) f32x4 {
    let x = xi(a);
    let hi = _mm_mul_ps(_mm_cvtepi32_ps(_mm_srli_epi32(x, 16)), _mm_set1_ps(65536.0));
    return xfv::<f32, 4>(_mm_add_ps(hi, _mm_cvtepi32_ps(_mm_and_si128(x, _mm_set1_epi32(65535)))));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cast_u32x4_f32x4_avx512vl(a: u32x4) f32x4 {
    return xfv::<f32, 4>(_mm_cvtepu32_ps(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512dq, cpu::Feature::Avx512vl])
fn cast_i64x2_f64x2(a: i64x2) f64x2 {
    return xdv::<f64, 2>(_mm_cvtepi64_pd(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512dq, cpu::Feature::Avx512vl])
fn cast_u64x2_f64x2(a: u64x2) f64x2 {
    return xdv::<f64, 2>(_mm_cvtepu64_pd(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse41])
fn cast_i8x8_i16x8(a: Simd<i8, 8>) i16x8 {
    return xiv::<i16, 8>(_mm_cvtepi8_epi16(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse41])
fn cast_i8x8_u16x8(a: Simd<i8, 8>) u16x8 {
    return xiv::<u16, 8>(_mm_cvtepi8_epi16(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse41])
fn cast_u8x8_i16x8(a: Simd<u8, 8>) i16x8 {
    return xiv::<i16, 8>(_mm_cvtepu8_epi16(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse41])
fn cast_u8x8_u16x8(a: Simd<u8, 8>) u16x8 {
    return xiv::<u16, 8>(_mm_cvtepu8_epi16(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse41])
fn cast_i16x4_i32x4(a: Simd<i16, 4>) i32x4 {
    return xiv::<i32, 4>(_mm_cvtepi16_epi32(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse41])
fn cast_i16x4_u32x4(a: Simd<i16, 4>) u32x4 {
    return xiv::<u32, 4>(_mm_cvtepi16_epi32(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse41])
fn cast_u16x4_i32x4(a: Simd<u16, 4>) i32x4 {
    return xiv::<i32, 4>(_mm_cvtepu16_epi32(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse41])
fn cast_u16x4_u32x4(a: Simd<u16, 4>) u32x4 {
    return xiv::<u32, 4>(_mm_cvtepu16_epi32(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse41])
fn cast_i32x2_i64x2(a: Simd<i32, 2>) i64x2 {
    return xiv::<i64, 2>(_mm_cvtepi32_epi64(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse41])
fn cast_i32x2_u64x2(a: Simd<i32, 2>) u64x2 {
    return xiv::<u64, 2>(_mm_cvtepi32_epi64(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse41])
fn cast_u32x2_i64x2(a: Simd<u32, 2>) i64x2 {
    return xiv::<i64, 2>(_mm_cvtepu32_epi64(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse41])
fn cast_u32x2_u64x2(a: Simd<u32, 2>) u64x2 {
    return xiv::<u64, 2>(_mm_cvtepu32_epi64(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_i16x8_i8x8(a: i16x8) Simd<i8, 8> {
    return xliv::<i8, 8>(_mm_packus_epi16(_mm_and_si128(xi(a), _mm_set1_epi16(255)), _mm_setzero_si128()));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_i16x8_u8x8(a: i16x8) Simd<u8, 8> {
    return xliv::<u8, 8>(_mm_packus_epi16(_mm_and_si128(xi(a), _mm_set1_epi16(255)), _mm_setzero_si128()));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_u16x8_i8x8(a: u16x8) Simd<i8, 8> {
    return xliv::<i8, 8>(_mm_packus_epi16(_mm_and_si128(xi(a), _mm_set1_epi16(255)), _mm_setzero_si128()));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_u16x8_u8x8(a: u16x8) Simd<u8, 8> {
    return xliv::<u8, 8>(_mm_packus_epi16(_mm_and_si128(xi(a), _mm_set1_epi16(255)), _mm_setzero_si128()));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Sse2])
fn narrow_saturating_i16x8_i8x8(a: i16x8) Simd<i8, 8> {
    return xliv::<i8, 8>(_mm_packs_epi16(xi(a), _mm_setzero_si128()));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Sse2])
fn narrow_saturating_i16x8_u8x8(a: i16x8) Simd<u8, 8> {
    return xliv::<u8, 8>(_mm_packus_epi16(xi(a), _mm_setzero_si128()));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Sse41])
fn narrow_saturating_u16x8_u8x8(a: u16x8) Simd<u8, 8> {
    return xliv::<u8, 8>(_mm_packus_epi16(_mm_min_epu16(xi(a), _mm_set1_epi16(255)), _mm_setzero_si128()));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse41])
fn cast_i32x4_i16x4(a: i32x4) Simd<i16, 4> {
    return xliv::<i16, 4>(_mm_packus_epi32(_mm_and_si128(xi(a), _mm_set1_epi32(65535)), _mm_setzero_si128()));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse41])
fn cast_i32x4_u16x4(a: i32x4) Simd<u16, 4> {
    return xliv::<u16, 4>(_mm_packus_epi32(_mm_and_si128(xi(a), _mm_set1_epi32(65535)), _mm_setzero_si128()));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse41])
fn cast_u32x4_i16x4(a: u32x4) Simd<i16, 4> {
    return xliv::<i16, 4>(_mm_packus_epi32(_mm_and_si128(xi(a), _mm_set1_epi32(65535)), _mm_setzero_si128()));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse41])
fn cast_u32x4_u16x4(a: u32x4) Simd<u16, 4> {
    return xliv::<u16, 4>(_mm_packus_epi32(_mm_and_si128(xi(a), _mm_set1_epi32(65535)), _mm_setzero_si128()));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Sse2])
fn narrow_saturating_i32x4_i16x4(a: i32x4) Simd<i16, 4> {
    return xliv::<i16, 4>(_mm_packs_epi32(xi(a), _mm_setzero_si128()));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Sse41])
fn narrow_saturating_i32x4_u16x4(a: i32x4) Simd<u16, 4> {
    return xliv::<u16, 4>(_mm_packus_epi32(xi(a), _mm_setzero_si128()));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Sse41])
fn narrow_saturating_u32x4_u16x4(a: u32x4) Simd<u16, 4> {
    return xliv::<u16, 4>(_mm_packus_epi32(_mm_min_epu32(xi(a), _mm_set1_epi32(65535)), _mm_setzero_si128()));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_f32x2_f64x2(a: Simd<f32, 2>) f64x2 {
    return xdv::<f64, 2>(_mm_cvtps_pd(_mm_castsi128_ps(xli(a))));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Sse2])
fn cast_f64x2_f32x2(a: f64x2) Simd<f32, 2> {
    return xliv::<f32, 2>(_mm_castps_si128(_mm_cvtpd_ps(xd(a))));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx])
fn cast_i8x32_u8x32(a: i8x32) u8x32 {
    return yiv::<u8, 32>(yi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx])
fn cast_u8x32_i8x32(a: u8x32) i8x32 {
    return yiv::<i8, 32>(yi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx])
fn cast_i16x16_u16x16(a: i16x16) u16x16 {
    return yiv::<u16, 16>(yi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx])
fn cast_u16x16_i16x16(a: u16x16) i16x16 {
    return yiv::<i16, 16>(yi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx])
fn cast_i32x8_u32x8(a: i32x8) u32x8 {
    return yiv::<u32, 8>(yi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx])
fn cast_u32x8_i32x8(a: u32x8) i32x8 {
    return yiv::<i32, 8>(yi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx])
fn cast_i64x4_u64x4(a: i64x4) u64x4 {
    return yiv::<u64, 4>(yi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx])
fn cast_u64x4_i64x4(a: u64x4) i64x4 {
    return yiv::<i64, 4>(yi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx])
fn cast_i32x8_f32x8(a: i32x8) f32x8 {
    return yfv::<f32, 8>(_mm256_cvtepi32_ps(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_f32x8_i32x8(a: f32x8) i32x8 {
    let x = yf(a);
    let r = _mm256_cvttps_epi32(x);
    let big = _mm256_castps_si256(unsafe _mm256_cmp_ps(x, _mm256_castsi256_ps(_mm256_set1_epi32(1325400064)), 29));
    let ord = _mm256_castps_si256(unsafe _mm256_cmp_ps(x, x, 7));
    return yiv::<i32, 8>(_mm256_and_si256(_mm256_xor_si256(r, big), ord));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_f32x8_u32x8(a: f32x8) u32x8 {
    let x = _mm256_max_ps(yf(a), _mm256_setzero_ps());
    let h = _mm256_castsi256_ps(_mm256_set1_epi32(1325400064));
    let big = _mm256_castps_si256(unsafe _mm256_cmp_ps(x, h, 29));
    let lo = _mm256_cvttps_epi32(x);
    let up = _mm256_xor_si256(_mm256_cvttps_epi32(_mm256_sub_ps(x, h)), _mm256_set1_epi32(-2147483648));
    let r = _mm256_or_si256(_mm256_and_si256(big, up), _mm256_andnot_si256(big, lo));
    return yiv::<u32, 8>(
        _mm256_or_si256(
            r,
            _mm256_castps_si256(unsafe _mm256_cmp_ps(x, _mm256_castsi256_ps(_mm256_set1_epi32(1333788672)), 29)),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_u32x8_f32x8(a: u32x8) f32x8 {
    let x = yi(a);
    let hi = _mm256_mul_ps(_mm256_cvtepi32_ps(_mm256_srli_epi32(x, 16)), _mm256_set1_ps(65536.0));
    return yfv::<f32, 8>(_mm256_add_ps(hi, _mm256_cvtepi32_ps(_mm256_and_si256(x, _mm256_set1_epi32(65535)))));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn cast_u32x8_f32x8_avx512vl(a: u32x8) f32x8 {
    return yfv::<f32, 8>(_mm256_cvtepu32_ps(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512dq, cpu::Feature::Avx512vl])
fn cast_i64x4_f64x4(a: i64x4) f64x4 {
    return ydv::<f64, 4>(_mm256_cvtepi64_pd(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512dq, cpu::Feature::Avx512vl])
fn cast_u64x4_f64x4(a: u64x4) f64x4 {
    return ydv::<f64, 4>(_mm256_cvtepu64_pd(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_i8x16_i16x16(a: i8x16) i16x16 {
    return yiv::<i16, 16>(_mm256_cvtepi8_epi16(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_i8x16_u16x16(a: i8x16) u16x16 {
    return yiv::<u16, 16>(_mm256_cvtepi8_epi16(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_u8x16_i16x16(a: u8x16) i16x16 {
    return yiv::<i16, 16>(_mm256_cvtepu8_epi16(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_u8x16_u16x16(a: u8x16) u16x16 {
    return yiv::<u16, 16>(_mm256_cvtepu8_epi16(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_i8x8_i32x8(a: Simd<i8, 8>) i32x8 {
    return yiv::<i32, 8>(_mm256_cvtepi8_epi32(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_i8x8_u32x8(a: Simd<i8, 8>) u32x8 {
    return yiv::<u32, 8>(_mm256_cvtepi8_epi32(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_u8x8_i32x8(a: Simd<u8, 8>) i32x8 {
    return yiv::<i32, 8>(_mm256_cvtepu8_epi32(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_u8x8_u32x8(a: Simd<u8, 8>) u32x8 {
    return yiv::<u32, 8>(_mm256_cvtepu8_epi32(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_i16x8_i32x8(a: i16x8) i32x8 {
    return yiv::<i32, 8>(_mm256_cvtepi16_epi32(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_i16x8_u32x8(a: i16x8) u32x8 {
    return yiv::<u32, 8>(_mm256_cvtepi16_epi32(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_u16x8_i32x8(a: u16x8) i32x8 {
    return yiv::<i32, 8>(_mm256_cvtepu16_epi32(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_u16x8_u32x8(a: u16x8) u32x8 {
    return yiv::<u32, 8>(_mm256_cvtepu16_epi32(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_i16x4_i64x4(a: Simd<i16, 4>) i64x4 {
    return yiv::<i64, 4>(_mm256_cvtepi16_epi64(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_i16x4_u64x4(a: Simd<i16, 4>) u64x4 {
    return yiv::<u64, 4>(_mm256_cvtepi16_epi64(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_u16x4_i64x4(a: Simd<u16, 4>) i64x4 {
    return yiv::<i64, 4>(_mm256_cvtepu16_epi64(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_u16x4_u64x4(a: Simd<u16, 4>) u64x4 {
    return yiv::<u64, 4>(_mm256_cvtepu16_epi64(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_i32x4_i64x4(a: i32x4) i64x4 {
    return yiv::<i64, 4>(_mm256_cvtepi32_epi64(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_i32x4_u64x4(a: i32x4) u64x4 {
    return yiv::<u64, 4>(_mm256_cvtepi32_epi64(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_u32x4_i64x4(a: u32x4) i64x4 {
    return yiv::<i64, 4>(_mm256_cvtepu32_epi64(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_u32x4_u64x4(a: u32x4) u64x4 {
    return yiv::<u64, 4>(_mm256_cvtepu32_epi64(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_i16x16_i8x16(a: i16x16) i8x16 {
    let x = yi(a);
    let k = _mm_set1_epi16(255);
    return xiv::<i8, 16>(
        _mm_packus_epi16(
            _mm_and_si128(_mm256_castsi256_si128(x), k),
            _mm_and_si128(unsafe _mm256_extracti128_si256(x, 1), k),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_i16x16_u8x16(a: i16x16) u8x16 {
    let x = yi(a);
    let k = _mm_set1_epi16(255);
    return xiv::<u8, 16>(
        _mm_packus_epi16(
            _mm_and_si128(_mm256_castsi256_si128(x), k),
            _mm_and_si128(unsafe _mm256_extracti128_si256(x, 1), k),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_u16x16_i8x16(a: u16x16) i8x16 {
    let x = yi(a);
    let k = _mm_set1_epi16(255);
    return xiv::<i8, 16>(
        _mm_packus_epi16(
            _mm_and_si128(_mm256_castsi256_si128(x), k),
            _mm_and_si128(unsafe _mm256_extracti128_si256(x, 1), k),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_u16x16_u8x16(a: u16x16) u8x16 {
    let x = yi(a);
    let k = _mm_set1_epi16(255);
    return xiv::<u8, 16>(
        _mm_packus_epi16(
            _mm_and_si128(_mm256_castsi256_si128(x), k),
            _mm_and_si128(unsafe _mm256_extracti128_si256(x, 1), k),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx2])
fn narrow_saturating_i16x16_i8x16(a: i16x16) i8x16 {
    let x = yi(a);
    return xiv::<i8, 16>(_mm_packs_epi16(_mm256_castsi256_si128(x), unsafe _mm256_extracti128_si256(x, 1)));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx2])
fn narrow_saturating_i16x16_u8x16(a: i16x16) u8x16 {
    let x = yi(a);
    return xiv::<u8, 16>(_mm_packus_epi16(_mm256_castsi256_si128(x), unsafe _mm256_extracti128_si256(x, 1)));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx2])
fn narrow_saturating_u16x16_u8x16(a: u16x16) u8x16 {
    let x = yi(a);
    return xiv::<u8, 16>(
        _mm_packus_epi16(
            _mm_min_epu16(_mm256_castsi256_si128(x), _mm_set1_epi16(255)),
            _mm_min_epu16(unsafe _mm256_extracti128_si256(x, 1), _mm_set1_epi16(255)),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_i32x8_i16x8(a: i32x8) i16x8 {
    let x = yi(a);
    let k = _mm_set1_epi32(65535);
    return xiv::<i16, 8>(
        _mm_packus_epi32(
            _mm_and_si128(_mm256_castsi256_si128(x), k),
            _mm_and_si128(unsafe _mm256_extracti128_si256(x, 1), k),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_i32x8_u16x8(a: i32x8) u16x8 {
    let x = yi(a);
    let k = _mm_set1_epi32(65535);
    return xiv::<u16, 8>(
        _mm_packus_epi32(
            _mm_and_si128(_mm256_castsi256_si128(x), k),
            _mm_and_si128(unsafe _mm256_extracti128_si256(x, 1), k),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_u32x8_i16x8(a: u32x8) i16x8 {
    let x = yi(a);
    let k = _mm_set1_epi32(65535);
    return xiv::<i16, 8>(
        _mm_packus_epi32(
            _mm_and_si128(_mm256_castsi256_si128(x), k),
            _mm_and_si128(unsafe _mm256_extracti128_si256(x, 1), k),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_u32x8_u16x8(a: u32x8) u16x8 {
    let x = yi(a);
    let k = _mm_set1_epi32(65535);
    return xiv::<u16, 8>(
        _mm_packus_epi32(
            _mm_and_si128(_mm256_castsi256_si128(x), k),
            _mm_and_si128(unsafe _mm256_extracti128_si256(x, 1), k),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx2])
fn narrow_saturating_i32x8_i16x8(a: i32x8) i16x8 {
    let x = yi(a);
    return xiv::<i16, 8>(_mm_packs_epi32(_mm256_castsi256_si128(x), unsafe _mm256_extracti128_si256(x, 1)));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx2])
fn narrow_saturating_i32x8_u16x8(a: i32x8) u16x8 {
    let x = yi(a);
    return xiv::<u16, 8>(_mm_packus_epi32(_mm256_castsi256_si128(x), unsafe _mm256_extracti128_si256(x, 1)));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx2])
fn narrow_saturating_u32x8_u16x8(a: u32x8) u16x8 {
    let x = yi(a);
    return xiv::<u16, 8>(
        _mm_packus_epi32(
            _mm_min_epu32(_mm256_castsi256_si128(x), _mm_set1_epi32(65535)),
            _mm_min_epu32(unsafe _mm256_extracti128_si256(x, 1), _mm_set1_epi32(65535)),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_i64x4_i32x4(a: i64x4) i32x4 {
    return xiv::<i32, 4>(
        _mm256_castsi256_si128(_mm256_permutevar8x32_epi32(yi(a), _mm256_setr_epi32(0, 2, 4, 6, 0, 2, 4, 6))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_i64x4_u32x4(a: i64x4) u32x4 {
    return xiv::<u32, 4>(
        _mm256_castsi256_si128(_mm256_permutevar8x32_epi32(yi(a), _mm256_setr_epi32(0, 2, 4, 6, 0, 2, 4, 6))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_u64x4_i32x4(a: u64x4) i32x4 {
    return xiv::<i32, 4>(
        _mm256_castsi256_si128(_mm256_permutevar8x32_epi32(yi(a), _mm256_setr_epi32(0, 2, 4, 6, 0, 2, 4, 6))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx2])
fn cast_u64x4_u32x4(a: u64x4) u32x4 {
    return xiv::<u32, 4>(
        _mm256_castsi256_si128(_mm256_permutevar8x32_epi32(yi(a), _mm256_setr_epi32(0, 2, 4, 6, 0, 2, 4, 6))),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx])
fn cast_f32x4_f64x4(a: f32x4) f64x4 {
    return ydv::<f64, 4>(_mm256_cvtps_pd(xf(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx])
fn cast_f64x4_f32x4(a: f64x4) f32x4 {
    return xfv::<f32, 4>(_mm256_cvtpd_ps(yd(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i8x64_u8x64(a: i8x64) u8x64 {
    return ziv::<u8, 64>(zi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u8x64_i8x64(a: u8x64) i8x64 {
    return ziv::<i8, 64>(zi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i16x32_u16x32(a: i16x32) u16x32 {
    return ziv::<u16, 32>(zi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u16x32_i16x32(a: u16x32) i16x32 {
    return ziv::<i16, 32>(zi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i32x16_u32x16(a: i32x16) u32x16 {
    return ziv::<u32, 16>(zi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u32x16_i32x16(a: u32x16) i32x16 {
    return ziv::<i32, 16>(zi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i64x8_u64x8(a: i64x8) u64x8 {
    return ziv::<u64, 8>(zi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u64x8_i64x8(a: u64x8) i64x8 {
    return ziv::<i64, 8>(zi(a));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i32x16_f32x16(a: i32x16) f32x16 {
    return zfv::<f32, 16>(_mm512_cvtepi32_ps(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u32x16_f32x16(a: u32x16) f32x16 {
    return zfv::<f32, 16>(_mm512_cvtepu32_ps(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_f32x16_i32x16(a: f32x16) i32x16 {
    let x = zf(a);
    let r = _mm512_cvttps_epi32(x);
    let r1 = _mm512_mask_mov_epi32(
        r,
        unsafe _mm512_cmp_ps_mask(x, _mm512_castsi512_ps(_mm512_set1_epi32(1325400064)), 29),
        _mm512_set1_epi32(2147483647),
    );
    return ziv::<i32, 16>(_mm512_maskz_mov_epi32(unsafe _mm512_cmp_ps_mask(x, x, 7), r1));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_f32x16_u32x16(a: f32x16) u32x16 {
    let x = zf(a);
    let r = _mm512_cvttps_epu32(x);
    let r1 = _mm512_mask_mov_epi32(
        r,
        unsafe _mm512_cmp_ps_mask(x, _mm512_castsi512_ps(_mm512_set1_epi32(1333788672)), 29),
        _mm512_set1_epi32(-1),
    );
    let r2 = _mm512_mask_mov_epi32(r1, unsafe _mm512_cmp_ps_mask(x, _mm512_setzero_ps(), 17), _mm512_set1_epi32(0));
    return ziv::<u32, 16>(_mm512_maskz_mov_epi32(unsafe _mm512_cmp_ps_mask(x, x, 7), r2));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512dq])
fn cast_i64x8_f64x8(a: i64x8) f64x8 {
    return zdv::<f64, 8>(_mm512_cvtepi64_pd(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512dq])
fn cast_u64x8_f64x8(a: u64x8) f64x8 {
    return zdv::<f64, 8>(_mm512_cvtepu64_pd(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512bw])
fn cast_i8x32_i16x32(a: i8x32) i16x32 {
    return ziv::<i16, 32>(_mm512_cvtepi8_epi16(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512bw])
fn cast_i8x32_u16x32(a: i8x32) u16x32 {
    return ziv::<u16, 32>(_mm512_cvtepi8_epi16(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512bw])
fn cast_u8x32_i16x32(a: u8x32) i16x32 {
    return ziv::<i16, 32>(_mm512_cvtepu8_epi16(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512bw])
fn cast_u8x32_u16x32(a: u8x32) u16x32 {
    return ziv::<u16, 32>(_mm512_cvtepu8_epi16(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i8x16_i32x16(a: i8x16) i32x16 {
    return ziv::<i32, 16>(_mm512_cvtepi8_epi32(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i8x16_u32x16(a: i8x16) u32x16 {
    return ziv::<u32, 16>(_mm512_cvtepi8_epi32(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u8x16_i32x16(a: u8x16) i32x16 {
    return ziv::<i32, 16>(_mm512_cvtepu8_epi32(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u8x16_u32x16(a: u8x16) u32x16 {
    return ziv::<u32, 16>(_mm512_cvtepu8_epi32(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i8x8_i64x8(a: Simd<i8, 8>) i64x8 {
    return ziv::<i64, 8>(_mm512_cvtepi8_epi64(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i8x8_u64x8(a: Simd<i8, 8>) u64x8 {
    return ziv::<u64, 8>(_mm512_cvtepi8_epi64(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u8x8_i64x8(a: Simd<u8, 8>) i64x8 {
    return ziv::<i64, 8>(_mm512_cvtepu8_epi64(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u8x8_u64x8(a: Simd<u8, 8>) u64x8 {
    return ziv::<u64, 8>(_mm512_cvtepu8_epi64(xli(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i16x16_i32x16(a: i16x16) i32x16 {
    return ziv::<i32, 16>(_mm512_cvtepi16_epi32(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i16x16_u32x16(a: i16x16) u32x16 {
    return ziv::<u32, 16>(_mm512_cvtepi16_epi32(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u16x16_i32x16(a: u16x16) i32x16 {
    return ziv::<i32, 16>(_mm512_cvtepu16_epi32(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u16x16_u32x16(a: u16x16) u32x16 {
    return ziv::<u32, 16>(_mm512_cvtepu16_epi32(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i16x8_i64x8(a: i16x8) i64x8 {
    return ziv::<i64, 8>(_mm512_cvtepi16_epi64(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i16x8_u64x8(a: i16x8) u64x8 {
    return ziv::<u64, 8>(_mm512_cvtepi16_epi64(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u16x8_i64x8(a: u16x8) i64x8 {
    return ziv::<i64, 8>(_mm512_cvtepu16_epi64(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u16x8_u64x8(a: u16x8) u64x8 {
    return ziv::<u64, 8>(_mm512_cvtepu16_epi64(xi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i32x8_i64x8(a: i32x8) i64x8 {
    return ziv::<i64, 8>(_mm512_cvtepi32_epi64(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i32x8_u64x8(a: i32x8) u64x8 {
    return ziv::<u64, 8>(_mm512_cvtepi32_epi64(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u32x8_i64x8(a: u32x8) i64x8 {
    return ziv::<i64, 8>(_mm512_cvtepu32_epi64(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u32x8_u64x8(a: u32x8) u64x8 {
    return ziv::<u64, 8>(_mm512_cvtepu32_epi64(yi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512bw])
fn cast_i16x32_i8x32(a: i16x32) i8x32 {
    return yiv::<i8, 32>(_mm512_cvtepi16_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx512bw])
fn narrow_saturating_i16x32_i8x32(a: i16x32) i8x32 {
    return yiv::<i8, 32>(_mm512_cvtsepi16_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512bw])
fn cast_i16x32_u8x32(a: i16x32) u8x32 {
    return yiv::<u8, 32>(_mm512_cvtepi16_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512bw])
fn cast_u16x32_i8x32(a: u16x32) i8x32 {
    return yiv::<i8, 32>(_mm512_cvtepi16_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512bw])
fn cast_u16x32_u8x32(a: u16x32) u8x32 {
    return yiv::<u8, 32>(_mm512_cvtepi16_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx512bw])
fn narrow_saturating_u16x32_u8x32(a: u16x32) u8x32 {
    return yiv::<u8, 32>(_mm512_cvtusepi16_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i32x16_i8x16(a: i32x16) i8x16 {
    return xiv::<i8, 16>(_mm512_cvtepi32_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx512f])
fn narrow_saturating_i32x16_i8x16(a: i32x16) i8x16 {
    return xiv::<i8, 16>(_mm512_cvtsepi32_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i32x16_u8x16(a: i32x16) u8x16 {
    return xiv::<u8, 16>(_mm512_cvtepi32_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u32x16_i8x16(a: u32x16) i8x16 {
    return xiv::<i8, 16>(_mm512_cvtepi32_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u32x16_u8x16(a: u32x16) u8x16 {
    return xiv::<u8, 16>(_mm512_cvtepi32_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx512f])
fn narrow_saturating_u32x16_u8x16(a: u32x16) u8x16 {
    return xiv::<u8, 16>(_mm512_cvtusepi32_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i32x16_i16x16(a: i32x16) i16x16 {
    return yiv::<i16, 16>(_mm512_cvtepi32_epi16(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx512f])
fn narrow_saturating_i32x16_i16x16(a: i32x16) i16x16 {
    return yiv::<i16, 16>(_mm512_cvtsepi32_epi16(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i32x16_u16x16(a: i32x16) u16x16 {
    return yiv::<u16, 16>(_mm512_cvtepi32_epi16(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u32x16_i16x16(a: u32x16) i16x16 {
    return yiv::<i16, 16>(_mm512_cvtepi32_epi16(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u32x16_u16x16(a: u32x16) u16x16 {
    return yiv::<u16, 16>(_mm512_cvtepi32_epi16(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx512f])
fn narrow_saturating_u32x16_u16x16(a: u32x16) u16x16 {
    return yiv::<u16, 16>(_mm512_cvtusepi32_epi16(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i64x8_i8x8(a: i64x8) Simd<i8, 8> {
    return xliv::<i8, 8>(_mm512_cvtepi64_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx512f])
fn narrow_saturating_i64x8_i8x8(a: i64x8) Simd<i8, 8> {
    return xliv::<i8, 8>(_mm512_cvtsepi64_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i64x8_u8x8(a: i64x8) Simd<u8, 8> {
    return xliv::<u8, 8>(_mm512_cvtepi64_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u64x8_i8x8(a: u64x8) Simd<i8, 8> {
    return xliv::<i8, 8>(_mm512_cvtepi64_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u64x8_u8x8(a: u64x8) Simd<u8, 8> {
    return xliv::<u8, 8>(_mm512_cvtepi64_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx512f])
fn narrow_saturating_u64x8_u8x8(a: u64x8) Simd<u8, 8> {
    return xliv::<u8, 8>(_mm512_cvtusepi64_epi8(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i64x8_i16x8(a: i64x8) i16x8 {
    return xiv::<i16, 8>(_mm512_cvtepi64_epi16(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx512f])
fn narrow_saturating_i64x8_i16x8(a: i64x8) i16x8 {
    return xiv::<i16, 8>(_mm512_cvtsepi64_epi16(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i64x8_u16x8(a: i64x8) u16x8 {
    return xiv::<u16, 8>(_mm512_cvtepi64_epi16(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u64x8_i16x8(a: u64x8) i16x8 {
    return xiv::<i16, 8>(_mm512_cvtepi64_epi16(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u64x8_u16x8(a: u64x8) u16x8 {
    return xiv::<u16, 8>(_mm512_cvtepi64_epi16(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx512f])
fn narrow_saturating_u64x8_u16x8(a: u64x8) u16x8 {
    return xiv::<u16, 8>(_mm512_cvtusepi64_epi16(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i64x8_i32x8(a: i64x8) i32x8 {
    return yiv::<i32, 8>(_mm512_cvtepi64_epi32(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx512f])
fn narrow_saturating_i64x8_i32x8(a: i64x8) i32x8 {
    return yiv::<i32, 8>(_mm512_cvtsepi64_epi32(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_i64x8_u32x8(a: i64x8) u32x8 {
    return yiv::<u32, 8>(_mm512_cvtepi64_epi32(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u64x8_i32x8(a: u64x8) i32x8 {
    return yiv::<i32, 8>(_mm512_cvtepi64_epi32(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_u64x8_u32x8(a: u64x8) u32x8 {
    return yiv::<u32, 8>(_mm512_cvtepi64_epi32(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::NarrowSaturating, [cpu::Feature::Avx512f])
fn narrow_saturating_u64x8_u32x8(a: u64x8) u32x8 {
    return yiv::<u32, 8>(_mm512_cvtusepi64_epi32(zi(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_f32x8_f64x8(a: f32x8) f64x8 {
    return zdv::<f64, 8>(_mm512_cvtps_pd(yf(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::Cast, [cpu::Feature::Avx512f])
fn cast_f64x8_f32x8(a: f64x8) f32x8 {
    return yfv::<f32, 8>(_mm512_cvtpd_ps(zd(a)));
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAdd, [cpu::Feature::Sse2])
fn reduce_add_i8x16(v: i8x16) i8 {
    let x = xi(v);
    let s = _mm_sad_epu8(x, _mm_setzero_si128());
    return _mm_cvtsi128_si32(_mm_add_epi64(s, _mm_unpackhi_epi64(s, s))) as i8;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAnd, [cpu::Feature::Sse2])
fn reduce_and_i8x16(v: i8x16) i8 {
    let mut s = xi(v);
    s = _mm_and_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_and_si128(s, _mm_shuffle_epi32(s, 177));
    s = _mm_and_si128(s, _mm_srli_epi32(s, 16));
    s = _mm_and_si128(s, _mm_srli_epi16(s, 8));
    return _mm_cvtsi128_si32(s) as i8;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceOr, [cpu::Feature::Sse2])
fn reduce_or_i8x16(v: i8x16) i8 {
    let mut s = xi(v);
    s = _mm_or_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_or_si128(s, _mm_shuffle_epi32(s, 177));
    s = _mm_or_si128(s, _mm_srli_epi32(s, 16));
    s = _mm_or_si128(s, _mm_srli_epi16(s, 8));
    return _mm_cvtsi128_si32(s) as i8;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceXor, [cpu::Feature::Sse2])
fn reduce_xor_i8x16(v: i8x16) i8 {
    let mut s = xi(v);
    s = _mm_xor_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_xor_si128(s, _mm_shuffle_epi32(s, 177));
    s = _mm_xor_si128(s, _mm_srli_epi32(s, 16));
    s = _mm_xor_si128(s, _mm_srli_epi16(s, 8));
    return _mm_cvtsi128_si32(s) as i8;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceMin, [cpu::Feature::Sse41])
fn reduce_min_i8x16(v: i8x16) i8 {
    let mut s = xi(v);
    s = _mm_min_epi8(s, _mm_unpackhi_epi64(s, s));
    s = _mm_min_epi8(s, _mm_shuffle_epi32(s, 177));
    s = _mm_min_epi8(s, _mm_srli_epi32(s, 16));
    s = _mm_min_epi8(s, _mm_srli_epi16(s, 8));
    return _mm_cvtsi128_si32(s) as i8;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceMax, [cpu::Feature::Sse41])
fn reduce_max_i8x16(v: i8x16) i8 {
    let mut s = xi(v);
    s = _mm_max_epi8(s, _mm_unpackhi_epi64(s, s));
    s = _mm_max_epi8(s, _mm_shuffle_epi32(s, 177));
    s = _mm_max_epi8(s, _mm_srli_epi32(s, 16));
    s = _mm_max_epi8(s, _mm_srli_epi16(s, 8));
    return _mm_cvtsi128_si32(s) as i8;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAdd, [cpu::Feature::Sse2])
fn reduce_add_u8x16(v: u8x16) u8 {
    let x = xi(v);
    let s = _mm_sad_epu8(x, _mm_setzero_si128());
    return _mm_cvtsi128_si32(_mm_add_epi64(s, _mm_unpackhi_epi64(s, s))) as u8;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAnd, [cpu::Feature::Sse2])
fn reduce_and_u8x16(v: u8x16) u8 {
    let mut s = xi(v);
    s = _mm_and_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_and_si128(s, _mm_shuffle_epi32(s, 177));
    s = _mm_and_si128(s, _mm_srli_epi32(s, 16));
    s = _mm_and_si128(s, _mm_srli_epi16(s, 8));
    return _mm_cvtsi128_si32(s) as u8;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceOr, [cpu::Feature::Sse2])
fn reduce_or_u8x16(v: u8x16) u8 {
    let mut s = xi(v);
    s = _mm_or_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_or_si128(s, _mm_shuffle_epi32(s, 177));
    s = _mm_or_si128(s, _mm_srli_epi32(s, 16));
    s = _mm_or_si128(s, _mm_srli_epi16(s, 8));
    return _mm_cvtsi128_si32(s) as u8;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceXor, [cpu::Feature::Sse2])
fn reduce_xor_u8x16(v: u8x16) u8 {
    let mut s = xi(v);
    s = _mm_xor_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_xor_si128(s, _mm_shuffle_epi32(s, 177));
    s = _mm_xor_si128(s, _mm_srli_epi32(s, 16));
    s = _mm_xor_si128(s, _mm_srli_epi16(s, 8));
    return _mm_cvtsi128_si32(s) as u8;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceMin, [cpu::Feature::Sse2])
fn reduce_min_u8x16(v: u8x16) u8 {
    let mut s = xi(v);
    s = _mm_min_epu8(s, _mm_unpackhi_epi64(s, s));
    s = _mm_min_epu8(s, _mm_shuffle_epi32(s, 177));
    s = _mm_min_epu8(s, _mm_srli_epi32(s, 16));
    s = _mm_min_epu8(s, _mm_srli_epi16(s, 8));
    return _mm_cvtsi128_si32(s) as u8;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceMax, [cpu::Feature::Sse2])
fn reduce_max_u8x16(v: u8x16) u8 {
    let mut s = xi(v);
    s = _mm_max_epu8(s, _mm_unpackhi_epi64(s, s));
    s = _mm_max_epu8(s, _mm_shuffle_epi32(s, 177));
    s = _mm_max_epu8(s, _mm_srli_epi32(s, 16));
    s = _mm_max_epu8(s, _mm_srli_epi16(s, 8));
    return _mm_cvtsi128_si32(s) as u8;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAdd, [cpu::Feature::Sse2])
fn reduce_add_i16x8(v: i16x8) i16 {
    let x = xi(v);
    let s = _mm_madd_epi16(x, _mm_set1_epi16(1));
    let s2 = _mm_add_epi32(s, _mm_shuffle_epi32(s, 78));
    return _mm_cvtsi128_si32(_mm_add_epi32(s2, _mm_shuffle_epi32(s2, 177))) as i16;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAnd, [cpu::Feature::Sse2])
fn reduce_and_i16x8(v: i16x8) i16 {
    let mut s = xi(v);
    s = _mm_and_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_and_si128(s, _mm_shuffle_epi32(s, 177));
    s = _mm_and_si128(s, _mm_srli_epi32(s, 16));
    return _mm_cvtsi128_si32(s) as i16;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceOr, [cpu::Feature::Sse2])
fn reduce_or_i16x8(v: i16x8) i16 {
    let mut s = xi(v);
    s = _mm_or_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_or_si128(s, _mm_shuffle_epi32(s, 177));
    s = _mm_or_si128(s, _mm_srli_epi32(s, 16));
    return _mm_cvtsi128_si32(s) as i16;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceXor, [cpu::Feature::Sse2])
fn reduce_xor_i16x8(v: i16x8) i16 {
    let mut s = xi(v);
    s = _mm_xor_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_xor_si128(s, _mm_shuffle_epi32(s, 177));
    s = _mm_xor_si128(s, _mm_srli_epi32(s, 16));
    return _mm_cvtsi128_si32(s) as i16;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceMin, [cpu::Feature::Sse2])
fn reduce_min_i16x8(v: i16x8) i16 {
    let mut s = xi(v);
    s = _mm_min_epi16(s, _mm_unpackhi_epi64(s, s));
    s = _mm_min_epi16(s, _mm_shuffle_epi32(s, 177));
    s = _mm_min_epi16(s, _mm_srli_epi32(s, 16));
    return _mm_cvtsi128_si32(s) as i16;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceMax, [cpu::Feature::Sse2])
fn reduce_max_i16x8(v: i16x8) i16 {
    let mut s = xi(v);
    s = _mm_max_epi16(s, _mm_unpackhi_epi64(s, s));
    s = _mm_max_epi16(s, _mm_shuffle_epi32(s, 177));
    s = _mm_max_epi16(s, _mm_srli_epi32(s, 16));
    return _mm_cvtsi128_si32(s) as i16;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAdd, [cpu::Feature::Sse2])
fn reduce_add_u16x8(v: u16x8) u16 {
    let x = xi(v);
    let s = _mm_madd_epi16(x, _mm_set1_epi16(1));
    let s2 = _mm_add_epi32(s, _mm_shuffle_epi32(s, 78));
    return _mm_cvtsi128_si32(_mm_add_epi32(s2, _mm_shuffle_epi32(s2, 177))) as u16;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAnd, [cpu::Feature::Sse2])
fn reduce_and_u16x8(v: u16x8) u16 {
    let mut s = xi(v);
    s = _mm_and_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_and_si128(s, _mm_shuffle_epi32(s, 177));
    s = _mm_and_si128(s, _mm_srli_epi32(s, 16));
    return _mm_cvtsi128_si32(s) as u16;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceOr, [cpu::Feature::Sse2])
fn reduce_or_u16x8(v: u16x8) u16 {
    let mut s = xi(v);
    s = _mm_or_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_or_si128(s, _mm_shuffle_epi32(s, 177));
    s = _mm_or_si128(s, _mm_srli_epi32(s, 16));
    return _mm_cvtsi128_si32(s) as u16;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceXor, [cpu::Feature::Sse2])
fn reduce_xor_u16x8(v: u16x8) u16 {
    let mut s = xi(v);
    s = _mm_xor_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_xor_si128(s, _mm_shuffle_epi32(s, 177));
    s = _mm_xor_si128(s, _mm_srli_epi32(s, 16));
    return _mm_cvtsi128_si32(s) as u16;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceMin, [cpu::Feature::Sse41])
fn reduce_min_u16x8(v: u16x8) u16 {
    return _mm_cvtsi128_si32(_mm_minpos_epu16(xi(v))) as u16;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceMax, [cpu::Feature::Sse41])
fn reduce_max_u16x8(v: u16x8) u16 {
    return 65535 - _mm_cvtsi128_si32(_mm_minpos_epu16(_mm_xor_si128(xi(v), _mm_set1_epi32(-1)))) as u16;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAdd, [cpu::Feature::Sse2])
fn reduce_add_i32x4(v: i32x4) i32 {
    let x = xi(v);
    let s = _mm_add_epi32(x, _mm_shuffle_epi32(x, 78));
    return _mm_cvtsi128_si32(_mm_add_epi32(s, _mm_shuffle_epi32(s, 177)));
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAnd, [cpu::Feature::Sse2])
fn reduce_and_i32x4(v: i32x4) i32 {
    let mut s = xi(v);
    s = _mm_and_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_and_si128(s, _mm_shuffle_epi32(s, 177));
    return _mm_cvtsi128_si32(s);
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceOr, [cpu::Feature::Sse2])
fn reduce_or_i32x4(v: i32x4) i32 {
    let mut s = xi(v);
    s = _mm_or_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_or_si128(s, _mm_shuffle_epi32(s, 177));
    return _mm_cvtsi128_si32(s);
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceXor, [cpu::Feature::Sse2])
fn reduce_xor_i32x4(v: i32x4) i32 {
    let mut s = xi(v);
    s = _mm_xor_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_xor_si128(s, _mm_shuffle_epi32(s, 177));
    return _mm_cvtsi128_si32(s);
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceMin, [cpu::Feature::Sse41])
fn reduce_min_i32x4(v: i32x4) i32 {
    let mut s = xi(v);
    s = _mm_min_epi32(s, _mm_unpackhi_epi64(s, s));
    s = _mm_min_epi32(s, _mm_shuffle_epi32(s, 177));
    return _mm_cvtsi128_si32(s);
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceMax, [cpu::Feature::Sse41])
fn reduce_max_i32x4(v: i32x4) i32 {
    let mut s = xi(v);
    s = _mm_max_epi32(s, _mm_unpackhi_epi64(s, s));
    s = _mm_max_epi32(s, _mm_shuffle_epi32(s, 177));
    return _mm_cvtsi128_si32(s);
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAdd, [cpu::Feature::Sse2])
fn reduce_add_u32x4(v: u32x4) u32 {
    let x = xi(v);
    let s = _mm_add_epi32(x, _mm_shuffle_epi32(x, 78));
    return _mm_cvtsi128_si32(_mm_add_epi32(s, _mm_shuffle_epi32(s, 177))) as u32;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAnd, [cpu::Feature::Sse2])
fn reduce_and_u32x4(v: u32x4) u32 {
    let mut s = xi(v);
    s = _mm_and_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_and_si128(s, _mm_shuffle_epi32(s, 177));
    return _mm_cvtsi128_si32(s) as u32;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceOr, [cpu::Feature::Sse2])
fn reduce_or_u32x4(v: u32x4) u32 {
    let mut s = xi(v);
    s = _mm_or_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_or_si128(s, _mm_shuffle_epi32(s, 177));
    return _mm_cvtsi128_si32(s) as u32;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceXor, [cpu::Feature::Sse2])
fn reduce_xor_u32x4(v: u32x4) u32 {
    let mut s = xi(v);
    s = _mm_xor_si128(s, _mm_unpackhi_epi64(s, s));
    s = _mm_xor_si128(s, _mm_shuffle_epi32(s, 177));
    return _mm_cvtsi128_si32(s) as u32;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceMin, [cpu::Feature::Sse41])
fn reduce_min_u32x4(v: u32x4) u32 {
    let mut s = xi(v);
    s = _mm_min_epu32(s, _mm_unpackhi_epi64(s, s));
    s = _mm_min_epu32(s, _mm_shuffle_epi32(s, 177));
    return _mm_cvtsi128_si32(s) as u32;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceMax, [cpu::Feature::Sse41])
fn reduce_max_u32x4(v: u32x4) u32 {
    let mut s = xi(v);
    s = _mm_max_epu32(s, _mm_unpackhi_epi64(s, s));
    s = _mm_max_epu32(s, _mm_shuffle_epi32(s, 177));
    return _mm_cvtsi128_si32(s) as u32;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAdd, [cpu::Feature::Sse2])
fn reduce_add_i64x2(v: i64x2) i64 {
    let x = xi(v);
    return _mm_cvtsi128_si64(_mm_add_epi64(x, _mm_unpackhi_epi64(x, x)));
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAnd, [cpu::Feature::Sse2])
fn reduce_and_i64x2(v: i64x2) i64 {
    let mut s = xi(v);
    s = _mm_and_si128(s, _mm_unpackhi_epi64(s, s));
    return _mm_cvtsi128_si64(s);
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceOr, [cpu::Feature::Sse2])
fn reduce_or_i64x2(v: i64x2) i64 {
    let mut s = xi(v);
    s = _mm_or_si128(s, _mm_unpackhi_epi64(s, s));
    return _mm_cvtsi128_si64(s);
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceXor, [cpu::Feature::Sse2])
fn reduce_xor_i64x2(v: i64x2) i64 {
    let mut s = xi(v);
    s = _mm_xor_si128(s, _mm_unpackhi_epi64(s, s));
    return _mm_cvtsi128_si64(s);
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAdd, [cpu::Feature::Sse2])
fn reduce_add_u64x2(v: u64x2) u64 {
    let x = xi(v);
    return _mm_cvtsi128_si64(_mm_add_epi64(x, _mm_unpackhi_epi64(x, x))) as u64;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAnd, [cpu::Feature::Sse2])
fn reduce_and_u64x2(v: u64x2) u64 {
    let mut s = xi(v);
    s = _mm_and_si128(s, _mm_unpackhi_epi64(s, s));
    return _mm_cvtsi128_si64(s) as u64;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceOr, [cpu::Feature::Sse2])
fn reduce_or_u64x2(v: u64x2) u64 {
    let mut s = xi(v);
    s = _mm_or_si128(s, _mm_unpackhi_epi64(s, s));
    return _mm_cvtsi128_si64(s) as u64;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceXor, [cpu::Feature::Sse2])
fn reduce_xor_u64x2(v: u64x2) u64 {
    let mut s = xi(v);
    s = _mm_xor_si128(s, _mm_unpackhi_epi64(s, s));
    return _mm_cvtsi128_si64(s) as u64;
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAddTree, [cpu::Feature::Sse2])
fn reduce_add_tree_f32x4(v: f32x4) f32 {
    let x = xf(v);
    let h = _mm_add_ps(x, _mm_movehl_ps(x, x));
    return _mm_cvtss_f32(_mm_add_ss(h, _mm_shuffle_ps(h, h, 85)));
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceMulTree, [cpu::Feature::Sse2])
fn reduce_mul_tree_f32x4(v: f32x4) f32 {
    let x = xf(v);
    let h = _mm_mul_ps(x, _mm_movehl_ps(x, x));
    return _mm_cvtss_f32(_mm_mul_ss(h, _mm_shuffle_ps(h, h, 85)));
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceAddTree, [cpu::Feature::Sse2])
fn reduce_add_tree_f64x2(v: f64x2) f64 {
    let x = xd(v);
    return _mm_cvtsd_f64(_mm_add_sd(x, _mm_unpackhi_pd(x, x)));
}

@arch(x86_64)
@simd_impl(simd::Op::ReduceMulTree, [cpu::Feature::Sse2])
fn reduce_mul_tree_f64x2(v: f64x2) f64 {
    let x = xd(v);
    return _mm_cvtsd_f64(_mm_mul_sd(x, _mm_unpackhi_pd(x, x)));
}

@arch(x86_64)
@simd_impl(simd::Op::Dot, [cpu::Feature::Sse2])
fn dot_i16x8_i32(a: i16x8, b: i16x8) i32 {
    let s = _mm_madd_epi16(xi(a), xi(b));
    let s2 = _mm_add_epi32(s, _mm_shuffle_epi32(s, 78));
    return _mm_cvtsi128_si32(_mm_add_epi32(s2, _mm_shuffle_epi32(s2, 177)));
}

@arch(x86_64)
@simd_impl(simd::Op::SwizzleOrZero, [cpu::Feature::Ssse3])
fn swizzle_or_zero_i8x16(a: i8x16, idx: u8x16) i8x16 {
    return xiv::<i8, 16>(_mm_shuffle_epi8(xi(a), _mm_adds_epu8(xi(idx), _mm_set1_epi8(112))));
}

@arch(x86_64)
@simd_impl(simd::Op::SwizzleOrZero, [cpu::Feature::Ssse3])
fn swizzle_or_zero_u8x16(a: u8x16, idx: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_shuffle_epi8(xi(a), _mm_adds_epu8(xi(idx), _mm_set1_epi8(112))));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn load_masked_i8x16(p: *const i8, m: mask16, fb: i8x16) i8x16 {
    return xiv::<i8, 16>(unsafe _mm_mask_loadu_epi8(xi(fb), (m as u64) as u16, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn store_masked_i8x16(p: *mut i8, m: mask16, v: i8x16) {
    unsafe _mm_mask_storeu_epi8(p, (m as u64) as u16, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
fn compress_i8x16(m: mask16, v: i8x16, fill: i8x16) i8x16 {
    return xiv::<i8, 16>(_mm_mask_compress_epi8(xi(fill), (m as u64) as u16, xi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
fn expand_i8x16(m: mask16, v: i8x16, fill: i8x16) i8x16 {
    return xiv::<i8, 16>(_mm_mask_expand_epi8(xi(fill), (m as u64) as u16, xi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn load_masked_u8x16(p: *const u8, m: mask16, fb: u8x16) u8x16 {
    return xiv::<u8, 16>(unsafe _mm_mask_loadu_epi8(xi(fb), (m as u64) as u16, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn store_masked_u8x16(p: *mut u8, m: mask16, v: u8x16) {
    unsafe _mm_mask_storeu_epi8(p, (m as u64) as u16, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
fn compress_u8x16(m: mask16, v: u8x16, fill: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_mask_compress_epi8(xi(fill), (m as u64) as u16, xi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
fn expand_u8x16(m: mask16, v: u8x16, fill: u8x16) u8x16 {
    return xiv::<u8, 16>(_mm_mask_expand_epi8(xi(fill), (m as u64) as u16, xi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn load_masked_i16x8(p: *const i16, m: mask8, fb: i16x8) i16x8 {
    return xiv::<i16, 8>(unsafe _mm_mask_loadu_epi16(xi(fb), (m as u64) as u8, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn store_masked_i16x8(p: *mut i16, m: mask8, v: i16x8) {
    unsafe _mm_mask_storeu_epi16(p, (m as u64) as u8, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
fn compress_i16x8(m: mask8, v: i16x8, fill: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_mask_compress_epi16(xi(fill), (m as u64) as u8, xi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
fn expand_i16x8(m: mask8, v: i16x8, fill: i16x8) i16x8 {
    return xiv::<i16, 8>(_mm_mask_expand_epi16(xi(fill), (m as u64) as u8, xi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn load_masked_u16x8(p: *const u16, m: mask8, fb: u16x8) u16x8 {
    return xiv::<u16, 8>(unsafe _mm_mask_loadu_epi16(xi(fb), (m as u64) as u8, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn store_masked_u16x8(p: *mut u16, m: mask8, v: u16x8) {
    unsafe _mm_mask_storeu_epi16(p, (m as u64) as u8, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
fn compress_u16x8(m: mask8, v: u16x8, fill: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_mask_compress_epi16(xi(fill), (m as u64) as u8, xi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
fn expand_u16x8(m: mask8, v: u16x8, fill: u16x8) u16x8 {
    return xiv::<u16, 8>(_mm_mask_expand_epi16(xi(fill), (m as u64) as u8, xi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn load_masked_i32x4(p: *const i32, m: mask4, fb: i32x4) i32x4 {
    return xiv::<i32, 4>(unsafe _mm_mask_loadu_epi32(xi(fb), (m as u64) as u8, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn store_masked_i32x4(p: *mut i32, m: mask4, v: i32x4) {
    unsafe _mm_mask_storeu_epi32(p, (m as u64) as u8, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn compress_i32x4(m: mask4, v: i32x4, fill: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_mask_compress_epi32(xi(fill), (m as u64) as u8, xi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn expand_i32x4(m: mask4, v: i32x4, fill: i32x4) i32x4 {
    return xiv::<i32, 4>(_mm_mask_expand_epi32(xi(fill), (m as u64) as u8, xi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx2])
fn load_masked_i32x4_avx2(p: *const i32, m: mask4, fb: i32x4) i32x4 {
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let s = _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64) as i32), b), b);
    let r = unsafe _mm_maskload_epi32(p, s);
    return xiv::<i32, 4>(_mm_blendv_epi8(xi(fb), r, s));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx2])
fn store_masked_i32x4_avx2(p: *mut i32, m: mask4, v: i32x4) {
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let s = _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64) as i32), b), b);
    unsafe _mm_maskstore_epi32(p, s, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn load_masked_u32x4(p: *const u32, m: mask4, fb: u32x4) u32x4 {
    return xiv::<u32, 4>(unsafe _mm_mask_loadu_epi32(xi(fb), (m as u64) as u8, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn store_masked_u32x4(p: *mut u32, m: mask4, v: u32x4) {
    unsafe _mm_mask_storeu_epi32(p, (m as u64) as u8, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn compress_u32x4(m: mask4, v: u32x4, fill: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_mask_compress_epi32(xi(fill), (m as u64) as u8, xi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn expand_u32x4(m: mask4, v: u32x4, fill: u32x4) u32x4 {
    return xiv::<u32, 4>(_mm_mask_expand_epi32(xi(fill), (m as u64) as u8, xi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx2])
fn load_masked_u32x4_avx2(p: *const u32, m: mask4, fb: u32x4) u32x4 {
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let s = _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64) as i32), b), b);
    let r = unsafe _mm_maskload_epi32(p as *const i32, s);
    return xiv::<u32, 4>(_mm_blendv_epi8(xi(fb), r, s));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx2])
fn store_masked_u32x4_avx2(p: *mut u32, m: mask4, v: u32x4) {
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let s = _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64) as i32), b), b);
    unsafe _mm_maskstore_epi32(p as *mut i32, s, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn load_masked_i64x2(p: *const i64, m: mask2, fb: i64x2) i64x2 {
    return xiv::<i64, 2>(unsafe _mm_mask_loadu_epi64(xi(fb), (m as u64) as u8, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn store_masked_i64x2(p: *mut i64, m: mask2, v: i64x2) {
    unsafe _mm_mask_storeu_epi64(p, (m as u64) as u8, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn compress_i64x2(m: mask2, v: i64x2, fill: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_mask_compress_epi64(xi(fill), (m as u64) as u8, xi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn expand_i64x2(m: mask2, v: i64x2, fill: i64x2) i64x2 {
    return xiv::<i64, 2>(_mm_mask_expand_epi64(xi(fill), (m as u64) as u8, xi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx2])
fn load_masked_i64x2_avx2(p: *const i64, m: mask2, fb: i64x2) i64x2 {
    let b = _mm_set_epi64x(2, 1);
    let s = _mm_cmpeq_epi64(_mm_and_si128(_mm_set1_epi64x((m as u64) as i64), b), b);
    let r = unsafe _mm_maskload_epi64(vc(p), s);
    return xiv::<i64, 2>(_mm_blendv_epi8(xi(fb), r, s));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx2])
fn store_masked_i64x2_avx2(p: *mut i64, m: mask2, v: i64x2) {
    let b = _mm_set_epi64x(2, 1);
    let s = _mm_cmpeq_epi64(_mm_and_si128(_mm_set1_epi64x((m as u64) as i64), b), b);
    unsafe _mm_maskstore_epi64(vm(p), s, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn load_masked_u64x2(p: *const u64, m: mask2, fb: u64x2) u64x2 {
    return xiv::<u64, 2>(unsafe _mm_mask_loadu_epi64(xi(fb), (m as u64) as u8, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn store_masked_u64x2(p: *mut u64, m: mask2, v: u64x2) {
    unsafe _mm_mask_storeu_epi64(p, (m as u64) as u8, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn compress_u64x2(m: mask2, v: u64x2, fill: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_mask_compress_epi64(xi(fill), (m as u64) as u8, xi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn expand_u64x2(m: mask2, v: u64x2, fill: u64x2) u64x2 {
    return xiv::<u64, 2>(_mm_mask_expand_epi64(xi(fill), (m as u64) as u8, xi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx2])
fn load_masked_u64x2_avx2(p: *const u64, m: mask2, fb: u64x2) u64x2 {
    let b = _mm_set_epi64x(2, 1);
    let s = _mm_cmpeq_epi64(_mm_and_si128(_mm_set1_epi64x((m as u64) as i64), b), b);
    let r = unsafe _mm_maskload_epi64(vc(p), s);
    return xiv::<u64, 2>(_mm_blendv_epi8(xi(fb), r, s));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx2])
fn store_masked_u64x2_avx2(p: *mut u64, m: mask2, v: u64x2) {
    let b = _mm_set_epi64x(2, 1);
    let s = _mm_cmpeq_epi64(_mm_and_si128(_mm_set1_epi64x((m as u64) as i64), b), b);
    unsafe _mm_maskstore_epi64(vm(p), s, xi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn load_masked_f32x4(p: *const f32, m: mask4, fb: f32x4) f32x4 {
    return xfv::<f32, 4>(unsafe _mm_mask_loadu_ps(xf(fb), (m as u64) as u8, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn store_masked_f32x4(p: *mut f32, m: mask4, v: f32x4) {
    unsafe _mm_mask_storeu_ps(p, (m as u64) as u8, xf(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn compress_f32x4(m: mask4, v: f32x4, fill: f32x4) f32x4 {
    return xfv::<f32, 4>(_mm_mask_compress_ps(xf(fill), (m as u64) as u8, xf(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn expand_f32x4(m: mask4, v: f32x4, fill: f32x4) f32x4 {
    return xfv::<f32, 4>(_mm_mask_expand_ps(xf(fill), (m as u64) as u8, xf(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx2])
fn load_masked_f32x4_avx2(p: *const f32, m: mask4, fb: f32x4) f32x4 {
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let s = _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64) as i32), b), b);
    let r = unsafe _mm_maskload_ps(p, s);
    return xfv::<f32, 4>(_mm_blendv_ps(xf(fb), r, _mm_castsi128_ps(s)));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx2])
fn store_masked_f32x4_avx2(p: *mut f32, m: mask4, v: f32x4) {
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let s = _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64) as i32), b), b);
    unsafe _mm_maskstore_ps(p, s, xf(v));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn load_masked_f64x2(p: *const f64, m: mask2, fb: f64x2) f64x2 {
    return xdv::<f64, 2>(unsafe _mm_mask_loadu_pd(xd(fb), (m as u64) as u8, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn store_masked_f64x2(p: *mut f64, m: mask2, v: f64x2) {
    unsafe _mm_mask_storeu_pd(p, (m as u64) as u8, xd(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn compress_f64x2(m: mask2, v: f64x2, fill: f64x2) f64x2 {
    return xdv::<f64, 2>(_mm_mask_compress_pd(xd(fill), (m as u64) as u8, xd(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn expand_f64x2(m: mask2, v: f64x2, fill: f64x2) f64x2 {
    return xdv::<f64, 2>(_mm_mask_expand_pd(xd(fill), (m as u64) as u8, xd(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx2])
fn load_masked_f64x2_avx2(p: *const f64, m: mask2, fb: f64x2) f64x2 {
    let b = _mm_set_epi64x(2, 1);
    let s = _mm_cmpeq_epi64(_mm_and_si128(_mm_set1_epi64x((m as u64) as i64), b), b);
    let r = unsafe _mm_maskload_pd(p, s);
    return xdv::<f64, 2>(_mm_blendv_pd(xd(fb), r, _mm_castsi128_pd(s)));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx2])
fn store_masked_f64x2_avx2(p: *mut f64, m: mask2, v: f64x2) {
    let b = _mm_set_epi64x(2, 1);
    let s = _mm_cmpeq_epi64(_mm_and_si128(_mm_set1_epi64x((m as u64) as i64), b), b);
    unsafe _mm_maskstore_pd(p, s, xd(v));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn load_masked_i8x32(p: *const i8, m: mask32, fb: i8x32) i8x32 {
    return yiv::<i8, 32>(unsafe _mm256_mask_loadu_epi8(yi(fb), (m as u64) as u32, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn store_masked_i8x32(p: *mut i8, m: mask32, v: i8x32) {
    unsafe _mm256_mask_storeu_epi8(p, (m as u64) as u32, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
fn compress_i8x32(m: mask32, v: i8x32, fill: i8x32) i8x32 {
    return yiv::<i8, 32>(_mm256_mask_compress_epi8(yi(fill), (m as u64) as u32, yi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
fn expand_i8x32(m: mask32, v: i8x32, fill: i8x32) i8x32 {
    return yiv::<i8, 32>(_mm256_mask_expand_epi8(yi(fill), (m as u64) as u32, yi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn load_masked_u8x32(p: *const u8, m: mask32, fb: u8x32) u8x32 {
    return yiv::<u8, 32>(unsafe _mm256_mask_loadu_epi8(yi(fb), (m as u64) as u32, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn store_masked_u8x32(p: *mut u8, m: mask32, v: u8x32) {
    unsafe _mm256_mask_storeu_epi8(p, (m as u64) as u32, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
fn compress_u8x32(m: mask32, v: u8x32, fill: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_mask_compress_epi8(yi(fill), (m as u64) as u32, yi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
fn expand_u8x32(m: mask32, v: u8x32, fill: u8x32) u8x32 {
    return yiv::<u8, 32>(_mm256_mask_expand_epi8(yi(fill), (m as u64) as u32, yi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn load_masked_i16x16(p: *const i16, m: mask16, fb: i16x16) i16x16 {
    return yiv::<i16, 16>(unsafe _mm256_mask_loadu_epi16(yi(fb), (m as u64) as u16, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn store_masked_i16x16(p: *mut i16, m: mask16, v: i16x16) {
    unsafe _mm256_mask_storeu_epi16(p, (m as u64) as u16, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
fn compress_i16x16(m: mask16, v: i16x16, fill: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_mask_compress_epi16(yi(fill), (m as u64) as u16, yi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
fn expand_i16x16(m: mask16, v: i16x16, fill: i16x16) i16x16 {
    return yiv::<i16, 16>(_mm256_mask_expand_epi16(yi(fill), (m as u64) as u16, yi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn load_masked_u16x16(p: *const u16, m: mask16, fb: u16x16) u16x16 {
    return yiv::<u16, 16>(unsafe _mm256_mask_loadu_epi16(yi(fb), (m as u64) as u16, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl, cpu::Feature::Avx512bw])
fn store_masked_u16x16(p: *mut u16, m: mask16, v: u16x16) {
    unsafe _mm256_mask_storeu_epi16(p, (m as u64) as u16, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
fn compress_u16x16(m: mask16, v: u16x16, fill: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_mask_compress_epi16(yi(fill), (m as u64) as u16, yi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512vbmi2, cpu::Feature::Avx512vl])
fn expand_u16x16(m: mask16, v: u16x16, fill: u16x16) u16x16 {
    return yiv::<u16, 16>(_mm256_mask_expand_epi16(yi(fill), (m as u64) as u16, yi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn load_masked_i32x8(p: *const i32, m: mask8, fb: i32x8) i32x8 {
    return yiv::<i32, 8>(unsafe _mm256_mask_loadu_epi32(yi(fb), (m as u64) as u8, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn store_masked_i32x8(p: *mut i32, m: mask8, v: i32x8) {
    unsafe _mm256_mask_storeu_epi32(p, (m as u64) as u8, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn compress_i32x8(m: mask8, v: i32x8, fill: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_mask_compress_epi32(yi(fill), (m as u64) as u8, yi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn expand_i32x8(m: mask8, v: i32x8, fill: i32x8) i32x8 {
    return yiv::<i32, 8>(_mm256_mask_expand_epi32(yi(fill), (m as u64) as u8, yi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx2])
fn load_masked_i32x8_avx2(p: *const i32, m: mask8, fb: i32x8) i32x8 {
    let b = _mm256_setr_epi32(1, 2, 4, 8, 16, 32, 64, 128);
    let s = _mm256_cmpeq_epi32(_mm256_and_si256(_mm256_set1_epi32((m as u64) as i32), b), b);
    let r = unsafe _mm256_maskload_epi32(p, s);
    return yiv::<i32, 8>(_mm256_blendv_epi8(yi(fb), r, s));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx2])
fn store_masked_i32x8_avx2(p: *mut i32, m: mask8, v: i32x8) {
    let b = _mm256_setr_epi32(1, 2, 4, 8, 16, 32, 64, 128);
    let s = _mm256_cmpeq_epi32(_mm256_and_si256(_mm256_set1_epi32((m as u64) as i32), b), b);
    unsafe _mm256_maskstore_epi32(p, s, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn load_masked_u32x8(p: *const u32, m: mask8, fb: u32x8) u32x8 {
    return yiv::<u32, 8>(unsafe _mm256_mask_loadu_epi32(yi(fb), (m as u64) as u8, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn store_masked_u32x8(p: *mut u32, m: mask8, v: u32x8) {
    unsafe _mm256_mask_storeu_epi32(p, (m as u64) as u8, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn compress_u32x8(m: mask8, v: u32x8, fill: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_mask_compress_epi32(yi(fill), (m as u64) as u8, yi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn expand_u32x8(m: mask8, v: u32x8, fill: u32x8) u32x8 {
    return yiv::<u32, 8>(_mm256_mask_expand_epi32(yi(fill), (m as u64) as u8, yi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx2])
fn load_masked_u32x8_avx2(p: *const u32, m: mask8, fb: u32x8) u32x8 {
    let b = _mm256_setr_epi32(1, 2, 4, 8, 16, 32, 64, 128);
    let s = _mm256_cmpeq_epi32(_mm256_and_si256(_mm256_set1_epi32((m as u64) as i32), b), b);
    let r = unsafe _mm256_maskload_epi32(p as *const i32, s);
    return yiv::<u32, 8>(_mm256_blendv_epi8(yi(fb), r, s));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx2])
fn store_masked_u32x8_avx2(p: *mut u32, m: mask8, v: u32x8) {
    let b = _mm256_setr_epi32(1, 2, 4, 8, 16, 32, 64, 128);
    let s = _mm256_cmpeq_epi32(_mm256_and_si256(_mm256_set1_epi32((m as u64) as i32), b), b);
    unsafe _mm256_maskstore_epi32(p as *mut i32, s, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn load_masked_i64x4(p: *const i64, m: mask4, fb: i64x4) i64x4 {
    return yiv::<i64, 4>(unsafe _mm256_mask_loadu_epi64(yi(fb), (m as u64) as u8, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn store_masked_i64x4(p: *mut i64, m: mask4, v: i64x4) {
    unsafe _mm256_mask_storeu_epi64(p, (m as u64) as u8, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn compress_i64x4(m: mask4, v: i64x4, fill: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_mask_compress_epi64(yi(fill), (m as u64) as u8, yi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn expand_i64x4(m: mask4, v: i64x4, fill: i64x4) i64x4 {
    return yiv::<i64, 4>(_mm256_mask_expand_epi64(yi(fill), (m as u64) as u8, yi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx2])
fn load_masked_i64x4_avx2(p: *const i64, m: mask4, fb: i64x4) i64x4 {
    let b = _mm256_set_epi64x(8, 4, 2, 1);
    let s = _mm256_cmpeq_epi64(_mm256_and_si256(_mm256_set1_epi64x((m as u64) as i64), b), b);
    let r = unsafe _mm256_maskload_epi64(vc(p), s);
    return yiv::<i64, 4>(_mm256_blendv_epi8(yi(fb), r, s));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx2])
fn store_masked_i64x4_avx2(p: *mut i64, m: mask4, v: i64x4) {
    let b = _mm256_set_epi64x(8, 4, 2, 1);
    let s = _mm256_cmpeq_epi64(_mm256_and_si256(_mm256_set1_epi64x((m as u64) as i64), b), b);
    unsafe _mm256_maskstore_epi64(vm(p), s, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn load_masked_u64x4(p: *const u64, m: mask4, fb: u64x4) u64x4 {
    return yiv::<u64, 4>(unsafe _mm256_mask_loadu_epi64(yi(fb), (m as u64) as u8, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn store_masked_u64x4(p: *mut u64, m: mask4, v: u64x4) {
    unsafe _mm256_mask_storeu_epi64(p, (m as u64) as u8, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn compress_u64x4(m: mask4, v: u64x4, fill: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_mask_compress_epi64(yi(fill), (m as u64) as u8, yi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn expand_u64x4(m: mask4, v: u64x4, fill: u64x4) u64x4 {
    return yiv::<u64, 4>(_mm256_mask_expand_epi64(yi(fill), (m as u64) as u8, yi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx2])
fn load_masked_u64x4_avx2(p: *const u64, m: mask4, fb: u64x4) u64x4 {
    let b = _mm256_set_epi64x(8, 4, 2, 1);
    let s = _mm256_cmpeq_epi64(_mm256_and_si256(_mm256_set1_epi64x((m as u64) as i64), b), b);
    let r = unsafe _mm256_maskload_epi64(vc(p), s);
    return yiv::<u64, 4>(_mm256_blendv_epi8(yi(fb), r, s));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx2])
fn store_masked_u64x4_avx2(p: *mut u64, m: mask4, v: u64x4) {
    let b = _mm256_set_epi64x(8, 4, 2, 1);
    let s = _mm256_cmpeq_epi64(_mm256_and_si256(_mm256_set1_epi64x((m as u64) as i64), b), b);
    unsafe _mm256_maskstore_epi64(vm(p), s, yi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn load_masked_f32x8(p: *const f32, m: mask8, fb: f32x8) f32x8 {
    return yfv::<f32, 8>(unsafe _mm256_mask_loadu_ps(yf(fb), (m as u64) as u8, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn store_masked_f32x8(p: *mut f32, m: mask8, v: f32x8) {
    unsafe _mm256_mask_storeu_ps(p, (m as u64) as u8, yf(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn compress_f32x8(m: mask8, v: f32x8, fill: f32x8) f32x8 {
    return yfv::<f32, 8>(_mm256_mask_compress_ps(yf(fill), (m as u64) as u8, yf(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn expand_f32x8(m: mask8, v: f32x8, fill: f32x8) f32x8 {
    return yfv::<f32, 8>(_mm256_mask_expand_ps(yf(fill), (m as u64) as u8, yf(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx2])
fn load_masked_f32x8_avx2(p: *const f32, m: mask8, fb: f32x8) f32x8 {
    let b = _mm256_setr_epi32(1, 2, 4, 8, 16, 32, 64, 128);
    let s = _mm256_cmpeq_epi32(_mm256_and_si256(_mm256_set1_epi32((m as u64) as i32), b), b);
    let r = unsafe _mm256_maskload_ps(p, s);
    return yfv::<f32, 8>(_mm256_blendv_ps(yf(fb), r, _mm256_castsi256_ps(s)));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx2])
fn store_masked_f32x8_avx2(p: *mut f32, m: mask8, v: f32x8) {
    let b = _mm256_setr_epi32(1, 2, 4, 8, 16, 32, 64, 128);
    let s = _mm256_cmpeq_epi32(_mm256_and_si256(_mm256_set1_epi32((m as u64) as i32), b), b);
    unsafe _mm256_maskstore_ps(p, s, yf(v));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn load_masked_f64x4(p: *const f64, m: mask4, fb: f64x4) f64x4 {
    return ydv::<f64, 4>(unsafe _mm256_mask_loadu_pd(yd(fb), (m as u64) as u8, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn store_masked_f64x4(p: *mut f64, m: mask4, v: f64x4) {
    unsafe _mm256_mask_storeu_pd(p, (m as u64) as u8, yd(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn compress_f64x4(m: mask4, v: f64x4, fill: f64x4) f64x4 {
    return ydv::<f64, 4>(_mm256_mask_compress_pd(yd(fill), (m as u64) as u8, yd(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f, cpu::Feature::Avx512vl])
fn expand_f64x4(m: mask4, v: f64x4, fill: f64x4) f64x4 {
    return ydv::<f64, 4>(_mm256_mask_expand_pd(yd(fill), (m as u64) as u8, yd(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx2])
fn load_masked_f64x4_avx2(p: *const f64, m: mask4, fb: f64x4) f64x4 {
    let b = _mm256_set_epi64x(8, 4, 2, 1);
    let s = _mm256_cmpeq_epi64(_mm256_and_si256(_mm256_set1_epi64x((m as u64) as i64), b), b);
    let r = unsafe _mm256_maskload_pd(p, s);
    return ydv::<f64, 4>(_mm256_blendv_pd(yd(fb), r, _mm256_castsi256_pd(s)));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx2])
fn store_masked_f64x4_avx2(p: *mut f64, m: mask4, v: f64x4) {
    let b = _mm256_set_epi64x(8, 4, 2, 1);
    let s = _mm256_cmpeq_epi64(_mm256_and_si256(_mm256_set1_epi64x((m as u64) as i64), b), b);
    unsafe _mm256_maskstore_pd(p, s, yd(v));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512bw])
fn load_masked_i8x64(p: *const i8, m: mask64, fb: i8x64) i8x64 {
    return ziv::<i8, 64>(unsafe _mm512_mask_loadu_epi8(zi(fb), m as u64, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512bw])
fn store_masked_i8x64(p: *mut i8, m: mask64, v: i8x64) {
    unsafe _mm512_mask_storeu_epi8(p, m as u64, zi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512vbmi2])
fn compress_i8x64(m: mask64, v: i8x64, fill: i8x64) i8x64 {
    return ziv::<i8, 64>(_mm512_mask_compress_epi8(zi(fill), m as u64, zi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512vbmi2])
fn expand_i8x64(m: mask64, v: i8x64, fill: i8x64) i8x64 {
    return ziv::<i8, 64>(_mm512_mask_expand_epi8(zi(fill), m as u64, zi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512bw])
fn load_masked_u8x64(p: *const u8, m: mask64, fb: u8x64) u8x64 {
    return ziv::<u8, 64>(unsafe _mm512_mask_loadu_epi8(zi(fb), m as u64, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512bw])
fn store_masked_u8x64(p: *mut u8, m: mask64, v: u8x64) {
    unsafe _mm512_mask_storeu_epi8(p, m as u64, zi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512vbmi2])
fn compress_u8x64(m: mask64, v: u8x64, fill: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_mask_compress_epi8(zi(fill), m as u64, zi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512vbmi2])
fn expand_u8x64(m: mask64, v: u8x64, fill: u8x64) u8x64 {
    return ziv::<u8, 64>(_mm512_mask_expand_epi8(zi(fill), m as u64, zi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512bw])
fn load_masked_i16x32(p: *const i16, m: mask32, fb: i16x32) i16x32 {
    return ziv::<i16, 32>(unsafe _mm512_mask_loadu_epi16(zi(fb), (m as u64) as u32, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512bw])
fn store_masked_i16x32(p: *mut i16, m: mask32, v: i16x32) {
    unsafe _mm512_mask_storeu_epi16(p, (m as u64) as u32, zi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512vbmi2])
fn compress_i16x32(m: mask32, v: i16x32, fill: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_mask_compress_epi16(zi(fill), (m as u64) as u32, zi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512vbmi2])
fn expand_i16x32(m: mask32, v: i16x32, fill: i16x32) i16x32 {
    return ziv::<i16, 32>(_mm512_mask_expand_epi16(zi(fill), (m as u64) as u32, zi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512bw])
fn load_masked_u16x32(p: *const u16, m: mask32, fb: u16x32) u16x32 {
    return ziv::<u16, 32>(unsafe _mm512_mask_loadu_epi16(zi(fb), (m as u64) as u32, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512bw])
fn store_masked_u16x32(p: *mut u16, m: mask32, v: u16x32) {
    unsafe _mm512_mask_storeu_epi16(p, (m as u64) as u32, zi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512vbmi2])
fn compress_u16x32(m: mask32, v: u16x32, fill: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_mask_compress_epi16(zi(fill), (m as u64) as u32, zi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512vbmi2])
fn expand_u16x32(m: mask32, v: u16x32, fill: u16x32) u16x32 {
    return ziv::<u16, 32>(_mm512_mask_expand_epi16(zi(fill), (m as u64) as u32, zi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f])
fn load_masked_i32x16(p: *const i32, m: mask16, fb: i32x16) i32x16 {
    return ziv::<i32, 16>(unsafe _mm512_mask_loadu_epi32(zi(fb), (m as u64) as u16, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f])
fn store_masked_i32x16(p: *mut i32, m: mask16, v: i32x16) {
    unsafe _mm512_mask_storeu_epi32(p, (m as u64) as u16, zi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f])
fn compress_i32x16(m: mask16, v: i32x16, fill: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_mask_compress_epi32(zi(fill), (m as u64) as u16, zi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f])
fn expand_i32x16(m: mask16, v: i32x16, fill: i32x16) i32x16 {
    return ziv::<i32, 16>(_mm512_mask_expand_epi32(zi(fill), (m as u64) as u16, zi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f])
fn load_masked_u32x16(p: *const u32, m: mask16, fb: u32x16) u32x16 {
    return ziv::<u32, 16>(unsafe _mm512_mask_loadu_epi32(zi(fb), (m as u64) as u16, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f])
fn store_masked_u32x16(p: *mut u32, m: mask16, v: u32x16) {
    unsafe _mm512_mask_storeu_epi32(p, (m as u64) as u16, zi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f])
fn compress_u32x16(m: mask16, v: u32x16, fill: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_mask_compress_epi32(zi(fill), (m as u64) as u16, zi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f])
fn expand_u32x16(m: mask16, v: u32x16, fill: u32x16) u32x16 {
    return ziv::<u32, 16>(_mm512_mask_expand_epi32(zi(fill), (m as u64) as u16, zi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f])
fn load_masked_i64x8(p: *const i64, m: mask8, fb: i64x8) i64x8 {
    return ziv::<i64, 8>(unsafe _mm512_mask_loadu_epi64(zi(fb), (m as u64) as u8, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f])
fn store_masked_i64x8(p: *mut i64, m: mask8, v: i64x8) {
    unsafe _mm512_mask_storeu_epi64(p, (m as u64) as u8, zi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f])
fn compress_i64x8(m: mask8, v: i64x8, fill: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_mask_compress_epi64(zi(fill), (m as u64) as u8, zi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f])
fn expand_i64x8(m: mask8, v: i64x8, fill: i64x8) i64x8 {
    return ziv::<i64, 8>(_mm512_mask_expand_epi64(zi(fill), (m as u64) as u8, zi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f])
fn load_masked_u64x8(p: *const u64, m: mask8, fb: u64x8) u64x8 {
    return ziv::<u64, 8>(unsafe _mm512_mask_loadu_epi64(zi(fb), (m as u64) as u8, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f])
fn store_masked_u64x8(p: *mut u64, m: mask8, v: u64x8) {
    unsafe _mm512_mask_storeu_epi64(p, (m as u64) as u8, zi(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f])
fn compress_u64x8(m: mask8, v: u64x8, fill: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_mask_compress_epi64(zi(fill), (m as u64) as u8, zi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f])
fn expand_u64x8(m: mask8, v: u64x8, fill: u64x8) u64x8 {
    return ziv::<u64, 8>(_mm512_mask_expand_epi64(zi(fill), (m as u64) as u8, zi(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f])
fn load_masked_f32x16(p: *const f32, m: mask16, fb: f32x16) f32x16 {
    return zfv::<f32, 16>(unsafe _mm512_mask_loadu_ps(zf(fb), (m as u64) as u16, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f])
fn store_masked_f32x16(p: *mut f32, m: mask16, v: f32x16) {
    unsafe _mm512_mask_storeu_ps(p, (m as u64) as u16, zf(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f])
fn compress_f32x16(m: mask16, v: f32x16, fill: f32x16) f32x16 {
    return zfv::<f32, 16>(_mm512_mask_compress_ps(zf(fill), (m as u64) as u16, zf(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f])
fn expand_f32x16(m: mask16, v: f32x16, fill: f32x16) f32x16 {
    return zfv::<f32, 16>(_mm512_mask_expand_ps(zf(fill), (m as u64) as u16, zf(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::LoadMasked, [cpu::Feature::Avx512f])
fn load_masked_f64x8(p: *const f64, m: mask8, fb: f64x8) f64x8 {
    return zdv::<f64, 8>(unsafe _mm512_mask_loadu_pd(zd(fb), (m as u64) as u8, p));
}

@arch(x86_64)
@simd_impl(simd::Op::StoreMasked, [cpu::Feature::Avx512f])
fn store_masked_f64x8(p: *mut f64, m: mask8, v: f64x8) {
    unsafe _mm512_mask_storeu_pd(p, (m as u64) as u8, zd(v));
}

@arch(x86_64)
@simd_impl(simd::Op::Compress, [cpu::Feature::Avx512f])
fn compress_f64x8(m: mask8, v: f64x8, fill: f64x8) f64x8 {
    return zdv::<f64, 8>(_mm512_mask_compress_pd(zd(fill), (m as u64) as u8, zd(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Expand, [cpu::Feature::Avx512f])
fn expand_f64x8(m: mask8, v: f64x8, fill: f64x8) f64x8 {
    return zdv::<f64, 8>(_mm512_mask_expand_pd(zd(fill), (m as u64) as u8, zd(v)));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_i32x4_u32(p: *const i32, idx: u32x4, m: mask4, fb: i32x4) i32x4 {
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let s = _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64) as i32), b), b);
    return xiv::<i32, 4>(unsafe _mm256_mask_i64gather_epi32(xi(fb), p, _mm256_cvtepu32_epi64(xi(idx)), s, 4));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_i32x8_u32(p: *const i32, idx: u32x8, m: mask8, fb: i32x8) i32x8 {
    let x = yi(idx);
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let lo = unsafe _mm256_mask_i64gather_epi32(
        xi(fb.low_half()),
        p,
        _mm256_cvtepu32_epi64(_mm256_castsi256_si128(x)),
        _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64 & 15) as i32), b), b),
        4,
    );
    let hi = unsafe _mm256_mask_i64gather_epi32(
        xi(fb.high_half()),
        p,
        _mm256_cvtepu32_epi64(unsafe _mm256_extracti128_si256(x, 1)),
        _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64 >> 4) as i32), b), b),
        4,
    );
    return yiv::<i32, 8>(_mm256_set_m128i(hi, lo));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx512f])
fn gather_i32x8_u32_avx512f(p: *const i32, idx: u32x8, m: mask8, fb: i32x8) i32x8 {
    return yiv::<i32, 8>(
        unsafe _mm512_mask_i64gather_epi32(yi(fb), (m as u64) as u8, _mm512_cvtepu32_epi64(yi(idx)), p, 4),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Scatter, [cpu::Feature::Avx512f])
fn scatter_i32x8_u32(p: *mut i32, idx: u32x8, m: mask8, v: i32x8) {
    unsafe _mm512_mask_i64scatter_epi32(p, (m as u64) as u8, _mm512_cvtepu32_epi64(yi(idx)), yi(v), 4);
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx512f])
fn gather_i32x16_u32(p: *const i32, idx: u32x16, m: mask16, fb: i32x16) i32x16 {
    let x = zi(idx);
    let lo = unsafe _mm512_mask_i64gather_epi32(
        yi(fb.low_half()),
        (m as u64 & 255) as u8,
        _mm512_cvtepu32_epi64(_mm512_castsi512_si256(x)),
        p,
        4,
    );
    let hi = unsafe _mm512_mask_i64gather_epi32(
        yi(fb.high_half()),
        (m as u64 >> 8) as u8,
        _mm512_cvtepu32_epi64(unsafe _mm512_extracti64x4_epi64(x, 1)),
        p,
        4,
    );
    return ziv::<i32, 16>(unsafe _mm512_inserti64x4(_mm512_castsi256_si512(lo), hi, 1));
}

@arch(x86_64)
@simd_impl(simd::Op::Scatter, [cpu::Feature::Avx512f])
fn scatter_i32x16_u32(p: *mut i32, idx: u32x16, m: mask16, v: i32x16) {
    let x = zi(idx);
    unsafe _mm512_mask_i64scatter_epi32(
        p,
        (m as u64 & 255) as u8,
        _mm512_cvtepu32_epi64(_mm512_castsi512_si256(x)),
        yi(v.low_half()),
        4,
    );
    unsafe _mm512_mask_i64scatter_epi32(
        p,
        (m as u64 >> 8) as u8,
        _mm512_cvtepu32_epi64(unsafe _mm512_extracti64x4_epi64(x, 1)),
        yi(v.high_half()),
        4,
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_i32x4_u64(p: *const i32, idx: u64x4, m: mask4, fb: i32x4) i32x4 {
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let s = _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64) as i32), b), b);
    return xiv::<i32, 4>(unsafe _mm256_mask_i64gather_epi32(xi(fb), p, yi(idx), s, 4));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_i32x8_u64(p: *const i32, idx: u64x8, m: mask8, fb: i32x8) i32x8 {
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let lo = unsafe _mm256_mask_i64gather_epi32(
        xi(fb.low_half()),
        p,
        yi(idx.low_half()),
        _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64 & 15) as i32), b), b),
        4,
    );
    let hi = unsafe _mm256_mask_i64gather_epi32(
        xi(fb.high_half()),
        p,
        yi(idx.high_half()),
        _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64 >> 4) as i32), b), b),
        4,
    );
    return yiv::<i32, 8>(_mm256_set_m128i(hi, lo));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx512f])
fn gather_i32x8_u64_avx512f(p: *const i32, idx: u64x8, m: mask8, fb: i32x8) i32x8 {
    return yiv::<i32, 8>(unsafe _mm512_mask_i64gather_epi32(yi(fb), (m as u64) as u8, zi(idx), p, 4));
}

@arch(x86_64)
@simd_impl(simd::Op::Scatter, [cpu::Feature::Avx512f])
fn scatter_i32x8_u64(p: *mut i32, idx: u64x8, m: mask8, v: i32x8) {
    unsafe _mm512_mask_i64scatter_epi32(p, (m as u64) as u8, zi(idx), yi(v), 4);
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_u32x4_u32(p: *const u32, idx: u32x4, m: mask4, fb: u32x4) u32x4 {
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let s = _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64) as i32), b), b);
    return xiv::<u32, 4>(
        unsafe _mm256_mask_i64gather_epi32(xi(fb), p as *const i32, _mm256_cvtepu32_epi64(xi(idx)), s, 4),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_u32x8_u32(p: *const u32, idx: u32x8, m: mask8, fb: u32x8) u32x8 {
    let x = yi(idx);
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let lo = unsafe _mm256_mask_i64gather_epi32(
        xi(fb.low_half()),
        p as *const i32,
        _mm256_cvtepu32_epi64(_mm256_castsi256_si128(x)),
        _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64 & 15) as i32), b), b),
        4,
    );
    let hi = unsafe _mm256_mask_i64gather_epi32(
        xi(fb.high_half()),
        p as *const i32,
        _mm256_cvtepu32_epi64(unsafe _mm256_extracti128_si256(x, 1)),
        _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64 >> 4) as i32), b), b),
        4,
    );
    return yiv::<u32, 8>(_mm256_set_m128i(hi, lo));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx512f])
fn gather_u32x8_u32_avx512f(p: *const u32, idx: u32x8, m: mask8, fb: u32x8) u32x8 {
    return yiv::<u32, 8>(
        unsafe _mm512_mask_i64gather_epi32(yi(fb), (m as u64) as u8, _mm512_cvtepu32_epi64(yi(idx)), p, 4),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Scatter, [cpu::Feature::Avx512f])
fn scatter_u32x8_u32(p: *mut u32, idx: u32x8, m: mask8, v: u32x8) {
    unsafe _mm512_mask_i64scatter_epi32(p, (m as u64) as u8, _mm512_cvtepu32_epi64(yi(idx)), yi(v), 4);
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx512f])
fn gather_u32x16_u32(p: *const u32, idx: u32x16, m: mask16, fb: u32x16) u32x16 {
    let x = zi(idx);
    let lo = unsafe _mm512_mask_i64gather_epi32(
        yi(fb.low_half()),
        (m as u64 & 255) as u8,
        _mm512_cvtepu32_epi64(_mm512_castsi512_si256(x)),
        p,
        4,
    );
    let hi = unsafe _mm512_mask_i64gather_epi32(
        yi(fb.high_half()),
        (m as u64 >> 8) as u8,
        _mm512_cvtepu32_epi64(unsafe _mm512_extracti64x4_epi64(x, 1)),
        p,
        4,
    );
    return ziv::<u32, 16>(unsafe _mm512_inserti64x4(_mm512_castsi256_si512(lo), hi, 1));
}

@arch(x86_64)
@simd_impl(simd::Op::Scatter, [cpu::Feature::Avx512f])
fn scatter_u32x16_u32(p: *mut u32, idx: u32x16, m: mask16, v: u32x16) {
    let x = zi(idx);
    unsafe _mm512_mask_i64scatter_epi32(
        p,
        (m as u64 & 255) as u8,
        _mm512_cvtepu32_epi64(_mm512_castsi512_si256(x)),
        yi(v.low_half()),
        4,
    );
    unsafe _mm512_mask_i64scatter_epi32(
        p,
        (m as u64 >> 8) as u8,
        _mm512_cvtepu32_epi64(unsafe _mm512_extracti64x4_epi64(x, 1)),
        yi(v.high_half()),
        4,
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_u32x4_u64(p: *const u32, idx: u64x4, m: mask4, fb: u32x4) u32x4 {
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let s = _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64) as i32), b), b);
    return xiv::<u32, 4>(unsafe _mm256_mask_i64gather_epi32(xi(fb), p as *const i32, yi(idx), s, 4));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_u32x8_u64(p: *const u32, idx: u64x8, m: mask8, fb: u32x8) u32x8 {
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let lo = unsafe _mm256_mask_i64gather_epi32(
        xi(fb.low_half()),
        p as *const i32,
        yi(idx.low_half()),
        _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64 & 15) as i32), b), b),
        4,
    );
    let hi = unsafe _mm256_mask_i64gather_epi32(
        xi(fb.high_half()),
        p as *const i32,
        yi(idx.high_half()),
        _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64 >> 4) as i32), b), b),
        4,
    );
    return yiv::<u32, 8>(_mm256_set_m128i(hi, lo));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx512f])
fn gather_u32x8_u64_avx512f(p: *const u32, idx: u64x8, m: mask8, fb: u32x8) u32x8 {
    return yiv::<u32, 8>(unsafe _mm512_mask_i64gather_epi32(yi(fb), (m as u64) as u8, zi(idx), p, 4));
}

@arch(x86_64)
@simd_impl(simd::Op::Scatter, [cpu::Feature::Avx512f])
fn scatter_u32x8_u64(p: *mut u32, idx: u64x8, m: mask8, v: u32x8) {
    unsafe _mm512_mask_i64scatter_epi32(p, (m as u64) as u8, zi(idx), yi(v), 4);
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_f32x4_u32(p: *const f32, idx: u32x4, m: mask4, fb: f32x4) f32x4 {
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let s = _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64) as i32), b), b);
    return xfv::<f32, 4>(
        unsafe _mm256_mask_i64gather_ps(xf(fb), p, _mm256_cvtepu32_epi64(xi(idx)), _mm_castsi128_ps(s), 4),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_f32x8_u32(p: *const f32, idx: u32x8, m: mask8, fb: f32x8) f32x8 {
    let x = yi(idx);
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let lo = unsafe _mm256_mask_i64gather_ps(
        xf(fb.low_half()),
        p,
        _mm256_cvtepu32_epi64(_mm256_castsi256_si128(x)),
        _mm_castsi128_ps(_mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64 & 15) as i32), b), b)),
        4,
    );
    let hi = unsafe _mm256_mask_i64gather_ps(
        xf(fb.high_half()),
        p,
        _mm256_cvtepu32_epi64(unsafe _mm256_extracti128_si256(x, 1)),
        _mm_castsi128_ps(_mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64 >> 4) as i32), b), b)),
        4,
    );
    return yfv::<f32, 8>(_mm256_set_m128(hi, lo));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx512f])
fn gather_f32x8_u32_avx512f(p: *const f32, idx: u32x8, m: mask8, fb: f32x8) f32x8 {
    return yfv::<f32, 8>(
        unsafe _mm512_mask_i64gather_ps(yf(fb), (m as u64) as u8, _mm512_cvtepu32_epi64(yi(idx)), p, 4),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Scatter, [cpu::Feature::Avx512f])
fn scatter_f32x8_u32(p: *mut f32, idx: u32x8, m: mask8, v: f32x8) {
    unsafe _mm512_mask_i64scatter_ps(p, (m as u64) as u8, _mm512_cvtepu32_epi64(yi(idx)), yf(v), 4);
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx512f])
fn gather_f32x16_u32(p: *const f32, idx: u32x16, m: mask16, fb: f32x16) f32x16 {
    let x = zi(idx);
    let lo = unsafe _mm512_mask_i64gather_ps(
        yf(fb.low_half()),
        (m as u64 & 255) as u8,
        _mm512_cvtepu32_epi64(_mm512_castsi512_si256(x)),
        p,
        4,
    );
    let hi = unsafe _mm512_mask_i64gather_ps(
        yf(fb.high_half()),
        (m as u64 >> 8) as u8,
        _mm512_cvtepu32_epi64(unsafe _mm512_extracti64x4_epi64(x, 1)),
        p,
        4,
    );
    return zfv::<f32, 16>(
        _mm512_castpd_ps(
            unsafe _mm512_insertf64x4(_mm512_castps_pd(_mm512_castps256_ps512(lo)), _mm256_castps_pd(hi), 1),
        ),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Scatter, [cpu::Feature::Avx512f])
fn scatter_f32x16_u32(p: *mut f32, idx: u32x16, m: mask16, v: f32x16) {
    let x = zi(idx);
    unsafe _mm512_mask_i64scatter_ps(
        p,
        (m as u64 & 255) as u8,
        _mm512_cvtepu32_epi64(_mm512_castsi512_si256(x)),
        yf(v.low_half()),
        4,
    );
    unsafe _mm512_mask_i64scatter_ps(
        p,
        (m as u64 >> 8) as u8,
        _mm512_cvtepu32_epi64(unsafe _mm512_extracti64x4_epi64(x, 1)),
        yf(v.high_half()),
        4,
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_f32x4_u64(p: *const f32, idx: u64x4, m: mask4, fb: f32x4) f32x4 {
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let s = _mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64) as i32), b), b);
    return xfv::<f32, 4>(unsafe _mm256_mask_i64gather_ps(xf(fb), p, yi(idx), _mm_castsi128_ps(s), 4));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_f32x8_u64(p: *const f32, idx: u64x8, m: mask8, fb: f32x8) f32x8 {
    let b = _mm_setr_epi32(1, 2, 4, 8);
    let lo = unsafe _mm256_mask_i64gather_ps(
        xf(fb.low_half()),
        p,
        yi(idx.low_half()),
        _mm_castsi128_ps(_mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64 & 15) as i32), b), b)),
        4,
    );
    let hi = unsafe _mm256_mask_i64gather_ps(
        xf(fb.high_half()),
        p,
        yi(idx.high_half()),
        _mm_castsi128_ps(_mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32((m as u64 >> 4) as i32), b), b)),
        4,
    );
    return yfv::<f32, 8>(_mm256_set_m128(hi, lo));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx512f])
fn gather_f32x8_u64_avx512f(p: *const f32, idx: u64x8, m: mask8, fb: f32x8) f32x8 {
    return yfv::<f32, 8>(unsafe _mm512_mask_i64gather_ps(yf(fb), (m as u64) as u8, zi(idx), p, 4));
}

@arch(x86_64)
@simd_impl(simd::Op::Scatter, [cpu::Feature::Avx512f])
fn scatter_f32x8_u64(p: *mut f32, idx: u64x8, m: mask8, v: f32x8) {
    unsafe _mm512_mask_i64scatter_ps(p, (m as u64) as u8, zi(idx), yf(v), 4);
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_i64x2_u32(p: *const i64, idx: Simd<u32, 2>, m: mask2, fb: i64x2) i64x2 {
    let b = _mm_set_epi64x(2, 1);
    let s = _mm_cmpeq_epi64(_mm_and_si128(_mm_set1_epi64x((m as u64) as i64), b), b);
    return xiv::<i64, 2>(unsafe _mm_mask_i64gather_epi64(xi(fb), vc(p), _mm_cvtepu32_epi64(xli(idx)), s, 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_i64x4_u32(p: *const i64, idx: u32x4, m: mask4, fb: i64x4) i64x4 {
    let b = _mm256_set_epi64x(8, 4, 2, 1);
    let s = _mm256_cmpeq_epi64(_mm256_and_si256(_mm256_set1_epi64x((m as u64) as i64), b), b);
    return yiv::<i64, 4>(unsafe _mm256_mask_i64gather_epi64(yi(fb), vc(p), _mm256_cvtepu32_epi64(xi(idx)), s, 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx512f])
fn gather_i64x8_u32(p: *const i64, idx: u32x8, m: mask8, fb: i64x8) i64x8 {
    return ziv::<i64, 8>(
        unsafe _mm512_mask_i64gather_epi64(zi(fb), (m as u64) as u8, _mm512_cvtepu32_epi64(yi(idx)), p, 8),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Scatter, [cpu::Feature::Avx512f])
fn scatter_i64x8_u32(p: *mut i64, idx: u32x8, m: mask8, v: i64x8) {
    unsafe _mm512_mask_i64scatter_epi64(p, (m as u64) as u8, _mm512_cvtepu32_epi64(yi(idx)), zi(v), 8);
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_i64x2_u64(p: *const i64, idx: u64x2, m: mask2, fb: i64x2) i64x2 {
    let b = _mm_set_epi64x(2, 1);
    let s = _mm_cmpeq_epi64(_mm_and_si128(_mm_set1_epi64x((m as u64) as i64), b), b);
    return xiv::<i64, 2>(unsafe _mm_mask_i64gather_epi64(xi(fb), vc(p), xi(idx), s, 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_i64x4_u64(p: *const i64, idx: u64x4, m: mask4, fb: i64x4) i64x4 {
    let b = _mm256_set_epi64x(8, 4, 2, 1);
    let s = _mm256_cmpeq_epi64(_mm256_and_si256(_mm256_set1_epi64x((m as u64) as i64), b), b);
    return yiv::<i64, 4>(unsafe _mm256_mask_i64gather_epi64(yi(fb), vc(p), yi(idx), s, 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx512f])
fn gather_i64x8_u64(p: *const i64, idx: u64x8, m: mask8, fb: i64x8) i64x8 {
    return ziv::<i64, 8>(unsafe _mm512_mask_i64gather_epi64(zi(fb), (m as u64) as u8, zi(idx), p, 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Scatter, [cpu::Feature::Avx512f])
fn scatter_i64x8_u64(p: *mut i64, idx: u64x8, m: mask8, v: i64x8) {
    unsafe _mm512_mask_i64scatter_epi64(p, (m as u64) as u8, zi(idx), zi(v), 8);
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_u64x2_u32(p: *const u64, idx: Simd<u32, 2>, m: mask2, fb: u64x2) u64x2 {
    let b = _mm_set_epi64x(2, 1);
    let s = _mm_cmpeq_epi64(_mm_and_si128(_mm_set1_epi64x((m as u64) as i64), b), b);
    return xiv::<u64, 2>(unsafe _mm_mask_i64gather_epi64(xi(fb), vc(p), _mm_cvtepu32_epi64(xli(idx)), s, 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_u64x4_u32(p: *const u64, idx: u32x4, m: mask4, fb: u64x4) u64x4 {
    let b = _mm256_set_epi64x(8, 4, 2, 1);
    let s = _mm256_cmpeq_epi64(_mm256_and_si256(_mm256_set1_epi64x((m as u64) as i64), b), b);
    return yiv::<u64, 4>(unsafe _mm256_mask_i64gather_epi64(yi(fb), vc(p), _mm256_cvtepu32_epi64(xi(idx)), s, 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx512f])
fn gather_u64x8_u32(p: *const u64, idx: u32x8, m: mask8, fb: u64x8) u64x8 {
    return ziv::<u64, 8>(
        unsafe _mm512_mask_i64gather_epi64(zi(fb), (m as u64) as u8, _mm512_cvtepu32_epi64(yi(idx)), p, 8),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Scatter, [cpu::Feature::Avx512f])
fn scatter_u64x8_u32(p: *mut u64, idx: u32x8, m: mask8, v: u64x8) {
    unsafe _mm512_mask_i64scatter_epi64(p, (m as u64) as u8, _mm512_cvtepu32_epi64(yi(idx)), zi(v), 8);
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_u64x2_u64(p: *const u64, idx: u64x2, m: mask2, fb: u64x2) u64x2 {
    let b = _mm_set_epi64x(2, 1);
    let s = _mm_cmpeq_epi64(_mm_and_si128(_mm_set1_epi64x((m as u64) as i64), b), b);
    return xiv::<u64, 2>(unsafe _mm_mask_i64gather_epi64(xi(fb), vc(p), xi(idx), s, 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_u64x4_u64(p: *const u64, idx: u64x4, m: mask4, fb: u64x4) u64x4 {
    let b = _mm256_set_epi64x(8, 4, 2, 1);
    let s = _mm256_cmpeq_epi64(_mm256_and_si256(_mm256_set1_epi64x((m as u64) as i64), b), b);
    return yiv::<u64, 4>(unsafe _mm256_mask_i64gather_epi64(yi(fb), vc(p), yi(idx), s, 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx512f])
fn gather_u64x8_u64(p: *const u64, idx: u64x8, m: mask8, fb: u64x8) u64x8 {
    return ziv::<u64, 8>(unsafe _mm512_mask_i64gather_epi64(zi(fb), (m as u64) as u8, zi(idx), p, 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Scatter, [cpu::Feature::Avx512f])
fn scatter_u64x8_u64(p: *mut u64, idx: u64x8, m: mask8, v: u64x8) {
    unsafe _mm512_mask_i64scatter_epi64(p, (m as u64) as u8, zi(idx), zi(v), 8);
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_f64x2_u32(p: *const f64, idx: Simd<u32, 2>, m: mask2, fb: f64x2) f64x2 {
    let b = _mm_set_epi64x(2, 1);
    let s = _mm_cmpeq_epi64(_mm_and_si128(_mm_set1_epi64x((m as u64) as i64), b), b);
    return xdv::<f64, 2>(unsafe _mm_mask_i64gather_pd(xd(fb), p, _mm_cvtepu32_epi64(xli(idx)), _mm_castsi128_pd(s), 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_f64x4_u32(p: *const f64, idx: u32x4, m: mask4, fb: f64x4) f64x4 {
    let b = _mm256_set_epi64x(8, 4, 2, 1);
    let s = _mm256_cmpeq_epi64(_mm256_and_si256(_mm256_set1_epi64x((m as u64) as i64), b), b);
    return ydv::<f64, 4>(
        unsafe _mm256_mask_i64gather_pd(yd(fb), p, _mm256_cvtepu32_epi64(xi(idx)), _mm256_castsi256_pd(s), 8),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx512f])
fn gather_f64x8_u32(p: *const f64, idx: u32x8, m: mask8, fb: f64x8) f64x8 {
    return zdv::<f64, 8>(
        unsafe _mm512_mask_i64gather_pd(zd(fb), (m as u64) as u8, _mm512_cvtepu32_epi64(yi(idx)), p, 8),
    );
}

@arch(x86_64)
@simd_impl(simd::Op::Scatter, [cpu::Feature::Avx512f])
fn scatter_f64x8_u32(p: *mut f64, idx: u32x8, m: mask8, v: f64x8) {
    unsafe _mm512_mask_i64scatter_pd(p, (m as u64) as u8, _mm512_cvtepu32_epi64(yi(idx)), zd(v), 8);
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_f64x2_u64(p: *const f64, idx: u64x2, m: mask2, fb: f64x2) f64x2 {
    let b = _mm_set_epi64x(2, 1);
    let s = _mm_cmpeq_epi64(_mm_and_si128(_mm_set1_epi64x((m as u64) as i64), b), b);
    return xdv::<f64, 2>(unsafe _mm_mask_i64gather_pd(xd(fb), p, xi(idx), _mm_castsi128_pd(s), 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx2])
fn gather_f64x4_u64(p: *const f64, idx: u64x4, m: mask4, fb: f64x4) f64x4 {
    let b = _mm256_set_epi64x(8, 4, 2, 1);
    let s = _mm256_cmpeq_epi64(_mm256_and_si256(_mm256_set1_epi64x((m as u64) as i64), b), b);
    return ydv::<f64, 4>(unsafe _mm256_mask_i64gather_pd(yd(fb), p, yi(idx), _mm256_castsi256_pd(s), 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Gather, [cpu::Feature::Avx512f])
fn gather_f64x8_u64(p: *const f64, idx: u64x8, m: mask8, fb: f64x8) f64x8 {
    return zdv::<f64, 8>(unsafe _mm512_mask_i64gather_pd(zd(fb), (m as u64) as u8, zi(idx), p, 8));
}

@arch(x86_64)
@simd_impl(simd::Op::Scatter, [cpu::Feature::Avx512f])
fn scatter_f64x8_u64(p: *mut f64, idx: u64x8, m: mask8, v: f64x8) {
    unsafe _mm512_mask_i64scatter_pd(p, (m as u64) as u8, zi(idx), zd(v), 8);
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Sse2])
fn cmp_eq_lanes_i64x2_sse2(a: i64x2, b: i64x2) u64x2 {
    let c = _mm_cmpeq_epi32(xi(a), xi(b));
    return xiv::<u64, 2>(_mm_and_si128(c, _mm_shuffle_epi32(c, 177)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Sse2])
fn cmp_ne_lanes_i64x2_sse2(a: i64x2, b: i64x2) u64x2 {
    let c = _mm_cmpeq_epi32(xi(a), xi(b));
    return xiv::<u64, 2>(_mm_xor_si128(_mm_and_si128(c, _mm_shuffle_epi32(c, 177)), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Sse2])
fn cmp_lt_lanes_i64x2_sse2(a: i64x2, b: i64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    let d = _mm_sub_epi64(x, y);
    let o = _mm_xor_si128(d, _mm_and_si128(_mm_xor_si128(x, y), _mm_xor_si128(d, x)));
    let m = _mm_shuffle_epi32(_mm_srai_epi32(o, 31), 245);
    return xiv::<u64, 2>(m);
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Sse2])
fn cmp_gt_lanes_i64x2_sse2(a: i64x2, b: i64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    let d = _mm_sub_epi64(y, x);
    let o = _mm_xor_si128(d, _mm_and_si128(_mm_xor_si128(y, x), _mm_xor_si128(d, y)));
    let m = _mm_shuffle_epi32(_mm_srai_epi32(o, 31), 245);
    return xiv::<u64, 2>(m);
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Sse2])
fn cmp_le_lanes_i64x2_sse2(a: i64x2, b: i64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    let d = _mm_sub_epi64(y, x);
    let o = _mm_xor_si128(d, _mm_and_si128(_mm_xor_si128(y, x), _mm_xor_si128(d, y)));
    let m = _mm_shuffle_epi32(_mm_srai_epi32(o, 31), 245);
    return xiv::<u64, 2>(_mm_xor_si128(m, _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Sse2])
fn cmp_ge_lanes_i64x2_sse2(a: i64x2, b: i64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    let d = _mm_sub_epi64(x, y);
    let o = _mm_xor_si128(d, _mm_and_si128(_mm_xor_si128(x, y), _mm_xor_si128(d, x)));
    let m = _mm_shuffle_epi32(_mm_srai_epi32(o, 31), 245);
    return xiv::<u64, 2>(_mm_xor_si128(m, _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Sse2])
fn min_i64x2_sse2(a: i64x2, b: i64x2) i64x2 {
    let x = xi(a);
    let y = xi(b);
    let d = _mm_sub_epi64(x, y);
    let o = _mm_xor_si128(d, _mm_and_si128(_mm_xor_si128(x, y), _mm_xor_si128(d, x)));
    let m = _mm_shuffle_epi32(_mm_srai_epi32(o, 31), 245);
    return xiv::<i64, 2>(_mm_or_si128(_mm_and_si128(m, xi(a)), _mm_andnot_si128(m, xi(b))));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Sse2])
fn max_i64x2_sse2(a: i64x2, b: i64x2) i64x2 {
    let x = xi(a);
    let y = xi(b);
    let d = _mm_sub_epi64(x, y);
    let o = _mm_xor_si128(d, _mm_and_si128(_mm_xor_si128(x, y), _mm_xor_si128(d, x)));
    let m = _mm_shuffle_epi32(_mm_srai_epi32(o, 31), 245);
    return xiv::<i64, 2>(_mm_or_si128(_mm_and_si128(m, xi(b)), _mm_andnot_si128(m, xi(a))));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Sse2])
fn abs_diff_i64x2_sse2(a: i64x2, b: i64x2) u64x2 {
    let x = xi(a);
    let y = xi(b);
    let d = _mm_sub_epi64(x, y);
    let o = _mm_xor_si128(d, _mm_and_si128(_mm_xor_si128(x, y), _mm_xor_si128(d, x)));
    let m = _mm_shuffle_epi32(_mm_srai_epi32(o, 31), 245);
    let p = _mm_sub_epi64(xi(a), xi(b));
    let q = _mm_sub_epi64(xi(b), xi(a));
    return xiv::<u64, 2>(_mm_or_si128(_mm_and_si128(m, q), _mm_andnot_si128(m, p)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Sse2])
fn wrapping_abs_i64x2_sse2(a: i64x2) i64x2 {
    let x = xi(a);
    let s = _mm_shuffle_epi32(_mm_srai_epi32(x, 31), 245);
    return xiv::<i64, 2>(_mm_sub_epi64(_mm_xor_si128(x, s), s));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpEqLanes, [cpu::Feature::Sse2])
fn cmp_eq_lanes_u64x2_sse2(a: u64x2, b: u64x2) u64x2 {
    let c = _mm_cmpeq_epi32(xi(a), xi(b));
    return xiv::<u64, 2>(_mm_and_si128(c, _mm_shuffle_epi32(c, 177)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpNeLanes, [cpu::Feature::Sse2])
fn cmp_ne_lanes_u64x2_sse2(a: u64x2, b: u64x2) u64x2 {
    let c = _mm_cmpeq_epi32(xi(a), xi(b));
    return xiv::<u64, 2>(_mm_xor_si128(_mm_and_si128(c, _mm_shuffle_epi32(c, 177)), _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLtLanes, [cpu::Feature::Sse2])
fn cmp_lt_lanes_u64x2_sse2(a: u64x2, b: u64x2) u64x2 {
    let x = _mm_xor_si128(xi(a), _mm_set1_epi64x(-9223372036854775807 - 1));
    let y = _mm_xor_si128(xi(b), _mm_set1_epi64x(-9223372036854775807 - 1));
    let d = _mm_sub_epi64(x, y);
    let o = _mm_xor_si128(d, _mm_and_si128(_mm_xor_si128(x, y), _mm_xor_si128(d, x)));
    let m = _mm_shuffle_epi32(_mm_srai_epi32(o, 31), 245);
    return xiv::<u64, 2>(m);
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGtLanes, [cpu::Feature::Sse2])
fn cmp_gt_lanes_u64x2_sse2(a: u64x2, b: u64x2) u64x2 {
    let x = _mm_xor_si128(xi(a), _mm_set1_epi64x(-9223372036854775807 - 1));
    let y = _mm_xor_si128(xi(b), _mm_set1_epi64x(-9223372036854775807 - 1));
    let d = _mm_sub_epi64(y, x);
    let o = _mm_xor_si128(d, _mm_and_si128(_mm_xor_si128(y, x), _mm_xor_si128(d, y)));
    let m = _mm_shuffle_epi32(_mm_srai_epi32(o, 31), 245);
    return xiv::<u64, 2>(m);
}

@arch(x86_64)
@simd_impl(simd::Op::CmpLeLanes, [cpu::Feature::Sse2])
fn cmp_le_lanes_u64x2_sse2(a: u64x2, b: u64x2) u64x2 {
    let x = _mm_xor_si128(xi(a), _mm_set1_epi64x(-9223372036854775807 - 1));
    let y = _mm_xor_si128(xi(b), _mm_set1_epi64x(-9223372036854775807 - 1));
    let d = _mm_sub_epi64(y, x);
    let o = _mm_xor_si128(d, _mm_and_si128(_mm_xor_si128(y, x), _mm_xor_si128(d, y)));
    let m = _mm_shuffle_epi32(_mm_srai_epi32(o, 31), 245);
    return xiv::<u64, 2>(_mm_xor_si128(m, _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::CmpGeLanes, [cpu::Feature::Sse2])
fn cmp_ge_lanes_u64x2_sse2(a: u64x2, b: u64x2) u64x2 {
    let x = _mm_xor_si128(xi(a), _mm_set1_epi64x(-9223372036854775807 - 1));
    let y = _mm_xor_si128(xi(b), _mm_set1_epi64x(-9223372036854775807 - 1));
    let d = _mm_sub_epi64(x, y);
    let o = _mm_xor_si128(d, _mm_and_si128(_mm_xor_si128(x, y), _mm_xor_si128(d, x)));
    let m = _mm_shuffle_epi32(_mm_srai_epi32(o, 31), 245);
    return xiv::<u64, 2>(_mm_xor_si128(m, _mm_set1_epi32(-1)));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Sse2])
fn min_u64x2_sse2(a: u64x2, b: u64x2) u64x2 {
    let x = _mm_xor_si128(xi(a), _mm_set1_epi64x(-9223372036854775807 - 1));
    let y = _mm_xor_si128(xi(b), _mm_set1_epi64x(-9223372036854775807 - 1));
    let d = _mm_sub_epi64(x, y);
    let o = _mm_xor_si128(d, _mm_and_si128(_mm_xor_si128(x, y), _mm_xor_si128(d, x)));
    let m = _mm_shuffle_epi32(_mm_srai_epi32(o, 31), 245);
    return xiv::<u64, 2>(_mm_or_si128(_mm_and_si128(m, xi(a)), _mm_andnot_si128(m, xi(b))));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Sse2])
fn max_u64x2_sse2(a: u64x2, b: u64x2) u64x2 {
    let x = _mm_xor_si128(xi(a), _mm_set1_epi64x(-9223372036854775807 - 1));
    let y = _mm_xor_si128(xi(b), _mm_set1_epi64x(-9223372036854775807 - 1));
    let d = _mm_sub_epi64(x, y);
    let o = _mm_xor_si128(d, _mm_and_si128(_mm_xor_si128(x, y), _mm_xor_si128(d, x)));
    let m = _mm_shuffle_epi32(_mm_srai_epi32(o, 31), 245);
    return xiv::<u64, 2>(_mm_or_si128(_mm_and_si128(m, xi(b)), _mm_andnot_si128(m, xi(a))));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Sse2])
fn abs_diff_u64x2_sse2(a: u64x2, b: u64x2) u64x2 {
    let x = _mm_xor_si128(xi(a), _mm_set1_epi64x(-9223372036854775807 - 1));
    let y = _mm_xor_si128(xi(b), _mm_set1_epi64x(-9223372036854775807 - 1));
    let d = _mm_sub_epi64(x, y);
    let o = _mm_xor_si128(d, _mm_and_si128(_mm_xor_si128(x, y), _mm_xor_si128(d, x)));
    let m = _mm_shuffle_epi32(_mm_srai_epi32(o, 31), 245);
    let p = _mm_sub_epi64(xi(a), xi(b));
    let q = _mm_sub_epi64(xi(b), xi(a));
    return xiv::<u64, 2>(_mm_or_si128(_mm_and_si128(m, q), _mm_andnot_si128(m, p)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Sse42])
fn abs_diff_i64x2_sse42(a: i64x2, b: i64x2) u64x2 {
    let m = _mm_cmpgt_epi64(xi(b), xi(a));
    let p = _mm_sub_epi64(xi(a), xi(b));
    let q = _mm_sub_epi64(xi(b), xi(a));
    return xiv::<u64, 2>(_mm_or_si128(_mm_and_si128(m, q), _mm_andnot_si128(m, p)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Sse42])
fn abs_diff_u64x2_sse42(a: u64x2, b: u64x2) u64x2 {
    let m = _mm_cmpgt_epi64(
        _mm_xor_si128(xi(b), _mm_set1_epi64x(-9223372036854775807 - 1)),
        _mm_xor_si128(xi(a), _mm_set1_epi64x(-9223372036854775807 - 1)),
    );
    let p = _mm_sub_epi64(xi(a), xi(b));
    let q = _mm_sub_epi64(xi(b), xi(a));
    return xiv::<u64, 2>(_mm_or_si128(_mm_and_si128(m, q), _mm_andnot_si128(m, p)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Sse42])
fn wrapping_abs_i64x2_sse42(a: i64x2) i64x2 {
    let x = xi(a);
    let s = _mm_cmpgt_epi64(_mm_setzero_si128(), x);
    return xiv::<i64, 2>(_mm_sub_epi64(_mm_xor_si128(x, s), s));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx2])
fn wrapping_shr_i64x2_avx2(a: i64x2, n: i64x2) i64x2 {
    let x = xi(a);
    let s = _mm_cmpgt_epi64(_mm_setzero_si128(), x);
    let c = _mm_and_si128(xi(n), _mm_set1_epi64x(63));
    return xiv::<i64, 2>(_mm_xor_si128(_mm_srlv_epi64(_mm_xor_si128(x, s), c), s));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx2])
fn abs_diff_i64x4_avx2(a: i64x4, b: i64x4) u64x4 {
    let m = _mm256_cmpgt_epi64(yi(b), yi(a));
    let p = _mm256_sub_epi64(yi(a), yi(b));
    let q = _mm256_sub_epi64(yi(b), yi(a));
    return yiv::<u64, 4>(_mm256_or_si256(_mm256_and_si256(m, q), _mm256_andnot_si256(m, p)));
}

@arch(x86_64)
@simd_impl(simd::Op::AbsDiff, [cpu::Feature::Avx2])
fn abs_diff_u64x4_avx2(a: u64x4, b: u64x4) u64x4 {
    let m = _mm256_cmpgt_epi64(
        _mm256_xor_si256(yi(b), _mm256_set1_epi64x(-9223372036854775807 - 1)),
        _mm256_xor_si256(yi(a), _mm256_set1_epi64x(-9223372036854775807 - 1)),
    );
    let p = _mm256_sub_epi64(yi(a), yi(b));
    let q = _mm256_sub_epi64(yi(b), yi(a));
    return yiv::<u64, 4>(_mm256_or_si256(_mm256_and_si256(m, q), _mm256_andnot_si256(m, p)));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingAbs, [cpu::Feature::Avx2])
fn wrapping_abs_i64x4_avx2(a: i64x4) i64x4 {
    let x = yi(a);
    let s = _mm256_cmpgt_epi64(_mm256_setzero_si256(), x);
    return yiv::<i64, 4>(_mm256_sub_epi64(_mm256_xor_si256(x, s), s));
}

@arch(x86_64)
@simd_impl(simd::Op::WrappingShr, [cpu::Feature::Avx2])
fn wrapping_shr_i64x4_avx2(a: i64x4, n: i64x4) i64x4 {
    let x = yi(a);
    let s = _mm256_cmpgt_epi64(_mm256_setzero_si256(), x);
    let c = _mm256_and_si256(yi(n), _mm256_set1_epi64x(63));
    return yiv::<i64, 4>(_mm256_xor_si256(_mm256_srlv_epi64(_mm256_xor_si256(x, s), c), s));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx102])
fn min_num_f32x4(a: f32x4, b: f32x4) f32x4 {
    return xfv::<f32, 4>(unsafe _mm_minmax_ps(xf(a), xf(b), 20));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx102])
fn max_num_f32x4(a: f32x4, b: f32x4) f32x4 {
    return xfv::<f32, 4>(unsafe _mm_minmax_ps(xf(a), xf(b), 21));
}

@arch(x86_64)
@simd_impl(simd::Op::Minimum, [cpu::Feature::Avx102])
fn minimum_f32x4_avx102(a: f32x4, b: f32x4) f32x4 {
    return xfv::<f32, 4>(unsafe _mm_minmax_ps(xf(a), xf(b), 4));
}

@arch(x86_64)
@simd_impl(simd::Op::Maximum, [cpu::Feature::Avx102])
fn maximum_f32x4_avx102(a: f32x4, b: f32x4) f32x4 {
    return xfv::<f32, 4>(unsafe _mm_minmax_ps(xf(a), xf(b), 5));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx102])
fn min_num_f64x2(a: f64x2, b: f64x2) f64x2 {
    return xdv::<f64, 2>(unsafe _mm_minmax_pd(xd(a), xd(b), 20));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx102])
fn max_num_f64x2(a: f64x2, b: f64x2) f64x2 {
    return xdv::<f64, 2>(unsafe _mm_minmax_pd(xd(a), xd(b), 21));
}

@arch(x86_64)
@simd_impl(simd::Op::Minimum, [cpu::Feature::Avx102])
fn minimum_f64x2_avx102(a: f64x2, b: f64x2) f64x2 {
    return xdv::<f64, 2>(unsafe _mm_minmax_pd(xd(a), xd(b), 4));
}

@arch(x86_64)
@simd_impl(simd::Op::Maximum, [cpu::Feature::Avx102])
fn maximum_f64x2_avx102(a: f64x2, b: f64x2) f64x2 {
    return xdv::<f64, 2>(unsafe _mm_minmax_pd(xd(a), xd(b), 5));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx102])
fn min_num_f32x8(a: f32x8, b: f32x8) f32x8 {
    return yfv::<f32, 8>(unsafe _mm256_minmax_ps(yf(a), yf(b), 20));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx102])
fn max_num_f32x8(a: f32x8, b: f32x8) f32x8 {
    return yfv::<f32, 8>(unsafe _mm256_minmax_ps(yf(a), yf(b), 21));
}

@arch(x86_64)
@simd_impl(simd::Op::Minimum, [cpu::Feature::Avx102])
fn minimum_f32x8_avx102(a: f32x8, b: f32x8) f32x8 {
    return yfv::<f32, 8>(unsafe _mm256_minmax_ps(yf(a), yf(b), 4));
}

@arch(x86_64)
@simd_impl(simd::Op::Maximum, [cpu::Feature::Avx102])
fn maximum_f32x8_avx102(a: f32x8, b: f32x8) f32x8 {
    return yfv::<f32, 8>(unsafe _mm256_minmax_ps(yf(a), yf(b), 5));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx102])
fn min_num_f64x4(a: f64x4, b: f64x4) f64x4 {
    return ydv::<f64, 4>(unsafe _mm256_minmax_pd(yd(a), yd(b), 20));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx102])
fn max_num_f64x4(a: f64x4, b: f64x4) f64x4 {
    return ydv::<f64, 4>(unsafe _mm256_minmax_pd(yd(a), yd(b), 21));
}

@arch(x86_64)
@simd_impl(simd::Op::Minimum, [cpu::Feature::Avx102])
fn minimum_f64x4_avx102(a: f64x4, b: f64x4) f64x4 {
    return ydv::<f64, 4>(unsafe _mm256_minmax_pd(yd(a), yd(b), 4));
}

@arch(x86_64)
@simd_impl(simd::Op::Maximum, [cpu::Feature::Avx102])
fn maximum_f64x4_avx102(a: f64x4, b: f64x4) f64x4 {
    return ydv::<f64, 4>(unsafe _mm256_minmax_pd(yd(a), yd(b), 5));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx102])
fn min_num_f32x16(a: f32x16, b: f32x16) f32x16 {
    return zfv::<f32, 16>(unsafe _mm512_minmax_ps(zf(a), zf(b), 20));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx102])
fn max_num_f32x16(a: f32x16, b: f32x16) f32x16 {
    return zfv::<f32, 16>(unsafe _mm512_minmax_ps(zf(a), zf(b), 21));
}

@arch(x86_64)
@simd_impl(simd::Op::Minimum, [cpu::Feature::Avx102])
fn minimum_f32x16_avx102(a: f32x16, b: f32x16) f32x16 {
    return zfv::<f32, 16>(unsafe _mm512_minmax_ps(zf(a), zf(b), 4));
}

@arch(x86_64)
@simd_impl(simd::Op::Maximum, [cpu::Feature::Avx102])
fn maximum_f32x16_avx102(a: f32x16, b: f32x16) f32x16 {
    return zfv::<f32, 16>(unsafe _mm512_minmax_ps(zf(a), zf(b), 5));
}

@arch(x86_64)
@simd_impl(simd::Op::Min, [cpu::Feature::Avx102])
fn min_num_f64x8(a: f64x8, b: f64x8) f64x8 {
    return zdv::<f64, 8>(unsafe _mm512_minmax_pd(zd(a), zd(b), 20));
}

@arch(x86_64)
@simd_impl(simd::Op::Max, [cpu::Feature::Avx102])
fn max_num_f64x8(a: f64x8, b: f64x8) f64x8 {
    return zdv::<f64, 8>(unsafe _mm512_minmax_pd(zd(a), zd(b), 21));
}

@arch(x86_64)
@simd_impl(simd::Op::Minimum, [cpu::Feature::Avx102])
fn minimum_f64x8_avx102(a: f64x8, b: f64x8) f64x8 {
    return zdv::<f64, 8>(unsafe _mm512_minmax_pd(zd(a), zd(b), 4));
}

@arch(x86_64)
@simd_impl(simd::Op::Maximum, [cpu::Feature::Avx102])
fn maximum_f64x8_avx102(a: f64x8, b: f64x8) f64x8 {
    return zdv::<f64, 8>(unsafe _mm512_minmax_pd(zd(a), zd(b), 5));
}
