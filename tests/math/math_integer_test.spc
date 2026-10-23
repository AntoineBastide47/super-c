// std::math::integer: bit fields, bit counts, extended arithmetic, powers of two, multiples, integer
// `log2`, bit interleaving, masks and rotations on scalars and vectors, then the edge cases: 8- and
// 16-bit operands computed in a wider type, the `i32`-built masks, signed inputs, carry and borrow
// extremes, `round_multiple` as a floor, the panic of `ceil_multiple` and constant initializers.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::integer as *;

// Bit fields, bit counts and extended arithmetic.

@test
fn bitfield_insert_table() {
    let base: [u32; 6] = [0x00000000, 0x00000000, 0x00000000, 0xff000000, 0xffff0000, 0x0000ffff];
    let insert: [u32; 6] = [0xffffffff, 0xffffffff, 0xffffffff, 0x000000ff, 0xffff0000, 0x0000ffff];
    let offset: [i32; 6] = [0, 0, 0, 8, 16, 16];
    let bits: [i32; 6] = [32, 31, 0, 8, 16, 16];
    let ret: [u32; 6] = [0xffffffff, 0x7fffffff, 0x00000000, 0xff00ff00, 0x00000000, 0xffffffff];
    for i in 0..6 {
        unsafe {
            assert_eq(bitfield_insert(base[i], insert[i], offset[i], bits[i]), ret[i]);
        }
    }
}

@test
fn bitfield_extract_table() {
    let value: [u32; 17] = [
        0xffffffff,
        0xffffffff,
        0x00000000,
        0x0f0f0f0f,
        0x00000000,
        0x80000000,
        0x7fffffff,
        0x00000300,
        0x0000ff00,
        0xfffffff0,
        0x000000ff,
        0x000000ff,
        0x00000000,
        0xffffffff,
        0xffff0000,
        0xfffffff0,
        0xffffffff,
    ];
    let offset: [i32; 17] = [0, 8, 0, 0, 8, 31, 31, 8, 8, 0, 1, 0, 0, 0, 16, 0, 16];
    let bits: [i32; 17] = [32, 0, 32, 32, 0, 1, 1, 8, 8, 5, 3, 3, 2, 8, 16, 8, 16];
    let ret: [u32; 17] = [
        0xffffffff,
        0x00000000,
        0x00000000,
        0x0f0f0f0f,
        0x00000000,
        0x00000001,
        0x00000000,
        0x00000003,
        0x000000ff,
        0x00000010,
        0x00000007,
        0x00000007,
        0x00000000,
        0x000000ff,
        0x0000ffff,
        0x00000000,
        0x00000000,
    ];
    for i in 0..17 {
        unsafe {
            let r = bitfield_extract(value[i], offset[i], bits[i]);
            // The last two rows list a wrong result: the function must not return it.
            if i < 15 {
                assert_eq(r, ret[i]);
            } else {
                assert_ne(r, ret[i]);
            }
        }
    }
}

@test
fn bitfield_reverse_table() {
    let v32: [u32; 7] = [0x00000001, 0x0000000f, 0x000000ff, 0xf0000000, 0xff000000, 0xffffffff, 0x00000000];
    let r32: [u32; 7] = [0x80000000, 0xf0000000, 0xff000000, 0x0000000f, 0x000000ff, 0xffffffff, 0x00000000];
    for i in 0..7 {
        unsafe {
            assert_eq(bitfield_reverse(v32[i]), r32[i]);
        }
    }
    let v64: [u64; 5] = [0x00000000000000ff, 0x000000000000000f, 0xf000000000000000, 0xffffffffffffffff, 0];
    let r64: [u64; 5] = [0xff00000000000000, 0xf000000000000000, 0x000000000000000f, 0xffffffffffffffff, 0];
    for i in 0..5 {
        unsafe {
            assert_eq(bitfield_reverse(v64[i]), r64[i]);
        }
    }
}

// The `find_msb` inputs: 0, 1, 2, 3, 4, 5, 7, then 8 .. 2^30.
const MSB_HEAD: [u32; 7] = [0, 1, 2, 3, 4, 5, 7];
const MSB_HEAD_R: [i32; 7] = [-1, 0, 1, 1, 2, 2, 2];

@test
fn find_msb_ivec4() {
    for i in 0..7 {
        unsafe {
            assert(find_msb(ivec4::splat(MSB_HEAD[i] as i32)) == ivec4::splat(MSB_HEAD_R[i]));
        }
    }
    for k in 3..31 {
        assert(find_msb(ivec4::splat(1 << k)) == ivec4::splat(k));
    }
}

