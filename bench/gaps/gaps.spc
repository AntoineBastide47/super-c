// Code generation gaps against clang -O2: each probe as Super-C compiles it and as clang compiles
// its C form (probes.c, archived by lib.sh into build/gaps/<arch>/libgaps.a: run `sh bench/gaps/lib.sh`
// first), timed on the same inputs in one binary. A row gives the median ns per call of each side, their
// ratio and each side's spread (p95 - min); a probe whose two sides give different results fails the run.
// Inputs come in two modes: `fixed` (one value, predictable branches) and `random` (uniform values).
import stdio;
import std::testing::bench as bench;

const CALLS: usize = 4096; // probe calls per round
const ROUNDS: i32 = 30;

@arch(aarch64)
@link("-Lbuild/gaps/aarch64 -lgaps")
extern "C" {
    fn c_r_sum(n: u32) u32;
    fn c_r_fact(n: u64) u64;
    fn c_r_bits(x: u32) u32;
    fn c_r_pow(b: u64, e: u32) u64;
    fn c_r_fib(n: u32) u32;
    fn c_r_len(n: u32) u32;
    fn c_is_even(i: u32) bool;
    fn c_l_pop(x: u32) u32;
    fn c_l_log2(x: u32) u32;
    fn c_b_bswap(x: u32) u32;
    fn c_c_load32be(b: *const u8) u32;
    fn c_b_lower(c: u8) bool;
    fn c_b_pow2(x: u32) bool;
    fn c_f_and(x: u32, y: u32, z: u32) bool;
    fn c_f_or0(x: u32, y: u32) bool;
    fn c_r_even(n: u32) bool;
    fn c_s_max(a: i32, b: i32) i32;
    fn c_s_clamp(x: i32, lo: i32, hi: i32) i32;
    fn c_s_cmp3(a: i32, b: i32) i32;
    fn c_s_abs(x: i32) i32;
    fn c_s_cinc(a: u32, b: u32, c: u32) u32;
    fn c_s_divmod(a: u32, b: u32) u32;
    fn c_s_srem2(x: i32) bool;
    fn c_s_ctz(x: u32) u32;
    fn c_s_clz16(x: u16) u32;
    fn c_s_shm(x: u32, n: u32) u32;
    fn c_t_call(x: u32, a: u32) u32;
    fn c_o_ref(p: *const u32) u32;
    fn c_s_mulhi(a: u32, b: u32) u32;
    fn c_s_ispow2m(x: u64, a: u64) u64;
    fn c_p_min(a: f64, b: f64) f64;
    fn c_p_abs(x: f64) f64;
    fn c_p_clamp01(x: f32) f32;
    fn c_b_table(x: u32) u32;
    fn c_t_sparse(x: u32) u32;
    fn c_t_jump(x: u32, a: u32) u32;
    fn c_f_space(c: u8) bool;
    fn c_f_class(c: u8) u8;
    fn c_b_bfi(x: u32, v: u32) u32;
    fn c_b_andn(x: u64, y: u64) u64;
    fn c_b_sbfx(x: u32) i32;
}

