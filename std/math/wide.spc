// The elementary functions of `Float<E, F>`: exp, exp2, ln, log2, pow, the trigonometric and hyperbolic
// functions and their inverses. Special values follow C (Annex F of C99).
//
// A format with at most f64's range and precision (f16, bf16, the 8-bit formats) is exact in f64: its
// functions compute there with the C library and round once. A wider format (f128, f256) computes in
// `Wf<W>`, a binary value with a significand of W = F + 66 bits, 65 past the format's: every operation
// truncates, the range reductions and the squarings of `exp` lose at most about 55 of the guard bits, and
// the result rounds once to the format. The result is within one ulp, and correctly rounded unless the exact
// value lies within about 2^-10 ulp of a rounding boundary.
//
// The constants are the bits of pi/4, ln 2 and 2/pi (`wide_consts.spc`, from tools/wide_math): they bound
// the formats. Every function needs F <= 4000; sin, cos and tan, whose argument reduction reads 2/pi to the
// largest exponent (Payne and Hanek), also need 2^(E-1) + 2F + 196 <= 268800 (f256 has E = 19).
import std::float as sf;
import std::math::wide_consts as wc;

// ---- Wf: the working values -------------------------------------------------------------------------

// (-1)^neg * m * 2^e, `m` with its top bit (W - 1) set, or zero (then `neg` is false and `e` 0).
struct Wf<const W: usize> {
    pub neg: bool,
    pub e: i64,
    pub m: UInt<W>,
}

fn wzero<const W: usize>() Wf<W> {
    return Wf::<W> { neg: false, e: 0, m: UInt::<W>::zero() };
}

// (-1)^neg * v * 2^e for any width of `v`, truncated to W bits.
fn wnorm<const W: usize, const N: usize>(neg: bool, e: i64, v: UInt<N>) Wf<W> {
    if v.is_zero() {
        return wzero::<W>();
    }
    let n = v.bit_length();
    if n > W {
        let top = v >> n - W;
        return Wf::<W> { neg: neg, e: e + (n - W) as i64, m: UInt::<W>::cast_unsigned(&top) };
    }
    return Wf::<W> { neg: neg, e: e - (W - n) as i64, m: UInt::<W>::cast_unsigned(&v) << W - n };
}

fn wfrom_u64<const W: usize>(v: u64) Wf<W> {
    return wnorm::<W, 64>(false, 0, UInt::<64>::from_u64(v));
}

fn wfrom_i64<const W: usize>(v: i64) Wf<W> {
    let mag = if v < 0 {
        0u64.wrapping_sub(v as u64);
    } else {
        v as u64;
    };
    let a = wfrom_u64::<W>(mag);
    return Wf::<W> { neg: v < 0 && !a.m.is_zero(), e: a.e, m: a.m };
}

fn wone<const W: usize>() Wf<W> {
    return wfrom_u64::<W>(1);
}

fn wneg<const W: usize>(a: Wf<W>) Wf<W> {
    return Wf::<W> { neg: !a.neg && !a.m.is_zero(), e: a.e, m: a.m };
}

fn wabs<const W: usize>(a: Wf<W>) Wf<W> {
    return Wf::<W> { neg: false, e: a.e, m: a.m };
}

// a * 2^k.
fn wscale<const W: usize>(a: Wf<W>, k: i64) Wf<W> {
    if a.m.is_zero() {
        return a;
    }
    return Wf::<W> { neg: a.neg, e: a.e + k, m: a.m };
}

// The order of |a| and |b|: -1, 0 or 1.
fn wcmp_abs<const W: usize>(a: Wf<W>, b: Wf<W>) i32 {
    if a.m.is_zero() || b.m.is_zero() {
        return if a.m.is_zero() && b.m.is_zero() {
            0;
        } else if a.m.is_zero() {
            -1;
        } else {
            1;
        };
    }
    if a.e != b.e {
        return if a.e < b.e {
            -1;
        } else {
            1;
        };
    }
    return a.m.cmp(&b.m);
}

// Whether |a| < 2^k.
fn wbelow<const W: usize>(a: Wf<W>, k: i64) bool {
    return a.m.is_zero() || a.e + W as i64 <= k;
}

fn wmul<const W: usize>(a: Wf<W>, b: Wf<W>) Wf<W> {
    if a.m.is_zero() || b.m.is_zero() {
        return wzero::<W>();
    }
    let mut hi = UInt::<W>::zero();
    let lo = a.m.widening_mul(&b.m, &mut hi);
    if hi.bit(W - 1) {
        return Wf::<W> { neg: a.neg != b.neg, e: a.e + b.e + W as i64, m: hi };
    }
    return Wf::<W> { neg: a.neg != b.neg, e: a.e + b.e + W as i64 - 1, m: hi << 1 | lo >> W - 1 };
}

