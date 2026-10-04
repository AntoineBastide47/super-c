// SIMD baselines: each kernel as a plain scalar loop, the reference that defines its result, and as
// hand-written C intrinsics, one C file per instruction set. Every implementation of a kernel gives the
// scalar loop's bits, any NaN counting as one value: `first_mismatch` checks that on every tail length,
// and the benchmark and tests/simd_baseline_test.spc run it. record.sh turns a run into the rows of
// baseline.tsv and probes.tsv.
import std::float as fl;
import std::testing::bench as bench;

const KERNELS: usize = 11;
const NAMES: [str<'static>; KERNELS] = [
    "saxpy_f32",
    "dot_f32_ordered",
    "dot_f32_tree",
    "count_eq_u8",
    "sum_i32",
    "min_max_f32",
    "filter_gt_f32",
    "gather_sum_f32",
    "tail_load_f32",
    "mix_width",
    "abs_diff_u8",
];
const SIZES: [usize; 3] = [4096, 65536, 4194304]; // input bytes of one kernel call
const TREE: usize = 32; // lanes of the fixed reduction tree (sb.h SB_TREE)
const ROW: usize = 13; // tail_load_f32: elements per input row (sb.h SB_ROW)
const STRIDE: usize = 16; // tail_load_f32: output row stride (sb.h SB_STRIDE)
const GUARD: usize = 64; // elements after each output that no kernel may write: one AVX-512 u8 vector

// One implementation of every kernel: sb.h's `sb_kernels`, field for field.
struct Kernels {
    pub name: *const char,
    pub saxpy_f32: fn(f32, *const f32, *mut f32, usize),
    pub dot_f32_ordered: fn(*const f32, *const f32, usize) f32,
    pub dot_f32_tree: fn(*const f32, *const f32, usize) f32,
    pub count_eq_u8: fn(*const u8, usize, u8) usize,
    pub sum_i32: fn(*const i32, usize) i32,
    pub min_max_f32: fn(*const f32, usize, *mut f32),
    pub filter_gt_f32: fn(*const f32, usize, f32, *mut f32) usize,
    pub gather_sum_f32: fn(*const f32, *const u32, usize) f32,
    pub tail_load_f32: fn(f32, *const f32, *mut f32, usize),
    pub mix_width: fn(*const f32, f32, *const u8, *const u8, *mut u8, usize),
    pub abs_diff_u8: fn(*const u8, *const u8, *mut u8, usize),
}

// The inputs of one size and the kernels' outputs. In `mode` 0, `mixed` mixes NaNs (quiet and signaling),
// zeros of both signs and infinities into numbers, and every byte is drawn. In the other modes `mixed`
// holds NaNs, zeros and 0.25 (mode 1); NaNs, then -0.0 in its first half and +0.0 in its second (mode 2,
// so every lane of a maximum sees the zeros in the order that exposes a missed sign), or the reverse
// (mode 3, the same for a minimum); or only NaNs (mode 4); and every `bytes_p` byte is the one count_eq_u8
// counts. `finite_a` and `finite_b` hold numbers, so a reduction over them checks every lane.
struct Input {
    mode: u64,
    floats: usize, // f32 and i32 elements
    finite_a: Vector<f32>,
    finite_b: Vector<f32>,
    mixed: Vector<f32>,
    saxpy_y: Vector<f32>, // saxpy_f32's in-place operand, then GUARD elements
    ints: Vector<i32>,
    indexes: Vector<u32>, // gather_sum_f32's indexes into `finite_a`
    bytes_p: Vector<u8>,
    bytes_q: Vector<u8>,
    out_f32: Vector<f32>, // every f32 output, then GUARD elements
    out_u8: Vector<u8>, // every u8 output, then GUARD elements
}

const SCALAR: Kernels = Kernels {
    name: "scalar".ptr() as *const char,
    saxpy_f32: saxpy_f32,
    dot_f32_ordered: dot_f32_ordered,
    dot_f32_tree: dot_f32_tree,
    count_eq_u8: count_eq_u8,
    sum_i32: sum_i32,
    min_max_f32: min_max_f32,
    filter_gt_f32: filter_gt_f32,
    gather_sum_f32: gather_sum_f32,
    tail_load_f32: tail_load_f32,
    mix_width: mix_width,
    abs_diff_u8: abs_diff_u8,
};

