// Micro-benchmarks: one primitive per lane, one distribution each. These are the numbers a regression shows
// up in first: a macro benchmark tells you something got slower, a micro benchmark tells you what.
//
// Every lane reports per-operation cost via `b.each(N)`, so the figure is comparable across runs whatever
// the round size, and every lane whose work can be counted VALIDATES it (`b.tally`): a channel lane that
// silently delivered nothing would otherwise report a wonderful number for doing no work, which is the one
// way a benchmark can lie outright. Where a lane needs more than one task it uses a WaitGroup rather than
// sleeping, so the measurement is the primitive and not a timer.
//
// One lane the runtime cannot yet report is NOT here, and deliberately: steals per task and idle-worker
// latency. The scheduler keeps no steal counter, and adding one means an atomic increment on the steal
// path: paying for the metric in the thing being measured. It wants a counter compiled in only under a
// flag, which is its own change.
//
// Task counts here are FIXED rather than taken from `worker_count()`: a lane whose round size depends on the
// machine cannot be compared between two machines, or against its own history on a different box.

import atomic;
import stdlib;
import sc_runtime;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::channel as chan;
import std::parallel::data as data;
import std::parallel::atomics as atomics;
import std::parallel::arc as arc;
import std::parallel::platform as platform;
import std::parallel::blocking as blocking;
import std::parallel::selector as selector;
import std::parallel::thread as thread;
import std::testing::bench as bench;
import std::testing::bench_sys as sys;

const SPAWNS: i64 = 2000; // tasks per round for the spawn lanes
const LATENCY_SPAWNS: i64 = 500; // one-at-a-time spawns per round for the latency lane
const OPS: i64 = 20000; // operations per round for the uncontended lanes
const MSGS: i64 = 5000; // messages per round for the channel lanes
const CHANNELS: i64 = 20000; // channels built and dropped per round in the construction lane
const PRODUCERS: i64 = 4; // producers in the MPMC lane: FIXED, comparable across machines
const CONSUMERS: i64 = 4; // consumers in the MPMC lane
const PARK_THREADS: i64 = 128; // plain threads parked at once in the parking-lot lane: past the bucket count
const PARK_ROUNDS: i64 = 20; // unparks of every thread per round
const HAMMER: i64 = 2000; // per-task operations in the contended lanes
const LOCKERS: i64 = 8; // tasks in the contended lock lane: FIXED, so the number compares across machines
const FANIN_TASKS: i64 = 8; // signallers in the fan-in lane
const FANIN_EACH: i64 = 20000; // `done` calls each, so spawn cost is a rounding error next to them
const DISPATCHES: i64 = 200; // `parallel::range` calls per round
const SPAN: usize = 256; // iterations per dispatch: small, so what is measured is the dispatch
const ALLOCS: i64 = 20000; // malloc/free pairs per round in the allocator lane
const DEEP_TASKS: i64 = 500; // tasks per round in the deep-stack lane
const BCALLS: i64 = 2000; // blocking calls per round in the round-trip lane
const BFAN_TASKS: i64 = 8; // tasks calling at once in the blocking fan-out lane: FIXED, comparable across machines
const BFAN_EACH: i64 = 250; // calls each
const LAT_ROUNDS: usize = 110; // rounds a latency sink is sized for: the default plus warm-up and diagnostics
const DEEP_FRAMES: u64 = 1500; // frames of at least 80 bytes each: past 100 KiB of the default stack
const CLEANUP_WAIT_NS: u64 = 5000000000; // how long spawn_to_completion waits for the runtime to retire its tasks

// --- spawn ------------------------------------------------------------------------------------------.

// Wait until the runtime has RETIRED `n` more tasks than `base`: completed, their blocks recycled. Bounded;
// false when the wait ran out, which is a runtime defect the lane must report.
fn wait_retired(base: usize, n: usize) bool {
    let deadline = platform::now_ns() + CLEANUP_WAIT_NS;
    while rt::completed_tasks() - base < n {
        if platform::now_ns() > deadline {
            return false;
        }
        unsafe sc_runtime::sc_rt_cpu_relax();
    }
    return true;
}

/// What one `launch` costs end to end: the task is created, scheduled, run, and RETIRED by the runtime
/// (its block recycled and its completion counted), which is later than the WaitGroup's `done` inside it.
/// This is the number a fan-out is made of, so it bounds every other coroutine lane.
@bench
pub fn spawn_to_completion(b: &mut bench::Bencher) {
    b.each(SPAWNS);
    b.unit("task");
    while b.running() {
        let base = rt::completed_tasks();
        let wg = sync::WaitGroup::new();
        wg.add(SPAWNS);
        for _i in 0..SPAWNS {
            let w = wg.clone();
            launch || {
                w.done();
            };
        }
        wg.wait();
        let retired = wait_retired(base, SPAWNS as usize);
        b.tally(
            SPAWNS,
            if retired {
                SPAWNS;
            } else {
                0i64;
            },
        );
        if !retired {
            bench::fail("spawn_to_completion: the runtime did not retire every task within the wait");
        }
    }
}

