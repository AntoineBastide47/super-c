// Poly1305 (RFC 8439, 2.5), proved: the specification is the RFC's algorithm on integers (`tag`), and
// `poly1305` computes exactly the tag it defines. The implementation holds the accumulator in five 26-bit
// limbs of `Secret<u64>` words; each function runs in constant time on the key and the message bytes
// (`@constant_time`): only the message length picks a branch or an index. No operation panics. Import with
// `import std::crypto::poly1305;`.

import std::crypto::secret as *;
import std::spec::arith;
import std::spec::seq as *;

// The prime 2^130 - 5.
pub(package) spec fn p() int {
    return 0x3fffffffffffffffffffffffffffffffb;
}

// The value of limbs `h`, 26 bits each.
pub(package) spec fn val(h: [Secret<u64>; 5]) int {
    return h[0].value() as int + h[1].value() as int * 0x4000000 + h[2].value() as int * 0x10000000000000 + h[3].value() as int * 0x40000000000000000000 + h[4].value() as int * 0x100000000000000000000000000;
}

// The value of sums `d`, at the limb weights.
spec fn dval(d: [Secret<u64>; 5]) int {
    return d[0].value() as int + d[1].value() as int * 0x4000000 + d[2].value() as int * 0x10000000000000 + d[3].value() as int * 0x40000000000000000000 + d[4].value() as int * 0x100000000000000000000000000;
}

// The limbs `carry` leaves: each below 2^26 but the second, below 2^26 + 2^13.
pub(package) spec fn carried(h: [Secret<u64>; 5]) bool {
    return h[0].value() < 0x4000000 && h[1].value() < 0x4002000 && h[2].value() < 0x4000000 && h[3].value() < 0x4000000 && h[4].value() < 0x4000000;
}

pub(package) spec fn below(h: [Secret<u64>; 5], b: u64) bool {
    return h[0].value() < b && h[1].value() < b && h[2].value() < b && h[3].value() < b && h[4].value() < b;
}

lemma mul_id(h0: int, h1: int, h2: int, h3: int, h4: int, r0: int, r1: int, r2: int, r3: int, r4: int)
    ensures (h0 + h1 * 0x4000000 + h2 * 0x10000000000000 + h3 * 0x40000000000000000000 + h4 * 0x100000000000000000000000000) * (r0 + r1 * 0x4000000 + r2 * 0x10000000000000 + r3 * 0x40000000000000000000 + r4 * 0x100000000000000000000000000) == h0 * r0 + 5 * (h1 * r4 + h2 * r3 + h3 * r2 + h4 * r1) + (h0 * r1 + h1 * r0 + 5 * (h2 * r4 + h3 * r3 + h4 * r2)) * 0x4000000 + (h0 * r2 + h1 * r1 + h2 * r0 + 5 * (h3 * r4 + h4 * r3)) * 0x10000000000000 + (h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + 5 * h4 * r4) * 0x40000000000000000000 + (h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0) * 0x100000000000000000000000000 + p() * (h1 * r4 + h2 * r3 + h3 * r2 + h4 * r1 + (h2 * r4 + h3 * r3 + h4 * r2) * 0x4000000 + (h3 * r4 + h4 * r3) * 0x10000000000000 + h4 * r4 * 0x40000000000000000000)
{}

// `c + a * b`, below 2^64.
@constant_time
const fn mul_add(c: Secret<u64>, a: Secret<u64>, b: Secret<u64>) Secret<u64>
    requires c.value() <= 0x800000000000000 && a.value() < 0x10000000 && b.value() < 0x20000000
    ensures |o| o.value() as int == c.value() as int + a.value() as int * b.value() as int
    ensures |o| o.value() <= c.value() + 0x200000000000000
{
    return c + a * b;
}

// `5 * r`.
@constant_time
const fn times5(r: Secret<u64>) Secret<u64>
    requires r.value() < 0x1000000000000000
    ensures |o| o.value() as int == 5 * r.value() as int
{
    return r * Secret::new(5u64);
}

// `a + b`, below 2^64.
@constant_time
pub(package) const fn add(a: Secret<u64>, b: Secret<u64>) Secret<u64>
    requires a.value() as int + b.value() as int < 0x10000000000000000
    ensures |o| o.value() as int == a.value() as int + b.value() as int
{
    return a + b;
}

// Sum `k` of the products of `h` and `r` at weight 2^(26k), the weights past 2^130 folded by 2^130 = 5
// mod p: `a` holds `r` from index `k` down, `s` holds `5 * r`.
@constant_time
const fn product_sum(
    h: [Secret<u64>; 5],
    a0: Secret<u64>,
    a1: Secret<u64>,
    a2: Secret<u64>,
    a3: Secret<u64>,
    a4: Secret<u64>,
) Secret<u64>
    requires below(h, 0x10000000)
    requires a0.value() < 0x20000000 && a1.value() < 0x20000000 && a2.value() < 0x20000000 && a3.value() < 0x20000000 && a4.value() < 0x20000000
    ensures |o| o.value() as int == h[0].value() as int * a0.value() as int + h[1].value() as int * a1.value() as int + h[2].value() as int * a2.value() as int + h[3].value() as int * a3.value() as int + h[4].value() as int * a4.value() as int
    ensures |o| o.value() < 0x1000000000000000
{
    let z = Secret::new(0u64);
    return mul_add(mul_add(mul_add(mul_add(mul_add(z, h[0], a0), h[1], a1), h[2], a2), h[3], a3), h[4], a4);
}

