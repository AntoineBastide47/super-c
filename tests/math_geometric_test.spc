// std::math::geometric: dot, length, distance, cross, normalize, faceforward, reflect, refract, the
// norms and the vector angles, then the summation order of dot, the sign of zero in length,
// faceforward and l1_norm, the scalar refract's NaN on total internal reflection, every overload of
// the norm, angle, triangle normal, projection, perpendicular, orthonormalize and polar coordinate
// functions, their degenerate inputs, and constant initializers.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::geometric as *;
import std::math::compare as *;
import std::math::mat as *;

@test
fn unit_length() {
    let e = f32::epsilon();
    assert(epsilon_equal(length(vec1::new(1.0)), 1.0f32, e));
    assert(epsilon_equal(length(vec2::new(1.0, 0.0)), 1.0f32, e));
    assert(epsilon_equal(length(vec3::new(1.0, 0.0, 0.0)), 1.0f32, e));
    assert(epsilon_equal(length(vec4::new(1.0, 0.0, 0.0, 0.0)), 1.0f32, e));
}

@test
fn distance_to_self() {
    let e = f32::epsilon();
    assert(epsilon_equal(distance(vec1::new(1.0), vec1::new(1.0)), 0.0f32, e));
    assert(epsilon_equal(distance(vec2::new(1.0, 0.0), vec2::new(1.0, 0.0)), 0.0f32, e));
    assert(epsilon_equal(distance(vec3::new(1.0, 0.0, 0.0), vec3::new(1.0, 0.0, 0.0)), 0.0f32, e));
    assert(epsilon_equal(distance(vec4::new(1.0, 0.0, 0.0, 0.0), vec4::new(1.0, 0.0, 0.0, 0.0)), 0.0f32, e));
}

@test
fn dot_of_ones() {
    let e = f32::epsilon();
    assert(epsilon_equal(dot(vec1::splat(1.0), vec1::splat(1.0)), 1.0f32, e));
    assert(epsilon_equal(dot(vec2::splat(1.0), vec2::splat(1.0)), 2.0f32, e));
    assert(epsilon_equal(dot(vec3::splat(1.0), vec3::splat(1.0)), 3.0f32, e));
    assert(epsilon_equal(dot(vec4::splat(1.0), vec4::splat(1.0)), 4.0f32, e));
}

@test
fn cross_of_axes() {
    let e = f32::epsilon();
    let c1 = cross(vec3::new(1.0, 0.0, 0.0), vec3::new(0.0, 1.0, 0.0));
    let c2 = cross(vec3::new(0.0, 1.0, 0.0), vec3::new(1.0, 0.0, 0.0));
    assert(all(epsilon_equal(c1, vec3::new(0.0, 0.0, 1.0), e)));
    assert(all(epsilon_equal(c2, vec3::new(0.0, 0.0, -1.0), e)));
}

@test
fn normalize_basis() {
    let e = f32::epsilon();
    let n1 = normalize(vec3::new(1.0, 0.0, 0.0));
    let n2 = normalize(vec3::new(2.0, 0.0, 0.0));
    assert(all(epsilon_equal(n1, vec3::new(1.0, 0.0, 0.0), e)));
    assert(all(epsilon_equal(n2, vec3::new(1.0, 0.0, 0.0), e)));

    let five: f32 = 5.0;
    let ro = vec3::new(five.cos() * 3.0, 2.0, five.sin() * 3.0);
    let w = normalize(vec3::new(0.0, -0.2, 0.0) - ro);
    let u = normalize(cross(w, vec3::new(0.0, 1.0, 0.0)));
    let v = cross(u, w);
    let x = cross(w, u);
    assert(all(equal_eps(x + v, vec3::splat(0.0), 0.01f32)));
}

@test
fn faceforward_flips() {
    let n = vec3::new(0.0, 0.0, 1.0);
    let i = vec3::new(1.0, 0.0, 1.0);
    let nref = vec3::new(0.0, 0.0, 1.0);
    let f = faceforward(n, i, nref);
    assert(all(equal_eps(f, vec3::new(0.0, 0.0, -1.0), 0.0001f32)));
}

