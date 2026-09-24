// Benchmarking. Import with `import std::testing::bench;`.
//
// A benchmark is a `pub fn` marked `@bench` in a file under `bench/`. `super-c bench` finds them the way
// `super-c test` finds `@test` functions (no registry, no `main` to maintain), hands each one a `Bencher`
// and prints one report per benchmark.
//
//     @bench
//     pub fn parse_a_file(b: &mut bench::Bencher) {
//         let src = load_fixture();       // setup: outside the loop, so it is not timed
//         b.each(src.len() as i64);       // optional: report per byte as well as per round
//         while b.running() {
//             parse(src);                 // the measured work
//             b.tally(1, 1);              // optional: work units done, and how many were validated
//         }
//     }
//
// `running()` is the whole protocol: it starts the clock, and each time round it stops the clock, keeps the
// sample and decides whether another round is wanted. The rounds come in two phases:
//
//   1. throughput: `warmup` rounds first (the first one is kept apart as the COLD sample, since it pays for
//      cold caches and lazily-started runtimes and is not the number anyone means), then `rounds` samples
//      with allocation accounting OFF, so nothing but the clock reads touch the measured work. Each sample
//      carries its wall time, the CPU cycles every thread of the process spent in it and the process CPU time.
//   2. diagnostic: `diag_rounds` more rounds with allocation accounting ON, for the allocation calls and bytes
//      per round. Their wall times are kept apart: the difference to the throughput median is what the
//      accounting cost, and a diagnostic figure is never mixed into a throughput one.
//
// What is reported is the DISTRIBUTION (min, median, p95, p99 once there are a hundred samples, standard
// deviation), since a single mean hides exactly the variance that makes a benchmark a lie. Memory is reported
// after the rounds: the resident set (its peak is independent only when the runner gave the benchmark a fresh
// process, which it does by default), the bytes mapped for task stacks, and what the task pool retains.
//
// Setup that has to happen INSIDE a round is excluded with `pause`/`resume`:
//
//     while b.running() {
//         b.pause();
//         let input = build_input();      // not counted
//         b.resume();
//         process(input);                 // counted
//     }.
//
// Every report line also goes to `$SC_BENCH_LOG` as one JSON object per line when that variable is set: the
// build identity, the platform, the worker limits, the sample counts and every figure above.

import stdio;
import stdlib;
import math;
import std::parallel::platform as platform;
import std::parallel::runtime as runtime;
import std::parallel::blocking as blocking;
import std::testing::bench_sys as sys;

const DEFAULT_ROUNDS: i32 = 100; // throughput samples kept per benchmark (p99 needs a hundred)
const DEFAULT_WARMUP: i32 = 1; // rounds run first; the first is the cold sample
const DEFAULT_DIAG: i32 = 3; // diagnostic rounds, allocation accounting on
const P99_MIN_SAMPLES: usize = 100; // below this a p99 is not reported
const NO_P99: f64 = 0.0; // the p99 of too few samples
const UNAVAILABLE: f64 = -1.0; // a figure whose counter this platform lacks

static mut G_BUILD_ID: str<'static> = ""; // what the runner was built from (see `begin`)
static mut G_FLAGS: str<'static> = ""; // the profile and C flags the runner was compiled with
static mut G_FAILED: bool = false; // a benchmark reported a failure (see `fail`)
static mut G_FRESH: bool = false; // every benchmark runs in a process of its own (see `run`)
static mut G_BURN_NS: f64 = 0.0; // `burn`'s measured cost per iteration (see `calibrate`)

/// The distribution of a sample set: `summarize` fills one. `p99` is 0 and not reported below
/// `P99_MIN_SAMPLES` samples.
pub struct Summary {
    pub n: usize,
    pub min: f64,
    pub median: f64,
    pub p95: f64,
    pub p99: f64,
    pub mean: f64,
    pub sd: f64, // population standard deviation
}

