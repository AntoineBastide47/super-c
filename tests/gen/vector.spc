// Vector model: one lane operation per case (an operator, a named function, a conversion, a lane
// rearrangement, a reduction or a masked memory form of std/simd.spc) over every lane type and 2, 4 or the most lanes, with inputs biased
// to the boundaries (integer MIN, MIN + 1, -1, 0, 1, MAX - 1, MAX; float zeros, infinities, quiet and
// signaling NaNs, subnormals, MAX and halves; shift counts from -1 to the width + 1). Float inputs are
// bit patterns, so every side reads the same lanes. The oracle compares each case as a constant and at
// run time (the same value, or the same trap with its lane), and the run time with a scalar lane loop
// of the same program (the same lanes, or a trap with the same message at the first failing lane). A result hashes its lanes; a NaN lane of
// an arithmetic result hashes as one NaN (its payload is not specified), a bit-preserving operation's
// with its bits.
import tests::gen::driver as *;
import tests::harness as h;
import ast::ast as ast;

// Lane types: 0..=3 i8..i64, 4..=7 u8..u64, 8 f32, 9 f64.
const LANES_N: u64 = 10;
const LANE_NAMES: [str<'static>; 10] = ["i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "f32", "f64"];

// Lane classes an operation accepts.
const C_ALL: u8 = 0;
const C_INT: u8 = 1;
const C_FLOAT: u8 = 2;
const C_SIGNED: u8 = 3; // signed integers and floats
const C_SINT: u8 = 4;
const C_UINT: u8 = 5;

// Result shapes: a vector of the input's lanes, of the target type `U`, a mask, a (value, mask) pair,
// half or double the lanes, `M` lanes of `U` (a bitcast).
const R_VEC: u8 = 0;
const R_U: u8 = 1;
const R_MASK: u8 = 2;
const R_PAIR: u8 = 3;
const R_UPAIR: u8 = 4;
const R_HALF: u8 = 5;
const R_TWICE: u8 = 6;
const R_BITS: u8 = 7;

// Targets of a conversion: any lane type, a wider one of the same kind, a narrower integer, a bitcast.
const U_NONE: u8 = 0;
const U_ANY: u8 = 1;
const U_WIDER: u8 = 2;
const U_NARROWER: u8 = 3;
const U_BITCAST: u8 = 4;
const U_UINT: u8 = 5; // an unsigned index type, `M` lanes (`swizzle_or_zero`)
const U_INDEX: u8 = 6; // `u32` or `u64` (`gather`, `scatter`)
const U_DOT: u8 = 7; // the accumulator of `dot`: the same kind class, at least as wide

/// One operation: the vector form over `x`, `y`, `z` (from the inputs `a`, `b`, `c`), the scalar `s`
/// and the target `U`, and the scalar form of lane `$i` over the lane values `$a`, `$b`, `$c`. Other
/// placeholders: `$T` lane type, `$U` target, `$Q` unsigned type of the lane width, `$W` width, `$F`
/// float lane type, `$N` lanes, `$M` target lanes.
pub struct VOp {
    pub name: str<'static>,
    pub cls: u8,
    pub nv: u8, // vector inputs
    pub res: u8,
    pub tgt: u8,
    pub exact: bool, // a NaN result lane keeps its bits
    pub vexpr: str<'static>,
    pub rexpr: str<'static>,
}

const fn vop(name: str<'static>, cls: u8, nv: u8, res: u8, vexpr: str<'static>, rexpr: str<'static>) VOp {
    return VOp { name: name, cls: cls, nv: nv, res: res, tgt: U_NONE, exact: false, vexpr: vexpr, rexpr: rexpr };
}

const fn vopx(name: str<'static>, cls: u8, nv: u8, res: u8, vexpr: str<'static>, rexpr: str<'static>) VOp {
    return VOp { name: name, cls: cls, nv: nv, res: res, tgt: U_NONE, exact: true, vexpr: vexpr, rexpr: rexpr };
}

const fn vopu(name: str<'static>, cls: u8, res: u8, tgt: u8, vexpr: str<'static>, rexpr: str<'static>) VOp {
    return VOp { name: name, cls: cls, nv: 1, res: res, tgt: tgt, exact: false, vexpr: vexpr, rexpr: rexpr };
}

/// Every operation the model draws.
pub const VOPS: [VOp; 72] = [
    vop("add", C_ALL, 2, R_VEC, "x + y", "$a + $b"),
    vop("sub", C_ALL, 2, R_VEC, "x - y", "$a - $b"),
    vop("mul", C_ALL, 2, R_VEC, "x * y", "$a * $b"),
    vop("div", C_ALL, 2, R_VEC, "x / y", "$a / $b"),
    vop("rem", C_INT, 2, R_VEC, "x % y", "$a % $b"),
    vop("and", C_INT, 2, R_VEC, "x & y", "$a & $b"),
    vop("or", C_INT, 2, R_VEC, "x | y", "$a | $b"),
    vop("xor", C_INT, 2, R_VEC, "x ^ y", "$a ^ $b"),
    vop("shl", C_INT, 2, R_VEC, "x << y", "$a << $b"),
    vop("shr", C_INT, 2, R_VEC, "x >> y", "$a >> $b"),
    vop("shl_scalar", C_INT, 1, R_VEC, "x << s", "$a << s"),
    vop("shr_scalar", C_INT, 1, R_VEC, "x >> s", "$a >> s"),
    vopx("neg", C_SIGNED, 1, R_VEC, "-x", "-$a"),
    vop("not", C_INT, 1, R_VEC, "~x", "~$a"),
    vop("equal", C_ALL, 2, R_MASK, "x.equal(y)", "$a == $b"),
    vop("not_equal", C_ALL, 2, R_MASK, "x.not_equal(y)", "$a != $b"),
    vop("less_than", C_ALL, 2, R_MASK, "x.less_than(y)", "$a < $b"),
    vop("less_equal", C_ALL, 2, R_MASK, "x.less_equal(y)", "$a <= $b"),
    vop("greater_than", C_ALL, 2, R_MASK, "x.greater_than(y)", "$a > $b"),
    vop("greater_equal", C_ALL, 2, R_MASK, "x.greater_equal(y)", "$a >= $b"),
    vopx(
        "choose",
        C_ALL,
        2,
        R_VEC,
        "simd::choose(Mask::<$N>::from_bits_truncate(m), x, y)",
        "pick((m >> $i & 1) != 0, $a, $b)",
    ),
    vopx("mask_choose", C_ALL, 2, R_VEC, "x.less_than(y).choose(y, x)", "pick($a < $b, $b, $a)"),
    vop("wrapping_add", C_INT, 2, R_VEC, "x.wrapping_add(y)", "$a.wrapping_add($b)"),
    vop("wrapping_sub", C_INT, 2, R_VEC, "x.wrapping_sub(y)", "$a.wrapping_sub($b)"),
    vop("wrapping_mul", C_INT, 2, R_VEC, "x.wrapping_mul(y)", "$a.wrapping_mul($b)"),
    vop("wrapping_neg", C_INT, 1, R_VEC, "x.wrapping_neg()", "$a.wrapping_neg()"),
    vop("wrapping_shl", C_INT, 2, R_VEC, "x.wrapping_shl(y)", "$a.wrapping_shl($b as u32)"),
    vop("wrapping_shr", C_INT, 2, R_VEC, "x.wrapping_shr(y)", "$a.wrapping_shr($b as u32)"),
    vop("checked_add", C_INT, 2, R_PAIR, "x.checked_add(y)", "$a.overflowing_add($b)"),
    vop("checked_sub", C_INT, 2, R_PAIR, "x.checked_sub(y)", "$a.overflowing_sub($b)"),
    vop("checked_mul", C_INT, 2, R_PAIR, "x.checked_mul(y)", "$a.overflowing_mul($b)"),
    vop("saturating_add", C_INT, 2, R_VEC, "x.saturating_add(y)", "$a.saturating_add($b)"),
    vop("saturating_sub", C_INT, 2, R_VEC, "x.saturating_sub(y)", "$a.saturating_sub($b)"),
    vop("min", C_INT, 2, R_VEC, "x.min(y)", "$a.min($b)"),
    vop("max", C_INT, 2, R_VEC, "x.max(y)", "$a.max($b)"),
    vop("min_num", C_FLOAT, 2, R_VEC, "x.min_num(y)", "rmm($a as f64, $b as f64, true, false) as $T"),
    vop("max_num", C_FLOAT, 2, R_VEC, "x.max_num(y)", "rmm($a as f64, $b as f64, false, false) as $T"),
    vop("minimum", C_FLOAT, 2, R_VEC, "x.minimum(y)", "rmm($a as f64, $b as f64, true, true) as $T"),
    vop("maximum", C_FLOAT, 2, R_VEC, "x.maximum(y)", "rmm($a as f64, $b as f64, false, true) as $T"),
    vop("clamp", C_INT, 3, R_VEC, "x.clamp(y, z)", "$b.max($a.min($c))"),
    vop(
        "clamp_float",
        C_FLOAT,
        3,
        R_VEC,
        "x.clamp(y, z)",
        "rmm($b as f64, rmm($a as f64, $c as f64, true, false), false, false) as $T",
    ),
    vop("abs", C_SINT, 1, R_VEC, "x.abs()", "$a.abs()"),
    vopx("abs_float", C_FLOAT, 1, R_VEC, "x.abs()", "$F_from_bits($F_bits($a) & ~$Z)"),
    vop("wrapping_abs", C_SINT, 1, R_VEC, "x.wrapping_abs()", "pick($a < 0, $a.wrapping_neg(), $a)"),
    vop(
        "abs_diff",
        C_INT,
        2,
        R_U,
        "x.abs_diff(y)",
        "pick($a > $b, ($a as $Q).wrapping_sub($b as $Q), ($b as $Q).wrapping_sub($a as $Q))",
    ),
    vop("leading_zeros", C_INT, 1, R_VEC, "x.leading_zeros()", "$a.leading_zeros() as $T"),
    vop("trailing_zeros", C_INT, 1, R_VEC, "x.trailing_zeros()", "$a.trailing_zeros() as $T"),
    vop("count_ones", C_INT, 1, R_VEC, "x.count_ones()", "$a.count_ones() as $T"),
    vop(
        "rotate_left",
        C_INT,
        2,
        R_VEC,
        "x.rotate_left(y)",
        "(rrot(($a as $Q) as u64, ($b as $Q) as u64, $W, true) as $Q) as $T",
    ),
    vop(
        "rotate_right",
        C_INT,
        2,
        R_VEC,
        "x.rotate_right(y)",
        "(rrot(($a as $Q) as u64, ($b as $Q) as u64, $W, false) as $Q) as $T",
    ),
    vop("reverse_bits", C_INT, 1, R_VEC, "x.reverse_bits()", "(rperm(($a as $Q) as u64, $W, 1) as $Q) as $T"),
    vop("swap_bytes", C_INT, 1, R_VEC, "x.swap_bytes()", "(rperm(($a as $Q) as u64, $W, 8) as $Q) as $T"),
    vopx("copysign", C_FLOAT, 2, R_VEC, "x.copysign(y)", "$F_from_bits($F_bits($a) & ~$Z | $F_bits($b) & $Z)"),
    vop("sqrt", C_FLOAT, 1, R_VEC, "x.sqrt()", "$a.sqrt()"),
    vop("ceil", C_FLOAT, 1, R_VEC, "x.ceil()", "$a.ceil()"),
    vop("floor", C_FLOAT, 1, R_VEC, "x.floor()", "$a.floor()"),
    vop("trunc", C_FLOAT, 1, R_VEC, "x.trunc()", "$a.trunc()"),
    vop("round_even", C_FLOAT, 1, R_VEC, "x.round_even()", "math::nearbyint($a as f64) as $T"),
    vop("fma", C_FLOAT, 3, R_VEC, "x.fma(y, z)", "$a.mul_add($b, $c)"),
    vop("is_nan", C_FLOAT, 1, R_MASK, "x.is_nan()", "$a.is_nan()"),
    vop("is_infinite", C_FLOAT, 1, R_MASK, "x.is_infinite()", "$a.is_infinite()"),
    vop("is_finite", C_FLOAT, 1, R_MASK, "x.is_finite()", "$a.is_finite()"),
    vop("is_normal", C_FLOAT, 1, R_MASK, "x.is_normal()", "$a.is_finite() && $a.abs() >= $L"),
    vop("is_subnormal", C_FLOAT, 1, R_MASK, "x.is_subnormal()", "$a != 0.0 && $a.abs() < $L"),
    vop("is_sign_negative", C_FLOAT, 1, R_MASK, "x.is_sign_negative()", "$a.is_sign_negative()"),
    vopu("cast", C_ALL, R_U, U_ANY, "x.cast::<$U>()", "$a as $U"),
    vopu("cast_checked", C_ALL, R_UPAIR, U_ANY, "x.cast_checked::<$U>()", "$a as $U"),
    vopu("widen", C_ALL, R_U, U_WIDER, "x.widen::<$U>()", "$a as $U"),
    vopu("narrow", C_INT, R_U, U_NARROWER, "x.narrow::<$U>()", "rfit($C, $a as $U)"),
    vopu("narrow_saturating", C_INT, R_U, U_NARROWER, "x.narrow_saturating::<$U>()", "$S"),
    vopu("narrow_wrapping", C_INT, R_U, U_NARROWER, "x.narrow_wrapping::<$U>()", "$a as $U"),
    VOp {
        name: "bitcast",
        cls: C_ALL,
        nv: 1,
        res: R_BITS,
        tgt: U_BITCAST,
        exact: true,
        vexpr: "x.bitcast::<$U, $M>()",
        rexpr: "",
    },
];

// The rearrangements, whose scalar form is a whole-array one (`case_ref`).
const L_LOW: u8 = 0;
const L_HIGH: u8 = 1;
const L_CONCAT: u8 = 2;
const L_IOTA: u8 = 3;
const L_TO_BITS: u8 = 4;
const L_FROM_BITS: u8 = 5;
const LANE_OPS: [str<'static>; 6] = ["low_half", "high_half", "concat", "iota", "to_bits", "from_bits"];

/// An operation whose scalar form is the whole function (the rearrangements, reductions and masked
/// memory forms): `vbody` the vector function's statements over `x`, `y`, `m`, `rbody` the scalar
/// function's over the arrays `a`, `b` and `m`, inside `unsafe`, its hash in `hr`. Placeholders as
/// VOp's, and `$X` the case's index list, start, rotation or index vector, `$E` the exact hash of
/// lanes of `$T`, `$H` the NaN-canonical one, `$A` the NaN-canonical hash of lanes of `$U`; and the
/// pieces of a scalar form: `$K` the active lane test, `$V` and `$R` the hash of the lanes or of the
/// scalar `r`, `$P` and `$G` the range checks of a start or an index lane, trapping as the vector form.
pub struct XOp {
    pub name: str<'static>,
    pub cls: u8,
    pub tgt: u8,
    pub vbody: str<'static>,
    pub rbody: str<'static>,
}

const fn xop(name: str<'static>, cls: u8, tgt: u8, vbody: str<'static>, rbody: str<'static>) XOp {
    return XOp { name: name, cls: cls, tgt: tgt, vbody: vbody, rbody: rbody };
}

/// The operations of `XOPS`, from index 78.
pub const XOPS: [XOp; 46] = [
    xop(
        "swizzle",
        C_ALL,
        U_NONE,
        "return $E(simd::swizzle(x, $X));",
        "let l: [usize; $M] = $X; let mut r = [0 as $T; $M]; for i in 0..$Musize { r[i] = a[l[i]]; } hr = $E(Simd::<$T, $M>::from_array(r));",
    ),
    xop(
        "shuffle",
        C_ALL,
        U_NONE,
        "return $E(simd::shuffle(x, y, $X));",
        "let l: [usize; $M] = $X; let mut r = [0 as $T; $M]; for i in 0..$Musize { r[i] = if l[i] < $Nusize { a[l[i]]; } else { b[l[i] - $Nusize]; }; } hr = $E(Simd::<$T, $M>::from_array(r));",
    ),
    xop(
        "swizzle_or_zero",
        C_ALL,
        U_UINT,
        "return $E(simd::swizzle_or_zero(x, Simd::<$U, $M>::from_array($X)));",
        "let l: [$U; $M] = $X; let mut r = [0 as $T; $M]; for i in 0..$Musize { if (l[i] as u64) < $Nu64 { r[i] = a[l[i] as usize]; } } hr = $E(Simd::<$T, $M>::from_array(r));",
    ),
    xop(
        "swizzle_checked",
        C_ALL,
        U_UINT,
        "let (r, mk) = simd::swizzle_checked(x, Simd::<$U, $M>::from_array($X)); return hmix($E(r), hm(mk));",
        "let l: [$U; $M] = $X; let mut r = [0 as $T; $M]; let mut bits: u64 = 0; for i in 0..$Musize { if (l[i] as u64) < $Nu64 { r[i] = a[l[i] as usize]; } else { bits = bits | 1u64 << i as u64; } } hr = hmix($E(Simd::<$T, $M>::from_array(r)), hm(Mask::<$M>::from_bits_truncate(bits)));",
    ),
    xop(
        "reverse",
        C_ALL,
        U_NONE,
        "return $E(simd::reverse(x));",
        "let mut r = a; for i in 0..$Nusize { r[i] = a[$Nusize - 1 - i]; } $V",
    ),
    xop(
        "rotate_lanes_left",
        C_ALL,
        U_NONE,
        "return $E(simd::rotate_lanes_left::<$X>(x));",
        "let mut r = a; for i in 0..$Nusize { r[i] = a[(i + $Xusize) % $Nusize]; } $V",
    ),
    xop(
        "rotate_lanes_right",
        C_ALL,
        U_NONE,
        "return $E(simd::rotate_lanes_right::<$X>(x));",
        "let mut r = a; for i in 0..$Nusize { r[i] = a[(i + $Nusize - $Xusize % $Nusize) % $Nusize]; } $V",
    ),
    xop(
        "interleave_low",
        C_ALL,
        U_NONE,
        "return $E(simd::interleave_low(x, y));",
        "let mut r = a; for i in 0..$Nusize { r[i] = if i % 2 == 0 { a[i / 2]; } else { b[i / 2]; }; } $V",
    ),
    xop(
        "interleave_high",
        C_ALL,
        U_NONE,
        "return $E(simd::interleave_high(x, y));",
        "let mut r = a; for i in 0..$Nusize { r[i] = if i % 2 == 0 { a[$Nusize / 2 + i / 2]; } else { b[$Nusize / 2 + i / 2]; }; } $V",
    ),
    xop(
        "deinterleave_even",
        C_ALL,
        U_NONE,
        "return $E(simd::deinterleave_even(x, y));",
        "let mut r = a; for i in 0..$Nusize { r[i] = if i < $Nusize / 2 { a[2 * i]; } else { b[2 * i - $Nusize]; }; } $V",
    ),
    xop(
        "deinterleave_odd",
        C_ALL,
        U_NONE,
        "return $E(simd::deinterleave_odd(x, y));",
        "let mut r = a; for i in 0..$Nusize { r[i] = if i < $Nusize / 2 { a[2 * i + 1]; } else { b[2 * i + 1 - $Nusize]; }; } $V",
    ),
    xop(
        "zip",
        C_ALL,
        U_NONE,
        "let (p, q) = simd::zip(x, y); return hmix($E(p), $E(q));",
        "let mut r = a; let mut q = a; for i in 0..$Nusize { r[i] = if i % 2 == 0 { a[i / 2]; } else { b[i / 2]; }; q[i] = if i % 2 == 0 { a[$Nusize / 2 + i / 2]; } else { b[$Nusize / 2 + i / 2]; }; } hr = hmix($E(Simd::<$T, $N>::from_array(r)), $E(Simd::<$T, $N>::from_array(q)));",
    ),
    xop(
        "unzip",
        C_ALL,
        U_NONE,
        "let (p, q) = simd::unzip(x, y); return hmix($E(p), $E(q));",
        "let mut r = a; let mut q = a; for i in 0..$Nusize { r[i] = if i < $Nusize / 2 { a[2 * i]; } else { b[2 * i - $Nusize]; }; q[i] = if i < $Nusize / 2 { a[2 * i + 1]; } else { b[2 * i + 1 - $Nusize]; }; } hr = hmix($E(Simd::<$T, $N>::from_array(r)), $E(Simd::<$T, $N>::from_array(q)));",
    ),
    xop(
        "compress",
        C_ALL,
        U_NONE,
        "return $E(simd::compress(Mask::<$N>::from_bits_truncate(m), x, y));",
        "let mut r = b; let mut k = 0usize; for i in 0..$Nusize { if $K { r[k] = a[i]; k += 1; } } $V",
    ),
    xop(
        "expand",
        C_ALL,
        U_NONE,
        "return $E(simd::expand(Mask::<$N>::from_bits_truncate(m), x, y));",
        "let mut r = b; let mut k = 0usize; for i in 0..$Nusize { if $K { r[i] = a[k]; k += 1; } } $V",
    ),
    xop(
        "reduce_add",
        C_INT,
        U_NONE,
        "return $H(Simd::<$T, 2>::splat(simd::reduce_add(x)));",
        "let mut r = a[0]; for i in 1..$Nusize { r = r.wrapping_add(a[i]); } $R",
    ),
    xop(
        "reduce_mul",
        C_INT,
        U_NONE,
        "return $H(Simd::<$T, 2>::splat(simd::reduce_mul(x)));",
        "let mut r = a[0]; for i in 1..$Nusize { r = r.wrapping_mul(a[i]); } $R",
    ),
    // The exact sum fits when, adding a lane of the sign that brings the sum back toward 0 whenever
    // there is one, no step overflows.
    xop(
        "reduce_add_checked",
        C_SINT,
        U_NONE,
        "let o = simd::reduce_add_checked(x); return hmix(o.is_some() as u64, $H(Simd::<$T, 2>::splat(o.unwrap_or(0 as $T))));",
        "let mut used = [false; $N]; let mut r = 0 as $T; let mut ok = true; for _k in 0..$Nusize { let neg = r >= 0; let mut j = $Nusize; for i in 0..$Nusize { if !used[i] && (j == $Nusize || (a[i] < 0) == neg && (a[j] < 0) != neg) { j = i; } } used[j] = true; let (v, o) = r.overflowing_add(a[j]); r = v; ok = ok && !o; } hr = hmix(ok as u64, $H(Simd::<$T, 2>::splat(if ok { r; } else { 0 as $T; })));",
    ),
    xop(
        "reduce_add_checked_u",
        C_UINT,
        U_NONE,
        "let o = simd::reduce_add_checked(x); return hmix(o.is_some() as u64, $H(Simd::<$T, 2>::splat(o.unwrap_or(0 as $T))));",
        "let mut r = 0 as $T; let mut ok = true; for i in 0..$Nusize { let (v, o) = r.overflowing_add(a[i]); r = v; ok = ok && !o; } hr = hmix(ok as u64, $H(Simd::<$T, 2>::splat(if ok { r; } else { 0 as $T; })));",
    ),
    // The exact product fits when a lane is 0, or its magnitude (which only grows) fits the sign.
    xop(
        "reduce_mul_checked",
        C_SINT,
        U_NONE,
        "let o = simd::reduce_mul_checked(x); return hmix(o.is_some() as u64, $H(Simd::<$T, 2>::splat(o.unwrap_or(0 as $T))));",
        "let mut z = false; let mut over = false; let mut neg = false; let mut p: u64 = 1; let mut r = a[0]; for i in 0..$Nusize { let w = a[i] as i64; let g = if w < 0 { (w as u64).wrapping_neg(); } else { w as u64; }; z = z || g == 0; neg = neg != (w < 0); let (q, o) = p.overflowing_mul(g); p = q; over = over || o; if i != 0 { r = r.wrapping_mul(a[i]); } } let lim = 1u64 << ($Wu64 - 1); let ok = z || !over && (p < lim || neg && p == lim); hr = hmix(ok as u64, $H(Simd::<$T, 2>::splat(if ok { r; } else { 0 as $T; })));",
    ),
    xop(
        "reduce_mul_checked_u",
        C_UINT,
        U_NONE,
        "let o = simd::reduce_mul_checked(x); return hmix(o.is_some() as u64, $H(Simd::<$T, 2>::splat(o.unwrap_or(0 as $T))));",
        "let mut z = false; let mut over = false; let mut p: u64 = 1; let mut r = a[0]; for i in 0..$Nusize { let g = a[i] as u64; z = z || g == 0; let (q, o) = p.overflowing_mul(g); p = q; over = over || o; if i != 0 { r = r.wrapping_mul(a[i]); } } let ok = z || !over && p <= $T::MAX as u64; hr = hmix(ok as u64, $H(Simd::<$T, 2>::splat(if ok { r; } else { 0 as $T; })));",
    ),
    xop(
        "reduce_add_ordered",
        C_FLOAT,
        U_NONE,
        "return $H(Simd::<$T, 2>::splat(simd::reduce_add_ordered(x)));",
        "let mut r = -0.0 as $T; for i in 0..$Nusize { r = r + a[i]; } $R",
    ),
    xop(
        "reduce_mul_ordered",
        C_FLOAT,
        U_NONE,
        "return $H(Simd::<$T, 2>::splat(simd::reduce_mul_ordered(x)));",
        "let mut r = 1.0 as $T; for i in 0..$Nusize { r = r * a[i]; } $R",
    ),
    xop(
        "reduce_add_tree",
        C_FLOAT,
        U_NONE,
        "return $H(Simd::<$T, 2>::splat(simd::reduce_add_tree(x)));",
        "let mut t = a; let mut h = $Nusize / 2; while h > 0 { for i in 0..h { t[i] = t[i] + t[i + h]; } h = h / 2; } let r = t[0]; $R",
    ),
    xop(
        "reduce_mul_tree",
        C_FLOAT,
        U_NONE,
        "return $H(Simd::<$T, 2>::splat(simd::reduce_mul_tree(x)));",
        "let mut t = a; let mut h = $Nusize / 2; while h > 0 { for i in 0..h { t[i] = t[i] * t[i + h]; } h = h / 2; } let r = t[0]; $R",
    ),
    xop(
        "reduce_min",
        C_INT,
        U_NONE,
        "return $H(Simd::<$T, 2>::splat(simd::reduce_min(x)));",
        "let mut r = a[0]; for i in 1..$Nusize { r = r.min(a[i]); } $R",
    ),
    xop(
        "reduce_max",
        C_INT,
        U_NONE,
        "return $H(Simd::<$T, 2>::splat(simd::reduce_max(x)));",
        "let mut r = a[0]; for i in 1..$Nusize { r = r.max(a[i]); } $R",
    ),
    xop(
        "reduce_min_num",
        C_FLOAT,
        U_NONE,
        "return $H(Simd::<$T, 2>::splat(simd::reduce_min_num(x)));",
        "let mut r = a[0]; for i in 1..$Nusize { r = rmm(r as f64, a[i] as f64, true, false) as $T; } $R",
    ),
    xop(
        "reduce_max_num",
        C_FLOAT,
        U_NONE,
        "return $H(Simd::<$T, 2>::splat(simd::reduce_max_num(x)));",
        "let mut r = a[0]; for i in 1..$Nusize { r = rmm(r as f64, a[i] as f64, false, false) as $T; } $R",
    ),
    xop(
        "reduce_minimum",
        C_FLOAT,
        U_NONE,
        "return $H(Simd::<$T, 2>::splat(simd::reduce_minimum(x)));",
        "let mut r = a[0]; for i in 1..$Nusize { r = rmm(r as f64, a[i] as f64, true, true) as $T; } $R",
    ),
    xop(
        "reduce_maximum",
        C_FLOAT,
        U_NONE,
        "return $H(Simd::<$T, 2>::splat(simd::reduce_maximum(x)));",
        "let mut r = a[0]; for i in 1..$Nusize { r = rmm(r as f64, a[i] as f64, false, true) as $T; } $R",
    ),
    xop(
        "reduce_and",
        C_INT,
        U_NONE,
        "return $H(Simd::<$T, 2>::splat(simd::reduce_and(x)));",
        "let mut r = a[0]; for i in 1..$Nusize { r = r & a[i]; } $R",
    ),
    xop(
        "reduce_or",
        C_INT,
        U_NONE,
        "return $H(Simd::<$T, 2>::splat(simd::reduce_or(x)));",
        "let mut r = a[0]; for i in 1..$Nusize { r = r | a[i]; } $R",
    ),
    xop(
        "reduce_xor",
        C_INT,
        U_NONE,
        "return $H(Simd::<$T, 2>::splat(simd::reduce_xor(x)));",
        "let mut r = a[0]; for i in 1..$Nusize { r = r ^ a[i]; } $R",
    ),
    xop(
        "arg_min",
        C_INT,
        U_NONE,
        "return hmix(0, simd::arg_min(x) as u64);",
        "let mut j = 0usize; for i in 1..$Nusize { if a[i] < a[j] { j = i; } } hr = hmix(0, j as u64);",
    ),
    xop(
        "arg_max",
        C_INT,
        U_NONE,
        "return hmix(0, simd::arg_max(x) as u64);",
        "let mut j = 0usize; for i in 1..$Nusize { if a[i] > a[j] { j = i; } } hr = hmix(0, j as u64);",
    ),
    xop(
        "arg_min_num",
        C_FLOAT,
        U_NONE,
        "return hmix(0, simd::arg_min_num(x).unwrap_or($N) as u64);",
        "let mut j = $Nusize; for i in 0..$Nusize { if a[i] == a[i] && (j == $Nusize || a[i] < a[j] || a[i] == a[j] && a[i].is_sign_negative() && !a[j].is_sign_negative()) { j = i; } } hr = hmix(0, j as u64);",
    ),
    xop(
        "arg_max_num",
        C_FLOAT,
        U_NONE,
        "return hmix(0, simd::arg_max_num(x).unwrap_or($N) as u64);",
        "let mut j = $Nusize; for i in 0..$Nusize { if a[i] == a[i] && (j == $Nusize || a[i] > a[j] || a[i] == a[j] && !a[i].is_sign_negative() && a[j].is_sign_negative()) { j = i; } } hr = hmix(0, j as u64);",
    ),
    xop(
        "dot",
        C_INT,
        U_DOT,
        "return $A(Simd::<$U, 2>::splat(simd::dot::<$U>(x, y)));",
        "let mut r = 0 as $U; for i in 0..$Nusize { r = r.wrapping_add((a[i] as $U).wrapping_mul(b[i] as $U)); } hr = $A(Simd::<$U, 2>::splat(r));",
    ),
    xop(
        "dot_float",
        C_FLOAT,
        U_DOT,
        "return $A(Simd::<$U, 2>::splat(simd::dot::<$U>(x, y)));",
        "let mut r = -0.0 as $U; for i in 0..$Nusize { r = r + (a[i] as $U) * (b[i] as $U); } hr = $A(Simd::<$U, 2>::splat(r));",
    ),
    xop(
        "load_or",
        C_ALL,
        U_NONE,
        "let ax = x.to_array(); return $E(simd::load_or(ax, $Xusize, y));",
        "let st = $Xusize; let mut r = b; for i in 0..$Nusize { if st <= $Nusize && i < $Nusize - st { r[i] = a[st + i]; } } $V",
    ),
    xop(
        "load_masked",
        C_ALL,
        U_NONE,
        "let ax = x.to_array(); return $E(simd::load_masked(ax, $Xusize, Mask::<$N>::from_bits_truncate(m), y));",
        "let st = $Xusize; let mut r = b; for i in 0..$Nusize { if $K { $P r[i] = a[st + i]; } } $V",
    ),
    xop(
        "store_masked",
        C_ALL,
        U_NONE,
        "let mut bx = y.to_array(); simd::store_masked(bx, $Xusize, Mask::<$N>::from_bits_truncate(m), x); return $E(Simd::<$T, $N>::from_array(bx));",
        "let st = $Xusize; let mut r = b; for i in 0..$Nusize { if $K { $P } } for i in 0..$Nusize { if $K { r[st + i] = a[i]; } } $V",
    ),
    xop(
        "gather",
        C_ALL,
        U_INDEX,
        "let ax = x.to_array(); return $E(simd::gather(ax, Simd::<$U, $N>::from_array($X), Mask::<$N>::from_bits_truncate(m), y));",
        "let l: [$U; $N] = $X; let mut r = b; for i in 0..$Nusize { if $K { $G r[i] = a[l[i] as usize]; } } $V",
    ),
    xop(
        "scatter",
        C_ALL,
        U_INDEX,
        "let mut bx = y.to_array(); simd::scatter(bx, Simd::<$U, $N>::from_array($X), Mask::<$N>::from_bits_truncate(m), x); return $E(Simd::<$T, $N>::from_array(bx));",
        "let l: [$U; $N] = $X; let mut r = b; for i in 0..$Nusize { if $K { $G } } for i in 0..$Nusize { if $K { r[l[i] as usize] = a[i]; } } $V",
    ),
    xop(
        "compress_store",
        C_ALL,
        U_NONE,
        "let mut bx = y.to_array(); let k = simd::compress_store(bx, $Xusize, Mask::<$N>::from_bits_truncate(m), x); return hmix($E(Simd::<$T, $N>::from_array(bx)), k as u64);",
        "let st = $Xusize; let mut r = b; let mut k = 0usize; for i in 0..$Nusize { if $K { k += 1; } } if st > $Nusize || k > $Nusize - st { panic(format(\"index out of bounds: {} lanes from {} but the length is {}\", k, st, $Nusize).as_str()); } let mut j = st; for i in 0..$Nusize { if $K { r[j] = a[i]; j += 1; } } hr = hmix($E(Simd::<$T, $N>::from_array(r)), k as u64);",
    ),
];

/// Operations in all: VOPS, LANE_OPS, then XOPS.
pub const OPS_N: u64 = 124;

// The whole-function operation `op` (78 and up).
fn xop_of(op: u8) XOp {
    let x: []XOp = XOPS;
    return x[(op - 78) as usize];
}

/// One case: operation `op` (an index into VOPS, then LANE_OPS, then XOPS) on lane type `t` with `n`
/// lanes, the conversion target `u` (and `m` lanes of it for a bitcast, or of an index list or
/// vector), the inputs' lane literals (a float lane's bits), the scalar operand (a shift count or mask
/// bits), and `x`, an XOp's index list, start, rotation or index vector.
@derive(Clone)
pub struct VCase {
    pub op: u8,
    pub t: u8,
    pub u: u8,
    pub n: u64,
    pub m: u64,
    pub a: Vector<String>,
    pub b: Vector<String>,
    pub c: Vector<String>,
    pub s: String,
    pub x: String,
}

/// The vector model: its cases, at most `cases_max` drawn per program.
@derive(Clone)
pub struct VectorModel {
    pub cases: Vector<VCase>,
    pub cases_max: u64,
}

/// A model of 1 to `cases_max` cases.
pub fn vector_model(cases_max: u64) VectorModel {
    return VectorModel { cases: Vector::<VCase>::new(), cases_max: cases_max };
}

fn lane_name(t: u8) str<'static> {
    let names: []str<'static> = LANE_NAMES;
    return names[t as usize];
}

// The width index of lane type `t`: 0 for 8 bits to 3 for 64.
fn wi(t: u8) u8 {
    if t >= 8 {
        return t - 6;
    }
    return t & 3;
}

/// The bytes of lane type `t`.
pub fn lane_bytes(t: u8) u64 {
    return 1u64 << wi(t) as u64;
}

const fn is_float(t: u8) bool {
    return t >= 8;
}

const fn is_signed(t: u8) bool {
    return t < 4;
}

// The unsigned integer type of `t`'s width: a float lane's storage.
fn store_name(t: u8) str<'static> {
    return lane_name(4 + wi(t));
}

