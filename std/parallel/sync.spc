// Task-aware synchronisation primitives. Import with `import std::parallel::sync;`.
//
// Every wait here is task-aware: a *coroutine* (anything running under `launch`) that cannot proceed PARKS
// it saves its context and hands its worker thread back to the scheduler, which runs other tasks: and
// any other thread blocks on the platform parking lot. Nothing ever occupies a worker while waiting, so
// more tasks than workers can contend for a lock without deadlocking. `RawMutex` below is a one-word
// lock: uncontended acquire and release are one CAS each, and a contender spins briefly before parking.

import atomic;
import sc_runtime;
import std::parallel::atomics as atomics;
import std::parallel::arc as arc;
import std::parallel::runtime as runtime;
import std::parallel::time as time;

// RawMutex: the task-aware lock behind Mutex<T>, and the wait primitive the rest of the module reuses.

/// One entry in a wait queue: a parked coroutine plus the wake token of the park it is waiting out, or a
/// plain thread plus the word it sleeps on. It lives on the waiter's own stack, so waiting costs no
/// allocation, and the waiter unlinks it before returning. The token (or the word's claim) is what makes a
/// wakeup park-specific: an entry a timed wait left behind is inert, and a notify that pops one passes its
/// wake to the next entry.
///
/// `claim`/`arm` serve a waiter queued on SEVERAL queues at once (a `select`): the notify that wins the
/// wake records which queue it came from, so the woken task retries that operation first. Null `claim` for
/// an ordinary single-queue wait, which already knows what woke it.
@no_const
pub struct Waiter {
    pub co: *mut runtime::Coroutine, // null for a plain thread, which sleeps on `os` instead
    pub token: u32,
    pub arm: i32, // index to publish through `claim` (fills this struct's padding)
    pub next: *mut Waiter,
    pub claim: *mut i32,
    pub os: *mut i32, // a plain thread's wake word, in its frame: 0 parked, 1 notified, 2 gave up
}

// Coordination counters, compiled in only when this is true: every count sits behind `sync_stats_on()`, a
// constant the emitter folds, so an ordinary build carries no counter code. Flip it, rebuild, and read
// `sync_stats()`. Relaxed atomics on one shared line: a diagnostic, not a contract.
const SYNC_STATS: bool = false;

/// Whether the coordination counters are compiled in. A constant: the emitter folds every
/// `if sync_stats_on()` away when it is false.
pub const fn sync_stats_on() bool {
    return SYNC_STATS;
}

/// Coordination counters over the whole process. All zero unless `sync_stats_on()`.
pub struct SyncStats {
    pub lock_slow: u64, // lock acquisitions that found the lock held (the spin-then-park path)
    pub lock_parks: u64, // lock waits that parked a coroutine
    pub lock_blocks: u64, // lock waits that blocked a plain thread
    pub lock_spins: u64, // spin-hint iterations executed while waiting for a held lock
    pub lock_cas_fail: u64, // acquisition attempts that lost the word to another contender
    pub lock_barges: u64, // acquisitions taken while a waiter was already queued (overtaking)
    pub lock_scan: u64, // queue nodes walked under a bucket lock (pop and remove together)
    pub lock_buckets: u64, // bucket-lock acquisitions
    pub cv_waits: u64, // condvar waits that parked a coroutine
    pub cv_blocks: u64, // condvar waits that blocked a plain thread
    pub wakes: u64, // notifies that resumed a waiter
    pub wakes_stale: u64, // popped nodes whose wait was already over (the wake went to the next node)
    pub notifies_idle: u64, // notifies that found no waiter at all
}

static mut G_SYNC: SyncStats = SyncStats {
    lock_slow: 0,
    lock_parks: 0,
    lock_blocks: 0,
    lock_spins: 0,
    lock_cas_fail: 0,
    lock_barges: 0,
    lock_scan: 0,
    lock_buckets: 0,
    cv_waits: 0,
    cv_blocks: 0,
    wakes: 0,
    wakes_stale: 0,
    notifies_idle: 0,
};

// The lock's interleaving hook points, for its race hunt. They share the runtime's hook machinery
// (`runtime::sched_hook_arm`, compiled in only when `RT_HOOKS` in std/parallel/runtime.spc is true) and its
// point space, so their values follow the scheduler's own. An armed point delays whoever reaches it, which
// turns a window of nanoseconds into one a test can hit on purpose.

/// Hook point: a contender has published the queued bit and is about to take the bucket lock, so an
/// unlock can get in first and release before the waiter has enqueued.
pub const HOOK_BEFORE_ENQUEUE: i32 = 2;

/// Hook point: an unlock has popped a waiter and has not published the release yet, so a cancellation can
/// claim that waiter's park before the wake reaches it.
pub const HOOK_AFTER_POP: i32 = 3;

/// Hook point: an unlock has published the release and has not woken its waiter yet, so a fresh acquirer
/// can barge in front of the waiter that was chosen, and a caller that frees the lock here proves the
/// unlock never touches it again.
pub const HOOK_AFTER_RELEASE: i32 = 4;

fn stat_add(p: *mut u64) {
    let _ = atomic::add_u64(p, 1, 0);
}

fn stat_addn(p: *mut u64, n: u64) {
    let _ = atomic::add_u64(p, n, 0);
}

/// The coordination counters. All zero unless the module was built with `sync_stats_on()` true.
pub fn sync_stats() SyncStats {
    return SyncStats {
        lock_slow: atomic::load_u64(&mut unsafe G_SYNC.lock_slow, 0),
        lock_parks: atomic::load_u64(&mut unsafe G_SYNC.lock_parks, 0),
        lock_blocks: atomic::load_u64(&mut unsafe G_SYNC.lock_blocks, 0),
        lock_spins: atomic::load_u64(&mut unsafe G_SYNC.lock_spins, 0),
        lock_cas_fail: atomic::load_u64(&mut unsafe G_SYNC.lock_cas_fail, 0),
        lock_barges: atomic::load_u64(&mut unsafe G_SYNC.lock_barges, 0),
        lock_scan: atomic::load_u64(&mut unsafe G_SYNC.lock_scan, 0),
        lock_buckets: atomic::load_u64(&mut unsafe G_SYNC.lock_buckets, 0),
        cv_waits: atomic::load_u64(&mut unsafe G_SYNC.cv_waits, 0),
        cv_blocks: atomic::load_u64(&mut unsafe G_SYNC.cv_blocks, 0),
        wakes: atomic::load_u64(&mut unsafe G_SYNC.wakes, 0),
        wakes_stale: atomic::load_u64(&mut unsafe G_SYNC.wakes_stale, 0),
        notifies_idle: atomic::load_u64(&mut unsafe G_SYNC.notifies_idle, 0),
    };
}

/// The whole lock is the `locked` word: bit 0 is HELD, bit 1 says a waiter is (or is about to be) parked.
/// An uncontended acquire and release are one CAS each; a contender spins briefly (the critical sections
/// this guards are tens of nanoseconds) and only then parks: a coroutine through the scheduler, any other
/// thread futex-style on a word in its own frame. `pub` for linkage: `Mutex<T>`'s methods are monomorphized
/// in the caller's module. Not a user-facing type.
///
/// Parked waiters queue in a STATIC bucket table (`sc_rt_lot_bucket`), keyed by the lock's address, not in
/// the lock itself, and that placement is load-bearing. A `Mutex` may be freed the moment its final unlock
/// is observed (a lock that lives no longer than the work it guards, e.g. the data-parallel latch), so once
/// an unlock has published the release it may touch only memory that outlives the mutex: the static buckets
/// and the popped waiter's own frame, which cannot die before its wake. It never touches the lock again.
///
/// The word takes four values, and every write of it appears here:
///
/// | from | to | written by | with |
/// |------|----|------------|------|
/// | 0 free | 1 held | an acquirer | the acquire CAS of `lock` or `try_lock` |
/// | 2 free, waiter queued | 3 held, waiter queued | an acquirer | the slow path's acquire CAS, which preserves bit 1 |
/// | 1 held | 3 held, waiter queued | a contender | a relaxed CAS, immediately before it enqueues |
/// | 1 held | 0 free | the owner | the release CAS of `unlock` |
/// | 3 held, waiter queued | 2 or 0 | the owner | the slow path's release store: 2 if a waiter remains queued, 0 if none does (a cancelled waiter leaves the bit with nobody behind it, and this is the store that clears it) |
///
/// A contender that observes 1 or 3 and spins writes nothing, and a lost CAS leaves the word as it found
/// it. 0 never becomes 2: the queued bit is only ever set on a HELD lock, by the contender that is about
/// to queue itself on it.
///
/// Linearization. A successful `lock` or `try_lock` linearizes at the acquire CAS that sets bit 0; a
/// failed `try_lock` at the relaxed load that saw bit 0 already set. An `unlock` linearizes at its release
/// CAS, or at the slow path's release store. A cancelled acquisition linearizes at the park's cancelled
/// return: it writes the word not at all, removes its own node under the bucket lock, and any queued bit
/// it leaves behind is corrected by the next unlock, which pops nobody and stores 0.
///
/// Happens-before. An acquisition's Acquire CAS reads the value the previous release wrote, so everything
/// the previous owner did inside its critical section happens-before everything the next owner does inside
/// its own. Registration and waking are ordered by the bucket spinlock rather than by the word: a waiter
/// enqueues only while the word still reads 3, revalidated under that lock, and an unlock pops under the
/// same lock, so between the two a waiter is either popped and woken or still queued when the release is
/// published. The queued bit is cleared only by the unlock that pops under that lock and finds no
/// survivor, which is why it can never be cleared while a queued waiter still needs a wake.
@no_const
pub struct RawMutex {
    pub locked: i32,
}

