// Task-aware synchronisation primitives. Import with `import std::parallel::sync;`.
//
// Every wait here is task-aware: a *coroutine* (anything running under `launch`) that cannot proceed PARKS
// -- it saves its context and hands its worker thread back to the scheduler, which runs other tasks -- and
// any other thread blocks on the platform parking lot. Nothing ever occupies a worker while waiting, so
// more tasks than workers can contend for a lock without deadlocking. `RawMutex` below is the one place
// that touches an OS mutex, and only for the few instructions that mutate its own fields.

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

/// Lock ownership is the `locked` flag; `inner` is an OS mutex held only for the handful of instructions
/// that touch this struct -- never across user code, and never across a park. A coroutine that finds the
/// lock held parks on `head`/`tail`; any other thread parks on the `locked` word itself. `pub` for linkage:
/// `Mutex<T>`'s methods are monomorphized in the caller's module. Not a user-facing type.
pub struct RawMutex {
    pub inner: *mut void, // OS mutex guarding this struct (sc_rt_mutex_new)
    pub locked: i32, // 0 free / 1 held; also the park word for OS-thread waiters
    pub os_waiters: i32, // OS threads parked on `locked`, so an unlock knows whether to unpark
    pub head: *mut Waiter, // parked coroutine waiters, FIFO
    pub tail: *mut Waiter,
}

/// A new, unlocked raw lock. `pub` for linkage.
pub fn raw_mutex_new() *mut RawMutex {
    let mut g = Global {};
    let m = g.alloc(sizeof(RawMutex), alignof(RawMutex)) as *mut RawMutex;
    unsafe m[0] = RawMutex {
        inner: unsafe sc_runtime::sc_rt_mutex_new(),
        locked: 0,
        os_waiters: 0,
        head: null,
        tail: null,
    };
    return m;
}

/// Destroy and release a raw lock. `pub` for linkage.
pub fn raw_mutex_free(m: *mut RawMutex) {
    unsafe sc_runtime::sc_rt_mutex_free((*m).inner);
    let mut g = Global {};
    g.dealloc(m, sizeof(RawMutex), alignof(RawMutex));
}

// The address OS-thread waiters park on: they sleep while it reads 1, and an unlock publishes 0 before
// unparking them, so a wakeup can never be missed.
fn park_word(m: *mut RawMutex) *mut i32 {
    return &mut unsafe (*m).locked;
}

// The park hand-off used inside `raw_mutex_lock`: release only the internal OS mutex, since the coroutine
// never held the lock itself.
fn commit_os_unlock(p: *mut void) {
    unsafe sc_runtime::sc_rt_mutex_unlock(p);
}

/// The park hand-off used by `Condvar::wait`: release the whole lock, so another task can take it while the
/// waiter sleeps. `pub` for linkage.
pub fn commit_raw_unlock(p: *mut void) {
    raw_mutex_unlock(p as *mut RawMutex);
}

/// Acquire the lock, parking the calling coroutine (or blocking the calling thread) while it is held.
pub fn raw_mutex_lock(m: *mut RawMutex) {
    unsafe sc_runtime::sc_rt_mutex_lock((*m).inner);
    while unsafe (*m).locked != 0 {
        let co = runtime::current();
        if co != null {
            // Queue up, then park: the runtime releases `inner` once our context is saved, so the unlock
            // that pops us can never resume a coroutine that is still switching out. The node lives in this
            // frame and is always popped by the unlock that wakes us.
            let mut w = Waiter { co: co, token: runtime::park_begin(co), arm: 0, next: null, claim: null };
            let wp = &mut w;
            if unsafe (*m).tail == null {
                unsafe (*m).head = wp;
            } else {
                unsafe (*(*m).tail).next = wp;
            }
            unsafe (*m).tail = wp;
            runtime::park_current(commit_os_unlock, unsafe (*m).inner);
            unsafe sc_runtime::sc_rt_mutex_lock((*m).inner);
        } else {
            let w = park_word(m);
            unsafe (*m).os_waiters = unsafe (*m).os_waiters + 1;
            unsafe sc_runtime::sc_rt_mutex_unlock((*m).inner);
            unsafe sc_runtime::sc_rt_park(w, 1, -1);
            unsafe sc_runtime::sc_rt_mutex_lock((*m).inner);
            unsafe (*m).os_waiters = unsafe (*m).os_waiters - 1;
        }
    }
    unsafe (*m).locked = 1;
    unsafe sc_runtime::sc_rt_mutex_unlock((*m).inner);
}

