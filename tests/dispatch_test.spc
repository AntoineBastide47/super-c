// Task storage and data dispatch (std/parallel/runtime, std/parallel/data): a closure of any size or
// alignment runs and is destroyed exactly once whether it rides inline in the task record or in a box;
// deep stacks, cached-stack reuse, yields and guard faults behave; dispatch records outlive every worker
// access, nested and with every worker occupied; and the idle task-block cache obeys its byte budget.

import atomic;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::data as data;
import std::parallel::atomics as atomics;
import std::parallel::arc as arc;
import std::parallel::platform as platform;
import std::parallel::time as time;

// Exact-destruction counter: every `free` of a Tracked bumps it.
static mut G_FREES: i64 = 0;
static mut G_RUNS: i64 = 0;

struct Tracked {
    pub n: i64,
}

extend Tracked as Free {
    pub fn free(self: &mut Tracked) {
        let _ = atomic::add_i64(&mut unsafe G_FREES, 1, 0);
    }
}

fn frees() i64 {
    return atomic::load_i64(&mut unsafe G_FREES, 1);
}

fn runs() i64 {
    return atomic::load_i64(&mut unsafe G_RUNS, 1);
}

fn ran(n: i64) {
    let _ = atomic::add_i64(&mut unsafe G_RUNS, n, 0);
}

// --- captures of every shape ------------------------------------------------------------------------------

// A zero-sized closure: nothing to store; it still runs once.
@test
fn zero_sized_closure_runs_once() {
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch || {
        ran(1);
        w.done();
    };
    wg.wait();
    assert_eq(runs(), 1);
    rt::shutdown();
}

// A small owning capture (rides inline in the task record): run once, destroyed once, on the task.
@test
fn small_owning_capture_destroyed_once() {
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let t = Tracked { n: 3 };
    launch || {
        ran(t.n);
        w.done();
    };
    wg.wait();
    rt::shutdown();
    assert_eq(runs(), 3);
    assert_eq(frees(), 1);
}

// A large capture (past the inline storage: a boxed closure): the same guarantees.
struct Wide {
    pub a: Array<u64, 16>,
    pub t: Tracked,
}

@test
fn large_capture_boxed_and_destroyed_once() {
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let mut big = Wide { a: Array::<u64, 16>::new(), t: Tracked { n: 5 } };
    big.a[15] = 7;
    launch || {
        ran(big.t.n + big.a[15] as i64);
        w.done();
    };
    wg.wait();
    rt::shutdown();
    assert_eq(runs(), 12);
    assert_eq(frees(), 1);
}

// A 16-byte-aligned capture cannot use the 8-aligned inline storage: it is boxed, and still exact.
@c.align(16)
struct Aligned {
    pub v: u64,
    pub t: Tracked,
}

@test
fn over_aligned_capture_destroyed_once() {
    assert_eq(alignof(Aligned), 16usize);
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let a = Aligned { v: 9, t: Tracked { n: 1 } };
    launch || {
        ran(a.v as i64);
        w.done();
    };
    wg.wait();
    rt::shutdown();
    assert_eq(runs(), 9);
    assert_eq(frees(), 1);
}

// Many small tasks in flight: every one runs and every capture is destroyed, across block reuse.
@test
fn thousand_tasks_exact() {
    let n: i64 = 1000;
    let wg = sync::WaitGroup::new();
    wg.add(n);
    for i in 0..n {
        let w = wg.clone();
        let t = Tracked { n: i };
        launch || {
            ran(1);
            let _ = t.n;
            w.done();
        };
    }
    wg.wait();
    rt::shutdown();
    assert_eq(runs(), n);
    assert_eq(frees(), n);
}

// --- stacks -----------------------------------------------------------------------------------------------

// Each frame's address escapes, so the optimiser cannot turn the tail call into a loop and the recursion
// really consumes stack, at every optimisation level.
static mut G_FRAME: usize = 0;