// One parked lock waiter, living on that waiter's stack. A coroutine parks through the scheduler
// (`co`/`token`); any other thread parks on `oswake` in its own frame: the waker names this node, never
// the (possibly already freed) mutex.
@no_const
struct LotNode {
    pub co: *mut runtime::Coroutine, // null for an OS-thread waiter
    pub token: u32,
    pub oswake: i32, // 0 while parked; the waker publishes 1 before unparking this address (OS threads)
    pub addr: *mut void, // which lock: one bucket queues waiters of many locks
    pub next: *mut LotNode,
}

// The Super-C view of one static bucket (a 64-byte slot in sc_rt.c): a spinlock over a FIFO of nodes.
//
// The queue needs no admission limit of its own because it cannot grow past the runtime's own capacity:
// a node lives in the frame of the coroutine or thread that is blocked on it, so a waiter contributes at
// most one node and only while it is waiting. The queue length is therefore bounded by the live task count
// plus the live thread count, external OS-thread callers included, both of which the runtime already
// bounds. `sync_stats()` reports the nodes walked per acquisition, which is what would show the bound
// being approached in practice; it measures under one per acquisition on every workload here.
@no_const
struct LotBucket {
    pub lock: i32,
    pub pad: i32,
    pub head: *mut LotNode,
    pub tail: *mut LotNode,
}

// Attempts a contender makes before it parks, counting both observations of a held lock and acquisitions
// lost to somebody else: every episode is bounded, so a contender that keeps losing races still reaches
// the queue instead of spinning for ever. The trade: spinning occupies a worker that could run other
// tasks, but a park costs microseconds (a context switch out and back, plus a wake) against a critical
// section of tens of nanoseconds, so a bounded spin is cheaper for the SYSTEM, not only for this task.
//
// Sized by measurement, not by instruction count. One iteration is a relaxed load plus `sc_rt_cpu_relax`,
// which on this family of targets is a real delay rather than a no-op (a pause on x86, an instruction
// barrier on arm64 measured at 13.9 ns), so this budget is a few microseconds of waiting. A cheaper hint
// at the same TOTAL duration was measured and rejected: it polls the contended line tens of times more
// often within the same window, and the owner's acquisition has to fight that traffic for the line.
const MUTEX_SPIN: i32 = 256;

// Acquisitions lost to another contender before this one stops spinning and takes the queue at the first
// opportunity. Lost attempts are bounded SEPARATELY from held-lock observations rather than sharing their
// budget: a lost attempt already carries a full read-modify-write, and spending the spin budget on them
// made a contended channel park far sooner than its short critical sections deserve. What the bound
// guarantees is that an episode of losing races cannot go on for ever.
const MUTEX_LOSSES: i32 = 64;

// Attempts `try_lock` makes before it reports failure. More than one, because losing the word once to
// another contender says nothing about whether the lock is available; bounded, because `try_lock` promises
// not to wait and a retry loop with no ceiling is a wait.
const TRY_ATTEMPTS: i32 = 8;

// The budget once a waiter is ALREADY queued on this lock. Our turn is then at least one whole release
// away, so the full budget mostly burns a worker that could be running the owner instead. Half the base
// budget, by measurement rather than by taste: a quarter of it (32) took the same wins but cost a
// contended channel about a tenth of its throughput, because a channel's critical section is a ring push
// and spinning through one is still the cheaper answer; half takes the wins with the channel lanes flat.
const MUTEX_SPIN_QUEUED: i32 = 128;

fn lot_bucket(m: *mut RawMutex) *mut LotBucket {
    return (unsafe sc_runtime::sc_rt_lot_bucket(m)) as *mut LotBucket;
}

// Append; caller holds the bucket lock.
fn lot_push(b: *mut LotBucket, n: *mut LotNode) {
    unsafe n.next = null;
    if unsafe b.tail == null {
        unsafe b.head = n;
    } else {
        unsafe b.tail.next = n;
    }
    unsafe b.tail = n;
}

// Unlink one specific node, if it is still queued (a racing pop may have taken it). Caller holds the
// bucket lock. A cancelled lock waiter removes its own node through this before its frame dies.
fn lot_remove(b: *mut LotBucket, n: *mut LotNode) {
    let mut prev: *mut LotNode = null;
    let mut cur = unsafe b.head;
    let mut seen: u64 = 0;
    while cur != null && cur != n {
        prev = cur;
        cur = unsafe cur.next;
        seen = seen + 1;
    }
    if sync_stats_on() {
        stat_addn(&mut unsafe G_SYNC.lock_scan, seen);
    }
    if cur != n {
        return;
    }
    if prev == null {
        unsafe b.head = unsafe n.next;
    } else {
        unsafe prev.next = unsafe n.next;
    }
    if unsafe b.tail == n {
        unsafe b.tail = prev;
    }
    unsafe n.next = null;
}

// Unlink and return the first node waiting on `addr`; `more` reports whether another remains behind it.
// Caller holds the bucket lock.
fn lot_pop(b: *mut LotBucket, addr: *mut void, more: &mut bool) *mut LotNode {
    *more = false;
    let mut prev: *mut LotNode = null;
    let mut cur = unsafe b.head;
    let mut found: *mut LotNode = null;
    let mut seen: u64 = 0;
    while cur != null {
        let nx = unsafe cur.next;
        seen = seen + 1;
        if unsafe cur.addr == addr {
            if found != null {
                *more = true;
                break;
            }
            found = cur;
            if prev == null {
                unsafe b.head = nx;
            } else {
                unsafe prev.next = nx;
            }
            if unsafe b.tail == cur {
                unsafe b.tail = prev;
            }
            unsafe cur.next = null;
        } else {
            prev = cur;
        }
        cur = nx;
    }
    if sync_stats_on() {
        stat_addn(&mut unsafe G_SYNC.lock_scan, seen);
    }
    return found;
}

// The park hand-off used inside the lock slow path: a parking contender holds only the bucket lock.
fn commit_lot_unlock(p: *mut void) {
    unsafe sc_runtime::sc_rt_spin_unlock(p as *mut i32);
}

/// The park hand-off used by `Condvar::wait`: release the whole lock, so another task can take it while the
/// waiter sleeps. `pub` for linkage.
pub unsafe fn commit_raw_unlock(p: *mut void) {
    raw_mutex_unlock(p as *mut RawMutex);
}

/// Acquire the lock, parking the calling coroutine (or blocking the calling thread) while it is held.
pub unsafe fn raw_mutex_lock(m: *mut RawMutex) {
    if atomic::cas_i32(&mut unsafe m.locked, 0, 1, false, 1, 0) {
        unsafe sc_runtime::sc_rt_lockdep_acquire(m);
        // Uncontended: one CAS.
        return;
    }
    let _ = raw_mutex_lock_slow(m, false);
    unsafe sc_runtime::sc_rt_lockdep_acquire(m);
}

/// `raw_mutex_lock`, but the park is a cancellation point: a `false` return means the wait was cancelled,
/// the lock is NOT held, the waiter's queue node is removed, and the cancellation is accepted. Only a
/// caller that can propagate cancellation (the compiler's cancellation edge) may use this form: it must
/// never hand a guard to code that would unlock a lock it does not hold. `pub` for linkage.
pub unsafe fn raw_mutex_lock_c(m: *mut RawMutex) bool {
    if atomic::cas_i32(&mut unsafe m.locked, 0, 1, false, 1, 0) {
        unsafe sc_runtime::sc_rt_lockdep_acquire(m);
        return true;
    }
    if !raw_mutex_lock_slow(m, true) {
        let _ = runtime::cancel_after_wait(true);
        return false;
    }
    unsafe sc_runtime::sc_rt_lockdep_acquire(m);
    return true;
}

