// Common functions on scalars, vectors and matrices: rounding, min and max, clamp, mix, step,
// classification, float bits and component reductions. `min`, `max` and `clamp` compare with `<`: a NaN
// first argument propagates, a NaN second argument loses. `abs` is `x >= 0 ? x : -x`, so `abs(-0.0)` is
// -0.0.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;

fn min_of<T: Scalar>(x: T, y: T) T {
    if y.less(x) {
        return y;
    }
    return x;
}

fn max_of<T: Scalar>(x: T, y: T) T {
    if x.less(y) {
        return y;
    }
    return x;
}

fn abs_of<T: Scalar>(x: T) T {
    if x.greater_equal(T::zero()) {
        return x;
    }
    return -x;
}

fn lerp<T: Scalar, U: Float>(x: T, y: T, a: U) T {
    return (x.cast::<U>() * (U::one() - a) + y.cast::<U>() * a).cast::<T>();
}

fn fract_of<T: Float>(x: T) T {
    return x - x.floor();
}

fn mod_of<T: Float>(x: T, y: T) T {
    return x - y * (x / y).floor();
}

/// A value `abs` takes: a number, a vector or a matrix.
pub interface Abs: Copy {
    fn abs(self: Self) Self;
}

/// The absolute value, component by component: `x >= 0 ? x : -x`, so -0.0 stays -0.0 and a NaN stays a
/// NaN; an unsigned value is returned unchanged.
pub fn abs<G: Abs>(x: G) G {
    return x.abs();
}

extend<T: Scalar> T as Abs {
    pub fn abs(self: T) T {
        return abs_of(self);
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as Abs {
    pub fn abs(self: Vec<T, N>) Vec<T, N> {
        let mut r = self;
        for i in 0..N {
            unsafe {
                r.e[i] = abs_of(self.e[i]);
            }
        }
        return r;
    }
}

extend<T: Scalar, const C: usize, const R: usize> Mat<T, C, R> as Abs {
    pub fn abs(self: Mat<T, C, R>) Mat<T, C, R> {
        let mut m = self;
        for i in 0..C {
            unsafe {
                m.c[i] = Abs::abs(self.c[i]);
            }
        }
        return m;
    }
}

/// 1, 0 or -1 for each component: `(0 < x) - (x < 0)` with each comparison as 1 or 0, so +0.0 for a zero
/// or a NaN. An unsigned `T` is a compile error.
pub fn sign<T: Scalar, G: Gen<T>>(x: G) G {
    static_assert(T::is_signed(), "'sign' only accepts signed inputs");
    let mut r = x;
    for i in 0..G::len() {
        let v = x.at(i);
        let p = if T::zero().less(v) {
            T::one();
        } else {
            T::zero();
        };
        let n = if v.less(T::zero()) {
            T::one();
        } else {
            T::zero();
        };
        r.put(i, p - n);
    }
    return r;
}

/// Each component rounded toward negative infinity.
pub fn floor<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, x.at(i).floor());
    }
    return r;
}

/// Each component rounded toward positive infinity.
pub fn ceil<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, x.at(i).ceil());
    }
    return r;
}

/// Each component rounded toward zero.
pub fn trunc<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, x.at(i).trunc());
    }
    return r;
}

/// Each component rounded to the nearest integer, halves away from zero.
pub fn round<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, x.at(i).round());
    }
    return r;
}

/// Each component rounded to the nearest integer, halves to the even one. A NaN component gives +0.0; an
/// infinity, or an `f64` half outside the `i32` range, gives 2^31 with the sign of the component.
pub fn round_even<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        let v = x.at(i);
        let integer = v.cast::<i32>();
        let integer_part = integer.cast::<T>();
        let fractional = fract_of(v);
        let half = T::from_f64(0.5);
        let rounded = if fractional.greater(half) || fractional.less(half) {
            v.round();
        } else if integer % 2 == 0 {
            integer_part;
        } else if v.less_equal(T::zero()) {
            integer_part - T::one();
        } else {
            integer_part + T::one();
        };
        r.put(i, rounded);
    }
    return r;
}

/// `x - floor(x)`, component by component.
pub fn fract<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, fract_of(x.at(i)));
    }
    return r;
}