// The kind of lane type `t`: 0 signed, 1 unsigned, 2 float.
fn lane_kind(t: u8) u8 {
    if is_float(t) {
        return 2;
    }
    return ast::pick(is_signed(t), 0u8, 1u8);
}

/// The most lanes of lane type `t`: 512 bits, at most 64 lanes.
pub fn max_lanes(t: u8) u64 {
    return 64 / lane_bytes(t);
}

/// Whether lane type `t` belongs to class `cls`.
pub fn in_class(t: u8, cls: u8) bool {
    if cls == C_ALL {
        return true;
    }
    if cls == C_INT || cls == C_FLOAT {
        return is_float(t) == (cls == C_FLOAT);
    }
    if cls == C_UINT {
        return lane_kind(t) == 1;
    }
    return is_signed(t) || cls == C_SIGNED && is_float(t);
}

/// Whether target `u` (with `m` lanes) suits conversion kind `k` from `n` lanes of `t`.
pub fn target_ok(k: u8, t: u8, n: u64, u: u8, m: u64) bool {
    if k == U_BITCAST {
        return m >= 2 && m <= 64 && lane_bytes(u) * m == lane_bytes(t) * n;
    }
    if lane_bytes(u) * n > 64 {
        return false; // the result would be wider than 512 bits
    }
    if k == U_WIDER {
        return lane_kind(u) == lane_kind(t) && lane_bytes(u) > lane_bytes(t);
    }
    if k == U_UINT || k == U_INDEX {
        return lane_kind(u) == 1 && (k == U_UINT || lane_bytes(u) >= 4) && lane_bytes(u) * m <= 64 && lane_bytes(t) * m <= 64;
    }
    if k == U_DOT {
        return is_float(u) == is_float(t) && lane_bytes(u) >= lane_bytes(t);
    }
    if k == U_NARROWER {
        return !is_float(u) && lane_bytes(u) < lane_bytes(t);
    }
    return k == U_ANY || u == t;
}

