// std::math::intersect: hits of the ray-plane, ray-triangle and line-triangle tests, then misses and
// the partial results a test returns on a miss, back faces, both ray-sphere forms, the line-sphere
// test, the closest point on a segment, every vector size and element type, degenerate inputs, and
// constant initializers.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::geometric as *;
import std::math::compare as *;
import std::math::intersect as *;

@test
fn ray_plane_hit() {
    let e = f32::epsilon();
    let plane_origin = vec3::new(0.0, 0.0, 1.0);
    let plane_normal = vec3::new(0.0, 0.0, -1.0);
    let ray_origin = vec3::new(0.0, 0.0, 0.0);
    let ray_dir = vec3::new(0.0, 0.0, 1.0);

    // Inverting the plane normal has no effect.
    let (d_a, hit_a) = intersect_ray_plane(ray_origin, ray_dir, plane_origin, plane_normal);
    assert((d_a - 1.0).abs() <= e);
    assert(hit_a);
    let (d_b, hit_b) = intersect_ray_plane(ray_origin, ray_dir, plane_origin, -1.0f32 * plane_normal);
    assert((d_b - 1.0).abs() <= e);
    assert(hit_b);

    // A plane behind the ray origin is no intersection, with distance 0.
    let (d_c, hit_c) = intersect_ray_plane(ray_origin, ray_dir, -1.0f32 * plane_origin, plane_normal);
    assert_eq(d_c, 0.0f32);
    assert(!hit_c);
}

@test
fn ray_triangle_hit() {
    let e = f32::epsilon();
    let orig = vec3::new(0.0, 0.0, 2.0);
    let dir = vec3::new(0.0, 0.0, -1.0);
    let v0 = vec3::new(0.0, 0.0, 0.0);
    let v1 = vec3::new(-1.0, -1.0, 0.0);
    let v2 = vec3::new(1.0, -1.0, 0.0);
    let (bary, distance, hit) = intersect_ray_triangle(orig, dir, v0, v1, v2);
    assert(all(epsilon_equal(bary, vec2::splat(0.0), e)));
    assert((distance - 2.0).abs() <= e);
    assert(hit);
}

@test
fn line_triangle_hit() {
    let orig = vec3::new(0.0, 0.0, 2.0);
    let dir = vec3::new(0.0, 0.0, -1.0);
    let v0 = vec3::new(0.0, 0.0, 0.0);
    let v1 = vec3::new(-1.0, -1.0, 0.0);
    let v2 = vec3::new(1.0, -1.0, 0.0);
    let (position, hit) = intersect_line_triangle(orig, dir, v0, v1, v2);
    assert(all(epsilon_equal(position, vec3::new(2.0, 0.0, 0.0), f32::epsilon())));
    assert(hit);
}

// A ray within epsilon of parallel misses, and every vector size works.
@test
fn ray_plane_cases() {
    let (d, hit) = intersect_ray_plane(
        vec3::splat(0.0),
        vec3::new(1.0, 0.0, 0.0),
        vec3::new(0.0, 0.0, 1.0),
        vec3::new(0.0, 0.0, 1.0),
    );
    assert(!hit);
    assert_eq(d, 0.0f32);
    let tiny = f32::epsilon();
    let (_, hit_e) = intersect_ray_plane(
        vec2::splat(0.0),
        vec2::new(1.0, tiny),
        vec2::new(0.0, 1.0),
        vec2::new(0.0, 1.0),
    );
    assert(!hit_e);
    let (d2, hit2) = intersect_ray_plane(
        vec2::splat(0.0),
        vec2::new(0.0, 1.0),
        vec2::new(5.0, 3.0),
        vec2::new(0.0, -1.0),
    );
    assert(hit2);
    assert_eq(d2, 3.0f32);
    let (d1, hit1) = intersect_ray_plane(dvec1::new(1.0), dvec1::new(-1.0), dvec1::new(-3.0), dvec1::new(1.0));
    assert(hit1);
    assert_eq(d1, 4.0f64);
    let (d4, hit4) = intersect_ray_plane(
        dvec4::splat(0.0),
        dvec4::new(0.0, 0.0, 0.0, 1.0),
        dvec4::new(0.0, 0.0, 0.0, 2.5),
        dvec4::new(0.0, 0.0, 0.0, 1.0),
    );
    assert(hit4);
    assert_eq(d4, 2.5f64);
    // A plane through the origin is at distance 0, which is not ahead.
    let (_, hit0) = intersect_ray_plane(
        vec3::splat(0.0),
        vec3::new(0.0, 0.0, 1.0),
        vec3::splat(0.0),
        vec3::new(0.0, 0.0, 1.0),
    );
    assert(!hit0);
}

