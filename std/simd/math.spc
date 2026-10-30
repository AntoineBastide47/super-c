// Measured by `tools/simd_math` (`simd-math-check --write`; f32: every input, f64: 1000000000 inputs per
// function and the special values, 0 results over the bound): the largest error per lane type,
// in ULP.
//   exp         f32 0.765 at -0x1.5e8f980000000p6
//               f64 0.752 at -0x1.6241e3994809dp9
//   exp2        f32 0.768 at -0x1.f9f8200000000p6
//               f64 0.745 at -0x1.ff0fc1d4876c4p9
//   exp10       f32 0.762 at -0x1.3073a80000000p5
//               f64 0.752 at -0x1.33b2d27a75e22p8
//   expm1       f32 0.761 at 0x1.1afd300000000p4
//               f64 0.612 at 0x1.368740eb193d8p5
//   log         f32 0.675 at 0x1.64a8120000000p0
//               f64 0.501 at 0x1.fe80f508ede7cp-1
//   log2        f32 0.769 at 0x1.69757e0000000p0
//               f64 0.502 at 0x1.fe0d7be12ea7fp-1
//   log10       f32 0.704 at 0x1.54d34a0000000p0
//               f64 0.503 at 0x1.01e76bc8dbba0p0
//   log1p       f32 0.684 at 0x1.9792660000000p-2
//               f64 0.661 at -0x1.9fff038ef68d2p-53
//   cbrt        f32 0.501 at 0x1.b7c6260000000p-124
//               f64 0.501 at -0x1.fffffe52ab5efp509
//   sin         f32 0.813 at 0x1.d5b1d40000000p92
//               f64 0.8 at -0x1.000000f13fe18p28
//   cos         f32 0.812 at 0x1.d99b860000000p14
//               f64 0.798 at -0x1.39c6fd67805a7p18
//   tan         f32 0.737 at 0x1.a5c03a0000000p32
//               f64 0.757 at -0x1.45b9220072649p242
//   sincos.sin  f32 0.813 at 0x1.d5b1d40000000p92
//               f64 0.8 at -0x1.000000f13fe18p28
//   sincos.cos  f32 0.812 at 0x1.d99b860000000p14
//               f64 0.798 at -0x1.39c6fd67805a7p18
//   asin        f32 0.65 at 0x1.0485ea0000000p-1
//               f64 0.645 at -0x1.00004f1599f64p-1
//   acos        f32 0.609 at 0x1.367ef20000000p-1
//               f64 0.588 at 0x1.1c8639c8151d0p-1
//   atan        f32 0.704 at 0x1.aa9b840000000p-2
//               f64 0.681 at -0x1.b9d6aaff2f1e6p-2
//   sinh        f32 0.932 at 0x1.0486c20000000p-1
//               f64 0.935 at -0x1.00000007ea644p-1
//   cosh        f32 0.748 at 0x1.5dc6920000000p-2
//               f64 0.748 at 0x1.5c893df04fe56p-2
//   tanh        f32 0.827 at 0x1.18ad880000000p-1
//               f64 0.78 at 0x1.000f39da1d348p-1
//   asinh       f32 0.677 at 0x1.62e7d20000000p-2
//               f64 0.519 at 0x1.e38f55a444675p-8
//   acosh       f32 0.66 at 0x1.0f4b1e0000000p0
//               f64 0.996 at 0x1.00001fa319290p0
//   atanh       f32 0.686 at 0x1.5d77e40000000p-3
//               f64 0.512 at 0x1.de5394ef52198p-9
//   erf         f32 1 at 0x1.8654f20000000p-125
//               f64 0.872 at -0x1.c541156aea947p-1021
//   erfc        f32 0.804 at 0x1.eaabec0000000p-2
//               f64 0.79 at 0x1.fff4a3b81821bp-2
//   pow         f32 0.755 at 0x1.6dbebc0000000p100, -0x1.4221f20000000p0
//               f64 0.751 at 0x1.e5b45779bb752p-526, 0x1.f25c238861569p0
//   powi        f32 0.752 at 0x1.b1bc120000000p-2, 0x1.9800000000000p6
//               f64 0.75 at 0x1.8b6ae8289cc96p-2, 0x1.7480000000000p9
//   atan2       f32 0.71 at 0x1.4694300000000p83, 0x1.9058ee0000000p84
//               f64 0.679 at -0x1.47fe09cba3b0cp-634, 0x1.8e953a2e53894p-633
//   hypot       f32 0.922 at 0x1.5cff080000000p-127, 0x1.abd1c00000000p-129
//               f64 0.917 at 0x0.965f75416d594p-1022, 0x0.6c53a75a1a60ep-1022
//
// Vector elementary functions, the `precise` class: at most 1.0 ULP from the exact result for every
// input, IEEE special values (C Annex F), subnormals in and out, and the same bits on every target
// and at compile time, a NaN's sign and payload aside (`lane.spc`). `std::simd::math::balanced` (at most 3.5 ULP) and
// `std::simd::math::fast` (a relative error bound per function) trade accuracy for speed. Each
// function is generic over the lane count and takes `f32` or `f64` lanes; the methods (`v.exp()`)
// are this class's.
//
// Reductions and approximations (p is the precision, 24 or 53 bits; double words carry about 2p bits):
//   exp:  x = k ln2 + r + rl, |r| <= ln2/2, r = x - k ln2_hi exact in one fma: 1 + r exact as a
//         double word, e^r - 1 - r = r^2 (1/2 + r P(r)) in one word and the factor 1 + rl, rounded
//         once (`exp_rw`); times 2^k by one product while 2^k is normal, exact unless the result is
//         subnormal, which rounds once more (`exp_fin`).
//   exp2, exp10: the same kernel at (x - k) ln2 and (x - k log10 2) ln10, both as double words.
//   expm1: below 0.34, x + x^2/2 + x^3 P(x), x^2/2 exact; past it e^x as a double word minus 1, e^x
//         = (h + l) 2^k: f64: x = k ln2/128 + r, 2^(j/128) = hi (1 + tail) from a table (j = k mod
//         128) and e^r - 1 = r + r^2 P(r): hi + hi (tail + r + r^2 P(r)) (glibc's exp); f32: 1 + r
//         and r^2/2 exact as double words.
//   log:  f64: x = 2^k z, z in [0x1.6p-1, 0x1.6p0) (subnormals scaled first), log z = log(1/invc) +
//         log1p(r) with invc from a 128-entry table and r = z invc - 1 exact in one fma (|r| < 2^-7),
//         log1p(r) = r - r^2/2 + r^3 P(r) (glibc's log). f32: x = m 2^e, m in [sqrt(1/2), sqrt(2)),
//         log m = f - f^2/2 + s (f^2/2 + s^2 P(s^2)), s = f / (2 + f) (fdlibm). Summed with k ln2
//         exactly.
//   log2, log10, log1p: the same parts times 1/ln2, 1/ln10 as double words; log1p: 1 + x = u + c
//         exactly, plus c/u.
//   pow, powi: e^(y log x) with log x as a double word (f64: the log table, r - r^2/2 exact and r^3
//         P(r) to 2^-68 relative, glibc's pow; f32: s = f / (2 + f), s^3 and s^5 as double words)
//         and e^ of a double-word argument; the sign and Annex F cases through masks, only when a
//         lane needs them (`pow_finish`, shared by the classes).
//   cbrt: x = m 2^(3q + r); a polynomial start and two Newton steps, the last with the residual
//         y^3 - x exact.
//   hypot: x^2 + y^2 as a double word rounded once, then its square root; a lane whose squares could
//         overflow or lose bits scaled to one binade first.
//   sin, cos, tan, sincos: x = q pi/2 + r, |r| <= pi/4: below 2^19 (f64) or 2^8 (f32) three parts
//         of pi/2, the first product exact and the second an exact double word, above by exact
//         integer arithmetic on the bits of 2/pi; then r + r^3 P(r^2), 1 - r^2/2 + r^4 P(r^2) (fdlibm kernels) and tan r = 2t / (1 - t^2)
//         with t = tan(r/2) = u + u^3 P(u^2), as double words.
//   asin, acos: |x| <= 1/2: x + x^3 P(x^2); else pi/2 - 2 asin(sqrt((1 - |x|) / 2)), the root and
//         the sum with pi/2 as double words.
//   atan, atan2: |t| > tan(3pi/8): pi/2 - atan(1/t); > tan(pi/8): pi/4 + atan((t - 1)/(t + 1));
//         then t + t^3 P(t^2), the quotient and the sum as double words; atan2 by octant.
//   sinh, cosh, tanh: |x| <= 1/2 (tanh: 0.55): x + x^3 P(x^2); past it (e^|x| +- e^-|x|)/2 with e^|x|
//         a double word and e^-|x| its reciprocal to half an ULP, and tanh = 1 - 2/(e^2|x| + 1), the
//         quotient as a double word. Each part only when a lane needs it.
//   asinh, acosh, atanh: the logarithm of a double-word argument (its low part as a correction from
//         s, `log_hl`): |x| + sqrt(x^2 + 1), x + sqrt(x^2 - 1), (1 + x) / (1 - x); past 2^(p/2 + 1),
//         log(2|x|).
//   erf, erfc: |x| < 1/2: 2/sqrt(pi) x + x^3 P(x^2), the first product exact; else erfc |x| =
//         e^-x^2 g(|x|) with e^-x^2 from the exact x^2 and g = erfc e^(x^2) from a table of 8
//         polynomials per binade (P(u) ~ g(mid + u), its constant as a double word, u the offset
//         from the piece's midpoint, the piece from the exponent and the top three significand
//         bits); erf = 1 - erfc, erfc of a negative x = 2 - erfc |x|, all as double words; each part
//         only when a lane needs it.
import std::simd::math::lane as *;

