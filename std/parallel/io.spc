// The reactor: park a coroutine on a file descriptor instead of a thread. Import with
// `import std::parallel::io;`.
//
//     io::wait_readable(fd);              // this worker runs other tasks meanwhile
//     let n = io::read(fd, buf);          // reads, parking whenever the descriptor is not ready
//
// `blocking::call` makes a blocking call SAFE by moving it to a thread that is allowed to block, which
// costs a thread per concurrent operation. This costs a registration instead: one reactor thread runs the
// platform poller (kqueue, epoll or select) and turns readiness into a wake, so ten thousand tasks waiting
// on ten thousand descriptors are ten thousand parked coroutines and one thread.
//
// Ownership is what makes it safe. The reactor thread is the ONLY thread that touches the per-descriptor
// records and the waiter lists; every other thread talks to it through a command list. A wait is a node
// in the waiting task's own frame, linked into the record of its descriptor by the reactor and unlinked by
// the reactor before the task is woken, so nothing is allocated per wait and no reference to a frame
// outlives the frame. Waits carry the task's park token: the reactor claims it exactly like a timer or a
// cancellation does, and exactly one wake reason wins a park. The operating-system registration itself is
// idempotent and thread-safe, so the worker that publishes an arm also registers the interest: the
// readiness event is then what wakes the reactor, and an arm costs no wake of its own. The reactor
// registers again only where directions must be combined, or where an event found no waiter yet (the
// worker's one-shot may have fired before the reactor saw the node), and never removes an interest: a
// one-shot that fires is gone, a closed descriptor is gone, and an interest left by an expired wait fires
// at most once into an empty list.
//
// The reclamation argument. A frame can end only when `wait_until` returns, and it returns either because
// the reactor claimed the park with `WR_IO` (having already unlinked the node, its last touch) or, on any
// other wake reason, after a second park that the reactor ends by acknowledging the node's removal. The
// operating-system cookie is the descriptor number, not a pointer: an event that arrives for a descriptor
// whose waiters are gone finds an empty list. Records are indexed by descriptor number and never freed
// while the reactor runs, so no event batch can reach reclaimed storage. Read and write waits on one
// descriptor are two lists and one combined interest; several waiters in one direction are all woken by
// its event and each retries its operation. A descriptor number reused under a stale wait is registered
// afresh by the next arm, so the new descriptor's waiter fires; the stale waiter's wake is spurious, which
// the wait contract allows. A close reported through `io::close` (every `net` handle does) is stronger:
// the record's generation moves on, its waiters settle as not ready at once, and an arm whose
// registration raced the close registers again and fails.
//
// Readiness-based on every platform. Windows watches SOCKETS ONLY: a socket is not a CRT file descriptor
// there, and its select() backend caps the simultaneously parked descriptors at FD_SETSIZE; arming past
// that reports the wait as not ready rather than silently dropping it.

import sc_runtime;
import atomic;
import sc_io;
import std::parallel::runtime as runtime;
import std::parallel::time as time;

// Interest and readiness bits, as the poller spells them; `CLOSE` marks a command node that reports a
// closed descriptor rather than a wait.
const CLOSE: i32 = 0;
const RD: i32 = 1;
const WR: i32 = 2;
// Descriptor numbers the record table may grow to hold: a wait past it is a programmer error.
const REC_MAX: usize = 4194304;
// First record table: enough for a small program without a resize.
const REC_INIT: usize = 64;
// `IoWait.state`, written by the reactor once the node is published.
const NS_NEW: i32 = 0; // filled by the task, not yet processed
const NS_ARMED: i32 = 1; // linked in its record's list
const NS_FIRED: i32 = 2; // unlinked: an event, a failure or shutdown settled it
const NS_CANCELLED: i32 = 3; // its disarm arrived before its arm: acknowledged when the arm does
// Compile-time switch for the reactor counters: `io_stats()` reads them; off, nothing is counted.
const IO_STATS: bool = false;

/// Is the reactor compiled with its counters? A `const fn`, so the emitter folds every `if` on it.
pub const fn io_stats_on() bool {
    return IO_STATS;
}

/// Reactor counters (all process-lifetime, summed over reactors started and stopped), zero unless
/// `IO_STATS` is on.
pub struct IoStats {
    pub arms: u64, // arm commands processed
    pub disarms: u64, // disarm commands processed (timeouts, cancellations, shutdown)
    pub sets: u64, // poller registration calls (by workers and by the reactor)
    pub polls: u64, // blocking poller waits
    pub events: u64, // readiness events received
    pub wakes: u64, // park claims won by readiness
    pub pipe_wakes: u64, // wake-pipe writes by command pushers
    pub batches: u64, // wake chains handed to the scheduler
    pub stale: u64, // events that found no waiter (a later arm in that direction registers again)
    pub records: u64, // records the table holds now (its retained memory is this times the record size)
}

// A pending wait: lives in the waiting task's frame (see the reclamation argument above). The task fills it
// and publishes it through the park hand-off; from then on only the reactor reads or writes it, except
// `ack`, which the task writes before publishing its disarm and the reactor reads after popping that.
@no_const
struct IoWait {
    pub co: *mut runtime::Coroutine,
    pub token: u32, // the wait's park token: what a readiness event claims
    pub ack: u32, // the acknowledgement park's token: what the disarm's completion claims
    pub fd: i32,
    pub dir: i32, // RD or WR
    pub state: i32, // NS_*
    pub rc: i32, // the worker's registration result: 0 registered, 1 always ready, -1 failed
    pub gen: u32, // the record's generation when this node was linked: see `FdRec.gen`
    pub anext: usize, // command-list link while the arm command is queued (tagged, see `push_cmd`)
    pub dnext: usize, // the same for the disarm command
    pub lnext: *mut IoWait, // the record's waiter list
}