@test
fn find_msb_int() {
    for i in 0..7 {
        unsafe {
            assert_eq(find_msb(MSB_HEAD[i]), MSB_HEAD_R[i]);
        }
    }
    for k in 3..31 {
        assert_eq(find_msb(1u32 << k as u32), k);
    }
}

@test
fn find_lsb_int() {
    let v: [i32; 8] = [0x00000001, 0x00000003, 0x00000002, 0x00010000, 0x7FFF0000, 0x7F000000, 0x7F00FF00, 0];
    let r: [i32; 8] = [0, 0, 1, 16, 16, 24, 8, -1];
    for i in 0..8 {
        unsafe {
            assert_eq(find_lsb(v[i]), r[i]);
        }
    }
}

@test
fn uadd_carry_overflow() {
    let (r0, c0) = uadd_carry(u32::MAX, 0u32);
    assert_eq(c0, 0);
    assert_eq(r0, u32::MAX);
    let (r1, c1) = uadd_carry(u32::MAX, 1u32);
    assert_eq(c1, 1);
    assert_eq(r1, 0);
    let (r2, c2) = uadd_carry(uvec1::new(u32::MAX), uvec1::new(0));
    assert(c2 == uvec1::new(0));
    assert(r2 == uvec1::new(u32::MAX));
    let (r3, c3) = uadd_carry(uvec1::new(u32::MAX), uvec1::new(1));
    assert(c3 == uvec1::new(1));
    assert(r3 == uvec1::new(0));
}

fn borrow_vec<const N: usize>() {
    let x = Vec::<u32, N>::splat(16);
    let y = Vec::<u32, N>::splat(17);
    let (r, b) = usub_borrow(x, y);
    assert(b == Vec::<u32, N>::splat(1));
    assert(r == x - y);
}

@test
fn usub_borrow_underflow() {
    let (r, b) = usub_borrow(16u32, 17u32);
    assert_eq(b, 1);
    assert_eq(r, 16u32.wrapping_sub(17));
    borrow_vec::<1>();
    borrow_vec::<2>();
    borrow_vec::<3>();
    borrow_vec::<4>();
}

fn umul_vec<const N: usize>() {
    let (msb, lsb) = umul_extended(Vec::<u32, N>::splat(2), Vec::<u32, N>::splat(3));
    assert(msb == Vec::<u32, N>::splat(0));
    assert(lsb == Vec::<u32, N>::splat(6));
}

fn imul_vec<const N: usize>() {
    let (msb, lsb) = imul_extended(Vec::<i32, N>::splat(2), Vec::<i32, N>::splat(3));
    assert(msb == Vec::<i32, N>::splat(0));
    assert(lsb == Vec::<i32, N>::splat(6));
}

@test
fn umul_extended_small_product() {
    let (msb, lsb) = umul_extended(2u32, 3u32);
    assert_eq(msb, 0);
    assert_eq(lsb, 6);
    umul_vec::<1>();
    umul_vec::<2>();
    umul_vec::<3>();
    umul_vec::<4>();
}

@test
fn imul_extended_small_product() {
    let (msb, lsb) = imul_extended(2, 3);
    assert_eq(msb, 0);
    assert_eq(lsb, 6);
    imul_vec::<1>();
    imul_vec::<2>();
    imul_vec::<3>();
    imul_vec::<4>();
}

@test
fn bit_count_table() {
    let v: [i32; 5] = [0x00000001, 0x00000003, 0x00000002, 0x7fffffff, 0x00000000];
    let r: [i32; 5] = [1, 2, 1, 31, 0];
    for i in 0..5 {
        unsafe {
            assert_eq(bit_count(v[i]), r[i]);
        }
    }
}

// Powers of two, multiples and `find_nsb` on scalars.