/// e^x.
pub fn exp<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let k = (x * kc.log2e_hi).round_even();
    // x - k ln2_hi is exact (it needs at most p bits); the rest of k ln2 is the low part.
    let y = exp_rw((-k).fma(Simd::splat(kc.ln2_hi), x), -k * kc.ln2_lo);
    return exp_fin(x, kc.exp_max, kc.exp_min, 0.0, y, k);
}

/// 2^x.
pub fn exp2<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let k = x.round_even();
    let r = x - k;
    let (th, t0) = two_prod(r, Simd::splat(kc.ln2_hi));
    let y = exp_rw(th, r.fma(Simd::splat(kc.ln2_lo), t0));
    return exp_fin(x, kc.exp2_max, kc.exp2_min, 0.0, y, k);
}

/// 10^x.
pub fn exp10<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let k = (x * kc.log2_10).round_even();
    let r1 = (-k).fma(Simd::splat(kc.lg2_hi), x); // exact, as in `expk`
    let t = k * kc.lg2_lo;
    let (r, e) = two_sum(r1, -t);
    let rl = e - k.fma(Simd::splat(kc.lg2_lo), -t);
    let (th, t0) = two_prod(r, Simd::splat(kc.ln10_hi));
    let y = exp_rw(th, r.fma(Simd::splat(kc.ln10_lo), rl.fma(Simd::splat(kc.ln10_hi), t0)));
    return exp_fin(x, kc.exp10_max, kc.exp10_min, 0.0, y, k);
}

