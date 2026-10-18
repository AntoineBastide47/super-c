// Geometric functions on f32 and f64 scalars and vectors: dot, length, distance, cross, normalize,
// faceforward, reflect and refract, then norms, vector angles, triangle normal, projection,
// perpendicular, orthonormalization and polar coordinates. `dot` with `length`, `normalize`, `cross`,
// `refract`, `length2` with `distance2`, and `proj` with `perp` dispatch through an interface that each
// type family conforms to. A norm of the two vectors `a` and `b` (the norm of `b - a`) is
// `*_norm_between`, the angle of two vectors is `vector_angle` (`angle` is the quaternion's), the
// oriented angle of two vec3s about a reference is `oriented_angle_3d`, and the orthonormalization of
// one vec3 against another is `orthonormalize_vec`.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::common as *;

/// A value `dot` and `length` take: an f32 or f64 scalar or vector, or a quaternion.
pub interface Dot<T: Float>: Copy {
    fn dot(self: Self, y: Self) T;
    /// `sqrt(dot(self, self))` unless the conformance defines its own.
    fn length(self: Self) T {
        return self.dot(self).sqrt();
    }
}

/// The dot product: `x * y` for scalars; for vectors the component products summed left to right, a
/// vec4's in pairs: `(x0 y0 + x1 y1) + (x2 y2 + x3 y3)`.
pub fn dot<T: Float, G: Dot<T>>(x: G, y: G) T {
    return x.dot(y);
}

/// The length: `x >= 0 ? x : -x` for a scalar (-0 stays -0), `sqrt(dot(x, x))` for a vector.
pub fn length<T: Float, G: Dot<T>>(x: G) T {
    return x.length();
}

/// The distance `length(p1 - p0)`.
pub fn distance<T: Float, G: Gen<T> + Dot<T>>(p0: G, p1: G) T {
    let mut d = p1;
    for i in 0..G::len() {
        d.put(i, p1.at(i) - p0.at(i));
    }
    return d.length();
}

/// A value `normalize` takes: an f32 or f64 vector, or a quaternion.
pub interface Normalize: Copy {
    fn normalize(self: Self) Self;
}

/// The unit vector `x * (1 / sqrt(dot(x, x)))` for a vector; a zero vector gives NaNs.
pub fn normalize<G: Normalize>(x: G) G {
    return x.normalize();
}

/// A value `cross` takes: an f32 or f64 `Vec<T, 3>`, or a quaternion.
pub interface Cross: Copy {
    fn cross(self: Self, y: Self) Self;
}

/// The cross product `(x.y y.z - y.y x.z, x.z y.x - y.z x.x, x.x y.y - y.x x.y)` for vectors.
pub fn cross<G: Cross>(x: G, y: G) G {
    return x.cross(y);
}

/// `n` if `dot(nref, i) < 0`, else `-n`, computed as `0 - n` for a vec3 or vec4: a +0 component gives
/// +0, not -0.
pub fn faceforward<T: Float, G: Gen<T> + Dot<T>>(n: G, i: G, nref: G) G {
    if nref.dot(i).less(T::zero()) {
        return n;
    }
    let mut r = n;
    for k in 0..G::len() {
        r.put(
            k,
            if G::len() >= 3 {
                T::zero() - n.at(k);
            } else {
                -n.at(k);
            },
        );
    }
    return r;
}

/// The reflection of the incident `i` about the normal `n`: `i - n * dot(n, i) * 2`.
pub fn reflect<T: Float, G: Gen<T> + Dot<T>>(i: G, n: G) G {
    let d = n.dot(i);
    let mut r = i;
    for k in 0..G::len() {
        r.put(k, i.at(k) - n.at(k) * d * T::from_i64(2));
    }
    return r;
}

/// A value `refract` takes: an f32 or f64 scalar or vector.
pub interface Refract<T: Float>: Copy {
    fn refract(self: Self, n: Self, eta: T) Self;
}

/// The refraction of the incident `i` through the surface of normal `n` with the ratio of indices
/// `eta`, `eta * i - (eta * dot(n, i) + sqrt(k)) * n` with `k = 1 - eta^2 (1 - dot(n, i)^2)`.
/// On total internal reflection (`k < 0` or NaN) a vector gives zero and a scalar gives NaN: the
/// scalar form multiplies by `k >= 0` instead of choosing.
pub fn refract<T: Float, G: Refract<T>>(i: G, n: G, eta: T) G {
    return i.refract(n, eta);
}

/// A value `length2` and `distance2` take: an f32 or f64 scalar or vector.
pub interface Length2<T: Float>: Copy {
    fn length2(self: Self) T;
    fn distance2(self: Self, p1: Self) T;
}

/// The squared length `dot(x, x)` of a vector, `x * x` of a scalar.
pub fn length2<T: Float, G: Length2<T>>(x: G) T {
    return x.length2();
}

/// The squared distance `length2(p1 - p0)`.
pub fn distance2<T: Float, G: Length2<T>>(p0: G, p1: G) T {
    return p0.distance2(p1);
}

