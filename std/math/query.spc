// Vector and matrix predicates: collinearity, orthogonality, normalization and nullness tests against
// an epsilon. Comparisons follow IEEE, so a NaN fails every test, and `abs` is `x >= 0 ? x : -x`.
// `is_null` and `is_normalized` take a vector or a square matrix through `NormQuery`.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::geometric as *;
import std::math::common as *;

/// A value `is_null` and `is_normalized` take: an f32 or f64 vector, or a 2x2, 3x3 or 4x4 matrix
/// of them.
pub interface NormQuery<T: Float>: Copy {
    fn is_null(self: Self, epsilon: T) bool;
    fn is_normalized(self: Self, epsilon: T) bool;
}

/// `length(v) <= epsilon` for a vector; for a matrix, every column null.
pub fn is_null<T: Float, G: NormQuery<T>>(x: G, epsilon: T) bool {
    return x.is_null(epsilon);
}

/// `|length(v) - 1| <= 2 epsilon` for a vector; for a matrix, every column and
/// every row normalized.
pub fn is_normalized<T: Float, G: NormQuery<T>>(x: G, epsilon: T) bool {
    return x.is_normalized(epsilon);
}

/// `length(cross(v0, v1)) < epsilon`, a vec2 extended with z = 0 and a vec4 cut to its x, y and z.
/// Only 2, 3 or 4 components (another size is a compile error).
pub fn are_collinear<T: Float, const N: usize>(v0: Vec<T, N>, v1: Vec<T, N>, epsilon: T) bool {
    static_assert(N >= 2 && N <= 4, "are_collinear of 2, 3 or 4 components");
    return xyz_of(v0).cross(xyz_of(v1)).length().less(epsilon);
}

/// `|dot(v0, v1)| <= max(1, length(v0)) * max(1, length(v1)) * epsilon`, with
/// `max(a, b) = (a < b) ? b : a`, so a NaN length counts as 1.
pub fn are_orthogonal<T: Float, const N: usize>(v0: Vec<T, N>, v1: Vec<T, N>, epsilon: T) bool {
    let bound = max(T::one(), v0.length()) * max(T::one(), v1.length()) * epsilon;
    return abs(v0.dot(v1)).less_equal(bound);
}

/// `|v[i]| < epsilon` per component. Only 2, 3 or 4 components (another size is a compile error).
pub fn is_comp_null<T: Float, const N: usize>(v: Vec<T, N>, epsilon: T) Vec<bool, N> {
    static_assert(N >= 2 && N <= 4, "is_comp_null of 2, 3 or 4 components");
    let mut r = Vec::<bool, N>::splat(false);
    for i in 0..N {
        unsafe {
            r.e[i] = abs(v.e[i]).less(epsilon);
        }
    }
    return r;
}

/// `v0` and `v1` normalized and `|dot(v0, v1)| <= epsilon`.
pub fn are_orthonormal<T: Float, const N: usize>(v0: Vec<T, N>, v1: Vec<T, N>, epsilon: T) bool {
    return v0.is_normalized(epsilon) && v1.is_normalized(epsilon) && abs(v0.dot(v1)).less_equal(epsilon);
}

/// Every diagonal element within `epsilon` of 1 and every other element within `epsilon` of 0, for
/// any shape and element type. An 8- or 16-bit integer's `m[i][i] - 1` is computed in i64: it neither
/// wraps nor narrows.
pub fn is_identity<T: Scalar, const C: usize, const R: usize>(m: Mat<T, C, R>, epsilon: T) bool {
    for i in 0..C {
        for j in 0..R {
            let x = unsafe m.c[i].e[j];
            let within = if i != j {
                abs(x).less_equal(epsilon)
            } else if !T::is_float() && sizeof(T) <= 2 {
                abs(x.cast::<i64>() - 1) <= epsilon.cast::<i64>()
            } else {
                abs(x - T::one()).less_equal(epsilon)
            };
            if !within {
                return false;
            }
        }
    }
    return true;
}

/// The columns of the square matrix `m` normalized and pairwise orthogonal
/// (`|dot| <= epsilon`), and its rows too.
pub fn is_orthogonal<T: Float, const N: usize>(m: Mat<T, N, N>, epsilon: T) bool {
    return columns_orthonormal(m, epsilon) && columns_orthonormal(transpose(m), epsilon);
}

// The vec3 `are_collinear` crosses: x, y and z, with z = 0 for a vec2.
fn xyz_of<T: Float, const N: usize>(v: Vec<T, N>) Vec<T, 3> {
    let z = if N == 2 {
        T::zero()
    } else {
        unsafe v.e[2]
    };
    return Vec::<T, 3>::new(v.e[0], v.e[1], z);
}

fn columns_null<T: Float, const N: usize>(m: Mat<T, N, N>, epsilon: T) bool {
    for i in 0..N {
        if !unsafe m.c[i].is_null(epsilon) {
            return false;
        }
    }
    return true;
}

fn lines_normalized<T: Float, const N: usize>(m: Mat<T, N, N>, epsilon: T) bool {
    for i in 0..N {
        if !unsafe m.c[i].is_normalized(epsilon) {
            return false;
        }
    }
    for i in 0..N {
        if !row(m, i).is_normalized(epsilon) {
            return false;
        }
    }
    return true;
}

// Always inlined, so that `is_orthogonal`'s row pass reuses the column pass's products, as GLM's single
// body does: two out-of-line calls cost about 25% more.
@always_inline
fn columns_orthonormal<T: Float, const N: usize>(m: Mat<T, N, N>, epsilon: T) bool {
    for i in 0..N {
        let ci = unsafe m.c[i];
        if !ci.is_normalized(epsilon) {
            return false;
        }
        for j in i + 1..N {
            if !abs(ci.dot(unsafe m.c[j])).less_equal(epsilon) {
                return false;
            }
        }
    }
    return true;
}

extend<T: Float, const N: usize> Vec<T, N> as NormQuery<T> {
    pub fn is_null(self: Vec<T, N>, epsilon: T) bool {
        return self.length().less_equal(epsilon);
    }
    pub fn is_normalized(self: Vec<T, N>, epsilon: T) bool {
        return abs(self.length() - T::one()).less_equal(T::from_i64(2) * epsilon);
    }
}

extend<T: Float> Mat<T, 2, 2> as NormQuery<T> {
    pub fn is_null(self: Mat<T, 2, 2>, epsilon: T) bool {
        return columns_null(self, epsilon);
    }
    pub fn is_normalized(self: Mat<T, 2, 2>, epsilon: T) bool {
        return lines_normalized(self, epsilon);
    }
}

extend<T: Float> Mat<T, 3, 3> as NormQuery<T> {
    pub fn is_null(self: Mat<T, 3, 3>, epsilon: T) bool {
        return columns_null(self, epsilon);
    }
    pub fn is_normalized(self: Mat<T, 3, 3>, epsilon: T) bool {
        return lines_normalized(self, epsilon);
    }
}

extend<T: Float> Mat<T, 4, 4> as NormQuery<T> {
    pub fn is_null(self: Mat<T, 4, 4>, epsilon: T) bool {
        return columns_null(self, epsilon);
    }
    pub fn is_normalized(self: Mat<T, 4, 4>, epsilon: T) bool {
        return lines_normalized(self, epsilon);
    }
}
