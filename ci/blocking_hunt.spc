// Blocking-pool race exerciser for the ThreadSanitizer lane (see check.sh): the shapes that move the
// pool's ownership boundaries hardest. Frame-resident records settled by pool threads while their
// callers resume, cancellable records abandoned and completed in either order, thread creation raced
// near the limit with publication delayed and creations made to fail, admission at a full queue, nested
// calls on pool threads, and bounded shutdowns racing accepted work and reservations. Every call must
// return its value or a cancellation, every count must settle, and any TSan report is a hole in the
// ownership argument at the top of std/parallel/blocking.spc.

import sc_runtime;
import std::parallel::runtime as rt;
import std::parallel::blocking as blocking;
import std::parallel::sync as sync;
import std::parallel::channel as chan;
import std::parallel::arc as arc;
import std::parallel::atomics as atomics;
import std::parallel::time as time;

fn counter() arc::Arc<atomics::Atomic<i64>> {
    return arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
}

fn count(c: &arc::Arc<atomics::Atomic<i64>>) i64 {
    return c.get().load(atomics::MemoryOrder::Acquire);
}

// Short calls from many tasks, values checked.
fn value_storm(tasks: i64, each: i64) {
    let ok = counter();
    let wg = sync::WaitGroup::new();
    wg.add(tasks);
    for t in 0..tasks {
        let w = wg.clone();
        let o = ok.clone();
        launch || {
            defer w.done();
            let mut n: i64 = 0;
            for i in 0..each {
                let want = t * each + i;
                if blocking::call(
                    fn() i64 {
                        return want;
                    },
                ) == want {
                    n = n + 1;
                }
            }
            let _ = o.get().fetch_add(n, atomics::MemoryOrder::Relaxed);
        };
    }
    wg.wait();
    if count(&ok) != tasks * each {
        panic("blocking_hunt: a call returned the wrong value");
    }
}

// Cancellable calls abandoned at every point, with completion racing the cancel.
fn abandon_storm(rounds: i64) {
    for i in 0..rounds {
        let kch = chan::Channel::<rt::TaskKey>::bounded(1);
        let ktx = kch.sender();
        let krx = kch.receiver();
        let done = sync::WaitGroup::new();
        done.add(1);
        let d = done.clone();
        launch || {
            defer d.done();
            let _ = ktx.send(rt::current_key());
            let _ = blocking::call_c(
                fn() i64 {
                    return 7i64;
                },
            );
        };
        let key = krx.recv().unwrap();
        if i % 3 == 0 {
            time::sleep(time::Duration::from_micros(50));
        }
        let _ = rt::request_cancel(key, rt::CR_USER);
        done.wait();
    }
}

// Creation near the limit: bursts wider than the thread limit, publication delayed, creations failing.
fn creation_storm(rounds: i64) {
    blocking::set_publish_delay_ns(100000);
    for r in 0..rounds {
        if r % 2 == 0 {
            unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_THREAD_CREATE, 3);
        }
        let calls: i64 = 128;
        let ok = counter();
        let wg = sync::WaitGroup::new();
        wg.add(calls);
        for i in 0..calls {
            let w = wg.clone();
            let o = ok.clone();
            launch || {
                defer w.done();
                let want = i;
                if blocking::call(
                    fn() i64 {
                        time::sleep(time::Duration::from_millis(1));
                        return want;
                    },
                ) == want {
                    let _ = o.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
                }
            };
        }
        wg.wait();
        if count(&ok) != calls {
            panic("blocking_hunt: a call was lost in the creation storm");
        }
        let st = blocking::stats();
        if st.peak_threads > blocking::MAX_THREADS || st.starting != 0 {
            panic("blocking_hunt: the thread limit was exceeded or a reservation never settled");
        }
    }
    blocking::set_publish_delay_ns(0);
    unsafe sc_runtime::sc_rt_fail_arm(sc_runtime::FAIL_THREAD_CREATE, 0);
}

// Nested calls on pool threads while the pool is saturated.
fn nested_storm(calls: i64) {
    let ok = counter();
    let wg = sync::WaitGroup::new();
    wg.add(calls);
    for i in 0..calls {
        let w = wg.clone();
        let o = ok.clone();
        launch || {
            defer w.done();
            let want = i;
            let got = blocking::call(
                fn() i64 {
                    return blocking::call(
                        fn() i64 {
                            time::sleep(time::Duration::from_millis(1));
                            return want;
                        },
                    );
                },
            );
            if got == want {
                let _ = o.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            }
        };
    }
    wg.wait();
    if count(&ok) != calls {
        panic("blocking_hunt: a nested call returned the wrong value");
    }
}

// Bounded shutdowns landing on accepted work, reservations and admission waiters; each round closes
// the pool under load, drains it, and the next round starts a fresh one.
fn shutdown_storm(rounds: i64) {
    for r in 0..rounds {
        let calls: i64 = 200;
        let ok = counter();
        let wg = sync::WaitGroup::new();
        wg.add(calls);
        for i in 0..calls {
            let w = wg.clone();
            let o = ok.clone();
            launch || {
                defer w.done();
                let want = i;
                let got = if i % 2 == 0 {
                    blocking::call(
                        fn() i64 {
                            time::sleep(time::Duration::from_millis(2));
                            return want;
                        },
                    );
                } else {
                    blocking::call_c(
                        fn() i64 {
                            return want;
                        },
                    ).unwrap_or(want);
                };
                if got == want {
                    let _ = o.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
                }
            };
        }
        time::sleep(time::Duration::from_micros(200 * (r % 5 + 1) as u64));
        let _ = blocking::try_shutdown(1000000 * (r % 3 + 1) as u64);
        wg.wait();
        if count(&ok) != calls {
            panic("blocking_hunt: a call was lost across a shutdown");
        }
        let fin = blocking::try_shutdown(5000000000);
        if !fin.released {
            panic("blocking_hunt: the pool was not released after its work drained");
        }
    }
}

fn main() i32 {
    rt::set_worker_count(4);
    eprintln("blocking_hunt: value_storm");
    value_storm(32, 100);
    eprintln("blocking_hunt: abandon_storm");
    abandon_storm(300);
    eprintln("blocking_hunt: creation_storm");
    blocking::set_idle_ns(5000000);
    creation_storm(6);
    eprintln("blocking_hunt: nested_storm");
    nested_storm(128);
    eprintln("blocking_hunt: shutdown_storm");
    shutdown_storm(12);
    eprintln("blocking_hunt: done");
    blocking::shutdown();
    let res = rt::try_shutdown(rt::ShutdownOptions::defaults());
    if res.unresponsive != 0 {
        return 1;
    }
    return 0;
}