// `x` split at bit 26.
lemma split(x: u64)
    ensures x as int == (x & 0x3ffffff) as int + 0x4000000 * (x >> 26) as int
    ensures (x & 0x3ffffff) < 0x4000000
{
    assert x / 0x4000000 == x >> 26 by {};
    assert x % 0x4000000 == (x & 0x3ffffff) by {};
    assert x as int == (x % 0x4000000) as int + 0x4000000 * (x / 0x4000000) as int by {};
}

// The low 26 bits of `x` and the carry past them.
@constant_time
const fn carry_out(x: Secret<u64>) [Secret<u64>; 2]
    ensures |o| x.value() as int == o[0].value() as int + 0x4000000 * o[1].value() as int
    ensures |o| o[0].value() < 0x4000000 && o[1].value() as int * 0x4000000 <= x.value() as int
{
    split(x.value());
    return [x & Secret::new(0x3ffffffu64), x >> 26];
}

// Limbs of the value of sums `d` modulo p: each below 2^26 but the second, below 2^26 + 2^13.
@constant_time
fn carry(d: [Secret<u64>; 5]) [Secret<u64>; 5]
    requires below(d, 0x1000000000000000)
    ensures |h| val(h) % p() == dval(d) % p()
    ensures |h| carried(h)
{
    let a0 = carry_out(d[0]);
    let a1 = carry_out(add(d[1], a0[1]));
    let a2 = carry_out(add(d[2], a1[1]));
    let a3 = carry_out(add(d[3], a2[1]));
    let a4 = carry_out(add(d[4], a3[1]));
    let b0 = carry_out(add(a0[0], times5(a4[1])));
    let h = [b0[0], add(a1[0], b0[1]), a2[0], a3[0], a4[0]];
    assert val(h) + p() * a4[1].value() as int == dval(d) by {};
    arith::mod_add_multiple(val(h), a4[1].value() as int, p());
    return h;
}

// `h * r` modulo p, as limbs of `carry`.
@constant_time
pub(package) fn mul_r(h: [Secret<u64>; 5], r: [Secret<u64>; 5]) [Secret<u64>; 5]
    requires below(h, 0x10000000) && below(r, 0x4000000)
    ensures |o| val(o) % p() == val(h) * val(r) % p()
    ensures |o| carried(o)
{
    let s1 = times5(r[1]);
    let s2 = times5(r[2]);
    let s3 = times5(r[3]);
    let s4 = times5(r[4]);
    let d = [
        product_sum(h, r[0], s4, s3, s2, s1),
        product_sum(h, r[1], r[0], s4, s3, s2),
        product_sum(h, r[2], r[1], r[0], s4, s3),
        product_sum(h, r[3], r[2], r[1], r[0], s4),
        product_sum(h, r[4], r[3], r[2], r[1], r[0]),
    ];
    ghost let h0 = h[0].value() as int;
    ghost let h1 = h[1].value() as int;
    ghost let h2 = h[2].value() as int;
    ghost let h3 = h[3].value() as int;
    ghost let h4 = h[4].value() as int;
    ghost let r0 = r[0].value() as int;
    ghost let r1 = r[1].value() as int;
    ghost let r2 = r[2].value() as int;
    ghost let r3 = r[3].value() as int;
    ghost let r4 = r[4].value() as int;
    mul_id(h0, h1, h2, h3, h4, r0, r1, r2, r3, r4);
    arith::mul_eq(h1, s4.value() as int, 5 * r4);
    arith::mul_eq(h2, s3.value() as int, 5 * r3);
    arith::mul_eq(h3, s2.value() as int, 5 * r2);
    arith::mul_eq(h4, s1.value() as int, 5 * r1);
    arith::mul_eq(h2, s4.value() as int, 5 * r4);
    arith::mul_eq(h3, s3.value() as int, 5 * r3);
    arith::mul_eq(h4, s2.value() as int, 5 * r2);
    arith::mul_eq(h3, s4.value() as int, 5 * r4);
    arith::mul_eq(h4, s3.value() as int, 5 * r3);
    arith::mul_eq(h4, s4.value() as int, 5 * r4);
    ghost let q = h1 * r4 + h2 * r3 + h3 * r2 + h4 * r1 + (h2 * r4 + h3 * r3 + h4 * r2) * 0x4000000 + (h3 * r4 + h4 * r3) * 0x10000000000000 + h4 * r4 * 0x40000000000000000000;
    assert val(h) * val(r) == dval(d) + p() * q by {};
    arith::mod_add_multiple(dval(d), q, p());
    return carry(d);
}

// Byte `i` (0 to 16) of block `j` of `m`, padded (2.5): the block's bytes, then 1, then 0. With `whole` a
// block is 16 bytes, its bytes past `m` 0, and its 1 at byte 16: the padding of the AEAD's data (2.8).
pub(package) spec fn pad(m: Seq<Secret<u8>>, j: int, i: int, whole: bool) int {
    let left = m.len() as int - 16 * j;
    let n = if whole || left >= 16 {
        16
    } else {
        left
    };
    return if 0 <= j && 0 <= i && i < n && i < left {
        m[16 * j + i].value() as int
    } else if i == n {
        1
    } else {
        0
    };
}

