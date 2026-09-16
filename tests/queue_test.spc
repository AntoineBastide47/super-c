// The run queues (std/parallel/runtime): every accepted task runs exactly once through ring wraparound
// under several thieves, through overflow into the injection queue, and through yield storms; a task that
// yields is served while its worker keeps spawning; external submitters and stealing workers agree on
// every task; and shutdown drains work still arriving from cancellation cleanup.

import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::atomics as atomics;
import std::parallel::arc as arc;
import std::parallel::platform as platform;
import std::parallel::task as task;
import std::parallel::time as time;

// A single owner pushes sixteen rings' worth of tasks while the other workers steal: the ring wraps many
// times, thieves copy batches across the wrap, and the count comes out exact.
@test
fn wraparound_under_thieves_runs_each_task_once() {
    rt::set_worker_count(4);
    let ran = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    let n: i64 = 4096;
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
    assert(wg.wait_timeout(time::Duration::from_secs(20)), "every task finishes");
    rt::shutdown();
    assert_eq(ran.get().load(atomics::MemoryOrder::Acquire), n);
}

// One worker, one task that spawns more than the ring holds before it can drain: the overflow spills to
// the injection queue and still runs exactly once, in a pool with nobody to steal.
@test
fn overflow_spills_to_the_injection_queue() {
    rt::set_worker_count(1);
    let ran = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    let n: i64 = 1000; // the ring holds 256
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
    assert(wg.wait_timeout(time::Duration::from_secs(20)), "every task finishes");
    rt::shutdown();
    assert_eq(ran.get().load(atomics::MemoryOrder::Acquire), n);
}

// A yielding task is served while its worker's ring never empties: sixty-four chains of tasks, each
// task spawning its successor, keep a single worker's ring at sixty-four entries from start to end
// (never empty, never overflowing), and the yielder must still get a bounded share of turns rather
// than its first one after the last chain.
fn chain(depth: i64, w: &sync::WaitGroup) {
    defer w.done();
    if depth == 0 {
        return;
    }
    let cw = w.clone();
    launch || {
        chain(depth - 1, &cw);
    };
}

@test
fn yielded_task_is_served_under_continuous_spawning() {
    rt::set_worker_count(1);
    let progress = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let stop = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let ydone = sync::WaitGroup::new();
    ydone.add(1);
    let w1 = ydone.clone();
    let p1 = progress.clone();
    let s1 = stop.clone();
    launch || {
        defer w1.done();
        while s1.get().load(atomics::MemoryOrder::Acquire) == 0 {
            let _ = p1.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            rt::yield_now();
        }
    };
    // Let the yielder take its first turn, so it is on the yield queue when the chains start.
    time::sleep(time::Duration::from_millis(5));
    let chains: i64 = 64;
    let depth: i64 = 255;
    let total: i64 = chains * (depth + 1);
    let cw = sync::WaitGroup::new();
    cw.add(total);
    for _c in 0..chains {
        let cw0 = cw.clone();
        launch || {
            chain(depth, &cw0);
        };
    }
    assert(cw.wait_timeout(time::Duration::from_secs(20)), "the chains finish");
    let turns = progress.get().load(atomics::MemoryOrder::Acquire);
    stop.get().store(1, atomics::MemoryOrder::Release);
    assert(ydone.wait_timeout(time::Duration::from_secs(5)), "the yielder stops");
    rt::shutdown();
    // A bounded share: at least one turn per 64 tasks the chains ran.
    assert(turns >= total / 64, "the yielder was served while the ring stayed full");
}

// Tasks submitted from off the pool against workers stealing from each other: every task runs once, and
// every child spawned from inside them too.
@test
fn external_submission_against_stealing_workers() {
    rt::set_worker_count(4);
    let ran = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    let n: i64 = 2000;
    wg.add(n);
    for _i in 0..n {
        let w = wg.clone();
        let r = ran.clone();
        launch || {
            defer w.done();
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
    assert(wg.wait_timeout(time::Duration::from_secs(20)), "every task finishes");
    rt::shutdown();
    assert_eq(ran.get().load(atomics::MemoryOrder::Acquire), n);
}

// A task that parks twice in a row (a wait, then a contended re-lock on the way out) leaves two park
// hand-offs on its block; the block must not be recycled until both are over. Thousands of such tasks
// through a busy pool, with the count checked: a lost hand-off shows as a corrupted or double-run task.
@test
fn double_park_hand_off_is_complete_before_reuse() {
    rt::set_worker_count(4);
    for _round in 0..5 {
        let ran = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
        let wg = sync::WaitGroup::new();
        let n: i64 = 1000;
        wg.add(n);
        for _i in 0..n {
            let w = wg.clone();
            let r = ran.clone();
            launch || {
                defer w.done();
                let inner = sync::WaitGroup::new();
                inner.add(2);
                for _k in 0..2 {
                    let iw = inner.clone();
                    launch || {
                        defer iw.done();
                    };
                }
                inner.wait();
                let _ = r.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            };
        }
        assert(wg.wait_timeout(time::Duration::from_secs(20)), "every task finishes");
        assert_eq(ran.get().load(atomics::MemoryOrder::Acquire), n);
    }
    rt::shutdown();
}

// Shutdown while cancellation cleanup is still producing work: children cancelled by their group unwind
// and complete as the pool is torn down; nothing is left unresponsive.
@test
fn shutdown_drains_cleanup_in_flight() {
    rt::set_worker_count(2);
    let mut g = task::TaskGroup::new();
    for _k in 0..32 {
        g.spawn(
            || {
                time::sleep(time::Duration::from_secs(10));
            },
        );
    }
    time::sleep(time::Duration::from_millis(5));
    g.cancel();
    let res = rt::try_shutdown(rt::ShutdownOptions::defaults());
    assert_eq(res.unresponsive, 0usize);
    let report = g.join();
    assert_eq(report.cancelled, 32usize);
    assert_eq(rt::live_tasks(), 0usize);
}