/// Sort `samples` in place and describe them. Panics: `samples` is empty (assert).
pub fn summarize(samples: &mut Vector<f64>) Summary {
    let n = samples.len();
    assert(n > 0);
    samples.sort();
    let mut sum: f64 = 0.0;
    for i in 0..n {
        sum = sum + samples[i];
    }
    let mean = sum / n as f64;
    let mut var: f64 = 0.0;
    for i in 0..n {
        let d = samples[i] - mean;
        var = var + d * d;
    }
    return Summary {
        n: n,
        min: samples[0],
        median: median_of(samples),
        p95: samples[(n * 95 + 99) / 100 - 1],
        p99: if n >= P99_MIN_SAMPLES {
            samples[(n * 99 + 99) / 100 - 1];
        } else {
            NO_P99;
        },
        mean: mean,
        sd: unsafe math::sqrt(var / n as f64),
    };
}

/// A per-operation distribution as note text: `name` and its `unit`, then median, p95, p99 (when the
/// samples allow one) and the maximum over `samples`, which are sorted in place. Empty samples give "".
pub fn dist_text(name: str, unit: str, samples: &mut Vector<f64>) String {
    let mut t = String::new();
    if samples.len() == 0 {
        return t;
    }
    let sm = summarize(samples);
    t.push_str(name);
    t.push_str(": median ");
    t.push_f64_prec(sm.median, 2);
    t.push_str(" ");
    t.push_str(unit);
    t.push_str(", p95 ");
    t.push_f64_prec(sm.p95, 2);
    if sm.p99 != NO_P99 {
        t.push_str(", p99 ");
        t.push_f64_prec(sm.p99, 2);
    }
    t.push_str(", max ");
    t.push_f64_prec(samples[samples.len() - 1], 2);
    t.push_str(" (");
    t.push_u64(sm.n as u64);
    t.push_str(" samples)");
    return t;
}

/// One benchmark's driver: the loop condition, the clock, the counters and the samples it collects. The
/// runner makes one per `@bench` function; a benchmark only ever calls the methods below.
@no_const
pub struct Bencher {
    name: String,
    units: i64, // work units per round (`each`); 0 reports per round only
    unit_name: String,
    samples: Vector<f64>, // throughput phase: seconds per round, warm-ups excluded
    cycles: Vector<f64>, // throughput phase: CPU cycles per round (every thread), when available
    cpu: Vector<f64>, // throughput phase: process CPU nanoseconds per round
    diag: Vector<f64>, // diagnostic phase: seconds per round
    extra: String,
    rounds: i32,
    warmup: i32,
    diag_rounds: i32,
    done: i32, // rounds started so far, warm-ups included
    diag_done: i32, // diagnostic rounds started so far
    phase: i32, // 0 throughput, 1 diagnostic
    cold: f64, // seconds of the very first round; negative when there was no warm-up round
    t0: u64, // when the current round's clock started
    excluded: u64, // ns paused out of the current round
    pause_at: u64, // when `pause` stopped the clock; 0 when running
    c0: i64, // cycle counter at the round start
    p0: i64, // process CPU ns at the round start
    a0: i64, // allocation calls at the round start (diagnostic phase)
    b0: i64, // allocation bytes at the round start (diagnostic phase)
    diag_calls: i64,
    diag_bytes: i64,
    work: i64, // `tally`: work units the benchmark did, every round
    ok: i64, // `tally`: of those, how many it validated
    tallied: bool,
    rss_before: i64, // resident bytes before the first round (-1 unavailable)
    rss_after: i64, // resident bytes after the throughput rounds
    stack_after: usize, // bytes mapped for task stacks after the throughput rounds
    pool_after: usize, // bytes the task pool retains after the throughput rounds
}