// Command tags, in the low bit of a queued node pointer.
const CMD_ARM: usize = 0;
const CMD_DISARM: usize = 1;
const CMD_MASK: usize = 1;

// One descriptor's state: its waiters in each direction, whether the backend still holds a registration
// for it (epoll keeps a fired one-shot registration, disabled, until the descriptor closes), the
// directions whose last event found no waiter (`stale`: the next arm in such a direction registers again,
// because the one-shot the event consumed may have been that arm's own, registered by its worker before
// the reactor saw the node), and the record's generation: bumped by every close reported through
// `io::close`, so the number's next file starts a new generation, every waiter of the old one has been
// settled, and a node is only ever unlinked from the generation that linked it.
@no_const
struct FdRec {
    pub rd: *mut IoWait,
    pub wr: *mut IoWait,
    pub known: i32,
    pub stale: i32,
    pub gen: u32,
    pub pad: u32,
}

// A batch of poller events: `sc_io::EV_MAX` triples (descriptor, ready bits, dropped bits). Wrapped in a
// struct so it is zero-initialized: reading an uninitialized array is (rightly) rejected.
@no_const
struct EvBuf {
    pub e: [i32; 192],
}

// Line-aligned (see `reactor_alloc`), with the fields workers write and the fields the reactor reads on
// every event on separate lines: the command head takes a compare-and-swap from every worker that arms,
// and must not invalidate the line the reactor finds its poller and table on.
@no_const
struct Reactor {
    pub base: *mut void, // the allocation this line-aligned record lives in
    pub poller: *mut void,
    pub thread: *mut void,
    pub recs: *mut FdRec, // the record table, indexed by descriptor number; reactor-owned
    pub nrec: usize,
    pub deferred: i32, // acknowledgements waiting for an arm still on its way: see `do_disarm`
    pub pad4: i32,
    pub regs: *mut i32, // REG_SLOTS + 1 registration counters, one line each: see `G_CLOSING`
    pub pad0: Array<u64, 9>,
    pub cmds: usize, // atomic: the command list head, tagged with CMD_*, 0 when empty
    pub pad1: Array<u64, 15>,
    pub sleeping: i32, // atomic: the reactor is in, or about to enter, its blocking poll
    pub pad2: i32,
    pub pad3: Array<u64, 15>,
    pub st: IoStats,
}

const R_ALIGN: usize = 128; // the largest line any supported core has (Apple M-series L2)

// A chain of claimed tasks, linked through their run headers, handed to the scheduler in one operation.
@no_const
struct Batch {
    pub head: *mut runtime::Coroutine,
    pub tail: *mut runtime::Coroutine,
    pub n: i32,
}

static mut G_STATE: i32 = 0; // 0 uninit / 1 building / 2 ready / 3 stopping

static mut G_REACTOR: *mut Reactor = null;

// Threads inside `close` between reading the reactor state and publishing their report: a stopping
// reactor leaves only when this is zero, so no report is pushed onto a released reactor.
static mut G_CLOSERS: i32 = 0;

// Closes in progress: raised around every close(2) of a descriptor the reactor may hold, so that no
// registration overlaps it. On macOS a close that overlaps a concurrent registration of the same socket
// wedges both threads in the kernel for good (measured: every run of a registration racing a close),
// so a registering thread counts itself in (`reg_enter`), and a closer waits for every count to reach
// zero before it closes. Registering threads back off while a close is pending, so a close never waits
// for more than the registrations already under way.
static mut G_CLOSING: i32 = 0;
// Registration counters, one cache line per slot: slot 0 is the reactor thread, slot 1 + (worker index
// mod REG_SLOTS) a worker; sharing a slot is safe, it only makes two workers wait for each other's close.
const REG_SLOTS: usize = 64;

// Closes reported so far. A worker reads it before registering an interest and after publishing the arm:
// a change means a close raced the arm, whose event may never come and whose report the reactor may have
// processed already, so the arm needs the wake it otherwise does without (see `commit_arm`).
static mut G_CLOSES: u64 = 0;

static mut G_STATS: IoStats = IoStats {
    arms: 0,
    disarms: 0,
    sets: 0,
    polls: 0,
    events: 0,
    wakes: 0,
    pipe_wakes: 0,
    batches: 0,
    stale: 0,
    records: 0,
};

/// The reactor counters (see `IoStats`): the totals of every reactor stopped so far plus the running one.
pub fn io_stats() IoStats {
    let mut s = unsafe G_STATS;
    let r = unsafe G_REACTOR;
    if r != null && atomic::load_i32((&mut unsafe G_STATE) as *mut i32, 1) == 2 {
        // Relaxed reads of counters only the reactor thread writes: a snapshot, not a fence.
        s.arms = s.arms + atomic::load_u64(&mut unsafe r.st.arms, 0);
        s.disarms = s.disarms + atomic::load_u64(&mut unsafe r.st.disarms, 0);
        s.sets = s.sets + atomic::load_u64(&mut unsafe r.st.sets, 0);
        s.polls = s.polls + atomic::load_u64(&mut unsafe r.st.polls, 0);
        s.events = s.events + atomic::load_u64(&mut unsafe r.st.events, 0);
        s.wakes = s.wakes + atomic::load_u64(&mut unsafe r.st.wakes, 0);
        s.pipe_wakes = s.pipe_wakes + atomic::load_u64(&mut unsafe r.st.pipe_wakes, 0);
        s.batches = s.batches + atomic::load_u64(&mut unsafe r.st.batches, 0);
        s.stale = s.stale + atomic::load_u64(&mut unsafe r.st.stale, 0);
        s.records = atomic::load_u64(&mut unsafe r.st.records, 0);
    }
    return s;
}

