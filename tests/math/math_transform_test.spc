// std::math::transform and the matrix access and inverse functions of std::math::mat: translate, scale,
// rotate and shear, row and column get and set of every matrix shape, affine_inverse, decompose and
// recompose, axis_angle and the vector rotations, then the `_slow` forms, look_at, inverse_transpose,
// the transform builders, the 2D transforms, the decompose and axis_angle branches, index traps and
// constant initializers.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::quat as *;
import std::math::geometric as *;
import std::math::elementary as *;
import std::math::transform as *;

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

// Every component of `a` strictly within `eps` of `b`.
fn eps_near<T: Float, const N: usize>(a: Vec<T, N>, b: Vec<T, N>, eps: T) bool {
    for i in 0..N {
        if !(a[i] - b[i]).abs().less(eps) {
            return false;
        }
    }
    return true;
}

// Every column of `a` has an element farther than `eps` from `b`'s.
fn all_cols_differ<T: Float, const C: usize, const R: usize>(a: Mat<T, C, R>, b: Mat<T, C, R>, eps: T) bool {
    for i in 0..C {
        if near(a[i], b[i], eps) {
            return false;
        }
    }
    return true;
}

const TRANSLATED: mat4 = translate(mat4::identity(), vec3::new(1.0, 2.0, 3.0));
const SCALED: dmat4 = scale(dmat4::identity(), dvec3::new(2.0, 3.0, 4.0));
const ROW1: vec3 = row(mat3::new(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0), 1);
const TM: mat4 = translate_matrix(vec3::new(1.0, 2.0, 3.0));
const RM: dmat4 = rotate_matrix(0.5f64, dvec3::new(0.0, 0.0, 1.0));
const SM: imat4 = scale_matrix(ivec3::new(2, 3, 4));
const T2: mat3 = translate(mat3::identity(), vec2::new(1.0, 2.0));
const R2: mat3 = rotate_2d(mat3::identity(), 0.25f32);
const SX: mat3 = shear_x(mat3::identity(), 2.0f32);
const AAM: mat4 = axis_angle_matrix(vec3::new(0.0, 1.0, 0.0), 0.5f32);
const RV: vec3 = rotate_x(vec3::new(0.0, 1.0, 0.0), 0.5f32);
const REC: mat4 = recompose(
    vec3::splat(2.0),
    Quat::<f32>::identity(),
    vec3::new(1.0, 2.0, 3.0),
    vec3::zero(),
    vec4::new(0.0, 0.0, 0.0, 1.0),
);

@test
fn translate_identity() {
    let t = translate(mat4::identity(), vec3::splat(1.0));
    assert(near(t[3], vec4::splat(1.0), epsilon::<f32>()));
}

@test
fn scale_identity() {
    let s = scale(mat4::identity(), vec3::splat(2.0));
    let r = mat4::cols(
        vec4::new(2.0, 0.0, 0.0, 0.0),
        vec4::new(0.0, 2.0, 0.0, 0.0),
        vec4::new(0.0, 0.0, 2.0, 0.0),
        vec4::new(0.0, 0.0, 0.0, 1.0),
    );
    assert(near_mat(s, r, epsilon::<f32>()));
}

@test
fn rotate_quarter_turn() {
    let a = vec4::new(1.0, 0.0, 0.0, 1.0);
    let r = rotate(mat4::identity(), radians(90.0f32), vec3::new(0.0, 0.0, 1.0));
    let b = r * a;
    assert(near(b, vec4::new(0.0, 1.0, 0.0, 1.0), 0.0001));
}

@test
fn translate_zero_matrix() {
    let t = translate(mat4::zero(), vec3::splat(1.0));
    assert(all_cols_differ(t, mat4::identity(), 0.001));
}

@test
fn shearing() {
    {
        let center = vec3::new(0.0, 0.0, 0.0);
        let l_x = vec2::new(2.0, 0.0);
        let l_y = vec2::new(0.0, 0.0);
        let l_z = vec2::new(0.0, 0.0);
        let a = mat4::cols(
            vec4::new(0.0, 0.0, 1.0, 1.0),
            vec4::new(0.0, 1.0, 1.0, 0.0),
            vec4::new(1.0, 1.0, 1.0, 0.0),
            vec4::new(1.0, 1.0, 0.0, 1.0),
        );
        let expected = mat4::cols(
            vec4::new(0.0, 0.0, 1.0, 1.0),
            vec4::new(0.0, 1.0, 3.0, 2.0),
            vec4::new(1.0, 1.0, 1.0, 0.0),
            vec4::new(1.0, 1.0, 0.0, 1.0),
        );
        assert(near_mat(shear(a, center, l_x, l_y, l_z), expected, epsilon::<f32>()));
        assert(near_mat(shear_slow(a, center, l_x, l_y, l_z), expected, epsilon::<f32>()));
    }
    {
        let center = vec3::new(0.0, 0.0, 0.0);
        let l_x = vec2::new(1.0, 0.0);
        let l_y = vec2::new(0.0, 1.0);
        let l_z = vec2::new(1.0, 0.0);
        let a = mat4::cols(
            vec4::new(0.0, 0.0, 1.0, 0.0),
            vec4::new(0.0, 1.0, 1.0, 0.0),
            vec4::new(1.0, 1.0, 1.0, 0.0),
            vec4::new(1.0, 0.0, 0.0, 0.0),
        );
        let expected = mat4::cols(
            vec4::new(1.0, 1.0, 2.0, 0.0),
            vec4::new(0.0, 1.0, 2.0, 0.0),
            vec4::new(1.0, 2.0, 2.0, 0.0),
            vec4::new(1.0, 0.0, 0.0, 0.0),
        );
        assert(near_mat(shear(a, center, l_x, l_y, l_z), expected, epsilon::<f32>()));
        assert(near_mat(shear_slow(a, center, l_x, l_y, l_z), expected, epsilon::<f32>()));
    }
    {
        let center = vec3::new(3.0, 2.0, 1.0);
        let l_x = vec2::new(1.0, 2.0);
        let l_y = vec2::new(3.0, 1.0);
        let l_z = vec2::new(4.0, 5.0);
        let a = mat4::identity();
        let expected = mat4::cols(
            vec4::new(1.0, 3.0, 4.0, 0.0),
            vec4::new(1.0, 1.0, 5.0, 0.0),
            vec4::new(2.0, 1.0, 1.0, 0.0),
            vec4::new(-9.0, -8.0, -9.0, 1.0),
        );
        assert(near_mat(shear(a, center, l_x, l_y, l_z), expected, epsilon::<f32>()));
        assert(near_mat(shear_slow(a, center, l_x, l_y, l_z), expected, epsilon::<f32>()));
    }
}

