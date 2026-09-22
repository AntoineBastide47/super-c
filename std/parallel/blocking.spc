// The escape hatch for work that blocks its OS thread. Import with `import std::parallel::blocking;`.
//
//     let data = blocking::call(fn() Data {
//         return read_from_a_library_that_blocks();
//     });
//
// A worker thread belongs to the scheduler: a coroutine that calls something which blocks the thread;
// `read()`, a legacy C library, anything the runtime cannot park: takes that worker out of circulation
// for the duration, and enough of them stall the whole pool. `call` moves the work onto a separate pool of
// plain OS threads (which are allowed to block) and PARKS the calling coroutine until the result comes
// back, so the worker keeps serving other tasks meanwhile. Called from a non-coroutine thread it still
// works: the caller blocks, which is what it would have done anyway. Called from a pool thread (a
// blocking body that itself calls `call`) the work runs right there: that thread may block, and a
// saturated pool never waits on itself.
//
// Bounds. At most `MAX_THREADS` pool threads exist, reservations for threads being created included, and
// at most `MAX_PENDING` accepted calls wait for a thread: a coroutine past that bound parks for admission
// (its wait node lives in its own frame, so admission storage is bounded by the tasks that exist), a plain
// thread blocks for it. A thread idle for `idle` nanoseconds (`set_idle_ns`, ten seconds by default) exits;
// its handle is announced first, so a join never waits for a running thread, and the handles are reaped at
// the next thread creation and at shutdown. Cancellable-call records are recycled within `CACHE_BUDGET`
// bytes.
//
// Cost. The queue is guarded by a spinlock held for a few stores; an OS mutex here was the pool's whole
// cost under load (every contended acquisition is a kernel round trip). Idle threads sleep one by one on
// a mutex and condition variable of their own and are woken one by one, most recently idle first (a
// shared parking lot woke every thread in a bucket per wake). One thread at a time spins for the next job
// before it sleeps, with a budget that doubles when the spin pays and halves when it does not, so a
// stream of short calls costs no thread wake, and an idle pool costs a short spin per wake.
//
// Ownership. A `call` and a `@blocking` call are not cancellable: their whole record (queue link, closure,
// result) lives in the caller's frame, which is alive until the pool thread has stored the value, and the
// thread's wake of the caller is its LAST touch of that frame. A `call_c` may be abandoned by a
// cancellation while its body still runs, so its record is heap-owned and reference-counted: the task and
// the pool thread hold one reference each, the completion/abandonment race is one compare-and-swap on the
// record's state, and whichever side ends with the value destroys it exactly once. Abandoning a call never
// stops the body: it returns whenever it returns, and the pool thread then destroys the unclaimed value.
//
// Shutdown. `try_shutdown(grace_ns)` closes the pool (a later call runs on its caller's own thread),
// releases admission waiters the same way, drains accepted work and reaps threads until the deadline, and
// reports what is left. What is left keeps everything it can reach: an expired deadline never means a
// foreign call stopped. `shutdown()` is the process-exit form: it aborts if the pool is not released.
// Stop the scheduler (`runtime::shutdown()`) after this pool: a task parked in a call keeps its stack
// until the call returns, which the scheduler's own bounded shutdown reports rather than frees.
//
// `f` must be `Send + 'static` for the same reason a launched task must: it runs on another thread, and
// it may still be running when the call that submitted it is gone (an abandoned `call_c`).

import atomic;
import sc_runtime;
import stdlib;
import std::parallel::runtime as runtime;
import std::parallel::platform as platform;

/// The most threads the blocking pool starts: the effective concurrency limit of `call`.
pub const MAX_THREADS: usize = 64; // enough concurrent blocking calls for real programs, bounded for safety
/// The most accepted calls waiting for a thread; past it, callers wait for admission.
pub const MAX_PENDING: usize = 1024;
/// How long `shutdown()` gives accepted work to finish before it aborts the process.
pub const SHUTDOWN_GRACE_NS: u64 = 1000000000;
/// Bytes of recycled `call_c` records the pool keeps for reuse.
pub const CACHE_BUDGET: usize = 65536;
const IDLE_NS_DEFAULT: i64 = 10000000000; // a thread with nothing to do for ten seconds goes away again
const SPIN_MIN: i32 = 32; // the spinner's look-again floor: see `pool_main`
const SPIN_MAX: i32 = 512; // and its ceiling: a spin longer than the wake it stands in for cannot pay
const CACHE_MIN: usize = 64; // the smallest record class
const CLASSES: usize = 7; // classes double from CACHE_MIN: 64, 128, ..., 4096
const POOL_THREAD: i32 = -2; // the worker-index slot of a pool thread: off the scheduler, may block

static mut G_STATE: i32 = 0; // 0 uninit / 1 building / 2 ready / 3 closing (a bounded shutdown is on)
static mut G_POOL: *mut Pool = null;
static mut G_EXT: usize = 0; // atomic: plain threads between reading state 2 and leaving the pool's lock
static mut G_IDLE_NS: i64 = IDLE_NS_DEFAULT;
static mut G_PUBLISH_DELAY_NS: i64 = 0; // test hook: a pause between creating a thread and publishing it

// The header every job carries: its queue link, the trampoline that runs and settles it, and who waits.
// A coroutine waits through its park token; a plain thread waits on `done`.
@no_const
pub struct Job {
    pub next: *mut Job,
    pub run: fn(*mut Job) void,
    pub co: *mut runtime::Coroutine,
    pub token: u32,
    pub done: i32, // atomic latch for a plain-thread caller
    pub t: *mut PThread, // the pool thread running the job; null for a job run in place
}

// A coroutine waiting for admission: the node lives in its frame, on the pool's list under the lock.
@no_const
struct Admit {
    pub co: *mut runtime::Coroutine,
    pub token: u32,
    pub next: *mut Admit,
}

// One pool thread. The creator publishes the handle into the record before the thread may take work;
// an idle thread parks on `park` from the idle stack; retirement moves the record from `live` to
// `retired`, whose handles a reap joins.
@no_const
struct PThread {
    pub handle: *mut void,
    pub mtx: *mut void, // where this thread sleeps when idle: its own, so a wake is an uncontended
    pub cv: *mut void, // lock and one signal that reaches exactly this thread
    pub next: *mut PThread, // the live list, then the retired list
    pub inext: *mut PThread, // the idle stack
    pub pool: *mut Pool,
    pub published: i32, // atomic: the handle is stored
    pub park: i32, // atomic: 1 = popped from the idle stack with work to take
    pub wakes: i32, // atomic: wakes a submitter still owes this thread (popped idle, signal not yet sent)
    pub covering: i32, // became the spinner when it released its last call (pool lock)
}

