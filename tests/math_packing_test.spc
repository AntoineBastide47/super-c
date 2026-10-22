// std::math::packing and the pointer functions: round trips of every packing format, `value_ptr` and
// the `make_*` constructors on vectors, matrices and quaternions, then exact packed bits, float16
// rounding (halves up), the -1 unpacked for a packed NaN or infinity, and constant initializers.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::quat as *;
import std::math::packing as *;

// Every component of `a` within `eps` of `b`.
const fn near<const N: usize>(a: Vec<f32, N>, b: Vec<f32, N>, eps: f32) bool {
    for i in 0..N {
        if !((a[i] - b[i]).abs() <= eps) {
            return false;
        }
    }
    return true;
}

const fn near1(a: f32, b: f32, eps: f32) bool {
    return (a - b).abs() <= eps;
}

// The 2x16, 4x8 and 2x32 formats.

@test
fn unorm2x16_roundtrip() {
    let a: [vec2; 3] = [vec2::new(1.0, 0.0), vec2::new(0.5, 0.7), vec2::new(0.1, 0.2)];
    for b in a {
        assert(near(b, unpack_unorm2x16(pack_unorm2x16(b)), 1.0 / 65535.0));
    }
}

@test
fn snorm2x16_roundtrip() {
    let a: [vec2; 3] = [vec2::new(1.0, 0.0), vec2::new(-0.5, -0.7), vec2::new(-0.1, 0.1)];
    for b in a {
        assert(near(b, unpack_snorm2x16(pack_snorm2x16(b)), 1.0 / 32767.0 * 2.0));
    }
}

@test
fn unorm4x8_roundtrip() {
    let packed = pack_unorm4x8(vec4::new(1.0, 0.5, 0.0, 1.0));
    assert_eq(packed, pack_uint4x8(u8vec4::new(255, 128, 0, 255)));
    let a: [vec4; 2] = [vec4::new(1.0, 0.7, 0.3, 0.0), vec4::new(0.5, 0.1, 0.2, 0.3)];
    for b in a {
        assert(near(b, unpack_unorm4x8(pack_unorm4x8(b)), 1.0 / 255.0));
    }
}

@test
fn snorm4x8_roundtrip() {
    let a: [vec4; 2] = [vec4::new(1.0, 0.0, -0.5, -1.0), vec4::new(-0.7, -0.1, 0.1, 0.7)];
    for b in a {
        assert(near(b, unpack_snorm4x8(pack_snorm4x8(b)), 1.0 / 127.0));
    }
}

@test
fn half2x16_roundtrip() {
    let a: [vec2; 3] = [vec2::new(1.0, 2.0), vec2::new(-1.0, -2.0), vec2::new(-1.1, 1.1)];
    for b in a {
        assert(near(b, unpack_half2x16(pack_half2x16(b)), 1.0 / 127.0));
    }
}

@test
fn double2x32_roundtrip() {
    let a: [uvec2; 3] = [
        uvec2::new(1, 2),
        uvec2::new(u32::MAX, u32::MAX - 1),
        uvec2::new(0u32.wrapping_sub(1000), 1100),
    ];
    for b in a {
        assert(unpack_double2x32(pack_double2x32(b)) == b);
    }
}

// The other formats.

@test
fn half1x16_roundtrip() {
    let tests: [f32; 6] = [0.0, 1.0, -1.0, 2.0, -2.0, 1.9];
    for t in tests {
        let v0 = unpack_half1x16(pack_half1x16(t));
        let v1 = unpack_half1x16(pack_half1x16(v0));
        assert(near1(v0, v1, f32::epsilon()));
    }
}

@test
fn half4x16_roundtrip() {
    let tests: [f32; 6] = [1.0, 0.0, 2.0, 0.1, 0.5, -0.9];
    for t in tests {
        let v0 = unpack_half4x16(pack_half4x16(vec4::splat(t)));
        let v1 = unpack_half4x16(pack_half4x16(v0));
        let v2 = unpack_half(pack_half(v0));
        assert(near(v0, v1, f32::epsilon()));
        assert(near(v0, v2, f32::epsilon()));
    }
}

