// SHA-512 (FIPS 180-4), proved: the specification is the standard's text as spec functions (the
// functions of 4.1.3, the schedule and the rounds of 6.4.2, the padding of 5.1.2 and the initial state of
// 5.3.5), and `sha512` computes exactly the digest it defines. Every function runs in constant time on
// the message bytes (`@constant_time`): only the message length, which is public, picks a branch or an
// index. No operation panics: the prover proves each check. The length field is the message's length in
// bits modulo 2^64 in the low half of its 128 bits; no message in memory reaches 2^64 bits. Import with
// `import std::crypto::sha512;`.

import std::crypto::secret as *;
import std::cpu;
import std::cpu::detect as detect;

// The functions of FIPS 180-4, 4.1.3.
spec fn ch(x: u64, y: u64, z: u64) u64 {
    return x & y ^ ~x & z;
}

spec fn maj(x: u64, y: u64, z: u64) u64 {
    return x & y ^ x & z ^ y & z;
}

spec fn big_sigma0(x: u64) u64 {
    return x.rotate_right(28) ^ x.rotate_right(34) ^ x.rotate_right(39);
}

spec fn big_sigma1(x: u64) u64 {
    return x.rotate_right(14) ^ x.rotate_right(18) ^ x.rotate_right(41);
}

spec fn small_sigma0(x: u64) u64 {
    return x.rotate_right(1) ^ x.rotate_right(8) ^ x >> 7;
}

spec fn small_sigma1(x: u64) u64 {
    return x.rotate_right(19) ^ x.rotate_right(61) ^ x >> 6;
}

// The round constants (4.2.3).
const K: [u64; 80] = [
    0x428a2f98d728ae22,
    0x7137449123ef65cd,
    0xb5c0fbcfec4d3b2f,
    0xe9b5dba58189dbbc,
    0x3956c25bf348b538,
    0x59f111f1b605d019,
    0x923f82a4af194f9b,
    0xab1c5ed5da6d8118,
    0xd807aa98a3030242,
    0x12835b0145706fbe,
    0x243185be4ee4b28c,
    0x550c7dc3d5ffb4e2,
    0x72be5d74f27b896f,
    0x80deb1fe3b1696b1,
    0x9bdc06a725c71235,
    0xc19bf174cf692694,
    0xe49b69c19ef14ad2,
    0xefbe4786384f25e3,
    0x0fc19dc68b8cd5b5,
    0x240ca1cc77ac9c65,
    0x2de92c6f592b0275,
    0x4a7484aa6ea6e483,
    0x5cb0a9dcbd41fbd4,
    0x76f988da831153b5,
    0x983e5152ee66dfab,
    0xa831c66d2db43210,
    0xb00327c898fb213f,
    0xbf597fc7beef0ee4,
    0xc6e00bf33da88fc2,
    0xd5a79147930aa725,
    0x06ca6351e003826f,
    0x142929670a0e6e70,
    0x27b70a8546d22ffc,
    0x2e1b21385c26c926,
    0x4d2c6dfc5ac42aed,
    0x53380d139d95b3df,
    0x650a73548baf63de,
    0x766a0abb3c77b2a8,
    0x81c2c92e47edaee6,
    0x92722c851482353b,
    0xa2bfe8a14cf10364,
    0xa81a664bbc423001,
    0xc24b8b70d0f89791,
    0xc76c51a30654be30,
    0xd192e819d6ef5218,
    0xd69906245565a910,
    0xf40e35855771202a,
    0x106aa07032bbd1b8,
    0x19a4c116b8d2d0c8,
    0x1e376c085141ab53,
    0x2748774cdf8eeb99,
    0x34b0bcb5e19b48a8,
    0x391c0cb3c5c95a63,
    0x4ed8aa4ae3418acb,
    0x5b9cca4f7763e373,
    0x682e6ff3d6b2b8a3,
    0x748f82ee5defb2fc,
    0x78a5636f43172f60,
    0x84c87814a1f0ab72,
    0x8cc702081a6439ec,
    0x90befffa23631e28,
    0xa4506cebde82bde9,
    0xbef9a3f7b2c67915,
    0xc67178f2e372532b,
    0xca273eceea26619c,
    0xd186b8c721c0c207,
    0xeada7dd6cde0eb1e,
    0xf57d4f7fee6ed178,
    0x06f067aa72176fba,
    0x0a637dc5a2c898a6,
    0x113f9804bef90dae,
    0x1b710b35131c471b,
    0x28db77f523047d84,
    0x32caab7b40c72493,
    0x3c9ebe0a15c9bebc,
    0x431d67c49c100d4c,
    0x4cc5d4becb3e42b6,
    0x597f299cfc657e2a,
    0x5fcb6fab3ad6faec,
    0x6c44198c4a475817,
];

// Word `t` of the message schedule of block `m` (6.4.2, step 1), defined up to word 95 so that the
// window of 16 words the loop keeps is defined at each of its 80 steps.
spec fn sched(m: [Secret<u64>; 16], t: u32) u64
    requires t < 96
    decreases t
{
    return if t < 16 {
        m[t].value()
    } else {
        small_sigma1(sched(m, t - 2)).wrapping_add(sched(m, t - 7)).wrapping_add(small_sigma0(sched(m, t - 15))).wrapping_add(
            sched(m, t - 16),
        )
    };
}

// One round on the working variables `a..h` (6.4.2, step 3).
spec fn round(s: [u64; 8], w: u64, k: u64) [u64; 8] {
    let t1 = s[7].wrapping_add(big_sigma1(s[4])).wrapping_add(ch(s[4], s[5], s[6])).wrapping_add(k).wrapping_add(w);
    let t2 = big_sigma0(s[0]).wrapping_add(maj(s[0], s[1], s[2]));
    return [t1.wrapping_add(t2), s[0], s[1], s[2], s[3].wrapping_add(t1), s[4], s[5], s[6]];
}

// The working variables after rounds `0..t` from state `h`.
spec fn rounds(h: [u64; 8], m: [Secret<u64>; 16], t: u32) [u64; 8]
    requires t <= 80
    decreases t
{
    return if t == 0 {
        h
    } else {
        round(rounds(h, m, t - 1), sched(m, t - 1), K[t - 1])
    };
}

// The state after block `m` (6.4.2, step 4).
spec fn compress(h: [u64; 8], m: [Secret<u64>; 16]) [u64; 8] {
    let s = rounds(h, m, 80);
    return [
        h[0].wrapping_add(s[0]),
        h[1].wrapping_add(s[1]),
        h[2].wrapping_add(s[2]),
        h[3].wrapping_add(s[3]),
        h[4].wrapping_add(s[4]),
        h[5].wrapping_add(s[5]),
        h[6].wrapping_add(s[6]),
        h[7].wrapping_add(s[7]),
    ];
}

// The initial state (5.3.5).
spec fn h0() [u64; 8] {
    return [
        0x6a09e667f3bcc908,
        0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b,
        0xa54ff53a5f1d36f1,
        0x510e527fade682d1,
        0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b,
        0x5be0cd19137e2179,
    ];
}

// The length of the padded message of `n` bytes: the message, 0x80, zeros and the 16 length bytes, a
// multiple of 128.
spec fn padded_len(n: int) int {
    return (n + 16) / 128 * 128 + 128;
}

// Byte `p` of the padded message (5.1.2); 0 outside it. The length's high 8 bytes are 0.
spec fn padded(msg: []Secret<u8>, p: int) u8 {
    let n = msg.len() as int;
    let end = padded_len(n);
    return if p < 0 || p >= end {
        0
    } else if p < n {
        msg[p as usize].value()
    } else if p == n {
        0x80
    } else if p + 8 >= end {
        ((msg.len() as u64).wrapping_mul(8) >> ((end - 1 - p) * 8) as u64) as u8
    } else {
        0
    };
}