/// e^x - 1, accurate near 0.
pub fn expm1<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    // Below 0.34 (ln2/2) its own series, the terms below x^3 exact (the result is near x there); past it
    // `Lane::expk`. Each only when a lane needs it.
    let small = x.abs().less_than(sp(0.34));
    let t = if small.any() {
        // x + x^2/2 + x^3 P(x), x^2/2 exact as a double word and added to x exactly.
        let (qh, ql) = two_prod(x, x);
        let (a, b) = fast_two_sum(x, qh * T::c(0.5));
        a + (b + (ql * T::c(0.5) + x * qh * T::poly::<{Poly::ExpP}>(x)))
    } else {
        x
    };
    let b = if (!small).any() {
        let (h, l, k) = T::expk(x, sp(0.0));
        // Past 2^(p + 1) the 1 is below a quarter ULP: e^x itself (2^k h alone could overflow there).
        let (s, e) = two_sum(scale(h, k), sp(-1.0));
        choose(k.greater_than(Simd::<T, N>::splat(kc.sub_bits) + T::c(1.0)), scale(h + l, k), s + (e + scale(l, k)))
    } else {
        x
    };
    return choose(x.equal(sp(0.0)), x, exp_range(x, kc.exp_max, kc.expm1_min, -1.0, choose(small, t, b)));
}

