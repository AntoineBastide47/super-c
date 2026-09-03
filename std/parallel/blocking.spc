// The escape hatch for work that blocks its OS thread. Import with `import std::parallel::blocking;`.
//
//     let data = blocking::call(fn move() Data {
//         return read_from_a_library_that_blocks();
//     });
//
// A worker thread belongs to the scheduler: a coroutine that calls something which blocks the thread;
// `read()`, a legacy C library, anything the runtime cannot park: takes that worker out of circulation
// for the duration, and enough of them stall the whole pool. `call` moves the work onto a separate pool of
// plain OS threads (which are allowed to block) and PARKS the calling coroutine until the result comes
// back, so the worker keeps serving other tasks meanwhile. Called from a non-coroutine thread it still
// works: the caller blocks, which is what it would have done anyway.
//
// The pool starts on first use and grows on demand up to `MAX_THREADS`; `shutdown()` joins it. `f` must be
// `Send + 'static` for the same reason a launched task must: it runs on another thread, and it may still
// be running when the call that submitted it is gone (if the caller panics, say).

import atomic;
import sc_runtime;
import std::parallel::sync as sync;
import std::parallel::runtime as runtime;

const MAX_THREADS: usize = 64; // enough concurrent blocking calls for real programs, bounded for safety
const IDLE_NS: i64 = 10000000000; // a thread with nothing to do for ten seconds goes away again

// One submitted piece of work: a type-erased trampoline plus its heap payload.
@no_const
struct BJob {
    pub run: fn(*mut void) void,
    pub env: *mut void,
    pub next: *mut BJob,
}

@no_const
struct Pool {
    pub lock: *mut void, // guards the queue, the counters and `shutting`
    pub cv: *mut void, // idle threads wait here
    pub head: *mut BJob,
    pub tail: *mut BJob,
    pub idle: usize, // threads currently waiting for work
    pub live: usize, // threads started
    pub shutting: i32,
    pub threads: Vector<*mut void>,
}

static mut G_STATE: i32 = 0; // 0 uninit / 1 building / 2 ready
static mut G_POOL: *mut Pool = null;

/// The latch one `call` waits on: `done` flips when the blocking thread has stored the result. It lives in
/// the caller's frame, which is sound because the caller does not return until it flips. `pub` for linkage.
@no_const
pub struct Done {
    pub state: sync::Mutex<i32>,
    pub cv: sync::Condvar,
}

/// Mark a call finished and wake its caller. `pub` for linkage (the per-`F` trampolines call it).
pub fn complete(d: *mut Done) {
    let m = &unsafe d.state;
    let mut g = m.lock();
    {
        let v = g.get_mut();
        *v = 1;
    }
    let cv = &unsafe d.cv;
    // Under the paired lock: it guards the wait queue.
    cv.notify_all();
}

// The C-ABI thread body: take work, run it, repeat until shutdown drains the queue.
fn pool_main(arg: *mut void) *mut void {
    let p = arg as *mut Pool;
    loop {
        unsafe sc_runtime::sc_rt_mutex_lock(p.lock);
        let mut expired = false;
        while unsafe p.head == null && unsafe p.shutting == 0 && !expired {
            unsafe p.idle = unsafe p.idle + 1;
            let rc = unsafe sc_runtime::sc_rt_cond_timedwait_ns(p.cv, p.lock, IDLE_NS);
            unsafe p.idle = unsafe p.idle - 1;
            // Timed out with still nothing to do: a burst of blocking calls should not cost threads for
            // the rest of the process. `submit` starts another the moment one is needed again.
            expired = rc != 0 && unsafe p.head == null;
        }
        let j = unsafe p.head;
        if j == null {
            unsafe p.live = unsafe p.live - 1;
            unsafe sc_runtime::sc_rt_mutex_unlock(p.lock);
            // Shutting down and drained, or idle for too long.
            break;
        }
        unsafe p.head = unsafe j.next;
        if unsafe p.head == null {
            unsafe p.tail = null;
        }
        unsafe sc_runtime::sc_rt_mutex_unlock(p.lock);
        let run = unsafe j.run;
        let env = unsafe j.env;
        let mut g = Global {};
        unsafe g.dealloc(j, sizeof(BJob), alignof(BJob));
        // Outside the lock: this is the part that is allowed to block.
        run(env);
    }
    return null;
}

