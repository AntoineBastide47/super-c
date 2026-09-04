// Stuck-coroutine cancellation and reclamation: the verification cases from the reclamation plan.
// Every test starts its own scheduler, and must end with a successful runtime
// shutdown: the suite's SC_LEAK_CHECK=fatal gate then proves that reclamation left no coroutine-owned
// allocation behind.

import atomic;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::channel as chan;
import std::parallel::selector as selector;
import std::parallel::time as time;
import std::parallel::task as task;
import std::parallel::blocking as blocking;
import std::parallel::io as io;
import std::parallel::net as net;
import std::parallel::atomics as atomics;
import std::parallel::arc as arc;

// Exact-destruction counter: every `free` of a Payload bumps it, so a test can prove one cleanup per value.
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

// Code after a cancelled wait must never run: bumped there, asserted zero from the main thread.
static mut G_AFTER: i64 = 0;
// Tasks whose completion report (a defer) ran while the task was cancelling.
static mut G_UNWOUND: i64 = 0;

fn afters() i64 {
    return atomic::load_i64(&mut unsafe G_AFTER, 1);
}

fn unwounds() i64 {
    return atomic::load_i64(&mut unsafe G_UNWOUND, 1);
}

fn after_mark() {
    let _ = atomic::add_i64(&mut unsafe G_AFTER, 1, 0);
}

// The task's completion report, always installed as a `defer`: it runs on the normal exit AND on
// the compiled cancellation ladder, and records whether the task was unwinding when it fired.
fn finish(w: &sync::WaitGroup) {
    if rt::cancelling() {
        let _ = atomic::add_i64(&mut unsafe G_UNWOUND, 1, 0);
    }
    w.done();
}

// A helper frame on the task path: the compiled cancellation edge must unwind THROUGH it, running
// its defer once, freeing its owning local once, and never executing its post-wait code.
static mut G_HELPER_DEFERS: i64 = 0;

fn helper_defer(v: &Payload) {
    let _ = atomic::add_i64(&mut unsafe G_HELPER_DEFERS, 1, 0);
    let _ = v.n;
}

fn edge_helper(rx: &chan::Receiver<i64>) i64 {
    let local = Payload { n: 10 };
    defer helper_defer(&local);
    let got = rx.recv(); // parks; a cancellation unwinds from here
    after_mark();
    return got.unwrap_or(-1);
}

// The counters are process-lifetime values (the runtime's survive shutdown by contract), so a test
// starts from a zeroed file counter set and a recorded runtime baseline instead of a fresh process.
struct Base {
    pub cancelled: usize,
}

@test_init
fn fresh_counters() Base {
    atomic::store_i64(&mut unsafe G_FREES, 0, 0);
    atomic::store_i64(&mut unsafe G_AFTER, 0, 0);
    atomic::store_i64(&mut unsafe G_UNWOUND, 0, 0);
    atomic::store_i64(&mut unsafe G_HELPER_DEFERS, 0, 0);
    return Base { cancelled: rt::cancelled_tasks() };
}

fn cancelled(b: &Base) usize {
    return rt::cancelled_tasks() - b.cancelled;
}

fn short() time::Duration {
    return time::Duration::from_millis(20);
}

fn forever() time::Duration {
    return time::Duration::from_secs(30);
}

// --- cancellation of parked waits: one test per wait kind --------------------------------------------.

@test
fn sleep_cancel_wakes_and_reclaims(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch || {
        defer finish(&w);
        let _ = ktx.send(rt::current_key());
        time::sleep(forever()); // the compiled edge unwinds here on cancellation
        after_mark();
    };
    let key = krx.recv().unwrap();
    time::sleep(short()); // let it park
    assert(rt::request_cancel(key, rt::CR_USER), "the key names a live task");
    assert(wg.wait_timeout(time::Duration::from_secs(5)), "the cancelled sleeper finishes");
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
    // The defer saw the task cancelling.
    assert_eq(unwounds(), 1);
    // Nothing after the cancelled sleep ran.
    assert_eq(afters(), 0);
}