@test
fn i3x10_1x2_roundtrip() {
    let tests: [i32; 6] = [0, 1, -1, 2, -2, 3];
    for t in tests {
        let v0 = unpack_i3x10_1x2(pack_i3x10_1x2(ivec4::splat(t)));
        let v1 = unpack_i3x10_1x2(pack_i3x10_1x2(v0));
        assert(v0 == v1);
    }
}

@test
fn u3x10_1x2_roundtrip() {
    for t in 0u32..6u32 {
        let v0 = unpack_u3x10_1x2(pack_u3x10_1x2(uvec4::splat(t)));
        let v1 = unpack_u3x10_1x2(pack_u3x10_1x2(v0));
        assert(v0 == v1);
    }
    assert_eq(pack_uint4x8(u8vec4::new(0xff, 0x77, 0x0, 0x33)), 0x330077ff);
    assert_eq(pack_u3x10_1x2(uvec4::new(0xff, 0x77, 0x0, 0x33)), 0xc001dcff);
}

@test
fn snorm_unorm3x10_1x2_roundtrip() {
    let tests: [f32; 6] = [1.0, 0.0, 2.0, 0.1, 0.5, 0.9];
    for t in tests {
        let s0 = unpack_snorm3x10_1x2(pack_snorm3x10_1x2(vec4::splat(t)));
        let s1 = unpack_snorm3x10_1x2(pack_snorm3x10_1x2(s0));
        assert(near(s0, s1, 0.01));
        let u0 = unpack_unorm3x10_1x2(pack_unorm3x10_1x2(vec4::splat(t)));
        let u1 = unpack_unorm3x10_1x2(pack_unorm3x10_1x2(u0));
        assert(near(u0, u1, 0.001));
    }
}

@test
fn f2x11_1x10_f3x9_e1x5_roundtrip() {
    let tests: [f32; 6] = [1.0, 0.0, 2.0, 0.1, 0.5, 0.9];
    for t in tests {
        let f0 = unpack_f2x11_1x10(pack_f2x11_1x10(vec3::splat(t)));
        let f1 = unpack_f2x11_1x10(pack_f2x11_1x10(f0));
        assert(near(f0, f1, f32::epsilon()));
        let e0 = unpack_f3x9_e1x5(pack_f3x9_e1x5(vec3::splat(t)));
        let e1 = unpack_f3x9_e1x5(pack_f3x9_e1x5(e0));
        assert(near(e0, e1, f32::epsilon()));
    }
}

@test
fn rgbm_roundtrip() {
    for i in 0..1024 {
        let color = vec3::splat(i as f32);
        assert(near(color, unpack_rgbm(pack_rgbm(color)), 0.01));
    }
}

@test
fn unorm_snorm_1x16_2x16_4x16() {
    let u1: [f32; 4] = [1.0, 0.5, 0.1, 0.0];
    for b in u1 {
        assert(near1(b, unpack_unorm1x16(pack_unorm1x16(b)), 1.0 / 65535.0));
        let v = vec4::splat(b);
        assert(near(v, unpack_unorm4x16(pack_unorm4x16(v)), 1.0 / 65535.0));
    }
    let s1: [f32; 4] = [1.0, 0.0, -0.5, -0.1];
    for b in s1 {
        assert(near1(b, unpack_snorm1x16(pack_snorm1x16(b)), 1.0 / 32767.0 * 2.0));
    }
    let u2: [vec2; 3] = [vec2::new(1.0, 0.0), vec2::new(0.5, 0.7), vec2::new(0.1, 0.2)];
    for b in u2 {
        assert(near(b, unpack_unorm2x16(pack_unorm2x16(b)), 1.0 / 65535.0));
    }
    let s2: [vec2; 3] = [vec2::new(1.0, 0.0), vec2::new(-0.5, -0.7), vec2::new(-0.1, 0.1)];
    for b in s2 {
        assert(near(b, unpack_snorm2x16(pack_snorm2x16(b)), 1.0 / 32767.0 * 2.0));
    }
    let s4: [vec4; 3] = [
        vec4::new(1.0, 0.0, -0.5, 0.5),
        vec4::new(-0.3, -0.7, 0.3, 0.7),
        vec4::new(-0.1, 0.1, -0.2, 0.2),
    ];
    for b in s4 {
        assert(near(b, unpack_snorm4x16(pack_snorm4x16(b)), 1.0 / 32767.0 * 2.0));
    }
}