// a + b, exact in 2W + 2 bits, then truncated.
fn wadd<const W: usize>(a: Wf<W>, b: Wf<W>) Wf<W> {
    if a.m.is_zero() {
        return b;
    }
    if b.m.is_zero() {
        return a;
    }
    let swap = wcmp_abs(a, b) < 0;
    let x = if swap {
        b;
    } else {
        a;
    };
    let y = if swap {
        a;
    } else {
        b;
    };
    let d = (x.e - y.e) as u64;
    let xs = UInt::<{2 * W + 2}>::cast_unsigned(&x.m) << W;
    let mut ys = UInt::<{2 * W + 2}>::zero();
    if d < 2 * W as u64 {
        ys = UInt::<{2 * W + 2}>::cast_unsigned(&y.m) << W >> d as usize;
    }
    let s = if x.neg == y.neg {
        xs + ys;
    } else {
        xs - ys;
    };
    return wnorm::<W, {2 * W + 2}>(x.neg, x.e - W as i64, s);
}

fn wsub<const W: usize>(a: Wf<W>, b: Wf<W>) Wf<W> {
    return wadd(a, wneg(b));
}

fn wdiv<const W: usize>(a: Wf<W>, b: Wf<W>) Wf<W> {
    if a.m.is_zero() {
        return wzero::<W>();
    }
    let n = UInt::<{2 * W + 2}>::cast_unsigned(&a.m) << W;
    let d = UInt::<{2 * W + 2}>::cast_unsigned(&b.m);
    return wnorm::<W, {2 * W + 2}>(a.neg != b.neg, a.e - b.e - W as i64, n / d);
}

// a / d for 0 < d < 2^32, limb by limb.
fn wdiv_small<const W: usize>(a: Wf<W>, d: u64) Wf<W> {
    if a.m.is_zero() {
        return a;
    }
    let n = UInt::<{W + 64}>::cast_unsigned(&a.m) << 64;
    let mut q = UInt::<{W + 64}>::zero();
    let mut rem: u64 = 0;
    let mut i = UInt::<{W + 64}>::limbs();
    while i > 0 {
        i -= 1;
        let l = n.limb(i);
        let h = rem << 32 | l >> 32;
        let qh = h / d;
        rem = h % d;
        let lw = rem << 32 | l & 0xFFFFFFFF;
        let ql = lw / d;
        rem = lw % d;
        q.set_limb(i, qh << 32 | ql);
    }
    return wnorm::<W, {W + 64}>(a.neg, a.e - 64, q);
}

fn wmul_small<const W: usize>(a: Wf<W>, k: u64) Wf<W> {
    return wmul(a, wfrom_u64::<W>(k));
}

// sqrt(a) for a >= 0: the integer square root of m * 2^s, s = W or W - 1 with e - s even.
fn wsqrt<const W: usize>(a: Wf<W>) Wf<W> {
    if a.m.is_zero() {
        return a;
    }
    let s: usize = if (a.e - W as i64) % 2 == 0 {
        W;
    } else {
        W - 1;
    };
    let mm = UInt::<{2 * W}>::cast_unsigned(&a.m) << s;
    // Newton's iteration from above: x0 >= sqrt(mm) decreases to floor(sqrt(mm)).
    let mut x = UInt::<{2 * W}>::one() << (mm.bit_length() + 1) / 2;
    for _ in 0..2 * W {
        let y = x + mm / x >> 1;
        if y >= x {
            break;
        }
        x = y;
    }
    return wnorm::<W, {2 * W}>(false, (a.e - s as i64) / 2, x);
}

// The integer nearest a (halves away from zero), for |a| < 2^62.
fn wround_i64<const W: usize>(a: Wf<W>) i64 {
    if a.m.is_zero() {
        return 0;
    }
    let mut v: u64 = 0;
    if a.e >= 0 {
        v = (a.m << a.e as usize).to_u64();
    } else if -a.e <= W as i64 {
        let sh = (-a.e) as usize;
        v = (a.m >> sh).to_u64() + a.m.bit(sh - 1) as u64;
    }
    return if a.neg {
        -(v as i64);
    } else {
        v as i64;
    };
}

// The value in [1/2, 1) of the leading bits of `t` (bits after the binary point, most significant first).
fn wconst<const W: usize>(t: []u64) Wf<W> {
    static_assert(W <= 64 * 64, "the functions of this format need more bits of pi and ln 2");
    let l = (W + 63) / 64;
    let mut acc = UInt::<{W + 64}>::zero();
    for i in 0..l {
        acc = acc << 64 | UInt::<{W + 64}>::from_u64(t[i]);
    }
    return wnorm::<W, {W + 64}>(false, -(64 * l as i64), acc);
}

fn wpi4<const W: usize>() Wf<W> {
    return wconst::<W>(wc::PI4_BITS);
}

