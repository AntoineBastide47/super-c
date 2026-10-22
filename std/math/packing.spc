// Packing of floats and integers into bit fields, and float16 conversions. Fields are laid out from the
// lowest bit on every target. Keep the operations and constants: the tests check exact packed bits and
// unpacked floats. A NaN given to a function that converts to an integer packs 0.
import std::math::scalar as *;
import std::math::vec as *;

/// Each component clamped to [0, 1], times 65535, rounded; x in the low 16 bits.
pub const fn pack_unorm2x16(v: Vec<f32, 2>) u32 {
    let x = unorm(v.e[0], 65535.0) as u16;
    let y = unorm(v.e[1], 65535.0) as u16;
    return x as u32 | y as u32 << 16;
}

/// Each 16-bit field times 1 / 65535.
pub const fn unpack_unorm2x16(p: u32) Vec<f32, 2> {
    let s: f32 = 1.5259021896696421759365224689097e-5;
    return Vec::<f32, 2> { e: [(p & 0xFFFF) as f32 * s, (p >> 16) as f32 * s] };
}

/// Each component clamped to [-1, 1], times 32767, rounded; x in the low 16 bits.
pub const fn pack_snorm2x16(v: Vec<f32, 2>) u32 {
    let x = (snorm(v.e[0], 32767.0) as i16) as u16;
    let y = (snorm(v.e[1], 32767.0) as i16) as u16;
    return x as u32 | y as u32 << 16;
}

/// Each signed 16-bit field times 1 / 32767, clamped to [-1, 1].
pub fn unpack_snorm2x16(p: u32) Vec<f32, 2> {
    let s: f32 = 3.0518509475997192297128208258309e-5;
    let x = (p as u16) as i16;
    let y = ((p >> 16) as u16) as i16;
    return Vec::<f32, 2> { e: [clamp_f(x as f32 * s, -1.0, 1.0), clamp_f(y as f32 * s, -1.0, 1.0)] };
}

/// Each component clamped to [0, 1], times 255, rounded; x in the low byte.
pub const fn pack_unorm4x8(v: Vec<f32, 4>) u32 {
    let x = unorm(v.e[0], 255.0);
    let y = unorm(v.e[1], 255.0);
    let z = unorm(v.e[2], 255.0);
    let w = unorm(v.e[3], 255.0);
    return x | y << 8 | z << 16 | w << 24;
}

/// Each byte times 1 / 255.
pub fn unpack_unorm4x8(p: u32) Vec<f32, 4> {
    let s: f32 = 0.0039215686274509803921568627451;
    let mut r = Vec::<f32, 4>::zero();
    for i in 0..4 {
        unsafe {
            r.e[i] = (p >> (i * 8) as u32 & 0xFF) as f32 * s;
        }
    }
    return r;
}

/// Each component clamped to [-1, 1], times 127, rounded; x in the low byte.
pub const fn pack_snorm4x8(v: Vec<f32, 4>) u32 {
    let mut r: u32 = 0;
    for i in 0..4 {
        r = r | ((snorm(unsafe v.e[i], 127.0) as i8) as u8) as u32 << (i * 8) as u32;
    }
    return r;
}

/// Each signed byte times 0.0078740157480315 (about 1 / 127), clamped to [-1, 1].
pub fn unpack_snorm4x8(p: u32) Vec<f32, 4> {
    let s: f32 = 0.0078740157480315;
    let mut r = Vec::<f32, 4>::zero();
    for i in 0..4 {
        unsafe {
            r.e[i] = clamp_f((((p >> (i * 8) as u32) as u8) as i8) as f32 * s, -1.0, 1.0);
        }
    }
    return r;
}

/// The double whose low 32 bits are x and high 32 bits y.
pub const fn pack_double2x32(v: Vec<u32, 2>) f64 {
    return f64_from_bits(v.e[0] as u64 | v.e[1] as u64 << 32);
}

/// The low and high 32 bits of `v`.
pub const fn unpack_double2x32(v: f64) Vec<u32, 2> {
    let b = f64_bits(v);
    return Vec::<u32, 2> { e: [b as u32, (b >> 32) as u32] };
}

/// The x and y components as float16 (round to nearest, halves up), x in the low 16 bits.
pub const fn pack_half2x16(v: Vec<f32, 2>) u32 {
    return (to_float16(v.e[0]) as u16) as u32 | (to_float16(v.e[1]) as u16) as u32 << 16;
}

/// The two float16 fields of `v` as floats.
pub const fn unpack_half2x16(v: u32) Vec<f32, 2> {
    return Vec::<f32, 2> { e: [to_float32((v as u16) as i16), to_float32(((v >> 16) as u16) as i16)] };
}