/// The natural logarithm.
pub fn log<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let (e, a, b, _) = T::log_parts(x);
    let (eh, el) = two_prod(e, Simd::splat(kc.ln2_hi));
    let (h, l) = two_sum(eh, a);
    return log_special(x, h + (l + (b + e.fma(Simd::splat(kc.ln2_lo), el))));
}

/// The base-2 logarithm.
pub fn log2<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let (e, a, b, _) = T::log_parts(x);
    let (p, p0) = two_prod(a, Simd::splat(kc.log2e_hi));
    let pl = a.fma(Simd::splat(kc.log2e_lo), b.fma(Simd::splat(kc.log2e_hi), p0));
    let (h, l) = two_sum(e, p);
    return log_special(x, h + (l + pl));
}

/// The base-10 logarithm.
pub fn log10<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let (e, a, b, _) = T::log_parts(x);
    let (eh, e0) = two_prod(e, Simd::splat(kc.lg2_hi));
    let el = e.fma(Simd::splat(kc.lg2_lo), e0);
    let (p, p0) = two_prod(a, Simd::splat(kc.log10e_hi));
    let pl = a.fma(Simd::splat(kc.log10e_lo), b.fma(Simd::splat(kc.log10e_hi), p0));
    let (h, l) = two_sum(eh, p);
    return log_special(x, h + (l + (pl + el)));
}

/// log(1 + x), accurate near 0.
pub fn log1p<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let (uh, ul) = two_sum(sp(1.0), x);
    let (e, a, b, _) = T::log_parts(uh);
    let (eh, el) = two_prod(e, Simd::splat(kc.ln2_hi));
    let (h, l) = two_sum(eh, a);
    let y = h + (l + (b + ul / uh + e.fma(Simd::splat(kc.ln2_lo), el)));
    return choose(x.equal(sp(0.0)), x, log_special(uh, y));
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
    let (h, l, k) = T::expk(zh, zl);
    return pow_finish(x, yh, yint, yodd, zh, scale(h + l, k));
}

/// The cube root.
pub fn cbrt<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let (c, y0, q) = cbrt_start::<T, {Poly::CbrtP}, N>(x.abs());
    // Newton: y - (y^3 - c) / (3 y^2), the residual of the last step exact.
    let y = y0 - (y0 * y0 * y0 - c) / (y0 * y0 * T::c(3.0));
    let (y2h, y2l) = two_prod(y, y);
    let res = y2h.fma(y, -c) + y2l * y;
    return cbrt_finish(x, y - res / (y * y * T::c(3.0)), q);
}

/// sqrt(x^2 + y^2) without overflow or underflow in between (Annex F: an infinite argument gives
/// +inf, NaN included).
pub fn hypot<T: Lane, const N: usize>(x: Simd<T, N>, y: Simd<T, N>) Simd<T, N> {
    let hi = x.abs().max_num(y.abs());
    let lo = x.abs().min_num(y.abs());
    let (e, far) = hypot_e(hi);
    let r = if far {
        scale(hypot_dw(scale(hi, -e), scale(lo, -e)), e)
    } else {
        hypot_dw(hi, lo)
    };
    return hypot_finish(x, y, r);
}

// sqrt(hi^2 + lo^2) for hi >= lo: the sum as a double word rounded once, then its root (0.25 ULP from
// the sum, 0.5 from the root).
const fn hypot_dw<T: Lane, const N: usize>(hi: Simd<T, N>, lo: Simd<T, N>) Simd<T, N> {
    let (h2, h2l) = two_prod(hi, hi);
    let (l2, l2l) = two_prod(lo, lo);
    let (sh, sl) = fast_two_sum(h2, l2);
    return (sh + (sl + (h2l + l2l))).sqrt();
}

/// The sine.
pub fn sin<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let (s, _) = sincos(x);
    return s;
}

/// The cosine.
pub fn cos<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let (_, c) = sincos(x);
    return c;
}

/// `(sin x, cos x)`.
pub fn sincos<T: Lane, const N: usize>(x: Simd<T, N>) (Simd<T, N>, Simd<T, N>) {
    let (q, rh, rl) = rem_pio2(x);
    let odd = q.equal(sp(1.0)) | q.equal(sp(3.0));
    let s0 = sin_core(rh, rl);
    let c0 = cos_core(rh, rl);
    let s1 = choose(odd, c0, s0);
    let c1 = choose(odd, s0, c0);
    let s = choose(q.greater_equal(sp(2.0)), -s1, s1);
    let c = choose(q.equal(sp(1.0)) | q.equal(sp(2.0)), -c1, c1);
    // A NaN or infinite x reduces to a NaN: so are both results.
    return (choose(x.equal(sp(0.0)), x, s), c);
}

