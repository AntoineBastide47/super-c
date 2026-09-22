// The lock under every shape of use it actually meets: one caller, two callers handing ownership back and
// forth, many callers over short and long critical sections, more runnable tasks than workers, coroutines
// and plain threads together, a hot re-acquirer against occasional waiters, many separate locks against
// locks that deliberately share a queue bucket, an owner that parks while holding, and dense arrays of
// small locks. `micro_bench` keeps the two headline lock lanes; these are the ones that separate a policy
// change from a layout change, and most of them report a per-acquisition wait distribution rather than a
// single mean, because the tail is where a fairness decision shows up.
//
// Every lane validates its own work (`b.tally`): a lock lane that silently lost mutual exclusion would
// otherwise report a wonderful number for doing the wrong thing. Task and thread counts are FIXED so a
// figure compares across machines.

import sc_runtime;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::thread as thread;
import std::parallel::arc as arc;
import std::parallel::atomics as atomics;
import std::parallel::platform as platform;
import std::parallel::time as time;
import std::testing::bench as bench;

const OPS: i64 = 20000; // operations per round in the single-caller lanes
const HAMMER: i64 = 2000; // per-task operations in the contended lanes
const LOCKERS: i64 = 8; // tasks in the contended lanes: FIXED, so the figure compares across machines
const THREADS: i64 = 4; // plain threads in the thread and mixed lanes
const HANDOFFS: i64 = 20000; // ownership transfers in the alternating lane
const DENSE: usize = 64; // locks in the dense array
const DENSE_OPS: i64 = 20000; // operations per task over that array
const ADDR_LOCKS: usize = 16; // locks in the address lanes
const ADDR_OPS: i64 = 600; // operations per task in the address lanes
const ADDR_WORK: i64 = 8192; // critical-section work there: past any spin, so waiters reach the queue
const POOL: usize = 2048; // locks allocated to select the address sets from
const PARK_HOLDS: i64 = 200; // acquisitions in the parking-owner lane
const STARVE_MS: u64 = 300; // how long the hot re-acquirer runs in the starvation lane
const SECTION_TASKS: i64 = 8; // tasks in the critical-section sweep

type Shared = arc::Arc<sync::Mutex<i64>>;

fn shared() Shared {
    return arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
}

fn counter() arc::Arc<atomics::Atomic<i64>> {
    return arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
}

fn count(c: &arc::Arc<atomics::Atomic<i64>>) i64 {
    return c.get().load(atomics::MemoryOrder::Acquire);
}

// A critical section of a chosen length, performed so the compiler cannot remove it: without the barrier
// the "long section" lanes would measure the same thing as the short ones.
fn section(v: &mut i64, work: i64) {
    *v = *v + 1;
    if work > 0 {
        // Sunk separately: folded into the protected value it would stop that value counting acquisitions,
        // and every lane here validates itself by that count.
        bench::black_box(bench::burn(work));
    }
    bench::black_box((*v) as u64);
}

// The lock counters over a lane, per acquisition. Reported only when the synchronisation module was built
// with them compiled in (`SYNC_STATS` in std/parallel/sync.spc); an ordinary run says nothing and pays
// nothing. These are shared relaxed atomics, so a run that reports them is not a run to quote a time from.
fn lock_note(b: &mut bench::Bencher, s0: &sync::SyncStats, acquisitions: i64, rounds: i64) {
    if !sync::sync_stats_on() || rounds <= 0 || acquisitions <= 0 {
        return;
    }
    let s1 = sync::sync_stats();
    let per = (rounds * acquisitions) as f64;
    let mut note = String::from_str("per acquisition: contended ");
    note.push_f64_prec((s1.lock_slow - s0.lock_slow) as f64 / per, 4);
    note.push_str(", spins ");
    note.push_f64_prec((s1.lock_spins - s0.lock_spins) as f64 / per, 2);
    note.push_str(", lost attempts ");
    note.push_f64_prec((s1.lock_cas_fail - s0.lock_cas_fail) as f64 / per, 4);
    note.push_str(", barges ");
    note.push_f64_prec((s1.lock_barges - s0.lock_barges) as f64 / per, 4);
    note.push_str(", task parks ");
    note.push_f64_prec((s1.lock_parks - s0.lock_parks) as f64 / per, 4);
    note.push_str(", thread blocks ");
    note.push_f64_prec((s1.lock_blocks - s0.lock_blocks) as f64 / per, 4);
    note.push_str(", bucket locks ");
    note.push_f64_prec((s1.lock_buckets - s0.lock_buckets) as f64 / per, 4);
    note.push_str(", nodes walked ");
    note.push_f64_prec((s1.lock_scan - s0.lock_scan) as f64 / per, 3);
    b.note_more(note.as_str());
}