/// Tasks inside an I/O wait (admitted or about to be, parked, or waiting for the reactor's
/// acknowledgement): zero once every task has left its wait. Diagnostics only; the count is a snapshot,
/// read from the task registry.
pub fn pending_waits() usize {
    return runtime::tasks_waiting(runtime::WK_IO);
}

fn stat_add(p: *mut u64, n: u64) {
    atomic::store_u64(p, atomic::load_u64(p, 0) + n, 0);
}

fn batch_add(b: &mut Batch, co: *mut runtime::Coroutine) {
    unsafe co.run.next = null;
    if b.tail == null {
        b.head = co;
    } else {
        unsafe b.tail.run.next = co as *mut runtime::Runnable;
    }
    b.tail = co;
    b.n = b.n + 1;
}

// Hand the batch to the scheduler. Every task in it holds a won claim, so none can run, complete or be
// woken by anyone else until this: the bounded flush delay is one command drain or one event batch.
fn batch_flush(r: *mut Reactor, b: &mut Batch) {
    if b.n == 0 {
        return;
    }
    if io_stats_on() {
        stat_add(&mut unsafe r.st.batches, 1);
    }
    runtime::run_claimed(b.head, b.tail, b.n);
    b.head = null;
    b.tail = null;
    b.n = 0;
}

// The record for `fd`, growing the table to reach it. Reactor thread only; nothing points into the table
// (waiters carry their descriptor number), so a resize moves nothing but the records.
fn rec_for(r: *mut Reactor, fd: i32) *mut FdRec {
    let i = fd as usize;
    if i >= unsafe r.nrec {
        if i >= REC_MAX {
            panic("reactor: descriptor number beyond the record table");
        }
        let mut cap = unsafe r.nrec;
        while cap <= i {
            cap = cap * 2;
        }
        let mut g = Global {};
        let t = (unsafe g.alloc(cap * sizeof(FdRec), alignof(FdRec))) as *mut FdRec;
        if t == null {
            panic("reactor: cannot grow the record table");
        }
        let old = unsafe r.recs;
        let n = unsafe r.nrec;
        for k in 0..n {
            unsafe t[k] = unsafe old[k];
        }
        for k in n..cap {
            unsafe t[k] = FdRec { rd: null, wr: null, known: 0, stale: 0, gen: 0, pad: 0 };
        }
        unsafe g.dealloc(old, n * sizeof(FdRec), alignof(FdRec));
        unsafe r.recs = t;
        unsafe r.nrec = cap;
        if io_stats_on() {
            atomic::store_u64(&mut unsafe r.st.records, cap as u64, 0);
        }
    }
    return unsafe (r.recs + i);
}

// Count this thread into its registration slot, backing off while a close is pending (see `G_CLOSING`).
// Returns the slot to leave through `reg_leave`.
fn reg_enter(r: *mut Reactor) *mut i32 {
    let wi = unsafe sc_runtime::sc_rt_widx_get();
    let slot = if wi < 0 {
        0usize;
    } else {
        1 + wi as usize % REG_SLOTS;
    };
    let f = unsafe (r.regs + slot * (R_ALIGN / 4));
    loop {
        let _ = atomic::add_i32(f, 1, 4);
        if atomic::load_i32(&mut unsafe G_CLOSING, 4) == 0 {
            return f;
        }
        let _ = atomic::sub_i32(f, 1, 4);
        while atomic::load_i32(&mut unsafe G_CLOSING, 4) != 0 {
            unsafe sc_runtime::sc_rt_cpu_relax();
        }
    }
}

fn reg_leave(f: *mut i32) {
    let _ = atomic::sub_i32(f, 1, 2);
}

// Register `want` in `fd` from any thread, excluded against closes: 0 done, 1 always ready, -1 failed.
fn register(r: *mut Reactor, fd: i32, want: i32, known: i32) i32 {
    let f = reg_enter(r);
    let rc = unsafe sc_io::sc_io_set(r.poller, fd, want, known);
    reg_leave(f);
    return rc;
}

// Add `want` to the poller's interest in `fd`: 0 done, 1 the descriptor is always ready, -1 failed.
fn set_interest(r: *mut Reactor, fd: i32, rec: *mut FdRec, want: i32) i32 {
    if io_stats_on() {
        stat_add(&mut unsafe r.st.sets, 1);
    }
    let rc = register(r, fd, want, unsafe rec.known);
    if rc == 0 {
        unsafe rec.known = 1;
    }
    return rc;
}

fn list_of(rec: *mut FdRec, dir: i32) *mut *mut IoWait {
    if dir == RD {
        return &mut unsafe rec.rd;
    }
    return &mut unsafe rec.wr;
}

// Wake every waiter of one list with `reason` and empty it. A claim lost to a timeout or a cancellation
// leaves the task to send its disarm; a claim won ends the wait here.
fn fire_list(r: *mut Reactor, head: *mut *mut IoWait, reason: u32, b: &mut Batch) {
    let mut n = unsafe head[0];
    unsafe head[0] = null;
    while n != null {
        let next = unsafe n.lnext;
        unsafe n.state = NS_FIRED;
        // The last touch of `n`: on a won claim the frame may end as soon as the batch is flushed.
        if runtime::claim_wake(unsafe n.co, unsafe n.token, reason) {
            batch_add(b, unsafe n.co);
            if reason == runtime::WR_IO && io_stats_on() {
                stat_add(&mut unsafe r.st.wakes, 1);
            }
        }
        n = next;
    }
}

