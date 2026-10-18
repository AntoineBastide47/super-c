// `std::math::elementary`: the exponential, trigonometric and reciprocal trigonometric functions on
// scalars and vectors, their special values (NaN, infinities, exact results), and constant evaluation
// that gives the run-time bits.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::common as *;
import std::math::elementary as *;

// `abs(x - y) <= eps`.
fn near<T: Float>(x: T, y: T, eps: T) bool {
    return abs(x - y).less_equal(eps);
}

fn near_v<T: Float, const N: usize>(x: Vec<T, N>, y: Vec<T, N>, eps: T) bool {
    for i in 0..N {
        if !near(x[i], y[i], eps) {
            return false;
        }
    }
    return true;
}

// The scalar result and the dvec1 result both near `e`.
fn both(s: f64, v: dvec1, e: f64) bool {
    return near(s, e, 0.01) && near(v.x(), e, 0.01);
}

@test
fn pow_sqrt_exp_log() {
    assert(near(pow(2.0f32, 2.0f32), 4.0, 0.01));
    assert(near_v(pow(vec1::splat(2.0), vec1::splat(2.0)), vec1::splat(4.0), 0.01));
    assert(near_v(pow(vec2::splat(2.0), vec2::splat(2.0)), vec2::splat(4.0), 0.01));
    assert(near_v(pow(vec3::splat(2.0), vec3::splat(2.0)), vec3::splat(4.0), 0.01));
    assert(near_v(pow(vec4::splat(2.0), vec4::splat(2.0)), vec4::splat(4.0), 0.01));
    assert(near(sqrt(4.0f32), 2.0, 0.01));
    assert(near_v(sqrt(vec1::splat(4.0)), vec1::splat(2.0), 0.01));
    assert(near_v(sqrt(vec2::splat(4.0)), vec2::splat(2.0), 0.01));
    assert(near_v(sqrt(vec3::splat(4.0)), vec3::splat(2.0), 0.01));
    assert(near_v(sqrt(vec4::splat(4.0)), vec4::splat(2.0), 0.01));
    let e = e::<f32>();
    assert(near(exp(1.0f32), e, 0.01));
    assert(near_v(exp(vec1::splat(1.0)), vec1::splat(e), 0.01));
    assert(near_v(exp(vec2::splat(1.0)), vec2::splat(e), 0.01));
    assert(near_v(exp(vec3::splat(1.0)), vec3::splat(e), 0.01));
    assert(near_v(exp(vec4::splat(1.0)), vec4::splat(e), 0.01));
    assert(near(log(e), 1.0, 0.01));
    assert(near_v(log(vec1::splat(e)), vec1::splat(1.0), 0.01));
    assert(near_v(log(vec2::splat(e)), vec2::splat(1.0), 0.01));
    assert(near_v(log(vec3::splat(e)), vec3::splat(1.0), 0.01));
    assert(near_v(log(vec4::splat(e)), vec4::splat(1.0), 0.01));
}

@test
fn exp2_log2_inversesqrt() {
    assert(near(exp2(4.0f32), 16.0, 0.01));
    assert(near_v(exp2(vec1::splat(4.0)), vec1::splat(16.0), 0.01));
    assert(near_v(exp2(vec2::new(4.0, 3.0)), vec2::new(16.0, 8.0), 0.01));
    assert(near_v(exp2(vec3::new(4.0, 3.0, 2.0)), vec3::new(16.0, 8.0, 4.0), 0.01));
    assert(near_v(exp2(vec4::new(4.0, 3.0, 2.0, 1.0)), vec4::new(16.0, 8.0, 4.0, 2.0), 0.01));
    assert(near(exp2(23.0f32), 8388608.0, 0.01));
    assert(near(log2(16.0f32), 4.0, 0.01));
    assert(near_v(log2(vec1::splat(16.0)), vec1::splat(4.0), 0.01));
    assert(near_v(log2(vec2::new(16.0, 8.0)), vec2::new(4.0, 3.0), 0.01));
    assert(near_v(log2(vec3::new(16.0, 8.0, 4.0)), vec3::new(4.0, 3.0, 2.0), 0.01));
    assert(near_v(log2(vec4::new(16.0, 8.0, 4.0, 2.0)), vec4::new(4.0, 3.0, 2.0, 1.0), 0.01));
    let s = sqrt(16.0f32);
    assert(near(inversesqrt(16.0f32) * s, 1.0, 0.01));
    assert(near_v(inversesqrt(vec1::splat(16.0)) * s, vec1::splat(1.0), 0.01));
    assert(near_v(inversesqrt(vec2::splat(16.0)) * s, vec2::splat(1.0), 0.01));
    assert(near_v(inversesqrt(vec3::splat(16.0)) * s, vec3::splat(1.0), 0.01));
    assert(near_v(inversesqrt(vec4::splat(16.0)) * s, vec4::splat(1.0), 0.01));
}