// --- one caller -------------------------------------------------------------------------------------.

/// `try_lock` on a free lock, which every optimistic caller takes: the same acquisition as `lock` plus the
/// guard's option wrapper, and the lane that says whether the two fast paths cost the same.
@bench
pub fn mutex_trylock_uncontended(b: &mut bench::Bencher) {
    b.each(OPS);
    b.unit("try");
    let m = sync::Mutex::<i64>::new(0);
    let mut expect: i64 = 0;
    while b.running() {
        let mut took: i64 = 0;
        for _i in 0..OPS {
            switch m.try_lock() {
                Some(g) => {
                    let mut gg = g;
                    let v = gg.get_mut();
                    *v = *v + 1;
                    bench::black_box((*v) as u64);
                    took = took + 1;
                },
                None => {},
            };
        }
        expect = expect + OPS;
        let g = m.lock();
        b.tally(
            OPS,
            if *g.get() == expect && took == OPS {
                OPS;
            } else {
                0i64;
            },
        );
    }
}

// --- ownership transfer -----------------------------------------------------------------------------.

/// Two tasks and nothing else on one lock, each taking it as fast as it can. With exactly two contenders
/// almost every acquisition is a transfer from the other one, so the per-acquisition figure is what handing
/// a lock over costs: a spin that catches the release, or a park and a wake when it does not. Strict
/// alternation enforced by a turn variable was tried and rejected: the task whose turn it is not cycles
/// through the lock doing nothing, which measures contention against an idle holder rather than transfer.
@bench
pub fn mutex_handoff(b: &mut bench::Bencher) {
    let each = HANDOFFS / 2;
    let total = each * 2;
    b.each(total);
    b.unit("handoff");
    let s0 = sync::sync_stats();
    let mut rounds: i64 = 0;
    while b.running() {
        rounds = rounds + 1;
        let m = shared();
        let wg = sync::WaitGroup::new();
        wg.add(2);
        for _side in 0..2 {
            let h = m.clone();
            let w = wg.clone();
            launch || {
                for _i in 0..each {
                    let mut g = h.get().lock();
                    section(g.get_mut(), 0);
                }
                w.done();
            };
        }
        wg.wait();
        let g = m.get().lock();
        b.tally(
            total,
            if *g.get() == total {
                total;
            } else {
                0i64;
            },
        );
    }
    lock_note(b, &s0, total, rounds);
}

// --- a crew that outlives the timed rounds -----------------------------------------------------------.

// Task creation, the lock itself and the join all cost far more than the locking they surround, so a lane
// that builds them inside its timed round measures the runtime's spawn path as much as the lock: that is
// what made the contended lanes disagree between sessions by more than the policy changes under test.
// A `Crew` is built ONCE, before the first round, and its tasks live across all of them. Each round only
// releases the crew and waits for it, so the timed region holds the locking and nothing else.
@no_const
struct Crew {
    pub lock: Shared,
    pub start: sync::Barrier, // releases the crew for one round; the caller is the last participant
    pub end: sync::Barrier, // gathers it again
    pub stop: arc::Arc<atomics::Atomic<i64>>,
    pub wg: sync::WaitGroup, // joined once, after the last round
}

extend Crew {
    /// Release the crew for one round and wait for all of it. `pub` for linkage.
    pub fn round(self: &Crew) {
        let _ = self.start.wait();
        let _ = self.end.wait();
    }
    /// Tell the crew to finish and join it. `pub` for linkage.
    pub fn finish(self: &Crew) {
        self.stop.get().store(1, atomics::MemoryOrder::Release);
        let _ = self.start.wait();
        self.wg.wait();
    }
}

