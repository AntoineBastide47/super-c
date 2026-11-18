// The scalar and cryptographic intrinsics of ffi/immintrin.spc (BMI1, BMI2, SHA, AES key expansion) and
// ffi/arm_neon.spc (PMULL, SHA-1) against scalar models of the vendors' pseudocode, run where the processor
// has the feature.
import std::cpu;
import std::cpu::detect as detect;
import immintrin;
import arm_neon;

const N: usize = 12;

const V: [u64; N] = [
    0,
    1,
    2,
    0x80,
    0xFF00,
    0x12345678,
    0x80000000,
    0xFFFFFFFF,
    0x100000000,
    0x8000000000000000,
    0xFFFFFFFFFFFFFFFF,
    0x0123456789ABCDEF,
];

// The bits of `a`, low first, put at the set bits of `m`.
@arch(x86_64)
fn pdep_model(a: u64, m: u64) u64 {
    let mut r: u64 = 0;
    let mut k: u64 = 0;
    for i in 0..64u64 {
        if (m >> i & 1) != 0 {
            r |= (a >> k & 1) << i;
            k += 1;
        }
    }
    return r;
}

// The bits of `a` at the set bits of `m`, packed low.
@arch(x86_64)
fn pext_model(a: u64, m: u64) u64 {
    let mut r: u64 = 0;
    let mut k: u64 = 0;
    for i in 0..64u64 {
        if (m >> i & 1) != 0 {
            r |= (a >> i & 1) << k;
            k += 1;
        }
    }
    return r;
}

// The low `n` bits of `a` (all of them from 64 on).
@arch(x86_64)
fn low_bits(a: u64, n: u64) u64 {
    return if n >= 64 {
        a
    } else {
        a & (1u64 << n) - 1
    };
}

@arch(x86_64)
@test
fn bmi_intrinsics_match_their_models() {
    if detect::has(cpu::Feature::Bmi1) && detect::has(cpu::Feature::Bmi2) {
        unsafe check_bmi();
    }
}

@arch(x86_64)
@target_feature([cpu::Feature::Bmi1, cpu::Feature::Bmi2])
fn check_bmi() {
    for i in 0..N {
        for j in 0..N {
            let a = V[i];
            let b = V[j].rotate_left(i as u32 * 5);
            let (a32, b32) = (a as u32, b as u32);
            assert_eq(immintrin::_andn_u64(a, b), ~a & b);
            assert_eq(immintrin::_andn_u32(a32, b32), ~a32 & b32);
            assert_eq(immintrin::_blsr_u64(a), a & a.wrapping_sub(1));
            assert_eq(immintrin::_blsi_u64(a), a & a.wrapping_neg());
            assert_eq(immintrin::_blsmsk_u64(a), a ^ a.wrapping_sub(1));
            assert_eq(immintrin::_blsr_u32(a32), a32 & a32.wrapping_sub(1));
            let start = b & 63;
            let len = b >> 8 & 63;
            assert_eq(immintrin::_bextr_u64(a, start as u32, len as u32), low_bits(a >> start, len));
            let n = b & 0x7F;
            assert_eq(immintrin::_bzhi_u64(a, n as u32), low_bits(a, n));
            assert_eq(immintrin::_bzhi_u32(a32, (n & 31) as u32), low_bits(a, n & 31) as u32);
            assert_eq(immintrin::_pdep_u64(a, b), pdep_model(a, b));
            assert_eq(immintrin::_pext_u64(a, b), pext_model(a, b));
            assert_eq(immintrin::_pdep_u32(a32, b32), pdep_model(a, b & 0xFFFFFFFF) as u32);
            assert_eq(immintrin::_pext_u32(a32, b32), pext_model(a & 0xFFFFFFFF, b & 0xFFFFFFFF) as u32);
        }
    }
}

// The carry-less product of `a` and `b`.
@arch(x86_64 | aarch64)
fn clmul(a: u64, b: u64) u128 {
    let mut r: u128 = 0;
    for i in 0..64usize {
        if (b >> i as u64 & 1) != 0 {
            r ^= a as u128 << i;
        }
    }
    return r;
}