/// `v` clamped to [0, 1], times 255, rounded.
pub const fn pack_unorm1x8(v: f32) u8 {
    return unorm(v, 255.0) as u8;
}

/// `p` times 1 / 255 (an f64 constant rounded to f32).
pub const fn unpack_unorm1x8(p: u8) f32 {
    return p as f32 * UNORM8_SCALE as f32;
}

/// The x and y components as `pack_unorm1x8`, x in the low byte.
pub const fn pack_unorm2x8(v: Vec<f32, 2>) u16 {
    return (unorm(v.e[0], 255.0) as u8) as u16 | (unorm(v.e[1], 255.0) as u8) as u16 << 8;
}

/// Each byte of `p` as `unpack_unorm1x8`.
pub const fn unpack_unorm2x8(p: u16) Vec<f32, 2> {
    let s = UNORM8_SCALE as f32;
    return Vec::<f32, 2> { e: [(p & 0xFF) as f32 * s, (p >> 8) as f32 * s] };
}

/// `v` clamped to [-1, 1], times 127, rounded, as the bits of an `i8`.
pub const fn pack_snorm1x8(v: f32) u8 {
    return (snorm(v, 127.0) as i8) as u8;
}

/// `p` as an `i8` times 1 / 127, clamped to [-1, 1].
pub fn unpack_snorm1x8(p: u8) f32 {
    return clamp_f((p as i8) as f32 * SNORM8_SCALE, -1.0, 1.0);
}

/// The x and y components as `pack_snorm1x8`, x in the low byte.
pub const fn pack_snorm2x8(v: Vec<f32, 2>) u16 {
    return ((snorm(v.e[0], 127.0) as i8) as u8) as u16 | ((snorm(v.e[1], 127.0) as i8) as u8) as u16 << 8;
}

/// Each byte of `p` as `unpack_snorm1x8`.
pub fn unpack_snorm2x8(p: u16) Vec<f32, 2> {
    return Vec::<f32, 2> { e: [unpack_snorm1x8(p as u8), unpack_snorm1x8((p >> 8) as u8)] };
}

/// `v` clamped to [0, 1], times 65535, rounded.
pub const fn pack_unorm1x16(v: f32) u16 {
    return unorm(v, 65535.0) as u16;
}

/// `p` times 1 / 65535.
pub const fn unpack_unorm1x16(p: u16) f32 {
    return p as f32 * UNORM16_SCALE;
}

/// Each component as `pack_unorm1x16`, x in the low 16 bits.
pub const fn pack_unorm4x16(v: Vec<f32, 4>) u64 {
    let mut r: u64 = 0;
    for i in 0..4 {
        r = r | (unorm(unsafe v.e[i], 65535.0) as u16) as u64 << (i * 16) as u64;
    }
    return r;
}

/// Each 16-bit field of `p` as `unpack_unorm1x16`.
pub fn unpack_unorm4x16(p: u64) Vec<f32, 4> {
    let mut r = Vec::<f32, 4>::zero();
    for i in 0..4 {
        unsafe {
            r.e[i] = ((p >> (i * 16) as u64) as u16) as f32 * UNORM16_SCALE;
        }
    }
    return r;
}

/// `v` clamped to [-1, 1], times 32767, rounded, as the bits of an `i16`.
pub const fn pack_snorm1x16(v: f32) u16 {
    return (snorm(v, 32767.0) as i16) as u16;
}

/// `p` as an `i16` times 1 / 32767, clamped to [-1, 1].
pub fn unpack_snorm1x16(p: u16) f32 {
    return clamp_f((p as i16) as f32 * SNORM16_SCALE, -1.0, 1.0);
}

/// Each component as `pack_snorm1x16`, x in the low 16 bits.
pub const fn pack_snorm4x16(v: Vec<f32, 4>) u64 {
    let mut r: u64 = 0;
    for i in 0..4 {
        r = r | ((snorm(unsafe v.e[i], 32767.0) as i16) as u16) as u64 << (i * 16) as u64;
    }
    return r;
}

/// Each 16-bit field of `p` as `unpack_snorm1x16`.
pub fn unpack_snorm4x16(p: u64) Vec<f32, 4> {
    let mut r = Vec::<f32, 4>::zero();
    for i in 0..4 {
        unsafe {
            r.e[i] = unpack_snorm1x16((p >> (i * 16) as u64) as u16);
        }
    }
    return r;
}