@arch(x86_64)
extern "C" "sse2.h" {
    fn sb_sse2() *const void;
}

@arch(x86_64)
extern "C" "avx2.h" {
    fn sb_avx2() *const void;
}

@arch(x86_64)
extern "C" "avx512.h" {
    fn sb_avx512() *const void;
}

@arch(aarch64)
extern "C" "neon.h" {
    fn sb_neon() *const void;
}

@arch(wasm32)
extern "C" "simd128.h" {
    fn sb_simd128() *const void;
}

/// Every kernel at every size on every instruction set this CPU runs, as `simd` rows of kernel,
/// instruction set, input bytes and median ns per element. A result that differs from the scalar loop's
/// fails the run.
@bench(log_results = false)
pub fn simd_baseline(_b: &mut bench::Bencher) {
    let tables = implementations();
    let bad = first_mismatch();
    if bad.len() != 0 {
        bench::fail(bad.as_str());
        return;
    }
    for bytes in SIZES {
        let mut input = Input::new(bytes, 0);
        let bad_here = input.mismatch(&tables);
        if bad_here.len() != 0 {
            bench::fail(bad_here.as_str());
            return;
        }
        let reps = SIZES[2] / bytes; // every round processes 4 MiB
        for k in 0..KERNELS {
            let elements = reps * input.elements(k);
            for t in 0..tables.len() {
                let table = tables[t];
                let mut b = bench::Bencher::new(names()[k]);
                b.set_diag_rounds(0);
                while b.running() {
                    for _ in 0..reps {
                        bench::black_box(input.call(k, table));
                    }
                }
                let mut s = b.samples().clone();
                let ns = bench::summarize(&mut s).median * 1e9 / elements as f64;
                println("simd\t{}\t{}\t{}\t{}", names()[k], str::from_cstr(table.name), bytes, ns);
            }
        }
    }
}

/// The first kernel whose result differs from the scalar loop's, as "<kernel> on <instruction set> at
/// <bytes> bytes, mode <mode>"; empty when every one agrees. The inputs: 0 to 300 bytes, every tail of
/// every vector width and unroll, and 65600 bytes in each mode, past 255 blocks of every byte counter.
pub fn first_mismatch() String {
    let tables = implementations();
    for bytes in 0usize..301 {
        let m = Input::new(bytes, bytes as u64).mismatch(&tables);
        if m.len() != 0 {
            return m;
        }
    }
    for mode in 0u64..5 {
        let m = Input::new(65600, mode).mismatch(&tables);
        if m.len() != 0 {
            return m;
        }
    }
    return String::new();
}

/// The instruction sets this CPU runs besides the scalar loops.
pub fn isa_count() usize {
    return implementations().len() - 1;
}

// The implementations this CPU runs: the scalar loops, then each table a C file reports as supported.
fn implementations() Vector<&'static Kernels> {
    let mut v = Vector::<&'static Kernels>::new();
    v.push(&SCALAR);
    if ARCH == Arch::X86_64 {
        push_table(&mut v, unsafe sb_sse2());
        push_table(&mut v, unsafe sb_avx2());
        push_table(&mut v, unsafe sb_avx512());
    } else if ARCH == Arch::AArch64 {
        push_table(&mut v, unsafe sb_neon());
    } else if ARCH == Arch::Wasm32 {
        push_table(&mut v, unsafe sb_simd128());
    }
    return v;
}

fn push_table(v: &mut Vector<&'static Kernels>, t: *const void) {
    if t != null {
        v.push(unsafe &*(t as *const Kernels));
    }
}

fn names() []'static str<'static> {
    return NAMES;
}

// The next value of a xorshift64 sequence; `r` is never 0.
fn next(r: &mut u64) u64 {
    *r ^= *r << 13;
    *r ^= *r >> 7;
    *r ^= *r << 17;
    return *r;
}

