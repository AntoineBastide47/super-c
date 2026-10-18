// std::math::vec: construction, operators, increments, swizzles, size and casts of vec1 .. vec4 and
// bvec3, bvec4, the bits of a 0.0 and 1.0 splat, the component count, then the zero sign of negation,
// IEEE equality, integer wrapping, index traps and constant initializers.
import std::math::scalar as *;
import std::math::vec as *;

// Every component of `a` within `eps` of `b`.
fn near<T: Float, const N: usize>(a: Vec<T, N>, b: Vec<T, N>, eps: T) bool {
    for i in 0..N {
        if !(a[i] - b[i]).abs().less_equal(eps) {
            return false;
        }
    }
    return true;
}

// The dot product for the swizzle checks: the component products summed left to right.
fn dot_of<T: Scalar, const N: usize>(a: Vec<T, N>, b: Vec<T, N>) T {
    let p = a * b;
    let mut s = p[0];
    for i in 1..N {
        s = s + p[i];
    }
    return s;
}

// A float vector and an integer vector on the same bits.
union Pack<const N: usize> {
    pub f: Vec<f32, N>,
    pub i: Vec<i32, N>,
}

// The bits of a 0.0 splat and a 1.0 splat read as integers.
fn pack_bits<const N: usize>() {
    let a = Pack::<N> { f: Vec::<f32, N>::splat(0.0) };
    assert(a.i == Vec::<i32, N>::splat(0));
    let b = Pack::<N> { f: Vec::<f32, N>::splat(1.0) };
    assert(b.i == Vec::<i32, N>::splat(1065353216));
}

const V3: vec3 = vec3::new(1.0, 2.0, 3.0) * 2.0;
const IV4: ivec4 = ivec2::new(1, 2).concat(ivec2::new(3, 4));
const SW: vec2 = V3.swizzle2::<2, 0>();
const NEG: vec4 = -vec4::new(1.0, -2.0, 0.0, 4.0);
const U8W: u8vec2 = u8vec2::new(250, 3) + u8vec2::splat(10);
const L2: usize = vec2::LEN;

// vec1.

@test
fn vec1_operators() {
    let mut a = ivec1::new(1);
    let mut b = ivec1::new(1);
    assert(a == b);
    assert(!(a != b));
    a = a * 1;
    b = b * 1;
    a = a + 1;
    b = b + 1;
    assert(a == b);
    assert(!(a != b));
}

@test
fn vec1_ctor() {
    let eps = f32::epsilon();
    let a: vec1 = vec2::splat(2.0).truncate::<1>();
    assert(near(a, vec1::new(2.0), eps));
    let b: vec1 = vec2::new(2.0, 3.0).truncate::<1>();
    assert(near(b, vec1::new(2.0), eps));
    let d: f64 = 3.0;
    let c: vec1 = vec2::new(2.0, d as f32).truncate::<1>();
    assert(near(c, vec1::new(2.0), eps));
    let e: vec1 = dvec2::splat(2.0).truncate::<1>().cast::<f32>();
    assert(near(e, vec1::new(2.0), eps));
    let f: vec1 = ivec2::splat(2).truncate::<1>().cast::<f32>();
    assert(near(f, vec1::new(2.0), eps));
}

@test
fn vec1_size() {
    assert_eq(sizeof(vec1), 4);
    assert_eq(sizeof(dvec1), 8);
    assert_eq(vec1::LEN, 1);
    assert_eq(dvec1::LEN, 1);
}

@test
fn vec1_operator_increment() {
    let v0 = ivec1::new(1);
    let mut v1 = v0;
    let mut v2 = v0;
    v1 = v1 + 1;
    let v3 = v1;
    let v4 = v2;
    v2 = v2 + 1;
    assert(v0 == v4);
    assert(v1 == v2);
    assert(v1 == v3);
}

@test
fn vec1_swizzle() {
    let a = vec1::new(1.0);
    let c = vec1::new(a.x());
    assert(near(a, c, f32::epsilon()));
}

// vec2.

@test
fn vec2_operators() {
    let eps = f32::epsilon();
    {
        let a = ivec2::splat(1);
        let b = ivec2::splat(1);
        assert(!(a != b));
        assert(a == b);
    }
    {
        let mut a = vec2::splat(1.0);
        let c = a + 1.0;
        a = a + 1.0;
        assert(near(a, vec2::splat(2.0), eps));
        assert(near(a, c, eps));
    }
    {
        let mut a = vec2::splat(1.0);
        let b = vec2::new(2.0, -1.0);
        let c = a + b;
        a += b;
        assert(near(a, vec2::new(3.0, 0.0), eps));
        assert(near(a, c, eps));
    }
    {
        let mut a = vec2::splat(1.0);
        let c = a - 1.0;
        a = a - 1.0;
        assert(near(a, vec2::splat(0.0), eps));
        assert(near(a, c, eps));
    }
    {
        let mut a = vec2::splat(1.0);
        let b = vec2::new(2.0, -1.0);
        let c = a - b;
        a -= b;
        assert(near(a, vec2::new(-1.0, 2.0), eps));
        assert(near(a, c, eps));
    }
    {
        let mut a = vec2::splat(1.0);
        let c = a * 2.0;
        a = a * 2.0;
        assert(near(a, vec2::splat(2.0), eps));
        assert(near(a, c, eps));
    }
    {
        let mut a = vec2::splat(2.0);
        let b = vec2::splat(2.0);
        let c = a / b;
        a /= b;
        assert(near(a, vec2::splat(1.0), eps));
        assert(near(a, c, eps));
    }
    {
        let a = vec2::new(1.0, 2.0);
        let b = vec2::new(4.0, 5.0);
        assert(near(a + b, vec2::new(5.0, 7.0), eps));
        assert(near(b - a, vec2::new(3.0, 3.0), eps));
        assert(near(a * b, vec2::new(4.0, 10.0), eps));
        assert(near(b / a, vec2::new(4.0, 2.5), eps));
        assert(near(a + 1.0, vec2::new(2.0, 3.0), eps));
        assert(near(b - 1.0, vec2::new(3.0, 4.0), eps));
        assert(near(a * 2.0, vec2::new(2.0, 4.0), eps));
        assert(near(b / 2.0, vec2::new(2.0, 2.5), eps));
        assert(near(1.0 + a, vec2::new(2.0, 3.0), eps));
        assert(near(1.0 - b, vec2::new(-3.0, -4.0), eps));
        assert(near(2.0 * a, vec2::new(2.0, 4.0), eps));
        assert(near(2.0 / b, vec2::new(0.5, 2.0 / 5.0), eps));
    }
    {
        let mut a = vec2::new(1.0, 2.0);
        let b = vec2::new(4.0, 5.0);
        a += b;
        assert(near(a, vec2::new(5.0, 7.0), eps));
        a = a + 1.0;
        assert(near(a, vec2::new(6.0, 8.0), eps));
    }
    {
        let a = ivec2::new(1, 2);
        let mut b = ivec2::new(4, 5);
        b -= a;
        assert(b == ivec2::new(3, 3));
        b = b - 1;
        assert(b == ivec2::new(2, 2));
    }
    {
        let mut a = ivec2::new(1, 2);
        let b = ivec2::new(4, 5);
        a *= b;
        assert(a == ivec2::new(4, 10));
        a = a * 2;
        assert(a == ivec2::new(8, 20));
    }
    {
        let a = ivec2::new(1, 2);
        let mut b = ivec2::new(4, 16);
        b /= a;
        assert(b == ivec2::new(4, 8));
        b = b / 2;
        assert(b == ivec2::new(2, 4));
    }
    {
        let a = ivec2::new(1, 2);
        let mut b = ivec2::new(4, 16);
        b = b / a;
        assert(b == ivec2::new(4, 8));
        b = b / 2;
        assert(b == ivec2::new(2, 4));
    }
    {
        let mut b = ivec2::splat(2);
        b = b / b.y();
        assert(b == ivec2::splat(1));
    }
    {
        let a = ivec2::new(1, 2);
        let b = -a;
        assert(b == ivec2::new(-1, -2));
    }
    {
        let mut a = ivec2::new(1, 2);
        a = a - 1;
        let b = a;
        assert(b == ivec2::new(0, 1));
    }
    {
        let mut a = ivec2::new(1, 2);
        let b = a;
        a = a - 1;
        assert(b == ivec2::new(1, 2));
        assert(a == ivec2::new(0, 1));
    }
    {
        let mut a = ivec2::new(1, 2);
        a = a + 1;
        let b = a;
        assert(b == ivec2::new(2, 3));
    }
    {
        let mut a = ivec2::new(1, 2);
        let b = a;
        a = a + 1;
        assert(b == ivec2::new(1, 2));
        assert(a == ivec2::new(2, 3));
    }
}

