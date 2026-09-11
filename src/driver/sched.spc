// The item job runner: a dependency graph of bounded jobs executed on the production runtime.
// A job runs once every job it depends on has completed; the job that completes the last
// dependency launches it. One worker (`jobs == 1`) runs the graph in its stable order on the
// calling thread, with no runtime, so the serial pipeline and the parallel one execute one
// code path over one graph.
import stdlib;
import atomic;
import std::parallel::runtime as prt;
import std::parallel::sync as psync;
import driver::taskctl as tctl;

/// A job graph: `pending[j]` counts the dependencies job `j` still waits for, `succ` (CSR by
/// job) lists the jobs that wait for it, `order` is the serial execution order (a topological
/// order: every job after its dependencies), `est` the estimated bytes each job puts in flight
/// for the memory gate.
pub struct Jobs {
    pub n: usize,
    pub pending: Vector<u32>,
    pub succ_off: Vector<u32>,
    pub succ: Vector<u32>,
    pub order: Vector<u32>,
    pub est: Vector<u64>,
}

extend Jobs {
    /// `n` jobs with the dependencies in `edges` (`pred << 32 | succ`, each pair once) and the
    /// serial order `order` (every job after its dependencies).
    pub fn from_edges(n: usize, edges: &Vector<u64>, order: Vector<u32>) Jobs {
        let mut j = Jobs::independent(n);
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
    pub fn independent(n: usize) Jobs {
        let mut j = Jobs {
            n: n,
            pending: Vector::<u32>::new(),
            succ_off: Vector::<u32>::new(),
            succ: Vector::<u32>::new(),
            order: Vector::<u32>::new(),
            est: Vector::<u64>::new(),
        };
        j.pending.resize_default(n);
        j.succ_off.resize_default(n + 1);
        j.est.resize_default(n);
        j.order.reserve(n);
        for i in 0..n {
            j.order.push(i as u32);
        }
        return j;
    }
}

// One job on a worker: the graph, the stage's callback and context, the job's index.
struct Task {
    pub g: *const Jobs,
    pub run: fn(*mut void, u32) void,
    pub ctx: *mut void,
    pub j: u32,
    pub ctl: *const tctl::Ctl,
    pub seed: u32, // SC_TASK_DELAY seed; 0 = no stagger
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
        let h = t.j * 0x9E3779B1u32 ^ t.seed * 0x85EBCA6Bu32;
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
        let left = atomic::sub_u32(unsafe (g.pending.as_ptr() as *mut u32 + s as usize), 1, 3);
        if left == 1 {
            spawn(Task { g: t.g, run: t.run, ctx: t.ctx, j: s, ctl: t.ctl, seed: t.seed }, wg);
        }
    }
}

/// Run every job of `g` through `run(ctx, job)`: in `order` on the calling thread when `workers`
/// is 1, else on the runtime with `workers` workers, each job started by the completion of its
/// last dependency. `ctl` (null = off) gates the estimated bytes in flight. Returns once every
/// job has completed.
pub fn run_jobs(g: &Jobs, workers: u32, run: fn(*mut void, u32) void, ctx: *mut void, ctl: *const tctl::Ctl) {
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
    // The initial ready set is read before any job runs: a completing job decrements live
    // counters, and a job whose count it takes to zero is its to launch.
    let mut ready = Vector::<u32>::new();
    for j in 0..g.n {
        if g.pending[j] == 0 {
            ready.push(j as u32);
        }
    }
    for k in 0..ready.len() {
        spawn(Task { g: g, run: run, ctx: ctx, j: ready[k], ctl: ctl, seed: seed }, &wg);
    }
    wg.wait_masked();
}
