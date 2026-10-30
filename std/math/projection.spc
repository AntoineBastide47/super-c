// Projections as 4x4 matrices: ortho, frustum, perspective, perspective_fov and the infinite
// perspectives, then project, unproject and pick_matrix. `_rh`/`_lh` name the handedness and `_zo`/`_no`
// the depth range (0..1 or -1..1); a name without them is right-handed with depth -1..1. An argument
// outside a function's domain panics (see its Panics line).
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::transform as *;

/// The 2D orthographic projection of [left, right] x [bottom, top], z negated.
pub fn ortho_2d<T: Float>(left: T, right: T, bottom: T, top: T) Mat<T, 4, 4> {
    let mut r = Mat::<T, 4, 4>::identity();
    r.c[0].e[0] = T::from_i64(2) / (right - left);
    r.c[1].e[1] = T::from_i64(2) / (top - bottom);
    r.c[2].e[2] = -T::one();
    r.c[3].e[0] = -(right + left) / (right - left);
    r.c[3].e[1] = -(top + bottom) / (top - bottom);
    return r;
}

/// The left-handed orthographic projection to depth 0..1.
pub fn ortho_lh_zo<T: Float>(left: T, right: T, bottom: T, top: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    let mut r = Mat::<T, 4, 4>::identity();
    r.c[0].e[0] = T::from_i64(2) / (right - left);
    r.c[1].e[1] = T::from_i64(2) / (top - bottom);
    r.c[2].e[2] = T::one() / (z_far - z_near);
    r.c[3].e[0] = -(right + left) / (right - left);
    r.c[3].e[1] = -(top + bottom) / (top - bottom);
    r.c[3].e[2] = -z_near / (z_far - z_near);
    return r;
}

/// The left-handed orthographic projection to depth -1..1.
pub fn ortho_lh_no<T: Float>(left: T, right: T, bottom: T, top: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    let mut r = Mat::<T, 4, 4>::identity();
    r.c[0].e[0] = T::from_i64(2) / (right - left);
    r.c[1].e[1] = T::from_i64(2) / (top - bottom);
    r.c[2].e[2] = T::from_i64(2) / (z_far - z_near);
    r.c[3].e[0] = -(right + left) / (right - left);
    r.c[3].e[1] = -(top + bottom) / (top - bottom);
    r.c[3].e[2] = -(z_far + z_near) / (z_far - z_near);
    return r;
}

/// The right-handed orthographic projection to depth 0..1.
pub fn ortho_rh_zo<T: Float>(left: T, right: T, bottom: T, top: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    let mut r = Mat::<T, 4, 4>::identity();
    r.c[0].e[0] = T::from_i64(2) / (right - left);
    r.c[1].e[1] = T::from_i64(2) / (top - bottom);
    r.c[2].e[2] = -T::one() / (z_far - z_near);
    r.c[3].e[0] = -(right + left) / (right - left);
    r.c[3].e[1] = -(top + bottom) / (top - bottom);
    r.c[3].e[2] = -z_near / (z_far - z_near);
    return r;
}

/// The right-handed orthographic projection to depth -1..1.
pub fn ortho_rh_no<T: Float>(left: T, right: T, bottom: T, top: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    let mut r = Mat::<T, 4, 4>::identity();
    r.c[0].e[0] = T::from_i64(2) / (right - left);
    r.c[1].e[1] = T::from_i64(2) / (top - bottom);
    r.c[2].e[2] = -T::from_i64(2) / (z_far - z_near);
    r.c[3].e[0] = -(right + left) / (right - left);
    r.c[3].e[1] = -(top + bottom) / (top - bottom);
    r.c[3].e[2] = -(z_far + z_near) / (z_far - z_near);
    return r;
}

/// Same as `ortho_rh_zo`.
pub fn ortho_zo<T: Float>(left: T, right: T, bottom: T, top: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    return ortho_rh_zo(left, right, bottom, top, z_near, z_far);
}

/// Same as `ortho_rh_no`.
pub fn ortho_no<T: Float>(left: T, right: T, bottom: T, top: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    return ortho_rh_no(left, right, bottom, top, z_near, z_far);
}

/// Same as `ortho_lh_no`.
pub fn ortho_lh<T: Float>(left: T, right: T, bottom: T, top: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    return ortho_lh_no(left, right, bottom, top, z_near, z_far);
}

