// The M:N coroutine scheduler: a lazily-started, fixed pool of OS worker threads that run detached tasks
// submitted with `launch`. Import with `import std::parallel::runtime;`.
//
// Each `launch(f)` becomes a STACKFUL COROUTINE -- an owning `Send` closure on its own guard-paged stack.
// A worker switches into a coroutine (M2's `sc_rt` context switch); when the coroutine blocks on a
// task-aware primitive (e.g. a `channel`), it PARKS -- saves its context and hands the worker back to the
// scheduler, which runs another coroutine -- instead of blocking the OS thread. `park_current`/`wake`/
// `current` are the primitives task-aware waits build on; `yield_now` cooperatively reschedules.
//
// A coroutine and the worker running it are the SAME OS thread (the switch only swaps stacks), so a
// coroutine's own fields (`done`, the commit hand-off) need no atomics; only the shared run queue and the
// wait queues (owned by each primitive) are locked. The pool starts on the first `launch` and is torn down
// by `shutdown()` (call it once, from the main thread, after all launched work has been awaited).

import pthread;
import atomic;
import sc_runtime;
import std::parallel::platform as platform;

// Leak-tracker backtrace suppression (super_rt.c): a coroutine stack has no clean base frame, so the tracker
// must not unwind it. Brackets each coroutine run slice; a no-op when leak checking is off.
extern "C" {
    fn sc_lk_bt_pause() void;
    fn sc_lk_bt_resume() void;
}

const STACK_SIZE: usize = 262144; // 256 KiB guard-paged stack per coroutine

/// A stackful task. `next` links it into exactly ONE intrusive list at a time (the run queue, or a
/// primitive's wait queue). `pub` only so task-aware primitives can hold `*mut Coroutine` and enqueue --
/// not a user-facing type.
pub struct Coroutine {
    pub ctx: *mut void, // sc_rt saved context
    pub stack: *mut void, // guard-paged stack (usable low end)
    pub entry: fn(*mut void) void, // per-F closure trampoline (job_entry::<F>)
    pub env: *mut void, // heap-boxed closure
    pub done: i32, // set by the coroutine when its body returns
    pub sched_ctx: *mut void, // the running worker's scheduler context (set on switch-in)
    pub next: *mut Coroutine, // intrusive queue link
    pub commit_lock: *mut void, // park hand-off: unlock this after the context is saved (null = none)
    pub commit_requeue: i32, // yield hand-off: re-enqueue this coroutine as runnable
    pub inited: i32, // context set up (lazily, on the first worker to run it)
}

/// The shared pool. Fields are `pub` only for the caller-monomorphized `launch` / task-aware primitives.
pub struct Scheduler {
    pub run_head: *mut Coroutine, // runnable FIFO
    pub run_tail: *mut Coroutine,
    pub lock: *mut void, // guards the run queue + shutting_down
    pub cv: *mut void, // workers wait here when the run queue is empty
    pub workers: Vector<pthread::pthread_t>,
    pub shutting_down: i32,
}

// The single global pool, guarded by a 0=uninit / 1=building / 2=ready init state machine.
static mut G_STATE: i32 = 0;
static mut G_SCHED: *mut Scheduler = null;

// Append `co` to the runnable queue and wake one idle worker. Caller must NOT hold `co` in any other list.
fn enqueue_runnable(s: *mut Scheduler, co: *mut Coroutine) {
    unsafe (*co).next = null;
    unsafe pthread::pthread_mutex_lock((*s).lock);
    if unsafe (*s).run_tail == null {
        unsafe (*s).run_head = co;
    } else {
        unsafe (*(*s).run_tail).next = co;
    }
    unsafe (*s).run_tail = co;
    unsafe pthread::pthread_cond_signal((*s).cv);
    unsafe pthread::pthread_mutex_unlock((*s).lock);
}