@arch(x86_64)
@link("-Lbuild/gaps/x86_64 -lgaps")
extern "C" {
    fn c_r_sum(n: u32) u32;
    fn c_r_fact(n: u64) u64;
    fn c_r_bits(x: u32) u32;
    fn c_r_pow(b: u64, e: u32) u64;
    fn c_r_fib(n: u32) u32;
    fn c_r_len(n: u32) u32;
    fn c_is_even(i: u32) bool;
    fn c_l_pop(x: u32) u32;
    fn c_l_log2(x: u32) u32;
    fn c_b_bswap(x: u32) u32;
    fn c_c_load32be(b: *const u8) u32;
    fn c_b_lower(c: u8) bool;
    fn c_b_pow2(x: u32) bool;
    fn c_f_and(x: u32, y: u32, z: u32) bool;
    fn c_f_or0(x: u32, y: u32) bool;
    fn c_r_even(n: u32) bool;
    fn c_s_max(a: i32, b: i32) i32;
    fn c_s_clamp(x: i32, lo: i32, hi: i32) i32;
    fn c_s_cmp3(a: i32, b: i32) i32;
    fn c_s_abs(x: i32) i32;
    fn c_s_cinc(a: u32, b: u32, c: u32) u32;
    fn c_s_divmod(a: u32, b: u32) u32;
    fn c_s_srem2(x: i32) bool;
    fn c_s_ctz(x: u32) u32;
    fn c_s_clz16(x: u16) u32;
    fn c_s_shm(x: u32, n: u32) u32;
    fn c_t_call(x: u32, a: u32) u32;
    fn c_o_ref(p: *const u32) u32;
    fn c_s_mulhi(a: u32, b: u32) u32;
    fn c_s_ispow2m(x: u64, a: u64) u64;
    fn c_p_min(a: f64, b: f64) f64;
    fn c_p_abs(x: f64) f64;
    fn c_p_clamp01(x: f32) f32;
    fn c_b_table(x: u32) u32;
    fn c_t_sparse(x: u32) u32;
    fn c_t_jump(x: u32, a: u32) u32;
    fn c_f_space(c: u8) bool;
    fn c_f_class(c: u8) u8;
    fn c_b_bfi(x: u32, v: u32) u32;
    fn c_b_andn(x: u64, y: u64) u64;
    fn c_b_sbfx(x: u32) i32;
}

// Recursion whose result an associative operation combines with the recursive call.
@noinline
fn r_sum(n: u32) u32 {
    if n == 0 {
        return 0;
    }
    return n + r_sum(n - 1);
}

@noinline
fn r_fact(n: u64) u64 {
    if n == 0 {
        return 1;
    }
    return n * r_fact(n - 1);
}

@noinline
fn r_bits(x: u32) u32 {
    if x == 0 {
        return 0;
    }
    return (x & 1) + r_bits(x >> 1);
}

@noinline
fn r_pow(b: u64, e: u32) u64 {
    if e == 0 {
        return 1;
    }
    return b * r_pow(b, e - 1);
}

@noinline
fn r_fib(n: u32) u32 {
    if n < 2 {
        return n;
    }
    return r_fib(n - 1) + r_fib(n - 2);
}

@noinline
fn r_len(n: u32) u32 {
    if n == 0 {
        return 0;
    }
    return 1 + r_len(n - 1);
}

@noinline
fn is_even(i: u32) bool {
    if i == 0 {
        return true;
    }
    return !is_even(i - 1);
}

// Bit counts as loops.
@noinline
fn l_pop(x0: u32) u32 {
    let mut x = x0;
    let mut c: u32 = 0;
    while x != 0 {
        x &= x - 1;
        c += 1;
    }
    return c;
}

@noinline
fn l_log2(x0: u32) u32 {
    let mut x = x0;
    let mut c: u32 = 0;
    while x != 0 {
        x >>= 1;
        c += 1;
    }
    return c;
}

// Byte swaps.
@noinline
fn b_bswap(x: u32) u32 {
    return x >> 24 | x >> 8 & 0xff00 | x << 8 & 0xff0000 | x << 24;
}

@noinline
fn c_load32be(b: &[u8; 4]) u32 {
    return b[0] as u32 << 24 | b[1] as u32 << 16 | b[2] as u32 << 8 | b[3] as u32;
}

// `&&` and `||` of comparisons.
@noinline
fn b_lower(c: u8) bool {
    return c >= 97 && c <= 122;
}

@noinline
fn b_pow2(x: u32) bool {
    return x != 0 && (x & x - 1) == 0;
}

@noinline
fn f_and(x: u32, y: u32, z: u32) bool {
    return x == 3 && y < 9 && z != 0;
}

@noinline
fn f_or0(x: u32, y: u32) bool {
    return x == 0 || y == 0;
}

// Switches, ranges and sets of constants.
@noinline
fn b_table(x: u32) u32 {
    return switch x {
        0 => 10,
        1 => 33,
        2 => 7,
        3 => 99,
        4 => 5,
        _ => 0,
    };
}

