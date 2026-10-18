// std::math::compare: exact and ordered component tests, epsilon and ULP tests on scalars, vectors and
// matrices, float steps and distances, then `<=` against `<` at the epsilon, the scalar and vector ULP
// tests on signs, the prev_float direction, integer promotion in the scalar epsilon test, NaN, and
// constant initializers.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::compare as *;

@test
fn vector_relational_not() {
    assert(all(not_(bvec1::splat(false))));
    assert(all(not_(bvec2::splat(false))));
    assert(all(not_(bvec3::splat(false))));
    assert(all(not_(bvec4::splat(false))));
}

@test
fn vector_relational_less() {
    assert(all(less_than(vec2::new(1.0, 2.0), vec2::new(2.0, 3.0))));
    assert(all(less_than_equal(vec2::new(1.0, 2.0), vec2::new(2.0, 3.0))));
    assert(all(less_than(vec3::new(1.0, 2.0, 3.0), vec3::new(2.0, 3.0, 4.0))));
    assert(all(less_than_equal(vec3::new(1.0, 2.0, 3.0), vec3::new(2.0, 3.0, 4.0))));
    assert(all(less_than(vec4::new(1.0, 2.0, 3.0, 4.0), vec4::new(2.0, 3.0, 4.0, 5.0))));
    assert(all(less_than_equal(vec4::new(1.0, 2.0, 3.0, 4.0), vec4::new(2.0, 3.0, 4.0, 5.0))));
    assert(all(less_than(ivec2::new(1, 2), ivec2::new(2, 3))));
    assert(all(less_than_equal(ivec2::new(1, 2), ivec2::new(1, 3))));
    assert(all(less_than(ivec3::new(1, 2, 3), ivec3::new(2, 3, 4))));
    assert(all(less_than_equal(ivec3::new(1, 2, 3), ivec3::new(1, 3, 4))));
    assert(all(less_than(ivec4::new(1, 2, 3, 4), ivec4::new(2, 3, 4, 5))));
    assert(all(less_than_equal(ivec4::new(1, 2, 3, 4), ivec4::new(1, 3, 4, 5))));
}

@test
fn vector_relational_greater() {
    assert(all(greater_than(vec2::new(2.0, 3.0), vec2::new(1.0, 2.0))));
    assert(all(greater_than_equal(vec2::new(2.0, 3.0), vec2::new(1.0, 2.0))));
    assert(all(greater_than(vec3::new(2.0, 3.0, 4.0), vec3::new(1.0, 2.0, 3.0))));
    assert(all(greater_than_equal(vec3::new(2.0, 3.0, 4.0), vec3::new(1.0, 2.0, 3.0))));
    assert(all(greater_than(vec4::new(2.0, 3.0, 4.0, 5.0), vec4::new(1.0, 2.0, 3.0, 4.0))));
    assert(all(greater_than_equal(vec4::new(2.0, 3.0, 4.0, 5.0), vec4::new(1.0, 2.0, 3.0, 4.0))));
    assert(all(greater_than(ivec2::new(2, 3), ivec2::new(1, 2))));
    assert(all(greater_than_equal(ivec2::new(1, 3), ivec2::new(1, 2))));
    assert(all(greater_than(ivec3::new(2, 3, 4), ivec3::new(1, 2, 3))));
    assert(all(greater_than_equal(ivec3::new(1, 3, 4), ivec3::new(1, 2, 3))));
    assert(all(greater_than(ivec4::new(2, 3, 4, 5), ivec4::new(1, 2, 3, 4))));
    assert(all(greater_than_equal(ivec4::new(1, 3, 4, 5), ivec4::new(1, 2, 3, 4))));
}

@test
fn vector_relational_equal() {
    assert(all(equal(ivec2::new(1, 2), ivec2::new(1, 2))));
    assert(all(equal(ivec3::new(1, 2, 3), ivec3::new(1, 2, 3))));
    assert(all(equal(ivec4::new(1, 2, 3, 4), ivec4::new(1, 2, 3, 4))));
}

