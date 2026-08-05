// Fixed-width integers of any size: `UInt<BITS>` and `Int<BITS>`, monomorphized per width, with the
// aliases `u128`/`u256`/`u512`/`u1024` and `i128`/`i256`/`i512`/`i1024` on top. Import with
// `import std::num::int as *;` for the aliases unqualified, or `import std::num::int;` to name them
// through the module.
//
// Deliberately NOT a prelude module. The storage `[u64; BITS / 64]` needs a compiler that substitutes a
// const-generic ARGUMENT into an array length expression, which the release the bootstrap starts from does
// not have; a prelude module is compiled by that release, and this one would not build there. It can move
// up once a release carries the substitution.
//
// The generic argument is the BIT width, not a limb count: `UInt<256>` says what it is at every use site
// and in every diagnostic, and the storage `[u64; BITS / 64]` follows from it. Widths must be a positive
// multiple of 64; a width that is not is a compile-time error at the first operation on the type.
//
// Storage is `u64` limbs, LEAST SIGNIFICANT FIRST, for signed values too. A signed value is two's
// complement over the whole width, so `Int<256>` is exactly `UInt<256>`'s bit pattern read differently:
// addition, subtraction, multiplication, the bitwise operations and left shift are the SAME limb code for
// both, and only ordering, division, remainder, right shift, overflow detection and formatting differ.
// Signed limbs would put C's undefined signed overflow and implementation-defined signed shifts underneath
// all of that; unsigned limbs make every step defined and portable.
//
// Semantics match the built-in integers. `UInt` arithmetic WRAPS at its width, as the built-in unsigned
// types do; `Int` arithmetic TRAPS on overflow, as the built-in signed types do. Division by zero panics
// either way. `wrapping_*`, `checked_*` and `saturating_*` are there when a different answer is wanted.
//
// Both are plain values: no heap, no allocator, no `Free`. They copy like the built-in integers do.

// ---------------------------------------------------------------------------------------------------------
// 64x64 -> 128 multiply
// ---------------------------------------------------------------------------------------------------------

// The full product of two limbs: the low half is returned, the high half stored through `hi`. Split into
// 32-bit halves rather than reaching for a compiler extension, so it is the same code on every target --
// each partial product is at most (2^32-1)^2, which a u64 holds exactly.
const fn mul_wide(a: u64, b: u64, hi: *mut u64) u64 {
    let a0 = a & 0xFFFFFFFFu64;
    let a1 = a >> 32;
    let b0 = b & 0xFFFFFFFFu64;
    let b1 = b >> 32;
    let p00 = a0 * b0;
    let p01 = a0 * b1;
    let p10 = a1 * b0;
    let p11 = a1 * b1;
    let mid = (p00 >> 32) + (p01 & 0xFFFFFFFFu64) + (p10 & 0xFFFFFFFFu64);
    unsafe *hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
    return p00 & 0xFFFFFFFFu64 | mid << 32;
}

// ---------------------------------------------------------------------------------------------------------
// IntBits: the representation both signedness wrappers share
// ---------------------------------------------------------------------------------------------------------

/// The limb vector itself. Everything whose meaning does not depend on signedness lives here, so `UInt`
/// and `Int` share one implementation of it rather than one converting into the other at every call.
struct IntBits<const BITS: usize> {
    limbs: [u64; BITS / 64],
}

