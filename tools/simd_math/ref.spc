// Reference values of the elementary functions in any `Real` format: series with argument reduction,
// carried well past the format's precision. Inputs are f64 values (every f32 is one), results are
// in the format, accurate to a few units of its last place except near a zero of the function, where
// the reductions keep the relative accuracy (the pi/2 reduction is exact to 2^-260, see `rem_pio2`).
// Special values (NaN, infinities, poles) are the checker's tables, not this module's.
import real as *;
import std::float as fl;

/// The bits of 2/pi after the binary point, 32 per word (`two_over_pi_words`): enough for the exact
/// pi/2 reduction of every finite f64 (exponent up to 1023, plus the 320-bit window).
pub const PIO2_WORDS: usize = 46;

// Working precision for the 2/pi constant: Machin's formula in a 1500-bit `Float`.
type Big = fl::Float<15, 1500>;

/// The reference library over format `R`, with its constants computed once in `R`.
pub struct Ref<R> {
    pub pi: R,
    pub pio2: R,
    pub ln2: R,
    pub ln10: R,
    pub two_sqrtpi: R, // 2 / sqrt(pi)
    pub sqrt2: R,
    two_pi_words: [u32; PIO2_WORDS],
}

/// The words of 2/pi (bits after the binary point, most significant first), from Machin's formula
/// for pi in 1500-bit arithmetic. About 0.1 s; deterministic on every host.
pub fn two_over_pi_words() [u32; PIO2_WORDS] {
    let pi = atan_inv_big(5).scalbn(4) - atan_inv_big(239).scalbn(2);
    let mut t = Big::from_f64(2.0) / pi; // in (0.5, 1): its bits after the point, one word at a time
    let mut w: [u32; PIO2_WORDS] = [0; PIO2_WORDS];
    for i in 0..PIO2_WORDS {
        t = t.scalbn(32);
        let d = t.floor();
        unsafe w[i] = d.to_f64() as u32;
        t = t - d;
    }
    return w;
}

// atan(1/k) by its Taylor series in `Big`, to the format's last bit.
fn atan_inv_big(k: i32) Big {
    let k2 = Big::from_f64((k * k) as f64);
    let mut p = Big::from_f64(1.0) / Big::from_f64(k as f64); // 1/k^(2n+1)
    let mut s = p;
    let eps = Big::from_f64(1.0).scalbn(-1510);
    let mut n: i32 = 1;
    for _ in 0..2000 {
        p = p / k2;
        if p.ieee_lt(&eps) {
            return s;
        }
        let t = p / Big::from_f64((2 * n + 1) as f64);
        s = if n % 2 == 1 {
            s - t
        } else {
            s + t
        };
        n += 1;
    }
    panic("atan_inv_big: series did not converge");
}