// Settle one node outside any list: wake it with `reason`; a lost claim leaves it to the disarm.
fn settle_node(n: *mut IoWait, reason: u32, b: &mut Batch) {
    unsafe n.state = NS_FIRED;
    if runtime::claim_wake(unsafe n.co, unsafe n.token, reason) {
        batch_add(b, unsafe n.co);
    }
}

// Acknowledge a disarm: the wait is over for the reactor, and the task's frame may end.
fn ack(n: *mut IoWait, b: &mut Batch) {
    unsafe n.state = NS_FIRED;
    // The acknowledgement park is untimed and non-cancellable: this claim is its only waker.
    if !runtime::claim_wake(unsafe n.co, unsafe n.ack, runtime::WR_IO) {
        panic("reactor: the acknowledgement park has exactly one waker");
    }
    batch_add(b, unsafe n.co);
}

// An arm command. The worker registered the interest itself before publishing (see `commit_arm`) and
// left the result in the node: a descriptor the poller cannot watch is always ready (the task retries
// its syscall at once); a real failure (a closed descriptor, the platform's registration limit) reports
// the wait as not ready. Otherwise the waiter is linked, and the reactor registers again only where it
// must: when the direction's last event found no waiter (the worker's one-shot may have been consumed
// before this node was seen), or when the other direction has waiters too, so that a backend with one
// registration per descriptor (epoll) carries both whichever registration landed last.
fn do_arm(r: *mut Reactor, n: *mut IoWait, b: &mut Batch) {
    if unsafe n.dir == CLOSE {
        do_close(r, n);
        return;
    }
    if io_stats_on() {
        stat_add(&mut unsafe r.st.arms, 1);
    }
    if unsafe n.state == NS_CANCELLED {
        // A deadline beat this arm's publication and the disarm is already waiting for it.
        unsafe r.deferred = unsafe r.deferred - 1;
        ack(n, b);
        return;
    }
    if atomic::load_i32((&mut unsafe G_STATE) as *mut i32, 4) == 3 {
        // Shutting down: the wait is settled as not ready; its disarm follows and is acknowledged.
        settle_node(n, runtime::WR_TIMEOUT, b);
        return;
    }
    if unsafe n.rc != 0 {
        settle_node(
            n,
            if unsafe n.rc > 0 {
                runtime::WR_IO;
            } else {
                runtime::WR_TIMEOUT;
            },
            b,
        );
        return;
    }
    let fd = unsafe n.fd;
    let dir = unsafe n.dir;
    let rec = rec_for(r, fd);
    let head = list_of(rec, dir);
    unsafe n.lnext = unsafe head[0];
    unsafe head[0] = n;
    unsafe n.state = NS_ARMED;
    unsafe n.gen = unsafe rec.gen;
    unsafe rec.known = 1;
    let mut again: i32 = 0;
    if (unsafe rec.stale & dir) != 0 {
        unsafe rec.stale = unsafe rec.stale & ~dir;
        again = dir;
    }
    if unsafe rec.rd != null && unsafe rec.wr != null {
        again = RD | WR;
    }
    if again != 0 && set_interest(r, fd, rec, again) != 0 {
        // The descriptor cannot be watched any more (closed under its waiters, most often): every wait on
        // it reports not ready, the same answer a failed first registration gives.
        fire_list(r, &mut unsafe rec.rd, runtime::WR_TIMEOUT, b);
        fire_list(r, &mut unsafe rec.wr, runtime::WR_TIMEOUT, b);
    }
}

// A closed descriptor, reported by `close`: the number's next file is a new generation. Every waiter of
// the old one settles as not ready at once (its syscall would fail anyway), and the record forgets the
// backend state, so an arm whose registration raced the close registers again and learns of it.
fn do_close(r: *mut Reactor, n: *mut IoWait) {
    let fd = unsafe n.fd;
    if fd as usize < unsafe r.nrec {
        let rec = unsafe (r.recs + fd as usize);
        unsafe rec.gen = unsafe rec.gen + 1;
        unsafe rec.known = 0;
        unsafe rec.stale = RD | WR;
        let mut b = Batch { head: null, tail: null, n: 0 };
        fire_list(r, &mut unsafe rec.rd, runtime::WR_TIMEOUT, &mut b);
        fire_list(r, &mut unsafe rec.wr, runtime::WR_TIMEOUT, &mut b);
        batch_flush(r, &mut b);
    }
    let mut g = Global {};
    unsafe g.dealloc(n, sizeof(IoWait), alignof(IoWait));
}

// Take an armed node off its record's list.
fn unlink(r: *mut Reactor, n: *mut IoWait) {
    let rec = unsafe (r.recs + n.fd as usize);
    if unsafe rec.gen != unsafe n.gen {
        panic("reactor: a waiter outlived its descriptor's generation");
    }
    let mut pp = list_of(rec, unsafe n.dir);
    while unsafe pp[0] != n {
        pp = &mut unsafe pp[0].lnext;
    }
    unsafe pp[0] = unsafe n.lnext;
    unsafe n.state = NS_FIRED;
}

