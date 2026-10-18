// std::math::mat: operators, construction, inverse, shape conversion, size and bits of every matrix
// shape, `matrix_comp_mult`, `outer_product`, `transpose`, `inverse` and `adjugate`, then
// determinants, `mat4::from_mat(mat4x2)`, every operator on every shape, integer matrices, the
// diagonal builders, integer adjugates, index traps and constant initializers.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::compare as *;

// Every component of `a` within `eps` of `b`.
fn near<T: Float, const N: usize>(a: Vec<T, N>, b: Vec<T, N>, eps: T) bool {
    for i in 0..N {
        if !(a[i] - b[i]).abs().less_equal(eps) {
            return false;
        }
    }
    return true;
}

// Every element of `a` within `eps` of `b`.
fn near_mat<T: Float, const C: usize, const R: usize>(a: Mat<T, C, R>, b: Mat<T, C, R>, eps: T) bool {
    for i in 0..C {
        if !near(a[i], b[i], eps) {
            return false;
        }
    }
    return true;
}

// The matrix whose element (i, j) is `i * R + j + 1`: distinct small integers, exact in every type.
fn seq<T: Scalar, const C: usize, const R: usize>(start: i64) Mat<T, C, R> {
    let mut m = Mat::<T, C, R>::zero();
    for i in 0..C {
        for j in 0..R {
            m[i][j] = T::from_i64(start + (i * R + j) as i64);
        }
    }
    return m;
}

// The vector `start, start + 1, ..`.
fn seq_vec<T: Scalar, const N: usize>(start: i64) Vec<T, N> {
    let mut v = Vec::<T, N>::zero();
    for i in 0..N {
        v[i] = T::from_i64(start + i as i64);
    }
    return v;
}

// The operators of a C x R matrix: `a` is `m * u`, `b` is `v * m` for the identity `m` and all-ones
// `u` and `v`.
fn operators<const C: usize, const R: usize>(a_expected: Vec<f32, R>, b_expected: Vec<f32, C>) {
    let eps = f32::epsilon();
    let l = Mat::<f32, C, R>::diagonal(1.0);
    let m = Mat::<f32, C, R>::diagonal(1.0);
    let u = Vec::<f32, C>::splat(1.0);
    let v = Vec::<f32, R>::splat(1.0);
    let x: f32 = 1.0;
    let a = m * u;
    assert(near(a, a_expected, eps));
    let b = v * m;
    assert(near(b, b_expected, eps));
    let n0 = Mat::<f32, C, R>::from_cols([Vec::<f32, R>::splat(1.0); C]);
    let n = x / n0;
    assert(near_mat(n, n0, eps));
    let o = m / x;
    assert(near_mat(o, m, eps));
    let p = x * m;
    assert(near_mat(p, m, eps));
    let q = m * x;
    let r = !near_mat(m, q, eps);
    let s = near_mat(m, l, eps);
    assert(s && !r);
}

// `from_mat` of the C2 x R2 identity is the C x R identity.
fn from_identity<const C2: usize, const R2: usize, const C: usize, const R: usize>() {
    let a = Mat::<f32, C2, R2>::diagonal(1.0);
    let b = Mat::<f32, C, R>::from_mat(a);
    assert(near_mat(b, Mat::<f32, C, R>::identity(), f32::epsilon()));
}

// `from_identity` for every source shape.
fn from_every_identity<const C: usize, const R: usize>() {
    from_identity::<2, 2, C, R>();
    from_identity::<2, 3, C, R>();
    from_identity::<2, 4, C, R>();
    from_identity::<3, 2, C, R>();
    from_identity::<3, 3, C, R>();
    from_identity::<3, 4, C, R>();
    from_identity::<4, 2, C, R>();
    from_identity::<4, 3, C, R>();
    from_identity::<4, 4, C, R>();
}

// Two fields on the same matrix bits.
union MatPack<const C: usize, const R: usize> {
    pub f: Mat<f32, C, R>,
    pub i: Mat<f32, C, R>,
}

// Column 0 of the 0.0 diagonal and the 1.0 diagonal, read through the other union field.
fn pack_cols<const C: usize, const R: usize>() {
    let eps = f32::epsilon();
    let a = MatPack::<C, R> { f: Mat::<f32, C, R>::diagonal(0.0) };
    assert(near(a.i[0], Vec::<f32, R>::zero(), eps));
    let b = MatPack::<C, R> { f: Mat::<f32, C, R>::diagonal(1.0) };
    let mut e = Vec::<f32, R>::zero();
    e[0] = 1.0;
    assert(near(b.i[0], e, eps));
}

// `a * b` against the sum of products written out, for exact integer-valued elements.
fn check_mul<T: Scalar, const C: usize, const R: usize, const K: usize>() {
    let a = seq::<T, C, R>(1);
    let b = seq::<T, K, C>(-3);
    let p = a * b;
    for k in 0..K {
        for r in 0..R {
            let mut s = T::zero();
            for i in 0..C {
                s = s + a[i][r] * b[k][i];
            }
            assert(p[k][r].equal(s));
        }
    }
}

// `m * v` and `v * m` against the sums written out.
fn check_mul_vec<T: Scalar, const C: usize, const R: usize>() {
    let m = seq::<T, C, R>(2);
    let v = seq_vec::<T, C>(-1);
    let w = seq_vec::<T, R>(3);
    let mv = m * v;
    for j in 0..R {
        let mut s = T::zero();
        for i in 0..C {
            s = s + m[i][j] * v[i];
        }
        assert(mv[j].equal(s));
    }
    let wm = w * m;
    for k in 0..C {
        let mut s = T::zero();
        for i in 0..R {
            s = s + w[i] * m[k][i];
        }
        assert(wm[k].equal(s));
    }
}

// The element-wise operators of one shape against each element.
fn check_elementwise<T: Scalar, const C: usize, const R: usize>() {
    let a = seq::<T, C, R>(1);
    let b = seq::<T, C, R>(5);
    let s = T::from_i64(2);
    let sum = a + b;
    let diff = b - a;
    let neg = -a;
    let ms = a * s;
    let sm = s * a;
    let ds = b / s;
    let sd = s / b;
    let ps = a + s;
    let sp = s + a;
    let mns = a - s;
    let smn = s - a;
    let cm = matrix_comp_mult(a, b);
    for i in 0..C {
        for j in 0..R {
            assert(sum[i][j].equal(a[i][j] + b[i][j]));
            assert(diff[i][j].equal(b[i][j] - a[i][j]));
            assert(neg[i][j].equal(T::zero() - a[i][j]));
            assert(ms[i][j].equal(a[i][j] * s));
            assert(sm[i][j].equal(s * a[i][j]));
            assert(ds[i][j].equal(b[i][j] / s));
            assert(sd[i][j].equal(s / b[i][j]));
            assert(ps[i][j].equal(a[i][j] + s));
            assert(sp[i][j].equal(s + a[i][j]));
            assert(mns[i][j].equal(a[i][j] - s));
            assert(smn[i][j].equal(s - a[i][j]));
            assert(cm[i][j].equal(a[i][j] * b[i][j]));
        }
    }
    let t = transpose(a);
    assert(transpose(t) == a);
    for i in 0..C {
        for j in 0..R {
            assert(t[j][i].equal(a[i][j]));
        }
    }
    let mut c = a;
    c += b;
    assert(c == sum);
    c -= b;
    assert(c == a);
    assert(a == a);
    assert(a != b);
}

