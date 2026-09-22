// Channel and wait coordination (std/parallel/channel, sync, selector and the parking lot): a channel is
// one allocation, a payload is destroyed exactly once whichever way an operation ends, every transition
// wakes the right end, a plain thread waits like a coroutine (on a queue node, not a poll), a `select` may
// name one channel twice, and an unpark reaches only the thread parked on that word. Every test that
// starts the runtime shuts it down; the suite's SC_LEAK_CHECK=fatal gate proves nothing was left behind.

import atomic;
import sc_runtime;
import std::parallel::runtime as rt;
import tests::parallel_harness as ph;
import std::parallel::sync as sync;
import std::parallel::channel as chan;
import std::parallel::selector as selector;
import std::parallel::thread as thread;
import std::parallel::arc as arc;
import std::parallel::atomics as atomics;
import std::parallel::platform as platform;
import std::parallel::time as time;
import std::testing::bench_sys as sys;

// Exact-destruction counter: every `free` of a Payload bumps it, so a test can prove one destruction.
static mut G_FREES: i64 = 0;

struct Payload {
    pub n: i64,
}

extend Payload as Free {
    pub fn free(self: &mut Payload) {
        let _ = atomic::add_i64(&mut unsafe G_FREES, 1, 0);
    }
}

fn frees() i64 {
    return atomic::load_i64(&mut unsafe G_FREES, 1);
}

// Wait, bounded, until `frees()` reaches `want`: a deferred signal fires before the task's locals drop.
fn wait_frees(want: i64) bool {
    let deadline = platform::now_ns() + 5000000000;
    while frees() < want {
        if platform::now_ns() > deadline {
            return false;
        }
        time::sleep(time::Duration::from_millis(1));
    }
    return true;
}

// A zero-sized payload: a channel of these has no ring at all.
struct Nothing {}

struct Base {
    pub cancelled: usize,
}

@test_init
fn fresh_counters() Base {
    atomic::store_i64(&mut unsafe G_FREES, 0, 0);
    return Base { cancelled: rt::cancelled_tasks() };
}

fn counter() arc::Arc<atomics::Atomic<i64>> {
    return arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
}

fn count(c: &arc::Arc<atomics::Atomic<i64>>) i64 {
    return c.get().load(atomics::MemoryOrder::Acquire);
}

// Tasks this test cancelled, against the process-lifetime base the fixture took.
fn cancelled(b: &Base) usize {
    return rt::cancelled_tasks() - b.cancelled;
}

// Runs a per-run allocation figure is measured over: enough that the leak tracker's own occasional
// allocations stay far below one per run.
const MEASURE_RUNS: i64 = 64;

const fn short() time::Duration {
    return time::Duration::from_millis(20);
}

// --- allocation ----------------------------------------------------------------------------------------.

// Allocation calls made by `body`, through the benchmark shim's per-thread counter. Negative when the
// platform has no counter.
fn allocs_of(body: fn() void, runs: i64) i64 {
    if unsafe sys::sc_bs_alloc_supported() == 0 {
        return -1;
    }
    unsafe sys::sc_bs_alloc_enable(1);
    let a0 = unsafe sys::sc_bs_alloc_calls();
    for _i in 0..runs {
        body();
    }
    let n = unsafe sys::sc_bs_alloc_calls() - a0;
    unsafe sys::sc_bs_alloc_enable(0);
    return n;
}

// The allocations ONE run of `body` makes, measured over MEASURE_RUNS runs and divided. The division is
// what makes the figure the program's own: the leak tracker, while it records, allocates for its own table
// now and then, and those calls are counted too. They are FEW and they stop, so over this many runs they
// cannot reach one per run, and the quotient is exactly what the body allocates.
fn allocs_per_run(body: fn() void) i64 {
    let n = allocs_of(body, MEASURE_RUNS);
    if n < 0 {
        return -1;
    }
    return n / MEASURE_RUNS;
}

@test
fn a_bounded_channel_is_one_allocation() {
    let n = allocs_per_run(
        || {
            let ch = chan::Channel::<i64>::bounded(64);
            let tx = ch.sender();
            let rx = ch.receiver();
            for i in 0..64 {
                let _ = tx.try_send(i);
            }
            let mut sum: i64 = 0;
            loop {
                switch rx.try_recv() {
                    Some(v) => {
                        sum = sum + v;
                    },
                    _ => {
                        break;
                    },
                };
            }
            assert_eq(sum, 2016);
        },
    );
    if n >= 0 {
        // The block: handle count, lock, state, both queues and the 64-slot ring. The handles allocate nothing.
        assert_eq(n, 1);
    }
}

