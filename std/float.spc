// Arbitrary-format IEEE-like binary floating point: `Float<E, F>` is one sign bit, `E` exponent bits and
// `F` stored fraction bits, packed into a `UInt<{1 + E + F}>`. `E` and `F` describe the BIT ALLOCATION;
// the semantics are fixed here to IEEE's: an all-zero exponent encodes zero and subnormals, an all-one
// exponent encodes infinity and NaN, rounding is to nearest, ties to even. The aliases `f16`, `f128` and
// `f256` name the standard formats the built-in `f32`/`f64` do not cover; `Float<8, 23>` and
// `Float<11, 52>` are those two built-ins bit for bit, which is what the tests hold this file to.
//
// Arithmetic decodes to (sign, exponent, significand), operates with three extra low bits -- guard,
// round, and a STICKY bit that any shifted-out bit jams into -- and re-encodes through one rounding in
// `round_pack`. Three guard bits with jamming are sufficient for correctly rounded add, subtract,
// multiply and divide; the differential tests against the hardware formats are the evidence.
//
// The third generic argument is the FAMILY -- the meaning of the top exponent field. It defaults to
// `IEEE`, so `Float<E, F>` reads as before; `Float<4, 3, FINITE_ONLY>` is the e4m3fn-style format with
// no infinities, whose overflow saturates to max_finite and whose only special value is one NaN
// encoding. The family is part of the type: two formats sharing E and F but not semantics never mix.

/// The semantic FAMILY of a format: what the top exponent field means. A single structured value rather
/// than loose booleans, so invalid combinations cannot be spelled; `IEEE` and `FINITE_ONLY` are the
/// canonical descriptors and the third generic argument takes one by NAME.
pub enum FloatFamily {
    /// The IEEE meaning: an all-one exponent is infinity (zero fraction) or NaN (any other fraction).
    FF_IEEE,
    /// No infinities (e4m3fn-style): the top exponent field holds ordinary values, except the single
    /// all-ones-fraction encoding, which is NaN. Overflow saturates to max_finite; x/0 gives NaN.
    FF_FINITE_ONLY,
}

pub const IEEE: FloatFamily = FloatFamily::FF_IEEE;
pub const FINITE_ONLY: FloatFamily = FloatFamily::FF_FINITE_ONLY;

/// How a value classifies, from its encoding alone.
pub enum FpClass {
    FP_ZERO,
    FP_SUBNORMAL,
    FP_NORMAL,
    FP_INFINITE,
    FP_NAN,
}

pub struct Float<const E: usize, const F: usize, const FAMILY: FloatFamily = IEEE> {
    bits: UInt<{1 + E + F}>,
}

