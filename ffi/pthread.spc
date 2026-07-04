// FFI bindings for common pthread APIs. Import with `import pthread;`.
// Opaque pthread structs other than pthread_t are passed as `*mut void` to avoid baking in libc layouts.

@c.link("pthread")
extern "C" {
    pub type pthread_t;

    pub fn pthread_self() pthread_t;
    pub fn pthread_equal(a: pthread_t, b: pthread_t) i32;
    pub fn pthread_create(thread: *mut pthread_t, attr: *const void, start: fn(*mut void) *mut void, arg: *mut void) i32;
    pub fn pthread_join(thread: pthread_t, retval: *mut void) i32;
    pub fn pthread_detach(thread: pthread_t) i32;
    pub fn pthread_exit(retval: *mut void) void;

    pub fn pthread_mutex_init(mutex: *mut void, attr: *const void) i32;
    pub fn pthread_mutex_destroy(mutex: *mut void) i32;
    pub fn pthread_mutex_lock(mutex: *mut void) i32;
    pub fn pthread_mutex_unlock(mutex: *mut void) i32;
}
