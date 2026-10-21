// Measured by `tools/simd_math` (`simd-math-check --write`; f32: every input, f64: 1000000000 inputs per
// function and the special values, 0 results over the bound): the largest error per lane type,
// in ULP.
//   exp         f32 1.035 at -0x1.76642e0000000p2
//               f64 1.019 at -0x1.1f5982e421799p2
//   exp2        f32 1.039 at 0x1.29f0fc0000000p-1
//               f64 1.104 at -0x1.633cece39860bp9
//   exp10       f32 1.272 at -0x1.725ef40000000p3
//               f64 1.397 at -0x1.a216273c63853p0
//   expm1       f32 1.44 at 0x1.1008140000000p4
//               f64 1.822 at 0x1.6cc6d9340a042p-2
//   log         f32 0.887 at 0x1.67ff4e0000000p-1
//               f64 0.959 at 0x1.8629fb904f18dp-2
//   log2        f32 1.829 at 0x1.68bbf60000000p0
//               f64 1.62 at 0x1.fdb9cfa4a6025p-1
//   log10       f32 1.978 at 0x1.54640a0000000p0
//               f64 1.833 at 0x1.fde29aad243a2p-1
//   log1p       f32 1.438 at -0x1.8000000000000p-24
//               f64 1.438 at -0x1.80005eeee2c2ap-53
//   cbrt        f32 3.275 at 0x1.81976c0000000p-127
//               f64 3.388 at 0x1.7b531de53f782p-802
//   sin         f32 2.302 at 0x1.46f9e20000000p7
//               f64 2.335 at 0x1.6fa3142210b0cp18
//   cos         f32 2.303 at 0x1.7619960000000p7
//               f64 2.26 at -0x1.fb3f174cee18cp14
//   tan         f32 3.154 at 0x1.3465180000000p81
//               f64 3.114 at 0x1.592f6996f2992p137
//   sincos.sin  f32 2.302 at 0x1.46f9e20000000p7
//               f64 2.335 at 0x1.6fa3142210b0cp18
//   sincos.cos  f32 2.303 at 0x1.7619960000000p7
//               f64 2.26 at -0x1.fb3f174cee18cp14
//   asin        f32 2.318 at 0x1.10fe740000000p-1
//               f64 2.134 at -0x1.034f9a8c00c7ap-1
//   acos        f32 1.077 at 0x1.1972520000000p-1
//               f64 1.115 at -0x1.000031ba5d760p-1
//   atan        f32 2.105 at 0x1.b0bb620000000p-2
//               f64 2.258 at -0x1.b7c754425e933p-2
//   sinh        f32 2.177 at 0x1.fdc70c0000000p-7
//               f64 2.36 at -0x1.a0cf87c098b74p-2
//   cosh        f32 1.483 at 0x1.22e7480000000p2
//               f64 1.47 at -0x1.ee1e9f43d9f7bp1
//   tanh        f32 2.419 at 0x1.fd07940000000p-8
//               f64 2.557 at -0x1.a97d4703ebb20p-3
//   asinh       f32 2.096 at 0x1.0096420000000p-2
//               f64 2.151 at 0x1.fe38121021a34p-7
//   acosh       f32 2.884 at 0x1.01c8560000000p0
//               f64 3.083 at 0x1.0007e9f7044c1p0
//   atanh       f32 2.473 at 0x1.fa97480000000p-4
//               f64 2.438 at 0x1.ffa76a7f5b0d2p-8
//   erfc        f32 2.476 at 0x1.bc27240000000p2
//               f64 2.546 at 0x1.b8c745394c049p2
//   pow         f32 1.202 at 0x1.4860800000000p-51, 0x1.184bb80000000p0
//               f64 1.189 at 0x1.70ca1fe0e6888p948, -0x1.b1ade687bd7afp-1
//   powi        f32 1.195 at 0x1.464fc80000000p-1, 0x1.a000000000000p3
//               f64 1.199 at 0x1.de762650992d1p-3, 0x1.1800000000000p5
//   atan2       f32 2.454 at 0x1.576fde0000000p-73, 0x1.8707f20000000p-72
//               f64 2.618 at 0x1.aead863adeacbp1021, 0x1.f7264405a5096p1022
//   hypot       f32 1.195 at 0x1.edac920000000p79, 0x1.6c5b020000000p88
//               f64 1.195 at 0x1.6b0f597b53e6ep404, 0x1.eba6eedf1adb4p380
//
// Vector elementary functions, the `balanced` class: at most 3.5 ULP from the exact result for every
// input, IEEE special values (C Annex F), subnormals in and out, and the same bits on every target
// and at compile time, a NaN's sign and payload aside. The kernels of `std::simd::math` (the `precise` class) without their
// double-word steps: the same polynomials, the results rounded in plain arithmetic.
//
// Reductions and approximations (p is the precision, 24 or 53 bits):
//   exp:  x = k ln2 + r by two fmas, e^r = 1 + r + r^2 (1/2 + r P(r)) (P a shorter polynomial than
//         the precise class's: its error is an ULP of e^r), times 2^k (`exp_fin`).
//   exp2, exp10: r = (x - k) ln2, or x - k log10(2) by two fmas times ln10; the same kernel.
//   expm1: the same r and k; 2^k (1 + q) - 1 = fma(2^k, q, 2^k - 1), q = e^r - 1 by the precise
//         polynomial (its error is relative to e^r - 1).
//   log, log2, log10, log1p: x = m 2^e, log m in one word: f64 from the precise class's table (no
//         division), f32 by fdlibm (s = f / (2 + f), f - f^2/2 + s (f^2/2 + s^2 P(s^2))); log1p adds
//         1 + x - u times about 1/u.
//   pow, powi: e^(y log x) with the precise class's log as a double word and e^ of its sum.
//   cbrt: the polynomial start and one Halley step.
//   hypot: sqrt(fma(x, x, y^2)), both scaled to one binade only in the lanes that need it.
//   sin, cos, tan, sincos: x = q pi/2 + r below 2^19 (f64) or 2^8 (f32) by four parts of pi/2 in four
//         fmas (r within about 1.5 ULP), above by the bits of 2/pi;
//         then r + r^3 P(r^2), 1 - r^2/2 + r^4 P(r^2); tan = sin/cos, from the exact reduction (as
//         `precise`) and first-order corrections for its low part.
//   asin, acos: |x| <= 1/2: x + x^3 P(x^2); else pi/2 - 2 asin(sqrt((1 - |x|) / 2)).
//   atan, atan2: t, -1/t or (t - 1)/(t + 1) by octant, then t + t^3 P(t^2) plus pi/4 or pi/2.
//   sinh, cosh, tanh: t = e^|x| - 1 as in expm1: (t + t/(t + 1))/2, (e^|x| + e^-|x|)/2, t/(t + 2).
//   asinh, acosh, atanh: one log1p: |x| + x^2/(1 + sqrt(1 + x^2)), x - 1 + sqrt((x - 1)(x + 1)), and
//         2|x|/(1 - |x|) (fdlibm), past 2^(p/2) log|x| + ln2.
//   erfc: the precise kernels' polynomial and table (each only when a lane needs it), e^-x^2 from the
//         exact x^2. No erf: its cost is the table, as the precise one's, so it is no faster
//         (`std::simd::math::erf`).
import std::simd::math::lane as *;