extend Bencher {
    /// A fresh benchmark named `name`. The runner calls this; a benchmark never needs to.
    pub fn new(name: str) Bencher {
        return Bencher {
            name: String::from_str(name),
            units: 0,
            unit_name: String::from_str("op"),
            samples: Vector::<f64>::new(),
            cycles: Vector::<f64>::new(),
            cpu: Vector::<f64>::new(),
            diag: Vector::<f64>::new(),
            extra: String::new(),
            rounds: DEFAULT_ROUNDS,
            warmup: DEFAULT_WARMUP,
            diag_rounds: DEFAULT_DIAG,
            done: 0,
            diag_done: 0,
            phase: 0,
            cold: -1.0,
            t0: 0,
            excluded: 0,
            pause_at: 0,
            c0: 0,
            p0: 0,
            a0: 0,
            b0: 0,
            diag_calls: 0,
            diag_bytes: 0,
            work: 0,
            ok: 0,
            tallied: false,
            rss_before: -1,
            rss_after: -1,
            stack_after: 0,
            pool_after: 0,
        };
    }

    /// How many throughput samples to keep (default 100). Call before the loop.
    pub fn set_rounds(self: &mut Self, n: i32) {
        if n > 0 {
            self.rounds = n;
        }
    }

    /// How many rounds to run first (default 1; the first is the cold sample). Call before the loop.
    pub fn set_warmup(self: &mut Self, n: i32) {
        if n >= 0 {
            self.warmup = n;
        }
    }

    /// How many diagnostic rounds to run with allocation accounting on (default 3; 0 for a benchmark that
    /// reads the allocation counters itself). Call before the loop.
    pub fn set_diag_rounds(self: &mut Self, n: i32) {
        if n >= 0 {
            self.diag_rounds = n;
        }
    }

    /// How many units of work one round does, so the report carries a per-unit cost as well as a per-round
    /// one. `b.each(1000)` on a round that processes a thousand tasks gives "ns/op" per task.
    pub fn each(self: &mut Self, units: i64) {
        self.units = units;
    }

    /// Rename the unit in the report ("op" by default): `b.unit("task")`, `b.unit("byte")`.
    pub fn unit(self: &mut Self, name: str) {
        self.unit_name.clear();
        self.unit_name.push_str(name);
    }

    /// Anything else worth printing on this benchmark's line: a cache hit rate, a per-item latency.
    /// Appended verbatim after the timings.
    pub fn note(self: &mut Self, s: str) {
        self.extra.clear();
        self.extra.push_str(s);
    }

    /// Append to the note, after what is already there.
    pub fn note_more(self: &mut Self, s: str) {
        if self.extra.len() != 0 {
            self.extra.push_str("; ");
        }
        self.extra.push_str(s);
    }

    /// Record one round's work: `done` units performed, `ok` of them validated. Summed over every round
    /// and printed; a benchmark whose `ok` falls short of `done` is a failed run (`fail` is called for it).
    pub fn tally(self: &mut Self, done: i64, ok: i64) {
        self.work = self.work + done;
        self.ok = self.ok + ok;
        self.tallied = true;
    }

    /// The loop condition. Stops the clock on the finished round, keeps it unless it was a warm-up,
    /// and starts the next one. False when enough samples have been collected.
    pub fn running(self: &mut Self) bool {
        // The clock stops first; every counter is read outside the timed interval.
        let now = platform::now_ns();
        if self.done > 0 {
            if self.pause_at != 0 {
                // A benchmark that paused and never resumed still gets a usable number.
                self.resume();
            }
            let dt = (now - self.t0 - self.excluded) as f64 / 1000000000.0;
            if self.phase == 0 {
                if self.done == 1 && self.warmup > 0 {
                    self.cold = dt;
                }
                if self.done > self.warmup {
                    self.samples.push(dt);
                    if unsafe sys::sc_bs_cycles_scope() != 0 {
                        self.cycles.push((unsafe sys::sc_bs_cycles() - self.c0) as f64);
                    }
                    let p1 = unsafe sys::sc_bs_cpu_ns();
                    if p1 >= 0 && self.p0 >= 0 {
                        self.cpu.push((p1 - self.p0) as f64);
                    }
                }
            } else {
                self.diag.push(dt);
                self.diag_calls = self.diag_calls + (unsafe sys::sc_bs_alloc_calls() - self.a0);
                self.diag_bytes = self.diag_bytes + (unsafe sys::sc_bs_alloc_bytes() - self.b0);
            }
        } else {
            self.rss_before = unsafe sys::sc_bs_rss_now();
        }
        if self.phase == 0 && self.done >= self.warmup + self.rounds {
            self.rss_after = unsafe sys::sc_bs_rss_now();
            self.stack_after = platform::stack_bytes();
            self.pool_after = runtime::pool_retained_bytes();
            if self.diag_rounds == 0 || unsafe sys::sc_bs_alloc_supported() == 0 {
                return false;
            }
            self.phase = 1;
            unsafe sys::sc_bs_alloc_enable(1);
        }
        if self.phase == 1 {
            if self.diag_done >= self.diag_rounds {
                unsafe sys::sc_bs_alloc_enable(0);
                return false;
            }
            self.diag_done = self.diag_done + 1;
            self.a0 = unsafe sys::sc_bs_alloc_calls();
            self.b0 = unsafe sys::sc_bs_alloc_bytes();
        }
        self.done = self.done + 1;
        self.excluded = 0;
        self.pause_at = 0;
        self.c0 = unsafe sys::sc_bs_cycles();
        self.p0 = unsafe sys::sc_bs_cpu_ns();
        self.t0 = platform::now_ns();
        return true;
    }

    /// Stop the clock for setup that should not be measured. Balanced by `resume`.
    pub fn pause(self: &mut Self) {
        if self.pause_at == 0 {
            self.pause_at = platform::now_ns();
        }
    }

    /// Start the clock again after a `pause`.
    pub fn resume(self: &mut Self) {
        if self.pause_at != 0 {
            self.excluded = self.excluded + (platform::now_ns() - self.pause_at);
            self.pause_at = 0;
        }
    }

    /// The throughput samples, in seconds, oldest first. For a benchmark that wants to report something of
    /// its own.
    pub fn samples(self: &Self) &Vector<f64> {
        return &self.samples;
    }

    /// Print this benchmark's report and log its record. The runner calls this; a benchmark never needs to.
    pub fn report(self: &mut Self) {
        let n = self.samples.len();
        if n == 0 {
            println("  {:<28} (no samples)", self.name.as_str());
            return;
        }
        if self.tallied && self.ok != self.work {
            let mut what = String::from_str(self.name.as_str());
            what.push_str(": validated ");
            what.push_i64(self.ok);
            what.push_str(" of ");
            what.push_i64(self.work);
            what.push_str(" work units");
            fail(what.as_str());
        }
        let sm = summarize(&mut self.samples);
        unsafe stdio::printf(
            "  %-28s n %3zu | min %8.3f | median %8.3f | p95 %8.3f | p99 ".ptr() as *const char,
            self.name.cstr(),
            n,
            sm.min * 1000.0,
            sm.median * 1000.0,
            sm.p95 * 1000.0,
        );
        if sm.p99 > 0.0 {
            unsafe stdio::printf("%8.3f".ptr() as *const char, sm.p99 * 1000.0);
        } else {
            unsafe stdio::printf("%8s".ptr() as *const char, "-".ptr() as *const char);
        }
        unsafe stdio::printf(" | sd %7.3f ms".ptr() as *const char, sm.sd * 1000.0);
        if self.units > 0 {
            unsafe stdio::printf(
                " | %9.1f ns/%s".ptr() as *const char,
                sm.median * 1000000000.0 / self.units as f64,
                self.unit_name.cstr(),
            );
        }
        if self.cold >= 0.0 {
            unsafe stdio::printf(" | cold %8.3f ms".ptr() as *const char, self.cold * 1000.0);
        }
        if self.extra.len() != 0 {
            unsafe stdio::printf(" | %s".ptr() as *const char, self.extra.cstr());
        }
        unsafe stdio::printf("\n".ptr() as *const char);

        // Per-round resources of the throughput rounds, and the validated work.
        unsafe stdio::printf("  %-28s ".ptr() as *const char, "".ptr() as *const char);
        let mut mcyc: f64 = UNAVAILABLE;
        if self.cycles.len() != 0 {
            let sc = summarize(&mut self.cycles);
            mcyc = sc.median / 1000000.0;
            unsafe stdio::printf(
                "cycles %9.2f Mcyc/round (%s)".ptr() as *const char,
                mcyc,
                cycles_scope_name().ptr() as *const char,
            );
        } else {
            unsafe stdio::printf("cycles unavailable".ptr() as *const char);
        }
        let mut cpu_ms: f64 = UNAVAILABLE;
        if self.cpu.len() != 0 {
            let sp = summarize(&mut self.cpu);
            cpu_ms = sp.median / 1000000.0;
            unsafe stdio::printf(" | cpu %8.3f ms/round".ptr() as *const char, cpu_ms);
        } else {
            unsafe stdio::printf(" | cpu time unavailable".ptr() as *const char);
        }
        if self.tallied {
            unsafe stdio::printf(" | work %lld ok %lld".ptr() as *const char, self.work, self.ok);
        }
        unsafe stdio::printf("\n".ptr() as *const char);

        // Allocations (diagnostic rounds) and memory.
        unsafe stdio::printf("  %-28s ".ptr() as *const char, "".ptr() as *const char);
        let dn = self.diag.len();
        let mut calls_pr: f64 = UNAVAILABLE;
        let mut bytes_pr: f64 = UNAVAILABLE;
        let mut diag_ms: f64 = UNAVAILABLE;
        if dn != 0 {
            calls_pr = self.diag_calls as f64 / dn as f64;
            bytes_pr = self.diag_bytes as f64 / dn as f64;
            let sd = summarize(&mut self.diag);
            diag_ms = sd.median * 1000.0;
            unsafe stdio::printf(
                "alloc %9.1f K calls %9.3f MiB per round (%zu diag rounds, median %.3f ms, %+.1f%%)".ptr() as *const char,
                calls_pr / 1000.0,
                bytes_pr / 1048576.0,
                dn,
                diag_ms,
                (sd.median / sm.median - 1.0) * 100.0,
            );
            if self.units > 0 {
                unsafe stdio::printf(
                    " | %.2f calls/%s".ptr() as *const char,
                    calls_pr / self.units as f64,
                    self.unit_name.cstr(),
                );
            }
        } else if unsafe sys::sc_bs_alloc_supported() == 0 {
            unsafe stdio::printf("alloc unavailable on this platform".ptr() as *const char);
        } else {
            unsafe stdio::printf("alloc not sampled".ptr() as *const char);
        }
        unsafe stdio::printf("\n  %-28s ".ptr() as *const char, "".ptr() as *const char);
        let peak = unsafe sys::sc_bs_rss_peak();
        if peak >= 0 {
            unsafe stdio::printf(
                "rss peak %8.1f MiB%s".ptr() as *const char,
                peak as f64 / 1048576.0,
                if unsafe G_FRESH {
                    "".ptr() as *const char;
                } else {
                    " (process-cumulative: not this benchmark alone)".ptr() as *const char;
                },
            );
        } else {
            unsafe stdio::printf("rss peak unavailable".ptr() as *const char);
        }
        if self.rss_after >= 0 && self.rss_before >= 0 {
            unsafe stdio::printf(
                " | rss now %8.1f MiB (%+.1f during)".ptr() as *const char,
                self.rss_after as f64 / 1048576.0,
                (self.rss_after - self.rss_before) as f64 / 1048576.0,
            );
        }
        unsafe stdio::printf(
            " | stacks %8.1f MiB mapped | pool %8.1f MiB retained\n".ptr() as *const char,
            self.stack_after as f64 / 1048576.0,
            self.pool_after as f64 / 1048576.0,
        );

        // The record.
        let mut js = String::with_capacity(1024);
        js.push_str("{\"v\":1,\"name\":");
        json_str(&mut js, self.name.as_str());
        json_identity(&mut js);
        js.push_str(",\"rounds\":");
        js.push_u64(n as u64);
        js.push_str(",\"warmup\":");
        js.push_i64(self.warmup);
        js.push_str(",\"unit\":");
        json_str(&mut js, self.unit_name.as_str());
        js.push_str(",\"units\":");
        js.push_i64(self.units);
        js.push_str(",\"cold_ms\":");
        js.push_f64_prec(self.cold * 1000.0, 3);
        json_dist(&mut js, "ms", &sm, 1000.0);
        js.push_str(",\"ns_per_unit\":");
        js.push_f64_prec(
            if self.units > 0 {
                sm.median * 1000000000.0 / self.units as f64;
            } else {
                UNAVAILABLE;
            },
            1,
        );
        js.push_str(",\"mcyc_per_round\":");
        js.push_f64_prec(mcyc, 3);
        js.push_str(",\"cycles_scope\":");
        json_str(&mut js, cycles_scope_name());
        js.push_str(",\"cpu_ms_per_round\":");
        js.push_f64_prec(cpu_ms, 3);
        js.push_str(",\"alloc_calls_per_round\":");
        js.push_f64_prec(calls_pr, 1);
        js.push_str(",\"alloc_bytes_per_round\":");
        js.push_f64_prec(bytes_pr, 0);
        js.push_str(",\"diag_rounds\":");
        js.push_u64(dn as u64);
        js.push_str(",\"diag_ms_median\":");
        js.push_f64_prec(diag_ms, 3);
        js.push_str(",\"rss_peak_bytes\":");
        js.push_i64(peak);
        js.push_str(",\"rss_peak_independent\":");
        js.push_str(
            if unsafe G_FRESH {
                "true";
            } else {
                "false";
            },
        );
        js.push_str(",\"rss_now_bytes\":");
        js.push_i64(self.rss_after);
        js.push_str(",\"rss_before_bytes\":");
        js.push_i64(self.rss_before);
        js.push_str(",\"stack_bytes\":");
        js.push_u64(self.stack_after as u64);
        js.push_str(",\"pool_bytes\":");
        js.push_u64(self.pool_after as u64);
        js.push_str(",\"work\":");
        js.push_i64(self.work);
        js.push_str(",\"ok\":");
        js.push_i64(self.ok);
        js.push_str(",\"note\":");
        json_str(&mut js, self.extra.as_str());
        js.push_byte(b'}');
        log_line(js.as_str());
    }
}

