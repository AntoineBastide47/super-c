// std::math::quat: construction, size and storage of the quaternion types, their operators, component
// access, conversions and constant initializers; then the common, exponential, geometric, relational,
// transform and trigonometric functions, angle-axis, Euler angles, slerp with spins, products and the
// rotation and interpolation functions (rotation, short_mix, fast_mix, squad); then the edge cases:
// NaN, signed zeros, degenerate inputs, index and interpolant traps.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::quat as *;
import std::math::common as *;
import std::math::elementary as *;
import std::math::geometric as *;
import std::math::compare as *;
import std::math::transform as *;

// Every component of `a` within `eps` of `b`.
fn near<T: Float, const N: usize>(a: Vec<T, N>, b: Vec<T, N>, eps: T) bool {
    for i in 0..N {
        if !(a[i] - b[i]).abs().less_equal(eps) {
            return false;
        }
    }
    return true;
}

// x, y, z and w of `p` each within `eps` of `q`.
fn near_quat<T: Float>(p: Quat<T>, q: Quat<T>, eps: T) bool {
    for i in 0..vec4::LEN {
        if !(p[i] - q[i]).abs().less_equal(eps) {
            return false;
        }
    }
    return true;
}

// Two quaternion views of one storage: a value written through `f` reads back through `i`.
union QuatPack {
    pub f: quat,
    pub i: quat,
}

const Q2: quat = Quat::<f32>::identity() * 2.0;
const QP: quat = Quat::<f32>::new(1.0, 2.0, 3.0, 4.0) * Quat::<f32>::new(5.0, 6.0, 7.0, 8.0);
const QN: quat = -Quat::<f32>::new(1.0, 0.0, -2.0, 3.0);
const QV: vec3 = Quat::<f32>::identity() * vec3::new(1.0, 2.0, 3.0);
const QLEN: f32 = length(Quat::<f32>::new(0.0, 3.0, 0.0, 4.0));
const VLEN: f32 = length(vec3::new(2.0, 3.0, 6.0));

// Construction and size

@test
fn quat_ctr() {
    let a = Quat::<f32>::new(0.0, 1.0, 2.0, 3.0);
    let b: [quat; 2] = [a, quat { x: 1.0, y: 2.0, z: 3.0, w: 0.0 }];
    assert(b[1] == a);
    assert(a.w == 0.0 && a.x == 1.0 && a.y == 2.0 && a.z == 3.0);
    let d = dquat::new(0.0, 1.0, 2.0, 3.0);
    let e: [dquat; 2] = [d, f64quat::new(0.0, 1.0, 2.0, 3.0)];
    assert(e[1] == d);
    assert(fquat::new(1.0, 2.0, 3.0, 4.0) == f32quat::new(1.0, 2.0, 3.0, 4.0));
}

@test
fn quat_two_axis_ctr() {
    let q1 = Quat::<f32>::from_vectors(vec3::new(1.0, 0.0, 0.0), vec3::new(0.0, 1.0, 0.0));
    let v1 = q1 * vec3::new(1.0, 0.0, 0.0);
    assert(near(v1, vec3::new(0.0, 1.0, 0.0), 0.0001));

    let q2 = q1 * q1;
    let v2 = q2 * vec3::new(1.0, 0.0, 0.0);
    assert(near(v2, vec3::new(-1.0, 0.0, 0.0), 0.0001));

    let q3 = Quat::<f32>::from_vectors(vec3::new(1.0, 0.0, 0.0), vec3::new(-1.0, 0.0, 0.0));
    let v3 = q3 * vec3::new(1.0, 0.0, 0.0);
    assert(near(v3, vec3::new(-1.0, 0.0, 0.0), 0.0001));

    let q4 = Quat::<f32>::from_vectors(vec3::new(0.0, 1.0, 0.0), vec3::new(0.0, -1.0, 0.0));
    let v4 = q4 * vec3::new(0.0, 1.0, 0.0);
    assert(near(v4, vec3::new(0.0, -1.0, 0.0), 0.0001));

    let q5 = Quat::<f32>::from_vectors(vec3::new(0.0, 0.0, 1.0), vec3::new(0.0, 0.0, -1.0));
    let v5 = q5 * vec3::new(0.0, 0.0, 1.0);
    assert(near(v5, vec3::new(0.0, 0.0, -1.0), 0.0001));
}

@test
fn quat_size() {
    assert_eq(sizeof(quat), 16);
    assert_eq(sizeof(dquat), 32);
}

// Union storage

@test
fn quat_ctor_bits() {
    let eps = f32::epsilon();
    let a = QuatPack { f: Quat::<f32>::new(0.0, 0.0, 0.0, 0.0) };
    assert(near_quat(a.i, Quat::<f32>::new(0.0, 0.0, 0.0, 0.0), eps));
    let b = QuatPack { f: Quat::<f32>::new(1.0, 1.0, 1.0, 1.0) };
    assert(near_quat(b.i, Quat::<f32>::new(1.0, 1.0, 1.0, 1.0), eps));
}

// The operators, access and conversions of the type.

@test
fn quat_constructors() {
    let i = Quat::<f32>::identity();
    assert(i == Quat::<f32>::new(1.0, 0.0, 0.0, 0.0));
    let q = Quat::<f32>::from_scalar_vec(4.0, vec3::new(1.0, 2.0, 3.0));
    assert(q == Quat::<f32>::new(4.0, 1.0, 2.0, 3.0));
    assert(q.w == 4.0 && q.x == 1.0 && q.y == 2.0 && q.z == 3.0);
    assert(dquat::identity().w == 1.0);
}

