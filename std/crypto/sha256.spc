// SHA-256 (FIPS 180-4), proved: the specification is the standard's text as spec functions (the
// functions of 4.1.2, the schedule and the rounds of 6.2.2, the padding of 5.1.1 and the initial state of
// 5.3.3), and `sha256` computes exactly the digest it defines. Every function runs in constant time on
// the message bytes (`@constant_time`): only the message length, which is public, picks a branch or an
// index. No operation panics: the prover proves each check. The length field is the message's length in
// bits modulo 2^64; the standard defines no message of 2^64 bits or more. Import with
// `import std::crypto::sha256;`.

import std::crypto::secret as *;
import std::cpu;
import std::cpu::detect as detect;

// The functions of FIPS 180-4, 4.1.2.
spec fn ch(x: u32, y: u32, z: u32) u32 {
    return x & y ^ ~x & z;
}

spec fn maj(x: u32, y: u32, z: u32) u32 {
    return x & y ^ x & z ^ y & z;
}

spec fn big_sigma0(x: u32) u32 {
    return x.rotate_right(2) ^ x.rotate_right(13) ^ x.rotate_right(22);
}

spec fn big_sigma1(x: u32) u32 {
    return x.rotate_right(6) ^ x.rotate_right(11) ^ x.rotate_right(25);
}

spec fn small_sigma0(x: u32) u32 {
    return x.rotate_right(7) ^ x.rotate_right(18) ^ x >> 3;
}

spec fn small_sigma1(x: u32) u32 {
    return x.rotate_right(17) ^ x.rotate_right(19) ^ x >> 10;
}

// The round constants (4.2.2).
const K: [u32; 64] = [
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
];

// Word `t` of the message schedule of block `m` (6.2.2, step 1), defined up to word 79 so that the
// window of 16 words the loop keeps is defined at each of its 64 steps.
spec fn sched(m: [Secret<u32>; 16], t: u32) u32
    requires t < 80
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

// One round on the working variables `a..h` (6.2.2, step 3).
spec fn round(s: [u32; 8], w: u32, k: u32) [u32; 8] {
    let t1 = s[7].wrapping_add(big_sigma1(s[4])).wrapping_add(ch(s[4], s[5], s[6])).wrapping_add(k).wrapping_add(w);
    let t2 = big_sigma0(s[0]).wrapping_add(maj(s[0], s[1], s[2]));
    return [t1.wrapping_add(t2), s[0], s[1], s[2], s[3].wrapping_add(t1), s[4], s[5], s[6]];
}

// The working variables after rounds `0..t` from state `h`.
spec fn rounds(h: [u32; 8], m: [Secret<u32>; 16], t: u32) [u32; 8]
    requires t <= 64
    decreases t
{
    return if t == 0 {
        h
    } else {
        round(rounds(h, m, t - 1), sched(m, t - 1), K[t - 1])
    };
}

