// `std::int` (a prelude module) -- the arbitrary-width fixed integers. What is worth testing here is the places the limb
// representation shows through: a carry crossing a limb boundary, a borrow crossing it the other way, a
// product wider than one limb, the sign bit at the top of the top limb, and the ends of each range.
// Widths are exercised at 128, 256 and 512 bits so the monomorphizer produces more than one instantiation.

// These read like the built-in integers: a prelude module, so the aliases need no import, and an integer
// literal or a `u64`/`i64` value converts through the `From` conformances wherever one is expected.
@test
fn reads_like_a_builtin_integer() {
    let a: u128 = 42;
    assert_eq(a.to_u64(), 42u64);
    // literal as an operand, on both sides of a comparison
    assert((a + 1).to_u64() == 43u64);
    assert(a == 42);
    assert(a > 41);
    assert(a < 43);
    // a built-in value widens into it, and the arithmetic then happens at the wide width
    let n: u64 = 0xFFFFFFFFFFFFFFFF;
    let wide: u128 = n;
    let sum = wide + 2;
    let s = sum.to_string();
    assert(s.as_str() == "18446744073709551617");
    s.free();
    // signed, including a negative literal
    let neg: i128 = -5;
    assert(neg < i128::zero());
    assert(neg + 5 == i128::zero());
}

// Widths convert like the built-in integers too. Implicitly only WIDENING, which is lossless -- the
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
    // as: down, across signedness, and to a built-in
    let big = u256::from_u64(0xFFFFFFFFFFFFFFFF) + 1;
    let low = big as u128;
    assert(low.limb(0) == 0);
    assert(low.limb(1) == 1);
    let n: i128 = -1;
    assert(n as u128 == u128::max()); // two's complement reinterpret, as C casts do
    assert((n as u256).limb(3) == 0xFFFFFFFFFFFFFFFF); // sign-extends because the SOURCE is signed
    assert(a as u64 == 7u64);
    assert(a as u32 == 7u32);
    assert(i128::from_i64(-2) as i64 == -2i64);
}

// Float casts round ONCE: the top 64 bits carry a sticky bit, so the single u64 conversion rounds
// exactly as converting the full value would -- limb-by-limb accumulation would round at every step.
// The float-to-integer direction truncates and SATURATES (NaN gives zero), as Rust's float casts do.
@test
fn float_casts_round_once_and_saturate() {
    assert(u128::from_u64(7) as f64 == 7.0);
    assert(7.0 as u128 == u128::from_u64(7));
    // 2^127 - 1 rounds up to 2^127 exactly; without the sticky bit it rounds wrong
    assert((u128::max() >> 1) as f64 == 170141183460469231731687303715884105728.0);
    // a large power of two is exact and round-trips
    let p = u128::one() << 100;
    assert((p as f64) as u128 == p);
    // signed, negative, fractional, and out-of-range saturation
    assert(i128::from_i64(-9) as f64 == -9.0);
    assert((0.0 - 9.75) as i128 == i128::from_i64(-9));
    assert(1.0e60 as u128 == u128::max());
    assert(((0.0 - 3.5) as u128).is_zero());
    assert(1.0e60 as i128 == i128::max());
    assert((0.0 - 1.0e60) as i128 == i128::min());
    // f32 has its own path, not a double round through f64
    assert(u128::from_u64(16777217) as f32 == 16777216.0f32); // rounds to even at 24 bits
}

