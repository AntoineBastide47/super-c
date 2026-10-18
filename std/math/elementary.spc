// Exponential, trigonometric and reciprocal trigonometric functions on float scalars and vectors,
// component by component. Each calls the matching C library function (`sin`, `pow`, ..) with a fixed
// operation order and fixed constants, so results are identical bit for bit with the same C library.
import std::math::scalar as *;
import std::math::vec as *;

/// A value `exp`, `log` and `sqrt` take: a float scalar, vector or quaternion.
pub interface Exponential: Copy {
    fn exp(self: Self) Self;
    fn log(self: Self) Self;
    fn sqrt(self: Self) Self;
}

/// e raised to each component (C `exp`).
pub fn exp<G: Exponential>(x: G) G {
    return x.exp();
}

/// The natural logarithm of each component (C `log`).
pub fn log<G: Exponential>(x: G) G {
    return x.log();
}

/// The square root of each component (C `sqrt`).
pub fn sqrt<G: Exponential>(x: G) G {
    return x.sqrt();
}

// On a `T: Float`, `self.exp()` and `self.sqrt()` call the bound's `Float` methods, not this conformance.
extend<T: Float> T as Exponential {
    pub fn exp(self: T) T {
        return self.exp();
    }
    pub fn log(self: T) T {
        return self.ln();
    }
    pub fn sqrt(self: T) T {
        return self.sqrt();
    }
}

extend<T: Float, const N: usize> Vec<T, N> as Exponential {
    pub fn exp(self: Vec<T, N>) Vec<T, N> {
        let mut r = self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].exp();
            }
        }
        return r;
    }
    pub fn log(self: Vec<T, N>) Vec<T, N> {
        let mut r = self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].ln();
            }
        }
        return r;
    }
    pub fn sqrt(self: Vec<T, N>) Vec<T, N> {
        let mut r = self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].sqrt();
            }
        }
        return r;
    }
}

/// The exponents `pow(base, exponent)` takes for a base of type `Self`.
pub interface Pow<E>: Copy {
    fn pow(self: Self, exponent: E) Self;
}

/// Each component of `base` raised to the matching component of `exponent` (C `pow`), or a quaternion
/// raised to a scalar.
pub fn pow<G: Pow<E>, E>(base: G, exponent: E) G {
    return base.pow(exponent);
}

// On a `T: Float`, `self.pow(e)` calls the bound's `Float::pow`, not this conformance.
extend<T: Float> T as Pow<T> {
    pub fn pow(self: T, exponent: T) T {
        return self.pow(exponent);
    }
}

extend<T: Float, const N: usize> Vec<T, N> as Pow<Vec<T, N>> {
    pub fn pow(self: Vec<T, N>, exponent: Vec<T, N>) Vec<T, N> {
        let mut r = self;
        for i in 0..N {
            unsafe {
                r.e[i] = self.e[i].pow(exponent.e[i]);
            }
        }
        return r;
    }
}

/// 2 raised to each component (C `exp2`).
pub fn exp2<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, x.at(i).exp2());
    }
    return r;
}

/// The base-2 logarithm of each component (C `log2`).
pub fn log2<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, x.at(i).log2());
    }
    return r;
}

/// `1 / sqrt(x)` for each component.
pub fn inversesqrt<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, T::one() / x.at(i).sqrt());
    }
    return r;
}

/// Each component times `T(0.01745329251994329576923690768489)`.
pub fn radians<T: Float, G: Gen<T>>(degrees: G) G {
    let k = T::from_f64(0.01745329251994329576923690768489);
    let mut r = degrees;
    for i in 0..G::len() {
        r.put(i, degrees.at(i) * k);
    }
    return r;
}

/// Each component times `T(57.295779513082320876798154814105)`.
pub fn degrees<T: Float, G: Gen<T>>(radians: G) G {
    let k = T::from_f64(57.295779513082320876798154814105);
    let mut r = radians;
    for i in 0..G::len() {
        r.put(i, radians.at(i) * k);
    }
    return r;
}

/// The sine of each component, in radians (C `sin`).
pub fn sin<T: Float, G: Gen<T>>(angle: G) G {
    let mut r = angle;
    for i in 0..G::len() {
        r.put(i, angle.at(i).sin());
    }
    return r;
}

/// The cosine of each component, in radians (C `cos`).
pub fn cos<T: Float, G: Gen<T>>(angle: G) G {
    let mut r = angle;
    for i in 0..G::len() {
        r.put(i, angle.at(i).cos());
    }
    return r;
}

/// The tangent of each component, in radians (C `tan`).
pub fn tan<T: Float, G: Gen<T>>(angle: G) G {
    let mut r = angle;
    for i in 0..G::len() {
        r.put(i, angle.at(i).tan());
    }
    return r;
}

/// The arc sine of each component (C `asin`): NaN outside [-1, 1].
pub fn asin<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, x.at(i).asin());
    }
    return r;
}