fn build_pool() *mut Pool {
    let mut g = Global {};
    let p = (unsafe g.alloc(sizeof(Pool), alignof(Pool))) as *mut Pool;
    unsafe p[0] = Pool {
        lock: unsafe sc_runtime::sc_rt_mutex_new(),
        cv: unsafe sc_runtime::sc_rt_cond_new(),
        head: null,
        tail: null,
        idle: 0,
        live: 0,
        shutting: 0,
        threads: Vector::<*mut void>::new(),
    };
    return p;
}

// The pool, started on first use. Same init state machine as the scheduler's.
fn ensure_pool() *mut Pool {
    // `G_POOL` is ordered by `G_STATE`, which the compiler cannot see: the CAS winner publishes the pointer
    // and THEN releases state 2, and every reader acquires state 2 first, so the write happens-before every
    // read. That handshake is what this `unsafe` asserts.
    unsafe {
        let sp = (&mut G_STATE) as *mut i32; // 0 Relaxed, 1 Acquire, 2 Release, 4 SeqCst
        if atomic_load(sp) == 2 {
            return G_POOL;
        }
        if atomic_cas(sp, 0, 1) {
            let p = build_pool();
            G_POOL = p;
            atomic_store(sp, 2);
            return p;
        }
        while atomic_load(sp) != 2 {}
        return G_POOL;
    }
}

// Thin wrappers so the init machinery reads the same as the scheduler's without importing ffi here.
fn atomic_load(p: *mut i32) i32 {
    return atomic::load_i32(p, 1);
}

fn atomic_store(p: *mut i32, v: i32) {
    atomic::store_i32(p, v, 2);
}

fn atomic_cas(p: *mut i32, from: i32, to: i32) bool {
    return atomic::cas_i32(p, from, to, false, 4, 0);
}

/// Queue `run(env)` on the blocking pool, starting another thread if every one of them is busy. `pub` for
/// linkage from the caller-monomorphized `call`.
pub fn submit(run: fn(*mut void) void, env: *mut void) {
    let p = ensure_pool();
    let mut g = Global {};
    let j = (unsafe g.alloc(sizeof(BJob), alignof(BJob))) as *mut BJob;
    unsafe j[0] = BJob { run: run, env: env, next: null };
    unsafe sc_runtime::sc_rt_mutex_lock(p.lock);
    if unsafe p.tail == null {
        unsafe p.head = j;
    } else {
        unsafe p.tail.next = j;
    }
    unsafe p.tail = j;
    // Grow only when nobody is free to take it: blocking calls are supposed to be rare and long.
    let need = unsafe p.idle == 0 && unsafe p.live < MAX_THREADS;
    if need {
        unsafe p.live = unsafe p.live + 1;
    }
    unsafe sc_runtime::sc_rt_cond_signal(p.cv);
    unsafe sc_runtime::sc_rt_mutex_unlock(p.lock);
    if need {
        let mut h: *mut void = null;
        let _ = unsafe sc_runtime::sc_rt_thread_create(&mut h, pool_main, p);
        unsafe sc_runtime::sc_rt_mutex_lock(p.lock);
        unsafe p.threads.push(h);
        unsafe sc_runtime::sc_rt_mutex_unlock(p.lock);
    }
}

// What one `call` from a plain thread hands to the pool: the closure, where to put its value, and who to
// wake. Sound only because that caller blocks until the latch flips, so the slot pointer stays alive.
@no_const
struct Payload<F, T> {
    pub body: F,
    pub slot: *mut T,
    pub done: *mut Done,
}

