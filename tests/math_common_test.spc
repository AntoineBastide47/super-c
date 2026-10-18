// `std::math::common` and the constants of `std::math::scalar`: rounding, min and max, mix, step,
// classification, float bits, frexp and ldexp, fma, texture coordinate wraps and component reductions on
// scalars, vectors and matrices, then the bit-level edge cases (signed zeros, NaN order, integer wrapping,
// saturation) and constant evaluation of representative functions.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::common as *;

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

fn all<const N: usize>(b: Vec<bool, N>) bool {
    for i in 0..N {
        if !b[i] {
            return false;
        }
    }
    return true;
}

fn any<const N: usize>(b: Vec<bool, N>) bool {
    for i in 0..N {
        if b[i] {
            return true;
        }
    }
    return false;
}

fn same_bits32(x: f32, y: f32) bool {
    return f32_bits(x) == f32_bits(y);
}

fn same_bits64(x: f64, y: f64) bool {
    return f64_bits(x) == f64_bits(y);
}

@test
fn floor_of_scalars_and_vectors() {
    assert(near(floor(1.1f32), 1.0, 0.0001));
    assert(near(floor(1.1f64), 1.0, 0.0001));
    assert(near_v(floor(vec1::splat(1.1)), vec1::splat(1.0), 0.0001));
    assert(near_v(floor(dvec1::splat(1.1)), dvec1::splat(1.0), 0.0001));
    assert(near_v(floor(vec2::splat(1.1)), vec2::splat(1.0), 0.0001));
    assert(near_v(floor(dvec2::splat(1.1)), dvec2::splat(1.0), 0.0001));
    assert(near_v(floor(vec3::splat(1.1)), vec3::splat(1.0), 0.0001));
    assert(near_v(floor(dvec3::splat(1.1)), dvec3::splat(1.0), 0.0001));
    assert(near_v(floor(vec4::splat(1.1)), vec4::splat(1.0), 0.0001));
    assert(near_v(floor(dvec4::splat(1.1)), dvec4::splat(1.0), 0.0001));
}

@test
fn modf_splits_fraction_and_integer() {
    let (a, i) = modf(1.5f32);
    assert(near(i, 1.0, 0.0001));
    assert(near(a, 0.5, 0.0001));
    let (av, iv) = modf(vec4::new(1.1, 1.2, 1.5, 1.7));
    assert(iv.cast::<i32>() == ivec4::splat(1));
    assert(near_v(av, vec4::new(0.1, 0.2, 0.5, 0.7), 0.00001));
    let (ad, id) = modf(dvec4::new(1.1, 1.2, 1.5, 1.7));
    assert(id.cast::<i32>() == ivec4::splat(1));
    assert(near_v(ad, dvec4::new(0.1, 0.2, 0.5, 0.7), 0.000000001));
    let (a2, i2) = modf(1.5f64);
    assert(near(i2, 1.0, 0.0001));
    assert(near(a2, 0.5, 0.0001));
    let (fneg, ineg) = modf(-2.25f64);
    assert_eq(fneg, -0.25);
    assert_eq(ineg, -2.0);
}

@test
fn mod_is_floored() {
    assert(near(mod(1.5f32, 1.0f32), 0.5, 0.00001));
    assert(near(mod(-0.2f32, 1.0f32), 0.8, 0.00001));
    assert(near(mod(3.0f32, 2.0f32), 1.0, 0.00001));
    assert(near_v(mod(vec4::splat(3.0), 2.0f32), vec4::splat(1.0), 0.00001));
    assert(near_v(mod(vec4::splat(3.0), vec4::splat(2.0)), vec4::splat(1.0), 0.00001));
}

@test
fn float_bits_round_trip() {
    let a: f32 = 1.0;
    let b = float_bits_to_int(a);
    assert_eq(b, 0x3F800000);
    assert(near(int_bits_to_float(b), a, 0.0001));
    let a2 = vec2::new(1.0, 2.0);
    assert(near_v(int_bits_to_float(float_bits_to_int(a2)), a2, 0.0001));
    let a3 = vec3::new(1.0, 2.0, 3.0);
    assert(near_v(int_bits_to_float(float_bits_to_int(a3)), a3, 0.0001));
    let a4 = vec4::new(1.0, 2.0, 3.0, 4.0);
    assert(near_v(int_bits_to_float(float_bits_to_int(a4)), a4, 0.0001));
    let u = float_bits_to_uint(a);
    assert_eq(u, 0x3F800000u32);
    assert(near(uint_bits_to_float(u), a, 0.0001));
    assert(near_v(uint_bits_to_float(float_bits_to_uint(a2)), a2, 0.0001));
    assert(near_v(uint_bits_to_float(float_bits_to_uint(a3)), a3, 0.0001));
    assert(near_v(uint_bits_to_float(float_bits_to_uint(a4)), a4, 0.0001));
    assert_eq(float_bits_to_uint(-0.0f32), 0x80000000u32);
    assert_eq(float_bits_to_int(-0.0f32), i32::MIN);
}

@test
fn min_max_of_vectors_and_scalars() {
    let eps = epsilon::<f32>();
    assert(near_v(min(vec1::splat(1.0), vec1::splat(1.0)), vec1::splat(1.0), eps));
    assert(near_v(min(vec2::splat(1.0), vec2::splat(1.0)), min(vec2::splat(1.0), 1.0f32), eps));
    assert(near_v(min(vec3::splat(1.0), vec3::splat(1.0)), min(vec3::splat(1.0), 1.0f32), eps));
    assert(near_v(min(vec4::splat(1.0), vec4::splat(1.0)), min(vec4::splat(1.0), 1.0f32), eps));
    assert(near_v(max(vec1::splat(1.0), vec1::splat(1.0)), vec1::splat(1.0), eps));
    assert(near_v(max(vec2::splat(1.0), vec2::splat(1.0)), max(vec2::splat(1.0), 1.0f32), eps));
    assert(near_v(max(vec3::splat(1.0), vec3::splat(1.0)), max(vec3::splat(1.0), 1.0f32), eps));
    assert(near_v(max(vec4::splat(1.0), vec4::splat(1.0)), max(vec4::splat(1.0), 1.0f32), eps));
}

