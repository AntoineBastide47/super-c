// std::math::color: sRGB round trips with and without gamma, HSV, saturation and YCoCg round trips, then
// bit-exact values of every conversion, the alpha passthrough, the clamp of the linear input, the branch
// edges, 1- and 2-component colors, the HSV sectors and greys, integer YCoCg with 8-, 16- and 32-bit
// wrapping, and constant initializers. The XYZ formulas are not inverses, so XYZ has no round trip.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::compare as *;
import std::math::color as *;

@test
fn srgb_round_trip() {
    let rgb = vec3::new(1.0, 0.5, 0.0);
    assert(all(epsilon_equal(rgb, convert_srgb_to_linear(convert_linear_to_srgb(rgb)), 0.00001f32)));
    let srgb = convert_linear_to_srgb_gamma(rgb, 2.8f32);
    assert(all(epsilon_equal(rgb, convert_srgb_to_linear_gamma(srgb, 2.8f32), 0.00001f32)));

    let rgba = vec4::new(1.0, 0.5, 0.0, 1.0);
    assert(all(epsilon_equal(rgba, convert_srgb_to_linear(convert_linear_to_srgb(rgba)), 0.00001f32)));
    let srgba = convert_linear_to_srgb_gamma(rgba, 2.8f32);
    assert(all(epsilon_equal(rgba, convert_srgb_to_linear_gamma(srgba, 2.8f32), 0.00001f32)));

    let gni = vec4::new(107.0, 107.0, 104.0, 131.0) / vec4::splat(255.0);
    assert(all(epsilon_equal(gni, convert_srgb_to_linear(convert_linear_to_srgb(gni)), 0.00001f32)));
}

@test
fn srgb_bits() {
    let s = convert_linear_to_srgb(vec4::new(1.0, 0.5, 0.0, 0.25));
    assert_eq(f32_bits(s.y()), 0x3f3c4098u32);
    let l = convert_srgb_to_linear(dvec3::new(0.5, 0.02, 1.0));
    assert_eq(f64_bits(l.x()), 0x3fcb65b3392f5354u64);
    assert_eq(f64_bits(l.y()), 0x3f595cbb0be377aeu64);
    let g = convert_linear_to_srgb_gamma(vec3::splat(0.25), 2.8f32);
    assert_eq(f32_bits(g.x()), 0x3f16891du32);
}

@test
fn alpha_passes_through() {
    let c = convert_linear_to_srgb(vec4::new(0.2, 0.4, 0.6, 7.5));
    assert_eq(c.w(), 7.5f32);
    let d = convert_srgb_to_linear_gamma(dvec4::new(0.2, 0.4, 0.6, -3.0), 2.2f64);
    assert_eq(d.w(), -3.0f64);
    let e = convert_linear_to_srgb(vec3::new(0.2, 0.4, 7.5));
    assert_eq(e.z(), 1.055f32 - 0.055f32);
}

@test
fn linear_input_is_clamped() {
    let c = convert_linear_to_srgb(dvec4::new(-1.0, 2.0, 0.001, 1.0));
    assert_eq(c.x(), 0.0f64);
    assert_eq(c.y(), 1.055f64 - 0.055f64);
    assert_eq(c.z(), 0.001f64 * 12.92f64);
    let n = convert_linear_to_srgb(vec2::new(f32::nan(), 0.0));
    assert(n.x().is_nan());
    assert_eq(n.y(), 0.0f32);
}

@test
fn branch_edges() {
    let below = convert_linear_to_srgb(vec1::new(0.0031307));
    assert_eq(below.x(), 0.0031307f32 * 12.92f32);
    let edge = convert_srgb_to_linear(dvec1::new(0.04045));
    assert_eq(edge.x(), 0.04045f64 * 0.07739938080495356037151702786378f64);
    let above = convert_srgb_to_linear(dvec2::new(0.5, 1.0));
    assert(epsilon_equal(above.y(), 1.0f64, 1e-12f64));
}

const SRGB: Vec<f32, 4> = convert_linear_to_srgb(vec4::new(1.0, 0.5, 0.0, 0.25));
const LINEAR: Vec<f64, 3> = convert_srgb_to_linear(dvec3::new(0.5, 0.02, 1.0));
const SRGB_GAMMA: Vec<f32, 3> = convert_linear_to_srgb_gamma(vec3::splat(0.25), 2.8f32);

@test
fn constant_initializers() {
    assert_eq(f32_bits(SRGB.y()), 0x3f3c4098u32);
    assert_eq(SRGB.w(), 0.25f32);
    assert_eq(f64_bits(LINEAR.x()), 0x3fcb65b3392f5354u64);
    assert_eq(f32_bits(SRGB_GAMMA.x()), 0x3f16891du32);
}

