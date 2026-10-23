// std::math::euler: the one- and two-axis rotations against `rotate`, the derivative matrices against
// the cross-product matrix of the angular velocity, every three-angle sequence against its `rotate`
// product and the extractions, then extract_euler_angle_xyz, yaw_pitch_roll and euler_angle_yxz
// agreement, the orientate builders, f64 instances, the derivative matrices against a finite
// difference, degenerate inputs and constant initializers.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::transform as *;
import std::math::euler as *;

// Every component of `a` strictly within `eps` of `b`.
fn eps_near<T: Float, const N: usize>(a: Vec<T, N>, b: Vec<T, N>, eps: T) bool {
    for i in 0..N {
        if !(a[i] - b[i]).abs().less(eps) {
            return false;
        }
    }
    return true;
}

// Every element of `a` strictly within `eps` of `b`.
fn eps_near_mat<T: Float, const C: usize, const R: usize>(a: Mat<T, C, R>, b: Mat<T, C, R>, eps: T) bool {
    for i in 0..C {
        if !eps_near(a[i], b[i], eps) {
            return false;
        }
    }
    return true;
}

// The 4x4 cross-product matrix of `x`: its upper-left 3x3 block times `v` is `cross(x, v)`.
fn cross4(x: vec3) mat4 {
    let mut r = mat4::zero();
    r[0][1] = x.z();
    r[1][0] = -x.z();
    r[0][2] = -x.y();
    r[2][0] = x.y();
    r[1][2] = x.x();
    r[2][1] = -x.x();
    return r;
}

// The three-angle sequences with their rotation axes.
fn sequences() [(fn(f32, f32, f32) mat4, vec3, vec3, vec3); 10] {
    let x = vec3::new(1.0, 0.0, 0.0);
    let y = vec3::new(0.0, 1.0, 0.0);
    let z = vec3::new(0.0, 0.0, 1.0);
    return [
        (euler_angle_xzx::<f32>, x, z, x),
        (euler_angle_xyx::<f32>, x, y, x),
        (euler_angle_yxy::<f32>, y, x, y),
        (euler_angle_yzy::<f32>, y, z, y),
        (euler_angle_zyz::<f32>, z, y, z),
        (euler_angle_zxz::<f32>, z, x, z),
        (euler_angle_xzy::<f32>, x, z, y),
        (euler_angle_yzx::<f32>, y, z, x),
        (euler_angle_zyx::<f32>, z, y, x),
        (euler_angle_zxy::<f32>, z, x, y),
    ];
}

// The angle triples of the sequence and extraction tests.
fn test_angles() [vec3; 22] {
    let min_angle = -pi::<f32>();
    let max_angle = pi::<f32>();
    let max_delta = max_angle - 0.0000001;
    let min_mid = -pi::<f32>() * 0.5;
    let max_mid = pi::<f32>() * 0.5;
    return [
        vec3::new(1.046, 0.52, -0.785),
        vec3::new(min_angle, min_mid, min_angle),
        vec3::new(min_angle, min_mid, max_angle),
        vec3::new(min_angle, min_mid, max_delta),
        vec3::new(min_angle, max_mid, min_angle),
        vec3::new(min_angle, max_mid, max_angle),
        vec3::new(min_angle, max_mid, max_delta),
        vec3::new(max_angle, min_mid, min_angle),
        vec3::new(max_angle, min_mid, max_angle),
        vec3::new(max_angle, min_mid, max_delta),
        vec3::new(max_delta, min_mid, max_angle),
        vec3::new(max_delta, min_mid, max_delta),
        vec3::new(max_angle, max_mid, min_angle),
        vec3::new(max_delta, max_mid, min_angle),
        vec3::new(max_angle, max_mid, max_angle),
        vec3::new(max_angle, max_mid, max_delta),
        vec3::new(max_delta, max_mid, max_angle),
        vec3::new(max_delta, max_mid, max_delta),
        vec3::new(min_angle, 0.0, min_angle),
        vec3::new(min_angle, 0.0, max_angle),
        vec3::new(max_angle, max_angle, min_angle),
        vec3::new(max_angle, max_angle, max_angle),
    ];
}

