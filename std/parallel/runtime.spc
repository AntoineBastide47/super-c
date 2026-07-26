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

/// A stackful task. `next` links it into the scheduler's run queue; a primitive's wait queue holds a
/// separate per-wait node instead (see `park_begin`), and `tnext` is the timer-list link. `pub` only so
/// task-aware primitives can hold `*mut Coroutine` and wake one -- not a user-facing type.
pub struct Coroutine {
    pub ctx: *mut void, // sc_rt saved context
    pub stack: *mut void, // guard-paged stack (usable low end)
    pub entry: fn(*mut void) void, // per-F closure trampoline (job_entry::<F>)
    pub env: *mut void, // heap-boxed closure
    pub done: i32, // set by the coroutine when its body returns
    pub sched_ctx: *mut void, // the running worker's scheduler context (set on switch-in)
    pub next: *mut Coroutine, // intrusive run-queue link
    pub commit_fn: fn(*mut void) void, // park hand-off: called once the context is saved
    pub commit_arg: *mut void, // its argument (the lock to release, if any)
    pub commit_requeue: i32, // yield hand-off: re-enqueue this coroutine as runnable
    pub inited: i32, // context set up (lazily, on the first worker to run it)
    pub park_state: u32, // (park generation << 1) | claimed -- see park_begin
    pub timed: i32, // currently linked into the scheduler's timer list
    pub deadline: u64, // monotonic wake time (ns) while `timed`
    pub tm_token: u32, // the token that pending timer will wake, while `timed`
    pub tnext: *mut Coroutine, // timer-list link (sorted by `deadline`)
}

/// The shared pool. Fields are `pub` only for the caller-monomorphized `launch` / task-aware primitives.
pub struct Scheduler {
    pub run_head: *mut Coroutine, // runnable FIFO
    pub run_tail: *mut Coroutine,
    pub timer_head: *mut Coroutine, // sleeping coroutines, earliest deadline first
    pub lock: *mut void, // guards the run queue, the timer list and shutting_down
    pub cv: *mut void, // workers wait here when the run queue is empty
    pub workers: Vector<pthread::pthread_t>,
    pub shutting_down: i32,
}

// The single global pool, guarded by a 0=uninit / 1=building / 2=ready init state machine.
static mut G_STATE: i32 = 0;
static mut G_SCHED: *mut Scheduler = null;
static mut G_NWORKERS: usize = 0; // 0 = one worker per CPU

// The commit hand-off for a park with nothing to release (e.g. `sleep`).
fn commit_nop(_p: *mut void) {}

// Claim the right to resume the park identified by `token`: succeeds once, for one waker, and only while
// that exact park is still current. A registration left behind by an expired timed wait therefore cannot
// resume a LATER park -- which would run a coroutine that never actually acquired what it waited for.
fn claim(co: *mut Coroutine, token: u32) bool {
    let p = &mut unsafe (*co).park_state;
    return atomic::cas_u32(p, token, token + 1, false, 4, 0); // SeqCst on success, Relaxed on failure
}

// Append `co` to the runnable queue and wake one idle worker. Caller holds `(*s).lock`.
fn push_runnable(s: *mut Scheduler, co: *mut Coroutine) {
    unsafe (*co).next = null;
    if unsafe (*s).run_tail == null {
        unsafe (*s).run_head = co;
    } else {
        unsafe (*(*s).run_tail).next = co;
    }
    unsafe (*s).run_tail = co;
    unsafe pthread::pthread_cond_signal((*s).cv);
}

// Append `co` to the runnable queue, taking the scheduler lock. Caller must NOT hold it.
fn enqueue_runnable(s: *mut Scheduler, co: *mut Coroutine) {
    unsafe pthread::pthread_mutex_lock((*s).lock);
    push_runnable(s, co);
    unsafe pthread::pthread_mutex_unlock((*s).lock);
}

// Link `co` into the deadline-sorted timer list. Caller holds `(*s).lock` and passes the deadline it read
// before this coroutine became visible to any waker (`co.deadline` is the coroutine's to overwrite).
fn arm_timer(s: *mut Scheduler, co: *mut Coroutine, dl: u64) {
    let mut prev: *mut Coroutine = null;
    let mut cur = unsafe (*s).timer_head;
    while cur != null && unsafe (*cur).deadline <= dl {
        prev = cur;
        cur = unsafe (*cur).tnext;
    }
    unsafe (*co).tnext = cur;
    if prev == null {
        unsafe (*s).timer_head = co;
    } else {
        unsafe (*prev).tnext = co;
    }
    unsafe (*co).timed = 1;
    // A nearer deadline shortens the wait of whichever worker is idle, so it has to re-evaluate.
    unsafe pthread::pthread_cond_signal((*s).cv);
}

