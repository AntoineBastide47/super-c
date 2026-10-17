// Fixed-width integers of any size: `UInt<BITS>` and `Int<BITS>`, monomorphized per width, with the
// aliases `u128`/`u256`/`u512`/`u1024` and `i128`/`i256`/`i512`/`i1024` on top. A top-level std file, so
// the aliases resolve unqualified everywhere and these read like the built-in integers: `let a: u128 = 42`
// converts the literal through the `From` conformances below, exactly as a narrower built-in widens.
//
// The generic argument is the BIT width, not a limb count: `UInt<256>` says what it is at every use site
// and in every diagnostic, and the storage `[u64; (BITS + 63) / 64]` follows from it. ANY positive width
// works, 64-multiple or not: the top limb's unused bits stay zero, an invariant `set` enforces at the one
// place limbs are written, so every operation wraps at exactly BITS.
//
// Storage is `u64` limbs, LEAST SIGNIFICANT FIRST, for signed values too. A signed value is two's
// complement over the whole width, so `Int<256>` is exactly `UInt<256>`'s bit pattern read differently:
// addition, subtraction, multiplication, the bitwise operations and left shift are the SAME limb code for
// both, and only ordering, division, remainder, right shift, overflow detection and formatting differ.
// Signed limbs would put C's undefined signed overflow and implementation-defined signed shifts underneath
// all of that; unsigned limbs make every step defined and portable.
//
// Overflow in `+`, `-`, `*` and `pow` (and `Int`'s `abs`) follows the build profile, as in the built-in
// integers: it traps with overflow checks and wraps without (`sc_int_overflow` in int128.h decides).
// Division by zero and MIN / -1 panic either way. `wrapping_*`, `checked_*`, `overflowing_*` and
// `saturating_*` give the other answers in every profile.
//
// The 128-bit width additionally routes addition, subtraction, multiplication and division through the
// C compiler's native 128-bit integer type where one exists (the `sc_i128_*` helpers in `int128.h`,
// shipped next to this file); targets without one, and every other width, run the limb code. Identical
// results either way: the two paths are pinned against each other in the tests.
//
// Both are plain values: no heap, no allocator, no `Free`. They copy like the built-in integers do.

// 64x64 -> 128 multiply.

