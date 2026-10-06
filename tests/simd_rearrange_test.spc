// Lane rearrangement (std/simd.spc): `swizzle` and `shuffle` over constant index lists and the
// compositions written over them, the run-time `swizzle_or_zero` and `swizzle_checked`, and `compress`
// and `expand`. Each runs against a scalar lane loop in one program, as a constant against its run
// time, and the index list's rules are diagnosed at compile time or, over a generic parameter, per
// instance.
import tests::harness as h;

// Constant lists: identity, reverse, broadcast, the last lane of each operand, results narrower and
// wider than the operands (a list past 16 lanes is a table loop), and every composition against the
// lane rule it is defined by.
@test
fn constant_index_lists_pick_their_lanes() {
    let src = M"(import std::simd;
fn ck<T: SimdElement, const N: usize>(got: Simd<T, N>, want: [T; N]) bool {
    return got.equal(Simd::<T, N>::from_array(want)).all();
}
fn same<T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) bool {
    return a.equal(b).all();
}
// Lane `i` of `a ++ b`.
fn ab<T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>, i: usize) T {
    if i < N {
        return a[i];
    }
    return b[i - N];
}
fn comp<T: SimdElement, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) i32 {
    let mut rev = a;
    let mut rl = a;
    let mut rr = a;
    let mut lo = a;
    let mut hi = a;
    let mut ev = a;
    let mut od = a;
    for i in 0..N {
        rev[i] = a[N - 1 - i];
        rl[i] = a[(i + 3) % N];
        rr[i] = a[(i + N - 3 % N) % N];
        lo[i] = ab(a, b, i / 2 + i % 2 * N);
        hi[i] = ab(a, b, N / 2 + i / 2 + i % 2 * N);
        ev[i] = ab(a, b, 2 * i);
        od[i] = ab(a, b, 2 * i + 1);
    }
    let (z0, z1) = simd::zip(a, b);
    let (u0, u1) = simd::unzip(a, b);
    if !same(simd::reverse(a), rev) || !same(simd::rotate_lanes_left::<3>(a), rl) || !same(simd::rotate_lanes_right::<3>(a), rr) {
        return 1;
    }
    if !same(simd::interleave_low(a, b), lo) || !same(simd::interleave_high(a, b), hi) || !same(z0, lo) || !same(z1, hi) {
        return 2;
    }
    if !same(simd::deinterleave_even(a, b), ev) || !same(simd::deinterleave_odd(a, b), od) || !same(u0, ev) || !same(u1, od) {
        return 3;
    }
    return 0;
}
fn main(args: Vector<str>) i32 {
    let k = args.len() as i32;
    let v = simd::iota::<i32, 4>() + Simd::<i32, 4>::splat(k * 10);
    let w = simd::iota::<i32, 4>() + Simd::<i32, 4>::splat(k * 100);
    if !ck(simd::swizzle(v, [0, 1, 2, 3]), v.to_array()) || !ck(simd::swizzle(v, [3, 2, 1, 0]), [v[3], v[2], v[1], v[0]]) {
        return 10;
    }
    if !ck(simd::swizzle(v, [3, 3]), [v[3], v[3]]) || !ck(simd::shuffle(v, w, [7, 3, 4, 0]), [w[3], v[3], w[0], v[0]]) {
        return 11;
    }
    if !ck(simd::shuffle(v, w, [0, 4, 1, 5, 2, 6, 3, 7]), [v[0], w[0], v[1], w[1], v[2], w[2], v[3], w[3]]) {
        return 12;
    }
    let b = simd::iota::<u8, 16>() + Simd::<u8, 16>::splat(k as u8);
    let wide = simd::swizzle(b, [15, 0, 14, 1, 13, 2, 12, 3, 11, 4, 10, 5, 9, 6, 8, 7, 15, 0, 14, 1, 13, 2, 12, 3, 11, 4, 10, 5, 9, 6, 8, 7]);
    for i in 0..32usize {
        let j = i % 16;
        if wide[i] != b[if j % 2 == 0 {
            15 - j / 2;
        } else {
            j / 2;
        }] {
            return 13;
        }
    }
    let r = comp(v, w) + comp(simd::iota::<f64, 8>(), Simd::<f64, 8>::splat(-0.5)) + comp(b, b + b);
    return r + comp(simd::iota::<i64, 2>(), Simd::<i64, 2>::splat(9));
}
)";
    h::expect_run("constant index lists", src, "", "");
}

