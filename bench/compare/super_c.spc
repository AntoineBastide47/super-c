// Super-C's two answers to a blocking syscall, measured against Go, Rust threads and tokio (see README.md).
//
//   MODE=blocking  `blocking::call` -- the closure is MOVED to a pool of plain threads while the coroutine
//                  parks. Our equivalent of tokio's spawn_blocking, and what the runtime does today.
//   MODE=direct    the coroutine makes the syscall itself, holding its worker for the duration. What Go
//                  looks like WITHOUT the handoff, so the gap between the two is what a handoff would buy.
//
// Build it through the release profile, never `super-c build <file>`: the script path compiles the emitted C
// with no -O flag, and an unoptimised number here would be worse than no number.

import stdlib;
import stdio;
import fcntl;
import unistd;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::blocking as blocking;
import std::parallel::platform as platform;

// One unit of work, identical in every lane: create a file, write 4 KiB, FSYNC it, close. The fsync is the
// whole point -- a page-cache write returns in nanoseconds and says nothing about how a runtime handles a
// blocking call, while this waits on the device. The original workload read /dev/urandom, which turned out
// not to block enough to separate `spawn_blocking` from `block_in_place` at all: they measured identical.
// Durability, matching what the other lanes' standard libraries do. On macOS `fsync` only pushes to the
// DEVICE CACHE and returns; Go's File.Sync and Rust's sync_all both issue F_FULLFSYNC instead, which is the
// real barrier. Using plain fsync here would have made this lane look fast by doing less work.
@platform(macos)
fn durable(fd: i32) i32 {
    // F_FULLFSYNC, spelled numerically because it is a macro and this is the only place we need it. It is
    // part of the macOS ABI and has been 51 since the call existed.
    return unsafe fcntl::fcntl(fd, 51);
}

@platform(linux | windows)
fn durable(fd: i32) i32 {
    return unsafe unistd::fsync(fd);
}

// A fixed directory rather than an env var: the closure handed to `blocking::call` must be Send + 'static,
// and a `str` from getenv carries a lifetime that is neither. run.sh creates and clears it.
const DIR: str = "/tmp/sc-compare";

fn unit(id: i64) i64 {
    let mut path = String::from_str(DIR);
    path.push_str("/f");
    path.push_i64(id);
    let mut buf = Array::<char, 4096>::new();
    buf[0] = 'x' as char;
    let flags = fcntl::O_WRONLY | fcntl::O_CREAT | fcntl::O_TRUNC;
    let fd = unsafe fcntl::open(path.cstr(), flags, 420);
    if fd < 0 {
        return 0;
    }
    let w = unsafe unistd::write(fd, &buf[0], 4096);
    let _ = durable(fd); // wait for the device, not the page cache
    let _ = unsafe unistd::close(fd);
    return w as i64;
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
    let iters = env_int("ITERS", 20);
    let tasks = env_int("TASKS", 1000);
    let direct = env_is("MODE", "direct");
    let t0 = platform::now_ns();
    for _i in 0..iters {
        let wg = sync::WaitGroup::new();
        wg.add(tasks);
        for _t in 0..tasks {
            let w = wg.clone();
            let id = _t;
            launch || {
                if direct {
                    let _ = unit(id); // on the worker: this task holds it for the whole syscall
                } else {
                    let _ = blocking::call(
                        fn() i64 {
                            return unit(id);
                        },
                    );
                }
                w.done();
            };
        }
        wg.wait();
        wg.free();
    }
    let dt = (platform::now_ns() - t0) as f64;
    unsafe stdio::printf("%.1f %.0f\n".ptr() as *const char, dt / 1000000.0 / iters as f64, dt / (iters * tasks) as f64);
    rt::shutdown();
    return 0;
}
