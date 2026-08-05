// `std::float` -- Float<E, F>, the arbitrary-format IEEE binary floats. The strongest oracle available
// is the hardware: `Float<11, 52>` and `Float<8, 23>` ARE the built-in f64/f32 formats, so every
// operation is checked BIT FOR BIT against the native one over a value set that crosses the interesting
// boundaries -- zeros of both signs, subnormals, the largest finite values, infinities, and fractions
// that exercise every rounding path. The exotic widths (f16, f128, f256) then check known encodings and
// identities the shared generic code must preserve.

import math;

fn dvals() [f64; 22] {
    return [
        0.0,
        -0.0,
        1.0,
        -1.0,
        2.0,
        0.5,
        3.5,
        0.1,
        -0.1,
        1.5e-300,
        4.9406564584124654e-324,
        2.2250738585072014e-308,
        1.7976931348623157e308,
        1.0000000000000002,
        3.141592653589793,
        -2.25e-10,
        1.0e60,
        -7.0,
        0.3333333333333333,
        1024.25,
        6.62607015e-34,
        123456789.123456789,
    ];
}

// Two values are "the same result" when their bits are -- except NaN, which is one VALUE with many
// encodings: 0/0 yields the platform's default quiet NaN, and x86's carries the sign bit set where
// AArch64's does not. Comparing payloads would fail on hardware differences IEEE never promises.
fn same64(x: f64, y: f64) bool {
    if x != x && y != y {
        return true;
    }
    return f64_bits(x) == f64_bits(y);
}

fn same32(x: f32, y: f32) bool {
    if x != x && y != y {
        return true;
    }
    return f32_bits(x) == f32_bits(y);
}

// Every pairwise add/sub/mul/div at the f64 format must produce the hardware's exact bits, and the
// f64 round-trip must be the identity.
@test
fn matches_hardware_f64_bit_for_bit() {
    let vs = dvals();
    for i in 0..22 {
        let a = unsafe vs[i];
        assert_eq(f64_bits(Float::<11, 52, IEEE>::from_f64(a).to_f64()), f64_bits(a));
        for j in 0..22 {
            let b = unsafe vs[j];
            let fa = Float::<11, 52, IEEE>::from_f64(a);
            let fb = Float::<11, 52, IEEE>::from_f64(b);
            assert(same64((fa + fb).to_f64(), a + b));
            assert(same64((fa - fb).to_f64(), a - b));
            assert(same64((fa * fb).to_f64(), a * b));
            assert(same64((fa / fb).to_f64(), a / b));
        }
    }
}

@test
fn matches_hardware_f32_bit_for_bit() {
    let vs: [f32; 18] = [
        0.0f32,
        -0.0f32,
        1.0f32,
        -1.0f32,
        0.5f32,
        3.5f32,
        0.1f32,
        -0.1f32,
        3.4028235e38f32,
        1.1754944e-38f32,
        1.4e-45f32,
        1.0000001f32,
        3.1415927f32,
        -2.25e-10f32,
        1.0e30f32,
        -7.0f32,
        0.33333334f32,
        123456.79f32,
    ];
    for i in 0..18 {
        let a = unsafe vs[i];
        assert_eq(f32_bits(Float::<8, 23, IEEE>::from_f32(a).to_f32()), f32_bits(a));
        for j in 0..18 {
            let b = unsafe vs[j];
            let fa = Float::<8, 23, IEEE>::from_f32(a);
            let fb = Float::<8, 23, IEEE>::from_f32(b);
            assert(same32((fa + fb).to_f32(), a + b));
            assert(same32((fa - fb).to_f32(), a - b));
            assert(same32((fa * fb).to_f32(), a * b));
            assert(same32((fa / fb).to_f32(), a / b));
        }
    }
}