fn wln2<const W: usize>() Wf<W> {
    return wconst::<W>(wc::LN2_BITS);
}

// Bits i0 .. i0 + N - 1 (bit i weighs 2^-i) of 2/pi as an integer.
fn two_over_pi_bits<const N: usize>(i0: u64) UInt<N> {
    let t = wc::TWO_OVER_PI_BITS;
    let l = (N + 63) / 64;
    let mut acc = UInt::<{N + 64}>::zero();
    for j in 0..l {
        let pos = i0 - 1 + 64 * j as u64;
        let q = (pos / 64) as usize;
        let s = pos % 64;
        let mut w = unsafe t[q] << s;
        if s != 0 {
            w = w | unsafe t[q + 1] >> 64 - s;
        }
        acc = acc << 64 | UInt::<{N + 64}>::from_u64(w);
    }
    let top = acc >> 64 * l - N;
    return UInt::<N>::cast_unsigned(&top);
}

// Whether a series term no longer reaches the sum's last bits.
fn wnegligible<const W: usize>(term: Wf<W>, sum: Wf<W>) bool {
    return term.m.is_zero() || !sum.m.is_zero() && term.e + W as i64 < sum.e - 1;
}

// ---- the functions on Wf ------------------------------------------------------------------------------

// e^x for |x| below about 2^31 ln 2: x = k ln 2 + r, e^r = (e^(r / 2^16))^(2^16), the inner one a Taylor
// series.
fn exp_w<const W: usize>(x: Wf<W>) Wf<W> {
    let ln2 = wln2::<W>();
    let k = wround_i64(wdiv(x, ln2));
    let r = wscale(wsub(x, wmul(wfrom_i64::<W>(k), ln2)), -16);
    let mut sum = wone::<W>();
    let mut term = wone::<W>();
    for n in 1..W as u64 + 8 {
        term = wdiv_small(wmul(term, r), n);
        if wnegligible(term, sum) {
            break;
        }
        sum = wadd(sum, term);
    }
    for _ in 0..16 {
        sum = wmul(sum, sum);
    }
    return wscale(sum, k);
}

// atanh(t) = t + t^3/3 + t^5/5 + .. for |t| <= 1/2.
fn atanh_series<const W: usize>(t: Wf<W>) Wf<W> {
    let t2 = wmul(t, t);
    let mut s = t;
    let mut p = t;
    for k in 1..W as u64 + 8 {
        p = wmul(p, t2);
        let term = wdiv_small(p, 2 * k + 1);
        if wnegligible(term, s) {
            break;
        }
        s = wadd(s, term);
    }
    return s;
}

// ln(1 + v) for v > -1/2: 2 atanh(v / (2 + v)).
fn ln1p_w<const W: usize>(v: Wf<W>) Wf<W> {
    let two = wfrom_u64::<W>(2);
    return wscale(atanh_series(wdiv(v, wadd(two, v))), 1);
}

// ln(x) for x > 0: x = u 2^j with u in [3/4, 3/2), ln x = j ln 2 + ln1p(u - 1); u - 1 is exact.
fn ln_w<const W: usize>(x: Wf<W>) Wf<W> {
    let mut j = x.e + W as i64 - 1;
    let mut u = Wf::<W> { neg: false, e: 1 - W as i64, m: x.m };
    let three_halves = wscale(wfrom_u64::<W>(3), -1);
    if wcmp_abs(u, three_halves) >= 0 {
        u = wscale(u, -1);
        j += 1;
    }
    let lu = ln1p_w(wsub(u, wone::<W>()));
    return wadd(wmul(wfrom_i64::<W>(j), wln2::<W>()), lu);
}

// sin(r) and cos(r) for |r| <= pi/4: Taylor series.
fn sin_w<const W: usize>(r: Wf<W>) Wf<W> {
    let r2 = wneg(wmul(r, r));
    let mut s = r;
    let mut term = r;
    for n in 1..W as u64 + 8 {
        term = wdiv_small(wmul(term, r2), 2 * n * (2 * n + 1));
        if wnegligible(term, s) {
            break;
        }
        s = wadd(s, term);
    }
    return s;
}

fn cos_w<const W: usize>(r: Wf<W>) Wf<W> {
    let r2 = wneg(wmul(r, r));
    let mut s = wone::<W>();
    let mut term = wone::<W>();
    for n in 1..W as u64 + 8 {
        term = wdiv_small(wmul(term, r2), (2 * n - 1) * 2 * n);
        if wnegligible(term, s) {
            break;
        }
        s = wadd(s, term);
    }
    return s;
}