/// Same as `ortho_rh_no`.
pub fn ortho_rh<T: Float>(left: T, right: T, bottom: T, top: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    return ortho_rh_no(left, right, bottom, top, z_near, z_far);
}

/// Same as `ortho_rh_no`.
pub fn ortho<T: Float>(left: T, right: T, bottom: T, top: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    return ortho_rh_no(left, right, bottom, top, z_near, z_far);
}

/// The left-handed perspective projection of the frustum to depth 0..1.
pub fn frustum_lh_zo<T: Float>(left: T, right: T, bottom: T, top: T, near: T, far: T) Mat<T, 4, 4> {
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[0] = T::from_i64(2) * near / (right - left);
    r.c[1].e[1] = T::from_i64(2) * near / (top - bottom);
    r.c[2].e[0] = -(right + left) / (right - left);
    r.c[2].e[1] = -(top + bottom) / (top - bottom);
    r.c[2].e[2] = far / (far - near);
    r.c[2].e[3] = T::one();
    r.c[3].e[2] = -(far * near) / (far - near);
    return r;
}

/// The left-handed perspective projection of the frustum to depth -1..1.
pub fn frustum_lh_no<T: Float>(left: T, right: T, bottom: T, top: T, near: T, far: T) Mat<T, 4, 4> {
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[0] = T::from_i64(2) * near / (right - left);
    r.c[1].e[1] = T::from_i64(2) * near / (top - bottom);
    r.c[2].e[0] = -(right + left) / (right - left);
    r.c[2].e[1] = -(top + bottom) / (top - bottom);
    r.c[2].e[2] = (far + near) / (far - near);
    r.c[2].e[3] = T::one();
    r.c[3].e[2] = -(T::from_i64(2) * far * near) / (far - near);
    return r;
}

/// The right-handed perspective projection of the frustum to depth 0..1.
pub fn frustum_rh_zo<T: Float>(left: T, right: T, bottom: T, top: T, near: T, far: T) Mat<T, 4, 4> {
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[0] = T::from_i64(2) * near / (right - left);
    r.c[1].e[1] = T::from_i64(2) * near / (top - bottom);
    r.c[2].e[0] = (right + left) / (right - left);
    r.c[2].e[1] = (top + bottom) / (top - bottom);
    r.c[2].e[2] = far / (near - far);
    r.c[2].e[3] = T::from_i64(-1);
    r.c[3].e[2] = -(far * near) / (far - near);
    return r;
}

/// The right-handed perspective projection of the frustum to depth -1..1.
pub fn frustum_rh_no<T: Float>(left: T, right: T, bottom: T, top: T, near: T, far: T) Mat<T, 4, 4> {
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[0] = T::from_i64(2) * near / (right - left);
    r.c[1].e[1] = T::from_i64(2) * near / (top - bottom);
    r.c[2].e[0] = (right + left) / (right - left);
    r.c[2].e[1] = (top + bottom) / (top - bottom);
    r.c[2].e[2] = -(far + near) / (far - near);
    r.c[2].e[3] = T::from_i64(-1);
    r.c[3].e[2] = -(T::from_i64(2) * far * near) / (far - near);
    return r;
}

/// Same as `frustum_rh_zo`.
pub fn frustum_zo<T: Float>(left: T, right: T, bottom: T, top: T, near: T, far: T) Mat<T, 4, 4> {
    return frustum_rh_zo(left, right, bottom, top, near, far);
}

/// Same as `frustum_rh_no`.
pub fn frustum_no<T: Float>(left: T, right: T, bottom: T, top: T, near: T, far: T) Mat<T, 4, 4> {
    return frustum_rh_no(left, right, bottom, top, near, far);
}

/// Same as `frustum_lh_no`.
pub fn frustum_lh<T: Float>(left: T, right: T, bottom: T, top: T, near: T, far: T) Mat<T, 4, 4> {
    return frustum_lh_no(left, right, bottom, top, near, far);
}

/// Same as `frustum_rh_no`.
pub fn frustum_rh<T: Float>(left: T, right: T, bottom: T, top: T, near: T, far: T) Mat<T, 4, 4> {
    return frustum_rh_no(left, right, bottom, top, near, far);
}

/// Same as `frustum_rh_no`.
pub fn frustum<T: Float>(left: T, right: T, bottom: T, top: T, near: T, far: T) Mat<T, 4, 4> {
    return frustum_rh_no(left, right, bottom, top, near, far);
}

