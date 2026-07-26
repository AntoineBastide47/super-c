// FFI bindings for common pthread APIs. Import with `import pthread;`.
// Opaque pthread structs other than pthread_t are passed as `*mut void` to avoid baking in libc layouts;
// the sized handles for mutex/cond/rwlock are allocated + initialised by the `sc_*_new` shim below (their
// C sizes are platform-dependent). Carries `@c.link("pthread")`; every call site requires `unsafe`.

@c.link("pthread")
extern "C" {
    pub type pthread_t;

    pub fn pthread_self() pthread_t;
    pub fn pthread_equal(a: pthread_t, b: pthread_t) i32;
    pub fn pthread_create(thread: *mut pthread_t, attr: *const void, start: fn(*mut void) *mut void, arg: *mut void) i32;
    pub fn pthread_join(thread: pthread_t, retval: *mut void) i32;
    pub fn pthread_detach(thread: pthread_t) i32;
    pub fn pthread_exit(retval: *mut void) void;

    // Mutex. `pthread_mutex_trylock` returns 0 on success, EBUSY if already held.
    pub fn pthread_mutex_init(mutex: *mut void, attr: *const void) i32;
    pub fn pthread_mutex_destroy(mutex: *mut void) i32;
    pub fn pthread_mutex_lock(mutex: *mut void) i32;
    pub fn pthread_mutex_trylock(mutex: *mut void) i32;
    pub fn pthread_mutex_unlock(mutex: *mut void) i32;

    // Condition variable. `wait` atomically releases `mutex` and blocks, re-acquiring it before returning.
    pub fn pthread_cond_wait(cond: *mut void, mutex: *mut void) i32;
    pub fn pthread_cond_signal(cond: *mut void) i32;
    pub fn pthread_cond_broadcast(cond: *mut void) i32;

    // Read/write lock. `try*` return 0 on success, EBUSY if the lock could not be taken.
    pub fn pthread_rwlock_rdlock(rwlock: *mut void) i32;
    pub fn pthread_rwlock_tryrdlock(rwlock: *mut void) i32;
    pub fn pthread_rwlock_wrlock(rwlock: *mut void) i32;
    pub fn pthread_rwlock_trywrlock(rwlock: *mut void) i32;
    pub fn pthread_rwlock_unlock(rwlock: *mut void) i32;
}