// Unlink `co` from the timer list if it is still on it. Caller holds `(*s).lock`.
fn disarm_timer(s: *mut Scheduler, co: *mut Coroutine) {
    if unsafe (*co).timed == 0 {
        return;
    }
    let mut prev: *mut Coroutine = null;
    let mut cur = unsafe (*s).timer_head;
    while cur != null && cur != co {
        prev = cur;
        cur = unsafe (*cur).tnext;
    }
    if cur == co {
        if prev == null {
            unsafe (*s).timer_head = unsafe (*co).tnext;
        } else {
            unsafe (*prev).tnext = unsafe (*co).tnext;
        }
    }
    unsafe (*co).tnext = null;
    unsafe (*co).timed = 0;
}

// Make every coroutine whose deadline has passed runnable. Caller holds `(*s).lock`. A coroutine already
// claimed (notified just before its deadline) is only unlinked -- its waker is resuming it.
fn promote_expired(s: *mut Scheduler) {
    let now = platform::now_ns();
    while unsafe (*s).timer_head != null && unsafe (*(*s).timer_head).deadline <= now {
        let co = unsafe (*s).timer_head;
        unsafe (*s).timer_head = unsafe (*co).tnext;
        unsafe (*co).tnext = null;
        unsafe (*co).timed = 0;
        if claim(co, unsafe (*co).tm_token) {
            push_runnable(s, co);
        }
    }
}

// Pop the next runnable coroutine, blocking the worker while the queue is empty (but no longer than the
// earliest pending timer); null once shut down and drained.
fn dequeue_runnable(s: *mut Scheduler) *mut Coroutine {
    unsafe pthread::pthread_mutex_lock((*s).lock);
    loop {
        promote_expired(s);
        if unsafe (*s).run_head != null {
            let co = unsafe (*s).run_head;
            unsafe (*s).run_head = unsafe (*co).next;
            if unsafe (*s).run_head == null {
                unsafe (*s).run_tail = null;
            }
            unsafe (*co).next = null;
            unsafe pthread::pthread_mutex_unlock((*s).lock);
            return co;
        }
        // Shutting down drains: workers keep going until the run queue is empty AND every pending timer has
        // fired, so a sleeping task is not silently dropped (one still parked on a wait queue is, since
        // nothing will ever wake it).
        if unsafe (*s).shutting_down != 0 && unsafe (*s).timer_head == null {
            unsafe pthread::pthread_mutex_unlock((*s).lock);
            return null;
        }
        if unsafe (*s).timer_head != null {
            let now = platform::now_ns();
            let dl = unsafe (*(*s).timer_head).deadline;
            let rel = if dl > now {
                (dl - now) as i64;
            } else {
                0i64;
            };
            let _ = unsafe pthread::sc_cond_timedwait_ns((*s).cv, (*s).lock, rel);
        } else {
            let _ = unsafe pthread::pthread_cond_wait((*s).cv, (*s).lock);
        }
    }
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
        } else {
            // Parked. Take the hand-off FIRST: arming the timer already publishes this coroutine, and a
            // deadline that has already passed lets another worker resume it -- and park it again, rewriting
            // these very fields -- before we get to them.
            let commit = unsafe (*co).commit_fn;
            let arg = unsafe (*co).commit_arg;
            let dl = unsafe (*co).deadline;
            // Then arm its timer (if the wait was timed) and only last release the lock that kept its waker
            // out: by now its context is fully saved, so any waker may resume it.
            if dl != 0 {
                unsafe pthread::pthread_mutex_lock((*s).lock);
                arm_timer(s, co, dl);
                unsafe pthread::pthread_mutex_unlock((*s).lock);
            }
            commit(arg);
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
        timer_head: null,
        lock: lk,
        cv: cvh,
        workers: Vector::<pthread::pthread_t>::new(),
        shutting_down: 0,
    };
    let nw = if G_NWORKERS > 0 {
        G_NWORKERS;
    } else {
        platform::ncpu();
    };
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
        commit_fn: commit_nop,
        commit_arg: null,
        commit_requeue: 0,
        inited: 0,
        park_state: 0,
        timed: 0,
        deadline: 0,
        tm_token: 0,
        tnext: null,
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

