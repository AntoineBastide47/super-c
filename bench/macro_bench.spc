// M7's macro-benchmarks: whole workloads rather than single primitives, each swept across worker counts to
// expose scaling cliffs. A micro-benchmark says what one operation costs; these say whether the runtime
// turns more cores into more work.
//
// The sweep runs IN PROCESS. A pool's size is fixed once it starts, but `shutdown` releases it and
// `set_worker_count` is honoured by the next one, so each point tears the pool down and builds a new one.
// Every lane restores the default (`set_worker_count(0)`) before returning, or every benchmark scheduled
// after it would silently inherit a one-worker pool.
//
// The workload at each point is IDENTICAL: same task count, same items, same arithmetic. Only the number
// of OS workers changes. A curve is only meaningful if the work is held still.

import stdio;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::channel as chan;
import std::parallel::data as data;
import std::parallel::atomics as atomics;
import std::parallel::arc as arc;
import std::parallel::platform as platform;
import std::testing::bench as bench;

const POINT_ROUNDS: i32 = 5; // timed rounds per worker count; the minimum is reported
const ITEMS: i64 = 4000; // items through the pipeline
const STAGES: i64 = 8; // pipeline stage tasks (fixed: the workload must not follow the worker count)
const BRANCH: i64 = 16; // fan-out tree: children per node, two levels deep
const MIXED_TASKS: i64 = 8;
const MIXED_OPS: i64 = 500;
const COMPUTE: usize = 2000000; // iterations for the compute-bound lane

// The per-task arithmetic count, as a `static mut` rather than a constant ON PURPOSE. With a literal
// argument LTO folds `burn(256)` to its answer at compile time and the task does no work at all, which had
// `fanout_tree` reporting 0.04ms for arithmetic that costs 0.10ms to perform. A mutable static cannot be
// folded, because nothing can prove it was not written.
static mut WORK: i64 = 256;

// A little arithmetic so a task is not pure scheduling. Unsigned: it wraps at width where the signed form
// would trap on overflow. Callers must OBSERVE the result: `let _ = burn(n)` is a pure call with a
// discarded value and LTO deletes it outright, which had `fanout_tree` reporting a time below the cost of
// the arithmetic it was supposed to be doing.
// Consume a value so the computation that produced it cannot be optimised away. Never prints.
fn keep(v: u64) {
    if v == 7u64 {
        unsafe stdio::printf("".ptr() as *const char);
    }
}

fn burn(rounds: i64) u64 {
    let mut acc: u64 = 1;
    for i in 0..rounds {
        acc = acc * 6364136223846793005 + i as u64;
    }
    return acc;
}

// Run `body` at each worker count and print a row per point: wall time and speedup against one worker.
// `body` must leave no task running: the pool is torn down between points.
fn sweep(name: str, body: fn() void) {
    unsafe stdio::printf("\n  %s: fixed workload, varying workers\n".ptr() as *const char, name.ptr() as *const char);
    unsafe stdio::printf(
        "    %-9s %12s %10s\n".ptr() as *const char,
        "workers".ptr() as *const char,
        "ms".ptr() as *const char,
        "speedup".ptr() as *const char,
    );
    let ncpu = platform::ncpu();
    let mut counts = Array::<usize, 5>::new();
    counts[0] = 1;
    counts[1] = 2;
    counts[2] = 4;
    counts[3] = 8;
    counts[4] = ncpu;
    let mut base: f64 = 0.0;
    for k in 0..5usize {
        let n = counts[k];
        if k > 0 && n <= counts[k - 1] {
            // A machine with few cores: skip a point the sweep already covered.
            continue;
        }
        rt::shutdown(); // release the previous pool so the next size is honoured
        rt::set_worker_count(n);
        // Warm: builds the pool and faults in the first stacks.
        body();
        let mut best: f64 = 0.0;
        for r in 0..POINT_ROUNDS {
            let t0 = platform::now_ns();
            body();
            let dt = (platform::now_ns() - t0) as f64 / 1000000.0;
            if r == 0 || dt < best {
                best = dt;
            }
        }
        if k == 0 {
            base = best;
        }
        unsafe stdio::printf("    %-9zu %12.2f %9.2fx\n".ptr() as *const char, n, best, base / best);
    }
    rt::shutdown();
    rt::set_worker_count(0); // back to one worker per CPU for whatever runs next
}

// --- producer / consumer pipeline -------------------------------------------------------------------.