// x = q pi/2 + r with |r| <= pi/4, for an exact x >= 0 (a format's value): q mod 4 and r. Past pi/4 the
// reduction multiplies x's significand by 3W bits of 2/pi from the bit where x's exponent puts the integer
// part's last two bits (Payne and Hanek): the earlier bits add multiples of 4, the later ones less than the
// truncation of r.
fn reduce_pio2<const W: usize>(x: Wf<W>) (u64, Wf<W>) {
    if wcmp_abs(x, wpi4::<W>()) <= 0 {
        return 0, x;
    }
    let tz = x.m.trailing_zeros();
    let low = x.m >> tz;
    let mi = UInt::<{3 * W}>::cast_unsigned(&low);
    let ex = x.e + tz as i64;
    let i0: i64 = if ex - 1 > 1 {
        ex - 1;
    } else {
        1;
    };
    let c = two_over_pi_bits::<{3 * W}>(i0 as u64);
    let mut hi = UInt::<{3 * W}>::zero();
    let lo = mi.widening_mul(&c, &mut hi);
    let p = UInt::<{6 * W}>::cast_unsigned(&hi) << 3 * W | UInt::<{6 * W}>::cast_unsigned(&lo);
    // x * 2/pi mod 4 is p * 2^-s.
    let s = (i0 + 3 * W as i64 - 1 - ex) as usize;
    let mut q = (p >> s).to_u64() & 3;
    let fr = p << 6 * W - s >> 6 * W - s;
    let mut f = wnorm::<W, {6 * W}>(false, -(s as i64), fr);
    if fr.bit(s - 1) {
        f = wsub(f, wone::<W>());
        q += 1;
    }
    return q & 3, wmul(f, wscale(wpi4::<W>(), 1));
}

// atan(x) for x >= 0: past 1, pi/2 - atan(1/x); then 8 halvings atan(t) = 2 atan(t / (1 + sqrt(1 + t^2)))
// bring t below tan(pi/1024), where the Taylor series gains 16 bits per term.
fn atan_w<const W: usize>(x: Wf<W>) Wf<W> {
    let one = wone::<W>();
    let inv = wcmp_abs(x, one) > 0;
    let mut t = if inv {
        wdiv(one, x);
    } else {
        x;
    };
    for _ in 0..8 {
        t = wdiv(t, wadd(one, wsqrt(wadd(one, wmul(t, t)))));
    }
    let t2 = wneg(wmul(t, t));
    let mut s = t;
    let mut p = t;
    for k in 1..W as u64 + 8 {
        p = wmul(p, t2);
        let term = wdiv_small(p, 2 * k + 1);
        if wnegligible(term, s) {
            break;
        }
        s = wadd(s, term);
    }
    s = wscale(s, 8);
    if inv {
        return wsub(wscale(wpi4::<W>(), 1), s);
    }
    return s;
}

// asin(y) for 0 <= y <= 1/sqrt 2: atan(y / sqrt(1 - y^2)).
fn asin_core<const W: usize>(y: Wf<W>) Wf<W> {
    let one = wone::<W>();
    return atan_w(wdiv(y, wsqrt(wsub(one, wmul(y, y)))));
}

// asin(x) for 0 <= x <= 1: below 1/2 the core; above, pi/2 - 2 asin(sqrt((1 - x) / 2)), 1 - x exact.
fn asin_w<const W: usize>(x: Wf<W>) Wf<W> {
    if wbelow(x, -1) {
        return asin_core(x);
    }
    let y = wsqrt(wscale(wsub(wone::<W>(), x), -1));
    return wsub(wscale(wpi4::<W>(), 1), wscale(asin_core(y), 1));
}

// acos(x) for -1 <= x <= 1.
fn acos_w<const W: usize>(x: Wf<W>) Wf<W> {
    let pi2 = wscale(wpi4::<W>(), 1);
    if wbelow(x, -1) {
        let a = asin_core(wabs(x));
        return if x.neg {
            wadd(pi2, a);
        } else {
            wsub(pi2, a);
        };
    }
    let one = wone::<W>();
    if !x.neg {
        return wscale(asin_core(wsqrt(wscale(wsub(one, x), -1))), 1);
    }
    let a = wscale(asin_core(wsqrt(wscale(wadd(one, x), -1))), 1);
    return wsub(wscale(wpi4::<W>(), 2), a);
}

// atan2(y, x) for finite, nonzero y and x.
fn atan2_w<const W: usize>(y: Wf<W>, x: Wf<W>) Wf<W> {
    let ay = wabs(y);
    let ax = wabs(x);
    let mut a = if wcmp_abs(ay, ax) <= 0 {
        atan_w(wdiv(ay, ax));
    } else {
        wsub(wscale(wpi4::<W>(), 1), atan_w(wdiv(ax, ay)));
    };
    if x.neg {
        a = wsub(wscale(wpi4::<W>(), 2), a);
    }
    return if y.neg {
        wneg(a);
    } else {
        a;
    };
}