/// `v` as float16 bits (round to nearest, halves up).
pub const fn pack_half1x16(v: f32) u16 {
    return to_float16(v) as u16;
}

/// The float16 `v` as a float.
pub const fn unpack_half1x16(v: u16) f32 {
    return to_float32(v as i16);
}

/// Each component as `pack_half1x16`, x in the low 16 bits.
pub const fn pack_half4x16(v: Vec<f32, 4>) u64 {
    let mut r: u64 = 0;
    for i in 0..4 {
        r = r | (to_float16(unsafe v.e[i]) as u16) as u64 << (i * 16) as u64;
    }
    return r;
}

/// Each 16-bit field of `p` as `unpack_half1x16`.
pub fn unpack_half4x16(p: u64) Vec<f32, 4> {
    let mut r = Vec::<f32, 4>::zero();
    for i in 0..4 {
        unsafe {
            r.e[i] = to_float32(((p >> (i * 16) as u64) as u16) as i16);
        }
    }
    return r;
}

/// The low 10 bits of x, y, z and the low 2 bits of w, x lowest.
pub const fn pack_i3x10_1x2(v: Vec<i32, 4>) u32 {
    return fields_3x10_1x2(v.e[0] as u32, v.e[1] as u32, v.e[2] as u32, v.e[3] as u32);
}

/// The three 10-bit fields and the 2-bit field of `p`, sign-extended.
pub const fn unpack_i3x10_1x2(p: u32) Vec<i32, 4> {
    return Vec::<i32, 4> { e: [(p << 22) as i32 >> 22, (p << 12) as i32 >> 22, (p << 2) as i32 >> 22, p as i32 >> 30] };
}

/// The low 10 bits of x, y, z and the low 2 bits of w, x lowest.
pub const fn pack_u3x10_1x2(v: Vec<u32, 4>) u32 {
    return fields_3x10_1x2(v.e[0], v.e[1], v.e[2], v.e[3]);
}

/// The three 10-bit fields and the 2-bit field of `p`.
pub const fn unpack_u3x10_1x2(p: u32) Vec<u32, 4> {
    return Vec::<u32, 4> { e: [p & 0x3FF, p >> 10 & 0x3FF, p >> 20 & 0x3FF, p >> 30] };
}

/// The x, y, z components clamped to [-1, 1] times 511 and w clamped times 1, rounded, in the fields of
/// `pack_i3x10_1x2`.
pub const fn pack_snorm3x10_1x2(v: Vec<f32, 4>) u32 {
    let x = snorm(v.e[0], 511.0) as u32;
    let y = snorm(v.e[1], 511.0) as u32;
    let z = snorm(v.e[2], 511.0) as u32;
    let w = snorm(v.e[3], 1.0) as u32;
    return fields_3x10_1x2(x, y, z, w);
}

/// The fields of `unpack_i3x10_1x2` times 1 / 511 (w times 1), clamped to [-1, 1].
pub fn unpack_snorm3x10_1x2(p: u32) Vec<f32, 4> {
    let i = unpack_i3x10_1x2(p);
    let s: f32 = 1.0 / 511.0;
    return Vec::<f32, 4> {
        e: [
            clamp_f(i.e[0] as f32 * s, -1.0, 1.0),
            clamp_f(i.e[1] as f32 * s, -1.0, 1.0),
            clamp_f(i.e[2] as f32 * s, -1.0, 1.0),
            clamp_f(i.e[3] as f32 * 1.0, -1.0, 1.0),
        ],
    };
}

/// The x, y, z components clamped to [0, 1] times 1023 and w times 3, rounded, in the fields of
/// `pack_u3x10_1x2`.
pub const fn pack_unorm3x10_1x2(v: Vec<f32, 4>) u32 {
    let x = unorm(v.e[0], 1023.0);
    let y = unorm(v.e[1], 1023.0);
    let z = unorm(v.e[2], 1023.0);
    let w = unorm(v.e[3], 3.0);
    return fields_3x10_1x2(x, y, z, w);
}

/// The fields of `unpack_u3x10_1x2` times 1 / 1023 (w times 1 / 3).
pub const fn unpack_unorm3x10_1x2(p: u32) Vec<f32, 4> {
    let u = unpack_u3x10_1x2(p);
    let s: f32 = 1.0 / 1023.0;
    let sw: f32 = 1.0 / 3.0;
    return Vec::<f32, 4> { e: [u.e[0] as f32 * s, u.e[1] as f32 * s, u.e[2] as f32 * s, u.e[3] as f32 * sw] };
}

