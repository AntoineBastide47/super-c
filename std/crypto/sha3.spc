// SHA-3 and SHAKE (FIPS 202), proved: the specification is the standard's Keccak-f[1600] permutation and
// sponge as spec functions, and `sha3_256`, `sha3_512`, `shake128` and `shake256` compute exactly the bytes
// they define. Each runs in constant time on the message bytes (`@constant_time`): only the lengths pick a
// branch or an index. No operation panics. Import with `import std::crypto::sha3;`.

import std::crypto::secret as *;
import std::spec::arith;
import std::spec::seq as *;

// The round constants (FIPS 202, 3.2.5).
const RC: [u64; 24] = [
    0x0000000000000001,
    0x0000000000008082,
    0x800000000000808a,
    0x8000000080008000,
    0x000000000000808b,
    0x0000000080000001,
    0x8000000080008081,
    0x8000000000008009,
    0x000000000000008a,
    0x0000000000000088,
    0x0000000080008009,
    0x000000008000000a,
    0x000000008000808b,
    0x800000000000008b,
    0x8000000000008089,
    0x8000000000008003,
    0x8000000000008002,
    0x8000000000000080,
    0x000000000000800a,
    0x800000008000000a,
    0x8000000080008081,
    0x8000000000008080,
    0x0000000080000001,
    0x8000000080008008,
];

// Theta (3.2.1).
spec fn theta(a: [u64; 25]) [u64; 25] {
    return [
        a[0] ^ (a[4] ^ a[9] ^ a[14] ^ a[19] ^ a[24] ^ (a[1] ^ a[6] ^ a[11] ^ a[16] ^ a[21]).rotate_left(1)),
        a[1] ^ (a[0] ^ a[5] ^ a[10] ^ a[15] ^ a[20] ^ (a[2] ^ a[7] ^ a[12] ^ a[17] ^ a[22]).rotate_left(1)),
        a[2] ^ (a[1] ^ a[6] ^ a[11] ^ a[16] ^ a[21] ^ (a[3] ^ a[8] ^ a[13] ^ a[18] ^ a[23]).rotate_left(1)),
        a[3] ^ (a[2] ^ a[7] ^ a[12] ^ a[17] ^ a[22] ^ (a[4] ^ a[9] ^ a[14] ^ a[19] ^ a[24]).rotate_left(1)),
        a[4] ^ (a[3] ^ a[8] ^ a[13] ^ a[18] ^ a[23] ^ (a[0] ^ a[5] ^ a[10] ^ a[15] ^ a[20]).rotate_left(1)),
        a[5] ^ (a[4] ^ a[9] ^ a[14] ^ a[19] ^ a[24] ^ (a[1] ^ a[6] ^ a[11] ^ a[16] ^ a[21]).rotate_left(1)),
        a[6] ^ (a[0] ^ a[5] ^ a[10] ^ a[15] ^ a[20] ^ (a[2] ^ a[7] ^ a[12] ^ a[17] ^ a[22]).rotate_left(1)),
        a[7] ^ (a[1] ^ a[6] ^ a[11] ^ a[16] ^ a[21] ^ (a[3] ^ a[8] ^ a[13] ^ a[18] ^ a[23]).rotate_left(1)),
        a[8] ^ (a[2] ^ a[7] ^ a[12] ^ a[17] ^ a[22] ^ (a[4] ^ a[9] ^ a[14] ^ a[19] ^ a[24]).rotate_left(1)),
        a[9] ^ (a[3] ^ a[8] ^ a[13] ^ a[18] ^ a[23] ^ (a[0] ^ a[5] ^ a[10] ^ a[15] ^ a[20]).rotate_left(1)),
        a[10] ^ (a[4] ^ a[9] ^ a[14] ^ a[19] ^ a[24] ^ (a[1] ^ a[6] ^ a[11] ^ a[16] ^ a[21]).rotate_left(1)),
        a[11] ^ (a[0] ^ a[5] ^ a[10] ^ a[15] ^ a[20] ^ (a[2] ^ a[7] ^ a[12] ^ a[17] ^ a[22]).rotate_left(1)),
        a[12] ^ (a[1] ^ a[6] ^ a[11] ^ a[16] ^ a[21] ^ (a[3] ^ a[8] ^ a[13] ^ a[18] ^ a[23]).rotate_left(1)),
        a[13] ^ (a[2] ^ a[7] ^ a[12] ^ a[17] ^ a[22] ^ (a[4] ^ a[9] ^ a[14] ^ a[19] ^ a[24]).rotate_left(1)),
        a[14] ^ (a[3] ^ a[8] ^ a[13] ^ a[18] ^ a[23] ^ (a[0] ^ a[5] ^ a[10] ^ a[15] ^ a[20]).rotate_left(1)),
        a[15] ^ (a[4] ^ a[9] ^ a[14] ^ a[19] ^ a[24] ^ (a[1] ^ a[6] ^ a[11] ^ a[16] ^ a[21]).rotate_left(1)),
        a[16] ^ (a[0] ^ a[5] ^ a[10] ^ a[15] ^ a[20] ^ (a[2] ^ a[7] ^ a[12] ^ a[17] ^ a[22]).rotate_left(1)),
        a[17] ^ (a[1] ^ a[6] ^ a[11] ^ a[16] ^ a[21] ^ (a[3] ^ a[8] ^ a[13] ^ a[18] ^ a[23]).rotate_left(1)),
        a[18] ^ (a[2] ^ a[7] ^ a[12] ^ a[17] ^ a[22] ^ (a[4] ^ a[9] ^ a[14] ^ a[19] ^ a[24]).rotate_left(1)),
        a[19] ^ (a[3] ^ a[8] ^ a[13] ^ a[18] ^ a[23] ^ (a[0] ^ a[5] ^ a[10] ^ a[15] ^ a[20]).rotate_left(1)),
        a[20] ^ (a[4] ^ a[9] ^ a[14] ^ a[19] ^ a[24] ^ (a[1] ^ a[6] ^ a[11] ^ a[16] ^ a[21]).rotate_left(1)),
        a[21] ^ (a[0] ^ a[5] ^ a[10] ^ a[15] ^ a[20] ^ (a[2] ^ a[7] ^ a[12] ^ a[17] ^ a[22]).rotate_left(1)),
        a[22] ^ (a[1] ^ a[6] ^ a[11] ^ a[16] ^ a[21] ^ (a[3] ^ a[8] ^ a[13] ^ a[18] ^ a[23]).rotate_left(1)),
        a[23] ^ (a[2] ^ a[7] ^ a[12] ^ a[17] ^ a[22] ^ (a[4] ^ a[9] ^ a[14] ^ a[19] ^ a[24]).rotate_left(1)),
        a[24] ^ (a[3] ^ a[8] ^ a[13] ^ a[18] ^ a[23] ^ (a[0] ^ a[5] ^ a[10] ^ a[15] ^ a[20]).rotate_left(1)),
    ];
}

