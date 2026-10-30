// Measured by `tools/simd_math` (`simd-math-check --write`; f32: every input, f64: 1000000000 inputs per
// function and the special values, 0 results over the bound): the largest error per lane type,
// relative.
//   exp         f32 2^-16.9 at -0x1.53a45e0000000p6
//               f64 2^-27.7 at 0x1.592ff2a821035p6
//   exp2        f32 2^-16.9 at -0x1.fffbca0000000p-2
//               f64 2^-27.7 at -0x1.ffffffffe2a89p-2
//   exp10       f32 2^-16.3 at -0x1.2e3be00000000p5
//               f64 2^-27.7 at 0x1.3441384a36ba0p-3
//   expm1       f32 2^-15.2 at 0x1.62e5240000000p-2
//               f64 2^-25.6 at -0x1.4f4b59d0c1844p-3
//   log         f32 2^-21.6 at 0x1.22227e0000000p0
//               f64 2^-30.2 at 0x1.c81c037ff4b9dp-1
//   log2        f32 2^-21.4 at 0x1.23d35e0000000p0
//               f64 2^-30.2 at 0x1.1f5ee9433236dp0
//   log10       f32 2^-21.3 at 0x1.69bf0e0000000p-1
//               f64 2^-30.2 at 0x1.1f5ee9433236dp0
//   log1p       f32 2^-21.4 at 0x1.a833fc0000000p-2
//               f64 2^-30.2 at 0x1.f5dc14579b40ep-4
//   cbrt        f32 2^-20.9 at 0x1.344f320000000p-126
//               f64 2^-33.4 at 0x1.9ed2eabbb99a6p-810
//   sin         f32 2^-12.6 at 0x1.fe9b660000000p12
//               f64 2^-27 at 0x1.00002a83946a3p19
//   cos         f32 2^-12.6 at -0x1.fe82440000000p12
//               f64 2^-27 at -0x1.2e5cc061c2667p-4
//   tan         f32 2^-13.9 at 0x1.2159dc0000000p10
//               f64 2^-25.3 at 0x1.c26c56dbc5de2p20
//   sincos.sin  f32 2^-12.6 at 0x1.fe9b660000000p12
//               f64 2^-27 at 0x1.00002a83946a3p19
//   sincos.cos  f32 2^-12.6 at -0x1.fe82440000000p12
//               f64 2^-27 at -0x1.2e5cc061c2667p-4
//   asin        f32 2^-13.7 at 0x1.00002e0000000p-1
//               f64 2^-26.6 at -0x1.0000000000013p-1
//   acos        f32 2^-14.6 at 0x1.cb43660000000p-1
//               f64 2^-27.5 at 0x1.f28cd68f09424p-1
//   atan        f32 2^-15.4 at 0x1.a827ea0000000p-2
//               f64 2^-25.5 at -0x1.a827a8d90022cp-2
//   sinh        f32 2^-15.3 at 0x1.62e5240000000p-2
//               f64 2^-25.9 at -0x1.4bc876ac0f0d2p-3
//   cosh        f32 2^-16.9 at 0x1.7912b20000000p2
//               f64 2^-27.7 at 0x1.592ff2a821035p6
//   tanh        f32 2^-15.4 at 0x1.62e5600000000p-3
//               f64 2^-25.9 at -0x1.4a5ed46478df7p-4
//   asinh       f32 2^-21.3 at 0x1.6a47a20000000p-2
//               f64 2^-30.2 at -0x1.da71fd3c5069bp-4
//   acosh       f32 2^-21.3 at 0x1.0f8b180000000p0
//               f64 2^-30.2 at 0x1.01b66544cd67bp0
//   atanh       f32 2^-21.2 at 0x1.5fcdec0000000p-3
//               f64 2^-30.2 at 0x1.d8f3e5740b658p-5
//   pow         f32 2^-15.8 at -0x1.7803780000000p-2, -0x1.4000000000000p6
//               f64 2^-27.7 at 0x1.5f87bf0ff935bp-672, -0x1.7e2a39c676e58p0
//   powi        f32 2^-15.8 at -0x1.6246e40000000p1, -0x1.4000000000000p6
//               f64 2^-27.7 at 0x1.31616a974dd43p7, 0x1.c000000000000p6
//   atan2       f32 2^-15.4 at -0x1.6e386a0000000p123, 0x1.ba0fac0000000p124
//               f64 2^-25.5 at 0x1.de6889ece3b41p680, 0x1.20beb2c071e5dp682
//   hypot       f32 2^-23 at 0x1.ca24ea0000000p-44, 0x1.0156c80000000p-35
//               f64 2^-52 at 0x1.0af185027cd54p-302, 0x1.04372ee9b96cep-293
//
// Vector elementary functions, the `fast` class: a relative error of at most 2^-11 (f32 lanes) and
// 2^-22 (f64 lanes) over each function's documented range, NaN in gives NaN out, infinities handled,
// and the same bits on every target and at compile time, a NaN's sign and payload aside. Subnormal
// results flush to 0 and subnormal arguments count as 0 where a function says so; no erf (the class of
// that is `precise`) or erfc (`balanced`).
//
// Reductions and approximations (low-degree minimax polynomials, plain arithmetic):
//   exp, exp2, exp10, expm1: x = k ln2 + r (one fma), e^r = 1 + r + r^2 P(r), times 2^k by an add
//         to the exponent field; a result below 2^emin is 0, one that reaches 2^(emax + 1) inf.
//   log, log2, log10, log1p: x = (1 + f) 2^e, log(1 + f) = 2s + s^3 P(s^2), s = f / (2 + f); a
//         subnormal x counts as 0 (log gives -inf).
//   pow, powi: e^(y log x), log x from the balanced kernel (its error times |y log x| stays in bound).
//   cbrt: the polynomial start and one Newton step.
//   hypot: sqrt(fma(x, x, y^2)) unscaled: |x| or |y| past 2^(emax/2) overflows, below 2^(emin/2) the
//         square flushes.
//   atan2: a quotient below 2^emin rounds as a subnormal (its relative error unbounded).
//   sin, cos, sincos: x = q pi + r (cos: x = (2q + 1) pi/2 + r) by four fmas, one polynomial for
//         sin r on |r| <= pi/2; tan: x = q pi/2 + r, r + r^3 P(r^2) or its negative reciprocal. Range:
//         |x| <= 2^13 (f32) or 2^24 (f64); past it the result is unspecified.
//   asin, acos, atan, atan2: the balanced reductions with lower-degree polynomials.
//   sinh, cosh, tanh, asinh, acosh, atanh: the balanced formulas over the fast exp and log1p.
import std::simd::math::lane as *;
import std::simd::math::balanced as mb;