/// Whether operation `op` converts to a target type.
pub fn converts(op: u8) bool {
    let ops: []VOp = VOPS;
    return op as u64 < 72 && ops[op as usize].tgt != U_NONE || op >= 78 && xop_of(op).tgt != U_NONE;
}

/// Whether operation `op` applies to `n` lanes of `t` (a rearrangement's result must be a vector).
pub fn op_ok(op: u8, t: u8, n: u64) bool {
    if op as u64 < 72 {
        let ops: []VOp = VOPS;
        return in_class(t, ops[op as usize].cls);
    }
    if op >= 78 {
        return in_class(t, xop_of(op).cls);
    }
    let l = op - 72;
    if l == L_LOW || l == L_HIGH {
        return n >= 4;
    }
    if l == L_CONCAT {
        return n * 2 <= max_lanes(t);
    }
    return l == L_IOTA || is_float(t);
}

// The bits of an interesting float of lane type `t` (8: f32, 9: f64), or random bits.
fn float_bits(rng: &mut Rng, t: u8) String {
    let f32s: []str = [
        "0x00000000", // +0
        "0x80000000", // -0
        "0x7f800000", // +inf
        "0xff800000", // -inf
        "0x7fc00000", // quiet NaN
        "0xffc00001", // negative quiet NaN with a payload
        "0x7fa00000", // signaling NaN
        "0x00000001", // smallest subnormal
        "0x007fffff", // largest subnormal
        "0x00800000", // smallest normal
        "0x7f7fffff", // MAX
        "0x3f800000", // 1.0
        "0xbf800000", // -1.0
        "0x3f000000", // 0.5
        "0x3fc00000", // 1.5
        "0x40200000", // 2.5
        "0xbfc00000", // -1.5
        "0x4b800001", // 16777218.0, past 2^24
        "0x4f000000", // 2^31
        "0xcf000000", // -2^31
    ];
    let f64s: []str = [
        "0x0000000000000000",
        "0x8000000000000000",
        "0x7ff0000000000000",
        "0xfff0000000000000",
        "0x7ff8000000000000",
        "0xfff8000000000001",
        "0x7ff4000000000000",
        "0x0000000000000001",
        "0x000fffffffffffff",
        "0x0010000000000000",
        "0x7fefffffffffffff",
        "0x3ff0000000000000",
        "0xbff0000000000000",
        "0x3fe0000000000000",
        "0x3ff8000000000000",
        "0x4004000000000000",
        "0xbff8000000000000",
        "0x4340000000000001", // 2^53 + 2
        "0x43e0000000000000", // 2^63
        "0xc3e0000000000000", // -2^63
    ];
    let mut s = String::new();
    if rng.one_in(4) {
        // a finite value of moderate exponent, with random mantissa bits
        if t == 8 {
            s.format_into("0x{}", hex(0x30000000u64 + rng.below(0x1C000000) | rng.below(2) << 31));
        } else {
            s.format_into("0x{}", hex(0x3c00000000000000u64 + rng.below(0x0800000000000000) | rng.below(2) << 63));
        }
        return s;
    }
    if t == 8 {
        return String::from_str(f32s[rng.below(f32s.len() as u64) as usize]);
    }
    return String::from_str(f64s[rng.below(f64s.len() as u64) as usize]);
}