// The contended path. Reports whether the lock was acquired: always true when `cancellable` is false;
// false only for a cancelled cancellable wait, after the waiter unlinked its own node. Acceptance is
// the cancellable wrapper's job: this body must not reach `cancel_accept`, or every plain `lock`
// caller in a task-reachable body would carry a compiled cancellation check.
fn raw_mutex_lock_slow(m: *mut RawMutex, cancellable: bool) bool {
    if sync_stats_on() {
        stat_add(&mut unsafe G_SYNC.lock_slow);
    }
    let w = &mut unsafe m.locked;
    let mut spins: i32 = 0;
    let mut losses: i32 = 0;
    loop {
        let c = atomic::load_i32(w, 0);
        if (c & 1) == 0 {
            // Free: take it, PRESERVING the parked bit; waiters may remain, and clearing it would let
            // the next unlock take its fast path straight past them.
            if atomic::cas_i32(w, c, c | 1, false, 1, 0) {
                if sync_stats_on() && (c & 2) != 0 {
                    // Taken with a waiter already queued: this acquisition overtook it.
                    stat_add(&mut unsafe G_SYNC.lock_barges);
                }
                return true;
            }
            // Lost the word to somebody else. Counted only up to the bound: past it the count is not
            // read again, and an unbounded increment on a signed counter would eventually trap.
            if losses < MUTEX_LOSSES {
                losses = losses + 1;
            }
            if sync_stats_on() {
                stat_add(&mut unsafe G_SYNC.lock_cas_fail);
            }
            continue;
        }
        // Held. How long to keep looking depends on who else is waiting: nobody, and the owner is
        // probably about to release; somebody, and our turn is at least one release away. An attempt that
        // has lost this many races is not winning this one either, so it stops looking and takes the queue
        // at the first opportunity. Past that bound the loop is no longer spinning: every turn of it
        // either acquires, loses to an acquirer, or reaches the queue, so the episode ends in acquisition,
        // in a park, or in a cancellation, never in waiting for its own sake.
        let budget = if losses >= MUTEX_LOSSES {
            0;
        } else if (c & 2) != 0 {
            MUTEX_SPIN_QUEUED;
        } else {
            MUTEX_SPIN;
        };
        if spins < budget {
            spins = spins + 1;
            if sync_stats_on() {
                stat_add(&mut unsafe G_SYNC.lock_spins);
            }
            unsafe sc_runtime::sc_rt_cpu_relax();
            continue;
        }
        if c != 3 && !atomic::cas_i32(w, 1, 3, false, 0, 0) {
            // The word moved under us: re-read and decide again.
            continue;
        }
        // The word reads held-with-waiters, so the next unlock takes its slow path. Enqueue while it STILL
        // reads that, validated under the bucket lock: the unlock pops (or records a survivor) under the
        // same lock, so between the two an enqueued waiter is either woken or left counted, never lost.
        if runtime::sched_hooks_on() {
            runtime::hook_delay(HOOK_BEFORE_ENQUEUE);
        }
        let b = lot_bucket(m);
        if sync_stats_on() {
            stat_add(&mut unsafe G_SYNC.lock_buckets);
        }
        unsafe sc_runtime::sc_rt_spin_lock(&mut b.lock);
        if atomic::load_i32(w, 0) != 3 {
            unsafe sc_runtime::sc_rt_spin_unlock(&mut b.lock);
            // Released since we looked: try to take it instead of sleeping through it.
            continue;
        }
        let co = runtime::current();
        if co != null {
            // The node lives in this frame and is popped by the unlock that wakes us; the runtime releases
            // the bucket lock once our context is saved, so that unlock can never resume a coroutine that
            // is still switching out.
            if sync_stats_on() {
                stat_add(&mut unsafe G_SYNC.lock_parks);
            }
            runtime::wait_note(runtime::WK_MUTEX, m as usize);
            let token = runtime::park_begin(co);
            let mut n = LotNode { co: co, token: token, oswake: 0, addr: m, next: null };
            lot_push(b, &mut n);
            let reason = runtime::park_current(token, commit_lot_unlock, &mut unsafe b.lock, cancellable);
            if reason == runtime::WR_CANCEL || reason == runtime::WR_SHUTDOWN {
                // Cancelled without the lock. Unlink our node (an unlock racing us may have popped it
                // already: then the pop consumed it and `lot_remove` finds nothing), clear the wait
                // record, and only then accept. A stale parked bit left on the word is harmless: the next
                // unlock takes its slow path, pops nobody, and clears it.
                if sync_stats_on() {
                    stat_add(&mut unsafe G_SYNC.lock_buckets);
                }
                unsafe sc_runtime::sc_rt_spin_lock(&mut b.lock);
                lot_remove(b, &mut n);
                unsafe sc_runtime::sc_rt_spin_unlock(&mut b.lock);
                runtime::wait_clear();
                runtime::park_done(co);
                return false;
            }
            // Woken by an unlock: this park CONSUMED that release, so it must be spent on an acquisition
            // attempt even when a cancellation landed after the wake claimed the park. Returning
            // cancelled here left the waiters behind us parked for good. The pending request is taken at
            // the next cancellation point: this loop's next park, or the caller's.
            runtime::wait_clear();
            runtime::park_done(co);
        } else {
            if sync_stats_on() {
                stat_add(&mut unsafe G_SYNC.lock_blocks);
            }
            let mut n = LotNode { co: null, token: 0, oswake: 0, addr: m, next: null };
            lot_push(b, &mut n);
            unsafe sc_runtime::sc_rt_spin_unlock(&mut b.lock);
            runtime::replay_release(); // about to block: in replay mode the pool runs while we do not
            while atomic::load_i32(&mut n.oswake, 1) == 0 {
                unsafe sc_runtime::sc_rt_park(&mut n.oswake, 0, -1);
            }
        }
        // Woken because the lock was free a moment ago: a fresh episode, and a fresh budget for it.
        spins = 0;
        losses = 0;
    }
}

/// Acquire the lock only if it is free; reports whether it was taken. Never waits, and never retries
/// without a bound: a caller that loses the word to another contender tries again at most `TRY_ATTEMPTS`
/// times and then reports failure. A `false` therefore means "not taken", which is what the contract has
/// always said, rather than "was held": under contention a lock that was free for an instant can report
/// failure, exactly as a weak compare-and-exchange may. Every caller already treats `false` as "go and do
/// something else", and an unbounded retry here would be a wait in a call that promises not to wait.
pub unsafe fn raw_mutex_try_lock(m: *mut RawMutex) bool {
    let w = &mut unsafe m.locked;
    let mut tries: i32 = 0;
    while tries < TRY_ATTEMPTS {
        let c = atomic::load_i32(w, 0);
        if (c & 1) != 0 {
            return false;
        }
        if atomic::cas_i32(w, c, c | 1, false, 1, 0) {
            return true;
        }
        tries = tries + 1;
    }
    return false;
}

/// Release the lock and wake the longest-parked waiter, if any. `pub` for linkage.
pub unsafe fn raw_mutex_unlock(m: *mut RawMutex) {
    // BEFORE the release: once published, another thread may take and even free this lock.
    unsafe sc_runtime::sc_rt_lockdep_release(m);
    if atomic::cas_i32(&mut unsafe m.locked, 1, 0, false, 2, 0) {
        // Nobody parked: one CAS, and the lock is never touched again.
        return;
    }
    raw_mutex_unlock_slow(m);
}

fn raw_mutex_unlock_slow(m: *mut RawMutex) {
    let b = lot_bucket(m);
    let mut released = false;
    // Usually one pass. A second pass happens only when the popped waiter's park was already claimed by a
    // cancellation: that wakeup was consumed elsewhere, so the release must go to the next waiter or the
    // bit self-corrects on the next unlock. Bounded by the number of queued waiters.
    loop {
        if sync_stats_on() {
            stat_add(&mut unsafe G_SYNC.lock_buckets);
        }
        unsafe sc_runtime::sc_rt_spin_lock(&mut b.lock);
        let mut more = false;
        let n = lot_pop(b, m, &mut more);
        if runtime::sched_hooks_on() {
            runtime::hook_delay(HOOK_AFTER_POP);
        }
        if !released {
            // The release store, and the LAST touch of the lock (see `RawMutex`): whoever acquires from
            // here on may legitimately free it. Everything below touches only the static bucket and the
            // popped waiter's frame, and that frame only under the bucket lock, because a cancelled
            // waiter may otherwise unlink and die at any moment.
            let next_word = if more {
                2;
            } else {
                0;
            };
            atomic::store_i32(&mut unsafe m.locked, next_word, 2);
            released = true;
            if runtime::sched_hooks_on() {
                // The lock may be taken, released and even destroyed from here on; everything below
                // touches only the static bucket and the popped waiter's frame.
                runtime::hook_delay(HOOK_AFTER_RELEASE);
            }
        }
        if n == null {
            unsafe sc_runtime::sc_rt_spin_unlock(&mut b.lock);
            // A waiter set the bit but has not enqueued yet: it revalidates and sees the release.
            return;
        }
        let wco = unsafe n.co;
        let wtoken = unsafe n.token;
        if wco == null {
            atomic::store_i32(&mut unsafe n.oswake, 1, 2);
            unsafe sc_runtime::sc_rt_spin_unlock(&mut b.lock);
            unsafe sc_runtime::sc_rt_unpark_one(&mut n.oswake);
            return;
        }
        unsafe sc_runtime::sc_rt_spin_unlock(&mut b.lock);
        // The wakee RE-CONTENDS rather than being handed the lock: with a ~2.3us wake latency, a hand-off
        // serializes every acquisition behind a wake (measured 781ns/lock on the contended-hammer lane
        // against 296ns for barging), so losing to a spinner is throughput, not loss. A false return means
        // a cancellation claimed that park first: spend the release on the next waiter.
        if runtime::wake(wco, wtoken) {
            return;
        }
    }
}