// A recycled `call_c` record, linked by class.
@no_const
struct CacheBlk {
    pub next: *mut CacheBlk,
}

/// Pool counters, read under the pool lock: a consistent snapshot.
pub struct Stats {
    pub live: usize, // threads that may take work
    pub starting: usize, // reserved thread slots whose creation is in progress
    pub idle: usize, // threads parked for work
    pub queued: usize, // accepted calls not yet started (reservations included)
    pub running: usize, // calls executing on pool threads
    pub peak_threads: usize, // most live plus starting at once
    pub peak_queued: usize, // most accepted calls waiting at once
    pub created: usize, // threads created over the pool's life
    pub reaped: usize, // exited threads joined
    pub admit_waits: usize, // admission parks and blocks
    pub cache_bytes: usize, // recycled record bytes held
}

/// What a bounded shutdown left behind. `released` means the pool is gone: nothing else is owed.
pub struct ShutdownReport {
    pub queued: usize, // accepted calls still waiting for a thread
    pub running: usize, // calls still executing
    pub threads: usize, // threads not yet retired, creations not yet settled
    pub released: bool,
}

@no_const
struct Pool {
    pub spin: i32, // the queue lock: guards everything below but the atomics and the cache
    pub head: *mut Job, // written with atomic stores: the spinner reads it without the lock
    pub tail: *mut Job,
    pub idle_head: *mut PThread, // parked threads, most recently idle first
    pub idle: usize,
    pub live: usize,
    pub starting: usize,
    pub running: usize,
    pub spinner: i32, // a thread is spinning for the next job: a linked job needs no wake
    pub spin_budget: i32, // SPIN_MIN..SPIN_MAX
    pub shutting: i32,
    pub live_list: *mut PThread,
    pub retired: *mut PThread,
    pub admit_head: *mut Admit,
    pub admit_tail: *mut Admit,
    pub ext_waiters: usize, // plain threads parked on `admit_gen`
    pub admit_gen: i32, // atomic: bumped when a plain admission waiter should look again
    pub done_gen: i32, // atomic: bumped when a shutdown waiter should look again
    pub peak_threads: usize,
    pub peak_queued: usize,
    pub created: usize,
    pub reaped: usize,
    pub admit_waits: usize,
    pub pad_q: Array<u64, 16>, // `queued` on a line of its own: every submitting worker adds to it outside
    pub queued: usize, // atomic: accepted, not yet started (the admission bound)
    pub pad_w: Array<u64, 15>,
    pub wakes: usize, // atomic: claimed wakes not yet handed to the scheduler, a stack through `run.next`
    pub pad_c: Array<u64, 15>, // the lock, and the cache below, must not share these lines
    pub cache_spin: i32, // the record cache has its own lock: freeing a record must not take the queue lock
    pub cache_bytes: usize,
    pub cache: Array<*mut CacheBlk, CLASSES>,
}

// --- the pool -----------------------------------------------------------------------------------------.

fn build_pool() *mut Pool {
    let mut g = Global {};
    let p = (unsafe g.alloc(sizeof(Pool), alignof(Pool))) as *mut Pool;
    unsafe p[0] = Pool {
        spin: 0,
        head: null,
        tail: null,
        idle_head: null,
        idle: 0,
        live: 0,
        starting: 0,
        running: 0,
        spinner: 0,
        spin_budget: SPIN_MAX,
        shutting: 0,
        live_list: null,
        retired: null,
        admit_head: null,
        admit_tail: null,
        ext_waiters: 0,
        admit_gen: 0,
        done_gen: 0,
        peak_threads: 0,
        peak_queued: 0,
        created: 0,
        reaped: 0,
        admit_waits: 0,
        pad_q: Array::<u64, 16> {},
        queued: 0,
        pad_w: Array::<u64, 15> {},
        wakes: 0,
        pad_c: Array::<u64, 15> {},
        cache_spin: 0,
        cache_bytes: 0,
        cache: Array::<*mut CacheBlk, CLASSES> {},
    };
    return p;
}

// The pool, started on first use; null while a shutdown is closing it. Same init state machine as the
// scheduler's: `G_POOL` is ordered by `G_STATE`, which the compiler cannot see: the CAS winner publishes the
// pointer and THEN releases state 2, and every reader acquires state 2 first.
fn ensure_pool() *mut Pool {
    unsafe {
        let sp = (&mut G_STATE) as *mut i32;
        let st = atomic::load_i32(sp, 4);
        if st == 2 {
            return G_POOL;
        }
        if st == 3 {
            return null;
        }
        if atomic::cas_i32(sp, 0, 1, false, 4, 0) {
            let p = build_pool();
            G_POOL = p;
            atomic::store_i32(sp, 2, 4);
            return p;
        }
        loop {
            let s = atomic::load_i32(sp, 4);
            if s == 2 {
                return G_POOL;
            }
            if s == 3 {
                return null;
            }
        }
    }
}

/// Set the idle timeout of pool threads, in nanoseconds. Takes effect for parks that start after it.
pub fn set_idle_ns(ns: i64) {
    atomic::store_i64(&mut unsafe G_IDLE_NS, ns, 0);
}

/// Test hook: pause every thread creation for `ns` between the thread's start and the publication of its
/// handle, to widen the window in which a thread runs before it may take work.
pub fn set_publish_delay_ns(ns: i64) {
    atomic::store_i64(&mut unsafe G_PUBLISH_DELAY_NS, ns, 0);
}

fn lock(p: *mut Pool) {
    unsafe sc_runtime::sc_rt_spin_lock(&mut p.spin);
}

fn unlock(p: *mut Pool) {
    unsafe sc_runtime::sc_rt_spin_unlock(&mut p.spin);
}

// The queue head is read by the spinner without the lock: every write is an atomic store (a plain
// store on every target, and a defined one against that read).
fn head_store(p: *mut Pool, j: *mut Job) {
    atomic::store_usize((&mut unsafe p.head) as *mut usize, j as usize, 0);
}

fn on_pool_thread() bool {
    return unsafe sc_runtime::sc_rt_widx_get() == POOL_THREAD;
}