fn deep(n: u64, acc: u64) u64 {
    let mut pad = Array::<u64, 8>::new();
    pad[7] = n;
    atomic::store_usize(&mut unsafe G_FRAME, ((&mut pad[0]) as *mut u64) as usize, 0);
    if n == 0 {
        return acc + pad[7];
    }
    return deep(n - 1, acc + pad[7]);
}

// A task recurses well past the pages a shallow task touches; the stack is reserved, not trimmed short.
@test
fn deep_recursion_fits_the_default_stack() {
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch || {
        // About 1500 frames of at least 80 bytes: past 100 KiB of a 256 KiB stack.
        let v = deep(1500, 0);
        ran(v as i64);
        w.done();
    };
    wg.wait();
    rt::shutdown();
    assert_eq(runs(), 1500 * 1501 / 2);
}

fn forever(n: u64) u64 {
    let mut pad = Array::<u64, 32>::new();
    pad[31] = n;
    atomic::store_usize(&mut unsafe G_FRAME, ((&mut pad[0]) as *mut u64) as usize, 0);
    return forever(n + 1) + pad[31];
}

// Past the guard page the task faults into the overflow report, never into the memory below the stack.
@test(should_panic)
fn stack_overflow_hits_the_guard() {
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    launch || {
        ran(forever(0) as i64);
        w.done();
    };
    wg.wait();
}

// Blocks are recycled: a second round of tasks maps no new stacks, and the retained bytes are counted.
@test
fn cached_stacks_are_reused() {
    rt::set_worker_count(2);
    let n: i64 = 64;
    for round in 0..3 {
        let wg = sync::WaitGroup::new();
        wg.add(n);
        for _i in 0..n {
            let w = wg.clone();
            launch || {
                rt::yield_now();
                w.done();
            };
        }
        wg.wait();
        if round == 0 {
            rt::sleep_ns(20000000); // let the blocks settle into the pool
        }
        let mapped = platform::stack_bytes();
        if round > 0 {
            assert(
                mapped <= 2usize * (n as usize + 32) * (262144 + platform::page_size()),
                "no unbounded growth of mappings",
            );
        }
    }
    rt::sleep_ns(20000000);
    assert(rt::pool_retained_bytes() > 0, "the idle pool holds the recycled blocks");
    assert(rt::pool_retained_bytes() <= rt::pool_budget(), "within the budget");
    rt::shutdown();
    assert_eq(platform::stack_bytes(), 0usize);
}

// A small budget: what the idle pool keeps stays within it, and everything past it is released.
@test
fn small_pool_budget_is_honoured() {
    rt::set_worker_count(2);
    let budget: usize = 4usize * 1048576; // 16 blocks at the default stack size
    rt::set_pool_budget(budget);
    let n: i64 = 200;
    let wg = sync::WaitGroup::new();
    wg.add(n);
    let gate = sync::Barrier::new(n + 1);
    for _i in 0..n {
        let w = wg.clone();
        let b = gate.clone();
        launch || {
            let _ = b.wait(); // every task alive at once: 200 blocks exist
            w.done();
        };
    }
    let _ = gate.wait();
    wg.wait();
    rt::sleep_ns(50000000); // workers park: stashes and the shared pool settle, idle trimming runs
    assert(rt::pool_retained_bytes() <= budget, "the idle cache is within the budget");
    let live_blocks = platform::stack_bytes() / (262144 + platform::page_size());
    assert(live_blocks <= 48usize, "released past the budget: at most the budget plus the stashes remain mapped");
    rt::shutdown();
}

// Yields: a task that yields many times still completes exactly once.
@test
fn yields_complete() {
    let wg = sync::WaitGroup::new();
    wg.add(4);
    for _t in 0..4 {
        let w = wg.clone();
        launch || {
            for _i in 0..200 {
                rt::yield_now();
            }
            ran(1);
            w.done();
        };
    }
    wg.wait();
    rt::shutdown();
    assert_eq(runs(), 4);
}

// --- dispatch --------------------------------------------------------------------------------------------

