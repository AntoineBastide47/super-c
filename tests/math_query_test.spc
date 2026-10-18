// std::math::query: the vector and matrix predicates on basic inputs, then every overload and vector
// size, the epsilon boundaries, NaN inputs, integer and non-square matrices in is_identity with the
// widening of 8- and 16-bit integers, and constant initializers.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::query as *;

@test
fn collinear_splats() {
    assert(are_collinear(vec2::splat(-1.0), vec2::splat(1.0), 0.00001f32));
    assert(are_collinear(vec3::splat(-1.0), vec3::splat(1.0), 0.00001f32));
    assert(are_collinear(vec4::splat(-1.0), vec4::splat(1.0), 0.00001f32));
}

@test
fn orthogonal_axes() {
    assert(are_orthogonal(vec2::new(1.0, 0.0), vec2::new(0.0, 1.0), 0.00001f32));
}

@test
fn normalized_axis() {
    assert(is_normalized(vec4::new(1.0, 0.0, 0.0, 0.0), 0.00001f32));
}

@test
fn null_vector() {
    assert(is_null(vec4::splat(0.0), 0.00001f32));
}

@test
fn orthonormal_axes() {
    assert(are_orthonormal(vec2::new(1.0, 0.0), vec2::new(0.0, 1.0), 0.00001f32));
}

@test
fn matrix_is_null() {
    assert(is_null(mat4::zero(), 0.00001f32));
}

@test
fn identity_matrices() {
    assert(is_identity(mat2::identity(), 0.00001f32));
    assert(is_identity(mat3::identity(), 0.00001f32));
    assert(is_identity(mat4::identity(), 0.00001f32));
}

@test
fn matrix_is_normalized() {
    assert(is_normalized(mat4::identity(), 0.00001f32));
}

@test
fn orthogonal_identity() {
    assert(is_orthogonal(mat4::identity(), 0.00001f32));
    assert(!is_orthogonal(mat4::zero(), 0.00001f32));
}

// The collinearity test crosses vec3s: a vec2 gets z = 0 and a vec4 loses w, so w never matters.
@test
fn are_collinear_shapes() {
    assert(!are_collinear(vec2::new(1.0, 0.0), vec2::new(0.0, 1.0), 0.1f32));
    assert(are_collinear(dvec2::new(2.0, 4.0), dvec2::new(-1.0, -2.0), 1e-12f64));
    assert(!are_collinear(vec3::new(1.0, 0.0, 0.0), vec3::new(1.0, 0.1, 0.0), 0.05f32));
    assert(are_collinear(vec3::new(1.0, 0.0, 0.0), vec3::new(1.0, 0.1, 0.0), 0.2f32));
    assert(are_collinear(vec4::new(1.0, 2.0, 3.0, 9.0), vec4::new(2.0, 4.0, 6.0, -5.0), 0.00001f32));
    assert(!are_collinear(dvec4::new(1.0, 0.0, 0.0, 0.0), dvec4::new(0.0, 0.0, 1.0, 0.0), 0.5f64));
    // The test is strict: a zero cross product is not below a zero epsilon.
    assert(!are_collinear(vec3::splat(1.0), vec3::splat(2.0), 0.0f32));
    assert(!are_collinear(vec3::new(f32::nan(), 0.0, 0.0), vec3::splat(1.0), 1.0f32));
}

// The orthogonality bound scales with the lengths above 1 and is inclusive; max turns a NaN length
// into 1, but the NaN dot product still fails the test.
@test
fn are_orthogonal_bound() {
    assert(are_orthogonal(vec1::new(0.0), vec1::new(5.0), 0.0f32));
    assert(!are_orthogonal(vec1::new(1.0), vec1::new(1.0), 0.5f32));
    assert(are_orthogonal(vec3::new(1.0, 0.5, 0.0), vec3::new(0.0, 0.0, 1.0), 0.0f32));
    assert(are_orthogonal(vec2::new(4.0, 0.0), vec2::new(0.25, 5.0), 0.05f32));
    assert(!are_orthogonal(vec2::new(4.0, 0.0), vec2::new(0.25, 5.0), 0.049f32));
    assert(are_orthogonal(dvec4::new(1.0, 1.0, 0.0, 0.0), dvec4::new(1.0, -1.0, 0.0, 0.0), 0.0f64));
    assert(!are_orthogonal(vec2::new(f32::nan(), 0.0), vec2::new(0.0, 1.0), 1.0f32));
}