@test
fn mix_with_bool_and_float_interpolants() {
    let eps = epsilon::<f32>();
    let xs: [f32; 4] = [0.0, 0.0, -1.0, -1.0];
    let ys: [f32; 4] = [1.0, 1.0, 1.0, 1.0];
    let bs: [bool; 4] = [false, true, false, true];
    let fs: [f32; 4] = [0.0, 1.0, 0.0, 1.0];
    let rs: [f32; 4] = [0.0, 1.0, -1.0, 1.0];
    for i in 0..4 {
        let (x, y, r) = unsafe (xs[i], ys[i], rs[i]);
        let (b, f) = unsafe (bs[i], fs[i]);
        assert(near(mix(x, y, b), r, eps));
        assert(near(mix(x, y, f), r, eps));
        assert(near_v(mix(vec2::splat(x), vec2::splat(y), b), vec2::splat(r), eps));
        assert(near_v(mix(vec2::splat(x), vec2::splat(y), bvec2::splat(b)), vec2::splat(r), eps));
        assert(near_v(mix(vec3::splat(x), vec3::splat(y), b), vec3::splat(r), eps));
        assert(near_v(mix(vec3::splat(x), vec3::splat(y), bvec3::splat(b)), vec3::splat(r), eps));
        assert(near_v(mix(vec4::splat(x), vec4::splat(y), b), vec4::splat(r), eps));
        assert(near_v(mix(vec4::splat(x), vec4::splat(y), bvec4::splat(b)), vec4::splat(r), eps));
    }
    let r2 = mix(vec2::splat(-1.0), vec2::splat(1.0), bvec2::new(true, false));
    assert(near_v(r2, vec2::new(1.0, -1.0), eps));
    let r3 = mix(vec3::new(1.0, 2.0, 3.0), vec3::new(4.0, 5.0, 6.0), bvec3::new(true, false, true));
    assert(near_v(r3, vec3::new(4.0, 2.0, 6.0), eps));
    let r4 = mix(vec4::new(0.0, 0.0, 1.0, 1.0), vec4::new(2.0, 2.0, 3.0, 3.0), bvec4::new(false, true, false, true));
    assert(near_v(r4, vec4::new(0.0, 2.0, 1.0, 3.0), eps));
    let r5 = mix(vec4::new(1.0, 2.0, 3.0, 4.0), vec4::new(5.0, 6.0, 7.0, 8.0), bvec4::new(true, false, true, false));
    assert(near_v(r5, vec4::new(5.0, 2.0, 7.0, 4.0), eps));
}

@test
fn mix_runs_in_the_interpolant_type() {
    // f32 values with an f64 interpolant: computed in f64, then rounded once to f32.
    let x: f32 = 1.0;
    let y: f32 = 2.0;
    let a: f64 = 0.1;
    assert(same_bits32(mix(x, y, a), (1.0f64 * (1.0 - a) + 2.0f64 * a) as f32));
    // Integers: the f32 result truncates toward zero.
    assert_eq(mix(3, 9, 0.5f32), 6);
    assert_eq(mix(3, 8, 0.5f32), 5);
    assert_eq(mix(ivec2::new(0, 10), ivec2::new(10, 0), vec2::new(0.25, 0.25)), ivec2::new(2, 7));
    assert_eq(mix(7u8, 9u8, true), 9u8);
}

// `mix` with an interpolant of a generic float type `T`: the generic conformances `T as Mix<U>`,
// `Vec<T, N> as Mix<U>` and `Mat<T, C, R> as Mix<U>` serve every float `U`, beside the `bool` ones.
fn gen_mix<T: Float>(v: Vec<T, 3>, w: Vec<T, 3>, t: T) Vec<T, 3> {
    return mix(v, w, t);
}

fn gen_mix_scalar<T: Float>(x: T, y: T, t: T) T {
    return mix(x, y, t);
}

@test
fn mix_with_a_generic_interpolant() {
    assert(gen_mix(dvec3::splat(0.0), dvec3::splat(8.0), 0.25f64) == dvec3::splat(2.0));
    assert(gen_mix(vec3::new(0.0, 1.0, 2.0), vec3::splat(4.0), 0.5f32) == vec3::new(2.0, 2.5, 3.0));
    assert_eq(gen_mix_scalar(2.0f64, 6.0f64, 0.5f64), 4.0f64);
    assert_eq(mix(2.0f32, 6.0f32, true), 6.0f32);
    assert(mix(vec2::splat(0.0), vec2::splat(2.0), bvec2::new(true, false)) == vec2::new(2.0, 0.0));
    assert(mix(mat2x3::identity(), mat2x3::identity() * 3.0, 0.5f32) == mat2x3::identity() * 2.0);
    assert(mix(mat2::identity(), mat2::identity() * 3.0, mat2::new(0.5, 0.5, 0.5, 0.5)) == mat2::identity() * 2.0);
}

@test
fn step_against_scalar_and_vector_edges() {
    let eps = epsilon::<f32>();
    assert(near(step(2.0f32, 1.0f32), 0.0, eps));
    assert(near(step(2.0f32, 3.0f32), 1.0, eps));
    assert(near(step(2.0f32, 2.0f32), 1.0, eps));
    assert(near_v(step(1.0f32, vec4::new(1.0, 2.0, 3.0, 4.0)), vec4::splat(1.0), eps));
    assert(near_v(step(0.0f32, vec4::new(1.0, 2.0, 3.0, 4.0)), vec4::splat(1.0), eps));
    assert(near_v(step(0.0f32, vec4::new(-1.0, -2.0, -3.0, -4.0)), vec4::splat(0.0), eps));
    let edges = [
        vec4::new(-1.0, -2.0, -3.0, -4.0),
        vec4::new(0.0, 1.0, 2.0, 3.0),
        vec4::new(2.0, 3.0, 4.0, 5.0),
        vec4::new(0.0, 1.0, 2.0, 3.0),
    ];
    let xs = [
        vec4::new(-2.0, -3.0, -4.0, -5.0),
        vec4::new(1.0, 2.0, 3.0, 4.0),
        vec4::new(1.0, 2.0, 3.0, 4.0),
        vec4::new(-1.0, -2.0, -3.0, -4.0),
    ];
    let rs: [f32; 4] = [0.0, 1.0, 0.0, 0.0];
    for i in 0..4 {
        assert(near_v(step(unsafe edges[i], unsafe xs[i]), vec4::splat(unsafe rs[i]), eps));
    }
    assert_eq(step(5, ivec3::new(4, 5, 6)), ivec3::new(0, 1, 1));
    assert_eq(step(1.0f32, f32::nan()), 1.0);
}