/// `x - y * floor(x / y)`, component by component; `y` is a `G` or a scalar.
pub fn mod<T: Float, G: Gen<T>, B: Arg<G>>(x: G, y: B) G {
    let d = y.to_gen();
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, mod_of(x.at(i), d.at(i)));
    }
    return r;
}

/// (fractional part, integral part) of each component, both with the sign of `x`.
pub fn modf<T: Float, G: Gen<T>>(x: G) (G, G) {
    let mut f = x;
    let mut n = x;
    for i in 0..G::len() {
        let (a, b) = x.at(i).modf();
        f.put(i, a);
        n.put(i, b);
    }
    return f, n;
}

/// `(y < x) ? y : x`, component by component; `y` is a `G` or a scalar.
pub fn min<T: Scalar, G: Gen<T>, B: Arg<G>>(x: G, y: B) G {
    let b = y.to_gen();
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, min_of(x.at(i), b.at(i)));
    }
    return r;
}

/// `(x < y) ? y : x`, component by component; `y` is a `G` or a scalar.
pub fn max<T: Scalar, G: Gen<T>, B: Arg<G>>(x: G, y: B) G {
    let b = y.to_gen();
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, max_of(x.at(i), b.at(i)));
    }
    return r;
}

/// `min(max(x, lo), hi)`, component by component; `lo` and `hi` are each a `G` or a scalar.
pub fn clamp<T: Scalar, G: Gen<T>, B: Arg<G>>(x: G, lo: B, hi: B) G {
    let l = lo.to_gen();
    let h = hi.to_gen();
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, min_of(max_of(x.at(i), l.at(i)), h.at(i)));
    }
    return r;
}

/// `clamp(x, 0, 1)`.
pub fn clamp_unit<T: Scalar, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, min_of(max_of(x.at(i), T::zero()), T::one()));
    }
    return r;
}

/// The interpolants `mix(x, y, a)` takes for an `x` of type `Self`.
pub interface Mix<A>: Copy {
    fn mix(self: Self, y: Self, a: A) Self;
}

/// `x * (1 - a) + y * a` computed in the interpolant's float type and converted back (`a` is an `f32` or
/// an `f64`, a vector of them, or for a square matrix a matrix of them, for each component), or
/// `a ? y : x` for a `bool` or a `Vec<bool, N>` `a`; for quaternions, a spherical interpolation. An
/// unsuffixed literal `a` is an `f32`: write `0.5f64` to interpolate in `f64`.
pub fn mix<G: Mix<A>, A>(x: G, y: G, a: A) G {
    return x.mix(y, a);
}

extend<T: Scalar, U: Float> T as Mix<U> {
    pub fn mix(self: T, y: T, a: U) T {
        return lerp(self, y, a);
    }
}

extend<T: Scalar> T as Mix<bool> {
    pub fn mix(self: T, y: T, a: bool) T {
        if a {
            return y;
        }
        return self;
    }
}

extend<T: Scalar, U: Float, const N: usize> Vec<T, N> as Mix<U> {
    pub fn mix(self: Vec<T, N>, y: Vec<T, N>, a: U) Vec<T, N> {
        return mix_vec(self, y, Vec::<U, N>::splat(a));
    }
}

