// std::crypto::x25519 against RFC 7748's test vectors (5.2: the two scalar multiples and the iterated
// function after 1 and 1000 steps; 6.1: the Diffie-Hellman keys and shared secret), and against a
// reference implementation for a u-coordinate past p, one with bit 255 set, and 0.
import std::crypto::secret as *;
import std::crypto::x25519;

// The 32 bytes that hex text `h` spells.
fn unhex(h: str) [Secret<u8>; 32] {
    let mut v = [Secret::new(0u8); 32];
    for i in 0usize..32 {
        let d = |c: u8| if c <= b'9' {
            c - b'0'
        } else {
            c - b'a' + 10
        };
        v[i] = Secret::new(d(h.byte_at(2 * i)) << 4 | d(h.byte_at(2 * i + 1)));
    }
    return v;
}

// `b` as lowercase hex.
fn hex(b: [Secret<u8>; 32]) String {
    let digits = "0123456789abcdef";
    let mut s = String::new();
    for x in b {
        let v = x.declassify();
        s.push_byte(digits.byte_at((v >> 4) as usize));
        s.push_byte(digits.byte_at((v & 15) as usize));
    }
    return s;
}

// X25519 of scalar `k` and u-coordinate `u` (hex), as hex.
fn x(k: str, u: str) String {
    return hex(x25519::x25519(unhex(k), unhex(u)));
}

@test
fn rfc_scalar_multiples() {
    assert_eq(
        x(
            "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4",
            "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c",
        ).as_str(),
        "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552",
    );
    assert_eq(
        x(
            "4b66e9d4d1b4673c5ad22691957d6af5c11b6421e0ea01d42ca4169e7918ba0d",
            "e5210f12786811d3f4b7959d0538ae2c31dbe7106fc03c3efc4cd549c715a493",
        ).as_str(),
        "95cbde9476e8907d7aade45cb4b873f88b595a68799fa152e6f8f7647aac7957",
    );
}

// RFC 7748, 5.2: k and u start at 9; each step sets k to X25519(k, u) and u to the old k.
@test
fn rfc_iterated() {
    let mut k = unhex("0900000000000000000000000000000000000000000000000000000000000000");
    let mut u = k;
    for i in 0usize..1000 {
        let r = x25519::x25519(k, u);
        u = k;
        k = r;
        if i == 0 {
            assert_eq(hex(k).as_str(), "422c8e7a6227d7bca1350b3e2bb7279f7897b87bb6854b783c60e80311ae3079");
        }
    }
    assert_eq(hex(k).as_str(), "684cf59ba83309552800ef566f2f4d3c1c3887c49360e3875f2eb94d99532c51");
}

@test
fn rfc_diffie_hellman() {
    let a = unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
    let b = unhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
    let pa = x25519::x25519_base(a);
    let pb = x25519::x25519_base(b);
    assert_eq(hex(pa).as_str(), "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a");
    assert_eq(hex(pb).as_str(), "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
    let shared = "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742";
    assert_eq(hex(x25519::x25519(a, pb)).as_str(), shared);
    assert_eq(hex(x25519::x25519(b, pa)).as_str(), shared);
}

// A u-coordinate of p + 5 is 5 (modulo p); bit 255 of the coordinate is cleared; 0 gives 0.
@test
fn coordinate_decoding() {
    let k = "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4";
    let five = "50e87fe55e186ff59bcfb758e02f341b4f62573826bb2d28ec182949a4e9cf1f";
    assert_eq(x(k, "0500000000000000000000000000000000000000000000000000000000000000").as_str(), five);
    assert_eq(x(k, "f2ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f").as_str(), five);
    assert_eq(x(k, "0500000000000000000000000000000000000000000000000000000000000080").as_str(), five);
    assert_eq(
        x(k, "0000000000000000000000000000000000000000000000000000000000000000").as_str(),
        "0000000000000000000000000000000000000000000000000000000000000000",
    );
}