@test
fn reflect_vec2() {
    let c = reflect(vec2::new(1.0, -1.0), vec2::new(0.0, 1.0));
    assert(all(equal_eps(c, vec2::new(1.0, 1.0), 0.0001f32)));
    let d = reflect(dvec2::new(1.0, -1.0), dvec2::new(0.0, 1.0));
    assert(all(equal_eps(d, dvec2::new(1.0, 1.0), 0.0001f64)));
}

@test
fn refract_forms() {
    let c = refract(-1.0f32, 1.0f32, 0.5f32);
    assert(equal_eps(c, -1.0f32, 0.0001f32));
    let v = refract(vec2::new(0.0, -1.0), vec2::new(0.0, 1.0), 0.5f32);
    assert(all(equal_eps(v, vec2::new(0.0, -1.0), 0.0001f32)));
    let d = refract(dvec2::new(0.0, -1.0), dvec2::new(0.0, 1.0), 0.5f64);
    assert(all(equal_eps(d, dvec2::new(0.0, -1.0), 0.0001f64)));
    let w = refract(vec4::new(0.0, -1.0, 0.0, 0.0), vec4::new(0.0, 1.0, 0.0, 0.0), 0.5f32);
    assert(all(equal_eps(w, vec4::new(0.0, -1.0, 0.0, 0.0), 0.0001f32)));
}

// Dot sums a vec3's products left to right and a vec4's in pairs. In f32, 1e8 + 1 and -1e8 + 1 round
// to 1e8 and -1e8: (1e8 + 1) + (-1e8 + 1) is 0, ((1e8 + 1) - 1e8) + 1 is 1.
@test
fn dot_summation_order() {
    let big: f32 = 100000000.0;
    assert_eq(dot(vec4::new(big, 1.0, -big, 1.0), vec4::splat(1.0)), 0.0f32);
    assert_eq(dot(vec3::new(big, 1.0, -big), vec3::splat(1.0)), 0.0f32);
    assert_eq(dot(vec3::new(big, -big, 1.0), vec3::splat(1.0)), 1.0f32);
}

// The scalar length is `x >= 0 ? x : -x`: -0 stays -0; a vector's is `sqrt(dot(v, v))`.
@test
fn length_zero_sign() {
    assert_eq(f32_bits(length(-0.0f32)), 0x80000000u32);
    assert_eq(length(-3.0f64), 3.0f64);
    assert_eq(f32_bits(length(vec1::new(-0.0))), 0u32);
    assert_eq(distance(2.0f32, -1.0f32), 3.0f32);
}

// Faceforward negates vec1 and vec2 component by component and vec3 and vec4 as `0 - n`: a +0 component
// becomes -0 in the first case and stays +0 in the second.
@test
fn faceforward_zero_sign() {
    let f2 = faceforward(vec2::new(0.0, 1.0), vec2::new(0.0, 1.0), vec2::new(0.0, 1.0));
    assert_eq(f32_bits(f2.x()), 0x80000000u32);
    assert_eq(f2.y(), -1.0f32);
    let f3 = faceforward(vec3::new(0.0, 1.0, 0.0), vec3::new(0.0, 1.0, 0.0), vec3::new(0.0, 1.0, 0.0));
    assert_eq(f32_bits(f3.x()), 0u32);
    assert_eq(f3.y(), -1.0f32);
    assert_eq(faceforward(2.0f32, 1.0f32, -1.0f32), 2.0f32);
    assert_eq(faceforward(2.0f32, 1.0f32, 1.0f32), -2.0f32);
}

// On total internal reflection a vector refracts to zero and a scalar to NaN, as the scalar form
// multiplies by `k >= 0` instead of choosing.
@test
fn refract_total_internal_reflection() {
    let i: f32 = 0.6;
    let n: f32 = 0.1;
    let eta: f32 = 2.0;
    assert(refract(i, n, eta).is_nan());
    assert(refract(vec1::new(i), vec1::new(n), eta) == vec1::new(0.0));
    assert(refract(vec2::new(i, 0.8), vec2::new(n, 0.0), eta) == vec2::splat(0.0));
}