fn hex(v: u64) String {
    let mut s = String::new();
    let d = "0123456789abcdef";
    let mut i: u64 = 16;
    let mut started = false;
    while i > 0 {
        i -= 1;
        let x = v >> i * 4 & 15;
        if x != 0 || started || i == 0 {
            s.push_byte(d.byte_at(x as usize));
            started = true;
        }
    }
    return s;
}

// An integer lane literal of `t`, biased to the boundaries; `count` draws a shift count instead
// (-1 to the width + 1), `divisor` favors 0 and -1, `small` draws from -9 to 9 (a case whose
// arithmetic seldom traps).
fn int_lit(rng: &mut Rng, t: u8, count: bool, divisor: bool, small: bool) String {
    let name = lane_name(t);
    let w = lane_bytes(t) * 8;
    let mut s = String::new();
    if count {
        let r = rng.below(5);
        if r == 0 && is_signed(t) {
            s.push_str("-1");
        } else if r == 1 {
            s.push_u64(w);
        } else if r == 2 && w < 64 || r == 2 && !is_signed(t) {
            s.push_u64(w + 1);
        } else {
            s.push_u64(rng.below(w));
        }
        return s;
    }
    if small {
        let v = rng.below(19) as i64 - 9;
        s.push_i64(ast::pick(is_signed(t), v, v.abs()));
        return s;
    }
    let r = rng.below(ast::pick(divisor, 12u64, 10u64));
    if r >= 10 {
        s.push_str(ast::pick(is_signed(t) && r == 11, "-1", "0"));
    } else if r == 0 {
        s.format_into("{}::MIN", name);
    } else if r == 1 {
        s.format_into("{}::MIN + 1", name);
    } else if r == 2 {
        s.push_str(ast::pick(is_signed(t), "-1", "2"));
    } else if r == 3 {
        s.push_str("0");
    } else if r == 4 {
        s.push_str("1");
    } else if r == 5 {
        s.format_into("{}::MAX - 1", name);
    } else if r == 6 {
        s.format_into("{}::MAX", name);
    } else if r == 7 {
        s.push_u64(rng.below(100));
    } else {
        let mut u = rng.next();
        if w < 64 {
            u = u % (1u64 << w);
        }
        if is_signed(t) {
            s.format_into("({}u64 as {})", u, name);
        } else {
            s.push_u64(u);
        }
    }
    return s;
}

