// The concurrency stack, end to end, in one program: what CI runs on every platform to prove the runtime
// works there and not just that it compiles. It is deliberately free of anything POSIX-only (no reactor, no
// sockets), because its whole job is to be the same test on Linux, macOS and Windows -- the three legs of
// `ffi/sc_rt.c` are OS threads, locks and context switches, and every one of them is exercised below.
//
// Build and run it with the compiler under test:
//     super-c build ci/parallel_smoke.spc -o smoke && ./smoke
// Exit code 0 means every check passed; anything else is the number of the check that failed, so a CI log
// names the failure without needing the program's output.

import std::parallel::runtime as rt;
import std::parallel::thread as thread;
import std::parallel::sync as sync;
import std::parallel::channel as chan;
import std::parallel::selector as selector;
import std::parallel::data as parallel;
import std::parallel::time as time;
import std::parallel::arc as arc;
import std::parallel::atomics as atomics;
import std::parallel::platform as platform;

const NTASKS: i64 = 32;
const NITEMS: i64 = 500;

// 1. OS threads: four of them, each returning a value through its join handle. This is the one check that
// does not touch the coroutine scheduler at all -- just thread create/join and the value hand-back.
fn check_threads() i32 {
    let mut handles = Vector::<thread::JoinHandle<i64>>::new();
    for i in 0..4 {
        let n = i as i64;
        handles.push(
            thread::spawn(
                fn() i64 {
                    let mut acc: i64 = 0;
                    for k in 0..1000 {
                        acc = acc + n * k as i64;
                    }
                    return acc;
                },
            ),
        );
    }
    let mut total: i64 = 0;
    while handles.len() > 0 {
        let h = handles.pop().unwrap();
        total = total + h.join();
    }
    handles.free();
    // sum over n in 0..3 of n * (0+..+999) = 6 * 499500
    if total != 2997000 {
        return 1;
    }
    return 0;
}

// 2. Shared state across OS threads: an Arc'd mutex and an atomic counter, hammered by every thread.
fn check_shared_state() i32 {
    let guarded = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let counter = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let mut handles = Vector::<thread::JoinHandle<i32>>::new();
    for _i in 0..4 {
        let g = guarded.clone();
        let c = counter.clone();
        handles.push(
            thread::spawn(
                fn() i32 {
                    for _k in 0..1000 {
                        {
                            let mut lk = g.get().lock();
                            let v = lk.get_mut();
                            *v = *v + 1;
                        }
                        let _ = c.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
                    }
                    return 0;
                },
            ),
        );
    }
    while handles.len() > 0 {
        let h = handles.pop().unwrap();
        let _ = h.join();
    }
    handles.free();
    let mut locked: i64 = 0;
    {
        let lk = guarded.get().lock();
        locked = *lk.get();
    }
    let atomic = counter.get().load(atomics::MemoryOrder::SeqCst);
    guarded.free();
    counter.free();
    if locked != 4000 {
        return 2;
    }
    if atomic != 4000 {
        return 3;
    }
    return 0;
}

// 3. Coroutines: `launch` across the worker pool, each task parking on a channel it feeds itself, with a
// WaitGroup to join them. This is the context switch (ucontext / fibers) plus the task-aware wait queues.
fn check_coroutines() i32 {
    let ch = chan::Channel::<i64>::bounded(8);
    let rx = ch.receiver();
    let tx = ch.sender();
    ch.free();
    let wg = sync::WaitGroup::new();
    wg.add(32);
    for i in 0..NTASKS {
        let t = tx.clone();
        let w = wg.clone();
        let n = i;
        launch || {
            for k in 0..NITEMS {
                let _ = t.send(n + k);
            }
            w.done();
        };
    }
    let mut got: i64 = 0;
    let mut sum: i64 = 0;
    while got < NTASKS * NITEMS {
        switch rx.recv_timeout(time::Duration::from_secs(120)) {
            Some(v) => {
                sum = sum + v;
                got = got + 1;
            },
            None => {
                break;
            },
        };
    }
    let joined = wg.wait_timeout(time::Duration::from_secs(120));
    tx.free();
    rx.free();
    wg.free();
    if !joined {
        return 4;
    }
    // sum over tasks n of sum over k of (n + k)
    let per_task = NITEMS * (NITEMS - 1) / 2;
    if sum != NTASKS * per_task + NITEMS * (NTASKS * (NTASKS - 1) / 2) {
        return 5;
    }
    return 0;
}