@test
fn quat_arithmetic() {
    let p = Quat::<f32>::new(1.0, 2.0, 3.0, 4.0);
    let q = Quat::<f32>::new(5.0, 6.0, 7.0, 8.0);
    assert(p + q == Quat::<f32>::new(6.0, 8.0, 10.0, 12.0));
    assert(q - p == Quat::<f32>::new(4.0, 4.0, 4.0, 4.0));
    assert(-p == Quat::<f32>::new(-1.0, -2.0, -3.0, -4.0));
    assert(p * q == Quat::<f32>::new(-60.0, 12.0, 30.0, 24.0));
    assert(q * p == Quat::<f32>::new(-60.0, 20.0, 14.0, 32.0));
    assert(p * 2.0 == Quat::<f32>::new(2.0, 4.0, 6.0, 8.0));
    assert(2.0 * p == Quat::<f32>::new(2.0, 4.0, 6.0, 8.0));
    assert(p / 2.0 == Quat::<f32>::new(0.5, 1.0, 1.5, 2.0));
    let mut r = p;
    r += q;
    assert(r == p + q);
    r -= q;
    assert(r == p);
    r *= q;
    assert(r == p * q);
    let d = dquat::new(1.0, 2.0, 3.0, 4.0) * dquat::new(5.0, 6.0, 7.0, 8.0);
    assert(d == dquat::new(-60.0, 12.0, 30.0, 24.0));
}

@test
fn quat_neg_zero_sign() {
    let n = -Quat::<f32>::new(0.0, 0.0, 0.0, 0.0);
    for i in 0..vec4::LEN {
        assert_eq(n[i].to_bits(), 0x80000000);
    }
}

@test
fn quat_rotates_vectors() {
    let eps: f32 = 0.0001;
    let h: f32 = 0.5;
    let s = h.sqrt();
    let q = Quat::<f32>::new(s, 0.0, 0.0, s);
    let i = Quat::<f32>::identity();
    assert(i * vec3::new(1.0, 2.0, 3.0) == vec3::new(1.0, 2.0, 3.0));
    assert(near(q * vec3::new(1.0, 0.0, 0.0), vec3::new(0.0, 1.0, 0.0), eps));
    assert(near(vec3::new(0.0, 1.0, 0.0) * q, vec3::new(1.0, 0.0, 0.0), eps));
    assert(near(q * vec4::new(1.0, 0.0, 0.0, 5.0), vec4::new(0.0, 1.0, 0.0, 5.0), eps));
    assert(near(vec4::new(0.0, 1.0, 0.0, 5.0) * q, vec4::new(1.0, 0.0, 0.0, 5.0), eps));
    let v = vec3::new(0.25, -1.5, 2.0);
    assert(near(q * v * q, v, eps));
    let dq = q.cast::<f64>();
    assert(near(dq * dvec3::new(0.0, 0.0, 1.0), dvec3::new(0.0, 0.0, 1.0), 0.000001));
}

@test
fn quat_inverse() {
    let p = Quat::<f32>::new(1.0, 2.0, 3.0, 4.0);
    assert(near_quat(p * inverse(p), Quat::<f32>::identity(), 0.0001));
    assert(inverse(Quat::<f32>::new(2.0, 0.0, 0.0, 0.0)) == Quat::<f32>::new(0.5, 0.0, 0.0, 0.0));
    assert(inverse(dquat::new(0.0, 0.0, 2.0, 0.0)) == dquat::new(0.0, 0.0, -0.5, 0.0));
}

@test
fn quat_equality_is_ieee() {
    let p = Quat::<f32>::new(1.0, 0.0, 2.0, 3.0);
    assert(p == Quat::<f32>::new(1.0, -0.0, 2.0, 3.0));
    assert(p != Quat::<f32>::new(1.0, 0.0, 2.0, 4.0));
    let n = Quat::<f32>::new(f32::nan(), 0.0, 0.0, 0.0);
    assert(n != n);
    assert(!(n == n));
}

@test
fn quat_component_cast() {
    let d = dquat::new(1.5, -2.25, 0.125, 4.0);
    assert(d.cast::<f32>() == Quat::<f32>::new(1.5, -2.25, 0.125, 4.0));
    assert(Quat::<f32>::new(1.5, -2.25, 0.125, 4.0).cast::<f64>() == d);
}

@test
fn quat_index() {
    let mut q = Quat::<f32>::new(5.0, 6.0, 7.0, 8.0);
    assert(q[0] == 6.0);
    assert(q[1] == 7.0);
    assert(q[2] == 8.0);
    assert(q[3] == 5.0);
    q[3] = 9.0;
    q[0] = -1.0;
    assert(q == Quat::<f32>::new(9.0, -1.0, 7.0, 8.0));
    let s = q.index_range(1..=3);
    assert_eq(s.len(), 3);
    assert(s[2] == 9.0);
    let w = q.index_range_mut(2..4);
    w[0] = 0.5;
    assert(q.z == 0.5);
}

@test(should_panic)
fn quat_index_out_of_range_traps() {
    let q = Quat::<f32>::identity();
    let i = vec4::LEN;
    let _ = q[i];
}

@test(should_panic)
fn quat_index_mut_out_of_range_traps() {
    let mut q = dquat::identity();
    let i = vec4::LEN;
    q[i] = 1.0;
}

@test(should_panic)
fn quat_index_range_out_of_range_traps() {
    let q = Quat::<f32>::identity();
    let s = q.index_range(2..5);
    assert_eq(s.len(), 3);
}