@test
fn vec2_ctor() {
    let eps = f32::epsilon();
    {
        let a = ivec2::splat(1);
        let b = a;
        assert(a == b);
    }
    {
        let a = vec2 { e: [0.0, 1.0] };
        let v: [vec2; 3] = [a, vec2 { e: [4.0, 5.0] }, vec2::from_array([8.0, 9.0])];
        assert(v[0] == vec2::new(0.0, 1.0));
        assert(v[1] == vec2::new(4.0, 5.0));
        assert(v[2] == vec2::new(8.0, 9.0));
    }
    {
        let a = dvec2 { e: [0.0, 1.0] };
        let v: [dvec2; 3] = [a, dvec2 { e: [4.0, 5.0] }, dvec2::from_array([8.0, 9.0])];
        assert(v[0] == dvec2::new(0.0, 1.0));
        assert(v[2].to_array()[1] == 9.0);
    }
    {
        assert(near(vec2::splat(2.0), vec2::splat(2.0), eps));
        assert(near(vec2::new(2.0, 3.0), vec2::new(2.0, 3.0), eps));
        let d: f64 = 3.0;
        assert(near(vec2::new(2.0, d as f32), vec2::new(2.0, 3.0), eps));
        assert(near(dvec2::splat(2.0).cast::<f32>(), vec2::splat(2.0), eps));
        assert(near(ivec2::splat(2).cast::<f32>(), vec2::splat(2.0), eps));
    }
    {
        let r = vec1::new(1.0);
        let s = vec1::new(2.0);
        let o = vec2::new(1.0, 2.0);
        assert(near(vec2::splat(r.x()), vec2::splat(1.0), 0.0001));
        assert(near(r.concat(s), o, 0.0001));
        assert(near(r.append(2.0), o, 0.0001));
        assert(near(vec1::new(1.0).concat(s), o, 0.0001));
    }
    {
        let r = vec1::new(1.0);
        let s = dvec1::new(2.0).cast::<f32>();
        let o = vec2::new(1.0, 2.0);
        assert(near(vec2::splat(r.x()), vec2::splat(1.0), 0.0001));
        assert(near(r.concat(s), o, 0.0001));
        assert(near(r.append(2.0), o, 0.0001));
        assert(near(vec1::new(1.0).concat(s), o, 0.0001));
    }
}

@test
fn vec2_size() {
    assert_eq(sizeof(vec2), 8);
    assert_eq(sizeof(dvec2), 16);
    assert_eq(vec2::LEN, 2);
    assert_eq(dvec2::LEN, 2);
    assert_eq(L2, 2);
}

@test
fn vec2_operator_increment() {
    let v0 = ivec2::splat(1);
    let mut v1 = v0;
    let mut v2 = v0;
    v1 = v1 + 1;
    let v3 = v1;
    let v4 = v2;
    v2 = v2 + 1;
    assert(v0 == v4);
    assert(v1 == v2);
    assert(v1 == v3);
}

@test
fn vec2_swizzle() {
    let a = vec2::new(1.0, 2.0);
    let b = a.swizzle2::<0, 1>();
    assert(near(a, b, 0.0001));
    assert(b.x() == 1.0);
    assert(b.y() == 2.0);
    assert(a.swizzle2::<1, 0>() == vec2::new(2.0, 1.0));
}

// vec3 and bvec3.

@test
fn vec3_ctor() {
    let eps = f32::epsilon();
    {
        let a = vec3 { e: [0.0, 1.0, 2.0] };
        let v: [vec3; 3] = [a, vec3::new(4.0, 5.0, 6.0), vec3::new(8.0, 9.0, 0.0)];
        assert(v[0] == vec3::new(0.0, 1.0, 2.0));
        assert(v[2].z() == 0.0);
    }
    {
        let a = dvec3 { e: [0.0, 1.0, 2.0] };
        let v: [dvec3; 3] = [a, dvec3::new(4.0, 5.0, 6.0), dvec3::new(8.0, 9.0, 0.0)];
        assert(v[0] == dvec3::new(0.0, 1.0, 2.0));
        assert(v[1].y() == 5.0);
    }
    {
        let a = ivec3::splat(1);
        let b = ivec3::new(1, 1, 1);
        assert(a == b);
    }
    {
        let tests: [ivec3; 4] = [
            ivec2::new(1, 2).append(3),
            ivec1::new(1).concat(ivec2::new(2, 3)),
            ivec3::new(1, 2, 3),
            ivec4::new(1, 2, 3, 4).truncate::<3>(),
        ];
        for t in tests {
            assert(t == ivec3::new(1, 2, 3));
        }
    }
    {
        let r = vec1::new(1.0);
        let s = vec1::new(2.0);
        let t = vec1::new(3.0);
        let o = vec3::new(1.0, 2.0, 3.0);
        assert(near(vec3::splat(r.x()), vec3::splat(1.0), eps));
        assert(near(r.concat(s).concat(t), o, eps));
        assert(near(r.append(2.0).append(3.0), o, eps));
        assert(near(vec1::new(1.0).concat(s).append(3.0), o, eps));
        assert(near(vec1::new(1.0).concat(s).concat(t), o, eps));
        assert(near(r.append(2.0).concat(t), o, eps));
        assert(near(r.concat(s).append(3.0), o, eps));
    }
    {
        let r = vec1::new(1.0);
        let s = dvec1::new(2.0).cast::<f32>();
        let t = vec1::new(3.0);
        let o = vec3::new(1.0, 2.0, 3.0);
        assert(near(vec3::splat(r.x()), vec3::splat(1.0), eps));
        assert(near(r.concat(s).concat(t), o, eps));
        assert(near(r.append(2.0).append(3.0), o, eps));
        assert(near(vec1::new(1.0).concat(s).append(3.0), o, eps));
        assert(near(vec1::new(1.0).concat(s).concat(t), o, eps));
        assert(near(r.append(2.0).concat(t), o, eps));
        assert(near(r.concat(s).append(3.0), o, eps));
    }
}