const EX: mat4 = euler_angle_x(0.5f32);
const EZYX: dmat4 = euler_angle_zyx(0.1f64, 0.2f64, 0.3f64);
const YPR: mat4 = yaw_pitch_roll(0.3f32, -0.2f32, 1.1f32);
const OR2: dmat2 = orientate2(0.25f64);

@test
fn euler_angle_x_test() {
    let angle = pi::<f32>() * 0.5;
    let x = vec3::new(1.0, 0.0, 0.0);
    for v in [vec4::new(0.0, 1.0, 0.0, 1.0), vec4::new(0.0, 0.0, 1.0, 1.0)] {
        let v1 = rotate(mat4::identity(), angle, x) * v;
        assert(eps_near(v1, euler_angle_x(angle) * v, 0.00001));
        assert(eps_near(v1, euler_angle_xy(angle, 0.0) * v, 0.00001));
        assert(eps_near(v1, euler_angle_yx(0.0, angle) * v, 0.00001));
        assert(eps_near(v1, euler_angle_xz(angle, 0.0) * v, 0.00001));
        assert(eps_near(v1, euler_angle_zx(0.0, angle) * v, 0.00001));
        assert(eps_near(v1, euler_angle_yxz(0.0, angle, 0.0) * v, 0.00001));
    }
}

@test
fn euler_angle_y_test() {
    let angle = pi::<f32>() * 0.5;
    let y = vec3::new(0.0, 1.0, 0.0);
    for v in [vec4::new(1.0, 0.0, 0.0, 1.0), vec4::new(0.0, 0.0, 1.0, 1.0)] {
        let v1 = rotate(mat4::identity(), angle, y) * v;
        assert(eps_near(v1, euler_angle_y(angle) * v, 0.00001));
        assert(eps_near(v1, euler_angle_yx(angle, 0.0) * v, 0.00001));
        assert(eps_near(v1, euler_angle_xy(0.0, angle) * v, 0.00001));
        assert(eps_near(v1, euler_angle_yz(angle, 0.0) * v, 0.00001));
        assert(eps_near(v1, euler_angle_zy(0.0, angle) * v, 0.00001));
        assert(eps_near(v1, euler_angle_yxz(angle, 0.0, 0.0) * v, 0.00001));
    }
}

@test
fn euler_angle_z_test() {
    let angle = pi::<f32>() * 0.5;
    let z = vec3::new(0.0, 0.0, 1.0);
    let v = vec4::new(1.0, 0.0, 0.0, 1.0);
    let v1 = rotate(mat4::identity(), angle, z) * v;
    assert(eps_near(v1, euler_angle_z(angle) * v, 0.00001));
    assert(eps_near(v1, euler_angle_zx(angle, 0.0) * v, 0.00001));
    assert(eps_near(v1, euler_angle_xz(0.0, angle) * v, 0.00001));
    assert(eps_near(v1, euler_angle_zy(angle, 0.0) * v, 0.00001));
    assert(eps_near(v1, euler_angle_yz(0.0, angle) * v, 0.00001));
    assert(eps_near(v1, euler_angle_yxz(0.0, 0.0, angle) * v, 0.00001));
}

@test
fn derived_euler_angles() {
    let angle = pi::<f32>() * 0.75;
    let velocity = pi::<f32>() * 0.27;
    let pairs: [(f32, f32); 9] = [
        (0.0, 0.0),
        (0.0, velocity),
        (0.0, -velocity),
        (angle, 0.0),
        (angle, velocity),
        (angle, -velocity),
        (-angle, 0.0),
        (-angle, velocity),
        (-angle, -velocity),
    ];
    let funcs: [(fn(f32) mat4, fn(f32, f32) mat4, vec3); 3] = [
        (euler_angle_x::<f32>, derived_euler_angle_x::<f32>, vec3::new(1.0, 0.0, 0.0)),
        (euler_angle_y::<f32>, derived_euler_angle_y::<f32>, vec3::new(0.0, 1.0, 0.0)),
        (euler_angle_z::<f32>, derived_euler_angle_z::<f32>, vec3::new(0.0, 0.0, 1.0)),
    ];
    for (rotation, derived, basis) in funcs {
        for (a, w) in pairs {
            let expected = cross4(basis * w);
            assert(eps_near_mat(expected, derived(a, w) * transpose(rotation(a)), 0.00001));
        }
    }
}