@test
fn quat_const_initializers() {
    assert(Q2 == Quat::<f32>::new(2.0, 0.0, 0.0, 0.0));
    assert(QP == Quat::<f32>::new(-60.0, 12.0, 30.0, 24.0));
    assert(QN == Quat::<f32>::new(-1.0, -0.0, 2.0, -3.0));
    assert_eq(QN.x.to_bits(), 0x80000000);
    assert(QV == vec3::new(1.0, 2.0, 3.0));
    assert(QLEN == 5.0);
    assert(VLEN == 7.0);
}

// The rotation that turns x onto y, and the one that turns x onto itself.
fn x_to_y<T: Float>() Quat<T> {
    return Quat::<T>::from_vectors(
        Vec::<T, 3>::new(T::one(), T::zero(), T::zero()),
        Vec::<T, 3>::new(T::zero(), T::one(), T::zero()),
    );
}

fn x_to_x() quat {
    return Quat::<f32>::from_vectors(vec3::new(1.0, 0.0, 0.0), vec3::new(1.0, 0.0, 0.0));
}

// Common functions

@test
fn quat_conjugate() {
    let a = x_to_y::<f32>();
    let c = conjugate(a);
    assert(any(not_equal_eps(a, c, f32::epsilon())));
    let b = conjugate(c);
    assert(all(equal_eps(a, b, f32::epsilon())));
}

@test
fn quat_mix() {
    let q1 = x_to_x();
    let q2 = x_to_y::<f32>();
    assert(equal_eps(degrees(angle(mix(q1, q2, 0.5f32))), 45.0f32, 0.001f32));
    assert(equal_eps(degrees(angle(mix(q2, q1, 0.5f32))), 45.0f32, 0.001f32));
    assert(equal_eps(degrees(angle(slerp(q1, q2, 0.5f32))), 45.0f32, 0.001f32));
    assert(equal_eps(degrees(angle(slerp(q2, q1, 0.5f32))), 45.0f32, 0.001f32));
}

// Exponential functions

fn check_log<T: Float>() {
    let eps = T::from_f32(0.001);
    let q = x_to_y::<T>();
    let p = log(q);
    assert(any(not_equal_eps(q, p, eps)));
    let r = exp(p);
    assert(all(equal_eps(q, r, eps)));
}

fn check_pow<T: Float>() {
    let eps = T::from_f32(0.001);
    let q = x_to_y::<T>();
    assert(all(equal_eps(q, pow(q, T::from_f32(1.0)), eps)));
    let p = pow(q, T::from_f32(2.0));
    assert(all(equal_eps(p, q * q, eps)));
    assert(all(equal_eps(q, sqrt(p), eps)));
}

@test
fn quat_log() {
    check_log::<f32>();
    check_log::<f64>();
}

@test
fn quat_pow() {
    check_pow::<f32>();
    check_pow::<f64>();
}

// Geometric functions

@test
fn quat_length() {
    let eps: f32 = 0.001;
    assert(equal_eps(length(Quat::<f32>::new(1.0, 0.0, 0.0, 0.0)), 1.0f32, eps));
    assert(equal_eps(length(Quat::<f32>::from_scalar_vec(1.0, vec3::splat(0.0))), 1.0f32, eps));
    assert(equal_eps(length(x_to_y::<f32>()), 1.0f32, eps));
    // `LEN` and `len()` give the component count, not the length.
    assert_eq(Quat::<f32>::LEN, 4);
    assert_eq(Quat::<f64>::identity().len(), 4);
}

@test
fn quat_normalize() {
    let eps: f32 = 0.001;
    let a = Quat::<f32>::new(1.0, 0.0, 0.0, 0.0);
    assert(all(equal_eps(a, normalize(a), eps)));
    let b = Quat::<f32>::from_scalar_vec(1.0, vec3::splat(0.0));
    assert(all(equal_eps(b, normalize(b), eps)));
}

@test
fn quat_dot() {
    let a = Quat::<f32>::new(1.0, 0.0, 0.0, 0.0);
    let b = Quat::<f32>::new(1.0, 0.0, 0.0, 0.0);
    assert(equal_eps(dot(a, b), 1.0f32, 0.001f32));
}

// Relational functions

@test
fn quat_equal() {
    let q = Quat::<f32>::new(1.0, 0.0, 0.0, 0.0);
    let p = Quat::<f32>::new(1.0, 0.0, 0.0, 0.0);
    assert(all(equal_eps(q, p, f32::epsilon())));
}

@test
fn quat_not_equal() {
    let q = Quat::<f32>::new(1.0, 0.0, 0.0, 0.0);
    let p = Quat::<f32>::new(1.0, 0.0, 0.0, 0.0);
    assert(!any(not_equal_eps(q, p, f32::epsilon())));
}

// Transform functions

@test
fn quat_look_at_matches_matrix() {
    let eye = vec3::splat(0.0);
    let center = vec3::new(1.1, -2.0, 3.1416);
    let up = vec3::new(-0.17, 7.23, -1.744);
    let eps = f32::epsilon();

    let q = quat_look_at(normalize(center - eye), up);
    let m = conjugate(quat_cast(look_at(eye, center, up)));
    assert(!(abs(length(q) - 1.0f32) > eps));
    assert(!(min(length(q + -m), length(q + m)) > eps));

    let q_lh = quat_look_at_lh(normalize(center - eye), up);
    let m_lh = conjugate(quat_cast(look_at_lh(eye, center, up)));
    assert(!(abs(length(q_lh) - 1.0f32) > eps));
    assert(!(min(length(q_lh - m_lh), length(q_lh + m_lh)) > eps));

    let q_rh = quat_look_at_rh(normalize(center - eye), up);
    let m_rh = conjugate(quat_cast(look_at_rh(eye, center, up)));
    assert(!(abs(length(q_rh) - 1.0f32) > eps));
    assert(!(min(length(q_rh - m_rh), length(q_rh + m_rh)) > eps));
}