// One producer feeds `STAGES` worker tasks over a channel; each does a little arithmetic per item and
// forwards it; one consumer drains the far end. The classic shape a server has.
fn pipeline_once() {
    let input = chan::Channel::<i64>::bounded(256);
    let output = chan::Channel::<i64>::bounded(256);
    let tx = input.sender(); // before any consumer starts: a zero sender count reads as "closed"
    let out_rx = output.receiver();
    let wg = sync::WaitGroup::new();
    wg.add(STAGES);
    for _s in 0..STAGES {
        let rx = input.receiver();
        let fwd = output.sender();
        let w = wg.clone();
        launch || {
            loop {
                switch rx.recv() {
                    Some(v) => {
                        let _ = fwd.send(v + burn(unsafe WORK / 4) as i64);
                    },
                    None => {
                        break;
                    },
                };
            }
            w.done();
        };
    }
    let drain = sync::WaitGroup::new();
    drain.add(1);
    let d = drain.clone();
    launch || {
        loop {
            switch out_rx.recv() {
                Some(_v) => {},
                None => {
                    break;
                },
            };
        }
        d.done();
    };
    for i in 0..ITEMS {
        let _ = tx.send(i);
    }
    tx.close();
    // Every stage has finished, so no sender remains on `output`.
    wg.wait();
    output.sender().close();
    drain.wait();
}

@bench(log_results = false)
/// Benchmark lane: a linear stage pipeline, one item per message.
pub fn pipeline(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    while b.running() {
        sweep("pipeline", pipeline_once);
    }
}

// The same pipeline moved in batches of `BATCH`: one lock, one unlock and one wake per batch rather than per
// item, at every hop. Directly comparable to `pipeline` above: same items, same stages, same arithmetic;
// so the difference between the two curves is exactly what per-item channel overhead costs a pipeline.
const BATCH: usize = 64;

fn pipeline_batched_once() {
    let input = chan::Channel::<i64>::bounded(256);
    let output = chan::Channel::<i64>::bounded(256);
    let tx = input.sender();
    let out_rx = output.receiver();
    let wg = sync::WaitGroup::new();
    wg.add(STAGES);
    for _s in 0..STAGES {
        let rx = input.receiver();
        let fwd = output.sender();
        let w = wg.clone();
        launch || {
            let mut buf = Vector::<i64>::new();
            loop {
                let k = rx.recv_batch(&mut buf, BATCH);
                if k == 0 {
                    break;
                }
                for i in 0..buf.len() {
                    buf.set(i, buf[i] + burn(unsafe WORK / 4) as i64);
                }
                let _ = fwd.send_batch(&mut buf); // leaves `buf` empty, ready for the next batch
                buf.clear();
            }
            w.done();
        };
    }
    let drain = sync::WaitGroup::new();
    drain.add(1);
    let d = drain.clone();
    launch || {
        let mut buf = Vector::<i64>::new();
        loop {
            if out_rx.recv_batch(&mut buf, BATCH) == 0 {
                break;
            }
            buf.clear();
        }
        d.done();
    };
    let mut out = Vector::<i64>::new();
    let mut i: i64 = 0;
    while i < ITEMS {
        // Short final batch: the ITEM COUNT must equal `pipeline`'s exactly or the curves are not comparable.
        let take = if ITEMS - i < BATCH as i64 {
            ITEMS - i;
        } else {
            BATCH as i64;
        };
        for j in 0..take {
            out.push(i + j);
        }
        let _ = tx.send_batch(&mut out);
        i = i + take;
    }
    tx.close();
    wg.wait();
    output.sender().close();
    drain.wait();
}

@bench(log_results = false)
/// Benchmark lane: the pipeline with batched messages.
pub fn pipeline_batched(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    while b.running() {
        sweep("pipeline_batched", pipeline_batched_once);
    }
}

// --- break-even ---------------------------------------------------------------------------------------.