extend<T: Scalar, U: Float, const N: usize> Vec<T, N> as Mix<Vec<U, N>> {
    pub fn mix(self: Vec<T, N>, y: Vec<T, N>, a: Vec<U, N>) Vec<T, N> {
        return mix_vec(self, y, a);
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as Mix<bool> {
    pub fn mix(self: Vec<T, N>, y: Vec<T, N>, a: bool) Vec<T, N> {
        if a {
            return y;
        }
        return self;
    }
}

extend<T: Scalar, const N: usize> Vec<T, N> as Mix<Vec<bool, N>> {
    pub fn mix(self: Vec<T, N>, y: Vec<T, N>, a: Vec<bool, N>) Vec<T, N> {
        let mut r = self;
        for i in 0..N {
            unsafe {
                if a.e[i] {
                    r.e[i] = y.e[i];
                }
            }
        }
        return r;
    }
}

extend<T: Scalar, U: Float, const C: usize, const R: usize> Mat<T, C, R> as Mix<U> {
    pub fn mix(self: Mat<T, C, R>, y: Mat<T, C, R>, a: U) Mat<T, C, R> {
        return mix_mat(self, y, Mat::<U, C, R> { c: [Vec::<U, R>::splat(a); C] });
    }
}

extend<T: Scalar, U: Float> Mat<T, 2, 2> as Mix<Mat<U, 2, 2>> {
    pub fn mix(self: Mat<T, 2, 2>, y: Mat<T, 2, 2>, a: Mat<U, 2, 2>) Mat<T, 2, 2> {
        return mix_mat(self, y, a);
    }
}

extend<T: Scalar, U: Float> Mat<T, 3, 3> as Mix<Mat<U, 3, 3>> {
    pub fn mix(self: Mat<T, 3, 3>, y: Mat<T, 3, 3>, a: Mat<U, 3, 3>) Mat<T, 3, 3> {
        return mix_mat(self, y, a);
    }
}

extend<T: Scalar, U: Float> Mat<T, 4, 4> as Mix<Mat<U, 4, 4>> {
    pub fn mix(self: Mat<T, 4, 4>, y: Mat<T, 4, 4>, a: Mat<U, 4, 4>) Mat<T, 4, 4> {
        return mix_mat(self, y, a);
    }
}

fn mix_vec<T: Scalar, U: Float, const N: usize>(x: Vec<T, N>, y: Vec<T, N>, a: Vec<U, N>) Vec<T, N> {
    let mut r = x;
    for i in 0..N {
        unsafe {
            r.e[i] = lerp(x.e[i], y.e[i], a.e[i]);
        }
    }
    return r;
}

fn mix_mat<T: Scalar, U: Float, const C: usize, const R: usize>(x: Mat<T, C, R>, y: Mat<T, C, R>, a: Mat<U, C, R>) Mat<
    T,
    C,
    R
> {
    let mut m = x;
    for i in 0..C {
        unsafe {
            m.c[i] = mix_vec(x.c[i], y.c[i], a.c[i]);
        }
    }
    return m;
}

/// `x < edge ? 0 : 1`, component by component; `edge` is a `G` or a scalar.
pub fn step<T: Scalar, G: Gen<T>, B: Arg<G>>(edge: B, x: G) G {
    let e = edge.to_gen();
    let mut r = x;
    for i in 0..G::len() {
        let v = if x.at(i).less(e.at(i)) {
            T::zero();
        } else {
            T::one();
        };
        r.put(i, v);
    }
    return r;
}

/// `t * t * (3 - 2 * t)` with `t = clamp((x - edge0) / (edge1 - edge0), 0, 1)`, component by component;
/// each edge is a `G` or a scalar.
pub fn smoothstep<T: Float, G: Gen<T>, B: Arg<G>>(edge0: B, edge1: B, x: G) G {
    let e0 = edge0.to_gen();
    let e1 = edge1.to_gen();
    let mut r = x;
    for i in 0..G::len() {
        let t = min_of(max_of((x.at(i) - e0.at(i)) / (e1.at(i) - e0.at(i)), T::zero()), T::one());
        r.put(i, t * t * (T::from_i64(3) - T::from_i64(2) * t));
    }
    return r;
}

/// A value `isnan` and `isinf` take: a float scalar, vector or quaternion, with
/// `Bools` the result: `bool` for a scalar, `Vec<bool, N>` for a vector, `Vec<bool, 4>` for a quaternion.
pub interface Classify: Copy {
    type Bools;
    fn isnan(self: Self) Self::Bools;
    fn isinf(self: Self) Self::Bools;
}

/// True for each NaN component.
pub fn isnan<G: Classify>(x: G) G::Bools {
    return x.isnan();
}

/// True for each infinite component.
pub fn isinf<G: Classify>(x: G) G::Bools {
    return x.isinf();
}

extend<T: Float> T as Classify {
    type Bools = bool;
    pub fn isnan(self: T) bool {
        return self.is_nan();
    }
    pub fn isinf(self: T) bool {
        return self.is_inf();
    }
}

extend<T: Float, const N: usize> Vec<T, N> as Classify {
    type Bools = Vec<bool, N>;
    pub fn isnan(self: Vec<T, N>) Vec<bool, N> {
        let mut r = Vec::<bool, N>::splat(false);
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].is_nan();
            }
        }
        return r;
    }
    pub fn isinf(self: Vec<T, N>) Vec<bool, N> {
        let mut r = Vec::<bool, N>::splat(false);
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].is_inf();
            }
        }
        return r;
    }
}