// The moment the latency lane's task first ran, published by the task and read by the launcher.
static mut G_FIRST_RUN: u64 = 0;

/// Spawn-to-FIRST-RUN latency: the launcher notes the clock, launches one task, and the task's first
/// instruction notes the clock again; the difference is what the scheduler took to get it running, with no
/// backlog to pipeline behind. The per-spawn distribution is the note; the round time is the loop.
@bench
pub fn spawn_latency(b: &mut bench::Bencher) {
    b.each(LATENCY_SPAWNS);
    b.unit("task");
    let mut lat = Vector::<f64>::new();
    while b.running() {
        for _i in 0..LATENCY_SPAWNS {
            let wg = sync::WaitGroup::new();
            wg.add(1);
            let w = wg.clone();
            let t0 = platform::now_ns();
            launch || {
                atomic::store_u64(&mut unsafe G_FIRST_RUN, platform::now_ns(), 2);
                w.done();
            };
            wg.wait();
            let t1 = atomic::load_u64(&mut unsafe G_FIRST_RUN, 1);
            lat.push((t1 - t0) as f64);
        }
        b.tally(LATENCY_SPAWNS, LATENCY_SPAWNS);
    }
    let sm = bench::summarize(&mut lat);
    let mut note = String::from_str("first run after launch: median ");
    note.push_f64_prec(sm.median, 0);
    note.push_str(" ns, p95 ");
    note.push_f64_prec(sm.p95, 0);
    note.push_str(" ns, p99 ");
    note.push_f64_prec(sm.p99, 0);
    note.push_str(" ns (");
    note.push_u64(sm.n as u64);
    note.push_str(" spawns)");
    b.note(note.as_str());
}

// --- park / unpark ----------------------------------------------------------------------------------.

/// A park/unpark ROUND TRIP between two COROUTINES: both ends are launched tasks, so every message parks
/// one task and wakes the other on the scheduler (the launcher only waits for both). This is the
/// context-switch cost as a program pays it: the raw register swap is a fraction of it; the rest is
/// the scheduler.
@bench
pub fn park_unpark_roundtrip(b: &mut bench::Bencher) {
    let trips: i64 = 2000;
    b.each(trips);
    b.unit("trip");
    let seen = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    while b.running() {
        let there = chan::Channel::<i64>::bounded(1);
        let back = chan::Channel::<i64>::bounded(1);
        let rx = there.receiver();
        let tx2 = back.sender();
        let tx = there.sender(); // before the echo task starts: see the note in `channel_lane`
        let rx2 = back.receiver();
        let n = trips;
        // Wait for both tasks before freeing the channels they hold: a task still parked in `recv` when
        // its channel is freed points at released memory.
        let wg = sync::WaitGroup::new();
        wg.add(2);
        let w1 = wg.clone();
        let w2 = wg.clone();
        let c = seen.clone();
        launch || {
            for _i in 0..n {
                switch rx.recv() {
                    Some(v) => {
                        let _ = tx2.send(v);
                    },
                    None => {
                        break;
                    },
                };
            }
            w1.done();
        };
        launch || {
            let mut got: i64 = 0;
            for i in 0..n {
                let _ = tx.send(i);
                switch rx2.recv() {
                    Some(v) => {
                        if v == i {
                            got = got + 1;
                        }
                    },
                    None => {
                        break;
                    },
                };
            }
            tx.close();
            c.get().store(got, atomics::MemoryOrder::Release);
            w2.done();
        };
        wg.wait();
        b.tally(trips, seen.get().load(atomics::MemoryOrder::Acquire));
    }
}

// --- blocking calls ---------------------------------------------------------------------------------.

// `n` blocking calls of an empty closure from one task, one after the other; how many returned their
// value, and each call's round trip in microseconds appended to `lat`.
fn call_chain(n: i64, lat: &mut Vector<f64>) i64 {
    let mut got: i64 = 0;
    for _i in 0..n {
        let t0 = platform::now_ns();
        got = got + blocking::call(
            fn() i64 {
                return 1i64;
            },
        );
        lat.push((platform::now_ns() - t0) as f64 / 1000.0);
    }
    return got;
}

// The per-call latencies of a lane, gathered from its tasks once each so the timed loop pays no lock.
type LatSink = arc::Arc<sync::Mutex<Vector<f64>>>;

fn lat_sink(cap: usize) LatSink {
    return arc::Arc::<sync::Mutex<Vector<f64>>>::new(sync::Mutex::<Vector<f64>>::new(Vector::<f64>::with_capacity(cap)));
}

fn lat_merge(sink: &LatSink, lat: &Vector<f64>) {
    let mut g = sink.get().lock();
    let v = g.get_mut();
    for i in 0..lat.len() {
        v.push(lat[i]);
    }
}

fn lat_note(b: &mut bench::Bencher, sink: &LatSink, name: str) {
    let mut g = sink.get().lock();
    let t = bench::dist_text(name, "us", g.get_mut());
    b.note_more(t.as_str());
}

