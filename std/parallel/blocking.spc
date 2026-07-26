// The escape hatch for work that blocks its OS thread. Import with `import std::parallel::blocking;`.
//
//     let data = blocking::call(fn move() Data {
//         return read_from_a_library_that_blocks();
//     });
//
// A worker thread belongs to the scheduler: a coroutine that calls something which blocks the thread --
// `read()`, a legacy C library, anything the runtime cannot park -- takes that worker out of circulation
// for the duration, and enough of them stall the whole pool. `call` moves the work onto a separate pool of
// plain OS threads (which are allowed to block) and PARKS the calling coroutine until the result comes
// back, so the worker keeps serving other tasks meanwhile. Called from a non-coroutine thread it still
// works: the caller simply blocks, which is what it would have done anyway.
//
// The pool starts on first use and grows on demand up to `MAX_THREADS`; `shutdown()` joins it. `f` must be
// `Send + 'static` for the same reason a launched task must -- it runs on another thread, and it may still
// be running when the call that submitted it is gone (if the caller panics, say).

import atomic;
import sc_runtime;
import std::parallel::sync as sync;

const MAX_THREADS: usize = 64; // enough concurrent blocking calls for real programs, bounded for safety
const IDLE_NS: i64 = 10000000000; // a thread with nothing to do for ten seconds goes away again

// One submitted piece of work: a type-erased trampoline plus its heap payload.
struct BJob {
    pub run: fn(*mut void) void,
    pub env: *mut void,
    pub next: *mut BJob,
}

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
pub struct Done {
    pub state: sync::Mutex<i32>,
    pub cv: sync::Condvar,
}

/// Mark a call finished and wake its caller. `pub` for linkage (the per-`F` trampolines call it).
pub fn complete(d: *mut Done) {
    let m = &unsafe (*d).state;
    let mut g = m.lock();
    {
        let v = g.get_mut();
        *v = 1;
    }
    let cv = &unsafe (*d).cv;
    cv.notify_all(); // under the paired lock: it guards the wait queue
}

// The C-ABI thread body: take work, run it, repeat until shutdown drains the queue.
fn pool_main(arg: *mut void) *mut void {
    let p = arg as *mut Pool;
    loop {
        unsafe sc_runtime::sc_rt_mutex_lock((*p).lock);
        let mut expired = false;
        while unsafe (*p).head == null && unsafe (*p).shutting == 0 && !expired {
            unsafe (*p).idle = unsafe (*p).idle + 1;
            let rc = unsafe sc_runtime::sc_rt_cond_timedwait_ns((*p).cv, (*p).lock, IDLE_NS);
            unsafe (*p).idle = unsafe (*p).idle - 1;
            // Timed out with still nothing to do: a burst of blocking calls should not cost threads for
            // the rest of the process. `submit` starts another the moment one is needed again.
            expired = rc != 0 && unsafe (*p).head == null;
        }
        let j = unsafe (*p).head;
        if j == null {
            unsafe (*p).live = unsafe (*p).live - 1;
            unsafe sc_runtime::sc_rt_mutex_unlock((*p).lock);
            break; // shutting down and drained, or idle for too long
        }
        unsafe (*p).head = unsafe (*j).next;
        if unsafe (*p).head == null {
            unsafe (*p).tail = null;
        }
        unsafe sc_runtime::sc_rt_mutex_unlock((*p).lock);
        let run = unsafe (*j).run;
        let env = unsafe (*j).env;
        let mut g = Global {};
        g.dealloc(j, sizeof(BJob), alignof(BJob));
        run(env); // outside the lock: this is the part that is allowed to block
    }
    return null;
}

fn build_pool() *mut Pool {
    let mut g = Global {};
    let p = g.alloc(sizeof(Pool), alignof(Pool)) as *mut Pool;
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
    let j = g.alloc(sizeof(BJob), alignof(BJob)) as *mut BJob;
    unsafe j[0] = BJob { run: run, env: env, next: null };
    unsafe sc_runtime::sc_rt_mutex_lock((*p).lock);
    if unsafe (*p).tail == null {
        unsafe (*p).head = j;
    } else {
        unsafe (*(*p).tail).next = j;
    }
    unsafe (*p).tail = j;
    // Grow only when nobody is free to take it: blocking calls are supposed to be rare and long.
    let need = unsafe (*p).idle == 0 && unsafe (*p).live < MAX_THREADS;
    if need {
        unsafe (*p).live = unsafe (*p).live + 1;
    }
    unsafe sc_runtime::sc_rt_cond_signal((*p).cv);
    unsafe sc_runtime::sc_rt_mutex_unlock((*p).lock);
    if need {
        let mut h: *mut void = null;
        let _ = unsafe sc_runtime::sc_rt_thread_create(&mut h, pool_main, p);
        unsafe sc_runtime::sc_rt_mutex_lock((*p).lock);
        unsafe (*p).threads.push(h);
        unsafe sc_runtime::sc_rt_mutex_unlock((*p).lock);
    }
}