/// An `f32` scalar or vector, with `Ints` and `UInts` the `i32` and `u32` scalar or vector of the same
/// shape: what `float_bits_to_int` and `float_bits_to_uint` take.
pub interface FloatBits: Copy {
    type Ints;
    type UInts;
    fn float_bits_to_int(self: Self) Self::Ints;
    fn float_bits_to_uint(self: Self) Self::UInts;
}

/// The bits of each `f32` component as an `i32`.
pub fn float_bits_to_int<G: FloatBits>(v: G) G::Ints {
    return v.float_bits_to_int();
}

/// The bits of each `f32` component as a `u32`.
pub fn float_bits_to_uint<G: FloatBits>(v: G) G::UInts {
    return v.float_bits_to_uint();
}

extend f32 as FloatBits {
    type Ints = i32;
    type UInts = u32;
    pub fn float_bits_to_int(self: f32) i32 {
        return self.bits_int();
    }
    pub fn float_bits_to_uint(self: f32) u32 {
        return self.bits_uint();
    }
}

extend<const N: usize> Vec<f32, N> as FloatBits {
    type Ints = Vec<i32, N>;
    type UInts = Vec<u32, N>;
    pub fn float_bits_to_int(self: Vec<f32, N>) Vec<i32, N> {
        let mut r = Vec::<i32, N>::zero();
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].bits_int();
            }
        }
        return r;
    }
    pub fn float_bits_to_uint(self: Vec<f32, N>) Vec<u32, N> {
        let mut r = Vec::<u32, N>::zero();
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].bits_uint();
            }
        }
        return r;
    }
}

/// An `I` scalar or vector (`I` is `i32` or `u32`), with `Floats` the `f32` scalar or vector of the same
/// shape: what `int_bits_to_float` (`I = i32`) and `uint_bits_to_float` (`I = u32`) take.
pub interface IntBits<I>: Copy {
    type Floats;
    fn bits_to_float(self: Self) Self::Floats;
}

/// Each `i32` component's bits as an `f32`.
pub fn int_bits_to_float<G: IntBits<i32>>(v: G) G::Floats {
    return v.bits_to_float();
}

/// Each `u32` component's bits as an `f32`.
pub fn uint_bits_to_float<G: IntBits<u32>>(v: G) G::Floats {
    return v.bits_to_float();
}

extend i32 as IntBits<i32> {
    type Floats = f32;
    pub fn bits_to_float(self: i32) f32 {
        return f32::from_bits_int(self);
    }
}

extend u32 as IntBits<u32> {
    type Floats = f32;
    pub fn bits_to_float(self: u32) f32 {
        return f32::from_bits_uint(self);
    }
}

extend<const N: usize> Vec<i32, N> as IntBits<i32> {
    type Floats = Vec<f32, N>;
    pub fn bits_to_float(self: Vec<i32, N>) Vec<f32, N> {
        let mut r = Vec::<f32, N>::zero();
        for i in 0..N {
            unsafe {
                r.e[i] = f32::from_bits_int(self.e[i]);
            }
        }
        return r;
    }
}

extend<const N: usize> Vec<u32, N> as IntBits<u32> {
    type Floats = Vec<f32, N>;
    pub fn bits_to_float(self: Vec<u32, N>) Vec<f32, N> {
        let mut r = Vec::<f32, N>::zero();
        for i in 0..N {
            unsafe {
                r.e[i] = f32::from_bits_uint(self.e[i]);
            }
        }
        return r;
    }
}

/// A value `fma` takes: a float scalar or vector.
pub interface Fma: Copy {
    fn fma(self: Self, b: Self, c: Self) Self;
}