// The number of block `j` of `m`: its padded bytes, little-endian.
pub(package) spec fn block(m: Seq<Secret<u8>>, j: int, whole: bool) int {
    return pad(m, j, 0, whole) + pad(m, j, 1, whole) * 0x100 + pad(m, j, 2, whole) * 0x10000 + pad(m, j, 3, whole) * 0x1000000 + pad(
        m,
        j,
        4,
        whole,
    ) * 0x100000000 + pad(m, j, 5, whole) * 0x10000000000 + pad(m, j, 6, whole) * 0x1000000000000 + pad(m, j, 7, whole) * 0x100000000000000 + pad(
        m,
        j,
        8,
        whole,
    ) * 0x10000000000000000 + pad(m, j, 9, whole) * 0x1000000000000000000 + pad(m, j, 10, whole) * 0x100000000000000000000 + pad(
        m,
        j,
        11,
        whole,
    ) * 0x10000000000000000000000 + pad(m, j, 12, whole) * 0x1000000000000000000000000 + pad(m, j, 13, whole) * 0x100000000000000000000000000 + pad(
        m,
        j,
        14,
        whole,
    ) * 0x10000000000000000000000000000 + pad(m, j, 15, whole) * 0x1000000000000000000000000000000 + pad(
        m,
        j,
        16,
        whole,
    ) * 0x100000000000000000000000000000000;
}

// Padded byte `i` of block `j` (`pad`).
@constant_time
fn pad_ct(m: []Secret<u8>, j: usize, i: usize, whole: bool) Secret<u64>
    requires 16 * j as int < m.len() as int && i <= 16
    ensures |o| o.value() as int == pad(m.view(), j as int, i as int, whole) && o.value() < 256
    ensures |o| i == 16 ==> o.value() < 2
{
    let left = m.len() - 16 * j;
    let n = if whole || left >= 16 {
        16
    } else {
        left
    };
    if i < n && i < left {
        return m[16 * j + i].cast::<u64>();
    }
    if i == n {
        return Secret::new(1u64);
    }
    return Secret::new(0u64);
}

// `x + 2^8 y + 2^16 z`.
@constant_time
const fn join3(x: Secret<u64>, y: Secret<u64>, z: Secret<u64>) Secret<u64>
    requires x.value() < 256 && y.value() < 256 && z.value() < 256
    ensures |o| o.value() as int == x.value() as int + 0x100 * y.value() as int + 0x10000 * z.value() as int
    ensures |o| o.value() < 0x1000000
{
    return x + (y << 8) + (z << 16);
}

// `(a >> k) + 2^(8 - k) * (b + 2^8 c + 2^16 (d & (2^k - 1)))`: limb bits from byte `a` bit `k` on.
@constant_time
const fn limb_at(a: Secret<u64>, b: Secret<u64>, c: Secret<u64>, d: Secret<u64>, k: usize) Secret<u64>
    requires a.value() < 256 && b.value() < 256 && c.value() < 256 && d.value() < 256 && (k == 2 || k == 4 || k == 6)
    ensures |o| k == 2 ==> o.value() as int == (a.value() >> 2) as int + 0x40 * b.value() as int + 0x4000 * c.value() as int + 0x400000 * (d.value() & 15) as int
    ensures |o| k == 4 ==> o.value() as int == (a.value() >> 4) as int + 0x10 * b.value() as int + 0x1000 * c.value() as int + 0x100000 * (d.value() & 63) as int
    ensures |o| k == 6 ==> o.value() as int == (a.value() >> 6) as int + 0x4 * b.value() as int + 0x400 * c.value() as int + 0x40000 * d.value() as int
    ensures |o| o.value() < 0x4000000
{
    if k == 2 {
        return (a >> 2) + (join3(b, c, d & Secret::new(15u64)) << 6);
    }
    if k == 4 {
        return (a >> 4) + (join3(b, c, d & Secret::new(63u64)) << 4);
    }
    return (a >> 6) + (join3(b, c, d) << 2);
}

// `a + 2^8 b + 2^16 c + 2^24 (d & 3)`.
@constant_time
const fn limb_low(a: Secret<u64>, b: Secret<u64>, c: Secret<u64>, d: Secret<u64>) Secret<u64>
    requires a.value() < 256 && b.value() < 256 && c.value() < 256 && d.value() < 256
    ensures |o| o.value() as int == a.value() as int + 0x100 * b.value() as int + 0x10000 * c.value() as int + 0x1000000 * (d.value() & 3) as int
    ensures |o| o.value() < 0x4000000
{
    return join3(a, b, c) + ((d & Secret::new(3u64)) << 24);
}

// Byte `b` split at bit `k`: its low `k` bits and the rest.
lemma byte_split(b: u64)
    requires b < 256
    ensures b as int == (b & 3) as int + 4 * (b >> 2) as int
    ensures b as int == (b & 15) as int + 16 * (b >> 4) as int
    ensures b as int == (b & 63) as int + 64 * (b >> 6) as int
    ensures b >> 2 < 64 && b >> 4 < 16 && b >> 6 < 4
{
    assert (b & 3) == b % 4 && b >> 2 == b / 4 by {};
    assert (b & 15) == b % 16 && b >> 4 == b / 16 by {};
    assert (b & 63) == b % 64 && b >> 6 == b / 64 by {};
}