// What one `call` hands to the pool: the closure, where to put its value, and who to wake.
struct Payload<F, T> {
    pub body: F,
    pub slot: *mut T,
    pub done: *mut Done,
}

/// The per-`(F, T)` trampoline: run the closure on the blocking thread, store its value, wake the caller.
/// `pub` for linkage.
pub fn entry<F: fn move() T + Send, T>(env: *mut void) {
    let pp = env as *mut Payload<F, T>;
    let pay = unsafe {
        pp[0];
    };
    let mut g = Global {};
    g.dealloc(env, sizeof(Payload<F, T>), alignof(Payload<F, T>));
    let f = pay.body;
    unsafe pay.slot[0] = f();
    complete(pay.done);
}

/// Run `run(env)` on the blocking pool and park the caller until it returns. The non-generic core of
/// `call`, and what a `@blocking` extern function's generated wrapper hands its work to -- hence the pinned
/// C symbol, which is the name codegen emits.
@c.export("__sc_blocking_run")
pub fn run_blocking(run: fn(*mut void) void, env: *mut void) {
    let mut done = Done { state: sync::Mutex::<i32>::new(0), cv: sync::Condvar::new() };
    let mut g = Global {};
    let box = g.alloc(sizeof(RawJob), alignof(RawJob)) as *mut RawJob;
    unsafe box[0] = RawJob { run: run, env: env, done: &mut done };
    submit(raw_entry, box);
    {
        let gd = done.state.lock();
        while *gd.get() == 0 {
            done.cv.wait(&gd);
        }
    }
}

// The payload behind `run_blocking`: an already-type-erased job plus who to wake.
struct RawJob {
    pub run: fn(*mut void) void,
    pub env: *mut void,
    pub done: *mut Done,
}

// Runs one `run_blocking` job on a pool thread. `pub` for linkage.
pub fn raw_entry(p: *mut void) {
    let j = p as *mut RawJob;
    let run = unsafe (*j).run;
    let env = unsafe (*j).env;
    let d = unsafe (*j).done;
    let mut g = Global {};
    g.dealloc(j, sizeof(RawJob), alignof(RawJob));
    run(env);
    complete(d);
}

/// Run `f` on the blocking pool and return its value. The calling coroutine PARKS while it runs, so the
/// worker thread stays available; any other caller simply blocks. This is how a coroutine calls something
/// that would otherwise hold a worker hostage -- a blocking `read`, a legacy library, a slow syscall.
pub fn call<F: fn move() T + Send + 'static, T: Send>(f: F) T {
    let mut slot: T;
    let mut done = Done { state: sync::Mutex::<i32>::new(0), cv: sync::Condvar::new() };
    let mut g = Global {};
    let env = g.alloc(sizeof(Payload<F, T>), alignof(Payload<F, T>)) as *mut Payload<F, T>;
    unsafe env[0] = Payload::<F, T> { body: f, slot: &mut slot, done: &mut done };
    submit(entry::<F, T>, env);
    {
        let gd = done.state.lock();
        while *gd.get() == 0 {
            done.cv.wait(&gd);
        }
    }
    return slot;
}

/// Stop the blocking pool and join its threads. Idempotent; a no-op if it never started. Call it once, from
/// the main thread, after every `call` has returned -- alongside `runtime::shutdown()`.
pub fn shutdown() {
    let sp = (&mut G_STATE) as *mut i32;
    if atomic_load(sp) != 2 {
        return;
    }
    let p = G_POOL;
    unsafe sc_runtime::sc_rt_mutex_lock((*p).lock);
    unsafe (*p).shutting = 1;
    unsafe sc_runtime::sc_rt_cond_broadcast((*p).cv);
    unsafe sc_runtime::sc_rt_mutex_unlock((*p).lock);
    let n = unsafe (*p).threads.len();
    for i in 0..n {
        let h = unsafe (*p).threads[i];
        let _ = unsafe sc_runtime::sc_rt_thread_join(h);
    }
    unsafe (*p).threads.free();
    unsafe sc_runtime::sc_rt_mutex_free((*p).lock);
    unsafe sc_runtime::sc_rt_cond_free((*p).cv);
    let mut g = Global {};
    g.dealloc(p, sizeof(Pool), alignof(Pool));
    atomic_store(sp, 0);
    G_POOL = null;
}