fn lanes(rng: &mut Rng, t: u8, n: u64, count: bool, divisor: bool, small: bool) Vector<String> {
    let mut v = Vector::<String>::new();
    for _ in 0..n {
        if is_float(t) {
            v.push(float_bits(rng, t));
        } else {
            v.push(int_lit(rng, t, count, divisor, small && !count));
        }
    }
    return v;
}

/// A case of `op` on `n` lanes of `t`, its inputs from `rng`; a conversion's target is `u` (or drawn,
/// for `u` below 0). False when the target does not suit.
pub fn draw_case(rng: &mut Rng, op: u8, t: u8, n: u64, u: i32, c: &mut VCase) bool {
    *c = VCase {
        op: op,
        t: t,
        u: t,
        n: n,
        m: n,
        a: Vector::<String>::new(),
        b: Vector::<String>::new(),
        c: Vector::<String>::new(),
        s: String::new(),
        x: String::new(),
    };
    if op >= 78 {
        return draw_xcase(rng, op, u, c);
    }
    let ops: []VOp = VOPS;
    let name = if op as u64 < 72 {
        ops[op as usize].name;
    } else {
        "";
    };
    if op as u64 < 72 && ops[op as usize].tgt != U_NONE {
        let k = ops[op as usize].tgt;
        let mut found = false;
        for _ in 0..ast::pick(u < 0, 40, 1) {
            let v = ast::pick(u < 0, rng.below(LANES_N) as u8, u as u8);
            let m = ast::pick(k == U_BITCAST, n * lane_bytes(t) / lane_bytes(v), n);
            if target_ok(k, t, n, v, m) {
                c.u = v;
                c.m = m;
                found = true;
                break;
            }
        }
        if !found {
            return false;
        }
    }
    let count = name == "shl" || name == "shr" || name == "wrapping_shl" || name == "wrapping_shr" || name == "rotate_left" || name == "rotate_right";
    let divisor = name == "div" || name == "rem";
    let small = rng.one_in(2);
    c.a = lanes(rng, t, n, false, false, small);
    c.b = lanes(rng, t, n, count, divisor, small);
    c.c = lanes(rng, t, n, false, false, small);
    if (name == "clamp" || name == "clamp_float") && !rng.one_in(6) {
        // Ordered bounds, so most cases clamp; random bounds (one case in six) mostly trap.
        let lo = if t == 8 {
            "0xbfc00000";
        } else if t == 9 {
            "0xbff8000000000000";
        } else {
            ast::pick(is_signed(t), "-3", "1");
        };
        let hi = if t == 8 {
            "0x40200000";
        } else if t == 9 {
            "0x4004000000000000";
        } else {
            "5";
        };
        for i in 0..n {
            c.b[i as usize] = String::from_str(lo);
            c.c[i as usize] = String::from_str(hi);
        }
    }
    if name == "shl_scalar" || name == "shr_scalar" {
        // the count as the u64 the case passes, cast back to the lane type
        let k = int_lit(rng, t, true, false, false);
        c.s.format_into("({}i64 as u64)", k.as_str());
    } else {
        c.s.format_into("{}", rng.next());
    }
    return true;
}

// A power of two from 2 to the most lanes of `t`.
fn draw_lanes(rng: &mut Rng, t: u8) u64 {
    return 2u64 << rng.below(max_lanes(t).trailing_zeros() as u64);
}

// A start for the `n` lanes of a slice of `n` elements: inside, at its edges, past it, or the largest.
fn draw_start(rng: &mut Rng, n: u64) String {
    let picks: [u64; 6] = [0, 1, n / 2, n - 1, n, n + 1];
    let mut s = String::new();
    if rng.one_in(8) {
        // The target's largest: wasm32's in the vector conformance lane.
        s.push_str(
            if h::simd_lane() {
                "4294967295";
            } else {
                "18446744073709551615";
            },
        );
    } else {
        s.push_u64(unsafe picks[rng.below(6) as usize]);
    }
    return s;
}

// The case `c` (its operation, lanes and type set) of XOp `op`: the inputs, the target `u` (or drawn,
// for `u` below 0), and `x`. False when the target does not suit.
fn draw_xcase(rng: &mut Rng, op: u8, u: i32, c: &mut VCase) bool {
    let o = xop_of(op);
    let t = c.t;
    let n = c.n;
    if o.tgt != U_NONE {
        let mut found = false;
        for _ in 0..ast::pick(u < 0, 40, 1) {
            let v = ast::pick(u < 0, rng.below(LANES_N) as u8, u as u8);
            let m = ast::pick(o.tgt == U_UINT, draw_lanes(rng, ast::pick(lane_bytes(t) > lane_bytes(v), t, v)), n);
            if target_ok(o.tgt, t, n, v, m) {
                c.u = v;
                c.m = m;
                found = true;
                break;
            }
        }
        if !found {
            return false;
        }
    }
    let small = rng.one_in(2);
    c.a = lanes(rng, t, n, false, false, small);
    c.b = lanes(rng, t, n, false, false, small);
    c.c = lanes(rng, t, n, false, false, small);
    c.s.format_into("{}", rng.next());
    let name = o.name;
    if name == "swizzle" || name == "shuffle" {
        c.m = draw_lanes(rng, t);
    }
    if name == "swizzle" || name == "shuffle" || o.tgt == U_UINT || o.tgt == U_INDEX {
        // Indexes inside the operands, at their edges, and (for a run-time index vector) past them and
        // the index type's largest.
        let lim = ast::pick(name == "shuffle", 2 * n, n);
        let past = o.tgt != U_NONE && rng.one_in(2);
        c.x.push_str("[");
        for i in 0..c.m {
            if i != 0 {
                c.x.push_str(", ");
            }
            let r = rng.below(8);
            if past && r == 0 {
                c.x.format_into("{}::MAX", lane_name(c.u));
            } else if past && r == 1 {
                c.x.push_u64(lim + rng.below(2));
            } else if r == 2 {
                c.x.push_u64(lim - 1);
            } else {
                c.x.push_u64(rng.below(lim));
            }
        }
        c.x.push_str("]");
    } else if name.starts_with("rotate") {
        c.x.push_u64(rng.below(2 * n + 1));
    } else {
        c.x = draw_start(rng, n);
    }
    return true;
}