@test
fn exponential_special_values() {
    assert(sqrt(-1.0f64).is_nan());
    assert_eq(log(0.0f32), -f32::infinity());
    assert_eq(inversesqrt(0.0f64), f64::infinity());
    assert_eq(inversesqrt(4.0f64), 0.5);
    assert_eq(pow(dvec2::new(2.0, 9.0), dvec2::new(10.0, 0.5)), dvec2::new(1024.0, 3.0));
    assert_eq(exp(dvec3::splat(0.0)), dvec3::splat(1.0));
}

@test
fn angles_and_trigonometry() {
    assert_eq(radians(180.0f64), 180.0 * 0.017453292519943295);
    assert_eq(degrees(pi::<f64>()), pi::<f64>() * 57.29577951308232);
    assert_eq(radians(vec2::new(90.0, -90.0)), vec2::new(90.0f32 * 0.017453292f32, -90.0f32 * 0.017453292f32));
    assert(near(sin(half_pi::<f64>()), 1.0, 1e-15));
    assert(near(cos(pi::<f64>()), -1.0, 1e-15));
    assert(near(tan(quarter_pi::<f64>()), 1.0, 1e-15));
    assert(near(asin(1.0f64), half_pi::<f64>(), 1e-15));
    assert(near(acos(-1.0f64), pi::<f64>(), 1e-15));
    assert(near(atan(1.0f64), quarter_pi::<f64>(), 1e-15));
    assert(asin(2.0f32).is_nan());
    assert(near(atan2(1.0f64, -1.0f64), three_over_two_pi::<f64>() / 2.0, 1e-15));
    assert_eq(atan2(dvec2::new(0.0, -0.0), dvec2::new(-1.0, -1.0)), dvec2::new(pi::<f64>(), -pi::<f64>()));
    assert(near_v(sinh(dvec2::new(0.0, 1.0)), dvec2::new(0.0, 1.1752011936438014), 1e-15));
    assert(near(cosh(0.0f64), 1.0, 0.0));
    assert(near(tanh(100.0f64), 1.0, 0.0));
    assert(near(asinh(sinh(0.5f64)), 0.5, 1e-15));
    assert(near(acosh(cosh(2.0f64)), 2.0, 1e-15));
    assert(near(atanh(tanh(0.25f64)), 0.25, 1e-15));
    assert(acosh(0.5f64).is_nan());
}

@test
fn sec_csc_cot() {
    let p = pi::<f64>();
    assert(both(sec(0.0f64), sec(dvec1::splat(0.0)), 1.0));
    assert(both(sec(p * 2.0), sec(dvec1::splat(p * 2.0)), 1.0));
    assert(both(sec(p * -2.0), sec(dvec1::splat(p * -2.0)), 1.0));
    assert(both(sec(p * 1.0), sec(dvec1::splat(p * 1.0)), -1.0));
    assert(both(sec(p * -1.0), sec(dvec1::splat(p * -1.0)), -1.0));
    assert(both(csc(p * 0.5), csc(dvec1::splat(p * 0.5)), 1.0));
    assert(both(csc(p * -0.5), csc(dvec1::splat(p * -0.5)), -1.0));
    assert(both(cot(p * 0.5), cot(dvec1::splat(p * 0.5)), 0.0));
    assert(both(cot(p * -0.5), cot(dvec1::splat(p * -0.5)), 0.0));
}