// `(q, k)`: e^x = (1 + q) 2^k.
fn exp_q<T: Lane, const N: usize>(x: Simd<T, N>) (Simd<T, N>, Simd<T, N>) {
    let kc = T::kc();
    let k = (x * kc.log2e_hi).round_even();
    let r = (-k).fma(Simd::splat(kc.ln2_hi), x);
    return ((r * r).fma(T::poly::<{Poly::ExpF}>(r), r), k);
}

// y 2^k for integer-valued k: past emax in two factors (so that it overflows), below emin 0.
fn ldexp<T: Lane, const N: usize>(y: Simd<T, N>, k: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let emax = Simd::<T, N>::splat(kc.emax);
    let over = at_most(at_least(k - emax, sp(0.0)), emax);
    let v = y * T::pow2i(over) * T::pow2i(at_least(at_most(k, emax), Simd::splat(kc.emin)));
    return choose(k.less_than(Simd::splat(kc.emin)), sp(0.0), v);
}

// y 2^(k - j) by the exponent add, for x = k c + r (r from one fma, exact): inf from x = (emax + 1 + j) c
// on, where k - j = emax + 1 and r >= 0, so y >= 1 and the add would reach the exponent's top.
fn exp_add<T: Lane, const N: usize>(x: Simd<T, N>, c: T, j: f64, y: Simd<T, N>, k: Simd<T, N>) Simd<T, N> {
    let top = (Simd::<T, N>::splat(T::kc().emax) + T::c(1.0 + j)) * c;
    return choose(x.greater_equal(top), inf(), T::add_exp(y, k - T::c(j)));
}

