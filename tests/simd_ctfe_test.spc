// Vector operations at compile time: a constant's trap names the lowest failing lane as the run time
// does, a static_assert folds vector code, a signaling NaN lane keeps its bits through the bit-preserving
// operations, a float lane converted to i64 saturates past 2^63 (a scalar constant too), a constant
// array of lanes has the instance's array type, and a narrow mask's operators keep its lanes.
import tests::harness as h;

@test
fn a_constant_trap_names_the_lowest_failing_lane() {
    let src = "const C: Simd<i32, 4> = Simd::<i32, 4>::from_array([1, i32::MAX, 3, i32::MAX]) + Simd::<i32, 4>::splat(1);\nfn main() i32 {\n    return C[0];\n}\n";
    let b = h::diff_build(src, []);
    assert(!b.built && b.diag.contains("lane 1: attempt to add with overflow"), "the lane and the message");
    let rt = "static mut SINK: usize = 0;\n@noinline\nfn opr<T>(x: T) T {\n    unsafe SINK += 1;\n    return x;\n}\nfn main() i32 {\n    let v = Simd::<i32, 4>::from_array(opr([1, i32::MAX, 3, i32::MAX])) + Simd::<i32, 4>::splat(1);\n    return v[0];\n}\n";
    let r = h::diff_build(rt, []);
    assert(r.built, "the run-time program builds");
    let run = h::diff_run(&r, "");
    assert(run.exit != 0 && run.err.contains("lane 1: attempt to add with overflow"), "the same lane at run time");
}

@test
fn static_assert_folds_vector_code() {
    let src = M"(const fn dot(a: Simd<i32, 4>, b: Simd<i32, 4>) i32 {
    let p = (a * b).to_array();
    return p[0] + p[1] + p[2] + p[3];
}
static_assert(dot(Simd::<i32, 4>::from_array([1, 2, 3, 4]), Simd::<i32, 4>::splat(2)) == 20, "dot");
static_assert(Simd::<u8, 16>::splat(200).saturating_add(Simd::<u8, 16>::splat(100))[15] == 255, "saturating");
static_assert(Simd::<f32, 4>::splat(2.0).sqrt().greater_than(Simd::<f32, 4>::splat(1.4)).all(), "sqrt");
fn main() i32 {
    return 0;
}
)";
    h::expect_exit("vector static_asserts", src, 0);
}

// The mask operators of 2- and 4-lane masks keep the bits above their lanes 0, at compile time and at
// run time.
@test
fn narrow_mask_operators_keep_their_lanes() {
    let src = M"(const fn mask_ops(x: u64) u64 {
    let a = Mask::<4>::from_bits_truncate(x);
    let b = Mask::<4>::from_bits_truncate(x >> 4);
    let c = Mask::<2>::from_bits_truncate(x);
    return (!a).to_bits() | (a & b).to_bits() << 4 | (a | b).to_bits() << 8 | (a ^ b).to_bits() << 12 | (!c).to_bits() << 16;
}
static_assert(mask_ops(0x5C) == 0x39D43, "mask operators");
@noinline
fn opr(x: u64) u64 {
    return x;
}
fn main() i32 {
    return (mask_ops(opr(0x5C)) != 0x39D43) as i32;
}
)";
    h::expect_exit("mask operators at compile time and at run time", src, 0);
}

@test
fn signaling_nan_lanes_keep_their_bits() {
    let decls = M"(const fn nan_ops(b: u32) u32 {
    let v = Simd::<f32, 2>::from_bits(Simd::<u32, 2>::splat(b));
    let w = (-v.abs()).copysign(v).to_bits();
    return w[0] ^ w[1] ^ v.to_bits()[1];
}
const fn pick_nan(b: u32) u32 {
    let v = Simd::<f32, 2>::from_bits(Simd::<u32, 2>::from_array([b, 0x3f800000]));
    let o = Simd::<f32, 2>::splat(1.0);
    // Two NaNs: `min_num` and `max_num` give `a` with its quiet bit set; a NaN `b` gives `a`.
    let q = Simd::<f32, 2>::from_bits(Simd::<u32, 2>::from_array([0x7fc00005, 0x7f800001]));
    let lo = v.min_num(q).to_bits();
    let hi = q.max_num(v).to_bits();
    return v.minimum(o).to_bits()[0] ^ o.maximum(v).to_bits()[0] ^ v.min_num(v).to_bits()[0] ^ lo[0] ^ lo[1] << 1 ^ hi[0] << 2 ^ hi[1] << 3;
}
const fn wide(x: f64) i64 {
    return Simd::<f64, 2>::splat(x).cast::<i64>()[1] ^ (x as i64);
}
)";
    let exprs: [str; 5] = [
        "nan_ops(opq::<u32>(0x7fa00001))",
        "nan_ops(opq::<u32>(0xffc00003))",
        "pick_nan(opq::<u32>(0x7fa00000))",
        "wide(opq::<f64>(1e19))",
        "wide(opq::<f64>(-1e19))",
    ];
    let tys: [str; 5] = ["u32", "u32", "u32", "i64", "i64"];
    let d = h::const_runtime_parity(decls, exprs, tys, []);
    if d.len() != 0 {
        eprintln("{}", d.as_str());
    }
    assert(d.len() == 0, "bit-preserving lanes, the NaN min and max pick, and saturating casts as constants");
    h::expect_exit(
        "the values",
        "const A: u32 = 0x7fa00001;\nconst fn f() u32 {\n    let v = Simd::<f32, 2>::from_bits(Simd::<u32, 2>::splat(A));\n    return (-v).to_bits()[0];\n}\nconst X: i64 = 1e19 as i64;\nstatic_assert(f() == 0xffa00001, \"the sign flips, the payload stays\");\nstatic_assert(X == 9223372036854775807, \"saturated\");\nfn main() i32 {\n    return 0;\n}\n",
        0,
    );
}

// A constant computed as a vector's lanes (`to_array` in a generic body) has the array type of the
// instance, `[u64; 2]`, not the template's `[T; N]`.
@test
fn a_constant_from_vector_lanes_has_the_instance_array_type() {
    h::expect_exit(
        "the lanes",
        "const fn lanes() [u64; 2] {\n    return Simd::<u64, 2>::splat(6).to_array();\n}\nconst C: [u64; 2] = lanes();\nconst D: [u64; 2] = Simd::<u64, 2>::splat(1).to_array();\nfn main() i32 {\n    return (C[0] + C[1] + D[1]) as i32;\n}\n",
        13,
    );
}