// Rho and pi (3.2.2, 3.2.3): lane (x, y) rotated, then moved to (y, 2x + 3y).
spec fn rho_pi(a: [u64; 25]) [u64; 25] {
    return [
        a[0],
        a[6].rotate_left(44),
        a[12].rotate_left(43),
        a[18].rotate_left(21),
        a[24].rotate_left(14),
        a[3].rotate_left(28),
        a[9].rotate_left(20),
        a[10].rotate_left(3),
        a[16].rotate_left(45),
        a[22].rotate_left(61),
        a[1].rotate_left(1),
        a[7].rotate_left(6),
        a[13].rotate_left(25),
        a[19].rotate_left(8),
        a[20].rotate_left(18),
        a[4].rotate_left(27),
        a[5].rotate_left(36),
        a[11].rotate_left(10),
        a[17].rotate_left(15),
        a[23].rotate_left(56),
        a[2].rotate_left(62),
        a[8].rotate_left(55),
        a[14].rotate_left(39),
        a[15].rotate_left(41),
        a[21].rotate_left(2),
    ];
}

// Chi (3.2.4).
spec fn chi(b: [u64; 25]) [u64; 25] {
    return [
        b[0] ^ ~b[1] & b[2],
        b[1] ^ ~b[2] & b[3],
        b[2] ^ ~b[3] & b[4],
        b[3] ^ ~b[4] & b[0],
        b[4] ^ ~b[0] & b[1],
        b[5] ^ ~b[6] & b[7],
        b[6] ^ ~b[7] & b[8],
        b[7] ^ ~b[8] & b[9],
        b[8] ^ ~b[9] & b[5],
        b[9] ^ ~b[5] & b[6],
        b[10] ^ ~b[11] & b[12],
        b[11] ^ ~b[12] & b[13],
        b[12] ^ ~b[13] & b[14],
        b[13] ^ ~b[14] & b[10],
        b[14] ^ ~b[10] & b[11],
        b[15] ^ ~b[16] & b[17],
        b[16] ^ ~b[17] & b[18],
        b[17] ^ ~b[18] & b[19],
        b[18] ^ ~b[19] & b[15],
        b[19] ^ ~b[15] & b[16],
        b[20] ^ ~b[21] & b[22],
        b[21] ^ ~b[22] & b[23],
        b[22] ^ ~b[23] & b[24],
        b[23] ^ ~b[24] & b[20],
        b[24] ^ ~b[20] & b[21],
    ];
}

// Round `i` (3.3).
spec fn round(a: [u64; 25], i: usize) [u64; 25]
    requires i < 24
{
    let b = chi(rho_pi(theta(a)));
    return [
        b[0] ^ RC[i],
        b[1],
        b[2],
        b[3],
        b[4],
        b[5],
        b[6],
        b[7],
        b[8],
        b[9],
        b[10],
        b[11],
        b[12],
        b[13],
        b[14],
        b[15],
        b[16],
        b[17],
        b[18],
        b[19],
        b[20],
        b[21],
        b[22],
        b[23],
        b[24],
    ];
}

// The state after rounds `0..n`.
spec fn rounds(a: [u64; 25], n: int) [u64; 25]
    decreases n
{
    return if n <= 0 || n > 24 {
        a
    } else {
        round(rounds(a, n - 1), (n - 1) as usize)
    };
}

// The values of the lanes of `s`.
pub(package) spec fn values(s: [Secret<u64>; 25]) [u64; 25] {
    return [
        s[0].value(),
        s[1].value(),
        s[2].value(),
        s[3].value(),
        s[4].value(),
        s[5].value(),
        s[6].value(),
        s[7].value(),
        s[8].value(),
        s[9].value(),
        s[10].value(),
        s[11].value(),
        s[12].value(),
        s[13].value(),
        s[14].value(),
        s[15].value(),
        s[16].value(),
        s[17].value(),
        s[18].value(),
        s[19].value(),
        s[20].value(),
        s[21].value(),
        s[22].value(),
        s[23].value(),
        s[24].value(),
    ];
}

// Theta.
@constant_time
fn theta_ct(a: [Secret<u64>; 25]) [Secret<u64>; 25]
    ensures |r| values(r) == theta(values(a))
{
    let c = [
        a[0] ^ a[5] ^ a[10] ^ a[15] ^ a[20],
        a[1] ^ a[6] ^ a[11] ^ a[16] ^ a[21],
        a[2] ^ a[7] ^ a[12] ^ a[17] ^ a[22],
        a[3] ^ a[8] ^ a[13] ^ a[18] ^ a[23],
        a[4] ^ a[9] ^ a[14] ^ a[19] ^ a[24],
    ];
    let e = [
        c[4] ^ c[1].rotate_left(1),
        c[0] ^ c[2].rotate_left(1),
        c[1] ^ c[3].rotate_left(1),
        c[2] ^ c[4].rotate_left(1),
        c[3] ^ c[0].rotate_left(1),
    ];
    return [
        a[0] ^ e[0],
        a[1] ^ e[1],
        a[2] ^ e[2],
        a[3] ^ e[3],
        a[4] ^ e[4],
        a[5] ^ e[0],
        a[6] ^ e[1],
        a[7] ^ e[2],
        a[8] ^ e[3],
        a[9] ^ e[4],
        a[10] ^ e[0],
        a[11] ^ e[1],
        a[12] ^ e[2],
        a[13] ^ e[3],
        a[14] ^ e[4],
        a[15] ^ e[0],
        a[16] ^ e[1],
        a[17] ^ e[2],
        a[18] ^ e[3],
        a[19] ^ e[4],
        a[20] ^ e[0],
        a[21] ^ e[1],
        a[22] ^ e[2],
        a[23] ^ e[3],
        a[24] ^ e[4],
    ];
}