// A disarm command: the wait ended by another wake reason. Unlink the node if it is still armed, then
// acknowledge, which lets the task's frame end. The interest stays with the poller: a one-shot that fires
// into an empty list is ignored, and removing it would cost a call on every expired wait.
fn do_disarm(r: *mut Reactor, n: *mut IoWait, b: &mut Batch) {
    if io_stats_on() {
        stat_add(&mut unsafe r.st.disarms, 1);
    }
    if unsafe n.state == NS_NEW {
        // The arm has not arrived yet (its worker's hand-off lost the race with the deadline): the
        // acknowledgement waits for it, so the node is never linked after its frame ends. The arm's push
        // brings no wake, so the reactor polls with a bound while an acknowledgement is deferred.
        unsafe n.state = NS_CANCELLED;
        unsafe r.deferred = unsafe r.deferred + 1;
        return;
    }
    if unsafe n.state == NS_ARMED {
        unlink(r, n);
    }
    ack(n, b);
}

// The queue link a tagged node pointer travels on.
fn cmd_link(v: usize) *mut usize {
    let n = (v & ~CMD_MASK) as *mut IoWait;
    let tag = v & CMD_MASK;
    if tag == CMD_DISARM {
        return &mut unsafe n.dnext;
    }
    return &mut unsafe n.anext;
}

// Take every queued command and run them oldest first, so a wait's arm precedes its disarm whenever both
// were published in that order.
fn drain_commands(r: *mut Reactor, b: &mut Batch) {
    let mut v = atomic::swap_usize(&mut unsafe r.cmds, 0, 4);
    if v == 0 {
        return;
    }
    // The list is newest first; reverse it through the same links.
    let mut prev: usize = 0;
    while v != 0 {
        let link = cmd_link(v);
        let next = unsafe link[0];
        unsafe link[0] = prev;
        prev = v;
        v = next;
    }
    v = prev;
    while v != 0 {
        let n = (v & ~CMD_MASK) as *mut IoWait;
        let tag = v & CMD_MASK;
        v = unsafe cmd_link(v)[0];
        if tag == CMD_DISARM {
            do_disarm(r, n, b);
        } else {
            do_arm(r, n, b);
        }
    }
}

// Deliver one event batch: wake the waiters of every ready direction, then re-arm what the backend let go
// of while waiters remain (epoll disables a whole descriptor when either direction fires).
fn process_events(r: *mut Reactor, evs: &mut EvBuf, n: i32, b: &mut Batch) {
    if io_stats_on() {
        stat_add(&mut unsafe r.st.events, n as u64);
    }
    for i in 0..n as usize {
        let fd = unsafe evs.e[3 * i];
        let ready = unsafe evs.e[3 * i + 1];
        let dropped = unsafe evs.e[3 * i + 2];
        if fd < 0 || fd as usize >= unsafe r.nrec {
            continue;
        }
        let rec = unsafe (r.recs + fd as usize);
        // A direction is stale only when the backend dropped an interest there that no waiter had:
        // an end-of-file sets both ready bits, but consumes only the filter that fired.
        let unowned = dropped & ~(if unsafe rec.rd != null {
            RD;
        } else {
            0;
        } | if unsafe rec.wr != null {
            WR;
        } else {
            0;
        });
        if unowned != 0 {
            unsafe rec.stale = unsafe rec.stale | unowned;
            if io_stats_on() {
                stat_add(&mut unsafe r.st.stale, 1);
            }
        }
        if (ready & RD) != 0 {
            fire_list(r, &mut unsafe rec.rd, runtime::WR_IO, b);
        }
        if (ready & WR) != 0 {
            fire_list(r, &mut unsafe rec.wr, runtime::WR_IO, b);
        }
        let mut want: i32 = 0;
        if unsafe rec.rd != null {
            want = want | RD;
        }
        if unsafe rec.wr != null {
            want = want | WR;
        }
        let rearm = want & dropped;
        if rearm != 0 {
            let rc = set_interest(r, fd, rec, rearm);
            if rc != 0 {
                // The descriptor cannot be watched any more: its remaining waits report not ready.
                if (rearm & RD) != 0 {
                    fire_list(r, &mut unsafe rec.rd, runtime::WR_TIMEOUT, b);
                }
                if (rearm & WR) != 0 {
                    fire_list(r, &mut unsafe rec.wr, runtime::WR_TIMEOUT, b);
                }
            }
        }
    }
}

// Shutdown: every armed wait is settled as not ready; its disarm follows and is acknowledged.
fn settle_all(r: *mut Reactor, b: &mut Batch) {
    for i in 0..unsafe r.nrec {
        let rec = unsafe (r.recs + i);
        fire_list(r, &mut unsafe rec.rd, runtime::WR_TIMEOUT, b);
        fire_list(r, &mut unsafe rec.wr, runtime::WR_TIMEOUT, b);
    }
}

// The reactor thread: drain commands, deliver events, sleep in the poller; at shutdown, settle every wait
// and keep acknowledging disarms until no admitted wait remains, then leave.
fn reactor_main(arg: *mut void) *mut void {
    let r = arg as *mut Reactor;
    let mut evs = EvBuf {};
    let mut b = Batch { head: null, tail: null, n: 0 };
    let mut settled = false;
    let sp = (&mut unsafe G_STATE) as *mut i32;
    loop {
        drain_commands(r, &mut b);
        if atomic::load_i32(sp, 4) == 3 {
            if !settled {
                settle_all(r, &mut b);
                settled = true;
            }
            batch_flush(r, &mut b);
            // Every task that can still reach this reactor has recorded an I/O wait: none left means
            // nothing more will be pushed (see `wait_until` for the order that makes this sound).
            if runtime::tasks_waiting(runtime::WK_IO) == 0 && atomic::load_i32(&mut unsafe G_CLOSERS, 4) == 0 {
                break;
            }
        }
        batch_flush(r, &mut b);
        // Sleep only with an empty command list: a pusher that sees `sleeping` writes the wake pipe, and
        // one that pushed before this store is caught by the load after it (both sides SeqCst).
        atomic::store_i32(&mut unsafe r.sleeping, 1, 4);
        if atomic::load_usize(&mut unsafe r.cmds, 4) != 0 {
            atomic::store_i32(&mut unsafe r.sleeping, 0, 4);
            continue;
        }
        if io_stats_on() {
            stat_add(&mut unsafe r.st.polls, 1);
        }
        // Poll with a bound while an acknowledgement waits for an arm that brings no wake, and while
        // stopping (a task that recorded its wait and then found the reactor stopping clears the record
        // without a wake); otherwise sleep until an event or a wake.
        let n = unsafe sc_io::sc_io_wait(
            r.poller,
            &mut evs.e[0],
            sc_io::EV_MAX,
            if settled || unsafe r.deferred > 0 {
                1;
            } else {
                -1;
            },
        );
        atomic::store_i32(&mut unsafe r.sleeping, 0, 4);
        if n < 0 {
            panic("reactor: the poller failed");
        }
        // Commands before events: a worker registers its interest right after publishing its arm, so
        // the event that woke this poll may belong to a node still on the command list.
        drain_commands(r, &mut b);
        process_events(r, &mut evs, n, &mut b);
    }
    return null;
}

