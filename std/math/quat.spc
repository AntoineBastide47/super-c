// `Quat<T>`: a quaternion stored x, y, z, w and built w first (`Quat::new(w, x, y, z)`), with its
// common, exponential, geometric, relational, transform and trigonometric functions. `q * v` rotates
// `v`, `v * q` rotates it by the inverse. A function name shared with vectors is a conformance to the
// vector function's dispatch interface. `cross(q, p)` is the Hamilton product and `rotate(q, angle, v)`
// turns `q`, so the functions that rotate a vector are `cross_quat_vec`, `cross_vec_quat` and
// `quat_rotate`.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::common as *;
import std::math::elementary as *;
import std::math::geometric as *;
import std::math::compare as *;
import std::math::transform as *;

/// A quaternion `w + xi + yj + zk`.
pub struct Quat<T: Float> {
    pub x: T,
    pub y: T,
    pub z: T,
    pub w: T,
}

pub type quat = Quat<f32>;
pub type fquat = Quat<f32>;
pub type f32quat = Quat<f32>;
pub type dquat = Quat<f64>;
pub type f64quat = Quat<f64>;

/// A value `slerp(x, y, a)` takes: a quaternion, or a unit `Vec<T, 3>` (transform.spc).
pub interface Slerp<T: Float>: Copy {
    fn slerp(self: Self, y: Self, a: T) Self;
}

/// A value `lerp(x, y, a)` takes: a quaternion, or a dual quaternion (dual_quat.spc).
pub interface Lerp<T: Float>: Copy {
    fn lerp(self: Self, y: Self, a: T) Self;
}

/// A vector `quat_rotate(q, v)` takes: a `Vec<T, 3>` or a `Vec<T, 4>`.
pub interface QuatRotate<T: Float>: Copy {
    /// `self` rotated by `q`.
    fn quat_rotate(self: Self, q: Quat<T>) Self;
}

extend<T: Float> Quat<T> {
    /// The quaternion `w + xi + yj + zk`, real part first.
    pub const fn new(w: T, x: T, y: T, z: T) Quat<T> {
        return Quat::<T> { x: x, y: y, z: z, w: w };
    }
    /// The real part `s`, the vector part `v`.
    pub const fn from_scalar_vec(s: T, v: Vec<T, 3>) Quat<T> {
        return Quat::<T> { x: v.e[0], y: v.e[1], z: v.e[2], w: s };
    }
    /// The number of components.
    pub const LEN: usize = 4;

    /// 4; an open-ended range (`q[1..]`) ends there.
    pub const fn len(self: &Quat<T>) usize {
        return 4;
    }
    /// The identity rotation `1 + 0i + 0j + 0k`.
    pub fn identity() Quat<T> {
        return Quat::<T> { x: T::zero(), y: T::zero(), z: T::zero(), w: T::one() };
    }
    /// Each component converted to `U` with `as`.
    pub fn cast<U: Float>(self: Quat<T>) Quat<U> {
        return Quat::<U> { x: self.x.cast::<U>(), y: self.y.cast::<U>(), z: self.z.cast::<U>(), w: self.w.cast::<U>() };
    }
    /// The normalized rotation that turns `u` onto `v`; for opposite vectors a half turn around an axis
    /// orthogonal to `u`.
    pub fn from_vectors(u: Vec<T, 3>, v: Vec<T, 3>) Quat<T> {
        let norm_u_norm_v = (dot(u, u) * dot(v, v)).sqrt();
        let real_part = norm_u_norm_v + dot(u, v);
        if real_part.less(T::from_f32(1e-6) * norm_u_norm_v) {
            let t = if u.e[0].abs().greater(u.e[2].abs()) {
                Vec::<T, 3>::new(-u.e[1], u.e[0], T::zero());
            } else {
                Vec::<T, 3>::new(T::zero(), -u.e[2], u.e[1]);
            };
            return normalize(Quat::<T>::new(T::zero(), t.e[0], t.e[1], t.e[2]));
        }
        let t = cross(u, v);
        return normalize(Quat::<T>::new(real_part, t.e[0], t.e[1], t.e[2]));
    }
    /// The rotation of the Euler angles (pitch, yaw, roll) in radians.
    pub fn from_euler(angles: Vec<T, 3>) Quat<T> {
        let c = cos(angles * T::from_f64(0.5));
        let s = sin(angles * T::from_f64(0.5));
        return Quat::<T>::new(
            c.e[0] * c.e[1] * c.e[2] + s.e[0] * s.e[1] * s.e[2],
            s.e[0] * c.e[1] * c.e[2] - c.e[0] * s.e[1] * s.e[2],
            c.e[0] * s.e[1] * c.e[2] + s.e[0] * c.e[1] * s.e[2],
            c.e[0] * c.e[1] * s.e[2] - s.e[0] * s.e[1] * c.e[2],
        );
    }
    /// `quat_cast(m)` of a 3x3 or 4x4 rotation matrix.
    pub fn from_mat<const N: usize>(m: Mat<T, N, N>) Quat<T> {
        return quat_cast(m);
    }
}

