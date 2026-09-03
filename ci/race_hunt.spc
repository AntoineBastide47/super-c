// Every concurrency primitive, driven hard enough that a missing happens-before edge shows up, and run by
// `check.sh` under `--profile=race`. The gate's other program (`parallel_smoke.spc`) proves the substrate
// WORKS; this one exists to be hostile to it.
//
// Two groups. The first is the primitives the smoke program never touches. The second is the intricate
// paths: timed waits reaching the scheduler's timer list, `select` taking several locks at once and
// unwinding them, `close` landing while both ends are mid-operation, and OS threads sharing a mutex with
// coroutines. The second group is where the real find was: `Condvar::wait_raw` armed a timer, then re-took
// its lock, and re-taking could park AGAIN and rewrite the timer fields a worker was reading.
//
// Producers here are BOUNDED (`send_timeout`, not `send`). The consumers make a fixed number of timed
// attempts and most expire, so they exit having taken far fewer items than a producer has to give: and
// `send` will not report "no receivers" while this frame still holds one. An unbounded producer waits for
// room that never comes, which reads exactly like a runtime deadlock and is not one.

import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::arc as arc;
import std::parallel::channel as chan;
import std::parallel::selector as sel;
import std::parallel::thread as thread;
import std::parallel::data as data;
import std::parallel::atomics as atomics;
import std::parallel::blocking as blocking;
import std::parallel::time as time;

const TASKS: i64 = 8;
const ROUNDS: i64 = 60;