@test
fn normalize_zero_is_nan() {
    let z = normalize(vec3::splat(0.0));
    assert(z.x().is_nan() && z.y().is_nan() && z.z().is_nan());
}

@test
fn double_precision() {
    let a = dvec4::new(1.0, 2.0, 3.0, 4.0);
    assert_eq(dot(a, a), 30.0f64);
    assert_eq(length(dvec2::new(3.0, 4.0)), 5.0f64);
    assert(cross(dvec3::new(1.0, 0.0, 0.0), dvec3::new(0.0, 1.0, 0.0)) == dvec3::new(0.0, 0.0, 1.0));
    assert(normalize(dvec2::new(0.0, 2.0)) == dvec2::new(0.0, 1.0));
    assert(reflect(dvec3::new(1.0, -1.0, 0.0), dvec3::new(0.0, 1.0, 0.0)) == dvec3::new(1.0, 1.0, 0.0));
    assert_eq(dot(2.0f64, 3.0f64), 6.0f64);
}

const DOT4: f32 = dot(vec4::new(1.0, 2.0, 3.0, 4.0), vec4::new(5.0, 6.0, 7.0, 8.0));
const CROSS: Vec<f32, 3> = cross(vec3::new(1.0, 0.0, 0.0), vec3::new(0.0, 1.0, 0.0));
const NORMAL: Vec<f32, 2> = normalize(vec2::new(0.0, 3.0));
const REFLECT: Vec<f32, 2> = reflect(vec2::new(1.0, -1.0), vec2::new(0.0, 1.0));
const REFRACT: f32 = refract(-1.0f32, 1.0f32, 0.5f32);
const FACE: Vec<f32, 3> = faceforward(vec3::new(0.0, 0.0, 1.0), vec3::new(1.0, 0.0, 1.0), vec3::new(0.0, 0.0, 1.0));

@test
fn constant_initializers() {
    assert_eq(DOT4, 70.0f32);
    assert(CROSS == vec3::new(0.0, 0.0, 1.0));
    assert(NORMAL == vec2::new(0.0, 1.0));
    assert(REFLECT == vec2::new(1.0, 1.0));
    assert_eq(REFRACT, refract(-1.0f32, 1.0f32, 0.5f32));
    assert(FACE == vec3::new(0.0, 0.0, -1.0));
}

@test
fn lmax_norm_values() {
    assert(equal_eps(lmax_norm(vec3::new(-1.0, -2.0, -3.0)), 3.0f32, 0.00001f32));
    assert(equal_eps(lmax_norm(vec3::new(2.0, 3.0, 1.0)), 3.0f32, 0.00001f32));
}

@test
fn lx_norm_values() {
    let e: f32 = 0.00001;
    let a = vec3::new(2.0, 3.0, 1.0);
    let b = vec3::new(-1.0, -2.0, -3.0);
    assert(equal_eps(lx_norm(a, 1), l1_norm(a), e));
    assert(equal_eps(lx_norm(a, 1), 6.0f32, e));
    assert(equal_eps(lx_norm(b, 1), l1_norm(b), e));
    assert(equal_eps(lx_norm(b, 1), 6.0f32, e));
    assert(equal_eps(lx_norm(a, 2), l2_norm(a), e));
    assert(equal_eps(lx_norm(a, 2), 3.741657387f32, e));
    assert(equal_eps(lx_norm(b, 2), l2_norm(b), e));
    assert(equal_eps(lx_norm(b, 2), 3.741657387f32, e));
    assert(equal_eps(lx_norm(a, 3), 3.301927249f32, e));
    assert(equal_eps(lx_norm(b, 3), 3.301927249f32, e));
}

@test
fn vector_angle_quarter_pi() {
    let q = pi::<f32>() * 0.25;
    assert(epsilon_equal(vector_angle(vec2::new(1.0, 0.0), normalize(vec2::new(1.0, 1.0))), q, 0.01f32));
    assert(epsilon_equal(vector_angle(vec3::new(1.0, 0.0, 0.0), normalize(vec3::new(1.0, 1.0, 0.0))), q, 0.01f32));
    let d = vector_angle(vec4::new(1.0, 0.0, 0.0, 0.0), normalize(vec4::new(1.0, 1.0, 0.0, 0.0)));
    assert(epsilon_equal(d, q, 0.01f32));
}

