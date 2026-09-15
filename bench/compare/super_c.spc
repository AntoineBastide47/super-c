// Super-C's two answers to a blocking syscall, measured against Go, Rust threads and tokio (see README.md).
//
//   MODE=blocking  `blocking::call`; the closure is MOVED to a pool of plain threads while the coroutine
//                  parks. Our equivalent of tokio's spawn_blocking, and what the runtime does today.
//   MODE=direct    the coroutine makes the syscall itself, holding its worker for the duration. What Go
//                  looks like WITHOUT the handoff, so the gap between the two is what a handoff would buy.
//
// Build it through the release profile, never `super-c build <file>`: the script path compiles the emitted C
// with no -O flag, and an unoptimised number here would be worse than no number.
//
// The protocol every lane follows: `ITERS` iterations of `TASKS` units each; a counting semaphore of
// `LIMIT` permits (default 64, the Super-C blocking pool's thread limit) bounds how many units block at
// once; the first iteration is reported apart as the cold one (it pays for the runtime's start) and the
// rest as a distribution; every unit validates its calls and the run exits nonzero when any fell short;
// the files go under `$SC_COMPARE_DIR`, a directory the script creates for this lane alone; the runtime
// pools are shut down explicitly before the report.

import stdlib;
import stdio;
import fcntl;
import unistd;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::blocking as blocking;
import std::parallel::atomics as atomics;
import std::parallel::arc as arc;
import std::parallel::platform as platform;
import std::testing::bench as bench;

const PAYLOAD: usize = 4096; // the identical payload of every lane: 4 KiB of zeros

// Durability, matching what the other lanes' standard libraries do. On macOS `fsync` only pushes to the
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

// The lane's directory, from the environment into static storage: the task closures must be `'static`.
type DirBuf = Array<char, 1024>;
static mut G_DIR_BUF: DirBuf = DirBuf {};
static mut G_DIR: str<'static> = "";

fn dir_setup() bool {
    let v = stdlib::getenv("SC_COMPARE_DIR");
    if v == null {
        return false;
    }
    let d = str::from_cstr(v);
    if d.len() == 0 || d.len() >= 1024 {
        return false;
    }
    unsafe {
        G_DIR_BUF.copy_from(d.ptr(), d.len());
        G_DIR = str::from_raw((&G_DIR_BUF[0]) as *const u8, d.len());
    }
    return true;
}

// One unit of work: create a file, write PAYLOAD zero bytes, make it durable, close. 1 when every call
// succeeded with the full count, else 0.
fn unit(id: i64) i64 {
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

fn env_int(name: str, def: i64) i64 {
    let v = stdlib::getenv(name);
    if v == null {
        return def;
    }
    let got = (unsafe stdlib::atoi(v)) as i64;
    return if got > 0 {
        got;
    } else {
        def;
    };
}

fn env_is(name: str, want: str) bool {
    let v = stdlib::getenv(name);
    if v == null {
        return false;
    }
    return str::from_cstr(v) == want;
}

fn main() i32 {
    let iters = env_int("ITERS", 5);
    let tasks = env_int("TASKS", 1000);
    let limit = env_int("LIMIT", blocking::MAX_THREADS as i64);
    let direct = env_is("MODE", "direct");
    if !dir_setup() {
        eprintln("super-c: SC_COMPARE_DIR is not set");
        return 2;
    }
    // The effective limit of the direct lane is also the worker count: a unit holds its worker.
    let effective = if direct && rt::worker_count() as i64 < limit {
        rt::worker_count() as i64;
    } else {
        limit;
    };
    let sem = sync::Semaphore::new(limit);
    let ok = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let mut samples = Vector::<f64>::with_capacity(iters as usize);
    for _i in 0..iters {
        let t0 = platform::now_ns();
        let wg = sync::WaitGroup::new();
        wg.add(tasks);
        for t in 0..tasks {
            let w = wg.clone();
            let s = sem.clone();
            let o = ok.clone();
            let id = t;
            launch || {
                s.acquire();
                let r = if direct {
                    unit(id); // on the worker: this task holds it for the whole syscall
                } else {
                    blocking::call(
                        fn() i64 {
                            return unit(id);
                        },
                    );
                };
                s.release();
                let _ = o.get().fetch_add(r, atomics::MemoryOrder::Relaxed);
                w.done();
            };
        }
        wg.wait();
        samples.push((platform::now_ns() - t0) as f64 / 1000000.0);
    }
    blocking::shutdown();
    rt::shutdown();
    // cold_ms median_ms p95_ms ns_per_op ok total limit: the first iteration apart, the distribution
    // of the rest, and the validated work.
    let cold = samples[0];
    let mut rest = Vector::<f64>::new();
    let from = if samples.len() > 1 {
        1usize;
    } else {
        0usize;
    };
    for i in from..samples.len() {
        rest.push(samples[i]);
    }
    let sm = bench::summarize(&mut rest);
    let done = ok.get().load(atomics::MemoryOrder::Acquire);
    unsafe stdio::printf(
        "%.1f %.1f %.1f %.0f %lld %lld %lld\n".ptr() as *const char,
        cold,
        sm.median,
        sm.p95,
        sm.median * 1000000.0 / tasks as f64,
        done,
        iters * tasks,
        effective,
    );
    return if done == iters * tasks {
        0;
    } else {
        1;
    };
}