@test
fn scalar_equal_epsilon() {
    assert(equal_eps(1.01f32, 1.02f32, 0.1f32));
    assert(!equal_eps(1.01f32, 1.02f32, 0.001f32));
}

@test
fn scalar_not_equal_epsilon() {
    assert(not_equal_eps(1.01f32, 1.02f32, 0.001f32));
    assert(!not_equal_eps(1.01f32, 1.02f32, 0.1f32));
}

@test
fn scalar_equal_ulps() {
    let p1 = next_float(1.0f32);
    assert(equal_ulps(1.0f32, p1, 1));
    let p2 = next_float(p1);
    assert(!equal_ulps(1.0f32, p2, 1));
    let m1 = prev_float(1.0f32);
    assert(equal_ulps(1.0f32, m1, 1));
    let m2 = prev_float(m1);
    assert(!equal_ulps(1.0f32, m2, 1));
}

@test
fn scalar_not_equal_ulps() {
    let p1 = next_float(1.0f32);
    assert(!not_equal_ulps(1.0f32, p1, 1));
    let p2 = next_float(p1);
    assert(not_equal_ulps(1.0f32, p2, 1));
    let m1 = prev_float(1.0f32);
    assert(!not_equal_ulps(1.0f32, m1, 1));
    let m2 = prev_float(m1);
    assert(not_equal_ulps(1.0f32, m2, 1));
}

@test
fn scalar_equal_sign() {
    assert(!equal_ulps(-0.0f32, 0.0f32, 2));
    assert(!equal_ulps(-0.0f64, 0.0f64, 2));
    assert(!equal_ulps(-1.0f32, 2.0f32, 2));
    assert(!equal_ulps(-1.0f64, 2.0f64, 2));
    assert(!equal_ulps(-0.00001f32, 1.0f32, 2));
    assert(!equal_ulps(-0.00001f64, 1.0f64, 2));
    assert(!equal_ulps(-1.0f32, 1.0f32, 2));
    assert(!equal_ulps(-1.0f64, 1.0f64, 2));
}

// `equal_eps` and `not_equal_eps` on one vector type, with a scalar and a vector epsilon.
fn vector_epsilon<T: Float, const N: usize>() {
    let a = Vec::<T, N>::splat(T::from_f32(1.01));
    let b = Vec::<T, N>::splat(T::from_f32(1.02));
    let e1 = T::from_f32(0.1);
    let e2 = T::from_f32(0.001);
    assert(all(equal_eps(a, b, e1)));
    assert(all(equal_eps(a, b, Vec::<T, N>::splat(e1))));
    assert(!any(equal_eps(a, b, e2)));
    assert(!any(equal_eps(a, b, Vec::<T, N>::splat(e2))));
    assert(all(not_equal_eps(a, b, e2)));
    assert(all(not_equal_eps(a, b, Vec::<T, N>::splat(e2))));
    assert(!any(not_equal_eps(a, b, e1)));
    assert(!any(not_equal_eps(a, b, Vec::<T, N>::splat(e1))));
}

@test
fn vector_equal_epsilon() {
    vector_epsilon::<f32, 1>();
    vector_epsilon::<f32, 2>();
    vector_epsilon::<f32, 3>();
    vector_epsilon::<f32, 4>();
    vector_epsilon::<f64, 1>();
    vector_epsilon::<f64, 2>();
    vector_epsilon::<f64, 3>();
    vector_epsilon::<f64, 4>();
}