@test
fn oriented_angle_vec2() {
    let q = pi::<f32>() * 0.25;
    let n = normalize(vec2::new(1.0, 1.0));
    assert(epsilon_equal(oriented_angle(vec2::new(1.0, 0.0), n), q, 0.01f32));
    assert(epsilon_equal(oriented_angle(vec2::new(0.0, 1.0), n), -pi::<f32>() * 0.25, 0.01f32));
    assert(epsilon_equal(oriented_angle(n, vec2::new(0.0, 1.0)), q, 0.01f32));
}

@test
fn oriented_angle_vec3() {
    let q = pi::<f32>() * 0.25;
    let n = normalize(vec3::new(1.0, 1.0, 0.0));
    let z = vec3::new(0.0, 0.0, 1.0);
    assert(epsilon_equal(oriented_angle_3d(vec3::new(1.0, 0.0, 0.0), n, z), q, 0.01f32));
    assert(epsilon_equal(oriented_angle_3d(vec3::new(0.0, 1.0, 0.0), n, z), -pi::<f32>() * 0.25, 0.01f32));
    assert(epsilon_equal(oriented_angle_3d(n, vec3::new(0.0, 1.0, 0.0), z), q, 0.01f32));
}

// The squared length and distance take scalars and vectors of every size, the other norms vec3s.
@test
fn norm_overloads() {
    assert_eq(length2(3.0f32), 9.0f32);
    assert_eq(length2(vec1::new(-2.0)), 4.0f32);
    assert_eq(length2(vec2::new(3.0, 4.0)), 25.0f32);
    assert_eq(length2(vec3::new(1.0, 2.0, 3.0)), 14.0f32);
    assert_eq(length2(dvec4::new(1.0, 2.0, 3.0, 4.0)), 30.0f64);
    assert_eq(distance2(1.0f64, 4.0f64), 9.0f64);
    assert_eq(distance2(vec2::new(1.0, 1.0), vec2::new(4.0, 5.0)), 25.0f32);
    assert_eq(distance2(dvec3::new(1.0, 2.0, 3.0), dvec3::new(1.0, 2.0, 5.0)), 4.0f64);
    let a = vec3::new(1.0, 2.0, 3.0);
    let b = vec3::new(-1.0, 0.0, 6.0);
    assert_eq(l1_norm_between(a, b), 7.0f32);
    assert_eq(l1_norm(b - a), 7.0f32);
    assert_eq(l2_norm_between(vec3::new(1.0, 1.0, 1.0), vec3::new(4.0, 5.0, 1.0)), 5.0f32);
    assert_eq(lx_norm_between(a, b, 1), 7.0f32);
    assert_eq(lx_norm_between(a, b, 2), l2_norm_between(a, b));
    assert_eq(lmax_norm_between(a, b), 3.0f32);
    assert_eq(l1_norm(dvec3::new(-1.0, 2.0, -3.0)), 6.0f64);
    assert_eq(l2_norm(dvec3::new(2.0, 3.0, 6.0)), 7.0f64);
    assert_eq(lx_norm(dvec3::new(0.0, 0.0, 2.0), 3), 2.0f64);
    assert_eq(lmax_norm(dvec3::new(-4.0, 2.0, 3.0)), 4.0f64);
}

// The abs of -0 is -0, so the L1 norm of a negative zero vector is -0; max lets a NaN in x through and
// drops one in y or z; depth 0 is `pow(3, 1 / 0)`.
@test
fn norm_edge_values() {
    assert_eq(f32_bits(l1_norm(vec3::splat(-0.0))), 0x80000000u32);
    assert_eq(f32_bits(l1_norm_between(vec3::splat(1.0), vec3::splat(1.0))), 0u32);
    let nan = f32::nan();
    assert(lmax_norm(vec3::new(nan, 1.0, 2.0)).is_nan());
    assert_eq(lmax_norm(vec3::new(1.0, nan, 2.0)), 2.0f32);
    assert_eq(lmax_norm(vec3::new(1.0, 2.0, nan)), 2.0f32);
    assert(lx_norm(vec3::new(1.0, 2.0, 3.0), 0).is_inf());
    assert(length2(vec2::new(nan, 0.0)).is_nan());
}