// Queue a command for the reactor: one compare-and-swap on the list head, then, for a command no event
// will announce, a wake-pipe write if the reactor is asleep (see `reactor_main`). Runs on a worker in the
// park hand-off, so it never waits.
fn push_cmd(r: *mut Reactor, n: *mut IoWait, tag: usize, wake: bool) {
    let tagged = n as usize | tag;
    let link = cmd_link(tagged);
    loop {
        let head = atomic::load_usize(&mut unsafe r.cmds, 0);
        unsafe link[0] = head;
        if atomic::cas_usize(&mut unsafe r.cmds, head, tagged, false, 4, 0) {
            break;
        }
    }
    if wake && atomic::load_i32(&mut unsafe r.sleeping, 4) != 0 {
        if io_stats_on() {
            stat_add(&mut unsafe r.st.pipe_wakes, 1);
        }
        unsafe sc_io::sc_io_wake(r.poller);
    }
}

// The reactor record's allocation: the record rounded up to a line, plus a line of slack for alignment.
fn reactor_bytes() usize {
    return (sizeof(Reactor) + R_ALIGN - 1) / R_ALIGN * R_ALIGN + R_ALIGN;
}

fn build_reactor() *mut Reactor {
    let poller = unsafe sc_io::sc_io_new();
    if poller == null {
        panic("reactor: cannot create the I/O poller");
    }
    let mut g = Global {};
    let base = unsafe g.alloc(reactor_bytes(), 16);
    let recs = (unsafe g.alloc(REC_INIT * sizeof(FdRec), alignof(FdRec))) as *mut FdRec;
    let regs = (unsafe g.alloc((REG_SLOTS + 1) * R_ALIGN, R_ALIGN)) as *mut i32;
    if base == null || recs == null || regs == null {
        panic("reactor: cannot allocate the reactor");
    }
    for k in 0..(REG_SLOTS + 1) * (R_ALIGN / 4) {
        unsafe regs[k] = 0;
    }
    for k in 0..REC_INIT {
        unsafe recs[k] = FdRec { rd: null, wr: null, known: 0, stale: 0, gen: 0, pad: 0 };
    }
    let r = ((base as usize + R_ALIGN - 1) / R_ALIGN * R_ALIGN) as *mut Reactor;
    unsafe r[0] = Reactor {
        base: base,
        poller: poller,
        thread: null,
        recs: recs,
        nrec: REC_INIT,
        deferred: 0,
        pad4: 0,
        regs: regs,
        pad0: Array::<u64, 9>::new(),
        cmds: 0,
        pad1: Array::<u64, 15>::new(),
        sleeping: 0,
        pad2: 0,
        pad3: Array::<u64, 15>::new(),
        st: IoStats {
            arms: 0,
            disarms: 0,
            sets: 0,
            polls: 0,
            events: 0,
            wakes: 0,
            pipe_wakes: 0,
            batches: 0,
            stale: 0,
            records: REC_INIT as u64,
        },
    };
    let mut h: *mut void = null;
    if unsafe sc_runtime::sc_rt_thread_create(&mut h, reactor_main, r) != 0 {
        // Nothing has seen `r`: release the poller and the record, then stop (a reactor that never
        // polls would park every I/O task forever).
        unsafe sc_io::sc_io_free(poller);
        unsafe g.dealloc(recs, REC_INIT * sizeof(FdRec), alignof(FdRec));
        unsafe g.dealloc(regs, (REG_SLOTS + 1) * R_ALIGN, R_ALIGN);
        unsafe g.dealloc(base, reactor_bytes(), 16);
        panic("reactor: cannot create the poller thread");
    }
    unsafe r.thread = h;
    return r;
}

/// Start the reactor if it is not running and return it; null while a shutdown is in progress (a wait
/// that begins then reports not ready: waiting for the restart would hold the stopping reactor's exit,
/// which waits for every recorded I/O wait to clear). `pub` for linkage.
pub fn ensure_reactor() *mut Reactor {
    // `G_REACTOR` is ordered by `G_STATE`, which the compiler cannot see: the CAS winner publishes the
    // pointer and THEN releases state 2, and every reader acquires state 2 first, so the write
    // happens-before every read. That handshake is what this `unsafe` asserts.
    unsafe {
        let sp = (&mut G_STATE) as *mut i32; // order codes: 0 Relaxed, 1 Acquire, 2 Release, 4 SeqCst
        loop {
            let st = atomic::load_i32(sp, 1);
            if st == 2 {
                return G_REACTOR;
            }
            if st == 3 {
                return null;
            }
            if st == 0 && atomic::cas_i32(sp, 0, 1, false, 4, 0) {
                let r = build_reactor();
                G_REACTOR = r;
                atomic::store_i32(sp, 2, 2);
                return r;
            }
            // Being built.
            sc_runtime::sc_rt_thread_yield();
        }
    }
}