/// The x and y components as unsigned 11-bit floats (6-bit mantissa), z as an unsigned 10-bit float
/// (5-bit mantissa), x lowest. The sign is dropped, zero packs 0, NaN all ones and an infinity the
/// maximum exponent, and a value below the smallest exponent packs garbage bits.
pub const fn pack_f2x11_1x10(v: Vec<f32, 3>) u32 {
    return float_to_11bit(v.e[0]) & 0x7FF | (float_to_11bit(v.e[1]) & 0x7FF) << 11 | (float_to_10bit(v.e[2]) & 0x3FF) << 22;
}

/// The inverse of `pack_f2x11_1x10`. A NaN or infinity field unpacks to -1, and x reads the whole word,
/// so it is 0 only when `p` is 0.
pub const fn unpack_f2x11_1x10(p: u32) Vec<f32, 3> {
    return Vec::<f32, 3> { e: [packed11_to_float(p), packed11_to_float(p >> 11), packed10_to_float(p >> 22)] };
}

/// The x, y, z components as 9-bit mantissas with a shared 5-bit exponent (bias 15) in the top bits;
/// each component is clamped to [0, 32768] first.
pub fn pack_f3x9_e1x5(v: Vec<f32, 3>) u32 {
    let shared_exp_max = 2.0f32.powf(9.0 - 1.0) / 2.0f32.powf(9.0) * 2.0f32.powf(31.0 - 15.0);
    let x = clamp_f(v.e[0], 0.0, shared_exp_max);
    let y = clamp_f(v.e[1], 0.0, shared_exp_max);
    let z = clamp_f(v.e[2], 0.0, shared_exp_max);
    let max_color = max_f(x, max_f(y, z));
    let exp_shared_p = max_f(-15.0 - 1.0, max_color.log2().floor()) + 1.0 + 15.0;
    let max_shared = (max_color / 2.0f32.powf(exp_shared_p - 15.0 - 9.0) + 0.5).floor();
    let d = max_shared - 2.0f32.powf(9.0);
    let near = if d >= 0.0 {
        d;
    } else {
        -d;
    };
    let exp_shared = if near <= f32::epsilon() {
        exp_shared_p + 1.0;
    } else {
        exp_shared_p;
    };
    let scale = 2.0f32.powf(exp_shared - 15.0 - 9.0);
    let cx = (x / scale + 0.5).floor() as u32;
    let cy = (y / scale + 0.5).floor() as u32;
    let cz = (z / scale + 0.5).floor() as u32;
    return cx & 0x1FF | (cy & 0x1FF) << 9 | (cz & 0x1FF) << 18 | (exp_shared as u32 & 0x1F) << 27;
}

/// The three 9-bit mantissas of `p` times 2^(exponent - 24).
pub const fn unpack_f3x9_e1x5(p: u32) Vec<f32, 3> {
    let scale = 2.0f32.powf((p >> 27) as f32 - 15.0 - 9.0);
    return Vec::<f32, 3> {
        e: [(p & 0x1FF) as f32 * scale, (p >> 9 & 0x1FF) as f32 * scale, (p >> 18 & 0x1FF) as f32 * scale],
    };
}

/// `rgb / 6` divided by alpha, and alpha: the largest of those components and 1e-6, clamped to [0, 1],
/// rounded up to a multiple of 1 / 255.
pub fn pack_rgbm<T: Float>(rgb: Vec<T, 3>) Vec<T, 4> {
    let color = rgb * T::from_decimal(
        1.0 / 6.0,
        "0.16666666666666666666666666666666666666666666666666666666666666666666666666666667",
    );
    let mut alpha = clamp_f(
        max_f(max_f(color.e[0], color.e[1]), max_f(color.e[2], T::from_f64(1e-6))),
        T::zero(),
        T::one(),
    );
    alpha = (alpha * T::from_f64(255.0)).ceil() / T::from_f64(255.0);
    return (color / alpha).append(alpha);
}

/// The x, y, z components of `rgbm` times `rgbm.w * 6`.
pub fn unpack_rgbm<T: Float>(rgbm: Vec<T, 4>) Vec<T, 3> {
    return Vec::<T, 3> { e: [rgbm.e[0], rgbm.e[1], rgbm.e[2]] } * rgbm.e[3] * T::from_i64(6);
}

/// Each component as float16 bits (round to nearest, halves up).
pub fn pack_half<const N: usize>(v: Vec<f32, N>) Vec<u16, N> {
    let mut r = Vec::<u16, N>::zero();
    for i in 0..N {
        unsafe {
            r.e[i] = to_float16(v.e[i]) as u16;
        }
    }
    return r;
}

