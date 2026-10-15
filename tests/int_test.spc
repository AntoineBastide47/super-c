// `std::int` (a prelude module); the arbitrary-width fixed integers. What is worth testing here is the places the limb
// representation shows through: a carry crossing a limb boundary, a borrow crossing it the other way, a
// product wider than one limb, the sign bit at the top of the top limb, and the ends of each range.
// Widths are exercised at 128, 256 and 512 bits so the monomorphizer produces more than one instantiation.

// These read like the built-in integers: a prelude module, so the aliases need no import, and an integer
// literal or a `u64`/`i64` value converts through the `From` conformances wherever one is expected.
import tests::harness as h;

const SUFFIXED: [u64; 4] = [1u64, 0x1Fu64, 1_000u64, 0b101u64];

@test
fn const_array_literals_keep_width_suffixes() {
    // Element spellings reach C without the Super-C width suffix or digit separators.
    assert(SUFFIXED[0] == 1);
    assert(SUFFIXED[1] == 31);
    assert(SUFFIXED[2] == 1000);
    assert(SUFFIXED[3] == 5);
}

@test
fn reads_like_a_builtin_integer() {
    let a: u128 = 42;
    assert_eq(a.to_u64(), 42u64);
    // Literal as an operand, on both sides of a comparison.
    assert((a + 1).to_u64() == 43u64);
    assert(a == 42);
    assert(a > 41);
    assert(a < 43);
    // A built-in value widens into it, and the arithmetic then happens at the wide width.
    let n: u64 = 0xFFFFFFFFFFFFFFFF;
    let wide: u128 = n;
    let sum = wide + 2;
    let s = sum.to_string();
    assert(s.as_str() == "18446744073709551617");
    // Signed, including a negative literal.
    let neg: i128 = -5;
    assert(neg < i128::zero());
    assert(neg + 5 == i128::zero());
}

// Widths convert like the built-in integers too. Implicitly only WIDENING, which is lossless: the
// signed form extends the sign, so a negative value stays the same number. `as` carries exactly C's cast
// semantics through the cast_unsigned/cast_signed pair: truncation when narrower, extension by the
// SOURCE's signedness when wider, and a scalar cast lands on the value's own to_u64/to_i64.
@test
fn widths_convert_like_builtins() {
    let a: u128 = 7;
    let b: u256 = a; // implicit widening
    assert(b.to_u64() == 7);
    let sgn: i256 = -9;
    let wider: i512 = sgn; // sign-extended
    assert(wider.to_i64() == -9);
    // `as`: down, across signedness, and to a built-in.
    let big = u256::from_u64(0xFFFFFFFFFFFFFFFF) + 1;
    let low = big as u128;
    assert(low.limb(0) == 0);
    assert(low.limb(1) == 1);
    let n: i128 = -1;
    // Two's complement reinterpret, as C casts do.
    assert(n as u128 == u128::max());
    // Sign-extends because the SOURCE is signed.
    assert((n as u256).limb(3) == 0xFFFFFFFFFFFFFFFF);
    assert(a as u64 == 7u64);
    assert(a as u32 == 7u32);
    assert(i128::from_i64(-2) as i64 == -2i64);
}

// Float casts round ONCE: the top 64 bits carry a sticky bit, so the single u64 conversion rounds
// exactly as converting the full value would: limb-by-limb accumulation would round at every step.
// The float-to-integer direction truncates and SATURATES (NaN gives zero), as Rust's float casts do.
@test
fn float_casts_round_once_and_saturate() {
    assert(u128::from_u64(7) as f64 == 7.0);
    assert(7.0 as u128 == u128::from_u64(7));
    // 2^127 - 1 rounds up to 2^127 exactly; without the sticky bit it rounds wrong.
    assert((u128::max() >> 1) as f64 == 170141183460469231731687303715884105728.0);
    // A large power of two is exact and round-trips.
    let p = u128::one() << 100;
    assert((p as f64) as u128 == p);
    // Signed, negative, fractional, and out-of-range saturation.
    assert(i128::from_i64(-9) as f64 == -9.0);
    assert((0.0 - 9.75) as i128 == i128::from_i64(-9));
    assert(1.0e60 as u128 == u128::max());
    assert(((0.0 - 3.5) as u128).is_zero());
    assert(1.0e60 as i128 == i128::max());
    assert((0.0 - 1.0e60) as i128 == i128::min());
    // f32 has its own path, not a double round through f64
    // Rounds to even at 24 bits.
    assert(u128::from_u64(16777217) as f32 == 16777216.0f32);
}

// A width need not be a whole number of limbs: the top limb's unused bits stay zero (an invariant the
// one limb-write site enforces), so every operation wraps at exactly BITS. The float formats depend on
// this: Float<5, 10> stores 16 bits.
@test
fn partial_limb_widths() {
    // 16-bit: wraps at 16, and checked arithmetic sees the true carry.
    let one16 = UInt::<16>::one();
    let m16 = UInt::<16>::from_u64(65535);
    assert(m16.wrapping_add(&one16).is_zero());
    assert(m16.checked_add(&one16).is_none());
    let s16 = m16.to_string();
    assert(s16.as_str() == "65535");
    // 100-bit: the carry crosses limb 0 into the partial limb, and overflow detection sees bit 100.
    let big = UInt::<100>::max();
    let one100 = UInt::<100>::one();
    let two100 = UInt::<100>::from_u64(2);
    assert(big.wrapping_add(&one100).is_zero());
    assert_eq(big.bit_length(), 100);
    assert_eq(big.count_ones(), 100);
    assert(big.checked_mul(&two100).is_none());
    // Division and the full product at a partial width.
    let three = UInt::<100>::from_u64(3);
    let mut r100 = UInt::<100>::zero();
    let q = big.divmod(&three, &mut r100);
    let qs = q.to_string();
    assert(qs.as_str() == "422550200076076467165567735125");
    let f = UInt::<100>::from_u64(0xFFFFFFFFFFFFFFFF);
    let p = f.full_mul(&f);
    let ps = p.to_string();
    assert(ps.as_str() == "340282366920938463426481119284349108225");
    // Signed 20-bit: the sign bit sits mid-limb, and every signed operation reads it there.
    let m = Int::<20>::from_i64(-3);
    assert_eq(m.to_i64(), -3i64);
    assert(m.is_negative());
    assert_eq(m.shr(1).to_i64(), -2i64);
    assert_eq(Int::<20>::min().to_i64(), -524288i64);
    assert_eq(Int::<20>::max().to_i64(), 524287i64);
    // Widening across a mid-limb boundary sign-extends through it.
    let w = Int::<100>::widen(&m);
    assert_eq(w.to_i64(), -3i64);
    assert(w.is_negative());
    assert_eq(Int::<20>::cast_signed(&w).to_i64(), -3i64);
}

@test
fn width_is_the_generic_argument() {
    assert_eq(u128::bits(), 128);
    assert_eq(u128::bytes(), 16);
    assert_eq(u128::limbs(), 2);
    assert_eq(u1024::limbs(), 16);
    assert_eq(i256::bits(), 256);
    // The value is exactly its limbs: no tag, no padding, no allocator.
    assert_eq(sizeof(u128), 16);
    assert_eq(sizeof(i512), 64);
}

// A carry out of limb 0 is the whole reason the type exists.
@test
fn addition_carries_across_limbs() {
    let a = u128::from_u64(0xFFFFFFFFFFFFFFFF);
    let one = u128::one();
    let b = a + one;
    assert_eq(b.limb(0), 0u64);
    assert_eq(b.limb(1), 1u64);
    let back = b - one;
    assert(back == a);
    // And a borrow back across it.
    let z = u128::zero();
    assert(z.wrapping_sub(&one) == u128::max());
}

@test
fn unsigned_overflow_methods_never_trap() {
    let mx = u128::max();
    let one = u128::one();
    let two = u128::from_u64(2);
    assert(mx.wrapping_add(&one).is_zero());
    assert(mx.checked_add(&one).is_none());
    assert(mx.saturating_add(&one) == mx);
    assert(u128::zero().saturating_sub(&one).is_zero());
    assert(u128::zero().checked_sub(&one).is_none());
    assert(u128::zero().wrapping_sub(&one) == mx);
    assert(mx.wrapping_mul(&two) == mx - one);
    assert(two.wrapping_pow(128).is_zero() && two.checked_pow(128).is_none());
    let (s, so) = mx.overflowing_add(&two);
    let (d, dO) = u128::zero().overflowing_sub(&one);
    let (m, mo) = mx.overflowing_mul(&two);
    assert(s == one && so && d == mx && dO && m == mx - one && mo);
    // A width that is not a multiple of 64 wraps at its own width.
    let one100 = UInt::<100>::one();
    let (w, wo) = UInt::<100>::max().overflowing_add(&one100);
    assert(w.is_zero() && wo);
}

@test(should_panic)
fn unsigned_overflow_traps() {
    let _ = u128::max() + u128::one(); // unsigned arithmetic traps, exactly as the built-in unsigned types do
}

@test(should_panic)
fn unsigned_pow_overflow_traps() {
    let _ = u128::from_u64(2).pow(128);
}

@test
fn multiplication_spans_limbs() {
    let a = u128::from_u64(1000000007);
    let b = u128::from_u64(1000000009);
    let p = a * b;
    let s = p.to_string();
    assert(s.as_str() == "1000000016000000063");
    // A product that needs the second limb, checked by dividing it back out.
    let big = u128::from_u64(0xFFFFFFFFFFFFFFFF);
    let two = u128::from_u64(2);
    let wide = big * two;
    assert_eq(wide.limb(1), 1u64);
    let mut rem = u128::zero();
    let back = wide.divmod(&two, &mut rem);
    assert(back == big);
    assert(rem.is_zero());
    // (2^64-1)^2 still fits in 128 bits exactly; twice the maximum does not.
    let sq = big.checked_mul(&big);
    assert(sq.is_some());
    let sqs = sq.unwrap().to_string();
    assert(sqs.as_str() == "340282366920938463426481119284349108225");
    assert(u128::max().checked_mul(&two).is_none());
}

@test
fn division_and_remainder() {
    let a = u256::from_u64(1000000000000000000);
    let b = u256::from_u64(7);
    let q = a / b;
    let r = a % b;
    let qs = q.to_string();
    assert(qs.as_str() == "142857142857142857");
    assert_eq(r.to_u64(), 1u64);
    // q * b + r == a.
    assert(q * b + r == a);
}

@test
fn shifts_move_bits_across_limbs() {
    let one = u128::one();
    // The shift operators take a COUNT, not another value of the shifted type, so `<<`/`>>` and their
    // compound forms pass a usize straight through to shl/shr.
    assert(one << 64 == one.shl(64));
    assert(one << 64 >> 64 == one);
    let mut sh = one;
    sh <<= 12;
    sh >>= 8;
    assert(sh == one.shl(4));
    assert(i128::from_i64(-16) >> 2 == i128::from_i64(-4));
    let hi = one.shl(64);
    assert_eq(hi.limb(0), 0u64);
    assert_eq(hi.limb(1), 1u64);
    assert(hi.shr(64) == one);
    assert(one.shl(127).shr(127) == one);
    // Shifting past the width discards, as the builtins do.
    assert(one.shl(128).is_zero());
    assert_eq(hi.bit_length(), 65);
    assert_eq(hi.leading_zeros(), 63);
    assert_eq(u128::max().count_ones(), 128);
}

// Reached through the operators, which is what the BitAnd/BitOr/BitXor/BitNot conformances are for; the
// methods behind them are the same ones.
@test
fn bitwise_operations() {
    let a = u128::from_u64(0xF0F0);
    let b = u128::from_u64(0x0FF0);
    assert_eq((a & b).to_u64(), 0x00F0u64);
    assert_eq((a | b).to_u64(), 0xFFF0u64);
    assert_eq((a ^ b).to_u64(), 0xFF00u64);
    assert(~~a == a);
    assert(~u128::zero() == u128::max());
    // and the compound forms, which lower to `x = x.op(y)`.
    let mut acc = a;
    acc &= b;
    assert(acc == (a & b));
    acc |= u128::from_u64(0xF);
    assert(acc == (a & b | u128::from_u64(0xF)));
    acc ^= acc;
    assert(acc.is_zero());
    // Signed values reach the same operators.
    assert(~i128::zero() == i128::from_i64(-1));
    assert((i128::from_i64(12) & i128::from_i64(10)) == i128::from_i64(8));
}

// The sign bit is the top bit of the top limb, and every signed-specific operation reads it.
@test
fn signed_sign_and_range() {
    let mn = i256::min();
    let mx = i256::max();
    assert(mn.is_negative());
    assert(!mx.is_negative());
    assert(!i256::zero().is_negative());
    assert(mn < mx);
    assert(i256::from_i64(-1) < i256::zero());
    assert(i256::from_i64(-1) > mn);
    // MIN has no positive counterpart, which every operation that could produce one must refuse.
    assert(mn.checked_neg().is_none());
    let one = i256::one();
    assert(mn.checked_sub(&one).is_none());
    assert(mx.checked_add(&one).is_none());
    assert(mn.saturating_sub(&one) == mn);
    assert(mx.saturating_add(&one) == mx);
}

@test
fn signed_negative_values_round_trip() {
    let a = i128::from_i64(-1234567890123456789);
    let b = i128::from_i64(1000000007);
    let p = a * b;
    let s = p.to_string();
    assert(s.as_str() == "-1234567898765432019864197523");
    let mut r = i128::zero();
    let q = p.divmod(&b, &mut r);
    assert(q == a);
    assert(r.is_zero());
    // Sign extension: a negative 64-bit value fills every limb above it.
    assert_eq(a.limb(1), 0xFFFFFFFFFFFFFFFFu64);
}

// C's rule, which the built-in signed types follow: the quotient truncates toward zero and the remainder
// takes the DIVIDEND's sign.
@test
fn signed_division_truncates_toward_zero() {
    let two = i128::from_i64(2);
    let mut r = i128::zero();
    let q = i128::from_i64(-7).divmod(&two, &mut r);
    assert(q == i128::from_i64(-3));
    assert(r == i128::from_i64(-1));
    let mt = i128::from_i64(-2);
    let q2 = i128::from_i64(7).divmod(&mt, &mut r);
    assert(q2 == i128::from_i64(-3));
    assert(r == i128::one());
    assert(i128::from_i64(-7) / two == i128::from_i64(-3));
    assert(i128::from_i64(-7) % two == i128::from_i64(-1));
}

// Arithmetic, not logical: the sign fills the top, so a negative value stays negative.
@test
fn signed_shift_right_keeps_the_sign() {
    assert(i128::from_i64(-16).shr(2) == i128::from_i64(-4));
    assert(i128::from_i64(-1).shr(60) == i128::from_i64(-1));
    assert(i128::from_i64(-1).shr(127) == i128::from_i64(-1));
    assert(i128::from_i64(16).shr(2) == i128::from_i64(4));
    assert(i256::min().shr(255) == i256::from_i64(-1));
}