// Something a shutdown waits for changed. Caller holds the lock.
fn done_bump(p: *mut Pool) {
    let _ = atomic::add_i32(&mut unsafe p.done_gen, 1, 3);
    unsafe sc_runtime::sc_rt_unpark_all(&mut p.done_gen);
}

// --- threads ------------------------------------------------------------------------------------------.

// Join every announced exit. Caller holds the lock, which the joins release: each waits for at most an
// exiting thread's last instructions, never for a running one.
fn reap(p: *mut Pool) {
    let mut t = unsafe p.retired;
    if t == null {
        return;
    }
    unsafe p.retired = null;
    unlock(p);
    let mut g = Global {};
    let mut n: usize = 0;
    while t != null {
        let nx = unsafe t.next;
        if unsafe sc_runtime::sc_rt_thread_join(t.handle) != 0 {
            panic("blocking pool: cannot join an exited pool thread");
        }
        // A submitter that popped this thread while it was idle may not have sent its signal yet (it was
        // held off between releasing the pool lock and taking this one); the thread has exited, but its
        // lock and condition must outlive that signal. Bounded by that submitter's few instructions.
        while atomic::load_i32(&mut unsafe t.wakes, 1) != 0 {
            unsafe sc_runtime::sc_rt_thread_yield();
        }
        unsafe sc_runtime::sc_rt_cond_free(t.cv);
        unsafe sc_runtime::sc_rt_mutex_free(t.mtx);
        unsafe g.dealloc(t, sizeof(PThread), alignof(PThread));
        n = n + 1;
        t = nx;
    }
    lock(p);
    unsafe p.reaped = unsafe p.reaped + n;
}

// What a job just linked needs from the caller once the lock is released: the idle thread to unpark, or a
// thread to create.
struct Post {
    pub wake: *mut PThread,
    pub spawn: bool,
}

// See to a taker for a job just linked. Caller holds the lock. A spinning thread will find the job by
// itself, but it takes only one: any job beyond the one it covers pops the most recently idle thread, or
// reserves a thread while the limit allows, which the caller creates after unlocking.
fn plan(p: *mut Pool) Post {
    let mut post = Post { wake: null, spawn: false };
    if unsafe p.spinner != 0 && unsafe p.head.next == null {
        return post;
    }
    let t = pop_idle(p);
    if t != null {
        post.wake = t;
        return post;
    }
    let n = unsafe p.live + unsafe p.starting;
    if n >= MAX_THREADS {
        return post;
    }
    unsafe p.starting = unsafe p.starting + 1;
    if n + 1 > unsafe p.peak_threads {
        unsafe p.peak_threads = n + 1;
    }
    post.spawn = true;
    return post;
}

// Pop the most recently idle thread for a wake, or null. Caller holds the lock and owes the thread a
// `wake_thread`. The signal may come only after the lock is released, from a worker the scheduler may
// hold off for as long as it likes; meanwhile the thread may take work on its own timed wake, serve it,
// and be retired and reaped. Every owed wake is counted, so the reap frees no record with one still due.
fn pop_idle(p: *mut Pool) *mut PThread {
    let t = unsafe p.idle_head;
    if t == null {
        return null;
    }
    unsafe p.idle_head = unsafe t.inext;
    unsafe p.idle = unsafe p.idle - 1;
    atomic::store_i32(&mut unsafe t.park, 1, 2);
    let _ = atomic::add_i32(&mut unsafe t.wakes, 1, 2);
    return t;
}

// Wake a thread popped by `pop_idle` (`park` already set): the signal lands under its own lock, so a
// thread between its check of `park` and its wait cannot miss it. The wake owed is paid off only once the
// lock is released: until then the record must stay allocated, whatever the thread itself has done.
fn wake_thread(t: *mut PThread) {
    unsafe sc_runtime::sc_rt_mutex_lock(t.mtx);
    unsafe sc_runtime::sc_rt_cond_signal(t.cv);
    unsafe sc_runtime::sc_rt_mutex_unlock(t.mtx);
    let _ = atomic::sub_i32(&mut unsafe t.wakes, 1, 3);
}

fn post_run(p: *mut Pool, post: Post) {
    if post.wake != null {
        wake_thread(post.wake);
    }
    if post.spawn {
        spawn_thread(p);
    }
}

// Create the thread a reservation stands for, outside the lock. Success publishes the handle and moves
// the reservation to the live count before the thread may take work; failure releases the reservation.
// With nothing else able to run the queued work, a failure is fatal; otherwise it is reported and a live
// thread takes the work when it frees up.
fn spawn_thread(p: *mut Pool) {
    let mut g = Global {};
    let t = (unsafe g.alloc(sizeof(PThread), alignof(PThread))) as *mut PThread;
    let mtx = unsafe sc_runtime::sc_rt_mutex_new();
    let cv = unsafe sc_runtime::sc_rt_cond_new();
    unsafe t[0] = PThread {
        handle: null,
        mtx: mtx,
        cv: cv,
        next: null,
        inext: null,
        pool: p,
        published: 0,
        park: 0,
        wakes: 0,
        covering: 0,
    };
    let mut h: *mut void = null;
    let mut rc: i32 = 12; // ENOMEM: a thread without its lock and condition variable is not started
    if mtx != null && cv != null {
        rc = unsafe sc_runtime::sc_rt_thread_create(&mut h, pool_main, t);
    }
    let delay = atomic::load_i64(&mut unsafe G_PUBLISH_DELAY_NS, 0);
    if rc == 0 && delay > 0 {
        unsafe sc_runtime::sc_rt_sleep_ns(delay);
    }
    lock(p);
    if rc == 0 {
        // The joins release the lock: the reservation stays counted until the thread is on the live list,
        // or a shutdown running meanwhile sees neither and releases the pool under this publication.
        reap(p);
        unsafe p.starting = unsafe p.starting - 1;
        unsafe t.handle = h;
        unsafe t.next = unsafe p.live_list;
        unsafe p.live_list = t;
        unsafe p.live = unsafe p.live + 1;
        unsafe p.created = unsafe p.created + 1;
        atomic::store_i32(&mut unsafe t.published, 1, 2);
        unlock(p);
        unsafe sc_runtime::sc_rt_unpark_all(&mut t.published);
        return;
    }
    unsafe p.starting = unsafe p.starting - 1;
    unsafe sc_runtime::sc_rt_cond_free(cv);
    unsafe sc_runtime::sc_rt_mutex_free(mtx);
    unsafe g.dealloc(t, sizeof(PThread), alignof(PThread));
    let stranded = unsafe p.live == 0 && unsafe p.starting == 0 && unsafe p.head != null;
    done_bump(p); // a shutdown counting reservations
    unlock(p);
    if stranded {
        panic("blocking pool: cannot create a thread and none is running");
    }
    eprintln("super-c: blocking pool: thread creation failed with code {}; the job waits for a live thread", rc);
}