// The big-endian word at byte `p` of the padded message.
spec fn word(msg: []Secret<u8>, p: int) u64 {
    return padded(msg, p) as u64 << 56 | padded(msg, p + 1) as u64 << 48 | padded(msg, p + 2) as u64 << 40 | padded(
        msg,
        p + 3,
    ) as u64 << 32 | padded(msg, p + 4) as u64 << 24 | padded(msg, p + 5) as u64 << 16 | padded(msg, p + 6) as u64 << 8 | padded(
        msg,
        p + 7,
    ) as u64;
}

// Block `b` of the padded message as 16 words (5.2.2).
spec fn block(msg: []Secret<u8>, b: int) [Secret<u64>; 16] {
    let p = b * 128;
    return [
        Secret::new(word(msg, p)),
        Secret::new(word(msg, p + 8)),
        Secret::new(word(msg, p + 16)),
        Secret::new(word(msg, p + 24)),
        Secret::new(word(msg, p + 32)),
        Secret::new(word(msg, p + 40)),
        Secret::new(word(msg, p + 48)),
        Secret::new(word(msg, p + 56)),
        Secret::new(word(msg, p + 64)),
        Secret::new(word(msg, p + 72)),
        Secret::new(word(msg, p + 80)),
        Secret::new(word(msg, p + 88)),
        Secret::new(word(msg, p + 96)),
        Secret::new(word(msg, p + 104)),
        Secret::new(word(msg, p + 112)),
        Secret::new(word(msg, p + 120)),
    ];
}

// The state after blocks `0..b` of the padded message.
spec fn hashes(msg: []Secret<u8>, b: int) [u64; 8]
    decreases b
{
    return if b <= 0 {
        h0()
    } else {
        compress(hashes(msg, b - 1), block(msg, b - 1))
    };
}

// The state's words as big-endian bytes.
spec fn be_bytes(h: [u64; 8]) [u8; 64] {
    return [
        (h[0] >> 56) as u8,
        (h[0] >> 48) as u8,
        (h[0] >> 40) as u8,
        (h[0] >> 32) as u8,
        (h[0] >> 24) as u8,
        (h[0] >> 16) as u8,
        (h[0] >> 8) as u8,
        (h[0] >> 0) as u8,
        (h[1] >> 56) as u8,
        (h[1] >> 48) as u8,
        (h[1] >> 40) as u8,
        (h[1] >> 32) as u8,
        (h[1] >> 24) as u8,
        (h[1] >> 16) as u8,
        (h[1] >> 8) as u8,
        (h[1] >> 0) as u8,
        (h[2] >> 56) as u8,
        (h[2] >> 48) as u8,
        (h[2] >> 40) as u8,
        (h[2] >> 32) as u8,
        (h[2] >> 24) as u8,
        (h[2] >> 16) as u8,
        (h[2] >> 8) as u8,
        (h[2] >> 0) as u8,
        (h[3] >> 56) as u8,
        (h[3] >> 48) as u8,
        (h[3] >> 40) as u8,
        (h[3] >> 32) as u8,
        (h[3] >> 24) as u8,
        (h[3] >> 16) as u8,
        (h[3] >> 8) as u8,
        (h[3] >> 0) as u8,
        (h[4] >> 56) as u8,
        (h[4] >> 48) as u8,
        (h[4] >> 40) as u8,
        (h[4] >> 32) as u8,
        (h[4] >> 24) as u8,
        (h[4] >> 16) as u8,
        (h[4] >> 8) as u8,
        (h[4] >> 0) as u8,
        (h[5] >> 56) as u8,
        (h[5] >> 48) as u8,
        (h[5] >> 40) as u8,
        (h[5] >> 32) as u8,
        (h[5] >> 24) as u8,
        (h[5] >> 16) as u8,
        (h[5] >> 8) as u8,
        (h[5] >> 0) as u8,
        (h[6] >> 56) as u8,
        (h[6] >> 48) as u8,
        (h[6] >> 40) as u8,
        (h[6] >> 32) as u8,
        (h[6] >> 24) as u8,
        (h[6] >> 16) as u8,
        (h[6] >> 8) as u8,
        (h[6] >> 0) as u8,
        (h[7] >> 56) as u8,
        (h[7] >> 48) as u8,
        (h[7] >> 40) as u8,
        (h[7] >> 32) as u8,
        (h[7] >> 24) as u8,
        (h[7] >> 16) as u8,
        (h[7] >> 8) as u8,
        (h[7] >> 0) as u8,
    ];
}

/// The SHA-512 digest of `msg` (FIPS 180-4, 6.4), the specification `sha512` meets.
pub spec fn digest(msg: []Secret<u8>) [u8; 64] {
    return be_bytes(hashes(msg, (msg.len() as int + 16) / 128 + 1));
}

/// The values of the bytes of `d`.
pub spec fn byte_values(d: [Secret<u8>; 64]) [u8; 64] {
    return [
        d[0].value(),
        d[1].value(),
        d[2].value(),
        d[3].value(),
        d[4].value(),
        d[5].value(),
        d[6].value(),
        d[7].value(),
        d[8].value(),
        d[9].value(),
        d[10].value(),
        d[11].value(),
        d[12].value(),
        d[13].value(),
        d[14].value(),
        d[15].value(),
        d[16].value(),
        d[17].value(),
        d[18].value(),
        d[19].value(),
        d[20].value(),
        d[21].value(),
        d[22].value(),
        d[23].value(),
        d[24].value(),
        d[25].value(),
        d[26].value(),
        d[27].value(),
        d[28].value(),
        d[29].value(),
        d[30].value(),
        d[31].value(),
        d[32].value(),
        d[33].value(),
        d[34].value(),
        d[35].value(),
        d[36].value(),
        d[37].value(),
        d[38].value(),
        d[39].value(),
        d[40].value(),
        d[41].value(),
        d[42].value(),
        d[43].value(),
        d[44].value(),
        d[45].value(),
        d[46].value(),
        d[47].value(),
        d[48].value(),
        d[49].value(),
        d[50].value(),
        d[51].value(),
        d[52].value(),
        d[53].value(),
        d[54].value(),
        d[55].value(),
        d[56].value(),
        d[57].value(),
        d[58].value(),
        d[59].value(),
        d[60].value(),
        d[61].value(),
        d[62].value(),
        d[63].value(),
    ];
}

// The values of the words of state `s`.
spec fn state_values(s: [Secret<u64>; 8]) [u64; 8] {
    return [
        s[0].value(),
        s[1].value(),
        s[2].value(),
        s[3].value(),
        s[4].value(),
        s[5].value(),
        s[6].value(),
        s[7].value(),
    ];
}

@constant_time
fn round_ct(s: [Secret<u64>; 8], w: Secret<u64>, k: u64) [Secret<u64>; 8]
    ensures |r| state_values(r) == round(state_values(s), w.value(), k)
{
    let a = s[0];
    let e = s[4];
    let t1 = s[7] + (e.rotate_right(14) ^ e.rotate_right(18) ^ e.rotate_right(41)) + (e & s[5] ^ ~e & s[6]) + Secret::new(
        k,
    ) + w;
    let t2 = (a.rotate_right(28) ^ a.rotate_right(34) ^ a.rotate_right(39)) + (a & s[1] ^ a & s[2] ^ s[1] & s[2]);
    return [t1 + t2, s[0], s[1], s[2], s[3] + t1, s[4], s[5], s[6]];
}