@test
fn euler_angle_xy_test() {
    let v = vec4::splat(1.0);
    let (ax, ay) = (pi::<f32>() * 0.5, pi::<f32>() * 0.25);
    let v1 = rotate(mat4::identity(), ax, vec3::new(1.0, 0.0, 0.0)) * rotate(
        mat4::identity(),
        ay,
        vec3::new(0.0, 1.0, 0.0),
    ) * v;
    assert(eps_near(v1, euler_angle_xy(ax, ay) * v, 0.00001));
    assert(eps_near(v1, euler_angle_x(ax) * euler_angle_y(ay) * v, 0.00001));
}

@test
fn euler_angle_yx_test() {
    let v = vec4::splat(1.0);
    let (ax, ay) = (pi::<f32>() * 0.5, pi::<f32>() * 0.25);
    let v1 = rotate(mat4::identity(), ay, vec3::new(0.0, 1.0, 0.0)) * rotate(
        mat4::identity(),
        ax,
        vec3::new(1.0, 0.0, 0.0),
    ) * v;
    assert(eps_near(v1, euler_angle_yx(ay, ax) * v, 0.00001));
    assert(eps_near(v1, euler_angle_y(ay) * euler_angle_x(ax) * v, 0.00001));
}

@test
fn euler_angle_xz_test() {
    let v = vec4::splat(1.0);
    let (ax, az) = (pi::<f32>() * 0.5, pi::<f32>() * 0.25);
    let v1 = rotate(mat4::identity(), ax, vec3::new(1.0, 0.0, 0.0)) * rotate(
        mat4::identity(),
        az,
        vec3::new(0.0, 0.0, 1.0),
    ) * v;
    assert(eps_near(v1, euler_angle_xz(ax, az) * v, 0.00001));
    assert(eps_near(v1, euler_angle_x(ax) * euler_angle_z(az) * v, 0.00001));
}

@test
fn euler_angle_zx_test() {
    let v = vec4::splat(1.0);
    let (ax, az) = (pi::<f32>() * 0.5, pi::<f32>() * 0.25);
    let v1 = rotate(mat4::identity(), az, vec3::new(0.0, 0.0, 1.0)) * rotate(
        mat4::identity(),
        ax,
        vec3::new(1.0, 0.0, 0.0),
    ) * v;
    assert(eps_near(v1, euler_angle_zx(az, ax) * v, 0.00001));
    assert(eps_near(v1, euler_angle_z(az) * euler_angle_x(ax) * v, 0.00001));
}

@test
fn euler_angle_yz_test() {
    let v = vec4::splat(1.0);
    let (ay, az) = (pi::<f32>() * 0.5, pi::<f32>() * 0.25);
    let v1 = rotate(mat4::identity(), ay, vec3::new(0.0, 1.0, 0.0)) * rotate(
        mat4::identity(),
        az,
        vec3::new(0.0, 0.0, 1.0),
    ) * v;
    assert(eps_near(v1, euler_angle_yz(ay, az) * v, 0.00001));
    assert(eps_near(v1, euler_angle_y(ay) * euler_angle_z(az) * v, 0.00001));
}

@test
fn euler_angle_zy_test() {
    let v = vec4::splat(1.0);
    let (ay, az) = (pi::<f32>() * 0.5, pi::<f32>() * 0.25);
    let v1 = rotate(mat4::identity(), az, vec3::new(0.0, 0.0, 1.0)) * rotate(
        mat4::identity(),
        ay,
        vec3::new(0.0, 1.0, 0.0),
    ) * v;
    assert(eps_near(v1, euler_angle_zy(az, ay) * v, 0.00001));
    assert(eps_near(v1, euler_angle_z(az) * euler_angle_y(ay) * v, 0.00001));
}