// e^r - 1 for |r| <= ln2/2 + rounding: r + r^2 (1/2 + r P(r)), P `ExpP`, or the shorter `ExpB` whose
// error is an ULP of e^r only, not of e^r - 1.
fn expm1_r<T: Lane, const P: Poly, const N: usize>(r: Simd<T, N>) Simd<T, N> {
    return (r * r).fma(r.fma(T::poly::<P>(r), sp(0.5)), r);
}

// `(r, k)` with x = k ln2 + r, |r| <= ln2/2.
fn reduce_ln2<T: Lane, const N: usize>(x: Simd<T, N>) (Simd<T, N>, Simd<T, N>) {
    let kc = T::kc();
    let k = (x * kc.log2e_hi).round_even();
    return (-k).fma(Simd::splat(kc.ln2_lo), (-k).fma(Simd::splat(kc.ln2_hi), x)), k;
}

/// e^x.
pub fn exp<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let (r, k) = reduce_ln2(x);
    return exp_fin(x, kc.exp_max, kc.exp_min, 0.0, sp::<T, N>(1.0) + expm1_r::<T, {Poly::ExpB}, N>(r), k);
}

/// 2^x.
pub fn exp2<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let k = x.round_even();
    let r = (x - k) * kc.ln2_hi;
    return exp_fin(x, kc.exp2_max, kc.exp2_min, 0.0, sp::<T, N>(1.0) + expm1_r::<T, {Poly::ExpB}, N>(r), k);
}