@constant_time
fn sched_ct(a: Secret<u64>, b: Secret<u64>, c: Secret<u64>, d: Secret<u64>) Secret<u64>
    ensures |r| r.value() == small_sigma1(a.value()).wrapping_add(b.value()).wrapping_add(small_sigma0(c.value())).wrapping_add(
        d.value(),
    )
{
    return (a.rotate_right(19) ^ a.rotate_right(61) ^ a >> 6) + b + (c.rotate_right(1) ^ c.rotate_right(8) ^ c >> 7) + d;
}

// Schedule word `t + 16` from words `t`, `t + 1`, `t + 9` and `t + 14`.
@constant_time
fn next_word(m: [Secret<u64>; 16], t: u32, w0: Secret<u64>, w1: Secret<u64>, w9: Secret<u64>, w14: Secret<u64>) Secret<
    u64
>
    requires t < 80
    requires w0.value() == sched(m, t)
    requires w1.value() == sched(m, t + 1)
    requires w9.value() == sched(m, t + 9)
    requires w14.value() == sched(m, t + 14)
    ensures |r| r.value() == sched(m, t + 16)
{
    return sched_ct(w14, w9, w1, w0);
}

// Round `t` on the working variables after rounds `0..t`.
@constant_time
fn next_state(h: [Secret<u64>; 8], m: [Secret<u64>; 16], t: u32, s: [Secret<u64>; 8], w0: Secret<u64>) [Secret<u64>; 8]
    requires t < 80
    requires state_values(s) == rounds(state_values(h), m, t)
    requires w0.value() == sched(m, t)
    ensures |r| state_values(r) == rounds(state_values(h), m, t + 1)
{
    return round_ct(s, w0, K[t]);
}

// Block `m` on state `h`. The window `w` holds schedule words `t..t + 16`.
@constant_time
fn compress_ct(h: [Secret<u64>; 8], m: [Secret<u64>; 16]) [Secret<u64>; 8]
    ensures |r| state_values(r) == compress(state_values(h), m)
{
    let mut w = m;
    let mut s = h;
    let mut t: u32 = 0;
    while t < 80
        invariant t <= 80
        invariant state_values(s) == rounds(state_values(h), m, t)
        invariant w[0].value() == sched(m, t + 0)
        invariant w[1].value() == sched(m, t + 1)
        invariant w[2].value() == sched(m, t + 2)
        invariant w[3].value() == sched(m, t + 3)
        invariant w[4].value() == sched(m, t + 4)
        invariant w[5].value() == sched(m, t + 5)
        invariant w[6].value() == sched(m, t + 6)
        invariant w[7].value() == sched(m, t + 7)
        invariant w[8].value() == sched(m, t + 8)
        invariant w[9].value() == sched(m, t + 9)
        invariant w[10].value() == sched(m, t + 10)
        invariant w[11].value() == sched(m, t + 11)
        invariant w[12].value() == sched(m, t + 12)
        invariant w[13].value() == sched(m, t + 13)
        invariant w[14].value() == sched(m, t + 14)
        invariant w[15].value() == sched(m, t + 15)
    {
        s = next_state(h, m, t, s, w[0]);
        let next = next_word(m, t, w[0], w[1], w[9], w[14]);
        w = [w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15], next];
        t += 1;
    }
    assert t == 80 by {};
    assert state_values(s) == rounds(state_values(h), m, 80) by {};
    return [h[0] + s[0], h[1] + s[1], h[2] + s[2], h[3] + s[3], h[4] + s[4], h[5] + s[5], h[6] + s[6], h[7] + s[7]];
}

// Byte `p` of the padded message.
@constant_time
const fn pad_byte(msg: []Secret<u8>, p: usize) Secret<u8>
    requires p as int < padded_len(msg.len() as int)
    ensures |r| r.value() == padded(msg, p as int)
{
    let n = msg.len();
    let end = (n + 16) / 128 * 128 + 128;
    if p < n {
        return msg[p];
    }
    if p == n {
        return Secret::new(0x80u8);
    }
    if p + 8 >= end {
        return Secret::new(((n as u64).wrapping_mul(8) >> ((end - 1 - p) * 8) as u64) as u8);
    }
    return Secret::new(0u8);
}

// The big-endian word at byte `p` of the padded message.
@constant_time
fn word_at(msg: []Secret<u8>, p: usize) Secret<u64>
    requires p as int + 8 <= padded_len(msg.len() as int)
    ensures |r| r.value() == word(msg, p as int)
{
    let b0 = pad_byte(msg, p).cast::<u64>();
    let b1 = pad_byte(msg, p + 1).cast::<u64>();
    let b2 = pad_byte(msg, p + 2).cast::<u64>();
    let b3 = pad_byte(msg, p + 3).cast::<u64>();
    let b4 = pad_byte(msg, p + 4).cast::<u64>();
    let b5 = pad_byte(msg, p + 5).cast::<u64>();
    let b6 = pad_byte(msg, p + 6).cast::<u64>();
    let b7 = pad_byte(msg, p + 7).cast::<u64>();
    return b0 << 56 | b1 << 48 | b2 << 40 | b3 << 32 | b4 << 24 | b5 << 16 | b6 << 8 | b7;
}

// The big-endian word at byte `p` of the message, inside it.
@constant_time
fn msg_word_at(msg: []Secret<u8>, p: usize) Secret<u64>
    requires p as int + 8 <= msg.len() as int
    ensures |r| r.value() == word(msg, p as int)
{
    let b0 = msg[p].cast::<u64>();
    let b1 = msg[p + 1].cast::<u64>();
    let b2 = msg[p + 2].cast::<u64>();
    let b3 = msg[p + 3].cast::<u64>();
    let b4 = msg[p + 4].cast::<u64>();
    let b5 = msg[p + 5].cast::<u64>();
    let b6 = msg[p + 6].cast::<u64>();
    let b7 = msg[p + 7].cast::<u64>();
    return b0 << 56 | b1 << 48 | b2 << 40 | b3 << 32 | b4 << 24 | b5 << 16 | b6 << 8 | b7;
}

// Block `b` of the message, inside it: no padding byte.
@constant_time
fn load_full_block(msg: []Secret<u8>, b: usize) [Secret<u64>; 16]
    requires (b as int + 1) * 128 <= msg.len() as int
    ensures |m| m == block(msg, b as int)
{
    let p = b * 128;
    return [
        msg_word_at(msg, p),
        msg_word_at(msg, p + 8),
        msg_word_at(msg, p + 16),
        msg_word_at(msg, p + 24),
        msg_word_at(msg, p + 32),
        msg_word_at(msg, p + 40),
        msg_word_at(msg, p + 48),
        msg_word_at(msg, p + 56),
        msg_word_at(msg, p + 64),
        msg_word_at(msg, p + 72),
        msg_word_at(msg, p + 80),
        msg_word_at(msg, p + 88),
        msg_word_at(msg, p + 96),
        msg_word_at(msg, p + 104),
        msg_word_at(msg, p + 112),
        msg_word_at(msg, p + 120),
    ];
}

// Block `b` of the padded message.
@constant_time
fn load_block(msg: []Secret<u8>, b: usize) [Secret<u64>; 16]
    requires (b as int + 1) * 128 <= padded_len(msg.len() as int)
    ensures |m| m == block(msg, b as int)
{
    let p = b * 128;
    if p + 128 <= msg.len() {
        return load_full_block(msg, b);
    }
    return [
        word_at(msg, p),
        word_at(msg, p + 8),
        word_at(msg, p + 16),
        word_at(msg, p + 24),
        word_at(msg, p + 32),
        word_at(msg, p + 40),
        word_at(msg, p + 48),
        word_at(msg, p + 56),
        word_at(msg, p + 64),
        word_at(msg, p + 72),
        word_at(msg, p + 80),
        word_at(msg, p + 88),
        word_at(msg, p + 96),
        word_at(msg, p + 104),
        word_at(msg, p + 112),
        word_at(msg, p + 120),
    ];
}