// The state after block `m` (6.2.2, step 4).
spec fn compress(h: [u32; 8], m: [Secret<u32>; 16]) [u32; 8] {
    let s = rounds(h, m, 64);
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

// The initial state (5.3.3).
spec fn h0() [u32; 8] {
    return [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
}

// The length of the padded message of `n` bytes: the message, 0x80, zeros and the 8 length bytes, a
// multiple of 64.
spec fn padded_len(n: int) int {
    return (n + 8) / 64 * 64 + 64;
}

// Byte `p` of the padded message (5.1.1); 0 outside it.
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
spec fn word(msg: []Secret<u8>, p: int) u32 {
    return padded(msg, p) as u32 << 24 | padded(msg, p + 1) as u32 << 16 | padded(msg, p + 2) as u32 << 8 | padded(
        msg,
        p + 3,
    ) as u32;
}

// Block `b` of the padded message as 16 words (5.2.1).
spec fn block(msg: []Secret<u8>, b: int) [Secret<u32>; 16] {
    let p = b * 64;
    return [
        Secret::new(word(msg, p)),
        Secret::new(word(msg, p + 4)),
        Secret::new(word(msg, p + 8)),
        Secret::new(word(msg, p + 12)),
        Secret::new(word(msg, p + 16)),
        Secret::new(word(msg, p + 20)),
        Secret::new(word(msg, p + 24)),
        Secret::new(word(msg, p + 28)),
        Secret::new(word(msg, p + 32)),
        Secret::new(word(msg, p + 36)),
        Secret::new(word(msg, p + 40)),
        Secret::new(word(msg, p + 44)),
        Secret::new(word(msg, p + 48)),
        Secret::new(word(msg, p + 52)),
        Secret::new(word(msg, p + 56)),
        Secret::new(word(msg, p + 60)),
    ];
}

// The state after blocks `0..b` of the padded message.
spec fn hashes(msg: []Secret<u8>, b: int) [u32; 8]
    decreases b
{
    return if b <= 0 {
        h0()
    } else {
        compress(hashes(msg, b - 1), block(msg, b - 1))
    };
}

// The state's words as big-endian bytes.
spec fn be_bytes(h: [u32; 8]) [u8; 32] {
    return [
        (h[0] >> 24) as u8,
        (h[0] >> 16) as u8,
        (h[0] >> 8) as u8,
        (h[0] >> 0) as u8,
        (h[1] >> 24) as u8,
        (h[1] >> 16) as u8,
        (h[1] >> 8) as u8,
        (h[1] >> 0) as u8,
        (h[2] >> 24) as u8,
        (h[2] >> 16) as u8,
        (h[2] >> 8) as u8,
        (h[2] >> 0) as u8,
        (h[3] >> 24) as u8,
        (h[3] >> 16) as u8,
        (h[3] >> 8) as u8,
        (h[3] >> 0) as u8,
        (h[4] >> 24) as u8,
        (h[4] >> 16) as u8,
        (h[4] >> 8) as u8,
        (h[4] >> 0) as u8,
        (h[5] >> 24) as u8,
        (h[5] >> 16) as u8,
        (h[5] >> 8) as u8,
        (h[5] >> 0) as u8,
        (h[6] >> 24) as u8,
        (h[6] >> 16) as u8,
        (h[6] >> 8) as u8,
        (h[6] >> 0) as u8,
        (h[7] >> 24) as u8,
        (h[7] >> 16) as u8,
        (h[7] >> 8) as u8,
        (h[7] >> 0) as u8,
    ];
}

/// The SHA-256 digest of `msg` (FIPS 180-4, 6.2), the specification `sha256` meets.
pub spec fn digest(msg: []Secret<u8>) [u8; 32] {
    return be_bytes(hashes(msg, (msg.len() as int + 8) / 64 + 1));
}

/// The values of the bytes of `d`.
pub spec fn byte_values(d: [Secret<u8>; 32]) [u8; 32] {
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
    ];
}

// The values of the words of state `s`.
spec fn state_values(s: [Secret<u32>; 8]) [u32; 8] {
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
fn round_ct(s: [Secret<u32>; 8], w: Secret<u32>, k: u32) [Secret<u32>; 8]
    ensures |r| state_values(r) == round(state_values(s), w.value(), k)
{
    let a = s[0];
    let e = s[4];
    let t1 = s[7] + (e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25)) + (e & s[5] ^ ~e & s[6]) + Secret::new(
        k,
    ) + w;
    let t2 = (a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22)) + (a & s[1] ^ a & s[2] ^ s[1] & s[2]);
    return [t1 + t2, s[0], s[1], s[2], s[3] + t1, s[4], s[5], s[6]];
}

@constant_time
fn sched_ct(a: Secret<u32>, b: Secret<u32>, c: Secret<u32>, d: Secret<u32>) Secret<u32>
    ensures |r| r.value() == small_sigma1(a.value()).wrapping_add(b.value()).wrapping_add(small_sigma0(c.value())).wrapping_add(
        d.value(),
    )
{
    return (a.rotate_right(17) ^ a.rotate_right(19) ^ a >> 10) + b + (c.rotate_right(7) ^ c.rotate_right(18) ^ c >> 3) + d;
}

// Schedule word `t + 16` from words `t`, `t + 1`, `t + 9` and `t + 14`.
@constant_time
fn next_word(m: [Secret<u32>; 16], t: u32, w0: Secret<u32>, w1: Secret<u32>, w9: Secret<u32>, w14: Secret<u32>) Secret<
    u32
>
    requires t < 64
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
fn next_state(h: [Secret<u32>; 8], m: [Secret<u32>; 16], t: u32, s: [Secret<u32>; 8], w0: Secret<u32>) [Secret<u32>; 8]
    requires t < 64
    requires state_values(s) == rounds(state_values(h), m, t)
    requires w0.value() == sched(m, t)
    ensures |r| state_values(r) == rounds(state_values(h), m, t + 1)
{
    return round_ct(s, w0, K[t]);
}

// Block `m` on state `h`. The window `w` holds schedule words `t..t + 16`.
@constant_time
fn compress_ct(h: [Secret<u32>; 8], m: [Secret<u32>; 16]) [Secret<u32>; 8]
    ensures |r| state_values(r) == compress(state_values(h), m)
{
    let mut w = m;
    let mut s = h;
    let mut t: u32 = 0;
    while t < 64
        invariant t <= 64
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
    assert t == 64 by {};
    assert state_values(s) == rounds(state_values(h), m, 64) by {};
    return [h[0] + s[0], h[1] + s[1], h[2] + s[2], h[3] + s[3], h[4] + s[4], h[5] + s[5], h[6] + s[6], h[7] + s[7]];
}