/// The tangent.
pub fn tan<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let (q, rh, rl) = rem_pio2(x);
    // t = tan(r/2) as a double word; tan r = 2t / (1 - t^2), -1/tan r = -(1 - t^2) / (2t).
    let uh = rh * T::c(0.5);
    let ul = rl * T::c(0.5);
    let z = uh * uh;
    let (th, tl) = fast_two_sum(uh, (z * uh).fma(T::poly::<{Poly::TanP}>(z), ul.fma(z, ul))); // tan' = 1 + tan^2
    let (t2h, t20) = two_prod(th, th);
    let t2l = (th + th).fma(tl, t20);
    let (dh, d0) = fast_two_sum(sp(1.0), -t2h);
    let dl = d0 - t2l;
    let odd = q.equal(sp(1.0)) | q.equal(sp(3.0));
    let (vh, vl) = dw_div(
        choose(odd, -dh, th + th),
        choose(odd, -dl, tl + tl),
        choose(odd, th + th, dh),
        choose(odd, tl + tl, dl),
    );
    return choose(x.abs().less_than(Simd::splat(T::kc().tiny)), x, vh + vl);
}

/// The arcsine.
pub fn asin<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    let small = a.less_equal(sp(0.5));
    // Small: asin a = a + a z P(z), z = a^2. Large: pi/2 - 2 asin(s), s = sqrt(z), z = (1 - a)/2.
    let z = choose(small, a * a, (sp::<T, N>(1.0) - a) * T::c(0.5));
    let (sh, sl) = dw_sqrt(z, sp(0.0));
    let s = choose(small, a, sh);
    let t = s * z * T::poly::<{Poly::AsinP}>(z);
    let (h, l) = fast_two_sum(Simd::splat(kc.pio2_hi), -(sh + sh));
    let big = h + (l + (kc.pio2_lo - (sl + sl) - (t + t)));
    let r = choose(small, a + t, big);
    return choose(x.equal(sp(0.0)), x, choose(a.greater_than(sp(1.0)) | x.is_nan(), nan(), r.copysign(x)));
}

/// The arccosine.
pub fn acos<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    let small = a.less_equal(sp(0.5));
    let z = choose(small, a * a, (sp::<T, N>(1.0) - a) * T::c(0.5));
    let (sh, sl) = dw_sqrt(z, sp(0.0));
    let s = choose(small, x, sh);
    let t = s * z * T::poly::<{Poly::AsinP}>(z);
    // Small: pi/2 - (x + t). x > 1/2: 2 (s + t). x < -1/2: pi - 2 (s + t).
    let (h1, l1) = two_sum(Simd::splat(kc.pio2_hi), -x);
    let rs = h1 + (l1 + (kc.pio2_lo - t));
    let (h2, l2) = fast_two_sum(sh + sh, t + t);
    let rp = h2 + (l2 + (sl + sl));
    let (h3, l3) = fast_two_sum(Simd::<T, N>::splat(kc.pi_hi), -(sh + sh));
    let rn = h3 + (l3 + (kc.pi_lo - (sl + sl) - (t + t)));
    let r = choose(small, rs, choose(x.greater_than(sp(0.0)), rp, rn));
    return choose(a.greater_than(sp(1.0)) | x.is_nan(), nan(), r);
}

/// The arctangent.
pub fn atan<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let a = x.abs();
    let ai = a.equal(inf());
    let (h, l) = atan_dw(choose(ai, sp(1.0), a), choose(ai, sp(0.0), sp(1.0))); // atan(1/0) = pi/2
    return choose(x.is_nan(), x, choose(x.equal(sp(0.0)), x, (h + l).copysign(x)));
}