/// `a * b + c`: one rounding for a scalar, two roundings (product, then sum) for a vector.
pub fn fma<G: Fma>(a: G, b: G, c: G) G {
    return a.fma(b, c);
}

// On a `T: Float`, `self.fma(b, c)` calls the bound's `Float::fma` (one rounding), not this conformance.
extend<T: Float> T as Fma {
    pub fn fma(self: T, b: T, c: T) T {
        return self.fma(b, c);
    }
}

extend<T: Float, const N: usize> Vec<T, N> as Fma {
    pub fn fma(self: Vec<T, N>, b: Vec<T, N>, c: Vec<T, N>) Vec<T, N> {
        return self * b + c;
    }
}

/// A float scalar or vector, with `Ints` and `UInts` the `i32` and `u32` scalar or vector of the same
/// shape: what `frexp`, `ldexp`, `iround` and `uround` take.
pub interface IntShaped: Copy {
    type Ints;
    type UInts;
    fn frexp(self: Self) (Self, Self::Ints);
    fn ldexp(self: Self, exp: Self::Ints) Self;
    fn iround(self: Self) Self::Ints;
    fn uround(self: Self) Self::UInts;
}

/// (mantissa, exponent) of each component: the mantissa's magnitude is in [0.5, 1), or it is the zero,
/// infinity or NaN itself with exponent 0.
pub fn frexp<G: IntShaped>(x: G) (G, G::Ints) {
    let (m, e) = x.frexp();
    return m, e;
}

/// `x * 2^exp` for each component.
pub fn ldexp<G: IntShaped>(x: G, exp: G::Ints) G {
    return x.ldexp(exp);
}

/// `x + 0.5` truncated to an `i32` for each component. Panics on a negative or NaN component.
pub fn iround<G: IntShaped>(x: G) G::Ints {
    return x.iround();
}

/// `x + 0.5` truncated to a `u32` for each component. Panics on a negative or NaN component.
pub fn uround<G: IntShaped>(x: G) G::UInts {
    return x.uround();
}

fn iround_of<T: Float>(x: T) i32 {
    assert(T::zero().less_equal(x), "iround: x must not be negative");
    return (x + T::from_f64(0.5)).cast::<i32>();
}

fn uround_of<T: Float>(x: T) u32 {
    assert(T::zero().less_equal(x), "uround: x must not be negative");
    return (x + T::from_f64(0.5)).cast::<u32>();
}

extend<T: Float> T as IntShaped {
    type Ints = i32;
    type UInts = u32;
    pub fn frexp(self: T) (T, i32) {
        let (m, e) = Float::frexp(self);
        return m, e;
    }
    pub fn ldexp(self: T, exp: i32) T {
        return Float::ldexp(self, exp);
    }
    pub fn iround(self: T) i32 {
        return iround_of(self);
    }
    pub fn uround(self: T) u32 {
        return uround_of(self);
    }
}

extend<T: Float, const N: usize> Vec<T, N> as IntShaped {
    type Ints = Vec<i32, N>;
    type UInts = Vec<u32, N>;
    pub fn frexp(self: Vec<T, N>) (Vec<T, N>, Vec<i32, N>) {
        let mut m = self;
        let mut e = Vec::<i32, N>::zero();
        for i in 0..N {
            unsafe {
                let (a, b) = self.e[i].frexp();
                m.e[i] = a;
                e.e[i] = b;
            }
        }
        return m, e;
    }
    pub fn ldexp(self: Vec<T, N>, exp: Vec<i32, N>) Vec<T, N> {
        let mut r = self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].ldexp(exp.e[i]);
            }
        }
        return r;
    }
    pub fn iround(self: Vec<T, N>) Vec<i32, N> {
        let mut r = Vec::<i32, N>::zero();
        for i in 0..N {
            unsafe {
                r.e[i] = iround_of(self.e[i]);
            }
        }
        return r;
    }
    pub fn uround(self: Vec<T, N>) Vec<u32, N> {
        let mut r = Vec::<u32, N>::zero();
        for i in 0..N {
            unsafe {
                r.e[i] = uround_of(self.e[i]);
            }
        }
        return r;
    }
}

