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
    // Combined-safepoint cancellation hook (super_rt.c): the cold half of a compiled combined
    // safepoint calls it; 1 means an unmasked request was accepted and the ladder must run.
    fn __sc_set_cancel_hook(f: fn() i32) void;
    // Task attribution (super_rt.c): a panic inside a coroutine names the task it happened in.
    fn __sc_set_task_id(id: u64) void;
}

// Per-coroutine stack. RESERVED, not consumed: the pages behind it are faulted in as the task actually
// uses them, so a shallow task costs a handful of pages however large this is (measured: ~16 KiB per parked
// task at the 256 KiB default). Raising it therefore buys depth, not memory -- see `set_stack_size`.
const STACK_SIZE_DEFAULT: usize = 262144;
static mut G_STACK_SIZE: usize = 262144;

// --- cancellation semantics (frozen) -------------------------------------------------------------------
// Cancellation is COOPERATIVE: it takes effect only at a cancellation point (a cancellable task-aware
// wait, a task-aware sleep, an explicit `cancel_point()`, or a compiler safepoint with a valid cleanup
// edge). It is not failure recovery: a request is idempotent, the first reason is retained, cleanup runs
// once, and the cancelled computation never resumes past its cleanup. Normal completion wins if it
// publishes completion before the cancellation is accepted; an accepted cancellation wins once the task
// reaches its root cancellation exit. After acceptance, further cancellation is MASKED: cleanup may use
// any runtime wait, and those waits park non-cancellably.
//
// A coroutine is NEVER freed while it is running user code, inside the park hand-off window, linked to a
// wait queue, timer, reactor or blocking result, inside an unreturned foreign call, or inside cleanup.
// A task that cannot accept cancellation is reported as unresponsive and its block stays allocated.

// Wake reasons: the low `WR_BITS` bits of `park_state`. Exactly one waker moves them from `WR_NONE` with
// one compare-and-swap per park generation -- notify, timeout, I/O readiness, blocking completion and
// cancellation all race through the same single-winner claim.
pub const WR_NONE: u32 = 0;
pub const WR_NOTIFY: u32 = 1;
pub const WR_TIMEOUT: u32 = 2;
pub const WR_CANCEL: u32 = 3;
pub const WR_SHUTDOWN: u32 = 4;
pub const WR_IO: u32 = 5;
pub const WR_BLOCKING: u32 = 6;
const WR_BITS: u32 = 3;
const WR_MASK: u32 = 7;
static_assert(WR_BLOCKING <= WR_MASK, "every wake reason must fit the park_state claim bits");
static_assert(WR_NONE == 0, "an open park must read as unclaimed");

// Park phases: the low `WR_BITS` bits of `park_phase`; the high bits carry the park token, so a late
// phase write for an already-finished park cannot corrupt the next one (every worker-side transition is a
// token-tagged compare-and-swap).
const PH_NOT_PARKING: u32 = 0;
const PH_PREPARING: u32 = 1;
const PH_SWITCHING: u32 = 2;
const PH_PARKED: u32 = 3;
const PH_RESUMING: u32 = 4;
static_assert(PH_RESUMING <= WR_MASK, "every park phase must fit the park_phase tag bits");

// Task lifecycle states, for the registry and diagnostics. Parking detail lives in `park_phase`; a task
// whose state is `TS_RUNNING` with a parked phase is parked, and one that parks while `TS_CLEANING` is
// the `CleaningBlocked` diagnostic case.
pub const TS_RUNNABLE: i32 = 0;
pub const TS_RUNNING: i32 = 1;
pub const TS_CLEANING: i32 = 2;
pub const TS_COMPLETED: i32 = 3;

// Cancellation request states.
pub const CS_NONE: i32 = 0;
pub const CS_REQUESTED: i32 = 1;
pub const CS_ACCEPTED: i32 = 2;
pub const CS_FINISHED: i32 = 3;

// Cancellation reasons; the first request's reason is retained.
pub const CR_NONE: u32 = 0;
pub const CR_USER: u32 = 1;
pub const CR_SHUTDOWN: u32 = 2;
pub const CR_POLICY: u32 = 3;

// Wait kinds, for diagnostics: what a parked task is waiting on.
pub const WK_NONE: i32 = 0;
pub const WK_MUTEX: i32 = 1;
pub const WK_CONDVAR: i32 = 2;
pub const WK_CHANNEL_SEND: i32 = 3;
pub const WK_CHANNEL_RECV: i32 = 4;
pub const WK_SELECT: i32 = 5;
pub const WK_SLEEP: i32 = 6;
pub const WK_IO: i32 = 7;
pub const WK_BLOCKING: i32 = 8;
pub const WK_WAIT_GROUP: i32 = 9;
pub const WK_SEMAPHORE: i32 = 10;
pub const WK_BARRIER: i32 = 11;
pub const WK_RWLOCK: i32 = 12;

// A job or a plain thread holds no registry slot.
const SLOT_NONE: u32 = 4294967295;

/// A schedulable task: either a stackful coroutine, or (`is_job`) a run-to-completion JOB that the worker
/// simply calls on its own stack -- no stack allocation, no context switch, and no ability to park. Jobs are
/// what the data-parallel API chunks work into, so a million-iteration loop costs a handful of tasks rather
/// than a million stacks.
///
/// `next` links it into the scheduler's run queue; a primitive's wait queue holds a separate per-wait node
/// instead (see `park_begin`), and `tnext` is the timer-list link. `pub` only so task-aware primitives can
/// hold `*mut Coroutine` and wake one -- not a user-facing type.
@no_const
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
    pub tm_token: u32, // the token of the CURRENT park (every park stores it, timed or not)
    pub tnext: *mut Coroutine, // timer-list link (sorted by `deadline`)
    pub slot: u32, // registry slot, fixed for the block's life (SLOT_NONE for a job)
    pub tstate: i32, // atomic TS_* lifecycle state
    pub cancel: i32, // atomic CS_* cancellation state
    pub cancel_reason: u32, // atomic CR_*: the first request's reason, set once
    pub cancel_wake: u32, // atomic: the WakeReason the first request claims with (WR_CANCEL or WR_SHUTDOWN)
    pub park_phase: u32, // atomic: park token | PH_* -- see park_begin and worker_main
    pub park_cancellable: i32, // atomic: may the CURRENT park be claimed with a cancel wake?
    pub cmask: i32, // cancellation-mask depth; only the task's own thread touches it
    pub wait_kind: i32, // atomic WK_* while parked, for diagnostics
    pub wait_obj: usize, // atomic: address identifying the wait object, for diagnostics
    pub handoff: i32, // atomic: the parking worker still owns the hand-off tail -- see worker_main
    pub unwound: i32, // the last checked call edge-returned: its value is poison -- see cancel_probe
}

/// A generation-checked handle to one task registry slot. A stale key (its task finished and the slot was
/// reused) can neither cancel nor observe the new occupant.
pub struct TaskKey {
    pub slot: u32,
    pub gen: u32,
}

/// One diagnostic snapshot row: the stable identity and current lifecycle of a live task.
pub struct TaskInfo {
    pub key: TaskKey,
    pub id: u64,
    pub state: i32, // TS_*
    pub phase: u32, // PH_*
    pub cancel: i32, // CS_*
    pub cancel_reason: u32, // CR_*
    pub wait_kind: i32, // WK_*
    pub wait_obj: usize,
    pub masked: bool, // parked non-cancellably, or running with the cancel mask held
}

// One registry slot. `gen` bumps once per task assigned to the slot and once per retirement, so a key
// captured for one task can never name another. `spin` orders a key-based cancel against block reuse.
@no_const
struct TaskSlot {
    pub co: *mut Coroutine,
    pub gen: u32,
    pub spin: i32,
    pub next_free: i64, // retired-slot freelist link; -1 = none
}

// The task registry: segment-allocated slots, so growth never moves a slot and a scan never chases a
// resize. The segment directory is allocated once; segments appear as concurrent task capacity grows.
const REG_SEG_SIZE: usize = 256;
const REG_MAX_SEGS: usize = 4096;
static_assert(REG_SEG_SIZE * REG_MAX_SEGS >= 1000000, "the registry must hold a large fan-out");

@no_const
struct Registry {
    pub segs: *mut *mut TaskSlot, // REG_MAX_SEGS pointers, allocated with the registry
    pub nsegs: usize,
    pub len: usize, // slots handed out so far (monotonic bump; retired slots recycle via free_head)
    pub free_head: i64,
    pub spin: i32, // guards slot allocation, retirement, and scans
}

static mut G_REG: *mut Registry = null;

const DEQUE_CAP: usize = 256; // power of two; an overflowing push spills to the injection queue
const BATCH_MAX: usize = 16; // injected tasks moved to a deque per lock -- see `take_injection`
const STEAL_MAX: usize = 32; // most tasks taken in one steal -- see `dq_steal`
const Y_MAX: i32 = 32; // yields a worker keeps to itself before spilling -- see `yq_push`
// Recycled task blocks the SHARED pool keeps. It has to exceed the number of tasks a program runs
// concurrently, or every spawn past it pays a fresh stack mmap plus a guard mprotect and a munmap on the way
// out -- at 256, a 1000-task fan-out re-allocated three quarters of its stacks on every iteration and the
// profile went allocation-bound. A block is 256 KiB RESERVED and roughly 16 KiB resident, so this bounds the
// idle cache at a few MiB rather than a few hundred.
const POOL_MAX: i32 = 1024;
const STASH_MAX: i32 = 16; // blocks a worker keeps to itself -- see the task-block pool
const STASH_BATCH: i32 = 16; // blocks moved between a stash and the shared pool per lock
const SPIN_MAX: i32 = 2048; // the spinner's look-again budget before it parks -- see `dequeue_runnable`
// A non-spinner's budget. Spinning costs a core and saves a wake-up syscall, so this is a real trade: at 64
// a cheap-task fan-out spent most of its time waking threads, and at 4096 the spinners stole cores from
// tasks that had actual work to do. 512 measured best across both shapes.
const SPIN_IDLE: i32 = 512;
const LINE: usize = 128; // cache line, and so the stride between two workers -- see `Worker.pad`

