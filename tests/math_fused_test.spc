// std::math::fused: each function is the fused sum of squares in index order, bit for bit, at run time and
// in constants; exact results stay exact; and over a fixed sample its mean error against an f64 reference
// is no larger than the unfused function's. `LargeVec` and `LargeMat`: the dot product is its strided
// definition and every product the fused chain, bit for bit, over edge shapes; the element-wise operations,
// access and shapes; `mul_fused` on both of its paths; the machine's kernels against the portable ones;
// and a length or shape mismatch panics.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::geometric as *;
import std::math::mat as *;
import std::math::fused as *;
import std::float as fl;
import tests::harness as h;
import tests::cli_harness as cli;

// A fixed sequence of values in [-1, 1).
fn next(r: &mut u64) f32 {
    *r = r.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    return (*r >> 40 & 0xFFFFFF) as f32 / 8388608.0 - 1.0;
}

// The error of `x` in units in the last place of the f32 nearest to the reference `r`.
fn ulps(x: f32, r: f64) f64 {
    let n = (r as f32).abs();
    let up = fl::f32_from_bits(fl::f32_bits(n) + 1) as f64 - n as f64;
    return (x as f64 - r).abs() / up;
}

@test
fn length2_is_the_fused_chain() {
    let mut r: u64 = 7;
    for _ in 0..1000 {
        let v = vec4::new(next(&mut r), next(&mut r), next(&mut r), next(&mut r));
        let chain = v.e[3].mul_add(v.e[3], v.e[2].mul_add(v.e[2], v.e[1].mul_add(v.e[1], v.e[0] * v.e[0])));
        assert(fl::f32_bits(length2_fused(v)) == fl::f32_bits(chain));
        let d = dvec2::new(next(&mut r), next(&mut r));
        assert(length2_fused(d) == d.e[1].mul_add(d.e[1], d.e[0] * d.e[0]));
    }
}

@test
fn every_size() {
    assert(length2_fused(vec1::new(-3.0)) == 9.0);
    let v = Vec::<f32, 7>::splat(2.0);
    assert(length2_fused(v) == 28.0);
    assert(length_fused(Vec::<f64, 9>::splat(1.0)) == 3.0);
}

@test
fn exact_results_stay_exact() {
    assert(length_fused(vec3::new(3.0, 4.0, 0.0)) == 5.0);
    assert(length_fused(vec3::new(0.0, -2.0, 0.0)) == 2.0);
    assert(normalize_fused(vec3::new(0.0, 0.0, -7.0)) == vec3::new(0.0, 0.0, -1.0));
    assert(distance_fused(vec2::new(1.0, 1.0), vec2::new(4.0, 5.0)) == 5.0);
    assert(distance2_fused(vec2::new(1.0, 1.0), vec2::new(4.0, 5.0)) == 25.0);
    let z = normalize_fused(vec3::zero());
    assert(z.e[0].is_nan() && z.e[1].is_nan() && z.e[2].is_nan());
}

const L: f32 = length_fused(vec3::new(0.1, 0.7, -0.3));
const N3: vec3 = normalize_fused(vec3::new(0.1, 0.7, -0.3));

@c.noinline
fn opaque(v: vec3) vec3 {
    return v;
}

@test
fn constants_equal_the_run_time() {
    let v = opaque(vec3::new(0.1, 0.7, -0.3));
    assert(fl::f32_bits(L) == fl::f32_bits(length_fused(v)));
    let n = normalize_fused(v);
    for i in 0..N3.len() {
        assert(fl::f32_bits(N3[i]) == fl::f32_bits(n[i]));
    }
}

@test
fn at_least_as_accurate_as_unfused() {
    let mut r: u64 = 0x2545F4914F6CDD1D;
    let mut eu: f64 = 0.0;
    let mut ef: f64 = 0.0;
    for _ in 0..20000 {
        let v = vec3::new(next(&mut r), next(&mut r), next(&mut r));
        let x = v.e[0] as f64 * v.e[0] as f64 + v.e[1] as f64 * v.e[1] as f64 + v.e[2] as f64 * v.e[2] as f64;
        eu += ulps(length2(v), x);
        ef += ulps(length2_fused(v), x);
    }
    assert(ef <= eu, "the fused squared length is at least as accurate on average");
}