/// Each float16 component as a float.
pub fn unpack_half<const N: usize>(v: Vec<u16, N>) Vec<f32, N> {
    let mut r = Vec::<f32, N>::zero();
    for i in 0..N {
        unsafe {
            r.e[i] = to_float32(v.e[i] as i16);
        }
    }
    return r;
}

/// Each component clamped to [0, 1], times `U`'s maximum (as `F`), rounded, converted to `U`.
/// For a 32- or 64-bit `U` the maximum rounds up in `F`, so 1 saturates to the maximum.
pub fn pack_unorm<U: Int, F: Float, const N: usize>(v: Vec<F, N>) Vec<U, N> {
    let m = U::max_value().cast::<F>();
    let mut r = Vec::<U, N>::zero();
    for i in 0..N {
        unsafe {
            r.e[i] = (clamp_f(v.e[i], F::zero(), F::one()) * m).round().cast::<U>();
        }
    }
    return r;
}

/// Each component as `F` times `1 / max` of `U`.
pub fn unpack_unorm<F: Float, U: Int, const N: usize>(v: Vec<U, N>) Vec<F, N> {
    let s = F::one() / U::max_value().cast::<F>();
    let mut r = Vec::<F, N>::zero();
    for i in 0..N {
        unsafe {
            r.e[i] = v.e[i].cast::<F>() * s;
        }
    }
    return r;
}

/// Each component clamped to [-1, 1], times `I`'s maximum (as `F`), rounded, converted to `I`.
pub fn pack_snorm<I: Int, F: Float, const N: usize>(v: Vec<F, N>) Vec<I, N> {
    let m = I::max_value().cast::<F>();
    let mut r = Vec::<I, N>::zero();
    for i in 0..N {
        unsafe {
            r.e[i] = (clamp_f(v.e[i], -F::one(), F::one()) * m).round().cast::<I>();
        }
    }
    return r;
}

/// Each component as `F` times `1 / max` of `I`, clamped to [-1, 1].
pub fn unpack_snorm<F: Float, I: Int, const N: usize>(v: Vec<I, N>) Vec<F, N> {
    let s = F::one() / I::max_value().cast::<F>();
    let mut r = Vec::<F, N>::zero();
    for i in 0..N {
        unsafe {
            r.e[i] = clamp_f(v.e[i].cast::<F>() * s, -F::one(), F::one());
        }
    }
    return r;
}

/// The x and y components clamped to [0, 1], times 15, rounded, in 4 bits each, x lowest.
pub const fn pack_unorm2x4(v: Vec<f32, 2>) u8 {
    let x = unorm(v.e[0], 15.0);
    let y = unorm(v.e[1], 15.0);
    return (x & 0xF | (y & 0xF) << 4) as u8;
}

/// Each 4-bit field times 1 / 15.
pub const fn unpack_unorm2x4(p: u8) Vec<f32, 2> {
    let s: f32 = 1.0 / 15.0;
    return Vec::<f32, 2> { e: [(p & 0xF) as f32 * s, (p >> 4) as f32 * s] };
}

/// Each component clamped to [0, 1], times 15, rounded, in 4 bits, x lowest.
pub const fn pack_unorm4x4(v: Vec<f32, 4>) u16 {
    let mut r: u32 = 0;
    for i in 0..4 {
        r = r | (unorm(unsafe v.e[i], 15.0) & 0xF) << (i * 4) as u32;
    }
    return r as u16;
}

/// Each 4-bit field times 1 / 15.
pub fn unpack_unorm4x4(p: u16) Vec<f32, 4> {
    let s: f32 = 1.0 / 15.0;
    let mut r = Vec::<f32, 4>::zero();
    for i in 0..4 {
        unsafe {
            r.e[i] = (p >> (i * 4) as u16 & 0xF) as f32 * s;
        }
    }
    return r;
}

/// The x, y, z components clamped to [0, 1] times 31, 63, 31, rounded, in 5, 6 and 5 bits, x lowest.
pub const fn pack_unorm1x5_1x6_1x5(v: Vec<f32, 3>) u16 {
    let x = unorm(v.e[0], 31.0);
    let y = unorm(v.e[1], 63.0);
    let z = unorm(v.e[2], 31.0);
    return (x & 0x1F | (y & 0x3F) << 5 | (z & 0x1F) << 11) as u16;
}

