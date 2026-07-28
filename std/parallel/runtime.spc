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

import atomic;
import stdlib;
import sc_runtime;
import std::parallel::platform as platform;

// Leak-tracker backtrace suppression (super_rt.c): a coroutine stack has no clean base frame, so the tracker
// must not unwind it. Brackets each coroutine run slice; a no-op when leak checking is off.
extern "C" {
    fn sc_lk_bt_pause() void;
    fn sc_lk_bt_resume() void;
    // Preemption safepoint hook (super_rt.c): codegen emits a `__sc_safepoint()` at every loop backedge of a
    // program that uses `launch`, and this is what those safepoints call.
    fn __sc_set_preempt_hook(f: fn() void) void;
    // Task attribution (super_rt.c): a panic inside a coroutine names the task it happened in.
    fn __sc_set_task_id(id: u64) void;
}

// Per-coroutine stack. RESERVED, not consumed: the pages behind it are faulted in as the task actually
// uses them, so a shallow task costs a handful of pages however large this is (measured: ~16 KiB per parked
// task at the 256 KiB default). Raising it therefore buys depth, not memory -- see `set_stack_size`.
const STACK_SIZE_DEFAULT: usize = 262144;
static mut G_STACK_SIZE: usize = 262144;

/// A schedulable task: either a stackful coroutine, or (`is_job`) a run-to-completion JOB that the worker
/// simply calls on its own stack -- no stack allocation, no context switch, and no ability to park. Jobs are
/// what the data-parallel API chunks work into, so a million-iteration loop costs a handful of tasks rather
/// than a million stacks.
///
/// `next` links it into the scheduler's run queue; a primitive's wait queue holds a separate per-wait node
/// instead (see `park_begin`), and `tnext` is the timer-list link. `pub` only so task-aware primitives can
/// hold `*mut Coroutine` and wake one -- not a user-facing type.
pub struct Coroutine {
    pub id: u64, // 1-based, unique for the process: what a panic and any diagnostic name it by
    pub ctx: *mut void, // sc_rt saved context (null for a job)
    pub stack: *mut void, // guard-paged stack, usable low end (null for a job)
    pub is_job: i32, // run-to-completion on the worker's own stack; never parks
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

const DEQUE_CAP: usize = 256; // power of two; an overflowing push spills to the injection queue
const BATCH_MAX: usize = 16; // injected tasks moved to a deque per lock -- see `take_injection`
const Y_MAX: i32 = 32; // yields a worker keeps to itself before spilling -- see `yq_push`
const POOL_MAX: i32 = 256; // recycled task blocks kept alive -- see `pool_put`
const SPIN_MAX: i32 = 2048; // the spinner's look-again budget before it parks -- see `dequeue_runnable`
// A non-spinner's budget. Spinning costs a core and saves a wake-up syscall, so this is a real trade: at 64
// a cheap-task fan-out spent most of its time waking threads, and at 4096 the spinners stole cores from
// tasks that had actual work to do. 512 measured best across both shapes.
const SPIN_IDLE: i32 = 512;
const LINE: usize = 128; // cache line, and so the stride between two workers -- see `Worker.pad`

static_assert(sizeof(Worker) == LINE, "Worker must be exactly one cache line: adjust its padding");

/// One worker's run deque (Chase-Lev): its owner pushes and pops the BOTTOM, thieves steal the TOP, and the
/// two only contend over the last element -- so the common case takes no lock at all. Fixed capacity, which
/// is what keeps it simple: a push that would overflow spills into the shared injection queue instead of
/// growing the buffer under the thieves' feet.
pub struct Worker {
    pub buf: *mut *mut Coroutine, // DEQUE_CAP slots, indexed modulo the capacity
    pub top: usize, // atomic: next slot a thief takes
    pub bottom: usize, // atomic: next free slot for the owner
    pub rng: u64, // xorshift state for victim selection
    pub tick: u32, // dequeue counter: every so often the injection queue is polled first (fairness)
    pub idx: usize, // this worker's index, so a thread can be started from its slot alone
    pub sched: *mut Scheduler,
    pub yhead: *mut Coroutine, // yielded here, oldest first: taken only once the deque is empty
    pub ytail: *mut Coroutine,
    pub ylen: i32, // beyond Y_MAX a yield spills to the injection queue -- see `yq_push`
    // Padding to a whole cache line. Workers live in one array, so without it two of them share a line:
    // every push moves `bottom` and every steal moves `top`, and a store to either invalidates the
    // neighbour's copy of both. Worth ~25% on a yield-heavy fan-out across fourteen workers, which is the
    // shape that moves these two fields hardest. 128 bytes because that is the line on Apple silicon; on a
    // 64-byte machine it is simply two lines per worker.
    pub pad: Array<u64, 6>,
}

/// Where one worker sleeps: its own mutex and condvar, so waking it is an UNCONTENDED lock plus one signal.
/// A single pool-wide condvar meant the submitter's wake had to queue behind every worker parking and
/// unparking through the same mutex, and on macOS a contended pthread mutex is two syscalls -- that queue
/// was most of what submitting a task cost at fourteen workers. `notified` is the predicate, so a signal
/// that lands before the wait is not lost. Line-padded: a worker being woken must not invalidate the
/// neighbour's line.
pub struct Parker {
    pub mtx: *mut void,
    pub cv: *mut void,
    pub notified: i32, // set by whoever wakes this worker; cleared by the worker before it sleeps
    pub pad: Array<u64, 13>,
}

/// The shared pool. Fields are `pub` only for the caller-monomorphized `launch` / task-aware primitives.
pub struct Scheduler {
    pub deques: *mut Worker, // one per worker thread
    pub nw: usize,
    pub inj_head: *mut Coroutine, // injection queue: submissions from off-pool threads, and deque spill
    pub inj_tail: *mut Coroutine,
    pub inj_len: i32, // atomic: injected-and-not-yet-taken, so a safepoint can ask "is anyone waiting?"
    pub inj_lock: i32, // spinlock over the three fields above -- see the queue section
    pub timer_head: *mut Coroutine, // sleeping coroutines, earliest deadline first
    pub timer_len: i32, // atomic: so a worker with no timers armed never takes `lock` to find that out
    pub lock: *mut void, // guards the timer list and shutting_down
    pub parkers: *mut Parker, // one per worker: where it sleeps, and how it is woken
    pub idle: *mut u64, // atomic bitmask, one bit per worker: set = parked and waiting to be woken
    pub idle_words: usize, // (nw + 63) / 64, so the mask is not capped at 64 workers
    pub spinning: i32, // atomic: a worker is looking for work right now -- see `dequeue_runnable`
    pub workers: Vector<*mut void>,
    pub shutting_down: i32,
    pub free_head: *mut Coroutine, // recycled task blocks, linked through `next` -- see `pool_take`
    pub free_len: i32, // atomic: how many, so the fast path can skip the lock
    pub free_spin: i32, // its own spinlock: recycling must not serialise against the run queue
}

// The single global pool, guarded by a 0=uninit / 1=building / 2=ready init state machine.
static mut G_STATE: i32 = 0;
static mut G_SCHED: *mut Scheduler = null;
static mut G_NWORKERS: usize = 0; // 0 = one worker per CPU
static mut G_NEXT_ID: u64 = 0; // atomic: task-id source, and so also the count of tasks ever created
static mut G_DONE: usize = 0; // atomic: tasks that ran to completion

static mut G_TRACE: i32 = 0; // 0 unknown / 1 off / 2 on

/// Is task tracing on? `SC_TASK_TRACE=1` turns it on for the life of the process; the answer is read from
/// the environment once and then costs a load and a compare, so a traced build and an untraced one are the
/// same binary. `pub` because the channel traces through it too.
pub fn tracing() bool {
    if G_TRACE == 0 {
        G_TRACE = if stdlib::getenv("SC_TASK_TRACE") == null {
            1;
        } else {
            2;
        };
    }
    return G_TRACE == 2;
}

/// One trace line: what happened, and to which task. Check `tracing()` first on a hot path.
pub fn trace(event: str, id: u64) {
    eprintln("[task {}] {}", id, event);
}

// The commit hand-off for a park with nothing to release (e.g. `sleep`).
fn commit_nop(_p: *mut void) {}

// A fresh task id. Ids are handed out in order and never reused, so the counter is also the number of tasks
// ever created -- one contended increment per task rather than two for the same pair of facts.
fn next_task_id() u64 {
    return atomic::add_u64(&mut G_NEXT_ID, 1, 0) + 1;
}

// Claim the right to resume the park identified by `token`: succeeds once, for one waker, and only while
// that exact park is still current. A registration left behind by an expired timed wait therefore cannot
// resume a LATER park -- which would run a coroutine that never actually acquired what it waited for.
fn claim(co: *mut Coroutine, token: u32) bool {
    let p = &mut unsafe co.park_state;
    return atomic::cas_u32(p, token, token + 1, false, 4, 0); // SeqCst on success, Relaxed on failure
}

// Memory-order codes for the atomic builtins: 0 Relaxed, 1 Acquire, 2 Release, 3 AcqRel, 4 SeqCst.

// --- Chase-Lev deque -----------------------------------------------------------------------------------
// Only the owning worker calls push/pop; any thread may call steal. The orders below are the published
// algorithm's: the owner's Release store of `bottom` publishes the slot it just wrote, a thief's Acquire
// load of `bottom` reads it, and the SeqCst fences plus the CAS on `top` settle the one case they can
// collide -- a deque holding exactly one task.

fn dq_top(w: *mut Worker) *mut usize {
    return &mut unsafe w.top;
}

fn dq_bottom(w: *mut Worker) *mut usize {
    return &mut unsafe w.bottom;
}

// Owner: append to the bottom. False when the deque is full (the caller spills to the injection queue).
fn dq_push(w: *mut Worker, co: *mut Coroutine) bool {
    let b = atomic::load_usize(dq_bottom(w), 0);
    let t = atomic::load_usize(dq_top(w), 1);
    if b - t >= DEQUE_CAP {
        return false;
    }
    unsafe w.buf[b % DEQUE_CAP] = co;
    atomic::store_usize(dq_bottom(w), b + 1, 2); // Release: publishes the slot
    return true;
}

// Owner: take from the bottom (LIFO, so the freshest task keeps its cache warm). Null when empty, or when
// a thief won the race for the last task.
fn dq_pop(w: *mut Worker) *mut Coroutine {
    let b0 = atomic::load_usize(dq_bottom(w), 0);
    let t0 = atomic::load_usize(dq_top(w), 1);
    if b0 == t0 {
        return null;
    }
    let b = b0 - 1;
    atomic::store_usize(dq_bottom(w), b, 0);
    atomic::fence(4); // SeqCst: order our claim against a concurrent steal
    let t = atomic::load_usize(dq_top(w), 0);
    if t > b {
        atomic::store_usize(dq_bottom(w), b + 1, 0); // a thief took it; restore
        return null;
    }
    let co = unsafe w.buf[b % DEQUE_CAP];
    if t == b {
        // Last task: a thief may be claiming this very slot, so settle it with the CAS.
        let won = atomic::cas_usize(dq_top(w), t, t + 1, false, 4, 0);
        atomic::store_usize(dq_bottom(w), b + 1, 0);
        if !won {
            return null;
        }
    }
    return co;
}

// Any thread: take from the top (FIFO, so a thief gets the OLDEST task -- the one least likely to be hot in
// the victim's cache, and most likely to have its own work to spawn).
fn dq_steal(w: *mut Worker) *mut Coroutine {
    // Probe first, unfenced: an idle worker asks every deque in the pool whether it has anything, over and
    // over, and almost always the answer is no. Paying a full barrier for that answer costs more than the
    // answer is worth -- and a spuriously empty reading is a steal that fails, which callers already handle.
    if atomic::load_usize(dq_top(w), 0) >= atomic::load_usize(dq_bottom(w), 0) {
        return null;
    }
    let t = atomic::load_usize(dq_top(w), 1);
    atomic::fence(4);
    let b = atomic::load_usize(dq_bottom(w), 1);
    if t >= b {
        return null;
    }
    let co = unsafe w.buf[t % DEQUE_CAP];
    if !atomic::cas_usize(dq_top(w), t, t + 1, false, 4, 0) {
        return null; // lost to the owner or another thief; the caller moves on to the next victim
    }
    return co;
}

fn dq_empty(w: *mut Worker) bool {
    return atomic::load_usize(dq_bottom(w), 1) == atomic::load_usize(dq_top(w), 1);
}

// --- the owner's yield queue ---------------------------------------------------------------------------
// A yield means "let somebody else go first", and the local deque is LIFO -- pushed there, the yielder is
// the very next task popped. It used to go to the shared queue instead, which is correct but costs a mutex
// and a condvar signal on EVERY yield; at fourteen workers that lock was most of what a yield cost. This
// queue is the somebody-else-first order kept locally: only the owning worker touches it, so it needs no
// synchronisation at all, and `dequeue_runnable` drains it once the deque is empty.
//
// The one thing a private queue cannot do is let an idle worker steal from it, so it is bounded: past
// `Y_MAX` a yield goes back to the shared queue, where anyone can take it.

fn yq_push(w: *mut Worker, co: *mut Coroutine) bool {
    if unsafe w.ylen >= Y_MAX {
        return false;
    }
    unsafe co.next = null;
    if unsafe w.ytail == null {
        unsafe w.yhead = co;
    } else {
        unsafe w.ytail.next = co;
    }
    unsafe w.ytail = co;
    unsafe w.ylen = unsafe w.ylen + 1;
    return true;
}

fn yq_pop(w: *mut Worker) *mut Coroutine {
    let co = unsafe w.yhead;
    if co == null {
        return null;
    }
    unsafe w.yhead = unsafe co.next;
    if unsafe w.yhead == null {
        unsafe w.ytail = null;
    }
    unsafe co.next = null;
    unsafe w.ylen = unsafe w.ylen - 1;
    return co;
}

// --- queues --------------------------------------------------------------------------------------------
// The injection queue is under `qlock`, a SPINLOCK, and not under the scheduler's mutex. Every task
// submitted from off the pool crosses it, and a contended pthread mutex on macOS is two syscalls -- with
// fourteen workers pulling against one submitter, that mutex was over 90% of what a fan-out cost. What it
// guards is a handful of pointer stores, so a spin is the right wait.
//
// `lock`/`cv` still cover the timer list and the sleep protocol, where a worker really does have to block.
// A holder of `lock` may take `qlock` (`promote_expired` does); the reverse never happens -- a pusher
// releases `qlock` before `signal_work` touches `lock` -- so the two can never deadlock.

fn qlock(s: *mut Scheduler) {
    unsafe sc_runtime::sc_rt_spin_lock(&mut s.inj_lock);
}

fn qunlock(s: *mut Scheduler) {
    unsafe sc_runtime::sc_rt_spin_unlock(&mut s.inj_lock);
}

// Append `co` to the injection queue. Caller holds `qlock`.
fn push_injection(s: *mut Scheduler, co: *mut Coroutine) {
    unsafe co.next = null;
    let _ = atomic::add_i32(&mut unsafe s.inj_len, 1, 2);
    if unsafe s.inj_tail == null {
        unsafe s.inj_head = co;
    } else {
        unsafe s.inj_tail.next = co;
    }
    unsafe s.inj_tail = co;
}

// Take the oldest injected task. Caller holds `qlock`.
fn pop_injection(s: *mut Scheduler) *mut Coroutine {
    let co = unsafe s.inj_head;
    if co == null {
        return null;
    }
    unsafe s.inj_head = unsafe co.next;
    if unsafe s.inj_head == null {
        unsafe s.inj_tail = null;
    }
    unsafe co.next = null;
    let _ = atomic::sub_i32(&mut unsafe s.inj_len, 1, 2);
    return co;
}

// Take one injected task to run now, and move a share of what is left onto this worker's own deque -- so
// the next few dequeues cost no lock at all. A fan-out submits from one thread, and taking those tasks back
// one acquisition at a time is what serialises the whole pool behind the submitter. Takes `qlock` itself.
fn take_injection(s: *mut Scheduler, w: *mut Worker) *mut Coroutine {
    if atomic::load_i32(&mut unsafe s.inj_len, 1) == 0 {
        return null; // the usual answer, and it costs one load rather than a lock
    }
    qlock(s);
    let co = pop_injection(s);
    if co == null {
        qunlock(s);
        return null;
    }
    // A share, not the lot: leaving the rest shared is what lets a worker that is still busy catch up.
    let mut n = atomic::load_i32(&mut unsafe s.inj_len, 0) as usize / unsafe s.nw;
    if n > BATCH_MAX {
        n = BATCH_MAX;
    }
    for _k in 0..n {
        let x = pop_injection(s);
        if x == null {
            break;
        }
        if !dq_push(w, x) {
            push_injection(s, x); // deque full: back where it came from, and stop
            break;
        }
    }
    qunlock(s);
    return co;
}

// Push `co` onto the shared queue and wake somebody if anybody is asleep. Takes `qlock`, and the mutex only
// when there is actually a worker to signal.
fn inject(s: *mut Scheduler, co: *mut Coroutine) {
    qlock(s);
    push_injection(s, co);
    qunlock(s);
    signal_work(s);
}

// Claim one parked worker out of the idle mask, or -1 if none is parked. Claiming is what stops a burst of
// submissions from spending a signal each on the same worker: the bit is cleared before the wake is sent, so
// the next submitter looks past it to a worker that is still asleep.
fn claim_idle(s: *mut Scheduler) i64 {
    for wi in 0..unsafe s.idle_words {
        let word = unsafe (s.idle + wi);
        loop {
            let cur = atomic::load_u64(word, 1);
            if cur == 0 {
                break; // nobody parked in this word; try the next
            }
            let bit = cur & 0 - cur; // lowest set bit
            if atomic::cas_u64(word, cur, cur ^ bit, false, 4, 0) {
                let mut idx: usize = 0;
                let mut probe = bit;
                while probe > 1 {
                    probe = probe >> 1;
                    idx = idx + 1;
                }
                return (wi * 64 + idx) as i64;
            }
        }
    }
    return -1;
}

// Wake one specific parked worker. Its mutex is its own, so this is an uncontended lock, a store and one
// signal -- no queueing behind the rest of the pool.
fn wake_parked(s: *mut Scheduler, idx: usize) {
    let pk = unsafe (s.parkers + idx);
    unsafe sc_runtime::sc_rt_mutex_lock(pk.mtx);
    unsafe pk.notified = 1;
    unsafe sc_runtime::sc_rt_cond_signal(pk.cv);
    unsafe sc_runtime::sc_rt_mutex_unlock(pk.mtx);
}

// Wake one idle worker, if one is parked at all. Deliberately touches no lock unless it has to: the mask
// read is paired with the re-look in `dequeue_runnable`, so a worker that parks between our push and this
// read finds the task itself rather than sleeping through it.
fn signal_work(s: *mut Scheduler) {
    atomic::fence(4);
    // A worker already looking for work will find this one without a syscall, which is the whole point of
    // keeping one awake. If it parks instead, it clears this flag BEFORE it joins the idle mask, and the
    // re-look it does after joining is what catches a task pushed in between.
    if atomic::load_i32(&mut unsafe s.spinning, 4) != 0 {
        return;
    }
    let idx = claim_idle(s);
    if idx >= 0 {
        wake_parked(s, idx as usize);
    }
}

// Make `co` runnable. From a worker thread it goes on that worker's own deque -- no lock, and the task stays
// where its data is warm; from anywhere else (or a full deque) it goes to the injection queue.
fn enqueue_runnable(s: *mut Scheduler, co: *mut Coroutine) {
    let wi = unsafe sc_runtime::sc_rt_widx_get();
    if wi >= 0 && wi as usize < unsafe s.nw {
        let w = unsafe (s.deques + wi as usize);
        if dq_push(w, co) {
            signal_work(s);
            return;
        }
    }
    inject(s, co);
}

// Link `co` into the deadline-sorted timer list. Caller holds `(*s).lock` and passes the deadline it read
// before this coroutine became visible to any waker (`co.deadline` is the coroutine's to overwrite).
fn arm_timer(s: *mut Scheduler, co: *mut Coroutine, dl: u64) {
    let mut prev: *mut Coroutine = null;
    let mut cur = unsafe s.timer_head;
    while cur != null && unsafe cur.deadline <= dl {
        prev = cur;
        cur = unsafe cur.tnext;
    }
    unsafe co.tnext = cur;
    if prev == null {
        unsafe s.timer_head = co;
    } else {
        unsafe prev.tnext = co;
    }
    unsafe co.timed = 1;
    atomic::store_i32(&mut unsafe s.timer_len, unsafe s.timer_len + 1, 2);
    // A nearer deadline shortens the wait of whichever worker is idle, so one has to re-evaluate.
    let idx = claim_idle(s);
    if idx >= 0 {
        wake_parked(s, idx as usize);
    }
}

// Unlink `co` from the timer list if it is still on it. Caller holds `(*s).lock`.
fn disarm_timer(s: *mut Scheduler, co: *mut Coroutine) {
    if unsafe co.timed == 0 {
        return;
    }
    let mut prev: *mut Coroutine = null;
    let mut cur = unsafe s.timer_head;
    while cur != null && cur != co {
        prev = cur;
        cur = unsafe cur.tnext;
    }
    if cur == co {
        if prev == null {
            unsafe s.timer_head = unsafe co.tnext;
        } else {
            unsafe prev.tnext = unsafe co.tnext;
        }
    }
    unsafe co.tnext = null;
    unsafe co.timed = 0;
    atomic::store_i32(&mut unsafe s.timer_len, unsafe s.timer_len - 1, 2);
}

// Make every coroutine whose deadline has passed runnable, and report whether any did. Caller holds
// `(*s).lock`. A coroutine already claimed (notified just before its deadline) is only unlinked -- its waker
// is resuming it, so it counts as promoted by somebody.
fn promote_expired(s: *mut Scheduler) bool {
    if atomic::load_i32(&mut unsafe s.timer_len, 1) == 0 {
        return false; // the usual case: a program with no `sleep` in it never pays for the timer list
    }
    let mut any = false;
    let now = platform::now_ns();
    while unsafe s.timer_head != null && unsafe s.timer_head.deadline <= now {
        let co = unsafe s.timer_head;
        unsafe s.timer_head = unsafe co.tnext;
        unsafe co.tnext = null;
        unsafe co.timed = 0;
        atomic::store_i32(&mut unsafe s.timer_len, unsafe s.timer_len - 1, 2);
        any = true;
        if claim(co, unsafe co.tm_token) {
            qlock(s); // `lock` then `qlock` is the one nesting order the two are ever taken in
            push_injection(s, co);
            qunlock(s);
        }
    }
    return any;
}

// Pick a victim at random and try every deque once. Random start, not round-robin: with several idle
// workers a fixed order makes them all converge on the same victim.
fn steal_any(s: *mut Scheduler, me: usize) *mut Coroutine {
    let nw = unsafe s.nw;
    if nw < 2 {
        return null;
    }
    let w = unsafe (s.deques + me);
    let mut r = unsafe w.rng; // xorshift64
    r = r ^ r << 13;
    r = r ^ r >> 7;
    r = r ^ r << 17;
    unsafe w.rng = r;
    let start = (r % nw as u64) as usize;
    for k in 0..nw {
        let v = (start + k) % nw;
        if v == me {
            continue;
        }
        let co = dq_steal(unsafe (s.deques + v));
        if co != null {
            if tracing() {
                trace("stolen", unsafe co.id);
            }
            return co;
        }
    }
    return null;
}

fn all_deques_empty(s: *mut Scheduler) bool {
    for i in 0..unsafe s.nw {
        if !dq_empty(unsafe (s.deques + i)) {
            return false;
        }
    }
    return true;
}

// Every source of work, in order of what it costs to look: this worker's own deque (no lock, LIFO, so the
// freshest task keeps its cache warm), then what it yielded, then the injection queue, then a steal.
//
// `shared` is false for a worker that is only filling in time before it parks. The injection queue is the
// one source behind a lock, and every idle worker racing for it the instant a task lands there turns a
// single submitter into a fourteen-way collision -- so only the spinner (and a worker on its first look
// after running something) goes near it. Everyone else finds work by stealing, which needs no lock.
fn find_work(s: *mut Scheduler, w: *mut Worker, me: usize, shared: bool) *mut Coroutine {
    if shared {
        // Every so often, look at the shared queue FIRST: a worker that keeps spawning local work would
        // otherwise never come back for anything submitted from off the pool.
        let t = unsafe w.tick + 1;
        unsafe w.tick = t;
        if t % 61 == 0 {
            let first = take_injection(s, w);
            if first != null {
                return first;
            }
        }
    }
    let local = dq_pop(w);
    if local != null {
        return local; // the hot path takes no lock at all
    }
    let yielded = yq_pop(w); // after the deque: a task that yielded asked to go behind fresh work
    if yielded != null {
        return yielded;
    }
    if shared {
        let injected = take_injection(s, w); // a spinlock at worst, one load when the queue is empty
        if injected != null {
            return injected;
        }
    }
    return steal_any(s, me);
}

// The next task for worker `me`, or null once shut down and every source is drained.
//
// A worker that finds nothing does not park straight away: it SPINS, and the pool keeps at most one spinner.
// That single flag is what makes a burst of submissions cost one wake-up instead of one per task -- a
// submitter that sees a spinner issues no signal at all, because the spinner will pick the task up without
// ever entering the kernel, and a condvar signal here is two syscalls and several microseconds. More than
// one spinner would only burn cores, so the spinner hands the duty on (by waking a replacement) exactly when
// it finds work AND there is more left to take: with the queue drained, another worker would wake to nothing.
fn dequeue_runnable(s: *mut Scheduler, me: usize) *mut Coroutine {
    let w = unsafe (s.deques + me);
    let mut spins: i32 = 0; // a fresh budget per call: a worker that just ran something expects more
    let mut spinning = false; // do we hold `s.spinning`?
    loop {
        // The shared queue is worth a look on the first try of every call (this worker has just finished
        // something, so it is the natural next taker) and for as long as we are the spinner. Not otherwise.
        let co = find_work(s, w, me, spinning || spins == 0);
        if co != null {
            if spinning {
                atomic::store_i32(&mut unsafe s.spinning, 0, 2);
                if atomic::load_i32(&mut unsafe s.inj_len, 1) > 0 {
                    signal_work(s); // work left over: somebody else should be awake for it
                }
            }
            return co;
        }
        if !spinning && spins == 0 {
            spinning = atomic::cas_i32(&mut unsafe s.spinning, 0, 1, false, 4, 0);
        }
        // The spinner waits long enough to cover a wake-up it is there to avoid; anyone else gives up almost
        // at once, since a second spinner buys nothing.
        let budget = if spinning {
            SPIN_MAX;
        } else {
            SPIN_IDLE;
        };
        if spins < budget {
            spins = spins + 1;
            unsafe sc_runtime::sc_rt_cpu_relax();
            continue;
        }
        unsafe sc_runtime::sc_rt_mutex_lock(s.lock);
        // Give the spin flag up BEFORE registering as sleeping: a submitter that sees it set issues no
        // signal, so leaving it set across the park would lose the wakeup outright.
        if spinning {
            atomic::store_i32(&mut unsafe s.spinning, 0, 2);
            spinning = false;
        }
        // A due timer is the only source of work left that needs this mutex, and we are holding it anyway.
        // Doing it here rather than round the loop is what keeps an armed-but-distant deadline from putting
        // every idle worker through the mutex on every spin iteration.
        if promote_expired(s) {
            spins = 0;
            unsafe sc_runtime::sc_rt_mutex_unlock(s.lock);
            continue;
        }
        // Shutting down drains: workers keep going until every deque, the injection queue AND every pending
        // timer is empty, so no submitted or sleeping task is silently dropped (one still parked on a wait
        // queue is, since nothing will ever wake it).
        if unsafe s.shutting_down != 0 {
            let drained = unsafe s.timer_head == null && atomic::load_i32(&mut unsafe s.inj_len, 1) == 0 && all_deques_empty(
                s,
            );
            if drained {
                unsafe sc_runtime::sc_rt_mutex_unlock(s.lock);
                return null;
            }
        }
        // The nearest deadline, read while we still hold the timer lock, decides whether this is a timed
        // park; then the scheduler mutex is dropped entirely. Parking happens on this worker's OWN mutex, so
        // a submitter waking us never has to queue behind the rest of the pool.
        let dl = if unsafe s.timer_head != null {
            unsafe s.timer_head.deadline;
        } else {
            0u64;
        };
        unsafe sc_runtime::sc_rt_mutex_unlock(s.lock);

        let pk = unsafe (s.parkers + me);
        unsafe sc_runtime::sc_rt_mutex_lock(pk.mtx);
        unsafe pk.notified = 0;
        // Join the idle mask, THEN look once more. A submitter reads the mask after its push, so if it read
        // us as awake its task is already visible to this look -- one of the two always sees the other.
        //
        // A LOOK, not a scan: the only push this races with is one from off the pool, which lands on the
        // injection queue (a worker's own push goes to its own deque, and that worker is awake by
        // definition). Stealing, batching and timers all happen back at the top of the loop, holding nothing.
        let word = unsafe (s.idle + me / 64);
        let bit = 1u64 << (me % 64) as u64;
        let _ = atomic::or_u64(word, bit, 4);
        atomic::fence(4);
        let due = dl != 0 && dl <= platform::now_ns();
        if atomic::load_i32(&mut unsafe s.inj_len, 1) > 0 || due {
            let _ = atomic::and_u64(word, ~bit, 4); // leave the mask; a claimed bit is already gone
            unsafe sc_runtime::sc_rt_mutex_unlock(pk.mtx);
            spins = 0; // there is something after all: look properly, shared queue included
            continue;
        }
        while unsafe pk.notified == 0 {
            if dl != 0 {
                let now = platform::now_ns();
                let rel = if dl > now {
                    (dl - now) as i64;
                } else {
                    0i64;
                };
                let _ = unsafe sc_runtime::sc_rt_cond_timedwait_ns(pk.cv, pk.mtx, rel);
                break; // a deadline to service: go round and promote it
            }
            unsafe sc_runtime::sc_rt_cond_wait(pk.cv, pk.mtx);
        }
        // Whoever woke us already cleared our bit; a timeout did not, so clear it either way.
        let _ = atomic::and_u64(word, ~bit, 4);
        unsafe sc_runtime::sc_rt_mutex_unlock(pk.mtx);
        spins = 0; // woken means work: earn the spin budget back rather than parking straight away
    }
}

// The coroutine body trampoline: run the closure (which frees its own box), mark done, return to scheduler.
fn coroutine_start(arg: *mut void) {
    let co = arg as *mut Coroutine;
    let e = unsafe co.entry;
    e(unsafe co.env);
    unsafe co.done = 1;
    unsafe sc_runtime::sc_rt_ctx_switch(co.ctx, co.sched_ctx);
}

// --- the task-block pool -------------------------------------------------------------------------------
// A task block is a `Coroutine` together with the stack and context handle it owns, and building one is by
// far the most expensive thing about spawning: the stack is a fresh mmap plus an mprotect for its guard
// page, and releasing it is a munmap -- which, with several worker threads live, also costs every core a
// TLB shootdown. Recycling the whole block makes a spawn a pop and a few stores, and reuses pages that are
// already faulted in. The block is inert once its coroutine is done, so nothing about it needs resetting
// beyond the fields `spawn_coroutine` writes (`inited: 0` re-forges the entry frame on the next run).
//
// Bounded, because these are the runtime's largest allocations: past `POOL_MAX` a block is really freed.
// `shutdown` drains what is left, so an unused pool costs nothing once the program stops launching tasks.

fn pool_take(s: *mut Scheduler) *mut Coroutine {
    if atomic::load_i32(&mut unsafe s.free_len, 1) <= 0 {
        return null;
    }
    unsafe sc_runtime::sc_rt_spin_lock(&mut s.free_spin);
    let co = unsafe s.free_head;
    if co != null {
        unsafe s.free_head = unsafe co.next;
        let _ = atomic::sub_i32(&mut unsafe s.free_len, 1, 0);
    }
    unsafe sc_runtime::sc_rt_spin_unlock(&mut s.free_spin);
    return co;
}

fn pool_put(s: *mut Scheduler, co: *mut Coroutine) bool {
    if atomic::load_i32(&mut unsafe s.free_len, 1) >= POOL_MAX {
        return false;
    }
    unsafe sc_runtime::sc_rt_spin_lock(&mut s.free_spin);
    unsafe co.next = unsafe s.free_head;
    unsafe s.free_head = co;
    let _ = atomic::add_i32(&mut unsafe s.free_len, 1, 0);
    unsafe sc_runtime::sc_rt_spin_unlock(&mut s.free_spin);
    return true;
}

fn release_block(co: *mut Coroutine) {
    unsafe sc_runtime::sc_rt_stack_free(co.stack, G_STACK_SIZE);
    unsafe sc_runtime::sc_rt_ctx_free(co.ctx);
    let mut g = Global {};
    g.dealloc(co, sizeof(Coroutine), alignof(Coroutine));
}

// Everything the pool is holding. Called from `shutdown`, after the workers have been joined.
fn pool_drain(s: *mut Scheduler) {
    let mut co = unsafe s.free_head;
    while co != null {
        let nxt = unsafe co.next;
        release_block(co);
        co = nxt;
    }
    unsafe s.free_head = null;
    unsafe s.free_len = 0;
}

fn free_coroutine(s: *mut Scheduler, co: *mut Coroutine) {
    if pool_put(s, co) {
        return;
    }
    release_block(co);
}

// The C-ABI worker: run/resume coroutines, honouring each one's park (unlock) or yield (requeue) hand-off
// AFTER its context has been fully saved -- so a woken coroutine can never be resumed while still switching.
fn worker_main(arg: *mut void) *mut void {
    let w = arg as *mut Worker;
    let s = unsafe w.sched;
    let me = unsafe w.idx;
    unsafe sc_runtime::sc_rt_widx_set(me as i32); // a push from this thread lands on this deque
    unsafe sc_runtime::sc_rt_stack_guard_install(); // report an overflow rather than dying on a bare fault
    unsafe sc_runtime::sc_rt_stack_note_size(G_STACK_SIZE);
    let sched_ctx = unsafe sc_runtime::sc_rt_ctx_alloc();
    loop {
        let co = dequeue_runnable(s, me);
        if co == null {
            break;
        }
        if unsafe co.is_job != 0 {
            // A job runs to completion right here, on the worker's own stack: no context, no switch, and
            // `current()` reports null so anything it waits on blocks this thread instead of parking.
            let je = unsafe co.entry;
            unsafe sc_runtime::sc_rt_tls_set(co);
            unsafe __sc_set_task_id(co.id);
            je(unsafe co.env);
            unsafe __sc_set_task_id(0);
            unsafe sc_runtime::sc_rt_tls_set(null);
            let mut gj = Global {};
            gj.dealloc(co, sizeof(Coroutine), alignof(Coroutine));
            let _ = atomic::add_usize(&mut G_DONE, 1, 0);
            continue;
        }
        unsafe co.sched_ctx = sched_ctx;
        if unsafe co.inited == 0 {
            // Arm the context on the worker that first runs it, not at spawn: arming writes the initial
            // frame to the coroutine's own stack, so a task that is queued but never reached never faults
            // a page of it in.
            unsafe sc_runtime::sc_rt_ctx_init(co.ctx, co.stack, G_STACK_SIZE, coroutine_start, co);
            unsafe co.inited = 1;
        }
        unsafe sc_runtime::sc_rt_tls_set(co);
        unsafe __sc_set_task_id(co.id);
        unsafe sc_lk_bt_pause(); // the leak tracker must not unwind the coroutine's stack
        unsafe sc_runtime::sc_rt_ctx_switch(sched_ctx, co.ctx);
        unsafe sc_lk_bt_resume();
        unsafe __sc_set_task_id(0);
        unsafe sc_runtime::sc_rt_tls_set(null);
        if unsafe co.done != 0 {
            if tracing() {
                trace("complete", unsafe co.id);
            }
            free_coroutine(s, co);
            let _ = atomic::add_usize(&mut G_DONE, 1, 0);
        } else if unsafe co.commit_requeue != 0 {
            unsafe co.commit_requeue = 0;
            if !yq_push(w, co) {
                inject(s, co); // this worker is hoarding yields: share them out again
            }
        } else {
            // Parked. Take the hand-off FIRST: arming the timer already publishes this coroutine, and a
            // deadline that has already passed lets another worker resume it -- and park it again, rewriting
            // these very fields -- before we get to them.
            let commit = unsafe co.commit_fn;
            let arg = unsafe co.commit_arg;
            let dl = unsafe co.deadline;
            // Then arm its timer (if the wait was timed) and only last release the lock that kept its waker
            // out: by now its context is fully saved, so any waker may resume it.
            if dl != 0 {
                unsafe sc_runtime::sc_rt_mutex_lock(s.lock);
                arm_timer(s, co, dl);
                unsafe sc_runtime::sc_rt_mutex_unlock(s.lock);
            }
            commit(arg);
        }
    }
    unsafe sc_runtime::sc_rt_ctx_free(sched_ctx);
    unsafe sc_runtime::sc_rt_widx_set(-1);
    return null;
}

fn build_scheduler() *mut Scheduler {
    let mut g = Global {};
    let s = g.alloc(sizeof(Scheduler), alignof(Scheduler)) as *mut Scheduler;
    let lk = unsafe sc_runtime::sc_rt_mutex_new();
    let nw = if G_NWORKERS > 0 {
        G_NWORKERS;
    } else {
        platform::ncpu();
    };
    let deques = g.alloc(nw * sizeof(Worker), LINE) as *mut Worker; // line-aligned: see Worker.pad
    let parkers = g.alloc(nw * sizeof(Parker), LINE) as *mut Parker;
    let words = (nw + 63) / 64;
    let idle = g.alloc(words * sizeof(u64), alignof(u64)) as *mut u64;
    for i in 0..words {
        unsafe idle[i] = 0;
    }
    for i in 0..nw {
        unsafe parkers[i] = Parker {
            mtx: unsafe sc_runtime::sc_rt_mutex_new(),
            cv: unsafe sc_runtime::sc_rt_cond_new(),
            notified: 0,
            pad: Array::<u64, 13>::new(),
        };
    }
    unsafe s[0] = Scheduler {
        deques: deques,
        nw: nw,
        inj_head: null,
        inj_tail: null,
        inj_len: 0,
        inj_lock: 0,
        timer_head: null,
        timer_len: 0,
        lock: lk,
        parkers: parkers,
        idle: idle,
        idle_words: words,
        spinning: 0,
        workers: Vector::<*mut void>::new(),
        shutting_down: 0,
        free_head: null,
        free_len: 0,
        free_spin: 0,
    };
    for i in 0..nw {
        let buf = g.alloc(DEQUE_CAP * sizeof(*mut Coroutine), alignof(*mut Coroutine)) as *mut *mut Coroutine;
        // Seed each victim-choice generator differently and never with zero, or xorshift stays at zero.
        let seed = 0x9e3779b97f4a7c15 + (i as u64 + 1) * 0x632be59bd9b4e019;
        unsafe deques[i] = Worker {
            buf: buf,
            top: 0,
            bottom: 0,
            rng: seed,
            tick: 0,
            idx: i,
            sched: s,
            yhead: null,
            ytail: null,
            ylen: 0,
            pad: Array::<u64, 6>::new(),
        };
    }
    // Before any worker exists, so every safepoint's read of the hook happens-after this write.
    unsafe __sc_set_preempt_hook(preempt_yield);
    for i in 0..nw {
        let mut h: *mut void = null;
        let _ = unsafe sc_runtime::sc_rt_thread_create(&mut h, worker_main, unsafe (deques + i));
        unsafe s.workers.push(h);
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
    // A recycled block brings its stack and context with it; only a cold spawn pays for an mmap. Its park
    // generation comes with it too, and deliberately does not restart: a token left over from the block's
    // previous life must stay behind the current one, or it could claim the task now using the block.
    let mut co = pool_take(s);
    let mut stk: *mut void = null;
    let mut ctx: *mut void = null;
    let mut pst: u32 = 0;
    if co == null {
        let mut g = Global {};
        co = g.alloc(sizeof(Coroutine), alignof(Coroutine)) as *mut Coroutine;
        stk = unsafe sc_runtime::sc_rt_stack_alloc(G_STACK_SIZE);
        ctx = unsafe sc_runtime::sc_rt_ctx_alloc();
    } else {
        stk = unsafe co.stack;
        ctx = unsafe co.ctx;
        pst = unsafe co.park_state;
    }
    unsafe co[0] = Coroutine {
        id: next_task_id(),
        ctx: ctx,
        stack: stk,
        is_job: 0,
        entry: entry,
        env: env,
        done: 0,
        sched_ctx: null,
        next: null,
        commit_fn: commit_nop,
        commit_arg: null,
        commit_requeue: 0,
        inited: 0,
        park_state: pst,
        timed: 0,
        deadline: 0,
        tm_token: 0,
        tnext: null,
    };
    if tracing() {
        trace("spawn coroutine", unsafe co.id);
    }
    enqueue_runnable(s, co);
}

/// Spawn a run-to-completion JOB: `entry(env)` runs on a worker's own stack, with no stack allocation and
/// no context switch. A job must never block on a task-aware primitive -- it cannot park, so it would hold
/// its worker -- which is why `current()` reports null inside one. This is how the data-parallel API
/// (`std::parallel::data`) submits chunks. `pub` for linkage.
pub fn spawn_job(entry: fn(*mut void) void, env: *mut void) {
    let s = ensure_started();
    let mut g = Global {};
    let co = g.alloc(sizeof(Coroutine), alignof(Coroutine)) as *mut Coroutine;
    unsafe co[0] = Coroutine {
        id: next_task_id(),
        ctx: null,
        stack: null,
        is_job: 1,
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
    if tracing() {
        trace("spawn job", unsafe co.id);
    }
    enqueue_runnable(s, co);
}

/// Submit `f` to run on the pool as a detached coroutine. Starts the pool on first use. The `launch`
/// statement lowers to this.
///
/// The bound is the whole safety argument. `fn move` lets `f` own what it uses; `Send` stops anything
/// unsafe to move between threads (a raw pointer, or a struct holding one) from crossing; and `'static`
/// is what makes DETACHING sound -- the task may outlive this call, so `f` may not capture a borrow of a
/// caller local (nor mutate a capture, which captures `&mut` into this frame). Move values in, or share
/// them through an `Arc`.
pub fn submit<F: fn move() + Send + 'static>(f: F) {
    let mut g = Global {};
    let slot = g.alloc(sizeof(F), alignof(F)) as *mut F;
    unsafe slot[0] = f;
    spawn_coroutine(job_entry::<F>, slot);
}

/// The coroutine currently running on this worker, or null on a non-worker (e.g. the main) thread -- and
/// also null inside a job, which has no context to park. A task-aware primitive checks this to decide
/// between parking a coroutine and blocking an OS thread.
pub fn current() *mut Coroutine {
    let t = (unsafe sc_runtime::sc_rt_tls_get()) as *mut Coroutine;
    if t != null && unsafe t.is_job != 0 {
        return null;
    }
    return t;
}

/// Is this thread running a data-parallel job? Such a task cannot park, so a nested parallel call has to run
/// its chunks inline rather than submit and wait for them.
pub fn in_job() bool {
    let t = (unsafe sc_runtime::sc_rt_tls_get()) as *mut Coroutine;
    return t != null && unsafe t.is_job != 0;
}

/// Open a new park and return its wake token. Call it (from inside the coroutine, under the lock guarding
/// the wait queue) before enqueueing a wait node, and store the token in that node: `wake` needs it, and it
/// is what makes a wakeup specific to one park. A node left behind by an expired timed wait keeps an old
/// token and is therefore inert -- which is why a waiter may re-park (to re-take the lock) before it has
/// managed to unlink itself.
pub fn park_begin(co: *mut Coroutine) u32 {
    let p = &mut unsafe co.park_state;
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
    if tracing() {
        trace(
            if deadline != 0 {
                "park (timed)";
            } else {
                "park";
            },
            unsafe co.id,
        );
    }
    unsafe co.commit_fn = commit;
    unsafe co.commit_arg = arg;
    unsafe co.deadline = deadline;
    unsafe co.tm_token = token;
    unsafe sc_runtime::sc_rt_ctx_switch(co.ctx, co.sched_ctx);
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
    if tracing() {
        trace("wake", unsafe co.id);
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
    unsafe sc_runtime::sc_rt_mutex_lock(s.lock);
    disarm_timer(s, co);
    unsafe sc_runtime::sc_rt_mutex_unlock(s.lock);
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

/// The id of the task running on this thread, or 0 on a plain thread. Ids are unique for the process and
/// are what a panic inside a coroutine reports, so a diagnostic can name the task rather than the process.
pub fn current_id() u64 {
    let t = (unsafe sc_runtime::sc_rt_tls_get()) as *mut Coroutine;
    if t == null {
        return 0;
    }
    return unsafe t.id;
}

/// Tasks created so far (coroutines and data-parallel jobs alike).
pub fn spawned_tasks() usize {
    return atomic::load_u64(&mut G_NEXT_ID, 1) as usize;
}

/// Tasks that have run to completion.
pub fn completed_tasks() usize {
    return atomic::load_usize(&mut G_DONE, 1);
}

/// Tasks created but not finished: still runnable, running, or parked. Zero after every launched task has
/// been awaited -- which is the precondition `shutdown` documents, and what it checks.
pub fn live_tasks() usize {
    return spawned_tasks() - completed_tasks();
}

/// Fix the pool's worker-thread count. Must be called before the first `launch` (the pool is built on
/// demand and never resized); `0` restores the default of one worker per CPU. Setting it to 1 makes
/// scheduling deterministic, which is what concurrency tests want.
/// Set the per-coroutine stack size, in bytes, before the pool starts (a later call is ignored, like
/// `set_worker_count`). The stack is RESERVED, not consumed -- pages arrive as the task uses them -- so this
/// buys depth for deeply recursive tasks rather than costing memory for shallow ones. Rounded up to 64 KiB;
/// 0 restores the default.
pub fn set_stack_size(bytes: usize) {
    if atomic::load_i32((&mut G_STATE) as *mut i32, 1) == 2 {
        return; // the running pool's stacks are already allocated
    }
    if bytes == 0 {
        G_STACK_SIZE = STACK_SIZE_DEFAULT;
        return;
    }
    let unit: usize = 65536;
    G_STACK_SIZE = (bytes + unit - 1) / unit * unit;
}

pub fn set_worker_count(n: usize) {
    G_NWORKERS = n;
}

/// How many worker threads the pool has (or will have): the configured count, else one per CPU. What the
/// data-parallel API divides its work by.
pub fn worker_count() usize {
    if G_NWORKERS > 0 {
        return G_NWORKERS;
    }
    return platform::ncpu();
}

// What a compiler-emitted safepoint calls. The scheduler cannot take a worker back from a task that never
// blocks, so a compute-bound coroutine would otherwise starve everything queued behind it. Yielding is only
// worth its context switch when there IS something else to run, and both checks are lock-free: this runs on
// every loop backedge (once per `__sc_pre_tick` of them).
fn preempt_yield() {
    let co = current();
    if co == null {
        return; // a plain thread, or a job: neither can park
    }
    let s = G_SCHED;
    if s == null {
        return;
    }
    let wi = unsafe sc_runtime::sc_rt_widx_get();
    if wi < 0 || wi as usize >= unsafe s.nw {
        return;
    }
    if !dq_empty(unsafe (s.deques + wi as usize)) || atomic::load_i32(&mut unsafe s.inj_len, 1) > 0 {
        yield_now();
    }
}

/// Cooperatively yield: reschedule the current coroutine behind the others. A no-op off a worker thread.
pub fn yield_now() {
    let co = current();
    if co == null {
        return;
    }
    let _ = park_begin(co); // retire the current token: nothing may wake a coroutine the worker requeues
    unsafe co.commit_requeue = 1;
    unsafe sc_runtime::sc_rt_ctx_switch(co.ctx, co.sched_ctx);
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
    unsafe sc_runtime::sc_rt_mutex_lock(s.lock);
    unsafe s.shutting_down = 1;
    unsafe sc_runtime::sc_rt_mutex_unlock(s.lock);
    // Every worker has its own condvar now, so shutting down means waking each in turn rather than one
    // broadcast. Unconditional: a worker not parked will see `shutting_down` on its next look anyway.
    for i in 0..unsafe s.nw {
        wake_parked(s, i);
    }
    let nw = unsafe s.workers.len();
    for i in 0..nw {
        let h = unsafe s.workers[i];
        let _ = unsafe sc_runtime::sc_rt_thread_join(h);
    }
    unsafe s.workers.free();
    pool_drain(s); // every recycled block, now that no worker can ask for one
    let mut g = Global {};
    for i in 0..unsafe s.nw {
        g.dealloc(unsafe (s.deques + i).buf, DEQUE_CAP * sizeof(*mut Coroutine), alignof(*mut Coroutine));
    }
    g.dealloc(unsafe s.deques, unsafe s.nw * sizeof(Worker), LINE);
    for i in 0..unsafe s.nw {
        let pk = unsafe (s.parkers + i);
        unsafe sc_runtime::sc_rt_mutex_free(pk.mtx);
        unsafe sc_runtime::sc_rt_cond_free(pk.cv);
    }
    g.dealloc(unsafe s.parkers, unsafe s.nw * sizeof(Parker), LINE);
    g.dealloc(unsafe s.idle, unsafe s.idle_words * sizeof(u64), alignof(u64));
    unsafe sc_runtime::sc_rt_mutex_free(s.lock);
    g.dealloc(s, sizeof(Scheduler), alignof(Scheduler));
    atomic::store_i32(sp, 0, 2);
    G_SCHED = null;
    // Anything still unfinished here is parked on something nothing will ever signal -- a deadlock the
    // program has already lost. Report it: the stacks it leaks are otherwise the only visible symptom.
    let stuck = live_tasks();
    if stuck > 0 {
        eprintln("super-c: {} task(s) still parked at shutdown (nothing will wake them)", stuck);
    }
}