extend<const E: usize, const F: usize, const FAMILY: FloatFamily> Float<E, F, FAMILY> {
    /// Format constants. `bias` fits an i64 because E is capped well below it: 2 <= E <= 30 keeps every
    /// exponent computation in comfortable i64 range at any F.
    pub const fn bits() usize {
        return 1 + E + F;
    }

    pub const fn precision() usize {
        return F + 1;
    }

    const fn bias() i64 {
        static_assert(E >= 2, "a float format needs at least 2 exponent bits");
        static_assert(E <= 30, "exponent fields past 30 bits serve no format and overflow the bias math");
        static_assert(F >= 1, "a float format needs at least 1 fraction bit");
        return (1i64 << (E - 1) as i64) - 1;
    }

    const fn emax() i64 {
        if FAMILY == FloatFamily::FF_FINITE_ONLY {
            return Float::<E, F, FAMILY>::bias() + 1; // the top field is an ordinary exponent here
        }
        return Float::<E, F, FAMILY>::bias();
    }

    const fn emin() i64 {
        return 1 - Float::<E, F, FAMILY>::bias();
    }

    const fn exp_field_max() u64 {
        return (1u64 << E as u64) - 1;
    }

    // ---- raw encoding --------------------------------------------------------------------------

    pub fn to_raw(self: &Float<E, F, FAMILY>) UInt<{1 + E + F}> {
        return self.bits;
    }

    pub fn from_raw(b: UInt<{1 + E + F}>) Float<E, F, FAMILY> {
        return Float::<E, F, FAMILY> { bits: b };
    }

    fn sign(self: &Float<E, F, FAMILY>) bool {
        return self.bits.bit(E + F);
    }

    /// The biased exponent field. E <= 30, so it always fits a u64 -- extracted by shifting the field's
    /// bottom to bit 0, where to_u64 reads it whatever the total width is.
    fn exp_field(self: &Float<E, F, FAMILY>) u64 {
        return self.bits.shr(F).to_u64() & Float::<E, F, FAMILY>::exp_field_max();
    }

    /// The stored fraction: the low F bits.
    fn frac_field(self: &Float<E, F, FAMILY>) UInt<{1 + E + F}> {
        let m = UInt::<{1 + E + F}>::max().shr(1 + E);
        return self.bits.bit_and(&m);
    }

    fn pack(negative: bool, ebits: u64, frac: &UInt<{1 + E + F}>) Float<E, F, FAMILY> {
        let mut b = UInt::<{1 + E + F}>::from_u64(ebits).shl(F).bit_or(frac);
        if negative {
            let s = UInt::<{1 + E + F}>::one().shl(E + F);
            b = b.bit_or(&s);
        }
        return Float::<E, F, FAMILY> { bits: b };
    }

    // ---- constructors --------------------------------------------------------------------------

    pub fn zero() Float<E, F, FAMILY> {
        return Float::<E, F, FAMILY> { bits: UInt::<{1 + E + F}>::zero() };
    }

    pub fn neg_zero() Float<E, F, FAMILY> {
        let z = UInt::<{1 + E + F}>::zero();
        return Float::<E, F, FAMILY>::pack(true, 0, &z);
    }

    pub fn one() Float<E, F, FAMILY> {
        let z = UInt::<{1 + E + F}>::zero();
        return Float::<E, F, FAMILY>::pack(false, Float::<E, F, FAMILY>::bias() as u64, &z);
    }

    pub fn infinity(negative: bool) Float<E, F, FAMILY> {
        let z = UInt::<{1 + E + F}>::zero();
        return Float::<E, F, FAMILY>::pack(negative, Float::<E, F, FAMILY>::exp_field_max(), &z);
    }

    /// The canonical quiet NaN. IEEE: exponent all ones, fraction MSB set. Finite-only: the single
    /// all-ones encoding. Operations produce this one; payloads of incoming NaNs are not propagated.
    pub fn nan() Float<E, F, FAMILY> {
        if FAMILY == FloatFamily::FF_FINITE_ONLY {
            let fr = UInt::<{1 + E + F}>::max().shr(1 + E);
            return Float::<E, F, FAMILY>::pack(false, Float::<E, F, FAMILY>::exp_field_max(), &fr);
        }
        let q = UInt::<{1 + E + F}>::one().shl(F - 1);
        return Float::<E, F, FAMILY>::pack(false, Float::<E, F, FAMILY>::exp_field_max(), &q);
    }

    /// The largest finite value. IEEE: top ordinary exponent, fraction all ones. Finite-only: the top
    /// exponent with the fraction one below the NaN encoding.
    pub fn max_finite(negative: bool) Float<E, F, FAMILY> {
        if FAMILY == FloatFamily::FF_FINITE_ONLY {
            let one = UInt::<{1 + E + F}>::one();
            let fr = UInt::<{1 + E + F}>::max().shr(1 + E).wrapping_sub(&one);
            return Float::<E, F, FAMILY>::pack(negative, Float::<E, F, FAMILY>::exp_field_max(), &fr);
        }
        let fr = UInt::<{1 + E + F}>::max().shr(1 + E);
        return Float::<E, F, FAMILY>::pack(negative, Float::<E, F, FAMILY>::exp_field_max() - 1, &fr);
    }

    /// What overflow produces: the family's answer -- infinity, or saturation at the largest finite.
    fn overflow_result(negative: bool) Float<E, F, FAMILY> {
        if FAMILY == FloatFamily::FF_FINITE_ONLY {
            return Float::<E, F, FAMILY>::max_finite(negative);
        }
        return Float::<E, F, FAMILY>::infinity(negative);
    }

    /// The smallest positive value: the least subnormal.
    pub fn min_positive() Float<E, F, FAMILY> {
        let fr = UInt::<{1 + E + F}>::one();
        return Float::<E, F, FAMILY>::pack(false, 0, &fr);
    }

    // ---- classification ------------------------------------------------------------------------

    pub fn classify(self: &Float<E, F, FAMILY>) FpClass {
        let eb = self.exp_field();
        let fz = self.frac_field().is_zero();
        if eb == 0 {
            if fz {
                return FpClass::FP_ZERO;
            }
            return FpClass::FP_SUBNORMAL;
        }
        if FAMILY == FloatFamily::FF_FINITE_ONLY {
            if self.is_nan() {
                return FpClass::FP_NAN;
            }
            return FpClass::FP_NORMAL;
        }
        if eb == Float::<E, F, FAMILY>::exp_field_max() {
            if fz {
                return FpClass::FP_INFINITE;
            }
            return FpClass::FP_NAN;
        }
        return FpClass::FP_NORMAL;
    }

    pub fn is_nan(self: &Float<E, F, FAMILY>) bool {
        if FAMILY == FloatFamily::FF_FINITE_ONLY {
            // The single NaN encoding: top exponent AND all-ones fraction.
            let fm = UInt::<{1 + E + F}>::max().shr(1 + E);
            return self.exp_field() == Float::<E, F, FAMILY>::exp_field_max() && self.frac_field() == fm;
        }
        return self.exp_field() == Float::<E, F, FAMILY>::exp_field_max() && !self.frac_field().is_zero();
    }

    pub fn is_infinite(self: &Float<E, F, FAMILY>) bool {
        if FAMILY == FloatFamily::FF_FINITE_ONLY {
            return false; // the family has no infinities
        }
        return self.exp_field() == Float::<E, F, FAMILY>::exp_field_max() && self.frac_field().is_zero();
    }

    pub fn is_zero(self: &Float<E, F, FAMILY>) bool {
        return self.exp_field() == 0 && self.frac_field().is_zero();
    }

    pub fn is_finite(self: &Float<E, F, FAMILY>) bool {
        return !self.is_nan() && !self.is_infinite();
    }

    pub fn is_negative(self: &Float<E, F, FAMILY>) bool {
        return self.sign();
    }

    // ---- sign operations -----------------------------------------------------------------------

    pub fn neg(self: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        let s = UInt::<{1 + E + F}>::one().shl(E + F);
        return Float::<E, F, FAMILY> { bits: self.bits.bit_xor(&s) };
    }

    pub fn abs(self: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        let m = UInt::<{1 + E + F}>::max().shr(1);
        return Float::<E, F, FAMILY> { bits: self.bits.bit_and(&m) };
    }

    // ---- decode --------------------------------------------------------------------------------
    // A finite nonzero value becomes (exp, sig3): sig3 holds the F+1 significand bits at position 3 --
    // guard, round and sticky below them, all zero here -- with the MSB at bit F+3, subnormals
    // normalized into the same shape. The value is sig3 * 2^(exp - F - 3).

    fn decode_sig3(self: &Float<E, F, FAMILY>, exp_out: *mut i64) UInt<{F + 8}> {
        let eb = self.exp_field();
        let fr = self.frac_field();
        let mut sig = UInt::<{F + 8}>::zero();
        let mut i: usize = 0;
        while i * 64 < F + 1 {
            sig.set_limb(i, fr.limb(i));
            i = i + 1;
        }
        if eb == 0 {
            // Subnormal: value = frac * 2^(emin - F). Normalize so the MSB sits at F, adjusting exp.
            let mut e = Float::<E, F, FAMILY>::emin();
            let sh = F + 1 - sig.bit_length();
            sig = sig.shl(sh);
            e = e - sh as i64;
            unsafe *exp_out = e;
            return sig.shl(3);
        }
        let top = UInt::<{F + 8}>::one().shl(F);
        sig = sig.bit_or(&top);
        unsafe *exp_out = eb as i64 - Float::<E, F, FAMILY>::bias();
        return sig.shl(3);
    }

    // ---- round and encode ----------------------------------------------------------------------
    // The single rounding step. `sig3` carries the significand with three extra low bits (guard, round,
    // sticky) and its MSB at F+3 -- except on the subnormal path, where the right shift below may push
    // it lower. `exp` is the exponent of bit F+3. Ties go to even; overflow to infinity.

    fn round_pack(negative: bool, exp0: i64, sig0: UInt<{F + 8}>) Float<E, F, FAMILY> {
        let mut exp = exp0;
        let mut sig3 = sig0;
        if sig3.is_zero() {
            if negative {
                return Float::<E, F, FAMILY>::neg_zero();
            }
            return Float::<E, F, FAMILY>::zero();
        }
        if exp < Float::<E, F, FAMILY>::emin() {
            // Below the normal range: shift right until the exponent reaches emin, jamming what falls
            // off into the sticky bit, then round at the subnormal precision.
            let mut sh = (Float::<E, F, FAMILY>::emin() - exp) as usize;
            if sh > F + 5 {
                sh = F + 5;
            }
            let kept = sig3.shr(sh);
            let back = kept.shl(sh);
            let mut j = kept;
            if !(back == sig3) {
                let one = UInt::<{F + 8}>::one();
                j = kept.bit_or(&one);
            }
            sig3 = j;
            exp = Float::<E, F, FAMILY>::emin();
        }
        let grs = sig3.to_u64() & 7;
        let mut keep = sig3.shr(3);
        let up = grs > 4 || grs == 4 && (keep.to_u64() & 1) == 1;
        if up {
            let one = UInt::<{F + 8}>::one();
            keep = keep.wrapping_add(&one);
        }
        if keep.bit(F + 1) {
            keep = keep.shr(1);
            exp = exp + 1;
        }
        if exp > Float::<E, F, FAMILY>::emax() {
            return Float::<E, F, FAMILY>::overflow_result(negative);
        }
        if FAMILY == FloatFamily::FF_FINITE_ONLY && exp == Float::<E, F, FAMILY>::emax() {
            // Rounding may land exactly on the NaN slot -- the all-ones encoding one past max_finite.
            let one8 = UInt::<{F + 8}>::one();
            let full = one8.shl(F + 1).wrapping_sub(&one8);
            if keep == full {
                return Float::<E, F, FAMILY>::max_finite(negative);
            }
        }
        let mut ebits: u64 = 0;
        if keep.bit(F) {
            ebits = (exp + Float::<E, F, FAMILY>::bias()) as u64;
        }
        // The fraction is `keep` without its implicit bit; the pack width copy goes limb by limb.
        let one8 = UInt::<{F + 8}>::one();
        let fm = one8.shl(F).wrapping_sub(&one8);
        let fr8 = keep.bit_and(&fm);
        let mut fr = UInt::<{1 + E + F}>::zero();
        let mut i: usize = 0;
        while i * 64 < F + 1 {
            fr.set_limb(i, fr8.limb(i));
            i = i + 1;
        }
        return Float::<E, F, FAMILY>::pack(negative, ebits, &fr);
    }

    // ---- helpers -------------------------------------------------------------------------------

    /// Shift right with the classic jam: any bit that falls off keeps the result odd, so one later
    /// rounding sees that something was there.
    fn shr_jam(v: &UInt<{F + 8}>, sh: usize) UInt<{F + 8}> {
        if sh == 0 {
            return *v;
        }
        if sh >= F + 8 {
            if v.is_zero() {
                return UInt::<{F + 8}>::zero();
            }
            return UInt::<{F + 8}>::one();
        }
        let kept = v.shr(sh);
        let back = kept.shl(sh);
        if back == *v {
            return kept;
        }
        let one = UInt::<{F + 8}>::one();
        return kept.bit_or(&one);
    }

    // ---- arithmetic ----------------------------------------------------------------------------

    // ---- cross-format conversion ---------------------------------------------------------------

    /// Any format into this one, with one rounding. Widening a fraction is exact; narrowing jams what
    /// falls off into the sticky bit; the exponent clamp (overflow, subnormals) is round_pack's.
    pub fn convert<const E2: usize, const F2: usize, const FAM2: FloatFamily>(v: &Float<E2, F2, FAM2>) Float<
        E,
        F,
        FAMILY
    > {
        if v.is_nan() {
            return Float::<E, F, FAMILY>::nan();
        }
        if v.is_infinite() {
            return Float::<E, F, FAMILY>::overflow_result(v.is_negative());
        }
        if v.is_zero() {
            if v.is_negative() {
                return Float::<E, F, FAMILY>::neg_zero();
            }
            return Float::<E, F, FAMILY>::zero();
        }
        let mut e: i64 = 0;
        let s3 = v.decode_sig3(&mut e);
        let mut sig = UInt::<{F + 8}>::zero();
        if F2 <= F {
            let mut i: usize = 0;
            while i * 64 < F2 + 8 {
                sig.set_limb(i, s3.limb(i));
                i = i + 1;
            }
            sig = sig.shl(F - F2);
        } else {
            let red = Float::<E2, F2, FAM2>::shr_jam(&s3, F2 - F);
            let mut i: usize = 0;
            while i * 64 < F + 8 {
                sig.set_limb(i, red.limb(i));
                i = i + 1;
            }
        }
        return Float::<E, F, FAMILY>::round_pack(v.is_negative(), e, sig);
    }

    // ---- square root ---------------------------------------------------------------------------

    /// Correctly rounded: the significand's integer square root with a remainder-driven sticky bit is
    /// exact by construction, and round_pack does the one rounding.
    pub fn sqrt(self: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        if self.is_nan() {
            return Float::<E, F, FAMILY>::nan();
        }
        if self.is_zero() {
            return *self; // both zeros: sqrt(-0) = -0
        }
        if self.is_negative() {
            return Float::<E, F, FAMILY>::nan();
        }
        if self.is_infinite() {
            return *self;
        }
        let mut e: i64 = 0;
        let s3 = self.decode_sig3(&mut e);
        let sig1 = s3.shr(3); // F+1 bits, MSB at F
        // A = sig1 << k with (e - F - k) even: r = isqrt(A) then has exactly F+3 bits.
        let mut k: usize = F + 4;
        if (e - F as i64 - k as i64) % 2 != 0 {
            k = k + 1;
        }
        let mut a = UInt::<{2 * F + 16}>::zero();
        let mut i: usize = 0;
        while i * 64 < F + 8 {
            a.set_limb(i, sig1.limb(i));
            i = i + 1;
        }
        a = a.shl(k);
        // Digit-by-digit integer square root: r^2 <= a < (r+1)^2, remainder exactness for the sticky.
        let mut num = a;
        let mut res = UInt::<{2 * F + 16}>::zero();
        let mut bit = UInt::<{2 * F + 16}>::one().shl((2 * F + 14) / 2 * 2);
        while !bit.is_zero() {
            let t = res.wrapping_add(&bit);
            if !(num < t) {
                num = num.wrapping_sub(&t);
                res = res.shr(1).wrapping_add(&bit);
            } else {
                res = res.shr(1);
            }
            bit = bit.shr(2);
        }
        // sig3 = r with a cleared sticky slot below, jammed by the remainder.
        let mut sig = UInt::<{F + 8}>::zero();
        i = 0;
        while i * 64 < F + 8 {
            sig.set_limb(i, res.limb(i));
            i = i + 1;
        }
        sig = sig.shl(1);
        if !num.is_zero() {
            let one8 = UInt::<{F + 8}>::one();
            sig = sig.bit_or(&one8);
        }
        let q = (e - F as i64 - k as i64) / 2;
        return Float::<E, F, FAMILY>::round_pack(false, q + F as i64 + 2, sig);
    }

    // ---- fused multiply-add ----------------------------------------------------------------------

    /// self * b + c with ONE rounding: the product is exact, the addend aligns on a shared grid wide
    /// enough to hold both, and round_pack rounds the exact sum once.
    pub fn fma(self: &Float<E, F, FAMILY>, b: &Float<E, F, FAMILY>, c: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        if self.is_nan() || b.is_nan() || c.is_nan() {
            return Float::<E, F, FAMILY>::nan();
        }
        let ps = self.sign() != b.sign();
        if self.is_infinite() || b.is_infinite() {
            if self.is_zero() || b.is_zero() {
                return Float::<E, F, FAMILY>::nan(); // 0 * inf
            }
            if c.is_infinite() && c.sign() != ps {
                return Float::<E, F, FAMILY>::nan(); // inf - inf
            }
            return Float::<E, F, FAMILY>::infinity(ps);
        }
        if c.is_infinite() {
            return *c;
        }
        if self.is_zero() || b.is_zero() {
            // An exactly zero product: the sum is c, except zero + zero, which follows the sign rule.
            if c.is_zero() {
                if ps && c.sign() {
                    return Float::<E, F, FAMILY>::neg_zero();
                }
                return Float::<E, F, FAMILY>::zero();
            }
            return *c;
        }
        let mut ea: i64 = 0;
        let mut eb: i64 = 0;
        let sa = self.decode_sig3(&mut ea).shr(3);
        let sb = b.decode_sig3(&mut eb).shr(3);
        let mut wa = UInt::<{4 * F + 40}>::zero();
        let mut wb = UInt::<{4 * F + 40}>::zero();
        let mut i: usize = 0;
        while i * 64 < F + 8 {
            wa.set_limb(i, sa.limb(i));
            wb.set_limb(i, sb.limb(i));
            i = i + 1;
        }
        // The product, placed F+8 bits up the grid so the addend has room below; its scale exponent.
        let prod = wa.wrapping_mul(&wb).shl(F + 8);
        let ep = ea + eb - 2 * F as i64 - (F as i64 + 8);
        if c.is_zero() {
            let bl0 = prod.bit_length();
            let red0 = Float::<E, F, FAMILY>::grid_to_sig3(&prod, bl0);
            return Float::<E, F, FAMILY>::round_pack(ps, ep + bl0 as i64 - 1, red0);
        }
        let mut ec: i64 = 0;
        let sc = c.decode_sig3(&mut ec).shr(3);
        let cs = c.sign();
        // d: how far c's grid position sits above the product's scale. A left shift past the width
        // would lose c's TOP -- but at that distance the whole product is provably below c's sticky
        // slot, so c with a jam is the exact reduction. A right shift of any size jams what falls off,
        // zero survivors included, so no downward clamp exists at all.
        let d = ec - F as i64 - ep;
        if d > 3 * F as i64 + 39 {
            let mut s3c = c.decode_sig3(&mut ec);
            let one8 = UInt::<{F + 8}>::one();
            s3c = s3c.bit_or(&one8);
            return Float::<E, F, FAMILY>::round_pack(cs, ec, s3c);
        }
        let mut wc = UInt::<{4 * F + 40}>::zero();
        i = 0;
        while i * 64 < F + 8 {
            wc.set_limb(i, sc.limb(i));
            i = i + 1;
        }
        let mut jam = false;
        if d >= 0 {
            wc = wc.shl(d as usize);
        } else {
            let sh = (0 - d) as usize;
            let kept = wc.shr(sh);
            let back = kept.shl(sh);
            if !(back == wc) {
                jam = true;
            }
            wc = kept;
        }
        let mut sum = UInt::<{4 * F + 40}>::zero();
        let mut neg = ps;
        if ps == cs {
            sum = prod.wrapping_add(&wc);
        } else if !(prod < wc) {
            sum = prod.wrapping_sub(&wc);
        } else {
            sum = wc.wrapping_sub(&prod);
            neg = cs;
        }
        if sum.is_zero() && !jam {
            if ps && cs {
                return Float::<E, F, FAMILY>::neg_zero();
            }
            return Float::<E, F, FAMILY>::zero();
        }
        let bl = sum.bit_length();
        let mut red = Float::<E, F, FAMILY>::grid_to_sig3(&sum, bl);
        if jam {
            let one8 = UInt::<{F + 8}>::one();
            red = red.bit_or(&one8);
        }
        return Float::<E, F, FAMILY>::round_pack(neg, ep + bl as i64 - 1, red);
    }

    /// A grid value reduced to the F+4-bit sig3 shape round_pack takes, jamming what falls off.
    fn grid_to_sig3(w: &UInt<{4 * F + 40}>, bl: usize) UInt<{F + 8}> {
        let mut sig = UInt::<{F + 8}>::zero();
        if bl <= F + 4 {
            let mut i: usize = 0;
            while i * 64 < F + 8 {
                sig.set_limb(i, w.limb(i));
                i = i + 1;
            }
            return sig.shl(F + 4 - bl);
        }
        let sh = bl - (F + 4);
        let kept = w.shr(sh);
        let back = kept.shl(sh);
        let mut i: usize = 0;
        while i * 64 < F + 8 {
            sig.set_limb(i, kept.limb(i));
            i = i + 1;
        }
        if !(back == *w) {
            let one8 = UInt::<{F + 8}>::one();
            sig = sig.bit_or(&one8);
        }
        return sig;
    }

    // ---- decimal text --------------------------------------------------------------------------
    // Both directions run in a WIDER instance of this same type -- two more exponent bits, 96 more
    // fraction bits -- whose correctly-rounded arithmetic carries the digit work. 96 guard bits put the
    // accumulated scaling error far below the target's half-ulp, so the one final rounding lands right;
    // an input contrived to sit within 2^-90 of an exact tie is the one place the last digit could go
    // the other way. Round-tripping to_string -> from_str is exact: the digit count is chosen for it.

    /// Decimal digits that round-trip this format: ceil(precision * log10(2)) + 1.
    pub const fn decimal_digits() usize {
        return (F + 1) * 30103 / 100000 + 2;
    }

    /// Scientific notation, `-d.dddde+dd`, with trailing zeros trimmed. NaN prints `nan`, infinities
    /// `inf`/`-inf`, zeros `0`/`-0`. Deliberately NOT a `Format` conformance: a conformance emits for
    /// every instance, this body instantiates the two-sizes-wider format, and that pairing would demand
    /// ever wider floats without end. As a plain method it exists only where a call asks for it.
    pub fn to_string(self: &Float<E, F, FAMILY>) String {
        static_assert(E <= 28, "decimal text runs in a format two exponent bits wider; cap E at 28");
        if self.is_nan() {
            return String::from_str("nan");
        }
        let mut out = String::new();
        if self.is_negative() {
            out.push_str("-");
        }
        if self.is_infinite() {
            out.push_str("inf");
            return out;
        }
        if self.is_zero() {
            out.push_str("0");
            return out;
        }
        let a = self.abs();
        let mut w = Float::<{E + 2}, {F + 96}, IEEE>::convert(&a);
        let ten = Float::<{E + 2}, {F + 96}, IEEE>::from_f64(10.0);
        let one = Float::<{E + 2}, {F + 96}, IEEE>::one();
        // Estimate the decimal exponent from the binary one, then correct -- the estimate is within one.
        let mut eb: i64 = 0;
        let _ = w.decode_sig3(&mut eb);
        let mut d10 = eb * 30103 / 100000;
        let mag = if d10 < 0 {
            (0 - d10) as u64;
        } else {
            d10 as u64;
        };
        let scale = Float::<{E + 2}, {F + 96}, IEEE>::pow10_wide(mag);
        if d10 >= 0 {
            w = w / scale;
        } else {
            w = w * scale;
        }
        while !w.ieee_lt(&ten) {
            w = w / ten;
            d10 = d10 + 1;
        }
        while w.ieee_lt(&one) {
            w = w * ten;
            d10 = d10 - 1;
        }
        // Extract one digit past the printed count, for the final round.
        let p = Float::<E, F, FAMILY>::decimal_digits();
        let mut digits = Vector::<u8>::new();
        let mut i: usize = 0;
        while i <= p {
            let d = w.int_digit();
            digits.push(d as u8);
            let dv = Float::<{E + 2}, {F + 96}, IEEE>::from_f64(d as f64);
            w = (w - dv) * ten;
            i = i + 1;
        }
        if digits[p] >= 5 {
            let mut j = p;
            loop {
                if j == 0 {
                    // carried past the first digit: the value became 10.0...e -> 1.0...e+1
                    digits.set(0, 1);
                    d10 = d10 + 1;
                    break;
                }
                j = j - 1;
                if digits[j] == 9 {
                    digits.set(j, 0);
                } else {
                    digits.set(j, digits[j] + 1);
                    break;
                }
            }
        }
        let mut last = p; // one past the printed digits; trim zeros back to the leading digit
        while last > 1 && digits[last - 1] == 0 {
            last = last - 1;
        }
        out.push_byte(b'0' + digits[0]);
        if last > 1 {
            out.push_str(".");
            i = 1;
            while i < last {
                out.push_byte(b'0' + digits[i]);
                i = i + 1;
            }
        }
        out.push_str("e");
        if d10 >= 0 {
            out.push_str("+");
        } else {
            out.push_str("-");
            d10 = 0 - d10;
        }
        out.push_u64(d10 as u64);
        digits.free();
        return out;
    }

    /// Parse `[-]ddd[.ddd][e[+-]ddd]`, plus `nan`, `inf` and `-inf`. None on anything malformed.
    pub fn from_str(s: str) Option<Float<E, F, FAMILY>> {
        static_assert(E <= 28, "decimal text runs in a format two exponent bits wider; cap E at 28");
        let n = s.len();
        let mut i: usize = 0;
        let mut negv = false;
        if i < n && (s[i] == b'-' || s[i] == b'+') {
            negv = s[i] == b'-';
            i = i + 1;
        }
        if n - i == 3 {
            if s[i] == b'n' && s[i + 1] == b'a' && s[i + 2] == b'n' {
                return Option::<Float<E, F, FAMILY>>::Some(Float::<E, F, FAMILY>::nan());
            }
            if s[i] == b'i' && s[i + 1] == b'n' && s[i + 2] == b'f' {
                return Option::<Float<E, F, FAMILY>>::Some(Float::<E, F, FAMILY>::infinity(negv));
            }
        }
        let mut acc = Float::<{E + 2}, {F + 96}, IEEE>::zero();
        let ten = Float::<{E + 2}, {F + 96}, IEEE>::from_f64(10.0);
        let maxd = Float::<E, F, FAMILY>::decimal_digits() + 10;
        let mut nsig: usize = 0;
        let mut exp_adj: i64 = 0;
        let mut any = false;
        let mut seen_dot = false;
        while i < n {
            let ch = s[i];
            if ch == b'.' {
                if seen_dot {
                    return Option::<Float<E, F, FAMILY>>::None;
                }
                seen_dot = true;
                i = i + 1;
                continue;
            }
            if ch < b'0' || ch > b'9' {
                break;
            }
            any = true;
            if nsig < maxd {
                let dv = Float::<{E + 2}, {F + 96}, IEEE>::from_f64((ch - b'0') as f64);
                acc = acc * ten + dv;
                if !acc.is_zero() {
                    nsig = nsig + 1;
                }
                if seen_dot {
                    exp_adj = exp_adj - 1;
                }
            } else if !seen_dot {
                exp_adj = exp_adj + 1; // beyond the tracked precision: only the magnitude moves
            }
            i = i + 1;
        }
        if !any {
            return Option::<Float<E, F, FAMILY>>::None;
        }
        let mut e10: i64 = 0;
        if i < n && (s[i] == b'e' || s[i] == b'E') {
            i = i + 1;
            let mut nege = false;
            if i < n && (s[i] == b'-' || s[i] == b'+') {
                nege = s[i] == b'-';
                i = i + 1;
            }
            if i >= n {
                return Option::<Float<E, F, FAMILY>>::None;
            }
            while i < n {
                let ch = s[i];
                if ch < b'0' || ch > b'9' {
                    return Option::<Float<E, F, FAMILY>>::None;
                }
                if e10 < 100000000 {
                    e10 = e10 * 10 + (ch - b'0') as i64;
                }
                i = i + 1;
            }
            if nege {
                e10 = 0 - e10;
            }
        }
        if i != n {
            return Option::<Float<E, F, FAMILY>>::None;
        }
        let total = e10 + exp_adj;
        let mag = if total < 0 {
            (0 - total) as u64;
        } else {
            total as u64;
        };
        let scale = Float::<{E + 2}, {F + 96}, IEEE>::pow10_wide(mag);
        if total >= 0 {
            acc = acc * scale;
        } else {
            acc = acc / scale;
        }
        let mut r = Float::<E, F, FAMILY>::convert(&acc);
        if negv {
            r = r.neg();
        }
        return Option::<Float<E, F, FAMILY>>::Some(r);
    }

    /// 10^k by binary exponentiation: log2(k) roundings of error, absorbed by the 96 guard bits.
    fn pow10_wide(k: u64) Float<E, F, FAMILY> {
        let mut base = Float::<E, F, FAMILY>::from_f64(10.0);
        let mut r = Float::<E, F, FAMILY>::one();
        let mut kk = k;
        while kk != 0 {
            if (kk & 1) == 1 {
                r = r * base;
            }
            kk = kk >> 1;
            if kk != 0 {
                base = base * base;
            }
        }
        return r;
    }

    /// The leading integer digit of a value in [0, 10): read straight off the decoded significand.
    fn int_digit(self: &Float<E, F, FAMILY>) u64 {
        if self.is_zero() {
            return 0;
        }
        let mut e: i64 = 0;
        let s3 = self.decode_sig3(&mut e);
        if e < 0 {
            return 0;
        }
        return s3.shr(F + 3 - e as usize).to_u64();
    }

    // ---- comparison ----------------------------------------------------------------------------
    // IEEE equality and ordering: NaN compares equal to nothing (itself included), the two zeros are
    // one value, and everything else follows the encoding, which is monotonic within a sign.

    pub fn ieee_eq(self: &Float<E, F, FAMILY>, other: &Float<E, F, FAMILY>) bool {
        if self.is_nan() || other.is_nan() {
            return false;
        }
        if self.is_zero() && other.is_zero() {
            return true;
        }
        return self.bits == other.bits;
    }

    pub fn ieee_lt(self: &Float<E, F, FAMILY>, other: &Float<E, F, FAMILY>) bool {
        if self.is_nan() || other.is_nan() {
            return false;
        }
        if self.is_zero() && other.is_zero() {
            return false;
        }
        let sn = self.sign();
        let on = other.sign();
        if sn != on {
            return sn && !(self.is_zero() && other.is_zero());
        }
        if sn {
            return other.bits < self.bits;
        }
        return self.bits < other.bits;
    }

    pub fn ieee_le(self: &Float<E, F, FAMILY>, other: &Float<E, F, FAMILY>) bool {
        return self.ieee_lt(other) || self.ieee_eq(other);
    }

    // ---- conversion with the built-in f64/f32 ----------------------------------------------------
    // The bridge decodes the BUILT-IN value with plain u64 arithmetic -- its significand always fits one
    // limb -- and rounds into this format, so any (E, F) converts through one shared path.

    pub fn from_f64(v: f64) Float<E, F, FAMILY> {
        let vb = f64_bits(v);
        return Float::<E, F, FAMILY>::from_scalar_parts(
            vb >> 63 != 0,
            (vb >> 52 & 0x7FF) as i64,
            vb & 0xFFFFFFFFFFFFF,
            11,
            52,
        );
    }

    pub fn from_f32(v: f32) Float<E, F, FAMILY> {
        let vb = f32_bits(v) as u64;
        return Float::<E, F, FAMILY>::from_scalar_parts(vb >> 31 != 0, (vb >> 23 & 0xFF) as i64, vb & 0x7FFFFF, 8, 23);
    }

    /// Decode a built-in format's fields (fraction in one u64) and round into THIS format.
    fn from_scalar_parts(negative: bool, ebits: i64, frac: u64, se: usize, sf: usize) Float<E, F, FAMILY> {
        let emax_src = (1i64 << se as i64) - 1;
        let bias_src = (1i64 << (se - 1) as i64) - 1;
        if ebits == emax_src {
            if frac == 0 {
                return Float::<E, F, FAMILY>::overflow_result(negative); // finite-only: saturate
            }
            return Float::<E, F, FAMILY>::nan();
        }
        if ebits == 0 && frac == 0 {
            if negative {
                return Float::<E, F, FAMILY>::neg_zero();
            }
            return Float::<E, F, FAMILY>::zero();
        }
        // The value is sig * 2^(e - sf) with sig's MSB at position `top`.
        let mut sig64 = frac;
        let mut e: i64 = 0;
        if ebits == 0 {
            e = 1 - bias_src;
        } else {
            sig64 = sig64 | 1u64 << sf as u64;
            e = ebits - bias_src;
        }
        let mut top: i64 = 63;
        while (sig64 >> top as u64 & 1) == 0 {
            top = top - 1;
        }
        // exponent of the MSB: e - sf + (top - sf adjustment folded below)
        let ebit = e + (top - sf as i64);
        // Place the MSB at F+3 in the working width, jamming when the source has more bits.
        let mut sig = UInt::<{F + 8}>::zero();
        if top as usize <= F + 3 {
            sig = UInt::<{F + 8}>::from_u64(sig64).shl(F + 3 - top as usize);
        } else {
            let sh = top as usize - (F + 3);
            let kept = sig64 >> sh as u64;
            let jam = kept << sh as u64 != sig64;
            sig = UInt::<{F + 8}>::from_u64(kept);
            if jam {
                let one = UInt::<{F + 8}>::one();
                sig = sig.bit_or(&one);
            }
        }
        return Float::<E, F, FAMILY>::round_pack(negative, ebit, sig);
    }

    pub fn to_f64(self: &Float<E, F, FAMILY>) f64 {
        let b = self.to_scalar_bits(11, 52);
        return f64_from_bits(b);
    }

    pub fn to_f32(self: &Float<E, F, FAMILY>) f32 {
        let b = self.to_scalar_bits(8, 23);
        return f32_from_bits(b as u32);
    }

    /// Round THIS value into a built-in format's fields, packed as its raw bits in a u64. The target
    /// significand always fits one limb, so the rounding runs in plain u64 arithmetic.
    fn to_scalar_bits(self: &Float<E, F, FAMILY>, de: usize, df: usize) u64 {
        let sbit = if self.sign() {
            1u64 << (de + df) as u64;
        } else {
            0u64;
        };
        let emax_dst = (1u64 << de as u64) - 1;
        if self.is_nan() {
            return sbit | emax_dst << df as u64 | 1u64 << (df - 1) as u64;
        }
        if self.is_infinite() {
            return sbit | emax_dst << df as u64;
        }
        if self.is_zero() {
            return sbit;
        }
        let mut e: i64 = 0;
        let sig3 = self.decode_sig3(&mut e);
        // Reduce to df+4 bits in a u64: MSB at df+3, jamming everything below.
        let bl = F + 4; // decode_sig3 normalizes the MSB to F+3
        let mut kept: u64 = 0;
        let mut jam = false;
        if bl <= df + 4 {
            kept = sig3.to_u64() << (df + 4 - bl) as u64;
        } else {
            let sh = bl - (df + 4);
            let k = sig3.shr(sh);
            let back = k.shl(sh);
            kept = k.to_u64();
            if !(back == sig3) {
                jam = true;
            }
        }
        if jam {
            kept = kept | 1;
        }
        // Round to nearest even at df precision, then encode with the destination's bias and range.
        let bias_dst = (1i64 << (de - 1) as i64) - 1;
        let emin_dst = 1 - bias_dst;
        if e < emin_dst {
            let mut sh2 = (emin_dst - e) as u64;
            if sh2 > (df + 5) as u64 {
                sh2 = (df + 5) as u64;
            }
            let low = kept & (1u64 << sh2) - 1;
            kept = kept >> sh2;
            if low != 0 {
                kept = kept | 1;
            }
            e = emin_dst;
        }
        let grs = kept & 7;
        let mut k2 = kept >> 3;
        if grs > 4 || grs == 4 && (k2 & 1) == 1 {
            k2 = k2 + 1;
        }
        if k2 >> (df + 1) as u64 != 0 {
            k2 = k2 >> 1;
            e = e + 1;
        }
        if e > bias_dst {
            return sbit | emax_dst << df as u64; // overflow: infinity
        }
        let mut ebits: u64 = 0;
        if k2 >> df as u64 != 0 {
            ebits = (e + bias_dst) as u64;
        }
        return sbit | ebits << df as u64 | k2 & (1u64 << df as u64) - 1;
    }
}

