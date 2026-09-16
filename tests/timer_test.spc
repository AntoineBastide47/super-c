// The timer heap (std/parallel/runtime): timed parks come due in deadline order and never early, an
// entry woken before its deadline is gone before the task parks again, equal deadlines keep arm order
// under deterministic replay, the heap grows through a burst and works when empty, a deadline that would
// wrap the clock waits for ever, a zero wait returns at once, and shutdown drains armed timers.

import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::time as time;
import std::parallel::atomics as atomics;
import std::parallel::arc as arc;
import std::parallel::platform as platform;

const LATE_LIMIT_NS: u64 = 50000000; // how late a sleep may end under load before the test fails (50 ms)

// A sleep ends at or after its deadline: never early. Deadlines are drawn increasing, decreasing, equal and
// pseudo-random across a thousand tasks, all armed at once.
@test
fn sleeps_end_in_order_and_never_early() {
    rt::set_worker_count(4);
    let n: i64 = 1000;
    let early = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let late = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(n);
    let base = platform::now_ns();
    for i in 0..n {
        let w = wg.clone();
        let e = early.clone();
        let l = late.clone();
        // Four patterns interleaved: increasing, decreasing, equal, and a linear congruential scatter.
        let ms: u64 = switch i % 4 {
            0 => (i / 4) as u64 % 40 + 1,
            1 => 40 - (i / 4) as u64 % 40,
            2 => 20u64,
            _ => (i as u64 * 2654435761 >> 7) % 40 + 1,
        };
        launch || {
            defer w.done();
            let dl = base + ms * 1000000;
            let left = if dl > platform::now_ns() {
                dl - platform::now_ns();
            } else {
                0u64;
            };
            rt::sleep_ns(left as i64);
            let now = platform::now_ns();
            if now < dl {
                let _ = e.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            }
            if now > dl + LATE_LIMIT_NS {
                let _ = l.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            }
        };
    }
    assert(wg.wait_timeout(time::Duration::from_secs(10)), "every sleeper wakes");
    rt::shutdown();
    assert_eq(early.get().load(atomics::MemoryOrder::Acquire), 0);
    assert_eq(late.get().load(atomics::MemoryOrder::Acquire), 0);
}

// A wait notified before its deadline leaves no entry behind: the old deadline passing later must not
// wake the task out of its next park. The task's second wait is a longer sleep; a stale wake would end it
// early.
@test
fn early_notify_leaves_no_stale_entry() {
    rt::set_worker_count(2);
    let m = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let cv = arc::Arc::<sync::Condvar>::new(sync::Condvar::new());
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let m1 = m.clone();
    let cv1 = cv.clone();
    let early = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let e = early.clone();
    launch || {
        defer w.done();
        for _k in 0..50 {
            {
                let g = m1.get().lock();
                // Woken by the notify well before this 20 ms deadline.
                let _ = cv1.get().wait_until(&g, time::deadline_in(time::Duration::from_millis(20)));
            }
            // The cancelled deadline passes during this sleep; it must not cut it short.
            let t0 = platform::now_ns();
            rt::sleep_ns(30000000);
            if platform::now_ns() - t0 < 30000000 {
                let _ = e.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            }
        }
    };
    for _k in 0..50 {
        rt::sleep_ns(1000000);
        cv.get().notify_one();
        rt::sleep_ns(31000000);
    }
    assert(wg.wait_timeout(time::Duration::from_secs(10)), "the waiter finishes its rounds");
    rt::shutdown();
    assert_eq(early.get().load(atomics::MemoryOrder::Acquire), 0);
}

// Equal deadlines come due in arm order, and replay makes the order the same on every run. The tasks
// share ONE absolute deadline through a condvar wait, so their heap entries differ only in arm sequence.
@test
fn equal_deadlines_keep_arm_order_under_replay() {
    rt::set_deterministic(11);
    let order = arc::Arc::<sync::Mutex<Vector<i64>>>::new(sync::Mutex::<Vector<i64>>::new(Vector::<i64>::new()));
    let gate = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let cv = arc::Arc::<sync::Condvar>::new(sync::Condvar::new());
    let wg = sync::WaitGroup::new();
    wg.add(16);
    let base = platform::now_ns() + 20000000;
    for i in 0..16i64 {
        let w = wg.clone();
        let o = order.clone();
        let m = gate.clone();
        let c = cv.clone();
        launch || {
            defer w.done();
            {
                let g = m.get().lock();
                let _ = c.get().wait_until(&g, base); // nobody notifies: the deadline ends it
            }
            let mut g = o.get().lock();
            g.get_mut().push(i);
        };
    }
    assert(wg.wait_timeout(time::Duration::from_secs(10)), "every sleeper wakes");
    rt::shutdown();
    let g = order.get().lock();
    assert_eq(g.len(), 16usize);
    for i in 0..16usize {
        assert_eq(*g.at(i), i as i64);
    }
}

