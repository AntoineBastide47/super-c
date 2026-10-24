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
    // Overflow saturates to infinity. Under IEEE equality NaN equals nothing (itself included); `==`
    // (Eq) is encoding equality, the total order the built-in floats' Eq uses.
    assert((f16::max_finite(false) + f16::from_f64(32.0)).is_infinite());
    assert(f16::nan().is_nan());
    let nan16 = f16::nan();
    assert(!f16::nan().ieee_eq(&nan16));
    assert(f16::nan() == f16::nan());
}

// The value of the IEEE encoding `raw` with `e` exponent and `f` fraction bits, from its fields in f64
// arithmetic, exact for the formats below.
const fn field_value(raw: u64, e: usize, f: usize) f64 {
    let emask = (1u64 << e as u64) - 1;
    let ef = raw >> f as u64 & emask;
    let fr = raw & (1u64 << f as u64) - 1;
    let mut v: f64 = 0.0;
    if ef == emask {
        v = if fr == 0 {
            1.0 / 0.0;
        } else {
            0.0 / 0.0;
        };
    } else {
        let sig = if ef == 0 {
            fr;
        } else {
            fr | 1u64 << f as u64;
        };
        let x = ef.max(1) as i64 - ((1i64 << (e - 1) as i64) - 1) - f as i64;
        v = sig as f64 * f64_from_bits((x + 1023) as u64 << 52);
    }
    if raw >> (e + f) as u64 != 0 {
        return -v;
    }
    return v;
}