// Byte `p` of the padded message.
@constant_time
const fn pad_byte(msg: []Secret<u8>, p: usize) Secret<u8>
    requires p as int < padded_len(msg.len() as int)
    ensures |r| r.value() == padded(msg, p as int)
{
    let n = msg.len();
    let end = (n + 8) / 64 * 64 + 64;
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
fn word_at(msg: []Secret<u8>, p: usize) Secret<u32>
    requires p as int + 4 <= padded_len(msg.len() as int)
    ensures |r| r.value() == word(msg, p as int)
{
    let a = pad_byte(msg, p).cast::<u32>();
    let b = pad_byte(msg, p + 1).cast::<u32>();
    let c = pad_byte(msg, p + 2).cast::<u32>();
    let d = pad_byte(msg, p + 3).cast::<u32>();
    return a << 24 | b << 16 | c << 8 | d;
}

// The big-endian word at byte `p` of the message, inside it.
@constant_time
fn msg_word_at(msg: []Secret<u8>, p: usize) Secret<u32>
    requires p as int + 4 <= msg.len() as int
    ensures |r| r.value() == word(msg, p as int)
{
    return msg[p].cast::<u32>() << 24 | msg[p + 1].cast::<u32>() << 16 | msg[p + 2].cast::<u32>() << 8 | msg[p + 3].cast::<
        u32
    >();
}

// Block `b` of the message, inside it: no padding byte.
@constant_time
fn load_full_block(msg: []Secret<u8>, b: usize) [Secret<u32>; 16]
    requires (b as int + 1) * 64 <= msg.len() as int
    ensures |m| m == block(msg, b as int)
{
    let p = b * 64;
    return [
        msg_word_at(msg, p),
        msg_word_at(msg, p + 4),
        msg_word_at(msg, p + 8),
        msg_word_at(msg, p + 12),
        msg_word_at(msg, p + 16),
        msg_word_at(msg, p + 20),
        msg_word_at(msg, p + 24),
        msg_word_at(msg, p + 28),
        msg_word_at(msg, p + 32),
        msg_word_at(msg, p + 36),
        msg_word_at(msg, p + 40),
        msg_word_at(msg, p + 44),
        msg_word_at(msg, p + 48),
        msg_word_at(msg, p + 52),
        msg_word_at(msg, p + 56),
        msg_word_at(msg, p + 60),
    ];
}

// Block `b` of the padded message.
@constant_time
fn load_block(msg: []Secret<u8>, b: usize) [Secret<u32>; 16]
    requires (b as int + 1) * 64 <= padded_len(msg.len() as int)
    ensures |m| m == block(msg, b as int)
{
    let p = b * 64;
    if p + 64 <= msg.len() {
        return load_full_block(msg, b);
    }
    return [
        word_at(msg, p),
        word_at(msg, p + 4),
        word_at(msg, p + 8),
        word_at(msg, p + 12),
        word_at(msg, p + 16),
        word_at(msg, p + 20),
        word_at(msg, p + 24),
        word_at(msg, p + 28),
        word_at(msg, p + 32),
        word_at(msg, p + 36),
        word_at(msg, p + 40),
        word_at(msg, p + 44),
        word_at(msg, p + 48),
        word_at(msg, p + 52),
        word_at(msg, p + 56),
        word_at(msg, p + 60),
    ];
}

@constant_time
fn to_bytes(h: [Secret<u32>; 8]) [Secret<u8>; 32]
    ensures |d| byte_values(d) == be_bytes(state_values(h))
{
    return [
        (h[0] >> 24).cast::<u8>(),
        (h[0] >> 16).cast::<u8>(),
        (h[0] >> 8).cast::<u8>(),
        (h[0] >> 0).cast::<u8>(),
        (h[1] >> 24).cast::<u8>(),
        (h[1] >> 16).cast::<u8>(),
        (h[1] >> 8).cast::<u8>(),
        (h[1] >> 0).cast::<u8>(),
        (h[2] >> 24).cast::<u8>(),
        (h[2] >> 16).cast::<u8>(),
        (h[2] >> 8).cast::<u8>(),
        (h[2] >> 0).cast::<u8>(),
        (h[3] >> 24).cast::<u8>(),
        (h[3] >> 16).cast::<u8>(),
        (h[3] >> 8).cast::<u8>(),
        (h[3] >> 0).cast::<u8>(),
        (h[4] >> 24).cast::<u8>(),
        (h[4] >> 16).cast::<u8>(),
        (h[4] >> 8).cast::<u8>(),
        (h[4] >> 0).cast::<u8>(),
        (h[5] >> 24).cast::<u8>(),
        (h[5] >> 16).cast::<u8>(),
        (h[5] >> 8).cast::<u8>(),
        (h[5] >> 0).cast::<u8>(),
        (h[6] >> 24).cast::<u8>(),
        (h[6] >> 16).cast::<u8>(),
        (h[6] >> 8).cast::<u8>(),
        (h[6] >> 0).cast::<u8>(),
        (h[7] >> 24).cast::<u8>(),
        (h[7] >> 16).cast::<u8>(),
        (h[7] >> 8).cast::<u8>(),
        (h[7] >> 0).cast::<u8>(),
    ];
}

// Block `b` on state `h`.
@constant_time
fn absorb_block(msg: []Secret<u8>, b: usize, h: [Secret<u32>; 8], hw: bool) [Secret<u32>; 8]
    requires (b as int + 1) * 64 <= padded_len(msg.len() as int)
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
fn absorb(msg: []Secret<u8>, b: usize, h: [Secret<u32>; 8], hw: bool) [Secret<u32>; 8]
    requires (b as int + 1) * 64 <= padded_len(msg.len() as int)
    requires state_values(h) == hashes(msg, b as int)
    ensures |r| state_values(r) == hashes(msg, b as int + 1)
{
    hashes_step(msg, b as int);
    return absorb_block(msg, b, h, hw);
}

// ---- The processor's SHA-256 instructions ----
//
// arm64's SHA256H, SHA256H2, SHA256SU0, SHA256SU1 (FEAT_SHA256) and x86-64's SHA256RNDS2, SHA256MSG1,
// SHA256MSG2 (SHA-NI) compute four or two rounds, or four schedule words, per instruction. Their meaning is
// the vendor's pseudocode (`std::crypto::secret`); the lemmas below prove the paths that use them compute
// `compress`. Each orders its sums differently from FIPS 180-4's text: wrapping addition is associative
// and commutative, one step at a time.

lemma add_comm(a: u32, b: u32)
    ensures a.wrapping_add(b) == b.wrapping_add(a)
{}

lemma add_assoc(a: u32, b: u32, c: u32)
    ensures a.wrapping_add(b).wrapping_add(c) == a.wrapping_add(b.wrapping_add(c))
{}

// The first four words of `s`, and the last four.
spec fn lo4(s: [u32; 8]) [u32; 4] {
    return [s[0], s[1], s[2], s[3]];
}

spec fn hi4(s: [u32; 8]) [u32; 4] {
    return [s[4], s[5], s[6], s[7]];
}

// Schedule words `t..t + 4` of block `m`.
spec fn sched4(m: [Secret<u32>; 16], t: u32) [u32; 4]
    requires t <= 76
{
    return [sched(m, t), sched(m, t + 1), sched(m, t + 2), sched(m, t + 3)];
}

// Round constants `t..t + 4`.
spec fn k4(t: u32) [u32; 4]
    requires t <= 60
{
    return [K[t], K[t + 1], K[t + 2], K[t + 3]];
}

// The lanes' sums `w + k`.
spec fn add4(w: [u32; 4], k: [u32; 4]) [u32; 4] {
    return [w[0].wrapping_add(k[0]), w[1].wrapping_add(k[1]), w[2].wrapping_add(k[2]), w[3].wrapping_add(k[3])];
}

// Four rounds from `s` with words `w` and constants `k`.
spec fn round4(s: [u32; 8], w: [u32; 4], k: [u32; 4]) [u32; 8] {
    return round(round(round(round(s, w[0], k[0]), w[1], k[1]), w[2], k[2]), w[3], k[3]);
}

// Rounds `t..t + 4`, one at a time.
lemma rounds_four(h: [u32; 8], m: [Secret<u32>; 16], t: u32)
    requires t <= 60
    ensures rounds(h, m, t + 4) == round4(rounds(h, m, t), sched4(m, t), k4(t))
{
    assert rounds(h, m, t + 1) == round(rounds(h, m, t), sched(m, t), K[t]) by {};
    assert rounds(h, m, t + 2) == round(rounds(h, m, t + 1), sched(m, t + 1), K[t + 1]) by {};
    assert rounds(h, m, t + 3) == round(rounds(h, m, t + 2), sched(m, t + 2), K[t + 2]) by {};
    assert rounds(h, m, t + 4) == round(rounds(h, m, t + 3), sched(m, t + 3), K[t + 3]) by {};
}

// The sum `h + sigma1(e) + ch(e, f, g) + k + w` of a round, with `w + k` added at once.
lemma t1_order(x: u32, k: u32, w: u32)
    ensures x.wrapping_add(k).wrapping_add(w) == x.wrapping_add(w.wrapping_add(k))
{
    add_assoc(x, k, w);
    add_comm(k, w);
}

// One iteration of Arm's SHA256hash is one round.
lemma arm_step_is_round(s: [u32; 8], w: u32, k: u32)
    ensures arm_sha256_step(s, w.wrapping_add(k)) == round(s, w, k)
{
    let x = s[7].wrapping_add(big_sigma1(s[4])).wrapping_add(ch(s[4], s[5], s[6]));
    assert ((s[5] ^ s[6]) & s[4] ^ s[6]) == ch(s[4], s[5], s[6]) by {};
    assert (s[0] & s[1] | (s[0] | s[1]) & s[2]) == maj(s[0], s[1], s[2]) by {};
    t1_order(x, k, w);
    let t1 = x.wrapping_add(k).wrapping_add(w);
    add_assoc(t1, big_sigma0(s[0]), maj(s[0], s[1], s[2]));
    add_comm(t1, s[3]);
}

// Arm's SHA256H and SHA256H2 on the halves of `s` are its next four rounds.
lemma arm_hash_is_round4(s: [u32; 8], w: [u32; 4], k: [u32; 4])
    ensures arm_sha256_hash(lo4(s), hi4(s), add4(w, k), true) == lo4(round4(s, w, k))
    ensures arm_sha256_hash(lo4(s), hi4(s), add4(w, k), false) == hi4(round4(s, w, k))
{
    let s1 = round(s, w[0], k[0]);
    let s2 = round(s1, w[1], k[1]);
    let s3 = round(s2, w[2], k[2]);
    assert [s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]] == s by {};
    arm_step_is_round(s, w[0], k[0]);
    arm_step_is_round(s1, w[1], k[1]);
    arm_step_is_round(s2, w[2], k[2]);
    arm_step_is_round(s3, w[3], k[3]);
}

