// std::crypto::chacha20, poly1305 and chacha20poly1305 against RFC 8439's test vectors (2.4.2, 2.5.2, 2.8.2
// and the Poly1305 edge cases of appendix A.3), and against vectors at each block and padding boundary
// (a reference implementation made them).
import std::crypto::secret as *;
import std::crypto::chacha20;
import std::crypto::poly1305;
import std::crypto::chacha20poly1305 as aead;

// The bytes that hex text `h` spells.
fn unhex(h: str) Vector<Secret<u8>> {
    let mut v = Vector::<Secret<u8>>::with_capacity(h.len() / 2);
    for i in 0..h.len() / 2 {
        let hi = h.byte_at(2 * i);
        let lo = h.byte_at(2 * i + 1);
        let d = |c: u8| if c <= b'9' {
            c - b'0'
        } else {
            c - b'a' + 10
        };
        v.push(Secret::new(d(hi) << 4 | d(lo)));
    }
    return v;
}

// Tag `t` as lowercase hex.
fn hex_tag(t: [Secret<u8>; 16]) String {
    let mut v = Vector::<Secret<u8>>::with_capacity(16);
    for x in t {
        v.push(x);
    }
    return hex(&v);
}

// `b` as lowercase hex.
fn hex(b: []Secret<u8>) String {
    let digits = "0123456789abcdef";
    let mut s = String::new();
    for x in b {
        let v = x.declassify();
        s.push_byte(digits.byte_at((v >> 4) as usize));
        s.push_byte(digits.byte_at((v & 15) as usize));
    }
    return s;
}

// The 32-byte key that hex text `h` spells.
fn key32(h: str) [Secret<u8>; 32] {
    let v = unhex(h);
    let mut k = [Secret::new(0u8); 32];
    for i in 0usize..32 {
        k[i] = v[i];
    }
    return k;
}

// The bytes of `text`.
fn bytes(text: str) Vector<Secret<u8>> {
    let mut v = Vector::<Secret<u8>>::with_capacity(text.len());
    for i in 0..text.len() {
        v.push(Secret::new(text.byte_at(i)));
    }
    return v;
}

// Bytes `i * b + a` modulo 256 for `i` in `0..n`.
fn ramp(n: usize, a: usize, b: usize) Vector<Secret<u8>> {
    let mut v = Vector::<Secret<u8>>::with_capacity(n);
    for i in 0..n {
        v.push(Secret::new((i * b + a) as u8));
    }
    return v;
}

// The bytes of `b`.
fn copy_of(b: []Secret<u8>) Vector<Secret<u8>> {
    let mut v = Vector::<Secret<u8>>::with_capacity(b.len());
    for x in b {
        v.push(x);
    }
    return v;
}

// `n` zero bytes.
fn zeros(n: usize) Vector<Secret<u8>> {
    return ramp(n, 0, 0);
}

const SUNSCREEN: str = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
const KEY_RAMP: str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

// ChaCha20 of `input` with `key` (hex), nonce `nonce` and counter `counter`.
fn chacha(key: str, nonce: [u8; 12], counter: u32, input: []Secret<u8>) String {
    let mut out = zeros(input.len());
    if out.len() == input.len() {
        chacha20::chacha20(key32(key), nonce, counter, input, &mut out);
    }
    return hex(&out);
}

@test
fn chacha20_rfc() {
    assert_eq(
        chacha(KEY_RAMP, [0, 0, 0, 0, 0, 0, 0, 0x4a, 0, 0, 0, 0], 1, bytes(SUNSCREEN).as_slice()).as_str(),
        "6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0bf91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d807ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab77937365af90bbf74a35be6b40b8eedf2785e42874d",
    );
}

@test
fn chacha20_block_boundaries() {
    let nonce: [u8; 12] = [0, 0, 0, 9, 0, 0, 0, 0x4a, 0, 0, 0, 0];
    let s129 = "11f9e8f2cc1f7227694f9a51f67c12aeb6a98b41be54f3a1ad921d240618bf94336a8bb0fa9ba11b0de2f02becb741e8e44ac3b7b362353b4240147607fc8ff4cb404ca1e43354bc01ccabbeff379afcac6efcd2e761469fcccf32e18fa20c7246895724e83d0f5466c180729dc14c964deae501ab611d4212569d6929eadc415d";
    for n in [0usize, 1, 63, 64, 65, 129] {
        assert_eq(chacha(KEY_RAMP, nonce, 1, ramp(n, 1, 7).as_slice()).as_str(), s129.slice(0, 2 * n));
    }
}

// The Poly1305 tag of `m` under `key` (hex), as hex.
fn mac(key: str, m: []Secret<u8>) String {
    return hex_tag(poly1305::poly1305(key32(key), m));
}

@test
fn poly1305_rfc() {
    assert_eq(
        mac(
            "85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b",
            bytes("Cryptographic Forum Research Group").as_slice(),
        ).as_str(),
        "a8061dc1305136c6c22b8baf0c0127a9",
    );
    // Appendix A.3, test vector 1: a zero key.
    assert_eq(
        mac("0000000000000000000000000000000000000000000000000000000000000000", zeros(64).as_slice()).as_str(),
        "00000000000000000000000000000000",
    );
    assert_eq(mac(KEY_RAMP, zeros(0).as_slice()).as_str(), "101112131415161718191a1b1c1d1e1f");
    assert_eq(mac(KEY_RAMP, ramp(17, 100, 1).as_slice()).as_str(), "daadd9e6f7bf92742a4a4a928aac9208");
}