@test
fn edge_unwinds_through_helper_frames_exactly_once(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let ch = chan::Channel::<i64>::bounded(1);
    let rx = ch.receiver();
    let _tx_keep = ch.sender();
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch || {
        defer finish(&w);
        let outer = Payload { n: 1 }; // an owning local of the ROOT frame, freed by its ladder
        let _ = ktx.send(rt::current_key());
        let _r = edge_helper(&rx); // the edge unwinds the helper, then this frame
        after_mark();
        let _ = &outer;
    };
    let key = krx.recv().unwrap();
    time::sleep(short());
    assert(rt::request_cancel(key, rt::CR_USER), "the task is live");
    assert(wg.wait_timeout(time::Duration::from_secs(5)), "the cancelled task finishes");
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
    assert_eq(unwounds(), 1);
    // Neither frame ran past its cancelled wait.
    assert_eq(afters(), 0);
    // The helper defer ran exactly once.
    assert_eq(atomic::load_i64(&mut unsafe G_HELPER_DEFERS, 1), 1);
    // The helper local and the root local, once each.
    assert_eq(frees(), 2);
}

@test
fn request_cancel_is_idempotent(fx: &mut Base) {
    rt::set_worker_count(1);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    launch || {
        let _ = ktx.send(rt::current_key());
        time::sleep(forever());
    };
    let key = krx.recv().unwrap();
    time::sleep(short());
    assert(rt::request_cancel(key, rt::CR_USER), "first request lands");
    let _ = rt::request_cancel(key, rt::CR_POLICY); // later request changes nothing
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
}

@test
fn wait_group_cancel_leaves_count(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let gate = sync::WaitGroup::new(); // never completed by anyone
    gate.add(1);
    let g2 = gate.clone();
    let done = sync::WaitGroup::new();
    done.add(1);
    let d2 = done.clone();
    launch || {
        defer finish(&d2);
        let _ = ktx.send(rt::current_key());
        // Parks forever until cancelled; the edge unwinds here.
        g2.wait();
        after_mark();
    };
    let key = krx.recv().unwrap();
    time::sleep(short());
    assert(rt::request_cancel(key, rt::CR_USER), "the waiter is live");
    assert(done.wait_timeout(time::Duration::from_secs(5)), "the cancelled waiter finishes");
    // The count is untouched: only the waiter was removed.
    assert(!gate.wait_timeout(time::Duration::from_millis(5)), "the gate count survives the cancel");
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
    assert_eq(unwounds(), 1);
    assert_eq(afters(), 0);
}

@test
fn semaphore_cancel_consumes_no_permit(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let sem = sync::Semaphore::new(0);
    let s2 = sem.clone();
    let done = sync::WaitGroup::new();
    done.add(1);
    let d2 = done.clone();
    launch || {
        defer finish(&d2);
        let _ = ktx.send(rt::current_key());
        // Parks; cancelled before any permit exists; the edge unwinds here.
        s2.acquire();
        after_mark();
    };
    let key = krx.recv().unwrap();
    time::sleep(short());
    assert(rt::request_cancel(key, rt::CR_USER), "the waiter is live");
    assert(done.wait_timeout(time::Duration::from_secs(5)), "the cancelled waiter finishes");
    sem.release();
    assert(sem.try_acquire(), "the released permit was not consumed by the cancelled waiter");
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
    assert_eq(unwounds(), 1);
    assert_eq(afters(), 0);
}

@test
fn barrier_cancel_breaks_generation_and_reset_recovers(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let b = sync::Barrier::new(2);
    let b2 = b.clone();
    let done = sync::WaitGroup::new();
    done.add(1);
    let d2 = done.clone();
    launch || {
        let _ = ktx.send(rt::current_key());
        assert(!b2.wait(), "a cancelled barrier wait reports the break");
        assert(rt::cancelling(), "a cancelled barrier wait accepts");
        d2.done();
    };
    let key = krx.recv().unwrap();
    time::sleep(short());
    assert(rt::request_cancel(key, rt::CR_USER), "the participant is live");
    assert(done.wait_timeout(time::Duration::from_secs(5)), "the cancelled participant finishes");
    // The break is observed by every later waiter until an explicit reset.
    assert(!b.wait(), "a broken barrier rejects new arrivals");
    b.reset();
    let done2 = sync::WaitGroup::new();
    done2.add(1);
    let d3 = done2.clone();
    let b3 = b.clone();
    launch || {
        assert(b3.wait(), "a reset barrier completes its next generation");
        d3.done();
    };
    assert(b.wait(), "the second participant of the reset generation passes");
    assert(done2.wait_timeout(time::Duration::from_secs(5)), "the partner finishes");
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
}

