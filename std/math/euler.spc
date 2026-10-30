// The 4x4 rotation matrices of Euler angles in radians for every axis sequence (`euler_angle_x` ..
// `euler_angle_zxy`, `yaw_pitch_roll`), their derivatives, the `orientate` builders and the
// `extract_euler_angle_*` inverses, which return the three angles (t1, t2, t3) as a tuple.
// `orientate3` takes an angle (a 2D rotation) or a vec3 of (pitch, yaw, roll) through `Orientate3`.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;

/// A value `orientate3` takes: an angle in radians, or a `Vec<T, 3>` of Euler angles.
pub interface Orientate3<T: Float>: Copy {
    fn orientate3(self: Self) Mat<T, 3, 3>;
}

/// The rotation by `angle_x` radians around the x axis.
pub fn euler_angle_x<T: Float>(angle_x: T) Mat<T, 4, 4> {
    let c = angle_x.cos();
    let s = angle_x.sin();
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(l, o, o, o, o, c, s, o, o, -s, c, o, o, o, o, l);
}

/// The rotation by `angle_y` radians around the y axis.
pub fn euler_angle_y<T: Float>(angle_y: T) Mat<T, 4, 4> {
    let c = angle_y.cos();
    let s = angle_y.sin();
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(c, o, -s, o, o, l, o, o, s, o, c, o, o, o, o, l);
}

/// The rotation by `angle_z` radians around the z axis.
pub fn euler_angle_z<T: Float>(angle_z: T) Mat<T, 4, 4> {
    let c = angle_z.cos();
    let s = angle_z.sin();
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(c, s, o, o, -s, c, o, o, o, o, l, o, o, o, o, l);
}

/// The time derivative of `euler_angle_x` at `angle_x` for the angular velocity `angular_velocity_x`.
pub fn derived_euler_angle_x<T: Float>(angle_x: T, angular_velocity_x: T) Mat<T, 4, 4> {
    let c = angle_x.cos() * angular_velocity_x;
    let s = angle_x.sin() * angular_velocity_x;
    let o = T::zero();
    return Mat::<T, 4, 4>::new(o, o, o, o, o, -s, c, o, o, -c, -s, o, o, o, o, o);
}

/// The time derivative of `euler_angle_y`.
pub fn derived_euler_angle_y<T: Float>(angle_y: T, angular_velocity_y: T) Mat<T, 4, 4> {
    let c = angle_y.cos() * angular_velocity_y;
    let s = angle_y.sin() * angular_velocity_y;
    let o = T::zero();
    return Mat::<T, 4, 4>::new(-s, o, -c, o, o, o, o, o, c, o, -s, o, o, o, o, o);
}

/// The time derivative of `euler_angle_z`.
pub fn derived_euler_angle_z<T: Float>(angle_z: T, angular_velocity_z: T) Mat<T, 4, 4> {
    let c = angle_z.cos() * angular_velocity_z;
    let s = angle_z.sin() * angular_velocity_z;
    let o = T::zero();
    return Mat::<T, 4, 4>::new(-s, c, o, o, -c, -s, o, o, o, o, o, o, o, o, o, o);
}

/// `euler_angle_x(angle_x) * euler_angle_y(angle_y)`, element by element.
pub fn euler_angle_xy<T: Float>(angle_x: T, angle_y: T) Mat<T, 4, 4> {
    let cx = angle_x.cos();
    let sx = angle_x.sin();
    let cy = angle_y.cos();
    let sy = angle_y.sin();
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(cy, -sx * -sy, cx * -sy, o, o, cx, sx, o, sy, -sx * cy, cx * cy, o, o, o, o, l);
}

/// `euler_angle_y(angle_y) * euler_angle_x(angle_x)`, element by element.
pub fn euler_angle_yx<T: Float>(angle_y: T, angle_x: T) Mat<T, 4, 4> {
    let cx = angle_x.cos();
    let sx = angle_x.sin();
    let cy = angle_y.cos();
    let sy = angle_y.sin();
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(cy, o, -sy, o, sy * sx, cx, cy * sx, o, sy * cx, -sx, cy * cx, o, o, o, o, l);
}

