// Blocking synchronisation primitives for OS threads, backed by pthread. Import with
// `import std::parallel::sync;`.

import pthread;
import std::parallel::atomics as atomics;
import std::parallel::arc as arc;

/// A mutual-exclusion lock guarding a `T`. Only the thread holding the lock can reach the value, through
/// the RAII `MutexGuard` returned by `lock` -- the lock is released when the guard is dropped. Put one in an
/// `Arc` to share it: `Arc<Mutex<T>>`.
pub struct Mutex<T> {
    handle: *mut void, // heap pthread_mutex_t (sc_mutex_new)
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
        return Mutex::<T> { handle: unsafe pthread::sc_mutex_new(), data: UnsafeCell::<T>::new(value) };
    }
    /// Block until the lock is acquired, then return the guard.
    pub fn lock(self: &Mutex<T>) MutexGuard<T> {
        let _ = unsafe pthread::pthread_mutex_lock(self.handle);
        return MutexGuard::<T>::hold(self);
    }
    /// Try to acquire without blocking; `None` if another thread holds it.
    pub fn try_lock(self: &Mutex<T>) Option<MutexGuard<T>> {
        if unsafe pthread::pthread_mutex_trylock(self.handle) == 0 {
            return Option::<MutexGuard<T>>::Some(MutexGuard::<T>::hold(self));
        }
        return Option::<MutexGuard<T>>::None;
    }
    /// Direct `&mut` access when the mutex is owned uniquely (`&mut self`) -- no locking needed.
    pub fn get_mut(self: &mut Mutex<T>) &mut T {
        return &mut unsafe self.data.get()[0];
    }
    // --- guard-facing helpers (same module) ---------------------------------------------------
    fn unlock_raw(self: &Mutex<T>) {
        let _ = unsafe pthread::pthread_mutex_unlock(self.handle);
    }
    fn raw_handle(self: &Mutex<T>) *mut void {
        return self.handle;
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
        unsafe pthread::sc_mutex_free(self.handle);
        self.handle = null;
    }
}

extend<T> MutexGuard<T> {
    // `pub` for external linkage: Mutex::lock is monomorphized in the caller's module. Not user-facing.
    pub fn hold(mutex: &Mutex<T>) MutexGuard<T> {
        return MutexGuard::<T> { mutex: mutex };
    }
    // The underlying OS mutex, for Condvar::wait to release+reacquire. Not user-facing.
    pub fn lock_handle(self: &MutexGuard<T>) *mut void {
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

/// A reader-writer lock guarding a `T`: any number of concurrent readers (`read`) or a single exclusive
/// writer (`write`), each returning an RAII guard. Share it as `Arc<RwLock<T>>`.
pub struct RwLock<T> {
    handle: *mut void, // heap pthread_rwlock_t (sc_rwlock_new)
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
        return RwLock::<T> { handle: unsafe pthread::sc_rwlock_new(), data: UnsafeCell::<T>::new(value) };
    }
    /// Block for shared read access.
    pub fn read(self: &RwLock<T>) RwLockReadGuard<T> {
        let _ = unsafe pthread::pthread_rwlock_rdlock(self.handle);
        return RwLockReadGuard::<T>::hold(self);
    }
    /// Block for exclusive write access.
    pub fn write(self: &RwLock<T>) RwLockWriteGuard<T> {
        let _ = unsafe pthread::pthread_rwlock_wrlock(self.handle);
        return RwLockWriteGuard::<T>::hold(self);
    }
    /// Non-blocking shared read; `None` if a writer holds the lock.
    pub fn try_read(self: &RwLock<T>) Option<RwLockReadGuard<T>> {
        if unsafe pthread::pthread_rwlock_tryrdlock(self.handle) == 0 {
            return Option::<RwLockReadGuard<T>>::Some(RwLockReadGuard::<T>::hold(self));
        }
        return Option::<RwLockReadGuard<T>>::None;
    }
    /// Non-blocking exclusive write; `None` if the lock is held.
    pub fn try_write(self: &RwLock<T>) Option<RwLockWriteGuard<T>> {
        if unsafe pthread::pthread_rwlock_trywrlock(self.handle) == 0 {
            return Option::<RwLockWriteGuard<T>>::Some(RwLockWriteGuard::<T>::hold(self));
        }
        return Option::<RwLockWriteGuard<T>>::None;
    }
    /// Direct `&mut` when owned uniquely (`&mut self`) -- no locking.
    pub fn get_mut(self: &mut RwLock<T>) &mut T {
        return &mut unsafe self.data.get()[0];
    }
    fn unlock_raw(self: &RwLock<T>) {
        let _ = unsafe pthread::pthread_rwlock_unlock(self.handle);
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
        unsafe pthread::sc_rwlock_free(self.handle);
        self.handle = null;
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
        self.lock.unlock_raw();
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
        self.lock.unlock_raw();
    }
}

// -----------------------------------------------------------------------------------------------------
// Condvar: block until another thread signals, paired with a Mutex.
// -----------------------------------------------------------------------------------------------------

/// A condition variable. Threads `wait` on it while holding a `MutexGuard` (the wait atomically releases
/// the mutex and re-acquires it before returning); other threads `notify_one`/`notify_all` to wake them.
/// Always re-check the condition in a loop after `wait` -- wakeups may be spurious.
pub struct Condvar {
    handle: *mut void, // heap pthread_cond_t (sc_cond_new)
}

extend Condvar as Send {}

extend Condvar as Sync {}

extend Condvar {
    /// A new condition variable.
    pub fn new() Condvar {
        return Condvar { handle: unsafe pthread::sc_cond_new() };
    }
    /// Atomically release `guard`'s mutex and block until notified, then re-acquire it before returning.
    /// Always re-check your condition in a loop afterwards -- wakeups may be spurious.
    pub fn wait<T>(self: &Condvar, guard: &MutexGuard<T>) {
        let _ = unsafe pthread::pthread_cond_wait(self.handle, guard.lock_handle());
    }
    /// Wake one waiting thread.
    pub fn notify_one(self: &Condvar) {
        let _ = unsafe pthread::pthread_cond_signal(self.handle);
    }
    /// Wake all waiting threads.
    pub fn notify_all(self: &Condvar) {
        let _ = unsafe pthread::pthread_cond_broadcast(self.handle);
    }
}

extend Condvar as Free {
    pub fn free(self: &mut Condvar) {
        unsafe pthread::sc_cond_free(self.handle);
        self.handle = null;
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
        return self.done.load() == 1;
    }
    /// Run `f` if it has not run yet; otherwise return at once. Exactly one caller across all threads ever
    /// runs `f`. A relaxed atomic fast-path skips the lock once initialisation has completed.
    pub fn call_once<F: fn move()>(self: &Once, f: F) {
        if self.done.load() == 1 {
            return;
        }
        let _g = self.gate.lock(); // held for the duration; unlocks at scope exit
        if self.done.load() == 0 {
            f();
            self.done.store(1);
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
    /// Block until the outstanding count reaches zero.
    pub fn wait(self: &WaitGroup) {
        let inner = self.inner.get();
        let g = inner.count.lock();
        while *g.get() > 0 {
            inner.cv.wait(&g);
        }
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
    /// Try to take a permit without blocking; returns whether one was taken.
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
