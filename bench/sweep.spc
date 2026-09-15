// The worker-count sweep the whole-workload benchmarks share: a FIXED workload measured at 1, 2, 4, 8 and
// every worker, one distribution per point. A pool's size is fixed once it starts, but `shutdown` releases
// it and `set_worker_count` is honoured by the next one, so each point tears the pool down and builds a new
// one. Every sweep restores the default (`set_worker_count(0)`) before returning, or every benchmark
// scheduled after it would silently inherit a one-worker pool.
//
// A point is `POINT_ROUNDS` samples after one warm round, described as a distribution (a best-of-N figure
// reports the one round the machine was quietest, which is not what the runtime costs). Beside the wall
// time each point carries the CPU cycles every thread spent per round and the process CPU time, so a
// speedup that comes from burning more cores shows as such.

import stdio;
import std::parallel::runtime as rt;
import std::parallel::platform as platform;
import std::testing::bench as bench;
import std::testing::bench_sys as sys;

/// Samples per sweep point.
pub const POINT_ROUNDS: i32 = 20;
const UNAVAILABLE: f64 = -1.0; // a figure whose counter this platform lacks

/// One measured point: the wall-time distribution, and the per-round medians of cycles and CPU time
/// (negative when the counter is unavailable).
pub struct Point {
    pub ms: bench::Summary,
    pub mcyc: f64,
    pub cpu_ms: f64,
}

/// Run `body` once to warm, then `rounds` times, and describe the rounds.
pub fn measure(body: fn() void, rounds: i32) Point {
    body();
    let mut ms = Vector::<f64>::with_capacity(rounds as usize);
    let mut cyc = Vector::<f64>::with_capacity(rounds as usize);
    let mut cpu = Vector::<f64>::with_capacity(rounds as usize);
    let have_cyc = unsafe sys::sc_bs_cycles_scope() != 0;
    for _r in 0..rounds {
        let c0 = unsafe sys::sc_bs_cycles();
        let p0 = unsafe sys::sc_bs_cpu_ns();
        let t0 = platform::now_ns();
        body();
        let t1 = platform::now_ns();
        let p1 = unsafe sys::sc_bs_cpu_ns();
        let c1 = unsafe sys::sc_bs_cycles();
        ms.push((t1 - t0) as f64 / 1000000.0);
        if have_cyc {
            cyc.push((c1 - c0) as f64 / 1000000.0);
        }
        if p0 >= 0 && p1 >= 0 {
            cpu.push((p1 - p0) as f64 / 1000000.0);
        }
    }
    let sm = bench::summarize(&mut ms);
    let mut mcyc: f64 = UNAVAILABLE;
    if cyc.len() != 0 {
        mcyc = bench::summarize(&mut cyc).median;
    }
    let mut cpu_ms: f64 = UNAVAILABLE;
    if cpu.len() != 0 {
        cpu_ms = bench::summarize(&mut cpu).median;
    }
    return Point { ms: sm, mcyc: mcyc, cpu_ms: cpu_ms };
}

/// Print the header of a sweep table.
pub fn header(name: str, what: str) {
    unsafe stdio::printf("\n  %s: %s\n".ptr() as *const char, name.ptr() as *const char, what.ptr() as *const char);
    unsafe stdio::printf(
        "    %-9s %10s %10s %10s %9s %10s %10s\n".ptr() as *const char,
        "workers".ptr() as *const char,
        "median ms".ptr() as *const char,
        "p95 ms".ptr() as *const char,
        "min ms".ptr() as *const char,
        "speedup".ptr() as *const char,
        "Mcyc".ptr() as *const char,
        "cpu ms".ptr() as *const char,
    );
}

/// Print one row of a sweep table and log its record. `label` is the row's first column (a worker
/// count, or whatever the sweep varies); `base` is the median the speedup is against.
pub fn row(name: str, label: i64, p: &Point, base: f64) {
    unsafe stdio::printf(
        "    %-9lld %10.3f %10.3f %10.3f %8.2fx %10.2f %10.3f\n".ptr() as *const char,
        label,
        p.ms.median,
        p.ms.p95,
        p.ms.min,
        base / p.ms.median,
        p.mcyc,
        p.cpu_ms,
    );
    let mut js = String::with_capacity(512);
    js.push_str("{\"v\":1,\"name\":");
    bench::json_str(&mut js, name);
    bench::json_identity(&mut js);
    js.push_str(",\"point\":");
    js.push_i64(label);
    js.push_str(",\"rounds\":");
    js.push_u64(p.ms.n as u64);
    bench::json_dist(&mut js, "ms", &p.ms, 1.0);
    js.push_str(",\"speedup\":");
    js.push_f64_prec(base / p.ms.median, 3);
    js.push_str(",\"mcyc_per_round\":");
    js.push_f64_prec(p.mcyc, 3);
    js.push_str(",\"cpu_ms_per_round\":");
    js.push_f64_prec(p.cpu_ms, 3);
    js.push_byte(b'}');
    bench::log_line(js.as_str());
}

/// Run `body` at each worker count and print a row per point. `body` must leave no task running: the pool
/// is torn down between points.
pub fn sweep(name: str, body: fn() void) {
    header(name, "fixed workload, varying workers");
    let ncpu = platform::ncpu();
    let mut counts = Array::<usize, 5>::new();
    counts[0] = 1;
    counts[1] = 2;
    counts[2] = 4;
    counts[3] = 8;
    counts[4] = ncpu;
    let mut base: f64 = 0.0;
    for k in 0..5usize {
        let n = counts[k];
        if k > 0 && n <= counts[k - 1] {
            // A machine with few cores: skip a point the sweep already covered.
            continue;
        }
        rt::shutdown(); // release the previous pool so the next size is honoured
        rt::set_worker_count(n);
        let p = measure(body, POINT_ROUNDS);
        if k == 0 {
            base = p.ms.median;
        }
        row(name, n as i64, &p, base);
    }
    rt::shutdown();
    rt::set_worker_count(0); // back to one worker per CPU for whatever runs next
}