// e^r 2^k for x = k c + r: 0 for x below `lo` (the result subnormal).
fn exp_fin<T: Lane, const N: usize>(x: Simd<T, N>, lo: T, c: T, r: Simd<T, N>, k: Simd<T, N>) Simd<T, N> {
    let y = exp_add(x, c, 0.0, sp::<T, N>(1.0) + (r * r).fma(T::poly::<{Poly::ExpF}>(r), r), k);
    return choose(x.less_than(Simd::splat(lo)), sp(0.0), y);
}

/// e^x (a subnormal result flushes to 0).
pub fn exp<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let k = (x * kc.log2e_hi).round_even();
    return exp_fin(x, kc.exp_norm, kc.ln2_hi, (-k).fma(Simd::splat(kc.ln2_hi), x), k);
}

/// 2^x (a subnormal result flushes to 0).
pub fn exp2<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let k = x.round_even();
    return exp_fin(x, kc.emin, T::c(1.0), (x - k) * kc.ln2_hi, k);
}

/// 10^x (a subnormal result flushes to 0).
pub fn exp10<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let k = (x * kc.log2_10).round_even();
    return exp_fin(x, kc.exp10_norm, kc.lg2_hi, (-k).fma(Simd::splat(kc.lg2_hi), x) * kc.ln10_hi, k);
}

/// e^x - 1, relatively accurate near 0.
pub fn expm1<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let (q, k) = exp_q(x);
    // 2^k q + (2^k - 1) up to k = sub_bits, then 2^k (1 + q).
    let t = T::pow2i(at_most(k, Simd::splat(kc.sub_bits)));
    let y = choose(
        k.greater_than(Simd::splat(kc.sub_bits)),
        exp_add(x, kc.ln2_hi, 0.0, sp::<T, N>(1.0) + q, k),
        t.fma(q, t - T::c(1.0)),
    );
    return choose(x.equal(sp(0.0)), x, choose(x.less_than(Simd::splat(kc.expm1_min)), sp(-1.0), y));
}

// `(e, v)`: x = (1 + f) 2^e and v = log(1 + f), for positive normal x.
fn log_ev<T: Lane, const N: usize>(x: Simd<T, N>) (Simd<T, N>, Simd<T, N>) {
    let (m0, e0) = T::frexp(x);
    let (f, e) = log_split_m(m0, e0);
    return (e, log1p_s(f));
}

// log(1 + f) for 1 + f in [sqrt(1/2), sqrt(2)]: 2s + s z P(z), s = f / (2 + f), z = s^2.
fn log1p_s<T: Lane, const N: usize>(f: Simd<T, N>) Simd<T, N> {
    let s = f / (sp::<T, N>(2.0) + f);
    let z = s * s;
    return (s * z).fma(T::poly::<{Poly::LogF}>(z), s + s);
}

// The results of a logarithm of x outside the positive normals: -inf at 0 and the subnormals, NaN
// below 0 and for NaN, inf at inf.
fn log_flush<T: Lane, const N: usize>(x: Simd<T, N>, y: Simd<T, N>) Simd<T, N> {
    let r = choose(x.equal(inf()), x, choose(x.less_than(Simd::splat(T::kc().min_normal)), -inf::<T, N>(), y));
    return choose(x.greater_equal(sp(0.0)), r, nan());
}

/// The natural logarithm (a subnormal x counts as 0).
pub fn log<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let (e, v) = log_ev(x);
    return log_flush(x, e.fma(Simd::splat(T::kc().ln2_hi), v));
}

/// The base-2 logarithm (a subnormal x counts as 0).
pub fn log2<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let (e, v) = log_ev(x);
    return log_flush(x, v.fma(Simd::splat(T::kc().log2e_hi), e));
}

/// The base-10 logarithm (a subnormal x counts as 0).
pub fn log10<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let (e, v) = log_ev(x);
    return log_flush(x, e.fma(Simd::splat(kc.lg2_hi), v * kc.log10e_hi));
}

// log(1 + x) for 1 + x in [0, inf]: u = 1 + x; at e = 0 log(1 + x) itself, else log u (1 + x - u is
// below 2^-p of the result there).
fn log1p_v<T: Lane, const N: usize>(x: Simd<T, N>) (Simd<T, N>, Simd<T, N>) {
    let u = sp::<T, N>(1.0) + x;
    let (e, v) = log_ev(u);
    let v0 = log1p_s(x);
    return (choose(e.equal(sp(0.0)), v0, e.fma(Simd::splat(T::kc().ln2_hi), v)), u);
}