@test
fn text_round_trips_at_every_width() {
    let m = u256::max();
    let mx = m.to_string();
    assert(mx.as_str() == "115792089237316195423570985008687907853269984665640564039457584007913129639935");
    let s = "-670390396497129854978701249910292306373968291029619668886178072186088201503677348840093714908345229483";
    switch i512::from_str(s) {
        Some(v) => {
            let back = v.to_string();
            assert(back.as_str() == s);
        },
        None => {
            assert(false);
        },
    };
    // A value one past the width does not parse.
    assert(u128::from_str("340282366920938463463374607431768211456").is_none());
    assert(u128::from_str("340282366920938463463374607431768211455").is_some());
    assert(u128::from_str("").is_none());
    assert(u128::from_str("12x").is_none());
    let z = u128::zero().to_string();
    assert(z.as_str() == "0");
}

@test
fn conformances() {
    // Eq/Ord drive `==` and `<`; Hash agrees with Eq; Default is zero.
    let a = u128::from_u64(5);
    let b = u128::from_u64(5);
    assert(a == b);
    assert_eq(a.hash(), b.hash());
    assert(u128::default().is_zero());
    assert(i128::default().is_zero());
    assert(a.clone() == a);
    let f = a.fmt();
    assert(f.as_str() == "5");
    // They work as Map keys, which is what Hash + Eq are for.
    let mut m = Map::<u128, i32>::new();
    m.insert(a, 7);
    switch m.get(&b) {
        Some(v) => {
            assert_eq(*v, 7);
        },
        None => {
            assert(false);
        },
    };
}

@test(should_panic)
fn division_by_zero_panics() {
    let a = u128::one();
    let z = u128::zero();
    let _ = a / z;
}

@test(should_panic)
fn signed_overflow_traps() {
    let mx = i128::max();
    let one = i128::one();
    let _ = mx + one; // signed arithmetic traps, exactly as the built-in signed types do
}

@test(should_panic)
fn min_divided_by_minus_one_traps() {
    let mn = i128::min();
    let neg1 = i128::from_i64(-1);
    let _ = mn / neg1;
}

// The full product needs 2N bits, so it is returned either as two N-bit halves or as one value of twice
// the width: the latter through a const-generic EXPRESSION, `UInt<{BITS * 2}>`.
@test
fn widening_and_full_multiplication() {
    let a = u128::max();
    let mut hi = u128::zero();
    let lo = a.widening_mul(&a, &mut hi);
    // (2^128-1)^2 = 2^256 - 2^129 + 1: low half 1, high half 2^128 - 2.
    assert(lo == u128::one());
    assert(hi == a - u128::one());
    let p = a.full_mul(&a);
    assert_eq(u128::bits() * 2, 256);
    let s = p.to_string();
    assert(s.as_str() == "115792089237316195423570985008687907852589419931798687112530834793049593217025");
    // And a width the aliases do not name, to show the expression is computed rather than looked up.
    let b = UInt::<192>::from_u64(0xFFFFFFFFFFFFFFFF);
    let w = b.full_mul(&b);
    assert_eq(UInt::<384>::limbs(), 6);
    let ws = w.to_string();
    assert(ws.as_str() == "340282366920938463426481119284349108225");
}

// Widening composes: the result of one full product feeds the next, and the width the signature promises
// is the one that arrives: `{(B * 2) * 2}` and `{B * 4}` are the same width, not two that look alike.
fn square_twice<const B: usize>(x: &UInt<B>) UInt<{B * 4}> {
    let sq = x.full_mul(x);
    return sq.full_mul(&sq);
}

@test
fn widening_composes_across_widths() {
    let a = u128::from_u64(0xFFFFFFFFFFFFFFFF);
    let q = square_twice(&a); // u128 -> u256 -> u512
    let s = q.to_string();
    assert(s.as_str() == "115792089237316195398462578067141184799968521174335529155754622898352762650625");
}

// The 128-bit width is the one that routes through the C compiler's native 128-bit type where one
// exists; UInt<256> never does. Recomputing every 128-bit result inside u256 and truncating back is
// therefore a differential test of the native path against the limb code, and on a target without
// the native type both sides run limb code, so the test still holds.
@test
fn native_128_path_matches_the_limb_code() {
    let vs: [u64; 6] = [0u64, 1, 2, 0x8000000000000000, 0xFFFFFFFFFFFFFFFF, 0xDEADBEEFCAFEBABE];
    for i in 0..6 {
        for j in 0..6 {
            let a = u128::from_u64(unsafe vs[i]) << 64 | unsafe vs[j];
            for k in 0..6 {
                for l in 0..6 {
                    let b = u128::from_u64(unsafe vs[k]) << 64 | unsafe vs[l];
                    let wa: u256 = a;
                    let wb: u256 = b;
                    // Addition: the wrapped value, and the carry as bit 128 of the wide sum.
                    assert(a.wrapping_add(&b) == (wa + wb) as u128);
                    assert(a.checked_add(&b).is_none() == !(wa + wb >> 128).is_zero());
                    // Subtraction: round-trips, and the borrow is the unsigned order.
                    assert(a.wrapping_sub(&b).wrapping_add(&b) == a);
                    assert(a.checked_sub(&b).is_none() == a < b);
                    // Multiplication: the exact 256-bit product is the ground truth for all three forms.
                    let p = wa * wb;
                    assert(a.wrapping_mul(&b) == p as u128);
                    assert(a.checked_mul(&b).is_none() == !(p >> 128).is_zero());
                    assert(a.full_mul(&b) == p);
                    // Division: quotient and remainder against the wide divider, plus reconstruction.
                    if !b.is_zero() {
                        let mut r = u128::zero();
                        let q = a.divmod(&b, &mut r);
                        assert(q == (wa / wb) as u128);
                        assert(r == (wa % wb) as u128);
                        assert(r < b);
                        assert(q.wrapping_mul(&b).wrapping_add(&r) == a);
                    }
                }
            }
            // Decimal text runs on the small divider; the wide width answers with the limb code.
            let w: u256 = a;
            let s1 = a.to_string();
            let s2 = w.to_string();
            assert(s1.as_str() == s2.as_str());
        }
    }
}

// The bit-utility and arithmetic tail: each answer is checked against a reformulation through already
// pinned operations (shifts, wrapping arithmetic, the 256-bit ground truth), never against itself.
@test
fn bit_utilities_and_arithmetic_tail() {
    let x = u128::from_u64(0xDEADBEEF00000000u64) << 64 | 0x12345678u64;
    // Counts.
    assert_eq(x.count_ones() + x.count_zeros(), 128);
    assert_eq(x.trailing_zeros(), 3);
    assert_eq(u128::zero().trailing_zeros(), 128);
    assert_eq(u128::one().trailing_zeros(), 0);
    assert_eq((u128::one() << 127).trailing_zeros(), 127);
    // Rotation: leaves one end, returns at the other; a full turn is identity.
    assert(x.rotate_left(0) == x);
    assert(x.rotate_left(128) == x);
    assert(x.rotate_left(40).rotate_right(40) == x);
    let rl = x << 1 | x >> 127;
    assert(x.rotate_left(1) == rl);
    // A PARTIAL width rotates through its own BITS, not a limb's 64.
    let p = UInt::<100>::one();
    assert(p.rotate_right(1) == UInt::<100>::one() << 99);
    // Byte and bit reversal are involutions, and land where they should.
    assert(x.swap_bytes().swap_bytes() == x);
    assert_eq(x.swap_bytes().limb(1), 0x7856341200000000u64);
    assert(x.reverse_bits().reverse_bits() == x);
    assert(u128::one().reverse_bits() == u128::one() << 127);
    // Powers of two.
    assert(!x.is_power_of_two());
    assert((u128::one() << 90).is_power_of_two());
    assert(u128::from_u64(100).next_power_of_two() == u128::from_u64(128));
    assert(u128::from_u64(128).next_power_of_two() == u128::from_u64(128));
    assert(u128::zero().next_power_of_two() == u128::one());
    assert(u128::max().checked_next_power_of_two().is_none());
    // overflowing_*: value matches wrapping, flag matches checked.
    let m = u128::max();
    let one = u128::one();
    let two = u128::from_u64(2);
    let four = u128::from_u64(4);
    let (av, ao) = m.overflowing_add(&one);
    assert(av.is_zero() && ao);
    let (bv, bo) = u128::zero().overflowing_sub(&one);
    assert(bv == m && bo);
    let (mv, mo) = m.overflowing_mul(&two);
    assert(mv == m.wrapping_mul(&two) && mo);
    let (nv, no) = u128::from_u64(3).overflowing_mul(&four);
    assert(nv == u128::from_u64(12) && !no);
    // Pow against repeated multiplication, and its overflow report.
    let three = u128::from_u64(3);
    let mut acc = u128::one();
    for _i in 0..77 {
        acc = acc * three;
    }
    assert(three.pow(77) == acc);
    assert(three.checked_pow(77).is_some());
    // 3^100 needs 159 bits.
    assert(three.checked_pow(100).is_none());
    assert(u128::from_u64(2).pow(0) == u128::one());
    // abs_diff and checked_rem.
    let seven = u128::from_u64(7);
    let nine = u128::from_u64(9);
    let z = u128::zero();
    assert(seven.abs_diff(&nine) == two);
    assert(m.abs_diff(&z) == m);
    assert(seven.checked_rem(&three).unwrap() == one);
    assert(seven.checked_rem(&z).is_none());
}

// The signed tail: delegations read the same bits, the euclidean pair satisfies its defining law for
// every sign combination, and overflow reporting matches the checked family.
@test
fn signed_tail_and_euclid() {
    let n = i128::from_i64(-2);
    // Two's complement -2: every bit but bit 0.
    assert_eq(n.count_ones(), 127);
    assert_eq(n.trailing_zeros(), 1);
    assert(n.signum() == i128::from_i64(-1));
    assert(i128::zero().signum().is_zero());
    assert(i128::from_i64(5).signum() == i128::one());
    let imax = i128::max();
    let ifour = i128::from_i64(4);
    assert(i128::min().abs_diff(&imax) == u128::max());
    assert(i128::from_i64(-3).abs_diff(&ifour) == u128::from_u64(7));
    // Euclid: d*q + r == self and 0 <= r < |d|, all four sign shapes.
    let vals: [i64; 4] = [7i64, -7i64, 9i64, -9i64];
    for i in 0..4 {
        for j in 0..4 {
            let a = i128::from_i64(unsafe vals[i]);
            let b = i128::from_i64(
                if unsafe vals[j] > 0 {
                    3i64;
                } else {
                    -3i64;
                },
            );
            let q = a.div_euclid(&b);
            let r = a.rem_euclid(&b);
            assert(!r.is_negative());
            assert(r < i128::from_i64(3));
            assert(b * q + r == a);
        }
    }
    // Overflowing against checked.
    let ione = i128::one();
    let ineg1 = i128::from_i64(-1);
    let (av, ao) = i128::max().overflowing_add(&ione);
    assert(ao && av == i128::min());
    let (sv, so) = i128::min().overflowing_sub(&ione);
    assert(so && sv == i128::max());
    let (_mv, mo) = i128::min().overflowing_mul(&ineg1);
    assert(mo);
    // Pow traps are reported, and the plain form matches multiplication.
    assert(i128::from_i64(-3).pow(3) == i128::from_i64(-27));
    assert(i128::from_i64(2).checked_pow(126).is_some());
    assert(i128::from_i64(2).checked_pow(127).is_none());
}

// Bytes and radix text: round-trips are exact (partial top byte included), byte order is what the
// name says, and every radix agrees with the decimal the type already pins.
@test
fn bytes_and_radix_text() {
    let x = u128::from_u64(0x0102030405060708u64) << 64 | 0x090A0B0C0D0E0F10u64;
    let mut le = Array::<u8, 16>::new();
    x.to_le_bytes(le.index_range_mut(0usize..16));
    assert_eq(le[0] as i32, 0x10);
    assert_eq(le[15] as i32, 0x01);
    assert(u128::from_le_bytes(le[0..16]) == x);
    let mut be = Array::<u8, 16>::new();
    x.to_be_bytes(be.index_range_mut(0usize..16));
    assert_eq(be[0] as i32, 0x01);
    assert_eq(be[15] as i32, 0x10);
    assert(u128::from_be_bytes(be[0..16]) == x);
    // A partial width: 100 bits = 13 bytes, 4 live bits in the top one, masked on the way back in.
    let p = UInt::<100>::max();
    let mut pb = Array::<u8, 13>::new();
    p.to_le_bytes(pb.index_range_mut(0usize..13));
    assert_eq(pb[12] as i32, 0x0F);
    assert(UInt::<100>::from_le_bytes(pb[0..13]) == p);
    let mut full = Array::<u8, 13>::new();
    for i in 0usize..13 {
        full[i] = 0xFF;
    }
    // Bits past the width do not exist.
    assert(UInt::<100>::from_le_bytes(full[0..13]) == p);
    // A missing high byte reads as the zero it is.
    assert(u128::from_le_bytes(le[0..8]) == u128::from_u64(0x090A0B0C0D0E0F10u64));
    // Signed round-trip preserves the sign bits exactly.
    let sn = i128::from_i64(-123456789);
    let mut sb = Array::<u8, 16>::new();
    sn.to_le_bytes(sb.index_range_mut(0usize..16));
    assert(i128::from_le_bytes(sb[0..16]) == sn);
    sn.to_be_bytes(sb.index_range_mut(0usize..16));
    assert(i128::from_be_bytes(sb[0..16]) == sn);
    // Radix: hex, binary and base 36 against the decimal ground truth.
    let v = u128::from_str("340282366920938463463374607431768211455").unwrap(); // 2^128 - 1
    let hex = v.to_string_radix(16);
    assert(hex.as_str() == "ffffffffffffffffffffffffffffffff");
    let two = u128::from_u64(2);
    let bin = two.pow(100).to_string_radix(2);
    assert_eq(bin.len(), 101);
    assert(bin.as_str().byte_at(0) == b'1');
    assert(u128::from_str_radix("ffffffffffffffffffffffffffffffff", 16).unwrap() == v);
    assert(u128::from_str_radix("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF", 16).unwrap() == v);
    // One too wide.
    assert(u128::from_str_radix("100000000000000000000000000000000", 16).is_none());
    // Digit outside the radix.
    assert(u128::from_str_radix("12", 2).is_none());
    assert(u128::from_str_radix("10", 37).is_none());
    let rt = u128::from_str_radix("zz", 36).unwrap();
    assert(rt == u128::from_u64(1295));
    assert(i128::from_str_radix("-80000000000000000000000000000000", 16).unwrap() == i128::min());
    assert(i128::from_str_radix("7fffffffffffffffffffffffffffffff", 16).unwrap() == i128::max());
    let sm = i128::from_i64(-255);
    let sh = sm.to_string_radix(16);
    assert(sh.as_str() == "-ff");
}