// Trigonometric functions

@test
fn quat_trigonometric_angle() {
    let eps: f32 = 0.001;
    assert(equal_eps(degrees(angle(x_to_y::<f32>())), 90.0f32, eps));
    let q = Quat::<f32>::from_vectors(vec3::new(0.0, 1.0, 0.0), vec3::new(1.0, 0.0, 0.0));
    assert(equal_eps(degrees(angle(q)), 90.0f32, eps));
    let r = angle_axis(two_pi::<f32>() - 1.0, vec3::new(1.0, 0.0, 0.0));
    assert(!equal_eps(angle(r), 1.0f32, eps));
}

// Angle-axis, Euler angles, slerp and products

@test
fn quat_angle() {
    let axes: [vec3; 3] = [
        vec3::new(0.0, 0.0, 1.0),
        normalize(vec3::new(0.0, 1.0, 1.0)),
        normalize(vec3::new(1.0, 2.0, 3.0)),
    ];
    for a in axes {
        let n = normalize(angle_axis(pi::<f32>() * 0.25, a));
        assert(equal_eps(length(n), 1.0f32, 0.01f32));
        assert(equal_eps(angle(n), pi::<f32>() * 0.25, 0.01f32));
    }
}

@test
fn quat_angle_axis() {
    let a = angle_axis(0.0f32, vec3::new(0.0, 0.0, 1.0));
    let b = angle_axis(pi::<f32>() * 0.5, vec3::new(0.0, 0.0, 1.0));
    let c = mix(a, b, 0.5f32);
    let d = angle_axis(pi::<f32>() * 0.25, vec3::new(0.0, 0.0, 1.0));
    assert(equal_eps(c.x, d.x, 0.01f32));
    assert(equal_eps(c.y, d.y, 0.01f32));
    assert(equal_eps(c.z, d.z, 0.01f32));
    assert(equal_eps(c.w, d.w, 0.01f32));
}

@test
fn quat_normalize_angle_axis() {
    let axes: [vec3; 3] = [vec3::new(0.0, 0.0, 1.0), vec3::new(0.0, 0.0, 2.0), vec3::new(1.0, 2.0, 3.0)];
    for a in axes {
        let n = normalize(angle_axis(pi::<f32>() * 0.25, a));
        assert(equal_eps(length(n), 1.0f32, 0.000001f32));
    }
}

@test
fn quat_euler() {
    let q = Quat::<f32>::new(1.0, 0.0, 0.0, 1.0);
    let angles = euler_angles(q);
    assert(all(equal_eps(angles, vec3::new(pitch(q), yaw(q), roll(q)), 0.000001f32)));
    let d = dquat::new(1.0, 0.0, 0.0, 1.0);
    let dangles = euler_angles(d);
    assert(all(equal_eps(dangles, dvec3::new(pitch(d), yaw(d), roll(d)), 0.000001f64)));
}

@test
fn quat_slerp() {
    let eps: f32 = 0.0001;
    let sqrt2 = 2.0f32.sqrt() / 2.0;
    let id = Quat::<f32>::new(1.0, 0.0, 0.0, 0.0);
    let y90 = Quat::<f32>::new(sqrt2, 0.0, sqrt2, 0.0);

    assert(all(equal_eps(id, slerp(id, y90, 0.0f32), eps)));
    assert(all(equal_eps(y90, slerp(id, y90, 1.0f32), eps)));
    let y45 = slerp(id, y90, 0.5f32);
    assert(all(equal_eps(y45, Quat::<f32>::new(0.924, 0.0, 0.383, 0.0), 0.01f32)));

    let ym45 = slerp(y90, id, 0.5f32);
    let y45_3 = slerp(id, -y90, 0.5f32);
    assert(equal_eps(angle(y45_3), pi::<f32>() * 0.25, eps));
    assert(all(equal_eps(ym45, y45_3, eps)));

    let y45_4 = slerp(-y90, id, 0.5f32);
    assert(all(equal_eps(ym45, -y45_4, eps)));

    assert(all(equal_eps(y90, slerp(y90, y90, 0.5f32), eps)));

    let xz90 = slerp(id, -y90, 0.5f32);
    assert(equal_eps(angle(xz90), pi::<f32>() * 0.25, eps));

    let almost_id = slerp(id, angle_axis(0.1f32, vec3::new(0.0, 1.0, 0.0)), 0.5f32);
    assert(all(equal_eps(almost_id, Quat::<f32>::new(1.0, 0.0, 0.0, 0.0), 0.1f32)));

    let a = Quat::<f32>::new(-1.0, 0.0, 0.0, 0.0);
    let result = slerp(a, id, 0.5f32);
    assert(equal_eps(pow(dot(id, result), 2.0f32), 1.0f32, 0.01f32));
}