@test
fn channel_send_cancel_keeps_payload_ownership(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let ch = chan::Channel::<Payload>::bounded(1);
    let tx = ch.sender();
    let rx = ch.receiver();
    let done = sync::WaitGroup::new();
    done.add(1);
    let d2 = done.clone();
    launch || {
        defer finish(&d2);
        let _ = ktx.send(rt::current_key());
        switch tx.send(Payload { n: 1 }) {
            Sent => {}, // fills the buffer
            Rejected(_v) => {
                assert(false, "the first send fits the buffer");
            },
        };
        // Parks: buffer full; cancelled while blocked. The channel hands the unsent payload back
        // and the compiled edge frees it exactly once through the spill, then unwinds.
        let _second = tx.send(Payload { n: 2 });
        after_mark();
    };
    let key = krx.recv().unwrap();
    time::sleep(short());
    assert(rt::request_cancel(key, rt::CR_USER), "the sender is live");
    assert(done.wait_timeout(time::Duration::from_secs(5)), "the cancelled sender finishes");
    // The unsent payload was freed exactly once; the buffered one is still owned by the channel.
    assert_eq(frees(), 1);
    switch rx.recv() {
        Some(_v) => {}, // the delivered payload is taken and freed at this arm's end
        None => {
            assert(false, "the delivered payload is still readable");
        },
    };
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
    assert_eq(unwounds(), 1);
    assert_eq(afters(), 0);
    // The received value was freed exactly once.
    assert_eq(frees(), 2);
}

@test
fn channel_recv_cancel_takes_nothing(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let ch = chan::Channel::<Payload>::bounded(1);
    let tx = ch.sender();
    let rx = ch.receiver();
    let _rx_keep = ch.receiver(); // keeps the channel open for sends after the task's handle drops
    let done = sync::WaitGroup::new();
    done.add(1);
    let d2 = done.clone();
    launch || {
        defer finish(&d2);
        let _ = ktx.send(rt::current_key());
        let _got = rx.recv(); // parks: empty channel; cancelled while blocked; the edge unwinds here
        after_mark();
    };
    let key = krx.recv().unwrap();
    time::sleep(short());
    assert(rt::request_cancel(key, rt::CR_USER), "the receiver is live");
    assert(done.wait_timeout(time::Duration::from_secs(5)), "the cancelled receiver finishes");
    // A value sent afterwards stays in the channel (the cancelled receive took nothing).
    let sr = tx.send(Payload { n: 3 });
    switch sr {
        Sent => {},
        Rejected(_v) => {
            assert(false, "the channel is still open");
        },
    };
    assert_eq(frees(), 0);
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
    assert_eq(unwounds(), 1);
    assert_eq(afters(), 0);
}

@test
fn select_cancel_unregisters_every_arm(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let a = chan::Channel::<i64>::bounded(1);
    let b = chan::Channel::<i64>::bounded(1);
    let arx = a.receiver();
    let brx = b.receiver();
    let atx = a.sender();
    let btx = b.sender();
    let done = sync::WaitGroup::new();
    done.add(1);
    let d2 = done.clone();
    launch || {
        defer finish(&d2);
        let _ = ktx.send(rt::current_key());
        let mut s = selector::Selector::new();
        let _ = s.arm_recv(&arx);
        let _ = s.arm_recv(&brx);
        // Parks on both queues under one token; cancelled while parked. Every arm is unregistered
        // (in the stable lock order) before the edge unwinds this frame.
        let _hit = s.wait();
        after_mark();
    };
    let key = krx.recv().unwrap();
    time::sleep(short());
    assert(rt::request_cancel(key, rt::CR_USER), "the selector task is live");
    assert(done.wait_timeout(time::Duration::from_secs(5)), "the cancelled select finishes");
    // Both queues are clean: sends after the cancel park nobody and deliver normally.
    let _ = atx.send(1);
    let _ = btx.send(2);
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
    assert_eq(unwounds(), 1);
    assert_eq(afters(), 0);
}

