// The benchmark instrumentation (std/testing/bench_sys, std/testing/bench): allocation counts that stay
// exact under concurrent allocation, cycle coverage of every thread, counters that report their own
// availability, an optimisation barrier that holds, and the distribution arithmetic.

import stdlib;
import std::parallel::thread as thread;
import std::parallel::sync as sync;
import std::parallel::platform as platform;
import std::testing::bench_sys as sys;
import std::testing::bench as bench;

const THREADS: i64 = 8;
const EACH: i64 = 20000;
const BURN_ITERS: i64 = 20000000; // multiply-chain iterations each burning thread performs

// Eight OS threads each make EACH counted allocations between two barriers; the snapshots taken while
// every thread stands at a barrier must differ by exactly THREADS * EACH calls and bytes. The racy
// shared counter this replaced lost about four fifths of these.
@test
fn concurrent_allocation_counts_are_exact() {
    if unsafe sys::sc_bs_alloc_supported() == 0 {
        // Windows: nothing is counted, and the reports say so.
        return;
    }
    let arrive = sync::Barrier::new(THREADS + 1);
    let go = sync::Barrier::new(THREADS + 1);
    let end = sync::Barrier::new(THREADS + 1);
    let mut hs = Vector::<thread::JoinHandle<i64>>::new();
    for _t in 0..THREADS {
        let a = arrive.clone();
        let g = go.clone();
        let e = end.clone();
        hs.push(
            thread::spawn(
                fn() i64 {
                    let _ = a.wait();
                    let _ = g.wait();
                    let mut n: i64 = 0;
                    for _i in 0..EACH {
                        let p = unsafe stdlib::malloc(16);
                        if p != null {
                            n = n + 1;
                        }
                        unsafe stdlib::free(p);
                    }
                    let _ = e.wait();
                    return n;
                },
            ),
        );
    }
    let _ = arrive.wait();
    unsafe sys::sc_bs_alloc_enable(1);
    let mut s0 = Array::<i64, 4>::new();
    unsafe sys::sc_bs_alloc_snapshot(&mut s0[0]);
    let _ = go.wait();
    let _ = end.wait();
    let mut s1 = Array::<i64, 4>::new();
    unsafe sys::sc_bs_alloc_snapshot(&mut s1[0]);
    unsafe sys::sc_bs_alloc_enable(0);
    let mut total: i64 = 0;
    loop {
        switch hs.pop() {
            Some(h) => {
                total = total + h.join();
            },
            _ => {
                break;
            },
        };
    }
    assert_eq(total, THREADS * EACH);
    // Exact, but for the leak tracker's own tables: under SC_LEAK_CHECK it allocates a few blocks of
    // its own between the snapshots (measured: ten), and those are real allocations by this binary.
    let calls = s1[0] - s0[0];
    assert(calls >= THREADS * EACH, "no concurrent allocation is lost");
    assert(calls <= THREADS * EACH + 256, "only the tracker's own tables come on top");
    assert(s1[1] - s0[1] >= THREADS * EACH * 16, "every requested byte is counted");
    assert(s1[2] >= THREADS, "every allocating thread has a line");
    assert_eq(s1[3], 0);
}

// Counting off, an allocation is not counted.
@test
fn disabled_accounting_counts_nothing() {
    if unsafe sys::sc_bs_alloc_supported() == 0 {
        return;
    }
    unsafe sys::sc_bs_alloc_enable(0);
    let c0 = unsafe sys::sc_bs_alloc_calls();
    let p = unsafe stdlib::malloc(64);
    unsafe stdlib::free(p);
    assert_eq(unsafe sys::sc_bs_alloc_calls(), c0);
    assert_eq(unsafe sys::sc_bs_alloc_enabled(), 0);
}