// `equal_ulps` and `not_equal_ulps` on vectors one and two ULPs away, in both directions.
fn vector_ulps<T: Float>() {
    let ones = Vec::<T, 4>::splat(T::one());
    let p1 = next_float::<T, T>(T::one());
    let p2 = next_float::<T, T>(p1);
    let m1 = prev_float::<T, T>(T::one());
    let m2 = prev_float::<T, T>(m1);
    assert(all(equal_ulps(ones, Vec::<T, 4>::splat(p1), 1)));
    assert(!all(equal_ulps(ones, Vec::<T, 4>::splat(p2), 1)));
    assert(all(equal_ulps(ones, Vec::<T, 4>::splat(m1), 1)));
    assert(!all(equal_ulps(ones, Vec::<T, 4>::splat(m2), 1)));
    assert(!all(not_equal_ulps(ones, Vec::<T, 4>::splat(p1), 1)));
    assert(all(not_equal_ulps(ones, Vec::<T, 4>::splat(p2), 1)));
    assert(!all(not_equal_ulps(ones, Vec::<T, 4>::splat(m1), 1)));
    assert(all(not_equal_ulps(ones, Vec::<T, 4>::splat(m2), 1)));
}

@test
fn vector_equal_ulps() {
    vector_ulps::<f32>();
    vector_ulps::<f64>();
}

// `equal_eps` and `not_equal_eps` on one matrix type, with a scalar and a per-column epsilon.
fn matrix_epsilon<T: Float, const C: usize, const R: usize>() {
    let e = T::from_f32(0.001);
    let one = Mat::<T, C, R>::diagonal(T::one());
    let two = Mat::<T, C, R>::diagonal(T::from_i64(2));
    assert(all(equal_eps(one, one, e)));
    assert(!all(equal_eps(one, two, Vec::<T, C>::splat(e))));
    assert(!any(not_equal_eps(one, one, e)));
    assert(any(not_equal_eps(one, two, Vec::<T, C>::splat(e))));
}

@test
fn matrix_equal_epsilon() {
    matrix_epsilon::<f32, 2, 2>();
    matrix_epsilon::<f32, 2, 3>();
    matrix_epsilon::<f32, 2, 4>();
    matrix_epsilon::<f32, 3, 2>();
    matrix_epsilon::<f32, 3, 3>();
    matrix_epsilon::<f32, 3, 4>();
    matrix_epsilon::<f32, 4, 2>();
    matrix_epsilon::<f32, 4, 3>();
    matrix_epsilon::<f32, 4, 4>();
    matrix_epsilon::<f64, 2, 2>();
    matrix_epsilon::<f64, 2, 3>();
    matrix_epsilon::<f64, 2, 4>();
    matrix_epsilon::<f64, 3, 2>();
    matrix_epsilon::<f64, 3, 3>();
    matrix_epsilon::<f64, 3, 4>();
    matrix_epsilon::<f64, 4, 2>();
    matrix_epsilon::<f64, 4, 3>();
    matrix_epsilon::<f64, 4, 4>();
}

// `equal_ulps` and `not_equal_ulps` on matrices one and two ULPs away, in both directions.
fn matrix_ulps<T: Float>() {
    let ones = Mat::<T, 4, 4>::diagonal(T::one());
    let p1 = next_float::<T, T>(T::one());
    let p2 = next_float::<T, T>(p1);
    let m1 = prev_float::<T, T>(T::one());
    let m2 = prev_float::<T, T>(m1);
    assert(all(equal_ulps(ones, Mat::<T, 4, 4>::diagonal(p1), 1)));
    assert(!all(equal_ulps(ones, Mat::<T, 4, 4>::diagonal(p2), 1)));
    assert(all(equal_ulps(ones, Mat::<T, 4, 4>::diagonal(m1), 1)));
    assert(!all(equal_ulps(ones, Mat::<T, 4, 4>::diagonal(m2), 1)));
    assert(!all(not_equal_ulps(ones, Mat::<T, 4, 4>::diagonal(p1), 1)));
    assert(all(not_equal_ulps(ones, Mat::<T, 4, 4>::diagonal(p2), 1)));
    assert(!all(not_equal_ulps(ones, Mat::<T, 4, 4>::diagonal(m1), 1)));
    assert(all(not_equal_ulps(ones, Mat::<T, 4, 4>::diagonal(m2), 1)));
}

@test
fn matrix_equal_ulps() {
    matrix_ulps::<f32>();
    matrix_ulps::<f64>();
}

