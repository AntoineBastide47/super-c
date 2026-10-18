// `DualQuat<T>`: a rigid transform as a real (rotation) and a dual (translation) quaternion, with its
// operators and functions: `dq * v` transforms the point `v`, `v * dq` applies the inverse.
// `normalize`, `inverse` and `lerp` are conformances to their dispatch interfaces; `dualquat_cast`
// takes a 2x4 or a 3x4 matrix. There is no unary `+` operator.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::geometric as *;
import std::math::quat as *;

/// The rigid transform `real + dual e` (e^2 = 0).
pub struct DualQuat<T: Float> {
    pub real: Quat<T>,
    pub dual: Quat<T>,
}

pub type dualquat = DualQuat<f32>;
pub type fdualquat = DualQuat<f32>;
pub type ddualquat = DualQuat<f64>;

/// The identity transform: real `1 + 0i + 0j + 0k`, dual 0.
pub fn dual_quat_identity<T: Float>() DualQuat<T> {
    return DualQuat::<T>::identity();
}

/// Column 0 is the real part (x, y, z, w), column 1 the dual part.
pub fn mat2x4_cast<T: Float>(x: DualQuat<T>) Mat<T, 2, 4> {
    let (r, d) = (x.real, x.dual);
    return Mat::<T, 2, 4>::new(r.x, r.y, r.z, r.w, d.x, d.y, d.z, d.w);
}

/// The 3x4 matrix of the rigid transform `x`, its rows the rotation (from the real part divided by its
/// squared length) and the translation in the last column of each row.
pub fn mat3x4_cast<T: Float>(x: DualQuat<T>) Mat<T, 3, 4> {
    let q = x.real;
    let mut r = q / length2(q);
    let rr = Quat::<T>::new(r.w * q.w, r.x * q.x, r.y * q.y, r.z * q.z);
    r = r * T::from_i64(2);
    let xy = r.x * q.y;
    let xz = r.x * q.z;
    let yz = r.y * q.z;
    let wx = r.w * q.x;
    let wy = r.w * q.y;
    let wz = r.w * q.z;
    let d = x.dual;
    let a = Vec::<T, 4>::new(
        rr.w + rr.x - rr.y - rr.z,
        xy - wz,
        xz + wy,
        -(d.w * r.x - d.x * r.w + d.y * r.z - d.z * r.y),
    );
    let b = Vec::<T, 4>::new(
        xy + wz,
        rr.w + rr.y - rr.x - rr.z,
        yz - wx,
        -(d.w * r.y - d.x * r.z - d.y * r.w + d.z * r.x),
    );
    let c = Vec::<T, 4>::new(
        xz - wy,
        yz + wx,
        rr.w + rr.z - rr.x - rr.y,
        -(d.w * r.z + d.x * r.y - d.y * r.x - d.z * r.w),
    );
    return Mat::<T, 3, 4>::cols(a, b, c);
}

/// Of a 2x4 matrix, the real part from column 0 (x, y, z, w) and the dual part from column 1; of a 3x4
/// matrix (rotation rows, translation in the last column), the rigid transform, its rotation from the
/// trace when positive, else from the largest diagonal element. Another shape is a compile error.
pub fn dualquat_cast<T: Float, const C: usize>(x: Mat<T, C, 4>) DualQuat<T> {
    static_assert(C == 2 || C == 3, "dualquat_cast of a 2x4 or 3x4 matrix");
    if C == 2 {
        return unsafe {
            DualQuat::<T>::new(
                Quat::<T>::new(x.c[0].e[3], x.c[0].e[0], x.c[0].e[1], x.c[0].e[2]),
                Quat::<T>::new(x.c[1].e[3], x.c[1].e[0], x.c[1].e[1], x.c[1].e[2]),
            );
        };
    }
    return unsafe dualquat_of_affine(x.c[0], x.c[1], x.c[2]);
}

