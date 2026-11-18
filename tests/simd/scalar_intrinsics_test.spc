// The scalar and cryptographic intrinsics of ffi/immintrin.spc (BMI1, BMI2) and ffi/arm_neon.spc (PMULL,
// SHA-1) against scalar models, run where the processor has the feature.
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
@arch(aarch64)
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