@test
fn epsilon_defined() {
    let e = f32::epsilon();
    assert(all(epsilon_equal(vec2::splat(0.0), vec2::splat(0.0), vec2::splat(e))));
    assert(all(epsilon_equal(vec3::splat(0.0), vec3::splat(0.0), vec3::splat(e))));
    assert(all(epsilon_equal(vec4::splat(0.0), vec4::splat(0.0), vec4::splat(e))));
    assert(all(epsilon_not_equal(vec2::splat(1.0), vec2::splat(2.0), vec2::splat(e))));
    assert(all(epsilon_not_equal(vec3::splat(1.0), vec3::splat(2.0), vec3::splat(e))));
    assert(all(epsilon_not_equal(vec4::splat(1.0), vec4::splat(2.0), vec4::splat(e))));
    assert(all(epsilon_equal(vec2::splat(0.0), vec2::splat(0.0), e)));
    assert(all(epsilon_equal(vec3::splat(0.0), vec3::splat(0.0), e)));
    assert(all(epsilon_equal(vec4::splat(0.0), vec4::splat(0.0), e)));
    assert(all(epsilon_not_equal(vec2::splat(1.0), vec2::splat(2.0), e)));
    assert(all(epsilon_not_equal(vec3::splat(1.0), vec3::splat(2.0), e)));
    assert(all(epsilon_not_equal(vec4::splat(1.0), vec4::splat(2.0), e)));
}

// Scalar `epsilon_equal` with a tolerance of two epsilons, in both argument orders.
fn epsilon_scalar<T: Float + EpsilonEqual<T, Bools = bool>>() {
    let e = T::epsilon();
    let two_e = e * T::from_i64(2);
    assert(epsilon_equal(e, e, two_e));
    assert(epsilon_equal(T::zero(), T::zero() + e, two_e));
    assert(epsilon_equal(T::zero(), T::zero() - e, two_e));
    assert(epsilon_equal(T::zero() + e, T::zero(), two_e));
    assert(epsilon_equal(T::zero() - e, T::zero(), two_e));
}

@test
fn epsilon_scalar_equal() {
    epsilon_scalar::<f32>();
    epsilon_scalar::<f64>();
}

// Scalar ULP steps and distances: one step here, then steps of 10 and 100.
@test
fn ulp_scalar_dist() {
    let b = next_float(1.0f32);
    assert(not_equal_ulps(1.0f32, b, 0));
    let c = prev_float(b);
    assert(equal_ulps(1.0f32, c, 0));
    assert_eq(float_distance(1.0f32, b), 1);
    assert_eq(float_distance(1.0f32, c), 0);
    let bd = next_float(1.0f64);
    assert(not_equal_ulps(1.0f64, bd, 0));
    let cd = prev_float(bd);
    assert(equal_ulps(1.0f64, cd, 0));
    assert_eq(float_distance(1.0f64, bd), 1i64);
    assert_eq(float_distance(1.0f64, cd), 0i64);
}

@test
fn ulp_scalar_step() {
    let mut i: i32 = 10;
    while i < 1000 {
        let b = next_float_ulps(1.0f32, i);
        assert(not_equal_ulps(1.0f32, b, 0));
        let c = prev_float_ulps(b, i);
        assert(equal_ulps(1.0f32, c, 0));
        assert_eq(float_distance(1.0f32, b), i);
        assert_eq(float_distance(1.0f32, c), 0);
        let bd = next_float_ulps(1.0f64, i);
        assert(not_equal_ulps(1.0f64, bd, 0));
        let cd = prev_float_ulps(bd, i);
        assert(equal_ulps(1.0f64, cd, 0));
        assert_eq(float_distance(1.0f64, bd), i as i64);
        assert_eq(float_distance(1.0f64, cd), 0i64);
        i *= 10;
    }
}

