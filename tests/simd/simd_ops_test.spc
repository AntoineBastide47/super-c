// The lane operations of std/simd.spc (the vector model, tests/gen/vector.spc): every operation over
// every lane type and 2, 4 and the most lanes with boundary inputs, as a constant and at run time and
// against a scalar lane loop; every conversion pair; the operators' diagnostics; vector loads and
// stores at the bounds; the borrow rules of a store; and the generator's fixed seeds.
import tests::gen::driver as gen;
import tests::gen::vector as vec;
import tests::harness as h;
import tests::cli_harness as cli;
import std::cpu;
import std::cpu::detect as detect;

// Both oracles over every case of the operations `ops` (every lane type, 2, 4 and the most lanes, and
// for a conversion every target), in programs of at most 256 cases.
fn sweep(ops: []u8) {
    let mut cases = Vector::<vec::VCase>::new();
    for op in ops {
        let mut rng = gen::Rng::new(op as u64 * 7919 + 1);
        for t in 0..10u8 {
            let most = vec::max_lanes(t);
            for n in [2u64, 4, most] {
                if n == 4 && most == 4 || !vec::op_ok(op, t, n) {
                    continue;
                }
                for u in -1..10 {
                    let mut c = vec::VCase {};
                    if u >= 0 == vec::converts(op) && vec::draw_case(&mut rng, op, t, n, u, &mut c) {
                        cases.push(c);
                    }
                }
            }
        }
    }
    let mut i: usize = 0;
    while i < cases.len() {
        let mut part = Vector::<vec::VCase>::new();
        while part.len() < 256 && i < cases.len() {
            part.push(cases.at(i).clone());
            i += 1;
        }
        let r = vec::check_cases(&part);
        if r.len() != 0 {
            eprintln("{}", r.as_str());
        }
        assert(r.len() == 0, "a vector operation differs");
    }
}

@test
fn operators_match_constants_and_scalar_loops() {
    sweep([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]);
}

@test
fn comparisons_and_choose_match_constants_and_scalar_loops() {
    sweep([14, 15, 16, 17, 18, 19, 20, 21]);
}

@test
fn wrapping_checked_saturating_min_max_match() {
    sweep([22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34]);
}

@test
fn integer_lane_functions_match() {
    sweep([39, 41, 43, 44, 45, 46, 47, 48, 49, 50, 51]);
}

@test
fn float_lane_functions_match() {
    sweep([35, 36, 37, 38, 40, 42, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64]);
}

@test
fn casts_of_every_lane_type_pair_match() {
    sweep([65, 66]);
}

@test
fn widen_narrow_and_bitcast_match() {
    sweep([67, 68, 69, 70, 71]);
}

@test
fn halves_concat_iota_and_bits_match() {
    sweep([72, 73, 74, 75, 76, 77]);
}

@test
fn rearrangements_match() {
    sweep([78, 79, 80, 81, 82, 83, 84]);
}

@test
fn interleaves_compress_and_expand_match() {
    sweep([85, 86, 87, 88, 89, 90, 91, 92]);
}

@test
fn integer_reductions_match() {
    sweep([93, 94, 95, 96, 97, 98, 103, 104, 109, 110, 111, 112, 113]);
}

@test
fn float_reductions_and_dot_match() {
    sweep([99, 100, 101, 102, 105, 106, 107, 108, 114, 115, 116, 117]);
}

@test
fn masked_loads_and_stores_match() {
    sweep([118, 119, 120, 123]);
}