/// `euler_angle_x(angle_x) * euler_angle_z(angle_z)` (a matrix product).
pub fn euler_angle_xz<T: Float>(angle_x: T, angle_z: T) Mat<T, 4, 4> {
    return euler_angle_x(angle_x) * euler_angle_z(angle_z);
}

/// `euler_angle_z(angle_z) * euler_angle_x(angle_x)` (a matrix product).
pub fn euler_angle_zx<T: Float>(angle_z: T, angle_x: T) Mat<T, 4, 4> {
    return euler_angle_z(angle_z) * euler_angle_x(angle_x);
}

/// `euler_angle_y(angle_y) * euler_angle_z(angle_z)` (a matrix product).
pub fn euler_angle_yz<T: Float>(angle_y: T, angle_z: T) Mat<T, 4, 4> {
    return euler_angle_y(angle_y) * euler_angle_z(angle_z);
}

/// `euler_angle_z(angle_z) * euler_angle_y(angle_y)` (a matrix product).
pub fn euler_angle_zy<T: Float>(angle_z: T, angle_y: T) Mat<T, 4, 4> {
    return euler_angle_z(angle_z) * euler_angle_y(angle_y);
}

/// The rotation of the angles `t1`, `t2`, `t3` around x, y, z, from the cosines and sines of `-t1`,
/// `-t2`, `-t3`.
pub fn euler_angle_xyz<T: Float>(t1: T, t2: T, t3: T) Mat<T, 4, 4> {
    let c1 = (-t1).cos();
    let c2 = (-t2).cos();
    let c3 = (-t3).cos();
    let s1 = (-t1).sin();
    let s2 = (-t2).sin();
    let s3 = (-t3).sin();
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(
        c2 * c3,
        -c1 * s3 + s1 * s2 * c3,
        s1 * s3 + c1 * s2 * c3,
        o,
        c2 * s3,
        c1 * c3 + s1 * s2 * s3,
        -s1 * c3 + c1 * s2 * s3,
        o,
        -s2,
        s1 * c2,
        c1 * c2,
        o,
        o,
        o,
        o,
        l,
    );
}

/// The rotation of `yaw` (y), `pitch` (x) and `roll` (z), as `yaw_pitch_roll`.
pub fn euler_angle_yxz<T: Float>(yaw: T, pitch: T, roll: T) Mat<T, 4, 4> {
    return yaw_pitch_roll(yaw, pitch, roll);
}

/// The rotation of `t1` around x, `t2` around z, `t3` around x.
pub fn euler_angle_xzx<T: Float>(t1: T, t2: T, t3: T) Mat<T, 4, 4> {
    let (c1, s1, c2, s2, c3, s3) = cos_sin3(t1, t2, t3);
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(
        c2,
        c1 * s2,
        s1 * s2,
        o,
        -c3 * s2,
        c1 * c2 * c3 - s1 * s3,
        c1 * s3 + c2 * c3 * s1,
        o,
        s2 * s3,
        -c3 * s1 - c1 * c2 * s3,
        c1 * c3 - c2 * s1 * s3,
        o,
        o,
        o,
        o,
        l,
    );
}

/// The rotation of `t1` around x, `t2` around y, `t3` around x.
pub fn euler_angle_xyx<T: Float>(t1: T, t2: T, t3: T) Mat<T, 4, 4> {
    let (c1, s1, c2, s2, c3, s3) = cos_sin3(t1, t2, t3);
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(
        c2,
        s1 * s2,
        -c1 * s2,
        o,
        s2 * s3,
        c1 * c3 - c2 * s1 * s3,
        c3 * s1 + c1 * c2 * s3,
        o,
        c3 * s2,
        -c1 * s3 - c2 * c3 * s1,
        c1 * c2 * c3 - s1 * s3,
        o,
        o,
        o,
        o,
        l,
    );
}

