// std::math::fused: each function is the fused sum of squares in index order, bit for bit, at run time and
// in constants; exact results stay exact; and over a fixed sample its mean error against an f64 reference
// is no larger than the unfused function's.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::geometric as *;
import std::math::fused as *;
import std::float as fl;

// A fixed sequence of values in [-1, 1).
fn next(r: &mut u64) f32 {
    *r = r.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    return (*r >> 40 & 0xFFFFFF) as f32 / 8388608.0 - 1.0;
}

// The error of `x` in units in the last place of the f32 nearest to the reference `r`.
fn ulps(x: f32, r: f64) f64 {
    let n = (r as f32).abs();
    let up = fl::f32_from_bits(fl::f32_bits(n) + 1) as f64 - n as f64;
    return (x as f64 - r).abs() / up;
}

@test
fn length2_is_the_fused_chain() {
    let mut r: u64 = 7;
    for _ in 0..1000 {
        let v = vec4::new(next(&mut r), next(&mut r), next(&mut r), next(&mut r));
        let chain = v.e[3].mul_add(v.e[3], v.e[2].mul_add(v.e[2], v.e[1].mul_add(v.e[1], v.e[0] * v.e[0])));
        assert(fl::f32_bits(length2_fused(v)) == fl::f32_bits(chain));
        let d = dvec2::new(next(&mut r), next(&mut r));
        assert(length2_fused(d) == d.e[1].mul_add(d.e[1], d.e[0] * d.e[0]));
    }
}

@test
fn every_size() {
    assert(length2_fused(vec1::new(-3.0)) == 9.0);
    let v = Vec::<f32, 7>::splat(2.0);
    assert(length2_fused(v) == 28.0);
    assert(length_fused(Vec::<f64, 9>::splat(1.0)) == 3.0);
}

@test
fn exact_results_stay_exact() {
    assert(length_fused(vec3::new(3.0, 4.0, 0.0)) == 5.0);
    assert(length_fused(vec3::new(0.0, -2.0, 0.0)) == 2.0);
    assert(normalize_fused(vec3::new(0.0, 0.0, -7.0)) == vec3::new(0.0, 0.0, -1.0));
    assert(distance_fused(vec2::new(1.0, 1.0), vec2::new(4.0, 5.0)) == 5.0);
    assert(distance2_fused(vec2::new(1.0, 1.0), vec2::new(4.0, 5.0)) == 25.0);
    let z = normalize_fused(vec3::zero());
    assert(z.e[0].is_nan() && z.e[1].is_nan() && z.e[2].is_nan());
}

const L: f32 = length_fused(vec3::new(0.1, 0.7, -0.3));
const N3: vec3 = normalize_fused(vec3::new(0.1, 0.7, -0.3));

@c.noinline
fn opaque(v: vec3) vec3 {
    return v;
}

@test
fn constants_equal_the_run_time() {
    let v = opaque(vec3::new(0.1, 0.7, -0.3));
    assert(fl::f32_bits(L) == fl::f32_bits(length_fused(v)));
    let n = normalize_fused(v);
    for i in 0..N3.len() {
        assert(fl::f32_bits(N3[i]) == fl::f32_bits(n[i]));
    }
}

@test
fn at_least_as_accurate_as_unfused() {
    let mut r: u64 = 0x2545F4914F6CDD1D;
    let mut eu: f64 = 0.0;
    let mut ef: f64 = 0.0;
    for _ in 0..20000 {
        let v = vec3::new(next(&mut r), next(&mut r), next(&mut r));
        let x = v.e[0] as f64 * v.e[0] as f64 + v.e[1] as f64 * v.e[1] as f64 + v.e[2] as f64 * v.e[2] as f64;
        eu += ulps(length2(v), x);
        ef += ulps(length2_fused(v), x);
    }
    assert(ef <= eu, "the fused squared length is at least as accurate on average");
}
