// OS threads. `spawn` moves an owning closure onto the heap and runs it on a fresh OS thread; the returned
// `JoinHandle<T>` hands back the closure's value from `join`. Import with `import std::parallel::thread;`.
//
// The thread itself comes from the platform substrate (`ffi/sc_rt.c`): pthreads on POSIX, `_beginthreadex`
// on Windows, one opaque handle either way: nothing here names a `pthread_t`.
//
// The closure must OWN everything it touches (an owning `fn move` closure): a detached thread outlives the
// launching call, so it may copy scalars and MOVE owned values (`String`, `Vector`, `Box`, `Arc`) in, but
// may not borrow a local: the borrow checker's escape rule rejects that at the call site. Cross-thread
// sharing goes through `Arc`; cross-thread mutation through an atomic or a lock. The value the closure
// returns crosses the boundary the other way, so it is `Send` too.
//
// Ownership of the result. The thread and the handle share one heap cell (`Cell<T>`): the thread is the
// PRODUCER (it writes the value and publishes `done`), the handle is the CONSUMER. Each holds one
// reference; the value is destroyed exactly once, by whichever side is last, unless `join` moved it out:
//
//   outcome                              value                       cell and thread handle
//   join, thread already finished        moved to the caller         cell freed by join; handle joined
//   join, thread still running           join waits, then as above   as above
//   handle dropped, thread finished      freed by the drop           cell freed by the drop; thread detached
//   handle dropped, thread running       freed by the thread         cell freed by the thread; detached
//   thread creation fails                never produced              payload, closure and cell released,
//                                                                    then fatal: no handle is returned
//   join fails                           not read                    nothing released: fatal
//   detach fails                         as the thread outcome       nothing released: fatal
//
// A failed join or detach is a programmer error the substrate cannot recover from (the handle no longer
// names a joinable thread, or the OS refused), so the process stops with a message rather than read a
// value that may not exist or free storage a live thread can still write.

import atomic;
import sc_runtime;

/// The shared result cell: raw value storage plus the two-party bookkeeping. `pub` for linkage only.
@no_const
pub struct Cell<T> {
    pub refs: i32, // atomic: the thread and the handle hold one each
    pub done: i32, // atomic: 1 once `value` holds the thread's result
    pub value: T, // written by the thread before `done`; raw storage until then
}

// Drop one reference. The last one frees the value (when the thread produced it and nobody moved it out)
// and the cell. Release/acquire on the count orders the thread's writes before the last holder's reads.
fn cell_drop<T>(c: *mut Cell<T>) {
    if atomic::sub_i32(&mut unsafe c.refs, 1, 3) != 1 {
        return;
    }
    if atomic::load_i32(&mut unsafe c.done, 1) == 1 && sizeof(T) != 0 {
        // The unclaimed value is destroyed in place: a read through the raw pointer would be a copy the
        // drop elaboration does not own. (A zero-sized value has no storage and nothing to destroy.)
        let vp = (&mut unsafe c.value) as *mut T;
        vp.free();
    }
    let mut g = Global {};
    unsafe g.dealloc(c, sizeof(Cell<T>), alignof(Cell<T>));
}

/// A closure body paired with the cell its return value lands in. Bundled into one heap block so the single
/// `void*` thread argument carries both; released by the trampoline once the body has run. `pub` for
/// linkage: `spawn` is monomorphized in the caller's module.
@no_const
pub struct ThreadPayload<F, T> {
    pub body: F,
    pub cell: *mut Cell<T>,
}

/// The C-ABI thread entry point: reconstruct the payload, release its block, run the body into the cell,
/// publish the result, drop the producer's reference. Monomorphized per (F, T); its address is handed to
/// `sc_rt_thread_create`. `pub` for linkage.
pub fn thread_entry<F: fn move() T, T>(arg: *mut void) *mut void {
    let pp = arg as *mut ThreadPayload<F, T>;
    let payload = unsafe {
        pp[0];
    };
    let mut g = Global {};
    unsafe g.dealloc(arg, sizeof(ThreadPayload<F, T>), alignof(ThreadPayload<F, T>));
    let f = payload.body;
    let c = payload.cell;
    unsafe c.value = f();
    atomic::store_i32(&mut unsafe c.done, 1, 2);
    cell_drop(c);
    return null;
}

