// Task-aware synchronisation primitives. Import with `import std::parallel::sync;`.
//
// Every wait here is task-aware: a *coroutine* (anything running under `launch`) that cannot proceed PARKS
// -- it saves its context and hands its worker thread back to the scheduler, which runs other tasks -- and
// any other thread blocks on the platform parking lot. Nothing ever occupies a worker while waiting, so
// more tasks than workers can contend for a lock without deadlocking. `RawMutex` below is a one-word
// lock: uncontended acquire and release are one CAS each, and a contender spins briefly before parking.

import atomic;
import sc_runtime;
import std::parallel::atomics as atomics;
import std::parallel::arc as arc;
import std::parallel::runtime as runtime;
import std::parallel::time as time;

// -----------------------------------------------------------------------------------------------------
// RawMutex: the task-aware lock behind Mutex<T>, and the wait primitive the rest of the module reuses.
// -----------------------------------------------------------------------------------------------------

/// One entry in a wait queue: a parked coroutine plus the wake token of the park it is waiting out. It
/// lives on that coroutine's own stack, so waiting costs no allocation, and the waiter unlinks it before
/// returning. The token is what makes a wakeup park-specific: an entry a timed wait left behind is inert.
///
/// `claim`/`arm` serve a waiter queued on SEVERAL queues at once (a `select`): the notify that wins the
/// wake records which queue it came from, so the woken task retries that operation first. Null `claim` for
/// an ordinary single-queue wait, which already knows what woke it.
pub struct Waiter {
    pub co: *mut runtime::Coroutine,
    pub token: u32,
    pub arm: i32, // index to publish through `claim` (fills this struct's padding)
    pub next: *mut Waiter,
    pub claim: *mut i32,
}

/// The whole lock is the `locked` word: bit 0 is HELD, bit 1 says a waiter is (or is about to be) parked.
/// An uncontended acquire and release are one CAS each; a contender spins briefly (the critical sections
/// this guards are tens of nanoseconds) and only then parks -- a coroutine through the scheduler, any other
/// thread futex-style on a word in its own frame. `pub` for linkage: `Mutex<T>`'s methods are monomorphized
/// in the caller's module. Not a user-facing type.
///
/// Parked waiters queue in a STATIC bucket table (`sc_rt_lot_bucket`), keyed by the lock's address, not in
/// the lock itself -- and that placement is load-bearing. A `Mutex` may be freed the moment its final unlock
/// is observed (a lock that lives no longer than the work it guards, e.g. the data-parallel latch), so once
/// an unlock has published the release it may touch only memory that outlives the mutex: the static buckets
/// and the popped waiter's own frame, which cannot die before its wake. It never touches the lock again.
pub struct RawMutex {
    pub locked: i32,
}

// One parked lock waiter, living on that waiter's stack. A coroutine parks through the scheduler
// (`co`/`token`); any other thread parks on `oswake` in its own frame -- the waker names this node, never
// the (possibly already freed) mutex.
struct LotNode {
    pub co: *mut runtime::Coroutine, // null for an OS-thread waiter
    pub token: u32,
    pub oswake: i32, // 0 while parked; the waker publishes 1 before unparking this address (OS threads)
    pub addr: *mut void, // which lock: one bucket queues waiters of many locks
    pub next: *mut LotNode,
}

// The Super-C view of one static bucket (a 64-byte slot in sc_rt.c): a spinlock over a FIFO of nodes.
struct LotBucket {
    pub lock: i32,
    pub pad: i32,
    pub head: *mut LotNode,
    pub tail: *mut LotNode,
}

// Spins before a contender parks. The trade: spinning occupies a worker that could run other tasks, but a
// park costs microseconds (a context switch out and back, plus a wake) against a critical section of tens
// of nanoseconds -- so a bounded spin is cheaper for the SYSTEM, not just for this task. Sized to cover a
// typical holder's critical section a few times over, and nowhere near the cost of the park it avoids.
const MUTEX_SPIN: i32 = 256;

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

