// ML-KEM (FIPS 203), proved: ML-KEM-512, ML-KEM-768 and ML-KEM-1024 as one implementation over the rank
// k. The specification is the standard's algorithms as spec functions over sequences (K-PKE in
// `ek_spec`, `pke_c` and `m_dec`, ML-KEM in `key_dec`), and each function computes exactly what they
// define: key generation, encapsulation and decapsulation with implicit rejection, the NTT, the samplers
// and the encodings. The input checks of FIPS 203, 7.2 and 7.3 are `ek_ok` and `dk_ok`; the length
// checks are `requires`. Every function on secret bytes runs in constant time (`@constant_time`), and no
// operation panics. SampleNTT stops after a fixed number of SHAKE128 blocks; a function that reaches it
// returns false (FIPS 203, Appendix B). Import with `import std::crypto::mlkem;`.

import std::crypto::secret as *;
import std::crypto::sha3;
import std::spec::seq as *;
import std::spec::arith;
import std::platform::entropy;

// Coefficients below q.
spec fn reduced(f: Seq<Secret<u32>>) bool {
    return forall i in 0..f.len() { f[i].value() < 3329 };
}

// A coefficient below q written into coefficients below q.
lemma reduced_update(s: Seq<Secret<u32>>, i: int, x: Secret<u32>)
    requires reduced(s) && x.value() < 3329 && 0 <= i && i < s.len()
    ensures reduced(s.update(i, x)) && s.update(i, x).len() == s.len()
{}

// A value `y` modulo q as a `u32`.
lemma cast_q(r: Secret<u32>, y: int)
    requires y >= 0 && r.value() as int == y % 3329
    ensures r.value() == (y % 3329) as u32
{}

// `a + b` modulo q.
@constant_time
fn add_q(a: Secret<u32>, b: Secret<u32>) Secret<u32>
    requires a.value() < 3329 && b.value() < 3329
    ensures |r| r.value() as int == (a.value() as int + b.value() as int) % 3329 && r.value() < 3329
{
    let s = a + b;
    return Secret::pick(s.lt(Secret::new(3329u32)), s, s - Secret::new(3329u32));
}

// `a - b` modulo q.
@constant_time
fn sub_q(a: Secret<u32>, b: Secret<u32>) Secret<u32>
    requires a.value() < 3329 && b.value() < 3329
    ensures |r| r.value() as int == (a.value() as int + 3329 - b.value() as int) % 3329 && r.value() < 3329
{
    return Secret::pick(a.lt(b), a + Secret::new(3329u32) - b, a - b);
}

// The Barrett quotient `t` of `x` below 2^26: `x - 3329 t` lies in [0, 6657].
lemma barrett(x: int, t: int)
    requires 0 <= x && x < 0x4000000
    requires t * 0x100000000 <= x * 1290167 && x * 1290167 < (t + 1) * 0x100000000
    ensures 3329 * t <= x && x < 3329 * t + 6658
{}

// `x` modulo q from `x - 3329 t` in [0, 6657].
lemma reduce_mod(x: int, t: int)
    requires 0 <= x && 3329 * t <= x && x < 3329 * t + 6658
    ensures x - 3329 * t < 3329 ==> x % 3329 == x - 3329 * t
    ensures x - 3329 * t >= 3329 ==> x % 3329 == x - 3329 * t - 3329
{
    arith::div_mod(x, 3329);
}

// `x` modulo q, for `x` below 2^26.
@constant_time
fn reduce(x: Secret<u64>) Secret<u32>
    requires x.value() < 0x4000000
    ensures |r| r.value() as int == x.value() as int % 3329 && r.value() < 3329
{
    let t = x * Secret::new(1290167u64) >> 32;
    barrett(x.value() as int, t.value() as int);
    reduce_mod(x.value() as int, t.value() as int);
    let r = (x - t * Secret::new(3329u64)).cast::<u32>();
    return Secret::pick(r.lt(Secret::new(3329u32)), r, r - Secret::new(3329u32));
}

// `a * b` modulo q.
@constant_time
fn mul_q(a: Secret<u32>, b: Secret<u32>) Secret<u32>
    requires a.value() < 3329 && b.value() < 3329
    ensures |r| r.value() as int == a.value() as int * b.value() as int % 3329 && r.value() < 3329
{
    return reduce(a.cast::<u64>() * b.cast::<u64>());
}

/// The values zeta^BitRev7(i) modulo q of FIPS 203, Appendix A, for i in [0, 127].
pub spec fn zetas() [u32; 128] {
    return [
        1,
        1729,
        2580,
        3289,
        2642,
        630,
        1897,
        848,
        1062,
        1919,
        193,
        797,
        2786,
        3260,
        569,
        1746,
        296,
        2447,
        1339,
        1476,
        3046,
        56,
        2240,
        1333,
        1426,
        2094,
        535,
        2882,
        2393,
        2879,
        1974,
        821,
        289,
        331,
        3253,
        1756,
        1197,
        2304,
        2277,
        2055,
        650,
        1977,
        2513,
        632,
        2865,
        33,
        1320,
        1915,
        2319,
        1435,
        807,
        452,
        1438,
        2868,
        1534,
        2402,
        2647,
        2617,
        1481,
        648,
        2474,
        3110,
        1227,
        910,
        17,
        2761,
        583,
        2649,
        1637,
        723,
        2288,
        1100,
        1409,
        2662,
        3281,
        233,
        756,
        2156,
        3015,
        3050,
        1703,
        1651,
        2789,
        1789,
        1847,
        952,
        1461,
        2687,
        939,
        2308,
        2437,
        2388,
        733,
        2337,
        268,
        641,
        1584,
        2298,
        2037,
        3220,
        375,
        2549,
        2090,
        1645,
        1063,
        319,
        2773,
        757,
        2099,
        561,
        2466,
        2594,
        2804,
        1092,
        403,
        1026,
        1143,
        2150,
        2775,
        886,
        1722,
        1212,
        1874,
        1029,
        2110,
        2935,
        885,
        2154,
    ];
}

// The zeta of index `i`.
@constant_time
const fn zeta(i: usize) Secret<u32>
    requires i < 128
    ensures |z| z.value() == zetas()[i] && z.value() < 3329
{
    let t: [u32; 128] = [
        1u32,
        1729,
        2580,
        3289,
        2642,
        630,
        1897,
        848,
        1062,
        1919,
        193,
        797,
        2786,
        3260,
        569,
        1746,
        296,
        2447,
        1339,
        1476,
        3046,
        56,
        2240,
        1333,
        1426,
        2094,
        535,
        2882,
        2393,
        2879,
        1974,
        821,
        289,
        331,
        3253,
        1756,
        1197,
        2304,
        2277,
        2055,
        650,
        1977,
        2513,
        632,
        2865,
        33,
        1320,
        1915,
        2319,
        1435,
        807,
        452,
        1438,
        2868,
        1534,
        2402,
        2647,
        2617,
        1481,
        648,
        2474,
        3110,
        1227,
        910,
        17,
        2761,
        583,
        2649,
        1637,
        723,
        2288,
        1100,
        1409,
        2662,
        3281,
        233,
        756,
        2156,
        3015,
        3050,
        1703,
        1651,
        2789,
        1789,
        1847,
        952,
        1461,
        2687,
        939,
        2308,
        2437,
        2388,
        733,
        2337,
        268,
        641,
        1584,
        2298,
        2037,
        3220,
        375,
        2549,
        2090,
        1645,
        1063,
        319,
        2773,
        757,
        2099,
        561,
        2466,
        2594,
        2804,
        1092,
        403,
        1026,
        1143,
        2150,
        2775,
        886,
        1722,
        1212,
        1874,
        1029,
        2110,
        2935,
        885,
        2154,
    ];
    assert t == zetas() by {};
    return Secret::new(t[i]);
}

// The butterflies of FIPS 203, Algorithm 9, from index `j` to `start + len` of the polynomial at `o` in
// `f`, with zeta `z`.
spec fn bfly(f: Seq<Secret<u32>>, o: int, len: int, start: int, j: int, z: Secret<u32>) Seq<Secret<u32>>
    decreases start + len - j
{
    return if j >= start + len || j < 0 || len < 0 || o < 0 || o + j + len >= f.len() {
        f
    } else {
        bfly(
            f.update(
                o + j + len,
                Secret::new(
                    ((f[o + j].value() as int + 3329 - z.value() as int * f[o + j + len].value() as int % 3329) % 3329) as u32,
                ),
            ).update(
                o + j,
                Secret::new(
                    ((f[o + j].value() as int + z.value() as int * f[o + j + len].value() as int % 3329) % 3329) as u32,
                ),
            ),
            o,
            len,
            start,
            j + 1,
            z,
        )
    };
}

// Butterfly groups from `start` (FIPS 203, Algorithm 9's middle loop), group `i` with zeta `zetas()[i]`.
spec fn ntt_starts(f: Seq<Secret<u32>>, o: int, len: int, start: int, i: int) Seq<Secret<u32>>
    decreases 256 - start
{
    return if start < 0 || start + 2 * len > 256 || len < 1 || i < 0 || i >= 128 {
        f
    } else {
        ntt_starts(bfly(f, o, len, start, start, Secret::new(zetas()[i as usize])), o, len, start + 2 * len, i + 1)
    };
}

// The layers of FIPS 203, Algorithm 9, from butterfly length `len` and zeta index `i`.
spec fn ntt_layers(f: Seq<Secret<u32>>, o: int, len: int, i: int) Seq<Secret<u32>>
    decreases len
{
    return if len < 2 {
        f
    } else {
        ntt_layers(ntt_starts(f, o, len, 0, i), o, len / 2, i + 128 / len)
    };
}

/// `f` with its polynomial at `o` replaced by its NTT (FIPS 203, Algorithm 9).
pub spec fn ntt_spec(f: Seq<Secret<u32>>, o: int) Seq<Secret<u32>> {
    return ntt_layers(f, o, 128, 1);
}

// The butterflies from index `start` of FIPS 203, Algorithm 9's inner loop, in place on the polynomial at
// `o` in `f`.
@constant_time
fn butterflies(f: []mut Secret<u32>, o: usize, len: usize, start: usize, z: Secret<u32>)
    requires o as int + 256 <= f.len() as int && start as int + 2 * len as int <= 256 && z.value() < 3329 && reduced(
        f.view(),
    )
    ensures f.len() == old(f.len()) && reduced(f.view())
    ensures f.view() == bfly(old(f.view()), o as int, len as int, start as int, start as int, z)
{
    for j in start..start + len
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant bfly(f.view(), o as int, len as int, start as int, j as int, z) == bfly(
            old(f.view()),
            o as int,
            len as int,
            start as int,
            start as int,
            z,
        )
    {
        let t = mul_q(z, f[o + j + len]);
        let a = f[o + j];
        let lo = sub_q(a, t);
        let hi = add_q(a, t);
        reduced_update(f.view(), (o + j + len) as int, lo);
        f[o + j + len] = lo;
        reduced_update(f.view(), (o + j) as int, hi);
        f[o + j] = hi;
    }
}

// `ntt_starts` as a step: one group, then the rest.
lemma starts_next(f: Seq<Secret<u32>>, o: int, len: int, start: int, i: int, g: Seq<Secret<u32>>)
    requires 0 <= start && start + 2 * len <= 256 && len >= 1 && 0 <= i && i < 128
    requires g == bfly(f, o, len, start, start, Secret::new(zetas()[i as usize]))
    ensures ntt_starts(f, o, len, start, i) == ntt_starts(g, o, len, start + 2 * len, i + 1)
{}

// `ntt_layers` as a step.
lemma layers_next(f: Seq<Secret<u32>>, o: int, len: int, i: int, g: Seq<Secret<u32>>)
    requires len >= 2 && g == ntt_starts(f, o, len, 0, i)
    ensures ntt_layers(f, o, len, i) == ntt_layers(g, o, len / 2, i + 128 / len)
{}

// One layer of FIPS 203, Algorithm 9: the `i` groups of butterfly length `len` with zetas from index `i`.
@constant_time
fn ntt_layer(f: []mut Secret<u32>, o: usize, len: usize, i: usize)
    requires o as int + 256 <= f.len() as int && reduced(f.view()) && len >= 2 && i as int * len as int == 128
    ensures f.len() == old(f.len()) && reduced(f.view())
    ensures f.view() == ntt_starts(old(f.view()), o as int, len as int, 0, i as int)
{
    ghost let g0 = f.view();
    arith::mul_le(2, len as int, i as int);
    let mut start: usize = 0;
    for s in 0..i
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant start as int == 2 * (s as int * len as int)
        invariant ntt_starts(f.view(), o as int, len as int, start as int, i as int + s as int) == ntt_starts(
            g0,
            o as int,
            len as int,
            0,
            i as int,
        )
    {
        arith::mul_le(s as int + 1, i as int, len as int);
        ghost let f0 = f.view();
        let k = i + s;
        butterflies(f, o, len, start, zeta(k));
        starts_next(f0, o as int, len as int, start as int, k as int, f.view());
        start += 2 * len;
    }
    assert start == 256 by {};
    assert ntt_starts(f.view(), o as int, len as int, start as int, 2 * i as int) == f.view() by {};
}

/// The NTT of the polynomial at `o` in `f` (coefficients below q), in place (FIPS 203, Algorithm 9).
@constant_time
pub fn ntt(f: []mut Secret<u32>, o: usize)
    requires o as int + 256 <= f.len() as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == ntt_spec(old(f.view()), o as int)
{
    ghost let g0 = f.view();
    ntt_layer(f, o, 128, 1);
    layers_next(g0, o as int, 128, 1, f.view());
    ghost let g1 = f.view();
    ntt_layer(f, o, 64, 2);
    layers_next(g1, o as int, 64, 2, f.view());
    ghost let g2 = f.view();
    ntt_layer(f, o, 32, 4);
    layers_next(g2, o as int, 32, 4, f.view());
    ghost let g3 = f.view();
    ntt_layer(f, o, 16, 8);
    layers_next(g3, o as int, 16, 8, f.view());
    ghost let g4 = f.view();
    ntt_layer(f, o, 8, 16);
    layers_next(g4, o as int, 8, 16, f.view());
    ghost let g5 = f.view();
    ntt_layer(f, o, 4, 32);
    layers_next(g5, o as int, 4, 32, f.view());
    ghost let g6 = f.view();
    ntt_layer(f, o, 2, 64);
    layers_next(g6, o as int, 2, 64, f.view());
    assert ntt_layers(f.view(), o as int, 1, 128) == f.view() by {};
}

// The butterflies of FIPS 203, Algorithm 10, from index `j` to `start + len` of the polynomial at `o` in
// `f`, with zeta `z`.
spec fn ibfly(f: Seq<Secret<u32>>, o: int, len: int, start: int, j: int, z: Secret<u32>) Seq<Secret<u32>>
    decreases start + len - j
{
    return if j >= start + len || j < 0 || len < 0 || o < 0 || o + j + len >= f.len() {
        f
    } else {
        ibfly(
            f.update(o + j, Secret::new(((f[o + j].value() as int + f[o + j + len].value() as int) % 3329) as u32)).update(
                o + j + len,
                Secret::new(
                    (z.value() as int * ((f[o + j + len].value() as int + 3329 - f[o + j].value() as int) % 3329) % 3329) as u32,
                ),
            ),
            o,
            len,
            start,
            j + 1,
            z,
        )
    };
}

// Butterfly groups from `start` (FIPS 203, Algorithm 10's middle loop), group zetas from index `i` down.
spec fn intt_starts(f: Seq<Secret<u32>>, o: int, len: int, start: int, i: int) Seq<Secret<u32>>
    decreases 256 - start
{
    return if start < 0 || start + 2 * len > 256 || len < 1 || i < 0 || i >= 128 {
        f
    } else {
        intt_starts(ibfly(f, o, len, start, start, Secret::new(zetas()[i as usize])), o, len, start + 2 * len, i - 1)
    };
}

// The layers of FIPS 203, Algorithm 10, from butterfly length `len` and zeta index `i`.
spec fn intt_layers(f: Seq<Secret<u32>>, o: int, len: int, i: int) Seq<Secret<u32>>
    decreases 256 - len
{
    return if len > 128 || len < 1 {
        f
    } else {
        intt_layers(intt_starts(f, o, len, 0, i), o, 2 * len, i - 128 / len)
    };
}

// Coefficients `c` to 255 of the polynomial at `o` in `f` times 3303 modulo q (FIPS 203, Algorithm 10,
// line 14).
spec fn scaled(f: Seq<Secret<u32>>, o: int, c: int) Seq<Secret<u32>>
    decreases 256 - c
{
    return if c >= 256 || c < 0 || o < 0 || o + c >= f.len() {
        f
    } else {
        scaled(f.update(o + c, Secret::new((f[o + c].value() as int * 3303 % 3329) as u32)), o, c + 1)
    };
}

/// `f` with its polynomial at `o` replaced by its inverse NTT (FIPS 203, Algorithm 10).
pub spec fn intt_spec(f: Seq<Secret<u32>>, o: int) Seq<Secret<u32>> {
    return scaled(intt_layers(f, o, 2, 127), o, 0);
}

// The butterflies from index `start` of FIPS 203, Algorithm 10's inner loop.
@constant_time
fn ibutterflies(f: []mut Secret<u32>, o: usize, len: usize, start: usize, z: Secret<u32>)
    requires o as int + 256 <= f.len() as int && start as int + 2 * len as int <= 256 && z.value() < 3329 && reduced(
        f.view(),
    )
    ensures f.len() == old(f.len()) && reduced(f.view())
    ensures f.view() == ibfly(old(f.view()), o as int, len as int, start as int, start as int, z)
{
    for j in start..start + len
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant ibfly(f.view(), o as int, len as int, start as int, j as int, z) == ibfly(
            old(f.view()),
            o as int,
            len as int,
            start as int,
            start as int,
            z,
        )
    {
        let t = f[o + j];
        let u = f[o + j + len];
        let lo = add_q(t, u);
        let hi = mul_q(z, sub_q(u, t));
        reduced_update(f.view(), (o + j) as int, lo);
        f[o + j] = lo;
        reduced_update(f.view(), (o + j + len) as int, hi);
        f[o + j + len] = hi;
    }
}

// `intt_starts` as a step.
lemma istarts_next(f: Seq<Secret<u32>>, o: int, len: int, start: int, i: int, g: Seq<Secret<u32>>)
    requires 0 <= start && start + 2 * len <= 256 && len >= 1 && 0 <= i && i < 128
    requires g == ibfly(f, o, len, start, start, Secret::new(zetas()[i as usize]))
    ensures intt_starts(f, o, len, start, i) == intt_starts(g, o, len, start + 2 * len, i - 1)
{}

// `intt_layers` as a step.
lemma ilayers_next(f: Seq<Secret<u32>>, o: int, len: int, i: int, g: Seq<Secret<u32>>)
    requires len >= 1 && len <= 128 && g == intt_starts(f, o, len, 0, i)
    ensures intt_layers(f, o, len, i) == intt_layers(g, o, 2 * len, i - 128 / len)
{}

// One layer of FIPS 203, Algorithm 10: the `n` groups of butterfly length `len` with zetas from index `i`
// down.
@constant_time
fn intt_layer(f: []mut Secret<u32>, o: usize, len: usize, n: usize, i: usize)
    requires o as int + 256 <= f.len() as int && reduced(f.view()) && len >= 2 && n as int * len as int == 128
    requires i as int + 1 == 2 * n as int
    ensures f.len() == old(f.len()) && reduced(f.view())
    ensures f.view() == intt_starts(old(f.view()), o as int, len as int, 0, i as int)
{
    ghost let g0 = f.view();
    arith::mul_le(2, len as int, n as int);
    let mut start: usize = 0;
    for s in 0..n
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant start as int == 2 * (s as int * len as int)
        invariant intt_starts(f.view(), o as int, len as int, start as int, i as int - s as int) == intt_starts(
            g0,
            o as int,
            len as int,
            0,
            i as int,
        )
    {
        arith::mul_le(s as int + 1, n as int, len as int);
        ghost let f0 = f.view();
        let k = i - s;
        ibutterflies(f, o, len, start, zeta(k));
        istarts_next(f0, o as int, len as int, start as int, k as int, f.view());
        start += 2 * len;
    }
    assert start == 256 by {};
    assert intt_starts(f.view(), o as int, len as int, start as int, i as int - n as int) == f.view() by {};
}

// `scaled` as a step.
lemma scaled_next(f: Seq<Secret<u32>>, o: int, c: int, g: Seq<Secret<u32>>)
    requires 0 <= c && c < 256 && 0 <= o && o + 256 <= f.len()
    requires g == f.update(o + c, Secret::new((f[o + c].value() as int * 3303 % 3329) as u32))
    ensures scaled(f, o, c) == scaled(g, o, c + 1)
{}

/// The inverse NTT of the polynomial at `o` in `f` (coefficients below q), in place (FIPS 203, Algorithm
/// 10).
@constant_time
pub fn intt(f: []mut Secret<u32>, o: usize)
    requires o as int + 256 <= f.len() as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == intt_spec(old(f.view()), o as int)
{
    ghost let g0 = f.view();
    intt_layer(f, o, 2, 64, 127);
    ilayers_next(g0, o as int, 2, 127, f.view());
    ghost let g1 = f.view();
    intt_layer(f, o, 4, 32, 63);
    ilayers_next(g1, o as int, 4, 63, f.view());
    ghost let g2 = f.view();
    intt_layer(f, o, 8, 16, 31);
    ilayers_next(g2, o as int, 8, 31, f.view());
    ghost let g3 = f.view();
    intt_layer(f, o, 16, 8, 15);
    ilayers_next(g3, o as int, 16, 15, f.view());
    ghost let g4 = f.view();
    intt_layer(f, o, 32, 4, 7);
    ilayers_next(g4, o as int, 32, 7, f.view());
    ghost let g5 = f.view();
    intt_layer(f, o, 64, 2, 3);
    ilayers_next(g5, o as int, 64, 3, f.view());
    ghost let g6 = f.view();
    intt_layer(f, o, 128, 1, 1);
    ilayers_next(g6, o as int, 128, 1, f.view());
    assert intt_layers(f.view(), o as int, 256, -1) == f.view() by {};
    ghost let h = f.view();
    let k = Secret::new(3303u32);
    for c in 0usize..256
        invariant f.len() == old(f.len()) && reduced(f.view()) && scaled(f.view(), o as int, c as int) == scaled(
            h,
            o as int,
            0,
        )
    {
        ghost let f0 = f.view();
        let x = mul_q(f[o + c], k);
        reduced_update(f.view(), (o + c) as int, x);
        f[o + c] = x;
        scaled_next(f0, o as int, c as int, f.view());
    }
    assert scaled(f.view(), o as int, 256) == f.view() by {};
}

/// The values zeta^(2 BitRev7(i) + 1) modulo q of FIPS 203, Appendix A, for i in [0, 127].
pub spec fn gammas() [u32; 128] {
    return [
        17,
        3312,
        2761,
        568,
        583,
        2746,
        2649,
        680,
        1637,
        1692,
        723,
        2606,
        2288,
        1041,
        1100,
        2229,
        1409,
        1920,
        2662,
        667,
        3281,
        48,
        233,
        3096,
        756,
        2573,
        2156,
        1173,
        3015,
        314,
        3050,
        279,
        1703,
        1626,
        1651,
        1678,
        2789,
        540,
        1789,
        1540,
        1847,
        1482,
        952,
        2377,
        1461,
        1868,
        2687,
        642,
        939,
        2390,
        2308,
        1021,
        2437,
        892,
        2388,
        941,
        733,
        2596,
        2337,
        992,
        268,
        3061,
        641,
        2688,
        1584,
        1745,
        2298,
        1031,
        2037,
        1292,
        3220,
        109,
        375,
        2954,
        2549,
        780,
        2090,
        1239,
        1645,
        1684,
        1063,
        2266,
        319,
        3010,
        2773,
        556,
        757,
        2572,
        2099,
        1230,
        561,
        2768,
        2466,
        863,
        2594,
        735,
        2804,
        525,
        1092,
        2237,
        403,
        2926,
        1026,
        2303,
        1143,
        2186,
        2150,
        1179,
        2775,
        554,
        886,
        2443,
        1722,
        1607,
        1212,
        2117,
        1874,
        1455,
        1029,
        2300,
        2110,
        1219,
        2935,
        394,
        885,
        2444,
        2154,
        1175,
    ];
}

// The gamma of index `i`.
@constant_time
const fn gamma(i: usize) Secret<u32>
    requires i < 128
    ensures |z| z.value() == gammas()[i] && z.value() < 3329
{
    let t: [u32; 128] = [
        17u32,
        3312,
        2761,
        568,
        583,
        2746,
        2649,
        680,
        1637,
        1692,
        723,
        2606,
        2288,
        1041,
        1100,
        2229,
        1409,
        1920,
        2662,
        667,
        3281,
        48,
        233,
        3096,
        756,
        2573,
        2156,
        1173,
        3015,
        314,
        3050,
        279,
        1703,
        1626,
        1651,
        1678,
        2789,
        540,
        1789,
        1540,
        1847,
        1482,
        952,
        2377,
        1461,
        1868,
        2687,
        642,
        939,
        2390,
        2308,
        1021,
        2437,
        892,
        2388,
        941,
        733,
        2596,
        2337,
        992,
        268,
        3061,
        641,
        2688,
        1584,
        1745,
        2298,
        1031,
        2037,
        1292,
        3220,
        109,
        375,
        2954,
        2549,
        780,
        2090,
        1239,
        1645,
        1684,
        1063,
        2266,
        319,
        3010,
        2773,
        556,
        757,
        2572,
        2099,
        1230,
        561,
        2768,
        2466,
        863,
        2594,
        735,
        2804,
        525,
        1092,
        2237,
        403,
        2926,
        1026,
        2303,
        1143,
        2186,
        2150,
        1179,
        2775,
        554,
        886,
        2443,
        1722,
        1607,
        1212,
        2117,
        1874,
        1455,
        1029,
        2300,
        2110,
        1219,
        2935,
        394,
        885,
        2444,
        2154,
        1175,
    ];
    assert t == gammas() by {};
    return Secret::new(t[i]);
}

// The polynomial at `ao` in `acc` plus the product (FIPS 203, Algorithms 11 and 12) of the NTTs at `af` in
// `a` and at `so` in `s`, from pair `p` on; each step modulo q.
spec fn macc(acc: Seq<Secret<u32>>, ao: int, a: Seq<Secret<u32>>, af: int, s: Seq<Secret<u32>>, so: int, p: int) Seq<
    Secret<u32>
>
    decreases 128 - p
{
    return if p >= 128 || p < 0 || ao < 0 || ao + 256 > acc.len() || af < 0 || af + 256 > a.len() || so < 0 || so + 256 > s.len() {
        acc
    } else {
        macc(
            acc.update(
                ao + 2 * p,
                Secret::new(
                    ((acc[ao + 2 * p].value() as int + (a[af + 2 * p].value() as int * s[so + 2 * p].value() as int + a[af + 2 * p + 1].value() as int * s[so + 2 * p + 1].value() as int % 3329 * gammas()[p as usize] as int) % 3329) % 3329) as u32,
                ),
            ).update(
                ao + 2 * p + 1,
                Secret::new(
                    ((acc[ao + 2 * p + 1].value() as int + (a[af + 2 * p].value() as int * s[so + 2 * p + 1].value() as int + a[af + 2 * p + 1].value() as int * s[so + 2 * p].value() as int) % 3329) % 3329) as u32,
                ),
            ),
            ao,
            a,
            af,
            s,
            so,
            p + 1,
        )
    };
}

// `macc` as a step.
lemma macc_next(
    acc: Seq<Secret<u32>>,
    ao: int,
    a: Seq<Secret<u32>>,
    af: int,
    s: Seq<Secret<u32>>,
    so: int,
    p: int,
    g: Seq<Secret<u32>>,
)
    requires 0 <= p && p < 128 && 0 <= ao && ao + 256 <= acc.len() && 0 <= af && af + 256 <= a.len() && 0 <= so && so + 256 <= s.len()
    requires g == acc.update(
        ao + 2 * p,
        Secret::new(
            ((acc[ao + 2 * p].value() as int + (a[af + 2 * p].value() as int * s[so + 2 * p].value() as int + a[af + 2 * p + 1].value() as int * s[so + 2 * p + 1].value() as int % 3329 * gammas()[p as usize] as int) % 3329) % 3329) as u32,
        ),
    ).update(
        ao + 2 * p + 1,
        Secret::new(
            ((acc[ao + 2 * p + 1].value() as int + (a[af + 2 * p].value() as int * s[so + 2 * p + 1].value() as int + a[af + 2 * p + 1].value() as int * s[so + 2 * p].value() as int) % 3329) % 3329) as u32,
        ),
    )
    ensures macc(acc, ao, a, af, s, so, p) == macc(g, ao, a, af, s, so, p + 1)
{}

// `x * y` for `x` and `y` below q.
@constant_time
const fn mul_small(x: Secret<u64>, y: Secret<u64>) Secret<u64>
    requires x.value() < 3329 && y.value() < 3329
    ensures |r| r.value() as int == x.value() as int * y.value() as int && r.value() < 11082241
{
    return x * y;
}

// `x + y` for `x` and `y` below 2^25.
@constant_time
const fn add_small(x: Secret<u64>, y: Secret<u64>) Secret<u64>
    requires x.value() < 0x2000000 && y.value() < 0x2000000
    ensures |r| r.value() as int == x.value() as int + y.value() as int && r.value() < 0x4000000
{
    return x + y;
}

// The product of `a0 + a1 X` and `b0 + b1 X` modulo `X^2 - g` (FIPS 203, Algorithm 12), each step modulo q.
@constant_time
fn base_mul(a0: Secret<u32>, a1: Secret<u32>, b0: Secret<u32>, b1: Secret<u32>, g: Secret<u32>) [Secret<u32>; 2]
    requires a0.value() < 3329 && a1.value() < 3329 && b0.value() < 3329 && b1.value() < 3329 && g.value() < 3329
    ensures |r| r[0].value() < 3329 && r[1].value() < 3329
    ensures |r| r[0].value() as int == (a0.value() as int * b0.value() as int + a1.value() as int * b1.value() as int % 3329 * g.value() as int) % 3329
    ensures |r| r[1].value() as int == (a0.value() as int * b1.value() as int + a1.value() as int * b0.value() as int) % 3329
{
    let (x0, x1, y0, y1) = (a0.cast::<u64>(), a1.cast::<u64>(), b0.cast::<u64>(), b1.cast::<u64>());
    let t = reduce(mul_small(x1, y1)).cast::<u64>();
    return [
        reduce(add_small(mul_small(x0, y0), mul_small(t, g.cast::<u64>()))),
        reduce(add_small(mul_small(x0, y1), mul_small(x1, y0))),
    ];
}

// Pair `x0 + x1 X` plus the product of `a0 + a1 X` and `b0 + b1 X` modulo `X^2 - g`: the step of `macc`.
@constant_time
fn pair_step(
    x0: Secret<u32>,
    x1: Secret<u32>,
    a0: Secret<u32>,
    a1: Secret<u32>,
    b0: Secret<u32>,
    b1: Secret<u32>,
    g: Secret<u32>,
) [Secret<u32>; 2]
    requires x0.value() < 3329 && x1.value() < 3329 && a0.value() < 3329 && a1.value() < 3329 && b0.value() < 3329 && b1.value() < 3329 && g.value() < 3329
    ensures |r| r[0].value() < 3329 && r[1].value() < 3329
    ensures |r| r[0].value() == ((x0.value() as int + (a0.value() as int * b0.value() as int + a1.value() as int * b1.value() as int % 3329 * g.value() as int) % 3329) % 3329) as u32
    ensures |r| r[1].value() == ((x1.value() as int + (a0.value() as int * b1.value() as int + a1.value() as int * b0.value() as int) % 3329) % 3329) as u32
{
    let c = base_mul(a0, a1, b0, b1, g);
    let r0 = add_q(x0, c[0]);
    let r1 = add_q(x1, c[1]);
    arith::mul_nonneg(a0.value() as int, b0.value() as int);
    arith::mul_nonneg(a1.value() as int * b1.value() as int % 3329, g.value() as int);
    arith::mul_nonneg(a0.value() as int, b1.value() as int);
    arith::mul_nonneg(a1.value() as int, b0.value() as int);
    cast_q(
        r0,
        x0.value() as int + (a0.value() as int * b0.value() as int + a1.value() as int * b1.value() as int % 3329 * g.value() as int) % 3329,
    );
    cast_q(
        r1,
        x1.value() as int + (a0.value() as int * b1.value() as int + a1.value() as int * b0.value() as int) % 3329,
    );
    return [r0, r1];
}

// Adds the product of the NTTs at `af` in `a` and at `so` in `s` to the polynomial at `ao` in `acc` (FIPS
// 203, Algorithms 11 and 12).
@constant_time
fn mul_acc(acc: []mut Secret<u32>, ao: usize, a: []Secret<u32>, af: usize, s: []Secret<u32>, so: usize)
    requires ao as int + 256 <= acc.len() as int && af as int + 256 <= a.len() as int && so as int + 256 <= s.len() as int
    requires reduced(acc.view()) && reduced(a.view()) && reduced(s.view())
    ensures acc.len() == old(acc.len()) && reduced(acc.view())
    ensures acc.view() == macc(old(acc.view()), ao as int, a.view(), af as int, s.view(), so as int, 0)
{
    for p in 0usize..128
        invariant acc.len() == old(acc.len()) && reduced(acc.view())
        invariant macc(acc.view(), ao as int, a.view(), af as int, s.view(), so as int, p as int) == macc(
            old(acc.view()),
            ao as int,
            a.view(),
            af as int,
            s.view(),
            so as int,
            0,
        )
    {
        ghost let f0 = acc.view();
        let r = pair_step(
            acc[ao + 2 * p],
            acc[ao + 2 * p + 1],
            a[af + 2 * p],
            a[af + 2 * p + 1],
            s[so + 2 * p],
            s[so + 2 * p + 1],
            gamma(p),
        );
        let x0 = r[0];
        let x1 = r[1];
        reduced_update(acc.view(), (ao + 2 * p) as int, x0);
        acc[ao + 2 * p] = x0;
        reduced_update(acc.view(), (ao + 2 * p + 1) as int, x1);
        acc[ao + 2 * p + 1] = x1;
        macc_next(f0, ao as int, a.view(), af as int, s.view(), so as int, p as int, acc.view());
    }
    assert macc(acc.view(), ao as int, a.view(), af as int, s.view(), so as int, 128) == acc.view() by {};
}

// Coefficients `c` to 255 of the polynomial at `fo` in `f` plus (`neg`: minus) those at `go` in `g`, modulo
// q.
spec fn padd(f: Seq<Secret<u32>>, fo: int, g: Seq<Secret<u32>>, go: int, neg: bool, c: int) Seq<Secret<u32>>
    decreases 256 - c
{
    return if c >= 256 || c < 0 || fo < 0 || fo + 256 > f.len() || go < 0 || go + 256 > g.len() {
        f
    } else if neg {
        padd(
            f.update(fo + c, Secret::new(((f[fo + c].value() as int + 3329 - g[go + c].value() as int) % 3329) as u32)),
            fo,
            g,
            go,
            neg,
            c + 1,
        )
    } else {
        padd(
            f.update(fo + c, Secret::new(((f[fo + c].value() as int + g[go + c].value() as int) % 3329) as u32)),
            fo,
            g,
            go,
            neg,
            c + 1,
        )
    };
}

// `padd` as a step.
lemma padd_next(
    f: Seq<Secret<u32>>,
    fo: int,
    g: Seq<Secret<u32>>,
    go: int,
    neg: bool,
    c: int,
    x: Secret<u32>,
    h: Seq<Secret<u32>>,
)
    requires 0 <= c && c < 256 && 0 <= fo && fo + 256 <= f.len() && 0 <= go && go + 256 <= g.len()
    requires neg ==> x.value() == ((f[fo + c].value() as int + 3329 - g[go + c].value() as int) % 3329) as u32
    requires !neg ==> x.value() == ((f[fo + c].value() as int + g[go + c].value() as int) % 3329) as u32
    requires h == f.update(fo + c, x)
    ensures padd(f, fo, g, go, neg, c) == padd(h, fo, g, go, neg, c + 1)
{}

// Adds (`neg`: subtracts) the polynomial at `go` in `g` to the one at `fo` in `f`, modulo q.
@constant_time
fn poly_add(f: []mut Secret<u32>, fo: usize, g: []Secret<u32>, go: usize, neg: bool)
    requires fo as int + 256 <= f.len() as int && go as int + 256 <= g.len() as int && reduced(f.view()) && reduced(
        g.view(),
    )
    ensures f.len() == old(f.len()) && reduced(f.view())
    ensures f.view() == padd(old(f.view()), fo as int, g.view(), go as int, neg, 0)
{
    for c in 0usize..256
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant padd(f.view(), fo as int, g.view(), go as int, neg, c as int) == padd(
            old(f.view()),
            fo as int,
            g.view(),
            go as int,
            neg,
            0,
        )
    {
        ghost let f0 = f.view();
        let (a, b) = (f[fo + c], g[go + c]);
        let x = if neg {
            sub_q(a, b)
        } else {
            add_q(a, b)
        };
        if neg {
            cast_q(x, a.value() as int + 3329 - b.value() as int);
        } else {
            cast_q(x, a.value() as int + b.value() as int);
        }
        reduced_update(f.view(), (fo + c) as int, x);
        f[fo + c] = x;
        padd_next(f0, fo as int, g.view(), go as int, neg, c as int, x, f.view());
    }
    assert padd(f.view(), fo as int, g.view(), go as int, neg, 256) == f.view() by {};
}

// Elements `lo` to `hi - 1` of `f` below `p`.
spec fn below_from(f: Seq<Secret<u32>>, lo: int, hi: int, p: u32) bool {
    return forall j in lo..hi { f[j].value() < p };
}

// Element `lo` written: elements `lo + 1` to `hi - 1` stay below `p`.
lemma below_update(f: Seq<Secret<u32>>, lo: int, hi: int, p: u32, x: Secret<u32>)
    requires below_from(f, lo, hi, p) && 0 <= lo && lo < hi && hi <= f.len()
    ensures below_from(f.update(lo, x), lo + 1, hi, p) && f[lo].value() < p
{}

// Element `hi` written with a value below `p`: elements `lo` to `hi` below `p`.
lemma below_push(f: Seq<Secret<u32>>, lo: int, hi: int, p: u32, x: Secret<u32>)
    requires below_from(f, lo, hi, p) && 0 <= lo && lo <= hi && hi < f.len() && x.value() < p
    ensures below_from(f.update(hi, x), lo, hi + 1, p)
{}

// Bit `k` of the bit array FIPS 203, Algorithm 4 makes of the bytes from `bo` in `b`: bit `k % 8` of byte
// `k / 8` (lines 4 and 5 take each byte's bits from the lowest).
spec fn bbit(b: Seq<Secret<u8>>, bo: int, k: int) u32 {
    return if k < 0 || bo < 0 || bo + k / 8 >= b.len() {
        0
    } else {
        b[bo + k / 8].value() as u32 >> (k % 8) as u32 & 1
    };
}

// Bits `i d` to `i d + d - 1` of the bit array from `bo` in `b` as a number, the first the lowest (FIPS
// 203, Algorithm 6, line 3, before the reduction: a sum of distinct powers of 2, their OR).
spec fn dec_bits(b: Seq<Secret<u8>>, bo: int, d: int, i: int) u32 {
    return bbit(b, bo, i * d) | if d > 1 {
        bbit(b, bo, i * d + 1) << 1
    } else {
        0
    } | if d > 2 {
        bbit(b, bo, i * d + 2) << 2
    } else {
        0
    } | if d > 3 {
        bbit(b, bo, i * d + 3) << 3
    } else {
        0
    } | if d > 4 {
        bbit(b, bo, i * d + 4) << 4
    } else {
        0
    } | if d > 5 {
        bbit(b, bo, i * d + 5) << 5
    } else {
        0
    } | if d > 6 {
        bbit(b, bo, i * d + 6) << 6
    } else {
        0
    } | if d > 7 {
        bbit(b, bo, i * d + 7) << 7
    } else {
        0
    } | if d > 8 {
        bbit(b, bo, i * d + 8) << 8
    } else {
        0
    } | if d > 9 {
        bbit(b, bo, i * d + 9) << 9
    } else {
        0
    } | if d > 10 {
        bbit(b, bo, i * d + 10) << 10
    } else {
        0
    } | if d > 11 {
        bbit(b, bo, i * d + 11) << 11
    } else {
        0
    };
}

/// Coefficient `i` of ByteDecode_d of the bytes from `bo` in `b` (FIPS 203, Algorithms 4 and 6): its `d`
/// bits modulo q for `d` 12; a number of `d` bits is its own value modulo 2^d.
pub spec fn dec_coeff(b: Seq<Secret<u8>>, bo: int, d: int, i: int) u32 {
    return if d == 12 {
        dec_bits(b, bo, d, i) % 3329
    } else {
        dec_bits(b, bo, d, i)
    };
}

// Coefficients `c` to 255 of the polynomial at `fo` in `f` set to those of ByteDecode_d of the bytes from
// `bo` in `b`.
spec fn decoded(f: Seq<Secret<u32>>, fo: int, b: Seq<Secret<u8>>, bo: int, d: int, c: int) Seq<Secret<u32>>
    decreases 256 - c
{
    return if c >= 256 || c < 0 || fo < 0 || fo + 256 > f.len() {
        f
    } else {
        decoded(f.update(fo + c, Secret::new(dec_coeff(b, bo, d, c))), fo, b, bo, d, c + 1)
    };
}

// `decoded` as a step.
lemma decoded_next(
    f: Seq<Secret<u32>>,
    fo: int,
    b: Seq<Secret<u8>>,
    bo: int,
    d: int,
    c: int,
    x: Secret<u32>,
    h: Seq<Secret<u32>>,
)
    requires 0 <= c && c < 256 && 0 <= fo && fo + 256 <= f.len()
    requires x.value() == dec_coeff(b, bo, d, c) && h == f.update(fo + c, x)
    ensures decoded(f, fo, b, bo, d, c) == decoded(h, fo, b, bo, d, c + 1)
{}

// Bit `k` of the bit array is bit `t` of the byte at `p` for `k == 8 (p - bo) + t`.
lemma bbit_at(b: Seq<Secret<u8>>, bo: int, k: int, p: int, t: int)
    requires 0 <= t && t < 8 && 0 <= bo && bo <= p && p < b.len() && k == (p - bo) * 8 + t
    ensures bbit(b, bo, k) == (b[p].value() as u32 >> t as u32 & 1)
{
    arith::mod_unique(k, p - bo, t, 8);
    bbit_eq(b, bo, k, p, t);
}

// `bbit_at` from the quotient and the remainder.
lemma bbit_eq(b: Seq<Secret<u8>>, bo: int, k: int, p: int, t: int)
    requires 0 <= t && t < 8 && 0 <= bo && bo <= p && p < b.len() && k / 8 == p - bo && k % 8 == t && k >= 0
    ensures bbit(b, bo, k) == (b[p].value() as u32 >> t as u32 & 1)
{
    assert bo + k / 8 == p by {};
}

// `x` modulo q for `x` below 2^12.
@constant_time
fn mod_q12(x: Secret<u32>) Secret<u32>
    requires x.value() < 4096
    ensures |r| r.value() == x.value() % 3329 && r.value() < 3329
{
    return Secret::pick(x.lt(Secret::new(3329u32)), x, x - Secret::new(3329u32));
}

// Coefficient 0 of a group of ByteDecode_1 as the bits of the bytes that hold it.
lemma dec1_bits0(x0: u8)
    ensures (x0 as u32 & 1u32) == (x0 as u32 >> 0u32 & 1)
{}

// Coefficient `8 g + 0` of ByteDecode_1 of the bytes from `bo` in `b`.
@constant_time
fn dec1_coeff0(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 32 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 1, 8 * g as int + 0) && r.value() < 2
{
    let x0 = b[bo + 1 * g + 0];
    bbit_at(b.view(), bo as int, 1 * (8 * g as int + 0) + 0, (bo + 1 * g + 0) as int, 0);
    dec1_bits0(x0.value());
    return x0.cast::<u32>() & Secret::new(1u32);
}

// Coefficient 1 of a group of ByteDecode_1 as the bits of the bytes that hold it.
lemma dec1_bits1(x0: u8)
    ensures (x0 as u32 >> 1u32 & 1u32) == (x0 as u32 >> 1u32 & 1)
{}

// Coefficient `8 g + 1` of ByteDecode_1 of the bytes from `bo` in `b`.
@constant_time
fn dec1_coeff1(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 32 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 1, 8 * g as int + 1) && r.value() < 2
{
    let x0 = b[bo + 1 * g + 0];
    bbit_at(b.view(), bo as int, 1 * (8 * g as int + 1) + 0, (bo + 1 * g + 0) as int, 1);
    dec1_bits1(x0.value());
    return x0.cast::<u32>() >> 1 & Secret::new(1u32);
}

// Coefficient 2 of a group of ByteDecode_1 as the bits of the bytes that hold it.
lemma dec1_bits2(x0: u8)
    ensures (x0 as u32 >> 2u32 & 1u32) == (x0 as u32 >> 2u32 & 1)
{}

// Coefficient `8 g + 2` of ByteDecode_1 of the bytes from `bo` in `b`.
@constant_time
fn dec1_coeff2(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 32 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 1, 8 * g as int + 2) && r.value() < 2
{
    let x0 = b[bo + 1 * g + 0];
    bbit_at(b.view(), bo as int, 1 * (8 * g as int + 2) + 0, (bo + 1 * g + 0) as int, 2);
    dec1_bits2(x0.value());
    return x0.cast::<u32>() >> 2 & Secret::new(1u32);
}

// Coefficient 3 of a group of ByteDecode_1 as the bits of the bytes that hold it.
lemma dec1_bits3(x0: u8)
    ensures (x0 as u32 >> 3u32 & 1u32) == (x0 as u32 >> 3u32 & 1)
{}

// Coefficient `8 g + 3` of ByteDecode_1 of the bytes from `bo` in `b`.
@constant_time
fn dec1_coeff3(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 32 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 1, 8 * g as int + 3) && r.value() < 2
{
    let x0 = b[bo + 1 * g + 0];
    bbit_at(b.view(), bo as int, 1 * (8 * g as int + 3) + 0, (bo + 1 * g + 0) as int, 3);
    dec1_bits3(x0.value());
    return x0.cast::<u32>() >> 3 & Secret::new(1u32);
}

// Coefficient 4 of a group of ByteDecode_1 as the bits of the bytes that hold it.
lemma dec1_bits4(x0: u8)
    ensures (x0 as u32 >> 4u32 & 1u32) == (x0 as u32 >> 4u32 & 1)
{}

// Coefficient `8 g + 4` of ByteDecode_1 of the bytes from `bo` in `b`.
@constant_time
fn dec1_coeff4(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 32 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 1, 8 * g as int + 4) && r.value() < 2
{
    let x0 = b[bo + 1 * g + 0];
    bbit_at(b.view(), bo as int, 1 * (8 * g as int + 4) + 0, (bo + 1 * g + 0) as int, 4);
    dec1_bits4(x0.value());
    return x0.cast::<u32>() >> 4 & Secret::new(1u32);
}

// Coefficient 5 of a group of ByteDecode_1 as the bits of the bytes that hold it.
lemma dec1_bits5(x0: u8)
    ensures (x0 as u32 >> 5u32 & 1u32) == (x0 as u32 >> 5u32 & 1)
{}

// Coefficient `8 g + 5` of ByteDecode_1 of the bytes from `bo` in `b`.
@constant_time
fn dec1_coeff5(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 32 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 1, 8 * g as int + 5) && r.value() < 2
{
    let x0 = b[bo + 1 * g + 0];
    bbit_at(b.view(), bo as int, 1 * (8 * g as int + 5) + 0, (bo + 1 * g + 0) as int, 5);
    dec1_bits5(x0.value());
    return x0.cast::<u32>() >> 5 & Secret::new(1u32);
}

// Coefficient 6 of a group of ByteDecode_1 as the bits of the bytes that hold it.
lemma dec1_bits6(x0: u8)
    ensures (x0 as u32 >> 6u32 & 1u32) == (x0 as u32 >> 6u32 & 1)
{}

// Coefficient `8 g + 6` of ByteDecode_1 of the bytes from `bo` in `b`.
@constant_time
fn dec1_coeff6(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 32 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 1, 8 * g as int + 6) && r.value() < 2
{
    let x0 = b[bo + 1 * g + 0];
    bbit_at(b.view(), bo as int, 1 * (8 * g as int + 6) + 0, (bo + 1 * g + 0) as int, 6);
    dec1_bits6(x0.value());
    return x0.cast::<u32>() >> 6 & Secret::new(1u32);
}

// Coefficient 7 of a group of ByteDecode_1 as the bits of the bytes that hold it.
lemma dec1_bits7(x0: u8)
    ensures (x0 as u32 >> 7u32 & 1u32) == (x0 as u32 >> 7u32 & 1)
{}

// Coefficient `8 g + 7` of ByteDecode_1 of the bytes from `bo` in `b`.
@constant_time
fn dec1_coeff7(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 32 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 1, 8 * g as int + 7) && r.value() < 2
{
    let x0 = b[bo + 1 * g + 0];
    bbit_at(b.view(), bo as int, 1 * (8 * g as int + 7) + 0, (bo + 1 * g + 0) as int, 7);
    dec1_bits7(x0.value());
    return x0.cast::<u32>() >> 7 & Secret::new(1u32);
}

// Coefficients `8 g + 0` to `8 g + 3` of ByteDecode_1 of the bytes from `bo` in `b` into the polynomial at `fo` in `f`.
@constant_time
fn dec1_part0(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, bo: usize, g: usize)
    requires g < 32 && fo as int + 256 <= f.len() as int && bo as int + 32 <= b.len() as int && reduced(f.view())
    requires below_from(f.view(), fo as int, fo as int + 8 * g as int + 0, 2)
    ensures f.len() == old(f.len()) && reduced(f.view())
    ensures below_from(f.view(), fo as int, fo as int + 8 * g as int + 4, 2)
    ensures decoded(old(f.view()), fo as int, b.view(), bo as int, 1, 8 * g as int + 0) == decoded(
        f.view(),
        fo as int,
        b.view(),
        bo as int,
        1,
        8 * g as int + 4,
    )
{
    ghost let h0 = f.view();
    let r0 = dec1_coeff0(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 0) as int, r0);
    below_push(f.view(), fo as int, (fo + 8 * g + 0) as int, 2, r0);
    f[fo + 8 * g + 0] = r0;
    decoded_next(h0, fo as int, b.view(), bo as int, 1, 8 * g as int + 0, r0, f.view());
    ghost let h1 = f.view();
    let r1 = dec1_coeff1(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 1) as int, r1);
    below_push(f.view(), fo as int, (fo + 8 * g + 1) as int, 2, r1);
    f[fo + 8 * g + 1] = r1;
    decoded_next(h1, fo as int, b.view(), bo as int, 1, 8 * g as int + 1, r1, f.view());
    ghost let h2 = f.view();
    let r2 = dec1_coeff2(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 2) as int, r2);
    below_push(f.view(), fo as int, (fo + 8 * g + 2) as int, 2, r2);
    f[fo + 8 * g + 2] = r2;
    decoded_next(h2, fo as int, b.view(), bo as int, 1, 8 * g as int + 2, r2, f.view());
    ghost let h3 = f.view();
    let r3 = dec1_coeff3(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 3) as int, r3);
    below_push(f.view(), fo as int, (fo + 8 * g + 3) as int, 2, r3);
    f[fo + 8 * g + 3] = r3;
    decoded_next(h3, fo as int, b.view(), bo as int, 1, 8 * g as int + 3, r3, f.view());
}

// Coefficients `8 g + 4` to `8 g + 7` of ByteDecode_1 of the bytes from `bo` in `b` into the polynomial at `fo` in `f`.
@constant_time
fn dec1_part4(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, bo: usize, g: usize)
    requires g < 32 && fo as int + 256 <= f.len() as int && bo as int + 32 <= b.len() as int && reduced(f.view())
    requires below_from(f.view(), fo as int, fo as int + 8 * g as int + 4, 2)
    ensures f.len() == old(f.len()) && reduced(f.view())
    ensures below_from(f.view(), fo as int, fo as int + 8 * g as int + 8, 2)
    ensures decoded(old(f.view()), fo as int, b.view(), bo as int, 1, 8 * g as int + 4) == decoded(
        f.view(),
        fo as int,
        b.view(),
        bo as int,
        1,
        8 * g as int + 8,
    )
{
    ghost let h4 = f.view();
    let r4 = dec1_coeff4(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 4) as int, r4);
    below_push(f.view(), fo as int, (fo + 8 * g + 4) as int, 2, r4);
    f[fo + 8 * g + 4] = r4;
    decoded_next(h4, fo as int, b.view(), bo as int, 1, 8 * g as int + 4, r4, f.view());
    ghost let h5 = f.view();
    let r5 = dec1_coeff5(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 5) as int, r5);
    below_push(f.view(), fo as int, (fo + 8 * g + 5) as int, 2, r5);
    f[fo + 8 * g + 5] = r5;
    decoded_next(h5, fo as int, b.view(), bo as int, 1, 8 * g as int + 5, r5, f.view());
    ghost let h6 = f.view();
    let r6 = dec1_coeff6(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 6) as int, r6);
    below_push(f.view(), fo as int, (fo + 8 * g + 6) as int, 2, r6);
    f[fo + 8 * g + 6] = r6;
    decoded_next(h6, fo as int, b.view(), bo as int, 1, 8 * g as int + 6, r6, f.view());
    ghost let h7 = f.view();
    let r7 = dec1_coeff7(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 7) as int, r7);
    below_push(f.view(), fo as int, (fo + 8 * g + 7) as int, 2, r7);
    f[fo + 8 * g + 7] = r7;
    decoded_next(h7, fo as int, b.view(), bo as int, 1, 8 * g as int + 7, r7, f.view());
}

// ByteDecode_1 of the bytes from `bo` in `b` into the polynomial at `fo` in `f`.
@constant_time
fn decode1(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, bo: usize)
    requires fo as int + 256 <= f.len() as int && bo as int + 32 <= b.len() as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == decoded(
        old(f.view()),
        fo as int,
        b.view(),
        bo as int,
        1,
        0,
    )
    ensures below_from(f.view(), fo as int, fo as int + 256, 2)
{
    for g in 0usize..32
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant below_from(f.view(), fo as int, fo as int + 8 * g as int, 2)
        invariant decoded(f.view(), fo as int, b.view(), bo as int, 1, 8 * g as int) == decoded(
            old(f.view()),
            fo as int,
            b.view(),
            bo as int,
            1,
            0,
        )
    {
        dec1_part0(f, fo, b, bo, g);
        dec1_part4(f, fo, b, bo, g);
    }
    assert decoded(f.view(), fo as int, b.view(), bo as int, 1, 256) == f.view() by {};
}

// Coefficient 0 of a group of ByteDecode_4 as the bits of the bytes that hold it.
lemma dec4_bits0(x0: u8)
    ensures (x0 as u32 & 15u32) == (x0 as u32 >> 0u32 & 1 | (x0 as u32 >> 1u32 & 1) << 1 | (x0 as u32 >> 2u32 & 1) << 2 | (x0 as u32 >> 3u32 & 1) << 3)
{}

// Coefficient `2 g + 0` of ByteDecode_4 of the bytes from `bo` in `b`.
@constant_time
fn dec4_coeff0(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 128 && bo as int + 128 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 4, 2 * g as int + 0) && r.value() < 16
{
    let x0 = b[bo + 1 * g + 0];
    bbit_at(b.view(), bo as int, 4 * (2 * g as int + 0) + 0, (bo + 1 * g + 0) as int, 0);
    bbit_at(b.view(), bo as int, 4 * (2 * g as int + 0) + 1, (bo + 1 * g + 0) as int, 1);
    bbit_at(b.view(), bo as int, 4 * (2 * g as int + 0) + 2, (bo + 1 * g + 0) as int, 2);
    bbit_at(b.view(), bo as int, 4 * (2 * g as int + 0) + 3, (bo + 1 * g + 0) as int, 3);
    dec4_bits0(x0.value());
    return x0.cast::<u32>() & Secret::new(15u32);
}

// Coefficient 1 of a group of ByteDecode_4 as the bits of the bytes that hold it.
lemma dec4_bits1(x0: u8)
    ensures (x0 as u32 >> 4u32 & 15u32) == (x0 as u32 >> 4u32 & 1 | (x0 as u32 >> 5u32 & 1) << 1 | (x0 as u32 >> 6u32 & 1) << 2 | (x0 as u32 >> 7u32 & 1) << 3)
{}

// Coefficient `2 g + 1` of ByteDecode_4 of the bytes from `bo` in `b`.
@constant_time
fn dec4_coeff1(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 128 && bo as int + 128 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 4, 2 * g as int + 1) && r.value() < 16
{
    let x0 = b[bo + 1 * g + 0];
    bbit_at(b.view(), bo as int, 4 * (2 * g as int + 1) + 0, (bo + 1 * g + 0) as int, 4);
    bbit_at(b.view(), bo as int, 4 * (2 * g as int + 1) + 1, (bo + 1 * g + 0) as int, 5);
    bbit_at(b.view(), bo as int, 4 * (2 * g as int + 1) + 2, (bo + 1 * g + 0) as int, 6);
    bbit_at(b.view(), bo as int, 4 * (2 * g as int + 1) + 3, (bo + 1 * g + 0) as int, 7);
    dec4_bits1(x0.value());
    return x0.cast::<u32>() >> 4 & Secret::new(15u32);
}

// Coefficients `2 g + 0` to `2 g + 1` of ByteDecode_4 of the bytes from `bo` in `b` into the polynomial at `fo` in `f`.
@constant_time
fn dec4_part0(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, bo: usize, g: usize)
    requires g < 128 && fo as int + 256 <= f.len() as int && bo as int + 128 <= b.len() as int && reduced(f.view())
    requires below_from(f.view(), fo as int, fo as int + 2 * g as int + 0, 16)
    ensures f.len() == old(f.len()) && reduced(f.view())
    ensures below_from(f.view(), fo as int, fo as int + 2 * g as int + 2, 16)
    ensures decoded(old(f.view()), fo as int, b.view(), bo as int, 4, 2 * g as int + 0) == decoded(
        f.view(),
        fo as int,
        b.view(),
        bo as int,
        4,
        2 * g as int + 2,
    )
{
    ghost let h0 = f.view();
    let r0 = dec4_coeff0(b, bo, g);
    reduced_update(f.view(), (fo + 2 * g + 0) as int, r0);
    below_push(f.view(), fo as int, (fo + 2 * g + 0) as int, 16, r0);
    f[fo + 2 * g + 0] = r0;
    decoded_next(h0, fo as int, b.view(), bo as int, 4, 2 * g as int + 0, r0, f.view());
    ghost let h1 = f.view();
    let r1 = dec4_coeff1(b, bo, g);
    reduced_update(f.view(), (fo + 2 * g + 1) as int, r1);
    below_push(f.view(), fo as int, (fo + 2 * g + 1) as int, 16, r1);
    f[fo + 2 * g + 1] = r1;
    decoded_next(h1, fo as int, b.view(), bo as int, 4, 2 * g as int + 1, r1, f.view());
}

// ByteDecode_4 of the bytes from `bo` in `b` into the polynomial at `fo` in `f`.
@constant_time
fn decode4(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, bo: usize)
    requires fo as int + 256 <= f.len() as int && bo as int + 128 <= b.len() as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == decoded(
        old(f.view()),
        fo as int,
        b.view(),
        bo as int,
        4,
        0,
    )
    ensures below_from(f.view(), fo as int, fo as int + 256, 16)
{
    for g in 0usize..128
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant below_from(f.view(), fo as int, fo as int + 2 * g as int, 16)
        invariant decoded(f.view(), fo as int, b.view(), bo as int, 4, 2 * g as int) == decoded(
            old(f.view()),
            fo as int,
            b.view(),
            bo as int,
            4,
            0,
        )
    {
        dec4_part0(f, fo, b, bo, g);
    }
    assert decoded(f.view(), fo as int, b.view(), bo as int, 4, 256) == f.view() by {};
}

// Coefficient 0 of a group of ByteDecode_5 as the bits of the bytes that hold it.
lemma dec5_bits0(x0: u8)
    ensures (x0 as u32 & 31u32) == (x0 as u32 >> 0u32 & 1 | (x0 as u32 >> 1u32 & 1) << 1 | (x0 as u32 >> 2u32 & 1) << 2 | (x0 as u32 >> 3u32 & 1) << 3 | (x0 as u32 >> 4u32 & 1) << 4)
{}

// Coefficient `8 g + 0` of ByteDecode_5 of the bytes from `bo` in `b`.
@constant_time
fn dec5_coeff0(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 160 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 5, 8 * g as int + 0) && r.value() < 32
{
    let x0 = b[bo + 5 * g + 0];
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 0) + 0, (bo + 5 * g + 0) as int, 0);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 0) + 1, (bo + 5 * g + 0) as int, 1);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 0) + 2, (bo + 5 * g + 0) as int, 2);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 0) + 3, (bo + 5 * g + 0) as int, 3);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 0) + 4, (bo + 5 * g + 0) as int, 4);
    dec5_bits0(x0.value());
    return x0.cast::<u32>() & Secret::new(31u32);
}

// Coefficient 1 of a group of ByteDecode_5 as the bits of the bytes that hold it.
lemma dec5_bits1(x0: u8, x1: u8)
    ensures (x0 as u32 >> 5u32 & 7u32 | (x1 as u32 & 3u32) << 3u32) == (x0 as u32 >> 5u32 & 1 | (x0 as u32 >> 6u32 & 1) << 1 | (x0 as u32 >> 7u32 & 1) << 2 | (x1 as u32 >> 0u32 & 1) << 3 | (x1 as u32 >> 1u32 & 1) << 4)
{}

// Coefficient `8 g + 1` of ByteDecode_5 of the bytes from `bo` in `b`.
@constant_time
fn dec5_coeff1(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 160 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 5, 8 * g as int + 1) && r.value() < 32
{
    let x0 = b[bo + 5 * g + 0];
    let x1 = b[bo + 5 * g + 1];
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 1) + 0, (bo + 5 * g + 0) as int, 5);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 1) + 1, (bo + 5 * g + 0) as int, 6);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 1) + 2, (bo + 5 * g + 0) as int, 7);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 1) + 3, (bo + 5 * g + 1) as int, 0);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 1) + 4, (bo + 5 * g + 1) as int, 1);
    dec5_bits1(x0.value(), x1.value());
    return x0.cast::<u32>() >> 5 & Secret::new(7u32) | (x1.cast::<u32>() & Secret::new(3u32)) << 3;
}

// Coefficient 2 of a group of ByteDecode_5 as the bits of the bytes that hold it.
lemma dec5_bits2(x1: u8)
    ensures (x1 as u32 >> 2u32 & 31u32) == (x1 as u32 >> 2u32 & 1 | (x1 as u32 >> 3u32 & 1) << 1 | (x1 as u32 >> 4u32 & 1) << 2 | (x1 as u32 >> 5u32 & 1) << 3 | (x1 as u32 >> 6u32 & 1) << 4)
{}

// Coefficient `8 g + 2` of ByteDecode_5 of the bytes from `bo` in `b`.
@constant_time
fn dec5_coeff2(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 160 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 5, 8 * g as int + 2) && r.value() < 32
{
    let x1 = b[bo + 5 * g + 1];
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 2) + 0, (bo + 5 * g + 1) as int, 2);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 2) + 1, (bo + 5 * g + 1) as int, 3);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 2) + 2, (bo + 5 * g + 1) as int, 4);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 2) + 3, (bo + 5 * g + 1) as int, 5);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 2) + 4, (bo + 5 * g + 1) as int, 6);
    dec5_bits2(x1.value());
    return x1.cast::<u32>() >> 2 & Secret::new(31u32);
}

// Coefficient 3 of a group of ByteDecode_5 as the bits of the bytes that hold it.
lemma dec5_bits3(x1: u8, x2: u8)
    ensures (x1 as u32 >> 7u32 & 1u32 | (x2 as u32 & 15u32) << 1u32) == (x1 as u32 >> 7u32 & 1 | (x2 as u32 >> 0u32 & 1) << 1 | (x2 as u32 >> 1u32 & 1) << 2 | (x2 as u32 >> 2u32 & 1) << 3 | (x2 as u32 >> 3u32 & 1) << 4)
{}

// Coefficient `8 g + 3` of ByteDecode_5 of the bytes from `bo` in `b`.
@constant_time
fn dec5_coeff3(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 160 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 5, 8 * g as int + 3) && r.value() < 32
{
    let x1 = b[bo + 5 * g + 1];
    let x2 = b[bo + 5 * g + 2];
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 3) + 0, (bo + 5 * g + 1) as int, 7);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 3) + 1, (bo + 5 * g + 2) as int, 0);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 3) + 2, (bo + 5 * g + 2) as int, 1);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 3) + 3, (bo + 5 * g + 2) as int, 2);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 3) + 4, (bo + 5 * g + 2) as int, 3);
    dec5_bits3(x1.value(), x2.value());
    return x1.cast::<u32>() >> 7 & Secret::new(1u32) | (x2.cast::<u32>() & Secret::new(15u32)) << 1;
}

// Coefficient 4 of a group of ByteDecode_5 as the bits of the bytes that hold it.
lemma dec5_bits4(x2: u8, x3: u8)
    ensures (x2 as u32 >> 4u32 & 15u32 | (x3 as u32 & 1u32) << 4u32) == (x2 as u32 >> 4u32 & 1 | (x2 as u32 >> 5u32 & 1) << 1 | (x2 as u32 >> 6u32 & 1) << 2 | (x2 as u32 >> 7u32 & 1) << 3 | (x3 as u32 >> 0u32 & 1) << 4)
{}

// Coefficient `8 g + 4` of ByteDecode_5 of the bytes from `bo` in `b`.
@constant_time
fn dec5_coeff4(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 160 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 5, 8 * g as int + 4) && r.value() < 32
{
    let x2 = b[bo + 5 * g + 2];
    let x3 = b[bo + 5 * g + 3];
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 4) + 0, (bo + 5 * g + 2) as int, 4);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 4) + 1, (bo + 5 * g + 2) as int, 5);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 4) + 2, (bo + 5 * g + 2) as int, 6);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 4) + 3, (bo + 5 * g + 2) as int, 7);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 4) + 4, (bo + 5 * g + 3) as int, 0);
    dec5_bits4(x2.value(), x3.value());
    return x2.cast::<u32>() >> 4 & Secret::new(15u32) | (x3.cast::<u32>() & Secret::new(1u32)) << 4;
}

// Coefficient 5 of a group of ByteDecode_5 as the bits of the bytes that hold it.
lemma dec5_bits5(x3: u8)
    ensures (x3 as u32 >> 1u32 & 31u32) == (x3 as u32 >> 1u32 & 1 | (x3 as u32 >> 2u32 & 1) << 1 | (x3 as u32 >> 3u32 & 1) << 2 | (x3 as u32 >> 4u32 & 1) << 3 | (x3 as u32 >> 5u32 & 1) << 4)
{}

// Coefficient `8 g + 5` of ByteDecode_5 of the bytes from `bo` in `b`.
@constant_time
fn dec5_coeff5(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 160 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 5, 8 * g as int + 5) && r.value() < 32
{
    let x3 = b[bo + 5 * g + 3];
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 5) + 0, (bo + 5 * g + 3) as int, 1);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 5) + 1, (bo + 5 * g + 3) as int, 2);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 5) + 2, (bo + 5 * g + 3) as int, 3);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 5) + 3, (bo + 5 * g + 3) as int, 4);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 5) + 4, (bo + 5 * g + 3) as int, 5);
    dec5_bits5(x3.value());
    return x3.cast::<u32>() >> 1 & Secret::new(31u32);
}

// Coefficient 6 of a group of ByteDecode_5 as the bits of the bytes that hold it.
lemma dec5_bits6(x3: u8, x4: u8)
    ensures (x3 as u32 >> 6u32 & 3u32 | (x4 as u32 & 7u32) << 2u32) == (x3 as u32 >> 6u32 & 1 | (x3 as u32 >> 7u32 & 1) << 1 | (x4 as u32 >> 0u32 & 1) << 2 | (x4 as u32 >> 1u32 & 1) << 3 | (x4 as u32 >> 2u32 & 1) << 4)
{}

// Coefficient `8 g + 6` of ByteDecode_5 of the bytes from `bo` in `b`.
@constant_time
fn dec5_coeff6(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 160 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 5, 8 * g as int + 6) && r.value() < 32
{
    let x3 = b[bo + 5 * g + 3];
    let x4 = b[bo + 5 * g + 4];
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 6) + 0, (bo + 5 * g + 3) as int, 6);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 6) + 1, (bo + 5 * g + 3) as int, 7);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 6) + 2, (bo + 5 * g + 4) as int, 0);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 6) + 3, (bo + 5 * g + 4) as int, 1);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 6) + 4, (bo + 5 * g + 4) as int, 2);
    dec5_bits6(x3.value(), x4.value());
    return x3.cast::<u32>() >> 6 & Secret::new(3u32) | (x4.cast::<u32>() & Secret::new(7u32)) << 2;
}

// Coefficient 7 of a group of ByteDecode_5 as the bits of the bytes that hold it.
lemma dec5_bits7(x4: u8)
    ensures (x4 as u32 >> 3u32 & 31u32) == (x4 as u32 >> 3u32 & 1 | (x4 as u32 >> 4u32 & 1) << 1 | (x4 as u32 >> 5u32 & 1) << 2 | (x4 as u32 >> 6u32 & 1) << 3 | (x4 as u32 >> 7u32 & 1) << 4)
{}

// Coefficient `8 g + 7` of ByteDecode_5 of the bytes from `bo` in `b`.
@constant_time
fn dec5_coeff7(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 160 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 5, 8 * g as int + 7) && r.value() < 32
{
    let x4 = b[bo + 5 * g + 4];
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 7) + 0, (bo + 5 * g + 4) as int, 3);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 7) + 1, (bo + 5 * g + 4) as int, 4);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 7) + 2, (bo + 5 * g + 4) as int, 5);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 7) + 3, (bo + 5 * g + 4) as int, 6);
    bbit_at(b.view(), bo as int, 5 * (8 * g as int + 7) + 4, (bo + 5 * g + 4) as int, 7);
    dec5_bits7(x4.value());
    return x4.cast::<u32>() >> 3 & Secret::new(31u32);
}

// Coefficients `8 g + 0` to `8 g + 3` of ByteDecode_5 of the bytes from `bo` in `b` into the polynomial at `fo` in `f`.
@constant_time
fn dec5_part0(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, bo: usize, g: usize)
    requires g < 32 && fo as int + 256 <= f.len() as int && bo as int + 160 <= b.len() as int && reduced(f.view())
    requires below_from(f.view(), fo as int, fo as int + 8 * g as int + 0, 32)
    ensures f.len() == old(f.len()) && reduced(f.view())
    ensures below_from(f.view(), fo as int, fo as int + 8 * g as int + 4, 32)
    ensures decoded(old(f.view()), fo as int, b.view(), bo as int, 5, 8 * g as int + 0) == decoded(
        f.view(),
        fo as int,
        b.view(),
        bo as int,
        5,
        8 * g as int + 4,
    )
{
    ghost let h0 = f.view();
    let r0 = dec5_coeff0(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 0) as int, r0);
    below_push(f.view(), fo as int, (fo + 8 * g + 0) as int, 32, r0);
    f[fo + 8 * g + 0] = r0;
    decoded_next(h0, fo as int, b.view(), bo as int, 5, 8 * g as int + 0, r0, f.view());
    ghost let h1 = f.view();
    let r1 = dec5_coeff1(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 1) as int, r1);
    below_push(f.view(), fo as int, (fo + 8 * g + 1) as int, 32, r1);
    f[fo + 8 * g + 1] = r1;
    decoded_next(h1, fo as int, b.view(), bo as int, 5, 8 * g as int + 1, r1, f.view());
    ghost let h2 = f.view();
    let r2 = dec5_coeff2(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 2) as int, r2);
    below_push(f.view(), fo as int, (fo + 8 * g + 2) as int, 32, r2);
    f[fo + 8 * g + 2] = r2;
    decoded_next(h2, fo as int, b.view(), bo as int, 5, 8 * g as int + 2, r2, f.view());
    ghost let h3 = f.view();
    let r3 = dec5_coeff3(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 3) as int, r3);
    below_push(f.view(), fo as int, (fo + 8 * g + 3) as int, 32, r3);
    f[fo + 8 * g + 3] = r3;
    decoded_next(h3, fo as int, b.view(), bo as int, 5, 8 * g as int + 3, r3, f.view());
}

// Coefficients `8 g + 4` to `8 g + 7` of ByteDecode_5 of the bytes from `bo` in `b` into the polynomial at `fo` in `f`.
@constant_time
fn dec5_part4(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, bo: usize, g: usize)
    requires g < 32 && fo as int + 256 <= f.len() as int && bo as int + 160 <= b.len() as int && reduced(f.view())
    requires below_from(f.view(), fo as int, fo as int + 8 * g as int + 4, 32)
    ensures f.len() == old(f.len()) && reduced(f.view())
    ensures below_from(f.view(), fo as int, fo as int + 8 * g as int + 8, 32)
    ensures decoded(old(f.view()), fo as int, b.view(), bo as int, 5, 8 * g as int + 4) == decoded(
        f.view(),
        fo as int,
        b.view(),
        bo as int,
        5,
        8 * g as int + 8,
    )
{
    ghost let h4 = f.view();
    let r4 = dec5_coeff4(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 4) as int, r4);
    below_push(f.view(), fo as int, (fo + 8 * g + 4) as int, 32, r4);
    f[fo + 8 * g + 4] = r4;
    decoded_next(h4, fo as int, b.view(), bo as int, 5, 8 * g as int + 4, r4, f.view());
    ghost let h5 = f.view();
    let r5 = dec5_coeff5(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 5) as int, r5);
    below_push(f.view(), fo as int, (fo + 8 * g + 5) as int, 32, r5);
    f[fo + 8 * g + 5] = r5;
    decoded_next(h5, fo as int, b.view(), bo as int, 5, 8 * g as int + 5, r5, f.view());
    ghost let h6 = f.view();
    let r6 = dec5_coeff6(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 6) as int, r6);
    below_push(f.view(), fo as int, (fo + 8 * g + 6) as int, 32, r6);
    f[fo + 8 * g + 6] = r6;
    decoded_next(h6, fo as int, b.view(), bo as int, 5, 8 * g as int + 6, r6, f.view());
    ghost let h7 = f.view();
    let r7 = dec5_coeff7(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 7) as int, r7);
    below_push(f.view(), fo as int, (fo + 8 * g + 7) as int, 32, r7);
    f[fo + 8 * g + 7] = r7;
    decoded_next(h7, fo as int, b.view(), bo as int, 5, 8 * g as int + 7, r7, f.view());
}

// ByteDecode_5 of the bytes from `bo` in `b` into the polynomial at `fo` in `f`.
@constant_time
fn decode5(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, bo: usize)
    requires fo as int + 256 <= f.len() as int && bo as int + 160 <= b.len() as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == decoded(
        old(f.view()),
        fo as int,
        b.view(),
        bo as int,
        5,
        0,
    )
    ensures below_from(f.view(), fo as int, fo as int + 256, 32)
{
    for g in 0usize..32
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant below_from(f.view(), fo as int, fo as int + 8 * g as int, 32)
        invariant decoded(f.view(), fo as int, b.view(), bo as int, 5, 8 * g as int) == decoded(
            old(f.view()),
            fo as int,
            b.view(),
            bo as int,
            5,
            0,
        )
    {
        dec5_part0(f, fo, b, bo, g);
        dec5_part4(f, fo, b, bo, g);
    }
    assert decoded(f.view(), fo as int, b.view(), bo as int, 5, 256) == f.view() by {};
}

// Coefficient 0 of a group of ByteDecode_10 as the bits of the bytes that hold it.
lemma dec10_bits0(x0: u8, x1: u8)
    ensures (x0 as u32 | (x1 as u32 & 3u32) << 8u32) == (x0 as u32 >> 0u32 & 1 | (x0 as u32 >> 1u32 & 1) << 1 | (x0 as u32 >> 2u32 & 1) << 2 | (x0 as u32 >> 3u32 & 1) << 3 | (x0 as u32 >> 4u32 & 1) << 4 | (x0 as u32 >> 5u32 & 1) << 5 | (x0 as u32 >> 6u32 & 1) << 6 | (x0 as u32 >> 7u32 & 1) << 7 | (x1 as u32 >> 0u32 & 1) << 8 | (x1 as u32 >> 1u32 & 1) << 9)
{}

// Coefficient `4 g + 0` of ByteDecode_10 of the bytes from `bo` in `b`.
@constant_time
fn dec10_coeff0(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 64 && bo as int + 320 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 10, 4 * g as int + 0) && r.value() < 1024
{
    let x0 = b[bo + 5 * g + 0];
    let x1 = b[bo + 5 * g + 1];
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 0) + 0, (bo + 5 * g + 0) as int, 0);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 0) + 1, (bo + 5 * g + 0) as int, 1);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 0) + 2, (bo + 5 * g + 0) as int, 2);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 0) + 3, (bo + 5 * g + 0) as int, 3);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 0) + 4, (bo + 5 * g + 0) as int, 4);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 0) + 5, (bo + 5 * g + 0) as int, 5);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 0) + 6, (bo + 5 * g + 0) as int, 6);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 0) + 7, (bo + 5 * g + 0) as int, 7);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 0) + 8, (bo + 5 * g + 1) as int, 0);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 0) + 9, (bo + 5 * g + 1) as int, 1);
    dec10_bits0(x0.value(), x1.value());
    return x0.cast::<u32>() | (x1.cast::<u32>() & Secret::new(3u32)) << 8;
}

// Coefficient 1 of a group of ByteDecode_10 as the bits of the bytes that hold it.
lemma dec10_bits1(x1: u8, x2: u8)
    ensures (x1 as u32 >> 2u32 & 63u32 | (x2 as u32 & 15u32) << 6u32) == (x1 as u32 >> 2u32 & 1 | (x1 as u32 >> 3u32 & 1) << 1 | (x1 as u32 >> 4u32 & 1) << 2 | (x1 as u32 >> 5u32 & 1) << 3 | (x1 as u32 >> 6u32 & 1) << 4 | (x1 as u32 >> 7u32 & 1) << 5 | (x2 as u32 >> 0u32 & 1) << 6 | (x2 as u32 >> 1u32 & 1) << 7 | (x2 as u32 >> 2u32 & 1) << 8 | (x2 as u32 >> 3u32 & 1) << 9)
{}

// Coefficient `4 g + 1` of ByteDecode_10 of the bytes from `bo` in `b`.
@constant_time
fn dec10_coeff1(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 64 && bo as int + 320 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 10, 4 * g as int + 1) && r.value() < 1024
{
    let x1 = b[bo + 5 * g + 1];
    let x2 = b[bo + 5 * g + 2];
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 1) + 0, (bo + 5 * g + 1) as int, 2);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 1) + 1, (bo + 5 * g + 1) as int, 3);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 1) + 2, (bo + 5 * g + 1) as int, 4);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 1) + 3, (bo + 5 * g + 1) as int, 5);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 1) + 4, (bo + 5 * g + 1) as int, 6);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 1) + 5, (bo + 5 * g + 1) as int, 7);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 1) + 6, (bo + 5 * g + 2) as int, 0);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 1) + 7, (bo + 5 * g + 2) as int, 1);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 1) + 8, (bo + 5 * g + 2) as int, 2);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 1) + 9, (bo + 5 * g + 2) as int, 3);
    dec10_bits1(x1.value(), x2.value());
    return x1.cast::<u32>() >> 2 & Secret::new(63u32) | (x2.cast::<u32>() & Secret::new(15u32)) << 6;
}

// Coefficient 2 of a group of ByteDecode_10 as the bits of the bytes that hold it.
lemma dec10_bits2(x2: u8, x3: u8)
    ensures (x2 as u32 >> 4u32 & 15u32 | (x3 as u32 & 63u32) << 4u32) == (x2 as u32 >> 4u32 & 1 | (x2 as u32 >> 5u32 & 1) << 1 | (x2 as u32 >> 6u32 & 1) << 2 | (x2 as u32 >> 7u32 & 1) << 3 | (x3 as u32 >> 0u32 & 1) << 4 | (x3 as u32 >> 1u32 & 1) << 5 | (x3 as u32 >> 2u32 & 1) << 6 | (x3 as u32 >> 3u32 & 1) << 7 | (x3 as u32 >> 4u32 & 1) << 8 | (x3 as u32 >> 5u32 & 1) << 9)
{}

// Coefficient `4 g + 2` of ByteDecode_10 of the bytes from `bo` in `b`.
@constant_time
fn dec10_coeff2(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 64 && bo as int + 320 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 10, 4 * g as int + 2) && r.value() < 1024
{
    let x2 = b[bo + 5 * g + 2];
    let x3 = b[bo + 5 * g + 3];
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 2) + 0, (bo + 5 * g + 2) as int, 4);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 2) + 1, (bo + 5 * g + 2) as int, 5);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 2) + 2, (bo + 5 * g + 2) as int, 6);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 2) + 3, (bo + 5 * g + 2) as int, 7);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 2) + 4, (bo + 5 * g + 3) as int, 0);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 2) + 5, (bo + 5 * g + 3) as int, 1);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 2) + 6, (bo + 5 * g + 3) as int, 2);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 2) + 7, (bo + 5 * g + 3) as int, 3);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 2) + 8, (bo + 5 * g + 3) as int, 4);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 2) + 9, (bo + 5 * g + 3) as int, 5);
    dec10_bits2(x2.value(), x3.value());
    return x2.cast::<u32>() >> 4 & Secret::new(15u32) | (x3.cast::<u32>() & Secret::new(63u32)) << 4;
}

// Coefficient 3 of a group of ByteDecode_10 as the bits of the bytes that hold it.
lemma dec10_bits3(x3: u8, x4: u8)
    ensures (x3 as u32 >> 6u32 & 3u32 | x4 as u32 << 2u32) == (x3 as u32 >> 6u32 & 1 | (x3 as u32 >> 7u32 & 1) << 1 | (x4 as u32 >> 0u32 & 1) << 2 | (x4 as u32 >> 1u32 & 1) << 3 | (x4 as u32 >> 2u32 & 1) << 4 | (x4 as u32 >> 3u32 & 1) << 5 | (x4 as u32 >> 4u32 & 1) << 6 | (x4 as u32 >> 5u32 & 1) << 7 | (x4 as u32 >> 6u32 & 1) << 8 | (x4 as u32 >> 7u32 & 1) << 9)
{}

// Coefficient `4 g + 3` of ByteDecode_10 of the bytes from `bo` in `b`.
@constant_time
fn dec10_coeff3(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 64 && bo as int + 320 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 10, 4 * g as int + 3) && r.value() < 1024
{
    let x3 = b[bo + 5 * g + 3];
    let x4 = b[bo + 5 * g + 4];
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 3) + 0, (bo + 5 * g + 3) as int, 6);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 3) + 1, (bo + 5 * g + 3) as int, 7);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 3) + 2, (bo + 5 * g + 4) as int, 0);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 3) + 3, (bo + 5 * g + 4) as int, 1);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 3) + 4, (bo + 5 * g + 4) as int, 2);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 3) + 5, (bo + 5 * g + 4) as int, 3);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 3) + 6, (bo + 5 * g + 4) as int, 4);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 3) + 7, (bo + 5 * g + 4) as int, 5);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 3) + 8, (bo + 5 * g + 4) as int, 6);
    bbit_at(b.view(), bo as int, 10 * (4 * g as int + 3) + 9, (bo + 5 * g + 4) as int, 7);
    dec10_bits3(x3.value(), x4.value());
    return x3.cast::<u32>() >> 6 & Secret::new(3u32) | x4.cast::<u32>() << 2;
}

// Coefficients `4 g + 0` to `4 g + 3` of ByteDecode_10 of the bytes from `bo` in `b` into the polynomial at `fo` in `f`.
@constant_time
fn dec10_part0(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, bo: usize, g: usize)
    requires g < 64 && fo as int + 256 <= f.len() as int && bo as int + 320 <= b.len() as int && reduced(f.view())
    requires below_from(f.view(), fo as int, fo as int + 4 * g as int + 0, 1024)
    ensures f.len() == old(f.len()) && reduced(f.view())
    ensures below_from(f.view(), fo as int, fo as int + 4 * g as int + 4, 1024)
    ensures decoded(old(f.view()), fo as int, b.view(), bo as int, 10, 4 * g as int + 0) == decoded(
        f.view(),
        fo as int,
        b.view(),
        bo as int,
        10,
        4 * g as int + 4,
    )
{
    ghost let h0 = f.view();
    let r0 = dec10_coeff0(b, bo, g);
    reduced_update(f.view(), (fo + 4 * g + 0) as int, r0);
    below_push(f.view(), fo as int, (fo + 4 * g + 0) as int, 1024, r0);
    f[fo + 4 * g + 0] = r0;
    decoded_next(h0, fo as int, b.view(), bo as int, 10, 4 * g as int + 0, r0, f.view());
    ghost let h1 = f.view();
    let r1 = dec10_coeff1(b, bo, g);
    reduced_update(f.view(), (fo + 4 * g + 1) as int, r1);
    below_push(f.view(), fo as int, (fo + 4 * g + 1) as int, 1024, r1);
    f[fo + 4 * g + 1] = r1;
    decoded_next(h1, fo as int, b.view(), bo as int, 10, 4 * g as int + 1, r1, f.view());
    ghost let h2 = f.view();
    let r2 = dec10_coeff2(b, bo, g);
    reduced_update(f.view(), (fo + 4 * g + 2) as int, r2);
    below_push(f.view(), fo as int, (fo + 4 * g + 2) as int, 1024, r2);
    f[fo + 4 * g + 2] = r2;
    decoded_next(h2, fo as int, b.view(), bo as int, 10, 4 * g as int + 2, r2, f.view());
    ghost let h3 = f.view();
    let r3 = dec10_coeff3(b, bo, g);
    reduced_update(f.view(), (fo + 4 * g + 3) as int, r3);
    below_push(f.view(), fo as int, (fo + 4 * g + 3) as int, 1024, r3);
    f[fo + 4 * g + 3] = r3;
    decoded_next(h3, fo as int, b.view(), bo as int, 10, 4 * g as int + 3, r3, f.view());
}

// ByteDecode_10 of the bytes from `bo` in `b` into the polynomial at `fo` in `f`.
@constant_time
fn decode10(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, bo: usize)
    requires fo as int + 256 <= f.len() as int && bo as int + 320 <= b.len() as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == decoded(
        old(f.view()),
        fo as int,
        b.view(),
        bo as int,
        10,
        0,
    )
    ensures below_from(f.view(), fo as int, fo as int + 256, 1024)
{
    for g in 0usize..64
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant below_from(f.view(), fo as int, fo as int + 4 * g as int, 1024)
        invariant decoded(f.view(), fo as int, b.view(), bo as int, 10, 4 * g as int) == decoded(
            old(f.view()),
            fo as int,
            b.view(),
            bo as int,
            10,
            0,
        )
    {
        dec10_part0(f, fo, b, bo, g);
    }
    assert decoded(f.view(), fo as int, b.view(), bo as int, 10, 256) == f.view() by {};
}

// Coefficient 0 of a group of ByteDecode_11 as the bits of the bytes that hold it.
lemma dec11_bits0(x0: u8, x1: u8)
    ensures (x0 as u32 | (x1 as u32 & 7u32) << 8u32) == (x0 as u32 >> 0u32 & 1 | (x0 as u32 >> 1u32 & 1) << 1 | (x0 as u32 >> 2u32 & 1) << 2 | (x0 as u32 >> 3u32 & 1) << 3 | (x0 as u32 >> 4u32 & 1) << 4 | (x0 as u32 >> 5u32 & 1) << 5 | (x0 as u32 >> 6u32 & 1) << 6 | (x0 as u32 >> 7u32 & 1) << 7 | (x1 as u32 >> 0u32 & 1) << 8 | (x1 as u32 >> 1u32 & 1) << 9 | (x1 as u32 >> 2u32 & 1) << 10)
{}

// Coefficient `8 g + 0` of ByteDecode_11 of the bytes from `bo` in `b`.
@constant_time
fn dec11_coeff0(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 352 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 11, 8 * g as int + 0) && r.value() < 2048
{
    let x0 = b[bo + 11 * g + 0];
    let x1 = b[bo + 11 * g + 1];
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 0) + 0, (bo + 11 * g + 0) as int, 0);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 0) + 1, (bo + 11 * g + 0) as int, 1);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 0) + 2, (bo + 11 * g + 0) as int, 2);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 0) + 3, (bo + 11 * g + 0) as int, 3);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 0) + 4, (bo + 11 * g + 0) as int, 4);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 0) + 5, (bo + 11 * g + 0) as int, 5);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 0) + 6, (bo + 11 * g + 0) as int, 6);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 0) + 7, (bo + 11 * g + 0) as int, 7);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 0) + 8, (bo + 11 * g + 1) as int, 0);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 0) + 9, (bo + 11 * g + 1) as int, 1);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 0) + 10, (bo + 11 * g + 1) as int, 2);
    dec11_bits0(x0.value(), x1.value());
    return x0.cast::<u32>() | (x1.cast::<u32>() & Secret::new(7u32)) << 8;
}

// Coefficient 1 of a group of ByteDecode_11 as the bits of the bytes that hold it.
lemma dec11_bits1(x1: u8, x2: u8)
    ensures (x1 as u32 >> 3u32 & 31u32 | (x2 as u32 & 63u32) << 5u32) == (x1 as u32 >> 3u32 & 1 | (x1 as u32 >> 4u32 & 1) << 1 | (x1 as u32 >> 5u32 & 1) << 2 | (x1 as u32 >> 6u32 & 1) << 3 | (x1 as u32 >> 7u32 & 1) << 4 | (x2 as u32 >> 0u32 & 1) << 5 | (x2 as u32 >> 1u32 & 1) << 6 | (x2 as u32 >> 2u32 & 1) << 7 | (x2 as u32 >> 3u32 & 1) << 8 | (x2 as u32 >> 4u32 & 1) << 9 | (x2 as u32 >> 5u32 & 1) << 10)
{}

// Coefficient `8 g + 1` of ByteDecode_11 of the bytes from `bo` in `b`.
@constant_time
fn dec11_coeff1(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 352 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 11, 8 * g as int + 1) && r.value() < 2048
{
    let x1 = b[bo + 11 * g + 1];
    let x2 = b[bo + 11 * g + 2];
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 1) + 0, (bo + 11 * g + 1) as int, 3);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 1) + 1, (bo + 11 * g + 1) as int, 4);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 1) + 2, (bo + 11 * g + 1) as int, 5);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 1) + 3, (bo + 11 * g + 1) as int, 6);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 1) + 4, (bo + 11 * g + 1) as int, 7);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 1) + 5, (bo + 11 * g + 2) as int, 0);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 1) + 6, (bo + 11 * g + 2) as int, 1);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 1) + 7, (bo + 11 * g + 2) as int, 2);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 1) + 8, (bo + 11 * g + 2) as int, 3);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 1) + 9, (bo + 11 * g + 2) as int, 4);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 1) + 10, (bo + 11 * g + 2) as int, 5);
    dec11_bits1(x1.value(), x2.value());
    return x1.cast::<u32>() >> 3 & Secret::new(31u32) | (x2.cast::<u32>() & Secret::new(63u32)) << 5;
}

// Coefficient 2 of a group of ByteDecode_11 as the bits of the bytes that hold it.
lemma dec11_bits2(x2: u8, x3: u8, x4: u8)
    ensures (x2 as u32 >> 6u32 & 3u32 | x3 as u32 << 2u32 | (x4 as u32 & 1u32) << 10u32) == (x2 as u32 >> 6u32 & 1 | (x2 as u32 >> 7u32 & 1) << 1 | (x3 as u32 >> 0u32 & 1) << 2 | (x3 as u32 >> 1u32 & 1) << 3 | (x3 as u32 >> 2u32 & 1) << 4 | (x3 as u32 >> 3u32 & 1) << 5 | (x3 as u32 >> 4u32 & 1) << 6 | (x3 as u32 >> 5u32 & 1) << 7 | (x3 as u32 >> 6u32 & 1) << 8 | (x3 as u32 >> 7u32 & 1) << 9 | (x4 as u32 >> 0u32 & 1) << 10)
{}

// Coefficient `8 g + 2` of ByteDecode_11 of the bytes from `bo` in `b`.
@constant_time
fn dec11_coeff2(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 352 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 11, 8 * g as int + 2) && r.value() < 2048
{
    let x2 = b[bo + 11 * g + 2];
    let x3 = b[bo + 11 * g + 3];
    let x4 = b[bo + 11 * g + 4];
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 2) + 0, (bo + 11 * g + 2) as int, 6);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 2) + 1, (bo + 11 * g + 2) as int, 7);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 2) + 2, (bo + 11 * g + 3) as int, 0);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 2) + 3, (bo + 11 * g + 3) as int, 1);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 2) + 4, (bo + 11 * g + 3) as int, 2);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 2) + 5, (bo + 11 * g + 3) as int, 3);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 2) + 6, (bo + 11 * g + 3) as int, 4);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 2) + 7, (bo + 11 * g + 3) as int, 5);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 2) + 8, (bo + 11 * g + 3) as int, 6);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 2) + 9, (bo + 11 * g + 3) as int, 7);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 2) + 10, (bo + 11 * g + 4) as int, 0);
    dec11_bits2(x2.value(), x3.value(), x4.value());
    return x2.cast::<u32>() >> 6 & Secret::new(3u32) | x3.cast::<u32>() << 2 | (x4.cast::<u32>() & Secret::new(1u32)) << 10;
}

// Coefficient 3 of a group of ByteDecode_11 as the bits of the bytes that hold it.
lemma dec11_bits3(x4: u8, x5: u8)
    ensures (x4 as u32 >> 1u32 & 127u32 | (x5 as u32 & 15u32) << 7u32) == (x4 as u32 >> 1u32 & 1 | (x4 as u32 >> 2u32 & 1) << 1 | (x4 as u32 >> 3u32 & 1) << 2 | (x4 as u32 >> 4u32 & 1) << 3 | (x4 as u32 >> 5u32 & 1) << 4 | (x4 as u32 >> 6u32 & 1) << 5 | (x4 as u32 >> 7u32 & 1) << 6 | (x5 as u32 >> 0u32 & 1) << 7 | (x5 as u32 >> 1u32 & 1) << 8 | (x5 as u32 >> 2u32 & 1) << 9 | (x5 as u32 >> 3u32 & 1) << 10)
{}

// Coefficient `8 g + 3` of ByteDecode_11 of the bytes from `bo` in `b`.
@constant_time
fn dec11_coeff3(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 352 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 11, 8 * g as int + 3) && r.value() < 2048
{
    let x4 = b[bo + 11 * g + 4];
    let x5 = b[bo + 11 * g + 5];
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 3) + 0, (bo + 11 * g + 4) as int, 1);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 3) + 1, (bo + 11 * g + 4) as int, 2);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 3) + 2, (bo + 11 * g + 4) as int, 3);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 3) + 3, (bo + 11 * g + 4) as int, 4);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 3) + 4, (bo + 11 * g + 4) as int, 5);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 3) + 5, (bo + 11 * g + 4) as int, 6);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 3) + 6, (bo + 11 * g + 4) as int, 7);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 3) + 7, (bo + 11 * g + 5) as int, 0);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 3) + 8, (bo + 11 * g + 5) as int, 1);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 3) + 9, (bo + 11 * g + 5) as int, 2);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 3) + 10, (bo + 11 * g + 5) as int, 3);
    dec11_bits3(x4.value(), x5.value());
    return x4.cast::<u32>() >> 1 & Secret::new(127u32) | (x5.cast::<u32>() & Secret::new(15u32)) << 7;
}

// Coefficient 4 of a group of ByteDecode_11 as the bits of the bytes that hold it.
lemma dec11_bits4(x5: u8, x6: u8)
    ensures (x5 as u32 >> 4u32 & 15u32 | (x6 as u32 & 127u32) << 4u32) == (x5 as u32 >> 4u32 & 1 | (x5 as u32 >> 5u32 & 1) << 1 | (x5 as u32 >> 6u32 & 1) << 2 | (x5 as u32 >> 7u32 & 1) << 3 | (x6 as u32 >> 0u32 & 1) << 4 | (x6 as u32 >> 1u32 & 1) << 5 | (x6 as u32 >> 2u32 & 1) << 6 | (x6 as u32 >> 3u32 & 1) << 7 | (x6 as u32 >> 4u32 & 1) << 8 | (x6 as u32 >> 5u32 & 1) << 9 | (x6 as u32 >> 6u32 & 1) << 10)
{}

// Coefficient `8 g + 4` of ByteDecode_11 of the bytes from `bo` in `b`.
@constant_time
fn dec11_coeff4(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 352 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 11, 8 * g as int + 4) && r.value() < 2048
{
    let x5 = b[bo + 11 * g + 5];
    let x6 = b[bo + 11 * g + 6];
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 4) + 0, (bo + 11 * g + 5) as int, 4);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 4) + 1, (bo + 11 * g + 5) as int, 5);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 4) + 2, (bo + 11 * g + 5) as int, 6);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 4) + 3, (bo + 11 * g + 5) as int, 7);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 4) + 4, (bo + 11 * g + 6) as int, 0);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 4) + 5, (bo + 11 * g + 6) as int, 1);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 4) + 6, (bo + 11 * g + 6) as int, 2);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 4) + 7, (bo + 11 * g + 6) as int, 3);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 4) + 8, (bo + 11 * g + 6) as int, 4);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 4) + 9, (bo + 11 * g + 6) as int, 5);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 4) + 10, (bo + 11 * g + 6) as int, 6);
    dec11_bits4(x5.value(), x6.value());
    return x5.cast::<u32>() >> 4 & Secret::new(15u32) | (x6.cast::<u32>() & Secret::new(127u32)) << 4;
}

// Coefficient 5 of a group of ByteDecode_11 as the bits of the bytes that hold it.
lemma dec11_bits5(x6: u8, x7: u8, x8: u8)
    ensures (x6 as u32 >> 7u32 & 1u32 | x7 as u32 << 1u32 | (x8 as u32 & 3u32) << 9u32) == (x6 as u32 >> 7u32 & 1 | (x7 as u32 >> 0u32 & 1) << 1 | (x7 as u32 >> 1u32 & 1) << 2 | (x7 as u32 >> 2u32 & 1) << 3 | (x7 as u32 >> 3u32 & 1) << 4 | (x7 as u32 >> 4u32 & 1) << 5 | (x7 as u32 >> 5u32 & 1) << 6 | (x7 as u32 >> 6u32 & 1) << 7 | (x7 as u32 >> 7u32 & 1) << 8 | (x8 as u32 >> 0u32 & 1) << 9 | (x8 as u32 >> 1u32 & 1) << 10)
{}

// Coefficient `8 g + 5` of ByteDecode_11 of the bytes from `bo` in `b`.
@constant_time
fn dec11_coeff5(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 352 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 11, 8 * g as int + 5) && r.value() < 2048
{
    let x6 = b[bo + 11 * g + 6];
    let x7 = b[bo + 11 * g + 7];
    let x8 = b[bo + 11 * g + 8];
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 5) + 0, (bo + 11 * g + 6) as int, 7);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 5) + 1, (bo + 11 * g + 7) as int, 0);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 5) + 2, (bo + 11 * g + 7) as int, 1);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 5) + 3, (bo + 11 * g + 7) as int, 2);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 5) + 4, (bo + 11 * g + 7) as int, 3);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 5) + 5, (bo + 11 * g + 7) as int, 4);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 5) + 6, (bo + 11 * g + 7) as int, 5);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 5) + 7, (bo + 11 * g + 7) as int, 6);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 5) + 8, (bo + 11 * g + 7) as int, 7);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 5) + 9, (bo + 11 * g + 8) as int, 0);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 5) + 10, (bo + 11 * g + 8) as int, 1);
    dec11_bits5(x6.value(), x7.value(), x8.value());
    return x6.cast::<u32>() >> 7 & Secret::new(1u32) | x7.cast::<u32>() << 1 | (x8.cast::<u32>() & Secret::new(3u32)) << 9;
}

// Coefficient 6 of a group of ByteDecode_11 as the bits of the bytes that hold it.
lemma dec11_bits6(x8: u8, x9: u8)
    ensures (x8 as u32 >> 2u32 & 63u32 | (x9 as u32 & 31u32) << 6u32) == (x8 as u32 >> 2u32 & 1 | (x8 as u32 >> 3u32 & 1) << 1 | (x8 as u32 >> 4u32 & 1) << 2 | (x8 as u32 >> 5u32 & 1) << 3 | (x8 as u32 >> 6u32 & 1) << 4 | (x8 as u32 >> 7u32 & 1) << 5 | (x9 as u32 >> 0u32 & 1) << 6 | (x9 as u32 >> 1u32 & 1) << 7 | (x9 as u32 >> 2u32 & 1) << 8 | (x9 as u32 >> 3u32 & 1) << 9 | (x9 as u32 >> 4u32 & 1) << 10)
{}

// Coefficient `8 g + 6` of ByteDecode_11 of the bytes from `bo` in `b`.
@constant_time
fn dec11_coeff6(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 352 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 11, 8 * g as int + 6) && r.value() < 2048
{
    let x8 = b[bo + 11 * g + 8];
    let x9 = b[bo + 11 * g + 9];
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 6) + 0, (bo + 11 * g + 8) as int, 2);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 6) + 1, (bo + 11 * g + 8) as int, 3);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 6) + 2, (bo + 11 * g + 8) as int, 4);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 6) + 3, (bo + 11 * g + 8) as int, 5);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 6) + 4, (bo + 11 * g + 8) as int, 6);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 6) + 5, (bo + 11 * g + 8) as int, 7);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 6) + 6, (bo + 11 * g + 9) as int, 0);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 6) + 7, (bo + 11 * g + 9) as int, 1);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 6) + 8, (bo + 11 * g + 9) as int, 2);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 6) + 9, (bo + 11 * g + 9) as int, 3);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 6) + 10, (bo + 11 * g + 9) as int, 4);
    dec11_bits6(x8.value(), x9.value());
    return x8.cast::<u32>() >> 2 & Secret::new(63u32) | (x9.cast::<u32>() & Secret::new(31u32)) << 6;
}

// Coefficient 7 of a group of ByteDecode_11 as the bits of the bytes that hold it.
lemma dec11_bits7(x9: u8, x10: u8)
    ensures (x9 as u32 >> 5u32 & 7u32 | x10 as u32 << 3u32) == (x9 as u32 >> 5u32 & 1 | (x9 as u32 >> 6u32 & 1) << 1 | (x9 as u32 >> 7u32 & 1) << 2 | (x10 as u32 >> 0u32 & 1) << 3 | (x10 as u32 >> 1u32 & 1) << 4 | (x10 as u32 >> 2u32 & 1) << 5 | (x10 as u32 >> 3u32 & 1) << 6 | (x10 as u32 >> 4u32 & 1) << 7 | (x10 as u32 >> 5u32 & 1) << 8 | (x10 as u32 >> 6u32 & 1) << 9 | (x10 as u32 >> 7u32 & 1) << 10)
{}

// Coefficient `8 g + 7` of ByteDecode_11 of the bytes from `bo` in `b`.
@constant_time
fn dec11_coeff7(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 32 && bo as int + 352 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 11, 8 * g as int + 7) && r.value() < 2048
{
    let x9 = b[bo + 11 * g + 9];
    let x10 = b[bo + 11 * g + 10];
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 7) + 0, (bo + 11 * g + 9) as int, 5);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 7) + 1, (bo + 11 * g + 9) as int, 6);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 7) + 2, (bo + 11 * g + 9) as int, 7);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 7) + 3, (bo + 11 * g + 10) as int, 0);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 7) + 4, (bo + 11 * g + 10) as int, 1);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 7) + 5, (bo + 11 * g + 10) as int, 2);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 7) + 6, (bo + 11 * g + 10) as int, 3);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 7) + 7, (bo + 11 * g + 10) as int, 4);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 7) + 8, (bo + 11 * g + 10) as int, 5);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 7) + 9, (bo + 11 * g + 10) as int, 6);
    bbit_at(b.view(), bo as int, 11 * (8 * g as int + 7) + 10, (bo + 11 * g + 10) as int, 7);
    dec11_bits7(x9.value(), x10.value());
    return x9.cast::<u32>() >> 5 & Secret::new(7u32) | x10.cast::<u32>() << 3;
}

// Coefficients `8 g + 0` to `8 g + 3` of ByteDecode_11 of the bytes from `bo` in `b` into the polynomial at `fo` in `f`.
@constant_time
fn dec11_part0(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, bo: usize, g: usize)
    requires g < 32 && fo as int + 256 <= f.len() as int && bo as int + 352 <= b.len() as int && reduced(f.view())
    requires below_from(f.view(), fo as int, fo as int + 8 * g as int + 0, 2048)
    ensures f.len() == old(f.len()) && reduced(f.view())
    ensures below_from(f.view(), fo as int, fo as int + 8 * g as int + 4, 2048)
    ensures decoded(old(f.view()), fo as int, b.view(), bo as int, 11, 8 * g as int + 0) == decoded(
        f.view(),
        fo as int,
        b.view(),
        bo as int,
        11,
        8 * g as int + 4,
    )
{
    ghost let h0 = f.view();
    let r0 = dec11_coeff0(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 0) as int, r0);
    below_push(f.view(), fo as int, (fo + 8 * g + 0) as int, 2048, r0);
    f[fo + 8 * g + 0] = r0;
    decoded_next(h0, fo as int, b.view(), bo as int, 11, 8 * g as int + 0, r0, f.view());
    ghost let h1 = f.view();
    let r1 = dec11_coeff1(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 1) as int, r1);
    below_push(f.view(), fo as int, (fo + 8 * g + 1) as int, 2048, r1);
    f[fo + 8 * g + 1] = r1;
    decoded_next(h1, fo as int, b.view(), bo as int, 11, 8 * g as int + 1, r1, f.view());
    ghost let h2 = f.view();
    let r2 = dec11_coeff2(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 2) as int, r2);
    below_push(f.view(), fo as int, (fo + 8 * g + 2) as int, 2048, r2);
    f[fo + 8 * g + 2] = r2;
    decoded_next(h2, fo as int, b.view(), bo as int, 11, 8 * g as int + 2, r2, f.view());
    ghost let h3 = f.view();
    let r3 = dec11_coeff3(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 3) as int, r3);
    below_push(f.view(), fo as int, (fo + 8 * g + 3) as int, 2048, r3);
    f[fo + 8 * g + 3] = r3;
    decoded_next(h3, fo as int, b.view(), bo as int, 11, 8 * g as int + 3, r3, f.view());
}

// Coefficients `8 g + 4` to `8 g + 7` of ByteDecode_11 of the bytes from `bo` in `b` into the polynomial at `fo` in `f`.
@constant_time
fn dec11_part4(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, bo: usize, g: usize)
    requires g < 32 && fo as int + 256 <= f.len() as int && bo as int + 352 <= b.len() as int && reduced(f.view())
    requires below_from(f.view(), fo as int, fo as int + 8 * g as int + 4, 2048)
    ensures f.len() == old(f.len()) && reduced(f.view())
    ensures below_from(f.view(), fo as int, fo as int + 8 * g as int + 8, 2048)
    ensures decoded(old(f.view()), fo as int, b.view(), bo as int, 11, 8 * g as int + 4) == decoded(
        f.view(),
        fo as int,
        b.view(),
        bo as int,
        11,
        8 * g as int + 8,
    )
{
    ghost let h4 = f.view();
    let r4 = dec11_coeff4(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 4) as int, r4);
    below_push(f.view(), fo as int, (fo + 8 * g + 4) as int, 2048, r4);
    f[fo + 8 * g + 4] = r4;
    decoded_next(h4, fo as int, b.view(), bo as int, 11, 8 * g as int + 4, r4, f.view());
    ghost let h5 = f.view();
    let r5 = dec11_coeff5(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 5) as int, r5);
    below_push(f.view(), fo as int, (fo + 8 * g + 5) as int, 2048, r5);
    f[fo + 8 * g + 5] = r5;
    decoded_next(h5, fo as int, b.view(), bo as int, 11, 8 * g as int + 5, r5, f.view());
    ghost let h6 = f.view();
    let r6 = dec11_coeff6(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 6) as int, r6);
    below_push(f.view(), fo as int, (fo + 8 * g + 6) as int, 2048, r6);
    f[fo + 8 * g + 6] = r6;
    decoded_next(h6, fo as int, b.view(), bo as int, 11, 8 * g as int + 6, r6, f.view());
    ghost let h7 = f.view();
    let r7 = dec11_coeff7(b, bo, g);
    reduced_update(f.view(), (fo + 8 * g + 7) as int, r7);
    below_push(f.view(), fo as int, (fo + 8 * g + 7) as int, 2048, r7);
    f[fo + 8 * g + 7] = r7;
    decoded_next(h7, fo as int, b.view(), bo as int, 11, 8 * g as int + 7, r7, f.view());
}

// ByteDecode_11 of the bytes from `bo` in `b` into the polynomial at `fo` in `f`.
@constant_time
fn decode11(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, bo: usize)
    requires fo as int + 256 <= f.len() as int && bo as int + 352 <= b.len() as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == decoded(
        old(f.view()),
        fo as int,
        b.view(),
        bo as int,
        11,
        0,
    )
    ensures below_from(f.view(), fo as int, fo as int + 256, 2048)
{
    for g in 0usize..32
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant below_from(f.view(), fo as int, fo as int + 8 * g as int, 2048)
        invariant decoded(f.view(), fo as int, b.view(), bo as int, 11, 8 * g as int) == decoded(
            old(f.view()),
            fo as int,
            b.view(),
            bo as int,
            11,
            0,
        )
    {
        dec11_part0(f, fo, b, bo, g);
        dec11_part4(f, fo, b, bo, g);
    }
    assert decoded(f.view(), fo as int, b.view(), bo as int, 11, 256) == f.view() by {};
}

// Coefficient 0 of a group of ByteDecode_12 as the bits of the bytes that hold it.
lemma dec12_bits0(x0: u8, x1: u8)
    ensures (x0 as u32 | (x1 as u32 & 15u32) << 8u32) == (x0 as u32 >> 0u32 & 1 | (x0 as u32 >> 1u32 & 1) << 1 | (x0 as u32 >> 2u32 & 1) << 2 | (x0 as u32 >> 3u32 & 1) << 3 | (x0 as u32 >> 4u32 & 1) << 4 | (x0 as u32 >> 5u32 & 1) << 5 | (x0 as u32 >> 6u32 & 1) << 6 | (x0 as u32 >> 7u32 & 1) << 7 | (x1 as u32 >> 0u32 & 1) << 8 | (x1 as u32 >> 1u32 & 1) << 9 | (x1 as u32 >> 2u32 & 1) << 10 | (x1 as u32 >> 3u32 & 1) << 11)
{}

// Coefficient `2 g + 0` of ByteDecode_12 of the bytes from `bo` in `b`.
@constant_time
fn dec12_coeff0(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 128 && bo as int + 384 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 12, 2 * g as int + 0) && r.value() < 3329
{
    let x0 = b[bo + 3 * g + 0];
    let x1 = b[bo + 3 * g + 1];
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 0) + 0, (bo + 3 * g + 0) as int, 0);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 0) + 1, (bo + 3 * g + 0) as int, 1);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 0) + 2, (bo + 3 * g + 0) as int, 2);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 0) + 3, (bo + 3 * g + 0) as int, 3);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 0) + 4, (bo + 3 * g + 0) as int, 4);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 0) + 5, (bo + 3 * g + 0) as int, 5);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 0) + 6, (bo + 3 * g + 0) as int, 6);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 0) + 7, (bo + 3 * g + 0) as int, 7);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 0) + 8, (bo + 3 * g + 1) as int, 0);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 0) + 9, (bo + 3 * g + 1) as int, 1);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 0) + 10, (bo + 3 * g + 1) as int, 2);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 0) + 11, (bo + 3 * g + 1) as int, 3);
    dec12_bits0(x0.value(), x1.value());
    return mod_q12(x0.cast::<u32>() | (x1.cast::<u32>() & Secret::new(15u32)) << 8);
}

// Coefficient 1 of a group of ByteDecode_12 as the bits of the bytes that hold it.
lemma dec12_bits1(x1: u8, x2: u8)
    ensures (x1 as u32 >> 4u32 & 15u32 | x2 as u32 << 4u32) == (x1 as u32 >> 4u32 & 1 | (x1 as u32 >> 5u32 & 1) << 1 | (x1 as u32 >> 6u32 & 1) << 2 | (x1 as u32 >> 7u32 & 1) << 3 | (x2 as u32 >> 0u32 & 1) << 4 | (x2 as u32 >> 1u32 & 1) << 5 | (x2 as u32 >> 2u32 & 1) << 6 | (x2 as u32 >> 3u32 & 1) << 7 | (x2 as u32 >> 4u32 & 1) << 8 | (x2 as u32 >> 5u32 & 1) << 9 | (x2 as u32 >> 6u32 & 1) << 10 | (x2 as u32 >> 7u32 & 1) << 11)
{}

// Coefficient `2 g + 1` of ByteDecode_12 of the bytes from `bo` in `b`.
@constant_time
fn dec12_coeff1(b: []Secret<u8>, bo: usize, g: usize) Secret<u32>
    requires g < 128 && bo as int + 384 <= b.len() as int
    ensures |r| r.value() == dec_coeff(b.view(), bo as int, 12, 2 * g as int + 1) && r.value() < 3329
{
    let x1 = b[bo + 3 * g + 1];
    let x2 = b[bo + 3 * g + 2];
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 1) + 0, (bo + 3 * g + 1) as int, 4);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 1) + 1, (bo + 3 * g + 1) as int, 5);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 1) + 2, (bo + 3 * g + 1) as int, 6);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 1) + 3, (bo + 3 * g + 1) as int, 7);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 1) + 4, (bo + 3 * g + 2) as int, 0);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 1) + 5, (bo + 3 * g + 2) as int, 1);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 1) + 6, (bo + 3 * g + 2) as int, 2);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 1) + 7, (bo + 3 * g + 2) as int, 3);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 1) + 8, (bo + 3 * g + 2) as int, 4);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 1) + 9, (bo + 3 * g + 2) as int, 5);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 1) + 10, (bo + 3 * g + 2) as int, 6);
    bbit_at(b.view(), bo as int, 12 * (2 * g as int + 1) + 11, (bo + 3 * g + 2) as int, 7);
    dec12_bits1(x1.value(), x2.value());
    return mod_q12(x1.cast::<u32>() >> 4 & Secret::new(15u32) | x2.cast::<u32>() << 4);
}

// Coefficients `2 g + 0` to `2 g + 1` of ByteDecode_12 of the bytes from `bo` in `b` into the polynomial at `fo` in `f`.
@constant_time
fn dec12_part0(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, bo: usize, g: usize)
    requires g < 128 && fo as int + 256 <= f.len() as int && bo as int + 384 <= b.len() as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view())
    ensures decoded(old(f.view()), fo as int, b.view(), bo as int, 12, 2 * g as int + 0) == decoded(
        f.view(),
        fo as int,
        b.view(),
        bo as int,
        12,
        2 * g as int + 2,
    )
{
    ghost let h0 = f.view();
    let r0 = dec12_coeff0(b, bo, g);
    reduced_update(f.view(), (fo + 2 * g + 0) as int, r0);
    f[fo + 2 * g + 0] = r0;
    decoded_next(h0, fo as int, b.view(), bo as int, 12, 2 * g as int + 0, r0, f.view());
    ghost let h1 = f.view();
    let r1 = dec12_coeff1(b, bo, g);
    reduced_update(f.view(), (fo + 2 * g + 1) as int, r1);
    f[fo + 2 * g + 1] = r1;
    decoded_next(h1, fo as int, b.view(), bo as int, 12, 2 * g as int + 1, r1, f.view());
}

// ByteDecode_12 of the bytes from `bo` in `b` into the polynomial at `fo` in `f`.
@constant_time
fn decode12(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, bo: usize)
    requires fo as int + 256 <= f.len() as int && bo as int + 384 <= b.len() as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == decoded(
        old(f.view()),
        fo as int,
        b.view(),
        bo as int,
        12,
        0,
    )
{
    for g in 0usize..128
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant decoded(f.view(), fo as int, b.view(), bo as int, 12, 2 * g as int) == decoded(
            old(f.view()),
            fo as int,
            b.view(),
            bo as int,
            12,
            0,
        )
    {
        dec12_part0(f, fo, b, bo, g);
    }
    assert decoded(f.view(), fo as int, b.view(), bo as int, 12, 256) == f.view() by {};
}

// 2^d for the `d` of the ML-KEM parameter sets (1, 4, 5, 10 and 11); 1 for another.
spec fn two_pow(d: int) int {
    return if d == 1 {
        2
    } else if d == 4 {
        16
    } else if d == 5 {
        32
    } else if d == 10 {
        1024
    } else if d == 11 {
        2048
    } else {
        1
    };
}

/// Compress_d(x) (FIPS 203, (4.7)): the rounding of `2^d x / q` (`(2^(d + 1) x + q) / 2q` rounded down)
/// modulo 2^d.
pub spec fn compress(d: int, x: u32) int {
    return (x as int * 2 * two_pow(d) + 3329) / 6658 % two_pow(d);
}

/// Decompress_d(y) (FIPS 203, (4.8)): the rounding of `q y / 2^d` (`(2 q y + 2^d) / 2^(d + 1)` rounded
/// down).
pub spec fn decompress(d: int, y: u32) int {
    return (6658 * y as int + two_pow(d)) / (2 * two_pow(d));
}

// Coefficients `c` to 255 of the polynomial at `o` in `f` compressed (`dec`: decompressed) with `d` bits.
spec fn compressed(f: Seq<Secret<u32>>, o: int, d: int, dec: bool, c: int) Seq<Secret<u32>>
    decreases 256 - c
{
    return if c >= 256 || c < 0 || o < 0 || o + 256 > f.len() {
        f
    } else if dec {
        compressed(f.update(o + c, Secret::new(decompress(d, f[o + c].value()) as u32)), o, d, dec, c + 1)
    } else {
        compressed(f.update(o + c, Secret::new(compress(d, f[o + c].value()) as u32)), o, d, dec, c + 1)
    };
}

// `compressed` as a step.
lemma compressed_next(f: Seq<Secret<u32>>, o: int, d: int, dec: bool, c: int, x: Secret<u32>, h: Seq<Secret<u32>>)
    requires 0 <= c && c < 256 && 0 <= o && o + 256 <= f.len()
    requires dec ==> x.value() == decompress(d, f[o + c].value()) as u32
    requires !dec ==> x.value() == compress(d, f[o + c].value()) as u32
    requires h == f.update(o + c, x)
    ensures compressed(f, o, d, dec, c) == compressed(h, o, d, dec, c + 1)
{}

// The quotient `t` of `y` below 2^24 by 2q: `y * 41285358 >> 38`.
lemma div_2q(y: int, t: int)
    requires 0 <= y && y < 0x1000000
    requires t * 0x4000000000 <= y * 41285358 && y * 41285358 < (t + 1) * 0x4000000000
    ensures t == y / 6658
{
    arith::mod_unique(y, t, y - 6658 * t, 6658);
}

// Compress_1(x) for `x` below q.
@constant_time
fn compress1(x: Secret<u32>) Secret<u32>
    requires x.value() < 3329
    ensures |r| r.value() as int == compress(1, x.value()) && r.value() == compress(1, x.value()) as u32 && r.value() < 2
{
    let y = (x.cast::<u64>() << 2) + Secret::new(3329u64);
    assert y.value() as int == x.value() as int * 4 + 3329 by {};
    let t = y * Secret::new(41285358u64) >> 38;
    div_2q(y.value() as int, t.value() as int);
    mask1(t.value());
    return (t & Secret::new(1u64)).cast::<u32>();
}

// A mask of the low 1 bits is the remainder by 2^1.
lemma mask1(t: u64)
    ensures (t & 1u64) == t % 2u64
{}

// Decompress_1(y) for `y` below 2^1.
@constant_time
fn decompress1(y: Secret<u32>) Secret<u32>
    requires y.value() < 2
    ensures |r| r.value() as int == decompress(1, y.value()) && r.value() == decompress(1, y.value()) as u32 && r.value() < 3329
{
    return (y.cast::<u64>() * Secret::new(3329u64) + Secret::new(1u64) >> 1).cast::<u32>();
}

// Compresses the polynomial at `o` in `f` with 1 bits, in place.
@constant_time
fn compress_poly1(f: []mut Secret<u32>, o: usize)
    requires o as int + 256 <= f.len() as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == compressed(old(f.view()), o as int, 1, false, 0)
{
    for c in 0usize..256
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant compressed(f.view(), o as int, 1, false, c as int) == compressed(old(f.view()), o as int, 1, false, 0)
    {
        ghost let f0 = f.view();
        let x = compress1(f[o + c]);
        reduced_update(f.view(), (o + c) as int, x);
        f[o + c] = x;
        compressed_next(f0, o as int, 1, false, c as int, x, f.view());
    }
    assert compressed(f.view(), o as int, 1, false, 256) == f.view() by {};
}

// Decompresses the polynomial at `o` in `f` of 1-bit coefficients, in place.
@constant_time
fn decompress_poly1(f: []mut Secret<u32>, o: usize)
    requires o as int + 256 <= f.len() as int && reduced(f.view())
    requires below_from(f.view(), o as int, o as int + 256, 2)
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == compressed(old(f.view()), o as int, 1, true, 0)
{
    for c in 0usize..256
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant below_from(f.view(), o as int + c as int, o as int + 256, 2)
        invariant compressed(f.view(), o as int, 1, true, c as int) == compressed(old(f.view()), o as int, 1, true, 0)
    {
        ghost let f0 = f.view();
        let x = decompress1(f[o + c]);
        below_update(f.view(), o as int + c as int, o as int + 256, 2, x);
        reduced_update(f.view(), (o + c) as int, x);
        f[o + c] = x;
        compressed_next(f0, o as int, 1, true, c as int, x, f.view());
    }
    assert compressed(f.view(), o as int, 1, true, 256) == f.view() by {};
}

// Compress_4(x) for `x` below q.
@constant_time
fn compress4(x: Secret<u32>) Secret<u32>
    requires x.value() < 3329
    ensures |r| r.value() as int == compress(4, x.value()) && r.value() == compress(4, x.value()) as u32 && r.value() < 16
{
    let y = (x.cast::<u64>() << 5) + Secret::new(3329u64);
    assert y.value() as int == x.value() as int * 32 + 3329 by {};
    let t = y * Secret::new(41285358u64) >> 38;
    div_2q(y.value() as int, t.value() as int);
    mask4(t.value());
    return (t & Secret::new(15u64)).cast::<u32>();
}

// A mask of the low 4 bits is the remainder by 2^4.
lemma mask4(t: u64)
    ensures (t & 15u64) == t % 16u64
{}

// Decompress_4(y) for `y` below 2^4.
@constant_time
fn decompress4(y: Secret<u32>) Secret<u32>
    requires y.value() < 16
    ensures |r| r.value() as int == decompress(4, y.value()) && r.value() == decompress(4, y.value()) as u32 && r.value() < 3329
{
    return (y.cast::<u64>() * Secret::new(3329u64) + Secret::new(8u64) >> 4).cast::<u32>();
}

// Compresses the polynomial at `o` in `f` with 4 bits, in place.
@constant_time
fn compress_poly4(f: []mut Secret<u32>, o: usize)
    requires o as int + 256 <= f.len() as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == compressed(old(f.view()), o as int, 4, false, 0)
{
    for c in 0usize..256
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant compressed(f.view(), o as int, 4, false, c as int) == compressed(old(f.view()), o as int, 4, false, 0)
    {
        ghost let f0 = f.view();
        let x = compress4(f[o + c]);
        reduced_update(f.view(), (o + c) as int, x);
        f[o + c] = x;
        compressed_next(f0, o as int, 4, false, c as int, x, f.view());
    }
    assert compressed(f.view(), o as int, 4, false, 256) == f.view() by {};
}

// Decompresses the polynomial at `o` in `f` of 4-bit coefficients, in place.
@constant_time
fn decompress_poly4(f: []mut Secret<u32>, o: usize)
    requires o as int + 256 <= f.len() as int && reduced(f.view())
    requires below_from(f.view(), o as int, o as int + 256, 16)
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == compressed(old(f.view()), o as int, 4, true, 0)
{
    for c in 0usize..256
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant below_from(f.view(), o as int + c as int, o as int + 256, 16)
        invariant compressed(f.view(), o as int, 4, true, c as int) == compressed(old(f.view()), o as int, 4, true, 0)
    {
        ghost let f0 = f.view();
        let x = decompress4(f[o + c]);
        below_update(f.view(), o as int + c as int, o as int + 256, 16, x);
        reduced_update(f.view(), (o + c) as int, x);
        f[o + c] = x;
        compressed_next(f0, o as int, 4, true, c as int, x, f.view());
    }
    assert compressed(f.view(), o as int, 4, true, 256) == f.view() by {};
}

// Compress_5(x) for `x` below q.
@constant_time
fn compress5(x: Secret<u32>) Secret<u32>
    requires x.value() < 3329
    ensures |r| r.value() as int == compress(5, x.value()) && r.value() == compress(5, x.value()) as u32 && r.value() < 32
{
    let y = (x.cast::<u64>() << 6) + Secret::new(3329u64);
    assert y.value() as int == x.value() as int * 64 + 3329 by {};
    let t = y * Secret::new(41285358u64) >> 38;
    div_2q(y.value() as int, t.value() as int);
    mask5(t.value());
    return (t & Secret::new(31u64)).cast::<u32>();
}

// A mask of the low 5 bits is the remainder by 2^5.
lemma mask5(t: u64)
    ensures (t & 31u64) == t % 32u64
{}

// Decompress_5(y) for `y` below 2^5.
@constant_time
fn decompress5(y: Secret<u32>) Secret<u32>
    requires y.value() < 32
    ensures |r| r.value() as int == decompress(5, y.value()) && r.value() == decompress(5, y.value()) as u32 && r.value() < 3329
{
    return (y.cast::<u64>() * Secret::new(3329u64) + Secret::new(16u64) >> 5).cast::<u32>();
}

// Compresses the polynomial at `o` in `f` with 5 bits, in place.
@constant_time
fn compress_poly5(f: []mut Secret<u32>, o: usize)
    requires o as int + 256 <= f.len() as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == compressed(old(f.view()), o as int, 5, false, 0)
{
    for c in 0usize..256
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant compressed(f.view(), o as int, 5, false, c as int) == compressed(old(f.view()), o as int, 5, false, 0)
    {
        ghost let f0 = f.view();
        let x = compress5(f[o + c]);
        reduced_update(f.view(), (o + c) as int, x);
        f[o + c] = x;
        compressed_next(f0, o as int, 5, false, c as int, x, f.view());
    }
    assert compressed(f.view(), o as int, 5, false, 256) == f.view() by {};
}

// Decompresses the polynomial at `o` in `f` of 5-bit coefficients, in place.
@constant_time
fn decompress_poly5(f: []mut Secret<u32>, o: usize)
    requires o as int + 256 <= f.len() as int && reduced(f.view())
    requires below_from(f.view(), o as int, o as int + 256, 32)
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == compressed(old(f.view()), o as int, 5, true, 0)
{
    for c in 0usize..256
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant below_from(f.view(), o as int + c as int, o as int + 256, 32)
        invariant compressed(f.view(), o as int, 5, true, c as int) == compressed(old(f.view()), o as int, 5, true, 0)
    {
        ghost let f0 = f.view();
        let x = decompress5(f[o + c]);
        below_update(f.view(), o as int + c as int, o as int + 256, 32, x);
        reduced_update(f.view(), (o + c) as int, x);
        f[o + c] = x;
        compressed_next(f0, o as int, 5, true, c as int, x, f.view());
    }
    assert compressed(f.view(), o as int, 5, true, 256) == f.view() by {};
}

// Compress_10(x) for `x` below q.
@constant_time
fn compress10(x: Secret<u32>) Secret<u32>
    requires x.value() < 3329
    ensures |r| r.value() as int == compress(10, x.value()) && r.value() == compress(10, x.value()) as u32 && r.value() < 1024
{
    let y = (x.cast::<u64>() << 11) + Secret::new(3329u64);
    assert y.value() as int == x.value() as int * 2048 + 3329 by {};
    let t = y * Secret::new(41285358u64) >> 38;
    div_2q(y.value() as int, t.value() as int);
    mask10(t.value());
    return (t & Secret::new(1023u64)).cast::<u32>();
}

// A mask of the low 10 bits is the remainder by 2^10.
lemma mask10(t: u64)
    ensures (t & 1023u64) == t % 1024u64
{}

// Decompress_10(y) for `y` below 2^10.
@constant_time
fn decompress10(y: Secret<u32>) Secret<u32>
    requires y.value() < 1024
    ensures |r| r.value() as int == decompress(10, y.value()) && r.value() == decompress(10, y.value()) as u32 && r.value() < 3329
{
    return (y.cast::<u64>() * Secret::new(3329u64) + Secret::new(512u64) >> 10).cast::<u32>();
}

// Compresses the polynomial at `o` in `f` with 10 bits, in place.
@constant_time
fn compress_poly10(f: []mut Secret<u32>, o: usize)
    requires o as int + 256 <= f.len() as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == compressed(
        old(f.view()),
        o as int,
        10,
        false,
        0,
    )
{
    for c in 0usize..256
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant compressed(f.view(), o as int, 10, false, c as int) == compressed(
            old(f.view()),
            o as int,
            10,
            false,
            0,
        )
    {
        ghost let f0 = f.view();
        let x = compress10(f[o + c]);
        reduced_update(f.view(), (o + c) as int, x);
        f[o + c] = x;
        compressed_next(f0, o as int, 10, false, c as int, x, f.view());
    }
    assert compressed(f.view(), o as int, 10, false, 256) == f.view() by {};
}

// Decompresses the polynomial at `o` in `f` of 10-bit coefficients, in place.
@constant_time
fn decompress_poly10(f: []mut Secret<u32>, o: usize)
    requires o as int + 256 <= f.len() as int && reduced(f.view())
    requires below_from(f.view(), o as int, o as int + 256, 1024)
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == compressed(old(f.view()), o as int, 10, true, 0)
{
    for c in 0usize..256
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant below_from(f.view(), o as int + c as int, o as int + 256, 1024)
        invariant compressed(f.view(), o as int, 10, true, c as int) == compressed(old(f.view()), o as int, 10, true, 0)
    {
        ghost let f0 = f.view();
        let x = decompress10(f[o + c]);
        below_update(f.view(), o as int + c as int, o as int + 256, 1024, x);
        reduced_update(f.view(), (o + c) as int, x);
        f[o + c] = x;
        compressed_next(f0, o as int, 10, true, c as int, x, f.view());
    }
    assert compressed(f.view(), o as int, 10, true, 256) == f.view() by {};
}

// Compress_11(x) for `x` below q.
@constant_time
fn compress11(x: Secret<u32>) Secret<u32>
    requires x.value() < 3329
    ensures |r| r.value() as int == compress(11, x.value()) && r.value() == compress(11, x.value()) as u32 && r.value() < 2048
{
    let y = (x.cast::<u64>() << 12) + Secret::new(3329u64);
    assert y.value() as int == x.value() as int * 4096 + 3329 by {};
    let t = y * Secret::new(41285358u64) >> 38;
    div_2q(y.value() as int, t.value() as int);
    mask11(t.value());
    return (t & Secret::new(2047u64)).cast::<u32>();
}

// A mask of the low 11 bits is the remainder by 2^11.
lemma mask11(t: u64)
    ensures (t & 2047u64) == t % 2048u64
{}

// Decompress_11(y) for `y` below 2^11.
@constant_time
fn decompress11(y: Secret<u32>) Secret<u32>
    requires y.value() < 2048
    ensures |r| r.value() as int == decompress(11, y.value()) && r.value() == decompress(11, y.value()) as u32 && r.value() < 3329
{
    return (y.cast::<u64>() * Secret::new(3329u64) + Secret::new(1024u64) >> 11).cast::<u32>();
}

// Compresses the polynomial at `o` in `f` with 11 bits, in place.
@constant_time
fn compress_poly11(f: []mut Secret<u32>, o: usize)
    requires o as int + 256 <= f.len() as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == compressed(
        old(f.view()),
        o as int,
        11,
        false,
        0,
    )
{
    for c in 0usize..256
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant compressed(f.view(), o as int, 11, false, c as int) == compressed(
            old(f.view()),
            o as int,
            11,
            false,
            0,
        )
    {
        ghost let f0 = f.view();
        let x = compress11(f[o + c]);
        reduced_update(f.view(), (o + c) as int, x);
        f[o + c] = x;
        compressed_next(f0, o as int, 11, false, c as int, x, f.view());
    }
    assert compressed(f.view(), o as int, 11, false, 256) == f.view() by {};
}

// Decompresses the polynomial at `o` in `f` of 11-bit coefficients, in place.
@constant_time
fn decompress_poly11(f: []mut Secret<u32>, o: usize)
    requires o as int + 256 <= f.len() as int && reduced(f.view())
    requires below_from(f.view(), o as int, o as int + 256, 2048)
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == compressed(old(f.view()), o as int, 11, true, 0)
{
    for c in 0usize..256
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant below_from(f.view(), o as int + c as int, o as int + 256, 2048)
        invariant compressed(f.view(), o as int, 11, true, c as int) == compressed(old(f.view()), o as int, 11, true, 0)
    {
        ghost let f0 = f.view();
        let x = decompress11(f[o + c]);
        below_update(f.view(), o as int + c as int, o as int + 256, 2048, x);
        reduced_update(f.view(), (o + c) as int, x);
        f[o + c] = x;
        compressed_next(f0, o as int, 11, true, c as int, x, f.view());
    }
    assert compressed(f.view(), o as int, 11, true, 256) == f.view() by {};
}

// Bit `n` of the bit array FIPS 203, Algorithm 5 makes of the polynomial at `fo` in `f` with `d`-bit
// coefficients: bit `n % d` of coefficient `n / d` (lines 4 and 5 take the coefficient's bits from the
// lowest).
spec fn fbit(f: Seq<Secret<u32>>, fo: int, d: int, n: int) u32 {
    return if d < 1 || d > 12 || n < 0 || fo < 0 || fo + n / d >= f.len() {
        0
    } else {
        f[fo + n / d].value() >> (n % d) as u32 & 1
    };
}

/// Byte `m` of ByteEncode_d of the polynomial at `fo` in `f` (FIPS 203, Algorithms 5 and 3): bits `8 m`
/// to `8 m + 7` of the bit array, the first the lowest (Algorithm 3 adds their distinct powers of 2: their
/// OR).
pub spec fn enc_byte(f: Seq<Secret<u32>>, fo: int, d: int, m: int) u32 {
    return fbit(f, fo, d, 8 * m) | fbit(f, fo, d, 8 * m + 1) << 1 | fbit(f, fo, d, 8 * m + 2) << 2 | fbit(
        f,
        fo,
        d,
        8 * m + 3,
    ) << 3 | fbit(f, fo, d, 8 * m + 4) << 4 | fbit(f, fo, d, 8 * m + 5) << 5 | fbit(f, fo, d, 8 * m + 6) << 6 | fbit(
        f,
        fo,
        d,
        8 * m + 7,
    ) << 7;
}

// Bytes `m` to `32 d - 1` of `out` from `oo` on set to those of ByteEncode_d of the polynomial at `fo` in
// `f`.
spec fn encoded(out: Seq<Secret<u8>>, oo: int, f: Seq<Secret<u32>>, fo: int, d: int, m: int) Seq<Secret<u8>>
    decreases 32 * d - m
{
    return if m >= 32 * d || m < 0 || oo < 0 || oo + 32 * d > out.len() {
        out
    } else {
        encoded(out.update(oo + m, Secret::new(enc_byte(f, fo, d, m) as u8)), oo, f, fo, d, m + 1)
    };
}

// `encoded` as a step.
lemma encoded_next(
    out: Seq<Secret<u8>>,
    oo: int,
    f: Seq<Secret<u32>>,
    fo: int,
    d: int,
    m: int,
    x: Secret<u8>,
    h: Seq<Secret<u8>>,
)
    requires 0 <= m && m < 32 * d && 0 <= oo && oo + 32 * d <= out.len()
    requires x.value() == enc_byte(f, fo, d, m) as u8 && h == out.update(oo + m, x)
    ensures encoded(out, oo, f, fo, d, m) == encoded(h, oo, f, fo, d, m + 1)
{}

// Bit `n` of the bit array is bit `j` of the coefficient at `p` for `n == (p - fo) d + j`.
lemma fbit_at(f: Seq<Secret<u32>>, fo: int, d: int, n: int, p: int, j: int)
    requires 1 <= d && d <= 12 && 0 <= j && j < d && 0 <= fo && fo <= p && p < f.len() && n == (p - fo) * d + j
    ensures fbit(f, fo, d, n) == (f[p].value() >> j as u32 & 1)
{
    arith::mod_unique(n, p - fo, j, d);
    fbit_eq(f, fo, d, n, p, j);
}

// `fbit_at` from the quotient and the remainder.
lemma fbit_eq(f: Seq<Secret<u32>>, fo: int, d: int, n: int, p: int, j: int)
    requires 1 <= d && d <= 12 && 0 <= j && j < d && 0 <= fo && fo <= p && p < f.len() && n / d == p - fo && n % d == j && n >= 0
    ensures fbit(f, fo, d, n) == (f[p].value() >> j as u32 & 1)
{
    assert fo + n / d == p by {};
}

// Byte 0 of a group of ByteEncode_1 as the bits of the coefficients it holds.
lemma enc1_bits0(c0: u32, c1: u32, c2: u32, c3: u32, c4: u32, c5: u32, c6: u32, c7: u32)
    ensures (c0 & 1u32 | (c1 & 1u32) << 1u32 | (c2 & 1u32) << 2u32 | (c3 & 1u32) << 3u32 | (c4 & 1u32) << 4u32 | (c5 & 1u32) << 5u32 | (c6 & 1u32) << 6u32 | (c7 & 1u32) << 7u32) == (c0 >> 0u32 & 1 | (c1 >> 0u32 & 1) << 1 | (c2 >> 0u32 & 1) << 2 | (c3 >> 0u32 & 1) << 3 | (c4 >> 0u32 & 1) << 4 | (c5 >> 0u32 & 1) << 5 | (c6 >> 0u32 & 1) << 6 | (c7 >> 0u32 & 1) << 7)
{}

// Byte `1 g + 0` of ByteEncode_1 of the polynomial at `fo` in `f`.
@constant_time
fn enc1_byte0(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 32 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 1, 1 * g as int + 0) as u8
{
    let c0 = f[fo + 8 * g + 0];
    let c1 = f[fo + 8 * g + 1];
    let c2 = f[fo + 8 * g + 2];
    let c3 = f[fo + 8 * g + 3];
    let c4 = f[fo + 8 * g + 4];
    let c5 = f[fo + 8 * g + 5];
    let c6 = f[fo + 8 * g + 6];
    let c7 = f[fo + 8 * g + 7];
    fbit_at(f.view(), fo as int, 1, 8 * (1 * g as int + 0) + 0, (fo + 8 * g + 0) as int, 0);
    fbit_at(f.view(), fo as int, 1, 8 * (1 * g as int + 0) + 1, (fo + 8 * g + 1) as int, 0);
    fbit_at(f.view(), fo as int, 1, 8 * (1 * g as int + 0) + 2, (fo + 8 * g + 2) as int, 0);
    fbit_at(f.view(), fo as int, 1, 8 * (1 * g as int + 0) + 3, (fo + 8 * g + 3) as int, 0);
    fbit_at(f.view(), fo as int, 1, 8 * (1 * g as int + 0) + 4, (fo + 8 * g + 4) as int, 0);
    fbit_at(f.view(), fo as int, 1, 8 * (1 * g as int + 0) + 5, (fo + 8 * g + 5) as int, 0);
    fbit_at(f.view(), fo as int, 1, 8 * (1 * g as int + 0) + 6, (fo + 8 * g + 6) as int, 0);
    fbit_at(f.view(), fo as int, 1, 8 * (1 * g as int + 0) + 7, (fo + 8 * g + 7) as int, 0);
    enc1_bits0(c0.value(), c1.value(), c2.value(), c3.value(), c4.value(), c5.value(), c6.value(), c7.value());
    return (c0 & Secret::new(1u32) | (c1 & Secret::new(1u32)) << 1 | (c2 & Secret::new(1u32)) << 2 | (c3 & Secret::new(
        1u32,
    )) << 3 | (c4 & Secret::new(1u32)) << 4 | (c5 & Secret::new(1u32)) << 5 | (c6 & Secret::new(1u32)) << 6 | (c7 & Secret::new(
        1u32,
    )) << 7).cast::<u8>();
}

// Bytes `1 g + 0` to `1 g + 0` of ByteEncode_1 of the polynomial at `fo` in `f` into `out` from `oo` on.
@constant_time
fn enc1_part0(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, fo: usize, g: usize)
    requires g < 32 && oo as int + 32 <= out.len() as int && fo as int + 256 <= f.len() as int
    ensures out.len() == old(out.len())
    ensures encoded(old(out.view()), oo as int, f.view(), fo as int, 1, 1 * g as int + 0) == encoded(
        out.view(),
        oo as int,
        f.view(),
        fo as int,
        1,
        1 * g as int + 1,
    )
{
    ghost let o0 = out.view();
    let r0 = enc1_byte0(f, fo, g);
    out[oo + 1 * g + 0] = r0;
    encoded_next(o0, oo as int, f.view(), fo as int, 1, 1 * g as int + 0, r0, out.view());
}

// ByteEncode_1 of the polynomial at `fo` in `f` into `out` from `oo` on.
@constant_time
fn encode1(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, fo: usize)
    requires oo as int + 32 <= out.len() as int && fo as int + 256 <= f.len() as int
    ensures out.len() == old(out.len()) && out.view() == encoded(old(out.view()), oo as int, f.view(), fo as int, 1, 0)
{
    for g in 0usize..32
        invariant out.len() == old(out.len()) && encoded(out.view(), oo as int, f.view(), fo as int, 1, 1 * g as int) == encoded(
            old(out.view()),
            oo as int,
            f.view(),
            fo as int,
            1,
            0,
        )
    {
        enc1_part0(out, oo, f, fo, g);
    }
    assert encoded(out.view(), oo as int, f.view(), fo as int, 1, 32) == out.view() by {};
}

// Byte 0 of a group of ByteEncode_4 as the bits of the coefficients it holds.
lemma enc4_bits0(c0: u32, c1: u32)
    ensures (c0 & 15u32 | (c1 & 15u32) << 4u32) == (c0 >> 0u32 & 1 | (c0 >> 1u32 & 1) << 1 | (c0 >> 2u32 & 1) << 2 | (c0 >> 3u32 & 1) << 3 | (c1 >> 0u32 & 1) << 4 | (c1 >> 1u32 & 1) << 5 | (c1 >> 2u32 & 1) << 6 | (c1 >> 3u32 & 1) << 7)
{}

// Byte `1 g + 0` of ByteEncode_4 of the polynomial at `fo` in `f`.
@constant_time
fn enc4_byte0(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 128 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 4, 1 * g as int + 0) as u8
{
    let c0 = f[fo + 2 * g + 0];
    let c1 = f[fo + 2 * g + 1];
    fbit_at(f.view(), fo as int, 4, 8 * (1 * g as int + 0) + 0, (fo + 2 * g + 0) as int, 0);
    fbit_at(f.view(), fo as int, 4, 8 * (1 * g as int + 0) + 1, (fo + 2 * g + 0) as int, 1);
    fbit_at(f.view(), fo as int, 4, 8 * (1 * g as int + 0) + 2, (fo + 2 * g + 0) as int, 2);
    fbit_at(f.view(), fo as int, 4, 8 * (1 * g as int + 0) + 3, (fo + 2 * g + 0) as int, 3);
    fbit_at(f.view(), fo as int, 4, 8 * (1 * g as int + 0) + 4, (fo + 2 * g + 1) as int, 0);
    fbit_at(f.view(), fo as int, 4, 8 * (1 * g as int + 0) + 5, (fo + 2 * g + 1) as int, 1);
    fbit_at(f.view(), fo as int, 4, 8 * (1 * g as int + 0) + 6, (fo + 2 * g + 1) as int, 2);
    fbit_at(f.view(), fo as int, 4, 8 * (1 * g as int + 0) + 7, (fo + 2 * g + 1) as int, 3);
    enc4_bits0(c0.value(), c1.value());
    return (c0 & Secret::new(15u32) | (c1 & Secret::new(15u32)) << 4).cast::<u8>();
}

// Bytes `1 g + 0` to `1 g + 0` of ByteEncode_4 of the polynomial at `fo` in `f` into `out` from `oo` on.
@constant_time
fn enc4_part0(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, fo: usize, g: usize)
    requires g < 128 && oo as int + 128 <= out.len() as int && fo as int + 256 <= f.len() as int
    ensures out.len() == old(out.len())
    ensures encoded(old(out.view()), oo as int, f.view(), fo as int, 4, 1 * g as int + 0) == encoded(
        out.view(),
        oo as int,
        f.view(),
        fo as int,
        4,
        1 * g as int + 1,
    )
{
    ghost let o0 = out.view();
    let r0 = enc4_byte0(f, fo, g);
    out[oo + 1 * g + 0] = r0;
    encoded_next(o0, oo as int, f.view(), fo as int, 4, 1 * g as int + 0, r0, out.view());
}

// ByteEncode_4 of the polynomial at `fo` in `f` into `out` from `oo` on.
@constant_time
fn encode4(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, fo: usize)
    requires oo as int + 128 <= out.len() as int && fo as int + 256 <= f.len() as int
    ensures out.len() == old(out.len()) && out.view() == encoded(old(out.view()), oo as int, f.view(), fo as int, 4, 0)
{
    for g in 0usize..128
        invariant out.len() == old(out.len()) && encoded(out.view(), oo as int, f.view(), fo as int, 4, 1 * g as int) == encoded(
            old(out.view()),
            oo as int,
            f.view(),
            fo as int,
            4,
            0,
        )
    {
        enc4_part0(out, oo, f, fo, g);
    }
    assert encoded(out.view(), oo as int, f.view(), fo as int, 4, 128) == out.view() by {};
}

// Byte 0 of a group of ByteEncode_5 as the bits of the coefficients it holds.
lemma enc5_bits0(c0: u32, c1: u32)
    ensures (c0 & 31u32 | (c1 & 7u32) << 5u32) == (c0 >> 0u32 & 1 | (c0 >> 1u32 & 1) << 1 | (c0 >> 2u32 & 1) << 2 | (c0 >> 3u32 & 1) << 3 | (c0 >> 4u32 & 1) << 4 | (c1 >> 0u32 & 1) << 5 | (c1 >> 1u32 & 1) << 6 | (c1 >> 2u32 & 1) << 7)
{}

// Byte `5 g + 0` of ByteEncode_5 of the polynomial at `fo` in `f`.
@constant_time
fn enc5_byte0(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 32 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 5, 5 * g as int + 0) as u8
{
    let c0 = f[fo + 8 * g + 0];
    let c1 = f[fo + 8 * g + 1];
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 0) + 0, (fo + 8 * g + 0) as int, 0);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 0) + 1, (fo + 8 * g + 0) as int, 1);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 0) + 2, (fo + 8 * g + 0) as int, 2);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 0) + 3, (fo + 8 * g + 0) as int, 3);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 0) + 4, (fo + 8 * g + 0) as int, 4);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 0) + 5, (fo + 8 * g + 1) as int, 0);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 0) + 6, (fo + 8 * g + 1) as int, 1);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 0) + 7, (fo + 8 * g + 1) as int, 2);
    enc5_bits0(c0.value(), c1.value());
    return (c0 & Secret::new(31u32) | (c1 & Secret::new(7u32)) << 5).cast::<u8>();
}

// Byte 1 of a group of ByteEncode_5 as the bits of the coefficients it holds.
lemma enc5_bits1(c1: u32, c2: u32, c3: u32)
    ensures (c1 >> 3u32 & 3u32 | (c2 & 31u32) << 2u32 | (c3 & 1u32) << 7u32) == (c1 >> 3u32 & 1 | (c1 >> 4u32 & 1) << 1 | (c2 >> 0u32 & 1) << 2 | (c2 >> 1u32 & 1) << 3 | (c2 >> 2u32 & 1) << 4 | (c2 >> 3u32 & 1) << 5 | (c2 >> 4u32 & 1) << 6 | (c3 >> 0u32 & 1) << 7)
{}

// Byte `5 g + 1` of ByteEncode_5 of the polynomial at `fo` in `f`.
@constant_time
fn enc5_byte1(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 32 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 5, 5 * g as int + 1) as u8
{
    let c1 = f[fo + 8 * g + 1];
    let c2 = f[fo + 8 * g + 2];
    let c3 = f[fo + 8 * g + 3];
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 1) + 0, (fo + 8 * g + 1) as int, 3);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 1) + 1, (fo + 8 * g + 1) as int, 4);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 1) + 2, (fo + 8 * g + 2) as int, 0);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 1) + 3, (fo + 8 * g + 2) as int, 1);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 1) + 4, (fo + 8 * g + 2) as int, 2);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 1) + 5, (fo + 8 * g + 2) as int, 3);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 1) + 6, (fo + 8 * g + 2) as int, 4);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 1) + 7, (fo + 8 * g + 3) as int, 0);
    enc5_bits1(c1.value(), c2.value(), c3.value());
    return (c1 >> 3 & Secret::new(3u32) | (c2 & Secret::new(31u32)) << 2 | (c3 & Secret::new(1u32)) << 7).cast::<u8>();
}

// Byte 2 of a group of ByteEncode_5 as the bits of the coefficients it holds.
lemma enc5_bits2(c3: u32, c4: u32)
    ensures (c3 >> 1u32 & 15u32 | (c4 & 15u32) << 4u32) == (c3 >> 1u32 & 1 | (c3 >> 2u32 & 1) << 1 | (c3 >> 3u32 & 1) << 2 | (c3 >> 4u32 & 1) << 3 | (c4 >> 0u32 & 1) << 4 | (c4 >> 1u32 & 1) << 5 | (c4 >> 2u32 & 1) << 6 | (c4 >> 3u32 & 1) << 7)
{}

// Byte `5 g + 2` of ByteEncode_5 of the polynomial at `fo` in `f`.
@constant_time
fn enc5_byte2(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 32 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 5, 5 * g as int + 2) as u8
{
    let c3 = f[fo + 8 * g + 3];
    let c4 = f[fo + 8 * g + 4];
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 2) + 0, (fo + 8 * g + 3) as int, 1);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 2) + 1, (fo + 8 * g + 3) as int, 2);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 2) + 2, (fo + 8 * g + 3) as int, 3);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 2) + 3, (fo + 8 * g + 3) as int, 4);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 2) + 4, (fo + 8 * g + 4) as int, 0);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 2) + 5, (fo + 8 * g + 4) as int, 1);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 2) + 6, (fo + 8 * g + 4) as int, 2);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 2) + 7, (fo + 8 * g + 4) as int, 3);
    enc5_bits2(c3.value(), c4.value());
    return (c3 >> 1 & Secret::new(15u32) | (c4 & Secret::new(15u32)) << 4).cast::<u8>();
}

// Byte 3 of a group of ByteEncode_5 as the bits of the coefficients it holds.
lemma enc5_bits3(c4: u32, c5: u32, c6: u32)
    ensures (c4 >> 4u32 & 1u32 | (c5 & 31u32) << 1u32 | (c6 & 3u32) << 6u32) == (c4 >> 4u32 & 1 | (c5 >> 0u32 & 1) << 1 | (c5 >> 1u32 & 1) << 2 | (c5 >> 2u32 & 1) << 3 | (c5 >> 3u32 & 1) << 4 | (c5 >> 4u32 & 1) << 5 | (c6 >> 0u32 & 1) << 6 | (c6 >> 1u32 & 1) << 7)
{}

// Byte `5 g + 3` of ByteEncode_5 of the polynomial at `fo` in `f`.
@constant_time
fn enc5_byte3(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 32 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 5, 5 * g as int + 3) as u8
{
    let c4 = f[fo + 8 * g + 4];
    let c5 = f[fo + 8 * g + 5];
    let c6 = f[fo + 8 * g + 6];
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 3) + 0, (fo + 8 * g + 4) as int, 4);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 3) + 1, (fo + 8 * g + 5) as int, 0);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 3) + 2, (fo + 8 * g + 5) as int, 1);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 3) + 3, (fo + 8 * g + 5) as int, 2);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 3) + 4, (fo + 8 * g + 5) as int, 3);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 3) + 5, (fo + 8 * g + 5) as int, 4);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 3) + 6, (fo + 8 * g + 6) as int, 0);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 3) + 7, (fo + 8 * g + 6) as int, 1);
    enc5_bits3(c4.value(), c5.value(), c6.value());
    return (c4 >> 4 & Secret::new(1u32) | (c5 & Secret::new(31u32)) << 1 | (c6 & Secret::new(3u32)) << 6).cast::<u8>();
}

// Byte 4 of a group of ByteEncode_5 as the bits of the coefficients it holds.
lemma enc5_bits4(c6: u32, c7: u32)
    ensures (c6 >> 2u32 & 7u32 | (c7 & 31u32) << 3u32) == (c6 >> 2u32 & 1 | (c6 >> 3u32 & 1) << 1 | (c6 >> 4u32 & 1) << 2 | (c7 >> 0u32 & 1) << 3 | (c7 >> 1u32 & 1) << 4 | (c7 >> 2u32 & 1) << 5 | (c7 >> 3u32 & 1) << 6 | (c7 >> 4u32 & 1) << 7)
{}

// Byte `5 g + 4` of ByteEncode_5 of the polynomial at `fo` in `f`.
@constant_time
fn enc5_byte4(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 32 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 5, 5 * g as int + 4) as u8
{
    let c6 = f[fo + 8 * g + 6];
    let c7 = f[fo + 8 * g + 7];
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 4) + 0, (fo + 8 * g + 6) as int, 2);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 4) + 1, (fo + 8 * g + 6) as int, 3);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 4) + 2, (fo + 8 * g + 6) as int, 4);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 4) + 3, (fo + 8 * g + 7) as int, 0);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 4) + 4, (fo + 8 * g + 7) as int, 1);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 4) + 5, (fo + 8 * g + 7) as int, 2);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 4) + 6, (fo + 8 * g + 7) as int, 3);
    fbit_at(f.view(), fo as int, 5, 8 * (5 * g as int + 4) + 7, (fo + 8 * g + 7) as int, 4);
    enc5_bits4(c6.value(), c7.value());
    return (c6 >> 2 & Secret::new(7u32) | (c7 & Secret::new(31u32)) << 3).cast::<u8>();
}

// Bytes `5 g + 0` to `5 g + 3` of ByteEncode_5 of the polynomial at `fo` in `f` into `out` from `oo` on.
@constant_time
fn enc5_part0(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, fo: usize, g: usize)
    requires g < 32 && oo as int + 160 <= out.len() as int && fo as int + 256 <= f.len() as int
    ensures out.len() == old(out.len())
    ensures encoded(old(out.view()), oo as int, f.view(), fo as int, 5, 5 * g as int + 0) == encoded(
        out.view(),
        oo as int,
        f.view(),
        fo as int,
        5,
        5 * g as int + 4,
    )
{
    ghost let o0 = out.view();
    let r0 = enc5_byte0(f, fo, g);
    out[oo + 5 * g + 0] = r0;
    encoded_next(o0, oo as int, f.view(), fo as int, 5, 5 * g as int + 0, r0, out.view());
    ghost let o1 = out.view();
    let r1 = enc5_byte1(f, fo, g);
    out[oo + 5 * g + 1] = r1;
    encoded_next(o1, oo as int, f.view(), fo as int, 5, 5 * g as int + 1, r1, out.view());
    ghost let o2 = out.view();
    let r2 = enc5_byte2(f, fo, g);
    out[oo + 5 * g + 2] = r2;
    encoded_next(o2, oo as int, f.view(), fo as int, 5, 5 * g as int + 2, r2, out.view());
    ghost let o3 = out.view();
    let r3 = enc5_byte3(f, fo, g);
    out[oo + 5 * g + 3] = r3;
    encoded_next(o3, oo as int, f.view(), fo as int, 5, 5 * g as int + 3, r3, out.view());
}

// Bytes `5 g + 4` to `5 g + 4` of ByteEncode_5 of the polynomial at `fo` in `f` into `out` from `oo` on.
@constant_time
fn enc5_part4(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, fo: usize, g: usize)
    requires g < 32 && oo as int + 160 <= out.len() as int && fo as int + 256 <= f.len() as int
    ensures out.len() == old(out.len())
    ensures encoded(old(out.view()), oo as int, f.view(), fo as int, 5, 5 * g as int + 4) == encoded(
        out.view(),
        oo as int,
        f.view(),
        fo as int,
        5,
        5 * g as int + 5,
    )
{
    ghost let o4 = out.view();
    let r4 = enc5_byte4(f, fo, g);
    out[oo + 5 * g + 4] = r4;
    encoded_next(o4, oo as int, f.view(), fo as int, 5, 5 * g as int + 4, r4, out.view());
}

// ByteEncode_5 of the polynomial at `fo` in `f` into `out` from `oo` on.
@constant_time
fn encode5(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, fo: usize)
    requires oo as int + 160 <= out.len() as int && fo as int + 256 <= f.len() as int
    ensures out.len() == old(out.len()) && out.view() == encoded(old(out.view()), oo as int, f.view(), fo as int, 5, 0)
{
    for g in 0usize..32
        invariant out.len() == old(out.len()) && encoded(out.view(), oo as int, f.view(), fo as int, 5, 5 * g as int) == encoded(
            old(out.view()),
            oo as int,
            f.view(),
            fo as int,
            5,
            0,
        )
    {
        enc5_part0(out, oo, f, fo, g);
        enc5_part4(out, oo, f, fo, g);
    }
    assert encoded(out.view(), oo as int, f.view(), fo as int, 5, 160) == out.view() by {};
}

// Byte 0 of a group of ByteEncode_10 as the bits of the coefficients it holds.
lemma enc10_bits0(c0: u32)
    ensures (c0 & 255u32) == (c0 >> 0u32 & 1 | (c0 >> 1u32 & 1) << 1 | (c0 >> 2u32 & 1) << 2 | (c0 >> 3u32 & 1) << 3 | (c0 >> 4u32 & 1) << 4 | (c0 >> 5u32 & 1) << 5 | (c0 >> 6u32 & 1) << 6 | (c0 >> 7u32 & 1) << 7)
{}

// Byte `5 g + 0` of ByteEncode_10 of the polynomial at `fo` in `f`.
@constant_time
fn enc10_byte0(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 64 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 10, 5 * g as int + 0) as u8
{
    let c0 = f[fo + 4 * g + 0];
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 0) + 0, (fo + 4 * g + 0) as int, 0);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 0) + 1, (fo + 4 * g + 0) as int, 1);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 0) + 2, (fo + 4 * g + 0) as int, 2);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 0) + 3, (fo + 4 * g + 0) as int, 3);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 0) + 4, (fo + 4 * g + 0) as int, 4);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 0) + 5, (fo + 4 * g + 0) as int, 5);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 0) + 6, (fo + 4 * g + 0) as int, 6);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 0) + 7, (fo + 4 * g + 0) as int, 7);
    enc10_bits0(c0.value());
    return (c0 & Secret::new(255u32)).cast::<u8>();
}

// Byte 1 of a group of ByteEncode_10 as the bits of the coefficients it holds.
lemma enc10_bits1(c0: u32, c1: u32)
    ensures (c0 >> 8u32 & 3u32 | (c1 & 63u32) << 2u32) == (c0 >> 8u32 & 1 | (c0 >> 9u32 & 1) << 1 | (c1 >> 0u32 & 1) << 2 | (c1 >> 1u32 & 1) << 3 | (c1 >> 2u32 & 1) << 4 | (c1 >> 3u32 & 1) << 5 | (c1 >> 4u32 & 1) << 6 | (c1 >> 5u32 & 1) << 7)
{}

// Byte `5 g + 1` of ByteEncode_10 of the polynomial at `fo` in `f`.
@constant_time
fn enc10_byte1(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 64 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 10, 5 * g as int + 1) as u8
{
    let c0 = f[fo + 4 * g + 0];
    let c1 = f[fo + 4 * g + 1];
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 1) + 0, (fo + 4 * g + 0) as int, 8);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 1) + 1, (fo + 4 * g + 0) as int, 9);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 1) + 2, (fo + 4 * g + 1) as int, 0);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 1) + 3, (fo + 4 * g + 1) as int, 1);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 1) + 4, (fo + 4 * g + 1) as int, 2);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 1) + 5, (fo + 4 * g + 1) as int, 3);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 1) + 6, (fo + 4 * g + 1) as int, 4);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 1) + 7, (fo + 4 * g + 1) as int, 5);
    enc10_bits1(c0.value(), c1.value());
    return (c0 >> 8 & Secret::new(3u32) | (c1 & Secret::new(63u32)) << 2).cast::<u8>();
}

// Byte 2 of a group of ByteEncode_10 as the bits of the coefficients it holds.
lemma enc10_bits2(c1: u32, c2: u32)
    ensures (c1 >> 6u32 & 15u32 | (c2 & 15u32) << 4u32) == (c1 >> 6u32 & 1 | (c1 >> 7u32 & 1) << 1 | (c1 >> 8u32 & 1) << 2 | (c1 >> 9u32 & 1) << 3 | (c2 >> 0u32 & 1) << 4 | (c2 >> 1u32 & 1) << 5 | (c2 >> 2u32 & 1) << 6 | (c2 >> 3u32 & 1) << 7)
{}

// Byte `5 g + 2` of ByteEncode_10 of the polynomial at `fo` in `f`.
@constant_time
fn enc10_byte2(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 64 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 10, 5 * g as int + 2) as u8
{
    let c1 = f[fo + 4 * g + 1];
    let c2 = f[fo + 4 * g + 2];
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 2) + 0, (fo + 4 * g + 1) as int, 6);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 2) + 1, (fo + 4 * g + 1) as int, 7);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 2) + 2, (fo + 4 * g + 1) as int, 8);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 2) + 3, (fo + 4 * g + 1) as int, 9);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 2) + 4, (fo + 4 * g + 2) as int, 0);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 2) + 5, (fo + 4 * g + 2) as int, 1);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 2) + 6, (fo + 4 * g + 2) as int, 2);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 2) + 7, (fo + 4 * g + 2) as int, 3);
    enc10_bits2(c1.value(), c2.value());
    return (c1 >> 6 & Secret::new(15u32) | (c2 & Secret::new(15u32)) << 4).cast::<u8>();
}

// Byte 3 of a group of ByteEncode_10 as the bits of the coefficients it holds.
lemma enc10_bits3(c2: u32, c3: u32)
    ensures (c2 >> 4u32 & 63u32 | (c3 & 3u32) << 6u32) == (c2 >> 4u32 & 1 | (c2 >> 5u32 & 1) << 1 | (c2 >> 6u32 & 1) << 2 | (c2 >> 7u32 & 1) << 3 | (c2 >> 8u32 & 1) << 4 | (c2 >> 9u32 & 1) << 5 | (c3 >> 0u32 & 1) << 6 | (c3 >> 1u32 & 1) << 7)
{}

// Byte `5 g + 3` of ByteEncode_10 of the polynomial at `fo` in `f`.
@constant_time
fn enc10_byte3(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 64 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 10, 5 * g as int + 3) as u8
{
    let c2 = f[fo + 4 * g + 2];
    let c3 = f[fo + 4 * g + 3];
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 3) + 0, (fo + 4 * g + 2) as int, 4);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 3) + 1, (fo + 4 * g + 2) as int, 5);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 3) + 2, (fo + 4 * g + 2) as int, 6);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 3) + 3, (fo + 4 * g + 2) as int, 7);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 3) + 4, (fo + 4 * g + 2) as int, 8);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 3) + 5, (fo + 4 * g + 2) as int, 9);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 3) + 6, (fo + 4 * g + 3) as int, 0);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 3) + 7, (fo + 4 * g + 3) as int, 1);
    enc10_bits3(c2.value(), c3.value());
    return (c2 >> 4 & Secret::new(63u32) | (c3 & Secret::new(3u32)) << 6).cast::<u8>();
}

// Byte 4 of a group of ByteEncode_10 as the bits of the coefficients it holds.
lemma enc10_bits4(c3: u32)
    ensures (c3 >> 2u32 & 255u32) == (c3 >> 2u32 & 1 | (c3 >> 3u32 & 1) << 1 | (c3 >> 4u32 & 1) << 2 | (c3 >> 5u32 & 1) << 3 | (c3 >> 6u32 & 1) << 4 | (c3 >> 7u32 & 1) << 5 | (c3 >> 8u32 & 1) << 6 | (c3 >> 9u32 & 1) << 7)
{}

// Byte `5 g + 4` of ByteEncode_10 of the polynomial at `fo` in `f`.
@constant_time
fn enc10_byte4(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 64 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 10, 5 * g as int + 4) as u8
{
    let c3 = f[fo + 4 * g + 3];
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 4) + 0, (fo + 4 * g + 3) as int, 2);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 4) + 1, (fo + 4 * g + 3) as int, 3);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 4) + 2, (fo + 4 * g + 3) as int, 4);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 4) + 3, (fo + 4 * g + 3) as int, 5);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 4) + 4, (fo + 4 * g + 3) as int, 6);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 4) + 5, (fo + 4 * g + 3) as int, 7);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 4) + 6, (fo + 4 * g + 3) as int, 8);
    fbit_at(f.view(), fo as int, 10, 8 * (5 * g as int + 4) + 7, (fo + 4 * g + 3) as int, 9);
    enc10_bits4(c3.value());
    return (c3 >> 2 & Secret::new(255u32)).cast::<u8>();
}

// Bytes `5 g + 0` to `5 g + 3` of ByteEncode_10 of the polynomial at `fo` in `f` into `out` from `oo` on.
@constant_time
fn enc10_part0(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, fo: usize, g: usize)
    requires g < 64 && oo as int + 320 <= out.len() as int && fo as int + 256 <= f.len() as int
    ensures out.len() == old(out.len())
    ensures encoded(old(out.view()), oo as int, f.view(), fo as int, 10, 5 * g as int + 0) == encoded(
        out.view(),
        oo as int,
        f.view(),
        fo as int,
        10,
        5 * g as int + 4,
    )
{
    ghost let o0 = out.view();
    let r0 = enc10_byte0(f, fo, g);
    out[oo + 5 * g + 0] = r0;
    encoded_next(o0, oo as int, f.view(), fo as int, 10, 5 * g as int + 0, r0, out.view());
    ghost let o1 = out.view();
    let r1 = enc10_byte1(f, fo, g);
    out[oo + 5 * g + 1] = r1;
    encoded_next(o1, oo as int, f.view(), fo as int, 10, 5 * g as int + 1, r1, out.view());
    ghost let o2 = out.view();
    let r2 = enc10_byte2(f, fo, g);
    out[oo + 5 * g + 2] = r2;
    encoded_next(o2, oo as int, f.view(), fo as int, 10, 5 * g as int + 2, r2, out.view());
    ghost let o3 = out.view();
    let r3 = enc10_byte3(f, fo, g);
    out[oo + 5 * g + 3] = r3;
    encoded_next(o3, oo as int, f.view(), fo as int, 10, 5 * g as int + 3, r3, out.view());
}

// Bytes `5 g + 4` to `5 g + 4` of ByteEncode_10 of the polynomial at `fo` in `f` into `out` from `oo` on.
@constant_time
fn enc10_part4(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, fo: usize, g: usize)
    requires g < 64 && oo as int + 320 <= out.len() as int && fo as int + 256 <= f.len() as int
    ensures out.len() == old(out.len())
    ensures encoded(old(out.view()), oo as int, f.view(), fo as int, 10, 5 * g as int + 4) == encoded(
        out.view(),
        oo as int,
        f.view(),
        fo as int,
        10,
        5 * g as int + 5,
    )
{
    ghost let o4 = out.view();
    let r4 = enc10_byte4(f, fo, g);
    out[oo + 5 * g + 4] = r4;
    encoded_next(o4, oo as int, f.view(), fo as int, 10, 5 * g as int + 4, r4, out.view());
}

// ByteEncode_10 of the polynomial at `fo` in `f` into `out` from `oo` on.
@constant_time
fn encode10(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, fo: usize)
    requires oo as int + 320 <= out.len() as int && fo as int + 256 <= f.len() as int
    ensures out.len() == old(out.len()) && out.view() == encoded(old(out.view()), oo as int, f.view(), fo as int, 10, 0)
{
    for g in 0usize..64
        invariant out.len() == old(out.len()) && encoded(out.view(), oo as int, f.view(), fo as int, 10, 5 * g as int) == encoded(
            old(out.view()),
            oo as int,
            f.view(),
            fo as int,
            10,
            0,
        )
    {
        enc10_part0(out, oo, f, fo, g);
        enc10_part4(out, oo, f, fo, g);
    }
    assert encoded(out.view(), oo as int, f.view(), fo as int, 10, 320) == out.view() by {};
}

// Byte 0 of a group of ByteEncode_11 as the bits of the coefficients it holds.
lemma enc11_bits0(c0: u32)
    ensures (c0 & 255u32) == (c0 >> 0u32 & 1 | (c0 >> 1u32 & 1) << 1 | (c0 >> 2u32 & 1) << 2 | (c0 >> 3u32 & 1) << 3 | (c0 >> 4u32 & 1) << 4 | (c0 >> 5u32 & 1) << 5 | (c0 >> 6u32 & 1) << 6 | (c0 >> 7u32 & 1) << 7)
{}

// Byte `11 g + 0` of ByteEncode_11 of the polynomial at `fo` in `f`.
@constant_time
fn enc11_byte0(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 32 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 11, 11 * g as int + 0) as u8
{
    let c0 = f[fo + 8 * g + 0];
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 0) + 0, (fo + 8 * g + 0) as int, 0);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 0) + 1, (fo + 8 * g + 0) as int, 1);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 0) + 2, (fo + 8 * g + 0) as int, 2);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 0) + 3, (fo + 8 * g + 0) as int, 3);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 0) + 4, (fo + 8 * g + 0) as int, 4);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 0) + 5, (fo + 8 * g + 0) as int, 5);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 0) + 6, (fo + 8 * g + 0) as int, 6);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 0) + 7, (fo + 8 * g + 0) as int, 7);
    enc11_bits0(c0.value());
    return (c0 & Secret::new(255u32)).cast::<u8>();
}

// Byte 1 of a group of ByteEncode_11 as the bits of the coefficients it holds.
lemma enc11_bits1(c0: u32, c1: u32)
    ensures (c0 >> 8u32 & 7u32 | (c1 & 31u32) << 3u32) == (c0 >> 8u32 & 1 | (c0 >> 9u32 & 1) << 1 | (c0 >> 10u32 & 1) << 2 | (c1 >> 0u32 & 1) << 3 | (c1 >> 1u32 & 1) << 4 | (c1 >> 2u32 & 1) << 5 | (c1 >> 3u32 & 1) << 6 | (c1 >> 4u32 & 1) << 7)
{}

// Byte `11 g + 1` of ByteEncode_11 of the polynomial at `fo` in `f`.
@constant_time
fn enc11_byte1(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 32 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 11, 11 * g as int + 1) as u8
{
    let c0 = f[fo + 8 * g + 0];
    let c1 = f[fo + 8 * g + 1];
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 1) + 0, (fo + 8 * g + 0) as int, 8);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 1) + 1, (fo + 8 * g + 0) as int, 9);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 1) + 2, (fo + 8 * g + 0) as int, 10);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 1) + 3, (fo + 8 * g + 1) as int, 0);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 1) + 4, (fo + 8 * g + 1) as int, 1);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 1) + 5, (fo + 8 * g + 1) as int, 2);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 1) + 6, (fo + 8 * g + 1) as int, 3);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 1) + 7, (fo + 8 * g + 1) as int, 4);
    enc11_bits1(c0.value(), c1.value());
    return (c0 >> 8 & Secret::new(7u32) | (c1 & Secret::new(31u32)) << 3).cast::<u8>();
}

// Byte 2 of a group of ByteEncode_11 as the bits of the coefficients it holds.
lemma enc11_bits2(c1: u32, c2: u32)
    ensures (c1 >> 5u32 & 63u32 | (c2 & 3u32) << 6u32) == (c1 >> 5u32 & 1 | (c1 >> 6u32 & 1) << 1 | (c1 >> 7u32 & 1) << 2 | (c1 >> 8u32 & 1) << 3 | (c1 >> 9u32 & 1) << 4 | (c1 >> 10u32 & 1) << 5 | (c2 >> 0u32 & 1) << 6 | (c2 >> 1u32 & 1) << 7)
{}

// Byte `11 g + 2` of ByteEncode_11 of the polynomial at `fo` in `f`.
@constant_time
fn enc11_byte2(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 32 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 11, 11 * g as int + 2) as u8
{
    let c1 = f[fo + 8 * g + 1];
    let c2 = f[fo + 8 * g + 2];
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 2) + 0, (fo + 8 * g + 1) as int, 5);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 2) + 1, (fo + 8 * g + 1) as int, 6);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 2) + 2, (fo + 8 * g + 1) as int, 7);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 2) + 3, (fo + 8 * g + 1) as int, 8);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 2) + 4, (fo + 8 * g + 1) as int, 9);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 2) + 5, (fo + 8 * g + 1) as int, 10);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 2) + 6, (fo + 8 * g + 2) as int, 0);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 2) + 7, (fo + 8 * g + 2) as int, 1);
    enc11_bits2(c1.value(), c2.value());
    return (c1 >> 5 & Secret::new(63u32) | (c2 & Secret::new(3u32)) << 6).cast::<u8>();
}

// Byte 3 of a group of ByteEncode_11 as the bits of the coefficients it holds.
lemma enc11_bits3(c2: u32)
    ensures (c2 >> 2u32 & 255u32) == (c2 >> 2u32 & 1 | (c2 >> 3u32 & 1) << 1 | (c2 >> 4u32 & 1) << 2 | (c2 >> 5u32 & 1) << 3 | (c2 >> 6u32 & 1) << 4 | (c2 >> 7u32 & 1) << 5 | (c2 >> 8u32 & 1) << 6 | (c2 >> 9u32 & 1) << 7)
{}

// Byte `11 g + 3` of ByteEncode_11 of the polynomial at `fo` in `f`.
@constant_time
fn enc11_byte3(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 32 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 11, 11 * g as int + 3) as u8
{
    let c2 = f[fo + 8 * g + 2];
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 3) + 0, (fo + 8 * g + 2) as int, 2);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 3) + 1, (fo + 8 * g + 2) as int, 3);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 3) + 2, (fo + 8 * g + 2) as int, 4);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 3) + 3, (fo + 8 * g + 2) as int, 5);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 3) + 4, (fo + 8 * g + 2) as int, 6);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 3) + 5, (fo + 8 * g + 2) as int, 7);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 3) + 6, (fo + 8 * g + 2) as int, 8);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 3) + 7, (fo + 8 * g + 2) as int, 9);
    enc11_bits3(c2.value());
    return (c2 >> 2 & Secret::new(255u32)).cast::<u8>();
}

// Byte 4 of a group of ByteEncode_11 as the bits of the coefficients it holds.
lemma enc11_bits4(c2: u32, c3: u32)
    ensures (c2 >> 10u32 & 1u32 | (c3 & 127u32) << 1u32) == (c2 >> 10u32 & 1 | (c3 >> 0u32 & 1) << 1 | (c3 >> 1u32 & 1) << 2 | (c3 >> 2u32 & 1) << 3 | (c3 >> 3u32 & 1) << 4 | (c3 >> 4u32 & 1) << 5 | (c3 >> 5u32 & 1) << 6 | (c3 >> 6u32 & 1) << 7)
{}

// Byte `11 g + 4` of ByteEncode_11 of the polynomial at `fo` in `f`.
@constant_time
fn enc11_byte4(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 32 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 11, 11 * g as int + 4) as u8
{
    let c2 = f[fo + 8 * g + 2];
    let c3 = f[fo + 8 * g + 3];
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 4) + 0, (fo + 8 * g + 2) as int, 10);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 4) + 1, (fo + 8 * g + 3) as int, 0);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 4) + 2, (fo + 8 * g + 3) as int, 1);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 4) + 3, (fo + 8 * g + 3) as int, 2);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 4) + 4, (fo + 8 * g + 3) as int, 3);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 4) + 5, (fo + 8 * g + 3) as int, 4);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 4) + 6, (fo + 8 * g + 3) as int, 5);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 4) + 7, (fo + 8 * g + 3) as int, 6);
    enc11_bits4(c2.value(), c3.value());
    return (c2 >> 10 & Secret::new(1u32) | (c3 & Secret::new(127u32)) << 1).cast::<u8>();
}

// Byte 5 of a group of ByteEncode_11 as the bits of the coefficients it holds.
lemma enc11_bits5(c3: u32, c4: u32)
    ensures (c3 >> 7u32 & 15u32 | (c4 & 15u32) << 4u32) == (c3 >> 7u32 & 1 | (c3 >> 8u32 & 1) << 1 | (c3 >> 9u32 & 1) << 2 | (c3 >> 10u32 & 1) << 3 | (c4 >> 0u32 & 1) << 4 | (c4 >> 1u32 & 1) << 5 | (c4 >> 2u32 & 1) << 6 | (c4 >> 3u32 & 1) << 7)
{}

// Byte `11 g + 5` of ByteEncode_11 of the polynomial at `fo` in `f`.
@constant_time
fn enc11_byte5(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 32 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 11, 11 * g as int + 5) as u8
{
    let c3 = f[fo + 8 * g + 3];
    let c4 = f[fo + 8 * g + 4];
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 5) + 0, (fo + 8 * g + 3) as int, 7);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 5) + 1, (fo + 8 * g + 3) as int, 8);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 5) + 2, (fo + 8 * g + 3) as int, 9);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 5) + 3, (fo + 8 * g + 3) as int, 10);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 5) + 4, (fo + 8 * g + 4) as int, 0);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 5) + 5, (fo + 8 * g + 4) as int, 1);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 5) + 6, (fo + 8 * g + 4) as int, 2);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 5) + 7, (fo + 8 * g + 4) as int, 3);
    enc11_bits5(c3.value(), c4.value());
    return (c3 >> 7 & Secret::new(15u32) | (c4 & Secret::new(15u32)) << 4).cast::<u8>();
}

// Byte 6 of a group of ByteEncode_11 as the bits of the coefficients it holds.
lemma enc11_bits6(c4: u32, c5: u32)
    ensures (c4 >> 4u32 & 127u32 | (c5 & 1u32) << 7u32) == (c4 >> 4u32 & 1 | (c4 >> 5u32 & 1) << 1 | (c4 >> 6u32 & 1) << 2 | (c4 >> 7u32 & 1) << 3 | (c4 >> 8u32 & 1) << 4 | (c4 >> 9u32 & 1) << 5 | (c4 >> 10u32 & 1) << 6 | (c5 >> 0u32 & 1) << 7)
{}

// Byte `11 g + 6` of ByteEncode_11 of the polynomial at `fo` in `f`.
@constant_time
fn enc11_byte6(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 32 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 11, 11 * g as int + 6) as u8
{
    let c4 = f[fo + 8 * g + 4];
    let c5 = f[fo + 8 * g + 5];
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 6) + 0, (fo + 8 * g + 4) as int, 4);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 6) + 1, (fo + 8 * g + 4) as int, 5);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 6) + 2, (fo + 8 * g + 4) as int, 6);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 6) + 3, (fo + 8 * g + 4) as int, 7);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 6) + 4, (fo + 8 * g + 4) as int, 8);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 6) + 5, (fo + 8 * g + 4) as int, 9);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 6) + 6, (fo + 8 * g + 4) as int, 10);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 6) + 7, (fo + 8 * g + 5) as int, 0);
    enc11_bits6(c4.value(), c5.value());
    return (c4 >> 4 & Secret::new(127u32) | (c5 & Secret::new(1u32)) << 7).cast::<u8>();
}

// Byte 7 of a group of ByteEncode_11 as the bits of the coefficients it holds.
lemma enc11_bits7(c5: u32)
    ensures (c5 >> 1u32 & 255u32) == (c5 >> 1u32 & 1 | (c5 >> 2u32 & 1) << 1 | (c5 >> 3u32 & 1) << 2 | (c5 >> 4u32 & 1) << 3 | (c5 >> 5u32 & 1) << 4 | (c5 >> 6u32 & 1) << 5 | (c5 >> 7u32 & 1) << 6 | (c5 >> 8u32 & 1) << 7)
{}

// Byte `11 g + 7` of ByteEncode_11 of the polynomial at `fo` in `f`.
@constant_time
fn enc11_byte7(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 32 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 11, 11 * g as int + 7) as u8
{
    let c5 = f[fo + 8 * g + 5];
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 7) + 0, (fo + 8 * g + 5) as int, 1);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 7) + 1, (fo + 8 * g + 5) as int, 2);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 7) + 2, (fo + 8 * g + 5) as int, 3);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 7) + 3, (fo + 8 * g + 5) as int, 4);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 7) + 4, (fo + 8 * g + 5) as int, 5);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 7) + 5, (fo + 8 * g + 5) as int, 6);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 7) + 6, (fo + 8 * g + 5) as int, 7);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 7) + 7, (fo + 8 * g + 5) as int, 8);
    enc11_bits7(c5.value());
    return (c5 >> 1 & Secret::new(255u32)).cast::<u8>();
}

// Byte 8 of a group of ByteEncode_11 as the bits of the coefficients it holds.
lemma enc11_bits8(c5: u32, c6: u32)
    ensures (c5 >> 9u32 & 3u32 | (c6 & 63u32) << 2u32) == (c5 >> 9u32 & 1 | (c5 >> 10u32 & 1) << 1 | (c6 >> 0u32 & 1) << 2 | (c6 >> 1u32 & 1) << 3 | (c6 >> 2u32 & 1) << 4 | (c6 >> 3u32 & 1) << 5 | (c6 >> 4u32 & 1) << 6 | (c6 >> 5u32 & 1) << 7)
{}

// Byte `11 g + 8` of ByteEncode_11 of the polynomial at `fo` in `f`.
@constant_time
fn enc11_byte8(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 32 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 11, 11 * g as int + 8) as u8
{
    let c5 = f[fo + 8 * g + 5];
    let c6 = f[fo + 8 * g + 6];
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 8) + 0, (fo + 8 * g + 5) as int, 9);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 8) + 1, (fo + 8 * g + 5) as int, 10);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 8) + 2, (fo + 8 * g + 6) as int, 0);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 8) + 3, (fo + 8 * g + 6) as int, 1);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 8) + 4, (fo + 8 * g + 6) as int, 2);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 8) + 5, (fo + 8 * g + 6) as int, 3);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 8) + 6, (fo + 8 * g + 6) as int, 4);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 8) + 7, (fo + 8 * g + 6) as int, 5);
    enc11_bits8(c5.value(), c6.value());
    return (c5 >> 9 & Secret::new(3u32) | (c6 & Secret::new(63u32)) << 2).cast::<u8>();
}

// Byte 9 of a group of ByteEncode_11 as the bits of the coefficients it holds.
lemma enc11_bits9(c6: u32, c7: u32)
    ensures (c6 >> 6u32 & 31u32 | (c7 & 7u32) << 5u32) == (c6 >> 6u32 & 1 | (c6 >> 7u32 & 1) << 1 | (c6 >> 8u32 & 1) << 2 | (c6 >> 9u32 & 1) << 3 | (c6 >> 10u32 & 1) << 4 | (c7 >> 0u32 & 1) << 5 | (c7 >> 1u32 & 1) << 6 | (c7 >> 2u32 & 1) << 7)
{}

// Byte `11 g + 9` of ByteEncode_11 of the polynomial at `fo` in `f`.
@constant_time
fn enc11_byte9(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 32 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 11, 11 * g as int + 9) as u8
{
    let c6 = f[fo + 8 * g + 6];
    let c7 = f[fo + 8 * g + 7];
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 9) + 0, (fo + 8 * g + 6) as int, 6);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 9) + 1, (fo + 8 * g + 6) as int, 7);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 9) + 2, (fo + 8 * g + 6) as int, 8);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 9) + 3, (fo + 8 * g + 6) as int, 9);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 9) + 4, (fo + 8 * g + 6) as int, 10);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 9) + 5, (fo + 8 * g + 7) as int, 0);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 9) + 6, (fo + 8 * g + 7) as int, 1);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 9) + 7, (fo + 8 * g + 7) as int, 2);
    enc11_bits9(c6.value(), c7.value());
    return (c6 >> 6 & Secret::new(31u32) | (c7 & Secret::new(7u32)) << 5).cast::<u8>();
}

// Byte 10 of a group of ByteEncode_11 as the bits of the coefficients it holds.
lemma enc11_bits10(c7: u32)
    ensures (c7 >> 3u32 & 255u32) == (c7 >> 3u32 & 1 | (c7 >> 4u32 & 1) << 1 | (c7 >> 5u32 & 1) << 2 | (c7 >> 6u32 & 1) << 3 | (c7 >> 7u32 & 1) << 4 | (c7 >> 8u32 & 1) << 5 | (c7 >> 9u32 & 1) << 6 | (c7 >> 10u32 & 1) << 7)
{}

// Byte `11 g + 10` of ByteEncode_11 of the polynomial at `fo` in `f`.
@constant_time
fn enc11_byte10(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 32 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 11, 11 * g as int + 10) as u8
{
    let c7 = f[fo + 8 * g + 7];
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 10) + 0, (fo + 8 * g + 7) as int, 3);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 10) + 1, (fo + 8 * g + 7) as int, 4);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 10) + 2, (fo + 8 * g + 7) as int, 5);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 10) + 3, (fo + 8 * g + 7) as int, 6);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 10) + 4, (fo + 8 * g + 7) as int, 7);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 10) + 5, (fo + 8 * g + 7) as int, 8);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 10) + 6, (fo + 8 * g + 7) as int, 9);
    fbit_at(f.view(), fo as int, 11, 8 * (11 * g as int + 10) + 7, (fo + 8 * g + 7) as int, 10);
    enc11_bits10(c7.value());
    return (c7 >> 3 & Secret::new(255u32)).cast::<u8>();
}

// Bytes `11 g + 0` to `11 g + 3` of ByteEncode_11 of the polynomial at `fo` in `f` into `out` from `oo` on.
@constant_time
fn enc11_part0(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, fo: usize, g: usize)
    requires g < 32 && oo as int + 352 <= out.len() as int && fo as int + 256 <= f.len() as int
    ensures out.len() == old(out.len())
    ensures encoded(old(out.view()), oo as int, f.view(), fo as int, 11, 11 * g as int + 0) == encoded(
        out.view(),
        oo as int,
        f.view(),
        fo as int,
        11,
        11 * g as int + 4,
    )
{
    ghost let o0 = out.view();
    let r0 = enc11_byte0(f, fo, g);
    out[oo + 11 * g + 0] = r0;
    encoded_next(o0, oo as int, f.view(), fo as int, 11, 11 * g as int + 0, r0, out.view());
    ghost let o1 = out.view();
    let r1 = enc11_byte1(f, fo, g);
    out[oo + 11 * g + 1] = r1;
    encoded_next(o1, oo as int, f.view(), fo as int, 11, 11 * g as int + 1, r1, out.view());
    ghost let o2 = out.view();
    let r2 = enc11_byte2(f, fo, g);
    out[oo + 11 * g + 2] = r2;
    encoded_next(o2, oo as int, f.view(), fo as int, 11, 11 * g as int + 2, r2, out.view());
    ghost let o3 = out.view();
    let r3 = enc11_byte3(f, fo, g);
    out[oo + 11 * g + 3] = r3;
    encoded_next(o3, oo as int, f.view(), fo as int, 11, 11 * g as int + 3, r3, out.view());
}

// Bytes `11 g + 4` to `11 g + 7` of ByteEncode_11 of the polynomial at `fo` in `f` into `out` from `oo` on.
@constant_time
fn enc11_part4(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, fo: usize, g: usize)
    requires g < 32 && oo as int + 352 <= out.len() as int && fo as int + 256 <= f.len() as int
    ensures out.len() == old(out.len())
    ensures encoded(old(out.view()), oo as int, f.view(), fo as int, 11, 11 * g as int + 4) == encoded(
        out.view(),
        oo as int,
        f.view(),
        fo as int,
        11,
        11 * g as int + 8,
    )
{
    ghost let o4 = out.view();
    let r4 = enc11_byte4(f, fo, g);
    out[oo + 11 * g + 4] = r4;
    encoded_next(o4, oo as int, f.view(), fo as int, 11, 11 * g as int + 4, r4, out.view());
    ghost let o5 = out.view();
    let r5 = enc11_byte5(f, fo, g);
    out[oo + 11 * g + 5] = r5;
    encoded_next(o5, oo as int, f.view(), fo as int, 11, 11 * g as int + 5, r5, out.view());
    ghost let o6 = out.view();
    let r6 = enc11_byte6(f, fo, g);
    out[oo + 11 * g + 6] = r6;
    encoded_next(o6, oo as int, f.view(), fo as int, 11, 11 * g as int + 6, r6, out.view());
    ghost let o7 = out.view();
    let r7 = enc11_byte7(f, fo, g);
    out[oo + 11 * g + 7] = r7;
    encoded_next(o7, oo as int, f.view(), fo as int, 11, 11 * g as int + 7, r7, out.view());
}

// Bytes `11 g + 8` to `11 g + 10` of ByteEncode_11 of the polynomial at `fo` in `f` into `out` from `oo` on.
@constant_time
fn enc11_part8(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, fo: usize, g: usize)
    requires g < 32 && oo as int + 352 <= out.len() as int && fo as int + 256 <= f.len() as int
    ensures out.len() == old(out.len())
    ensures encoded(old(out.view()), oo as int, f.view(), fo as int, 11, 11 * g as int + 8) == encoded(
        out.view(),
        oo as int,
        f.view(),
        fo as int,
        11,
        11 * g as int + 11,
    )
{
    ghost let o8 = out.view();
    let r8 = enc11_byte8(f, fo, g);
    out[oo + 11 * g + 8] = r8;
    encoded_next(o8, oo as int, f.view(), fo as int, 11, 11 * g as int + 8, r8, out.view());
    ghost let o9 = out.view();
    let r9 = enc11_byte9(f, fo, g);
    out[oo + 11 * g + 9] = r9;
    encoded_next(o9, oo as int, f.view(), fo as int, 11, 11 * g as int + 9, r9, out.view());
    ghost let o10 = out.view();
    let r10 = enc11_byte10(f, fo, g);
    out[oo + 11 * g + 10] = r10;
    encoded_next(o10, oo as int, f.view(), fo as int, 11, 11 * g as int + 10, r10, out.view());
}

// ByteEncode_11 of the polynomial at `fo` in `f` into `out` from `oo` on.
@constant_time
fn encode11(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, fo: usize)
    requires oo as int + 352 <= out.len() as int && fo as int + 256 <= f.len() as int
    ensures out.len() == old(out.len()) && out.view() == encoded(old(out.view()), oo as int, f.view(), fo as int, 11, 0)
{
    for g in 0usize..32
        invariant out.len() == old(out.len()) && encoded(out.view(), oo as int, f.view(), fo as int, 11, 11 * g as int) == encoded(
            old(out.view()),
            oo as int,
            f.view(),
            fo as int,
            11,
            0,
        )
    {
        enc11_part0(out, oo, f, fo, g);
        enc11_part4(out, oo, f, fo, g);
        enc11_part8(out, oo, f, fo, g);
    }
    assert encoded(out.view(), oo as int, f.view(), fo as int, 11, 352) == out.view() by {};
}

// Byte 0 of a group of ByteEncode_12 as the bits of the coefficients it holds.
lemma enc12_bits0(c0: u32)
    ensures (c0 & 255u32) == (c0 >> 0u32 & 1 | (c0 >> 1u32 & 1) << 1 | (c0 >> 2u32 & 1) << 2 | (c0 >> 3u32 & 1) << 3 | (c0 >> 4u32 & 1) << 4 | (c0 >> 5u32 & 1) << 5 | (c0 >> 6u32 & 1) << 6 | (c0 >> 7u32 & 1) << 7)
{}

// Byte `3 g + 0` of ByteEncode_12 of the polynomial at `fo` in `f`.
@constant_time
fn enc12_byte0(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 128 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 12, 3 * g as int + 0) as u8
{
    let c0 = f[fo + 2 * g + 0];
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 0) + 0, (fo + 2 * g + 0) as int, 0);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 0) + 1, (fo + 2 * g + 0) as int, 1);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 0) + 2, (fo + 2 * g + 0) as int, 2);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 0) + 3, (fo + 2 * g + 0) as int, 3);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 0) + 4, (fo + 2 * g + 0) as int, 4);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 0) + 5, (fo + 2 * g + 0) as int, 5);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 0) + 6, (fo + 2 * g + 0) as int, 6);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 0) + 7, (fo + 2 * g + 0) as int, 7);
    enc12_bits0(c0.value());
    return (c0 & Secret::new(255u32)).cast::<u8>();
}

// Byte 1 of a group of ByteEncode_12 as the bits of the coefficients it holds.
lemma enc12_bits1(c0: u32, c1: u32)
    ensures (c0 >> 8u32 & 15u32 | (c1 & 15u32) << 4u32) == (c0 >> 8u32 & 1 | (c0 >> 9u32 & 1) << 1 | (c0 >> 10u32 & 1) << 2 | (c0 >> 11u32 & 1) << 3 | (c1 >> 0u32 & 1) << 4 | (c1 >> 1u32 & 1) << 5 | (c1 >> 2u32 & 1) << 6 | (c1 >> 3u32 & 1) << 7)
{}

// Byte `3 g + 1` of ByteEncode_12 of the polynomial at `fo` in `f`.
@constant_time
fn enc12_byte1(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 128 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 12, 3 * g as int + 1) as u8
{
    let c0 = f[fo + 2 * g + 0];
    let c1 = f[fo + 2 * g + 1];
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 1) + 0, (fo + 2 * g + 0) as int, 8);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 1) + 1, (fo + 2 * g + 0) as int, 9);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 1) + 2, (fo + 2 * g + 0) as int, 10);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 1) + 3, (fo + 2 * g + 0) as int, 11);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 1) + 4, (fo + 2 * g + 1) as int, 0);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 1) + 5, (fo + 2 * g + 1) as int, 1);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 1) + 6, (fo + 2 * g + 1) as int, 2);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 1) + 7, (fo + 2 * g + 1) as int, 3);
    enc12_bits1(c0.value(), c1.value());
    return (c0 >> 8 & Secret::new(15u32) | (c1 & Secret::new(15u32)) << 4).cast::<u8>();
}

// Byte 2 of a group of ByteEncode_12 as the bits of the coefficients it holds.
lemma enc12_bits2(c1: u32)
    ensures (c1 >> 4u32 & 255u32) == (c1 >> 4u32 & 1 | (c1 >> 5u32 & 1) << 1 | (c1 >> 6u32 & 1) << 2 | (c1 >> 7u32 & 1) << 3 | (c1 >> 8u32 & 1) << 4 | (c1 >> 9u32 & 1) << 5 | (c1 >> 10u32 & 1) << 6 | (c1 >> 11u32 & 1) << 7)
{}

// Byte `3 g + 2` of ByteEncode_12 of the polynomial at `fo` in `f`.
@constant_time
fn enc12_byte2(f: []Secret<u32>, fo: usize, g: usize) Secret<u8>
    requires g < 128 && fo as int + 256 <= f.len() as int
    ensures |r| r.value() == enc_byte(f.view(), fo as int, 12, 3 * g as int + 2) as u8
{
    let c1 = f[fo + 2 * g + 1];
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 2) + 0, (fo + 2 * g + 1) as int, 4);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 2) + 1, (fo + 2 * g + 1) as int, 5);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 2) + 2, (fo + 2 * g + 1) as int, 6);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 2) + 3, (fo + 2 * g + 1) as int, 7);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 2) + 4, (fo + 2 * g + 1) as int, 8);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 2) + 5, (fo + 2 * g + 1) as int, 9);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 2) + 6, (fo + 2 * g + 1) as int, 10);
    fbit_at(f.view(), fo as int, 12, 8 * (3 * g as int + 2) + 7, (fo + 2 * g + 1) as int, 11);
    enc12_bits2(c1.value());
    return (c1 >> 4 & Secret::new(255u32)).cast::<u8>();
}

// Bytes `3 g + 0` to `3 g + 2` of ByteEncode_12 of the polynomial at `fo` in `f` into `out` from `oo` on.
@constant_time
fn enc12_part0(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, fo: usize, g: usize)
    requires g < 128 && oo as int + 384 <= out.len() as int && fo as int + 256 <= f.len() as int
    ensures out.len() == old(out.len())
    ensures encoded(old(out.view()), oo as int, f.view(), fo as int, 12, 3 * g as int + 0) == encoded(
        out.view(),
        oo as int,
        f.view(),
        fo as int,
        12,
        3 * g as int + 3,
    )
{
    ghost let o0 = out.view();
    let r0 = enc12_byte0(f, fo, g);
    out[oo + 3 * g + 0] = r0;
    encoded_next(o0, oo as int, f.view(), fo as int, 12, 3 * g as int + 0, r0, out.view());
    ghost let o1 = out.view();
    let r1 = enc12_byte1(f, fo, g);
    out[oo + 3 * g + 1] = r1;
    encoded_next(o1, oo as int, f.view(), fo as int, 12, 3 * g as int + 1, r1, out.view());
    ghost let o2 = out.view();
    let r2 = enc12_byte2(f, fo, g);
    out[oo + 3 * g + 2] = r2;
    encoded_next(o2, oo as int, f.view(), fo as int, 12, 3 * g as int + 2, r2, out.view());
}

// ByteEncode_12 of the polynomial at `fo` in `f` into `out` from `oo` on.
@constant_time
fn encode12(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, fo: usize)
    requires oo as int + 384 <= out.len() as int && fo as int + 256 <= f.len() as int
    ensures out.len() == old(out.len()) && out.view() == encoded(old(out.view()), oo as int, f.view(), fo as int, 12, 0)
{
    for g in 0usize..128
        invariant out.len() == old(out.len()) && encoded(out.view(), oo as int, f.view(), fo as int, 12, 3 * g as int) == encoded(
            old(out.view()),
            oo as int,
            f.view(),
            fo as int,
            12,
            0,
        )
    {
        enc12_part0(out, oo, f, fo, g);
    }
    assert encoded(out.view(), oo as int, f.view(), fo as int, 12, 384) == out.view() by {};
}

// Whether `d` is a `d` of the parameter sets (1, 4, 5, 10, 11; with `twelve` also 12).
spec fn d_ok(d: int, twelve: bool) bool {
    return d == 1 || d == 4 || d == 5 || d == 10 || d == 11 || twelve && d == 12;
}

// ByteDecode_d of the bytes from `bo` in `b` into the polynomial at `fo` in `f`, for `d` of the parameter
// sets.
@constant_time
fn decode_d(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, bo: usize, d: usize)
    requires d_ok(d as int, true) && fo as int + 256 <= f.len() as int && bo as int + 32 * d as int <= b.len() as int && reduced(
        f.view(),
    )
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == decoded(
        old(f.view()),
        fo as int,
        b.view(),
        bo as int,
        d as int,
        0,
    )
    ensures d < 12 ==> below_from(f.view(), fo as int, fo as int + 256, two_pow(d as int) as u32)
{
    ghost let f0 = f.view();
    if d == 1 {
        decode1(f, fo, b, bo);
        assert d as int == 1 && two_pow(d as int) as u32 == 2 by {};

        assert f.view() == decoded(f0, fo as int, b.view(), bo as int, d as int, 0) && below_from(
            f.view(),
            fo as int,
            fo as int + 256,
            two_pow(d as int) as u32,
        ) by {};
    } else if d == 4 {
        decode4(f, fo, b, bo);
        assert d as int == 4 && two_pow(d as int) as u32 == 16 by {};

        assert f.view() == decoded(f0, fo as int, b.view(), bo as int, d as int, 0) && below_from(
            f.view(),
            fo as int,
            fo as int + 256,
            two_pow(d as int) as u32,
        ) by {};
    } else if d == 5 {
        decode5(f, fo, b, bo);
        assert d as int == 5 && two_pow(d as int) as u32 == 32 by {};

        assert f.view() == decoded(f0, fo as int, b.view(), bo as int, d as int, 0) && below_from(
            f.view(),
            fo as int,
            fo as int + 256,
            two_pow(d as int) as u32,
        ) by {};
    } else if d == 10 {
        decode10(f, fo, b, bo);
        assert d as int == 10 && two_pow(d as int) as u32 == 1024 by {};

        assert f.view() == decoded(f0, fo as int, b.view(), bo as int, d as int, 0) && below_from(
            f.view(),
            fo as int,
            fo as int + 256,
            two_pow(d as int) as u32,
        ) by {};
    } else if d == 11 {
        decode11(f, fo, b, bo);
        assert d as int == 11 && two_pow(d as int) as u32 == 2048 by {};

        assert f.view() == decoded(f0, fo as int, b.view(), bo as int, d as int, 0) && below_from(
            f.view(),
            fo as int,
            fo as int + 256,
            two_pow(d as int) as u32,
        ) by {};
    } else {
        decode12(f, fo, b, bo);
        assert f.view() == decoded(f0, fo as int, b.view(), bo as int, d as int, 0) by {};
    }
}

// Compress_d of the polynomial at `o` in `f`, for `d` of the parameter sets.
@constant_time
fn compress_d(f: []mut Secret<u32>, o: usize, d: usize)
    requires d_ok(d as int, false) && o as int + 256 <= f.len() as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == compressed(
        old(f.view()),
        o as int,
        d as int,
        false,
        0,
    )
{
    ghost let f0 = f.view();
    if d == 1 {
        assert d as int == 1 by {};
        compress_poly1(f, o);
        assert f.view() == compressed(f0, o as int, d as int, false, 0) by {};
    } else if d == 4 {
        assert d as int == 4 by {};
        compress_poly4(f, o);
        assert f.view() == compressed(f0, o as int, d as int, false, 0) by {};
    } else if d == 5 {
        assert d as int == 5 by {};
        compress_poly5(f, o);
        assert f.view() == compressed(f0, o as int, d as int, false, 0) by {};
    } else if d == 10 {
        assert d as int == 10 by {};
        compress_poly10(f, o);
        assert f.view() == compressed(f0, o as int, d as int, false, 0) by {};
    } else {
        assert d as int == 11 by {};
        compress_poly11(f, o);
        assert f.view() == compressed(f0, o as int, d as int, false, 0) by {};
    }
}

// Decompress_d of the polynomial at `o` in `f`, for `d` of the parameter sets.
@constant_time
fn decompress_d(f: []mut Secret<u32>, o: usize, d: usize)
    requires d_ok(d as int, false) && o as int + 256 <= f.len() as int && reduced(f.view())
    requires below_from(f.view(), o as int, o as int + 256, two_pow(d as int) as u32)
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == compressed(
        old(f.view()),
        o as int,
        d as int,
        true,
        0,
    )
{
    ghost let f0 = f.view();
    if d == 1 {
        assert d as int == 1 && two_pow(d as int) as u32 == 2 by {};
        decompress_poly1(f, o);
        assert f.view() == compressed(f0, o as int, d as int, true, 0) by {};
    } else if d == 4 {
        assert d as int == 4 && two_pow(d as int) as u32 == 16 by {};
        decompress_poly4(f, o);
        assert f.view() == compressed(f0, o as int, d as int, true, 0) by {};
    } else if d == 5 {
        assert d as int == 5 && two_pow(d as int) as u32 == 32 by {};
        decompress_poly5(f, o);
        assert f.view() == compressed(f0, o as int, d as int, true, 0) by {};
    } else if d == 10 {
        assert d as int == 10 && two_pow(d as int) as u32 == 1024 by {};
        decompress_poly10(f, o);
        assert f.view() == compressed(f0, o as int, d as int, true, 0) by {};
    } else {
        assert d as int == 11 && two_pow(d as int) as u32 == 2048 by {};
        decompress_poly11(f, o);
        assert f.view() == compressed(f0, o as int, d as int, true, 0) by {};
    }
}

// ByteEncode_d of the polynomial at `fo` in `f` into `out` from `oo` on, for `d` of the parameter sets.
@constant_time
fn encode_d(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, fo: usize, d: usize)
    requires d_ok(d as int, true) && oo as int + 32 * d as int <= out.len() as int && fo as int + 256 <= f.len() as int
    ensures out.len() == old(out.len()) && out.view() == encoded(
        old(out.view()),
        oo as int,
        f.view(),
        fo as int,
        d as int,
        0,
    )
{
    if d == 1 {
        encode1(out, oo, f, fo);
    } else if d == 4 {
        encode4(out, oo, f, fo);
    } else if d == 5 {
        encode5(out, oo, f, fo);
    } else if d == 10 {
        encode10(out, oo, f, fo);
    } else if d == 11 {
        encode11(out, oo, f, fo);
    } else {
        encode12(out, oo, f, fo);
    }
}

// Polynomials `i` to `k - 1` of `f` in the NTT domain (`ntt_spec`; `inv`: back from it, `intt_spec`).
spec fn ntt_vec(f: Seq<Secret<u32>>, k: int, inv: bool, i: int) Seq<Secret<u32>>
    decreases k - i
{
    return if i >= k || i < 0 {
        f
    } else if inv {
        ntt_vec(intt_spec(f, 256 * i), k, inv, i + 1)
    } else {
        ntt_vec(ntt_spec(f, 256 * i), k, inv, i + 1)
    };
}

// `ntt_vec` as a step.
lemma ntt_vec_next(f: Seq<Secret<u32>>, k: int, inv: bool, i: int, g: Seq<Secret<u32>>)
    requires 0 <= i && i < k
    requires inv ==> g == intt_spec(f, 256 * i)
    requires !inv ==> g == ntt_spec(f, 256 * i)
    ensures ntt_vec(f, k, inv, i) == ntt_vec(g, k, inv, i + 1)
{}

// The `k` polynomials of `f` into the NTT domain (`inv`: back from it).
@constant_time
fn ntt_all(f: []mut Secret<u32>, k: usize, inv: bool)
    requires 1 <= k && k <= 4 && f.len() as int == 256 * k as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == ntt_vec(old(f.view()), k as int, inv, 0)
{
    for i in 0..k
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant ntt_vec(f.view(), k as int, inv, i as int) == ntt_vec(old(f.view()), k as int, inv, 0)
    {
        ghost let f0 = f.view();
        if inv {
            intt(f, 256 * i);
        } else {
            ntt(f, 256 * i);
        }
        ntt_vec_next(f0, k as int, inv, i as int, f.view());
    }
}

// Polynomials `i` to `k - 1` of `f` plus (`neg`: minus) those of `g`.
spec fn vadd(f: Seq<Secret<u32>>, g: Seq<Secret<u32>>, k: int, neg: bool, i: int) Seq<Secret<u32>>
    decreases k - i
{
    return if i >= k || i < 0 {
        f
    } else {
        vadd(padd(f, 256 * i, g, 256 * i, neg, 0), g, k, neg, i + 1)
    };
}

// `vadd` as a step.
lemma vadd_next(f: Seq<Secret<u32>>, g: Seq<Secret<u32>>, k: int, neg: bool, i: int, h: Seq<Secret<u32>>)
    requires 0 <= i && i < k && h == padd(f, 256 * i, g, 256 * i, neg, 0)
    ensures vadd(f, g, k, neg, i) == vadd(h, g, k, neg, i + 1)
{}

// Adds (`neg`: subtracts) the `k` polynomials of `g` to those of `f`.
@constant_time
fn vec_add(f: []mut Secret<u32>, g: []Secret<u32>, k: usize, neg: bool)
    requires 1 <= k && k <= 4 && f.len() as int == 256 * k as int && g.len() as int == 256 * k as int && reduced(
        f.view(),
    ) && reduced(g.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == vadd(old(f.view()), g.view(), k as int, neg, 0)
{
    for i in 0..k
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant vadd(f.view(), g.view(), k as int, neg, i as int) == vadd(old(f.view()), g.view(), k as int, neg, 0)
    {
        ghost let f0 = f.view();
        poly_add(f, 256 * i, g, 256 * i, neg);
        vadd_next(f0, g.view(), k as int, neg, i as int, f.view());
    }
}

// The polynomial of entry (`i`, `j`) of a `k` by `k` matrix (`tr`: of its transpose), the entries row by
// row.
spec fn ent(k: int, i: int, j: int, tr: bool) int {
    return if tr {
        j * k + i
    } else {
        i * k + j
    };
}

// An entry of a `k` by `k` matrix lies in it.
lemma ent_in(k: int, i: int, j: int, tr: bool)
    requires 1 <= k && k <= 4 && 0 <= i && i < k && 0 <= j && j < k
    ensures 0 <= ent(k, i, j, tr) && ent(k, i, j, tr) + 1 <= k * k
{
    arith::mul_le(j + 1, k, k);
    arith::mul_le(i + 1, k, k);
    arith::mul_nonneg(i, k);
    arith::mul_nonneg(j, k);
}

// The polynomial at `to` in `t` plus the NTT-domain products of entries (`i`, `j`) to (`i`, `k - 1`) of
// matrix `a` (`tr`: its transpose) with polynomials `j` to `k - 1` of `s` (FIPS 203, (2.12), one row).
spec fn row(t: Seq<Secret<u32>>, to: int, a: Seq<Secret<u32>>, s: Seq<Secret<u32>>, k: int, i: int, tr: bool, j: int) Seq<
    Secret<u32>
>
    decreases k - j
{
    return if j >= k || j < 0 {
        t
    } else {
        row(macc(t, to, a, 256 * ent(k, i, j, tr), s, 256 * j, 0), to, a, s, k, i, tr, j + 1)
    };
}

// `row` as a step.
lemma row_next(
    t: Seq<Secret<u32>>,
    to: int,
    a: Seq<Secret<u32>>,
    s: Seq<Secret<u32>>,
    k: int,
    i: int,
    tr: bool,
    j: int,
    h: Seq<Secret<u32>>,
)
    requires 0 <= j && j < k && h == macc(t, to, a, 256 * ent(k, i, j, tr), s, 256 * j, 0)
    ensures row(t, to, a, s, k, i, tr, j) == row(h, to, a, s, k, i, tr, j + 1)
{}

// Adds row `i` of matrix `a` (`tr`: of its transpose) times vector `s` to the polynomial at `to` in `t`.
@constant_time
fn mat_row(t: []mut Secret<u32>, to: usize, a: []Secret<u32>, s: []Secret<u32>, k: usize, i: usize, tr: bool)
    requires 1 <= k && k <= 4 && i < k && to as int + 256 <= t.len() as int
    requires a.len() as int == 256 * k as int * k as int && s.len() as int == 256 * k as int
    requires reduced(t.view()) && reduced(a.view()) && reduced(s.view())
    ensures t.len() == old(t.len()) && reduced(t.view()) && t.view() == row(
        old(t.view()),
        to as int,
        a.view(),
        s.view(),
        k as int,
        i as int,
        tr,
        0,
    )
{
    for j in 0..k
        invariant t.len() == old(t.len()) && reduced(t.view())
        invariant row(t.view(), to as int, a.view(), s.view(), k as int, i as int, tr, j as int) == row(
            old(t.view()),
            to as int,
            a.view(),
            s.view(),
            k as int,
            i as int,
            tr,
            0,
        )
    {
        ent_in(k as int, i as int, j as int, tr);
        let e = if tr {
            j * k + i
        } else {
            i * k + j
        };
        assert e as int == ent(k as int, i as int, j as int, tr) by {};
        arith::mul_le(e as int + 1, k as int * k as int, 256);
        ghost let t0 = t.view();
        mul_acc(t, to, a, 256 * e, s, 256 * j);
        row_next(t0, to as int, a.view(), s.view(), k as int, i as int, tr, j as int, t.view());
    }
}

// Polynomials `i` to `k - 1` of `t` plus the rows of matrix `a` (`tr`: its transpose) times `s`.
spec fn rows(t: Seq<Secret<u32>>, a: Seq<Secret<u32>>, s: Seq<Secret<u32>>, k: int, tr: bool, i: int) Seq<Secret<u32>>
    decreases k - i
{
    return if i >= k || i < 0 {
        t
    } else {
        rows(row(t, 256 * i, a, s, k, i, tr, 0), a, s, k, tr, i + 1)
    };
}

// `rows` as a step.
lemma rows_next(
    t: Seq<Secret<u32>>,
    a: Seq<Secret<u32>>,
    s: Seq<Secret<u32>>,
    k: int,
    tr: bool,
    i: int,
    h: Seq<Secret<u32>>,
)
    requires 0 <= i && i < k && h == row(t, 256 * i, a, s, k, i, tr, 0)
    ensures rows(t, a, s, k, tr, i) == rows(h, a, s, k, tr, i + 1)
{}

// Adds matrix `a` (`tr`: its transpose) times vector `s` to vector `t`.
@constant_time
fn mat_mul(t: []mut Secret<u32>, a: []Secret<u32>, s: []Secret<u32>, k: usize, tr: bool)
    requires 1 <= k && k <= 4 && t.len() as int == 256 * k as int
    requires a.len() as int == 256 * k as int * k as int && s.len() as int == 256 * k as int
    requires reduced(t.view()) && reduced(a.view()) && reduced(s.view())
    ensures t.len() == old(t.len()) && reduced(t.view()) && t.view() == rows(
        old(t.view()),
        a.view(),
        s.view(),
        k as int,
        tr,
        0,
    )
{
    for i in 0..k
        invariant t.len() == old(t.len()) && reduced(t.view())
        invariant rows(t.view(), a.view(), s.view(), k as int, tr, i as int) == rows(
            old(t.view()),
            a.view(),
            s.view(),
            k as int,
            tr,
            0,
        )
    {
        ghost let t0 = t.view();
        mat_row(t, 256 * i, a, s, k, i, tr);
        rows_next(t0, a.view(), s.view(), k as int, tr, i as int, t.view());
    }
}

// Bytes of `out` from `oo` on set to ByteEncode_12 of polynomials `i` to `k - 1` of `f`, 384 bytes each.
spec fn enc_vec(out: Seq<Secret<u8>>, oo: int, f: Seq<Secret<u32>>, k: int, i: int) Seq<Secret<u8>>
    decreases k - i
{
    return if i >= k || i < 0 {
        out
    } else {
        enc_vec(encoded(out, oo + 384 * i, f, 256 * i, 12, 0), oo, f, k, i + 1)
    };
}

// `enc_vec` as a step.
lemma enc_vec_next(out: Seq<Secret<u8>>, oo: int, f: Seq<Secret<u32>>, k: int, i: int, h: Seq<Secret<u8>>)
    requires 0 <= i && i < k && h == encoded(out, oo + 384 * i, f, 256 * i, 12, 0)
    ensures enc_vec(out, oo, f, k, i) == enc_vec(h, oo, f, k, i + 1)
{}

// ByteEncode_12 of the `k` polynomials of `f` into `out` from `oo` on.
@constant_time
fn encode_vec(out: []mut Secret<u8>, oo: usize, f: []Secret<u32>, k: usize)
    requires 1 <= k && k <= 4 && f.len() as int == 256 * k as int && oo as int + 384 * k as int <= out.len() as int
    ensures out.len() == old(out.len()) && out.view() == enc_vec(old(out.view()), oo as int, f.view(), k as int, 0)
{
    for i in 0..k
        invariant out.len() == old(out.len())
        invariant enc_vec(out.view(), oo as int, f.view(), k as int, i as int) == enc_vec(
            old(out.view()),
            oo as int,
            f.view(),
            k as int,
            0,
        )
    {
        ghost let o0 = out.view();
        encode12(out, oo + 384 * i, f, 256 * i);
        enc_vec_next(o0, oo as int, f.view(), k as int, i as int, out.view());
    }
}

// `n` zero coefficients.
spec fn zeros32(n: int) Seq<Secret<u32>>
    decreases n
{
    return if n <= 0 {
        Seq::<Secret<u32>>::empty()
    } else {
        zeros32(n - 1).push(Secret::new(0u32))
    };
}

// `n` zero bytes.
spec fn zeros8(n: int) Seq<Secret<u8>>
    decreases n
{
    return if n <= 0 {
        Seq::<Secret<u8>>::empty()
    } else {
        zeros8(n - 1).push(Secret::new(0u8))
    };
}

// A coefficient below q pushed onto coefficients below q.
lemma reduced_push(s: Seq<Secret<u32>>, x: Secret<u32>)
    requires reduced(s) && x.value() < 3329
    ensures reduced(s.push(x)) && s.push(x).len() == s.len() + 1
{}

// `n` zero coefficients, a vector of `n / 256` polynomials.
fn new_polys(n: usize) Vector<Secret<u32>>
    ensures |v| v.len() == n && v.view() == zeros32(n as int) && reduced(v.view())
{
    let mut v = Vector::<Secret<u32>>::with_capacity(n);
    for i in 0..n
        invariant v.len() == i && v.view() == zeros32(i as int) && reduced(v.view())
    {
        reduced_push(v.view(), Secret::new(0u32));
        v.push(Secret::new(0u32));
    }
    return v;
}

// `n` zero bytes.
fn new_bytes(n: usize) Vector<Secret<u8>>
    ensures |v| v.len() == n && v.view() == zeros8(n as int)
{
    let mut v = Vector::<Secret<u8>>::with_capacity(n);
    for i in 0..n
        invariant v.len() == i && v.view() == zeros8(i as int)
    {
        v.push(Secret::new(0u8));
    }
    return v;
}

// The first `j + 1` elements: the first `j`, then element `j`.
lemma take_next(s: Seq<Secret<u8>>, j: int)
    requires 0 <= j && j < s.len()
    ensures s.take(j + 1) == s.take(j).push(s[j])
{}

// `src` followed by byte `n`.
fn with_byte(src: []Secret<u8>, n: Secret<u8>) Vector<Secret<u8>>
    ensures |v| v.view() == src.view().push(n) && v.len() == src.len() + 1
{
    let mut v = Vector::<Secret<u8>>::with_capacity(src.len() + 1);
    for j in 0..src.len()
        invariant v.view() == src.view().take(j as int) && v.len() == j
    {
        take_next(src.view(), j as int);
        v.push(src[j]);
    }
    assert src.view().take(src.len() as int) == src.view() by {};
    v.push(n);
    return v;
}

// Bytes `c` to `src.len() - 1` of `out` from `oo` on set to those of `src`.
spec fn copied(out: Seq<Secret<u8>>, oo: int, src: Seq<Secret<u8>>, c: int) Seq<Secret<u8>>
    decreases src.len() - c
{
    return if c >= src.len() || c < 0 || oo < 0 || oo + src.len() > out.len() {
        out
    } else {
        copied(out.update(oo + c, src[c]), oo, src, c + 1)
    };
}

// Copies `src` into `out` from `oo` on.
fn copy_bytes(out: []mut Secret<u8>, oo: usize, src: []Secret<u8>)
    requires oo as int + src.len() as int <= out.len() as int
    ensures out.len() == old(out.len()) && out.view() == copied(old(out.view()), oo as int, src.view(), 0)
{
    for c in 0..src.len()
        invariant out.len() == old(out.len()) && copied(out.view(), oo as int, src.view(), c as int) == copied(
            old(out.view()),
            oo as int,
            src.view(),
            0,
        )
    {
        ghost let o0 = out.view();
        out[oo + c] = src[c];
        assert copied(o0, oo as int, src.view(), c as int) == copied(out.view(), oo as int, src.view(), c as int + 1) by {};
    }
    assert copied(out.view(), oo as int, src.view(), src.len() as int) == out.view() by {};
}

// Bytes `lo` to `lo + n - 1` of the output of the sponge of rate `rate` and domain `ds` (FIPS 202) on
// `m`, as secrets.
spec fn out_seq(m: Seq<Secret<u8>>, rate: int, ds: u8, lo: int, n: int) Seq<Secret<u8>>
    decreases n
{
    return if n <= 0 {
        Seq::<Secret<u8>>::empty()
    } else {
        out_seq(m, rate, ds, lo, n - 1).push(Secret::new(sha3::output(m, rate, ds, lo + n - 1)))
    };
}

// `out_seq` one byte longer.
lemma out_seq_next(m: Seq<Secret<u8>>, rate: int, ds: u8, lo: int, n: int)
    requires n >= 0
    ensures out_seq(m, rate, ds, lo, n + 1) == out_seq(m, rate, ds, lo, n).push(
        Secret::new(sha3::output(m, rate, ds, lo + n)),
    )
{}

// `out_seq` has `n` bytes.
lemma out_seq_len(m: Seq<Secret<u8>>, rate: int, ds: u8, lo: int, n: int)
    requires n >= 0
    ensures out_seq(m, rate, ds, lo, n).len() == n
    decreases n
{
    if n > 0 {
        out_seq_len(m, rate, ds, lo, n - 1);
        out_seq_next(m, rate, ds, lo, n - 1);
    }
}

// Bytes `lo` to `lo + 31` of G's output `g` on `m` (FIPS 203, (4.5): SHA3-512), as a vector.

@constant_time
fn g_part0(g: [Secret<u8>; 64], m: []Secret<u8>) Vector<Secret<u8>>
    requires sha3::values64(g) == sha3::sha3_512_digest(m.view())
    ensures |v| v.len() == 32 && v.view() == out_seq(m.view(), 72, 6, 0, 32)
{
    let mut v = Vector::<Secret<u8>>::with_capacity(32);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 0) by {};
    assert g[0].value() == sha3::output(m.view(), 72, 6, 0) by {};
    out_seq_next(m.view(), 72, 6, 0, 0);
    v.push(g[0]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 1) by {};
    assert g[1].value() == sha3::output(m.view(), 72, 6, 1) by {};
    out_seq_next(m.view(), 72, 6, 0, 1);
    v.push(g[1]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 2) by {};
    assert g[2].value() == sha3::output(m.view(), 72, 6, 2) by {};
    out_seq_next(m.view(), 72, 6, 0, 2);
    v.push(g[2]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 3) by {};
    assert g[3].value() == sha3::output(m.view(), 72, 6, 3) by {};
    out_seq_next(m.view(), 72, 6, 0, 3);
    v.push(g[3]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 4) by {};
    assert g[4].value() == sha3::output(m.view(), 72, 6, 4) by {};
    out_seq_next(m.view(), 72, 6, 0, 4);
    v.push(g[4]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 5) by {};
    assert g[5].value() == sha3::output(m.view(), 72, 6, 5) by {};
    out_seq_next(m.view(), 72, 6, 0, 5);
    v.push(g[5]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 6) by {};
    assert g[6].value() == sha3::output(m.view(), 72, 6, 6) by {};
    out_seq_next(m.view(), 72, 6, 0, 6);
    v.push(g[6]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 7) by {};
    assert g[7].value() == sha3::output(m.view(), 72, 6, 7) by {};
    out_seq_next(m.view(), 72, 6, 0, 7);
    v.push(g[7]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 8) by {};
    assert g[8].value() == sha3::output(m.view(), 72, 6, 8) by {};
    out_seq_next(m.view(), 72, 6, 0, 8);
    v.push(g[8]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 9) by {};
    assert g[9].value() == sha3::output(m.view(), 72, 6, 9) by {};
    out_seq_next(m.view(), 72, 6, 0, 9);
    v.push(g[9]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 10) by {};
    assert g[10].value() == sha3::output(m.view(), 72, 6, 10) by {};
    out_seq_next(m.view(), 72, 6, 0, 10);
    v.push(g[10]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 11) by {};
    assert g[11].value() == sha3::output(m.view(), 72, 6, 11) by {};
    out_seq_next(m.view(), 72, 6, 0, 11);
    v.push(g[11]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 12) by {};
    assert g[12].value() == sha3::output(m.view(), 72, 6, 12) by {};
    out_seq_next(m.view(), 72, 6, 0, 12);
    v.push(g[12]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 13) by {};
    assert g[13].value() == sha3::output(m.view(), 72, 6, 13) by {};
    out_seq_next(m.view(), 72, 6, 0, 13);
    v.push(g[13]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 14) by {};
    assert g[14].value() == sha3::output(m.view(), 72, 6, 14) by {};
    out_seq_next(m.view(), 72, 6, 0, 14);
    v.push(g[14]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 15) by {};
    assert g[15].value() == sha3::output(m.view(), 72, 6, 15) by {};
    out_seq_next(m.view(), 72, 6, 0, 15);
    v.push(g[15]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 16) by {};
    assert g[16].value() == sha3::output(m.view(), 72, 6, 16) by {};
    out_seq_next(m.view(), 72, 6, 0, 16);
    v.push(g[16]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 17) by {};
    assert g[17].value() == sha3::output(m.view(), 72, 6, 17) by {};
    out_seq_next(m.view(), 72, 6, 0, 17);
    v.push(g[17]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 18) by {};
    assert g[18].value() == sha3::output(m.view(), 72, 6, 18) by {};
    out_seq_next(m.view(), 72, 6, 0, 18);
    v.push(g[18]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 19) by {};
    assert g[19].value() == sha3::output(m.view(), 72, 6, 19) by {};
    out_seq_next(m.view(), 72, 6, 0, 19);
    v.push(g[19]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 20) by {};
    assert g[20].value() == sha3::output(m.view(), 72, 6, 20) by {};
    out_seq_next(m.view(), 72, 6, 0, 20);
    v.push(g[20]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 21) by {};
    assert g[21].value() == sha3::output(m.view(), 72, 6, 21) by {};
    out_seq_next(m.view(), 72, 6, 0, 21);
    v.push(g[21]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 22) by {};
    assert g[22].value() == sha3::output(m.view(), 72, 6, 22) by {};
    out_seq_next(m.view(), 72, 6, 0, 22);
    v.push(g[22]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 23) by {};
    assert g[23].value() == sha3::output(m.view(), 72, 6, 23) by {};
    out_seq_next(m.view(), 72, 6, 0, 23);
    v.push(g[23]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 24) by {};
    assert g[24].value() == sha3::output(m.view(), 72, 6, 24) by {};
    out_seq_next(m.view(), 72, 6, 0, 24);
    v.push(g[24]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 25) by {};
    assert g[25].value() == sha3::output(m.view(), 72, 6, 25) by {};
    out_seq_next(m.view(), 72, 6, 0, 25);
    v.push(g[25]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 26) by {};
    assert g[26].value() == sha3::output(m.view(), 72, 6, 26) by {};
    out_seq_next(m.view(), 72, 6, 0, 26);
    v.push(g[26]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 27) by {};
    assert g[27].value() == sha3::output(m.view(), 72, 6, 27) by {};
    out_seq_next(m.view(), 72, 6, 0, 27);
    v.push(g[27]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 28) by {};
    assert g[28].value() == sha3::output(m.view(), 72, 6, 28) by {};
    out_seq_next(m.view(), 72, 6, 0, 28);
    v.push(g[28]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 29) by {};
    assert g[29].value() == sha3::output(m.view(), 72, 6, 29) by {};
    out_seq_next(m.view(), 72, 6, 0, 29);
    v.push(g[29]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 30) by {};
    assert g[30].value() == sha3::output(m.view(), 72, 6, 30) by {};
    out_seq_next(m.view(), 72, 6, 0, 30);
    v.push(g[30]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 31) by {};
    assert g[31].value() == sha3::output(m.view(), 72, 6, 31) by {};
    out_seq_next(m.view(), 72, 6, 0, 31);
    v.push(g[31]);
    assert v.view() == out_seq(m.view(), 72, 6, 0, 32) by {};
    out_seq_len(m.view(), 72, 6, 0, 32);
    return v;
}

@constant_time
fn g_part32(g: [Secret<u8>; 64], m: []Secret<u8>) Vector<Secret<u8>>
    requires sha3::values64(g) == sha3::sha3_512_digest(m.view())
    ensures |v| v.len() == 32 && v.view() == out_seq(m.view(), 72, 6, 32, 32)
{
    let mut v = Vector::<Secret<u8>>::with_capacity(32);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 0) by {};
    assert g[32].value() == sha3::output(m.view(), 72, 6, 32) by {};
    out_seq_next(m.view(), 72, 6, 32, 0);
    v.push(g[32]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 1) by {};
    assert g[33].value() == sha3::output(m.view(), 72, 6, 33) by {};
    out_seq_next(m.view(), 72, 6, 32, 1);
    v.push(g[33]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 2) by {};
    assert g[34].value() == sha3::output(m.view(), 72, 6, 34) by {};
    out_seq_next(m.view(), 72, 6, 32, 2);
    v.push(g[34]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 3) by {};
    assert g[35].value() == sha3::output(m.view(), 72, 6, 35) by {};
    out_seq_next(m.view(), 72, 6, 32, 3);
    v.push(g[35]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 4) by {};
    assert g[36].value() == sha3::output(m.view(), 72, 6, 36) by {};
    out_seq_next(m.view(), 72, 6, 32, 4);
    v.push(g[36]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 5) by {};
    assert g[37].value() == sha3::output(m.view(), 72, 6, 37) by {};
    out_seq_next(m.view(), 72, 6, 32, 5);
    v.push(g[37]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 6) by {};
    assert g[38].value() == sha3::output(m.view(), 72, 6, 38) by {};
    out_seq_next(m.view(), 72, 6, 32, 6);
    v.push(g[38]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 7) by {};
    assert g[39].value() == sha3::output(m.view(), 72, 6, 39) by {};
    out_seq_next(m.view(), 72, 6, 32, 7);
    v.push(g[39]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 8) by {};
    assert g[40].value() == sha3::output(m.view(), 72, 6, 40) by {};
    out_seq_next(m.view(), 72, 6, 32, 8);
    v.push(g[40]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 9) by {};
    assert g[41].value() == sha3::output(m.view(), 72, 6, 41) by {};
    out_seq_next(m.view(), 72, 6, 32, 9);
    v.push(g[41]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 10) by {};
    assert g[42].value() == sha3::output(m.view(), 72, 6, 42) by {};
    out_seq_next(m.view(), 72, 6, 32, 10);
    v.push(g[42]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 11) by {};
    assert g[43].value() == sha3::output(m.view(), 72, 6, 43) by {};
    out_seq_next(m.view(), 72, 6, 32, 11);
    v.push(g[43]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 12) by {};
    assert g[44].value() == sha3::output(m.view(), 72, 6, 44) by {};
    out_seq_next(m.view(), 72, 6, 32, 12);
    v.push(g[44]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 13) by {};
    assert g[45].value() == sha3::output(m.view(), 72, 6, 45) by {};
    out_seq_next(m.view(), 72, 6, 32, 13);
    v.push(g[45]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 14) by {};
    assert g[46].value() == sha3::output(m.view(), 72, 6, 46) by {};
    out_seq_next(m.view(), 72, 6, 32, 14);
    v.push(g[46]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 15) by {};
    assert g[47].value() == sha3::output(m.view(), 72, 6, 47) by {};
    out_seq_next(m.view(), 72, 6, 32, 15);
    v.push(g[47]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 16) by {};
    assert g[48].value() == sha3::output(m.view(), 72, 6, 48) by {};
    out_seq_next(m.view(), 72, 6, 32, 16);
    v.push(g[48]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 17) by {};
    assert g[49].value() == sha3::output(m.view(), 72, 6, 49) by {};
    out_seq_next(m.view(), 72, 6, 32, 17);
    v.push(g[49]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 18) by {};
    assert g[50].value() == sha3::output(m.view(), 72, 6, 50) by {};
    out_seq_next(m.view(), 72, 6, 32, 18);
    v.push(g[50]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 19) by {};
    assert g[51].value() == sha3::output(m.view(), 72, 6, 51) by {};
    out_seq_next(m.view(), 72, 6, 32, 19);
    v.push(g[51]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 20) by {};
    assert g[52].value() == sha3::output(m.view(), 72, 6, 52) by {};
    out_seq_next(m.view(), 72, 6, 32, 20);
    v.push(g[52]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 21) by {};
    assert g[53].value() == sha3::output(m.view(), 72, 6, 53) by {};
    out_seq_next(m.view(), 72, 6, 32, 21);
    v.push(g[53]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 22) by {};
    assert g[54].value() == sha3::output(m.view(), 72, 6, 54) by {};
    out_seq_next(m.view(), 72, 6, 32, 22);
    v.push(g[54]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 23) by {};
    assert g[55].value() == sha3::output(m.view(), 72, 6, 55) by {};
    out_seq_next(m.view(), 72, 6, 32, 23);
    v.push(g[55]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 24) by {};
    assert g[56].value() == sha3::output(m.view(), 72, 6, 56) by {};
    out_seq_next(m.view(), 72, 6, 32, 24);
    v.push(g[56]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 25) by {};
    assert g[57].value() == sha3::output(m.view(), 72, 6, 57) by {};
    out_seq_next(m.view(), 72, 6, 32, 25);
    v.push(g[57]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 26) by {};
    assert g[58].value() == sha3::output(m.view(), 72, 6, 58) by {};
    out_seq_next(m.view(), 72, 6, 32, 26);
    v.push(g[58]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 27) by {};
    assert g[59].value() == sha3::output(m.view(), 72, 6, 59) by {};
    out_seq_next(m.view(), 72, 6, 32, 27);
    v.push(g[59]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 28) by {};
    assert g[60].value() == sha3::output(m.view(), 72, 6, 60) by {};
    out_seq_next(m.view(), 72, 6, 32, 28);
    v.push(g[60]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 29) by {};
    assert g[61].value() == sha3::output(m.view(), 72, 6, 61) by {};
    out_seq_next(m.view(), 72, 6, 32, 29);
    v.push(g[61]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 30) by {};
    assert g[62].value() == sha3::output(m.view(), 72, 6, 62) by {};
    out_seq_next(m.view(), 72, 6, 32, 30);
    v.push(g[62]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 31) by {};
    assert g[63].value() == sha3::output(m.view(), 72, 6, 63) by {};
    out_seq_next(m.view(), 72, 6, 32, 31);
    v.push(g[63]);
    assert v.view() == out_seq(m.view(), 72, 6, 32, 32) by {};
    out_seq_len(m.view(), 72, 6, 32, 32);
    return v;
}

// Byte `j` of the XOF stream of seed `s` (SHAKE128, FIPS 203, 4.1).
spec fn xof(s: Seq<Secret<u8>>, j: int) int {
    return sha3::output(s, 168, 0x1f, j) as int;
}

// `d1` and `d2` of iteration `it` of FIPS 203, Algorithm 7 (lines 6 and 7) on the XOF stream of `s`.
spec fn d1(s: Seq<Secret<u8>>, it: int) int {
    return xof(s, 3 * it) + 256 * (xof(s, 3 * it + 1) % 16);
}

spec fn d2(s: Seq<Secret<u8>>, it: int) int {
    return xof(s, 3 * it + 1) / 16 + 16 * xof(s, 3 * it + 2);
}

// Lines 8 to 11 of iteration `it`: the coefficients at `ao` in `a` with `d1` as coefficient `n` when it
// is below q.
spec fn take1(a: Seq<Secret<u32>>, ao: int, s: Seq<Secret<u8>>, it: int, n: int) Seq<Secret<u32>> {
    return if d1(s, it) < 3329 && 0 <= ao + n && ao + n < a.len() {
        a.update(ao + n, Secret::new(d1(s, it) as u32))
    } else {
        a
    };
}

// The count after lines 8 to 11.
spec fn count1(s: Seq<Secret<u8>>, it: int, n: int) int {
    return if d1(s, it) < 3329 {
        n + 1
    } else {
        n
    };
}

// Lines 12 to 15 of iteration `it`, after count `n`.
spec fn take2(a: Seq<Secret<u32>>, ao: int, s: Seq<Secret<u8>>, it: int, n: int) Seq<Secret<u32>> {
    return if d2(s, it) < 3329 && n < 256 && 0 <= ao + n && ao + n < a.len() {
        a.update(ao + n, Secret::new(d2(s, it) as u32))
    } else {
        a
    };
}

spec fn count2(s: Seq<Secret<u8>>, it: int, n: int) int {
    return if d2(s, it) < 3329 && n < 256 {
        n + 1
    } else {
        n
    };
}

/// The XOF iterations SampleNTT runs at most: FIPS 203, Appendix B, Table 4 allows 280, which the loop
/// passes with probability 2^-261.
pub const SAMPLE_ITERATIONS: usize = 280;

// The coefficients at `ao` in `a` after iterations `it` to 279 of FIPS 203, Algorithm 7 from count `n`
// on the XOF stream of `s` (the loop ends at count 256).
spec fn sampled(a: Seq<Secret<u32>>, ao: int, s: Seq<Secret<u8>>, it: int, n: int) Seq<Secret<u32>>
    decreases 280 - it
{
    return if it >= 280 || it < 0 || n >= 256 || n < 0 || ao < 0 || ao + 256 > a.len() {
        a
    } else {
        sampled(
            take2(take1(a, ao, s, it, n), ao, s, it, count1(s, it, n)),
            ao,
            s,
            it + 1,
            count2(s, it, count1(s, it, n)),
        )
    };
}

// The count after iterations `it` to 279 from count `n`.
spec fn sample_count(s: Seq<Secret<u8>>, it: int, n: int) int
    decreases 280 - it
{
    return if it >= 280 || it < 0 || n >= 256 || n < 0 {
        n
    } else {
        sample_count(s, it + 1, count2(s, it, count1(s, it, n)))
    };
}

/// Whether SampleNTT of seed `s` sets all 256 coefficients within SAMPLE_ITERATIONS.
pub spec fn sample_ok(s: Seq<Secret<u8>>) bool {
    return sample_count(s, 0, 0) == 256;
}

// `sampled` and `sample_count` as a step of count `n` below 256: lines 6 to 11 give `b1` and `m1`, lines
// 12 to 15 `b` and `m`.
lemma sampled_next(
    a: Seq<Secret<u32>>,
    ao: int,
    s: Seq<Secret<u8>>,
    it: int,
    n: int,
    b1: Seq<Secret<u32>>,
    m1: int,
    b: Seq<Secret<u32>>,
    m: int,
)
    requires 0 <= it && it < 280 && 0 <= n && n < 256 && 0 <= ao && ao + 256 <= a.len()
    requires b1 == take1(a, ao, s, it, n) && m1 == count1(s, it, n) && b == take2(b1, ao, s, it, m1) && m == count2(
        s,
        it,
        m1,
    )
    ensures sampled(a, ao, s, it, n) == sampled(b, ao, s, it + 1, m)
    ensures sample_count(s, it, n) == sample_count(s, it + 1, m)
{}

// `sampled` and `sample_count` past count 256.
lemma sampled_done(a: Seq<Secret<u32>>, ao: int, s: Seq<Secret<u8>>, it: int, n: int)
    requires 0 <= it && it < 280 && n >= 256
    ensures sampled(a, ao, s, it, n) == sampled(a, ao, s, it + 1, n)
    ensures sample_count(s, it, n) == sample_count(s, it + 1, n)
{}

// Coefficient values of the bytes: `d1` and `d2` of bytes `c0`, `c1` and `c2`.
lemma digits(c0: u32, c1: u32, c2: u32)
    requires c0 < 256 && c1 < 256 && c2 < 256
    ensures (c0 | (c1 & 15) << 8) == c0 + 256 * (c1 % 16)
    ensures (c1 >> 4 | c2 << 4) == c1 / 16 + 16 * c2
{}

// The first 840 bytes of the XOF stream of `seed`: the bytes of SAMPLE_ITERATIONS iterations.
fn xof_stream(seed: []Secret<u8>) Vector<Secret<u8>>
    ensures |st| st.len() == 840 && forall j in 0..st.len() {
        st.view()[j as int].value() as int == xof(seed.view(), j as int)
    }
{
    let mut st = Vector::<Secret<u8>>::with_capacity(840);
    for _i in 0usize..840
        invariant st.len() == _i
    {
        st.push(Secret::new(0u8));
    }
    sha3::shake128(seed, &mut st);
    return st;
}

// Lines 6 and 8 to 11 of iteration `it` of FIPS 203, Algorithm 7, after count `n`, from stream bytes
// `c0` and `c1` of the iteration: the new count.
fn sample_take1(a: []mut Secret<u32>, ao: usize, seed: []Secret<u8>, it: usize, n: usize, c0: u32, c1: u32) usize
    requires ao as int + 256 <= a.len() as int && reduced(a.view()) && it < 280 && n < 256
    requires c0 as int == xof(seed.view(), 3 * it as int) && c1 as int == xof(seed.view(), 3 * it as int + 1) && c0 < 256 && c1 < 256
    ensures |m| a.len() == old(a.len()) && reduced(a.view()) && m <= 256
    ensures |m| a.view() == take1(old(a.view()), ao as int, seed.view(), it as int, n as int) && m as int == count1(
        seed.view(),
        it as int,
        n as int,
    )
{
    digits(c0, c1, 0);
    let x = c0 | (c1 & 15) << 8;
    assert x as int == d1(seed.view(), it as int) by {};
    if x < 3329 {
        let v = Secret::new(x);
        reduced_update(a.view(), (ao + n) as int, v);
        a[ao + n] = v;
        return n + 1;
    }
    return n;
}

// Lines 7 and 12 to 15 of iteration `it`, after count `n`, from stream bytes `c1` and `c2`: the new
// count.
fn sample_take2(a: []mut Secret<u32>, ao: usize, seed: []Secret<u8>, it: usize, n: usize, c1: u32, c2: u32) usize
    requires ao as int + 256 <= a.len() as int && reduced(a.view()) && it < 280 && n <= 256
    requires c1 as int == xof(seed.view(), 3 * it as int + 1) && c2 as int == xof(seed.view(), 3 * it as int + 2) && c1 < 256 && c2 < 256
    ensures |m| a.len() == old(a.len()) && reduced(a.view()) && m <= 256
    ensures |m| a.view() == take2(old(a.view()), ao as int, seed.view(), it as int, n as int) && m as int == count2(
        seed.view(),
        it as int,
        n as int,
    )
{
    digits(0, c1, c2);
    let x = c1 >> 4 | c2 << 4;
    assert x as int == d2(seed.view(), it as int) by {};
    if x < 3329 && n < 256 {
        let v = Secret::new(x);
        reduced_update(a.view(), (ao + n) as int, v);
        a[ao + n] = v;
        return n + 1;
    }
    return n;
}

// The coefficients at `ao` in `a` sampled from the XOF stream of `seed` (FIPS 203, Algorithm 7,
// bounded by Appendix B): whether all 256 were set. The seed is public (`rho`).
fn sample_ntt(a: []mut Secret<u32>, ao: usize, seed: []Secret<u8>) bool
    requires ao as int + 256 <= a.len() as int && reduced(a.view())
    ensures |ok| a.len() == old(a.len()) && reduced(a.view()) && a.view() == sampled(
        old(a.view()),
        ao as int,
        seed.view(),
        0,
        0,
    )
    ensures |ok| ok == sample_ok(seed.view())
{
    ghost let s = seed.view();
    let st = xof_stream(seed);
    let mut n: usize = 0;
    for it in 0usize..280
        invariant a.len() == old(a.len()) && reduced(a.view()) && n <= 256
        invariant sampled(a.view(), ao as int, s, it as int, n as int) == sampled(old(a.view()), ao as int, s, 0, 0)
        invariant sample_count(s, it as int, n as int) == sample_count(s, 0, 0)
    {
        if n < 256 {
            let c0 = st[3 * it].declassify() as u32;
            let c1 = st[3 * it + 1].declassify() as u32;
            let c2 = st[3 * it + 2].declassify() as u32;

            assert c0 as int == xof(s, 3 * it as int) && c1 as int == xof(s, 3 * it as int + 1) && c2 as int == xof(
                s,
                3 * it as int + 2,
            ) by {};
            ghost let a0 = a.view();
            let n1 = sample_take1(a, ao, seed, it, n, c0, c1);
            ghost let a1 = a.view();
            let n2 = sample_take2(a, ao, seed, it, n1, c1, c2);
            sampled_next(a0, ao as int, s, it as int, n as int, a1, n1 as int, a.view(), n2 as int);
            n = n2;
        } else {
            sampled_done(a.view(), ao as int, s, it as int, n as int);
        }
    }
    assert sampled(a.view(), ao as int, s, 280, n as int) == a.view() && sample_count(s, 280, n as int) == n as int by {};
    return n == 256;
}

// Bit `k` of the bit array of PRF output with input `s` (FIPS 203, (4.3): SHAKE256), Algorithm 4: bit
// `k % 8` of byte `k / 8`.
spec fn pbit(s: Seq<Secret<u8>>, k: int) u32 {
    return if k < 0 {
        0
    } else {
        sha3::output(s, 136, 0x1f, k / 8) as u32 >> (k % 8) as u32 & 1
    };
}

// The sum of bits `k` to `k + eta - 1` of the PRF output of `s`, for `eta` 2 or 3.
spec fn bsum(s: Seq<Secret<u8>>, k: int, eta: int) int {
    return pbit(s, k) as int + pbit(s, k + 1) as int + if eta > 2 {
        pbit(s, k + 2) as int
    } else {
        0
    };
}

/// Coefficient `i` of SamplePolyCBD_eta of the PRF output of `s` (FIPS 203, Algorithm 8): `x - y` modulo
/// q for `x` the sum of bits `2 i eta` to `2 i eta + eta - 1` and `y` that of the next `eta`.
pub spec fn cbd_coeff(s: Seq<Secret<u8>>, eta: int, i: int) int {
    return (bsum(s, 2 * i * eta, eta) - bsum(s, 2 * i * eta + eta, eta) + 3329) % 3329;
}

// Coefficients `c` to 255 of the polynomial at `fo` in `f` set to those of SamplePolyCBD_eta of the PRF
// output of `s`.
spec fn cbd(f: Seq<Secret<u32>>, fo: int, s: Seq<Secret<u8>>, eta: int, c: int) Seq<Secret<u32>>
    decreases 256 - c
{
    return if c >= 256 || c < 0 || fo < 0 || fo + 256 > f.len() {
        f
    } else {
        cbd(f.update(fo + c, Secret::new(cbd_coeff(s, eta, c) as u32)), fo, s, eta, c + 1)
    };
}

// `cbd` as a step.
lemma cbd_next(f: Seq<Secret<u32>>, fo: int, s: Seq<Secret<u8>>, eta: int, c: int, x: Secret<u32>, h: Seq<Secret<u32>>)
    requires 0 <= c && c < 256 && 0 <= fo && fo + 256 <= f.len()
    requires x.value() == cbd_coeff(s, eta, c) as u32 && h == f.update(fo + c, x)
    ensures cbd(f, fo, s, eta, c) == cbd(h, fo, s, eta, c + 1)
{}

// Bit `k` of the PRF output is bit `t` of byte `p` for `k == 8 p + t`.
lemma pbit_at(s: Seq<Secret<u8>>, k: int, p: int, t: int)
    requires 0 <= t && t < 8 && 0 <= p && k == p * 8 + t
    ensures pbit(s, k) == (sha3::output(s, 136, 0x1f, p) as u32 >> t as u32 & 1)
{
    arith::mod_unique(k, p, t, 8);
    pbit_eq(s, k, p, t);
}

// `pbit_at` from the quotient and the remainder.
lemma pbit_eq(s: Seq<Secret<u8>>, k: int, p: int, t: int)
    requires 0 <= t && t < 8 && 0 <= p && k / 8 == p && k % 8 == t && k >= 0
    ensures pbit(s, k) == (sha3::output(s, 136, 0x1f, p) as u32 >> t as u32 & 1)
{}

// `a0 + a1 - b0 - b1` modulo q for bits `a0`, `a1`, `b0` and `b1`.
@constant_time
fn cbd_val2(a0: Secret<u32>, a1: Secret<u32>, b0: Secret<u32>, b1: Secret<u32>) Secret<u32>
    requires a0.value() <= 1 && a1.value() <= 1 && b0.value() <= 1 && b1.value() <= 1
    ensures |r| r.value() == ((a0.value() as int + a1.value() as int - (b0.value() as int + b1.value() as int) + 3329) % 3329) as u32 && r.value() < 3329
{
    let s = a0 + a1 + Secret::new(3329u32) - b0 - b1;
    let t = s - Secret::new(3329u32);
    assert s.value() < 3329 || t.value() as int == s.value() as int - 3329 by {};
    let r = Secret::pick(s.lt(Secret::new(3329u32)), s, t);
    ghost let y = a0.value() as int + a1.value() as int - (b0.value() as int + b1.value() as int) + 3329;
    assert s.value() as int == y by {};
    arith::div_mod(y, 3329);
    assert y < 3329 || y / 3329 == 1 by {};
    assert y >= 3329 || y / 3329 == 0 by {};
    cast_q(r, y);
    return r;
}

// `a0 + a1 + a2 - b0 - b1 - b2` modulo q for bits `a0` to `b2`.
@constant_time
fn cbd_val3(a0: Secret<u32>, a1: Secret<u32>, a2: Secret<u32>, b0: Secret<u32>, b1: Secret<u32>, b2: Secret<u32>) Secret<
    u32
>
    requires a0.value() <= 1 && a1.value() <= 1 && a2.value() <= 1 && b0.value() <= 1 && b1.value() <= 1 && b2.value() <= 1
    ensures |r| r.value() == ((a0.value() as int + a1.value() as int + a2.value() as int - (b0.value() as int + b1.value() as int + b2.value() as int) + 3329) % 3329) as u32 && r.value() < 3329
{
    let s = a0 + a1 + a2 + Secret::new(3329u32) - b0 - b1 - b2;
    let t = s - Secret::new(3329u32);
    assert s.value() < 3329 || t.value() as int == s.value() as int - 3329 by {};
    let r = Secret::pick(s.lt(Secret::new(3329u32)), s, t);
    ghost let y = a0.value() as int + a1.value() as int + a2.value() as int - (b0.value() as int + b1.value() as int + b2.value() as int) + 3329;
    assert s.value() as int == y by {};
    arith::div_mod(y, 3329);
    assert y < 3329 || y / 3329 == 1 by {};
    assert y >= 3329 || y / 3329 == 0 by {};
    cast_q(r, y);
    return r;
}

// Coefficient `2 g + 0` of SamplePolyCBD_2 of the PRF output of `seed`, from its bytes 0 of group `g`.
@constant_time
fn cbd2_coeff0(x0: Secret<u8>, seed: []Secret<u8>, g: usize) Secret<u32>
    requires g < 128 && x0.value() == sha3::output(seed.view(), 136, 0x1f, (1 * g + 0) as int)
    ensures |r| r.value() == cbd_coeff(seed.view(), 2, 2 * g as int + 0) as u32 && r.value() < 3329
{
    pbit_at(seed.view(), 2 * (2 * g as int + 0) * 2 + 0, (1 * g + 0) as int, 0);
    pbit_at(seed.view(), 2 * (2 * g as int + 0) * 2 + 1, (1 * g + 0) as int, 1);
    pbit_at(seed.view(), 2 * (2 * g as int + 0) * 2 + 2, (1 * g + 0) as int, 2);
    pbit_at(seed.view(), 2 * (2 * g as int + 0) * 2 + 3, (1 * g + 0) as int, 3);
    return cbd_val2(
        x0.cast::<u32>() >> 0 & Secret::new(1u32),
        x0.cast::<u32>() >> 1 & Secret::new(1u32),
        x0.cast::<u32>() >> 2 & Secret::new(1u32),
        x0.cast::<u32>() >> 3 & Secret::new(1u32),
    );
}

// Coefficient `2 g + 1` of SamplePolyCBD_2 of the PRF output of `seed`, from its bytes 0 of group `g`.
@constant_time
fn cbd2_coeff1(x0: Secret<u8>, seed: []Secret<u8>, g: usize) Secret<u32>
    requires g < 128 && x0.value() == sha3::output(seed.view(), 136, 0x1f, (1 * g + 0) as int)
    ensures |r| r.value() == cbd_coeff(seed.view(), 2, 2 * g as int + 1) as u32 && r.value() < 3329
{
    pbit_at(seed.view(), 2 * (2 * g as int + 1) * 2 + 0, (1 * g + 0) as int, 4);
    pbit_at(seed.view(), 2 * (2 * g as int + 1) * 2 + 1, (1 * g + 0) as int, 5);
    pbit_at(seed.view(), 2 * (2 * g as int + 1) * 2 + 2, (1 * g + 0) as int, 6);
    pbit_at(seed.view(), 2 * (2 * g as int + 1) * 2 + 3, (1 * g + 0) as int, 7);
    return cbd_val2(
        x0.cast::<u32>() >> 4 & Secret::new(1u32),
        x0.cast::<u32>() >> 5 & Secret::new(1u32),
        x0.cast::<u32>() >> 6 & Secret::new(1u32),
        x0.cast::<u32>() >> 7 & Secret::new(1u32),
    );
}

// SamplePolyCBD_2 of the PRF output `b` of `seed` into the polynomial at `fo` in `f` (FIPS 203, Algorithm 8).
@constant_time
fn sample_cbd2(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, seed: []Secret<u8>)
    requires fo as int + 256 <= f.len() as int && b.len() == 128 && reduced(f.view())
    requires forall j in 0..b.len() { b.view()[j as int].value() == sha3::output(seed.view(), 136, 0x1f, j as int) }
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == cbd(old(f.view()), fo as int, seed.view(), 2, 0)
{
    for g in 0usize..128
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant cbd(f.view(), fo as int, seed.view(), 2, 2 * g as int) == cbd(
            old(f.view()),
            fo as int,
            seed.view(),
            2,
            0,
        )
    {
        let x0 = b[1 * g + 0];
        assert x0.value() == sha3::output(seed.view(), 136, 0x1f, (1 * g + 0) as int) by {};
        ghost let h0 = f.view();
        let r0 = cbd2_coeff0(x0, seed, g);
        reduced_update(f.view(), (fo + 2 * g + 0) as int, r0);
        f[fo + 2 * g + 0] = r0;
        cbd_next(h0, fo as int, seed.view(), 2, 2 * g as int + 0, r0, f.view());
        ghost let h1 = f.view();
        let r1 = cbd2_coeff1(x0, seed, g);
        reduced_update(f.view(), (fo + 2 * g + 1) as int, r1);
        f[fo + 2 * g + 1] = r1;
        cbd_next(h1, fo as int, seed.view(), 2, 2 * g as int + 1, r1, f.view());
    }
    assert cbd(f.view(), fo as int, seed.view(), 2, 256) == f.view() by {};
}

// Coefficient `4 g + 0` of SamplePolyCBD_3 of the PRF output of `seed`, from its bytes 0 of group `g`.
@constant_time
fn cbd3_coeff0(x0: Secret<u8>, seed: []Secret<u8>, g: usize) Secret<u32>
    requires g < 64 && x0.value() == sha3::output(seed.view(), 136, 0x1f, (3 * g + 0) as int)
    ensures |r| r.value() == cbd_coeff(seed.view(), 3, 4 * g as int + 0) as u32 && r.value() < 3329
{
    pbit_at(seed.view(), 2 * (4 * g as int + 0) * 3 + 0, (3 * g + 0) as int, 0);
    pbit_at(seed.view(), 2 * (4 * g as int + 0) * 3 + 1, (3 * g + 0) as int, 1);
    pbit_at(seed.view(), 2 * (4 * g as int + 0) * 3 + 2, (3 * g + 0) as int, 2);
    pbit_at(seed.view(), 2 * (4 * g as int + 0) * 3 + 3, (3 * g + 0) as int, 3);
    pbit_at(seed.view(), 2 * (4 * g as int + 0) * 3 + 4, (3 * g + 0) as int, 4);
    pbit_at(seed.view(), 2 * (4 * g as int + 0) * 3 + 5, (3 * g + 0) as int, 5);
    return cbd_val3(
        x0.cast::<u32>() >> 0 & Secret::new(1u32),
        x0.cast::<u32>() >> 1 & Secret::new(1u32),
        x0.cast::<u32>() >> 2 & Secret::new(1u32),
        x0.cast::<u32>() >> 3 & Secret::new(1u32),
        x0.cast::<u32>() >> 4 & Secret::new(1u32),
        x0.cast::<u32>() >> 5 & Secret::new(1u32),
    );
}

// Coefficient `4 g + 1` of SamplePolyCBD_3 of the PRF output of `seed`, from its bytes 0, 1 of group `g`.
@constant_time
fn cbd3_coeff1(x0: Secret<u8>, x1: Secret<u8>, seed: []Secret<u8>, g: usize) Secret<u32>
    requires g < 64 && x0.value() == sha3::output(seed.view(), 136, 0x1f, (3 * g + 0) as int) && x1.value() == sha3::output(
        seed.view(),
        136,
        0x1f,
        (3 * g + 1) as int,
    )
    ensures |r| r.value() == cbd_coeff(seed.view(), 3, 4 * g as int + 1) as u32 && r.value() < 3329
{
    pbit_at(seed.view(), 2 * (4 * g as int + 1) * 3 + 0, (3 * g + 0) as int, 6);
    pbit_at(seed.view(), 2 * (4 * g as int + 1) * 3 + 1, (3 * g + 0) as int, 7);
    pbit_at(seed.view(), 2 * (4 * g as int + 1) * 3 + 2, (3 * g + 1) as int, 0);
    pbit_at(seed.view(), 2 * (4 * g as int + 1) * 3 + 3, (3 * g + 1) as int, 1);
    pbit_at(seed.view(), 2 * (4 * g as int + 1) * 3 + 4, (3 * g + 1) as int, 2);
    pbit_at(seed.view(), 2 * (4 * g as int + 1) * 3 + 5, (3 * g + 1) as int, 3);
    return cbd_val3(
        x0.cast::<u32>() >> 6 & Secret::new(1u32),
        x0.cast::<u32>() >> 7 & Secret::new(1u32),
        x1.cast::<u32>() >> 0 & Secret::new(1u32),
        x1.cast::<u32>() >> 1 & Secret::new(1u32),
        x1.cast::<u32>() >> 2 & Secret::new(1u32),
        x1.cast::<u32>() >> 3 & Secret::new(1u32),
    );
}

// Coefficient `4 g + 2` of SamplePolyCBD_3 of the PRF output of `seed`, from its bytes 1, 2 of group `g`.
@constant_time
fn cbd3_coeff2(x1: Secret<u8>, x2: Secret<u8>, seed: []Secret<u8>, g: usize) Secret<u32>
    requires g < 64 && x1.value() == sha3::output(seed.view(), 136, 0x1f, (3 * g + 1) as int) && x2.value() == sha3::output(
        seed.view(),
        136,
        0x1f,
        (3 * g + 2) as int,
    )
    ensures |r| r.value() == cbd_coeff(seed.view(), 3, 4 * g as int + 2) as u32 && r.value() < 3329
{
    pbit_at(seed.view(), 2 * (4 * g as int + 2) * 3 + 0, (3 * g + 1) as int, 4);
    pbit_at(seed.view(), 2 * (4 * g as int + 2) * 3 + 1, (3 * g + 1) as int, 5);
    pbit_at(seed.view(), 2 * (4 * g as int + 2) * 3 + 2, (3 * g + 1) as int, 6);
    pbit_at(seed.view(), 2 * (4 * g as int + 2) * 3 + 3, (3 * g + 1) as int, 7);
    pbit_at(seed.view(), 2 * (4 * g as int + 2) * 3 + 4, (3 * g + 2) as int, 0);
    pbit_at(seed.view(), 2 * (4 * g as int + 2) * 3 + 5, (3 * g + 2) as int, 1);
    return cbd_val3(
        x1.cast::<u32>() >> 4 & Secret::new(1u32),
        x1.cast::<u32>() >> 5 & Secret::new(1u32),
        x1.cast::<u32>() >> 6 & Secret::new(1u32),
        x1.cast::<u32>() >> 7 & Secret::new(1u32),
        x2.cast::<u32>() >> 0 & Secret::new(1u32),
        x2.cast::<u32>() >> 1 & Secret::new(1u32),
    );
}

// Coefficient `4 g + 3` of SamplePolyCBD_3 of the PRF output of `seed`, from its bytes 2 of group `g`.
@constant_time
fn cbd3_coeff3(x2: Secret<u8>, seed: []Secret<u8>, g: usize) Secret<u32>
    requires g < 64 && x2.value() == sha3::output(seed.view(), 136, 0x1f, (3 * g + 2) as int)
    ensures |r| r.value() == cbd_coeff(seed.view(), 3, 4 * g as int + 3) as u32 && r.value() < 3329
{
    pbit_at(seed.view(), 2 * (4 * g as int + 3) * 3 + 0, (3 * g + 2) as int, 2);
    pbit_at(seed.view(), 2 * (4 * g as int + 3) * 3 + 1, (3 * g + 2) as int, 3);
    pbit_at(seed.view(), 2 * (4 * g as int + 3) * 3 + 2, (3 * g + 2) as int, 4);
    pbit_at(seed.view(), 2 * (4 * g as int + 3) * 3 + 3, (3 * g + 2) as int, 5);
    pbit_at(seed.view(), 2 * (4 * g as int + 3) * 3 + 4, (3 * g + 2) as int, 6);
    pbit_at(seed.view(), 2 * (4 * g as int + 3) * 3 + 5, (3 * g + 2) as int, 7);
    return cbd_val3(
        x2.cast::<u32>() >> 2 & Secret::new(1u32),
        x2.cast::<u32>() >> 3 & Secret::new(1u32),
        x2.cast::<u32>() >> 4 & Secret::new(1u32),
        x2.cast::<u32>() >> 5 & Secret::new(1u32),
        x2.cast::<u32>() >> 6 & Secret::new(1u32),
        x2.cast::<u32>() >> 7 & Secret::new(1u32),
    );
}

// SamplePolyCBD_3 of the PRF output `b` of `seed` into the polynomial at `fo` in `f` (FIPS 203, Algorithm 8).
@constant_time
fn sample_cbd3(f: []mut Secret<u32>, fo: usize, b: []Secret<u8>, seed: []Secret<u8>)
    requires fo as int + 256 <= f.len() as int && b.len() == 192 && reduced(f.view())
    requires forall j in 0..b.len() { b.view()[j as int].value() == sha3::output(seed.view(), 136, 0x1f, j as int) }
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == cbd(old(f.view()), fo as int, seed.view(), 3, 0)
{
    for g in 0usize..64
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant cbd(f.view(), fo as int, seed.view(), 3, 4 * g as int) == cbd(
            old(f.view()),
            fo as int,
            seed.view(),
            3,
            0,
        )
    {
        let x0 = b[3 * g + 0];
        assert x0.value() == sha3::output(seed.view(), 136, 0x1f, (3 * g + 0) as int) by {};
        let x1 = b[3 * g + 1];
        assert x1.value() == sha3::output(seed.view(), 136, 0x1f, (3 * g + 1) as int) by {};
        let x2 = b[3 * g + 2];
        assert x2.value() == sha3::output(seed.view(), 136, 0x1f, (3 * g + 2) as int) by {};
        ghost let h0 = f.view();
        let r0 = cbd3_coeff0(x0, seed, g);
        reduced_update(f.view(), (fo + 4 * g + 0) as int, r0);
        f[fo + 4 * g + 0] = r0;
        cbd_next(h0, fo as int, seed.view(), 3, 4 * g as int + 0, r0, f.view());
        ghost let h1 = f.view();
        let r1 = cbd3_coeff1(x0, x1, seed, g);
        reduced_update(f.view(), (fo + 4 * g + 1) as int, r1);
        f[fo + 4 * g + 1] = r1;
        cbd_next(h1, fo as int, seed.view(), 3, 4 * g as int + 1, r1, f.view());
        ghost let h2 = f.view();
        let r2 = cbd3_coeff2(x1, x2, seed, g);
        reduced_update(f.view(), (fo + 4 * g + 2) as int, r2);
        f[fo + 4 * g + 2] = r2;
        cbd_next(h2, fo as int, seed.view(), 3, 4 * g as int + 2, r2, f.view());
        ghost let h3 = f.view();
        let r3 = cbd3_coeff3(x2, seed, g);
        reduced_update(f.view(), (fo + 4 * g + 3) as int, r3);
        f[fo + 4 * g + 3] = r3;
        cbd_next(h3, fo as int, seed.view(), 3, 4 * g as int + 3, r3, f.view());
    }
    assert cbd(f.view(), fo as int, seed.view(), 3, 256) == f.view() by {};
}

// Whether `eta` is an eta of the parameter sets (2 or 3).
spec fn eta_ok(eta: int) bool {
    return eta == 2 || eta == 3;
}

// The seed of matrix entry `m` (row `m / k`, column `m % k`) of FIPS 203, Algorithm 13, line 5: `rho`,
// the column, the row.
spec fn mat_seed(rho: Seq<Secret<u8>>, k: int, m: int) Seq<Secret<u8>> {
    return if k < 1 {
        rho
    } else {
        rho.push(Secret::new((m % k) as u8)).push(Secret::new((m / k) as u8))
    };
}

// Matrix entries `m` to `k k - 1` of `a` sampled (FIPS 203, Algorithm 13, lines 3 to 7), entry `m` at
// polynomial `m`.
spec fn mat(a: Seq<Secret<u32>>, rho: Seq<Secret<u8>>, k: int, m: int) Seq<Secret<u32>>
    decreases k * k - m
{
    return if m >= k * k || m < 0 || k < 1 {
        a
    } else {
        mat(sampled(a, 256 * m, mat_seed(rho, k, m), 0, 0), rho, k, m + 1)
    };
}

// Whether SampleNTT sets every coefficient of entries `m` to `k k - 1`.
spec fn mat_ok(rho: Seq<Secret<u8>>, k: int, m: int) bool
    decreases k * k - m
{
    return if m >= k * k || m < 0 || k < 1 {
        true
    } else {
        sample_ok(mat_seed(rho, k, m)) && mat_ok(rho, k, m + 1)
    };
}

// `mat` and `mat_ok` as a step.
lemma mat_next(a: Seq<Secret<u32>>, rho: Seq<Secret<u8>>, k: int, m: int, b: Seq<Secret<u32>>, ok: bool)
    requires 1 <= k && 0 <= m && m < k * k
    requires b == sampled(a, 256 * m, mat_seed(rho, k, m), 0, 0) && ok == sample_ok(mat_seed(rho, k, m))
    ensures mat(a, rho, k, m) == mat(b, rho, k, m + 1) && mat_ok(rho, k, m) == (ok && mat_ok(rho, k, m + 1))
{}

// The matrix of seed `rho` into `a` (FIPS 203, Algorithm 13, lines 3 to 7): whether every entry was
// sampled within the iteration bound.
fn sample_matrix(a: []mut Secret<u32>, rho: []Secret<u8>, k: usize) bool
    requires 2 <= k && k <= 4 && a.len() as int == 256 * k as int * k as int && reduced(a.view())
    ensures |ok| a.len() == old(a.len()) && reduced(a.view()) && a.view() == mat(old(a.view()), rho.view(), k as int, 0)
    ensures |ok| ok == mat_ok(rho.view(), k as int, 0)
{
    let mut ok = true;
    for m in 0..k * k
        invariant a.len() == old(a.len()) && reduced(a.view())
        invariant mat(a.view(), rho.view(), k as int, m as int) == mat(old(a.view()), rho.view(), k as int, 0)
        invariant (ok && mat_ok(rho.view(), k as int, m as int)) == mat_ok(rho.view(), k as int, 0)
    {
        arith::mul_le(m as int + 1, k as int * k as int, 256);
        let s1 = with_byte(rho, Secret::new((m % k) as u8));
        let seed = with_byte(&s1, Secret::new((m / k) as u8));
        assert seed.view() == mat_seed(rho.view(), k as int, m as int) by {};
        ghost let a0 = a.view();
        let one = sample_ntt(a, 256 * m, &seed);
        mat_next(a0, rho.view(), k as int, m as int, a.view(), one);
        ok = ok && one;
    }
    return ok;
}

// Polynomials `i` to `k - 1` of `f` set to SamplePolyCBD_eta(PRF_eta(s, n0 + i)) (FIPS 203, Algorithm 13,
// lines 8 to 15).
spec fn cbd_vec(f: Seq<Secret<u32>>, s: Seq<Secret<u8>>, eta: int, k: int, n0: int, i: int) Seq<Secret<u32>>
    decreases k - i
{
    return if i >= k || i < 0 {
        f
    } else {
        cbd_vec(cbd(f, 256 * i, s.push(Secret::new((n0 + i) as u8)), eta, 0), s, eta, k, n0, i + 1)
    };
}

// `cbd_vec` as a step.
lemma cbd_vec_next(f: Seq<Secret<u32>>, s: Seq<Secret<u8>>, eta: int, k: int, n0: int, i: int, g: Seq<Secret<u32>>)
    requires 0 <= i && i < k && g == cbd(f, 256 * i, s.push(Secret::new((n0 + i) as u8)), eta, 0)
    ensures cbd_vec(f, s, eta, k, n0, i) == cbd_vec(g, s, eta, k, n0, i + 1)
{}

// SamplePolyCBD_eta(PRF_eta(seed)) into the polynomial at `fo` in `f` (FIPS 203, Algorithm 13, lines 9
// and 13).
@constant_time
fn noise_poly(f: []mut Secret<u32>, fo: usize, seed: []Secret<u8>, eta: usize)
    requires eta_ok(eta as int) && fo as int + 256 <= f.len() as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == cbd(
        old(f.view()),
        fo as int,
        seed.view(),
        eta as int,
        0,
    )
{
    let mut b = new_bytes(64 * eta);
    sha3::shake256(seed, &mut b);
    if eta == 2 {
        sample_cbd2(f, fo, &b, seed);
    } else {
        sample_cbd3(f, fo, &b, seed);
    }
}

// The noise vector of seed `s` with counters from `n0` into `f` (FIPS 203, Algorithm 13, lines 8 to 15).
@constant_time
fn sample_noise(f: []mut Secret<u32>, s: []Secret<u8>, eta: usize, k: usize, n0: usize)
    requires 1 <= k && k <= 4 && eta_ok(eta as int) && n0 <= 8 && f.len() as int == 256 * k as int && reduced(f.view())
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == cbd_vec(
        old(f.view()),
        s.view(),
        eta as int,
        k as int,
        n0 as int,
        0,
    )
{
    for i in 0..k
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant cbd_vec(f.view(), s.view(), eta as int, k as int, n0 as int, i as int) == cbd_vec(
            old(f.view()),
            s.view(),
            eta as int,
            k as int,
            n0 as int,
            0,
        )
    {
        let seed = with_byte(s, Secret::new((n0 + i) as u8));
        ghost let f0 = f.view();
        noise_poly(f, 256 * i, &seed, eta);
        cbd_vec_next(f0, s.view(), eta as int, k as int, n0 as int, i as int, f.view());
    }
}

// The input of G in FIPS 203, Algorithm 13, line 1: `d` and the byte `k`.
spec fn g_seed(d: Seq<Secret<u8>>, k: int) Seq<Secret<u8>> {
    return d.push(Secret::new(k as u8));
}

// rho and sigma of FIPS 203, Algorithm 13, line 1: the halves of G(d || k).
spec fn rho_of(d: Seq<Secret<u8>>, k: int) Seq<Secret<u8>> {
    return out_seq(g_seed(d, k), 72, 6, 0, 32);
}

spec fn sigma_of(d: Seq<Secret<u8>>, k: int) Seq<Secret<u8>> {
    return out_seq(g_seed(d, k), 72, 6, 32, 32);
}

/// The matrix A-hat of seed `rho` (FIPS 203, Algorithm 13, lines 3 to 7), entry (`i`, `j`) at
/// polynomial `k i + j`.
pub spec fn a_hat(rho: Seq<Secret<u8>>, k: int) Seq<Secret<u32>> {
    return mat(zeros32(256 * k * k), rho, k, 0);
}

/// s-hat of FIPS 203, Algorithm 13, lines 8 to 11 and 16, of seed `sigma`.
pub spec fn s_hat(sigma: Seq<Secret<u8>>, k: int, eta1: int) Seq<Secret<u32>> {
    return ntt_vec(cbd_vec(zeros32(256 * k), sigma, eta1, k, 0, 0), k, false, 0);
}

/// t-hat of FIPS 203, Algorithm 13, lines 12 to 15, 17 and 18, of seeds `rho` and `sigma`.
pub spec fn t_hat(rho: Seq<Secret<u8>>, sigma: Seq<Secret<u8>>, k: int, eta1: int) Seq<Secret<u32>> {
    return vadd(
        rows(zeros32(256 * k), a_hat(rho, k), s_hat(sigma, k, eta1), k, false, 0),
        ntt_vec(cbd_vec(zeros32(256 * k), sigma, eta1, k, k, 0), k, false, 0),
        k,
        false,
        0,
    );
}

// The NTT of the noise vector of seed `sigma` with counters from `n0` (FIPS 203, Algorithm 13, lines 8 to
// 16; Algorithm 14, lines 9 to 12 without the NTT).
@constant_time
fn noise_vec(sigma: []Secret<u8>, eta: usize, k: usize, n0: usize, hat: bool) Vector<Secret<u32>>
    requires 1 <= k && k <= 4 && eta_ok(eta as int) && n0 <= 8
    ensures |v| v.len() as int == 256 * k as int && reduced(v.view())
    ensures |v| hat ==> v.view() == ntt_vec(
        cbd_vec(zeros32(256 * k as int), sigma.view(), eta as int, k as int, n0 as int, 0),
        k as int,
        false,
        0,
    )
    ensures |v| !hat ==> v.view() == cbd_vec(zeros32(256 * k as int), sigma.view(), eta as int, k as int, n0 as int, 0)
{
    let mut v = new_polys(256 * k);
    sample_noise(&mut v, sigma, eta, k, n0);
    if hat {
        ntt_all(&mut v, k, false);
    }
    return v;
}

// A-hat times `s` plus `e` (FIPS 203, Algorithm 13, line 18).
@constant_time
fn mat_vec_add(a: []Secret<u32>, s: []Secret<u32>, e: []Secret<u32>, k: usize) Vector<Secret<u32>>
    requires 2 <= k && k <= 4 && a.len() as int == 256 * k as int * k as int && s.len() as int == 256 * k as int && e.len() as int == 256 * k as int
    requires reduced(a.view()) && reduced(s.view()) && reduced(e.view())
    ensures |t| t.len() as int == 256 * k as int && reduced(t.view())
    ensures |t| t.view() == vadd(
        rows(zeros32(256 * k as int), a.view(), s.view(), k as int, false, 0),
        e.view(),
        k as int,
        false,
        0,
    )
{
    let mut t = new_polys(256 * k);
    mat_mul(&mut t, a, s, k, false);
    vec_add(&mut t, e, k, false);
    return t;
}

// The matrix A-hat of seed `rho`: whether SampleNTT set every coefficient within its iteration bound.
fn matrix(a: []mut Secret<u32>, rho: []Secret<u8>, k: usize) bool
    requires 2 <= k && k <= 4 && a.len() as int == 256 * k as int * k as int && a.view() == zeros32(
        256 * k as int * k as int,
    )
    ensures |ok| a.len() == old(a.len()) && reduced(a.view()) && a.view() == a_hat(rho.view(), k as int) && ok == mat_ok(
        rho.view(),
        k as int,
        0,
    )
{
    zeros_reduced(256 * k as int * k as int);
    return sample_matrix(a, rho, k);
}

// `n` zero coefficients lie below q.
lemma zeros_reduced(n: int)
    ensures reduced(zeros32(n))
    decreases n
{
    if n > 0 {
        zeros_reduced(n - 1);
        reduced_push(zeros32(n - 1), Secret::new(0u32));
    }
}

// Lines 3 to 20 of K-PKE.KeyGen (FIPS 203, Algorithm 13) from seeds `rho` and `sigma`: ek_PKE into `ek`
// from `eo` on and dk_PKE into `dk` from `dko` on; whether SampleNTT set every coefficient of A-hat within
// its iteration bound.
fn kpke_core(
    rho: []Secret<u8>,
    sigma: []Secret<u8>,
    k: usize,
    eta1: usize,
    ek: []mut Secret<u8>,
    eo: usize,
    dk: []mut Secret<u8>,
    dko: usize,
) bool
    requires rho.len() == 32 && 2 <= k && k <= 4 && eta_ok(eta1 as int)
    requires eo as int + 384 * k as int + 32 <= ek.len() as int && dko as int + 384 * k as int <= dk.len() as int
    ensures |ok| ek.len() == old(ek.len()) && dk.len() == old(dk.len()) && ok == mat_ok(rho.view(), k as int, 0)
    ensures |ok| ek.view() == copied(
        enc_vec(old(ek.view()), eo as int, t_hat(rho.view(), sigma.view(), k as int, eta1 as int), k as int, 0),
        eo as int + 384 * k as int,
        rho.view(),
        0,
    )
    ensures |ok| dk.view() == enc_vec(
        old(dk.view()),
        dko as int,
        s_hat(sigma.view(), k as int, eta1 as int),
        k as int,
        0,
    )
{
    let mut a = new_polys(256 * k * k);
    let ok = matrix(&mut a, rho, k);
    let s = noise_vec(sigma, eta1, k, 0, true);
    let e = noise_vec(sigma, eta1, k, k, true);
    let t = mat_vec_add(&a, &s, &e, k);
    encode_vec(ek, eo, &t, k);
    copy_bytes(ek, eo + 384 * k, rho);
    encode_vec(dk, dko, &s, k);
    return ok;
}

// K-PKE.KeyGen(d) (FIPS 203, Algorithm 13): ek_PKE into `ek` from `eo` on and dk_PKE into `dk` from `dko`
// on; whether SampleNTT set every coefficient of A-hat within its iteration bound.
fn kpke_keygen(
    d: []Secret<u8>,
    k: usize,
    eta1: usize,
    ek: []mut Secret<u8>,
    eo: usize,
    dk: []mut Secret<u8>,
    dko: usize,
) bool
    requires d.len() == 32 && 2 <= k && k <= 4 && eta_ok(eta1 as int)
    requires eo as int + 384 * k as int + 32 <= ek.len() as int && dko as int + 384 * k as int <= dk.len() as int
    ensures |ok| ek.len() == old(ek.len()) && dk.len() == old(dk.len()) && ok == mat_ok(
        rho_of(d.view(), k as int),
        k as int,
        0,
    )
    ensures |ok| ek.view() == copied(
        enc_vec(
            old(ek.view()),
            eo as int,
            t_hat(rho_of(d.view(), k as int), sigma_of(d.view(), k as int), k as int, eta1 as int),
            k as int,
            0,
        ),
        eo as int + 384 * k as int,
        rho_of(d.view(), k as int),
        0,
    )
    ensures |ok| dk.view() == enc_vec(
        old(dk.view()),
        dko as int,
        s_hat(sigma_of(d.view(), k as int), k as int, eta1 as int),
        k as int,
        0,
    )
{
    let gin = with_byte(d, Secret::new(k as u8));
    let gd = sha3::sha3_512(&gin);
    let rho = g_part0(gd, &gin);
    let sigma = g_part32(gd, &gin);
    out_seq_len(gin.view(), 72, 6, 0, 32);
    assert gin.view() == g_seed(d.view(), k as int) by {};
    assert rho.view() == rho_of(d.view(), k as int) && sigma.view() == sigma_of(d.view(), k as int) by {};
    return kpke_core(&rho, &sigma, k, eta1, ek, eo, dk, dko);
}

// Polynomials `i` to `k - 1` of `f` set to ByteDecode_d of the bytes from `bo` in `b`, `32 d` bytes each.
spec fn dvec(f: Seq<Secret<u32>>, b: Seq<Secret<u8>>, bo: int, k: int, d: int, i: int) Seq<Secret<u32>>
    decreases k - i
{
    return if i >= k || i < 0 {
        f
    } else {
        dvec(decoded(f, 256 * i, b, bo + 32 * d * i, d, 0), b, bo, k, d, i + 1)
    };
}

// `dvec` as a step.
lemma dvec_next(f: Seq<Secret<u32>>, b: Seq<Secret<u8>>, bo: int, k: int, d: int, i: int, h: Seq<Secret<u32>>)
    requires 0 <= i && i < k && h == decoded(f, 256 * i, b, bo + 32 * d * i, d, 0)
    ensures dvec(f, b, bo, k, d, i) == dvec(h, b, bo, k, d, i + 1)
{}

// ByteDecode_12 of `k` polynomials from `bo` in `b` into `f`.
@constant_time
fn decode_vec(f: []mut Secret<u32>, b: []Secret<u8>, bo: usize, k: usize)
    requires 1 <= k && k <= 4 && f.len() as int == 256 * k as int && bo as int + 384 * k as int <= b.len() as int && reduced(
        f.view(),
    )
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == dvec(
        old(f.view()),
        b.view(),
        bo as int,
        k as int,
        12,
        0,
    )
{
    for i in 0..k
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant dvec(f.view(), b.view(), bo as int, k as int, 12, i as int) == dvec(
            old(f.view()),
            b.view(),
            bo as int,
            k as int,
            12,
            0,
        )
    {
        ghost let f0 = f.view();
        decode12(f, 256 * i, b, bo + 384 * i);
        dvec_next(f0, b.view(), bo as int, k as int, 12, i as int, f.view());
    }
}

// Polynomials `i` to `k - 1` of `f` compressed with `d` bits.
spec fn cvec(f: Seq<Secret<u32>>, k: int, d: int, i: int) Seq<Secret<u32>>
    decreases k - i
{
    return if i >= k || i < 0 {
        f
    } else {
        cvec(compressed(f, 256 * i, d, false, 0), k, d, i + 1)
    };
}

// `cvec` as a step.
lemma cvec_next(f: Seq<Secret<u32>>, k: int, d: int, i: int, h: Seq<Secret<u32>>)
    requires 0 <= i && i < k && h == compressed(f, 256 * i, d, false, 0)
    ensures cvec(f, k, d, i) == cvec(h, k, d, i + 1)
{}

// Bytes of `out` from `oo` on set to ByteEncode_d of polynomials `i` to `k - 1` of `f`, `32 d` bytes each.
spec fn evec(out: Seq<Secret<u8>>, oo: int, f: Seq<Secret<u32>>, k: int, d: int, i: int) Seq<Secret<u8>>
    decreases k - i
{
    return if i >= k || i < 0 {
        out
    } else {
        evec(encoded(out, oo + 32 * d * i, f, 256 * i, d, 0), oo, f, k, d, i + 1)
    };
}

// `evec` as a step.
lemma evec_next(
    out: Seq<Secret<u8>>,
    oo: int,
    off: int,
    fo: int,
    f: Seq<Secret<u32>>,
    k: int,
    d: int,
    i: int,
    h: Seq<Secret<u8>>,
)
    requires 0 <= i && i < k && off == oo + 32 * d * i && fo == 256 * i && h == encoded(out, off, f, fo, d, 0)
    ensures evec(out, oo, f, k, d, i) == evec(h, oo, f, k, d, i + 1)
{}

// ByteEncode_d(Compress_d) of the `k` polynomials of `f` into `out` from `oo` on (FIPS 203, Algorithm
// 14, lines 22 and 23); `f` keeps the compressed values.
@constant_time
fn compress_encode(out: []mut Secret<u8>, oo: usize, f: []mut Secret<u32>, k: usize, d: usize)
    requires 1 <= k && k <= 4 && d_ok(d as int, false) && f.len() as int == 256 * k as int && reduced(f.view())
    requires oo as int + 32 * d as int * k as int <= out.len() as int
    ensures out.len() == old(out.len()) && f.len() == old(f.len())
    ensures out.view() == evec(
        old(out.view()),
        oo as int,
        cvec(old(f.view()), k as int, d as int, 0),
        k as int,
        d as int,
        0,
    )
{
    for i in 0..k
        invariant f.len() == old(f.len()) && reduced(f.view())
        invariant cvec(f.view(), k as int, d as int, i as int) == cvec(old(f.view()), k as int, d as int, 0)
    {
        ghost let f0 = f.view();
        compress_d(f, 256 * i, d);
        cvec_next(f0, k as int, d as int, i as int, f.view());
    }
    assert cvec(f.view(), k as int, d as int, k as int) == f.view() by {};
    let mut off = oo;
    for i in 0..k
        invariant out.len() == old(out.len()) && off as int == oo as int + 32 * d as int * i as int
        invariant evec(out.view(), oo as int, f.view(), k as int, d as int, i as int) == evec(
            old(out.view()),
            oo as int,
            f.view(),
            k as int,
            d as int,
            0,
        )
    {
        arith::mul_le(i as int + 1, k as int, 32 * d as int);
        ghost let o0 = out.view();
        encode_d(out, off, f, 256 * i, d);
        evec_next(o0, oo as int, off as int, (256 * i) as int, f.view(), k as int, d as int, i as int, out.view());
        off += 32 * d;
    }
}

// The polynomial at `to` in `t` plus the NTT-domain products of polynomials `j` to `k - 1` of `a` and
// `s` (FIPS 203, (2.13)).
spec fn drow(t: Seq<Secret<u32>>, to: int, a: Seq<Secret<u32>>, s: Seq<Secret<u32>>, k: int, j: int) Seq<Secret<u32>>
    decreases k - j
{
    return if j >= k || j < 0 {
        t
    } else {
        drow(macc(t, to, a, 256 * j, s, 256 * j, 0), to, a, s, k, j + 1)
    };
}

// `drow` as a step.
lemma drow_next(
    t: Seq<Secret<u32>>,
    to: int,
    a: Seq<Secret<u32>>,
    s: Seq<Secret<u32>>,
    k: int,
    j: int,
    h: Seq<Secret<u32>>,
)
    requires 0 <= j && j < k && h == macc(t, to, a, 256 * j, s, 256 * j, 0)
    ensures drow(t, to, a, s, k, j) == drow(h, to, a, s, k, j + 1)
{}

// Adds the NTT-domain dot product of vectors `a` and `s` to the polynomial at `to` in `t`.
@constant_time
fn dot(t: []mut Secret<u32>, to: usize, a: []Secret<u32>, s: []Secret<u32>, k: usize)
    requires 1 <= k && k <= 4 && to as int + 256 <= t.len() as int && a.len() as int == 256 * k as int && s.len() as int == 256 * k as int
    requires reduced(t.view()) && reduced(a.view()) && reduced(s.view())
    ensures t.len() == old(t.len()) && reduced(t.view()) && t.view() == drow(
        old(t.view()),
        to as int,
        a.view(),
        s.view(),
        k as int,
        0,
    )
{
    for j in 0..k
        invariant t.len() == old(t.len()) && reduced(t.view())
        invariant drow(t.view(), to as int, a.view(), s.view(), k as int, j as int) == drow(
            old(t.view()),
            to as int,
            a.view(),
            s.view(),
            k as int,
            0,
        )
    {
        ghost let t0 = t.view();
        mul_acc(t, to, a, 256 * j, s, 256 * j);
        drow_next(t0, to as int, a.view(), s.view(), k as int, j as int, t.view());
    }
}

/// u of FIPS 203, Algorithm 14, line 19: NTT^-1(A-hat^T y-hat) + e1.
pub spec fn u_spec(a: Seq<Secret<u32>>, y: Seq<Secret<u32>>, e1: Seq<Secret<u32>>, k: int) Seq<Secret<u32>> {
    return vadd(ntt_vec(rows(zeros32(256 * k), a, y, k, true, 0), k, true, 0), e1, k, false, 0);
}

// u of FIPS 203, Algorithm 14, line 19.
@constant_time
fn u_of(a: []Secret<u32>, y: []Secret<u32>, e1: []Secret<u32>, k: usize) Vector<Secret<u32>>
    requires 2 <= k && k <= 4 && a.len() as int == 256 * k as int * k as int && y.len() as int == 256 * k as int && e1.len() as int == 256 * k as int
    requires reduced(a.view()) && reduced(y.view()) && reduced(e1.view())
    ensures |u| u.len() as int == 256 * k as int && reduced(u.view()) && u.view() == u_spec(
        a.view(),
        y.view(),
        e1.view(),
        k as int,
    )
{
    let mut u = new_polys(256 * k);
    mat_mul(&mut u, a, y, k, true);
    ntt_all(&mut u, k, true);
    vec_add(&mut u, e1, k, false);
    return u;
}

/// v of FIPS 203, Algorithm 14, line 21: NTT^-1(t-hat^T y-hat) + e2 + mu.
pub spec fn v_spec(t: Seq<Secret<u32>>, y: Seq<Secret<u32>>, e2: Seq<Secret<u32>>, mu: Seq<Secret<u32>>, k: int) Seq<
    Secret<u32>
> {
    return padd(padd(intt_spec(drow(zeros32(256), 0, t, y, k, 0), 0), 0, e2, 0, false, 0), 0, mu, 0, false, 0);
}

// v of FIPS 203, Algorithm 14, line 21.
@constant_time
fn v_of(t: []Secret<u32>, y: []Secret<u32>, e2: []Secret<u32>, mu: []Secret<u32>, k: usize) Vector<Secret<u32>>
    requires 2 <= k && k <= 4 && t.len() as int == 256 * k as int && y.len() as int == 256 * k as int && e2.len() == 256 && mu.len() == 256
    requires reduced(t.view()) && reduced(y.view()) && reduced(e2.view()) && reduced(mu.view())
    ensures |v| v.len() == 256 && reduced(v.view()) && v.view() == v_spec(
        t.view(),
        y.view(),
        e2.view(),
        mu.view(),
        k as int,
    )
{
    let mut v = new_polys(256);
    dot(&mut v, 0, t, y, k);
    intt(&mut v, 0);
    poly_add(&mut v, 0, e2, 0, false);
    poly_add(&mut v, 0, mu, 0, false);
    return v;
}

/// mu of FIPS 203, Algorithm 14, line 20: Decompress_1(ByteDecode_1(m)).
pub spec fn mu_spec(m: Seq<Secret<u8>>) Seq<Secret<u32>> {
    return compressed(decoded(zeros32(256), 0, m, 0, 1, 0), 0, 1, true, 0);
}

// mu of FIPS 203, Algorithm 14, line 20.
@constant_time
fn mu_of(m: []Secret<u8>) Vector<Secret<u32>>
    requires m.len() == 32
    ensures |v| v.len() == 256 && reduced(v.view()) && v.view() == mu_spec(m.view())
{
    let mut v = new_polys(256);
    decode1(&mut v, 0, m, 0);
    decompress_poly1(&mut v, 0);
    return v;
}

// Elements `lo` to `hi - 1` of `s`, one more: element `hi` after them.
lemma sub_next(s: Seq<Secret<u8>>, lo: int, hi: int)
    requires 0 <= lo && lo <= hi && hi < s.len()
    ensures s.subrange(lo, hi + 1) == s.subrange(lo, hi).push(s[hi])
{}

// Bytes `lo` to `lo + n - 1` of `s` as a vector.
fn bytes_at(s: []Secret<u8>, lo: usize, n: usize) Vector<Secret<u8>>
    requires lo as int + n as int <= s.len() as int
    ensures |v| v.len() == n && v.view() == s.view().subrange(lo as int, lo as int + n as int)
{
    let mut v = Vector::<Secret<u8>>::with_capacity(n);
    for j in 0..n
        invariant v.len() == j && v.view() == s.view().subrange(lo as int, lo as int + j as int)
    {
        sub_next(s.view(), lo as int, lo as int + j as int);
        v.push(s[lo + j]);
    }
    return v;
}

/// t-hat of FIPS 203, Algorithm 14, line 2: ByteDecode_12 of the first `384 k` bytes of `ek`.
pub spec fn t_ek(ek: Seq<Secret<u8>>, k: int) Seq<Secret<u32>> {
    return dvec(zeros32(256 * k), ek, 0, k, 12, 0);
}

/// rho of FIPS 203, Algorithm 14, line 3: bytes `384 k` to `384 k + 31` of `ek`.
pub spec fn rho_ek(ek: Seq<Secret<u8>>, k: int) Seq<Secret<u8>> {
    return if k < 0 || 384 * k + 32 > ek.len() {
        ek
    } else {
        ek.subrange(384 * k, 384 * k + 32)
    };
}

/// c of K-PKE.Encrypt(ek, m, r) (FIPS 203, Algorithm 14) written over `c` from `co` on.
pub spec fn pke_c(
    c: Seq<Secret<u8>>,
    co: int,
    ek: Seq<Secret<u8>>,
    m: Seq<Secret<u8>>,
    r: Seq<Secret<u8>>,
    k: int,
    eta1: int,
    eta2: int,
    du: int,
    dv: int,
) Seq<Secret<u8>> {
    return evec(
        evec(
            c,
            co,
            cvec(
                u_spec(a_hat(rho_ek(ek, k), k), s_hat(r, k, eta1), cbd_vec(zeros32(256 * k), r, eta2, k, k, 0), k),
                k,
                du,
                0,
            ),
            k,
            du,
            0,
        ),
        co + 32 * du * k,
        cvec(
            v_spec(t_ek(ek, k), s_hat(r, k, eta1), cbd_vec(zeros32(256), r, eta2, 1, 2 * k, 0), mu_spec(m), k),
            1,
            dv,
            0,
        ),
        1,
        dv,
        0,
    );
}

// t-hat of FIPS 203, Algorithm 14, line 2.
@constant_time
fn t_of(ek: []Secret<u8>, k: usize) Vector<Secret<u32>>
    requires 2 <= k && k <= 4 && ek.len() as int == 384 * k as int + 32
    ensures |t| t.len() as int == 256 * k as int && reduced(t.view()) && t.view() == t_ek(ek.view(), k as int)
{
    let mut t = new_polys(256 * k);
    decode_vec(&mut t, ek, 0, k);
    return t;
}

// K-PKE.Encrypt(ek, m, r) (FIPS 203, Algorithm 14): c into `c` from `co` on; whether SampleNTT set every
// coefficient of A-hat within its iteration bound.
fn kpke_encrypt(
    ek: []Secret<u8>,
    m: []Secret<u8>,
    r: []Secret<u8>,
    k: usize,
    eta1: usize,
    eta2: usize,
    du: usize,
    dv: usize,
    c: []mut Secret<u8>,
    co: usize,
) bool
    requires 2 <= k && k <= 4 && eta_ok(eta1 as int) && eta2 == 2 && d_ok(du as int, false) && d_ok(dv as int, false)
    requires ek.len() as int == 384 * k as int + 32 && m.len() == 32 && r.len() == 32
    requires co as int + 32 * du as int * k as int + 32 * dv as int <= c.len() as int
    ensures |ok| c.len() == old(c.len()) && ok == mat_ok(rho_ek(ek.view(), k as int), k as int, 0)
    ensures |ok| c.view() == pke_c(
        old(c.view()),
        co as int,
        ek.view(),
        m.view(),
        r.view(),
        k as int,
        eta1 as int,
        eta2 as int,
        du as int,
        dv as int,
    )
{
    ghost let c0 = c.view();
    assert eta_ok(eta2 as int) by {};
    let co2 = co + 32 * du * k;
    let t = t_of(ek, k);
    let rho = bytes_at(ek, 384 * k, 32);
    let mut a = new_polys(256 * k * k);
    let ok = matrix(&mut a, &rho, k);

    assert ok == mat_ok(rho_ek(ek.view(), k as int), k as int, 0) && a.view() == a_hat(
        rho_ek(ek.view(), k as int),
        k as int,
    ) by {};
    let y = noise_vec(r, eta1, k, 0, true);
    assert y.view() == s_hat(r.view(), k as int, eta1 as int) by {};
    let e1 = noise_vec(r, eta2, k, k, false);
    let e2 = noise_vec(r, eta2, 1, 2 * k, false);
    let mut u = u_of(&a, &y, &e1, k);
    let mu = mu_of(m);
    let mut v = v_of(&t, &y, &e2, &mu, k);
    compress_encode(c, co, &mut u, k, du);
    compress_encode(c, co2, &mut v, 1, dv);

    assert c.view() == pke_c(
        c0,
        co as int,
        ek.view(),
        m.view(),
        r.view(),
        k as int,
        eta1 as int,
        eta2 as int,
        du as int,
        dv as int,
    ) by {};
    return ok;
}

// Polynomials `i` to `k - 1` of `f` set to Decompress_d(ByteDecode_d) of the bytes from `bo` in `b`, `32 d`
// bytes each.
spec fn ddvec(f: Seq<Secret<u32>>, b: Seq<Secret<u8>>, bo: int, k: int, d: int, i: int) Seq<Secret<u32>>
    decreases k - i
{
    return if i >= k || i < 0 {
        f
    } else {
        ddvec(compressed(decoded(f, 256 * i, b, bo + 32 * d * i, d, 0), 256 * i, d, true, 0), b, bo, k, d, i + 1)
    };
}

// `ddvec` as a step.
lemma ddvec_next(
    f: Seq<Secret<u32>>,
    b: Seq<Secret<u8>>,
    bo: int,
    off: int,
    fo: int,
    k: int,
    d: int,
    i: int,
    g: Seq<Secret<u32>>,
    h: Seq<Secret<u32>>,
)
    requires 0 <= i && i < k && off == bo + 32 * d * i && fo == 256 * i && g == decoded(f, fo, b, off, d, 0) && h == compressed(
        g,
        fo,
        d,
        true,
        0,
    )
    ensures ddvec(f, b, bo, k, d, i) == ddvec(h, b, bo, k, d, i + 1)
{}

// Decompress_d(ByteDecode_d) of `k` polynomials from `bo` in `b` into `f` (FIPS 203, Algorithm 15, lines 3
// and 4).
@constant_time
fn decode_decompress(f: []mut Secret<u32>, b: []Secret<u8>, bo: usize, k: usize, d: usize)
    requires 1 <= k && k <= 4 && d_ok(d as int, false) && f.len() as int == 256 * k as int && bo as int + 32 * d as int * k as int <= b.len() as int && reduced(
        f.view(),
    )
    ensures f.len() == old(f.len()) && reduced(f.view()) && f.view() == ddvec(
        old(f.view()),
        b.view(),
        bo as int,
        k as int,
        d as int,
        0,
    )
{
    let mut off = bo;
    for i in 0..k
        invariant f.len() == old(f.len()) && reduced(f.view()) && off as int == bo as int + 32 * d as int * i as int
        invariant ddvec(f.view(), b.view(), bo as int, k as int, d as int, i as int) == ddvec(
            old(f.view()),
            b.view(),
            bo as int,
            k as int,
            d as int,
            0,
        )
    {
        arith::mul_le(i as int + 1, k as int, 32 * d as int);
        ghost let f0 = f.view();
        decode_d(f, 256 * i, b, off, d);
        ghost let f1 = f.view();
        decompress_d(f, 256 * i, d);
        ddvec_next(f0, b.view(), bo as int, off as int, (256 * i) as int, k as int, d as int, i as int, f1, f.view());
        off += 32 * d;
    }
}

/// w of FIPS 203, Algorithm 15, line 6: v' - NTT^-1(s-hat^T NTT(u')) for the dk_PKE `dk` and the
/// ciphertext `c` from `co` on.
pub spec fn w_spec(dk: Seq<Secret<u8>>, c: Seq<Secret<u8>>, co: int, k: int, du: int, dv: int) Seq<Secret<u32>> {
    return padd(
        ddvec(zeros32(256), c, co + 32 * du * k, 1, dv, 0),
        0,
        intt_spec(
            drow(
                zeros32(256),
                0,
                dvec(zeros32(256 * k), dk, 0, k, 12, 0),
                ntt_vec(ddvec(zeros32(256 * k), c, co, k, du, 0), k, false, 0),
                k,
                0,
            ),
            0,
        ),
        0,
        true,
        0,
    );
}

// w of FIPS 203, Algorithm 15, line 6.
@constant_time
fn w_of(dk: []Secret<u8>, c: []Secret<u8>, co: usize, k: usize, du: usize, dv: usize) Vector<Secret<u32>>
    requires 2 <= k && k <= 4 && d_ok(du as int, false) && d_ok(dv as int, false) && 384 * k as int <= dk.len() as int
    requires co as int + 32 * du as int * k as int + 32 * dv as int <= c.len() as int
    ensures |w| w.len() == 256 && reduced(w.view()) && w.view() == w_spec(
        dk.view(),
        c.view(),
        co as int,
        k as int,
        du as int,
        dv as int,
    )
{
    let co2 = co + 32 * du * k;
    let mut u = new_polys(256 * k);
    decode_decompress(&mut u, c, co, k, du);
    let mut v = new_polys(256);
    decode_decompress(&mut v, c, co2, 1, dv);
    let mut s = new_polys(256 * k);
    decode_vec(&mut s, dk, 0, k);
    ntt_all(&mut u, k, false);
    let mut p = new_polys(256);
    dot(&mut p, 0, &s, &u, k);
    intt(&mut p, 0);
    poly_add(&mut v, 0, &p, 0, true);
    return v;
}

// K-PKE.Decrypt(dk, c) (FIPS 203, Algorithm 15): m into `m`, of the dk_PKE `dk` and the ciphertext `c`
// from `co` on.
@constant_time
fn kpke_decrypt(dk: []Secret<u8>, c: []Secret<u8>, co: usize, k: usize, du: usize, dv: usize, m: []mut Secret<u8>)
    requires 2 <= k && k <= 4 && d_ok(du as int, false) && d_ok(dv as int, false) && 384 * k as int <= dk.len() as int
    requires co as int + 32 * du as int * k as int + 32 * dv as int <= c.len() as int && m.len() == 32
    ensures m.len() == old(m.len()) && m.view() == evec(
        old(m.view()),
        0,
        cvec(w_spec(dk.view(), c.view(), co as int, k as int, du as int, dv as int), 1, 1, 0),
        1,
        1,
        0,
    )
{
    let mut w = w_of(dk, c, co, k, du, dv);
    compress_encode(m, 0, &mut w, 1, 1);
}

// `a` and the first `j + 1` elements of `b`: `a` and the first `j`, then element `j`.
lemma cat_next(a: Seq<Secret<u8>>, b: Seq<Secret<u8>>, j: int)
    requires 0 <= j && j < b.len()
    ensures a.concat(b.take(j + 1)) == a.concat(b.take(j)).push(b[j])
{}

// `a` followed by `b`.
fn cat_bytes(a: []Secret<u8>, b: []Secret<u8>) Vector<Secret<u8>>
    requires a.len() <= 4096 && b.len() <= 4096
    ensures |v| v.len() == a.len() + b.len() && v.view() == a.view().concat(b.view())
{
    let mut v = Vector::<Secret<u8>>::with_capacity(a.len() + b.len());
    for j in 0..a.len()
        invariant v.view() == a.view().take(j as int) && v.len() == j
    {
        take_next(a.view(), j as int);
        v.push(a[j]);
    }
    assert a.view().take(a.len() as int) == a.view() && b.view().take(0) == Seq::<Secret<u8>>::empty() by {};
    assert v.view() == a.view().concat(b.view().take(0)) by {};
    for j in 0..b.len()
        invariant v.view() == a.view().concat(b.view().take(j as int)) && v.len() == a.len() + j
    {
        cat_next(a.view(), b.view(), j as int);
        v.push(b[j]);
    }
    assert b.view().take(b.len() as int) == b.view() by {};
    return v;
}

// H(s) of FIPS 203, (4.4): SHA3-256, as a vector.
@constant_time
fn h_of(s: []Secret<u8>) Vector<Secret<u8>>
    ensures |v| v.len() == 32 && v.view() == out_seq(s.view(), 136, 6, 0, 32)
{
    let h = sha3::sha3_256(s);
    let mut v = Vector::<Secret<u8>>::with_capacity(32);
    assert v.view() == out_seq(s.view(), 136, 6, 0, 0) by {};
    assert h[0].value() == sha3::output(s.view(), 136, 6, 0) by {};
    out_seq_next(s.view(), 136, 6, 0, 0);
    v.push(h[0]);
    assert h[1].value() == sha3::output(s.view(), 136, 6, 1) by {};
    out_seq_next(s.view(), 136, 6, 0, 1);
    v.push(h[1]);
    assert h[2].value() == sha3::output(s.view(), 136, 6, 2) by {};
    out_seq_next(s.view(), 136, 6, 0, 2);
    v.push(h[2]);
    assert h[3].value() == sha3::output(s.view(), 136, 6, 3) by {};
    out_seq_next(s.view(), 136, 6, 0, 3);
    v.push(h[3]);
    assert h[4].value() == sha3::output(s.view(), 136, 6, 4) by {};
    out_seq_next(s.view(), 136, 6, 0, 4);
    v.push(h[4]);
    assert h[5].value() == sha3::output(s.view(), 136, 6, 5) by {};
    out_seq_next(s.view(), 136, 6, 0, 5);
    v.push(h[5]);
    assert h[6].value() == sha3::output(s.view(), 136, 6, 6) by {};
    out_seq_next(s.view(), 136, 6, 0, 6);
    v.push(h[6]);
    assert h[7].value() == sha3::output(s.view(), 136, 6, 7) by {};
    out_seq_next(s.view(), 136, 6, 0, 7);
    v.push(h[7]);
    assert h[8].value() == sha3::output(s.view(), 136, 6, 8) by {};
    out_seq_next(s.view(), 136, 6, 0, 8);
    v.push(h[8]);
    assert h[9].value() == sha3::output(s.view(), 136, 6, 9) by {};
    out_seq_next(s.view(), 136, 6, 0, 9);
    v.push(h[9]);
    assert h[10].value() == sha3::output(s.view(), 136, 6, 10) by {};
    out_seq_next(s.view(), 136, 6, 0, 10);
    v.push(h[10]);
    assert h[11].value() == sha3::output(s.view(), 136, 6, 11) by {};
    out_seq_next(s.view(), 136, 6, 0, 11);
    v.push(h[11]);
    assert h[12].value() == sha3::output(s.view(), 136, 6, 12) by {};
    out_seq_next(s.view(), 136, 6, 0, 12);
    v.push(h[12]);
    assert h[13].value() == sha3::output(s.view(), 136, 6, 13) by {};
    out_seq_next(s.view(), 136, 6, 0, 13);
    v.push(h[13]);
    assert h[14].value() == sha3::output(s.view(), 136, 6, 14) by {};
    out_seq_next(s.view(), 136, 6, 0, 14);
    v.push(h[14]);
    assert h[15].value() == sha3::output(s.view(), 136, 6, 15) by {};
    out_seq_next(s.view(), 136, 6, 0, 15);
    v.push(h[15]);
    assert h[16].value() == sha3::output(s.view(), 136, 6, 16) by {};
    out_seq_next(s.view(), 136, 6, 0, 16);
    v.push(h[16]);
    assert h[17].value() == sha3::output(s.view(), 136, 6, 17) by {};
    out_seq_next(s.view(), 136, 6, 0, 17);
    v.push(h[17]);
    assert h[18].value() == sha3::output(s.view(), 136, 6, 18) by {};
    out_seq_next(s.view(), 136, 6, 0, 18);
    v.push(h[18]);
    assert h[19].value() == sha3::output(s.view(), 136, 6, 19) by {};
    out_seq_next(s.view(), 136, 6, 0, 19);
    v.push(h[19]);
    assert h[20].value() == sha3::output(s.view(), 136, 6, 20) by {};
    out_seq_next(s.view(), 136, 6, 0, 20);
    v.push(h[20]);
    assert h[21].value() == sha3::output(s.view(), 136, 6, 21) by {};
    out_seq_next(s.view(), 136, 6, 0, 21);
    v.push(h[21]);
    assert h[22].value() == sha3::output(s.view(), 136, 6, 22) by {};
    out_seq_next(s.view(), 136, 6, 0, 22);
    v.push(h[22]);
    assert h[23].value() == sha3::output(s.view(), 136, 6, 23) by {};
    out_seq_next(s.view(), 136, 6, 0, 23);
    v.push(h[23]);
    assert h[24].value() == sha3::output(s.view(), 136, 6, 24) by {};
    out_seq_next(s.view(), 136, 6, 0, 24);
    v.push(h[24]);
    assert h[25].value() == sha3::output(s.view(), 136, 6, 25) by {};
    out_seq_next(s.view(), 136, 6, 0, 25);
    v.push(h[25]);
    assert h[26].value() == sha3::output(s.view(), 136, 6, 26) by {};
    out_seq_next(s.view(), 136, 6, 0, 26);
    v.push(h[26]);
    assert h[27].value() == sha3::output(s.view(), 136, 6, 27) by {};
    out_seq_next(s.view(), 136, 6, 0, 27);
    v.push(h[27]);
    assert h[28].value() == sha3::output(s.view(), 136, 6, 28) by {};
    out_seq_next(s.view(), 136, 6, 0, 28);
    v.push(h[28]);
    assert h[29].value() == sha3::output(s.view(), 136, 6, 29) by {};
    out_seq_next(s.view(), 136, 6, 0, 29);
    v.push(h[29]);
    assert h[30].value() == sha3::output(s.view(), 136, 6, 30) by {};
    out_seq_next(s.view(), 136, 6, 0, 30);
    v.push(h[30]);
    assert h[31].value() == sha3::output(s.view(), 136, 6, 31) by {};
    out_seq_next(s.view(), 136, 6, 0, 31);
    v.push(h[31]);
    out_seq_len(s.view(), 136, 6, 0, 32);
    return v;
}

/// eta_1 of the parameter set of rank `k` (FIPS 203, Table 2): 3 for ML-KEM-512, else 2.
pub spec fn eta1_of(k: int) int {
    return if k == 2 {
        3
    } else {
        2
    };
}

/// d_u of the parameter set of rank `k`: 11 for ML-KEM-1024, else 10.
pub spec fn du_of(k: int) int {
    return if k == 4 {
        11
    } else {
        10
    };
}

/// d_v of the parameter set of rank `k`: 5 for ML-KEM-1024, else 4.
pub spec fn dv_of(k: int) int {
    return if k == 4 {
        5
    } else {
        4
    };
}

// eta_1 of rank `k`.
const fn eta1_for(k: usize) usize
    requires 2 <= k && k <= 4
    ensures |r| r as int == eta1_of(k as int) && eta_ok(r as int)
{
    return if k == 2 {
        3
    } else {
        2
    };
}

// d_u of rank `k`.
const fn du_for(k: usize) usize
    requires 2 <= k && k <= 4
    ensures |r| r as int == du_of(k as int) && d_ok(r as int, false)
{
    return if k == 4 {
        11
    } else {
        10
    };
}

// d_v of rank `k`.
const fn dv_for(k: usize) usize
    requires 2 <= k && k <= 4
    ensures |r| r as int == dv_of(k as int) && d_ok(r as int, false)
{
    return if k == 4 {
        5
    } else {
        4
    };
}

/// ek of ML-KEM.KeyGen_internal(d, z) (FIPS 203, Algorithm 16) of rank `k`, written over `e`.
pub spec fn ek_spec(e: Seq<Secret<u8>>, d: Seq<Secret<u8>>, k: int) Seq<Secret<u8>> {
    return copied(enc_vec(e, 0, t_hat(rho_of(d, k), sigma_of(d, k), k, eta1_of(k)), k, 0), 384 * k, rho_of(d, k), 0);
}

/// dk of ML-KEM.KeyGen_internal(d, z) of rank `k` and encapsulation key `ek`, written over `e`: dk_PKE,
/// ek, H(ek), z.
pub spec fn dk_spec(e: Seq<Secret<u8>>, d: Seq<Secret<u8>>, z: Seq<Secret<u8>>, ek: Seq<Secret<u8>>, k: int) Seq<
    Secret<u8>
> {
    return copied(
        copied(
            copied(enc_vec(e, 0, s_hat(sigma_of(d, k), k, eta1_of(k)), k, 0), 384 * k, ek, 0),
            768 * k + 32,
            out_seq(ek, 136, 6, 0, 32),
            0,
        ),
        768 * k + 64,
        z,
        0,
    );
}

/// ML-KEM.KeyGen_internal(d, z) (FIPS 203, Algorithm 16) of rank `k`: ek into `ek` and dk into `dk`;
/// whether SampleNTT set every coefficient of A-hat within its iteration bound. Deterministic: for
/// known-answer tests; `keygen` draws d and z.
pub fn keygen_internal(d: []Secret<u8>, z: []Secret<u8>, k: usize, ek: []mut Secret<u8>, dk: []mut Secret<u8>) bool
    requires d.len() == 32 && z.len() == 32 && 2 <= k && k <= 4
    requires ek.len() as int == 384 * k as int + 32 && dk.len() as int == 768 * k as int + 96
    ensures |ok| ek.len() == old(ek.len()) && dk.len() == old(dk.len()) && ok == mat_ok(
        rho_of(d.view(), k as int),
        k as int,
        0,
    )
    ensures |ok| ek.view() == ek_spec(old(ek.view()), d.view(), k as int)
    ensures |ok| dk.view() == dk_spec(old(dk.view()), d.view(), z.view(), ek.view(), k as int)
{
    ghost let ek0 = ek.view();
    ghost let dk0 = dk.view();
    let eta1 = eta1_for(k);
    let ok = kpke_keygen(d, k, eta1, ek, 0, dk, 0);
    assert ek.view() == ek_spec(ek0, d.view(), k as int) by {};
    ghost let dk1 = dk.view();
    assert dk1 == enc_vec(dk0, 0, s_hat(sigma_of(d.view(), k as int), k as int, eta1_of(k as int)), k as int, 0) by {};
    copy_bytes(dk, 384 * k, ek);
    let h = h_of(ek);
    out_seq_len(ek.view(), 136, 6, 0, 32);
    copy_bytes(dk, 768 * k + 32, &h);
    copy_bytes(dk, 768 * k + 64, z);
    return ok;
}

// J(s) of FIPS 203, (4.4): SHAKE256 with 32 bytes of output, as a vector.
@constant_time
fn j_of(s: []Secret<u8>) Vector<Secret<u8>>
    ensures |v| v.len() == 32 && v.view() == out_seq(s.view(), 136, 0x1f, 0, 32)
{
    let h = sha3::shake256_32(s);
    let mut v = Vector::<Secret<u8>>::with_capacity(32);
    assert v.view() == out_seq(s.view(), 136, 0x1f, 0, 0) by {};
    assert h[0].value() == sha3::output(s.view(), 136, 0x1f, 0) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 0);
    v.push(h[0]);
    assert h[1].value() == sha3::output(s.view(), 136, 0x1f, 1) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 1);
    v.push(h[1]);
    assert h[2].value() == sha3::output(s.view(), 136, 0x1f, 2) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 2);
    v.push(h[2]);
    assert h[3].value() == sha3::output(s.view(), 136, 0x1f, 3) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 3);
    v.push(h[3]);
    assert h[4].value() == sha3::output(s.view(), 136, 0x1f, 4) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 4);
    v.push(h[4]);
    assert h[5].value() == sha3::output(s.view(), 136, 0x1f, 5) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 5);
    v.push(h[5]);
    assert h[6].value() == sha3::output(s.view(), 136, 0x1f, 6) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 6);
    v.push(h[6]);
    assert h[7].value() == sha3::output(s.view(), 136, 0x1f, 7) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 7);
    v.push(h[7]);
    assert h[8].value() == sha3::output(s.view(), 136, 0x1f, 8) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 8);
    v.push(h[8]);
    assert h[9].value() == sha3::output(s.view(), 136, 0x1f, 9) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 9);
    v.push(h[9]);
    assert h[10].value() == sha3::output(s.view(), 136, 0x1f, 10) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 10);
    v.push(h[10]);
    assert h[11].value() == sha3::output(s.view(), 136, 0x1f, 11) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 11);
    v.push(h[11]);
    assert h[12].value() == sha3::output(s.view(), 136, 0x1f, 12) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 12);
    v.push(h[12]);
    assert h[13].value() == sha3::output(s.view(), 136, 0x1f, 13) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 13);
    v.push(h[13]);
    assert h[14].value() == sha3::output(s.view(), 136, 0x1f, 14) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 14);
    v.push(h[14]);
    assert h[15].value() == sha3::output(s.view(), 136, 0x1f, 15) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 15);
    v.push(h[15]);
    assert h[16].value() == sha3::output(s.view(), 136, 0x1f, 16) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 16);
    v.push(h[16]);
    assert h[17].value() == sha3::output(s.view(), 136, 0x1f, 17) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 17);
    v.push(h[17]);
    assert h[18].value() == sha3::output(s.view(), 136, 0x1f, 18) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 18);
    v.push(h[18]);
    assert h[19].value() == sha3::output(s.view(), 136, 0x1f, 19) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 19);
    v.push(h[19]);
    assert h[20].value() == sha3::output(s.view(), 136, 0x1f, 20) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 20);
    v.push(h[20]);
    assert h[21].value() == sha3::output(s.view(), 136, 0x1f, 21) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 21);
    v.push(h[21]);
    assert h[22].value() == sha3::output(s.view(), 136, 0x1f, 22) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 22);
    v.push(h[22]);
    assert h[23].value() == sha3::output(s.view(), 136, 0x1f, 23) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 23);
    v.push(h[23]);
    assert h[24].value() == sha3::output(s.view(), 136, 0x1f, 24) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 24);
    v.push(h[24]);
    assert h[25].value() == sha3::output(s.view(), 136, 0x1f, 25) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 25);
    v.push(h[25]);
    assert h[26].value() == sha3::output(s.view(), 136, 0x1f, 26) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 26);
    v.push(h[26]);
    assert h[27].value() == sha3::output(s.view(), 136, 0x1f, 27) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 27);
    v.push(h[27]);
    assert h[28].value() == sha3::output(s.view(), 136, 0x1f, 28) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 28);
    v.push(h[28]);
    assert h[29].value() == sha3::output(s.view(), 136, 0x1f, 29) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 29);
    v.push(h[29]);
    assert h[30].value() == sha3::output(s.view(), 136, 0x1f, 30) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 30);
    v.push(h[30]);
    assert h[31].value() == sha3::output(s.view(), 136, 0x1f, 31) by {};
    out_seq_next(s.view(), 136, 0x1f, 0, 31);
    v.push(h[31]);
    out_seq_len(s.view(), 136, 0x1f, 0, 32);
    return v;
}

/// Whether the first `n` bytes of `a` and `b` are equal.
pub spec fn same_upto(a: Seq<Secret<u8>>, b: Seq<Secret<u8>>, n: int) bool
    decreases n
{
    return if n <= 0 || n > a.len() || n > b.len() {
        n <= 0
    } else {
        same_upto(a, b, n - 1) && a[n - 1].value() == b[n - 1].value()
    };
}

// `d | (x ^ y)` is 0 exactly where `d` is 0 and `x` is `y`.
lemma or_xor_zero(d: u8, x: u8, y: u8)
    ensures (d | x ^ y) == 0 == (d == 0 && x == y)
{}

// Whether `a` and `b` are equal, in time independent of their bytes.
@constant_time
fn ct_same(a: []Secret<u8>, b: []Secret<u8>) Secret<bool>
    requires a.len() == b.len()
    ensures |r| r.value() == same_upto(a.view(), b.view(), a.len() as int)
{
    let mut d = Secret::new(0u8);
    for j in 0..a.len()
        invariant d.value() == 0 == same_upto(a.view(), b.view(), j as int)
    {
        or_xor_zero(d.value(), a[j].value(), b[j].value());
        d = d | a[j] ^ b[j];
    }
    return d.eq(Secret::new(0u8));
}

/// The first `n` bytes of `a` where `c` holds, else of `b`, byte by byte.
pub spec fn sel_seq(c: bool, a: Seq<Secret<u8>>, b: Seq<Secret<u8>>, n: int) Seq<Secret<u8>>
    decreases n
{
    return if n <= 0 || n > a.len() || n > b.len() {
        Seq::<Secret<u8>>::empty()
    } else {
        sel_seq(c, a, b, n - 1).push(
            Secret::new(
                if c {
                    a[n - 1].value()
                } else {
                    b[n - 1].value()
                },
            ),
        )
    };
}

// `sel_seq` one byte longer.
lemma sel_next(c: bool, a: Seq<Secret<u8>>, b: Seq<Secret<u8>>, n: int)
    requires 0 <= n && n < a.len() && n < b.len()
    ensures sel_seq(c, a, b, n + 1) == sel_seq(c, a, b, n).push(
        Secret::new(
            if c {
                a[n].value()
            } else {
                b[n].value()
            },
        ),
    )
{}

// `a` where `c` holds, else `b`, in time independent of `c`.
@constant_time
fn ct_select(c: Secret<bool>, a: []Secret<u8>, b: []Secret<u8>) Vector<Secret<u8>>
    requires a.len() == 32 && b.len() == 32
    ensures |v| v.len() == 32 && v.view() == sel_seq(c.value(), a.view(), b.view(), 32)
{
    let mut v = Vector::<Secret<u8>>::with_capacity(a.len());
    assert v.view() == sel_seq(c.value(), a.view(), b.view(), 0) by {};
    for j in 0..a.len()
        invariant v.len() == j && v.view() == sel_seq(c.value(), a.view(), b.view(), j as int)
    {
        sel_next(c.value(), a.view(), b.view(), j as int);
        v.push(Secret::pick(c, a[j], b[j]));
    }
    return v;
}

/// Bytes `lo` to `lo + n - 1` of `s` (`s` where they do not lie in it).
pub spec fn part(s: Seq<Secret<u8>>, lo: int, n: int) Seq<Secret<u8>> {
    return if lo < 0 || n < 0 || lo + n > s.len() {
        s
    } else {
        s.subrange(lo, lo + n)
    };
}

// The ciphertext length of rank `k` is at most 1568, and `32 (du k + dv)` for its `du` and `dv`.
lemma ct_len_le(k: int, du: int, dv: int)
    requires 2 <= k && k <= 4 && du == du_of(k) && dv == dv_of(k)
    ensures ct_len_of(k) <= 1568 && ct_len_of(k) >= 768 && ct_len_of(k) == 32 * du * k + 32 * dv
{
    if k == 2 {
        assert ct_len_of(k) == 768 by {};
    } else if k == 3 {
        assert ct_len_of(k) == 1088 by {};
    } else {
        assert ct_len_of(k) == 1568 by {};
    }
}

/// G(s) of FIPS 203, (4.5): SHA3-512, its 64 bytes.
pub spec fn g_spec(s: Seq<Secret<u8>>) Seq<Secret<u8>> {
    return out_seq(s, 72, 6, 0, 32).concat(out_seq(s, 72, 6, 32, 32));
}

// G(gin) of FIPS 203, (4.5), as a vector.
@constant_time
fn g_of(gin: []Secret<u8>) Vector<Secret<u8>>
    ensures |v| v.len() == 64 && v.view() == g_spec(gin.view())
{
    let gd = sha3::sha3_512(gin);
    let a = g_part0(gd, gin);
    let b = g_part32(gd, gin);
    return cat_bytes(&a, &b);
}

/// The input of G in ML-KEM.Encaps_internal(ek, m) (FIPS 203, Algorithm 17, line 1): m || H(ek).
pub spec fn kr_in(ek: Seq<Secret<u8>>, m: Seq<Secret<u8>>) Seq<Secret<u8>> {
    return m.concat(out_seq(ek, 136, 6, 0, 32));
}

/// The ciphertext length of rank `k`: `32 (d_u k + d_v)`.
pub spec fn ct_len_of(k: int) int {
    return 32 * du_of(k) * k + 32 * dv_of(k);
}

/// ML-KEM.Encaps_internal(ek, m) (FIPS 203, Algorithm 17) of rank `k`: c into `c` and K into `key`;
/// whether SampleNTT set every coefficient of A-hat within its iteration bound. Deterministic and without
/// the modulus check: for known-answer tests; `encaps` checks `ek` and draws m.
pub fn encaps_internal(ek: []Secret<u8>, m: []Secret<u8>, k: usize, c: []mut Secret<u8>, key: []mut Secret<u8>) bool
    requires 2 <= k && k <= 4 && ek.len() as int == 384 * k as int + 32 && m.len() == 32 && key.len() == 32
    requires c.len() as int == ct_len_of(k as int)
    ensures |ok| c.len() == old(c.len()) && key.len() == old(key.len()) && ok == mat_ok(
        rho_ek(ek.view(), k as int),
        k as int,
        0,
    )
    ensures |ok| c.view() == pke_c(
        old(c.view()),
        0,
        ek.view(),
        m.view(),
        part(g_spec(kr_in(ek.view(), m.view())), 32, 32),
        k as int,
        eta1_of(k as int),
        2,
        du_of(k as int),
        dv_of(k as int),
    )
    ensures |ok| key.view() == copied(old(key.view()), 0, part(g_spec(kr_in(ek.view(), m.view())), 0, 32), 0)
{
    let eta1 = eta1_for(k);
    let du = du_for(k);
    let dv = dv_for(k);
    ct_len_le(k as int, du as int, dv as int);
    let hek = h_of(ek);
    out_seq_len(ek.view(), 136, 6, 0, 32);
    let gin = cat_bytes(m, &hek);
    assert gin.view() == kr_in(ek.view(), m.view()) by {};
    let g = g_of(&gin);
    assert g.view().len() == 64 by {};

    assert part(g_spec(kr_in(ek.view(), m.view())), 32, 32) == g.view().subrange(32, 64) && part(
        g_spec(kr_in(ek.view(), m.view())),
        0,
        32,
    ) == g.view().subrange(0, 32) by {};
    let ok = kpke_encrypt(ek, m, &g[32..64], k, eta1, 2, du, dv, c, 0);
    copy_bytes(key, 0, &g[0..32]);
    return ok;
}

/// m' of ML-KEM.Decaps_internal(dk, c) (FIPS 203, Algorithm 18, line 5) of rank `k`.
pub spec fn m_dec(dk: Seq<Secret<u8>>, c: Seq<Secret<u8>>, k: int) Seq<Secret<u8>> {
    return evec(zeros8(32), 0, cvec(w_spec(dk, c, 0, k, du_of(k), dv_of(k)), 1, 1, 0), 1, 1, 0);
}

/// The input of G in Algorithm 18, line 6: m' || h.
pub spec fn kr_dec(dk: Seq<Secret<u8>>, c: Seq<Secret<u8>>, k: int) Seq<Secret<u8>> {
    return m_dec(dk, c, k).concat(part(dk, 768 * k + 32, 32));
}

/// c' of Algorithm 18, line 8: K-PKE.Encrypt(ek_PKE, m', r').
pub spec fn c_dec(dk: Seq<Secret<u8>>, c: Seq<Secret<u8>>, k: int) Seq<Secret<u8>> {
    return pke_c(
        zeros8(c.len()),
        0,
        part(dk, 384 * k, 384 * k + 32),
        m_dec(dk, c, k),
        part(g_spec(kr_dec(dk, c, k)), 32, 32),
        k,
        eta1_of(k),
        2,
        du_of(k),
        dv_of(k),
    );
}

/// K' of ML-KEM.Decaps_internal(dk, c) (FIPS 203, Algorithm 18) of rank `k`: the key of m' where c' is c,
/// else the implicit rejection J(z || c), byte by byte.
pub spec fn key_dec(dk: Seq<Secret<u8>>, c: Seq<Secret<u8>>, k: int) Seq<Secret<u8>> {
    return sel_seq(
        same_upto(c, c_dec(dk, c, k), c.len()),
        part(g_spec(kr_dec(dk, c, k)), 0, 32),
        out_seq(part(dk, 768 * k + 64, 32).concat(c), 136, 0x1f, 0, 32),
        32,
    );
}

// Lines 1 to 8 of ML-KEM.Decaps_internal(dk, c) (FIPS 203, Algorithm 18) of rank `k`: c' into `cp` (zeros
// before); G of m' and h, the key of m' first. SampleNTT fails within its bound for no ek_PKE whose key generation it did not
// fail for: the same seed rho samples the same matrix.
fn decaps_reencrypt(dk: []Secret<u8>, c: []Secret<u8>, k: usize, cp: []mut Secret<u8>) Vector<Secret<u8>>
    requires 2 <= k && k <= 4 && dk.len() as int == 768 * k as int + 96 && c.len() as int == ct_len_of(k as int)
    requires cp.len() == c.len() && cp.view() == zeros8(c.len() as int)
    ensures |kp| cp.len() == old(cp.len()) && cp.view() == c_dec(dk.view(), c.view(), k as int)
    ensures |kp| kp.len() == 64 && kp.view() == g_spec(kr_dec(dk.view(), c.view(), k as int))
{
    let eta1 = eta1_for(k);
    let du = du_for(k);
    let dv = dv_for(k);
    ct_len_le(k as int, du as int, dv as int);
    let ekp = bytes_at(dk, 384 * k, 384 * k + 32);
    let h = bytes_at(dk, 768 * k + 32, 32);

    assert ekp.view() == part(dk.view(), 384 * k as int, 384 * k as int + 32) && h.view() == part(
        dk.view(),
        768 * k as int + 32,
        32,
    ) by {};
    let mut mp = new_bytes(32);
    kpke_decrypt(dk, c, 0, k, du, dv, &mut mp);
    assert mp.view() == m_dec(dk.view(), c.view(), k as int) by {};
    let gin = cat_bytes(&mp, &h);
    assert gin.view() == kr_dec(dk.view(), c.view(), k as int) by {};
    let g = g_of(&gin);
    assert g.view().len() == 64 by {};
    assert part(g_spec(kr_dec(dk.view(), c.view(), k as int)), 32, 32) == g.view().subrange(32, 64) by {};
    let _ = kpke_encrypt(&ekp, &mp, &g[32..64], k, eta1, 2, du, dv, cp, 0);
    return g;
}

// The same selection of equal choices.
lemma sel_same(c1: bool, c2: bool, a1: Seq<Secret<u8>>, a2: Seq<Secret<u8>>, b: Seq<Secret<u8>>)
    requires c1 == c2 && a1 == a2
    ensures sel_seq(c1, a1, b, 32) == sel_seq(c2, a2, b, 32)
{}

/// ML-KEM.Decaps_internal(dk, c) (FIPS 203, Algorithm 18) of rank `k`: K'. Without the hash check:
/// `decaps` checks `dk`.
pub fn decaps_internal(dk: []Secret<u8>, c: []Secret<u8>, k: usize) Vector<Secret<u8>>
    requires 2 <= k && k <= 4 && dk.len() as int == 768 * k as int + 96 && c.len() as int == ct_len_of(k as int)
    ensures |key| key.len() == 32 && key.view() == key_dec(dk.view(), c.view(), k as int)
{
    ct_len_le(k as int, du_of(k as int), dv_of(k as int));
    let mut cp = new_bytes(c.len());
    let kp = decaps_reencrypt(dk, c, k, &mut cp);
    let z = bytes_at(dk, 768 * k + 64, 32);
    let jin = cat_bytes(&z, c);
    assert jin.view() == part(dk.view(), 768 * k as int + 64, 32).concat(c.view()) by {};
    let kbar = j_of(&jin);
    assert kbar.view() == out_seq(part(dk.view(), 768 * k as int + 64, 32).concat(c.view()), 136, 0x1f, 0, 32) by {};
    let same = ct_same(c, &cp);
    assert same.value() == same_upto(c.view(), c_dec(dk.view(), c.view(), k as int), c.len() as int) by {};
    assert kp.view().len() == 64 by {};
    assert part(g_spec(kr_dec(dk.view(), c.view(), k as int)), 0, 32) == kp.view().subrange(0, 32) by {};
    ghost let kv = kbar.view();
    ghost let sv = same.value();
    ghost let av = kp.view().subrange(0, 32);
    let r = ct_select(same, &kp[0..32], &kbar);
    sel_same(
        sv,
        same_upto(c.view(), c_dec(dk.view(), c.view(), k as int), c.len() as int),
        av,
        part(g_spec(kr_dec(dk.view(), c.view(), k as int)), 0, 32),
        kv,
    );
    return r;
}
/// The rank k of ML-KEM-512 (FIPS 203, Table 2).
pub const ML_KEM_512: usize = 2;
/// The rank k of ML-KEM-768.
pub const ML_KEM_768: usize = 3;
/// The rank k of ML-KEM-1024.
pub const ML_KEM_1024: usize = 4;

/// The length in bytes of an encapsulation key of rank `k` (FIPS 203, Table 3).
pub const fn ek_len(k: usize) usize
    requires 2 <= k && k <= 4
    ensures |n| n as int == 384 * k as int + 32
{
    return 384 * k + 32;
}

/// The length in bytes of a decapsulation key of rank `k`.
pub const fn dk_len(k: usize) usize
    requires 2 <= k && k <= 4
    ensures |n| n as int == 768 * k as int + 96
{
    return 768 * k + 96;
}

/// The length in bytes of a ciphertext of rank `k`.
pub const fn ct_len(k: usize) usize
    requires 2 <= k && k <= 4
    ensures |n| n as int == ct_len_of(k as int)
{
    ct_len_le(k as int, du_of(k as int), dv_of(k as int));
    return 32 * du_for(k) * k + 32 * dv_for(k);
}

/// The modulus check of FIPS 203, 7.2: ByteEncode_12(ByteDecode_12(ek[0 : 384 k])) is ek[0 : 384 k].
pub spec fn ek_ok(ek: Seq<Secret<u8>>, k: int) bool {
    return same_upto(enc_vec(zeros8(384 * k), 0, t_ek(ek, k), k, 0), part(ek, 0, 384 * k), 384 * k);
}

// The modulus check of `ek`, in time independent of its bytes.
@constant_time
fn modulus_check(ek: []Secret<u8>, k: usize) Secret<bool>
    requires 2 <= k && k <= 4 && ek.len() as int == 384 * k as int + 32
    ensures |r| r.value() == ek_ok(ek.view(), k as int)
{
    let t = t_of(ek, k);
    let mut e = new_bytes(384 * k);
    encode_vec(&mut e, 0, &t, k);
    let p = bytes_at(ek, 0, 384 * k);
    assert p.view() == part(ek.view(), 0, 384 * k as int) by {};
    return ct_same(&e, &p);
}

/// The hash check of FIPS 203, 7.3: H(dk[384 k : 768 k + 32]) is dk[768 k + 32 : 768 k + 64].
pub spec fn dk_ok(dk: Seq<Secret<u8>>, k: int) bool {
    return same_upto(out_seq(part(dk, 384 * k, 384 * k + 32), 136, 6, 0, 32), part(dk, 768 * k + 32, 32), 32);
}

// The hash check of `dk`, in time independent of its bytes.
@constant_time
fn hash_check(dk: []Secret<u8>, k: usize) Secret<bool>
    requires 2 <= k && k <= 4 && dk.len() as int == 768 * k as int + 96
    ensures |r| r.value() == dk_ok(dk.view(), k as int)
{
    let ekp = bytes_at(dk, 384 * k, 384 * k + 32);
    assert ekp.view() == part(dk.view(), 384 * k as int, 384 * k as int + 32) by {};
    let h = h_of(&ekp);
    let hh = bytes_at(dk, 768 * k + 32, 32);
    assert hh.view() == part(dk.view(), 768 * k as int + 32, 32) by {};
    let r = ct_same(&h, &hh);

    assert r.value() == same_upto(
        out_seq(part(dk.view(), 384 * k as int, 384 * k as int + 32), 136, 6, 0, 32),
        part(dk.view(), 768 * k as int + 32, 32),
        32,
    ) by {};
    return r;
}

// Fills `v` with bytes of the system's entropy, as secrets; false when the source fails.
fn random_into(v: []mut Secret<u8>) bool
    requires v.len() <= 64
    ensures v.len() == old(v.len())
{
    let mut raw = [0u8; 64];
    if entropy::fill(&mut raw[0..v.len()]).is_err() {
        return false;
    }
    for j in 0..v.len()
        invariant v.len() == old(v.len())
    {
        v[j] = Secret::new(raw[j]);
    }
    return true;
}

/// ML-KEM.KeyGen (FIPS 203, Algorithm 19) of rank `k`: the encapsulation key into `ek` and the
/// decapsulation key into `dk`, from 64 bytes of the system's entropy (`keygen_internal` of them). False
/// when `k` is no rank, a buffer has the wrong length (`ek_len`, `dk_len`), the entropy source fails, or
/// SampleNTT reaches its iteration bound; `ek` and `dk` then hold no key.
pub fn keygen(k: usize, ek: []mut Secret<u8>, dk: []mut Secret<u8>) bool
    ensures ek.len() == old(ek.len()) && dk.len() == old(dk.len())
{
    if k < 2 || k > 4 || ek.len() != 384 * k + 32 || dk.len() != 768 * k + 96 {
        return false;
    }
    let mut s = new_bytes(64);
    if !random_into(&mut s) {
        return false;
    }
    let d = bytes_at(&s, 0, 32);
    let z = bytes_at(&s, 32, 32);
    return keygen_internal(&d, &z, k, ek, dk);
}

/// ML-KEM.Encaps (FIPS 203, Algorithm 20) of rank `k`: the ciphertext into `c` and the shared key into
/// `key`, from 32 bytes of the system's entropy (`encaps_internal` of them). False when `k` is no rank, a
/// buffer has the wrong length (`ek_len`, `ct_len`, 32), `ek` fails the modulus check (`ek_ok`), the
/// entropy source fails, or SampleNTT reaches its iteration bound; `c` and `key` then hold no result.
pub fn encaps(ek: []Secret<u8>, k: usize, c: []mut Secret<u8>, key: []mut Secret<u8>) bool
    ensures |ok| c.len() == old(c.len()) && key.len() == old(key.len())
    ensures |ok| ok ==> 2 <= k && k <= 4 && ek.len() as int == 384 * k as int + 32 && ek_ok(ek.view(), k as int)
{
    if k < 2 || k > 4 || ek.len() != 384 * k + 32 || c.len() != ct_len(k) || key.len() != 32 {
        return false;
    }
    if !modulus_check(ek, k).declassify() {
        return false;
    }
    let mut m = new_bytes(32);
    if !random_into(&mut m) {
        return false;
    }
    return encaps_internal(ek, &m, k, c, key);
}

/// ML-KEM.Decaps (FIPS 203, Algorithm 21) of rank `k`: the shared key of `c` into `key`
/// (`decaps_internal`). False, with `key` unchanged, when `k` is no rank, a buffer has the wrong length
/// (`dk_len`, `ct_len`, 32), or `dk` fails the hash check (`dk_ok`).
pub fn decaps(dk: []Secret<u8>, c: []Secret<u8>, k: usize, key: []mut Secret<u8>) bool
    ensures |ok| key.len() == old(key.len()) && (!ok ==> key.view() == old(key.view()))
    ensures |ok| ok == (2 <= k && k <= 4 && dk.len() as int == 768 * k as int + 96 && c.len() as int == ct_len_of(
        k as int,
    ) && key.len() == 32 && dk_ok(dk.view(), k as int))
    ensures |ok| ok ==> key.view() == copied(old(key.view()), 0, key_dec(dk.view(), c.view(), k as int), 0)
{
    if k < 2 || k > 4 || dk.len() != 768 * k + 96 || c.len() != ct_len(k) || key.len() != 32 {
        return false;
    }
    if !hash_check(dk, k).declassify() {
        return false;
    }
    let kk = decaps_internal(dk, c, k);
    copy_bytes(key, 0, &kk);
    return true;
}