// 1. RwLock: many readers against a writer, which is the shape its writer-priority logic exists for.
fn hunt_rwlock() i64 {
    let l = arc::Arc::<sync::RwLock<i64>>::new(sync::RwLock::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(TASKS);
    for t in 0..TASKS {
        let h = l.clone();
        let w = wg.clone();
        let writer = t % 3 == 0;
        launch || {
            for _i in 0..ROUNDS {
                if writer {
                    let mut g = h.get().write();
                    let v = g.get_mut();
                    *v = *v + 1;
                } else {
                    let g = h.get().read();
                    let _ = *g.get();
                }
            }
            w.done();
        };
    }
    wg.wait();
    let g = l.get().read();
    let out = *g.get();
    return out;
}

// 2. Semaphore: permits taken and returned from every worker at once.
fn hunt_semaphore() {
    let s = sync::Semaphore::new(3);
    let wg = sync::WaitGroup::new();
    wg.add(TASKS);
    for _t in 0..TASKS {
        let sem = s.clone();
        let w = wg.clone();
        launch || {
            for _i in 0..ROUNDS {
                sem.acquire();
                sem.release();
            }
            w.done();
        };
    }
    wg.wait();
}

// 3. Barrier: reused across rounds, so the generation counter is what is really under test.
fn hunt_barrier() {
    let b = sync::Barrier::new(TASKS);
    let wg = sync::WaitGroup::new();
    wg.add(TASKS);
    for _t in 0..TASKS {
        let bar = b.clone();
        let w = wg.clone();
        launch || {
            for _i in 0..20 {
                bar.wait();
            }
            w.done();
        };
    }
    wg.wait();
}

// 4. Once: every task races to be the one initialiser, and all must see the result.
static mut ONCE_VAL: i64 = 0;

fn hunt_once() i64 {
    let o = arc::Arc::<sync::Once>::new(sync::Once::new());
    let wg = sync::WaitGroup::new();
    wg.add(TASKS);
    for _t in 0..TASKS {
        let h = o.clone();
        let w = wg.clone();
        launch || {
            h.get().call_once(
                || {
                    unsafe ONCE_VAL = 42;
                },
            );
            w.done();
        };
    }
    wg.wait();
    return unsafe ONCE_VAL;
}

// 5. sections: independent bodies dispatched together, each adding to one shared atomic.
fn hunt_sections() i64 {
    let total = atomics::Atomic::<i64>::new(0);
    let tp = &total;
    data::sections(
        |s: &mut data::Sections| {
            s.add(
                || {
                    let _ = tp.fetch_add(1, atomics::MemoryOrder::Relaxed);
                },
            );
            s.add(
                || {
                    let _ = tp.fetch_add(2, atomics::MemoryOrder::Relaxed);
                },
            );
            s.add(
                || {
                    let _ = tp.fetch_add(3, atomics::MemoryOrder::Relaxed);
                },
            );
            s.add(
                || {
                    let _ = tp.fetch_add(4, atomics::MemoryOrder::Relaxed);
                },
            );
        },
    );
    return total.load(atomics::MemoryOrder::Relaxed);
}

// 6. The blocking pool: work handed off to a separate thread pool and a value carried back.
fn hunt_blocking() i64 {
    let wg = sync::WaitGroup::new();
    wg.add(TASKS);
    let hits = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    for _t in 0..TASKS {
        let w = wg.clone();
        let h = hits.clone();
        launch || {
            for _i in 0..10 {
                // `fn` form, not `||`: only it has a return-type slot, and `call` carries a value back.
                let v = blocking::call(
                    fn() i64 {
                        time::sleep(time::Duration::from_millis(1));
                        return 1i64;
                    },
                );
                let _ = h.get().fetch_add(v, atomics::MemoryOrder::Relaxed);
            }
            w.done();
        };
    }
    wg.wait();
    let out = hits.get().load(atomics::MemoryOrder::Relaxed);
    return out;
}

// 7. Batched channel traffic, which the gate's smoke program never exercises.
fn hunt_batch() i64 {
    let ch = chan::Channel::<i64>::bounded(32);
    let rx = ch.receiver();
    let tx = ch.sender();
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch || {
        let mut out = Vector::<i64>::new();
        for i in 0..500 {
            out.push(i);
        }
        let _ = tx.send_batch(&mut out);
        tx.close();
        w.done();
    };
    let mut got = Vector::<i64>::new();
    let mut n: i64 = 0;
    loop {
        let k = rx.recv_batch(&mut got, 16);
        if k == 0 {
            break;
        }
        n = n + k as i64;
        got.clear();
    }
    wg.wait();
    return n;
}

const T2: i64 = 8;

// 1. Timed waits that mostly EXPIRE: the deadline and the notify race for the same park token, which is
// what `cancel_timer` and the wake-claim exist for.
fn hunt_timers() i64 {
    let ch = chan::Channel::<i64>::bounded(1);
    let rx = ch.receiver();
    let tx = ch.sender();
    let wg = sync::WaitGroup::new();
    wg.add(T2);
    let got = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    for _t in 0..T2 {
        let r = rx.clone();
        let w = wg.clone();
        let g = got.clone();
        launch || {
            for _i in 0..40 {
                // A deadline short enough that timeout and delivery genuinely contend.
                switch r.recv_timeout(time::Duration::from_micros(200)) {
                    Some(_v) => {
                        let _ = g.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
                    },
                    None => {},
                };
            }
            w.done();
        };
    }
    // Bounded on purpose. The consumers make a FIXED number of timed attempts, most of which expire, so
    // they exit having taken far fewer items than this loop has to give. `send` does not report "no
    // receivers" while this frame still holds one, so an unbounded producer waits for room forever:
    // a stall in the probe, not in the runtime.
    for i in 0..200 {
        let _ = tx.send_timeout(i, time::Duration::from_millis(50));
    }
    tx.close();
    wg.wait();
    let out = got.get().load(atomics::MemoryOrder::Relaxed);
    return out;
}

// 2. Several selectors over the SAME pair of channels: `lock_all` takes both locks in address order and
// `unlock_all` unwinds them, so two selectors sharing channels exercise the ordering rule directly.
fn hunt_select_contention() i64 {
    let a = chan::Channel::<i64>::bounded(2);
    let b = chan::Channel::<i64>::bounded(2);
    let arx = a.receiver();
    let brx = b.receiver();
    let atx = a.sender();
    let btx = b.sender();
    let hits = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(T2);
    for _t in 0..T2 {
        let ra = arx.clone();
        let rb = brx.clone();
        let w = wg.clone();
        let h = hits.clone();
        launch || {
            for _i in 0..30 {
                let mut s = sel::Selector::new();
                let _ = s.arm(&ra);
                let _ = s.arm(&rb);
                switch s.wait_timeout(time::Duration::from_micros(300)) {
                    Ready(_i2) => {
                        let _ = h.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
                    },
                    TimedOut => {},
                };
            }
            w.done();
        };
    }
    // Bounded for the same reason as `hunt_timers`: the selectors give up after a fixed number of rounds.
    for i in 0..300 {
        let _ = atx.send_timeout(i, time::Duration::from_millis(50));
        let _ = btx.send_timeout(i, time::Duration::from_millis(50));
    }
    atx.close();
    btx.close();
    wg.wait();
    let out = hits.get().load(atomics::MemoryOrder::Relaxed);
    return out;
}

// 3. `close` landing while senders and receivers are mid-flight, from many tasks at once.
fn hunt_close_race() i64 {
    let ch = chan::Channel::<i64>::bounded(4);
    let rx = ch.receiver();
    let tx = ch.sender();
    let wg = sync::WaitGroup::new();
    wg.add(T2);
    for t in 0..T2 {
        let s = tx.clone();
        let r = rx.clone();
        let w = wg.clone();
        let closer = t == 0;
        launch || {
            if closer {
                time::sleep(time::Duration::from_millis(2));
                // Lands with every other task inside send or recv.
                s.close();
            } else {
                for i in 0..100 {
                    let _ = s.send(i);
                    let _ = r.try_recv();
                }
            }
            w.done();
        };
    }
    wg.wait();
    return 0;
}

// 4. OS threads and coroutines on ONE mutex. The lock takes two entirely different paths: a thread parks
// futex-style on a word in its own frame, a coroutine goes through the scheduler, and here they interleave.
fn hunt_mixed_threads() i64 {
    let m = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(8);
    for _t in 0..8 {
        let h = m.clone();
        let w = wg.clone();
        launch || {
            for _i in 0..200 {
                let mut g = h.get().lock();
                let v = g.get_mut();
                *v = *v + 1;
            }
            w.done();
        };
    }
    let mut hs = Vector::<thread::JoinHandle<i64>>::new();
    for _t in 0..4 {
        let h = m.clone();
        hs.push(
            thread::spawn(
                fn() i64 {
                    for _i in 0..200 {
                        let mut g = h.get().lock();
                        let v = g.get_mut();
                        *v = *v + 1;
                    }
                    return 0;
                },
            ),
        );
    }
    for i in 0..hs.len() {
        let _ = hs[i].join();
    }
    wg.wait();
    let g = m.get().lock();
    let out = *g.get();
    return out;
}

fn main() i32 {
    let a = hunt_rwlock();
    hunt_semaphore();
    hunt_barrier();
    let b = hunt_once();
    let c = hunt_sections();
    let d = hunt_blocking();
    let e = hunt_batch();
    let f = hunt_timers();
    let g = hunt_select_contention();
    let h = hunt_close_race();
    let i = hunt_mixed_threads();
    // The blocking pool has its OWN threads; `rt::shutdown` does not join them, and unjoined threads are a
    // leak TSan reports at exit.
    blocking::shutdown();
    rt::shutdown();
    return (a - a + b - b + c - c + d - d + e - e + f - f + g - g + h - h + i - i) as i32;
}