// Both faces hit, at the barycentric position of the hit point; on a miss the results hold the values
// computed before the failed check: u alone, or u and v, unscaled, with distance 0.
@test
fn ray_triangle_cases() {
    let v0 = vec3::new(0.0, 0.0, 0.0);
    let v1 = vec3::new(4.0, 0.0, 0.0);
    let v2 = vec3::new(0.0, 4.0, 0.0);
    let down = vec3::new(0.0, 0.0, -1.0);
    let (bary, distance, hit) = intersect_ray_triangle(vec3::new(1.0, 2.0, 3.0), down, v0, v1, v2);
    assert(hit);
    assert(bary == vec2::new(0.25, 0.5));
    assert_eq(distance, 3.0f32);
    let (bary_b, distance_b, back) = intersect_ray_triangle(vec3::new(1.0, 2.0, 3.0), down, v0, v2, v1);
    assert(back);
    assert(bary_b == vec2::new(0.5, 0.25));
    assert_eq(distance_b, 3.0f32);
    // Behind the origin still hits, with a negative distance.
    let (_, distance_n, behind) = intersect_ray_triangle(vec3::new(1.0, 1.0, -2.0), down, v0, v1, v2);
    assert(behind);
    assert_eq(distance_n, -2.0f32);
    // Outside past v1: u fails first. Outside past the hypotenuse: v fails after u passes.
    let (bary_u, distance_u, miss_u) = intersect_ray_triangle(vec3::new(-1.0, 1.0, 3.0), down, v0, v1, v2);
    assert(!miss_u);
    assert(bary_u == vec2::new(-4.0, 0.0));
    assert_eq(distance_u, 0.0f32);
    let (bary_v, _, miss_v) = intersect_ray_triangle(vec3::new(3.0, 3.0, 3.0), down, v0, v1, v2);
    assert(!miss_v);
    assert(bary_v == vec2::new(12.0, 12.0));
    let (bary_back, _, miss_back) = intersect_ray_triangle(vec3::new(-1.0, 1.0, 3.0), down, v0, v2, v1);
    assert(!miss_back);
    assert(bary_back == vec2::new(-4.0, 4.0));
    // Parallel ray and degenerate triangle: determinant 0, nothing written.
    let (bary_p, distance_p, par) = intersect_ray_triangle(
        vec3::new(1.0, 1.0, 1.0),
        vec3::new(1.0, 0.0, 0.0),
        v0,
        v1,
        v2,
    );
    assert(!par);
    assert(bary_p == vec2::splat(0.0));
    assert_eq(distance_p, 0.0f32);
    let (_, _, flat) = intersect_ray_triangle(vec3::new(1.0, 1.0, 1.0), down, v0, v1, vec3::new(8.0, 0.0, 0.0));
    assert(!flat);
    let (_, _, nan) = intersect_ray_triangle(vec3::splat(1.0), vec3::new(f32::nan(), 0.0, -1.0), v0, v1, v2);
    assert(!nan);
    let (dbary, dd, dhit) = intersect_ray_triangle(
        dvec3::new(1.0, 2.0, 3.0),
        dvec3::new(0.0, 0.0, -1.0),
        dvec3::splat(0.0),
        dvec3::new(4.0, 0.0, 0.0),
        dvec3::new(0.0, 4.0, 0.0),
    );
    assert(dhit);
    assert(dbary == dvec2::new(0.25, 0.5));
    assert_eq(dd, 3.0f64);
}

// The line test has no direction restriction; position is (t, u, v) and a miss keeps the partial u, v.
@test
fn line_triangle_cases() {
    let v0 = vec3::new(0.0, 0.0, 0.0);
    let v1 = vec3::new(4.0, 0.0, 0.0);
    let v2 = vec3::new(0.0, 4.0, 0.0);
    let (p, hit) = intersect_line_triangle(vec3::new(1.0, 2.0, -3.0), vec3::new(0.0, 0.0, -1.0), v0, v1, v2);
    assert(hit);
    assert(p == vec3::new(-3.0, 0.25, 0.5));
    let (p_y, miss_y) = intersect_line_triangle(vec3::new(-1.0, 1.0, 3.0), vec3::new(0.0, 0.0, -1.0), v0, v1, v2);
    assert(!miss_y);
    assert(p_y == vec3::new(0.0, -0.25, 0.0));
    let (p_z, miss_z) = intersect_line_triangle(vec3::new(3.0, 3.0, 3.0), vec3::new(0.0, 0.0, -1.0), v0, v1, v2);
    assert(!miss_z);
    assert(p_z == vec3::new(0.0, 0.75, 0.75));
    let (p_p, par) = intersect_line_triangle(vec3::splat(1.0), vec3::new(1.0, 0.0, 0.0), v0, v1, v2);
    assert(!par);
    assert(p_p == vec3::splat(0.0));
    let (dp, dhit) = intersect_line_triangle(
        dvec3::new(1.0, 2.0, 3.0),
        dvec3::new(0.0, 0.0, -2.0),
        dvec3::splat(0.0),
        dvec3::new(4.0, 0.0, 0.0),
        dvec3::new(0.0, 4.0, 0.0),
    );
    assert(dhit);
    assert(dp == dvec3::new(1.5, 0.25, 0.5));
}

