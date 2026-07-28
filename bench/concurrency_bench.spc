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
import std::testing::bench as bench;

import fcntl;
import unistd;

const TASKS: i64 = 1000; // concurrent tasks per iteration, as in the comparison benchmark
const ITERS: i32 = 20; // iterations per lane (the comparison runs 1000; 20 keeps `bench` interactive)
const YIELDS: i64 = 10; // how many times a compute task hands the worker back

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

// One lane, driven by the Bencher: it owns the warm-up, the repetition and the statistics, so a lane here
// is just "what one round does" plus the two facts the timings alone would not carry -- how many tasks a
// round runs, and how many allocations each one cost.
fn run_lane(b: &mut bench::Bencher, io_share: i64) {
    b.each(TASKS);
    b.unit("task");
    b.set_rounds(ITERS);
    let a0 = unsafe shim::sc_alloc_count();
    let mut rounds: i64 = 0;
    while b.running() {
        let _ = one_iteration(io_share);
        rounds = rounds + 1;
    }
    let allocs = (unsafe shim::sc_alloc_count() - a0) / (rounds * TASKS);
    let mut note = String::new();
    note.push_i64(allocs);
    note.push_str(" alloc/task");
    b.note(note.as_str());
    note.free();
}

@bench
pub fn no_io(b: &mut bench::Bencher) {
    run_lane(b, 0);
}

// The workload is the comparison set's, and /dev/urandom is POSIX: there is nothing on Windows to hold the
// same number against, so these two lanes measure nothing there rather than measuring a different thing.
@platform(macos | linux)
@bench
pub fn io_only(b: &mut bench::Bencher) {
    run_lane(b, 4);
}

@platform(macos | linux)
@bench
pub fn mixed(b: &mut bench::Bencher) {
    run_lane(b, 2);
}