// A list must be a constant, its indexes below the operands' lanes, and its length a valid lane
// count; a list over a generic parameter is checked per instance; and the operation has no value.
@test
fn index_list_rules_are_diagnosed() {
    let pre = "import std::simd;\nconst fn mk<T: Copy>(x: usize) [usize; 2] {\n    return [x, 0];\n}\nfn f(v: Simd<i32, 4>, k: usize) {\n    ";
    let cases: [[str; 2]; 8] = [
        ["let _ = simd::swizzle(v, [k, 0]);", "the index list of `swizzle` must be a compile-time constant"],
        ["let _ = simd::swizzle(v, mk::<u8>(k));", "the index list of `swizzle` must be a compile-time constant"],
        ["let _ = simd::swizzle(v, [0, 4]);", "names lane 4 at position 1, past the 4 lanes of its operands"],
        ["let _ = simd::shuffle(v, v, [0, 8]);", "names lane 8 at position 1, past the 8 lanes of its operands"],
        ["let _ = simd::swizzle(v, [0, 1, 2]);", "`Simd<i32, 3>` needs a power-of-two lane count"],
        ["let _ = simd::swizzle(v, [0; 32]);", "is 1024 bits wide; the limit is 512 bits"],
        [
            "let e: [usize; 0] = []; let _ = simd::swizzle(v, e);",
            "the index list of `swizzle` must be a compile-time constant",
        ],
        ["let _ = simd::swizzle::<i32, 4, 2>;", "`swizzle` takes a constant index list and cannot be named as a value"],
    ];
    for c in cases {
        let mut src = String::from_str(pre);
        src.format_into("{}\n}}\nfn main() i32 {{\n    return 0;\n}}\n", c[0]);
        h::expect_build_err(c[1], src.as_str(), c[1]);
    }
    h::expect_build_err(
        "a constant list of no lanes",
        "import std::simd;\nfn main() i32 {\n    return simd::swizzle(Simd::<i32, 4>::splat(1), [])[0];\n}\n",
        "`Simd<i32, 0>` needs a power-of-two lane count",
    );
    h::expect_build_err(
        "a generic list beside a run-time value",
        "import std::simd;\nfn g<const K: usize>(v: Simd<u32, 4>, x: usize) u32 {\n    return simd::swizzle(v, [K, x])[0];\n}\nfn main(a: Vector<str>) i32 {\n    return g::<1>(Simd::<u32, 4>::splat(1), a.len()) as i32;\n}\n",
        "the index list of `swizzle` must be a compile-time constant",
    );
    h::expect_build_err(
        "a list past the lanes in a constant's instance",
        "import std::simd;\nconst fn g<const K: usize>(v: Simd<u32, 4>) u32 {\n    return simd::swizzle(v, [K, 0, 0, 0])[0];\n}\nconst C: u32 = g::<5>(Simd::<u32, 4>::splat(1));\nfn main() i32 {\n    return C as i32;\n}\n",
        "constant 'C' cannot be evaluated at compile time: the index list names a lane past the lanes of its operands",
    );
    h::expect_build_err(
        "a list past the lanes of one instance",
        M"(import std::simd;
const fn up<const N: usize>() [usize; 2] {
    return [N - 1, N];
}
fn pick2<const N: usize>(v: Simd<i32, N>) Simd<i32, 2> {
    return simd::swizzle(v, up::<N>());
}
fn main() i32 {
    return pick2(Simd::<i32, 4>::splat(1))[0];
}
)",
        "the index list names a lane past the lanes of its operands",
    );
}

// The run-time index vector: every index from 0 to N + 1 and the index type's maximum, for each
// unsigned index type; `swizzle_checked` reports exactly the lanes past `N`.
@test
fn runtime_indexes_zero_and_report_the_lanes_past() {
    let src = M"(import std::simd;
fn run<U: SimdInt, const M: usize>(idx: Simd<U, M>, top: u64) i32 {
    let v = simd::iota::<i16, 8>() + Simd::<i16, 8>::splat(7);
    let (r, oob) = simd::swizzle_checked(v, idx);
    if !simd::swizzle_or_zero(v, idx).equal(r).all() {
        return 1;
    }
    for i in 0..M {
        let k = idx[i] as u64;
        let want = if k < 8 {
            v[k as usize];
        } else {
            0;
        };
        if r[i] != want || oob.get(i) != (k >= 8) || k > top {
            return 2;
        }
    }
    return 0;
}
fn main() i32 {
    let a = Simd::<u8, 16>::from_array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 255, 0, 7, 8, 9, 1]);
    let b = Simd::<u16, 16>::from_array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 65535, 0, 7, 8, 9, 1]);
    let c = Simd::<u32, 16>::from_array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 4294967295, 0, 7, 8, 9, 1]);
    let d = Simd::<u64, 8>::from_array([0, 1, 7, 8, 9, 18446744073709551615, 3, 6]);
    return run(a, 255) + run(b, 65535) + run(c, 4294967295) + run(d, 18446744073709551615);
}
)";
    h::expect_run("run-time indexes", src, "", "");
    h::expect_build_err(
        "signed indexes",
        "import std::simd;\nfn main() i32 {\n    return simd::swizzle_or_zero(Simd::<i32, 4>::splat(1), Simd::<i32, 4>::splat(0))[0];\n}\n",
        "swizzle_or_zero: the indexes must be unsigned",
    );
}