// Rho and pi.
@constant_time
fn rho_pi_ct(a: [Secret<u64>; 25]) [Secret<u64>; 25]
    ensures |r| values(r) == rho_pi(values(a))
{
    return [
        a[0],
        a[6].rotate_left(44),
        a[12].rotate_left(43),
        a[18].rotate_left(21),
        a[24].rotate_left(14),
        a[3].rotate_left(28),
        a[9].rotate_left(20),
        a[10].rotate_left(3),
        a[16].rotate_left(45),
        a[22].rotate_left(61),
        a[1].rotate_left(1),
        a[7].rotate_left(6),
        a[13].rotate_left(25),
        a[19].rotate_left(8),
        a[20].rotate_left(18),
        a[4].rotate_left(27),
        a[5].rotate_left(36),
        a[11].rotate_left(10),
        a[17].rotate_left(15),
        a[23].rotate_left(56),
        a[2].rotate_left(62),
        a[8].rotate_left(55),
        a[14].rotate_left(39),
        a[15].rotate_left(41),
        a[21].rotate_left(2),
    ];
}

// Chi.
@constant_time
const fn chi_ct(b: [Secret<u64>; 25]) [Secret<u64>; 25]
    ensures |r| values(r) == chi(values(b))
{
    return [
        b[0] ^ ~b[1] & b[2],
        b[1] ^ ~b[2] & b[3],
        b[2] ^ ~b[3] & b[4],
        b[3] ^ ~b[4] & b[0],
        b[4] ^ ~b[0] & b[1],
        b[5] ^ ~b[6] & b[7],
        b[6] ^ ~b[7] & b[8],
        b[7] ^ ~b[8] & b[9],
        b[8] ^ ~b[9] & b[5],
        b[9] ^ ~b[5] & b[6],
        b[10] ^ ~b[11] & b[12],
        b[11] ^ ~b[12] & b[13],
        b[12] ^ ~b[13] & b[14],
        b[13] ^ ~b[14] & b[10],
        b[14] ^ ~b[10] & b[11],
        b[15] ^ ~b[16] & b[17],
        b[16] ^ ~b[17] & b[18],
        b[17] ^ ~b[18] & b[19],
        b[18] ^ ~b[19] & b[15],
        b[19] ^ ~b[15] & b[16],
        b[20] ^ ~b[21] & b[22],
        b[21] ^ ~b[22] & b[23],
        b[22] ^ ~b[23] & b[24],
        b[23] ^ ~b[24] & b[20],
        b[24] ^ ~b[20] & b[21],
    ];
}

// Round `i`.
@constant_time
fn round_ct(a: [Secret<u64>; 25], i: usize) [Secret<u64>; 25]
    requires i < 24
    ensures |r| values(r) == round(values(a), i)
{
    let b = chi_ct(rho_pi_ct(theta_ct(a)));
    return [
        b[0] ^ Secret::new(RC[i]),
        b[1],
        b[2],
        b[3],
        b[4],
        b[5],
        b[6],
        b[7],
        b[8],
        b[9],
        b[10],
        b[11],
        b[12],
        b[13],
        b[14],
        b[15],
        b[16],
        b[17],
        b[18],
        b[19],
        b[20],
        b[21],
        b[22],
        b[23],
        b[24],
    ];
}

lemma rounds_step(a: [u64; 25], i: int)
    requires 0 <= i && i < 24
    ensures rounds(a, i + 1) == round(rounds(a, i), i as usize)
{}

lemma round_next(s: [u64; 25], a: [u64; 25], i: int)
    requires 0 <= i && i < 24
    requires a == rounds(s, i)
    ensures round(a, i as usize) == rounds(s, i + 1)
{
    rounds_step(s, i);
}

// Round `i` on the state after rounds `0..i` of `s`.
@constant_time
fn next_round(s: [Secret<u64>; 25], i: usize, x: [Secret<u64>; 25]) [Secret<u64>; 25]
    requires i < 24
    requires values(x) == rounds(values(s), i as int)
    ensures |r| values(r) == rounds(values(s), i as int + 1)
{
    round_next(values(s), values(x), i as int);
    return round_ct(x, i);
}

// Keccak-f[1600] (3.3): 24 rounds.
@constant_time
pub(package) fn keccak_ct(s: [Secret<u64>; 25]) [Secret<u64>; 25]
    ensures |r| values(r) == rounds(values(s), 24)
{
    let mut x = s;
    let mut i: usize = 0;
    while i < 24
        invariant i <= 24
        invariant values(x) == rounds(values(s), i as int)
    {
        x = next_round(s, i, x);
        i += 1;
    }
    return x;
}

// Byte `p` of `m` padded for a rate of `rate` bytes with domain byte `ds` (5.1, B.2): the message, `ds`,
// zeros, and 0x80 in the last byte of the last block; 0 outside it.
pub(package) spec fn padded(m: Seq<Secret<u8>>, rate: int, ds: u8, p: int) u8 {
    let n = m.len() as int;
    let end = if rate > 0 {
        (n / rate + 1) * rate
    } else {
        0
    };
    return if p < 0 || p >= end {
        0
    } else if p < n {
        m[p].value()
    } else if p == n && p == end - 1 {
        ds | 0x80
    } else if p == n {
        ds
    } else if p == end - 1 {
        0x80
    } else {
        0
    };
}

// The little-endian lane at byte `p` of the padded message.
spec fn lane(m: Seq<Secret<u8>>, rate: int, ds: u8, p: int) u64 {
    return padded(m, rate, ds, p) as u64 | padded(m, rate, ds, p + 1) as u64 << 8 | padded(m, rate, ds, p + 2) as u64 << 16 | padded(
        m,
        rate,
        ds,
        p + 3,
    ) as u64 << 24 | padded(m, rate, ds, p + 4) as u64 << 32 | padded(m, rate, ds, p + 5) as u64 << 40 | padded(
        m,
        rate,
        ds,
        p + 6,
    ) as u64 << 48 | padded(m, rate, ds, p + 7) as u64 << 56;
}