/// The per-`(F, T)` trampoline for a plain-thread caller: run the closure on the blocking thread, store
/// its value, wake the caller. `pub` for linkage.
pub fn entry<F: fn move() T + Send, T>(env: *mut void) {
    let pp = env as *mut Payload<F, T>;
    let pay = unsafe {
        pp[0];
    };
    let mut g = Global {};
    unsafe g.dealloc(env, sizeof(Payload<F, T>), alignof(Payload<F, T>));
    let f = pay.body;
    unsafe pay.slot[0] = f();
    complete(pay.done);
}

// The blocking-result states: the single-winner race between completion and task-side abandonment.
const BS_PENDING: i32 = 0;
const BS_COMPLETING: i32 = 1;
const BS_COMPLETE: i32 = 2;
const BS_ABANDONED: i32 = 3;

/// A coroutine's blocking-call record: HEAP-owned and reference-counted, never a pointer into the waiting
/// coroutine's stack, so a cancelled task can abandon the call and the pool worker still has somewhere
/// safe to write. The task and the worker hold one reference each; the completion/abandonment race is one
/// compare-and-swap on `state`, the loser of which owns nothing, and whichever side ends with the value
/// (`Complete` read by the task, or `Complete` after `Abandoned` seen by the worker) frees it exactly
/// once. The last reference frees the record. `pub` for linkage.
@no_const
pub struct BRec<T> {
    pub refs: i32, // atomic: task + worker
    pub state: i32, // atomic BS_*
    pub co: *mut runtime::Coroutine,
    pub token: u32,
    pub value: T, // written by the worker before the state CAS; raw storage until then
}

// Drop one reference; the last one frees the record (the value inside was already settled).
fn brec_drop<T>(rp: *mut BRec<T>) {
    if atomic::sub_i32(&mut unsafe rp.refs, 1, 3) == 1 {
        let mut g = Global {};
        unsafe g.dealloc(rp, sizeof(BRec<T>), alignof(BRec<T>));
    }
}

fn brec_wait_complete<T>(rp: *mut BRec<T>) {
    // Reached only after the worker won the PENDING->COMPLETING CAS, so it is committed to storing
    // COMPLETE next with no blocking step in between: the sole cause of a wait here is the worker being
    // descheduled. Spin briefly, then yield the CPU so a preempted worker can finish. A fixed spin cap
    // would turn a scheduler delay under load into a spurious panic.
    let mut spins: u32 = 0;
    while atomic::load_i32(&mut unsafe rp.state, 1) == BS_COMPLETING {
        if spins < 64 {
            unsafe sc_runtime::sc_rt_cpu_relax();
            spins += 1;
        } else {
            unsafe sc_runtime::sc_rt_thread_yield();
        }
    }
}

// What a coroutine `call` hands to the pool: the closure and the shared record.
@no_const
struct CPayload<F, T> {
    pub body: F,
    pub rec: *mut BRec<T>,
}

/// The per-`(F, T)` trampoline for a coroutine caller: run the closure, publish the value into the heap
/// record, and settle the ownership race. If the task abandoned the call, the value is freed HERE: the
/// blocking worker never touches the coroutine or its stack after an abandonment. `pub` for linkage.
pub fn entry_rec<F: fn move() T + Send, T>(env: *mut void) {
    let pp = env as *mut CPayload<F, T>;
    let pay = unsafe {
        pp[0];
    };
    let mut g = Global {};
    unsafe g.dealloc(env, sizeof(CPayload<F, T>), alignof(CPayload<F, T>));
    let f = pay.body;
    let rp = pay.rec;
    // Raw store into record storage the worker's reference keeps alive.
    unsafe rp.value = f();
    if atomic::cas_i32(&mut unsafe rp.state, BS_PENDING, BS_COMPLETING, false, 4, 0) {
        let _ = runtime::wake_as(unsafe rp.co, unsafe rp.token, runtime::WR_BLOCKING);
        atomic::store_i32(&mut unsafe rp.state, BS_COMPLETE, 2);
    } else {
        // Abandoned: the task is gone from the record. Drop the unclaimed result.
        let vp = (&mut unsafe rp.value) as *mut T;
        vp.free();
    }
    brec_drop(rp);
}