// Gated on the instruction set, not asserted everywhere: `pad` is sized for 8-byte pointers, and on wasm32
// the fields add up to less than a line. Nothing is lost there -- wasm runs one thread, so no second worker
// exists to share the line with, and the padding it does carry is only wasted bytes rather than a bug.
@arch(x86_64 | aarch64)
static_assert(sizeof(Worker) == LINE, "Worker must be exactly one cache line: adjust its padding");

/// One worker's run deque (Chase-Lev): its owner pushes and pops the BOTTOM, thieves steal the TOP, and the
/// two only contend over the last element -- so the common case takes no lock at all. Fixed capacity, which
/// is what keeps it simple: a push that would overflow spills into the shared injection queue instead of
/// growing the buffer under the thieves' feet.
@no_const
pub struct Worker {
    pub buf: *mut *mut Coroutine, // DEQUE_CAP slots, indexed modulo the capacity
    pub head: usize, // atomic: next slot to run; CAS'd by the owner and by thieves alike
    pub tail: usize, // atomic: one past the last slot pushed (only the owner writes it)
    pub rng: u64, // xorshift state for victim selection
    pub tick: u32, // dequeue counter: every so often the injection queue is polled first (fairness)
    pub idx: usize, // this worker's index, so a thread can be started from its slot alone
    pub sched: *mut Scheduler,
    pub bhead: *mut Coroutine, // this worker's private stash of recycled task blocks
    pub blen: i32, // how many; beyond STASH_MAX the stash is handed to the shared pool in one go
    // Padding to a whole cache line. Workers live in one array, so without it two of them share a line:
    // every push moves `bottom` and every steal moves `top`, and a store to either invalidates the
    // neighbour's copy of both. Worth ~25% on a yield-heavy fan-out across fourteen workers, which is the
    // shape that moves these two fields hardest. 128 bytes because that is the line on Apple silicon; on a
    // 64-byte machine it is simply two lines per worker.
    pub yhead: *mut Coroutine, // yielded here, oldest first: taken only once the ring is empty
    pub ytail: *mut Coroutine,
    pub ylen: i32, // beyond Y_MAX a yield spills to the injection queue -- see `yq_push`
    pub pad: Array<u64, 4>,
}

/// Where one worker sleeps: its own mutex and condvar, so waking it is an UNCONTENDED lock plus one signal.
/// A single pool-wide condvar meant the submitter's wake had to queue behind every worker parking and
/// unparking through the same mutex, and on macOS a contended pthread mutex is two syscalls -- that queue
/// was most of what submitting a task cost at fourteen workers. `notified` is the predicate, so a signal
/// that lands before the wait is not lost. Line-padded: a worker being woken must not invalidate the
/// neighbour's line.
@no_const
pub struct Parker {
    pub mtx: *mut void,
    pub cv: *mut void,
    pub notified: i32, // set by whoever wakes this worker; cleared by the worker before it sleeps
    pub pad: Array<u64, 13>,
}

/// The shared pool. Fields are `pub` only for the caller-monomorphized `launch` / task-aware primitives.
@no_const
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
static mut G_CANCELLED: usize = 0; // atomic: completions that were accepted cancellations
static mut G_CLOSED: i32 = 0; // atomic: shutdown has stopped accepting new tasks

static mut G_TRACE: i32 = 0; // 0 unknown / 1 off / 2 on

// Deterministic-replay mode: 0 = off, anything else is the seed. Resolved once, before the first worker
// exists, and never written again -- so no reader needs to synchronize with it. `G_DET` is the generator the
// safepoint draws from; only the single deterministic worker ever touches it (see `preempt_yield`).
static mut G_SEED: u64 = 0;
static mut G_DET: u64 = 0;
// Replay mode only. `G_GATE` is a GENERATION, not a flag: a plain thread bumps it when it blocks, and the
// worker runs exactly until it has consumed that release. A flag loses a release that arrives while the
// worker is still draining the previous one; a generation cannot. `G_SEEN` belongs to the single worker.
static mut G_GATE: i32 = 0; // atomic
static mut G_SEEN: i32 = 0;
static mut G_ACTIVE: i32 = 0; // is the worker inside a release right now?

/// Is task tracing on? `SC_TASK_TRACE=1` turns it on for the life of the process; the answer is read from
/// the environment once and then costs a load and a compare, so a traced build and an untraced one are the
/// same binary. `pub` because the channel traces through it too.
pub fn tracing() bool {
    // Benign by construction rather than by ordering: every writer computes the SAME value from the same
    // environment, so a racing pair of first calls can only write 1 over 1 or 2 over 2.
    unsafe {
        if G_TRACE == 0 {
            G_TRACE = if stdlib::getenv("SC_TASK_TRACE") == null {
                1;
            } else {
                2;
            };
        }
        return G_TRACE == 2;
    }
}

/// One trace line: what happened, and to which task. Check `tracing()` first on a hot path.
pub fn trace(event: str, id: u64) {
    eprintln("[task {}] {}", id, event);
}

// The commit hand-off for a park with nothing to release (e.g. `sleep`).
const fn commit_nop(_p: *mut void) {}

// A fresh task id. Ids are handed out in order and never reused, so the counter is also the number of tasks
// ever created -- one contended increment per task rather than two for the same pair of facts.
fn next_task_id() u64 {
    return atomic::add_u64(&mut unsafe G_NEXT_ID, 1, 0) + 1;
}

// Claim the right to resume the park identified by `token`, recording `reason` as the winning wake:
// succeeds once, for one waker, and only while that exact park is still current. A registration left
// behind by an expired timed wait therefore cannot resume a LATER park -- which would run a coroutine
// that never actually acquired what it waited for.
fn claim(co: *mut Coroutine, token: u32, reason: u32) bool {
    let p = &mut unsafe co.park_state;
    return atomic::cas_u32(p, token, token | reason, false, 4, 0); // SeqCst on success, Relaxed on failure
}

// --- the task registry ---------------------------------------------------------------------------------
// Every coroutine block owns one generation-checked slot for its whole life: assigned on the block's first
// spawn, generation-bumped per reuse, retired only when the block itself is released. Spawn and completion
// therefore never touch the registry lock on the recycled path; only cold block allocation, block release,
// and diagnostic scans take it.

fn reg_ensure() *mut Registry {
    if unsafe G_REG != null {
        return unsafe G_REG;
    }
    let mut g = Global {};
    let r = (unsafe g.alloc(sizeof(Registry), alignof(Registry))) as *mut Registry;
    let segs = (unsafe g.alloc(REG_MAX_SEGS * sizeof(*mut TaskSlot), alignof(*mut TaskSlot))) as *mut *mut TaskSlot;
    for i in 0..REG_MAX_SEGS {
        unsafe segs[i] = null;
    }
    unsafe r[0] = Registry { segs: segs, nsegs: 0, len: 0, free_head: -1, spin: 0 };
    unsafe G_REG = r;
    return r;
}

fn reg_slot(r: *mut Registry, idx: usize) *mut TaskSlot {
    let seg = unsafe r.segs[idx / REG_SEG_SIZE];
    return unsafe (seg + idx % REG_SEG_SIZE);
}

// Give a freshly-built block its slot. Called once per block, before the task is published to any queue.
fn reg_assign(co: *mut Coroutine) {
    let r = reg_ensure();
    unsafe sc_runtime::sc_rt_spin_lock(&mut r.spin);
    let mut idx: usize = 0;
    if unsafe r.free_head >= 0 {
        idx = (unsafe r.free_head) as usize;
        let sl0 = reg_slot(r, idx);
        unsafe r.free_head = unsafe sl0.next_free;
    } else {
        idx = unsafe r.len;
        if idx >= REG_SEG_SIZE * REG_MAX_SEGS {
            // Registry exhausted: the task runs unregistered (it cannot be cancelled by key). Bounded by
            // design; a program holding a million live tasks has larger problems than this.
            unsafe sc_runtime::sc_rt_spin_unlock(&mut r.spin);
            unsafe co.slot = SLOT_NONE;
            return;
        }
        if unsafe r.segs[idx / REG_SEG_SIZE] == null {
            let mut g = Global {};
            let seg = (unsafe g.alloc(REG_SEG_SIZE * sizeof(TaskSlot), alignof(TaskSlot))) as *mut TaskSlot;
            for i in 0..REG_SEG_SIZE {
                unsafe seg[i] = TaskSlot { co: null, gen: 0, spin: 0, next_free: -1 };
            }
            unsafe r.segs[idx / REG_SEG_SIZE] = seg;
            unsafe r.nsegs = unsafe r.nsegs + 1;
        }
        atomic::store_usize(&mut unsafe r.len, idx + 1, 2); // atomic: key validation reads it unlocked
    }
    let sl = reg_slot(r, idx);
    unsafe sl.co = co;
    atomic::store_u32(&mut unsafe sl.gen, unsafe sl.gen + 1, 2);
    unsafe co.slot = idx as u32;
    unsafe sc_runtime::sc_rt_spin_unlock(&mut r.spin);
}