@constant_time
fn to_bytes(h: [Secret<u64>; 8]) [Secret<u8>; 64]
    ensures |d| byte_values(d) == be_bytes(state_values(h))
{
    return [
        (h[0] >> 56).cast::<u8>(),
        (h[0] >> 48).cast::<u8>(),
        (h[0] >> 40).cast::<u8>(),
        (h[0] >> 32).cast::<u8>(),
        (h[0] >> 24).cast::<u8>(),
        (h[0] >> 16).cast::<u8>(),
        (h[0] >> 8).cast::<u8>(),
        (h[0] >> 0).cast::<u8>(),
        (h[1] >> 56).cast::<u8>(),
        (h[1] >> 48).cast::<u8>(),
        (h[1] >> 40).cast::<u8>(),
        (h[1] >> 32).cast::<u8>(),
        (h[1] >> 24).cast::<u8>(),
        (h[1] >> 16).cast::<u8>(),
        (h[1] >> 8).cast::<u8>(),
        (h[1] >> 0).cast::<u8>(),
        (h[2] >> 56).cast::<u8>(),
        (h[2] >> 48).cast::<u8>(),
        (h[2] >> 40).cast::<u8>(),
        (h[2] >> 32).cast::<u8>(),
        (h[2] >> 24).cast::<u8>(),
        (h[2] >> 16).cast::<u8>(),
        (h[2] >> 8).cast::<u8>(),
        (h[2] >> 0).cast::<u8>(),
        (h[3] >> 56).cast::<u8>(),
        (h[3] >> 48).cast::<u8>(),
        (h[3] >> 40).cast::<u8>(),
        (h[3] >> 32).cast::<u8>(),
        (h[3] >> 24).cast::<u8>(),
        (h[3] >> 16).cast::<u8>(),
        (h[3] >> 8).cast::<u8>(),
        (h[3] >> 0).cast::<u8>(),
        (h[4] >> 56).cast::<u8>(),
        (h[4] >> 48).cast::<u8>(),
        (h[4] >> 40).cast::<u8>(),
        (h[4] >> 32).cast::<u8>(),
        (h[4] >> 24).cast::<u8>(),
        (h[4] >> 16).cast::<u8>(),
        (h[4] >> 8).cast::<u8>(),
        (h[4] >> 0).cast::<u8>(),
        (h[5] >> 56).cast::<u8>(),
        (h[5] >> 48).cast::<u8>(),
        (h[5] >> 40).cast::<u8>(),
        (h[5] >> 32).cast::<u8>(),
        (h[5] >> 24).cast::<u8>(),
        (h[5] >> 16).cast::<u8>(),
        (h[5] >> 8).cast::<u8>(),
        (h[5] >> 0).cast::<u8>(),
        (h[6] >> 56).cast::<u8>(),
        (h[6] >> 48).cast::<u8>(),
        (h[6] >> 40).cast::<u8>(),
        (h[6] >> 32).cast::<u8>(),
        (h[6] >> 24).cast::<u8>(),
        (h[6] >> 16).cast::<u8>(),
        (h[6] >> 8).cast::<u8>(),
        (h[6] >> 0).cast::<u8>(),
        (h[7] >> 56).cast::<u8>(),
        (h[7] >> 48).cast::<u8>(),
        (h[7] >> 40).cast::<u8>(),
        (h[7] >> 32).cast::<u8>(),
        (h[7] >> 24).cast::<u8>(),
        (h[7] >> 16).cast::<u8>(),
        (h[7] >> 8).cast::<u8>(),
        (h[7] >> 0).cast::<u8>(),
    ];
}

// Block `b` on state `h`.
@constant_time
fn absorb_block(msg: []Secret<u8>, b: usize, h: [Secret<u64>; 8], hw: bool) [Secret<u64>; 8]
    requires (b as int + 1) * 128 <= padded_len(msg.len() as int)
    ensures |r| state_values(r) == compress(state_values(h), block(msg, b as int))
{
    let m = load_block(msg, b);
    return compress_on(h, m, hw);
}

lemma hashes_step(msg: []Secret<u8>, b: int)
    requires b >= 0
    ensures hashes(msg, b + 1) == compress(hashes(msg, b), block(msg, b))
{}

// Block `b` on the state after blocks `0..b`.
@constant_time
fn absorb(msg: []Secret<u8>, b: usize, h: [Secret<u64>; 8], hw: bool) [Secret<u64>; 8]
    requires (b as int + 1) * 128 <= padded_len(msg.len() as int)
    requires state_values(h) == hashes(msg, b as int)
    ensures |r| state_values(r) == hashes(msg, b as int + 1)
{
    hashes_step(msg, b as int);
    return absorb_block(msg, b, h, hw);
}

// ---- The processor's SHA-512 instructions ----
//
// arm64's SHA512H, SHA512H2, SHA512SU0, SHA512SU1 (FEAT_SHA512) compute two rounds, or two schedule words,
// per pair of instructions. Their meaning is Arm's pseudocode (`std::crypto::secret`); the lemmas below
// prove the path that uses them computes `compress`. Each orders its sums differently from FIPS 180-4's
// text: wrapping addition is associative and commutative, one step at a time.

lemma add_comm(a: u64, b: u64)
    ensures a.wrapping_add(b) == b.wrapping_add(a)
{}

lemma add_assoc(a: u64, b: u64, c: u64)
    ensures a.wrapping_add(b).wrapping_add(c) == a.wrapping_add(b.wrapping_add(c))
{}

// Schedule words `t` and `t + 1` of block `m`.
spec fn sched2(m: [Secret<u64>; 16], t: u32) [u64; 2]
    requires t <= 94
{
    return [sched(m, t), sched(m, t + 1)];
}

// Rounds `t` and `t + 1`, one at a time.
lemma rounds_two(h: [u64; 8], m: [Secret<u64>; 16], t: u32)
    requires t <= 78
    ensures rounds(h, m, t + 2) == round(round(rounds(h, m, t), sched(m, t), K[t]), sched(m, t + 1), K[t + 1])
{
    assert rounds(h, m, t + 1) == round(rounds(h, m, t), sched(m, t), K[t]) by {};
    assert rounds(h, m, t + 2) == round(rounds(h, m, t + 1), sched(m, t + 1), K[t + 1]) by {};
}

// A round's `t1`, `h + sigma1(e) + ch(e, f, g) + k + w`, as SHA512H sums it: `(ch + sigma1) + (h + (w + k))`.
lemma t1_order(h: u64, s1: u64, c: u64, k: u64, w: u64)
    ensures c.wrapping_add(s1).wrapping_add(h.wrapping_add(w.wrapping_add(k))) == h.wrapping_add(s1).wrapping_add(c).wrapping_add(
        k,
    ).wrapping_add(w)
{
    let x = h.wrapping_add(s1).wrapping_add(c);
    // (x + k) + w == x + (k + w) == x + (w + k).
    add_assoc(x, k, w);
    add_comm(k, w);
    // (c + s1) + (h + wk) == ((c + s1) + h) + wk, and (c + s1) + h == h + (s1 + c) == (h + s1) + c.
    let wk = w.wrapping_add(k);
    add_assoc(c.wrapping_add(s1), h, wk);
    add_comm(c.wrapping_add(s1), h);
    add_comm(c, s1);
    add_assoc(h, s1, c);
}