/// The fields times 1 / 31, 1 / 63, 1 / 31.
pub const fn unpack_unorm1x5_1x6_1x5(p: u16) Vec<f32, 3> {
    let s5: f32 = 1.0 / 31.0;
    let s6: f32 = 1.0 / 63.0;
    return Vec::<f32, 3> { e: [(p & 0x1F) as f32 * s5, (p >> 5 & 0x3F) as f32 * s6, (p >> 11) as f32 * s5] };
}

/// The x, y, z components clamped to [0, 1] times 31 and w times 1, rounded, in 5, 5, 5 and 1 bits,
/// x lowest.
pub const fn pack_unorm3x5_1x1(v: Vec<f32, 4>) u16 {
    let x = unorm(v.e[0], 31.0);
    let y = unorm(v.e[1], 31.0);
    let z = unorm(v.e[2], 31.0);
    let w = unorm(v.e[3], 1.0);
    return (x & 0x1F | (y & 0x1F) << 5 | (z & 0x1F) << 10 | (w & 1) << 15) as u16;
}

/// The fields times 1 / 31 (w times 1).
pub const fn unpack_unorm3x5_1x1(p: u16) Vec<f32, 4> {
    let s: f32 = 1.0 / 31.0;
    return Vec::<f32, 4> {
        e: [(p & 0x1F) as f32 * s, (p >> 5 & 0x1F) as f32 * s, (p >> 10 & 0x1F) as f32 * s, (p >> 15) as f32 * 1.0],
    };
}

/// The x, y, z components clamped to [0, 1] times 7, 7, 3, rounded, in 3, 3 and 2 bits, x lowest.
pub const fn pack_unorm2x3_1x2(v: Vec<f32, 3>) u8 {
    let x = unorm(v.e[0], 7.0);
    let y = unorm(v.e[1], 7.0);
    let z = unorm(v.e[2], 3.0);
    return (x & 7 | (y & 7) << 3 | (z & 3) << 6) as u8;
}

/// The fields times 1 / 7, 1 / 7, 1 / 3.
pub const fn unpack_unorm2x3_1x2(p: u8) Vec<f32, 3> {
    let s7: f32 = 1.0 / 7.0;
    let s3: f32 = 1.0 / 3.0;
    return Vec::<f32, 3> { e: [(p & 7) as f32 * s7, (p >> 3 & 7) as f32 * s7, (p >> 6) as f32 * s3] };
}

/// The bytes of x and y, x low.
pub const fn pack_int2x8(v: Vec<i8, 2>) i16 {
    return ((v.e[0] as u8) as u16 | (v.e[1] as u8) as u16 << 8) as i16;
}

/// The low and high bytes of `p`.
pub const fn unpack_int2x8(p: i16) Vec<i8, 2> {
    return Vec::<i8, 2> { e: [p as i8, (p as u16 >> 8) as i8] };
}

/// The bytes of x and y, x low.
pub const fn pack_uint2x8(v: Vec<u8, 2>) u16 {
    return v.e[0] as u16 | v.e[1] as u16 << 8;
}

/// The low and high bytes of `p`.
pub const fn unpack_uint2x8(p: u16) Vec<u8, 2> {
    return Vec::<u8, 2> { e: [p as u8, (p >> 8) as u8] };
}

/// The bytes of x, y, z, w, x lowest.
pub const fn pack_int4x8(v: Vec<i8, 4>) i32 {
    return pack_uint4x8(Vec::<u8, 4> { e: [v.e[0] as u8, v.e[1] as u8, v.e[2] as u8, v.e[3] as u8] }) as i32;
}

/// The bytes of `p`, lowest first.
pub const fn unpack_int4x8(p: i32) Vec<i8, 4> {
    let u = unpack_uint4x8(p as u32);
    return Vec::<i8, 4> { e: [u.e[0] as i8, u.e[1] as i8, u.e[2] as i8, u.e[3] as i8] };
}

/// The bytes of x, y, z, w, x lowest.
pub const fn pack_uint4x8(v: Vec<u8, 4>) u32 {
    return v.e[0] as u32 | v.e[1] as u32 << 8 | v.e[2] as u32 << 16 | v.e[3] as u32 << 24;
}

/// The bytes of `p`, lowest first.
pub const fn unpack_uint4x8(p: u32) Vec<u8, 4> {
    return Vec::<u8, 4> { e: [p as u8, (p >> 8) as u8, (p >> 16) as u8, (p >> 24) as u8] };
}

/// The 16-bit halves x and y, x low.
pub const fn pack_int2x16(v: Vec<i16, 2>) i32 {
    return ((v.e[0] as u16) as u32 | (v.e[1] as u16) as u32 << 16) as i32;
}