extend<const BITS: usize> IntBits<BITS> {
    // Limbs are reached through these two, which are the only places the raw array is touched: the index
    // is checked against the width at every entry point, and a bad width is refused before any of them.

    fn get(self: &IntBits<BITS>, i: usize) u64 {
        if i >= BITS / 64 {
            return 0; // reading past the top limb yields the zero extension, which is what callers mean
        }
        return unsafe self.limbs[i];
    }

    fn set(self: &mut IntBits<BITS>, i: usize, v: u64) {
        if i < BITS / 64 {
            unsafe self.limbs[i] = v;
        }
    }

    fn zero() IntBits<BITS> {
        static_assert(BITS >= 64, "an integer width must be at least 64 bits");
        static_assert(BITS % 64 == 0, "an integer width must be a whole number of 64-bit limbs");
        return IntBits::<BITS> {};
    }

    fn from_u64(v: u64) IntBits<BITS> {
        let mut r = IntBits::<BITS>::zero();
        r.set(0, v);
        return r;
    }

    fn is_zero(self: &IntBits<BITS>) bool {
        for i in 0..BITS / 64 {
            if self.get(i) != 0 {
                return false;
            }
        }
        return true;
    }

    /// Bit `i` counted from the least significant, 0 past the top.
    fn bit(self: &IntBits<BITS>, i: usize) u64 {
        if i >= BITS {
            return 0;
        }
        return self.get(i / 64) >> (i % 64) as u64 & 1u64;
    }

    fn set_bit(self: &mut IntBits<BITS>, i: usize, on: bool) {
        if i >= BITS {
            return;
        }
        let mask = 1u64 << (i % 64) as u64;
        let cur = self.get(i / 64);
        if on {
            self.set(i / 64, cur | mask);
        } else {
            self.set(i / 64, cur & ~mask);
        }
    }

    /// Index of the highest set bit, or -1 for zero. Drives division's iteration count.
    fn top_bit(self: &IntBits<BITS>) i64 {
        let mut i = BITS / 64;
        while i > 0 {
            i = i - 1;
            let l = self.get(i);
            if l != 0 {
                let mut b: usize = 64;
                while b > 0 {
                    b = b - 1;
                    if (l >> b as u64 & 1u64) != 0 {
                        return (i * 64 + b) as i64;
                    }
                }
            }
        }
        return -1;
    }

    // ---- addition and subtraction --------------------------------------------------------------
    // Identical at the bit level for both signednesses, which is the whole reason this type exists.
    // `carry` reports the carry OUT of the top limb: an unsigned overflow, and what signed overflow
    // detection is derived from.

    fn add_carry(self: &IntBits<BITS>, other: &IntBits<BITS>, carry_out: *mut u64) IntBits<BITS> {
        let mut r = IntBits::<BITS>::zero();
        let mut carry: u64 = 0;
        for i in 0..BITS / 64 {
            let a = self.get(i);
            let b = other.get(i);
            let s1 = a + b; // u64 addition wraps at the width, which is the carry test below
            let c1 = (s1 < a) as u64;
            let s2 = s1 + carry;
            let c2 = (s2 < s1) as u64;
            r.set(i, s2);
            carry = c1 | c2;
        }
        unsafe *carry_out = carry;
        return r;
    }

    fn sub_borrow(self: &IntBits<BITS>, other: &IntBits<BITS>, borrow_out: *mut u64) IntBits<BITS> {
        let mut r = IntBits::<BITS>::zero();
        let mut borrow: u64 = 0;
        for i in 0..BITS / 64 {
            let a = self.get(i);
            let b = other.get(i);
            let d1 = a - b;
            let b1 = (a < b) as u64;
            let d2 = d1 - borrow;
            let b2 = (d1 < borrow) as u64;
            r.set(i, d2);
            borrow = b1 | b2;
        }
        unsafe *borrow_out = borrow;
        return r;
    }

    /// Two's complement negation: `!self + 1`. Shared, and the reason signed subtraction needs no code
    /// of its own.
    fn negate(self: &IntBits<BITS>) IntBits<BITS> {
        let mut c: u64 = 0;
        let one = IntBits::<BITS>::from_u64(1);
        return self.bit_not().add_carry(&one, &mut c);
    }

    /// The low `BITS` of the full product -- what wrapping multiplication means, for either signedness.
    fn mul_wrap(self: &IntBits<BITS>, other: &IntBits<BITS>, overflow: *mut bool) IntBits<BITS> {
        let mut r = IntBits::<BITS>::zero();
        let n = BITS / 64;
        let mut over = false;
        for i in 0..n {
            let a = self.get(i);
            if a == 0 {
                continue;
            }
            let mut carry: u64 = 0;
            for j in 0..n {
                let b = other.get(j);
                if i + j >= n {
                    // A partial product past the top limb is a bit that cannot be represented.
                    if b != 0 && a != 0 {
                        over = true;
                    }
                    continue;
                }
                let mut hi: u64 = 0;
                let lo = mul_wide(a, b, &mut hi);
                let cur = r.get(i + j);
                let s1 = cur + lo;
                hi = hi + (s1 < cur) as u64;
                let s2 = s1 + carry;
                hi = hi + (s2 < s1) as u64;
                r.set(i + j, s2);
                carry = hi;
            }
            if carry != 0 {
                // Propagate the high half upwards; anything past the top is lost, hence overflow.
                let mut k = i + n;
                if k >= n {
                    over = true;
                } else {
                    while carry != 0 && k < n {
                        let cur = r.get(k);
                        let s = cur + carry;
                        carry = (s < cur) as u64;
                        r.set(k, s);
                        k = k + 1;
                    }
                    if carry != 0 {
                        over = true;
                    }
                }
            }
        }
        unsafe *overflow = over;
        return r;
    }

    /// The FULL product: the low half is returned, the high half stored through `hi_out`. Two N-bit
    /// values multiply to 2N bits, so nothing narrower than a second N-bit value holds what the low half
    /// loses -- a carry-out BIT would say only THAT it overflowed, which `checked_mul` already reports.
    fn mul_full(self: &IntBits<BITS>, other: &IntBits<BITS>, hi_out: *mut IntBits<BITS>) IntBits<BITS> {
        let n = BITS / 64;
        let mut lo = IntBits::<BITS>::zero();
        let mut hi = IntBits::<BITS>::zero();
        for i in 0..n {
            let a = self.get(i);
            if a == 0 {
                continue;
            }
            let mut carry: u64 = 0;
            for j in 0..n {
                let b = other.get(j);
                let mut h: u64 = 0;
                let l = mul_wide(a, b, &mut h);
                let k = i + j;
                let cur = if k < n {
                    lo.get(k);
                } else {
                    hi.get(k - n);
                };
                // a*b + cur + carry is at most 2^128 - 1, so neither carry can push `h` past a limb.
                let s1 = cur + l;
                h = h + (s1 < cur) as u64;
                let s2 = s1 + carry;
                h = h + (s2 < s1) as u64;
                if k < n {
                    lo.set(k, s2);
                } else {
                    hi.set(k - n, s2);
                }
                carry = h;
            }
            let mut k = i + n;
            while carry != 0 && k < n + n {
                let cur = hi.get(k - n);
                let s = cur + carry;
                carry = (s < cur) as u64;
                hi.set(k - n, s);
                k = k + 1;
            }
        }
        unsafe *hi_out = hi;
        return lo;
    }

    // ---- bitwise -------------------------------------------------------------------------------

    fn bit_and(self: &IntBits<BITS>, other: &IntBits<BITS>) IntBits<BITS> {
        let mut r = IntBits::<BITS>::zero();
        for i in 0..BITS / 64 {
            r.set(i, self.get(i) & other.get(i));
        }
        return r;
    }

    fn bit_or(self: &IntBits<BITS>, other: &IntBits<BITS>) IntBits<BITS> {
        let mut r = IntBits::<BITS>::zero();
        for i in 0..BITS / 64 {
            r.set(i, self.get(i) | other.get(i));
        }
        return r;
    }

    fn bit_xor(self: &IntBits<BITS>, other: &IntBits<BITS>) IntBits<BITS> {
        let mut r = IntBits::<BITS>::zero();
        for i in 0..BITS / 64 {
            r.set(i, self.get(i) ^ other.get(i));
        }
        return r;
    }

    fn bit_not(self: &IntBits<BITS>) IntBits<BITS> {
        let mut r = IntBits::<BITS>::zero();
        for i in 0..BITS / 64 {
            r.set(i, ~self.get(i));
        }
        return r;
    }

    /// Left shift; bits shifted past the top are discarded, as they are for the built-in types.
    fn shl(self: &IntBits<BITS>, amount: usize) IntBits<BITS> {
        let mut r = IntBits::<BITS>::zero();
        if amount >= BITS {
            return r;
        }
        let n = BITS / 64;
        let limb_shift = amount / 64;
        let bit_shift = amount % 64;
        let mut i = n;
        while i > 0 {
            i = i - 1;
            if i < limb_shift {
                break;
            }
            let src = i - limb_shift;
            let mut v = self.get(src) << bit_shift as u64;
            if bit_shift != 0 && src > 0 {
                v = v | self.get(src - 1) >> (64 - bit_shift) as u64;
            }
            r.set(i, v);
        }
        return r;
    }

    /// Logical right shift: zeros in at the top, whatever the sign bit says.
    fn shr_logical(self: &IntBits<BITS>, amount: usize) IntBits<BITS> {
        let mut r = IntBits::<BITS>::zero();
        if amount >= BITS {
            return r;
        }
        let n = BITS / 64;
        let limb_shift = amount / 64;
        let bit_shift = amount % 64;
        for i in 0..n {
            let src = i + limb_shift;
            if src >= n {
                break;
            }
            let mut v = self.get(src) >> bit_shift as u64;
            if bit_shift != 0 && src + 1 < n {
                v = v | self.get(src + 1) << (64 - bit_shift) as u64;
            }
            r.set(i, v);
        }
        return r;
    }

    /// Arithmetic right shift: the sign bit is what fills the top, so `-1 >> k` stays `-1`.
    fn shr_arith(self: &IntBits<BITS>, amount: usize) IntBits<BITS> {
        let neg = self.bit(BITS - 1) != 0;
        if !neg {
            return self.shr_logical(amount);
        }
        if amount >= BITS {
            return IntBits::<BITS>::zero().bit_not(); // all ones: the limit of shifting a negative value
        }
        let r = self.shr_logical(amount);
        // Put the sign back into everything the logical shift zeroed.
        let mut ones = IntBits::<BITS>::zero().bit_not();
        ones = ones.shl(BITS - amount);
        return r.bit_or(&ones);
    }

    // ---- unsigned comparison ------------------------------------------------------------------

    fn cmp_unsigned(self: &IntBits<BITS>, other: &IntBits<BITS>) i32 {
        let mut i = BITS / 64;
        while i > 0 {
            i = i - 1;
            let a = self.get(i);
            let b = other.get(i);
            if a < b {
                return -1;
            }
            if a > b {
                return 1;
            }
        }
        return 0;
    }

    fn eq_bits(self: &IntBits<BITS>, other: &IntBits<BITS>) bool {
        for i in 0..BITS / 64 {
            if self.get(i) != other.get(i) {
                return false;
            }
        }
        return true;
    }

    // ---- unsigned division ---------------------------------------------------------------------

    /// Shift-and-subtract long division, one bit per iteration from the dividend's highest set bit down.
    /// O(BITS) limb passes rather than Knuth's O(limbs^2) -- slower on very wide values, and small enough
    /// to be obviously correct, which is what a division routine most needs to be.
    fn divmod_unsigned(self: &IntBits<BITS>, divisor: &IntBits<BITS>, quot: *mut IntBits<BITS>, rem: *mut IntBits<BITS>) {
        if divisor.is_zero() {
            panic("integer division by zero");
        }
        let mut q = IntBits::<BITS>::zero();
        let mut r = IntBits::<BITS>::zero();
        let top = self.top_bit();
        let mut i = top;
        while i >= 0 {
            r = r.shl(1);
            r.set_bit(0, self.bit(i as usize) != 0);
            if r.cmp_unsigned(divisor) >= 0 {
                let mut b: u64 = 0;
                r = r.sub_borrow(divisor, &mut b);
                q.set_bit(i as usize, true);
            }
            i = i - 1;
        }
        unsafe *quot = q;
        unsafe *rem = r;
    }

    /// Divide by a value that fits in one limb, returning the remainder. The path decimal formatting and
    /// parsing take, where the divisor is 10 (or a power of it) and full division would be wasteful.
    fn divmod_small(self: &IntBits<BITS>, d: u64, quot: *mut IntBits<BITS>) u64 {
        if d == 0 {
            panic("integer division by zero");
        }
        let mut q = IntBits::<BITS>::zero();
        let mut rem: u64 = 0;
        let mut i = BITS / 64;
        while i > 0 {
            i = i - 1;
            let cur = self.get(i);
            // (rem : cur) / d, computed in two 32-bit halves so the intermediate never exceeds 64 bits.
            let hi = rem << 32 | cur >> 32;
            let qhi = hi / d;
            let rhi = hi % d;
            let lo = rhi << 32 | cur & 0xFFFFFFFFu64;
            let qlo = lo / d;
            rem = lo % d;
            q.set(i, qhi << 32 | qlo);
        }
        unsafe *quot = q;
        return rem;
    }
}

