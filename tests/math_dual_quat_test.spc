// std::math::dual_quat: construction, copy, scalar products, inverse, composition and point transforms
// checked against 4x4 matrices on pseudo-random rigid transforms, and size; then every operator,
// component access, the matrix casts and their round trips, normalize, lerp, the conversions, index
// and interpolant traps, and constant initializers.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::quat as *;
import std::math::geometric as *;
import std::math::compare as *;
import std::math::transform as *;
import std::math::euler as *;
import std::math::dual_quat as *;

// A linear congruential generator; `frand` divides its 15-bit value by 0x7ffff in f64, converts the
// quotient to f32 and maps it as `* 2 - 1`. The divisor is 0x7ffff, not 0x7fff, so values lie in
// [-1, -0.875].
struct Rand {
    hold: i32,
}

extend Rand {
    fn new() Rand {
        return Rand { hold: 1 };
    }
    fn next(self: &mut Rand) i32 {
        self.hold = self.hold.wrapping_mul(214013).wrapping_add(2531011);
        return self.hold >> 16 & 0x7fff;
    }
    fn frand(self: &mut Rand) f32 {
        return (self.next() as f64 / 0x7ffff as f64) as f32 * 2.0 - 1.0;
    }
}

// Every component of `a` strictly within `eps` of `b`.
fn eps_quat(a: quat, b: quat, eps: f32) bool {
    return all(epsilon_equal(a, b, eps));
}

fn eps_dq(a: dualquat, b: dualquat, eps: f32) bool {
    return eps_quat(a.real, b.real, eps) && eps_quat(a.dual, b.dual, eps);
}

fn copies<T: Copy>(x: T) (T, T) {
    return x, x;
}

const DQ_ID: dualquat = DualQuat::<f32>::identity();
const DQ_T: ddualquat = DualQuat::<f64>::from_orientation_translation(
    Quat::<f64>::identity(),
    dvec3::new(1.0, 2.0, 3.0),
);
const DQ_P: vec3 = DualQuat::<f32>::from_orientation_translation(Quat::<f32>::identity(), vec3::new(1.0, 2.0, 3.0)) * vec3::splat(
    1.0,
);

// Construction, scalar products, inverse, composition and size

// A `DualQuat` is `Copy`: both copies compare equal.
@test
fn dual_quat_ctr() {
    let (a, b) = copies(dual_quat_identity::<f32>());
    assert(a == b);
    let (c, d) = copies(dual_quat_identity::<f64>());
    assert(c == d);
}

@test
fn dquat_type() {
    let va = dvec3::zero();
    let dqa = dquat::identity();
    let dqb = dquat::identity();
    let c = ddualquat::new(dqa, dqb);
    let b = ddualquat::from_real(dqa);
    let d = ddualquat::from_orientation_translation(dqa, va);
    assert(c.real == dqa);
    assert(b.dual == Quat::<f64>::new(0.0, 0.0, 0.0, 0.0));
    assert(d.dual == Quat::<f64>::new(-0.0, 0.0, 0.0, 0.0));
}

@test
fn scalars() {
    let eps: f32 = 0.0001;
    let src_q1 = quat::new(1.0, 2.0, 3.0, 4.0);
    let src_q2 = quat::new(5.0, 6.0, 7.0, 8.0);
    let src1 = dualquat::new(src_q1, src_q2);
    {
        let dst1 = src1 * 2.0;
        let dst2 = 2.0f32 * src1;
        let mut dst3 = src1;
        dst3 *= 2.0;
        let cmp = dualquat::new(src_q1 * 2.0, src_q2 * 2.0);
        assert(eps_dq(dst1, cmp, eps));
        assert(eps_dq(dst2, cmp, eps));
        assert(eps_dq(dst3, cmp, eps));
    }
    {
        let dst1 = src1 / 2.0;
        let mut dst2 = src1;
        dst2 /= 2.0;
        let cmp = dualquat::new(src_q1 / 2.0, src_q2 / 2.0);
        assert(eps_dq(dst1, cmp, eps));
        assert(eps_dq(dst2, cmp, eps));
    }
}

@test
fn inverse_test() {
    let eps: f32 = 0.0001;
    let mut r = Rand::new();
    let id = dual_quat_identity::<f32>();
    for _ in 0..100 {
        let yaw = r.frand() * 360.0;
        let pitch = r.frand() * 360.0;
        let roll = r.frand() * 360.0;
        let rot = yaw_pitch_roll(yaw, pitch, roll);
        let vt = vec3::new(r.frand() * 10.0, r.frand() * 10.0, r.frand() * 10.0);
        let m = translate(mat4::identity(), vt) * rot;
        let dq = dualquat::from_real(quat_cast(m));
        let invdq = inverse(dq);
        assert(eps_dq(invdq * dq, id, eps));
        assert(eps_dq(dq * invdq, id, eps));
        let w = r.frand() * pi::<f32>() * 2.0;
        let x = r.frand();
        let y = r.frand();
        let z = r.frand();
        let t = vec3::new(r.frand() * 10.0, r.frand() * 10.0, r.frand() * 10.0);
        let rq = dualquat::from_orientation_translation(quat::new(w, x, y, z), t);
        assert(eps_dq(rq * invdq * dq, rq * dq * invdq, eps));
    }
}