// The full product of two limbs: the low half is returned, the high half stored through `hi`. The C
// compiler's 128-bit type where it has one (one multiply instruction pair); else 32-bit halves, each
// partial product at most (2^32-1)^2, which a u64 holds exactly. Compile time runs the halves.
fn mul_wide(a: u64, b: u64, hi: *mut u64) u64 {
    if use_i128() {
        return unsafe sc_mul64(a, b, hi);
    }
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

// The native 128-bit fast path.

// Whether the C compiler building the emitted code has a native 128-bit integer type is knowable only
// THERE, so the choice is made there: `sc_has_i128()` (int128.h, shipped next to this file) folds to a
// constant, a `BITS == 128 && use_i128()` branch keeps exactly one side, and on targets without the
// type the helpers below are never-reached stubs. Limbs pass as explicit 64-bit halves, least
// significant first.
extern "C" "int128.h" {
    fn sc_has_i128() i32;
    fn sc_i128_add(al: u64, ah: u64, bl: u64, bh: u64, rl: *mut u64, rh: *mut u64, carry: *mut u64) void;
    fn sc_i128_sub(al: u64, ah: u64, bl: u64, bh: u64, rl: *mut u64, rh: *mut u64, borrow: *mut u64) void;
    fn sc_i128_mul(al: u64, ah: u64, bl: u64, bh: u64, rl: *mut u64, rh: *mut u64, hl: *mut u64, hh: *mut u64) void;
    fn sc_i128_divmod(al: u64, ah: u64, bl: u64, bh: u64, ql: *mut u64, qh: *mut u64, rl: *mut u64, rh: *mut u64) void;
    fn sc_mul64(a: u64, b: u64, hi: *mut u64) u64;
    fn sc_div128by64(u1: u64, u0: u64, v: u64, r: *mut u64) u64;
}

// The reciprocal of a normalized limb d (its top bit set): floor((2^128 - 1) / d) - 2^64, for
// `div2by1_pre` (Moller and Granlund, "Improved division by invariant integers", IEEE TC 2011, Algorithm 2's
// value, here by one 2-by-1 division).
fn reciprocal(d: u64) u64 {
    let mut r: u64 = 0;
    return div2by1(~d, 0xFFFFFFFFFFFFFFFF, d, &mut r);
}

// (u1 : u0) / d for a normalized d and u1 < d, by the reciprocal `v` of d: one full and one low
// multiplication and at most two corrections (Moller and Granlund, Algorithm 4); the remainder through `r`.
fn div2by1_pre(u1: u64, u0: u64, d: u64, v: u64, r: *mut u64) u64 {
    let mut q1: u64 = 0;
    let q0 = mul_wide(v, u1, &mut q1);
    let s0 = q0.wrapping_add(u0);
    q1 = q1.wrapping_add(u1).wrapping_add((s0 < q0) as u64).wrapping_add(1);
    let mut rem = u0.wrapping_sub(q1.wrapping_mul(d));
    if rem > s0 {
        q1 = q1.wrapping_sub(1);
        rem = rem.wrapping_add(d);
    }
    if rem >= d {
        q1 = q1 + 1;
        rem = rem - d;
    }
    unsafe *r = rem;
    return q1;
}

// (u1 : u0) / v for u1 < v, the remainder stored through `r`: the quotient fits one limb. The C
// compiler's 128-bit division where it has the type; else Hacker's Delight's `divlu`: the divisor
// normalized, two 32-bit quotient digits, each estimate corrected at most twice.
fn div2by1(u1: u64, u0: u64, v: u64, r: *mut u64) u64 {
    if use_i128() {
        return unsafe sc_div128by64(u1, u0, v, r);
    }
    let b: u64 = 1u64 << 32;
    let s = v.leading_zeros() as u64;
    let vn = v << s;
    let vn1 = vn >> 32;
    let vn0 = vn & 0xFFFFFFFFu64;
    let un32 = if s == 0 {
        u1;
    } else {
        u1 << s | u0 >> 64 - s;
    };
    let un10 = u0 << s;
    let un1 = un10 >> 32;
    let un0 = un10 & 0xFFFFFFFFu64;
    let mut q1 = un32 / vn1;
    let mut rhat = un32 - q1 * vn1;
    while q1 >= b || q1 * vn0 > (rhat << 32 | un1) {
        q1 = q1 - 1;
        rhat = rhat + vn1;
        if rhat >= b {
            break;
        }
    }
    let un21 = (un32 << 32 | un1).wrapping_sub(q1.wrapping_mul(vn));
    let mut q0 = un21 / vn1;
    rhat = un21 - q0 * vn1;
    while q0 >= b || q0 * vn0 > (rhat << 32 | un0) {
        q0 = q0 - 1;
        rhat = rhat + vn1;
        if rhat >= b {
            break;
        }
    }
    unsafe *r = (un21 << 32 | un0).wrapping_sub(q0.wrapping_mul(vn)) >> s;
    return q1 << 32 | q0;
}

const fn use_i128() bool {
    return unsafe sc_has_i128() != 0;
}

// The 8 bytes of `x` in reverse order: halves swapped, then quarters, then bytes.
const fn bswap64(x: u64) u64 {
    let mut v = x << 32 | x >> 32;
    v = (v & 0x0000FFFF0000FFFF) << 16 | v >> 16 & 0x0000FFFF0000FFFF;
    return (v & 0x00FF00FF00FF00FF) << 8 | v >> 8 & 0x00FF00FF00FF00FF;
}

// The 64 bits of `x` in reverse order: bytes reversed, then nibbles, pairs and bits within each.
const fn rev64(x: u64) u64 {
    let mut v = bswap64(x);
    v = (v & 0x0F0F0F0F0F0F0F0F) << 4 | v >> 4 & 0x0F0F0F0F0F0F0F0F;
    v = (v & 0x3333333333333333) << 2 | v >> 2 & 0x3333333333333333;
    return (v & 0x5555555555555555) << 1 | v >> 1 & 0x5555555555555555;
}

// Overflow in the `UInt` and `Int` operators (int128.h): the built-in trap with message `msg`, or a
// return when the build wraps, and the operator then yields the wrapped value. A zero divisor and MIN / -1 trap
// in every profile, as the built-in `/` and `%` do.
extern "C" "int128.h" {
    fn sc_int_overflow(msg: *const u8) void;
    fn sc_int_div_zero(msg: *const u8) void;
    fn sc_int_div_overflow(msg: *const u8) void;
}

// IntBits: the representation both signedness wrappers share.

// The limb vector itself. Everything whose meaning does not depend on signedness lives here, so `UInt`
// and `Int` share one implementation of it rather than one converting into the other at every call.
struct IntBits<const BITS: usize> {
    limbs: [u64; (BITS + 63) / 64],
}

extend<const BITS: usize> IntBits<BITS> {
    // Limbs are reached through these two, which are the only places the raw array is touched: the index
    // is checked at every entry point, and `set` masks the top limb, so bits past the width do not
    // exist: the invariant every operation relies on, kept in one place.

    const fn nlimbs() usize {
        return (BITS + 63) / 64;
    }

    // The live bits of the top limb: all of them when the width is a whole number of limbs.
    const fn top_mask() u64 {
        if BITS % 64 == 0 {
            return 0xFFFFFFFFFFFFFFFF;
        }
        return (1u64 << (BITS % 64) as u64) - 1;
    }

    const fn get(self: &IntBits<BITS>, i: usize) u64 {
        if i >= IntBits::<BITS>::nlimbs() {
            // Reading past the top limb yields the zero extension, which is what callers mean.
            return 0;
        }
        return unsafe self.limbs[i];
    }

    const fn set(self: &mut IntBits<BITS>, i: usize, v: u64) {
        let n = IntBits::<BITS>::nlimbs();
        if i + 1 == n {
            unsafe self.limbs[i] = v & IntBits::<BITS>::top_mask();
        } else if i < n {
            unsafe self.limbs[i] = v;
        }
    }

    const fn zero() IntBits<BITS> {
        static_assert(BITS >= 1, "an integer width must be positive");
        return IntBits::<BITS> {};
    }

    const fn from_u64(v: u64) IntBits<BITS> {
        let mut r = IntBits::<BITS>::zero();
        r.set(0, v);
        return r;
    }

    fn is_zero(self: &IntBits<BITS>) bool {
        for i in 0..IntBits::<BITS>::nlimbs() {
            if self.get(i) != 0 {
                return false;
            }
        }
        return true;
    }

    // Bit `i` counted from the least significant, 0 past the top.
    const fn bit(self: &IntBits<BITS>, i: usize) u64 {
        if i >= BITS {
            return 0;
        }
        return self.get(i / 64) >> (i % 64) as u64 & 1u64;
    }

    const fn set_bit(self: &mut IntBits<BITS>, i: usize, on: bool) {
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

    // The limbs up to the highest nonzero one: 0 for zero. Multiplication and division run over these
    // only, so a short value costs what its size does, not what the width does.
    fn len(self: &IntBits<BITS>) usize {
        let mut n = IntBits::<BITS>::nlimbs();
        while n > 0 && unsafe self.limbs[n - 1] == 0 {
            n = n - 1;
        }
        return n;
    }

    // Index of the highest set bit, or -1 for zero. Drives division's iteration count.
    fn top_bit(self: &IntBits<BITS>) i64 {
        let mut i = IntBits::<BITS>::nlimbs();
        while i > 0 {
            i = i - 1;
            let l = self.get(i);
            if l != 0 {
                return (i * 64 + 63 - l.leading_zeros()) as i64;
            }
        }
        return -1;
    }

    // Identical at the bit level for both signednesses, which is the whole reason this type exists.
    // `carry` reports the carry OUT of the top limb: an unsigned overflow, and what signed overflow
    // detection is derived from.

    fn add_carry(self: &IntBits<BITS>, other: &IntBits<BITS>, carry_out: *mut u64) IntBits<BITS> {
        if BITS == 128 && use_i128() {
            let mut lo: u64 = 0;
            let mut hi: u64 = 0;
            let mut c: u64 = 0;
            unsafe sc_i128_add(self.get(0), self.get(1), other.get(0), other.get(1), &mut lo, &mut hi, &mut c);
            let mut r = IntBits::<BITS>::zero();
            r.set(0, lo);
            r.set(1, hi);
            unsafe *carry_out = c;
            return r;
        }
        let mut r = IntBits::<BITS>::zero();
        let mut carry: u64 = 0;
        for i in 0..IntBits::<BITS>::nlimbs() {
            let a = self.get(i);
            let b = other.get(i);
            let s1 = a.wrapping_add(b); // the sum modulo 2^64: the carry test below reads the lost bit
            let c1 = (s1 < a) as u64;
            let s2 = s1.wrapping_add(carry);
            let c2 = (s2 < s1) as u64;
            r.set(i, s2);
            // For a partial top limb the carry sits INSIDE the u64, one past the width's top bit:
            // both operands are masked, so the sum holds at most one bit there.
            if BITS % 64 != 0 && i + 1 == IntBits::<BITS>::nlimbs() {
                carry = s2 >> (BITS % 64) as u64;
            } else {
                carry = c1 | c2;
            }
        }
        unsafe *carry_out = carry;
        return r;
    }

    fn sub_borrow(self: &IntBits<BITS>, other: &IntBits<BITS>, borrow_out: *mut u64) IntBits<BITS> {
        if BITS == 128 && use_i128() {
            let mut lo: u64 = 0;
            let mut hi: u64 = 0;
            let mut b: u64 = 0;
            unsafe sc_i128_sub(self.get(0), self.get(1), other.get(0), other.get(1), &mut lo, &mut hi, &mut b);
            let mut r = IntBits::<BITS>::zero();
            r.set(0, lo);
            r.set(1, hi);
            unsafe *borrow_out = b;
            return r;
        }
        let mut r = IntBits::<BITS>::zero();
        let mut borrow: u64 = 0;
        for i in 0..IntBits::<BITS>::nlimbs() {
            let a = self.get(i);
            let b = other.get(i);
            let d1 = a.wrapping_sub(b);
            let b1 = (a < b) as u64;
            let d2 = d1.wrapping_sub(borrow);
            let b2 = (d1 < borrow) as u64;
            r.set(i, d2);
            borrow = b1 | b2;
        }
        unsafe *borrow_out = borrow;
        return r;
    }

    // Two's complement negation: `!self + 1`. Shared, and the reason signed subtraction needs no code
    // of its own.
    fn negate(self: &IntBits<BITS>) IntBits<BITS> {
        let mut c: u64 = 0;
        let one = IntBits::<BITS>::from_u64(1);
        return self.bit_not().add_carry(&one, &mut c);
    }

    // The low `BITS` of the full product: what wrapping multiplication means, for either signedness.
    fn mul_wrap(self: &IntBits<BITS>, other: &IntBits<BITS>, overflow: *mut bool) IntBits<BITS> {
        if BITS == 128 && use_i128() {
            let mut lo: u64 = 0;
            let mut hi: u64 = 0;
            let mut hl: u64 = 0;
            let mut hh: u64 = 0;
            unsafe sc_i128_mul(self.get(0), self.get(1), other.get(0), other.get(1), &mut lo, &mut hi, &mut hl, &mut hh);
            let mut r = IntBits::<BITS>::zero();
            r.set(0, lo);
            r.set(1, hi);
            // A nonzero high half is exactly what wrapping lost.
            unsafe *overflow = hl != 0 || hh != 0;
            return r;
        }
        let mut r = IntBits::<BITS>::zero();
        let n = IntBits::<BITS>::nlimbs();
        // Up to four limbs the rows run over the whole width, loops the C compiler unrolls, and each row
        // checks the limbs of b past the top. Wider, they run over the limbs up to the top nonzero ones,
        // whose product lands at limb na + nb - 2: at or past n, a bit the width cannot hold.
        let small = n <= 4;
        let mut na = n;
        let mut nb = n;
        let mut over = false;
        if !small {
            na = self.len();
            nb = other.len();
            if na == 0 || nb == 0 {
                unsafe *overflow = false;
                return r;
            }
            over = na + nb - 2 >= n;
        }
        for i in 0..na {
            let a = unsafe self.limbs[i];
            if a == 0 {
                continue;
            }
            if small {
                for j in n - i..n {
                    if unsafe other.limbs[j] != 0 {
                        over = true;
                    }
                }
            }
            // Row i: the limbs of b that land below the top, then the carry into the limb past them,
            // which no earlier row has written.
            let m = if nb < n - i {
                nb;
            } else {
                n - i;
            };
            let mut carry: u64 = 0;
            for j in 0..m {
                let mut hi: u64 = 0;
                let lo = mul_wide(a, unsafe other.limbs[j], &mut hi);
                let cur = unsafe r.limbs[i + j];
                let s1 = cur.wrapping_add(lo);
                hi = hi + (s1 < cur) as u64;
                let s2 = s1.wrapping_add(carry);
                hi = hi + (s2 < s1) as u64;
                unsafe r.limbs[i + j] = s2;
                carry = hi;
            }
            if i + m < n {
                unsafe r.limbs[i + m] = carry;
            } else if carry != 0 {
                over = true;
            }
        }
        // A partial top limb holds bits above the width inside it; `set` clears them.
        let top = unsafe r.limbs[n - 1];
        let mask = IntBits::<BITS>::top_mask();
        if (top & ~mask) != 0 {
            over = true;
        }
        r.set(n - 1, top);
        unsafe *overflow = over;
        return r;
    }

    // self * m + c, and whether the true value exceeds the width: the step of parsing digits.
    fn mul_limb_add(self: &IntBits<BITS>, m: u64, c: u64, overflow: *mut bool) IntBits<BITS> {
        let n = IntBits::<BITS>::nlimbs();
        let len = self.len();
        let mut r = IntBits::<BITS>::zero();
        let mut carry = c;
        for i in 0..len {
            let mut hi: u64 = 0;
            let lo = mul_wide(unsafe self.limbs[i], m, &mut hi);
            let s = lo.wrapping_add(carry);
            // hi is at most 2^64 - 2, so the carry fits.
            carry = hi + (s < lo) as u64;
            unsafe r.limbs[i] = s;
        }
        let mut over = false;
        if len < n {
            unsafe r.limbs[len] = carry;
        } else {
            over = carry != 0;
        }
        let top = unsafe r.limbs[n - 1];
        let mask = IntBits::<BITS>::top_mask();
        if (top & ~mask) != 0 {
            over = true;
        }
        r.set(n - 1, top);
        unsafe *overflow = over;
        return r;
    }

    // The FULL product: the low half is returned, the high half stored through `hi_out`. Two N-bit
    // values multiply to 2N bits, so nothing narrower than a second N-bit value holds what the low half
    // loses: a carry-out BIT would say only THAT it overflowed, which `checked_mul` already reports.
    fn mul_full(self: &IntBits<BITS>, other: &IntBits<BITS>, hi_out: *mut IntBits<BITS>) IntBits<BITS> {
        // The split sits at BITS: a limb edge only when the width is a whole number of limbs.
        let n = IntBits::<BITS>::nlimbs();
        let prod = self.mul_double(other);
        let mut lo = IntBits::<BITS>::zero();
        let mut hi = IntBits::<BITS>::zero();
        let top = prod.shr_logical(BITS);
        for i in 0..n {
            // Set() masks the top limb: exactly the low BITS.
            lo.set(i, prod.get(i));
            hi.set(i, top.get(i));
        }
        unsafe *hi_out = hi;
        return lo;
    }

    // The 2*BITS-bit product, one row per nonzero limb of self over the limbs of other up to its top
    // nonzero one: each row's carry lands in the limb past it, which no earlier row has written. The
    // product fits, so no partial sum sets a bit above 2*BITS, and a carry with no limb to land in is zero.
    fn mul_double(self: &IntBits<BITS>, other: &IntBits<BITS>) IntBits<{BITS * 2}> {
        let mut prod = IntBits::<{BITS * 2}>::zero();
        if BITS == 128 && use_i128() {
            let mut p0: u64 = 0;
            let mut p1: u64 = 0;
            let mut p2: u64 = 0;
            let mut p3: u64 = 0;
            unsafe sc_i128_mul(self.get(0), self.get(1), other.get(0), other.get(1), &mut p0, &mut p1, &mut p2, &mut p3);
            prod.set(0, p0);
            prod.set(1, p1);
            prod.set(2, p2);
            prod.set(3, p3);
            return prod;
        }
        let na = self.len();
        let nb = other.len();
        for i in 0..na {
            let a = unsafe self.limbs[i];
            if a == 0 {
                continue;
            }
            let mut carry: u64 = 0;
            for j in 0..nb {
                let mut h: u64 = 0;
                let l = mul_wide(a, unsafe other.limbs[j], &mut h);
                let cur = unsafe prod.limbs[i + j];
                // a*b + cur + carry is at most 2^128 - 1, so neither carry can push `h` past a limb.
                let s1 = cur.wrapping_add(l);
                h = h + (s1 < cur) as u64;
                let s2 = s1.wrapping_add(carry);
                h = h + (s2 < s1) as u64;
                unsafe prod.limbs[i + j] = s2;
                carry = h;
            }
            prod.set(i + nb, carry);
        }
        return prod;
    }

    fn bit_and(self: &IntBits<BITS>, other: &IntBits<BITS>) IntBits<BITS> {
        let mut r = IntBits::<BITS>::zero();
        for i in 0..IntBits::<BITS>::nlimbs() {
            r.set(i, self.get(i) & other.get(i));
        }
        return r;
    }

    fn bit_or(self: &IntBits<BITS>, other: &IntBits<BITS>) IntBits<BITS> {
        let mut r = IntBits::<BITS>::zero();
        for i in 0..IntBits::<BITS>::nlimbs() {
            r.set(i, self.get(i) | other.get(i));
        }
        return r;
    }

    fn bit_xor(self: &IntBits<BITS>, other: &IntBits<BITS>) IntBits<BITS> {
        let mut r = IntBits::<BITS>::zero();
        for i in 0..IntBits::<BITS>::nlimbs() {
            r.set(i, self.get(i) ^ other.get(i));
        }
        return r;
    }

    fn bit_not(self: &IntBits<BITS>) IntBits<BITS> {
        let mut r = IntBits::<BITS>::zero();
        for i in 0..IntBits::<BITS>::nlimbs() {
            r.set(i, ~self.get(i));
        }
        return r;
    }

    // Left shift; bits shifted past the top are discarded, as they are for the built-in types.
    fn shl(self: &IntBits<BITS>, amount: usize) IntBits<BITS> {
        let mut r = IntBits::<BITS>::zero();
        if amount >= BITS {
            return r;
        }
        let n = IntBits::<BITS>::nlimbs();
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

    // Logical right shift: zeros in at the top, whatever the sign bit says.
    fn shr_logical(self: &IntBits<BITS>, amount: usize) IntBits<BITS> {
        let mut r = IntBits::<BITS>::zero();
        if amount >= BITS {
            return r;
        }
        let n = IntBits::<BITS>::nlimbs();
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

    // Arithmetic right shift: the sign bit is what fills the top, so `-1 >> k` stays `-1`.
    fn shr_arith(self: &IntBits<BITS>, amount: usize) IntBits<BITS> {
        let neg = self.bit(BITS - 1) != 0;
        if !neg {
            return self.shr_logical(amount);
        }
        if amount >= BITS {
            // All ones: the limit of shifting a negative value.
            return IntBits::<BITS>::zero().bit_not();
        }
        let r = self.shr_logical(amount);
        // Put the sign back into everything the logical shift zeroed.
        let mut ones = IntBits::<BITS>::zero().bit_not();
        ones = ones.shl(BITS - amount);
        return r.bit_or(&ones);
    }

    fn cmp_unsigned(self: &IntBits<BITS>, other: &IntBits<BITS>) i32 {
        let mut i = IntBits::<BITS>::nlimbs();
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
        for i in 0..IntBits::<BITS>::nlimbs() {
            if self.get(i) != other.get(i) {
                return false;
            }
        }
        return true;
    }

    // Long division by whole limbs: Knuth's Algorithm D (TAOCP vol. 2, 4.3.1; Hacker's Delight 9-2) in
    // base 2^64. The divisor is normalized (its top limb's high bit set) so each quotient limb's estimate
    // from the top two remainder limbs is at most 2 too large; a test against the next limb removes almost
    // every such case, and the rare one left shows as a borrow and is added back.
    fn divmod_unsigned(self: &IntBits<BITS>, divisor: &IntBits<BITS>, quot: *mut IntBits<BITS>, rem: *mut IntBits<BITS>) {
        if divisor.is_zero() {
            unsafe sc_int_div_zero("attempt to divide by zero".ptr());
        }
        if BITS == 128 && use_i128() {
            let mut ql: u64 = 0;
            let mut qh: u64 = 0;
            let mut rl: u64 = 0;
            let mut rh: u64 = 0;
            unsafe sc_i128_divmod(
                self.get(0),
                self.get(1),
                divisor.get(0),
                divisor.get(1),
                &mut ql,
                &mut qh,
                &mut rl,
                &mut rh,
            );
            let mut q = IntBits::<BITS>::zero();
            q.set(0, ql);
            q.set(1, qh);
            let mut r = IntBits::<BITS>::zero();
            r.set(0, rl);
            r.set(1, rh);
            unsafe *quot = q;
            unsafe *rem = r;
            return;
        }
        let nl = IntBits::<BITS>::nlimbs();
        // Significant limbs of the divisor (at least 1) and of the dividend.
        let mut n = nl;
        while divisor.get(n - 1) == 0 {
            n = n - 1;
        }
        let mut m = nl;
        while m > 0 && self.get(m - 1) == 0 {
            m = m - 1;
        }
        let mut q = IntBits::<BITS>::zero();
        let mut r = IntBits::<BITS>::zero();
        if m < n {
            unsafe *quot = q;
            unsafe *rem = *self;
            return;
        }
        // Normalized copies: the divisor in n limbs, the dividend in m + 1.
        let s = divisor.get(n - 1).leading_zeros() as u64;
        let mut vn: [u64; (BITS + 63) / 64] = [0; (BITS + 63) / 64];
        let mut un: [u64; (BITS + 63) / 64 + 1] = [0; (BITS + 63) / 64 + 1];
        for i in 0..n {
            let lo = if s == 0 || i == 0 {
                0u64;
            } else {
                divisor.get(i - 1) >> 64 - s;
            };
            unsafe vn[i] = divisor.get(i) << s | lo;
        }
        for i in 0..m + 1 {
            let lo = if s == 0 || i == 0 {
                0u64;
            } else {
                self.get(i - 1) >> 64 - s;
            };
            unsafe un[i] = self.get(i) << s | lo;
        }
        let vtop = unsafe vn[n - 1];
        let vinv = reciprocal(vtop);
        if n == 1 {
            // One limb: each quotient limb from two remainder limbs, the remainder the low one.
            let mut rl = unsafe un[m];
            let mut j = m;
            while j > 0 {
                j = j - 1;
                q.set(j, div2by1_pre(rl, unsafe un[j], vtop, vinv, &mut rl));
            }
            r.set(0, rl >> s);
            unsafe *quot = q;
            unsafe *rem = r;
            return;
        }
        let vnext = unsafe vn[n - 2];
        let mut j = m - n + 1;
        while j > 0 {
            j = j - 1;
            // The estimate from the top two limbs: the remainder's top limb is at most vtop, and at vtop
            // the quotient limb is at most 2^64 - 1.
            let u2 = unsafe un[j + n];
            let u1 = unsafe un[j + n - 1];
            let mut qhat: u64 = 0;
            let mut rhat: u64 = 0;
            let mut big = false; // rhat >= 2^64: the next-limb test cannot fail
            if u2 >= vtop {
                qhat = 0xFFFFFFFFFFFFFFFF;
                rhat = u1.wrapping_add(vtop);
                big = rhat < u1;
            } else {
                qhat = div2by1_pre(u2, u1, vtop, vinv, &mut rhat);
            }
            while !big {
                let mut ph: u64 = 0;
                let pl = mul_wide(qhat, vnext, &mut ph);
                let u0 = unsafe un[j + n - 2];
                if ph < rhat || ph == rhat && pl <= u0 {
                    break;
                }
                qhat = qhat - 1;
                let r2 = rhat.wrapping_add(vtop);
                big = r2 < rhat;
                rhat = r2;
            }
            // un[j..j + n] -= qhat * vn.
            let mut carry: u64 = 0;
            let mut borrow: u64 = 0;
            for i in 0..n {
                let mut ph: u64 = 0;
                let pl = mul_wide(qhat, unsafe vn[i], &mut ph);
                let p = pl.wrapping_add(carry);
                carry = ph + (p < pl) as u64;
                let t = unsafe un[i + j];
                let d1 = t.wrapping_sub(p);
                let d2 = d1.wrapping_sub(borrow);
                borrow = (t < p) as u64 | (d1 < borrow) as u64;
                unsafe un[i + j] = d2;
            }
            let t = unsafe un[j + n];
            let d1 = t.wrapping_sub(carry);
            let d2 = d1.wrapping_sub(borrow);
            unsafe un[j + n] = d2;
            if t < carry || d1 < borrow {
                // qhat was one too large: add the divisor back.
                qhat = qhat - 1;
                let mut c: u64 = 0;
                for i in 0..n {
                    let a = unsafe un[i + j];
                    let s1 = a.wrapping_add(unsafe vn[i]);
                    let s2 = s1.wrapping_add(c);
                    c = (s1 < a) as u64 | (s2 < s1) as u64;
                    unsafe un[i + j] = s2;
                }
                unsafe un[j + n] = unsafe un[j + n].wrapping_add(c);
            }
            q.set(j, qhat);
        }
        // The remainder: the low n limbs, shifted back.
        for i in 0..n {
            let hi = if s == 0 {
                0u64;
            } else {
                unsafe un[i + 1] << 64 - s;
            };
            r.set(i, unsafe un[i] >> s | hi);
        }
        unsafe *quot = q;
        unsafe *rem = r;
    }

    // Divide by a one-limb divisor d, returning the remainder: the path digit formatting takes. The
    // divisor comes normalized, `dn` = d << s with its top bit set, with `v` its reciprocal, so a caller
    // dividing by one d many times computes them once; each quotient limb is one `div2by1_pre` on the
    // dividend shifted by s, over the limbs up to its top nonzero one.
    fn divmod_limb(self: &IntBits<BITS>, s: u64, dn: u64, v: u64, quot: *mut IntBits<BITS>) u64 {
        let mut q = IntBits::<BITS>::zero();
        let n = self.len();
        if n == 0 {
            unsafe *quot = q;
            return 0;
        }
        // The shifted dividend's limb past the top: below 2^s, so below dn.
        let mut rem = if s == 0 {
            0u64;
        } else {
            unsafe self.limbs[n - 1] >> 64 - s;
        };
        let mut i = n;
        while i > 0 {
            i = i - 1;
            let mut u0 = unsafe self.limbs[i] << s;
            if s != 0 && i > 0 {
                u0 = u0 | unsafe self.limbs[i - 1] >> 64 - s;
            }
            unsafe q.limbs[i] = div2by1_pre(rem, u0, dn, v, &mut rem);
        }
        unsafe *quot = q;
        return rem >> s;
    }

    // The limbs in reverse order, each bit-reversed (`bits`) or byte-reversed, then shifted down by the
    // unused top bits: the whole width reversed.
    fn reversed(self: &IntBits<BITS>, bits: bool) IntBits<BITS> {
        let n = IntBits::<BITS>::nlimbs();
        let mut r = IntBits::<BITS>::zero();
        for i in 0..n {
            let v = unsafe self.limbs[i];
            unsafe r.limbs[n - 1 - i] = if bits {
                rev64(v);
            } else {
                bswap64(v);
            };
        }
        let a = (n * 64 - BITS) as u64;
        if a != 0 {
            for i in 0..n {
                let hi = if i + 1 < n {
                    unsafe r.limbs[i + 1] << 64 - a;
                } else {
                    0u64;
                };
                unsafe r.limbs[i] = unsafe r.limbs[i] >> a | hi;
            }
        }
        return r;
    }
}

// UInt<BITS>: the unsigned view.

/// An unsigned integer `BITS` wide. Overflow traps or wraps with the build profile, exactly as in the
/// built-in unsigned types; `wrapping_*`, `checked_*` and `saturating_*` give the other answers.
pub struct UInt<const BITS: usize> {
    bits: IntBits<BITS>,
}

extend<const BITS: usize> UInt<BITS> {
    /// The width in bits, bytes and 64-bit limbs. Compile-time constants: each is a `const fn` over the
    /// type's own generic argument, so a call folds to a literal in the emitted C.
    pub const fn bits() usize {
        return BITS;
    }

    /// Bytes needed to hold the value: ceil(BITS / 8).
    pub const fn bytes() usize {
        return (BITS + 7) / 8;
    }

    /// 64-bit limbs of storage: ceil(BITS / 64).
    pub const fn limbs() usize {
        return (BITS + 63) / 64;
    }

    // The only places `bits` is named from outside this type's own methods: a wrapper's field belongs
    // to that wrapper, so the signed view goes through these rather than reaching into the unsigned one.
    const fn from_bits(b: IntBits<BITS>) UInt<BITS> {
        return UInt::<BITS> { bits: b };
    }

    const fn raw(self: &UInt<BITS>) IntBits<BITS> {
        return self.bits;
    }

    /// The value 0.
    pub const fn zero() UInt<BITS> {
        return UInt::<BITS> { bits: IntBits::<BITS>::zero() };
    }

    /// The value 1.
    pub const fn one() UInt<BITS> {
        return UInt::<BITS> { bits: IntBits::<BITS>::from_u64(1) };
    }

    /// The largest value: every bit set.
    pub fn max() UInt<BITS> {
        return UInt::<BITS> { bits: IntBits::<BITS>::zero().bit_not() };
    }

    /// The smallest value (0 for unsigned).
    pub const fn min() UInt<BITS> {
        return UInt::<BITS>::zero();
    }

    /// The value of `v`, truncated to BITS.
    pub const fn from_u64(v: u64) UInt<BITS> {
        return UInt::<BITS> { bits: IntBits::<BITS>::from_u64(v) };
    }

    /// The low 64 bits, discarding the rest: the `as u64` of a wide value.
    pub const fn to_u64(self: &UInt<BITS>) u64 {
        return self.bits.get(0);
    }

    /// Limb `i`, least significant first; 0 past the top.
    pub const fn limb(self: &UInt<BITS>, i: usize) u64 {
        return self.bits.get(i);
    }

    /// Overwrite limb `i`; bits past the width are masked off.
    pub const fn set_limb(self: &mut UInt<BITS>, i: usize, v: u64) {
        self.bits.set(i, v);
    }

    /// True when every bit is clear.
    pub fn is_zero(self: &UInt<BITS>) bool {
        return self.bits.is_zero();
    }

    /// True when bit `i` (0 = least significant) is set; `i` must be below BITS.
    pub const fn bit(self: &UInt<BITS>, i: usize) bool {
        return self.bits.bit(i) != 0;
    }

    /// Bits needed to represent the value: 0 for zero, otherwise one past the highest set bit.
    pub fn bit_length(self: &UInt<BITS>) usize {
        return (self.bits.top_bit() + 1) as usize;
    }

    /// Zero bits above the most significant set bit (BITS for zero).
    pub fn leading_zeros(self: &UInt<BITS>) usize {
        return BITS - self.bit_length();
    }

    /// Number of set bits.
    pub fn count_ones(self: &UInt<BITS>) usize {
        let mut n: usize = 0;
        for i in 0..UInt::<BITS>::limbs() {
            n = n + self.bits.get(i).count_ones();
        }
        return n;
    }

    /// Number of clear bits.
    pub fn count_zeros(self: &UInt<BITS>) usize {
        return BITS - self.count_ones();
    }

    /// Zero bits below the least significant set bit (BITS for zero).
    pub fn trailing_zeros(self: &UInt<BITS>) usize {
        for i in 0..UInt::<BITS>::limbs() {
            let l = self.bits.get(i);
            if l != 0 {
                return i * 64 + l.trailing_zeros();
            }
        }
        return BITS;
    }

    /// Rotation at the type's own width: bits leaving one end come back in at the other, so a partial
    /// width rotates through exactly BITS positions, not through a limb's 64.
    pub fn rotate_left(self: &UInt<BITS>, amount: usize) UInt<BITS> {
        let k = amount % BITS;
        if k == 0 {
            return *self;
        }
        let hi = self.shr(BITS - k);
        return self.shl(k).bit_or(&hi);
    }

    /// Bits rotated right by `amount` modulo BITS.
    pub fn rotate_right(self: &UInt<BITS>, amount: usize) UInt<BITS> {
        let k = amount % BITS;
        if k == 0 {
            return *self;
        }
        let hi = self.shl(BITS - k);
        return self.shr(k).bit_or(&hi);
    }

    /// Byte order reversed. Bytes are a claim about layout, so this exists only for whole-byte widths.
    pub fn swap_bytes(self: &UInt<BITS>) UInt<BITS> {
        static_assert(BITS % 8 == 0, "swap_bytes needs a whole number of bytes");
        return UInt::<BITS> { bits: self.bits.reversed(false) };
    }

    /// Bit order reversed over the full width.
    pub fn reverse_bits(self: &UInt<BITS>) UInt<BITS> {
        return UInt::<BITS> { bits: self.bits.reversed(true) };
    }

    /// True for exactly one set bit.
    pub fn is_power_of_two(self: &UInt<BITS>) bool {
        return self.count_ones() == 1;
    }

    /// The smallest power of two at or above the value. Panics when that power is 2^BITS, one past the
    /// top of the range: `checked_next_power_of_two` answers None there instead.
    pub fn next_power_of_two(self: &UInt<BITS>) UInt<BITS> {
        switch self.checked_next_power_of_two() {
            Some(v) => {
                return v;
            },
            None => {
                panic("arithmetic overflow");
            },
        };
    }

    /// The smallest power of two not below `self`; None when it does not fit.
    pub fn checked_next_power_of_two(self: &UInt<BITS>) Option<UInt<BITS>> {
        let one = UInt::<BITS>::one();
        if self.cmp(&one) <= 0 {
            return Option::<UInt<BITS>>::Some(one);
        }
        // For a value above one, the answer is 1 << bit_length(value - 1): exactly the value when it
        // already is a power of two, the next one otherwise.
        let n = self.wrapping_sub(&one).bit_length();
        if n >= BITS {
            return Option::<UInt<BITS>>::None;
        }
        return Option::<UInt<BITS>>::Some(one.shl(n));
    }

    /// Addition modulo 2^BITS.
    pub fn wrapping_add(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        let mut c: u64 = 0;
        return UInt::<BITS> { bits: self.bits.add_carry(&other.bits, &mut c) };
    }

    /// Subtraction modulo 2^BITS.
    pub fn wrapping_sub(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        let mut b: u64 = 0;
        return UInt::<BITS> { bits: self.bits.sub_borrow(&other.bits, &mut b) };
    }

    /// Multiplication modulo 2^BITS.
    pub fn wrapping_mul(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        let mut o = false;
        return UInt::<BITS> { bits: self.bits.mul_wrap(&other.bits, &mut o) };
    }

    /// Two's-complement negation modulo 2^BITS.
    pub fn wrapping_neg(self: &UInt<BITS>) UInt<BITS> {
        return UInt::<BITS> { bits: self.bits.negate() };
    }

    /// The low and high halves of the full product: `hi` receives the top `BITS`, the low ones are
    /// returned. Nothing is lost, and no wider type has to exist for it.
    pub fn widening_mul(self: &UInt<BITS>, other: &UInt<BITS>, hi: &mut UInt<BITS>) UInt<BITS> {
        let mut h = IntBits::<BITS>::zero();
        let lo = self.bits.mul_full(&other.bits, &mut h);
        *hi = UInt::<BITS>::from_bits(h);
        return UInt::<BITS>::from_bits(lo);
    }

    /// The widening conversion between widths: a `UInt<M>` read as a `UInt<BITS>` at least as wide. The
    /// compiler applies it implicitly wherever a `UInt<BITS>` is expected, exactly as a narrower built-in
    /// integer widens to a wider one; a narrowing M is rejected where the copy would lose limbs.
    pub fn widen<const M: usize>(v: &UInt<M>) UInt<BITS> {
        static_assert(M <= BITS, "widen: the target must be at least as wide as the source");
        let mut r = UInt::<BITS>::zero();
        for i in 0..(M + 63) / 64 {
            r.set_limb(i, v.limb(i));
        }
        return r;
    }

    /// The value as a double, rounded ONCE: the top 64 bits are taken with a sticky bit; any dropped
    /// low bit ORed into the bottom, so the single u64 conversion rounds exactly as converting the
    /// full value would. Accumulating limb by limb instead would round at every step. Values past f64's
    /// range become infinity, as the built-in conversions do: the scaling by powers of two after the one
    /// rounding is exact up to that overflow. A scale of 2^1100 from u >= 2^63 is past 2^1024 already,
    /// so at most 18 steps scale.
    pub fn to_f64(self: &UInt<BITS>) f64 {
        let n = self.bit_length();
        if n <= 64 {
            return self.limb(0) as f64;
        }
        let mut shift = n - 64;
        let top = self.shr(shift);
        let mut u = top.limb(0);
        let back = top.shl(shift);
        if !(back == *self) {
            u = u | 1;
        }
        let mut f = u as f64;
        if shift > 1100 {
            shift = 1100;
        }
        while shift >= 64 {
            f = f * 18446744073709551616.0;
            shift = shift - 64;
        }
        return f * (1u64 << shift as u64) as f64;
    }

    /// The same, to f32: the u64 carrier holds every bit that can matter for a 24-bit mantissa too, and
    /// past 2^128 the result is infinite.
    pub fn to_f32(self: &UInt<BITS>) f32 {
        let n = self.bit_length();
        if n <= 64 {
            return self.limb(0) as f32;
        }
        let mut shift = n - 64;
        let top = self.shr(shift);
        let mut u = top.limb(0);
        let back = top.shl(shift);
        if !(back == *self) {
            u = u | 1;
        }
        let mut f = u as f32;
        if shift > 200 {
            shift = 200;
        }
        while shift >= 64 {
            f = f * 18446744073709551616.0f32;
            shift = shift - 64;
        }
        return f * (1u64 << shift as u64) as f32;
    }

    /// The integer part of a double, SATURATING: NaN and everything below zero give zero, values at or
    /// past 2^BITS give max(). The top limb k comes from four halvings of the range (a finite double is
    /// below 2^1024, so k <= 15); then each limb from the top, p = 2^(64 j), is floor(rest / p), and rest -
    /// limb p is exact, because the limb's bits are bits of rest. 53 significant bits span at most two
    /// limbs, so the steps end at a zero rest.
    pub fn from_f64(v: f64) UInt<BITS> {
        if !(v == v) || v < 1.0 {
            return UInt::<BITS>::zero();
        }
        if v > 1.7976931348623157e308 {
            // Infinity, past every width.
            return UInt::<BITS>::max();
        }
        let t64: f64 = 18446744073709551616.0;
        let t128 = t64 * t64;
        let t256 = t128 * t128;
        let t512 = t256 * t256;
        let mut x = v;
        let mut p: f64 = 1.0;
        let mut k: usize = 0;
        if x >= t512 {
            x = x / t512;
            p = p * t512;
            k = k + 8;
        }
        if x >= t256 {
            x = x / t256;
            p = p * t256;
            k = k + 4;
        }
        if x >= t128 {
            x = x / t128;
            p = p * t128;
            k = k + 2;
        }
        if x >= t64 {
            x = x / t64;
            p = p * t64;
            k = k + 1;
        }
        let top = x as u64;
        if 64 * k + 64 - top.leading_zeros() > BITS {
            return UInt::<BITS>::max();
        }
        let mut r = UInt::<BITS>::zero();
        let mut rest = v;
        let mut j = k + 1;
        while j > 0 && rest != 0.0 {
            j = j - 1;
            let c = (rest / p) as u64;
            r.set_limb(j, c);
            rest = rest - c as f64 * p;
            p = p / t64;
        }
        return r;
    }

    /// What `expr as uN` means for these types, with exactly C's cast semantics: truncate when the
    /// target is narrower, extend when wider: by zero here, and by the sign in `cast_signed`, because
    /// extension follows the SOURCE's signedness. `as` dispatches to whichever the operand fits; the pair
    /// is named by source rather than overloaded so the two monomorphize to distinct symbols. Not applied
    /// implicitly: an implicit conversion must be lossless, and these deliberately are not.
    pub fn cast_unsigned<const M: usize>(v: &UInt<M>) UInt<BITS> {
        let mut r = UInt::<BITS>::zero();
        for i in 0..UInt::<BITS>::limbs() {
            if i < (M + 63) / 64 {
                r.set_limb(i, v.limb(i));
            }
        }
        return r;
    }

    /// Sign-extend or truncate an Int<M> into this width.
    pub fn cast_signed<const M: usize>(v: &Int<M>) UInt<BITS> {
        let fill = if v.is_negative() {
            0xFFFFFFFFFFFFFFFFu64;
        } else {
            0u64;
        };
        let mut r = UInt::<BITS>::zero();
        for i in 0..UInt::<BITS>::limbs() {
            if i < (M + 63) / 64 {
                r.set_limb(i, v.limb(i));
            } else {
                r.set_limb(i, fill);
            }
        }
        // A source width that ends inside a limb keeps its own top bits zero, so the sign must also
        // fill the rest of that boundary limb.
        if fill != 0 && M % 64 != 0 && M < BITS {
            r.set_limb(M / 64, v.limb(M / 64) | fill << (M % 64) as u64);
        }
        return r;
    }

    /// The same full product as ONE value twice as wide. `{BITS * 2}` is a const-generic EXPRESSION: the
    /// result's width is computed from the receiver's when the call is monomorphized. The wider type is
    /// instantiated because this call asks for it, not because the method exists: otherwise every width
    /// would demand the next one without end.
    pub fn full_mul(self: &UInt<BITS>, other: &UInt<BITS>) UInt<{BITS * 2}> {
        return UInt::<{BITS * 2}>::from_bits(self.bits.mul_double(&other.bits));
    }

    /// The sum, or None on overflow.
    pub fn checked_add(self: &UInt<BITS>, other: &UInt<BITS>) Option<UInt<BITS>> {
        let mut c: u64 = 0;
        let r = UInt::<BITS> { bits: self.bits.add_carry(&other.bits, &mut c) };
        if c != 0 {
            return Option::<UInt<BITS>>::None;
        }
        return Option::<UInt<BITS>>::Some(r);
    }

    /// The difference, or None on overflow.
    pub fn checked_sub(self: &UInt<BITS>, other: &UInt<BITS>) Option<UInt<BITS>> {
        let mut b: u64 = 0;
        let r = UInt::<BITS> { bits: self.bits.sub_borrow(&other.bits, &mut b) };
        if b != 0 {
            return Option::<UInt<BITS>>::None;
        }
        return Option::<UInt<BITS>>::Some(r);
    }

    /// The product, or None on overflow.
    pub fn checked_mul(self: &UInt<BITS>, other: &UInt<BITS>) Option<UInt<BITS>> {
        let mut o = false;
        let r = UInt::<BITS> { bits: self.bits.mul_wrap(&other.bits, &mut o) };
        if o {
            return Option::<UInt<BITS>>::None;
        }
        return Option::<UInt<BITS>>::Some(r);
    }

    /// The sum, clamped to the range.
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

    /// The difference, clamped to the range.
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

    /// The product, clamped to the range.
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

    /// The wrapped sum and whether it overflowed.
    pub fn overflowing_add(self: &UInt<BITS>, other: &UInt<BITS>) (UInt<BITS>, bool) {
        let mut c: u64 = 0;
        let r = UInt::<BITS> { bits: self.bits.add_carry(&other.bits, &mut c) };
        return r, c != 0;
    }

    /// The wrapped difference and whether it overflowed.
    pub fn overflowing_sub(self: &UInt<BITS>, other: &UInt<BITS>) (UInt<BITS>, bool) {
        let mut b: u64 = 0;
        let r = UInt::<BITS> { bits: self.bits.sub_borrow(&other.bits, &mut b) };
        return r, b != 0;
    }

    /// The wrapped product and whether it overflowed.
    pub fn overflowing_mul(self: &UInt<BITS>, other: &UInt<BITS>) (UInt<BITS>, bool) {
        let mut o = false;
        let r = UInt::<BITS> { bits: self.bits.mul_wrap(&other.bits, &mut o) };
        return r, o;
    }

    /// Exponentiation by squaring. Overflow traps or wraps like the operators; `checked_pow` reports it
    /// instead.
    pub fn pow(self: &UInt<BITS>, exp: u32) UInt<BITS> {
        switch self.checked_pow(exp) {
            Some(v) => {
                return v;
            },
            None => {
                unsafe sc_int_overflow("attempt to multiply with overflow".ptr());
                return self.wrapping_pow(exp);
            },
        };
    }

    /// Exponentiation by squaring modulo 2^BITS.
    pub fn wrapping_pow(self: &UInt<BITS>, exp: u32) UInt<BITS> {
        let mut acc = UInt::<BITS>::one();
        let mut base = *self;
        let mut e = exp;
        while e != 0 {
            if (e & 1) != 0 {
                acc = acc.wrapping_mul(&base);
            }
            base = base.wrapping_mul(&base);
            e = e >> 1;
        }
        return acc;
    }

    /// `self` to the power `exp`, or None on overflow.
    pub fn checked_pow(self: &UInt<BITS>, exp: u32) Option<UInt<BITS>> {
        let mut acc = UInt::<BITS>::one();
        let mut base = *self;
        let mut e = exp;
        while e != 0 {
            if (e & 1) != 0 {
                switch acc.checked_mul(&base) {
                    Some(v) => {
                        acc = v;
                    },
                    None => {
                        return Option::<UInt<BITS>>::None;
                    },
                };
            }
            e = e >> 1;
            if e == 0 {
                // The last squaring feeds nothing: its overflow would be a false alarm.
                break;
            }
            switch base.checked_mul(&base) {
                Some(v) => {
                    base = v;
                },
                None => {
                    return Option::<UInt<BITS>>::None;
                },
            };
        }
        return Option::<UInt<BITS>>::Some(acc);
    }

    /// |self - other|: the smaller subtracted from the larger, which wrapping arithmetic makes exact.
    pub fn abs_diff(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        if self.cmp(other) >= 0 {
            return self.wrapping_sub(other);
        }
        return other.wrapping_sub(self);
    }

    /// Quotient and remainder in one pass: the division routine runs once, which `div` and `rem`
    /// separately would not.
    pub fn divmod(self: &UInt<BITS>, other: &UInt<BITS>, rem: &mut UInt<BITS>) UInt<BITS> {
        let mut q = IntBits::<BITS>::zero();
        let mut r = IntBits::<BITS>::zero();
        self.bits.divmod_unsigned(&other.bits, &mut q, &mut r);
        *rem = UInt::<BITS> { bits: r };
        return UInt::<BITS> { bits: q };
    }

    /// The quotient, or None for a zero divisor.
    pub fn checked_div(self: &UInt<BITS>, other: &UInt<BITS>) Option<UInt<BITS>> {
        if other.is_zero() {
            return Option::<UInt<BITS>>::None;
        }
        let mut r = UInt::<BITS>::zero();
        return Option::<UInt<BITS>>::Some(self.divmod(other, &mut r));
    }

    /// The remainder, or None for a zero divisor.
    pub fn checked_rem(self: &UInt<BITS>, other: &UInt<BITS>) Option<UInt<BITS>> {
        if other.is_zero() {
            return Option::<UInt<BITS>>::None;
        }
        let mut r = UInt::<BITS>::zero();
        let _ = self.divmod(other, &mut r);
        return Option::<UInt<BITS>>::Some(r);
    }

    // Serialization at the value's own width: bytes() = (BITS + 7) / 8 bytes, a partial top byte
    // carrying the remaining bits. Slices rather than fixed arrays, so any buffer serves; `to_*`
    // panics on one too short (a silent truncation would be a wrong VALUE), `from_*` reads at most
    // bytes() and masks anything past the width, so a round-trip is exact.

    /// Write the value little-endian into `out`, which must hold `bytes()` bytes.
    pub fn to_le_bytes(self: &UInt<BITS>, out: []mut u8) {
        let nb = UInt::<BITS>::bytes();
        if out.len() < nb {
            panic("to_le_bytes: the buffer is smaller than the value");
        }
        for i in 0..nb {
            out[i] = (self.bits.get(i / 8) >> (i % 8 * 8) as u64) as u8;
        }
    }

    /// The value of little-endian bytes `b` (short input is zero-extended, extra bytes ignored).
    pub fn from_le_bytes(b: []u8) UInt<BITS> {
        let mut nb = UInt::<BITS>::bytes();
        if b.len() < nb {
            // Missing high bytes read as the zeros they are.
            nb = b.len();
        }
        let mut r = UInt::<BITS>::zero();
        for i in 0..nb {
            let li = i / 8;
            r.bits.set(li, r.bits.get(li) | b[i] as u64 << (i % 8 * 8) as u64);
        }
        return r;
    }

    /// Write the value big-endian into `out`, which must hold `bytes()` bytes.
    pub fn to_be_bytes(self: &UInt<BITS>, out: []mut u8) {
        let nb = UInt::<BITS>::bytes();
        if out.len() < nb {
            panic("to_be_bytes: the buffer is smaller than the value");
        }
        for i in 0..nb {
            out[nb - 1 - i] = (self.bits.get(i / 8) >> (i % 8 * 8) as u64) as u8;
        }
    }

    /// The value of big-endian bytes `b` (short input is zero-extended, extra bytes ignored).
    pub fn from_be_bytes(b: []u8) UInt<BITS> {
        let n = b.len();
        let mut nb = UInt::<BITS>::bytes();
        if n < nb {
            nb = n;
        }
        let mut r = UInt::<BITS>::zero();
        for i in 0..nb {
            let li = i / 8;
            r.bits.set(li, r.bits.get(li) | b[n - 1 - i] as u64 << (i % 8 * 8) as u64);
        }
        return r;
    }

    /// Decimal digits. Repeated division by a single limb, which is the cheap path through the divider.
    pub fn to_string(self: &UInt<BITS>) String {
        let mut out = String::new();
        self.push_digits(&mut out, 10);
        return out;
    }

    // Append the digits in `radix` (2..=36, `a`-`z` past 9) to `out` with one reservation: a value has at
    // most BITS / floor(log2 radix) + 1 digits. They are written least significant first into the spare
    // capacity, then reversed in place. Each division is by the largest power of the radix one limb holds
    // (10^19 for decimal), so one pass over the limbs yields that many digits, in u64 arithmetic.
    fn push_digits(self: &UInt<BITS>, out: &mut String, radix: u32) {
        let mut lg: usize = 1;
        while 2u32 << lg as u32 <= radix {
            lg = lg + 1;
        }
        let r = radix as u64;
        let mut big = r;
        let mut k: usize = 1;
        while big <= 0xFFFFFFFFFFFFFFFF / r {
            big = big * r;
            k = k + 1;
        }
        let s = big.leading_zeros() as u64;
        let v = reciprocal(big << s);
        let p = out.spare_mut(BITS / lg + 1);
        let mut n: usize = 0;
        let mut cur = self.bits;
        loop {
            let mut q = IntBits::<BITS>::zero();
            let mut c = cur.divmod_limb(s, big << s, v, &mut q);
            let last = q.is_zero();
            // A chunk below the top one is k digits, its leading zeros included; the top one stops at
            // its top nonzero digit.
            for m in 0..k {
                if last && c == 0 && m > 0 {
                    break;
                }
                let d = c % r;
                c = c / r;
                if d < 10 {
                    unsafe p[n] = b'0' + d as u8;
                } else {
                    unsafe p[n] = b'a' + (d - 10) as u8;
                }
                n = n + 1;
            }
            cur = q;
            if last {
                break;
            }
        }
        let mut i: usize = 0;
        let mut j = n - 1;
        while i < j {
            let t = unsafe p[i];
            unsafe p[i] = unsafe p[j];
            unsafe p[j] = t;
            i = i + 1;
            j = j - 1;
        }
        out.advance_len(n);
    }

    /// Parse decimal digits. `None` on an empty string, a non-digit, or a value too wide to represent.
    pub fn from_str(s: str) Option<UInt<BITS>> {
        // Radix 10 rejects every letter, as a decimal parse must.
        return UInt::<BITS>::from_str_radix(s, 10);
    }

    /// Digits in any radix from 2 to 36, `a`-`z` past 9; repeated single-limb division, like `to_string`.
    /// Panics on a radix outside that range: the caller wrote it, so it is a bug, not an input.
    pub fn to_string_radix(self: &UInt<BITS>, radix: u32) String {
        if radix < 2 || radix > 36 {
            panic("radix must be between 2 and 36");
        }
        let mut out = String::new();
        self.push_digits(&mut out, radix);
        return out;
    }

    /// Parse digits in any radix from 2 to 36, either letter case. `None` on an empty string, a digit
    /// outside the radix, a radix outside the range, or a value too wide to represent.
    pub fn from_str_radix(s: str, radix: u32) Option<UInt<BITS>> {
        if radix < 2 || radix > 36 || s.len() == 0 {
            return Option::<UInt<BITS>>::None;
        }
        // Digits gather in a u64 `c`, `m` the radix to their count, and fold into the wide value once m
        // could not take another digit, or at the end: one pass over the limbs per limb of digits. The value
        // only grows, so an overflow at a fold is an overflow of the whole.
        let r = radix as u64;
        let mut acc = IntBits::<BITS>::zero();
        let mut c: u64 = 0;
        let mut m: u64 = 1;
        for i in 0..s.len() {
            let ch = s.byte_at(i);
            let mut d: u32 = 255;
            if ch >= b'0' && ch <= b'9' {
                d = ch - b'0';
            } else if ch >= b'a' && ch <= b'z' {
                d = ch - b'a' + 10;
            } else if ch >= b'A' && ch <= b'Z' {
                d = ch - b'A' + 10;
            }
            if d >= radix {
                return Option::<UInt<BITS>>::None;
            }
            c = c * r + d as u64;
            m = m * r;
            if m > 0xFFFFFFFFFFFFFFFF / r || i + 1 == s.len() {
                let mut over = false;
                acc = acc.mul_limb_add(m, c, &mut over);
                if over {
                    return Option::<UInt<BITS>>::None;
                }
                c = 0;
                m = 1;
            }
        }
        return Option::<UInt<BITS>>::Some(UInt::<BITS> { bits: acc });
    }
}

// Operators. `+`, `-` and `*` trap or wrap on overflow with the build profile, and `/` and `%` panic on a
// zero divisor, which is what the built-in unsigned types do.
extend<const BITS: usize> UInt<BITS> as Add {
    type Output = UInt<BITS>;

    pub fn add(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        let (r, o) = self.overflowing_add(other);
        if o {
            unsafe sc_int_overflow("attempt to add with overflow".ptr());
        }
        return r;
    }
}

extend<const BITS: usize> UInt<BITS> as Sub {
    type Output = UInt<BITS>;

    pub fn sub(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        let (r, o) = self.overflowing_sub(other);
        if o {
            unsafe sc_int_overflow("attempt to subtract with overflow".ptr());
        }
        return r;
    }
}

extend<const BITS: usize> UInt<BITS> as Mul {
    type Output = UInt<BITS>;

    pub fn mul(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        let (r, o) = self.overflowing_mul(other);
        if o {
            unsafe sc_int_overflow("attempt to multiply with overflow".ptr());
        }
        return r;
    }
}

/// `From<u64>` is what lets a `UInt<BITS>` stand where the built-in integers do: an integer literal or a
/// `u64` value converts implicitly at an assignment, an argument or an operand, exactly as a narrower
/// built-in widens to a wider one.
extend<const BITS: usize> UInt<BITS> as From<u64> {
    pub fn from(v: u64) UInt<BITS> {
        return UInt::<BITS>::from_u64(v);
    }
}

extend<const BITS: usize> UInt<BITS> as BitAnd {
    type Output = UInt<BITS>;

    pub fn bit_and(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        return UInt::<BITS> { bits: self.bits.bit_and(&other.bits) };
    }
}

extend<const BITS: usize> UInt<BITS> as BitOr {
    type Output = UInt<BITS>;

    pub fn bit_or(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        return UInt::<BITS> { bits: self.bits.bit_or(&other.bits) };
    }
}

extend<const BITS: usize> UInt<BITS> as BitXor {
    type Output = UInt<BITS>;

    pub fn bit_xor(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        return UInt::<BITS> { bits: self.bits.bit_xor(&other.bits) };
    }
}

extend<const BITS: usize> UInt<BITS> as BitNot {
    type Output = UInt<BITS>;

    pub fn bit_not(self: &UInt<BITS>) UInt<BITS> {
        return UInt::<BITS> { bits: self.bits.bit_not() };
    }
}

extend<const BITS: usize> UInt<BITS> as Shl {
    type Output = UInt<BITS>;

    pub fn shl(self: &UInt<BITS>, amount: usize) UInt<BITS> {
        return UInt::<BITS> { bits: self.bits.shl(amount) };
    }
}

/// Logical right shift: the only kind an unsigned value has.
extend<const BITS: usize> UInt<BITS> as Shr {
    type Output = UInt<BITS>;

    pub fn shr(self: &UInt<BITS>, amount: usize) UInt<BITS> {
        return UInt::<BITS> { bits: self.bits.shr_logical(amount) };
    }
}

extend<const BITS: usize> UInt<BITS> as Div {
    type Output = UInt<BITS>;

    pub fn div(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        let mut r = UInt::<BITS>::zero();
        return self.divmod(other, &mut r);
    }
}

extend<const BITS: usize> UInt<BITS> as Rem {
    type Output = UInt<BITS>;

    pub fn rem(self: &UInt<BITS>, other: &UInt<BITS>) UInt<BITS> {
        if other.is_zero() {
            unsafe sc_int_div_zero("attempt to calculate the remainder with a divisor of zero".ptr());
        }
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
        for i in 0..UInt::<BITS>::limbs() {
            h = (h ^ self.bits.get(i)).wrapping_mul(1099511628211u64);
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

// Int<BITS>: the signed view.

/// A two's-complement signed integer `BITS` wide. Overflow traps or wraps with the build profile, exactly
/// as in the built-in signed types; `wrapping_*`, `checked_*` and `saturating_*` give the other answers.
pub struct Int<const BITS: usize> {
    bits: IntBits<BITS>,
}

extend<const BITS: usize> Int<BITS> {
    /// The width in bits.
    pub const fn bits() usize {
        return BITS;
    }

    /// Bytes needed to hold the value: ceil(BITS / 8).
    pub const fn bytes() usize {
        return (BITS + 7) / 8;
    }

    /// 64-bit limbs of storage: ceil(BITS / 64).
    pub const fn limbs() usize {
        return (BITS + 63) / 64;
    }

    const fn from_bits(b: IntBits<BITS>) Int<BITS> {
        return Int::<BITS> { bits: b };
    }

    /// The value 0.
    pub const fn zero() Int<BITS> {
        return Int::<BITS> { bits: IntBits::<BITS>::zero() };
    }

    /// The value 1.
    pub const fn one() Int<BITS> {
        return Int::<BITS> { bits: IntBits::<BITS>::from_u64(1) };
    }

    /// The most negative value: the sign bit alone. Its magnitude has no positive counterpart, which is
    /// what makes `MIN.abs()` and `MIN / -1` overflow.
    pub const fn min() Int<BITS> {
        let mut b = IntBits::<BITS>::zero();
        b.set_bit(BITS - 1, true);
        return Int::<BITS> { bits: b };
    }

    /// The largest value.
    pub fn max() Int<BITS> {
        return Int::<BITS> { bits: IntBits::<BITS>::zero().bit_not().shr_logical(1) };
    }

    /// Sign-extended from a 64-bit value, so a negative one stays negative at any width.
    pub fn from_i64(v: i64) Int<BITS> {
        let mut b = IntBits::<BITS>::from_u64(v as u64);
        if v < 0 {
            for i in 1..(BITS + 63) / 64 {
                b.set(i, 0xFFFFFFFFFFFFFFFF);
            }
        }
        return Int::<BITS> { bits: b };
    }

    /// The low 64 bits as a signed value, discarding the rest; a width below 64 sign-extends from its
    /// own top bit, so the value survives the trip.
    pub const fn to_i64(self: &Int<BITS>) i64 {
        if BITS < 64 {
            let sh = (64 - BITS) as u64;
            return (self.bits.get(0) << sh) as i64 >> sh as i64;
        }
        return self.bits.get(0) as i64;
    }

    /// Limb `i` (little-endian); `i` must be below `limbs()`.
    pub const fn limb(self: &Int<BITS>, i: usize) u64 {
        return self.bits.get(i);
    }

    /// Overwrite limb `i`; bits past the width are masked off.
    pub const fn set_limb(self: &mut Int<BITS>, i: usize, v: u64) {
        self.bits.set(i, v);
    }

    /// True when every bit is clear.
    pub fn is_zero(self: &Int<BITS>) bool {
        return self.bits.is_zero();
    }

    /// The sign bit: the top bit of the top limb.
    pub const fn is_negative(self: &Int<BITS>) bool {
        return self.bits.bit(BITS - 1) != 0;
    }

    /// True when bit `i` (0 = least significant) is set; `i` must be below BITS.
    pub const fn bit(self: &Int<BITS>, i: usize) bool {
        return self.bits.bit(i) != 0;
    }

    /// Number of set bits.
    pub fn count_ones(self: &Int<BITS>) usize {
        return self.to_unsigned().count_ones();
    }

    /// Number of clear bits.
    pub fn count_zeros(self: &Int<BITS>) usize {
        return BITS - self.count_ones();
    }

    /// Zero bits above the most significant set bit (BITS for zero).
    pub fn leading_zeros(self: &Int<BITS>) usize {
        return self.to_unsigned().leading_zeros();
    }

    /// Zero bits below the least significant set bit (BITS for zero).
    pub fn trailing_zeros(self: &Int<BITS>) usize {
        return self.to_unsigned().trailing_zeros();
    }

    /// Bits rotated left by `amount` modulo BITS.
    pub fn rotate_left(self: &Int<BITS>, amount: usize) Int<BITS> {
        let u = self.to_unsigned().rotate_left(amount);
        return Int::<BITS>::from_unsigned(&u);
    }

    /// Bits rotated right by `amount` modulo BITS.
    pub fn rotate_right(self: &Int<BITS>, amount: usize) Int<BITS> {
        let u = self.to_unsigned().rotate_right(amount);
        return Int::<BITS>::from_unsigned(&u);
    }

    /// Byte order reversed over the `bytes()` storage bytes.
    pub fn swap_bytes(self: &Int<BITS>) Int<BITS> {
        let u = self.to_unsigned().swap_bytes();
        return Int::<BITS>::from_unsigned(&u);
    }

    /// Bit order reversed over the full width.
    pub fn reverse_bits(self: &Int<BITS>) Int<BITS> {
        let u = self.to_unsigned().reverse_bits();
        return Int::<BITS>::from_unsigned(&u);
    }

    /// -1, 0 or 1 by the value's sign.
    pub fn signum(self: &Int<BITS>) Int<BITS> {
        if self.is_negative() {
            return Int::<BITS>::from_i64(-1);
        }
        if self.is_zero() {
            return Int::<BITS>::zero();
        }
        return Int::<BITS>::one();
    }

    /// |self - other| as the UNSIGNED width: the true distance always fits there, which is exactly
    /// what a signed return could not promise (MIN.abs_diff(MAX) is one past the signed top).
    pub fn abs_diff(self: &Int<BITS>, other: &Int<BITS>) UInt<BITS> {
        if self.cmp(other) >= 0 {
            return self.wrapping_sub(other).to_unsigned();
        }
        return other.wrapping_sub(self).to_unsigned();
    }

    /// The widening conversion between widths, SIGN-EXTENDING: the source's sign fills every limb above
    /// it, so a negative value stays the same number. Applied implicitly, as the built-in signed types are.
    pub fn widen<const M: usize>(v: &Int<M>) Int<BITS> {
        static_assert(M <= BITS, "widen: the target must be at least as wide as the source");
        let mut r = Int::<BITS>::zero();
        let fill = if v.is_negative() {
            0xFFFFFFFFFFFFFFFFu64;
        } else {
            0u64;
        };
        for i in 0..Int::<BITS>::limbs() {
            if i < (M + 63) / 64 {
                r.set_limb(i, v.limb(i));
            } else {
                r.set_limb(i, fill);
            }
        }
        if fill != 0 && M % 64 != 0 && M < BITS {
            r.set_limb(M / 64, v.limb(M / 64) | fill << (M % 64) as u64);
        }
        return r;
    }

    /// The value as a double, through the magnitude: MIN needs no special case, because negating it
    /// wraps back to itself and its unsigned reading IS the magnitude.
    pub fn to_f64(self: &Int<BITS>) f64 {
        if self.is_negative() {
            return 0.0 - self.wrapping_neg().to_unsigned().to_f64();
        }
        return self.to_unsigned().to_f64();
    }

    /// Nearest f32 (round-to-nearest-even; huge values become infinity).
    pub fn to_f32(self: &Int<BITS>) f32 {
        if self.is_negative() {
            return 0.0f32 - self.wrapping_neg().to_unsigned().to_f32();
        }
        return self.to_unsigned().to_f32();
    }

    /// The integer part of a double, SATURATING at min()/max(); NaN gives zero.
    pub fn from_f64(v: f64) Int<BITS> {
        if !(v == v) {
            return Int::<BITS>::zero();
        }
        let lim = UInt::<BITS>::one().shl(BITS - 1);
        if v < 0.0 {
            let mag = UInt::<BITS>::from_f64(0.0 - v);
            if mag > lim {
                return Int::<BITS>::min();
            }
            // Magnitude 2^(BITS-1) reads as MIN unsigned, and negating MIN wraps back to MIN: exact.
            return Int::<BITS>::from_unsigned(&mag).wrapping_neg();
        }
        let mag = UInt::<BITS>::from_f64(v);
        if !(mag < lim) {
            return Int::<BITS>::max();
        }
        return Int::<BITS>::from_unsigned(&mag);
    }

    /// `expr as iN`, with C's cast semantics: truncate when narrower, extend per the SOURCE's
    /// signedness when wider. Named by source rather than overloaded so the two monomorphize to
    /// distinct symbols; not applied implicitly.
    pub fn cast_signed<const M: usize>(v: &Int<M>) Int<BITS> {
        let fill = if v.is_negative() {
            0xFFFFFFFFFFFFFFFFu64;
        } else {
            0u64;
        };
        let mut r = Int::<BITS>::zero();
        for i in 0..Int::<BITS>::limbs() {
            if i < (M + 63) / 64 {
                r.set_limb(i, v.limb(i));
            } else {
                r.set_limb(i, fill);
            }
        }
        if fill != 0 && M % 64 != 0 && M < BITS {
            r.set_limb(M / 64, v.limb(M / 64) | fill << (M % 64) as u64);
        }
        return r;
    }

    /// Zero-extend or truncate a UInt<M> into this width.
    pub fn cast_unsigned<const M: usize>(v: &UInt<M>) Int<BITS> {
        let mut r = Int::<BITS>::zero();
        for i in 0..Int::<BITS>::limbs() {
            if i < (M + 63) / 64 {
                r.set_limb(i, v.limb(i));
            }
        }
        return r;
    }

    /// The same bits read as unsigned: a negative value becomes its two's-complement magnitude.
    pub const fn to_unsigned(self: &Int<BITS>) UInt<BITS> {
        return UInt::<BITS>::from_bits(self.bits);
    }

    /// Reinterpret the bits of a same-width UInt.
    pub const fn from_unsigned(v: &UInt<BITS>) Int<BITS> {
        return Int::<BITS>::from_bits(v.raw());
    }

    // The limb code is the unsigned one: two's complement makes these bit-identical.

    /// Addition modulo 2^BITS.
    pub fn wrapping_add(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        let mut c: u64 = 0;
        return Int::<BITS> { bits: self.bits.add_carry(&other.bits, &mut c) };
    }

    /// Subtraction modulo 2^BITS.
    pub fn wrapping_sub(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        let mut b: u64 = 0;
        return Int::<BITS> { bits: self.bits.sub_borrow(&other.bits, &mut b) };
    }

    /// Multiplication modulo 2^BITS.
    pub fn wrapping_mul(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        let mut o = false;
        return Int::<BITS> { bits: self.bits.mul_wrap(&other.bits, &mut o) };
    }

    /// Two's-complement negation modulo 2^BITS.
    pub fn wrapping_neg(self: &Int<BITS>) Int<BITS> {
        return Int::<BITS> { bits: self.bits.negate() };
    }

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

    /// The negation, or None for MIN.
    pub fn checked_neg(self: &Int<BITS>) Option<Int<BITS>> {
        let mn = Int::<BITS>::min();
        if self.eq(&mn) {
            // MIN has no positive counterpart.
            return Option::<Int<BITS>>::None;
        }
        return Option::<Int<BITS>>::Some(self.wrapping_neg());
    }

    /// The product, or None on overflow.
    pub fn checked_mul(self: &Int<BITS>, other: &Int<BITS>) Option<Int<BITS>> {
        let mut over = false;
        let r = self.mul_over(other, &mut over);
        if over {
            return Option::<Int<BITS>>::None;
        }
        return Option::<Int<BITS>>::Some(r);
    }

    // The wrapped product and whether it overflowed, from one multiplication of the magnitudes: their
    // unsigned product must not overflow, and a nonzero result must carry the expected sign (a positive
    // product below 2^(BITS-1), a negative one at most that). The wrapped magnitude product, negated
    // for a negative result, is the wrapped signed product.
    fn mul_over(self: &Int<BITS>, other: &Int<BITS>, overflow: *mut bool) Int<BITS> {
        let neg = self.is_negative() != other.is_negative();
        // Two's-complement magnitudes: MIN's is 2^(BITS-1), which the unsigned reading holds exactly.
        let ma = if self.is_negative() {
            self.wrapping_neg();
        } else {
            *self;
        };
        let mb = if other.is_negative() {
            other.wrapping_neg();
        } else {
            *other;
        };
        let mut over = false;
        let mut r = Int::<BITS> { bits: ma.bits.mul_wrap(&mb.bits, &mut over) };
        if neg {
            r = r.wrapping_neg();
        }
        unsafe *overflow = over || !r.is_zero() && r.is_negative() != neg;
        return r;
    }

    /// The sum, clamped to the range.
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

    /// The difference, clamped to the range.
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

    /// The product, clamped to the range.
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

    /// The wrapped sum and whether it overflowed.
    pub fn overflowing_add(self: &Int<BITS>, other: &Int<BITS>) (Int<BITS>, bool) {
        let r = self.wrapping_add(other);
        let sa = self.is_negative();
        return r, sa == other.is_negative() && r.is_negative() != sa;
    }

    /// The wrapped difference and whether it overflowed.
    pub fn overflowing_sub(self: &Int<BITS>, other: &Int<BITS>) (Int<BITS>, bool) {
        let r = self.wrapping_sub(other);
        let sa = self.is_negative();
        return r, sa != other.is_negative() && r.is_negative() != sa;
    }

    /// The wrapped product and whether it overflowed.
    pub fn overflowing_mul(self: &Int<BITS>, other: &Int<BITS>) (Int<BITS>, bool) {
        let mut over = false;
        let r = self.mul_over(other, &mut over);
        return r, over;
    }

    /// Exponentiation by squaring. Overflow traps or wraps like the signed operators; `checked_pow`
    /// reports it instead.
    pub fn pow(self: &Int<BITS>, exp: u32) Int<BITS> {
        switch self.checked_pow(exp) {
            Some(v) => {
                return v;
            },
            None => {
                unsafe sc_int_overflow("attempt to multiply with overflow".ptr());
                // Two's complement: the unsigned power has the wrapped bits.
                let u = self.to_unsigned().wrapping_pow(exp);
                return Int::<BITS>::from_unsigned(&u);
            },
        };
    }

    /// `self` to the power `exp`, or None on overflow.
    pub fn checked_pow(self: &Int<BITS>, exp: u32) Option<Int<BITS>> {
        let mut acc = Int::<BITS>::one();
        let mut base = *self;
        let mut e = exp;
        while e != 0 {
            if (e & 1) != 0 {
                switch acc.checked_mul(&base) {
                    Some(v) => {
                        acc = v;
                    },
                    None => {
                        return Option::<Int<BITS>>::None;
                    },
                };
            }
            e = e >> 1;
            if e == 0 {
                // The last squaring feeds nothing: its overflow would be a false alarm.
                break;
            }
            switch base.checked_mul(&base) {
                Some(v) => {
                    base = v;
                },
                None => {
                    return Option::<Int<BITS>>::None;
                },
            };
        }
        return Option::<Int<BITS>>::Some(acc);
    }

    /// Magnitude. MIN, whose magnitude is one past the top of the range, overflows as `-MIN` does: a trap
    /// with overflow checks, MIN itself without.
    pub fn abs(self: &Int<BITS>) Int<BITS> {
        if !self.is_negative() {
            return *self;
        }
        switch self.checked_neg() {
            Some(v) => {
                return v;
            },
            None => {
                unsafe sc_int_overflow("attempt to negate with overflow".ptr());
                return *self;
            },
        };
    }

    /// Truncating division, with the remainder taking the DIVIDEND's sign: C's rule, and the built-in
    /// signed types'. Panics on a zero divisor, and on MIN / -1, whose quotient is out of range.
    pub fn divmod(self: &Int<BITS>, other: &Int<BITS>, rem: &mut Int<BITS>) Int<BITS> {
        if other.is_zero() {
            unsafe sc_int_div_zero("attempt to divide by zero".ptr());
        }
        if self.is_min_by_neg1(other) {
            unsafe sc_int_div_overflow("attempt to divide with overflow".ptr());
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
        *rem = r;
        return q;
    }

    // MIN / -1 and MIN % -1: the quotient is out of range.
    fn is_min_by_neg1(self: &Int<BITS>, other: &Int<BITS>) bool {
        let mn = Int::<BITS>::min();
        let neg1 = Int::<BITS>::from_i64(-1);
        return self.eq(&mn) && other.eq(&neg1);
    }

    // The traps of the built-in `%`, whose messages differ from `/`'s (divmod's).
    fn rem_traps(self: &Int<BITS>, other: &Int<BITS>) {
        if other.is_zero() {
            unsafe sc_int_div_zero("attempt to calculate the remainder with a divisor of zero".ptr());
        }
        if self.is_min_by_neg1(other) {
            unsafe sc_int_div_overflow("attempt to calculate the remainder with overflow".ptr());
        }
    }

    /// The quotient (toward zero), or None for a zero divisor or MIN / -1.
    pub fn checked_div(self: &Int<BITS>, other: &Int<BITS>) Option<Int<BITS>> {
        if other.is_zero() || self.is_min_by_neg1(other) {
            return Option::<Int<BITS>>::None;
        }
        let mut r = Int::<BITS>::zero();
        return Option::<Int<BITS>>::Some(self.divmod(other, &mut r));
    }

    /// The remainder (sign of the dividend), or None for a zero divisor or MIN / -1.
    pub fn checked_rem(self: &Int<BITS>, other: &Int<BITS>) Option<Int<BITS>> {
        if other.is_zero() || self.is_min_by_neg1(other) {
            return Option::<Int<BITS>>::None;
        }
        let mut r = Int::<BITS>::zero();
        let _ = self.divmod(other, &mut r);
        return Option::<Int<BITS>>::Some(r);
    }

    /// Euclidean division: the remainder is always in [0, |divisor|), so the quotient rounds toward
    /// negative infinity for a positive divisor: what modular index arithmetic wants, and what
    /// truncating `/` refuses to promise for negative operands. Panics exactly where `/` does.
    pub fn div_euclid(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        let mut r = Int::<BITS>::zero();
        let q = self.divmod(other, &mut r);
        if r.is_negative() {
            // The adjusted quotient stays in range: it moves toward zero for a negative divisor, and
            // the one case a +1 could overflow (MIN / -1) already panicked inside divmod.
            let one = Int::<BITS>::one();
            if other.is_negative() {
                return q.wrapping_add(&one);
            }
            return q.wrapping_sub(&one);
        }
        return q;
    }

    /// The non-negative remainder. Panics: zero divisor, MIN % -1.
    pub fn rem_euclid(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        self.rem_traps(other);
        let mut r = Int::<BITS>::zero();
        let _ = self.divmod(other, &mut r);
        if r.is_negative() {
            if other.is_negative() {
                return r.wrapping_sub(other);
            }
            return r.wrapping_add(other);
        }
        return r;
    }

    // The unsigned view's serialization over the same two's-complement bits.

    /// Write the value little-endian into `out`, which must hold `bytes()` bytes.
    pub fn to_le_bytes(self: &Int<BITS>, out: []mut u8) {
        self.to_unsigned().to_le_bytes(out);
    }

    /// The value of little-endian bytes `b` (short input is zero-extended, extra bytes ignored).
    pub fn from_le_bytes(b: []u8) Int<BITS> {
        let u = UInt::<BITS>::from_le_bytes(b);
        return Int::<BITS>::from_unsigned(&u);
    }

    /// Write the value big-endian into `out`, which must hold `bytes()` bytes.
    pub fn to_be_bytes(self: &Int<BITS>, out: []mut u8) {
        self.to_unsigned().to_be_bytes(out);
    }

    /// The value of big-endian bytes `b` (short input is zero-extended, extra bytes ignored).
    pub fn from_be_bytes(b: []u8) Int<BITS> {
        let u = UInt::<BITS>::from_be_bytes(b);
        return Int::<BITS>::from_unsigned(&u);
    }

    /// The decimal spelling with a leading `-` when negative.
    pub fn to_string(self: &Int<BITS>) String {
        return self.to_string_radix(10);
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
                    // The magnitude overflowed into the sign bit.
                    return Option::<Int<BITS>>::None;
                }
                return Option::<Int<BITS>>::Some(v);
            },
            None => {
                return Option::<Int<BITS>>::None;
            },
        };
    }

    /// The magnitude's digits in any radix from 2 to 36, `-`-prefixed when negative.
    pub fn to_string_radix(self: &Int<BITS>, radix: u32) String {
        if !self.is_negative() {
            return self.to_unsigned().to_string_radix(radix);
        }
        if radix < 2 || radix > 36 {
            panic("radix must be between 2 and 36");
        }
        // The magnitude through the unsigned view: negating MIN wraps back to MIN, whose unsigned
        // reading is exactly the magnitude wanted, so this needs no case of its own.
        let mut out = String::from_str("-");
        self.wrapping_neg().to_unsigned().push_digits(&mut out, radix);
        return out;
    }

    /// Parse an optionally signed value in any radix from 2 to 36; the same range rules as `from_str`.
    pub fn from_str_radix(s: str, radix: u32) Option<Int<BITS>> {
        if s.len() == 0 {
            return Option::<Int<BITS>>::None;
        }
        let neg = s.byte_at(0) == b'-';
        let body = if neg || s.byte_at(0) == b'+' {
            s.slice(1, s.len());
        } else {
            s;
        };
        switch UInt::<BITS>::from_str_radix(body, radix) {
            Some(u) => {
                let v = Int::<BITS>::from_unsigned(&u);
                if neg {
                    let mn = Int::<BITS>::min();
                    if v.is_negative() && !v.eq(&mn) {
                        return Option::<Int<BITS>>::None;
                    }
                    return Option::<Int<BITS>>::Some(v.wrapping_neg());
                }
                if v.is_negative() {
                    // The magnitude overflowed into the sign bit.
                    return Option::<Int<BITS>>::None;
                }
                return Option::<Int<BITS>>::Some(v);
            },
            None => {
                return Option::<Int<BITS>>::None;
            },
        };
    }
}

// Operators. `+`, `-` and `*` trap or wrap on overflow with the build profile, and `/` and `%` trap on MIN / -1,
// which is what the built-in signed types do.
extend<const BITS: usize> Int<BITS> as Add {
    type Output = Int<BITS>;

    pub fn add(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        switch self.checked_add(other) {
            Some(v) => {
                return v;
            },
            None => {
                unsafe sc_int_overflow("attempt to add with overflow".ptr());
                return self.wrapping_add(other);
            },
        };
    }
}

extend<const BITS: usize> Int<BITS> as Sub {
    type Output = Int<BITS>;

    pub fn sub(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        switch self.checked_sub(other) {
            Some(v) => {
                return v;
            },
            None => {
                unsafe sc_int_overflow("attempt to subtract with overflow".ptr());
                return self.wrapping_sub(other);
            },
        };
    }
}

extend<const BITS: usize> Int<BITS> as Mul {
    type Output = Int<BITS>;

    pub fn mul(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        let mut over = false;
        let r = self.mul_over(other, &mut over);
        if over {
            unsafe sc_int_overflow("attempt to multiply with overflow".ptr());
        }
        return r;
    }
}

/// The signed counterpart: an integer literal or an `i64` value converts implicitly.
extend<const BITS: usize> Int<BITS> as From<i64> {
    pub fn from(v: i64) Int<BITS> {
        return Int::<BITS>::from_i64(v);
    }
}

extend<const BITS: usize> Int<BITS> as BitAnd {
    type Output = Int<BITS>;

    pub fn bit_and(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        return Int::<BITS> { bits: self.bits.bit_and(&other.bits) };
    }
}

extend<const BITS: usize> Int<BITS> as BitOr {
    type Output = Int<BITS>;

    pub fn bit_or(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        return Int::<BITS> { bits: self.bits.bit_or(&other.bits) };
    }
}

extend<const BITS: usize> Int<BITS> as BitXor {
    type Output = Int<BITS>;

    pub fn bit_xor(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        return Int::<BITS> { bits: self.bits.bit_xor(&other.bits) };
    }
}

extend<const BITS: usize> Int<BITS> as BitNot {
    type Output = Int<BITS>;

    pub fn bit_not(self: &Int<BITS>) Int<BITS> {
        return Int::<BITS> { bits: self.bits.bit_not() };
    }
}

extend<const BITS: usize> Int<BITS> as Shl {
    type Output = Int<BITS>;

    pub fn shl(self: &Int<BITS>, amount: usize) Int<BITS> {
        return Int::<BITS> { bits: self.bits.shl(amount) };
    }
}

/// Arithmetic right shift: the sign is what fills the top, so shifting a negative value keeps it negative
/// and rounds toward negative infinity.
extend<const BITS: usize> Int<BITS> as Shr {
    type Output = Int<BITS>;

    pub fn shr(self: &Int<BITS>, amount: usize) Int<BITS> {
        return Int::<BITS> { bits: self.bits.shr_arith(amount) };
    }
}

extend<const BITS: usize> Int<BITS> as Div {
    type Output = Int<BITS>;

    pub fn div(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        let mut r = Int::<BITS>::zero();
        return self.divmod(other, &mut r);
    }
}

extend<const BITS: usize> Int<BITS> as Rem {
    type Output = Int<BITS>;

    pub fn rem(self: &Int<BITS>, other: &Int<BITS>) Int<BITS> {
        self.rem_traps(other);
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
        for i in 0..Int::<BITS>::limbs() {
            h = (h ^ self.bits.get(i)).wrapping_mul(1099511628211u64);
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

// The named widths
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