/// Open a new park and return its wake token. Call it (from inside the coroutine, under the lock guarding
/// the wait queue) before enqueueing a wait node, and store the token in that node: `wake` needs it, and it
/// is what makes a wakeup specific to one park. A node left behind by an expired timed wait keeps an old
/// token and is therefore inert -- which is why a waiter may re-park (to re-take the lock) before it has
/// managed to unlink itself.
pub fn park_begin(co: *mut Coroutine) u32 {
    let p = &mut unsafe (*co).park_state;
    let t = ((atomic::load_u32(p, 0) >> 1) + 1) * 2; // next generation, claim bit clear; wraps at width
    atomic::store_u32(p, t, 0);
    return t;
}

/// Suspend the current coroutine until woken, or until `deadline` (a `platform::now_ns()` value; 0 means no
/// timeout, in which case `token` is unused). Only valid from inside a coroutine (`current() != null`).
///
/// The caller MUST, before calling: take a `park_begin` token, place a node carrying it on the primitive's
/// wait queue, and hold the lock guarding that queue -- `commit(arg)` releases that lock once the context is
/// saved (`commit_nop`/`null` when there is none), which is what keeps a waker from resuming a coroutine
/// that is still switching out. On return the lock is NOT held; the caller must re-acquire it, call
/// `cancel_timer` if the wait was timed, unlink its node, and re-check its condition.
pub fn park_timed(token: u32, deadline: u64, commit: fn(*mut void) void, arg: *mut void) {
    let co = current();
    unsafe (*co).commit_fn = commit;
    unsafe (*co).commit_arg = arg;
    unsafe (*co).deadline = deadline;
    unsafe (*co).tm_token = token;
    unsafe sc_runtime::sc_rt_ctx_switch((*co).ctx, (*co).sched_ctx);
}

/// `park_timed` with no deadline: park until woken.
pub fn park_current(commit: fn(*mut void) void, arg: *mut void) {
    park_timed(0, 0, commit, arg);
}

/// Resume the park `token` identifies, and report whether this call is the one that did it. Exactly one
/// waker wins per park, so a notify racing a timeout can never enqueue a coroutine twice; `false` means the
/// wakeup was not consumed (the token is stale, or another waker got there first) and should go to the next
/// waiter. Safe to call while holding the primitive's wait-queue lock (it takes only the scheduler's lock,
/// always in that order).
pub fn wake(co: *mut Coroutine, token: u32) bool {
    if !claim(co, token) {
        return false;
    }
    enqueue_runnable(G_SCHED, co);
    return true;
}

/// Drop `co`'s pending timer, if its wait was timed and it was woken before the deadline. Call after every
/// `park_until` with a deadline, before the coroutine can park again -- a stale timer entry would otherwise
/// resume a running coroutine.
pub fn cancel_timer(co: *mut Coroutine) {
    let s = G_SCHED;
    if s == null {
        return;
    }
    unsafe pthread::pthread_mutex_lock((*s).lock);
    disarm_timer(s, co);
    unsafe pthread::pthread_mutex_unlock((*s).lock);
}

/// Suspend for `ns` nanoseconds. A coroutine parks on the scheduler's timer list, so its worker keeps
/// running other tasks; any other thread sleeps outright. `std::parallel::time::sleep` is the friendly form.
pub fn sleep_ns(ns: i64) {
    if ns <= 0 {
        return;
    }
    let co = current();
    if co == null {
        unsafe sc_runtime::sc_rt_sleep_ns(ns);
        return;
    }
    let token = park_begin(co); // on no wait queue: the timer is the only waker
    park_timed(token, platform::now_ns() + ns as u64, commit_nop, null);
    cancel_timer(co);
}

/// Fix the pool's worker-thread count. Must be called before the first `launch` (the pool is built on
/// demand and never resized); `0` restores the default of one worker per CPU. Setting it to 1 makes
/// scheduling deterministic, which is what concurrency tests want.
pub fn set_worker_count(n: usize) {
    G_NWORKERS = n;
}

/// Cooperatively yield: reschedule the current coroutine behind the others. A no-op off a worker thread.
pub fn yield_now() {
    let co = current();
    if co == null {
        return;
    }
    let _ = park_begin(co); // retire the current token: nothing may wake a coroutine the worker requeues
    unsafe (*co).commit_requeue = 1;
    unsafe sc_runtime::sc_rt_ctx_switch((*co).ctx, (*co).sched_ctx);
}

/// Drain the run queue and every pending timer, stop and join all workers, and free the pool. Idempotent;
/// a no-op if never started. Call once from the main thread after all launched work has completed: a
/// coroutine still parked on a lock, a channel or a `WaitGroup` will never be woken, so its stack leaks.
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