extend<const E: usize, const F: usize, const FAMILY: FloatFamily> Float<E, F, FAMILY> {
    // ---- integer rounding ----------------------------------------------------------------------
    // Bit surgery on the encoding, so every result is EXACT: clearing fraction bits truncates, and
    // the one-step corrections go through add/sub, which are exact on integers this small.

    /// The integer part: rounds toward zero.
    pub fn trunc(self: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        if self.is_nan() || self.is_infinite() {
            return *self;
        }
        let eb = self.exp_field();
        let e = eb as i64 - Float::<E, F, FAMILY>::bias();
        if eb == 0 || e < 0 {
            if self.sign() {
                return Float::<E, F, FAMILY>::neg_zero();
            }
            return Float::<E, F, FAMILY>::zero();
        }
        if e >= F as i64 {
            return *self;
        }
        let drop = (F as i64 - e) as usize;
        return Float::<E, F, FAMILY>::from_raw(self.to_raw().shr(drop).shl(drop));
    }

    /// The largest integer at or below the value.
    pub fn floor(self: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        let t = self.trunc();
        if self.sign() && !(t.to_raw() == self.to_raw()) {
            let one = Float::<E, F, FAMILY>::one();
            return t.sub(&one);
        }
        return t;
    }

    /// The smallest integer at or above the value.
    pub fn ceil(self: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        let t = self.trunc();
        if !self.sign() && !(t.to_raw() == self.to_raw()) {
            let one = Float::<E, F, FAMILY>::one();
            return t.add(&one);
        }
        return t;
    }

    // The half bit and what lies below it, for the two round flavors. Works from the NORMALIZED
    // significand (decode_sig3 renormalizes subnormals), so a family whose subnormals reach past 0.5
    // is read correctly too.
    fn round_parts(self: &Float<E, F, FAMILY>, half: &mut bool, rest: &mut bool, odd: &mut bool) i64 {
        let mut e: i64 = 0;
        let sig = self.decode_sig3(&mut e).shr(3);
        *half = false;
        *rest = false;
        *odd = false;
        if e < 0 - 1 || e >= F as i64 {
            return e;
        }
        if e == 0 - 1 {
            *half = true; // the MSB is the half digit
            let msb_only = UInt::<{F + 8}>::one().shl(sig.bit_length() - 1);
            *rest = !(sig == msb_only); // any bit below the MSB
            return e;
        }
        let hpos = (F as i64 - e - 1) as usize;
        *half = sig.bit(hpos);
        if hpos > 0 {
            let below = sig.shr(hpos).shl(hpos);
            *rest = !(below == sig);
        }
        *odd = sig.bit(hpos + 1);
        return e;
    }

    /// Rounds to the nearest integer, halves AWAY from zero -- what C's round does.
    pub fn round(self: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        if self.is_nan() || self.is_infinite() || self.is_zero() {
            return *self;
        }
        let mut half = false;
        let mut rest = false;
        let mut odd = false;
        let e = self.round_parts(&mut half, &mut rest, &mut odd);
        if e >= F as i64 {
            return *self;
        }
        let t = self.trunc();
        if !half {
            return t;
        }
        let one = Float::<E, F, FAMILY>::one();
        if self.sign() {
            return t.sub(&one);
        }
        return t.add(&one);
    }

    /// Rounds to the nearest integer, halves to the EVEN neighbour -- the default IEEE rounding.
    pub fn round_ties_even(self: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        if self.is_nan() || self.is_infinite() || self.is_zero() {
            return *self;
        }
        let mut half = false;
        let mut rest = false;
        let mut odd = false;
        let e = self.round_parts(&mut half, &mut rest, &mut odd);
        if e >= F as i64 {
            return *self;
        }
        let t = self.trunc();
        if !half || !rest && !odd {
            return t;
        }
        let one = Float::<E, F, FAMILY>::one();
        if self.sign() {
            return t.sub(&one);
        }
        return t.add(&one);
    }

    /// The fractional part: self - trunc(self), exact, keeping the value's sign; NaN for infinities.
    pub fn fract(self: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        let t = self.trunc();
        return self.sub(&t);
    }

    // ---- selection -----------------------------------------------------------------------------

    /// The smaller value, IGNORING a NaN operand (both NaN gives NaN); the negative zero counts as
    /// smaller than the positive one, so the answer is deterministic everywhere.
    pub fn min(self: &Float<E, F, FAMILY>, other: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        if self.is_nan() {
            return *other;
        }
        if other.is_nan() {
            return *self;
        }
        if self.ieee_lt(other) {
            return *self;
        }
        if other.ieee_lt(self) {
            return *other;
        }
        if self.sign() {
            return *self; // equal incl the zeros: the negative-signed one is the minimum
        }
        return *other;
    }

    pub fn max(self: &Float<E, F, FAMILY>, other: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        if self.is_nan() {
            return *other;
        }
        if other.is_nan() {
            return *self;
        }
        if self.ieee_lt(other) {
            return *other;
        }
        if other.ieee_lt(self) {
            return *self;
        }
        if self.sign() {
            return *other;
        }
        return *self;
    }

    /// Clamps into [lo, hi]. Panics when lo > hi or a bound is NaN -- the RANGE is the caller's
    /// constant, so a broken one is a bug, not an input. A NaN VALUE passes through as NaN.
    pub fn clamp(self: &Float<E, F, FAMILY>, lo: &Float<E, F, FAMILY>, hi: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        if lo.is_nan() || hi.is_nan() || hi.ieee_lt(lo) {
            panic("clamp requires an ordered, NaN-free range");
        }
        if self.is_nan() {
            return *self;
        }
        if self.ieee_lt(lo) {
            return *lo;
        }
        if hi.ieee_lt(self) {
            return *hi;
        }
        return *self;
    }

    /// The value with `from`'s sign -- including onto NaN and zero, which negation alone cannot reach.
    pub fn copysign(self: &Float<E, F, FAMILY>, from: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        if self.sign() == from.sign() {
            return *self;
        }
        return self.neg();
    }

    /// +-1 by the sign, so signum(-0) is -1 and signum(+0) is +1 (copysign's reading); NaN stays NaN.
    pub fn signum(self: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        if self.is_nan() {
            return *self;
        }
        let one = Float::<E, F, FAMILY>::one();
        return one.copysign(self);
    }

    // ---- neighbours ----------------------------------------------------------------------------

    /// The next representable value toward +infinity. On the encoding this is one raw step: magnitude
    /// up for a positive value, down for a negative one, and -0 steps to the smallest positive
    /// subnormal. In the FINITE_ONLY family one past max_finite is the NaN slot, and NaN is what
    /// comes back -- there IS nothing else past the top there.
    pub fn next_up(self: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        if self.is_nan() {
            return *self;
        }
        if self.is_infinite() {
            if !self.sign() {
                return *self;
            }
            return Float::<E, F, FAMILY>::max_finite(true);
        }
        let one = UInt::<{1 + E + F}>::one();
        let r = self.to_raw();
        if self.sign() {
            if self.is_zero() {
                return Float::<E, F, FAMILY>::from_raw(one); // -0 -> the smallest positive
            }
            return Float::<E, F, FAMILY>::from_raw(r.wrapping_sub(&one));
        }
        return Float::<E, F, FAMILY>::from_raw(r.wrapping_add(&one));
    }

    pub fn next_down(self: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        return self.neg().next_up().neg();
    }

    /// The distance to the next representable magnitude: 2^(max(e, emin) - F). The smallest positive
    /// subnormal for zero, infinity for infinity, NaN for NaN.
    pub fn ulp(self: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        if self.is_nan() {
            return *self;
        }
        if self.is_infinite() {
            return self.abs();
        }
        let one = UInt::<{1 + E + F}>::one();
        if self.is_zero() {
            return Float::<E, F, FAMILY>::from_raw(one);
        }
        let mut e: i64 = 0;
        let _ = self.decode_sig3(&mut e);
        if e < Float::<E, F, FAMILY>::emin() {
            e = Float::<E, F, FAMILY>::emin();
        }
        let t = e - F as i64;
        if t >= Float::<E, F, FAMILY>::emin() {
            let z = UInt::<{1 + E + F}>::zero();
            return Float::<E, F, FAMILY>::pack(false, (t + Float::<E, F, FAMILY>::bias()) as u64, &z);
        }
        // Below the normal range the spacing is one subnormal bit.
        let pos = (t - (Float::<E, F, FAMILY>::emin() - F as i64)) as usize;
        return Float::<E, F, FAMILY>::from_raw(one.shl(pos));
    }

    /// self * 2^n, correctly rounded (one round_pack): exponent arithmetic, no multiplication.
    pub fn scalbn(self: &Float<E, F, FAMILY>, n: i64) Float<E, F, FAMILY> {
        if self.is_nan() || self.is_infinite() || self.is_zero() {
            return *self;
        }
        let mut nn = n;
        if nn > 1000000 {
            nn = 1000000;
        }
        if nn < 0 - 1000000 {
            nn = 0 - 1000000;
        }
        let mut e: i64 = 0;
        let sig = self.decode_sig3(&mut e);
        return Float::<E, F, FAMILY>::round_pack(self.sign(), e + nn, sig);
    }

    // ---- the encoding's parts --------------------------------------------------------------------

    /// Sign, biased exponent field, and stored fraction -- the raw fields, not the mathematical
    /// significand (the implicit bit is not included).
    pub fn to_parts(self: &Float<E, F, FAMILY>) (bool, u64, UInt<{1 + E + F}>) {
        return self.sign(), self.exp_field(), self.frac_field();
    }

    /// The inverse of to_parts; the exponent and fraction are masked to their fields.
    pub fn from_parts(negative: bool, ebits: u64, frac: &UInt<{1 + E + F}>) Float<E, F, FAMILY> {
        let m = UInt::<{1 + E + F}>::max().shr(1 + E);
        let f = frac.bit_and(&m);
        return Float::<E, F, FAMILY>::pack(negative, ebits & Float::<E, F, FAMILY>::exp_field_max(), &f);
    }

    // ---- integers, directly ----------------------------------------------------------------------
    // The wide integers convert WITHOUT an f64 stopover: the top F+4 bits ride into round_pack with a
    // sticky bit, so the single rounding is the correct one at any width -- u128 -> f128 is exact
    // where f64 in the middle would have rounded twice.

    fn from_mag<const M: usize>(negative: bool, v: &UInt<M>) Float<E, F, FAMILY> {
        if v.is_zero() {
            return Float::<E, F, FAMILY>::zero();
        }
        let n = v.bit_length();
        let mut sig = UInt::<{F + 8}>::zero();
        if n <= F + 4 {
            let mut i: usize = 0;
            while i * 64 < n {
                sig.set_limb(i, v.limb(i));
                i = i + 1;
            }
            sig = sig.shl(F + 4 - n);
        } else {
            let sh = n - (F + 4);
            let top = v.shr(sh);
            let back = top.shl(sh);
            let mut i: usize = 0;
            while i * 64 < F + 5 {
                sig.set_limb(i, top.limb(i));
                i = i + 1;
            }
            if !(back == *v) {
                let one = UInt::<{F + 8}>::one();
                sig = sig.bit_or(&one); // sticky: the dropped bits still steer the rounding
            }
        }
        return Float::<E, F, FAMILY>::round_pack(negative, (n - 1) as i64, sig);
    }

    pub fn from_uint<const M: usize>(v: &UInt<M>) Float<E, F, FAMILY> {
        return Float::<E, F, FAMILY>::from_mag(false, v);
    }

    pub fn from_int<const M: usize>(v: &Int<M>) Float<E, F, FAMILY> {
        if v.is_negative() {
            let mag = v.wrapping_neg().to_unsigned(); // MIN wraps to itself: its unsigned reading IS the magnitude
            return Float::<E, F, FAMILY>::from_mag(true, &mag);
        }
        let mag = v.to_unsigned();
        return Float::<E, F, FAMILY>::from_mag(false, &mag);
    }

    /// The integer part, SATURATING like the built-in casts: NaN and everything below zero give
    /// zero, values at or past 2^M give max(). An OUT parameter names the width -- `x.to_uint(&mut
    /// r)` -- because a generic return position binds nothing at a call site.
    pub fn to_uint<const M: usize>(self: &Float<E, F, FAMILY>, out: &mut UInt<M>) {
        *out = UInt::<M>::zero();
        Float::<E, F, FAMILY>::mag_into(self, out);
    }

    // The shared magnitude conversion. An OUT parameter rather than a generic return, because the
    // width is inferred from an argument -- a return position binds nothing.
    fn mag_into<const M: usize>(v: &Float<E, F, FAMILY>, out: &mut UInt<M>) {
        if v.is_nan() || v.is_zero() || v.sign() {
            return;
        }
        if v.is_infinite() {
            *out = UInt::<M>::max();
            return;
        }
        let mut e: i64 = 0;
        let sig = v.decode_sig3(&mut e).shr(3);
        if e < 0 {
            return;
        }
        if e >= M as i64 {
            *out = UInt::<M>::max();
            return;
        }
        if e < F as i64 {
            // Truncate in the wide significand FIRST: UInt<M> may be narrower than the significand.
            let t = sig.shr((F as i64 - e) as usize);
            let mut i: usize = 0;
            while i * 64 < e as usize + 1 {
                out.set_limb(i, t.limb(i));
                i = i + 1;
            }
            return;
        }
        let mut r = UInt::<M>::zero();
        let mut i: usize = 0;
        while i * 64 < F + 1 {
            r.set_limb(i, sig.limb(i));
            i = i + 1;
        }
        *out = r.shl((e - F as i64) as usize);
    }

    /// The integer part, saturating at min()/max(); NaN gives zero.
    pub fn to_int<const M: usize>(self: &Float<E, F, FAMILY>, out: &mut Int<M>) {
        if self.is_nan() {
            *out = Int::<M>::zero();
            return;
        }
        let a = self.abs();
        let mut mag = UInt::<M>::zero();
        Float::<E, F, FAMILY>::mag_into(&a, &mut mag);
        let lim = UInt::<M>::one().shl(M - 1);
        if self.sign() {
            if mag.cmp(&lim) >= 0 {
                *out = Int::<M>::min();
                return;
            }
            *out = Int::<M>::from_unsigned(&mag).wrapping_neg();
            return;
        }
        if mag.cmp(&lim) >= 0 {
            *out = Int::<M>::max();
            return;
        }
        *out = Int::<M>::from_unsigned(&mag);
    }
}