@noinline
fn t_sparse(x: u32) u32 {
    return switch x {
        1 => 3,
        10 => 9,
        100 => 4,
        1000 => 8,
        5000 => 1,
        9000 => 7,
        20000 => 2,
        77777 => 6,
        _ => 0,
    };
}

@noinline
fn t_jump(x: u32, a: u32) u32 {
    return switch x {
        0 => a + 1,
        1 => a * 3,
        2 => a ^ 7,
        3 => a << 2,
        4 => a - 9,
        5 => a / 3,
        6 => a | 64,
        7 => a & 5,
        _ => 0,
    };
}

@noinline
fn f_space(c: u8) bool {
    return c == 32 || c == 9 || c == 10 || c == 13;
}

@noinline
fn f_class(c: u8) u8 {
    return switch c {
        97..=122 => 1,
        65..=90 => 1,
        48..=57 => 2,
        32 | 9 | 10 => 3,
        _ => 0,
    };
}

// Bit fields and inverted operands.
@noinline
fn b_bfi(x: u32, v: u32) u32 {
    return x & 0xffff00ff | (v & 0xff) << 8;
}

@noinline
fn b_andn(x: u64, y: u64) u64 {
    return ~x & y;
}

@noinline
fn b_sbfx(x: u32) i32 {
    return (x << 20) as i32 >> 24;
}

// Callee-saved registers around sibling calls.
@noinline
fn r_even(n: u32) bool {
    if n == 0 {
        return true;
    }
    return r_odd(n - 1);
}

@noinline
fn r_odd(n: u32) bool {
    if n == 0 {
        return false;
    }
    return r_even(n - 1);
}

// Return diamonds.
@noinline
fn s_max(a: i32, b: i32) i32 {
    if a > b {
        return a;
    }
    return b;
}

@noinline
fn s_clamp(x: i32, lo: i32, hi: i32) i32 {
    if x < lo {
        return lo;
    }
    if x > hi {
        return hi;
    }
    return x;
}

@noinline
fn s_cmp3(a: i32, b: i32) i32 {
    if a < b {
        return -1;
    }
    if a > b {
        return 1;
    }
    return 0;
}

// Arithmetic idioms.
@noinline
fn s_abs(x: i32) i32 {
    return if x < 0 {
        -x
    } else {
        x
    };
}

@noinline
fn s_cinc(a: u32, b: u32, c: u32) u32 {
    return if a > b {
        c + 1
    } else {
        c
    };
}

@noinline
fn s_divmod(a: u32, b: u32) u32 {
    return a / b + a % b;
}

@noinline
fn s_srem2(x: i32) bool {
    return x % 2 == 1;
}

@noinline
fn s_ctz(x: u32) u32 {
    return x.trailing_zeros() as u32;
}

@noinline
fn s_clz16(x: u16) u32 {
    return x.leading_zeros() as u32;
}

@noinline
fn s_mulhi(a: u32, b: u32) u32 {
    return (a as u64 * b as u64 >> 32) as u32;
}

@noinline
fn s_ispow2m(x: u64, a: u64) u64 {
    return x % 64 + a / 8;
}

@noinline
fn s_shm(x: u32, n: u32) u32 {
    return x << (n & 31);
}

// Arms that return a call.
@noinline
fn t_f0(a: u32) u32 {
    return a * 3 + 1;
}

@noinline
fn t_f1(a: u32) u32 {
    return a ^ 0x55;
}

@noinline
fn t_f2(a: u32) u32 {
    return a << 2;
}

@noinline
fn t_call(x: u32, a: u32) u32 {
    return switch x {
        0 => t_f0(a),
        1 => t_f1(a),
        2 => t_f2(a),
        _ => a,
    };
}

@noinline
fn o_ref(p: Option<&u32>) u32 {
    return switch p {
        Some(r) => *r,
        None => 0,
    };
}

// Float return diamonds.
@noinline
fn p_min(a: f64, b: f64) f64 {
    if a < b {
        return a;
    }
    return b;
}

@noinline
fn p_abs(x: f64) f64 {
    if x < 0.0 {
        return -x;
    }
    return x;
}