@test
fn mul() {
    let eps: f32 = 0.0001;
    let mut r = Rand::new();
    for _ in 0..100 {
        let vt1 = vec3::new(r.frand() * 10.0, r.frand() * 10.0, r.frand() * 10.0);
        let vt2 = vec3::new(r.frand() * 10.0, r.frand() * 10.0, r.frand() * 10.0);
        let rot1 = yaw_pitch_roll(r.frand() * 360.0, r.frand() * 360.0, r.frand() * 360.0);
        let rot2 = yaw_pitch_roll(r.frand() * 360.0, r.frand() * 360.0, r.frand() * 360.0);
        let m1 = translate(mat4::identity(), vt1) * rot1;
        let m2 = translate(mat4::identity(), vt2) * rot2;
        let m3 = m2 * m1;
        let m4 = m1 * m2;
        let dq1 = dualquat::from_orientation_translation(quat_cast(rot1), vt1);
        let dq2 = dualquat::from_orientation_translation(quat_cast(rot2), vt2);
        let dq3 = dq2 * dq1;
        let dq4 = dq1 * dq2;
        for _ in 0..100 {
            let p = vec4::new(r.frand() * 4.0, r.frand() * 5.0, r.frand() * 3.0, 1.0);
            assert(all(epsilon_equal(m3 * p, dq3 * p, eps)));
            assert(all(epsilon_equal(m4 * p, dq4 * p, eps)));
            assert(all(epsilon_equal(inverse(m3) * p, p * dq3, eps)));
            assert(all(epsilon_equal(inverse(m4) * p, p * dq4, eps)));
        }
    }
}

@test
fn size() {
    assert(sizeof(dualquat) == 32);
    assert(sizeof(ddualquat) == 64);
    assert(dualquat::LEN == 2);
    assert(ddualquat::LEN == 2);
    assert(dual_quat_identity::<f32>().len() == 2);
    assert(dual_quat_identity::<f64>().len() == 2);
}

// Operators, access, matrix casts, normalize, lerp, conversions and traps

@test
fn aliases_and_identity() {
    let a: fdualquat = dualquat::identity();
    assert(a == dual_quat_identity::<f32>());
    assert(a.real == quat::identity());
    assert(a.dual == quat::new(0.0, 0.0, 0.0, 0.0));
    let d: ddualquat = DualQuat::<f64>::identity();
    assert(d * dvec3::new(1.0, 2.0, 3.0) == dvec3::new(1.0, 2.0, 3.0));
}

@test
fn neg_add_eq() {
    let a = dualquat::new(quat::new(1.0, 2.0, 3.0, 4.0), quat::new(5.0, 6.0, 7.0, 8.0));
    let b = dualquat::new(quat::new(0.5, 0.5, 0.5, 0.5), quat::new(-1.0, 0.0, 1.0, 2.0));
    let n = -a;
    assert(n.real == quat::new(-1.0, -2.0, -3.0, -4.0));
    assert(n.dual == quat::new(-5.0, -6.0, -7.0, -8.0));
    let s = a + b;
    assert(s.real == quat::new(1.5, 2.5, 3.5, 4.5));
    assert(s.dual == quat::new(4.0, 6.0, 8.0, 10.0));
    assert(a == a);
    assert(a != b);
    let nan = dualquat::new(quat::new(f32::nan(), 0.0, 0.0, 0.0), quat::identity());
    assert(nan != nan);
}

// A rigid transform moves a point by its rotation then its translation; a vec4 keeps its w.
@test
fn transform_points() {
    let q = angle_axis(pi::<f64>() * 0.5, dvec3::new(0.0, 0.0, 1.0));
    let dq = DualQuat::<f64>::from_orientation_translation(q, dvec3::new(1.0, 2.0, 3.0));
    let p = dq * dvec3::new(1.0, 0.0, 0.0);
    assert(all(epsilon_equal(p, dvec3::new(1.0, 3.0, 3.0), 1e-15f64)));
    let p4 = dq * dvec4::new(1.0, 0.0, 0.0, 7.0);
    assert(all(epsilon_equal(p4, dvec4::new(1.0, 3.0, 3.0, 7.0), 1e-15f64)));
    let back = p * dq;
    assert(all(epsilon_equal(back, dvec3::new(1.0, 0.0, 0.0), 1e-15f64)));
    let back4 = p4 * dq;
    assert(all(epsilon_equal(back4, dvec4::new(1.0, 0.0, 0.0, 7.0), 1e-15f64)));
}

@test
fn normalize_divides_by_the_real_length() {
    let a = dualquat::new(quat::new(0.0, 3.0, 0.0, 4.0), quat::new(5.0, 0.0, 10.0, 0.0));
    let n = normalize(a);
    assert(n.real == quat::new(0.0, 0.6, 0.0, 0.8));
    assert(n.dual == quat::new(1.0, 0.0, 2.0, 0.0));
}