// ---------------------------------------------------------------------------------------------------------
// UInt<BITS>: the unsigned view
// ---------------------------------------------------------------------------------------------------------

/// An unsigned integer `BITS` wide. Arithmetic WRAPS at the width, exactly as the built-in unsigned types
/// do; `checked_*` and `saturating_*` give the other answers.
pub struct UInt<const BITS: usize> {
    bits: IntBits<BITS>,
}

extend<const BITS: usize> UInt<BITS> {
    /// The width in bits, bytes and 64-bit limbs. Compile-time constants: each is a `const fn` over the
    /// type's own generic argument, so a call folds to a literal in the emitted C.
    pub const fn bits() usize {
        return BITS;
    }

    pub const fn bytes() usize {
        return BITS / 8;
    }

    pub const fn limbs() usize {
        return BITS / 64;
    }

    // The only places `bits` is named from outside this type's own methods: a wrapper's field belongs
    // to that wrapper, so the signed view goes through these rather than reaching into the unsigned one.
    fn from_bits(b: IntBits<BITS>) UInt<BITS> {
        return UInt::<BITS> { bits: b };
    }

    fn raw(self: &UInt<BITS>) IntBits<BITS> {
        return self.bits;
    }

    pub fn zero() UInt<BITS> {
        return UInt::<BITS> { bits: IntBits::<BITS>::zero() };
    }

    pub fn one() UInt<BITS> {
        return UInt::<BITS> { bits: IntBits::<BITS>::from_u64(1) };
    }

    /// The largest value: every bit set.
    pub fn max() UInt<BITS> {
        return UInt::<BITS> { bits: IntBits::<BITS>::zero().bit_not() };
    }

    pub fn min() UInt<BITS> {
        return UInt::<BITS>::zero();
    }

    pub fn from_u64(v: u64) UInt<BITS> {
        return UInt::<BITS> { bits: IntBits::<BITS>::from_u64(v) };
    }

    /// The low 64 bits, discarding the rest -- the `as u64` of a wide value.
    pub fn to_u64(self: &UInt<BITS>) u64 {
        return self.bits.get(0);
    }

    /// Limb `i`, least significant first; 0 past the top.
    pub fn limb(self: &UInt<BITS>, i: usize) u64 {
        return self.bits.get(i);
    }

    pub fn set_limb(self: &mut UInt<BITS>, i: usize, v: u64) {
        self.bits.set(i, v);
    }

    pub fn is_zero(self: &UInt<BITS>) bool {
        return self.bits.is_zero();
    }

    pub fn bit(self: &UInt<BITS>, i: usize) bool {
        return self.bits.bit(i) != 0;
    }

    /// Bits needed to represent the value: 0 for zero, otherwise one past the highest set bit.
    pub fn bit_length(self: &UInt<BITS>) usize {
        return (self.bits.top_bit() + 1) as usize;
    }

    pub fn leading_zeros(self: &UInt<BITS>) usize {
        return BITS - self.bit_length();
    }

    pub fn count_ones(self: &UInt<BITS>) usize {
        let mut n: usize = 0;
        for i in 0..BITS / 64 {
            let mut l = self.bits.get(i);
            while l != 0 {
                n = n + (l & 1u64) as usize;
                l = l >> 1;
            }
        }
        return n;
    }

    // ---- wrapping ------------------------------------------------------------------------------

    pub fn wrapping_add(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        let mut c: u64 = 0;
        return UInt::<BITS> { bits: self.bits.add_carry(&other.bits, &mut c) };
    }

    pub fn wrapping_sub(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        let mut b: u64 = 0;
        return UInt::<BITS> { bits: self.bits.sub_borrow(&other.bits, &mut b) };
    }

    pub fn wrapping_mul(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        let mut o = false;
        return UInt::<BITS> { bits: self.bits.mul_wrap(&other.bits, &mut o) };
    }

    pub fn wrapping_neg(self: &UInt<BITS>) UInt<BITS> {
        return UInt::<BITS> { bits: self.bits.negate() };
    }

    /// The low and high halves of the full product: `hi` receives the top `BITS`, the low ones are
    /// returned. Nothing is lost, and no wider type has to exist for it.
    pub fn widening_mul(self: &UInt<BITS>, other: &UInt<BITS>, hi: *mut UInt<BITS>) UInt<BITS> {
        let mut h = IntBits::<BITS>::zero();
        let lo = self.bits.mul_full(&other.bits, &mut h);
        unsafe *hi = UInt::<BITS>::from_bits(h);
        return UInt::<BITS>::from_bits(lo);
    }

    /// The same full product as ONE value twice as wide. `{BITS * 2}` is a const-generic EXPRESSION: the
    /// result's width is computed from the receiver's when the call is monomorphized. The wider type is
    /// instantiated because this call asks for it, not because the method exists -- otherwise every width
    /// would demand the next one without end.
    pub fn full_mul(self: &UInt<BITS>, other: &UInt<BITS>) UInt<{BITS * 2}> {
        let mut hi = UInt::<BITS>::zero();
        let lo = self.widening_mul(other, &mut hi);
        let mut r = UInt::<{BITS * 2}>::zero();
        for i in 0..BITS / 64 {
            r.set_limb(i, lo.limb(i));
            r.set_limb(i + BITS / 64, hi.limb(i));
        }
        return r;
    }

    // ---- checked -------------------------------------------------------------------------------

    pub fn checked_add(self: &UInt<BITS>, other: &UInt<BITS>) Option<UInt<BITS>> {
        let mut c: u64 = 0;
        let r = UInt::<BITS> { bits: self.bits.add_carry(&other.bits, &mut c) };
        if c != 0 {
            return Option::<UInt<BITS>>::None;
        }
        return Option::<UInt<BITS>>::Some(r);
    }

    pub fn checked_sub(self: &UInt<BITS>, other: &UInt<BITS>) Option<UInt<BITS>> {
        let mut b: u64 = 0;
        let r = UInt::<BITS> { bits: self.bits.sub_borrow(&other.bits, &mut b) };
        if b != 0 {
            return Option::<UInt<BITS>>::None;
        }
        return Option::<UInt<BITS>>::Some(r);
    }

    pub fn checked_mul(self: &UInt<BITS>, other: &UInt<BITS>) Option<UInt<BITS>> {
        let mut o = false;
        let r = UInt::<BITS> { bits: self.bits.mul_wrap(&other.bits, &mut o) };
        if o {
            return Option::<UInt<BITS>>::None;
        }
        return Option::<UInt<BITS>>::Some(r);
    }

    // ---- saturating ----------------------------------------------------------------------------

    pub fn saturating_add(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        switch self.checked_add(other) {
            Some(v) => {
                return v;
            },
            None => {
                return UInt::<BITS>::max();
            },
        };
    }

    pub fn saturating_sub(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        switch self.checked_sub(other) {
            Some(v) => {
                return v;
            },
            None => {
                return UInt::<BITS>::zero();
            },
        };
    }

    pub fn saturating_mul(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        switch self.checked_mul(other) {
            Some(v) => {
                return v;
            },
            None => {
                return UInt::<BITS>::max();
            },
        };
    }

    // ---- division ------------------------------------------------------------------------------

    /// Quotient and remainder in one pass -- the division routine runs once, which `div` and `rem`
    /// separately would not.
    pub fn divmod(self: &UInt<BITS>, other: &UInt<BITS>, rem: *mut UInt<BITS>) UInt<BITS> {
        let mut q = IntBits::<BITS>::zero();
        let mut r = IntBits::<BITS>::zero();
        self.bits.divmod_unsigned(&other.bits, &mut q, &mut r);
        unsafe *rem = UInt::<BITS> { bits: r };
        return UInt::<BITS> { bits: q };
    }

    pub fn checked_div(self: &UInt<BITS>, other: &UInt<BITS>) Option<UInt<BITS>> {
        if other.is_zero() {
            return Option::<UInt<BITS>>::None;
        }
        let mut r = UInt::<BITS>::zero();
        return Option::<UInt<BITS>>::Some(self.divmod(other, &mut r));
    }

    // ---- bitwise -------------------------------------------------------------------------------

    pub fn bit_and(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        return UInt::<BITS> { bits: self.bits.bit_and(&other.bits) };
    }

    pub fn bit_or(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        return UInt::<BITS> { bits: self.bits.bit_or(&other.bits) };
    }

    pub fn bit_xor(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        return UInt::<BITS> { bits: self.bits.bit_xor(&other.bits) };
    }

    pub fn bit_not(self: &UInt<BITS>) UInt<BITS> {
        return UInt::<BITS> { bits: self.bits.bit_not() };
    }

    pub fn shl(self: &UInt<BITS>, amount: usize) UInt<BITS> {
        return UInt::<BITS> { bits: self.bits.shl(amount) };
    }

    /// Logical right shift -- the only kind an unsigned value has.
    pub fn shr(self: &UInt<BITS>, amount: usize) UInt<BITS> {
        return UInt::<BITS> { bits: self.bits.shr_logical(amount) };
    }

    // ---- text ----------------------------------------------------------------------------------

    /// Decimal digits. Repeated division by a single limb, which is the cheap path through the divider.
    pub fn to_string(self: &UInt<BITS>) String {
        let mut out = String::new();
        if self.is_zero() {
            out.push_byte(b'0');
            return out;
        }
        let mut digits = String::new();
        let mut cur = self.bits;
        while !cur.is_zero() {
            let mut q = IntBits::<BITS>::zero();
            let d = cur.divmod_small(10, &mut q);
            digits.push_byte(b'0' + d as u8);
            cur = q;
        }
        let mut i = digits.len();
        while i > 0 {
            i = i - 1;
            out.push_byte(digits.as_str().byte_at(i));
        }
        digits.free();
        return out;
    }

    /// Parse decimal digits. `None` on an empty string, a non-digit, or a value too wide to represent.
    pub fn from_str(s: str) Option<UInt<BITS>> {
        if s.len() == 0 {
            return Option::<UInt<BITS>>::None;
        }
        let mut acc = UInt::<BITS>::zero();
        let ten = UInt::<BITS>::from_u64(10);
        for i in 0..s.len() {
            let ch = s.byte_at(i);
            if ch < b'0' || ch > b'9' {
                return Option::<UInt<BITS>>::None;
            }
            switch acc.checked_mul(&ten) {
                Some(m) => {
                    let d = UInt::<BITS>::from_u64(ch - b'0');
                    switch m.checked_add(&d) {
                        Some(v) => {
                            acc = v;
                        },
                        None => {
                            return Option::<UInt<BITS>>::None;
                        },
                    };
                },
                None => {
                    return Option::<UInt<BITS>>::None;
                },
            };
        }
        return Option::<UInt<BITS>>::Some(acc);
    }
}