// The 26-bit limbs of the 17-byte little-endian number `b`.
@constant_time
pub(package) const fn limbs_of(b: [Secret<u64>; 17]) [Secret<u64>; 5]
    requires b[0].value() < 256 && b[1].value() < 256 && b[2].value() < 256 && b[3].value() < 256 && b[4].value() < 256 && b[5].value() < 256 && b[6].value() < 256 && b[7].value() < 256 && b[8].value() < 256 && b[9].value() < 256 && b[10].value() < 256 && b[11].value() < 256 && b[12].value() < 256 && b[13].value() < 256 && b[14].value() < 256 && b[15].value() < 256 && b[16].value() < 2
    ensures |o| val(o) == b[0].value() as int + b[1].value() as int * 0x100 + b[2].value() as int * 0x10000 + b[3].value() as int * 0x1000000 + b[4].value() as int * 0x100000000 + b[5].value() as int * 0x10000000000 + b[6].value() as int * 0x1000000000000 + b[7].value() as int * 0x100000000000000 + b[8].value() as int * 0x10000000000000000 + b[9].value() as int * 0x1000000000000000000 + b[10].value() as int * 0x100000000000000000000 + b[11].value() as int * 0x10000000000000000000000 + b[12].value() as int * 0x1000000000000000000000000 + b[13].value() as int * 0x100000000000000000000000000 + b[14].value() as int * 0x10000000000000000000000000000 + b[15].value() as int * 0x1000000000000000000000000000000 + b[16].value() as int * 0x100000000000000000000000000000000
    ensures |o| below(o, 0x4000000)
{
    byte_split(b[3].value());
    byte_split(b[6].value());
    byte_split(b[9].value());
    assert (b[16].value() & 3) == b[16].value() by {};
    let l0 = limb_low(b[0], b[1], b[2], b[3]);
    let l1 = limb_at(b[3], b[4], b[5], b[6], 2);
    let l2 = limb_at(b[6], b[7], b[8], b[9], 4);
    let l3 = limb_at(b[9], b[10], b[11], b[12], 6);
    let l4 = limb_low(b[13], b[14], b[15], b[16]);
    return [l0, l1, l2, l3, l4];
}

// Block `j` of `m` as limbs.
@constant_time
fn load(m: []Secret<u8>, j: usize, whole: bool) [Secret<u64>; 5]
    requires 16 * j as int < m.len() as int
    ensures |o| val(o) == block(m.view(), j as int, whole) && below(o, 0x4000000)
{
    return limbs_of(
        [
            pad_ct(m, j, 0, whole),
            pad_ct(m, j, 1, whole),
            pad_ct(m, j, 2, whole),
            pad_ct(m, j, 3, whole),
            pad_ct(m, j, 4, whole),
            pad_ct(m, j, 5, whole),
            pad_ct(m, j, 6, whole),
            pad_ct(m, j, 7, whole),
            pad_ct(m, j, 8, whole),
            pad_ct(m, j, 9, whole),
            pad_ct(m, j, 10, whole),
            pad_ct(m, j, 11, whole),
            pad_ct(m, j, 12, whole),
            pad_ct(m, j, 13, whole),
            pad_ct(m, j, 14, whole),
            pad_ct(m, j, 15, whole),
            pad_ct(m, j, 16, whole),
        ],
    );
}

// `h + b` limb by limb.
@constant_time
pub(package) const fn add_limbs(h: [Secret<u64>; 5], b: [Secret<u64>; 5]) [Secret<u64>; 5]
    requires carried(h) && below(b, 0x4000000)
    ensures |o| val(o) == val(h) + val(b) && below(o, 0x10000000)
{
    return [add(h[0], b[0]), add(h[1], b[1]), add(h[2], b[2]), add(h[3], b[3]), add(h[4], b[4])];
}

// The accumulator after blocks `0..j` of `m` from `a`, with key part `r` (2.5): each block added, then the
// sum times `r`, modulo p.
pub(package) spec fn acc(r: int, m: Seq<Secret<u8>>, j: int, whole: bool, a: int) int
    decreases j
{
    return if j <= 0 {
        a
    } else {
        (acc(r, m, j - 1, whole, a) + block(m, j - 1, whole)) * r % p()
    };
}

lemma acc_step(r: int, m: Seq<Secret<u8>>, j: int, whole: bool, a: int)
    requires j >= 0
    ensures acc(r, m, j + 1, whole, a) == (acc(r, m, j, whole, a) + block(m, j, whole)) * r % p()
{}

// `(h + b) * r` modulo p depends on `h` modulo p only.
pub(package) lemma step_mod(h: int, b: int, r: int)
    requires h >= 0 && b >= 0 && r >= 0
    ensures (h + b) * r % p() == (h % p() + b) * r % p()
{
    arith::div_mod(h, p());
    arith::mod_add(h, b, p());
    arith::mod_add(h % p(), b, p());
    arith::mod_mod(h, p());
    arith::mod_mul(h + b, r, p());
    arith::mod_mul(h % p() + b, r, p());
    arith::mul_eq(r % p(), (h + b) % p(), (h % p() + b) % p());
}

