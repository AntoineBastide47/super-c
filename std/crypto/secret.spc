// Secret values for constant-time code. A `Secret<T>` holds a value whose bits no branch, memory address
// or variable-time operation may depend on: the build checks the code it generates for each function that
// reads one, which must be `@constant_time` (`lir::ct`). The methods here, and the processor's hash
// instructions over groups of secret words below, are the only operations on the value. Each one is
// branch-free, wraps where an integer operator would trap, and is `@constant_time` when it reads a secret;
// a secret goes from one function to another only inside a `Secret`, never as a bare integer.
// `declassify` gives the value back.
import std::cpu;
import arm_neon;
import immintrin;

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

// ---- SHA-256 instructions ----
//
// Each instruction takes and gives groups of four secret words, a vector register's lanes from lane 0.
// Its `ensures` is the vendor's pseudocode of the instruction (Arm's shared pseudocode `SHA256hash`,
// `SHA256SU0`, `SHA256SU1`; Intel's SHA256RNDS2, SHA256MSG1, SHA256MSG2), which the processor computes and
// no proof checks (`@trusted`). Both vendors list them as data-independent in time (Arm's DIT, Intel's
// DOIT).

/// The values of four secret words.
pub spec fn words4(x: [Secret<u32>; 4]) [u32; 4] {
    return [x[0].v, x[1].v, x[2].v, x[3].v];
}

// The functions of Arm's pseudocode (`SHAchoose`, `SHAmajority`, `SHAhashSIGMA0`, `SHAhashSIGMA1`) and of
// Intel's (`Ch`, `Maj`, the sigmas).
spec fn sha_choose(x: u32, y: u32, z: u32) u32 {
    return (y ^ z) & x ^ z;
}

spec fn sha_majority(x: u32, y: u32, z: u32) u32 {
    return x & y | (x | y) & z;
}

spec fn sha_ch(e: u32, f: u32, g: u32) u32 {
    return e & f ^ ~e & g;
}

spec fn sha_maj(a: u32, b: u32, c: u32) u32 {
    return a & b ^ a & c ^ b & c;
}

spec fn hash_sigma0(x: u32) u32 {
    return x.rotate_right(2) ^ x.rotate_right(13) ^ x.rotate_right(22);
}

spec fn hash_sigma1(x: u32) u32 {
    return x.rotate_right(6) ^ x.rotate_right(11) ^ x.rotate_right(25);
}

spec fn sched_sigma0(x: u32) u32 {
    return x.rotate_right(7) ^ x.rotate_right(18) ^ x >> 3;
}

spec fn sched_sigma1(x: u32) u32 {
    return x.rotate_right(17) ^ x.rotate_right(19) ^ x >> 10;
}

/// One iteration of Arm's `SHA256hash` on `X:Y`, `X` the first four words of `s` and `Y` the last, with
/// the round's word plus constant `wk`: the new `X<127:96>` and `Y<127:96>`, then `ROL(Y:X, 32)`.
pub spec fn arm_sha256_step(s: [u32; 8], wk: u32) [u32; 8] {
    let chs = sha_choose(s[4], s[5], s[6]);
    let maj = sha_majority(s[0], s[1], s[2]);
    let t = s[7].wrapping_add(hash_sigma1(s[4])).wrapping_add(chs).wrapping_add(wk);
    let x3 = t.wrapping_add(s[3]);
    let y3 = t.wrapping_add(hash_sigma0(s[0])).wrapping_add(maj);
    return [y3, s[0], s[1], s[2], x3, s[4], s[5], s[6]];
}

/// Arm's `SHA256hash(X, Y, W, part1)`: four iterations over `W`'s lanes, then `X` when `part1`, else `Y`.
pub spec fn arm_sha256_hash(x: [u32; 4], y: [u32; 4], w: [u32; 4], part1: bool) [u32; 4] {
    let s0: [u32; 8] = [x[0], x[1], x[2], x[3], y[0], y[1], y[2], y[3]];
    let s4 = arm_sha256_step(arm_sha256_step(arm_sha256_step(arm_sha256_step(s0, w[0]), w[1]), w[2]), w[3]);
    return if part1 {
        [s4[0], s4[1], s4[2], s4[3]]
    } else {
        [s4[4], s4[5], s4[6], s4[7]]
    };
}

/// Arm's `SHA256SU0`: operand 1 `d`, operand 2 `n`.
pub spec fn arm_sha256_su0(d: [u32; 4], n: [u32; 4]) [u32; 4] {
    let t: [u32; 4] = [d[1], d[2], d[3], n[0]];
    return [
        sched_sigma0(t[0]).wrapping_add(d[0]),
        sched_sigma0(t[1]).wrapping_add(d[1]),
        sched_sigma0(t[2]).wrapping_add(d[2]),
        sched_sigma0(t[3]).wrapping_add(d[3]),
    ];
}