@test
fn bvec3_ctor() {
    let a = bvec3::splat(true);
    let c = bvec3::splat(false);
    assert(a == bvec3::new(true, true, true));
    assert(c == bvec3::new(false, false, false));
    let g = a == c;
    let h = a != c;
    assert(!g);
    assert(h);
}

@test
fn vec3_operators() {
    let eps = f32::epsilon();
    {
        let a = ivec3::splat(1);
        let b = ivec3::splat(1);
        let r = a != b;
        let s = a == b;
        assert(s && !r);
    }
    {
        let a = vec3::new(1.0, 2.0, 3.0);
        let b = vec3::new(4.0, 5.0, 6.0);
        assert(near(a + b, vec3::new(5.0, 7.0, 9.0), eps));
        assert(near(b - a, vec3::new(3.0, 3.0, 3.0), eps));
        assert(near(a * b, vec3::new(4.0, 10.0, 18.0), eps));
        assert(near(b / a, vec3::new(4.0, 2.5, 2.0), eps));
        assert(near(a + 1.0, vec3::new(2.0, 3.0, 4.0), eps));
        assert(near(b - 1.0, vec3::new(3.0, 4.0, 5.0), eps));
        assert(near(a * 2.0, vec3::new(2.0, 4.0, 6.0), eps));
        assert(near(b / 2.0, vec3::new(2.0, 2.5, 3.0), eps));
        assert(near(1.0 + a, vec3::new(2.0, 3.0, 4.0), eps));
        assert(near(1.0 - b, vec3::new(-3.0, -4.0, -5.0), eps));
        assert(near(2.0 * a, vec3::new(2.0, 4.0, 6.0), eps));
        assert(near(2.0 / b, vec3::new(0.5, 2.0 / 5.0, 2.0 / 6.0), eps));
    }
    {
        let mut a = ivec3::new(1, 2, 3);
        let b = ivec3::new(4, 5, 6);
        a += b;
        assert(a == ivec3::new(5, 7, 9));
        a = a + 1;
        assert(a == ivec3::new(6, 8, 10));
    }
    {
        let a = ivec3::new(1, 2, 3);
        let mut b = ivec3::new(4, 5, 6);
        b -= a;
        assert(b == ivec3::new(3, 3, 3));
        b = b - 1;
        assert(b == ivec3::new(2, 2, 2));
    }
    {
        let mut a = ivec3::new(1, 2, 3);
        let b = ivec3::new(4, 5, 6);
        a *= b;
        assert(a == ivec3::new(4, 10, 18));
        a = a * 2;
        assert(a == ivec3::new(8, 20, 36));
    }
    {
        let a = ivec3::new(1, 2, 3);
        let mut b = ivec3::new(4, 4, 6);
        b /= a;
        assert(b == ivec3::new(4, 2, 2));
        b = b / 2;
        assert(b == ivec3::new(2, 1, 1));
    }
    {
        let a = ivec3::new(1, 2, 3);
        let mut b = ivec3::new(4, 4, 6);
        b = b / a;
        assert(b == ivec3::new(4, 2, 2));
        b = b / 2;
        assert(b == ivec3::new(2, 1, 1));
    }
    {
        let mut b = ivec3::splat(2);
        b = b / b.y();
        assert(b == ivec3::splat(1));
    }
    {
        let a = ivec3::new(1, 2, 3);
        assert(-a == ivec3::new(-1, -2, -3));
    }
    {
        let mut a = ivec3::new(1, 2, 3);
        a = a - 1;
        let b = a;
        assert(b == ivec3::new(0, 1, 2));
    }
    {
        let mut a = ivec3::new(1, 2, 3);
        let b = a;
        a = a - 1;
        assert(b == ivec3::new(1, 2, 3));
        assert(a == ivec3::new(0, 1, 2));
    }
    {
        let mut a = ivec3::new(1, 2, 3);
        a = a + 1;
        let b = a;
        assert(b == ivec3::new(2, 3, 4));
    }
    {
        let mut a = ivec3::new(1, 2, 3);
        let b = a;
        a = a + 1;
        assert(b == ivec3::new(1, 2, 3));
        assert(a == ivec3::new(2, 3, 4));
    }
}

@test
fn vec3_size() {
    assert_eq(sizeof(vec3), 12);
    assert_eq(sizeof(dvec3), 24);
    assert_eq(vec3::LEN, 3);
    assert_eq(dvec3::LEN, 3);
    const L: usize = vec3::LEN;
    assert_eq(L, 3);
}

@test
fn vec3_operator_increment() {
    let v0 = ivec3::splat(1);
    let mut v1 = v0;
    let mut v2 = v0;
    v1 = v1 + 1;
    let v3 = v1;
    let v4 = v2;
    v2 = v2 + 1;
    assert(v0 == v4);
    assert(v1 == v2);
    assert(v1 == v3);
}

@test
fn vec3_swizzle() {
    let eps = f32::epsilon();
    let a = vec3::new(1.0, 2.0, 3.0);
    let b = a.swizzle3::<0, 1, 2>();
    let e = vec1::new(a.x()).concat(a.swizzle2::<1, 2>());
    let g = a.xy().append(a.z());
    let h = a.swizzle2::<0, 1>().append(a.z());
    assert(near(a, b, eps));
    assert(near(a, e, eps));
    assert(near(a, g, eps));
    assert(near(a, h, eps));
}

