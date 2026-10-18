// Comparisons and ULP steps: exact and ordered component tests, epsilon and ULP tests on scalars, vectors
// and matrices, and float steps by ULPs. Floats compare IEEE. The epsilon tests come in two kinds:
// `equal_eps` is `|x - y| <= eps`, `epsilon_equal` is `|x - y| < eps`.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;

/// A value the exact `equal` and `not_equal` take: a vector of any element type, a matrix, or a
/// quaternion.
pub interface Relational: Copy {
    /// `Vec<bool, N>` for a vector, `Vec<bool, C>` (one per column) for a matrix.
    type Bools;
    fn equal(self: Self, y: Self) Self::Bools;
    fn not_equal(self: Self, y: Self) Self::Bools;
}

/// `x[i] == y[i]` per component; per column of a matrix, all of its components.
pub fn equal<G: Relational>(x: G, y: G) G::Bools {
    return x.equal(y);
}

/// `x[i] != y[i]` per component; per column of a matrix, any of its components.
pub fn not_equal<G: Relational>(x: G, y: G) G::Bools {
    return x.not_equal(y);
}

/// A value `less_than`, `less_than_equal`, `greater_than` and `greater_than_equal` take: a vector of
/// numbers, or a quaternion. Its results are `Relational`'s `Bools`.
pub interface Ordered: Relational {
    fn less_than(self: Self, y: Self) Self::Bools;
    fn less_than_equal(self: Self, y: Self) Self::Bools;
    fn greater_than(self: Self, y: Self) Self::Bools;
    fn greater_than_equal(self: Self, y: Self) Self::Bools;
}

/// `x[i] < y[i]` per component (false where either is NaN).
pub fn less_than<G: Ordered>(x: G, y: G) G::Bools {
    return x.less_than(y);
}

/// `x[i] <= y[i]` per component.
pub fn less_than_equal<G: Ordered>(x: G, y: G) G::Bools {
    return x.less_than_equal(y);
}

/// `x[i] > y[i]` per component.
pub fn greater_than<G: Ordered>(x: G, y: G) G::Bools {
    return x.greater_than(y);
}

/// `x[i] >= y[i]` per component.
pub fn greater_than_equal<G: Ordered>(x: G, y: G) G::Bools {
    return x.greater_than_equal(y);
}

/// True when a component is true.
pub fn any<const N: usize>(v: Vec<bool, N>) bool {
    let mut r = false;
    for i in 0..N {
        r = r || unsafe v.e[i];
    }
    return r;
}

/// True when every component is true.
pub fn all<const N: usize>(v: Vec<bool, N>) bool {
    let mut r = true;
    for i in 0..N {
        r = r && unsafe v.e[i];
    }
    return r;
}

/// Each component negated.
pub fn not_<const N: usize>(v: Vec<bool, N>) Vec<bool, N> {
    let mut r = v;
    for i in 0..N {
        unsafe {
            r.e[i] = !v.e[i];
        }
    }
    return r;
}

/// A value `equal_eps` and `not_equal_eps` take with an epsilon of type `E`: a scalar with a `T`, a
/// vector with a `T` or a vector, a matrix with a `T` or a `Vec<T, C>` (one per column), or a quaternion
/// with a `T`.
pub interface EqualEps<E>: Copy {
    /// `bool` for a scalar, `Vec<bool, N>` for a vector, `Vec<bool, C>` for a matrix.
    type Bools;
    fn equal_eps(self: Self, y: Self, eps: E) Self::Bools;
    fn not_equal_eps(self: Self, y: Self, eps: E) Self::Bools;
}

/// `abs(x - y) <= epsilon` per component; per column of a matrix, all of its components against that
/// column's epsilon. A NaN compares unequal. An 8- or 16-bit integer scalar subtracts in `i64`, without
/// wrapping; a vector's components and a wider unsigned scalar wrap, and `abs` of an unsigned value is
/// the value (`equal_eps(0u32, 1u32, 1u32)` is false). A quaternion compares strictly
/// (`abs(x - y) < epsilon`).
pub fn equal_eps<E, G: EqualEps<E>>(x: G, y: G, eps: E) G::Bools {
    return x.equal_eps(y, eps);
}

