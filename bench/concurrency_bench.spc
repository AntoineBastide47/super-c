// The runtime at HIGH TASK COUNTS, in the shapes that stress different parts of it. Run with `super-c bench`
// (the bench profile: a benchmark built through the script path would compile at -O0 and measure nothing).
//
//   no_io       N tasks that only compute and yield      -> the scheduler alone: spawn, switch, run-queue, stealing
//   io_short    N tasks each making one short syscall    -> the blocking path when the call returns at once
//   io_durable  N tasks each writing a file durably      -> the blocking path when the call really waits
//   mixed       half compute, half short syscall         -> whether the two interfere, which neither lane shows
//
// The two I/O shapes are kept as separate tests because they measure different things. A syscall that returns
// in a microsecond (ten bytes from /dev/urandom to /dev/null) gives the runtime nothing to schedule around, so
// it measures the hand-off itself; a durable write waits on the device, so it measures how the runtime keeps
// the rest of the program moving meanwhile. The durable workload is byte for byte the one bench/compare runs
// against Go, Rust threads and tokio.
//
// Every task VALIDATES its work (bytes read and written, the durability call, every close) and reports one
// success; a round whose successes fall short of its tasks fails the run. A syscall that fails is a failed
// benchmark, never a faster one.

import stdio;
import stdlib;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::blocking as blocking;
import std::parallel::atomics as atomics;
import std::parallel::arc as arc;
import std::testing::bench as bench;
import driver_shim as dshim;

import fcntl;
import unistd;

const TASKS: i64 = 1000; // concurrent tasks per round, as in the comparison benchmark
const YIELDS: i64 = 10; // how many times a compute task hands the worker back
const DURABLE_TASKS: i64 = 100; // durable writes per round: each waits on the device, so a round is long
const DURABLE_ROUNDS: i32 = 20; // samples for the durable lane (its rounds are hundreds of milliseconds)
const PAYLOAD: usize = 4096; // bytes each durable task writes, identical in every compared lane

// A compute task: some arithmetic and a yield, so the scheduler has to move it around rather than running
// it to completion the moment it starts. The result reaches the barrier, so the arithmetic is performed.
fn compute_task(rounds: i64) i64 {
    let mut acc: u64 = 1;
    for i in 0..rounds {
        acc = acc * 6364136223846793005 + i as u64;
        rt::yield_now();
    }
    bench::black_box(acc);
    return 1;
}

// The short syscall: read 10 bytes from /dev/urandom, write them to /dev/null. Success is every step
// succeeding with the full count; anything else is 0.
fn io_short_unit() i64 {
    let mut buf = Array::<char, 16>::new();
    let src = unsafe fcntl::open("/dev/urandom".ptr() as *const char, fcntl::O_RDONLY);
    if src < 0 {
        return 0;
    }
    let n = unsafe unistd::read(src, &mut buf[0], 10);
    let c1 = unsafe unistd::close(src);
    let dst = unsafe fcntl::open("/dev/null".ptr() as *const char, fcntl::O_WRONLY);
    if dst < 0 {
        return 0;
    }
    let w = unsafe unistd::write(dst, &buf[0], 10);
    let c2 = unsafe unistd::close(dst);
    return if n == 10 && w == 10 && c1 == 0 && c2 == 0 {
        1i64;
    } else {
        0i64;
    };
}

fn io_short_task() i64 {
    return blocking::call(
        fn() i64 {
            return io_short_unit();
        },
    );
}

// Durability, matching what the compared lanes' standard libraries do. On macOS `fsync` only pushes to the
// DEVICE CACHE and returns; Go's File.Sync and Rust's sync_all both issue F_FULLFSYNC (51, part of the
// macOS ABI since the call existed) instead, which is the real barrier.
@platform(macos)
fn durable(fd: i32) i32 {
    return unsafe fcntl::fcntl(fd, 51);
}

@platform(!macos)
fn durable(fd: i32) i32 {
    return unsafe unistd::fsync(fd);
}

// The directory the durable lane writes into: created by this process under the temporary directory,
// unique by pid, removed by this process. Read by every task, so it lives in static storage the lane
// fills first (a `str` view of that storage is `'static`, which the task closures require).
type DirBuf = Array<char, 1024>;
static mut G_DIR_BUF: DirBuf = DirBuf {};
static mut G_DIR: str<'static> = "";