// Four threads each perform BURN_ITERS dependent multiplies while the calling thread only waits in
// `join`: a caller-only counter would report near zero, while a counter that covers every thread must
// report at least one cycle per multiply of every thread. Bounded by WORK, not by time, so the check holds
// on a loaded box with fewer cores than threads (a CI runner sharing three cores with the test pool).
@test
fn cycles_cover_every_thread() {
    let scope = unsafe sys::sc_bs_cycles_scope();
    if scope == 0 {
        // Unavailable is a legal answer (containers, no PMU): the reports say so instead of showing zero.
        // TODO: the hosted macOS runner is a virtual machine whose cycle counter never advances, so the
        // shim's availability probe (bench_sys.c, `sc_bs_cycles_scope`) reports it unavailable and this
        // test returns here. Once CI runs on a hardware macOS runner, drop the probe and this early return
        // so the coverage assertions below run on every macOS build.
        return;
    }
    assert((scope & sys::CYC_ALL) != 0, "the counter covers every thread");
    let c0 = unsafe sys::sc_bs_cycles();
    let p0 = unsafe sys::sc_bs_cpu_ns();
    let mut hs = Vector::<thread::JoinHandle<u64>>::new();
    for _t in 0..4 {
        hs.push(
            thread::spawn(
                fn() u64 {
                    let acc = bench::burn(BURN_ITERS);
                    bench::black_box(acc);
                    return acc;
                },
            ),
        );
    }
    loop {
        switch hs.pop() {
            Some(h) => {
                let _ = h.join();
            },
            _ => {
                break;
            },
        };
    }
    let dc = (unsafe sys::sc_bs_cycles() - c0) as f64;
    let dp = (unsafe sys::sc_bs_cpu_ns() - p0) as f64;
    assert(dc >= 4.0 * BURN_ITERS as f64, "cycles of every thread: at least one per multiply of each");
    assert(dp > 0.0, "the threads' CPU time is accounted to the process");
    let ghz = dc / dp;
    assert(ghz > 0.2 && ghz < 10.0, "cycles and CPU time agree on a plausible clock");
}

// A counter that this platform lacks says so; one it has is positive.
@test
fn counters_state_their_availability() {
    let peak = unsafe sys::sc_bs_rss_peak();
    let now = unsafe sys::sc_bs_rss_now();
    assert(peak == -1 || peak > 0);
    assert(now == -1 || now > 0);
    let p0 = unsafe sys::sc_bs_cpu_ns();
    assert(p0 == -1 || p0 >= 0);
    if unsafe sys::sc_bs_alloc_supported() == 0 {
        unsafe sys::sc_bs_alloc_enable(1);
        assert_eq(unsafe sys::sc_bs_alloc_enabled(), 0);
        assert_eq(unsafe sys::sc_bs_alloc_calls(), 0);
    }
    assert(platform::stack_bytes() < 1usize << 40, "the stack counter reads a plausible size");
}

// The barrier: the multiply chain runs (no core does a dependent 64-bit multiply under a quarter of a
// nanosecond) and the sunk value is the one stored.
@test
fn optimisation_barrier_holds() {
    let n: i64 = 1 << 20;
    let t0 = platform::now_ns();
    let v = bench::burn(n);
    bench::black_box(v);
    let dt = (platform::now_ns() - t0) as f64 / n as f64;
    assert(dt >= 0.25, "burn runs at least 0.25 ns per iteration");
    assert_eq(unsafe sys::sc_bs_sunk(), v);
}

// The distribution: percentiles by rank over a sorted copy, p99 only from a hundred samples.
@test
fn summary_percentiles() {
    let mut v = Vector::<f64>::new();
    let mut i: i64 = 100;
    while i >= 1 {
        v.push(i as f64);
        i = i - 1;
    }
    let sm = bench::summarize(&mut v);
    assert_eq(sm.n, 100usize);
    assert_eq(sm.min, 1.0);
    assert_eq(sm.median, 50.5);
    assert_eq(sm.p95, 95.0);
    assert_eq(sm.p99, 99.0);
    assert_eq(sm.mean, 50.5);
    let mut w = Vector::<f64>::new();
    for k in 0..10 {
        w.push(k as f64);
    }
    let sw = bench::summarize(&mut w);
    assert_eq(sw.p99, 0.0);
    assert_eq(sw.p95, 9.0);
}
