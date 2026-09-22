// The lock's interleavings, forced rather than waited for. Every window this program opens is nanoseconds
// wide in ordinary running, so each one is held open on purpose with the lock's hook points
// (`sync::HOOK_*`, armed through `rt::sched_hook_arm` and compiled in only when `RT_HOOKS` in
// std/parallel/runtime.spc is true) and then driven hard enough that the other side lands inside it. Run
// under `--profile=race`: a report here is a real happens-before hole, and a hang is a lost wake.
//
// Eight shapes, in order: a release that lands before its waiter has enqueued, a release that lands while
// the waiter is parked, a cancellation that claims a waiter the unlock has already chosen, an acquirer
// that barges in front of a waiter between the release and its wake, repeated cancellation on one lock,
// an address the allocator hands back after a lock with a stale queued bit died on it, a lock freed the
// instant its last unlock is observed, and plain threads with coroutines through the barging window.
//
// Every round is BOUNDED and every wait has a deadline: a shape that stops making progress fails the
// program rather than hanging it, because a hang under a sanitizer looks the same as a slow machine.

import stdio;
import stdlib;
import sc_runtime;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::channel as chan;
import std::parallel::thread as thread;
import std::parallel::arc as arc;
import std::parallel::atomics as atomics;
import std::parallel::platform as platform;
import std::parallel::time as time;

const ROUNDS: i64 = 60; // rounds per shape: bounded, so the program always ends
const HOOK_NS: u64 = 20000; // how wide each forced window is held open
const DEADLINE_S: u64 = 20; // per-shape diagnostic timeout

type Lock = arc::Arc<sync::Mutex<i64>>;

fn lock_of(v: i64) Lock {
    return arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(v));
}

fn counter() arc::Arc<atomics::Atomic<i64>> {
    return arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
}

fn count(c: &arc::Arc<atomics::Atomic<i64>>) i64 {
    return c.get().load(atomics::MemoryOrder::Acquire);
}

// Say which shape failed and how, then stop rather than hang.
fn fail(name: str, what: str) {
    unsafe stdio::printf(
        "mutex_hunt: %.*s %.*s\n".ptr() as *const char,
        name.len() as i32,
        name.ptr() as *const char,
        what.len() as i32,
        what.ptr() as *const char,
    );
    unsafe stdlib::exit(1);
}

// Wait for a group with a deadline.
fn finish(name: str, wg: &sync::WaitGroup) {
    if !wg.wait_timeout(time::Duration::from_secs(DEADLINE_S)) {
        fail(name, "did not finish");
    }
}

fn require(name: str, ok: bool) {
    if !ok {
        fail(name, "reported wrong work");
    }
}

// Take the lock on a task and keep it until the returned sender delivers, so anything else that asks for
// it queues. The sender is created HERE: a receive on a channel with no live sender returns at once.
fn hold(m: &Lock, w: &sync::WaitGroup) chan::Sender<i64> {
    let ch = chan::Channel::<i64>::bounded(1);
    let go = ch.sender();
    let rx = ch.receiver();
    let h = m.clone();
    let done = w.clone();
    launch || {
        let _g = h.get().lock();
        let _ = rx.recv();
        done.done();
    };
    return go;
}

// Busy-wait on the clock: a sleep would park this thread and hand the window to the scheduler.
fn spin_for(ns: u64) {
    let until = platform::now_ns() + ns;
    while platform::now_ns() < until {
        unsafe sc_runtime::sc_rt_cpu_relax();
    }
}