/// A blocking-call ROUND TRIP: one task hands an empty closure to the blocking pool and parks until the
/// value comes back, BCALLS times in a row. Nothing blocks, so this is the dispatch itself: the submission,
/// the pool thread's wake, the result's return and the task's wake, with no work to hide any of it behind.
@bench
pub fn blocking_roundtrip(b: &mut bench::Bencher) {
    b.each(BCALLS);
    b.unit("call");
    let seen = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let sink = lat_sink(LAT_ROUNDS * BCALLS as usize);
    while b.running() {
        let wg = sync::WaitGroup::new();
        wg.add(1);
        let w = wg.clone();
        let c = seen.clone();
        let k = sink.clone();
        launch || {
            let mut lat = Vector::<f64>::with_capacity(BCALLS as usize);
            c.get().store(call_chain(BCALLS, &mut lat), atomics::MemoryOrder::Release);
            lat_merge(&k, &lat);
            w.done();
        };
        wg.wait();
        b.tally(BCALLS, seen.get().load(atomics::MemoryOrder::Acquire));
    }
    lat_note(b, &sink, "call latency");
}

/// The same round trip from BFAN_TASKS tasks at once: what the pool's submission path costs when several
/// workers hand work over at the same time, and how the pool threads share it.
@bench
pub fn blocking_fanout(b: &mut bench::Bencher) {
    let calls = BFAN_TASKS * BFAN_EACH;
    b.each(calls);
    b.unit("call");
    let seen = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let sink = lat_sink(LAT_ROUNDS * calls as usize);
    while b.running() {
        seen.get().store(0, atomics::MemoryOrder::Release);
        let wg = sync::WaitGroup::new();
        wg.add(BFAN_TASKS);
        for _t in 0..BFAN_TASKS {
            let w = wg.clone();
            let c = seen.clone();
            let k = sink.clone();
            launch || {
                let mut lat = Vector::<f64>::with_capacity(BFAN_EACH as usize);
                let _ = c.get().fetch_add(call_chain(BFAN_EACH, &mut lat), atomics::MemoryOrder::Relaxed);
                lat_merge(&k, &lat);
                w.done();
            };
        }
        wg.wait();
        b.tally(calls, seen.get().load(atomics::MemoryOrder::Acquire));
    }
    lat_note(b, &sink, "call latency");
}

// Scheduler parks and wakes over a lane, per work unit: what the coordination under test cost the
// scheduler, which the per-operation time alone does not separate from the work itself. Reported only when
// the runtime was built with its counters compiled in (`RT_STATS` in std/parallel/runtime.spc), so an
// ordinary run says nothing and pays nothing.
fn sched_note(b: &mut bench::Bencher, s0: &rt::SchedStats, units: i64, rounds: i64, unit: str) {
    if !rt::sched_stats_on() || rounds <= 0 || units <= 0 {
        return;
    }
    let s1 = rt::sched_stats();
    let per = (rounds * units) as f64;
    let mut note = String::from_str("scheduler per ");
    note.push_str(unit);
    note.push_str(": parks ");
    note.push_f64_prec((s1.parks - s0.parks) as f64 / per, 3);
    note.push_str(", wakes ");
    note.push_f64_prec((s1.wakes - s0.wakes) as f64 / per, 3);
    note.push_str(", steals ");
    note.push_f64_prec((s1.steals - s0.steals) as f64 / per, 3);
    note.push_str(", injections ");
    note.push_f64_prec((s1.inj_takes - s0.inj_takes) as f64 / per, 3);
    note.push_str(" (");
    note.push_i64(rounds);
    note.push_str(" rounds)");
    b.note_more(note.as_str());
}

// The coordination the primitives themselves did, per work unit: how often a wait actually blocked, how
// many notifies found a waiter, and how many found none. Reported only when the synchronisation module was
// built with its counters compiled in (`SYNC_STATS` in std/parallel/sync.spc). A build of an older runtime
// for comparison has no such counters, so an A/B against one drops this call.
fn sync_note(b: &mut bench::Bencher, s0: &sync::SyncStats, units: i64, rounds: i64, unit: str) {
    if !sync::sync_stats_on() || rounds <= 0 || units <= 0 {
        return;
    }
    let s1 = sync::sync_stats();
    let per = (rounds * units) as f64;
    let mut note = String::from_str("coordination per ");
    note.push_str(unit);
    note.push_str(": task waits ");
    note.push_f64_prec((s1.cv_waits - s0.cv_waits) as f64 / per, 3);
    note.push_str(", thread waits ");
    note.push_f64_prec((s1.cv_blocks - s0.cv_blocks) as f64 / per, 3);
    note.push_str(", wakes ");
    note.push_f64_prec((s1.wakes - s0.wakes) as f64 / per, 3);
    note.push_str(" (stale ");
    note.push_f64_prec((s1.wakes_stale - s0.wakes_stale) as f64 / per, 3);
    note.push_str("), notifies with no waiter ");
    note.push_f64_prec((s1.notifies_idle - s0.notifies_idle) as f64 / per, 3);
    note.push_str(", contended locks ");
    note.push_f64_prec((s1.lock_slow - s0.lock_slow) as f64 / per, 3);
    b.note_more(note.as_str());
}

// --- mutex ------------------------------------------------------------------------------------------.