// Integer literals wider than 64 bits, admitted wherever the context expects UInt<N>/Int<N>: the
// typechecker parses the digits into the storage's limbs at compile time, so the emitted value is a
// compound literal, not a runtime conversion. Decimal and hex, both signs, partial widths, and the
// operand position (where the left side's type is the context).
@test
fn wide_integer_literals() {
    let a: u128 = 340282366920938463463374607431768211455;
    assert(a == u128::max());
    let h: u128 = 0xDEADBEEF00000000123456789ABCDEF0;
    assert_eq(h.limb(1), 0xDEADBEEF00000000u64);
    assert_eq(h.limb(0), 0x123456789ABCDEF0u64);
    let mn: i128 = -170141183460469231731687303715884105728;
    assert(mn == i128::min());
    let mx: i128 = 170141183460469231731687303715884105727;
    assert(mx == i128::max());
    let p: UInt<100> = 0xFFFFFFFFFFFFFFFFFFFFFFFFF;
    assert(p == UInt::<100>::max());
    let big: u256 = 115792089237316195423570985008687907853269984665640564039457584007913129639935;
    assert(big == u256::max());
    // The operand position: the left side's width is what the literal means.
    let one: u128 = 1;
    let b = one + 18446744073709551616;
    assert_eq(b.limb(1), 1u64);
    assert(b == 18446744073709551617);
    // Separators and a negative hex magnitude.
    let sep: u128 = 340_282_366_920_938_463_463_374_607_431_768_211_455;
    assert(sep == u128::max());
    let nh: i128 = -0x80000000000000000000000000000000;
    assert(nh == i128::min());
    // And the SUFFIX spelling: the width rides on the literal, so no context is needed at all.
    let sa = 5i128;
    assert(sa == i128::from_i64(5));
    assert(340282366920938463463374607431768211455u128 == u128::max());
    assert(-170141183460469231731687303715884105728i128 == i128::min());
    assert(0xFFu256 == u256::from_u64(255));
    // ANY width, not only the aliased ones.
    assert(7u100 == UInt::<100>::from_u64(7));
    assert(sa + 1i128 == 6i128);
}

// from_f64 saturates at the WIDTH, whatever the width: below 64 bits and past a limb boundary too.
@test
fn from_f64_saturates_at_every_width() {
    assert(UInt::<32>::from_f64(1.0e10) == UInt::<32>::max());
    assert(UInt::<100>::from_f64(1267650600228229401496703205376.0) == UInt::<100>::max()); // 2^100
    let big = UInt::<100>::from_f64(1.0e20).to_string();
    assert(big.as_str() == "100000000000000000000");
    assert(Int::<32>::from_f64(0.0 - 1.0e10) == Int::<32>::min());
    assert(Int::<100>::from_f64(1.0e40) == Int::<100>::max());
}

// Signed multiplication overflow, decided from the magnitudes and the sign.
@test
fn signed_checked_mul_edges() {
    let mn = i256::min();
    let neg1 = i256::from_i64(-1);
    let two = i256::from_i64(2);
    assert(mn.checked_mul(&neg1).is_none());
    assert(neg1.checked_mul(&mn).is_none());
    let one = i256::one();
    assert(mn.checked_mul(&one).unwrap() == mn);
    let half = mn.checked_div(&two).unwrap(); // -2^254
    assert(half.checked_mul(&two).unwrap() == mn);
    assert(half.wrapping_neg().checked_mul(&two).is_none()); // +2^255 overflows
    let a = i256::from_i64(-12345);
    let b = i256::from_i64(6789);
    assert(a.checked_mul(&b).unwrap() == i256::from_i64(-83810205));
    assert(Int::<70>::from_i64(3).checked_pow(44).is_none() && Int::<70>::from_i64(-3).checked_pow(43).is_some());
}

// Digits are written once into the result: every radix and the sign.
@test
fn to_string_every_radix() {
    let zero = u256::zero().to_string();
    assert(zero.as_str() == "0");
    assert_eq(u256::max().to_string_radix(16).len(), 64 as usize);
    assert_eq(i256::min().to_string_radix(2).len(), 257 as usize);
    let hex = i128::from_i64(-255).to_string_radix(16);
    assert(hex.as_str() == "-ff");
    let mx = u128::max().to_string();
    assert(mx.as_str() == "340282366920938463463374607431768211455");
}

// The built-in integers' bit counts, packed as trailing * 10000 + leading * 100 + ones so one compare
// checks all three. The same `const fn`s run at compile time (the static_asserts below) and in the
// emitted C (the test, whose inputs come from a Vector).
const fn packed(t: usize, l: usize, c: usize) usize {
    return t * 10000 + l * 100 + c;
}
const fn bits_u8(x: u8) usize {
    return packed(x.trailing_zeros(), x.leading_zeros(), x.count_ones());
}
const fn bits_u16(x: u16) usize {
    return packed(x.trailing_zeros(), x.leading_zeros(), x.count_ones());
}
const fn bits_u32(x: u32) usize {
    return packed(x.trailing_zeros(), x.leading_zeros(), x.count_ones());
}
const fn bits_u64(x: u64) usize {
    return packed(x.trailing_zeros(), x.leading_zeros(), x.count_ones());
}
const fn bits_usize(x: usize) usize {
    return packed(x.trailing_zeros(), x.leading_zeros(), x.count_ones());
}
const fn bits_i8(x: i8) usize {
    return packed(x.trailing_zeros(), x.leading_zeros(), x.count_ones());
}
const fn bits_i16(x: i16) usize {
    return packed(x.trailing_zeros(), x.leading_zeros(), x.count_ones());
}
const fn bits_i32(x: i32) usize {
    return packed(x.trailing_zeros(), x.leading_zeros(), x.count_ones());
}
const fn bits_i64(x: i64) usize {
    return packed(x.trailing_zeros(), x.leading_zeros(), x.count_ones());
}
const fn bits_isize(x: isize) usize {
    return packed(x.trailing_zeros(), x.leading_zeros(), x.count_ones());
}
const USIZE_W: usize = sizeof(usize) * 8;

static_assert(bits_u8(0) == packed(8, 8, 0) && bits_u8(1) == packed(0, 7, 1), "u8 zero, one");
static_assert(bits_u8(0x80) == packed(7, 0, 1) && bits_u8(0xFF) == packed(0, 0, 8), "u8 top, all");
static_assert(bits_u16(0) == packed(16, 16, 0) && bits_u16(1) == packed(0, 15, 1), "u16 zero, one");
static_assert(bits_u16(0x8000) == packed(15, 0, 1) && bits_u16(0xFFFF) == packed(0, 0, 16), "u16 top, all");
static_assert(bits_u32(0) == packed(32, 32, 0) && bits_u32(1) == packed(0, 31, 1), "u32 zero, one");
static_assert(bits_u32(0x80000000) == packed(31, 0, 1) && bits_u32(0xFFFFFFFF) == packed(0, 0, 32), "u32 top, all");
static_assert(bits_u64(0) == packed(64, 64, 0) && bits_u64(1) == packed(0, 63, 1), "u64 zero, one");
static_assert(bits_u64(0x8000000000000000) == packed(63, 0, 1), "u64 top");
static_assert(bits_u64(0xFFFFFFFFFFFFFFFF) == packed(0, 0, 64), "u64 all");
static_assert(bits_u64(0x50) == packed(4, 57, 2), "u64 inner bits");
static_assert(bits_usize(0) == packed(USIZE_W, USIZE_W, 0) && bits_usize(1) == packed(0, USIZE_W - 1, 1), "usize zero, one");
static_assert(bits_usize(1 << USIZE_W - 1) == packed(USIZE_W - 1, 0, 1), "usize top");
static_assert(bits_i8(0) == packed(8, 8, 0) && bits_i8(-128) == packed(7, 0, 1) && bits_i8(-1) == packed(0, 0, 8), "i8");
static_assert(bits_i16(0) == packed(16, 16, 0) && bits_i16(-1) == packed(0, 0, 16), "i16");
static_assert(bits_i32(1) == packed(0, 31, 1) && bits_i32(-1) == packed(0, 0, 32), "i32");
static_assert(bits_i64(0) == packed(64, 64, 0) && bits_i64(-1) == packed(0, 0, 64), "i64");
static_assert(bits_isize(0) == packed(USIZE_W, USIZE_W, 0) && bits_isize(-1) == packed(0, 0, USIZE_W), "isize");

@test
fn builtin_bit_counts_at_run_time() {
    let mut v: Vector<u64> = Vector::new();
    v.push(0);
    v.push(1);
    v.push(0xFFFFFFFFFFFFFFFF);
    v.push(0x50);
    let z = v[0];
    let one = v[1];
    let all = v[2];
    let mid = v[3];
    assert_eq(bits_u8(z as u8), packed(8, 8, 0));
    assert_eq(bits_u8(one as u8), packed(0, 7, 1));
    assert_eq(bits_u8((one << 7) as u8), packed(7, 0, 1));
    assert_eq(bits_u8(all as u8), packed(0, 0, 8));
    assert_eq(bits_u8(mid as u8), packed(4, 1, 2));
    assert_eq(bits_u16(z as u16), packed(16, 16, 0));
    assert_eq(bits_u16(one as u16), packed(0, 15, 1));
    assert_eq(bits_u16((one << 15) as u16), packed(15, 0, 1));
    assert_eq(bits_u16(all as u16), packed(0, 0, 16));
    assert_eq(bits_u32(z as u32), packed(32, 32, 0));
    assert_eq(bits_u32(one as u32), packed(0, 31, 1));
    assert_eq(bits_u32((one << 31) as u32), packed(31, 0, 1));
    assert_eq(bits_u32(all as u32), packed(0, 0, 32));
    assert_eq(bits_u64(z), packed(64, 64, 0));
    assert_eq(bits_u64(one), packed(0, 63, 1));
    assert_eq(bits_u64(one << 63), packed(63, 0, 1));
    assert_eq(bits_u64(all), packed(0, 0, 64));
    assert_eq(bits_u64(mid), packed(4, 57, 2));
    assert_eq(bits_usize(z as usize), packed(USIZE_W, USIZE_W, 0));
    assert_eq(bits_usize(one as usize), packed(0, USIZE_W - 1, 1));
    assert_eq(bits_usize((one << (USIZE_W - 1) as u64) as usize), packed(USIZE_W - 1, 0, 1));
    assert_eq(bits_usize(all as usize), packed(0, 0, USIZE_W));
    // Signed values count the two's complement pattern.
    assert_eq(bits_i8(z as i8), packed(8, 8, 0));
    assert_eq(bits_i8(((one << 7) as u8) as i8), packed(7, 0, 1));
    assert_eq(bits_i8((all as u8) as i8), packed(0, 0, 8));
    assert_eq(bits_i16((all as u16) as i16), packed(0, 0, 16));
    assert_eq(bits_i32(one as i32), packed(0, 31, 1));
    assert_eq(bits_i32((all as u32) as i32), packed(0, 0, 32));
    assert_eq(bits_i64(all as i64), packed(0, 0, 64));
    assert_eq(bits_isize((all as usize) as isize), packed(0, 0, USIZE_W));
}