@test
fn unorm_snorm_1x8_2x8_4x8() {
    let u1: [f32; 3] = [1.0, 0.5, 0.0];
    for b in u1 {
        assert(near1(b, unpack_unorm1x8(pack_unorm1x8(b)), 1.0 / 255.0));
    }
    let s1: [f32; 3] = [1.0, -0.7, -1.0];
    for b in s1 {
        assert(near1(b, unpack_snorm1x8(pack_snorm1x8(b)), 1.0 / 127.0));
    }
    let u2: [vec2; 2] = [vec2::new(1.0, 0.7), vec2::new(0.5, 0.1)];
    for b in u2 {
        assert(near(b, unpack_unorm2x8(pack_unorm2x8(b)), 1.0 / 255.0));
    }
    let s2: [vec2; 2] = [vec2::new(1.0, 0.0), vec2::new(-0.7, -0.1)];
    for b in s2 {
        assert(near(b, unpack_snorm2x8(pack_snorm2x8(b)), 1.0 / 127.0));
    }
    let u4: [vec4; 2] = [vec4::new(1.0, 0.7, 0.3, 0.0), vec4::new(0.5, 0.1, 0.2, 0.3)];
    for b in u4 {
        assert(near(b, unpack_unorm4x8(pack_unorm4x8(b)), 1.0 / 255.0));
    }
    let s4: [vec4; 2] = [vec4::new(1.0, 0.0, -0.5, -1.0), vec4::new(-0.7, -0.1, 0.1, 0.7)];
    for b in s4 {
        assert(near(b, unpack_snorm4x8(pack_snorm4x8(b)), 1.0 / 127.0));
    }
}

@test
fn unorm_snorm_templates() {
    let u: [vec2; 2] = [vec2::new(1.0, 0.7), vec2::new(0.5, 0.1)];
    for b in u {
        let c: u16vec2 = pack_unorm::<u16>(b);
        assert(near(b, unpack_unorm::<f32>(c), 1.0 / 255.0));
    }
    let s: [vec2; 3] = [vec2::new(1.0, 0.0), vec2::new(-0.5, -0.7), vec2::new(-0.1, 0.1)];
    for b in s {
        let c: i16vec2 = pack_snorm::<i16>(b);
        assert(near(b, unpack_snorm::<f32>(c), 1.0 / 32767.0 * 2.0));
    }
}

@test
fn small_unorm_formats() {
    let a2: [vec2; 2] = [vec2::new(1.0, 0.7), vec2::new(0.5, 0.0)];
    for b in a2 {
        assert(near(b, unpack_unorm2x4(pack_unorm2x4(b)), 1.0 / 15.0));
    }
    let a4: [vec4; 2] = [vec4::new(1.0, 0.7, 0.5, 0.0), vec4::new(0.5, 0.1, 0.0, 1.0)];
    for b in a4 {
        assert(near(b, unpack_unorm4x4(pack_unorm4x4(b)), 1.0 / 15.0));
        assert(near(b, unpack_unorm3x5_1x1(pack_unorm3x5_1x1(b)), 1.0 / 15.0));
    }
    let a3: [vec3; 2] = [vec3::new(1.0, 0.7, 0.5), vec3::new(0.5, 0.1, 0.0)];
    for b in a3 {
        assert(near(b, unpack_unorm1x5_1x6_1x5(pack_unorm1x5_1x6_1x5(b)), 1.0 / 15.0));
        assert(near(b, unpack_unorm2x3_1x2(pack_unorm2x3_1x2(b)), 1.0 / 3.0));
    }
}