/// A mutual-exclusion lock guarding a `T`. Only the holder can reach the value, through the RAII
/// `MutexGuard` returned by `lock`: the lock is released when the guard is dropped. A contended `lock`
/// parks a coroutine instead of blocking its worker. Put one in an `Arc` to share it: `Arc<Mutex<T>>`.
///
/// The lock word lives in the value, so a mutex costs no allocation of its own. It may move while nothing
/// holds it (a guard borrows it) and nothing waits on it (a waiter is queued only against a held lock,
/// under the holder's guard), which is the only time a value can move at all.
@no_const
pub struct Mutex<T> {
    raw: UnsafeCell<RawMutex>,
    data: UnsafeCell<T>,
}

/// The RAII lock token. Reach the guarded value with `guard.get()` / `guard.get_mut()`, or call methods on
/// it directly (`guard.push(..)` auto-derefs); the mutex unlocks when the guard is dropped. Cannot outlive
/// the `Mutex` it borrows.
@no_const
pub struct MutexGuard<'a, T> {
    mutex: &'a Mutex<T>,
    // A guard means THIS thread holds the lock, so it must not cross to another: the unlock would run
    // where the lock never ran, and a task-aware lock queues its waiters against the acquiring
    // coroutine. A raw pointer is neither `Send` nor `Sync` structurally, and nothing transitively
    // holding one is either, so this dead field is what denies the guard both. It is never read.
    _pin: *const void,
}

// A Mutex makes its contents shareable across threads, so `Mutex<T>` is Send + Sync whenever `T` is Send.
unsafe extend<T: Send> Mutex<T> as Send {}

unsafe extend<T: Send> Mutex<T> as Sync {}

extend<T> Mutex<T> {
    /// A new unlocked mutex owning `value`.
    pub fn new(value: T) Mutex<T> {
        return Mutex::<T> {
            raw: UnsafeCell::<RawMutex>::new(RawMutex { locked: 0 }),
            data: UnsafeCell::<T>::new(value),
        };
    }
    /// Wait until the lock is acquired, then return the guard. A coroutine parks while it is held.
    pub fn lock(self: &Mutex<T>) MutexGuard<T> {
        // The guard is what keeps the promise: it holds the lock for exactly its own lifetime.
        unsafe raw_mutex_lock(self.raw.get());
        return MutexGuard::<T>::hold(self);
    }
    /// Try to acquire without waiting; `None` if it is already held.
    pub fn try_lock(self: &Mutex<T>) Option<MutexGuard<T>> {
        if unsafe raw_mutex_try_lock(self.raw.get()) {
            return Option::<MutexGuard<T>>::Some(MutexGuard::<T>::hold(self));
        }
        return Option::<MutexGuard<T>>::None;
    }
    /// `lock`, but the wait is a cancellation point: `None` means the wait was cancelled; no guard
    /// exists, the lock is not held, and the cancellation is accepted. The cancellable form of `lock` for
    /// callers that can propagate cancellation; ordinary code uses `lock`.
    pub fn lock_c(self: &Mutex<T>) Option<MutexGuard<T>> {
        if !unsafe raw_mutex_lock_c(self.raw.get()) {
            return Option::<MutexGuard<T>>::None;
        }
        return Option::<MutexGuard<T>>::Some(MutexGuard::<T>::hold(self));
    }
    /// Direct `&mut` access when the mutex is owned uniquely (`&mut self`): no locking needed.
    pub fn get_mut(self: &mut Mutex<T>) &mut T {
        return &mut unsafe self.data.get()[0];
    }
    /// The underlying lock, to take and release by hand. For a wait that must hold several locks at once
    /// (`select`); everything else should use `lock`. `pub` for linkage; not user-facing.
    pub unsafe fn raw_handle(self: &Mutex<T>) *mut RawMutex {
        return self.raw.get();
    }
    /// The guarded value WITHOUT locking. Sound only while the caller holds `raw_handle`: the escape hatch
    /// for code that took the raw lock itself. `pub` for linkage; not user-facing.
    pub unsafe fn locked_ref(self: &Mutex<T>) &T {
        return self.data.get_ref();
    }
    // --- guard-facing helpers (same module) ---------------------------------------------------.
    fn unlock_raw(self: &Mutex<T>) {
        // Paired with the `lock` that produced the guard being dropped.
        unsafe raw_mutex_unlock(self.raw.get());
    }
    fn data_ref(self: &Mutex<T>) &T {
        return self.data.get_ref();
    }
    fn data_mut(self: &Mutex<T>) &mut T {
        return &mut unsafe self.data.get()[0];
    }
}

extend<T> Mutex<T> as Free {
    pub fn free(self: &mut Mutex<T>) {
        // Deep-free the guarded value (no-op if T isn't Free).
        self.data.get().free();
        // `&mut self`: no guard can be outstanding, so no waiter can be queued either.
        unsafe sc_runtime::sc_rt_lockdep_forget(self.raw.get());
    }
}

extend<T> MutexGuard<T> {
    /// `pub` for external linkage: Mutex::lock is monomorphized in the caller's module. Not user-facing.
    pub fn hold(mutex: &Mutex<T>) MutexGuard<T> {
        return MutexGuard::<T> { mutex: mutex, _pin: null };
    }
    /// The underlying lock, for Condvar::wait to release and re-acquire. Not user-facing.
    pub fn lock_handle(self: &MutexGuard<T>) *mut RawMutex {
        // The guard proves the lock is held.
        return unsafe self.mutex.raw_handle();
    }
    /// Borrow the guarded value.
    pub fn get(self: &MutexGuard<T>) &T {
        return self.mutex.data_ref();
    }
    /// Mutably borrow the guarded value.
    pub fn get_mut(self: &mut MutexGuard<T>) &mut T {
        return self.mutex.data_mut();
    }
}

extend<T> MutexGuard<T> as Deref<T> {
    pub fn deref(self: &MutexGuard<T>) &T {
        return self.mutex.data_ref();
    }
}

extend<T> MutexGuard<T> as DerefMut<T> {
    pub fn deref_mut(self: &mut MutexGuard<T>) &mut T {
        return self.mutex.data_mut();
    }
}

extend<T> MutexGuard<T> as Free {
    pub fn free(self: &mut MutexGuard<T>) {
        self.mutex.unlock_raw();
    }
}

// RwLock: many readers OR one writer.

// Who holds the lock right now. `waiting_writers` gives writers priority: a new reader yields to a writer
// that is already queued, so a steady stream of readers cannot starve it.
@no_const
struct RwState {
    pub readers: i64,
    pub writer: bool,
    pub waiting_writers: i64,
}

/// A reader-writer lock guarding a `T`: any number of concurrent readers (`read`) or a single exclusive
/// writer (`write`), each returning an RAII guard. Waiting parks a coroutine rather than its worker. Share
/// it as `Arc<RwLock<T>>`.
@no_const
pub struct RwLock<T> {
    state: Mutex<RwState>, // held only while acquiring/releasing, never while the lock is held
    cv: Condvar, // signalled whenever the lock becomes free
    data: UnsafeCell<T>,
}

/// Shared read access; releases the read lock when dropped.
@no_const
pub struct RwLockReadGuard<'a, T> {
    lock: &'a RwLock<T>,
    // A guard means THIS thread holds the lock, so it must not cross to another: the unlock would run
    // where the lock never ran, and a task-aware lock queues its waiters against the acquiring
    // coroutine. A raw pointer is neither `Send` nor `Sync` structurally, and nothing transitively
    // holding one is either, so this dead field is what denies the guard both. It is never read.
    _pin: *const void,
}

/// Exclusive write access; releases the write lock when dropped.
@no_const
pub struct RwLockWriteGuard<'a, T> {
    lock: &'a RwLock<T>,
    // A guard means THIS thread holds the lock, so it must not cross to another: the unlock would run
    // where the lock never ran, and a task-aware lock queues its waiters against the acquiring
    // coroutine. A raw pointer is neither `Send` nor `Sync` structurally, and nothing transitively
    // holding one is either, so this dead field is what denies the guard both. It is never read.
    _pin: *const void,
}

// Send when `T` is; Sync additionally needs `T: Sync`, since concurrent readers alias `&T` across threads.
unsafe extend<T: Send> RwLock<T> as Send {}