/// The rotation of `t1` around y, `t2` around x, `t3` around y.
pub fn euler_angle_yxy<T: Float>(t1: T, t2: T, t3: T) Mat<T, 4, 4> {
    let (c1, s1, c2, s2, c3, s3) = cos_sin3(t1, t2, t3);
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(
        c1 * c3 - c2 * s1 * s3,
        s2 * s3,
        -c3 * s1 - c1 * c2 * s3,
        o,
        s1 * s2,
        c2,
        c1 * s2,
        o,
        c1 * s3 + c2 * c3 * s1,
        -c3 * s2,
        c1 * c2 * c3 - s1 * s3,
        o,
        o,
        o,
        o,
        l,
    );
}

/// The rotation of `t1` around y, `t2` around z, `t3` around y.
pub fn euler_angle_yzy<T: Float>(t1: T, t2: T, t3: T) Mat<T, 4, 4> {
    let (c1, s1, c2, s2, c3, s3) = cos_sin3(t1, t2, t3);
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(
        c1 * c2 * c3 - s1 * s3,
        c3 * s2,
        -c1 * s3 - c2 * c3 * s1,
        o,
        -c1 * s2,
        c2,
        s1 * s2,
        o,
        c3 * s1 + c1 * c2 * s3,
        s2 * s3,
        c1 * c3 - c2 * s1 * s3,
        o,
        o,
        o,
        o,
        l,
    );
}

/// The rotation of `t1` around z, `t2` around y, `t3` around z.
pub fn euler_angle_zyz<T: Float>(t1: T, t2: T, t3: T) Mat<T, 4, 4> {
    let (c1, s1, c2, s2, c3, s3) = cos_sin3(t1, t2, t3);
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(
        c1 * c2 * c3 - s1 * s3,
        c1 * s3 + c2 * c3 * s1,
        -c3 * s2,
        o,
        -c3 * s1 - c1 * c2 * s3,
        c1 * c3 - c2 * s1 * s3,
        s2 * s3,
        o,
        c1 * s2,
        s1 * s2,
        c2,
        o,
        o,
        o,
        o,
        l,
    );
}

/// The rotation of `t1` around z, `t2` around x, `t3` around z.
pub fn euler_angle_zxz<T: Float>(t1: T, t2: T, t3: T) Mat<T, 4, 4> {
    let (c1, s1, c2, s2, c3, s3) = cos_sin3(t1, t2, t3);
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(
        c1 * c3 - c2 * s1 * s3,
        c3 * s1 + c1 * c2 * s3,
        s2 * s3,
        o,
        -c1 * s3 - c2 * c3 * s1,
        c1 * c2 * c3 - s1 * s3,
        c3 * s2,
        o,
        s1 * s2,
        -c1 * s2,
        c2,
        o,
        o,
        o,
        o,
        l,
    );
}

/// The rotation of `t1` around x, `t2` around z, `t3` around y.
pub fn euler_angle_xzy<T: Float>(t1: T, t2: T, t3: T) Mat<T, 4, 4> {
    let (c1, s1, c2, s2, c3, s3) = cos_sin3(t1, t2, t3);
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(
        c2 * c3,
        s1 * s3 + c1 * c3 * s2,
        c3 * s1 * s2 - c1 * s3,
        o,
        -s2,
        c1 * c2,
        c2 * s1,
        o,
        c2 * s3,
        c1 * s2 * s3 - c3 * s1,
        c1 * c3 + s1 * s2 * s3,
        o,
        o,
        o,
        o,
        l,
    );
}

/// The rotation of `t1` around y, `t2` around z, `t3` around x.
pub fn euler_angle_yzx<T: Float>(t1: T, t2: T, t3: T) Mat<T, 4, 4> {
    let (c1, s1, c2, s2, c3, s3) = cos_sin3(t1, t2, t3);
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(
        c1 * c2,
        s2,
        -c2 * s1,
        o,
        s1 * s3 - c1 * c3 * s2,
        c2 * c3,
        c1 * s3 + c3 * s1 * s2,
        o,
        c3 * s1 + c1 * s2 * s3,
        -c2 * s3,
        c1 * c3 - s1 * s2 * s3,
        o,
        o,
        o,
        o,
        l,
    );
}