// The submit hand-off for a coroutine `call`: runs on the worker once the caller's context is saved, so
// the pool cannot complete (and wake) a task that is still switching out. `cs` lives in the caller's
// frame, which is alive because the caller cannot resume before this commit runs.
@no_const
struct CSubmit {
    pub run: fn(*mut void) void,
    pub env: *mut void,
}

fn commit_submit(p: *mut void) {
    let cs = p as *mut CSubmit;
    submit(unsafe cs.run, unsafe cs.env);
}

/// Run `run(env)` on the blocking pool and park the caller until it returns. The non-generic core of
/// `call`, and what a `@blocking` extern function's generated wrapper hands its work to: hence the pinned
/// C symbol, which is the name codegen emits.
@c.export("__sc_blocking_run")
pub fn run_blocking(run: fn(*mut void) void, env: *mut void) {
    let mut done = Done { state: sync::Mutex::<i32>::new(0), cv: sync::Condvar::new() };
    let mut g = Global {};
    let box = (unsafe g.alloc(sizeof(RawJob), alignof(RawJob))) as *mut RawJob;
    unsafe box[0] = RawJob { run: run, env: env, done: &mut done };
    submit(raw_entry, box);
    {
        let gd = done.state.lock();
        while *gd.get() == 0 {
            // Masked: a `@blocking` extern call is foreign code whose result lands through `env`, so the
            // waiter can never unwind early. An unreturned call is reported, never freed under.
            let _ = unsafe done.cv.wait_raw(gd.lock_handle(), 0, false, runtime::WK_BLOCKING);
        }
    }
}

// The payload behind `run_blocking`: an already-type-erased job plus who to wake.
@no_const
struct RawJob {
    pub run: fn(*mut void) void,
    pub env: *mut void,
    pub done: *mut Done,
}

/// Runs one `run_blocking` job on a pool thread. `pub` for linkage.
pub fn raw_entry(p: *mut void) {
    let j = p as *mut RawJob;
    let run = unsafe j.run;
    let env = unsafe j.env;
    let d = unsafe j.done;
    let mut g = Global {};
    unsafe g.dealloc(j, sizeof(RawJob), alignof(RawJob));
    run(env);
    complete(d);
}

// The coroutine path shared by `call` and `call_c`: build the record, park (submitting from the commit
// hand-off), and settle. Returns the record pointer and the wake reason through out-parameters; the
// callers decide what a cancel means.
fn call_park<F: fn move() T + Send + 'static, T: Send>(
    f: F,
    co: *mut runtime::Coroutine,
    cancellable: bool,
    reason: &mut u32,
) *mut BRec<T> {
    let mut g = Global {};
    let rp = (unsafe g.alloc(sizeof(BRec<T>), alignof(BRec<T>))) as *mut BRec<T>;
    runtime::wait_note(runtime::WK_BLOCKING, rp as usize);
    let token = runtime::park_begin(co);
    unsafe rp.refs = 2;
    unsafe rp.state = BS_PENDING;
    unsafe rp.co = co;
    unsafe rp.token = token;
    let env = (unsafe g.alloc(sizeof(CPayload<F, T>), alignof(CPayload<F, T>))) as *mut CPayload<F, T>;
    unsafe env[0] = CPayload::<F, T> { body: f, rec: rp };
    let mut cs = CSubmit { run: entry_rec::<F, T>, env: env };
    *reason = runtime::park_timed(token, 0, commit_submit, &mut cs, cancellable);
    runtime::wait_clear();
    runtime::park_done(co);
    return rp;
}