@test
fn vec3_swizzle3_2() {
    let v = ivec3::new(1, 2, 3);
    let mut u = v.swizzle2::<0, 0>();
    assert(u.x() == 1 && u.y() == 1);
    u = v.swizzle2::<0, 1>();
    assert(u.x() == 1 && u.y() == 2);
    u = v.swizzle2::<0, 2>();
    assert(u.x() == 1 && u.y() == 3);
    u = v.swizzle2::<1, 0>();
    assert(u.x() == 2 && u.y() == 1);
    u = v.swizzle2::<1, 1>();
    assert(u.x() == 2 && u.y() == 2);
    u = v.swizzle2::<1, 2>();
    assert(u.x() == 2 && u.y() == 3);
    u = v.swizzle2::<2, 0>();
    assert(u.x() == 3 && u.y() == 1);
    u = v.swizzle2::<2, 1>();
    assert(u.x() == 3 && u.y() == 2);
    u = v.swizzle2::<2, 2>();
    assert(u.x() == 3 && u.y() == 3);
    u = v.swizzle2::<0, 0>();
    assert(u.r() == 1 && u.g() == 1);
    u = v.swizzle2::<0, 1>();
    assert(u.r() == 1 && u.g() == 2);
    u = v.swizzle2::<0, 2>();
    assert(u.r() == 1 && u.g() == 3);
    u = v.swizzle2::<1, 0>();
    assert(u.r() == 2 && u.g() == 1);
    u = v.swizzle2::<1, 1>();
    assert(u.r() == 2 && u.g() == 2);
    u = v.swizzle2::<1, 2>();
    assert(u.r() == 2 && u.g() == 3);
    u = v.swizzle2::<2, 0>();
    assert(u.r() == 3 && u.g() == 1);
    u = v.swizzle2::<2, 1>();
    assert(u.r() == 3 && u.g() == 2);
    u = v.swizzle2::<2, 2>();
    assert(u.r() == 3 && u.g() == 3);
    assert(v.xy() == ivec2::new(1, 2));
}

@test
fn vec3_swizzle3_3() {
    let v = ivec3::new(1, 2, 3);
    let mut u = v;
    assert(u.x() == 1 && u.y() == 2 && u.z() == 3);
    u = v.swizzle3::<0, 1, 2>();
    assert(u.x() == 1 && u.y() == 2 && u.z() == 3);
    u = v.swizzle3::<2, 1, 0>();
    assert(u.x() == 3 && u.y() == 2 && u.z() == 1);
    assert(u.r() == 3 && u.g() == 2 && u.b() == 1);
}

@test
fn vec3_swizzle_partial() {
    {
        let a = vec3::new(1.0, 2.0, 3.0);
        let b = a.xy().append(3.0);
        assert(near(a, b, f32::epsilon()));
    }
    {
        let a = ivec3::new(1, 2, 3);
        let b = ivec1::new(1).concat(a.swizzle2::<1, 2>());
        assert(a == b);
    }
    {
        let a = ivec3::new(1, 2, 3);
        let b = a.swizzle3::<0, 1, 2>();
        assert(a == b);
    }
}

@test
fn vec3_swizzle_operators() {
    let u = ivec3::new(1, 2, 3);
    let v = ivec3::new(10, 20, 30);
    let mut q = u.swizzle3::<0, 1, 2>() + v.swizzle3::<0, 1, 2>();
    assert(q == u + v);
    q = (u.swizzle3::<2, 1, 0>() + v.swizzle3::<2, 1, 0>()).swizzle3::<2, 1, 0>();
    assert(q == u + v);
    q = u.swizzle3::<0, 1, 2>() - v.swizzle3::<0, 1, 2>();
    assert(q == u - v);
    q = u.swizzle3::<0, 1, 2>() * v.swizzle3::<0, 1, 2>();
    assert(q == u * v);
    q = u.swizzle3::<0, 0, 0>() * v.swizzle3::<0, 0, 0>();
    assert(q == ivec3::splat(u.x() * v.x()));
    q = u.swizzle3::<0, 1, 2>() / v.swizzle3::<0, 1, 2>();
    assert(q == u / v);

    q = u + v.swizzle3::<0, 1, 2>();
    assert(q == u + v);
    q = u - v.swizzle3::<0, 1, 2>();
    assert(q == u - v);
    q = u * v.swizzle3::<0, 1, 2>();
    assert(q == u * v);
    q = u * v.swizzle3::<0, 0, 0>();
    assert(q == v.x() * u);
    q = u / v.swizzle3::<0, 1, 2>();
    assert(q == u / v);

    q = u.swizzle3::<0, 1, 2>() + v;
    assert(q == u + v);
    q = u.swizzle3::<0, 1, 2>() - v;
    assert(q == u - v);
    q = u.swizzle3::<0, 1, 2>() * v;
    assert(q == u * v);
    q = u.swizzle3::<0, 0, 0>() * v;
    assert(q == u.x() * v);
    q = u.swizzle3::<0, 1, 2>() / v;
    assert(q == u / v);
}

@test
fn vec3_swizzle_functions() {
    let a = vec2::new(1.0, 2.0);
    let b = vec2::new(10.0, 20.0);
    assert_eq(dot_of(a, b) as i32, 50);
    assert_eq(dot_of(a.swizzle2::<0, 1>(), b.swizzle2::<0, 1>()) as i32, 50);
    assert_eq(dot_of(a.swizzle2::<0, 1>(), b.swizzle2::<1, 1>()) as i32, 60);

    let u = vec3::new(1.0, 2.0, 3.0);
    let v = vec3::new(10.0, 20.0, 30.0);
    assert_eq(dot_of(u, v) as i32, 140);
    assert_eq(dot_of(u.swizzle3::<0, 1, 2>(), v.swizzle3::<2, 1, 2>()) as i32, 160);
    assert_eq(dot_of(u, v.swizzle3::<2, 1, 0>()) as i32, 100);
    assert_eq(dot_of(u.swizzle3::<0, 1, 2>(), v) as i32, 140);
    assert_eq(dot_of(u.xy(), v.xy()) as i32, 50);

    let s = vec4::new(1.0, 2.0, 3.0, 4.0);
    let t = vec4::new(10.0, 20.0, 30.0, 40.0);
    assert_eq(dot_of(s, t) as i32, 300);
    assert_eq(dot_of(s.swizzle4::<0, 1, 2, 3>(), t.swizzle4::<0, 1, 2, 3>()) as i32, 300);
    assert_eq(dot_of(s.xyz(), t.xyz()) as i32, 140);
}

// vec4 and bvec4.