// A number in [-1, 1) on a 2^-23 grid.
fn unit(r: &mut u64) f32 {
    return (next(r) >> 40) as f32 / 8388608.0 - 1.0;
}

// The bits of `v`, every NaN as one value: the NaN payload of an arithmetic result is not specified.
fn bits(v: f32) u64 {
    if v.is_nan() {
        return 0x7fc00000;
    }
    return fl::f32_bits(v);
}

// One FNV-1a step over a 64-bit value.
fn mix(h: u64, v: u64) u64 {
    return (h ^ v).wrapping_mul(0x100000001b3);
}

// A view of `n` elements at `p`, which stay alive and unwritten while the view is used.
fn view<'a, T>(p: *const T, n: usize) []'a T {
    return Slice::<T> { ptr: p, len: n };
}

// A view of `n` elements at `p`, which nothing else reads or writes while the view is used.
fn view_mut<'a, T>(p: *mut T, n: usize) []'a mut T {
    return SliceMut::<T> { ptr: p, len: n };
}

// The scalar kernels: plain loops over slices behind the C signatures of `Kernels`.

fn saxpy_f32(a: f32, xp: *const f32, yp: *mut f32, n: usize) {
    let x = view(xp, n);
    let y = view_mut(yp, n);
    for i in 0..n {
        y[i] = a * x[i] + y[i];
    }
}

// The products summed left to right from -0.0.
fn dot_f32_ordered(xp: *const f32, yp: *const f32, n: usize) f32 {
    let x = view(xp, n);
    let y = view(yp, n);
    let mut s: f32 = -0.0;
    for i in 0..n {
        s += x[i] * y[i];
    }
    return s;
}

// Product i summed into lane i % TREE, the lanes starting at -0.0, then reduced by `tree`.
fn dot_f32_tree(xp: *const f32, yp: *const f32, n: usize) f32 {
    let x = view(xp, n);
    let y = view(yp, n);
    let mut acc: [f32; TREE] = [-0.0; TREE];
    let l: []mut f32 = acc;
    for i in 0..n {
        l[i % TREE] += x[i] * y[i];
    }
    return tree(l);
}

fn count_eq_u8(xp: *const u8, n: usize, v: u8) usize {
    let mut c: usize = 0;
    for x in view(xp, n) {
        if x == v {
            c += 1;
        }
    }
    return c;
}

fn sum_i32(xp: *const i32, n: usize) i32 {
    let mut s: i32 = 0;
    for x in view(xp, n) {
        s = s.wrapping_add(x);
    }
    return s;
}

// out[0] and out[1]: the IEEE 754-2019 minimumNumber and maximumNumber of the elements (a NaN is skipped,
// -0 < +0), or NaN when no element is a number.
fn min_max_f32(xp: *const f32, n: usize, outp: *mut f32) {
    let mut lo: f32 = 1.0 / 0.0;
    let mut hi: f32 = -1.0 / 0.0;
    for x in view(xp, n) {
        if x < lo || x == lo && x.is_sign_negative() {
            lo = x;
        }
        if x > hi || x == hi && !x.is_sign_negative() {
            hi = x;
        }
    }
    if lo > hi {
        lo = 0.0 / 0.0;
        hi = lo;
    }
    let out = view_mut(outp, 2);
    out[0] = lo;
    out[1] = hi;
}

// The elements above `t`, in order, to the front of `out`; returns their count. `out` holds n elements, and
// an implementation may write any of them past the count.
fn filter_gt_f32(xp: *const f32, n: usize, t: f32, outp: *mut f32) usize {
    let out = view_mut(outp, n);
    let mut k: usize = 0;
    for x in view(xp, n) {
        if x > t {
            out[k] = x;
            k += 1;
        }
    }
    return k;
}

// x[idx[i]] summed as `dot_f32_tree` sums its products; every index is below n.
fn gather_sum_f32(xp: *const f32, ip: *const u32, n: usize) f32 {
    let x = view(xp, n);
    let idx = view(ip, n);
    let mut acc: [f32; TREE] = [-0.0; TREE];
    let l: []mut f32 = acc;
    for i in 0..n {
        l[i % TREE] += x[idx[i] as usize];
    }
    return tree(l);
}