// Take this thread off the live list and announce its exit. Caller holds the lock.
fn retire(p: *mut Pool, t: *mut PThread) {
    let mut pp = (&mut unsafe p.live_list) as *mut *mut PThread;
    while unsafe pp[0] != t {
        pp = &mut unsafe pp[0].next;
    }
    unsafe pp[0] = unsafe t.next;
    unsafe t.next = unsafe p.retired;
    unsafe p.retired = t;
    unsafe p.live = unsafe p.live - 1;
    done_bump(p);
}

// Take this thread off the idle stack, where its timed-out park left it. Caller holds the lock.
fn idle_unlink(p: *mut Pool, t: *mut PThread) {
    let mut pp = (&mut unsafe p.idle_head) as *mut *mut PThread;
    while unsafe pp[0] != t {
        pp = &mut unsafe pp[0].inext;
    }
    unsafe pp[0] = unsafe t.inext;
    unsafe p.idle = unsafe p.idle - 1;
}

// A job was taken off the queue: one more may be accepted. Caller holds the lock.
fn admit_next(p: *mut Pool) {
    let _ = atomic::sub_usize(&mut unsafe p.queued, 1, 3);
    let a = unsafe p.admit_head;
    if a != null {
        unsafe p.admit_head = unsafe a.next;
        if unsafe p.admit_head == null {
            unsafe p.admit_tail = null;
        }
        let _ = runtime::wake(unsafe a.co, unsafe a.token);
    }
    if unsafe p.ext_waiters != 0 {
        let _ = atomic::add_i32(&mut unsafe p.admit_gen, 1, 3);
        unsafe sc_runtime::sc_rt_unpark_all(&mut p.admit_gen);
    }
}

// Park this idle thread until it is handed work or the idle timeout passes. Caller holds the lock, which
// is released across the park and held again on return; reports whether work was handed over.
fn idle_park(p: *mut Pool, t: *mut PThread) bool {
    atomic::store_i32(&mut unsafe t.park, 0, 0);
    unsafe t.inext = unsafe p.idle_head;
    unsafe p.idle_head = t;
    unsafe p.idle = unsafe p.idle + 1;
    unlock(p);
    let deadline = platform::now_ns() + atomic::load_i64(&mut unsafe G_IDLE_NS, 0) as u64;
    unsafe sc_runtime::sc_rt_mutex_lock(t.mtx);
    while atomic::load_i32(&mut unsafe t.park, 1) == 0 {
        let now = platform::now_ns();
        if now >= deadline {
            break;
        }
        let _ = unsafe sc_runtime::sc_rt_cond_timedwait_ns(t.cv, t.mtx, (deadline - now) as i64);
    }
    unsafe sc_runtime::sc_rt_mutex_unlock(t.mtx);
    lock(p);
    if atomic::load_i32(&mut unsafe t.park, 1) != 0 {
        return true;
    }
    idle_unlink(p, t);
    return false;
}

// The C-ABI thread body: wait for the creator's publication, then take work until the pool drains at
// shutdown or the thread has been idle for the timeout. Between jobs, one thread spins for the next
// before parking; the budget adapts to whether the spin paid. A thread that just served a call is that
// spinner from before its caller is woken (see `release`), so a call the caller makes at once finds it.
fn pool_main(arg: *mut void) *mut void {
    let t = arg as *mut PThread;
    let p = unsafe t.pool;
    unsafe sc_runtime::sc_rt_widx_set(POOL_THREAD);
    while atomic::load_i32(&mut unsafe t.published, 1) == 0 {
        unsafe sc_runtime::sc_rt_park(&mut t.published, 0, -1);
    }
    lock(p);
    loop {
        let j = unsafe p.head;
        if j != null {
            if unsafe t.covering != 0 {
                unsafe t.covering = 0;
                unsafe p.spinner = 0;
            }
            head_store(p, unsafe j.next);
            if unsafe j.next == null {
                unsafe p.tail = null;
            }
            unsafe p.running = unsafe p.running + 1;
            unsafe j.t = t;
            admit_next(p);
            unlock(p);
            // Outside the lock: this is the part that is allowed to block. The trampoline counts this
            // thread out again (`release`) before it wakes the caller.
            let run = unsafe j.run;
            run(j);
            lock(p);
            continue;
        }
        if unsafe p.shutting != 0 {
            if unsafe t.covering != 0 {
                unsafe t.covering = 0;
                unsafe p.spinner = 0;
            }
            break;
        }
        if unsafe t.covering != 0 || unsafe p.spinner == 0 {
            unsafe t.covering = 0;
            unsafe p.spinner = 1;
            if spin_for_work(p) || unsafe p.head != null || unsafe p.shutting != 0 {
                continue;
            }
        }
        // Timed out with still nothing to do: a burst of blocking calls should not cost threads for the
        // rest of the process. A submission starts another the moment one is needed again.
        if !idle_park(p, t) && unsafe p.head == null && unsafe p.shutting == 0 {
            break;
        }
    }
    retire(p, t);
    unlock(p);
    return null;
}

// Spin for the next job as the pool's one spinner: the caller holds the lock and has set `spinner`. Back
// under the lock with `spinner` cleared and the budget adapted to whether the spin paid.
fn spin_for_work(p: *mut Pool) bool {
    let budget = unsafe p.spin_budget;
    unlock(p);
    let mut spins: i32 = 0;
    let mut found = false;
    while spins < budget {
        if atomic::load_usize((&mut unsafe p.head) as *mut usize, 1) != 0 {
            found = true;
            break;
        }
        unsafe sc_runtime::sc_rt_cpu_relax();
        spins = spins + 1;
    }
    lock(p);
    unsafe p.spinner = 0;
    if found {
        if budget < SPIN_MAX {
            unsafe p.spin_budget = budget * 2;
        }
    } else if budget > SPIN_MIN {
        unsafe p.spin_budget = budget / 2;
    }
    return found;
}

