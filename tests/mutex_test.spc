// The lock's own contract (std/parallel/sync): mutual exclusion under every mix of callers, a guard that
// owns the payload exactly once, a `try_lock` that never waits, a cancelled acquisition that holds no lock
// and leaves no queue node, a lock that may be destroyed the moment its last unlock is observed, and an
// address that may be reused afterwards. The interleavings that need a forced window (release before
// enqueue, release during park, cancellation after selection, barging before wake) are driven from
// `ci/mutex_hunt.spc` with the lock's hooks compiled in; what is here needs no hook to be true.
//
// Every test that starts the runtime shuts it down, and the suite's SC_LEAK_CHECK=fatal gate proves no
// queue node, guard or payload was left behind.

import atomic;
import sc_runtime;
import std::parallel::runtime as rt;
import tests::parallel_harness as ph;
import std::parallel::sync as sync;
import std::parallel::channel as chan;
import std::parallel::thread as thread;
import std::parallel::arc as arc;
import std::parallel::atomics as atomics;
import std::parallel::platform as platform;
import std::parallel::time as time;

// Exact-destruction counter: every `free` of a Payload bumps it, so a test can prove one destruction.
static mut G_FREES: i64 = 0;

struct Payload {
    pub n: i64,
}

extend Payload as Free {
    pub fn free(self: &mut Payload) {
        let _ = unsafe atomic::add_i64(&mut unsafe G_FREES, 1, 0);
    }
}

fn frees() i64 {
    return unsafe atomic::load_i64(&mut unsafe G_FREES, 1);
}

struct Base {
    pub cancelled: usize,
}

@test_init
fn fresh_counters() Base {
    unsafe atomic::store_i64(&mut unsafe G_FREES, 0, 0);
    return Base { cancelled: rt::cancelled_tasks() };
}

fn cancelled(b: &Base) usize {
    return rt::cancelled_tasks() - b.cancelled;
}

fn counter() arc::Arc<atomics::Atomic<i64>> {
    return arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
}

fn count(c: &arc::Arc<atomics::Atomic<i64>>) i64 {
    return c.get().load(atomics::MemoryOrder::Acquire);
}

// --- mutual exclusion -------------------------------------------------------------------------------.

// A counter that only exact mutual exclusion keeps right: each holder reads, yields the core, and writes
// back, so any overlap of two holders loses an increment.
fn bump(v: &mut i64) {
    let seen = *v;
    unsafe sc_runtime::sc_rt_cpu_relax();
    *v = seen + 1;
}

@test
fn coroutines_never_overlap_in_the_critical_section() {
    rt::set_worker_count(4);
    let tasks: i64 = 8;
    let each: i64 = 500;
    let m = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(tasks);
    for _t in 0..tasks {
        let h = m.clone();
        let w = wg.clone();
        launch || {
            for _i in 0..each {
                let mut g = h.get().lock();
                bump(g.get_mut());
            }
            w.done();
        };
    }
    wg.wait();
    let g = m.get().lock();
    assert_eq(*g.get(), tasks * each);
    rt::shutdown();
}

@test
fn threads_and_coroutines_never_overlap() {
    rt::set_worker_count(4);
    let each: i64 = 400;
    let tasks: i64 = 4;
    let threads: i64 = 4;
    let m = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(tasks);
    for _t in 0..tasks {
        let h = m.clone();
        let w = wg.clone();
        launch || {
            for _i in 0..each {
                let mut g = h.get().lock();
                bump(g.get_mut());
            }
            w.done();
        };
    }
    let mut hs = Vector::<thread::JoinHandle<i64>>::new();
    for _t in 0..threads {
        let h = m.clone();
        hs.push(
            thread::spawn(
                fn() i64 {
                    for _i in 0..each {
                        let mut g = h.get().lock();
                        bump(g.get_mut());
                    }
                    return 0;
                },
            ),
        );
    }
    loop {
        switch hs.pop() {
            Some(h) => {
                let _ = h.join();
            },
            _ => {
                break;
            },
        };
    }
    wg.wait();
    let g = m.get().lock();
    assert_eq(*g.get(), (tasks + threads) * each);
    rt::shutdown();
}

// --- try_lock ---------------------------------------------------------------------------------------.

@test
fn try_lock_takes_a_free_lock_and_refuses_a_held_one() {
    let m = sync::Mutex::<i64>::new(7);
    {
        let mut g = m.try_lock().unwrap();
        let v = g.get_mut();
        assert_eq(*v, 7);
        *v = 8;
        // Held by this very guard: a second attempt must refuse rather than deadlock.
        assert(m.try_lock().is_none(), "a held lock refuses try_lock");
    }
    let g = m.try_lock().unwrap();
    assert_eq(*g.get(), 8);
}