// Lane `k` of a state, `x`, with block `b` of the padded message added where `k` is below `rate / 8`.
spec fn mix_lane(x: u64, m: Seq<Secret<u8>>, rate: int, ds: u8, b: int, k: int) u64 {
    return if k < rate / 8 {
        x ^ lane(m, rate, ds, b * rate + 8 * k)
    } else {
        x
    };
}

// State `a` with block `b` of the padded message added to its first `rate / 8` lanes.
spec fn mix(a: [u64; 25], m: Seq<Secret<u8>>, rate: int, ds: u8, b: int) [u64; 25] {
    return [
        mix_lane(a[0], m, rate, ds, b, 0),
        mix_lane(a[1], m, rate, ds, b, 1),
        mix_lane(a[2], m, rate, ds, b, 2),
        mix_lane(a[3], m, rate, ds, b, 3),
        mix_lane(a[4], m, rate, ds, b, 4),
        mix_lane(a[5], m, rate, ds, b, 5),
        mix_lane(a[6], m, rate, ds, b, 6),
        mix_lane(a[7], m, rate, ds, b, 7),
        mix_lane(a[8], m, rate, ds, b, 8),
        mix_lane(a[9], m, rate, ds, b, 9),
        mix_lane(a[10], m, rate, ds, b, 10),
        mix_lane(a[11], m, rate, ds, b, 11),
        mix_lane(a[12], m, rate, ds, b, 12),
        mix_lane(a[13], m, rate, ds, b, 13),
        mix_lane(a[14], m, rate, ds, b, 14),
        mix_lane(a[15], m, rate, ds, b, 15),
        mix_lane(a[16], m, rate, ds, b, 16),
        mix_lane(a[17], m, rate, ds, b, 17),
        mix_lane(a[18], m, rate, ds, b, 18),
        mix_lane(a[19], m, rate, ds, b, 19),
        mix_lane(a[20], m, rate, ds, b, 20),
        mix_lane(a[21], m, rate, ds, b, 21),
        mix_lane(a[22], m, rate, ds, b, 22),
        mix_lane(a[23], m, rate, ds, b, 23),
        mix_lane(a[24], m, rate, ds, b, 24),
    ];
}

// The state after blocks `0..b` of the padded message (4, the absorbing phase).
spec fn absorbed(m: Seq<Secret<u8>>, rate: int, ds: u8, b: int) [u64; 25]
    decreases b
{
    return if b <= 0 {
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    } else {
        rounds(mix(absorbed(m, rate, ds, b - 1), m, rate, ds, b - 1), 24)
    };
}

// The number of blocks of a padded message of `n` bytes.
spec fn blocks(n: int, rate: int) int {
    return if rate > 0 {
        n / rate + 1
    } else {
        0
    };
}

// The state that block `q` of the output reads (4, the squeezing phase).
spec fn squeezed(m: Seq<Secret<u8>>, rate: int, ds: u8, q: int) [u64; 25]
    decreases q
{
    return if q <= 0 {
        absorbed(m, rate, ds, blocks(m.len(), rate))
    } else {
        rounds(squeezed(m, rate, ds, q - 1), 24)
    };
}

// Byte `o` of state `s`, its lanes little-endian.
spec fn state_byte(s: [u64; 25], o: int) u8 {
    return if 0 <= o && o < 200 {
        (s[(o / 8) as usize] >> (8 * (o % 8)) as u64) as u8
    } else {
        0
    };
}

/// Byte `j` of the output of the Keccak sponge on `m`, with a rate of `rate` bytes and domain byte `ds`
/// (FIPS 202, 4 and 6): SHA3-256 is rate 136 and domain 0x06, SHA3-512 rate 72 and 0x06, SHAKE128 rate
/// 168 and 0x1F, SHAKE256 rate 136 and 0x1F.
pub spec fn output(m: Seq<Secret<u8>>, rate: int, ds: u8, j: int) u8 {
    return if rate > 0 {
        state_byte(squeezed(m, rate, ds, j / rate), j % rate)
    } else {
        0
    };
}

// Byte `p` of the padded message.
@constant_time
const fn pad_byte(m: []Secret<u8>, rate: usize, ds: u8, p: usize) Secret<u8>
    requires rate == 72 || rate == 136 || rate == 168
    ensures |r| r.value() == padded(m.view(), rate as int, ds, p as int)
{
    let n = m.len();
    let end = (n / rate + 1) * rate;
    if p >= end {
        return Secret::new(0u8);
    }
    if p < n {
        return m[p];
    }
    if p == n && p == end - 1 {
        return Secret::new(ds | 0x80);
    }
    if p == n {
        return Secret::new(ds);
    }
    if p == end - 1 {
        return Secret::new(0x80u8);
    }
    return Secret::new(0u8);
}

// The little-endian lane at byte `p` of the padded message.
@constant_time
fn lane_ct(m: []Secret<u8>, rate: usize, ds: u8, p: usize) Secret<u64>
    requires rate == 72 || rate == 136 || rate == 168
    requires p as int + 8 <= m.len() as int + 200
    ensures |r| r.value() == lane(m.view(), rate as int, ds, p as int)
{
    let b0 = pad_byte(m, rate, ds, p).cast::<u64>();
    let b1 = pad_byte(m, rate, ds, p + 1).cast::<u64>();
    let b2 = pad_byte(m, rate, ds, p + 2).cast::<u64>();
    let b3 = pad_byte(m, rate, ds, p + 3).cast::<u64>();
    let b4 = pad_byte(m, rate, ds, p + 4).cast::<u64>();
    let b5 = pad_byte(m, rate, ds, p + 5).cast::<u64>();
    let b6 = pad_byte(m, rate, ds, p + 6).cast::<u64>();
    let b7 = pad_byte(m, rate, ds, p + 7).cast::<u64>();
    return b0 | b1 << 8 | b2 << 16 | b3 << 24 | b4 << 32 | b5 << 40 | b6 << 48 | b7 << 56;
}