// The operator conformances. `==` is IEEE equality: NaN equals nothing, the zeros are one value --
// exactly what `==` on the built-in floats means. `<` orders through `cmp`, which needs a TOTAL order,
// so NaN sorts above +infinity (negative NaN below -infinity); for strict IEEE comparisons, where any
// NaN makes every comparison false, use ieee_lt/ieee_le.
extend<const E: usize, const F: usize, const FAMILY: FloatFamily> Float<E, F, FAMILY> as Add {
    type Output = Float<E, F, FAMILY>;

    pub fn add(self: &Float<E, F, FAMILY>, other: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        if self.is_nan() || other.is_nan() {
            return Float::<E, F, FAMILY>::nan();
        }
        if self.is_infinite() {
            if other.is_infinite() && self.sign() != other.sign() {
                return Float::<E, F, FAMILY>::nan(); // inf + -inf has no value
            }
            return *self;
        }
        if other.is_infinite() {
            return *other;
        }
        if self.is_zero() && other.is_zero() {
            // +0 unless both are -0: the IEEE sign rule for exact zero sums under round-to-nearest.
            if self.sign() && other.sign() {
                return Float::<E, F, FAMILY>::neg_zero();
            }
            return Float::<E, F, FAMILY>::zero();
        }
        if self.is_zero() {
            return *other;
        }
        if other.is_zero() {
            return *self;
        }
        let mut ea: i64 = 0;
        let mut eb: i64 = 0;
        let mut sa = self.decode_sig3(&mut ea);
        let mut sb = other.decode_sig3(&mut eb);
        let mut na = self.sign();
        let nb = other.sign();
        // Order by exponent, then magnitude, so `a` is the larger operand and the result's sign is its.
        if eb > ea || eb == ea && sb > sa {
            let te = ea;
            ea = eb;
            eb = te;
            let ts = sa;
            sa = sb;
            sb = ts;
            na = nb;
        }
        let d = (ea - eb) as usize;
        sb = Float::<E, F, FAMILY>::shr_jam(&sb, d);
        if self.sign() == other.sign() {
            let mut sum = sa.wrapping_add(&sb);
            if sum.bit(F + 4) {
                sum = Float::<E, F, FAMILY>::shr_jam(&sum, 1);
                return Float::<E, F, FAMILY>::round_pack(na, ea + 1, sum);
            }
            return Float::<E, F, FAMILY>::round_pack(na, ea, sum);
        }
        let diff = sa.wrapping_sub(&sb);
        if diff.is_zero() {
            return Float::<E, F, FAMILY>::zero(); // exact cancellation: +0 under round-to-nearest
        }
        // Renormalize: the MSB may have fallen well below F+3 after cancellation. Shifting left past
        // the sticky bit is only reached when the subtraction was exact (d <= 1), so no set sticky is
        // ever stretched.
        let mut z = diff;
        let mut e = ea;
        let bl = z.bit_length();
        if bl < F + 4 {
            let sh = F + 4 - bl;
            z = z.shl(sh);
            e = e - sh as i64;
        }
        return Float::<E, F, FAMILY>::round_pack(na, e, z);
    }
}