@test
fn try_lock_returns_without_waiting_while_another_caller_holds() {
    rt::set_worker_count(2);
    let m = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let held = counter();
    let release = counter();
    let wg = sync::WaitGroup::new();
    wg.add(1);
    {
        let h = m.clone();
        let w = wg.clone();
        let hd = held.clone();
        let rl = release.clone();
        launch || {
            let _g = h.get().lock();
            hd.get().store(1, atomics::MemoryOrder::Release);
            while count(&rl) == 0 {
                time::sleep(time::Duration::from_millis(1));
            }
            w.done();
        };
    }
    while count(&held) == 0 {
        time::sleep(time::Duration::from_millis(1));
    }
    // The lock is held by a parked task that releases only when told below, so an attempt that waited
    // would never return: a thousand refusals prove `try_lock` never waits.
    let mut refused: i64 = 0;
    for _i in 0..1000 {
        if m.get().try_lock().is_none() {
            refused = refused + 1;
        }
    }
    assert_eq(refused, 1000);
    release.get().store(1, atomics::MemoryOrder::Release);
    wg.wait();
    rt::shutdown();
}

// --- the guard owns the payload ---------------------------------------------------------------------.

@test
fn the_guard_hands_back_the_payload_exactly_once(fx: &mut Base) {
    {
        let m = sync::Mutex::<Payload>::new(Payload { n: 1 });
        {
            let mut g = m.lock();
            g.get_mut().n = 2;
        }
        {
            let g = m.lock();
            assert_eq(g.get().n, 2);
        }
        // Still owned by the mutex: dropping guards destroys nothing.
        assert_eq(frees(), 0);
    }
    // The mutex went out of scope and took its payload with it, once.
    assert_eq(frees(), 1);
    let _ = fx;
}

@test
fn an_idle_lock_may_move(fx: &mut Base) {
    let m = sync::Mutex::<Payload>::new(Payload { n: 5 });
    // Moved while nothing holds it and nothing waits on it, which is the only time a value can move.
    let moved = m;
    {
        let g = moved.lock();
        assert_eq(g.get().n, 5);
    }
    assert_eq(frees(), 0);
    let _ = fx;
}

// --- cancellation -----------------------------------------------------------------------------------.

// Code after a cancelled wait must never run: bumped there, asserted zero from the test.
static mut G_AFTER: i64 = 0;

fn after_mark() {
    let _ = unsafe atomic::add_i64(&mut unsafe G_AFTER, 1, 0);
}

fn afters() i64 {
    return unsafe atomic::load_i64(&mut unsafe G_AFTER, 1);
}

// Take the lock on a task and keep it until `release` says otherwise, so anything else that asks for it
// blocks. Returns once the holder HAS the lock. The guard is dropped before the group is signalled: a
// signal fires before the signaller's locals drop, and a waiter that then found the lock still held would
// be seeing that gap, not a defect.
fn hold_until(m: &arc::Arc<sync::Mutex<i64>>, release: &arc::Arc<atomics::Atomic<i64>>, w: &sync::WaitGroup) {
    let h = m.clone();
    let rl = release.clone();
    let done = w.clone();
    let held = counter();
    let hd = held.clone();
    launch || {
        {
            let _g = h.get().lock();
            hd.get().store(1, atomics::MemoryOrder::Release);
            while count(&rl) == 0 {
                time::sleep(time::Duration::from_millis(1));
            }
        }
        done.done();
    };
    assert(ph::wait_count(&held, 1), "the holder takes the lock");
}

// `lock_c` is the cancellable acquisition: a cancelled wait returns no guard, holds no lock, removes its
// own queue node, and the task unwinds from there rather than running on.
@test
fn a_cancelled_acquisition_holds_no_lock(fx: &mut Base) {
    rt::set_worker_count(4);
    unsafe atomic::store_i64(&mut unsafe G_AFTER, 0, 0);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let m = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let release = counter();
    let holder = sync::WaitGroup::new();
    holder.add(1);
    hold_until(&m, &release, &holder);
    let waiter = sync::WaitGroup::new();
    waiter.add(1);
    {
        let h = m.clone();
        let w = waiter.clone();
        launch || {
            defer w.done();
            let _ = ktx.send(rt::current_key());
            // Blocks on the held lock; the cancellation claims the park and hands back no guard.
            let got = h.get().lock_c();
            assert(got.is_none(), "a cancelled acquisition yields no guard");
            after_mark();
        };
    }
    let key = krx.recv().unwrap();
    assert(ph::wait_parked(key), "the waiter reaches the queue");
    assert(rt::request_cancel(key, rt::CR_USER), "the waiter is live");
    assert(waiter.wait_timeout(time::Duration::from_secs(5)), "the cancelled waiter finishes at once");
    // It never entered the critical section and never ran on past the cancelled wait.
    assert_eq(afters(), 0);
    release.get().store(1, atomics::MemoryOrder::Release);
    assert(holder.wait_timeout(time::Duration::from_secs(5)), "the holder finishes");
    {
        let g = m.get().try_lock();
        assert(g.is_some(), "the lock is free once both are gone");
    }
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
}