@test
fn hsv_round_trip() {
    let hsv = hsv_color(vec3::new(1.0, 0.5, 0.0));
    let rgb = rgb_color(hsv);
    assert(all(equal_eps(rgb, vec3::new(1.0, 0.5, 0.0), f32::epsilon())));
}

@test
fn full_saturation_keeps_color() {
    let color = saturation_color(1.0f32, vec4::new(1.0, 0.5, 0.0, 1.0));
    assert(all(equal_eps(color, vec4::new(1.0, 0.5, 0.0, 1.0), f32::epsilon())));
}

@test
fn ycocg_round_trip() {
    let ycocg = rgb_to_ycocg(vec3::new(1.0, 0.5, 0.0));
    let rgb = ycocg_to_rgb(ycocg);
    assert(all(equal_eps(rgb, vec3::new(1.0, 0.5, 0.0), f32::epsilon())));
}

@test
fn color_encoding_srgb() {
    let rgb = vec3::new(1.0, 0.5, 0.0);
    let srgb = convert_linear_to_srgb_gamma(rgb, 2.8f32);
    assert(all(epsilon_equal(rgb, convert_srgb_to_linear_gamma(srgb, 2.8f32), 0.00001f32)));
    let rgba = vec4::new(1.0, 0.5, 0.0, 1.0);
    assert(all(epsilon_equal(rgba, convert_srgb_to_linear(convert_linear_to_srgb(rgba)), 0.00001f32)));
    let srgba = convert_linear_to_srgb_gamma(rgba, 2.8f32);
    assert(all(epsilon_equal(rgba, convert_srgb_to_linear_gamma(srgba, 2.8f32), 0.00001f32)));
}

fn bits3(v: vec3) [u32; 3] {
    return [f32_bits(v.x()), f32_bits(v.y()), f32_bits(v.z())];
}

fn bits3d(v: dvec3) [u64; 3] {
    return [f64_bits(v.x()), f64_bits(v.y()), f64_bits(v.z())];
}

fn same3(a: [u32; 3], b: [u32; 3]) bool {
    return a[0] == b[0] && a[1] == b[1] && a[2] == b[2];
}

fn same3d(a: [u64; 3], b: [u64; 3]) bool {
    return a[0] == b[0] && a[1] == b[1] && a[2] == b[2];
}

@test
fn hsv_bits() {
    assert(same3(bits3(hsv_color(vec3::new(0.2, 0.7, 0.4))), [0x43100000, 0x3f36db6e, 0x3f333333]));
    let rgb = rgb_color(dvec3::new(200.0, 0.6, 0.9));
    assert(same3d(bits3d(rgb), [0x3fd70a3d70a3d70b, 0x3fe70a3d70a3d70a, 0x3feccccccccccccd]));
    assert_eq(luminosity(vec3::new(0.2, 0.7, 0.4)), f32_from_bits(0x3f05e354));
}

@test
fn hsv_sectors_and_greys() {
    assert_eq(rgb_color(vec3::new(30.0, 0.0, 0.25)), vec3::splat(0.25));
    assert_eq(hsv_color(vec3::splat(0.0)), vec3::splat(0.0));
    assert_eq(hsv_color(vec3::new(0.0, 0.0, 1.0)), vec3::new(240.0, 1.0, 1.0));
    assert_eq(hsv_color(vec3::new(1.0, 0.0, 1.0)), vec3::new(300.0, 1.0, 1.0));
    assert_eq(rgb_color(vec3::new(0.0, 1.0, 1.0)), vec3::new(1.0, 0.0, 0.0));
    assert(all(equal_eps(rgb_color(vec3::new(60.0, 1.0, 1.0)), vec3::new(1.0, 1.0, 0.0), 1e-6f32)));
    assert(all(equal_eps(rgb_color(vec3::new(120.0, 1.0, 1.0)), vec3::new(0.0, 1.0, 0.0), 1e-6f32)));
    assert(all(equal_eps(rgb_color(vec3::new(180.0, 1.0, 1.0)), vec3::new(0.0, 1.0, 1.0), 1e-6f32)));
    assert(all(equal_eps(rgb_color(vec3::new(240.0, 1.0, 1.0)), vec3::new(0.0, 0.0, 1.0), 1e-6f32)));
    assert(all(equal_eps(rgb_color(vec3::new(300.0, 1.0, 1.0)), vec3::new(1.0, 0.0, 1.0), 1e-6f32)));
    let past = rgb_color(vec3::new(400.0, 1.0, 1.0));
    assert_eq(past.x(), 1.0f32);
    assert_eq(past.z(), 0.0f32);
    assert_eq(rgb_color(vec3::new(-30.0, 1.0, 1.0)), vec3::new(1.0, 0.5, 0.0));
}