// One block on the limbs: `h` holds `a` modulo p, `x` is `h` plus the block `b`, and `n` holds `x * r`.
pub(package) lemma absorb_step(h: int, x: int, b: int, r: int, a: int, n: int)
    requires h >= 0 && b >= 0 && r >= 0
    requires h % p() == a && x == h + b && n % p() == x * r % p()
    ensures n % p() == (a + b) * r % p()
{
    arith::mul_eq(r, x, h + b);
    step_mod(h, b, r);
}

// The accumulator of the blocks of `m` from `h`, with key part `r`, as limbs.
@constant_time
pub(package) fn absorb(r: [Secret<u64>; 5], m: []Secret<u8>, whole: bool, h: [Secret<u64>; 5]) [Secret<u64>; 5]
    requires below(r, 0x4000000) && carried(h)
    ensures |o| val(o) % p() == acc(val(r), m.view(), (m.view().len() as int + 15) / 16, whole, val(h) % p())
    ensures |o| carried(o)
{
    let nb = (m.len() + 15) / 16;
    assert nb as int == (m.view().len() as int + 15) / 16 by {};
    let mut x = h;
    for j in 0..nb
        invariant carried(x)
        invariant val(x) % p() == acc(val(r), m.view(), j as int, whole, val(h) % p())
    {
        let y = add_limbs(x, load(m, j, whole));
        let n = mul_r(y, r);
        acc_step(val(r), m.view(), j as int, whole, val(h) % p());
        absorb_step(
            val(x),
            val(y),
            block(m.view(), j as int, whole),
            val(r),
            acc(val(r), m.view(), j as int, whole, val(h) % p()),
            val(n),
        );
        x = n;
    }
    return x;
}

// `r`, the first half of key `key` with bits cleared (2.5).
pub(package) spec fn r_of(key: [u8; 32]) int {
    return (key[0] & 0xff) as int + (key[1] & 0xff) as int * 0x100 + (key[2] & 0xff) as int * 0x10000 + (key[3] & 0x0f) as int * 0x1000000 + (key[4] & 0xfc) as int * 0x100000000 + (key[5] & 0xff) as int * 0x10000000000 + (key[6] & 0xff) as int * 0x1000000000000 + (key[7] & 0x0f) as int * 0x100000000000000 + (key[8] & 0xfc) as int * 0x10000000000000000 + (key[9] & 0xff) as int * 0x1000000000000000000 + (key[10] & 0xff) as int * 0x100000000000000000000 + (key[11] & 0x0f) as int * 0x10000000000000000000000 + (key[12] & 0xfc) as int * 0x1000000000000000000000000 + (key[13] & 0xff) as int * 0x100000000000000000000000000 + (key[14] & 0xff) as int * 0x10000000000000000000000000000 + (key[15] & 0x0f) as int * 0x1000000000000000000000000000000;
}

// `s`, the second half of key `key`.
pub(package) spec fn s_of(key: [u8; 32]) int {
    return key[16] as int + key[17] as int * 0x100 + key[18] as int * 0x10000 + key[19] as int * 0x1000000 + key[20] as int * 0x100000000 + key[21] as int * 0x10000000000 + key[22] as int * 0x1000000000000 + key[23] as int * 0x100000000000000 + key[24] as int * 0x10000000000000000 + key[25] as int * 0x1000000000000000000 + key[26] as int * 0x100000000000000000000 + key[27] as int * 0x10000000000000000000000 + key[28] as int * 0x1000000000000000000000000 + key[29] as int * 0x100000000000000000000000000 + key[30] as int * 0x10000000000000000000000000000 + key[31] as int * 0x1000000000000000000000000000000;
}

/// The values of the bytes of `key`.
pub spec fn key_values(key: [Secret<u8>; 32]) [u8; 32] {
    return [
        key[0].value(),
        key[1].value(),
        key[2].value(),
        key[3].value(),
        key[4].value(),
        key[5].value(),
        key[6].value(),
        key[7].value(),
        key[8].value(),
        key[9].value(),
        key[10].value(),
        key[11].value(),
        key[12].value(),
        key[13].value(),
        key[14].value(),
        key[15].value(),
        key[16].value(),
        key[17].value(),
        key[18].value(),
        key[19].value(),
        key[20].value(),
        key[21].value(),
        key[22].value(),
        key[23].value(),
        key[24].value(),
        key[25].value(),
        key[26].value(),
        key[27].value(),
        key[28].value(),
        key[29].value(),
        key[30].value(),
        key[31].value(),
    ];
}

/// The value of tag `t`, little-endian.
pub spec fn tag_value(t: [Secret<u8>; 16]) int {
    return t[0].value() as int + t[1].value() as int * 0x100 + t[2].value() as int * 0x10000 + t[3].value() as int * 0x1000000 + t[4].value() as int * 0x100000000 + t[5].value() as int * 0x10000000000 + t[6].value() as int * 0x1000000000000 + t[7].value() as int * 0x100000000000000 + t[8].value() as int * 0x10000000000000000 + t[9].value() as int * 0x1000000000000000000 + t[10].value() as int * 0x100000000000000000000 + t[11].value() as int * 0x10000000000000000000000 + t[12].value() as int * 0x1000000000000000000000000 + t[13].value() as int * 0x100000000000000000000000000 + t[14].value() as int * 0x10000000000000000000000000000 + t[15].value() as int * 0x1000000000000000000000000000000;
}