/// `abs(x - y) > epsilon` per component; per column of a matrix, any of its components. A NaN compares
/// equal (the test is false).
pub fn not_equal_eps<E, G: EqualEps<E>>(x: G, y: G, eps: E) G::Bools {
    return x.not_equal_eps(y, eps);
}

/// A value `epsilon_equal` and `epsilon_not_equal` take with an epsilon of type `E`: an f32 or f64
/// scalar with a `T`, a vector of numbers with a `T` or a vector, or a quaternion with a `T`.
pub interface EpsilonEqual<E>: Copy {
    /// `bool` for a scalar, `Vec<bool, N>` for a vector.
    type Bools;
    fn epsilon_equal(self: Self, y: Self, eps: E) Self::Bools;
    fn epsilon_not_equal(self: Self, y: Self, eps: E) Self::Bools;
}

/// `abs(x - y) < epsilon` per component (strict, unlike `equal_eps`).
pub fn epsilon_equal<E, G: EpsilonEqual<E>>(x: G, y: G, eps: E) G::Bools {
    return x.epsilon_equal(y, eps);
}

/// `abs(x - y) >= epsilon` per component.
pub fn epsilon_not_equal<E, G: EpsilonEqual<E>>(x: G, y: G, eps: E) G::Bools {
    return x.epsilon_not_equal(y, eps);
}

/// A value `equal_ulps` and `not_equal_ulps` take with a ULP count of type `U`: an f32 or f64 scalar
/// with an `i32`, a vector with an `i32` or a `Vec<i32, N>`, a matrix with an `i32` or a `Vec<i32, C>`
/// (one per column).
pub interface EqualUlps<U>: Copy {
    /// `bool` for a scalar, `Vec<bool, N>` for a vector, `Vec<bool, C>` for a matrix.
    type Bools;
    fn equal_ulps(self: Self, y: Self, max_ulps: U) Self::Bools;
    fn not_equal_ulps(self: Self, y: Self, max_ulps: U) Self::Bools;
}

/// True when x and y have the same sign and their bit patterns differ by at most `max_ulps`. Signs
/// differ: a scalar gives false (-0 and +0 differ), a vector component gives true when only the sign bit
/// differs (-0 equals +0, and -1 equals 1). Per column of a matrix, all of its components.
pub fn equal_ulps<U, G: EqualUlps<U>>(x: G, y: G, max_ulps: U) G::Bools {
    return x.equal_ulps(y, max_ulps);
}

/// The negation of `equal_ulps` per component; per column of a matrix, any of its components.
pub fn not_equal_ulps<U, G: EqualUlps<U>>(x: G, y: G, max_ulps: U) G::Bools {
    return x.not_equal_ulps(y, max_ulps);
}

/// Each component's next value toward the largest finite value (`T::max_finite()`), so the largest
/// finite value and +inf give the largest finite value.
pub fn next_float<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, x.at(i).next_after(T::max_finite()));
    }
    return r;
}

/// Each component's next value toward the smallest positive normal value (`T::min_positive()`): values
/// above it step down, values below it (zero, subnormals, negative values) step up.
pub fn prev_float<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, x.at(i).next_after(T::min_positive()));
    }
    return r;
}

/// A value `next_float_ulps` and `prev_float_ulps` take with a ULP count of type `U`: an f32 or f64
/// scalar with an `i32`, a vector with an `i32` or a `Vec<i32, N>`.
pub interface FloatUlps<U>: Copy {
    fn next_float_ulps(self: Self, ulps: U) Self;
    fn prev_float_ulps(self: Self, ulps: U) Self;
}

/// `next_float` applied `ulps` times per component. Panics: a negative count.
pub fn next_float_ulps<U, G: FloatUlps<U>>(x: G, ulps: U) G {
    return x.next_float_ulps(ulps);
}