// Four rounds of SHA-1 with the choice function (Arm's SHA1C pseudocode): `x` the state's words a to d,
// `y` its word e, `w` the round inputs plus constants.
@arch(aarch64)
fn sha1c_model(x0: [u32; 4], y0: u32, w: [u32; 4]) [u32; 4] {
    let mut x = x0;
    let mut y = y0;
    for e in 0..4usize {
        let t = x[1] & x[2] | ~x[1] & x[3];
        y = y.wrapping_add(x[0].rotate_left(5)).wrapping_add(t).wrapping_add(w[e]);
        x[1] = x[1].rotate_left(30);
        let top = x[3];
        x[3] = x[2];
        x[2] = x[1];
        x[1] = x[0];
        x[0] = y;
        y = top;
    }
    return x;
}

@arch(aarch64)
@test
fn pmull_and_sha1_intrinsics_match_their_models() {
    crypto_checks();
}

// Apple's baseline (the M1, the A7) has both features.
@arch(aarch64)
@platform(macos | ios)
fn crypto_checks() {
    check_pmull();
    check_sha1();
}

@arch(aarch64)
@platform(linux | windows | android)
fn crypto_checks() {
    if detect::has(cpu::Feature::Pmull) {
        unsafe check_pmull();
    }
    if detect::has(cpu::Feature::Sha2) {
        unsafe check_sha1();
    }
}

@arch(aarch64)
@target_feature([cpu::Feature::Pmull])
fn check_pmull() {
    for i in 0..N {
        for j in 0..N {
            let b = V[j].rotate_left(i as u32 * 7);
            assert_eq(arm_neon::vmull_p64(V[i], b), clmul(V[i], b));
        }
    }
}

@arch(aarch64)
@target_feature([cpu::Feature::Sha2])
fn check_sha1() {
    for i in 0..N {
        let x = (V[i] >> 13) as u32;
        assert_eq(arm_neon::vsha1h_u32(x), x.rotate_left(30));
    }
    let abcd: [u32; 4] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476];
    let w: [u32; 4] = [0x5A827999, 0x12345678, 0x9ABCDEF0, 0x0F1E2D3C];
    let mut out: [u32; 4] = [0; 4];
    unsafe {
        let r = arm_neon::vsha1cq_u32(arm_neon::vld1q_u32(&abcd[0]), 0xC3D2E1F0, arm_neon::vld1q_u32(&w[0]));
        arm_neon::vst1q_u32(&mut out[0], r);
    }
    let want = sha1c_model(abcd, 0xC3D2E1F0, w);
    for k in 0..4usize {
        assert_eq(out[k], want[k]);
    }
}

// Four 32-bit lanes through an xmm register, lane 0 lowest.
@arch(x86_64)
fn xmm(v: [u32; 4]) immintrin::__m128i {
    return immintrin::_mm_setr_epi32(v[0] as i32, v[1] as i32, v[2] as i32, v[3] as i32);
}

@arch(x86_64)
fn lanes_of(x: immintrin::__m128i) [u32; 4] {
    let mut o: [u32; 4] = [0; 4];
    unsafe immintrin::_mm_storeu_si128(((&mut o[0]) as *mut u32) as *mut immintrin::__m128i_u, x);
    return o;
}

// Two SHA-256 rounds (Intel's SHA256RNDS2): `cdgh` holds C, D, G, H in lanes 3 to 0, `abef` A, B, E, F,
// `wk` the rounds' words plus constants in lanes 0 and 1; the result A, B, E, F after them.
@arch(x86_64)
fn sha256rnds2_model(cdgh: [u32; 4], abef: [u32; 4], wk: [u32; 4]) [u32; 4] {
    let mut s: [u32; 8] = [abef[3], abef[2], cdgh[3], cdgh[2], abef[1], abef[0], cdgh[1], cdgh[0]];
    for r in 0..2usize {
        let (a, b, c, d, e, f, g, h) = (s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]);
        let ch = e & f ^ ~e & g;
        let maj = a & b ^ a & c ^ b & c;
        let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
        let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
        let t = ch.wrapping_add(s1).wrapping_add(wk[r]).wrapping_add(h);
        s = [t.wrapping_add(maj).wrapping_add(s0), a, b, c, t.wrapping_add(d), e, f, g];
    }
    return [s[5], s[4], s[1], s[0]];
}