@test
fn smoothstep_midpoint() {
    let eps = epsilon::<f32>();
    let edge: f32 = 2.0;
    assert(near(smoothstep(0.0f32, edge, 1.0f32), 0.5, eps));
    assert(near_v(smoothstep(0.0f32, edge, vec4::splat(1.0)), vec4::splat(0.5), eps));
    assert(near_v(smoothstep(vec4::splat(0.0), vec4::splat(edge), vec4::splat(1.0)), vec4::splat(0.5), eps));
    assert_eq(smoothstep(0.0f32, edge, -1.0f32), 0.0);
    assert_eq(smoothstep(0.0f32, edge, 3.0f32), 1.0);
}

@test
fn round_halves_away_from_zero() {
    let eps = epsilon::<f32>();
    assert(near(round(0.0f32), 0.0, eps));
    let b = round(0.5f32);
    assert(near(b, 1.0, eps) || near(b, 0.0, eps));
    assert(near(round(1.0f32), 1.0, eps));
    assert(near(round(0.1f32), 0.0, eps));
    assert(near(round(0.9f32), 1.0, eps));
    assert(near(round(1.5f32), 2.0, eps));
    assert(near(round(1.9f32), 2.0, eps));
    assert(near(round(-0.0f32), 0.0, eps));
    let nb = round(-0.5f32);
    assert(near(nb, -1.0, eps) || near(nb, 0.0, eps));
    assert(near(round(-1.0f32), -1.0, eps));
    assert(near(round(-0.1f32), 0.0, eps));
    assert(near(round(-0.9f32), -1.0, eps));
    assert(near(round(-1.5f32), -2.0, eps));
    assert(near(round(-1.9f32), -2.0, eps));
    assert_eq(round(vec3::new(2.5, -2.5, 0.4)), vec3::new(3.0, -3.0, 0.0));
    assert_eq(ceil(dvec2::new(1.2, -1.2)), dvec2::new(2.0, -1.0));
    assert_eq(trunc(vec2::new(1.7, -1.7)), vec2::new(1.0, -1.0));
    assert_eq(fract(-1.25f32), 0.75);
}

@test
fn round_even_halves_to_even() {
    let xs: [f32; 14] = [-1.5, 1.5, -2.5, 2.5, -3.5, 3.5, -4.5, 4.5, -5.5, 5.5, -6.5, 6.5, -7.5, 7.5];
    let rs: [f32; 14] = [-2.0, 2.0, -2.0, 2.0, -4.0, 4.0, -4.0, 4.0, -6.0, 6.0, -6.0, 6.0, -8.0, 8.0];
    for i in 0..14 {
        assert(near(round_even(unsafe xs[i]), unsafe rs[i], 0.0001));
    }
    let ys: [f32; 6] = [-2.4, 2.4, -2.6, 2.6, -2.0, 2.0];
    let ts: [f32; 6] = [-2.0, 2.0, -3.0, 3.0, -2.0, 2.0];
    for i in 0..6 {
        assert(near(round_even(unsafe ys[i]), unsafe ts[i], 0.0001));
    }
    let eps = epsilon::<f32>();
    let zs: [f32; 7] = [0.0, 0.5, 1.0, 0.1, 0.9, 1.5, 1.9];
    let us: [f32; 7] = [0.0, 0.0, 1.0, 0.0, 1.0, 2.0, 2.0];
    for i in 0..7 {
        assert(near(round_even(unsafe zs[i]), unsafe us[i], eps));
        assert(near(round_even(-unsafe zs[i]), -unsafe us[i], eps));
    }
    let hs: [f32; 7] = [1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5];
    let gs: [f32; 7] = [2.0, 2.0, 4.0, 4.0, 6.0, 6.0, 8.0];
    for i in 0..7 {
        assert(near(round_even(unsafe hs[i]), unsafe gs[i], eps));
        assert(near(round_even(-unsafe hs[i]), -unsafe gs[i], eps));
    }
    // A half that rounds to zero gives the computed integral part: +0.0 for -0.5, not -0.0.
    assert(same_bits32(round_even(-0.5f32), 0.0));
    assert_eq(round_even(dvec3::new(0.5, 1.5, -2.5)), dvec3::new(0.0, 2.0, -2.0));
}

@test
fn isnan_and_isinf() {
    let zero_f: f32 = 0.0;
    let zero_d: f64 = 0.0;
    assert(isnan(0.0 / zero_d));
    assert(any(isnan(dvec2::splat(0.0 / zero_d))));
    assert(any(isnan(dvec3::splat(0.0 / zero_d))));
    assert(any(isnan(dvec4::splat(0.0 / zero_d))));
    assert(isnan(0.0 / zero_f));
    assert(any(isnan(vec2::splat(0.0 / zero_f))));
    assert(any(isnan(vec3::splat(0.0 / zero_f))));
    assert(any(isnan(vec4::splat(0.0 / zero_f))));
    assert(isinf(1.0 / zero_d));
    assert(isinf(-1.0 / zero_d));
    assert(any(isinf(dvec2::splat(1.0 / zero_d))));
    assert(any(isinf(dvec2::splat(-1.0 / zero_d))));
    assert(any(isinf(dvec3::splat(1.0 / zero_d))));
    assert(any(isinf(dvec3::splat(-1.0 / zero_d))));
    assert(any(isinf(dvec4::splat(1.0 / zero_d))));
    assert(any(isinf(dvec4::splat(-1.0 / zero_d))));
    assert(isinf(1.0 / zero_f));
    assert(isinf(-1.0 / zero_f));
    assert(any(isinf(vec2::splat(1.0 / zero_f))));
    assert(any(isinf(vec2::splat(-1.0 / zero_f))));
    assert(any(isinf(vec3::splat(1.0 / zero_f))));
    assert(any(isinf(vec3::splat(-1.0 / zero_f))));
    assert(any(isinf(vec4::splat(1.0 / zero_f))));
    assert(any(isinf(vec4::splat(-1.0 / zero_f))));
    assert_eq(isnan(vec3::new(1.0, 0.0 / zero_f, 2.0)), bvec3::new(false, true, false));
    assert(!isinf(f64::nan()));
}