// Panics unless |aspect - epsilon| > 0: an aspect equal to epsilon or NaN fails the check.
fn check_aspect<T: Float>(aspect: T) {
    assert((aspect - T::epsilon()).abs().greater(T::zero()), "perspective: aspect must not equal epsilon");
}

/// The right-handed perspective projection of vertical field of view `fovy` radians to depth 0..1.
/// Panics: `aspect` equal to `epsilon::<T>()` or NaN.
pub fn perspective_rh_zo<T: Float>(fovy: T, aspect: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    check_aspect(aspect);
    let tan_half_fovy = (fovy / T::from_i64(2)).tan();
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[0] = T::one() / (aspect * tan_half_fovy);
    r.c[1].e[1] = T::one() / tan_half_fovy;
    r.c[2].e[2] = z_far / (z_near - z_far);
    r.c[2].e[3] = -T::one();
    r.c[3].e[2] = -(z_far * z_near) / (z_far - z_near);
    return r;
}

/// The right-handed perspective projection to depth -1..1. Panics as `perspective_rh_zo`.
pub fn perspective_rh_no<T: Float>(fovy: T, aspect: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    check_aspect(aspect);
    let tan_half_fovy = (fovy / T::from_i64(2)).tan();
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[0] = T::one() / (aspect * tan_half_fovy);
    r.c[1].e[1] = T::one() / tan_half_fovy;
    r.c[2].e[2] = -(z_far + z_near) / (z_far - z_near);
    r.c[2].e[3] = -T::one();
    r.c[3].e[2] = -(T::from_i64(2) * z_far * z_near) / (z_far - z_near);
    return r;
}

/// The left-handed perspective projection to depth 0..1. Panics as `perspective_rh_zo`.
pub fn perspective_lh_zo<T: Float>(fovy: T, aspect: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    check_aspect(aspect);
    let tan_half_fovy = (fovy / T::from_i64(2)).tan();
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[0] = T::one() / (aspect * tan_half_fovy);
    r.c[1].e[1] = T::one() / tan_half_fovy;
    r.c[2].e[2] = z_far / (z_far - z_near);
    r.c[2].e[3] = T::one();
    r.c[3].e[2] = -(z_far * z_near) / (z_far - z_near);
    return r;
}

/// The left-handed perspective projection to depth -1..1. Panics as `perspective_rh_zo`.
pub fn perspective_lh_no<T: Float>(fovy: T, aspect: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    check_aspect(aspect);
    let tan_half_fovy = (fovy / T::from_i64(2)).tan();
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[0] = T::one() / (aspect * tan_half_fovy);
    r.c[1].e[1] = T::one() / tan_half_fovy;
    r.c[2].e[2] = (z_far + z_near) / (z_far - z_near);
    r.c[2].e[3] = T::one();
    r.c[3].e[2] = -(T::from_i64(2) * z_far * z_near) / (z_far - z_near);
    return r;
}

/// Same as `perspective_rh_zo`.
pub fn perspective_zo<T: Float>(fovy: T, aspect: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    return perspective_rh_zo(fovy, aspect, z_near, z_far);
}

/// Same as `perspective_rh_no`.
pub fn perspective_no<T: Float>(fovy: T, aspect: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    return perspective_rh_no(fovy, aspect, z_near, z_far);
}

/// Same as `perspective_lh_no`.
pub fn perspective_lh<T: Float>(fovy: T, aspect: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    return perspective_lh_no(fovy, aspect, z_near, z_far);
}

/// Same as `perspective_rh_no`.
pub fn perspective_rh<T: Float>(fovy: T, aspect: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    return perspective_rh_no(fovy, aspect, z_near, z_far);
}

/// Same as `perspective_rh_no`.
pub fn perspective<T: Float>(fovy: T, aspect: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    return perspective_rh_no(fovy, aspect, z_near, z_far);
}

// The (w, h) scale factors of the perspective_fov functions. Panics: `width`, `height` or `fov` not
// greater than 0.
fn fov_scale<T: Float>(fov: T, width: T, height: T) (T, T) {
    assert(width.greater(T::zero()), "perspective_fov: width must be greater than 0");
    assert(height.greater(T::zero()), "perspective_fov: height must be greater than 0");
    assert(fov.greater(T::zero()), "perspective_fov: fov must be greater than 0");
    let h = (T::from_f64(0.5) * fov).cos() / (T::from_f64(0.5) * fov).sin();
    let w = h * height / width;
    return (w, h);
}