@test
fn vec4_ctor() {
    let eps = f32::epsilon();
    {
        let a = ivec4::new(1, 2, 3, 4);
        let b = a;
        assert(a == b);
    }
    {
        let a = vec4 { e: [0.0, 1.0, 2.0, 3.0] };
        let v: [vec4; 3] = [a, vec4::new(4.0, 5.0, 6.0, 7.0), vec4::new(8.0, 9.0, 0.0, 1.0)];
        assert(v[0] == vec4::new(0.0, 1.0, 2.0, 3.0));
        assert(v[2].w() == 1.0);
    }
    {
        let a = dvec4 { e: [0.0, 1.0, 2.0, 3.0] };
        let v: [dvec4; 3] = [a, dvec4::new(4.0, 5.0, 6.0, 7.0), dvec4::new(8.0, 9.0, 0.0, 1.0)];
        assert(v[0] == dvec4::new(0.0, 1.0, 2.0, 3.0));
        assert(v[1].z() == 6.0);
    }
    {
        let a = ivec4::splat(1);
        let b = ivec4::new(1, 1, 1, 1);
        assert(a == b);
    }
    {
        let tests: [ivec4; 8] = [
            ivec2::new(1, 2).append(3).append(4),
            ivec1::new(1).concat(ivec2::new(2, 3)).append(4),
            ivec2::new(1, 2).concat(ivec2::new(3, 4)),
            ivec3::new(1, 2, 3).append(4),
            ivec1::new(1).concat(ivec3::new(2, 3, 4)),
            ivec2::new(1, 2).concat(ivec2::new(3, 4)),
            ivec4::new(1, 2, 3, 4),
            ivec4::new(1, 2, 3, 4),
        ];
        for t in tests {
            assert(t == ivec4::new(1, 2, 3, 4));
        }
    }
    {
        let r = vec1::new(1.0);
        let s = vec1::new(2.0);
        let t = vec1::new(3.0);
        let u = vec1::new(4.0);
        let o = vec4::new(1.0, 2.0, 3.0, 4.0);
        let one = vec1::new(1.0);
        assert(near(vec4::splat(r.x()), vec4::splat(1.0), eps));
        assert(near(r.concat(s).concat(t).concat(u), o, eps));
        assert(near(r.append(2.0).append(3.0).append(4.0), o, eps));
        assert(near(one.concat(s).append(3.0).append(4.0), o, eps));
        assert(near(r.concat(s).append(3.0).append(4.0), o, eps));
        assert(near(one.append(2.0).concat(t).append(4.0), o, eps));
        assert(near(r.append(2.0).concat(t).append(4.0), o, eps));
        assert(near(one.concat(s).concat(t).append(4.0), o, eps));
        assert(near(r.concat(s).concat(t).append(4.0), o, eps));
        assert(near(r.append(2.0).append(3.0).concat(u), o, eps));
        assert(near(one.concat(s).append(3.0).concat(u), o, eps));
        assert(near(r.concat(s).append(3.0).concat(u), o, eps));
        assert(near(one.append(2.0).concat(t).concat(u), o, eps));
        assert(near(r.append(2.0).concat(t).concat(u), o, eps));
        assert(near(one.concat(s).concat(t).concat(u), o, eps));
        assert(near(r.concat(s).concat(t).concat(u), o, eps));
    }
    {
        let r = vec1::new(1.0);
        let s = dvec1::new(2.0).cast::<f32>();
        let t = vec1::new(3.0);
        let u = dvec1::new(4.0).cast::<f32>();
        let d: f64 = 2.0;
        let o = vec4::new(1.0, d as f32, 3.0, 4.0);
        let one = vec1::new(1.0);
        assert(near(vec4::splat(r.x()), vec4::splat(1.0), eps));
        assert(near(r.concat(s).concat(t).concat(u), o, eps));
        assert(near(r.append(2.0).append(3.0).append(4.0), o, eps));
        assert(near(one.concat(s).append(3.0).append(4.0), o, eps));
        assert(near(r.concat(s).append(3.0).append(4.0), o, eps));
        assert(near(one.append(2.0).concat(t).append(4.0), o, eps));
        assert(near(r.append(2.0).concat(t).append(4.0), o, eps));
        assert(near(one.concat(s).concat(t).append(4.0), o, eps));
        assert(near(r.concat(s).concat(t).append(4.0), o, eps));
        assert(near(r.append(2.0).append(3.0).concat(u), o, eps));
        assert(near(one.concat(s).append(3.0).concat(u), o, eps));
        assert(near(r.concat(s).append(3.0).concat(u), o, eps));
        assert(near(one.append(2.0).concat(t).concat(u), o, eps));
        assert(near(r.append(2.0).concat(t).concat(u), o, eps));
        assert(near(one.concat(s).concat(t).concat(u), o, eps));
        assert(near(r.concat(s).concat(t).concat(u), o, eps));
    }
    {
        let v1_0 = vec1::new(1.0);
        let v1_1 = vec1::new(2.0);
        let v1_2 = vec1::new(3.0);
        let v1_3 = vec1::new(4.0);
        let v2_0 = vec2::new(1.0, 2.0);
        let v2_1 = vec2::new(2.0, 3.0);
        let v2_2 = vec2::new(3.0, 4.0);
        let v3_0 = vec3::new(1.0, 2.0, 3.0);
        let v3_1 = vec3::new(2.0, 3.0, 4.0);
        let o = vec4::new(1.0, 2.0, 3.0, 4.0);
        assert(near(v1_0.concat(v1_1).concat(v2_2), o, eps));
        assert(near(vec2::new(1.0, 2.0).concat(v2_2), o, eps));
        assert(near(v1_0.append(2.0).concat(v2_2), o, eps));
        assert(near(vec1::new(1.0).concat(v1_1).concat(v2_2), o, eps));
        assert(near(v2_0.concat(v1_2).concat(v1_3), o, eps));
        assert(near(v2_0.append(3.0).concat(v1_3), o, eps));
        assert(near(v2_0.concat(v1_2).append(4.0), o, eps));
        assert(near(v2_0.append(3.0).append(4.0), o, eps));
        assert(near(v3_0.append(4.0), o, eps));
        assert(near(vec1::new(1.0).concat(v3_1), o, eps));
        assert(near(vec1::new(1.0).concat(v2_1).append(4.0), o, eps));
    }
}

@test
fn bvec4_ctor() {
    let a = bvec4::splat(true);
    let c = bvec4::splat(false);
    assert(a == bvec4::new(true, true, true, true));
    assert(c == bvec4::new(false, false, false, false));
    let g = a == c;
    let h = a != c;
    assert(!g);
    assert(h);
}