/// Run `f` on the blocking pool and return its value. The calling coroutine PARKS while it runs, so the
/// worker thread stays available; any other caller blocks. This is how a coroutine calls something
/// that would otherwise hold a worker hostage: a blocking `read`, a legacy library, a slow syscall.
pub fn call<F: fn move() T + Send + 'static, T: Send>(f: F) T {
    let co = runtime::current();
    if co != null {
        let mut reason: u32 = 0;
        let rp = call_park::<F, T>(f, co, false, &mut reason);
        if reason != runtime::WR_BLOCKING {
            panic("a non-cancellable blocking park has exactly one waker");
        }
        brec_wait_complete(rp);
        let v = unsafe {
            rp.value;
        };
        brec_drop(rp);
        return v;
    }
    // A plain thread blocks anyway: latch in this frame, result slot in this frame.
    let mut slot: T;
    let mut done = Done { state: sync::Mutex::<i32>::new(0), cv: sync::Condvar::new() };
    let mut g = Global {};
    let env = (unsafe g.alloc(sizeof(Payload<F, T>), alignof(Payload<F, T>))) as *mut Payload<F, T>;
    unsafe env[0] = Payload::<F, T> { body: f, slot: &mut slot, done: &mut done };
    submit(entry::<F, T>, env);
    {
        let gd = done.state.lock();
        while *gd.get() == 0 {
            done.cv.wait_masked(&gd);
        }
    }
    return slot;
}

/// `call`, but the park is a cancellation point: `None` means the wait was cancelled. The task's side of
/// the job is ABANDONED: the blocking operation is not stopped; when it returns, the pool worker frees
/// the unclaimed result and the last reference frees the record. No pool thread ever writes into this
/// coroutine's stack. The cancellable form for callers that can propagate cancellation.
pub fn call_c<F: fn move() T + Send + 'static, T: Send>(f: F) Option<T> {
    let co = runtime::current();
    if co == null {
        // A plain thread has no task to cancel.
        return Option::<T>::Some(call::<F, T>(f));
    }
    let mut reason: u32 = 0;
    let rp = call_park::<F, T>(f, co, true, &mut reason);
    if runtime::cancel_after_wait(true) {
        if !atomic::cas_i32(&mut unsafe rp.state, BS_PENDING, BS_ABANDONED, false, 4, 0) {
            brec_wait_complete(rp);
            let vp = (&mut unsafe rp.value) as *mut T;
            vp.free();
        }
        brec_drop(rp);
        return Option::<T>::None;
    }
    brec_wait_complete(rp);
    let v = unsafe {
        rp.value;
    };
    brec_drop(rp);
    return Option::<T>::Some(v);
}

/// Stop the blocking pool and join its threads. Idempotent; a no-op if it never started. Call it once, from
/// the main thread, after every `call` has returned: alongside `runtime::shutdown()`.
pub fn shutdown() {
    let sp = (&mut unsafe G_STATE) as *mut i32;
    if atomic_load(sp) != 2 {
        return;
    }
    let p = unsafe G_POOL;
    unsafe sc_runtime::sc_rt_mutex_lock(p.lock);
    unsafe p.shutting = 1;
    unsafe sc_runtime::sc_rt_cond_broadcast(p.cv);
    unsafe sc_runtime::sc_rt_mutex_unlock(p.lock);
    let n = unsafe p.threads.len();
    for i in 0..n {
        let h = unsafe p.threads[i];
        let _ = unsafe sc_runtime::sc_rt_thread_join(h);
    }
    unsafe p.threads.free();
    unsafe sc_runtime::sc_rt_mutex_free(p.lock);
    unsafe sc_runtime::sc_rt_cond_free(p.cv);
    let mut g = Global {};
    unsafe g.dealloc(p, sizeof(Pool), alignof(Pool));
    atomic_store(sp, 0);
    unsafe G_POOL = null;
}