// `dualquat_cast` of the 3x4 matrix with the columns `x0`, `x1`, `x2`.
fn dualquat_of_affine<T: Float>(x0: Vec<T, 4>, x1: Vec<T, 4>, x2: Vec<T, 4>) DualQuat<T> {
    let half = T::from_f64(0.5);
    let mut real = Quat::<T>::new(T::zero(), T::zero(), T::zero(), T::zero());
    let trace = x0.e[0] + x1.e[1] + x2.e[2];
    if trace.greater(T::zero()) {
        let r = (T::one() + trace).sqrt();
        let invr = half / r;
        real.w = half * r;
        real.x = (x2.e[1] - x1.e[2]) * invr;
        real.y = (x0.e[2] - x2.e[0]) * invr;
        real.z = (x1.e[0] - x0.e[1]) * invr;
    } else if x0.e[0].greater(x1.e[1]) && x0.e[0].greater(x2.e[2]) {
        let r = (T::one() + x0.e[0] - x1.e[1] - x2.e[2]).sqrt();
        let invr = half / r;
        real.x = half * r;
        real.y = (x1.e[0] + x0.e[1]) * invr;
        real.z = (x0.e[2] + x2.e[0]) * invr;
        real.w = (x2.e[1] - x1.e[2]) * invr;
    } else if x1.e[1].greater(x2.e[2]) {
        let r = (T::one() + x1.e[1] - x0.e[0] - x2.e[2]).sqrt();
        let invr = half / r;
        real.x = (x1.e[0] + x0.e[1]) * invr;
        real.y = half * r;
        real.z = (x2.e[1] + x1.e[2]) * invr;
        real.w = (x0.e[2] - x2.e[0]) * invr;
    } else {
        let r = (T::one() + x2.e[2] - x0.e[0] - x1.e[1]).sqrt();
        let invr = half / r;
        real.x = (x0.e[2] + x2.e[0]) * invr;
        real.y = (x2.e[1] + x1.e[2]) * invr;
        real.z = half * r;
        real.w = (x1.e[0] - x0.e[1]) * invr;
    }
    let (t0, t1, t2) = (x0.e[3], x1.e[3], x2.e[3]);
    let dual = Quat::<T>::new(
        -half * (t0 * real.x + t1 * real.y + t2 * real.z),
        half * (t0 * real.w + t1 * real.z - t2 * real.y),
        half * (-t0 * real.z + t1 * real.w + t2 * real.x),
        half * (t0 * real.y - t1 * real.x + t2 * real.w),
    );
    return DualQuat::<T>::new(real, dual);
}

extend<T: Float> DualQuat<T> {
    /// The number of parts.
    pub const LEN: usize = 2;

    /// The dual quaternion `real + dual e`.
    pub fn new(real: Quat<T>, dual: Quat<T>) DualQuat<T> {
        return DualQuat::<T> { real: real, dual: dual };
    }
    /// The real part `real`, the dual part 0.
    pub fn from_real(real: Quat<T>) DualQuat<T> {
        return DualQuat::<T> { real: real, dual: Quat::<T>::new(T::zero(), T::zero(), T::zero(), T::zero()) };
    }
    /// The rotation `q` followed by the translation `p`, the dual part `p q / 2` term by term.
    pub fn from_orientation_translation(q: Quat<T>, p: Vec<T, 3>) DualQuat<T> {
        let (x, y, z) = (p.e[0], p.e[1], p.e[2]);
        let half = T::from_f64(0.5);
        let dual = Quat::<T>::new(
            T::from_f64(-0.5) * (x * q.x + y * q.y + z * q.z),
            half * (x * q.w + y * q.z - z * q.y),
            half * (-x * q.z + y * q.w + z * q.x),
            half * (x * q.y - y * q.x + z * q.w),
        );
        return DualQuat::<T> { real: q, dual: dual };
    }
    /// `dualquat_cast(m)` of a 2x4 or 3x4 matrix.
    pub fn from_mat<const C: usize>(m: Mat<T, C, 4>) DualQuat<T> {
        return dualquat_cast(m);
    }
    /// The identity transform: real `1 + 0i + 0j + 0k`, dual 0.
    pub fn identity() DualQuat<T> {
        return DualQuat::<T> {
            real: Quat::<T>::new(T::one(), T::zero(), T::zero(), T::zero()),
            dual: Quat::<T>::new(T::zero(), T::zero(), T::zero(), T::zero()),
        };
    }
    /// Each component of both parts converted to `U` with `as`.
    pub fn cast<U: Float>(self: DualQuat<T>) DualQuat<U> {
        return DualQuat::<U> { real: self.real.cast::<U>(), dual: self.dual.cast::<U>() };
    }
    /// 2; an open-ended range (`dq[1..]`) ends there.
    pub fn len(self: &DualQuat<T>) usize {
        return 2;
    }
}

