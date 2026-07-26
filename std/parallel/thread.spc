// OS threads. `spawn` moves an owning closure onto the heap and runs it on a fresh pthread; the returned
// `JoinHandle<T>` hands back the closure's value from `join`. Import with `import std::parallel::thread;`.
//
// The closure must OWN everything it touches (an owning `fn move` closure): a detached thread outlives the
// launching call, so it may copy scalars and MOVE owned values (`String`, `Vector`, `Box`, `Arc`) in, but
// may not borrow a local -- the borrow checker's escape rule rejects that at the call site. Cross-thread
// sharing goes through `Arc`; cross-thread mutation through an atomic or a lock.

import pthread;

// A closure body paired with the heap slot its return value lands in. Bundled into one heap block so the
// single `void*` pthread argument carries both; released by the trampoline once the body has run.
struct ThreadPayload<F, T> {
    body: F,
    result: *mut T,
}

extend<F: fn move() T, T> ThreadPayload<F, T> {
    fn make(body: F, result: *mut T) ThreadPayload<F, T> {
        return ThreadPayload::<F, T> { body: body, result: result };
    }
    // Consume the payload: run the body and store its value in the result slot.
    fn run(self: ThreadPayload<F, T>) {
        let f = self.body;
        unsafe self.result[0] = f();
    }
}

// Move `value` onto the heap through the global allocator, returning the owning raw pointer.
fn heap_alloc<T>(value: T) *mut T {
    let mut g = Global {};
    let p = g.alloc(sizeof(T), alignof(T)) as *mut T;
    unsafe p[0] = value;
    return p;
}

// The C-ABI thread entry point: reconstruct the payload, run the body into its result slot, release the
// payload block. Monomorphized per (F, T); its address is handed to `pthread_create`. The value travels
// back through the `result` slot the `JoinHandle` already holds, not through pthread's return channel.
fn thread_entry<F: fn move() T, T>(arg: *mut void) *mut void {
    let pp = arg as *mut ThreadPayload<F, T>;
    let payload = unsafe {
        pp[0];
    };
    let mut g = Global {};
    g.dealloc(arg, sizeof(ThreadPayload<F, T>), alignof(ThreadPayload<F, T>));
    payload.run();
    return null;
}

/// A handle to a running thread. `join` blocks until the thread finishes and returns its value; the handle
/// is consumed. Dropping a handle without joining detaches the thread (its value is never collected).
pub struct JoinHandle<T> {
    handle: pthread::pthread_t,
    result: *mut T, // heap slot the thread writes into; join reads then frees it
}

extend<T> JoinHandle<T> {
    // `pub` for external linkage: `spawn` is monomorphized in the CALLER's module, so its call to this
    // constructor must reach a non-static symbol. Not part of the intended surface -- use `spawn`.
    pub fn from_parts(handle: pthread::pthread_t, result: *mut T) JoinHandle<T> {
        return JoinHandle::<T> { handle: handle, result: result };
    }
    /// Block until the thread finishes and take its return value. Consumes the handle.
    pub fn join(self: JoinHandle<T>) T {
        let mut ret: *mut void = null;
        unsafe pthread::pthread_join(self.handle, &mut ret);
        let v = unsafe {
            self.result[0];
        };
        let mut g = Global {};
        g.dealloc(self.result, sizeof(T), alignof(T));
        return v;
    }
}

/// Spawn a new OS thread running `f`, returning a handle to await its result. `f` is an owning closure:
/// values it uses are moved in and freed on the thread; it may not borrow the caller's locals. `F: Send`
/// makes that safe -- every captured value must itself be `Send`, so a raw pointer (or anything holding
/// one) cannot cross the boundary; share through `Arc` and mutate through an atomic or a lock instead.
/// `F: 'static` is what forbids capturing a borrow of a caller local: the thread may outlive this call.
pub fn spawn<F: fn move() T + Send + 'static, T>(f: F) JoinHandle<T> {
    let mut g = Global {};
    let slot = g.alloc(sizeof(T), alignof(T)) as *mut T;
    let env = heap_alloc::<ThreadPayload<F, T>>(ThreadPayload::<F, T>::make(f, slot)) as *mut void;
    let mut h: pthread::pthread_t;
    unsafe pthread::pthread_create(&mut h, null, thread_entry::<F, T>, env);
    return JoinHandle::<T>::from_parts(h, slot);
}