// Schedule word `t + 16` from words `t`, `t + 1`, `t + 9` and `t + 14` as SHA256SU0 and SHA256SU1 (or
// SHA256MSG1, an addition and SHA256MSG2) sum them.
lemma sched_order(w0: u32, s0: u32, w9: u32, s1: u32)
    ensures s1.wrapping_add(w9).wrapping_add(s0).wrapping_add(w0) == s1.wrapping_add(s0.wrapping_add(w0)).wrapping_add(
        w9,
    )
    ensures s1.wrapping_add(w9).wrapping_add(s0).wrapping_add(w0) == w0.wrapping_add(s0).wrapping_add(w9).wrapping_add(
        s1,
    )
{
    // s1 + w9 + s0 + w0 == s1 + (w9 + (s0 + w0)) == s1 + ((s0 + w0) + w9) == (s1 + (s0 + w0)) + w9.
    add_assoc(s1, w9, s0);
    add_assoc(s1, w9.wrapping_add(s0), w0);
    add_assoc(w9, s0, w0);
    add_comm(w9, s0.wrapping_add(w0));
    add_assoc(s1, s0.wrapping_add(w0), w9);
    // (w0 + s0 + w9) + s1 == s1 + ((s0 + w0) + w9).
    add_comm(w0, s0);
    add_comm(s0.wrapping_add(w0).wrapping_add(w9), s1);
    add_assoc(s0, w0, w9);
}