@test
fn is_power_of_two_scalar() {
    let i16v: [i16; 6] = [0x0001, 0x0002, 0x0004, 0x0080, 0x0000, 0x0003];
    let u16v: [u16; 6] = [0x0001, 0x0002, 0x0004, 0x0000, 0x0000, 0x0003];
    let i32v: [i32; 6] = [0x00000001, 0x00000002, 0x00000004, 0x0000000f, 0x00000000, 0x00000003];
    let u32v: [u32; 6] = [0x00000001, 0x00000002, 0x00000004, 0x80000000, 0x00000000, 0x00000003];
    let r16: [bool; 6] = [true, true, true, true, true, false];
    let r32: [bool; 6] = [true, true, true, false, true, false];
    let ru32: [bool; 6] = [true, true, true, true, true, false];
    for i in 0..6 {
        unsafe {
            assert_eq(is_power_of_two(i16v[i]), r16[i]);
            assert_eq(is_power_of_two(u16v[i]), r16[i]);
            assert_eq(is_power_of_two(i32v[i]), r32[i]);
            assert_eq(is_power_of_two(u32v[i]), ru32[i]);
        }
    }
}

@test
fn next_power_of_two_advanced() {
    let iv: [i32; 12] = [0x0000ffff, -3, -8, 1, 2, 4, 7, 0x0000fff0, 0x0000f000, 0x08000000, 0, 3];
    let ir: [i32; 12] = [0x00010000, -4, -8, 1, 2, 4, 8, 0x00010000, 0x00010000, 0x08000000, 0, 4];
    for i in 0..12 {
        unsafe {
            assert_eq(next_power_of_two(iv[i]), ir[i]);
            assert_eq(ceil_power_of_two(iv[i]), ir[i]);
        }
    }
    let uv: [u32; 10] = [1, 2, 4, 7, 0x0000ffff, 0x0000fff0, 0x0000f000, 0x80000000, 0, 3];
    let ur: [u32; 10] = [1, 2, 4, 8, 0x00010000, 0x00010000, 0x00010000, 0x80000000, 0, 4];
    for i in 0..10 {
        unsafe {
            assert_eq(next_power_of_two(uv[i]), ur[i]);
            assert_eq(ceil_power_of_two(uv[i]), ur[i]);
        }
    }
}

// The turbofish names `T` and `G`: the compiler does not yet solve `T` from `G: Gen<T>` when `G` is a
// type parameter.
fn powers_scalar<T: Int>() {
    let t = |v: i64| T::from_i64(v);
    let prev: [T; 4] = [
        prev_power_of_two::<T, T>(t(7)),
        prev_power_of_two::<T, T>(t(15)),
        prev_power_of_two::<T, T>(t(31)),
        prev_power_of_two::<T, T>(t(32)),
    ];
    let next: [T; 4] = [
        next_power_of_two::<T, T>(t(7)),
        next_power_of_two::<T, T>(t(15)),
        next_power_of_two::<T, T>(t(31)),
        next_power_of_two::<T, T>(t(32)),
    ];
    let prev_r: [i64; 4] = [4, 8, 16, 32];
    let next_r: [i64; 4] = [8, 16, 32, 32];
    for i in 0..4 {
        unsafe {
            assert(prev[i].equal(t(prev_r[i])));
            assert(next[i].equal(t(next_r[i])));
        }
    }
}

fn multiples_scalar<T: Int>() {
    let t = |v: i64| T::from_i64(v);
    let a: T = prev_multiple::<T, T>(t(8), t(3));
    assert(a.equal(t(6)));
    let b: T = prev_multiple::<T, T>(t(7), t(7));
    assert(b.equal(t(7)));
    let src: [i64; 6] = [3, 6, 5, 7, 0, 8];
    let mul: [i64; 6] = [4, 3, 3, 7, 1, 3];
    let ret: [i64; 6] = [4, 6, 6, 7, 0, 9];
    for i in 0..6 {
        unsafe {
            let r: T = next_multiple::<T, T>(t(src[i]), t(mul[i]));
            assert(r.equal(t(ret[i])));
        }
    }
}

// The `find_nsb` rows: (source, significant bit count, result).
const NSB_SRC: [i64; 10] = [0x00, 0x01, 0x02, 0x06, 0x01, 0x03, 0x03, 0x07, 0x05, 0x0D];
const NSB_COUNT: [i32; 10] = [1, 2, 2, 3, 1, 1, 2, 2, 2, 2];
const NSB_RET: [i32; 10] = [-1, -1, -1, -1, 0, 0, 1, 1, 2, 2];

fn nsb_scalar<T: Int>() {
    for i in 0..10 {
        unsafe {
            let r = find_nsb::<T, T, i32>(T::from_i64(NSB_SRC[i]), NSB_COUNT[i]);
            assert_eq(r, NSB_RET[i]);
        }
    }
}