// The built-in integers' wrapping, overflowing, checked and saturating methods at the edges of each width
// (Rust's semantics): MIN, MAX, -1, 0 and 1, a zero divisor, MIN / -1 and MIN * -1, and shift counts at the
// width - 1, the width and the width + 1. Each `fam_*` returns a bit per failed check; the static_asserts run
// it at compile time on the type's MAX and 2, and the test runs the same code in the emitted C with inputs
// from a Vector.
const fn fam_i8(a: i8, b: i8) u32 {
    let z = b - b;
    let one = b / b;
    let m = -a - one;
    let mut bad: u32 = 0;
    if !(a.wrapping_add(one) == m) {
        bad = bad | 1u32 << 0;
    }
    if !(m.wrapping_sub(one) == a) {
        bad = bad | 1u32 << 1;
    }
    if !(a.wrapping_mul(b) == -b) {
        bad = bad | 1u32 << 2;
    }
    if !(m.wrapping_neg() == m) {
        bad = bad | 1u32 << 3;
    }
    if !(one.wrapping_neg() == -one) {
        bad = bad | 1u32 << 4;
    }
    if !((-one).wrapping_shl(8 + 1) == -b) {
        bad = bad | 1u32 << 5;
    }
    if !(m.wrapping_shr(8 + 1) == m / b) {
        bad = bad | 1u32 << 6;
    }
    let (r7, o7) = a.overflowing_add(one);
    if !(r7 == m && o7) {
        bad = bad | 1u32 << 7;
    }
    let (r8, o8) = m.overflowing_sub(one);
    if !(r8 == a && o8) {
        bad = bad | 1u32 << 8;
    }
    let (r9, o9) = a.overflowing_mul(b);
    if !(r9 == -b && o9) {
        bad = bad | 1u32 << 9;
    }
    let (r10, o10) = b.overflowing_mul(-b);
    if !(r10 == -b * b && !o10) {
        bad = bad | 1u32 << 10;
    }
    if !(a.checked_add(one).is_none() && b.checked_add(b).unwrap() == b * b) {
        bad = bad | 1u32 << 11;
    }
    if !(m.checked_sub(one).is_none() && m.checked_sub(-one).unwrap() == m + one) {
        bad = bad | 1u32 << 12;
    }
    if !(a.checked_mul(b).is_none() && (-b).checked_mul(b).unwrap() == -b * b) {
        bad = bad | 1u32 << 13;
    }
    if !(m.checked_div(-one).is_none() && a.checked_div(z).is_none() && m.checked_div(b).unwrap() == m / b) {
        bad = bad | 1u32 << 14;
    }
    if !(m.checked_rem(-one).is_none() && a.checked_rem(z).is_none() && a.checked_rem(b).unwrap() == one) {
        bad = bad | 1u32 << 15;
    }
    if !(m.checked_neg().is_none() && a.checked_neg().unwrap() == -a) {
        bad = bad | 1u32 << 16;
    }
    if !(one.checked_shl(8).is_none() && one.checked_shl(8 - 1).unwrap() == m) {
        bad = bad | 1u32 << 17;
    }
    if !(m.checked_shr(8).is_none() && (-one).checked_shr(8 - 1).unwrap() == -one) {
        bad = bad | 1u32 << 18;
    }
    if !(a.saturating_add(one) == a && m.saturating_add(-one) == m && b.saturating_add(b) == b * b) {
        bad = bad | 1u32 << 19;
    }
    if !(m.saturating_sub(one) == m && a.saturating_sub(-one) == a && b.saturating_sub(b) == z) {
        bad = bad | 1u32 << 20;
    }
    if !(a.saturating_mul(b) == a && a.saturating_mul(-b) == m && m.saturating_mul(-one) == a && b.saturating_mul(-b) == -b * b) {
        bad = bad | 1u32 << 21;
    }
    if !(one.wrapping_shl(8) == one && one.wrapping_shl(8 - 1) == m && m.wrapping_shr(8) == m && m.wrapping_shr(8 - 1) == -one && a.wrapping_shr(
        8 - 1,
    ) == z) {
        bad = bad | 1u32 << 22;
    }
    let (r23, o23) = m.overflowing_mul(-one);
    if !(m.checked_mul(-one).is_none() && m.wrapping_mul(-one) == m && r23 == m && o23 && m.checked_mul(z).unwrap() == z && m.checked_div(
        one,
    ).unwrap() == m && z.checked_div(-one).unwrap() == z && m.checked_rem(one).unwrap() == z && a.checked_sub(z).unwrap() == a) {
        bad = bad | 1u32 << 23;
    }
    return bad;
}
const fn fam_i16(a: i16, b: i16) u32 {
    let z = b - b;
    let one = b / b;
    let m = -a - one;
    let mut bad: u32 = 0;
    if !(a.wrapping_add(one) == m) {
        bad = bad | 1u32 << 0;
    }
    if !(m.wrapping_sub(one) == a) {
        bad = bad | 1u32 << 1;
    }
    if !(a.wrapping_mul(b) == -b) {
        bad = bad | 1u32 << 2;
    }
    if !(m.wrapping_neg() == m) {
        bad = bad | 1u32 << 3;
    }
    if !(one.wrapping_neg() == -one) {
        bad = bad | 1u32 << 4;
    }
    if !((-one).wrapping_shl(16 + 1) == -b) {
        bad = bad | 1u32 << 5;
    }
    if !(m.wrapping_shr(16 + 1) == m / b) {
        bad = bad | 1u32 << 6;
    }
    let (r7, o7) = a.overflowing_add(one);
    if !(r7 == m && o7) {
        bad = bad | 1u32 << 7;
    }
    let (r8, o8) = m.overflowing_sub(one);
    if !(r8 == a && o8) {
        bad = bad | 1u32 << 8;
    }
    let (r9, o9) = a.overflowing_mul(b);
    if !(r9 == -b && o9) {
        bad = bad | 1u32 << 9;
    }
    let (r10, o10) = b.overflowing_mul(-b);
    if !(r10 == -b * b && !o10) {
        bad = bad | 1u32 << 10;
    }
    if !(a.checked_add(one).is_none() && b.checked_add(b).unwrap() == b * b) {
        bad = bad | 1u32 << 11;
    }
    if !(m.checked_sub(one).is_none() && m.checked_sub(-one).unwrap() == m + one) {
        bad = bad | 1u32 << 12;
    }
    if !(a.checked_mul(b).is_none() && (-b).checked_mul(b).unwrap() == -b * b) {
        bad = bad | 1u32 << 13;
    }
    if !(m.checked_div(-one).is_none() && a.checked_div(z).is_none() && m.checked_div(b).unwrap() == m / b) {
        bad = bad | 1u32 << 14;
    }
    if !(m.checked_rem(-one).is_none() && a.checked_rem(z).is_none() && a.checked_rem(b).unwrap() == one) {
        bad = bad | 1u32 << 15;
    }
    if !(m.checked_neg().is_none() && a.checked_neg().unwrap() == -a) {
        bad = bad | 1u32 << 16;
    }
    if !(one.checked_shl(16).is_none() && one.checked_shl(16 - 1).unwrap() == m) {
        bad = bad | 1u32 << 17;
    }
    if !(m.checked_shr(16).is_none() && (-one).checked_shr(16 - 1).unwrap() == -one) {
        bad = bad | 1u32 << 18;
    }
    if !(a.saturating_add(one) == a && m.saturating_add(-one) == m && b.saturating_add(b) == b * b) {
        bad = bad | 1u32 << 19;
    }
    if !(m.saturating_sub(one) == m && a.saturating_sub(-one) == a && b.saturating_sub(b) == z) {
        bad = bad | 1u32 << 20;
    }
    if !(a.saturating_mul(b) == a && a.saturating_mul(-b) == m && m.saturating_mul(-one) == a && b.saturating_mul(-b) == -b * b) {
        bad = bad | 1u32 << 21;
    }
    if !(one.wrapping_shl(16) == one && one.wrapping_shl(16 - 1) == m && m.wrapping_shr(16) == m && m.wrapping_shr(
        16 - 1,
    ) == -one && a.wrapping_shr(16 - 1) == z) {
        bad = bad | 1u32 << 22;
    }
    let (r23, o23) = m.overflowing_mul(-one);
    if !(m.checked_mul(-one).is_none() && m.wrapping_mul(-one) == m && r23 == m && o23 && m.checked_mul(z).unwrap() == z && m.checked_div(
        one,
    ).unwrap() == m && z.checked_div(-one).unwrap() == z && m.checked_rem(one).unwrap() == z && a.checked_sub(z).unwrap() == a) {
        bad = bad | 1u32 << 23;
    }
    return bad;
}
const fn fam_i32(a: i32, b: i32) u32 {
    let z = b - b;
    let one = b / b;
    let m = -a - one;
    let mut bad: u32 = 0;
    if !(a.wrapping_add(one) == m) {
        bad = bad | 1u32 << 0;
    }
    if !(m.wrapping_sub(one) == a) {
        bad = bad | 1u32 << 1;
    }
    if !(a.wrapping_mul(b) == -b) {
        bad = bad | 1u32 << 2;
    }
    if !(m.wrapping_neg() == m) {
        bad = bad | 1u32 << 3;
    }
    if !(one.wrapping_neg() == -one) {
        bad = bad | 1u32 << 4;
    }
    if !((-one).wrapping_shl(32 + 1) == -b) {
        bad = bad | 1u32 << 5;
    }
    if !(m.wrapping_shr(32 + 1) == m / b) {
        bad = bad | 1u32 << 6;
    }
    let (r7, o7) = a.overflowing_add(one);
    if !(r7 == m && o7) {
        bad = bad | 1u32 << 7;
    }
    let (r8, o8) = m.overflowing_sub(one);
    if !(r8 == a && o8) {
        bad = bad | 1u32 << 8;
    }
    let (r9, o9) = a.overflowing_mul(b);
    if !(r9 == -b && o9) {
        bad = bad | 1u32 << 9;
    }
    let (r10, o10) = b.overflowing_mul(-b);
    if !(r10 == -b * b && !o10) {
        bad = bad | 1u32 << 10;
    }
    if !(a.checked_add(one).is_none() && b.checked_add(b).unwrap() == b * b) {
        bad = bad | 1u32 << 11;
    }
    if !(m.checked_sub(one).is_none() && m.checked_sub(-one).unwrap() == m + one) {
        bad = bad | 1u32 << 12;
    }
    if !(a.checked_mul(b).is_none() && (-b).checked_mul(b).unwrap() == -b * b) {
        bad = bad | 1u32 << 13;
    }
    if !(m.checked_div(-one).is_none() && a.checked_div(z).is_none() && m.checked_div(b).unwrap() == m / b) {
        bad = bad | 1u32 << 14;
    }
    if !(m.checked_rem(-one).is_none() && a.checked_rem(z).is_none() && a.checked_rem(b).unwrap() == one) {
        bad = bad | 1u32 << 15;
    }
    if !(m.checked_neg().is_none() && a.checked_neg().unwrap() == -a) {
        bad = bad | 1u32 << 16;
    }
    if !(one.checked_shl(32).is_none() && one.checked_shl(32 - 1).unwrap() == m) {
        bad = bad | 1u32 << 17;
    }
    if !(m.checked_shr(32).is_none() && (-one).checked_shr(32 - 1).unwrap() == -one) {
        bad = bad | 1u32 << 18;
    }
    if !(a.saturating_add(one) == a && m.saturating_add(-one) == m && b.saturating_add(b) == b * b) {
        bad = bad | 1u32 << 19;
    }
    if !(m.saturating_sub(one) == m && a.saturating_sub(-one) == a && b.saturating_sub(b) == z) {
        bad = bad | 1u32 << 20;
    }
    if !(a.saturating_mul(b) == a && a.saturating_mul(-b) == m && m.saturating_mul(-one) == a && b.saturating_mul(-b) == -b * b) {
        bad = bad | 1u32 << 21;
    }
    if !(one.wrapping_shl(32) == one && one.wrapping_shl(32 - 1) == m && m.wrapping_shr(32) == m && m.wrapping_shr(
        32 - 1,
    ) == -one && a.wrapping_shr(32 - 1) == z) {
        bad = bad | 1u32 << 22;
    }
    let (r23, o23) = m.overflowing_mul(-one);
    if !(m.checked_mul(-one).is_none() && m.wrapping_mul(-one) == m && r23 == m && o23 && m.checked_mul(z).unwrap() == z && m.checked_div(
        one,
    ).unwrap() == m && z.checked_div(-one).unwrap() == z && m.checked_rem(one).unwrap() == z && a.checked_sub(z).unwrap() == a) {
        bad = bad | 1u32 << 23;
    }
    return bad;
}
const fn fam_i64(a: i64, b: i64) u32 {
    let z = b - b;
    let one = b / b;
    let m = -a - one;
    let mut bad: u32 = 0;
    if !(a.wrapping_add(one) == m) {
        bad = bad | 1u32 << 0;
    }
    if !(m.wrapping_sub(one) == a) {
        bad = bad | 1u32 << 1;
    }
    if !(a.wrapping_mul(b) == -b) {
        bad = bad | 1u32 << 2;
    }
    if !(m.wrapping_neg() == m) {
        bad = bad | 1u32 << 3;
    }
    if !(one.wrapping_neg() == -one) {
        bad = bad | 1u32 << 4;
    }
    if !((-one).wrapping_shl(64 + 1) == -b) {
        bad = bad | 1u32 << 5;
    }
    if !(m.wrapping_shr(64 + 1) == m / b) {
        bad = bad | 1u32 << 6;
    }
    let (r7, o7) = a.overflowing_add(one);
    if !(r7 == m && o7) {
        bad = bad | 1u32 << 7;
    }
    let (r8, o8) = m.overflowing_sub(one);
    if !(r8 == a && o8) {
        bad = bad | 1u32 << 8;
    }
    let (r9, o9) = a.overflowing_mul(b);
    if !(r9 == -b && o9) {
        bad = bad | 1u32 << 9;
    }
    let (r10, o10) = b.overflowing_mul(-b);
    if !(r10 == -b * b && !o10) {
        bad = bad | 1u32 << 10;
    }
    if !(a.checked_add(one).is_none() && b.checked_add(b).unwrap() == b * b) {
        bad = bad | 1u32 << 11;
    }
    if !(m.checked_sub(one).is_none() && m.checked_sub(-one).unwrap() == m + one) {
        bad = bad | 1u32 << 12;
    }
    if !(a.checked_mul(b).is_none() && (-b).checked_mul(b).unwrap() == -b * b) {
        bad = bad | 1u32 << 13;
    }
    if !(m.checked_div(-one).is_none() && a.checked_div(z).is_none() && m.checked_div(b).unwrap() == m / b) {
        bad = bad | 1u32 << 14;
    }
    if !(m.checked_rem(-one).is_none() && a.checked_rem(z).is_none() && a.checked_rem(b).unwrap() == one) {
        bad = bad | 1u32 << 15;
    }
    if !(m.checked_neg().is_none() && a.checked_neg().unwrap() == -a) {
        bad = bad | 1u32 << 16;
    }
    if !(one.checked_shl(64).is_none() && one.checked_shl(64 - 1).unwrap() == m) {
        bad = bad | 1u32 << 17;
    }
    if !(m.checked_shr(64).is_none() && (-one).checked_shr(64 - 1).unwrap() == -one) {
        bad = bad | 1u32 << 18;
    }
    if !(a.saturating_add(one) == a && m.saturating_add(-one) == m && b.saturating_add(b) == b * b) {
        bad = bad | 1u32 << 19;
    }
    if !(m.saturating_sub(one) == m && a.saturating_sub(-one) == a && b.saturating_sub(b) == z) {
        bad = bad | 1u32 << 20;
    }
    if !(a.saturating_mul(b) == a && a.saturating_mul(-b) == m && m.saturating_mul(-one) == a && b.saturating_mul(-b) == -b * b) {
        bad = bad | 1u32 << 21;
    }
    if !(one.wrapping_shl(64) == one && one.wrapping_shl(64 - 1) == m && m.wrapping_shr(64) == m && m.wrapping_shr(
        64 - 1,
    ) == -one && a.wrapping_shr(64 - 1) == z) {
        bad = bad | 1u32 << 22;
    }
    let (r23, o23) = m.overflowing_mul(-one);
    if !(m.checked_mul(-one).is_none() && m.wrapping_mul(-one) == m && r23 == m && o23 && m.checked_mul(z).unwrap() == z && m.checked_div(
        one,
    ).unwrap() == m && z.checked_div(-one).unwrap() == z && m.checked_rem(one).unwrap() == z && a.checked_sub(z).unwrap() == a) {
        bad = bad | 1u32 << 23;
    }
    return bad;
}
const fn fam_isize(a: isize, b: isize) u32 {
    let z = b - b;
    let one = b / b;
    let m = -a - one;
    let mut bad: u32 = 0;
    if !(a.wrapping_add(one) == m) {
        bad = bad | 1u32 << 0;
    }
    if !(m.wrapping_sub(one) == a) {
        bad = bad | 1u32 << 1;
    }
    if !(a.wrapping_mul(b) == -b) {
        bad = bad | 1u32 << 2;
    }
    if !(m.wrapping_neg() == m) {
        bad = bad | 1u32 << 3;
    }
    if !(one.wrapping_neg() == -one) {
        bad = bad | 1u32 << 4;
    }
    if !((-one).wrapping_shl(sizeof(isize) as u32 * 8 + 1) == -b) {
        bad = bad | 1u32 << 5;
    }
    if !(m.wrapping_shr(sizeof(isize) as u32 * 8 + 1) == m / b) {
        bad = bad | 1u32 << 6;
    }
    let (r7, o7) = a.overflowing_add(one);
    if !(r7 == m && o7) {
        bad = bad | 1u32 << 7;
    }
    let (r8, o8) = m.overflowing_sub(one);
    if !(r8 == a && o8) {
        bad = bad | 1u32 << 8;
    }
    let (r9, o9) = a.overflowing_mul(b);
    if !(r9 == -b && o9) {
        bad = bad | 1u32 << 9;
    }
    let (r10, o10) = b.overflowing_mul(-b);
    if !(r10 == -b * b && !o10) {
        bad = bad | 1u32 << 10;
    }
    if !(a.checked_add(one).is_none() && b.checked_add(b).unwrap() == b * b) {
        bad = bad | 1u32 << 11;
    }
    if !(m.checked_sub(one).is_none() && m.checked_sub(-one).unwrap() == m + one) {
        bad = bad | 1u32 << 12;
    }
    if !(a.checked_mul(b).is_none() && (-b).checked_mul(b).unwrap() == -b * b) {
        bad = bad | 1u32 << 13;
    }
    if !(m.checked_div(-one).is_none() && a.checked_div(z).is_none() && m.checked_div(b).unwrap() == m / b) {
        bad = bad | 1u32 << 14;
    }
    if !(m.checked_rem(-one).is_none() && a.checked_rem(z).is_none() && a.checked_rem(b).unwrap() == one) {
        bad = bad | 1u32 << 15;
    }
    if !(m.checked_neg().is_none() && a.checked_neg().unwrap() == -a) {
        bad = bad | 1u32 << 16;
    }
    if !(one.checked_shl(sizeof(isize) as u32 * 8).is_none() && one.checked_shl(sizeof(isize) as u32 * 8 - 1).unwrap() == m) {
        bad = bad | 1u32 << 17;
    }
    if !(m.checked_shr(sizeof(isize) as u32 * 8).is_none() && (-one).checked_shr(sizeof(isize) as u32 * 8 - 1).unwrap() == -one) {
        bad = bad | 1u32 << 18;
    }
    if !(a.saturating_add(one) == a && m.saturating_add(-one) == m && b.saturating_add(b) == b * b) {
        bad = bad | 1u32 << 19;
    }
    if !(m.saturating_sub(one) == m && a.saturating_sub(-one) == a && b.saturating_sub(b) == z) {
        bad = bad | 1u32 << 20;
    }
    if !(a.saturating_mul(b) == a && a.saturating_mul(-b) == m && m.saturating_mul(-one) == a && b.saturating_mul(-b) == -b * b) {
        bad = bad | 1u32 << 21;
    }
    if !(one.wrapping_shl(sizeof(isize) as u32 * 8) == one && one.wrapping_shl(sizeof(isize) as u32 * 8 - 1) == m && m.wrapping_shr(
        sizeof(isize) as u32 * 8,
    ) == m && m.wrapping_shr(sizeof(isize) as u32 * 8 - 1) == -one && a.wrapping_shr(sizeof(isize) as u32 * 8 - 1) == z) {
        bad = bad | 1u32 << 22;
    }
    let (r23, o23) = m.overflowing_mul(-one);
    if !(m.checked_mul(-one).is_none() && m.wrapping_mul(-one) == m && r23 == m && o23 && m.checked_mul(z).unwrap() == z && m.checked_div(
        one,
    ).unwrap() == m && z.checked_div(-one).unwrap() == z && m.checked_rem(one).unwrap() == z && a.checked_sub(z).unwrap() == a) {
        bad = bad | 1u32 << 23;
    }
    return bad;
}
const fn fam_u8(a: u8, b: u8) u32 {
    let z = b - b;
    let one = b / b;
    let mut bad: u32 = 0;
    if !(a.wrapping_add(one) == z) {
        bad = bad | 1u32 << 0;
    }
    if !(z.wrapping_sub(one) == a) {
        bad = bad | 1u32 << 1;
    }
    if !(a.wrapping_mul(b) == a - one) {
        bad = bad | 1u32 << 2;
    }
    if !(one.wrapping_neg() == a) {
        bad = bad | 1u32 << 3;
    }
    if !(z.wrapping_neg() == z) {
        bad = bad | 1u32 << 4;
    }
    if !(one.wrapping_shl(8 + 1) == b) {
        bad = bad | 1u32 << 5;
    }
    if !(a.wrapping_shr(8 + 1) == a / b) {
        bad = bad | 1u32 << 6;
    }
    let (r7, o7) = a.overflowing_add(one);
    if !(r7 == z && o7) {
        bad = bad | 1u32 << 7;
    }
    let (r8, o8) = b.overflowing_sub(a);
    if !(r8 == b + one && o8) {
        bad = bad | 1u32 << 8;
    }
    let (r9, o9) = a.overflowing_mul(b);
    if !(r9 == a - one && o9) {
        bad = bad | 1u32 << 9;
    }
    let (r10, o10) = b.overflowing_mul(b);
    if !(r10 == b * b && !o10) {
        bad = bad | 1u32 << 10;
    }
    if !(a.checked_add(one).is_none() && b.checked_add(b).unwrap() == b * b) {
        bad = bad | 1u32 << 11;
    }
    if !(z.checked_sub(one).is_none() && a.checked_sub(a).unwrap() == z) {
        bad = bad | 1u32 << 12;
    }
    if !(a.checked_mul(b).is_none() && b.checked_mul(b).unwrap() == b * b) {
        bad = bad | 1u32 << 13;
    }
    if !(a.checked_div(z).is_none() && a.checked_div(b).unwrap() == a / b) {
        bad = bad | 1u32 << 14;
    }
    if !(a.checked_rem(z).is_none() && a.checked_rem(b).unwrap() == one) {
        bad = bad | 1u32 << 15;
    }
    if !(one.checked_neg().is_none() && z.checked_neg().unwrap() == z) {
        bad = bad | 1u32 << 16;
    }
    if !(one.checked_shl(8).is_none() && one.checked_shl(8 - 1).unwrap() == a / b + one) {
        bad = bad | 1u32 << 17;
    }
    if !(a.checked_shr(8).is_none() && a.checked_shr(8 - 1).unwrap() == one) {
        bad = bad | 1u32 << 18;
    }
    if !(a.saturating_add(one) == a && b.saturating_add(b) == b * b) {
        bad = bad | 1u32 << 19;
    }
    if !(z.saturating_sub(one) == z && b.saturating_sub(one) == one) {
        bad = bad | 1u32 << 20;
    }
    if !(a.saturating_mul(b) == a && b.saturating_mul(b) == b * b) {
        bad = bad | 1u32 << 21;
    }
    if !(one.wrapping_shl(8) == one && one.wrapping_shl(8 - 1) == a / b + one && a.wrapping_shr(8) == a && a.wrapping_shr(
        8 - 1,
    ) == one) {
        bad = bad | 1u32 << 22;
    }
    if !(z.checked_mul(a).unwrap() == z && a.checked_div(one).unwrap() == a && a.checked_rem(one).unwrap() == z && z.checked_add(
        a,
    ).unwrap() == a && a.saturating_sub(a) == z && z.wrapping_sub(a) == one) {
        bad = bad | 1u32 << 23;
    }
    return bad;
}
const fn fam_u16(a: u16, b: u16) u32 {
    let z = b - b;
    let one = b / b;
    let mut bad: u32 = 0;
    if !(a.wrapping_add(one) == z) {
        bad = bad | 1u32 << 0;
    }
    if !(z.wrapping_sub(one) == a) {
        bad = bad | 1u32 << 1;
    }
    if !(a.wrapping_mul(b) == a - one) {
        bad = bad | 1u32 << 2;
    }
    if !(one.wrapping_neg() == a) {
        bad = bad | 1u32 << 3;
    }
    if !(z.wrapping_neg() == z) {
        bad = bad | 1u32 << 4;
    }
    if !(one.wrapping_shl(16 + 1) == b) {
        bad = bad | 1u32 << 5;
    }
    if !(a.wrapping_shr(16 + 1) == a / b) {
        bad = bad | 1u32 << 6;
    }
    let (r7, o7) = a.overflowing_add(one);
    if !(r7 == z && o7) {
        bad = bad | 1u32 << 7;
    }
    let (r8, o8) = b.overflowing_sub(a);
    if !(r8 == b + one && o8) {
        bad = bad | 1u32 << 8;
    }
    let (r9, o9) = a.overflowing_mul(b);
    if !(r9 == a - one && o9) {
        bad = bad | 1u32 << 9;
    }
    let (r10, o10) = b.overflowing_mul(b);
    if !(r10 == b * b && !o10) {
        bad = bad | 1u32 << 10;
    }
    if !(a.checked_add(one).is_none() && b.checked_add(b).unwrap() == b * b) {
        bad = bad | 1u32 << 11;
    }
    if !(z.checked_sub(one).is_none() && a.checked_sub(a).unwrap() == z) {
        bad = bad | 1u32 << 12;
    }
    if !(a.checked_mul(b).is_none() && b.checked_mul(b).unwrap() == b * b) {
        bad = bad | 1u32 << 13;
    }
    if !(a.checked_div(z).is_none() && a.checked_div(b).unwrap() == a / b) {
        bad = bad | 1u32 << 14;
    }
    if !(a.checked_rem(z).is_none() && a.checked_rem(b).unwrap() == one) {
        bad = bad | 1u32 << 15;
    }
    if !(one.checked_neg().is_none() && z.checked_neg().unwrap() == z) {
        bad = bad | 1u32 << 16;
    }
    if !(one.checked_shl(16).is_none() && one.checked_shl(16 - 1).unwrap() == a / b + one) {
        bad = bad | 1u32 << 17;
    }
    if !(a.checked_shr(16).is_none() && a.checked_shr(16 - 1).unwrap() == one) {
        bad = bad | 1u32 << 18;
    }
    if !(a.saturating_add(one) == a && b.saturating_add(b) == b * b) {
        bad = bad | 1u32 << 19;
    }
    if !(z.saturating_sub(one) == z && b.saturating_sub(one) == one) {
        bad = bad | 1u32 << 20;
    }
    if !(a.saturating_mul(b) == a && b.saturating_mul(b) == b * b) {
        bad = bad | 1u32 << 21;
    }
    if !(one.wrapping_shl(16) == one && one.wrapping_shl(16 - 1) == a / b + one && a.wrapping_shr(16) == a && a.wrapping_shr(
        16 - 1,
    ) == one) {
        bad = bad | 1u32 << 22;
    }
    if !(z.checked_mul(a).unwrap() == z && a.checked_div(one).unwrap() == a && a.checked_rem(one).unwrap() == z && z.checked_add(
        a,
    ).unwrap() == a && a.saturating_sub(a) == z && z.wrapping_sub(a) == one) {
        bad = bad | 1u32 << 23;
    }
    return bad;
}
const fn fam_u32(a: u32, b: u32) u32 {
    let z = b - b;
    let one = b / b;
    let mut bad: u32 = 0;
    if !(a.wrapping_add(one) == z) {
        bad = bad | 1u32 << 0;
    }
    if !(z.wrapping_sub(one) == a) {
        bad = bad | 1u32 << 1;
    }
    if !(a.wrapping_mul(b) == a - one) {
        bad = bad | 1u32 << 2;
    }
    if !(one.wrapping_neg() == a) {
        bad = bad | 1u32 << 3;
    }
    if !(z.wrapping_neg() == z) {
        bad = bad | 1u32 << 4;
    }
    if !(one.wrapping_shl(32 + 1) == b) {
        bad = bad | 1u32 << 5;
    }
    if !(a.wrapping_shr(32 + 1) == a / b) {
        bad = bad | 1u32 << 6;
    }
    let (r7, o7) = a.overflowing_add(one);
    if !(r7 == z && o7) {
        bad = bad | 1u32 << 7;
    }
    let (r8, o8) = b.overflowing_sub(a);
    if !(r8 == b + one && o8) {
        bad = bad | 1u32 << 8;
    }
    let (r9, o9) = a.overflowing_mul(b);
    if !(r9 == a - one && o9) {
        bad = bad | 1u32 << 9;
    }
    let (r10, o10) = b.overflowing_mul(b);
    if !(r10 == b * b && !o10) {
        bad = bad | 1u32 << 10;
    }
    if !(a.checked_add(one).is_none() && b.checked_add(b).unwrap() == b * b) {
        bad = bad | 1u32 << 11;
    }
    if !(z.checked_sub(one).is_none() && a.checked_sub(a).unwrap() == z) {
        bad = bad | 1u32 << 12;
    }
    if !(a.checked_mul(b).is_none() && b.checked_mul(b).unwrap() == b * b) {
        bad = bad | 1u32 << 13;
    }
    if !(a.checked_div(z).is_none() && a.checked_div(b).unwrap() == a / b) {
        bad = bad | 1u32 << 14;
    }
    if !(a.checked_rem(z).is_none() && a.checked_rem(b).unwrap() == one) {
        bad = bad | 1u32 << 15;
    }
    if !(one.checked_neg().is_none() && z.checked_neg().unwrap() == z) {
        bad = bad | 1u32 << 16;
    }
    if !(one.checked_shl(32).is_none() && one.checked_shl(32 - 1).unwrap() == a / b + one) {
        bad = bad | 1u32 << 17;
    }
    if !(a.checked_shr(32).is_none() && a.checked_shr(32 - 1).unwrap() == one) {
        bad = bad | 1u32 << 18;
    }
    if !(a.saturating_add(one) == a && b.saturating_add(b) == b * b) {
        bad = bad | 1u32 << 19;
    }
    if !(z.saturating_sub(one) == z && b.saturating_sub(one) == one) {
        bad = bad | 1u32 << 20;
    }
    if !(a.saturating_mul(b) == a && b.saturating_mul(b) == b * b) {
        bad = bad | 1u32 << 21;
    }
    if !(one.wrapping_shl(32) == one && one.wrapping_shl(32 - 1) == a / b + one && a.wrapping_shr(32) == a && a.wrapping_shr(
        32 - 1,
    ) == one) {
        bad = bad | 1u32 << 22;
    }
    if !(z.checked_mul(a).unwrap() == z && a.checked_div(one).unwrap() == a && a.checked_rem(one).unwrap() == z && z.checked_add(
        a,
    ).unwrap() == a && a.saturating_sub(a) == z && z.wrapping_sub(a) == one) {
        bad = bad | 1u32 << 23;
    }
    return bad;
}
const fn fam_u64(a: u64, b: u64) u32 {
    let z = b - b;
    let one = b / b;
    let mut bad: u32 = 0;
    if !(a.wrapping_add(one) == z) {
        bad = bad | 1u32 << 0;
    }
    if !(z.wrapping_sub(one) == a) {
        bad = bad | 1u32 << 1;
    }
    if !(a.wrapping_mul(b) == a - one) {
        bad = bad | 1u32 << 2;
    }
    if !(one.wrapping_neg() == a) {
        bad = bad | 1u32 << 3;
    }
    if !(z.wrapping_neg() == z) {
        bad = bad | 1u32 << 4;
    }
    if !(one.wrapping_shl(64 + 1) == b) {
        bad = bad | 1u32 << 5;
    }
    if !(a.wrapping_shr(64 + 1) == a / b) {
        bad = bad | 1u32 << 6;
    }
    let (r7, o7) = a.overflowing_add(one);
    if !(r7 == z && o7) {
        bad = bad | 1u32 << 7;
    }
    let (r8, o8) = b.overflowing_sub(a);
    if !(r8 == b + one && o8) {
        bad = bad | 1u32 << 8;
    }
    let (r9, o9) = a.overflowing_mul(b);
    if !(r9 == a - one && o9) {
        bad = bad | 1u32 << 9;
    }
    let (r10, o10) = b.overflowing_mul(b);
    if !(r10 == b * b && !o10) {
        bad = bad | 1u32 << 10;
    }
    if !(a.checked_add(one).is_none() && b.checked_add(b).unwrap() == b * b) {
        bad = bad | 1u32 << 11;
    }
    if !(z.checked_sub(one).is_none() && a.checked_sub(a).unwrap() == z) {
        bad = bad | 1u32 << 12;
    }
    if !(a.checked_mul(b).is_none() && b.checked_mul(b).unwrap() == b * b) {
        bad = bad | 1u32 << 13;
    }
    if !(a.checked_div(z).is_none() && a.checked_div(b).unwrap() == a / b) {
        bad = bad | 1u32 << 14;
    }
    if !(a.checked_rem(z).is_none() && a.checked_rem(b).unwrap() == one) {
        bad = bad | 1u32 << 15;
    }
    if !(one.checked_neg().is_none() && z.checked_neg().unwrap() == z) {
        bad = bad | 1u32 << 16;
    }
    if !(one.checked_shl(64).is_none() && one.checked_shl(64 - 1).unwrap() == a / b + one) {
        bad = bad | 1u32 << 17;
    }
    if !(a.checked_shr(64).is_none() && a.checked_shr(64 - 1).unwrap() == one) {
        bad = bad | 1u32 << 18;
    }
    if !(a.saturating_add(one) == a && b.saturating_add(b) == b * b) {
        bad = bad | 1u32 << 19;
    }
    if !(z.saturating_sub(one) == z && b.saturating_sub(one) == one) {
        bad = bad | 1u32 << 20;
    }
    if !(a.saturating_mul(b) == a && b.saturating_mul(b) == b * b) {
        bad = bad | 1u32 << 21;
    }
    if !(one.wrapping_shl(64) == one && one.wrapping_shl(64 - 1) == a / b + one && a.wrapping_shr(64) == a && a.wrapping_shr(
        64 - 1,
    ) == one) {
        bad = bad | 1u32 << 22;
    }
    if !(z.checked_mul(a).unwrap() == z && a.checked_div(one).unwrap() == a && a.checked_rem(one).unwrap() == z && z.checked_add(
        a,
    ).unwrap() == a && a.saturating_sub(a) == z && z.wrapping_sub(a) == one) {
        bad = bad | 1u32 << 23;
    }
    return bad;
}
const fn fam_usize(a: usize, b: usize) u32 {
    let z = b - b;
    let one = b / b;
    let mut bad: u32 = 0;
    if !(a.wrapping_add(one) == z) {
        bad = bad | 1u32 << 0;
    }
    if !(z.wrapping_sub(one) == a) {
        bad = bad | 1u32 << 1;
    }
    if !(a.wrapping_mul(b) == a - one) {
        bad = bad | 1u32 << 2;
    }
    if !(one.wrapping_neg() == a) {
        bad = bad | 1u32 << 3;
    }
    if !(z.wrapping_neg() == z) {
        bad = bad | 1u32 << 4;
    }
    if !(one.wrapping_shl(sizeof(usize) as u32 * 8 + 1) == b) {
        bad = bad | 1u32 << 5;
    }
    if !(a.wrapping_shr(sizeof(usize) as u32 * 8 + 1) == a / b) {
        bad = bad | 1u32 << 6;
    }
    let (r7, o7) = a.overflowing_add(one);
    if !(r7 == z && o7) {
        bad = bad | 1u32 << 7;
    }
    let (r8, o8) = b.overflowing_sub(a);
    if !(r8 == b + one && o8) {
        bad = bad | 1u32 << 8;
    }
    let (r9, o9) = a.overflowing_mul(b);
    if !(r9 == a - one && o9) {
        bad = bad | 1u32 << 9;
    }
    let (r10, o10) = b.overflowing_mul(b);
    if !(r10 == b * b && !o10) {
        bad = bad | 1u32 << 10;
    }
    if !(a.checked_add(one).is_none() && b.checked_add(b).unwrap() == b * b) {
        bad = bad | 1u32 << 11;
    }
    if !(z.checked_sub(one).is_none() && a.checked_sub(a).unwrap() == z) {
        bad = bad | 1u32 << 12;
    }
    if !(a.checked_mul(b).is_none() && b.checked_mul(b).unwrap() == b * b) {
        bad = bad | 1u32 << 13;
    }
    if !(a.checked_div(z).is_none() && a.checked_div(b).unwrap() == a / b) {
        bad = bad | 1u32 << 14;
    }
    if !(a.checked_rem(z).is_none() && a.checked_rem(b).unwrap() == one) {
        bad = bad | 1u32 << 15;
    }
    if !(one.checked_neg().is_none() && z.checked_neg().unwrap() == z) {
        bad = bad | 1u32 << 16;
    }
    if !(one.checked_shl(sizeof(usize) as u32 * 8).is_none() && one.checked_shl(sizeof(usize) as u32 * 8 - 1).unwrap() == a / b + one) {
        bad = bad | 1u32 << 17;
    }
    if !(a.checked_shr(sizeof(usize) as u32 * 8).is_none() && a.checked_shr(sizeof(usize) as u32 * 8 - 1).unwrap() == one) {
        bad = bad | 1u32 << 18;
    }
    if !(a.saturating_add(one) == a && b.saturating_add(b) == b * b) {
        bad = bad | 1u32 << 19;
    }
    if !(z.saturating_sub(one) == z && b.saturating_sub(one) == one) {
        bad = bad | 1u32 << 20;
    }
    if !(a.saturating_mul(b) == a && b.saturating_mul(b) == b * b) {
        bad = bad | 1u32 << 21;
    }
    if !(one.wrapping_shl(sizeof(usize) as u32 * 8) == one && one.wrapping_shl(sizeof(usize) as u32 * 8 - 1) == a / b + one && a.wrapping_shr(
        sizeof(usize) as u32 * 8,
    ) == a && a.wrapping_shr(sizeof(usize) as u32 * 8 - 1) == one) {
        bad = bad | 1u32 << 22;
    }
    if !(z.checked_mul(a).unwrap() == z && a.checked_div(one).unwrap() == a && a.checked_rem(one).unwrap() == z && z.checked_add(
        a,
    ).unwrap() == a && a.saturating_sub(a) == z && z.wrapping_sub(a) == one) {
        bad = bad | 1u32 << 23;
    }
    return bad;
}
static_assert(fam_i8(127, 2) == 0, "i8 methods");
static_assert(fam_i16(32767, 2) == 0, "i16 methods");
static_assert(fam_i32(2147483647, 2) == 0, "i32 methods");
static_assert(fam_i64(9223372036854775807, 2) == 0, "i64 methods");
static_assert(fam_isize(isize::MAX, 2) == 0, "isize methods");
static_assert(fam_u8(255, 2) == 0, "u8 methods");
static_assert(fam_u16(65535, 2) == 0, "u16 methods");
static_assert(fam_u32(4294967295, 2) == 0, "u32 methods");
static_assert(fam_u64(18446744073709551615, 2) == 0, "u64 methods");
static_assert(fam_usize(usize::MAX, 2) == 0, "usize methods");