const fn median_of(v: &Vector<f64>) f64 {
    let n = v.len();
    if n % 2 == 0 {
        return (v[n / 2 - 1] + v[n / 2]) / 2.0;
    }
    return v[n / 2];
}

// A stable name for what the cycle counter covers.
fn cycles_scope_name() str<'static> {
    let s = unsafe sys::sc_bs_cycles_scope();
    if s == 0 {
        return "unavailable";
    }
    if (s & sys::CYC_ALL) == 0 {
        return "calling thread only";
    }
    if (s & sys::CYC_EXISTING) == 0 {
        return "threads created after start, kernel excluded";
    }
    if (s & sys::CYC_KERNEL) != 0 {
        return "all threads, kernel included";
    }
    return "all threads, kernel excluded";
}

/// Append `s` inside a JSON string, escaped.
pub fn json_str(js: &mut String, s: str) {
    js.push_byte(b'"');
    for i in 0..s.len() {
        let c = s[i];
        if c == b'"' || c == b'\\' {
            js.push_byte(b'\\');
        }
        if c < 32 {
            js.push_byte(b' ');
        } else {
            js.push_byte(c);
        }
    }
    js.push_byte(b'"');
}

/// Append a distribution as `,"name":{...}`; `scale` converts the samples' unit to the reported one.
pub fn json_dist(js: &mut String, name: str, sm: &Summary, scale: f64) {
    js.push_str(",\"");
    js.push_str(name);
    js.push_str("\":{\"n\":");
    js.push_u64(sm.n as u64);
    js.push_str(",\"min\":");
    js.push_f64_prec(sm.min * scale, 3);
    js.push_str(",\"median\":");
    js.push_f64_prec(sm.median * scale, 3);
    js.push_str(",\"p95\":");
    js.push_f64_prec(sm.p95 * scale, 3);
    js.push_str(",\"p99\":");
    js.push_f64_prec(sm.p99 * scale, 3);
    js.push_str(",\"mean\":");
    js.push_f64_prec(sm.mean * scale, 3);
    js.push_str(",\"sd\":");
    js.push_f64_prec(sm.sd * scale, 3);
    js.push_byte(b'}');
}