// sinh(x) for x >= 0: below 1 the Taylor series, above (e^x - e^-x) / 2.
fn sinh_w<const W: usize>(x: Wf<W>) Wf<W> {
    if wbelow(x, 0) {
        let x2 = wmul(x, x);
        let mut s = x;
        let mut term = x;
        for n in 1..W as u64 + 8 {
            term = wdiv_small(wmul(term, x2), 2 * n * (2 * n + 1));
            if wnegligible(term, s) {
                break;
            }
            s = wadd(s, term);
        }
        return s;
    }
    let ex = exp_w(x);
    return wscale(wsub(ex, wdiv(wone::<W>(), ex)), -1);
}

fn cosh_w<const W: usize>(x: Wf<W>) Wf<W> {
    let ex = exp_w(x);
    return wscale(wadd(ex, wdiv(wone::<W>(), ex)), -1);
}

// tanh(x) for x >= 0: below 1 sinh / sqrt(1 + sinh^2), above 1 - 2 / (e^2x + 1).
fn tanh_w<const W: usize>(x: Wf<W>) Wf<W> {
    let one = wone::<W>();
    if wbelow(x, 0) {
        let s = sinh_w(x);
        return wdiv(s, wsqrt(wadd(one, wmul(s, s))));
    }
    let e2 = exp_w(wscale(x, 1));
    return wsub(one, wdiv(wfrom_u64::<W>(2), wadd(e2, one)));
}

// asinh(x) for x >= 0: below 2 ln1p(x + x^2 / (1 + sqrt(1 + x^2))), above ln(x + sqrt(x^2 + 1)).
fn asinh_w<const W: usize>(x: Wf<W>) Wf<W> {
    let one = wone::<W>();
    let x2 = wmul(x, x);
    let r = wsqrt(wadd(one, x2));
    if wbelow(x, 1) {
        return ln1p_w(wadd(x, wdiv(x2, wadd(one, r))));
    }
    return ln_w(wadd(x, r));
}

// acosh(x) for x >= 1: with d = x - 1 (exact), below 2 ln1p(d + sqrt(d (d + 2))), above
// ln(x + sqrt((x - 1)(x + 1))).
fn acosh_w<const W: usize>(x: Wf<W>) Wf<W> {
    let one = wone::<W>();
    let d = wsub(x, one);
    if wbelow(x, 1) {
        return ln1p_w(wadd(d, wsqrt(wmul(d, wadd(d, wfrom_u64::<W>(2))))));
    }
    return ln_w(wadd(x, wsqrt(wmul(d, wadd(x, one)))));
}

// atanh(x) for 0 <= x < 1: below 1/2 the series, above ln((1 + x) / (1 - x)) / 2, 1 - x exact.
fn atanh_w<const W: usize>(x: Wf<W>) Wf<W> {
    if wbelow(x, -1) {
        return atanh_series(x);
    }
    let one = wone::<W>();
    return wscale(ln_w(wdiv(wadd(one, x), wsub(one, x))), -1);
}

// ---- the formats -------------------------------------------------------------------------------------

/// Whether `Float<E, F, FAMILY>` is exact in f64: its functions compute there and round once.
pub fn exact_in_f64<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>() bool {
    return F <= 52 && (E < 11 || E == 11 && FAMILY == sf::FloatFamily::FF_IEEE);
}

fn of64<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(v: f64) Float<E, F, FAMILY> {
    return Float::<E, F, FAMILY>::from_f64(v);
}

fn bias<const E: usize>() i64 {
    return (1i64 << (E - 1) as i64) - 1;
}

// The exact value of a finite x.
fn to_w<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>) Wf<{F + 66}> {
    let (neg, eb, fr) = x.to_parts();
    let mut sig = UInt::<{F + 66}>::cast_unsigned(&fr);
    let mut ex = 1 - bias::<E>() - F as i64;
    if eb != 0 {
        sig = sig | UInt::<{F + 66}>::one() << F;
        ex = eb as i64 - bias::<E>() - F as i64;
    }
    let w = wnorm::<{F + 66}, {F + 66}>(neg, ex, sig);
    return Wf::<{F + 66}> { neg: neg && !w.m.is_zero(), e: w.e, m: w.m };
}

// The format's value nearest a (ties to even), overflowing as the format does; a zero gets `a`'s sign.
fn from_w<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(a: Wf<{F + 66}>) Float<E, F, FAMILY> {
    if a.m.is_zero() {
        return Float::<E, F, FAMILY>::zero();
    }
    let w = (F + 66) as i64;
    // Bits kept: F + 1, fewer below the normal range.
    let top = a.e + w - 1;
    let mut keep = F as i64 + 1;
    let emin = 1 - bias::<E>();
    if top < emin {
        keep = keep - (emin - top);
    }
    let drop = w - keep;
    let mut r = UInt::<{F + 66}>::zero();
    if drop <= w {
        r = a.m >> drop as usize;
        let half = a.m.bit((drop - 1) as usize);
        let rest = !(a.m << (w - drop + 1) as usize).is_zero();
        if half && (rest || r.bit(0)) {
            r = r + UInt::<{F + 66}>::one();
        }
    }
    let v = Float::<E, F, FAMILY>::from_uint(&r).scalbn(a.e + drop);
    if a.neg {
        return v.neg();
    }
    return v;
}