// Unlink and return the first node waiting on `addr`; `more` reports whether another remains behind it.
// Caller holds the bucket lock.
fn lot_pop(b: *mut LotBucket, addr: *mut void, more: &mut bool) *mut LotNode {
    *more = false;
    let mut prev: *mut LotNode = null;
    let mut cur = unsafe b.head;
    let mut found: *mut LotNode = null;
    while cur != null {
        let nx = unsafe cur.next;
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
    return found;
}

/// A new, unlocked raw lock. `pub` for linkage.
pub unsafe fn raw_mutex_new() *mut RawMutex {
    let mut g = Global {};
    let m = g.alloc(sizeof(RawMutex), alignof(RawMutex)) as *mut RawMutex;
    unsafe m[0] = RawMutex { locked: 0 };
    return m;
}

/// Destroy and release a raw lock. `pub` for linkage.
pub unsafe fn raw_mutex_free(m: *mut RawMutex) {
    let mut g = Global {};
    g.dealloc(m, sizeof(RawMutex), alignof(RawMutex));
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
        return; // uncontended: one CAS
    }
    raw_mutex_lock_slow(m);
}

fn raw_mutex_lock_slow(m: *mut RawMutex) {
    let w = &mut unsafe m.locked;
    let mut spins: i32 = 0;
    loop {
        let c = atomic::load_i32(w, 0);
        if (c & 1) == 0 {
            // Free: take it, PRESERVING the parked bit -- waiters may remain, and clearing it would let
            // the next unlock take its fast path straight past them.
            if atomic::cas_i32(w, c, c | 1, false, 1, 0) {
                return;
            }
            continue;
        }
        if spins < MUTEX_SPIN {
            spins = spins + 1;
            unsafe sc_runtime::sc_rt_cpu_relax();
            continue;
        }
        if c != 3 && !atomic::cas_i32(w, 1, 3, false, 0, 0) {
            continue; // the word moved under us: re-read and decide again
        }
        // The word reads held-with-waiters, so the next unlock takes its slow path. Enqueue while it STILL
        // reads that, validated under the bucket lock -- the unlock pops (or records a survivor) under the
        // same lock, so between the two an enqueued waiter is either woken or left counted, never lost.
        let b = lot_bucket(m);
        unsafe sc_runtime::sc_rt_spin_lock(&mut b.lock);
        if atomic::load_i32(w, 0) != 3 {
            unsafe sc_runtime::sc_rt_spin_unlock(&mut b.lock);
            continue; // released since we looked: try to take it instead of sleeping through it
        }
        let co = runtime::current();
        if co != null {
            // The node lives in this frame and is popped by the unlock that wakes us; the runtime releases
            // the bucket lock once our context is saved, so that unlock can never resume a coroutine that
            // is still switching out.
            let mut n = LotNode { co: co, token: runtime::park_begin(co), oswake: 0, addr: m, next: null };
            lot_push(b, &mut n);
            runtime::park_current(commit_lot_unlock, &mut unsafe b.lock);
        } else {
            let mut n = LotNode { co: null, token: 0, oswake: 0, addr: m, next: null };
            lot_push(b, &mut n);
            unsafe sc_runtime::sc_rt_spin_unlock(&mut b.lock);
            while atomic::load_i32(&mut n.oswake, 1) == 0 {
                unsafe sc_runtime::sc_rt_park(&mut n.oswake, 0, -1);
            }
        }
        spins = 0; // woken because the lock was just free: a fresh spin is worth it again
    }
}

/// Acquire the lock only if it is free; reports whether it was taken. Never waits.
pub unsafe fn raw_mutex_try_lock(m: *mut RawMutex) bool {
    let w = &mut unsafe m.locked;
    loop {
        let c = atomic::load_i32(w, 0);
        if (c & 1) != 0 {
            return false;
        }
        if atomic::cas_i32(w, c, c | 1, false, 1, 0) {
            return true;
        }
    }
}

/// Release the lock and wake the longest-parked waiter, if any. `pub` for linkage.
pub unsafe fn raw_mutex_unlock(m: *mut RawMutex) {
    if atomic::cas_i32(&mut unsafe m.locked, 1, 0, false, 2, 0) {
        return; // nobody parked: one CAS, and the lock is never touched again
    }
    raw_mutex_unlock_slow(m);
}