// The array type of `n` lanes of `t` as the inputs carry them (a float's bits).
fn store_arr(t: u8, n: u64) String {
    let mut s = String::new();
    s.format_into("[{}; {}]", ast::pick(is_float(t), store_name(t), lane_name(t)), n);
    return s;
}

fn arr_lit(v: &Vector<String>) String {
    let mut s = String::from_str("[");
    for i in 0..v.len() {
        if i != 0 {
            s.push_str(", ");
        }
        s.push_string(v.at(i));
    }
    s.push_str("]");
    return s;
}

// `tpl` with the placeholders of a case (`VOp`), lane values `a`, `b`, `c` and lane index `i`.
fn expand(tpl: str, cs: &VCase, a: str, b: str, c: str, i: str) String {
    let t = cs.t;
    let mut out = String::new();
    let mut k: usize = 0;
    while k < tpl.len() {
        let ch = tpl.byte_at(k);
        k += 1;
        if ch != b'$' {
            out.push_byte(ch);
            continue;
        }
        let p = tpl.byte_at(k);
        k += 1;
        switch p {
            b'a' => out.push_str(a),
            b'b' => out.push_str(b),
            b'c' => out.push_str(c),
            b'i' => out.push_str(i),
            b'T' => out.push_str(lane_name(t)),
            b'U' => out.push_str(lane_name(cs.u)),
            b'Q' => out.push_str(lane_name(4 + wi(t))),
            b'W' => out.push_u64(lane_bytes(t) * 8),
            b'F' => out.push_str(lane_name(t)),
            b'N' => out.push_u64(cs.n),
            b'M' => out.push_u64(cs.m),
            b'Z' => out.push_str(ast::pick(t == 8, "0x80000000u32", "0x8000000000000000u64")),
            b'L' => out.push_str(ast::pick(t == 8, "1.1754943508222875e-38", "2.2250738585072014e-308")),
            b'C' => out.push_str(changed(cs, a).as_str()),
            b'S' => out.push_str(saturate(cs, a).as_str()),
            b'X' => out.push_string(&cs.x),
            b'E' => out.push_str(hash_fn(t, true).as_str()),
            b'H' => out.push_str(hash_fn(t, false).as_str()),
            b'A' => out.push_str(hash_fn(cs.u, false).as_str()),
            b'K' => out.push_str("(m >> i as u64 & 1) != 0"),
            b'V' => out.push_str(expand("hr = $E(Simd::<$T, $N>::from_array(r));", cs, a, b, c, i).as_str()),
            b'R' => out.push_str(expand("hr = $H(Simd::<$T, 2>::splat(r));", cs, a, b, c, i).as_str()),
            b'P' => out.push_str(
                expand(
                    "if st > $Nusize || i >= $Nusize - st { panic(format(\"index out of bounds: the index is {} + {} but the length is {}\", st, i, $Nusize).as_str()); }",
                    cs,
                    a,
                    b,
                    c,
                    i,
                ).as_str(),
            ),
            b'G' => out.push_str(
                expand(
                    "if l[i] as u64 >= $Nu64 { panic(format(\"index out of bounds: the index is {} but the length is {}\", l[i], $Nusize).as_str()); }",
                    cs,
                    a,
                    b,
                    c,
                    i,
                ).as_str(),
            ),
            _ => out.push_byte(p),
        };
    }
    return out;
}

// Whether `a` (a lane of `cs.t`) changes in a cast to `cs.u`, or is a NaN: the scalar form of the
// changed-lane mask.
fn changed(cs: &VCase, a: str) String {
    let t = cs.t;
    let u = cs.u;
    let tn = lane_name(t);
    let un = lane_name(u);
    let mut s = String::new();
    if is_float(t) && is_float(u) {
        s.format_into("({} != {} || ({} as {}) as {} != {})", a, a, a, un, tn, a);
    } else if is_float(t) {
        let w = lane_bytes(u) * 8 - ast::pick(is_signed(u), 1u64, 0u64);
        let lo = fpow(w, true, is_signed(u));
        s.format_into(
            "!({} >= {} && {} < {} && {}.trunc() == {})",
            a,
            lo.as_str(),
            a,
            fpow(w, false, true).as_str(),
            a,
            a,
        );
    } else if is_float(u) {
        let w = lane_bytes(t) * 8 - ast::pick(is_signed(t), 1u64, 0u64);
        s.format_into(
            "!(({} as {}) >= {} && ({} as {}) < {} && (({} as {}) as {}) == {})",
            a,
            un,
            fpow(w, true, is_signed(t)).as_str(),
            a,
            un,
            fpow(w, false, true).as_str(),
            a,
            un,
            tn,
            a,
        );
    } else {
        s.format_into("(({} as {}) as {} != {}", a, un, tn, a);
        if is_signed(t) && !is_signed(u) {
            s.format_into(" || {} < 0", a);
        } else if !is_signed(t) && is_signed(u) {
            s.format_into(" || ({} as {}) < 0", a, un);
        }
        s.push_str(")");
    }
    return s;
}

// The float literal 2^w (or -2^w), or 0.0 when not `some`.
fn fpow(w: u64, neg: bool, some: bool) String {
    if !some {
        return String::from_str("0.0");
    }
    let mut s = String::from_str(ast::pick(neg, "-", ""));
    let mut v = 1.0;
    for _ in 0..w {
        v = v * 2.0;
    }
    s.format_into("{}.0", v as u64);
    if w == 64 {
        s = String::from_str(ast::pick(neg, "-18446744073709551616.0", "18446744073709551616.0"));
    }
    return s;
}

// The scalar form of `narrow_saturating` from `cs.t` to the narrower integer `cs.u`.
fn saturate(cs: &VCase, a: str) String {
    let tn = lane_name(cs.t);
    let un = lane_name(cs.u);
    let mut s = String::new();
    if !is_signed(cs.t) {
        s.format_into("pick({} > ({}::MAX as {}), {}::MAX, {} as {})", a, un, tn, un, a, un);
    } else if !is_signed(cs.u) {
        s.format_into("pick({} < 0, 0, pick({} > ({}::MAX as {}), {}::MAX, {} as {}))", a, a, un, tn, un, a, un);
    } else {
        s.format_into(
            "pick({} < ({}::MIN as {}), {}::MIN, pick({} > ({}::MAX as {}), {}::MAX, {} as {}))",
            a,
            un,
            tn,
            un,
            a,
            un,
            tn,
            un,
            a,
            un,
        );
    }
    return s;
}

// The hash function of a vector of `n` lanes of `t`: `hv_<t>`, or for a float the NaN-canonical
// `hc_<t>` unless `exact`.
fn hash_fn(t: u8, exact: bool) String {
    let mut s = String::new();
    s.format_into("{}_{}", ast::pick(is_float(t) && !exact, "hc", "hv"), lane_name(t));
    return s;
}

/// The helper functions every program of the model shares: the hashes, and the scalar forms'
/// helpers (`rmm` IEEE min/max, `rrot` rotation, `rperm` bit and byte reversal, `rfit` the narrow
/// trap, `rbits` a bitcast).
pub fn helpers() String {
    let mut s = String::from_str("import std::simd;\nimport math;\nimport string;\nimport signal;\nimport stdlib;\n");
    s.push_str(
        "const fn pick<T: Copy>(c: bool, a: T, b: T) T {\n    if c {\n        return a;\n    }\n    return b;\n}\n",
    );
    s.push_str("const fn hmix(h: u64, x: u64) u64 {\n    return (h ^ x).wrapping_mul(0x100000001B3);\n}\n");
    let names: []str = LANE_NAMES;
    for k in 0..10 {
        let t = names[k];
        if k < 8 {
            s.format_into(
                "const fn hv_{}<const N: usize>(v: Simd<{}, N>) u64 {{\n    let mut h: u64 = N as u64;\n    for x in v.to_array() {{\n        h = hmix(h, x as u64);\n    }}\n    return h;\n}}\n",
                t,
                t,
            );
        } else {
            let q = ast::pick(k == 8, "u32", "u64");
            s.format_into(
                "const fn hv_{}<const N: usize>(v: Simd<{}, N>) u64 {{\n    return hv_{}(v.to_bits());\n}}\n",
                t,
                t,
                q,
            );
            s.format_into(
                "const fn hc_{}<const N: usize>(v: Simd<{}, N>) u64 {{\n    return hv_{}(v.is_nan().choose(Simd::<{}, N>::splat({}), v.to_bits()));\n}}\n",
                t,
                t,
                q,
                q,
                ast::pick(k == 8, "0x7fc00000", "0x7ff8000000000000"),
            );
        }
    }
    s.push_str("const fn hm<const N: usize>(m: Mask<N>) u64 {\n    return hmix(N as u64, m.to_bits());\n}\n");
    s.push_str("fn rmm(a: f64, b: f64, min: bool, nan: bool) f64 {\n    if a != a || b != b {\n");
    s.push_str("        return pick(nan, pick(a != a, a, b), pick(a != a, b, a));\n    }\n    if a != b {\n");
    s.push_str(
        "        return pick((a < b) == min, a, b);\n    }\n    return pick(a.is_sign_negative() == min, a, b);\n}\n",
    );
    s.push_str(
        "fn rrot(x: u64, k: u64, w: u64, left: bool) u64 {\n    let n = k % w;\n    if n == 0 {\n        return x;\n    }\n",
    );
    s.push_str(
        "    let m = if w == 64 {\n        0xFFFFFFFFFFFFFFFFu64;\n    } else {\n        (1u64 << w) - 1;\n    };\n",
    );
    s.push_str("    let r = pick(left, x << n | x >> (w - n), x >> n | x << (w - n));\n    return r & m;\n}\n");
    s.push_str("fn rperm(x: u64, w: u64, step: u64) u64 {\n    let mut r: u64 = 0;\n    let mut j: u64 = 0;\n");
    s.push_str(
        "    while j < w {\n        r = r | (x >> j & (1u64 << step) - 1) << (w - step - j);\n        j += step;\n    }\n    return r;\n}\n",
    );
    s.push_str(
        "fn rfit<V>(bad: bool, v: V) V {\n    if bad {\n        panic(\"attempt to narrow a lane that does not fit\");\n    }\n    return v;\n}\n",
    );
    s.push_str(
        "fn rbits<T: Copy, const N: usize, U: Copy, const M: usize>(a: [T; N], z: U) [U; M] {\n    let mut r = [z; M];\n",
    );
    s.push_str(
        "    unsafe string::memcpy(&mut r as *mut [U; M] as *mut void, &a as *const [T; N] as *const void, sizeof([T; N]));\n    return r;\n}\n",
    );
    return s;
}