// A recycled block keeps its slot; a new task in it is a new generation. The bump happens under the slot's
// own spinlock, BEFORE the block's task fields are rewritten, so a canceller that validated a stale key
// under the same lock can never touch the new task.
fn reg_reuse_lock(co: *mut Coroutine) *mut TaskSlot {
    if unsafe co.slot == SLOT_NONE {
        return null;
    }
    let r = unsafe G_REG;
    let sl = reg_slot(r, (unsafe co.slot) as usize);
    unsafe sc_runtime::sc_rt_spin_lock(&mut sl.spin);
    atomic::store_u32(&mut unsafe sl.gen, unsafe sl.gen + 1, 2);
    return sl;
}

// Retire a released block's slot. After this no key can reach the block, so its memory may be freed.
fn reg_retire(co: *mut Coroutine) {
    if unsafe co.slot == SLOT_NONE || unsafe G_REG == null {
        return;
    }
    let r = unsafe G_REG;
    unsafe sc_runtime::sc_rt_spin_lock(&mut r.spin);
    let sl = reg_slot(r, (unsafe co.slot) as usize);
    unsafe sc_runtime::sc_rt_spin_lock(&mut sl.spin);
    unsafe sl.co = null;
    atomic::store_u32(&mut unsafe sl.gen, unsafe sl.gen + 1, 2);
    unsafe sc_runtime::sc_rt_spin_unlock(&mut sl.spin);
    unsafe sl.next_free = unsafe r.free_head;
    unsafe r.free_head = unsafe co.slot;
    unsafe co.slot = SLOT_NONE;
    unsafe sc_runtime::sc_rt_spin_unlock(&mut r.spin);
}

// Free the registry itself. Only shutdown calls it, after every block is released.
fn reg_free() {
    let r = unsafe G_REG;
    if r == null {
        return;
    }
    let mut g = Global {};
    for i in 0..unsafe r.nsegs {
        unsafe g.dealloc(unsafe r.segs[i], REG_SEG_SIZE * sizeof(TaskSlot), alignof(TaskSlot));
    }
    unsafe g.dealloc(unsafe r.segs, REG_MAX_SEGS * sizeof(*mut TaskSlot), alignof(*mut TaskSlot));
    unsafe g.dealloc(r, sizeof(Registry), alignof(Registry));
    unsafe G_REG = null;
}

// Read one live slot into a TaskInfo row. Caller holds the registry spinlock. The slot lock pins the
// generation to the coroutine fields while a recycled block is initialized for its next task.
fn reg_read(sl: *mut TaskSlot, idx: usize, out: &mut TaskInfo) bool {
    unsafe sc_runtime::sc_rt_spin_lock(&mut sl.spin);
    let co = unsafe sl.co;
    if co == null {
        unsafe sc_runtime::sc_rt_spin_unlock(&mut sl.spin);
        return false;
    }
    let mut st = atomic::load_i32(&mut unsafe co.tstate, 1);
    if st == TS_COMPLETED {
        unsafe sc_runtime::sc_rt_spin_unlock(&mut sl.spin);
        return false;
    }
    if atomic::load_i32(&mut unsafe co.cancel, 1) == CS_ACCEPTED {
        st = TS_CLEANING; // cleanup owns the task from acceptance to completion
    }
    let ph = atomic::load_u32(&mut unsafe co.park_phase, 1);
    let parked_masked = (ph & WR_MASK) == PH_PARKED && atomic::load_i32(&mut unsafe co.park_cancellable, 1) == 0;
    *out = TaskInfo {
        key: TaskKey { slot: idx as u32, gen: atomic::load_u32(&mut unsafe sl.gen, 1) },
        id: atomic::load_u64(&mut unsafe co.id, 1),
        state: st,
        phase: ph & WR_MASK,
        cancel: atomic::load_i32(&mut unsafe co.cancel, 1),
        cancel_reason: atomic::load_u32(&mut unsafe co.cancel_reason, 1),
        wait_kind: atomic::load_i32(&mut unsafe co.wait_kind, 1),
        wait_obj: atomic::load_usize(&mut unsafe co.wait_obj, 1),
        masked: parked_masked,
    };
    unsafe sc_runtime::sc_rt_spin_unlock(&mut sl.spin);
    return true;
}

/// Snapshot every live registered task into `out`, in stable slot order. A diagnostic scan: the rows are
/// a consistent identity (key, id) with a racy-but-monotone view of state. `pub` for shutdown reports and
/// the task-leak sanitizer.
pub fn task_snapshot(out: &mut Vector<TaskInfo>) {
    if unsafe G_REG == null {
        return;
    }
    let r = unsafe G_REG;
    unsafe sc_runtime::sc_rt_spin_lock(&mut r.spin);
    for idx in 0..unsafe r.len {
        let sl = reg_slot(r, idx);
        let mut info = TaskInfo {
            key: TaskKey { slot: 0, gen: 0 },
            id: 0,
            state: 0,
            phase: 0,
            cancel: 0,
            cancel_reason: 0,
            wait_kind: 0,
            wait_obj: 0,
            masked: false,
        };
        if reg_read(sl, idx, &mut info) {
            out.push(info);
        }
    }
    unsafe sc_runtime::sc_rt_spin_unlock(&mut r.spin);
}

/// The registry key of the task running on this thread. `slot` is `SLOT_NONE`-valued (`is_task` false) on
/// a plain thread or inside a data-parallel job.
pub fn current_key() TaskKey {
    let co = current();
    if co == null || unsafe co.slot == SLOT_NONE {
        return TaskKey { slot: SLOT_NONE, gen: 0 };
    }
    let r = unsafe G_REG;
    let sl = reg_slot(r, (unsafe co.slot) as usize);
    return TaskKey { slot: unsafe co.slot, gen: atomic::load_u32(&mut unsafe sl.gen, 1) };
}

extend TaskKey {
    /// Does this key name a real registered task (as opposed to a plain thread or job)?
    pub fn is_task(self: &TaskKey) bool {
        return self.slot != SLOT_NONE;
    }
}

// Memory-order codes for the atomic builtins: 0 Relaxed, 1 Acquire, 2 Release, 3 AcqRel, 4 SeqCst.

// --- the run queue --------------------------------------------------------------------------------------
// A fixed ring per worker. The owner appends at `tail`; EVERY take -- a thief's and the owner's own --
// claims its slot with a CAS on `head`.
//
// That CAS on the owner's own path is a real cost, and it buys BATCH STEALING. Chase-Lev's cheaper trick,
// where the owner pops the far end with no synchronisation at all, cannot support it: a thief claiming two
// slots races an owner draining down into them, and the owner only CASes on the very last element -- so with
// two tasks queued both would run the same one. Go's run queue makes exactly this trade for exactly this
// reason. Taking half a victim's queue per steal, rather than one task per CAS, is what stops a fan-out from
// serialising on the victim's head line.
//
// The cost is that the owner now takes in FIFO order, so the freshest task no longer runs first. The yield
// queue below is unaffected -- it is still drained after this one.

fn dq_head(w: *mut Worker) *mut usize {
    return &mut unsafe w.head;
}

fn dq_tail(w: *mut Worker) *mut usize {
    return &mut unsafe w.tail;
}

// Owner: append. False when the ring is full (the caller spills to the injection queue).
fn dq_push(w: *mut Worker, co: *mut Coroutine) bool {
    let t = atomic::load_usize(dq_tail(w), 0); // only this worker writes it
    let h = atomic::load_usize(dq_head(w), 1);
    if t - h >= DEQUE_CAP {
        return false;
    }
    unsafe w.buf[t % DEQUE_CAP] = co;
    atomic::store_usize(dq_tail(w), t + 1, 2); // Release: publishes the slot
    return true;
}

// Owner: take the oldest. Null when empty, or when a thief won the race for the slot.
fn dq_pop(w: *mut Worker) *mut Coroutine {
    loop {
        let h = atomic::load_usize(dq_head(w), 1);
        let t = atomic::load_usize(dq_tail(w), 1);
        if h == t {
            return null;
        }
        let co = unsafe w.buf[h % DEQUE_CAP];
        if atomic::cas_usize(dq_head(w), h, h + 1, false, 4, 0) {
            return co;
        }
    }
}

// Any worker: take HALF of `victim`'s queue, keeping one to run and putting the rest on the thief's own
// ring. Reading the slots before the CAS is sound because they can only be reused after `head` advances
// past them, and `head` advancing is exactly what makes our CAS fail.
fn dq_steal(victim: *mut Worker, thief: *mut Worker) *mut Coroutine {
    loop {
        let h = atomic::load_usize(dq_head(victim), 1);
        let t = atomic::load_usize(dq_tail(victim), 1);
        if t == h {
            return null; // empty; a spuriously empty reading is a steal that fails, which callers handle
        }
        let avail = t - h;
        let mut n = avail - avail / 2; // half, rounded up, so a single task is still worth taking
        if n > STEAL_MAX {
            n = STEAL_MAX;
        }
        // Never take more than we can carry: the surplus would have to go back, and putting it back is a
        // second race we do not need.
        let th = atomic::load_usize(dq_head(thief), 1);
        let tt = atomic::load_usize(dq_tail(thief), 0);
        let room = DEQUE_CAP - (tt - th) + 1; // +1: the one we return to the caller is not stored
        if n > room {
            n = room;
        }
        if n == 0 {
            return null;
        }
        // Copy straight into our own ring, at slots past our tail: nobody can see them until we publish
        // that tail, so a failed CAS below simply leaves scribbles on memory we own and we try again.
        let first = unsafe victim.buf[h % DEQUE_CAP];
        for i in 1..n {
            unsafe thief.buf[(tt + i - 1) % DEQUE_CAP] = unsafe victim.buf[(h + i) % DEQUE_CAP];
        }
        if !atomic::cas_usize(dq_head(victim), h, h + n, false, 4, 0) {
            continue; // somebody else moved the head; re-read and try again
        }
        if n > 1 {
            atomic::store_usize(dq_tail(thief), tt + n - 1, 2); // Release: publishes what we just wrote
        }
        return first;
    }
}