// The normalization test is `|length - 1| <= 2 epsilon`, the null test `length <= epsilon`, both
// inclusive.
@test
fn vector_norm_queries() {
    assert(is_normalized(vec1::new(-1.0), 0.0f32));
    assert(is_normalized(vec2::new(0.6, 0.8), 0.0000001f32));
    assert(is_normalized(dvec3::new(1.5, 0.0, 0.0), 0.25f64));
    assert(!is_normalized(dvec3::new(1.5, 0.0, 0.0), 0.2499f64));
    assert(!is_normalized(vec4::splat(0.0), 0.4f32));
    assert(!is_normalized(vec2::new(f32::nan(), 0.0), 1.0f32));
    assert(is_null(vec1::new(-0.5), 0.5f32));
    assert(!is_null(vec2::new(0.3, 0.4), 0.49f32));
    assert(is_null(dvec3::new(0.3, 0.4, 0.0), 0.5f64));
    assert(!is_null(vec3::new(f32::nan(), 0.0, 0.0), 1.0f32));
}

// The component null test is strict: |v[i]| < epsilon.
@test
fn is_comp_null_components() {
    assert(is_comp_null(vec2::new(0.0, 0.5), 0.5f32) == bvec2::new(true, false));
    assert(is_comp_null(vec3::new(-0.1, 0.1, -1.0), 0.2f32) == bvec3::new(true, true, false));
    let n = f64::nan();
    assert(is_comp_null(dvec4::new(n, 0.0, -0.0, 1e-9), 1e-8f64) == bvec4::new(false, true, true, true));
}

@test
fn are_orthonormal_cases() {
    assert(are_orthonormal(vec3::new(1.0, 0.0, 0.0), vec3::new(0.0, 0.0, -1.0), 0.0f32));
    assert(!are_orthonormal(vec3::new(2.0, 0.0, 0.0), vec3::new(0.0, 1.0, 0.0), 0.1f32));
    assert(!are_orthonormal(vec3::new(1.0, 0.0, 0.0), vec3::new(0.0, 2.0, 0.0), 0.1f32));
    let h = 0.5f64.sqrt();
    assert(are_orthonormal(dvec2::new(h, h), dvec2::new(-h, h), 1e-15f64));
    assert(!are_orthonormal(dvec4::new(1.0, 0.0, 0.0, 0.0), dvec4::new(0.6, 0.8, 0.0, 0.0), 0.5f64));
}

// A matrix is null when every column is, and normalized when every column and every row is.
@test
fn matrix_norm_queries() {
    assert(is_null(mat2::new(0.1, 0.0, 0.0, -0.1), 0.1f32));
    assert(!is_null(mat2::new(0.1, 0.0, 0.0, -0.2), 0.1f32));
    assert(is_null(dmat3::zero(), 0.0f64));
    assert(!is_null(mat3::diagonal(f32::nan()), 1.0f32));
    let rot = mat2::new(0.6, 0.8, -0.8, 0.6);
    assert(is_normalized(rot, 0.0000001f32));
    // Unit columns whose rows are not unit: (1, 0) and (1, 0) as columns.
    assert(!is_normalized(mat2::new(1.0, 0.0, 1.0, 0.0), 0.01f32));
    assert(is_normalized(dmat3::identity(), 0.0f64));
    assert(!is_normalized(dmat4::diagonal(2.0), 0.4f64));
    assert(is_normalized(dmat4::diagonal(2.0), 0.5f64));
}

// The identity test takes any shape and element type; the diagonal is within epsilon of 1, the rest of 0.
@test
fn is_identity_shapes() {
    assert(is_identity(mat2x3::identity(), 0.0f32));
    assert(is_identity(dmat4x2::identity(), 0.0f64));
    assert(!is_identity(mat3x2::diagonal(2.0), 0.5f32));
    assert(is_identity(mat3x2::diagonal(1.5), 0.5f32));
    let mut m = mat4::identity();
    m.c[3].e[0] = 0.25;
    assert(!is_identity(m, 0.2f32));
    assert(is_identity(m, 0.25f32));
    m.c[3].e[0] = f32::nan();
    assert(!is_identity(m, 1.0f32));
    assert(is_identity(imat3::identity(), 0i32));
    assert(!is_identity(imat3::diagonal(2), 0i32));
    assert(is_identity(imat3::diagonal(2), 1i32));
    assert(is_identity(umat2x4::identity(), 0u32));
}

