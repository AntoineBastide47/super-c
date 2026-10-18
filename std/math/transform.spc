// Model and view transforms: translate, rotate, scale, shear and look_at on 4x4 matrices (with the
// `_slow` forms), 2D transforms on 3x3 matrices, decompose and recompose, matrix interpolation and
// vector rotation. `rotate` also takes a quaternion (quat.spc) and a vec3 or vec4, `translate` and
// `scale` a 3x3 matrix with a vec2. One name per argument count: the matrices of a vector alone are
// `translate_matrix`, `rotate_matrix` and `scale_matrix`; the rotation of a 3x3 matrix or a vec2 by an
// angle alone is `rotate_2d`.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::geometric as *;
import std::math::compare as *;
import std::math::quat as *;

/// A value `rotate(x, angle, axis)` takes: a 4x4 matrix, a quaternion, or a `Vec<T, 3>` or `Vec<T, 4>`.
pub interface Rotate<T: Float>: Copy {
    fn rotate(self: Self, angle: T, axis: Vec<T, 3>) Self;
}

/// A value `rotate_2d(x, angle)` takes: a 3x3 matrix or a `Vec<T, 2>`.
pub interface Rotate2d<T: Float>: Copy {
    fn rotate_2d(self: Self, angle: T) Self;
}

/// A vector `rotate_x`, `rotate_y` and `rotate_z` take: a `Vec<T, 3>` or a `Vec<T, 4>`.
pub interface RotateAxis<T: Float>: Copy {
    fn rotate_x(self: Self, angle: T) Self;
    fn rotate_y(self: Self, angle: T) Self;
    fn rotate_z(self: Self, angle: T) Self;
}

/// A matrix `translate(m, v)` takes with its vector `V`: a 4x4 matrix with a `Vec<T, 3>`, or a 3x3
/// matrix with a `Vec<T, 2>`.
pub interface Translate<V>: Copy {
    fn translate(self: Self, v: V) Self;
}

/// A matrix `scale(m, v)` takes with its vector `V`: a 4x4 matrix with a `Vec<T, 3>`, or a 3x3 matrix
/// with a `Vec<T, 2>`.
pub interface Scale<V>: Copy {
    fn scale(self: Self, v: V) Self;
}

/// `x` rotated by `angle` radians around `axis`. For a vector, the rotation matrix
/// `rotate_matrix(angle, axis)` times `x` (its upper-left 3x3 block for a vec3).
pub fn rotate<T: Float, G: Rotate<T>>(x: G, angle: T, axis: Vec<T, 3>) G {
    return x.rotate(angle, axis);
}

/// `m * R` with R the rotation by `angle` radians around `normalize(v)`, built
/// element by element. Rounds differently from `rotate`.
pub fn rotate_slow<T: Float>(m: Mat<T, 4, 4>, angle: T, v: Vec<T, 3>) Mat<T, 4, 4> {
    let c = angle.cos();
    let s = angle.sin();
    let axis = normalize(v);
    let (x, y, z) = (axis.e[0], axis.e[1], axis.e[2]);
    let k = T::one() - c;
    let r = Mat::<T, 4, 4>::new(
        c + k * x * x,
        k * x * y + s * z,
        k * x * z - s * y,
        T::zero(),
        k * y * x - s * z,
        c + k * y * y,
        k * y * z + s * x,
        T::zero(),
        k * z * x + s * y,
        k * z * y - s * x,
        c + k * z * z,
        T::zero(),
        T::zero(),
        T::zero(),
        T::zero(),
        T::one(),
    );
    return m * r;
}

/// For a 4x4 `m`, `m` with column 3 set to `m[0] * v.x + m[1] * v.y + m[2] * v.z + m[3]`; for a 3x3
/// `m`, column 2 set to `m[0] * v.x + m[1] * v.y + m[2]`.
pub fn translate<V, G: Translate<V>>(m: G, v: V) G {
    return m.translate(v);
}