@test
fn sign_of_integers_and_floats() {
    let values: [i32; 9] = [i32::MAX, i32::MIN, 0, 1, 2, 3, -1, -2, -3];
    let signs: [i32; 9] = [1, -1, 0, 1, 1, 1, -1, -1, -1];
    for i in 0..9 {
        assert_eq(sign(unsafe values[i]), unsafe signs[i]);
    }
    let vs: [i32; 7] = [1, 0, 2, 3, -1, -2, -3];
    let ss: [i32; 7] = [1, 0, 1, 1, -1, -1, -1];
    for i in 0..7 {
        assert(sign(ivec4::splat(unsafe vs[i])) == ivec4::splat(unsafe ss[i]));
        assert(near_v(sign(vec4::splat((unsafe vs[i]) as f32)), vec4::splat((unsafe ss[i]) as f32), epsilon::<f32>()));
    }
    // T(0 < x) - T(x < 0): +0.0 for -0.0 and for a NaN.
    assert(same_bits32(sign(-0.0f32), 0.0));
    assert(same_bits64(sign(f64::nan()), 0.0));
    assert_eq(sign(i8::MIN), -1i8);
}

@test
fn frexp_and_ldexp() {
    let eps = epsilon::<f32>();
    let (a1, e1) = frexp(vec1::splat(1024.0));
    assert(near_v(a1, vec1::splat(0.5), eps));
    assert(e1 == ivec1::splat(11));
    let (a2, e2) = frexp(vec2::new(1024.0, 0.24));
    assert(near_v(a2, vec2::new(0.5, 0.96), eps));
    assert(e2 == ivec2::new(11, -2));
    let (a3, e3) = frexp(vec3::new(1024.0, 0.24, 0.0));
    assert(near_v(a3, vec3::new(0.5, 0.96, 0.0), eps));
    assert(e3 == ivec3::new(11, -2, 0));
    let (a4, e4) = frexp(vec4::new(1024.0, 0.24, 0.0, -1.33));
    assert(near_v(a4, vec4::new(0.5, 0.96, 0.0, -0.665), eps));
    assert(e4 == ivec4::new(11, -2, 0, 1));
    let (m, k) = frexp(1024.0f64);
    assert_eq(m, 0.5);
    assert_eq(k, 11);
    assert(near_v(ldexp(vec1::splat(0.5), ivec1::splat(11)), vec1::splat(1024.0), 0.00001));
    assert(near_v(ldexp(vec2::new(0.5, 0.96), ivec2::new(11, -2)), vec2::new(1024.0, 0.24), 0.00001));
    assert(near_v(ldexp(vec3::new(0.5, 0.96, 0.0), ivec3::new(11, -2, 0)), vec3::new(1024.0, 0.24, 0.0), 0.00001));
    let l4 = ldexp(vec4::new(0.5, 0.96, 0.0, -0.665), ivec4::new(11, -2, 0, 1));
    assert(near_v(l4, vec4::new(1024.0, 0.24, 0.0, -1.33), 0.00001));
    assert_eq(ldexp(0.75f64, 4), 12.0);
}

@test
fn fma_scalar_rounds_once_vector_twice() {
    let a: f32 = 1.0 + 1.0e-7;
    let b: f32 = 1.0 - 1.0e-7;
    let c: f32 = -1.0;
    // The scalar `fma` keeps the -2^-46 that `a * b` rounds away; the vector `fma` rounds `a * b`, then the
    // sum.
    assert(fma(a, b, c) != 0.0);
    assert_eq(fma(vec1::splat(a), vec1::splat(b), vec1::splat(c)), vec1::splat(0.0));
    assert_eq(fma(2.0f64, 3.0f64, 4.0f64), 10.0);
}

@test
fn min_max_of_three_and_four() {
    check_min_max::<f32>();
    check_min_max::<f64>();
    check_min_max_v::<f32, 2>();
    check_min_max_v::<f32, 3>();
}

