// `std::float`; Float<E, F>, the arbitrary-format IEEE binary floats. The strongest oracle available
// is the hardware: `Float<11, 52>` and `Float<8, 23>` ARE the built-in f64/f32 formats, so every
// operation is checked BIT FOR BIT against the native one over a value set that crosses the interesting
// boundaries: zeros of both signs, subnormals, the largest finite values, infinities, and fractions
// that exercise every rounding path. The exotic widths (f16, f128, f256) then check known encodings and
// identities the shared generic code must preserve.

import math;

const fn dvals() [f64; 22] {
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

// Two values are "the same result" when their bits are: except NaN, which is one VALUE with many
// encodings: 0/0 yields the platform's default quiet NaN, and x86's carries the sign bit set where
// AArch64's does not. Comparing payloads would fail on hardware differences IEEE never promises.
const fn same64(x: f64, y: f64) bool {
    if x != x && y != y {
        return true;
    }
    return f64_bits(x) == f64_bits(y);
}

const fn same32(x: f32, y: f32) bool {
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
        assert_eq(f64_bits(Float::<11, 52>::from_f64(a).to_f64()), f64_bits(a));
        for j in 0..22 {
            let b = unsafe vs[j];
            let fa = Float::<11, 52>::from_f64(a);
            let fb = Float::<11, 52>::from_f64(b);
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
        assert_eq(f32_bits(Float::<8, 23>::from_f32(a).to_f32()), f32_bits(a));
        for j in 0..18 {
            let b = unsafe vs[j];
            let fa = Float::<8, 23>::from_f32(a);
            let fb = Float::<8, 23>::from_f32(b);
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
    // 3.0.
    assert_eq((one + two).to_raw().to_u64(), 0x4200u64);
    // 0.1 rounded to 11 bits.
    assert_eq(f16::from_f64(0.1).to_raw().to_u64(), 0x2E66u64);
    // 1/3.
    assert_eq((one / (one + two)).to_raw().to_u64(), 0x3555u64);
    // Least subnormal.
    assert_eq(f16::min_positive().to_raw().to_u64(), 0x0001u64);
    // 65504.
    assert_eq(f16::max_finite(false).to_raw().to_u64(), 0x7BFFu64);
    // Overflow saturates to infinity, and NaN equals nothing (itself included).
    assert((f16::max_finite(false) + f16::from_f64(32.0)).is_infinite());
    assert(f16::nan().is_nan());
    assert(!(f16::nan() == f16::nan()));
}

// The wide formats run the same generic code with multi-limb significands: identities that require
// correct multi-limb rounding, and exact round-trips through f64 for representable values.
@test
fn wide_formats_compute_exactly() {
    // (1/3) * 3 at 113-bit precision differs from 1 by at most one ulp.
    let third = f128::one() / f128::from_f64(3.0);
    let back = third * f128::from_f64(3.0);
    let d = (back - f128::one()).abs();
    let eps = f128::from_f64(1.0e-33);
    assert(d.is_zero() || d.ieee_lt(&eps));
    // Exact small f256 arithmetic surfaces through f64 unchanged.
    let f4 = f256::from_f64(2.0) + f256::from_f64(2.0);
    assert(f4.to_f64() == 4.0);
    assert((f4 / f256::from_f64(4.0)).to_f64() == 1.0);
    assert((f256::from_f64(1024.25) * f256::one()).to_f64() == 1024.25);
    // Subnormal f128 arithmetic: the least positive value halves to zero and doubles back exactly.
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
    // Overflow saturates instead of producing an infinity, converted infinities included.
    assert((mx + mx).ieee_eq(&mx));
    assert(f8e4m3fn::from_f64(1.0e9).ieee_eq(&mx));
    let inf_in = f8e4m3fn::from_f64(1.0 / 0.0);
    assert(inf_in.ieee_eq(&mx));
    assert(!inf_in.is_infinite());
    // Division by zero: no infinity exists, so the answer is NaN.
    assert((one / f8e4m3fn::zero()).is_nan());
    assert(f8e4m3fn::nan().is_nan());
    assert(!(f8e4m3fn::nan() == f8e4m3fn::nan()));
    // The family is part of the TYPE: same bit budget, different meaning of the top encodings
    // The IEEE sibling overflows to infinity.
    assert(f8e5m2::from_f64(1.0e9).is_infinite());
    // Round-trip of every representable value through f64 is exact.
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
    // The zeros are one value to ==, and neither is less than the other.
    assert(f16::zero() == f16::neg_zero());
    let nz = f16::neg_zero();
    assert(!f16::zero().ieee_lt(&nz));
    // Sign and magnitude ordering, both signs.
    let a = f16::from_f64(1.5);
    let b = f16::from_f64(2.5);
    assert(a.ieee_lt(&b));
    let na = a.neg();
    assert(b.neg().ieee_lt(&na));
    assert(na.ieee_lt(&b));
    // `<` runs on the total order, so it agrees with ieee_lt wherever IEEE defines an answer.
    assert(a < b);
    assert(b.neg() < a.neg());
    // Nan propagates through arithmetic.
    assert((f16::nan() + f16::one()).is_nan());
    assert((f16::infinity(false) - f16::infinity(false)).is_nan());
    assert((f16::zero() * f16::infinity(true)).is_nan());
    assert((f16::zero() / f16::zero()).is_nan());
    // Signed-zero rules: exact cancellation gives +0; 1/-0 is -inf.
    assert(!(a - a).is_negative());
    let ninf = f16::one() / f16::neg_zero();
    assert(ninf.is_infinite() && ninf.is_negative());
}

// Sqrt and fma, held to libm bit for bit; convert held to the identity it promises.
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
        assert(same64(Float::<11, 52>::from_f64(a).sqrt().to_f64(), unsafe math::sqrt(a)));
        for j in 0..14 {
            for k in 0..14 {
                let b = unsafe vs[j];
                let c = unsafe vs[k];
                let fa = Float::<11, 52>::from_f64(a);
                let fb = Float::<11, 52>::from_f64(b);
                let fc = Float::<11, 52>::from_f64(c);
                assert(same64(fa.fma(&fb, &fc).to_f64(), unsafe math::fma(a, b, c)));
            }
        }
        // Widening then narrowing through f128 is the identity; direct narrowing agrees with from_f64.
        let src = Float::<11, 52>::from_f64(a);
        let wide = f128::convert(&src);
        assert_eq(f64_bits(Float::<11, 52>::convert(&wide).to_f64()), f64_bits(a));
        assert_eq(f16::convert(&src).to_raw().to_u64(), f16::from_f64(a).to_raw().to_u64());
    }
    // Sqrt specials.
    assert(f16::from_f64(0.0 - 4.0).sqrt().is_nan());
    assert(f16::neg_zero().sqrt().is_negative());
    assert(f16::infinity(false).sqrt().is_infinite());
    // Sqrt runs the same generic code at multi-limb widths: an exact square stays exact.
    let nine = f128::from_f64(9.0);
    assert(nine.sqrt() == f128::from_f64(3.0));
}

// Decimal text: to_string -> from_str is the identity (the digit count is chosen for it), parsing
// agrees with the compiler's own literal reading, and the specials spell as expected.
@test
fn decimal_text_round_trips() {
    let vs: [f64; 12] = [
        1.0,
        -1.0,
        0.5,
        3.5,
        0.1,
        1.5e-300,
        2.2250738585072014e-308,
        1.7976931348623157e308,
        3.141592653589793,
        1.0e60,
        0.3333333333333333,
        -2.25e-10,
    ];
    for i in 0..12 {
        let a = unsafe vs[i];
        let f = Float::<11, 52>::from_f64(a);
        let s = f.to_string();
        switch Float::<11, 52>::from_str(s.as_str()) {
            Some(b) => {
                assert_eq(f64_bits(b.to_f64()), f64_bits(a));
            },
            None => {
                assert(false);
            },
        };
    }
    switch Float::<11, 52>::from_str("0.1") {
        Some(v) => {
            assert_eq(f64_bits(v.to_f64()), f64_bits(0.1));
        },
        None => {
            assert(false);
        },
    };
    let so = f16::from_f64(1.5).to_string();
    assert(so.as_str() == "1.5e+0");
    let sz = f16::zero().to_string();
    assert(sz.as_str() == "0");
    switch f16::from_str("nan") {
        Some(v) => {
            assert(v.is_nan());
        },
        None => {
            assert(false);
        },
    };
    switch f16::from_str("-inf") {
        Some(v) => {
            assert(v.is_infinite() && v.is_negative());
        },
        None => {
            assert(false);
        },
    };
    assert(f16::from_str("12x").is_none());
    assert(f16::from_str("").is_none());
    // A 36-digit f128 value survives its own text.
    let third = f128::one() / f128::from_f64(3.0);
    let ts = third.to_string();
    switch f128::from_str(ts.as_str()) {
        Some(b) => {
            assert(b == third);
        },
        None => {
            assert(false);
        },
    };
}

// The remainder and the integer-rounding family, bit-for-bit against libm at the f64 format over the
// same differential grid the arithmetic uses: fmod's exactness claim is exactly what this checks.
@test
fn rem_and_rounding_match_libm() {
    let vs = dvals();
    for i in 0..22 {
        let a = unsafe vs[i];
        let fa = Float::<11, 52>::from_f64(a);
        assert(same64(fa.trunc().to_f64(), unsafe math::trunc(a)));
        assert(same64(fa.floor().to_f64(), unsafe math::floor(a)));
        assert(same64(fa.ceil().to_f64(), unsafe math::ceil(a)));
        assert(same64(fa.round().to_f64(), unsafe math::round(a)));
        for j in 0..22 {
            let b = unsafe vs[j];
            let fb = Float::<11, 52>::from_f64(b);
            assert(same64((fa % fb).to_f64(), unsafe math::fmod(a, b)));
            if a == 0.0 && b == 0.0 {
                // C leaves fmin/fmax's zero sign unspecified; ours is IEEE-2019's -0 < +0.
                let na = fa.signum().to_f64() < 0.0;
                let nb = fb.signum().to_f64() < 0.0;
                assert(fa.min(&fb).signum().to_f64() < 0.0 == (na || nb));
                assert(fa.max(&fb).signum().to_f64() < 0.0 == (na && nb));
            } else {
                assert(same64(fa.min(&fb).to_f64(), unsafe math::fmin(a, b)));
                assert(same64(fa.max(&fb).to_f64(), unsafe math::fmax(a, b)));
            }
            assert(same64(fa.copysign(&fb).to_f64(), unsafe math::copysign(a, b)));
        }
    }
    // Ties: away for round, even for round_ties_even; fract is the exact complement.
    let h = Float::<11, 52>::from_f64(2.5);
    assert(same64(h.round().to_f64(), 3.0));
    assert(same64(h.round_ties_even().to_f64(), 2.0));
    let nh = Float::<11, 52>::from_f64(0.0 - 2.5);
    assert(same64(nh.round().to_f64(), 0.0 - 3.0));
    assert(same64(nh.round_ties_even().to_f64(), 0.0 - 2.0));
    let fr = Float::<11, 52>::from_f64(0.0 - 1.25);
    assert(same64(fr.fract().to_f64(), 0.0 - 0.25));
    // Signum reads the sign bit, zeros included.
    assert(same64(Float::<11, 52>::from_f64(0.0).signum().to_f64(), 1.0));
    assert(same64(Float::<11, 52>::neg_zero().signum().to_f64(), 0.0 - 1.0));
    // Clamp: the range is checked, the value passes NaN through.
    let lo = Float::<11, 52>::from_f64(0.0 - 1.0);
    let hi = Float::<11, 52>::from_f64(1.0);
    assert(same64(Float::<11, 52>::from_f64(7.0).clamp(&lo, &hi).to_f64(), 1.0));
    assert(same64(Float::<11, 52>::from_f64(0.5).clamp(&lo, &hi).to_f64(), 0.5));
    assert(Float::<11, 52>::nan().clamp(&lo, &hi).is_nan());
}

// The direct integer bridges: exact where a route through f64 would round twice, saturating exactly
// like the built-in casts, and single-rounded (round to nearest even) past the significand.
@test
fn wide_integer_conversions_are_single_rounded() {
    // More than 53 significant bits but under f128's 113: exact both ways, which f64 in the middle
    // could not deliver.
    let w: u128 = 0x1000000000000F00000000000000;
    let y = f128::from_uint(&w);
    let mut rw = u128::zero();
    y.to_uint(&mut rw);
    assert(rw == w);
    // The rounding is round-to-nearest-even at the 113-bit boundary, checked by hand.
    let a: u128 = (u128::one() << 114) + 1; // half below the tie: rounds down
    let fa = f128::from_uint(&a);
    let mut ra = u128::zero();
    fa.to_uint(&mut ra);
    assert(ra == u128::one() << 114);
    let b: u128 = (u128::one() << 114) + (u128::one() << 1) + 1; // past the half: rounds up
    let fb = f128::from_uint(&b);
    let mut rb = u128::zero();
    fb.to_uint(&mut rb);
    assert(rb == (u128::one() << 114) + (u128::one() << 2));
    // Signed: MIN survives the round-trip, saturation clamps, NaN gives zero.
    let mn = i128::min();
    let fm = f128::from_int(&mn);
    let mut rm = i128::zero();
    fm.to_int(&mut rm);
    assert(rm == mn);
    let huge = Float::<11, 52>::from_f64(1.0e60);
    let mut sat = i128::zero();
    huge.to_int(&mut sat);
    assert(sat == i128::max());
    let mut nz = u128::zero();
    Float::<11, 52>::nan().to_uint(&mut nz);
    assert(nz.is_zero());
    let mut neg = u128::zero();
    Float::<11, 52>::from_f64(0.0 - 3.5).to_uint(&mut neg);
    assert(neg.is_zero());
    // And the f64 grid truncates exactly like the builtin casts.
    let g = Float::<11, 52>::from_f64(12345.75);
    let mut gv = UInt::<64>::zero();
    g.to_uint(&mut gv);
    assert_eq(gv.to_u64(), 12345u64);
}

// Neighbours, spacing and the parts: next_up is one encoding step (proved through libm-free bit
// identities), ulp agrees with the next_up distance on normals, scalbn is exponent arithmetic with
// one correct rounding, and to_parts/from_parts is the identity.
@test
fn neighbours_parts_and_scalbn() {
    let one = Float::<11, 52>::one();
    // next_up(1) - 1 == ulp(1).
    let up = one.next_up();
    assert(same64(up.sub(&one).to_f64(), one.ulp().to_f64()));
    let eps: f64 = 1.1102230246251565e-16; // 2^-53; a named binding, so the subtraction runs at f64
    assert(same64(one.next_down().to_f64(), 1.0 - eps));
    // Across zero: -0 steps to the smallest positive subnormal.
    let tiny = Float::<11, 52>::neg_zero().next_up();
    assert(same64(tiny.to_f64(), 5.0e-324));
    let sd: f64 = 5.0e-324;
    assert(same64(Float::<11, 52>::zero().next_down().to_f64(), 0.0 - sd));
    // The top: max_finite steps to infinity, and back down again.
    let mx = Float::<11, 52>::max_finite(false);
    assert(mx.next_up().is_infinite());
    assert(same64(Float::<11, 52>::infinity(false).next_down().to_f64(), mx.to_f64()));
    // Ulp of zero is the smallest subnormal; of a subnormal, the same.
    assert(same64(Float::<11, 52>::zero().ulp().to_f64(), 5.0e-324));
    // Scalbn against ldexp semantics: exact powers, subnormal entry, overflow exit.
    let three = Float::<11, 52>::from_f64(3.0);
    assert(same64(three.scalbn(10).to_f64(), 3072.0));
    let step: f64 = 5.0e-324; // 2^-1074, the subnormal grid step
    // 3 * 2^-1074 lies ON the grid: exact.
    assert(same64(three.scalbn(0 - 1074).to_f64(), step * 3.0));
    assert(three.scalbn(2000).is_infinite());
    // Parts round-trip the encoding exactly.
    let v = Float::<11, 52>::from_f64(0.0 - 123.456);
    let (sg, eb, fr) = v.to_parts();
    let back = Float::<11, 52>::from_parts(sg, eb, &fr);
    assert(same64(back.to_f64(), v.to_f64()));
    // Hash follows Eq at the zeros.
    assert_eq(Float::<11, 52>::zero().hash(), Float::<11, 52>::neg_zero().hash());
}

// The FINITE_ONLY family exercises the same new surface exhaustively: 256 encodings, every rem and
// floor recomputed through f64 (exact for e4m3's values), and the family rules kept.
@test
fn finite_only_family_new_surface() {
    for i in 0..256 {
        let x = f8e4m3fn::from_raw(UInt::<8>::from_u64(i as u64));
        let xf = x.to_f64();
        for j in 0..256 {
            let y = f8e4m3fn::from_raw(UInt::<8>::from_u64(j as u64));
            let yf = y.to_f64();
            let r = x % y;
            // Every e4m3 value is exact in f64 and fmod is exact, so f64's fmod is the truth:
            // except that this family calls x % 0 NaN, which fmod also does.
            let want = unsafe math::fmod(xf, yf);
            if r.is_nan() {
                assert(want != want || x.is_nan() || y.is_nan() || y.is_zero());
            } else {
                assert(same64(r.to_f64(), want));
            }
        }
        assert(same64(x.trunc().to_f64(), unsafe math::trunc(xf)));
        assert(same64(x.floor().to_f64(), unsafe math::floor(xf)));
        assert(same64(x.ceil().to_f64(), unsafe math::ceil(xf)));
    }
}