// Count the pool thread running `j` out of the call, before its caller is woken: with no spinner, this
// thread becomes it, so a caller that calls again at once is covered instead of reserving a creation.
// A job run in place (`t` null) has nothing to release.
fn release(j: *mut Job) {
    let t = unsafe j.t;
    if t == null {
        return;
    }
    let p = unsafe t.pool;
    lock(p);
    unsafe p.running = unsafe p.running - 1;
    if unsafe p.shutting != 0 {
        done_bump(p);
    } else if unsafe p.spinner == 0 {
        unsafe p.spinner = 1;
        unsafe t.covering = 1;
    }
    unlock(p);
}

// --- submission ---------------------------------------------------------------------------------------.

// Link an accepted job. Caller holds the lock and has reserved the job's admission; the returned plan is
// run after unlocking.
fn enqueue(p: *mut Pool, j: *mut Job) Post {
    unsafe j.next = null;
    if unsafe p.tail == null {
        head_store(p, j);
    } else {
        unsafe p.tail.next = j;
    }
    unsafe p.tail = j;
    let q = atomic::load_usize(&mut unsafe p.queued, 0);
    if q > unsafe p.peak_queued {
        unsafe p.peak_queued = q;
    }
    return plan(p);
}

// The park hand-off of a coroutine call: link the job once the coroutine's context is saved, so the pool
// cannot wake a task that is still switching out. A pool found closed here (a shutdown landed between
// admission and this hand-off) runs the job on this worker at once: no thread is promised to take it.
fn commit_submit(a: *mut void) {
    let j = a as *mut Job;
    let p = unsafe G_POOL;
    lock(p);
    if unsafe p.shutting != 0 {
        let _ = atomic::sub_usize(&mut unsafe p.queued, 1, 3);
        unlock(p);
        let run = unsafe j.run;
        run(j);
        return;
    }
    let post = enqueue(p, j);
    unlock(p);
    post_run(p, post);
}

fn commit_unlock(a: *mut void) {
    unsafe sc_runtime::sc_rt_spin_unlock(a as *mut i32);
}

// Admit one coroutine call: the pool, or null when the call must run on the caller's thread (the pool is
// closing) or, for a cancellable wait, the admission was cancelled (`cancelled`). The caller has recorded
// its wait kind; the fence orders that record before the state read, so a stopping pool's registry scan
// sees every task that may still reach it.
fn admit(co: *mut runtime::Coroutine, cancellable: bool, cancelled: &mut bool) *mut Pool {
    atomic::fence(4);
    let p = ensure_pool();
    if p == null {
        return null;
    }
    if atomic::add_usize(&mut unsafe p.queued, 1, 3) < MAX_PENDING {
        return p;
    }
    let _ = atomic::sub_usize(&mut unsafe p.queued, 1, 3);
    lock(p);
    loop {
        if unsafe p.shutting != 0 {
            unlock(p);
            return null;
        }
        if atomic::load_usize(&mut unsafe p.queued, 0) < MAX_PENDING {
            let _ = atomic::add_usize(&mut unsafe p.queued, 1, 3);
            unlock(p);
            return p;
        }
        unsafe p.admit_waits = unsafe p.admit_waits + 1;
        let token = runtime::park_begin(co);
        let mut a = Admit { co: co, token: token, next: null };
        let ap = &mut a;
        if unsafe p.admit_tail == null {
            unsafe p.admit_head = ap;
        } else {
            unsafe p.admit_tail.next = ap;
        }
        unsafe p.admit_tail = ap;
        let reason = runtime::park_timed(token, 0, commit_unlock, &mut unsafe p.spin, cancellable);
        lock(p);
        admit_unlink(p, ap);
        if reason == runtime::WR_CANCEL || reason == runtime::WR_SHUTDOWN {
            unlock(p);
            *cancelled = true;
            return null;
        }
    }
}

// Take an admission node off the list if a wake did not already pop it. Caller holds the lock.
fn admit_unlink(p: *mut Pool, ap: *mut Admit) {
    let mut prev: *mut Admit = null;
    let mut cur = unsafe p.admit_head;
    while cur != null && cur != ap {
        prev = cur;
        cur = unsafe cur.next;
    }
    if cur != ap {
        return;
    }
    if prev == null {
        unsafe p.admit_head = unsafe ap.next;
    } else {
        unsafe prev.next = unsafe ap.next;
    }
    if unsafe p.admit_tail == ap {
        unsafe p.admit_tail = prev;
    }
}

// Submit from a plain thread: wait for admission if the pool is full, link the job, see to a thread.
// Returns false when the pool is closing, in which case the caller runs the job itself.
fn submit_ext(p: *mut Pool, j: *mut Job) bool {
    lock(p);
    while unsafe p.shutting == 0 && atomic::load_usize(&mut unsafe p.queued, 0) >= MAX_PENDING {
        unsafe p.admit_waits = unsafe p.admit_waits + 1;
        unsafe p.ext_waiters = unsafe p.ext_waiters + 1;
        let gen = atomic::load_i32(&mut unsafe p.admit_gen, 1);
        unlock(p);
        unsafe sc_runtime::sc_rt_park(&mut p.admit_gen, gen, -1);
        lock(p);
        unsafe p.ext_waiters = unsafe p.ext_waiters - 1;
    }
    if unsafe p.shutting != 0 {
        unlock(p);
        return false;
    }
    let _ = atomic::add_usize(&mut unsafe p.queued, 1, 3);
    let post = enqueue(p, j);
    unlock(p);
    post_run(p, post);
    return true;
}

// Block a plain thread until its job has settled.
fn wait_ext(j: *mut Job) {
    runtime::replay_release(); // about to block: in replay mode the pool runs while we do not
    while atomic::load_i32(&mut unsafe j.done, 1) == 0 {
        unsafe sc_runtime::sc_rt_park(&mut j.done, 0, -1);
    }
}

// The job's value is stored: wake its caller. For a coroutine the claim is the last touch of the record
// (the frame may end the moment the park is claimed); for a plain thread the latch store is, and the
// unpark that follows uses only the address.
fn settle(j: *mut Job) {
    let co = unsafe j.co;
    if co != null {
        let token = unsafe j.token;
        if runtime::claim_wake(co, token, runtime::WR_BLOCKING) {
            wake_push(co);
        }
        return;
    }
    atomic::store_i32(&mut unsafe j.done, 1, 2);
    unsafe sc_runtime::sc_rt_unpark_all(&mut j.done);
}