// Every operator of every shape for one element type.
fn check_all_shapes<T: Scalar>() {
    check_elementwise::<T, 2, 2>();
    check_elementwise::<T, 2, 3>();
    check_elementwise::<T, 2, 4>();
    check_elementwise::<T, 3, 2>();
    check_elementwise::<T, 3, 3>();
    check_elementwise::<T, 3, 4>();
    check_elementwise::<T, 4, 2>();
    check_elementwise::<T, 4, 3>();
    check_elementwise::<T, 4, 4>();
    check_mul_vec::<T, 2, 2>();
    check_mul_vec::<T, 2, 3>();
    check_mul_vec::<T, 2, 4>();
    check_mul_vec::<T, 3, 2>();
    check_mul_vec::<T, 3, 3>();
    check_mul_vec::<T, 3, 4>();
    check_mul_vec::<T, 4, 2>();
    check_mul_vec::<T, 4, 3>();
    check_mul_vec::<T, 4, 4>();
    check_mul::<T, 2, 2, 2>();
    check_mul::<T, 2, 2, 3>();
    check_mul::<T, 2, 2, 4>();
    check_mul::<T, 2, 3, 2>();
    check_mul::<T, 2, 3, 3>();
    check_mul::<T, 2, 3, 4>();
    check_mul::<T, 2, 4, 2>();
    check_mul::<T, 2, 4, 3>();
    check_mul::<T, 2, 4, 4>();
    check_mul::<T, 3, 2, 2>();
    check_mul::<T, 3, 2, 3>();
    check_mul::<T, 3, 2, 4>();
    check_mul::<T, 3, 3, 2>();
    check_mul::<T, 3, 3, 3>();
    check_mul::<T, 3, 3, 4>();
    check_mul::<T, 3, 4, 2>();
    check_mul::<T, 3, 4, 3>();
    check_mul::<T, 3, 4, 4>();
    check_mul::<T, 4, 2, 2>();
    check_mul::<T, 4, 2, 3>();
    check_mul::<T, 4, 2, 4>();
    check_mul::<T, 4, 3, 2>();
    check_mul::<T, 4, 3, 3>();
    check_mul::<T, 4, 3, 4>();
    check_mul::<T, 4, 4, 2>();
    check_mul::<T, 4, 4, 3>();
    check_mul::<T, 4, 4, 4>();
}

// The mat4 scalar, vector and matrix operators, for one element type.
fn mat4_operators_of<T: Float>() {
    let eps = T::from_f64(0.001);
    let m = Mat::<T, 4, 4>::diagonal(T::from_f64(2.0));
    let n = Mat::<T, 4, 4>::diagonal(T::one());
    let u = Vec::<T, 4>::splat(T::from_f64(2.0));
    let p = n * T::from_f64(2.0);
    assert(near_mat(p, m, eps));
    let q = m / T::from_f64(2.0);
    assert(near_mat(q, n, eps));
    let v = m * u;
    assert(near(v, Vec::<T, 4>::splat(T::from_f64(4.0)), eps));
    let w = u / m;
    assert(near(w, Vec::<T, 4>::splat(T::one()), eps));
    let o = m * n;
    assert(near_mat(o, Mat::<T, 4, 4>::diagonal(T::from_f64(2.0)), eps));
}

// `matrix * (identity / matrix)` is the identity within 0.001, for one element type.
fn mat4_inverse_of<T: Float>() {
    let identity = Mat::<T, 4, 4>::diagonal(T::one());
    let matrix = Mat::<T, 4, 4>::cols(
        vec4::new(0.6, 0.2, 0.3, 0.4).cast::<T>(),
        vec4::new(0.2, 0.7, 0.5, 0.3).cast::<T>(),
        vec4::new(0.3, 0.5, 0.7, 0.2).cast::<T>(),
        vec4::new(0.4, 0.3, 0.2, 0.6).cast::<T>(),
    );
    let inv = identity / matrix;
    let result = matrix * inv;
    assert(near_mat(identity, result, T::from_f64(0.001)));
}

const M2: mat4 = mat4::identity() * 2.0;
const T23: mat3x2 = transpose(mat2x3::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0));
const DET: f32 = determinant(mat2::new(1.0, 2.0, 3.0, 4.0));
const INV: mat2 = inverse(mat2::new(4.0, 0.0, 0.0, 2.0));
const OUTER: mat3x2 = outer_product(vec2::new(1.0, 2.0), vec3::new(3.0, 4.0, 5.0));
const IM: imat3 = imat3::identity() * 3;
const PROD: mat2 = mat3x2::new(1.0, 2.0, 3.0, 4.0, 0.0, 0.0) * mat2x3::new(1.0, 0.0, 0.0, 0.0, 3.0, 0.0);
const FROM: mat4 = mat4::from_mat(mat4x2::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0));
const DIAG: mat4x3 = diagonal4x3(vec3::new(2.0, 3.0, 4.0));
const ADJ: imat2 = adjugate(imat2::new(2, 3, 1, 5));
const ADJ3: imat3 = adjugate(imat3::new(2, 3, 3, 1, 5, 4, 4, 6, 8));
const ADJ4: imat4 = adjugate(imat4::new(2, 3, 3, 1, 1, 5, 4, 3, 4, 6, 8, 5, -2, -3, -3, 4));
const INV3: dmat3 = inverse(dmat3::new(2.0, 3.0, 3.0, 1.0, 5.0, 4.0, 4.0, 6.0, 8.0));
const INV4: mat4 = inverse(mat4::new(2.0, 0.0, 0.0, 0.0, 0.0, 4.0, 0.0, 0.0, 0.0, 0.0, 8.0, 0.0, 1.0, 2.0, 3.0, 1.0));
const AFF3: mat3 = affine_inverse(mat3::new(2.0, 0.0, 0.0, 0.0, 4.0, 0.0, 1.0, 2.0, 1.0));
const AFF4: mat4 = affine_inverse(
    mat4::new(2.0, 0.0, 0.0, 0.0, 0.0, 4.0, 0.0, 0.0, 0.0, 0.0, 8.0, 0.0, 1.0, 2.0, 3.0, 1.0),
);

// mat2x2.

@test
fn mat2x2_operators() {
    operators::<2, 2>(vec2::splat(1.0), vec2::splat(1.0));
}