/// A handle to a running thread. `join` blocks until the thread finishes and returns its value; the handle
/// is consumed. Dropping a handle without joining detaches the thread: it runs on, and its value is
/// destroyed when it finishes (or here, if it already has).
@no_const
pub struct JoinHandle<T> {
    handle: *mut void, // the substrate's opaque thread handle; join or detach consumes it
    cell: *mut Cell<T>, // the shared result cell; null once consumed
}

extend<T> JoinHandle<T> {
    /// `pub` for external linkage: `spawn` is monomorphized in the CALLER's module, so its call to this
    /// constructor must reach a non-static symbol. Not part of the intended surface: use `spawn`.
    pub fn from_parts(handle: *mut void, cell: *mut Cell<T>) JoinHandle<T> {
        return JoinHandle::<T> { handle: handle, cell: cell };
    }
    /// Block until the thread finishes and take its return value. Consumes the handle. A join the OS
    /// refuses is fatal: the value cannot be read and the cell cannot be released.
    pub fn join(self: JoinHandle<T>) T {
        let mut me = self;
        let rc = unsafe sc_runtime::sc_rt_thread_join(me.handle);
        if rc != 0 {
            panic("thread::join: the OS refused to join the thread");
        }
        // The thread has exited, so its `done` store and its reference drop happen-before this point:
        // the value is initialized and this is the last reference.
        let c = me.cell;
        me.handle = null;
        me.cell = null;
        let v = unsafe {
            c.value;
        };
        let mut g = Global {};
        unsafe g.dealloc(c, sizeof(Cell<T>), alignof(Cell<T>));
        return v;
    }
}

extend<T> JoinHandle<T> as Free {
    /// Detach the thread and give up this side's reference to its result.
    pub fn free(self: &mut JoinHandle<T>) {
        if self.cell == null {
            return;
        }
        if unsafe sc_runtime::sc_rt_thread_detach(self.handle) != 0 {
            panic("thread: the OS refused to detach the thread");
        }
        self.handle = null;
        let c = self.cell;
        self.cell = null;
        cell_drop(c);
    }
}

/// Spawn a new OS thread running `f`, returning a handle to await its result. `f` is an owning closure:
/// values it uses are moved in and freed on the thread; it may not borrow the caller's locals. `F: Send`
/// makes that safe: every captured value must itself be `Send`, so a raw pointer (or anything holding
/// one) cannot cross the boundary; share through `Arc` and mutate through an atomic or a lock instead.
/// `T: Send` is the same rule for the value coming back. `F: 'static` is what forbids capturing a borrow
/// of a caller local: the thread may outlive this call.
///
/// A thread the OS cannot create is fatal: the closure, its captures and the cell are released first, and
/// no handle is ever returned for a thread that does not exist.
pub fn spawn<F: fn move() T + Send + 'static, T: Send>(f: F) JoinHandle<T> {
    let mut g = Global {};
    let c = (unsafe g.alloc(sizeof(Cell<T>), alignof(Cell<T>))) as *mut Cell<T>;
    unsafe c.refs = 2;
    unsafe c.done = 0;
    let env = (unsafe g.alloc(sizeof(ThreadPayload<F, T>), alignof(ThreadPayload<F, T>))) as *mut ThreadPayload<F, T>;
    unsafe env[0] = ThreadPayload::<F, T> { body: f, cell: c };
    let mut h: *mut void = null;
    let rc = unsafe sc_runtime::sc_rt_thread_create(&mut h, thread_entry::<F, T>, env);
    if rc != 0 {
        // Nothing was published: take the payload back (freeing the closure and everything it owns),
        // release the cell, then stop.
        let payload = unsafe {
            env[0];
        };
        unsafe g.dealloc(env, sizeof(ThreadPayload<F, T>), alignof(ThreadPayload<F, T>));
        let _ = payload;
        unsafe g.dealloc(c, sizeof(Cell<T>), alignof(Cell<T>));
        panic("thread::spawn: the OS cannot create a thread");
    }
    return JoinHandle::<T>::from_parts(h, c);
}