// Hand a claimed task to the scheduler in a batch: threads that complete together push onto one stack,
// and the one that found it empty flushes everything pushed meanwhile under a single scheduler lock
// (sixty-four threads injecting one wake each made that lock the pool's cost). A push onto a non-empty
// stack is covered by the flusher's next swap; a push onto an empty one flushes itself. A flush is one
// swap and one scheduler operation, so a wake waits for at most the batch in front of it.
fn wake_push(co: *mut runtime::Coroutine) {
    let p = unsafe G_POOL;
    let hp = (&mut unsafe p.wakes) as *mut usize;
    loop {
        let old = atomic::load_usize(hp, 0);
        unsafe co.run.next = old as *mut runtime::Runnable;
        if atomic::cas_usize(hp, old, co as usize, true, 3, 0) {
            if old == 0 {
                wake_flush(hp);
            }
            return;
        }
    }
}

fn wake_flush(hp: *mut usize) {
    loop {
        let got = atomic::swap_usize(hp, 0, 3);
        if got == 0 {
            return;
        }
        // Pushed last in, first out: reverse into completion order.
        let tail = got as *mut runtime::Coroutine;
        let mut head: *mut runtime::Coroutine = null;
        let mut cur = tail;
        let mut n: i32 = 0;
        while cur != null {
            let nx = (unsafe cur.run.next) as *mut runtime::Coroutine;
            unsafe cur.run.next = head as *mut runtime::Runnable;
            head = cur;
            cur = nx;
            n = n + 1;
        }
        runtime::run_claimed(head, tail, n);
    }
}

// --- call: frame-resident records ---------------------------------------------------------------------.

// The record of a non-cancellable call: the job, the closure and the value, in the caller's frame. Written
// through a raw pointer into declared but never initialised storage, so the frame owns nothing of it: the
// pool thread consumes the closure and the caller reads the value out exactly once.
@no_const
struct Call<F, T> {
    pub job: Job,
    pub body: F,
    pub value: T,
}

/// The per-`(F, T)` trampoline of `call`: run the closure on the pool thread, store its value, wake the
/// caller. `pub` for linkage.
pub fn run_call<F: fn move() T + Send, T>(j: *mut Job) {
    let rp = j as *mut Call<F, T>;
    let f = unsafe rp.body;
    unsafe rp.value = f();
    release(j);
    settle(j);
}

// A plain thread or a pool thread calling: block on the result, or run the body right here.
fn call_ext<F: fn move() T + Send + 'static, T: Send>(f: F) T {
    if on_pool_thread() {
        return f();
    }
    let _ = atomic::add_usize(&mut unsafe G_EXT, 1, 4);
    let p = ensure_pool();
    if p == null {
        let _ = atomic::sub_usize(&mut unsafe G_EXT, 1, 4);
        return f();
    }
    let mut rec: Call<F, T>;
    let rp = (&mut rec) as *mut Call<F, T>;
    unsafe rp.job = Job { next: null, run: run_call::<F, T>, co: null, token: 0, done: 0, t: null };
    unsafe rp.body = f;
    if submit_ext(p, rp as *mut Job) {
        wait_ext(rp as *mut Job);
    } else {
        let g = unsafe rp.body;
        unsafe rp.value = g();
    }
    let _ = atomic::sub_usize(&mut unsafe G_EXT, 1, 4);
    let v = unsafe {
        rp.value;
    };
    return v;
}

/// Run `f` on the blocking pool and return its value. The calling coroutine PARKS while it runs, so the
/// worker thread stays available; a plain thread blocks; a pool thread runs it in place. Not a
/// cancellation point: a cancelled task returns from here only with the value. This is how a coroutine
/// calls something that would otherwise hold a worker hostage: a blocking `read`, a legacy library, a slow
/// syscall.
pub fn call<F: fn move() T + Send + 'static, T: Send>(f: F) T {
    let co = runtime::current();
    if co == null {
        return call_ext::<F, T>(f);
    }
    runtime::wait_note(runtime::WK_BLOCKING, 0);
    let mut cancelled = false;
    let p = admit(co, false, &mut cancelled);
    if p == null {
        runtime::wait_clear();
        return f();
    }
    let mut rec: Call<F, T>;
    let rp = (&mut rec) as *mut Call<F, T>;
    let token = runtime::park_begin(co);
    unsafe rp.job = Job { next: null, run: run_call::<F, T>, co: co, token: token, done: 0, t: null };
    unsafe rp.body = f;
    let reason = runtime::park_timed(token, 0, commit_submit, rp, false);
    if reason != runtime::WR_BLOCKING {
        panic("a non-cancellable blocking park has exactly one waker");
    }
    let v = unsafe {
        rp.value;
    };
    runtime::park_done(co);
    runtime::wait_clear();
    return v;
}

// The record of a `@blocking` call: an already type-erased body and its argument frame.
@no_const
struct Raw {
    pub job: Job,
    pub run: fn(*mut void) void,
    pub env: *mut void,
}

/// Runs one `run_blocking` job on a pool thread. `pub` for linkage.
pub fn run_raw(j: *mut Job) {
    let rp = j as *mut Raw;
    let run = unsafe rp.run;
    let env = unsafe rp.env;
    run(env);
    release(j);
    settle(j);
}

/// Run `run(env)` on the blocking pool and park the caller until it returns. What a `@blocking` extern
/// function's generated wrapper hands its work to: hence the pinned C symbol, which is the name codegen
/// emits. Masked: foreign code whose result lands through `env` can never be abandoned.
@c.export("__sc_blocking_run")
pub fn run_blocking(run: fn(*mut void) void, env: *mut void) {
    if on_pool_thread() {
        run(env);
        return;
    }
    let mut rec: Raw;
    let rp = (&mut rec) as *mut Raw;
    unsafe rp.run = run;
    unsafe rp.env = env;
    let co = runtime::current();
    if co == null {
        let _ = atomic::add_usize(&mut unsafe G_EXT, 1, 4);
        let p = ensure_pool();
        if p == null {
            let _ = atomic::sub_usize(&mut unsafe G_EXT, 1, 4);
            run(env);
            return;
        }
        unsafe rp.job = Job { next: null, run: run_raw, co: null, token: 0, done: 0, t: null };
        if submit_ext(p, rp as *mut Job) {
            wait_ext(rp as *mut Job);
        } else {
            run(env);
        }
        let _ = atomic::sub_usize(&mut unsafe G_EXT, 1, 4);
        return;
    }
    runtime::wait_note(runtime::WK_BLOCKING, 0);
    let mut cancelled = false;
    let p = admit(co, false, &mut cancelled);
    if p == null {
        runtime::wait_clear();
        run(env);
        return;
    }
    let token = runtime::park_begin(co);
    unsafe rp.job = Job { next: null, run: run_raw, co: co, token: token, done: 0, t: null };
    let reason = runtime::park_timed(token, 0, commit_submit, rp, false);
    if reason != runtime::WR_BLOCKING {
        panic("a non-cancellable blocking park has exactly one waker");
    }
    runtime::park_done(co);
    runtime::wait_clear();
}