@test
fn powers_of_two_all_types() {
    powers_scalar::<i8>();
    powers_scalar::<i16>();
    powers_scalar::<i32>();
    powers_scalar::<i64>();
    powers_scalar::<u8>();
    powers_scalar::<u16>();
    powers_scalar::<u32>();
    powers_scalar::<u64>();
}

@test
fn multiples_all_types() {
    multiples_scalar::<i8>();
    multiples_scalar::<i16>();
    multiples_scalar::<i32>();
    multiples_scalar::<i64>();
    multiples_scalar::<u8>();
    multiples_scalar::<u16>();
    multiples_scalar::<u32>();
    multiples_scalar::<u64>();
}

@test
fn find_nsb_all_types() {
    nsb_scalar::<u8>();
    nsb_scalar::<u16>();
    nsb_scalar::<u32>();
    nsb_scalar::<u64>();
    nsb_scalar::<i8>();
    nsb_scalar::<i16>();
    nsb_scalar::<i32>();
    nsb_scalar::<i64>();
}

// Powers of two, multiples and `find_nsb` on vectors.

fn pow2_vec<T: Int, const N: usize>(v: i64, expected: bool) {
    assert(is_power_of_two(Vec::<T, N>::splat(T::from_i64(v))) == Vec::<bool, N>::splat(expected));
}

fn pow2_table_vec<const N: usize>() {
    let s16: [i64; 6] = [0x0001, 0x0002, 0x0004, 0x0080, 0x0000, 0x0003];
    let u16s: [i64; 6] = [0x0001, 0x0002, 0x0004, 0x0000, 0x0000, 0x0003];
    let s32: [i64; 6] = [0x00000001, 0x00000002, 0x00000004, 0x0000000f, 0x00000000, 0x00000003];
    let u32s: [i64; 6] = [0x00000001, 0x00000002, 0x00000004, 0x80000000, 0x00000000, 0x00000003];
    let r16: [bool; 6] = [true, true, true, true, true, false];
    let r32: [bool; 6] = [true, true, true, false, true, false];
    for i in 0..6 {
        unsafe {
            pow2_vec::<i16, N>(s16[i], r16[i]);
            pow2_vec::<u16, N>(u16s[i], r16[i]);
            pow2_vec::<i32, N>(s32[i], r32[i]);
            pow2_vec::<u32, N>(u32s[i], r16[i]);
        }
    }
}

@test
fn is_power_of_two_vector() {
    pow2_table_vec::<1>();
    pow2_table_vec::<2>();
    pow2_table_vec::<3>();
    pow2_table_vec::<4>();
}

fn powers_vec<T: Int, const N: usize>() {
    let t = |v: i64| Vec::<T, N>::splat(T::from_i64(v));
    assert(prev_power_of_two(t(7)) == t(4));
    assert(prev_power_of_two(t(15)) == t(8));
    assert(prev_power_of_two(t(31)) == t(16));
    assert(prev_power_of_two(t(32)) == t(32));
    assert(next_power_of_two(t(7)) == t(8));
    assert(next_power_of_two(t(15)) == t(16));
    assert(next_power_of_two(t(31)) == t(32));
    assert(next_power_of_two(t(32)) == t(32));
}

fn multiples_vec<T: Int, const N: usize>() {
    let t = |v: i64| Vec::<T, N>::splat(T::from_i64(v));
    assert(prev_multiple(t(8), T::from_i64(3)) == t(6));
    assert(prev_multiple(t(8), t(3)) == t(6));
    assert(prev_multiple(t(7), T::from_i64(7)) == t(7));
    assert(prev_multiple(t(7), t(7)) == t(7));
    let src: [i64; 6] = [3, 6, 5, 7, 0, 8];
    let mul: [i64; 6] = [4, 3, 3, 7, 1, 3];
    let ret: [i64; 6] = [4, 6, 6, 7, 0, 9];
    for i in 0..6 {
        unsafe {
            assert(next_multiple(t(src[i]), t(mul[i])) == t(ret[i]));
            assert(next_multiple(t(src[i]), T::from_i64(mul[i])) == t(ret[i]));
        }
    }
}

fn nsb_vec<T: Int, const N: usize>() {
    for i in 0..10 {
        unsafe {
            let r = find_nsb(Vec::<T, N>::splat(T::from_i64(NSB_SRC[i])), Vec::<i32, N>::splat(NSB_COUNT[i]));
            assert(r == Vec::<i32, N>::splat(NSB_RET[i]));
        }
    }
}