// Ten thousand sleepers at once: the heap grows through the burst, every one wakes, and the runtime
// shuts down with the storage released (the suite's leak gate).
@test
fn a_burst_grows_the_heap() {
    rt::set_worker_count(4);
    let n: i64 = 10000;
    let wg = sync::WaitGroup::new();
    wg.add(n);
    for i in 0..n {
        let w = wg.clone();
        launch || {
            defer w.done();
            rt::sleep_ns(5000000 + i % 7 * 1000000);
        };
    }
    assert(wg.wait_timeout(time::Duration::from_secs(20)), "every sleeper wakes");
    rt::shutdown();
}

// A zero or negative wait returns at once without touching the heap; an empty heap costs nothing to
// look at.
@test
fn zero_wait_returns_at_once() {
    rt::set_worker_count(1);
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch || {
        defer w.done();
        let t0 = platform::now_ns();
        rt::sleep_ns(0);
        rt::sleep_ns(-5);
        assert(platform::now_ns() - t0 < 1000000, "no park for a zero wait");
    };
    assert(wg.wait_timeout(time::Duration::from_secs(5)), "the task finishes");
    rt::shutdown();
}

// A duration that would wrap the clock saturates to the far future instead of landing in the past.
@test
fn overflowing_deadline_saturates() {
    let huge = rt::deadline_after(18446744073709551615u64);
    assert_eq(huge, 18446744073709551615u64);
    let d = time::deadline_in(time::Duration::from_secs(1));
    assert(d > platform::now_ns(), "an ordinary deadline is in the future");
}

// Shutdown with armed timers: every sleeper is cancelled and reclaimed, and nothing stays armed.
@test
fn shutdown_drains_armed_timers() {
    rt::set_worker_count(2);
    for _i in 0..64 {
        launch || {
            rt::sleep_ns(60000000000);
        };
    }
    rt::sleep_ns(20000000);
    let before = rt::cancelled_tasks();
    let res = rt::try_shutdown(rt::ShutdownOptions::defaults());
    assert_eq(res.unresponsive, 0usize);
    assert_eq(rt::cancelled_tasks() - before, 64usize);
    assert_eq(rt::live_tasks(), 0usize);
}

// Repeatedly cancelled deadlines: a waiter whose timed waits are always notified first arms and disarms
// a thousand times while other sleepers hold the heap; the disarm must find its entry every time.
@test
fn repeated_cancellation_finds_its_entry() {
    rt::set_worker_count(4);
    let m = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let cv = arc::Arc::<sync::Condvar>::new(sync::Condvar::new());
    let wg = sync::WaitGroup::new();
    wg.add(9);
    // Eight background sleepers keep the heap populated around the waiter's entries.
    for _i in 0..8 {
        let w = wg.clone();
        launch || {
            defer w.done();
            for _k in 0..40 {
                rt::sleep_ns(5000000);
            }
        };
    }
    let w = wg.clone();
    let m1 = m.clone();
    let cv1 = cv.clone();
    let timeouts = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let tm = timeouts.clone();
    launch || {
        defer w.done();
        let g = m1.get().lock();
        while *g.get() < 1000 {
            // Each wait is notified within a millisecond; one that ran to its deadline was not.
            let t0 = platform::now_ns();
            let _ = cv1.get().wait_until(&g, time::deadline_in(time::Duration::from_secs(2)));
            if platform::now_ns() - t0 >= 1900000000 {
                let _ = tm.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            }
        }
    };
    for _k in 0..1000 {
        {
            let mut g = m.get().lock();
            *g.get_mut() = *g.get() + 1;
        }
        cv.get().notify_one();
        rt::sleep_ns(100000);
    }
    assert(wg.wait_timeout(time::Duration::from_secs(20)), "every task finishes");
    rt::shutdown();
    assert_eq(timeouts.get().load(atomics::MemoryOrder::Acquire), 0);
}