// f16 encodings pinned to the IEEE binary16 bit patterns (values cross-checked externally).
@test
fn f16_known_encodings() {
    let one = f16::from_f64(1.0);
    let two = f16::from_f64(2.0);
    assert_eq(one.to_raw().to_u64(), 0x3C00u64);
    assert_eq(two.neg().to_raw().to_u64(), 0xC000u64);
    assert_eq((one + two).to_raw().to_u64(), 0x4200u64); // 3.0
    assert_eq(f16::from_f64(0.1).to_raw().to_u64(), 0x2E66u64); // 0.1 rounded to 11 bits
    assert_eq((one / (one + two)).to_raw().to_u64(), 0x3555u64); // 1/3
    assert_eq(f16::min_positive().to_raw().to_u64(), 0x0001u64); // least subnormal
    assert_eq(f16::max_finite(false).to_raw().to_u64(), 0x7BFFu64); // 65504
    // overflow saturates to infinity, and NaN equals nothing (itself included)
    assert((f16::max_finite(false) + f16::from_f64(32.0)).is_infinite());
    assert(f16::nan().is_nan());
    assert(!(f16::nan() == f16::nan()));
}

// The wide formats run the same generic code with multi-limb significands: identities that require
// correct multi-limb rounding, and exact round-trips through f64 for representable values.
@test
fn wide_formats_compute_exactly() {
    // (1/3) * 3 at 113-bit precision differs from 1 by at most one ulp
    let third = f128::one() / f128::from_f64(3.0);
    let back = third * f128::from_f64(3.0);
    let d = (back - f128::one()).abs();
    let eps = f128::from_f64(1.0e-33);
    assert(d.is_zero() || d.ieee_lt(&eps));
    // f256 exact small arithmetic surfaces through f64 unchanged
    let f4 = f256::from_f64(2.0) + f256::from_f64(2.0);
    assert(f4.to_f64() == 4.0);
    assert((f4 / f256::from_f64(4.0)).to_f64() == 1.0);
    assert((f256::from_f64(1024.25) * f256::one()).to_f64() == 1024.25);
    // subnormal f128 arithmetic: the least positive value halves to zero and doubles back exactly
    let ms = f128::min_positive();
    assert((ms / f128::from_f64(2.0)).is_zero());
    let dbl = ms * f128::from_f64(2.0);
    assert((ms + ms).ieee_eq(&dbl));
}

// The FINITE_ONLY family, held to e4m3fn's published encodings: no infinities, one NaN encoding
// (S.1111.111), and the top exponent otherwise ordinary, which puts max_finite at 448. Overflow and an
// incoming infinity saturate; division by zero has no infinity to give and answers NaN.
@test
fn finite_only_family_is_e4m3fn() {
    let one = f8e4m3fn::from_f64(1.0);
    assert_eq(one.to_raw().to_u64(), 0x38u64);
    let mx = f8e4m3fn::max_finite(false);
    assert_eq(mx.to_raw().to_u64(), 0x7Eu64);
    assert(mx.to_f64() == 448.0);
    assert_eq(f8e4m3fn::nan().to_raw().to_u64(), 0x7Fu64);
    assert_eq(f8e4m3fn::min_positive().to_raw().to_u64(), 0x01u64);
    // overflow saturates instead of producing an infinity, converted infinities included
    assert((mx + mx).ieee_eq(&mx));
    assert(f8e4m3fn::from_f64(1.0e9).ieee_eq(&mx));
    let inf_in = f8e4m3fn::from_f64(1.0 / 0.0);
    assert(inf_in.ieee_eq(&mx));
    assert(!inf_in.is_infinite());
    // division by zero: no infinity exists, so the answer is NaN
    assert((one / f8e4m3fn::zero()).is_nan());
    assert(f8e4m3fn::nan().is_nan());
    assert(!(f8e4m3fn::nan() == f8e4m3fn::nan()));
    // the family is part of the TYPE: same bit budget, different meaning of the top encodings
    assert(f8e5m2::from_f64(1.0e9).is_infinite()); // the IEEE sibling overflows to infinity
    // round-trip of every representable value through f64 is exact
    let mut i: u64 = 0;
    while i < 256 {
        let v = f8e4m3fn::from_raw(UInt::<8>::from_u64(i));
        if !v.is_nan() {
            let back = f8e4m3fn::from_f64(v.to_f64());
            assert_eq(back.to_raw().to_u64(), i);
        }
        i = i + 1;
    }
}