@test
fn asec_acsc_acot() {
    let p = pi::<f64>();
    assert(both(asec(100000.0f64), asec(dvec1::splat(100000.0)), p * 0.5));
    assert(both(asec(-100000.0f64), asec(dvec1::splat(-100000.0)), p * 0.5));
    assert(both(acsc(100000.0f64), acsc(dvec1::splat(100000.0)), 0.0));
    assert(both(acsc(-100000.0f64), acsc(dvec1::splat(-100000.0)), 0.0));
    assert(both(acot(100000.0f64), acot(dvec1::splat(100000.0)), 0.0));
    assert(both(acot(-100000.0f64), acot(dvec1::splat(-100000.0)), p));
    assert(both(acot(0.0f64), acot(dvec1::splat(0.0)), p * 0.5));
}

@test
fn sech_csch_coth() {
    assert(both(sech(100000.0f64), sech(dvec1::splat(100000.0)), 0.0));
    assert(both(sech(-100000.0f64), sech(dvec1::splat(-100000.0)), 0.0));
    assert(both(sech(0.0f64), sech(dvec1::splat(0.0)), 1.0));
    assert(both(csch(100000.0f64), csch(dvec1::splat(100000.0)), 0.0));
    assert(both(csch(-100000.0f64), csch(dvec1::splat(-100000.0)), 0.0));
    assert(both(coth(100.0f64), coth(dvec1::splat(100.0)), 1.0));
    assert(both(coth(-100.0f64), coth(dvec1::splat(-100.0)), -1.0));
}

@test
fn asech_acsch_acoth() {
    assert(both(asech(1.0f64), asech(dvec1::splat(1.0)), 0.0));
    assert(acsch(0.01f64) > 1.0);
    assert(acsch(-0.01f64) < -1.0);
    assert(acsch(dvec1::splat(0.01)).x() > 1.0);
    assert(acsch(dvec1::splat(-0.01)).x() < -1.0);
    assert(both(acsch(100.0f64), acsch(dvec1::splat(100.0)), 0.0));
    assert(both(acsch(-100.0f64), acsch(dvec1::splat(-100.0)), 0.0));
    assert(acoth(1.00001f64) > 6.0);
    assert(acoth(-1.00001f64) < -6.0);
    assert(acoth(dvec1::splat(1.00001)).x() > 6.0);
    assert(acoth(dvec1::splat(-1.00001)).x() < -6.0);
    assert(both(acoth(10000.0f64), acoth(dvec1::splat(10000.0)), 0.0));
    assert(both(acoth(-10000.0f64), acoth(dvec1::splat(-10000.0)), 0.0));
}

const C_SQRT: f64 = sqrt(2.0f64);
const C_RADIANS: vec3 = radians(vec3::new(90.0, 180.0, 360.0));
const C_POW: dvec2 = pow(dvec2::new(2.0, 3.0), dvec2::new(0.5, 1.5));
const C_SIN: f64 = sin(0.5f64);
const C_ATAN2: f32 = atan2(1.0f32, 2.0f32);
const C_SEC: f64 = sec(1.0f64);
const C_EXP: f32 = exp(1.5f32);

// A constant initializer evaluates at compile time; each must give the bits the run-time call gives.
fn runtime_sin(x: f64) f64 {
    return sin(x);
}

@test
fn constant_evaluation_matches_run_time() {
    let two: f64 = 2.0;
    assert(f64_bits(C_SQRT) == f64_bits(sqrt(two)));
    assert(C_RADIANS == radians(vec3::new(90.0, 180.0, 360.0)));
    assert(C_POW == pow(dvec2::new(2.0, 3.0), dvec2::new(0.5, 1.5)));
    assert(f64_bits(C_SIN) == f64_bits(runtime_sin(0.5)));
    assert(f32_bits(C_ATAN2) == f32_bits(atan2(1.0f32, 2.0f32)));
    assert(f64_bits(C_SEC) == f64_bits(sec(1.0f64)));
    assert(f32_bits(C_EXP) == f32_bits(exp(1.5f32)));
}
