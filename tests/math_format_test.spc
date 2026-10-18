// std::math::format: the text of vectors, matrices, quaternions and dual quaternions, one-key maps of
// each type, the `Format` text, then every type prefix, the `%d` of `u32` and 64-bit components, floats
// past `%f`'s usual width, the 4095-byte cut, the hash of +0.0 and -0.0, exact hash values, and maps
// keyed by vectors.
import std::math::scalar as *;
import std::math::vec as *;
import std::math::mat as *;
import std::math::quat as *;
import std::math::dual_quat as *;
import std::math::format as *;

fn text_is<G: Format + Copy>(x: G, want: str) bool {
    let s = to_string(x);
    return s.as_str() == want;
}

@test
fn vector_text() {
    assert(text_is(vec2::new(1.0, 2.0), "vec2(1.000000, 2.000000)"));
    assert(text_is(vec3::new(1.0, 2.0, 3.0), "vec3(1.000000, 2.000000, 3.000000)"));
    assert(text_is(vec4::new(1.0, 2.0, 3.0, 4.0), "vec4(1.000000, 2.000000, 3.000000, 4.000000)"));
    assert(text_is(dvec2::new(1.0, 2.0), "dvec2(1.000000, 2.000000)"));
    assert(text_is(dvec3::new(1.0, 2.0, 3.0), "dvec3(1.000000, 2.000000, 3.000000)"));
    assert(text_is(dvec4::new(1.0, 2.0, 3.0, 4.0), "dvec4(1.000000, 2.000000, 3.000000, 4.000000)"));
    assert(text_is(bvec2::new(false, true), "bvec2(false, true)"));
    assert(text_is(bvec3::new(false, true, false), "bvec3(false, true, false)"));
    assert(text_is(bvec4::new(false, true, false, true), "bvec4(false, true, false, true)"));
    assert(text_is(ivec2::new(1, 2), "ivec2(1, 2)"));
    assert(text_is(ivec3::new(1, 2, 3), "ivec3(1, 2, 3)"));
    assert(text_is(ivec4::new(1, 2, 3, 4), "ivec4(1, 2, 3, 4)"));
    assert(text_is(i8vec2::new(1, 2), "i8vec2(1, 2)"));
    assert(text_is(i8vec3::new(1, 2, 3), "i8vec3(1, 2, 3)"));
    assert(text_is(i8vec4::new(1, 2, 3, 4), "i8vec4(1, 2, 3, 4)"));
    assert(text_is(i16vec2::new(1, 2), "i16vec2(1, 2)"));
    assert(text_is(i16vec3::new(1, 2, 3), "i16vec3(1, 2, 3)"));
    assert(text_is(i16vec4::new(1, 2, 3, 4), "i16vec4(1, 2, 3, 4)"));
    assert(text_is(i64vec2::new(1, 2), "i64vec2(1, 2)"));
    assert(text_is(i64vec3::new(1, 2, 3), "i64vec3(1, 2, 3)"));
    assert(text_is(i64vec4::new(1, 2, 3, 4), "i64vec4(1, 2, 3, 4)"));
}

@test
fn matrix_text() {
    let m = mat2x2::cols(vec2::new(1.0, 2.0), vec2::new(3.0, 4.0));
    assert(text_is(m, "mat2x2((1.000000, 2.000000), (3.000000, 4.000000))"));
}

@test
fn quaternion_text() {
    assert(text_is(quat::new(1.0, 2.0, 3.0, 4.0), "quat(1.000000, {2.000000, 3.000000, 4.000000})"));
}

@test
fn dual_quaternion_text() {
    let q = dualquat::new(quat::new(1.0, 2.0, 3.0, 4.0), quat::new(5.0, 6.0, 7.0, 8.0));
    let want = "dualquat((1.000000, {2.000000, 3.000000, 4.000000}), (5.000000, {6.000000, 7.000000, 8.000000}))";
    assert(text_is(q, want));
}

