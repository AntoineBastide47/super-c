// Less common functions: associated min and max, 32-bit integer functions, logarithms to a base, small
// powers, Gauss functions, gradients, handedness, principal component analysis, QR and RQ factorization,
// cross and mixed products, row- and column-major construction, texture levels, bounds tests, `fmod`,
// `extend_by`, `normalize_dot` and rotation around a normalized axis. `std::math::all` does not import
// this module: write `import std::math::extra as *;` next to it. Every name is unique across std::math:
// `log_base`, `pow_int`, `sqrt_int`, `mod_int` and `cross_2d` carry a suffix, `extend` (a keyword) is
// `extend_by`, the 3- and 4-pair forms are `associated_min3`/`4` and `associated_max3`/`4`, and the
// matrix forms of `row_majorN` and `col_majorN` are `row_major2_from_mat`..`4` and
// `col_major2_from_mat`..`4`. Multiple results are tuples: `qr_decompose` and `rq_decompose` return
// (left, right) with `m == left * right`, `find_eigenvalues_sym_real` returns (count, eigenvalues,
// eigenvectors), `sort_eigenvalues` returns the sorted pair. `find_msb` and `log2_int` give the floor
// log2 of an integer.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::quat as *;
import std::math::geometric as *;
import std::math::integer as *;

// Factors `factorial` multiplies at most. After 128 factors a wrapping integer product is 0 (64 of
// them are even), and a float product above 1 overflows to infinity within 171 factors; neither
// changes after, so the bound changes no result an unbounded loop reaches.
const FACTORIAL_FACTORS_MAX: i32 = 256;

// Newton steps `sqrt_int` takes at most: from x / 2 each step at least shrinks the guess by 3/8 until
// it is within twice the root, then the error squares; 32-bit inputs need fewer than 32.
const SQRT_INT_STEPS_MAX: i32 = 64;

// The QL iterations `find_eigenvalues_sym_real` allows per eigenvalue.
const EIGEN_ITERATIONS_MAX: i32 = 30;

// Associated min and max.

/// A key type of `associated_min` and `associated_max` with values of type `A`: scalar keys with
/// scalar values, vector keys with vector values, scalar keys with vector values, or vector keys with
/// scalar values (a number). Keys compare with `<` and `>`: a NaN key loses each test.
pub interface AssociatedMinMax<A>: Copy {
    /// The result: `A` for scalar keys and values, else the vector of the value type.
    type Out;
    /// The result of the 2- and 3-pair `associated_max`: `Out`, except for scalar keys with vector
    /// values, where it is the vector of the key type (each value converted with `cast`).
    type MaxOut;
    fn associated_min(self: Self, a: A, y: Self, b: A) Self::Out;
    fn associated_min3(self: Self, a: A, y: Self, b: A, z: Self, c: A) Self::Out;
    fn associated_min4(self: Self, a: A, y: Self, b: A, z: Self, c: A, w: Self, d: A) Self::Out;
    fn associated_max(self: Self, a: A, y: Self, b: A) Self::MaxOut;
    fn associated_max3(self: Self, a: A, y: Self, b: A, z: Self, c: A) Self::MaxOut;
    fn associated_max4(self: Self, a: A, y: Self, b: A, z: Self, c: A, w: Self, d: A) Self::Out;
}

/// The value of the smaller key, `x < y ? a : b` per component.
pub fn associated_min<X: AssociatedMinMax<A>, A>(x: X, a: A, y: X, b: A) X::Out {
    return x.associated_min(a, y, b);
}

/// `x < y ? (x < z ? a : c) : (y < z ? b : c)` per component. Vector keys with scalar values follow the
/// vector form.
pub fn associated_min3<X: AssociatedMinMax<A>, A>(x: X, a: A, y: X, b: A, z: X, c: A) X::Out {
    return x.associated_min3(a, y, b, z, c);
}

/// The value of the smaller key of each pair, then of the smaller of the two pair minimums
/// (`min(x, y) < min(z, w)`), per component.
pub fn associated_min4<X: AssociatedMinMax<A>, A>(x: X, a: A, y: X, b: A, z: X, c: A, w: X, d: A) X::Out {
    return x.associated_min4(a, y, b, z, c, w, d);
}

/// The value of the larger key, `x > y ? a : b` per component. With vector keys and scalar values each
/// value passes through the key type (`cast` to it and back).
pub fn associated_max<X: AssociatedMinMax<A>, A>(x: X, a: A, y: X, b: A) X::MaxOut {
    return x.associated_max(a, y, b);
}

/// `x > y ? (x > z ? a : c) : (y > z ? b : c)` per component, with the conversions of `associated_max`.
pub fn associated_max3<X: AssociatedMinMax<A>, A>(x: X, a: A, y: X, b: A, z: X, c: A) X::MaxOut {
    return x.associated_max3(a, y, b, z, c);
}

/// The value of the larger key of each pair, then of the larger of the two pair maximums
/// (`max(x, y) > max(z, w)`), per component.
pub fn associated_max4<X: AssociatedMinMax<A>, A>(x: X, a: A, y: X, b: A, z: X, c: A, w: X, d: A) X::Out {
    return x.associated_max4(a, y, b, z, c, w, d);
}

fn assoc_min2<T: Scalar, V: Copy>(x: T, a: V, y: T, b: V) V {
    if x.less(y) {
        return a;
    }
    return b;
}

fn assoc_min3<T: Scalar, V: Copy>(x: T, a: V, y: T, b: V, z: T, c: V) V {
    if x.less(y) {
        return assoc_min2(x, a, z, c);
    }
    return assoc_min2(y, b, z, c);
}

fn assoc_min4<T: Scalar, V: Copy>(x: T, a: V, y: T, b: V, z: T, c: V, w: T, d: V) V {
    return assoc_min2(min_of(x, y), assoc_min2(x, a, y, b), min_of(z, w), assoc_min2(z, c, w, d));
}

fn assoc_max2<T: Scalar, V: Copy>(x: T, a: V, y: T, b: V) V {
    if x.greater(y) {
        return a;
    }
    return b;
}

fn assoc_max3<T: Scalar, V: Copy>(x: T, a: V, y: T, b: V, z: T, c: V) V {
    if x.greater(y) {
        return assoc_max2(x, a, z, c);
    }
    return assoc_max2(y, b, z, c);
}

fn assoc_max4<T: Scalar, V: Copy>(x: T, a: V, y: T, b: V, z: T, c: V, w: T, d: V) V {
    return assoc_max2(max_of(x, y), assoc_max2(x, a, y, b), max_of(z, w), assoc_max2(z, c, w, d));
}

// `(y < x) ? y : x`: with a NaN operand the result is `x`.
fn min_of<T: Scalar>(x: T, y: T) T {
    if y.less(x) {
        return y;
    }
    return x;
}