/// The columns of `m` but the last times the components of `v`; the last column
/// unchanged (column 3 of a 4x4 `m`, column 2 of a 3x3 one).
pub fn scale<V, G: Scale<V>>(m: G, v: V) G {
    return m.scale(v);
}

/// `m` times the diagonal matrix (v.x, v.y, v.z, 1).
pub fn scale_slow<T: Scalar>(m: Mat<T, 4, 4>, v: Vec<T, 3>) Mat<T, 4, 4> {
    let mut r = Mat::<T, 4, 4>::identity();
    r.c[0].e[0] = v.e[0];
    r.c[1].e[1] = v.e[1];
    r.c[2].e[2] = v.e[2];
    return m * r;
}

// The shear matrix of `shear` and `shear_slow` about the point `p`.
fn shear_matrix<T: Scalar>(p: Vec<T, 3>, l_x: Vec<T, 2>, l_y: Vec<T, 2>, l_z: Vec<T, 2>) Mat<T, 4, 4> {
    let (xy, xz) = (l_x.e[0], l_x.e[1]);
    let (yx, yz) = (l_y.e[0], l_y.e[1]);
    let (zx, zy) = (l_z.e[0], l_z.e[1]);
    let pl = Vec::<T, 3>::new(xy + xz, yx + yz, zx + zy);
    let (o, z) = (T::one(), T::zero());
    return Mat::<T, 4, 4>::new(
        o,
        yx,
        zx,
        z,
        xy,
        o,
        zy,
        z,
        xz,
        yz,
        o,
        z,
        -pl.e[0] * p.e[0],
        -pl.e[1] * p.e[1],
        -pl.e[2] * p.e[2],
        o,
    );
}

/// `m` times the shear matrix about the point `p` with the ratios `l_x` (xy, xz), `l_y`
/// (yx, yz) and `l_z` (zx, zy); each column sums all four products, zero factors included.
pub fn shear<T: Scalar>(m: Mat<T, 4, 4>, p: Vec<T, 3>, l_x: Vec<T, 2>, l_y: Vec<T, 2>, l_z: Vec<T, 2>) Mat<T, 4, 4> {
    let s = shear_matrix(p, l_x, l_y, l_z);
    let mut r = m;
    for k in 0..4 {
        unsafe {
            r.c[k] = m.c[0] * s.c[k].e[0] + m.c[1] * s.c[k].e[1] + m.c[2] * s.c[k].e[2] + m.c[3] * s.c[k].e[3];
        }
    }
    return r;
}

/// `m * S` with S the shear matrix of `shear`.
pub fn shear_slow<T: Scalar>(m: Mat<T, 4, 4>, p: Vec<T, 3>, l_x: Vec<T, 2>, l_y: Vec<T, 2>, l_z: Vec<T, 2>) Mat<T, 4, 4> {
    return m * shear_matrix(p, l_x, l_y, l_z);
}

/// The right-handed view matrix of a camera at `eye` looking at `center`, `up`
/// giving the vertical. `eye == center` or `up` parallel to the view direction gives NaNs.
pub fn look_at_rh<T: Float>(eye: Vec<T, 3>, center: Vec<T, 3>, up: Vec<T, 3>) Mat<T, 4, 4> {
    let f = normalize(center - eye);
    let s = normalize(cross(f, up));
    let u = cross(s, f);
    let mut r = Mat::<T, 4, 4>::identity();
    r.c[0].e[0] = s.e[0];
    r.c[1].e[0] = s.e[1];
    r.c[2].e[0] = s.e[2];
    r.c[0].e[1] = u.e[0];
    r.c[1].e[1] = u.e[1];
    r.c[2].e[1] = u.e[2];
    r.c[0].e[2] = -f.e[0];
    r.c[1].e[2] = -f.e[1];
    r.c[2].e[2] = -f.e[2];
    r.c[3].e[0] = -dot(s, eye);
    r.c[3].e[1] = -dot(u, eye);
    r.c[3].e[2] = dot(f, eye);
    return r;
}