@test
fn hash_maps_count_one_key() {
    let mut errors = 0;
    errors += count_one(ivec1::splat(0));
    errors += count_one(ivec2::splat(0));
    errors += count_one(ivec3::splat(0));
    errors += count_one(ivec4::splat(0));
    errors += count_one(quat::from_scalar_vec(0.0, vec3::splat(0.0)));
    errors += count_one(dualquat::from_real(quat::identity()));
    errors += count_one(mat2x2::diagonal(0.0));
    errors += count_one(mat2x3::diagonal(0.0));
    errors += count_one(mat2x4::diagonal(0.0));
    errors += count_one(mat3x2::diagonal(0.0));
    errors += count_one(mat3x3::diagonal(0.0));
    errors += count_one(mat3x4::diagonal(0.0));
    errors += count_one(mat4x2::diagonal(0.0));
    errors += count_one(mat4x3::diagonal(0.0));
    errors += count_one(mat4x4::diagonal(0.0));
    assert_eq(errors, 15);
}

fn count_one<K: Hash + Eq + Copy>(key: K) i32 {
    let mut m = Map::<K, i32>::new();
    m.insert(key, 0);
    let n = *m.get(&key).unwrap() + 1;
    m.insert(key, n);
    return *m.get(&key).unwrap();
}

@test
fn format_gives_to_string_text() {
    let q = dquat::new(1.0, 0.0, 0.0, 0.0);
    assert(q.fmt().as_str() == "dquat(1.000000, {0.000000, 0.000000, 0.000000})");
    let v = vec4::new(1.0, 2.0, 3.0, 4.0);
    assert(v.fmt().as_str() == "vec4(1.000000, 2.000000, 3.000000, 4.000000)");
    let m = mat4x3::identity();
    let want = "mat4x3((1.000000, 0.000000, 0.000000), (0.000000, 1.000000, 0.000000), (0.000000, 0.000000, 1.000000), (0.000000, 0.000000, 0.000000))";
    assert(m.fmt().as_str() == want);
    let text = format("{}", v);
    assert(text.as_str() == "vec4(1.000000, 2.000000, 3.000000, 4.000000)");
}

@test
fn every_prefix() {
    assert(text_is(vec1::new(0.5), "vec1(0.500000)"));
    assert(text_is(dvec1::new(-0.25), "dvec1(-0.250000)"));
    assert(text_is(bvec1::new(true), "bvec1(true)"));
    assert(text_is(u8vec3::new(255, 0, 7), "u8vec3(255, 0, 7)"));
    assert(text_is(i16vec1::new(-300), "i16vec1(-300)"));
    assert(text_is(u16vec2::new(65535, 1), "u16vec2(65535, 1)"));
    assert(text_is(uvec2::new(7, 8), "uvec2(7, 8)"));
    assert(text_is(u64vec1::new(9), "u64vec1(9)"));
    assert(
        text_is(
            imat3x2::cols(ivec2::new(1, -2), ivec2::new(3, 4), ivec2::new(5, 6)),
            "imat3x2((1, -2), (3, 4), (5, 6))",
        ),
    );
    let d = dmat2x3::cols(dvec3::new(1.5, -2.25, 3.0), dvec3::new(4.0, 5.0, 6.0));
    assert(text_is(d, "dmat2x3((1.500000, -2.250000, 3.000000), (4.000000, 5.000000, 6.000000))"));
    assert(text_is(dquat::new(1.0, 2.0, 3.0, 4.0), "dquat(1.000000, {2.000000, 3.000000, 4.000000})"));
    let dual = ddualquat::new(dquat::new(-1.0, 0.5, 0.0, 2.0), dquat::new(0.0, -0.0, 1.0, 3.0));
    let want = "ddualquat((-1.000000, {0.500000, 0.000000, 2.000000}), (0.000000, {-0.000000, 1.000000, 3.000000}))";
    assert(text_is(dual, want));
}

@test
fn integers_print_as_i32() {
    assert(text_is(uvec2::new(4000000000, 7), "uvec2(-294967296, 7)"));
    assert(text_is(i64vec2::new(5000000000, -1), "i64vec2(705032704, -1)"));
    assert(text_is(u64vec1::new(u64::MAX), "u64vec1(-1)"));
}