@test
fn int_uint_packing() {
    let p0 = pack_uint2x8(u8vec2::new(1, 2));
    assert_ne(p0, 0);
    assert(unpack_uint2x8(p0) == u8vec2::new(1, 2));
    let p1 = pack_uint4x8(u8vec4::new(1, 2, 3, 4));
    assert_ne(p1, 0);
    assert(unpack_uint4x8(p1) == u8vec4::new(1, 2, 3, 4));
    let p2 = pack_uint2x16(u16vec2::new(1, 2));
    assert_ne(p2, 0);
    assert(unpack_uint2x16(p2) == u16vec2::new(1, 2));
    let p3 = pack_uint4x16(u16vec4::new(1, 2, 3, 4));
    assert_ne(p3, 0);
    assert(unpack_uint4x16(p3) == u16vec4::new(1, 2, 3, 4));
    let p4 = pack_uint2x32(u32vec2::new(1, 2));
    assert_ne(p4, 0);
    assert(unpack_uint2x32(p4) == u32vec2::new(1, 2));
    let q0 = pack_int2x8(i8vec2::new(1, 2));
    assert_ne(q0, 0);
    assert(unpack_int2x8(q0) == i8vec2::new(1, 2));
    let q1 = pack_int4x8(i8vec4::new(1, 2, 3, 4));
    assert_ne(q1, 0);
    assert(unpack_int4x8(q1) == i8vec4::new(1, 2, 3, 4));
    let q2 = pack_int2x16(i16vec2::new(1, 2));
    assert_ne(q2, 0);
    assert(unpack_int2x16(q2) == i16vec2::new(1, 2));
    let q3 = pack_int4x16(i16vec4::new(1, 2, 3, 4));
    assert_ne(q3, 0);
    assert(unpack_int4x16(q3) == i16vec4::new(1, 2, 3, 4));
    let q4 = pack_int2x32(i32vec2::new(1, 2));
    assert_ne(q4, 0);
    assert(unpack_int2x32(q4) == i32vec2::new(1, 2));
}

// Pointer access: `value_ptr` and the `make_*` constructors.

fn vec_ptr<T: Scalar, const N: usize>() {
    let mut v = Vec::<T, N>::splat(T::one());
    let p = value_ptr(&v);
    assert(p == (&v.e[0]) as *const T);
    let q = value_ptr_mut(&mut v);
    unsafe {
        *q = T::zero();
    }
    assert(v.e[0].equal(T::zero()));
}

fn mat_ptr<const C: usize, const R: usize>() {
    let mut m = Mat::<f32, C, R>::identity();
    assert(value_ptr(&m) == (&m.c[0].e[0]) as *const f32);
    let q = value_ptr_mut(&mut m);
    unsafe {
        *(q + C * R - 1) = 5.0;
    }
    assert_eq(m[C - 1][R - 1], 5.0);
}

@test
fn value_ptr_vec() {
    vec_ptr::<f32, 2>();
    vec_ptr::<f32, 3>();
    vec_ptr::<f32, 4>();
    vec_ptr::<f64, 2>();
    vec_ptr::<f64, 3>();
    vec_ptr::<f64, 4>();
}

@test
fn value_ptr_mat() {
    mat_ptr::<2, 2>();
    mat_ptr::<2, 3>();
    mat_ptr::<2, 4>();
    mat_ptr::<3, 2>();
    mat_ptr::<3, 3>();
    mat_ptr::<3, 4>();
    mat_ptr::<4, 2>();
    mat_ptr::<4, 3>();
    mat_ptr::<4, 4>();
}

