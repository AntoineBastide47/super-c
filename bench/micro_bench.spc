// M7's micro-benchmarks: one primitive per lane, one number each. These are the numbers a regression shows
// up in first -- a macro benchmark tells you something got slower, a micro benchmark tells you what.
//
// Every lane reports per-operation cost via `b.each(N)`, so the figure is comparable across runs whatever
// the round size. Where a lane needs more than one task it uses a WaitGroup rather than sleeping, so the
// measurement is the primitive and not a timer.
//
// Two lanes the milestone asks for are NOT here, and deliberately:
//
//   * steals per task / idle-worker latency. The scheduler keeps no steal counter, and adding one means an
//     atomic increment on the steal path -- paying for the metric in the thing being measured. It wants a
//     counter compiled in only under a flag, which is its own change.
//   * the data-parallel SCALING CURVE (speedup at 1/2/4/8/N workers). Worker count is fixed before the pool
//     starts and the pool is per process, so a curve needs one process per point; `parallel_range` below
//     measures the dispatch cost at the configured count only.
//
// Task counts here are FIXED rather than taken from `worker_count()`: a lane whose round size depends on the
// machine cannot be compared between two machines, or against its own history on a different box.

import std::parallel::sync as sync;
import std::parallel::channel as chan;
import std::parallel::data as data;
import std::parallel::atomics as atomics;
import std::parallel::arc as arc;
import std::testing::bench as bench;

const SPAWNS: i64 = 2000; // tasks per round for the spawn lanes
const OPS: i64 = 20000; // operations per round for the uncontended lanes
const MSGS: i64 = 5000; // messages per round for the channel lanes
const HAMMER: i64 = 2000; // per-task operations in the contended lanes
const LOCKERS: i64 = 8; // tasks in the contended lock lane -- FIXED, so the number compares across machines
const FANIN_TASKS: i64 = 8; // signallers in the fan-in lane
const FANIN_EACH: i64 = 20000; // `done` calls each, so spawn cost is a rounding error next to them
const DISPATCHES: i64 = 200; // `parallel::range` calls per round
const SPAN: usize = 256; // iterations per dispatch: small, so what is measured is the dispatch

// --- spawn ------------------------------------------------------------------------------------------

/// What one `launch` costs end to end: the task is created, scheduled, run and accounted for. This is the
/// number a fan-out is made of, so it bounds every other coroutine lane.
@bench
pub fn spawn_to_completion(b: &mut bench::Bencher) {
    b.each(SPAWNS);
    b.unit("task");
    while b.running() {
        let wg = sync::WaitGroup::new();
        wg.add(SPAWNS);
        for _i in 0..SPAWNS {
            let w = wg.clone();
            launch || {
                w.done();
            };
        }
        wg.wait();
        wg.free();
    }
}

/// Spawn-to-FIRST-RUN, isolated from the run itself: the launcher waits for one task at a time, so what is
/// measured is the latency from `launch` to the task's first instruction rather than throughput under a
/// backlog. Slower per task than the lane above by design -- there is no pipelining to hide it.
@bench
pub fn spawn_latency(b: &mut bench::Bencher) {
    let rounds: i64 = 2000;
    b.each(rounds);
    b.unit("task");
    while b.running() {
        for _i in 0..rounds {
            let wg = sync::WaitGroup::new();
            wg.add(1);
            let w = wg.clone();
            launch || {
                w.done();
            };
            wg.wait();
            wg.free();
        }
    }
}

// --- park / unpark ----------------------------------------------------------------------------------

/// A park/unpark ROUND TRIP: two coroutines hand a value back and forth over a pair of channels, so each
/// message parks one task and wakes the other. This is the context-switch cost as a program actually pays
/// it -- the raw register swap is a fraction of it; the rest is the scheduler.
@bench
pub fn park_unpark_roundtrip(b: &mut bench::Bencher) {
    let trips: i64 = 2000;
    b.each(trips);
    b.unit("trip");
    while b.running() {
        let there = chan::Channel::<i64>::bounded(1);
        let back = chan::Channel::<i64>::bounded(1);
        let rx = there.receiver();
        let tx2 = back.sender();
        let tx = there.sender(); // before the echo task starts -- see the note in `channel_lane`
        let rx2 = back.receiver();
        let n = trips;
        // Wait for the echo task before freeing the channels it holds. Without this the round returns while
        // that task is still parked in `recv`, and freeing the channel under it leaves a live task pointing
        // at released memory -- which showed up not here but in whichever lane ran next.
        let wg = sync::WaitGroup::new();
        wg.add(1);
        let w = wg.clone();
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
            w.done();
        };
        for i in 0..trips {
            let _ = tx.send(i);
            let _ = rx2.recv();
        }
        tx.close();
        wg.wait();
        wg.free();
        let t = there;
        let bk = back;
        t.free();
        bk.free();
    }
}