@test
fn vec4_operators() {
    let eps = f32::epsilon();
    {
        let a = ivec4::splat(1);
        let b = ivec4::splat(1);
        let r = a != b;
        let s = a == b;
        assert(s && !r);
    }
    {
        let a = vec4::new(1.0, 2.0, 3.0, 4.0);
        let b = vec4::new(4.0, 5.0, 6.0, 7.0);
        assert(near(a + b, vec4::new(5.0, 7.0, 9.0, 11.0), eps));
        assert(near(b - a, vec4::new(3.0, 3.0, 3.0, 3.0), eps));
        assert(near(a * b, vec4::new(4.0, 10.0, 18.0, 28.0), eps));
        assert(near(b / a, vec4::new(4.0, 2.5, 2.0, 7.0 / 4.0), eps));
        assert(near(a + 1.0, vec4::new(2.0, 3.0, 4.0, 5.0), eps));
        assert(near(b - 1.0, vec4::new(3.0, 4.0, 5.0, 6.0), eps));
        assert(near(a * 2.0, vec4::new(2.0, 4.0, 6.0, 8.0), eps));
        assert(near(b / 2.0, vec4::new(2.0, 2.5, 3.0, 3.5), eps));
        assert(near(1.0 + a, vec4::new(2.0, 3.0, 4.0, 5.0), eps));
        assert(near(1.0 - b, vec4::new(-3.0, -4.0, -5.0, -6.0), eps));
        assert(near(2.0 * a, vec4::new(2.0, 4.0, 6.0, 8.0), eps));
        assert(near(2.0 / b, vec4::new(0.5, 2.0 / 5.0, 2.0 / 6.0, 2.0 / 7.0), eps));
    }
    {
        let mut a = ivec4::new(1, 2, 3, 4);
        let b = ivec4::new(4, 5, 6, 7);
        a += b;
        assert(a == ivec4::new(5, 7, 9, 11));
        a = a + 1;
        assert(a == ivec4::new(6, 8, 10, 12));
    }
    {
        let a = ivec4::new(1, 2, 3, 4);
        let mut b = ivec4::new(4, 5, 6, 7);
        b -= a;
        assert(b == ivec4::new(3, 3, 3, 3));
        b = b - 1;
        assert(b == ivec4::new(2, 2, 2, 2));
    }
    {
        let mut a = ivec4::new(1, 2, 3, 4);
        let b = ivec4::new(4, 5, 6, 7);
        a *= b;
        assert(a == ivec4::new(4, 10, 18, 28));
        a = a * 2;
        assert(a == ivec4::new(8, 20, 36, 56));
    }
    {
        let a = ivec4::new(1, 2, 2, 4);
        let mut b = ivec4::new(4, 4, 8, 8);
        b /= a;
        assert(b == ivec4::new(4, 2, 4, 2));
        b = b / 2;
        assert(b == ivec4::new(2, 1, 2, 1));
    }
    {
        let a = ivec4::new(1, 2, 2, 4);
        let mut b = ivec4::new(4, 4, 8, 8);
        b = b / a;
        assert(b == ivec4::new(4, 2, 4, 2));
        b = b / 2;
        assert(b == ivec4::new(2, 1, 2, 1));
    }
    {
        let mut b = ivec4::splat(2);
        b = b / b.y();
        assert(b == ivec4::splat(1));
    }
    {
        let a = ivec4::new(1, 2, 3, 4);
        assert(-a == ivec4::new(-1, -2, -3, -4));
    }
    {
        let mut a = ivec4::new(1, 2, 3, 4);
        a = a - 1;
        let b = a;
        assert(b == ivec4::new(0, 1, 2, 3));
    }
    {
        let mut a = ivec4::new(1, 2, 3, 4);
        let b = a;
        a = a - 1;
        assert(b == ivec4::new(1, 2, 3, 4));
        assert(a == ivec4::new(0, 1, 2, 3));
    }
    {
        let mut a = ivec4::new(1, 2, 3, 4);
        a = a + 1;
        let b = a;
        assert(b == ivec4::new(2, 3, 4, 5));
    }
    {
        let mut a = ivec4::new(1, 2, 3, 4);
        let b = a;
        a = a + 1;
        assert(b == ivec4::new(1, 2, 3, 4));
        assert(a == ivec4::new(2, 3, 4, 5));
    }
}

@test
fn vec4_equal() {
    {
        let a = uvec4::new(1, 2, 3, 4);
        let b = uvec4::new(1, 2, 3, 4);
        assert(a == b);
        assert(!(a != b));
    }
    {
        let a = ivec4::new(1, 2, 3, 4);
        let b = ivec4::new(1, 2, 3, 4);
        assert(a == b);
        assert(!(a != b));
    }
}

@test
fn vec4_size() {
    assert_eq(sizeof(vec4), 16);
    assert_eq(sizeof(dvec4), 32);
    assert_eq(vec4::LEN, 4);
    assert_eq(dvec4::LEN, 4);
}

@test
fn vec4_swizzle_partial() {
    let eps = f32::epsilon();
    let a = vec4::new(1.0, 2.0, 3.0, 4.0);
    assert(near(a, a.xy().concat(a.swizzle2::<2, 3>()), eps));
    assert(near(a, a.xy().append(3.0).append(4.0), eps));
    assert(near(a, vec1::new(1.0).concat(a.swizzle2::<1, 2>()).append(4.0), eps));
    assert(near(a, vec2::new(1.0, 2.0).concat(a.swizzle2::<2, 3>()), eps));
    assert(near(a, a.xyz().append(4.0), eps));
    assert(near(a, vec1::new(1.0).concat(a.swizzle3::<1, 2, 3>()), eps));
}

@test
fn vec4_swizzle() {
    {
        let a = ivec4::new(1, 2, 3, 4);
        let b = a.swizzle4::<0, 1, 2, 3>();
        let e = ivec1::new(a.x()).concat(a.swizzle3::<1, 2, 3>());
        let g = a.xyz().append(a.w());
        let h = a.swizzle3::<0, 1, 2>().append(a.w());
        let i = a.xy().concat(a.swizzle2::<2, 3>());
        let k = ivec2::new(a.x(), a.y()).concat(a.swizzle2::<2, 3>());
        let l = ivec1::new(a.x()).concat(a.swizzle2::<1, 2>()).append(a.w());
        let m = a.xy().append(a.z()).append(a.w());
        assert(a == b);
        assert(a == e);
        assert(a == g);
        assert(a == h);
        assert(a == i);
        assert(a == k);
        assert(a == l);
        assert(a == m);
    }
    {
        let eps = f32::epsilon();
        let a = vec4::new(1.0, 2.0, 3.0, 4.0);
        let b = a.swizzle4::<0, 1, 2, 3>();
        let e = vec1::new(a.x()).concat(a.swizzle3::<1, 2, 3>());
        let g = a.xyz().append(a.w());
        let i = a.xy().concat(a.swizzle2::<2, 3>());
        let k = vec2::new(a.x(), a.y()).concat(a.swizzle2::<2, 3>());
        let l = vec1::new(a.x()).concat(a.swizzle2::<1, 2>()).append(a.w());
        let m = a.xy().append(a.z()).append(a.w());
        assert(near(a, b, eps));
        assert(near(a, e, eps));
        assert(near(a, g, eps));
        assert(near(a, i, eps));
        assert(near(a, k, eps));
        assert(near(a, l, eps));
        assert(near(a, m, eps));
        assert(a.r() == 1.0 && a.g() == 2.0 && a.b() == 3.0 && a.a() == 4.0);
    }
}

