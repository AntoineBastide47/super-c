// Secret values for constant-time code. A `Secret<T>` holds a value whose bits no branch, memory address
// or variable-time operation may depend on: the build checks the code it generates for each function that
// reads one, which must be `@constant_time` (`lir::ct`). The methods here are the only operations on the
// value. Each one is branch-free, wraps where an integer operator would trap, and is `@constant_time` when
// it reads a secret; a secret goes from one function to another only inside a `Secret`, never as a bare
// integer. `declassify` gives the value back.

/// A value that constant-time code computes on without revealing it through its timing. A buffer of
/// secret bytes is `[]Secret<u8>`: its length is public, its elements secret.
pub struct Secret<T> {
    v: T,
}

/// A type a `Secret` holds: `u8`, `u16`, `u32`, `u64`, `usize` or `bool`. Only this module implements
/// it.
pub interface SecretWord: Copy {
    /// The width in bits (`bool`: 1).
    fn word_bits() u32;
    /// `s` zero-extended to 64 bits.
    fn widen(s: Secret<Self>) Secret<u64>;
    /// The low `word_bits()` bits of `w`.
    fn narrow(w: Secret<u64>) Secret<Self>;
}

/// An unsigned integer type a `Secret` holds: `u8`, `u16`, `u32`, `u64` or `usize`. Only this module
/// implements it.
pub interface SecretInt: SecretWord {}

extern "C" {
    fn sc_wadd64(a: u64, b: u64) u64;
    fn sc_wsub64(a: u64, b: u64) u64;
    fn sc_wmul64(a: u64, b: u64) u64;
    fn sc_wshl64(a: u64, n: u32) u64;
    fn sc_wshr64(a: u64, n: u32) u64;
}

@intrinsic("secret.declassify")
const fn reveal<T>(x: T) T;

extend<T: SecretWord> Secret<T> {
    /// `x` as a secret.
    pub const fn new(x: T) Secret<T> {
        return Secret::<T> { v: x };
    }

    /// The value, for proofs: the prover gives each method its meaning on it (`add` wraps, `pick`
    /// selects, ...), so a specification states what a function on secrets computes.
    pub spec fn value(self: Secret<T>) T {
        return self.v;
    }

    /// The value, which no check counts as secret from here on: the one way out of a `Secret`.
    @constant_time
    pub const fn declassify(self: Secret<T>) T {
        return reveal(self.v);
    }

    /// Whether `self` and `other` are equal.
    @constant_time
    pub fn eq(self: Secret<T>, other: Secret<T>) Secret<bool> {
        let a = T::widen(self);
        let b = T::widen(other);
        let z = is_zero(Secret::<u64> { v: a.v ^ b.v });
        return bool::narrow(z);
    }

    /// Whether `self` and `other` differ.
    @constant_time
    pub fn ne(self: Secret<T>, other: Secret<T>) Secret<bool> {
        let a = T::widen(self);
        let b = T::widen(other);
        let z = is_zero(Secret::<u64> { v: a.v ^ b.v });
        return bool::narrow(Secret::<u64> { v: z.v ^ 1 });
    }

    /// `a` where `c` is true, else `b`.
    @constant_time
    pub fn pick(c: Secret<bool>, a: Secret<T>, b: Secret<T>) Secret<T> {
        let m = unsafe sc_wsub64(0, bool::widen(c).v);
        let x = T::widen(a);
        let y = T::widen(b);
        return T::narrow(Secret::<u64> { v: x.v & m | y.v & ~m });
    }
}