unsafe extend<T: Send + Sync> RwLock<T> as Sync {}

extend<T> RwLock<T> {
    /// A new unlocked lock owning `value`.
    pub fn new(value: T) RwLock<T> {
        return RwLock::<T> {
            state: Mutex::<RwState>::new(RwState { readers: 0, writer: false, waiting_writers: 0 }),
            cv: Condvar::new(),
            data: UnsafeCell::<T>::new(value),
        };
    }
    /// Wait for shared read access.
    pub fn read(self: &RwLock<T>) RwLockReadGuard<T> {
        let mut g = self.state.lock();
        loop {
            let mut ready = false;
            {
                let s = g.get();
                ready = !s.writer && s.waiting_writers == 0;
            }
            if ready {
                break;
            }
            // A plain acquisition cannot unwind: never cancelled here.
            self.cv.wait_masked(&g);
        }
        let s = g.get_mut();
        s.readers = s.readers + 1;
        return RwLockReadGuard::<T>::hold(self);
    }
    /// `read`, but the wait is a cancellation point: `None` means cancelled, no read lock is held, and the
    /// cancellation is accepted. For callers that can propagate cancellation; ordinary code uses `read`.
    pub fn read_c(self: &RwLock<T>) Option<RwLockReadGuard<T>> {
        let mut g = self.state.lock();
        loop {
            let mut ready = false;
            {
                let s = g.get();
                ready = !s.writer && s.waiting_writers == 0;
            }
            if ready {
                break;
            }
            let r = unsafe self.cv.wait_raw(g.lock_handle(), 0, true, runtime::WK_RWLOCK);
            if r == runtime::WR_CANCEL || r == runtime::WR_SHUTDOWN {
                let _ = runtime::cancel_after_wait(true);
                // Cancelled: reader count untouched.
                return Option::<RwLockReadGuard<T>>::None;
            }
        }
        let s = g.get_mut();
        s.readers = s.readers + 1;
        return Option::<RwLockReadGuard<T>>::Some(RwLockReadGuard::<T>::hold(self));
    }
    /// Wait for exclusive write access.
    pub fn write(self: &RwLock<T>) RwLockWriteGuard<T> {
        let mut g = self.state.lock();
        {
            let s = g.get_mut();
            s.waiting_writers = s.waiting_writers + 1;
        }
        loop {
            let mut ready = false;
            {
                let s = g.get();
                ready = !s.writer && s.readers == 0;
            }
            if ready {
                break;
            }
            // A plain acquisition cannot unwind: never cancelled here.
            self.cv.wait_masked(&g);
        }
        let s = g.get_mut();
        s.waiting_writers = s.waiting_writers - 1;
        s.writer = true;
        return RwLockWriteGuard::<T>::hold(self);
    }
    /// `write`, but the wait is a cancellation point: `None` means cancelled. The queued-writer count is
    /// restored (and readers a gone writer no longer blocks are woken) before the cancellation propagates.
    pub fn write_c(self: &RwLock<T>) Option<RwLockWriteGuard<T>> {
        let mut g = self.state.lock();
        {
            let s = g.get_mut();
            s.waiting_writers = s.waiting_writers + 1;
        }
        loop {
            let mut ready = false;
            {
                let s = g.get();
                ready = !s.writer && s.readers == 0;
            }
            if ready {
                break;
            }
            let r = unsafe self.cv.wait_raw(g.lock_handle(), 0, true, runtime::WK_RWLOCK);
            if r == runtime::WR_CANCEL || r == runtime::WR_SHUTDOWN {
                let s = g.get_mut();
                s.waiting_writers = s.waiting_writers - 1;
                if s.waiting_writers == 0 {
                    // Readers held back by this writer may go now.
                    self.cv.notify_all();
                }
                let _ = runtime::cancel_after_wait(true);
                return Option::<RwLockWriteGuard<T>>::None;
            }
        }
        let s = g.get_mut();
        s.waiting_writers = s.waiting_writers - 1;
        s.writer = true;
        return Option::<RwLockWriteGuard<T>>::Some(RwLockWriteGuard::<T>::hold(self));
    }
    /// Take shared read access only if it is free right now; `None` if a writer holds or wants the lock.
    pub fn try_read(self: &RwLock<T>) Option<RwLockReadGuard<T>> {
        let mut g = self.state.lock();
        let mut ready = false;
        {
            let s = g.get();
            ready = !s.writer && s.waiting_writers == 0;
        }
        if !ready {
            return Option::<RwLockReadGuard<T>>::None;
        }
        let s = g.get_mut();
        s.readers = s.readers + 1;
        return Option::<RwLockReadGuard<T>>::Some(RwLockReadGuard::<T>::hold(self));
    }
    /// Take exclusive write access only if the lock is completely free; `None` otherwise.
    pub fn try_write(self: &RwLock<T>) Option<RwLockWriteGuard<T>> {
        let mut g = self.state.lock();
        let mut ready = false;
        {
            let s = g.get();
            ready = !s.writer && s.readers == 0;
        }
        if !ready {
            return Option::<RwLockWriteGuard<T>>::None;
        }
        let s = g.get_mut();
        s.writer = true;
        return Option::<RwLockWriteGuard<T>>::Some(RwLockWriteGuard::<T>::hold(self));
    }
    /// Direct `&mut` when owned uniquely (`&mut self`): no locking.
    pub fn get_mut(self: &mut RwLock<T>) &mut T {
        return &mut unsafe self.data.get()[0];
    }
    // Release shared access; the last reader out lets a waiting writer in.
    fn unlock_read(self: &RwLock<T>) {
        let mut g = self.state.lock();
        let mut last = false;
        {
            let s = g.get_mut();
            s.readers = s.readers - 1;
            last = s.readers == 0;
        }
        if last {
            // Under the paired lock: it guards the wait queue.
            self.cv.notify_all();
        }
    }
    // Release exclusive access.
    fn unlock_write(self: &RwLock<T>) {
        let mut g = self.state.lock();
        {
            let s = g.get_mut();
            s.writer = false;
        }
        self.cv.notify_all();
    }
    fn data_ref(self: &RwLock<T>) &T {
        return self.data.get_ref();
    }
    fn data_mut(self: &RwLock<T>) &mut T {
        return &mut unsafe self.data.get()[0];
    }
}

extend<T> RwLock<T> as Free {
    pub fn free(self: &mut RwLock<T>) {
        self.data.get().free();
        self.state.free();
    }
}

extend<T> RwLockReadGuard<T> {
    /// A guard for a read lock the caller already holds; dropping it calls `unlock_read`.
    pub fn hold(lock: &RwLock<T>) RwLockReadGuard<T> {
        return RwLockReadGuard::<T> { lock: lock, _pin: null };
    }
    /// Borrow the guarded value.
    pub fn get(self: &RwLockReadGuard<T>) &T {
        return self.lock.data_ref();
    }
}

extend<T> RwLockReadGuard<T> as Deref<T> {
    pub fn deref(self: &RwLockReadGuard<T>) &T {
        return self.lock.data_ref();
    }
}

extend<T> RwLockReadGuard<T> as Free {
    pub fn free(self: &mut RwLockReadGuard<T>) {
        self.lock.unlock_read();
    }
}

extend<T> RwLockWriteGuard<T> {
    /// A guard for a write lock the caller already holds; dropping it calls `unlock_write`.
    pub fn hold(lock: &RwLock<T>) RwLockWriteGuard<T> {
        return RwLockWriteGuard::<T> { lock: lock, _pin: null };
    }
    /// Borrow the guarded value.
    pub fn get(self: &RwLockWriteGuard<T>) &T {
        return self.lock.data_ref();
    }
    /// Mutably borrow the guarded value.
    pub fn get_mut(self: &mut RwLockWriteGuard<T>) &mut T {
        return self.lock.data_mut();
    }
}

extend<T> RwLockWriteGuard<T> as Deref<T> {
    pub fn deref(self: &RwLockWriteGuard<T>) &T {
        return self.lock.data_ref();
    }
}

extend<T> RwLockWriteGuard<T> as DerefMut<T> {
    pub fn deref_mut(self: &mut RwLockWriteGuard<T>) &mut T {
        return self.lock.data_mut();
    }
}

extend<T> RwLockWriteGuard<T> as Free {
    pub fn free(self: &mut RwLockWriteGuard<T>) {
        self.lock.unlock_write();
    }
}

// Condvar: block until another thread signals, paired with a Mutex.

// The waiter set: a FIFO of `Waiter` nodes, each in its waiter's frame, guarded by the paired mutex (so it
// sits in an `UnsafeCell` and is mutated through that, never structurally). Coroutines and plain threads
// queue alike; the node says which it is.
@no_const
struct CondQ {
    pub head: *mut Waiter,
    pub tail: *mut Waiter,
}

