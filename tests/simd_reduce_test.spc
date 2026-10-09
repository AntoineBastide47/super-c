// Reductions (std/simd.spc): the float orders the definitions fix (left to right from -0.0, and by
// halves), NaN lanes, integer wrapping and the exact-result tests at their boundaries, the extreme
// lanes, and `dot` in its accumulation type; each at run time and as a constant.
import tests::harness as h;

// [1e8, 1, -1e8, 1] in f32: left to right gives 1, by halves 2, and by adjacent pairs 0, so each result
// shows its order. A vector of -0.0 sums to -0.0; NaN lanes follow the lane rule of each reduction.
@test
fn float_reductions_keep_their_order() {
    let src = M"(import std::simd;
fn main(args: Vector<str>) i32 {
    let k = args.len() as f32;
    let f = Simd::<f32, 4>::from_array([1.0e8 * k, 1.0, -1.0e8, 1.0]);
    let pairs = (f[0] + f[1]) + (f[2] + f[3]);
    if simd::reduce_add_ordered(f) != 1.0 || simd::reduce_add_tree(f) != 2.0 || pairs != 0.0 {
        return 1;
    }
    let z = Simd::<f64, 8>::splat(-0.0 * k as f64);
    if !simd::reduce_add_ordered(z).is_sign_negative() || !simd::reduce_add_tree(z).is_sign_negative() {
        return 2;
    }
    let m = Simd::<f64, 4>::from_array([3.0, 0.5, 4.0, 0.25 * k as f64]);
    if simd::reduce_mul_ordered(m) != 1.5 || simd::reduce_mul_tree(m) != 1.5 {
        return 3;
    }
    let nan = 0.0f32 / 0.0;
    let n = Simd::<f32, 4>::from_array([2.0, nan, -0.0, 0.0]);
    if !simd::reduce_add_ordered(n).is_nan() || !simd::reduce_minimum(n).is_nan() || !simd::reduce_maximum(n).is_nan() {
        return 4;
    }
    if simd::reduce_max_num(n) != 2.0 || !simd::reduce_min_num(n).is_sign_negative() {
        return 5;
    }
    let all = Simd::<f32, 4>::splat(nan);
    if !simd::reduce_min_num(all).is_nan() || simd::arg_min_num(all).is_some() || simd::arg_max_num(all).is_some() {
        return 6;
    }
    // The lowest lane of the extreme non-NaN value; -0.0 is below +0.0.
    let a = Simd::<f32, 8>::from_array([nan, 0.0, 5.0, -0.0, 5.0, -0.0, 1.0, nan]);
    if simd::arg_min_num(a).unwrap() != 3 || simd::arg_max_num(a).unwrap() != 2 {
        return 7;
    }
    let s = Simd::<f64, 4>::from_array([0.0, -0.0, 0.0, -0.0]);
    if simd::arg_max_num(s).unwrap() != 0 || simd::arg_min_num(s).unwrap() != 1 {
        return 8;
    }
    return 0;
}
)";
    h::expect_run("float orders", src, "", "");
}