// An unlock spends its release on the waiter whose park its wake claims. A cancellation that lands after
// that claim and before the waiter runs must not make the waiter give the wait up: the release would go
// with it, and every waiter queued behind it would stay parked. One worker, kept busy on a compute loop,
// holds the woken waiter off its run so the cancellation can land in that window.
@test
fn a_cancel_after_the_wake_claim_passes_the_release_on(fx: &mut Base) {
    rt::set_worker_count(1);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let m = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let waiters = sync::WaitGroup::new();
    waiters.add(2);
    let taken = counter();
    let gate = counter();
    let busy = counter();
    let mut key = rt::TaskKey { slot: 0, gen: 0 };
    {
        let held = m.get().lock();
        {
            let h = m.clone();
            let w = waiters.clone();
            let t = taken.clone();
            launch || {
                defer w.done();
                let _ = ktx.send(rt::current_key());
                let got = h.get().lock_c();
                if got.is_some() {
                    let _ = t.get().fetch_add(1, atomics::MemoryOrder::AcqRel);
                }
            };
        }
        key = krx.recv().unwrap();
        assert(ph::wait_parked(key), "the first waiter is queued");
        {
            let h = m.clone();
            let w = waiters.clone();
            let t = taken.clone();
            launch || {
                defer w.done();
                let _g = h.get().lock();
                let _ = t.get().fetch_add(1, atomics::MemoryOrder::AcqRel);
            };
        }
        assert(ph::wait_waiting(rt::WK_MUTEX, 2), "both waiters are queued");
        {
            let b = busy.clone();
            let gt = gate.clone();
            launch || {
                b.get().store(1, atomics::MemoryOrder::Release);
                while gt.get().load(atomics::MemoryOrder::Acquire) == 0 {
                    unsafe sc_runtime::sc_rt_cpu_relax();
                }
            };
        }
        assert(ph::wait_count(&busy, 1), "the only worker is busy");
        // The guard drops here: the unlock pops the first waiter and claims its park; it cannot run yet.
        let _ = held;
    }
    assert(rt::request_cancel(key, rt::CR_USER), "the woken waiter is live");
    gate.get().store(1, atomics::MemoryOrder::Release);
    assert(waiters.wait_timeout(time::Duration::from_secs(5)), "both waiters acquire in turn");
    assert_eq(count(&taken), 2);
    rt::shutdown();
    assert_eq(cancelled(fx), 0);
}

// A plain `lock` is deliberately NOT a cancellation point: it cannot hand a guard to a caller that would
// unlock a lock it does not hold, so a cancelled task blocked there keeps waiting, acquires normally, and
// unwinds at its next cancellation point instead.
@test
fn a_plain_acquisition_is_not_a_cancellation_point(fx: &mut Base) {
    rt::set_worker_count(4);
    unsafe atomic::store_i64(&mut unsafe G_AFTER, 0, 0);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let m = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let release = counter();
    let took = counter();
    let holder = sync::WaitGroup::new();
    holder.add(1);
    hold_until(&m, &release, &holder);
    let waiter = sync::WaitGroup::new();
    waiter.add(1);
    {
        let h = m.clone();
        let w = waiter.clone();
        let t = took.clone();
        launch || {
            defer w.done();
            let _ = ktx.send(rt::current_key());
            {
                let mut g = h.get().lock();
                let v = g.get_mut();
                *v = *v + 1;
                let _ = t.get().fetch_add(1, atomics::MemoryOrder::AcqRel);
            }
            // A cancellation point AFTER the guard is gone: this is where the task unwinds.
            time::sleep(time::Duration::from_secs(30));
            after_mark();
        };
    }
    let key = krx.recv().unwrap();
    assert(ph::wait_parked(key), "the waiter reaches the queue");
    assert(rt::request_cancel(key, rt::CR_USER), "the waiter is live");
    // Still blocked on the lock, which no cancellation may cut short.
    assert(!waiter.wait_timeout(time::Duration::from_millis(200)), "a plain acquisition waits through a cancellation");
    assert_eq(count(&took), 0);
    release.get().store(1, atomics::MemoryOrder::Release);
    assert(holder.wait_timeout(time::Duration::from_secs(5)), "the holder finishes");
    // It acquires, does its work, and unwinds at the sleep rather than at the lock.
    assert(waiter.wait_timeout(time::Duration::from_secs(5)), "the waiter finishes once the lock is free");
    assert_eq(count(&took), 1);
    assert_eq(afters(), 0);
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
}