// A round's new `a`, `t1 + (sigma0(a) + maj(a, b, c))`, as SHA512H2 sums it: `(maj + sigma0) + t1`.
lemma a_order(m: u64, s0: u64, t1: u64)
    ensures m.wrapping_add(s0).wrapping_add(t1) == t1.wrapping_add(s0.wrapping_add(m))
{
    add_comm(m, s0);
    add_comm(s0.wrapping_add(m), t1);
}

// SHA512H, then SHA512H2 on its result, are two rounds: from `s`, the pairs `GH + (w + k)` crossed,
// `FG`, `DE`, then `CD` and `AB`.
lemma arm_rounds2(s: [u64; 8], w0: u64, w1: u64, k0: u64, k1: u64)
    ensures arm_sha512h2(
        arm_sha512h(
            [s[6].wrapping_add(w1.wrapping_add(k1)), s[7].wrapping_add(w0.wrapping_add(k0))],
            [s[5], s[6]],
            [s[3], s[4]],
        ),
        [s[2], s[3]],
        [s[0], s[1]],
    ) == [round(round(s, w0, k0), w1, k1)[0], round(round(s, w0, k0), w1, k1)[1]]
    ensures s[2].wrapping_add(
        arm_sha512h(
            [s[6].wrapping_add(w1.wrapping_add(k1)), s[7].wrapping_add(w0.wrapping_add(k0))],
            [s[5], s[6]],
            [s[3], s[4]],
        )[0],
    ) == round(round(s, w0, k0), w1, k1)[4]
    ensures s[3].wrapping_add(
        arm_sha512h(
            [s[6].wrapping_add(w1.wrapping_add(k1)), s[7].wrapping_add(w0.wrapping_add(k0))],
            [s[5], s[6]],
            [s[3], s[4]],
        )[1],
    ) == round(round(s, w0, k0), w1, k1)[5]
{
    let r1 = round(s, w0, k0);
    let ta = s[7].wrapping_add(big_sigma1(s[4])).wrapping_add(ch(s[4], s[5], s[6])).wrapping_add(k0).wrapping_add(w0);
    t1_order(s[7], big_sigma1(s[4]), ch(s[4], s[5], s[6]), k0, w0);
    let e1 = s[3].wrapping_add(ta);
    add_comm(ta, s[3]);
    assert r1[4] == e1 by {};
    let tb = s[6].wrapping_add(big_sigma1(e1)).wrapping_add(ch(e1, s[4], s[5])).wrapping_add(k1).wrapping_add(w1);
    t1_order(s[6], big_sigma1(e1), ch(e1, s[4], s[5]), k1, w1);
    assert (s[2] & s[1] | (s[2] | s[1]) & s[0]) == maj(s[0], s[1], s[2]) by {};
    a_order(maj(s[0], s[1], s[2]), big_sigma0(s[0]), ta);
    let a1 = r1[0];
    assert (a1 & s[0] | (a1 | s[0]) & s[1]) == maj(a1, s[0], s[1]) by {};
    a_order(maj(a1, s[0], s[1]), big_sigma0(a1), tb);
}

// Schedule word `t + 16` from words `t`, `t + 1`, `t + 9` and `t + 14` as SHA512SU0 and SHA512SU1 sum
// them: `((w0 + s0) + s1) + w9`.
lemma sched_order(w0: u64, s0: u64, w9: u64, s1: u64)
    ensures w0.wrapping_add(s0).wrapping_add(s1).wrapping_add(w9) == s1.wrapping_add(w9).wrapping_add(s0).wrapping_add(
        w0,
    )
{
    // ((w0 + s0) + s1) + w9 == (w0 + s0) + (s1 + w9) == (s1 + w9) + (w0 + s0) == ((s1 + w9) + w0) + s0
    // == (s1 + w9) + (w0 + s0) ... == ((s1 + w9) + s0) + w0.
    let p = w0.wrapping_add(s0);
    add_assoc(p, s1, w9);
    add_comm(p, s1.wrapping_add(w9));
    add_comm(w0, s0);
    add_assoc(s1.wrapping_add(w9), s0, w0);
}

// Schedule words `t + 16` and `t + 17`: SHA512SU1 of SHA512SU0's first halves.
lemma arm_sched(m: [Secret<u64>; 16], t: u32)
    requires t <= 78
    ensures arm_sha512su1(
        arm_sha512su0(sched2(m, t), sched2(m, t + 2)),
        sched2(m, t + 14),
        [sched(m, t + 9), sched(m, t + 10)],
    ) == sched2(m, t + 16)
{
    sched_order(sched(m, t), small_sigma0(sched(m, t + 1)), sched(m, t + 9), small_sigma1(sched(m, t + 14)));
    sched_order(sched(m, t + 1), small_sigma0(sched(m, t + 2)), sched(m, t + 10), small_sigma1(sched(m, t + 15)));
}

// Rounds `t` and `t + 1` on the working variables after rounds `0..t`, with arm64's SHA512H and SHA512H2.
@always_inline
@constant_time
@arch(aarch64)
@target_feature([cpu::Feature::Sha512])
fn rounds_a64(h: [Secret<u64>; 8], m: [Secret<u64>; 16], t: u32, s: [Secret<u64>; 8], w: [Secret<u64>; 2]) [Secret<u64>; 8]
    requires t <= 78
    requires state_values(s) == rounds(state_values(h), m, t)
    requires words2(w) == sched2(m, t)
    ensures |r| state_values(r) == rounds(state_values(h), m, t + 2)
{
    let gh: [Secret<u64>; 2] = [s[6] + (w[1] + Secret::new(K[t + 1])), s[7] + (w[0] + Secret::new(K[t]))];
    let fg: [Secret<u64>; 2] = [s[5], s[6]];
    let de: [Secret<u64>; 2] = [s[3], s[4]];
    let t1 = sha512h(gh, fg, de);
    let cd: [Secret<u64>; 2] = [s[2], s[3]];
    let ab: [Secret<u64>; 2] = [s[0], s[1]];
    let na = sha512h2(t1, cd, ab);

    assert words2(gh) == [
        state_values(s)[6].wrapping_add(sched(m, t + 1).wrapping_add(K[t + 1])),
        state_values(s)[7].wrapping_add(sched(m, t).wrapping_add(K[t])),
    ] by {};

    assert words2(fg) == [state_values(s)[5], state_values(s)[6]] && words2(de) == [
        state_values(s)[3],
        state_values(s)[4],
    ] by {};

    assert words2(cd) == [state_values(s)[2], state_values(s)[3]] && words2(ab) == [
        state_values(s)[0],
        state_values(s)[1],
    ] by {};
    arm_rounds2(state_values(s), sched(m, t), sched(m, t + 1), K[t], K[t + 1]);
    rounds_two(state_values(h), m, t);
    return [na[0], na[1], s[0], s[1], s[2] + t1[0], s[3] + t1[1], s[4], s[5]];
}

// Schedule words `t + 16` and `t + 17` with arm64's SHA512SU0 and SHA512SU1, from the window's pairs of
// words `t`, `t + 2`, `t + 8`, `t + 10` and `t + 14`.
@always_inline
@constant_time
@arch(aarch64)
@target_feature([cpu::Feature::Sha512])
fn sched_a64(
    m: [Secret<u64>; 16],
    t: u32,
    p0: [Secret<u64>; 2],
    p1: [Secret<u64>; 2],
    p4: [Secret<u64>; 2],
    p5: [Secret<u64>; 2],
    p7: [Secret<u64>; 2],
) [Secret<u64>; 2]
    requires t <= 78
    requires words2(p0) == sched2(m, t) && words2(p1) == sched2(m, t + 2)
    requires words2(p4) == sched2(m, t + 8) && words2(p5) == sched2(m, t + 10)
    requires words2(p7) == sched2(m, t + 14)
    ensures |r| words2(r) == sched2(m, t + 16)
{
    let w9_10: [Secret<u64>; 2] = [p4[1], p5[0]];
    assert words2(w9_10) == [sched(m, t + 9), sched(m, t + 10)] by {};
    arm_sched(m, t);
    return sha512su1(sha512su0(p0, p1), p7, w9_10);
}