@test
fn an_unbounded_channel_allocates_again_only_past_its_inline_ring() {
    let inline_only = allocs_per_run(
        || {
            let ch = chan::Channel::<i64>::unbounded();
            let tx = ch.sender();
            let rx = ch.receiver();
            for i in 0..8 {
                let _ = tx.send(i);
            }
            for i in 0..8 {
                assert_eq(rx.recv().unwrap(), i);
            }
        },
    );
    let grown = allocs_per_run(
        || {
            let ch = chan::Channel::<i64>::unbounded();
            let tx = ch.sender();
            let rx = ch.receiver();
            for i in 0..9 {
                let _ = tx.send(i);
            }
            for i in 0..9 {
                assert_eq(rx.recv().unwrap(), i);
            }
        },
    );
    if inline_only >= 0 {
        assert_eq(inline_only, 1);
        // The ninth item outgrows the inline ring: the block, then one heap ring.
        assert_eq(grown, 2);
    }
}

@test
fn a_zero_sized_payload_has_no_ring() {
    let n = allocs_per_run(
        || {
            let ch = chan::Channel::<Nothing>::unbounded();
            let tx = ch.sender();
            let rx = ch.receiver();
            for _i in 0..100 {
                let _ = tx.send(Nothing {});
            }
            let mut got = 0;
            loop {
                switch rx.try_recv() {
                    Some(_v) => {
                        got = got + 1;
                    },
                    _ => {
                        break;
                    },
                };
            }
            assert_eq(got, 100);
        },
    );
    if n >= 0 {
        // The block alone: a hundred zero-sized items need no slots at all.
        assert_eq(n, 1);
    }
}

// --- payload ownership: exactly one destruction whichever way an operation ends ------------------------.

@test
fn a_timed_out_send_hands_the_value_back(fx: &mut Base) {
    let ch = chan::Channel::<Payload>::bounded(1);
    let tx = ch.sender();
    let rx = ch.receiver();
    switch tx.send(Payload { n: 1 }) {
        Sent => {},
        Rejected(_v) => {
            assert(false, "the first send fits");
        },
    };
    // Full: the timed send waits (on this plain thread's queue node) and gives up.
    let t0 = platform::now_ns();
    switch tx.send_timeout(Payload { n: 2 }, short()) {
        Sent => {
            assert(false, "a full channel rejects after the deadline");
        },
        Rejected(v) => {
            assert_eq(v.n, 2);
            assert_eq(frees(), 0);
        },
    };
    assert(platform::now_ns() - t0 >= 20000000, "the deadline was waited out");
    // The handed-back value was freed at the arm's end; the buffered one is still owned by the channel.
    assert_eq(frees(), 1);
    {
        let got = rx.recv_timeout(short()).unwrap();
        assert_eq(got.n, 1);
    }
    assert_eq(frees(), 2);
    let none = rx.recv_timeout(short());
    assert(none.is_none(), "an empty channel times out with nothing");
    let _ = fx;
}

@test
fn close_frees_buffered_payloads_once_on_the_last_handle(fx: &mut Base) {
    {
        let ch = chan::Channel::<Payload>::bounded(4);
        let tx = ch.sender();
        let rx = ch.receiver();
        for i in 0..3 {
            let _ = tx.send(Payload { n: i });
        }
        tx.close();
        switch tx.send(Payload { n: 9 }) {
            Sent => {
                assert(false, "a closed channel rejects");
            },
            Rejected(v) => {
                assert_eq(v.n, 9);
            },
        };
        assert_eq(frees(), 1); // the rejected one
        // Closed but not drained: the first buffered item is still readable.
        {
            let first = rx.recv().unwrap();
            assert_eq(first.n, 0);
        }
        assert_eq(frees(), 2);
        // Two payloads stay buffered; the last handle out frees them with the block.
    }
    assert_eq(frees(), 4);
    {
        // The same past the inline ring: the heap ring is freed with its payloads.
        let ch = chan::Channel::<Payload>::unbounded();
        let tx = ch.sender();
        let _rx = ch.receiver();
        for i in 0..20 {
            let _ = tx.send(Payload { n: i });
        }
    }
    assert_eq(frees(), 24);
    let _ = fx;
}