// Did this wake reason leave the wait in its normal (notified, timed out, or spurious) course, as opposed
// to a cancellation the caller must unwind through?
const fn cv_normal(reason: u32) bool {
    return reason != runtime::WR_CANCEL && reason != runtime::WR_SHUTDOWN;
}

fn wait_cancel_requested(reason: u32) bool {
    return reason == runtime::WR_CANCEL || reason == runtime::WR_SHUTDOWN || runtime::cancel_requested();
}

// Tell a multi-queue waiter (a `select`) which queue this notify came from, before waking it. Written under
// the queue's own mutex, which the waiter re-takes to unlink the node before it reads the value, so the
// write always lands while the node is still alive. It is a HINT: a notify that goes on to LOSE the wake
// race also writes, so the reader must re-check the arm it names. Two notifies under two different queue
// locks may write it at once, hence the atomic store (relaxed: whichever lands last is as good a hint).
fn publish_arm(wp: *mut Waiter) {
    let c = unsafe wp.claim;
    if c != null {
        atomic::store_i32(c, unsafe wp.arm, 0);
    }
}

// Spend one wake on a node just popped from a queue; false when that wait is already over (a coroutine's
// token claimed by its deadline or a cancellation, a plain thread that gave up), so the caller passes the
// wake to the next node. Called under the paired mutex, which is what keeps the node alive: its owner
// re-takes that mutex to unlink it before its frame ends. A plain thread's wake claims its word (0 to 1)
// and then unparks the ADDRESS, and the parking lot never reads through an address it is handed.
fn wake_waiter(wp: *mut Waiter) bool {
    publish_arm(wp);
    let co = unsafe wp.co;
    let mut won = false;
    if co != null {
        won = runtime::wake(co, unsafe wp.token);
    } else {
        let word = unsafe wp.os;
        won = atomic::cas_i32(word, 0, 1, false, 2, 0);
        if won {
            unsafe sc_runtime::sc_rt_unpark_one(word);
        }
    }
    if sync_stats_on() {
        if won {
            stat_add(&mut unsafe G_SYNC.wakes);
        } else {
            stat_add(&mut unsafe G_SYNC.wakes_stale);
        }
    }
    return won;
}

/// Sleep a plain thread on `word` (0 while it waits) until a waker claims it or `deadline` (a
/// `time::deadline_in` value; 0 waits forever) passes: the sleeping half of a queued plain-thread wait, once
/// the node is registered and the paired mutex released. Reports `WR_NOTIFY`, or `WR_TIMEOUT` when this call
/// claimed the word (2) first: a notify that pops the node afterwards finds it claimed and passes its wake
/// on. `pub` for `select`; not user-facing.
pub fn os_wait(word: *mut i32, deadline: u64) u32 {
    while atomic::load_i32(word, 1) == 0 {
        let mut rel = -1i64;
        if deadline != 0 {
            rel = time::remaining_ns(deadline) as i64;
            if rel == 0 {
                if atomic::cas_i32(word, 0, 2, false, 1, 1) {
                    return runtime::WR_TIMEOUT;
                }
                break;
            }
        }
        unsafe sc_runtime::sc_rt_park(word, 0, rel);
    }
    return runtime::WR_NOTIFY;
}

/// A condition variable. A coroutine that `wait`s PARKS (its worker runs other tasks); any other thread
/// blocks. `notify_one`/`notify_all` wake whichever kind is waiting, and must be called while holding the
/// paired mutex. Always re-check the condition in a loop after `wait`: wakeups may be spurious.
///
/// The waiter set is stored in the condvar itself, so a condvar costs no allocation and must not MOVE while
/// a waiter is queued: a waiter reaches back through `&self` to unlink its node. Nothing can, in practice,
/// because a waiter exists only once a second thread has the same condvar, which means it is shared through
/// a pointer and so is not moving. The same holds for the lock word in `Mutex<T>`.
@no_const
pub struct Condvar {
    wq: UnsafeCell<CondQ>, // the waiter set, guarded by the paired mutex; in place, so nothing is allocated
}

unsafe extend Condvar as Send {}

unsafe extend Condvar as Sync {}

extend Condvar {
    /// A new condition variable.
    pub fn new() Condvar {
        return Condvar { wq: UnsafeCell::<CondQ>::new(CondQ { head: null, tail: null }) };
    }
    /// Atomically release `guard`'s lock and wait until notified, then take it again before returning.
    /// A coroutine parks (freeing its worker); any other thread blocks. Re-check the condition in a loop:
    /// wakeups may be spurious. Reports `false` when the wait was CANCELLED: the paired mutex is re-held
    /// (so the guard stays sound and unlocks on drop), the wait node is removed, and the cancellation is
    /// accepted: the caller must stop waiting and return through its cleanup.
    pub fn wait<T>(self: &Condvar, guard: &MutexGuard<T>) bool {
        let reason = unsafe self.wait_raw(guard.lock_handle(), 0, true, runtime::WK_CONDVAR);
        if wait_cancel_requested(reason) {
            let _ = runtime::cancel_after_wait(true);
            return false;
        }
        return cv_normal(reason);
    }
    /// `wait`, but also returning once the monotonic `deadline` (a `time::deadline_in` value) has passed.
    /// A timeout reports `true`: as with `wait`, re-check the condition (and the deadline) in a loop.
    /// `false` means cancelled, exactly as for `wait`.
    pub fn wait_until<T>(self: &Condvar, guard: &MutexGuard<T>, deadline: u64) bool {
        let reason = unsafe self.wait_raw(guard.lock_handle(), deadline, true, runtime::WK_CONDVAR);
        if wait_cancel_requested(reason) {
            let _ = runtime::cancel_after_wait(true);
            return false;
        }
        return cv_normal(reason);
    }
    /// `wait` for a caller that cannot unwind (a lock acquisition loop, or cleanup): the park is never
    /// claimed by a cancellation, and a pending request stays for the next cancellation point.
    pub fn wait_masked<T>(self: &Condvar, guard: &MutexGuard<T>) {
        let _ = unsafe self.wait_raw(guard.lock_handle(), 0, false, runtime::WK_CONDVAR);
    }
    /// The whole wait, minus the generic guard: the public forms differ only in deadline and
    /// cancellability, so this is monomorphized once instead of per `T`. Returns the winning `WR_*` wake
    /// reason (plain threads always report a notify). `kind` is the wait-kind diagnostic the primitives
    /// above this condvar record (`WK_CONDVAR` for a bare wait). `pub` for linkage.
    pub unsafe fn wait_raw(self: &Condvar, m: *mut RawMutex, deadline: u64, cancellable: bool, kind: i32) u32 {
        let co = runtime::current();
        if co != null {
            // Queue up under the held lock, then park; the runtime releases the lock once our context is
            // saved. On resume, take it again: exactly the pthread_cond_wait contract. Re-taking the lock
            // may park us a second time while this node is still queued (when a deadline, not a notify, woke
            // us): harmless, because the node's token is spent and no notify can act on it.
            if sync_stats_on() {
                stat_add(&mut unsafe G_SYNC.cv_waits);
            }
            runtime::wait_note(kind, self.wq.get() as usize);
            let token = runtime::park_begin(co);
            let mut w = Waiter { co: co, token: token, arm: 0, next: null, claim: null, os: null };
            let wp = &mut w;
            self.register(wp);
            let reason = runtime::park_timed(token, deadline, commit_raw_unlock, m, cancellable);
            // Disarm BEFORE re-taking the lock, not after. Re-taking it may park us a second time, and a
            // park rewrites this coroutine's `deadline` and `tm_token`: while a stale timer entry still
            // points at us, and a worker walking that list under the scheduler lock is reading the very
            // fields being rewritten. TSan reports it; the damage is a timer acting on a coroutine that has
            // since parked on something else.
            if deadline != 0 {
                runtime::cancel_timer(co);
            }
            // On cancellation too, the paired mutex is REACQUIRED before the node is unlinked (the queue
            // is guarded by it) and before anything propagates: the caller's guard must own the mutex
            // again so its destructor can release it. The reacquire itself never cancels.
            raw_mutex_lock(m);
            // Still queued if the deadline or a cancellation is what woke us.
            self.unlink(wp);
            runtime::wait_clear();
            runtime::park_done(co);
            return reason;
        }
        // No coroutine to park: queue a node whose wake word is in this frame, drop the lock and sleep on
        // the word. A notify claims the word under the paired mutex, while the node is still queued, and
        // only then unparks the address, so a notify in the window before the sleep cannot be missed and a
        // wake is never spent on a wait that has given up. The mutex is re-taken before the node is
        // unlinked, so nothing points into this frame once it is gone. A plain thread has no task to cancel.
        if sync_stats_on() {
            stat_add(&mut unsafe G_SYNC.cv_blocks);
        }
        let mut word: i32 = 0;
        let mut w = Waiter { co: null, token: 0, arm: 0, next: null, claim: null, os: &mut word };
        let wp = &mut w;
        self.register(wp);
        raw_mutex_unlock(m);
        runtime::replay_release(); // about to block: in replay mode the pool runs while we do not
        let reason = os_wait(&mut word, deadline);
        raw_mutex_lock(m);
        self.unlink(wp);
        return reason;
    }
    /// Queue an externally-owned wait node. For a waiter that must sit on several queues at once (`select`);
    /// an ordinary `wait` builds its own node. Caller holds the paired mutex, and MUST `unregister` the node
    /// before it dies. `pub` for `select`; not user-facing.
    pub unsafe fn register(self: &Condvar, wp: *mut Waiter) {
        let q = self.wq.get();
        unsafe wp.next = null;
        if unsafe q.tail == null {
            unsafe q.head = wp;
        } else {
            unsafe q.tail.next = wp;
        }
        unsafe q.tail = wp;
    }
    /// Take a `register`ed node back off the queue (a no-op if a notify already popped it). Caller holds the
    /// paired mutex. `pub` for `select`; not user-facing.
    pub unsafe fn unregister(self: &Condvar, wp: *mut Waiter) {
        self.unlink(wp);
    }
    // Take a wait node off the queue if it is still on it (a notify pops its own). Caller holds the paired
    // lock. Mandatory before the waiter returns: the node lives in that frame.
    fn unlink(self: &Condvar, wp: *mut Waiter) {
        let q = self.wq.get();
        let mut prev: *mut Waiter = null;
        let mut cur = unsafe q.head;
        while cur != null && cur != wp {
            prev = cur;
            cur = unsafe cur.next;
        }
        if cur != wp {
            return;
        }
        if prev == null {
            unsafe q.head = unsafe wp.next;
        } else {
            unsafe prev.next = unsafe wp.next;
        }
        if unsafe q.tail == wp {
            unsafe q.tail = prev;
        }
        unsafe wp.next = null;
    }
    // Take the longest-queued node off the queue, or null. Caller holds the paired lock.
    fn pop(self: &Condvar) *mut Waiter {
        let q = self.wq.get();
        let wp = unsafe q.head;
        if wp == null {
            return null;
        }
        unsafe q.head = unsafe wp.next;
        if unsafe q.head == null {
            unsafe q.tail = null;
        }
        unsafe wp.next = null;
        return wp;
    }
    /// Wake one waiter. Call under the paired mutex.
    pub fn notify_one(self: &Condvar) {
        self.notify_some(1);
    }
    /// Wake up to `n` waiters, the longest-queued first: what a batch that delivered `n` items (or freed `n`
    /// slots) owes, since each one can admit one waiter and any more woken would only queue again. A node
    /// whose wait is already over does not count. Call under the paired mutex.
    pub fn notify_some(self: &Condvar, n: usize) {
        let mut left = n;
        while left > 0 {
            let wp = self.pop();
            if wp == null {
                if sync_stats_on() && left == n {
                    stat_add(&mut unsafe G_SYNC.notifies_idle);
                }
                return;
            }
            if wake_waiter(wp) {
                left = left - 1;
            }
        }
    }
    /// Wake every waiter. Call under the paired mutex.
    pub fn notify_all(self: &Condvar) {
        loop {
            let wp = self.pop();
            if wp == null {
                return;
            }
            let _ = wake_waiter(wp);
        }
    }
}