@noinline
fn p_clamp01(x: f32) f32 {
    if x < 0.0 {
        return 0.0;
    }
    if x > 1.0 {
        return 1.0;
    }
    return x;
}

// `CALLS` inputs below `max`: all `max - 1` (`fixed`), or uniform (`random`, a fixed seed).
fn inputs(max: u32, random: bool) Vector<u32> {
    let mut v = Vector::<u32>::with_capacity(CALLS);
    let mut s: u64 = 0x9E3779B97F4A7C15;
    for _ in 0..CALLS {
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        v.push(
            if random {
                (s % max as u64) as u32
            } else {
                max - 1
            },
        );
    }
    return v;
}

// The median and spread (p95 - min) of one call of `f` over `xs`, in ns, and the sum of its results.
struct Stat {
    median: f64,
    spread: f64,
    sum: u64,
}

fn time<F: fn(u32) u64>(xs: &Vector<u32>, f: F) Stat {
    let mut b = bench::Bencher::new("gap probe");
    b.set_diag_rounds(0);
    b.set_rounds(ROUNDS);
    let mut sum: u64 = 0;
    while b.running() {
        sum = 0;
        for i in 0..xs.len() {
            sum += f(xs[i]);
        }
        bench::black_box(sum);
    }
    let mut s = b.samples().clone();
    let sm = bench::summarize(&mut s);
    let n = xs.len() as f64;
    return Stat { median: sm.median * 1e9 / n, spread: (sm.p95 - sm.min) * 1e9 / n, sum: sum };
}

// About 200 ms of work, so the clock is up before the first row.
fn warm() {
    bench::black_box(bench::burn((0.2e9 / bench::burn_ns_per_iter()) as i64));
}

// `time` with each call's input depending on the previous result (`x ^ (r & 1)`): the probe's latency.
fn chain<F: fn(u32) u64>(xs: &Vector<u32>, f: F) Stat {
    let mut b = bench::Bencher::new("gap probe");
    b.set_diag_rounds(0);
    b.set_rounds(ROUNDS);
    let mut sum: u64 = 0;
    while b.running() {
        sum = 0;
        let mut r: u64 = 0;
        for i in 0..xs.len() {
            r = f(xs[i] ^ (r & 1) as u32);
            sum += r;
        }
        bench::black_box(sum);
    }
    let mut s = b.samples().clone();
    let sm = bench::summarize(&mut s);
    let n = xs.len() as f64;
    return Stat { median: sm.median * 1e9 / n, spread: (sm.p95 - sm.min) * 1e9 / n, sum: sum };
}

// One row: probe `name` on `xs` (`mode`), Super-C's `sc` against clang's `c`.
// `time` of `f` over `xs`, or its `chain` when `latency`.
fn measure<F: fn(u32) u64>(xs: &Vector<u32>, latency: bool, f: F) Stat {
    return if latency {
        chain(xs, f)
    } else {
        time(xs, f)
    };
}

fn row(name: str, mode: str, sc: Stat, c: Stat) {
    unsafe stdio::printf(
        "gaps %-10.*s %-6.*s  sc %9.2f ns (+%.2f)  c %9.2f ns (+%.2f)  sc/c %.3f\n".ptr() as *const char,
        name.len() as i32,
        name.ptr(),
        mode.len() as i32,
        mode.ptr(),
        sc.median,
        sc.spread,
        c.median,
        c.spread,
        sc.median / c.median,
    );
    if sc.sum != c.sum {
        bench::fail(format("gaps {} {}: Super-C sums {}, clang {}", name, mode, sc.sum, c.sum).as_str());
    }
}