extend<const E: usize, const F: usize, const FAMILY: FloatFamily> Float<E, F, FAMILY> as Sub {
    type Output = Float<E, F, FAMILY>;

    pub fn sub(self: &Float<E, F, FAMILY>, other: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        let n = other.neg();
        return self.add(&n);
    }
}

extend<const E: usize, const F: usize, const FAMILY: FloatFamily> Float<E, F, FAMILY> as Mul {
    type Output = Float<E, F, FAMILY>;

    pub fn mul(self: &Float<E, F, FAMILY>, other: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        let neg = self.sign() != other.sign();
        if self.is_nan() || other.is_nan() {
            return Float::<E, F, FAMILY>::nan();
        }
        if self.is_infinite() || other.is_infinite() {
            if self.is_zero() || other.is_zero() {
                return Float::<E, F, FAMILY>::nan(); // 0 * inf has no value
            }
            return Float::<E, F, FAMILY>::infinity(neg);
        }
        if self.is_zero() || other.is_zero() {
            if neg {
                return Float::<E, F, FAMILY>::neg_zero();
            }
            return Float::<E, F, FAMILY>::zero();
        }
        let mut ea: i64 = 0;
        let mut eb: i64 = 0;
        let sa = self.decode_sig3(&mut ea);
        let sb = other.decode_sig3(&mut eb);
        // The F+1-bit significands (the >>3 undoes the GRS positioning) multiply into 2F+2 bits.
        let mut wa = UInt::<{2 * F + 8}>::zero();
        let mut wb = UInt::<{2 * F + 8}>::zero();
        let a1 = sa.shr(3);
        let b1 = sb.shr(3);
        let mut i: usize = 0;
        while i * 64 < F + 8 {
            wa.set_limb(i, a1.limb(i));
            wb.set_limb(i, b1.limb(i));
            i = i + 1;
        }
        let p = wa.wrapping_mul(&wb); // exact: 2F+2 bits fit the width
        // MSB at 2F+1 or 2F; bring it to F+3 with a jamming shift, then round once.
        let bl = p.bit_length();
        let sh = bl - (F + 4);
        let kept = p.shr(sh);
        let back = kept.shl(sh);
        let mut sig = UInt::<{F + 8}>::zero();
        i = 0;
        while i * 64 < F + 8 {
            sig.set_limb(i, kept.limb(i));
            i = i + 1;
        }
        if !(back == p) {
            let one = UInt::<{F + 8}>::one();
            sig = sig.bit_or(&one);
        }
        // exponents: each significand is sig1 * 2^(e - F); the product's MSB landed at bl-1.
        let e = ea + eb + (bl as i64 - 1) - 2 * F as i64;
        return Float::<E, F, FAMILY>::round_pack(neg, e, sig);
    }
}