// The distance is to the near crossing ahead, the far one from inside; a sphere behind the start misses
// but still reports its (negative) distance, and a line that passes by reports nothing.
@test
fn ray_sphere_cases() {
    let x = vec3::new(1.0, 0.0, 0.0);
    let (d, hit) = intersect_ray_sphere(vec3::splat(0.0), x, vec3::new(5.0, 0.0, 0.0), 4.0f32);
    assert(hit);
    assert_eq(d, 3.0f32);
    let (d_in, inside) = intersect_ray_sphere(vec3::splat(0.0), x, vec3::new(1.0, 0.0, 0.0), 4.0f32);
    assert(inside);
    assert_eq(d_in, 3.0f32);
    let (d_b, behind) = intersect_ray_sphere(vec3::splat(0.0), x, vec3::new(-5.0, 0.0, 0.0), 4.0f32);
    assert(!behind);
    assert_eq(d_b, -3.0f32);
    let (d_by, by) = intersect_ray_sphere(vec3::splat(0.0), x, vec3::new(5.0, 3.0, 0.0), 4.0f32);
    assert(!by);
    assert_eq(d_by, 0.0f32);
    let (d_t, tangent) = intersect_ray_sphere(vec2::splat(0.0), vec2::new(1.0, 0.0), vec2::new(5.0, 2.0), 4.0f32);
    assert(tangent);
    assert_eq(d_t, 5.0f32);
    let (d4, h4) = intersect_ray_sphere(
        dvec4::splat(0.0),
        dvec4::new(0.0, 0.0, 0.0, 1.0),
        dvec4::new(0.0, 0.0, 0.0, 10.0),
        1.0f64,
    );
    assert(h4);
    assert_eq(d4, 9.0f64);
    let (d1, h1) = intersect_ray_sphere(dvec1::new(0.0), dvec1::new(-1.0), dvec1::new(-3.0), 1.0f64);
    assert(h1);
    assert_eq(d1, 2.0f64);
    let (_, nan) = intersect_ray_sphere(vec3::splat(0.0), x, vec3::new(5.0, 0.0, 0.0), f32::nan());
    assert(!nan);
}

@test
fn ray_sphere_point_cases() {
    let (p, n, hit) = intersect_ray_sphere_point(
        vec3::splat(0.0),
        vec3::new(1.0, 0.0, 0.0),
        vec3::new(5.0, 0.0, 0.0),
        2.0f32,
    );
    assert(hit);
    assert(p == vec3::new(3.0, 0.0, 0.0));
    assert(n == vec3::new(-1.0, 0.0, 0.0));
    let (p_m, n_m, miss) = intersect_ray_sphere_point(
        vec3::splat(0.0),
        vec3::new(1.0, 0.0, 0.0),
        vec3::new(-5.0, 0.0, 0.0),
        2.0f32,
    );
    assert(!miss);
    assert(p_m == vec3::splat(0.0));
    assert(n_m == vec3::splat(0.0));
    let (dp, dn, dhit) = intersect_ray_sphere_point(
        dvec2::new(0.0, -10.0),
        dvec2::new(0.0, 1.0),
        dvec2::splat(0.0),
        4.0f64,
    );
    assert(dhit);
    assert(dp == dvec2::new(0.0, -4.0));
    assert(dn == dvec2::new(0.0, -1.0));
    // A negative radius squares to the same sphere and flips the normal.
    let (_, n_neg, neg) = intersect_ray_sphere_point(
        vec3::splat(0.0),
        vec3::new(1.0, 0.0, 0.0),
        vec3::new(5.0, 0.0, 0.0),
        -2.0f32,
    );
    assert(neg);
    assert(n_neg == vec3::new(1.0, 0.0, 0.0));
}

