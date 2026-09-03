// FFI bindings for common pthread APIs. Import with `import pthread;`.
// Opaque pthread structs other than pthread_t are passed as `*mut void` to avoid baking in libc layouts;
// the sized handles for mutex/cond/rwlock are allocated + initialised by the `sc_*_new` shim below (their
// C sizes are platform-dependent). Carries `@c.link("pthread")` off Android; every call site requires `unsafe`.

// The `-l` rides on its own gated block rather than on the declarations, which every target needs: bionic
// keeps the pthread entry points in libc itself and ships no libpthread at all, so the NDK's linker fails
// on `-lpthread` instead of ignoring it the way macOS and glibc do.
@platform(!android)
@c.link("pthread")
extern "C" {}

extern "C" {
    /// A thread handle.
    pub type pthread_t;

    /// The calling thread's handle.
    pub fn pthread_self() pthread_t;
    /// Nonzero when two handles name the same thread.
    pub fn pthread_equal(a: pthread_t, b: pthread_t) i32;
    /// Start a thread running `start(arg)`; 0 on success, else an errno value. `attr` may be null.
    pub fn pthread_create(thread: *mut pthread_t, attr: *const void, start: fn(*mut void) *mut void, arg: *mut void) i32;
    /// Wait for a thread and take its return value (may be null); 0 or an errno value.
    pub fn pthread_join(thread: pthread_t, retval: *mut void) i32;
    /// Let the thread reclaim itself on exit; 0 or an errno value.
    pub fn pthread_detach(thread: pthread_t) i32;
    /// End the calling thread with `retval`; never returns.
    pub fn pthread_exit(retval: *mut void) void;

    /// Mutex. `pthread_mutex_trylock` returns 0 on success, EBUSY if already held.
    pub fn pthread_mutex_init(mutex: *mut void, attr: *const void) i32;
    /// Release a mutex's resources; it must be unlocked.
    pub fn pthread_mutex_destroy(mutex: *mut void) i32;
    /// Block until the mutex is held; 0 or an errno value.
    pub fn pthread_mutex_lock(mutex: *mut void) i32;
    /// Take the mutex without blocking; EBUSY when held.
    pub fn pthread_mutex_trylock(mutex: *mut void) i32;
    /// Release a mutex the caller holds.
    pub fn pthread_mutex_unlock(mutex: *mut void) i32;

    /// Condition variable. `wait` atomically releases `mutex` and blocks, re-acquiring it before returning.
    pub fn pthread_cond_wait(cond: *mut void, mutex: *mut void) i32;
    /// Wake one waiter.
    pub fn pthread_cond_signal(cond: *mut void) i32;
    /// Wake every waiter.
    pub fn pthread_cond_broadcast(cond: *mut void) i32;

    /// Read/write lock. `try*` return 0 on success, EBUSY if the lock could not be taken.
    pub fn pthread_rwlock_rdlock(rwlock: *mut void) i32;
    /// Take a read lock without blocking; EBUSY when a writer holds it.
    pub fn pthread_rwlock_tryrdlock(rwlock: *mut void) i32;
    /// Block until the write lock is held.
    pub fn pthread_rwlock_wrlock(rwlock: *mut void) i32;
    /// Take the write lock without blocking; EBUSY when held.
    pub fn pthread_rwlock_trywrlock(rwlock: *mut void) i32;
    /// Release a read or write lock the caller holds.
    pub fn pthread_rwlock_unlock(rwlock: *mut void) i32;
}
