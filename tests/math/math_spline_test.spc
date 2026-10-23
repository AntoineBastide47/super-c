// std::math::spline: Catmull-Rom, Hermite and cubic curves of f32 vectors, then bit-exact values for f32
// and f64 vectors, matrices and quaternions, integer vectors (8-bit wrapping included), curve end points
// and constant initializers.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::quat as *;
import std::math::compare as *;
import std::math::spline as *;

@test
fn catmull_rom_vectors() {
    let r2 = catmull_rom(vec2::new(0.0, 0.0), vec2::new(1.0, 0.0), vec2::new(1.0, 1.0), vec2::new(0.0, 1.0), 0.5f32);
    assert(all(equal_eps(r2, vec2::new(1.125, 0.5), f32::epsilon())));
    let r3 = catmull_rom(
        vec3::new(0.0, 0.0, 0.0),
        vec3::new(1.0, 0.0, 0.0),
        vec3::new(1.0, 1.0, 0.0),
        vec3::new(0.0, 1.0, 0.0),
        0.5f32,
    );
    assert(all(equal_eps(r3, vec3::new(1.125, 0.5, 0.0), f32::epsilon())));
    let r4 = catmull_rom(
        vec4::new(0.0, 0.0, 0.0, 1.0),
        vec4::new(1.0, 0.0, 0.0, 1.0),
        vec4::new(1.0, 1.0, 0.0, 1.0),
        vec4::new(0.0, 1.0, 0.0, 1.0),
        0.5f32,
    );
    assert(all(equal_eps(r4, vec4::new(1.125, 0.5, 0.0, 1.0), f32::epsilon())));
}

@test
fn hermite_vectors() {
    let r2 = hermite(vec2::new(0.0, 0.0), vec2::new(1.0, 0.0), vec2::new(1.0, 1.0), vec2::new(0.0, 1.0), 0.5f32);
    assert(all(equal_eps(r2, vec2::new(0.625, 0.375), f32::epsilon())));
    let r3 = hermite(
        vec3::new(0.0, 0.0, 0.0),
        vec3::new(1.0, 0.0, 0.0),
        vec3::new(1.0, 1.0, 0.0),
        vec3::new(0.0, 1.0, 0.0),
        0.5f32,
    );
    assert(all(equal_eps(r3, vec3::new(0.625, 0.375, 0.0), f32::epsilon())));
    let r4 = hermite(
        vec4::new(0.0, 0.0, 0.0, 1.0),
        vec4::new(1.0, 0.0, 0.0, 1.0),
        vec4::new(1.0, 1.0, 0.0, 1.0),
        vec4::new(0.0, 1.0, 0.0, 1.0),
        0.5f32,
    );
    assert(all(equal_eps(r4, vec4::new(0.625, 0.375, 0.0, 1.0), f32::epsilon())));
}

@test
fn cubic_vectors() {
    let r2 = cubic(vec2::new(0.0, 0.0), vec2::new(1.0, 0.0), vec2::new(1.0, 1.0), vec2::new(0.0, 1.0), 0.5f32);
    assert(all(equal_eps(r2, vec2::new(0.75, 1.5), f32::epsilon())));
    let r3 = cubic(
        vec3::new(0.0, 0.0, 0.0),
        vec3::new(1.0, 0.0, 0.0),
        vec3::new(1.0, 1.0, 0.0),
        vec3::new(0.0, 1.0, 0.0),
        0.5f32,
    );
    assert(all(equal_eps(r3, vec3::new(0.75, 1.5, 0.0), f32::epsilon())));
    let r4 = cubic(
        vec4::new(0.0, 0.0, 0.0, 1.0),
        vec4::new(1.0, 0.0, 0.0, 1.0),
        vec4::new(1.0, 1.0, 0.0, 1.0),
        vec4::new(0.0, 1.0, 0.0, 1.0),
        0.5f32,
    );
    assert(all(equal_eps(r4, vec4::new(0.75, 1.5, 0.0, 1.875), f32::epsilon())));
}