// Several waiters cancelled one after another on the same lock: each removes its own node, and the queued
// bit they leave behind must not stop the next acquisition.
@test
fn repeated_cancellation_leaves_the_lock_usable(fx: &mut Base) {
    rt::set_worker_count(4);
    unsafe atomic::store_i64(&mut unsafe G_AFTER, 0, 0);
    let m = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let release = counter();
    let holder = sync::WaitGroup::new();
    holder.add(1);
    hold_until(&m, &release, &holder);
    let rounds: i64 = 5;
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let krx = kch.receiver();
    let waiters = sync::WaitGroup::new();
    waiters.add(rounds);
    for _r in 0..rounds {
        let h = m.clone();
        let w = waiters.clone();
        let ktx = kch.sender();
        launch || {
            defer w.done();
            let _ = ktx.send(rt::current_key());
            let got = h.get().lock_c();
            assert(got.is_none(), "a cancelled acquisition yields no guard");
            after_mark();
        };
        let key = krx.recv().unwrap();
        assert(ph::wait_parked(key), "each waiter reaches the queue");
        assert(rt::request_cancel(key, rt::CR_USER), "each waiter is live when cancelled");
    }
    assert(waiters.wait_timeout(time::Duration::from_secs(10)), "every cancelled waiter finishes");
    assert_eq(afters(), 0);
    release.get().store(1, atomics::MemoryOrder::Release);
    assert(holder.wait_timeout(time::Duration::from_secs(5)), "the holder finishes");
    // After five cancellations the queued bit may be stale; the next acquisition must still work.
    {
        let mut g = m.get().lock();
        let v = g.get_mut();
        *v = 99;
    }
    let g = m.get().lock();
    assert_eq(*g.get(), 99);
    rt::shutdown();
    assert_eq(cancelled(fx), rounds as usize);
}

// --- destruction and address reuse -------------------------------------------------------------------.

// A lock destroyed the instant its last unlock is observed, many times over, at the same address. The lock
// is a local of the loop body, so every round builds it in the same frame slot: the reuse is the frame's
// rather than the allocator's, which no allocator policy can take away. An unlock that touched the word
// after publishing its release, or a queued bit that outlived its lock, would show up as a corrupted
// successor.
@test
fn a_lock_may_be_destroyed_at_its_last_unlock_and_its_address_reused() {
    rt::set_worker_count(2);
    let rounds: i64 = 200;
    let mut reused: i64 = 0;
    let mut last: usize = 0;
    for r in 0..rounds {
        let m = sync::Mutex::<i64>::new(0);
        let here = (unsafe m.raw_handle()) as usize;
        if r > 0 && here == last {
            reused = reused + 1;
        }
        last = here;
        let shared = &m; // the parallel body borrows the lock; capturing `m` itself would move it
        parallel for _t in 0..2 {
            for _i in 0..50 {
                let mut g = shared.lock();
                bump(g.get_mut());
            }
        }
        let g = m.lock();
        assert_eq(*g.get(), 100);
        // `m` dies here, right behind its final unlock.
    }
    rt::shutdown();
    assert_eq(reused, rounds - 1);
}

// Locks in a vector behind an `Arc`: the element is reached through the reference `get` returns, and the
// guard borrows the vector, never the temporary that held that reference for the length of one statement.
@test
fn a_lock_in_a_vector_is_reached_through_the_arc() {
    let n: i64 = 4;
    let mut v = Vector::<sync::Mutex<i64>>::new();
    for i in 0..n {
        v.push(sync::Mutex::<i64>::new(i));
    }
    let locks = arc::Arc::<Vector<sync::Mutex<i64>>>::new(v);
    let mut sum: i64 = 0;
    for i in 0..n as usize {
        let g = locks.get()[i].lock();
        sum = sum + *g.get();
    }
    assert_eq(sum, 6);
}

// --- condition variables and the raw handle -----------------------------------------------------------.