/// Arm's `SHA256SU1`: operand 1 `d`, operand 2 `n`, operand 3 `m`; lanes 2 and 3 read the result's lanes 0
/// and 1.
pub spec fn arm_sha256_su1(d: [u32; 4], n: [u32; 4], m: [u32; 4]) [u32; 4] {
    let t0: [u32; 4] = [n[1], n[2], n[3], m[0]];
    let r0 = sched_sigma1(m[2]).wrapping_add(d[0]).wrapping_add(t0[0]);
    let r1 = sched_sigma1(m[3]).wrapping_add(d[1]).wrapping_add(t0[1]);
    let r2 = sched_sigma1(r0).wrapping_add(d[2]).wrapping_add(t0[2]);
    let r3 = sched_sigma1(r1).wrapping_add(d[3]).wrapping_add(t0[3]);
    return [r0, r1, r2, r3];
}

/// One round of Intel's SHA256RNDS2 on `A..H` (`s[0]` to `s[7]`) with word plus constant `wk`.
pub spec fn intel_sha256_round(s: [u32; 8], wk: u32) [u32; 8] {
    let t = sha_ch(s[4], s[5], s[6]).wrapping_add(hash_sigma1(s[4])).wrapping_add(wk).wrapping_add(s[7]);
    let a = t.wrapping_add(sha_maj(s[0], s[1], s[2])).wrapping_add(hash_sigma0(s[0]));
    let e = t.wrapping_add(s[3]);
    return [a, s[0], s[1], s[2], e, s[4], s[5], s[6]];
}

/// Intel's SHA256RNDS2 with `cdgh` (SRC1: C, D, G, H in lanes 3 to 0), `abef` (SRC2: A, B, E, F) and
/// `wk` (XMM0, lanes 0 and 1): A, B, E, F after two rounds, in lanes 3 to 0.
pub spec fn intel_sha256_rnds2(cdgh: [u32; 4], abef: [u32; 4], wk: [u32; 4]) [u32; 4] {
    let s0: [u32; 8] = [abef[3], abef[2], cdgh[3], cdgh[2], abef[1], abef[0], cdgh[1], cdgh[0]];
    let s2 = intel_sha256_round(intel_sha256_round(s0, wk[0]), wk[1]);
    return [s2[5], s2[4], s2[1], s2[0]];
}

/// Intel's SHA256MSG1: lane `i` is `x[i] + sigma0(W[i + 1])`, `W` the words of `x` then `y[0]`.
pub spec fn intel_sha256_msg1(x: [u32; 4], y: [u32; 4]) [u32; 4] {
    return [
        x[0].wrapping_add(sched_sigma0(x[1])),
        x[1].wrapping_add(sched_sigma0(x[2])),
        x[2].wrapping_add(sched_sigma0(x[3])),
        x[3].wrapping_add(sched_sigma0(y[0])),
    ];
}

/// Intel's SHA256MSG2: `W16 = x[0] + sigma1(y[2])`, `W17 = x[1] + sigma1(y[3])`, `W18 = x[2] +
/// sigma1(W16)`, `W19 = x[3] + sigma1(W17)`.
pub spec fn intel_sha256_msg2(x: [u32; 4], y: [u32; 4]) [u32; 4] {
    let w16 = x[0].wrapping_add(sched_sigma1(y[2]));
    let w17 = x[1].wrapping_add(sched_sigma1(y[3]));
    return [w16, w17, x[2].wrapping_add(sched_sigma1(w16)), x[3].wrapping_add(sched_sigma1(w17))];
}

/// Four SHA-256 rounds, the new `a, b, c, d` (`SHA256H`): `abcd`, `efgh` and the rounds' words plus
/// constants `wk`.
@trusted
@constant_time
@arch(aarch64)
@target_feature([cpu::Feature::Sha2])
pub fn sha256h(abcd: [Secret<u32>; 4], efgh: [Secret<u32>; 4], wk: [Secret<u32>; 4]) [Secret<u32>; 4]
    ensures |r| words4(r) == arm_sha256_hash(words4(abcd), words4(efgh), words4(wk), true)
{
    let abcd_w: [u32; 4] = [abcd[0].v, abcd[1].v, abcd[2].v, abcd[3].v];
    let efgh_w: [u32; 4] = [efgh[0].v, efgh[1].v, efgh[2].v, efgh[3].v];
    let wk_w: [u32; 4] = [wk[0].v, wk[1].v, wk[2].v, wk[3].v];
    let mut o: [u32; 4] = [0; 4];
    unsafe arm_neon::vst1q_u32(
        &mut o[0],
        arm_neon::vsha256hq_u32(
            unsafe arm_neon::vld1q_u32(&abcd_w[0]),
            unsafe arm_neon::vld1q_u32(&efgh_w[0]),
            unsafe arm_neon::vld1q_u32(&wk_w[0]),
        ),
    );
    return [Secret::<u32> { v: o[0] }, Secret::<u32> { v: o[1] }, Secret::<u32> { v: o[2] }, Secret::<u32> { v: o[3] }];
}

