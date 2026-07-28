// M7's concurrency lanes: what the runtime costs at HIGH TASK COUNTS, in the three shapes that stress
// different parts of it. Run with `super-c bench` (the bench profile, -O2 -flto -- a benchmark built through
// the script path would compile at -O0 and measure nothing).
//
//   no-io    N tasks that only compute and yield  -> the scheduler alone: spawn, switch, run-queue, stealing
//   io-only  N tasks that only do blocking I/O    -> the blocking path: how a task that leaves the CPU behaves
//   mixed    half of each, interleaved            -> whether the two interfere, which neither lane can show
//
// The io-only lane is deliberately the SAME workload as the cross-language comparison this milestone is
// built around (each task reads 10 bytes from /dev/urandom and writes them to /dev/null), so our number can
// be put next to Go's goroutines, Rust's OS threads, tokio's spawn_blocking and tokio's block_in_place
// without arguing about what was measured. `block_in_place` is the interesting one: it does not move the
// closure to a pool, it moves the OTHER tasks off the worker and blocks in place -- the strategy Go uses for
// blocking syscalls, and the one we would have to adopt to close that lane.
//
// Every lane reports the same distribution as the transpile bench, plus allocations and peak RSS: for a task
// runtime the allocation count per task is usually the story, and a latency number alone hides it.

import stdio;
import math;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::blocking as blocking;
import std::parallel::platform as platform;
import bench::bench_shim as shim;

import fcntl;
import unistd;

const TASKS: i64 = 1000; // concurrent tasks per iteration, as in the comparison benchmark
const ITERS: i32 = 20; // iterations per lane (the comparison runs 1000; 20 keeps `bench` interactive)
const YIELDS: i64 = 10; // how many times a compute task hands the worker back

/// One lane's timing sample, in seconds.
pub struct Sample {
    pub secs: f64,
    pub allocs: i64,
}

// A compute task: touch some memory and yield, so the scheduler actually has to move it around rather than
// running it to completion the moment it starts.
fn compute_task(rounds: i64) i64 {
    let mut acc: i64 = 0;
    for i in 0..rounds {
        acc = acc + i * 2654435761;
        rt::yield_now();
    }
    return acc;
}

// A blocking-I/O task, byte for byte the workload the comparison set runs.
fn io_task() i64 {
    return blocking::call(
        fn() i64 {
            let mut buf = Array::<char, 16>::new();
            let src = unsafe fcntl::open("/dev/urandom".ptr() as *const char, 0);
            if src < 0 {
                return 0;
            }
            let n = unsafe unistd::read(src, &mut buf[0], 10);
            let _ = unsafe unistd::close(src);
            let dst = unsafe fcntl::open("/dev/null".ptr() as *const char, 1);
            if dst < 0 {
                return 0;
            }
            let want = if n > 0 {
                n as usize;
            } else {
                0 as usize;
            };
            let w = unsafe unistd::write(dst, &buf[0], want);
            let _ = unsafe unistd::close(dst);
            return w as i64;
        },
    );
}

// The workload is the comparison set's, and /dev/urandom is POSIX: there is nothing on Windows to hold the
// same number against, so the lane is skipped rather than measured against a different thing.
@platform(macos | linux)
fn io_available() bool {
    return true;
}

@platform(windows)
fn io_available() bool {
    return false;
}

// One iteration of a lane: spawn TASKS tasks, wait for all of them. `io_share` out of every 4 tasks do I/O,
// so 0 = no-io, 4 = io-only, 2 = mixed.
fn one_iteration(io_share: i64) f64 {
    let wg = sync::WaitGroup::new();
    wg.add(TASKS);
    let t0 = platform::now_ns();
    for i in 0..TASKS {
        let w = wg.clone();
        let does_io = i % 4 < io_share;
        launch || {
            if does_io {
                let _ = io_task();
            } else {
                let _ = compute_task(YIELDS);
            }
            w.done();
        };
    }
    wg.wait();
    let dt = (platform::now_ns() - t0) as f64 / 1000000000.0;
    wg.free();
    return dt;
}

fn run_lane(name: str, io_share: i64, out: &mut Vector<f64>) {
    let a0 = unsafe shim::sc_alloc_count();
    let _ = one_iteration(io_share); // warm: the pool starts, the first stacks are faulted in
    for _i in 0..ITERS {
        out.push(one_iteration(io_share));
    }
    let allocs = (unsafe shim::sc_alloc_count() - a0) / ((ITERS as i64 + 1) * TASKS);
    dist_line(name, out, allocs);
}

fn sort_f64(v: &mut Vector<f64>) {
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

// min/median/p95/stddev in ms, plus per-task cost and allocations per task -- the two numbers a task runtime
// is actually judged on.
fn dist_line(name: str, v: &mut Vector<f64>, allocs: i64) {
    let nn = v.len();
    if nn == 0 {
        return;
    }
    sort_f64(v);
    let mut med = v[nn / 2];
    if nn % 2 == 0 {
        med = (v[nn / 2 - 1] + v[nn / 2]) / 2.0;
    }
    let p95 = v[(nn * 95 + 99) / 100 - 1];
    let mut sum: f64 = 0.0;
    for q in 0..nn {
        sum = sum + v[q];
    }
    let mean = sum / nn as f64;
    let mut var: f64 = 0.0;
    for q in 0..nn {
        let d = v[q] - mean;
        var = var + d * d;
    }
    let sd = unsafe math::sqrt(var / nn as f64);
    unsafe stdio::printf(
        "  %-10s min %7.2f | median %7.2f | p95 %7.2f | sd %6.2f ms  |  %7.0f ns/task  | %lld alloc/task\n".ptr() as *const char,
        name.ptr() as *const char,
        v[0] * 1000.0,
        med * 1000.0,
        p95 * 1000.0,
        sd * 1000.0,
        med * 1000000000.0 / TASKS as f64,
        allocs,
    );
}

pub fn run() i32 {
    let mut cpu = Array::<char, 256>::new();
    if unsafe shim::sc_cpu_model(&mut cpu[0], 256) != 0 {
        unsafe stdio::snprintf(&mut cpu[0], 256, "%s".ptr() as *const char, "unknown CPU".ptr() as *const char);
    }
    unsafe stdio::printf(
        "\nconcurrency: %lld tasks x %d iterations, %zu workers;  %s\n".ptr() as *const char,
        TASKS,
        ITERS,
        platform::ncpu(),
        (&cpu[0]) as *const char,
    );

    let mut no_io = Vector::<f64>::new();
    run_lane("no-io", 0, &mut no_io);
    no_io.free();

    if io_available() {
        let mut io_only = Vector::<f64>::new();
        run_lane("io-only", 4, &mut io_only);
        io_only.free();
        let mut mixed = Vector::<f64>::new();
        run_lane("mixed", 2, &mut mixed);
        mixed.free();
    } else {
        unsafe stdio::printf("  io-only    skipped (the comparison workload is /dev/urandom)\n".ptr() as *const char);
    }

    unsafe stdio::printf("  peak RSS %.1f MiB\n".ptr() as *const char, (unsafe shim::sc_peak_rss()) as f64 / 1048576.0);
    rt::shutdown();
    return 0;
}