@test
fn builtin_overflow_methods_at_run_time() {
    let mut v: Vector<u64> = Vector::new();
    v.push(0xFFFFFFFFFFFFFFFF);
    v.push(2);
    let all = v[0];
    let two = v[1];
    assert_eq(fam_i8((all >> 57) as i8, two as i8), 0);
    assert_eq(fam_i16((all >> 49) as i16, two as i16), 0);
    assert_eq(fam_i32((all >> 33) as i32, two as i32), 0);
    assert_eq(fam_i64((all >> 1) as i64, two as i64), 0);
    assert_eq(fam_isize((all as usize >> 1) as isize, two as isize), 0);
    assert_eq(fam_u8(all as u8, two as u8), 0);
    assert_eq(fam_u16(all as u16, two as u16), 0);
    assert_eq(fam_u32(all as u32, two as u32), 0);
    assert_eq(fam_u64(all, two), 0);
    assert_eq(fam_usize(all as usize, two as usize), 0);
}

// The wide counts run per limb on the u64 counts: limb boundaries and a partial top limb.
@test
fn wide_bit_counts_per_limb() {
    let hi = u256::one() << 200;
    assert_eq(hi.trailing_zeros(), 200);
    assert_eq(hi.leading_zeros(), 55);
    assert_eq(hi.count_ones(), 1);
    assert_eq(u256::max().count_ones(), 256);
    assert_eq(u256::zero().leading_zeros(), 256);
    let p = UInt::<100>::one() << 99;
    assert_eq(p.leading_zeros(), 0);
    assert_eq(p.trailing_zeros(), 99);
    assert_eq(UInt::<100>::max().count_ones(), 100);
    assert_eq(UInt::<100>::zero().trailing_zeros(), 100);
    assert_eq(i256::from_i64(-1).count_ones(), 256);
    assert_eq(i256::from_i64(-8).trailing_zeros(), 3);
}