const OPERATIONS: str = M"(import std::simd;
// A store of a vector loaded from the same slice one element before writes the loaded lanes, as if
// every lane were read before the first write.
fn main_0(args: Vector<str>) i32 {
    let mut a = [0.0f32; 17];
    let s: []mut f32 = a;
    for k in 0..17usize {
        s[k] = (k + args.len() - 1) as f32;
    }
    let v = simd::load::<f32, 16>(s, 0) + Simd::<f32, 16>::splat(100.0);
    simd::store(s, 1, v);
    for k in 1..17usize {
        if s[k] != (k + 99) as f32 {
            return 1;
        }
    }
    return 0;
}
// A lane scalar beside an operator is the scalar in every lane: a variable, a literal and literal-only
// arithmetic, on either side, in concrete code and in code generic over the lanes.
fn axpy<T: SimdFloat, const N: usize>(a: T, x: Simd<T, N>, y: Simd<T, N>) Simd<T, N> {
    return x * a + y;
}
fn axpy_left<T: SimdFloat, const N: usize>(a: T, x: Simd<T, N>, y: Simd<T, N>) Simd<T, N> {
    return a * x + y;
}
fn twice<T: SimdInt, const N: usize>(x: Simd<T, N>) Simd<T, N> {
    return x + x;
}
fn main_1(args: Vector<str>) i32 {
    let k = args.len() as f32;
    let v = Simd::<f32, 8>::splat(k + 1.0);
    let a = v * 3.0 + k - 0.5;
    let q = v / (1.0 + 3.0);
    let w = Simd::<u8, 16>::splat(args.len() as u8 * 200);
    let b = w ^ (3 | 4) * 2;
    let c = (w % 7 & 6 | 1) - 1u8;
    let r = axpy::<f32, 4>(2.0, Simd::<f32, 4>::splat(k), Simd::<f32, 4>::splat(1.0));
    let t = twice::<i16, 8>(Simd::<i16, 8>::splat(3));
    if a[7] != 6.5 || q[0] != 0.5 || b[15] != 198 || c[3] != 4 || r[2] != 3.0 || t[7] != 6 {
        return 1;
    }
    let l = 3.0 * v + k;
    let m = 10.0 - v;
    let s = 1u8 << Simd::<u8, 16>::splat(args.len() as u8 * 3);
    let e = 200 - w ^ 1;
    let rl = axpy_left::<f32, 4>(2.0, Simd::<f32, 4>::splat(k), Simd::<f32, 4>::splat(1.0));
    if l[0] != 7.0 || m[1] != 8.0 || s[2] != 8 || e[3] != 1 || rl[0] != 3.0 {
        return 2;
    }
    return 0;
}
// Vector operators through generic code over a bound (`Add`, `SimdSigned`), a free generic function as
// a value, an unqualified prelude function with a turbofish, compound assignments with a lane shift
// count, and both forms of `choose`.
fn sum3<V: Add<Output = V> + Copy>(a: V, b: V, c: V) V {
    return a + b + c;
}
fn neg<T: SimdSigned, const N: usize>(v: Simd<T, N>) Simd<T, N> {
    return -v;
}
fn main_2() i32 {
    let a = Simd::<f32, 4>::from_array([1.0, -2.0, 3.0, 0.5]);
    let s = sum3(a, a, a);
    let f = simd::concat::<f32, 4>;
    let r = f(s * s, s).sqrt().low_half();
    let m = r.greater_than(a);
    let c = simd::choose(m, r, a) + m.choose(a, r);
    let n = neg(Simd::<i8, 4>::splat(5));
    let mut k = iota::<u16, 8>();
    k <<= 2;
    k >>= 1u16;
    k += Simd::<u16, 8>::splat(1);
    if s[1] != -6.0 || r[1] != 6.0 || c[3] != 2.0 || n[2] != -5 || k[7] != 15 {
        return 1;
    }
    return 0;
}
// The free forms are the methods: `simd::f(a, ..)` is `a.f(..)`, generic code over the lanes' unsigned
// type included.

fn ud<T: SimdInt, const N: usize>(a: Simd<T, N>, b: Simd<T, N>) Simd<T::Unsigned, N> {
    return simd::abs_diff(a, b);
}