/// The rotation of `t1` around z, `t2` around y, `t3` around x.
pub fn euler_angle_zyx<T: Float>(t1: T, t2: T, t3: T) Mat<T, 4, 4> {
    let (c1, s1, c2, s2, c3, s3) = cos_sin3(t1, t2, t3);
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(
        c1 * c2,
        c2 * s1,
        -s2,
        o,
        c1 * s2 * s3 - c3 * s1,
        c1 * c3 + s1 * s2 * s3,
        c2 * s3,
        o,
        s1 * s3 + c1 * c3 * s2,
        c3 * s1 * s2 - c1 * s3,
        c2 * c3,
        o,
        o,
        o,
        o,
        l,
    );
}

/// The rotation of `t1` around z, `t2` around x, `t3` around y.
pub fn euler_angle_zxy<T: Float>(t1: T, t2: T, t3: T) Mat<T, 4, 4> {
    let (c1, s1, c2, s2, c3, s3) = cos_sin3(t1, t2, t3);
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(
        c1 * c3 - s1 * s2 * s3,
        c3 * s1 + c1 * s2 * s3,
        -c2 * s3,
        o,
        -c2 * s1,
        c1 * c2,
        s2,
        o,
        c1 * s3 + c3 * s1 * s2,
        s1 * s3 - c1 * c3 * s2,
        c2 * c3,
        o,
        o,
        o,
        o,
        l,
    );
}

/// The rotation of `yaw` around y, then `pitch` around x, then `roll` around z.
pub fn yaw_pitch_roll<T: Float>(yaw: T, pitch: T, roll: T) Mat<T, 4, 4> {
    let ch = yaw.cos();
    let sh = yaw.sin();
    let cp = pitch.cos();
    let sp = pitch.sin();
    let cb = roll.cos();
    let sb = roll.sin();
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(
        ch * cb + sh * sp * sb,
        sb * cp,
        -sh * cb + ch * sp * sb,
        o,
        -ch * sb + sh * sp * cb,
        cb * cp,
        sb * sh + ch * sp * cb,
        o,
        sh * cp,
        -sp,
        ch * cp,
        o,
        o,
        o,
        o,
        l,
    );
}

/// The 2x2 rotation by `angle` radians.
pub fn orientate2<T: Float>(angle: T) Mat<T, 2, 2> {
    let c = angle.cos();
    let s = angle.sin();
    return Mat::<T, 2, 2>::new(c, s, -s, c);
}

/// Of an angle, the 3x3 homogeneous 2D rotation by it; of a vec3 of Euler angles, the upper-left 3x3
/// block of `yaw_pitch_roll(angles.z, angles.x, angles.y)`.
pub fn orientate3<T: Float, G: Orientate3<T>>(x: G) Mat<T, 3, 3> {
    return x.orientate3();
}

/// `yaw_pitch_roll(angles.z, angles.x, angles.y)`.
pub fn orientate4<T: Float>(angles: Vec<T, 3>) Mat<T, 4, 4> {
    return yaw_pitch_roll(angles.e[2], angles.e[0], angles.e[1]);
}

/// The angles (t1, t2, t3) whose `euler_angle_xyz` is the rotation of `m`, t2 in [-pi/2, pi/2].
pub fn extract_euler_angle_xyz<T: Float>(m: Mat<T, 4, 4>) (T, T, T) {
    let (a, b, c) = (m.c[0].e, m.c[1].e, m.c[2].e);
    let t1 = c[1].atan2(c[2]);
    let c2 = (a[0] * a[0] + b[0] * b[0]).sqrt();
    let t2 = (-c[0]).atan2(c2);
    let s1 = t1.sin();
    let c1 = t1.cos();
    let t3 = (s1 * a[2] - c1 * a[1]).atan2(c1 * b[1] - s1 * b[2]);
    return (-t1, -t2, -t3);
}

/// The angles (t1, t2, t3) of `euler_angle_yxz`.
pub fn extract_euler_angle_yxz<T: Float>(m: Mat<T, 4, 4>) (T, T, T) {
    let (a, b, c) = (m.c[0].e, m.c[1].e, m.c[2].e);
    let t1 = c[0].atan2(c[2]);
    let c2 = (a[1] * a[1] + b[1] * b[1]).sqrt();
    let t2 = (-c[1]).atan2(c2);
    let s1 = t1.sin();
    let c1 = t1.cos();
    let t3 = (s1 * b[2] - c1 * b[0]).atan2(c1 * a[0] - s1 * a[2]);
    return (t1, t2, t3);
}

