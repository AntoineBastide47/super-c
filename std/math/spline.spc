// Spline curves `catmull_rom`, `hermite` and `cubic` at the curve parameter `s`. The curve values are
// vectors, matrices, quaternions or dual quaternions of `T`. Each product is `value * weight`, so
// integer values wrap or trap as the element type's `+` and `*` do.
import std::math::scalar as *;

/// The Catmull-Rom curve through `v2` (at `s` = 0) and `v3` (at `s` = 1), shaped by `v1` and `v4`:
/// `(f1 v1 + f2 v2 + f3 v3 + f4 v4) / 2` with the cubic Catmull-Rom weights of `s`.
pub fn catmull_rom<T: Scalar, G: Copy + Add<Output = G> + Mul<T, Output = G> + Div<T, Output = G>>(
    v1: G,
    v2: G,
    v3: G,
    v4: G,
    s: T,
) G {
    let s2 = s * s;
    let s3 = s * s * s;
    let f1 = -s3 + T::from_i64(2) * s2 - s;
    let f2 = T::from_i64(3) * s3 - T::from_i64(5) * s2 + T::from_i64(2);
    let f3 = T::from_i64(-3) * s3 + T::from_i64(4) * s2 + s;
    let f4 = s3 - s2;
    return (v1 * f1 + v2 * f2 + v3 * f3 + v4 * f4) / T::from_i64(2);
}

/// The Hermite curve from `v1` (at `s` = 0) with tangent `t1` to `v2` (at `s` = 1)
/// with tangent `t2`.
pub fn hermite<T: Scalar, G: Copy + Add<Output = G> + Mul<T, Output = G>>(v1: G, t1: G, v2: G, t2: G, s: T) G {
    let s2 = s * s;
    let s3 = s * s * s;
    let f1 = T::from_i64(2) * s3 - T::from_i64(3) * s2 + T::one();
    let f2 = T::from_i64(-2) * s3 + T::from_i64(3) * s2;
    let f3 = s3 - T::from_i64(2) * s2 + s;
    let f4 = s3 - s2;
    return v1 * f1 + v2 * f2 + t1 * f3 + t2 * f4;
}

/// The polynomial `((v1 s + v2) s + v3) s + v4`.
pub fn cubic<T: Scalar, G: Copy + Add<Output = G> + Mul<T, Output = G>>(v1: G, v2: G, v3: G, v4: G, s: T) G {
    return ((v1 * s + v2) * s + v3) * s + v4;
}
