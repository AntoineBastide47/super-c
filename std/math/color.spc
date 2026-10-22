// Color conversions: the sRGB curves on f32 and f64 vectors of 1 to 4 components, and HSV, saturation,
// luminosity, YCoCg and CIE XYZ on 3-component colors. A 4-component color is RGBA: its alpha (w) passes
// through unchanged.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::common as *;
import std::math::compare as *;
import std::math::geometric as *;

/// Each color component clamped to [0, 1], then `c * 12.92` below 0.0031308, else
/// `pow(c, 0.41666) * 1.055 - 0.055`.
pub fn convert_linear_to_srgb<T: Float, const N: usize>(color_linear: Vec<T, N>) Vec<T, N> {
    return linear_to_srgb(color_linear, T::from_f64(0.41666));
}

/// `convert_linear_to_srgb` with the exponent `1 / gamma`.
pub fn convert_linear_to_srgb_gamma<T: Float, const N: usize>(color_linear: Vec<T, N>, gamma: T) Vec<T, N> {
    return linear_to_srgb(color_linear, T::one() / gamma);
}

/// Each color component `c * (1 / 12.92)` up to 0.04045, else `pow((c + 0.055) * (1 / 1.055), 2.4)`.
/// No clamp.
pub fn convert_srgb_to_linear<T: Float, const N: usize>(color_srgb: Vec<T, N>) Vec<T, N> {
    return srgb_to_linear(color_srgb, T::from_f64(2.4));
}

/// `convert_srgb_to_linear` with the exponent `gamma`.
pub fn convert_srgb_to_linear_gamma<T: Float, const N: usize>(color_srgb: Vec<T, N>, gamma: T) Vec<T, N> {
    return srgb_to_linear(color_srgb, gamma);
}

// The clamp is `min(max(c, 0), 1)`: a NaN component stays NaN.
fn linear_to_srgb<T: Float, const N: usize>(color: Vec<T, N>, g: T) Vec<T, N> {
    let mut r = color;
    for i in 0..N {
        if N != 4 || i != 3 {
            let mut c = unsafe color.e[i];
            if c.less(T::zero()) {
                c = T::zero();
            }
            if T::one().less(c) {
                c = T::one();
            }
            let v = if c.less(T::from_f64(0.0031308)) {
                c * T::from_f64(12.92);
            } else {
                c.pow(g) * T::from_f64(1.055) - T::from_f64(0.055);
            };
            unsafe {
                r.e[i] = v;
            }
        }
    }
    return r;
}

// The two long constants are 1 / 12.92 and 1 / 1.055.
fn srgb_to_linear<T: Float, const N: usize>(color: Vec<T, N>, g: T) Vec<T, N> {
    let mut r = color;
    for i in 0..N {
        if N != 4 || i != 3 {
            let c = unsafe color.e[i];
            let v = if c.less_equal(T::from_f64(0.04045)) {
                c * T::from_decimal(
                    0.07739938080495356037151702786378,
                    "0.077399380804953560371517027863777089783281733746130030959752321981424148606811146",
                );
            } else {
                ((c + T::from_f64(0.055)) * T::from_decimal(
                    0.94786729857819905213270142180095,
                    "0.94786729857819905213270142180094786729857819905213270142180094786729857819905213",
                )).pow(g);
            };
            unsafe {
                r.e[i] = v;
            }
        }
    }
    return r;
}

/// The RGB color of an HSV color (hue in degrees in x, saturation in y, value in z). A saturation within
/// `epsilon` of 0 gives the grey `splat(value)`; a hue outside [0, 360) takes the red sector.
pub fn rgb_color<T: Float>(hsv_color: Vec<T, 3>) Vec<T, 3> {
    let h = hsv_color.e[0];
    let s = hsv_color.e[1];
    let v = hsv_color.e[2];
    if equal_eps(s, T::zero(), T::epsilon()) {
        return Vec::<T, 3>::splat(v);
    }
    let sector = (h * (T::one() / T::from_i64(60))).floor();
    let frac = h * (T::one() / T::from_i64(60)) - sector;
    let o = v * (T::one() - s);
    let p = v * (T::one() - s * frac);
    let q = v * (T::one() - s * (T::one() - frac));
    // The sector is compared as a float, which needs no conversion to an integer: a NaN or any sector
    // outside 1..5, also one too large for an integer, takes the red sector.
    if sector.equal(T::one()) {
        return Vec::<T, 3>::new(p, v, o);
    }
    if sector.equal(T::from_i64(2)) {
        return Vec::<T, 3>::new(o, v, q);
    }
    if sector.equal(T::from_i64(3)) {
        return Vec::<T, 3>::new(o, p, v);
    }
    if sector.equal(T::from_i64(4)) {
        return Vec::<T, 3>::new(q, o, v);
    }
    if sector.equal(T::from_i64(5)) {
        return Vec::<T, 3>::new(v, o, p);
    }
    return Vec::<T, 3>::new(v, q, o);
}