// Every mask of 2, 4 and 8 lanes: `compress` and `expand` against the lane rules, and `expand` of the
// compressed lanes gives back the active lanes.
@test
fn compress_and_expand_over_every_mask() {
    let src = M"(import std::simd;
fn all<const N: usize>(v: Simd<i32, N>, f: Simd<i32, N>) i32 {
    for bits in 0..(1u64 << N as u64) {
        let m = Mask::<N>::from_bits_truncate(bits);
        let c = simd::compress(m, v, f);
        let e = simd::expand(m, v, f);
        let mut k: usize = 0;
        for i in 0..N {
            if m.get(i) {
                if c[k] != v[i] || e[i] != v[k] {
                    return 1;
                }
                k += 1;
            } else if e[i] != f[i] {
                return 2;
            }
        }
        for i in k..N {
            if c[i] != f[i] {
                return 3;
            }
        }
        if !simd::expand(m, c, f).equal(m.choose(v, f)).all() {
            return 4;
        }
    }
    return 0;
}
fn main(args: Vector<str>) i32 {
    let k = args.len() as i32;
    let r = all(simd::iota::<i32, 2>() + Simd::<i32, 2>::splat(k), Simd::<i32, 2>::splat(-k));
    return r + all(simd::iota::<i32, 4>() + Simd::<i32, 4>::splat(k), Simd::<i32, 4>::splat(-k)) + all(
        simd::iota::<i32, 8>() + Simd::<i32, 8>::splat(k),
        Simd::<i32, 8>::splat(-k),
    );
}
)";
    h::expect_run("every mask", src, "", "");
}

// Each rearrangement has the same value as a constant and at run time.
@test
fn rearrangements_match_as_constants() {
    let decls = M"(import std::simd;
const fn hv<T: SimdElement, const N: usize>(v: Simd<T, N>) u64 {
    let mut h: u64 = N as u64;
    for x in v.to_array() {
        h = (h ^ x as u64).wrapping_mul(0x100000001B3);
    }
    return h;
}
const fn va(k: i32) Simd<i32, 8> {
    return simd::iota::<i32, 8>() * Simd::<i32, 8>::splat(k);
}
const fn ix(k: u32) Simd<u32, 8> {
    return simd::iota::<u32, 8>() * Simd::<u32, 8>::splat(k);
}
const fn oob(v: Simd<i32, 8>, i: Simd<u32, 8>) u64 {
    let (_, m) = simd::swizzle_checked(v, i);
    return m.to_bits();
}
const fn zu(a: Simd<i32, 8>, b: Simd<i32, 8>) u64 {
    let (_, z1) = simd::zip(a, b);
    let (u0, _) = simd::unzip(a, b);
    return hv(z1 + u0);
}
)";
    let exprs: [str; 12] = [
        "hv(simd::swizzle(va(opq::<i32>(3)), [7, 0, 6, 1]))",
        "hv(simd::shuffle(va(opq::<i32>(3)), va(opq::<i32>(-5)), [15, 0, 8, 7, 1, 9, 2, 10, 3, 11, 4, 12, 5, 13, 6, 14]))",
        "hv(simd::swizzle_or_zero(va(opq::<i32>(2)), ix(opq::<u32>(3))))",
        "oob(va(opq::<i32>(2)), ix(opq::<u32>(3)))",
        "hv(simd::reverse(va(opq::<i32>(7))))",
        "hv(simd::rotate_lanes_left::<3>(va(opq::<i32>(7))) + simd::rotate_lanes_right::<10>(va(opq::<i32>(1))))",
        "hv(simd::interleave_low(va(opq::<i32>(2)), va(opq::<i32>(-1))) + simd::interleave_high(va(opq::<i32>(4)), va(opq::<i32>(1))))",
        "hv(simd::deinterleave_even(va(opq::<i32>(2)), va(opq::<i32>(-1))) - simd::deinterleave_odd(va(opq::<i32>(4)), va(opq::<i32>(1))))",
        "zu(va(opq::<i32>(2)), va(opq::<i32>(5)))",
        "hv(simd::compress(Mask::<8>::from_bits_truncate(opq::<u64>(0xA5)), va(opq::<i32>(3)), va(opq::<i32>(-1))))",
        "hv(simd::expand(Mask::<8>::from_bits_truncate(opq::<u64>(0x5A)), va(opq::<i32>(3)), va(opq::<i32>(-1))))",
        "hv(simd::swizzle(simd::iota::<u8, 64>() + Simd::<u8, 64>::splat(opq::<u8>(1)), [63, 0, 62, 1, 61, 2, 60, 3, 59, 4, 58, 5, 57, 6, 56, 7, 55, 8, 54, 9, 53, 10, 52, 11, 51, 12, 50, 13, 49, 14, 48, 15]))",
    ];
    let tys: [str; 12] = ["u64"; 12];
    let d = h::const_runtime_parity(decls, exprs, tys, ["--profile=ubsan"]);
    if d.len() != 0 {
        eprintln("{}", d.as_str());
    }
    assert(d.len() == 0, "rearrangements as constants");
}