@test
fn saturation_bits() {
    let m = saturation(0.3f32);
    assert_eq(f32_bits(m.c[0].e[0]), 0x3ee5cbbcu32);
    assert_eq(f32_bits(m.c[1].e[0]), 0x3f0029f1u32);
    assert_eq(f32_bits(m.c[2].e[2]), 0x3eb379fbu32);
    assert_eq(m.c[3], vec4::new(0.0, 0.0, 0.0, 1.0));
    assert_eq(m.c[0].e[3], 0.0f32);
    assert(same3(bits3(saturation_color(0.3f32, vec3::new(0.2, 0.7, 0.4))), [0x3eebbd37, 0x3f1c4502, 0x3f053ac5]));
    let c4 = saturation_color(0.3f32, vec4::new(0.2, 0.7, 0.4, 0.5));
    assert_eq(c4.xyz(), saturation_color(0.3f32, vec3::new(0.2, 0.7, 0.4)));
    assert_eq(c4.w(), 0.5f32);
    assert(saturation(1i32) == imat4::identity());
    assert(saturation(1.0f64) == dmat4::identity());
}

@test
fn ycocg_bits() {
    assert(same3(bits3(rgb_to_ycocg(vec3::new(0.2, 0.7, 0.4))), [0x3f000000, 0xbdcccccd, 0x3e4ccccc]));
    assert(same3(bits3(rgb_to_ycocg_r(vec3::new(0.2, 0.7, 0.4))), [0x3f000000, 0xbe4ccccd, 0x3ecccccc]));
    let back = ycocg_r_to_rgb(rgb_to_ycocg_r(dvec3::new(0.25, 0.5, 0.75)));
    assert_eq(back, dvec3::new(0.25, 0.5, 0.75));
}

@test
fn integer_ycocg() {
    assert_eq(rgb_to_ycocg_r(ivec3::new(13, 200, 77)), ivec3::new(122, -64, 155));
    assert_eq(rgb_to_ycocg(u8vec3::new(13, 200, 77)), u8vec3::new(122, 224, 78));
    assert_eq(rgb_to_ycocg(i8vec3::new(-128, 100, -77)), i8vec3::new(-1, -26, 101));
    assert_eq(rgb_to_ycocg(uvec3::new(13, 200, 77)), uvec3::new(122, 4294967264, 1073741901));
    let colors = [i16vec3::new(-300, 7, 12000), i16vec3::new(0, 0, 0), i16vec3::new(255, 128, 1)];
    for c in colors {
        assert_eq(ycocg_r_to_rgb(rgb_to_ycocg_r(c)), c);
    }
    let bytes = u8vec3::new(250, 3, 129);
    assert_eq(ycocg_r_to_rgb(rgb_to_ycocg_r(bytes)), bytes);
}

@test
fn xyz_bits() {
    let d65 = convert_linear_srgb_to_d65_xyz(vec3::new(0.2, 0.7, 0.4));
    assert(same3(bits3(d65), [0x3fba9ba0, 0x407cfda4, 0x402dae0d]));
    let d50 = convert_linear_srgb_to_d50_xyz(dvec3::new(0.2, 0.7, 0.4));
    assert(same3d(bits3d(d50), [0x3fc8aefb26666667, 0x3fe666665c99999a, 0x3fd51e10ac666666]));
    let linear = convert_d65_xyz_to_linear_srgb(vec3::new(0.2, 0.7, 0.4));
    assert(same3(bits3(linear), [0x3d55973c, 0x3de38743, 0x3d9fee78]));
    assert(same3(bits3(convert_d65_xyz_to_d50_xyz(vec3::new(0.2, 0.7, 0.4))), [0x3e510185, 0x3f33bc04, 0x3e9b24df]));
}

const HSV: vec3 = hsv_color(vec3::new(0.2, 0.7, 0.4));
const YCOCG: i8vec3 = rgb_to_ycocg(i8vec3::new(-128, 100, -77));
const SATURATED: vec3 = saturation_color(0.3f32, vec3::new(0.2, 0.7, 0.4));

@test
fn color_space_constant_initializers() {
    assert(same3(bits3(HSV), [0x43100000, 0x3f36db6e, 0x3f333333]));
    assert_eq(YCOCG, i8vec3::new(-1, -26, 101));
    assert(same3(bits3(SATURATED), [0x3eebbd37, 0x3f1c4502, 0x3f053ac5]));
}