fn raw_mutex_unlock_slow(m: *mut RawMutex) {
    let b = lot_bucket(m);
    unsafe sc_runtime::sc_rt_spin_lock(&mut b.lock);
    let mut more = false;
    let n = lot_pop(b, m, &mut more);
    // The release store, and the LAST touch of the lock (see `RawMutex`): whoever acquires from here on may
    // legitimately free it. Everything below touches only the static bucket and the popped waiter's frame.
    let next_word = if more {
        2;
    } else {
        0;
    };
    atomic::store_i32(&mut unsafe m.locked, next_word, 2);
    unsafe sc_runtime::sc_rt_spin_unlock(&mut b.lock);
    if n == null {
        return; // a waiter set the bit but has not enqueued yet: it revalidates and sees the release
    }
    if unsafe n.co != null {
        // Cannot fail: a lock park is untimed, so nothing else can claim its token. The wakee RE-CONTENDS
        // rather than being handed the lock: with a ~2.3us wake latency, a hand-off serializes every
        // acquisition behind a wake (measured 781ns/lock on the contended-hammer lane against 296ns for
        // barging, and it tripled the batched pipeline floor), so losing to a spinner is throughput, not loss.
        let _ = runtime::wake(unsafe n.co, unsafe n.token);
    } else {
        atomic::store_i32(&mut unsafe n.oswake, 1, 2);
        unsafe sc_runtime::sc_rt_unpark_one(&mut n.oswake);
    }
}

/// A mutual-exclusion lock guarding a `T`. Only the holder can reach the value, through the RAII
/// `MutexGuard` returned by `lock` -- the lock is released when the guard is dropped. A contended `lock`
/// parks a coroutine instead of blocking its worker. Put one in an `Arc` to share it: `Arc<Mutex<T>>`.
pub struct Mutex<T> {
    raw: *mut RawMutex,
    data: UnsafeCell<T>,
}

/// The RAII lock token. Reach the guarded value with `guard.get()` / `guard.get_mut()`, or call methods on
/// it directly (`guard.push(..)` auto-derefs); the mutex unlocks when the guard is dropped. Cannot outlive
/// the `Mutex` it borrows.
pub struct MutexGuard<'a, T> {
    mutex: &'a Mutex<T>,
}

// A Mutex makes its contents shareable across threads, so `Mutex<T>` is Send + Sync whenever `T` is Send.
unsafe extend<T: Send> Mutex<T> as Send {}

unsafe extend<T: Send> Mutex<T> as Sync {}

extend<T> Mutex<T> {
    /// A new unlocked mutex owning `value`.
    pub fn new(value: T) Mutex<T> {
        // Safe here by construction: this is the only handle to a lock nobody can have taken yet.
        return Mutex::<T> { raw: unsafe raw_mutex_new(), data: UnsafeCell::<T>::new(value) };
    }
    /// Wait until the lock is acquired, then return the guard. A coroutine parks while it is held.
    pub fn lock(self: &Mutex<T>) MutexGuard<T> {
        // The guard is what keeps the promise: it holds the lock for exactly its own lifetime.
        unsafe raw_mutex_lock(self.raw);
        return MutexGuard::<T>::hold(self);
    }
    /// Try to acquire without waiting; `None` if it is already held.
    pub fn try_lock(self: &Mutex<T>) Option<MutexGuard<T>> {
        if unsafe raw_mutex_try_lock(self.raw) {
            return Option::<MutexGuard<T>>::Some(MutexGuard::<T>::hold(self));
        }
        return Option::<MutexGuard<T>>::None;
    }
    /// Direct `&mut` access when the mutex is owned uniquely (`&mut self`) -- no locking needed.
    pub fn get_mut(self: &mut Mutex<T>) &mut T {
        return &mut unsafe self.data.get()[0];
    }
    /// The underlying lock, to take and release by hand. For a wait that must hold several locks at once
    /// (`select`); everything else should use `lock`. `pub` for linkage; not user-facing.
    pub unsafe fn raw_handle(self: &Mutex<T>) *mut RawMutex {
        return self.raw;
    }
    /// The guarded value WITHOUT locking. Sound only while the caller holds `raw_handle` -- the escape hatch
    /// for code that took the raw lock itself. `pub` for linkage; not user-facing.
    pub unsafe fn locked_ref(self: &Mutex<T>) &T {
        return self.data.get_ref();
    }
    // --- guard-facing helpers (same module) ---------------------------------------------------
    fn unlock_raw(self: &Mutex<T>) {
        unsafe raw_mutex_unlock(self.raw); // paired with the `lock` that produced the guard being dropped
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
        self.data.get().free(); // deep-free the guarded value (no-op if T isn't Free)
        unsafe raw_mutex_free(self.raw); // `&mut self`: no guard can be outstanding
        self.raw = null;
    }
}