@test
fn mutex_lock_c_cancel_never_returns_a_guard(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let m = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let m2 = m.clone();
    let hold = sync::WaitGroup::new(); // released once the test wants the lock free again
    hold.add(1);
    let h2 = hold.clone();
    let holding = sync::WaitGroup::new();
    holding.add(1);
    let hg = holding.clone();
    launch || {
        let _g = m2.get().lock();
        hg.done();
        // Owns the lock until the main thread says otherwise.
        h2.wait();
    };
    holding.wait();
    let m3 = m.clone();
    let done = sync::WaitGroup::new();
    done.add(1);
    let d2 = done.clone();
    launch || {
        defer finish(&d2);
        let _ = ktx.send(rt::current_key());
        let _got = m3.get().lock_c(); // parks behind the holder; the edge unwinds here on cancellation
        after_mark();
    };
    let key = krx.recv().unwrap();
    time::sleep(short());
    assert(rt::request_cancel(key, rt::CR_USER), "the lock waiter is live");
    assert(done.wait_timeout(time::Duration::from_secs(5)), "the cancelled waiter finishes");
    // Release the holder; the lock must be fully functional afterwards.
    hold.done();
    time::sleep(short());
    {
        let g = m.get().lock();
        assert_eq(*g.get(), 0);
    }
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
    assert_eq(unwounds(), 1);
    // No guard reached the cancelled waiter's frame.
    assert_eq(afters(), 0);
}

@test
fn mutex_unlock_passes_over_a_cancelled_waiter(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let m = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let hold = sync::WaitGroup::new();
    hold.add(1);
    let holding = sync::WaitGroup::new();
    holding.add(1);
    let m2 = m.clone();
    let h2 = hold.clone();
    let hg = holding.clone();
    launch || {
        let _g = m2.get().lock();
        hg.done();
        h2.wait();
    };
    holding.wait();
    // Two queued waiters: the first is cancelled, the second must still get the release.
    let m3 = m.clone();
    let done_c = sync::WaitGroup::new();
    done_c.add(1);
    let dc = done_c.clone();
    launch || {
        defer finish(&dc);
        let _ = ktx.send(rt::current_key());
        let _got = m3.get().lock_c(); // the first queued waiter; the edge unwinds here on cancellation
        after_mark();
    };
    let key = krx.recv().unwrap();
    time::sleep(short());
    let m4 = m.clone();
    let done_n = sync::WaitGroup::new();
    done_n.add(1);
    let dn = done_n.clone();
    launch || {
        let mut g = m4.get().lock(); // a normal waiter behind the cancelled one
        *g.get_mut() = 7;
        dn.done();
    };
    time::sleep(short());
    assert(rt::request_cancel(key, rt::CR_USER), "the first waiter is live");
    assert(done_c.wait_timeout(time::Duration::from_secs(5)), "the cancelled waiter finishes");
    // The release must reach the surviving waiter, not die on the cancelled one.
    hold.done();
    assert(done_n.wait_timeout(time::Duration::from_secs(5)), "the surviving waiter acquires");
    {
        let g = m.get().lock();
        assert_eq(*g.get(), 7);
    }
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
    assert_eq(unwounds(), 1);
    assert_eq(afters(), 0);
}

@test
fn rwlock_write_c_cancel_restores_writer_count(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let l = arc::Arc::<sync::RwLock<i64>>::new(sync::RwLock::<i64>::new(0));
    let hold = sync::WaitGroup::new();
    hold.add(1);
    let holding = sync::WaitGroup::new();
    holding.add(1);
    let l2 = l.clone();
    let h2 = hold.clone();
    let hg = holding.clone();
    launch || {
        let _g = l2.get().read(); // a reader keeps the writer queued
        hg.done();
        h2.wait();
    };
    holding.wait();
    let l3 = l.clone();
    let done = sync::WaitGroup::new();
    done.add(1);
    let d2 = done.clone();
    launch || {
        defer finish(&d2);
        let _ = ktx.send(rt::current_key());
        let _got = l3.get().write_c(); // queues as a writer; the edge unwinds here on cancellation
        after_mark();
    };
    let key = krx.recv().unwrap();
    time::sleep(short());
    assert(rt::request_cancel(key, rt::CR_USER), "the writer is live");
    assert(done.wait_timeout(time::Duration::from_secs(5)), "the cancelled writer finishes");
    time::sleep(short());
    // The queued-writer count went back down: new readers are admitted again.
    let r = l.get().try_read();
    assert(r.is_some(), "no phantom writer blocks readers after the cancel");
    hold.done();
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
    assert_eq(unwounds(), 1);
    // No guard reached the cancelled writer's frame.
    assert_eq(afters(), 0);
}