/// The vector function of case `k` (`vk<k>`), over the inputs as arrays, and its hash.
pub fn case_vec(cs: &VCase, k: usize, out: &mut String) {
    let t = cs.t;
    let tn = lane_name(t);
    let arr = store_arr(t, cs.n);
    out.format_into("const fn vk{}(a: {}, b: {}, c: {}, s0: u64) u64 {{\n", k, arr.as_str(), arr.as_str(), arr.as_str());
    for p in ["x", "y", "z"] {
        let src = ast::pick(p == "x", "a", ast::pick(p == "y", "b", "c"));
        if is_float(t) {
            out.format_into(
                "    let {} = Simd::<{}, {}>::from_bits(Simd::<{}, {}>::from_array({}));\n",
                p,
                tn,
                cs.n,
                store_name(t),
                cs.n,
                src,
            );
        } else {
            out.format_into("    let {} = Simd::<{}, {}>::from_array({});\n", p, tn, cs.n, src);
        }
    }
    out.format_into("    let m = s0;\n    let _ = m;\n    let s = s0 as {};\n", ast::pick(is_float(t), "u64", tn));
    out.push_str("    let _ = x;\n    let _ = y;\n    let _ = z;\n    let _ = s;\n");
    if cs.op >= 78 {
        out.format_into("    {}\n}}\n", expand(xop_of(cs.op).vbody, cs, "", "", "", "").as_str());
        return;
    }
    if cs.op as u64 >= 72 {
        let l = cs.op - 72;
        let forms: []str = [
            "x.low_half()",
            "x.high_half()",
            "simd::concat(x, y)",
            "simd::iota::<$T, $N>()",
            "x.to_bits()",
            "Simd::<$T, $N>::from_bits(x.to_bits())",
        ];
        let e = forms[l as usize];
        let rt = ast::pick(l == L_TO_BITS, 4 + wi(t), t);
        out.format_into("    return {}({});\n}}\n", hash_fn(rt, true).as_str(), expand(e, cs, "", "", "", "").as_str());
        return;
    }
    let ops: []VOp = VOPS;
    let o = ops[cs.op as usize];
    let e = expand(o.vexpr, cs, "", "", "", "");
    if o.res == R_MASK {
        out.format_into("    return hm({});\n}}\n", e.as_str());
    } else if o.res == R_PAIR || o.res == R_UPAIR {
        let ht = ast::pick(o.res == R_PAIR, t, cs.u);
        out.format_into(
            "    let (r, mk) = {};\n    return hmix({}(r), hm(mk));\n}}\n",
            e.as_str(),
            hash_fn(ht, false).as_str(),
        );
    } else {
        let ht = if o.res == R_VEC {
            t;
        } else if o.name == "abs_diff" {
            4 + wi(t);
        } else {
            cs.u;
        };
        out.format_into("    return {}({});\n}}\n", hash_fn(ht, o.exact).as_str(), e.as_str());
    }
}

/// The scalar function of case `k` (`rk<k>`): every lane through the scalar form, then the same hash.
pub fn case_ref(cs: &VCase, k: usize, out: &mut String) {
    let t = cs.t;
    let tn = lane_name(t);
    let un = lane_name(cs.u);
    let n = cs.n;
    let arr = store_arr(t, n);
    out.format_into("fn rk{}(a0: {}, b0: {}, c0: {}, s0: u64) u64 {{\n", k, arr.as_str(), arr.as_str(), arr.as_str());
    out.format_into("    let mut a = [0 as {}; {}];\n    let mut b = a;\n    let mut c = a;\n", tn, n);
    out.format_into("    for i in 0..{}usize {{\n", n);
    if is_float(t) {
        out.format_into(
            "        unsafe {{ a[i] = {}_from_bits(a0[i]); b[i] = {}_from_bits(b0[i]); c[i] = {}_from_bits(c0[i]); }}\n",
            tn,
            tn,
            tn,
        );
    } else {
        out.push_str("        unsafe { a[i] = a0[i]; b[i] = b0[i]; c[i] = c0[i]; }\n");
    }
    out.format_into(
        "    }}\n    let m = s0;\n    let _ = m;\n    let s = s0 as {};\n    let _ = s;\n",
        ast::pick(is_float(t), "u64", tn),
    );
    if cs.op >= 78 {
        out.format_into(
            "    let mut hr: u64 = 0;\n    unsafe {{\n        {}\n    }}\n    return hr;\n}}\n",
            expand(xop_of(cs.op).rbody, cs, "", "", "", "").as_str(),
        );
        return;
    }
    if cs.op as u64 >= 72 {
        let l = cs.op - 72;
        if l == L_TO_BITS || l == L_FROM_BITS {
            out.format_into(
                "    return hv_{}(Simd::<{}, {}>::from_array(a0));\n}}\n",
                lane_name(4 + wi(t)),
                lane_name(4 + wi(t)),
                n,
            );
            return;
        }
        let rn = if l == L_LOW || l == L_HIGH {
            n / 2;
        } else if l == L_CONCAT {
            n * 2;
        } else {
            n;
        };
        out.format_into("    let mut r = [0 as {}; {}];\n    for i in 0..{}usize {{\n", tn, rn, rn);
        let forms: []str = ["a[i]", "a[i + $N / 2]", "pick(i < $N, a[i % $N], b[i % $N])", "i as $T"];
        let e = forms[l as usize];
        out.format_into("        unsafe {{ r[i] = {}; }}\n    }}\n", expand(e, cs, "", "", "", "").as_str());
        out.format_into("    return {}(Simd::<{}, {}>::from_array(r));\n}}\n", hash_fn(t, true).as_str(), tn, rn);
        return;
    }
    let ops: []VOp = VOPS;
    let o = ops[cs.op as usize];
    if o.name == "clamp" || o.name == "clamp_float" {
        out.format_into("    for i in 0..{}usize {{\n        if unsafe !(b[i] <= c[i]) {{\n", n);
        out.push_str("            panic(\"Simd::clamp: a lane has lo > hi or a NaN bound\");\n        }\n    }\n");
    }
    if o.res == R_BITS {
        out.format_into("    let r = rbits::<{}, {}, {}, {}>(a, 0 as {});\n", tn, n, un, cs.m, un);
        out.format_into("    return {}(Simd::<{}, {}>::from_array(r));\n}}\n", hash_fn(cs.u, true).as_str(), un, cs.m);
        return;
    }
    let rt = if o.res == R_VEC || o.res == R_PAIR {
        tn;
    } else if o.name == "abs_diff" {
        lane_name(4 + wi(t));
    } else {
        un;
    };
    if o.res == R_MASK {
        out.push_str("    let mut bits: u64 = 0;\n");
    } else {
        out.format_into("    let mut r = [0 as {}; {}];\n", rt, n);
    }
    if o.res == R_PAIR || o.res == R_UPAIR {
        out.push_str("    let mut bits: u64 = 0;\n");
    }
    out.format_into("    for i in 0..{}usize {{\n", n);
    out.push_str("        let av = unsafe a[i];\n        let bv = unsafe b[i];\n        let cv = unsafe c[i];\n");
    out.push_str("        let _ = av;\n        let _ = bv;\n        let _ = cv;\n");
    let e = expand(o.rexpr, cs, "av", "bv", "cv", "i as u64");
    if o.res == R_MASK {
        out.format_into("        if {} {{\n            bits = bits | 1u64 << i as u64;\n        }}\n", e.as_str());
    } else if o.res == R_PAIR {
        out.format_into("        let (v, o) = {};\n        unsafe {{ r[i] = v; }}\n", e.as_str());
        out.push_str("        if o {\n            bits = bits | 1u64 << i as u64;\n        }\n");
    } else if o.res == R_UPAIR {
        out.format_into("        unsafe {{ r[i] = {}; }}\n", e.as_str());
        out.format_into(
            "        if {} {{\n            bits = bits | 1u64 << i as u64;\n        }}\n",
            changed(cs, "av").as_str(),
        );
    } else {
        out.format_into("        unsafe {{ r[i] = {}; }}\n", e.as_str());
    }
    out.push_str("    }\n");
    if o.res == R_MASK {
        out.format_into("    return hm(Mask::<{}>::from_bits_truncate(bits));\n}}\n", n);
    } else if o.res == R_PAIR || o.res == R_UPAIR {
        let ht = ast::pick(o.res == R_PAIR, t, cs.u);
        out.format_into(
            "    return hmix({}(Simd::<{}, {}>::from_array(r)), hm(Mask::<{}>::from_bits_truncate(bits)));\n}}\n",
            hash_fn(ht, false).as_str(),
            rt,
            n,
            n,
        );
    } else {
        let ht = if o.res == R_VEC {
            t;
        } else if o.name == "abs_diff" {
            4 + wi(t);
        } else {
            cs.u;
        };
        out.format_into("    return {}(Simd::<{}, {}>::from_array(r));\n}}\n", hash_fn(ht, o.exact).as_str(), rt, n);
    }
}

/// Case `cs`'s call of `fname` (`vk<k>` or `rk<k>`) on its inputs, each through `wrap` (`opq` for a
/// constant, `opr` at run time).
pub fn case_call(cs: &VCase, fname: str, k: usize, wrap: str) String {
    let arr = store_arr(cs.t, cs.n);
    let mut s = String::new();
    s.format_into(
        "{}{}({}::<{}>({}), {}::<{}>({}), {}::<{}>({}), {}::<u64>({}))",
        fname,
        k,
        wrap,
        arr.as_str(),
        arr_lit(&cs.a).as_str(),
        wrap,
        arr.as_str(),
        arr_lit(&cs.b).as_str(),
        wrap,
        arr.as_str(),
        arr_lit(&cs.c).as_str(),
        wrap,
        cs.s.as_str(),
    );
    return s;
}

