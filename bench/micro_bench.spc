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
import std::testing::bench as bench;

const SPAWNS: i64 = 2000; // tasks per round for the spawn lanes
const LATENCY_SPAWNS: i64 = 500; // one-at-a-time spawns per round for the latency lane
const OPS: i64 = 20000; // operations per round for the uncontended lanes
const MSGS: i64 = 5000; // messages per round for the channel lanes
const HAMMER: i64 = 2000; // per-task operations in the contended lanes
const LOCKERS: i64 = 8; // tasks in the contended lock lane: FIXED, so the number compares across machines
const FANIN_TASKS: i64 = 8; // signallers in the fan-in lane
const FANIN_EACH: i64 = 20000; // `done` calls each, so spawn cost is a rounding error next to them
const DISPATCHES: i64 = 200; // `parallel::range` calls per round
const SPAN: usize = 256; // iterations per dispatch: small, so what is measured is the dispatch
const ALLOCS: i64 = 20000; // malloc/free pairs per round in the allocator lane
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
    while b.running() {
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
    while b.running() {
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