// Block `m` on state `h` with arm64's SHA-512 instructions. The window `w0..w7` holds schedule words
// `t..t + 16` in pairs.
@constant_time
@arch(aarch64)
@target_feature([cpu::Feature::Sha512])
fn compress_a64(h: [Secret<u64>; 8], m: [Secret<u64>; 16]) [Secret<u64>; 8]
    ensures |r| state_values(r) == compress(state_values(h), m)
{
    let mut s = h;
    let mut w0: [Secret<u64>; 2] = [m[0], m[1]];
    let mut w1: [Secret<u64>; 2] = [m[2], m[3]];
    let mut w2: [Secret<u64>; 2] = [m[4], m[5]];
    let mut w3: [Secret<u64>; 2] = [m[6], m[7]];
    let mut w4: [Secret<u64>; 2] = [m[8], m[9]];
    let mut w5: [Secret<u64>; 2] = [m[10], m[11]];
    let mut w6: [Secret<u64>; 2] = [m[12], m[13]];
    let mut w7: [Secret<u64>; 2] = [m[14], m[15]];
    // The 80 rounds in order, two at a time, each pair of the window taking its next words in place once read.
    s = rounds_a64(h, m, 0, s, w0);
    w0 = sched_a64(m, 0, w0, w1, w4, w5, w7);
    s = rounds_a64(h, m, 2, s, w1);
    w1 = sched_a64(m, 2, w1, w2, w5, w6, w0);
    s = rounds_a64(h, m, 4, s, w2);
    w2 = sched_a64(m, 4, w2, w3, w6, w7, w1);
    s = rounds_a64(h, m, 6, s, w3);
    w3 = sched_a64(m, 6, w3, w4, w7, w0, w2);
    s = rounds_a64(h, m, 8, s, w4);
    w4 = sched_a64(m, 8, w4, w5, w0, w1, w3);
    s = rounds_a64(h, m, 10, s, w5);
    w5 = sched_a64(m, 10, w5, w6, w1, w2, w4);
    s = rounds_a64(h, m, 12, s, w6);
    w6 = sched_a64(m, 12, w6, w7, w2, w3, w5);
    s = rounds_a64(h, m, 14, s, w7);
    w7 = sched_a64(m, 14, w7, w0, w3, w4, w6);
    s = rounds_a64(h, m, 16, s, w0);
    w0 = sched_a64(m, 16, w0, w1, w4, w5, w7);
    s = rounds_a64(h, m, 18, s, w1);
    w1 = sched_a64(m, 18, w1, w2, w5, w6, w0);
    s = rounds_a64(h, m, 20, s, w2);
    w2 = sched_a64(m, 20, w2, w3, w6, w7, w1);
    s = rounds_a64(h, m, 22, s, w3);
    w3 = sched_a64(m, 22, w3, w4, w7, w0, w2);
    s = rounds_a64(h, m, 24, s, w4);
    w4 = sched_a64(m, 24, w4, w5, w0, w1, w3);
    s = rounds_a64(h, m, 26, s, w5);
    w5 = sched_a64(m, 26, w5, w6, w1, w2, w4);
    s = rounds_a64(h, m, 28, s, w6);
    w6 = sched_a64(m, 28, w6, w7, w2, w3, w5);
    s = rounds_a64(h, m, 30, s, w7);
    w7 = sched_a64(m, 30, w7, w0, w3, w4, w6);
    s = rounds_a64(h, m, 32, s, w0);
    w0 = sched_a64(m, 32, w0, w1, w4, w5, w7);
    s = rounds_a64(h, m, 34, s, w1);
    w1 = sched_a64(m, 34, w1, w2, w5, w6, w0);
    s = rounds_a64(h, m, 36, s, w2);
    w2 = sched_a64(m, 36, w2, w3, w6, w7, w1);
    s = rounds_a64(h, m, 38, s, w3);
    w3 = sched_a64(m, 38, w3, w4, w7, w0, w2);
    s = rounds_a64(h, m, 40, s, w4);
    w4 = sched_a64(m, 40, w4, w5, w0, w1, w3);
    s = rounds_a64(h, m, 42, s, w5);
    w5 = sched_a64(m, 42, w5, w6, w1, w2, w4);
    s = rounds_a64(h, m, 44, s, w6);
    w6 = sched_a64(m, 44, w6, w7, w2, w3, w5);
    s = rounds_a64(h, m, 46, s, w7);
    w7 = sched_a64(m, 46, w7, w0, w3, w4, w6);
    s = rounds_a64(h, m, 48, s, w0);
    w0 = sched_a64(m, 48, w0, w1, w4, w5, w7);
    s = rounds_a64(h, m, 50, s, w1);
    w1 = sched_a64(m, 50, w1, w2, w5, w6, w0);
    s = rounds_a64(h, m, 52, s, w2);
    w2 = sched_a64(m, 52, w2, w3, w6, w7, w1);
    s = rounds_a64(h, m, 54, s, w3);
    w3 = sched_a64(m, 54, w3, w4, w7, w0, w2);
    s = rounds_a64(h, m, 56, s, w4);
    w4 = sched_a64(m, 56, w4, w5, w0, w1, w3);
    s = rounds_a64(h, m, 58, s, w5);
    w5 = sched_a64(m, 58, w5, w6, w1, w2, w4);
    s = rounds_a64(h, m, 60, s, w6);
    w6 = sched_a64(m, 60, w6, w7, w2, w3, w5);
    s = rounds_a64(h, m, 62, s, w7);
    w7 = sched_a64(m, 62, w7, w0, w3, w4, w6);
    s = rounds_a64(h, m, 64, s, w0);
    s = rounds_a64(h, m, 66, s, w1);
    s = rounds_a64(h, m, 68, s, w2);
    s = rounds_a64(h, m, 70, s, w3);
    s = rounds_a64(h, m, 72, s, w4);
    s = rounds_a64(h, m, 74, s, w5);
    s = rounds_a64(h, m, 76, s, w6);
    s = rounds_a64(h, m, 78, s, w7);
    return [h[0] + s[0], h[1] + s[1], h[2] + s[2], h[3] + s[3], h[4] + s[4], h[5] + s[5], h[6] + s[6], h[7] + s[7]];
}

// ---- x86-64's SHA-512 instructions ----
//
// VSHA512RNDS2, VSHA512MSG1 and VSHA512MSG2 (the SHA512 extension) compute two rounds or four schedule
// words per instruction. Their meaning is Intel's pseudocode (`std::crypto::secret`); the lemmas below
// prove the path that uses them computes `compress`.

// Schedule words `t..t + 4` of block `m`.
spec fn sched4(m: [Secret<u64>; 16], t: u32) [u64; 4]
    requires t <= 92
{
    return [sched(m, t), sched(m, t + 1), sched(m, t + 2), sched(m, t + 3)];
}

// Round constants `t..t + 4`.
spec fn k4(t: u32) [u64; 4]
    requires t <= 76
{
    return [K[t], K[t + 1], K[t + 2], K[t + 3]];
}

// The lanes' sums `w + k`.
spec fn add4(w: [u64; 4], k: [u64; 4]) [u64; 4] {
    return [w[0].wrapping_add(k[0]), w[1].wrapping_add(k[1]), w[2].wrapping_add(k[2]), w[3].wrapping_add(k[3])];
}