/// `min(min(a, b), c)`.
pub fn min3<T: Scalar, G: Gen<T>>(a: G, b: G, c: G) G {
    let mut r = a;
    for i in 0..G::len() {
        r.put(i, min_of(min_of(a.at(i), b.at(i)), c.at(i)));
    }
    return r;
}

/// `min(min(a, b), min(c, d))`.
pub fn min4<T: Scalar, G: Gen<T>>(a: G, b: G, c: G, d: G) G {
    let mut r = a;
    for i in 0..G::len() {
        r.put(i, min_of(min_of(a.at(i), b.at(i)), min_of(c.at(i), d.at(i))));
    }
    return r;
}

/// `max(max(a, b), c)`.
pub fn max3<T: Scalar, G: Gen<T>>(a: G, b: G, c: G) G {
    let mut r = a;
    for i in 0..G::len() {
        r.put(i, max_of(max_of(a.at(i), b.at(i)), c.at(i)));
    }
    return r;
}

/// `max(max(a, b), max(c, d))`.
pub fn max4<T: Scalar, G: Gen<T>>(a: G, b: G, c: G, d: G) G {
    let mut r = a;
    for i in 0..G::len() {
        r.put(i, max_of(max_of(a.at(i), b.at(i)), max_of(c.at(i), d.at(i))));
    }
    return r;
}

/// The smaller value for each component, a NaN losing to a number; `b` is a `G` or a scalar.
pub fn fmin<T: Float, G: Gen<T>, B: Arg<G>>(a: G, b: B) G {
    let v = b.to_gen();
    let mut r = a;
    for i in 0..G::len() {
        r.put(i, a.at(i).fmin(v.at(i)));
    }
    return r;
}

/// The larger value for each component, a NaN losing to a number; `b` is a `G` or a scalar.
pub fn fmax<T: Float, G: Gen<T>, B: Arg<G>>(a: G, b: B) G {
    let v = b.to_gen();
    let mut r = a;
    for i in 0..G::len() {
        r.put(i, a.at(i).fmax(v.at(i)));
    }
    return r;
}

/// `fmin(fmax(x, lo), hi)`, component by component, so a NaN loses to a number; `lo` and `hi` are each
/// a `G` or a scalar.
pub fn fclamp<T: Float, G: Gen<T>, B: Arg<G>>(x: G, lo: B, hi: B) G {
    let l = lo.to_gen();
    let h = hi.to_gen();
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, x.at(i).fmax(l.at(i)).fmin(h.at(i)));
    }
    return r;
}

/// A value `fmin3`, `fmin4`, `fmax3` and `fmax4` take: a float scalar or vector.
pub interface FMinMax: Copy {
    fn fmin3(self: Self, b: Self, c: Self) Self;
    fn fmin4(self: Self, b: Self, c: Self, d: Self) Self;
    fn fmax3(self: Self, b: Self, c: Self) Self;
    fn fmax4(self: Self, b: Self, c: Self, d: Self) Self;
}

/// The smallest number of the three, NaNs ignored. A scalar takes `min(min(a, b), c)` when no argument
/// is a NaN (so `fmin3(0.0, -0.0, 1.0)` is +0.0) and a vector takes `fmin(fmin(a, b), c)` for each
/// component.
pub fn fmin3<G: FMinMax>(a: G, b: G, c: G) G {
    return a.fmin3(b, c);
}

/// The smallest number of the four, NaNs ignored; a scalar without NaN takes `min(min(a, b), min(c, d))`,
/// a vector `fmin(fmin(a, b), fmin(c, d))`.
pub fn fmin4<G: FMinMax>(a: G, b: G, c: G, d: G) G {
    return a.fmin4(b, c, d);
}

/// The largest number of the three, NaNs ignored, with the operation order of `fmin3`.
pub fn fmax3<G: FMinMax>(a: G, b: G, c: G) G {
    return a.fmax3(b, c);
}

/// The largest number of the four, NaNs ignored, with the operation order of `fmin4`.
pub fn fmax4<G: FMinMax>(a: G, b: G, c: G, d: G) G {
    return a.fmax4(b, c, d);
}

