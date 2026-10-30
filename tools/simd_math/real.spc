// Real arithmetic for the reference functions (`ref.spc`): `Dw`, an unevaluated pair of f64 values
// (about 104 bits, fast), for the accuracy check's bulk runs, and std's correctly rounded `f128` and
// `f256` for the generator and the re-checks. Every operation is an IEEE f64 operation or a std
// `Float` operation, so a result is the same on every host.
import std::float as fl;

/// A real-number format: exact f64 inputs, the four operators (through `Add` .. `Div`), a square
/// root, exact power-of-two scaling and an order.
pub interface Real: Copy {
    /// `x`, exactly.
    fn of(x: f64) Self;
    /// The nearest f64.
    fn near(self: &Self) f64;
    /// The square root, rounded in the format.
    fn root(self: &Self) Self;
    /// `self * 2^k`, exactly.
    fn scale(self: &Self, k: i64) Self;
    /// `self < o`.
    fn lt(self: Self, o: Self) bool;
    /// The format's significand bits: a rounded operation is off by at most 2^-bits() relatively.
    fn prec() i32;
}

/// A double-word value `hi + lo` with `|lo| <= ulp(hi) / 2`.
pub struct Dw {
    pub hi: f64,
    pub lo: f64,
}

// Exact sum: `s + e == a + b` (Knuth).
const fn two_sum(a: f64, b: f64) (f64, f64) {
    let s = a + b;
    let bb = s - a;
    return (s, a - (s - bb) + (b - bb));
}

// Exact sum for `|a| >= |b|` (Dekker).
const fn fast_two_sum(a: f64, b: f64) (f64, f64) {
    let s = a + b;
    return (s, b - (s - a));
}

// Exact product: `p + e == a * b`.
const fn two_prod(a: f64, b: f64) (f64, f64) {
    let p = a * b;
    return (p, a.mul_add(b, -p));
}

extend Dw {
    // `x * y` for a double-word `x` and an f64 `y`.
    const fn times_f64(self: Dw, y: f64) Dw {
        let (ch, cl1) = two_prod(self.hi, y);
        let (zh, zl) = fast_two_sum(ch, self.lo.mul_add(y, cl1));
        return Dw { hi: zh, lo: zl };
    }
}

// The accurate algorithms of Joldes, Muller and Popescu, "Tight and rigorous error bounds for basic
// building blocks of double-word arithmetic" (ACM TOMS 44(2), 2017): relative errors of 3u^2 (sum),
// 4u^2 (product) and below 10u^2 (quotient, refined twice), u = 2^-53.
extend Dw as Add {
    type Output = Dw;

    pub fn add(self: &Dw, o: &Dw) Dw {
        let (sh, sl) = two_sum(self.hi, o.hi);
        let (th, tl) = two_sum(self.lo, o.lo);
        let (vh, vl) = fast_two_sum(sh, sl + th);
        let (zh, zl) = fast_two_sum(vh, tl + vl);
        return Dw { hi: zh, lo: zl };
    }
}

extend Dw as Sub {
    type Output = Dw;

    pub fn sub(self: &Dw, o: &Dw) Dw {
        return *self + Dw { hi: -o.hi, lo: -o.lo };
    }
}

extend Dw as Mul {
    type Output = Dw;

    pub fn mul(self: &Dw, o: &Dw) Dw {
        let (ch, cl1) = two_prod(self.hi, o.hi);
        let cl2 = self.lo.mul_add(o.hi, self.hi.mul_add(o.lo, self.lo * o.lo));
        let (zh, zl) = fast_two_sum(ch, cl1 + cl2);
        return Dw { hi: zh, lo: zl };
    }
}

extend Dw as Div {
    type Output = Dw;

    pub fn div(self: &Dw, o: &Dw) Dw {
        let q1 = self.hi / o.hi;
        let r1 = *self - o.times_f64(q1);
        let q2 = r1.hi / o.hi;
        let r2 = r1 - o.times_f64(q2);
        let q3 = r2.hi / o.hi;
        let (s, e) = fast_two_sum(q1, q2);
        return Dw { hi: s, lo: e } + Dw { hi: q3, lo: 0.0 };
    }
}

extend Dw as Real {
    pub fn of(x: f64) Dw {
        return Dw { hi: x, lo: 0.0 };
    }

    pub fn near(self: &Dw) f64 {
        // hi + 0 would turn a -0 into +0.
        return if self.lo == 0.0 {
            self.hi
        } else {
            self.hi + self.lo
        };
    }

    pub fn root(self: &Dw) Dw {
        if self.hi <= 0.0 {
            return Dw { hi: self.hi.sqrt(), lo: 0.0 };
        }
        let s = self.hi.sqrt();
        let (p, e) = two_prod(s, s);
        let (zh, zl) = fast_two_sum(s, (self.hi - p - e + self.lo) / (2.0 * s));
        return Dw { hi: zh, lo: zl };
    }

    pub fn scale(self: &Dw, k: i64) Dw {
        // Steps of 2^512 keep every factor a normal power of two; each product is exact unless the
        // value leaves the range.
        let mut v = *self;
        let mut j = k;
        for _ in 0..8 {
            let s: i64 = if j > 512 {
                512
            } else if j < -512 {
                -512
            } else {
                j
            };
            let f = fl::f64_from_bits((1023 + s) as u64 << 52);
            v = Dw { hi: v.hi * f, lo: v.lo * f };
            j -= s;
            if j == 0 {
                return v;
            }
        }
        return v;
    }

    pub fn lt(self: Dw, o: Dw) bool {
        return self.hi < o.hi || self.hi == o.hi && self.lo < o.lo;
    }

    pub fn prec() i32 {
        return 104;
    }
}

extend fl::f128 as Real {
    pub fn of(x: f64) fl::f128 {
        return fl::f128::from_f64(x);
    }

    pub fn near(self: &fl::f128) f64 {
        return self.to_f64();
    }

    pub fn root(self: &fl::f128) fl::f128 {
        return self.sqrt();
    }

    pub fn scale(self: &fl::f128, k: i64) fl::f128 {
        return self.scalbn(k);
    }

    pub fn lt(self: fl::f128, o: fl::f128) bool {
        return self.ieee_lt(&o);
    }

    pub fn prec() i32 {
        return 113;
    }
}

extend fl::f256 as Real {
    pub fn of(x: f64) fl::f256 {
        return fl::f256::from_f64(x);
    }

    pub fn near(self: &fl::f256) f64 {
        return self.to_f64();
    }

    pub fn root(self: &fl::f256) fl::f256 {
        return self.sqrt();
    }

    pub fn scale(self: &fl::f256, k: i64) fl::f256 {
        return self.scalbn(k);
    }

    pub fn lt(self: fl::f256, o: fl::f256) bool {
        return self.ieee_lt(&o);
    }

    pub fn prec() i32 {
        return 237;
    }
}