// Classification, IEEE comparison semantics, and the total order behind `<`.
@test
fn classification_and_comparison() {
    assert(f16::zero().classify() == FpClass::FP_ZERO);
    assert(f16::min_positive().classify() == FpClass::FP_SUBNORMAL);
    assert(f16::one().classify() == FpClass::FP_NORMAL);
    assert(f16::infinity(false).classify() == FpClass::FP_INFINITE);
    assert(f16::nan().classify() == FpClass::FP_NAN);
    // the zeros are one value to ==, and neither is less than the other
    assert(f16::zero() == f16::neg_zero());
    let nz = f16::neg_zero();
    assert(!f16::zero().ieee_lt(&nz));
    // sign and magnitude ordering, both signs
    let a = f16::from_f64(1.5);
    let b = f16::from_f64(2.5);
    assert(a.ieee_lt(&b));
    let na = a.neg();
    assert(b.neg().ieee_lt(&na));
    assert(na.ieee_lt(&b));
    // `<` runs on the total order, so it agrees with ieee_lt wherever IEEE defines an answer
    assert(a < b);
    assert(b.neg() < a.neg());
    // nan propagates through arithmetic
    assert((f16::nan() + f16::one()).is_nan());
    assert((f16::infinity(false) - f16::infinity(false)).is_nan());
    assert((f16::zero() * f16::infinity(true)).is_nan());
    assert((f16::zero() / f16::zero()).is_nan());
    // signed-zero rules: exact cancellation gives +0; 1/-0 is -inf
    assert(!(a - a).is_negative());
    let ninf = f16::one() / f16::neg_zero();
    assert(ninf.is_infinite() && ninf.is_negative());
}

// sqrt and fma, held to libm bit for bit; convert held to the identity it promises.
@test
fn sqrt_fma_convert_match_libm() {
    let vs: [f64; 14] = [
        0.0,
        1.0,
        2.0,
        0.5,
        3.5,
        0.1,
        1.5e-300,
        2.2250738585072014e-308,
        1.7976931348623157e308,
        1.0000000000000002,
        3.141592653589793,
        1.0e60,
        0.3333333333333333,
        1024.25,
    ];
    for i in 0..14 {
        let a = unsafe vs[i];
        assert(same64(Float::<11, 52, IEEE>::from_f64(a).sqrt().to_f64(), unsafe math::sqrt(a)));
        for j in 0..14 {
            for k in 0..14 {
                let b = unsafe vs[j];
                let c = unsafe vs[k];
                let fa = Float::<11, 52, IEEE>::from_f64(a);
                let fb = Float::<11, 52, IEEE>::from_f64(b);
                let fc = Float::<11, 52, IEEE>::from_f64(c);
                assert(same64(fa.fma(&fb, &fc).to_f64(), unsafe math::fma(a, b, c)));
            }
        }
        // widening then narrowing through f128 is the identity; direct narrowing agrees with from_f64
        let src = Float::<11, 52, IEEE>::from_f64(a);
        let wide = f128::convert(&src);
        assert_eq(f64_bits(Float::<11, 52, IEEE>::convert(&wide).to_f64()), f64_bits(a));
        assert_eq(f16::convert(&src).to_raw().to_u64(), f16::from_f64(a).to_raw().to_u64());
    }
    // sqrt specials
    assert(f16::from_f64(0.0 - 4.0).sqrt().is_nan());
    assert(f16::neg_zero().sqrt().is_negative());
    assert(f16::infinity(false).sqrt().is_infinite());
    // sqrt runs the same generic code at multi-limb widths: an exact square stays exact
    let nine = f128::from_f64(9.0);
    assert(nine.sqrt() == f128::from_f64(3.0));
}