extend<T> MutexGuard<T> {
    // `pub` for external linkage: Mutex::lock is monomorphized in the caller's module. Not user-facing.
    pub fn hold(mutex: &Mutex<T>) MutexGuard<T> {
        return MutexGuard::<T> { mutex: mutex };
    }
    // The underlying lock, for Condvar::wait to release and re-acquire. Not user-facing.
    pub fn lock_handle(self: &MutexGuard<T>) *mut RawMutex {
        return unsafe self.mutex.raw_handle(); // the guard proves the lock is held
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

// -----------------------------------------------------------------------------------------------------
// RwLock: many readers OR one writer.
// -----------------------------------------------------------------------------------------------------

// Who holds the lock right now. `waiting_writers` gives writers priority: a new reader yields to a writer
// that is already queued, so a steady stream of readers cannot starve it.
struct RwState {
    pub readers: i64,
    pub writer: bool,
    pub waiting_writers: i64,
}

/// A reader-writer lock guarding a `T`: any number of concurrent readers (`read`) or a single exclusive
/// writer (`write`), each returning an RAII guard. Waiting parks a coroutine rather than its worker. Share
/// it as `Arc<RwLock<T>>`.
pub struct RwLock<T> {
    state: Mutex<RwState>, // held only while acquiring/releasing, never while the lock is held
    cv: Condvar, // signalled whenever the lock becomes free
    data: UnsafeCell<T>,
}

/// Shared read access; releases the read lock when dropped.
pub struct RwLockReadGuard<'a, T> {
    lock: &'a RwLock<T>,
}

/// Exclusive write access; releases the write lock when dropped.
pub struct RwLockWriteGuard<'a, T> {
    lock: &'a RwLock<T>,
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
            self.cv.wait(&g);
        }
        let s = g.get_mut();
        s.readers = s.readers + 1;
        return RwLockReadGuard::<T>::hold(self);
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
            self.cv.wait(&g);
        }
        let s = g.get_mut();
        s.waiting_writers = s.waiting_writers - 1;
        s.writer = true;
        return RwLockWriteGuard::<T>::hold(self);
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
    /// Direct `&mut` when owned uniquely (`&mut self`) -- no locking.
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
            self.cv.notify_all(); // under the paired lock: it guards the wait queue
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
        self.cv.free();
    }
}