/// Four SHA-256 rounds, the new `e, f, g, h` (`SHA256H2`).
@trusted
@constant_time
@arch(aarch64)
@target_feature([cpu::Feature::Sha2])
pub fn sha256h2(efgh: [Secret<u32>; 4], abcd: [Secret<u32>; 4], wk: [Secret<u32>; 4]) [Secret<u32>; 4]
    ensures |r| words4(r) == arm_sha256_hash(words4(abcd), words4(efgh), words4(wk), false)
{
    let efgh_w: [u32; 4] = [efgh[0].v, efgh[1].v, efgh[2].v, efgh[3].v];
    let abcd_w: [u32; 4] = [abcd[0].v, abcd[1].v, abcd[2].v, abcd[3].v];
    let wk_w: [u32; 4] = [wk[0].v, wk[1].v, wk[2].v, wk[3].v];
    let mut o: [u32; 4] = [0; 4];
    unsafe arm_neon::vst1q_u32(
        &mut o[0],
        arm_neon::vsha256h2q_u32(
            unsafe arm_neon::vld1q_u32(&efgh_w[0]),
            unsafe arm_neon::vld1q_u32(&abcd_w[0]),
            unsafe arm_neon::vld1q_u32(&wk_w[0]),
        ),
    );
    return [Secret::<u32> { v: o[0] }, Secret::<u32> { v: o[1] }, Secret::<u32> { v: o[2] }, Secret::<u32> { v: o[3] }];
}

/// The first half of four schedule words (`SHA256SU0`): `w[t] + sigma0(w[t + 1])` from `w0_3` and `w4_7`.
@trusted
@constant_time
@arch(aarch64)
@target_feature([cpu::Feature::Sha2])
pub fn sha256su0(w0_3: [Secret<u32>; 4], w4_7: [Secret<u32>; 4]) [Secret<u32>; 4]
    ensures |r| words4(r) == arm_sha256_su0(words4(w0_3), words4(w4_7))
{
    let w0_3_w: [u32; 4] = [w0_3[0].v, w0_3[1].v, w0_3[2].v, w0_3[3].v];
    let w4_7_w: [u32; 4] = [w4_7[0].v, w4_7[1].v, w4_7[2].v, w4_7[3].v];
    let mut o: [u32; 4] = [0; 4];
    unsafe arm_neon::vst1q_u32(
        &mut o[0],
        arm_neon::vsha256su0q_u32(unsafe arm_neon::vld1q_u32(&w0_3_w[0]), unsafe arm_neon::vld1q_u32(&w4_7_w[0])),
    );
    return [Secret::<u32> { v: o[0] }, Secret::<u32> { v: o[1] }, Secret::<u32> { v: o[2] }, Secret::<u32> { v: o[3] }];
}

/// Four schedule words (`SHA256SU1`) from the first halves `tw0_3`, `w8_11` and `w12_15`.
@trusted
@constant_time
@arch(aarch64)
@target_feature([cpu::Feature::Sha2])
pub fn sha256su1(tw0_3: [Secret<u32>; 4], w8_11: [Secret<u32>; 4], w12_15: [Secret<u32>; 4]) [Secret<u32>; 4]
    ensures |r| words4(r) == arm_sha256_su1(words4(tw0_3), words4(w8_11), words4(w12_15))
{
    let tw0_3_w: [u32; 4] = [tw0_3[0].v, tw0_3[1].v, tw0_3[2].v, tw0_3[3].v];
    let w8_11_w: [u32; 4] = [w8_11[0].v, w8_11[1].v, w8_11[2].v, w8_11[3].v];
    let w12_15_w: [u32; 4] = [w12_15[0].v, w12_15[1].v, w12_15[2].v, w12_15[3].v];
    let mut o: [u32; 4] = [0; 4];
    unsafe arm_neon::vst1q_u32(
        &mut o[0],
        arm_neon::vsha256su1q_u32(
            unsafe arm_neon::vld1q_u32(&tw0_3_w[0]),
            unsafe arm_neon::vld1q_u32(&w8_11_w[0]),
            unsafe arm_neon::vld1q_u32(&w12_15_w[0]),
        ),
    );
    return [Secret::<u32> { v: o[0] }, Secret::<u32> { v: o[1] }, Secret::<u32> { v: o[2] }, Secret::<u32> { v: o[3] }];
}