@test
fn mat2x2_row_set() {
    let mut m = mat2x2::identity();
    m = set_row(m, 0, vec2::new(0.0, 1.0));
    m = set_row(m, 1, vec2::new(4.0, 5.0));
    assert(near(row(m, 0), vec2::new(0.0, 1.0), epsilon::<f32>()));
    assert(near(row(m, 1), vec2::new(4.0, 5.0), epsilon::<f32>()));
}

@test
fn mat2x2_col_set() {
    let mut m = mat2x2::identity();
    m = set_column(m, 0, vec2::new(0.0, 1.0));
    m = set_column(m, 1, vec2::new(4.0, 5.0));
    assert(near(column(m, 0), vec2::new(0.0, 1.0), epsilon::<f32>()));
    assert(near(column(m, 1), vec2::new(4.0, 5.0), epsilon::<f32>()));
}

@test
fn mat2x3_row_set() {
    let mut m = mat2x3::identity();
    m = set_row(m, 0, vec2::new(0.0, 1.0));
    m = set_row(m, 1, vec2::new(4.0, 5.0));
    m = set_row(m, 2, vec2::new(8.0, 9.0));
    assert(near(row(m, 0), vec2::new(0.0, 1.0), epsilon::<f32>()));
    assert(near(row(m, 1), vec2::new(4.0, 5.0), epsilon::<f32>()));
    assert(near(row(m, 2), vec2::new(8.0, 9.0), epsilon::<f32>()));
}

@test
fn mat2x3_col_set() {
    let mut m = mat2x3::identity();
    m = set_column(m, 0, vec3::new(0.0, 1.0, 2.0));
    m = set_column(m, 1, vec3::new(4.0, 5.0, 6.0));
    assert(near(column(m, 0), vec3::new(0.0, 1.0, 2.0), epsilon::<f32>()));
    assert(near(column(m, 1), vec3::new(4.0, 5.0, 6.0), epsilon::<f32>()));
}

@test
fn mat2x4_row_set() {
    let mut m = mat2x4::identity();
    m = set_row(m, 0, vec2::new(0.0, 1.0));
    m = set_row(m, 1, vec2::new(4.0, 5.0));
    m = set_row(m, 2, vec2::new(8.0, 9.0));
    m = set_row(m, 3, vec2::new(12.0, 13.0));
    assert(near(row(m, 0), vec2::new(0.0, 1.0), epsilon::<f32>()));
    assert(near(row(m, 1), vec2::new(4.0, 5.0), epsilon::<f32>()));
    assert(near(row(m, 2), vec2::new(8.0, 9.0), epsilon::<f32>()));
    assert(near(row(m, 3), vec2::new(12.0, 13.0), epsilon::<f32>()));
}

@test
fn mat2x4_col_set() {
    let mut m = mat2x4::identity();
    m = set_column(m, 0, vec4::new(0.0, 1.0, 2.0, 3.0));
    m = set_column(m, 1, vec4::new(4.0, 5.0, 6.0, 7.0));
    assert(near(column(m, 0), vec4::new(0.0, 1.0, 2.0, 3.0), epsilon::<f32>()));
    assert(near(column(m, 1), vec4::new(4.0, 5.0, 6.0, 7.0), epsilon::<f32>()));
}

@test
fn mat3x2_row_set() {
    let mut m = mat3x2::identity();
    m = set_row(m, 0, vec3::new(0.0, 1.0, 2.0));
    m = set_row(m, 1, vec3::new(4.0, 5.0, 6.0));
    assert(near(row(m, 0), vec3::new(0.0, 1.0, 2.0), epsilon::<f32>()));
    assert(near(row(m, 1), vec3::new(4.0, 5.0, 6.0), epsilon::<f32>()));
}

@test
fn mat3x2_col_set() {
    let mut m = mat3x2::identity();
    m = set_column(m, 0, vec2::new(0.0, 1.0));
    m = set_column(m, 1, vec2::new(4.0, 5.0));
    m = set_column(m, 2, vec2::new(8.0, 9.0));
    assert(near(column(m, 0), vec2::new(0.0, 1.0), epsilon::<f32>()));
    assert(near(column(m, 1), vec2::new(4.0, 5.0), epsilon::<f32>()));
    assert(near(column(m, 2), vec2::new(8.0, 9.0), epsilon::<f32>()));
}

@test
fn mat3x3_row_set() {
    let mut m = mat3x3::identity();
    m = set_row(m, 0, vec3::new(0.0, 1.0, 2.0));
    m = set_row(m, 1, vec3::new(4.0, 5.0, 6.0));
    m = set_row(m, 2, vec3::new(8.0, 9.0, 10.0));
    assert(near(row(m, 0), vec3::new(0.0, 1.0, 2.0), epsilon::<f32>()));
    assert(near(row(m, 1), vec3::new(4.0, 5.0, 6.0), epsilon::<f32>()));
    assert(near(row(m, 2), vec3::new(8.0, 9.0, 10.0), epsilon::<f32>()));
}

@test
fn mat3x3_col_set() {
    let mut m = mat3x3::identity();
    m = set_column(m, 0, vec3::new(0.0, 1.0, 2.0));
    m = set_column(m, 1, vec3::new(4.0, 5.0, 6.0));
    m = set_column(m, 2, vec3::new(8.0, 9.0, 10.0));
    assert(near(column(m, 0), vec3::new(0.0, 1.0, 2.0), epsilon::<f32>()));
    assert(near(column(m, 1), vec3::new(4.0, 5.0, 6.0), epsilon::<f32>()));
    assert(near(column(m, 2), vec3::new(8.0, 9.0, 10.0), epsilon::<f32>()));
}