/// The left-handed view matrix of a camera at `eye` looking at `center`.
pub fn look_at_lh<T: Float>(eye: Vec<T, 3>, center: Vec<T, 3>, up: Vec<T, 3>) Mat<T, 4, 4> {
    let f = normalize(center - eye);
    let s = normalize(cross(up, f));
    let u = cross(f, s);
    let mut r = Mat::<T, 4, 4>::identity();
    r.c[0].e[0] = s.e[0];
    r.c[1].e[0] = s.e[1];
    r.c[2].e[0] = s.e[2];
    r.c[0].e[1] = u.e[0];
    r.c[1].e[1] = u.e[1];
    r.c[2].e[1] = u.e[2];
    r.c[0].e[2] = f.e[0];
    r.c[1].e[2] = f.e[1];
    r.c[2].e[2] = f.e[2];
    r.c[3].e[0] = -dot(s, eye);
    r.c[3].e[1] = -dot(u, eye);
    r.c[3].e[2] = -dot(f, eye);
    return r;
}

/// Same as `look_at_rh`.
pub fn look_at<T: Float>(eye: Vec<T, 3>, center: Vec<T, 3>, up: Vec<T, 3>) Mat<T, 4, 4> {
    return look_at_rh(eye, center, up);
}

/// `translate(identity, v)`, the identity products and sums included.
pub fn translate_matrix<T: Scalar>(v: Vec<T, 3>) Mat<T, 4, 4> {
    return translate(Mat::<T, 4, 4>::identity(), v);
}

/// `rotate(identity, angle, v)`, the rotation by `angle` radians around `normalize(v)` with the
/// identity products and sums included.
pub fn rotate_matrix<T: Float>(angle: T, v: Vec<T, 3>) Mat<T, 4, 4> {
    return rotate(Mat::<T, 4, 4>::identity(), angle, v);
}

/// `scale(identity, v)`.
pub fn scale_matrix<T: Scalar>(v: Vec<T, 3>) Mat<T, 4, 4> {
    return scale(Mat::<T, 4, 4>::identity(), v);
}

/// A 3x3 `m` times the 2D rotation by `angle` radians (column 0 is `m[0] cos + m[1] sin`, column 1
/// `m[0] (-sin) + m[1] cos`), or a vec2 rotated by `angle` radians.
pub fn rotate_2d<T: Float, G: Rotate2d<T>>(x: G, angle: T) G {
    return x.rotate_2d(angle);
}

/// `m` times the identity with element [0][1] set to `y`.
pub fn shear_x<T: Scalar>(m: Mat<T, 3, 3>, y: T) Mat<T, 3, 3> {
    let mut r = Mat::<T, 3, 3>::identity();
    r.c[0].e[1] = y;
    return m * r;
}

/// `m` times the identity with element [1][0] set to `x`.
pub fn shear_y<T: Scalar>(m: Mat<T, 3, 3>, x: T) Mat<T, 3, 3> {
    let mut r = Mat::<T, 3, 3>::identity();
    r.c[1].e[0] = x;
    return m * r;
}

/// `v` rotated by `angle` radians around the x axis; a vec4's w is kept.
pub fn rotate_x<T: Float, G: RotateAxis<T>>(v: G, angle: T) G {
    return v.rotate_x(angle);
}

/// `v` rotated by `angle` radians around the y axis; a vec4's w is kept.
pub fn rotate_y<T: Float, G: RotateAxis<T>>(v: G, angle: T) G {
    return v.rotate_y(angle);
}

/// `v` rotated by `angle` radians around the z axis; a vec4's w is kept.
pub fn rotate_z<T: Float, G: RotateAxis<T>>(v: G, angle: T) G {
    return v.rotate_z(angle);
}

/// `rotate_matrix(acos(dot(normal, up)), cross(up, normal))`, the rotation that turns the unit vector
/// `up` onto the unit vector `normal`; the identity when every component of `normal` is within epsilon
/// of `up`'s. Opposite vectors give NaNs.
pub fn orientation<T: Float>(normal: Vec<T, 3>, up: Vec<T, 3>) Mat<T, 4, 4> {
    if all(equal_eps(normal, up, epsilon::<T>())) {
        return Mat::<T, 4, 4>::identity();
    }
    return rotate_matrix(dot(normal, up).acos(), cross(up, normal));
}