// Four SHA-1 rounds (Intel's SHA1RNDS4) of function `f` (0 choice, 1 and 3 parity, 2 majority): `abcd`
// holds A..D in lanes 3 to 0, `w` W0 + E, W1, W2, W3 in lanes 3 to 0; the result A..D after them.
@arch(x86_64)
fn sha1rnds4_model(abcd: [u32; 4], w: [u32; 4], f: u32) [u32; 4] {
    let ks: [u32; 4] = [0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xCA62C1D6];
    let k = ks[f as usize];
    let (mut a, mut b, mut c, mut d, mut e) = (abcd[3], abcd[2], abcd[1], abcd[0], 0u32);
    let ws: [u32; 4] = [w[3], w[2], w[1], w[0]];
    for i in 0..4usize {
        let fv = if f == 0 {
            b & c ^ ~b & d
        } else if f == 2 {
            b & c ^ b & d ^ c & d
        } else {
            b ^ c ^ d
        };
        let na = fv.wrapping_add(a.rotate_left(5)).wrapping_add(ws[i]).wrapping_add(e).wrapping_add(k);
        e = d;
        d = c;
        c = b.rotate_left(30);
        b = a;
        a = na;
    }
    return [d, c, b, a];
}

@arch(x86_64)
fn sigma0(x: u32) u32 {
    return x.rotate_right(7) ^ x.rotate_right(18) ^ x >> 3;
}

@arch(x86_64)
fn sigma1(x: u32) u32 {
    return x.rotate_right(17) ^ x.rotate_right(19) ^ x >> 10;
}