/// The right-handed perspective projection of field of view `fov` radians on a `width` x `height`
/// viewport to depth 0..1. Panics: `width`, `height` or `fov` not greater than 0.
pub fn perspective_fov_rh_zo<T: Float>(fov: T, width: T, height: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    let (w, h) = fov_scale(fov, width, height);
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[0] = w;
    r.c[1].e[1] = h;
    r.c[2].e[2] = z_far / (z_near - z_far);
    r.c[2].e[3] = -T::one();
    r.c[3].e[2] = -(z_far * z_near) / (z_far - z_near);
    return r;
}

/// The right-handed perspective projection to depth -1..1. Panics as `perspective_fov_rh_zo`.
pub fn perspective_fov_rh_no<T: Float>(fov: T, width: T, height: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    let (w, h) = fov_scale(fov, width, height);
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[0] = w;
    r.c[1].e[1] = h;
    r.c[2].e[2] = -(z_far + z_near) / (z_far - z_near);
    r.c[2].e[3] = -T::one();
    r.c[3].e[2] = -(T::from_i64(2) * z_far * z_near) / (z_far - z_near);
    return r;
}

/// The left-handed perspective projection to depth 0..1. Panics as `perspective_fov_rh_zo`.
pub fn perspective_fov_lh_zo<T: Float>(fov: T, width: T, height: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    let (w, h) = fov_scale(fov, width, height);
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[0] = w;
    r.c[1].e[1] = h;
    r.c[2].e[2] = z_far / (z_far - z_near);
    r.c[2].e[3] = T::one();
    r.c[3].e[2] = -(z_far * z_near) / (z_far - z_near);
    return r;
}

/// The left-handed perspective projection to depth -1..1. Panics as `perspective_fov_rh_zo`.
pub fn perspective_fov_lh_no<T: Float>(fov: T, width: T, height: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    let (w, h) = fov_scale(fov, width, height);
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[0] = w;
    r.c[1].e[1] = h;
    r.c[2].e[2] = (z_far + z_near) / (z_far - z_near);
    r.c[2].e[3] = T::one();
    r.c[3].e[2] = -(T::from_i64(2) * z_far * z_near) / (z_far - z_near);
    return r;
}

/// Same as `perspective_fov_rh_zo`.
pub fn perspective_fov_zo<T: Float>(fov: T, width: T, height: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    return perspective_fov_rh_zo(fov, width, height, z_near, z_far);
}

/// Same as `perspective_fov_rh_no`.
pub fn perspective_fov_no<T: Float>(fov: T, width: T, height: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    return perspective_fov_rh_no(fov, width, height, z_near, z_far);
}

/// Same as `perspective_fov_lh_no`.
pub fn perspective_fov_lh<T: Float>(fov: T, width: T, height: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    return perspective_fov_lh_no(fov, width, height, z_near, z_far);
}

/// Same as `perspective_fov_rh_no`.
pub fn perspective_fov_rh<T: Float>(fov: T, width: T, height: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    return perspective_fov_rh_no(fov, width, height, z_near, z_far);
}

/// Same as `perspective_fov_rh_no`.
pub fn perspective_fov<T: Float>(fov: T, width: T, height: T, z_near: T, z_far: T) Mat<T, 4, 4> {
    return perspective_fov_rh_no(fov, width, height, z_near, z_far);
}

// The infinite perspective matrices' x and y scales, `2 near / (right - left)` and
// `2 near / (top - bottom)` of the symmetric frustum at `z_near`, computed from the frustum edges
// without simplification: the order of operations sets the result bits.
fn infinite_scale<T: Float>(fovy: T, aspect: T, z_near: T) (T, T) {
    let range = (fovy / T::from_i64(2)).tan() * z_near;
    let left = -range * aspect;
    let right = range * aspect;
    let bottom = -range;
    let top = range;
    return (T::from_i64(2) * z_near / (right - left), T::from_i64(2) * z_near / (top - bottom));
}

/// The right-handed perspective projection with the far plane at infinity, depth -1..1.
pub fn infinite_perspective_rh_no<T: Float>(fovy: T, aspect: T, z_near: T) Mat<T, 4, 4> {
    let (sx, sy) = infinite_scale(fovy, aspect, z_near);
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[0] = sx;
    r.c[1].e[1] = sy;
    r.c[2].e[2] = -T::one();
    r.c[2].e[3] = -T::one();
    r.c[3].e[2] = -T::from_i64(2) * z_near;
    return r;
}

