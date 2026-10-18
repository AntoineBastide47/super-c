// Fused forms of the vector functions whose arithmetic is a sum of squares: each square after the first is
// added with one rounding (`fma`), in index order. No square can cancel another, so these keep every exact
// property of the unfused functions, are at least as accurate, and run faster where the CPU has a fused
// multiply-add. Their results differ in the last bits from `length`, `distance` and `normalize`.
// Products whose terms can cancel (`dot`, the matrix products, `cross`, the quaternion product,
// `determinant`) have no fused form: fusing them breaks exact results such as `cross(a, a) == 0`,
// `dot(v, perp(v)) == 0` or a zero determinant for two equal columns.
import std::math::scalar as *;
import std::math::vec as *;

/// The squared length of `v`: `fma(v[N-1], v[N-1], .. fma(v[1], v[1], v[0] * v[0]))`.
pub fn length2_fused<T: Float, const N: usize>(v: Vec<T, N>) T {
    static_assert(N >= 1, "length2_fused of an empty vector");
    let mut s = unsafe v.e[0] * v.e[0];
    for i in 1..N {
        unsafe {
            s = v.e[i].fma(v.e[i], s);
        }
    }
    return s;
}

/// The length of `v`: `sqrt(length2_fused(v))`.
pub fn length_fused<T: Float, const N: usize>(v: Vec<T, N>) T {
    return length2_fused(v).sqrt();
}

/// The squared distance between `p0` and `p1`: `length2_fused(p1 - p0)`.
pub fn distance2_fused<T: Float, const N: usize>(p0: Vec<T, N>, p1: Vec<T, N>) T {
    return length2_fused(p1 - p0);
}

/// The distance between `p0` and `p1`: `length_fused(p1 - p0)`.
pub fn distance_fused<T: Float, const N: usize>(p0: Vec<T, N>, p1: Vec<T, N>) T {
    return length_fused(p1 - p0);
}

/// `v` scaled to length 1: `v * (1 / length_fused(v))`. A zero vector gives NaN components, as
/// `normalize` does.
pub fn normalize_fused<T: Float, const N: usize>(v: Vec<T, N>) Vec<T, N> {
    return v * (T::one() / length_fused(v));
}