@test
fn mat2x2_inverse() {
    {
        let matrix = mat2::new(1.0, 2.0, 3.0, 4.0);
        let inv = inverse(matrix);
        let identity = matrix * inv;
        assert(near(identity[0], vec2::new(1.0, 0.0), 0.01));
        assert(near(identity[1], vec2::new(0.0, 1.0), 0.01));
    }
    {
        let matrix = mat2::new(1.0, 2.0, 3.0, 4.0);
        let identity = matrix / matrix;
        assert(near(identity[0], vec2::new(1.0, 0.0), 0.01));
        assert(near(identity[1], vec2::new(0.0, 1.0), 0.01));
    }
}

@test
fn mat2x2_ctr() {
    let eps = f32::epsilon();
    {
        let a = mat2x2::diagonal(1.0);
        let b = mat2x2::from_mat(a);
        let c = mat2x2::from_mat(b);
        assert(near_mat(a, c, eps));
    }
    let m0 = mat2x2::cols(vec2::new(0.0, 1.0), vec2::new(2.0, 3.0));
    let m1 = mat2x2::new(0.0, 1.0, 2.0, 3.0);
    let m2 = mat2x2 { c: [vec2::new(0.0, 1.0), vec2::new(2.0, 3.0)] };
    assert(near_mat(m0, m2, eps));
    assert(near_mat(m1, m2, eps));
    let v1: [mat2x2; 2] = [mat2x2::new(0.0, 1.0, 2.0, 3.0), mat2x2::new(0.0, 1.0, 2.0, 3.0)];
    let v2: [mat2x2; 2] = [
        mat2x2::from_cols([vec2::new(0.0, 1.0), vec2::new(4.0, 5.0)]),
        mat2x2::from_cols([vec2::new(0.0, 1.0), vec2::new(4.0, 5.0)]),
    ];
    assert(v1[1] == m1);
    assert(v2[0][1] == vec2::new(4.0, 5.0));
}

@test
fn mat2x2_cast() {
    from_every_identity::<2, 2>();
}

@test
fn mat2x2_size() {
    assert_eq(sizeof(mat2x2), 16);
    assert_eq(sizeof(dmat2x2), 32);
    assert_eq(mat2x2::LEN, 2);
    assert_eq(dmat2x2::LEN, 2);
}

// mat2x3.

@test
fn mat2x3_operators() {
    operators::<2, 3>(vec2::splat(1.0).append(0.0), vec2::splat(1.0));
}

@test
fn mat2x3_ctr() {
    let eps = f32::epsilon();
    let m0 = mat2x3::cols(vec3::new(0.0, 1.0, 2.0), vec3::new(3.0, 4.0, 5.0));
    let m1 = mat2x3::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0);
    let m2 = mat2x3 { c: [vec3::new(0.0, 1.0, 2.0), vec3::new(3.0, 4.0, 5.0)] };
    assert(near_mat(m0, m2, eps));
    assert(near_mat(m1, m2, eps));
    let v: [mat2x3; 2] = [m1, mat2x3::from_cols([vec3::new(0.0, 1.0, 2.0), vec3::new(4.0, 5.0, 6.0)])];
    assert(v[1][1] == vec3::new(4.0, 5.0, 6.0));
}

@test
fn mat2x3_cast() {
    from_every_identity::<2, 3>();
}

@test
fn mat2x3_size() {
    assert_eq(sizeof(mat2x3), 24);
    assert_eq(sizeof(dmat2x3), 48);
    assert_eq(mat2x3::LEN, 2);
    assert_eq(dmat2x3::LEN, 2);
}

// mat2x4.

@test
fn mat2x4_operators() {
    operators::<2, 4>(vec2::splat(1.0).append(0.0).append(0.0), vec2::splat(1.0));
}

@test
fn mat2x4_ctr() {
    let eps = f32::epsilon();
    let m0 = mat2x4::cols(vec4::new(0.0, 1.0, 2.0, 3.0), vec4::new(4.0, 5.0, 6.0, 7.0));
    let m1 = mat2x4::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0);
    let m2 = mat2x4 { c: [vec4::new(0.0, 1.0, 2.0, 3.0), vec4::new(4.0, 5.0, 6.0, 7.0)] };
    assert(near_mat(m0, m2, eps));
    assert(near_mat(m1, m2, eps));
}

@test
fn mat2x4_cast() {
    from_every_identity::<2, 4>();
}

@test
fn mat2x4_size() {
    assert_eq(sizeof(mat2x4), 32);
    assert_eq(sizeof(dmat2x4), 64);
    assert_eq(mat2x4::LEN, 2);
    assert_eq(dmat2x4::LEN, 2);
}

// mat3x2.

@test
fn mat3x2_operators() {
    operators::<3, 2>(vec2::splat(1.0), vec2::splat(1.0).append(0.0));
}

@test
fn mat3x2_ctr() {
    let eps = f32::epsilon();
    let m0 = mat3x2::cols(vec2::new(0.0, 1.0), vec2::new(2.0, 3.0), vec2::new(4.0, 5.0));
    let m1 = mat3x2::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0);
    let m2 = mat3x2 { c: [vec2::new(0.0, 1.0), vec2::new(2.0, 3.0), vec2::new(4.0, 5.0)] };
    assert(near_mat(m0, m2, eps));
    assert(near_mat(m1, m2, eps));
}

@test
fn mat3x2_cast() {
    from_every_identity::<3, 2>();
}

@test
fn mat3x2_size() {
    assert_eq(sizeof(mat3x2), 24);
    assert_eq(sizeof(dmat3x2), 48);
    assert_eq(mat3x2::LEN, 3);
    assert_eq(dmat3x2::LEN, 3);
}

// mat3x3.

@test
fn mat3x3_inverse_double() {
    let mat0 = dmat3::cols(
        vec3::new(0.6, 0.2, 0.3).cast::<f64>(),
        vec3::new(0.2, 0.7, 0.5).cast::<f64>(),
        vec3::new(0.3, 0.5, 0.7).cast::<f64>(),
    );
    let inv0 = inverse(mat0);
    let res0 = mat0 * inv0;
    assert(near_mat(res0, dmat3::diagonal(1.0), 0.01));
}

@test
fn mat3x3_operators() {
    operators::<3, 3>(vec3::splat(1.0), vec3::splat(1.0));
}

@test
fn mat3x3_inverse() {
    {
        let matrix = mat3::cols(vec3::new(0.6, 0.2, 0.3), vec3::new(0.2, 0.7, 0.5), vec3::new(0.3, 0.5, 0.7));
        let inv = inverse(matrix);
        let identity = matrix * inv;
        assert(near(identity[0], vec3::new(1.0, 0.0, 0.0), 0.01));
        assert(near(identity[1], vec3::new(0.0, 1.0, 0.0), 0.01));
        assert(near(identity[2], vec3::new(0.0, 0.0, 1.0), 0.01));
    }
    {
        let matrix = mat3::cols(vec3::new(0.6, 0.2, 0.3), vec3::new(0.2, 0.7, 0.5), vec3::new(0.3, 0.5, 0.7));
        let identity = matrix / matrix;
        assert(near(identity[0], vec3::new(1.0, 0.0, 0.0), 0.01));
        assert(near(identity[1], vec3::new(0.0, 1.0, 0.0), 0.01));
        assert(near(identity[2], vec3::new(0.0, 0.0, 1.0), 0.01));
    }
}