// atan(n / d) as a double word, for n >= 0, d > 0 (n / d may be infinite).
fn atan_dw<T: Lane, const N: usize>(n: Simd<T, N>, d: Simd<T, N>) (Simd<T, N>, Simd<T, N>) {
    let kc = T::kc();
    // t = n/d; t > tan(3pi/8): pi/2 + atan(-d/n); t > tan(pi/8): pi/4 + atan((n - d)/(n + d)).
    let far = n.greater_than(d * kc.tan_3pio8);
    let mid = !far & n.greater_than(d * kc.tan_pio8);
    let (nh, nl) = two_sum(n, -d);
    let (dh, dl) = two_sum(n, d);
    let (qh, ql) = dw_div(
        choose(far, -d, choose(mid, nh, n)),
        choose(mid, nl, sp(0.0)),
        choose(far, n, choose(mid, dh, d)),
        choose(mid, dl, sp(0.0)),
    );
    let z = qh * qh;
    let t = (z * qh).fma(T::poly::<{Poly::AtanP}>(z), ql);
    let m: Simd<T, N> = choose(far, sp(1.0), choose(mid, sp(0.5), sp(0.0))); // pi/2, pi/4 or 0
    let (h, l) = two_sum(m * kc.pio2_hi, qh);
    return (h, l + (m * kc.pio2_lo + t));
}

/// The angle of (x, y) from the positive x axis, in [-pi, pi] (Annex F signed zeros and infinities).
pub fn atan2<T: Lane, const N: usize>(y: Simd<T, N>, x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let (n, d, swap) = atan2_nd(y, x);
    let sn = choose(swap, d, n);
    let sd = choose(swap, n, d);
    // A lane whose n + d could overflow, or whose double words could lose bits to subnormals, scales
    // both by its d's 2^-e; the others keep e = 0, so a lane's result does not depend on its
    // neighbors. A quotient below `tiny` is its own arctangent: IEEE division rounds it once.
    let far = sd.greater_than(Simd::splat(kc.hyp_hi)) | sd.less_than(Simd::splat(kc.hyp_lo));
    let mut ns = sn;
    let mut ds = sd;
    if unlikely(far.any()) {
        let (_, e0) = frexp_any(choose(sd.equal(sp(0.0)), sp(1.0), sd));
        let e = choose(far, e0, sp(0.0));
        ns = scale(sn, -e);
        ds = scale(sd, -e);
    }
    let (ah, al) = atan_dw(ns, ds);
    let small = ns.less_than(ds * kc.tiny);
    let mut h0 = ah;
    let mut l0 = al;
    if unlikely(small.any()) {
        h0 = choose(small, sn / sd, ah);
        l0 = choose(small, sp(0.0), al);
    }
    let zero = n.equal(sp(0.0)); // atan2(+-0, +-0) and a finite y over an infinite x
    let rh0 = choose(zero, sp(0.0), h0);
    let rl0 = choose(zero, sp(0.0), l0);
    // Swapped: pi/2 - r. x < 0 (or -0): pi - r.
    let (h1, l1) = fast_two_sum(Simd::splat(kc.pio2_hi), -rh0);
    let rh1 = choose(swap, h1, rh0);
    let rl1 = choose(swap, l1 + (kc.pio2_lo - rl0), rl0);
    let (h2, l2) = fast_two_sum(Simd::<T, N>::splat(kc.pi_hi), -rh1);
    let neg = sp::<T, N>(1.0).copysign(x).less_than(sp(0.0));
    let r = choose(neg, h2 + (l2 + (kc.pi_lo - rl1)), rh1 + rl1);
    return choose(x.is_nan() | y.is_nan(), x + y, r.copysign(y));
}

/// The hyperbolic sine.
pub fn sinh<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    let small = a.less_equal(sp(0.5));
    // Up to 1/2: a + a z P(z), z = a^2. Past it (e^a - e^-a)/2 from the double words, or e^a / 2 past
    // hyp_big; each only when a lane needs it.
    let s = if small.any() {
        let z = a * a;
        (a * z).fma(T::poly::<{Poly::SinhP}>(z), a)
    } else {
        a
    };
    let b = if (!small).any() {
        hyp_sum(a, T::c(-1.0))
    } else {
        a
    };
    let r = choose(small, s, b);
    return choose(
        a.less_than(Simd::splat(kc.tiny)) | x.is_nan(),
        x,
        choose(a.greater_than(Simd::splat(kc.cosh_max)), inf(), r).copysign(x),
    );
}