/// The low and high 16 bits of `p`.
pub const fn unpack_int2x16(p: i32) Vec<i16, 2> {
    return Vec::<i16, 2> { e: [p as i16, (p as u32 >> 16) as i16] };
}

/// The 16-bit fields x, y, z, w, x lowest.
pub const fn pack_int4x16(v: Vec<i16, 4>) i64 {
    return pack_uint4x16(Vec::<u16, 4> { e: [v.e[0] as u16, v.e[1] as u16, v.e[2] as u16, v.e[3] as u16] }) as i64;
}

/// The 16-bit fields of `p`, lowest first.
pub const fn unpack_int4x16(p: i64) Vec<i16, 4> {
    let u = unpack_uint4x16(p as u64);
    return Vec::<i16, 4> { e: [u.e[0] as i16, u.e[1] as i16, u.e[2] as i16, u.e[3] as i16] };
}

/// The 16-bit halves x and y, x low.
pub const fn pack_uint2x16(v: Vec<u16, 2>) u32 {
    return v.e[0] as u32 | v.e[1] as u32 << 16;
}

/// The low and high 16 bits of `p`.
pub const fn unpack_uint2x16(p: u32) Vec<u16, 2> {
    return Vec::<u16, 2> { e: [p as u16, (p >> 16) as u16] };
}

/// The 16-bit fields x, y, z, w, x lowest.
pub const fn pack_uint4x16(v: Vec<u16, 4>) u64 {
    return v.e[0] as u64 | v.e[1] as u64 << 16 | v.e[2] as u64 << 32 | v.e[3] as u64 << 48;
}

/// The 16-bit fields of `p`, lowest first.
pub const fn unpack_uint4x16(p: u64) Vec<u16, 4> {
    return Vec::<u16, 4> { e: [p as u16, (p >> 16) as u16, (p >> 32) as u16, (p >> 48) as u16] };
}

/// The 32-bit halves x and y, x low.
pub const fn pack_int2x32(v: Vec<i32, 2>) i64 {
    return ((v.e[0] as u32) as u64 | (v.e[1] as u32) as u64 << 32) as i64;
}

/// The low and high 32 bits of `p`.
pub const fn unpack_int2x32(p: i64) Vec<i32, 2> {
    return Vec::<i32, 2> { e: [p as i32, (p as u64 >> 32) as i32] };
}

/// The 32-bit halves x and y, x low.
pub const fn pack_uint2x32(v: Vec<u32, 2>) u64 {
    return v.e[0] as u64 | v.e[1] as u64 << 32;
}

/// The low and high 32 bits of `p`.
pub const fn unpack_uint2x32(p: u64) Vec<u32, 2> {
    return Vec::<u32, 2> { e: [p as u32, (p >> 32) as u32] };
}

// The f64 1 / 255 of `unpack_unorm1x8` and `unpack_unorm2x8`, rounded to f32 where used.
const UNORM8_SCALE: f64 = 0.0039215686274509803921568627451;
const SNORM8_SCALE: f32 = 0.00787401574803149606299212598425;
const UNORM16_SCALE: f32 = 1.5259021896696421759365224689097e-5;
const SNORM16_SCALE: f32 = 3.0518509475997192297128208258309e-5;

// `x < y ? y : x`: a NaN `x` gives `x`.
fn max_f<T: Float>(x: T, y: T) T {
    if x.less(y) {
        return y;
    }
    return x;
}

// `min(max(x, lo), hi)`, `min(a, b)` being `b < a ? b : a`: a NaN `x` gives `x`.
fn clamp_f<T: Float>(x: T, lo: T, hi: T) T {
    let m = max_f(x, lo);
    if hi.less(m) {
        return hi;
    }
    return m;
}

// `round(clamp(x, 0, 1) * scale)` as an integer, for a `scale` below 2^31. The lower bound is
// tested first, so a NaN takes it: every result fits, and NaN gives 0 as a saturating `as` does.
const fn unorm(x: f32, scale: f32) u32 {
    let lo = if 0.0 < x {
        x;
    } else {
        0.0;
    };
    let c = if 1.0 < lo {
        1.0;
    } else {
        lo;
    };
    return unsafe (c * scale).round().to_int_unchecked::<u32>();
}

// `round(clamp(x, -1, 1) * scale)` as an integer, as `unorm` (NaN gives 0).
const fn snorm(x: f32, scale: f32) i32 {
    let lo = if -1.0 < x {
        x;
    } else if x == x {
        -1.0;
    } else {
        0.0;
    };
    let c = if 1.0 < lo {
        1.0;
    } else {
        lo;
    };
    return unsafe (c * scale).round().to_int_unchecked::<i32>();
}

