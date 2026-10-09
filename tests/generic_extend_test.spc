// Generic extends (`extend<T: B> T as I<..>`, the conformance of every type its bounds admit) and
// extend parameters only a conformance's interface arguments name (`extend<const N: usize> f32 as
// Mul<V<N>>`): methods, operators, bounds, `dyn` values, inherited defaults, constants, associated
// types and path calls, inlined and called alike; and the declaration and overlap errors.
import tests::harness as h;

const PROGRAM: str = M"(interface Lane {}
extend f32 as Lane {}
extend i64 as Lane {}
struct P { pub x: i32 }
extend P as Lane {}
struct G<T> { pub v: T }
extend<T> G<T> as Lane {}
interface Twice {
    fn twice(self: &Self) i64;
    fn base(self: &Self) i64 { return 5; }
}
extend<T: Lane> T as Twice {
    fn twice(self: &Self) i64 {
        let mut s: i64 = 0;
        for i in 0..10 {
            if i % 3 == 1 {
                s += 1;
            }
        }
        return s - 1;
    }
}
interface Out { type O; fn o(self: &Self) Self::O; }
extend<T: Lane + Copy> T as Out {
    type O = T;
    fn o(self: &Self) T { return *self; }
}
interface Pair { fn pair<U: Copy>(self: &Self, u: U) U; }
extend<T: Lane + Copy> T as Pair {
    fn pair<U: Copy>(self: &Self, u: U) U { return u; }
}
struct V<T, const N: usize> { pub x: [T; N] }
extend<T: Lane + Copy, const N: usize> T as Mul<V<T, N>> {
    type Output = V<T, N>;
    fn mul(self: &Self, o: &V<T, N>) V<T, N> {
        let mut r = *o;
        for i in 0..N {
            unsafe r.x[i] = *self;
        }
        return r;
    }
}
struct W<const N: usize> { pub y: [f32; N] }
extend<const N: usize> f32 as Mul<W<N>> {
    type Output = f32;
    fn mul(self: &Self, o: &W<N>) f32 { return *self + N as f32; }
}
fn via_bound<U: Twice>(u: U) i64 { return u.twice(); }
fn outv<U: Out>(u: U) U::O { return u.o(); }
fn scale<U: Mul<V<f32, 3>, Output = V<f32, 3>>>(u: U, v: V<f32, 3>) V<f32, 3> { return u * v; }
fn twice_of<T: Lane>(t: T) i64 { return t.twice(); }
const C: i64 = 1.5f32.twice() + via_bound(2.5f32);
const E: f32 = outv(2.5f32);
fn main(args: Vector<str>) i32 {
    let k = args.len() as f32;
    let p = P { x: 1 };
    let g = G::<u8> { v: 1 };
    let d: &dyn Twice = &g;
    let a = k.twice() + 7i64.twice() + p.twice() + d.twice() + g.base() + 2i64.base() + C;
    let b = via_bound(P { x: 2 }) + twice_of(k) + f32::twice(&k);
    let v = V::<f32, 3> { x: [1.0, 2.0, 3.0] };
    let w = 4.0f32 * v;
    let s = scale(2.0f32, v);
    let n = 2.0f32 * W::<4> { y: [0.0; 4] };
    let o = outv(k) + E;
    let q = k.pair(7u8) as i64 + 3i64.pair(2i64);
    if a != 22 || b != 6 || w.x[2] != 4.0 || s.x[1] != 2.0 || n != 6.0 || o != 3.5 || q != 9 {
        return 1;
    }
    return 0;
}
)";

@test
fn a_generic_conformance_reaches_every_type_its_bounds_admit() {
    h::expect_exit("generic conformances", PROGRAM, 0);
    h::expect_same_output("inlined and called", PROGRAM, ["SC_INLINE=0"], []);
}