/// 10^x.
pub fn exp10<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let k = (x * kc.log2_10).round_even();
    let r = (-k).fma(Simd::splat(kc.lg2_lo), (-k).fma(Simd::splat(kc.lg2_hi), x));
    let s = r * kc.ln10_hi;
    return exp_fin(x, kc.exp10_max, kc.exp10_min, 0.0, sp::<T, N>(1.0) + expm1_r::<T, {Poly::ExpB}, N>(s), k);
}

// `(t, y, k)`: e^x - 1 = t and e^x = y 2^k, for x at most `exp_max`. Up to k = sub_bits t is
// fma(2^k, q, 2^k - 1) (one rounding); past it 2^k (1 + q), where the 1 is below a quarter ULP.
fn expm1_k<T: Lane, const N: usize>(x: Simd<T, N>) (Simd<T, N>, Simd<T, N>, Simd<T, N>) {
    let kc = T::kc();
    let (r, k) = reduce_ln2(x);
    let q = expm1_r::<T, {Poly::ExpP}, N>(r);
    let y = sp::<T, N>(1.0) + q;
    let t = T::pow2i(at_most(k, Simd::splat(kc.sub_bits)));
    return choose(k.greater_than(Simd::splat(kc.sub_bits)), scale(y, k), t.fma(q, t - T::c(1.0))), y, k;
}

/// e^x - 1, accurate near 0.
pub fn expm1<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let (t, _, _) = expm1_k(x);
    return choose(x.equal(sp(0.0)), x, exp_range(x, kc.exp_max, kc.expm1_min, -1.0, t));
}

/// The natural logarithm.
pub fn log<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let (e, v, _) = T::log_b(x);
    return log_special(x, e.fma(Simd::splat(kc.ln2_hi), e.fma(Simd::splat(kc.ln2_lo), v)));
}

/// The base-2 logarithm.
pub fn log2<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let (e, v, _) = T::log_b(x);
    return log_special(x, v.fma(Simd::splat(kc.log2e_hi), e));
}

/// The base-10 logarithm.
pub fn log10<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let (e, v, _) = T::log_b(x);
    return log_special(x, e.fma(Simd::splat(kc.lg2_hi), v.fma(Simd::splat(kc.log10e_hi), e * kc.lg2_lo)));
}

// log(1 + x) for 1 + x in [0, inf], without its special cases: u + c = 1 + x exactly, log u + c/u with
// c/u as c im 2^-e (no division).
fn log1p_v<T: Lane, const N: usize>(x: Simd<T, N>) (Simd<T, N>, Simd<T, N>) {
    let kc = T::kc();
    // c = 1 + x - u exactly: u - 1 and x - (u - 1) are exact for u below 2^p; past it c is below
    // 2^-p u and its omission below the result's rounding.
    let u = sp::<T, N>(1.0) + x;
    let c = x - (u - T::c(1.0));
    let (e, v, im) = T::log_b(u);
    let cu = c * im * T::pow2i(at_most(at_least(-e, Simd::splat(kc.emin)), Simd::splat(kc.emax)));
    return e.fma(Simd::splat(kc.ln2_hi), v + e.fma(Simd::splat(kc.ln2_lo), cu)), u;
}

/// log(1 + x), accurate near 0.
pub fn log1p<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let (y, u) = log1p_v(x);
    return choose(x.equal(sp(0.0)), x, log_special(u, y));
}

/// x^y (Annex F: pow(x, +-0) = 1 and pow(1, y) = 1 for every x and y, NaN included).
pub fn pow<T: Lane, const N: usize>(x: Simd<T, N>, y: Simd<T, N>) Simd<T, N> {
    let (yi, yo) = pow_parity(y);
    return pow_dw(x, y, sp(0.0), yi, yo);
}

/// x^n.
pub fn powi<T: Lane, const N: usize>(x: Simd<T, N>, n: Simd<i32, N>) Simd<T, N> {
    let (yh, yl) = T::of_i32(n);
    return pow_dw(x, yh, yl, Mask::<N>::splat(true), (n & 1).equal(Simd::splat(1)));
}