/// Splits the model matrix `m` into (success, scale, orientation, translation, skew, perspective), by
/// the unmatrix algorithm of Graphics Gems II (`recompose` inverts it). False, with every other result
/// zero, when `m[3][3]` or the determinant of `m`'s affine part after normalizing is within epsilon of
/// 0; NaN inputs flow into the results.
pub fn decompose<T: Float>(m: Mat<T, 4, 4>) (bool, Vec<T, 3>, Quat<T>, Vec<T, 3>, Vec<T, 3>, Vec<T, 4>) {
    let zero3 = Vec::<T, 3>::zero();
    let zero_quat = Quat::<T>::new(T::zero(), T::zero(), T::zero(), T::zero());
    let eps = epsilon::<T>();
    let mut local = m;
    if local.c[3].e[3].abs().less(eps) {
        return false, zero3, zero_quat, zero3, zero3, Vec::<T, 4>::zero();
    }
    for i in 0..4 {
        for j in 0..4 {
            unsafe {
                local.c[i].e[j] = local.c[i].e[j] / local.c[3].e[3];
            }
        }
    }
    let mut perspective_matrix = local;
    perspective_matrix.c[0].e[3] = T::zero();
    perspective_matrix.c[1].e[3] = T::zero();
    perspective_matrix.c[2].e[3] = T::zero();
    perspective_matrix.c[3].e[3] = T::one();
    if determinant(perspective_matrix).abs().less(eps) {
        return false, zero3, zero_quat, zero3, zero3, Vec::<T, 4>::zero();
    }
    let mut perspective = Vec::<T, 4>::new(T::zero(), T::zero(), T::zero(), T::one());
    if local.c[0].e[3].abs().greater_equal(eps) || local.c[1].e[3].abs().greater_equal(eps) || local.c[2].e[3].abs().greater_equal(
        eps,
    ) {
        let right_hand_side = Vec::<T, 4>::new(local.c[0].e[3], local.c[1].e[3], local.c[2].e[3], local.c[3].e[3]);
        perspective = transpose(inverse(perspective_matrix)) * right_hand_side;
    }
    let translation = local.c[3].xyz();
    let mut row0 = local.c[0].xyz();
    let mut row1 = local.c[1].xyz();
    let mut row2 = local.c[2].xyz();
    let mut scale = zero3;
    let mut skew = zero3;
    scale.e[0] = length(row0);
    row0 = unit_length(row0);
    skew.e[2] = dot(row0, row1);
    row1 = combine(row1, row0, T::one(), -skew.e[2]);
    scale.e[1] = length(row1);
    row1 = unit_length(row1);
    skew.e[2] = skew.e[2] / scale.e[1];
    skew.e[1] = dot(row0, row2);
    row2 = combine(row2, row0, T::one(), -skew.e[1]);
    skew.e[0] = dot(row1, row2);
    row2 = combine(row2, row1, T::one(), -skew.e[0]);
    scale.e[2] = length(row2);
    row2 = unit_length(row2);
    skew.e[1] = skew.e[1] / scale.e[2];
    skew.e[0] = skew.e[0] / scale.e[2];
    if dot(row0, cross(row1, row2)).less(T::zero()) {
        let minus_one = T::from_i64(-1);
        scale = scale * minus_one;
        row0 = row0 * minus_one;
        row1 = row1 * minus_one;
        row2 = row2 * minus_one;
    }
    return true, scale, decompose_orientation([row0, row1, row2]), translation, skew, perspective;
}

fn unit_length<T: Float>(v: Vec<T, 3>) Vec<T, 3> {
    return v * T::one() / length(v);
}

fn combine<T: Float>(a: Vec<T, 3>, b: Vec<T, 3>, ascl: T, bscl: T) Vec<T, 3> {
    return a * ascl + b * bscl;
}