// --- blocking pool: heap-owned results and abandonment ------------------------------------------------.

@test
fn blocking_call_c_cancel_abandons_job(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let done = sync::WaitGroup::new();
    done.add(1);
    let d2 = done.clone();
    launch || {
        defer finish(&d2);
        let _ = ktx.send(rt::current_key());
        let _got = blocking::call_c(
            fn() Payload {
                // A genuinely blocking body: the pool thread sleeps through the cancellation.
                time::sleep(time::Duration::from_millis(150));
                return Payload { n: 9 };
            },
        );
        after_mark();
    };
    let key = krx.recv().unwrap();
    time::sleep(short());
    assert(rt::request_cancel(key, rt::CR_USER), "the blocked caller is live");
    assert(done.wait_timeout(time::Duration::from_secs(5)), "the cancelled caller finishes");
    // The blocking body is NOT stopped: it returns later and the pool worker frees the unclaimed result
    // exactly once. Joining the pool bounds that.
    blocking::shutdown();
    assert_eq(frees(), 1);
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
    assert_eq(unwounds(), 1);
    assert_eq(afters(), 0);
}

@test
fn blocking_completion_races_cancel_to_one_owner(_fx: &mut Base) {
    rt::set_worker_count(2);
    // Repeated short calls with a racing cancel: whichever side wins, the value is freed exactly once.
    let rounds: i64 = 20;
    for i in 0..rounds {
        let kch = chan::Channel::<rt::TaskKey>::bounded(1);
        let ktx = kch.sender();
        let krx = kch.receiver();
        let done = sync::WaitGroup::new();
        done.add(1);
        let d2 = done.clone();
        launch || {
            defer finish(&d2);
            let _ = ktx.send(rt::current_key());
            // Completion or cancel wins the race; either way exactly one owner frees the payload:
            // the spill on the unwind path, this scope on the normal path, or the pool worker for
            // an abandoned result.
            let _got = blocking::call_c(
                fn() Payload {
                    return Payload { n: 1 };
                },
            );
        };
        let key = krx.recv().unwrap();
        if i % 2 == 0 {
            time::sleep(time::Duration::from_micros(50));
        }
        let _ = rt::request_cancel(key, rt::CR_USER);
        assert(done.wait_timeout(time::Duration::from_secs(5)), "the racer finishes");
    }
    blocking::shutdown();
    // One free per round, from exactly one owner.
    assert_eq(frees(), rounds);
    rt::shutdown();
}

// --- I/O: reactor interests and cancellation ----------------------------------------------------------.

@test
fn io_read_cancel_settles_interest(fx: &mut Base) {
    rt::set_worker_count(2);
    let listener = net::TcpListener::bind("127.0.0.1", 0).unwrap();
    let port = listener.port();
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let done = sync::WaitGroup::new();
    done.add(1);
    let d2 = done.clone();
    launch || {
        defer finish(&d2);
        switch listener.accept() {
            Ok(s) => {
                let _ = ktx.send(rt::current_key());
                let mut buf = Vector::<u8>::new();
                for _k in 0..16 {
                    buf.push(0u8);
                }
                let cap: usize = 16;
                // Parks on the reactor; no data ever comes. The interest is settled and the edge
                // unwinds this frame (closing the stream on the way out).
                let _n = s.read(buf.index_range_mut(0..cap));
                after_mark();
            },
            Err(_) => {
                assert(false, "accept succeeds");
            },
        };
    };
    let peer = net::TcpStream::connect("127.0.0.1", port).unwrap();
    let key = krx.recv().unwrap();
    time::sleep(short()); // let the reader arm its interest
    assert(rt::request_cancel(key, rt::CR_USER), "the reader is live");
    assert(done.wait_timeout(time::Duration::from_secs(5)), "the cancelled reader finishes");
    let msg: [u8; 2] = [1u8, 2u8];
    let _ = peer.write(msg); // the socket still works; nothing dangles on the reactor
    io::shutdown();
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
    assert_eq(unwounds(), 1);
    assert_eq(afters(), 0);
}