@test
fn ulp_vector_dist() {
    let a = vec4::splat(1.0);
    let b = next_float(a);
    assert(any(not_equal_ulps(a, b, 0)));
    let c = prev_float(b);
    assert(all(equal_ulps(a, c, 0)));
    assert(float_distance(a, b) == ivec4::splat(1));
    assert(float_distance(a, c) == ivec4::splat(0));
    let ad = dvec4::splat(1.0);
    let bd = next_float(ad);
    assert(any(not_equal_ulps(ad, bd, 0)));
    let cd = prev_float(bd);
    assert(all(equal_ulps(ad, cd, 0)));
    assert(float_distance(ad, bd).cast::<i32>() == ivec4::splat(1));
    assert(float_distance(ad, cd).cast::<i32>() == ivec4::splat(0));
}

@test
fn ulp_vector_step() {
    let mut i: i32 = 10;
    while i < 1000 {
        let a = vec4::splat(1.0);
        let b = next_float_ulps(a, i);
        assert(any(not_equal_ulps(a, b, 0)));
        let c = prev_float_ulps(b, i);
        assert(all(equal_ulps(a, c, 0)));
        assert(float_distance(a, b) == ivec4::splat(i));
        assert(float_distance(a, c) == ivec4::splat(0));
        let ad = dvec4::splat(1.0);
        let bd = next_float_ulps(ad, i);
        assert(any(not_equal_ulps(ad, bd, 0)));
        let cd = prev_float_ulps(bd, i);
        assert(all(equal_ulps(ad, cd, 0)));
        assert(float_distance(ad, bd).cast::<i32>() == ivec4::splat(i));
        assert(float_distance(ad, cd).cast::<i32>() == ivec4::splat(0));
        i *= 10;
    }
}

// `equal_eps` is `<=`, `epsilon_equal` is `<`: they differ exactly at the epsilon.
@test
fn epsilon_boundary() {
    assert(equal_eps(1.0f32, 1.5f32, 0.5f32));
    assert(!epsilon_equal(1.0f32, 1.5f32, 0.5f32));
    assert(!not_equal_eps(1.0f32, 1.5f32, 0.5f32));
    assert(epsilon_not_equal(1.0f32, 1.5f32, 0.5f32));
    assert(equal_eps(dvec2::new(1.0, 3.0), dvec2::new(1.5, 4.0), 0.5f64) == bvec2::new(true, false));
    assert(epsilon_equal(dvec2::new(1.0, 3.0), dvec2::new(1.5, 4.0), 0.5f64) == bvec2::new(false, false));
    assert(equal_eps(ivec2::new(1, 3), ivec2::new(2, 5), ivec2::new(1, 1)) == bvec2::new(true, false));
    assert(epsilon_equal(ivec2::new(1, 3), ivec2::new(2, 5), 2) == bvec2::new(true, false));
}

// A scalar ULP test fails on different signs; a vector component then compares the bits without the
// sign, so -0 equals +0 and every value equals its negation.
@test
fn ulps_sign() {
    assert(!equal_ulps(-0.0f32, 0.0f32, 0));
    assert(!equal_ulps(-1.0f32, 1.0f32, 100));
    assert(all(equal_ulps(vec1::new(-0.0), vec1::new(0.0), 0)));
    assert(all(equal_ulps(dvec3::splat(-0.0), dvec3::splat(0.0), 0)));
    assert(all(equal_ulps(vec2::new(-1.0, 1.0), vec2::new(1.0, -1.0), 0)));
    assert(equal_ulps(vec2::new(-1.0, 2.0), vec2::new(1.0, -1.0), 100) == bvec2::new(true, false));
    assert(equal_ulps(mat2::diagonal(-0.0), mat2::zero(), 0) == bvec2::splat(true));
    assert(not_equal_ulps(mat2::diagonal(-0.0), mat2::zero(), ivec2::new(0, 0)) == bvec2::splat(false));
}