@test
fn last_handle_drop_closes_each_side(fx: &mut Base) {
    let ch = chan::Channel::<Payload>::bounded(2);
    {
        let rx = ch.receiver();
        {
            let tx = ch.sender();
            let _ = tx.send(Payload { n: 1 });
        }
        // No sender left: the buffered item drains, then `None`.
        let v = rx.recv().unwrap();
        assert_eq(v.n, 1);
        let _ = v;
        assert(rx.recv().is_none(), "closed and drained once the last sender is gone");
    }
    assert_eq(frees(), 1);
    let tx = ch.sender();
    // No receiver left: a send hands the value back at once.
    switch tx.send(Payload { n: 2 }) {
        Sent => {
            assert(false, "no receiver can take it");
        },
        Rejected(v) => {
            assert_eq(v.n, 2);
        },
    };
    assert_eq(frees(), 2);
    let _ = fx;
}

@test
fn a_partial_batch_keeps_the_remainder_in_order(fx: &mut Base) {
    rt::set_worker_count(2);
    let ch = chan::Channel::<Payload>::bounded(4);
    let tx = ch.sender();
    let rx = ch.receiver();
    let taken = counter();
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let t = taken.clone();
    launch || {
        // Take four, then drop the last receiver: the batch in flight loses its consumer.
        let mut got = Vector::<Payload>::new();
        while got.len() < 4 {
            let _ = rx.recv_batch(&mut got, 4);
        }
        t.get().store(got.len() as i64, atomics::MemoryOrder::Release);
        w.done();
    };
    let mut items = Vector::<Payload>::new();
    for i in 0..10 {
        items.push(Payload { n: i });
    }
    let sent = tx.send_batch(&mut items);
    wg.wait();
    assert_eq(count(&taken), 4);
    // The receiver's take makes room and wakes the sender, and the receiver drops its handle only after
    // that: whether the sender sees the room or the closed channel first is the scheduler's choice, so
    // it sends four, or up to four more before it notices. What holds in every order: at least the four
    // that fit, never past the room made, and the remainder handed back intact and in order.
    assert(sent >= 4 && sent <= 8, "the batch sends what fits and stops at the closed channel");
    assert_eq(items.len(), 10 - sent);
    for i in 0..items.len() {
        assert_eq(items[i].n, (i + sent) as i64);
    }
    rt::shutdown();
    // The four delivered ones were freed by the receiver; the rest are owned here or by the channel.
    assert_eq(frees(), 4);
    let _ = fx;
}

// --- transitions and mixed waiters ------------------------------------------------------------------------.

@test
fn a_full_and_empty_ring_wakes_a_thread_and_a_task_in_turn(fx: &mut Base) {
    rt::set_worker_count(2);
    let there = chan::Channel::<i64>::bounded(1);
    let back = chan::Channel::<i64>::bounded(1);
    let tx = there.sender();
    let rx = there.receiver();
    let btx = back.sender();
    let brx = back.receiver();
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch || {
        // The task side: every receive finds an empty ring (it parks), every send a full one.
        loop {
            switch rx.recv() {
                Some(v) => {
                    let _ = btx.send(v * 2);
                },
                _ => {
                    break;
                },
            };
        }
        btx.close();
        w.done();
    };
    // The plain-thread side: capacity one, so this thread blocks on its queue node for every reply.
    let mut sum: i64 = 0;
    for i in 0..200 {
        let _ = tx.send(i);
        let _ = tx.send(i + 1000); // a second send parks this thread on the full ring
        sum = sum + brx.recv().unwrap() + brx.recv().unwrap();
    }
    tx.close();
    assert(brx.recv().is_none(), "the echo closed after the last reply");
    wg.wait();
    rt::shutdown();
    assert_eq(sum, 2 * (199 * 200 / 2 + 200 * 1000 + 199 * 200 / 2));
    let _ = fx;
}