// Four rounds from `s` with words `w` and constants `k`.
spec fn round4(s: [u64; 8], w: [u64; 4], k: [u64; 4]) [u64; 8] {
    return round(round(round(round(s, w[0], k[0]), w[1], k[1]), w[2], k[2]), w[3], k[3]);
}

// Rounds `t..t + 4`, one at a time.
lemma rounds_four(h: [u64; 8], m: [Secret<u64>; 16], t: u32)
    requires t <= 76
    ensures rounds(h, m, t + 4) == round4(rounds(h, m, t), sched4(m, t), k4(t))
{
    assert rounds(h, m, t + 1) == round(rounds(h, m, t), sched(m, t), K[t]) by {};
    assert rounds(h, m, t + 2) == round(rounds(h, m, t + 1), sched(m, t + 1), K[t + 1]) by {};
    assert rounds(h, m, t + 3) == round(rounds(h, m, t + 2), sched(m, t + 2), K[t + 2]) by {};
    assert rounds(h, m, t + 4) == round(rounds(h, m, t + 3), sched(m, t + 3), K[t + 3]) by {};
}

// One round of Intel's VSHA512RNDS2 is one round.
lemma intel_round_is_round(s: [u64; 8], w: u64, k: u64)
    ensures intel_sha512_round(s, w.wrapping_add(k)) == round(s, w, k)
{
    assert (s[4] & s[5] ^ s[6] & ~s[4]) == ch(s[4], s[5], s[6]) by {};
}

// The words of `s` as VSHA512RNDS2 holds them: A, B, E, F in lanes 3 to 0 of the first four, C, D, G, H
// of the last four.
spec fn abef_cdgh(s: [u64; 8]) [u64; 8] {
    return [s[5], s[4], s[1], s[0], s[7], s[6], s[3], s[2]];
}

// The first four words of `x`, and the last four.
spec fn first4(x: [u64; 8]) [u64; 4] {
    return [x[0], x[1], x[2], x[3]];
}

spec fn last4(x: [u64; 8]) [u64; 4] {
    return [x[4], x[5], x[6], x[7]];
}

// Two VSHA512RNDS2 are four rounds: the first gives A, B, E, F after two, which are C, D, G, H after four.
lemma intel_rnds2_is_round4(s: [u64; 8], w: [u64; 4], k: [u64; 4])
    ensures intel_sha512_rnds2(
        last4(abef_cdgh(s)),
        first4(abef_cdgh(s)),
        [w[0].wrapping_add(k[0]), w[1].wrapping_add(k[1])],
    ) == last4(abef_cdgh(round4(s, w, k)))
    ensures intel_sha512_rnds2(
        first4(abef_cdgh(s)),
        last4(abef_cdgh(round4(s, w, k))),
        [w[2].wrapping_add(k[2]), w[3].wrapping_add(k[3])],
    ) == first4(abef_cdgh(round4(s, w, k)))
{
    let s1 = round(s, w[0], k[0]);
    let s2 = round(s1, w[1], k[1]);
    let s3 = round(s2, w[2], k[2]);
    intel_round_is_round(s, w[0], k[0]);
    intel_round_is_round(s1, w[1], k[1]);
    intel_round_is_round(s2, w[2], k[2]);
    intel_round_is_round(s3, w[3], k[3]);
}

// A schedule word's terms in VSHA512MSG1's, the add's and VSHA512MSG2's order, and in `sched`'s.
lemma intel_sched_order(w0: u64, s0: u64, w9: u64, s1: u64)
    ensures w0.wrapping_add(s0).wrapping_add(w9).wrapping_add(s1) == s1.wrapping_add(w9).wrapping_add(s0).wrapping_add(
        w0,
    )
{}

// Schedule words `t + 16..t + 20`: VSHA512MSG2 of VSHA512MSG1's first halves plus words `t + 9..t + 13`.
lemma intel_sched(m: [Secret<u64>; 16], t: u32)
    requires t <= 60
    ensures intel_sha512_msg2(
        add4(
            intel_sha512_msg1(sched4(m, t), [sched(m, t + 4), sched(m, t + 5)]),
            [sched(m, t + 9), sched(m, t + 10), sched(m, t + 11), sched(m, t + 12)],
        ),
        sched4(m, t + 12),
    ) == sched4(m, t + 16)
{
    intel_sched_order(sched(m, t), small_sigma0(sched(m, t + 1)), sched(m, t + 9), small_sigma1(sched(m, t + 14)));
    intel_sched_order(sched(m, t + 1), small_sigma0(sched(m, t + 2)), sched(m, t + 10), small_sigma1(sched(m, t + 15)));
    intel_sched_order(sched(m, t + 2), small_sigma0(sched(m, t + 3)), sched(m, t + 11), small_sigma1(sched(m, t + 16)));
    intel_sched_order(sched(m, t + 3), small_sigma0(sched(m, t + 4)), sched(m, t + 12), small_sigma1(sched(m, t + 17)));
}

// Rounds `t..t + 4` with x86-64's VSHA512RNDS2, the working variables as it holds them (`abef_cdgh`).
@always_inline
@constant_time
@arch(x86_64)
@target_feature([cpu::Feature::Sha512ni])
fn rounds_x64(h: [Secret<u64>; 8], m: [Secret<u64>; 16], t: u32, s: [Secret<u64>; 8], w: [Secret<u64>; 4]) [Secret<u64>; 8]
    requires t <= 76
    requires state_values(s) == abef_cdgh(rounds(state_values(h), m, t))
    requires qwords4(w) == sched4(m, t)
    ensures |r| state_values(r) == abef_cdgh(rounds(state_values(h), m, t + 4))
{
    let abef: [Secret<u64>; 4] = [s[0], s[1], s[2], s[3]];
    let cdgh: [Secret<u64>; 4] = [s[4], s[5], s[6], s[7]];
    let wk0: [Secret<u64>; 2] = [w[0] + Secret::new(K[t]), w[1] + Secret::new(K[t + 1])];
    let wk1: [Secret<u64>; 2] = [w[2] + Secret::new(K[t + 2]), w[3] + Secret::new(K[t + 3])];
    let half = sha512rnds2(cdgh, abef, wk0);
    let full = sha512rnds2(abef, half, wk1);
    assert words2(wk0) == [sched(m, t).wrapping_add(K[t]), sched(m, t + 1).wrapping_add(K[t + 1])] by {};
    assert words2(wk1) == [sched(m, t + 2).wrapping_add(K[t + 2]), sched(m, t + 3).wrapping_add(K[t + 3])] by {};
    assert qwords4(abef) == first4(state_values(s)) && qwords4(cdgh) == last4(state_values(s)) by {};
    assert qwords4(half) == last4(abef_cdgh(round4(rounds(state_values(h), m, t), sched4(m, t), k4(t)))) by {
        intel_rnds2_is_round4(rounds(state_values(h), m, t), sched4(m, t), k4(t));
    };
    assert qwords4(full) == first4(abef_cdgh(round4(rounds(state_values(h), m, t), sched4(m, t), k4(t)))) by {
        intel_rnds2_is_round4(rounds(state_values(h), m, t), sched4(m, t), k4(t));
    };
    rounds_four(state_values(h), m, t);
    return [full[0], full[1], full[2], full[3], half[0], half[1], half[2], half[3]];
}