extend<T> RwLockReadGuard<T> {
    pub fn hold(lock: &RwLock<T>) RwLockReadGuard<T> {
        return RwLockReadGuard::<T> { lock: lock };
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
    pub fn hold(lock: &RwLock<T>) RwLockWriteGuard<T> {
        return RwLockWriteGuard::<T> { lock: lock };
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

// -----------------------------------------------------------------------------------------------------
// Condvar: block until another thread signals, paired with a Mutex.
// -----------------------------------------------------------------------------------------------------

// The waiter set, guarded by the paired mutex -- so it is heap-boxed and reached through a raw pointer
// (mutated under that lock, never structurally). Coroutines queue their own `Waiter` nodes on `head`/`tail`;
// other threads park on `gen`, which every notify bumps, and `os_waiters` counts them so a notify with no
// thread waiting costs nothing.
struct CondQ {
    pub head: *mut Waiter,
    pub tail: *mut Waiter,
    pub gen: i32,
    pub os_waiters: i32,
}

// Tell a multi-queue waiter (a `select`) which queue this notify came from, before waking it. Written under
// the queue's own mutex, which the waiter re-takes to unlink the node before it reads the value -- so the
// write always lands while the node is still alive. It is a HINT: a notify that goes on to LOSE the wake
// race also writes, so the reader must re-check the arm it names.
fn publish_arm(wp: *mut Waiter) {
    let c = unsafe wp.claim;
    if c != null {
        unsafe *c = unsafe wp.arm;
    }
}

/// A condition variable. A coroutine that `wait`s PARKS (its worker runs other tasks); any other thread
/// blocks. `notify_one`/`notify_all` wake whichever kind is waiting, and must be called while holding the
/// paired mutex. Always re-check the condition in a loop after `wait` -- wakeups may be spurious.
pub struct Condvar {
    wq: *mut CondQ, // waiter set, guarded by the paired mutex
}

unsafe extend Condvar as Send {}

unsafe extend Condvar as Sync {}

extend Condvar {
    /// A new condition variable.
    pub fn new() Condvar {
        let mut g = Global {};
        let q = g.alloc(sizeof(CondQ), alignof(CondQ)) as *mut CondQ;
        unsafe q[0] = CondQ { head: null, tail: null, gen: 0, os_waiters: 0 };
        return Condvar { wq: q };
    }
    /// Atomically release `guard`'s lock and wait until notified, then take it again before returning.
    /// A coroutine parks (freeing its worker); any other thread blocks. Re-check the condition in a loop --
    /// wakeups may be spurious.
    pub fn wait<T>(self: &Condvar, guard: &MutexGuard<T>) {
        unsafe self.wait_raw(guard.lock_handle(), 0); // the guard proves the paired lock is held
    }
    /// `wait`, but also returning once the monotonic `deadline` (a `time::deadline_in` value) has passed.
    /// It reports nothing: as with `wait`, re-check the condition -- and the deadline -- in a loop.
    pub fn wait_until<T>(self: &Condvar, guard: &MutexGuard<T>, deadline: u64) {
        unsafe self.wait_raw(guard.lock_handle(), deadline); // the guard proves the paired lock is held
    }
    // The whole wait, minus the generic guard: `wait` and `wait_until` differ only in the deadline, so this
    // is monomorphized once instead of per `T`. `pub` for linkage.
    pub unsafe fn wait_raw(self: &Condvar, m: *mut RawMutex, deadline: u64) {
        let co = runtime::current();
        if co != null {
            // Queue up under the held lock, then park; the runtime releases the lock once our context is
            // saved. On resume, take it again -- exactly the pthread_cond_wait contract. Re-taking the lock
            // may park us a second time while this node is still queued (when a deadline, not a notify, woke
            // us): harmless, because the node's token is spent and no notify can act on it.
            let token = runtime::park_begin(co);
            let mut w = Waiter { co: co, token: token, arm: 0, next: null, claim: null };
            let wp = &mut w;
            if unsafe self.wq.tail == null {
                unsafe self.wq.head = wp;
            } else {
                unsafe self.wq.tail.next = wp;
            }
            unsafe self.wq.tail = wp;
            runtime::park_timed(token, deadline, commit_raw_unlock, m);
            // Disarm BEFORE re-taking the lock, not after. Re-taking it may park us a second time, and a
            // park rewrites this coroutine's `deadline` and `tm_token` -- while a stale timer entry still
            // points at us, and a worker walking that list under the scheduler lock is reading the very
            // fields being rewritten. TSan reports it; the damage is a timer acting on a coroutine that has
            // since parked on something else.
            if deadline != 0 {
                runtime::cancel_timer(co);
            }
            raw_mutex_lock(m);
            self.unlink(wp); // still queued if the deadline is what woke us
        } else {
            // No coroutine to park: publish that we are waiting, drop the lock and sleep on `gen`, which
            // every notify bumps before unparking -- so a notify in that window cannot be missed.
            let g = unsafe self.wq.gen;
            let w = &mut unsafe self.wq.gen;
            unsafe self.wq.os_waiters = unsafe self.wq.os_waiters + 1;
            raw_mutex_unlock(m);
            let rel = if deadline == 0 {
                -1i64;
            } else {
                time::remaining_ns(deadline) as i64;
            };
            unsafe sc_runtime::sc_rt_park(w, g, rel);
            raw_mutex_lock(m);
            unsafe self.wq.os_waiters = unsafe self.wq.os_waiters - 1;
        }
    }
    /// Queue an externally-owned wait node. For a waiter that must sit on several queues at once (`select`);
    /// an ordinary `wait` builds its own node. Caller holds the paired mutex, and MUST `unregister` the node
    /// before it dies. `pub` for `select`; not user-facing.
    pub unsafe fn register(self: &Condvar, wp: *mut Waiter) {
        unsafe wp.next = null;
        if unsafe self.wq.tail == null {
            unsafe self.wq.head = wp;
        } else {
            unsafe self.wq.tail.next = wp;
        }
        unsafe self.wq.tail = wp;
    }
    /// Take a `register`ed node back off the queue (a no-op if a notify already popped it). Caller holds the
    /// paired mutex. `pub` for `select`; not user-facing.
    pub unsafe fn unregister(self: &Condvar, wp: *mut Waiter) {
        self.unlink(wp);
    }
    // Take a wait node off the queue if it is still on it (a notify pops its own). Caller holds the paired
    // lock. Mandatory before the waiter returns: the node lives in that frame.
    fn unlink(self: &Condvar, wp: *mut Waiter) {
        let mut prev: *mut Waiter = null;
        let mut cur = unsafe self.wq.head;
        while cur != null && cur != wp {
            prev = cur;
            cur = unsafe cur.next;
        }
        if cur != wp {
            return;
        }
        if prev == null {
            unsafe self.wq.head = unsafe wp.next;
        } else {
            unsafe prev.next = unsafe wp.next;
        }
        if unsafe self.wq.tail == wp {
            unsafe self.wq.tail = prev;
        }
        unsafe wp.next = null;
    }
    // Publish a new generation and unpark the OS-thread waiters. Caller holds the paired lock.
    fn bump_gen(self: &Condvar) {
        if unsafe self.wq.os_waiters == 0 {
            return;
        }
        // ATOMIC, because the reader is not under this lock: `sc_rt_park` loads this word itself to re-check
        // the generation before it sleeps. A plain write against that atomic load is a data race whatever the
        // lock says, and it is the exact shape TSan reports first.
        let w = &mut unsafe self.wq.gen;
        atomic::store_i32(w, unsafe self.wq.gen + 1, 2);
        unsafe sc_runtime::sc_rt_unpark_all(w);
    }
    /// Wake one waiter. Call under the paired mutex. (OS-thread waiters share one park address, so they all
    /// wake and re-check -- a spurious wakeup, which the contract allows.)
    pub fn notify_one(self: &Condvar) {
        let mut woke = false;
        while !woke {
            let wp = unsafe self.wq.head;
            if wp == null {
                break;
            }
            unsafe self.wq.head = unsafe wp.next;
            if unsafe self.wq.head == null {
                unsafe self.wq.tail = null;
            }
            unsafe wp.next = null;
            publish_arm(wp);
            // false if that park is already over (its deadline claimed it): spend the wakeup on the next.
            woke = runtime::wake(unsafe wp.co, unsafe wp.token);
        }
        self.bump_gen();
    }
    /// Wake every waiter. Call under the paired mutex.
    pub fn notify_all(self: &Condvar) {
        let mut wp = unsafe self.wq.head;
        unsafe self.wq.head = null;
        unsafe self.wq.tail = null;
        while wp != null {
            let nx = unsafe wp.next;
            unsafe wp.next = null;
            publish_arm(wp);
            let _ = runtime::wake(unsafe wp.co, unsafe wp.token);
            wp = nx;
        }
        self.bump_gen();
    }
}

extend Condvar as Free {
    pub fn free(self: &mut Condvar) {
        let mut g = Global {};
        g.dealloc(self.wq, sizeof(CondQ), alignof(CondQ));
        self.wq = null;
    }
}

// -----------------------------------------------------------------------------------------------------
// Selectable: what `select` needs from an endpoint to wait on it beside others.
// -----------------------------------------------------------------------------------------------------

/// The three things `std::parallel::selector` needs in order to wait on an endpoint without knowing what it
/// carries: the lock to take by hand, the queue to sit on, and whether the operation would proceed. Conform
/// to it and your own type works in a `select` exactly as a channel does.
///
/// The contract, which is why every method is `unsafe`:
///
///  * `select_lock` and `select_queue` return raw pointers into your value. They must stay valid for as long
///    as the selector holds the arm, and they must be the SAME pair every call -- the selector locks every
///    arm at once and orders them by address to avoid a deadlock.
///  * `select_ready` is called WITH `select_lock` held, and must not take it again.
///  * A ready answer must be honest: `select` will go on to perform the operation, and an arm that says it
///    is ready and then blocks parks a task nothing will wake.
pub interface Selectable {
    unsafe fn select_lock(self: &Self) *mut RawMutex;
    unsafe fn select_queue(self: &Self) *const Condvar;
    unsafe fn select_ready(self: &Self) bool;
}

// -----------------------------------------------------------------------------------------------------
// Once: run an initialiser exactly once across all threads.
// -----------------------------------------------------------------------------------------------------

/// Runs a closure a single time, no matter how many threads call `call_once`; later calls return
/// immediately. A relaxed atomic fast-path skips the lock once initialisation has completed.
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

// -----------------------------------------------------------------------------------------------------
// WaitGroup: wait for a set of tasks to finish. Cheaply cloned; every clone shares one counter.
// -----------------------------------------------------------------------------------------------------

// The count is an ATOMIC, not the mutex's payload, and that is the whole design. `done` runs once per task
// in a fan-out, so putting it behind a task-aware lock made every task in the group queue through one
// mutex -- and a task-aware lock parks the coroutine when it is contended, so the loser paid a context
// switch as well. Here all but the last `done` is a single atomic decrement that touches nothing shared
// but one cache line; the mutex is left holding nothing at all, and exists only so the last decrement and
// a waiter about to sleep cannot slip past each other.
struct WaitGroupInner {
    pub count: atomics::Atomic<i64>,
    pub gate: Mutex<i32>, // guards no data: it is the handshake between the final `done` and `wait`
    pub cv: Condvar,
}

/// Tracks a count of outstanding tasks. `add` before spawning, `done` as each finishes, `wait` blocks until
/// the count reaches zero. Clone one into each worker; all clones share the same counter.
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
            return; // the common case, and it costs one atomic: no lock, no wake, no park
        }
        // Last one out. Take the gate before notifying: a waiter that has read a non-zero count but is not
        // yet inside `wait` holds it, so this cannot notify into the gap and leave that waiter asleep.
        let g = inner.gate.lock();
        inner.cv.notify_all();
        g.free();
    }
    /// Wait until the outstanding count reaches zero.
    pub fn wait(self: &WaitGroup) {
        let inner = self.inner.get();
        if inner.count.load(atomics::MemoryOrder::Acquire) <= 0 {
            return; // already finished: never touch the lock at all
        }
        let g = inner.gate.lock();
        while inner.count.load(atomics::MemoryOrder::Acquire) > 0 {
            inner.cv.wait(&g);
        }
    }
    /// Wait for the count to reach zero, giving up after `d`; reports whether it reached zero.
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
            inner.cv.wait_until(&g, deadline);
        }
        return true;
    }
}