fn main_3() i32 {
    let a = Simd::<i32, 4>::from_array([5, -3, 7, 0]);
    let b = Simd::<i32, 4>::splat(2);
    let (w, o) = simd::checked_add(a, b);
    let f = Simd::<f32, 4>::from_array([1.5, -2.0, 4.0, 9.0]);
    let g = simd::fma(f, f, f);
    let bits = simd::to_bits(f);
    let back = simd::from_bits::<f32, 4>(bits);
    let d = ud(a, b);
    let m = simd::less_than(a, b);
    let c = simd::clamp(a, Simd::<i32, 4>::splat(-1), b);
    if w[0] != 7 || o.any() || g[0] != 3.75 || back[3] != 9.0 || d[1] != 5 || !m.get(1) || c[0] != 2 || c[1] != -1 {
        return 1;
    }
    if simd::min(a, b)[2] != 2 || simd::abs(a)[1] != 3 || simd::sqrt(f)[3] != 3.0 || simd::count_ones(b)[0] != 1 {
        return 2;
    }
    return 0;
}
// IEEE 754-2019 minimumNumber/maximumNumber and minimum/maximum on every pair of NaN, -0.0, +0.0 and
// 1.0, and an fma whose one rounding differs from a multiply then an add.
const fn bits(v: Simd<f64, 8>) Simd<u64, 8> {
    return v.is_nan().choose(Simd::<u64, 8>::splat(1), v.to_bits());
}
const fn mix(h: u64, v: Simd<u64, 8>) u64 {
    let mut r = h;
    for l in v.to_array() {
        r = r.wrapping_mul(31).wrapping_add(l);
    }
    return r;
}
const fn table() u64 {
    let vals: [f64; 4] = [0.0 / 0.0, -0.0, 0.0, 1.0];
    let mut h: u64 = 0;
    for half in 0..2usize {
        let mut a: [f64; 8] = [0.0; 8];
        let mut b: [f64; 8] = [0.0; 8];
        for i in 0..8usize {
            unsafe {
                a[i] = vals[(half * 8 + i) / 4];
                b[i] = vals[i % 4];
            }
        }
        let x = Simd::<f64, 8>::from_array(a);
        let y = Simd::<f64, 8>::from_array(b);
        h = mix(mix(mix(mix(h, bits(x.min_num(y))), bits(x.max_num(y))), bits(x.minimum(y))), bits(x.maximum(y)));
    }
    return h;
}
const T: u64 = table();
fn main_4() i32 {
    let n: u64 = 1;
    let mz: u64 = 0x8000000000000000;
    let pz: u64 = 0;
    let one: u64 = 0x3FF0000000000000;
    let min_num = [n, mz, pz, one, mz, mz, mz, mz, pz, mz, pz, pz, one, mz, pz, one];
    let max_num = [n, mz, pz, one, mz, mz, pz, one, pz, pz, pz, one, one, one, one, one];
    let minimum = [n, n, n, n, n, mz, mz, mz, n, mz, pz, pz, n, mz, pz, one];
    let maximum = [n, n, n, n, n, mz, pz, one, n, pz, pz, one, n, one, one, one];
    let mut h: u64 = 0;
    for half in 0..2usize {
        for t in [min_num, max_num, minimum, maximum] {
            for i in 0..8usize {
                h = h.wrapping_mul(31).wrapping_add(unsafe t[half * 8 + i]);
            }
        }
    }
    if h != T || h != table() {
        return 1;
    }
    let e: f64 = 1.0 + 0.0000000074505805969238281;
    let v = Simd::<f64, 2>::splat(e);
    let c = Simd::<f64, 2>::splat(-1.0 - 0.000000014901161193847656f64);
    let fused = v.fma(v, c);
    let split = v * v + c;
    if fused[0] != 0.0000000000000000555111512312578270 || split[0] != 0.0 {
        return 2;
    }
    return 0;
}
// A store needs its slice mutably borrowed, a load shared: a live borrow of the other kind conflicts.
// A `[]mut` view written through (a store, a call) conflicts with a live shared borrow of it; as a
// `[]T` it is borrowed shared.
fn main_5() i32 {
    let mut a = [1, 2, 3, 4, 5, 6, 7, 8];
    let y: []mut i32 = a;
    let v = simd::load::<i32, 4>(y, 0);
    simd::store(y, 4, v + simd::load::<i32, 4>(y, 4));
    return a[7] - 12;
}
// The case is the last argument; the case's own arguments come before it.
fn main(args: Vector<str>) i32 {
    let mut a = args;
    let k = a.pop().unwrap().parse_i64().unwrap();
    if k == 0 {
        return main_0(a);
    }
    if k == 1 {
        return main_1(a);
    }
    if k == 2 {
        return main_2();
    }
    if k == 3 {
        return main_3();
    }
    if k == 4 {
        return main_4();
    }
    if k == 5 {
        return main_5();
    }
    return 255;
}
)";

// The programs above, each a case of one build: its last argument selects it.
@test
fn run_cases() {
    h::expect_runs("operations", OPERATIONS, ["0", "1", "2", "3", "4", "5"], ["", "", "", "", "", ""]);
}

@test
fn gathers_and_scatters_match() {
    sweep([121, 122, 126]);
}

// A comparison read by `count`, and by a `choose` of narrower lanes.
@test
fn comparison_reads_match() {
    sweep([124, 125]);
}

// Masks read by several `choose`s, combined by every mask operator and copied; `big & lt` and `both`
// are also read as bits.
const LANE_MASKS: str = M"(import std::simd;
@noinline
fn mix(a: f32x8, b: f32x8) f32x8 {
    let lt = a.less_than(b);
    let big = a.greater_than(f32x8::splat(10.0));
    let both = lt & !big;
    let either = lt | big;
    let odd = both ^ either;
    let same = lt;
    let mut r = simd::choose(both, a, b) + simd::choose(either, b, a) + simd::choose(odd, a * 2.0, b) + simd::choose(
        same,
        a,
        f32x8::splat(1.0),
    );
    if (big & lt).any() {
        r = r * 2.0;
    }
    if both.count() == 3 {
        r = r + 1.0;
    }
    return r;
}
fn main(args: Vector<str>) i32 {
    let k = args.len() as f32;
    let a = f32x8::from_array([k, 12.0, -3.0, 5.0, 20.0, 0.5, 7.0, 11.0]);
    let b = f32x8::from_array([2.0, 15.0, -4.0, 9.0, 1.0, 0.25, 8.0, 30.0]);
    let r = mix(a, b) + mix(b, a);
    for i in 0..8 {
        println("{}", r[i]);
    }
    return 0;
}
)";

@test
fn masks_read_several_times_stay_lane_masks() {
    h::expect_c_absent("no mask converts to lanes", LANE_MASKS, "mask_to_lanes");
    h::expect_same_output("lane masks and the lane loop", LANE_MASKS, ["SC_SIMD_SCALAR=1"], []);
}