/// Accumulator recursion: the recursion probes, each on depths below 64 (`r_fib`: below 20).
@bench(log_results = false)
pub fn gaps_recursion(_b: &mut bench::Bencher) {
    warm();
    for m in 0..2 {
        let random = m == 1;
        let mode = if random {
            "random"
        } else {
            "fixed"
        };
        let xs = inputs(64, random);
        row("r_sum", mode, time(&xs, |x: u32| r_sum(x) as u64), time(&xs, |x: u32| (unsafe c_r_sum(x)) as u64));
        row("r_fact", mode, time(&xs, |x: u32| r_fact(x)), time(&xs, |x: u32| unsafe c_r_fact(x)));
        row(
            "r_bits",
            mode,
            time(&xs, |x: u32| r_bits(x * 0x9E3779B9) as u64),
            time(&xs, |x: u32| (unsafe c_r_bits(x * 0x9E3779B9)) as u64),
        );
        row("r_pow", mode, time(&xs, |x: u32| r_pow(3, x)), time(&xs, |x: u32| unsafe c_r_pow(3, x)));
        row("r_len", mode, time(&xs, |x: u32| r_len(x) as u64), time(&xs, |x: u32| (unsafe c_r_len(x)) as u64));
        row("is_even", mode, time(&xs, |x: u32| is_even(x) as u64), time(&xs, |x: u32| (unsafe c_is_even(x)) as u64));
        let fs = inputs(20, random);
        row("r_fib", mode, time(&fs, |x: u32| r_fib(x) as u64), time(&fs, |x: u32| (unsafe c_r_fib(x)) as u64));
    }
}

/// Bit-count loops: `l_pop` and `l_log2` on random words, and on one word of 16 set bits.
@bench(log_results = false)
pub fn gaps_bits(_b: &mut bench::Bencher) {
    warm();
    for m in 0..2 {
        let random = m == 1;
        let mode = if random {
            "random"
        } else {
            "fixed"
        };
        let mut xs = inputs(0xFFFFFFFF, random);
        for i in 0..xs.len() {
            xs[i] = if random {
                xs[i] * 0x9E3779B9
            } else {
                0x5A5A5A5A
            };
        }
        row("l_pop", mode, time(&xs, |x: u32| l_pop(x) as u64), time(&xs, |x: u32| (unsafe c_l_pop(x)) as u64));
        row("l_log2", mode, time(&xs, |x: u32| l_log2(x) as u64), time(&xs, |x: u32| (unsafe c_l_log2(x)) as u64));
    }
}

/// Byte swaps: `b_bswap` on words, `c_load32be` on the 4 bytes of each word.
@bench(log_results = false)
pub fn gaps_bswap(_b: &mut bench::Bencher) {
    warm();
    for m in 0..2 {
        let random = m == 1;
        let mode = if random {
            "random"
        } else {
            "fixed"
        };
        let xs = inputs(0xFFFFFFFF, random);
        let mut by = Vector::<[u8; 4]>::with_capacity(xs.len());
        for i in 0..xs.len() {
            by.push(xs[i].to_le_bytes());
        }
        let ix = inputs(CALLS as u32, random);
        row("b_bswap", mode, time(&xs, |x: u32| b_bswap(x) as u64), time(&xs, |x: u32| (unsafe c_b_bswap(x)) as u64));
        row(
            "b_bswap",
            "chain",
            chain(&xs, |x: u32| b_bswap(x) as u64),
            chain(&xs, |x: u32| (unsafe c_b_bswap(x)) as u64),
        );
        row(
            "c_load32be",
            mode,
            time(&ix, |k: u32| c_load32be(&by[k as usize]) as u64),
            time(&ix, |k: u32| (unsafe c_c_load32be(((&by[k as usize]) as *const [u8; 4]) as *const u8)) as u64),
        );
    }
}