// The overflow of the sign `neg`: infinity, or the largest finite value of a format without one.
fn huge<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(neg: bool) Float<E, F, FAMILY> {
    let h = Float::<E, F, FAMILY>::one().scalbn(i64::MAX / 4);
    if neg {
        return h.neg();
    }
    return h;
}

fn signed_zero<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(neg: bool) Float<E, F, FAMILY> {
    if neg {
        return Float::<E, F, FAMILY>::neg_zero();
    }
    return Float::<E, F, FAMILY>::zero();
}

// The largest |x| for which e^x is not past both ends of the format: (2^(E-1) + F + 8) ln 2.
fn exp_bound<const E: usize, const F: usize>() Wf<{F + 66}> {
    let n = (1u64 << (E - 1) as u64) + F as u64 + 8;
    return wmul(wfrom_u64::<{F + 66}>(n), wln2::<{F + 66}>());
}

// e^w of a working value, saturated past the format's range.
fn exp_of<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(w: Wf<{F + 66}>, neg: bool) Float<E, F, FAMILY> {
    if wcmp_abs(w, exp_bound::<E, F>()) > 0 {
        if w.neg {
            return signed_zero::<E, F, FAMILY>(neg);
        }
        return huge::<E, F, FAMILY>(neg);
    }
    let r = exp_w(w);
    return from_w::<E, F, FAMILY>(Wf::<{F + 66}> { neg: neg, e: r.e, m: r.m });
}

pub fn wide_exp<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>) Float<
    E,
    F,
    FAMILY
> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(x.to_f64().exp());
    }
    if x.is_nan() {
        return x;
    }
    if x.is_infinite() {
        return if x.is_negative() {
            Float::<E, F, FAMILY>::zero();
        } else {
            x;
        };
    }
    return exp_of::<E, F, FAMILY>(to_w(x), false);
}

pub fn wide_exp2<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>) Float<
    E,
    F,
    FAMILY
> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(x.to_f64().exp2());
    }
    if x.is_nan() {
        return x;
    }
    if x.is_infinite() {
        return if x.is_negative() {
            Float::<E, F, FAMILY>::zero();
        } else {
            x;
        };
    }
    return exp_of::<E, F, FAMILY>(wmul(to_w(x), wln2::<{F + 66}>()), false);
}

pub fn wide_ln<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>) Float<
    E,
    F,
    FAMILY
> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(x.to_f64().ln());
    }
    if x.is_nan() || x.is_negative() && !x.is_zero() {
        return Float::<E, F, FAMILY>::nan();
    }
    if x.is_zero() {
        return huge::<E, F, FAMILY>(true);
    }
    if x.is_infinite() {
        return x;
    }
    return from_w::<E, F, FAMILY>(ln_w(to_w(x)));
}

pub fn wide_log2<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>) Float<
    E,
    F,
    FAMILY
> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(x.to_f64().log2());
    }
    if x.is_nan() || x.is_negative() && !x.is_zero() {
        return Float::<E, F, FAMILY>::nan();
    }
    if x.is_zero() {
        return huge::<E, F, FAMILY>(true);
    }
    if x.is_infinite() {
        return x;
    }
    return from_w::<E, F, FAMILY>(wdiv(ln_w(to_w(x)), wln2::<{F + 66}>()));
}

// Whether y is an integer, and whether an odd one.
fn int_kind<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(y: Float<E, F, FAMILY>, odd: &mut bool) bool {
    *odd = false;
    if !y.is_finite() || !y.trunc().ieee_eq(&y) {
        return false;
    }
    let h = y.scalbn(-1);
    *odd = !h.trunc().ieee_eq(&h);
    return true;
}