@test
fn mat3x4_row_set() {
    let mut m = mat3x4::identity();
    m = set_row(m, 0, vec3::new(0.0, 1.0, 2.0));
    m = set_row(m, 1, vec3::new(4.0, 5.0, 6.0));
    m = set_row(m, 2, vec3::new(8.0, 9.0, 10.0));
    m = set_row(m, 3, vec3::new(12.0, 13.0, 14.0));
    assert(near(row(m, 0), vec3::new(0.0, 1.0, 2.0), epsilon::<f32>()));
    assert(near(row(m, 1), vec3::new(4.0, 5.0, 6.0), epsilon::<f32>()));
    assert(near(row(m, 2), vec3::new(8.0, 9.0, 10.0), epsilon::<f32>()));
    assert(near(row(m, 3), vec3::new(12.0, 13.0, 14.0), epsilon::<f32>()));
}

@test
fn mat3x4_col_set() {
    let mut m = mat3x4::identity();
    m = set_column(m, 0, vec4::new(0.0, 1.0, 2.0, 3.0));
    m = set_column(m, 1, vec4::new(4.0, 5.0, 6.0, 7.0));
    m = set_column(m, 2, vec4::new(8.0, 9.0, 10.0, 11.0));
    assert(near(column(m, 0), vec4::new(0.0, 1.0, 2.0, 3.0), epsilon::<f32>()));
    assert(near(column(m, 1), vec4::new(4.0, 5.0, 6.0, 7.0), epsilon::<f32>()));
    assert(near(column(m, 2), vec4::new(8.0, 9.0, 10.0, 11.0), epsilon::<f32>()));
}

@test
fn mat4x2_row_set() {
    let mut m = mat4x2::identity();
    m = set_row(m, 0, vec4::new(0.0, 1.0, 2.0, 3.0));
    m = set_row(m, 1, vec4::new(4.0, 5.0, 6.0, 7.0));
    assert(near(row(m, 0), vec4::new(0.0, 1.0, 2.0, 3.0), epsilon::<f32>()));
    assert(near(row(m, 1), vec4::new(4.0, 5.0, 6.0, 7.0), epsilon::<f32>()));
}

@test
fn mat4x2_col_set() {
    let mut m = mat4x2::identity();
    m = set_column(m, 0, vec2::new(0.0, 1.0));
    m = set_column(m, 1, vec2::new(4.0, 5.0));
    m = set_column(m, 2, vec2::new(8.0, 9.0));
    m = set_column(m, 3, vec2::new(12.0, 13.0));
    assert(near(column(m, 0), vec2::new(0.0, 1.0), epsilon::<f32>()));
    assert(near(column(m, 1), vec2::new(4.0, 5.0), epsilon::<f32>()));
    assert(near(column(m, 2), vec2::new(8.0, 9.0), epsilon::<f32>()));
    assert(near(column(m, 3), vec2::new(12.0, 13.0), epsilon::<f32>()));
}

@test
fn mat4x3_row_set() {
    let mut m = mat4x3::identity();
    m = set_row(m, 0, vec4::new(0.0, 1.0, 2.0, 3.0));
    m = set_row(m, 1, vec4::new(4.0, 5.0, 6.0, 7.0));
    m = set_row(m, 2, vec4::new(8.0, 9.0, 10.0, 11.0));
    assert(near(row(m, 0), vec4::new(0.0, 1.0, 2.0, 3.0), epsilon::<f32>()));
    assert(near(row(m, 1), vec4::new(4.0, 5.0, 6.0, 7.0), epsilon::<f32>()));
    assert(near(row(m, 2), vec4::new(8.0, 9.0, 10.0, 11.0), epsilon::<f32>()));
}

@test
fn mat4x3_col_set() {
    let mut m = mat4x3::identity();
    m = set_column(m, 0, vec3::new(0.0, 1.0, 2.0));
    m = set_column(m, 1, vec3::new(4.0, 5.0, 6.0));
    m = set_column(m, 2, vec3::new(8.0, 9.0, 10.0));
    m = set_column(m, 3, vec3::new(12.0, 13.0, 14.0));
    assert(near(column(m, 0), vec3::new(0.0, 1.0, 2.0), epsilon::<f32>()));
    assert(near(column(m, 1), vec3::new(4.0, 5.0, 6.0), epsilon::<f32>()));
    assert(near(column(m, 2), vec3::new(8.0, 9.0, 10.0), epsilon::<f32>()));
    assert(near(column(m, 3), vec3::new(12.0, 13.0, 14.0), epsilon::<f32>()));
}

@test
fn mat4x4_row_set() {
    let mut m = mat4::identity();
    m = set_row(m, 0, vec4::new(0.0, 1.0, 2.0, 3.0));
    m = set_row(m, 1, vec4::new(4.0, 5.0, 6.0, 7.0));
    m = set_row(m, 2, vec4::new(8.0, 9.0, 10.0, 11.0));
    m = set_row(m, 3, vec4::new(12.0, 13.0, 14.0, 15.0));
    assert(near(row(m, 0), vec4::new(0.0, 1.0, 2.0, 3.0), epsilon::<f32>()));
    assert(near(row(m, 1), vec4::new(4.0, 5.0, 6.0, 7.0), epsilon::<f32>()));
    assert(near(row(m, 2), vec4::new(8.0, 9.0, 10.0, 11.0), epsilon::<f32>()));
    assert(near(row(m, 3), vec4::new(12.0, 13.0, 14.0, 15.0), epsilon::<f32>()));
}