// The rotation of `decompose`'s orthonormal rows: from the trace when it is positive, else from the
// largest diagonal element.
fn decompose_orientation<T: Float>(rows: [Vec<T, 3>; 3]) Quat<T> {
    let mut q = Quat::<T>::new(T::zero(), T::zero(), T::zero(), T::zero());
    let trace = rows[0].e[0] + rows[1].e[1] + rows[2].e[2];
    if trace.greater(T::zero()) {
        let root = (trace + T::one()).sqrt();
        q.w = T::from_f64(0.5) * root;
        let half_over_root = T::from_f64(0.5) / root;
        q.x = half_over_root * (rows[1].e[2] - rows[2].e[1]);
        q.y = half_over_root * (rows[2].e[0] - rows[0].e[2]);
        q.z = half_over_root * (rows[0].e[1] - rows[1].e[0]);
        return q;
    }
    let mut i: usize = 0;
    if rows[1].e[1].greater(rows[0].e[0]) {
        i = 1;
    }
    if rows[2].e[2].greater(unsafe rows[i][i]) {
        i = 2;
    }
    let j = (i + 1) % 3;
    let k = (j + 1) % 3;
    unsafe {
        let root = (rows[i][i] - rows[j][j] - rows[k][k] + T::one()).sqrt();
        q[i] = T::from_f64(0.5) * root;
        let half_over_root = T::from_f64(0.5) / root;
        q[j] = half_over_root * (rows[i][j] + rows[j][i]);
        q[k] = half_over_root * (rows[i][k] + rows[k][i]);
        q.w = half_over_root * (rows[j][k] - rows[k][j]);
    }
    return q;
}

/// The model matrix `P * translate_matrix(translation) * mat4_cast(orientation) *
/// skews * scale_matrix(scale)`, P the identity with row 3 set to `perspective` and each skew matrix
/// (z-y from `skew.x`, z-x from `skew.y`, y-x from `skew.z`) applied only when its factor is nonzero.
pub fn recompose<T: Float>(
    scale: Vec<T, 3>,
    orientation: Quat<T>,
    translation: Vec<T, 3>,
    skew: Vec<T, 3>,
    perspective: Vec<T, 4>,
) Mat<T, 4, 4> {
    let mut m = Mat::<T, 4, 4>::identity();
    m.c[0].e[3] = perspective.e[0];
    m.c[1].e[3] = perspective.e[1];
    m.c[2].e[3] = perspective.e[2];
    m.c[3].e[3] = perspective.e[3];
    m = m * translate_matrix(translation);
    m = m * mat4_cast(orientation);
    if skew.e[0].abs().greater(T::zero()) {
        let mut tmp = Mat::<T, 4, 4>::identity();
        tmp.c[2].e[1] = skew.e[0];
        m = m * tmp;
    }
    if skew.e[1].abs().greater(T::zero()) {
        let mut tmp = Mat::<T, 4, 4>::identity();
        tmp.c[2].e[0] = skew.e[1];
        m = m * tmp;
    }
    if skew.e[2].abs().greater(T::zero()) {
        let mut tmp = Mat::<T, 4, 4>::identity();
        tmp.c[1].e[0] = skew.e[2];
        m = m * tmp;
    }
    return m * scale_matrix(scale);
}