/// log(1 + x), relatively accurate near 0.
pub fn log1p<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let (y, u) = log1p_v(x);
    let r = choose(u.equal(inf()), u, choose(u.equal(sp(0.0)), -inf::<T, N>(), y));
    return choose(x.equal(sp(0.0)) | x.is_nan(), x, choose(u.greater_equal(sp(0.0)), r, nan()));
}

/// x^y (Annex F special cases as the other classes).
pub fn pow<T: Lane, const N: usize>(x: Simd<T, N>, y: Simd<T, N>) Simd<T, N> {
    let (yi, yo) = pow_parity(y);
    return pow_f(x, y, yi, yo);
}

/// x^n.
pub fn powi<T: Lane, const N: usize>(x: Simd<T, N>, n: Simd<i32, N>) Simd<T, N> {
    let (y, _) = T::of_i32(n); // y = n rounded, as a cast; without f64's conversion lane loop on AVX2
    return pow_f(x, y, Mask::<N>::splat(true), (n & 1).equal(Simd::splat(1)));
}

fn pow_f<T: Lane, const N: usize>(x: Simd<T, N>, y: Simd<T, N>, yint: Mask<N>, yodd: Mask<N>) Simd<T, N> {
    let z = y * mb::log(x.abs());
    let (q, k) = exp_q(z);
    return pow_finish(x, y, yint, yodd, z, ldexp(sp::<T, N>(1.0) + q, k));
}

/// The cube root.
pub fn cbrt<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let (c, y, q) = cbrt_start::<T, {Poly::CbrtP}, N>(x.abs());
    return cbrt_finish(x, y - (y * y * y - c) / (y * y * T::c(3.0)), q);
}

/// sqrt(x^2 + y^2), unscaled (see the header); an infinite argument gives +inf, NaN included.
pub fn hypot<T: Lane, const N: usize>(x: Simd<T, N>, y: Simd<T, N>) Simd<T, N> {
    return hypot_finish(x, y, x.fma(x, y * y).sqrt());
}

// sin r for |r| <= pi/2.
fn sin_r<T: Lane, const N: usize>(r: Simd<T, N>) Simd<T, N> {
    let z = r * r;
    return (r * z).fma(T::poly::<{Poly::SinF}>(z), r);
}

// -v for an odd q, v for an even one.
fn odd_neg<T: Lane, const N: usize>(q: Simd<T, N>, v: Simd<T, N>) Simd<T, N> {
    return choose((q * T::c(0.5)).floor().not_equal(q * T::c(0.5)), -v, v);
}

/// The sine, for |x| up to 2^13 (f32) or 2^24 (f64).
pub fn sin<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let q = (x * T::kc().two_over_pi * T::c(0.5)).round_even();
    return choose(x.equal(sp(0.0)), x, odd_neg(q, sin_r(sub_pio2(x, q + q))));
}

/// The cosine, for |x| up to 2^13 (f32) or 2^24 (f64).
pub fn cos<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    // x = (2q + 1) pi/2 + r: cos x = (-1)^(q + 1) sin r.
    let q = (x * T::kc().two_over_pi * T::c(0.5) - T::c(0.5)).round_even();
    return odd_neg(q + T::c(1.0), sin_r(sub_pio2(x, q.fma(sp(2.0), sp(1.0)))));
}

/// `(sin x, cos x)`, for |x| up to 2^13 (f32) or 2^24 (f64).
pub fn sincos<T: Lane, const N: usize>(x: Simd<T, N>) (Simd<T, N>, Simd<T, N>) {
    return (sin(x), cos(x));
}

/// The tangent, for |x| up to 2^13 (f32) or 2^24 (f64).
pub fn tan<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let k = (x * T::kc().two_over_pi).round_even();
    let r = sub_pio2(x, k);
    let z = r * r;
    let t = (r * z).fma(T::poly::<{Poly::TanF}>(z), r);
    return choose(x.equal(sp(0.0)), x, choose((k * T::c(0.5)).floor().not_equal(k * T::c(0.5)), T::c(-1.0) / t, t));
}