// prev_float steps toward the smallest positive normal value: down above it, up below it, so negative
// values move toward zero and zero moves to the smallest subnormal.
@test
fn prev_float_direction() {
    assert(prev_float(1.0f32) < 1.0f32);
    assert(prev_float(-1.0f32) > -1.0f32);
    assert_eq(f32_bits(prev_float(0.0f32)), 1u32);
    assert_eq(f64_bits(prev_float(0.0f64)), 1u64);
    assert_eq(prev_float(f32::min_positive()), f32::min_positive());
    assert_eq(next_float(f32::max_finite()), f32::max_finite());
    assert_eq(next_float(f64::infinity()), f64::max_finite());
    assert(next_float(f32::nan()).is_nan());
    assert(next_float_ulps(vec2::new(1.0, 1.0), ivec2::new(0, 2)) == vec2::new(1.0, next_float(next_float(1.0f32))));
}

// An 8- or 16-bit integer scalar subtracts in `i64`; vector components and wider unsigned scalars wrap
// in their type, and `abs` of an unsigned value is the value.
@test
fn integer_epsilon() {
    let lo: i8 = -128;
    let hi: i8 = 127;
    assert(!equal_eps(lo, hi, 1i8));
    assert(all(equal_eps(Vec::<i8, 1>::new(lo), Vec::<i8, 1>::new(hi), 1i8)));
    assert(!equal_eps(0u8, 255u8, 1u8));
    assert(all(equal_eps(Vec::<u8, 1>::new(0), Vec::<u8, 1>::new(255), 1u8)));
    assert(!equal_eps(0u32, 1u32, 1u32));
    assert(equal_eps(1u32, 0u32, 1u32));
    assert(equal_eps(-3, 4, 7));
    assert(not_equal_eps(-3i64, 4i64, 6i64));
}

@test
fn nan_comparisons() {
    let n = f32::nan();
    let v = vec2::new(n, 1.0);
    assert(equal(v, v) == bvec2::new(false, true));
    assert(not_equal(v, v) == bvec2::new(true, false));
    assert(less_than_equal(v, v) == bvec2::new(false, true));
    assert(greater_than_equal(v, v) == bvec2::new(false, true));
    assert(!equal_eps(n, n, 1.0f32));
    assert(!not_equal_eps(n, n, 1.0f32));
    assert(!epsilon_equal(n, n, 1.0f32));
    assert(!epsilon_not_equal(n, n, 1.0f32));
    assert(equal_ulps(n, n, 0));
}

@test
fn matrix_exact() {
    let a = mat2x3::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0);
    let mut b = a;
    b.c[1].e[2] = 7.0;
    assert(equal(a, a) == bvec2::splat(true));
    assert(equal(a, b) == bvec2::new(true, false));
    assert(not_equal(a, b) == bvec2::new(false, true));
    assert(equal(imat2::identity(), imat2::identity()) == bvec2::splat(true));
    assert(equal(bvec3::new(true, false, true), bvec3::new(true, true, true)) == bvec3::new(true, false, true));
    assert(any(bvec4::new(false, false, true, false)));
    assert(!all(bvec4::new(true, true, true, false)));
}

const ALL_LESS: bool = all(less_than(ivec3::new(1, 2, 3), ivec3::new(2, 3, 4)));
const ANY_EQUAL: bool = any(equal(vec2::new(1.0, 2.0), vec2::new(0.0, 2.0)));
const NOT_V: Vec<bool, 2> = not_(bvec2::new(true, false));
const MAT_EQ: Vec<bool, 2> = equal(mat2::identity(), mat2::diagonal(2.0));
const EPS_EQ: bool = equal_eps(1.01f32, 1.02f32, 0.1f32);
const EPS_VEC: Vec<bool, 3> = equal_eps(vec3::new(1.0, 2.0, 3.0), vec3::new(1.0, 2.5, 3.0), 0.25f32);

@test
fn constant_initializers() {
    assert(ALL_LESS);
    assert(ANY_EQUAL);
    assert(NOT_V == bvec2::new(false, true));
    assert(MAT_EQ == bvec2::splat(false));
    assert(EPS_EQ);
    assert(EPS_VEC == bvec3::new(true, false, true));
}
