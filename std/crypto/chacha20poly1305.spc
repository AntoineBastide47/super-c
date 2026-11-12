// ChaCha20-Poly1305 (RFC 8439, 2.8), proved: `seal` encrypts with `std::crypto::chacha20` and returns the
// Poly1305 tag of the additional data and the ciphertext; `open` checks a tag and decrypts. Both state what
// they compute against the RFC's definitions, and both run in constant time on the key, the data and the
// tag: only the lengths and the nonce pick a branch or an index. A nonce encrypts one message under a key.
// Import with `import std::crypto::chacha20poly1305;`.

import std::crypto::secret as *;
import std::crypto::chacha20;
import std::crypto::poly1305;
import std::spec::seq as *;

/// The one-time Poly1305 key of `key` and `nonce` (2.6): the first 32 bytes of ChaCha20 block 0.
pub spec fn one_time_key(key: [Secret<u8>; 32], nonce: [u8; 12]) [u8; 32] {
    return [
        chacha20::byte_of(chacha20::block(key, 0, nonce), 0),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 1),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 2),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 3),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 4),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 5),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 6),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 7),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 8),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 9),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 10),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 11),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 12),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 13),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 14),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 15),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 16),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 17),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 18),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 19),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 20),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 21),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 22),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 23),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 24),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 25),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 26),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 27),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 28),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 29),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 30),
        chacha20::byte_of(chacha20::block(key, 0, nonce), 31),
    ];
}

/// The tag (2.8) of `aad` and ciphertext `ct` under `key` and `nonce`, as a number (`tag_of`).
pub spec fn tag(key: [Secret<u8>; 32], nonce: [u8; 12], aad: Seq<Secret<u8>>, ct: Seq<Secret<u8>>) int {
    return tag_of(one_time_key(key, nonce), aad, ct);
}

/// The tag of `aad` and `ct` with one-time key `k`, as a number: Poly1305 on `aad` and `ct`, each padded
/// with zeros to 16 bytes, then their lengths as two 64-bit little-endian numbers.
pub spec fn tag_of(k: [u8; 32], aad: Seq<Secret<u8>>, ct: Seq<Secret<u8>>) int {
    let r = poly1305::r_of(k);
    let a1 = poly1305::acc(r, aad, (aad.len() as int + 15) / 16, true, 0);
    let a2 = poly1305::acc(r, ct, (ct.len() as int + 15) / 16, true, a1);
    let a3 = (a2 + aad.len() as int + ct.len() as int * 0x10000000000000000 + 0x100000000000000000000000000000000) * r % poly1305::p();
    return (a3 + poly1305::s_of(k)) % 0x100000000000000000000000000000000;
}

// The one-time key (`one_time_key`).
@constant_time
fn one_time_key_ct(key: [Secret<u8>; 32], nonce: [u8; 12]) [Secret<u8>; 32]
    ensures |k| poly1305::key_values(k) == one_time_key(key, nonce)
{
    let w = chacha20::block_ct(key, 0, nonce);
    return [
        chacha20::stream_byte(w, 0),
        chacha20::stream_byte(w, 1),
        chacha20::stream_byte(w, 2),
        chacha20::stream_byte(w, 3),
        chacha20::stream_byte(w, 4),
        chacha20::stream_byte(w, 5),
        chacha20::stream_byte(w, 6),
        chacha20::stream_byte(w, 7),
        chacha20::stream_byte(w, 8),
        chacha20::stream_byte(w, 9),
        chacha20::stream_byte(w, 10),
        chacha20::stream_byte(w, 11),
        chacha20::stream_byte(w, 12),
        chacha20::stream_byte(w, 13),
        chacha20::stream_byte(w, 14),
        chacha20::stream_byte(w, 15),
        chacha20::stream_byte(w, 16),
        chacha20::stream_byte(w, 17),
        chacha20::stream_byte(w, 18),
        chacha20::stream_byte(w, 19),
        chacha20::stream_byte(w, 20),
        chacha20::stream_byte(w, 21),
        chacha20::stream_byte(w, 22),
        chacha20::stream_byte(w, 23),
        chacha20::stream_byte(w, 24),
        chacha20::stream_byte(w, 25),
        chacha20::stream_byte(w, 26),
        chacha20::stream_byte(w, 27),
        chacha20::stream_byte(w, 28),
        chacha20::stream_byte(w, 29),
        chacha20::stream_byte(w, 30),
        chacha20::stream_byte(w, 31),
    ];
}