// The angle takes scalars and vectors; the dot product is clamped to [-1, 1] before acos. Each
// expected angle is the C library's acos of the clamped value, as vector_angle calls it.
@test
fn vector_angle_overloads() {
    assert_eq(vector_angle(1.0f32, -1.0f32), (-1.0f32).acos());
    assert_eq(vector_angle(0.5f64, 2.0f64), 0.0f64);
    assert_eq(vector_angle(vec1::new(1.0), vec1::new(1.0)), 0.0f32);
    assert_eq(vector_angle(vec2::new(1.0, 0.0), vec2::new(2.0, 0.0)), 0.0f32);
    assert_eq(vector_angle(vec3::new(1.0, 0.0, 0.0), vec3::new(-3.0, 0.0, 0.0)), (-1.0f32).acos());
    assert_eq(vector_angle(dvec3::new(1.0, 0.0, 0.0), dvec3::new(0.0, 1.0, 0.0)), 0.0f64.acos());
    assert(vector_angle(vec2::new(f32::nan(), 0.0), vec2::new(1.0, 0.0)).is_nan());
}

// The oriented angle of vec2s negates unless the partial cross product is positive: collinear vectors
// give -0 and -pi; the vec3 form negates only when the reference side test is negative.
@test
fn oriented_angle_signs() {
    assert_eq(f32_bits(oriented_angle(vec2::new(1.0, 0.0), vec2::new(1.0, 0.0))), 0x80000000u32);
    assert_eq(oriented_angle(vec2::new(1.0, 0.0), vec2::new(-1.0, 0.0)), -(-1.0f32).acos());
    assert_eq(oriented_angle(dvec2::new(1.0, 0.0), dvec2::new(0.0, -1.0)), -0.0f64.acos());
    let x = vec3::new(1.0, 0.0, 0.0);
    let y = vec3::new(0.0, 1.0, 0.0);
    assert_eq(oriented_angle_3d(x, y, vec3::new(0.0, 0.0, -1.0)), -0.0f32.acos());
    assert_eq(oriented_angle_3d(x, y, vec3::new(1.0, 0.0, 0.0)), 0.0f32.acos());
    assert_eq(
        oriented_angle_3d(dvec3::new(0.0, 1.0, 0.0), dvec3::new(1.0, 0.0, 0.0), dvec3::new(0.0, 0.0, 1.0)),
        -0.0f64.acos(),
    );
}

@test
fn triangle_normal_winding() {
    let o = vec3::new(0.0, 0.0, 0.0);
    let x = vec3::new(1.0, 0.0, 0.0);
    let y = vec3::new(0.0, 1.0, 0.0);
    assert(triangle_normal(o, x, y) == vec3::new(0.0, 0.0, 1.0));
    assert(triangle_normal(o, y, x) == vec3::new(0.0, 0.0, -1.0));
    let d = triangle_normal(dvec3::new(0.0, 0.0, 0.0), dvec3::new(0.0, 2.0, 0.0), dvec3::new(0.0, 0.0, 2.0));
    assert(d == dvec3::new(1.0, 0.0, 0.0));
    let degenerate = triangle_normal(o, x, vec3::new(2.0, 0.0, 0.0));
    assert(degenerate.x().is_nan() && degenerate.y().is_nan() && degenerate.z().is_nan());
}