/// The right-handed infinite perspective projection, depth 0..1.
pub fn infinite_perspective_rh_zo<T: Float>(fovy: T, aspect: T, z_near: T) Mat<T, 4, 4> {
    let (sx, sy) = infinite_scale(fovy, aspect, z_near);
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[0] = sx;
    r.c[1].e[1] = sy;
    r.c[2].e[2] = -T::one();
    r.c[2].e[3] = -T::one();
    r.c[3].e[2] = -z_near;
    return r;
}

/// The left-handed infinite perspective projection, depth -1..1.
pub fn infinite_perspective_lh_no<T: Float>(fovy: T, aspect: T, z_near: T) Mat<T, 4, 4> {
    let (sx, sy) = infinite_scale(fovy, aspect, z_near);
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[0] = sx;
    r.c[1].e[1] = sy;
    r.c[2].e[2] = T::one();
    r.c[2].e[3] = T::one();
    r.c[3].e[2] = -T::from_i64(2) * z_near;
    return r;
}

/// The left-handed infinite perspective projection, depth 0..1.
pub fn infinite_perspective_lh_zo<T: Float>(fovy: T, aspect: T, z_near: T) Mat<T, 4, 4> {
    let (sx, sy) = infinite_scale(fovy, aspect, z_near);
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[0] = sx;
    r.c[1].e[1] = sy;
    r.c[2].e[2] = T::one();
    r.c[2].e[3] = T::one();
    r.c[3].e[2] = -z_near;
    return r;
}

/// Same as `infinite_perspective_rh_no`.
pub fn infinite_perspective_rh<T: Float>(fovy: T, aspect: T, z_near: T) Mat<T, 4, 4> {
    return infinite_perspective_rh_no(fovy, aspect, z_near);
}

/// Same as `infinite_perspective_lh_no`.
pub fn infinite_perspective_lh<T: Float>(fovy: T, aspect: T, z_near: T) Mat<T, 4, 4> {
    return infinite_perspective_lh_no(fovy, aspect, z_near);
}

/// Same as `infinite_perspective_rh_no`.
pub fn infinite_perspective<T: Float>(fovy: T, aspect: T, z_near: T) Mat<T, 4, 4> {
    return infinite_perspective_rh_no(fovy, aspect, z_near);
}

/// The right-handed infinite perspective projection with depth -1..1 shrunk by `ep`, so that the far
/// plane clips no point (Lengyel).
pub fn tweaked_infinite_perspective_ep<T: Float>(fovy: T, aspect: T, z_near: T, ep: T) Mat<T, 4, 4> {
    let (sx, sy) = infinite_scale(fovy, aspect, z_near);
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[0] = sx;
    r.c[1].e[1] = sy;
    r.c[2].e[2] = ep - T::one();
    r.c[2].e[3] = T::from_i64(-1);
    r.c[3].e[2] = (ep - T::from_i64(2)) * z_near;
    return r;
}

/// `tweaked_infinite_perspective_ep` with `ep = epsilon::<T>()`.
pub fn tweaked_infinite_perspective<T: Float>(fovy: T, aspect: T, z_near: T) Mat<T, 4, 4> {
    return tweaked_infinite_perspective_ep(fovy, aspect, z_near, T::epsilon());
}

// `obj` through `model` and `proj`, divided by w: the first steps of `project_zo` and `project_no`.
fn clip_of<T: Float>(obj: Vec<T, 3>, model: Mat<T, 4, 4>, proj: Mat<T, 4, 4>) Vec<T, 4> {
    let mut tmp = obj.append(T::one());
    tmp = model * tmp;
    tmp = proj * tmp;
    return tmp / tmp.e[3];
}

/// The window coordinates of the object point `obj` for clip depth 0..1, with the viewport (x, y,
/// width, height); z is the depth unchanged.
pub fn project_zo<T: Float, U: Scalar>(obj: Vec<T, 3>, model: Mat<T, 4, 4>, proj: Mat<T, 4, 4>, viewport: Vec<U, 4>) Vec<
    T,
    3
> {
    let mut tmp = clip_of(obj, model, proj);
    let half = T::from_f64(0.5);
    tmp.e[0] = tmp.e[0] * half + half;
    tmp.e[1] = tmp.e[1] * half + half;
    tmp.e[0] = tmp.e[0] * viewport.e[2].cast::<T>() + viewport.e[0].cast::<T>();
    tmp.e[1] = tmp.e[1] * viewport.e[3].cast::<T>() + viewport.e[1].cast::<T>();
    return tmp.xyz();
}