@test
fn lerp_takes_the_shorter_arc() {
    let a = DualQuat::<f64>::from_orientation_translation(dquat::identity(), dvec3::new(0.0, 0.0, 0.0));
    let b = DualQuat::<f64>::from_orientation_translation(dquat::identity(), dvec3::new(2.0, 0.0, 0.0));
    let m = lerp(a, b, 0.5);
    assert(all(epsilon_equal(m * dvec3::zero(), dvec3::new(1.0, 0.0, 0.0), 1e-15f64)));
    let m2 = lerp(a, -b, 0.5);
    assert(m2 == m);
    assert(lerp(a, b, 0.0) == a * 1.0 + b * 0.0);
}

@test(should_panic)
fn lerp_above_one_traps() {
    let a = dual_quat_identity::<f32>();
    let _ = lerp(a, a, 1.5);
}

@test(should_panic)
fn lerp_nan_traps() {
    let a = dual_quat_identity::<f32>();
    let _ = lerp(a, a, f32::nan());
}

@test
fn inverse_of_rigid_transforms() {
    let q = normalize(dquat::new(0.3, -0.5, 0.7, 0.1));
    let dq = DualQuat::<f64>::from_orientation_translation(q, dvec3::new(-4.0, 2.5, 9.0));
    let id = (inverse(dq) * dq).real;
    assert(all(epsilon_equal(id, dquat::identity(), 1e-15f64)));
    let p = dvec3::new(0.25, -1.0, 3.0);
    assert(all(epsilon_equal(inverse(dq) * (dq * p), p, 1e-14f64)));
}

@test
fn matrix_casts_round_trip() {
    let a = dualquat::new(quat::new(1.0, 2.0, 3.0, 4.0), quat::new(5.0, 6.0, 7.0, 8.0));
    let m24 = mat2x4_cast(a);
    assert(m24 == mat2x4::new(2.0, 3.0, 4.0, 1.0, 6.0, 7.0, 8.0, 5.0));
    assert(dualquat_cast(m24) == a);
    assert(dualquat::from_mat(m24) == a);
    let q = normalize(dquat::new(0.3, -0.5, 0.7, 0.1));
    let dq = DualQuat::<f64>::from_orientation_translation(q, dvec3::new(-4.0, 2.5, 9.0));
    let m34 = mat3x4_cast(dq);
    let back = dualquat_cast(m34);
    assert(all(epsilon_equal(back.real, dq.real, 1e-15f64)) || all(epsilon_equal(back.real, -dq.real, 1e-15f64)));
    let p = dvec3::new(1.0, -2.0, 0.5);
    let by_mat = transpose(m34) * p.append(1.0);
    assert(all(epsilon_equal(by_mat, dq * p, 1e-14f64)));
    assert(all(epsilon_equal(DualQuat::<f64>::from_mat(m34) * p, dq * p, 1e-14f64)));
}

// Each branch of dualquat_cast(mat3x4): the trace positive, then the largest diagonal element in x, y
// and z (half turns about each axis).
@test
fn dualquat_cast_branches() {
    let p = dvec3::new(1.0, 2.0, 3.0);
    let axes = [
        dvec3::new(0.0, 0.0, 1.0),
        dvec3::new(1.0, 0.0, 0.0),
        dvec3::new(0.0, 1.0, 0.0),
        dvec3::new(0.0, 0.0, 1.0),
    ];
    let angles = [0.5f64, pi::<f64>(), pi::<f64>(), pi::<f64>()];
    for i in 0..4 {
        let dq = DualQuat::<f64>::from_orientation_translation(unsafe angle_axis(angles[i], axes[i]), p);
        let back = dualquat_cast(mat3x4_cast(dq));
        let v = dvec3::new(0.5, -1.5, 2.0);
        assert(all(epsilon_equal(back * v, dq * v, 1e-14f64)));
    }
}

@test
fn index_and_cast() {
    let mut a = dualquat::new(quat::new(1.0, 2.0, 3.0, 4.0), quat::new(5.0, 6.0, 7.0, 8.0));
    assert(a[0] == a.real);
    assert(a[1] == a.dual);
    a[1] = quat::identity();
    assert(a.dual == quat::identity());
    assert(a[0..].len() == 2);
    let d = a.cast::<f64>();
    assert(d.real == dquat::new(1.0, 2.0, 3.0, 4.0));
    assert(d.cast::<f32>() == a);
}

@test(should_panic)
fn index_out_of_range_traps() {
    let a = dual_quat_identity::<f32>();
    let i = dualquat::LEN;
    let _ = a[i];
}

@test(should_panic)
fn index_mut_out_of_range_traps() {
    let mut a = dual_quat_identity::<f32>();
    let i = dualquat::LEN;
    a[i] = quat::identity();
}

@test
fn constant_initializers() {
    assert(DQ_ID == dual_quat_identity::<f32>());
    assert(DQ_T == DualQuat::<f64>::from_orientation_translation(Quat::<f64>::identity(), dvec3::new(1.0, 2.0, 3.0)));
    assert(DQ_P == vec3::new(2.0, 3.0, 4.0));
}