/// The HSV color (hue in degrees in [0, 360) in x, saturation in y, value in z) of an
/// RGB color. A value within `epsilon` of 0 gives hue and saturation 0.
pub fn hsv_color<T: Float>(rgb_color: Vec<T, 3>) Vec<T, 3> {
    let r = rgb_color.e[0];
    let g = rgb_color.e[1];
    let b = rgb_color.e[2];
    let lo = min(min(r, g), b);
    let hi = max(max(r, g), b);
    let delta = hi - lo;
    if within_epsilon(hi, T::zero()) {
        return Vec::<T, 3>::new(T::zero(), T::zero(), hi);
    }
    let saturation = delta / hi;
    // Each branch gives the hue `offset + 60 * difference / delta`; the branches only choose the operands.
    let (offset, difference) = if within_epsilon(r, hi) {
        (T::zero(), g - b);
    } else if within_epsilon(g, hi) {
        (T::from_i64(120), b - r);
    } else {
        (T::from_i64(240), r - g);
    };
    let h = offset + T::from_i64(60) * difference / delta;
    let hue = if h.less(T::zero()) {
        h + T::from_i64(360);
    } else {
        h;
    };
    return Vec::<T, 3>::new(hue, saturation, hi);
}

// `abs(x - y) <= epsilon`, false for a NaN. `Float::abs` lets the C compiler use its `fabs`.
fn within_epsilon<T: Float>(x: T, y: T) bool {
    return (x - y).abs().less_equal(T::epsilon());
}

/// The 4x4 matrix that sets the saturation of an RGBA color to `s`
/// (1 keeps it, 0 gives the grey of luma weights 0.2126, 0.7152, 0.0722); w passes through.
pub fn saturation<T: Scalar>(s: T) Mat<T, 4, 4> {
    let rgbw = Vec::<T, 3>::new(T::from_f64(0.2126), T::from_f64(0.7152), T::from_f64(0.0722));
    let col = rgbw * (T::one() - s);
    let mut m = Mat::<T, 4, 4>::identity();
    m.c[0].e[0] = col.e[0] + s;
    m.c[0].e[1] = col.e[0];
    m.c[0].e[2] = col.e[0];
    m.c[1].e[0] = col.e[1];
    m.c[1].e[1] = col.e[1] + s;
    m.c[1].e[2] = col.e[1];
    m.c[2].e[0] = col.e[2];
    m.c[2].e[1] = col.e[2];
    m.c[2].e[2] = col.e[2] + s;
    return m;
}

/// `saturation(s) * color` for an RGBA color, and for an RGB color the
/// first three components of `saturation(s) * (color, 0)`. A size other than 3 or 4 is a compile error.
pub fn saturation_color<T: Scalar, const N: usize>(s: T, color: Vec<T, N>) Vec<T, N> {
    static_assert(N == 3 || N == 4, "'saturation_color' takes an RGB or an RGBA color");
    let mut rgba = Vec::<T, 4>::zero();
    for i in 0..N {
        unsafe {
            rgba.e[i] = color.e[i];
        }
    }
    let saturated = saturation(s) * rgba;
    let mut r = color;
    for i in 0..N {
        unsafe {
            r.e[i] = saturated.e[i];
        }
    }
    return r;
}

/// `dot(color, (0.33, 0.59, 0.11))`.
pub fn luminosity<T: Float>(color: Vec<T, 3>) T {
    return dot(color, Vec::<T, 3>::new(T::from_f64(0.33), T::from_f64(0.59), T::from_f64(0.11)));
}

