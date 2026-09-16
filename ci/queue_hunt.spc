// Run-queue race exerciser for the ThreadSanitizer lane (see check.sh): the shapes that move a worker's
// ring hardest. Ring wraparound with several thieves (an owner that keeps spawning while others drain it, so
// slots are reused under readers), overflow past the ring into the injection queue, yield storms that route
// through the private yield queue and spill out of it, external submitters against stealing workers, and a
// shutdown that lands while cancellation cleanup is still running. Every task must run exactly once: the
// counts are checked, and any TSan report is a real hole in the slot-ownership argument.

import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::arc as arc;
import std::parallel::atomics as atomics;
import std::parallel::task as task;
import std::parallel::time as time;

// One owner spawns far more tasks than its ring holds while every other worker steals from it: the ring
// wraps many times and thieves batch-copy across the wrap.
fn wrap_under_thieves(rounds: i64) {
    for _r in 0..rounds {
        let ran = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
        let wg = sync::WaitGroup::new();
        let n: i64 = 4000; // sixteen rings' worth
        wg.add(n + 1);
        let w0 = wg.clone();
        let r0 = ran.clone();
        launch || {
            defer w0.done();
            for _i in 0..n {
                let w = w0.clone();
                let r = r0.clone();
                launch || {
                    defer w.done();
                    let _ = r.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
                };
            }
        };
        wg.wait();
        if ran.get().load(atomics::MemoryOrder::Acquire) != n {
            panic("queue_hunt: a task ran zero or several times under wraparound");
        }
    }
}

// Overflow: one task spawns a burst larger than the ring in a tight loop with no chance to drain, so pushes
// spill to the injection queue; then it yields in a storm past the private yield queue's bound.
fn overflow_and_yield(rounds: i64) {
    for _r in 0..rounds {
        let ran = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
        let wg = sync::WaitGroup::new();
        let n: i64 = 1024;
        wg.add(n + 8);
        for _k in 0..8 {
            let w0 = wg.clone();
            let r0 = ran.clone();
            launch || {
                defer w0.done();
                for _i in 0..n / 8 {
                    let w = w0.clone();
                    let r = r0.clone();
                    launch || {
                        defer w.done();
                        for _y in 0..3 {
                            rt::yield_now();
                        }
                        let _ = r.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
                    };
                }
                for _y in 0..64 {
                    rt::yield_now();
                }
            };
        }
        wg.wait();
        if ran.get().load(atomics::MemoryOrder::Acquire) != n {
            panic("queue_hunt: a task ran zero or several times under overflow");
        }
    }
}

// External submission from off the pool against workers stealing from each other.
fn external_vs_steal(rounds: i64) {
    for _r in 0..rounds {
        let ran = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
        let wg = sync::WaitGroup::new();
        let n: i64 = 2000;
        wg.add(n);
        for _i in 0..n {
            let w = wg.clone();
            let r = ran.clone();
            launch || {
                defer w.done();
                // A short fan-in inside: local pushes racing the external ones.
                let inner = sync::WaitGroup::new();
                inner.add(2);
                for _k in 0..2 {
                    let iw = inner.clone();
                    launch || {
                        defer iw.done();
                        rt::yield_now();
                    };
                }
                inner.wait();
                let _ = r.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            };
        }
        wg.wait();
        if ran.get().load(atomics::MemoryOrder::Acquire) != n {
            panic("queue_hunt: a task ran zero or several times under external submission");
        }
    }
}

// Shutdown with cancellation cleanup still active: children parked in sleeps are cancelled by the group
// while the pool is torn down under them, then the pool is rebuilt for the next round.
fn shutdown_during_cleanup(rounds: i64) {
    for _r in 0..rounds {
        let mut g = task::TaskGroup::new();
        for _k in 0..32 {
            g.spawn(
                || {
                    time::sleep(time::Duration::from_secs(10));
                },
            );
        }
        time::sleep(time::Duration::from_millis(2));
        g.cancel();
        let res = rt::try_shutdown(rt::ShutdownOptions::defaults());
        if res.unresponsive != 0 {
            panic("queue_hunt: shutdown left an unresponsive task");
        }
        let _ = g.join();
    }
}

fn main() i32 {
    wrap_under_thieves(20);
    overflow_and_yield(20);
    external_vs_steal(10);
    shutdown_during_cleanup(10);
    let res = rt::try_shutdown(rt::ShutdownOptions::defaults());
    if res.unresponsive != 0 {
        return 1;
    }
    return 0;
}