// Admit one wait. The caller has already recorded its wait kind (a fence orders that record before the
// state load below); the stopping reactor's exit check reads the state, then scans those records, both
// sequentially consistent, so a task that saw the reactor accepting is counted until it has cleared its
// record, and the reactor it read stays alive that long. Null when the reactor is stopping.
fn admit() *mut Reactor {
    if ensure_reactor() == null {
        return null;
    }
    if atomic::load_i32((&mut unsafe G_STATE) as *mut i32, 4) != 2 {
        return null;
    }
    return unsafe G_REACTOR;
}

// The park hand-offs: publish the command once the coroutine's context is saved. Doing it here rather than
// before the park is the whole trick: the reactor cannot wake a coroutine it does not know about, and it
// does not know about this one until its context is safely stored.
fn commit_arm(p: *mut void) {
    let n = p as *mut IoWait;
    let r = unsafe G_REACTOR;
    // Register, then publish: an event that lands before the node is seen marks the record stale and
    // the arm registers again (see `do_arm`). A failed registration brings no event, so only then is the
    // reactor woken for the command.
    if io_stats_on() {
        // Workers count concurrently: an atomic add, unlike the reactor's own counters.
        let _ = atomic::add_u64(&mut unsafe r.st.sets, 1, 0);
    }
    let closes = atomic::load_u64(&mut unsafe G_CLOSES, 4);
    let rc = register(r, unsafe n.fd, unsafe n.dir, 1);
    unsafe n.rc = rc;
    // Nothing touches `n` after the push: the reactor may acknowledge it and the frame may end at once.
    push_cmd(r, n, CMD_ARM, rc != 0);
    // A close between the two reads may have taken the registration with it (the kernel drops a closed
    // descriptor's interests) after its report was processed, leaving this arm with no event and no wake.
    // A close after the push is ordered behind the arm on the command list and settles it there.
    if rc == 0 && atomic::load_u64(&mut unsafe G_CLOSES, 4) != closes && atomic::load_i32(&mut unsafe r.sleeping, 4) != 0 {
        unsafe sc_io::sc_io_wake(r.poller);
    }
}

fn commit_disarm(p: *mut void) {
    push_cmd(unsafe G_REACTOR, p as *mut IoWait, CMD_DISARM, true);
}

/// Wait until `fd` is ready in the given direction, or until `deadline` (a `time::deadline_in` value; 0
/// waits indefinitely). Reports whether it became ready: `false` means the deadline passed first, the wait
/// was cancelled, the reactor is shutting down, or the descriptor could not be watched.
///
/// From a coroutine this PARKS, freeing the worker. From any other thread it blocks that thread, which is
/// what it would have done anyway.
pub fn wait_until(fd: i32, write: bool, deadline: u64) bool {
    let co = runtime::current();
    if co == null {
        // Not a coroutine: nothing to park, so wait on the one descriptor. A poll(2) rather than a
        // poller of its own: that meant building and tearing down a kqueue per call.
        let w = if write {
            1;
        } else {
            0;
        };
        let ms = if deadline == 0 {
            -1;
        } else {
            (time::remaining_ns(deadline) / 1000000) as i32 + 1;
        };
        return unsafe sc_io::sc_io_wait_fd(fd, w, ms) > 0;
    }
    if fd < 0 {
        // Never a descriptor: ready, so the caller's syscall reports the real error.
        return true;
    }
    // The wait record comes BEFORE admission: see `admit`.
    runtime::wait_note(runtime::WK_IO, fd as usize);
    atomic::fence(4);
    let r = admit();
    if r == null {
        runtime::wait_clear();
        return false;
    }
    let mut n = IoWait {
        co: co,
        token: 0,
        ack: 0,
        fd: fd,
        dir: if write {
            WR;
        } else {
            RD;
        },
        state: NS_NEW,
        rc: 0,
        gen: 0,
        anext: 0,
        dnext: 0,
        lnext: null,
    };
    let token = runtime::park_begin(co);
    n.token = token;
    let reason = runtime::park_timed(token, deadline, commit_arm, &mut n, true);
    if deadline != 0 {
        runtime::cancel_timer(co);
    }
    let ready = reason == runtime::WR_IO;
    if !ready {
        // The deadline, a cancellation or shutdown won the park: the reactor may still hold the node,
        // armed or not yet processed. Park again until it has let go; that park has exactly one waker.
        n.ack = runtime::park_begin(co);
        let _ = runtime::park_timed(n.ack, 0, commit_disarm, &mut n, false);
    }
    runtime::wait_clear();
    runtime::park_done(co);
    if runtime::cancel_after_wait(true) {
        return false;
    }
    return ready;
}