/// The L1 norm `|v.x| + |v.y| + |v.z|`, with `abs(-0) = -0`.
pub fn l1_norm<T: Float>(v: Vec<T, 3>) T {
    return abs(v.e[0]) + abs(v.e[1]) + abs(v.e[2]);
}

/// The L1 norm of `b - a`.
pub fn l1_norm_between<T: Float>(a: Vec<T, 3>, b: Vec<T, 3>) T {
    return l1_norm(b - a);
}

/// The L2 norm `length(v)`.
pub fn l2_norm<T: Float>(v: Vec<T, 3>) T {
    return v.length();
}

/// The L2 norm `length(b - a)`.
pub fn l2_norm_between<T: Float>(a: Vec<T, 3>, b: Vec<T, 3>) T {
    return (b - a).length();
}

/// The Lx norm `pow(|v.x|^d + |v.y|^d + |v.z|^d, 1 / d)` with `d = depth` as `T`.
/// Depth 0 gives `pow(3, inf)`, infinity.
pub fn lx_norm<T: Float>(v: Vec<T, 3>, depth: u32) T {
    let d = T::from_u64(depth);
    return (abs(v.e[0]).pow(d) + abs(v.e[1]).pow(d) + abs(v.e[2]).pow(d)).pow(T::one() / d);
}

/// The Lx norm `lx_norm(b - a, depth)`.
pub fn lx_norm_between<T: Float>(a: Vec<T, 3>, b: Vec<T, 3>, depth: u32) T {
    return lx_norm(b - a, depth);
}

/// The max norm: the largest of `|v.x|`, `|v.y|`, `|v.z|` by `max(a, b) = (a < b) ? b : a`, so a NaN
/// in x propagates and a NaN in y or z loses.
pub fn lmax_norm<T: Float>(v: Vec<T, 3>) T {
    return max(max(abs(v.e[0]), abs(v.e[1])), abs(v.e[2]));
}

/// The max norm `lmax_norm(b - a)`.
pub fn lmax_norm_between<T: Float>(a: Vec<T, 3>, b: Vec<T, 3>) T {
    return lmax_norm(b - a);
}

/// The angle in radians in [0, pi] between the unit vectors (or scalars) `x` and `y`,
/// `acos(clamp(dot(x, y), -1, 1))`; NaN when the dot product is NaN.
pub fn vector_angle<T: Float, G: Gen<T> + Dot<T>>(x: G, y: G) T {
    return clamp(x.dot(y), T::from_i64(-1), T::one()).acos();
}

/// The signed angle of the unit vec2s `x` and `y`: `vector_angle(x, y)`, negated unless
/// `x.x y.y - y.x x.y > 0` (so also negated when the vectors are collinear or the test is NaN).
pub fn oriented_angle<T: Float>(x: Vec<T, 2>, y: Vec<T, 2>) T {
    let a = vector_angle(x, y);
    if (x.e[0] * y.e[1] - y.e[0] * x.e[1]).greater(T::zero()) {
        return a;
    }
    return -a;
}

/// The signed angle of the unit vec3s `x` and `y` about `reference`: `vector_angle(x, y)`, negated when
/// `dot(reference, cross(x, y)) < 0`.
pub fn oriented_angle_3d<T: Float>(x: Vec<T, 3>, y: Vec<T, 3>, reference: Vec<T, 3>) T {
    let a = vector_angle(x, y);
    if reference.dot(x.cross(y)).less(T::zero()) {
        return -a;
    }
    return a;
}

/// The unit normal `normalize(cross(p1 - p2, p1 - p3))` of a triangle; NaNs for a degenerate triangle.
pub fn triangle_normal<T: Float>(p1: Vec<T, 3>, p2: Vec<T, 3>, p3: Vec<T, 3>) Vec<T, 3> {
    return (p1 - p2).cross(p1 - p3).normalize();
}

/// A value `proj` and `perp` take: an f32 or f64 scalar or vector.
pub interface Proj: Copy {
    fn proj(self: Self, normal: Self) Self;
    fn perp(self: Self, normal: Self) Self;
}

/// The projection of `x` on `normal`, which need not be unit length:
/// `dot(x, normal) / dot(normal, normal) * normal`; NaNs for a zero `normal`.
pub fn proj<G: Proj>(x: G, normal: G) G {
    return x.proj(normal);
}

/// The part of `x` perpendicular to `normal`: `x - proj(x, normal)`.
pub fn perp<G: Proj>(x: G, normal: G) G {
    return x.perp(normal);
}

/// The columns of `m` orthonormalized by Gram-Schmidt, column 0 first.
pub fn orthonormalize<T: Float>(m: Mat<T, 3, 3>) Mat<T, 3, 3> {
    let mut r = m;
    r.c[0] = r.c[0].normalize();
    r.c[1] = (r.c[1] - r.c[0] * r.c[0].dot(r.c[1])).normalize();
    let d1 = r.c[1].dot(r.c[2]);
    let d0 = r.c[0].dot(r.c[2]);
    r.c[2] = (r.c[2] - (r.c[0] * d0 + r.c[1] * d1)).normalize();
    return r;
}