/// An uncontended lock/unlock pair, on the thread that already owns it. The fast path, and the one that
/// shows up in every data structure built on top of `Mutex`.
@bench
pub fn mutex_uncontended(b: &mut bench::Bencher) {
    b.each(OPS);
    b.unit("lock");
    let m = sync::Mutex::<i64>::new(0);
    let mut expect: i64 = 0;
    while b.running() {
        for _i in 0..OPS {
            let mut g = m.lock();
            let v = g.get_mut();
            *v = *v + 1;
        }
        expect = expect + OPS;
        let g = m.lock();
        b.tally(
            OPS,
            if *g.get() == expect {
                OPS;
            } else {
                0i64;
            },
        );
    }
}

/// The same lock with every worker fighting for it. What this measures is the hand-off: a coroutine that
/// loses the race parks and is woken by the unlock, so this is the lock's queue plus a context switch.
@bench
pub fn mutex_contended(b: &mut bench::Bencher) {
    let total = LOCKERS * HAMMER;
    b.each(total);
    b.unit("lock");
    while b.running() {
        let shared = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
        let wg = sync::WaitGroup::new();
        wg.add(LOCKERS);
        for _t in 0..LOCKERS {
            let w = wg.clone();
            let m = shared.clone();
            launch || {
                for _i in 0..HAMMER {
                    let mut g = m.get().lock();
                    let v = g.get_mut();
                    *v = *v + 1;
                }
                w.done();
            };
        }
        wg.wait();
        let g = shared.get().lock();
        b.tally(
            total,
            if *g.get() == total {
                total;
            } else {
                0i64;
            },
        );
    }
}

// --- channels ---------------------------------------------------------------------------------------.

// One producer, one consumer, `cap` slots. Capacity is the whole point of the sweep: at 1 every message
// parks both ends, and at 1024 a producer runs ahead and the parks disappear.
fn channel_lane(b: &mut bench::Bencher, cap: usize) {
    b.each(MSGS);
    b.unit("msg");
    // The consumer records how many it took; the round is validated against it.
    let seen = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let s0 = rt::sched_stats();
    let y0 = sync::sync_stats();
    let mut rounds: i64 = 0;
    while b.running() {
        rounds = rounds + 1;
        let ch = chan::Channel::<i64>::bounded(cap);
        let rx = ch.receiver();
        // The sender MUST exist before the consumer starts. `recv` reports "closed and drained" when the
        // sender count is zero, so a consumer scheduled in the window between `launch` and `ch.sender()`
        // gives up at once and drops the last receiver: after which every `send` is rejected and the round
        // silently measures nothing. Cheap to get wrong, and it only shows up under load.
        let tx = ch.sender();
        let wg = sync::WaitGroup::new();
        wg.add(1);
        let w = wg.clone();
        let c = seen.clone();
        launch || {
            let mut got: i64 = 0;
            loop {
                switch rx.recv() {
                    Some(_v) => {
                        got = got + 1;
                    },
                    None => {
                        break;
                    },
                };
            }
            c.get().store(got, atomics::MemoryOrder::Release);
            w.done();
        };
        for i in 0..MSGS {
            let _ = tx.send(i);
        }
        tx.close();
        wg.wait();
        b.tally(MSGS, seen.get().load(atomics::MemoryOrder::Acquire));
    }
    sched_note(b, &s0, MSGS, rounds, "msg");
    sync_note(b, &y0, MSGS, rounds, "msg");
}

@bench
/// Benchmark lane: ping-pong over a capacity-1 channel.
pub fn channel_cap1(b: &mut bench::Bencher) {
    channel_lane(b, 1);
}

@bench
/// Benchmark lane: ping-pong over a capacity-64 channel.
pub fn channel_cap64(b: &mut bench::Bencher) {
    channel_lane(b, 64);
}

@bench
/// Benchmark lane: ping-pong over a capacity-1024 channel.
pub fn channel_cap1024(b: &mut bench::Bencher) {
    channel_lane(b, 1024);
}

/// The same traffic as `channel_cap64` (same message count, same capacity) moved with `send_batch` /
/// `recv_batch` instead of one `send`/`recv` per item. Directly comparable to that lane, and the difference
/// between the two is what one lock, one unlock and one wake per item cost.
@bench
pub fn channel_batch64(b: &mut bench::Bencher) {
    b.each(MSGS);
    b.unit("msg");
    let seen = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let s0 = rt::sched_stats();
    let y0 = sync::sync_stats();
    let mut rounds: i64 = 0;
    while b.running() {
        rounds = rounds + 1;
        let ch = chan::Channel::<i64>::bounded(64);
        let rx = ch.receiver();
        let tx = ch.sender(); // before the consumer starts: see the note in `channel_lane`
        let wg = sync::WaitGroup::new();
        wg.add(1);
        let w = wg.clone();
        let c = seen.clone();
        launch || {
            let mut got = Vector::<i64>::new();
            let mut n: i64 = 0;
            loop {
                let k = rx.recv_batch(&mut got, 64);
                if k == 0 {
                    // Closed and drained.
                    break;
                }
                n = n + k as i64;
                got.clear();
            }
            c.get().store(n, atomics::MemoryOrder::Release);
            w.done();
        };
        let mut out = Vector::<i64>::new();
        let mut i: i64 = 0;
        while i < MSGS {
            // The last batch is short whenever MSGS is not a multiple of 64: the message COUNT has to match
            // `channel_cap64`'s exactly, or the two per-message figures are not comparable.
            let take = if MSGS - i < 64 {
                MSGS - i;
            } else {
                64i64;
            };
            for j in 0..take {
                out.push(i + j);
            }
            let _ = tx.send_batch(&mut out);
            i = i + take;
        }
        tx.close();
        wg.wait();
        b.tally(MSGS, seen.get().load(atomics::MemoryOrder::Acquire));
    }
    sched_note(b, &s0, MSGS, rounds, "msg");
    sync_note(b, &y0, MSGS, rounds, "msg");
}