// Loops that add `count()` of a comparison to an integer, over lanes of 1, 2, 4 and 8 bytes, one register
// and several, one sum and two (the second taken from its start), a sum as wide as the lanes and wider,
// and the count of two comparisons' masks combined (`count_range`).
// `main` runs each over slices of equal elements (every lane counts in every iteration) of the iterations
// around one and two runs of 255 (65535 for 2-byte lanes), and over mixed elements; it returns the wrong
// counts of equal elements.
// Scalar loops that count flags, which the vectorizer keeps the same way: a flag added as an integer
// (`flag_u8`, `flag_u32`; `flag_narrow` into a 1-byte sum), a step under a condition (`cond_u16`,
// `cond_f64`; `cond_range` under two), two counts, one taken from its sum, beside a sum of the elements
// (`flag_two`), a loop that leaves at an element (`flag_break`), counts beside wider and narrower lanes
// (`flag_beside_u32`, `flag_f32_beside_u8`), a counter down (`flag_down`) and one that steps by 2
// (`flag_step`). `main` runs them around a run of 255 vector iterations of 16 to 128 elements (65535 of 8
// to 64 for 2-byte lanes).
const MASK_COUNTS: str = M"(import std::simd;

@noinline
fn count_u8(x: []u8, v: u8) usize {
    let m = x.len() - x.len() % 64;
    let vv = Simd::<u8, 64>::splat(v);
    let mut c: usize = 0;
    let mut i: usize = 0;
    while i < m {
        c += simd::load::<u8, 64>(x, i).equal(vv).count();
        i += 64;
    }
    return c;
}

@noinline
fn count_u8x16(x: []u8, v: u8) usize {
    let mut c: usize = 0;
    let mut i: usize = 0;
    while i + 16 <= x.len() {
        c += simd::load::<u8, 16>(x, i).equal(Simd::<u8, 16>::splat(v)).count();
        i += 16;
    }
    return c;
}

@noinline
fn count_u16(x: []u16, v: u16) usize {
    let mut c: usize = 0;
    let mut i: usize = 0;
    while i + 32 <= x.len() {
        c += simd::load::<u16, 32>(x, i).less_than(Simd::<u16, 32>::splat(v)).count();
        i += 32;
    }
    return c;
}

@noinline
fn count_u32(x: []u32, v: u32) u32 {
    let mut c: u32 = 7;
    let mut i: usize = 0;
    while i + 16 <= x.len() {
        c += simd::load::<u32, 16>(x, i).equal(Simd::<u32, 16>::splat(v)).count() as u32;
        i += 16;
    }
    return c;
}

@noinline
fn count_u32_wide(x: []u32, v: u32) u64 {
    let mut c: u64 = 0;
    let mut i: usize = 0;
    while i + 16 <= x.len() {
        c += simd::load::<u32, 16>(x, i).not_equal(Simd::<u32, 16>::splat(v)).count() as u64;
        i += 16;
    }
    return c;
}

@noinline
fn count_f64(x: []f64, v: f64) usize {
    let mut c: usize = 0;
    let mut i: usize = 0;
    while i + 8 <= x.len() {
        c += simd::load::<f64, 8>(x, i).less_than(Simd::<f64, 8>::splat(v)).count();
        i += 8;
    }
    return c;
}

@noinline
fn count_two(x: []u8, v: u8, w: u8) u64 {
    let mut c: usize = 0;
    let mut d: usize = 1000000;
    let mut i: usize = 0;
    while i + 32 <= x.len() {
        let a = simd::load::<u8, 32>(x, i);
        c += a.equal(Simd::<u8, 32>::splat(v)).count();
        d -= a.less_than(Simd::<u8, 32>::splat(w)).count();
        i += 32;
    }
    return c as u64 * 2000000 + d as u64;
}

@noinline
fn count_range(x: []u8, lo: u8, hi: u8) usize {
    let mut c: usize = 0;
    let mut i: usize = 0;
    while i + 32 <= x.len() {
        let a = simd::load::<u8, 32>(x, i);
        c += (a.greater_than(Simd::<u8, 32>::splat(lo)) & !a.greater_equal(Simd::<u8, 32>::splat(hi))).count();
        i += 32;
    }
    return c;
}

@noinline
fn flag_u8(x: []u8, v: u8) usize {
    let mut c: usize = 0;
    for i in 0..x.len() {
        c += (x[i] == v) as usize;
    }
    return c;
}

@noinline
fn cond_u16(x: []u16, v: u16) u32 {
    let mut c: u32 = 5;
    for i in 0..x.len() {
        if x[i] < v {
            c += 1;
        }
    }
    return c;
}

@noinline
fn flag_u32(x: []u32, v: u32) u64 {
    let mut c: u64 = 0;
    for i in 0..x.len() {
        c += (x[i] != v) as u64;
    }
    return c;
}