// ---- LargeVec and LargeMat ---------------------------------------------------------------------------

// `n` values of `next` as f64, every 13th a signed zero.
fn values(r: &mut u64, n: usize) Vector<f64> {
    let mut v = Vector::<f64>::with_capacity(n);
    for i in 0..n {
        let x = next(r) as f64 * 3.0;
        v.push(
            if i % 13 == 5 {
                -0.0;
            } else {
                x;
            },
        );
    }
    return v;
}

// The dot product's definition: 16 partial sums by fused multiply-add from +0.0, lane j holding
// elements j, j + 16, .., then summed by halves.
fn dot_def(a: []f64, b: []f64) f64 {
    let mut acc: [f64; 16] = [0.0; 16];
    for i in 0..a.len() {
        unsafe {
            acc[i % 16] = a[i].mul_add(b[i], acc[i % 16]);
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
    return acc[0];
}

@test
fn large_dot_is_the_strided_fused_sum() {
    let mut r: u64 = 11;
    for n in [0usize, 1, 15, 16, 17, 100, 1000] {
        let a = LargeVec::<f64>::from_slice(values(&mut r, n)[0..n]);
        let b = LargeVec::<f64>::from_slice(values(&mut r, n)[0..n]);
        assert(fl::f64_bits(a.dot(&b)) == fl::f64_bits(dot_def(a.as_slice(), b.as_slice())));
        assert(fl::f64_bits(a.length2()) == fl::f64_bits(dot_def(a.as_slice(), a.as_slice())));
    }
    let e = LargeVec::<f32>::zeros(0);
    assert(fl::f32_bits(e.dot(&e)) == 0, "an empty dot product is +0.0");
}

@test
fn large_vector_arithmetic() {
    let a = LargeVec::<f64>::from_vec(dvec3::new(3.0, 0.0, 4.0));
    let b = LargeVec::<f64>::splat(3, 1.0);
    assert(a.length() == 5.0);
    assert(a.distance(&a) == 0.0);
    let s = &a + &b;
    let d = &a - &b;
    let m = &a * &2.0;
    assert(s[0] == 4.0 && s[1] == 1.0 && s[2] == 5.0);
    assert(d[0] == 2.0 && d[1] == -1.0 && d[2] == 3.0);
    assert(m[0] == 6.0 && m[2] == 8.0);
    let u = a.normalized();
    assert(u[0] == 3.0 * (1.0 / 5.0) && u[2] == 4.0 * (1.0 / 5.0));
    let mut y = LargeVec::<f32>::splat(37, 0.1);
    let x = LargeVec::<f32>::splat(37, 0.3);
    y.axpy(0.7, &x);
    for i in 0..y.len() {
        assert(fl::f32_bits(y[i]) == fl::f32_bits(0.7f32.mul_add(0.3, 0.1)));
    }
    let mut c = y.clone();
    c[3] = 2.0;
    assert(c[3] == 2.0 && y[3] != 2.0);
}

// Column-major `rows` x `cols` elements of `next`.
fn large_mat(r: &mut u64, rows: usize, cols: usize) LargeMat<f64> {
    return LargeMat::<f64>::from_slice(rows, cols, values(r, rows * cols)[0..rows * cols]);
}

// Element (i, j) of `a * b` by its definition: the fused chain over p in order from +0.0.
fn chain(a: &LargeMat<f64>, b: &LargeMat<f64>, i: usize, j: usize) f64 {
    let mut s: f64 = 0.0;
    for p in 0..a.cols() {
        s = a.get(i, p).mul_add(b.get(p, j), s);
    }
    return s;
}

@test
fn large_products_are_the_fused_chain() {
    let mut r: u64 = 23;
    let shapes: [[usize; 3]; 6] = [[1, 1, 1], [3, 5, 7], [16, 16, 16], [33, 17, 40], [64, 64, 64], [40, 1, 3]];
    for s in shapes {
        let (m, k, n) = (s[0], s[1], s[2]);
        let a = large_mat(&mut r, m, k);
        let b = large_mat(&mut r, k, n);
        let c = &a * &b;
        assert(c.rows() == m && c.cols() == n);
        for i in 0..m {
            for j in 0..n {
                assert(fl::f64_bits(c.get(i, j)) == fl::f64_bits(chain(&a, &b, i, j)));
            }
        }
        // Matrix times vector: below 32 rows the lanes, from 32 on the matrix kernel.
        let x = LargeVec::<f64>::from_slice(values(&mut r, k)[0..k]);
        let y = &a * &x;
        let xm = LargeMat::<f64>::from_slice(k, 1, x.as_slice());
        for i in 0..m {
            assert(fl::f64_bits(y[i]) == fl::f64_bits(chain(&a, &xm, i, 0)));
        }
    }
}

@test
fn large_matrix_shape_and_access() {
    let m = LargeMat::<f32>::from_mat(mat2x3::cols(vec3::new(1.0, 2.0, 3.0), vec3::new(4.0, 5.0, 6.0)));
    assert(m.rows() == 3 && m.cols() == 2);
    assert(m.get(2, 0) == 3.0 && m.get(0, 1) == 4.0);
    assert(m.column(1)[2] == 6.0);
    let t = m.transpose();
    assert(t.rows() == 2 && t.cols() == 3 && t.get(1, 2) == 6.0 && t.get(0, 1) == 2.0);
    let mut i = LargeMat::<f32>::identity(3);
    let p = &i * &m;
    for k in 0..m.as_slice().len() {
        assert(p.as_slice()[k] == m.as_slice()[k]);
    }
    i.set(1, 1, 5.0);
    assert(i.get(1, 1) == 5.0 && i.clone().get(1, 1) == 5.0);
}

@test
fn mul_fused_is_the_fused_chain() {
    let mut r: u64 = 31;
    let mut a = Mat::<f32, 5, 3>::zero();
    let mut b = Mat::<f32, 4, 5>::zero();
    for j in 0..5usize {
        for i in 0..3usize {
            a[j][i] = next(&mut r);
        }
        for q in 0..4usize {
            b[q][j] = next(&mut r);
        }
    }
    let c = mul_fused(a, b);
    for q in 0..4usize {
        for i in 0..3usize {
            let mut s: f32 = 0.0;
            for p in 0..5usize {
                s = a[p][i].mul_add(b[q][p], s);
            }
            assert(fl::f32_bits(c[q][i]) == fl::f32_bits(s));
        }
    }
    let x = mat2::cols(vec2::new(2.0, -3.0), vec2::new(0.5, 7.0));
    assert(mul_fused(mat2::identity(), x) == x);
    // From 32 x 32 x 32 on, the matrix kernel: the same chain as `LargeMat`'s product.
    let mut big = Mat::<f64, 32, 32>::zero();
    for j in 0..32usize {
        for i in 0..32usize {
            big[j][i] = next(&mut r);
        }
    }
    let f = mul_fused(big, big);
    let lb = LargeMat::<f64>::from_mat(big);
    let lp = &lb * &lb;
    for j in 0..32usize {
        for i in 0..32usize {
            assert(fl::f64_bits(f[j][i]) == fl::f64_bits(lp.get(i, j)));
            assert(fl::f64_bits(lp.get(i, j)) == fl::f64_bits(chain(&lb, &lb, i, j)));
        }
    }
}

@test
fn large_length_mismatch_panics() {
    h::expect_run(
        "dot of different lengths",
        "import std::math::fused as *;\nfn main() i32 {\n    let a = LargeVec::<f32>::zeros(3);\n    let b = LargeVec::<f32>::zeros(4);\n    return a.dot(&b) as i32;\n}\n",
        "",
        "LargeVec::dot: the lengths differ",
    );
    h::expect_run(
        "product of mismatched shapes",
        "import std::math::fused as *;\nfn main() i32 {\n    let a = LargeMat::<f64>::zeros(2, 3);\n    let b = LargeMat::<f64>::zeros(2, 3);\n    let c = &a * &b;\n    return c.rows() as i32;\n}\n",
        "",
        "LargeMat * LargeMat: the left column count is not the right row count",
    );
}

// Matrix products and dot products of the large types, checked against the fused chain and hashed.
const LARGE_KERNELS: str<'static> = M"(import std::math::fused as *;
import std::float as fl;

fn next(r: &mut u64) u64 {
    *r ^= *r << 13;
    *r ^= *r >> 7;
    *r ^= *r << 17;
    return *r;
}

fn val(r: &mut u64) f64 {
    return ((next(r) >> 11) as f64 / 9007199254740992.0 - 0.5) * 8.0;
}

fn mix(h: u64, v: u64) u64 {
    return (h ^ v).wrapping_mul(0x100000001b3);
}

fn main() i32 {
    let mut r: u64 = 0x9E3779B97F4A7C15;
    let shapes: [[usize; 3]; 5] = [[3, 5, 7], [33, 17, 65], [64, 64, 64], [100, 31, 1], [129, 3, 130]];
    let mut bad: u64 = 0;
    let mut hash: u64 = 0xcbf29ce484222325;
    for s in shapes {
        let (m, k, n) = (s[0], s[1], s[2]);
        let mut a = LargeMat::<f64>::zeros(m, k);
        let mut b = LargeMat::<f32>::zeros(k, n);
        let mut x = LargeVec::<f64>::zeros(k);
        for i in 0..m {
            for p in 0..k {
                a.set(i, p, val(&mut r));
            }
        }
        for p in 0..k {
            x[p] = val(&mut r);
            for j in 0..n {
                b.set(p, j, val(&mut r) as f32);
            }
        }
        let b2 = b.transpose();
        let c = &b2 * &b;
        let y = &a * &x;
        for i in 0..n {
            for j in 0..n {
                let mut s32: f32 = 0.0;
                for p in 0..k {
                    s32 = b2.get(i, p).mul_add(b.get(p, j), s32);
                }
                if fl::f32_bits(c.get(i, j)) != fl::f32_bits(s32) {
                    bad += 1;
                }
                hash = mix(hash, fl::f32_bits(c.get(i, j)));
            }
        }
        for i in 0..m {
            let mut s64: f64 = 0.0;
            for p in 0..k {
                s64 = a.get(i, p).mul_add(x[p], s64);
            }
            if fl::f64_bits(y[i]) != fl::f64_bits(s64) {
                bad += 1;
            }
            hash = mix(hash, fl::f64_bits(y[i]));
        }
        hash = mix(hash, fl::f64_bits(x.dot(&x)));
    }
    println("mismatches {} hash {}", bad, hash);
    return bad as i32;
}
)";

// The run of `p`'s program with `env` (NAME=VALUE pairs): its output, or "fail".
fn kernels_run(p: &cli::Proj, env: str) String {
    let root = p.dir();
    let mut cmd = format("\"{}/app\"", root);
    let mut out = format("{}/.out", root);
    let mut err = format("{}/.err", root);
    let rc = cli::run_with(cmd.cstr(), null, out.cstr(), err.cstr(), env);
    if rc != 0 {
        eprintln("[{}]: exit {}: {}", env, rc, cli::read_text(err.as_str()).as_str());
        return String::from_str("fail");
    }
    return cli::read_text(out.as_str());
}

// The machine's kernels (SME where the CPU has them) and the portable ones (`SC_CPU_OFF`) give the
// fused chain, so the same bits.
@test
fn large_kernels_agree() {
    let p = cli::proj_new();
    p.mkfile("main.spc", LARGE_KERNELS);
    let root = p.dir();
    let b = p.run_raw(format("build \"{}/main.spc\" -o \"{}/app\"", root, root).as_str());
    if !b.ok() {
        b.show();
    }
    assert(b.ok(), "the program builds");
    let with = kernels_run(&p, "");
    let without = kernels_run(&p, "SC_CPU_OFF=0xFFFFFFFFFFFFFFFF");
    assert(with.starts_with("mismatches 0 "), "the products equal the fused chain");
    assert(with == without, "the machine's kernels and the portable ones agree");
}