/// The angles (t1, t2, t3) of `euler_angle_xzx`, t2 in [0, pi].
pub fn extract_euler_angle_xzx<T: Float>(m: Mat<T, 4, 4>) (T, T, T) {
    let (a, b, c) = (m.c[0].e, m.c[1].e, m.c[2].e);
    let t1 = a[2].atan2(a[1]);
    let s2 = (b[0] * b[0] + c[0] * c[0]).sqrt();
    let t2 = s2.atan2(a[0]);
    let s1 = t1.sin();
    let c1 = t1.cos();
    let t3 = (c1 * b[2] - s1 * b[1]).atan2(c1 * c[2] - s1 * c[1]);
    return (t1, t2, t3);
}

/// The angles (t1, t2, t3) of `euler_angle_xyx`, t2 in [0, pi].
pub fn extract_euler_angle_xyx<T: Float>(m: Mat<T, 4, 4>) (T, T, T) {
    let (a, b, c) = (m.c[0].e, m.c[1].e, m.c[2].e);
    let t1 = a[1].atan2(-a[2]);
    let s2 = (b[0] * b[0] + c[0] * c[0]).sqrt();
    let t2 = s2.atan2(a[0]);
    let s1 = t1.sin();
    let c1 = t1.cos();
    let t3 = (-c1 * c[1] - s1 * c[2]).atan2(c1 * b[1] + s1 * b[2]);
    return (t1, t2, t3);
}

/// The angles (t1, t2, t3) of `euler_angle_yxy`, t2 in [0, pi].
pub fn extract_euler_angle_yxy<T: Float>(m: Mat<T, 4, 4>) (T, T, T) {
    let (a, b, c) = (m.c[0].e, m.c[1].e, m.c[2].e);
    let t1 = b[0].atan2(b[2]);
    let s2 = (a[1] * a[1] + c[1] * c[1]).sqrt();
    let t2 = s2.atan2(b[1]);
    let s1 = t1.sin();
    let c1 = t1.cos();
    let t3 = (c1 * c[0] - s1 * c[2]).atan2(c1 * a[0] - s1 * a[2]);
    return (t1, t2, t3);
}

/// The angles (t1, t2, t3) of `euler_angle_yzy`, t2 in [0, pi].
pub fn extract_euler_angle_yzy<T: Float>(m: Mat<T, 4, 4>) (T, T, T) {
    let (a, b, c) = (m.c[0].e, m.c[1].e, m.c[2].e);
    let t1 = b[2].atan2(-b[0]);
    let s2 = (a[1] * a[1] + c[1] * c[1]).sqrt();
    let t2 = s2.atan2(b[1]);
    let s1 = t1.sin();
    let c1 = t1.cos();
    let t3 = (-s1 * a[0] - c1 * a[2]).atan2(s1 * c[0] + c1 * c[2]);
    return (t1, t2, t3);
}

/// The angles (t1, t2, t3) of `euler_angle_zyz`, t2 in [0, pi].
pub fn extract_euler_angle_zyz<T: Float>(m: Mat<T, 4, 4>) (T, T, T) {
    let (a, b, c) = (m.c[0].e, m.c[1].e, m.c[2].e);
    let t1 = c[1].atan2(c[0]);
    let s2 = (a[2] * a[2] + b[2] * b[2]).sqrt();
    let t2 = s2.atan2(c[2]);
    let s1 = t1.sin();
    let c1 = t1.cos();
    let t3 = (c1 * a[1] - s1 * a[0]).atan2(c1 * b[1] - s1 * b[0]);
    return (t1, t2, t3);
}

/// The angles (t1, t2, t3) of `euler_angle_zxz`, t2 in [0, pi].
pub fn extract_euler_angle_zxz<T: Float>(m: Mat<T, 4, 4>) (T, T, T) {
    let (a, b, c) = (m.c[0].e, m.c[1].e, m.c[2].e);
    let t1 = c[0].atan2(-c[1]);
    let s2 = (a[2] * a[2] + b[2] * b[2]).sqrt();
    let t2 = s2.atan2(c[2]);
    let s1 = t1.sin();
    let c1 = t1.cos();
    let t3 = (-c1 * b[0] - s1 * b[1]).atan2(c1 * a[0] + s1 * a[1]);
    return (t1, t2, t3);
}