extend<const E: usize, const F: usize, const FAMILY: FloatFamily> Float<E, F, FAMILY> as Div {
    type Output = Float<E, F, FAMILY>;

    pub fn div(self: &Float<E, F, FAMILY>, other: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        let neg = self.sign() != other.sign();
        if self.is_nan() || other.is_nan() {
            return Float::<E, F, FAMILY>::nan();
        }
        if self.is_infinite() {
            if other.is_infinite() {
                return Float::<E, F, FAMILY>::nan(); // inf / inf has no value
            }
            return Float::<E, F, FAMILY>::infinity(neg);
        }
        if other.is_infinite() {
            if neg {
                return Float::<E, F, FAMILY>::neg_zero();
            }
            return Float::<E, F, FAMILY>::zero();
        }
        if other.is_zero() {
            if self.is_zero() {
                return Float::<E, F, FAMILY>::nan(); // 0 / 0 has no value
            }
            if FAMILY == FloatFamily::FF_FINITE_ONLY {
                return Float::<E, F, FAMILY>::nan(); // no infinity to give
            }
            return Float::<E, F, FAMILY>::infinity(neg); // finite / 0: the IEEE divideByZero result
        }
        if self.is_zero() {
            if neg {
                return Float::<E, F, FAMILY>::neg_zero();
            }
            return Float::<E, F, FAMILY>::zero();
        }
        let mut ea: i64 = 0;
        let mut eb: i64 = 0;
        let sa = self.decode_sig3(&mut ea);
        let sb = other.decode_sig3(&mut eb);
        // (a << F+4) / b gives a quotient with F+5 or F+4 significant bits; the remainder jams.
        let a1 = sa.shr(3);
        let b1 = sb.shr(3);
        let mut num = UInt::<{2 * F + 16}>::zero();
        let mut den = UInt::<{2 * F + 16}>::zero();
        let mut i: usize = 0;
        while i * 64 < F + 8 {
            num.set_limb(i, a1.limb(i));
            den.set_limb(i, b1.limb(i));
            i = i + 1;
        }
        num = num.shl(F + 4);
        let mut rem = UInt::<{2 * F + 16}>::zero();
        let q = num.divmod(&den, &mut rem);
        let bl = q.bit_length(); // F+5 when a1 >= b1, else F+4
        let sh = bl - (F + 4);
        let kept = q.shr(sh);
        let back = kept.shl(sh);
        let mut sig = UInt::<{F + 8}>::zero();
        i = 0;
        while i * 64 < F + 8 {
            sig.set_limb(i, kept.limb(i));
            i = i + 1;
        }
        if !(back == q) || !rem.is_zero() {
            let one = UInt::<{F + 8}>::one();
            sig = sig.bit_or(&one);
        }
        let e = ea - eb + (bl as i64 - 1) - (F as i64 + 4);
        return Float::<E, F, FAMILY>::round_pack(neg, e, sig);
    }
}