// 1. The release lands BEFORE the waiter has enqueued. The contender is held between publishing the queued
// bit and taking the bucket lock, which is exactly the window in which the owner can release and leave a
// queued bit with no waiter behind it.
fn hunt_release_before_enqueue() i64 {
    rt::sched_hook_arm(sync::HOOK_BEFORE_ENQUEUE, HOOK_NS);
    let taken = counter();
    for _r in 0..ROUNDS {
        let m = lock_of(0);
        let wg = sync::WaitGroup::new();
        wg.add(2);
        for _t in 0..2 {
            let h = m.clone();
            let w = wg.clone();
            let c = taken.clone();
            launch || {
                for _i in 0..40 {
                    let mut g = h.get().lock();
                    let v = g.get_mut();
                    *v = *v + 1;
                }
                let _ = c.get().fetch_add(40, atomics::MemoryOrder::AcqRel);
                w.done();
            };
        }
        finish("release before enqueue", &wg);
        let g = m.get().lock();
        require("release before enqueue", *g.get() == 80);
    }
    rt::sched_hook_arm(0, 0);
    return count(&taken);
}

// 2. The release lands while the waiter is parked: a long critical section past any spin, so every waiter
// reaches the queue and is woken from it rather than catching the lock on the way past.
fn hunt_release_during_park() i64 {
    let taken = counter();
    for _r in 0..ROUNDS {
        let m = lock_of(0);
        let wg = sync::WaitGroup::new();
        wg.add(4);
        for _t in 0..4 {
            let h = m.clone();
            let w = wg.clone();
            let c = taken.clone();
            launch || {
                for _i in 0..10 {
                    let mut g = h.get().lock();
                    let v = g.get_mut();
                    *v = *v + 1;
                    // Parked WITH the guard held: no spin can cover this, so the others queue.
                    time::sleep(time::Duration::from_micros(50));
                }
                let _ = c.get().fetch_add(10, atomics::MemoryOrder::AcqRel);
                w.done();
            };
        }
        finish("release during park", &wg);
        let g = m.get().lock();
        require("release during park", *g.get() == 40);
    }
    return count(&taken);
}

// 3. A cancellation claims the waiter the unlock has ALREADY chosen. The unlock is held between popping a
// node and publishing its release, and the first-queued waiter (the one a FIFO pop chooses) is cancelled
// inside that window, so the wake finds a park that is already spent and must pass it to the next waiter
// instead of losing it. A cancellation wakes a parked waiter at once, so it has to be requested AFTER the
// release and inside the held-open window: the holder is released, given time to reach the pop, and then
// the waiter is cancelled while the unlock is still delayed there.
fn hunt_cancel_after_selection() i64 {
    rt::sched_hook_arm(sync::HOOK_AFTER_POP, HOOK_NS * 10);
    let done = counter();
    for _r in 0..ROUNDS {
        let m = lock_of(0);
        let kch = chan::Channel::<rt::TaskKey>::bounded(4);
        let krx = kch.receiver();
        let holder = sync::WaitGroup::new();
        holder.add(1);
        let go = hold(&m, &holder);
        time::sleep(time::Duration::from_millis(2));
        let waiters = sync::WaitGroup::new();
        waiters.add(3);
        for _t in 0..3 {
            let h = m.clone();
            let w = waiters.clone();
            let ktx = kch.sender();
            let d = done.clone();
            launch || {
                defer w.done();
                let _ = ktx.send(rt::current_key());
                let got = h.get().lock_c();
                if got.is_some() {
                    let _ = d.get().fetch_add(1, atomics::MemoryOrder::AcqRel);
                }
            };
        }
        let key = krx.recv().unwrap();
        time::sleep(time::Duration::from_millis(2)); // every waiter is queued
        let _ = go.send(1);
        spin_for(HOOK_NS * 2); // the holder wakes and pops within this; the pop then holds ten times longer
        let _ = rt::request_cancel(key, rt::CR_USER);
        finish("cancel after selection", &holder);
        finish("cancel after selection", &waiters);
        // Whatever happened to the cancelled one, the lock is usable afterwards.
        let mut g = m.get().lock();
        let v = g.get_mut();
        *v = *v + 1;
    }
    rt::sched_hook_arm(0, 0);
    return count(&done);
}