// Build a crew of `workers` tasks, each of which takes the lock `each` times per round with a critical
// section of `work`.
fn crew(workers: i64, each: i64, work: i64) Crew {
    let c = Crew {
        lock: shared(),
        start: sync::Barrier::new(workers + 1),
        end: sync::Barrier::new(workers + 1),
        stop: counter(),
        wg: sync::WaitGroup::new(),
    };
    c.wg.add(workers);
    for _t in 0..workers {
        let h = c.lock.clone();
        let st = c.start.clone();
        let en = c.end.clone();
        let s = c.stop.clone();
        let w = c.wg.clone();
        launch || {
            loop {
                // Parked between rounds rather than spinning: a crew that spun would occupy the very
                // workers the lock under test needs, and the lane would measure that instead.
                let _ = st.wait();
                if s.get().load(atomics::MemoryOrder::Acquire) != 0 {
                    break;
                }
                for _i in 0..each {
                    let mut lg = h.get().lock();
                    section(lg.get_mut(), work);
                }
                let _ = en.wait();
            }
            w.done();
        };
    }
    return c;
}

// --- critical-section length ------------------------------------------------------------------------.

// `SECTION_TASKS` tasks hammering one lock with a critical section of `work` units. The sweep over `work`
// is where spinning stops paying: a short section is covered by a spin, a long one is not. The crew is
// built before the first round, so the figure is the locking alone.
fn section_lane(b: &mut bench::Bencher, work: i64) {
    let total = SECTION_TASKS * HAMMER;
    b.each(total);
    b.unit("lock");
    let c = crew(SECTION_TASKS, HAMMER, work);
    let s0 = sync::sync_stats();
    let mut rounds: i64 = 0;
    while b.running() {
        rounds = rounds + 1;
        c.round();
        b.tally(total, total);
    }
    let held = c.lock.get().lock();
    let want = total * rounds;
    c.finish();
    if *held.get() < want {
        bench::fail("mutex section lane: the crew did not perform every acquisition");
    }
    lock_note(b, &s0, total, rounds);
}

@bench
/// Benchmark lane: eight tasks, a critical section of nothing but the increment.
pub fn mutex_section_0(b: &mut bench::Bencher) {
    section_lane(b, 0);
}

@bench
/// Benchmark lane: eight tasks, a critical section of about a hundred nanoseconds.
pub fn mutex_section_64(b: &mut bench::Bencher) {
    section_lane(b, 64);
}

@bench
/// Benchmark lane: eight tasks, a critical section well past what any spin can cover.
pub fn mutex_section_1024(b: &mut bench::Bencher) {
    section_lane(b, 1024);
}

// --- oversubscription -------------------------------------------------------------------------------.

// More runnable tasks than workers, so a spinning waiter is occupying a worker that has other work to do.
// `workers` of 1 is the extreme: a spinner there is holding the only thread that could run the owner.
fn oversubscribed(b: &mut bench::Bencher, workers: usize, tasks: i64) {
    let total = tasks * HAMMER;
    b.each(total);
    b.unit("lock");
    rt::set_worker_count(workers);
    let s0 = sync::sync_stats();
    let mut rounds: i64 = 0;
    while b.running() {
        rounds = rounds + 1;
        let m = shared();
        let wg = sync::WaitGroup::new();
        wg.add(tasks);
        for _t in 0..tasks {
            let h = m.clone();
            let w = wg.clone();
            launch || {
                for _i in 0..HAMMER {
                    let mut g = h.get().lock();
                    section(g.get_mut(), 16);
                }
                w.done();
            };
        }
        wg.wait();
        let g = m.get().lock();
        b.tally(
            total,
            if *g.get() >= total {
                total;
            } else {
                0i64;
            },
        );
    }
    lock_note(b, &s0, total, rounds);
}

@bench
/// Benchmark lane: thirty-two tasks on one worker, where every spin displaces the owner itself.
pub fn mutex_one_worker(b: &mut bench::Bencher) {
    oversubscribed(b, 1, 32);
}

@bench
/// Benchmark lane: thirty-two tasks on four workers, more runnable work than threads to run it.
pub fn mutex_oversubscribed(b: &mut bench::Bencher) {
    oversubscribed(b, 4, 32);
}

// --- caller classes ---------------------------------------------------------------------------------.