// `Condvar` releases and re-acquires the very same lock around a wait, and `select` takes raw handles by
// hand. Both go through the raw contract rather than the guard, so a lock change has to keep them working.
@test
fn a_condvar_releases_and_retakes_the_same_lock() {
    rt::set_worker_count(4);
    let st = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let cv = arc::Arc::<sync::Condvar>::new(sync::Condvar::new());
    let wg = sync::WaitGroup::new();
    let waiters: i64 = 4;
    wg.add(waiters);
    for _t in 0..waiters {
        let m = st.clone();
        let c = cv.clone();
        let w = wg.clone();
        launch || {
            let mut g = m.get().lock();
            while *g.get() == 0 {
                let _ = c.get().wait(&g);
            }
            // Holding the lock again on the far side of the wait.
            let v = g.get_mut();
            *v = *v + 1;
            w.done();
        };
    }
    assert(ph::wait_waiting(rt::WK_CONDVAR, waiters as usize), "every waiter is parked on the condvar");
    {
        let mut g = st.get().lock();
        let v = g.get_mut();
        *v = 1;
        cv.get().notify_all();
    }
    assert(wg.wait_timeout(time::Duration::from_secs(5)), "every waiter woke and retook the lock");
    let g = st.get().lock();
    assert_eq(*g.get(), 1 + waiters);
    rt::shutdown();
}

// A cancellation that lands after a notify has claimed a condvar waiter's park does not drop that
// notify: the waiter's `wait` reports a normal wake and it takes what it was woken for, and the request
// waits for the next cancellation point. Reporting the wait cancelled lost the notify, and the waiter
// queued behind it stayed parked with the condition true. One busy worker keeps the woken waiter from
// running until the request is in.
@test
fn a_cancel_after_a_condvar_notify_keeps_the_notify(fx: &mut Base) {
    rt::set_worker_count(1);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let krx = kch.receiver();
    let st = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let cv = arc::Arc::<sync::Condvar>::new(sync::Condvar::new());
    let taken = counter();
    let gate = counter();
    let busy = counter();
    let wg = sync::WaitGroup::new();
    wg.add(2);
    let mut key = rt::TaskKey { slot: 0, gen: 0 };
    for k in 0..2 {
        let m = st.clone();
        let c = cv.clone();
        let w = wg.clone();
        let t = taken.clone();
        let kt = kch.sender();
        launch || {
            defer w.done();
            if k == 0 {
                let _ = kt.send(rt::current_key());
            }
            let mut g = m.get().lock();
            while *g.get() == 0 {
                if !c.get().wait(&g) {
                    return;
                }
            }
            // Take the ticket.
            let v = g.get_mut();
            *v = *v - 1;
            let _ = t.get().fetch_add(1, atomics::MemoryOrder::AcqRel);
        };
        if k == 0 {
            key = krx.recv().unwrap();
            assert(ph::wait_parked(key), "the first waiter is queued first");
        }
    }
    assert(ph::wait_waiting(rt::WK_CONDVAR, 2), "both waiters are queued");
    {
        let b = busy.clone();
        let gt = gate.clone();
        launch || {
            b.get().store(1, atomics::MemoryOrder::Release);
            while gt.get().load(atomics::MemoryOrder::Acquire) == 0 {
                unsafe sc_runtime::sc_rt_cpu_relax();
            }
        };
    }
    assert(ph::wait_count(&busy, 1), "the only worker is busy");
    {
        let mut g = st.get().lock();
        let v = g.get_mut();
        *v = 1;
        // Pops the first waiter and claims its park; it cannot run yet.
        cv.get().notify_one();
    }
    assert(rt::request_cancel(key, rt::CR_USER), "the woken waiter is live");
    gate.get().store(1, atomics::MemoryOrder::Release);
    assert(ph::wait_count(&taken, 1), "the notified waiter takes the ticket");
    {
        let mut g = st.get().lock();
        let v = g.get_mut();
        *v = *v + 1;
        cv.get().notify_all();
    }
    assert(wg.wait_timeout(time::Duration::from_secs(5)), "both waiters finish");
    assert_eq(count(&taken), 2);
    rt::shutdown();
    assert_eq(cancelled(fx), 0);
}

@test
fn the_raw_handle_is_the_same_address_every_time() {
    let m = sync::Mutex::<i64>::new(0);
    let a = unsafe m.raw_handle();
    let b = unsafe m.raw_handle();
    assert(a == b, "a selector holds this address for the life of an arm");
    {
        let _g = m.lock();
        assert(unsafe m.raw_handle() == a, "holding the lock does not move it");
    }
}
