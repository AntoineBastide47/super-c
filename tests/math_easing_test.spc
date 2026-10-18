// std::math::easing: every function at 0.5 in f32 and f64, then bit-exact values at 0.3 (f32) and 0.8
// (f64), the ends of the interval, the explicit overshoot forms, the panics on inputs outside [0, 1], and
// constant initializers.
import std::math::scalar as *;
import std::math::easing as *;

fn every_easing<T: Float>(a: T) [T; 31] {
    return [
        linear_interpolation(a),
        quadratic_ease_in(a),
        quadratic_ease_out(a),
        quadratic_ease_in_out(a),
        cubic_ease_in(a),
        cubic_ease_out(a),
        cubic_ease_in_out(a),
        quartic_ease_in(a),
        quartic_ease_out(a),
        quartic_ease_in_out(a),
        quintic_ease_in(a),
        quintic_ease_out(a),
        quintic_ease_in_out(a),
        sine_ease_in(a),
        sine_ease_out(a),
        sine_ease_in_out(a),
        circular_ease_in(a),
        circular_ease_out(a),
        circular_ease_in_out(a),
        exponential_ease_in(a),
        exponential_ease_out(a),
        exponential_ease_in_out(a),
        elastic_ease_in(a),
        elastic_ease_out(a),
        elastic_ease_in_out(a),
        back_ease_in(a),
        back_ease_out(a),
        back_ease_in_out(a),
        bounce_ease_in(a),
        bounce_ease_out(a),
        bounce_ease_in_out(a),
    ];
}

@test
fn easing_at_half() {
    let f = every_easing(0.5f32);
    let d = every_easing(0.5f64);
    for i in 0..31 {
        assert(!(unsafe f[i]).is_nan());
        assert(!(unsafe d[i]).is_nan());
    }
}

// The results at 0.3 as f32 bits and at 0.8 as f64 bits, in `every_easing` order.
const BITS_F32: [u32; 31] = [
    0x3e99999a,
    0x3db851ec,
    0x3f028f5d,
    0x3e3851ec,
    0x3cdd2f1c,
    0x3f283127,
    0x3ddd2f1c,
    0x3c04b5de,
    0x3f4288ce,
    0x3d84b5de,
    0x3b1f40a4,
    0x3f54f95e,
    0x3d1f40a4,
    0x3ddf37f8,
    0x3ee87173,
    0x3e530dd2,
    0x3d3caa40,
    0x3f36d211,
    0x3dcccccc,
    0x3c000000,
    0x3f600000,
    0x3d000000,
    0xbaa03034,
    0x3f6064dc,
    0xbc1e3755,
    0xbda43fa9,
    0x3f6839d2,
    0xbda17372,
    0x3daa7f00,
    0x3f2e3d72,
    0x3d5d2f00,
];

const BITS_F64: [u64; 31] = [
    0x3fe999999999999a,
    0x3fe47ae147ae147c,
    0x3feeb851eb851eb8,
    0x3fed70a3d70a3d70,
    0x3fe0624dd2f1a9fd,
    0x3fefbe76c8b43958,
    0x3feef9db22d0e560,
    0x3fda36e2eb1c432f,
    0x3feff2e48e8a71de,
    0x3fef972474538ef3,
    0x3fd4f8b588e368f3,
    0x3feffd60e94ee393,
    0x3fefd60e94ee392e,
    0x3fe61c8864680b59,
    0x3fee6f0e134454ff,
    0x3fecf1bbcdcbfa54,
    0x3fd999999999999c,
    0x3fef5a7cecdb684a,
    0x3feeaa0bc744186b,
    0x3fd0000000000001,
    0x3fefe00000000000,
    0x3fefc00000000000,
    0xbfc2cf2304755a74,
    0x3ff00cf1bbcdcbfa,
    0x3fefc321e3d97756,
    0x3fd2d422d77069cb,
    0x3ff0be42f1414b4f,
    0x3ff17b1ba3b946f8,
    0x3fe651eb851eb853,
    0x3fed3119d752db30,
    0x3feba1cac083126c,
];

@test
fn easing_bits() {
    let f = every_easing(0.3f32);
    let d = every_easing(0.8f64);
    for i in 0..31 {
        assert_eq(f32_bits(unsafe f[i]), unsafe BITS_F32[i]);
        assert_eq(f64_bits(unsafe d[i]), unsafe BITS_F64[i]);
    }
}

@test
fn overshoot_forms() {
    assert_eq(f32_bits(back_ease_in_overshoot(0.3f32, 2.5)), 0xbe05a1cbu32);
    assert_eq(f32_bits(back_ease_out_overshoot(0.3f32, 2.5)), 0x3f8322d1u32);
    assert_eq(f32_bits(back_ease_in_out_overshoot(0.3f32, 2.5)), 0xbe2a7efau32);
    assert_eq(back_ease_in_overshoot(0.6f64, 1.70158), back_ease_in(0.6f64));
    assert_eq(back_ease_out_overshoot(0.6f64, 1.70158), back_ease_out(0.6f64));
    assert_eq(back_ease_in_out_overshoot(0.6f64, 1.70158), back_ease_in_out(0.6f64));
}

@test
fn interval_ends() {
    let zero = every_easing(0.0f64);
    let one = every_easing(1.0f64);
    for i in 0..31 {
        assert((unsafe zero[i]).abs() < 1e-3);
        assert((unsafe one[i] - 1.0).abs() < 1e-3);
    }
    assert_eq(exponential_ease_in(0.0f32), 0.0);
    assert_eq(exponential_ease_out(1.0f32), 1.0);
}

@test(should_panic)
fn input_below_zero_panics() {
    let _ = quadratic_ease_in(-0.25f32);
}

@test(should_panic)
fn input_above_one_panics() {
    let _ = bounce_ease_out(1.5f64);
}

@test(should_panic)
fn nan_input_panics() {
    let _ = sine_ease_in_out(f32::nan());
}

const EASED: f64 = elastic_ease_in_out(0.8f64);

@test
fn constant_initializers() {
    assert_eq(f64_bits(EASED), 0x3fefc321e3d97756u64);
}