// Bit fields 10, 10, 10, 2 from the lowest bit; each value keeps its low bits.
const fn fields_3x10_1x2(x: u32, y: u32, z: u32, w: u32) u32 {
    return x & 0x3FF | (y & 0x3FF) << 10 | (z & 0x3FF) << 20 | (w & 3) << 30;
}

// `f` as float16 bits: round to nearest with halves up; overflow gives an infinity, NaN keeps the sign
// and the top 10 mantissa bits (at least one set). An exponent overflow does not raise the
// floating-point overflow flag.
const fn to_float16(f: f32) i16 {
    let i = f32_bits(f) as i32;
    let s = i >> 16 & 0x00008000;
    let mut e = (i >> 23 & 0x000000ff) - (127 - 15);
    let mut m = i & 0x007fffff;
    if e <= 0 {
        if e < -10 {
            return s as i16;
        }
        m = (m | 0x00800000) >> 1 - e;
        if (m & 0x00001000) != 0 {
            m += 0x00002000;
        }
        return (s | m >> 13) as i16;
    } else if e == 0xff - (127 - 15) {
        if m == 0 {
            return (s | 0x7c00) as i16;
        }
        m = m >> 13;
        return (s | 0x7c00 | m | (m == 0) as i32) as i16;
    }
    if (m & 0x00001000) != 0 {
        m += 0x00002000;
        if (m & 0x00800000) != 0 {
            m = 0;
            e += 1;
        }
    }
    if e > 30 {
        return (s | 0x7c00) as i16;
    }
    return (s | e << 10 | m >> 13) as i16;
}

// The float16 bits `value` as an f32: exact; a NaN keeps its sign and mantissa bits.
const fn to_float32(value: i16) f32 {
    let v = value as i32;
    let s = v >> 15 & 0x00000001;
    let mut e = v >> 10 & 0x0000001f;
    let mut m = v & 0x000003ff;
    if e == 0 {
        if m == 0 {
            return f32_from_bits((s << 31) as u32);
        }
        // A denormal: at most 10 shifts, as 0 < m < 0x400.
        while (m & 0x00000400) == 0 {
            m = m << 1;
            e -= 1;
        }
        e += 1;
        m = m & ~0x00000400;
    } else if e == 31 {
        if m == 0 {
            return f32_from_bits((s << 31 | 0x7f800000) as u32);
        }
        return f32_from_bits((s << 31 | 0x7f800000 | m << 13) as u32);
    }
    e = e + (127 - 15);
    m = m << 13;
    return f32_from_bits((s << 31 | e << 23 | m) as u32);
}

// `x` as an unsigned 11-bit float (5-bit exponent, 6-bit mantissa); the sign is dropped and the
// exponent rebias wraps as a `u32`.
const fn float_to_11bit(x: f32) u32 {
    if x == 0.0 {
        return 0;
    } else if x.is_nan() {
        return ~0u32;
    } else if x.is_infinite() {
        return 0x1F << 6;
    }
    let f = f32_bits(x);
    return (f & 0x7f800000).wrapping_sub(0x38000000) >> 17 & 0x07c0 | f >> 17 & 0x003f;
}

// `x` as an unsigned 10-bit float, as `float_to_11bit` with a 5-bit mantissa.
const fn float_to_10bit(x: f32) u32 {
    if x == 0.0 {
        return 0;
    } else if x.is_nan() {
        return ~0u32;
    } else if x.is_infinite() {
        return 0x1F << 5;
    }
    let f = f32_bits(x);
    return (f & 0x7f800000).wrapping_sub(0x38000000) >> 18 & 0x03E0 | f >> 18 & 0x001f;
}

// An unsigned 11-bit float as an f32: -1 for NaN and infinity.
const fn packed11_to_float(x: u32) f32 {
    if x == 0 {
        return 0.0;
    } else if x == (1 << 11) - 1 || x == 0x1f << 6 {
        return -1.0;
    }
    return f32_from_bits(((x & 0x07c0) << 17) + 0x38000000 & 0x7f800000 | (x & 0x003f) << 17);
}

// An unsigned 10-bit float as an f32: -1 for NaN and infinity.
const fn packed10_to_float(x: u32) f32 {
    if x == 0 {
        return 0.0;
    } else if x == (1 << 10) - 1 || x == 0x1f << 5 {
        return -1.0;
    }
    return f32_from_bits(((x & 0x03E0) << 18) + 0x38000000 & 0x7f800000 | (x & 0x001f) << 18);
}