// `(x < y) ? y : x`: with a NaN operand the result is `x`.
fn max_of<T: Scalar>(x: T, y: T) T {
    if x.less(y) {
        return y;
    }
    return x;
}

// 32-bit integer functions.

/// A 32-bit integer `pow_int`, `sqrt_int` and `mod_int` take: `i32` or `u32`.
pub interface PowSqrtMod: Copy {
    fn pow_int(self: Self, y: u32) Self;
    fn sqrt_int(self: Self) Self;
    fn mod_int(self: Self, y: Self) Self;
}

/// `x` multiplied `y` times. `pow_int(x, 0)` is 1, and -1 for a negative `i32` `x`. A `u32` product
/// wraps; an `i32` overflow traps in a checked profile.
pub fn pow_int<X: PowSqrtMod>(x: X, y: u32) X {
    return x.pow_int(y);
}

/// The floor of the square root by Newton's method (Musial, Graphics Gems); `x <= 1` (a negative `i32`
/// included) gives `x`.
pub fn sqrt_int<X: PowSqrtMod>(x: X) X {
    return x.sqrt_int();
}

/// `((x % y) + y) % y` for `i32`, the floored modulo for `y > 0`; `x - y * (x / y)` for `u32`. A zero
/// `y` traps; so does an `i32` overflow of `x % y + y` in a checked profile.
pub fn mod_int<X: PowSqrtMod>(x: X, y: X) X {
    return x.mod_int(y);
}

/// The number of leading zero bits, 32 for 0 (`31 - find_msb(x)`).
pub fn nlz(x: u32) u32 {
    return x.leading_zeros() as u32;
}

/// `x * (x - 1) * ..` down to the last factor above 1 (1 for `x <= 1`), per component; a float `x`
/// works too. A product of `u8`..`u64`, `i8` or `i16` wraps; an `i32` or `i64` overflow (13! and 21!)
/// traps in a checked profile. After 256 factors the product stops changing, so the loop stops there:
/// an infinite or huge float gives infinity.
pub fn factorial<T: Scalar, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, factorial_of(x.at(i)));
    }
    return r;
}

fn factorial_of<T: Scalar>(x: T) T {
    let one = T::one();
    let mut temp = x;
    let mut result = one;
    let mut factors_left = FACTORIAL_FACTORS_MAX;
    while temp.greater(one) && factors_left > 0 {
        result = result * temp;
        temp = temp - one;
        factors_left -= 1;
    }
    return result;
}

// Logarithms to a base, small powers, Gauss functions, gradients and handedness.

/// `ln(x) / ln(base)` per component.
pub fn log_base<T: Float, G: Gen<T>>(x: G, base: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, x.at(i).ln() / base.at(i).ln());
    }
    return r;
}

/// `x * x` per component.
pub fn pow2<T: Scalar, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        let v = x.at(i);
        r.put(i, v * v);
    }
    return r;
}

/// `x * x * x` per component.
pub fn pow3<T: Scalar, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        let v = x.at(i);
        r.put(i, v * v * v);
    }
    return r;
}

/// `(x * x) * (x * x)` per component.
pub fn pow4<T: Scalar, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        let v = x.at(i);
        r.put(i, v * v * (v * v));
    }
    return r;
}

/// A value `gauss` takes: an f32 or f64 scalar or `Vec<T, 2>`.
pub interface Gauss<T: Float>: Copy {
    fn gauss(self: Self, expected_value: Self, standard_deviation: Self) T;
}

/// For a scalar the normal density `exp(-(x - mu)^2 / (2 sd^2)) / (sd sqrt(2 pi))`; for a `Vec<T, 2>`
/// the unnormalized `exp(-(sq.x + sq.y))` with `sq = (x - mu)^2 / (2 sd sd)` per component.
pub fn gauss<T: Float, G: Gauss<T>>(x: G, expected_value: G, standard_deviation: G) T {
    return x.gauss(expected_value, standard_deviation);
}

extend<T: Float> T as Gauss<T> {
    pub fn gauss(self: T, expected_value: T, standard_deviation: T) T {
        let d = self - expected_value;
        let exponent = -(d * d) / (T::from_i64(2) * standard_deviation * standard_deviation);
        let two_pi = T::from_decimal(
            6.28318530717958647692528676655900576,
            "6.2831853071795864769252867665590057683943387987502116419498891846156328125724180",
        );
        return exponent.exp() / (standard_deviation * two_pi.sqrt());
    }
}

extend<T: Float> Vec<T, 2> as Gauss<T> {
    pub fn gauss(self: Vec<T, 2>, expected_value: Vec<T, 2>, standard_deviation: Vec<T, 2>) T {
        let d = self - expected_value;
        let squared = d * d / (T::from_i64(2) * standard_deviation * standard_deviation);
        return (-(squared.e[0] + squared.e[1])).exp();
    }
}

/// The gradient ratio at `position` of the radial gradient of `center`, `radius` and `focal` point.
pub fn radial_gradient<T: Float>(center: Vec<T, 2>, radius: T, focal: Vec<T, 2>, position: Vec<T, 2>) T {
    let f = focal - center;
    let d = position - focal;
    let (fx, fy) = (f.e[0], f.e[1]);
    let (dx, dy) = (d.e[0], d.e[1]);
    let radius2 = radius * radius;
    let fx2 = fx * fx;
    let fy2 = fy * fy;
    let cross = dx * fy - dy * fx;
    let numerator = dx * fx + dy * fy + (radius2 * (dx * dx + dy * dy) - cross * cross).sqrt();
    let denominator = radius2 - (fx2 + fy2);
    return numerator / denominator;
}

/// The projection ratio of `position` on the segment `point0`, `point1`.
pub fn linear_gradient<T: Float>(point0: Vec<T, 2>, point1: Vec<T, 2>, position: Vec<T, 2>) T {
    let dist = point1 - point0;
    return (dist.e[0] * (position.e[0] - point0.e[0]) + dist.e[1] * (position.e[1] - point0.e[1])) / dot(dist, dist);
}

/// True when `dot(cross(normal, tangent), binormal) > 0`.
pub fn right_handed<T: Float>(tangent: Vec<T, 3>, binormal: Vec<T, 3>, normal: Vec<T, 3>) bool {
    return dot(cross(normal, tangent), binormal).greater(T::zero());
}

/// True when `dot(cross(normal, tangent), binormal) < 0`.
pub fn left_handed<T: Float>(tangent: Vec<T, 3>, binormal: Vec<T, 3>, normal: Vec<T, 3>) bool {
    return dot(cross(normal, tangent), binormal).less(T::zero());
}

// Principal component analysis.