// The AES S-box (FIPS 197, 5.1.1).
const SBOX: [u8; 256] = [
    0x63,
    0x7c,
    0x77,
    0x7b,
    0xf2,
    0x6b,
    0x6f,
    0xc5,
    0x30,
    0x01,
    0x67,
    0x2b,
    0xfe,
    0xd7,
    0xab,
    0x76,
    0xca,
    0x82,
    0xc9,
    0x7d,
    0xfa,
    0x59,
    0x47,
    0xf0,
    0xad,
    0xd4,
    0xa2,
    0xaf,
    0x9c,
    0xa4,
    0x72,
    0xc0,
    0xb7,
    0xfd,
    0x93,
    0x26,
    0x36,
    0x3f,
    0xf7,
    0xcc,
    0x34,
    0xa5,
    0xe5,
    0xf1,
    0x71,
    0xd8,
    0x31,
    0x15,
    0x04,
    0xc7,
    0x23,
    0xc3,
    0x18,
    0x96,
    0x05,
    0x9a,
    0x07,
    0x12,
    0x80,
    0xe2,
    0xeb,
    0x27,
    0xb2,
    0x75,
    0x09,
    0x83,
    0x2c,
    0x1a,
    0x1b,
    0x6e,
    0x5a,
    0xa0,
    0x52,
    0x3b,
    0xd6,
    0xb3,
    0x29,
    0xe3,
    0x2f,
    0x84,
    0x53,
    0xd1,
    0x00,
    0xed,
    0x20,
    0xfc,
    0xb1,
    0x5b,
    0x6a,
    0xcb,
    0xbe,
    0x39,
    0x4a,
    0x4c,
    0x58,
    0xcf,
    0xd0,
    0xef,
    0xaa,
    0xfb,
    0x43,
    0x4d,
    0x33,
    0x85,
    0x45,
    0xf9,
    0x02,
    0x7f,
    0x50,
    0x3c,
    0x9f,
    0xa8,
    0x51,
    0xa3,
    0x40,
    0x8f,
    0x92,
    0x9d,
    0x38,
    0xf5,
    0xbc,
    0xb6,
    0xda,
    0x21,
    0x10,
    0xff,
    0xf3,
    0xd2,
    0xcd,
    0x0c,
    0x13,
    0xec,
    0x5f,
    0x97,
    0x44,
    0x17,
    0xc4,
    0xa7,
    0x7e,
    0x3d,
    0x64,
    0x5d,
    0x19,
    0x73,
    0x60,
    0x81,
    0x4f,
    0xdc,
    0x22,
    0x2a,
    0x90,
    0x88,
    0x46,
    0xee,
    0xb8,
    0x14,
    0xde,
    0x5e,
    0x0b,
    0xdb,
    0xe0,
    0x32,
    0x3a,
    0x0a,
    0x49,
    0x06,
    0x24,
    0x5c,
    0xc2,
    0xd3,
    0xac,
    0x62,
    0x91,
    0x95,
    0xe4,
    0x79,
    0xe7,
    0xc8,
    0x37,
    0x6d,
    0x8d,
    0xd5,
    0x4e,
    0xa9,
    0x6c,
    0x56,
    0xf4,
    0xea,
    0x65,
    0x7a,
    0xae,
    0x08,
    0xba,
    0x78,
    0x25,
    0x2e,
    0x1c,
    0xa6,
    0xb4,
    0xc6,
    0xe8,
    0xdd,
    0x74,
    0x1f,
    0x4b,
    0xbd,
    0x8b,
    0x8a,
    0x70,
    0x3e,
    0xb5,
    0x66,
    0x48,
    0x03,
    0xf6,
    0x0e,
    0x61,
    0x35,
    0x57,
    0xb9,
    0x86,
    0xc1,
    0x1d,
    0x9e,
    0xe1,
    0xf8,
    0x98,
    0x11,
    0x69,
    0xd9,
    0x8e,
    0x94,
    0x9b,
    0x1e,
    0x87,
    0xe9,
    0xce,
    0x55,
    0x28,
    0xdf,
    0x8c,
    0xa1,
    0x89,
    0x0d,
    0xbf,
    0xe6,
    0x42,
    0x68,
    0x41,
    0x99,
    0x2d,
    0x0f,
    0xb0,
    0x54,
    0xbb,
    0x16,
];

@arch(x86_64)
fn sub_word(w: u32) u32 {
    return SBOX[(w & 0xFF) as usize] as u32 | SBOX[(w >> 8 & 0xFF) as usize] as u32 << 8 | SBOX[(w >> 16 & 0xFF) as usize] as u32 << 16 | SBOX[(w >> 24) as usize] as u32 << 24;
}

@arch(x86_64)
@test
fn sha_and_aes_key_intrinsics_match_their_models() {
    if detect::has(cpu::Feature::Sha) {
        unsafe check_sha_ni();
    }
    if detect::has(cpu::Feature::Aesni) {
        unsafe check_aes_key();
    }
    if detect::has(cpu::Feature::Pclmulqdq) {
        unsafe check_clmul();
    }
    if detect::has(cpu::Feature::Vpclmulqdq) && detect::has(cpu::Feature::Avx2) {
        unsafe check_clmul256();
    }
}

// The 64-bit halves `lo`, `hi` as an xmm register's four lanes.
@arch(x86_64)
fn pair(lo: u64, hi: u64) [u32; 4] {
    return [lo as u32, (lo >> 32) as u32, hi as u32, (hi >> 32) as u32];
}

@arch(x86_64)
fn wide(l: [u32; 4]) u128 {
    return l[0] as u128 | l[1] as u128 << 32 | l[2] as u128 << 64 | l[3] as u128 << 96;
}