fn dq_empty(w: *mut Worker) bool {
    return atomic::load_usize(dq_tail(w), 1) == atomic::load_usize(dq_head(w), 1);
}

// --- the owner's yield queue ---------------------------------------------------------------------------
// A yield means "let somebody else go first". The ring above is FIFO for its owner, so appending a yielded
// task would put it behind everything already queued -- the right ORDER -- and deleting this queue in favour
// of that was measured and was 34% WORSE on a fourteen-worker fan-out. A yielded task goes back on the same
// worker almost immediately, and routing it through the shared ring means a CAS on the head to take it back
// plus the chance a thief drags it to a cold core in between. Keeping it private costs no synchronisation at
// all, and `find_work` drains it once the ring is empty.
//
// The one thing a private queue cannot do is let an idle worker steal from it, so it is bounded: past
// `Y_MAX` a yield goes to the injection queue, where anyone can take it.

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
    atomic::store_i32(&mut unsafe co.tstate, TS_RUNNABLE, 0);
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
        if claim(co, unsafe co.tm_token, WR_TIMEOUT) {
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
        let co = dq_steal(unsafe (s.deques + v), w);
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
    let yielded = yq_pop(w); // after the ring: a task that yielded asked to go behind fresh work
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
    // Replay mode: the nearest armed timer deadline as of this worker's last look, so the gate wait can end on
    // it and not only on a release. Zero means nothing is armed -- always true on the first pass, because
    // nothing has run yet to arm one.
    let mut replay_deadline: u64 = 0;
    loop {
        // Replay mode: a release admits the worker for a whole DRAIN, not for one task. The admission is
        // taken here, before the spin -- a worker that spins while the launcher is still submitting picks
        // tasks up one at a time, and then the interleaving is a race with thread start-up rather than a
        // function of the seed. It is given back below, where the drain runs dry.
        if unsafe G_SEED != 0 && unsafe G_ACTIVE == 0 {
            replay_gate_wait(s, me, replay_deadline);
            unsafe G_ACTIVE = 1;
        }
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
        if unsafe G_SEED != 0 {
            // The drain ran dry: give the admission back and go round, which waits for the next release -- or
            // for the nearest armed deadline, read here because this is the one place holding the lock that
            // guards the timer list.
            replay_deadline = if unsafe s.timer_head != null {
                unsafe s.timer_head.deadline;
            } else {
                0u64;
            };
            unsafe sc_runtime::sc_rt_mutex_unlock(s.lock);
            unsafe G_ACTIVE = 0;
            spins = 0;
            continue;
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

// Replay mode: block the worker until a plain thread hands it the CPU. Without this the pool starts running
// tasks while the launcher is still submitting them, and how many are queued by then is a race with thread
// start-up -- so the first run of a binary interleaves differently from the second, seed or no seed.
//
// Two conditions besides the gate end the wait, and both are there to make a missed hand-off cost latency
// rather than a hang: work that arrived after the gate shut, and shutdown. The timed park is the third.
fn replay_gate_wait(s: *mut Scheduler, me: usize, nearest_deadline: u64) {
    let pk = unsafe (s.parkers + me);
    let start = platform::now_ns();
    unsafe sc_runtime::sc_rt_mutex_lock(pk.mtx);
    loop {
        let g = atomic::load_i32(&mut unsafe G_GATE, 1);
        if g != unsafe G_SEEN || unsafe s.shutting_down != 0 {
            unsafe G_SEEN = g;
            break;
        }
        // A deadline that has come due ends the wait, exactly as it ends an ordinary park. It has to: the
        // coroutine behind a timed wait sits on the TIMER LIST, not on any run queue, and only a worker past
        // this gate promotes it -- so waiting for a release instead would strand it for as long as the program
        // had no plain thread left to block, which for a program whose remaining tasks are ALL on timed waits
        // is forever. `nearest_deadline` is read by the caller, which holds the lock the timer list is under.
        if nearest_deadline != 0 && nearest_deadline <= platform::now_ns() {
            break;
        }
        // Work queued, but no plain thread has blocked to release the pool: an OS thread fed it and kept
        // running, which is outside what this mode models. Run rather than hang -- determinism was already
        // lost to that thread, and a hang would only hide which program lost it.
        if atomic::load_i32(&mut unsafe s.inj_len, 1) > 0 && platform::now_ns() - start > 20000000 {
            break;
        }
        let _ = unsafe sc_runtime::sc_rt_cond_timedwait_ns(pk.cv, pk.mtx, 5000000i64);
    }
    unsafe sc_runtime::sc_rt_mutex_unlock(pk.mtx);
}

/// Replay mode only, and a no-op otherwise: give the pool the CPU because this thread is about to block.
/// `pub` because the two places a non-coroutine thread blocks are in `std::parallel::sync`, not here.
pub fn replay_release() {
    if unsafe G_SEED == 0 {
        return;
    }
    let s = unsafe G_SCHED;
    if s == null {
        return;
    }
    let _ = atomic::add_i32(&mut unsafe G_GATE, 1, 2);
    wake_parked(s, 0);
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
//
// The pool is TWO tiers, and the split is the whole point. One shared free list behind one lock made
// spawning serialise on it: a spawn takes a block and a completion gives one back, so at fourteen workers
// that single lock's cache line was the most contended thing in the runtime -- far more than the lock's own
// instructions (an atomic on a line thirteen threads are hammering measures ~127ns against ~2.5ns
// uncontended). So each worker keeps a private STASH it alone touches, and trades with the shared pool
// `STASH_BATCH` blocks at a time, amortising the lock over sixteen tasks. Measured: spawning from inside
// coroutines went from 3041ns to 372ns per task at fourteen workers.

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
    reg_retire(co); // after this no key or scan can reach the block
    unsafe sc_runtime::sc_rt_stack_free(co.stack, G_STACK_SIZE);
    unsafe sc_runtime::sc_rt_ctx_free(co.ctx);
    let mut g = Global {};
    unsafe g.dealloc(co, sizeof(Coroutine), alignof(Coroutine));
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

// Take up to `n` blocks off the shared pool as one chain, for one lock acquisition. `got` reports how many.
fn pool_take_chain(s: *mut Scheduler, n: i32, got: &mut i32) *mut Coroutine {
    *got = 0;
    if atomic::load_i32(&mut unsafe s.free_len, 1) <= 0 {
        return null;
    }
    unsafe sc_runtime::sc_rt_spin_lock(&mut s.free_spin);
    let mut head: *mut Coroutine = null;
    let mut k: i32 = 0;
    while k < n && unsafe s.free_head != null {
        let co = unsafe s.free_head;
        unsafe s.free_head = unsafe co.next;
        unsafe co.next = head;
        head = co;
        k = k + 1;
    }
    let _ = atomic::sub_i32(&mut unsafe s.free_len, k, 0);
    unsafe sc_runtime::sc_rt_spin_unlock(&mut s.free_spin);
    *got = k;
    return head;
}

// Hand a whole chain back in one lock acquisition. Whatever the pool has no room for is really freed, and
// deliberately outside the lock: a munmap is far too slow to hold a contended spinlock across.
fn pool_put_chain(s: *mut Scheduler, head: *mut Coroutine) {
    if head == null {
        return;
    }
    let mut co = head;
    unsafe sc_runtime::sc_rt_spin_lock(&mut s.free_spin);
    let mut k: i32 = 0;
    while co != null && unsafe s.free_len + k < POOL_MAX {
        let nxt = unsafe co.next;
        unsafe co.next = unsafe s.free_head;
        unsafe s.free_head = co;
        k = k + 1;
        co = nxt;
    }
    let _ = atomic::add_i32(&mut unsafe s.free_len, k, 0);
    unsafe sc_runtime::sc_rt_spin_unlock(&mut s.free_spin);
    while co != null {
        let nxt = unsafe co.next;
        release_block(co);
        co = nxt;
    }
}

// This thread's worker, or null off the pool. The stash is owner-only, so everything below needs this first.
fn my_worker(s: *mut Scheduler) *mut Worker {
    let wi = unsafe sc_runtime::sc_rt_widx_get();
    if wi < 0 || wi as usize >= unsafe s.nw {
        return null;
    }
    return unsafe (s.deques + wi as usize);
}

// A recycled block, from this worker's stash if it has one. Null when nothing is cached anywhere and the
// caller has to build one.
fn take_block(s: *mut Scheduler) *mut Coroutine {
    let w = my_worker(s);
    if w == null {
        return pool_take(s); // an off-pool submitter has no stash of its own
    }
    let co = unsafe w.bhead;
    if co != null {
        unsafe w.bhead = unsafe co.next;
        unsafe w.blen = unsafe w.blen - 1;
        unsafe co.next = null;
        return co;
    }
    // Empty: refill the stash and keep the head, so the next STASH_BATCH spawns take no lock at all.
    let mut got: i32 = 0;
    let chain = pool_take_chain(s, STASH_BATCH, &mut got);
    if chain == null {
        return null;
    }
    unsafe w.bhead = unsafe chain.next;
    unsafe w.blen = got - 1;
    unsafe chain.next = null;
    return chain;
}

// Give a finished block back: to this worker's stash if there is room, else hand the whole stash on at once.
fn free_coroutine(s: *mut Scheduler, co: *mut Coroutine) {
    let w = my_worker(s);
    if w == null {
        if !pool_put(s, co) {
            release_block(co);
        }
        return;
    }
    if unsafe w.blen >= STASH_MAX {
        let full = unsafe w.bhead;
        unsafe w.bhead = null;
        unsafe w.blen = 0;
        pool_put_chain(s, full);
    }
    unsafe co.next = unsafe w.bhead;
    unsafe w.bhead = co;
    unsafe w.blen = unsafe w.blen + 1;
}

// A worker's stash dies with it: hand it back before the thread leaves, or `shutdown` would never see it.
fn stash_flush(s: *mut Scheduler, w: *mut Worker) {
    let head = unsafe w.bhead;
    unsafe w.bhead = null;
    unsafe w.blen = 0;
    pool_put_chain(s, head);
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
            unsafe gj.dealloc(co, sizeof(Coroutine), alignof(Coroutine));
            let _ = atomic::add_usize(&mut unsafe G_DONE, 1, 0);
            continue;
        }
        unsafe co.sched_ctx = sched_ctx;
        atomic::store_i32(&mut unsafe co.tstate, TS_RUNNING, 0);
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
            // The previous run slice's parking worker may still own the hand-off tail (its Parked
            // publication and cancel check). The block must not be recycled under it; the wait is bounded
            // by that worker's dozen remaining instructions.
            while atomic::load_i32(&mut unsafe co.handoff, 1) != 0 {
                unsafe sc_runtime::sc_rt_cpu_relax();
            }
            // Completion accounting BEFORE the block is recycled: an accepted cancellation that reaches
            // this point was reclaimed; publish Completed last so a registry scan never reads a half-done
            // retirement.
            if atomic::load_i32(&mut unsafe co.cancel, 1) == CS_ACCEPTED {
                atomic::store_i32(&mut unsafe co.cancel, CS_FINISHED, 2);
                let _ = atomic::add_usize(&mut unsafe G_CANCELLED, 1, 0);
                if tracing() {
                    trace("task reclaimed", unsafe co.id);
                }
            }
            atomic::store_i32(&mut unsafe co.tstate, TS_COMPLETED, 2);
            free_coroutine(s, co);
            let _ = atomic::add_usize(&mut unsafe G_DONE, 1, 0);
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
            let token = unsafe co.tm_token;
            // Own the hand-off tail before the task becomes visible to any waker: a worker that resumes
            // and completes this task spins on `handoff` before recycling the block, so the tail below can
            // never touch freed memory.
            atomic::store_i32(&mut unsafe co.handoff, 1, 2);
            // Then arm its timer (if the wait was timed) and only last release the lock that kept its waker
            // out: by now its context is fully saved, so any waker may resume it.
            if dl != 0 {
                unsafe sc_runtime::sc_rt_mutex_lock(s.lock);
                arm_timer(s, co, dl);
                unsafe sc_runtime::sc_rt_mutex_unlock(s.lock);
            }
            commit(arg);
            // Publish Parked for THIS park generation. The tag makes a late publication harmless: if a
            // waker already resumed the task (and it moved to another park), the compare fails and the
            // hand-off is over. On success, look at the cancellation flag AFTER the publication -- paired
            // with request_cancel's Requested-store-then-phase-read, one side always sees the other, so a
            // request that lands during the hand-off window is never lost.
            if atomic::cas_u32(&mut unsafe co.park_phase, token | PH_SWITCHING, token | PH_PARKED, false, 4, 0) {
                if atomic::load_i32(&mut unsafe co.cancel, 4) == CS_REQUESTED {
                    if atomic::load_i32(&mut unsafe co.park_cancellable, 1) != 0 {
                        let wr = atomic::load_u32(&mut unsafe co.cancel_wake, 1);
                        if claim(co, token, wr) {
                            if tracing() {
                                trace("cancel wake won", unsafe co.id);
                            }
                            enqueue_runnable(s, co);
                        }
                    }
                }
            }
            atomic::store_i32(&mut unsafe co.handoff, 0, 2); // the tail is over: the block may be recycled
        }
    }
    stash_flush(s, w); // before widx goes: `free_coroutine` keys off it
    unsafe sc_runtime::sc_rt_ctx_free(sched_ctx);
    unsafe sc_runtime::sc_rt_widx_set(-1);
    return null;
}

fn build_scheduler() *mut Scheduler {
    let mut g = Global {};
    let s = (unsafe g.alloc(sizeof(Scheduler), alignof(Scheduler))) as *mut Scheduler;
    let lk = unsafe sc_runtime::sc_rt_mutex_new();
    // Resolved here, before any worker exists, so every later read of `G_SEED` happens-after this write.
    // Replay needs ONE worker: with a second one, stealing decides who runs next and the seed cannot.
    unsafe G_SEED = resolve_seed();
    unsafe G_DET = unsafe G_SEED;
    if unsafe G_SEED != 0 {
        unsafe G_NWORKERS = 1;
    }
    let nw = if unsafe G_NWORKERS > 0 {
        unsafe G_NWORKERS;
    } else {
        platform::ncpu();
    };
    let deques = (unsafe g.alloc(nw * sizeof(Worker), LINE)) as *mut Worker; // line-aligned: see Worker.pad
    let parkers = (unsafe g.alloc(nw * sizeof(Parker), LINE)) as *mut Parker;
    let words = (nw + 63) / 64;
    let idle = (unsafe g.alloc(words * sizeof(u64), alignof(u64))) as *mut u64;
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
        let buf = (unsafe g.alloc(DEQUE_CAP * sizeof(*mut Coroutine), alignof(*mut Coroutine))) as *mut *mut Coroutine;
        // Seed each victim-choice generator differently and never with zero, or xorshift stays at zero.
        let seed = 0x9e3779b97f4a7c15 + (i as u64 + 1) * 0x632be59bd9b4e019;
        unsafe deques[i] = Worker {
            buf: buf,
            head: 0,
            tail: 0,
            rng: seed,
            tick: 0,
            idx: i,
            sched: s,
            bhead: null,
            blen: 0,
            yhead: null,
            ytail: null,
            ylen: 0,
            pad: Array::<u64, 4>::new(),
        };
    }
    // Before any worker exists, so every safepoint's read of the hook happens-after this write.
    unsafe __sc_set_preempt_hook(preempt_yield);
    unsafe __sc_set_cancel_hook(cancel_safepoint_tick);
    for i in 0..nw {
        let mut h: *mut void = null;
        let _ = unsafe sc_runtime::sc_rt_thread_create(&mut h, worker_main, unsafe (deques + i));
        unsafe s.workers.push(h);
    }
    return s;
}