/// The covariance matrix of the points `v` relative to their center, `sum(v[x] * v[y]) / len` per
/// element, summed in slice order; zero for an empty slice.
pub fn compute_covariance_matrix<T: Scalar, const N: usize>(v: []Vec<T, N>) Mat<T, N, N> {
    let mut m = Mat::<T, N, N>::zero();
    for p in v {
        add_outer(&mut m, p);
    }
    if v.len() > 0 {
        m = m / T::from_u64(v.len() as u64);
    }
    return m;
}

/// The covariance matrix of the absolute points `v` about their center `c`.
pub fn compute_covariance_matrix_with_center<T: Scalar, const N: usize>(v: []Vec<T, N>, c: Vec<T, N>) Mat<T, N, N> {
    let mut m = Mat::<T, N, N>::zero();
    for p in v {
        add_outer(&mut m, p - c);
    }
    if v.len() > 0 {
        m = m / T::from_u64(v.len() as u64);
    }
    return m;
}

// m[x][y] += v[x] * v[y].
fn add_outer<T: Scalar, const N: usize>(m: &mut Mat<T, N, N>, v: Vec<T, N>) {
    for x in 0..N {
        for y in 0..N {
            unsafe {
                m.c[x].e[y] = m.c[x].e[y] + v.e[x] * v.e[y];
            }
        }
    }
}

/// (count, eigenvalues, eigenvectors) of the symmetric real matrix `covar` by Householder reduction and
/// the QL algorithm; eigenvector i is column i. The count is N, or 0 when an eigenvalue needs more than
/// 30 QL iterations; then the eigenvalues and eigenvectors are zero.
pub fn find_eigenvalues_sym_real<T: Float, const N: usize>(covar: Mat<T, N, N>) (u32, Vec<T, N>, Mat<T, N, N>) {
    // The row-major workspace a[r * N + c] = covar[c][r] is `covar` itself: element (r, c) is
    // `a.c[c].e[r]`, and the eigenvectors read back from it are its columns.
    let mut a = covar;
    let mut d = [T::zero(); N];
    let mut e = [T::zero(); N];
    let eps = T::from_f64(0.0000001);
    let two = T::from_i64(2);
    let (zero, one) = (T::zero(), T::one());
    unsafe {
        // 1. Householder reduction; the indices count from 1.
        for t in 0..N - 1 {
            let i = N - t;
            let l = i - 1;
            let mut h = zero;
            if l > 1 {
                let mut scale = zero;
                for k in 1..=l {
                    scale = scale + abs_of(a.c[k - 1].e[i - 1]);
                }
                if equal_of(scale, zero, eps) {
                    e[i - 1] = a.c[l - 1].e[i - 1];
                } else {
                    for k in 1..=l {
                        a.c[k - 1].e[i - 1] = a.c[k - 1].e[i - 1] / scale;
                        h = h + a.c[k - 1].e[i - 1] * a.c[k - 1].e[i - 1];
                    }
                    let mut f = a.c[l - 1].e[i - 1];
                    let mut g = if f.greater_equal(zero) {
                        -h.sqrt();
                    } else {
                        h.sqrt();
                    };
                    e[i - 1] = scale * g;
                    h = h - f * g;
                    a.c[l - 1].e[i - 1] = f - g;
                    f = zero;
                    for j in 1..=l {
                        a.c[i - 1].e[j - 1] = a.c[j - 1].e[i - 1] / h;
                        g = zero;
                        for k in 1..=j {
                            g = g + a.c[k - 1].e[j - 1] * a.c[k - 1].e[i - 1];
                        }
                        for k in j + 1..=l {
                            g = g + a.c[j - 1].e[k - 1] * a.c[k - 1].e[i - 1];
                        }
                        e[j - 1] = g / h;
                        f = f + e[j - 1] * a.c[j - 1].e[i - 1];
                    }
                    let hh = f / (h + h);
                    for j in 1..=l {
                        f = a.c[j - 1].e[i - 1];
                        g = e[j - 1] - hh * f;
                        e[j - 1] = g;
                        for k in 1..=j {
                            a.c[k - 1].e[j - 1] = a.c[k - 1].e[j - 1] - (f * e[k - 1] + g * a.c[k - 1].e[i - 1]);
                        }
                    }
                }
            } else {
                e[i - 1] = a.c[l - 1].e[i - 1];
            }
            d[i - 1] = h;
        }
        d[0] = zero;
        e[0] = zero;
        for i in 1..=N {
            let l = i - 1;
            if !equal_of(d[i - 1], zero, eps) {
                for j in 1..=l {
                    let mut g = zero;
                    for k in 1..=l {
                        g = g + a.c[k - 1].e[i - 1] * a.c[j - 1].e[k - 1];
                    }
                    for k in 1..=l {
                        a.c[j - 1].e[k - 1] = a.c[j - 1].e[k - 1] - g * a.c[i - 1].e[k - 1];
                    }
                }
            }
            d[i - 1] = a.c[i - 1].e[i - 1];
            a.c[i - 1].e[i - 1] = one;
            for j in 1..=l {
                a.c[j - 1].e[i - 1] = zero;
                a.c[i - 1].e[j - 1] = zero;
            }
        }
        // 2. Eigenvalues and eigenvectors by the QL algorithm.
        for i in 2..=N {
            e[i - 2] = e[i - 1];
        }
        e[N - 1] = zero;
        for l in 1..=N {
            // Iteration `iter` follows `iter` splits: the last one breaks or returns.
            for iter in 0..=EIGEN_ITERATIONS_MAX {
                let mut m = l;
                while m <= N - 1 {
                    let dd = abs_of(d[m - 1]) + abs_of(d[m]);
                    if equal_of(abs_of(e[m - 1]) + dd, dd, eps) {
                        break;
                    }
                    m += 1;
                }
                if m == l {
                    break;
                }
                if iter == EIGEN_ITERATIONS_MAX {
                    return 0, Vec::<T, N>::zero(), Mat::<T, N, N>::zero();
                }
                let mut g = (d[l] - d[l - 1]) / (two * e[l - 1]);
                let mut r = pythag(g, one);
                g = d[m - 1] - d[l - 1] + e[l - 1] / (g + transfer_sign(r, g));
                let mut s = one;
                let mut c = one;
                let mut p = zero;
                let mut i = m - 1;
                while i >= l {
                    let mut f = s * e[i - 1];
                    let b = c * e[i - 1];
                    r = pythag(f, g);
                    e[i] = r;
                    if equal_of(r, zero, eps) {
                        d[i] = d[i] - p;
                        e[m - 1] = zero;
                        break;
                    }
                    s = f / r;
                    c = g / r;
                    g = d[i] - p;
                    r = (d[i - 1] - g) * s + two * c * b;
                    p = s * r;
                    d[i] = g + p;
                    g = c * r - b;
                    for k in 1..=N {
                        f = a.c[i].e[k - 1];
                        a.c[i].e[k - 1] = s * a.c[i - 1].e[k - 1] + c * f;
                        a.c[i - 1].e[k - 1] = c * a.c[i - 1].e[k - 1] - s * f;
                    }
                    i -= 1;
                }
                if equal_of(r, zero, eps) && i >= l {
                    continue;
                }
                d[l - 1] = d[l - 1] - p;
                e[l - 1] = g;
                e[m - 1] = zero;
            }
        }
    }
    return N as u32, Vec::<T, N> { e: d }, a;
}

