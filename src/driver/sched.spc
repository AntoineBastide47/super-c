// The item job runner: a dependency graph of bounded jobs executed on the production runtime.
// A job runs once every job it depends on has completed; the job that completes the last
// dependency launches it. Of the jobs ready at the start, the one on the costliest remaining
// chain launches first. One worker (`jobs == 1`) runs the graph in its stable order on the
// calling thread, with no runtime, so the serial pipeline and the parallel one execute one code
// path over one graph.
import stdlib;
import atomic;
import std::parallel::runtime as prt;
import std::parallel::sync as psync;
import driver::taskctl as tctl;

/// A job graph: `pending[j]` counts the dependencies job `j` still waits for, `succ` (CSR by
/// job) lists the jobs that wait for it, `order` is the serial execution order (a topological
/// order: every job after its dependencies), `est` the estimated bytes each job puts in flight
/// for the memory gate, `cost` its estimated work (any unit; 0 counts as 1), which picks the job
/// that launches first.
pub(package) struct Jobs {
    pub(package) n: usize,
    pub(package) pending: Vector<u32>,
    pub(package) succ_off: Vector<u32>,
    pub(package) succ: Vector<u32>,
    pub(package) order: Vector<u32>,
    pub(package) est: Vector<u64>,
    pub(package) cost: Vector<u64>,
}

extend Jobs {
    /// `n` jobs with the dependencies in `edges` (`pred << 32 | succ`, each pair once) and the
    /// serial order `order` (every job after its dependencies).
    pub(package) fn from_edges(n: usize, edges: &Vector<u64>, order: Vector<u32>) Jobs {
        let mut j = Jobs::independent(n);
        // Every edge must run forward in the serial order: a backward one is a cycle, which the
        // parallel path would wait on forever.
        let mut pos = Vector::<u32>::new();
        pos.resize_default(n);
        for k in 0..order.len() {
            pos.set(order[k] as usize, k as u32);
        }
        for i in 0..edges.len() {
            assert(
                pos[(edges[i] >> 32) as usize] < pos[(edges[i] & 0xFFFFFFFFu64) as usize],
                "job graph edge against the serial order",
            );
        }
        j.order = order;
        j.succ_off.clear();
        j.succ_off.resize_default(n + 1);
        for i in 0..edges.len() {
            let a = (edges[i] >> 32) as usize;
            let b = (edges[i] & 0xFFFFFFFFu64) as usize;
            j.succ_off.set(a + 1, j.succ_off[a + 1] + 1);
            j.pending.set(b, j.pending[b] + 1);
        }
        for i in 0..n {
            j.succ_off.set(i + 1, j.succ_off[i + 1] + j.succ_off[i]);
        }
        j.succ.resize_default(edges.len());
        let mut fill = Vector::<u32>::new();
        fill.resize_default(n);
        for i in 0..edges.len() {
            let a = (edges[i] >> 32) as usize;
            j.succ.set((j.succ_off[a] + fill[a]) as usize, (edges[i] & 0xFFFFFFFFu64) as u32);
            fill.set(a, fill[a] + 1);
        }
        return j;
    }

    /// `n` independent jobs in index order.
    pub(package) fn independent(n: usize) Jobs {
        let mut j = Jobs {
            n: n,
            pending: Vector::<u32>::new(),
            succ_off: Vector::<u32>::new(),
            succ: Vector::<u32>::new(),
            order: Vector::<u32>::new(),
            est: Vector::<u64>::new(),
            cost: Vector::<u64>::new(),
        };
        j.pending.resize_default(n);
        j.succ_off.resize_default(n + 1);
        j.est.resize_default(n);
        j.cost.resize_default(n);
        j.order.reserve(n);
        for i in 0..n {
            j.order.push(i as u32);
        }
        return j;
    }
}

// One job on a worker: the graph, its live dependency counts (`g.pending`, taken from the
// caller's exclusive borrow), the stage's callback and context, the job's index.
struct Task {
    pub(package) g: *const Jobs,
    pub(package) pend: *mut u32,
    pub(package) run: fn(*mut void, u32) void,
    pub(package) ctx: *mut void,
    pub(package) j: u32,
    pub(package) ctl: *const tctl::Ctl,
    pub(package) seed: u32, // SC_TASK_DELAY seed; 0 = no stagger
}

// The callback's context and the graph are shared by every task of the stage and outlive the
// stage's join; a task touches only its own job's outputs.
unsafe extend Task as Send {}