fn check_min_max<T: Float>() {
    let eps = epsilon::<T>();
    let n = T::zero();
    let b = T::one();
    let c = T::from_i64(2);
    let d = T::from_i64(3);
    assert(near(min::<T>(n, b), n, eps));
    assert(near(min::<T>(b, n), n, eps));
    assert(near(min3::<T>(n, b, c), n, eps));
    assert(near(min3::<T>(b, n, c), n, eps));
    assert(near(min3::<T>(c, n, b), n, eps));
    assert(near(min3::<T>(c, b, n), n, eps));
    assert(near(min3::<T>(b, c, n), n, eps));
    assert(near(min3::<T>(n, c, b), n, eps));
    assert(near(min4::<T>(d, n, b, c), n, eps));
    assert(near(min4::<T>(b, d, n, c), n, eps));
    assert(near(min4::<T>(c, n, d, b), n, eps));
    assert(near(min4::<T>(c, b, d, n), n, eps));
    assert(near(min4::<T>(b, c, n, d), n, eps));
    assert(near(min4::<T>(n, c, b, d), n, eps));
    assert(near(max::<T>(n, b), b, eps));
    assert(near(max::<T>(b, n), b, eps));
    assert(near(max3::<T>(n, b, c), c, eps));
    assert(near(max3::<T>(b, n, c), c, eps));
    assert(near(max3::<T>(c, n, b), c, eps));
    assert(near(max3::<T>(c, b, n), c, eps));
    assert(near(max3::<T>(b, c, n), c, eps));
    assert(near(max3::<T>(n, c, b), c, eps));
    assert(near(max4::<T>(d, n, b, c), d, eps));
    assert(near(max4::<T>(b, d, n, c), d, eps));
    assert(near(max4::<T>(c, n, d, b), d, eps));
    assert(near(max4::<T>(c, b, d, n), d, eps));
    assert(near(max4::<T>(b, c, n, d), d, eps));
    assert(near(max4::<T>(n, c, b, d), d, eps));

    // A NaN first argument propagates through `<`; elsewhere it loses.
    let q = T::nan();
    assert(isnan_of(min::<T>(q, b)));
    assert(!isnan_of(min::<T>(b, q)));
    assert(isnan_of(min3::<T>(q, b, c)));
    assert(!isnan_of(min3::<T>(b, q, c)));
    assert(!isnan_of(min3::<T>(c, q, b)));
    assert(!isnan_of(min3::<T>(c, b, q)));
    assert(!isnan_of(min3::<T>(b, c, q)));
    assert(isnan_of(min3::<T>(q, c, b)));
    assert(!isnan_of(min4::<T>(d, q, b, c)));
    assert(!isnan_of(min4::<T>(b, d, q, c)));
    assert(!isnan_of(min4::<T>(c, q, d, b)));
    assert(!isnan_of(min4::<T>(c, b, d, q)));
    assert(!isnan_of(min4::<T>(b, c, q, d)));
    assert(isnan_of(min4::<T>(q, c, b, d)));
    assert(isnan_of(max::<T>(q, b)));
    assert(!isnan_of(max::<T>(b, q)));
    assert(isnan_of(max3::<T>(q, b, c)));
    assert(!isnan_of(max3::<T>(b, q, c)));
    assert(!isnan_of(max3::<T>(c, q, b)));
    assert(!isnan_of(max3::<T>(c, b, q)));
    assert(!isnan_of(max3::<T>(b, c, q)));
    assert(isnan_of(max3::<T>(q, c, b)));
    assert(!isnan_of(max4::<T>(d, q, b, c)));
    assert(!isnan_of(max4::<T>(b, d, q, c)));
    assert(!isnan_of(max4::<T>(c, q, d, b)));
    assert(!isnan_of(max4::<T>(c, b, d, q)));
    assert(!isnan_of(max4::<T>(b, c, q, d)));
    assert(isnan_of(max4::<T>(q, c, b, d)));

    // fmin and fmax ignore NaNs.
    assert(near(fmin::<T>(q, b), b, eps));
    assert(near(fmin::<T>(b, q), b, eps));
    assert(near(fmin3(q, b, c), b, eps));
    assert(near(fmin3(b, q, c), b, eps));
    assert(near(fmin3(c, q, b), b, eps));
    assert(near(fmin3(c, b, q), b, eps));
    assert(near(fmin3(b, c, q), b, eps));
    assert(near(fmin3(q, c, b), b, eps));
    assert(near(fmin4(d, q, b, c), b, eps));
    assert(near(fmin4(b, d, q, c), b, eps));
    assert(near(fmin4(c, q, d, b), b, eps));
    assert(near(fmin4(c, b, d, q), b, eps));
    assert(near(fmin4(b, c, q, d), b, eps));
    assert(near(fmin4(q, c, b, d), b, eps));
    assert(near(fmax::<T>(q, b), b, eps));
    assert(near(fmax::<T>(b, q), b, eps));
    assert(near(fmax3(q, b, c), c, eps));
    assert(near(fmax3(b, q, c), c, eps));
    assert(near(fmax3(c, q, b), c, eps));
    assert(near(fmax3(c, b, q), c, eps));
    assert(near(fmax3(b, c, q), c, eps));
    assert(near(fmax3(q, c, b), c, eps));
    assert(near(fmax4(d, q, b, c), d, eps));
    assert(near(fmax4(b, d, q, c), d, eps));
    assert(near(fmax4(c, q, d, b), d, eps));
    assert(near(fmax4(c, b, d, q), d, eps));
    assert(near(fmax4(b, c, q, d), d, eps));
    assert(near(fmax4(q, c, b, d), d, eps));
}

fn isnan_of<T: Float>(x: T) bool {
    return x.is_nan();
}

fn check_min_max_v<T: Float, const N: usize>() {
    let eps = epsilon::<T>();
    let n = Vec::<T, N>::splat(T::zero());
    let b = Vec::<T, N>::splat(T::one());
    let c = Vec::<T, N>::splat(T::from_i64(2));
    let d = Vec::<T, N>::splat(T::from_i64(3));
    assert(near_v(min(n, b), n, eps));
    assert(near_v(min(b, n), n, eps));
    assert(near_v(min3(n, b, c), n, eps));
    assert(near_v(min3(b, n, c), n, eps));
    assert(near_v(min3(c, n, b), n, eps));
    assert(near_v(min3(c, b, n), n, eps));
    assert(near_v(min3(b, c, n), n, eps));
    assert(near_v(min3(n, c, b), n, eps));
    assert(near_v(min4(d, n, b, c), n, eps));
    assert(near_v(min4(b, d, n, c), n, eps));
    assert(near_v(min4(c, n, d, b), n, eps));
    assert(near_v(min4(c, b, d, n), n, eps));
    assert(near_v(min4(b, c, n, d), n, eps));
    assert(near_v(min4(n, c, b, d), n, eps));
    assert(near_v(max(n, b), b, eps));
    assert(near_v(max(b, n), b, eps));
    assert(near_v(max3(n, b, c), c, eps));
    assert(near_v(max3(b, n, c), c, eps));
    assert(near_v(max3(c, n, b), c, eps));
    assert(near_v(max3(c, b, n), c, eps));
    assert(near_v(max3(b, c, n), c, eps));
    assert(near_v(max3(n, c, b), c, eps));
    assert(near_v(max4(d, n, b, c), d, eps));
    assert(near_v(max4(b, d, n, c), d, eps));
    assert(near_v(max4(c, n, d, b), d, eps));
    assert(near_v(max4(c, b, d, n), d, eps));
    assert(near_v(max4(b, c, n, d), d, eps));
    assert(near_v(max4(n, c, b, d), d, eps));

    let q = Vec::<T, N>::splat(T::nan());
    assert(all(isnan(min(q, b))));
    assert(!all(isnan(min(b, q))));
    assert(all(isnan(min3(q, b, c))));
    assert(!all(isnan(min3(b, q, c))));
    assert(!all(isnan(min3(c, q, b))));
    assert(!all(isnan(min3(c, b, q))));
    assert(!all(isnan(min3(b, c, q))));
    assert(all(isnan(min3(q, c, b))));
    assert(!all(isnan(min4(d, q, b, c))));
    assert(!all(isnan(min4(b, d, q, c))));
    assert(!all(isnan(min4(c, q, d, b))));
    assert(!all(isnan(min4(c, b, d, q))));
    assert(!all(isnan(min4(b, c, q, d))));
    assert(all(isnan(min4(q, c, b, d))));
    assert(all(isnan(max(q, b))));
    assert(!all(isnan(max(b, q))));
    assert(all(isnan(max3(q, b, c))));
    assert(!all(isnan(max3(b, q, c))));
    assert(!all(isnan(max3(c, q, b))));
    assert(!all(isnan(max3(c, b, q))));
    assert(!all(isnan(max3(b, c, q))));
    assert(all(isnan(max3(q, c, b))));
    assert(!all(isnan(max4(d, q, b, c))));
    assert(!all(isnan(max4(b, d, q, c))));
    assert(!all(isnan(max4(c, q, d, b))));
    assert(!all(isnan(max4(c, b, d, q))));
    assert(!all(isnan(max4(b, c, q, d))));
    assert(all(isnan(max4(q, c, b, d))));

    assert(near_v(fmin(q, b), b, eps));
    assert(near_v(fmin(b, q), b, eps));
    assert(near_v(fmin3(q, b, c), b, eps));
    assert(near_v(fmin3(b, q, c), b, eps));
    assert(near_v(fmin3(c, q, b), b, eps));
    assert(near_v(fmin3(c, b, q), b, eps));
    assert(near_v(fmin3(b, c, q), b, eps));
    assert(near_v(fmin3(q, c, b), b, eps));
    assert(near_v(fmin4(d, q, b, c), b, eps));
    assert(near_v(fmin4(b, d, q, c), b, eps));
    assert(near_v(fmin4(c, q, d, b), b, eps));
    assert(near_v(fmin4(c, b, d, q), b, eps));
    assert(near_v(fmin4(b, c, q, d), b, eps));
    assert(near_v(fmin4(q, c, b, d), b, eps));
    assert(near_v(fmax(q, b), b, eps));
    assert(near_v(fmax(b, q), b, eps));
    assert(near_v(fmax3(q, b, c), c, eps));
    assert(near_v(fmax3(b, q, c), c, eps));
    assert(near_v(fmax3(c, q, b), c, eps));
    assert(near_v(fmax3(c, b, q), c, eps));
    assert(near_v(fmax3(b, c, q), c, eps));
    assert(near_v(fmax3(q, c, b), c, eps));
    assert(near_v(fmax4(d, q, b, c), d, eps));
    assert(near_v(fmax4(b, d, q, c), d, eps));
    assert(near_v(fmax4(c, q, d, b), d, eps));
    assert(near_v(fmax4(c, b, d, q), d, eps));
    assert(near_v(fmax4(b, c, q, d), d, eps));
    assert(near_v(fmax4(q, c, b, d), d, eps));
}