extend<T: SecretInt> Secret<T> {
    /// Whether `self < other`.
    @constant_time
    pub fn lt(self: Secret<T>, other: Secret<T>) Secret<bool> {
        let l = less(T::widen(self), T::widen(other));
        return bool::narrow(l);
    }

    /// Whether `self <= other`.
    @constant_time
    pub fn le(self: Secret<T>, other: Secret<T>) Secret<bool> {
        let l = less(T::widen(other), T::widen(self));
        return bool::narrow(Secret::<u64> { v: l.v ^ 1 });
    }

    /// Whether `self > other`.
    @constant_time
    pub fn gt(self: Secret<T>, other: Secret<T>) Secret<bool> {
        let l = less(T::widen(other), T::widen(self));
        return bool::narrow(l);
    }

    /// Whether `self >= other`.
    @constant_time
    pub fn ge(self: Secret<T>, other: Secret<T>) Secret<bool> {
        let l = less(T::widen(self), T::widen(other));
        return bool::narrow(Secret::<u64> { v: l.v ^ 1 });
    }

    /// The bits rotated left by `n` modulo the width.
    @constant_time
    pub fn rotate_left(self: Secret<T>, n: u32) Secret<T> {
        let b = T::word_bits();
        let k = n % b;
        let w = T::widen(self).v;
        return T::narrow(Secret::<u64> { v: unsafe sc_wshl64(w, k) | unsafe sc_wshr64(w, (b - k) % b) });
    }

    /// The bits rotated right by `n` modulo the width.
    @constant_time
    pub fn rotate_right(self: Secret<T>, n: u32) Secret<T> {
        let b = T::word_bits();
        return self.rotate_left((b - n % b) % b);
    }

    /// The value in `U`: zero-extended, or truncated to `U`'s width.
    @constant_time
    pub fn cast<U: SecretInt>(self: Secret<T>) Secret<U> {
        let w = T::widen(self);
        return U::narrow(w);
    }
}

// 1 when `w` is 0, else 0: `w | -w` has its top bit set exactly when `w` is not 0.
@constant_time
const fn is_zero(w: Secret<u64>) Secret<u64> {
    let x = w.v;
    return Secret::<u64> { v: (x | unsafe sc_wsub64(0, x)) >> 63 ^ 1 };
}

// 1 when `x < y` as unsigned 64-bit words, else 0 (Hacker's Delight, 2-12).
@constant_time
const fn less(x: Secret<u64>, y: Secret<u64>) Secret<u64> {
    let a = x.v;
    let b = y.v;
    return Secret::<u64> { v: (~a & b | ~(a ^ b) & unsafe sc_wsub64(a, b)) >> 63 };
}

extend<T: SecretInt> Secret<T> as Add {
    type Output = Secret<T>;

    /// `self + other` modulo 2^N, N the width.
    @constant_time
    pub fn add(self: &Secret<T>, other: &Secret<T>) Secret<T> {
        return T::narrow(Secret::<u64> { v: unsafe sc_wadd64(T::widen(*self).v, T::widen(*other).v) });
    }
}

extend<T: SecretInt> Secret<T> as Sub {
    type Output = Secret<T>;

    /// `self - other` modulo 2^N.
    @constant_time
    pub fn sub(self: &Secret<T>, other: &Secret<T>) Secret<T> {
        return T::narrow(Secret::<u64> { v: unsafe sc_wsub64(T::widen(*self).v, T::widen(*other).v) });
    }
}

extend<T: SecretInt> Secret<T> as Mul {
    type Output = Secret<T>;

    /// `self * other` modulo 2^N.
    @constant_time
    pub fn mul(self: &Secret<T>, other: &Secret<T>) Secret<T> {
        return T::narrow(Secret::<u64> { v: unsafe sc_wmul64(T::widen(*self).v, T::widen(*other).v) });
    }
}

extend<T: SecretInt> Secret<T> as Neg {
    type Output = Secret<T>;

    /// `-self` modulo 2^N.
    @constant_time
    pub fn neg(self: &Secret<T>) Secret<T> {
        return T::narrow(Secret::<u64> { v: unsafe sc_wsub64(0, T::widen(*self).v) });
    }
}

extend<T: SecretWord> Secret<T> as BitAnd {
    type Output = Secret<T>;

    @constant_time
    pub fn bit_and(self: &Secret<T>, other: &Secret<T>) Secret<T> {
        return T::narrow(Secret::<u64> { v: T::widen(*self).v & T::widen(*other).v });
    }
}

extend<T: SecretWord> Secret<T> as BitOr {
    type Output = Secret<T>;

    @constant_time
    pub fn bit_or(self: &Secret<T>, other: &Secret<T>) Secret<T> {
        return T::narrow(Secret::<u64> { v: T::widen(*self).v | T::widen(*other).v });
    }
}