// Pop the next runnable coroutine, blocking the worker while the queue is empty; null once shut down + empty.
fn dequeue_runnable(s: *mut Scheduler) *mut Coroutine {
    unsafe pthread::pthread_mutex_lock((*s).lock);
    while unsafe (*s).run_head == null && unsafe (*s).shutting_down == 0 {
        unsafe pthread::pthread_cond_wait((*s).cv, (*s).lock);
    }
    if unsafe (*s).run_head == null {
        unsafe pthread::pthread_mutex_unlock((*s).lock);
        return null;
    }
    let co = unsafe (*s).run_head;
    unsafe (*s).run_head = unsafe (*co).next;
    if unsafe (*s).run_head == null {
        unsafe (*s).run_tail = null;
    }
    unsafe (*co).next = null;
    unsafe pthread::pthread_mutex_unlock((*s).lock);
    return co;
}

// The coroutine body trampoline: run the closure (which frees its own box), mark done, return to scheduler.
fn coroutine_start(arg: *mut void) {
    let co = arg as *mut Coroutine;
    let e = unsafe (*co).entry;
    e(unsafe (*co).env);
    unsafe (*co).done = 1;
    unsafe sc_runtime::sc_rt_ctx_switch((*co).ctx, (*co).sched_ctx);
}

fn free_coroutine(co: *mut Coroutine) {
    unsafe sc_runtime::sc_rt_stack_free((*co).stack, STACK_SIZE);
    unsafe sc_runtime::sc_rt_ctx_free((*co).ctx);
    let mut g = Global {};
    g.dealloc(co, sizeof(Coroutine), alignof(Coroutine));
}

// The C-ABI worker: run/resume coroutines, honouring each one's park (unlock) or yield (requeue) hand-off
// AFTER its context has been fully saved -- so a woken coroutine can never be resumed while still switching.
fn worker_main(arg: *mut void) *mut void {
    let s = arg as *mut Scheduler;
    let sched_ctx = unsafe sc_runtime::sc_rt_ctx_alloc();
    loop {
        let co = dequeue_runnable(s);
        if co == null {
            break;
        }
        unsafe (*co).sched_ctx = sched_ctx;
        if unsafe (*co).inited == 0 {
            // Set the context up on the worker that first runs it -- macOS ucontext is not reliably
            // cross-thread if created on the submitting thread.
            unsafe sc_runtime::sc_rt_ctx_init((*co).ctx, (*co).stack, STACK_SIZE, coroutine_start, co);
            unsafe (*co).inited = 1;
        }
        unsafe sc_runtime::sc_rt_tls_set(co);
        unsafe sc_lk_bt_pause(); // the leak tracker must not unwind the coroutine's stack
        unsafe sc_runtime::sc_rt_ctx_switch(sched_ctx, (*co).ctx);
        unsafe sc_lk_bt_resume();
        unsafe sc_runtime::sc_rt_tls_set(null);
        if unsafe (*co).done != 0 {
            free_coroutine(co);
        } else if unsafe (*co).commit_requeue != 0 {
            unsafe (*co).commit_requeue = 0;
            enqueue_runnable(s, co);
        } else if unsafe (*co).commit_lock != null {
            let lk = unsafe (*co).commit_lock;
            unsafe (*co).commit_lock = null;
            unsafe pthread::pthread_mutex_unlock(lk);
        }
    }
    unsafe sc_runtime::sc_rt_ctx_free(sched_ctx);
    return null;
}