@test
fn many_senders_and_receivers_deliver_each_item_once(fx: &mut Base) {
    rt::set_worker_count(4);
    let ch = chan::Channel::<Payload>::bounded(3);
    let got = counter();
    let sum = counter();
    let wg = sync::WaitGroup::new();
    wg.add(7);
    let mut txs = Vector::<chan::Sender<Payload>>::new();
    for _p in 0..4 {
        txs.push(ch.sender());
    }
    for _c in 0..3 {
        let rx = ch.receiver();
        let w = wg.clone();
        let g = got.clone();
        let s = sum.clone();
        launch || {
            loop {
                switch rx.recv() {
                    Some(v) => {
                        let _ = g.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
                        let _ = s.get().fetch_add(v.n, atomics::MemoryOrder::Relaxed);
                    },
                    _ => {
                        break;
                    },
                };
            }
            w.done();
        };
    }
    loop {
        switch txs.pop() {
            Some(tx) => {
                let w = wg.clone();
                launch || {
                    for i in 0..25 {
                        let _ = tx.send(Payload { n: i });
                    }
                    w.done();
                };
            },
            _ => {
                break;
            },
        };
    }
    wg.wait();
    rt::shutdown();
    assert_eq(count(&got), 100);
    assert_eq(count(&sum), 4 * 300);
    assert_eq(frees(), 100);
    let _ = fx;
}

// A receive cancelled in the same instant a send lands: the value is either taken by the task or still
// buffered, never both and never lost.
@test
fn a_receive_cancelled_as_a_send_lands_loses_nothing(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let ch = chan::Channel::<Payload>::bounded(1);
    let tx = ch.sender();
    let rx = ch.receiver();
    let rx2 = rx.clone();
    let taken = counter();
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let t = taken.clone();
    launch || {
        defer w.done();
        let _ = ktx.send(rt::current_key());
        switch rx.recv() {
            Some(_v) => {
                let _ = t.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            },
            None => {},
        };
    };
    let key = krx.recv().unwrap();
    assert(ph::wait_parked(key), "the receiver parks");
    assert(rt::request_cancel(key, rt::CR_USER), "the receiver is live");
    let _ = tx.send(Payload { n: 1 }); // races the cancellation for the parked receiver
    assert(wg.wait_timeout(time::Duration::from_secs(5)), "the receiver finishes either way");
    let buffered: i64;
    {
        let left = rx2.try_recv();
        buffered = if left.is_some() {
            1i64;
        } else {
            0i64;
        };
    }
    rt::shutdown();
    assert_eq(count(&taken) + buffered, 1);
    assert_eq(frees(), 1);
    let _ = fx;
}

// --- select -------------------------------------------------------------------------------------------.

@test
fn select_may_name_one_channel_twice(fx: &mut Base) {
    rt::set_worker_count(2);
    let ch = chan::Channel::<i64>::bounded(1);
    let tx = ch.sender();
    let rx = ch.receiver();
    let mut s = selector::Selector::new();
    let r1 = s.arm_recv(&rx);
    let r2 = s.arm_recv(&rx);
    let snd = s.arm_send(&tx);
    // Empty: only the send arm can proceed, and the shared lock is taken once.
    switch s.poll() {
        Ready(i) => {
            assert_eq(i, snd);
        },
        TimedOut => {
            assert(false, "the send arm is ready");
        },
    };
    let _ = tx.try_send(7);
    // Full: only the receive arms; either duplicate may win.
    switch s.wait_timeout(short()) {
        Ready(i) => {
            assert(i == r1 || i == r2, "a receive arm wins on a full ring");
            assert_eq(rx.try_recv().unwrap(), 7);
        },
        TimedOut => {
            assert(false, "a receive arm is ready");
        },
    };
    // Empty again, and a task sends after a moment: the parked wait ends on a receive arm.
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let tx2 = tx.clone();
    launch || {
        time::sleep(short());
        let _ = tx2.send(8);
        w.done();
    };
    let mut s2 = selector::Selector::new();
    let a = s2.arm_recv(&rx);
    let b = s2.arm_recv(&rx);
    switch s2.wait_timeout(time::Duration::from_secs(5)) {
        Ready(i) => {
            assert(i == a || i == b, "a receive arm wins when the value lands");
            assert_eq(rx.try_recv().unwrap(), 8);
        },
        TimedOut => {
            assert(false, "the value arrives within the deadline");
        },
    };
    wg.wait();
    rt::shutdown();
    let _ = fx;
}