/// The Poly1305 tag of `m` under the one-time key `key` (RFC 8439, 2.5) as a number: the accumulator of
/// the blocks of `m` with `r`, plus `s`, modulo 2^128.
pub spec fn tag(key: [u8; 32], m: Seq<Secret<u8>>) int {
    return (acc(r_of(key), m, (m.len() as int + 15) / 16, false, 0) + s_of(key)) % 0x100000000000000000000000000000000;
}

// `r` as limbs.
@constant_time
pub(package) fn load_r(key: [Secret<u8>; 32]) [Secret<u64>; 5]
    ensures |o| val(o) == r_of(key_values(key)) && below(o, 0x4000000)
{
    return limbs_of(
        [
            (key[0] & Secret::new(0xffu8)).cast::<u64>(),
            (key[1] & Secret::new(0xffu8)).cast::<u64>(),
            (key[2] & Secret::new(0xffu8)).cast::<u64>(),
            (key[3] & Secret::new(0x0fu8)).cast::<u64>(),
            (key[4] & Secret::new(0xfcu8)).cast::<u64>(),
            (key[5] & Secret::new(0xffu8)).cast::<u64>(),
            (key[6] & Secret::new(0xffu8)).cast::<u64>(),
            (key[7] & Secret::new(0x0fu8)).cast::<u64>(),
            (key[8] & Secret::new(0xfcu8)).cast::<u64>(),
            (key[9] & Secret::new(0xffu8)).cast::<u64>(),
            (key[10] & Secret::new(0xffu8)).cast::<u64>(),
            (key[11] & Secret::new(0x0fu8)).cast::<u64>(),
            (key[12] & Secret::new(0xfcu8)).cast::<u64>(),
            (key[13] & Secret::new(0xffu8)).cast::<u64>(),
            (key[14] & Secret::new(0xffu8)).cast::<u64>(),
            (key[15] & Secret::new(0x0fu8)).cast::<u64>(),
            Secret::new(0u64),
        ],
    );
}

// The limbs of the block of lengths `a` and `c` (2.8): `a + 2^64 c` and its 1 at byte 16.
@constant_time
const fn length_limbs(a: u64, c: u64) [Secret<u64>; 5]
    ensures |o| val(o) == a as int + c as int * 0x10000000000000000 + 0x100000000000000000000000000000000
    ensures |o| below(o, 0x4000000)
{
    let a1 = a / 0x4000000;
    let c1 = c / 0x4000;
    return [
        Secret::new(a % 0x4000000),
        Secret::new(a1 % 0x4000000),
        Secret::new(a1 / 0x4000000 + c % 0x4000 * 0x1000),
        Secret::new(c1 % 0x4000000),
        Secret::new(c1 / 0x4000000 + 0x1000000),
    ];
}

// The block of lengths `a` and `c` absorbed into `h`.
@constant_time
pub(package) fn absorb_lengths(r: [Secret<u64>; 5], h: [Secret<u64>; 5], a: u64, c: u64) [Secret<u64>; 5]
    requires below(r, 0x4000000) && carried(h)
    ensures |o| val(o) % p() == (val(h) % p() + a as int + c as int * 0x10000000000000000 + 0x100000000000000000000000000000000) * val(
        r,
    ) % p()
    ensures |o| carried(o)
{
    let b = length_limbs(a, c);
    let s = add_limbs(h, b);
    let n = mul_r(s, r);
    absorb_step(
        val(h),
        val(s),
        a as int + c as int * 0x10000000000000000 + 0x100000000000000000000000000000000,
        val(r),
        val(h) % p(),
        val(n),
    );
    return n;
}

// `(x + l1) * r1` and `(y + l2) * r2` modulo p are equal where `x == y`, `l1 == l2` and `r1 == r2`.
pub(package) lemma mul_mod_eq(x: int, y: int, l1: int, l2: int, r1: int, r2: int)
    requires x == y && l1 == l2 && r1 == r2
    ensures (x + l1) * r1 % p() == (y + l2) * r2 % p()
{
    arith::mul_eq(x + l1, r1, r2);
    arith::mul_eq(r2, x + l1, y + l2);
}

// The limbs of `h + c`, each below 2^26, and the carry past 2^130.
@constant_time
const fn chain(h: [Secret<u64>; 5], c: Secret<u64>) [Secret<u64>; 6]
    requires below(h, 0x4002000) && c.value() < 0x100
    ensures |o| o[0].value() as int + o[1].value() as int * 0x4000000 + o[2].value() as int * 0x10000000000000 + o[3].value() as int * 0x40000000000000000000 + o[4].value() as int * 0x100000000000000000000000000 + o[5].value() as int * 0x400000000000000000000000000000000 == val(
        h,
    ) + c.value() as int
    ensures |o| below([o[0], o[1], o[2], o[3], o[4]], 0x4000000) && o[5].value() < 2
{
    let a0 = carry_out(add(h[0], c));
    let a1 = carry_out(add(h[1], a0[1]));
    let a2 = carry_out(add(h[2], a1[1]));
    let a3 = carry_out(add(h[3], a2[1]));
    let a4 = carry_out(add(h[4], a3[1]));
    return [a0[0], a1[0], a2[0], a3[0], a4[0], a4[1]];
}