// Lane `k` of a state, `x`, with block `b` (at byte `p`) added (`mix_lane`).
@constant_time
fn mix_lane_ct(x: Secret<u64>, m: []Secret<u8>, rate: usize, ds: u8, b: usize, p: usize, k: usize) Secret<u64>
    requires rate == 72 || rate == 136 || rate == 168
    requires k < 25 && p as int == b as int * rate as int && p <= m.len()
    ensures |r| r.value() == mix_lane(x.value(), m.view(), rate as int, ds, b as int, k as int)
{
    if k < rate / 8 {
        return x ^ lane_ct(m, rate, ds, p + 8 * k);
    }
    return x;
}

// Block `b` (at byte `p`) added to state `a` (`mix`).
@constant_time
fn mix_ct(a: [Secret<u64>; 25], m: []Secret<u8>, rate: usize, ds: u8, b: usize, p: usize) [Secret<u64>; 25]
    requires rate == 72 || rate == 136 || rate == 168
    requires p as int == b as int * rate as int && p <= m.len()
    ensures |r| values(r) == mix(values(a), m.view(), rate as int, ds, b as int)
{
    return [
        mix_lane_ct(a[0], m, rate, ds, b, p, 0),
        mix_lane_ct(a[1], m, rate, ds, b, p, 1),
        mix_lane_ct(a[2], m, rate, ds, b, p, 2),
        mix_lane_ct(a[3], m, rate, ds, b, p, 3),
        mix_lane_ct(a[4], m, rate, ds, b, p, 4),
        mix_lane_ct(a[5], m, rate, ds, b, p, 5),
        mix_lane_ct(a[6], m, rate, ds, b, p, 6),
        mix_lane_ct(a[7], m, rate, ds, b, p, 7),
        mix_lane_ct(a[8], m, rate, ds, b, p, 8),
        mix_lane_ct(a[9], m, rate, ds, b, p, 9),
        mix_lane_ct(a[10], m, rate, ds, b, p, 10),
        mix_lane_ct(a[11], m, rate, ds, b, p, 11),
        mix_lane_ct(a[12], m, rate, ds, b, p, 12),
        mix_lane_ct(a[13], m, rate, ds, b, p, 13),
        mix_lane_ct(a[14], m, rate, ds, b, p, 14),
        mix_lane_ct(a[15], m, rate, ds, b, p, 15),
        mix_lane_ct(a[16], m, rate, ds, b, p, 16),
        mix_lane_ct(a[17], m, rate, ds, b, p, 17),
        mix_lane_ct(a[18], m, rate, ds, b, p, 18),
        mix_lane_ct(a[19], m, rate, ds, b, p, 19),
        mix_lane_ct(a[20], m, rate, ds, b, p, 20),
        mix_lane_ct(a[21], m, rate, ds, b, p, 21),
        mix_lane_ct(a[22], m, rate, ds, b, p, 22),
        mix_lane_ct(a[23], m, rate, ds, b, p, 23),
        mix_lane_ct(a[24], m, rate, ds, b, p, 24),
    ];
}

// Lane `k` of the values of `s`.
lemma values_at(s: [Secret<u64>; 25], k: usize)
    requires k < 25
    ensures values(s)[k] == s[k].value()
{}

lemma absorbed_step(m: Seq<Secret<u8>>, rate: int, ds: u8, b: int)
    requires b >= 0
    ensures absorbed(m, rate, ds, b + 1) == rounds(mix(absorbed(m, rate, ds, b), m, rate, ds, b), 24)
{}

// A state equal to `absorbed(b)`, mixed with block `b` and permuted, is `absorbed(b + 1)`.
lemma absorbed_next(m: Seq<Secret<u8>>, rate: int, ds: u8, b: int, x: [u64; 25], y: [u64; 25])
    requires b >= 0 && x == absorbed(m, rate, ds, b) && y == mix(x, m, rate, ds, b)
    ensures rounds(y, 24) == absorbed(m, rate, ds, b + 1)
{
    absorbed_step(m, rate, ds, b);
}

// A state equal to `squeezed(q)`, permuted, is `squeezed(q + 1)`.
lemma squeezed_next(m: Seq<Secret<u8>>, rate: int, ds: u8, q: int, x: [u64; 25])
    requires q >= 0 && x == squeezed(m, rate, ds, q)
    ensures rounds(x, 24) == squeezed(m, rate, ds, q + 1)
{
    squeezed_step(m, rate, ds, q);
}

// Equal states have equal bytes.
lemma state_byte_eq(x: [u64; 25], y: [u64; 25], o: int)
    requires x == y
    ensures state_byte(x, o) == state_byte(y, o)
{}

// Output byte `j` is byte `o` of block `q` where `j` is `q * rate + o`.
lemma output_at(m: Seq<Secret<u8>>, rate: int, ds: u8, j: int, q: int, o: int)
    requires rate > 0 && q >= 0 && 0 <= o && o < rate && j == q * rate + o
    ensures output(m, rate, ds, j) == state_byte(squeezed(m, rate, ds, q), o)
{
    arith::mul_nonneg(q, rate);
    arith::mod_unique(j, q, o, rate);
}

// The state after all blocks is the first one the output reads.
lemma absorbed_all(m: Seq<Secret<u8>>, rate: int, ds: u8, nb: int, x: [u64; 25])
    requires nb == blocks(m.len(), rate) && x == absorbed(m, rate, ds, nb)
    ensures x == squeezed(m, rate, ds, 0)
{}

lemma squeezed_step(m: Seq<Secret<u8>>, rate: int, ds: u8, q: int)
    requires q >= 0
    ensures squeezed(m, rate, ds, q + 1) == rounds(squeezed(m, rate, ds, q), 24)
{}

// The state after all blocks of the padded message.
@constant_time
fn absorb(m: []Secret<u8>, rate: usize, ds: u8) [Secret<u64>; 25]
    requires rate == 72 || rate == 136 || rate == 168
    ensures |s| values(s) == squeezed(m.view(), rate as int, ds, 0)
{
    let nb = m.len() / rate + 1;
    assert nb as int == blocks(m.view().len(), rate as int) by {};
    let z = Secret::new(0u64);
    let mut s = [z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z, z];
    let mut p: usize = 0;
    let mut b: usize = 0;
    while b < nb
        invariant b <= nb && p as int == b as int * rate as int
        invariant values(s) == absorbed(m.view(), rate as int, ds, b as int)
    {
        arith::div_mod(m.len() as int, rate as int);
        arith::mul_le(b as int, m.len() as int / rate as int, rate as int);
        let x = mix_ct(s, m, rate, ds, b, p);
        absorbed_next(m.view(), rate as int, ds, b as int, values(s), values(x));
        s = keccak_ct(x);
        p += rate;
        b += 1;
    }
    absorbed_all(m.view(), rate as int, ds, b as int, values(s));
    return s;
}