/// (Y, Co, Cg) = (r / 4 + g / 2 + b / 4, r / 2 - b / 2, -r / 4 + g / 2 - b / 4) in `T`'s arithmetic
/// (an integer `T` divides truncating toward zero).
pub fn rgb_to_ycocg<T: Scalar>(rgb_color: Vec<T, 3>) Vec<T, 3> {
    let r = rgb_color.e[0];
    let g = rgb_color.e[1];
    let b = rgb_color.e[2];
    let two = T::from_i64(2);
    let four = T::from_i64(4);
    // For a float and an 8- or 16-bit integer, `-r / 4 + g / 2` is `g / 2 - r / 4`: the result of a
    // negation of `r` in 32 bits, where it cannot wrap. A 32- or 64-bit integer negates `r` in `T`, so an
    // unsigned `r` wraps before the division.
    let cg_head = if T::is_float() || sizeof(T) < 4 {
        g / two - r / four;
    } else {
        -r / four + g / two;
    };
    let y = r / four + g / two + b / four;
    let co = r / two + g * T::zero() - b / two;
    return Vec::<T, 3>::new(y, co, cg_head - b / four);
}

/// The RGB color of a YCoCg color: (r, g, b) = (Y + Co - Cg, Y + Cg, Y - Co - Cg).
pub const fn ycocg_to_rgb<T: Scalar>(ycocg_color: Vec<T, 3>) Vec<T, 3> {
    let y = ycocg_color.e[0];
    let co = ycocg_color.e[1];
    let cg = ycocg_color.e[2];
    return Vec::<T, 3>::new(y + co - cg, y + cg, y - co - cg);
}

// The YCoCg-R lifting steps with shifts for an integer `T`, with halves and quarters for a float one.
interface YCoCgR: Scalar {
    fn rgb_to_ycocg_r(rgb: Vec<Self, 3>) Vec<Self, 3>;
    fn ycocg_r_to_rgb(ycocg: Vec<Self, 3>) Vec<Self, 3>;
}

/// The reversible YCoCg-R transform. An integer `T` uses the lifting steps (Co = r - b,
/// t = b + (Co >> 1), Cg = g - t, Y = t + (Cg >> 1)), which `ycocg_r_to_rgb` inverts exactly; a float `T`
/// computes (g / 2 + (r + b) / 4, r - b, g - (r + b) / 2).
pub fn rgb_to_ycocg_r<T: YCoCgR>(rgb_color: Vec<T, 3>) Vec<T, 3> {
    return T::rgb_to_ycocg_r(rgb_color);
}

/// The inverse of `rgb_to_ycocg_r` (t = Y - (Cg >> 1), g = Cg + t, b = t - (Co >> 1),
/// r = b + Co, with `* 0.5` for `>> 1` on a float `T`).
pub fn ycocg_r_to_rgb<T: YCoCgR>(ycocg_color: Vec<T, 3>) Vec<T, 3> {
    return T::ycocg_r_to_rgb(ycocg_color);
}

extend<T: Int> T as YCoCgR {
    pub fn rgb_to_ycocg_r(rgb: Vec<T, 3>) Vec<T, 3> {
        let co = rgb.e[0] - rgb.e[2];
        let t = rgb.e[2] + (co >> T::one());
        let cg = rgb.e[1] - t;
        return Vec::<T, 3>::new(t + (cg >> T::one()), co, cg);
    }
    pub fn ycocg_r_to_rgb(ycocg: Vec<T, 3>) Vec<T, 3> {
        let t = ycocg.e[0] - (ycocg.e[2] >> T::one());
        let g = ycocg.e[2] + t;
        let b = t - (ycocg.e[1] >> T::one());
        return Vec::<T, 3>::new(b + ycocg.e[1], g, b);
    }
}

extend f32 as YCoCgR {
    pub fn rgb_to_ycocg_r(rgb: Vec<f32, 3>) Vec<f32, 3> {
        return float_rgb_to_ycocg_r(rgb);
    }
    pub fn ycocg_r_to_rgb(ycocg: Vec<f32, 3>) Vec<f32, 3> {
        return float_ycocg_r_to_rgb(ycocg);
    }
}