// `x >= 0 ? x : -x`: -0 stays -0 and a NaN changes sign.
fn abs_of<T: Scalar>(x: T) T {
    if x.greater_equal(T::zero()) {
        return x;
    }
    return -x;
}

fn equal_of<T: Scalar>(x: T, y: T, eps: T) bool {
    return abs_of(x - y).less_equal(eps);
}

// `abs_of(v)` with the sign of `s` by the test `s >= 0`: an `s` of -0 gives `abs_of(v)`, a NaN `s` its
// negation.
fn transfer_sign<T: Float>(v: T, s: T) T {
    if s.greater_equal(T::zero()) {
        return abs_of(v);
    }
    return -abs_of(v);
}

// `sqrt(a^2 + b^2)` without overflow.
fn pythag<T: Float>(a: T, b: T) T {
    let mut absa = abs_of(a);
    let mut absb = abs_of(b);
    if absa.greater(absb) {
        absb = absb / absa;
        absb = absb * absb;
        return absa * (T::one() + absb).sqrt();
    }
    if equal_of(absb, T::zero(), T::from_f64(0.0000001)) {
        return T::zero();
    }
    absa = absa / absb;
    absa = absa * absa;
    return absb * (T::one() + absa).sqrt();
}

/// The eigenvalues from the largest to the smallest with the eigenvector columns moved alike, for N = 2,
/// 3 or 4 (another N is a compile error), by a swap network of `<` tests (a pair with a NaN does not
/// swap).
pub fn sort_eigenvalues<T: Scalar, const N: usize>(eigenvalues: Vec<T, N>, eigenvectors: Mat<T, N, N>) (
    Vec<T, N>,
    Mat<T, N, N>
) {
    static_assert(N >= 2 && N <= 4, "sort_eigenvalues of 2, 3 or 4 eigenvalues");
    let mut values = eigenvalues;
    let mut vectors = eigenvectors;
    if N == 2 {
        sort_eigen_pair(&mut values, &mut vectors, 0, 1);
    } else if N == 3 {
        sort_eigen_pair(&mut values, &mut vectors, 0, 1);
        sort_eigen_pair(&mut values, &mut vectors, 0, 2);
        sort_eigen_pair(&mut values, &mut vectors, 1, 2);
    } else {
        sort_eigen_pair(&mut values, &mut vectors, 0, 2);
        sort_eigen_pair(&mut values, &mut vectors, 1, 3);
        sort_eigen_pair(&mut values, &mut vectors, 0, 1);
        sort_eigen_pair(&mut values, &mut vectors, 2, 3);
        sort_eigen_pair(&mut values, &mut vectors, 1, 2);
    }
    return values, vectors;
}

// Swap entries i and j (i < j < N) when values[i] < values[j].
fn sort_eigen_pair<T: Scalar, const N: usize>(values: &mut Vec<T, N>, vectors: &mut Mat<T, N, N>, i: usize, j: usize) {
    unsafe {
        if values.e[i].less(values.e[j]) {
            let v = values.e[i];
            values.e[i] = values.e[j];
            values.e[j] = v;
            let c = vectors.c[i];
            vectors.c[i] = vectors.c[j];
            vectors.c[j] = c;
        }
    }
}

// Matrix factorization.

/// The columns of `m` in reverse order.
pub fn fliplr<T: Scalar, const C: usize, const R: usize>(m: Mat<T, C, R>) Mat<T, C, R> {
    let mut out = m;
    for i in 0..C {
        unsafe {
            out.c[i] = m.c[C - 1 - i];
        }
    }
    return out;
}

/// The rows of `m` in reverse order.
pub fn flipud<T: Scalar, const C: usize, const R: usize>(m: Mat<T, C, R>) Mat<T, C, R> {
    let mut out = m;
    for i in 0..C {
        for j in 0..R {
            unsafe {
                out.c[i].e[j] = m.c[i].e[R - 1 - j];
            }
        }
    }
    return out;
}

/// A matrix `qr_decompose` and `rq_decompose` take: an f32 or f64 matrix of 2 to 4 columns and
/// rows. With K = min(C, R) the factors are `Left` = `Mat<T, K, R>` and `Right` = `Mat<T, C, K>`.
pub interface QrDecompose: Copy {
    type Left;
    type Right;
    fn qr_decompose(self: Self) (Self::Left, Self::Right);
    fn rq_decompose(self: Self) (Self::Left, Self::Right);
}

/// (q, r) by modified Gram-Schmidt, with orthonormal columns in `q`, `r` upper triangular and
/// `m == q * r`. A rank-deficient `m` gives NaNs.
pub fn qr_decompose<M: QrDecompose>(m: M) (M::Left, M::Right) {
    return m.qr_decompose();
}

/// (r, q) with `r` upper triangular, orthonormal rows in `q` and `m == r * q`, by `qr_decompose` of the
/// flipped transpose.
pub fn rq_decompose<M: QrDecompose>(m: M) (M::Left, M::Right) {
    return m.rq_decompose();
}

fn qr_of<T: Float, const C: usize, const R: usize, const K: usize>(m: Mat<T, C, R>) (Mat<T, K, R>, Mat<T, C, K>) {
    static_assert(C < R && K == C || C >= R && K == R, "qr_decompose: K must be min(C, R)");
    let mut q = Mat::<T, K, R>::zero();
    let mut r = Mat::<T, C, K>::zero();
    for i in 0..K {
        unsafe {
            let mut qi = m.c[i];
            for j in 0..i {
                qi = qi - dot(qi, q.c[j]) * q.c[j];
            }
            qi = normalize(qi);
            q.c[i] = qi;
            for j in i..C {
                r.c[j].e[i] = dot(m.c[j], qi);
            }
        }
    }
    return q, r;
}

fn rq_of<T: Float, const C: usize, const R: usize, const K: usize>(m: Mat<T, C, R>) (Mat<T, K, R>, Mat<T, C, K>) {
    let (tq, tr) = qr_of::<T, R, C, K>(fliplr(transpose(m)));
    return fliplr(transpose(fliplr(tr))), transpose(fliplr(tq));
}