/// The (axis, angle in radians) of the rotation in the upper-left 3x3 block of `m`. A block symmetric
/// within 100 epsilon is the identity ((1, 0, 0), 0) or a half turn (angle pi, the axis from the
/// diagonal, (0, 0.7071, 0.7071)-like when its largest element is below that epsilon); otherwise the
/// angle is `acos((trace - 1) / 2)` clamped to [0, pi] and the axis the normalized antisymmetric part.
pub fn axis_angle<T: Float>(m: Mat<T, 4, 4>) (Vec<T, 3>, T) {
    let eps = epsilon::<T>() * T::from_f64(1e2);
    let (m00, m01, m02) = (m.c[0].e[0], m.c[0].e[1], m.c[0].e[2]);
    let (m10, m11, m12) = (m.c[1].e[0], m.c[1].e[1], m.c[1].e[2]);
    let (m20, m21, m22) = (m.c[2].e[0], m.c[2].e[1], m.c[2].e[2]);
    let near_symmetrical = (m10 - m01).abs().less(eps) && (m20 - m02).abs().less(eps) && (m21 - m12).abs().less(eps);
    if near_symmetrical {
        let near_identity = (m10 + m01).abs().less(eps) && (m20 + m02).abs().less(eps) && (m21 + m12).abs().less(eps) && (m00 + m11 + m22 - T::from_i64(
            3,
        )).abs().less(eps);
        if near_identity {
            return Vec::<T, 3>::new(T::one(), T::zero(), T::zero()), T::zero();
        }
        let pi = pi::<T>();
        let half = T::from_f64(0.5);
        let xx = (m00 + T::one()) * half;
        let yy = (m11 + T::one()) * half;
        let zz = (m22 + T::one()) * half;
        let xy = (m10 + m01) * T::from_f64(0.25);
        let xz = (m20 + m02) * T::from_f64(0.25);
        let yz = (m21 + m12) * T::from_f64(0.25);
        let h = T::from_f64(0.7071);
        if xx.greater(yy) && xx.greater(zz) {
            if xx.less(eps) {
                return Vec::<T, 3>::new(T::zero(), h, h), pi;
            }
            let x = xx.sqrt();
            return Vec::<T, 3>::new(x, xy / x, xz / x), pi;
        }
        if yy.greater(zz) {
            if yy.less(eps) {
                return Vec::<T, 3>::new(h, T::zero(), h), pi;
            }
            let y = yy.sqrt();
            return Vec::<T, 3>::new(xy / y, y, yz / y), pi;
        }
        if zz.less(eps) {
            return Vec::<T, 3>::new(h, h, T::zero()), pi;
        }
        let z = zz.sqrt();
        return Vec::<T, 3>::new(xz / z, yz / z, z), pi;
    }
    let angle_cos = (m00 + m11 + m22 - T::one()) * T::from_f64(0.5);
    let angle = if angle_cos.greater_equal(T::one()) {
        T::zero();
    } else if angle_cos.less_equal(T::from_i64(-1)) {
        pi::<T>();
    } else {
        angle_cos.acos();
    };
    return normalize(Vec::<T, 3>::new(m12 - m21, m20 - m02, m01 - m10)), angle;
}

/// The 4x4 rotation by `angle` radians around `normalize(axis)`, element by element as
/// `t n_i n_j + c` and `t n_i n_j -+ n_k s` with `t = 1 - c`.
pub fn axis_angle_matrix<T: Float>(axis: Vec<T, 3>, angle: T) Mat<T, 4, 4> {
    let c = angle.cos();
    let s = angle.sin();
    let t = T::one() - c;
    let n = normalize(axis);
    let (x, y, z) = (n.e[0], n.e[1], n.e[2]);
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(
        t * x * x + c,
        t * x * y + z * s,
        t * x * z - y * s,
        o,
        t * x * y - z * s,
        t * y * y + c,
        t * y * z + x * s,
        o,
        t * x * z + y * s,
        t * y * z - x * s,
        t * z * z + c,
        o,
        o,
        o,
        o,
        l,
    );
}

/// The upper-left 3x3 block of `m` in the identity.
pub fn extract_matrix_rotation<T: Float>(m: Mat<T, 4, 4>) Mat<T, 4, 4> {
    let (o, l) = (T::zero(), T::one());
    return Mat::<T, 4, 4>::new(
        m.c[0].e[0],
        m.c[0].e[1],
        m.c[0].e[2],
        o,
        m.c[1].e[0],
        m.c[1].e[1],
        m.c[1].e[2],
        o,
        m.c[2].e[0],
        m.c[2].e[1],
        m.c[2].e[2],
        o,
        o,
        o,
        o,
        l,
    );
}

