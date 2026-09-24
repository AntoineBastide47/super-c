// FFI bindings for the pthread thread calls. Import with `import pthread;`.
// Mutexes, condition variables and read/write locks are not bound: their storage size is platform-defined
// and Super-C cannot allocate it, so a binding could only be called on storage of a guessed size. Use
// `std::parallel::sync` (Mutex, Condvar, RwLock) instead.
// Carries `@c.link("pthread")` off Android; every call site requires `unsafe`.

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
}