extend<T: Float> Mat<T, 2, 2> as QrDecompose {
    type Left = Mat<T, 2, 2>;
    type Right = Mat<T, 2, 2>;
    pub fn qr_decompose(self: Mat<T, 2, 2>) (Mat<T, 2, 2>, Mat<T, 2, 2>) {
        return qr_of::<T, 2, 2, 2>(self);
    }
    pub fn rq_decompose(self: Mat<T, 2, 2>) (Mat<T, 2, 2>, Mat<T, 2, 2>) {
        return rq_of::<T, 2, 2, 2>(self);
    }
}

extend<T: Float> Mat<T, 2, 3> as QrDecompose {
    type Left = Mat<T, 2, 3>;
    type Right = Mat<T, 2, 2>;
    pub fn qr_decompose(self: Mat<T, 2, 3>) (Mat<T, 2, 3>, Mat<T, 2, 2>) {
        return qr_of::<T, 2, 3, 2>(self);
    }
    pub fn rq_decompose(self: Mat<T, 2, 3>) (Mat<T, 2, 3>, Mat<T, 2, 2>) {
        return rq_of::<T, 2, 3, 2>(self);
    }
}

extend<T: Float> Mat<T, 2, 4> as QrDecompose {
    type Left = Mat<T, 2, 4>;
    type Right = Mat<T, 2, 2>;
    pub fn qr_decompose(self: Mat<T, 2, 4>) (Mat<T, 2, 4>, Mat<T, 2, 2>) {
        return qr_of::<T, 2, 4, 2>(self);
    }
    pub fn rq_decompose(self: Mat<T, 2, 4>) (Mat<T, 2, 4>, Mat<T, 2, 2>) {
        return rq_of::<T, 2, 4, 2>(self);
    }
}

extend<T: Float> Mat<T, 3, 2> as QrDecompose {
    type Left = Mat<T, 2, 2>;
    type Right = Mat<T, 3, 2>;
    pub fn qr_decompose(self: Mat<T, 3, 2>) (Mat<T, 2, 2>, Mat<T, 3, 2>) {
        return qr_of::<T, 3, 2, 2>(self);
    }
    pub fn rq_decompose(self: Mat<T, 3, 2>) (Mat<T, 2, 2>, Mat<T, 3, 2>) {
        return rq_of::<T, 3, 2, 2>(self);
    }
}

extend<T: Float> Mat<T, 3, 3> as QrDecompose {
    type Left = Mat<T, 3, 3>;
    type Right = Mat<T, 3, 3>;
    pub fn qr_decompose(self: Mat<T, 3, 3>) (Mat<T, 3, 3>, Mat<T, 3, 3>) {
        return qr_of::<T, 3, 3, 3>(self);
    }
    pub fn rq_decompose(self: Mat<T, 3, 3>) (Mat<T, 3, 3>, Mat<T, 3, 3>) {
        return rq_of::<T, 3, 3, 3>(self);
    }
}

extend<T: Float> Mat<T, 3, 4> as QrDecompose {
    type Left = Mat<T, 3, 4>;
    type Right = Mat<T, 3, 3>;
    pub fn qr_decompose(self: Mat<T, 3, 4>) (Mat<T, 3, 4>, Mat<T, 3, 3>) {
        return qr_of::<T, 3, 4, 3>(self);
    }
    pub fn rq_decompose(self: Mat<T, 3, 4>) (Mat<T, 3, 4>, Mat<T, 3, 3>) {
        return rq_of::<T, 3, 4, 3>(self);
    }
}

extend<T: Float> Mat<T, 4, 2> as QrDecompose {
    type Left = Mat<T, 2, 2>;
    type Right = Mat<T, 4, 2>;
    pub fn qr_decompose(self: Mat<T, 4, 2>) (Mat<T, 2, 2>, Mat<T, 4, 2>) {
        return qr_of::<T, 4, 2, 2>(self);
    }
    pub fn rq_decompose(self: Mat<T, 4, 2>) (Mat<T, 2, 2>, Mat<T, 4, 2>) {
        return rq_of::<T, 4, 2, 2>(self);
    }
}

extend<T: Float> Mat<T, 4, 3> as QrDecompose {
    type Left = Mat<T, 3, 3>;
    type Right = Mat<T, 4, 3>;
    pub fn qr_decompose(self: Mat<T, 4, 3>) (Mat<T, 3, 3>, Mat<T, 4, 3>) {
        return qr_of::<T, 4, 3, 3>(self);
    }
    pub fn rq_decompose(self: Mat<T, 4, 3>) (Mat<T, 3, 3>, Mat<T, 4, 3>) {
        return rq_of::<T, 4, 3, 3>(self);
    }
}

extend<T: Float> Mat<T, 4, 4> as QrDecompose {
    type Left = Mat<T, 4, 4>;
    type Right = Mat<T, 4, 4>;
    pub fn qr_decompose(self: Mat<T, 4, 4>) (Mat<T, 4, 4>, Mat<T, 4, 4>) {
        return qr_of::<T, 4, 4, 4>(self);
    }
    pub fn rq_decompose(self: Mat<T, 4, 4>) (Mat<T, 4, 4>, Mat<T, 4, 4>) {
        return rq_of::<T, 4, 4, 4>(self);
    }
}

// Cross and mixed products.

/// The matrix `M` with `M * y == cross(x, y)`.
pub fn matrix_cross3<T: Scalar>(x: Vec<T, 3>) Mat<T, 3, 3> {
    let mut r = Mat::<T, 3, 3>::zero();
    r.c[0].e[1] = x.e[2];
    r.c[1].e[0] = -x.e[2];
    r.c[0].e[2] = -x.e[1];
    r.c[2].e[0] = x.e[1];
    r.c[1].e[2] = x.e[0];
    r.c[2].e[1] = -x.e[0];
    return r;
}

/// `matrix_cross3(x)` in a 4x4 matrix with zero row and column 3.
pub fn matrix_cross4<T: Scalar>(x: Vec<T, 3>) Mat<T, 4, 4> {
    let mut r = Mat::<T, 4, 4>::zero();
    r.c[0].e[1] = x.e[2];
    r.c[1].e[0] = -x.e[2];
    r.c[0].e[2] = -x.e[1];
    r.c[2].e[0] = x.e[1];
    r.c[1].e[2] = x.e[0];
    r.c[2].e[1] = -x.e[0];
    return r;
}

/// `dot(cross(v1, v2), v3)`.
pub fn mixed_product<T: Float>(v1: Vec<T, 3>, v2: Vec<T, 3>, v3: Vec<T, 3>) T {
    return dot(cross(v1, v2), v3);
}

/// The 2D cross product `v.x * u.y - u.x * v.y`.
pub fn cross_2d<T: Float>(v: Vec<T, 2>, u: Vec<T, 2>) T {
    return v.e[0] * u.e[1] - u.e[0] * v.e[1];
}