// --- call_c: heap records ---------------------------------------------------------------------------.

// The states of a cancellable call's record: the single-winner race between completion and abandonment.
const BS_PENDING: i32 = 0;
const BS_COMPLETE: i32 = 1;
const BS_ABANDONED: i32 = 2;

// The record of a cancellable call, heap-owned and reference-counted (task and pool thread). `bytes` is
// its allocation size, which the cache classes by.
@no_const
struct CCall<F, T> {
    pub job: Job,
    pub refs: i32, // atomic
    pub state: i32, // atomic BS_*
    pub bytes: usize,
    pub body: F,
    pub value: T,
}

// The cache class of a record size: 0 for the smallest, or CLASSES for a size the cache does not keep.
fn cache_class(bytes: usize) usize {
    let mut c: usize = 0;
    let mut sz = CACHE_MIN;
    while sz < bytes && c < CLASSES {
        sz = sz * 2;
        c = c + 1;
    }
    return c;
}

fn cache_alloc(p: *mut Pool, bytes: usize) *mut void {
    let c = cache_class(bytes);
    if c < CLASSES {
        unsafe sc_runtime::sc_rt_spin_lock(&mut p.cache_spin);
        let b = unsafe p.cache[c];
        if b != null {
            unsafe p.cache[c] = unsafe b.next;
            unsafe p.cache_bytes = unsafe p.cache_bytes - (CACHE_MIN << c);
            unsafe sc_runtime::sc_rt_spin_unlock(&mut p.cache_spin);
            return b;
        }
        unsafe sc_runtime::sc_rt_spin_unlock(&mut p.cache_spin);
    }
    let mut g = Global {};
    return unsafe g.alloc(
        if c < CLASSES {
            CACHE_MIN << c;
        } else {
            bytes;
        },
        16,
    );
}

fn cache_free(p: *mut Pool, blk: *mut void, bytes: usize) {
    let c = cache_class(bytes);
    if c < CLASSES {
        let sz = CACHE_MIN << c;
        unsafe sc_runtime::sc_rt_spin_lock(&mut p.cache_spin);
        if unsafe p.cache_bytes + sz <= CACHE_BUDGET {
            let b = blk as *mut CacheBlk;
            unsafe b.next = unsafe p.cache[c];
            unsafe p.cache[c] = b;
            unsafe p.cache_bytes = unsafe p.cache_bytes + sz;
            unsafe sc_runtime::sc_rt_spin_unlock(&mut p.cache_spin);
            return;
        }
        unsafe sc_runtime::sc_rt_spin_unlock(&mut p.cache_spin);
        let mut g = Global {};
        unsafe g.dealloc(blk, sz, 16);
        return;
    }
    let mut g = Global {};
    unsafe g.dealloc(blk, bytes, 16);
}

// Release every cached record. No thread runs.
fn cache_drain(p: *mut Pool) {
    let mut g = Global {};
    for c in 0..CLASSES {
        let mut b = unsafe p.cache[c];
        while b != null {
            let nx = unsafe b.next;
            unsafe g.dealloc(b, CACHE_MIN << c, 16);
            b = nx;
        }
        unsafe p.cache[c] = null;
    }
    unsafe p.cache_bytes = 0;
}

// Drop one reference; the last one recycles the record (its value was settled by then).
fn crec_drop<F, T>(rp: *mut CCall<F, T>) {
    if atomic::sub_i32(&mut unsafe rp.refs, 1, 3) == 1 {
        cache_free(unsafe G_POOL, rp, unsafe rp.bytes);
    }
}

/// The per-`(F, T)` trampoline of `call_c`: run the closure, publish the value into the record, and settle
/// the ownership race. If the task abandoned the call, the value is destroyed HERE: the pool thread never
/// touches the coroutine after an abandonment. `pub` for linkage.
pub fn run_ccall<F: fn move() T + Send, T>(j: *mut Job) {
    let rp = j as *mut CCall<F, T>;
    let f = unsafe rp.body;
    unsafe rp.value = f();
    release(j);
    if atomic::cas_i32(&mut unsafe rp.state, BS_PENDING, BS_COMPLETE, false, 4, 0) {
        settle(j);
    } else {
        let vp = (&mut unsafe rp.value) as *mut T;
        vp.free();
    }
    crec_drop::<F, T>(rp);
}

/// `call`, but the park is a cancellation point: `None` means the wait was cancelled, before the call was
/// admitted or while its body ran. The task's side of the job is ABANDONED: the blocking operation is
/// not stopped; when it returns, the pool thread destroys the unclaimed result. The cancellable form for
/// callers that can propagate cancellation.
pub fn call_c<F: fn move() T + Send + 'static, T: Send>(f: F) Option<T> {
    let co = runtime::current();
    if co == null {
        // A plain thread has no task to cancel.
        return Option::<T>::Some(call_ext::<F, T>(f));
    }
    runtime::wait_note(runtime::WK_BLOCKING, 0);
    let mut cancelled = false;
    let p = admit(co, true, &mut cancelled);
    if p == null {
        runtime::wait_clear();
        if cancelled {
            let _ = runtime::cancel_after_wait(true);
            return Option::<T>::None;
        }
        return Option::<T>::Some(f());
    }
    let bytes = sizeof(CCall<F, T>);
    let rp = cache_alloc(p, bytes) as *mut CCall<F, T>;
    let token = runtime::park_begin(co);
    unsafe rp.job = Job { next: null, run: run_ccall::<F, T>, co: co, token: token, done: 0, t: null };
    unsafe rp.refs = 2;
    unsafe rp.state = BS_PENDING;
    unsafe rp.bytes = bytes;
    unsafe rp.body = f;
    let _ = runtime::park_timed(token, 0, commit_submit, rp, true);
    if runtime::cancel_after_wait(true) {
        if !atomic::cas_i32(&mut unsafe rp.state, BS_PENDING, BS_ABANDONED, false, 4, 0) {
            // Completed first: the value is this side's to destroy.
            let vp = (&mut unsafe rp.value) as *mut T;
            vp.free();
        }
        crec_drop::<F, T>(rp);
        runtime::park_done(co);
        runtime::wait_clear();
        return Option::<T>::None;
    }
    let v = unsafe {
        rp.value;
    };
    crec_drop::<F, T>(rp);
    runtime::park_done(co);
    runtime::wait_clear();
    return Option::<T>::Some(v);
}