/// Append the record fields every log line shares: build, flags, platform, CPU, worker limits.
pub fn json_identity(js: &mut String) {
    js.push_str(",\"build\":");
    json_str(js, unsafe G_BUILD_ID);
    js.push_str(",\"flags\":");
    json_str(js, unsafe G_FLAGS);
    js.push_str(",\"os\":");
    json_str(js, str::from_cstr(unsafe sys::sc_bs_os()));
    js.push_str(",\"arch\":");
    json_str(js, str::from_cstr(unsafe sys::sc_bs_arch()));
    let mut cpu = Array::<char, 256>::new();
    if unsafe sys::sc_bs_cpu_model(&mut cpu[0], 256) != 0 {
        cpu[0] = 0 as char;
    }
    js.push_str(",\"cpu\":");
    json_str(js, str::from_cstr(&cpu[0]));
    js.push_str(",\"ncpu\":");
    js.push_u64(platform::ncpu() as u64);
    js.push_str(",\"workers\":");
    js.push_u64(runtime::worker_count() as u64);
    js.push_str(",\"blocking_threads\":");
    js.push_u64(blocking::MAX_THREADS as u64);
    js.push_str(",\"fresh_process\":");
    js.push_str(
        if unsafe G_FRESH {
            "true";
        } else {
            "false";
        },
    );
}