pub fn wide_pow<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(
    x: Float<E, F, FAMILY>,
    y: Float<E, F, FAMILY>,
) Float<E, F, FAMILY> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(x.to_f64().powf(y.to_f64()));
    }
    let one = Float::<E, F, FAMILY>::one();
    if y.is_zero() || x.ieee_eq(&one) {
        return one;
    }
    if x.is_nan() || y.is_nan() {
        return Float::<E, F, FAMILY>::nan();
    }
    let mut odd = false;
    let yint = int_kind(y, &mut odd);
    let yneg = y.is_negative();
    if x.is_zero() {
        if yneg {
            return huge::<E, F, FAMILY>(odd && x.is_negative());
        }
        return signed_zero::<E, F, FAMILY>(odd && x.is_negative());
    }
    if y.is_infinite() {
        let c = x.abs().ieee_lt(&one);
        let minus_one = one.neg();
        if x.ieee_eq(&minus_one) {
            return one;
        }
        if c != yneg {
            return Float::<E, F, FAMILY>::zero();
        }
        return huge::<E, F, FAMILY>(false);
    }
    if x.is_infinite() {
        let neg = x.is_negative() && odd;
        if yneg {
            return signed_zero::<E, F, FAMILY>(neg);
        }
        return huge::<E, F, FAMILY>(neg);
    }
    if x.is_negative() && !yint {
        return Float::<E, F, FAMILY>::nan();
    }
    let z = wmul(to_w(y), ln_w(wabs(to_w(x))));
    return exp_of::<E, F, FAMILY>(z, x.is_negative() && odd);
}

// sin, cos and tan of a finite x: |x| = q pi/2 + r.
fn trig<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>, which: u32) Float<
    E,
    F,
    FAMILY
> {
    static_assert((1usize << E - 1) + 2 * F + 196 <= 64 * 4200, "sin, cos and tan of this format need more bits of 2/pi");
    let w = to_w(x);
    let (q, r) = reduce_pio2(wabs(w));
    let mut v = wzero::<{F + 66}>();
    if which == 0 {
        // sin: odd in x.
        v = if q % 2 == 0 {
            sin_w(r);
        } else {
            cos_w(r);
        };
        if q >= 2 {
            v = wneg(v);
        }
        if w.neg {
            v = wneg(v);
        }
    } else if which == 1 {
        // cos: even in x.
        v = if q % 2 == 0 {
            cos_w(r);
        } else {
            sin_w(r);
        };
        if q == 1 || q == 2 {
            v = wneg(v);
        }
    } else {
        // tan: odd in x, of period pi.
        v = if q % 2 == 0 {
            wdiv(sin_w(r), cos_w(r));
        } else {
            wneg(wdiv(cos_w(r), sin_w(r)));
        };
        if w.neg {
            v = wneg(v);
        }
    }
    return from_w::<E, F, FAMILY>(v);
}

pub fn wide_sin<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>) Float<
    E,
    F,
    FAMILY
> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(x.to_f64().sin());
    }
    if x.is_nan() || x.is_infinite() {
        return Float::<E, F, FAMILY>::nan();
    }
    if x.is_zero() {
        return x;
    }
    return trig(x, 0);
}

pub fn wide_cos<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>) Float<
    E,
    F,
    FAMILY
> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(x.to_f64().cos());
    }
    if x.is_nan() || x.is_infinite() {
        return Float::<E, F, FAMILY>::nan();
    }
    if x.is_zero() {
        return Float::<E, F, FAMILY>::one();
    }
    return trig(x, 1);
}

pub fn wide_tan<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>) Float<
    E,
    F,
    FAMILY
> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(x.to_f64().tan());
    }
    if x.is_nan() || x.is_infinite() {
        return Float::<E, F, FAMILY>::nan();
    }
    if x.is_zero() {
        return x;
    }
    return trig(x, 2);
}

pub fn wide_asin<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>) Float<
    E,
    F,
    FAMILY
> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(x.to_f64().asin());
    }
    let ax = x.abs();
    if x.is_nan() || Float::<E, F, FAMILY>::one().ieee_lt(&ax) {
        return Float::<E, F, FAMILY>::nan();
    }
    if x.is_zero() {
        return x;
    }
    let w = to_w(x);
    let a = asin_w(wabs(w));
    return from_w::<E, F, FAMILY>(Wf::<{F + 66}> { neg: w.neg, e: a.e, m: a.m });
}

pub fn wide_acos<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>) Float<
    E,
    F,
    FAMILY
> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(x.to_f64().acos());
    }
    let ax = x.abs();
    if x.is_nan() || Float::<E, F, FAMILY>::one().ieee_lt(&ax) {
        return Float::<E, F, FAMILY>::nan();
    }
    return from_w::<E, F, FAMILY>(acos_w(to_w(x)));
}

pub fn wide_atan<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>) Float<
    E,
    F,
    FAMILY
> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(x.to_f64().atan());
    }
    if x.is_nan() || x.is_zero() {
        return x;
    }
    let pi2 = wscale(wpi4::<{F + 66}>(), 1);
    if x.is_infinite() {
        return from_w::<E, F, FAMILY>(Wf::<{F + 66}> { neg: x.is_negative(), e: pi2.e, m: pi2.m });
    }
    let w = to_w(x);
    let a = atan_w(wabs(w));
    return from_w::<E, F, FAMILY>(Wf::<{F + 66}> { neg: w.neg, e: a.e, m: a.m });
}

