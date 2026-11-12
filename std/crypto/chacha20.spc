// ChaCha20 (RFC 8439), proved: the specification is the RFC's text as spec functions (the quarter round
// of 2.1, the state and the block function of 2.3, the key stream of 2.4), and `chacha20` computes exactly
// the bytes it defines. Every function runs in constant time on the key and the data (`@constant_time`):
// only the lengths, the nonce and the counter, which are public, pick a branch or an index. No operation
// panics: the prover proves each check. The block counter wraps at 2^32, as the 32-bit counter of the RFC
// does; a message of more than 2^32 blocks reuses the key stream. Import with
// `import std::crypto::chacha20;`.

import std::crypto::secret as *;
import std::spec::seq as *;

// The quarter round on words `a`, `b`, `c` and `d` (2.1).
spec fn quarter(a: u32, b: u32, c: u32, d: u32) [u32; 4] {
    let a1 = a.wrapping_add(b);
    let d1 = (d ^ a1).rotate_left(16);
    let c1 = c.wrapping_add(d1);
    let b1 = (b ^ c1).rotate_left(12);
    let a2 = a1.wrapping_add(b1);
    let d2 = (d1 ^ a2).rotate_left(8);
    let c2 = c1.wrapping_add(d2);
    let b2 = (b1 ^ c2).rotate_left(7);
    return [a2, b2, c2, d2];
}

// The quarter rounds on the columns of the state (2.3).
spec fn column_round(s: [u32; 16]) [u32; 16] {
    let q0 = quarter(s[0], s[4], s[8], s[12]);
    let q1 = quarter(s[1], s[5], s[9], s[13]);
    let q2 = quarter(s[2], s[6], s[10], s[14]);
    let q3 = quarter(s[3], s[7], s[11], s[15]);
    return [
        q0[0],
        q1[0],
        q2[0],
        q3[0],
        q0[1],
        q1[1],
        q2[1],
        q3[1],
        q0[2],
        q1[2],
        q2[2],
        q3[2],
        q0[3],
        q1[3],
        q2[3],
        q3[3],
    ];
}

// The quarter rounds on the diagonals of the state (2.3).
spec fn diagonal_round(s: [u32; 16]) [u32; 16] {
    let q0 = quarter(s[0], s[5], s[10], s[15]);
    let q1 = quarter(s[1], s[6], s[11], s[12]);
    let q2 = quarter(s[2], s[7], s[8], s[13]);
    let q3 = quarter(s[3], s[4], s[9], s[14]);
    return [
        q0[0],
        q1[0],
        q2[0],
        q3[0],
        q3[1],
        q0[1],
        q1[1],
        q2[1],
        q2[2],
        q3[2],
        q0[2],
        q1[2],
        q1[3],
        q2[3],
        q3[3],
        q0[3],
    ];
}

// The state after `n` double rounds.
spec fn rounds(s: [u32; 16], n: u32) [u32; 16]
    requires n <= 10
    decreases n
{
    return if n == 0 {
        s
    } else {
        diagonal_round(column_round(rounds(s, n - 1)))
    };
}

// The values of the words of state `s`.
pub(package) spec fn values(s: [Secret<u32>; 16]) [u32; 16] {
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
    ];
}

// The little-endian word of bytes `a`, `b`, `c` and `d`.
spec fn le32(a: u8, b: u8, c: u8, d: u8) u32 {
    return a as u32 | b as u32 << 8 | c as u32 << 16 | d as u32 << 24;
}

// Word `j` of the key.
spec fn key_word(key: [Secret<u8>; 32], j: usize) u32
    requires j < 8
{
    return le32(key[4 * j].value(), key[4 * j + 1].value(), key[4 * j + 2].value(), key[4 * j + 3].value());
}

// The initial state (2.3).
spec fn init(key: [Secret<u8>; 32], counter: u32, nonce: [u8; 12]) [u32; 16] {
    return [
        0x61707865,
        0x3320646e,
        0x79622d32,
        0x6b206574,
        key_word(key, 0),
        key_word(key, 1),
        key_word(key, 2),
        key_word(key, 3),
        key_word(key, 4),
        key_word(key, 5),
        key_word(key, 6),
        key_word(key, 7),
        counter,
        le32(nonce[0], nonce[1], nonce[2], nonce[3]),
        le32(nonce[4], nonce[5], nonce[6], nonce[7]),
        le32(nonce[8], nonce[9], nonce[10], nonce[11]),
    ];
}