@test
fn proj_perp_overloads() {
    assert_eq(proj(3.0f32, 2.0f32), 3.0f32);
    assert_eq(perp(3.0f32, 2.0f32), 0.0f32);
    assert(proj(vec1::new(2.0), vec1::new(-4.0)) == vec1::new(2.0));
    assert(proj(vec2::new(1.0, 1.0), vec2::new(2.0, 0.0)) == vec2::new(1.0, 0.0));
    assert(perp(vec2::new(1.0, 1.0), vec2::new(2.0, 0.0)) == vec2::new(0.0, 1.0));
    assert(proj(vec3::new(1.0, 2.0, 3.0), vec3::new(0.0, 0.0, 2.0)) == vec3::new(0.0, 0.0, 3.0));
    assert(perp(vec3::new(1.0, 2.0, 3.0), vec3::new(0.0, 0.0, 2.0)) == vec3::new(1.0, 2.0, 0.0));
    assert(proj(dvec4::new(1.0, 2.0, 3.0, 4.0), dvec4::new(0.0, 0.0, 0.0, 0.5)) == dvec4::new(0.0, 0.0, 0.0, 4.0));
    assert(perp(dvec4::new(1.0, 2.0, 3.0, 4.0), dvec4::new(0.0, 0.0, 0.0, 0.5)) == dvec4::new(1.0, 2.0, 3.0, 0.0));
    let z = proj(vec3::new(1.0, 2.0, 3.0), vec3::splat(0.0));
    assert(z.x().is_nan() && z.y().is_nan() && z.z().is_nan());
}

@test
fn orthonormalize_forms() {
    let m = mat3::cols(vec3::new(2.0, 0.0, 0.0), vec3::new(1.0, 1.0, 0.0), vec3::new(1.0, 1.0, 1.0));
    assert(orthonormalize(m) == mat3::identity());
    let r = orthonormalize(
        dmat3::cols(dvec3::new(1.0, 2.0, 3.0), dvec3::new(-2.0, 0.5, 1.0), dvec3::new(0.3, -1.0, 2.0)),
    );
    for i in 0usize..3 {
        assert(equal_eps(length(r[i]), 1.0f64, 1e-15f64));
        for j in i + 1..3 {
            assert(equal_eps(dot(r[i], r[j]), 0.0f64, 1e-15f64));
        }
    }
    assert(orthonormalize_vec(vec3::new(1.0, 1.0, 0.0), vec3::new(1.0, 0.0, 0.0)) == vec3::new(0.0, 1.0, 0.0));
    assert(orthonormalize_vec(dvec3::new(0.0, 3.0, 4.0), dvec3::new(0.0, 0.0, 1.0)) == dvec3::new(0.0, 1.0, 0.0));
    let parallel = orthonormalize_vec(vec3::new(2.0, 0.0, 0.0), vec3::new(1.0, 0.0, 0.0));
    assert(parallel.x().is_nan());
}

@test
fn polar_euclidean() {
    assert(polar(vec3::new(0.0, 0.0, 1.0)) == vec3::new(0.0, 0.0, 1.0));
    assert(polar(vec3::new(3.0, 0.0, 0.0)) == vec3::new(0.0, 1.0f32.atan2(0.0), 1.0));
    assert(polar(dvec3::new(0.0, 2.0, 0.0)) == dvec3::new(1.0f64.asin(), 0.0, 0.0));
    assert(euclidean(vec2::new(0.0, 0.0)) == vec3::new(0.0, 0.0, 1.0));
    assert(
        euclidean(dvec2::new(0.0, half_pi::<f64>())) == dvec3::new(half_pi::<f64>().sin(), 0.0, half_pi::<f64>().cos()),
    );
    let v = vec3::new(1.0, -2.0, 0.5);
    let back = euclidean(polar(v).xy());
    assert(all(equal_eps(back, normalize(v), 0.000001f32)));
    let z = polar(vec3::splat(0.0));
    assert(z.x().is_nan() && z.y().is_nan() && z.z().is_nan());
}

const LENGTH2: f32 = length2(vec3::new(1.0, 2.0, 3.0));
const ANGLE: f64 = vector_angle(dvec2::new(1.0, 0.0), dvec2::new(-1.0, 0.0));
const PROJ: Vec<f32, 3> = proj(vec3::new(1.0, 2.0, 3.0), vec3::new(0.0, 0.0, 2.0));
const ORTHO: Vec<f32, 3> = orthonormalize_vec(vec3::new(1.0, 1.0, 0.0), vec3::new(1.0, 0.0, 0.0));
const NORMAL3: Vec<f32, 3> = triangle_normal(
    vec3::new(0.0, 0.0, 0.0),
    vec3::new(1.0, 0.0, 0.0),
    vec3::new(0.0, 1.0, 0.0),
);

