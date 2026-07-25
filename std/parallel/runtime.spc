// The coroutine/task scheduler: a lazily-started, fixed pool of OS worker threads that run detached tasks
// submitted with `launch`. Import with `import std::parallel::runtime;`.
//
// `launch(f)` moves an owning closure onto the heap and hands it to the pool; some worker runs it to
// completion, then frees it. Like `thread::spawn`, `f` must OWN everything it touches (`fn move`) and be
// `Send`, so it may move `String`/`Vector`/`Arc`/... in but never borrow a caller local -- the escape rule
// rejects that at the call site. Share across tasks through `Arc`; coordinate with the `sync` primitives.
//
// The pool starts on the first `launch` (a program that never launches pays nothing) and is torn down by
// `shutdown()`, which drains the queue, joins the workers and frees the scheduler. Blocking a task blocks
// its worker thread for now (task-aware parking that frees the worker is a later milestone); the M2 context
// switch in `sc_runtime` is the substrate that will carry it.

import pthread;
import atomic;
import std::parallel::platform as platform;

/// A type-erased unit of work: `run(env)` reconstructs the boxed closure, runs it, and frees the box.
pub struct Job {
    pub run: fn(*mut void) void,
    pub env: *mut void,
}

/// The shared pool state. One instance lives behind `G_SCHED`; its fields are `pub` only so the generic
/// `launch` (monomorphized in the caller's module) can enqueue -- not a user-facing type.
pub struct Scheduler {
    pub q: Vector<Job>,
    pub lock: *mut void, // pthread_mutex (sc_mutex_new)
    pub cv: *mut void, // pthread_cond  (sc_cond_new)
    pub workers: Vector<pthread::pthread_t>,
    pub shutting_down: i32, // guarded by `lock`
}

// The single global pool, guarded by a small init state machine (0 = uninit, 1 = building, 2 = ready) so the
// first `launch` on any thread starts it exactly once. `static mut`, reached only through atomics on G_STATE.
static mut G_STATE: i32 = 0;
static mut G_SCHED: *mut Scheduler = null;

// The C-ABI worker entry: block on the queue, run jobs, and exit once the pool is shutting down and drained.
fn worker_main(arg: *mut void) *mut void {
    let s = arg as *mut Scheduler;
    loop {
        unsafe pthread::pthread_mutex_lock((*s).lock);
        while unsafe (*s).q.len() == 0 && unsafe (*s).shutting_down == 0 {
            unsafe pthread::pthread_cond_wait((*s).cv, (*s).lock);
        }
        if unsafe (*s).q.len() == 0 {
            unsafe pthread::pthread_mutex_unlock((*s).lock);
            break; // shutting down and the queue is drained
        }
        let job = unsafe (*s).q.pop().unwrap();
        unsafe pthread::pthread_mutex_unlock((*s).lock);
        let entry = job.run;
        entry(job.env);
    }
    return null;
}

// Allocate the pool, create its lock/cond, and spawn one worker per CPU.
fn build_scheduler() *mut Scheduler {
    let mut g = Global {};
    let s = g.alloc(sizeof(Scheduler), alignof(Scheduler)) as *mut Scheduler;
    let lk = unsafe pthread::sc_mutex_new();
    let cvh = unsafe pthread::sc_cond_new();
    unsafe s[0] = Scheduler {
        q: Vector::<Job>::new(),
        lock: lk,
        cv: cvh,
        workers: Vector::<pthread::pthread_t>::new(),
        shutting_down: 0,
    };
    let nw = platform::ncpu();
    for _i in 0..nw {
        let mut h: pthread::pthread_t;
        unsafe pthread::pthread_create(&mut h, null, worker_main, s);
        unsafe (*s).workers.push(h);
    }
    return s;
}

/// Start the pool if it is not running yet and return it. Thread-safe: the first caller builds it, the rest
/// wait for it to become ready. `pub` for linkage -- `launch` is monomorphized in the caller's module.
pub fn ensure_started() *mut Scheduler {
    // Order codes (see MemoryOrder): 0 Relaxed, 1 Acquire, 2 Release, 4 SeqCst.
    let sp = (&mut G_STATE) as *mut i32;
    if atomic::load_i32(sp, 1) == 2 {
        return G_SCHED;
    }
    if atomic::cas_i32(sp, 0, 1, false, 4, 0) {
        let s = build_scheduler();
        G_SCHED = s;
        atomic::store_i32(sp, 2, 2);
        return s;
    }
    while atomic::load_i32(sp, 1) != 2 {}
    return G_SCHED;
}

/// The per-`F` trampoline handed to the pool: move the closure out of its heap box, free the box, and run
/// it. The closure value is dropped when it returns, freeing any owned captures. `pub` for linkage.
pub fn job_entry<F: fn move()>(env: *mut void) {
    let pp = env as *mut F;
    let f = unsafe {
        pp[0];
    };
    let mut g = Global {};
    g.dealloc(env, sizeof(F), alignof(F));
    f();
}

/// Submit `f` to run on the pool as a detached task. Starts the pool on first use. `f` owns its captures and
/// must be `Send`; it is moved onto the heap and freed after it runs. The `launch` statement lowers to this.
pub fn submit<F: fn move() + Send>(f: F) {
    let s = ensure_started();
    let mut g = Global {};
    let slot = g.alloc(sizeof(F), alignof(F)) as *mut F;
    unsafe slot[0] = f;
    let job = Job { run: job_entry::<F>, env: slot };
    unsafe pthread::pthread_mutex_lock((*s).lock);
    unsafe (*s).q.push(job);
    unsafe pthread::pthread_cond_signal((*s).cv);
    unsafe pthread::pthread_mutex_unlock((*s).lock);
}

/// Drain the queue, stop and join every worker, and free the pool. Idempotent; a no-op if never started.
/// Call it once, from the main thread, when all launched work has been awaited (e.g. via a `WaitGroup`).
pub fn shutdown() {
    let sp = (&mut G_STATE) as *mut i32;
    if atomic::load_i32(sp, 1) != 2 {
        return;
    }
    let s = G_SCHED;
    unsafe pthread::pthread_mutex_lock((*s).lock);
    unsafe (*s).shutting_down = 1;
    unsafe pthread::pthread_cond_broadcast((*s).cv);
    unsafe pthread::pthread_mutex_unlock((*s).lock);
    let nw = unsafe (*s).workers.len();
    for i in 0..nw {
        let h = unsafe (*s).workers[i];
        unsafe pthread::pthread_join(h, null);
    }
    unsafe (*s).workers.free();
    unsafe (*s).q.free();
    unsafe pthread::sc_mutex_free((*s).lock);
    unsafe pthread::sc_cond_free((*s).cv);
    let mut g = Global {};
    g.dealloc(s, sizeof(Scheduler), alignof(Scheduler));
    atomic::store_i32(sp, 0, 2);
    G_SCHED = null;
}