// `q[i]` is x, y, z, w for i = 0..3; an index of 4 or more traps.
extend<T: Float> Quat<T> as Index<T, []T> {
    pub fn index(self: &Quat<T>, i: usize) &T {
        return switch i {
            0 => &self.x,
            1 => &self.y,
            2 => &self.z,
            3 => &self.w,
            _ => panic_parts(type_info::<Self>().qualified_name, "[i]: index out of bounds"),
        };
    }
    pub fn index_range(self: &Quat<T>, r: Range<usize>) []T {
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        if r.start > hi || hi > 4 {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        return unsafe Slice::<T> { ptr: (&self.x) as *const T + r.start, len: hi - r.start };
    }
}

extend<T: Float> Quat<T> as IndexMut<T, []mut T> {
    pub fn index_mut(self: &mut Quat<T>, i: usize) &mut T {
        return switch i {
            0 => &mut self.x,
            1 => &mut self.y,
            2 => &mut self.z,
            3 => &mut self.w,
            _ => panic_parts(type_info::<Self>().qualified_name, "[i]: index out of bounds"),
        };
    }
    pub fn index_range_mut(self: &mut Quat<T>, r: Range<usize>) []mut T {
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        if r.start > hi || hi > 4 {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        return unsafe SliceMut::<T> { ptr: (&mut self.x) as *mut T + r.start, len: hi - r.start };
    }
}

// `p == q`: x, y, z and w IEEE-equal.
extend<T: Float> Quat<T> as Eq {
    pub fn eq(self: &Quat<T>, other: &Quat<T>) bool {
        return self.x.equal(other.x) && self.y.equal(other.y) && self.z.equal(other.z) && self.w.equal(other.w);
    }
}

extend<T: Float> Quat<T> as Neg {
    type Output = Quat<T>;
    pub fn neg(self: &Quat<T>) Quat<T> {
        return Quat::<T>::new(-self.w, -self.x, -self.y, -self.z);
    }
}

extend<T: Float> Quat<T> as Add {
    type Output = Quat<T>;
    pub fn add(self: &Quat<T>, p: &Quat<T>) Quat<T> {
        return Quat::<T>::new(self.w + p.w, self.x + p.x, self.y + p.y, self.z + p.z);
    }
}

extend<T: Float> Quat<T> as Sub {
    type Output = Quat<T>;
    pub fn sub(self: &Quat<T>, p: &Quat<T>) Quat<T> {
        return Quat::<T>::new(self.w - p.w, self.x - p.x, self.y - p.y, self.z - p.z);
    }
}

// The Hamilton product; each component sums its four products left to right.
extend<T: Float> Quat<T> as Mul {
    type Output = Quat<T>;
    pub fn mul(self: &Quat<T>, q: &Quat<T>) Quat<T> {
        let p = *self;
        return Quat::<T>::new(
            p.w * q.w - p.x * q.x - p.y * q.y - p.z * q.z,
            p.w * q.x + p.x * q.w + p.y * q.z - p.z * q.y,
            p.w * q.y + p.y * q.w + p.z * q.x - p.x * q.z,
            p.w * q.z + p.z * q.w + p.x * q.y - p.y * q.x,
        );
    }
}

extend<T: Float> Quat<T> as Mul<T> {
    type Output = Quat<T>;
    pub fn mul(self: &Quat<T>, s: &T) Quat<T> {
        return Quat::<T>::new(self.w * *s, self.x * *s, self.y * *s, self.z * *s);
    }
}

extend<T: Float> T as Mul<Quat<T>> {
    type Output = Quat<T>;
    pub fn mul(self: &T, q: &Quat<T>) Quat<T> {
        return *q * *self;
    }
}

extend<T: Float> Quat<T> as Div<T> {
    type Output = Quat<T>;
    pub fn div(self: &Quat<T>, s: &T) Quat<T> {
        return Quat::<T>::new(self.w / *s, self.x / *s, self.y / *s, self.z / *s);
    }
}

// `q * v`: v rotated by q, computed as v + ((uv w) + uuv) 2, uv = cross(q.xyz, v), uuv = cross(q.xyz, uv).
extend<T: Float> Quat<T> as Mul<Vec<T, 3>> {
    type Output = Vec<T, 3>;
    pub fn mul(self: &Quat<T>, v: &Vec<T, 3>) Vec<T, 3> {
        let qv = Vec::<T, 3> { e: [self.x, self.y, self.z] };
        let uv = cross(qv, *v);
        let uuv = cross(qv, uv);
        return *v + (uv * self.w + uuv) * T::from_f64(2.0);
    }
}

// `v * q`: v rotated by the inverse of q.
extend<T: Float> Vec<T, 3> as Mul<Quat<T>> {
    type Output = Vec<T, 3>;
    pub fn mul(self: &Vec<T, 3>, q: &Quat<T>) Vec<T, 3> {
        return q.inverse() * *self;
    }
}

// `q * v`: the xyz part rotated, w kept.
extend<T: Float> Quat<T> as Mul<Vec<T, 4>> {
    type Output = Vec<T, 4>;
    pub fn mul(self: &Quat<T>, v: &Vec<T, 4>) Vec<T, 4> {
        let r = *self * Vec::<T, 3> { e: [v.e[0], v.e[1], v.e[2]] };
        return Vec::<T, 4> { e: [r.e[0], r.e[1], r.e[2], v.e[3]] };
    }
}

// `v * q`: v rotated by the inverse of q.
extend<T: Float> Vec<T, 4> as Mul<Quat<T>> {
    type Output = Vec<T, 4>;
    pub fn mul(self: &Vec<T, 4>, q: &Quat<T>) Vec<T, 4> {
        return q.inverse() * *self;
    }
}

// `inverse(q)`: conjugate(q) / dot(q, q).
extend<T: Float> Quat<T> as Invertible {
    pub fn inverse(self: Quat<T>) Quat<T> {
        return conjugate(self) / dot(self, self);
    }
}

// x, y, z, w are contiguous in that order.
extend<T: Float> Quat<T> as ValuePtr<T> {
    pub fn value_ptr(self: &Quat<T>) *const T {
        return &self.x;
    }
    pub fn value_ptr_mut(self: &mut Quat<T>) *mut T {
        return &mut self.x;
    }
}

/// x, y, z, w from the 4 `T`s at `ptr`, in that order (the storage order, not the argument order of
/// `Quat::new`). Safety: `ptr` addresses 4 valid `T`s.
pub unsafe const fn make_quat<T: Float>(ptr: *const T) Quat<T> {
    return Quat::<T> { x: ptr[0], y: ptr[1], z: ptr[2], w: ptr[3] };
}

// The scalar linear blend `x * (1 - a) + y * a`.
fn mix_of<T: Float>(x: T, y: T, a: T) T {
    return x * (T::one() - a) + y * a;
}

/// The conjugate `(w, -x, -y, -z)`.
pub const fn conjugate<T: Float>(q: Quat<T>) Quat<T> {
    return Quat::<T>::new(q.w, -q.x, -q.y, -q.z);
}

/// For quaternions `x * (1 - a) + y * a`, not normalized; for dual quaternions (dual_quat.spc) the
/// linear blend along the shorter arc.
/// Panics: `a` is outside [0, 1] or NaN (assert).
pub fn lerp<T: Float, G: Lerp<T>>(x: G, y: G, a: T) G {
    return x.lerp(y, a);
}

/// For quaternions the spherical interpolation along the shorter arc (`y` negated when
/// `dot(x, y) < 0`), a linear one when the cosine of the angle exceeds `1 - epsilon`; for a `Vec<T, 3>`
/// (transform.spc) the spherical interpolation of two unit vectors.
pub fn slerp<T: Float, G: Slerp<T>>(x: G, y: G, a: T) G {
    return x.slerp(y, a);
}

/// `slerp` with `k` extra half turns added to the arc (`k` full spins of
/// the rotation); a negative `k` turns the other way.
pub fn slerp_spin<T: Float, S: Int>(x: Quat<T>, y: Quat<T>, a: T, k: S) Quat<T> {
    let mut z = y;
    let mut cos_theta = dot(x, y);
    if cos_theta.less(T::zero()) {
        z = -y;
        cos_theta = -cos_theta;
    }
    if cos_theta.greater(T::one() - epsilon::<T>()) {
        return Quat::<T>::new(mix_of(x.w, z.w, a), mix_of(x.x, z.x, a), mix_of(x.y, z.y, a), mix_of(x.z, z.z, a));
    }
    let angle = cos_theta.acos();
    let phi = angle + k.cast::<T>() * pi::<T>();
    return ((angle - a * phi).sin() * x + (a * phi).sin() * z) / angle.sin();
}

/// The rotation angle of the unit quaternion `x` in radians, in [0, 2 pi].
pub fn angle<T: Float>(x: Quat<T>) T {
    if x.w.abs().greater(cos_one_over_two::<T>()) {
        let a = (x.x * x.x + x.y * x.y + x.z * x.z).sqrt().asin() * T::from_i64(2);
        if x.w.less(T::zero()) {
            return pi::<T>() * T::from_i64(2) - a;
        }
        return a;
    }
    return x.w.acos() * T::from_i64(2);
}

/// The rotation axis of the unit quaternion `x`; `(0, 0, 1)` when `1 - w^2 <= 0`.
pub fn axis<T: Float>(x: Quat<T>) Vec<T, 3> {
    let tmp1 = T::one() - x.w * x.w;
    if tmp1.less_equal(T::zero()) {
        return Vec::<T, 3>::new(T::zero(), T::zero(), T::one());
    }
    let tmp2 = T::one() / tmp1.sqrt();
    return Vec::<T, 3>::new(x.x * tmp2, x.y * tmp2, x.z * tmp2);
}

/// The rotation of `angle` radians around the unit axis `v`.
pub fn angle_axis<T: Float>(angle: T, v: Vec<T, 3>) Quat<T> {
    let s = (angle * T::from_f64(0.5)).sin();
    return Quat::<T>::from_scalar_vec((angle * T::from_f64(0.5)).cos(), v * s);
}

/// The Euler angles (pitch, yaw, roll) in radians.
pub fn euler_angles<T: Float>(x: Quat<T>) Vec<T, 3> {
    return Vec::<T, 3>::new(pitch(x), yaw(x), roll(x));
}

/// The rotation around the z axis in radians; 0 where both atan2 arguments are within epsilon of 0.
pub fn roll<T: Float>(q: Quat<T>) T {
    let y = T::from_i64(2) * (q.x * q.y + q.w * q.z);
    let x = q.w * q.w + q.x * q.x - q.y * q.y - q.z * q.z;
    if all(equal_eps(Vec::<T, 2>::new(x, y), Vec::<T, 2>::splat(T::zero()), epsilon::<T>())) {
        return T::zero();
    }
    return y.atan2(x);
}

/// The rotation around the x axis in radians; `2 atan2(x, w)` where both atan2 arguments are within
/// epsilon of 0.
pub fn pitch<T: Float>(q: Quat<T>) T {
    let y = T::from_i64(2) * (q.y * q.z + q.w * q.x);
    let x = q.w * q.w - q.x * q.x - q.y * q.y + q.z * q.z;
    if all(equal_eps(Vec::<T, 2>::new(x, y), Vec::<T, 2>::splat(T::zero()), epsilon::<T>())) {
        return T::from_i64(2) * q.x.atan2(q.w);
    }
    return y.atan2(x);
}

/// The rotation around the y axis in radians, `asin(clamp(-2 (xz - wy), -1, 1))`.
pub fn yaw<T: Float>(q: Quat<T>) T {
    return clamp(T::from_i64(-2) * (q.x * q.z - q.w * q.y), T::from_i64(-1), T::one()).asin();
}

/// The rotation matrix of the unit quaternion `q`.
pub fn mat3_cast<T: Float>(q: Quat<T>) Mat<T, 3, 3> {
    let qxx = q.x * q.x;
    let qyy = q.y * q.y;
    let qzz = q.z * q.z;
    let qxz = q.x * q.z;
    let qxy = q.x * q.y;
    let qyz = q.y * q.z;
    let qwx = q.w * q.x;
    let qwy = q.w * q.y;
    let qwz = q.w * q.z;
    let two = T::from_i64(2);
    return Mat::<T, 3, 3>::new(
        T::one() - two * (qyy + qzz),
        two * (qxy + qwz),
        two * (qxz - qwy),
        two * (qxy - qwz),
        T::one() - two * (qxx + qzz),
        two * (qyz + qwx),
        two * (qxz + qwy),
        two * (qyz - qwx),
        T::one() - two * (qxx + qyy),
    );
}

/// `mat3_cast(q)` in the upper-left 3x3 block of the identity.
pub fn mat4_cast<T: Float>(q: Quat<T>) Mat<T, 4, 4> {
    return Mat::<T, 4, 4>::from_mat(mat3_cast(q));
}

/// The unit quaternion of the rotation in the upper-left 3x3 block of a 3x3 or 4x4 matrix (another
/// size is a compile error), built from its largest diagonal combination.
pub fn quat_cast<T: Float, const N: usize>(m: Mat<T, N, N>) Quat<T> {
    static_assert(N == 3 || N == 4, "quat_cast of a 3x3 or 4x4 matrix");
    let m00 = m.c[0].e[0];
    let m01 = m.c[0].e[1];
    let m02 = m.c[0].e[2];
    let m10 = m.c[1].e[0];
    let m11 = m.c[1].e[1];
    let m12 = m.c[1].e[2];
    let m20 = m.c[2].e[0];
    let m21 = m.c[2].e[1];
    let m22 = m.c[2].e[2];
    let four_x_squared_minus1 = m00 - m11 - m22;
    let four_y_squared_minus1 = m11 - m00 - m22;
    let four_z_squared_minus1 = m22 - m00 - m11;
    let four_w_squared_minus1 = m00 + m11 + m22;
    let mut biggest_index = 0;
    let mut four_biggest_squared_minus1 = four_w_squared_minus1;
    if four_x_squared_minus1.greater(four_biggest_squared_minus1) {
        four_biggest_squared_minus1 = four_x_squared_minus1;
        biggest_index = 1;
    }
    if four_y_squared_minus1.greater(four_biggest_squared_minus1) {
        four_biggest_squared_minus1 = four_y_squared_minus1;
        biggest_index = 2;
    }
    if four_z_squared_minus1.greater(four_biggest_squared_minus1) {
        four_biggest_squared_minus1 = four_z_squared_minus1;
        biggest_index = 3;
    }
    let biggest_val = (four_biggest_squared_minus1 + T::one()).sqrt() * T::from_f64(0.5);
    let mult = T::from_f64(0.25) / biggest_val;
    return switch biggest_index {
        0 => Quat::<T>::new(biggest_val, (m12 - m21) * mult, (m20 - m02) * mult, (m01 - m10) * mult),
        1 => Quat::<T>::new((m12 - m21) * mult, biggest_val, (m01 + m10) * mult, (m20 + m02) * mult),
        2 => Quat::<T>::new((m20 - m02) * mult, (m01 + m10) * mult, biggest_val, (m12 + m21) * mult),
        _ => Quat::<T>::new((m01 - m10) * mult, (m20 + m02) * mult, (m12 + m21) * mult, biggest_val),
    };
}

/// `quat_look_at_rh`: right-handed is the default.
pub fn quat_look_at<T: Float>(direction: Vec<T, 3>, up: Vec<T, 3>) Quat<T> {
    return quat_look_at_rh(direction, up);
}

/// The rotation that looks along `direction` (-z forward) with `up` above.
pub fn quat_look_at_rh<T: Float>(direction: Vec<T, 3>, up: Vec<T, 3>) Quat<T> {
    return look_at_basis(-direction, up);
}

/// The rotation that looks along `direction` (+z forward) with `up` above.
pub fn quat_look_at_lh<T: Float>(direction: Vec<T, 3>, up: Vec<T, 3>) Quat<T> {
    return look_at_basis(direction, up);
}

// The body `quat_look_at_rh` and `quat_look_at_lh` share, with `c2` the third column.
fn look_at_basis<T: Float>(c2: Vec<T, 3>, up: Vec<T, 3>) Quat<T> {
    let right = cross(up, c2);
    let c0 = right * inversesqrt(max(T::from_f64(0.00001), dot(right, right)));
    let c1 = cross(c2, c0);
    return quat_cast(Mat::<T, 3, 3>::cols(c0, c1, c2));
}

/// `1 + 0i + 0j + 0k`, as `Quat::identity()`.
pub fn quat_identity<T: Float>() Quat<T> {
    return Quat::<T>::new(T::one(), T::zero(), T::zero(), T::zero());
}

/// `q * v`, `v` rotated by `q`.
pub const fn cross_quat_vec<T: Float>(q: Quat<T>, v: Vec<T, 3>) Vec<T, 3> {
    return q * v;
}

/// `inverse(q) * v`, `v` rotated by the inverse of `q`.
pub fn cross_vec_quat<T: Float>(v: Vec<T, 3>, q: Quat<T>) Vec<T, 3> {
    return q.inverse() * v;
}

/// The point at `h` on the spherical quadrangle of the control points `q1`, `q2` and the intermediate
/// points `s1`, `s2`: `mix(mix(q1, q2, h), mix(s1, s2, h), 2 (1 - h) h)` with the quaternion `mix`.
pub fn squad<T: Float>(q1: Quat<T>, q2: Quat<T>, s1: Quat<T>, s2: Quat<T>, h: T) Quat<T> {
    return q1.mix(q2, h).mix(s1.mix(s2, h), T::from_i64(2) * (T::one() - h) * h);
}

/// The `squad` control point of `curr` between `prev` and `next`,
/// `exp((log(next curr^-1) + log(prev curr^-1)) / -4) curr`. When the two logs cancel to a vector part
/// below epsilon (evenly spaced rotations about one axis) the result is 0, because `exp` gives 0 there.
pub fn intermediate<T: Float>(prev: Quat<T>, curr: Quat<T>, next: Quat<T>) Quat<T> {
    let inv_quat = curr.inverse();
    return (((next * inv_quat).log() + (prev * inv_quat).log()) / T::from_i64(-4)).exp() * curr;
}

/// `q * v`: a `Vec<T, 3>` rotated by `q`, or a `Vec<T, 4>` with its xyz part
/// rotated and w kept.
pub fn quat_rotate<T: Float, V: QuatRotate<T>>(q: Quat<T>, v: V) V {
    return v.quat_rotate(q);
}

/// The w that makes `q` a unit quaternion from its vector part,
/// `-sqrt(1 - x^2 - y^2 - z^2)`, or 0 when that radicand is negative.
pub fn extract_real_component<T: Float>(q: Quat<T>) T {
    let w = T::one() - q.x * q.x - q.y * q.y - q.z * q.z;
    if w.less(T::zero()) {
        return T::zero();
    }
    return -w.sqrt();
}

// `length2(q)`: the squared length, `x^2 + y^2 + z^2 + w^2` summed left to right (not in `dot`'s
// order). `distance2(p0, p1)` is `length2(p1 - p0)`.
extend<T: Float> Quat<T> as Length2<T> {
    pub fn length2(self: Quat<T>) T {
        return self.x * self.x + self.y * self.y + self.z * self.z + self.w * self.w;
    }
    pub fn distance2(self: Quat<T>, p1: Quat<T>) T {
        return (p1 - self).length2();
    }
}

/// `mat3_cast(q)`.
pub fn to_mat3<T: Float>(q: Quat<T>) Mat<T, 3, 3> {
    return mat3_cast(q);
}

/// `mat4_cast(q)`.
pub fn to_mat4<T: Float>(q: Quat<T>) Mat<T, 4, 4> {
    return mat4_cast(q);
}

/// `quat_cast(m)` of a 3x3 or 4x4 rotation matrix (another size is a compile error).
pub fn to_quat<T: Float, const N: usize>(m: Mat<T, N, N>) Quat<T> {
    return quat_cast(m);
}

/// The spherical interpolation along the shorter arc with the angle from
/// `atan2(sqrt(1 - cos^2), cos)`; `x` for `a <= 0`, `y` for `a >= 1`, and a linear blend when the
/// cosine exceeds `1 - epsilon`.
pub fn short_mix<T: Float>(x: Quat<T>, y: Quat<T>, a: T) Quat<T> {
    if a.less_equal(T::zero()) {
        return x;
    }
    if a.greater_equal(T::one()) {
        return y;
    }
    let mut f_cos = dot(x, y);
    let mut y2 = y;
    if f_cos.less(T::zero()) {
        y2 = -y;
        f_cos = -f_cos;
    }
    let k0: T;
    let k1: T;
    if f_cos.greater(T::one() - epsilon::<T>()) {
        k0 = T::one() - a;
        k1 = T::zero() + a;
    } else {
        let f_sin = (T::one() - f_cos * f_cos).sqrt();
        let f_angle = f_sin.atan2(f_cos);
        let f_one_over_sin = T::one() / f_sin;
        k0 = ((T::one() - a) * f_angle).sin() * f_one_over_sin;
        k1 = ((T::zero() + a) * f_angle).sin() * f_one_over_sin;
    }
    return Quat::<T>::new(k0 * x.w + k1 * y2.w, k0 * x.x + k1 * y2.x, k0 * x.y + k1 * y2.y, k0 * x.z + k1 * y2.z);
}

/// `normalize(x * (1 - a) + y * a)`, the normalized linear blend.
pub fn fast_mix<T: Float>(x: Quat<T>, y: Quat<T>, a: T) Quat<T> {
    return normalize(x * (T::one() - a) + y * a);
}

/// The rotation that turns the unit vector `orig` onto the unit vector `dest`. The
/// identity when `dot(orig, dest) >= 1 - epsilon`; for opposite vectors a half turn around
/// `normalize(cross((0, 0, 1), orig))`, or around `normalize(cross((1, 0, 0), orig))` when the first
/// cross product's squared length is below epsilon.
pub fn rotation<T: Float>(orig: Vec<T, 3>, dest: Vec<T, 3>) Quat<T> {
    let cos_theta = dot(orig, dest);
    if cos_theta.greater_equal(T::one() - epsilon::<T>()) {
        return quat_identity::<T>();
    }
    if cos_theta.less(T::from_i64(-1) + epsilon::<T>()) {
        let mut rotation_axis = cross(Vec::<T, 3>::new(T::zero(), T::zero(), T::one()), orig);
        if dot(rotation_axis, rotation_axis).less(epsilon::<T>()) {
            rotation_axis = cross(Vec::<T, 3>::new(T::one(), T::zero(), T::zero()), orig);
        }
        return angle_axis(pi::<T>(), normalize(rotation_axis));
    }
    let rotation_axis = cross(orig, dest);
    let s = ((T::one() + cos_theta) * T::from_i64(2)).sqrt();
    let invs = T::one() / s;
    return Quat::<T>::new(
        s * T::from_f32(0.5),
        rotation_axis.e[0] * invs,
        rotation_axis.e[1] * invs,
        rotation_axis.e[2] * invs,
    );
}

extend<T: Float> Quat<T> as Dot<T> {
    pub fn dot(self: Quat<T>, y: Quat<T>) T {
        return self.w * y.w + self.x * y.x + (self.y * y.y + self.z * y.z);
    }
}

// A quaternion whose length is 0 or less normalizes to the identity; a NaN length gives NaNs.
extend<T: Float> Quat<T> as Normalize {
    pub fn normalize(self: Quat<T>) Quat<T> {
        let len = self.length();
        if len.less_equal(T::zero()) {
            return Quat::<T>::identity();
        }
        let one_over_len = T::one() / len;
        return Quat::<T>::new(
            self.w * one_over_len,
            self.x * one_over_len,
            self.y * one_over_len,
            self.z * one_over_len,
        );
    }
}

// The quaternion `cross` is the Hamilton product.
extend<T: Float> Quat<T> as Cross {
    pub fn cross(self: Quat<T>, y: Quat<T>) Quat<T> {
        return self * y;
    }
}

// The quaternion `mix`: the spherical interpolation along the arc from `x` to `y`, not the shorter
// one; a linear one when the cosine of the angle exceeds `1 - epsilon`.
extend<T: Float> Quat<T> as Mix<T> {
    pub fn mix(self: Quat<T>, y: Quat<T>, a: T) Quat<T> {
        let x = self;
        let cos_theta = dot(x, y);
        if cos_theta.greater(T::one() - epsilon::<T>()) {
            return Quat::<T>::new(mix_of(x.w, y.w, a), mix_of(x.x, y.x, a), mix_of(x.y, y.y, a), mix_of(x.z, y.z, a));
        }
        let angle = cos_theta.acos();
        return (((T::one() - a) * angle).sin() * x + (a * angle).sin() * y) / angle.sin();
    }
}

// `isnan` and `isinf` of x, y, z and w, in that order.
extend<T: Float> Quat<T> as Classify {
    type Bools = Vec<bool, 4>;
    pub fn isnan(self: Quat<T>) Vec<bool, 4> {
        return Vec::<bool, 4>::new(self.x.is_nan(), self.y.is_nan(), self.z.is_nan(), self.w.is_nan());
    }
    pub fn isinf(self: Quat<T>) Vec<bool, 4> {
        return Vec::<bool, 4>::new(self.x.is_inf(), self.y.is_inf(), self.z.is_inf(), self.w.is_inf());
    }
}

// The quaternion `exp` uses the vector part only: `(cos |v|, sin |v| v / |v|)`, and (0, 0, 0, 0) when
// `|v| < epsilon`. `log` is `(log |q|, atan2(|v|, w) v / |v|)`; for `|v| < epsilon` it is `(log w, 0, 0,
// 0)`, `(log -w, pi, 0, 0)`, or infinities for a w of 0 or NaN. `sqrt` is `pow(q, 0.5)`.
extend<T: Float> Quat<T> as Exponential {
    pub fn exp(self: Quat<T>) Quat<T> {
        let u = Vec::<T, 3>::new(self.x, self.y, self.z);
        let angle = length(u);
        if angle.less(epsilon::<T>()) {
            return Quat::<T>::new(T::zero(), T::zero(), T::zero(), T::zero());
        }
        let v = u / angle;
        return Quat::<T>::from_scalar_vec(angle.cos(), angle.sin() * v);
    }
    pub fn log(self: Quat<T>) Quat<T> {
        let u = Vec::<T, 3>::new(self.x, self.y, self.z);
        let vec3_len = length(u);
        if vec3_len.less(epsilon::<T>()) {
            if self.w.greater(T::zero()) {
                return Quat::<T>::new(self.w.ln(), T::zero(), T::zero(), T::zero());
            }
            if self.w.less(T::zero()) {
                return Quat::<T>::new((-self.w).ln(), pi::<T>(), T::zero(), T::zero());
            }
            return Quat::<T>::new(T::infinity(), T::infinity(), T::infinity(), T::infinity());
        }
        let t = vec3_len.atan2(self.w) / vec3_len;
        let quat_len2 = vec3_len * vec3_len + self.w * self.w;
        return Quat::<T>::new(T::from_f64(0.5) * quat_len2.ln(), t * self.x, t * self.y, t * self.z);
    }
    pub fn sqrt(self: Quat<T>) Quat<T> {
        return pow(self, T::from_f64(0.5));
    }
}

// The quaternion `pow(x, y)`: the identity for `|y| < epsilon`; the angle from the vector part when
// `|w| / |x| > cos(1 / 2)`, else from `w`; `(pow(w, y), 0, 0, 0)` when the vector part's squared length
// is below the smallest normal value.
extend<T: Float> Quat<T> as Pow<T> {
    pub fn pow(self: Quat<T>, y: T) Quat<T> {
        let x = self;
        if y.greater(-epsilon::<T>()) && y.less(epsilon::<T>()) {
            return Quat::<T>::identity();
        }
        let magnitude = (x.x * x.x + x.y * x.y + x.z * x.z + x.w * x.w).sqrt();
        let mut angle = (x.w / magnitude).acos();
        if (x.w / magnitude).abs().greater(cos_one_over_two::<T>()) {
            let vector_magnitude = x.x * x.x + x.y * x.y + x.z * x.z;
            if vector_magnitude.less(T::min_positive()) {
                return Quat::<T>::new(x.w.pow(y), T::zero(), T::zero(), T::zero());
            }
            angle = (vector_magnitude.sqrt() / magnitude).asin();
        }
        let new_angle = angle * y;
        let div = new_angle.sin() / angle.sin();
        let mag = magnitude.pow(y - T::one());
        return Quat::<T>::new(new_angle.cos() * magnitude * mag, x.x * div * mag, x.y * div * mag, x.z * div * mag);
    }
}

// Component by component in x, y, z, w order, IEEE.
extend<T: Float> Quat<T> as Relational {
    type Bools = Vec<bool, 4>;
    pub fn equal(self: Quat<T>, y: Quat<T>) Vec<bool, 4> {
        return Vec::<bool, 4>::new(self.x.equal(y.x), self.y.equal(y.y), self.z.equal(y.z), self.w.equal(y.w));
    }
    pub fn not_equal(self: Quat<T>, y: Quat<T>) Vec<bool, 4> {
        return Vec::<bool, 4>::new(
            self.x.not_equal(y.x),
            self.y.not_equal(y.y),
            self.z.not_equal(y.z),
            self.w.not_equal(y.w),
        );
    }
}

// Component by component in x, y, z, w order, IEEE.
extend<T: Float> Quat<T> as Ordered {
    type Bools = Vec<bool, 4>;
    pub fn less_than(self: Quat<T>, y: Quat<T>) Vec<bool, 4> {
        return Vec::<bool, 4>::new(self.x.less(y.x), self.y.less(y.y), self.z.less(y.z), self.w.less(y.w));
    }
    pub fn less_than_equal(self: Quat<T>, y: Quat<T>) Vec<bool, 4> {
        return Vec::<bool, 4>::new(
            self.x.less_equal(y.x),
            self.y.less_equal(y.y),
            self.z.less_equal(y.z),
            self.w.less_equal(y.w),
        );
    }
    pub fn greater_than(self: Quat<T>, y: Quat<T>) Vec<bool, 4> {
        return Vec::<bool, 4>::new(self.x.greater(y.x), self.y.greater(y.y), self.z.greater(y.z), self.w.greater(y.w));
    }
    pub fn greater_than_equal(self: Quat<T>, y: Quat<T>) Vec<bool, 4> {
        return Vec::<bool, 4>::new(
            self.x.greater_equal(y.x),
            self.y.greater_equal(y.y),
            self.z.greater_equal(y.z),
            self.w.greater_equal(y.w),
        );
    }
}

// `equal_eps(x, y, eps)` is strict, unlike the vector one: `abs(x - y) < eps` per component in x, y, z,
// w order; `not_equal_eps` is `abs(x - y) >= eps`.
extend<T: Float> Quat<T> as EqualEps<T> {
    type Bools = Vec<bool, 4>;
    pub fn equal_eps(self: Quat<T>, y: Quat<T>, eps: T) Vec<bool, 4> {
        return less_than(abs(quat_diff(self, y)), Vec::<T, 4>::splat(eps));
    }
    pub fn not_equal_eps(self: Quat<T>, y: Quat<T>, eps: T) Vec<bool, 4> {
        return greater_than_equal(abs(quat_diff(self, y)), Vec::<T, 4>::splat(eps));
    }
}

// `epsilon_equal`: `abs(x - y) < eps` per component in x, y, z, w order; `epsilon_not_equal` is
// `abs(x - y) >= eps`.
extend<T: Float> Quat<T> as EpsilonEqual<T> {
    type Bools = Vec<bool, 4>;
    pub fn epsilon_equal(self: Quat<T>, y: Quat<T>, eps: T) Vec<bool, 4> {
        return less_than(abs(quat_diff(self, y)), Vec::<T, 4>::splat(eps));
    }
    pub fn epsilon_not_equal(self: Quat<T>, y: Quat<T>, eps: T) Vec<bool, 4> {
        return greater_than_equal(abs(quat_diff(self, y)), Vec::<T, 4>::splat(eps));
    }
}

// `(x.x - y.x, x.y - y.y, x.z - y.z, x.w - y.w)`.
const fn quat_diff<T: Float>(x: Quat<T>, y: Quat<T>) Vec<T, 4> {
    return Vec::<T, 4>::new(x.x - y.x, x.y - y.y, x.z - y.z, x.w - y.w);
}

// `rotate(q, angle, v)`: `q * angle_axis(angle, v)`, `v` normalized first when its
// length is more than 0.001 away from 1.
extend<T: Float> Quat<T> as Rotate<T> {
    pub fn rotate(self: Quat<T>, angle: T, v: Vec<T, 3>) Quat<T> {
        let mut tmp = v;
        let len = length(tmp);
        if (len - T::one()).abs().greater(T::from_f64(0.001)) {
            let one_over_len = T::one() / len;
            tmp.e[0] = tmp.e[0] * one_over_len;
            tmp.e[1] = tmp.e[1] * one_over_len;
            tmp.e[2] = tmp.e[2] * one_over_len;
        }
        let sin = (angle * T::from_f64(0.5)).sin();
        return self * Quat::<T>::new((angle * T::from_f64(0.5)).cos(), tmp.e[0] * sin, tmp.e[1] * sin, tmp.e[2] * sin);
    }
}

extend<T: Float> Quat<T> as Slerp<T> {
    pub fn slerp(self: Quat<T>, y: Quat<T>, a: T) Quat<T> {
        let x = self;
        let mut z = y;
        let mut cos_theta = dot(x, y);
        if cos_theta.less(T::zero()) {
            z = -y;
            cos_theta = -cos_theta;
        }
        if cos_theta.greater(T::one() - epsilon::<T>()) {
            return Quat::<T>::new(mix_of(x.w, z.w, a), mix_of(x.x, z.x, a), mix_of(x.y, z.y, a), mix_of(x.z, z.z, a));
        }
        let angle = cos_theta.acos();
        return (((T::one() - a) * angle).sin() * x + (a * angle).sin() * z) / angle.sin();
    }
}

extend<T: Float> Quat<T> as Lerp<T> {
    pub fn lerp(self: Quat<T>, y: Quat<T>, a: T) Quat<T> {
        assert(a.greater_equal(T::zero()) && a.less_equal(T::one()), "lerp: the interpolant is outside [0, 1]");
        return self * (T::one() - a) + y * a;
    }
}

extend<T: Float> Vec<T, 3> as QuatRotate<T> {
    pub fn quat_rotate(self: Vec<T, 3>, q: Quat<T>) Vec<T, 3> {
        return q * self;
    }
}

extend<T: Float> Vec<T, 4> as QuatRotate<T> {
    pub fn quat_rotate(self: Vec<T, 4>, q: Quat<T>) Vec<T, 4> {
        return q * self;
    }
}