// Byte `o` of state `s` (`state_byte`).
@constant_time
fn byte_ct(s: [Secret<u64>; 25], o: usize) Secret<u8>
    requires o < 200
    ensures |r| r.value() == state_byte(values(s), o as int)
{
    values_at(s, o / 8);
    return (s[o / 8] >> 8 * (o % 8)).cast::<u8>();
}

// The sponge's output bytes `0..out.len()` into `out`.
@constant_time
fn squeeze(m: []Secret<u8>, rate: usize, ds: u8, out: []mut Secret<u8>)
    requires rate == 72 || rate == 136 || rate == 168
    ensures out.len() == old(out.len())
    ensures forall j in 0..out.len() { out.view()[j as int].value() == output(m.view(), rate as int, ds, j as int) }
{
    let mut s = absorb(m, rate, ds);
    let mut q: usize = 0;
    let mut o: usize = 0;
    for j in 0..out.len()
        invariant out.len() == old(out.len())
        invariant o < rate && j as int == q as int * rate as int + o as int
        invariant values(s) == squeezed(m.view(), rate as int, ds, q as int)
        invariant forall k in 0..j { out.view()[k as int].value() == output(m.view(), rate as int, ds, k as int) }
    {
        output_at(m.view(), rate as int, ds, j as int, q as int, o as int);
        state_byte_eq(values(s), squeezed(m.view(), rate as int, ds, q as int), o as int);
        out[j] = byte_ct(s, o);
        o += 1;
        if o == rate {
            arith::mul_le(1, rate as int, q as int + 1);
            squeezed_next(m.view(), rate as int, ds, q as int, values(s));
            s = keccak_ct(s);
            o = 0;
            q += 1;
        }
    }
}

// Output byte `c` of the first block: byte `c` of the state after all blocks, `s`.
@constant_time
fn digest_byte(s: [Secret<u64>; 25], m: []Secret<u8>, rate: usize, ds: u8, c: usize) Secret<u8>
    requires (rate == 72 || rate == 136 || rate == 168) && c < rate
    requires values(s) == squeezed(m.view(), rate as int, ds, 0)
    ensures |r| r.value() == output(m.view(), rate as int, ds, c as int)
{
    output_at(m.view(), rate as int, ds, c as int, 0, c as int);
    state_byte_eq(values(s), squeezed(m.view(), rate as int, ds, 0), c as int);
    return byte_ct(s, c);
}

/// The SHAKE128 output of `m` (FIPS 202, 6.2), as many bytes as `out` holds, into `out`.
@constant_time
pub fn shake128(m: []Secret<u8>, out: []mut Secret<u8>)
    ensures out.len() == old(out.len())
    ensures forall j in 0..out.len() { out.view()[j as int].value() == output(m.view(), 168, 0x1f, j as int) }
{
    squeeze(m, 168, 0x1f, out);
}

/// The SHAKE256 output of `m` (FIPS 202, 6.2), as many bytes as `out` holds, into `out`.
@constant_time
pub fn shake256(m: []Secret<u8>, out: []mut Secret<u8>)
    ensures out.len() == old(out.len())
    ensures forall j in 0..out.len() { out.view()[j as int].value() == output(m.view(), 136, 0x1f, j as int) }
{
    squeeze(m, 136, 0x1f, out);
}

/// The first 32 bytes of SHAKE256(m) (FIPS 202, 6.2): output bytes of rate 136, domain 0x1f.
pub spec fn shake256_32_out(m: Seq<Secret<u8>>) [u8; 32] {
    return [
        output(m, 136, 0x1f, 0),
        output(m, 136, 0x1f, 1),
        output(m, 136, 0x1f, 2),
        output(m, 136, 0x1f, 3),
        output(m, 136, 0x1f, 4),
        output(m, 136, 0x1f, 5),
        output(m, 136, 0x1f, 6),
        output(m, 136, 0x1f, 7),
        output(m, 136, 0x1f, 8),
        output(m, 136, 0x1f, 9),
        output(m, 136, 0x1f, 10),
        output(m, 136, 0x1f, 11),
        output(m, 136, 0x1f, 12),
        output(m, 136, 0x1f, 13),
        output(m, 136, 0x1f, 14),
        output(m, 136, 0x1f, 15),
        output(m, 136, 0x1f, 16),
        output(m, 136, 0x1f, 17),
        output(m, 136, 0x1f, 18),
        output(m, 136, 0x1f, 19),
        output(m, 136, 0x1f, 20),
        output(m, 136, 0x1f, 21),
        output(m, 136, 0x1f, 22),
        output(m, 136, 0x1f, 23),
        output(m, 136, 0x1f, 24),
        output(m, 136, 0x1f, 25),
        output(m, 136, 0x1f, 26),
        output(m, 136, 0x1f, 27),
        output(m, 136, 0x1f, 28),
        output(m, 136, 0x1f, 29),
        output(m, 136, 0x1f, 30),
        output(m, 136, 0x1f, 31),
    ];
}

/// The SHA3-256 digest of `m` (FIPS 202, 6.1): the first 32 output bytes of rate 136, domain 0x06.
pub spec fn sha3_256_digest(m: Seq<Secret<u8>>) [u8; 32] {
    return [
        output(m, 136, 0x06, 0),
        output(m, 136, 0x06, 1),
        output(m, 136, 0x06, 2),
        output(m, 136, 0x06, 3),
        output(m, 136, 0x06, 4),
        output(m, 136, 0x06, 5),
        output(m, 136, 0x06, 6),
        output(m, 136, 0x06, 7),
        output(m, 136, 0x06, 8),
        output(m, 136, 0x06, 9),
        output(m, 136, 0x06, 10),
        output(m, 136, 0x06, 11),
        output(m, 136, 0x06, 12),
        output(m, 136, 0x06, 13),
        output(m, 136, 0x06, 14),
        output(m, 136, 0x06, 15),
        output(m, 136, 0x06, 16),
        output(m, 136, 0x06, 17),
        output(m, 136, 0x06, 18),
        output(m, 136, 0x06, 19),
        output(m, 136, 0x06, 20),
        output(m, 136, 0x06, 21),
        output(m, 136, 0x06, 22),
        output(m, 136, 0x06, 23),
        output(m, 136, 0x06, 24),
        output(m, 136, 0x06, 25),
        output(m, 136, 0x06, 26),
        output(m, 136, 0x06, 27),
        output(m, 136, 0x06, 28),
        output(m, 136, 0x06, 29),
        output(m, 136, 0x06, 30),
        output(m, 136, 0x06, 31),
    ];
}

