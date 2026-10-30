// Intersection and closest-point tests on f32 and f64 vectors. Each intersection test returns its
// results first and the `bool` hit last: on a miss each result holds the partial value the test
// computed before it failed, or zero when it computed none. The ray-sphere test of a radius, which
// gives the hit point and normal, is `intersect_ray_sphere_point`.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::geometric as *;
import std::math::common as *;

/// (distance, hit) from `orig` along `dir` to the plane through
/// `plane_orig` with normal `plane_normal` (both directions unit length). A ray within epsilon of
/// parallel to the plane, or a plane at or behind `orig`, misses.
pub fn intersect_ray_plane<T: Float, const N: usize>(
    orig: Vec<T, N>,
    dir: Vec<T, N>,
    plane_orig: Vec<T, N>,
    plane_normal: Vec<T, N>,
) (T, bool) {
    let d = dir.dot(plane_normal);
    if abs(d).greater(T::epsilon()) {
        let t = (plane_orig - orig).dot(plane_normal) / d;
        if t.greater(T::zero()) {
            return (t, true);
        }
    }
    return (T::zero(), false);
}

/// Moller-Trumbore test, both faces: (barycentric position, distance, hit)
/// of the ray from `orig` along `dir` and the triangle `v0 v1 v2`: the hit point is
/// `orig + dir * distance`, which is `(1 - b.x - b.y) v0 + b.x v1 + b.y v2`. A ray parallel to the
/// plane (determinant 0 or NaN) misses; a triangle behind `orig` hits with a negative distance.
pub fn intersect_ray_triangle<T: Float>(orig: Vec<T, 3>, dir: Vec<T, 3>, v0: Vec<T, 3>, v1: Vec<T, 3>, v2: Vec<T, 3>) (
    Vec<T, 2>,
    T,
    bool
) {
    let edge1 = v1 - v0;
    let edge2 = v2 - v0;
    let p = dir.cross(edge2);
    let det = edge1.dot(p);
    let front = det.greater(T::zero());
    if !front && !det.less(T::zero()) {
        return (Vec::<T, 2>::zero(), T::zero(), false);
    }
    let dist = orig - v0;
    let u = dist.dot(p);
    let u_out = if front {
        u.less(T::zero()) || u.greater(det)
    } else {
        u.greater(T::zero()) || u.less(det)
    };
    if u_out {
        return (Vec::<T, 2>::new(u, T::zero()), T::zero(), false);
    }
    let perpendicular = dist.cross(edge1);
    let v = dir.dot(perpendicular);
    let v_out = if front {
        v.less(T::zero()) || (u + v).greater(det)
    } else {
        v.greater(T::zero()) || (u + v).less(det)
    };
    if v_out {
        return (Vec::<T, 2>::new(u, v), T::zero(), false);
    }
    let inv_det = T::one() / det;
    return (Vec::<T, 2>::new(u * inv_det, v * inv_det), edge2.dot(perpendicular) * inv_det, true);
}

/// (position, hit) of the line through `orig` along `dir` and the
/// triangle `v0 v1 v2`, with `position = (t, b.x, b.y)`: the line parameter of the hit, then its
/// barycentric coordinates. A determinant within epsilon of 0 misses.
pub fn intersect_line_triangle<T: Float>(orig: Vec<T, 3>, dir: Vec<T, 3>, v0: Vec<T, 3>, v1: Vec<T, 3>, v2: Vec<T, 3>) (
    Vec<T, 3>,
    bool
) {
    let eps = T::epsilon();
    let edge1 = v1 - v0;
    let edge2 = v2 - v0;
    let perpendicular = dir.cross(edge2);
    let det = edge1.dot(perpendicular);
    if det.greater(-eps) && det.less(eps) {
        return (Vec::<T, 3>::zero(), false);
    }
    let inv_det = T::one() / det;
    let tangent = orig - v0;
    let y = tangent.dot(perpendicular) * inv_det;
    if y.less(T::zero()) || y.greater(T::one()) {
        return (Vec::<T, 3>::new(T::zero(), y, T::zero()), false);
    }
    let cotangent = tangent.cross(edge1);
    let z = dir.dot(cotangent) * inv_det;
    if z.less(T::zero()) || (y + z).greater(T::one()) {
        return (Vec::<T, 3>::new(T::zero(), y, z), false);
    }
    return (Vec::<T, 3>::new(edge2.dot(cotangent) * inv_det, y, z), true);
}