// The block function's words (2.3).
pub(package) spec fn block(key: [Secret<u8>; 32], counter: u32, nonce: [u8; 12]) [u32; 16] {
    let s = init(key, counter, nonce);
    let x = rounds(s, 10);
    return [
        x[0].wrapping_add(s[0]),
        x[1].wrapping_add(s[1]),
        x[2].wrapping_add(s[2]),
        x[3].wrapping_add(s[3]),
        x[4].wrapping_add(s[4]),
        x[5].wrapping_add(s[5]),
        x[6].wrapping_add(s[6]),
        x[7].wrapping_add(s[7]),
        x[8].wrapping_add(s[8]),
        x[9].wrapping_add(s[9]),
        x[10].wrapping_add(s[10]),
        x[11].wrapping_add(s[11]),
        x[12].wrapping_add(s[12]),
        x[13].wrapping_add(s[13]),
        x[14].wrapping_add(s[14]),
        x[15].wrapping_add(s[15]),
    ];
}

// Byte `j` of words `w`, little-endian.
pub(package) spec fn byte_of(w: [u32; 16], j: usize) u8
    requires j < 64
{
    return (w[j / 4] >> (j % 4 * 8) as u32) as u8;
}

/// Byte `i` of the ChaCha20 key stream of `key` and `nonce` from block `counter` on (RFC 8439, 2.4):
/// byte `i % 64` of block `counter + i / 64`, the counter modulo 2^32.
pub spec fn stream(key: [Secret<u8>; 32], nonce: [u8; 12], counter: u32, i: int) u8
    requires i >= 0
{
    return byte_of(block(key, counter.wrapping_add((i / 64) as u32), nonce), (i % 64) as usize);
}

@constant_time
fn quarter_ct(a: Secret<u32>, b: Secret<u32>, c: Secret<u32>, d: Secret<u32>) [Secret<u32>; 4]
    ensures |r| [r[0].value(), r[1].value(), r[2].value(), r[3].value()] == quarter(
        a.value(),
        b.value(),
        c.value(),
        d.value(),
    )
{
    let a1 = a + b;
    let d1 = (d ^ a1).rotate_left(16);
    let c1 = c + d1;
    let b1 = (b ^ c1).rotate_left(12);
    let a2 = a1 + b1;
    let d2 = (d1 ^ a2).rotate_left(8);
    let c2 = c1 + d2;
    let b2 = (b1 ^ c2).rotate_left(7);
    return [a2, b2, c2, d2];
}

@constant_time
fn column_ct(s: [Secret<u32>; 16]) [Secret<u32>; 16]
    ensures |r| values(r) == column_round(values(s))
{
    let q0 = quarter_ct(s[0], s[4], s[8], s[12]);
    let q1 = quarter_ct(s[1], s[5], s[9], s[13]);
    let q2 = quarter_ct(s[2], s[6], s[10], s[14]);
    let q3 = quarter_ct(s[3], s[7], s[11], s[15]);
    return [
        q0[0],
        q1[0],
        q2[0],
        q3[0],
        q0[1],
        q1[1],
        q2[1],
        q3[1],
        q0[2],
        q1[2],
        q2[2],
        q3[2],
        q0[3],
        q1[3],
        q2[3],
        q3[3],
    ];
}

@constant_time
fn diagonal_ct(s: [Secret<u32>; 16]) [Secret<u32>; 16]
    ensures |r| values(r) == diagonal_round(values(s))
{
    let q0 = quarter_ct(s[0], s[5], s[10], s[15]);
    let q1 = quarter_ct(s[1], s[6], s[11], s[12]);
    let q2 = quarter_ct(s[2], s[7], s[8], s[13]);
    let q3 = quarter_ct(s[3], s[4], s[9], s[14]);
    return [
        q0[0],
        q1[0],
        q2[0],
        q3[0],
        q3[1],
        q0[1],
        q1[1],
        q2[1],
        q2[2],
        q3[2],
        q0[2],
        q1[2],
        q1[3],
        q2[3],
        q3[3],
        q0[3],
    ];
}