// Row- and column-major construction.

/// The matrix whose rows are `v1` and `v2`.
pub fn row_major2<T: Scalar>(v1: Vec<T, 2>, v2: Vec<T, 2>) Mat<T, 2, 2> {
    return transpose(Mat::<T, 2, 2>::cols(v1, v2));
}

/// The transpose of `m`.
pub fn row_major2_from_mat<T: Scalar>(m: Mat<T, 2, 2>) Mat<T, 2, 2> {
    return transpose(m);
}

/// The matrix whose rows are `v1`, `v2` and `v3`.
pub fn row_major3<T: Scalar>(v1: Vec<T, 3>, v2: Vec<T, 3>, v3: Vec<T, 3>) Mat<T, 3, 3> {
    return transpose(Mat::<T, 3, 3>::cols(v1, v2, v3));
}

/// The transpose of `m`.
pub fn row_major3_from_mat<T: Scalar>(m: Mat<T, 3, 3>) Mat<T, 3, 3> {
    return transpose(m);
}

/// The matrix whose rows are `v1` to `v4`.
pub fn row_major4<T: Scalar>(v1: Vec<T, 4>, v2: Vec<T, 4>, v3: Vec<T, 4>, v4: Vec<T, 4>) Mat<T, 4, 4> {
    return transpose(Mat::<T, 4, 4>::cols(v1, v2, v3, v4));
}

/// The transpose of `m`.
pub fn row_major4_from_mat<T: Scalar>(m: Mat<T, 4, 4>) Mat<T, 4, 4> {
    return transpose(m);
}

/// The matrix whose columns are `v1` and `v2`.
pub fn col_major2<T: Scalar>(v1: Vec<T, 2>, v2: Vec<T, 2>) Mat<T, 2, 2> {
    return Mat::<T, 2, 2>::cols(v1, v2);
}

/// `m` unchanged.
pub fn col_major2_from_mat<T: Scalar>(m: Mat<T, 2, 2>) Mat<T, 2, 2> {
    return m;
}

/// The matrix whose columns are `v1`, `v2` and `v3`.
pub fn col_major3<T: Scalar>(v1: Vec<T, 3>, v2: Vec<T, 3>, v3: Vec<T, 3>) Mat<T, 3, 3> {
    return Mat::<T, 3, 3>::cols(v1, v2, v3);
}

/// `m` unchanged.
pub fn col_major3_from_mat<T: Scalar>(m: Mat<T, 3, 3>) Mat<T, 3, 3> {
    return m;
}

/// The matrix whose columns are `v1` to `v4`.
pub fn col_major4<T: Scalar>(v1: Vec<T, 4>, v2: Vec<T, 4>, v3: Vec<T, 4>, v4: Vec<T, 4>) Mat<T, 4, 4> {
    return Mat::<T, 4, 4>::cols(v1, v2, v3, v4);
}

/// `m` unchanged.
pub fn col_major4_from_mat<T: Scalar>(m: Mat<T, 4, 4>) Mat<T, 4, 4> {
    return m;
}

// Texture levels, `fmod`, bounds tests and `extend_by`.

/// A number `fmod` and `levels` take: for f32 and f64 the float remainder `fmod` and `log2`; for an
/// integer `%` and `log2_int` (the index of the highest set bit, -1 for 0).
pub interface FmodLog2: Scalar {
    fn fmod_of(self: Self, y: Self) Self;
    fn log2_of(self: Self) Self;
}

extend<T: Int> T as FmodLog2 {
    pub fn fmod_of(self: T, y: T) T {
        return self % y;
    }
    pub fn log2_of(self: T) T {
        return log2_int(self);
    }
}

extend f32 as FmodLog2 {
    pub fn fmod_of(self: f32, y: f32) f32 {
        return self.fmod(y);
    }
    pub fn log2_of(self: f32) f32 {
        return self.log2();
    }
}

extend f64 as FmodLog2 {
    pub fn fmod_of(self: f64, y: f64) f64 {
        return self.fmod(y);
    }
    pub fn log2_of(self: f64) f64 {
        return self.log2();
    }
}

/// The mipmap level count of a texture of size `extent`, `log2` of the largest component plus 1 (an
/// integer extent takes the floor log2; a float one the unrounded `log2`).
pub fn levels<T: FmodLog2, G: Gen<T>>(extent: G) T {
    let mut m = extent.at(0);
    for i in 1..G::len() {
        m = max_of(m, extent.at(i));
    }
    return m.log2_of() + T::one();
}

/// True for each subnormal component: nonzero with a magnitude below the smallest positive normal value.
pub fn isdenormal<T: Float, G: Gen<T> + GenAs<bool, O>, O>(x: G) O {
    let mut r = G::out_of(false);
    for i in 0..G::len() {
        let v = x.at(i);
        G::out_put(&mut r, i, v.abs().less(T::min_positive()) && v.not_equal(T::zero()));
    }
    return r;
}

/// The float remainder `fmod(x, y)` per component for floats, `x % y` for integers (a zero `y` traps);
/// `y` has the type of `x` or is a scalar.
pub fn fmod<T: FmodLog2, G: Gen<T>, B: Arg<G>>(x: G, y: B) G {
    let d = y.to_gen();
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, x.at(i).fmod_of(d.at(i)));
    }
    return r;
}

/// `min < value && value < max` per component.
pub fn open_bounded<T: Scalar, const N: usize>(value: Vec<T, N>, min: Vec<T, N>, max: Vec<T, N>) Vec<bool, N> {
    let mut r = Vec::<bool, N>::splat(false);
    for i in 0..N {
        unsafe {
            r.e[i] = value.e[i].greater(min.e[i]) && value.e[i].less(max.e[i]);
        }
    }
    return r;
}

/// `min <= value && value <= max` per component.
pub fn close_bounded<T: Scalar, const N: usize>(value: Vec<T, N>, min: Vec<T, N>, max: Vec<T, N>) Vec<bool, N> {
    let mut r = Vec::<bool, N>::splat(false);
    for i in 0..N {
        unsafe {
            r.e[i] = value.e[i].greater_equal(min.e[i]) && value.e[i].less_equal(max.e[i]);
        }
    }
    return r;
}

/// `origin + (source - origin) * distance` per component; `distance` has the type of `origin` or is a
/// scalar.
pub fn extend_by<T: Scalar, G: Gen<T>, B: Arg<G>>(origin: G, source: G, distance: B) G {
    let d = distance.to_gen();
    let mut r = origin;
    for i in 0..G::len() {
        r.put(i, origin.at(i) + (source.at(i) - origin.at(i)) * d.at(i));
    }
    return r;
}

// Normalized dot product and rotation around a normalized axis.