// --- pairwise races -----------------------------------------------------------------------------------.

@test
fn notify_races_cancel_single_winner(fx: &mut Base) {
    rt::set_worker_count(2);
    let rounds: i64 = 30;
    let mut cancelled_total: usize = 0;
    for i in 0..rounds {
        let kch = chan::Channel::<rt::TaskKey>::bounded(1);
        let ktx = kch.sender();
        let krx = kch.receiver();
        let ch = chan::Channel::<i64>::bounded(1);
        let tx = ch.sender();
        let rx = ch.receiver();
        let done = sync::WaitGroup::new();
        done.add(1);
        let d2 = done.clone();
        launch || {
            defer d2.done();
            let _ = ktx.send(rt::current_key());
            let got = rx.recv(); // notify and cancel race for this park
            switch got {
                Some(_v) => {}, // the notify won; the pending cancel is observed later
                None => {
                    assert(rt::cancelling(), "no value means the cancel won");
                },
            };
        };
        let key = krx.recv().unwrap();
        if i % 3 == 0 {
            time::sleep(time::Duration::from_micros(200));
        }
        let _ = tx.send(i);
        let _ = rt::request_cancel(key, rt::CR_USER);
        assert(done.wait_timeout(time::Duration::from_secs(5)), "the racer finishes exactly once");
    }
    cancelled_total = cancelled(fx);
    assert(cancelled_total <= rounds as usize, "at most one outcome per round");
    rt::shutdown();
}

@test
fn timeout_races_cancel_single_winner(_fx: &mut Base) {
    rt::set_worker_count(2);
    let rounds: i64 = 30;
    for _i in 0..rounds {
        let kch = chan::Channel::<rt::TaskKey>::bounded(1);
        let ktx = kch.sender();
        let krx = kch.receiver();
        let gate = sync::WaitGroup::new();
        gate.add(1);
        let g2 = gate.clone();
        let done = sync::WaitGroup::new();
        done.add(1);
        let d2 = done.clone();
        launch || {
            defer finish(&d2);
            let _ = ktx.send(rt::current_key());
            // The deadline races the cancel through the same single-winner claim; either winner
            // finishes the round exactly once (a cancel win unwinds through the defer).
            let _ok = g2.wait_timeout(time::Duration::from_millis(1));
        };
        let key = krx.recv().unwrap();
        time::sleep(time::Duration::from_millis(1)); // land the request right at the deadline
        let _ = rt::request_cancel(key, rt::CR_USER);
        assert(done.wait_timeout(time::Duration::from_secs(5)), "the racer finishes exactly once");
        // Reset for leak-freedom (the group is dropped each round).
        gate.done();
    }
    rt::shutdown();
}

@test
fn completion_races_cancel_to_one_outcome(_fx: &mut Base) {
    rt::set_worker_count(2);
    let rounds: i64 = 40;
    for _i in 0..rounds {
        let mut g = task::TaskGroup::new();
        g.spawn(|| {});
        // May land before, during, or after the (instant) body.
        g.cancel();
        let report = g.join();
        assert_eq(report.completed + report.cancelled, 1);
        assert_eq(report.unresponsive, 0);
    }
    rt::shutdown();
}

@test
fn stale_key_cannot_touch_a_recycled_task(fx: &mut Base) {
    rt::set_worker_count(1);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch || {
        let _ = ktx.send(rt::current_key());
        w.done();
    };
    let stale = krx.recv().unwrap();
    wg.wait();
    time::sleep(short()); // let the block retire into the pool
    // Recycle the block through fresh tasks; the stale key must never reach any of them.
    let wg2 = sync::WaitGroup::new();
    wg2.add(8);
    for _i in 0..8 {
        let w2 = wg2.clone();
        launch || {
            time::sleep(time::Duration::from_millis(2));
            w2.done();
        };
        let _ = rt::request_cancel(stale, rt::CR_USER);
    }
    wg2.wait();
    rt::shutdown();
    // Nothing was cancelled by the stale key.
    assert_eq(cancelled(fx), 0);
}