/// Append one line to `$SC_BENCH_LOG` when it is set. A file that cannot be opened is a failed run: a
/// record the caller asked for and did not get is not a result.
pub fn log_line(line: str) {
    let outp = stdlib::getenv("SC_BENCH_LOG");
    if outp == null {
        return;
    }
    let path = str::from_cstr(outp);
    let f = stdio::fopen(path, "ab");
    if f == null {
        let mut what = String::from_str("cannot append to SC_BENCH_LOG=");
        what.push_str(path);
        fail(what.as_str());
        return;
    }
    unsafe stdio::fwrite(line.ptr(), 1, line.len(), f);
    unsafe stdio::fputc(10, f);
    unsafe stdio::fclose(f);
}

// --- the optimisation barrier ---------------------------------------------------------------------------

/// Consume `v`: the computation that produced it cannot be deleted or folded past this call, whatever the
/// optimiser proves about it. A volatile store in the platform glue.
pub fn black_box(v: u64) {
    unsafe sys::sc_bs_sink(v);
}

/// `rounds` iterations of a dependent multiply-add chain: arithmetic a task can be given so it is not pure
/// scheduling. The chain starts from the barrier's last value (a volatile load), so the result is unknown
/// at compile time however constant `rounds` is; the caller feeds the result to `black_box`. Unsigned, so
/// it wraps at width where the signed form would trap.
pub fn burn(rounds: i64) u64 {
    let mut acc: u64 = unsafe sys::sc_bs_sunk() | 1;
    for i in 0..rounds {
        acc = acc * 6364136223846793005 + i as u64;
    }
    return acc;
}