@noinline
fn flag_narrow(x: []u32, v: u32) u8 {
    let mut c: u8 = 0;
    for i in 0..x.len() {
        c = c.wrapping_add((x[i] == v) as u8);
    }
    return c;
}

@noinline
fn cond_f64(x: []f64, v: f64) usize {
    let mut c: usize = 0;
    for i in 0..x.len() {
        if x[i] < v {
            c += 1;
        }
    }
    return c;
}

@noinline
fn flag_two(x: []u8, v: u8, w: u8) u64 {
    let mut c: usize = 0;
    let mut d: usize = 1000000;
    let mut s: u32 = 0;
    for i in 0..x.len() {
        if x[i] == v {
            c += 1;
        }
        d -= (x[i] < w) as usize;
        s += x[i];
    }
    return c as u64 * 1000000000000 + d as u64 * 1000000 + s as u64;
}

@noinline
fn cond_range(x: []u8, lo: u8, hi: u8) usize {
    let mut c: usize = 0;
    for i in 0..x.len() {
        if x[i] > lo && x[i] < hi {
            c += 1;
        }
    }
    return c;
}

@noinline
fn flag_break(x: []u8, v: u8, stop: u8) usize {
    let mut c: usize = 0;
    for i in 0..x.len() {
        if x[i] == stop {
            break;
        }
        c += (x[i] == v) as usize;
    }
    return c;
}

@noinline
fn flag_beside_u32(x: []u8, y: []u32, v: u8) u64 {
    let mut c: usize = 0;
    let mut s: u32 = 0;
    for i in 0..x.len() {
        c += (x[i] == v) as usize;
        s += y[i];
    }
    return c as u64 * 1000000 + (s % 1000000) as u64;
}

@noinline
fn flag_f32_beside_u8(x: []f32, y: []u8, v: f32) u64 {
    let mut c: usize = 0;
    let mut s: u8 = 0;
    for i in 0..x.len() {
        c += (x[i] < v) as usize;
        s = s.wrapping_add(y[i]);
    }
    return c as u64 * 1000 + s as u64;
}

@noinline
fn flag_down(x: []u8, v: u8) usize {
    let mut c: usize = 0;
    let mut i = x.len();
    while i > 0 {
        i -= 1;
        c += (x[i] == v) as usize;
    }
    return c;
}

@noinline
fn flag_step(x: []u8, v: u8) usize {
    let mut c: usize = 0;
    let mut i: usize = 0;
    while i < x.len() {
        c += (x[i] == v) as usize;
        i += 2;
    }
    return c;
}

