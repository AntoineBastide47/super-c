// std::crypto::sha256 against the digests of FIPS 180-4's examples (NIST's "Example Algorithms") and of
// messages at each padding boundary: 55 bytes leave room for the length in the last block, 56 do not, 64
// fill a block.
import std::crypto::secret as *;
import std::crypto::sha256 as *;

// The digest of `msg` as lowercase hex.
fn hex_digest(msg: []u8) String {
    let mut v = Vector::<Secret<u8>>::with_capacity(msg.len());
    for b in msg {
        v.push(Secret::new(b));
    }
    let d = sha256(&v);
    let digits = "0123456789abcdef";
    let mut s = String::new();
    for i in 0usize..32 {
        let b = d[i].declassify();
        s.push_byte(digits.byte_at((b >> 4) as usize));
        s.push_byte(digits.byte_at((b & 15) as usize));
    }
    return s;
}

// The bytes of `text`.
fn bytes(text: str) Vector<u8> {
    let mut v = Vector::<u8>::with_capacity(text.len());
    for i in 0..text.len() {
        v.push(text.byte_at(i));
    }
    return v;
}

// Bytes `i * 7 + 1` modulo 256 for `i` in `0..n`.
fn ramp(n: usize) Vector<u8> {
    let mut v = Vector::<u8>::with_capacity(n);
    for i in 0..n {
        v.push((i * 7 + 1) as u8);
    }
    return v;
}

@test
fn fips_examples() {
    assert_eq(
        hex_digest(bytes("").as_slice()).as_str(),
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    );
    assert_eq(
        hex_digest(bytes("abc").as_slice()).as_str(),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    );
    assert_eq(
        hex_digest(bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq").as_slice()).as_str(),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
    );
    assert_eq(
        hex_digest(
            bytes(
                "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
            ).as_slice(),
        ).as_str(),
        "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1",
    );
}

@test
fn one_million_a() {
    let mut v = Vector::<u8>::with_capacity(1000000);
    for _i in 0..1000000 {
        v.push(0x61);
    }
    assert_eq(hex_digest(&v).as_str(), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
}

@test
fn padding_boundaries() {
    assert_eq(
        hex_digest(ramp(55).as_slice()).as_str(),
        "16fa57a0a3423a715d594516339f36189d6b5f93754a9714fef202616a9fabfe",
    );
    assert_eq(
        hex_digest(ramp(56).as_slice()).as_str(),
        "c37b44e5f1b18554b36966f4f8e08bfbf3164c4b6c10374d12d89850892073c5",
    );
    assert_eq(
        hex_digest(ramp(63).as_slice()).as_str(),
        "bbba992d2c85af960fb2987a1fd05e0aa82a3db3c740dd8982a9e273b75e36a3",
    );
    assert_eq(
        hex_digest(ramp(64).as_slice()).as_str(),
        "66bd4633ed6f71c4ecfa4763bf7ba1c8ec7612de9aa6c0578a7b675207c71e0b",
    );
    assert_eq(
        hex_digest(ramp(119).as_slice()).as_str(),
        "a3ed307b730fa77c07531300c6e4a282330011d4d4caf6bb7b63ae05950f4b66",
    );
    assert_eq(
        hex_digest(ramp(120).as_slice()).as_str(),
        "8e3b15d9fea7472655aa069620b7f8c2e55ee1499f763200a7515fe826e99d20",
    );
}