fn build_scheduler() *mut Scheduler {
    let mut g = Global {};
    let s = g.alloc(sizeof(Scheduler), alignof(Scheduler)) as *mut Scheduler;
    let lk = unsafe pthread::sc_mutex_new();
    let cvh = unsafe pthread::sc_cond_new();
    unsafe s[0] = Scheduler {
        run_head: null,
        run_tail: null,
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

/// Start the pool if it is not running yet and return it. Thread-safe; `pub` for linkage.
pub fn ensure_started() *mut Scheduler {
    let sp = (&mut G_STATE) as *mut i32; // order codes: 0 Relaxed, 1 Acquire, 2 Release, 4 SeqCst
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

/// The per-`F` trampoline: move the closure out of its heap box, free the box, and run it. `pub` for linkage.
pub fn job_entry<F: fn move()>(env: *mut void) {
    let pp = env as *mut F;
    let f = unsafe {
        pp[0];
    };
    let mut g = Global {};
    g.dealloc(env, sizeof(F), alignof(F));
    f();
}

/// Spawn a coroutine running `entry(env)` on a fresh guard-paged stack. Non-generic so it (and the runtime
/// internals it touches) live in this TU; `pub` for linkage from the caller-monomorphized `submit`.
pub fn spawn_coroutine(entry: fn(*mut void) void, env: *mut void) {
    let s = ensure_started();
    let mut g = Global {};
    let co = g.alloc(sizeof(Coroutine), alignof(Coroutine)) as *mut Coroutine;
    let stk = unsafe sc_runtime::sc_rt_stack_alloc(STACK_SIZE);
    let ctx = unsafe sc_runtime::sc_rt_ctx_alloc();
    unsafe co[0] = Coroutine {
        ctx: ctx,
        stack: stk,
        entry: entry,
        env: env,
        done: 0,
        sched_ctx: null,
        next: null,
        commit_lock: null,
        commit_requeue: 0,
        inited: 0,
    };
    enqueue_runnable(s, co);
}

/// Submit `f` to run on the pool as a detached coroutine. Starts the pool on first use. `f` owns its
/// captures and must be `Send`. The `launch` statement lowers to this.
pub fn submit<F: fn move() + Send>(f: F) {
    let mut g = Global {};
    let slot = g.alloc(sizeof(F), alignof(F)) as *mut F;
    unsafe slot[0] = f;
    spawn_coroutine(job_entry::<F>, slot);
}

/// The coroutine currently running on this worker, or null on a non-worker (e.g. the main) thread. A
/// task-aware primitive checks this to decide between parking a coroutine and blocking an OS thread.
pub fn current() *mut Coroutine {
    return (unsafe sc_runtime::sc_rt_tls_get()) as *mut Coroutine;
}

/// Suspend the current coroutine until it is `wake`d. The caller MUST already hold `held_lock`, have placed
/// the current coroutine on the primitive's wait queue under it, and be prepared to re-check its condition
/// on return; `held_lock` is released once the context is saved and is NOT held again on return. Only valid
/// from inside a coroutine (`current() != null`).
pub fn park_current(held_lock: *mut void) {
    let co = current();
    unsafe (*co).commit_lock = held_lock;
    unsafe sc_runtime::sc_rt_ctx_switch((*co).ctx, (*co).sched_ctx);
}

/// Make a previously-parked coroutine runnable again. Safe to call while holding the primitive's wait-queue
/// lock (it takes only the scheduler's run-queue lock, always in that order).
pub fn wake(co: *mut Coroutine) {
    enqueue_runnable(G_SCHED, co);
}

/// Cooperatively yield: reschedule the current coroutine behind the others. A no-op off a worker thread.
pub fn yield_now() {
    let co = current();
    if co == null {
        return;
    }
    unsafe (*co).commit_requeue = 1;
    unsafe sc_runtime::sc_rt_ctx_switch((*co).ctx, (*co).sched_ctx);
}

/// Drain the run queue, stop and join every worker, and free the pool. Idempotent; a no-op if never
/// started. Call once from the main thread after all launched work has completed (no coroutine may still be
/// parked, or its stack leaks).
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
    unsafe pthread::sc_mutex_free((*s).lock);
    unsafe pthread::sc_cond_free((*s).cv);
    let mut g = Global {};
    g.dealloc(s, sizeof(Scheduler), alignof(Scheduler));
    atomic::store_i32(sp, 0, 2);
    G_SCHED = null;
}