/// The window coordinates of `obj` for clip depth -1..1; z maps to 0..1.
pub fn project_no<T: Float, U: Scalar>(obj: Vec<T, 3>, model: Mat<T, 4, 4>, proj: Mat<T, 4, 4>, viewport: Vec<U, 4>) Vec<
    T,
    3
> {
    let mut tmp = clip_of(obj, model, proj);
    let half = T::from_f64(0.5);
    tmp = tmp * half + half;
    tmp.e[0] = tmp.e[0] * viewport.e[2].cast::<T>() + viewport.e[0].cast::<T>();
    tmp.e[1] = tmp.e[1] * viewport.e[3].cast::<T>() + viewport.e[1].cast::<T>();
    return tmp.xyz();
}

/// Same as `project_no`.
pub fn project<T: Float, U: Scalar>(obj: Vec<T, 3>, model: Mat<T, 4, 4>, proj: Mat<T, 4, 4>, viewport: Vec<U, 4>) Vec<
    T,
    3
> {
    return project_no(obj, model, proj, viewport);
}

/// The object point of the window point `win` for clip depth 0..1, through `inverse(proj * model)`;
/// the inverse of `project_zo`.
pub fn unproject_zo<T: Float, U: Scalar>(win: Vec<T, 3>, model: Mat<T, 4, 4>, proj: Mat<T, 4, 4>, viewport: Vec<U, 4>) Vec<
    T,
    3
> {
    let inv = inverse(proj * model);
    let mut tmp = win.append(T::one());
    tmp.e[0] = (tmp.e[0] - viewport.e[0].cast::<T>()) / viewport.e[2].cast::<T>();
    tmp.e[1] = (tmp.e[1] - viewport.e[1].cast::<T>()) / viewport.e[3].cast::<T>();
    tmp.e[0] = tmp.e[0] * T::from_i64(2) - T::one();
    tmp.e[1] = tmp.e[1] * T::from_i64(2) - T::one();
    let obj = inv * tmp;
    return (obj / obj.e[3]).xyz();
}

/// The object point of `win` for clip depth -1..1; the inverse of `project_no`.
pub fn unproject_no<T: Float, U: Scalar>(win: Vec<T, 3>, model: Mat<T, 4, 4>, proj: Mat<T, 4, 4>, viewport: Vec<U, 4>) Vec<
    T,
    3
> {
    let inv = inverse(proj * model);
    let mut tmp = win.append(T::one());
    tmp.e[0] = (tmp.e[0] - viewport.e[0].cast::<T>()) / viewport.e[2].cast::<T>();
    tmp.e[1] = (tmp.e[1] - viewport.e[1].cast::<T>()) / viewport.e[3].cast::<T>();
    tmp = tmp * T::from_i64(2) - T::one();
    let obj = inv * tmp;
    return (obj / obj.e[3]).xyz();
}

/// Same as `unproject_no`.
pub fn unproject<T: Float, U: Scalar>(win: Vec<T, 3>, model: Mat<T, 4, 4>, proj: Mat<T, 4, 4>, viewport: Vec<U, 4>) Vec<
    T,
    3
> {
    return unproject_no(win, model, proj, viewport);
}

/// The matrix that maps the `delta`-sized region around the window point `center` onto the whole
/// viewport (x, y, width, height). Panics: a component of `delta` not greater than 0.
pub fn pick_matrix<T: Float, U: Scalar>(center: Vec<T, 2>, delta: Vec<T, 2>, viewport: Vec<U, 4>) Mat<T, 4, 4> {
    assert(delta.e[0].greater(T::zero()) && delta.e[1].greater(T::zero()), "pick_matrix: delta must be positive");
    let (vx, vy) = (viewport.e[0].cast::<T>(), viewport.e[1].cast::<T>());
    let (vw, vh) = (viewport.e[2].cast::<T>(), viewport.e[3].cast::<T>());
    let two = T::from_i64(2);
    let temp = Vec::<T, 3>::new(
        (vw - two * (center.e[0] - vx)) / delta.e[0],
        (vh - two * (center.e[1] - vy)) / delta.e[1],
        T::zero(),
    );
    let r = translate(Mat::<T, 4, 4>::identity(), temp);
    return scale(r, Vec::<T, 3>::new(vw / delta.e[0], vh / delta.e[1], T::one()));
}