// The tag of `aad` and `ct` with one-time key `k` (`tag_of`).
@constant_time
fn tag_ct(k: [Secret<u8>; 32], aad: []Secret<u8>, ct: []Secret<u8>) [Secret<u8>; 16]
    ensures |t| poly1305::tag_value(t) == tag_of(poly1305::key_values(k), aad.view(), ct.view())
{
    let z = Secret::new(0u64);
    let zero = [z, z, z, z, z];
    ghost let rk = poly1305::r_of(poly1305::key_values(k));
    let r = poly1305::load_r(k);
    assert poly1305::val(zero) % poly1305::p() == 0 by {};
    let h1 = poly1305::absorb(r, aad, true, zero);
    ghost let a1 = poly1305::acc(rk, aad.view(), (aad.view().len() as int + 15) / 16, true, 0);
    assert poly1305::val(h1) % poly1305::p() == a1 by {};
    let h2 = poly1305::absorb(r, ct, true, h1);
    ghost let a2 = poly1305::acc(rk, ct.view(), (ct.view().len() as int + 15) / 16, true, a1);
    assert poly1305::val(h2) % poly1305::p() == a2 by {};
    let h3 = poly1305::absorb_lengths(r, h2, aad.len() as u64, ct.len() as u64);
    ghost let l = aad.view().len() as int + ct.view().len() as int * 0x10000000000000000 + 0x100000000000000000000000000000000;
    poly1305::mul_mod_eq(
        poly1305::val(h2) % poly1305::p(),
        a2,
        (aad.len() as u64) as int + (ct.len() as u64) as int * 0x10000000000000000 + 0x100000000000000000000000000000000,
        l,
        poly1305::val(r),
        rk,
    );
    ghost let a3 = (a2 + l) * rk % poly1305::p();
    let t = poly1305::finish(poly1305::reduce(h3), k);
    assert poly1305::tag_value(t) == (a3 + poly1305::s_of(poly1305::key_values(k))) % 0x100000000000000000000000000000000 by {};
    return t;
}

/// Encrypts `plaintext` into `ciphertext` under `key` and `nonce`, and returns the tag of `aad` and the
/// ciphertext (RFC 8439, 2.8).
@constant_time
pub fn seal(
    key: [Secret<u8>; 32],
    nonce: [u8; 12],
    aad: []Secret<u8>,
    plaintext: []Secret<u8>,
    ciphertext: []mut Secret<u8>,
) [Secret<u8>; 16]
    requires ciphertext.len() == plaintext.len()
    ensures ciphertext.len() == plaintext.len()
    ensures forall k in 0..plaintext.len() {
        ciphertext.view()[k as int].value() == (plaintext[k].value() ^ chacha20::stream(key, nonce, 1, k as int))
    }
    ensures |t| poly1305::tag_value(t) == tag(key, nonce, aad.view(), ciphertext.view())
{
    let k = one_time_key_ct(key, nonce);
    chacha20::chacha20(key, nonce, 1, plaintext, ciphertext);
    let t = tag_ct(k, aad, ciphertext.as_slice());
    assert poly1305::tag_value(t) == tag_of(one_time_key(key, nonce), aad.view(), ciphertext.view()) by {};
    return t;
}