@test
fn mat3x3_ctr() {
    let eps = f32::epsilon();
    let m0 = mat3x3::cols(vec3::new(0.0, 1.0, 2.0), vec3::new(3.0, 4.0, 5.0), vec3::new(6.0, 7.0, 8.0));
    let m1 = mat3x3::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
    let m2 = mat3x3 { c: [vec3::new(0.0, 1.0, 2.0), vec3::new(3.0, 4.0, 5.0), vec3::new(6.0, 7.0, 8.0)] };
    assert(near_mat(m0, m2, eps));
    assert(near_mat(m1, m2, eps));
}

@test
fn mat3x3_cast() {
    from_every_identity::<3, 3>();
}

@test
fn mat3x3_size() {
    assert_eq(sizeof(mat3x3), 36);
    assert_eq(sizeof(dmat3x3), 72);
    assert_eq(mat3x3::LEN, 3);
    assert_eq(dmat3x3::LEN, 3);
}

// mat3x4.

@test
fn mat3x4_operators() {
    operators::<3, 4>(vec3::splat(1.0).append(0.0), vec3::splat(1.0));
}

@test
fn mat3x4_ctr() {
    let eps = f32::epsilon();
    let m0 = mat3x4::cols(vec4::new(0.0, 1.0, 2.0, 3.0), vec4::new(4.0, 5.0, 6.0, 7.0), vec4::new(8.0, 9.0, 10.0, 11.0));
    let m1 = mat3x4::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0);
    let m2 = mat3x4 {
        c: [vec4::new(0.0, 1.0, 2.0, 3.0), vec4::new(4.0, 5.0, 6.0, 7.0), vec4::new(8.0, 9.0, 10.0, 11.0)],
    };
    assert(near_mat(m0, m2, eps));
    assert(near_mat(m1, m2, eps));
}

@test
fn mat3x4_cast() {
    from_every_identity::<3, 4>();
}

@test
fn mat3x4_size() {
    assert_eq(sizeof(mat3x4), 48);
    assert_eq(sizeof(dmat3x4), 96);
    assert_eq(mat3x4::LEN, 3);
    assert_eq(dmat3x4::LEN, 3);
}

// mat4x2.

@test
fn mat4x2_operators() {
    operators::<4, 2>(vec2::splat(1.0), vec2::splat(1.0).append(0.0).append(0.0));
}

@test
fn mat4x2_ctr() {
    let eps = f32::epsilon();
    let m0 = mat4x2::cols(vec2::new(0.0, 1.0), vec2::new(2.0, 3.0), vec2::new(4.0, 5.0), vec2::new(6.0, 7.0));
    let m1 = mat4x2::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0);
    let m2 = mat4x2 { c: [vec2::new(0.0, 1.0), vec2::new(2.0, 3.0), vec2::new(4.0, 5.0), vec2::new(6.0, 7.0)] };
    assert(near_mat(m0, m2, eps));
    assert(near_mat(m1, m2, eps));
}

@test
fn mat4x2_cast() {
    from_every_identity::<4, 2>();
}

@test
fn mat4x2_size() {
    assert_eq(sizeof(mat4x2), 32);
    assert_eq(sizeof(dmat4x2), 64);
    assert_eq(mat4x2::LEN, 4);
    assert_eq(dmat4x2::LEN, 4);
}

// mat4x3.

@test
fn mat4x3_operators() {
    operators::<4, 3>(vec3::splat(1.0), vec3::splat(1.0).append(0.0));
}

@test
fn mat4x3_ctr() {
    let eps = f32::epsilon();
    let m0 = mat4x3::cols(
        vec3::new(0.0, 1.0, 2.0),
        vec3::new(3.0, 4.0, 5.0),
        vec3::new(6.0, 7.0, 8.0),
        vec3::new(9.0, 10.0, 11.0),
    );
    let m1 = mat4x3::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0);
    let m2 = mat4x3 {
        c: [vec3::new(0.0, 1.0, 2.0), vec3::new(3.0, 4.0, 5.0), vec3::new(6.0, 7.0, 8.0), vec3::new(9.0, 10.0, 11.0)],
    };
    assert(near_mat(m0, m2, eps));
    assert(near_mat(m1, m2, eps));
}

@test
fn mat4x3_cast() {
    from_every_identity::<4, 3>();
}

@test
fn mat4x3_size() {
    assert_eq(sizeof(mat4x3), 48);
    assert_eq(sizeof(dmat4x3), 96);
    assert_eq(mat4x3::LEN, 4);
    assert_eq(dmat4x3::LEN, 4);
}

// mat4x4.

@test
fn mat4x4_member_alloc() {
    let m = Box::new(mat4::zero());
    assert(*m == mat4::diagonal(0.0));
}

@test
fn mat4x4_ctr() {
    let eps = f32::epsilon();
    let m0 = mat4::cols(
        vec4::new(0.0, 1.0, 2.0, 3.0),
        vec4::new(4.0, 5.0, 6.0, 7.0),
        vec4::new(8.0, 9.0, 10.0, 11.0),
        vec4::new(12.0, 13.0, 14.0, 15.0),
    );
    assert_eq(sizeof(mat4), 4 * 4 * 4);
    let v = vec4 { e: [0.0, 1.0, 2.0, 3.0] };
    let m1 = mat4::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
    let m2 = mat4 {
        c: [v, vec4::new(4.0, 5.0, 6.0, 7.0), vec4::new(8.0, 9.0, 10.0, 11.0), vec4::new(12.0, 13.0, 14.0, 15.0)],
    };
    assert(near_mat(m0, m2, eps));
    assert(near_mat(m1, m2, eps));
    let m3: [mat4; 4] = [m1; 4];
    assert(m3[3] == m1);
    let m4 = mat4 {
        c: [
            vec4::new(1.0, 0.0, 0.0, 0.0),
            vec4::new(0.0, 1.0, 0.0, 0.0),
            vec4::new(0.0, 0.0, 1.0, 0.0),
            vec4::new(0.0, 0.0, 0.0, 1.0),
        ],
    };
    assert((m4[0][0] - 1.0).abs() <= 0.0001);
    assert((m4[3][3] - 1.0).abs() <= 0.0001);
}

@test
fn mat4x4_operators() {
    mat4_operators_of::<f32>();
    mat4_operators_of::<f64>();
}

@test
fn mat4x4_inverse() {
    mat4_inverse_of::<f32>();
    mat4_inverse_of::<f64>();
}

@test
fn mat4x4_size() {
    assert_eq(sizeof(mat4), 64);
    assert_eq(sizeof(dmat4), 128);
    assert_eq(mat4::LEN, 4);
    assert_eq(dmat4::LEN, 4);
}

// Bits of the constructed matrices.

@test
fn mat2x2_ctor_bits() {
    pack_cols::<2, 2>();
}

