// Macro-benchmarks: whole workloads rather than single primitives, each swept across worker counts to
// expose scaling cliffs (`bench/sweep.spc`). A micro-benchmark says what one operation costs; these say
// whether the runtime turns more cores into more work.
//
// The workload at each point is IDENTICAL: same task count, same items, same arithmetic. Only the number
// of OS workers changes. A curve is only meaningful if the work is held still. Every workload validates
// its result (items drained, tasks completed) and fails the run on a shortfall; arithmetic results reach
// the optimisation barrier (`bench::black_box`), so the work is performed however hard LTO looks at it.

import stdio;
import std::parallel::runtime as rt;
import std::parallel::sync as sync;
import std::parallel::channel as chan;
import std::parallel::data as data;
import std::parallel::atomics as atomics;
import std::parallel::arc as arc;
import std::parallel::platform as platform;
import std::testing::bench as bench;
import bench::sweep as sweep;

const ITEMS: i64 = 4000; // items through the pipeline
const STAGES: i64 = 8; // pipeline stage tasks (fixed: the workload must not follow the worker count)
const BRANCH: i64 = 16; // fan-out tree: children per node, two levels deep
const MIXED_TASKS: i64 = 8;
const MIXED_OPS: i64 = 500;
const COMPUTE: usize = 2000000; // iterations for the compute-bound lane
const BREAKEVEN_ROUNDS: i32 = 10; // samples per (work, side) point of the break-even table

// The per-task arithmetic count, as a `static mut` because `breakeven` sweeps it.
static mut WORK: i64 = 256;

fn work() i64 {
    return unsafe WORK;
}

// Report a workload that did less than it claims: the sweep row is then not a measurement.
fn check(name: str, got: i64, want: i64) {
    if got != want {
        let mut what = String::from_str(name);
        what.push_str(": completed ");
        what.push_i64(got);
        what.push_str(" of ");
        what.push_i64(want);
        bench::fail(what.as_str());
    }
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
                        let _ = fwd.send(v + bench::burn(work() / 4) as i64);
                    },
                    None => {
                        break;
                    },
                };
            }
            w.done();
        };
    }
    let drained = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let dc = drained.clone();
    let drain = sync::WaitGroup::new();
    drain.add(1);
    let d = drain.clone();
    launch || {
        let mut n: i64 = 0;
        let mut acc: u64 = 0;
        loop {
            switch out_rx.recv() {
                Some(v) => {
                    n = n + 1;
                    acc = acc + v as u64;
                },
                None => {
                    break;
                },
            };
        }
        bench::black_box(acc);
        dc.get().store(n, atomics::MemoryOrder::Release);
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
    check("pipeline", drained.get().load(atomics::MemoryOrder::Acquire), ITEMS);
}

@bench(log_results = false)
/// Benchmark lane: a linear stage pipeline, one item per message.
pub fn pipeline(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    b.set_diag_rounds(0);
    while b.running() {
        sweep::sweep("pipeline", pipeline_once);
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
                    buf.set(i, buf[i] + bench::burn(work() / 4) as i64);
                }
                let _ = fwd.send_batch(&mut buf); // leaves `buf` empty, ready for the next batch
                buf.clear();
            }
            w.done();
        };
    }
    let drained = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let dc = drained.clone();
    let drain = sync::WaitGroup::new();
    drain.add(1);
    let d = drain.clone();
    launch || {
        let mut buf = Vector::<i64>::new();
        let mut n: i64 = 0;
        let mut acc: u64 = 0;
        loop {
            let k = out_rx.recv_batch(&mut buf, BATCH);
            if k == 0 {
                break;
            }
            for i in 0..buf.len() {
                acc = acc + buf[i] as u64;
            }
            n = n + k as i64;
            buf.clear();
        }
        bench::black_box(acc);
        dc.get().store(n, atomics::MemoryOrder::Release);
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
    check("pipeline_batched", drained.get().load(atomics::MemoryOrder::Acquire), ITEMS);
}