/// `prev_float` applied `ulps` times per component. Panics: a negative count.
pub fn prev_float_ulps<U, G: FloatUlps<U>>(x: G, ulps: U) G {
    return x.prev_float_ulps(ulps);
}

/// A value `float_distance` takes: an f32 or f64 scalar or vector.
pub interface FloatDistance: Copy {
    /// `i32` for f32, `i64` for f64; a vector of those for a vector.
    type Distance;
    fn float_distance(self: Self, y: Self) Self::Distance;
}

/// `abs(xi - yi)` per component, with xi and yi the bit patterns as signed integers. Opposite signs far
/// apart overflow: a trap in a profile with overflow checks.
pub fn float_distance<G: FloatDistance>(x: G, y: G) G::Distance {
    return x.float_distance(y);
}

// `x >= 0 ? x : -x` for a signed type or a float (-0 stays -0), `x` for an unsigned one.
fn scalar_abs<T: Scalar>(x: T) T {
    if !T::is_signed() || x.greater_equal(T::zero()) {
        return x;
    }
    return -x;
}

// The bits of `x` as a signed integer of its width, widened to i64.
fn float_int<T: Float>(x: T) i64 {
    let b = x.to_bits();
    if sizeof(T) == 4 {
        return (b as u32) as i32;
    }
    return b as i64;
}

// The scalar ULP test: false on different signs.
fn scalar_equal_ulps<T: Float>(x: T, y: T, max_ulps: i32) bool {
    let a = float_int(x);
    let b = float_int(y);
    if a < 0 != b < 0 {
        return false;
    }
    return scalar_abs(a - b) <= max_ulps as i64;
}

// The ULP test of one vector component: on different signs, equal mantissas and exponents.
fn component_equal_ulps<T: Float>(x: T, y: T, max_ulps: i32) bool {
    let a = float_int(x);
    let b = float_int(y);
    if a < 0 != b < 0 {
        let magnitude: i64 = if sizeof(T) == 4 {
            0x7FFFFFFF;
        } else {
            0x7FFFFFFFFFFFFFFF;
        };
        return ((a ^ b) & magnitude) == 0;
    }
    return scalar_abs(a - b) <= max_ulps as i64;
}

// `x` moved `n` times to its next value toward `toward`.
fn step_ulps<T: Float>(x: T, n: i32, toward: T) T {
    assert(n >= 0, "next_float_ulps / prev_float_ulps: negative ULP count");
    let mut t = x;
    for _ in 0..n {
        t = t.next_after(toward);
    }
    return t;
}

extend<T: Elem, const N: usize> Vec<T, N> as Relational {
    type Bools = Vec<bool, N>;
    pub fn equal(self: Vec<T, N>, y: Vec<T, N>) Vec<bool, N> {
        let mut r = Vec::<bool, N>::splat(true);
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].equal(y.e[i]);
            }
        }
        return r;
    }
    pub fn not_equal(self: Vec<T, N>, y: Vec<T, N>) Vec<bool, N> {
        let mut r = Vec::<bool, N>::splat(true);
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].not_equal(y.e[i]);
            }
        }
        return r;
    }
}

extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as Relational {
    type Bools = Vec<bool, C>;
    pub fn equal(self: Mat<T, C, R>, y: Mat<T, C, R>) Vec<bool, C> {
        let mut r = Vec::<bool, C>::splat(true);
        for i in 0..C {
            unsafe {
                r.e[i] = all(self.c[i].equal(y.c[i]));
            }
        }
        return r;
    }
    pub fn not_equal(self: Mat<T, C, R>, y: Mat<T, C, R>) Vec<bool, C> {
        let mut r = Vec::<bool, C>::splat(true);
        for i in 0..C {
            unsafe {
                r.e[i] = any(self.c[i].not_equal(y.c[i]));
            }
        }
        return r;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as Ordered {
    pub fn less_than(self: Vec<T, N>, y: Vec<T, N>) Vec<bool, N> {
        let mut r = Vec::<bool, N>::splat(true);
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].less(y.e[i]);
            }
        }
        return r;
    }
    pub fn less_than_equal(self: Vec<T, N>, y: Vec<T, N>) Vec<bool, N> {
        let mut r = Vec::<bool, N>::splat(true);
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].less_equal(y.e[i]);
            }
        }
        return r;
    }
    pub fn greater_than(self: Vec<T, N>, y: Vec<T, N>) Vec<bool, N> {
        let mut r = Vec::<bool, N>::splat(true);
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].greater(y.e[i]);
            }
        }
        return r;
    }
    pub fn greater_than_equal(self: Vec<T, N>, y: Vec<T, N>) Vec<bool, N> {
        let mut r = Vec::<bool, N>::splat(true);
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].greater_equal(y.e[i]);
            }
        }
        return r;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as EqualEps<Vec<T, N>> {
    type Bools = Vec<bool, N>;
    pub fn equal_eps(self: Vec<T, N>, y: Vec<T, N>, eps: Vec<T, N>) Vec<bool, N> {
        let mut r = Vec::<bool, N>::splat(true);
        for i in 0..N {
            unsafe {
                r.e[i] = scalar_abs(self.e[i] - y.e[i]).less_equal(eps.e[i]);
            }
        }
        return r;
    }
    pub fn not_equal_eps(self: Vec<T, N>, y: Vec<T, N>, eps: Vec<T, N>) Vec<bool, N> {
        let mut r = Vec::<bool, N>::splat(true);
        for i in 0..N {
            unsafe {
                r.e[i] = scalar_abs(self.e[i] - y.e[i]).greater(eps.e[i]);
            }
        }
        return r;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as EqualEps<T> {
    type Bools = Vec<bool, N>;
    pub fn equal_eps(self: Vec<T, N>, y: Vec<T, N>, eps: T) Vec<bool, N> {
        return self.equal_eps(y, Vec::<T, N>::splat(eps));
    }
    pub fn not_equal_eps(self: Vec<T, N>, y: Vec<T, N>, eps: T) Vec<bool, N> {
        return self.not_equal_eps(y, Vec::<T, N>::splat(eps));
    }
}

extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as EqualEps<Vec<T, C>> {
    type Bools = Vec<bool, C>;
    pub fn equal_eps(self: Mat<T, C, R>, y: Mat<T, C, R>, eps: Vec<T, C>) Vec<bool, C> {
        let mut r = Vec::<bool, C>::splat(true);
        for i in 0..C {
            unsafe {
                r.e[i] = all(self.c[i].equal_eps(y.c[i], eps.e[i]));
            }
        }
        return r;
    }
    pub fn not_equal_eps(self: Mat<T, C, R>, y: Mat<T, C, R>, eps: Vec<T, C>) Vec<bool, C> {
        let mut r = Vec::<bool, C>::splat(true);
        for i in 0..C {
            unsafe {
                r.e[i] = any(self.c[i].not_equal_eps(y.c[i], eps.e[i]));
            }
        }
        return r;
    }
}

extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as EqualEps<T> {
    type Bools = Vec<bool, C>;
    pub fn equal_eps(self: Mat<T, C, R>, y: Mat<T, C, R>, eps: T) Vec<bool, C> {
        return self.equal_eps(y, Vec::<T, C>::splat(eps));
    }
    pub fn not_equal_eps(self: Mat<T, C, R>, y: Mat<T, C, R>, eps: T) Vec<bool, C> {
        return self.not_equal_eps(y, Vec::<T, C>::splat(eps));
    }
}

extend<T: Scalar> T as EqualEps<T> {
    type Bools = bool;
    pub fn equal_eps(self: T, y: T, eps: T) bool {
        if promotes::<T>() {
            return scalar_abs(self.cast::<i64>() - y.cast::<i64>()) <= eps.cast::<i64>();
        }
        return scalar_abs(self - y).less_equal(eps);
    }
    pub fn not_equal_eps(self: T, y: T, eps: T) bool {
        if promotes::<T>() {
            return scalar_abs(self.cast::<i64>() - y.cast::<i64>()) > eps.cast::<i64>();
        }
        return scalar_abs(self - y).greater(eps);
    }
}

// An 8- or 16-bit integer scalar subtracts in `i64`, so `x - y` does not wrap.
fn promotes<T: Scalar>() bool {
    return !T::is_float() && sizeof(T) < 4;
}

extend<T: Scalar, const N: usize> Vec<T, N> as EpsilonEqual<Vec<T, N>> {
    type Bools = Vec<bool, N>;
    pub fn epsilon_equal(self: Vec<T, N>, y: Vec<T, N>, eps: Vec<T, N>) Vec<bool, N> {
        let mut r = Vec::<bool, N>::splat(true);
        for i in 0..N {
            unsafe {
                r.e[i] = scalar_abs(self.e[i] - y.e[i]).less(eps.e[i]);
            }
        }
        return r;
    }
    pub fn epsilon_not_equal(self: Vec<T, N>, y: Vec<T, N>, eps: Vec<T, N>) Vec<bool, N> {
        let mut r = Vec::<bool, N>::splat(true);
        for i in 0..N {
            unsafe {
                r.e[i] = scalar_abs(self.e[i] - y.e[i]).greater_equal(eps.e[i]);
            }
        }
        return r;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as EpsilonEqual<T> {
    type Bools = Vec<bool, N>;
    pub fn epsilon_equal(self: Vec<T, N>, y: Vec<T, N>, eps: T) Vec<bool, N> {
        return self.epsilon_equal(y, Vec::<T, N>::splat(eps));
    }
    pub fn epsilon_not_equal(self: Vec<T, N>, y: Vec<T, N>, eps: T) Vec<bool, N> {
        return self.epsilon_not_equal(y, Vec::<T, N>::splat(eps));
    }
}

extend<T: Float> T as EpsilonEqual<T> {
    type Bools = bool;
    pub fn epsilon_equal(self: T, y: T, eps: T) bool {
        return scalar_abs(self - y).less(eps);
    }
    pub fn epsilon_not_equal(self: T, y: T, eps: T) bool {
        return scalar_abs(self - y).greater_equal(eps);
    }
}

extend<T: Float, const N: usize> Vec<T, N> as EqualUlps<Vec<i32, N>> {
    type Bools = Vec<bool, N>;
    pub fn equal_ulps(self: Vec<T, N>, y: Vec<T, N>, max_ulps: Vec<i32, N>) Vec<bool, N> {
        let mut r = Vec::<bool, N>::splat(false);
        for i in 0..N {
            unsafe {
                r.e[i] = component_equal_ulps(self.e[i], y.e[i], max_ulps.e[i]);
            }
        }
        return r;
    }
    pub fn not_equal_ulps(self: Vec<T, N>, y: Vec<T, N>, max_ulps: Vec<i32, N>) Vec<bool, N> {
        return not_(self.equal_ulps(y, max_ulps));
    }
}

extend<T: Float, const N: usize> Vec<T, N> as EqualUlps<i32> {
    type Bools = Vec<bool, N>;
    pub fn equal_ulps(self: Vec<T, N>, y: Vec<T, N>, max_ulps: i32) Vec<bool, N> {
        return self.equal_ulps(y, Vec::<i32, N>::splat(max_ulps));
    }
    pub fn not_equal_ulps(self: Vec<T, N>, y: Vec<T, N>, max_ulps: i32) Vec<bool, N> {
        return self.not_equal_ulps(y, Vec::<i32, N>::splat(max_ulps));
    }
}

extend<T: Float, const C: usize, const R: usize> Mat<T, C, R> as EqualUlps<Vec<i32, C>> {
    type Bools = Vec<bool, C>;
    pub fn equal_ulps(self: Mat<T, C, R>, y: Mat<T, C, R>, max_ulps: Vec<i32, C>) Vec<bool, C> {
        let mut r = Vec::<bool, C>::splat(true);
        for i in 0..C {
            unsafe {
                r.e[i] = all(self.c[i].equal_ulps(y.c[i], max_ulps.e[i]));
            }
        }
        return r;
    }
    pub fn not_equal_ulps(self: Mat<T, C, R>, y: Mat<T, C, R>, max_ulps: Vec<i32, C>) Vec<bool, C> {
        let mut r = Vec::<bool, C>::splat(true);
        for i in 0..C {
            unsafe {
                r.e[i] = any(self.c[i].not_equal_ulps(y.c[i], max_ulps.e[i]));
            }
        }
        return r;
    }
}

extend<T: Float, const C: usize, const R: usize> Mat<T, C, R> as EqualUlps<i32> {
    type Bools = Vec<bool, C>;
    pub fn equal_ulps(self: Mat<T, C, R>, y: Mat<T, C, R>, max_ulps: i32) Vec<bool, C> {
        return self.equal_ulps(y, Vec::<i32, C>::splat(max_ulps));
    }
    pub fn not_equal_ulps(self: Mat<T, C, R>, y: Mat<T, C, R>, max_ulps: i32) Vec<bool, C> {
        return self.not_equal_ulps(y, Vec::<i32, C>::splat(max_ulps));
    }
}

extend<T: Float> T as EqualUlps<i32> {
    type Bools = bool;
    pub fn equal_ulps(self: T, y: T, max_ulps: i32) bool {
        return scalar_equal_ulps(self, y, max_ulps);
    }
    pub fn not_equal_ulps(self: T, y: T, max_ulps: i32) bool {
        return !scalar_equal_ulps(self, y, max_ulps);
    }
}

extend<T: Float, const N: usize> Vec<T, N> as FloatUlps<Vec<i32, N>> {
    pub fn next_float_ulps(self: Vec<T, N>, ulps: Vec<i32, N>) Vec<T, N> {
        let mut r = self;
        for i in 0..N {
            unsafe {
                r.e[i] = step_ulps(self.e[i], ulps.e[i], T::max_finite());
            }
        }
        return r;
    }
    pub fn prev_float_ulps(self: Vec<T, N>, ulps: Vec<i32, N>) Vec<T, N> {
        let mut r = self;
        for i in 0..N {
            unsafe {
                r.e[i] = step_ulps(self.e[i], ulps.e[i], T::min_positive());
            }
        }
        return r;
    }
}

extend<T: Float, const N: usize> Vec<T, N> as FloatUlps<i32> {
    pub fn next_float_ulps(self: Vec<T, N>, ulps: i32) Vec<T, N> {
        return self.next_float_ulps(Vec::<i32, N>::splat(ulps));
    }
    pub fn prev_float_ulps(self: Vec<T, N>, ulps: i32) Vec<T, N> {
        return self.prev_float_ulps(Vec::<i32, N>::splat(ulps));
    }
}

extend<T: Float> T as FloatUlps<i32> {
    pub fn next_float_ulps(self: T, ulps: i32) T {
        return step_ulps(self, ulps, T::max_finite());
    }
    pub fn prev_float_ulps(self: T, ulps: i32) T {
        return step_ulps(self, ulps, T::min_positive());
    }
}

extend f32 as FloatDistance {
    type Distance = i32;
    pub fn float_distance(self: f32, y: f32) i32 {
        return scalar_abs(f32_bits(self) as i32 - f32_bits(y) as i32);
    }
}

extend f64 as FloatDistance {
    type Distance = i64;
    pub fn float_distance(self: f64, y: f64) i64 {
        return scalar_abs(f64_bits(self) as i64 - f64_bits(y) as i64);
    }
}

extend<const N: usize> Vec<f32, N> as FloatDistance {
    type Distance = Vec<i32, N>;
    pub fn float_distance(self: Vec<f32, N>, y: Vec<f32, N>) Vec<i32, N> {
        let mut r = Vec::<i32, N>::zero();
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].float_distance(y.e[i]);
            }
        }
        return r;
    }
}

extend<const N: usize> Vec<f64, N> as FloatDistance {
    type Distance = Vec<i64, N>;
    pub fn float_distance(self: Vec<f64, N>, y: Vec<f64, N>) Vec<i64, N> {
        let mut r = Vec::<i64, N>::zero();
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].float_distance(y.e[i]);
            }
        }
        return r;
    }
}