@test
fn fmin3_keeps_signed_zero_order() {
    // The scalar form compares with `<` (first of equal values); the vector form calls `fmin`.
    assert(same_bits32(fmin3(0.0f32, -0.0f32, 1.0f32), 0.0));
    assert(same_bits32(fmax3(-0.0f32, 0.0f32, -1.0f32), -0.0));
    assert_eq(fclamp(f32::nan(), 0.0f32, 1.0f32), 0.0);
    assert_eq(fclamp(vec2::new(-1.0, 2.0), 0.0f32, 1.0f32), vec2::new(0.0, 1.0));
}

@test
fn texture_coordinate_wraps() {
    let eps: f32 = 0.00001;
    let cl: [f32; 5] = [0.5, 0.0, 1.0, -0.5, 1.5];
    let cr: [f32; 5] = [0.5, 0.0, 1.0, 0.0, 1.0];
    for i in 0..5 {
        assert(near(clamp_unit(unsafe cl[i]), unsafe cr[i], eps));
    }
    let rp: [f32; 6] = [0.5, 0.0, 1.0, -0.5, 1.5, 0.9];
    let rr: [f32; 6] = [0.5, 0.0, 0.0, 0.5, 0.5, 0.9];
    for i in 0..6 {
        assert(near(repeat(unsafe rp[i]), unsafe rr[i], eps));
    }
    let mc: [f32; 9] = [0.5, 0.0, 1.1, -0.5, 1.5, 0.9, 3.1, -3.1, -0.9];
    let mr: [f32; 9] = [0.5, 0.0, 0.1, 0.5, 0.5, 0.9, 0.1, 0.1, 0.9];
    for i in 0..9 {
        assert(near(mirror_clamp(unsafe mc[i]), unsafe mr[i], eps));
    }
    let mp: [f32; 9] = [0.5, 0.0, 1.0, -0.5, 1.5, 0.9, 3.0, -3.0, -1.0];
    let mq: [f32; 9] = [0.5, 0.0, 1.0, 0.5, 0.5, 0.9, 1.0, 1.0, 1.0];
    for i in 0..9 {
        assert(near(mirror_repeat(unsafe mp[i]), unsafe mq[i], eps));
    }
    assert(near_v(clamp_unit(vec2::splat(0.5)), vec2::splat(0.5), eps));
    assert(near_v(clamp_unit(vec3::splat(0.5)), vec3::splat(0.5), eps));
    assert(near_v(clamp_unit(vec4::splat(0.5)), vec4::splat(0.5), eps));
    assert(near_v(clamp_unit(vec1::splat(0.5)), vec1::splat(0.5), eps));
    assert(near_v(repeat(vec2::splat(0.5)), vec2::splat(0.5), eps));
    assert(near_v(repeat(vec3::splat(0.5)), vec3::splat(0.5), eps));
    assert(near_v(repeat(vec4::splat(0.5)), vec4::splat(0.5), eps));
    assert(near_v(repeat(vec1::splat(0.5)), vec1::splat(0.5), eps));
    assert(near_v(mirror_clamp(vec2::splat(0.5)), vec2::splat(0.5), eps));
    assert(near_v(mirror_clamp(vec3::splat(0.5)), vec3::splat(0.5), eps));
    assert(near_v(mirror_clamp(vec4::splat(0.5)), vec4::splat(0.5), eps));
    assert(near_v(mirror_clamp(vec1::splat(0.5)), vec1::splat(0.5), eps));
    assert(near_v(mirror_repeat(vec2::splat(0.5)), vec2::splat(0.5), eps));
    assert(near_v(mirror_repeat(vec3::splat(0.5)), vec3::splat(0.5), eps));
    assert(near_v(mirror_repeat(vec4::splat(0.5)), vec4::splat(0.5), eps));
    assert(near_v(mirror_repeat(vec1::splat(0.5)), vec1::splat(0.5), eps));
    assert_eq(clamp(ivec3::new(-5, 5, 50), 0, 10), ivec3::new(0, 5, 10));
    assert_eq(clamp_unit(ivec2::new(-3, 3)), ivec2::new(0, 1));
}

@test
fn iround_and_uround_match_round() {
    let mut f: f32 = 0.0;
    for _ in 0..63 {
        if !f.less(3.1) {
            break;
        }
        assert_eq(iround(f), round(f) as i32);
        assert_eq(uround(f), round(f) as u32);
        assert_eq(iround(vec2::splat(f)), ivec2::splat(round(f) as i32));
        assert_eq(uround(dvec3::splat(f)), uvec3::splat(round(f) as u32));
        f = f + 0.05;
    }
}