fn main() i32 {
    let mut bytes = Vector::<u8>::new();
    let mut mixed = Vector::<u8>::new();
    let mut stops = Vector::<u8>::new();
    let mut nums = Vector::<u32>::new();
    for i in 0usize..65700 {
        bytes.push(3);
        mixed.push(((i * 7 + i / 13) % 5) as u8);
        // One element stops `flag_break`.
        stops.push((3 + 6 * (i == 65600) as usize) as u8);
        nums.push((i % 7) as u32);
    }
    let runs: [usize; 8] = [0, 1, 254, 255, 256, 510, 511, 1025];
    let mut bad = 0;
    for p in runs {
        let a = count_u8(bytes[0..p * 64 + 63], 3);
        let b = count_u8x16(bytes[0..p * 16], 3);
        let c = count_two(bytes[0..p * 32], 3, 4);
        let d = count_range(bytes[0..p * 32], 2, 4);
        if a != p * 64 || b != p * 16 || c != p as u64 * 32 * 2000000 + 1000000 - p as u64 * 32 || d != p * 32 {
            bad += 1;
        }
        println("{} {} {} {} {}", p, a, b, c, d);
        println(
            "{} {} {} {}",
            count_u8(mixed[0..p * 64], 3),
            count_u8x16(mixed[5..5 + p * 16 + 9], 2),
            count_two(mixed[1..1 + p * 32], 4, 2),
            count_range(mixed[2..2 + p * 32], 0, 3),
        );
    }
    let mut words = Vector::<u16>::new();
    let mut ints = Vector::<u32>::new();
    let mut floats = Vector::<f64>::new();
    for i in 0usize..65537 * 32 {
        words.push((i % 3) as u16);
    }
    for i in 0usize..4000 {
        ints.push((i % 7) as u32);
        floats.push((i % 11) as f64);
    }
    let long: [usize; 5] = [0, 1, 65535, 65536, 65537];
    for p in long {
        let a = count_u16(words[0..p * 32], 9);
        if a != p * 32 {
            bad += 1;
        }
        println("{} {} {}", p, a, count_u16(words[0..p * 32], 1));
    }
    println("{} {} {}", count_u32(ints[0..4000], 3), count_u32_wide(ints[0..3999], 3), count_f64(floats[0..3996], 4.0));
    println("{} {} {}", count_u32(ints[0..15], 3), count_u32_wide(ints[0..16], 3), count_f64(floats[0..0], 4.0));
    for base in [16usize, 32, 64, 128] {
        for off in [0usize, 1, 2, base + 1, 255 * base + 18, 255 * base + base + 1] {
            let n = 255 * base + off - 1;
            let a = flag_u8(bytes[0..n], 3);
            let b = flag_two(bytes[0..n], 3, 4);
            let c = cond_range(bytes[0..n], 2, 4);
            let d = flag_break(stops[65600 - n..65650], 3, 9);
            let e = flag_beside_u32(bytes[0..n], nums[0..n], 3);
            let f = flag_down(bytes[0..n], 3);
            let g = flag_step(bytes[0..n], 3);
            let two = n as u64 * 1000000000000 + (1000000 - n as u64) * 1000000 + 3 * n as u64;
            if a != n || b != two || c != n || d != n || e / 1000000 != n as u64 || f != n || g != (n + 1) / 2 {
                bad += 1;
            }
            println("{} {} {} {} {} {} {} {}", n, a, b, c, d, e, f, g);
            println(
                "{} {} {} {} {} {} {}",
                flag_u8(mixed[3..3 + n], 3),
                flag_two(mixed[1..1 + n], 4, 2),
                cond_range(mixed[2..2 + n], 0, 3),
                flag_break(mixed[0..n], 2, 7),
                flag_beside_u32(mixed[0..n], nums[5..5 + n], 1),
                flag_down(mixed[7..7 + n], 0),
                flag_step(mixed[0..n], 4),
            );
        }
    }
    for i in 65537usize * 32..65537 * 64 {
        words.push((i % 3) as u16);
    }
    for base in [8usize, 16, 32, 64] {
        for off in [0usize, 1, 2, base + 4] {
            let n = 65535 * base + off - 1;
            let a = cond_u16(words[0..n], 9);
            if a != n as u32 + 5 {
                bad += 1;
            }
            println("{} {} {}", n, a, cond_u16(words[1..1 + n], 1));
        }
    }
    let mut singles = Vector::<f32>::new();
    for i in 0usize..4000 {
        singles.push((i % 2) as f32);
    }
    for n in [0usize, 1, 7, 17, 4000] {
        println(
            "{} {} {} {} {} {} {} {}",
            flag_u8(mixed[0..n], 3),
            cond_u16(words[0..n], 1),
            flag_u32(ints[0..n], 3),
            flag_narrow(ints[0..n], 3),
            flag_narrow(ints[0..n], 9),
            cond_f64(floats[0..n], 4.0),
            flag_f32_beside_u8(singles[0..n], mixed[0..n], 0.5),
            flag_break(stops[65600 - n..65601], 3, 9),
        );
    }
    return bad;
}
)";

// A release build keeps those sums in lane accumulators (`lir::loops` `count_lanes`, and the vectorizer's
// counts of flags); a debug build counts each iteration. Both give the same counts, and the counts of equal
// elements are the elements'. On x86-64 the baseline's code runs too (the run-time copies off), and the
// AVX2 code of the whole program where the processor has it.
@test(timeout = 300)
fn mask_counts_summed_in_loops_match() {
    let d = h::diff_build(MASK_COUNTS, ["--profile=debug"]);
    let r = h::diff_build(MASK_COUNTS, ["--profile=release"]);
    assert(d.built && r.built, "the program builds");
    let m = h::same_runs(&d, &r, [""]);
    if m.len() != 0 {
        eprintln("debug and release: {}", m.as_str());
    }
    assert(m.len() == 0, "a release build counts as a debug build");
    assert(h::diff_run(&r, "").exit == 0, "the count of equal elements is their count");
    // In the vector lane the program is wasm32: no x86-64 copies or levels.
    if ARCH == Arch::X86_64 && !h::simd_lane() {
        let s = h::diff_build(MASK_COUNTS, ["--profile=release", "--simd-dispatch=off"]);
        assert(s.built, "the program builds without run-time copies");
        let n = h::same_runs(&d, &s, [""]);
        if n.len() != 0 {
            eprintln("debug and the baseline: {}", n.as_str());
        }
        assert(n.len() == 0, "the baseline's code counts as a debug build");
        if detect::has_level(cpu::Level::V3) {
            let w = h::diff_build(MASK_COUNTS, ["--profile=release", "--target-cpu=x86-64-v3"]);
            assert(w.built, "the program builds for x86-64-v3");
            let v = h::same_runs(&d, &w, [""]);
            if v.len() != 0 {
                eprintln("debug and x86-64-v3: {}", v.as_str());
            }
            assert(v.len() == 0, "the AVX2 code counts as a debug build");
        }
    }
}