// 4. Multi-way waiting: a selector parked on two channels, woken by whichever moves, plus the `select`
// keyword over the same pair. Both the library layer and the sugar it lowers to.
fn check_select() i32 {
    let a = chan::Channel::<i64>::bounded(4);
    let arx = a.receiver();
    let atx = a.sender();
    a.free();
    let b = chan::Channel::<i64>::bounded(4);
    let brx = b.receiver();
    let btx = b.sender();
    b.free();

    let _ = btx.send(7);
    let mut s = selector::Selector::new();
    let _ = s.arm_recv(&arx);
    let bi = s.arm_recv(&brx);
    let mut rc: i32 = 0;
    switch s.wait_timeout(time::Duration::from_secs(120)) {
        Ready(i) => {
            if i != bi || brx.try_recv().unwrap_or(-1) != 7 {
                rc = 6;
            }
        },
        TimedOut => {
            rc = 7;
        },
    };

    // The keyword, with the value arriving 50ms late so the select really parks.
    let wg = sync::WaitGroup::new();
    wg.add(1);
    {
        let t = atx.clone();
        let w = wg.clone();
        launch || {
            time::sleep(time::Duration::from_millis(50));
            let _ = t.send(11);
            w.done();
        };
    }
    let mut hit: i64 = -1;
    select {
        v = arx.recv() => {
            hit = v.unwrap_or(-1);
        }
        brx.recv() => {
            hit = -2;
        }
        timeout(time::Duration::from_secs(120)) => {
            hit = -3;
        }
    }
    let joined = wg.wait_timeout(time::Duration::from_secs(120));
    atx.free();
    arx.free();
    btx.free();
    brx.free();
    wg.free();
    if rc != 0 {
        return rc;
    }
    if !joined {
        return 8;
    }
    if hit != 11 {
        return 9;
    }
    return 0;
}

// 5. Data parallelism: the chunked API over a real array, mutating in place and reducing. Chunks run as
// stackless jobs on the same pool, so this also proves the pool is usable from a plain thread.
fn check_data_parallel() i32 {
    let n: usize = 5000;
    let mut v = Vector::<i64>::new();
    for i in 0..n {
        v.push(i as i64);
    }
    parallel::each_mut(
        v.index_range_mut(0..n),
        |x: &mut i64| {
            *x = *x * 2;
        },
    );
    let total = parallel::reduce(
        v[0..n],
        fn() i64 {
            return 0;
        },
        fn(a: i64, x: &i64) i64 {
            return a + *x;
        },
        fn(a: i64, b: i64) i64 {
            return a + b;
        },
    );
    v.free();
    // 2 * (0 + .. + 4999)
    if total != 24995000 {
        return 10;
    }
    return 0;
}

// 6. Timers: a sleep must actually sleep (the monotonic clock and the scheduler's timer list agree).
fn check_timers() i32 {
    let t0 = platform::now_ns();
    time::sleep(time::Duration::from_millis(50));
    if platform::now_ns() - t0 < 40000000 {
        return 11;
    }
    return 0;
}

fn main() i32 {
    let mut rc = check_threads();
    if rc == 0 {
        rc = check_shared_state();
    }
    if rc == 0 {
        rc = check_coroutines();
    }
    if rc == 0 {
        rc = check_select();
    }
    if rc == 0 {
        rc = check_data_parallel();
    }
    if rc == 0 {
        rc = check_timers();
    }
    rt::shutdown();
    return rc;
}