// `dq[0]` is the real part, `dq[1]` the dual part; an index of 2 or more traps.
extend<T: Float> DualQuat<T> as Index<Quat<T>, []Quat<T>> {
    pub fn index(self: &DualQuat<T>, i: usize) &Quat<T> {
        return switch i {
            0 => &self.real,
            1 => &self.dual,
            _ => panic("DualQuat<T>[i]: index out of bounds"),
        };
    }
    pub fn index_range(self: &DualQuat<T>, r: Range<usize>) []Quat<T> {
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        if r.start > hi || hi > 2 {
            panic("DualQuat<T>[a..b]: range out of bounds");
        }
        return unsafe Slice::<Quat<T>> { ptr: (&self.real) as *const Quat<T> + r.start, len: hi - r.start };
    }
}

extend<T: Float> DualQuat<T> as IndexMut<Quat<T>, []mut Quat<T>> {
    pub fn index_mut(self: &mut DualQuat<T>, i: usize) &mut Quat<T> {
        return switch i {
            0 => &mut self.real,
            1 => &mut self.dual,
            _ => panic("DualQuat<T>[i]: index out of bounds"),
        };
    }
    pub fn index_range_mut(self: &mut DualQuat<T>, r: Range<usize>) []mut Quat<T> {
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        if r.start > hi || hi > 2 {
            panic("DualQuat<T>[a..b]: range out of bounds");
        }
        return unsafe SliceMut::<Quat<T>> { ptr: (&mut self.real) as *mut Quat<T> + r.start, len: hi - r.start };
    }
}

// `p == q`: both parts IEEE-equal.
extend<T: Float> DualQuat<T> as Eq {
    pub fn eq(self: &DualQuat<T>, other: &DualQuat<T>) bool {
        return self.real == other.real && self.dual == other.dual;
    }
}

extend<T: Float> DualQuat<T> as Neg {
    type Output = DualQuat<T>;
    pub fn neg(self: &DualQuat<T>) DualQuat<T> {
        return DualQuat::<T> { real: -self.real, dual: -self.dual };
    }
}

extend<T: Float> DualQuat<T> as Add {
    type Output = DualQuat<T>;
    pub fn add(self: &DualQuat<T>, p: &DualQuat<T>) DualQuat<T> {
        return DualQuat::<T> { real: self.real + p.real, dual: self.dual + p.dual };
    }
}

// The composition `p * o` (o first): `(p.real o.real, p.real o.dual + p.dual o.real)`.
extend<T: Float> DualQuat<T> as Mul {
    type Output = DualQuat<T>;
    pub fn mul(self: &DualQuat<T>, o: &DualQuat<T>) DualQuat<T> {
        return DualQuat::<T> { real: self.real * o.real, dual: self.real * o.dual + self.dual * o.real };
    }
}