/// The cosine of the angle between `x` and `y`: `dot(x, y) * (1 / sqrt(dot(x, x) * dot(y, y)))`.
pub fn normalize_dot<T: Float, const N: usize>(x: Vec<T, N>, y: Vec<T, N>) T {
    return dot(x, y) * (T::one() / (dot(x, x) * dot(y, y)).sqrt());
}

/// `normalize_dot` with a fast inverse square root: for f32 the bit estimate `0x5f375a86 - (bits >> 1)`
/// refined by one Newton step, for f64 `1 / sqrt`.
pub fn fast_normalize_dot<T: Float, const N: usize>(x: Vec<T, N>, y: Vec<T, N>) T {
    return dot(x, y) * fast_inverse_sqrt_of(dot(x, x) * dot(y, y));
}

fn fast_inverse_sqrt_of<T: Float>(x: T) T {
    if sizeof(T) != 4 {
        return T::one() / x.sqrt();
    }
    let xhalf = x * T::from_f32(0.5);
    let i = 0x5f375a86u32.wrapping_sub(x.to_bits() as u32 >> 1);
    let t = T::from_bits(i);
    return t * (T::from_f32(1.5) - xhalf * t * t);
}

/// A value `rotate_normalized_axis` takes: a 4x4 matrix or a quaternion.
pub interface RotateNormalizedAxis<T: Float>: Copy {
    fn rotate_normalized_axis(self: Self, angle: T, axis: Vec<T, 3>) Self;
}

/// `x` rotated by `angle` radians around `axis`, which must be normalized (unlike `rotate`, nothing
/// normalizes it).
pub fn rotate_normalized_axis<T: Float, G: RotateNormalizedAxis<T>>(x: G, angle: T, axis: Vec<T, 3>) G {
    return x.rotate_normalized_axis(angle, axis);
}