extend<T: Float> T as FMinMax {
    pub fn fmin3(self: T, b: T, c: T) T {
        if self.is_nan() {
            return b.fmin(c);
        }
        if b.is_nan() {
            return self.fmin(c);
        }
        if c.is_nan() {
            return min_of(self, b);
        }
        return min_of(min_of(self, b), c);
    }
    pub fn fmin4(self: T, b: T, c: T, d: T) T {
        if self.is_nan() {
            return b.fmin3(c, d);
        }
        if b.is_nan() {
            return min_of(self, c.fmin(d));
        }
        if c.is_nan() {
            return min_of(self, b).fmin(d);
        }
        if d.is_nan() {
            return min_of(min_of(self, b), c);
        }
        return min_of(min_of(self, b), min_of(c, d));
    }
    pub fn fmax3(self: T, b: T, c: T) T {
        if self.is_nan() {
            return b.fmax(c);
        }
        if b.is_nan() {
            return self.fmax(c);
        }
        if c.is_nan() {
            return max_of(self, b);
        }
        return max_of(max_of(self, b), c);
    }
    pub fn fmax4(self: T, b: T, c: T, d: T) T {
        if self.is_nan() {
            return b.fmax3(c, d);
        }
        if b.is_nan() {
            return max_of(self, c.fmax(d));
        }
        if c.is_nan() {
            return max_of(self, b).fmax(d);
        }
        if d.is_nan() {
            return max_of(max_of(self, b), c);
        }
        return max_of(max_of(self, b), max_of(c, d));
    }
}

extend<T: Float, const N: usize> Vec<T, N> as FMinMax {
    pub fn fmin3(self: Vec<T, N>, b: Vec<T, N>, c: Vec<T, N>) Vec<T, N> {
        return fmin(fmin(self, b), c);
    }
    pub fn fmin4(self: Vec<T, N>, b: Vec<T, N>, c: Vec<T, N>, d: Vec<T, N>) Vec<T, N> {
        return fmin(fmin(self, b), fmin(c, d));
    }
    pub fn fmax3(self: Vec<T, N>, b: Vec<T, N>, c: Vec<T, N>) Vec<T, N> {
        return fmax(fmax(self, b), c);
    }
    pub fn fmax4(self: Vec<T, N>, b: Vec<T, N>, c: Vec<T, N>, d: Vec<T, N>) Vec<T, N> {
        return fmax(fmax(self, b), fmax(c, d));
    }
}

/// The texture coordinate wrapped to [0, 1): `fract(x)`.
pub fn repeat<T: Float, G: Gen<T>>(x: G) G {
    return fract(x);
}

/// `fract(abs(x))`.
pub fn mirror_clamp<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, fract_of(abs_of(x.at(i))));
    }
    return r;
}

/// The coordinate mirrored on every other unit interval:
/// `mod(floor(abs(x)), 2) + rest >= 1 ? 1 - rest : rest`, with `rest = abs(x) - floor(abs(x))`.
pub fn mirror_repeat<T: Float, G: Gen<T>>(x: G) G {
    let two = T::from_i64(2);
    let mut r = x;
    for i in 0..G::len() {
        let a = abs_of(x.at(i));
        let clamped = mod_of(a.floor(), two);
        let floored = a.floor();
        let rest = a - floored;
        let mirror = clamped + rest;
        let v = if mirror.greater_equal(T::one()) {
            T::one() - rest;
        } else {
            rest;
        };
        r.put(i, v);
    }
    return r;
}

/// A vector component `comp_normalize` and `comp_scale` convert: an integer, or a float that passes
/// through.
pub interface CompScalar: Scalar {
    /// `self` mapped to [-1, 1] (signed integer) or [0, 1] (unsigned integer) as an `F`, or converted.
    fn comp_normalize<F: Float>(self: Self) F;
    /// `x` in [-1, 1] or [0, 1] scaled to the integer range, or converted.
    fn comp_scale<F: Float>(x: F) Self;
}