@test
fn mat2x3_ctor_bits() {
    pack_cols::<2, 3>();
}

@test
fn mat2x4_ctor_bits() {
    pack_cols::<2, 4>();
}

@test
fn mat3x2_ctor_bits() {
    pack_cols::<3, 2>();
}

@test
fn mat3x3_ctor_bits() {
    pack_cols::<3, 3>();
}

@test
fn mat3x4_ctor_bits() {
    pack_cols::<3, 4>();
}

@test
fn mat4x2_ctor_bits() {
    pack_cols::<4, 2>();
}

@test
fn mat4x3_ctor_bits() {
    pack_cols::<4, 3>();
}

@test
fn mat4x4_ctor_bits() {
    pack_cols::<4, 4>();
}

// Column count.

@test
fn mat_length_non_squared() {
    assert_eq(mat2x3::LEN, 2);
    assert_eq(mat2x4::LEN, 2);
    assert_eq(mat3x2::LEN, 3);
    assert_eq(mat3x4::LEN, 3);
    assert_eq(mat4x2::LEN, 4);
    assert_eq(mat4x3::LEN, 4);
    assert_eq(dmat2x3::LEN, 2);
    assert_eq(dmat2x4::LEN, 2);
    assert_eq(dmat3x2::LEN, 3);
    assert_eq(dmat3x4::LEN, 3);
    assert_eq(dmat4x2::LEN, 4);
    assert_eq(dmat4x3::LEN, 4);
}

@test
fn mat_length() {
    assert_eq(mat2::LEN, 2);
    assert_eq(mat3::LEN, 3);
    assert_eq(mat4::LEN, 4);
    assert_eq(mat2x2::LEN, 2);
    assert_eq(mat3x3::LEN, 3);
    assert_eq(mat4x4::LEN, 4);
    assert_eq(dmat2::LEN, 2);
    assert_eq(dmat3::LEN, 3);
    assert_eq(dmat4::LEN, 4);
    assert_eq(dmat2x2::LEN, 2);
    assert_eq(dmat3x3::LEN, 3);
    assert_eq(dmat4x4::LEN, 4);
    assert_eq(mat3::identity().len(), 3);
    assert_eq(dmat4x2::identity().len(), 4);
}

// Matrix functions.

@test
fn func_matrix_comp_mult() {
    let eps = f32::epsilon();
    {
        let m = mat2::new(0.0, 1.0, 2.0, 3.0);
        let n = matrix_comp_mult(m, m);
        assert(near_mat(n, mat2::new(0.0, 1.0, 4.0, 9.0), eps));
    }
    {
        let m = mat2x3::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0);
        let n = matrix_comp_mult(m, m);
        assert(near_mat(n, mat2x3::new(0.0, 1.0, 4.0, 9.0, 16.0, 25.0), eps));
    }
    {
        let m = mat2x4::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0);
        let n = matrix_comp_mult(m, m);
        assert(near_mat(n, mat2x4::new(0.0, 1.0, 4.0, 9.0, 16.0, 25.0, 36.0, 49.0), eps));
    }
    {
        let m = mat3::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
        let n = matrix_comp_mult(m, m);
        assert(near_mat(n, mat3::new(0.0, 1.0, 4.0, 9.0, 16.0, 25.0, 36.0, 49.0, 64.0), eps));
    }
    {
        let m = mat3x2::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0);
        let n = matrix_comp_mult(m, m);
        assert(near_mat(n, mat3x2::new(0.0, 1.0, 4.0, 9.0, 16.0, 25.0), eps));
    }
    {
        let m = mat3x4::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0);
        let n = matrix_comp_mult(m, m);
        let e = mat3x4::new(0.0, 1.0, 4.0, 9.0, 16.0, 25.0, 36.0, 49.0, 64.0, 81.0, 100.0, 121.0);
        assert(near_mat(n, e, eps));
    }
    {
        let m = mat4::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
        let n = matrix_comp_mult(m, m);
        let e = mat4::new(
            0.0,
            1.0,
            4.0,
            9.0,
            16.0,
            25.0,
            36.0,
            49.0,
            64.0,
            81.0,
            100.0,
            121.0,
            144.0,
            169.0,
            196.0,
            225.0,
        );
        assert(near_mat(n, e, eps));
    }
    {
        let m = mat4x2::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0);
        let n = matrix_comp_mult(m, m);
        assert(near_mat(n, mat4x2::new(0.0, 1.0, 4.0, 9.0, 16.0, 25.0, 36.0, 49.0), eps));
    }
    {
        let m = mat4x3::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0);
        let n = matrix_comp_mult(m, m);
        let e = mat4x3::new(0.0, 1.0, 4.0, 9.0, 16.0, 25.0, 36.0, 49.0, 64.0, 81.0, 100.0, 121.0);
        assert(near_mat(n, e, eps));
    }
}

@test
fn func_outer_product() {
    let eps = f32::epsilon();
    let m0: mat2 = outer_product(vec2::splat(1.0), vec2::splat(1.0));
    assert(near_mat(m0, mat2::new(1.0, 1.0, 1.0, 1.0), eps));
    let m1: mat3 = outer_product(vec3::splat(1.0), vec3::splat(1.0));
    assert(near_mat(m1, mat3::from_cols([vec3::splat(1.0); 3]), eps));
    let m2: mat4 = outer_product(vec4::splat(1.0), vec4::splat(1.0));
    assert(near_mat(m2, mat4::from_cols([vec4::splat(1.0); 4]), eps));
    let m3: mat2x3 = outer_product(vec3::splat(1.0), vec2::splat(1.0));
    assert(near_mat(m3, mat2x3::new(1.0, 1.0, 1.0, 1.0, 1.0, 1.0), eps));
    let m4: mat2x4 = outer_product(vec4::splat(1.0), vec2::splat(1.0));
    assert(near_mat(m4, mat2x4::new(1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0), eps));
    let m5: mat3x2 = outer_product(vec2::splat(1.0), vec3::splat(1.0));
    assert(near_mat(m5, mat3x2::new(1.0, 1.0, 1.0, 1.0, 1.0, 1.0), eps));
    let m6: mat3x4 = outer_product(vec4::splat(1.0), vec3::splat(1.0));
    assert(near_mat(m6, mat3x4::from_cols([vec4::splat(1.0); 3]), eps));
    let m7: mat4x2 = outer_product(vec2::splat(1.0), vec4::splat(1.0));
    assert(near_mat(m7, mat4x2::new(1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0), eps));
    let m8: mat4x3 = outer_product(vec3::splat(1.0), vec4::splat(1.0));
    assert(near_mat(m8, mat4x3::from_cols([vec3::splat(1.0); 4]), eps));
    let p: mat3x2 = outer_product(vec2::new(1.0, 2.0), vec3::new(3.0, 4.0, 5.0));
    assert(p == mat3x2::new(3.0, 6.0, 4.0, 8.0, 5.0, 10.0));
}