/// The SHA3-512 digest of `m` (FIPS 202, 6.1): the first 64 output bytes of rate 72, domain 0x06.
pub spec fn sha3_512_digest(m: Seq<Secret<u8>>) [u8; 64] {
    return [
        output(m, 72, 0x06, 0),
        output(m, 72, 0x06, 1),
        output(m, 72, 0x06, 2),
        output(m, 72, 0x06, 3),
        output(m, 72, 0x06, 4),
        output(m, 72, 0x06, 5),
        output(m, 72, 0x06, 6),
        output(m, 72, 0x06, 7),
        output(m, 72, 0x06, 8),
        output(m, 72, 0x06, 9),
        output(m, 72, 0x06, 10),
        output(m, 72, 0x06, 11),
        output(m, 72, 0x06, 12),
        output(m, 72, 0x06, 13),
        output(m, 72, 0x06, 14),
        output(m, 72, 0x06, 15),
        output(m, 72, 0x06, 16),
        output(m, 72, 0x06, 17),
        output(m, 72, 0x06, 18),
        output(m, 72, 0x06, 19),
        output(m, 72, 0x06, 20),
        output(m, 72, 0x06, 21),
        output(m, 72, 0x06, 22),
        output(m, 72, 0x06, 23),
        output(m, 72, 0x06, 24),
        output(m, 72, 0x06, 25),
        output(m, 72, 0x06, 26),
        output(m, 72, 0x06, 27),
        output(m, 72, 0x06, 28),
        output(m, 72, 0x06, 29),
        output(m, 72, 0x06, 30),
        output(m, 72, 0x06, 31),
        output(m, 72, 0x06, 32),
        output(m, 72, 0x06, 33),
        output(m, 72, 0x06, 34),
        output(m, 72, 0x06, 35),
        output(m, 72, 0x06, 36),
        output(m, 72, 0x06, 37),
        output(m, 72, 0x06, 38),
        output(m, 72, 0x06, 39),
        output(m, 72, 0x06, 40),
        output(m, 72, 0x06, 41),
        output(m, 72, 0x06, 42),
        output(m, 72, 0x06, 43),
        output(m, 72, 0x06, 44),
        output(m, 72, 0x06, 45),
        output(m, 72, 0x06, 46),
        output(m, 72, 0x06, 47),
        output(m, 72, 0x06, 48),
        output(m, 72, 0x06, 49),
        output(m, 72, 0x06, 50),
        output(m, 72, 0x06, 51),
        output(m, 72, 0x06, 52),
        output(m, 72, 0x06, 53),
        output(m, 72, 0x06, 54),
        output(m, 72, 0x06, 55),
        output(m, 72, 0x06, 56),
        output(m, 72, 0x06, 57),
        output(m, 72, 0x06, 58),
        output(m, 72, 0x06, 59),
        output(m, 72, 0x06, 60),
        output(m, 72, 0x06, 61),
        output(m, 72, 0x06, 62),
        output(m, 72, 0x06, 63),
    ];
}

