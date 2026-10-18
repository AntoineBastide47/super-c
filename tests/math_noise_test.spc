// std::math::noise: Perlin, periodic Perlin and simplex noise at the origin, exact f32 and f64 result
// bits, the range of the f64 3D simplex noise, Perlin noise zero on the lattice, the period of the
// periodic form, the value range and noise in constant initializers.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::noise as *;

@test
fn origin() {
    assert_eq(simplex(vec2::splat(0.0)), 0.0f32);
    assert_eq(f32_bits(simplex(vec3::splat(0.0))), 0xbed30bb7u32);
    assert_eq(simplex(vec4::splat(0.0)), 0.0f32);
    assert(simplex(dvec3::splat(0.0)).abs() <= 1.0);
    assert_eq(perlin(vec2::splat(0.0)), 0.0f32);
    assert_eq(perlin(dvec3::splat(0.0)), 0.0f64);
    assert_eq(perlin(vec4::splat(0.0)), 0.0f32);
    assert_eq(perlin_periodic(dvec2::splat(0.0), dvec2::splat(2.0)), 0.0f64);
    assert_eq(perlin_periodic(vec3::splat(0.0), vec3::splat(2.0)), 0.0f32);
    assert_eq(perlin_periodic(dvec4::splat(0.0), dvec4::splat(2.0)), 0.0f64);
}

@test
fn bits_f32() {
    assert_eq(f32_bits(perlin(vec2::new(0.3, 0.7))), 0xbedaea54u32);
    assert_eq(f32_bits(perlin(vec3::new(0.3, 0.7, 1.2))), 0x3a96fce7u32);
    assert_eq(f32_bits(perlin(vec4::new(0.3, 0.7, 1.2, 2.5))), 0xbe469093u32);
    assert_eq(f32_bits(perlin_periodic(vec2::new(0.3, 0.7), vec2::splat(2.0))), 0xbedaea54u32);
    assert_eq(f32_bits(perlin_periodic(vec3::new(0.3, 0.7, 1.2), vec3::splat(2.0))), 0xbe8055efu32);
    assert_eq(f32_bits(perlin_periodic(vec4::new(0.3, 0.7, 1.2, 2.5), vec4::splat(2.0))), 0xbf21d10fu32);
    assert_eq(f32_bits(simplex(vec2::new(0.3, 0.7))), 0xbee29f0bu32);
    assert_eq(f32_bits(simplex(vec3::new(0.3, 0.7, 1.2))), 0xbbbcac1au32);
    assert_eq(f32_bits(simplex(vec4::new(0.3, 0.7, 1.2, 2.5))), 0x3e905e18u32);
}

@test
fn bits_f64() {
    assert_eq(f64_bits(perlin(dvec2::new(0.3, 0.7))), 0xbfdb5d4a5f0eca50u64);
    assert_eq(f64_bits(perlin(dvec3::new(0.3, 0.7, 1.2))), 0xbfce05fa0bd8a89cu64);
    assert_eq(f64_bits(perlin(dvec4::new(0.3, 0.7, 1.2, 2.5))), 0xbfc8d212f3342df4u64);
    assert_eq(f64_bits(perlin_periodic(dvec2::new(0.3, 0.7), dvec2::splat(2.0))), 0xbfdb5d4a5f0eca50u64);
    assert_eq(f64_bits(perlin_periodic(dvec3::new(0.3, 0.7, 1.2), dvec3::splat(2.0))), 0xbfd00abe5cbba141u64);
    assert_eq(f64_bits(perlin_periodic(dvec4::new(0.3, 0.7, 1.2, 2.5), dvec4::splat(2.0))), 0xbfe43a2276ce0dd3u64);
    assert_eq(f64_bits(simplex(dvec2::new(0.3, 0.7))), 0xbfdc53e4ec4de150u64);
    assert_eq(f64_bits(simplex(dvec3::new(0.3, 0.7, 1.2))), 0xbf7795872456b01eu64);
    assert_eq(f64_bits(simplex(dvec4::new(0.3, 0.7, 1.2, 2.5))), 0xbfc525bfebac2c03u64);
}

// The f64 3D simplex noise scales by 0.142857142857, a little below 1/7, so a permutation value that is a
// multiple of 7 maps to a gradient outside the octahedron; the result reaches about 3.3 there.
@test
fn f64_simplex3_out_of_range() {
    assert(simplex(dvec3::new(-3.0, -2.0, 1.0)).less(-3.28));
    assert(simplex(vec3::new(-3.0, -2.0, 1.0)).abs() <= 1.0);
}

@test
fn perlin_is_zero_on_the_lattice() {
    for i in 0..9 {
        let x = i as f32 - 4.0;
        assert_eq(perlin(vec2::new(x, 3.0 - x)), 0.0f32);
        assert_eq(perlin(dvec3::new(x, 2.0, -x)), 0.0f64);
        assert_eq(perlin(vec4::new(x, -1.0, 2.0 * x, 5.0)), 0.0f32);
    }
}

@test
fn periodic_form_repeats() {
    let rep2 = vec2::new(3.0, 5.0);
    let rep3 = dvec3::new(4.0, 2.0, 6.0);
    let rep4 = vec4::new(2.0, 3.0, 4.0, 5.0);
    for i in 0..16 {
        let t = i as f32 * 0.375 - 2.5;
        let p2 = vec2::new(t, 0.25 - t);
        assert_eq(perlin_periodic(p2 + rep2, rep2), perlin_periodic(p2, rep2));
        let p3 = dvec3::new(t, 0.75, -t);
        assert_eq(perlin_periodic(p3 + rep3, rep3), perlin_periodic(p3, rep3));
        let p4 = vec4::new(t, 1.5, -t, 0.125);
        assert_eq(perlin_periodic(p4 + rep4, rep4), perlin_periodic(p4, rep4));
    }
}

@test
fn values_stay_in_range() {
    for i in 0..24 {
        for j in 0..24 {
            let x = i as f32 * 0.173 - 3.0;
            let y = j as f32 * 0.191 - 2.0;
            assert(perlin(vec2::new(x, y)).abs() <= 1.1);
            assert(perlin(vec3::new(x, y, x * y)).abs() <= 1.1);
            assert(perlin(vec4::new(x, y, 1.5, y - x)).abs() <= 1.1);
            assert(simplex(vec2::new(x, y)).abs() <= 1.1);
            assert(simplex(vec3::new(x, y, x * y)).abs() <= 1.1);
            assert(simplex(vec4::new(x, y, 1.5, y - x)).abs() <= 1.1);
            let d = dvec2::new(x, y);
            assert(perlin(d).abs() <= 1.1);
            assert(perlin(d.append(0.5)).abs() <= 1.1);
            assert(simplex(d).abs() <= 1.1);
            assert(simplex(d.concat(dvec2::new(0.5, -0.25))).abs() <= 1.1);
        }
    }
}

// Noise in constant initializers: compile-time evaluation gives the same bits as the run.
const PERLIN3: f32 = perlin(vec3::new(0.3, 0.7, 1.2));
const SIMPLEX4: f64 = simplex(dvec4::new(0.3, 0.7, 1.2, 2.5));
static_assert(f32_bits(PERLIN3) == 0x3a96fce7 && f64_bits(SIMPLEX4) == 0xbfc525bfebac2c03);

@test
fn noise_constants() {
    assert_eq(f32_bits(PERLIN3), 0x3a96fce7u32);
    assert_eq(f64_bits(SIMPLEX4), 0xbfc525bfebac2c03u64);
    assert_eq(f32_bits(PERLIN3), f32_bits(perlin(vec3::new(0.3, 0.7, 1.2))));
}