@test
fn mat4x4_col_set() {
    let mut m = mat4::identity();
    m = set_column(m, 0, vec4::new(0.0, 1.0, 2.0, 3.0));
    m = set_column(m, 1, vec4::new(4.0, 5.0, 6.0, 7.0));
    m = set_column(m, 2, vec4::new(8.0, 9.0, 10.0, 11.0));
    m = set_column(m, 3, vec4::new(12.0, 13.0, 14.0, 15.0));
    assert(near(column(m, 0), vec4::new(0.0, 1.0, 2.0, 3.0), epsilon::<f32>()));
    assert(near(column(m, 1), vec4::new(4.0, 5.0, 6.0, 7.0), epsilon::<f32>()));
    assert(near(column(m, 2), vec4::new(8.0, 9.0, 10.0, 11.0), epsilon::<f32>()));
    assert(near(column(m, 3), vec4::new(12.0, 13.0, 14.0, 15.0), epsilon::<f32>()));
}

@test
fn mat4x4_row_get() {
    let m = mat4::identity();
    assert(near(row(m, 0), vec4::new(1.0, 0.0, 0.0, 0.0), epsilon::<f32>()));
    assert(near(row(m, 1), vec4::new(0.0, 1.0, 0.0, 0.0), epsilon::<f32>()));
    assert(near(row(m, 2), vec4::new(0.0, 0.0, 1.0, 0.0), epsilon::<f32>()));
    assert(near(row(m, 3), vec4::new(0.0, 0.0, 0.0, 1.0), epsilon::<f32>()));
}

@test
fn mat4x4_col_get() {
    let m = mat4::identity();
    assert(near(column(m, 0), vec4::new(1.0, 0.0, 0.0, 0.0), epsilon::<f32>()));
    assert(near(column(m, 1), vec4::new(0.0, 1.0, 0.0, 0.0), epsilon::<f32>()));
    assert(near(column(m, 2), vec4::new(0.0, 0.0, 1.0, 0.0), epsilon::<f32>()));
    assert(near(column(m, 3), vec4::new(0.0, 0.0, 0.0, 1.0), epsilon::<f32>()));
}

@test
fn affine() {
    {
        let m = mat3::new(2.0, 0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 1.0);
        let a = affine_inverse(m);
        let i = inverse(m);
        let r = affine_inverse(a);
        for k in 0..mat3::LEN {
            assert(eps_near(m[k], r[k], 0.01));
            assert(eps_near(a[k], i[k], 0.01));
        }
    }
    {
        let m = mat4::new(2.0, 0.0, 0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 0.0, 2.0, 0.0, 0.0, 0.0, 0.0, 1.0);
        let a = affine_inverse(m);
        let i = inverse(m);
        let r = affine_inverse(a);
        for k in 0..mat4::LEN {
            assert(eps_near(m[k], r[k], 0.01));
            assert(eps_near(a[k], i[k], 0.01));
        }
    }
}

@test
fn affine_inverse_of_translation() {
    let m = translate(rotate(dmat4::identity(), 0.5, dvec3::new(1.0, 2.0, 3.0)), dvec3::new(4.0, -5.0, 6.0));
    assert(near_mat(affine_inverse(m) * m, dmat4::identity(), 1e-12));
    let m3 = dmat3::new(0.0, 1.0, 0.0, -1.0, 0.0, 0.0, 3.0, 4.0, 1.0);
    assert(affine_inverse(m3) == dmat3::new(0.0, -1.0, 0.0, 1.0, 0.0, 0.0, -4.0, 3.0, 1.0));
}

@test
fn inverse_transpose_shapes() {
    let m3 = dmat3::new(2.0, 1.0, 0.0, 0.0, 3.0, 1.0, 1.0, 0.0, 4.0);
    assert(near_mat(inverse_transpose(m3), transpose(inverse(m3)), 1e-15));
    let m4 = dmat4::new(2.0, 1.0, 0.0, 0.0, 0.0, 3.0, 1.0, 0.0, 1.0, 0.0, 4.0, 1.0, 0.0, 1.0, 0.0, 5.0);
    assert(near_mat(inverse_transpose(m4), transpose(inverse(m4)), 1e-15));
    // The 2x2 form returns the inverse, not its transpose.
    let m2 = dmat2::new(4.0, 1.0, 2.0, 3.0);
    assert(near_mat(inverse_transpose(m2), inverse(m2), 1e-15));
}

@test
fn slow_forms_match() {
    let m = mat4::new(1.0, 2.0, 0.0, 0.0, 0.0, 1.0, 3.0, 0.0, 0.5, 0.0, 1.0, 0.0, 4.0, 5.0, 6.0, 1.0);
    let axis = vec3::new(1.0, -2.0, 0.5);
    assert(near_mat(rotate_slow(m, 0.7, axis), rotate(m, 0.7, axis), 1e-5));
    let v = vec3::new(2.0, -3.0, 0.25);
    assert(scale_slow(m, v) == scale(m, v));
}

@test
fn look_at_frames() {
    let eye = dvec3::new(1.0, 2.0, 3.0);
    let target = dvec3::new(1.0, 2.0, 0.0);
    let up = dvec3::new(0.0, 1.0, 0.0);
    let rh = look_at_rh(eye, target, up);
    assert(near_mat(rh, translate(dmat4::identity(), -eye), 1e-15));
    assert(look_at(eye, target, up) == rh);
    // A left-handed camera looks down +z of its own frame: the target lands at positive z.
    let p = look_at_lh(eye, target, up) * target.append(1.0);
    assert(near(p, dvec4::new(0.0, 0.0, 3.0, 1.0), 1e-15));
}

@test(should_panic)
fn row_index_out_of_range_traps() {
    let i = vec2::LEN;
    let _ = row(mat3x2::identity(), i);
}

@test(should_panic)
fn set_row_index_out_of_range_traps() {
    let i = vec2::LEN;
    let _ = set_row(mat3x2::identity(), i, vec3::splat(1.0));
}

@test(should_panic)
fn column_index_out_of_range_traps() {
    let i = mat3x2::LEN;
    let _ = column(mat3x2::identity(), i);
}

@test(should_panic)
fn set_column_index_out_of_range_traps() {
    let i = mat3x2::LEN;
    let _ = set_column(mat3x2::identity(), i, vec2::splat(1.0));
}