// The records of a dispatch outlive every worker access: a body that records where it ran, many
// dispatches back to back, every index exactly once.
@test
fn dispatch_counts_every_index_once() {
    let n: usize = 10000;
    let hits = atomics::Atomic::<i64>::new(0);
    let hp = &hits;
    for _r in 0..50 {
        data::range(
            0..n,
            |_i: usize| {
                let _ = hp.fetch_add(1, atomics::MemoryOrder::Relaxed);
            },
        );
    }
    assert_eq(hits.load(atomics::MemoryOrder::Acquire), 500000);
    rt::shutdown();
}

// Reduction keeps its result order: chunk results are combined left to right, so a non-commutative
// combine sees them in index order.
@test
fn reduce_combines_in_index_order() {
    let mut v = Vector::<i64>::new();
    for i in 0..1000 {
        v.push(i);
    }
    let n = v.len();
    // Each chunk folds into (first index, last index) pairs encoded as lo * 100000 + hi; combine keeps
    // the left's lo and the right's hi, which is only right when chunks arrive in order.
    let r = data::reduce(
        v[0..n],
        fn() i64 {
            return -1;
        },
        fn(a: i64, x: &i64) i64 {
            if a < 0 {
                return *x * 100000 + *x;
            }
            return a / 100000 * 100000 + *x;
        },
        fn(a: i64, b: i64) i64 {
            return a / 100000 * 100000 + b % 100000;
        },
    );
    assert_eq(r, 999);
    rt::shutdown();
}

// Nested dispatch inside a job runs inline (a job cannot park) with one worker and with every worker busy.
fn nested_sum(n: usize) i64 {
    let total = atomics::Atomic::<i64>::new(0);
    let tp = &total;
    data::range(
        0..n,
        |i: usize| {
            let inner = atomics::Atomic::<i64>::new(0);
            let ip = &inner;
            data::range(
                0..8usize,
                |j: usize| {
                    let _ = ip.fetch_add((i * 8 + j) as i64, atomics::MemoryOrder::Relaxed);
                },
            );
            let _ = tp.fetch_add(inner.load(atomics::MemoryOrder::Acquire), atomics::MemoryOrder::Relaxed);
        },
    );
    return total.load(atomics::MemoryOrder::Acquire);
}

@test
fn nested_dispatch_one_worker() {
    rt::set_worker_count(1);
    let n: usize = 100;
    let want = (n * 8) as i64 * (n * 8 - 1) as i64 / 2;
    assert_eq(nested_sum(n), want);
    rt::shutdown();
}

@test
fn nested_dispatch_every_worker_occupied() {
    rt::set_worker_count(3);
    // Three coroutines dispatch at once: every worker is busy in a chunk when the nested ranges run.
    let wg = sync::WaitGroup::new();
    wg.add(3);
    let ok = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    for _t in 0..3 {
        let w = wg.clone();
        let o = ok.clone();
        launch || {
            let n: usize = 100;
            let want = (n * 8) as i64 * (n * 8 - 1) as i64 / 2;
            if nested_sum(n) == want {
                let _ = o.get().fetch_add(1, atomics::MemoryOrder::Relaxed);
            }
            w.done();
        };
    }
    wg.wait();
    assert_eq(ok.get().load(atomics::MemoryOrder::Acquire), 3);
    rt::shutdown();
}

// A short range gets fewer chunks than workers, and every index still runs once.
@test
fn short_range_runs_every_index() {
    let hits = atomics::Atomic::<i64>::new(0);
    let hp = &hits;
    for n in 1..40usize {
        data::range(
            0..n,
            |_i: usize| {
                let _ = hp.fetch_add(1, atomics::MemoryOrder::Relaxed);
            },
        );
    }
    assert_eq(hits.load(atomics::MemoryOrder::Acquire), 39 * 40 / 2);
    rt::shutdown();
}