/// `&&`, `||` of comparisons: each probe on bytes or words (`fixed`: all true; `random`), and as a
/// latency chain.
@bench(log_results = false)
pub fn gaps_flags(_b: &mut bench::Bencher) {
    warm();
    for m in 0..2 {
        let random = m == 1;
        let mode = if random {
            "random"
        } else {
            "fixed"
        };
        let mut xs = inputs(0xFFFFFFFF, random);
        if !random {
            for i in 0..xs.len() {
                xs[i] = 0x08000863;
            }
        }
        row(
            "b_lower",
            mode,
            time(&xs, |x: u32| b_lower(x as u8) as u64),
            time(&xs, |x: u32| (unsafe c_b_lower(x as u8)) as u64),
        );
        row(
            "b_pow2",
            mode,
            time(&xs, |x: u32| b_pow2(x >> 24) as u64),
            time(&xs, |x: u32| (unsafe c_b_pow2(x >> 24)) as u64),
        );
        row(
            "f_and",
            mode,
            time(&xs, |x: u32| f_and(x & 3, x >> 8 & 15, x >> 16 & 1) as u64),
            time(&xs, |x: u32| (unsafe c_f_and(x & 3, x >> 8 & 15, x >> 16 & 1)) as u64),
        );
        row(
            "f_or0",
            mode,
            time(&xs, |x: u32| f_or0(x & 1, x >> 8 & 1) as u64),
            time(&xs, |x: u32| (unsafe c_f_or0(x & 1, x >> 8 & 1)) as u64),
        );
    }
    let xs = inputs(0xFFFFFFFF, true);
    row(
        "b_lower",
        "chain",
        chain(&xs, |x: u32| b_lower(x as u8) as u64),
        chain(&xs, |x: u32| (unsafe c_b_lower(x as u8)) as u64),
    );
    row(
        "f_and",
        "chain",
        chain(&xs, |x: u32| f_and(x & 3, x >> 8 & 15, x >> 16 & 1) as u64),
        chain(&xs, |x: u32| (unsafe c_f_and(x & 3, x >> 8 & 15, x >> 16 & 1)) as u64),
    );
}

/// Callee-saved registers in a body whose only call is a sibling one: `r_even` on depths below 64.
@bench(log_results = false)
pub fn gaps_sibling(_b: &mut bench::Bencher) {
    warm();
    for m in 0..2 {
        let random = m == 1;
        let mode = if random {
            "random"
        } else {
            "fixed"
        };
        let xs = inputs(64, random);
        row("r_even", mode, time(&xs, |x: u32| r_even(x) as u64), time(&xs, |x: u32| (unsafe c_r_even(x)) as u64));
    }
}

/// Return diamonds: `s_max`, `s_clamp`, `s_cmp3` on words (`fixed`: one value, predictable;
/// `random`: unpredictable), and as latency chains.
@bench(log_results = false)
pub fn gaps_select(_b: &mut bench::Bencher) {
    warm();
    for m in 0..3 {
        let random = m != 0;
        let mode = if m == 0 {
            "fixed"
        } else if m == 1 {
            "random"
        } else {
            "chain"
        };
        let xs = inputs(0xFFFFFFFF, random);
        if m < 2 {
            row(
                "s_max",
                mode,
                time(&xs, |x: u32| s_max(x as i32, (x << 7) as i32) as u64),
                time(&xs, |x: u32| (unsafe c_s_max(x as i32, (x << 7) as i32)) as u64),
            );
            row(
                "s_clamp",
                mode,
                time(&xs, |x: u32| s_clamp(x as i32, -1000000, 1000000) as u64),
                time(&xs, |x: u32| (unsafe c_s_clamp(x as i32, -1000000, 1000000)) as u64),
            );
            row(
                "s_cmp3",
                mode,
                time(&xs, |x: u32| s_cmp3(x as i32, (x << 7) as i32) as u64),
                time(&xs, |x: u32| (unsafe c_s_cmp3(x as i32, (x << 7) as i32)) as u64),
            );
        } else {
            row(
                "s_max",
                mode,
                chain(&xs, |x: u32| s_max(x as i32, (x << 7) as i32) as u64),
                chain(&xs, |x: u32| (unsafe c_s_max(x as i32, (x << 7) as i32)) as u64),
            );
            row(
                "s_clamp",
                mode,
                chain(&xs, |x: u32| s_clamp(x as i32, -1000000, 1000000) as u64),
                chain(&xs, |x: u32| (unsafe c_s_clamp(x as i32, -1000000, 1000000)) as u64),
            );
            row(
                "s_cmp3",
                mode,
                chain(&xs, |x: u32| s_cmp3(x as i32, (x << 7) as i32) as u64),
                chain(&xs, |x: u32| (unsafe c_s_cmp3(x as i32, (x << 7) as i32)) as u64),
            );
        }
    }
}