@test
fn const_initializers() {
    assert(TRANSLATED == translate(mat4::identity(), vec3::new(1.0, 2.0, 3.0)));
    assert(TRANSLATED[3] == vec4::new(1.0, 2.0, 3.0, 1.0));
    assert(SCALED == dmat4::new(2.0, 0.0, 0.0, 0.0, 0.0, 3.0, 0.0, 0.0, 0.0, 0.0, 4.0, 0.0, 0.0, 0.0, 0.0, 1.0));
    assert(ROW1 == vec3::new(2.0, 5.0, 8.0));
}

@test
fn decompose_identity() {
    let m = mat4::identity();
    let (ok, scale, orientation, translation, skew, perspective) = decompose(m);
    assert(ok);
    let out = recompose(scale, orientation, translation, skew, perspective);
    assert(near_mat(m, out, epsilon::<f32>()));
}

@test
fn decompose_scale_translate() {
    let t = vec3::splat(2.0);
    let s = vec3::splat(2.0);
    let m = translate(scale(mat4::identity(), s), t);
    let (ok, scale, orientation, translation, skew, perspective) = decompose(m);
    assert(ok);
    let out = recompose(scale, orientation, translation, skew, perspective);
    assert(near_mat(m, out, epsilon::<f32>()));
}

// The axis, the angle and the yaw of the rotation between two rotations about y. The matrices are
// scaled by about 1.00016, so the cosine of the angle clamps at 1 and the angle is 0, while the yaw of
// the quaternion shows the turn.
@test
fn axis_angle_of_a_delta_rotation() {
    let m1 = mat4::new(
        -0.9946,
        0.0,
        -0.104531,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.104531,
        0.0,
        -0.9946,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
    );
    let m2 = mat4::new(
        -0.992624,
        0.0,
        -0.121874,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.121874,
        0.0,
        -0.992624,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
    );
    let m1rot = extract_matrix_rotation(m1);
    let dlt_rotation = m2 * transpose(m1rot);
    let (axis, angle) = axis_angle(dlt_rotation);
    assert(near(axis, vec3::new(0.0, -1.0, 0.0), 0.001));
    assert(angle == 0.0);
    assert((yaw(quat_cast(dlt_rotation)) + 0.01746).abs() < 0.0001);
}

// The matrix rebuilt from the extracted axis and angle is within
// sqrt(epsilon) of the original, element by element.
fn axis_angle_round_trip<T: Float>(axis_true: Vec<T, 3>, angle_true: T) bool {
    let eps = epsilon::<T>().sqrt();
    let mat_true = axis_angle_matrix(axis_true, angle_true);
    let (axis, angle) = axis_angle(mat_true);
    let err = mat_true - axis_angle_matrix(axis, angle);
    for i in 0..mat4::LEN {
        for j in 0..vec4::LEN {
            if !err[i][j].abs().less(eps) {
                return false;
            }
        }
    }
    return true;
}

@test
fn axis_angle2() {
    let pi = pi::<f32>();
    let cases: [(vec3, f32); 17] = [
        (vec3::new(0.0, 1.0, 0.0), 0.0),
        (vec3::new(0.358, 0.0716, 0.9309), 0.00001),
        (vec3::new(1.0, 0.0, 0.0), 0.0001),
        (vec3::new(0.0, 0.0, 1.0), 0.001),
        (vec3::new(0.0, 0.0, 1.0), 0.001),
        (vec3::new(0.0, 1.0, 0.0), 0.005),
        (vec3::new(0.0, 0.0, 1.0), 0.005),
        (vec3::new(0.358, 0.0716, 0.9309), 0.03),
        (vec3::new(0.358, 0.0716, 0.9309), 0.0003),
        (vec3::new(0.0, 0.0, 1.0), 0.01),
        (vec3::new(0.0, 0.7071, 0.7071), 1.3),
        (vec3::new(0.0, 0.7071, 0.7071), 6.3),
        (vec3::new(1.0, 0.0, 0.0), -0.23456),
        (vec3::new(1.0, 0.0, 0.0), pi),
        (vec3::new(0.0, 1.0, 0.0), -pi),
        (vec3::new(0.358, 0.0716, 0.9309), -pi),
        (vec3::new(1.0, 0.0, 0.0), pi + 2e-6),
    ];
    for (axis, angle) in cases {
        assert(axis_angle_round_trip(axis, angle));
    }
    let more: [(vec3, f32); 3] = [
        (vec3::new(1.0, 0.0, 0.0), pi + 1e-4),
        (vec3::new(0.0, 1.0, 0.0), -pi + 1e-3),
        (vec3::new(0.358, 0.0716, 0.9309), -pi + 5e-3),
    ];
    for (axis, angle) in more {
        assert(axis_angle_round_trip(axis, angle));
    }
    let doubles: [(dvec3, f64); 7] = [
        (dvec3::new(0.0, 1.0, 0.0), 0.00005),
        (dvec3::new(-1.0, 0.0, 0.0), 0.000001),
        (dvec3::new(0.7071, 0.7071, 0.0), 0.5),
        (dvec3::new(0.7071, 0.0, 0.7071), 0.0002),
        (dvec3::new(0.7071, 0.0, 0.7071), 0.00002),
        (dvec3::new(0.7071, 0.0, 0.7071), 0.000002),
        (dvec3::new(0.7071, 0.0, 0.7071), 0.0000002),
    ];
    for (axis, angle) in doubles {
        assert(axis_angle_round_trip(axis, angle));
    }
}

@test
fn axis_angle_of_rotate() {
    let m2 = rotate(mat4::identity(), 1.0f32, vec3::new(1.0, 0.0, 0.0));
    let (axis, angle) = axis_angle(m2);
    assert(near(axis, vec3::new(1.0, 0.0, 0.0), 0.00001));
    assert((angle - 1.0).abs() < 0.00001);
}