// The one number here that a choice of workload cannot flatter: how much work an item must carry before
// spreading the pipeline over every core beats keeping it on one.
//
// A speedup quoted at a single `WORK` says only what `WORK` was chosen: ANY scheduler, however bad, reaches
// linear scaling once the work per synchronisation dwarfs the synchronisation. Sweeping `WORK` instead and
// reporting where the all-cores time crosses the one-core time measures the runtime rather than the
// benchmark: the crossover IS the per-item synchronisation cost, in units of work.
//
// Read the table as: below the crossover, `launch`ing this across N cores makes it slower; above it, faster.
fn breakeven(name: str, body: fn() void) {
    unsafe stdio::printf(
        "\n  %s: work per item vs. the gain from every core\n".ptr() as *const char,
        name.ptr() as *const char,
    );
    unsafe stdio::printf(
        "    %-9s %12s %12s %10s\n".ptr() as *const char,
        "work".ptr() as *const char,
        "1 worker ms".ptr() as *const char,
        "N ms".ptr() as *const char,
        "gain".ptr() as *const char,
    );
    let ncpu = platform::ncpu();
    let mut steps = Array::<i64, 6>::new();
    steps[0] = 16;
    steps[1] = 64;
    steps[2] = 256;
    steps[3] = 1024;
    steps[4] = 4096;
    steps[5] = 16384;
    let saved = unsafe WORK;
    for k in 0..6usize {
        unsafe WORK = steps[k];
        let mut t = Array::<f64, 2>::new();
        for side in 0..2usize {
            rt::shutdown();
            rt::set_worker_count(
                if side == 0 {
                    1usize;
                } else {
                    ncpu;
                },
            );
            // Warm.
            body();
            let mut best: f64 = 0.0;
            for r in 0..3 {
                let t0 = platform::now_ns();
                body();
                let dt = (platform::now_ns() - t0) as f64 / 1000000.0;
                if r == 0 || dt < best {
                    best = dt;
                }
            }
            t[side] = best;
        }
        unsafe stdio::printf(
            "    %-9lld %12.2f %12.2f %9.2fx\n".ptr() as *const char,
            steps[k],
            t[0],
            t[1],
            t[0] / t[1],
        );
    }
    unsafe WORK = saved;
    rt::shutdown();
    rt::set_worker_count(0);
}

@bench(log_results = false)
/// Benchmark lane: pipeline throughput as batch size varies.
pub fn pipeline_breakeven(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    while b.running() {
        breakeven("pipeline", pipeline_once);
        breakeven("pipeline_batched", pipeline_batched_once);
    }
}

// --- fan-out / fan-in tree --------------------------------------------------------------------------.

// Two levels: `BRANCH` children, each spawning `BRANCH` of its own. Spawning from INSIDE a task is the
// shape that exercises the per-worker queues and stealing rather than the submit path.
fn tree_once() {
    let wg = sync::WaitGroup::new();
    wg.add(BRANCH * BRANCH + BRANCH);
    for _i in 0..BRANCH {
        let outer = wg.clone();
        launch || {
            for _j in 0..BRANCH {
                let inner = outer.clone();
                launch || {
                    keep(burn(unsafe WORK));
                    inner.done();
                };
            }
            keep(burn(unsafe WORK));
            outer.done();
        };
    }
    wg.wait();
}

@bench(log_results = false)
/// Benchmark lane: a fan-out/fan-in task tree.
pub fn fanout_tree(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    while b.running() {
        sweep("fanout_tree", tree_once);
    }
}

// Tasks that both contend on a shared lock and pass messages: the two synchronisation paths interleaved,
// which is where a runtime that is fast at each one separately can still fall over.
fn mixed_once() {
    let counter = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let ch = chan::Channel::<i64>::bounded(128);
    let tx = ch.sender();
    let rx = ch.receiver();
    let drain = sync::WaitGroup::new();
    drain.add(1);
    let d = drain.clone();
    launch || {
        loop {
            switch rx.recv() {
                Some(_v) => {},
                None => {
                    break;
                },
            };
        }
        d.done();
    };
    let wg = sync::WaitGroup::new();
    wg.add(MIXED_TASKS);
    for _t in 0..MIXED_TASKS {
        let w = wg.clone();
        let m = counter.clone();
        let s = tx.clone();
        launch || {
            for i in 0..MIXED_OPS {
                {
                    let mut g = m.get().lock();
                    let v = g.get_mut();
                    *v = *v + 1;
                }
                let _ = s.send(i);
            }
            w.done();
        };
    }
    wg.wait();
    tx.close();
    drain.wait();
}

@bench(log_results = false)
/// Benchmark lane: mixed mutex and channel traffic.
pub fn mixed_lock_channel(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    while b.running() {
        sweep("mixed_lock_channel", mixed_once);
    }
}

// --- compute-bound parallel::range ------------------------------------------------------------------.

// The case the data-parallel API exists for: enough arithmetic that its ~180us dispatch (see
// `micro_bench::parallel_range`) is amortised and the curve shows what the chunking buys.
fn compute_once() {
    let hits = atomics::Atomic::<i64>::new(0);
    let hp = &hits;
    data::range(
        0..COMPUTE,
        |i: usize| {
            if i % 65536 == 0 {
                let _ = hp.fetch_add(1, atomics::MemoryOrder::Relaxed);
            }
        },
    );
}

@bench(log_results = false)
/// Benchmark lane: data-parallel range over a compute kernel.
pub fn compute_range(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    while b.running() {
        sweep("compute_range", compute_once);
    }
}