// Appendix A.3, test vectors 5 to 9: sums near and past p and 2^130, which the reduction must carry.
@test
fn poly1305_reduction_edges() {
    let r2 = "0200000000000000000000000000000000000000000000000000000000000000";
    let r1 = "0100000000000000000000000000000000000000000000000000000000000000";
    assert_eq(
        mac(r2, unhex("ffffffffffffffffffffffffffffffff").as_slice()).as_str(),
        "03000000000000000000000000000000",
    );
    assert_eq(
        mac(
            "02000000000000000000000000000000ffffffffffffffffffffffffffffffff",
            unhex("02000000000000000000000000000000").as_slice(),
        ).as_str(),
        "03000000000000000000000000000000",
    );
    assert_eq(
        mac(
            r1,
            unhex("fffffffffffffffffffffffffffffffff0ffffffffffffffffffffffffffffff11000000000000000000000000000000").as_slice(),
        ).as_str(),
        "05000000000000000000000000000000",
    );
    assert_eq(
        mac(
            r1,
            unhex("fffffffffffffffffffffffffffffffffbfefefefefefefefefefefefefefefe01010101010101010101010101010101").as_slice(),
        ).as_str(),
        "00000000000000000000000000000000",
    );
    assert_eq(
        mac(r2, unhex("fdffffffffffffffffffffffffffffff").as_slice()).as_str(),
        "faffffffffffffffffffffffffffffff",
    );
}

// Seals `pt` with `aad`: the ciphertext and the tag, as hex; then opens them and checks the plaintext.
fn seal_open(key: [Secret<u8>; 32], nonce: [u8; 12], aad: []Secret<u8>, pt: []Secret<u8>) (String, String) {
    let mut ct = zeros(pt.len());
    let mut back = zeros(pt.len());
    if ct.len() != pt.len() || back.len() != pt.len() {
        return (String::new(), String::new());
    }
    let t = aead::seal(key, nonce, aad, pt, &mut ct);
    assert(aead::open(key, nonce, aad, &ct, t, &mut back), "open rejected its own tag");
    assert_eq(hex(&back).as_str(), hex(pt).as_str());
    return (hex(&ct), hex_tag(t));
}

@test
fn aead_rfc() {
    let (ct, t) = seal_open(
        key32("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"),
        [7, 0, 0, 0, 0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47],
        unhex("50515253c0c1c2c3c4c5c6c7").as_slice(),
        bytes(SUNSCREEN).as_slice(),
    );
    assert_eq(
        ct.as_str(),
        "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116",
    );
    assert_eq(t.as_str(), "1ae10b594f09e26a7e902ecbd0600691");
}

// Data and plaintext lengths at the 16-byte padding and the 64-byte block boundaries.
@test
fn aead_padding_boundaries() {
    let key = key32(KEY_RAMP);
    let nonce: [u8; 12] = [0, 0, 0, 9, 0, 0, 0, 0x4a, 0, 0, 0, 0];
    let s65 = "11f9e8f2cc1f7227694f9a51f67c12aeb6a98b41be54f3a1ad921d240618bf94336a8bb0fa9ba11b0de2f02becb741e8e44ac3b7b362353b4240147607fc8ff4cb";
    let cases: [(usize, usize, str); 5] = [
        (0, 0, "8e62f3b3c9fdbfce61fa1a01cbd7e08b"),
        (0, 1, "94fb063b0dfafb2265716e90526adfd7"),
        (17, 16, "5b015307c85cfe0cfcd7273867baa8c1"),
        (16, 64, "729c6c4b3645f3872df55142be5918f9"),
        (1, 65, "7e7eb87fc14a5cd39867ff0ed48c4357"),
    ];
    for (na, np, tag) in cases {
        let (ct, t) = seal_open(key, nonce, ramp(na, 3, 5).as_slice(), ramp(np, 1, 7).as_slice());
        assert_eq(ct.as_str(), s65.slice(0, 2 * np));
        assert_eq(t.as_str(), tag);
    }
}

// A changed tag, ciphertext or data: `open` rejects it and leaves the output as it was.
@test
fn aead_rejects_forgeries() {
    let key = key32(KEY_RAMP);
    let nonce: [u8; 12] = [0, 0, 0, 9, 0, 0, 0, 0x4a, 0, 0, 0, 0];
    let aad = ramp(17, 3, 5);
    let pt = ramp(65, 1, 7);
    let mut ct = zeros(65);
    let mut out = ramp(65, 9, 0);
    if ct.len() != pt.len() || out.len() != pt.len() {
        panic("lengths");
    }
    let t = aead::seal(key, nonce, &aad, &pt, &mut ct);
    let mut bad_tag = t;
    bad_tag[15] = bad_tag[15] ^ Secret::new(0x80u8);
    assert(!aead::open(key, nonce, &aad, &ct, bad_tag, &mut out), "a changed tag passed");
    let mut bad_ct = copy_of(&ct);
    bad_ct[64] = bad_ct[64] ^ Secret::new(1u8);
    if bad_ct.len() != out.len() {
        panic("lengths");
    }
    assert(!aead::open(key, nonce, &aad, &bad_ct, t, &mut out), "a changed ciphertext passed");
    let mut bad_aad = copy_of(&aad);
    bad_aad[0] = bad_aad[0] ^ Secret::new(1u8);
    assert(!aead::open(key, nonce, &bad_aad, &ct, t, &mut out), "changed data passed");
    assert_eq(hex(&out).as_str(), hex(ramp(65, 9, 0).as_slice()).as_str());
}