extend<R: Real + Add<Output = R> + Sub<Output = R> + Mul<Output = R> + Div<Output = R>> Ref<R> {
    pub fn new() Ref<R> {
        let one = R::of(1.0);
        let pi = Ref::<R>::atan_inv(5).scale(4) - Ref::<R>::atan_inv(239).scale(2);
        let ln2 = Ref::<R>::atanh_series(one / R::of(3.0)).scale(1);
        let ln10 = ln2 * R::of(3.0) + Ref::<R>::atanh_series(one / R::of(9.0)).scale(1);
        return Ref::<R> {
            pi: pi,
            pio2: pi.scale(-1),
            ln2: ln2,
            ln10: ln10,
            two_sqrtpi: R::of(2.0) / pi.root(),
            sqrt2: R::of(2.0).root(),
            two_pi_words: two_over_pi_words(),
        };
    }

    // A term below this, relative to a sum of magnitude 1, no longer changes the sum.
    fn tiny() R {
        return R::of(1.0).scale(-(R::prec() as i64) - 8);
    }

    pub fn abs(x: R) R {
        if x.lt(R::of(0.0)) {
            return R::of(0.0) - x;
        }
        return x;
    }

    fn neg(x: R) R {
        return R::of(0.0) - x;
    }

    // atan(1/k), Taylor series.
    fn atan_inv(k: i32) R {
        let k2 = R::of((k * k) as f64);
        let mut p = R::of(1.0) / R::of(k as f64);
        let mut s = p;
        let mut n: i32 = 1;
        for _ in 0..1000 {
            p = p / k2;
            if p.lt(Ref::<R>::tiny()) {
                return s;
            }
            let t = p / R::of((2 * n + 1) as f64);
            s = if n % 2 == 1 {
                s - t
            } else {
                s + t
            };
            n += 1;
        }
        panic("atan_inv: series did not converge");
    }

    // atanh(s) = s + s^3/3 + s^5/5 + .., |s| <= 1/3.
    fn atanh_series(s: R) R {
        let z = s * s;
        let mut p = s;
        let mut sum = s;
        let mut n: i32 = 1;
        for _ in 0..2000 {
            p = p * z;
            let t = p / R::of((2 * n + 1) as f64);
            sum = sum + t;
            if !(Ref::<R>::tiny() * Ref::<R>::abs(sum)).lt(Ref::<R>::abs(t)) {
                return sum;
            }
            n += 1;
        }
        panic("atanh_series: series did not converge");
    }

    // e^s - 1 for |s| <= 2^-8 by its Taylor series.
    fn expm1_series(s: R) R {
        let mut p = s;
        let mut sum = s;
        let mut n: i32 = 2;
        for _ in 0..200 {
            p = p * s / R::of(n as f64);
            sum = sum + p;
            if !(Ref::<R>::tiny() * Ref::<R>::abs(sum)).lt(Ref::<R>::abs(p)) {
                return sum;
            }
            n += 1;
        }
        panic("expm1_series: series did not converge");
    }

    // e^r - 1 for |r| <= 1: r / 2^10 by series, then (1 + t)^2 - 1 = t (2 + t) ten times, which keeps
    // the relative accuracy of t.
    fn expm1_small(r: R) R {
        if Ref::<R>::abs(r).lt(R::of(0x1p-10)) {
            // Small enough for the series itself; halving it first would push a tiny r into subnormals.
            return Ref::<R>::expm1_series(r);
        }
        let mut t = Ref::<R>::expm1_series(r.scale(-10));
        for _ in 0..10 {
            t = t * (R::of(2.0) + t);
        }
        return t;
    }

    /// e^x.
    pub fn exp(self: &Ref<R>, x: R) R {
        // Far past both ends of every format here: the result is 0 or infinite.
        let xn = x.near();
        if xn < -1.0e6 {
            return R::of(0.0);
        }
        if xn > 1.0e6 {
            return R::of(1.0) / R::of(0.0);
        }
        let k = (xn / 0.6931471805599453).round();
        let r = x - R::of(k) * self.ln2;
        return (R::of(1.0) + Ref::<R>::expm1_small(r)).scale(k as i64);
    }

    /// e^x - 1, relatively accurate near 0.
    pub fn expm1(self: &Ref<R>, x: R) R {
        if Ref::<R>::abs(x).lt(R::of(0.5)) {
            return Ref::<R>::expm1_small(x);
        }
        return self.exp(x) - R::of(1.0);
    }

    /// log(x), x > 0.
    pub fn log(self: &Ref<R>, x: R) R {
        // An x past the f64 range (an f128 constant) is scaled into it first.
        let mut xs = x;
        let mut adj: i64 = 0;
        for _ in 0..40 {
            let v = xs.near();
            if v == 0.0 {
                xs = xs.scale(512);
                adj -= 512;
            } else if v.is_infinite() {
                xs = xs.scale(-512);
                adj += 512;
            } else {
                break;
            }
        }
        let mut e = exponent(xs.near()) as i64 + adj;
        let mut m = x.scale(-e);
        if self.sqrt2.lt(m) {
            m = m.scale(-1);
            e += 1;
        }
        let s = (m - R::of(1.0)) / (m + R::of(1.0));
        return Ref::<R>::atanh_series(s).scale(1) + R::of(e as f64) * self.ln2;
    }

    /// log(1 + u), u > -1, relatively accurate near 0.
    pub fn log1p(self: &Ref<R>, u: R) R {
        if Ref::<R>::abs(u).lt(R::of(0.25)) {
            return Ref::<R>::atanh_series(u / (R::of(2.0) + u)).scale(1);
        }
        return self.log(R::of(1.0) + u);
    }

    // Taylor series of sin and cos at |r| <= pi/4.
    fn sin_series(r: R) R {
        let z = r * r;
        let mut p = r;
        let mut sum = r;
        let mut n: i32 = 1;
        for _ in 0..200 {
            p = p * z / R::of((2 * n * (2 * n + 1)) as f64);
            sum = if n % 2 == 1 {
                sum - p
            } else {
                sum + p
            };
            if !(Ref::<R>::tiny() * Ref::<R>::abs(sum)).lt(Ref::<R>::abs(p)) {
                return sum;
            }
            n += 1;
        }
        panic("sin_series: series did not converge");
    }

    fn cos_series(r: R) R {
        let z = r * r;
        let mut p = R::of(1.0);
        let mut sum = p;
        let mut n: i32 = 1;
        for _ in 0..200 {
            p = p * z / R::of(((2 * n - 1) * (2 * n)) as f64);
            sum = if n % 2 == 1 {
                sum - p
            } else {
                sum + p
            };
            if p.lt(Ref::<R>::tiny()) {
                return sum;
            }
            n += 1;
        }
        panic("cos_series: series did not converge");
    }

    /// x reduced by pi/2: `(q, r)` with x = q pi/2 + r, |r| <= pi/4 (q mod 4 in 0..4). Exact
    /// fixed-point arithmetic on the bits of 2/pi: the absolute error of r is below 2^-260.
    pub fn rem_pio2(self: &Ref<R>, x: f64) (i64, R) {
        let a = x.abs();
        if a <= 0.78 {
            return (0, R::of(x));
        }
        let b = fl::f64_bits(a);
        let mant = b & 0xFFFFFFFFFFFFF | 1u64 << 52; // a = mant * 2^e
        let e = (b >> 52) as i64 - 1075;
        // Bits i of 2/pi (weight 2^-i, i >= 1) with mant * 2^(e - i) a multiple of 4 add nothing mod 4:
        // the window starts at bit i0 = max(1, e - 1) and spans 320 bits (10 words).
        let mut i0 = e - 1;
        if i0 < 1 {
            i0 = 1;
        }
        let mut win: [u64; 11] = [0; 11]; // 32-bit limbs of the window, least significant first
        for k in 0..10 {
            // limb k holds bits i0 + 288 - 32k .. i0 + 319 - 32k
            unsafe win[k] = self.bits32(i0 + 288 - 32 * k as i64);
        }
        // P = mant * window: 12 limbs.
        let mut p: [u64; 12] = [0; 12];
        let ml = [mant & 0xFFFFFFFF, mant >> 32];
        for j in 0..2 {
            let mut carry: u64 = 0;
            for k in 0..10 {
                let t = unsafe p[j + k] + unsafe ml[j] * unsafe win[k] + carry;
                unsafe p[j + k] = t & 0xFFFFFFFF;
                carry = t >> 32;
            }
            let mut q = j + 10;
            while carry != 0 && q < 12 {
                let t = unsafe p[q] + carry;
                unsafe p[q] = t & 0xFFFFFFFF;
                carry = t >> 32;
                q += 1;
            }
        }
        // x * 2/pi = P * 2^-shift (mod 4), shift = i0 + 319 - e.
        let shift = i0 + 319 - e;
        let mut quad = (Ref::<R>::bits_at(&p, shift) | Ref::<R>::bits_at(&p, shift + 1) << 1) as i64;
        // The fraction's bits below 2^-shift, from the top: 8 words of 32 bits.
        let mut f = R::of(0.0);
        for k in 0..8 {
            let mut wv: u64 = 0;
            for j in 0..32 {
                wv = wv << 1 | Ref::<R>::bits_at(&p, shift - 1 - (32 * k + j) as i64);
            }
            f = f + R::of(wv as f64).scale(-32 * (k as i64 + 1));
        }
        if !f.lt(R::of(0.5)) {
            f = f - R::of(1.0);
            quad += 1;
        }
        let r = f * self.pio2;
        if x < 0.0 {
            return ((4 - quad % 4) % 4, Ref::<R>::neg(r));
        }
        return (quad % 4, r);
    }

    // Bit `i` (weight 2^-i, i >= 1) of 2/pi and the 31 bits after it, as one word.
    const fn bits32(self: &Ref<R>, i: i64) u32 {
        let w = (i - 1) / 32;
        let o = (i - 1) % 32;
        let hi = (unsafe self.two_pi_words[w as usize]) as u64;
        let lo = if (w + 1) as usize < PIO2_WORDS {
            (unsafe self.two_pi_words[(w + 1) as usize]) as u64
        } else {
            0
        };
        return ((hi << 32 | lo) >> (32 - o) as u64) as u32;
    }

    // Bit `i` (weight 2^i) of the 12-limb integer `p`; 0 outside it.
    const fn bits_at(p: &[u64; 12], i: i64) u64 {
        if i < 0 || i >= 384 {
            return 0;
        }
        return unsafe p[(i / 32) as usize] >> (i % 32) as u64 & 1;
    }

    /// sin(x).
    pub fn sin(self: &Ref<R>, x: f64) R {
        let (q, r) = self.rem_pio2(x);
        return switch q {
            0 => Ref::<R>::sin_series(r),
            1 => Ref::<R>::cos_series(r),
            2 => Ref::<R>::neg(Ref::<R>::sin_series(r)),
            _ => Ref::<R>::neg(Ref::<R>::cos_series(r)),
        };
    }

    /// cos(x).
    pub fn cos(self: &Ref<R>, x: f64) R {
        let (q, r) = self.rem_pio2(x);
        return switch q {
            0 => Ref::<R>::cos_series(r),
            1 => Ref::<R>::neg(Ref::<R>::sin_series(r)),
            2 => Ref::<R>::neg(Ref::<R>::cos_series(r)),
            _ => Ref::<R>::sin_series(r),
        };
    }

    /// tan(x).
    pub fn tan(self: &Ref<R>, x: f64) R {
        let (q, r) = self.rem_pio2(x);
        let s = Ref::<R>::sin_series(r);
        let c = Ref::<R>::cos_series(r);
        if q % 2 == 0 {
            return s / c;
        }
        return Ref::<R>::neg(c / s);
    }

    /// atan(x).
    pub fn atan(self: &Ref<R>, x: R) R {
        if x.lt(R::of(0.0)) {
            return Ref::<R>::neg(self.atan(Ref::<R>::neg(x)));
        }
        if R::of(1.0).lt(x) {
            return self.pio2 - self.atan(R::of(1.0) / x);
        }
        // Three halvings, atan(u) = 2 atan(u / (1 + sqrt(1 + u^2))), leave u <= tan(pi/32); a u below
        // that is not halved (a tiny u would lose bits to the subnormal range).
        let mut u = x;
        let mut halvings: i64 = 0;
        for _ in 0..3 {
            if u.lt(R::of(0.0985)) {
                break;
            }
            u = u / (R::of(1.0) + (R::of(1.0) + u * u).root());
            halvings += 1;
        }
        let z = u * u;
        let mut p = u;
        let mut sum = u;
        let mut n: i32 = 1;
        for _ in 0..1000 {
            p = p * z;
            let t = p / R::of((2 * n + 1) as f64);
            sum = if n % 2 == 1 {
                sum - t
            } else {
                sum + t
            };
            if !(Ref::<R>::tiny() * Ref::<R>::abs(sum)).lt(Ref::<R>::abs(t)) {
                return sum.scale(halvings);
            }
            n += 1;
        }
        panic("atan: series did not converge");
    }

    /// asin(x), |x| <= 1.
    pub fn asin(self: &Ref<R>, x: f64) R {
        if x.abs() == 1.0 {
            return if x < 0.0 {
                Ref::<R>::neg(self.pio2)
            } else {
                self.pio2
            };
        }
        let v = R::of(x);
        return self.atan(v / ((R::of(1.0) - v) * (R::of(1.0) + v)).root());
    }

    /// acos(x), |x| <= 1.
    pub fn acos(self: &Ref<R>, x: f64) R {
        if x == -1.0 {
            return self.pi;
        }
        let v = R::of(x);
        return self.atan(((R::of(1.0) - v) / (R::of(1.0) + v)).root()).scale(1);
    }

    /// atan2(y, x) for finite, not both zero, inputs.
    pub fn atan2(self: &Ref<R>, y: f64, x: f64) R {
        if x == 0.0 {
            return if y < 0.0 {
                Ref::<R>::neg(self.pio2)
            } else {
                self.pio2
            };
        }
        // The ratio of the two scaled to one binade: no overflow or underflow in `R`.
        let ex = exponent(x.abs());
        let ey = if y == 0.0 {
            ex
        } else {
            exponent(y.abs())
        };
        // |y| > |x|: +-pi/2 - atan(x / y), so that the ratio stays at most 1 (an overflow would be NaN).
        let q = R::of(y).scale(-(ey as i64)) / R::of(x).scale(-(ex as i64));
        let s = if y < 0.0 == x < 0.0 {
            self.pio2
        } else {
            Ref::<R>::neg(self.pio2)
        };
        let t = if ey > ex + 1 {
            s - self.atan(R::of(1.0) / q * R::of(1.0).scale(ex - ey))
        } else {
            self.atan(q * R::of(1.0).scale(ey - ex))
        };
        if x > 0.0 {
            return t;
        }
        if y < 0.0 || y == 0.0 && y.is_sign_negative() {
            return t - self.pi;
        }
        return t + self.pi;
    }

    /// cbrt(x), x > 0: Newton from e^(log(x) / 3).
    pub fn cbrt(self: &Ref<R>, x: R) R {
        // x = m 2^(3j), m in [1, 8): Newton on m (its cube never overflows), the root times 2^j.
        let e = exponent(x.near()) as i64;
        let j = if e >= 0 {
            e / 3
        } else {
            -((2 - e) / 3)
        }; // floor(e / 3)
        let m = x.scale(-3 * j);
        let mut y = self.exp(self.log(m) / R::of(3.0));
        for _ in 0..2 {
            y = y - (y * y * y - m) / (R::of(3.0) * y * y);
        }
        return y.scale(j);
    }

    /// sqrt(x^2 + y^2), not both zero.
    pub fn hypot(self: &Ref<R>, x: f64, y: f64) R {
        let e = exponent(x.abs().max(y.abs()));
        let a = R::of(x).scale(-(e as i64));
        let b = R::of(y).scale(-(e as i64));
        return (a * a + b * b).root().scale(e);
    }

    /// sinh(x).
    pub fn sinh(self: &Ref<R>, x: f64) R {
        let a = x.abs();
        let s = if a < 20.0 {
            let t = self.expm1(R::of(a));
            (t + t / (t + R::of(1.0))).scale(-1)
        } else {
            self.exp(R::of(a) - self.ln2) - self.exp(R::of(-a) - self.ln2)
        };
        if x < 0.0 {
            return Ref::<R>::neg(s);
        }
        return s;
    }

    /// cosh(x).
    pub fn cosh(self: &Ref<R>, x: f64) R {
        let a = R::of(x.abs());
        return self.exp(a - self.ln2) + self.exp(Ref::<R>::neg(a) - self.ln2);
    }

    /// tanh(x).
    pub fn tanh(self: &Ref<R>, x: f64) R {
        // Past 40, 1 - 2 / (e^2|x| + 1) without the overflow of e^2|x|.
        let r = if x.abs() > 40.0 {
            R::of(1.0) - self.exp(R::of(-2.0 * x.abs())).scale(1)
        } else {
            let t = self.expm1(R::of(2.0 * x.abs()));
            t / (t + R::of(2.0))
        };
        if x < 0.0 {
            return Ref::<R>::neg(r);
        }
        return r;
    }

    /// asinh(x).
    pub fn asinh(self: &Ref<R>, x: f64) R {
        let a = x.abs();
        let r = if a > 1e30 {
            self.log(R::of(a)) + self.ln2
        } else {
            let v = R::of(a);
            self.log1p(v + v * v / (R::of(1.0) + (R::of(1.0) + v * v).root()))
        };
        if x < 0.0 {
            return Ref::<R>::neg(r);
        }
        return r;
    }

    /// acosh(x), x >= 1.
    pub fn acosh(self: &Ref<R>, x: f64) R {
        if x > 1e30 {
            return self.log(R::of(x)) + self.ln2;
        }
        let t = R::of(x) - R::of(1.0);
        return self.log1p(t + (t * (R::of(2.0) + t)).root());
    }

    /// atanh(x), |x| < 1.
    pub fn atanh(self: &Ref<R>, x: f64) R {
        let v = R::of(x);
        return self.log1p(v.scale(1) / (R::of(1.0) - v)).scale(-1);
    }

    /// erf(x).
    pub fn erf(self: &Ref<R>, x: f64) R {
        let a = x.abs();
        let r = if a < 3.0 {
            self.erf_series(a)
        } else {
            R::of(1.0) - self.erfc_cf(a)
        };
        if x < 0.0 {
            return Ref::<R>::neg(r);
        }
        return r;
    }

    /// erfc(x).
    pub fn erfc(self: &Ref<R>, x: f64) R {
        if x < 0.0 {
            return R::of(2.0) - self.erfc(-x);
        }
        if x < 3.0 {
            return R::of(1.0) - self.erf_series(x);
        }
        return self.erfc_cf(x);
    }

    // 2/sqrt(pi) sum (-1)^n x^(2n+1) / (n! (2n+1)), 0 <= x < 3: its largest term is below 2^8.
    fn erf_series(self: &Ref<R>, x: f64) R {
        let v = R::of(x);
        let z = v * v;
        let mut p = v; // x^(2n+1) / n!
        let mut sum = v;
        let mut n: i32 = 1;
        for _ in 0..2000 {
            p = p * z / R::of(n as f64);
            let t = p / R::of((2 * n + 1) as f64);
            sum = if n % 2 == 1 {
                sum - t
            } else {
                sum + t
            };
            if !(Ref::<R>::tiny() * Ref::<R>::abs(sum).scale(-8)).lt(t) {
                return sum * self.two_sqrtpi;
            }
            n += 1;
        }
        panic("erf_series: series did not converge");
    }

    // erfc(x) = e^(-x^2) / sqrt(pi) / (x + (1/2) / (x + 1 / (x + (3/2) / (x + ..)))), x >= 3, the
    // continued fraction evaluated from a depth where its tail no longer matters.
    fn erfc_cf(self: &Ref<R>, x: f64) R {
        if x > 40.0 {
            return R::of(0.0); // below e^-1600: 0 in every format the check compares
        }
        let depth = 60 + (6000.0 * R::prec() as f64 / 104.0 / (x * x)) as i32;
        let v = R::of(x);
        let mut t = v;
        let mut k = depth;
        while k >= 1 {
            t = v + R::of(k as f64 * 0.5) / t;
            k -= 1;
        }
        let (x2h, x2l) = (x * x, x.mul_add(x, -(x * x)));
        let e = self.exp(Ref::<R>::neg(R::of(x2h) + R::of(x2l)));
        return e * self.two_sqrtpi.scale(-1) / t;
    }
}

// The unbiased exponent of a finite nonzero f64 `v` (a subnormal's true one): 2^e <= |v| < 2^(e+1).
pub fn exponent(v: f64) i32 {
    assert(v != 0.0 && v.is_finite(), "exponent: a finite nonzero value");
    let b = fl::f64_bits(v) >> 52 & 0x7FF;
    if b == 0 {
        return exponent(v * 18014398509481984.0) - 54; // 2^54
    }
    return b as i32 - 1023;
}
