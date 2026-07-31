// Benchmarking. Import with `import std::testing::bench;`.
//
// A benchmark is a `pub fn` marked `@bench` in a file under `bench/`. `super-c bench` finds them the way
// `super-c test` finds `@test` functions -- no registry, no `main` to maintain -- hands each one a `Bencher`
// and prints one table.
//
//     @bench
//     pub fn parse_a_file(b: &mut bench::Bencher) {
//         let src = load_fixture();       // setup: outside the loop, so it is not timed
//         b.each(src.len() as i64);       // optional: report per byte as well as per round
//         while b.running() {
//             parse(src);                 // the measured work
//         }
//     }
//
// `running()` is the whole protocol: it starts the clock, and each time round it stops the clock, keeps the
// sample and decides whether another round is wanted. Warm-up rounds run first and are discarded, because
// the first pass through any code pays for cold caches and lazily-started runtimes and is not the number
// anyone means. What is reported is the DISTRIBUTION -- min, median, p95, standard deviation -- since a
// single mean hides exactly the variance that makes a benchmark a lie.
//
// Setup that has to happen INSIDE a round is excluded with `pause`/`resume`:
//
//     while b.running() {
//         b.pause();
//         let input = build_input();      // not counted
//         b.resume();
//         process(input);                 // counted
//     }

import stdio;
import math;
import std::parallel::platform as platform;

const DEFAULT_ROUNDS: i32 = 20; // samples kept per benchmark
const DEFAULT_WARMUP: i32 = 1; // rounds run and discarded first

/// One benchmark's driver: the loop condition, the clock, and the samples it collects. The runner makes one
/// per `@bench` function; a benchmark only ever calls the methods below.
@no_const
pub struct Bencher {
    name: String,
    units: i64, // work units per round (`each`); 0 reports per round only
    unit_name: String,
    samples: Vector<f64>, // seconds per round, warm-ups excluded
    extra: String,
    rounds: i32,
    warmup: i32,
    done: i32, // rounds started so far, warm-ups included
    t0: u64, // when the current round's clock started
    excluded: u64, // ns paused out of the current round
    pause_at: u64, // when `pause` stopped the clock; 0 when running
}

extend Bencher {
    /// A fresh benchmark named `name`. The runner calls this; a benchmark never needs to.
    pub fn new(name: str) Bencher {
        return Bencher {
            name: String::from_str(name),
            units: 0,
            unit_name: String::from_str("op"),
            samples: Vector::<f64>::new(),
            extra: String::new(),
            rounds: DEFAULT_ROUNDS,
            warmup: DEFAULT_WARMUP,
            done: 0,
            t0: 0,
            excluded: 0,
            pause_at: 0,
        };
    }

    /// How many samples to keep (default 20). Call before the loop.
    pub fn set_rounds(self: &mut Self, n: i32) {
        if n > 0 {
            self.rounds = n;
        }
    }

    /// How many rounds to run and discard first (default 1). Call before the loop.
    pub fn set_warmup(self: &mut Self, n: i32) {
        if n >= 0 {
            self.warmup = n;
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

    /// Anything else worth printing on this benchmark's line -- an allocation count, a cache hit rate.
    /// Appended verbatim after the timings.
    pub fn note(self: &mut Self, s: str) {
        self.extra.clear();
        self.extra.push_str(s);
    }

    /// The loop condition. Stops the clock on the round just finished, keeps it unless it was a warm-up,
    /// and starts the next one. False when enough samples have been collected.
    pub fn running(self: &mut Self) bool {
        if self.done > 0 {
            if self.pause_at != 0 {
                self.resume(); // a benchmark that paused and never resumed still gets a usable number
            }
            let dt = platform::now_ns() - self.t0 - self.excluded;
            if self.done > self.warmup {
                self.samples.push(dt as f64 / 1000000000.0);
            }
        }
        if self.done >= self.warmup + self.rounds {
            return false;
        }
        self.done = self.done + 1;
        self.excluded = 0;
        self.pause_at = 0;
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

    /// The samples, in seconds, oldest first. For a benchmark that wants to report something of its own.
    pub fn samples(self: &Self) &Vector<f64> {
        return &self.samples;
    }

    /// Print this benchmark's line. The runner calls this; a benchmark never needs to.
    pub fn report(self: &mut Self) {
        let n = self.samples.len();
        if n == 0 {
            println("  {:<28} (no samples)", self.name.as_str());
            return;
        }
        sort_secs(&mut self.samples);
        let med = median_of(&self.samples);
        let p95 = self.samples[(n * 95 + 99) / 100 - 1];
        let mut sum: f64 = 0.0;
        for i in 0..n {
            sum = sum + self.samples[i];
        }
        let mean = sum / n as f64;
        let mut var: f64 = 0.0;
        for i in 0..n {
            let d = self.samples[i] - mean;
            var = var + d * d;
        }
        let sd = unsafe math::sqrt(var / n as f64);
        unsafe stdio::printf(
            "  %-28s min %8.3f | median %8.3f | p95 %8.3f | sd %7.3f ms".ptr() as *const char,
            self.name.cstr(),
            self.samples[0] * 1000.0,
            med * 1000.0,
            p95 * 1000.0,
            sd * 1000.0,
        );
        if self.units > 0 {
            unsafe stdio::printf(
                "  | %9.1f ns/%s".ptr() as *const char,
                med * 1000000000.0 / self.units as f64,
                self.unit_name.cstr(),
            );
        }
        if self.extra.len() != 0 {
            unsafe stdio::printf("  | %s".ptr() as *const char, self.extra.cstr());
        }
        unsafe stdio::printf("\n".ptr() as *const char);
    }
}

extend Bencher as Free {
    pub fn free(self: &mut Bencher) {
        self.name.free();
        self.unit_name.free();
        self.samples.free();
        self.extra.free();
    }
}

// Insertion sort: a benchmark keeps tens of samples, so the simple thing is also the right one.
fn sort_secs(v: &mut Vector<f64>) {
    let n = v.len();
    let mut i: usize = 1;
    while i < n {
        let x = v[i];
        let mut j = i;
        while j > 0 && v[j - 1] > x {
            v[j] = v[j - 1];
            j = j - 1;
        }
        v[j] = x;
        i = i + 1;
    }
}

const fn median_of(v: &Vector<f64>) f64 {
    let n = v.len();
    if n % 2 == 0 {
        return (v[n / 2 - 1] + v[n / 2]) / 2.0;
    }
    return v[n / 2];
}

/// Printed once before the first benchmark. `pub` for the generated runner.
pub fn begin() {
    println("");
    println("running benchmarks");
}

/// Printed once after the last one. `pub` for the generated runner.
pub fn end(n: i32) i32 {
    println("");
    println("{} benchmark(s)", n);
    return 0;
}