/// `x` made orthogonal to the unit vector `y` and normalized: `normalize(x - y * dot(y, x))`.
pub fn orthonormalize_vec<T: Float>(x: Vec<T, 3>, y: Vec<T, 3>) Vec<T, 3> {
    return (x - y * y.dot(x)).normalize();
}

/// The `(latitude, longitude, xz distance)` of the direction of `v`:
/// `(asin(t.y), atan2(t.x, t.z), sqrt(t.x^2 + t.z^2))` with `t = v / length(v)`; NaNs for a zero `v`.
pub fn polar<T: Float>(v: Vec<T, 3>) Vec<T, 3> {
    let t = v / v.length();
    let xz = (t.e[0] * t.e[0] + t.e[2] * t.e[2]).sqrt();
    return Vec::<T, 3>::new(t.e[1].asin(), t.e[0].atan2(t.e[2]), xz);
}

/// The unit vector at latitude `p.x` and longitude `p.y`,
/// `(cos(p.x) sin(p.y), sin(p.x), cos(p.x) cos(p.y))`.
pub fn euclidean<T: Float>(p: Vec<T, 2>) Vec<T, 3> {
    let cos_lat = p.e[0].cos();
    return Vec::<T, 3>::new(cos_lat * p.e[1].sin(), p.e[0].sin(), cos_lat * p.e[1].cos());
}

extend<T: Float, const N: usize> Vec<T, N> as Dot<T> {
    pub fn dot(self: Vec<T, N>, y: Vec<T, N>) T {
        let p = self * y;
        if N == 4 {
            unsafe {
                return p.e[0] + p.e[1] + (p.e[2] + p.e[3]);
            }
        }
        let mut s = unsafe p.e[0];
        for i in 1..N {
            s = s + unsafe p.e[i];
        }
        return s;
    }
}

extend<T: Float> T as Dot<T> {
    pub fn dot(self: T, y: T) T {
        return self * y;
    }
    pub fn length(self: T) T {
        if self.greater_equal(T::zero()) {
            return self;
        }
        return -self;
    }
}

extend<T: Float, const N: usize> Vec<T, N> as Normalize {
    pub fn normalize(self: Vec<T, N>) Vec<T, N> {
        return self * (T::one() / self.dot(self).sqrt());
    }
}

extend<T: Float> Vec<T, 3> as Cross {
    pub fn cross(self: Vec<T, 3>, y: Vec<T, 3>) Vec<T, 3> {
        let x = self.e;
        return Vec::<T, 3>::new(
            x[1] * y.e[2] - y.e[1] * x[2],
            x[2] * y.e[0] - y.e[2] * x[0],
            x[0] * y.e[1] - y.e[0] * x[1],
        );
    }
}

extend<T: Float, const N: usize> Vec<T, N> as Length2<T> {
    pub fn length2(self: Vec<T, N>) T {
        return self.dot(self);
    }
    pub fn distance2(self: Vec<T, N>, p1: Vec<T, N>) T {
        let d = p1 - self;
        return d.dot(d);
    }
}

extend<T: Float> T as Length2<T> {
    pub fn length2(self: T) T {
        return self * self;
    }
    pub fn distance2(self: T, p1: T) T {
        let d = p1 - self;
        return d * d;
    }
}

extend<T: Float, const N: usize> Vec<T, N> as Proj {
    pub fn proj(self: Vec<T, N>, normal: Vec<T, N>) Vec<T, N> {
        return self.dot(normal) / normal.dot(normal) * normal;
    }
    pub fn perp(self: Vec<T, N>, normal: Vec<T, N>) Vec<T, N> {
        return self - self.proj(normal);
    }
}

extend<T: Float> T as Proj {
    pub fn proj(self: T, normal: T) T {
        return self * normal / (normal * normal) * normal;
    }
    pub fn perp(self: T, normal: T) T {
        return self - self.proj(normal);
    }
}

extend<T: Float, const N: usize> Vec<T, N> as Refract<T> {
    pub fn refract(self: Vec<T, N>, n: Vec<T, N>, eta: T) Vec<T, N> {
        let d = n.dot(self);
        let k = T::one() - eta * eta * (T::one() - d * d);
        if !k.greater_equal(T::zero()) {
            return Vec::<T, N>::zero();
        }
        let s = eta * d + k.sqrt();
        let mut r = self;
        for i in 0..N {
            unsafe {
                r.e[i] = eta * self.e[i] - s * n.e[i];
            }
        }
        return r;
    }
}

extend<T: Float> T as Refract<T> {
    pub fn refract(self: T, n: T, eta: T) T {
        let d = n * self;
        let k = T::one() - eta * eta * (T::one() - d * d);
        let keep = if k.greater_equal(T::zero()) {
            T::one();
        } else {
            T::zero();
        };
        return (eta * self - (eta * d + k.sqrt()) * n) * keep;
    }
}