@test
fn vec4_simd() {
    let a = vec4::new(3.0, 1.0, 4.0, 1.0);
    let b = vec4::new(5.0, 9.0, 2.0, 6.0);
    let c = b * a;
    let d = a + c;
    for i in 0..vec4::LEN {
        assert(d[i].greater_equal(0.0));
    }
}

@test
fn vec4_operator_increment() {
    let v0 = ivec4::splat(1);
    let mut v1 = v0;
    let mut v2 = v0;
    v1 = v1 + 1;
    let v3 = v1;
    let v4 = v2;
    v2 = v2 + 1;
    assert(v0 == v4);
    assert(v1 == v2);
    assert(v1 == v3);
}

// Bits of the constructed vectors.

@test
fn vec1_ctor_bits() {
    pack_bits::<1>();
}

@test
fn vec2_ctor_bits() {
    pack_bits::<2>();
}

@test
fn vec3_ctor_bits() {
    pack_bits::<3>();
}

@test
fn vec4_ctor_bits() {
    pack_bits::<4>();
}

// Casts.

@test
fn vec2_cast() {
    let eps = f32::epsilon();
    let a = vec2::new(1.0, 2.0);
    let e: vec2 = a;
    assert(near(a, e, eps));
    assert(near(a.cast::<f32>(), a, eps));
    let k = vec2::splat(7.8);
    let l = vec2::new(7.8, 7.8);
    assert(near(k, l, eps));
}

@test
fn vec3_cast() {
    let a = vec3::new(1.0, 2.0, 3.0);
    let e: vec3 = a;
    assert(near(a, e, f32::epsilon()));
    assert(near(a.cast::<f32>(), a, f32::epsilon()));
}

@test
fn vec4_cast() {
    let a = vec4::new(1.0, 2.0, 3.0, 4.0);
    let e: vec4 = a;
    assert(near(a, e, f32::epsilon()));
    assert(near(a.cast::<f32>(), a, f32::epsilon()));
}

@test
fn vec_std_copy() {
    let mut high4 = Vector::<dvec4>::new();
    let mut high3 = Vector::<dvec3>::new();
    let mut high2 = Vector::<dvec2>::new();
    for i in 0..64 {
        let x = i as f64;
        high4.push(dvec4::new(x, x + 0.5, -x, 2.0));
        high3.push(dvec3::new(x, x + 0.5, -x));
        high2.push(dvec2::new(x, x + 0.5));
    }
    let mut medium4 = Vector::<vec4>::new();
    let mut medium3 = Vector::<vec3>::new();
    let mut medium2 = Vector::<vec2>::new();
    for i in 0..high4.len() {
        medium4.push(high4[i].cast::<f32>());
        medium3.push(high3[i].cast::<f32>());
        medium2.push(high2[i].cast::<f32>());
    }
    assert(medium4[0] == vec4::new(0.0, 0.5, 0.0, 2.0));
    assert(medium3[63] == vec3::new(63.0, 63.5, -63.0));
    assert(medium2[10] == vec2::new(10.0, 10.5));
    let v1 = dvec4::splat(0.25);
    let v2: vec4 = v1.cast::<f32>();
    assert(v2 == vec4::splat(0.25));
}

// Component count.

@test
fn vec_length() {
    assert_eq(vec2::LEN, 2);
    assert_eq(vec3::LEN, 3);
    assert_eq(vec4::LEN, 4);
    assert_eq(ivec2::LEN, 2);
    assert_eq(ivec3::LEN, 3);
    assert_eq(ivec4::LEN, 4);
    assert_eq(uvec2::LEN, 2);
    assert_eq(uvec3::LEN, 3);
    assert_eq(uvec4::LEN, 4);
    assert_eq(dvec2::LEN, 2);
    assert_eq(dvec3::LEN, 3);
    assert_eq(dvec4::LEN, 4);
}

// Edge cases: zero sign, IEEE equality, wrapping, indexing and constant initializers.

@test
fn vec_neg_zero_sign() {
    // Negation of a vec1 or vec2 negates each component; negation of a vec3 or vec4 computes 0 - v.
    let z3 = -vec3::new(0.0, 0.0, 0.0);
    let z4 = -vec4::splat(0.0);
    let z1 = -vec1::new(0.0);
    let z2 = -vec2::splat(0.0);
    let d3 = -dvec3::splat(0.0);
    let d2 = -dvec2::splat(0.0);
    for i in 0..vec3::LEN {
        assert_eq(z3[i].to_bits(), 0);
        assert_eq(d3[i].to_bits(), 0);
    }
    for i in 0..vec4::LEN {
        assert_eq(z4[i].to_bits(), 0);
    }
    assert_eq(z1.x().to_bits(), 0x80000000);
    assert_eq(z2.x().to_bits(), 0x80000000);
    assert_eq(z2.y().to_bits(), 0x80000000);
    assert_eq(d2.y().to_bits(), 0x8000000000000000);
    assert(-vec3::new(1.0, -2.0, 0.5) == vec3::new(-1.0, 2.0, -0.5));
}

@test
fn vec_float_equality_is_ieee() {
    let n = f32::nan();
    assert(vec2::new(n, 1.0) != vec2::new(n, 1.0));
    assert(!(vec2::new(n, 1.0) == vec2::new(n, 1.0)));
    assert(vec2::new(0.0, 1.0) == vec2::new(-0.0, 1.0));
    assert(dvec3::splat(-0.0) == dvec3::splat(0.0));
}

@test
fn vec_u8_wraps() {
    let a = u8vec2::new(200, 255);
    assert(a + u8vec2::new(100, 1) == u8vec2::new(44, 0));
    assert(u8vec2::new(1, 0) - u8vec2::new(2, 1) == u8vec2::new(255, 255));
    assert(u8vec2::new(16, 20) * 16u8 == u8vec2::new(0, 64));
    assert(-u8vec2::new(1, 0) == u8vec2::new(255, 0));
    assert(u8vec2::new(1, 3) << 7u8 == u8vec2::new(128, 128));
    assert(u8vec2::new(1, 255) << 8u8 == u8vec2::new(0, 0));
    assert(U8W == u8vec2::new(4, 13));
}

@test
fn vec_u16_wraps() {
    assert(u16vec3::new(65535, 1, 0) + 1u16 == u16vec3::new(0, 2, 1));
    assert(u16vec3::splat(0) - u16vec3::new(1, 2, 3) == u16vec3::new(65535, 65534, 65533));
    assert(u16vec3::splat(256) * u16vec3::new(256, 255, 1) == u16vec3::new(0, 65280, 256));
    assert(-u16vec3::new(1, 0, 65535) == u16vec3::new(65535, 0, 1));
}