// Operators. `+`, `-` and `*` WRAP, which is what the built-in unsigned types do; `/` and `%` panic on a
// zero divisor, as they do.
extend<const BITS: usize> UInt<BITS> as Add {
    pub fn add(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        return self.wrapping_add(other);
    }
}

extend<const BITS: usize> UInt<BITS> as Sub {
    pub fn sub(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        return self.wrapping_sub(other);
    }
}

extend<const BITS: usize> UInt<BITS> as Mul {
    pub fn mul(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        return self.wrapping_mul(other);
    }
}

extend<const BITS: usize> UInt<BITS> as Div {
    pub fn div(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        let mut r = UInt::<BITS>::zero();
        return self.divmod(other, &mut r);
    }
}

extend<const BITS: usize> UInt<BITS> as Rem {
    pub fn rem(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        let mut r = UInt::<BITS>::zero();
        let _ = self.divmod(other, &mut r);
        return r;
    }
}

extend<const BITS: usize> UInt<BITS> as Eq {
    pub fn eq(self: &UInt<BITS>, other: &UInt<BITS>) bool {
        return self.bits.eq_bits(&other.bits);
    }
}

extend<const BITS: usize> UInt<BITS> as Ord {
    pub fn cmp(self: &UInt<BITS>, other: &UInt<BITS>) i32 {
        return self.bits.cmp_unsigned(&other.bits);
    }
}