@test
fn quat_slerp_spins() {
    let eps: f32 = 0.0001;
    let sqrt2 = 2.0f32.sqrt() / 2.0;
    let id = Quat::<f32>::new(1.0, 0.0, 0.0, 0.0);
    let y90 = Quat::<f32>::new(sqrt2, 0.0, sqrt2, 0.0);
    let y180 = Quat::<f32>::new(0.0, 0.0, 1.0, 0.0);

    assert(all(equal_eps(id, slerp_spin(id, id, 1.0f32, 1), eps)));
    assert(all(equal_eps(id, slerp_spin(id, id, 1.0f32, 2), eps)));
    assert(all(equal_eps(y90, -slerp_spin(id, y90, 1.0f32, 1), eps)));
    assert(all(equal_eps(id, slerp_spin(id, y90, 8.0f32 / 9.0, 2), eps)));
    assert(all(equal_eps(y90, slerp_spin(id, y90, 0.2f32, 1), eps)));

    let ym45_2 = slerp_spin(y90, id, 0.9f32, 1);
    let ym45_3 = slerp(y90, id, 0.5f32);
    assert(all(equal_eps(-ym45_2, ym45_3, eps)));

    let y45_3 = slerp_spin(id, -y90, 0.5f32, 0);
    assert(equal_eps(angle(y45_3), pi::<f32>() * 0.25, eps));
    assert(all(equal_eps(ym45_3, y45_3, eps)));

    let y45_4 = slerp_spin(-y90, id, 0.5f32, 0);
    assert(all(equal_eps(ym45_2, y45_4, eps)));

    assert(all(equal_eps(y90, slerp_spin(y90, y90, 0.5f32, 2), eps)));

    let xz90 = slerp_spin(id, -y90, 0.5f32, 1);
    assert(equal_eps(angle(xz90), pi::<f32>() * 1.25, eps));

    let neg90 = slerp_spin(id, y90, 2.0f32 / 3.0, -1);
    assert(all(equal_eps(y180, -neg90, eps)));
}

@test
fn quat_mul_vec() {
    let q = angle_axis(pi::<f32>() * 0.5, vec3::new(0.0, 0.0, 1.0));
    let v = vec3::new(1.0, 0.0, 0.0);
    let u = q * v;
    let w = u * q;
    assert(all(equal_eps(v, w, 0.01f32)));
}

@test
fn quat_mul() {
    let temp1 = normalize(Quat::<f32>::from_scalar_vec(1.0, vec3::new(0.0, 1.0, 0.0)));
    let temp2 = normalize(Quat::<f32>::from_scalar_vec(0.5, vec3::new(1.0, 0.0, 0.0)));

    let transformed0 = temp1 * vec3::new(0.0, 1.0, 0.0) * inverse(temp1);
    let temp4 = temp2 * transformed0 * inverse(temp2);
    assert(all(equal_eps(temp4, vec3::new(0.0, -0.28, -0.96), 0.01f32)));

    let temp5 = normalize(temp1 * temp2);
    let temp6 = temp5 * vec3::new(0.0, 1.0, 0.0) * inverse(temp5);
    assert(all(equal_eps(temp6, vec3::new(-0.48, 0.36, -0.8), 0.01f32)));

    let mut temp7 = Quat::<f32>::from_scalar_vec(1.0, vec3::new(0.0, 1.0, 0.0));
    temp7 *= temp5;
    temp7 *= inverse(temp5);
    assert(!any(not_equal_eps(temp7, Quat::<f32>::from_scalar_vec(1.0, vec3::new(0.0, 1.0, 0.0)), f32::epsilon())));
}

@test
fn quat_and_mat_identity() {
    let q = Quat::<f32>::identity();
    assert(all(equal_eps(q, Quat::<f32>::new(1.0, 0.0, 0.0, 0.0), 0.0001f32)));
    assert(!any(not_equal_eps(q, Quat::<f32>::new(1.0, 0.0, 0.0, 0.0), 0.0001f32)));
    let m = mat4::identity();
    let n = mat4::diagonal(1.0);
    assert(all(equal_eps(m, n, 0.0001f32)));
}

// The branches and conformances the tests above do not reach.

@test
fn quat_exact_relational() {
    let p = Quat::<f32>::new(1.0, 0.0, 2.0, f32::nan());
    let q = Quat::<f32>::new(1.0, -0.0, 3.0, f32::nan());
    assert(equal(p, q) == bvec4::new(true, false, false, true));
    assert(not_equal(p, q) == bvec4::new(false, true, true, false));
    let d = dquat::new(1.0, 2.0, 3.0, 4.0);
    assert(all(equal(d, d)));
}

@test
fn quat_ordered() {
    let p = Quat::<f32>::new(4.0, 1.0, 2.0, 3.0);
    let q = Quat::<f32>::new(4.0, 2.0, 2.0, f32::nan());
    assert(less_than(p, q) == bvec4::new(true, false, false, false));
    assert(less_than_equal(p, q) == bvec4::new(true, true, false, true));
    assert(greater_than(p, q) == bvec4::new(false, false, false, false));
    assert(greater_than_equal(p, q) == bvec4::new(false, true, false, true));
}

@test
fn quat_epsilon_tests_are_strict() {
    let p = Quat::<f32>::new(1.0, 0.0, 0.25, 0.0);
    let q = Quat::<f32>::new(1.5, 0.0, 0.0, 0.0);
    assert(equal_eps(p, q, 0.5f32) == bvec4::new(true, true, true, false));
    assert(not_equal_eps(p, q, 0.5f32) == bvec4::new(false, false, false, true));
    assert(epsilon_equal(p, q, 0.5f32) == bvec4::new(true, true, true, false));
    assert(epsilon_not_equal(p, q, 0.5f32) == bvec4::new(false, false, false, true));
    let d = dquat::new(1.0, 0.0, 0.0, 0.0);
    assert(all(epsilon_equal(d, d, 0.000001f64)));
}

@test
fn quat_classify() {
    let q = Quat::<f32>::new(f32::infinity(), f32::nan(), 0.0, -f32::infinity());
    assert(isnan(q) == bvec4::new(true, false, false, false));
    assert(isinf(q) == bvec4::new(false, false, true, true));
    assert(!any(isnan(dquat::identity())));
}

@test
fn quat_normalize_zero_is_identity() {
    assert(normalize(Quat::<f32>::new(0.0, 0.0, 0.0, 0.0)) == Quat::<f32>::identity());
    assert(normalize(dquat::new(2.0, 0.0, 0.0, 0.0)) == dquat::identity());
}