// The rotation sequence y, x, z from the identity equals euler_angle_yxz; negating the yaw gives a
// different matrix.
@test
fn euler_angle_yxz_test() {
    let (first, second, third) = (1.046f32, 0.52f32, -0.785f32);
    let euler = euler_angle_yxz(first, second, third);
    let inverted_y = euler_angle_y(-1.0 * first) * euler_angle_x(second) * euler_angle_z(third);
    let mut dumb = mat4::identity();
    dumb = rotate(dumb, first, vec3::new(0.0, 1.0, 0.0));
    dumb = rotate(dumb, second, vec3::new(1.0, 0.0, 0.0));
    dumb = rotate(dumb, third, vec3::new(0.0, 0.0, 1.0));
    assert(eps_near_mat(euler, dumb, 0.00001));
    assert(!eps_near_mat(euler, inverted_y, 0.00001));
}

@test
fn euler_angles_test() {
    let v = vec4::splat(1.0);
    for (func, i, j, k) in sequences() {
        for angles in test_angles() {
            let euler = func(angles.x(), angles.y(), angles.z());
            let mut dumb = diagonal4x4(vec4::splat(1.0));
            dumb = rotate(dumb, angles.x(), i);
            dumb = rotate(dumb, angles.y(), j);
            dumb = rotate(dumb, angles.z(), k);
            assert(eps_near(euler * v, dumb * v, 0.00001));
        }
    }
}

@test
fn extracts_euler_angles() {
    let pairs: [(fn(f32, f32, f32) mat4, fn(mat4) (f32, f32, f32)); 11] = [
        (euler_angle_yxz::<f32>, extract_euler_angle_yxz::<f32>),
        (euler_angle_xzx::<f32>, extract_euler_angle_xzx::<f32>),
        (euler_angle_xyx::<f32>, extract_euler_angle_xyx::<f32>),
        (euler_angle_yxy::<f32>, extract_euler_angle_yxy::<f32>),
        (euler_angle_yzy::<f32>, extract_euler_angle_yzy::<f32>),
        (euler_angle_zyz::<f32>, extract_euler_angle_zyz::<f32>),
        (euler_angle_zxz::<f32>, extract_euler_angle_zxz::<f32>),
        (euler_angle_xzy::<f32>, extract_euler_angle_xzy::<f32>),
        (euler_angle_yzx::<f32>, extract_euler_angle_yzx::<f32>),
        (euler_angle_zyx::<f32>, extract_euler_angle_zyx::<f32>),
        (euler_angle_zxy::<f32>, extract_euler_angle_zxy::<f32>),
    ];
    let v = vec4::splat(1.0);
    for (rotation, extract) in pairs {
        for angles in test_angles() {
            let m = rotation(angles.x(), angles.y(), angles.z());
            let (t1, t2, t3) = extract(m);
            assert(eps_near(m * v, rotation(t1, t2, t3) * v, 0.00001));
        }
    }
}

@test
fn extract_euler_angle_xyz_round_trip() {
    let v = vec4::splat(1.0);
    for angles in test_angles() {
        let m = euler_angle_xyz(angles.x(), angles.y(), angles.z());
        let (t1, t2, t3) = extract_euler_angle_xyz(m);
        assert(eps_near(m * v, euler_angle_xyz(t1, t2, t3) * v, 0.00001));
    }
    let (t1, t2, t3) = extract_euler_angle_xyz(euler_angle_xyz(0.1f64, -0.2f64, 0.3f64));
    assert((t1 - 0.1).abs() < 1e-15);
    assert((t2 + 0.2).abs() < 1e-15);
    assert((t3 - 0.3).abs() < 1e-15);
}

// euler_angle_xyz rotates by the negated angles in its formula: it is the product x, y, z of the
// single-axis rotations by the angles as given.
@test
fn euler_angle_xyz_is_the_x_y_z_product() {
    let (a, b, c) = (0.3f64, -1.2f64, 2.5f64);
    let product = euler_angle_x(a) * euler_angle_y(b) * euler_angle_z(c);
    assert(eps_near_mat(euler_angle_xyz(a, b, c), product, 1e-15));
}

@test
fn two_axis_products_match_one_axis_products() {
    let (a, b) = (0.7f64, -2.1f64);
    assert(eps_near_mat(euler_angle_xy(a, b), euler_angle_x(a) * euler_angle_y(b), 1e-15));
    assert(eps_near_mat(euler_angle_yx(a, b), euler_angle_y(a) * euler_angle_x(b), 1e-15));
    assert(euler_angle_xz(a, b) == euler_angle_x(a) * euler_angle_z(b));
    assert(euler_angle_zx(a, b) == euler_angle_z(a) * euler_angle_x(b));
    assert(euler_angle_yz(a, b) == euler_angle_y(a) * euler_angle_z(b));
    assert(euler_angle_zy(a, b) == euler_angle_z(a) * euler_angle_y(b));
}