@test
fn shutdown_races_spawn_and_rejects_new_tasks(_fx: &mut Base) {
    rt::set_worker_count(2);
    launch || {
        time::sleep(time::Duration::from_millis(1));
    };
    let mut opts = rt::ShutdownOptions::defaults();
    opts.grace_ns = 2000000000;
    let res = rt::try_shutdown(opts);
    assert_eq(res.unresponsive, 0);
    // The runtime is destroyed and closed-flag cleared; the counters survive for inspection.
    launch || {
        // A post-shutdown launch restarts the pool by contract; make it finish before the final check.
        time::sleep(time::Duration::from_millis(1));
    };
    rt::shutdown();
}

@test
fn closed_runtime_frees_rejected_closures(fx: &mut Base) {
    rt::set_worker_count(2);
    let gate = sync::WaitGroup::new();
    gate.add(1);
    let g2 = gate.clone();
    launch || {
        rt::cancel_mask_enter();
        // Masked: shutdown cannot cancel this wait.
        g2.wait();
        rt::cancel_mask_exit();
    };
    time::sleep(short());
    let mut opts = rt::ShutdownOptions::defaults();
    opts.grace_ns = 50000000;
    opts.report_unresponsive = false;
    let res = rt::try_shutdown(opts);
    // The masked waiter cannot be reclaimed.
    assert_eq(res.unresponsive, 1);
    // The runtime is still alive and closed: a new submission is rejected and its captures freed.
    let p = Payload { n: 5 };
    launch || {
        // `p` is an owned capture.
        assert(p.n != 5, "a closed runtime must not run new tasks");
    };
    assert_eq(frees(), 1);
    // Unblock the masked waiter; it completes normally.
    gate.done();
    time::sleep(short());
    let res2 = rt::try_shutdown(rt::ShutdownOptions::defaults());
    assert_eq(res2.unresponsive, 0);
    // The masked task was never cancelled, only reported.
    assert_eq(cancelled(fx), 0);
}

@test
fn snapshot_names_wait_kind_and_masked_state(_fx: &mut Base) {
    rt::set_worker_count(1);
    let gate = sync::WaitGroup::new();
    gate.add(1);
    let g2 = gate.clone();
    launch || {
        g2.wait();
    };
    time::sleep(short());
    let mut rows = Vector::<rt::TaskInfo>::new();
    rt::task_snapshot(&mut rows);
    assert_eq(rows.len(), 1);
    assert_eq(rows.at(0).wait_kind, rt::WK_WAIT_GROUP);
    assert(!rows.at(0).masked, "an ordinary wait is cancellable");
    gate.done();
    rt::shutdown();
}

@test
fn cancel_point_stops_a_compute_task(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let done = sync::WaitGroup::new();
    done.add(1);
    let d2 = done.clone();
    launch || {
        // The combined loop safepoint can accept and unwind before the explicit point does, so the
        // completion report is a defer: it runs on either exit.
        defer finish(&d2);
        let _ = ktx.send(rt::current_key());
        let mut spins: i64 = 0;
        while !rt::cancel_point() {
            spins = spins + 1;
            rt::yield_now();
        }
        assert(rt::cancelling(), "cancel_point accepted the request");
    };
    let key = krx.recv().unwrap();
    time::sleep(short());
    assert(rt::request_cancel(key, rt::CR_USER), "the spinner is live");
    assert(done.wait_timeout(time::Duration::from_secs(5)), "the spinner stops at a cancellation point");
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
}

@test
fn safepoint_cancels_a_compute_loop(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    let done = sync::WaitGroup::new();
    done.add(1);
    let d2 = done.clone();
    launch || {
        defer finish(&d2);
        let held = Payload { n: 3 }; // an owning local the safepoint ladder must free
        let _ = ktx.send(rt::current_key());
        // A compute loop with NO wait and NO explicit cancellation point: only the combined loop
        // safepoint can stop it. The xorshift state never reaches zero from a nonzero
        // seed, so cancellation is the loop's only exit.
        let mut x: u64 = 88172645463325252;
        loop {
            x = x ^ x << 13;
            x = x ^ x >> 7;
            x = x ^ x << 17;
            if x == 0 {
                break;
            }
        }
        after_mark();
        let _ = &held;
    };
    let key = krx.recv().unwrap();
    time::sleep(short());
    assert(rt::request_cancel(key, rt::CR_USER), "the compute task is live");
    assert(done.wait_timeout(time::Duration::from_secs(5)), "the safepoint stops the compute loop");
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
    assert_eq(unwounds(), 1);
    // Nothing after the cancelled loop ran.
    assert_eq(afters(), 0);
    // The ladder freed the owning local exactly once.
    assert_eq(frees(), 1);
}