// --- diagnostics and shutdown -------------------------------------------------------------------------.

/// The pool's counters, all zero when it is not running.
pub fn stats() Stats {
    let mut s = Stats {
        live: 0,
        starting: 0,
        idle: 0,
        queued: 0,
        running: 0,
        peak_threads: 0,
        peak_queued: 0,
        created: 0,
        reaped: 0,
        admit_waits: 0,
        cache_bytes: 0,
    };
    let st = atomic::load_i32((&mut unsafe G_STATE) as *mut i32, 4);
    if st != 2 && st != 3 {
        return s;
    }
    let p = unsafe G_POOL;
    lock(p);
    s.live = unsafe p.live;
    s.starting = unsafe p.starting;
    s.idle = unsafe p.idle;
    s.queued = atomic::load_usize(&mut unsafe p.queued, 0);
    s.running = unsafe p.running;
    s.peak_threads = unsafe p.peak_threads;
    s.peak_queued = unsafe p.peak_queued;
    s.created = unsafe p.created;
    s.reaped = unsafe p.reaped;
    s.admit_waits = unsafe p.admit_waits;
    unlock(p);
    unsafe sc_runtime::sc_rt_spin_lock(&mut p.cache_spin);
    s.cache_bytes = unsafe p.cache_bytes;
    unsafe sc_runtime::sc_rt_spin_unlock(&mut p.cache_spin);
    return s;
}

// Jobs linked and not yet taken. Caller holds the lock.
fn queued_jobs(p: *mut Pool) usize {
    let mut n: usize = 0;
    let mut j = unsafe p.head;
    while j != null {
        n = n + 1;
        j = unsafe j.next;
    }
    return n;
}

/// Close the pool and drain it for up to `grace_ns`. Admission stops at once: a call that arrives from
/// here on, and every caller waiting for admission, runs on its own thread. Accepted work runs to the
/// end; threads exit as the queue empties and announced exits are joined. Nothing is destroyed while work
/// or a thread is outstanding: the report says what remains, the pool stays closed, a late completion
/// still settles its caller, and a later call here finishes the drain. Callable from any thread that is
/// not on the pool. Idempotent; a pool that never started reports released.
pub fn try_shutdown(grace_ns: u64) ShutdownReport {
    let mut r = ShutdownReport { queued: 0, running: 0, threads: 0, released: true };
    let sp = (&mut unsafe G_STATE) as *mut i32;
    let st = atomic::load_i32(sp, 4);
    if st != 2 && st != 3 {
        return r;
    }
    if on_pool_thread() {
        panic("blocking pool: try_shutdown from a pool thread would wait for itself");
    }
    atomic::store_i32(sp, 3, 4);
    let p = unsafe G_POOL;
    let deadline = platform::now_ns() + grace_ns;
    lock(p);
    if unsafe p.shutting == 0 {
        unsafe p.shutting = 1;
        // Idle threads: woken to find the pool closed and exit.
        while unsafe p.idle_head != null {
            let t = pop_idle(p);
            wake_thread(t);
        }
        // Admission waiters: woken to find the pool closed and run their calls themselves.
        let mut a = unsafe p.admit_head;
        unsafe p.admit_head = null;
        unsafe p.admit_tail = null;
        while a != null {
            let nx = unsafe a.next;
            let _ = runtime::wake(unsafe a.co, unsafe a.token);
            a = nx;
        }
        if unsafe p.ext_waiters != 0 {
            let _ = atomic::add_i32(&mut unsafe p.admit_gen, 1, 3);
            unsafe sc_runtime::sc_rt_unpark_all(&mut p.admit_gen);
        }
    }
    loop {
        reap(p);
        if unsafe p.retired != null {
            continue; // retirements landed while the joins ran unlocked
        }
        let left = unsafe p.head != null || unsafe p.running != 0 || unsafe p.live != 0 || unsafe p.starting != 0;
        if !left {
            break;
        }
        let now = platform::now_ns();
        if now >= deadline {
            break;
        }
        let gen = atomic::load_i32(&mut unsafe p.done_gen, 1);
        unlock(p);
        unsafe sc_runtime::sc_rt_park(&mut p.done_gen, gen, (deadline - now) as i64);
        lock(p);
    }
    r.queued = queued_jobs(p);
    r.running = unsafe p.running;
    r.threads = unsafe p.live + unsafe p.starting;
    unlock(p);
    if r.queued != 0 || r.running != 0 || r.threads != 0 {
        r.released = false;
        return r;
    }
    // Every caller that read state 2 has either left the lock or recorded a blocking wait; wait for both
    // counts to clear before the record they may still touch goes away.
    while atomic::load_usize(&mut unsafe G_EXT, 4) != 0 || runtime::tasks_waiting(runtime::WK_BLOCKING) != 0 {
        if platform::now_ns() >= deadline {
            r.released = false;
            return r;
        }
        unsafe sc_runtime::sc_rt_sleep_ns(200000);
    }
    cache_drain(p);
    let mut g = Global {};
    unsafe g.dealloc(p, sizeof(Pool), alignof(Pool));
    unsafe G_POOL = null;
    atomic::store_i32(sp, 0, 4);
    return r;
}

/// Stop the blocking pool and join its threads: `try_shutdown` with `SHUTDOWN_GRACE_NS`. Call it once,
/// from the main thread, after every call has returned, alongside `runtime::shutdown()`. Work still
/// outstanding at the deadline is reported and the process aborts: the pool cannot be released under an
/// unreturned foreign call, and running on without releasing it would hide that.
pub fn shutdown() {
    let r = try_shutdown(SHUTDOWN_GRACE_NS);
    if r.released {
        return;
    }
    eprintln(
        "super-c: blocking pool not released at shutdown: {} call(s) queued, {} running, {} thread(s) outstanding",
        r.queued,
        r.running,
        r.threads,
    );
    unsafe stdlib::abort();
}
