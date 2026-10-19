// std::math over the wide types: Int<N>, UInt<N> and Float<E, F> in vectors, matrices, quaternions and the
// large types. The integers keep their own checked arithmetic past 64 bits; every cast rounds once from the
// exact value; the functions of f128 and f256 equal a 400-digit reference rounded to the format (values from
// an implementation independent of std/math/wide.spc), keep their identities with the exact constants and
// C's special values; the formats exact in f64 compute there; the large types and the text of vectors take
// every element type.
import std::math::all as *;
import std::math::extra as *;
import std::float as sf;
import tests::harness as h;

fn u256_hex(s: str) u256 {
    return u256::from_str_radix(s, 16).unwrap();
}

fn f128_hex(s: str) f128 {
    return f128::from_raw(UInt::<128>::from_str_radix(s, 16).unwrap());
}

fn f256_hex(s: str) f256 {
    return f256::from_raw(UInt::<256>::from_str_radix(s, 16).unwrap());
}

fn q(v: f64) f128 {
    return f128::from_f64(v);
}

@test
fn wide_integer_vectors() {
    let big = u256_hex("1000000000000000000000000000000000000000000000000000");
    let a = Vec::<u256, 2>::new(big, u256::from_u64(3));
    let b = Vec::<u256, 2>::new(big, u256::from_u64(5));
    let s = a + b;
    let p = a * Vec::<u256, 2>::new(u256::from_u64(7), u256::from_u64(5));
    assert(s.e[0] == big + big && s.e[1] == u256::from_u64(8));
    assert(p.e[0] == big * u256::from_u64(7) && p.e[1] == u256::from_u64(15));
    // Shifts by counts of the type: past the width every bit shifts out, as the type's own shift does.
    let sh = a << Vec::<u256, 2>::new(u256::from_u64(56), u256::from_u64(300));
    assert(sh.e[0] == big << 56 && sh.e[1] == u256::zero());
    let n = Vec::<i128, 3>::new(i128::from_i64(-7), i128::from_i64(2), i128::from_i64(9));
    assert(abs(n).e[0] == i128::from_i64(7) && sign(n).e[0] == i128::from_i64(-1));
    assert(min(n, Vec::<i128, 3>::splat(i128::zero())).e[2] == i128::zero());
    assert(comp_add(n * n) == i128::from_i64(134));
    let m = Mat::<i128, 2, 2>::cols(
        Vec::<i128, 2>::new(i128::from_i64(3), i128::from_i64(1)),
        Vec::<i128, 2>::new(i128::from_i64(4), i128::from_i64(2)),
    );
    assert(determinant(m) == i128::from_i64(2));
    assert((m * m)[1][0] == i128::from_i64(20));
    assert(find_msb(u128::one() << 100) == 100 && bit_count(u128::max()) == 128 && is_power_of_two(u128::one() << 90));
}

@test
fn wide_integer_overflow_traps() {
    h::expect_run(
        "Int<128> vector overflow",
        "import std::math::all as *;\nfn main(args: Vector<str>) i32 {\n    let a = Vec::<i128, 2>::splat(i128::max());\n    let b = a + Vec::<i128, 2>::splat(i128::from_i64(args.len() as i64 - 1));\n    return b.e[0].to_i64() as i32;\n}\n",
        "x",
        "attempt to add with overflow",
    );
}

@test
fn casts_round_once() {
    // 2^200 + 1 rounds to 2^200 in f64, once.
    let x = (u256::one() << 200) + u256::one();
    assert(x.cast::<f64>() == 1606938044258990275541962092341162602522202993782792835301376.0);
    assert(f128::from_f64(1e300).cast::<i128>() == i128::max());
    assert(f128::from_f64(-2.75).cast::<i128>() == i128::from_i64(-2));
    assert(i128::from_i64(-70000).cast::<f16>().is_infinite());
    let t256 = third::<f256>();
    let t128 = t256.cast::<f128>();
    assert(t128 == third::<f128>());
    assert(u128::from_decimal(3.75, "3.75") == u128::from_u64(3));
}