// An 8- or 16-bit integer widens to i64 before `m[i][i] - 1`: a u8 diagonal of 0 is 1 away
// from 1 (not 255), and an i8 diagonal of -128 is 129 away (not 127). Wider integers keep their own
// arithmetic: a u32 diagonal of 0 is 0xFFFFFFFF away.
@test
fn is_identity_integer_promotion() {
    assert(is_identity(u8mat2::identity(), 0u8));
    assert(is_identity(u8mat2::diagonal(0), 1u8));
    assert(!is_identity(u8mat2::diagonal(0), 0u8));
    assert(!is_identity(i8mat2::diagonal(-128), 127i8));
    assert(is_identity(i16mat3::diagonal(-1), 2i16));
    assert(is_identity(u16mat2::diagonal(3), 2u16));
    assert(!is_identity(umat2::diagonal(0), 1u32));
    assert(is_identity(umat2::diagonal(0), 0xFFFFFFFFu32));
    assert(is_identity(i64mat2::diagonal(-4), 5i64));
}

// The orthogonal matrix test checks the columns, then the rows, for unit length and pairwise
// orthogonality.
@test
fn is_orthogonal_cases() {
    let rot = mat2::new(0.6, 0.8, -0.8, 0.6);
    assert(is_orthogonal(rot, 0.0000001f32));
    assert(!is_orthogonal(mat2::new(0.6, 0.8, 0.8, 0.6), 0.1f32));
    let p = dmat3::cols(dvec3::new(0.0, 1.0, 0.0), dvec3::new(0.0, 0.0, 1.0), dvec3::new(1.0, 0.0, 0.0));
    assert(is_orthogonal(p, 0.0f64));
    assert(!is_orthogonal(dmat3::diagonal(2.0), 0.4f64));
    assert(!is_orthogonal(mat4::diagonal(f32::nan()), 1.0f32));
}

const COMP: Vec<bool, 2> = is_comp_null(vec2::new(0.0, 1.0), 0.5f32);
const IDENTITY: bool = is_identity(mat3::identity(), 0.0f32);
const NULL_VEC: bool = is_null(vec4::splat(0.0), 0.00001f32);
const NULL_MAT: bool = is_null(mat4::zero(), 0.00001f32);
const NORMALIZED_VEC: bool = is_normalized(vec2::new(0.6, 0.8), 0.0000001f32);
const NORMALIZED_MAT: bool = is_normalized(mat4::identity(), 0.00001f32);
const COLLINEAR: bool = are_collinear(vec3::splat(-1.0), vec3::splat(1.0), 0.00001f32);
const ORTHOGONAL: bool = are_orthogonal(vec2::new(0.6, 0.8), vec2::new(-0.8, 0.6), 0.0000001f32);
const ORTHONORMAL: bool = are_orthonormal(vec2::new(1.0, 0.0), vec2::new(0.0, 1.0), 0.00001f32);
const ORTHOGONAL_MAT: bool = is_orthogonal(mat2::new(0.6, 0.8, -0.8, 0.6), 0.0000001f32);
const NOT_ORTHOGONAL_MAT: bool = is_orthogonal(mat4::zero(), 0.00001f32);

@test
fn constant_initializers() {
    assert(COMP == bvec2::new(true, false));
    assert(IDENTITY);
    assert(NULL_VEC);
    assert(NULL_MAT);
    assert(NORMALIZED_VEC);
    assert(NORMALIZED_MAT);
    assert(COLLINEAR);
    assert(ORTHOGONAL);
    assert(ORTHONORMAL);
    assert(ORTHOGONAL_MAT);
    assert(!NOT_ORTHOGONAL_MAT);
}

// Each constant equals the same call at run time.
@test
fn constants_match_run_time() {
    let e = 0.0000001f32;
    assert_eq(NORMALIZED_VEC, is_normalized(vec2::new(0.6, 0.8), e));
    assert_eq(ORTHOGONAL, are_orthogonal(vec2::new(0.6, 0.8), vec2::new(-0.8, 0.6), e));
    assert_eq(ORTHOGONAL_MAT, is_orthogonal(mat2::new(0.6, 0.8, -0.8, 0.6), e));
}