/// Arithmetic idioms: conditional negation and increment, quotient and remainder, a signed
/// remainder test, 32- and 16-bit bit counts, a masked shift, a widening product's high half, a shifted
/// operand; on unpredictable words and as latency chains.
@bench(log_results = false)
pub fn gaps_arith(_b: &mut bench::Bencher) {
    warm();
    let xs = inputs(0xFFFFFFFF, true);
    for m in 0..2 {
        let mode = if m == 0 {
            "random"
        } else {
            "chain"
        };
        row(
            "s_abs",
            mode,
            measure(&xs, m == 1, |x: u32| s_abs(x as i32) as u64),
            measure(&xs, m == 1, |x: u32| (unsafe c_s_abs(x as i32)) as u64),
        );
        row(
            "s_cinc",
            mode,
            measure(&xs, m == 1, |x: u32| s_cinc(x, x << 3, x) as u64),
            measure(&xs, m == 1, |x: u32| (unsafe c_s_cinc(x, x << 3, x)) as u64),
        );
        row(
            "s_divmod",
            mode,
            measure(&xs, m == 1, |x: u32| s_divmod(x, x >> 20 | 1) as u64),
            measure(&xs, m == 1, |x: u32| (unsafe c_s_divmod(x, x >> 20 | 1)) as u64),
        );
        row(
            "s_srem2",
            mode,
            measure(&xs, m == 1, |x: u32| s_srem2(x as i32) as u64),
            measure(&xs, m == 1, |x: u32| (unsafe c_s_srem2(x as i32)) as u64),
        );
        row(
            "s_ctz",
            mode,
            measure(&xs, m == 1, |x: u32| s_ctz(x >> (x & 31)) as u64),
            measure(&xs, m == 1, |x: u32| (unsafe c_s_ctz(x >> (x & 31))) as u64),
        );
        row(
            "s_clz16",
            mode,
            measure(&xs, m == 1, |x: u32| s_clz16(x as u16) as u64),
            measure(&xs, m == 1, |x: u32| (unsafe c_s_clz16(x as u16)) as u64),
        );
        row(
            "s_shm",
            mode,
            measure(&xs, m == 1, |x: u32| s_shm(x, x >> 7) as u64),
            measure(&xs, m == 1, |x: u32| (unsafe c_s_shm(x, x >> 7)) as u64),
        );
        row(
            "s_mulhi",
            mode,
            measure(&xs, m == 1, |x: u32| s_mulhi(x, x ^ 0x9E3779B9) as u64),
            measure(&xs, m == 1, |x: u32| (unsafe c_s_mulhi(x, x ^ 0x9E3779B9)) as u64),
        );
        row(
            "s_ispow2m",
            mode,
            measure(&xs, m == 1, |x: u32| s_ispow2m(x, x as u64 << 9)),
            measure(&xs, m == 1, |x: u32| unsafe c_s_ispow2m(x, x as u64 << 9)),
        );
    }
}

/// Arms that return a call or a load: `t_call` on 4 arms (`fixed`: one arm; `random`: any), and
/// `o_ref` on present and absent references.
@bench(log_results = false)
pub fn gaps_tail(_b: &mut bench::Bencher) {
    warm();
    let v: u32 = 7;
    for m in 0..2 {
        let random = m == 1;
        let mode = if random {
            "random"
        } else {
            "fixed"
        };
        let xs = inputs(0xFFFFFFFF, random);
        row(
            "t_call",
            mode,
            time(&xs, |x: u32| t_call(x & 3, x) as u64),
            time(&xs, |x: u32| (unsafe c_t_call(x & 3, x)) as u64),
        );
        row(
            "o_ref",
            mode,
            time(
                &xs,
                |x: u32| o_ref(
                    if (x & 1) != 0 {
                        Some(&v)
                    } else {
                        None
                    },
                ) as u64,
            ),
            time(
                &xs,
                |x: u32| (unsafe c_o_ref(
                    if (x & 1) != 0 {
                        &v
                    } else {
                        0 as *const u32
                    },
                )) as u64,
            ),
        );
    }
}