// Selectable: what `select` needs from an endpoint to wait on it beside others.

/// The three things `std::parallel::selector` needs in order to wait on an endpoint without knowing what it
/// carries: the lock to take by hand, the queue to sit on, and whether the operation would proceed. Conform
/// to it and your own type works in a `select` exactly as a channel does.
///
/// The contract, which is why every method is `unsafe`:
///
///  * `select_lock` and `select_queue` return raw pointers into your value. They must stay valid for as long
///    as the selector holds the arm, and they must be the SAME pair every call: the selector locks every
///    arm at once and orders them by address to avoid a deadlock.
///  * `select_ready` is called WITH `select_lock` held, and must not take it again.
///  * A ready answer must be honest: `select` will go on to perform the operation, and an arm that says it
///    is ready and then blocks parks a task nothing will wake.
pub interface Selectable {
    unsafe fn select_lock(self: &Self) *mut RawMutex;
    unsafe fn select_queue(self: &Self) *const Condvar;
    unsafe fn select_ready(self: &Self) bool;
}

// Once: run an initialiser exactly once across all threads.

/// Runs a closure a single time, no matter how many threads call `call_once`; later calls return
/// immediately. A relaxed atomic fast-path skips the lock once initialisation has completed.
@no_const
pub struct Once {
    done: atomics::Atomic<i32>,
    gate: Mutex<i32>,
}

unsafe extend Once as Send {}

unsafe extend Once as Sync {}

extend Once {
    /// A fresh, not-yet-run `Once`.
    pub fn new() Once {
        return Once { done: atomics::Atomic::<i32>::new(0), gate: Mutex::<i32>::new(0) };
    }
    /// Has the initialiser already run?
    pub fn is_completed(self: &Once) bool {
        return self.done.load(atomics::MemoryOrder::Acquire) == 1;
    }
    /// Run `f` if it has not run yet; otherwise return at once. Exactly one caller across all threads ever
    /// runs `f`. A relaxed atomic fast-path skips the lock once initialisation has completed.
    pub fn call_once<F: fn move()>(self: &Once, f: F) {
        if self.done.load(atomics::MemoryOrder::Acquire) == 1 {
            return;
        }
        let _g = self.gate.lock(); // held for the duration; unlocks at scope exit
        if self.done.load(atomics::MemoryOrder::Relaxed) == 0 {
            f();
            self.done.store(1, atomics::MemoryOrder::Release);
        }
    }
}

extend Once as Free {
    pub fn free(self: &mut Once) {
        self.gate.free();
    }
}

// WaitGroup: wait for a set of tasks to finish. Cheaply cloned; every clone shares one counter.

// The count is an ATOMIC, not the mutex's payload, and that is the whole design. `done` runs once per task
// in a fan-out, so putting it behind a task-aware lock made every task in the group queue through one
// mutex, and a task-aware lock parks the coroutine when it is contended, so the loser paid a context
// switch as well. Here all but the last `done` is a single atomic decrement that touches nothing shared
// but one cache line; the mutex is left holding nothing at all, and exists only so the last decrement and
// a waiter about to sleep cannot slip past each other.
@no_const
struct WaitGroupInner {
    pub count: atomics::Atomic<i64>,
    pub gate: Mutex<i32>, // guards no data: it is the handshake between the final `done` and `wait`
    pub cv: Condvar,
}

/// Tracks a count of outstanding tasks. `add` before spawning, `done` as each finishes, `wait` blocks until
/// the count reaches zero. Clone one into each worker; all clones share the same counter.
@no_const
pub struct WaitGroup {
    inner: arc::Arc<WaitGroupInner>,
}

extend WaitGroup {
    /// A new group with a zero count.
    pub fn new() WaitGroup {
        return WaitGroup {
            inner: arc::Arc::<WaitGroupInner>::new(
                WaitGroupInner { count: atomics::Atomic::<i64>::new(0), gate: Mutex::<i32>::new(0), cv: Condvar::new() },
            ),
        };
    }
    /// Another handle to the same group.
    pub fn clone(self: &WaitGroup) WaitGroup {
        return WaitGroup { inner: self.inner.clone() };
    }
    /// Add `n` to the outstanding count (before spawning that many tasks).
    pub fn add(self: &WaitGroup, n: i64) {
        let inner = self.inner.get();
        let _ = inner.count.fetch_add(n, atomics::MemoryOrder::Relaxed);
    }
    /// Mark one task finished; wakes waiters when the count reaches zero.
    pub fn done(self: &WaitGroup) {
        let inner = self.inner.get();
        // Release: everything this task did happens-before the waiter's Acquire read of zero.
        let left = inner.count.fetch_sub(1, atomics::MemoryOrder::AcqRel) - 1;
        if left > 0 {
            // The common case, and it costs one atomic: no lock, no wake, no park.
            return;
        }
        // Last one out. Take the gate before notifying: a waiter that has read a non-zero count but is not
        // yet inside `wait` holds it, so this cannot notify into the gap and leave that waiter asleep.
        // A waiter that saw the zero may already be dropping its handle, so from here down the gate and cv
        // are held up by `self`'s own handle alone: safe because Arc's AcqRel teardown orders every
        // handle's last touch (these included) before the free.
        let _g = inner.gate.lock(); // held for the duration; unlocks at scope exit, as in `call_once`
        inner.cv.notify_all();
    }
    /// `wait` for a caller that cannot unwind (runtime and compiler infrastructure): the park is never
    /// claimed by a cancellation, and a pending request stays for the next cancellation point.
    pub fn wait_masked(self: &WaitGroup) {
        let inner = self.inner.get();
        if inner.count.load(atomics::MemoryOrder::Acquire) <= 0 {
            return;
        }
        let g = inner.gate.lock();
        while inner.count.load(atomics::MemoryOrder::Acquire) > 0 {
            let _ = unsafe inner.cv.wait_raw(g.lock_handle(), 0, false, runtime::WK_WAIT_GROUP);
        }
    }
    /// Wait until the outstanding count reaches zero. A cancelled wait returns early with the count
    /// untouched (only the waiter is removed); the caller's cancellation cleanup takes over.
    pub fn wait(self: &WaitGroup) {
        let inner = self.inner.get();
        if inner.count.load(atomics::MemoryOrder::Acquire) <= 0 {
            // Already finished: never touch the lock at all.
            return;
        }
        let g = inner.gate.lock();
        while inner.count.load(atomics::MemoryOrder::Acquire) > 0 {
            let r = unsafe inner.cv.wait_raw(g.lock_handle(), 0, true, runtime::WK_WAIT_GROUP);
            if r == runtime::WR_CANCEL || r == runtime::WR_SHUTDOWN {
                let _ = runtime::cancel_after_wait(true);
                // Cancelled: no state to restore, the group keeps its count.
                return;
            }
        }
    }
    /// Wait for the count to reach zero, giving up after `d`; reports whether it reached zero. A cancelled
    /// wait reports `false` with the count untouched.
    pub fn wait_timeout(self: &WaitGroup, d: time::Duration) bool {
        let inner = self.inner.get();
        let deadline = time::deadline_in(d);
        if inner.count.load(atomics::MemoryOrder::Acquire) <= 0 {
            return true;
        }
        let g = inner.gate.lock();
        while inner.count.load(atomics::MemoryOrder::Acquire) > 0 {
            if time::remaining_ns(deadline) == 0 {
                return false;
            }
            let r = unsafe inner.cv.wait_raw(g.lock_handle(), deadline, true, runtime::WK_WAIT_GROUP);
            if r == runtime::WR_CANCEL || r == runtime::WR_SHUTDOWN {
                let _ = runtime::cancel_after_wait(true);
                return false;
            }
        }
        return true;
    }
}