/// The rotation of `m1` turned by `delta` of the rotation from `m1` to `m2` (`axis_angle` of
/// `m2 * transpose(rotation of m1)`), with the translation of `m1` blended toward `m2`'s by `delta`;
/// row 3 is the rotation's.
pub fn interpolate<T: Float>(m1: Mat<T, 4, 4>, m2: Mat<T, 4, 4>, delta: T) Mat<T, 4, 4> {
    let m1rot = extract_matrix_rotation(m1);
    let (dlt_axis, dlt_angle) = axis_angle(m2 * transpose(m1rot));
    let mut out = axis_angle_matrix(dlt_axis, dlt_angle * delta) * m1rot;
    out.c[3].e[0] = m1.c[3].e[0] + delta * (m2.c[3].e[0] - m1.c[3].e[0]);
    out.c[3].e[1] = m1.c[3].e[1] + delta * (m2.c[3].e[1] - m1.c[3].e[1]);
    out.c[3].e[2] = m1.c[3].e[2] + delta * (m2.c[3].e[2] - m1.c[3].e[2]);
    return out;
}

// `rotate_x`, `rotate_y` and `rotate_z` of a vec3 or vec4 (N = 3 or 4).
fn rotate_x_of<T: Float, const N: usize>(v: Vec<T, N>, angle: T) Vec<T, N> {
    let c = angle.cos();
    let s = angle.sin();
    let mut r = v;
    r.e[1] = v.e[1] * c - v.e[2] * s;
    r.e[2] = v.e[1] * s + v.e[2] * c;
    return r;
}

fn rotate_y_of<T: Float, const N: usize>(v: Vec<T, N>, angle: T) Vec<T, N> {
    let c = angle.cos();
    let s = angle.sin();
    let mut r = v;
    r.e[0] = v.e[0] * c + v.e[2] * s;
    r.e[2] = -v.e[0] * s + v.e[2] * c;
    return r;
}

fn rotate_z_of<T: Float, const N: usize>(v: Vec<T, N>, angle: T) Vec<T, N> {
    let c = angle.cos();
    let s = angle.sin();
    let mut r = v;
    r.e[0] = v.e[0] * c - v.e[1] * s;
    r.e[1] = v.e[0] * s + v.e[1] * c;
    return r;
}

// `m` times the rotation around `normalize(v)`, column by column.
extend<T: Float> Mat<T, 4, 4> as Rotate<T> {
    pub fn rotate(self: Mat<T, 4, 4>, angle: T, v: Vec<T, 3>) Mat<T, 4, 4> {
        let c = angle.cos();
        let s = angle.sin();
        let axis = normalize(v);
        let temp = (T::one() - c) * axis;
        let a = axis.e;
        let t = temp.e;
        let r00 = c + t[0] * a[0];
        let r01 = t[0] * a[1] + s * a[2];
        let r02 = t[0] * a[2] - s * a[1];
        let r10 = t[1] * a[0] - s * a[2];
        let r11 = c + t[1] * a[1];
        let r12 = t[1] * a[2] + s * a[0];
        let r20 = t[2] * a[0] + s * a[1];
        let r21 = t[2] * a[1] - s * a[0];
        let r22 = c + t[2] * a[2];
        let m = self.c;
        return Mat::<T, 4, 4>::cols(
            m[0] * r00 + m[1] * r01 + m[2] * r02,
            m[0] * r10 + m[1] * r11 + m[2] * r12,
            m[0] * r20 + m[1] * r21 + m[2] * r22,
            m[3],
        );
    }
}

extend<T: Float> Vec<T, 3> as Rotate<T> {
    pub fn rotate(self: Vec<T, 3>, angle: T, normal: Vec<T, 3>) Vec<T, 3> {
        return Mat::<T, 3, 3>::from_mat(rotate_matrix(angle, normal)) * self;
    }
}

extend<T: Float> Vec<T, 4> as Rotate<T> {
    pub fn rotate(self: Vec<T, 4>, angle: T, normal: Vec<T, 3>) Vec<T, 4> {
        return rotate_matrix(angle, normal) * self;
    }
}