fn vec_checks<T: Int, const N: usize>() {
    powers_vec::<T, N>();
    multiples_vec::<T, N>();
    nsb_vec::<T, N>();
}

fn vec_checks_all<const N: usize>() {
    vec_checks::<i8, N>();
    vec_checks::<i16, N>();
    vec_checks::<i32, N>();
    vec_checks::<i64, N>();
    vec_checks::<u8, N>();
    vec_checks::<u16, N>();
    vec_checks::<u32, N>();
    vec_checks::<u64, N>();
}

@test
fn vector_powers_multiples_nsb() {
    vec_checks_all::<1>();
    vec_checks_all::<2>();
    vec_checks_all::<3>();
    vec_checks_all::<4>();
}

// Integer base-2 logarithm.

@test
fn log2_int_of_16() {
    let a0 = 16.0f32.log2() as i32;
    assert_eq(log2_int(16), a0);
    assert(log2_int(ivec1::splat(16)) == ivec1::splat(a0));
    assert(log2_int(ivec2::splat(16)) == ivec2::splat(a0));
    assert(log2_int(ivec3::splat(16)) == ivec3::splat(a0));
    assert(log2_int(ivec4::splat(16)) == ivec4::splat(a0));
    assert_eq(log2_int(16u64), 4u64);
    assert(log2_int(u64vec1::splat(16)) == u64vec1::splat(4));
    assert(log2_int(u64vec2::splat(16)) == u64vec2::splat(4));
    assert(log2_int(u64vec3::splat(16)) == u64vec3::splat(4));
    assert(log2_int(u64vec4::splat(16)) == u64vec4::splat(4));
}

// Rounding to powers of two and to multiples.

@test
fn is_power_of_two_round() {
    let v: [i32; 6] = [0x00000001, 0x00000002, 0x00000004, 0x0000000f, 0x00000000, 0x00000003];
    let r: [bool; 6] = [true, true, true, false, true, false];
    for i in 0..6 {
        unsafe {
            assert_eq(is_power_of_two(v[i]), r[i]);
            assert(is_power_of_two(ivec1::splat(v[i])) == bvec1::splat(r[i]));
            assert(is_power_of_two(ivec2::splat(v[i])) == bvec2::splat(r[i]));
            assert(is_power_of_two(ivec3::splat(v[i])) == bvec3::splat(r[i]));
            assert(is_power_of_two(ivec4::splat(v[i])) == bvec4::splat(r[i]));
        }
    }
}

@test
fn round_floor_ceil_power_of_two() {
    assert_eq(round_power_of_two(7u32), 8);
    assert_eq(round_power_of_two(15u32), 16);
    assert_eq(round_power_of_two(31u32), 32);
    assert_eq(round_power_of_two(9u32), 8);
    assert_eq(round_power_of_two(17u32), 16);
    assert_eq(round_power_of_two(33u32), 32);
    assert_eq(floor_power_of_two(7u32), 4);
    assert_eq(floor_power_of_two(15u32), 8);
    assert_eq(floor_power_of_two(31u32), 16);
    assert_eq(ceil_power_of_two(7u32), 8);
    assert_eq(ceil_power_of_two(15u32), 16);
    assert_eq(ceil_power_of_two(31u32), 32);
}

@test
fn floor_ceil_multiple_float() {
    assert((floor_multiple(3.4f64, 0.3) - 3.3).abs() <= 0.0001);
    assert((floor_multiple(-1.4f64, 0.3) - -1.5).abs() <= 0.0001);
    assert((ceil_multiple(3.4f64, 0.3) - 3.6).abs() <= 0.0001);
    assert((ceil_multiple(-1.4f64, 0.3) - -1.2).abs() <= 0.0001);
}

@test
fn ceil_multiple_int() {
    let s: [i32; 9] = [3, 7, 5, 1, 1, 4, 4, 1, 7];
    let m: [i32; 9] = [4, 4, 4, 4, 3, 3, 1, 1, 1];
    let r: [i32; 9] = [4, 8, 8, 4, 3, 6, 4, 1, 7];
    for i in 0..9 {
        unsafe {
            assert_eq(ceil_multiple(s[i], m[i]), r[i]);
        }
    }
}

// Bit interleaving, masks and rotations.