lemma rounds_step(s: [u32; 16], i: u32)
    requires i < 10
    ensures rounds(s, i + 1) == diagonal_round(column_round(rounds(s, i)))
{}

lemma rounds_next(s: [u32; 16], a: [u32; 16], i: u32)
    requires i < 10
    requires a == rounds(s, i)
    ensures diagonal_round(column_round(a)) == rounds(s, i + 1)
{
    rounds_step(s, i);
}

@constant_time
fn two_ct(x: [Secret<u32>; 16]) [Secret<u32>; 16]
    ensures |r| values(r) == diagonal_round(column_round(values(x)))
{
    return diagonal_ct(column_ct(x));
}

// Double round `i` on the state after rounds `0..i`.
@constant_time
fn next_rounds(s: [Secret<u32>; 16], i: u32, x: [Secret<u32>; 16]) [Secret<u32>; 16]
    requires i < 10
    requires values(x) == rounds(values(s), i)
    ensures |r| values(r) == rounds(values(s), i + 1)
{
    rounds_next(values(s), values(x), i);
    return two_ct(x);
}

@constant_time
fn rounds_ct(s: [Secret<u32>; 16]) [Secret<u32>; 16]
    ensures |r| values(r) == rounds(values(s), 10)
{
    let mut x = s;
    let mut i: u32 = 0;
    while i < 10
        invariant i <= 10
        invariant values(x) == rounds(values(s), i)
    {
        x = next_rounds(s, i, x);
        i += 1;
    }
    assert i == 10 by {};
    return x;
}

@constant_time
fn key_word_ct(key: [Secret<u8>; 32], j: usize) Secret<u32>
    requires j < 8
    ensures |r| r.value() == key_word(key, j)
{
    return key[4 * j].cast::<u32>() | key[4 * j + 1].cast::<u32>() << 8 | key[4 * j + 2].cast::<u32>() << 16 | key[4 * j + 3].cast::<
        u32
    >() << 24;
}

@constant_time
fn init_ct(key: [Secret<u8>; 32], counter: u32, nonce: [u8; 12]) [Secret<u32>; 16]
    ensures |r| values(r) == init(key, counter, nonce)
{
    return [
        Secret::new(0x61707865u32),
        Secret::new(0x3320646eu32),
        Secret::new(0x79622d32u32),
        Secret::new(0x6b206574u32),
        key_word_ct(key, 0),
        key_word_ct(key, 1),
        key_word_ct(key, 2),
        key_word_ct(key, 3),
        key_word_ct(key, 4),
        key_word_ct(key, 5),
        key_word_ct(key, 6),
        key_word_ct(key, 7),
        Secret::new(counter),
        Secret::new(nonce[0] as u32 | nonce[1] as u32 << 8 | nonce[2] as u32 << 16 | nonce[3] as u32 << 24),
        Secret::new(nonce[4] as u32 | nonce[5] as u32 << 8 | nonce[6] as u32 << 16 | nonce[7] as u32 << 24),
        Secret::new(nonce[8] as u32 | nonce[9] as u32 << 8 | nonce[10] as u32 << 16 | nonce[11] as u32 << 24),
    ];
}

@constant_time
pub(package) fn block_ct(key: [Secret<u8>; 32], counter: u32, nonce: [u8; 12]) [Secret<u32>; 16]
    ensures |r| values(r) == block(key, counter, nonce)
{
    let s = init_ct(key, counter, nonce);
    let x = rounds_ct(s);
    return [
        x[0] + s[0],
        x[1] + s[1],
        x[2] + s[2],
        x[3] + s[3],
        x[4] + s[4],
        x[5] + s[5],
        x[6] + s[6],
        x[7] + s[7],
        x[8] + s[8],
        x[9] + s[9],
        x[10] + s[10],
        x[11] + s[11],
        x[12] + s[12],
        x[13] + s[13],
        x[14] + s[14],
        x[15] + s[15],
    ];
}

// Byte `j` of block words `w`.
@constant_time
pub(package) fn stream_byte(w: [Secret<u32>; 16], j: usize) Secret<u8>
    requires j < 64
    ensures |r| r.value() == byte_of(values(w), j)
{
    return (w[j / 4] >> j % 4 * 8).cast::<u8>();
}