@test
fn make_pointer_mat() {
    let a: [f32; 16] = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0];
    let b: [f64; 16] = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0];
    let pa = (&a[0]) as *const f32;
    let pb = (&b[0]) as *const f64;
    unsafe {
        assert(make_mat2x2(pa) == mat2x2::new(0.0, 1.0, 2.0, 3.0));
        assert(make_mat2x3(pa) == mat2x3::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0));
        assert(make_mat2x4(pa) == mat2x4::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0));
        assert(make_mat3x2(pa) == mat3x2::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0));
        assert(make_mat3x3(pa) == mat3x3::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0));
        assert(make_mat3x4(pa) == mat3x4::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0));
        assert(make_mat4x2(pa) == mat4x2::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0));
        assert(make_mat4x3(pa) == mat4x3::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0));
        assert(
            make_mat4x4(pa) == mat4x4::new(
                0.0,
                1.0,
                2.0,
                3.0,
                4.0,
                5.0,
                6.0,
                7.0,
                8.0,
                9.0,
                10.0,
                11.0,
                12.0,
                13.0,
                14.0,
                15.0,
            ),
        );
        assert(make_mat2x2(pb) == dmat2x2::new(0.0, 1.0, 2.0, 3.0));
        assert(make_mat2x3(pb) == dmat2x3::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0));
        assert(make_mat2x4(pb) == dmat2x4::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0));
        assert(make_mat3x2(pb) == dmat3x2::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0));
        assert(make_mat3x3(pb) == dmat3x3::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0));
        assert(make_mat3x4(pb) == dmat3x4::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0));
        assert(make_mat4x2(pb) == dmat4x2::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0));
        assert(make_mat4x3(pb) == dmat4x3::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0));
        assert(
            make_mat4x4(pb) == dmat4x4::new(
                0.0,
                1.0,
                2.0,
                3.0,
                4.0,
                5.0,
                6.0,
                7.0,
                8.0,
                9.0,
                10.0,
                11.0,
                12.0,
                13.0,
                14.0,
                15.0,
            ),
        );
        assert(make_mat2(pa) == make_mat2x2(pa));
        assert(make_mat3(pa) == make_mat3x3(pa));
        assert(make_mat4(pa) == make_mat4x4(pa));
    }
}

@test
fn make_pointer_vec() {
    let a: [f32; 16] = [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0];
    let b: [i32; 16] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15];
    let c: [bool; 16] = [
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
        true,
        false,
    ];
    let pa = (&a[0]) as *const f32;
    let pb = (&b[0]) as *const i32;
    let pc = (&c[0]) as *const bool;
    unsafe {
        assert(make_vec2(pa) == vec2::new(0.0, 1.0));
        assert(make_vec3(pa) == vec3::new(0.0, 1.0, 2.0));
        assert(make_vec4(pa) == vec4::new(0.0, 1.0, 2.0, 3.0));
        assert(make_vec2(pb) == ivec2::new(0, 1));
        assert(make_vec3(pb) == ivec3::new(0, 1, 2));
        assert(make_vec4(pb) == ivec4::new(0, 1, 2, 3));
        assert(make_vec2(pc) == bvec2::new(true, false));
        assert(make_vec3(pc) == bvec3::new(true, false, true));
        assert(make_vec4(pc) == bvec4::new(true, false, true, false));
    }
}