@test
fn rotate_vector() {
    let half_pi = pi::<f32>() * 0.5;
    let a = rotate_2d(vec2::new(1.0, 0.0), half_pi);
    assert(near(a, vec2::new(0.0, 1.0), epsilon::<f32>()));
    let b = rotate(vec3::new(1.0, 0.0, 0.0), half_pi, vec3::new(0.0, 0.0, 1.0));
    assert(near(b, vec3::new(0.0, 1.0, 0.0), epsilon::<f32>()));
    let c = rotate(vec4::new(1.0, 0.0, 0.0, 1.0), half_pi, vec3::new(0.0, 0.0, 1.0));
    assert(near(c, vec4::new(0.0, 1.0, 0.0, 1.0), epsilon::<f32>()));
}

@test
fn rotate_x_vector() {
    let half_pi = pi::<f32>() * 0.5;
    assert(near(rotate_x(vec3::new(1.0, 0.0, 0.0), half_pi), vec3::new(1.0, 0.0, 0.0), epsilon::<f32>()));
    assert(near(rotate_x(vec4::new(1.0, 0.0, 0.0, 1.0), half_pi), vec4::new(1.0, 0.0, 0.0, 1.0), epsilon::<f32>()));
}

@test
fn rotate_y_vector() {
    let half_pi = pi::<f32>() * 0.5;
    assert(near(rotate_y(vec3::new(1.0, 0.0, 0.0), half_pi), vec3::new(0.0, 0.0, -1.0), epsilon::<f32>()));
    assert(near(rotate_y(vec4::new(1.0, 0.0, 0.0, 1.0), half_pi), vec4::new(0.0, 0.0, -1.0, 1.0), epsilon::<f32>()));
}

@test
fn rotate_z_vector() {
    let half_pi = pi::<f32>() * 0.5;
    assert(near(rotate_z(vec3::new(1.0, 0.0, 0.0), half_pi), vec3::new(0.0, 1.0, 0.0), epsilon::<f32>()));
    assert(near(rotate_z(vec4::new(1.0, 0.0, 0.0, 1.0), half_pi), vec4::new(0.0, 1.0, 0.0, 1.0), epsilon::<f32>()));
}

@test
fn orientation_of_normal() {
    let o = orientation(normalize(vec3::splat(1.0)), vec3::new(0.0, 0.0, 1.0));
    assert(near(o[0], vec4::new(0.79, -0.21, -0.58, 0.0), 0.1));
    assert(near(o[1], vec4::new(-0.21, 0.79, -0.58, 0.0), 0.1));
    assert(near(o[2], vec4::new(0.58, 0.58, 0.58, 0.0), 0.1));
    assert(near(o[3], vec4::new(0.0, 0.0, 0.0, 1.0), 0.1));
}

@test
fn transform_builders_start_from_identity() {
    let v = vec3::new(1.5, -2.0, 0.25);
    assert(translate_matrix(v) == translate(mat4::identity(), v));
    assert(translate_matrix(v)[3] == vec4::new(1.5, -2.0, 0.25, 1.0));
    assert(scale_matrix(v) == scale(mat4::identity(), v));
    assert(scale_matrix(v) == diagonal4x4(v.append(1.0)));
    let axis = dvec3::new(1.0, 2.0, -3.0);
    assert(rotate_matrix(0.75f64, axis) == rotate(dmat4::identity(), 0.75f64, axis));
    assert(near_mat(rotate_matrix(0.75f64, axis), rotate_slow(dmat4::identity(), 0.75f64, axis), 1e-15));
}

@test
fn transform_builders_of_integers() {
    assert(translate_matrix(ivec3::new(1, -2, 3))[3] == ivec4::new(1, -2, 3, 1));
    assert(scale_matrix(ivec3::new(2, 3, 4)) == imat4::new(2, 0, 0, 0, 0, 3, 0, 0, 0, 0, 4, 0, 0, 0, 0, 1));
    // u8 arithmetic wraps: 200 + 200 is 144.
    let t = translate(u8mat4::identity() * 200u8, u8vec3::new(1, 0, 0));
    assert(t[3] == u8vec4::new(200, 0, 0, 200));
    assert(translate(t, u8vec3::new(1, 0, 0))[3] == u8vec4::new(144, 0, 0, 200));
}

@test
fn transform_2d_matrices() {
    let m = mat3::new(1.0, 2.0, 0.0, 3.0, 4.0, 0.0, 5.0, 6.0, 1.0);
    let t = translate(m, vec2::new(2.0, -1.0));
    assert(t[2] == m[0] * 2.0 + m[1] * -1.0 + m[2]);
    assert(t[0] == m[0] && t[1] == m[1]);
    let s = scale(m, vec2::new(2.0, 3.0));
    assert(s == mat3::cols(m[0] * 2.0, m[1] * 3.0, m[2]));
    let a = 0.4f32;
    let r = rotate_2d(m, a);
    assert(r == mat3::cols(m[0] * a.cos() + m[1] * a.sin(), m[0] * -a.sin() + m[1] * a.cos(), m[2]));
    assert(
        near_mat(
            rotate_2d(mat3::identity(), a),
            mat3::from_mat(rotate(mat4::identity(), a, vec3::new(0.0, 0.0, 1.0))),
            1e-6,
        ),
    );
    let sx = shear_x(m, 0.5);
    assert(sx == m * mat3::new(1.0, 0.5, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0));
    let sy = shear_y(m, 0.5);
    assert(sy == m * mat3::new(1.0, 0.0, 0.0, 0.5, 1.0, 0.0, 0.0, 0.0, 1.0));
    // A point (x, y, 1) moves by the translation and the shear as in 2D homogeneous coordinates.
    let p = translate(mat3::identity(), vec2::new(3.0, 4.0)) * vec3::new(1.0, 1.0, 1.0);
    assert(p == vec3::new(4.0, 5.0, 1.0));
    assert(shear_x(mat3::identity(), 2.0) * vec3::new(1.0, 1.0, 1.0) == vec3::new(1.0, 3.0, 1.0));
    assert(shear_y(mat3::identity(), 2.0) * vec3::new(1.0, 1.0, 1.0) == vec3::new(3.0, 1.0, 1.0));
}