// `a` where `c` is 1, else `b`.
@constant_time
fn pick_word(c: Secret<u64>, a: Secret<u64>, b: Secret<u64>) Secret<u64>
    requires c.value() < 2
    ensures |o| c.value() == 1 ==> o.value() == a.value()
    ensures |o| c.value() == 0 ==> o.value() == b.value()
{
    return Secret::pick(c.eq(Secret::new(1u64)), a, b);
}

// `a` where `c` is 1, else `b`.
@constant_time
fn choose(c: Secret<u64>, a: [Secret<u64>; 5], b: [Secret<u64>; 5]) [Secret<u64>; 5]
    requires c.value() < 2 && below(a, 0x4000000) && below(b, 0x4000000)
    ensures |o| (c.value() == 1 ==> val(o) == val(a)) && (c.value() == 0 ==> val(o) == val(b))
    ensures |o| below(o, 0x4000000)
{
    return [
        pick_word(c, a[0], b[0]),
        pick_word(c, a[1], b[1]),
        pick_word(c, a[2], b[2]),
        pick_word(c, a[3], b[3]),
        pick_word(c, a[4], b[4]),
    ];
}

// The reduction modulo p on values: `v` is `k` plus `k5` times 2^130, `u` is `k + 5 k5` less `u5`
// times 2^130, `g` is `u + 5` less `g5` times 2^130, and `o` is `g` where `g5` is 1, else `u`.
lemma reduced(v: int, k: int, k5: int, u: int, u5: int, g: int, g5: int, o: int)
    requires 0 <= k
    requires k < 0x400000000000000000000000000000000
    requires k5 == 0 || k5 == 1
    requires v == k + k5 * 0x400000000000000000000000000000000
    requires v < 0x400000000000000000000000000000000 + 0x8000000000
    requires 0 <= u
    requires u < 0x400000000000000000000000000000000
    requires u5 == 0 || u5 == 1
    requires u + u5 * 0x400000000000000000000000000000000 == k + 5 * k5
    requires 0 <= g
    requires g < 0x400000000000000000000000000000000
    requires g5 == 0 || g5 == 1
    requires g + g5 * 0x400000000000000000000000000000000 == u + 5
    requires g5 == 1 ==> o == g
    requires g5 == 0 ==> o == u
    ensures o == v % p()
{
    assert u5 == 0 by {};
    arith::mod_add_multiple(u, k5, p());
    arith::mod_unique(u, g5, o, p());
}

// The limbs of `h` modulo p, each below 2^26.
@constant_time
pub(package) fn reduce(h: [Secret<u64>; 5]) [Secret<u64>; 5]
    requires carried(h)
    ensures |o| val(o) == val(h) % p() && below(o, 0x4000000)
{
    let k = chain(h, Secret::new(0u64));
    let kl = [k[0], k[1], k[2], k[3], k[4]];
    let j = chain(kl, times5(k[5]));
    let u = [j[0], j[1], j[2], j[3], j[4]];
    let g = chain(u, Secret::new(5u64));
    let w = [g[0], g[1], g[2], g[3], g[4]];
    let o = choose(g[5], w, u);
    reduced(val(h), val(kl), k[5].value() as int, val(u), j[5].value() as int, val(w), g[5].value() as int, val(o));
    return o;
}

// Limb `x` (below 2^26) split at bits 6, 12, 18 and 24.
lemma limb_split(x: u64)
    requires x < 0x4000000
    ensures x as int == (x & 0x3f) as int + 0x40 * (x >> 6) as int && x >> 6 < 0x100000
    ensures x as int == (x & 0xfff) as int + 0x1000 * (x >> 12) as int && x >> 12 < 0x4000
    ensures x as int == (x & 0x3ffff) as int + 0x40000 * (x >> 18) as int && x >> 18 < 0x100
    ensures x as int == (x & 0xffffff) as int + 0x1000000 * (x >> 24) as int && x >> 24 < 4
{
    assert (x & 0x3f) == x % 0x40 && x >> 6 == x / 0x40 by {};
    assert (x & 0xfff) == x % 0x1000 && x >> 12 == x / 0x1000 by {};
    assert (x & 0x3ffff) == x % 0x40000 && x >> 18 == x / 0x40000 by {};
    assert (x & 0xffffff) == x % 0x1000000 && x >> 24 == x / 0x1000000 by {};
}

// `lo + hi * m`, below 2^64.
@constant_time
const fn mul_add_k(lo: Secret<u64>, hi: Secret<u64>, m: u64) Secret<u64>
    requires hi.value() < 0x100000000 && m <= 0x4000000 && lo.value() < 0x100000000
    ensures |o| o.value() as int == lo.value() as int + hi.value() as int * m as int
{
    return lo + hi * Secret::new(m);
}

// `x & m`.
@constant_time
const fn mask(x: Secret<u64>, m: u64) Secret<u64>
    ensures |o| o.value() == (x.value() & m)
{
    return x & Secret::new(m);
}