@test
fn quat_cross_is_product() {
    let p = Quat::<f32>::new(1.0, 2.0, 3.0, 4.0);
    let q = Quat::<f32>::new(5.0, 6.0, 7.0, 8.0);
    assert(cross(p, q) == p * q);
}

@test
fn quat_exp_log_real_parts() {
    // `exp` ignores w and gives zero for a vector part below epsilon.
    assert(exp(Quat::<f32>::new(5.0, 0.0, 0.0, 0.0)) == Quat::<f32>::new(0.0, 0.0, 0.0, 0.0));
    let two: f32 = 2.0;
    assert(log(Quat::<f32>::new(2.0, 0.0, 0.0, 0.0)) == Quat::<f32>::new(two.ln(), 0.0, 0.0, 0.0));
    assert(log(Quat::<f32>::new(-2.0, 0.0, 0.0, 0.0)) == Quat::<f32>::new(two.ln(), pi::<f32>(), 0.0, 0.0));
    let inf = f32::infinity();
    assert(log(Quat::<f32>::new(0.0, 0.0, 0.0, 0.0)) == Quat::<f32>::new(inf, inf, inf, inf));
}

@test
fn quat_pow_special_cases() {
    let q = Quat::<f32>::new(0.5, 0.5, 0.5, 0.5);
    assert(pow(q, 0.0f32) == Quat::<f32>::identity());
    assert(pow(Quat::<f32>::new(4.0, 0.0, 0.0, 0.0), 0.5f32) == Quat::<f32>::new(2.0, 0.0, 0.0, 0.0));
    assert(sqrt(dquat::new(9.0, 0.0, 0.0, 0.0)) == dquat::new(3.0, 0.0, 0.0, 0.0));
}

@test
fn quat_lerp() {
    let p = Quat::<f32>::new(1.0, 0.0, 0.0, 0.0);
    let q = Quat::<f32>::new(0.0, 4.0, 0.0, 0.0);
    assert(lerp(p, q, 0.25f32) == Quat::<f32>::new(0.75, 1.0, 0.0, 0.0));
    assert(lerp(p, q, 0.0f32) == p);
    assert(lerp(p, q, 1.0f32) == q);
}

@test(should_panic)
fn quat_lerp_outside_unit_interval_traps() {
    let p = Quat::<f32>::identity();
    let _ = lerp(p, p, 1.5f32);
}

@test
fn quat_rotate_normalizes_axis() {
    let eps: f32 = 0.00001;
    let q = Quat::<f32>::identity();
    let r = rotate(q, pi::<f32>() * 0.5, vec3::new(0.0, 0.0, 2.0));
    assert(all(equal_eps(r, angle_axis(pi::<f32>() * 0.5, vec3::new(0.0, 0.0, 1.0)), eps)));
    assert(all(equal_eps(r * vec3::new(1.0, 0.0, 0.0), vec3::new(0.0, 1.0, 0.0), eps)));
    let d = rotate(dquat::identity(), 1.0, dvec3::new(1.0, 0.0, 0.0));
    assert(d == angle_axis(1.0f64, dvec3::new(1.0, 0.0, 0.0)));
}

@test
fn quat_axis() {
    let a = normalize(vec3::new(1.0, 2.0, 3.0));
    assert(all(equal_eps(axis(angle_axis(1.0f32, a)), a, 0.00001f32)));
    assert(axis(Quat::<f32>::identity()) == vec3::new(0.0, 0.0, 1.0));
    assert(equal_eps(angle(angle_axis(1.0f64, dvec3::new(0.0, 1.0, 0.0))), 1.0f64, 0.0000000001f64));
}

@test
fn quat_euler_singularities() {
    let q = Quat::<f32>::new(1.0, 1.0, 1.0, -1.0);
    assert(roll(q) == 0.0);
    assert(pitch(q) == 2.0 * 1.0f32.atan2(1.0));
    let r = Quat::<f32>::new(1.0, 0.0, 1.0, 0.0);
    assert(roll(r) == 0.0);
    assert(pitch(r) == 0.0);
}

@test
fn quat_from_euler_round_trip() {
    let angles = vec3::new(0.3, -0.2, 0.5);
    let q = Quat::<f32>::from_euler(angles);
    assert(equal_eps(length(q), 1.0f32, 0.000001f32));
    assert(all(equal_eps(euler_angles(q), angles, 0.00001f32)));
    let d = dvec3::new(-1.0, 0.25, 2.0);
    assert(all(equal_eps(euler_angles(dquat::from_euler(d)), d, 0.000000001f64)));
}

@test
fn quat_mat_cast_round_trip() {
    let eps: f32 = 0.00001;
    let qs: [quat; 4] = [
        normalize(Quat::<f32>::new(0.9, 0.1, -0.2, 0.3)),
        normalize(Quat::<f32>::new(0.1, 0.9, -0.2, 0.3)),
        normalize(Quat::<f32>::new(0.1, -0.2, 0.9, 0.3)),
        normalize(Quat::<f32>::new(0.1, -0.2, 0.3, 0.9)),
    ];
    for q in qs {
        let m3 = mat3_cast(q);
        let m4 = mat4_cast(q);
        assert(all(equal_eps(quat_cast(m3), q, eps)));
        assert(all(equal_eps(quat_cast(m4), q, eps)));
        assert(all(equal_eps(Quat::<f32>::from_mat(m3), q, eps)));
        assert(all(equal_eps(Quat::<f32>::from_mat(m4), q, eps)));
        assert(m4[3] == vec4::new(0.0, 0.0, 0.0, 1.0));
        assert(m4[0][3] == 0.0 && m4[1][3] == 0.0 && m4[2][3] == 0.0);
        let v = vec3::new(0.25, -1.5, 2.0);
        assert(all(equal_eps(m3 * v, q * v, eps)));
    }
    assert(mat3_cast(dquat::identity()) == dmat3::identity());
}