/// The hyperbolic cosine.
pub fn cosh<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    return choose(x.is_nan(), x, choose(a.greater_than(Simd::splat(kc.cosh_max)), inf(), hyp_sum(a, T::c(1.0))));
}

// (e^a + sg e^-a)/2 for a >= 0 (sg +-1): e^a = eh + el as a double word, e^-a = 1/eh (1 - el/eh) to
// half an ULP of itself (at most half of e^a + sg e^-a from a = 1/2: a quarter ULP of the result),
// the sum rounded once; past hyp_big, e^a / 2 (to overflow at cosh_max).
fn hyp_sum<T: Lane, const N: usize>(a: Simd<T, N>, sg: T) Simd<T, N> {
    let kc = T::kc();
    let big = a.greater_than(Simd::splat(kc.hyp_big));
    let (h, l, k) = T::expk(a, sp(0.0));
    // 2^k is normal below hyp_big.
    let p = T::pow2i(choose(big, sp(0.0), k));
    let (eh, el) = fast_two_sum(h * p, l * p);
    let q = sp::<T, N>(1.0) / eh;
    let (s, e) = two_sum(eh, (-q * el).fma(q, q) * sg);
    return choose(big, scale(h + l, k - T::c(1.0)), (s + (e + el)) * T::c(0.5));
}

/// The hyperbolic tangent.
pub fn tanh<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    let small = a.less_equal(sp(0.55));
    // Up to 0.55: a + a z P(z), z = a^2. Past it 1 - 2/(e^2a + 1), the quotient as a double word; 1 past
    // tanh_one. Each only when a lane needs it.
    let s = if small.any() {
        let z = a * a;
        (a * z).fma(T::poly::<{Poly::TanhP}>(z), a)
    } else {
        a
    };
    let b = if (!small).any() {
        let (h, l, k) = T::expk(choose(a.greater_than(Simd::splat(kc.tanh_one)), sp(0.0), a + a), sp(0.0));
        let p = T::pow2i(k);
        let (dh0, d0) = two_sum(h * p, sp(1.0));
        let (dh, dl) = fast_two_sum(dh0, d0 + l * p);
        let (qh, ql) = dw_div(sp(2.0), sp(0.0), dh, dl);
        let (oh, ol) = fast_two_sum(sp(1.0), -qh);
        oh + (ol - ql)
    } else {
        a
    };
    let r = choose(small, s, choose(a.greater_than(Simd::splat(kc.tanh_one)), sp(1.0), b));
    return choose(a.less_than(Simd::splat(kc.tiny)) | x.is_nan(), x, r.copysign(x));
}

/// The inverse hyperbolic sine.
pub fn asinh<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    let big = a.greater_than(Simd::splat(kc.big));
    // log(|x| + sqrt(x^2 + 1)) of a double word; past `big`, log|x| + ln2.
    let ab = choose(big, sp(1.0), a);
    let (sh, s0) = two_prod(ab, ab);
    let (vh, v0) = two_sum(sh, sp(1.0));
    let (rh, rl) = dw_sqrt(vh, v0 + s0);
    let (wh, w0) = two_sum(ab, rh);
    let r = log_big(big, a, wh, w0 + rl);
    return choose(a.less_than(Simd::splat(kc.tiny)) | x.is_nan() | a.equal(inf()), x, r.copysign(x));
}

/// The inverse hyperbolic cosine.
pub fn acosh<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let big = x.greater_than(Simd::splat(kc.big));
    let xb = choose(big, sp(1.0), x);
    let (sh, s0) = two_prod(xb, xb);
    let (vh, v0) = two_sum(sh, sp(-1.0));
    let (rh, rl) = dw_sqrt(vh, v0 + s0);
    let (wh, w0) = two_sum(xb, rh);
    let out = choose(x.equal(inf()), x, log_big(big, x, wh, w0 + rl));
    return choose(x.greater_equal(sp(1.0)), out, nan());
}

// log(h + l) for a positive double word, or log(2a) in the `big` lanes.
fn log_big<T: Lane, const N: usize>(big: Mask<N>, a: Simd<T, N>, h: Simd<T, N>, l: Simd<T, N>) Simd<T, N> {
    return log_hl(choose(big, a, h), choose(big, sp(0.0), l), choose(big, sp(1.0), sp(0.0)));
}