@test
fn make_vec_from_vec() {
    assert(make_vec1(ivec1::splat(2)) == ivec1::splat(2));
    assert(make_vec1(ivec2::splat(2)) == ivec1::splat(2));
    assert(make_vec1(ivec3::splat(2)) == ivec1::splat(2));
    assert(make_vec1(ivec4::splat(2)) == ivec1::splat(2));
    assert(make_vec2_from_vec(ivec1::splat(2)) == ivec2::new(2, 0));
    assert(make_vec2_from_vec(ivec2::splat(2)) == ivec2::new(2, 2));
    assert(make_vec2_from_vec(ivec3::splat(2)) == ivec2::new(2, 2));
    assert(make_vec2_from_vec(ivec4::splat(2)) == ivec2::new(2, 2));
    assert(make_vec3_from_vec(ivec1::splat(2)) == ivec3::new(2, 0, 0));
    assert(make_vec3_from_vec(ivec2::splat(2)) == ivec3::new(2, 2, 0));
    assert(make_vec3_from_vec(ivec3::splat(2)) == ivec3::new(2, 2, 2));
    assert(make_vec3_from_vec(ivec4::splat(2)) == ivec3::new(2, 2, 2));
    assert(make_vec4_from_vec(ivec1::splat(2)) == ivec4::new(2, 0, 0, 1));
    assert(make_vec4_from_vec(ivec2::splat(2)) == ivec4::new(2, 2, 0, 1));
    assert(make_vec4_from_vec(ivec3::splat(2)) == ivec4::new(2, 2, 2, 1));
    assert(make_vec4_from_vec(ivec4::splat(2)) == ivec4::new(2, 2, 2, 2));
}

// Exact bits and edge cases.

@test
fn quat_pointer_order() {
    // A quaternion stores x, y, z, w; `Quat::new` takes w first.
    let q = Quat::<f32>::new(4.0, 1.0, 2.0, 3.0);
    let p = value_ptr(&q);
    unsafe {
        assert_eq(p[0], 1.0);
        assert_eq(p[3], 4.0);
        let r = make_quat(p);
        assert(r == q);
    }
}

@test
fn exact_packed_bits() {
    assert_eq(pack_unorm2x16(vec2::new(1.0, 0.5)), 0x8000FFFF);
    assert_eq(pack_snorm2x16(vec2::new(-1.0, 1.0)), 0x7FFF8001);
    assert_eq(pack_snorm4x8(vec4::new(-1.0, 0.0, 1.0, -2.0)), 0x817F0081);
    assert_eq(pack_unorm1x5_1x6_1x5(vec3::new(1.0, 1.0, 0.0)), 0x07FF);
    assert_eq(pack_unorm3x5_1x1(vec4::new(0.0, 0.0, 0.0, 1.0)), 0x8000);
    assert_eq(pack_unorm2x3_1x2(vec3::new(1.0, 0.0, 1.0)), 0xC7);
    assert(unpack_i3x10_1x2(0xFFFFFFFF) == ivec4::splat(-1));
    assert(unpack_i3x10_1x2(pack_i3x10_1x2(ivec4::new(511, -512, 1023, 2))) == ivec4::new(511, -512, -1, -2));
    assert_eq(f64_bits(pack_double2x32(uvec2::new(0, 0x3FF00000))), f64_bits(1.0));
    // A NaN clamps through min and max unchanged; the conversion then packs 0.
    assert_eq(pack_unorm1x8(f32::nan()), 0);
}

@test
fn float16_rounding() {
    assert_eq(pack_half1x16(1.0), 0x3C00);
    assert_eq(pack_half1x16(-2.0), 0xC000);
    assert_eq(pack_half1x16(65504.0), 0x7BFF);
    assert_eq(pack_half1x16(65520.0), 0x7C00);
    assert_eq(pack_half1x16(f32::infinity()), 0x7C00);
    assert_eq(pack_half1x16(f32_from_bits(0x7F800001)), 0x7C01);
    assert_eq(pack_half1x16(f32_from_bits(0xFFC00000)), 0xFE00);
    assert_eq(pack_half1x16(5.9604645e-8), 0x0001);
    assert_eq(pack_half1x16(2.9802322e-8), 0x0001);
    assert_eq(pack_half1x16(1e-9), 0x0000);
    assert_eq(pack_half1x16(-0.0), 0x8000);
    // Halves round up, not to even: 1 + 2^-11 packs as 1 + 2^-10.
    assert_eq(pack_half1x16(f32_from_bits(0x3F801000)), 0x3C01);
    assert_eq(f32_bits(unpack_half1x16(0x0001)), f32_bits(5.9604645e-8));
    assert_eq(f32_bits(unpack_half1x16(0x8000)), 0x80000000);
    assert_eq(f32_bits(unpack_half1x16(0x7E00)), 0x7FC00000);
    for h in 0u32..0x7C00u32 {
        assert_eq(pack_half1x16(unpack_half1x16(h as u16)) as u32, h);
    }
}