@test
fn quat_from_vectors_opposite() {
    let eps: f32 = 0.00001;
    let u = vec3::new(1.0, 2.0, -0.5);
    let q = Quat::<f32>::from_vectors(u, -u);
    assert(equal_eps(length(q), 1.0f32, eps));
    assert(all(equal_eps(q * u, -u, 0.0001f32)));
    let v = vec3::new(0.0, 0.0, 3.0);
    let r = Quat::<f32>::from_vectors(v, -v);
    assert(all(equal_eps(r * v, -v, 0.0001f32)));
}

@test
fn quat_look_at_handedness() {
    let eps: f32 = 0.00001;
    let up = vec3::new(0.0, 1.0, 0.0);
    let rh = quat_look_at_rh(vec3::new(0.0, 0.0, -1.0), up);
    assert(all(equal_eps(rh, Quat::<f32>::identity(), eps)));
    let lh = quat_look_at_lh(vec3::new(0.0, 0.0, 1.0), up);
    assert(all(equal_eps(lh, Quat::<f32>::identity(), eps)));
    assert(quat_look_at(vec3::new(0.0, 0.0, -1.0), up) == rh);
}

const QC: quat = conjugate(Quat::<f32>::new(1.0, 2.0, 3.0, 4.0));
const QDOT: f32 = dot(Quat::<f32>::new(1.0, 2.0, 3.0, 4.0), Quat::<f32>::new(5.0, 6.0, 7.0, 8.0));
const QM3: mat3 = mat3_cast(Quat::<f32>::new(0.0, 1.0, 0.0, 0.0));

@test
fn quat_function_const_initializers() {
    assert(QC == Quat::<f32>::new(1.0, -2.0, -3.0, -4.0));
    assert(QDOT == 70.0);
    assert(QM3 == mat3::new(1.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, -1.0));
}

// Rotation between vectors, orientation angles and fast and short interpolation

@test
fn quat_rotation_log() {
    let v = vec3::new(1.0, 0.0, 0.0);
    let u = vec3::new(0.0, 1.0, 0.0);
    let q = rotation(v, u);
    let r = exp(log(q));
    assert(all(equal_eps(q, r, 0.0001)));
}

@test
fn quat_rotation() {
    let q = rotation(vec3::new(1.0, 0.0, 0.0), vec3::new(0.0, 1.0, 0.0));
    assert((angle(q) - pi::<f32>() * 0.5).abs() < epsilon::<f32>());
}

@test
fn quat_orientation() {
    let q = quat::new(1.0, 0.0, 0.0, 1.0);
    assert(epsilon_equal(roll(q), pi::<f32>() * 0.5, 0.0001));
    assert(epsilon_equal(pitch(q), 0.0, 0.0001));
    assert(epsilon_equal(yaw(q), 0.0, 0.0001));
}

@test
fn quat_fast_mix() {
    let z = vec3::new(0.0, 0.0, 1.0);
    let a = angle_axis(0.0f32, z);
    let b = angle_axis(pi::<f32>() * 0.5, z);
    let c = fast_mix(a, b, 0.5);
    let d = angle_axis(pi::<f32>() * 0.25, z);
    assert(epsilon_equal(c.x, d.x, 0.01));
    assert(epsilon_equal(c.y, d.y, 0.01));
    assert(epsilon_equal(c.z, d.z, 0.01));
    assert(epsilon_equal(c.w, d.w, 0.01));
}

@test
fn quat_short_mix() {
    let z = vec3::new(0.0, 0.0, 1.0);
    let a = angle_axis(0.0f32, z);
    let b = angle_axis(pi::<f32>() * 0.5, z);
    let c = short_mix(a, b, 0.5);
    let d = angle_axis(pi::<f32>() * 0.25, z);
    assert(epsilon_equal(c.x, d.x, 0.01));
    assert(epsilon_equal(c.y, d.y, 0.01));
    assert(epsilon_equal(c.z, d.z, 0.01));
    assert(epsilon_equal(c.w, d.w, 0.01));
}

// Identity, matrix casts, vector rotation, squad and the branches of the functions above

const QID: dquat = quat_identity::<f64>();
const QLEN2: f32 = length2(Quat::<f32>::new(1.0, 2.0, 3.0, 4.0));
const QREAL: f32 = extract_real_component(Quat::<f32>::new(0.0, 0.6, 0.0, 0.0));
const QROT: vec3 = quat_rotate(angle_axis(pi::<f32>(), vec3::new(0.0, 0.0, 1.0)), vec3::new(1.0, 0.0, 0.0));

@test
fn quat_identity_and_casts() {
    assert(quat_identity::<f32>() == Quat::<f32>::identity());
    let q = normalize(quat::new(0.3, -0.5, 0.7, 0.1));
    assert(to_mat3(q) == mat3_cast(q));
    assert(to_mat4(q) == mat4_cast(q));
    assert(to_quat(mat3_cast(q)) == quat_cast(mat3_cast(q)));
    assert(to_quat(mat4_cast(q)) == quat_cast(mat4_cast(q)));
    assert(all(equal_eps(to_quat(to_mat4(q)), q, 0.000001)) || all(equal_eps(to_quat(to_mat4(q)), -q, 0.000001)));
}