@test
fn bitfield_interleave_all_widths() {
    for y in 0u8..15u8 {
        for x in 0u8..15u8 {
            let a = bitfield_interleave_u8vec2(u8vec2::new(x, y)) as u64;
            let b = bitfield_interleave_u16vec2(u16vec2::new(x, y)) as u64;
            let c = bitfield_interleave_u32vec2(u32vec2::new(x, y));
            assert_eq(a, b);
            assert_eq(a, c);
            let d = bitfield_deinterleave_u64(c);
            assert_eq(d.x(), x as u32);
            assert_eq(d.y(), y as u32);
        }
    }
    for y in 0..15 {
        for x in 0..15 {
            let a = bitfield_interleave_i8x2(x as i8, y as i8) as i64;
            let b = bitfield_interleave_i16x2(x as i16, y as i16) as i64;
            let c = bitfield_interleave_i32x2(x, y);
            assert_eq(a, b);
            assert_eq(a, c);
        }
    }
}

// The reference interleave: bit i of the k-th input goes to bit i * count + k.
const fn interleave_ref(v: []u64, bits: u64) u64 {
    let mut r: u64 = 0;
    let n = v.len() as u64;
    for i in 0..bits {
        for k in 0..n {
            r = r | (v[k as usize] >> i & 1) << i * n + k;
        }
    }
    return r;
}

@test
fn bitfield_interleave_reference() {
    for z in [0u16, 27] {
        for y in [0u16, 27] {
            for x in [0u16, 27] {
                assert_eq(bitfield_interleave_u16x3(x, y, z), interleave_ref([x as u64, y as u64, z as u64], 16));
                for w in [0u16, 27] {
                    assert_eq(
                        bitfield_interleave_u16x4(x, y, z, w),
                        interleave_ref([x as u64, y as u64, z as u64, w as u64], 16),
                    );
                }
            }
        }
    }
    for j in 0..4u64 {
        for i in 0..4u64 {
            let a = bitfield_interleave_u8x2(i as u8, j as u8);
            assert_eq(a as u64, interleave_ref([i, j], 8));
            let c = bitfield_deinterleave_u16(a);
            assert_eq(c.x() as u64, i);
            assert_eq(c.y() as u64, j);
        }
    }
}

@test
fn mask_table() {
    let v: [i32; 5] = [0, 1, 2, 3, 31];
    let r: [i32; 5] = [0x00000000, 0x00000001, 0x00000003, 0x00000007, 0x7fffffff];
    for i in 0..5 {
        unsafe {
            assert_eq(mask(v[i]), r[i]);
            if i < 4 {
                assert(mask(ivec4::splat(v[i])) == ivec4::splat(r[i]));
            }
        }
    }
}

@test
fn bitfield_rotate_differs_from_shift() {
    // `bitfield_rotate_right` moves the bits left and `bitfield_rotate_left` moves them right.
    let a = bitfield_rotate_right(ivec4::splat(2), 1);
    assert(a != ivec4::splat(2) >> 1);
    assert(a == ivec4::splat(4));
    let b = bitfield_rotate_left(ivec4::splat(2), 1);
    assert(b != ivec4::splat(2) << 1);
    assert(b == ivec4::splat(1));
}

// Edge cases.

@test
fn int_promotion_of_small_types() {
    // The scalar form computes `abs(v) & (abs(v) - 1)` in i64, the vector form in the component type.
    assert(!is_power_of_two(i8::MIN));
    assert(is_power_of_two(i8vec1::new(i8::MIN)) == bvec1::new(true));
    assert(!is_power_of_two(i16::MIN));
    assert(is_power_of_two(i16vec2::splat(i16::MIN)) == bvec2::splat(true));
    // `round_power_of_two` compares `next - v` and `v - prev` in i64: `next` wraps to 0 for 129.
    assert_eq(round_power_of_two(129u8), 0);
    assert_eq(round_power_of_two(200u8), 0);
    assert_eq(round_power_of_two(129u32), 128);
    // `next_multiple` negates the source in i64: -(-128) is 128, not -128.
    assert_eq(next_multiple(i16::MIN, 3i16), -32766);
    assert_eq(next_multiple(i8::MIN, 3i8), -126);
    assert(next_multiple(i8vec2::new(-128, 9), 3i8) == i8vec2::new(-126, 9));
}