@test
fn declarations_are_checked() {
    let cases: [[str; 2]; 4] = [
        [
            "interface I {}\nextend<T: I> T { fn f(self: &Self) i32 { return 0; } }\n",
            "an extend whose target is one of its generic parameters must be a conformance",
        ],
        [
            "interface I {}\nextend<T: I> T as Free { fn free(self: &mut Self) {} }\n",
            "'Free' cannot be implemented for every type that satisfies a bound",
        ],
        [
            "interface J { fn g(self: &Self) i32; }\nstruct P { pub x: i32 }\nextend<const M: usize> P as J { pub fn g(self: &P) i32 { return M as i32; } }\n",
            "the generic parameter 'M' of this extend appears neither in its target nor in its interface's arguments",
        ],
        [
            "interface I {}\nextend f32 as I {}\ninterface J { fn g(self: &Self) i32; }\nextend<T: I> T as J { fn g(self: &Self) i32 { return 1; } }\nextend f32 as J { fn g(self: &Self) i32 { return 2; } }\n",
            "conflicting conformances to 'J': a generic conformance also applies to this type",
        ],
    ];
    for c in cases {
        let mut src = String::from_str(c[0]);
        src.push_str("fn main() i32 {\n    return 0;\n}\n");
        h::expect_build_err(c[1], src.as_str(), c[1]);
    }
    // Two generic conformances of one interface whose arguments meet for a type, and a type the
    // bounds do not admit.
    h::expect_build_err(
        "two generic conformances",
        "interface I {}\ninterface J { fn g(self: &Self) i32; }\nextend<T: I> T as J { fn g(self: &Self) i32 { return 1; } }\nextend<U: Copy> U as J { fn g(self: &Self) i32 { return 2; } }\nfn main() i32 {\n    return 0;\n}\n",
        "conflicting conformances to 'J'",
    );
    h::expect_build_err(
        "a type outside the bounds",
        "interface I {}\nextend f32 as I {}\ninterface J { fn g(self: &Self) i32; }\nextend<T: I> T as J { fn g(self: &Self) i32 { return 1; } }\nfn h<U: J>(u: U) i32 { return u.g(); }\nfn main() i32 {\n    return h(3u8);\n}\n",
        "type 'u8' does not satisfy bound 'J'",
    );
    h::expect_build_err(
        "a method of a generic conformance outside its bounds",
        "interface I {}\nextend f32 as I {}\ninterface J { fn g(self: &Self) i32; }\nextend<T: I> T as J { fn g(self: &Self) i32 { return 1; } }\nfn main() i32 {\n    return 2i32.g();\n}\n",
        "cannot call 'i32::g': unsatisfied interface bounds",
    );
}

// A parameter only an array length of the interface's arguments names: through a direct call, a
// bound, an associated type and a constant.
@test
fn an_array_length_parameter_binds() {
    let src = M"(extend<const N: usize> f32 as Mul<[f32; N]> {
    type Output = [f32; N];
    fn mul(self: &Self, o: &[f32; N]) [f32; N] {
        let mut r = *o;
        for i in 0..N {
            unsafe r[i] = *self * unsafe o[i];
        }
        return r;
    }
}
fn g<U: Mul<[f32; 4], Output = [f32; 4]>>(u: U, a: [f32; 4]) [f32; 4] { return u * a; }
fn h<U: Mul<[f32; 4]>>(u: U, a: [f32; 4]) U::Output { return u * a; }
const C: [f32; 4] = g(2.0f32, [1.0, 2.0, 3.0, 4.0]);
fn main() i32 {
    let r = g(3.0f32, [1.0; 4]);
    let s = h(2.0f32, [1.0; 4]);
    let d = 2.0f32 * [1.0f32, 2.0];
    return (r[3] != 3.0 || s[0] != 2.0 || C[3] != 8.0 || d[1] != 4.0) as i32;
}
)";
    h::expect_exit("an array length parameter", src, 0);
    h::expect_same_output("inlined and called", src, ["SC_INLINE=0"], []);
}