// `tasks` coroutines and `threads` plain threads competing for ONE shared budget of acquisitions, not a
// quota each: with a quota every caller finishes its own and the split says nothing, while a shared budget
// lets whichever class the policy favours take more of it. The note reports the split per caller.
fn caller_classes(b: &mut bench::Bencher, tasks: i64, threads: i64) {
    let total = (tasks + threads) * HAMMER;
    b.each(total);
    b.unit("lock");
    let by_task = counter();
    let by_thread = counter();
    let s0 = sync::sync_stats();
    let mut rounds: i64 = 0;
    while b.running() {
        rounds = rounds + 1;
        by_task.get().store(0, atomics::MemoryOrder::Relaxed);
        by_thread.get().store(0, atomics::MemoryOrder::Relaxed);
        let m = shared();
        let wg = sync::WaitGroup::new();
        wg.add(tasks);
        for _t in 0..tasks {
            let h = m.clone();
            let w = wg.clone();
            let c = by_task.clone();
            launch || {
                let mut mine: i64 = 0;
                loop {
                    let mut g = h.get().lock();
                    let v = g.get_mut();
                    if *v >= total {
                        break;
                    }
                    section(v, 16);
                    mine = mine + 1;
                }
                let _ = c.get().fetch_add(mine, atomics::MemoryOrder::AcqRel);
                w.done();
            };
        }
        let mut hs = Vector::<thread::JoinHandle<i64>>::new();
        for _t in 0..threads {
            let h = m.clone();
            let c = by_thread.clone();
            hs.push(
                thread::spawn(
                    fn() i64 {
                        let mut mine: i64 = 0;
                        loop {
                            let mut g = h.get().lock();
                            let v = g.get_mut();
                            if *v >= total {
                                break;
                            }
                            section(v, 16);
                            mine = mine + 1;
                        }
                        let _ = c.get().fetch_add(mine, atomics::MemoryOrder::AcqRel);
                        return mine;
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
        b.tally(
            total,
            if *g.get() >= total {
                total;
            } else {
                0i64;
            },
        );
    }
    lock_note(b, &s0, total, rounds);
    if tasks > 0 && threads > 0 {
        let mut note = String::from_str("share of one budget per caller: task ");
        note.push_f64_prec(count(&by_task) as f64 / tasks as f64, 0);
        note.push_str(", thread ");
        note.push_f64_prec(count(&by_thread) as f64 / threads as f64, 0);
        b.note_more(note.as_str());
    }
}

@bench
/// Benchmark lane: plain threads only, so the lock never sees a coroutine.
pub fn mutex_threads_only(b: &mut bench::Bencher) {
    caller_classes(b, 0, THREADS);
}

@bench
/// Benchmark lane: coroutines and plain threads contending for the same lock.
pub fn mutex_mixed_callers(b: &mut bench::Bencher) {
    caller_classes(b, LOCKERS, THREADS);
}

// --- fairness ---------------------------------------------------------------------------------------.

// What the starvation lane's waiters report: every wait they timed, and the fewest and most acquisitions
// any one of them made, all under one lock.
struct Waits {
    pub samples: Vector<f64>,
    pub fewest: i64,
    pub most: i64,
}

/// A hot re-acquirer against occasional waiters: one task takes and releases the lock as fast as it can
/// while `LOCKERS` others ask for it now and then and time every wait. The note is those waits' tail and
/// the spread between the luckiest and unluckiest waiter, which is what barging costs when it costs
/// anything. A waiter that never acquires is starvation, and the lane fails.
@bench
pub fn mutex_starvation(b: &mut bench::Bencher) {
    b.each(1);
    b.unit("round");
    b.set_rounds(5);
    let sink = arc::Arc::<sync::Mutex<Waits>>::new(
        sync::Mutex::<Waits>::new(Waits { samples: Vector::<f64>::new(), fewest: 0, most: 0 }),
    );
    while b.running() {
        let m = shared();
        let stop = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
        let wg = sync::WaitGroup::new();
        wg.add(LOCKERS + 1);
        {
            // The hot one: no gap at all between release and the next acquisition.
            let h = m.clone();
            let w = wg.clone();
            let s = stop.clone();
            launch || {
                while s.get().load(atomics::MemoryOrder::Acquire) == 0 {
                    for _i in 0..64 {
                        let mut g = h.get().lock();
                        section(g.get_mut(), 0);
                    }
                }
                w.done();
            };
        }
        for _t in 0..LOCKERS {
            let h = m.clone();
            let w = wg.clone();
            let s = stop.clone();
            let k = sink.clone();
            launch || {
                let mut waits = Vector::<f64>::new();
                let mut mine: i64 = 0;
                while s.get().load(atomics::MemoryOrder::Acquire) == 0 {
                    let t0 = platform::now_ns();
                    {
                        let mut g = h.get().lock();
                        waits.push((platform::now_ns() - t0) as f64 / 1000.0);
                        section(g.get_mut(), 0);
                        mine = mine + 1;
                    }
                    time::sleep(time::Duration::from_micros(50));
                }
                // One lock around the samples and both extremes, so two waiters finishing together cannot
                // lose the true minimum between a read and a write.
                let mut g = k.get().lock();
                let v = g.get_mut();
                for i in 0..waits.len() {
                    v.samples.push(waits[i]);
                }
                if v.fewest == 0 || mine < v.fewest {
                    v.fewest = mine;
                }
                if mine > v.most {
                    v.most = mine;
                }
                w.done();
            };
        }
        time::sleep(time::Duration::from_millis(STARVE_MS));
        stop.get().store(1, atomics::MemoryOrder::Release);
        wg.wait();
        let g = sink.get().lock();
        b.tally(
            1,
            if g.get().fewest > 0 {
                1i64;
            } else {
                0i64;
            },
        );
    }
    let mut g = sink.get().lock();
    let v = g.get_mut();
    if v.fewest == 0 {
        bench::fail("mutex_starvation: a waiter never acquired the lock");
    }
    let t = bench::dist_text("waiter wait", "us", &mut v.samples);
    b.note(t.as_str());
    let mut note = String::from_str("acquisitions across waiters: fewest ");
    note.push_i64(v.fewest);
    note.push_str(", most ");
    note.push_i64(v.most);
    b.note_more(note.as_str());
}

// --- queue buckets ----------------------------------------------------------------------------------.

// `ADDR_LOCKS` locks, each contended by two tasks with a section long enough to park them, so the queue
// buckets are actually used. `collide` picks locks that share one bucket, which is what makes the bucket
// spinlock and the queue scan the cost rather than the lock itself.
fn address_lane(b: &mut bench::Bencher, collide: bool) {
    let total = ADDR_LOCKS as i64 * 2 * ADDR_OPS;
    b.each(total);
    b.unit("lock");
    // Build a pool and keep either an arbitrary set or a set that hashes to one bucket. The bucket a lock
    // queues in is a function of its address, so the only honest way to collide on purpose is to ask the
    // runtime which bucket each one landed in. Built ONCE, before the first round, so the timed region
    // holds the locking and not two thousand allocations.
    //
    // Both sets come from ONE pool and are taken at the same spacing, so the only difference between the
    // lanes is the queue bucket. Spacing matters as much as the bucket: sixteen consecutively allocated
    // locks sit next to each other in memory, and a lane built that way measured neighbouring lock words
    // sharing a cache line rather than the bucket, reporting the COLLIDING set as faster. A bucket is one
    // in sixty-four, so locks that share one are about sixty-four allocations apart; the spread set takes
    // every sixty-fourth lock to match that.
    let mut pool = Vector::<Shared>::new();
    for _i in 0..POOL {
        pool.push(shared());
    }
    let mut kept = Vector::<Shared>::new();
    let target = bucket_of(&pool[0]);
    let mut i: usize = 0;
    while i < pool.len() && kept.len() < ADDR_LOCKS {
        let take = if collide {
            bucket_of(&pool[i]) == target;
        } else {
            i % 64 == 0;
        };
        if take {
            kept.push(pool[i].clone());
        }
        i = i + 1;
    }
    if kept.len() < ADDR_LOCKS {
        bench::fail("mutex address lane: could not build the lock set");
    }
    let s0 = sync::sync_stats();
    let mut rounds: i64 = 0;
    let mut expect: i64 = 0;
    while b.running() {
        rounds = rounds + 1;
        let wg = sync::WaitGroup::new();
        wg.add(ADDR_LOCKS as i64 * 2);
        for k in 0..kept.len() {
            for _side in 0..2 {
                let h = kept[k].clone();
                let w = wg.clone();
                launch || {
                    for _k in 0..ADDR_OPS {
                        let mut g = h.get().lock();
                        // Longer than any spin budget can cover, so the waiter actually reaches the queue
                        // and this lane measures the bucket rather than a spin.
                        section(g.get_mut(), ADDR_WORK);
                    }
                    w.done();
                };
            }
        }
        wg.wait();
        // The same locks serve every round, so the protected counts accumulate.
        expect = expect + total;
        let mut sum: i64 = 0;
        for k in 0..kept.len() {
            let g = kept[k].get().lock();
            sum = sum + *g.get();
        }
        b.tally(
            total,
            if sum == expect {
                total;
            } else {
                0i64;
            },
        );
    }
    lock_note(b, &s0, total, rounds);
    let mut note = String::from_str("locks ");
    note.push_u64(ADDR_LOCKS as u64);
    note.push_str(" over ");
    note.push_u64(distinct_buckets(&kept) as u64);
    note.push_str(" queue buckets");
    b.note_more(note.as_str());
}

// The queue bucket a lock's waiters would use: a function of its address, so the only honest way to
// collide on purpose is to ask the runtime.
fn bucket_of(m: &Shared) usize {
    let raw = unsafe m.get().raw_handle();
    return (unsafe sc_runtime::sc_rt_lot_bucket(raw)) as usize;
}

// How many distinct queue buckets a set of locks lands in.
fn distinct_buckets(set: &Vector<Shared>) usize {
    let mut seen = Vector::<usize>::new();
    for i in 0..set.len() {
        let bk = bucket_of(&set[i]);
        let mut have = false;
        for k in 0..seen.len() {
            if seen[k] == bk {
                have = true;
            }
        }
        if !have {
            seen.push(bk);
        }
    }
    return seen.len();
}

@bench
/// Benchmark lane: independent locks, whose queues spread over the bucket table.
pub fn mutex_addresses_spread(b: &mut bench::Bencher) {
    address_lane(b, false);
}

@bench
/// Benchmark lane: locks chosen to share one queue bucket, so every wait meets the same bucket lock.
pub fn mutex_addresses_collide(b: &mut bench::Bencher) {
    address_lane(b, true);
}

// --- an owner that stops running --------------------------------------------------------------------.

/// The owner parks while holding the guard, so no amount of spinning can help and the waiters must reach
/// the queue. What this lane checks is progress: every waiter acquires, and the lane says what waiting
/// through a parked owner costs.
@bench
pub fn mutex_owner_parks(b: &mut bench::Bencher) {
    let total = LOCKERS * PARK_HOLDS;
    b.each(total);
    b.unit("lock");
    let s0 = sync::sync_stats();
    let mut rounds: i64 = 0;
    while b.running() {
        rounds = rounds + 1;
        let m = shared();
        let wg = sync::WaitGroup::new();
        wg.add(LOCKERS);
        for _t in 0..LOCKERS {
            let h = m.clone();
            let w = wg.clone();
            launch || {
                for _i in 0..PARK_HOLDS {
                    let mut g = h.get().lock();
                    let v = g.get_mut();
                    *v = *v + 1;
                    bench::black_box((*v) as u64);
                    // Parked WITH the guard held: the worker goes elsewhere and every other caller waits.
                    time::sleep(time::Duration::from_micros(20));
                }
                w.done();
            };
        }
        wg.wait();
        let g = m.get().lock();
        b.tally(
            total,
            if *g.get() >= total {
                total;
            } else {
                0i64;
            },
        );
    }
    lock_note(b, &s0, total, rounds);
}

// --- the raw lock, without the guard ------------------------------------------------------------------.

/// The same uncontended acquisition taken by hand rather than through `Mutex<T>`: the raw lock and nothing
/// else. What the pair says is whether the guard, its option wrapper and the borrow of the payload cost
/// anything once the compiler has finished with them, which the public lanes cannot separate.
@bench
pub fn mutex_raw_uncontended(b: &mut bench::Bencher) {
    b.each(OPS);
    b.unit("lock");
    let m = sync::Mutex::<i64>::new(0);
    let raw = unsafe m.raw_handle();
    while b.running() {
        let mut took: i64 = 0;
        for _i in 0..OPS {
            unsafe sync::raw_mutex_lock(raw);
            took = took + 1;
            bench::black_box(took as u64);
            unsafe sync::raw_mutex_unlock(raw);
        }
        b.tally(OPS, took);
    }
}

// --- a large protected payload ------------------------------------------------------------------------.

// Big enough that the payload spans many cache lines, so a holder's own access to it, rather than the
// lock word, is what the next holder waits behind.
const PAYLOAD_WORDS: usize = 512; // 4 KiB

@no_const
struct BigPayload {
    pub w: Array<i64, PAYLOAD_WORDS>,
}

/// A lock over a large payload. The critical section touches the whole of it, so this lane says what a
/// lock costs when the data it guards, not the lock itself, dominates the hand-off: the line the lock word
/// sits on is one of many the next holder has to pull over.
@bench
pub fn mutex_large_payload(b: &mut bench::Bencher) {
    let tasks = LOCKERS;
    let each: i64 = 400;
    let total = tasks * each;
    b.each(total);
    b.unit("lock");
    let m = arc::Arc::<sync::Mutex<BigPayload>>::new(
        sync::Mutex::<BigPayload>::new(BigPayload { w: Array::<i64, PAYLOAD_WORDS>::new() }),
    );
    while b.running() {
        let wg = sync::WaitGroup::new();
        wg.add(tasks);
        for _t in 0..tasks {
            let h = m.clone();
            let w = wg.clone();
            launch || {
                for _i in 0..each {
                    let mut g = h.get().lock();
                    let p = g.get_mut();
                    // Every line of the payload, so the hand-off carries the data and not just the word.
                    let mut acc: i64 = 0;
                    for k in 0..PAYLOAD_WORDS {
                        let v = p.w[k] + 1;
                        p.w[k] = v;
                        acc = acc + v;
                    }
                    bench::black_box(acc as u64);
                }
                w.done();
            };
        }
        wg.wait();
        b.tally(total, total);
    }
    let g = m.get().lock();
    let mut note = String::from_str("payload ");
    note.push_u64((PAYLOAD_WORDS * sizeof(i64)) as u64);
    note.push_str(" B beside a ");
    note.push_u64(sizeof(sync::RawMutex) as u64);
    note.push_str(" B lock word; first word ");
    note.push_i64(g.get().w[0]);
    b.note(note.as_str());
}

// --- layout -----------------------------------------------------------------------------------------.

/// A dense array of small locks, each task working on its own index. Nothing here contends: what it
/// measures is the layout, since neighbouring locks share cache lines and an acquisition dirties the line
/// its neighbours are read from. The comparison lane gives every task its own line.
@bench
pub fn mutex_dense_array(b: &mut bench::Bencher) {
    dense_lane(b, false);
}

@bench
/// Benchmark lane: the same locks eight apart, so no acquisition disturbs another.
pub fn mutex_dense_spaced(b: &mut bench::Bencher) {
    dense_lane(b, true);
}

// `DENSE` locks in ONE contiguous buffer, which is what makes the array dense: separate allocations would
// sit wherever the allocator put them. `spaced` uses every eighth, so each task's lock has a line to
// itself; the difference between the two lanes is what packing them costs.
fn dense_lane(b: &mut bench::Bencher, spaced: bool) {
    let tasks = LOCKERS;
    let total = tasks * DENSE_OPS;
    b.each(total);
    b.unit("lock");
    let stride = if spaced {
        8usize;
    } else {
        1usize;
    };
    while b.running() {
        let mut array = Vector::<sync::Mutex<i64>>::new();
        for _i in 0..DENSE {
            array.push(sync::Mutex::<i64>::new(0));
        }
        let locks = arc::Arc::<Vector<sync::Mutex<i64>>>::new(array);
        let wg = sync::WaitGroup::new();
        wg.add(tasks);
        for t in 0..tasks {
            let idx = t as usize * stride % DENSE;
            let h = locks.clone();
            let w = wg.clone();
            launch || {
                for _i in 0..DENSE_OPS {
                    let mut g = h.get()[idx].lock();
                    let v = g.get_mut();
                    *v = *v + 1;
                    bench::black_box((*v) as u64);
                }
                w.done();
            };
        }
        wg.wait();
        let mut ok: i64 = 0;
        for i in 0..DENSE {
            let g = locks.get()[i].lock();
            ok = ok + *g.get();
        }
        b.tally(total, ok);
    }
    let mut note = String::from_str("one lock is ");
    note.push_u64(sizeof(sync::Mutex<i64>) as u64);
    note.push_str(" B; the array holds ");
    note.push_u64(DENSE as u64);
    b.note(note.as_str());
}