@test
fn int_built_masks() {
    // The extract and fill masks are built in `i32`: 64-bit values keep every bit above the offset,
    // and fills sign-extend.
    assert_eq(bitfield_extract(0xFFFFFFFFFFFFFFFFu64, 4, 40), 0x0FFFFFFFFFFFFFFF);
    assert_eq(bitfield_extract(0xFFFFFFFFFFFFFFFFu64, 4, 20), 0xFFFFF);
    assert_eq(bitfield_fill_one(0u64, 28, 5), 0xFFFFFFFFF0000000);
    assert_eq(bitfield_fill_zero(0xFFFFFFFFFFFFFFFFu64, 28, 5), 0x0FFFFFFF);
    assert_eq(bitfield_fill_one(0u8, 2, 3), 0x1C);
    assert_eq(bitfield_fill_zero(0xFFu8, 2, 3), 0xE3);
    assert_eq(mask(8u8), 0xFF);
    assert_eq(mask(63i64), i64::MAX);
    assert_eq(bitfield_insert(0i32, -1, 0, 31), i32::MAX);
}

@test
fn signed_bit_functions() {
    assert_eq(find_msb(-1), 31);
    assert_eq(find_msb(-128i8), 7);
    assert_eq(find_lsb(-8i16), 3);
    assert_eq(find_lsb(i32::MIN), 31);
    assert_eq(bit_count(-1i64), 64);
    assert(bit_count(i8vec3::new(-1, 0, 5)) == ivec3::new(8, 0, 2));
    assert_eq(log2_int(0u8), 255);
    assert_eq(log2_int(0i32), -1);
    assert_eq(bitfield_rotate_right(0x81u8, 1), 0x03);
    assert_eq(bitfield_rotate_left(0x81u8, 1), 0xC0);
    assert_eq(bitfield_reverse(1i32), i32::MIN);
    assert_eq(find_nsb(-1, 1), 0);
}

@test
fn carry_borrow_extremes() {
    let (r, c) = uadd_carry(uvec3::new(u32::MAX, 1, 0x80000000), uvec3::new(u32::MAX, 2, 0x80000000));
    assert(r == uvec3::new(u32::MAX - 1, 3, 0));
    assert(c == uvec3::new(1, 0, 1));
    let (um, ul) = umul_extended(u32::MAX, u32::MAX);
    assert_eq(um, 0xFFFFFFFE);
    assert_eq(ul, 1);
    let (im, il) = imul_extended(i32::MIN, -1);
    assert_eq(im, 0);
    assert_eq(il, i32::MIN);
    let (vm, vl) = imul_extended(ivec2::new(-2, i32::MAX), ivec2::new(3, i32::MAX));
    assert(vm == ivec2::new(-1, 0x3FFFFFFF));
    assert(vl == ivec2::new(-6, 1));
}

@test
fn round_multiple_is_a_floor() {
    assert_eq(round_multiple(7, 4), 4);
    assert_eq(round_multiple(-7, 4), -8);
    assert_eq(floor_multiple(-7, 4), -8);
    assert_eq(round_multiple(-6.5f32, 2.0), -6.0);
    assert_eq(floor_multiple(-6.5f32, 2.0), -8.0);
    assert(round_multiple(dvec2::new(5.5, -0.5), dvec2::splat(2.0)) == dvec2::new(4.0, -2.0));
}

@test(should_panic)
fn ceil_multiple_signed_needs_positive_multiple() {
    assert_eq(ceil_multiple(5, -1), 0);
}

const C_BIT_COUNT: i32 = bit_count(0xF0F0u32);
const C_MSB: ivec3 = find_msb(ivec3::new(1, 255, 0));
const C_REVERSE: u32 = bitfield_reverse(1u32);
const C_NEXT_POT: i32 = next_power_of_two(17);
const C_IS_POT: bvec2 = is_power_of_two(u8vec2::new(64, 65));
const C_INTERLEAVE: u16 = bitfield_interleave_u8x2(0xFF, 0);
const C_MASK: i32 = mask(5);
const C_CEIL_MUL: f64 = ceil_multiple(3.25f64, 0.5);

@test
fn constant_initializers() {
    assert_eq(C_BIT_COUNT, 8);
    assert(C_MSB == ivec3::new(0, 7, -1));
    assert_eq(C_REVERSE, 0x80000000);
    assert_eq(C_NEXT_POT, 32);
    assert(C_IS_POT == bvec2::new(true, false));
    assert_eq(C_INTERLEAVE, 0x5555);
    assert_eq(C_MASK, 31);
    assert_eq(C_CEIL_MUL, 3.5);
}