// x^(yh + yl) with y integral and odd as given; yl is 0 unless y is an integer past the precision.
fn pow_dw<T: Lane, const N: usize>(x: Simd<T, N>, yh: Simd<T, N>, yl: Simd<T, N>, yint: Mask<N>, yodd: Mask<N>) Simd<
    T,
    N
> {
    let (lh, ll) = T::logk(x.abs());
    let (zh, z0) = two_prod(yh, lh);
    let zl = yh.fma(ll, yl.fma(lh, z0));
    // e^(zh + zl): zh reduced by two fmas, zl added to r.
    let (r, k) = reduce_ln2(zh);
    return pow_finish(x, yh, yint, yodd, zh, scale(sp::<T, N>(1.0) + expm1_r::<T, {Poly::ExpB}, N>(r + zl), k));
}

/// The cube root.
pub fn cbrt<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let (c, y, q) = cbrt_start::<T, {Poly::CbrtB}, N>(x.abs());
    // Halley: y (y^3 + 2c) / (2 y^3 + c).
    let y3 = y * y * y;
    return cbrt_finish(x, y * (y3 + c + c) / (y3 + y3 + c), q);
}

/// sqrt(x^2 + y^2) without overflow or underflow in between (Annex F: an infinite argument gives
/// +inf, NaN included).
pub fn hypot<T: Lane, const N: usize>(x: Simd<T, N>, y: Simd<T, N>) Simd<T, N> {
    let hi = x.abs().max_num(y.abs());
    let lo = x.abs().min_num(y.abs());
    let (e, far) = hypot_e(hi);
    let r = if far {
        let hs = scale(hi, -e);
        let ls = scale(lo, -e);
        scale(ls.fma(ls, hs * hs).sqrt(), e);
    } else {
        lo.fma(lo, hi * hi).sqrt();
    };
    return hypot_finish(x, y, r);
}

// `(q, r)`: x = q pi/2 + r modulo 2 pi, q in 0..4, |r| <= pi/4 plus rounding (see the header); a NaN or
// infinite x gives a NaN r.
fn reduce_pio2<T: Lane, const N: usize>(x: Simd<T, N>) (Simd<T, N>, Simd<T, N>) {
    let kc = T::kc();
    let big = x.abs().greater_equal(Simd::splat(kc.cw_max));
    if unlikely(big.any()) {
        // Its own path, as `rem_pio2`'s.
        let k = choose(big, sp::<T, N>(0.0), (x * kc.two_over_pi).round_even());
        let fin = x.is_finite();
        let (bq, bh, bl) = T::rem_pio2_big(choose(big & fin, x, Simd::splat(kc.cw_max)));
        let q = k - (k * T::c(0.25)).floor() * T::c(4.0);
        return choose(big, bq, q), choose(big, choose(fin, bh + bl, x - x), sub_pio2(x, k));
    }
    let k = (x * kc.two_over_pi).round_even();
    return k - (k * T::c(0.25)).floor() * T::c(4.0), sub_pio2(x, k);
}

fn sin_r<T: Lane, const N: usize>(r: Simd<T, N>) Simd<T, N> {
    let z = r * r;
    return (z * r).fma(T::poly::<{Poly::SinP}>(z), r);
}

// cos r = w + ((1 - w) - z/2 + z^2 P(z)), w = 1 - z/2 rounded (fdlibm): the rounding of w kept.
fn cos_r<T: Lane, const N: usize>(r: Simd<T, N>) Simd<T, N> {
    let z = r * r;
    let hz = z * T::c(0.5);
    let w = sp::<T, N>(1.0) - hz;
    return w + (z * z).fma(T::poly::<{Poly::CosP}>(z), sp::<T, N>(1.0) - w - hz);
}

/// The sine.
pub fn sin<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let (q, r) = reduce_pio2(x);
    let v = choose(q.equal(sp(1.0)) | q.equal(sp(3.0)), cos_r(r), sin_r(r));
    let s = choose(q.greater_equal(sp(2.0)), -v, v);
    return choose(x.equal(sp(0.0)), x, s);
}

/// The cosine.
pub fn cos<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let (q, r) = reduce_pio2(x);
    let v = choose(q.equal(sp(1.0)) | q.equal(sp(3.0)), sin_r(r), cos_r(r));
    return choose(q.equal(sp(1.0)) | q.equal(sp(2.0)), -v, v);
}