extend<const E: usize, const F: usize, const FAMILY: FloatFamily> Float<E, F, FAMILY> as Rem {
    type Output = Float<E, F, FAMILY>;

    /// C's fmod: the remainder of truncating division, with the DIVIDEND's sign -- and EXACT, because
    /// the remainder of two representable values always is; the shift-subtract runs on the integer
    /// significands, one exponent step per iteration. NaN for a NaN operand, x % 0, and inf % y;
    /// x % inf is x.
    pub fn rem(self: &Float<E, F, FAMILY>, other: &Float<E, F, FAMILY>) Float<E, F, FAMILY> {
        if self.is_nan() || other.is_nan() || self.is_infinite() || other.is_zero() {
            return Float::<E, F, FAMILY>::nan();
        }
        if other.is_infinite() || self.is_zero() {
            return *self;
        }
        let mut ex: i64 = 0;
        let mut ey: i64 = 0;
        let mut ux = self.decode_sig3(&mut ex).shr(3);
        let uy = other.decode_sig3(&mut ey).shr(3);
        if ex < ey {
            return *self; // |x| < |y|: x is its own remainder
        }
        while ex > ey {
            if ux.cmp(&uy) >= 0 {
                ux = ux.wrapping_sub(&uy);
            }
            ux = ux.shl(1);
            ex = ex - 1;
        }
        if ux.cmp(&uy) >= 0 {
            ux = ux.wrapping_sub(&uy);
        }
        if ux.is_zero() {
            if self.sign() {
                return Float::<E, F, FAMILY>::neg_zero();
            }
            return Float::<E, F, FAMILY>::zero();
        }
        // Normalize the MSB back to F -- but no lower than emin, where the result is subnormal. A
        // subnormal DIVISOR sits below emin already: then nothing may shift, and round_pack's own
        // subnormal path finishes the (exact) encoding.
        let mut sh = F + 1 - ux.bit_length();
        let mut cap = ey - Float::<E, F, FAMILY>::emin();
        if cap < 0 {
            cap = 0;
        }
        if cap < sh as i64 {
            sh = cap as usize;
        }
        ux = ux.shl(sh);
        return Float::<E, F, FAMILY>::round_pack(self.sign(), ey - sh as i64, ux.shl(3));
    }
}