/// The inverse hyperbolic tangent.
pub fn atanh<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    let (nh, nl) = two_sum(sp(1.0), a);
    let (dh, dl) = two_sum(sp(1.0), -a);
    let (qh, ql) = dw_div(nh, nl, dh, dl);
    let r = log_hl(qh, ql, sp(0.0)) * T::c(0.5);
    let out = choose(a.equal(sp(1.0)), inf(), choose(a.greater_than(sp(1.0)), nan(), r));
    return choose(a.less_than(Simd::splat(kc.tiny)) | x.is_nan(), x, out.copysign(x));
}

/// The error function.
pub fn erf<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let a = x.abs();
    // Below 1/2 the series, else 1 - erfc |x| (erfc below 0.48); each only when a lane needs it.
    let lo = a.less_than(sp(0.5)) | x.is_nan();
    let s = if lo.any() {
        let (sh, sl) = erf_small(x);
        sh + sl
    } else {
        x
    };
    let b = if (!lo).any() {
        let (h, l, k) = erfc_dw(a);
        let (oh, ol) = fast_two_sum(sp(1.0), -scale(h, k));
        oh + (ol - scale(l, k))
    } else {
        x
    };
    return choose(lo, s, b).copysign(x);
}

/// The complementary error function, 1 - erf x, accurate where erf x is near 1.
pub fn erfc<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let a = x.abs();
    let lo = a.less_than(sp(0.5));
    let s = if lo.any() {
        let (sh, sl) = erf_small(x);
        let (oh, ol) = fast_two_sum(sp(1.0), -sh);
        oh + (ol - sl)
    } else {
        x
    };
    // Below -1/2: 2 - erfc |x|.
    let b = if (!lo).any() {
        let (h, l, k) = erfc_dw(a);
        let (nh, nl) = fast_two_sum(sp(2.0), -scale(h, k));
        choose(x.less_than(sp(0.0)), nh + (nl - scale(l, k)), scale(h + l, k))
    } else {
        x
    };
    return choose(lo, s, choose(x.is_nan(), x, b));
}

/// The precise class's methods: `v.exp()` is `exp(v)`.
extend<T: Lane, const N: usize> Simd<T, N> {
    pub fn exp(self: Self) Self {
        return exp(self);
    }

    pub fn exp2(self: Self) Self {
        return exp2(self);
    }

    pub fn exp10(self: Self) Self {
        return exp10(self);
    }

    pub fn expm1(self: Self) Self {
        return expm1(self);
    }

    pub fn log(self: Self) Self {
        return log(self);
    }

    pub fn log2(self: Self) Self {
        return log2(self);
    }

    pub fn log10(self: Self) Self {
        return log10(self);
    }

    pub fn log1p(self: Self) Self {
        return log1p(self);
    }

    pub fn pow(self: Self, y: Self) Self {
        return pow(self, y);
    }

    pub fn powi(self: Self, n: Simd<i32, N>) Self {
        return powi(self, n);
    }

    pub fn cbrt(self: Self) Self {
        return cbrt(self);
    }

    pub fn hypot(self: Self, y: Self) Self {
        return hypot(self, y);
    }

    pub fn sin(self: Self) Self {
        return sin(self);
    }

    pub fn cos(self: Self) Self {
        return cos(self);
    }

    pub fn tan(self: Self) Self {
        return tan(self);
    }

    pub fn sincos(self: Self) (Self, Self) {
        let (s, c) = sincos(self);
        return (s, c);
    }

    pub fn asin(self: Self) Self {
        return asin(self);
    }

    pub fn acos(self: Self) Self {
        return acos(self);
    }

    pub fn atan(self: Self) Self {
        return atan(self);
    }

    pub fn atan2(self: Self, x: Self) Self {
        return atan2(self, x);
    }

    pub fn sinh(self: Self) Self {
        return sinh(self);
    }

    pub fn cosh(self: Self) Self {
        return cosh(self);
    }

    pub fn tanh(self: Self) Self {
        return tanh(self);
    }

    pub fn asinh(self: Self) Self {
        return asinh(self);
    }

    pub fn acosh(self: Self) Self {
        return acosh(self);
    }

    pub fn atanh(self: Self) Self {
        return atanh(self);
    }

    pub fn erf(self: Self) Self {
        return erf(self);
    }

    pub fn erfc(self: Self) Self {
        return erfc(self);
    }
}