// `dq * v`: the point `v` rotated and translated, with `r`, `d` the vector parts of the real and dual
// quaternions.
extend<T: Float> DualQuat<T> as Mul<Vec<T, 3>> {
    type Output = Vec<T, 3>;
    pub fn mul(self: &DualQuat<T>, v: &Vec<T, 3>) Vec<T, 3> {
        let r = Vec::<T, 3>::new(self.real.x, self.real.y, self.real.z);
        let d = Vec::<T, 3>::new(self.dual.x, self.dual.y, self.dual.z);
        let two = T::from_i64(2);
        return (cross(r, cross(r, *v) + *v * self.real.w + d) + d * self.real.w - r * self.dual.w) * two + *v;
    }
}

// `v * dq`: `inverse(dq) * v`.
extend<T: Float> Vec<T, 3> as Mul<DualQuat<T>> {
    type Output = Vec<T, 3>;
    pub fn mul(self: &Vec<T, 3>, q: &DualQuat<T>) Vec<T, 3> {
        return q.inverse() * *self;
    }
}

// `dq * v`: the xyz part transformed, w kept.
extend<T: Float> DualQuat<T> as Mul<Vec<T, 4>> {
    type Output = Vec<T, 4>;
    pub fn mul(self: &DualQuat<T>, v: &Vec<T, 4>) Vec<T, 4> {
        return (*self * v.xyz()).append(v.e[3]);
    }
}

// `v * dq`: `inverse(dq) * v`.
extend<T: Float> Vec<T, 4> as Mul<DualQuat<T>> {
    type Output = Vec<T, 4>;
    pub fn mul(self: &Vec<T, 4>, q: &DualQuat<T>) Vec<T, 4> {
        return q.inverse() * *self;
    }
}

extend<T: Float> DualQuat<T> as Mul<T> {
    type Output = DualQuat<T>;
    pub fn mul(self: &DualQuat<T>, s: &T) DualQuat<T> {
        return DualQuat::<T> { real: self.real * *s, dual: self.dual * *s };
    }
}

extend<T: Float> T as Mul<DualQuat<T>> {
    type Output = DualQuat<T>;
    pub fn mul(self: &T, q: &DualQuat<T>) DualQuat<T> {
        return *q * *self;
    }
}

extend<T: Float> DualQuat<T> as Div<T> {
    type Output = DualQuat<T>;
    pub fn div(self: &DualQuat<T>, s: &T) DualQuat<T> {
        return DualQuat::<T> { real: self.real / *s, dual: self.dual / *s };
    }
}

// `normalize`: both parts divided by the length of the real part.
extend<T: Float> DualQuat<T> as Normalize {
    pub fn normalize(self: DualQuat<T>) DualQuat<T> {
        return self / length(self.real);
    }
}

// `inverse`: `(conjugate(real), conjugate(dual) + conjugate(real) (-2 dot(conjugate(real),
// conjugate(dual))))`, the inverse of a unit dual quaternion.
extend<T: Float> DualQuat<T> as Invertible {
    pub fn inverse(self: DualQuat<T>) DualQuat<T> {
        let real = conjugate(self.real);
        let dual = conjugate(self.dual);
        return DualQuat::<T> { real: real, dual: dual + real * (T::from_f32(-2.0) * dot(real, dual)) };
    }
}

// `lerp`: the dual quaternion linear blend `x (1 - a) + y k`, `k = -a` when `dot(x.real, y.real) < 0`
// (the shorter arc), else `a`; not normalized. Panics: `a` is outside [0, 1] or NaN (assert).
extend<T: Float> DualQuat<T> as Lerp<T> {
    pub fn lerp(self: DualQuat<T>, y: DualQuat<T>, a: T) DualQuat<T> {
        assert(a.greater_equal(T::zero()) && a.less_equal(T::one()), "lerp: the interpolant is outside [0, 1]");
        let k = if dot(self.real, y.real).less(T::zero()) {
            -a;
        } else {
            a;
        };
        return self * (T::one() - a) + y * k;
    }
}