// Schedule words `t + 16..t + 20`: SHA256SU1 of SHA256SU0's first halves.
lemma arm_sched(m: [Secret<u32>; 16], t: u32)
    requires t <= 60
    ensures arm_sha256_su1(arm_sha256_su0(sched4(m, t), sched4(m, t + 4)), sched4(m, t + 8), sched4(m, t + 12)) == sched4(
        m,
        t + 16,
    )
{
    sched_order(sched(m, t), small_sigma0(sched(m, t + 1)), sched(m, t + 9), small_sigma1(sched(m, t + 14)));
    sched_order(sched(m, t + 1), small_sigma0(sched(m, t + 2)), sched(m, t + 10), small_sigma1(sched(m, t + 15)));
    sched_order(sched(m, t + 2), small_sigma0(sched(m, t + 3)), sched(m, t + 11), small_sigma1(sched(m, t + 16)));
    sched_order(sched(m, t + 3), small_sigma0(sched(m, t + 4)), sched(m, t + 12), small_sigma1(sched(m, t + 17)));
}

// Rounds `t..t + 4` on the working variables after rounds `0..t`, with arm64's SHA256H and SHA256H2.
@always_inline
@constant_time
@arch(aarch64)
@target_feature([cpu::Feature::Sha2])
fn rounds_a64(h: [Secret<u32>; 8], m: [Secret<u32>; 16], t: u32, s: [Secret<u32>; 8], w: [Secret<u32>; 4]) [Secret<u32>; 8]
    requires t <= 60
    requires state_values(s) == rounds(state_values(h), m, t)
    requires words4(w) == sched4(m, t)
    ensures |r| state_values(r) == rounds(state_values(h), m, t + 4)
{
    let x: [Secret<u32>; 4] = [s[0], s[1], s[2], s[3]];
    let y: [Secret<u32>; 4] = [s[4], s[5], s[6], s[7]];
    let wk: [Secret<u32>; 4] = [
        w[0] + Secret::new(K[t]),
        w[1] + Secret::new(K[t + 1]),
        w[2] + Secret::new(K[t + 2]),
        w[3] + Secret::new(K[t + 3]),
    ];
    let nx = sha256h(x, y, wk);
    let ny = sha256h2(y, x, wk);
    assert words4(wk) == add4(sched4(m, t), k4(t)) by {};
    assert words4(x) == lo4(state_values(s)) && words4(y) == hi4(state_values(s)) by {};
    assert words4(nx) == lo4(round4(state_values(s), sched4(m, t), k4(t))) by {
        arm_hash_is_round4(state_values(s), sched4(m, t), k4(t));
    };
    assert words4(ny) == hi4(round4(state_values(s), sched4(m, t), k4(t))) by {
        arm_hash_is_round4(state_values(s), sched4(m, t), k4(t));
    };
    rounds_four(state_values(h), m, t);
    return [nx[0], nx[1], nx[2], nx[3], ny[0], ny[1], ny[2], ny[3]];
}