@test(should_panic)
fn iround_rejects_a_negative_value() {
    iround(-1.0f32);
}

@test
fn abs_of_matrices() {
    let a = mat4::new(3.0, 1.0, 5.2, 4.9, 1.4, 0.5, 9.3, 3.7, 6.8, 8.4, 4.3, 3.9, 5.6, 7.2, 1.1, 4.4);
    let b = mat4::new(1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0, -1.0, -1.0, -1.0, -1.0, -1.0, 1.0, 1.0);
    check_abs_matrix(a, b);
    let a43 = mat4x3::new(3.0, 1.0, 5.2, 4.9, 1.4, 0.5, 9.3, 3.7, 6.8, 8.4, 4.3, 3.9);
    let b43 = mat4x3::new(1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0, -1.0, -1.0, -1.0);
    check_abs_matrix(a43, b43);
    let a42 = mat4x2::new(3.0, 1.0, 1.4, 0.5, 6.8, 8.4, 5.6, 7.2);
    let b42 = mat4x2::new(1.0, -1.0, -1.0, 1.0, 1.0, -1.0, -1.0, -1.0);
    check_abs_matrix(a42, b42);
    let a34 = mat3x4::new(3.0, 1.0, 5.2, 4.9, 1.4, 0.5, 9.3, 3.7, 6.8, 8.4, 4.3, 3.9);
    let b34 = mat3x4::new(1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0, -1.0, -1.0, -1.0);
    check_abs_matrix(a34, b34);
    let a33 = mat3::new(3.0, 1.0, 5.2, 1.4, 0.5, 9.3, 6.8, 8.4, 4.3);
    let b33 = mat3::new(1.0, -1.0, 1.0, -1.0, 1.0, 1.0, 1.0, -1.0, -1.0);
    check_abs_matrix(a33, b33);
    let a32 = mat3x2::new(5.2, 4.9, 9.3, 3.7, 4.3, 3.9);
    let b32 = mat3x2::new(1.0, 1.0, 1.0, -1.0, -1.0, -1.0);
    check_abs_matrix(a32, b32);
    let a24 = mat2x4::new(3.0, 1.0, 5.2, 4.9, 5.6, 7.2, 1.1, 4.4);
    let b24 = mat2x4::new(1.0, -1.0, 1.0, 1.0, -1.0, -1.0, 1.0, 1.0);
    check_abs_matrix(a24, b24);
    let a23 = mat2x3::new(3.0, 1.0, 5.2, 8.4, 4.3, 3.9);
    let b23 = mat2x3::new(1.0, -1.0, 1.0, -1.0, -1.0, -1.0);
    check_abs_matrix(a23, b23);
    let a22 = mat2::new(3.0, 1.0, 5.6, 7.2);
    let b22 = mat2::new(1.0, -1.0, -1.0, -1.0);
    check_abs_matrix(a22, b22);
}

fn check_abs_matrix<const C: usize, const R: usize>(a: Mat<f32, C, R>, b: Mat<f32, C, R>) {
    let d = abs(matrix_comp_mult(a, b));
    for i in 0..C {
        assert(near_v(d[i], a[i], 0.001));
    }
}

@test
fn mix_of_matrices() {
    let a = mat4::diagonal(2.0);
    let b = mat4::diagonal(4.0);
    check_mat_near(mix(a, b, 0.5f32), mat4::diagonal(3.0));
    check_mat_near(mix(a, b, 0.5f64), mat4::diagonal(3.0));
    let da = dmat4::diagonal(2.0);
    let db = dmat4::diagonal(4.0);
    check_mat_near(mix(da, db, 0.5f64).cast::<f32>(), mat4::diagonal(3.0));
    check_mat_near(mix(da, db, 0.5f32).cast::<f32>(), mat4::diagonal(3.0));
    check_mat_near(
        mix(a, b, mat4::diagonal(0.5)),
        mat4::new(3.0, 0.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 0.0, 3.0),
    );
}

fn check_mat_near(x: mat4, y: mat4) {
    for i in 0usize..4 {
        assert(near_v(x[i], y[i], 1.0));
    }
}

@test
fn constants() {
    assert(epsilon::<f32>() > 0.0);
    assert(epsilon::<f64>() > 0.0);
    assert(pi::<f32>() > 3.14 && pi::<f32>() < 3.15);
    assert(pi::<f64>() > 3.14 && pi::<f64>() < 3.15);
    assert_eq(epsilon::<f32>(), f32_from_bits(0x34000000));
    assert_eq(pi::<f64>(), 3.141592653589793);
    assert_eq(pi::<f32>(), 3.1415927f32);
    assert_eq(tau::<f64>(), two_pi::<f64>());
    assert_eq(half_pi::<f64>() * 2.0, pi::<f64>());
    assert_eq(two_pi::<i32>(), 6);
    assert_eq(zero::<u8>(), 0u8);
    assert_eq(one::<f64>(), 1.0);
    assert_eq(third::<f64>(), 1.0 / 3.0);
    assert_eq(ln_two::<f64>(), 0.6931471805599453);
    assert_eq(golden_ratio::<f64>(), 1.618033988749895);
}

const C_PI: f32 = pi::<f32>();
const C_MIN: vec2 = min(vec2::new(1.0, 3.0), 2.0f32);
const C_CLAMP: f64 = clamp(1.5f64, 0.0f64, 1.0f64);
const C_MIX: dvec3 = mix(dvec3::splat(2.0), dvec3::splat(4.0), 0.25f64);
const C_ABS: imat2 = abs(imat2::new(-1, 2, -3, 4));
const C_ROUND_EVEN: f64 = round_even(2.5f64);
const C_SIGN: ivec3 = sign(ivec3::new(-7, 0, 7));
const C_ISNAN: bvec2 = isnan(vec2::new(0.0, 0.0 / 0.0));

@test
fn constant_evaluation() {
    assert_eq(C_PI, pi::<f32>());
    assert_eq(C_MIN, vec2::new(1.0, 2.0));
    assert_eq(C_CLAMP, 1.0);
    assert_eq(C_MIX, dvec3::splat(2.5));
    assert(C_ABS == imat2::new(1, 2, 3, 4));
    assert_eq(C_ROUND_EVEN, 2.0);
    assert_eq(C_SIGN, ivec3::new(-1, 0, 1));
    assert_eq(C_ISNAN, bvec2::new(false, true));
}