@bench(log_results = false)
/// Benchmark lane: the pipeline with batched messages.
pub fn pipeline_batched(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    b.set_diag_rounds(0);
    while b.running() {
        sweep::sweep("pipeline_batched", pipeline_batched_once);
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
// Each cell is the median of BREAKEVEN_ROUNDS rounds.
fn breakeven(name: str, body: fn() void) {
    unsafe stdio::printf(
        "\n  %s: work per item vs. the gain from every core (medians of %d rounds)\n".ptr() as *const char,
        name.ptr() as *const char,
        BREAKEVEN_ROUNDS,
    );
    unsafe stdio::printf(
        "    %-9s %12s %12s %10s %12s %12s\n".ptr() as *const char,
        "work".ptr() as *const char,
        "1 worker ms".ptr() as *const char,
        "N ms".ptr() as *const char,
        "gain".ptr() as *const char,
        "1 wkr Mcyc".ptr() as *const char,
        "N Mcyc".ptr() as *const char,
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
        let mut c = Array::<f64, 2>::new();
        for side in 0..2usize {
            rt::shutdown();
            rt::set_worker_count(
                if side == 0 {
                    1usize;
                } else {
                    ncpu;
                },
            );
            let p = sweep::measure(body, BREAKEVEN_ROUNDS);
            t[side] = p.ms.median;
            c[side] = p.mcyc;
            let mut js = String::with_capacity(512);
            js.push_str("{\"v\":1,\"name\":");
            bench::json_str(&mut js, name);
            js.push_str("_breakeven");
            bench::json_identity(&mut js);
            js.push_str(",\"work\":");
            js.push_i64(steps[k]);
            js.push_str(",\"point_workers\":");
            js.push_u64(
                if side == 0 {
                    1u64;
                } else {
                    ncpu as u64;
                },
            );
            bench::json_dist(&mut js, "ms", &p.ms, 1.0);
            js.push_str(",\"mcyc_per_round\":");
            js.push_f64_prec(p.mcyc, 3);
            js.push_str(",\"cpu_ms_per_round\":");
            js.push_f64_prec(p.cpu_ms, 3);
            js.push_byte(b'}');
            bench::log_line(js.as_str());
        }
        unsafe stdio::printf(
            "    %-9lld %12.3f %12.3f %9.2fx %12.2f %12.2f\n".ptr() as *const char,
            steps[k],
            t[0],
            t[1],
            t[0] / t[1],
            c[0],
            c[1],
        );
    }
    unsafe WORK = saved;
    rt::shutdown();
    rt::set_worker_count(0);
}

@bench(log_results = false)
/// Benchmark lane: pipeline throughput as the work per item varies.
pub fn pipeline_breakeven(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    b.set_diag_rounds(0);
    while b.running() {
        breakeven("pipeline", pipeline_once);
        breakeven("pipeline_batched", pipeline_batched_once);
    }
}

// --- fan-out / fan-in tree --------------------------------------------------------------------------.

// Two levels: `BRANCH` children, each spawning `BRANCH` of its own. Spawning from INSIDE a task is the
// shape that exercises the per-worker queues and stealing rather than the submit path.
fn tree_once() {
    let want = BRANCH * BRANCH + BRANCH;
    let wg = sync::WaitGroup::new();
    wg.add(want);
    for _i in 0..BRANCH {
        let outer = wg.clone();
        launch || {
            for _j in 0..BRANCH {
                let inner = outer.clone();
                launch || {
                    bench::black_box(bench::burn(work()));
                    inner.done();
                };
            }
            bench::black_box(bench::burn(work()));
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
    b.set_diag_rounds(0);
    while b.running() {
        sweep::sweep("fanout_tree", tree_once);
    }
}

// Tasks that both contend on a shared lock and pass messages: the two synchronisation paths interleaved,
// which is where a runtime that is fast at each one separately can still fall over.
fn mixed_once() {
    let counter = arc::Arc::<sync::Mutex<i64>>::new(sync::Mutex::<i64>::new(0));
    let ch = chan::Channel::<i64>::bounded(128);
    let tx = ch.sender();
    let rx = ch.receiver();
    let drained = arc::Arc::<atomics::Atomic<i64>>::new(atomics::Atomic::<i64>::new(0));
    let dc = drained.clone();
    let drain = sync::WaitGroup::new();
    drain.add(1);
    let d = drain.clone();
    launch || {
        let mut n: i64 = 0;
        loop {
            switch rx.recv() {
                Some(_v) => {
                    n = n + 1;
                },
                None => {
                    break;
                },
            };
        }
        dc.get().store(n, atomics::MemoryOrder::Release);
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
    let g = counter.get().lock();
    check("mixed_lock_channel locks", *g.get(), MIXED_TASKS * MIXED_OPS);
    check("mixed_lock_channel messages", drained.get().load(atomics::MemoryOrder::Acquire), MIXED_TASKS * MIXED_OPS);
}

@bench(log_results = false)
/// Benchmark lane: mixed mutex and channel traffic.
pub fn mixed_lock_channel(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    b.set_diag_rounds(0);
    while b.running() {
        sweep::sweep("mixed_lock_channel", mixed_once);
    }
}

// --- compute-bound parallel::range ------------------------------------------------------------------.

// The case the data-parallel API exists for: enough arithmetic that its dispatch (see
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
    check("compute_range", hits.load(atomics::MemoryOrder::Acquire), ((COMPUTE + 65535) / 65536) as i64);
}

@bench(log_results = false)
/// Benchmark lane: data-parallel range over a compute kernel.
pub fn compute_range(b: &mut bench::Bencher) {
    b.set_rounds(1);
    b.set_warmup(0);
    b.set_diag_rounds(0);
    while b.running() {
        sweep::sweep("compute_range", compute_once);
    }
}