/// The name of case `cs`'s operation.
pub fn op_name(cs: &VCase) str<'static> {
    if cs.op >= 78 {
        return xop_of(cs.op).name;
    }
    if cs.op as u64 >= 72 {
        let l: []str<'static> = LANE_OPS;
        return l[(cs.op - 72) as usize];
    }
    let ops: []VOp = VOPS;
    return ops[cs.op as usize].name;
}

/// The program of `cases`: each case's vector function as the constant `PARITY_C<k>` (unless
/// `omit[k]`, a constant that traps) and at run time, and its scalar function. `prog k v` runs the
/// cases from `k` on and prints to stderr, per case, `R <k>`, the constant (`C <k> <value>`) and the
/// run-time value (`V <k> <value>`); `prog k r` prints `R <k>` and the scalar value (`S <k> <value>`).
/// A trap ends the run after the `R` line of its case, with status 134 and no crash report or core dump,
/// which cost more than the run.
pub fn program(cases: &Vector<VCase>, omit: &Vector<bool>) String {
    let mut s = helpers();
    s.push_str("fn parity_abort(_sig: i32) {\n    unsafe stdlib::exit_now(134);\n}\n");
    s.push_str("const fn opq<T>(x: T) T {\n    return x;\n}\n");
    s.push_str(
        "static mut SINK: usize = 0;\n@c.noinline\nfn opr<T>(x: T) T {\n    unsafe SINK += 1;\n    return x;\n}\n",
    );
    for k in 0..cases.len() {
        case_vec(cases.at(k), k, &mut s);
        case_ref(cases.at(k), k, &mut s);
        if !omit[k] {
            s.format_into("const PARITY_C{}: u64 = {};\n", k, case_call(cases.at(k), "vk", k, "opq").as_str());
        }
    }
    s.push_str(
        "fn main(args: Vector<str>) i32 {\n    let _ = unsafe signal::signal(signal::SIGABRT, parity_abort);\n    let from = args.at(1).parse_i64().unwrap();\n    let v = args.at(2) == \"v\";\n",
    );
    for k in 0..cases.len() {
        s.format_into("    if from <= {} {{\n        eprintln(\"R {}\");\n", k, k);
        if !omit[k] {
            s.format_into("        if v {{\n            eprintln(\"C {} {{}}\", PARITY_C{});\n        }}\n", k, k);
        }
        s.format_into(
            "        if v {{\n            eprintln(\"V {} {{}}\", {});\n",
            k,
            case_call(cases.at(k), "vk", k, "opr").as_str(),
        );
        s.format_into(
            "        }} else {{\n            eprintln(\"S {} {{}}\", {});\n        }}\n    }}\n",
            k,
            case_call(cases.at(k), "rk", k, "opr").as_str(),
        );
    }
    s.push_str("    return 0;\n}\n");
    return s;
}

// A trap's text without the runtime's prefix, and without a vector trap's lane when `lane` is false:
// the scalar loop traps with the same text at the same first lane.
fn trap_core(t: str, lane: bool) String {
    let mut s = t;
    for p in ["super-c: ", "panic: "] {
        if s.starts_with(p) {
            s = s.slice(p.len(), s.len());
        }
    }
    if !lane && s.starts_with("lane ") {
        let c = s.find(": ");
        if c >= 0 {
            s = s.slice(c as usize + 2, s.len());
        }
    }
    return String::from_str(s);
}

/// Run every case of program `b` in `mode` (`v` or `r`): one process from the first case, and after a
/// trap one more from the next case. `out[k]` gets each tagged value (`C`, `V`, `S`: "<tag> <value>"), or
/// "trap: <message>" for the case that trapped; `bad` notes a sanitizer report.
pub fn run_all(b: &h::DiffBuild, n: usize, mode: str, out: &mut Vector<String>, bad: &mut String) {
    let mut from: usize = 0;
    while from < n {
        let mut args = String::new();
        args.format_into("{} {}", from, mode);
        let r = h::diff_run(b, args.as_str());
        if r.err.contains("runtime error:") || r.err.contains("Sanitizer") {
            bad.format_into("a sanitizer report from case {} on:\n{}\n", from, r.err.as_str());
        }
        let mut last = from;
        for line in r.err.as_str().lines() {
            if line.starts_with("R ") {
                last = line.slice(2, line.len()).parse_usize().unwrap();
            } else if line.starts_with("C ") || line.starts_with("V ") || line.starts_with("S ") {
                let sp = line.find(" ") as usize + 1;
                let rest = line.slice(sp, line.len());
                let k = rest.slice(0, rest.find(" ") as usize).parse_usize().unwrap();
                out[k].push_str(line.slice(0, 2));
                out[k].push_str(rest.slice(rest.find(" ") as usize + 1, rest.len()));
                out[k].push_str("\n");
            } else if line.starts_with("super-c: ") || line.starts_with("panic: ") {
                out[last].format_into("trap: {}\n", line);
            }
        }
        if r.exit == 0 {
            return;
        }
        from = last + 1;
    }
}

// The line of `text` tagged `tag` (`C `, `V `, `S `) without its tag, or the trap line's message.
fn value_of(text: &String, tag: str, lane: bool) String {
    for line in text.as_str().lines() {
        if line.starts_with(tag) {
            return String::from_str(line.slice(2, line.len()));
        }
        if line.starts_with("trap: ") {
            return trap_core(line.slice(6, line.len()), lane);
        }
    }
    return String::new();
}

/// Both oracles on `cases`: each case's constant equals its run-time value, or the constant's error
/// is the run-time trap (with its lane); and its run-time value equals its scalar loop's, or both trap
/// with the same message. Empty when every case agrees, else each difference.
pub fn check_cases(cases: &Vector<VCase>) String {
    let n = cases.len();
    let mut r = String::new();
    let mut omit = Vector::<bool>::new();
    let mut ctrap = Vector::<String>::new();
    let mut vout = Vector::<String>::new();
    let mut sout = Vector::<String>::new();
    for _ in 0..n {
        omit.push(false);
        ctrap.push(String::new());
        vout.push(String::new());
        sout.push(String::new());
    }
    let mut b = h::diff_build(program(cases, &omit).as_str(), ["--profile=ubsan"]);
    if !b.built {
        // Each constant that traps is an error at it: note the trap's detail, and build without it.
        for line in b.diag.as_str().lines() {
            let at = line.find("constant 'PARITY_C");
            let ct = line.find("compile time: ");
            if !line.starts_with("error:") || at < 0 || ct < 0 {
                continue;
            }
            let ks = line.slice(at as usize + 18, line.len());
            let k = ks.slice(0, ks.find("'") as usize).parse_usize().unwrap();
            let d = line.slice(ct as usize + 14, line.len());
            let stack = d.find(" (call stack");
            omit[k] = true;
            ctrap[k] = String::from_str(
                if stack >= 0 {
                    d.slice(0, stack as usize);
                } else {
                    d;
                },
            );
        }
        b = h::diff_build(program(cases, &omit).as_str(), ["--profile=ubsan"]);
        if !b.built {
            r.format_into("the program does not build:\n{}", b.diag.as_str());
            return r;
        }
    }
    run_all(&b, n, "v", &mut vout, &mut r);
    run_all(&b, n, "r", &mut sout, &mut r);
    for k in 0..n {
        let c = if omit[k] {
            ctrap[k].clone();
        } else {
            value_of(&vout[k], "C ", true);
        };
        let x = value_of(&vout[k], "V ", true);
        let xcore = value_of(&vout[k], "V ", false);
        let y = value_of(&sout[k], "S ", false);
        if c.len() == 0 || !c.equals(&x) || !xcore.equals(&y) {
            let cs = cases.at(k);
            r.format_into(
                "case {}: {} on {} lanes of {} (target {}): {}\n  const:  {}\n  vector: {}\n  scalar: {}\n",
                k,
                op_name(cs),
                cs.n,
                lane_name(cs.t),
                lane_name(cs.u),
                case_call(cs, "vk", k, "opq").as_str(),
                c.as_str(),
                x.as_str(),
                y.as_str(),
            );
        }
    }
    return r;
}

extend VectorModel as Model {
    pub fn name(self: &Self) str<'static> {
        return "vector";
    }

    pub fn generate(self: &mut Self, rng: &mut Rng) {
        self.cases.clear();
        let n = 1 + rng.below(self.cases_max);
        while self.cases.len() as u64 < n {
            let op = rng.below(OPS_N) as u8;
            let t = rng.below(LANES_N) as u8;
            let lanes: [u64; 3] = [2, 4, max_lanes(t)];
            let ln = unsafe lanes[rng.below(3) as usize];
            let mut c = VCase {};
            if op_ok(op, t, ln) && draw_case(rng, op, t, ln, -1, &mut c) {
                self.cases.push(c);
            }
        }
    }

    pub fn oracles(self: &Self) usize {
        return 1;
    }

    pub fn check(self: &Self, k: usize) String {
        assert(k == 0);
        return check_cases(&self.cases);
    }

    pub fn render(self: &Self, k: usize) String {
        assert(k == 0);
        let mut omit = Vector::<bool>::new();
        for _ in 0..self.cases.len() {
            omit.push(false);
        }
        return program(&self.cases, &omit);
    }

    // Keep only case c, or drop case c.
    pub fn candidates(self: &Self) usize {
        return 2 * self.cases.len();
    }

    pub fn reduce(self: &mut Self, i: usize) bool {
        let n = self.cases.len();
        if n == 1 {
            return false;
        }
        if i < n {
            let keep = self.cases.at(i).clone();
            self.cases.clear();
            self.cases.push(keep);
        } else {
            let _ = self.cases.remove(i - n);
        }
        return true;
    }
}