fn spawn(t: Task, wg: &psync::WaitGroup) {
    if t.ctl != null {
        // The submitter parks until the job's estimate fits the budget: a frontier never puts
        // more estimated bytes in flight than the build allows.
        (unsafe &*t.ctl).acquire(unsafe (&*t.g).est[t.j as usize]);
    }
    let wgc = wg.clone();
    launch || {
        run_task(t, &wgc);
        wgc.done();
    };
}

fn run_task(t: Task, wg: &psync::WaitGroup) {
    if t.seed != 0 {
        // SC_TASK_DELAY=<seed>: a deterministic per-job stagger (100 to 400 us, a hash of the job
        // and the seed), so the identity gates run under schedules the machine would not
        // produce by itself and a different one per seed.
        let h = t.j.wrapping_mul(0x9E3779B1u32) ^ t.seed.wrapping_mul(0x85EBCA6Bu32);
        prt::sleep_ns(((h >> 24 & 3) as i64 + 1) * 100000);
    }
    let run = t.run;
    run(t.ctx, t.j);
    if t.ctl != null {
        (unsafe &*t.ctl).release(unsafe (&*t.g).est[t.j as usize]);
    }
    let g = unsafe &*t.g;
    for k in g.succ_off[t.j as usize] as usize..g.succ_off[t.j as usize + 1] as usize {
        let s = g.succ[k];
        // Release: this job's writes happen-before the successor's start (it reads them).
        let left = unsafe atomic::sub_u32(unsafe (t.pend + s as usize), 1, 3);
        if left == 1 {
            spawn(Task { g: t.g, pend: t.pend, run: t.run, ctx: t.ctx, j: s, ctl: t.ctl, seed: t.seed }, wg);
        }
    }
}

/// Run every job of `g` through `run(ctx, job)`: in `order` on the calling thread when `workers`
/// is 1, else on the runtime with `workers` workers, each job started by the completion of its
/// last dependency, the job ready at the start on the costliest remaining chain first. `ctl`
/// (null = off) gates the estimated bytes in flight. Returns once every job has completed. The
/// parallel path counts `g.pending` down to zero, so a graph runs once.
pub(package) fn run_jobs(
    g: &mut Jobs,
    workers: u32,
    run: fn(*mut void, u32) void,
    ctx: *mut void,
    ctl: *const tctl::Ctl,
) {
    if workers == 1 || g.n <= 1 {
        for k in 0..g.order.len() {
            run(ctx, g.order[k]);
        }
        return;
    }
    if workers >= 2 {
        prt::set_worker_count(workers as usize);
    }
    prt::set_stack_size(8usize << 20); // the checker's expression recursion outgrows the default task stack
    let wg = psync::WaitGroup::new();
    wg.add(g.n as i64);
    let dv = stdlib::getenv("SC_TASK_DELAY");
    let mut seed: u32 = 0;
    if dv != null {
        seed = (unsafe stdlib::atoi(dv)) as u32;
        if seed == 0 {
            seed = 1;
        }
    }
    // A job's rank: its cost plus its costliest successor's rank, over the serial order backward
    // (every successor after its job), saturated at 32 bits.
    let mut rank = Vector::<u32>::new();
    rank.resize_default(g.n);
    let mut k = g.order.len();
    while k > 0 {
        k -= 1;
        let j = g.order[k] as usize;
        let mut best: u64 = 0;
        for e in g.succ_off[j] as usize..g.succ_off[j + 1] as usize {
            let s = rank[g.succ[e] as usize] as u64;
            if s > best {
                best = s;
            }
        }
        let sum = best + if g.cost[j] == 0 {
            1u64
        } else {
            g.cost[j]
        };
        rank.set(
            j,
            if sum > 0xFFFFFFFFu64 {
                0xFFFFFFFFu32
            } else {
                sum as u32
            },
        );
    }
    // The initial ready set is read before any job runs: a completing job decrements live
    // counters, and a job whose count it takes to zero is its to launch. Its costliest chain
    // launches first, the rest in index order: the costliest first throughout put the largest jobs
    // in flight together, which raised the peak memory.
    let mut ready = Vector::<u32>::new();
    let mut top: usize = 0;
    for j in 0..g.n {
        if g.pending[j] == 0 {
            if ready.len() == 0 || rank[j] > rank[ready[top] as usize] {
                top = ready.len();
            }
            ready.push(j as u32);
        }
    }
    let pend: *mut u32 = g.pending.index_mut(0);
    spawn(Task { g: g, pend: pend, run: run, ctx: ctx, j: ready[top], ctl: ctl, seed: seed }, &wg);
    for k in 0..ready.len() {
        if k != top {
            spawn(Task { g: g, pend: pend, run: run, ctx: ctx, j: ready[k], ctl: ctl, seed: seed }, &wg);
        }
    }
    wg.wait_masked();
}