@test
fn f2x11_1x10_specials() {
    // NaN packs as all ones and an infinity as the top exponent; both unpack as -1.
    assert_eq(pack_f2x11_1x10(vec3::new(f32::nan(), 0.0, 0.0)), 0x7FF);
    assert_eq(pack_f2x11_1x10(vec3::new(f32::infinity(), 0.0, 0.0)), 0x7C0);
    assert_eq(pack_f2x11_1x10(vec3::new(0.0, 0.0, f32::infinity())), 0x3E0u32 << 22);
    assert(unpack_f2x11_1x10(0x7FF) == vec3::new(-1.0, 0.0, 0.0));
    assert(unpack_f2x11_1x10(0x7C0) == vec3::new(-1.0, 0.0, 0.0));
    // x and y read the whole word above them: a zero field unpacks to 2^-15 when a higher one is set.
    let tiny = f32_from_bits(0x38000000);
    assert(unpack_f2x11_1x10(0x3E0u32 << 22) == vec3::new(tiny, tiny, -1.0));
    assert(unpack_f2x11_1x10(1u32 << 11)[0] != 0.0);
    assert(unpack_f2x11_1x10(pack_f2x11_1x10(vec3::new(1.0, 2.0, 4.0))) == vec3::new(1.0, 2.0, 4.0));
}

@test
fn f3x9_e1x5_values() {
    assert(unpack_f3x9_e1x5(pack_f3x9_e1x5(vec3::new(1.0, 0.5, 0.25))) == vec3::new(1.0, 0.5, 0.25));
    assert(unpack_f3x9_e1x5(pack_f3x9_e1x5(vec3::new(-1.0, 0.0, 0.0))) == vec3::splat(0.0));
    assert(unpack_f3x9_e1x5(pack_f3x9_e1x5(vec3::new(f32::infinity(), 0.0, 0.0))) == vec3::new(32768.0, 0.0, 0.0));
}

@test
fn generic_unorm_snorm() {
    assert(pack_unorm::<u8>(dvec3::new(0.0, 0.5, 1.0)) == u8vec3::new(0, 128, 255));
    assert(pack_snorm::<i8>(vec2::new(-1.0, 1.0)) == i8vec2::new(-127, 127));
    assert(unpack_snorm::<f32>(i8vec2::new(-128, 127)) == vec2::new(-1.0, 1.0));
    assert((unpack_unorm::<f64>(u16vec1::new(65535))[0] - 1.0).abs() <= 1e-15);
    assert(pack_unorm::<u32>(dvec1::new(1.0)) == u32vec1::new(u32::MAX));
}

const C_UNORM: u32 = pack_unorm2x16(vec2::new(1.0, 0.5));
const C_SNORM: u32 = pack_snorm4x8(vec4::new(-1.0, 0.0, 1.0, -2.0));
const C_UNORM4X4: vec4 = unpack_unorm4x4(0xF0F0);
const C_I3X10: ivec4 = unpack_i3x10_1x2(0xFFFFFFFF);
const C_UINT4X8: u32 = pack_uint4x8(u8vec4::new(1, 2, 3, 4));
const C_RGBM: vec3 = unpack_rgbm(vec4::new(0.5, 0.25, 1.0, 1.0));

@test
fn constant_initializers() {
    assert_eq(C_UNORM, 0x8000FFFF);
    assert_eq(C_SNORM, 0x817F0081);
    assert(C_UNORM4X4 == vec4::new(0.0, 1.0, 0.0, 1.0));
    assert(C_I3X10 == ivec4::splat(-1));
    assert_eq(C_UINT4X8, 0x04030201);
    assert(C_RGBM == vec3::new(3.0, 1.5, 6.0));
}