// `rows` rows of ROW elements, packed in x, scaled into rows STRIDE apart in y; y's other elements keep
// their values.
fn tail_load_f32(a: f32, xp: *const f32, yp: *mut f32, rows: usize) {
    let x = view(xp, rows * ROW);
    let y = view_mut(yp, rows * STRIDE);
    for r in 0..rows {
        for j in 0..ROW {
            y[r * STRIDE + j] = a * x[r * ROW + j];
        }
    }
}

fn mix_width(xp: *const f32, t: f32, pp: *const u8, qp: *const u8, outp: *mut u8, n: usize) {
    let x = view(xp, n);
    let p = view(pp, n);
    let q = view(qp, n);
    let out = view_mut(outp, n);
    for i in 0..n {
        out[i] = if x[i] > t {
            p[i];
        } else {
            q[i];
        };
    }
}

fn abs_diff_u8(ap: *const u8, bp: *const u8, outp: *mut u8, n: usize) {
    let a = view(ap, n);
    let b = view(bp, n);
    let out = view_mut(outp, n);
    for i in 0..n {
        out[i] = if a[i] > b[i] {
            a[i] - b[i];
        } else {
            b[i] - a[i];
        };
    }
}

// Halves the lanes until one is left: lane j adds lane j + w for w = TREE / 2, ..., 1.
fn tree(l: []mut f32) f32 {
    let mut w = TREE / 2;
    while w > 0 {
        for j in 0..w {
            l[j] += l[j + w];
        }
        w /= 2;
    }
    return l[0];
}