@test
fn func_transpose() {
    let eps = f32::epsilon();
    {
        let m = mat2::new(0.0, 1.0, 2.0, 3.0);
        let t = transpose(m);
        assert(near_mat(t, mat2::new(0.0, 2.0, 1.0, 3.0), eps));
    }
    {
        let m = mat2x3::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0);
        let t: mat3x2 = transpose(m);
        assert(near_mat(t, mat3x2::new(0.0, 3.0, 1.0, 4.0, 2.0, 5.0), eps));
    }
    {
        let m = mat2x4::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0);
        let t: mat4x2 = transpose(m);
        assert(near_mat(t, mat4x2::new(0.0, 4.0, 1.0, 5.0, 2.0, 6.0, 3.0, 7.0), eps));
    }
    {
        let m = mat3::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
        let t = transpose(m);
        assert(near_mat(t, mat3::new(0.0, 3.0, 6.0, 1.0, 4.0, 7.0, 2.0, 5.0, 8.0), eps));
    }
    {
        let m = mat3x2::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0);
        let t: mat2x3 = transpose(m);
        assert(near_mat(t, mat2x3::new(0.0, 2.0, 4.0, 1.0, 3.0, 5.0), eps));
    }
    {
        let m = mat3x4::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0);
        let t: mat4x3 = transpose(m);
        assert(near_mat(t, mat4x3::new(0.0, 4.0, 8.0, 1.0, 5.0, 9.0, 2.0, 6.0, 10.0, 3.0, 7.0, 11.0), eps));
    }
    {
        let m = mat4::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0);
        let t = transpose(m);
        let e = mat4::new(0.0, 4.0, 8.0, 12.0, 1.0, 5.0, 9.0, 13.0, 2.0, 6.0, 10.0, 14.0, 3.0, 7.0, 11.0, 15.0);
        assert(near_mat(t, e, eps));
    }
    {
        let m = mat4x2::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0);
        let t: mat2x4 = transpose(m);
        assert(near_mat(t, mat2x4::new(0.0, 2.0, 4.0, 6.0, 1.0, 3.0, 5.0, 7.0), eps));
    }
    {
        let m = mat4x3::new(0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0);
        let t: mat3x4 = transpose(m);
        assert(near_mat(t, mat3x4::new(0.0, 3.0, 6.0, 9.0, 1.0, 4.0, 7.0, 10.0, 2.0, 5.0, 8.0, 11.0), eps));
    }
}

@test
fn func_inverse() {
    let eps = f32::epsilon();
    {
        let a = mat4x4::cols(
            vec4::new(1.0, 0.0, 1.0, 0.0),
            vec4::new(0.0, 1.0, 0.0, 0.0),
            vec4::new(0.0, 0.0, 1.0, 0.0),
            vec4::new(0.0, 0.0, 0.0, 1.0),
        );
        let b = inverse(a);
        let i = a * b;
        assert(near_mat(i, mat4x4::identity(), eps));
    }
    {
        let a = mat3x3::cols(vec3::new(1.0, 0.0, 1.0), vec3::new(0.0, 1.0, 0.0), vec3::new(0.0, 0.0, 1.0));
        let b = inverse(a);
        let i = a * b;
        assert(near_mat(i, mat3x3::identity(), eps));
    }
    {
        let a = mat2x2::cols(vec2::new(1.0, 1.0), vec2::new(0.0, 1.0));
        let b = inverse(a);
        let i = a * b;
        assert(near_mat(i, mat2x2::identity(), eps));
    }
}

@test
fn func_inverse_simd() {
    let identity = mat4x4::identity();
    let a = mat4x4::cols(
        vec4::new(1.0, 0.0, 1.0, 0.0),
        vec4::new(0.0, 1.0, 0.0, 0.0),
        vec4::new(0.0, 0.0, 1.0, 0.0),
        vec4::new(0.0, 0.0, 0.0, 1.0),
    );
    let b = inverse(a);
    let i = a * b;
    assert(near_mat(i, identity, 0.001));
}

// Edge cases: determinants, shape conversion, every shape, wrapping, division, indexing, constants.

@test
fn func_determinant() {
    assert(determinant(mat2::new(1.0, 2.0, 3.0, 4.0)) == -2.0);
    assert(determinant(mat3::new(2.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 4.0)) == 24.0);
    assert(determinant(mat3::new(1.0, 2.0, 3.0, 0.0, 1.0, 4.0, 5.0, 6.0, 0.0)) == 1.0);
    assert(
        determinant(mat4::new(1.0, 0.0, 0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 0.0, 4.0)) == 24.0,
    );
    let a = mat4::cols(
        vec4::new(1.0, 0.0, 1.0, 0.0),
        vec4::new(0.0, 1.0, 0.0, 0.0),
        vec4::new(0.0, 0.0, 1.0, 0.0),
        vec4::new(0.0, 0.0, 0.0, 1.0),
    );
    assert(determinant(a) == 1.0);
    let s = mat4::new(1.0, 2.0, 3.0, 4.0, 2.0, 4.0, 6.0, 8.0, 0.0, 1.0, 0.0, 1.0, 1.0, 0.0, 1.0, 0.0);
    assert(determinant(s) == 0.0);
    assert_eq(determinant(imat3::new(1, 2, 3, 0, 1, 4, 5, 6, 0)), 1);
    assert_eq(determinant(imat2::new(3, 1, 4, 2)), 2);
    assert(determinant(dmat4::diagonal(0.5)) == 0.0625);
    let m = mat3::cols(vec3::new(0.6, 0.2, 0.3), vec3::new(0.2, 0.7, 0.5), vec3::new(0.3, 0.5, 0.7));
    assert((determinant(m) * determinant(inverse(m)) - 1.0).abs() <= 0.0001);
    assert(determinant(transpose(m)) == determinant(m));
}

@test
fn mat_from_mat_shapes() {
    // A 4x4 from a 4x2 takes only the first two columns; a 4x4 from a 4x3 takes all four.
    let m42 = mat4x2::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0);
    let r = mat4::from_mat(m42);
    assert(r[0] == vec4::new(1.0, 2.0, 0.0, 0.0));
    assert(r[1] == vec4::new(3.0, 4.0, 0.0, 0.0));
    assert(r[2] == vec4::new(0.0, 0.0, 1.0, 0.0));
    assert(r[3] == vec4::new(0.0, 0.0, 0.0, 1.0));
    let m43 = mat4x3::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0);
    let s = mat4::from_mat(m43);
    assert(s[2] == vec4::new(7.0, 8.0, 9.0, 0.0));
    assert(s[3] == vec4::new(10.0, 11.0, 12.0, 1.0));
    let t = mat3::from_mat(m42);
    assert(t == mat3::new(1.0, 2.0, 0.0, 3.0, 4.0, 0.0, 5.0, 6.0, 1.0));
    let big = mat4::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0);
    assert(mat2::from_mat(big) == mat2::new(1.0, 2.0, 5.0, 6.0));
    assert(mat2x4::from_mat(big) == mat2x4::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0));
    assert(mat3x2::from_mat(big) == mat3x2::new(1.0, 2.0, 5.0, 6.0, 9.0, 10.0));
    let small = mat2::new(1.0, 2.0, 3.0, 4.0);
    assert(mat3x4::from_mat(small) == mat3x4::new(1.0, 2.0, 0.0, 0.0, 3.0, 4.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0));
    assert(mat4x3::from_mat(small) == mat4x3::new(1.0, 2.0, 0.0, 3.0, 4.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0));
}

