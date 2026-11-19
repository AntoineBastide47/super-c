// std::crypto::sha512 against the digests of FIPS 180-4's examples (NIST's "Example Algorithms") and of
// messages at each padding boundary: 111 bytes leave room for the 16 length bytes in the last block, 112
// do not, 128 fill a block. Each digest twice: `sha512` with the processor's SHA-512 instructions where the
// host has them (arm64 FEAT_SHA512, x86-64 SHA512), and `sha512_portable` without.
import std::crypto::secret as *;
import std::crypto::sha512 as *;

// The digest of `msg` as lowercase hex, by `sha512_portable` when `portable`.
fn hex_of(msg: []u8, portable: bool) String {
    let mut v = Vector::<Secret<u8>>::with_capacity(msg.len());
    for b in msg {
        v.push(Secret::new(b));
    }
    let d = if portable {
        sha512_portable(&v)
    } else {
        sha512(&v)
    };
    let digits = "0123456789abcdef";
    let mut s = String::new();
    for i in 0usize..64 {
        let b = d[i].declassify();
        s.push_byte(digits.byte_at((b >> 4) as usize));
        s.push_byte(digits.byte_at((b & 15) as usize));
    }
    return s;
}

// The digest of `msg` as lowercase hex, by both paths, which agree.
fn hex_digest(msg: []u8) String {
    let h = hex_of(msg, false);
    assert_eq(h.as_str(), hex_of(msg, true).as_str());
    return h;
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
        "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e",
    );
    assert_eq(
        hex_digest(bytes("abc").as_slice()).as_str(),
        "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
    );
    assert_eq(
        hex_digest(
            bytes(
                "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
            ).as_slice(),
        ).as_str(),
        "8e959b75dae313da8cf4f72814fc143f8f7779c6eb9f7fa17299aeadb6889018501d289e4900f7e4331b99dec4b5433ac7d329eeb6dd26545e96e55b874be909",
    );
    assert_eq(
        hex_digest(bytes("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq").as_slice()).as_str(),
        "204a8fc6dda82f0a0ced7beb8e08a41657c16ef468b228a8279be331a703c33596fd15c13b1b07f9aa1d3bea57789ca031ad85c7a71dd70354ec631238ca3445",
    );
}

@test
fn one_million_a() {
    let mut v = Vector::<u8>::with_capacity(1000000);
    for _i in 0..1000000 {
        v.push(0x61);
    }
    assert_eq(
        hex_digest(&v).as_str(),
        "e718483d0ce769644e2e42c7bc15b4638e1f98b13b2044285632a803afa973ebde0ff244877ea60a4cb0432ce577c31beb009c5c2c49aa2e4eadb217ad8cc09b",
    );
}

@test
fn padding_boundaries() {
    assert_eq(
        hex_digest(ramp(111).as_slice()).as_str(),
        "3dfde1184fd99f233f98be4250f4edb9b535157909b668334370742204d97e047f1fd6a74bb5ba447f337286f421d9af957811f7ef62a458771457da126cb65e",
    );
    assert_eq(
        hex_digest(ramp(112).as_slice()).as_str(),
        "acc96c509e6d01787330a4c6a241e2cda9dcc2529dbe4288dbbcc3812133233c4698831127cf6ed0b333632b22715a5ce53a0a1002a684367b71c98aa6d1d900",
    );
    assert_eq(
        hex_digest(ramp(127).as_slice()).as_str(),
        "a315910cb7812a8e66d87c0c49a42d93dbe97bf0240ee995792292c529256d93f40199a59b3f6266343f302651fea1589e2040a2f3756126d3fe4f421a72079d",
    );
    assert_eq(
        hex_digest(ramp(128).as_slice()).as_str(),
        "31f33a52b36dc2e70c83b604fa999a5cabf33bf70e4556fbed7bff10870c1b7b241dd3f15d1ade24599f068fc58ab51e0028b0f0c98895c23358e8dee032ce06",
    );
    assert_eq(
        hex_digest(ramp(239).as_slice()).as_str(),
        "d5e023834c68aeb6e8eef9619ed5fb6fd8b3df796b49d18dce5f6fae76f3f6cae8ddf055611c4031bf5fe6aa68708360f5de1fe69a77055eb55612c5509d5e19",
    );
    assert_eq(
        hex_digest(ramp(240).as_slice()).as_str(),
        "67b19552bd96d84b251b262b7eef6fe73b2fdeabc4a4a0e4de2c8c621ee395729b3877c85c2b0fa79e379ca718f1a00d7508d8a5c04967fe240d4608edf05c10",
    );
    assert_eq(
        hex_digest(ramp(255).as_slice()).as_str(),
        "3e09a61576e14ea6d37a82b9463a1731f1de024664c4386d6a645ae40ad8b9be8d737a166ef08a1ae36f95c0179bcbcf441c45aa0509ce04740fffac9724dc35",
    );
    assert_eq(
        hex_digest(ramp(256).as_slice()).as_str(),
        "736e6ce54295f07fa411029e1b610c4a86659552c394165c7ddc2ba622630f26f898ec8f47db21051773b1ec17b3f63ff4c5f6cf95ddfd68581daed51ff4242b",
    );
}

// Both paths agree on every length up to five blocks and on longer messages, of bytes that differ.
@test
fn hardware_and_portable_paths_agree() {
    let mut x: u64 = 0x9E3779B97F4A7C15;
    let mut msg = Vector::<u8>::with_capacity(2200);
    for n in 0usize..2200 {
        if n <= 640 || n % 97 == 0 {
            let _ = hex_digest(&msg);
        }
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        msg.push(x as u8);
    }
}