extend<const BITS: usize> UInt<BITS> as Hash {
    pub fn hash(self: &UInt<BITS>) u64 {
        let mut h: u64 = 0xcbf29ce484222325;
        for i in 0..BITS / 64 {
            h = (h ^ self.bits.get(i)) * 1099511628211u64;
        }
        return h;
    }
}

extend<const BITS: usize> UInt<BITS> as Default {
    pub fn default() UInt<BITS> {
        return UInt::<BITS>::zero();
    }
}

extend<const BITS: usize> UInt<BITS> as Clone {
    pub fn clone(self: &UInt<BITS>) UInt<BITS> {
        return *self;
    }
}

extend<const BITS: usize> UInt<BITS> as Format {
    pub fn fmt(self: &UInt<BITS>) String {
        return self.to_string();
    }
}

// ---------------------------------------------------------------------------------------------------------
// Int<BITS>: the signed view
// ---------------------------------------------------------------------------------------------------------

/// A two's-complement signed integer `BITS` wide. Arithmetic TRAPS on overflow, exactly as the built-in
/// signed types do; `wrapping_*`, `checked_*` and `saturating_*` give the other answers.
pub struct Int<const BITS: usize> {
    bits: IntBits<BITS>,
}

extend<const BITS: usize> Int<BITS> {
    pub const fn bits() usize {
        return BITS;
    }

    pub const fn bytes() usize {
        return BITS / 8;
    }

    pub const fn limbs() usize {
        return BITS / 64;
    }

    fn from_bits(b: IntBits<BITS>) Int<BITS> {
        return Int::<BITS> { bits: b };
    }

    pub fn zero() Int<BITS> {
        return Int::<BITS> { bits: IntBits::<BITS>::zero() };
    }

    pub fn one() Int<BITS> {
        return Int::<BITS> { bits: IntBits::<BITS>::from_u64(1) };
    }

    /// The most negative value: the sign bit alone. Its magnitude has no positive counterpart, which is
    /// what makes `MIN.abs()` and `MIN / -1` overflow.
    pub fn min() Int<BITS> {
        let mut b = IntBits::<BITS>::zero();
        b.set_bit(BITS - 1, true);
        return Int::<BITS> { bits: b };
    }

    pub fn max() Int<BITS> {
        return Int::<BITS> { bits: IntBits::<BITS>::zero().bit_not().shr_logical(1) };
    }

    /// Sign-extended from a 64-bit value, so a negative one stays negative at any width.
    pub fn from_i64(v: i64) Int<BITS> {
        let mut b = IntBits::<BITS>::from_u64(v as u64);
        if v < 0 {
            for i in 1..BITS / 64 {
                b.set(i, 0xFFFFFFFFFFFFFFFF);
            }
        }
        return Int::<BITS> { bits: b };
    }

    /// The low 64 bits as a signed value, discarding the rest.
    pub fn to_i64(self: &Int<BITS>) i64 {
        return self.bits.get(0) as i64;
    }

    pub fn limb(self: &Int<BITS>, i: usize) u64 {
        return self.bits.get(i);
    }

    pub fn set_limb(self: &mut Int<BITS>, i: usize, v: u64) {
        self.bits.set(i, v);
    }

    pub fn is_zero(self: &Int<BITS>) bool {
        return self.bits.is_zero();
    }

    /// The sign bit -- the top bit of the top limb.
    pub fn is_negative(self: &Int<BITS>) bool {
        return self.bits.bit(BITS - 1) != 0;
    }

    pub fn bit(self: &Int<BITS>, i: usize) bool {
        return self.bits.bit(i) != 0;
    }

    /// The same bits read as unsigned: a negative value becomes its two's-complement magnitude.
    pub fn to_unsigned(self: &Int<BITS>) UInt<BITS> {
        return UInt::<BITS>::from_bits(self.bits);
    }

    pub fn from_unsigned(v: &UInt<BITS>) Int<BITS> {
        return Int::<BITS>::from_bits(v.raw());
    }

    // ---- wrapping ------------------------------------------------------------------------------
    // The limb code is the unsigned one: two's complement makes these bit-identical.

    pub fn wrapping_add(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        let mut c: u64 = 0;
        return Int::<BITS> { bits: self.bits.add_carry(&other.bits, &mut c) };
    }

    pub fn wrapping_sub(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        let mut b: u64 = 0;
        return Int::<BITS> { bits: self.bits.sub_borrow(&other.bits, &mut b) };
    }

    pub fn wrapping_mul(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        let mut o = false;
        return Int::<BITS> { bits: self.bits.mul_wrap(&other.bits, &mut o) };
    }

    pub fn wrapping_neg(self: &Int<BITS>) Int<BITS> {
        return Int::<BITS> { bits: self.bits.negate() };
    }

    // ---- checked -------------------------------------------------------------------------------

    /// Signed addition overflows exactly when both operands share a sign and the result does not.
    pub fn checked_add(self: &Int<BITS>, other: &Int<BITS>) Option<Int<BITS>> {
        let r = self.wrapping_add(other);
        let sa = self.is_negative();
        let sb = other.is_negative();
        if sa == sb && r.is_negative() != sa {
            return Option::<Int<BITS>>::None;
        }
        return Option::<Int<BITS>>::Some(r);
    }

    /// And subtraction exactly when the operands' signs differ and the result does not match the first.
    pub fn checked_sub(self: &Int<BITS>, other: &Int<BITS>) Option<Int<BITS>> {
        let r = self.wrapping_sub(other);
        let sa = self.is_negative();
        let sb = other.is_negative();
        if sa != sb && r.is_negative() != sa {
            return Option::<Int<BITS>>::None;
        }
        return Option::<Int<BITS>>::Some(r);
    }

    pub fn checked_neg(self: &Int<BITS>) Option<Int<BITS>> {
        let mn = Int::<BITS>::min();
        if self.eq(&mn) {
            return Option::<Int<BITS>>::None; // MIN has no positive counterpart
        }
        return Option::<Int<BITS>>::Some(self.wrapping_neg());
    }

    /// Checked by dividing back out: the product is representable exactly when recovering one operand
    /// from it succeeds.
    pub fn checked_mul(self: &Int<BITS>, other: &Int<BITS>) Option<Int<BITS>> {
        if self.is_zero() || other.is_zero() {
            return Option::<Int<BITS>>::Some(Int::<BITS>::zero());
        }
        let mn = Int::<BITS>::min();
        let neg1 = Int::<BITS>::from_i64(-1);
        if self.eq(&mn) && other.eq(&neg1) || other.eq(&mn) && self.eq(&neg1) {
            return Option::<Int<BITS>>::None;
        }
        let r = self.wrapping_mul(other);
        let mut rem = Int::<BITS>::zero();
        let back = r.divmod(other, &mut rem);
        if !back.eq(self) || !rem.is_zero() {
            return Option::<Int<BITS>>::None;
        }
        return Option::<Int<BITS>>::Some(r);
    }

    // ---- saturating ----------------------------------------------------------------------------

    pub fn saturating_add(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        switch self.checked_add(other) {
            Some(v) => {
                return v;
            },
            None => {
                if self.is_negative() {
                    return Int::<BITS>::min();
                }
                return Int::<BITS>::max();
            },
        };
    }

    pub fn saturating_sub(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        switch self.checked_sub(other) {
            Some(v) => {
                return v;
            },
            None => {
                if self.is_negative() {
                    return Int::<BITS>::min();
                }
                return Int::<BITS>::max();
            },
        };
    }

    pub fn saturating_mul(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        switch self.checked_mul(other) {
            Some(v) => {
                return v;
            },
            None => {
                if self.is_negative() != other.is_negative() {
                    return Int::<BITS>::min();
                }
                return Int::<BITS>::max();
            },
        };
    }

    /// Magnitude. Panics on MIN, whose magnitude is one past the top of the range.
    pub fn abs(self: &Int<BITS>) Int<BITS> {
        if !self.is_negative() {
            return *self;
        }
        switch self.checked_neg() {
            Some(v) => {
                return v;
            },
            None => {
                panic("Int::abs: no positive counterpart for the minimum value");
            },
        };
    }

    // ---- division ------------------------------------------------------------------------------

    /// Truncating division, with the remainder taking the DIVIDEND's sign -- C's rule, and the built-in
    /// signed types'. Panics on a zero divisor, and on MIN / -1, whose quotient is out of range.
    pub fn divmod(self: &Int<BITS>, other: &Int<BITS>, rem: *mut Int<BITS>) Int<BITS> {
        if other.is_zero() {
            panic("integer division by zero");
        }
        let mn = Int::<BITS>::min();
        let neg1 = Int::<BITS>::from_i64(-1);
        if self.eq(&mn) && other.eq(&neg1) {
            panic("integer overflow: MIN divided by -1");
        }
        let neg_a = self.is_negative();
        let neg_b = other.is_negative();
        let ua = if neg_a {
            self.wrapping_neg().to_unsigned();
        } else {
            self.to_unsigned();
        };
        let ub = if neg_b {
            other.wrapping_neg().to_unsigned();
        } else {
            other.to_unsigned();
        };
        let mut ur = UInt::<BITS>::zero();
        let uq = ua.divmod(&ub, &mut ur);
        let mut q = Int::<BITS>::from_unsigned(&uq);
        let mut r = Int::<BITS>::from_unsigned(&ur);
        if neg_a != neg_b {
            q = q.wrapping_neg();
        }
        if neg_a {
            r = r.wrapping_neg();
        }
        unsafe *rem = r;
        return q;
    }

    pub fn checked_div(self: &Int<BITS>, other: &Int<BITS>) Option<Int<BITS>> {
        let mn = Int::<BITS>::min();
        let neg1 = Int::<BITS>::from_i64(-1);
        if other.is_zero() || self.eq(&mn) && other.eq(&neg1) {
            return Option::<Int<BITS>>::None;
        }
        let mut r = Int::<BITS>::zero();
        return Option::<Int<BITS>>::Some(self.divmod(other, &mut r));
    }

    // ---- bitwise -------------------------------------------------------------------------------

    pub fn bit_and(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        return Int::<BITS> { bits: self.bits.bit_and(&other.bits) };
    }

    pub fn bit_or(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        return Int::<BITS> { bits: self.bits.bit_or(&other.bits) };
    }

    pub fn bit_xor(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        return Int::<BITS> { bits: self.bits.bit_xor(&other.bits) };
    }

    pub fn bit_not(self: &Int<BITS>) Int<BITS> {
        return Int::<BITS> { bits: self.bits.bit_not() };
    }

    pub fn shl(self: &Int<BITS>, amount: usize) Int<BITS> {
        return Int::<BITS> { bits: self.bits.shl(amount) };
    }

    /// Arithmetic right shift: the sign is what fills the top, so shifting a negative value keeps it
    /// negative and rounds toward negative infinity.
    pub fn shr(self: &Int<BITS>, amount: usize) Int<BITS> {
        return Int::<BITS> { bits: self.bits.shr_arith(amount) };
    }

    // ---- text ----------------------------------------------------------------------------------

    pub fn to_string(self: &Int<BITS>) String {
        if !self.is_negative() {
            return self.to_unsigned().to_string();
        }
        // The magnitude through the unsigned view: negating MIN wraps back to MIN, whose unsigned
        // reading is exactly the magnitude wanted, so this needs no case of its own.
        let mag = self.wrapping_neg().to_unsigned();
        let mut out = String::from_str("-");
        let digits = mag.to_string();
        out.push_str(digits.as_str());
        digits.free();
        return out;
    }

    /// Parse an optionally signed decimal. `None` on anything else, or on a value out of range.
    pub fn from_str(s: str) Option<Int<BITS>> {
        if s.len() == 0 {
            return Option::<Int<BITS>>::None;
        }
        let neg = s.byte_at(0) == b'-';
        let body = if neg || s.byte_at(0) == b'+' {
            s.slice(1, s.len());
        } else {
            s;
        };
        switch UInt::<BITS>::from_str(body) {
            Some(u) => {
                let v = Int::<BITS>::from_unsigned(&u);
                if neg {
                    // A magnitude of exactly MIN's is the one negative value with no positive form.
                    let mn = Int::<BITS>::min();
                    if v.is_negative() && !v.eq(&mn) {
                        return Option::<Int<BITS>>::None;
                    }
                    return Option::<Int<BITS>>::Some(v.wrapping_neg());
                }
                if v.is_negative() {
                    return Option::<Int<BITS>>::None; // the magnitude overflowed into the sign bit
                }
                return Option::<Int<BITS>>::Some(v);
            },
            None => {
                return Option::<Int<BITS>>::None;
            },
        };
    }
}