// Byte `p + j` lies in block `p / 64`, at `j`.
lemma block_index(p: usize, j: usize)
    requires p % 64 == 0 && j < 64
    ensures ((p as int + j as int) / 64) as u32 == (p / 64) as u32
{}

lemma byte_index(p: usize, j: usize)
    requires p % 64 == 0 && j < 64
    ensures ((p as int + j as int) % 64) as usize == j
{}

lemma block_eq(key: [Secret<u8>; 32], nonce: [u8; 12], c1: u32, c2: u32)
    requires c1 == c2
    ensures block(key, c1, nonce) == block(key, c2, nonce)
{}

lemma stream_in_block(key: [Secret<u8>; 32], nonce: [u8; 12], counter: u32, i: int, w: [u32; 16])
    requires i >= 0
    requires w == block(key, counter.wrapping_add((i / 64) as u32), nonce)
    ensures stream(key, nonce, counter, i) == byte_of(w, (i % 64) as usize)
{}

// Byte `p + j` of the key stream: byte `j` of block `p / 64`, `w`.
lemma stream_at(key: [Secret<u8>; 32], nonce: [u8; 12], counter: u32, p: usize, j: usize, w: [u32; 16])
    requires p % 64 == 0 && j < 64
    requires w == block(key, counter.wrapping_add((p / 64) as u32), nonce)
    ensures stream(key, nonce, counter, p as int + j as int) == byte_of(w, j)
{
    block_index(p, j);
    byte_index(p, j);
    block_eq(
        key,
        nonce,
        counter.wrapping_add((p / 64) as u32),
        counter.wrapping_add(((p as int + j as int) / 64) as u32),
    );
    stream_in_block(key, nonce, counter, p as int + j as int, w);
}

// Bytes `p..p + m` of `output`: `input` XOR the key stream, the block of `p` in `w`.
@constant_time
fn xor_block(
    key: [Secret<u8>; 32],
    nonce: [u8; 12],
    counter: u32,
    input: []Secret<u8>,
    output: []mut Secret<u8>,
    p: usize,
    m: usize,
    w: [Secret<u32>; 16],
)
    requires output.len() == input.len()
    requires p % 64 == 0 && m <= 64 && p as int + m as int <= input.len() as int
    requires values(w) == block(key, counter.wrapping_add((p / 64) as u32), nonce)
    requires forall k in 0..p {
        output.view()[k as int].value() == (input[k].value() ^ stream(key, nonce, counter, k as int))
    }
    ensures output.len() == input.len()
    ensures forall k in 0..p + m {
        output.view()[k as int].value() == (input[k].value() ^ stream(key, nonce, counter, k as int))
    }
{
    for j in 0..m
        invariant output.len() == input.len()
        invariant forall k in 0..p + j {
            output.view()[k as int].value() == (input[k].value() ^ stream(key, nonce, counter, k as int))
        }
    {
        stream_at(key, nonce, counter, p, j, values(w));
        output[p + j] = input[p + j] ^ stream_byte(w, j);
    }
}

/// `input` XOR the ChaCha20 key stream (RFC 8439, 2.4) of `key` and `nonce` from block `counter`, into
/// `output`.
@constant_time
pub fn chacha20(key: [Secret<u8>; 32], nonce: [u8; 12], counter: u32, input: []Secret<u8>, output: []mut Secret<u8>)
    requires output.len() == input.len()
    ensures output.len() == input.len()
    ensures forall k in 0..input.len() {
        output.view()[k as int].value() == (input[k].value() ^ stream(key, nonce, counter, k as int))
    }
{
    let n = input.len();
    let mut p: usize = 0;
    while p < n
        invariant p <= n && (p % 64 == 0 || p == n) && output.len() == input.len()
        invariant forall k in 0..p {
            output.view()[k as int].value() == (input[k].value() ^ stream(key, nonce, counter, k as int))
        }
    {
        let w = block_ct(key, counter.wrapping_add((p / 64) as u32), nonce);
        let m = if n - p < 64 {
            n - p
        } else {
            64
        };
        xor_block(key, nonce, counter, input, output, p, m, w);
        p += m;
    }
}