/// Float return diamonds: `p_min`, `p_abs`, `p_clamp01` on signed values from the words, on
/// unpredictable inputs and as latency chains (the result's bits feed the next input).
@bench(log_results = false)
pub fn gaps_float(_b: &mut bench::Bencher) {
    warm();
    let xs = inputs(0xFFFFFFFF, true);
    for m in 0..2 {
        let mode = if m == 0 {
            "random"
        } else {
            "chain"
        };
        row(
            "p_min",
            mode,
            measure(&xs, m == 1, |x: u32| p_min((x as i32) as f64, ((x << 7) as i32) as f64).to_bits()),
            measure(&xs, m == 1, |x: u32| (unsafe c_p_min((x as i32) as f64, ((x << 7) as i32) as f64)).to_bits()),
        );
        row(
            "p_abs",
            mode,
            measure(&xs, m == 1, |x: u32| p_abs((x as i32) as f64).to_bits()),
            measure(&xs, m == 1, |x: u32| (unsafe c_p_abs((x as i32) as f64)).to_bits()),
        );
        row(
            "p_clamp01",
            mode,
            measure(&xs, m == 1, |x: u32| p_clamp01((x as i32) as f32 * 1.0e-9).to_bits() as u64),
            measure(&xs, m == 1, |x: u32| (unsafe c_p_clamp01((x as i32) as f32 * 1.0e-9)).to_bits() as u64),
        );
    }
}

/// Switches, ranges, sets and bit fields: each kernel on unpredictable inputs (the
/// switches' values mostly among their cases) and as a latency chain.
@bench(log_results = false)
pub fn gaps_switch(_b: &mut bench::Bencher) {
    warm();
    let xs = inputs(0xFFFFFFFF, true);
    let sparse: [u32; 9] = [1, 10, 100, 1000, 5000, 9000, 20000, 77777, 3];
    for m in 0..2 {
        let mode = if m == 0 {
            "random"
        } else {
            "chain"
        };
        let l = m == 1;
        row(
            "b_table",
            mode,
            measure(&xs, l, |x: u32| b_table(x % 6) as u64),
            measure(&xs, l, |x: u32| (unsafe c_b_table(x % 6)) as u64),
        );
        row(
            "t_sparse",
            mode,
            measure(&xs, l, |x: u32| t_sparse(sparse[(x % 9) as usize]) as u64),
            measure(&xs, l, |x: u32| (unsafe c_t_sparse(sparse[(x % 9) as usize])) as u64),
        );
        row(
            "t_jump",
            mode,
            measure(&xs, l, |x: u32| t_jump(x % 9, x) as u64),
            measure(&xs, l, |x: u32| (unsafe c_t_jump(x % 9, x)) as u64),
        );
        row(
            "f_space",
            mode,
            measure(&xs, l, |x: u32| f_space((x % 40) as u8) as u64),
            measure(&xs, l, |x: u32| (unsafe c_f_space((x % 40) as u8)) as u64),
        );
        row(
            "f_class",
            mode,
            measure(&xs, l, |x: u32| f_class(x as u8 & 0x7f) as u64),
            measure(&xs, l, |x: u32| (unsafe c_f_class(x as u8 & 0x7f)) as u64),
        );
        row(
            "b_bfi",
            mode,
            measure(&xs, l, |x: u32| b_bfi(x, x >> 5) as u64),
            measure(&xs, l, |x: u32| (unsafe c_b_bfi(x, x >> 5)) as u64),
        );
        row(
            "b_andn",
            mode,
            measure(&xs, l, |x: u32| b_andn(x, x as u64 * 0x9E3779B9)),
            measure(&xs, l, |x: u32| unsafe c_b_andn(x, x as u64 * 0x9E3779B9)),
        );
        row(
            "b_sbfx",
            mode,
            measure(&xs, l, |x: u32| b_sbfx(x) as u64),
            measure(&xs, l, |x: u32| (unsafe c_b_sbfx(x)) as u64),
        );
    }
}