/// Start the pool if it is not running yet and return it. Thread-safe; `pub` for linkage.
pub fn ensure_started() *mut Scheduler {
    // `G_SCHED` is ordered by `G_STATE`, which the compiler cannot see: the winner of the CAS publishes the
    // pointer and THEN releases state 2, and every reader acquires state 2 before reading the pointer -- so
    // the write happens-before every read of it. That handshake is what the `unsafe` here asserts.
    unsafe {
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
}

/// The per-`F` trampoline: move the closure out of its heap box, free the box, and run it. `pub` for linkage.
pub fn job_entry<F: fn move()>(env: *mut void) {
    let pp = env as *mut F;
    let f = unsafe {
        pp[0];
    };
    let mut g = Global {};
    unsafe g.dealloc(env, sizeof(F), alignof(F));
    f();
}

/// Spawn a coroutine running `entry(env)` on a fresh guard-paged stack. Non-generic so it (and the runtime
/// internals it touches) live in this TU; `pub` for linkage from the caller-monomorphized `submit`.
pub fn spawn_coroutine(entry: fn(*mut void) void, env: *mut void) {
    let s = ensure_started();
    // A recycled block brings its stack and context with it; only a cold spawn pays for an mmap. Its park
    // generation comes with it too, and deliberately does not restart: a token left over from the block's
    // previous life must stay behind the current one, or it could claim the task now using the block.
    let mut co = take_block(s);
    let mut stk: *mut void = null;
    let mut ctx: *mut void = null;
    let mut pst: u32 = 0;
    let mut slot: u32 = SLOT_NONE;
    let mut reuse_slot: *mut TaskSlot = null;
    let fresh = co == null;
    if fresh {
        let mut g = Global {};
        co = (unsafe g.alloc(sizeof(Coroutine), alignof(Coroutine))) as *mut Coroutine;
        stk = unsafe sc_runtime::sc_rt_stack_alloc(G_STACK_SIZE);
        ctx = unsafe sc_runtime::sc_rt_ctx_alloc();
    } else {
        stk = unsafe co.stack;
        ctx = unsafe co.ctx;
        pst = unsafe co.park_state;
        slot = unsafe co.slot;
        // Open the slot's next generation BEFORE the task fields are rewritten: a canceller validates its
        // key under the slot lock, so once the bump lands a stale key can no longer reach this block.
        reuse_slot = reg_reuse_lock(co);
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
        slot: slot,
        tstate: TS_RUNNABLE,
        cancel: CS_NONE,
        cancel_reason: CR_NONE,
        cancel_wake: 0,
        park_phase: pst & ~WR_MASK | PH_NOT_PARKING,
        park_cancellable: 0,
        cmask: 0,
        wait_kind: WK_NONE,
        wait_obj: 0,
        handoff: 0,
        unwound: 0,
    };
    if fresh {
        reg_assign(co);
    } else if reuse_slot != null {
        unsafe sc_runtime::sc_rt_spin_unlock(&mut reuse_slot.spin);
    }
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
    let co = (unsafe g.alloc(sizeof(Coroutine), alignof(Coroutine))) as *mut Coroutine;
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
        slot: SLOT_NONE,
        tstate: TS_RUNNABLE,
        cancel: CS_NONE,
        cancel_reason: CR_NONE,
        cancel_wake: 0,
        park_phase: 0,
        park_cancellable: 0,
        cmask: 0,
        wait_kind: WK_NONE,
        wait_obj: 0,
        handoff: 0,
        unwound: 0,
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
/// Has shutdown stopped the runtime from accepting new tasks?
pub fn closed() bool {
    return atomic::load_i32(&mut unsafe G_CLOSED, 1) != 0;
}

pub fn submit<F: fn move() + Send + 'static>(f: F) {
    if closed() {
        return; // shutdown has stopped accepting tasks; `f` and its captures are freed here
    }
    let mut g = Global {};
    let slot = (unsafe g.alloc(sizeof(F), alignof(F))) as *mut F;
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
    let t = (atomic::load_u32(p, 0) >> WR_BITS) + 1 << WR_BITS; // next generation, reason clear; wraps at width
    atomic::store_u32(p, t, 4); // SeqCst: a cancel claim reads this without holding the wait-queue lock
    atomic::store_u32(&mut unsafe co.park_phase, t | PH_PREPARING, 2);
    return t;
}

/// Suspend the current coroutine until woken, or until `deadline` (a `platform::now_ns()` value; 0 means
/// no timeout), and return the winning `WR_*` wake reason. Only valid from inside a coroutine
/// (`current() != null`).
///
/// The caller MUST, before calling: take a `park_begin` token, place a node carrying it on the primitive's
/// wait queue, and hold the lock guarding that queue -- `commit(arg)` releases that lock once the context is
/// saved (`commit_nop`/`null` when there is none), which is what keeps a waker from resuming a coroutine
/// that is still switching out. On return the lock is NOT held; the caller must re-acquire it, call
/// `cancel_timer` if the wait was timed, unlink its node, and re-check its condition (or, on a cancel
/// reason, follow the wait cleanup contract: timer, lock, unlink, metadata, then `cancel_accept`).
///
/// `cancellable` opts the park into the cancellation wake. A cancel claim is possible only when it is set
/// AND the task's cancel mask is clear AND cleanup has not already started; the wait that sets it promises
/// that a `WR_CANCEL`/`WR_SHUTDOWN` return leaves no registration behind.
pub fn park_timed(token: u32, deadline: u64, commit: fn(*mut void) void, arg: *mut void, cancellable: bool) u32 {
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
    let c = cancellable && unsafe co.cmask == 0 && atomic::load_i32(&mut unsafe co.cancel, 0) != CS_ACCEPTED;
    atomic::store_i32(
        &mut unsafe co.park_cancellable,
        if c {
            1;
        } else {
            0;
        },
        2,
    );
    unsafe co.commit_fn = commit;
    unsafe co.commit_arg = arg;
    unsafe co.deadline = deadline;
    unsafe co.tm_token = token;
    atomic::store_u32(&mut unsafe co.park_phase, token | PH_SWITCHING, 2);
    unsafe sc_runtime::sc_rt_ctx_switch(co.ctx, co.sched_ctx);
    // Back: exactly one waker claimed `token`, and wrote its reason before the enqueue that ran us -- so
    // the reason is stable until the next park_begin.
    let reason = atomic::load_u32(&mut unsafe co.park_state, 1) & WR_MASK;
    atomic::store_u32(&mut unsafe co.park_phase, token | PH_RESUMING, 0);
    atomic::store_i32(&mut unsafe co.park_cancellable, 0, 0);
    return reason;
}

/// `park_timed` with no deadline: park until woken, and return the winning wake reason.
pub fn park_current(token: u32, commit: fn(*mut void) void, arg: *mut void, cancellable: bool) u32 {
    return park_timed(token, 0, commit, arg, cancellable);
}

/// The current park is fully over: registrations removed, wait metadata cleared. Diagnostics only.
pub fn park_done(co: *mut Coroutine) {
    let t = atomic::load_u32(&mut unsafe co.park_state, 0) & ~WR_MASK;
    atomic::store_u32(&mut unsafe co.park_phase, t | PH_NOT_PARKING, 0);
}

/// Resume the park `token` identifies with a notify wake, and report whether this call is the one that did
/// it. Exactly one waker wins per park, so a notify racing a timeout can never enqueue a coroutine twice;
/// `false` means the wakeup was not consumed (the token is stale, or another waker got there first) and
/// should go to the next waiter. Safe to call while holding the primitive's wait-queue lock (it takes only
/// the scheduler's lock, always in that order).
pub fn wake(co: *mut Coroutine, token: u32) bool {
    return wake_as(co, token, WR_NOTIFY);
}

/// `wake`, claiming with an explicit `WR_*` reason (the reactor claims `WR_IO`, blocking completion claims
/// `WR_BLOCKING`). The parked task reads the reason back from `park_timed`.
pub fn wake_as(co: *mut Coroutine, token: u32, reason: u32) bool {
    if !claim(co, token, reason) {
        return false;
    }
    if tracing() {
        trace("wake", unsafe co.id);
    }
    enqueue_runnable(unsafe G_SCHED, co);
    return true;
}

/// Drop `co`'s pending timer, if its wait was timed and it was woken before the deadline. Call after every
/// `park_until` with a deadline, before the coroutine can park again -- a stale timer entry would otherwise
/// resume a running coroutine.
pub fn cancel_timer(co: *mut Coroutine) {
    let s = unsafe G_SCHED;
    if s == null {
        return;
    }
    unsafe sc_runtime::sc_rt_mutex_lock(s.lock);
    disarm_timer(s, co);
    unsafe sc_runtime::sc_rt_mutex_unlock(s.lock);
}

// --- cancellation --------------------------------------------------------------------------------------

/// Request cancellation of the task `key` names, with a `CR_*` reason. Idempotent: the first request's
/// reason is retained and later requests change nothing. Reports whether the key still named a live task.
/// Delivery is cooperative: a task parked in a cancellable wait is woken through the single-winner park
/// claim; a running (or non-cancellably parked) task observes the request at its next cancellation point.
pub fn request_cancel(key: TaskKey, reason: u32) bool {
    return request_cancel_wake(key, reason, WR_CANCEL);
}

// `request_cancel` with an explicit claim reason: shutdown claims with `WR_SHUTDOWN`.
fn request_cancel_wake(key: TaskKey, reason: u32, wr: u32) bool {
    if key.slot == SLOT_NONE || unsafe G_REG == null {
        return false;
    }
    let r = unsafe G_REG;
    if key.slot as usize >= atomic::load_usize(&mut unsafe r.len, 1) {
        return false;
    }
    let sl = reg_slot(r, key.slot as usize);
    // The slot lock orders this request against block reuse: `reg_reuse` bumps the generation under it
    // before the block's task fields are rewritten, so a stale key can never mark the slot's next task.
    unsafe sc_runtime::sc_rt_spin_lock(&mut sl.spin);
    let co = unsafe sl.co;
    let mut live = co != null;
    if live {
        live = atomic::load_u32(&mut unsafe sl.gen, 0) == key.gen;
    }
    if live {
        live = atomic::load_i32(&mut unsafe co.tstate, 1) != TS_COMPLETED;
    }
    if live {
        request_cancel_co(co, reason, wr);
    }
    unsafe sc_runtime::sc_rt_spin_unlock(&mut sl.spin);
    return live;
}

// The request core, given the coroutine itself. `wr` is the wake reason a park claim will carry.
fn request_cancel_co(co: *mut Coroutine, reason: u32, wr: u32) {
    let _ = atomic::cas_u32(&mut unsafe co.cancel_reason, CR_NONE, reason, false, 4, 0);
    let _ = atomic::cas_u32(&mut unsafe co.cancel_wake, 0, wr, false, 4, 0);
    if !atomic::cas_i32(&mut unsafe co.cancel, CS_NONE, CS_REQUESTED, false, 4, 0) {
        return; // already requested, accepted or finished
    }
    if tracing() {
        trace("cancel requested", unsafe co.id);
    }
    cancel_nudge(co);
}

// Try to win the task's current park with the cancel wake. Failing is fine: the Requested flag is sticky,
// the park hand-off re-checks it after publishing Parked, and every cancellation point observes it -- so a
// request can be delayed but never lost. The retry bound is real: each retry means the task completed a
// park transition under us, and after 64 of them the flag alone is the delivery.
fn cancel_nudge(co: *mut Coroutine) {
    let mut looks: i32 = 0;
    while looks < 64 {
        looks = looks + 1;
        let ps = atomic::load_u32(&mut unsafe co.park_state, 4);
        if (ps & WR_MASK) != 0 {
            if tracing() {
                trace("cancel wake lost to another waker", unsafe co.id);
            }
            return; // this park already has a winner; the wait exit observes the flag
        }
        let ph = atomic::load_u32(&mut unsafe co.park_phase, 4);
        if ph == (ps | PH_PARKED) {
            if atomic::load_i32(&mut unsafe co.park_cancellable, 1) == 0 {
                return; // a masked or non-cancellable wait: report it, never force it
            }
            let wr = atomic::load_u32(&mut unsafe co.cancel_wake, 1);
            if claim(co, ps, wr) {
                if tracing() {
                    trace("cancel wake won", unsafe co.id);
                }
                enqueue_runnable(unsafe G_SCHED, co);
                return;
            }
            continue; // lost the claim race: re-read who won
        }
        if ph >> WR_BITS != ps >> WR_BITS {
            continue; // a park transition is in flight: look again
        }
        return; // not parked: the next cancellation point or park commit sees the flag
    }
}

/// Is a cancellation request pending (not yet accepted) for the current task?
pub fn cancel_requested() bool {
    let co = current();
    if co == null {
        return false;
    }
    return atomic::load_i32(&mut unsafe co.cancel, 1) == CS_REQUESTED;
}

/// Has the current task accepted cancellation? From acceptance to completion the task is in cleanup:
/// every wait it enters parks non-cancellably, and its callers must unwind rather than continue.
pub fn cancelling() bool {
    let co = current();
    if co == null {
        return false;
    }
    return atomic::load_i32(&mut unsafe co.cancel, 1) == CS_ACCEPTED;
}

/// Accept a pending cancellation for the current task. The wait cleanup contract calls this LAST -- after
/// the timer is cancelled, registrations are unlinked, guards are settled and wait metadata is cleared.
/// Idempotent. `pub` for the task-aware primitives; user code uses `cancel_point`.
pub fn cancel_accept() {
    let co = current();
    if co == null {
        return;
    }
    if atomic::cas_i32(&mut unsafe co.cancel, CS_REQUESTED, CS_ACCEPTED, false, 4, 0) {
        if tracing() {
            trace("cleanup begin", unsafe co.id);
        }
    }
}

/// Read-only form of the wait-exit acceptance test: is an unmasked request pending (or already
/// accepted) for the current task? Wait internals that must not syntactically reach `cancel_accept`
/// (the cancel-mark seed) test this and leave the acceptance to their cancellable wrapper.
pub fn cancel_pending() bool {
    let co = current();
    if co == null || unsafe co.cmask != 0 {
        return false;
    }
    let c = atomic::load_i32(&mut unsafe co.cancel, 1);
    return c == CS_REQUESTED || c == CS_ACCEPTED;
}

/// Accept a request after a cancellable wait has removed every external registration. Returns true when
/// cleanup must start. This also covers a request that arrived during `Resuming` after another wake reason
/// won the park token.
pub fn cancel_after_wait(cancellable: bool) bool {
    if !cancellable {
        return false;
    }
    let co = current();
    if co == null || unsafe co.cmask != 0 {
        return false;
    }
    if atomic::load_i32(&mut unsafe co.cancel, 1) == CS_REQUESTED {
        cancel_accept();
    }
    return atomic::load_i32(&mut unsafe co.cancel, 1) == CS_ACCEPTED;
}

/// The compiled cancellation-edge probe, inserted by the compiler after a call that can reach
/// cancellation acceptance; user code never calls it. Returns:
///   0 -- continue normally (no accepted cancellation, or off a task, or masked).
///   1 -- the callee itself returned through its cancellation ladder: its result is POISON (a zero
///        the callee never constructed) and must be abandoned, never freed.
///   2 -- the callee returned a real value but the task has accepted cancellation: the caller must
///        take ownership of the result (its cleanup frees it) and unwind.
pub fn cancel_probe() i32 {
    // A PURE read: the backend may evaluate a probe more than once per check, so the poison flag is
    // consumed by `cancel_ladder_begin`, never here.
    let co = current();
    if co == null {
        return 0;
    }
    if unsafe co.unwound != 0 {
        return 1;
    }
    if unsafe co.cmask != 0 {
        return 0;
    }
    if atomic::load_i32(&mut unsafe co.cancel, 1) == CS_ACCEPTED {
        return 2;
    }
    return 0;
}

/// Open a compiled cancellation ladder: consume the callee's poison flag and MASK cleanup from here
/// (a wait inside a defer or a destructor parks non-cancellably and no nested edge fires).
/// Compiler-inserted; never call it.
pub fn cancel_ladder_begin() {
    let co = current();
    if co == null {
        return;
    }
    unsafe co.unwound = 0;
    unsafe co.cmask = unsafe co.cmask + 1;
}

/// Close a compiled cancellation ladder: lift the cleanup mask and hand the edge to the caller (its
/// probe reads the returned value as poison). Compiler-inserted; never call it.
pub fn cancel_ladder_end() {
    let co = current();
    if co == null {
        return;
    }
    unsafe co.cmask = unsafe co.cmask - 1;
    unsafe co.unwound = 1;
}

// The combined safepoint's cancellation tick (rt_c's `__sc_cancel_tick`): `cancel_point` behind
// the C hook ABI. Runs on a safepoint's cold half only.
fn cancel_safepoint_tick() i32 {
    if cancel_point() {
        return 1;
    }
    return 0;
}

/// An explicit cancellation point. Accepts a pending request when the task is unmasked, and reports
/// whether the task is cancelling -- a `true` return means the caller must stop its work and return
/// through its cleanup.
pub fn cancel_point() bool {
    let co = current();
    if co == null {
        return false;
    }
    if unsafe co.cmask != 0 {
        return false;
    }
    if atomic::load_i32(&mut unsafe co.cancel, 1) == CS_REQUESTED {
        cancel_accept();
    }
    return atomic::load_i32(&mut unsafe co.cancel, 1) == CS_ACCEPTED;
}

/// Enter a cancellation-masked region: parks inside it are never claimed by a cancel wake and
/// `cancel_point` is inert. Foreign and otherwise non-cancellable calls run under a mask. Re-entrant.
pub fn cancel_mask_enter() {
    let co = current();
    if co == null {
        return;
    }
    unsafe co.cmask = unsafe co.cmask + 1;
}

/// Leave a cancellation-masked region. A pending request is then observed at the next cancellation point.
pub fn cancel_mask_exit() {
    let co = current();
    if co == null {
        return;
    }
    // A panic, not an assert: demanded std code must not embed source paths (the fixpoint compares
    // emissions whose std roots differ).
    if unsafe co.cmask <= 0 {
        panic("cancel_mask_exit without a matching cancel_mask_enter");
    }
    unsafe co.cmask = unsafe co.cmask - 1;
}

/// Record what the current task is about to wait on, for diagnostics and shutdown reports.
pub fn wait_note(kind: i32, obj: usize) {
    let co = current();
    if co == null {
        return;
    }
    atomic::store_i32(&mut unsafe co.wait_kind, kind, 0);
    atomic::store_usize(&mut unsafe co.wait_obj, obj, 0);
}

/// Clear the current task's wait record (step 6 of the wait cleanup contract: metadata is cleared before
/// cancellation propagates).
pub fn wait_clear() {
    let co = current();
    if co == null {
        return;
    }
    atomic::store_i32(&mut unsafe co.wait_kind, WK_NONE, 0);
    atomic::store_usize(&mut unsafe co.wait_obj, 0, 0);
}

/// Completions that were accepted cancellations (the task was reclaimed rather than finishing normally).
pub fn cancelled_tasks() usize {
    return atomic::load_usize(&mut unsafe G_CANCELLED, 1);
}

/// Suspend for `ns` nanoseconds. A coroutine parks on the scheduler's timer list, so its worker keeps
/// running other tasks; any other thread sleeps outright. `std::parallel::time::sleep` is the friendly form.
pub fn sleep_ns(ns: i64) {
    if ns <= 0 {
        return;
    }
    let co = current();
    if co == null {
        // A plain thread about to stop making progress is exactly when replay mode must hand the pool the
        // CPU. Not a nicety: `select` on a plain thread waits by POLLING through here rather than on a
        // condvar, so without this the gate stays shut, whatever the select is waiting for never runs, and
        // the wait times out -- a program that behaves differently under replay, which defeats the point.
        replay_release();
        unsafe sc_runtime::sc_rt_sleep_ns(ns);
        return;
    }
    wait_note(WK_SLEEP, 0);
    let token = park_begin(co); // on no wait queue: the timer and a cancel are the only wakers
    let _ = park_timed(token, platform::now_ns() + ns as u64, commit_nop, null, true);
    cancel_timer(co);
    wait_clear();
    park_done(co);
    let _ = cancel_after_wait(true);
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
    return atomic::load_u64(&mut unsafe G_NEXT_ID, 1) as usize;
}

/// Tasks that have run to completion.
pub fn completed_tasks() usize {
    return atomic::load_usize(&mut unsafe G_DONE, 1);
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
    if atomic::load_i32((&mut unsafe G_STATE) as *mut i32, 1) == 2 {
        return; // the running pool's stacks are already allocated
    }
    if bytes == 0 {
        unsafe G_STACK_SIZE = STACK_SIZE_DEFAULT;
        return;
    }
    let unit: usize = 65536;
    unsafe G_STACK_SIZE = (bytes + unit - 1) / unit * unit;
}

pub fn set_worker_count(n: usize) {
    unsafe G_NWORKERS = n;
}

/// Turn on deterministic replay: one worker, and every preemption point decided by `seed` alone. Two runs of
/// the same binary with the same seed take the same interleaving, so a race caught once can be re-run instead
/// of chased; a different seed takes a different one, so seeds are also how the interleaving space is swept.
/// A seed of 0 turns the mode off. Must be called before the pool starts, and it overrides
/// `set_worker_count`.
///
/// What it does NOT make deterministic: the wall clock (`sleep`, timed waits), the reactor's I/O readiness,
/// the `@blocking` pool, and OS threads from `thread::spawn`. Those are concurrent with the worker rather
/// than scheduled by it, so a program that depends on them replays only as far as they agree.
pub fn set_deterministic(seed: u64) {
    if atomic::load_i32((&mut unsafe G_STATE) as *mut i32, 1) == 2 {
        return; // the pool is already running with whatever it resolved at build time
    }
    unsafe G_SEED = seed;
}

/// The replay seed in force, or 0 when the scheduler is running normally.
pub fn deterministic_seed() u64 {
    return unsafe G_SEED;
}

// The seed the pool will run with. `SC_SCHED_SEED` is read only when the program set none itself, which is
// what lets a race found in a shipped binary be replayed without rebuilding it.
fn resolve_seed() u64 {
    if unsafe G_SEED != 0 {
        return unsafe G_SEED;
    }
    let p = stdlib::getenv("SC_SCHED_SEED");
    if p == null {
        return 0;
    }
    return switch str::from_cstr(p).parse_u64() {
        Some(v) => v,
        None => 0u64,
    };
}

/// How many worker threads the pool has (or will have): the configured count, else one per CPU. What the
/// data-parallel API divides its work by.
pub fn worker_count() usize {
    if unsafe G_NWORKERS > 0 {
        return unsafe G_NWORKERS;
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
    let s = unsafe G_SCHED;
    if s == null {
        return;
    }
    let wi = unsafe sc_runtime::sc_rt_widx_get();
    if wi < 0 || wi as usize >= unsafe s.nw {
        return;
    }
    // The yield queue counts as runnable work. Leaving it out stops preemption dead once every task on this
    // worker has yielded once -- they all sit there, the ring reads empty, and the task holding the CPU is
    // never asked to give it up again.
    let wp = unsafe (s.deques + wi as usize);
    if dq_empty(wp) && unsafe wp.ylen == 0 && atomic::load_i32(&mut unsafe s.inj_len, 1) == 0 {
        return;
    }
    // Replay mode: the seed, not the timing, says whether this safepoint switches. The generator is plain
    // (not atomic) because deterministic mode runs exactly one worker and only that worker reaches here --
    // a plain thread and a `@blocking` job both left above, having no coroutine to park.
    if unsafe G_SEED != 0 {
        let mut x = unsafe G_DET;
        x = x ^ x << 13;
        x = x ^ x >> 7;
        x = x ^ x << 17;
        unsafe G_DET = x;
        if (x >> 33 & 3) == 0 {
            return; // this seed leaves the task running here
        }
    }
    yield_now();
}

/// Cooperatively yield: reschedule the current coroutine behind the others. A no-op off a worker thread.
pub fn yield_now() {
    let co = current();
    if co == null {
        return;
    }
    let t = park_begin(co); // retire the current token: nothing may wake a coroutine the worker requeues
    unsafe co.commit_requeue = 1;
    unsafe sc_runtime::sc_rt_ctx_switch(co.ctx, co.sched_ctx);
    atomic::store_u32(&mut unsafe co.park_phase, t | PH_NOT_PARKING, 0); // a yield is not a park
}

/// The default `shutdown` grace period: how long cancelled tasks get to run their cleanup.
pub const SHUTDOWN_GRACE_NS: u64 = 1000000000;

/// Bounded-shutdown policy for `try_shutdown`.
pub struct ShutdownOptions {
    pub grace_ns: u64, // how long to wait for cancelled tasks to finish cleanup
    pub report_unresponsive: bool, // print a stable per-task report for what did not finish
    pub abort_on_unresponsive: bool, // abort the process instead of returning an unresponsive result
}

/// What a shutdown attempt achieved. `unresponsive > 0` means the runtime was NOT destroyed: those tasks
/// keep their stacks, and the caller may wait longer, report, or terminate the process.
pub struct ShutdownResult {
    pub completed: usize,
    pub cancelled: usize,
    pub unresponsive: usize,
}

extend ShutdownOptions {
    /// The `shutdown()` defaults, minus the abort: default grace, report unresponsive tasks, return.
    pub fn defaults() ShutdownOptions {
        return ShutdownOptions { grace_ns: SHUTDOWN_GRACE_NS, report_unresponsive: true, abort_on_unresponsive: false };
    }
}

// A stable name for a wait kind, for the unresponsive-task report.
fn wk_name(kind: i32) str<'static> {
    if kind == WK_MUTEX {
        return "mutex";
    }
    if kind == WK_CONDVAR {
        return "condvar";
    }
    if kind == WK_CHANNEL_SEND {
        return "channel send";
    }
    if kind == WK_CHANNEL_RECV {
        return "channel recv";
    }
    if kind == WK_SELECT {
        return "select";
    }
    if kind == WK_SLEEP {
        return "sleep";
    }
    if kind == WK_IO {
        return "io";
    }
    if kind == WK_BLOCKING {
        return "blocking call";
    }
    if kind == WK_WAIT_GROUP {
        return "wait group";
    }
    if kind == WK_SEMAPHORE {
        return "semaphore";
    }
    if kind == WK_BARRIER {
        return "barrier";
    }
    if kind == WK_RWLOCK {
        return "rwlock";
    }
    return "none";
}

// One stable line per unresponsive task, in ascending task-ID order (never worker completion order).
fn report_unresponsive(tasks: &mut Vector<TaskInfo>) {
    // Insertion sort by task ID: the report is small and the order contract matters more than the sort.
    for i in 1..tasks.len() {
        let mut j = i;
        while j > 0 && tasks.at(j - 1).id > tasks.at(j).id {
            tasks.swap(j - 1, j);
            j = j - 1;
        }
    }
    eprintln("super-c: {} unresponsive task(s) at shutdown (stacks kept allocated):", tasks.len());
    for i in 0..tasks.len() {
        let t = tasks.at(i);
        let why = if t.cancel == CS_ACCEPTED {
            "cleaning";
        } else if t.masked {
            "wait is not cancellable";
        } else if t.cancel == CS_REQUESTED {
            "cancellation not yet accepted";
        } else {
            "running";
        };
        eprintln(
            "  task {} (slot {} gen {}): waiting on {} ({}); {}",
            t.id,
            t.key.slot,
            t.key.gen,
            wk_name(t.wait_kind),
            t.wait_obj,
            why,
        );
    }
}

// Tear the pool down: drain the workers, join them, and free every scheduler structure. Callable only
// once every task has completed -- nothing may still refer to a task stack or the scheduler.
fn destroy_pool(sp: *mut i32, s: *mut Scheduler) {
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
    reg_free(); // after pool_drain: releasing a block retires its registry slot
    let mut g = Global {};
    for i in 0..unsafe s.nw {
        unsafe g.dealloc(unsafe (s.deques + i).buf, DEQUE_CAP * sizeof(*mut Coroutine), alignof(*mut Coroutine));
    }
    unsafe g.dealloc(unsafe s.deques, unsafe s.nw * sizeof(Worker), LINE);
    for i in 0..unsafe s.nw {
        let pk = unsafe (s.parkers + i);
        unsafe sc_runtime::sc_rt_mutex_free(pk.mtx);
        unsafe sc_runtime::sc_rt_cond_free(pk.cv);
    }
    unsafe g.dealloc(unsafe s.parkers, unsafe s.nw * sizeof(Parker), LINE);
    unsafe g.dealloc(unsafe s.idle, unsafe s.idle_words * sizeof(u64), alignof(u64));
    unsafe sc_runtime::sc_rt_mutex_free(s.lock);
    unsafe g.dealloc(s, sizeof(Scheduler), alignof(Scheduler));
    atomic::store_i32(&mut unsafe G_CLOSED, 0, 2);
    atomic::store_i32(sp, 0, 2);
    unsafe G_SCHED = null;
}

/// Bounded, safe shutdown. In order: stop accepting new tasks, snapshot the registry, request `Shutdown`
/// cancellation for every live task (waking safely parked ones through their current park generation),
/// keep the workers running cleanup, and wait until everything completes or `grace_ns` expires. Only when
/// no task remains is the scheduler destroyed. Otherwise the runtime stays fully alive -- an unresponsive
/// task keeps its stack, and the caller may wait longer, report, or exit the process.
///
/// Call from outside the pool (the main thread), after `io::shutdown()` and `blocking::shutdown()` if the
/// program started them: the reactor and blocking pool must outlive the tasks parked on them.
pub fn try_shutdown(opts: ShutdownOptions) ShutdownResult {
    let mut res = ShutdownResult { completed: 0, cancelled: 0, unresponsive: 0 };
    let sp = (&mut unsafe G_STATE) as *mut i32;
    if atomic::load_i32(sp, 1) != 2 {
        return res; // never started, or already destroyed
    }
    if current() != null {
        panic("try_shutdown must be called from outside the pool");
    }
    let s = unsafe G_SCHED;
    // 1. Stop accepting new tasks before anything is cancelled or counted.
    atomic::store_i32(&mut unsafe G_CLOSED, 1, 4);
    // 2. A stable snapshot of every live registered task.
    let base_cancelled = cancelled_tasks();
    let mut snap = Vector::<TaskInfo>::new();
    task_snapshot(&mut snap);
    // 3-5. Request Shutdown cancellation. Already completed tasks fail the key check and retire normally.
    for i in 0..snap.len() {
        let key = snap.at(i).key;
        let _ = request_cancel_wake(key, CR_SHUTDOWN, WR_SHUTDOWN);
    }
    // 6-9. Workers keep running cleanup; wait for full completion or the deadline. Timers, reactor
    // interests and blocking-job sides are removed by each cancelled task through its own wait cleanup.
    let deadline = platform::now_ns() + opts.grace_ns;
    while live_tasks() > 0 && platform::now_ns() < deadline {
        sleep_ns(200000);
    }
    res.cancelled = cancelled_tasks() - base_cancelled;
    let left = live_tasks();
    if snap.len() >= left + res.cancelled {
        res.completed = snap.len() - left - res.cancelled;
    }
    if left == 0 {
        // 10-12. Nothing can refer to a task stack any more: destroy workers, registry and scheduler.
        destroy_pool(sp, s);
        return res;
    }
    res.unresponsive = left;
    if opts.report_unresponsive {
        let mut stuck = Vector::<TaskInfo>::new();
        task_snapshot(&mut stuck);
        report_unresponsive(&mut stuck);
    }
    if opts.abort_on_unresponsive {
        unsafe stdlib::abort();
    }
    return res;
}

/// The simple process-exit shutdown: `try_shutdown` with the default grace period. All launched work
/// should have been awaited first. If an unresponsive task remains, its stack cannot be safely freed and
/// the scheduler cannot be safely destroyed -- the report above names it, and the process aborts rather
/// than run on over a runtime it can no longer release. Idempotent; a no-op if the pool never started.
pub fn shutdown() {
    let mut opts = ShutdownOptions::defaults();
    opts.abort_on_unresponsive = true;
    let _ = try_shutdown(opts);
}