@test
fn transform_2d_integers() {
    let m = imat3::identity();
    assert(translate(m, ivec2::new(3, -4))[2] == ivec3::new(3, -4, 1));
    assert(scale(m, ivec2::new(2, 5)) == imat3::new(2, 0, 0, 0, 5, 0, 0, 0, 1));
    assert(shear_x(m, 7) == imat3::new(1, 7, 0, 0, 1, 0, 0, 0, 1));
    assert(shear_y(m, 7) == imat3::new(1, 0, 0, 7, 1, 0, 0, 0, 1));
    assert(scale(u8mat3::identity(), u8vec2::new(255, 2)) * u8vec3::new(2, 1, 1) == u8vec3::new(254, 2, 1));
}

@test
fn decompose_recompose_round_trip() {
    let q = normalize(dquat::new(0.6, -0.2, 0.5, 0.3));
    let m = translate(dmat4::identity(), dvec3::new(1.0, -2.0, 3.0)) * mat4_cast(q) * scale(
        dmat4::identity(),
        dvec3::new(2.0, 0.5, 3.0),
    );
    let (ok, s, o, t, k, p) = decompose(m);
    assert(ok);
    assert(near(s, dvec3::new(2.0, 0.5, 3.0), 1e-12));
    assert(near(t, dvec3::new(1.0, -2.0, 3.0), 1e-12));
    assert(near(k, dvec3::zero(), 1e-12));
    assert(p == dvec4::new(0.0, 0.0, 0.0, 1.0));
    assert(all(equal_eps(o, q, 1e-12)) || all(equal_eps(o, -q, 1e-12)));
    assert(near_mat(recompose(s, o, t, k, p), m, 1e-12));
}

@test
fn decompose_skew_and_perspective() {
    let mut skew = dmat4::identity();
    skew[1][0] = 0.25;
    let mut m = translate(dmat4::identity(), dvec3::new(4.0, 5.0, 6.0)) * mat4_cast(
        angle_axis(0.3f64, dvec3::new(0.0, 0.0, 1.0)),
    ) * skew;
    m[0][3] = 0.01;
    m[1][3] = -0.02;
    m[2][3] = 0.03;
    let (ok, s, o, t, k, p) = decompose(m);
    assert(ok);
    assert((k.z() - 0.25).abs() < 1e-12);
    assert(p != dvec4::new(0.0, 0.0, 0.0, 1.0));
    assert(near_mat(recompose(s, o, t, k, p), m, 1e-12));
}

// A matrix whose determinant is negative (a mirror) decomposes with every scale negated.
@test
fn decompose_mirror_negates_scale() {
    let m = scale(dmat4::identity(), dvec3::new(-2.0, 3.0, 4.0));
    let (ok, s, o, _, _, _) = decompose(m);
    assert(ok);
    assert(s == dvec3::new(-2.0, -3.0, -4.0));
    assert(near_mat(mat4_cast(o), scale(dmat4::identity(), dvec3::new(1.0, -1.0, -1.0)), 1e-15));
}

// The orientation of a half turn about x, y or z has a trace of -1: the largest diagonal element
// picks the component.
@test
fn decompose_half_turns() {
    let axes = [dvec3::new(1.0, 0.0, 0.0), dvec3::new(0.0, 1.0, 0.0), dvec3::new(0.0, 0.0, 1.0)];
    for axis in axes {
        let q = angle_axis(pi::<f64>(), axis);
        let (ok, _, o, _, _, _) = decompose(mat4_cast(q));
        assert(ok);
        assert(all(equal_eps(o, q, 1e-15)) || all(equal_eps(o, -q, 1e-15)));
    }
}

@test
fn decompose_failures() {
    let mut m = mat4::identity();
    m[3][3] = 0.0;
    let (ok, s, o, t, k, p) = decompose(m);
    assert(!ok);
    assert(s == vec3::zero() && t == vec3::zero() && k == vec3::zero() && p == vec4::zero());
    assert(o == Quat::<f32>::new(0.0, 0.0, 0.0, 0.0));
    let singular = scale(mat4::identity(), vec3::new(1.0, 0.0, 1.0));
    let (ok2, _, _, _, _, _) = decompose(singular);
    assert(!ok2);
    // Every element is divided by m[3][3] first.
    let (ok3, s3, _, t3, _, _) = decompose(translate(mat4::identity(), vec3::new(2.0, 4.0, 6.0)) * 2.0);
    assert(ok3);
    assert(s3 == vec3::splat(1.0));
    assert(t3 == vec3::new(2.0, 4.0, 6.0));
}

@test
fn recompose_applies_each_skew() {
    let id = dquat::identity();
    let one = dvec3::splat(1.0);
    let zero = dvec3::zero();
    let p = dvec4::new(0.0, 0.0, 0.0, 1.0);
    let m = recompose(one, id, zero, dvec3::new(0.5, 0.0, 0.0), p);
    assert(m[2][1] == 0.5);
    let m2 = recompose(one, id, zero, dvec3::new(0.0, 0.5, 0.0), p);
    assert(m2[2][0] == 0.5);
    let m3 = recompose(one, id, zero, dvec3::new(0.0, 0.0, 0.5), p);
    assert(m3[1][0] == 0.5);
    assert(
        recompose(one, id, zero, zero, dvec4::new(0.1, 0.2, 0.3, 2.0)) == dmat4::new(
            1.0,
            0.0,
            0.0,
            0.1,
            0.0,
            1.0,
            0.0,
            0.2,
            0.0,
            0.0,
            1.0,
            0.3,
            0.0,
            0.0,
            0.0,
            2.0,
        ),
    );
}