@test
fn mat_operators_f32_every_shape() {
    check_all_shapes::<f32>();
}

@test
fn mat_operators_f64_every_shape() {
    check_all_shapes::<f64>();
}

@test
fn mat_operators_i32_every_shape() {
    check_all_shapes::<i32>();
}

@test
fn mat_operators_u8_wrap() {
    let a = u8mat2::new(200, 1, 2, 255);
    assert(a + u8mat2::new(100, 1, 1, 1) == u8mat2::new(44, 2, 3, 0));
    assert(u8mat2::diagonal(16) * u8mat2::diagonal(16) == u8mat2::diagonal(0));
    assert(-u8mat2::diagonal(1) == u8mat2::new(255, 0, 0, 255));
    assert(i16mat2::diagonal(256) * 128i16 == i16mat2::diagonal(-32768));
}

@test
fn mat_division() {
    // m / n is m * inverse(n), m / v is inverse(m) * v and v / m is v * inverse(m).
    let m2 = mat2::new(4.0, 1.0, 2.0, 3.0);
    let n2 = mat2::new(1.0, 2.0, 3.0, 5.0);
    let v2 = vec2::new(1.0, 2.0);
    assert(m2 / n2 == m2 * inverse(n2));
    assert(m2 / v2 == inverse(m2) * v2);
    assert(v2 / m2 == v2 * inverse(m2));
    assert(near_mat(m2 / m2, mat2::identity(), 0.001));
    let m3 = mat3::new(2.0, 0.0, 1.0, 1.0, 3.0, 0.0, 0.0, 1.0, 4.0);
    let n3 = transpose(m3);
    let v3 = vec3::new(1.0, 2.0, 3.0);
    assert(m3 / n3 == m3 * inverse(n3));
    assert(m3 / v3 == inverse(m3) * v3);
    assert(v3 / m3 == v3 * inverse(m3));
    assert(near_mat(m3 / m3, mat3::identity(), 0.001));
    let m4 = mat4::new(4.0, 1.0, 0.0, 0.0, 1.0, 3.0, 1.0, 0.0, 0.0, 1.0, 2.0, 1.0, 1.0, 0.0, 0.0, 5.0);
    let n4 = transpose(m4);
    let v4 = vec4::new(1.0, 2.0, 3.0, 4.0);
    assert(m4 / n4 == m4 * inverse(n4));
    assert(m4 / v4 == inverse(m4) * v4);
    assert(v4 / m4 == v4 * inverse(m4));
    assert(near_mat(m4 / m4, mat4::identity(), 0.001));
    let d4 = dmat4::diagonal(2.0) + dmat4::new(
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
        1.0,
        0.0,
        0.0,
        0.0,
    );
    let e4 = d4 * 2.0;
    let w4 = dvec4::new(1.0, 2.0, 3.0, 4.0);
    assert(d4 / e4 == d4 * inverse(e4));
    assert(d4 / w4 == inverse(d4) * w4);
    assert(w4 / d4 == w4 * inverse(d4));
    assert(near_mat(d4 / d4, dmat4::identity(), 0.001));
}

@test
fn mat_inverse_exact() {
    assert(inverse(mat2::new(4.0, 0.0, 0.0, 2.0)) == mat2::new(0.25, 0.0, 0.0, 0.5));
    assert(inverse(mat3::diagonal(2.0)) == mat3::diagonal(0.5));
    assert(inverse(dmat4::diagonal(4.0)) == dmat4::diagonal(0.25));
    let s = inverse(mat2::new(1.0, 2.0, 2.0, 4.0));
    assert(s[0][0].is_inf() || s[0][0].is_nan());
}

@test
fn mat_cast_and_constructors() {
    assert(imat2::new(1, -2, 3, 4).cast::<f32>() == mat2::new(1.0, -2.0, 3.0, 4.0));
    assert(dmat3::diagonal(1.5).cast::<f32>() == mat3::diagonal(1.5));
    assert(mat2x3::new(1.9, -1.9, 0.5, 2.0, 3.0, 4.0).cast::<i32>() == imat2x3::new(1, -1, 0, 2, 3, 4));
    assert(mat3x2::zero() == mat3x2::diagonal(0.0));
    assert(mat2x4::identity() == mat2x4::new(1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0));
    assert(mat4x2::identity() == mat4x2::new(1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0));
    assert(mat3::cols(vec3::splat(1.0), vec3::splat(2.0), vec3::splat(3.0))[2] == vec3::splat(3.0));
    assert(mat3x4::from_cols([vec4::splat(7.0); 3])[1][3] == 7.0);
}

@test
fn mat_float_equality_is_ieee() {
    let mut m = mat2::identity();
    assert(m == mat2::identity());
    m[1][0] = -0.0;
    assert(m == mat2::identity());
    m[0][1] = f32::nan();
    assert(m != m);
    assert(!(m == m));
}

@test
fn mat_index() {
    let mut m = mat3x2::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0);
    assert(m[0] == vec2::new(1.0, 2.0));
    assert(m[2][1] == 6.0);
    m[1][0] = 9.0;
    m[2] = vec2::new(7.0, 8.0);
    assert(m == mat3x2::new(1.0, 2.0, 9.0, 4.0, 7.0, 8.0));
    let cols = m[1..3];
    assert_eq(cols.len(), 2);
    assert(cols[1] == vec2::new(7.0, 8.0));
    let w = &mut m[0..1];
    w[0] = vec2::splat(0.0);
    assert(m[0] == vec2::splat(0.0));
}

@test(should_panic)
fn mat_index_out_of_range_traps() {
    let m = mat2x3::identity();
    let i = mat2x3::LEN;
    let _ = m[i];
}

@test(should_panic)
fn mat_index_row_out_of_range_traps() {
    let m = mat3x2::identity();
    let j = vec2::LEN;
    let _ = m[0][j];
}

@test(should_panic)
fn mat_index_mut_out_of_range_traps() {
    let mut m = mat4::identity();
    let i = mat4::LEN;
    m[i] = vec4::splat(1.0);
}

@test
fn mat_const_initializers() {
    assert(M2 == mat4::diagonal(2.0));
    assert(T23 == mat3x2::new(0.0, 3.0, 1.0, 4.0, 2.0, 5.0));
    assert(DET == -2.0);
    assert(INV == mat2::new(0.25, 0.0, 0.0, 0.5));
    assert(OUTER == mat3x2::new(3.0, 6.0, 4.0, 8.0, 5.0, 10.0));
    assert(IM == imat3::diagonal(3));
    assert(PROD == mat2::new(1.0, 2.0, 9.0, 12.0));
    assert(FROM[1] == vec4::new(3.0, 4.0, 0.0, 0.0));
    assert(FROM[3] == vec4::new(0.0, 0.0, 0.0, 1.0));
}