@test
fn yaw_pitch_roll_is_euler_angle_yxz() {
    let (yaw, pitch, roll) = (0.4f32, -1.3f32, 2.2f32);
    assert(yaw_pitch_roll(yaw, pitch, roll) == euler_angle_yxz(yaw, pitch, roll));
    let r = yaw_pitch_roll(yaw, pitch, roll);
    let p = euler_angle_y(yaw) * euler_angle_x(pitch) * euler_angle_z(roll);
    assert(eps_near_mat(r, p, 0.000001));
}

@test
fn orientate_builders() {
    let a = 0.6f64;
    let o2 = orientate2(a);
    assert(o2 == dmat2::new(a.cos(), a.sin(), -a.sin(), a.cos()));
    let o3 = orientate3(a);
    assert(o3 == dmat3::new(a.cos(), a.sin(), 0.0, -a.sin(), a.cos(), 0.0, 0.0, 0.0, 1.0));
    let angles = dvec3::new(0.1, 0.2, 0.3);
    let o4 = orientate4(angles);
    assert(o4 == yaw_pitch_roll(0.3f64, 0.1f64, 0.2f64));
    assert(orientate3(angles) == dmat3::from_mat(o4));
    assert(orientate3(0.5f32) == mat3::from_mat(euler_angle_z(0.5f32)));
}

// A derivative matrix is the finite-difference quotient of its rotation, scaled by the velocity.
@test
fn derived_matrices_are_derivatives() {
    let (a, w, h) = (0.8f64, 1.5f64, 1e-6f64);
    let funcs: [(fn(f64) dmat4, fn(f64, f64) dmat4); 3] = [
        (euler_angle_x::<f64>, derived_euler_angle_x::<f64>),
        (euler_angle_y::<f64>, derived_euler_angle_y::<f64>),
        (euler_angle_z::<f64>, derived_euler_angle_z::<f64>),
    ];
    for (rotation, derived) in funcs {
        let quotient = (rotation(a + h) - rotation(a - h)) * (w / (2.0 * h));
        assert(eps_near_mat(derived(a, w), quotient, 1e-8));
    }
}

// The extractions of a gimbal-locked matrix (the middle angle at +-pi/2) still give a matrix that
// rotates as the original.
@test
fn extract_gimbal_lock() {
    let v = dvec4::new(0.3, -0.7, 0.2, 1.0);
    let half_pi = pi::<f64>() * 0.5;
    let m = euler_angle_zyx(0.4f64, half_pi, -0.9f64);
    let (t1, t2, t3) = extract_euler_angle_zyx(m);
    assert(eps_near(m * v, euler_angle_zyx(t1, t2, t3) * v, 1e-12));
    let n = euler_angle_xyz(0.4f64, -half_pi, -0.9f64);
    let (s1, s2, s3) = extract_euler_angle_xyz(n);
    assert(eps_near(n * v, euler_angle_xyz(s1, s2, s3) * v, 1e-12));
}

@test
fn nan_angles_give_nan_rotations() {
    let nan = f32::nan();
    let m = euler_angle_x(nan);
    assert(m[1][1].is_nan());
    assert(m[0][0] == 1.0);
    let (t1, t2, t3) = extract_euler_angle_yxz(mat4 { c: [vec4::splat(nan); 4] });
    assert(t1.is_nan());
    assert(t2.is_nan());
    assert(t3.is_nan());
}

// A constant initializer evaluates at compile time; each must give the bits the run-time call gives.
fn runtime_x(a: f32) mat4 {
    return euler_angle_x(a);
}

@test
fn constant_initializers() {
    assert(EX == runtime_x(0.5));
    assert(EZYX == euler_angle_zyx(0.1f64, 0.2f64, 0.3f64));
    assert(YPR == yaw_pitch_roll(0.3f32, -0.2f32, 1.1f32));
    assert(OR2 == orientate2(0.25f64));
}