// A format no wider than f32 in either field converts exactly, every encoding of it: to_f32 and
// to_f64 give its value, NaNs the canonical quiet NaN with the sign kept.
@test
fn narrow_formats_widen_exactly() {
    for raw in 0u64..65536 {
        let v = field_value(raw, 5, 10);
        let h = f16::from_raw(UInt::<16>::from_u64(raw));
        assert(same64(h.to_f64(), v) && same32(h.to_f32(), v as f32));
        let w = field_value(raw, 8, 7);
        let g = bf16::from_raw(UInt::<16>::from_u64(raw));
        assert(same64(g.to_f64(), w) && same32(g.to_f32(), w as f32));
        if h.is_nan() {
            assert_eq(f32_bits(h.to_f32()), (raw >> 15) as u32 << 31 | 0x7FC00000);
            assert_eq(f64_bits(h.to_f64()), raw >> 15 << 63 | 0x7FF8000000000000);
        }
    }
    for raw in 0u64..256 {
        let v = field_value(raw, 5, 2);
        let q = f8e5m2::from_raw(UInt::<8>::from_u64(raw));
        assert(same64(q.to_f64(), v) && same32(q.to_f32(), v as f32));
        let u = field_value(raw, 4, 3);
        let p = Float::<4, 3>::from_raw(UInt::<8>::from_u64(raw));
        assert(same64(p.to_f64(), u) && same32(p.to_f32(), u as f32));
    }
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
// One f128 operand: random bits; or a random sign and fraction with the exponent field 0 (zeros and
// subnormals), all ones (infinities and NaN), tiny or huge (results that underflow or overflow), or near
// `near` (cancelling sums, quotients near 1).
const fn f128_operand(r: &mut u64, near: u64) f128 {
    *r = r.wrapping_add(0x9E3779B97F4A7C15);
    let mut z = *r;
    z = (z ^ z >> 30).wrapping_mul(0xBF58476D1CE4E5B9);
    z = (z ^ z >> 27).wrapping_mul(0x94D049BB133111EB);
    z = z ^ z >> 31;
    let lo = z.wrapping_mul(0x2545F4914F6CDD1D);
    let mut b = UInt::<128>::zero();
    b.set_limb(0, lo);
    let pick = z % 8;
    if pick == 0 {
        b.set_limb(1, z);
        return f128::from_raw(b);
    }
    let e = if pick == 1 {
        0;
    } else if pick == 2 {
        32767;
    } else if pick == 3 {
        (z >> 8) % 160;
    } else if pick == 4 {
        32766 - (z >> 8) % 160;
    } else {
        (near + 32768 + (z >> 8) % 129 - 64) % 32768;
    };
    // A short fraction half the time: ties and exact results.
    let frac = if (z >> 7 & 1) == 0 {
        z >> 16 & 0xFFFFFFFFFFFF;
    } else {
        z >> 16 & 0xFF0000000000;
    };
    if (z >> 7 & 1) != 0 {
        b.set_limb(0, 0);
    }
    b.set_limb(1, z >> 63 << 63 | e << 48 | frac);
    return f128::from_raw(b);
}

// f128 add, subtract, multiply, divide and square root against the f256 result rounded to f128: exact, as
// f256's 237-bit significand is at least 2 x 113 + 2 bits, so its double rounding is innocuous (Figueroa).
// Where the C compiler has binary128 the f128 side of the first four is the native path (float128.h), else
// the limb code; the square roots are the limb code's at both widths.
@test
fn f128_operations_round_as_f256_does() {
    let mut r: u64 = 0x1234;
    for i in 0..20000 {
        let a = f128_operand(&mut r, 16383);
        let b = f128_operand(&mut r, a.to_raw().limb(1) >> 48 & 0x7FFF);
        let wa = f256::convert(&a);
        let wb = f256::convert(&b);
        let aa = a.abs();
        let got = [a + b, a - b, a * b, a / b, aa.sqrt()];
        let waa = wa.abs();
        let ws = [wa + wb, wa - wb, wa * wb, wa / wb, waa.sqrt()];
        for k in 0..5 {
            let g = unsafe got[k];
            let w = f128::convert(&unsafe ws[k]);
            let same = g.is_nan() && w.is_nan() || g.to_raw() == w.to_raw();
            if !same {
                eprintln("case {} op {}: {} and {}", i, k, a.to_string().as_str(), b.to_string().as_str());
            }
            assert(same, "the f128 result is the f256 result rounded");
        }
    }
}

// The square root of an exact square is exact: k with a short significand (56 bits) squares exactly, so
// sqrt(k^2) must be k, with no sticky bit. A root one too large (the integer root's last correction) shows
// here where rounding would hide it.
@test
fn square_roots_of_squares_are_exact() {
    let mut r: u64 = 0x5EED;
    for _ in 0..20000 {
        r = r.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let sig = r >> 8 | 1u64 << 55;
        let e = (r % 4000) as i64 - 2000;
        let su = UInt::<64>::from_u64(sig);
        let k = f128::from_uint(&su).scalbn(e - 55);
        let k2 = k * k;
        assert(k2.sqrt() == k, "an f128 square's root is exact");
        let w = f256::convert(&k);
        let w2 = w * w;
        assert(w2.sqrt() == w, "an f256 square's root is exact");
    }
}

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
    let nan8 = f8e4m3fn::nan();
    assert(!f8e4m3fn::nan().ieee_eq(&nan8));
    // No infinity exists: the text saturates like an overflowing literal.
    assert(f8e4m3fn::from_str("inf").unwrap() == mx);
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
    // The zeros are one value to IEEE equality, and neither is IEEE-less than the other; `==` and `<`
    // follow the total order, which puts -0 below +0.
    let nz = f16::neg_zero();
    assert(f16::zero().ieee_eq(&nz));
    assert(!f16::zero().ieee_lt(&nz));
    assert(f16::zero() != f16::neg_zero() && f16::neg_zero() < f16::zero());
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
        assert(same64(Float::<11, 52>::from_f64(a).sqrt().to_f64(), math::sqrt(a)));
        for j in 0..14 {
            for k in 0..14 {
                let b = unsafe vs[j];
                let c = unsafe vs[k];
                let fa = Float::<11, 52>::from_f64(a);
                let fb = Float::<11, 52>::from_f64(b);
                let fc = Float::<11, 52>::from_f64(c);
                assert(same64(fa.fma(&fb, &fc).to_f64(), math::fma(a, b, c)));
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
        assert(same64(fa.trunc().to_f64(), math::trunc(a)));
        assert(same64(fa.floor().to_f64(), math::floor(a)));
        assert(same64(fa.ceil().to_f64(), math::ceil(a)));
        assert(same64(fa.round().to_f64(), math::round(a)));
        for j in 0..22 {
            let b = unsafe vs[j];
            let fb = Float::<11, 52>::from_f64(b);
            assert(same64((fa % fb).to_f64(), math::fmod(a, b)));
            if a == 0.0 && b == 0.0 {
                // C leaves fmin/fmax's zero sign unspecified; ours is IEEE-2019's -0 < +0.
                let na = fa.signum().to_f64() < 0.0;
                let nb = fb.signum().to_f64() < 0.0;
                assert(fa.min(&fb).signum().to_f64() < 0.0 == (na || nb));
                assert(fa.max(&fb).signum().to_f64() < 0.0 == (na && nb));
            } else {
                assert(same64(fa.min(&fb).to_f64(), math::fmin(a, b)));
                assert(same64(fa.max(&fb).to_f64(), math::fmax(a, b)));
            }
            assert(same64(fa.copysign(&fb).to_f64(), math::copysign(a, b)));
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
    // Hash follows Eq: equal encodings hash alike.
    let (z1, z2) = (Float::<11, 52>::neg_zero(), Float::<11, 52>::neg_zero());
    assert_eq(hash(&z1), hash(&z2));
    // Past the exponent span scalbn still overflows or underflows (a wide exponent field included).
    let wide = Float::<20, 10>::min_positive();
    assert(wide.scalbn(1100000).is_infinite() && wide.scalbn(0 - 10).is_zero());
    let low = Float::<20, 10>::one().scalbn(0 - 524000);
    assert(low.scalbn(1048000) == Float::<20, 10>::one().scalbn(524000));
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
            let want = math::fmod(xf, yf);
            if r.is_nan() {
                assert(want != want || x.is_nan() || y.is_nan() || y.is_zero());
            } else {
                assert(same64(r.to_f64(), want));
            }
        }
        assert(same64(x.trunc().to_f64(), math::trunc(xf)));
        assert(same64(x.floor().to_f64(), math::floor(xf)));
        assert(same64(x.ceil().to_f64(), math::ceil(xf)));
    }
}

// Decimal text is rounded once, to nearest even, as the C compiler reads the same literal: the fast
// path (one exact IEEE operation) and the exact decimal path both, compared bit for bit with values the
// C compiler parsed.
@test
fn parse_f64_is_correctly_rounded() {
    let cases: [str; 12] = [
        "7e-2",
        "0.1",
        "0.3",
        "123.456",
        "1e23",
        "8.98846567431158e307",
        "2.2250738585072011e-308",
        "4.9406564584124654e-324",
        "1.7976931348623157e308",
        "9007199254740993",
        "0.000000000000000000000000000000000000000000001234567890123456789",
        "179769313486231580793728971405303415079934132710037826936173778980444968292764750946649017977587207096330286416692887910946555547851940402630657488671505820681908902000708383676273854845817711531764475730270069855571366959622842914819860834936475292719074168444365510704342711559699508093042880177904174497791",
    ];
    let want: [f64; 12] = [
        7e-2,
        0.1,
        0.3,
        123.456,
        1e23,
        8.98846567431158e307,
        2.2250738585072011e-308,
        4.9406564584124654e-324,
        1.7976931348623157e308,
        9007199254740993.0,
        0.000000000000000000000000000000000000000000001234567890123456789,
        1.7976931348623157e308,
    ];
    for i in 0..12 {
        let got = (unsafe cases[i]).parse_f64().unwrap();
        assert(same64(got, unsafe want[i]));
    }
    assert(same64("1e400".parse_f64().unwrap(), 1.0 / 0.0));
    assert(same64("1e-400".parse_f64().unwrap(), 0.0));
    let nz = "-0.0".parse_f64().unwrap();
    assert(nz == 0.0 && 1.0 / nz < 0.0);
    assert("1.5e".parse_f64().is_none() && ".".parse_f64().is_none() && "1.2.3".parse_f64().is_none());
    assert("0.1".parse_f32().unwrap() == 0.1f32 && "16777217".parse_f32().unwrap() == 16777216.0f32);
}

// A zero significand stays zero at any scale; an overflowing power of ten must not turn it into NaN.
@test
fn from_str_zero_with_huge_exponent() {
    assert(f16::from_str("0e5000").unwrap().is_zero());
    assert(f16::from_str("-0e5000").unwrap().is_negative());
}

const fn step(s: &mut u64) u64 {
    *s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    return *s ^ *s >> 29;
}

// A random fraction field.
const fn rand_frac<const E: usize, const F: usize>(s: &mut u64) UInt<{1 + E + F}> {
    let mut v = UInt::<{1 + E + F}>::zero();
    for i in 0..UInt::<{1 + E + F}>::limbs() {
        v.set_limb(i, step(s));
    }
    return v;
}

// The remainder at every exponent distance: random bit patterns, all classes and scales, against libm.
@test
fn fmod_matches_libm_at_every_scale() {
    let mut s: u64 = 5;
    for _ in 0..20000 {
        let a = f64_from_bits(step(&mut s));
        let b = f64_from_bits(step(&mut s));
        let fa = Float::<11, 52>::from_f64(a);
        let fb = Float::<11, 52>::from_f64(b);
        assert(same64((fa % fb).to_f64(), math::fmod(a, b)));
    }
}

// The wide remainders against the integer one: x = mx 2^(d + e), y = my 2^e, x % y = (mx 2^d mod my) 2^e,
// in a 1024-bit integer for distances up to 700.
fn check_wide_rem<const E: usize, const F: usize>(seed: u64, n: usize) {
    let mut s = seed;
    let bias = (1u64 << (E - 1) as u64) - 1;
    let implicit = UInt::<1024>::one().shl(F);
    for _ in 0..n {
        let fx = rand_frac::<E, F>(&mut s);
        let fy = rand_frac::<E, F>(&mut s);
        let r = step(&mut s);
        let d = (r >> 40) % 700;
        let ey = bias - 20 + (r >> 20) % 40;
        let neg = (r & 1) == 1;
        let x = Float::<E, F, IEEE>::from_parts(neg, ey + d, &fx);
        let y = Float::<E, F, IEEE>::from_parts((r & 2) == 2, ey, &fy);
        let (_, _, px) = x.to_parts();
        let (_, _, py) = y.to_parts();
        let mx = UInt::<1024>::cast_unsigned(&px).bit_or(&implicit);
        let my = UInt::<1024>::cast_unsigned(&py).bit_or(&implicit);
        let rem = mx.shl(d as usize) % my;
        let mut want = Float::<E, F, IEEE>::from_uint(&rem).scalbn(ey as i64 - bias as i64 - F as i64);
        if neg {
            want = want.neg();
        }
        assert(x % y == want, "the remainder is the integer remainder of the significands");
    }
}

@test
fn wide_fmod_matches_the_integer_remainder() {
    check_wide_rem::<15, 112>(41, 3000);
    check_wide_rem::<19, 236>(42, 2000);
}

// Decimal text against the hardware's correctly rounded parse: every finite double prints digits that
// parse back to it, and random digit strings at every scale parse to what the hardware reads.
@test
fn decimal_text_matches_the_hardware_parse() {
    let mut s: u64 = 99;
    for _ in 0..3000 {
        let a = f64_from_bits(step(&mut s));
        if a != a || a - a != 0.0 {
            continue;
        }
        let t = Float::<11, 52>::from_f64(a).to_string();
        assert(same64(t.as_str().parse_f64().unwrap(), a));
        assert(same64(Float::<11, 52>::from_str(t.as_str()).unwrap().to_f64(), a));
    }
    for _ in 0..3000 {
        let r = step(&mut s);
        let mut t = String::new();
        if (r & 1) == 1 {
            t.push_byte(b'-');
        }
        let nd = 1 + (r >> 8) as usize % 30;
        let dot = (r >> 16) as usize % (nd + 1);
        for i in 0..nd {
            if i == dot && i != 0 {
                t.push_byte(b'.');
            }
            t.push_byte(b'0' + (step(&mut s) % 10) as u8);
        }
        t.push_byte(b'e');
        let e = ((r >> 24) % 660) as i64 - 340;
        t.push_i64(e);
        let want = t.as_str().parse_f64().unwrap();
        assert(same64(Float::<11, 52>::from_str(t.as_str()).unwrap().to_f64(), want));
    }
}

// The wide formats' text round-trips: the digit count is chosen for it.
fn check_text_round_trip<const E: usize, const F: usize>(seed: u64, n: usize) {
    let mut s = seed;
    let span = 1u64 << (E - 1) as u64;
    for _ in 0..n {
        let f = rand_frac::<E, F>(&mut s);
        let r = step(&mut s);
        let x = Float::<E, F, IEEE>::from_parts((r & 1) == 1, 1 + (r >> 8) % (2 * span - 2), &f);
        let t = x.to_string();
        assert(Float::<E, F, IEEE>::from_str(t.as_str()).unwrap() == x, "the text parses back to the value");
    }
}

@test
fn wide_decimal_text_round_trips() {
    check_text_round_trip::<15, 112>(51, 500);
    check_text_round_trip::<19, 236>(52, 300);
    check_text_round_trip::<23, 492>(53, 100);
}

// The root is correctly rounded: its value squared brackets x between the squares of the midpoints to
// its neighbours, exact in a format twice as wide. Against the hardware too at the f64 format.
fn check_sqrt<const E: usize, const F: usize>(seed: u64, n: usize) {
    let mut s = seed;
    let span = 1u64 << (E - 1) as u64;
    for _ in 0..n {
        let f = rand_frac::<E, F>(&mut s);
        let r = step(&mut s);
        let x = Float::<E, F, IEEE>::from_parts(false, 1 + r % (2 * span - 2), &f);
        let q = x.sqrt();
        let wq = Float::<{E + 1}, {2 * F + 8}, IEEE>::convert(&q);
        let qd = q.next_down();
        let qu = q.next_up();
        let wd = Float::<{E + 1}, {2 * F + 8}, IEEE>::convert(&qd);
        let wu = Float::<{E + 1}, {2 * F + 8}, IEEE>::convert(&qu);
        let lo = (wd + wq).scalbn(-1);
        let hi = (wq + wu).scalbn(-1);
        let wx = Float::<{E + 1}, {2 * F + 8}, IEEE>::convert(&x);
        let hh = hi * hi;
        assert((lo * lo).ieee_lt(&wx) && wx.ieee_lt(&hh), "x lies between the squares of the midpoints");
    }
}

@test
fn square_roots_are_correctly_rounded() {
    let mut s: u64 = 61;
    for _ in 0..20000 {
        let a = f64_from_bits(step(&mut s));
        assert(same64(Float::<11, 52>::from_f64(a).sqrt().to_f64(), math::sqrt(a)));
    }
    check_sqrt::<15, 112>(62, 3000);
    check_sqrt::<19, 236>(63, 2000);
    check_sqrt::<23, 492>(64, 500);
}
