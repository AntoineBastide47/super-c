// Vector operations at compile time: a constant's trap names the lowest failing lane as the run time
// does, a static_assert folds vector code, a signaling NaN lane keeps its bits through the bit-preserving
// operations, and a float lane converted to i64 saturates past 2^63 (a scalar constant too).
import tests::harness as h;

@test
fn a_constant_trap_names_the_lowest_failing_lane() {
    let src = "const C: Simd<i32, 4> = Simd::<i32, 4>::from_array([1, i32::MAX, 3, i32::MAX]) + Simd::<i32, 4>::splat(1);\nfn main() i32 {\n    return C[0];\n}\n";
    let b = h::diff_build(src, []);
    assert(!b.built && b.diag.contains("lane 1: attempt to add with overflow"), "the lane and the message");
    let rt = "static mut SINK: usize = 0;\n@c.noinline\nfn opr<T>(x: T) T {\n    unsafe SINK += 1;\n    return x;\n}\nfn main() i32 {\n    let v = Simd::<i32, 4>::from_array(opr([1, i32::MAX, 3, i32::MAX])) + Simd::<i32, 4>::splat(1);\n    return v[0];\n}\n";
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
    return v.minimum(o).to_bits()[0] ^ o.maximum(v).to_bits()[0] ^ v.min_num(v).to_bits()[0];
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