@test
fn axis_angle_branches() {
    let pi = pi::<f64>();
    // Near the identity.
    let (a0, t0) = axis_angle(dmat4::identity());
    assert(a0 == dvec3::new(1.0, 0.0, 0.0));
    assert(t0 == 0.0);
    // Half turns: the axis from the largest diagonal element.
    let xs = [
        dvec3::new(1.0, 0.0, 0.0),
        dvec3::new(0.0, 1.0, 0.0),
        dvec3::new(0.0, 0.0, 1.0),
        normalize(dvec3::new(1.0, 2.0, 2.0)),
    ];
    for axis in xs {
        let (a, t) = axis_angle(rotate_matrix(pi, axis));
        assert(t == pi);
        assert(near(a, axis, 1e-7) || near(a, -axis, 1e-7));
    }
    // A symmetric block whose diagonal is -1 gives the fixed (0.7071, 0.7071, 0) axis.
    let (a1, t1) = axis_angle(
        dmat4::new(-1.0, 0.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.0, 1.0),
    );
    assert(a1 == dvec3::new(0.7071, 0.7071, 0.0));
    assert(t1 == pi);
    let (a2, _) = axis_angle(
        dmat4::new(-1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.0, 1.0),
    );
    assert(a2 == dvec3::new(0.0, 0.5f64.sqrt(), 0.0));
    // The cosine clamps: a trace above 3 gives angle 0, below -1 gives pi.
    let mut big = dmat4::identity() * 2.0;
    big[1][0] = 1.0;
    let (_, t3) = axis_angle(big);
    assert(t3 == 0.0);
    let mut small = dmat4::identity() * -2.0;
    small[1][0] = 1.0;
    let (_, t4) = axis_angle(small);
    assert(t4 == pi);
}

@test
fn axis_angle_matrix_rotates() {
    let m = axis_angle_matrix(dvec3::new(0.0, 0.0, 2.0), pi::<f64>() * 0.5);
    assert(near(m * dvec4::new(1.0, 0.0, 0.0, 1.0), dvec4::new(0.0, 1.0, 0.0, 1.0), 1e-15));
    assert(near_mat(m, rotate_matrix(pi::<f64>() * 0.5, dvec3::new(0.0, 0.0, 1.0)), 1e-15));
}

@test
fn extract_matrix_rotation_and_interpolate() {
    let a = translate(dmat4::identity(), dvec3::new(1.0, 2.0, 3.0)) * rotate_matrix(0.2f64, dvec3::new(0.0, 1.0, 0.0));
    let b = translate(dmat4::identity(), dvec3::new(3.0, 2.0, 1.0)) * rotate_matrix(1.0f64, dvec3::new(0.0, 1.0, 0.0));
    let r = extract_matrix_rotation(a);
    assert(r[3] == dvec4::new(0.0, 0.0, 0.0, 1.0));
    assert(r[0] == a[0] && r[1] == a[1] && r[2] == a[2]);
    let mid = interpolate(a, b, 0.5);
    let expected = translate(dmat4::identity(), dvec3::new(2.0, 2.0, 2.0)) * rotate_matrix(
        0.6f64,
        dvec3::new(0.0, 1.0, 0.0),
    );
    assert(near_mat(mid, expected, 1e-12));
    assert(near_mat(interpolate(a, b, 0.0), a, 1e-12));
    assert(near_mat(interpolate(a, b, 1.0), b, 1e-12));
}

@test
fn rotate_vector_f64_and_slerp() {
    let v = dvec3::new(1.0, 2.0, 3.0);
    let axis = dvec3::new(0.0, 1.0, 1.0);
    assert(rotate(v, 0.7f64, axis) == dmat3::from_mat(rotate_matrix(0.7f64, axis)) * v);
    assert(rotate(v.append(5.0), 0.7f64, axis) == rotate_matrix(0.7f64, axis) * v.append(5.0));
    let a = 1.1f64;
    let rx = rotate_x(v, a);
    assert(near(rx, dmat3::from_mat(rotate_matrix(a, dvec3::new(1.0, 0.0, 0.0))) * v, 1e-15));
    assert(near(rotate_y(v, a), dmat3::from_mat(rotate_matrix(a, dvec3::new(0.0, 1.0, 0.0))) * v, 1e-15));
    assert(near(rotate_z(v, a), dmat3::from_mat(rotate_matrix(a, dvec3::new(0.0, 0.0, 1.0))) * v, 1e-15));
    assert(rotate_z(v.append(9.0), a) == rotate_z(v, a).append(9.0));
    let x = dvec3::new(1.0, 0.0, 0.0);
    let y = dvec3::new(0.0, 1.0, 0.0);
    assert(near(slerp(x, y, 0.5f64), normalize(dvec3::new(1.0, 1.0, 0.0)), 1e-15));
    assert(near(slerp(x, y, 0.0f64), x, 1e-15));
    assert(near(slerp(x, y, 1.0f64), y, 1e-15));
    // Equal vectors divide by a zero sine.
    assert(slerp(x, x, 0.5f64).x().is_nan());
}

@test
fn orientation_of_equal_vectors_is_identity() {
    let up = vec3::new(0.0, 0.0, 1.0);
    assert(orientation(up, up) == mat4::identity());
    assert(orientation(up + vec3::splat(1e-8), up) == mat4::identity());
    let o = orientation(dvec3::new(1.0, 0.0, 0.0), dvec3::new(0.0, 0.0, 1.0));
    assert(near(o * dvec4::new(0.0, 0.0, 1.0, 0.0), dvec4::new(1.0, 0.0, 0.0, 0.0), 1e-15));
}

@test
fn builder_const_initializers() {
    assert(TM == translate_matrix(vec3::new(1.0, 2.0, 3.0)));
    assert(RM == rotate_matrix(0.5f64, dvec3::new(0.0, 0.0, 1.0)));
    assert(SM == imat4::new(2, 0, 0, 0, 0, 3, 0, 0, 0, 0, 4, 0, 0, 0, 0, 1));
    assert(T2 == mat3::new(1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 2.0, 1.0));
    assert(R2 == rotate_2d(mat3::identity(), 0.25f32));
    assert(SX == mat3::new(1.0, 2.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0));
    assert(AAM == axis_angle_matrix(vec3::new(0.0, 1.0, 0.0), 0.5f32));
    assert(RV == rotate_x(vec3::new(0.0, 1.0, 0.0), 0.5f32));
    assert(REC == translate_matrix(vec3::new(1.0, 2.0, 3.0)) * scale_matrix(vec3::splat(2.0)));
}