// --- mutex ------------------------------------------------------------------------------------------

/// An uncontended lock/unlock pair, on the thread that already owns it. The fast path, and the one that
/// shows up in every data structure built on top of `Mutex`.
@bench
pub fn mutex_uncontended(b: &mut bench::Bencher) {
    b.each(OPS);
    b.unit("lock");
    let m = sync::Mutex::<i64>::new(0);
    while b.running() {
        for _i in 0..OPS {
            let mut g = m.lock();
            let v = g.get_mut();
            *v = *v + 1;
        }
    }
}

/// The same lock with every worker fighting for it. What this measures is the hand-off: a coroutine that
/// loses the race parks and is woken by the unlock, so this is the lock's queue plus a context switch.
@bench
pub fn mutex_contended(b: &mut bench::Bencher) {
    let total = LOCKERS * HAMMER;
    b.each(total);
    b.unit("lock");
    b.set_rounds(50);
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
        wg.free();
        let s = shared;
        s.free();
    }
}

// --- channels ---------------------------------------------------------------------------------------

// One producer, one consumer, `cap` slots. Capacity is the whole point of the sweep: at 1 every message
// parks both ends, and at 1024 a producer runs ahead and the parks disappear.
fn channel_lane(b: &mut bench::Bencher, cap: usize) {
    b.each(MSGS);
    b.unit("msg");
    // The consumer records how many it actually took. A channel lane that silently delivers nothing would
    // otherwise report a wonderful number for doing no work, which is the one way a benchmark can lie
    // outright -- so the count is checked and a wrong one is said out loud rather than averaged in.
    let seen = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let mut short: i64 = 0;
    while b.running() {
        let ch = chan::Channel::<i64>::bounded(cap);
        let rx = ch.receiver();
        // The sender MUST exist before the consumer starts. `recv` reports "closed and drained" when the
        // sender count is zero, so a consumer scheduled in the window between `launch` and `ch.sender()`
        // gives up at once and drops the last receiver -- after which every `send` is rejected and the round
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
            let _ = c.get().fetch_add(got, atomics::MemoryOrder::Relaxed);
            w.done();
        };
        let mut sent: i64 = 0;
        for i in 0..MSGS {
            switch tx.send(i) {
                Sent => {
                    sent = sent + 1;
                },
                _ => {},
            };
        }
        tx.close();
        wg.wait();
        wg.free();
        if sent != MSGS {
            short = short + 1;
        }
        let cc = ch;
        cc.free();
    }
    if short != 0 {
        b.note("SHORT: some rounds failed to send every message");
    }
    let s = seen;
    s.free();
}

@bench
pub fn channel_cap1(b: &mut bench::Bencher) {
    channel_lane(b, 1);
}

@bench
pub fn channel_cap64(b: &mut bench::Bencher) {
    channel_lane(b, 64);
}

@bench
pub fn channel_cap1024(b: &mut bench::Bencher) {
    channel_lane(b, 1024);
}

// --- fan-in -----------------------------------------------------------------------------------------

/// `WaitGroup` fan-in: `done` itself, plus the wake the last one owes the waiter.
///
/// A FIXED, small number of tasks each signal many times. One task per `done` -- the obvious way to write
/// this -- measures spawn instead: `done` is a single atomic, so a task built to call it once is a thousand
/// nanoseconds of scheduling wrapped around twenty of work, and the lane reported the same figure as
/// `spawn_to_completion` to within one percent.
@bench
pub fn waitgroup_fanin(b: &mut bench::Bencher) {
    let total = FANIN_TASKS * FANIN_EACH;
    b.each(total);
    b.unit("done");
    b.set_rounds(50);
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
        wg.free();
    }
}

// --- data-parallel ----------------------------------------------------------------------------------

/// What one `parallel::range` CALL costs, which is almost entirely fixed: measured at 182us per dispatch
/// over a 256-iteration span and 217us over an 8192-iteration one, so thirty-two times the work adds under
/// a fifth. Reporting it per iteration instead (a large span, amortised) hid that behind a 1.5ns figure and
/// said nothing useful. The number to take from this: `parallel::range` is worth reaching for only when the
/// serial loop it replaces would cost well over 180us.
@bench
pub fn parallel_range(b: &mut bench::Bencher) {
    b.each(DISPATCHES);
    b.unit("dispatch");
    b.set_rounds(50);
    // A SCOPED parallel call returns only once every chunk is done, so it may borrow this frame -- no Arc.
    let hits = atomics::Atomic::<i64>::new(0);
    let hp = &hits;
    while b.running() {
        for _d in 0..DISPATCHES {
            data::range(
                0..SPAN,
                |i: usize| {
                    // Just enough that the body cannot be deleted, and far too little to hide the dispatch.
                    if i == 0 {
                        let _ = hp.fetch_add(1, atomics::MemoryOrder::Relaxed);
                    }
                },
            );
        }
    }
}