extend<T: Scalar> Mat<T, 4, 4> as Translate<Vec<T, 3>> {
    pub fn translate(self: Mat<T, 4, 4>, v: Vec<T, 3>) Mat<T, 4, 4> {
        let mut r = self;
        r.c[3] = self.c[0] * v.e[0] + self.c[1] * v.e[1] + self.c[2] * v.e[2] + self.c[3];
        return r;
    }
}

extend<T: Scalar> Mat<T, 3, 3> as Translate<Vec<T, 2>> {
    pub fn translate(self: Mat<T, 3, 3>, v: Vec<T, 2>) Mat<T, 3, 3> {
        let mut r = self;
        r.c[2] = self.c[0] * v.e[0] + self.c[1] * v.e[1] + self.c[2];
        return r;
    }
}

extend<T: Scalar> Mat<T, 4, 4> as Scale<Vec<T, 3>> {
    pub fn scale(self: Mat<T, 4, 4>, v: Vec<T, 3>) Mat<T, 4, 4> {
        return Mat::<T, 4, 4>::cols(self.c[0] * v.e[0], self.c[1] * v.e[1], self.c[2] * v.e[2], self.c[3]);
    }
}

extend<T: Scalar> Mat<T, 3, 3> as Scale<Vec<T, 2>> {
    pub fn scale(self: Mat<T, 3, 3>, v: Vec<T, 2>) Mat<T, 3, 3> {
        return Mat::<T, 3, 3>::cols(self.c[0] * v.e[0], self.c[1] * v.e[1], self.c[2]);
    }
}

extend<T: Float> Mat<T, 3, 3> as Rotate2d<T> {
    pub fn rotate_2d(self: Mat<T, 3, 3>, angle: T) Mat<T, 3, 3> {
        let c = angle.cos();
        let s = angle.sin();
        return Mat::<T, 3, 3>::cols(self.c[0] * c + self.c[1] * s, self.c[0] * -s + self.c[1] * c, self.c[2]);
    }
}

extend<T: Float> Vec<T, 2> as Rotate2d<T> {
    pub fn rotate_2d(self: Vec<T, 2>, angle: T) Vec<T, 2> {
        let c = angle.cos();
        let s = angle.sin();
        return Vec::<T, 2>::new(self.e[0] * c - self.e[1] * s, self.e[0] * s + self.e[1] * c);
    }
}

extend<T: Float> Vec<T, 3> as RotateAxis<T> {
    pub fn rotate_x(self: Vec<T, 3>, angle: T) Vec<T, 3> {
        return rotate_x_of(self, angle);
    }
    pub fn rotate_y(self: Vec<T, 3>, angle: T) Vec<T, 3> {
        return rotate_y_of(self, angle);
    }
    pub fn rotate_z(self: Vec<T, 3>, angle: T) Vec<T, 3> {
        return rotate_z_of(self, angle);
    }
}

extend<T: Float> Vec<T, 4> as RotateAxis<T> {
    pub fn rotate_x(self: Vec<T, 4>, angle: T) Vec<T, 4> {
        return rotate_x_of(self, angle);
    }
    pub fn rotate_y(self: Vec<T, 4>, angle: T) Vec<T, 4> {
        return rotate_y_of(self, angle);
    }
    pub fn rotate_z(self: Vec<T, 4>, angle: T) Vec<T, 4> {
        return rotate_z_of(self, angle);
    }
}

// `slerp(x, y, a)` of two unit vec3s: `x sin((1 - a) alpha) / sin(alpha) + y sin(a alpha) /
// sin(alpha)` with `alpha = acos(dot(x, y))`; equal or opposite vectors divide by a zero sine.
extend<T: Float> Vec<T, 3> as Slerp<T> {
    pub fn slerp(self: Vec<T, 3>, y: Vec<T, 3>, a: T) Vec<T, 3> {
        let alpha = dot(self, y).acos();
        let sin_alpha = alpha.sin();
        let t1 = ((T::one() - a) * alpha).sin() / sin_alpha;
        let t2 = (a * alpha).sin() / sin_alpha;
        return self * t1 + y * t2;
    }
}