@test
fn vector_bits() {
    let cr = catmull_rom(
        vec3::new(0.1, 0.2, 0.3),
        vec3::new(1.3, -0.7, 2.0),
        vec3::new(0.4, 0.9, -1.1),
        vec3::new(2.2, 0.6, 0.0),
        0.3f32,
    );
    assert_eq(f32_bits(cr.x()), 0x3f8cb5ddu32);
    assert_eq(f32_bits(cr.y()), 0xbeb013aau32);
    assert_eq(f32_bits(cr.z()), 0x3fa52f1bu32);
    let he = hermite(dvec2::new(0.1, 0.2), dvec2::new(1.3, -0.7), dvec2::new(0.4, 0.9), dvec2::new(2.2, 0.6), 0.7f64);
    assert_eq(f64_bits(he.x()), 0x3fb7fcb923a29c6cu64);
    assert_eq(f64_bits(he.y()), 0x3fe3ba5e353f7cedu64);
    let cu = cubic(vec4::new(0.1, 0.2, 0.3, 0.4), vec4::splat(1.3), vec4::splat(-0.4), vec4::splat(2.2), 0.6f32);
    assert_eq(f32_bits(cu.x()), 0x401cc63fu32);
    assert_eq(f32_bits(cu.w()), 0x4020ebeeu32);
}

@test
fn matrix_and_quaternion_curves() {
    let m = catmull_rom(
        mat2::cols(vec2::new(1.0, 2.0), vec2::new(3.0, 4.0)),
        mat2::diagonal(0.5),
        mat2::cols(vec2::new(-1.0, 0.0), vec2::new(2.0, 1.0)),
        mat2::diagonal(3.0),
        0.25f32,
    );
    assert_eq(f32_bits(m.c[0].e[0]), 0x3d880000u32);
    assert_eq(f32_bits(m.c[0].e[1]), 0xbe100000u32);
    assert_eq(f32_bits(m.c[1].e[0]), 0x3e780000u32);
    assert_eq(f32_bits(m.c[1].e[1]), 0x3e9e0000u32);
    let q = hermite(
        quat::new(1.0, 0.0, 0.0, 0.0),
        quat::new(0.5, 0.1, 0.2, 0.3),
        quat::new(0.0, 1.0, 0.0, 0.0),
        quat::new(0.2, 0.3, -0.4, 0.5),
        0.4f32,
    );
    assert_eq(f32_bits(q.w), 0x3f3367a1u32);
    assert_eq(f32_bits(q.x), 0x3eacd9e8u32);
    assert_eq(f32_bits(q.y), 0x3d89a028u32);
    assert_eq(f32_bits(q.z), 0xbb9d4958u32);
}

@test
fn integer_curves() {
    let ci = catmull_rom(ivec3::new(1, 2, 3), ivec3::new(4, 5, 6), ivec3::new(-7, 8, 9), ivec3::new(10, -11, 12), 3);
    assert_eq(ci, ivec3::new(307, -184, 15));
    let cu = cubic(u8vec2::new(200, 3), u8vec2::new(7, 250), u8vec2::new(100, 1), u8vec2::new(5, 9), 13u8);
    assert_eq(cu, u8vec2::new(32, 223));
}

@test
fn curve_ends() {
    let p1 = dvec3::new(0.25, -1.5, 3.0);
    let p2 = dvec3::new(2.0, 0.5, -1.0);
    assert_eq(catmull_rom(dvec3::splat(9.0), p1, p2, dvec3::splat(-9.0), 0.0f64), p1);
    assert_eq(catmull_rom(dvec3::splat(9.0), p1, p2, dvec3::splat(-9.0), 1.0f64), p2);
    assert_eq(hermite(p1, dvec3::splat(7.0), p2, dvec3::splat(-7.0), 0.0f64), p1);
    assert_eq(hermite(p1, dvec3::splat(7.0), p2, dvec3::splat(-7.0), 1.0f64), p2);
    assert_eq(cubic(p1, p2, p1, p2, 0.0f64), p2);
}

const CURVE: Vec<f32, 3> = catmull_rom(
    vec3::new(0.1, 0.2, 0.3),
    vec3::new(1.3, -0.7, 2.0),
    vec3::new(0.4, 0.9, -1.1),
    vec3::new(2.2, 0.6, 0.0),
    0.3f32,
);

@test
fn constant_initializers() {
    assert_eq(f32_bits(CURVE.x()), 0x3f8cb5ddu32);
    assert_eq(f32_bits(CURVE.z()), 0x3fa52f1bu32);
}