// Schedule words `t + 16..t + 20` with arm64's SHA256SU0 and SHA256SU1.
@always_inline
@constant_time
@arch(aarch64)
@target_feature([cpu::Feature::Sha2])
fn sched_a64(
    m: [Secret<u32>; 16],
    t: u32,
    w0: [Secret<u32>; 4],
    w1: [Secret<u32>; 4],
    w2: [Secret<u32>; 4],
    w3: [Secret<u32>; 4],
) [Secret<u32>; 4]
    requires t <= 60
    requires words4(w0) == sched4(m, t) && words4(w1) == sched4(m, t + 4)
    requires words4(w2) == sched4(m, t + 8) && words4(w3) == sched4(m, t + 12)
    ensures |r| words4(r) == sched4(m, t + 16)
{
    arm_sched(m, t);
    return sha256su1(sha256su0(w0, w1), w2, w3);
}

// Block `m` on state `h` with arm64's SHA-256 instructions. The window `w0..w3` holds schedule words
// `t..t + 16`.
@constant_time
@arch(aarch64)
@target_feature([cpu::Feature::Sha2])
fn compress_a64(h: [Secret<u32>; 8], m: [Secret<u32>; 16]) [Secret<u32>; 8]
    ensures |r| state_values(r) == compress(state_values(h), m)
{
    let mut s = h;
    let mut w0: [Secret<u32>; 4] = [m[0], m[1], m[2], m[3]];
    let mut w1: [Secret<u32>; 4] = [m[4], m[5], m[6], m[7]];
    let mut w2: [Secret<u32>; 4] = [m[8], m[9], m[10], m[11]];
    let mut w3: [Secret<u32>; 4] = [m[12], m[13], m[14], m[15]];
    // The 64 rounds in order, four at a time, each window taking its next words in place once read.
    s = rounds_a64(h, m, 0, s, w0);
    w0 = sched_a64(m, 0, w0, w1, w2, w3);
    s = rounds_a64(h, m, 4, s, w1);
    w1 = sched_a64(m, 4, w1, w2, w3, w0);
    s = rounds_a64(h, m, 8, s, w2);
    w2 = sched_a64(m, 8, w2, w3, w0, w1);
    s = rounds_a64(h, m, 12, s, w3);
    w3 = sched_a64(m, 12, w3, w0, w1, w2);
    s = rounds_a64(h, m, 16, s, w0);
    w0 = sched_a64(m, 16, w0, w1, w2, w3);
    s = rounds_a64(h, m, 20, s, w1);
    w1 = sched_a64(m, 20, w1, w2, w3, w0);
    s = rounds_a64(h, m, 24, s, w2);
    w2 = sched_a64(m, 24, w2, w3, w0, w1);
    s = rounds_a64(h, m, 28, s, w3);
    w3 = sched_a64(m, 28, w3, w0, w1, w2);
    s = rounds_a64(h, m, 32, s, w0);
    w0 = sched_a64(m, 32, w0, w1, w2, w3);
    s = rounds_a64(h, m, 36, s, w1);
    w1 = sched_a64(m, 36, w1, w2, w3, w0);
    s = rounds_a64(h, m, 40, s, w2);
    w2 = sched_a64(m, 40, w2, w3, w0, w1);
    s = rounds_a64(h, m, 44, s, w3);
    w3 = sched_a64(m, 44, w3, w0, w1, w2);
    s = rounds_a64(h, m, 48, s, w0);
    s = rounds_a64(h, m, 52, s, w1);
    s = rounds_a64(h, m, 56, s, w2);
    s = rounds_a64(h, m, 60, s, w3);
    return [h[0] + s[0], h[1] + s[1], h[2] + s[2], h[3] + s[3], h[4] + s[4], h[5] + s[5], h[6] + s[6], h[7] + s[7]];
}

// One round of Intel's SHA256RNDS2 is one round.
lemma intel_round_is_round(s: [u32; 8], w: u32, k: u32)
    ensures intel_sha256_round(s, w.wrapping_add(k)) == round(s, w, k)
{
    let c = ch(s[4], s[5], s[6]);
    let e1 = big_sigma1(s[4]);
    let x = w.wrapping_add(k);
    let p = s[7].wrapping_add(e1).wrapping_add(c);
    t1_order(p, k, w);
    // ((c + e1) + x) + h == ((h + e1) + c) + x.
    add_assoc(c.wrapping_add(e1), x, s[7]);
    add_comm(x, s[7]);
    add_assoc(c.wrapping_add(e1), s[7], x);
    add_comm(c.wrapping_add(e1), s[7]);
    add_comm(c, e1);
    add_assoc(s[7], e1, c);
    let t = p.wrapping_add(x);
    let mj = maj(s[0], s[1], s[2]);
    add_assoc(t, mj, big_sigma0(s[0]));
    add_comm(mj, big_sigma0(s[0]));
    add_comm(t, s[3]);
}

// The words of `s` as SHA256RNDS2 holds them: A, B, E, F in lanes 3 to 0 of the first four, C, D, G, H
// of the last four.
spec fn abef_cdgh(s: [u32; 8]) [u32; 8] {
    return [s[5], s[4], s[1], s[0], s[7], s[6], s[3], s[2]];
}