// Tags of equal value have equal bytes.
lemma bytes_of_equal(a: [Secret<u8>; 16], b: [Secret<u8>; 16])
    ensures poly1305::tag_value(a) == poly1305::tag_value(b) ==> a[0].value() == b[0].value() && a[1].value() == b[1].value() && a[2].value() == b[2].value() && a[3].value() == b[3].value() && a[4].value() == b[4].value() && a[5].value() == b[5].value() && a[6].value() == b[6].value() && a[7].value() == b[7].value() && a[8].value() == b[8].value() && a[9].value() == b[9].value() && a[10].value() == b[10].value() && a[11].value() == b[11].value() && a[12].value() == b[12].value() && a[13].value() == b[13].value() && a[14].value() == b[14].value() && a[15].value() == b[15].value()
{}

// `d | (x ^ y)`: `d` where `x` equals `y`; 0 only where `x` equals `y`.
@constant_time
const fn differ(d: Secret<u8>, x: Secret<u8>, y: Secret<u8>) Secret<u8>
    ensures |o| o.value() >= d.value()
    ensures |o| o.value() == 0 ==> x.value() == y.value()
    ensures |o| x.value() == y.value() ==> o.value() == d.value()
{
    return d | x ^ y;
}

// Whether tags `a` and `b` are equal, in constant time.
@constant_time
fn tags_equal(a: [Secret<u8>; 16], b: [Secret<u8>; 16]) Secret<bool>
    ensures |e| e.value() ==> poly1305::tag_value(a) == poly1305::tag_value(b)
    ensures |e| poly1305::tag_value(a) == poly1305::tag_value(b) ==> e.value()
{
    let d0 = Secret::new(0u8);
    let d1 = differ(d0, a[0], b[0]);
    let d2 = differ(d1, a[1], b[1]);
    let d3 = differ(d2, a[2], b[2]);
    let d4 = differ(d3, a[3], b[3]);
    let d5 = differ(d4, a[4], b[4]);
    let d6 = differ(d5, a[5], b[5]);
    let d7 = differ(d6, a[6], b[6]);
    let d8 = differ(d7, a[7], b[7]);
    let d9 = differ(d8, a[8], b[8]);
    let d10 = differ(d9, a[9], b[9]);
    let d11 = differ(d10, a[10], b[10]);
    let d12 = differ(d11, a[11], b[11]);
    let d13 = differ(d12, a[12], b[12]);
    let d14 = differ(d13, a[13], b[13]);
    let d15 = differ(d14, a[14], b[14]);
    let d16 = differ(d15, a[15], b[15]);
    bytes_of_equal(a, b);
    return d16.eq(Secret::new(0u8));
}

/// Checks `expected` against the tag of `aad` and `ciphertext` under `key` and `nonce` (RFC 8439, 2.8)
/// and, where it matches, decrypts `ciphertext` into `plaintext`; where it does not, `plaintext` stays as
/// it was. Whether it matched.
@constant_time
pub fn open(
    key: [Secret<u8>; 32],
    nonce: [u8; 12],
    aad: []Secret<u8>,
    ciphertext: []Secret<u8>,
    expected: [Secret<u8>; 16],
    plaintext: []mut Secret<u8>,
) bool
    requires plaintext.len() == ciphertext.len()
    ensures plaintext.len() == ciphertext.len()
    ensures |ok| ok == (poly1305::tag_value(expected) == tag(key, nonce, aad.view(), ciphertext.view()))
    ensures |ok| ok ==> forall k in 0..ciphertext.len() {
        plaintext.view()[k as int].value() == (ciphertext[k].value() ^ chacha20::stream(key, nonce, 1, k as int))
    }
    ensures |ok| !ok ==> plaintext.view() == old(plaintext.view())
{
    let k = one_time_key_ct(key, nonce);
    let t = tag_ct(k, aad, ciphertext);
    assert poly1305::tag_value(t) == tag(key, nonce, aad.view(), ciphertext.view()) by {};
    let ok = tags_equal(t, expected).declassify();
    if ok {
        chacha20::chacha20(key, nonce, 1, ciphertext, plaintext);
    }
    return ok;
}