// f(x) of a 400-digit reference rounded to the format, for inputs that take every range reduction.
@test
fn wide_float_reference_values() {
    assert(sin(f128_hex("73e6a3750647fcab18c21ab905450cc3")) == f128_hex("3ffd6d83fd6946e241dd929a03bad4bd"));
    assert(cos(f128_hex("73e6a3750647fcab18c21ab905450cc3")) == f128_hex("bffede457e6279aa1077024a8b3c7305"));
    assert(tan(f128_hex("73e6a3750647fcab18c21ab905450cc3")) == f128_hex("bffd874ad9b103e843d7f57fb32bc5bc"));
    assert(
        sin(f256_hex("78c55f44c21be1e7bcf1da954f49b709b6b8432f928a19daa18100a79a849b72")) == f256_hex(
            "bfffefb69b406b0f294c4a94abbefb5e6e310c787e5c138fba1c4ad863dc189a",
        ),
    );
    assert(
        cos(f256_hex("3fffe00000000000000000000000000000000000000000000000000000000000")) == f256_hex(
            "3fffec1528065b7d4f9db7bbb3b45f5f5b30aacacd67513e87d57ae46a15e7d1",
        ),
    );
    assert(
        tan(f256_hex("3ffff921fb54442d18306c8336e79acefc54485f00994c59840462fafd41742e")) == f256_hex(
            "400367178bb5475911d52050b90da2ec64791e5631f3ded0b8b28a4b526938e7",
        ),
    );
    assert(exp(f128_hex("c008f400000000000000000000000000")) == f128_hex("3a5c3c4219e4189540f324f46e7945bf"));
    assert(
        exp(f256_hex("4000f86a00000000000000000000000000000000000000000000000000000000")) == f256_hex(
            "6338c6b10f3ca6398f1a7f0db77250c6fd225c65b0c27612894cdd1b5284ed35",
        ),
    );
    assert(log2(f128_hex("40008000000000000000000000000000")) == f128_hex("3fff95c01a39fbd6879fa00b120a068c"));
    assert(
        log(f256_hex("73a805fcf905111fcab427f5625cbafb649d913ed6f17e69dbbe452f556398b")) == f256_hex(
            "c00103ace7a6ee7f1129f73da40c43318945416fd355c3e5b7f6ae1bfda6bf9e",
        ),
    );
    assert(asinh(f128_hex("3f9b4484bfeebc29f863424b06f3529a")) == f128_hex("3f9b4484bfeebc29f863424b06f3529a"));
    assert(atanh(f128_hex("3ffefffffff768fa0bec94b5a68ce97f")) == f128_hex("400256a9a0b21abc62fdd94fb76ee297"));
    assert(
        sinh(f256_hex("3ff7a16c262777579c58c46475896767b402a76c57cf783400856887c31589ce")) == f256_hex(
            "3ff7a16c262777579c58c46475896767b402a76c57cf783400856887c31589ce",
        ),
    );
    assert(tanh(f128_hex("40034000000000000000000000000000")) == f128_hex("3ffefffffffffffffec686db664e5dbe"));
    assert(acos(f128_hex("bffefffffffffdcd0ccfda42bddcd01b")) == f128_hex("4000921fa96742b0c033ab0910732617"));
    assert(
        asin(f256_hex("3fffe66666666666666666666666666666666666666666666666666666666666")) == f256_hex(
            "3fffe8d00e692afd95ddac34fe03894175c5ca828295659d8dd7c215b0d78d34",
        ),
    );
    assert(atan(f128_hex("406293e5939a08ce9dbd480000000000")) == f128_hex("3fff921fb54442d18469898cc516ed70"));
    assert(cosh(f128_hex("400c57c0000000000000000000000000")) == f128_hex("7dfb90712c344d655bb4c68a4e0ad481"));
    assert(exp2(f128_hex("c00d0042000000000000000000000000")) == f128_hex("2d413cccfe779921165f626d"));
    assert(
        acosh(f256_hex("3ffff00000000000000000000000002073accb12d0ff3d203ab3e521dc33b5d2")) == f256_hex(
            "3ffcc01cd13f3dc5922eff1cbc169bc80910a201dc75fe176dc1879eb91ccc6b",
        ),
    );
}