@test
fn mask_defers_cancellation_until_exit(fx: &mut Base) {
    rt::set_worker_count(2);
    let kch = chan::Channel::<rt::TaskKey>::bounded(1);
    let ktx = kch.sender();
    let krx = kch.receiver();
    // main -> task: released only after the cancel has been requested, so the request is guaranteed
    // pending before the mask lifts. This orders the two threads without a timing guess.
    let rch = chan::Channel::<i32>::bounded(1);
    let rtx = rch.sender();
    let rrx = rch.receiver();
    let done = sync::WaitGroup::new();
    done.add(1);
    let d2 = done.clone();
    launch || {
        let _ = ktx.send(rt::current_key());
        rt::cancel_mask_enter();
        let _ = rrx.recv(); // a masked park: the pending cancel must not claim it
        assert(!rt::cancelling(), "a masked park is never cancelled");
        rt::cancel_mask_exit();
        assert(rt::cancel_point(), "the pending request is accepted after the mask lifts");
        d2.done();
    };
    let key = krx.recv().unwrap();
    assert(rt::request_cancel(key, rt::CR_USER), "the masked task is live");
    let _ = rtx.send(1); // release the masked park now that the cancel is pending
    assert(done.wait_timeout(time::Duration::from_secs(5)), "the masked task finishes");
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
}

// --- task groups and sources --------------------------------------------------------------------------.

@test
fn group_cancel_reclaims_children_at_any_worker_count(_fx: &mut Base) {
    let counts: [usize; 3] = [1usize, 2usize, 4usize];
    // One worker count per forked test would triple the file; the pool is rebuilt between rounds
    // through a full shutdown, which is itself part of what the plan verifies.
    for i in 0..3 {
        rt::set_worker_count(unsafe counts[i]);
        let mut g = task::TaskGroup::new();
        for _k in 0..6 {
            g.spawn(
                || {
                    time::sleep(forever());
                },
            );
        }
        time::sleep(short());
        g.cancel();
        let report = g.join();
        assert_eq(report.cancelled, 6);
        assert_eq(report.completed, 0);
        assert_eq(report.unresponsive, 0);
        rt::shutdown(); // destroys the pool so the next round can change the worker count
    }
}

@test
fn group_drop_leaves_no_child(fx: &mut Base) {
    rt::set_worker_count(2);
    {
        let mut g = task::TaskGroup::new();
        for _k in 0..4 {
            g.spawn(
                || {
                    time::sleep(forever());
                },
            );
        }
        time::sleep(short());
        // The group goes out of scope here: its drop cancels and joins every child.
    }
    rt::shutdown();
    assert_eq(cancelled(fx), 4);
    assert_eq(rt::live_tasks(), 0);
}

@test
fn token_observes_source_and_late_binding_cancels(fx: &mut Base) {
    rt::set_worker_count(2);
    let (src, tok) = task::CancelSource::new();
    assert(!tok.is_cancelled());
    src.cancel(rt::CR_USER);
    assert(tok.is_cancelled());
    // A task that binds AFTER the cancel is cancelled at registration.
    let t2 = src.token();
    let done = sync::WaitGroup::new();
    done.add(1);
    let d2 = done.clone();
    launch || {
        defer finish(&d2);
        t2.bind_current();
        time::sleep(forever()); // claimed immediately: the request landed at bind time
        after_mark();
    };
    assert(done.wait_timeout(time::Duration::from_secs(5)), "the late-bound task is reclaimed");
    rt::shutdown();
    assert_eq(cancelled(fx), 1);
    assert_eq(unwounds(), 1);
    assert_eq(afters(), 0);
}

@test
fn shutdown_cancels_detached_sleepers(_fx: &mut Base) {
    rt::set_worker_count(2);
    for _k in 0..3 {
        launch || {
            time::sleep(forever());
        };
    }
    time::sleep(short());
    let res = rt::try_shutdown(rt::ShutdownOptions::defaults());
    assert_eq(res.unresponsive, 0);
    // Runtime shutdown owns detached tasks.
    assert_eq(res.cancelled, 3);
}