/// Two SHA-256 rounds (SHA256RNDS2): A, B, E, F after them from `cdgh`, `abef` and `wk`'s lanes 0 and 1.
@trusted
@constant_time
@arch(x86_64)
@target_feature([cpu::Feature::Sha, cpu::Feature::Sse41])
pub fn sha256rnds2(cdgh: [Secret<u32>; 4], abef: [Secret<u32>; 4], wk: [Secret<u32>; 4]) [Secret<u32>; 4]
    ensures |r| words4(r) == intel_sha256_rnds2(words4(cdgh), words4(abef), words4(wk))
{
    let cdgh_w: [u32; 4] = [cdgh[0].v, cdgh[1].v, cdgh[2].v, cdgh[3].v];
    let abef_w: [u32; 4] = [abef[0].v, abef[1].v, abef[2].v, abef[3].v];
    let wk_w: [u32; 4] = [wk[0].v, wk[1].v, wk[2].v, wk[3].v];
    let mut o: [u32; 4] = [0; 4];
    unsafe immintrin::_mm_storeu_si128(
        ((&mut o) as *mut [u32; 4]) as *mut immintrin::__m128i_u,
        immintrin::_mm_sha256rnds2_epu32(
            unsafe immintrin::_mm_loadu_si128(((&cdgh_w) as *const [u32; 4]) as *const immintrin::__m128i_u),
            unsafe immintrin::_mm_loadu_si128(((&abef_w) as *const [u32; 4]) as *const immintrin::__m128i_u),
            unsafe immintrin::_mm_loadu_si128(((&wk_w) as *const [u32; 4]) as *const immintrin::__m128i_u),
        ),
    );
    return [Secret::<u32> { v: o[0] }, Secret::<u32> { v: o[1] }, Secret::<u32> { v: o[2] }, Secret::<u32> { v: o[3] }];
}

/// The first half of four schedule words (SHA256MSG1).
@trusted
@constant_time
@arch(x86_64)
@target_feature([cpu::Feature::Sha, cpu::Feature::Sse41])
pub fn sha256msg1(x: [Secret<u32>; 4], y: [Secret<u32>; 4]) [Secret<u32>; 4]
    ensures |r| words4(r) == intel_sha256_msg1(words4(x), words4(y))
{
    let x_w: [u32; 4] = [x[0].v, x[1].v, x[2].v, x[3].v];
    let y_w: [u32; 4] = [y[0].v, y[1].v, y[2].v, y[3].v];
    let mut o: [u32; 4] = [0; 4];
    unsafe immintrin::_mm_storeu_si128(
        ((&mut o) as *mut [u32; 4]) as *mut immintrin::__m128i_u,
        immintrin::_mm_sha256msg1_epu32(
            unsafe immintrin::_mm_loadu_si128(((&x_w) as *const [u32; 4]) as *const immintrin::__m128i_u),
            unsafe immintrin::_mm_loadu_si128(((&y_w) as *const [u32; 4]) as *const immintrin::__m128i_u),
        ),
    );
    return [Secret::<u32> { v: o[0] }, Secret::<u32> { v: o[1] }, Secret::<u32> { v: o[2] }, Secret::<u32> { v: o[3] }];
}

/// Four schedule words from their sums without sigma1 (SHA256MSG2).
@trusted
@constant_time
@arch(x86_64)
@target_feature([cpu::Feature::Sha, cpu::Feature::Sse41])
pub fn sha256msg2(x: [Secret<u32>; 4], y: [Secret<u32>; 4]) [Secret<u32>; 4]
    ensures |r| words4(r) == intel_sha256_msg2(words4(x), words4(y))
{
    let x_w: [u32; 4] = [x[0].v, x[1].v, x[2].v, x[3].v];
    let y_w: [u32; 4] = [y[0].v, y[1].v, y[2].v, y[3].v];
    let mut o: [u32; 4] = [0; 4];
    unsafe immintrin::_mm_storeu_si128(
        ((&mut o) as *mut [u32; 4]) as *mut immintrin::__m128i_u,
        immintrin::_mm_sha256msg2_epu32(
            unsafe immintrin::_mm_loadu_si128(((&x_w) as *const [u32; 4]) as *const immintrin::__m128i_u),
            unsafe immintrin::_mm_loadu_si128(((&y_w) as *const [u32; 4]) as *const immintrin::__m128i_u),
        ),
    );
    return [Secret::<u32> { v: o[0] }, Secret::<u32> { v: o[1] }, Secret::<u32> { v: o[2] }, Secret::<u32> { v: o[3] }];
}