/// `burn`'s cost per iteration, in nanoseconds, measured by `calibrate`; 0 before it ran.
pub fn burn_ns_per_iter() f64 {
    return unsafe G_BURN_NS;
}

// Measure `burn` once per process and fail the run when the loop is not being executed: a dependent 64-bit
// multiply chain cannot run under a quarter of a nanosecond per iteration on any current core, so a figure
// below that means the optimiser deleted or closed-formed the work the benchmarks charge tasks with.
fn calibrate() {
    let n: i64 = 1 << 22;
    let mut best: f64 = 0.0;
    for r in 0..3 {
        let t0 = platform::now_ns();
        black_box(burn(n));
        let dt = (platform::now_ns() - t0) as f64 / n as f64;
        if r == 0 || dt < best {
            best = dt;
        }
    }
    unsafe G_BURN_NS = best;
    if best < 0.25 {
        fail("the optimisation barrier does not hold: burn() runs under 0.25 ns per iteration");
    }
}

// --- the runner ---------------------------------------------------------------------------------------

/// One discovered benchmark: its display name, the function, and whether it prints its own report.
pub struct Entry {
    pub name: str<'static>,
    pub run: fn(&mut Bencher) void,
    pub quiet: bool,
}

/// The benchmark selection from the runner's arguments: the text after `--filter=`, or "" when every
/// benchmark runs. `pub` for the generated runner.
pub fn filter_of<'a>(argv: &Vector<str<'a>>) str<'a> {
    for i in 0..argv.len() {
        let a = argv[i];
        if a.starts_with("--filter=") {
            return a.slice(9, a.len());
        }
    }
    return "";
}

/// Whether the benchmark called `name` runs under `filter`: a substring match, and "" selects all.
/// `pub` for the generated runner.
pub fn selected(name: str, filter: str) bool {
    return filter.len() == 0 || name.contains(filter);
}

fn has_flag(argv: &Vector<str>, flag: str) bool {
    for i in 0..argv.len() {
        if argv[i] == flag {
            return true;
        }
    }
    return false;
}