// Adjugate.

@test
fn mat_adjugate() {
    let eps = epsilon::<f32>();
    let m2 = mat2::new(2.0, 3.0, 1.0, 5.0);
    let eam2 = mat2::new(5.0, -3.0, -1.0, 2.0);
    let am2 = adjugate(m2);
    assert(all(epsilon_equal(am2[0], eam2[0], eps)) && all(epsilon_equal(am2[1], eam2[1], eps)));
    let m3 = mat3::new(2.0, 3.0, 3.0, 1.0, 5.0, 4.0, 4.0, 6.0, 8.0);
    let eam3 = mat3::new(16.0, -6.0, -3.0, 8.0, 4.0, -5.0, -14.0, 0.0, 7.0);
    let am3 = adjugate(m3);
    for i in 0..mat3::LEN {
        assert(all(epsilon_equal(am3[i], eam3[i], eps)));
    }
    let m4 = mat4::new(2.0, 3.0, 3.0, 1.0, 1.0, 5.0, 4.0, 3.0, 4.0, 6.0, 8.0, 5.0, -2.0, -3.0, -3.0, 4.0);
    let eam4 = mat4::new(
        97.0,
        -30.0,
        -15.0,
        17.0,
        45.0,
        20.0,
        -25.0,
        5.0,
        -91.0,
        0.0,
        35.0,
        -21.0,
        14.0,
        0.0,
        0.0,
        14.0,
    );
    let am4 = adjugate(m4);
    for i in 0..mat4::LEN {
        assert(all(epsilon_equal(am4[i], eam4[i], eps)));
    }
}

// Diagonal builders and adjugate edge cases.

@test
fn mat_diagonal_every_shape() {
    let v2 = vec2::new(2.0, 3.0);
    let v3 = vec3::new(2.0, 3.0, 4.0);
    assert(diagonal2x2(v2) == mat2x2::new(2.0, 0.0, 0.0, 3.0));
    assert(diagonal2x3(v2) == mat2x3::new(2.0, 0.0, 0.0, 0.0, 3.0, 0.0));
    assert(diagonal2x4(v2) == mat2x4::new(2.0, 0.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0));
    assert(diagonal3x2(v2) == mat3x2::new(2.0, 0.0, 0.0, 3.0, 0.0, 0.0));
    assert(diagonal3x3(v3) == mat3x3::new(2.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 4.0));
    assert(diagonal3x4(v3) == mat3x4::new(2.0, 0.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 0.0, 4.0, 0.0));
    assert(diagonal4x2(v2) == mat4x2::new(2.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 0.0));
    assert(diagonal4x3(v3) == mat4x3::new(2.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 4.0, 0.0, 0.0, 0.0));
    assert(
        diagonal4x4(vec4::new(2.0, 3.0, 4.0, 5.0)) == mat4::diagonal(1.0) * diagonal4x4(vec4::new(2.0, 3.0, 4.0, 5.0)),
    );
    assert(diagonal4x4(vec4::new(2.0, 3.0, 4.0, 5.0))[3][3] == 5.0);
    // The rest of the diagonal past the vector stays 1: the builders start from the identity.
    assert(diagonal3x3(vec3::splat(0.0)) == mat3::zero());
    assert(diagonal2x2(ivec2::new(-1, 7)) == imat2::new(-1, 0, 0, 7));
    assert(diagonal4x4(u8vec4::new(1, 2, 3, 255)) == u8mat4::new(1, 0, 0, 0, 0, 2, 0, 0, 0, 0, 3, 0, 0, 0, 0, 255));
}

@test
fn mat_adjugate_is_determinant_times_inverse() {
    let m = dmat4::new(2.0, 3.0, 3.0, 1.0, 1.0, 5.0, 4.0, 3.0, 4.0, 6.0, 8.0, 5.0, -2.0, -3.0, -3.0, 4.0);
    let expected = inverse(m) * determinant(m);
    let a = adjugate(m);
    for i in 0..dmat4::LEN {
        assert(all(epsilon_equal(a[i], expected[i], 1e-12f64)));
    }
    let m3 = dmat3::new(2.0, 3.0, 3.0, 1.0, 5.0, 4.0, 4.0, 6.0, 8.0);
    assert(adjugate(m3) * m3 == dmat3::identity() * determinant(m3));
}

@test
fn mat_adjugate_of_integers() {
    assert(adjugate(imat2::new(2, 3, 1, 5)) == imat2::new(5, -3, -1, 2));
    assert(adjugate(imat3::new(2, 3, 3, 1, 5, 4, 4, 6, 8)) == imat3::new(16, -6, -3, 8, 4, -5, -14, 0, 7));
    let m4 = imat4::new(2, 3, 3, 1, 1, 5, 4, 3, 4, 6, 8, 5, -2, -3, -3, 4);
    assert(adjugate(m4) == imat4::new(97, -30, -15, 17, 45, 20, -25, 5, -91, 0, 35, -21, 14, 0, 0, 14));
    // An unsigned matrix negates modulo 2^N.
    assert(adjugate(u8mat2::new(2, 3, 1, 5)) == u8mat2::new(5, 253, 255, 2));
    assert(adjugate(i8mat2::new(-128, 0, 0, 1)) == i8mat2::new(1, 0, 0, -128));
}

@test
fn mat_diagonal_adjugate_const_initializers() {
    assert(DIAG == mat4x3::new(2.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 4.0, 0.0, 0.0, 0.0));
    assert(ADJ == imat2::new(5, -3, -1, 2));
    assert(ADJ3 == imat3::new(16, -6, -3, 8, 4, -5, -14, 0, 7));
    assert(ADJ4 == imat4::new(97, -30, -15, 17, 45, 20, -25, 5, -91, 0, 35, -21, 14, 0, 0, 14));
}

// Constant inverses equal the same calls at run time, element for element.
@test
fn inverse_const_initializers() {
    let m3 = dmat3::new(2.0, 3.0, 3.0, 1.0, 5.0, 4.0, 4.0, 6.0, 8.0);
    let m4 = mat4::new(2.0, 0.0, 0.0, 0.0, 0.0, 4.0, 0.0, 0.0, 0.0, 0.0, 8.0, 0.0, 1.0, 2.0, 3.0, 1.0);
    assert(INV3 == inverse(m3));
    assert(INV4 == inverse(m4));
    assert(AFF3 == affine_inverse(mat3::new(2.0, 0.0, 0.0, 0.0, 4.0, 0.0, 1.0, 2.0, 1.0)));
    assert(AFF4 == affine_inverse(m4));
    assert(INV4 == mat4::new(0.5, 0.0, 0.0, 0.0, 0.0, 0.25, 0.0, 0.0, 0.0, 0.0, 0.125, 0.0, -0.5, -0.5, -0.375, 1.0));
}