@test
fn derived_constant_initializers() {
    assert_eq(LENGTH2, 14.0f32);
    assert_eq(ANGLE, (-1.0f64).acos());
    assert(PROJ == vec3::new(0.0, 0.0, 3.0));
    assert(ORTHO == vec3::new(0.0, 1.0, 0.0));
    assert(NORMAL3 == vec3::new(0.0, 0.0, 1.0));
}

// f32 constants of the angle, polar and norm functions over the C library: each equals the same call
// at run time bit for bit (the evaluator calls the f32 function the program links, `acosf` for an f32
// `acos`).
const ANGLE32: f32 = vector_angle(vec2::new(1.0, 0.0), vec2::new(-1.0, 0.0));
const ANGLE32_3: f32 = vector_angle(vec3::new(1.0, 2.0, 3.0), vec3::new(-2.0, 0.5, 1.0));
const ORIENTED: f32 = oriented_angle(vec2::new(0.6, 0.8), vec2::new(-0.8, 0.6));
const ORIENTED_3D: f32 = oriented_angle_3d(vec3::new(1.0, 0.0, 0.0), vec3::new(0.0, 1.0, 0.0), vec3::new(0.0, 0.0, 1.0));
const POLAR: Vec<f32, 3> = polar(vec3::new(1.0, -2.0, 0.5));
const EUCLIDEAN: Vec<f32, 3> = euclidean(vec2::new(0.3, 1.2));
const LX: f32 = lx_norm(vec3::new(1.0, 2.0, 3.0), 3);
const L2: f32 = l2_norm(vec3::new(1.0, 2.0, 3.0));
const L2_BETWEEN: f32 = l2_norm_between(vec3::new(1.0, 2.0, 3.0), vec3::new(-1.0, 0.5, 2.0));

// The identity at run time: the call it feeds cannot fold.
@c.noinline
fn rt<T: Copy>(x: T) T {
    return x;
}

fn same_vec3(a: Vec<f32, 3>, b: Vec<f32, 3>) bool {
    return f32_bits(a.e[0]) == f32_bits(b.e[0]) && f32_bits(a.e[1]) == f32_bits(b.e[1]) && f32_bits(a.e[2]) == f32_bits(
        b.e[2],
    );
}

@test
fn f32_constants_match_run_time() {
    assert_eq(f32_bits(ANGLE32), f32_bits(vector_angle(rt(vec2::new(1.0, 0.0)), vec2::new(-1.0, 0.0))));
    assert_eq(f32_bits(ANGLE32_3), f32_bits(vector_angle(rt(vec3::new(1.0, 2.0, 3.0)), vec3::new(-2.0, 0.5, 1.0))));
    assert_eq(f32_bits(ORIENTED), f32_bits(oriented_angle(rt(vec2::new(0.6, 0.8)), vec2::new(-0.8, 0.6))));
    assert_eq(
        f32_bits(ORIENTED_3D),
        f32_bits(oriented_angle_3d(rt(vec3::new(1.0, 0.0, 0.0)), vec3::new(0.0, 1.0, 0.0), vec3::new(0.0, 0.0, 1.0))),
    );
    assert(same_vec3(POLAR, polar(rt(vec3::new(1.0, -2.0, 0.5)))));
    assert(same_vec3(EUCLIDEAN, euclidean(rt(vec2::new(0.3, 1.2)))));
    assert_eq(f32_bits(LX), f32_bits(lx_norm(rt(vec3::new(1.0, 2.0, 3.0)), 3)));
    assert_eq(f32_bits(L2), f32_bits(l2_norm(rt(vec3::new(1.0, 2.0, 3.0)))));
    assert_eq(f32_bits(L2_BETWEEN), f32_bits(l2_norm_between(rt(vec3::new(1.0, 2.0, 3.0)), vec3::new(-1.0, 0.5, 2.0))));
}