// The first four words of `x`, and the last four.
spec fn first4(x: [u32; 8]) [u32; 4] {
    return [x[0], x[1], x[2], x[3]];
}

spec fn last4(x: [u32; 8]) [u32; 4] {
    return [x[4], x[5], x[6], x[7]];
}

// Two SHA256RNDS2 are four rounds: the first gives A, B, E, F after two, which are C, D, G, H after four.
lemma intel_rnds2_is_round4(s: [u32; 8], w: [u32; 4], k: [u32; 4])
    ensures intel_sha256_rnds2(last4(abef_cdgh(s)), first4(abef_cdgh(s)), add4(w, k)) == last4(
        abef_cdgh(round4(s, w, k)),
    )
    ensures intel_sha256_rnds2(
        first4(abef_cdgh(s)),
        last4(abef_cdgh(round4(s, w, k))),
        [w[2].wrapping_add(k[2]), w[3].wrapping_add(k[3]), w[2].wrapping_add(k[2]), w[3].wrapping_add(k[3])],
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

// Schedule words `t + 16..t + 20`: SHA256MSG2 of SHA256MSG1's first halves plus words `t + 9..t + 13`.
lemma intel_sched(m: [Secret<u32>; 16], t: u32)
    requires t <= 60
    ensures intel_sha256_msg2(
        add4(
            intel_sha256_msg1(sched4(m, t), sched4(m, t + 4)),
            [sched(m, t + 9), sched(m, t + 10), sched(m, t + 11), sched(m, t + 12)],
        ),
        sched4(m, t + 12),
    ) == sched4(m, t + 16)
{
    sched_order(sched(m, t), small_sigma0(sched(m, t + 1)), sched(m, t + 9), small_sigma1(sched(m, t + 14)));
    sched_order(sched(m, t + 1), small_sigma0(sched(m, t + 2)), sched(m, t + 10), small_sigma1(sched(m, t + 15)));
    sched_order(sched(m, t + 2), small_sigma0(sched(m, t + 3)), sched(m, t + 11), small_sigma1(sched(m, t + 16)));
    sched_order(sched(m, t + 3), small_sigma0(sched(m, t + 4)), sched(m, t + 12), small_sigma1(sched(m, t + 17)));
}

// Rounds `t..t + 4` with x86-64's SHA256RNDS2, the working variables as it holds them (`abef_cdgh`).
@always_inline
@constant_time
@arch(x86_64)
@target_feature([cpu::Feature::Sha])
fn rounds_x64(h: [Secret<u32>; 8], m: [Secret<u32>; 16], t: u32, s: [Secret<u32>; 8], w: [Secret<u32>; 4]) [Secret<u32>; 8]
    requires t <= 60
    requires state_values(s) == abef_cdgh(rounds(state_values(h), m, t))
    requires words4(w) == sched4(m, t)
    ensures |r| state_values(r) == abef_cdgh(rounds(state_values(h), m, t + 4))
{
    let abef: [Secret<u32>; 4] = [s[0], s[1], s[2], s[3]];
    let cdgh: [Secret<u32>; 4] = [s[4], s[5], s[6], s[7]];
    let wk: [Secret<u32>; 4] = [
        w[0] + Secret::new(K[t]),
        w[1] + Secret::new(K[t + 1]),
        w[2] + Secret::new(K[t + 2]),
        w[3] + Secret::new(K[t + 3]),
    ];
    let half = sha256rnds2(cdgh, abef, wk);
    let full = sha256rnds2(abef, half, [wk[2], wk[3], wk[2], wk[3]]);
    assert words4(wk) == add4(sched4(m, t), k4(t)) by {};
    assert words4(abef) == first4(state_values(s)) && words4(cdgh) == last4(state_values(s)) by {};
    assert words4(half) == last4(abef_cdgh(round4(rounds(state_values(h), m, t), sched4(m, t), k4(t)))) by {
        intel_rnds2_is_round4(rounds(state_values(h), m, t), sched4(m, t), k4(t));
    };
    assert words4(full) == first4(abef_cdgh(round4(rounds(state_values(h), m, t), sched4(m, t), k4(t)))) by {
        intel_rnds2_is_round4(rounds(state_values(h), m, t), sched4(m, t), k4(t));
    };
    rounds_four(state_values(h), m, t);
    return [full[0], full[1], full[2], full[3], half[0], half[1], half[2], half[3]];
}

// Schedule words `t + 16..t + 20` with x86-64's SHA256MSG1 and SHA256MSG2.
@always_inline
@constant_time
@arch(x86_64)
@target_feature([cpu::Feature::Sha])
fn sched_x64(
    m: [Secret<u32>; 16],
    t: u32,
    w0: [Secret<u32>; 4],
    w1: [Secret<u32>; 4],
    w2: [Secret<u32>; 4],
    w3: [Secret<u32>; 4],
) [Secret<u32>; 4]
    requires t <= 60
    requires words4(w0) == sched4(m, t) && words4(w1) == sched4(m, t + 4)
    requires words4(w2) == sched4(m, t + 8) && words4(w3) == sched4(m, t + 12)
    ensures |r| words4(r) == sched4(m, t + 16)
{
    intel_sched(m, t);
    let h = sha256msg1(w0, w1);
    return sha256msg2([h[0] + w2[1], h[1] + w2[2], h[2] + w2[3], h[3] + w3[0]], w3);
}

// Block `m` on state `h` with x86-64's SHA-256 instructions.
@constant_time
@arch(x86_64)
@target_feature([cpu::Feature::Sha])
fn compress_x64(h: [Secret<u32>; 8], m: [Secret<u32>; 16]) [Secret<u32>; 8]
    ensures |r| state_values(r) == compress(state_values(h), m)
{
    let mut s: [Secret<u32>; 8] = [h[5], h[4], h[1], h[0], h[7], h[6], h[3], h[2]];
    let mut w0: [Secret<u32>; 4] = [m[0], m[1], m[2], m[3]];
    let mut w1: [Secret<u32>; 4] = [m[4], m[5], m[6], m[7]];
    let mut w2: [Secret<u32>; 4] = [m[8], m[9], m[10], m[11]];
    let mut w3: [Secret<u32>; 4] = [m[12], m[13], m[14], m[15]];
    assert rounds(state_values(h), m, 0) == state_values(h) by {};
    // The 64 rounds in order, four at a time, each window taking its next words in place once read.
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
    s = rounds_x64(h, m, 52, s, w1);
    s = rounds_x64(h, m, 56, s, w2);
    s = rounds_x64(h, m, 60, s, w3);
    return [h[0] + s[3], h[1] + s[2], h[2] + s[7], h[3] + s[6], h[4] + s[1], h[5] + s[0], h[6] + s[5], h[7] + s[4]];
}

// Block `m` on state `h`, with the processor's SHA-256 instructions when `hw` (the machine has them,
// `hw_ok`).
@constant_time
@arch(aarch64)
fn compress_on(h: [Secret<u32>; 8], m: [Secret<u32>; 16], hw: bool) [Secret<u32>; 8]
    ensures |r| state_values(r) == compress(state_values(h), m)
{
    if hw {
        return unsafe compress_a64(h, m);
    }
    return compress_ct(h, m);
}

@constant_time
@arch(x86_64)
fn compress_on(h: [Secret<u32>; 8], m: [Secret<u32>; 16], hw: bool) [Secret<u32>; 8]
    ensures |r| state_values(r) == compress(state_values(h), m)
{
    if hw {
        return unsafe compress_x64(h, m);
    }
    return compress_ct(h, m);
}

@constant_time
@arch(wasm32)
fn compress_on(h: [Secret<u32>; 8], m: [Secret<u32>; 16], _hw: bool) [Secret<u32>; 8]
    ensures |r| state_values(r) == compress(state_values(h), m)
{
    return compress_ct(h, m);
}

// Whether this machine has the SHA-256 instructions `compress_on` uses.
@arch(aarch64)
fn hw_ok() bool {
    return detect::has(cpu::Feature::Sha2);
}

@arch(x86_64)
fn hw_ok() bool {
    return detect::has(cpu::Feature::Sha);
}

@arch(wasm32)
const fn hw_ok() bool {
    return false;
}

/// The SHA-256 digest of `msg` (FIPS 180-4), with the processor's SHA-256 instructions where the
/// machine has them (arm64 FEAT_SHA256, x86-64 SHA-NI).
@constant_time
pub fn sha256(msg: []Secret<u8>) [Secret<u8>; 32]
    ensures |d| byte_values(d) == digest(msg)
{
    return digest_with(msg, hw_ok());
}

/// The SHA-256 digest of `msg` without the processor's SHA-256 instructions: the same digest as `sha256`.
@constant_time
pub fn sha256_portable(msg: []Secret<u8>) [Secret<u8>; 32]
    ensures |d| byte_values(d) == digest(msg)
{
    return digest_with(msg, false);
}

// The digest of `msg`, with the processor's instructions when `hw`.
@constant_time
fn digest_with(msg: []Secret<u8>, hw: bool) [Secret<u8>; 32]
    ensures |d| byte_values(d) == digest(msg)
{
    let nb = (msg.len() + 8) / 64 + 1;
    let mut h: [Secret<u32>; 8] = [
        Secret::new(0x6a09e667u32),
        Secret::new(0xbb67ae85u32),
        Secret::new(0x3c6ef372u32),
        Secret::new(0xa54ff53au32),
        Secret::new(0x510e527fu32),
        Secret::new(0x9b05688cu32),
        Secret::new(0x1f83d9abu32),
        Secret::new(0x5be0cd19u32),
    ];
    let mut b: usize = 0;
    while b < nb
        invariant b <= nb
        invariant state_values(h) == hashes(msg, b as int)
    {
        h = absorb(msg, b, h, hw);
        b += 1;
    }
    assert b as int == (msg.len() as int + 8) / 64 + 1 by {};
    assert state_values(h) == hashes(msg, (msg.len() as int + 8) / 64 + 1) by {};
    return to_bytes(h);
}