// Operators. `+`, `-`, `*`, `/` and `%` TRAP on overflow, which is what the built-in signed types do.
extend<const BITS: usize> Int<BITS> as Add {
    pub fn add(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        switch self.checked_add(other) {
            Some(v) => {
                return v;
            },
            None => {
                panic("arithmetic overflow");
            },
        };
    }
}

extend<const BITS: usize> Int<BITS> as Sub {
    pub fn sub(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        switch self.checked_sub(other) {
            Some(v) => {
                return v;
            },
            None => {
                panic("arithmetic overflow");
            },
        };
    }
}

extend<const BITS: usize> Int<BITS> as Mul {
    pub fn mul(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        switch self.checked_mul(other) {
            Some(v) => {
                return v;
            },
            None => {
                panic("arithmetic overflow");
            },
        };
    }
}

extend<const BITS: usize> Int<BITS> as Div {
    pub fn div(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        let mut r = Int::<BITS>::zero();
        return self.divmod(other, &mut r);
    }
}

extend<const BITS: usize> Int<BITS> as Rem {
    pub fn rem(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        let mut r = Int::<BITS>::zero();
        let _ = self.divmod(other, &mut r);
        return r;
    }
}

extend<const BITS: usize> Int<BITS> as Eq {
    pub fn eq(self: &Int<BITS>, other: &Int<BITS>) bool {
        return self.bits.eq_bits(&other.bits);
    }
}