// A width need not be a whole number of limbs: the top limb's unused bits stay zero (an invariant the
// one limb-write site enforces), so every operation wraps at exactly BITS. The float formats depend on
// this -- Float<5, 10> stores 16 bits.
@test
fn partial_limb_widths() {
    // 16-bit: wraps at 16, and checked arithmetic sees the true carry
    let one16 = UInt::<16>::one();
    let m16 = UInt::<16>::from_u64(65535);
    assert(m16.wrapping_add(&one16).is_zero());
    assert(m16.checked_add(&one16).is_none());
    let s16 = m16.to_string();
    assert(s16.as_str() == "65535");
    s16.free();
    // 100-bit: the carry crosses limb 0 into the partial limb, and overflow detection sees bit 100
    let big = UInt::<100>::max();
    let one100 = UInt::<100>::one();
    let two100 = UInt::<100>::from_u64(2);
    assert(big.wrapping_add(&one100).is_zero());
    assert_eq(big.bit_length(), 100);
    assert_eq(big.count_ones(), 100);
    assert(big.checked_mul(&two100).is_none());
    // division and the full product at a partial width
    let three = UInt::<100>::from_u64(3);
    let mut r100 = UInt::<100>::zero();
    let q = big.divmod(&three, &mut r100);
    let qs = q.to_string();
    assert(qs.as_str() == "422550200076076467165567735125");
    qs.free();
    let f = UInt::<100>::from_u64(0xFFFFFFFFFFFFFFFF);
    let p = f.full_mul(&f);
    let ps = p.to_string();
    assert(ps.as_str() == "340282366920938463426481119284349108225");
    ps.free();
    // signed 20-bit: the sign bit sits mid-limb, and every signed operation reads it there
    let m = Int::<20>::from_i64(-3);
    assert_eq(m.to_i64(), -3i64);
    assert(m.is_negative());
    assert_eq(m.shr(1).to_i64(), -2i64);
    assert_eq(Int::<20>::min().to_i64(), -524288i64);
    assert_eq(Int::<20>::max().to_i64(), 524287i64);
    // widening across a mid-limb boundary sign-extends through it
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
    // and a borrow back across it
    let z = u128::zero();
    assert(z - one == u128::max());
}

@test
fn unsigned_wraps_like_the_builtin_types() {
    let mx = u128::max();
    let one = u128::one();
    assert(mx.wrapping_add(&one).is_zero());
    assert(mx.checked_add(&one).is_none());
    assert(mx.saturating_add(&one) == mx);
    assert(u128::zero().saturating_sub(&one).is_zero());
    assert(u128::zero().checked_sub(&one).is_none());
}

@test
fn multiplication_spans_limbs() {
    let a = u128::from_u64(1000000007);
    let b = u128::from_u64(1000000009);
    let p = a * b;
    let s = p.to_string();
    assert(s.as_str() == "1000000016000000063");
    s.free();
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
    sqs.free();
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
    qs.free();
    assert_eq(r.to_u64(), 1u64);
    // q * b + r == a
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
    assert(one.shl(128).is_zero()); // shifting past the width discards, as the builtins do
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
    // and the compound forms, which lower to `x = x.op(y)`
    let mut acc = a;
    acc &= b;
    assert(acc == (a & b));
    acc |= u128::from_u64(0xF);
    assert(acc == (a & b | u128::from_u64(0xF)));
    acc ^= acc;
    assert(acc.is_zero());
    // signed values reach the same operators
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
    s.free();
    let mut r = i128::zero();
    let q = p.divmod(&b, &mut r);
    assert(q == a);
    assert(r.is_zero());
    // sign extension: a negative 64-bit value fills every limb above it
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
    mx.free();
    let s = "-670390396497129854978701249910292306373968291029619668886178072186088201503677348840093714908345229483";
    switch i512::from_str(s) {
        Some(v) => {
            let back = v.to_string();
            assert(back.as_str() == s);
            back.free();
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
    z.free();
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
    f.free();
    // and they work as Map keys, which is what Hash + Eq are for
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
    m.free();
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
// the width -- the latter through a const-generic EXPRESSION, `UInt<{BITS * 2}>`.
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
    s.free();
    // and a width the aliases do not name, to show the expression is computed rather than looked up
    let b = UInt::<192>::from_u64(0xFFFFFFFFFFFFFFFF);
    let w = b.full_mul(&b);
    assert_eq(UInt::<384>::limbs(), 6);
    let ws = w.to_string();
    assert(ws.as_str() == "340282366920938463426481119284349108225");
    ws.free();
}

// Widening composes: the result of one full product feeds the next, and the width the signature promises
// is the one that arrives -- `{(B * 2) * 2}` and `{B * 4}` are the same width, not two that look alike.
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
    s.free();
}