// 4. An acquirer barges in front of the waiter the unlock chose. The unlock is held between publishing its
// release and waking its waiter, and a fresh acquirer takes the lock inside that window, so the woken
// waiter finds the lock held again and must go back round rather than assume ownership.
fn hunt_barge_before_wake() i64 {
    rt::sched_hook_arm(sync::HOOK_AFTER_RELEASE, HOOK_NS);
    let taken = counter();
    for _r in 0..ROUNDS {
        let m = lock_of(0);
        let wg = sync::WaitGroup::new();
        wg.add(5);
        for _t in 0..5 {
            let h = m.clone();
            let w = wg.clone();
            let c = taken.clone();
            launch || {
                for _i in 0..20 {
                    let mut g = h.get().lock();
                    let v = g.get_mut();
                    *v = *v + 1;
                }
                let _ = c.get().fetch_add(20, atomics::MemoryOrder::AcqRel);
                w.done();
            };
        }
        finish("barge before wake", &wg);
        let g = m.get().lock();
        require("barge before wake", *g.get() == 100);
    }
    rt::sched_hook_arm(0, 0);
    return count(&taken);
}

// 5. Repeated cancellation on ONE lock: every waiter is cancelled in turn, each removes its own node, and
// the queued bit they leave behind must not stop the acquisitions that follow.
fn hunt_repeated_cancellation() i64 {
    let ok = counter();
    for _r in 0..ROUNDS {
        let m = lock_of(0);
        let holder = sync::WaitGroup::new();
        holder.add(1);
        let go = hold(&m, &holder);
        time::sleep(time::Duration::from_millis(2));
        let kch = chan::Channel::<rt::TaskKey>::bounded(1);
        let krx = kch.receiver();
        let waiters = sync::WaitGroup::new();
        waiters.add(4);
        for _t in 0..4 {
            let h = m.clone();
            let w = waiters.clone();
            let ktx = kch.sender();
            launch || {
                defer w.done();
                let _ = ktx.send(rt::current_key());
                let _got = h.get().lock_c();
            };
            let key = krx.recv().unwrap();
            time::sleep(time::Duration::from_micros(500));
            let _ = rt::request_cancel(key, rt::CR_USER);
        }
        finish("repeated cancellation", &waiters);
        let _ = go.send(1);
        finish("repeated cancellation", &holder);
        {
            let mut g = m.get().lock();
            let v = g.get_mut();
            *v = 7;
        }
        let g = m.get().lock();
        require("repeated cancellation", *g.get() == 7);
        let _ = ok.get().fetch_add(1, atomics::MemoryOrder::AcqRel);
    }
    return count(&ok);
}

// Build a lock, leave a cancelled waiter's queued bit on it, and let it die; reports where it stood.
fn die_with_stale_bit() usize {
    let m = lock_of(0);
    let addr = (unsafe m.get().raw_handle()) as usize;
    let holder = sync::WaitGroup::new();
    holder.add(1);
    let go = hold(&m, &holder);
    time::sleep(time::Duration::from_millis(2));
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let krx = kch.receiver();
    let waiter = sync::WaitGroup::new();
    waiter.add(1);
    {
        let h = m.clone();
        let w = waiter.clone();
        let ktx = kch.sender();
        launch || {
            defer w.done();
            let _ = ktx.send(rt::current_key());
            let _got = h.get().lock_c();
        };
    }
    let key = krx.recv().unwrap();
    time::sleep(time::Duration::from_millis(2));
    let _ = rt::request_cancel(key, rt::CR_USER);
    finish("address reuse", &waiter);
    let _ = go.send(1);
    finish("address reuse", &holder);
    // The lock dies here, possibly with the cancelled waiter's queued bit still set.
    return addr;
}

// 6. An address the allocator hands back. A lock is left with a stale queued bit (a cancelled waiter set it
// and went away), destroyed, and another lock is built where it stood: the new lock's first unlock must
// not act on the old one's queue, and the old bit must not follow the address.
fn hunt_address_reuse() i64 {
    let reused = counter();
    let mut last: usize = 0;
    for _r in 0..ROUNDS {
        let stale = die_with_stale_bit();
        let fresh = lock_of(0);
        let here = (unsafe fresh.get().raw_handle()) as usize;
        if here == stale || here == last {
            let _ = reused.get().fetch_add(1, atomics::MemoryOrder::AcqRel);
        }
        last = here;
        for _i in 0..20 {
            let mut g = fresh.get().lock();
            let v = g.get_mut();
            *v = *v + 1;
        }
        let g = fresh.get().lock();
        require("address reuse", *g.get() == 20);
    }
    return count(&reused);
}