@test
fn floats_print_as_percent_f() {
    assert(text_is(vec2::new(-0.0, 1e20), "vec2(-0.000000, 100000002004087734272.000000)"));
    assert(text_is(dvec2::new(0.0000004, 0.0000015), "dvec2(0.000000, 0.000002)"));
    let inf = to_string(vec1::new(f32::infinity()));
    assert(inf.as_str() == "vec1(inf)");
}

@test
fn text_is_cut_at_4095_bytes() {
    let big = to_string(dmat4::diagonal(1e300));
    assert_eq(big.len(), 1375);
    let full = to_string(Mat::<f64, 4, 4> { c: [dvec4::splat(-1e300); 4] });
    assert_eq(full.len(), 4095);
    let first = "dmat4x4((-1000000000000000052504760255204420248704468581108159154915854115511802457988908195786371375080447864043704443832883878176942523235360430575644792184786706982848387200926575803737830233794788090059368953234970799945081119038967640880074652742780142494579258788820056842838115669472196386865459400540160.000000, ";
    assert(full.as_str().starts_with(first));
}

@test
fn signed_zeros_hash_equally() {
    assert_eq(vec2::new(0.0, -0.0).hash(), vec2::new(-0.0, 0.0).hash());
    assert_eq(dvec1::new(-0.0).hash(), dvec1::new(0.0).hash());
    assert_eq(quat::new(-0.0, 0.0, -0.0, 0.0).hash(), quat::new(0.0, -0.0, 0.0, -0.0).hash());
    let m = mat2::cols(vec2::new(-0.0, 1.0), vec2::new(2.0, 0.0));
    assert_eq(m.hash(), mat2::cols(vec2::new(0.0, 1.0), vec2::new(2.0, -0.0)).hash());
    assert(vec2::new(0.0, -0.0) == vec2::new(-0.0, 0.0));
    let p = dualquat::new(quat::new(1.0, -0.0, 0.0, 0.0), quat::new(0.0, 0.0, -0.0, 2.0));
    let q = dualquat::new(quat::new(1.0, 0.0, -0.0, 0.0), quat::new(-0.0, 0.0, 0.0, 2.0));
    assert(p == q);
    assert_eq(p.hash(), q.hash());
}

@test
fn hash_values() {
    assert_eq(ivec1::new(-5).hash(), 0xfffffffffffffffbu64);
    assert_eq(ivec3::new(1, 2, 3).hash(), 0xa16fb58d153u64);
    assert_eq(imat2x2::cols(ivec2::new(1, 2), ivec2::new(3, 4)).hash(), 0xaa7d20141b0u64);
    assert_eq(bvec2::new(true, false).hash(), 0x28cd94bf1du64);
    assert_eq(vec2::new(1.0, -0.0).hash(), 0x389e34bfdeu64);
    assert_eq(dvec2::new(1.0, 0.0).hash(), 0x340c0028cd94bfdeu64);
    assert_eq(quat::new(1.0, 0.0, -0.0, 2.0).hash(), 0x28223d9cd221au64);
}

@test
fn maps_keyed_by_vectors() {
    let mut m = Map::<vec3, i32>::new();
    for i in 0..100 {
        m.insert(vec3::new(i as f32, (i * 2) as f32, -0.5), i);
    }
    m.insert(vec3::new(0.0, 0.0, -0.5), 1000);
    m.insert(vec3::new(-0.0, -0.0, -0.5), 2000);
    assert_eq(m.len(), 100);
    let zero = vec3::new(0.0, 0.0, -0.5);
    let present = vec3::new(42.0, 84.0, -0.5);
    let absent = vec3::new(42.0, 84.0, 0.5);
    assert_eq(*m.get(&zero).unwrap(), 2000);
    assert_eq(*m.get(&present).unwrap(), 42);
    assert(m.get(&absent).is_none());
    let mut b = Map::<bvec2, i32>::new();
    b.insert(bvec2::new(true, false), 1);
    b.insert(bvec2::new(false, true), 2);
    let key = bvec2::new(false, true);
    assert_eq(*b.get(&key).unwrap(), 2);
    let mut s = Set::<i64vec2>::new();
    s.insert(i64vec2::new(1, 2));
    s.insert(i64vec2::new(1, 2));
    s.insert(i64vec2::new(2, 1));
    assert_eq(s.len(), 2);
}