// Schedule words `t + 16..t + 20` with x86-64's VSHA512MSG1 and VSHA512MSG2.
@always_inline
@constant_time
@arch(x86_64)
@target_feature([cpu::Feature::Sha512ni])
fn sched_x64(
    m: [Secret<u64>; 16],
    t: u32,
    w0: [Secret<u64>; 4],
    w1: [Secret<u64>; 4],
    w2: [Secret<u64>; 4],
    w3: [Secret<u64>; 4],
) [Secret<u64>; 4]
    requires t <= 60
    requires qwords4(w0) == sched4(m, t) && qwords4(w1) == sched4(m, t + 4)
    requires qwords4(w2) == sched4(m, t + 8) && qwords4(w3) == sched4(m, t + 12)
    ensures |r| qwords4(r) == sched4(m, t + 16)
{
    intel_sched(m, t);
    let h = sha512msg1(w0, [w1[0], w1[1]]);
    return sha512msg2([h[0] + w2[1], h[1] + w2[2], h[2] + w2[3], h[3] + w3[0]], w3);
}

// Block `m` on state `h` with x86-64's SHA-512 instructions. The window `w0..w3` holds schedule words
// `t..t + 16`.
@constant_time
@arch(x86_64)
@target_feature([cpu::Feature::Sha512ni])
fn compress_x64(h: [Secret<u64>; 8], m: [Secret<u64>; 16]) [Secret<u64>; 8]
    ensures |r| state_values(r) == compress(state_values(h), m)
{
    let mut s: [Secret<u64>; 8] = [h[5], h[4], h[1], h[0], h[7], h[6], h[3], h[2]];
    let mut w0: [Secret<u64>; 4] = [m[0], m[1], m[2], m[3]];
    let mut w1: [Secret<u64>; 4] = [m[4], m[5], m[6], m[7]];
    let mut w2: [Secret<u64>; 4] = [m[8], m[9], m[10], m[11]];
    let mut w3: [Secret<u64>; 4] = [m[12], m[13], m[14], m[15]];
    // The 80 rounds in order, four at a time, each window taking its next words in place once read.
    s = rounds_x64(h, m, 0, s, w0);
    w0 = sched_x64(m, 0, w0, w1, w2, w3);
    s = rounds_x64(h, m, 4, s, w1);
    w1 = sched_x64(m, 4, w1, w2, w3, w0);
    s = rounds_x64(h, m, 8, s, w2);
    w2 = sched_x64(m, 8, w2, w3, w0, w1);
    s = rounds_x64(h, m, 12, s, w3);
    w3 = sched_x64(m, 12, w3, w0, w1, w2);
    s = rounds_x64(h, m, 16, s, w0);
    w0 = sched_x64(m, 16, w0, w1, w2, w3);
    s = rounds_x64(h, m, 20, s, w1);
    w1 = sched_x64(m, 20, w1, w2, w3, w0);
    s = rounds_x64(h, m, 24, s, w2);
    w2 = sched_x64(m, 24, w2, w3, w0, w1);
    s = rounds_x64(h, m, 28, s, w3);
    w3 = sched_x64(m, 28, w3, w0, w1, w2);
    s = rounds_x64(h, m, 32, s, w0);
    w0 = sched_x64(m, 32, w0, w1, w2, w3);
    s = rounds_x64(h, m, 36, s, w1);
    w1 = sched_x64(m, 36, w1, w2, w3, w0);
    s = rounds_x64(h, m, 40, s, w2);
    w2 = sched_x64(m, 40, w2, w3, w0, w1);
    s = rounds_x64(h, m, 44, s, w3);
    w3 = sched_x64(m, 44, w3, w0, w1, w2);
    s = rounds_x64(h, m, 48, s, w0);
    w0 = sched_x64(m, 48, w0, w1, w2, w3);
    s = rounds_x64(h, m, 52, s, w1);
    w1 = sched_x64(m, 52, w1, w2, w3, w0);
    s = rounds_x64(h, m, 56, s, w2);
    w2 = sched_x64(m, 56, w2, w3, w0, w1);
    s = rounds_x64(h, m, 60, s, w3);
    w3 = sched_x64(m, 60, w3, w0, w1, w2);
    s = rounds_x64(h, m, 64, s, w0);
    s = rounds_x64(h, m, 68, s, w1);
    s = rounds_x64(h, m, 72, s, w2);
    s = rounds_x64(h, m, 76, s, w3);
    return [h[0] + s[3], h[1] + s[2], h[2] + s[7], h[3] + s[6], h[4] + s[1], h[5] + s[0], h[6] + s[5], h[7] + s[4]];
}

// Block `m` on state `h`, with the processor's SHA-512 instructions when `hw` (the machine has them,
// `hw_ok`).
@constant_time
@arch(aarch64)
fn compress_on(h: [Secret<u64>; 8], m: [Secret<u64>; 16], hw: bool) [Secret<u64>; 8]
    ensures |r| state_values(r) == compress(state_values(h), m)
{
    if hw {
        return unsafe compress_a64(h, m);
    }
    return compress_ct(h, m);
}

@constant_time
@arch(x86_64)
fn compress_on(h: [Secret<u64>; 8], m: [Secret<u64>; 16], hw: bool) [Secret<u64>; 8]
    ensures |r| state_values(r) == compress(state_values(h), m)
{
    if hw {
        return unsafe compress_x64(h, m);
    }
    return compress_ct(h, m);
}

@constant_time
@arch(wasm32)
fn compress_on(h: [Secret<u64>; 8], m: [Secret<u64>; 16], _hw: bool) [Secret<u64>; 8]
    ensures |r| state_values(r) == compress(state_values(h), m)
{
    return compress_ct(h, m);
}

// Whether this machine has the SHA-512 instructions `compress_on` uses.
@arch(aarch64)
fn hw_ok() bool {
    return detect::has(cpu::Feature::Sha512);
}

@arch(x86_64)
fn hw_ok() bool {
    return detect::has(cpu::Feature::Sha512ni);
}

@arch(wasm32)
const fn hw_ok() bool {
    return false;
}

/// The SHA-512 digest of `msg` (FIPS 180-4), with the processor's SHA-512 instructions where the
/// machine has them (arm64 FEAT_SHA512, x86-64's SHA512 extension).
@constant_time
pub fn sha512(msg: []Secret<u8>) [Secret<u8>; 64]
    ensures |d| byte_values(d) == digest(msg)
{
    return digest_with(msg, hw_ok());
}

/// The SHA-512 digest of `msg` without the processor's SHA-512 instructions: the same digest as `sha512`.
@constant_time
pub fn sha512_portable(msg: []Secret<u8>) [Secret<u8>; 64]
    ensures |d| byte_values(d) == digest(msg)
{
    return digest_with(msg, false);
}

// The digest of `msg`, with the processor's instructions when `hw`.
@constant_time
fn digest_with(msg: []Secret<u8>, hw: bool) [Secret<u8>; 64]
    ensures |d| byte_values(d) == digest(msg)
{
    let nb = (msg.len() + 16) / 128 + 1;
    let mut h: [Secret<u64>; 8] = [
        Secret::new(0x6a09e667f3bcc908u64),
        Secret::new(0xbb67ae8584caa73bu64),
        Secret::new(0x3c6ef372fe94f82bu64),
        Secret::new(0xa54ff53a5f1d36f1u64),
        Secret::new(0x510e527fade682d1u64),
        Secret::new(0x9b05688c2b3e6c1fu64),
        Secret::new(0x1f83d9abfb41bd6bu64),
        Secret::new(0x5be0cd19137e2179u64),
    ];
    let mut b: usize = 0;
    while b < nb
        invariant b <= nb
        invariant state_values(h) == hashes(msg, b as int)
    {
        h = absorb(msg, b, h, hw);
        b += 1;
    }
    assert b as int == (msg.len() as int + 16) / 128 + 1 by {};
    assert state_values(h) == hashes(msg, (msg.len() as int + 16) / 128 + 1) by {};
    return to_bytes(h);
}