// PCLMULQDQ: immediate bit 0 picks the first operand's half, bit 4 the second's.
@arch(x86_64)
@target_feature([cpu::Feature::Pclmulqdq])
fn check_clmul() {
    for i in 0..N {
        for j in 0..N {
            let (a, b) = (V[i], V[j].rotate_left(i as u32 * 7));
            let x = xmm(pair(a, b));
            let y = xmm(pair(b.rotate_left(3), a ^ b));
            assert_eq(wide(lanes_of(unsafe immintrin::_mm_clmulepi64_si128(x, y, 0x00))), clmul(a, b.rotate_left(3)));
            assert_eq(wide(lanes_of(unsafe immintrin::_mm_clmulepi64_si128(x, y, 0x11))), clmul(b, a ^ b));
            assert_eq(wide(lanes_of(unsafe immintrin::_mm_clmulepi64_si128(x, y, 0x01))), clmul(b, b.rotate_left(3)));
            assert_eq(wide(lanes_of(unsafe immintrin::_mm_clmulepi64_si128(x, y, 0x10))), clmul(a, a ^ b));
        }
    }
}

// VPCLMULQDQ on 256 bits: each 128-bit half on its own.
@arch(x86_64)
@target_feature([cpu::Feature::Vpclmulqdq, cpu::Feature::Avx2])
fn check_clmul256() {
    for i in 0..N {
        let (a, b) = (V[i], V[(i + 3) % N]);
        let x: [u64; 4] = [a, b, b ^ 1, a.rotate_left(9)];
        let y: [u64; 4] = [b, a, a.rotate_left(5), b ^ a];
        let vx = unsafe immintrin::_mm256_loadu_si256(((&x[0]) as *const u64) as *const immintrin::__m256i_u);
        let vy = unsafe immintrin::_mm256_loadu_si256(((&y[0]) as *const u64) as *const immintrin::__m256i_u);
        let mut o: [u64; 4] = [0; 4];
        unsafe immintrin::_mm256_storeu_si256(
            ((&mut o[0]) as *mut u64) as *mut immintrin::__m256i_u,
            unsafe immintrin::_mm256_clmulepi64_epi128(vx, vy, 0x01),
        );
        let lo = clmul(x[1], y[0]);
        let hi = clmul(x[3], y[2]);
        assert_eq(o[0] as u128 | o[1] as u128 << 64, lo);
        assert_eq(o[2] as u128 | o[3] as u128 << 64, hi);
    }
}