// The run-time division of wide integers (Algorithm D, `div2by1`) satisfies its identity: q b + r = a and
// r < b, which fixes q and r. Random operands of each limb count, with limbs that stress the estimate
// (0, 1, all ones, the top bit alone), at whole-limb and partial-limb widths.
fn check_division<const W: usize>(seed: u64, n: usize) {
    let mut s = seed;
    let nl = UInt::<W>::limbs();
    for _ in 0..n {
        let mut v: [UInt<W>; 2] = [UInt::<W>::zero(), UInt::<W>::zero()];
        for k in 0..2 {
            s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            let live = 1 + (s >> 33) as usize % nl;
            for i in 0..live {
                s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                let pick = s >> 60;
                let l = if pick == 0 {
                    0u64;
                } else if pick == 1 {
                    0xFFFFFFFFFFFFFFFF;
                } else if pick == 2 {
                    0x8000000000000000;
                } else if pick == 3 {
                    1u64;
                } else {
                    s ^ s << 17;
                };
                unsafe v[k].set_limb(i, l);
            }
        }
        let a = v[0];
        let b = v[1];
        if b.is_zero() {
            continue;
        }
        let mut r = UInt::<W>::zero();
        let q = a.divmod(&b, &mut r);
        assert(r < b, "the remainder is below the divisor");
        switch q.checked_mul(&b) {
            Some(qb) => {
                switch qb.checked_add(&r) {
                    Some(t) => assert(t == a, "q b + r is the dividend"),
                    None => assert(false, "q b + r overflows"),
                };
            },
            None => assert(false, "q b overflows"),
        };
    }
}

@test
fn division_satisfies_its_identity() {
    check_division::<192>(1, 20000);
    check_division::<200>(2, 20000);
    check_division::<240>(3, 20000);
    check_division::<256>(4, 20000);
    check_division::<512>(5, 20000);
}

// Compile time (the limb code: the interpreter has no 128-bit type) and run time (the C compiler's
// 128-bit division where it has one) divide 256-bit values alike, at the estimate's corners and at random.
const DIV_DECLS: str<'static> = "fn w(a: u64, b: u64, c: u64, d: u64) UInt<256> {\n    let mut x = UInt::<256>::zero();\n    x.set_limb(0, a);\n    x.set_limb(1, b);\n    x.set_limb(2, c);\n    x.set_limb(3, d);\n    return x;\n}\nfn dv(a0: u64, a1: u64, a2: u64, a3: u64, b0: u64, b1: u64, b2: u64, b3: u64) u64 {\n    let a = w(a0, a1, a2, a3);\n    let b = w(b0, b1, b2, b3);\n    let mut r = UInt::<256>::zero();\n    let q = a.divmod(&b, &mut r);\n    let mut h: u64 = 0xcbf29ce484222325;\n    for i in 0usize..4 {\n        h = (h ^ q.limb(i)).wrapping_mul(0x100000001b3);\n        h = (h ^ r.limb(i)).wrapping_mul(0x100000001b3);\n    }\n    return h;\n}\n";