@test
fn quat_cross_with_vectors() {
    let q = angle_axis(pi::<f64>() * 0.5, dvec3::new(0.0, 0.0, 1.0));
    let v = dvec3::new(1.0, 0.0, 0.0);
    assert(cross_quat_vec(q, v) == q * v);
    assert(cross_vec_quat(v, q) == inverse(q) * v);
    assert(near(cross_quat_vec(q, v), dvec3::new(0.0, 1.0, 0.0), 1e-15));
    assert(near(cross_vec_quat(v, q), dvec3::new(0.0, -1.0, 0.0), 1e-15));
}

@test
fn quat_rotate_vectors() {
    let q = angle_axis(pi::<f32>() * 0.5, vec3::new(0.0, 0.0, 1.0));
    assert(quat_rotate(q, vec3::new(1.0, 2.0, 3.0)) == q * vec3::new(1.0, 2.0, 3.0));
    assert(quat_rotate(q, vec4::new(1.0, 2.0, 3.0, 4.0)) == q * vec4::new(1.0, 2.0, 3.0, 4.0));
    assert(quat_rotate(q, vec4::new(1.0, 0.0, 0.0, 4.0)).w() == 4.0);
}

@test
fn quat_squad_and_intermediate() {
    let a = angle_axis(0.2f64, dvec3::new(0.0, 0.0, 1.0));
    let b = angle_axis(0.9f64, dvec3::new(0.0, 1.0, 0.0));
    let s1 = angle_axis(0.4f64, dvec3::new(1.0, 0.0, 0.0));
    let s2 = angle_axis(0.7f64, dvec3::new(1.0, 1.0, 0.0) * 0.5f64.sqrt());
    // The endpoints: h = 0 gives q1, h = 1 gives q2 (the outer interpolant is 0 at both ends).
    assert(all(equal_eps(squad(a, b, s1, s2, 0.0), a, 1e-15)));
    assert(all(equal_eps(squad(a, b, s1, s2, 1.0), b, 1e-15)));
    assert(squad(a, b, s1, s2, 0.3) == mix(mix(a, b, 0.3f64), mix(s1, s2, 0.3f64), 2.0 * 0.7 * 0.3));
    // Off one axis the control point lies between the neighbors' corrections.
    let mid = intermediate(a, s1, b);
    let inv = inverse(s1);
    assert(mid == exp((log(b * inv) + log(a * inv)) / -4.0) * s1);
    assert(length(mid) > 0.5);
    // On a single axis the logs of evenly spaced rotations cancel; `exp` of a quaternion whose vector
    // part is below epsilon is 0, so the control point is 0, not the middle rotation.
    let z = dvec3::new(0.0, 0.0, 1.0);
    let zero = intermediate(angle_axis(0.25f64, z), angle_axis(0.5f64, z), angle_axis(0.75f64, z));
    assert(zero == dquat::new(0.0, 0.0, 0.0, 0.0));
}

@test
fn quat_extract_real_component() {
    let q = dquat::new(9.0, 0.6, 0.0, 0.0);
    assert(extract_real_component(q) == -(1.0f64 - 0.36).sqrt());
    assert(extract_real_component(dquat::new(1.0, 1.0, 1.0, 0.0)) == 0.0);
    assert(extract_real_component(dquat::new(1.0, 0.0, 0.0, 0.0)) == -1.0);
}

@test
fn quat_length2() {
    let q = quat::new(1.0, 2.0, 3.0, 4.0);
    assert(length2(q) == 30.0);
    // x^2 + y^2 + z^2 + w^2 left to right, not dot's order: the sums round apart.
    let r = Quat::<f32>::new(16777216.0, 1.0, 1.0, 1.0);
    assert(length2(r) == 281474976710656.0 + 1.0 + 1.0 + 1.0);
}

@test
fn quat_short_mix_branches() {
    let a = angle_axis(0.3f64, dvec3::new(0.0, 1.0, 0.0));
    let b = angle_axis(1.3f64, dvec3::new(0.0, 1.0, 0.0));
    assert(short_mix(a, b, 0.0) == a);
    assert(short_mix(a, b, -1.0) == a);
    assert(short_mix(a, b, 1.0) == b);
    assert(short_mix(a, b, 2.0) == b);
    let mid = short_mix(a, b, 0.5);
    assert(all(equal_eps(mid, angle_axis(0.8f64, dvec3::new(0.0, 1.0, 0.0)), 1e-15)));
    // The shorter arc: a negated end gives the same rotation.
    assert(all(equal_eps(short_mix(a, -b, 0.5), mid, 1e-15)));
    // Nearly equal ends blend linearly.
    assert(short_mix(a, a, 0.25) == a * 0.75 + a * 0.25);
}

@test
fn quat_rotation_branches() {
    let x = vec3::new(1.0, 0.0, 0.0);
    assert(rotation(x, x) == quat_identity::<f32>());
    let half = rotation(x, -x);
    assert(near(half * x, -x, 0.000001));
    assert((angle(half) - pi::<f32>()).abs() < 0.000001);
    // Along z the first trial axis is parallel: `rotation` turns about cross((1, 0, 0), z) instead.
    let z = dvec3::new(0.0, 0.0, 1.0);
    let flip = rotation(z, -z);
    assert(near(flip * z, -z, 1e-15));
    assert(near(axis(flip), dvec3::new(0.0, -1.0, 0.0), 1e-15));
    let r = rotation(x, normalize(vec3::new(1.0, 1.0, 0.0)));
    assert(near(r * x, normalize(vec3::new(1.0, 1.0, 0.0)), 0.000001));
}

@test
fn quat_utility_const_initializers() {
    assert(QID == Quat::<f64>::identity());
    assert(QLEN2 == 30.0);
    assert(QREAL == -0.8);
    assert(QROT == quat_rotate(angle_axis(pi::<f32>(), vec3::new(0.0, 0.0, 1.0)), vec3::new(1.0, 0.0, 0.0)));
}