/// The values of the bytes of `d`.
pub spec fn values32(d: [Secret<u8>; 32]) [u8; 32] {
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

/// The values of the bytes of `d`.
pub spec fn values64(d: [Secret<u8>; 64]) [u8; 64] {
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

/// The SHA3-256 digest of `m` (FIPS 202, 6.1).
@constant_time
pub fn sha3_256(m: []Secret<u8>) [Secret<u8>; 32]
    ensures |d| values32(d) == sha3_256_digest(m.view())
{
    let s = absorb(m, 136, 0x06);
    return [
        digest_byte(s, m, 136, 0x06, 0),
        digest_byte(s, m, 136, 0x06, 1),
        digest_byte(s, m, 136, 0x06, 2),
        digest_byte(s, m, 136, 0x06, 3),
        digest_byte(s, m, 136, 0x06, 4),
        digest_byte(s, m, 136, 0x06, 5),
        digest_byte(s, m, 136, 0x06, 6),
        digest_byte(s, m, 136, 0x06, 7),
        digest_byte(s, m, 136, 0x06, 8),
        digest_byte(s, m, 136, 0x06, 9),
        digest_byte(s, m, 136, 0x06, 10),
        digest_byte(s, m, 136, 0x06, 11),
        digest_byte(s, m, 136, 0x06, 12),
        digest_byte(s, m, 136, 0x06, 13),
        digest_byte(s, m, 136, 0x06, 14),
        digest_byte(s, m, 136, 0x06, 15),
        digest_byte(s, m, 136, 0x06, 16),
        digest_byte(s, m, 136, 0x06, 17),
        digest_byte(s, m, 136, 0x06, 18),
        digest_byte(s, m, 136, 0x06, 19),
        digest_byte(s, m, 136, 0x06, 20),
        digest_byte(s, m, 136, 0x06, 21),
        digest_byte(s, m, 136, 0x06, 22),
        digest_byte(s, m, 136, 0x06, 23),
        digest_byte(s, m, 136, 0x06, 24),
        digest_byte(s, m, 136, 0x06, 25),
        digest_byte(s, m, 136, 0x06, 26),
        digest_byte(s, m, 136, 0x06, 27),
        digest_byte(s, m, 136, 0x06, 28),
        digest_byte(s, m, 136, 0x06, 29),
        digest_byte(s, m, 136, 0x06, 30),
        digest_byte(s, m, 136, 0x06, 31),
    ];
}

/// The first 32 bytes of SHAKE256(m) (FIPS 202, 6.2).
@constant_time
pub fn shake256_32(m: []Secret<u8>) [Secret<u8>; 32]
    ensures |d| values32(d) == shake256_32_out(m.view())
{
    let s = absorb(m, 136, 0x1f);
    return [
        digest_byte(s, m, 136, 0x1f, 0),
        digest_byte(s, m, 136, 0x1f, 1),
        digest_byte(s, m, 136, 0x1f, 2),
        digest_byte(s, m, 136, 0x1f, 3),
        digest_byte(s, m, 136, 0x1f, 4),
        digest_byte(s, m, 136, 0x1f, 5),
        digest_byte(s, m, 136, 0x1f, 6),
        digest_byte(s, m, 136, 0x1f, 7),
        digest_byte(s, m, 136, 0x1f, 8),
        digest_byte(s, m, 136, 0x1f, 9),
        digest_byte(s, m, 136, 0x1f, 10),
        digest_byte(s, m, 136, 0x1f, 11),
        digest_byte(s, m, 136, 0x1f, 12),
        digest_byte(s, m, 136, 0x1f, 13),
        digest_byte(s, m, 136, 0x1f, 14),
        digest_byte(s, m, 136, 0x1f, 15),
        digest_byte(s, m, 136, 0x1f, 16),
        digest_byte(s, m, 136, 0x1f, 17),
        digest_byte(s, m, 136, 0x1f, 18),
        digest_byte(s, m, 136, 0x1f, 19),
        digest_byte(s, m, 136, 0x1f, 20),
        digest_byte(s, m, 136, 0x1f, 21),
        digest_byte(s, m, 136, 0x1f, 22),
        digest_byte(s, m, 136, 0x1f, 23),
        digest_byte(s, m, 136, 0x1f, 24),
        digest_byte(s, m, 136, 0x1f, 25),
        digest_byte(s, m, 136, 0x1f, 26),
        digest_byte(s, m, 136, 0x1f, 27),
        digest_byte(s, m, 136, 0x1f, 28),
        digest_byte(s, m, 136, 0x1f, 29),
        digest_byte(s, m, 136, 0x1f, 30),
        digest_byte(s, m, 136, 0x1f, 31),
    ];
}

/// The SHA3-512 digest of `m` (FIPS 202, 6.1).
@constant_time
pub fn sha3_512(m: []Secret<u8>) [Secret<u8>; 64]
    ensures |d| values64(d) == sha3_512_digest(m.view())
{
    let s = absorb(m, 72, 0x06);
    return [
        digest_byte(s, m, 72, 0x06, 0),
        digest_byte(s, m, 72, 0x06, 1),
        digest_byte(s, m, 72, 0x06, 2),
        digest_byte(s, m, 72, 0x06, 3),
        digest_byte(s, m, 72, 0x06, 4),
        digest_byte(s, m, 72, 0x06, 5),
        digest_byte(s, m, 72, 0x06, 6),
        digest_byte(s, m, 72, 0x06, 7),
        digest_byte(s, m, 72, 0x06, 8),
        digest_byte(s, m, 72, 0x06, 9),
        digest_byte(s, m, 72, 0x06, 10),
        digest_byte(s, m, 72, 0x06, 11),
        digest_byte(s, m, 72, 0x06, 12),
        digest_byte(s, m, 72, 0x06, 13),
        digest_byte(s, m, 72, 0x06, 14),
        digest_byte(s, m, 72, 0x06, 15),
        digest_byte(s, m, 72, 0x06, 16),
        digest_byte(s, m, 72, 0x06, 17),
        digest_byte(s, m, 72, 0x06, 18),
        digest_byte(s, m, 72, 0x06, 19),
        digest_byte(s, m, 72, 0x06, 20),
        digest_byte(s, m, 72, 0x06, 21),
        digest_byte(s, m, 72, 0x06, 22),
        digest_byte(s, m, 72, 0x06, 23),
        digest_byte(s, m, 72, 0x06, 24),
        digest_byte(s, m, 72, 0x06, 25),
        digest_byte(s, m, 72, 0x06, 26),
        digest_byte(s, m, 72, 0x06, 27),
        digest_byte(s, m, 72, 0x06, 28),
        digest_byte(s, m, 72, 0x06, 29),
        digest_byte(s, m, 72, 0x06, 30),
        digest_byte(s, m, 72, 0x06, 31),
        digest_byte(s, m, 72, 0x06, 32),
        digest_byte(s, m, 72, 0x06, 33),
        digest_byte(s, m, 72, 0x06, 34),
        digest_byte(s, m, 72, 0x06, 35),
        digest_byte(s, m, 72, 0x06, 36),
        digest_byte(s, m, 72, 0x06, 37),
        digest_byte(s, m, 72, 0x06, 38),
        digest_byte(s, m, 72, 0x06, 39),
        digest_byte(s, m, 72, 0x06, 40),
        digest_byte(s, m, 72, 0x06, 41),
        digest_byte(s, m, 72, 0x06, 42),
        digest_byte(s, m, 72, 0x06, 43),
        digest_byte(s, m, 72, 0x06, 44),
        digest_byte(s, m, 72, 0x06, 45),
        digest_byte(s, m, 72, 0x06, 46),
        digest_byte(s, m, 72, 0x06, 47),
        digest_byte(s, m, 72, 0x06, 48),
        digest_byte(s, m, 72, 0x06, 49),
        digest_byte(s, m, 72, 0x06, 50),
        digest_byte(s, m, 72, 0x06, 51),
        digest_byte(s, m, 72, 0x06, 52),
        digest_byte(s, m, 72, 0x06, 53),
        digest_byte(s, m, 72, 0x06, 54),
        digest_byte(s, m, 72, 0x06, 55),
        digest_byte(s, m, 72, 0x06, 56),
        digest_byte(s, m, 72, 0x06, 57),
        digest_byte(s, m, 72, 0x06, 58),
        digest_byte(s, m, 72, 0x06, 59),
        digest_byte(s, m, 72, 0x06, 60),
        digest_byte(s, m, 72, 0x06, 61),
        digest_byte(s, m, 72, 0x06, 62),
        digest_byte(s, m, 72, 0x06, 63),
    ];
}