/// The arc cosine of each component (C `acos`): NaN outside [-1, 1].
pub fn acos<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, x.at(i).acos());
    }
    return r;
}

/// The arc tangent of each component (C `atan`): in [-pi/2, pi/2].
pub fn atan<T: Float, G: Gen<T>>(y_over_x: G) G {
    let mut r = y_over_x;
    for i in 0..G::len() {
        r.put(i, y_over_x.at(i).atan());
    }
    return r;
}

/// The angle of each (x, y) component pair in [-pi, pi] (C `atan2`).
pub fn atan2<T: Float, G: Gen<T>>(y: G, x: G) G {
    let mut r = y;
    for i in 0..G::len() {
        r.put(i, y.at(i).atan2(x.at(i)));
    }
    return r;
}

/// The hyperbolic sine of each component (C `sinh`).
pub fn sinh<T: Float, G: Gen<T>>(angle: G) G {
    let mut r = angle;
    for i in 0..G::len() {
        r.put(i, angle.at(i).sinh());
    }
    return r;
}

/// The hyperbolic cosine of each component (C `cosh`).
pub fn cosh<T: Float, G: Gen<T>>(angle: G) G {
    let mut r = angle;
    for i in 0..G::len() {
        r.put(i, angle.at(i).cosh());
    }
    return r;
}

/// The hyperbolic tangent of each component (C `tanh`).
pub fn tanh<T: Float, G: Gen<T>>(angle: G) G {
    let mut r = angle;
    for i in 0..G::len() {
        r.put(i, angle.at(i).tanh());
    }
    return r;
}

/// The inverse hyperbolic sine of each component (C `asinh`).
pub fn asinh<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, x.at(i).asinh());
    }
    return r;
}

/// The inverse hyperbolic cosine of each component (C `acosh`): NaN below 1.
pub fn acosh<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, x.at(i).acosh());
    }
    return r;
}

/// The inverse hyperbolic tangent of each component (C `atanh`): NaN outside [-1, 1].
pub fn atanh<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, x.at(i).atanh());
    }
    return r;
}

/// `1 / cos(angle)`, component by component.
pub fn sec<T: Float, G: Gen<T>>(angle: G) G {
    let mut r = angle;
    for i in 0..G::len() {
        r.put(i, T::one() / angle.at(i).cos());
    }
    return r;
}

/// `1 / sin(angle)`, component by component.
pub fn csc<T: Float, G: Gen<T>>(angle: G) G {
    let mut r = angle;
    for i in 0..G::len() {
        r.put(i, T::one() / angle.at(i).sin());
    }
    return r;
}

/// `tan(T(pi / 2) - angle)`, component by component.
pub fn cot<T: Float, G: Gen<T>>(angle: G) G {
    let pi_over_2 = T::from_f64(3.1415926535897932384626433832795 / 2.0);
    let mut r = angle;
    for i in 0..G::len() {
        r.put(i, (pi_over_2 - angle.at(i)).tan());
    }
    return r;
}

/// `acos(1 / x)`, component by component.
pub fn asec<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, (T::one() / x.at(i)).acos());
    }
    return r;
}

/// `asin(1 / x)`, component by component.
pub fn acsc<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, (T::one() / x.at(i)).asin());
    }
    return r;
}

/// `T(pi / 2) - atan(x)`, component by component.
pub fn acot<T: Float, G: Gen<T>>(x: G) G {
    let pi_over_2 = T::from_f64(3.1415926535897932384626433832795 / 2.0);
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, pi_over_2 - x.at(i).atan());
    }
    return r;
}

/// `1 / cosh(angle)`, component by component.
pub fn sech<T: Float, G: Gen<T>>(angle: G) G {
    let mut r = angle;
    for i in 0..G::len() {
        r.put(i, T::one() / angle.at(i).cosh());
    }
    return r;
}

/// `1 / sinh(angle)`, component by component.
pub fn csch<T: Float, G: Gen<T>>(angle: G) G {
    let mut r = angle;
    for i in 0..G::len() {
        r.put(i, T::one() / angle.at(i).sinh());
    }
    return r;
}

/// `cosh(angle) / sinh(angle)`, component by component.
pub fn coth<T: Float, G: Gen<T>>(angle: G) G {
    let mut r = angle;
    for i in 0..G::len() {
        r.put(i, angle.at(i).cosh() / angle.at(i).sinh());
    }
    return r;
}

/// `acosh(1 / x)`, component by component.
pub fn asech<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, (T::one() / x.at(i)).acosh());
    }
    return r;
}

/// `asinh(1 / x)`, component by component.
pub fn acsch<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, (T::one() / x.at(i)).asinh());
    }
    return r;
}

/// `atanh(1 / x)`, component by component.
pub fn acoth<T: Float, G: Gen<T>>(x: G) G {
    let mut r = x;
    for i in 0..G::len() {
        r.put(i, (T::one() / x.at(i)).atanh());
    }
    return r;
}