extend WaitGroup as Free {
    pub fn free(self: &mut WaitGroup) {
        self.inner.free();
    }
}

// -----------------------------------------------------------------------------------------------------
// Barrier: release a fixed number of threads together.
// -----------------------------------------------------------------------------------------------------

struct BarrierState {
    pub arrived: i64,
    pub generation: i64,
}

struct BarrierInner {
    pub state: Mutex<BarrierState>,
    pub cv: Condvar,
    pub threshold: i64,
}

/// A synchronisation point for a fixed number of threads: each `wait` blocks until `n` threads have
/// arrived, then all are released together. Reusable -- it resets for the next round. Clone one per thread.
pub struct Barrier {
    inner: arc::Arc<BarrierInner>,
}

extend Barrier {
    /// A barrier that releases once `n` threads have called `wait`.
    pub fn new(n: i64) Barrier {
        return Barrier {
            inner: arc::Arc::<BarrierInner>::new(
                BarrierInner {
                    state: Mutex::<BarrierState>::new(BarrierState { arrived: 0, generation: 0 }),
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
    /// Block until `n` threads have arrived at this barrier.
    pub fn wait(self: &Barrier) {
        let inner = self.inner.get();
        let mut g = inner.state.lock();
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
            return;
        }
        while g.get().generation == gen {
            inner.cv.wait(&g);
        }
    }
}

extend Barrier as Free {
    pub fn free(self: &mut Barrier) {
        self.inner.free();
    }
}

// -----------------------------------------------------------------------------------------------------
// Semaphore: a counted set of permits.
// -----------------------------------------------------------------------------------------------------

struct SemaphoreInner {
    pub permits: Mutex<i64>,
    pub cv: Condvar,
}

/// A counting semaphore: `acquire` takes a permit (blocking until one is free), `release` returns one.
/// Bound concurrency with it (e.g. a connection pool). Clone one per user; all clones share the count.
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
    /// Block until a permit is available, then take it.
    pub fn acquire(self: &Semaphore) {
        let inner = self.inner.get();
        let mut g = inner.permits.lock();
        while *g.get() <= 0 {
            inner.cv.wait(&g);
        }
        let c = g.get_mut();
        *c = *c - 1;
    }
    /// Take a permit, giving up after `d`; reports whether one was taken.
    pub fn acquire_timeout(self: &Semaphore, d: time::Duration) bool {
        let inner = self.inner.get();
        let deadline = time::deadline_in(d);
        let mut g = inner.permits.lock();
        while *g.get() <= 0 {
            if time::remaining_ns(deadline) == 0 {
                return false;
            }
            inner.cv.wait_until(&g, deadline);
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