extend<const BITS: usize> Int<BITS> as Ord {
    /// Signed order: a negative value is below every non-negative one, and two of the same sign compare
    /// by their bits.
    pub fn cmp(self: &Int<BITS>, other: &Int<BITS>) i32 {
        let sa = self.is_negative();
        let sb = other.is_negative();
        if sa != sb {
            if sa {
                return -1;
            }
            return 1;
        }
        return self.bits.cmp_unsigned(&other.bits);
    }
}

extend<const BITS: usize> Int<BITS> as Hash {
    pub fn hash(self: &Int<BITS>) u64 {
        let mut h: u64 = 0xcbf29ce484222325;
        for i in 0..BITS / 64 {
            h = (h ^ self.bits.get(i)) * 1099511628211u64;
        }
        return h;
    }
}

extend<const BITS: usize> Int<BITS> as Default {
    pub fn default() Int<BITS> {
        return Int::<BITS>::zero();
    }
}

extend<const BITS: usize> Int<BITS> as Clone {
    pub fn clone(self: &Int<BITS>) Int<BITS> {
        return *self;
    }
}

extend<const BITS: usize> Int<BITS> as Format {
    pub fn fmt(self: &Int<BITS>) String {
        return self.to_string();
    }
}

// ---------------------------------------------------------------------------------------------------------
// the named widths
// ---------------------------------------------------------------------------------------------------------
// `UInt<BITS>` accepts any whole number of limbs; these are the widths worth a name of their own, and they
// read like the built-in types they extend.

pub type u128 = UInt<128>;
pub type u256 = UInt<256>;
pub type u512 = UInt<512>;
pub type u1024 = UInt<1024>;

pub type i128 = Int<128>;
pub type i256 = Int<256>;
pub type i512 = Int<512>;
pub type i1024 = Int<1024>;