// Dynamic scheduling over uneven work: every index exactly once, from a coroutine (masked join) too.
@test
fn dynamic_uneven_work_from_a_task() {
    let wg = sync::WaitGroup::new();
    wg.add(1);
    let w = wg.clone();
    let sum = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let sp = sum.clone();
    launch || {
        let n: usize = 3000;
        let s = sp.get();
        data::range_with(
            0..n,
            data::Options { schedule: data::Schedule::Dynamic, grain_size: 7 },
            |i: usize| {
                let mut acc: u64 = 1;
                for k in 0..i % 64 {
                    acc = acc * 6364136223846793005 + k as u64;
                }
                let _ = s.fetch_add(i as i64 + (acc & 0) as i64, atomics::MemoryOrder::Relaxed);
            },
        );
        w.done();
    };
    wg.wait();
    assert_eq(sum.get().load(atomics::MemoryOrder::Acquire), 3000 * 2999 / 2);
    rt::shutdown();
}

// Sections: each closure box runs once.
@test
fn sections_run_once() {
    data::sections(
        |s: &mut data::Sections| {
            for k in 0..5i64 {
                s.add(
                    || {
                        ran(k + 1);
                    },
                );
            }
        },
    );
    assert_eq(runs(), 15);
    rt::shutdown();
}

// A shutdown that lands while the only worker is on its way to park must still stop it: the worker gives
// the OS the pages of cached stacks before it sleeps, which is the window a shutdown wake-up can fall into.
// More tasks than one worker's stash holds, so the shared pool has blocks to trim; the delay before the
// shutdown scans across the window.
@test
fn shutdown_reaches_a_parking_worker() {
    let mut delay: i64 = 0;
    while delay <= 400000 {
        rt::set_worker_count(1);
        let wg = sync::WaitGroup::new();
        wg.add(64);
        for _i in 0..64 {
            let w = wg.clone();
            launch || {
                w.done();
            };
        }
        wg.wait();
        rt::sleep_ns(delay);
        rt::shutdown();
        delay = delay + 2000;
    }
}

// A task cancelled BEFORE its first run still destroys its inline capture exactly once: the sole worker is
// held busy, so the second task waits in the queue when the request lands; it then starts, reaches its
// first cancellable wait, unwinds and frees what it carries.
@test
fn inline_capture_cancelled_before_first_run_destroyed_once() {
    rt::set_worker_count(1);
    let release = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let holder_id = arc::Arc::<atomics::Atomic<u64>>::new(atomics::Atomic::<u64>::new(0));
    let wg = sync::WaitGroup::new();
    wg.add(2);
    let w1 = wg.clone();
    let r1 = release.clone();
    let h1 = holder_id.clone();
    launch || {
        h1.get().store(rt::current_id(), atomics::MemoryOrder::Release);
        // Busy, not parked: a park would hand the worker to the queued task.
        let mut spins: i64 = 0;
        while r1.get().load(atomics::MemoryOrder::Acquire) == 0 {
            spins = spins + 1;
        }
        ran(spins & 0);
        w1.done();
    };
    let w2 = wg.clone();
    let t = Tracked { n: 7 };
    launch || {
        defer w2.done();
        ran(t.n);
        time::sleep(time::Duration::from_secs(3600)); // the compiled edge unwinds here on cancellation
        ran(100);
    };
    // Both are registered once the snapshot shows two tasks; the one that is not the holder is queued.
    let mut key = rt::TaskKey { slot: 0, gen: 0 };
    let mut found = false;
    let mut tries = 0;
    while !found && tries < 100000 {
        let mut snap = Vector::<rt::TaskInfo>::new();
        rt::task_snapshot(&mut snap);
        let hid = holder_id.get().load(atomics::MemoryOrder::Acquire);
        if snap.len() == 2 && hid != 0 {
            for i in 0..snap.len() {
                if snap.at(i).id != hid {
                    key = snap.at(i).key;
                    found = true;
                }
            }
        }
        tries = tries + 1;
    }
    assert(found, "the queued task is registered");
    assert(rt::request_cancel(key, rt::CR_USER), "the request lands on the queued task");
    release.get().store(1, atomics::MemoryOrder::Release);
    assert(wg.wait_timeout(time::Duration::from_secs(5)), "both tasks finish");
    rt::shutdown();
    assert_eq(frees(), 1);
    assert_eq(runs(), 7);
}