// 7. The lock is freed the instant its last unlock is observed, with the unlock held inside its own window
// between publishing the release and waking. Whatever the unlock does after that point must touch only the
// static bucket and the woken waiter's frame, never the lock, because by then the lock is gone.
fn hunt_free_at_last_unlock() i64 {
    rt::sched_hook_arm(sync::HOOK_AFTER_RELEASE, HOOK_NS);
    let rounds = counter();
    for _r in 0..ROUNDS {
        let m = lock_of(0);
        let wg = sync::WaitGroup::new();
        wg.add(3);
        for _t in 0..3 {
            let h = m.clone();
            let w = wg.clone();
            launch || {
                for _i in 0..15 {
                    let mut g = h.get().lock();
                    let v = g.get_mut();
                    *v = *v + 1;
                }
                w.done();
            };
        }
        finish("free at last unlock", &wg);
        {
            let g = m.get().lock();
            require("free at last unlock", *g.get() == 45);
        }
        let _ = rounds.get().fetch_add(1, atomics::MemoryOrder::AcqRel);
        // `m` is the last handle and dies here, right behind its own final unlock.
    }
    rt::sched_hook_arm(0, 0);
    return count(&rounds);
}

// 8. Plain threads and coroutines through the barging window at once, because the two wait on the same
// queue by different means and the wake path differs between them.
fn hunt_mixed_callers() i64 {
    rt::sched_hook_arm(sync::HOOK_AFTER_RELEASE, HOOK_NS);
    let taken = counter();
    for _r in 0..ROUNDS / 4 {
        let m = lock_of(0);
        let wg = sync::WaitGroup::new();
        wg.add(3);
        for _t in 0..3 {
            let h = m.clone();
            let w = wg.clone();
            let c = taken.clone();
            launch || {
                for _i in 0..20 {
                    let mut g = h.get().lock();
                    let v = g.get_mut();
                    *v = *v + 1;
                }
                let _ = c.get().fetch_add(20, atomics::MemoryOrder::AcqRel);
                w.done();
            };
        }
        let mut hs = Vector::<thread::JoinHandle<i64>>::new();
        for _t in 0..3 {
            let h = m.clone();
            let c = taken.clone();
            hs.push(
                thread::spawn(
                    fn() i64 {
                        for _i in 0..20 {
                            let mut g = h.get().lock();
                            let v = g.get_mut();
                            *v = *v + 1;
                        }
                        let _ = c.get().fetch_add(20, atomics::MemoryOrder::AcqRel);
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
        finish("mixed callers", &wg);
        let g = m.get().lock();
        require("mixed callers", *g.get() == 120);
    }
    rt::sched_hook_arm(0, 0);
    return count(&taken);
}

fn main() i32 {
    if !rt::sched_hooks_on() {
        let _ = unsafe stdio::puts(
            "mutex_hunt: the hooks are not compiled in; every window is left to chance".ptr() as *const char,
        );
    }
    let a = hunt_release_before_enqueue();
    let b = hunt_release_during_park();
    let c = hunt_cancel_after_selection();
    let d = hunt_barge_before_wake();
    let e = hunt_repeated_cancellation();
    let f = hunt_address_reuse();
    let g = hunt_free_at_last_unlock();
    let h = hunt_mixed_callers();
    unsafe stdio::printf(
        "mutex_hunt: enqueue %lld park %lld cancel %lld barge %lld repeat %lld reuse %lld free %lld mixed %lld\n".ptr() as *const char,
        a,
        b,
        c,
        d,
        e,
        f,
        g,
        h,
    );
    rt::shutdown();
    return 0;
}