@platform(macos | linux)
fn dir_setup(name: str) bool {
    let mut d = String::from_str(str::from_cstr(unsafe dshim::sc_tmpdir()));
    d.push_str("/sc-bench-");
    d.push_str(name);
    d.push_byte(b'-');
    d.push_i64(unsafe dshim::sc_getpid());
    if d.len() >= 1024 || unsafe dshim::sc_mkdir_p(d.cstr()) != 0 {
        let mut what = String::from_str("cannot create ");
        what.push_string(&d);
        bench::fail(what.as_str());
        return false;
    }
    unsafe {
        G_DIR_BUF.copy_from(d.as_str().ptr(), d.len());
        G_DIR = str::from_raw((&G_DIR_BUF[0]) as *const u8, d.len());
    }
    return true;
}

@platform(macos | linux)
fn dir_teardown() {
    let mut d = String::from_str(unsafe G_DIR);
    let _ = unsafe dshim::sc_rm_rf(d.cstr());
}

// One durable unit, identical in every compared lane: create a file, write PAYLOAD zero bytes, make it
// durable, close. Success is every call succeeding with the full count.
fn io_durable_unit(id: i64) i64 {
    let mut path = String::from_str(unsafe G_DIR);
    path.push_str("/f");
    path.push_i64(id);
    let buf = Array::<char, PAYLOAD>::new();
    let flags = fcntl::O_WRONLY | fcntl::O_CREAT | fcntl::O_TRUNC;
    let fd = unsafe fcntl::open(path.cstr(), flags, 420);
    if fd < 0 {
        return 0;
    }
    let w = unsafe unistd::write(fd, &buf[0], PAYLOAD);
    let d = durable(fd);
    let c = unsafe unistd::close(fd);
    return if w == PAYLOAD as isize && d == 0 && c == 0 {
        1i64;
    } else {
        0i64;
    };
}

// One round: spawn `tasks` tasks, `io_share` out of every 4 doing the short syscall (0 = none, 4 = all,
// 2 = half), wait for all of them, and report how many validated their work.
fn one_round(tasks: i64, io_share: i64, durable_lane: bool) i64 {
    let wg = sync::WaitGroup::new();
    wg.add(tasks);
    let oks = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    for i in 0..tasks {
        let w = wg.clone();
        let o = oks.clone();
        let does_io = i % 4 < io_share;
        let id = i;
        launch || {
            let ok = if durable_lane {
                blocking::call(
                    fn() i64 {
                        return io_durable_unit(id);
                    },
                );
            } else if does_io {
                io_short_task();
            } else {
                compute_task(YIELDS);
            };
            let _ = o.get().fetch_add(ok, atomics::MemoryOrder::Relaxed);
            w.done();
        };
    }
    wg.wait();
    return oks.get().load(atomics::MemoryOrder::Acquire);
}

fn run_lane(b: &mut bench::Bencher, io_share: i64) {
    b.each(TASKS);
    b.unit("task");
    while b.running() {
        let ok = one_round(TASKS, io_share, false);
        b.tally(TASKS, ok);
    }
}

@bench
/// Benchmark lane: compute-only tasks.
pub fn no_io(b: &mut bench::Bencher) {
    run_lane(b, 0);
}

// /dev/urandom and F_FULLFSYNC are POSIX: there is nothing on Windows to hold the same number against, so
// these lanes measure nothing there rather than measuring a different thing.
@platform(macos | linux)
@bench
/// Benchmark lane: tasks that each make one short blocking syscall.
pub fn io_short(b: &mut bench::Bencher) {
    run_lane(b, 4);
}

@platform(macos | linux)
@bench
/// Benchmark lane: half compute, half short syscall.
pub fn mixed(b: &mut bench::Bencher) {
    run_lane(b, 2);
}

@platform(macos | linux)
@bench
/// Benchmark lane: tasks that each write a file durably through the blocking pool.
pub fn io_durable(b: &mut bench::Bencher) {
    if !dir_setup("durable") {
        return;
    }
    b.each(DURABLE_TASKS);
    b.unit("task");
    b.set_rounds(DURABLE_ROUNDS);
    let mut note = String::from_str("concurrency limit ");
    note.push_u64(blocking::MAX_THREADS as u64);
    note.push_str(" blocking threads");
    b.note(note.as_str());
    while b.running() {
        let ok = one_round(DURABLE_TASKS, 4, true);
        b.tally(DURABLE_TASKS, ok);
    }
    dir_teardown();
}