extend<T: SecretWord> Secret<T> as BitXor {
    type Output = Secret<T>;

    @constant_time
    pub fn bit_xor(self: &Secret<T>, other: &Secret<T>) Secret<T> {
        return T::narrow(Secret::<u64> { v: T::widen(*self).v ^ T::widen(*other).v });
    }
}

extend<T: SecretWord> Secret<T> as BitNot {
    type Output = Secret<T>;

    /// Each bit inverted (`bool`: the negation).
    @constant_time
    pub fn bit_not(self: &Secret<T>) Secret<T> {
        return T::narrow(Secret::<u64> { v: ~T::widen(*self).v });
    }
}

extend<T: SecretInt> Secret<T> as Shl {
    type Output = Secret<T>;

    /// `self << amount`; `amount`, which is public, must be below the width.
    @constant_time
    pub fn shl(self: &Secret<T>, amount: usize) Secret<T> {
        assert(amount < T::word_bits() as usize, "Secret: shift amount out of range");
        return T::narrow(Secret::<u64> { v: unsafe sc_wshl64(T::widen(*self).v, amount as u32) });
    }
}

extend<T: SecretInt> Secret<T> as Shr {
    type Output = Secret<T>;

    /// `self >> amount`, a logical shift; `amount`, which is public, must be below the width.
    @constant_time
    pub fn shr(self: &Secret<T>, amount: usize) Secret<T> {
        assert(amount < T::word_bits() as usize, "Secret: shift amount out of range");
        return T::narrow(Secret::<u64> { v: unsafe sc_wshr64(T::widen(*self).v, amount as u32) });
    }
}

extend u8 as SecretWord {
    pub fn word_bits() u32 {
        return 8;
    }

    @constant_time
    pub fn widen(s: Secret<u8>) Secret<u64> {
        return Secret::<u64> { v: s.v };
    }

    @constant_time
    pub fn narrow(w: Secret<u64>) Secret<u8> {
        return Secret::<u8> { v: w.v as u8 };
    }
}

extend u16 as SecretWord {
    pub fn word_bits() u32 {
        return 16;
    }

    @constant_time
    pub fn widen(s: Secret<u16>) Secret<u64> {
        return Secret::<u64> { v: s.v };
    }

    @constant_time
    pub fn narrow(w: Secret<u64>) Secret<u16> {
        return Secret::<u16> { v: w.v as u16 };
    }
}

extend u32 as SecretWord {
    pub fn word_bits() u32 {
        return 32;
    }

    @constant_time
    pub fn widen(s: Secret<u32>) Secret<u64> {
        return Secret::<u64> { v: s.v };
    }

    @constant_time
    pub fn narrow(w: Secret<u64>) Secret<u32> {
        return Secret::<u32> { v: w.v as u32 };
    }
}

extend u64 as SecretWord {
    pub fn word_bits() u32 {
        return 64;
    }

    @constant_time
    pub fn widen(s: Secret<u64>) Secret<u64> {
        return Secret::<u64> { v: s.v };
    }

    @constant_time
    pub fn narrow(w: Secret<u64>) Secret<u64> {
        return Secret::<u64> { v: w.v };
    }
}

extend usize as SecretWord {
    pub fn word_bits() u32 {
        return (sizeof(usize) * 8) as u32;
    }

    @constant_time
    pub fn widen(s: Secret<usize>) Secret<u64> {
        return Secret::<u64> { v: s.v as u64 };
    }

    @constant_time
    pub fn narrow(w: Secret<u64>) Secret<usize> {
        return Secret::<usize> { v: w.v as usize };
    }
}

extend bool as SecretWord {
    pub fn word_bits() u32 {
        return 1;
    }

    @constant_time
    pub fn widen(s: Secret<bool>) Secret<u64> {
        return Secret::<u64> { v: s.v as u64 };
    }

    @constant_time
    pub fn narrow(w: Secret<u64>) Secret<bool> {
        return Secret::<bool> { v: (w.v & 1) != 0 };
    }
}

extend u8 as SecretInt {}

extend u16 as SecretInt {}

extend u32 as SecretInt {}

extend u64 as SecretInt {}

extend usize as SecretInt {}