/// Printed once before the first benchmark. `build_id` names the sources the runner was built from
/// (the checkout's commit, "-dirty" appended when it had local changes) and `flags` the profile and C
/// flags it was compiled with. Opens the cycle counter while the process still has one thread, and
/// calibrates the optimisation barrier. `pub` for the generated runner.
pub fn begin(build_id: str<'static>, flags: str<'static>) {
    unsafe G_BUILD_ID = build_id;
    unsafe G_FLAGS = flags;
    let _ = unsafe sys::sc_bs_cycles_scope(); // opens the counters while this is the only thread
    calibrate();
    let mut cpu = Array::<char, 256>::new();
    if unsafe sys::sc_bs_cpu_model(&mut cpu[0], 256) != 0 {
        unsafe stdio::snprintf(&mut cpu[0], 256, "%s".ptr() as *const char, "unknown CPU".ptr() as *const char);
    }
    println("");
    println("running benchmarks (build {}; {})", build_id, flags);
    unsafe stdio::printf(
        "  %s %s, %s, %zu cpus; %zu workers, %zu blocking threads; cycles: %s; allocations: %s; burn %.2f ns/iter\n".ptr() as *const char,
        sys::sc_bs_os(),
        sys::sc_bs_arch(),
        (&cpu[0]) as *const char,
        platform::ncpu(),
        runtime::worker_count(),
        blocking::MAX_THREADS,
        cycles_scope_name().ptr() as *const char,
        if unsafe sys::sc_bs_alloc_supported() != 0 {
            "counted in diagnostic rounds".ptr() as *const char;
        } else {
            "unavailable on this platform".ptr() as *const char;
        },
        unsafe G_BURN_NS,
    );
}

/// The identity `begin` was given.
pub fn build_id() str<'static> {
    return unsafe G_BUILD_ID;
}

/// A benchmark could not measure what it claims to: the run exits nonzero after every benchmark ran.
pub fn fail(what: str) {
    unsafe G_FAILED = true;
    eprintln("bench: FAILED: {}", what);
}

// Run one benchmark on this thread and report it.
fn run_one(e: &Entry) {
    let mut b = Bencher::new(e.name);
    e.run(&mut b);
    if !e.quiet {
        b.report();
    }
}

// Release every runtime pool a benchmark may have started. The blocking pool has threads of its own that
// `runtime::shutdown` does not join, so it goes first; both are no-ops when nothing started them.
fn shutdown_pools() {
    blocking::shutdown();
    runtime::shutdown();
}

/// Run every selected entry and return the process exit code. Each benchmark runs in a forked process of
/// its own (so its peak resident set and its runtime pools are its alone, and a crash fails only it), unless
/// `--in-process` is given or the platform has no fork; a child returns its own code here and the caller
/// must return it from `main`. `pub` for the generated runner.
pub fn run(argv: &Vector<str>, entries: &Vector<Entry>) i32 {
    let filter = filter_of(argv);
    let mut can_fork = !has_flag(argv, "--in-process");
    let mut ran: i32 = 0;
    for i in 0..entries.len() {
        let e = entries.at(i);
        if !selected(e.name, filter) {
            continue;
        }
        ran = ran + 1;
        if can_fork {
            unsafe sys::sc_bs_flush();
            let pid = unsafe sys::sc_bs_fork();
            if pid == 0 {
                // The child: this one benchmark, then its exit code goes back through `main`, so the
                // runner's own frames are released and the leak tracker's exit report sees a clean process.
                unsafe G_FRESH = true;
                run_one(e);
                shutdown_pools();
                return if unsafe G_FAILED {
                    1;
                } else {
                    0;
                };
            }
            if pid < 0 {
                // No fork here (Windows, wasm): the rest of the run stays in this process.
                can_fork = false;
            } else {
                let code = unsafe sys::sc_bs_wait(pid);
                if code != 0 {
                    let mut what = String::from_str(e.name);
                    if code > 128 {
                        what.push_str(" died with signal ");
                        what.push_i64(code - 128);
                    } else {
                        what.push_str(" exited with code ");
                        what.push_i64(code);
                    }
                    fail(what.as_str());
                }
                continue;
            }
        }
        run_one(e);
    }
    shutdown_pools();
    return end(ran, filter);
}

/// Printed once after the last one; `n` is how many ran. A `filter` that selected nothing is an error, as
/// a mistyped name would otherwise report success; so is any `fail`. `pub` for the generated runner.
pub fn end(n: i32, filter: str) i32 {
    println("");
    println("{} benchmark(s)", n);
    if n == 0 && filter.len() != 0 {
        eprintln("bench: no benchmark name contains '{}'", filter);
        return 1;
    }
    if unsafe G_FAILED {
        eprintln("bench: a benchmark reported a failure (see above)");
        return 1;
    }
    return 0;
}