@arch(x86_64)
@target_feature([cpu::Feature::Sha])
fn check_sha_ni() {
    let mut w: [u32; 12] = [0; 12];
    let mut x: u32 = 0x9E3779B9;
    for _ in 0..64usize {
        for k in 0..12usize {
            x = x.wrapping_mul(1664525).wrapping_add(1013904223);
            w[k] = x;
        }
        let a: [u32; 4] = [w[0], w[1], w[2], w[3]];
        let b: [u32; 4] = [w[4], w[5], w[6], w[7]];
        let k: [u32; 4] = [w[8], w[9], w[10], w[11]];
        let got = lanes_of(immintrin::_mm_sha256rnds2_epu32(xmm(a), xmm(b), xmm(k)));
        let want = sha256rnds2_model(a, b, k);
        for q in 0..4usize {
            assert_eq(got[q], want[q]);
        }
        // SHA256MSG1: W0..W3 plus sigma0 of W1..W4 (W4 the second operand's lane 0).
        let m1 = lanes_of(immintrin::_mm_sha256msg1_epu32(xmm(a), xmm(b)));
        let n1: [u32; 4] = [
            a[0].wrapping_add(sigma0(a[1])),
            a[1].wrapping_add(sigma0(a[2])),
            a[2].wrapping_add(sigma0(a[3])),
            a[3].wrapping_add(sigma0(b[0])),
        ];
        // SHA256MSG2: W16..W19 from the first operand and sigma1 of W14, W15 (the second's lanes 2, 3) and
        // of W16, W17.
        let m2 = lanes_of(immintrin::_mm_sha256msg2_epu32(xmm(a), xmm(b)));
        let w16 = a[0].wrapping_add(sigma1(b[2]));
        let w17 = a[1].wrapping_add(sigma1(b[3]));
        let n2: [u32; 4] = [w16, w17, a[2].wrapping_add(sigma1(w16)), a[3].wrapping_add(sigma1(w17))];
        for q in 0..4usize {
            assert_eq(m1[q], n1[q]);
            assert_eq(m2[q], n2[q]);
        }
        for f in 0..4u32 {
            let r4 = lanes_of(unsafe immintrin::_mm_sha1rnds4_epu32(xmm(a), xmm(b), f as i32));
            let e4 = sha1rnds4_model(a, b, f);
            for q in 0..4usize {
                assert_eq(r4[q], e4[q]);
            }
        }
        // SHA1NEXTE: lane 3 is the first operand's lane 3 rotated left 30 plus the second's; lanes 0 to 2
        // the second's.
        let ne = lanes_of(immintrin::_mm_sha1nexte_epu32(xmm(a), xmm(b)));
        let wn: [u32; 4] = [b[0], b[1], b[2], a[3].rotate_left(30).wrapping_add(b[3])];
        // SHA1MSG1: W0..W3 the first operand's lanes 3 to 0, W4, W5 the second's lanes 3, 2; lane 3 to 0:
        // W0 ^ W2, W1 ^ W3, W2 ^ W4, W3 ^ W5.
        let g1 = lanes_of(immintrin::_mm_sha1msg1_epu32(xmm(a), xmm(b)));
        let w1: [u32; 4] = [a[0] ^ b[2], a[1] ^ b[3], a[2] ^ a[0], a[3] ^ a[1]];
        // SHA1MSG2: W13..W15 the second operand's lanes 2 to 0; W16..W19 from the first's lanes 3 to 0.
        let g2 = lanes_of(immintrin::_mm_sha1msg2_epu32(xmm(a), xmm(b)));
        let w16 = (a[3] ^ b[2]).rotate_left(1);
        let w17 = (a[2] ^ b[1]).rotate_left(1);
        let w18 = (a[1] ^ b[0]).rotate_left(1);
        let w19 = (a[0] ^ w16).rotate_left(1);
        let w2: [u32; 4] = [w19, w18, w17, w16];
        for q in 0..4usize {
            assert_eq(ne[q], wn[q]);
            assert_eq(g1[q], w1[q]);
            assert_eq(g2[q], w2[q]);
        }
    }
}

// AESKEYGENASSIST with round constant 0x1B: SubWord of lanes 1 and 3, and each rotated right by 8 bits
// with the constant in its low byte.
@arch(x86_64)
@target_feature([cpu::Feature::Aesni])
fn check_aes_key() {
    let v: [u32; 4] = [0x16157e2b, 0xa6d2ae28, 0x8815f7ab, 0x3c4fcf09];
    let got = lanes_of(unsafe immintrin::_mm_aeskeygenassist_si128(xmm(v), 0x1B));
    let (s1, s3) = (sub_word(v[1]), sub_word(v[3]));
    let want: [u32; 4] = [s1, s1.rotate_right(8) ^ 0x1B, s3, s3.rotate_right(8) ^ 0x1B];
    for q in 0..4usize {
        assert_eq(got[q], want[q]);
    }
    // AESIMC undoes MixColumns, which AESDECLAST of a zero key and AESENC of a zero key bracket: the
    // inverse of AESENC's MixColumns on its own output, the state of SubBytes and ShiftRows alone.
    let st = xmm(v);
    let z = xmm([0, 0, 0, 0]);
    let full = immintrin::_mm_aesenc_si128(st, z);
    let last = immintrin::_mm_aesenclast_si128(st, z);
    let undone = lanes_of(immintrin::_mm_aesimc_si128(full));
    let l = lanes_of(last);
    for q in 0..4usize {
        assert_eq(undone[q], l[q]);
    }
}