extend Input {
    fn new(bytes: usize, seed: u64) Input {
        let floats = bytes / 4;
        let mode = seed % 5;
        let mut r = seed | 1;
        let mut v = Input {
            mode: mode,
            floats: floats,
            finite_a: Vector::<f32>::with_capacity(floats),
            finite_b: Vector::<f32>::with_capacity(floats),
            mixed: Vector::<f32>::with_capacity(floats),
            saxpy_y: Vector::<f32>::new(),
            ints: Vector::<i32>::with_capacity(floats),
            indexes: Vector::<u32>::with_capacity(floats),
            bytes_p: Vector::<u8>::with_capacity(bytes),
            bytes_q: Vector::<u8>::with_capacity(bytes),
            out_f32: Vector::<f32>::new(),
            out_u8: Vector::<u8>::new(),
        };
        let specials: []f32 = [
            0.0 / 0.0,
            fl::f32_from_bits(0x7fa00000),
            fl::f32_from_bits(0xffa00000),
            -0.0,
            0.0,
            0.25,
            1.0 / 0.0,
            -1.0 / 0.0,
        ];
        for i in 0..floats {
            v.finite_a.push(unit(&mut r));
            v.finite_b.push(unit(&mut r));
            let k = next(&mut r);
            v.mixed.push(
                if mode == 0 && k % 8 != 0 {
                    unit(&mut r);
                } else if mode == 0 {
                    specials[((k >> 8) % 8) as usize];
                } else if mode == 1 {
                    specials[((k >> 8) % 6) as usize];
                } else if mode == 4 || k % 4 == 0 {
                    specials[((k >> 8) % 3) as usize];
                } else if i < floats / 2 == (mode == 2) {
                    -0.0;
                } else {
                    0.0;
                },
            );
            v.ints.push(next(&mut r) as i32);
            v.indexes.push((next(&mut r) % floats as u64) as u32);
        }
        for _ in 0..bytes {
            v.bytes_p.push(
                if mode == 0 {
                    next(&mut r) as u8;
                } else {
                    3;
                },
            );
            v.bytes_q.push(next(&mut r) as u8);
        }
        v.reset();
        return v;
    }

    // The outputs before a checked call: saxpy_f32's operand, and values no kernel writes elsewhere.
    fn reset(self: &mut Input) {
        self.saxpy_y = self.finite_b.clone();
        self.out_f32.clear();
        self.out_u8.clear();
        for _ in 0..GUARD {
            self.saxpy_y.push(7.0);
        }
        for _ in 0..self.floats.max(self.floats / ROW * STRIDE).max(2) + GUARD {
            self.out_f32.push(7.0);
        }
        for _ in 0..self.bytes_p.len() + GUARD {
            self.out_u8.push(255);
        }
    }

    // Elements one call of kernel `k` reads from its first input.
    fn elements(self: &Input, k: usize) usize {
        return switch k {
            3 | 10 => self.bytes_p.len(),
            8 => self.floats / ROW * ROW,
            _ => self.floats,
        };
    }

    // Runs kernel `k` of `table` once; returns its scalar result as bits, or 0 when it only writes.
    fn call(self: &mut Input, k: usize, table: &Kernels) u64 {
        let n = self.floats;
        let n_bytes = self.bytes_p.len();
        let out = self.out_f32.as_ptr() as *mut f32;
        let out_u8 = self.out_u8.as_ptr() as *mut u8;
        return switch k {
            0 => {
                table.saxpy_f32(1.5, self.mixed.as_ptr(), self.saxpy_y.as_ptr() as *mut f32, n);
                0;
            },
            1 => bits(table.dot_f32_ordered(self.finite_a.as_ptr(), self.finite_b.as_ptr(), n)),
            2 => bits(table.dot_f32_tree(self.finite_a.as_ptr(), self.finite_b.as_ptr(), n)),
            3 => table.count_eq_u8(self.bytes_p.as_ptr(), n_bytes, 3) as u64,
            4 => table.sum_i32(self.ints.as_ptr(), n) as u32,
            5 => {
                table.min_max_f32(self.mixed.as_ptr(), n, out);
                0;
            },
            6 => table.filter_gt_f32(self.mixed.as_ptr(), n, 0.25, out) as u64,
            7 => bits(table.gather_sum_f32(self.finite_a.as_ptr(), self.indexes.as_ptr(), n)),
            8 => {
                table.tail_load_f32(1.5, self.mixed.as_ptr(), out, n / ROW);
                0;
            },
            9 => {
                table.mix_width(self.mixed.as_ptr(), 0.0, self.bytes_p.as_ptr(), self.bytes_q.as_ptr(), out_u8, n);
                0;
            },
            10 => {
                table.abs_diff_u8(self.bytes_p.as_ptr(), self.bytes_q.as_ptr(), out_u8, n_bytes);
                0;
            },
            _ => 0,
        };
    }

    // The first kernel whose result on `tables[t]` differs from `tables[0]`'s, as `first_mismatch` names
    // it; empty when every one agrees.
    fn mismatch(self: &mut Input, tables: &Vector<&'static Kernels>) String {
        for k in 0..KERNELS {
            let want = self.check(k, tables[0]);
            for t in 1..tables.len() {
                if self.check(k, tables[t]) != want {
                    return format(
                        "{} on {} at {} bytes, mode {}",
                        names()[k],
                        str::from_cstr(tables[t].name),
                        self.bytes_p.len(),
                        self.mode,
                    );
                }
            }
        }
        return String::new();
    }

    // Runs kernel `k` of `table` once on reset outputs and hashes its result and every output element:
    // the reset values show any write outside a kernel's range. filter_gt_f32 may write any of its n
    // elements past its count, so those are not hashed.
    fn check(self: &mut Input, k: usize, table: &Kernels) u64 {
        self.reset();
        let r = self.call(k, table);
        let mut h = mix(0xcbf29ce484222325, r);
        for j in 0..self.out_f32.len() {
            if k != 6 || j < r as usize || j >= self.floats {
                h = mix(h, bits(self.out_f32[j]));
            }
        }
        for j in 0..self.saxpy_y.len() {
            h = mix(h, bits(self.saxpy_y[j]));
        }
        for j in 0..self.out_u8.len() {
            h = mix(h, self.out_u8[j]);
        }
        return h;
    }
}