extend<const E: usize, const F: usize, const FAMILY: FloatFamily> Float<E, F, FAMILY> as Eq {
    pub fn eq(self: &Float<E, F, FAMILY>, other: &Float<E, F, FAMILY>) bool {
        return self.ieee_eq(other);
    }
}

extend<const E: usize, const F: usize, const FAMILY: FloatFamily> Float<E, F, FAMILY> as Ord {
    pub fn cmp(self: &Float<E, F, FAMILY>, other: &Float<E, F, FAMILY>) i32 {
        // Total order over the encoding: flip the sign bit for positives, complement for negatives.
        let ka = Float::<E, F, FAMILY>::total_key(self);
        let kb = Float::<E, F, FAMILY>::total_key(other);
        if ka < kb {
            return -1;
        }
        if kb < ka {
            return 1;
        }
        return 0;
    }
}

extend<const E: usize, const F: usize, const FAMILY: FloatFamily> Float<E, F, FAMILY> as Hash {
    /// Consistent with Eq's IEEE equality where equality exists: +0 and -0 are equal and hash alike.
    /// (NaN equals nothing, so its hash constrains nothing.)
    pub fn hash(self: &Float<E, F, FAMILY>) u64 {
        if self.is_zero() {
            return UInt::<{1 + E + F}>::zero().hash();
        }
        return self.bits.hash();
    }
}

extend<const E: usize, const F: usize, const FAMILY: FloatFamily> Float<E, F, FAMILY> {
    fn total_key(v: &Float<E, F, FAMILY>) UInt<{1 + E + F}> {
        let top = UInt::<{1 + E + F}>::one().shl(E + F);
        if v.sign() {
            return v.bits.bit_not();
        }
        return v.bits.bit_or(&top);
    }
}

// The standard formats the built-ins do not cover. `Float<8, 23>` and `Float<11, 52>` ARE the built-in
// `f32`/`f64` formats and exist for generic code and tests; the aliases keep their built-in names.
pub type f16 = Float<5, 10>;
pub type f128 = Float<15, 112>;
pub type f256 = Float<19, 236>;
pub type f8e5m2 = Float<5, 2>;
pub type f8e4m3fn = Float<4, 3, FINITE_ONLY>;

// ---- bit bridges to the built-in floats ----------------------------------------------------------------
// A reinterpretation, not a conversion. Through a UNION rather than a pointer cast: reading the other
// member of a union is the type pun both gcc and clang document as defined, where the cast form is a
// strict-aliasing violation an optimizer is entitled to break.

union Pun64 {
    pub f: f64,
    pub u: u64,
}

union Pun32 {
    pub f: f32,
    pub u: u32,
}

pub fn f64_bits(v: f64) u64 {
    let p = Pun64 { f: v };
    return p.u;
}

pub fn f64_from_bits(b: u64) f64 {
    let p = Pun64 { u: b };
    return p.f;
}

pub fn f32_bits(v: f32) u32 {
    let p = Pun32 { f: v };
    return p.u;
}

pub fn f32_from_bits(b: u32) f32 {
    let p = Pun32 { u: b };
    return p.f;
}