/// Each component of an integer vector as an `F` in [-1, 1] for a signed `T`
/// (`(x - MIN) / (MAX - MIN) * 2 - 1`) or in [0, 1] for an unsigned one (`x / MAX`); a float vector
/// converts to `F` unchanged. `F` comes first: `comp_normalize::<f32>(v)`.
pub fn comp_normalize<F: Float, T: CompScalar, const N: usize>(v: Vec<T, N>) Vec<F, N> {
    let mut r = Vec::<F, N>::zero();
    for i in 0..N {
        unsafe {
            r.e[i] = v.e[i].comp_normalize::<F>();
        }
    }
    return r;
}

/// Each component of a float vector in [-1, 1] (signed `T`: `x * (MAX + 0.5) - 0.5`) or in [0, 1]
/// (unsigned `T`: `x * MAX`) scaled to the integer range, the conversion truncating; a float `T` converts
/// unchanged. `T` comes first: `comp_scale::<u8>(v)`. A result outside `T` saturates.
pub fn comp_scale<T: CompScalar, F: Float, const N: usize>(v: Vec<F, N>) Vec<T, N> {
    let mut r = Vec::<T, N>::zero();
    for i in 0..N {
        unsafe {
            r.e[i] = T::comp_scale(v.e[i]);
        }
    }
    return r;
}

extend<T: Int> T as CompScalar {
    pub fn comp_normalize<F: Float>(self: T) F {
        let hi = T::max_value().cast::<F>();
        if T::is_signed() {
            let lo = T::min_value().cast::<F>();
            return (self.cast::<F>() - lo) / (hi - lo) * F::from_i64(2) - F::one();
        }
        return self.cast::<F>() / hi;
    }
    pub fn comp_scale<F: Float>(x: F) T {
        if T::is_signed() {
            let hi = T::max_value().cast::<F>() + F::from_f64(0.5);
            return (x * hi - F::from_f64(0.5)).cast::<T>();
        }
        return (x * T::max_value().cast::<F>()).cast::<T>();
    }
}

extend f32 as CompScalar {
    pub fn comp_normalize<F: Float>(self: f32) F {
        return self.cast::<F>();
    }
    pub fn comp_scale<F: Float>(x: F) f32 {
        return x.cast::<f32>();
    }
}

extend f64 as CompScalar {
    pub fn comp_normalize<F: Float>(self: f64) F {
        return self.cast::<F>();
    }
    pub fn comp_scale<F: Float>(x: F) f64 {
        return x.cast::<f64>();
    }
}

/// `0 + v[0] + v[1] + ..`, left to right.
pub fn comp_add<T: Scalar, const N: usize>(v: Vec<T, N>) T {
    let mut r = T::zero();
    for i in 0..N {
        r = r + unsafe v.e[i];
    }
    return r;
}

/// `1 * v[0] * v[1] * ..`, left to right.
pub fn comp_mul<T: Scalar, const N: usize>(v: Vec<T, N>) T {
    let mut r = T::one();
    for i in 0..N {
        r = r * unsafe v.e[i];
    }
    return r;
}

/// `min(..min(v[0], v[1]).., v[N - 1])` with `min`, so a NaN `v[0]` propagates and a later NaN loses.
pub fn comp_min<T: Scalar, const N: usize>(v: Vec<T, N>) T {
    let mut r = v.e[0];
    for i in 1..N {
        r = min_of(r, unsafe v.e[i]);
    }
    return r;
}

/// `max(..max(v[0], v[1]).., v[N - 1])` with `max`.
pub fn comp_max<T: Scalar, const N: usize>(v: Vec<T, N>) T {
    let mut r = v.e[0];
    for i in 1..N {
        r = max_of(r, unsafe v.e[i]);
    }
    return r;
}

/// The smallest component, NaNs ignored unless all are NaN.
pub fn fcomp_min<T: Float, const N: usize>(v: Vec<T, N>) T {
    let mut r = v.e[0];
    for i in 1..N {
        r = r.fmin(unsafe v.e[i]);
    }
    return r;
}

/// The largest component, NaNs ignored unless all are NaN.
pub fn fcomp_max<T: Float, const N: usize>(v: Vec<T, N>) T {
    let mut r = v.e[0];
    for i in 1..N {
        r = r.fmax(unsafe v.e[i]);
    }
    return r;
}