// The functions agree with the exact constants (each correctly rounded): atan(1) is pi/4 exactly scaled.
@test
fn wide_float_identities() {
    assert(atan(q(1.0)) * q(4.0) == pi::<f128>());
    assert(exp(q(1.0)) == e::<f128>());
    assert(log(q(2.0)) == ln_two::<f128>());
    assert(sqrt(q(2.0)) == root_two::<f128>());
    let one256 = f256::one();
    assert(atan(one256) * f256::from_f64(4.0) == pi::<f256>());
    assert(exp(one256) == e::<f256>());
    assert(log2(q(1024.0)) == q(10.0) && pow(q(2.0), q(10.0)) == q(1024.0) && exp2(q(-3.0)) == q(0.125));
    assert(sin(q(0.0)) == q(0.0) && sin(q(-0.0)) == q(-0.0) && cos(q(0.0)) == q(1.0));
    // C's special values.
    let inf = f128::infinity(false);
    let nan = f128::nan();
    assert(pow(nan, q(0.0)) == q(1.0) && pow(q(1.0), nan) == q(1.0) && pow(q(-1.0), inf) == q(1.0));
    assert(pow(q(-0.0), q(-3.0)) == f128::infinity(true) && pow(q(-0.0), q(3.0)) == q(-0.0));
    assert(pow(q(0.5), inf) == q(0.0) && pow(q(-8.0), q(1.0) / q(3.0)).is_nan());
    assert(atan2(q(0.0), q(-0.0)) == pi::<f128>() && atan2(q(-0.0), q(1.0)) == q(-0.0));
    assert(atan2(inf, f128::infinity(true)) == pi::<f128>() * q(0.75));
    assert(log(q(0.0)) == f128::infinity(true) && log(q(-1.0)).is_nan() && exp(f128::infinity(true)) == q(0.0));
    assert(atanh(q(1.0)) == inf && acosh(q(0.5)).is_nan() && tanh(q(50000.0)) == q(1.0));
}

// A format exact in f64 computes there and rounds once.
@test
fn narrow_formats_compute_in_f64() {
    for k in 0..40 {
        let x = f16::from_f64(-3.0 + k as f64 * 0.17);
        assert(sin(x) == f16::from_f64(x.to_f64().sin()));
        assert(exp(x) == f16::from_f64(x.to_f64().exp()));
        let y = bf16::from_f64(0.03 + k as f64 * 0.31);
        assert(log(y) == bf16::from_f64(y.to_f64().ln()));
        assert(atan2(y, bf16::from_f64(-1.0)) == bf16::from_f64(y.to_f64().atan2(-1.0)));
    }
    // A format without infinities saturates there.
    assert(infinity::<sf::f8e4m3fn>() == sf::f8e4m3fn::max_finite(false));
}

fn infinity<T: Float>() T {
    return T::infinity();
}

@test
fn wide_float_vectors_and_matrices() {
    let v = Vec::<f128, 3>::new(q(3.0), q(0.0), q(4.0));
    assert(length(v) == q(5.0) && normalize(v).e[2] == q(4.0) / q(5.0));
    let m = rotate(Mat::<f128, 4, 4>::identity(), q(0.5), normalize(Vec::<f128, 3>::new(q(1.0), q(2.0), q(2.0))));
    let p = inverse(m) * m;
    for i in 0..4usize {
        for j in 0..4usize {
            let want = if i == j {
                q(1.0);
            } else {
                q(0.0);
            };
            assert(abs(p[i][j] - want) < q(1e-32));
        }
    }
    let rq = angle_axis(pi::<f128>() / q(2.0), Vec::<f128, 3>::new(q(0.0), q(0.0), q(1.0)));
    let r = rq * Vec::<f128, 3>::new(q(1.0), q(0.0), q(0.0));
    assert(abs(r.e[0]) < q(1e-33) && abs(r.e[1] - q(1.0)) < q(1e-33));
    assert(equal_ulps(q(1.0), q(1.0).next_up(), 1) && !equal_ulps(q(1.0), q(1.0).next_up().next_up(), 1));
    assert(float_distance(q(1.0), q(1.0).next_up().next_up()) == i128::from_i64(2));
    let hv = Vec::<f16, 2>::new(f16::one(), f16::one());
    assert(float_distance(hv, hv).e[0] == std::int::Int::<16>::zero());
}