// Wrapping integer reductions, the exact-result tests on each side of their boundary (an exact sum
// that fits after an intermediate overflow, a zero lane in a product), the extremes, the bitwise
// reductions, and `dot` wrapping in its accumulation type.
@test
fn integer_reductions_wrap_and_check_exactly() {
    let src = M"(import std::simd;
fn main(args: Vector<str>) i32 {
    let k = args.len() as i8;
    let a = Simd::<i8, 4>::from_array([127, k, -1, 0]);
    if simd::reduce_add(a) != 127 || simd::reduce_add_checked(a).unwrap() != 127 {
        return 1;
    }
    let b = Simd::<i8, 4>::from_array([127, k, 0, 0]);
    if simd::reduce_add(b) != -128 || simd::reduce_add_checked(b).is_some() {
        return 2;
    }
    let c = Simd::<i8, 2>::from_array([-128, k]);
    if simd::reduce_mul_checked(c).unwrap() != -128 || simd::reduce_mul_checked(c - Simd::<i8, 2>::from_array([0, 2])).is_some() {
        return 3;
    }
    let d = Simd::<i8, 4>::from_array([16, 8, k, 1]);
    let e = Simd::<i8, 4>::from_array([-16, 8, k, 1]);
    if simd::reduce_mul_checked(d).is_some() || simd::reduce_mul_checked(e).unwrap() != -128 || simd::reduce_mul(d) != -128 {
        return 4;
    }
    let z = Simd::<i64, 4>::from_array([9223372036854775807, 9223372036854775807, 0, k as i64 - 1]);
    if simd::reduce_mul_checked(z).unwrap() != 0 || simd::reduce_add_checked(z).is_some() {
        return 5;
    }
    let u = Simd::<u64, 2>::from_array([18446744073709551615, k as u64 - 1]);
    if simd::reduce_add_checked(u).unwrap() != 18446744073709551615 || simd::reduce_add_checked(u + Simd::<u64, 2>::from_array([0, 1])).is_some() {
        return 6;
    }
    let s = Simd::<i64, 4>::from_array([-9223372036854775807 - 1, -1, 1, k as i64 - 1]);
    if simd::reduce_add_checked(s).unwrap() != -9223372036854775807 - 1 || simd::reduce_add_checked(s - Simd::<i64, 4>::from_array([0, 0, 1, 0])).is_some() {
        return 7;
    }
    let w = Simd::<u8, 4>::from_array([255, k as u8, 1, 1]);
    let w2 = Simd::<u8, 4>::from_array([128, k as u8, 2, 1]);
    if simd::reduce_mul_checked(w).unwrap() != 255 || simd::reduce_mul_checked(w2).is_some() || simd::reduce_mul(w2) != 0 {
        return 8;
    }
    let m = Simd::<i16, 8>::from_array([5, -7, 3, -7, 9, 9, k as i16, 0]);
    if simd::reduce_min(m) != -7 || simd::reduce_max(m) != 9 || simd::arg_min(m) != 1 || simd::arg_max(m) != 4 {
        return 9;
    }
    let x = Simd::<u32, 4>::from_array([0xF0F0, 0xFF00, 0x0FF0 * k as u32, 0xF000]);
    if simd::reduce_and(x) != 0 || simd::reduce_or(x) != 0xFFF0 || simd::reduce_xor(x) != (0xF0F0 ^ 0xFF00 ^ 0x0FF0 ^ 0xF000) {
        return 10;
    }
    let p = Simd::<i8, 16>::splat(127 * k);
    if simd::dot::<i32>(p, p) != 16 * 127 * 127 || simd::dot::<i8>(p, p) != 16 || simd::dot::<i64>(-p, p) != -258064 {
        return 11;
    }
    let q = Simd::<u8, 4>::splat(200 * k as u8);
    if simd::dot::<i32>(q, q) != 160000 || simd::dot::<u16>(q, q) != (160000 % 65536) as u16 {
        return 12;
    }
    return 0;
}
)";
    h::expect_run("integer reductions", src, "", "");
}

// `dot` over floats: each product rounded to the accumulation type, then summed left to right from
// -0.0; and an accumulation type that is narrower or of another kind is refused.
@test
fn dot_rounds_in_its_accumulation_type() {
    let src = M"(import std::simd;
fn main(args: Vector<str>) i32 {
    let e = 1.0f32 + 0.000000119209290 * args.len() as f32;
    let a = Simd::<f32, 4>::from_array([e, e, -1.0, -1.0]);
    let exact = 2.0 * (e as f64 * e as f64) + 2.0;
    let narrow = ((e * e + e * e) + 1.0) + 1.0;
    if simd::dot::<f64>(a, a) != exact || simd::dot::<f32>(a, a) != narrow || simd::dot::<f32>(a, a) as f64 == exact {
        return 1;
    }
    if !simd::dot::<f32>(Simd::<f32, 2>::splat(-0.0), Simd::<f32, 2>::splat(1.0)).is_sign_negative() {
        return 2;
    }
    return 0;
}
)";
    h::expect_run("float dot", src, "", "");
    let bad: [[str; 2]; 3] = [["i16", "i32"], ["f32", "f64"], ["f64", "i64"]];
    for c in bad {
        let mut s = String::new();
        s.format_into(
            "import std::simd;\nfn main() i32 {{\n    let v = Simd::<{}, 4>::splat(1 as {});\n    return simd::dot::<{}>(v, v) as i32;\n}}\n",
            c[1],
            c[1],
            c[0],
        );
        h::expect_build_err(c[0], s.as_str(), "dot: A must be a type of the same kind as T, at least as wide");
    }
}