@test
fn operator_misuse_is_diagnosed() {
    let main = "\nfn main() i32 {\n    return 0;\n}\n";
    let cases: [[str; 2]; 10] = [
        ["fn f(a: i32x4, b: f32x4) { let _ = a + b; }", "mismatched types"],
        ["fn f(a: f32x4, b: f64) { let _ = a + b; }", "the right operand is the vector type or its lane type"],
        ["fn f(a: f32x4, b: f64) { let _ = b + a; }", "the left operand is the vector type or its lane type"],
        ["fn f(a: i32x4) { let _ = a << 1u32; }", "the right operand is the vector type or its lane type"],
        ["fn f(a: f32x4) { let _ = a << a; }", "unsatisfied interface bounds"],
        ["fn f(a: f32x4) { let _ = a % a; }", "unsatisfied interface bounds"],
        ["fn f(a: f32x4) { let _ = ~a; }", "unsatisfied interface bounds"],
        [
            "fn f(a: u32x4) { let _ = -a; }",
            "cannot apply unary operator '-' to type 'Simd<u32, 4>' (its lanes have no sign)",
        ],
        ["fn f(a: f32x4) { let _ = a.min(a); }", "unsatisfied interface bounds"],
        [
            "@intrinsic(\"simd.add\")\nfn g(a: f32x4, b: f32x4) f32x4;",
            "'@intrinsic' is reserved for the standard library",
        ],
    ];
    for c in cases {
        let mut src = String::from_str(c[0]);
        src.push_str(main);
        h::expect_err_msg(c[1], &src, c[1]);
    }
    // The reserved attribute is the first error of the check; the build reports the unknown name too.
    h::expect_build_err(
        "an unknown intrinsic",
        "@intrinsic(\"simd.nope\")\nfn g(a: f32x4) f32x4;\nfn main() i32 {\n    return 0;\n}\n",
        "unknown intrinsic 'simd.nope'",
    );
    h::expect_build_err(
        "widen to a narrower type",
        "fn main() i32 {\n    let v = Simd::<i32, 4>::splat(1).widen::<i16>();\n    return v[0] as i32 - 1;\n}\n",
        "widen: U must be a wider lane type of the same kind as T",
    );
    h::expect_build_err(
        "bitcast to another size",
        "fn main() i32 {\n    let v = Simd::<i32, 4>::splat(1).bitcast::<u8, 8>();\n    return v[0] as i32;\n}\n",
        "bitcast: the two vectors must have the same size",
    );
    h::expect_build_err(
        "narrow to a wider type",
        "fn main() i32 {\n    let v = Simd::<i16, 4>::splat(1).narrow::<i32>();\n    return v[0];\n}\n",
        "narrow: U must be a narrower integer type than T",
    );
    h::expect_build_err(
        "low half of two lanes",
        "fn main() i32 {\n    let v = Simd::<i32, 2>::splat(1).low_half();\n    return v[0];\n}\n",
        "low_half: the vector needs at least 4 lanes",
    );
}

// Under --bootstrap-tags a std intrinsic whose name this compiler does not know is accepted, and so is a
// std body that calls it, unchecked (a previous release building a std with newer intrinsics; the newer
// compiler checks the body, and an emission of it fails).
@test
fn unknown_intrinsic_under_bootstrap_tags() {
    let mut src = String::from_str(
        "@intrinsic(\"simd.nope\")\npub const fn nope<T: SimdElement, const N: usize>(a: Simd<T, N>) Simd<T, N>;\n",
    );
    src.push_str("pub fn twice(a: f32x4) f32x4 {\n    return nope(a) + a;\n}\n");
    let r = h::compile_std(&src, -1, h::STAGE_BORROWCK);
    assert(!r.ok() && r.msg_has("unknown intrinsic 'simd.nope'"), "rejected without the flag");
    assert(h::compile_std_bootstrap(&src, h::STAGE_BORROWCK).ok(), "accepted under --bootstrap-tags");
}

// A slice access checks its lanes once: `start <= len && N <= len - start`, overflow-free, and the trap
// names the lanes, the start and the length, as a constant and at run time.
// A target without vector registers (wasm32 without simd128) copies a vector load's lanes one by one,
// spelling no vector type: the range check's helper comes with the check itself.
@test
fn vector_range_check_without_vector_registers() {
    let p = cli::proj_new();
    p.mkfile(
        "main.spc",
        M"(import std::simd;
const fn ld(start: usize) i32 {
    let a = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    let mut b = [0; 10];
    simd::store(b, start, simd::load::<i32, 4>(a, start));
    return unsafe b[start] + unsafe b[start + 3];
}
fn main(args: Vector<str>) i32 {
    return ld(args.len() + 5) - 17;
}
)",
    );
    assert(p.compile_flags("--target=wasm", "main.spc").ok(), "the program transpiles for wasm32");
    let c = cli::read_text(format("{}/build/debug/raw/main.c", p.dir()).as_str());
    assert(c.contains("__sc_bounds_vec("), "the load's range check");
    assert(c.contains("#include \"__sc_t/__sc_lane_check.h\""), "the check's helper is included");
}