/// `(sin x, cos x)`.
pub fn sincos<T: Lane, const N: usize>(x: Simd<T, N>) (Simd<T, N>, Simd<T, N>) {
    let (q, r) = reduce_pio2(x);
    let odd = q.equal(sp(1.0)) | q.equal(sp(3.0));
    let s0 = sin_r(r);
    let c0 = cos_r(r);
    let s1 = choose(odd, c0, s0);
    let c1 = choose(odd, s0, c0);
    let s = choose(q.greater_equal(sp(2.0)), -s1, s1);
    let c = choose(q.equal(sp(1.0)) | q.equal(sp(2.0)), -c1, c1);
    return choose(x.equal(sp(0.0)), x, s), c;
}

/// The tangent.
pub fn tan<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    // The exact reduction (rh + rl): near a pole or a zero, an error of r is the result's.
    let (q, rh, rl) = rem_pio2(x);
    let s0 = sin_r(rh);
    let c0 = cos_r(rh);
    let s = rl.fma(c0, s0);
    let c = (-rl).fma(s0, c0);
    let odd = q.equal(sp(1.0)) | q.equal(sp(3.0));
    let v = choose(odd, -c, s) / choose(odd, s, c);
    return choose(x.equal(sp(0.0)), x, v);
}

/// The arcsine.
pub fn asin<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    let small = a.less_equal(sp(0.5));
    let z = choose(small, a * a, (sp::<T, N>(1.0) - a) * T::c(0.5));
    let s = choose(small, a, z.sqrt());
    let t = (s * z).fma(T::poly::<{Poly::AsinP}>(z), s);
    let big = Simd::<T, N>::splat(kc.pio2_hi) - (t + t - kc.pio2_lo);
    let r = choose(small, t, big);
    return choose(x.equal(sp(0.0)), x, choose(a.greater_than(sp(1.0)) | x.is_nan(), nan(), r.copysign(x)));
}

/// The arccosine.
pub fn acos<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    let small = a.less_equal(sp(0.5));
    let z = choose(small, a * a, (sp::<T, N>(1.0) - a) * T::c(0.5));
    let s = choose(small, x, z.sqrt());
    let t = (s * z).fma(T::poly::<{Poly::AsinP}>(z), s);
    // Small: pi/2 - t. x > 1/2: 2t. x < -1/2: pi - 2t.
    let rs = Simd::<T, N>::splat(kc.pio2_hi) - (t - kc.pio2_lo);
    let rn = Simd::<T, N>::splat(kc.pi_hi) - (t + t - kc.pi_lo);
    let r = choose(small, rs, choose(x.greater_than(sp(0.0)), t + t, rn));
    return choose(a.greater_than(sp(1.0)) | x.is_nan(), nan(), r);
}

// atan(n / d) for 0 <= n <= d (n / d in [0, 1], 0/0 excluded by the caller).
fn atan_q<T: Lane, const N: usize>(n: Simd<T, N>, d: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let t = n / d;
    // t > tan(pi/8): pi/4 + atan((t - 1)/(t + 1)).
    let mid = t.greater_than(Simd::splat(kc.tan_pio8));
    let u = choose(mid, (t - T::c(1.0)) / (t + T::c(1.0)), t);
    let z = u * u;
    let m: Simd<T, N> = choose(mid, sp(0.5), sp(0.0)); // pi/4 or 0
    return m * kc.pio2_hi + (z * u).fma(T::poly::<{Poly::AtanP}>(z), m * kc.pio2_lo + u);
}

/// The arctangent.
pub fn atan<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    // |x| > 1: pi/2 - atan(1/|x|).
    let inv = a.greater_than(sp(1.0));
    let v = atan_q(choose(inv, sp(1.0), a), choose(inv, a, sp(1.0)));
    let r = choose(inv, Simd::<T, N>::splat(kc.pio2_hi) - (v - kc.pio2_lo), v);
    return choose(x.is_nan() | x.equal(sp(0.0)), x, r.copysign(x));
}

/// The angle of (x, y) from the positive x axis, in [-pi, pi] (Annex F signed zeros and infinities).
pub fn atan2<T: Lane, const N: usize>(y: Simd<T, N>, x: Simd<T, N>) Simd<T, N> {
    let (n, d, swap) = atan2_nd(y, x);
    return atan2_finish(y, x, swap, choose(n.equal(sp(0.0)), sp(0.0), atan_q(choose(swap, d, n), choose(swap, n, d))));
}

