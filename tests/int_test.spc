// `std::num::int` -- the arbitrary-width fixed integers. What is worth testing here is the places the limb
// representation shows through: a carry crossing a limb boundary, a borrow crossing it the other way, a
// product wider than one limb, the sign bit at the top of the top limb, and the ends of each range.
// Widths are exercised at 128, 256 and 512 bits so the monomorphizer produces more than one instantiation.

import std::num::int as *;

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