extend f64 as YCoCgR {
    pub fn rgb_to_ycocg_r(rgb: Vec<f64, 3>) Vec<f64, 3> {
        return float_rgb_to_ycocg_r(rgb);
    }
    pub fn ycocg_r_to_rgb(ycocg: Vec<f64, 3>) Vec<f64, 3> {
        return float_ycocg_r_to_rgb(ycocg);
    }
}

fn float_rgb_to_ycocg_r<T: Float>(rgb: Vec<T, 3>) Vec<T, 3> {
    let r = rgb.e[0];
    let g = rgb.e[1];
    let b = rgb.e[2];
    let y = g * T::from_f64(0.5) + (r + b) * T::from_f64(0.25);
    let cg = g - (r + b) * T::from_f64(0.5);
    return Vec::<T, 3>::new(y, r - b, cg);
}

fn float_ycocg_r_to_rgb<T: Float>(ycocg: Vec<T, 3>) Vec<T, 3> {
    let t = ycocg.e[0] - ycocg.e[2] * T::from_f64(0.5);
    let g = ycocg.e[2] + t;
    let b = t - ycocg.e[1] * T::from_f64(0.5);
    return Vec::<T, 3>::new(b + ycocg.e[1], g, b);
}

/// `(M * c + N * c + O * c) * 5.650675255693055` with `*` per component and M, N, O f32 coefficient
/// vectors: not a matrix product, so each output component depends only on the same input component.
pub fn convert_linear_srgb_to_d65_xyz<T: Scalar>(color_linear_srgb: Vec<T, 3>) Vec<T, 3> {
    let m = vec3_from_f32::<T>(0.490, 0.17697, 0.2);
    let n = vec3_from_f32::<T>(0.31, 0.8124, 0.01063);
    let o = vec3_from_f32::<T>(0.490, 0.01, 0.99);
    let c = color_linear_srgb;
    return (m * c + n * c + o * c) * T::from_f32(5.650675255693055);
}

/// `M * c + N * c + O * c` with `*` per component and M, N, O f32 coefficient vectors.
pub fn convert_linear_srgb_to_d50_xyz<T: Scalar>(color_linear_srgb: Vec<T, 3>) Vec<T, 3> {
    let m = vec3_from_f32::<T>(0.436030342570117, 0.222438466210245, 0.013897440074263);
    let n = vec3_from_f32::<T>(0.385101860087134, 0.716942745571917, 0.097076381494207);
    let o = vec3_from_f32::<T>(0.143067806654203, 0.060618777416563, 0.713926257896652);
    let c = color_linear_srgb;
    return m * c + n * c + o * c;
}

/// `M * c + N * c + O * c` with `*` per component and M, N, O f32 coefficient vectors.
pub fn convert_d65_xyz_to_linear_srgb<T: Scalar>(color_d65_xyz: Vec<T, 3>) Vec<T, 3> {
    let m = vec3_from_f32::<T>(0.41847, -0.091169, 0.0009209);
    let n = vec3_from_f32::<T>(-0.15866, 0.25243, 0.015708);
    let o = vec3_from_f32::<T>(0.0009209, -0.0025498, 0.1786);
    let c = color_d65_xyz;
    return m * c + n * c + o * c;
}

/// `M * c + N * c + O * c` with `*` per component and M, N, O f32 coefficient vectors.
pub fn convert_d65_xyz_to_d50_xyz<T: Scalar>(color_d65_xyz: Vec<T, 3>) Vec<T, 3> {
    let m = vec3_from_f32::<T>(1.047844353856414, 0.029549007606644, -0.009250984365223);
    let n = vec3_from_f32::<T>(0.022898981050086, 0.990508028941971, 0.015072338237051);
    let o = vec3_from_f32::<T>(-0.050206647741605, -0.017074711360960, 0.751717835079977);
    let c = color_d65_xyz;
    return m * c + n * c + o * c;
}

// Each literal is rounded to f32, then converted to `T` with `from_f32`.
fn vec3_from_f32<T: Scalar>(x: f32, y: f32, z: f32) Vec<T, 3> {
    return Vec::<T, 3>::new(T::from_f32(x), T::from_f32(y), T::from_f32(z));
}