/// The hyperbolic sine.
pub fn sinh<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    let big = a.greater_than(Simd::splat(kc.hyp_big));
    // Up to hyp_big: (t + t/(t + 1))/2, t = e^a - 1; past it e^a / 2.
    let (t, y, k) = expm1_k(a);
    let r = choose(big, scale(y, k - T::c(1.0)), (t + t / (t + T::c(1.0))) * T::c(0.5));
    let out = choose(a.greater_than(Simd::splat(kc.cosh_max)), inf(), r);
    return choose(a.less_than(Simd::splat(kc.tiny)) | x.is_nan(), x, out.copysign(x));
}

/// The hyperbolic cosine.
pub fn cosh<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    let (r, k) = reduce_ln2(a);
    let y = sp::<T, N>(1.0) + expm1_r::<T, {Poly::ExpB}, N>(r);
    // (e^a + e^-a)/2 = y 2^(k-1) + 2^(-k-1) / y; past hyp_big the second term is below the rounding.
    let big = a.greater_than(Simd::splat(kc.hyp_big));
    let ks = choose(big, sp(0.0), k);
    let small = y * T::pow2i(ks - T::c(1.0)) + T::pow2i(-ks - T::c(1.0)) / y;
    let r2 = choose(big, scale(y, k - T::c(1.0)), small);
    return choose(x.is_nan(), x, choose(a.greater_than(Simd::splat(kc.cosh_max)), inf(), r2));
}

/// The hyperbolic tangent.
pub fn tanh<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    let one = a.greater_than(Simd::splat(kc.tanh_one));
    // t/(t + 2), t = e^2a - 1 (2a at most 2 tanh_one: 2^k stays normal).
    let (t, _, _) = expm1_k(choose(one, sp(0.0), a + a));
    let r = choose(one, sp(1.0), t / (t + T::c(2.0)));
    return choose(a.less_than(Simd::splat(kc.tiny)) | x.is_nan(), x, r.copysign(x));
}

/// The inverse hyperbolic sine.
pub fn asinh<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let (v, _) = log1p_v(asinh_arg(x.abs()));
    return asinh_finish(x, v);
}

/// The inverse hyperbolic cosine.
pub fn acosh<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let (v, _) = log1p_v(acosh_arg(x));
    return acosh_finish(x, v);
}

/// The inverse hyperbolic tangent.
pub fn atanh<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let a = x.abs();
    let (v, _) = log1p_v((a + a) / (sp::<T, N>(1.0) - a));
    return atanh_finish(x, v);
}

// erfc a = y 2^k for a >= 1/2 (NaN and a below 1/2 as 1/2): e^-a^2 from the exact a^2, times the
// table's g.
fn erfc_k<T: Lane, const N: usize>(a: Simd<T, N>) (Simd<T, N>, Simd<T, N>) {
    let b = at_most(at_least(a, sp(0.5)), Simd::splat(T::kc().erfc_max));
    let (m, e) = T::frexp(b);
    let (g, _) = T::erfc_g(b, (e + T::c(1.0)) * T::c(8.0) + ((m - T::c(1.0)) * T::c(8.0)).floor());
    let (sh, sl) = two_prod(b, b);
    let (r, k) = reduce_ln2(-sh);
    return (sp::<T, N>(1.0) + expm1_r::<T, {Poly::ExpB}, N>(r - sl)) * g, k;
}

/// The complementary error function, 1 - erf x, accurate where erf x is near 1.
pub fn erfc<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let a = x.abs();
    let lo = a.less_than(sp(0.5));
    let s = if lo.any() {
        sp::<T, N>(1.0) - erf_b(x);
    } else {
        x;
    };
    let b = if (!lo).any() {
        let (y, k) = erfc_k(a);
        let c = scale(y, k);
        choose(x.less_than(sp(0.0)), sp::<T, N>(2.0) - c, c);
    } else {
        x;
    };
    return choose(lo, s, choose(x.is_nan(), x, b));
}

// erf x for |x| < 1/2: 2/sqrt(pi) x + x z P(z), z = x^2.
fn erf_b<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let z = x * x;
    return x.fma(Simd::splat(T::kc().two_sqrtpi_hi), x * z * T::poly::<{Poly::ErfP}>(z));
}