/// Close `fd` and tell the reactor, so that every task waiting on it is settled at once as not ready and
/// the number's next file starts a fresh record generation. Returns what close(2) returned. Sockets
/// closed any other way leave their waiters to their deadlines.
pub fn close(fd: i32) i32 {
    if fd < 0 {
        return unsafe sc_io::sc_io_close(fd);
    }
    let sp = (&mut unsafe G_STATE) as *mut i32;
    // Count in before reading the state: a stopping reactor waits for the count (see `reactor_main`).
    let _ = atomic::add_i32(&mut unsafe G_CLOSERS, 1, 4);
    if atomic::load_i32(sp, 4) != 2 {
        // No reactor: nothing can be registering the descriptor.
        let rc = unsafe sc_io::sc_io_close(fd);
        let _ = atomic::sub_i32(&mut unsafe G_CLOSERS, 1, 4);
        return rc;
    }
    let r = unsafe G_REACTOR;
    // No registration may overlap the close (see `G_CLOSING`): raise the flag, wait out the ones under
    // way, close, lower it.
    let _ = atomic::add_i32(&mut unsafe G_CLOSING, 1, 4);
    for slot in 0..REG_SLOTS + 1 {
        let f = unsafe (r.regs + slot * (R_ALIGN / 4));
        while atomic::load_i32(f, 4) != 0 {
            unsafe sc_runtime::sc_rt_cpu_relax();
        }
    }
    let rc = unsafe sc_io::sc_io_close(fd);
    let _ = atomic::sub_i32(&mut unsafe G_CLOSING, 1, 4);
    // Counted before the report is published, so an arm that saw the old count and then finds the new one
    // knows its registration may have died with the descriptor.
    let _ = atomic::add_u64(&mut unsafe G_CLOSES, 1, 4);
    let mut g = Global {};
    let n = (unsafe g.alloc(sizeof(IoWait), alignof(IoWait))) as *mut IoWait;
    if n == null {
        panic("reactor: cannot allocate a close report");
    }
    unsafe n[0] = IoWait {
        co: null,
        token: 0,
        ack: 0,
        fd: fd,
        dir: CLOSE,
        state: NS_NEW,
        rc: 0,
        gen: 0,
        anext: 0,
        dnext: 0,
        lnext: null,
    };
    push_cmd(r, n, CMD_ARM, true);
    let _ = atomic::sub_i32(&mut unsafe G_CLOSERS, 1, 4);
    return rc;
}

/// Wait until `fd` can be read without blocking.
pub fn wait_readable(fd: i32) {
    let _ = wait_until(fd, false, 0);
}

/// Wait until `fd` can be written without blocking.
pub fn wait_writable(fd: i32) {
    let _ = wait_until(fd, true, 0);
}

/// Read from `fd`, parking whenever it is not ready. Returns what the read returned: the byte count, `0`
/// at end of file, or negative for a real error (one that is not "would block"). A wait that ends without
/// readiness (cancelled, or the reactor shut down) also returns `-1`: the caller must stop reading.
pub fn read(fd: i32, buf: []mut u8) isize {
    loop {
        let n = unsafe sc_io::sc_io_read(fd, buf.ptr, buf.len());
        if n >= 0 {
            return n;
        }
        if unsafe sc_io::sc_io_would_block() == 0 {
            return n;
        }
        if !wait_until(fd, false, 0) {
            return -1;
        }
    }
}

/// Write all of `buf` to `fd`, parking whenever it is not ready. Returns the number of bytes written, or
/// negative on a real error. A wait that ends without readiness returns the bytes written so far.
pub fn write(fd: i32, buf: []u8) isize {
    let mut at: usize = 0;
    while at < buf.len() {
        let n = unsafe sc_io::sc_io_write(fd, unsafe (buf.ptr + at), buf.len() - at);
        if n > 0 {
            at = at + n as usize;
            continue;
        }
        if n == 0 {
            break;
        }
        if unsafe sc_io::sc_io_would_block() == 0 {
            return n;
        }
        if !wait_until(fd, true, 0) {
            break;
        }
    }
    return at as isize;
}

/// Stop the reactor and release its poller. Idempotent; a no-op if it never started. Call it once, from
/// the main thread. Every wait still pending is settled as not ready (its task resumes and finds its
/// operation failed), every wait started meanwhile reports not ready at once, and the thread is joined
/// only when no wait references the reactor. A later wait starts a fresh reactor.
pub fn shutdown() {
    let sp = (&mut unsafe G_STATE) as *mut i32;
    loop {
        let st = atomic::load_i32(sp, 4);
        if st == 2 && atomic::cas_i32(sp, 2, 3, false, 4, 0) {
            break;
        }
        if st != 1 && st != 2 {
            return;
        }
        unsafe sc_runtime::sc_rt_thread_yield();
    }
    let r = unsafe G_REACTOR;
    // The reactor re-reads the state after every wake.
    unsafe sc_io::sc_io_wake(r.poller);
    if unsafe sc_runtime::sc_rt_thread_join(r.thread) != 0 {
        panic("reactor: cannot join the poller thread at shutdown");
    }
    unsafe sc_io::sc_io_free(r.poller);
    if io_stats_on() {
        let t = &mut unsafe G_STATS;
        t.arms = t.arms + unsafe r.st.arms;
        t.disarms = t.disarms + unsafe r.st.disarms;
        t.sets = t.sets + unsafe r.st.sets;
        t.polls = t.polls + unsafe r.st.polls;
        t.events = t.events + unsafe r.st.events;
        t.wakes = t.wakes + unsafe r.st.wakes;
        t.pipe_wakes = t.pipe_wakes + unsafe r.st.pipe_wakes;
        t.batches = t.batches + unsafe r.st.batches;
        t.stale = t.stale + unsafe r.st.stale;
    }
    let mut g = Global {};
    unsafe g.dealloc(r.recs, r.nrec * sizeof(FdRec), alignof(FdRec));
    unsafe g.dealloc(r.regs, (REG_SLOTS + 1) * R_ALIGN, R_ALIGN);
    unsafe g.dealloc(r.base, reactor_bytes(), 16);
    unsafe G_REACTOR = null;
    atomic::store_i32(sp, 0, 4);
}