pub fn wide_atan2<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(
    y: Float<E, F, FAMILY>,
    x: Float<E, F, FAMILY>,
) Float<E, F, FAMILY> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(y.to_f64().atan2(x.to_f64()));
    }
    if y.is_nan() || x.is_nan() {
        return Float::<E, F, FAMILY>::nan();
    }
    let pi4 = wpi4::<{F + 66}>();
    let neg = y.is_negative();
    // Multiples of pi/4 for the special cases: k pi/4 with y's sign.
    let mut k: u64 = 0;
    if y.is_zero() {
        if !x.is_negative() {
            return y;
        }
        k = 4;
    } else if x.is_zero() {
        k = 2;
    } else if y.is_infinite() {
        k = 2;
        if x.is_infinite() {
            k = 1 + 2 * x.is_negative() as u64;
        }
    } else if x.is_infinite() {
        if !x.is_negative() {
            return signed_zero::<E, F, FAMILY>(neg);
        }
        k = 4;
    } else {
        return from_w::<E, F, FAMILY>(atan2_w(to_w(y), to_w(x)));
    }
    let v = wmul_small(pi4, k);
    return from_w::<E, F, FAMILY>(Wf::<{F + 66}> { neg: neg, e: v.e, m: v.m });
}

pub fn wide_sinh<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>) Float<
    E,
    F,
    FAMILY
> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(x.to_f64().sinh());
    }
    if x.is_nan() || x.is_infinite() || x.is_zero() {
        return x;
    }
    let w = to_w(x);
    let a = wabs(w);
    if wcmp_abs(a, exp_bound::<E, F>()) > 0 {
        return huge::<E, F, FAMILY>(w.neg);
    }
    let v = sinh_w(a);
    return from_w::<E, F, FAMILY>(Wf::<{F + 66}> { neg: w.neg, e: v.e, m: v.m });
}

pub fn wide_cosh<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>) Float<
    E,
    F,
    FAMILY
> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(x.to_f64().cosh());
    }
    if x.is_nan() {
        return x;
    }
    if x.is_infinite() {
        return x.abs();
    }
    let a = wabs(to_w(x));
    if wcmp_abs(a, exp_bound::<E, F>()) > 0 {
        return huge::<E, F, FAMILY>(false);
    }
    return from_w::<E, F, FAMILY>(cosh_w(a));
}

pub fn wide_tanh<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>) Float<
    E,
    F,
    FAMILY
> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(x.to_f64().tanh());
    }
    if x.is_nan() || x.is_zero() {
        return x;
    }
    let one = Float::<E, F, FAMILY>::one();
    let w = to_w(x);
    let a = wabs(w);
    // Past F + 8, 1 - tanh |x| < 2^-(F + 2): the nearest value is 1.
    if x.is_infinite() || wcmp_abs(a, wfrom_u64::<{F + 66}>(F as u64 + 8)) > 0 {
        return if w.neg {
            one.neg();
        } else {
            one;
        };
    }
    let v = tanh_w(a);
    return from_w::<E, F, FAMILY>(Wf::<{F + 66}> { neg: w.neg, e: v.e, m: v.m });
}

pub fn wide_asinh<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>) Float<
    E,
    F,
    FAMILY
> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(x.to_f64().asinh());
    }
    if x.is_nan() || x.is_infinite() || x.is_zero() {
        return x;
    }
    let w = to_w(x);
    let v = asinh_w(wabs(w));
    return from_w::<E, F, FAMILY>(Wf::<{F + 66}> { neg: w.neg, e: v.e, m: v.m });
}

pub fn wide_acosh<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>) Float<
    E,
    F,
    FAMILY
> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(x.to_f64().acosh());
    }
    let one = Float::<E, F, FAMILY>::one();
    if x.is_nan() || x.ieee_lt(&one) {
        return Float::<E, F, FAMILY>::nan();
    }
    if x.is_infinite() {
        return x;
    }
    return from_w::<E, F, FAMILY>(acosh_w(to_w(x)));
}

pub fn wide_atanh<const E: usize, const F: usize, const FAMILY: sf::FloatFamily>(x: Float<E, F, FAMILY>) Float<
    E,
    F,
    FAMILY
> {
    if exact_in_f64::<E, F, FAMILY>() {
        return of64::<E, F, FAMILY>(x.to_f64().atanh());
    }
    let one = Float::<E, F, FAMILY>::one();
    let ax = x.abs();
    if x.is_nan() || one.ieee_lt(&ax) {
        return Float::<E, F, FAMILY>::nan();
    }
    if x.is_zero() {
        return x;
    }
    if x.abs().ieee_eq(&one) {
        return huge::<E, F, FAMILY>(x.is_negative());
    }
    let w = to_w(x);
    let v = atanh_w(wabs(w));
    return from_w::<E, F, FAMILY>(Wf::<{F + 66}> { neg: w.neg, e: v.e, m: v.m });
}