/// Channel construction: build a bounded channel, one sender and one receiver, and drop them. The
/// allocation figure is the whole cost of a channel's block(s); a program that opens a channel per
/// request pays this per request.
@bench
pub fn channel_construct(b: &mut bench::Bencher) {
    b.each(CHANNELS);
    b.unit("channel");
    while b.running() {
        let mut ok: i64 = 0;
        for _i in 0..CHANNELS {
            let ch = chan::Channel::<i64>::bounded(64);
            let tx = ch.sender();
            let rx = ch.receiver();
            switch tx.try_send(1) {
                Sent => {},
                Rejected(_v) => {},
            };
            switch rx.try_recv() {
                Some(v) => {
                    ok = ok + v;
                },
                None => {},
            };
        }
        b.tally(CHANNELS, ok);
    }
}

/// PRODUCERS producers and CONSUMERS consumers on one 64-slot channel: the lock contended from both sides,
/// with a wake for every item a parked consumer or producer was waiting for. The MPMC shape a work queue
/// has.
@bench
pub fn channel_mpmc(b: &mut bench::Bencher) {
    let per = MSGS / PRODUCERS;
    let total = per * PRODUCERS;
    b.each(total);
    b.unit("msg");
    let seen = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let s0 = rt::sched_stats();
    let y0 = sync::sync_stats();
    let mut rounds: i64 = 0;
    while b.running() {
        rounds = rounds + 1;
        seen.get().store(0, atomics::MemoryOrder::Relaxed);
        let ch = chan::Channel::<i64>::bounded(64);
        let wg = sync::WaitGroup::new();
        wg.add(PRODUCERS + CONSUMERS);
        // Every sender exists before a consumer can start: see the note in `channel_lane`.
        let mut txs = Vector::<chan::Sender<i64>>::with_capacity(PRODUCERS as usize);
        for _p in 0..PRODUCERS {
            txs.push(ch.sender());
        }
        for _c in 0..CONSUMERS {
            let rx = ch.receiver();
            let w = wg.clone();
            let s = seen.clone();
            launch || {
                let mut got: i64 = 0;
                loop {
                    switch rx.recv() {
                        Some(_v) => {
                            got = got + 1;
                        },
                        None => {
                            break;
                        },
                    };
                }
                let _ = s.get().fetch_add(got, atomics::MemoryOrder::AcqRel);
                w.done();
            };
        }
        loop {
            switch txs.pop() {
                Some(tx) => {
                    let w = wg.clone();
                    launch || {
                        for i in 0..per {
                            let _ = tx.send(i);
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
        b.tally(total, seen.get().load(atomics::MemoryOrder::Acquire));
    }
    sched_note(b, &s0, total, rounds, "msg");
    sync_note(b, &y0, total, rounds, "msg");
}

/// One producer, one consumer, 64 slots, and every message carries the time it was sent, so the note is
/// the per-message delivery latency: what a wake costs a receiver in time, where `channel_cap64` says what
/// the traffic costs in throughput.
@bench
pub fn channel_latency(b: &mut bench::Bencher) {
    b.each(MSGS);
    b.unit("msg");
    let sink = lat_sink(LAT_ROUNDS * MSGS as usize);
    let seen = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let s0 = rt::sched_stats();
    let y0 = sync::sync_stats();
    let mut rounds: i64 = 0;
    while b.running() {
        rounds = rounds + 1;
        let ch = chan::Channel::<u64>::bounded(64);
        let rx = ch.receiver();
        let tx = ch.sender(); // before the consumer starts: see the note in `channel_lane`
        let wg = sync::WaitGroup::new();
        wg.add(1);
        let w = wg.clone();
        let c = seen.clone();
        let s = sink.clone();
        launch || {
            let mut lat = Vector::<f64>::with_capacity(MSGS as usize);
            let mut got: i64 = 0;
            loop {
                switch rx.recv() {
                    Some(t0) => {
                        lat.push((platform::now_ns() - t0) as f64 / 1000.0);
                        got = got + 1;
                    },
                    None => {
                        break;
                    },
                };
            }
            lat_merge(&s, &lat);
            c.get().store(got, atomics::MemoryOrder::Release);
            w.done();
        };
        for _i in 0..MSGS {
            let _ = tx.send(platform::now_ns());
        }
        tx.close();
        wg.wait();
        b.tally(MSGS, seen.get().load(atomics::MemoryOrder::Acquire));
    }
    sched_note(b, &s0, MSGS, rounds, "msg");
    sync_note(b, &y0, MSGS, rounds, "msg");
    lat_note(b, &sink, "delivery latency");
}

// The `select` half of a two-channel exchange: `who` receives MSGS messages that one task sends alternately
// on two 64-slot channels, waiting on both at once, and reports how many it took. Run on a coroutine or on
// the calling thread, which is what the two lanes below differ in.
fn select_two_channels(b: &mut bench::Bencher, on_thread: bool) {
    b.each(MSGS);
    b.unit("msg");
    let seen = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let s0 = rt::sched_stats();
    let y0 = sync::sync_stats();
    let mut rounds: i64 = 0;
    while b.running() {
        rounds = rounds + 1;
        let a = chan::Channel::<i64>::bounded(64);
        let c = chan::Channel::<i64>::bounded(64);
        let arx = a.receiver();
        let crx = c.receiver();
        let atx = a.sender();
        let ctx = c.sender();
        let wg = sync::WaitGroup::new();
        wg.add(1);
        let w = wg.clone();
        launch || {
            for i in 0..MSGS {
                if i % 2 == 0 {
                    let _ = atx.send(i);
                } else {
                    let _ = ctx.send(i);
                }
            }
            atx.close();
            ctx.close();
            w.done();
        };
        if on_thread {
            seen.get().store(select_drain(&arx, &crx), atomics::MemoryOrder::Release);
        } else {
            let s = seen.clone();
            let done = sync::WaitGroup::new();
            done.add(1);
            let d = done.clone();
            launch || {
                s.get().store(select_drain(&arx, &crx), atomics::MemoryOrder::Release);
                d.done();
            };
            done.wait();
        }
        wg.wait();
        b.tally(MSGS, seen.get().load(atomics::MemoryOrder::Acquire));
    }
    sched_note(b, &s0, MSGS, rounds, "msg");
    sync_note(b, &y0, MSGS, rounds, "msg");
}

// Take everything from both receivers through one selector until both are closed and drained. A closed
// arm is always ready, so once one reports "closed and drained" the selector is rebuilt without it.
fn select_drain(arx: &chan::Receiver<i64>, crx: &chan::Receiver<i64>) i64 {
    let mut s = selector::Selector::new();
    let mut ia = s.arm_recv(arx);
    let mut ic = s.arm_recv(crx);
    let mut got: i64 = 0;
    let mut a_open = true;
    let mut c_open = true;
    while a_open || c_open {
        switch s.wait() {
            Ready(i) => {
                let from_a = a_open && i == ia;
                let r = if from_a {
                    arx.try_recv();
                } else {
                    crx.try_recv();
                };
                switch r {
                    Some(_v) => {
                        got = got + 1;
                    },
                    None => {
                        s.clear();
                        if from_a {
                            a_open = false;
                            if c_open {
                                ic = s.arm_recv(crx);
                            }
                        } else {
                            c_open = false;
                            if a_open {
                                ia = s.arm_recv(arx);
                            }
                        }
                    },
                };
            },
            TimedOut => {},
        };
    }
    let _ = ic;
    return got;
}

/// `select` over two channels from a coroutine: one park under one wake token however many arms there are.
@bench
pub fn select_two(b: &mut bench::Bencher) {
    select_two_channels(b, false);
}

/// `select` over two channels from a plain thread (the calling thread), which sleeps on one wake word that
/// every arm's node names and is woken by the first arm to move.
@bench
pub fn select_thread(b: &mut bench::Bencher) {
    select_two_channels(b, true);
}

/// The parking lot under collision: PARK_THREADS plain threads (more than the lot has buckets) each park
/// on a word of their own, and the lane unparks them one at a time, round-robin, PARK_ROUNDS times each.
/// The note counts the wakes that reached a thread whose word had NOT changed: what a bucket-wide
/// broadcast costs every thread that merely shares a bucket, and what a targeted wake never does.
@bench
pub fn park_collisions(b: &mut bench::Bencher) {
    let total = PARK_THREADS * PARK_ROUNDS;
    b.each(total);
    b.unit("unpark");
    // One word per thread, 64 bytes apart: a line each, and a spread of addresses over the buckets.
    let stride: usize = 16;
    let mut words = Vector::<i32>::with_capacity(PARK_THREADS as usize * stride);
    for _i in 0..PARK_THREADS as usize * stride {
        words.push(0);
    }
    let base = words.as_ptr() as usize;
    let acks = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let unrelated = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let rss0 = unsafe sys::sc_bs_rss_now();
    let mut handles = Vector::<thread::JoinHandle<i64>>::with_capacity(PARK_THREADS as usize);
    for t in 0..PARK_THREADS as usize {
        let addr = base + t * stride * sizeof(i32);
        let a = acks.clone();
        let u = unrelated.clone();
        handles.push(
            thread::spawn(
                fn() i64 {
                    let w = addr as *mut i32;
                    let mut stray: i64 = 0;
                    let mut served: i64 = 0;
                    loop {
                        while atomic::load_i32(w, 1) == 0 {
                            unsafe sc_runtime::sc_rt_park(w, 0, -1);
                            if atomic::load_i32(w, 1) == 0 {
                                stray = stray + 1;
                            }
                        }
                        let v = atomic::load_i32(w, 1);
                        atomic::store_i32(w, 0, 2);
                        if v == 2 {
                            break;
                        }
                        served = served + 1;
                        let _ = a.get().fetch_add(1, atomics::MemoryOrder::Release);
                    }
                    let _ = u.get().fetch_add(stray, atomics::MemoryOrder::AcqRel);
                    return served;
                },
            ),
        );
    }
    // Every thread is parked by now (the first round's first unpark waits for an acknowledgement, so the
    // reading below happens with the whole set asleep on their words).
    rt::sleep_ns(50000000);
    let rss1 = unsafe sys::sc_bs_rss_now();
    let mut expected: i64 = 0;
    while b.running() {
        for _r in 0..PARK_ROUNDS {
            for t in 0..PARK_THREADS as usize {
                let w = (base + t * stride * sizeof(i32)) as *mut i32;
                atomic::store_i32(w, 1, 2);
                unsafe sc_runtime::sc_rt_unpark_one(w);
                expected = expected + 1;
                // Each unpark is acknowledged before the next: the figure is one wake's round trip.
                while acks.get().load(atomics::MemoryOrder::Acquire) < expected {
                    unsafe sc_runtime::sc_rt_cpu_relax();
                }
            }
        }
        b.tally(total, total);
    }
    let mut served: i64 = 0;
    for t in 0..PARK_THREADS as usize {
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
    if served != expected {
        bench::fail("park_collisions: a thread was not woken for every unpark");
    }
    let mut note = String::from_str("unrelated wakes per unpark: ");
    note.push_f64_prec(unrelated.get().load(atomics::MemoryOrder::Acquire) as f64 / expected as f64, 3);
    note.push_str(" (");
    note.push_i64(PARK_THREADS);
    note.push_str(" threads parked at once)");
    b.note(note.as_str());
    // What the lot RETAINS for those threads, which the wake count alone does not say: a targeted wake
    // may be paid for in records that never come back. Wait records live in the parking frames and are
    // not retained; what is kept is one parker per thread that has ever parked, plus the bucket table.
    let per = unsafe sc_runtime::sc_rt_park_bytes_per_thread();
    let mut held = String::from_str("parking retains ");
    held.push_u64(per as u64);
    held.push_str(" B per parked thread (");
    held.push_f64_prec((per * PARK_THREADS as usize) as f64 / 1024.0, 1);
    held.push_str(" KiB for ");
    held.push_i64(PARK_THREADS);
    held.push_str("), ");
    held.push_f64_prec((unsafe sc_runtime::sc_rt_park_bytes_fixed()) as f64 / 1024.0, 1);
    held.push_str(" KiB fixed; resident while parked ");
    held.push_f64_prec((rss1 - rss0) as f64 / 1024.0, 1);
    held.push_str(" KiB (thread stacks included)");
    b.note_more(held.as_str());
}

// --- fan-in -----------------------------------------------------------------------------------------.

/// `WaitGroup` fan-in: `done` itself, plus the wake the last one owes the waiter.
///
/// A FIXED, small number of tasks each signal many times. One task per `done`: the obvious way to write
/// this: measures spawn instead: `done` is a single atomic, so a task built to call it once is a thousand
/// nanoseconds of scheduling wrapped around twenty of work, and the lane reported the same figure as
/// `spawn_to_completion` to within one percent.
@bench
pub fn waitgroup_fanin(b: &mut bench::Bencher) {
    let total = FANIN_TASKS * FANIN_EACH;
    b.each(total);
    b.unit("done");
    while b.running() {
        let wg = sync::WaitGroup::new();
        wg.add(total);
        for _t in 0..FANIN_TASKS {
            let w = wg.clone();
            launch || {
                for _i in 0..FANIN_EACH {
                    w.done();
                }
            };
        }
        wg.wait();
        b.tally(total, total);
    }
}

// --- data-parallel ----------------------------------------------------------------------------------.

/// What one `parallel::range` CALL costs, which is almost entirely fixed: measured earlier at 182us per
/// dispatch over a 256-iteration span and 217us over an 8192-iteration one, so thirty-two times the work
/// added under a fifth. Reporting it per iteration instead (a large span, amortised) hid that behind a
/// 1.5ns figure and said nothing useful. The number to take from this: `parallel::range` is worth reaching
/// for only when the serial loop it replaces would cost well over the dispatch.
@bench
pub fn parallel_range(b: &mut bench::Bencher) {
    b.each(DISPATCHES);
    b.unit("dispatch");
    // A SCOPED parallel call returns only once every chunk is done, so it may borrow this frame: no Arc.
    let hits = atomics::Atomic::<i64>::new(0);
    let hp = &hits;
    while b.running() {
        let h0 = hits.load(atomics::MemoryOrder::Acquire);
        for _d in 0..DISPATCHES {
            data::range(
                0..SPAN,
                |i: usize| {
                    // Enough that the body cannot be deleted, and far too little to hide the dispatch.
                    if i == 0 {
                        let _ = hp.fetch_add(1, atomics::MemoryOrder::Relaxed);
                    }
                },
            );
        }
        b.tally(DISPATCHES, hits.load(atomics::MemoryOrder::Acquire) - h0);
    }
}

/// The same short dispatch over UNEVEN work: index `i` costs `4 * (i % 64)` multiply steps, so with the
/// sixteen-index chunk floor one static chunk carries up to seven times another's work. Static and Dynamic
/// run back to back on identical work; the gap between them is what dynamic claiming buys on a short
/// range, and bounds what the chunk floor costs there.
@bench
pub fn parallel_range_uneven(b: &mut bench::Bencher) {
    b.each(DISPATCHES * 2);
    b.unit("dispatch");
    let hits = atomics::Atomic::<i64>::new(0);
    let hp = &hits;
    let dynamic = data::Options { schedule: data::Schedule::Dynamic, grain_size: 8 };
    let mut ms_static = Vector::<f64>::new();
    let mut ms_dynamic = Vector::<f64>::new();
    while b.running() {
        let h0 = hits.load(atomics::MemoryOrder::Acquire);
        let t0 = platform::now_ns();
        for _d in 0..DISPATCHES {
            data::range(
                0..SPAN,
                |i: usize| {
                    bench::black_box(bench::burn((i % 64) as i64 * 4));
                    if i == 0 {
                        let _ = hp.fetch_add(1, atomics::MemoryOrder::Relaxed);
                    }
                },
            );
        }
        let t1 = platform::now_ns();
        for _d in 0..DISPATCHES {
            data::range_with(
                0..SPAN,
                dynamic,
                |i: usize| {
                    bench::black_box(bench::burn((i % 64) as i64 * 4));
                    if i == 0 {
                        let _ = hp.fetch_add(1, atomics::MemoryOrder::Relaxed);
                    }
                },
            );
        }
        let t2 = platform::now_ns();
        ms_static.push((t1 - t0) as f64 / 1000000.0);
        ms_dynamic.push((t2 - t1) as f64 / 1000000.0);
        b.tally(DISPATCHES * 2, hits.load(atomics::MemoryOrder::Acquire) - h0);
    }
    let ss = bench::summarize(&mut ms_static);
    let sd = bench::summarize(&mut ms_dynamic);
    let mut note = String::from_str("static ");
    note.push_f64_prec(ss.median * 1000000.0 / DISPATCHES as f64, 1);
    note.push_str(" ns/dispatch, dynamic ");
    note.push_f64_prec(sd.median * 1000000.0 / DISPATCHES as f64, 1);
    note.push_str(" ns/dispatch (medians)");
    b.note(note.as_str());
}

// --- deep stacks ------------------------------------------------------------------------------------.

// The frame's address escapes: with it private the optimiser turns this tail call into a loop, and the
// lane would measure a shallow stack.
fn deep(n: u64, acc: u64) u64 {
    let mut pad = Array::<u64, 8>::new();
    pad[7] = n;
    bench::black_box((((&mut pad[0]) as *mut u64) as usize) as u64);
    if n == 0 {
        return acc + pad[7];
    }
    return deep(n - 1, acc + pad[7]);
}

/// Tasks that each recurse past 100 KiB of their 256 KiB stack: what a task pays when it uses its stack
/// rather than the first page of it. A recycled block whose pages were given back faults them in again
/// here, so this is the lane that prices stack trimming and block reuse, not spawn.
@bench
pub fn deep_stack(b: &mut bench::Bencher) {
    b.each(DEEP_TASKS);
    b.unit("task");
    while b.running() {
        let base = rt::completed_tasks();
        let wg = sync::WaitGroup::new();
        wg.add(DEEP_TASKS);
        for _i in 0..DEEP_TASKS {
            let w = wg.clone();
            launch || {
                bench::black_box(deep(DEEP_FRAMES, 0));
                w.done();
            };
        }
        wg.wait();
        let retired = wait_retired(base, DEEP_TASKS as usize);
        b.tally(
            DEEP_TASKS,
            if retired {
                DEEP_TASKS;
            } else {
                0i64;
            },
        );
        if !retired {
            bench::fail("deep_stack: the runtime did not retire every task within the wait");
        }
    }
}

// --- the allocator ----------------------------------------------------------------------------------.

/// `malloc` plus `free` of a small block, back to back: the allocator's fast path, and the lane whose
/// diagnostic rounds price the allocation accounting itself. The throughput rounds run with accounting
/// off and the diagnostic rounds with it on; the difference between the two medians is the cost of the
/// per-thread counters, which is what every other lane's diagnostic figure paid.
@bench
pub fn malloc_free(b: &mut bench::Bencher) {
    b.each(ALLOCS);
    b.unit("pair");
    while b.running() {
        let mut ok: i64 = 0;
        for _i in 0..ALLOCS {
            let p = unsafe stdlib::malloc(32);
            if p != null {
                ok = ok + 1;
            }
            unsafe stdlib::free(p);
        }
        b.tally(ALLOCS, ok);
    }
}