// An instance a generic conformance gives only through a bound or a `dyn` value is checked like any
// other: its array length out of range is a compile error located at the interface call, and no C
// is compiled.
@test
fn instances_through_bounds_and_dyn_are_checked() {
    let decl = "interface Lane {}\nextend f32 as Lane {}\ninterface Take<R> { fn take(self: &Self, r: &R) usize; }\nextend<T: Lane, const N: usize> T as Take<[f32; N]> {\n    fn take(self: &Self, r: &[f32; N]) usize {\n        let b: [u8; N - 2] = unsafe zeroed::<[u8; N - 2]>();\n        return unsafe b[0] as usize;\n    }\n}\n";
    let mut bound = String::from_str(decl);
    bound.push_str(
        "fn via<U: Take<[f32; 1]>>(u: U) usize { return u.take(&[1.0]); }\nfn main() i32 {\n    return via(1.0f32) as i32;\n}\n",
    );
    h::expect_build_err("through a bound", bound.as_str(), "array length N - 2 is negative (-1) for N = 1");
    h::expect_build_err("the bound call demands it", bound.as_str(), "demanded here");
    let mut dyn_ = String::from_str(decl);
    dyn_.push_str(
        "fn main() i32 {\n    let x = 1.0f32;\n    let d: &dyn Take<[f32; 1]> = &x;\n    return d.take(&[1.0]) as i32;\n}\n",
    );
    h::expect_build_err("through dyn", dyn_.as_str(), "array length N - 2 is negative (-1) for N = 1");
    h::expect_build_err("the dyn call demands it", dyn_.as_str(), "demanded here");
}

// Reflection lists the methods of the generic conformances whose bounds the type satisfies, a
// `Copy` bound included.
@test
fn reflection_lists_applying_generic_conformances() {
    let src = M"(interface Lane {}
struct P { pub x: i32 }
extend P as Lane {}
struct Q { pub s: String }
extend Q as Lane {}
interface Twice { fn twice(self: &Self) i64; }
extend<T: Lane> T as Twice {
    pub fn twice(self: &Self) i64 { return 2; }
}
interface Dup { fn dup(self: &Self) Self; }
extend<T: Lane + Copy> T as Dup {
    pub fn dup(self: &Self) T { return *self; }
}
fn has<T>(name: str) bool {
    return type_info::<T>().method(name).is_some();
}
fn main() i32 {
    if !has::<P>("twice") || !has::<P>("dup") || !has::<Q>("twice") || has::<Q>("dup") || has::<i8>("twice") {
        return 1;
    }
    return 0;
}
)";
    h::expect_exit("generic conformance methods", src, 0);
}

// An interface-qualified call takes its implementer from the receiver argument: a conformance's own
// method, an inherited default, a type parameter's bound, and the conformance the expected result
// chooses among several.
@test
fn an_interface_qualified_call_finds_its_implementer() {
    let src = M"(interface Lane {}
extend f32 as Lane {}
interface Twice {
    fn twice(self: &Self) i64;
    fn base(self: &Self) i64 { return 5; }
}
extend<T: Lane> T as Twice {
    fn twice(self: &Self) i64 { return 2; }
}
struct P { pub x: i64 }
extend P as Twice {
    fn twice(self: &Self) i64 { return self.x; }
}
interface Conv<R> {
    fn conv(self: &Self) R;
    fn dbl(self: &Self) R { return self.conv(); }
}
extend P as Conv<i64> { fn conv(self: &Self) i64 { return 40; } }
extend P as Conv<u8> { fn conv(self: &Self) u8 { return 7; } }
fn gen<T: Twice>(t: &T) i64 { return Twice::twice(t) + Twice::base(t); }
fn main() i32 {
    let x = 0.5f32;
    let p = P { x: 9 };
    let a = Twice::twice(&x) + Twice::base(&x) + Twice::twice(&p) + gen(&p);
    let c: i64 = Conv::conv(&p);
    let d: u8 = Conv::dbl(&p);
    return (a != 30 || c != 40 || d != 7) as i32;
}
)";
    h::expect_exit("interface-qualified calls", src, 0);
    h::expect_build_err(
        "several conformances, no expected type",
        "interface Conv<R> { fn conv(self: &Self) R; }\nstruct P { pub x: i64 }\nextend P as Conv<i64> { fn conv(self: &Self) i64 { return 40; } }\nextend P as Conv<u8> { fn conv(self: &Self) u8 { return 7; } }\nfn main() i32 {\n    let p = P { x: 1 };\n    let _ = Conv::conv(&p);\n    return 0;\n}\n",
        "ambiguous call to 'conv': 'P' conforms to 'Conv' with several arguments that fit",
    );
}
