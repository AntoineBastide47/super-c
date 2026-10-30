// Code generation gaps against clang -O2 (GAPS.md): each probe as Super-C compiles it and as clang compiles
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
}

// Gap 1: recursion whose result an associative operation combines with the recursive call.
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

// Gap 3: bit counts as loops.
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

// Gap 4 and 32: byte swaps.
@noinline
fn b_bswap(x: u32) u32 {
    return x >> 24 | x >> 8 & 0xff00 | x << 8 & 0xff0000 | x << 24;
}

@noinline
fn c_load32be(b: &[u8; 4]) u32 {
    return b[0] as u32 << 24 | b[1] as u32 << 16 | b[2] as u32 << 8 | b[3] as u32;
}

// Gap 5: `&&` and `||` of comparisons.
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

// Gap 8: callee-saved registers around sibling calls.
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

// Gap 14: return diamonds.
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

// Gaps 15 to 20: arithmetic idioms.
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
fn s_shm(x: u32, n: u32) u32 {
    return x << (n & 31);
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

/// Gap 1 (accumulator recursion): the recursion probes, each on depths below 64 (`r_fib`: below 20).
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

/// Gap 3 (bit-count loops): `l_pop` and `l_log2` on random words, and on one word of 16 set bits.
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

/// Gaps 4 and 32 (byte swaps): `b_bswap` on words, `c_load32be` on the 4 bytes of each word.
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

/// Gap 5 (`&&`, `||` of comparisons): each probe on bytes or words (`fixed`: all true; `random`), and as a
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

/// Gap 8 (callee-saved registers in a body whose only call is a sibling one): `r_even` on depths below 64.
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

/// Gap 14 (return diamonds): `s_max`, `s_clamp`, `s_cmp3` on words (`fixed`: one value, predictable;
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

/// Gaps 15 to 20 (arithmetic idioms): conditional negation and increment, quotient and remainder, a signed
/// remainder test, 32- and 16-bit bit counts, a masked shift; on unpredictable words and as latency chains.
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
    }
}