@test
fn a_plain_thread_select_wakes_on_the_arm_that_moves(fx: &mut Base) {
    rt::set_worker_count(2);
    let a = chan::Channel::<i64>::bounded(1);
    let b = chan::Channel::<i64>::bounded(1);
    let arx = a.receiver();
    let brx = b.receiver();
    // Both senders stay alive here: a channel whose last sender is gone reads as ready (closed).
    let _atx = a.sender();
    let _btx = b.sender();
    let btx = b.sender();
    let sent_at = arc::Arc::<atomics::Atomic<u64>>::new(atomics::Atomic::<u64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let s = sent_at.clone();
    launch || {
        time::sleep(time::Duration::from_millis(50));
        s.get().store(platform::now_ns(), atomics::MemoryOrder::Release);
        let _ = btx.send(3);
        w.done();
    };
    // This thread runs no coroutine: it queues a node on both channels and sleeps on one word.
    let mut sel = selector::Selector::new();
    let ia = sel.arm_recv(&arx);
    let ib = sel.arm_recv(&brx);
    switch sel.wait_timeout(time::Duration::from_secs(5)) {
        Ready(i) => {
            let woke_at = platform::now_ns();
            assert_eq(i, ib);
            assert_eq(brx.try_recv().unwrap(), 3);
            let t0 = sent_at.get().load(atomics::MemoryOrder::Acquire);
            // Woken by the send, not before it. How PROMPTLY is the concurrency benchmark's question: a
            // bound on the latency here would measure the runner's scheduler, not the wake.
            assert(woke_at >= t0, "the wake follows the send");
        },
        TimedOut => {
            assert(false, "the send on b ends the wait");
        },
    };
    let _ = ia;
    // Nothing moves: the deadline ends the wait, and the wake word's timeout claim leaves no node behind.
    let t1 = platform::now_ns();
    switch sel.wait_timeout(short()) {
        Ready(_i) => {
            assert(false, "nothing is ready");
        },
        TimedOut => {},
    };
    assert(platform::now_ns() - t1 >= 20000000, "the deadline was waited out");
    wg.wait();
    rt::shutdown();
    let _ = fx;
}

// --- plain-thread condvar waits -----------------------------------------------------------------------------.

// Permits handed out one at a time to WAITERS plain threads parked on one condvar. A notify wakes the
// longest-queued waiter and no other: a woken thread that finds no permit counts a stray wake.
struct Permits {
    pub free: sync::Mutex<i64>,
    pub cv: sync::Condvar,
    pub stop: sync::Mutex<bool>,
}

const WAITERS: i64 = 8;

fn stopped(p: &Permits) bool {
    let g = p.stop.lock();
    return *g.get();
}

@test
fn a_notify_wakes_one_plain_thread_and_no_other() {
    let st = arc::Arc::<Permits>::new(
        Permits { free: sync::Mutex::<i64>::new(0), cv: sync::Condvar::new(), stop: sync::Mutex::<bool>::new(false) },
    );
    let strays = counter();
    let served = counter();
    let mut handles = Vector::<thread::JoinHandle<i64>>::new();
    for _t in 0..WAITERS {
        let s = st.clone();
        let stray = strays.clone();
        let done = served.clone();
        handles.push(
            thread::spawn(
                fn() i64 {
                    let p = s.get();
                    let mut mine: i64 = 0;
                    loop {
                        let mut g = p.free.lock();
                        while *g.get() == 0 {
                            if stopped(p) {
                                return mine;
                            }
                            let _ = p.cv.wait(&g);
                            if *g.get() == 0 && !stopped(p) {
                                let _ = stray.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
                            }
                        }
                        let c = g.get_mut();
                        *c = *c - 1;
                        mine = mine + 1;
                        let _ = done.get().fetch_add(1, atomics::MemoryOrder::Release);
                    }
                },
            ),
        );
    }
    let p = st.get();
    // Let every thread queue up, so each notify has a full queue to pick from.
    rt::sleep_ns(50000000);
    let rounds: i64 = 40;
    for i in 0..rounds {
        {
            let mut g = p.free.lock();
            let c = g.get_mut();
            *c = *c + 1;
            p.cv.notify_one();
        }
        while count(&served) < i + 1 {
            rt::sleep_ns(100000);
        }
    }
    {
        let mut g = p.stop.lock();
        *g.get_mut() = true;
        let _h = p.free.lock();
        p.cv.notify_all();
    }
    let mut total: i64 = 0;
    loop {
        switch handles.pop() {
            Some(h) => {
                total = total + h.join();
            },
            _ => {
                break;
            },
        };
    }
    assert_eq(total, rounds);
    assert_eq(count(&strays), 0);
}

@test
fn a_timed_plain_thread_wait_ends_at_its_deadline() {
    let m = sync::Mutex::<i64>::new(0);
    let cv = sync::Condvar::new();
    let g = m.lock();
    let t0 = platform::now_ns();
    assert(cv.wait_until(&g, time::deadline_in(short())), "a timeout is a normal end of the wait");
    assert(platform::now_ns() - t0 >= 20000000, "the deadline was waited out");
    // A later notify finds no node: the timed-out wait unlinked its own.
    cv.notify_one();
    cv.notify_all();
}

// --- the parking lot ----------------------------------------------------------------------------------------.

const PARKED: i64 = 96;

@test
fn an_unpark_reaches_only_the_thread_parked_on_that_word() {
    // More threads than the lot has buckets, so several share every bucket; 64 bytes apart.
    let stride: usize = 16;
    let mut words = Vector::<i32>::with_capacity(PARKED as usize * stride);
    for _i in 0..PARKED as usize * stride {
        words.push(0);
    }
    let base = words.as_ptr() as usize;
    let acks = counter();
    let strays = counter();
    let mut handles = Vector::<thread::JoinHandle<i64>>::new();
    for t in 0..PARKED as usize {
        let addr = base + t * stride * sizeof(i32);
        let a = acks.clone();
        let s = strays.clone();
        handles.push(
            thread::spawn(
                fn() i64 {
                    let w = addr as *mut i32;
                    let mut served: i64 = 0;
                    loop {
                        while atomic::load_i32(w, 1) == 0 {
                            unsafe sc_runtime::sc_rt_park(w, 0, -1);
                            if atomic::load_i32(w, 1) == 0 {
                                let _ = s.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
                            }
                        }
                        let v = atomic::load_i32(w, 1);
                        atomic::store_i32(w, 0, 2);
                        if v == 2 {
                            return served;
                        }
                        served = served + 1;
                        let _ = a.get().fetch_add(1, atomics::MemoryOrder::Release);
                    }
                },
            ),
        );
    }
    let mut expected: i64 = 0;
    for _r in 0..3 {
        for t in 0..PARKED as usize {
            let w = (base + t * stride * sizeof(i32)) as *mut i32;
            atomic::store_i32(w, 1, 2);
            unsafe sc_runtime::sc_rt_unpark_one(w);
            expected = expected + 1;
            let deadline = platform::now_ns() + 5000000000;
            while count(&acks) < expected {
                assert(platform::now_ns() < deadline, "the parked thread is woken");
                unsafe sc_runtime::sc_rt_cpu_relax();
            }
        }
    }
    // A timed park on a word nobody unparks returns at its deadline and leaves no record behind.
    let t0 = platform::now_ns();
    let mut lone: i32 = 0;
    unsafe sc_runtime::sc_rt_park(&mut lone, 0, 20000000);
    assert(platform::now_ns() - t0 >= 20000000, "the timed park waited its deadline out");
    unsafe sc_runtime::sc_rt_unpark_all(&mut lone);
    let mut served: i64 = 0;
    for t in 0..PARKED as usize {
        let w = (base + t * stride * sizeof(i32)) as *mut i32;
        atomic::store_i32(w, 2, 2);
        unsafe sc_runtime::sc_rt_unpark_one(w);
    }
    loop {
        switch handles.pop() {
            Some(h) => {
                served = served + h.join();
            },
            _ => {
                break;
            },
        };
    }
    assert_eq(served, expected);
    assert_eq(count(&strays), 0);
}

@test
fn unpark_all_wakes_every_thread_on_the_word_and_no_other() {
    let stride: usize = 16;
    let mut words = Vector::<i32>::with_capacity(2 * stride);
    for _i in 0..2 * stride {
        words.push(0);
    }
    let base = words.as_ptr() as usize;
    let woke = counter();
    let strays = counter();
    let mut handles = Vector::<thread::JoinHandle<i64>>::new();
    for t in 0..6usize {
        // Three threads on each of two words.
        let addr = base + t % 2 * stride * sizeof(i32);
        let k = woke.clone();
        let s = strays.clone();
        handles.push(
            thread::spawn(
                fn() i64 {
                    let w = addr as *mut i32;
                    while atomic::load_i32(w, 1) == 0 {
                        unsafe sc_runtime::sc_rt_park(w, 0, -1);
                        if atomic::load_i32(w, 1) == 0 {
                            let _ = s.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
                        }
                    }
                    let _ = k.get().fetch_add(1, atomics::MemoryOrder::Release);
                    return 1;
                },
            ),
        );
    }
    rt::sleep_ns(50000000); // every thread parked
    let w0 = base as *mut i32;
    let w1 = (base + stride * sizeof(i32)) as *mut i32;
    atomic::store_i32(w0, 1, 2);
    unsafe sc_runtime::sc_rt_unpark_all(w0);
    let deadline = platform::now_ns() + 5000000000;
    while count(&woke) < 3 {
        assert(platform::now_ns() < deadline, "the three parked on the first word wake");
        rt::sleep_ns(100000);
    }
    rt::sleep_ns(20000000);
    assert_eq(count(&woke), 3); // the other three stay parked
    atomic::store_i32(w1, 1, 2);
    unsafe sc_runtime::sc_rt_unpark_all(w1);
    let mut n: i64 = 0;
    loop {
        switch handles.pop() {
            Some(h) => {
                n = n + h.join();
            },
            _ => {
                break;
            },
        };
    }
    assert_eq(n, 6);
    assert_eq(count(&strays), 0);
}

// --- cancellation at a batch boundary ------------------------------------------------------------------.

// A task cancelled while a batch WAITS for room keeps the items it has not sent, in order, and its cleanup
// destroys each of them exactly once. The delivered prefix belongs to the channel.
@test
fn a_cancelled_send_batch_keeps_its_remainder(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let ch = chan::Channel::<Payload>::bounded(2);
    let tx = ch.sender();
    let rx = ch.receiver();
    let sent = counter();
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let n = sent.clone();
    launch || {
        defer w.done();
        let _ = ktx.send(rt::current_key());
        let mut items = Vector::<Payload>::new();
        for i in 0..6 {
            items.push(Payload { n: i });
        }
        // Two fit; the rest wait for room that never comes, and the cancellation unwinds from there with
        // `items` still holding them. The vector is this frame's, so its cleanup frees them.
        let k = tx.send_batch(&mut items);
        n.get().store(k as i64, atomics::MemoryOrder::Release);
    };
    let key = krx.recv().unwrap();
    assert(ph::wait_parked(key), "the batch fills the ring and parks");
    assert(rt::request_cancel(key, rt::CR_USER), "the sender is live");
    assert(wg.wait_timeout(time::Duration::from_secs(5)), "the cancelled sender finishes");
    // Four unsent payloads were destroyed by the task's cleanup; two are still owned by the channel.
    assert(wait_frees(4), "the task's cleanup destroys the remainder");
    assert_eq(frees(), 4);
    for i in 0..2 {
        let got = rx.recv().unwrap();
        assert_eq(got.n, i);
    }
    rt::shutdown();
    assert_eq(frees(), 6);
    assert_eq(cancelled(fx), 1);
}

// A task cancelled while a batch WAITS for items takes nothing: a value sent afterwards is still there.
@test
fn a_cancelled_recv_batch_takes_nothing(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let ch = chan::Channel::<Payload>::bounded(2);
    let tx = ch.sender();
    let rx = ch.receiver();
    let _rx_keep = ch.receiver(); // keeps the channel open for sends after the task's handle drops
    let took = counter();
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let t = took.clone();
    launch || {
        defer w.done();
        let _ = ktx.send(rt::current_key());
        let mut out = Vector::<Payload>::new();
        // Parks: the ring is empty; cancelled while blocked.
        let k = rx.recv_batch(&mut out, 4);
        t.get().store(k as i64, atomics::MemoryOrder::Release);
    };
    let key = krx.recv().unwrap();
    assert(ph::wait_parked(key), "the receiver parks");
    assert(rt::request_cancel(key, rt::CR_USER), "the receiver is live");
    assert(wg.wait_timeout(time::Duration::from_secs(5)), "the cancelled receiver finishes");
    assert_eq(count(&took), 0);
    assert_eq(frees(), 0);
    // The cancelled batch took nothing, so a value sent now is the first one out.
    switch tx.send(Payload { n: 7 }) {
        Sent => {},
        Rejected(_v) => {
            assert(false, "the channel is still open");
        },
    };
    {
        let got = _rx_keep.recv().unwrap();
        assert_eq(got.n, 7);
    }
    rt::shutdown();
    assert_eq(frees(), 1);
    assert_eq(cancelled(fx), 1);
}