@test
fn division_is_the_same_at_compile_time() {
    let exprs = [
        "dv(opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x8000000000000000), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x1), opq::<u64>(0x0), opq::<u64>(0x8000000000000000), opq::<u64>(0x0))",
        "dv(opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x8000000000000000), opq::<u64>(0x1), opq::<u64>(0x0), opq::<u64>(0x8000000000000000), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x0), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x8000000000000000), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x3), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x2), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0xFFFFFFFFFFFFFFFF))",
        "dv(opq::<u64>(0x3039), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x1), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x7FFFFFFF00000000), opq::<u64>(0x8000), opq::<u64>(0x1), opq::<u64>(0x0), opq::<u64>(0x8000), opq::<u64>(0x0))",
        "dv(opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0xFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x1), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x8000000000000000), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x0), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x0), opq::<u64>(0xD3AC94AF0F21DDB6), opq::<u64>(0x39263059F28C105D), opq::<u64>(0xF29D0DA9953F48F1), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x1), opq::<u64>(0x100000000), opq::<u64>(0x8000000000000000))",
        "dv(opq::<u64>(0xD0EDA82F8F6D0558), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x94E3BF911A61DBE2), opq::<u64>(0x5F557203301850C5), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x34B9B5DF9E7769B1), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x6D76B07E881ED162), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x5C90A9587403E430), opq::<u64>(0x100000000), opq::<u64>(0x100000000), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x8000000000000000), opq::<u64>(0x72E6CC3ABABCED20), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x8000000000000000), opq::<u64>(0xAB1031D0F646E1F4), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0xD17F9ACAE01F5057), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x7F26144B98289FCD), opq::<u64>(0x119A72D174C9DF6A), opq::<u64>(0x451ABD81F1D69ED6), opq::<u64>(0x0), opq::<u64>(0x10A3D6B2AA05E11A), opq::<u64>(0xFFFFFFFF), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x0))",
        "dv(opq::<u64>(0xAB2CD31EE3151288), opq::<u64>(0x8000000000000000), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x1), opq::<u64>(0x100000000))",
        "dv(opq::<u64>(0x8000000000000000), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x230D977EE2257159), opq::<u64>(0x8CDB305FDD2E1609), opq::<u64>(0x8000000000000000), opq::<u64>(0xE25A7605AEC6F024))",
        "dv(opq::<u64>(0x1), opq::<u64>(0xFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x8000000000000000), opq::<u64>(0x43435CC52EAE05CF), opq::<u64>(0x1), opq::<u64>(0x9C1CAAF75E8766ED))",
        "dv(opq::<u64>(0xF341E07A83F73F16), opq::<u64>(0xBD628881AD1B72DB), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x100000000), opq::<u64>(0xAE3A2B7FDFE01893), opq::<u64>(0x65E7E4236472F1A3), opq::<u64>(0x0))",
        "dv(opq::<u64>(0xFFFFFFFF), opq::<u64>(0x113DB17D30CBC97D), opq::<u64>(0x298CB3A570CCEC31), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x19F9919C895FD7B3), opq::<u64>(0x68739FA9D1DE2A0), opq::<u64>(0x1))",
        "dv(opq::<u64>(0x58EE8571F4998D7C), opq::<u64>(0x1F7296AB7961FD92), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x8000000000000000), opq::<u64>(0x7AFB2C68774B15D7), opq::<u64>(0x24E4E25A15FC899E), opq::<u64>(0xFFFFFFFFFFFFFFFF))",
        "dv(opq::<u64>(0x842E7FC229540A6E), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0xFFFFFFFF), opq::<u64>(0xC215A82A06EC41AD), opq::<u64>(0xA49636A2FA7F0EAB), opq::<u64>(0xD86F40F6B239F3C7), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x8AA4248C8857F9A4), opq::<u64>(0xA2EDDBBD5464ECC2), opq::<u64>(0x100000000), opq::<u64>(0x0), opq::<u64>(0xDA45E18AC2216B02), opq::<u64>(0x1), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x8000000000000000), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x4787F93BCA44EB86), opq::<u64>(0xB1491E243192B704), opq::<u64>(0x727D83495822CB77), opq::<u64>(0xFCF00FECB91EE9E5))",
        "dv(opq::<u64>(0x0), opq::<u64>(0x1), opq::<u64>(0x8000000000000000), opq::<u64>(0x0), opq::<u64>(0x9C3A23CDE67A9B75), opq::<u64>(0xE8C147437ABEC539), opq::<u64>(0xA4A45EFFCCB573D9), opq::<u64>(0x0))",
        "dv(opq::<u64>(0xB6246771C8450070), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0xE39639BE7A605A91), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x16353D03551FD8F9), opq::<u64>(0xB8C9817AF8BE8831), opq::<u64>(0x8000000000000000), opq::<u64>(0xB98C67C215BD448F), opq::<u64>(0x1), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0xFAF55496988AF3FB), opq::<u64>(0x59B44E92EFFDDEEA), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0xA6511445B9F3635C), opq::<u64>(0xFFFFFFFF))",
        "dv(opq::<u64>(0xD37EE91531DEC4F4), opq::<u64>(0x40783F0A072A98D2), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0xF977044218E0B7B), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0xE77FFE48D0A6EC17), opq::<u64>(0xEAEFC4D2D3BF6D01), opq::<u64>(0x8825AE562179B37D), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x8000000000000000), opq::<u64>(0x101B8119BCA3CB7), opq::<u64>(0x2C1EEA1F265974A7), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x8E752FDF1ECE615D), opq::<u64>(0xFFFFFFFF), opq::<u64>(0x7B8444D18E317041), opq::<u64>(0xE21B37CA1B29FC99), opq::<u64>(0x30F970583F9D52F9), opq::<u64>(0x100000000), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0xE4DDF9B9C28EE907), opq::<u64>(0x535B6A437178BA0A), opq::<u64>(0x9B2BD6C0816BEE06), opq::<u64>(0x46F5A1B4B156D1AD), opq::<u64>(0xCEAF4915888564E8), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0xE040015CE064A114), opq::<u64>(0xEC3B96054274A3EB), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x33DCD77FF179F2D2), opq::<u64>(0x6AA8B9E0231B3E14), opq::<u64>(0x8000000000000000), opq::<u64>(0xFFFFFFFF))",
        "dv(opq::<u64>(0xFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0xF08360852789D059), opq::<u64>(0x5DBE3023A906922F), opq::<u64>(0x1), opq::<u64>(0xBF268EA03836E865), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x8000000000000000), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x626467BA04A10547), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x15850A031AD2D5F1), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x453BF4912E7A26E9), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0xD1A89B37AD0C9BB6), opq::<u64>(0x263CFA5E67EC326A), opq::<u64>(0x9212824C83C8CB28), opq::<u64>(0x16E6FEC353B97377), opq::<u64>(0x100000000), opq::<u64>(0xE53169606CE193C2), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x16AC4191A26AA0AE), opq::<u64>(0x9BB183E11570266B), opq::<u64>(0x43B30F66110E2CB6), opq::<u64>(0x0), opq::<u64>(0x2F4B342742A8063), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x9F27F52C449274D2), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x1C0502C6F0290531), opq::<u64>(0xCE5AF69430B91ED), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0xC26E7A4287F53DDD), opq::<u64>(0x8000000000000000), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x0), opq::<u64>(0x3EDB92009758340), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x83A4E62930803889), opq::<u64>(0x72723B9CEF44C0D5), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0xD5A9422A8BC08311), opq::<u64>(0x81B62BB5F86664AE), opq::<u64>(0x1), opq::<u64>(0x32D90DCD57BB7D97), opq::<u64>(0xBA958810B4EBF4B6), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0xDEC6823FB5C9D56), opq::<u64>(0x121AE3E603A63966), opq::<u64>(0x416E99B0E13E213E), opq::<u64>(0x15A0CCE60E2EC40A), opq::<u64>(0xDEDB9109618177FF), opq::<u64>(0x482CC78EF88EDE10), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x1), opq::<u64>(0x8000000000000000), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0xFC2325A9F8FDD208), opq::<u64>(0x8D180113E940BB4), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0xA7F0C99E80B5244A), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x43A08F0617420E94), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x0), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x1), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0xC8B6EAFFB74B589B), opq::<u64>(0xC3A9E88963B759F5), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x8000000000000000), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x250E7B34A4AA07B4), opq::<u64>(0x100000000), opq::<u64>(0xA098D6918352BC85), opq::<u64>(0x0), opq::<u64>(0xCFED943BB3783A7C), opq::<u64>(0x8614F504E8EE65A1), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x0), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0xD5F860C3606A0DEB), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x880CB401A0506098), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x4387EE7B7D42646F), opq::<u64>(0x100000000), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0xA8C7D9E01789819F))",
        "dv(opq::<u64>(0x0), opq::<u64>(0xBAB5B3733C1AE917), opq::<u64>(0xBD65680C3B1185D9), opq::<u64>(0x7E736D5F75D8D8A4), opq::<u64>(0x7AA068F113A5397F), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x32C32444A48C1D5C), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x1), opq::<u64>(0xFFFFFFFF), opq::<u64>(0x9F03BC5A4DEE4812), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x44CE4AB37C5D42DC), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0xB1330C3F197A14E2), opq::<u64>(0x8000000000000000), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0xC4653CDE776200B5), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x4A227F39047B2C10), opq::<u64>(0x81B1C025D1E4D0A3), opq::<u64>(0xFE749E67730F37F1), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x1), opq::<u64>(0x0), opq::<u64>(0x7FFFFFFFFFFFFFFF), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x100000000), opq::<u64>(0xE30966194791C2E9), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x64E276027C73B6C9), opq::<u64>(0x0), opq::<u64>(0x736506ECAE7C8F09), opq::<u64>(0x24056360BA28A679), opq::<u64>(0x50EA7DA760487E15), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x65F456AAD6CFF718), opq::<u64>(0x1), opq::<u64>(0xBD6A996DE6CD10F1), opq::<u64>(0x0), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0x100000000), opq::<u64>(0xECE807995C57722E), opq::<u64>(0xDAB0792946709312), opq::<u64>(0x0), opq::<u64>(0xFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "dv(opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x3099F27150CB407A), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0xF4C73F2BC8FF1C38), opq::<u64>(0xCFDCC257076D490A), opq::<u64>(0xE9D625C966692158), opq::<u64>(0x0))",
    ];
    let tys: [str; 60] = ["u64"; 60];
    let d = h::const_runtime_parity(DIV_DECLS, exprs[0..60], tys[0..60], []);
    if d.len() != 0 {
        eprintln("{}", d.as_str());
    }
    assert(d.len() == 0, "a quotient or remainder differs between compile time and run time");
}

// Random operands with a random count of live limbs, each limb 0, 1, all ones, the top bit alone or random
// bits: the short and full lengths the multiplication and division loops take.
fn rand_uint<const W: usize>(s: &mut u64) UInt<W> {
    let nl = UInt::<W>::limbs();
    *s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    let live = 1 + (*s >> 33) as usize % nl;
    let mut v = UInt::<W>::zero();
    for i in 0..live {
        *s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let pick = *s >> 60;
        let l = if pick == 0 {
            0u64;
        } else if pick == 1 {
            0xFFFFFFFFFFFFFFFF;
        } else if pick == 2 {
            0x8000000000000000;
        } else if pick == 3 {
            1u64;
        } else {
            *s ^ *s << 17;
        };
        v.set_limb(i, l);
    }
    return v;
}

// Every multiplication path (the whole width or the top nonzero limbs only, the overflow flag, the full
// product, the signed one through magnitudes) against division, which shares none of their code, and
// against the exact product of the sign-extended values in twice the width.
fn check_multiplication<const W: usize>(seed: u64, n: usize) {
    let mut s = seed;
    for _ in 0..n {
        let a = rand_uint::<W>(&mut s);
        let b = rand_uint::<W>(&mut s);
        let full = a.full_mul(&b);
        let mut hi = UInt::<W>::zero();
        let lo = a.widening_mul(&b, &mut hi);
        let top = full.shr(W);
        assert(
            UInt::<W>::cast_unsigned(&full) == lo && UInt::<W>::cast_unsigned(&top) == hi,
            "full_mul is widening_mul's halves",
        );
        let fits = hi.is_zero();
        let (w, o) = a.overflowing_mul(&b);
        assert(
            w == lo && o == !fits,
            "the wrapped product is the low half, and it overflows when the high half is not zero",
        );
        assert(a.checked_mul(&b).is_some() == fits, "checked_mul overflows exactly where the product does not fit");
        if !b.is_zero() {
            let wa = UInt::<{2 * W}>::widen(&a);
            let wb = UInt::<{2 * W}>::widen(&b);
            let mut r = UInt::<{2 * W}>::zero();
            let q = full.divmod(&wb, &mut r);
            assert(r.is_zero() && q == wa, "the full product divided by b is a");
        }
        let ia = Int::<W>::from_unsigned(&a);
        let ib = Int::<W>::from_unsigned(&b);
        let sa = Int::<{2 * W}>::widen(&ia);
        let sb = Int::<{2 * W}>::widen(&ib);
        // Exact: each magnitude is at most 2^(W-1), the product's at most 2^(2W-2).
        let p = sa.wrapping_mul(&sb);
        let narrow = Int::<W>::cast_signed(&p);
        let exact = Int::<{2 * W}>::widen(&narrow) == p;
        let (sw, so) = ia.overflowing_mul(&ib);
        assert(
            sw == narrow && so == !exact,
            "the signed product wraps to the low half and overflows when that changes it",
        );
        assert(
            ia.checked_mul(&ib).is_some() == exact,
            "the signed checked_mul overflows exactly where the product does not fit",
        );
        if !ib.is_zero() {
            let mut r = Int::<{2 * W}>::zero();
            let q = p.divmod(&sb, &mut r);
            assert(r.is_zero() && q == sa, "the signed product divided by b is a");
        }
    }
}

@test
fn multiplication_matches_division() {
    check_multiplication::<64>(1, 3000);
    check_multiplication::<70>(2, 3000);
    check_multiplication::<128>(3, 3000);
    check_multiplication::<130>(4, 3000);
    check_multiplication::<256>(5, 3000);
    check_multiplication::<320>(6, 3000);
    check_multiplication::<1000>(7, 1000);
}

// Digits against the division operator taking one digit at a time, and back through the parser, in
// every radix; signed values through their magnitude.
fn check_text<const W: usize>(seed: u64, n: usize) {
    let mut s = seed;
    for _ in 0..n {
        let v = rand_uint::<W>(&mut s);
        s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let radix = 2 + (s >> 40) as u32 % 35;
        let t = v.to_string_radix(radix);
        let rr = UInt::<W>::from_u64(radix);
        let mut rev = Vector::<u8>::new();
        let mut x = v;
        for _ in 0..W + 1 {
            let d = (x % rr).to_u64() as u8;
            if d < 10 {
                rev.push(b'0' + d);
            } else {
                rev.push(b'a' + d - 10);
            }
            x = x / rr;
            if x.is_zero() {
                break;
            }
        }
        let mut want = String::new();
        for i in 0..rev.len() {
            want.push_byte(rev[rev.len() - 1 - i]);
        }
        assert(t.as_str() == want.as_str(), "the digits are the remainders of repeated division");
        switch UInt::<W>::from_str_radix(t.as_str(), radix) {
            Some(back) => assert(back == v, "the digits parse back to the value"),
            None => assert(false, "the digits parse"),
        };
        let iv = Int::<W>::from_unsigned(&v);
        let it = iv.to_string_radix(radix);
        switch Int::<W>::from_str_radix(it.as_str(), radix) {
            Some(back) => assert(back == iv, "the signed digits parse back to the value"),
            None => assert(false, "the signed digits parse"),
        };
    }
    // The ends of the range: max parses, one more digit overflows.
    let m = UInt::<W>::max().to_string();
    assert(UInt::<W>::from_str(m.as_str()).unwrap() == UInt::<W>::max(), "max parses");
    let mut over = String::from_str(m.as_str());
    over.push_byte(b'0');
    assert(UInt::<W>::from_str(over.as_str()).is_none(), "ten times max overflows");
}

@test
fn text_matches_repeated_division() {
    check_text::<64>(11, 1500);
    check_text::<70>(12, 1500);
    check_text::<128>(13, 1500);
    check_text::<200>(14, 1500);
    check_text::<512>(15, 800);
    check_text::<1000>(16, 300);
}

// The float casts against the float formats' own integer bridges, a separate rounding path: the value
// rounded once to f64 or f32 (infinite past the range), and a double's integer part, saturating.
fn check_float_casts<const W: usize>(seed: u64, n: usize) {
    let mut s = seed;
    for _ in 0..n {
        let v = rand_uint::<W>(&mut s);
        let want = Float::<11, 52>::from_uint(&v).to_f64();
        assert(f64_bits(v.to_f64()) == f64_bits(want), "to_f64 rounds once");
        let want32 = Float::<8, 23>::from_uint(&v).to_f32();
        assert(f32_bits(v.to_f32()) == f32_bits(want32), "to_f32 rounds once");
        let iv = Int::<W>::from_unsigned(&v);
        assert(
            f64_bits(iv.to_f64()) == f64_bits(Float::<11, 52>::from_int(&iv).to_f64()),
            "the signed to_f64 rounds once",
        );
        s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let d = f64_from_bits(s ^ s >> 29);
        let mut u = UInt::<W>::zero();
        Float::<11, 52>::from_f64(d).to_uint(&mut u);
        assert(UInt::<W>::from_f64(d) == u, "from_f64 is the saturated integer part");
        let mut i = Int::<W>::zero();
        Float::<11, 52>::from_f64(d).to_int(&mut i);
        assert(Int::<W>::from_f64(d) == i, "the signed from_f64 is the saturated integer part");
    }
}