// The low 128 bits of the value of limbs `f` (each below 2^26) as four 32-bit words; `f[4] >> 24` holds
// the bits past them.
@constant_time
const fn words_of(f: [Secret<u64>; 5]) [Secret<u64>; 4]
    requires below(f, 0x4000000)
    ensures |w| w[0].value() as int + w[1].value() as int * 0x100000000 + w[2].value() as int * 0x10000000000000000 + w[3].value() as int * 0x1000000000000000000000000 + (f[4].value() >> 24) as int * 0x100000000000000000000000000000000 == val(
        f,
    )
    ensures |w| w[0].value() < 0x100000000 && w[1].value() < 0x100000000 && w[2].value() < 0x100000000 && w[3].value() < 0x100000000
{
    limb_split(f[1].value());
    limb_split(f[2].value());
    limb_split(f[3].value());
    limb_split(f[4].value());
    return [
        mul_add_k(f[0], mask(f[1], 0x3f), 0x4000000),
        mul_add_k(f[1] >> 6, mask(f[2], 0xfff), 0x100000),
        mul_add_k(f[2] >> 12, mask(f[3], 0x3ffff), 0x4000),
        mul_add_k(f[3] >> 18, mask(f[4], 0xffffff), 0x100),
    ];
}

// The little-endian word of bytes `a`, `b`, `c` and `d`.
@constant_time
pub(package) fn le_word(a: Secret<u8>, b: Secret<u8>, c: Secret<u8>, d: Secret<u8>) Secret<u64>
    ensures |o| o.value() as int == a.value() as int + 0x100 * b.value() as int + 0x10000 * c.value() as int + 0x1000000 * d.value() as int
    ensures |o| o.value() < 0x100000000
{
    return mul_add_k(join3(a.cast::<u64>(), b.cast::<u64>(), c.cast::<u64>()), d.cast::<u64>(), 0x1000000);
}

// `x` (below 2^34) split at bit 32.
@constant_time
const fn split32(x: Secret<u64>) [Secret<u64>; 2]
    requires x.value() < 0x400000000
    ensures |o| x.value() as int == o[0].value() as int + 0x100000000 * o[1].value() as int
    ensures |o| o[0].value() < 0x100000000 && o[1].value() < 4
{
    assert (x.value() & 0xffffffff) == x.value() % 0x100000000 && x.value() >> 32 == x.value() / 0x100000000 by {};
    return [mask(x, 0xffffffff), x >> 32];
}

// `y` split at bit 8: its low byte and the rest.
lemma split8(y: u64)
    ensures y as int == (y as u8) as int + 0x100 * (y >> 8) as int
{
    assert (y as u8) as u64 == y % 0x100 && y >> 8 == y / 0x100 by {};
}

// The bytes of word `w` (below 2^32), little-endian.
@constant_time
pub(package) fn word_bytes(w: Secret<u64>) [Secret<u8>; 4]
    requires w.value() < 0x100000000
    ensures |o| o[0].value() as int + 0x100 * o[1].value() as int + 0x10000 * o[2].value() as int + 0x1000000 * o[3].value() as int == w.value() as int
{
    ghost let x = w.value();
    split8(x);
    split8(x >> 8);
    split8(x >> 16);
    assert x >> 8 >> 8 == x >> 16 && x >> 16 >> 8 == x >> 24 && x >> 24 < 0x100 by {};
    return [w.cast::<u8>(), (w >> 8).cast::<u8>(), (w >> 16).cast::<u8>(), (w >> 24).cast::<u8>()];
}

// The tag bytes: `val(f) + s` modulo 2^128, little-endian.
@constant_time
pub(package) fn finish(f: [Secret<u64>; 5], key: [Secret<u8>; 32]) [Secret<u8>; 16]
    requires below(f, 0x4000000)
    ensures |t| tag_value(t) == (val(f) + s_of(key_values(key))) % 0x100000000000000000000000000000000
{
    let w = words_of(f);
    let s0 = le_word(key[16], key[17], key[18], key[19]);
    let s1 = le_word(key[20], key[21], key[22], key[23]);
    let s2 = le_word(key[24], key[25], key[26], key[27]);
    let s3 = le_word(key[28], key[29], key[30], key[31]);
    let a0 = split32(add(w[0], s0));
    let a1 = split32(add(add(w[1], s1), a0[1]));
    let a2 = split32(add(add(w[2], s2), a1[1]));
    let a3 = split32(add(add(w[3], s3), a2[1]));
    let b0 = word_bytes(a0[0]);
    let b1 = word_bytes(a1[0]);
    let b2 = word_bytes(a2[0]);
    let b3 = word_bytes(a3[0]);
    let t = [
        b0[0],
        b0[1],
        b0[2],
        b0[3],
        b1[0],
        b1[1],
        b1[2],
        b1[3],
        b2[0],
        b2[1],
        b2[2],
        b2[3],
        b3[0],
        b3[1],
        b3[2],
        b3[3],
    ];
    arith::mod_unique(
        val(f) + s_of(key_values(key)),
        a3[1].value() as int + (f[4].value() >> 24) as int,
        tag_value(t),
        0x100000000000000000000000000000000,
    );
    return t;
}

/// The Poly1305 tag of `m` under the one-time key `key` (RFC 8439, 2.5). A key authenticates one message:
/// two tags under one key reveal it.
@constant_time
pub fn poly1305(key: [Secret<u8>; 32], m: []Secret<u8>) [Secret<u8>; 16]
    ensures |t| tag_value(t) == tag(key_values(key), m.view())
{
    let z = Secret::new(0u64);
    let zero = [z, z, z, z, z];
    let r = load_r(key);
    assert val(zero) % p() == 0 by {};
    let f = reduce(absorb(r, m, false, zero));
    assert val(f) == acc(r_of(key_values(key)), m.view(), (m.view().len() as int + 15) / 16, false, 0) by {};
    return finish(f, key);
}