// `m` times the rotation, column by column; the `0 +` of the off-diagonal terms turns -0 into +0.
extend<T: Float> Mat<T, 4, 4> as RotateNormalizedAxis<T> {
    pub fn rotate_normalized_axis(self: Mat<T, 4, 4>, angle: T, axis: Vec<T, 3>) Mat<T, 4, 4> {
        let c = angle.cos();
        let s = angle.sin();
        let z = T::zero();
        let a = axis.e;
        let t = ((T::one() - c) * axis).e;
        let r00 = c + t[0] * a[0];
        let r01 = z + t[0] * a[1] + s * a[2];
        let r02 = z + t[0] * a[2] - s * a[1];
        let r10 = z + t[1] * a[0] - s * a[2];
        let r11 = c + t[1] * a[1];
        let r12 = z + t[1] * a[2] + s * a[0];
        let r20 = z + t[2] * a[0] + s * a[1];
        let r21 = z + t[2] * a[1] - s * a[0];
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

// `q * (cos(angle / 2), v * sin(angle / 2))`.
extend<T: Float> Quat<T> as RotateNormalizedAxis<T> {
    pub fn rotate_normalized_axis(self: Quat<T>, angle: T, axis: Vec<T, 3>) Quat<T> {
        let half = angle * T::from_f64(0.5);
        let s = half.sin();
        return self * Quat::<T>::new(half.cos(), axis.e[0] * s, axis.e[1] * s, axis.e[2] * s);
    }
}

// The conformances of `AssociatedMinMax`.

extend<T: Scalar, U: Elem> T as AssociatedMinMax<U> {
    type Out = U;
    type MaxOut = U;
    pub fn associated_min(self: T, a: U, y: T, b: U) U {
        return assoc_min2(self, a, y, b);
    }
    pub fn associated_min3(self: T, a: U, y: T, b: U, z: T, c: U) U {
        return assoc_min3(self, a, y, b, z, c);
    }
    pub fn associated_min4(self: T, a: U, y: T, b: U, z: T, c: U, w: T, d: U) U {
        return assoc_min4(self, a, y, b, z, c, w, d);
    }
    pub fn associated_max(self: T, a: U, y: T, b: U) U {
        return assoc_max2(self, a, y, b);
    }
    pub fn associated_max3(self: T, a: U, y: T, b: U, z: T, c: U) U {
        return assoc_max3(self, a, y, b, z, c);
    }
    pub fn associated_max4(self: T, a: U, y: T, b: U, z: T, c: U, w: T, d: U) U {
        return assoc_max4(self, a, y, b, z, c, w, d);
    }
}

extend<T: Scalar, U: Elem, const N: usize> Vec<T, N> as AssociatedMinMax<Vec<U, N>> {
    type Out = Vec<U, N>;
    type MaxOut = Vec<U, N>;
    pub fn associated_min(self: Vec<T, N>, a: Vec<U, N>, y: Vec<T, N>, b: Vec<U, N>) Vec<U, N> {
        let mut r = a;
        for i in 0..N {
            unsafe {
                r.e[i] = assoc_min2(self.e[i], a.e[i], y.e[i], b.e[i]);
            }
        }
        return r;
    }
    pub fn associated_min3(self: Vec<T, N>, a: Vec<U, N>, y: Vec<T, N>, b: Vec<U, N>, z: Vec<T, N>, c: Vec<U, N>) Vec<
        U,
        N
    > {
        let mut r = a;
        for i in 0..N {
            unsafe {
                r.e[i] = assoc_min3(self.e[i], a.e[i], y.e[i], b.e[i], z.e[i], c.e[i]);
            }
        }
        return r;
    }
    pub fn associated_min4(
        self: Vec<T, N>,
        a: Vec<U, N>,
        y: Vec<T, N>,
        b: Vec<U, N>,
        z: Vec<T, N>,
        c: Vec<U, N>,
        w: Vec<T, N>,
        d: Vec<U, N>,
    ) Vec<U, N> {
        let mut r = a;
        for i in 0..N {
            unsafe {
                r.e[i] = assoc_min4(self.e[i], a.e[i], y.e[i], b.e[i], z.e[i], c.e[i], w.e[i], d.e[i]);
            }
        }
        return r;
    }
    pub fn associated_max(self: Vec<T, N>, a: Vec<U, N>, y: Vec<T, N>, b: Vec<U, N>) Vec<U, N> {
        let mut r = a;
        for i in 0..N {
            unsafe {
                r.e[i] = assoc_max2(self.e[i], a.e[i], y.e[i], b.e[i]);
            }
        }
        return r;
    }
    pub fn associated_max3(self: Vec<T, N>, a: Vec<U, N>, y: Vec<T, N>, b: Vec<U, N>, z: Vec<T, N>, c: Vec<U, N>) Vec<
        U,
        N
    > {
        let mut r = a;
        for i in 0..N {
            unsafe {
                r.e[i] = assoc_max3(self.e[i], a.e[i], y.e[i], b.e[i], z.e[i], c.e[i]);
            }
        }
        return r;
    }
    pub fn associated_max4(
        self: Vec<T, N>,
        a: Vec<U, N>,
        y: Vec<T, N>,
        b: Vec<U, N>,
        z: Vec<T, N>,
        c: Vec<U, N>,
        w: Vec<T, N>,
        d: Vec<U, N>,
    ) Vec<U, N> {
        let mut r = a;
        for i in 0..N {
            unsafe {
                r.e[i] = assoc_max4(self.e[i], a.e[i], y.e[i], b.e[i], z.e[i], c.e[i], w.e[i], d.e[i]);
            }
        }
        return r;
    }
}

// Scalar keys pick whole vectors; the 2- and 3-pair max converts the pick to a vector of the key type.
extend<T: Scalar, U: Scalar, const N: usize> T as AssociatedMinMax<Vec<U, N>> {
    type Out = Vec<U, N>;
    type MaxOut = Vec<T, N>;
    pub fn associated_min(self: T, a: Vec<U, N>, y: T, b: Vec<U, N>) Vec<U, N> {
        return assoc_min2(self, a, y, b);
    }
    pub fn associated_min3(self: T, a: Vec<U, N>, y: T, b: Vec<U, N>, z: T, c: Vec<U, N>) Vec<U, N> {
        return assoc_min3(self, a, y, b, z, c);
    }
    pub fn associated_min4(self: T, a: Vec<U, N>, y: T, b: Vec<U, N>, z: T, c: Vec<U, N>, w: T, d: Vec<U, N>) Vec<U, N> {
        return assoc_min4(self, a, y, b, z, c, w, d);
    }
    pub fn associated_max(self: T, a: Vec<U, N>, y: T, b: Vec<U, N>) Vec<T, N> {
        return assoc_max2(self, a, y, b).cast::<T>();
    }
    pub fn associated_max3(self: T, a: Vec<U, N>, y: T, b: Vec<U, N>, z: T, c: Vec<U, N>) Vec<T, N> {
        return assoc_max3(self, a, y, b, z, c).cast::<T>();
    }
    pub fn associated_max4(self: T, a: Vec<U, N>, y: T, b: Vec<U, N>, z: T, c: Vec<U, N>, w: T, d: Vec<U, N>) Vec<U, N> {
        return assoc_max4(self, a, y, b, z, c, w, d);
    }
}

// Vector keys pick a scalar per component; the 2- and 3-pair max stores the pick in a vector of the
// key type and converts it back.
extend<T: Scalar, U: Scalar, const N: usize> Vec<T, N> as AssociatedMinMax<U> {
    type Out = Vec<U, N>;
    type MaxOut = Vec<U, N>;
    pub fn associated_min(self: Vec<T, N>, a: U, y: Vec<T, N>, b: U) Vec<U, N> {
        let mut r = Vec::<U, N>::splat(a);
        for i in 0..N {
            unsafe {
                r.e[i] = assoc_min2(self.e[i], a, y.e[i], b);
            }
        }
        return r;
    }
    pub fn associated_min3(self: Vec<T, N>, a: U, y: Vec<T, N>, b: U, z: Vec<T, N>, c: U) Vec<U, N> {
        let mut r = Vec::<U, N>::splat(a);
        for i in 0..N {
            unsafe {
                r.e[i] = assoc_min3(self.e[i], a, y.e[i], b, z.e[i], c);
            }
        }
        return r;
    }
    pub fn associated_min4(self: Vec<T, N>, a: U, y: Vec<T, N>, b: U, z: Vec<T, N>, c: U, w: Vec<T, N>, d: U) Vec<U, N> {
        let mut r = Vec::<U, N>::splat(a);
        for i in 0..N {
            unsafe {
                r.e[i] = assoc_min4(self.e[i], a, y.e[i], b, z.e[i], c, w.e[i], d);
            }
        }
        return r;
    }
    pub fn associated_max(self: Vec<T, N>, a: U, y: Vec<T, N>, b: U) Vec<U, N> {
        let mut r = Vec::<U, N>::splat(a);
        for i in 0..N {
            unsafe {
                r.e[i] = assoc_max2(self.e[i], a.cast::<T>(), y.e[i], b.cast::<T>()).cast::<U>();
            }
        }
        return r;
    }
    pub fn associated_max3(self: Vec<T, N>, a: U, y: Vec<T, N>, b: U, z: Vec<T, N>, c: U) Vec<U, N> {
        let mut r = Vec::<U, N>::splat(a);
        for i in 0..N {
            unsafe {
                r.e[i] = assoc_max3(self.e[i], a.cast::<T>(), y.e[i], b.cast::<T>(), z.e[i], c.cast::<T>()).cast::<U>();
            }
        }
        return r;
    }
    pub fn associated_max4(self: Vec<T, N>, a: U, y: Vec<T, N>, b: U, z: Vec<T, N>, c: U, w: Vec<T, N>, d: U) Vec<U, N> {
        let mut r = Vec::<U, N>::splat(a);
        for i in 0..N {
            unsafe {
                r.e[i] = assoc_max4(self.e[i], a, y.e[i], b, z.e[i], c, w.e[i], d);
            }
        }
        return r;
    }
}

// The conformances of `PowSqrtMod`.

extend i32 as PowSqrtMod {
    pub fn pow_int(self: i32, y: u32) i32 {
        if y == 0 {
            return if self >= 0 {
                1;
            } else {
                -1;
            };
        }
        let mut result = self;
        for _ in 1..y {
            result *= self;
        }
        return result;
    }
    pub fn sqrt_int(self: i32) i32 {
        if self <= 1 {
            return self;
        }
        let mut next = self >> 1;
        for _ in 0..SQRT_INT_STEPS_MAX {
            let current = next;
            next = next + self / next >> 1;
            if next >= current {
                return current;
            }
        }
        panic("sqrt_int: Newton's method did not converge within SQRT_INT_STEPS_MAX steps");
    }
    pub fn mod_int(self: i32, y: i32) i32 {
        return (self % y + y) % y;
    }
}

extend u32 as PowSqrtMod {
    pub fn pow_int(self: u32, y: u32) u32 {
        if y == 0 {
            return 1;
        }
        let mut result = self;
        for _ in 1..y {
            result = result.wrapping_mul(self);
        }
        return result;
    }
    pub fn sqrt_int(self: u32) u32 {
        if self <= 1 {
            return self;
        }
        let mut next = self >> 1;
        for _ in 0..SQRT_INT_STEPS_MAX {
            let current = next;
            next = next + self / next >> 1;
            if next >= current {
                return current;
            }
        }
        panic("sqrt_int: Newton's method did not converge within SQRT_INT_STEPS_MAX steps");
    }
    pub fn mod_int(self: u32, y: u32) u32 {
        return self - y * (self / y);
    }
}