/// The arcsine.
pub fn asin<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    let small = a.less_equal(sp(0.5));
    let z = choose(small, a * a, (sp::<T, N>(1.0) - a) * T::c(0.5));
    let s = choose(small, a, z.sqrt());
    let t = (s * z).fma(T::poly::<{Poly::AsinF}>(z), s);
    let r = choose(small, t, Simd::<T, N>::splat(kc.pio2_hi) - (t + t));
    return choose(a.greater_than(sp(1.0)), nan(), choose(x.is_nan(), x, r.copysign(x)));
}

/// The arccosine.
pub fn acos<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    let small = a.less_equal(sp(0.5));
    let z = choose(small, a * a, (sp::<T, N>(1.0) - a) * T::c(0.5));
    let s = choose(small, x, z.sqrt());
    let t = (s * z).fma(T::poly::<{Poly::AsinF}>(z), s);
    let r = choose(
        small,
        Simd::<T, N>::splat(kc.pio2_hi) - t,
        choose(x.greater_than(sp(0.0)), t + t, Simd::<T, N>::splat(kc.pi_hi) - (t + t)),
    );
    return choose(a.greater_than(sp(1.0)), nan(), choose(x.is_nan(), x, r));
}

// atan(n / d) for 0 <= n <= d.
fn atan_q<T: Lane, const N: usize>(n: Simd<T, N>, d: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let t = n / d;
    let mid = t.greater_than(Simd::splat(kc.tan_pio8));
    let u = choose(mid, (t - T::c(1.0)) / (t + T::c(1.0)), t);
    let z = u * u;
    let m: Simd<T, N> = choose(mid, sp(0.5), sp(0.0)); // pi/4 or 0
    return m * kc.pio2_hi + (z * u).fma(T::poly::<{Poly::AtanF}>(z), u);
}

/// The arctangent.
pub fn atan<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let a = x.abs();
    let inv = a.greater_than(sp(1.0));
    let v = atan_q(choose(inv, sp(1.0), a), choose(inv, a, sp(1.0)));
    let r = choose(inv, Simd::<T, N>::splat(T::kc().pio2_hi) - v, v);
    return choose(x.is_nan() | x.equal(sp(0.0)), x, r.copysign(x));
}

/// The angle of (x, y) from the positive x axis, in [-pi, pi] (Annex F signed zeros and infinities).
pub fn atan2<T: Lane, const N: usize>(y: Simd<T, N>, x: Simd<T, N>) Simd<T, N> {
    let (n, d, swap) = atan2_nd(y, x);
    return atan2_finish(y, x, swap, choose(n.equal(sp(0.0)), sp(0.0), atan_q(choose(swap, d, n), choose(swap, n, d))));
}

// `(t, y, k)`: e^a - 1 = t and e^a = y 2^k; t holds for k up to sub_bits (past it t is below e^a - 1,
// above 2^sub_bits: sinh and tanh take e^a or 1 there).
fn expm1_k<T: Lane, const N: usize>(a: Simd<T, N>) (Simd<T, N>, Simd<T, N>, Simd<T, N>) {
    let kc = T::kc();
    let (q, k) = exp_q(a);
    let t = T::pow2i(at_most(k, Simd::splat(kc.sub_bits)));
    return (t.fma(q, t - T::c(1.0)), sp::<T, N>(1.0) + q, k);
}

/// The hyperbolic sine.
pub fn sinh<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    let (t, y, k) = expm1_k(a);
    let r = choose(
        a.greater_than(Simd::splat(kc.hyp_big)),
        exp_add(a, kc.ln2_hi, 1.0, y, k),
        (t + t / (t + T::c(1.0))) * T::c(0.5),
    );
    return choose(a.less_than(Simd::splat(kc.tiny)) | x.is_nan(), x, r.copysign(x));
}

/// The hyperbolic cosine.
pub fn cosh<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    let (q, k) = exp_q(a);
    let y = sp::<T, N>(1.0) + q;
    let big = a.greater_than(Simd::splat(kc.hyp_big));
    let ks = choose(big, sp(0.0), k);
    let r = choose(big, exp_add(a, kc.ln2_hi, 1.0, y, k), y * T::pow2i(ks - T::c(1.0)) + T::pow2i(-ks - T::c(1.0)) / y);
    return choose(x.is_nan(), x, r);
}

/// The hyperbolic tangent.
pub fn tanh<T: Lane, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    let kc = T::kc();
    let a = x.abs();
    let one = a.greater_than(Simd::splat(kc.tanh_one));
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