@test
fn vector_loads_and_stores_check_their_range() {
    let src = M"(import std::simd;
fn main(args: Vector<str>) i32 {
    let a = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    let mut b = [0; 10];
    let start = args.at(1).parse_u64().unwrap() as usize;
    let v = simd::load::<i32, 4>(a, start);
    simd::store(b, start, v);
    let w = unsafe simd::load_unaligned::<i32, 4>(&a as *const [i32; 10] as *const i32 + start);
    unsafe simd::store_aligned::<i32, 4, 4>(&mut b as *mut [i32; 10] as *mut i32 + start, w + w);
    return unsafe b[start + 3] - 2 * unsafe a[start + 3];
}
)";
    // The largest start of the target: wasm32 in the vector conformance lane.
    let max = if h::simd_lane() {
        "4294967295"
    } else {
        "18446744073709551615"
    };
    let past = format("index out of bounds: 4 lanes from {} but the length is 10", max);
    h::expect_runs(
        "a slice access at its bounds",
        src,
        ["6", "7", "11", max],
        [
            "",
            "index out of bounds: 4 lanes from 7 but the length is 10",
            "index out of bounds: 4 lanes from 11 but the length is 10",
            past.as_str(),
        ],
    );
    let decls = M"(import std::simd;
const fn ld(start: usize) i32 {
    let a = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    let mut b = [0; 10];
    simd::store(b, start, simd::load::<i32, 4>(a, start));
    return unsafe b[start] + unsafe b[start + 3];
}
)";
    let exprs: [str; 4] = [
        "ld(opq::<usize>(6))",
        "ld(opq::<usize>(7))",
        "ld(opq::<usize>(11))",
        "ld(opq::<usize>(usize::MAX))",
    ];
    let tys: [str; 4] = ["i32", "i32", "i32", "i32"];
    let d = h::const_runtime_parity(decls, exprs, tys, []);
    if d.len() != 0 {
        eprintln("{}", d.as_str());
    }
    assert(d.len() == 0, "vector loads and stores as constants");
}

// A store needs its slice mutably borrowed, a load shared: a live borrow of the other kind conflicts.
// A `[]mut` view written through (a store, a call) conflicts with a live shared borrow of it; as a
// `[]T` it is borrowed shared.
@test
fn vector_access_borrows_its_slice() {
    h::expect_err_msg(
        "a store under a shared borrow",
        "import std::simd;\nfn main() i32 {\n    let mut a = [1, 2, 3, 4];\n    let r = &a[0];\n    simd::store(a, 0, Simd::<i32, 4>::splat(0));\n    return *r;\n}\n",
        "borrow",
    );
    h::expect_err_msg(
        "a load under a mutable borrow",
        "import std::simd;\nfn main() i32 {\n    let mut a = [1, 2, 3, 4];\n    let m = &mut a[0];\n    let v = simd::load::<i32, 4>(a, 0);\n    *m = v[1];\n    return a[0];\n}\n",
        "borrow",
    );
    h::expect_err_msg(
        "a store through a `[]mut` view under a shared borrow of it",
        "import std::simd;\nfn main() i32 {\n    let mut a = [1, 2, 3, 4];\n    let s: []mut i32 = a;\n    let r = &s[0];\n    simd::store(s, 0, Simd::<i32, 4>::splat(7));\n    return *r;\n}\n",
        "borrow",
    );
    h::expect_err_msg(
        "a `[]mut` view passed to a call under a shared borrow of it",
        "fn g(s: []mut i32) {\n    s[0] = 7;\n}\nfn main() i32 {\n    let mut a = [1, 2, 3, 4];\n    let s: []mut i32 = a;\n    let r = &s[0];\n    g(s);\n    return *r;\n}\n",
        "borrow",
    );
    h::expect_err_msg(
        "a write through a `[]mut` view while its `[]T` view is live",
        "fn main() i32 {\n    let mut a = [3, 4];\n    let y: []mut i32 = a;\n    let r: []i32 = y;\n    y[0] = 5;\n    return r[0];\n}\n",
        "borrow",
    );
}

// Without backend entries (SC_SIMD_SCALAR=1: the planner calls none, as on x86_64 and on wasm without
// simd128) the C of the vector operations is plain C: no target intrinsic header, no vector extension.
@test
fn vector_c_is_portable() {
    let src = "fn main() i32 {\n    let v = Simd::<f32, 4>::splat(2.0);\n    let w = (v * v).sqrt().min_num(v);\n    return w[0] as i32 - 2;\n}\n";
    h::expect_exit("the program runs", src, 0);
    let _env1 = cli::set_env("SC_SIMD_SCALAR", "1");
    for needle in ["immintrin", "arm_neon", "wasm_simd128", "vector_size", "__m128"] {
        h::expect_c_absent(needle, src, needle);
    }
}