/// The angles (t1, t2, t3) of `euler_angle_xzy`, t2 in [-pi/2, pi/2].
pub fn extract_euler_angle_xzy<T: Float>(m: Mat<T, 4, 4>) (T, T, T) {
    let (a, b, c) = (m.c[0].e, m.c[1].e, m.c[2].e);
    let t1 = b[2].atan2(b[1]);
    let c2 = (a[0] * a[0] + c[0] * c[0]).sqrt();
    let t2 = (-b[0]).atan2(c2);
    let s1 = t1.sin();
    let c1 = t1.cos();
    let t3 = (s1 * a[1] - c1 * a[2]).atan2(c1 * c[2] - s1 * c[1]);
    return (t1, t2, t3);
}

/// The angles (t1, t2, t3) of `euler_angle_yzx`, t2 in [-pi/2, pi/2].
pub fn extract_euler_angle_yzx<T: Float>(m: Mat<T, 4, 4>) (T, T, T) {
    let (a, b, c) = (m.c[0].e, m.c[1].e, m.c[2].e);
    let t1 = (-a[2]).atan2(a[0]);
    let c2 = (b[1] * b[1] + c[1] * c[1]).sqrt();
    let t2 = a[1].atan2(c2);
    let s1 = t1.sin();
    let c1 = t1.cos();
    let t3 = (s1 * b[0] + c1 * b[2]).atan2(s1 * c[0] + c1 * c[2]);
    return (t1, t2, t3);
}

/// The angles (t1, t2, t3) of `euler_angle_zyx`, t2 in [-pi/2, pi/2].
pub fn extract_euler_angle_zyx<T: Float>(m: Mat<T, 4, 4>) (T, T, T) {
    let (a, b, c) = (m.c[0].e, m.c[1].e, m.c[2].e);
    let t1 = a[1].atan2(a[0]);
    let c2 = (b[2] * b[2] + c[2] * c[2]).sqrt();
    let t2 = (-a[2]).atan2(c2);
    let s1 = t1.sin();
    let c1 = t1.cos();
    let t3 = (s1 * c[0] - c1 * c[1]).atan2(c1 * b[1] - s1 * b[0]);
    return (t1, t2, t3);
}

/// The angles (t1, t2, t3) of `euler_angle_zxy`, t2 in [-pi/2, pi/2].
pub fn extract_euler_angle_zxy<T: Float>(m: Mat<T, 4, 4>) (T, T, T) {
    let (a, b, c) = (m.c[0].e, m.c[1].e, m.c[2].e);
    let t1 = (-b[0]).atan2(b[1]);
    let c2 = (a[2] * a[2] + c[2] * c[2]).sqrt();
    let t2 = b[2].atan2(c2);
    let s1 = t1.sin();
    let c1 = t1.cos();
    let t3 = (c1 * c[0] + s1 * c[1]).atan2(c1 * a[0] + s1 * a[1]);
    return (t1, t2, t3);
}

fn cos_sin3<T: Float>(t1: T, t2: T, t3: T) (T, T, T, T, T, T) {
    return (t1.cos(), t1.sin(), t2.cos(), t2.sin(), t3.cos(), t3.sin());
}

extend<T: Float> T as Orientate3<T> {
    pub fn orientate3(self: T) Mat<T, 3, 3> {
        let c = self.cos();
        let s = self.sin();
        let (o, l) = (T::zero(), T::one());
        return Mat::<T, 3, 3>::new(c, s, o, -s, c, o, o, o, l);
    }
}

extend<T: Float> Vec<T, 3> as Orientate3<T> {
    pub fn orientate3(self: Vec<T, 3>) Mat<T, 3, 3> {
        return Mat::<T, 3, 3>::from_mat(yaw_pitch_roll(self.e[2], self.e[0], self.e[1]));
    }
}