/// Acquire the lock only if it is free; reports whether it was taken. Never waits.
pub fn raw_mutex_try_lock(m: *mut RawMutex) bool {
    unsafe sc_runtime::sc_rt_mutex_lock((*m).inner);
    let free = unsafe (*m).locked == 0;
    if free {
        unsafe (*m).locked = 1;
    }
    unsafe sc_runtime::sc_rt_mutex_unlock((*m).inner);
    return free;
}

/// Release the lock and hand it on: wake the first queued coroutine whose wake claim we win, and unpark any
/// OS threads waiting on it. `pub` for linkage.
pub fn raw_mutex_unlock(m: *mut RawMutex) {
    unsafe sc_runtime::sc_rt_mutex_lock((*m).inner);
    unsafe (*m).locked = 0;
    let mut woke = false;
    while !woke {
        let wp = unsafe (*m).head;
        if wp == null {
            break;
        }
        unsafe (*m).head = unsafe (*wp).next;
        if unsafe (*m).head == null {
            unsafe (*m).tail = null;
        }
        unsafe (*wp).next = null;
        woke = runtime::wake(unsafe (*wp).co, unsafe (*wp).token);
    }
    // Unpark BEFORE releasing `inner`, so releasing the lock is the very last thing this unlock does to the
    // RawMutex: a `Mutex` freed as soon as its final unlock is observed (a lock that lives no longer than the
    // work it guards, e.g. the data-parallel latch) would otherwise be freed under us.
    if unsafe (*m).os_waiters > 0 {
        unsafe sc_runtime::sc_rt_unpark_all(park_word(m));
    }
    unsafe sc_runtime::sc_rt_mutex_unlock((*m).inner);
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
extend<T: Send> Mutex<T> as Send {}

extend<T: Send> Mutex<T> as Sync {}

extend<T> Mutex<T> {
    /// A new unlocked mutex owning `value`.
    pub fn new(value: T) Mutex<T> {
        return Mutex::<T> { raw: raw_mutex_new(), data: UnsafeCell::<T>::new(value) };
    }
    /// Wait until the lock is acquired, then return the guard. A coroutine parks while it is held.
    pub fn lock(self: &Mutex<T>) MutexGuard<T> {
        raw_mutex_lock(self.raw);
        return MutexGuard::<T>::hold(self);
    }
    /// Try to acquire without waiting; `None` if it is already held.
    pub fn try_lock(self: &Mutex<T>) Option<MutexGuard<T>> {
        if raw_mutex_try_lock(self.raw) {
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
    pub fn raw_handle(self: &Mutex<T>) *mut RawMutex {
        return self.raw;
    }
    /// The guarded value WITHOUT locking. Sound only while the caller holds `raw_handle` -- the escape hatch
    /// for code that took the raw lock itself. `pub` for linkage; not user-facing.
    pub fn locked_ref(self: &Mutex<T>) &T {
        return self.data.get_ref();
    }
    // --- guard-facing helpers (same module) ---------------------------------------------------
    fn unlock_raw(self: &Mutex<T>) {
        raw_mutex_unlock(self.raw);
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
        raw_mutex_free(self.raw);
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
        return self.mutex.raw_handle();
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
extend<T: Send> RwLock<T> as Send {}

extend<T: Send + Sync> RwLock<T> as Sync {}

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
    let c = unsafe (*wp).claim;
    if c != null {
        unsafe *c = unsafe (*wp).arm;
    }
}

/// A condition variable. A coroutine that `wait`s PARKS (its worker runs other tasks); any other thread
/// blocks. `notify_one`/`notify_all` wake whichever kind is waiting, and must be called while holding the
/// paired mutex. Always re-check the condition in a loop after `wait` -- wakeups may be spurious.
pub struct Condvar {
    wq: *mut CondQ, // waiter set, guarded by the paired mutex
}

extend Condvar as Send {}

extend Condvar as Sync {}

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
        self.wait_raw(guard.lock_handle(), 0);
    }
    /// `wait`, but also returning once the monotonic `deadline` (a `time::deadline_in` value) has passed.
    /// It reports nothing: as with `wait`, re-check the condition -- and the deadline -- in a loop.
    pub fn wait_until<T>(self: &Condvar, guard: &MutexGuard<T>, deadline: u64) {
        self.wait_raw(guard.lock_handle(), deadline);
    }
    // The whole wait, minus the generic guard: `wait` and `wait_until` differ only in the deadline, so this
    // is monomorphized once instead of per `T`. `pub` for linkage.
    pub fn wait_raw(self: &Condvar, m: *mut RawMutex, deadline: u64) {
        let co = runtime::current();
        if co != null {
            // Queue up under the held lock, then park; the runtime releases the lock once our context is
            // saved. On resume, take it again -- exactly the pthread_cond_wait contract. Re-taking the lock
            // may park us a second time while this node is still queued (when a deadline, not a notify, woke
            // us): harmless, because the node's token is spent and no notify can act on it.
            let token = runtime::park_begin(co);
            let mut w = Waiter { co: co, token: token, arm: 0, next: null, claim: null };
            let wp = &mut w;
            if unsafe (*self.wq).tail == null {
                unsafe (*self.wq).head = wp;
            } else {
                unsafe (*(*self.wq).tail).next = wp;
            }
            unsafe (*self.wq).tail = wp;
            runtime::park_timed(token, deadline, commit_raw_unlock, m);
            raw_mutex_lock(m);
            if deadline != 0 {
                runtime::cancel_timer(co); // drop the timer if a notify got here first
            }
            self.unlink(wp); // still queued if the deadline is what woke us
        } else {
            // No coroutine to park: publish that we are waiting, drop the lock and sleep on `gen`, which
            // every notify bumps before unparking -- so a notify in that window cannot be missed.
            let g = unsafe (*self.wq).gen;
            let w = &mut unsafe (*self.wq).gen;
            unsafe (*self.wq).os_waiters = unsafe (*self.wq).os_waiters + 1;
            raw_mutex_unlock(m);
            let rel = if deadline == 0 {
                -1i64;
            } else {
                time::remaining_ns(deadline) as i64;
            };
            unsafe sc_runtime::sc_rt_park(w, g, rel);
            raw_mutex_lock(m);
            unsafe (*self.wq).os_waiters = unsafe (*self.wq).os_waiters - 1;
        }
    }
    /// Queue an externally-owned wait node. For a waiter that must sit on several queues at once (`select`);
    /// an ordinary `wait` builds its own node. Caller holds the paired mutex, and MUST `unregister` the node
    /// before it dies. `pub` for `select`; not user-facing.
    pub fn register(self: &Condvar, wp: *mut Waiter) {
        unsafe (*wp).next = null;
        if unsafe (*self.wq).tail == null {
            unsafe (*self.wq).head = wp;
        } else {
            unsafe (*(*self.wq).tail).next = wp;
        }
        unsafe (*self.wq).tail = wp;
    }
    /// Take a `register`ed node back off the queue (a no-op if a notify already popped it). Caller holds the
    /// paired mutex. `pub` for `select`; not user-facing.
    pub fn unregister(self: &Condvar, wp: *mut Waiter) {
        self.unlink(wp);
    }
    // Take a wait node off the queue if it is still on it (a notify pops its own). Caller holds the paired
    // lock. Mandatory before the waiter returns: the node lives in that frame.
    fn unlink(self: &Condvar, wp: *mut Waiter) {
        let mut prev: *mut Waiter = null;
        let mut cur = unsafe (*self.wq).head;
        while cur != null && cur != wp {
            prev = cur;
            cur = unsafe (*cur).next;
        }
        if cur != wp {
            return;
        }
        if prev == null {
            unsafe (*self.wq).head = unsafe (*wp).next;
        } else {
            unsafe (*prev).next = unsafe (*wp).next;
        }
        if unsafe (*self.wq).tail == wp {
            unsafe (*self.wq).tail = prev;
        }
        unsafe (*wp).next = null;
    }
    // Publish a new generation and unpark the OS-thread waiters. Caller holds the paired lock.
    fn bump_gen(self: &Condvar) {
        if unsafe (*self.wq).os_waiters == 0 {
            return;
        }
        let w = &mut unsafe (*self.wq).gen;
        unsafe (*self.wq).gen = unsafe (*self.wq).gen + 1;
        unsafe sc_runtime::sc_rt_unpark_all(w);
    }
    /// Wake one waiter. Call under the paired mutex. (OS-thread waiters share one park address, so they all
    /// wake and re-check -- a spurious wakeup, which the contract allows.)
    pub fn notify_one(self: &Condvar) {
        let mut woke = false;
        while !woke {
            let wp = unsafe (*self.wq).head;
            if wp == null {
                break;
            }
            unsafe (*self.wq).head = unsafe (*wp).next;
            if unsafe (*self.wq).head == null {
                unsafe (*self.wq).tail = null;
            }
            unsafe (*wp).next = null;
            publish_arm(wp);
            // false if that park is already over (its deadline claimed it): spend the wakeup on the next.
            woke = runtime::wake(unsafe (*wp).co, unsafe (*wp).token);
        }
        self.bump_gen();
    }
    /// Wake every waiter. Call under the paired mutex.
    pub fn notify_all(self: &Condvar) {
        let mut wp = unsafe (*self.wq).head;
        unsafe (*self.wq).head = null;
        unsafe (*self.wq).tail = null;
        while wp != null {
            let nx = unsafe (*wp).next;
            unsafe (*wp).next = null;
            publish_arm(wp);
            let _ = runtime::wake(unsafe (*wp).co, unsafe (*wp).token);
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
// Once: run an initialiser exactly once across all threads.
// -----------------------------------------------------------------------------------------------------

/// Runs a closure a single time, no matter how many threads call `call_once`; later calls return
/// immediately. A relaxed atomic fast-path skips the lock once initialisation has completed.
pub struct Once {
    done: atomics::Atomic<i32>,
    gate: Mutex<i32>,
}

extend Once as Send {}

extend Once as Sync {}

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

struct WaitGroupInner {
    pub count: Mutex<i64>,
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
            inner: arc::Arc::<WaitGroupInner>::new(WaitGroupInner { count: Mutex::<i64>::new(0), cv: Condvar::new() }),
        };
    }
    /// Another handle to the same group.
    pub fn clone(self: &WaitGroup) WaitGroup {
        return WaitGroup { inner: self.inner.clone() };
    }
    /// Add `n` to the outstanding count (before spawning that many tasks).
    pub fn add(self: &WaitGroup, n: i64) {
        let inner = self.inner.get();
        let mut g = inner.count.lock();
        let c = g.get_mut();
        *c = *c + n;
    }
    /// Mark one task finished; wakes waiters when the count reaches zero.
    pub fn done(self: &WaitGroup) {
        let inner = self.inner.get();
        let mut g = inner.count.lock();
        {
            let c = g.get_mut();
            *c = *c - 1;
        }
        let zero = *g.get() <= 0;
        if zero {
            inner.cv.notify_all();
        }
    }
    /// Wait until the outstanding count reaches zero.
    pub fn wait(self: &WaitGroup) {
        let inner = self.inner.get();
        let g = inner.count.lock();
        while *g.get() > 0 {
            inner.cv.wait(&g);
        }
    }
    /// Wait for the count to reach zero, giving up after `d`; reports whether it reached zero.
    pub fn wait_timeout(self: &WaitGroup, d: time::Duration) bool {
        let inner = self.inner.get();
        let deadline = time::deadline_in(d);
        let g = inner.count.lock();
        while *g.get() > 0 {
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