// Position 1 is the near crossing when it is ahead of point0, else the far one; the line extends both
// ways, so a sphere behind point0 still hits.
@test
fn line_sphere_cases() {
    let (p1, n1, p2, n2, hit) = intersect_line_sphere(
        vec3::splat(0.0),
        vec3::new(2.0, 0.0, 0.0),
        vec3::new(5.0, 0.0, 0.0),
        2.0f32,
    );
    assert(hit);
    assert(p1 == vec3::new(3.0, 0.0, 0.0));
    assert(n1 == vec3::new(-1.0, 0.0, 0.0));
    assert(p2 == vec3::new(7.0, 0.0, 0.0));
    assert(n2 == vec3::new(1.0, 0.0, 0.0));
    let (q1, _, q2, _, inside) = intersect_line_sphere(
        vec3::splat(0.0),
        vec3::new(0.0, 1.0, 0.0),
        vec3::splat(0.0),
        3.0f32,
    );
    assert(inside);
    assert(q1 == vec3::new(0.0, 3.0, 0.0));
    assert(q2 == vec3::new(0.0, -3.0, 0.0));
    let (r1, _, r2, _, behind) = intersect_line_sphere(
        dvec2::splat(0.0),
        dvec2::new(1.0, 0.0),
        dvec2::new(-5.0, 0.0),
        1.0f64,
    );
    assert(behind);
    assert(r1 == dvec2::new(-4.0, 0.0));
    assert(r2 == dvec2::new(-6.0, 0.0));
    let (m1, m2, m3, m4, miss) = intersect_line_sphere(
        vec4::splat(0.0),
        vec4::new(1.0, 0.0, 0.0, 0.0),
        vec4::new(0.0, 5.0, 0.0, 0.0),
        1.0f32,
    );
    assert(!miss);
    assert(m1 == vec4::splat(0.0) && m2 == vec4::splat(0.0) && m3 == vec4::splat(0.0) && m4 == vec4::splat(0.0));
    // point0 == point1 gives a NaN direction: no comparison holds, so the test does not miss.
    let (s1, _, _, _, same) = intersect_line_sphere(vec3::splat(1.0), vec3::splat(1.0), vec3::splat(0.0), 1.0f32);
    assert(same);
    assert(s1.x().is_nan());
}

// The closest point of the segment: the projection inside it, an end point past either end.
@test
fn closest_point_on_line_cases() {
    let a = vec3::new(0.0, 0.0, 0.0);
    let b = vec3::new(4.0, 0.0, 0.0);
    assert(closest_point_on_line(vec3::new(1.0, 2.0, 3.0), a, b) == vec3::new(1.0, 0.0, 0.0));
    assert(closest_point_on_line(vec3::new(-1.0, 2.0, 3.0), a, b) == a);
    assert(closest_point_on_line(vec3::new(0.0, 2.0, 3.0), a, b) == a);
    assert(closest_point_on_line(vec3::new(9.0, 2.0, 3.0), a, b) == b);
    assert(closest_point_on_line(vec3::new(4.0, -1.0, 0.0), a, b) == b);
    assert(closest_point_on_line(vec2::new(1.0, 1.0), vec2::new(0.0, 0.0), vec2::new(4.0, 0.0)) == vec2::new(1.0, 0.0));
    assert(
        closest_point_on_line(dvec2::new(3.0, -1.0), dvec2::new(0.0, 0.0), dvec2::new(0.0, 8.0)) == dvec2::new(0.0, 0.0),
    );
    assert(
        closest_point_on_line(dvec3::new(1.0, 5.0, 1.0), dvec3::new(0.0, 0.0, 0.0), dvec3::new(0.0, 8.0, 0.0)) == dvec3::new(
            0.0,
            5.0,
            0.0,
        ),
    );
    let degenerate = closest_point_on_line(vec3::splat(1.0), a, a);
    assert(degenerate.x().is_nan());
}

// A constant cannot bind several results; these evaluate the multi-result functions at compile time.
fn plane_distance() f32 {
    let (d, hit) = intersect_ray_plane(
        vec3::splat(0.0),
        vec3::new(0.0, 0.0, 1.0),
        vec3::new(0.0, 0.0, 2.0),
        vec3::new(0.0, 0.0, 1.0),
    );
    assert(hit);
    return d;
}

fn triangle_distance() f32 {
    let (_, d, hit) = intersect_ray_triangle(
        vec3::new(1.0, 2.0, 3.0),
        vec3::new(0.0, 0.0, -1.0),
        vec3::splat(0.0),
        vec3::new(4.0, 0.0, 0.0),
        vec3::new(0.0, 4.0, 0.0),
    );
    assert(hit);
    return d;
}

const PLANE: f32 = plane_distance();
const TRIANGLE: f32 = triangle_distance();
const CLOSEST: Vec<f32, 3> = closest_point_on_line(vec3::new(1.0, 2.0, 3.0), vec3::splat(0.0), vec3::new(4.0, 0.0, 0.0));
const CLOSEST_END: Vec<f64, 2> = closest_point_on_line(dvec2::new(3.0, -1.0), dvec2::splat(0.0), dvec2::new(0.0, 8.0));

@test
fn constant_initializers() {
    assert_eq(PLANE, 2.0f32);
    assert_eq(TRIANGLE, 3.0f32);
    assert(CLOSEST == vec3::new(1.0, 0.0, 0.0));
    assert(CLOSEST_END == dvec2::splat(0.0));
}