extend WaitGroup as Free {
    pub fn free(self: &mut WaitGroup) {
        self.inner.free();
    }
}

// Barrier: release a fixed number of threads together.

@no_const
struct BarrierState {
    pub arrived: i64,
    pub generation: i64,
    pub broken: bool, // a participant was cancelled: this generation can never complete
}

@no_const
struct BarrierInner {
    pub state: Mutex<BarrierState>,
    pub cv: Condvar,
    pub threshold: i64,
}

/// A synchronisation point for a fixed number of threads: each `wait` blocks until `n` threads have
/// arrived, then all are released together. Reusable: it resets for the next round. Clone one per thread.
@no_const
pub struct Barrier {
    inner: arc::Arc<BarrierInner>,
}

extend Barrier {
    /// A barrier that releases once `n` threads have called `wait`.
    pub fn new(n: i64) Barrier {
        return Barrier {
            inner: arc::Arc::<BarrierInner>::new(
                BarrierInner {
                    state: Mutex::<BarrierState>::new(BarrierState { arrived: 0, generation: 0, broken: false }),
                    cv: Condvar::new(),
                    threshold: n,
                },
            ),
        };
    }
    /// Another handle to the same barrier.
    pub fn clone(self: &Barrier) Barrier {
        return Barrier { inner: self.inner.clone() };
    }
    /// Block until `n` threads have arrived at this barrier. Reports `true` when the generation completed
    /// normally. `false` means the barrier is BROKEN: a participant was cancelled, so this generation can
    /// never complete: every current and later waiter observes the break (the required participant count
    /// is never silently lowered) until an explicit `reset`.
    pub fn wait(self: &Barrier) bool {
        let inner = self.inner.get();
        let mut g = inner.state.lock();
        if g.get().broken {
            return false;
        }
        let gen = g.get().generation;
        let mut last = false;
        {
            let s = g.get_mut();
            s.arrived = s.arrived + 1;
            last = s.arrived >= inner.threshold;
        }
        if last {
            let s = g.get_mut();
            s.arrived = 0;
            s.generation = s.generation + 1;
            inner.cv.notify_all();
            return true;
        }
        while g.get().generation == gen && !g.get().broken {
            let r = unsafe inner.cv.wait_raw(g.lock_handle(), 0, true, runtime::WK_BARRIER);
            if r == runtime::WR_CANCEL || r == runtime::WR_SHUTDOWN {
                // A cancelled participant makes this generation impossible: break it and wake everyone,
                // so no other participant waits for an arrival that can never come.
                let s = g.get_mut();
                s.broken = true;
                inner.cv.notify_all();
                let _ = runtime::cancel_after_wait(true);
                return false;
            }
        }
        return !g.get().broken;
    }
    /// Clear a broken barrier and start a fresh generation. The only way a later generation can begin
    /// after a break; the caller decides when the participant set is whole again.
    pub fn reset(self: &Barrier) {
        let inner = self.inner.get();
        let mut g = inner.state.lock();
        let s = g.get_mut();
        s.arrived = 0;
        s.generation = s.generation + 1;
        s.broken = false;
        inner.cv.notify_all();
    }
}

extend Barrier as Free {
    pub fn free(self: &mut Barrier) {
        self.inner.free();
    }
}

// Semaphore: a counted set of permits.

@no_const
struct SemaphoreInner {
    pub permits: Mutex<i64>,
    pub cv: Condvar,
}

/// A counting semaphore: `acquire` takes a permit (blocking until one is free), `release` returns one.
/// Bound concurrency with it (e.g. a connection pool). Clone one per user; all clones share the count.
@no_const
pub struct Semaphore {
    inner: arc::Arc<SemaphoreInner>,
}

extend Semaphore {
    /// A semaphore starting with `permits` permits.
    pub fn new(permits: i64) Semaphore {
        return Semaphore {
            inner: arc::Arc::<SemaphoreInner>::new(
                SemaphoreInner { permits: Mutex::<i64>::new(permits), cv: Condvar::new() },
            ),
        };
    }
    /// Another handle to the same semaphore.
    pub fn clone(self: &Semaphore) Semaphore {
        return Semaphore { inner: self.inner.clone() };
    }
    /// `acquire` for a caller that cannot unwind (runtime and compiler infrastructure): the park is
    /// never claimed by a cancellation, and a pending request stays for the next cancellation point.
    pub fn acquire_masked(self: &Semaphore) {
        let inner = self.inner.get();
        let mut g = inner.permits.lock();
        while *g.get() <= 0 {
            let _ = unsafe inner.cv.wait_raw(g.lock_handle(), 0, false, runtime::WK_SEMAPHORE);
        }
        let c = g.get_mut();
        *c = *c - 1;
    }
    /// Block until a permit is available, then take it. A cancelled wait returns early WITHOUT a permit
    /// (none is consumed or created); the caller's cancellation cleanup takes over.
    pub fn acquire(self: &Semaphore) {
        let inner = self.inner.get();
        let mut g = inner.permits.lock();
        while *g.get() <= 0 {
            let r = unsafe inner.cv.wait_raw(g.lock_handle(), 0, true, runtime::WK_SEMAPHORE);
            if r == runtime::WR_CANCEL || r == runtime::WR_SHUTDOWN {
                let _ = runtime::cancel_after_wait(true);
                // Cancelled: only the waiter is removed.
                return;
            }
        }
        let c = g.get_mut();
        *c = *c - 1;
    }
    /// Take a permit, giving up after `d`; reports whether one was taken. A cancelled wait reports `false`
    /// and consumes nothing.
    pub fn acquire_timeout(self: &Semaphore, d: time::Duration) bool {
        let inner = self.inner.get();
        let deadline = time::deadline_in(d);
        let mut g = inner.permits.lock();
        while *g.get() <= 0 {
            if time::remaining_ns(deadline) == 0 {
                return false;
            }
            let r = unsafe inner.cv.wait_raw(g.lock_handle(), deadline, true, runtime::WK_SEMAPHORE);
            if r == runtime::WR_CANCEL || r == runtime::WR_SHUTDOWN {
                let _ = runtime::cancel_after_wait(true);
                return false;
            }
        }
        let c = g.get_mut();
        *c = *c - 1;
        return true;
    }
    /// Try to take a permit without waiting; returns whether one was taken.
    pub fn try_acquire(self: &Semaphore) bool {
        let inner = self.inner.get();
        let mut g = inner.permits.lock();
        let ok = *g.get() > 0;
        if ok {
            let c = g.get_mut();
            *c = *c - 1;
        }
        return ok;
    }
    /// Return a permit, waking one waiter.
    pub fn release(self: &Semaphore) {
        let inner = self.inner.get();
        let mut g = inner.permits.lock();
        {
            let c = g.get_mut();
            *c = *c + 1;
        }
        inner.cv.notify_one();
    }
}

extend Semaphore as Free {
    pub fn free(self: &mut Semaphore) {
        self.inner.free();
    }
}