/// (distance, hit) from `start` along the unit `dir` to the first crossing of the sphere of squared
/// radius `radius_squared` ahead of `start` (the far one from inside). The distance is
/// computed whenever the line meets the sphere, also on a miss behind `start`.
@always_inline
pub fn intersect_ray_sphere<T: Float, const N: usize>(
    start: Vec<T, N>,
    dir: Vec<T, N>,
    center: Vec<T, N>,
    radius_squared: T,
) (T, bool) {
    // Always inlined: out of line, the C compiler rates this body just over its inline threshold
    // (cost 340, threshold 325), and the call makes a loop of ray tests 2.4 times slower.
    let eps = T::epsilon();
    let diff = center - start;
    let t0 = diff.dot(dir);
    let d_squared = diff.dot(diff) - t0 * t0;
    if d_squared.greater(radius_squared) {
        return (T::zero(), false);
    }
    let t1 = (radius_squared - d_squared).sqrt();
    let distance = if t0.greater(t1 + eps) {
        t0 - t1
    } else {
        t0 + t1
    };
    return (distance, distance.greater(eps));
}

/// (position, normal, hit) of the crossing
/// `intersect_ray_sphere(start, dir, center, radius * radius)` finds, the normal
/// `(position - center) / radius`.
pub fn intersect_ray_sphere_point<T: Float, const N: usize>(
    start: Vec<T, N>,
    dir: Vec<T, N>,
    center: Vec<T, N>,
    radius: T,
) (Vec<T, N>, Vec<T, N>, bool) {
    let (distance, hit) = intersect_ray_sphere(start, dir, center, radius * radius);
    if !hit {
        return (Vec::<T, N>::zero(), Vec::<T, N>::zero(), false);
    }
    let position = start + dir * distance;
    return (position, (position - center) / radius, true);
}

/// (position 1, normal 1, position 2, normal 2, hit) of the line through
/// `point0` and `point1` and the sphere: position 1 is the crossing nearer to `point0` along
/// `point1 - point0` when it lies more than epsilon ahead of `point0`, else the farther one, and
/// position 2 is the other; each normal is `(position - center) / radius`.
pub fn intersect_line_sphere<T: Float, const N: usize>(
    point0: Vec<T, N>,
    point1: Vec<T, N>,
    center: Vec<T, N>,
    radius: T,
) (Vec<T, N>, Vec<T, N>, Vec<T, N>, Vec<T, N>, bool) {
    let eps = T::epsilon();
    let dir = (point1 - point0).normalize();
    let diff = center - point0;
    let t0 = diff.dot(dir);
    let d_squared = diff.dot(diff) - t0 * t0;
    if d_squared.greater(radius * radius) {
        let z = Vec::<T, N>::zero();
        return (z, z, z, z, false);
    }
    let mut t1 = (radius * radius - d_squared).sqrt();
    if t0.less(t1 + eps) {
        t1 = -t1;
    }
    let position1 = point0 + dir * (t0 - t1);
    let position2 = point0 + dir * (t0 + t1);
    return (position1, (position1 - center) / radius, position2, (position2 - center) / radius, true);
}

/// The point of the segment `a b` closest to `point`, `a` or `b` past an end. A degenerate segment
/// (`a == b`) gives NaNs. Only 2 or 3 components (another size is a compile error).
pub fn closest_point_on_line<T: Float, const N: usize>(point: Vec<T, N>, a: Vec<T, N>, b: Vec<T, N>) Vec<T, N> {
    static_assert(N == 2 || N == 3, "closest_point_on_line of 2 or 3 components");
    let ab = b - a;
    let line_length = ab.length();
    let line_direction = ab / line_length;
    let d = (point - a).dot(line_direction);
    if d.less_equal(T::zero()) {
        return a;
    }
    if d.greater_equal(line_length) {
        return b;
    }
    return a + line_direction * d;
}