@test
fn float_casts_match_the_float_formats() {
    check_float_casts::<64>(21, 3000);
    check_float_casts::<70>(22, 3000);
    check_float_casts::<256>(23, 3000);
    check_float_casts::<1100>(24, 1000);
    check_float_casts::<2000>(25, 500);
}

// Bit and byte reversal against the bits and bytes themselves.
fn check_reverse_bits<const W: usize>(seed: u64, n: usize) {
    let mut s = seed;
    for _ in 0..n {
        let v = rand_uint::<W>(&mut s);
        let r = v.reverse_bits();
        for i in 0..W {
            assert(r.bit(i) == v.bit(W - 1 - i), "bit i of the reversal is bit W - 1 - i");
        }
        assert(Int::<W>::from_unsigned(&v).reverse_bits().to_unsigned() == r, "the signed reversal is the same bits");
    }
}

fn check_swap_bytes<const W: usize>(seed: u64, n: usize) {
    let mut s = seed;
    let mut le = Array::<u8, 256>::new();
    let mut be = Array::<u8, 256>::new();
    for _ in 0..n {
        let v = rand_uint::<W>(&mut s);
        v.swap_bytes().to_le_bytes(le.index_range_mut(0usize..256));
        v.to_be_bytes(be.index_range_mut(0usize..256));
        for i in 0..W / 8 {
            assert(le[i] == be[i], "the swapped bytes little-endian are the value big-endian");
        }
    }
}

@test
fn reversal_matches_the_bits_and_bytes() {
    check_reverse_bits::<8>(31, 500);
    check_reverse_bits::<70>(32, 500);
    check_reverse_bits::<128>(33, 500);
    check_reverse_bits::<200>(34, 500);
    check_swap_bytes::<8>(35, 500);
    check_swap_bytes::<24>(36, 500);
    check_swap_bytes::<128>(37, 500);
    check_swap_bytes::<200>(38, 500);
    check_swap_bytes::<1024>(39, 200);
}

// Compile time (the limb code: the interpreter has no 128-bit type) and run time compute the products,
// comparisons, digits, reversals, parsing and float casts of 320-bit values, and f128's arithmetic,
// remainder, root and parsing, alike. No digit output: a `String` past its inline bytes switches its
// union's member, which compile time refuses.
const ARITH_DECLS: str<'static> = "fn u(a: u64, b: u64, c: u64, d: u64) UInt<320> {\n    let mut x = UInt::<320>::zero();\n    x.set_limb(0, a);\n    x.set_limb(1, b);\n    x.set_limb(2, c);\n    x.set_limb(3, d);\n    x.set_limb(4, a ^ d);\n    return x;\n}\nfn mix(h: u64, v: u64) u64 {\n    return (h ^ v).wrapping_mul(0x100000001b3);\n}\nfn mh(a0: u64, a1: u64, a2: u64, a3: u64, b0: u64, b1: u64, b2: u64, b3: u64) u64 {\n    let a = u(a0, a1, a2, a3);\n    let b = u(b0, b1, b2, b3);\n    let mut h: u64 = 0xcbf29ce484222325;\n    let (w, o) = a.overflowing_mul(&b);\n    let f = a.full_mul(&b);\n    let ib = Int::<320>::from_unsigned(&b);\n    let (sw, so) = Int::<320>::from_unsigned(&a).overflowing_mul(&ib);\n    for i in 0usize..5 {\n        h = mix(h, w.limb(i));\n        h = mix(h, sw.limb(i));\n        h = mix(h, a.reverse_bits().limb(i));\n        h = mix(h, a.swap_bytes().limb(i));\n    }\n    for i in 0usize..10 {\n        h = mix(h, f.limb(i));\n    }\n    h = mix(h, o as u64 * 2 + so as u64 + (a < b) as u64 * 4 + (a == b) as u64 * 8);\n    let t = UInt::<320>::from_str(\"98765432109876543210987654321098765432109876543210\").unwrap();\n    h = mix(h, t.wrapping_mul(&a).limb(2));\n    h = mix(h, Int::<320>::from_str_radix(\"-1z2y3x4w5v6u7t8s9r0q\", 36).unwrap().wrapping_mul(&ib).limb(4));\n    h = mix(h, (a.to_f64() / 1.0e70) as u64);\n    h = mix(h, (b.to_f32() as f64 / 1.0e20) as u64);\n    h = mix(h, UInt::<320>::from_f64((a0 >> 11) as f64 * 1.0e80).limb(2));\n    return h;\n}\nfn fh(a0: u64, a1: u64, b0: u64, b1: u64) u64 {\n    let mut ra = UInt::<128>::from_u64(a0);\n    ra.set_limb(1, a1);\n    let mut rb = UInt::<128>::from_u64(b0);\n    rb.set_limb(1, b1);\n    let x = f128::from_raw(ra);\n    let y = f128::from_raw(rb);\n    let mut h: u64 = 0xcbf29ce484222325;\n    let rs: [f128; 6] = [x + y, x * y, x / y, x % y, x.abs().sqrt(), x.fma(&y, &x)];\n    for i in 0usize..6 {\n        h = mix(h, unsafe rs[i].to_raw().limb(0));\n        h = mix(h, unsafe rs[i].to_raw().limb(1));\n    }\n    h = mix(h, f128::from_str(\"-3.14159265358979323846e-12\").unwrap().to_raw().limb(0));\n    let w = f256::convert(&x);\n    h = mix(h, w.abs().sqrt().to_raw().limb(1));\n    return h;\n}\n";

@test
fn arithmetic_is_the_same_at_compile_time() {
    let exprs = [
        "mh(opq::<u64>(0x0), opq::<u64>(0xA9D9A5102EC74699), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x2D22BF79964DC0C2), opq::<u64>(0xFA8C2E87ECDC92F9), opq::<u64>(0x903E33C18CC9C5BC), opq::<u64>(0xFFFFFFFFFFFFFFFF))",
        "mh(opq::<u64>(0x8000000000000000), opq::<u64>(0x8000000000000000), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x730EF045E7849B99), opq::<u64>(0x8000000000000000), opq::<u64>(0x0), opq::<u64>(0x0))",
        "mh(opq::<u64>(0x8000000000000000), opq::<u64>(0x0), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x823B2BA861B03F5E), opq::<u64>(0xE65B58E37EBC9B7F), opq::<u64>(0x2A04BA6EC48129D3), opq::<u64>(0x0))",
        "mh(opq::<u64>(0x5A5154E852970EB0), opq::<u64>(0x522BDE78CCA127EC), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x120869525DB0A043), opq::<u64>(0x8000000000000000), opq::<u64>(0x8000000000000000), opq::<u64>(0xF8551A9F6AA87BC2))",
        "mh(opq::<u64>(0x0), opq::<u64>(0x4B4DD2C6A0590485), opq::<u64>(0x4E02AACA28937405), opq::<u64>(0xAD5F3CDCC410B377), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x8000000000000000), opq::<u64>(0x4A2258CF016C9F04), opq::<u64>(0x7DCA4029C477816E))",
        "mh(opq::<u64>(0x8000000000000000), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x8000000000000000), opq::<u64>(0xA68D469617EF709C), opq::<u64>(0x26C23B4CD86BA1AB), opq::<u64>(0x0))",
        "mh(opq::<u64>(0xF23238E7EBD23378), opq::<u64>(0x8000000000000000), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0xDCE35E0912AF33A4), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "mh(opq::<u64>(0x8000000000000000), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x13C33EB3828B7FF5), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x1), opq::<u64>(0x806327EFCFE4E6CD))",
        "mh(opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x1), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "mh(opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x4FA645C775CC5898), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "mh(opq::<u64>(0x5DA81A027F7BA251), opq::<u64>(0x7075BE75052FEFA4), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0xFD1B777A694DD72F), opq::<u64>(0x1DE6B801A9F74FBC), opq::<u64>(0x0), opq::<u64>(0x398C48CAB17EDF08))",
        "mh(opq::<u64>(0x8000000000000000), opq::<u64>(0x1), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0xF0E9B88D04DDF229), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x4AF4002006FCFFCE))",
        "mh(opq::<u64>(0x675BB47CCACFAF2), opq::<u64>(0x8000000000000000), opq::<u64>(0x0), opq::<u64>(0x8B0E9FE5A0CF17EE), opq::<u64>(0x3B838553DCE0F872), opq::<u64>(0x1), opq::<u64>(0x1BBA9DC38585720F), opq::<u64>(0x0))",
        "mh(opq::<u64>(0x758A81996B7D602E), opq::<u64>(0x7AA6E2A65D764819), opq::<u64>(0xDCD911339F9B0C7B), opq::<u64>(0x0), opq::<u64>(0x20A0CDF29A643C7A), opq::<u64>(0x8B053B3D868726B6), opq::<u64>(0x2573EE6853159F5), opq::<u64>(0x49717DBF837CA269))",
        "mh(opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x5BF47A7549D325EE), opq::<u64>(0x70E23B7DCC4B94A6), opq::<u64>(0x609464D891B6A6DF), opq::<u64>(0xDB05ECE45EE2C6F0))",
        "mh(opq::<u64>(0x8000000000000000), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x1CCCB18A82D5EBCB), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x0), opq::<u64>(0x0))",
        "mh(opq::<u64>(0x3044FCAF57B3E0A4), opq::<u64>(0x12CAF664433D55D6), opq::<u64>(0x928DE214FE81CAFA), opq::<u64>(0xB05E0B2DBED3B3CD), opq::<u64>(0x6621972FC5D751D9), opq::<u64>(0xD52BF801450711BD), opq::<u64>(0x6C7D78632C89EDA9), opq::<u64>(0x1))",
        "mh(opq::<u64>(0x99E868CB3FC87D16), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x1), opq::<u64>(0x1), opq::<u64>(0xABA5FC68B7888F65), opq::<u64>(0xE1B4FCB8E8807D99))",
        "mh(opq::<u64>(0x6A3DBED3FE55C105), opq::<u64>(0xACACA2B7BAED662C), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0xE5C475595FBE161F), opq::<u64>(0x5A08F8466D9E8C81), opq::<u64>(0x0), opq::<u64>(0x0))",
        "mh(opq::<u64>(0xE656E6FD4AF0C356), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x16672BA4765E47D2), opq::<u64>(0x1), opq::<u64>(0xAEB3CA4DA0A84075), opq::<u64>(0x0))",
        "mh(opq::<u64>(0x0), opq::<u64>(0x6F139E6E0546D1F8), opq::<u64>(0x58E97F0FB6ED4511), opq::<u64>(0x1), opq::<u64>(0x1), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "mh(opq::<u64>(0x6D2442B2182F57FD), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x8000000000000000), opq::<u64>(0x1), opq::<u64>(0xF62694B877E609E5), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x8000000000000000), opq::<u64>(0x5075833ABB1DA260))",
        "mh(opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x37F74C807B068811), opq::<u64>(0xC9B96A648560B6CC), opq::<u64>(0x794C429CD7E15323), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0), opq::<u64>(0x0))",
        "mh(opq::<u64>(0x38F5AFD569C4CDBF), opq::<u64>(0x0), opq::<u64>(0x1), opq::<u64>(0xFFFFFFFFFFFFFFFF), opq::<u64>(0x219A4E9519ED6218), opq::<u64>(0x5140AD8FF4EC6488), opq::<u64>(0xB94ED20A5BC871A6), opq::<u64>(0x0))",
        "fh(opq::<u64>(0xC8764D7EDB5586AE), opq::<u64>(0x40D8DA22336DA9D8), opq::<u64>(0x1053383AC7EC2C92), opq::<u64>(0x401CBDA5DD0FC8A0))",
        "fh(opq::<u64>(0x1D969E0ECA8B4382), opq::<u64>(0x405AB777D53C68DB), opq::<u64>(0xE56ECF8E042D32C), opq::<u64>(0x4020F51E9E1165C6))",
        "fh(opq::<u64>(0xD9CF7D3CFB5FDD8E), opq::<u64>(0x3FF0A2ADECB1488C), opq::<u64>(0x8A28448EBB4E152C), opq::<u64>(0xBFF57E9C820E815B))",
        "fh(opq::<u64>(0xCC32BF8BDD5600CA), opq::<u64>(0xC16AF10620555E7D), opq::<u64>(0x1C6557E6A3E85CC2), opq::<u64>(0xBFF31AEF13739877))",
        "fh(opq::<u64>(0xC0B2EBC79B5DE5E8), opq::<u64>(0x414F3F95D1933512), opq::<u64>(0x8C292A31E02E3377), opq::<u64>(0x3FE3C430805903BB))",
        "fh(opq::<u64>(0xE7D2B1A0AE7F4D8A), opq::<u64>(0x400BDEA2AFDA794B), opq::<u64>(0xD23F529B0016B6EC), opq::<u64>(0xBFECFD7113C8B5DD))",
        "fh(opq::<u64>(0x1735AD5DC91B192C), opq::<u64>(0xBFE7C5F8A0228DF8), opq::<u64>(0xAF0E9E6EC362ABF), opq::<u64>(0xC0026301916EC3EA))",
        "fh(opq::<u64>(0xF5D1402D8C35E468), opq::<u64>(0x3FF4AC5BB677BE97), opq::<u64>(0x4B5FF9E5E6FC1C13), opq::<u64>(0xBFE18C0818E96C55))",
        "fh(opq::<u64>(0xC5FAA47AB55CAECB), opq::<u64>(0xC0C9D16575ADDD99), opq::<u64>(0xE78A9BC33A74EB91), opq::<u64>(0xC015DA07FCC3A242))",
        "fh(opq::<u64>(0xD7B599DC833325E5), opq::<u64>(0xC1560400DE60A8A9), opq::<u64>(0x84E603F26E402FFB), opq::<u64>(0x4016708132960410))",
        "fh(opq::<u64>(0xAD62C4F89275E82B), opq::<u64>(0x401BC3EBD375BC4A), opq::<u64>(0xBBA1B2A93290DED0), opq::<u64>(0x401A57F8FC221A97))",
        "fh(opq::<u64>(0x4E476C0A1E375F9D), opq::<u64>(0xC096600367904403), opq::<u64>(0x9A70A6B336CA211), opq::<u64>(0x4006FD88E4FC8FDF))",
    ];
    let tys: [str; 36] = ["u64"; 36];
    let d = h::const_runtime_parity(ARITH_DECLS, exprs[0..36], tys[0..36], []);
    if d.len() != 0 {
        eprintln("{}", d.as_str());
    }
    assert(d.len() == 0, "an integer or f128 result differs between compile time and run time");
}