@test
fn large_types_of_every_scalar() {
    let big = u256_hex("100000000000000000000000000000");
    let a = LargeVec::<u256>::from_slice([big, u256::from_u64(2), u256::from_u64(3)]);
    assert(a.dot(&a) == big * big + u256::from_u64(13));
    let mi = LargeMat::<i128>::from_mat(
        Mat::<i128, 2, 2>::cols(
            Vec::<i128, 2>::new(i128::from_i64(1), i128::from_i64(-2)),
            Vec::<i128, 2>::new(i128::from_i64(3), i128::from_i64(4)),
        ),
    );
    let pi = &mi * &mi;
    assert(pi.get(0, 0) == i128::from_i64(-5) && pi.get(1, 1) == i128::from_i64(10));
    // A float format's dot: 16 strided fused partial sums, then summed by halves.
    let mut xs = Vector::<f16>::new();
    for k in 0..37 {
        xs.push(f16::from_f64(0.01 * k as f64 - 0.17));
    }
    let lv = LargeVec::<f16>::from_slice(xs[0..37]);
    let mut acc: [f16; 16] = [f16::zero(); 16];
    for k in 0..37usize {
        unsafe {
            acc[k % 16] = xs[k].fma(&xs[k], &acc[k % 16]);
        }
    }
    let mut w: usize = 8;
    while w >= 1 {
        for j in 0..w {
            unsafe {
                acc[j] = acc[j] + acc[j + w];
            }
        }
        w /= 2;
    }
    assert(lv.dot(&lv) == acc[0]);
    let mq = Mat::<f128, 2, 2>::cols(Vec::<f128, 2>::new(q(0.1), q(0.2)), Vec::<f128, 2>::new(q(0.3), q(0.4)));
    let f = mul_fused(mq, mq);
    let (a1, a3, a4, z) = (q(0.1), q(0.3), q(0.4), q(0.0));
    let inner = a3.fma(&a4, &z);
    assert(f[1][0] == a1.fma(&a3, &inner));
    let lq = LargeMat::<f128>::from_mat(mq);
    assert((&lq * &lq).get(0, 1) == f[1][0]);
}

@test
fn text_of_every_element_type() {
    assert(
        to_string(Vec::<u128, 2>::new(u128::from_u64(1), u128::max())).as_str() == "u128vec2(1, 340282366920938463463374607431768211455)",
    );
    assert(to_string(Vec::<f16, 2>::new(f16::one(), f16::from_f64(0.5))).as_str() == "f16vec2(1.000000, 0.500000)");
    assert(
        to_string(Vec::<f128, 2>::new(q(1.5), q(1.0) / q(10.0))).as_str() == "f128vec2(1.5e+0, 1.00000000000000000000000000000000005e-1)",
    );
    assert(to_string(Vec::<sf::Float<11, 100>, 1>::new(sf::Float::<11, 100>::one())).starts_with("f112e11m100vec1("));
    assert(to_string(Mat::<i128, 2, 2>::identity()).as_str() == "i128mat2x2((1, 0), (0, 1))");
}

@test
fn random_ranges_of_wide_types() {
    let mut rng = Pcg32::new(7, 11);
    let lo = u256_hex("1000000000000000000000000000000000");
    let hi = lo + u256_hex("ffffffffffffffffffffffff");
    for _ in 0..200 {
        let x = linear_rand(&mut rng, lo, hi);
        assert(x >= lo && x <= hi);
        let y = linear_rand(&mut rng, i128::from_i64(-50), i128::from_i64(-40));
        assert(y >= i128::from_i64(-50) && y <= i128::from_i64(-40));
        let z = linear_rand(&mut rng, q(0.0), q(1.0));
        assert(z >= q(0.0) && z <= q(1.0));
    }
}
