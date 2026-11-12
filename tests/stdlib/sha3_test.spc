// std::crypto::sha3 against FIPS 202's SHA3-256 of the empty message and of "abc" (NIST's examples) and
// against digests and SHAKE outputs at each rate boundary (a reference implementation made them): a
// message of a block's length less one, a block, a block and one, and outputs past one block.
import std::crypto::secret as *;
import std::crypto::sha3;

// Bytes `i * 7 + 1` modulo 256 for `i` in `0..n`.
fn ramp(n: usize) Vector<Secret<u8>> {
    let mut v = Vector::<Secret<u8>>::with_capacity(n);
    for i in 0..n {
        v.push(Secret::new((i * 7 + 1) as u8));
    }
    return v;
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

// The SHA3-256 digest of `m` as hex.
fn hex256(m: []Secret<u8>) String {
    let d = sha3::sha3_256(m);
    let mut v = Vector::<Secret<u8>>::with_capacity(32);
    for x in d {
        v.push(x);
    }
    return hex(&v);
}

// The SHA3-512 digest of `m` as hex.
fn hex512(m: []Secret<u8>) String {
    let d = sha3::sha3_512(m);
    let mut v = Vector::<Secret<u8>>::with_capacity(64);
    for x in d {
        v.push(x);
    }
    return hex(&v);
}

@test
fn fips_examples() {
    let mut abc = Vector::<Secret<u8>>::new();
    for c in [0x61u8, 0x62, 0x63] {
        abc.push(Secret::new(c));
    }
    assert_eq(hex256(ramp(0).as_slice()).as_str(), "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a");
    assert_eq(hex256(&abc).as_str(), "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532");
}

@test
fn sha3_256_rate_boundaries() {
    let cases: [(usize, str); 6] = [
        (0, "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a"),
        (3, "87006fc41b38735b9f02c804367b5db7528b5a28004fe212cbc92fa817b2d2b1"),
        (135, "64ccd300c1cf3d3846046bd588a1613e5ba619c09d45d4b7cc9afa093af29e19"),
        (136, "f106d1024a855c6a20d300bb53ec5472a1bae126fa630fee78219b51add7d768"),
        (137, "fa4d0b0141ec2c69a5dc314ed611a0819b920e95d13d586df89f370809e9465a"),
        (200, "1bea1a85c82f141d118988be6f7a7c0875a45c1a9820f2e1d7797061d2b3d86a"),
    ];
    for (n, want) in cases {
        assert_eq(hex256(ramp(n).as_slice()).as_str(), want);
    }
}

@test
fn sha3_512_rate_boundaries() {
    let cases: [(usize, str); 4] = [
        (
            0,
            "a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26"
        ),
        (
            71,
            "9e4dee6367de5a2369552f7bc5984aa66c4ddec980d907592834fc194af9cc9965bcb79292faeedcc93471ecc5b3d33983beb5549e29126074ffccc59af809b8"
        ),
        (
            72,
            "574f819c848e9d6f492f03847055180317740ce2f8473374e9c59255d9e2f5fc456eef18ed169f36b74e82a03e4164694c102389c0781483838c8840890c429e"
        ),
        (
            73,
            "96836c50a2d824ff0eb228e5060e0b88efd30e10b366347e95ace6909bda65b23fa8d268ecf88ad5e53cc3492280389200015556d8c2ee3e3fbaa5bce3db678b"
        ),
    ];
    for (n, want) in cases {
        assert_eq(hex512(ramp(n).as_slice()).as_str(), want);
    }
}

// SHAKE outputs of every length up to two blocks and one byte: each is a prefix of the longest.
@test
fn shake_outputs() {
    let s128 = "f556a4f5ec6d8c971f1d0ca3c0dc1a33f4c2878b8c54d313560a66be26b6266f49f448fb3b4239daa1093e07fae4f400c48710b1a9069d0508871fb14dd91a284f8133a401d9724d24f06ef8294a093f9f1c50330c5ee2c9f72f729d7193b86fc4e12f96bcdabac6bf4daf93bfa2aa83a02ac8dbafc1ee17d22d3bb3e8b5ea11d1ffc10ef8beef9ac0405eaf7a95f88ff5b3466541722496675b1e5ca3af8d2855726d7ad7b88e6b695dbb44247b397f0868fbae83770a591e2129b2d93082729ca2e8c30c7aec9356f329f287f9e2932de9929cd3f82e1d693433ba0b8dcac6f5490421f929d0f7da9bd950585b23218345f23c2bf20d3f31c471f072b9a7d49927af1f4ea57f255a38915d8aeab3f26fb1f59abd2bfc752272186b720761681169471b87be663649fef9db3c0318a3edcd78cd1a8cb432ac8e8aa7755374ea053336bf23db0ad08835e98aa7bad9ec9d";
    let s256 = "982c21d1d328ea0c182357958a9f776ca6a1811bf0f2c64b14262edef5d201c681a1883aa04988575f429adbb00859983e8f07e2047d6dd591730e57e1529c0059f730156461f589b23a15659b3be18b58ae6ad9e7e99a3efa44a7994e7be3987447eeaee2726cdd13cef483eb4a9d5a5967ea7d06d2aa59f5ec885f1fab2bd28fed5ffd7d02a741a498b294b3c1f5cbac2f8accdca46dba5531eeceebda6d686313faf8b3c15cde43e543e9a9fd88f6cc1908083128c345fbaa05e7e4c53a2acdb0688fac6e51261cca84df52e20faa8261b8d9043ddfedd22058bcb45e6d2b63cbf6b91c3c7e5107bda571febf35684db84524dd4b7e4d388f3fbb10a188f42c5c54442f872ef662d0ffd23cf7243782";
    let m128 = ramp(167);
    let m256 = ramp(136);
    for n in [0usize, 1, 167, 168, 169, 337] {
        let mut out = ramp(n);
        sha3::shake128(&m128, &mut out);
        assert_eq(hex(&out).as_str(), s128.slice(0, 2 * n));
    }
    for n in [0usize, 1, 135, 136, 137, 273] {
        let mut out = ramp(n);
        sha3::shake256(&m256, &mut out);
        assert_eq(hex(&out).as_str(), s256.slice(0, 2 * n));
    }
}