@test
fn vec_u32_wraps() {
    assert(uvec4::new(4294967295, 1, 0, 7) + 1u32 == uvec4::new(0, 2, 1, 8));
    assert(uvec4::splat(0) - 1u32 == uvec4::splat(4294967295));
    assert(uvec4::splat(65536) * 65536u32 == uvec4::splat(0));
    assert(-uvec4::new(1, 0, 2, 4294967295) == uvec4::new(4294967295, 0, 4294967294, 1));
}

@test
fn vec_u64_wraps() {
    let m = u64::MAX;
    assert(u64vec2::new(m, 5) + u64vec2::new(1, 1) == u64vec2::new(0, 6));
    assert(u64vec2::splat(0) - u64vec2::new(1, 0) == u64vec2::new(m, 0));
    assert(u64vec2::splat(1u64 << 32) * (1u64 << 32) == u64vec2::splat(0));
    assert(-u64vec2::new(1, 0) == u64vec2::new(m, 0));
}

@test
fn vec_i8_wraps() {
    assert(i8vec4::new(127, -128, 1, 0) + 1i8 == i8vec4::new(-128, -127, 2, 1));
    assert(i8vec4::new(-128, 0, 1, 127) - 1i8 == i8vec4::new(127, -1, 0, 126));
    assert(i8vec4::splat(16) * i8vec4::new(8, 16, -8, 2) == i8vec4::new(-128, 0, -128, 32));
    assert(-i8vec4::new(-128, 1, 0, 127) == i8vec4::new(-128, -1, 0, -127));
    assert(i8vec4::new(64, 1, 3, 0) << 1i8 == i8vec4::new(-128, 2, 6, 0));
}

@test
fn vec_i16_wraps() {
    assert(i16vec2::new(32767, -32768) + i16vec2::new(1, -1) == i16vec2::new(-32768, 32767));
    assert(i16vec2::splat(256) * 128i16 == i16vec2::splat(-32768));
    assert(-i16vec2::new(-32768, 5) == i16vec2::new(-32768, -5));
}

@test
fn vec_integer_operators() {
    let a = ivec3::new(7, -7, 12);
    let b = ivec3::new(3, 3, 5);
    assert(a % b == ivec3::new(1, -1, 2));
    assert(a % 4 == ivec3::new(3, -3, 0));
    assert(13 % b == ivec3::new(1, 1, 3));
    let u = uvec4::new(0xF0, 0x0F, 0xFF, 0);
    let v = uvec4::new(0x3C, 0x3C, 0x0F, 1);
    assert((u & v) == uvec4::new(0x30, 0x0C, 0x0F, 0));
    assert((u | v) == uvec4::new(0xFC, 0x3F, 0xFF, 1));
    assert((u ^ v) == uvec4::new(0xCC, 0x33, 0xF0, 1));
    assert((u & 0x0Fu32) == uvec4::new(0, 0x0F, 0x0F, 0));
    assert((u | 1u32) == uvec4::new(0xF1, 0x0F, 0xFF, 1));
    assert((u ^ 0xFFu32) == uvec4::new(0x0F, 0xF0, 0, 0xFF));
    assert((0x0F & u) == uvec4::new(0, 0x0F, 0x0F, 0));
    assert((1 | u) == uvec4::new(0xF1, 0x0F, 0xFF, 1));
    assert((0xFF ^ u) == uvec4::new(0x0F, 0xF0, 0, 0xFF));
    assert(~uvec2::new(0, 0xFFFFFFFF) == uvec2::new(0xFFFFFFFF, 0));
    assert(~ivec2::new(0, -1) == ivec2::new(-1, 0));
    let s = uvec3::new(1, 2, 3);
    assert(uvec3::splat(1) << s == uvec3::new(2, 4, 8));
    assert(s << 2u32 == uvec3::new(4, 8, 12));
    assert(1 << s == uvec3::new(2, 4, 8));
    assert(uvec3::splat(64) >> s == uvec3::new(32, 16, 8));
    assert(uvec3::new(4, 8, 12) >> 2u32 == s);
    assert(64 >> s == uvec3::new(32, 16, 8));
    assert(ivec2::new(-8, 8) >> 1 == ivec2::new(-4, 4));
    let mut c = ivec2::new(5, 6);
    c %= ivec2::new(3, 4);
    assert(c == ivec2::new(2, 2));
    c = c << ivec2::new(1, 2);
    assert(c == ivec2::new(4, 8));
}

@test
fn vec_index() {
    let mut v = vec3::new(1.0, 2.0, 3.0);
    assert(v[0] == 1.0);
    assert(v[2] == 3.0);
    v[1] = 5.0;
    assert(v == vec3::new(1.0, 5.0, 3.0));
    let s = v[1..3];
    assert_eq(s.len(), 2);
    assert(s[0] == 5.0);
    assert(s[1] == 3.0);
    assert_eq(v[0..=2].len(), 3);
    let w = &mut v[2..3];
    w[0] = 7.0;
    assert(v == vec3::new(1.0, 5.0, 7.0));
}

@test(should_panic)
fn vec_index_out_of_range_traps() {
    let v = vec3::splat(1.0);
    let i = vec3::LEN;
    let _ = v[i];
}

@test(should_panic)
fn vec_index_mut_out_of_range_traps() {
    let mut v = ivec2::splat(1);
    let i = ivec2::LEN;
    v[i] = 3;
}

@test(should_panic)
fn vec_index_range_out_of_range_traps() {
    let v = vec4::splat(1.0);
    let s = v.index_range(2..5);
    assert_eq(s.len(), 3);
}

@test
fn vec_const_initializers() {
    assert(V3 == vec3::new(2.0, 4.0, 6.0));
    assert(IV4 == ivec4::new(1, 2, 3, 4));
    assert(SW == vec2::new(6.0, 2.0));
    assert(NEG == vec4::new(-1.0, 2.0, 0.0, -4.0));
    assert_eq(NEG.z().to_bits(), 0);
    const Z: dvec2 = dvec2::zero();
    assert(Z == dvec2::splat(0.0));
}

// `len()` is the component count. On bool vectors, `&` and `|` are logical and and or per component.
@test
fn vec_len_and_bool_ops() {
    assert_eq(vec3::splat(1.0).len(), 3);
    assert_eq(bvec2::splat(true).len(), 2);
    assert_eq(ivec4::splat(0).len(), 4);
    let a = bvec2::new(true, false);
    let b = bvec2::new(true, true);
    assert((a & b) == bvec2::new(true, false));
    assert((a | bvec2::splat(false)) == a);
    assert(
        (bvec4::new(false, true, false, true) | bvec4::new(true, false, false, true)) == bvec4::new(
            true,
            true,
            false,
            true,
        ),
    );
    assert((ivec2::new(6, 5) & ivec2::new(3, 3)) == ivec2::new(2, 1));
}
