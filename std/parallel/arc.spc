// `Arc<T>`: a thread-safe, atomically reference-counted shared pointer. `clone` hands out another owning
// handle to the SAME heap value (a cheap atomic increment); the value and its block are freed when the last
// handle is dropped. Import with `import std::parallel::arc;`.
//
// Use it to share one value across threads: move an `Arc` into each thread (clone per thread), read through
// `get`. `Arc` gives shared (`&T`) access only -- for shared MUTATION put an atomic or a lock inside it
// (`Arc<Atomic<i64>>`, later `Arc<Mutex<T>>`).

import atomic;
import std::parallel::atomics as atomics;

// The shared heap block: the strong count sits beside the value so one allocation holds both.
struct ArcInner<T> {
    pub strong: usize,
    pub value: T,
}

/// A shared, atomically reference-counted handle to a `T`. Cloning is cheap and hands back another owner;
/// the value is freed exactly once, when the final handle is dropped.
pub struct Arc<T> {
    ptr: *mut ArcInner<T>,
}

extend<T> Arc<T> {
    /// Allocate `value` on the heap with a strong count of one.
    pub fn new(value: T) Arc<T> {
        let mut g = Global {};
        let p = g.alloc(sizeof(ArcInner<T>), alignof(ArcInner<T>)) as *mut ArcInner<T>;
        unsafe p[0] = ArcInner::<T> { strong: 1, value: value };
        return Arc::<T> { ptr: p };
    }
    /// Another owning handle to the same value (atomic increment of the strong count).
    pub fn clone(self: &Arc<T>) Arc<T> {
        // Relaxed: a new handle only requires the count be atomic, not ordered against other memory.
        let _ = unsafe atomic::add_usize(&mut (*self.ptr).strong, 1, atomics::MemoryOrder::Relaxed as i32);
        return Arc::<T> { ptr: self.ptr };
    }
    /// Borrow the shared value. Valid while this handle is alive.
    pub fn get(self: &Arc<T>) &T {
        return unsafe &(*self.ptr).value;
    }
    /// The current strong count (a snapshot; other threads may change it immediately).
    pub fn strong_count(self: &Arc<T>) usize {
        return unsafe atomic::load_usize(&(*self.ptr).strong, atomics::MemoryOrder::Relaxed as i32);
    }
}

// `Arc<T>` shares one value across threads, so it is `Send` and `Sync` exactly when its payload is safe to
// share -- `T: Send + Sync`. The conformances are explicit (unsafe) assertions: the raw pointer inside would
// otherwise make `Arc` structurally neither. The atomic strong count makes the reference counting itself
// race-free.
extend<T: Send + Sync> Arc<T> as Send {}

extend<T: Send + Sync> Arc<T> as Sync {}

// Dropping a handle atomically decrements the strong count; the thread that observes the count fall to zero
// owns the teardown -- it deep-frees the value and releases the block.
extend<T> Arc<T> as Free {
    pub fn free(self: &mut Arc<T>) {
        // Release: earlier writes through this handle must be visible to the thread that tears down.
        let prev = unsafe atomic::sub_usize(&mut (*self.ptr).strong, 1, atomics::MemoryOrder::Release as i32);
        if prev == 1 {
            // Acquire fence pairs with the Release decrements above so every prior handle's writes are
            // visible before we drop the value.
            atomics::fence(atomics::MemoryOrder::Acquire);
            // Free the value THROUGH a raw pointer (no-op if T isn't Free), like Box::free -- freeing the
            // place directly would be a conditional move out of a dereference.
            let vp = (&mut unsafe (*self.ptr).value) as *mut T;
            vp.free();
            let mut g = Global {};
            g.dealloc(self.ptr, sizeof(ArcInner<T>), alignof(ArcInner<T>));
        }
        self.ptr = null;
    }
}