@test
fn comp_normalize_ranges() {
    let a = comp_normalize::<f32>(u8vec4::new(0, 127, 128, 255));
    assert(near(a.x(), 0.0, f32::epsilon()));
    assert(a.y() < 0.5);
    assert(a.z() > 0.5);
    assert(near(a.w(), 1.0, f32::epsilon()));
    let b = comp_normalize::<f32>(i8vec4::new(-128, -1, 0, 127));
    assert(near(b.x(), -1.0, f32::epsilon()));
    assert(b.y() < 0.0);
    assert(b.z() > 0.0);
    assert(near(b.w(), 1.0, f32::epsilon()));
    let c = comp_normalize::<f32>(u16vec4::new(u16::MIN, (u16::MAX >> 1) + 0, (u16::MAX >> 1) + 1, u16::MAX));
    assert(near(c.x(), 0.0, f32::epsilon()));
    assert(c.y() < 0.5);
    assert(c.z() > 0.5);
    assert(near(c.w(), 1.0, f32::epsilon()));
    let d = comp_normalize::<f32>(i16vec4::new(i16::MIN, -1, 0, i16::MAX));
    assert(near(d.x(), -1.0, f32::epsilon()));
    assert(d.y() < 0.0);
    assert(d.z() > 0.0);
    assert(near(d.w(), 1.0, f32::epsilon()));
}

@test
fn comp_scale_ranges() {
    let a = comp_scale::<u8>(vec4::new(0.0, 0.2, 0.5, 1.0));
    assert_eq(a.x(), u8::MIN);
    assert(a.y() < u8::MAX >> 2);
    assert_eq(a.z(), 127);
    assert_eq(a.w(), 255);
    let b = comp_scale::<i8>(vec4::new(0.0, -1.0, 0.5, 1.0));
    assert_eq(b, i8vec4::new(0, -128, 63, 127));
    let c = comp_scale::<u16>(vec4::new(0.0, 0.2, 0.5, 1.0));
    assert_eq(c.x(), u16::MIN);
    assert(c.y() < u16::MAX >> 2);
    assert_eq(c.z(), 32767);
    assert_eq(c.w(), 65535);
    let d = comp_scale::<i16>(vec4::new(0.0, -1.0, 0.5, 1.0));
    assert_eq(d, i16vec4::new(0, -32768, 16383, 32767));
}

@test
fn fcomp_max_ignores_nan() {
    assert(near(fcomp_max(vec4::new(f32::nan(), 0.2, 0.5, 1.0)), 1.0, f32::epsilon()));
    assert(near(fcomp_max(vec4::new(2.0, f32::nan(), 0.3, 0.7)), 2.0, f32::epsilon()));
    assert(fcomp_max(vec4::splat(f32::nan())).is_nan());
}

@test
fn fcomp_min_ignores_nan() {
    assert(near(fcomp_min(vec4::new(f32::nan(), 0.2, 0.5, 1.0)), 0.2, f32::epsilon()));
    assert(near(fcomp_min(vec4::new(2.0, f32::nan(), 0.3, 0.7)), 0.3, f32::epsilon()));
    assert(fcomp_min(vec4::splat(f32::nan())).is_nan());
}

@test
fn comp_normalize_and_scale_bits() {
    let n = comp_normalize::<f32>(i16vec4::new(i16::MIN, -1, 0, i16::MAX));
    assert_eq(f32_bits(n.y()), 0xb7800000u32);
    assert_eq(f32_bits(n.z()), 0x37800000u32);
    let u = comp_normalize::<f64>(u64vec2::new(0, u64::MAX));
    assert_eq(u, dvec2::new(0.0, 1.0));
    let i = comp_normalize::<f64>(ivec2::new(i32::MIN, i32::MAX));
    assert_eq(i, dvec2::new(-1.0, 1.0));
    let f = comp_normalize::<f64>(vec2::new(0.1, -3.0));
    assert_eq(f, dvec2::new(0.1f32, -3.0));
    let g = comp_scale::<f32>(dvec2::new(0.1, -3.0));
    assert_eq(g, vec2::new(0.1, -3.0));
    let w = comp_scale::<u32>(dvec3::new(0.0, 0.5, 1.0));
    assert_eq(w, uvec3::new(0, 2147483647, 4294967295));
    let saturated = comp_scale::<i8>(vec2::new(2.0, -3.0));
    assert_eq(saturated, i8vec2::new(127, -128));
}

@test
fn comp_add_mul_min_max() {
    assert_eq(f32_bits(comp_add(vec3::new(0.1, 0.2, 0.3))), 0x3f19999au32);
    assert_eq(f32_bits(comp_mul(vec3::new(0.1, 0.2, 0.3))), 0x3bc49ba7u32);
    assert(same_bits64(comp_add(dvec2::new(-0.0, -0.0)), 0.0));
    assert_eq(comp_add(i8vec3::new(100, 100, 100)), 44i8);
    assert_eq(comp_mul(u8vec2::new(16, 17)), 16u8);
    assert_eq(comp_add(uvec1::new(7)), 7u32);
    assert_eq(comp_min(ivec4::new(3, -2, 9, -2)), -2);
    assert_eq(comp_max(u64vec3::new(3, u64::MAX, 9)), u64::MAX);
    assert_eq(comp_min(vec3::new(2.0, f32::nan(), 1.0)), 1.0);
    assert(comp_min(vec3::new(f32::nan(), 0.0, 1.0)).is_nan());
    assert(comp_max(dvec2::new(f64::nan(), 5.0)).is_nan());
    assert_eq(comp_max(dvec2::new(5.0, f64::nan())), 5.0);
    assert_eq(fcomp_min(dvec1::new(-4.0)), -4.0);
    assert_eq(fcomp_max(dvec3::new(f64::nan(), -4.0, f64::nan())), -4.0);
}

const C_COMP_ADD: i32 = comp_add(ivec4::new(1, 2, 3, 4));
const C_COMP_NORMALIZE: vec2 = comp_normalize::<f32>(u8vec2::new(0, 255));
const C_COMP_SCALE: i8vec2 = comp_scale::<i8>(vec2::new(-1.0, 1.0));

@test
fn component_wise_constants() {
    assert_eq(C_COMP_ADD, 10);
    assert_eq(C_COMP_NORMALIZE, vec2::new(0.0, 1.0));
    assert_eq(C_COMP_SCALE, i8vec2::new(-128, 127));
}
