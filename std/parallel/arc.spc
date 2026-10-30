// `Arc<T>`: a thread-safe, atomically reference-counted shared pointer, and `Weak<T>`, a handle that does
// not keep the value alive. `clone` hands out another owning handle to the SAME heap value (a cheap atomic
// increment); `downgrade` hands out a `Weak`, and `Weak::upgrade` an `Arc` while the value lives. The
// strong handles together count as one weak reference: the last strong drop frees the value, and the
// last handle of either kind frees the block. Import with `import std::parallel::arc;`.
//
// Use it to share one value across threads: move an `Arc` into each thread (clone per thread), read through
// `get`. `Arc` gives shared (`&T`) access only: for shared MUTATION put an atomic or a lock inside it
// (`Arc<Atomic<i64>>`, `Arc<Mutex<T>>`), or take `get_mut` while the handle is unique. Every operation is
// O(1) apart from the value's own `free`; `new` allocates the block from `Global`. The algorithm and its
// memory orderings are Rust's `alloc::sync::Arc`.

import atomic;
import std::parallel::atomics as atomics;

// Above this count an increment panics: forgotten handles could otherwise wrap a count to zero and free a
// value still in use. Half the range leaves room for the increments other threads make before they see it.
const MAX_REFCOUNT: usize = isize::MAX as usize;

// The weak count while `get_mut` checks uniqueness: `downgrade` waits for the check to end.
const WEAK_LOCKED: usize = ~(0 as usize);

// The shared heap block: both counts sit beside the value so one allocation holds all three. `weak`
// counts the `Weak` handles plus one for all strong handles together.
@no_const
struct ArcInner<T> {
    pub strong: usize,
    pub weak: usize,
    pub value: T,
}

/// A shared, atomically reference-counted handle to a `T`. Cloning is cheap and hands back another owner;
/// the value is freed exactly once, when the final strong handle is dropped.
@no_const
pub struct Arc<T> {
    ptr: *mut ArcInner<T>,
}

/// A handle to an `Arc`'s block that does not keep the value alive: `upgrade` gives an `Arc` while the
/// value lives, `None` from the moment its strong count reaches zero. `Weak::new` points at nothing.
@no_const
pub struct Weak<T> {
    ptr: *mut ArcInner<T>, // null for `Weak::new`
}

extend<T> Arc<T> {
    /// Allocate `value` on the heap with a strong count of one.
    pub fn new(value: T) Arc<T> {
        let mut g = Global {};
        let p = (unsafe g.alloc(sizeof(ArcInner<T>), alignof(ArcInner<T>))) as *mut ArcInner<T>;
        unsafe p[0] = ArcInner::<T> { strong: 1, weak: 1, value: value };
        return Arc::<T> { ptr: p };
    }
    /// Another owning handle to the same value (atomic increment of the strong count). Panics: the count
    /// passes `isize::MAX`.
    pub fn clone(self: &Arc<T>) Arc<T> {
        // Relaxed: a new handle only requires the count be atomic, not ordered against other memory. The
        // caller's handle keeps the count above zero, so no drop can race to the teardown.
        let old = unsafe atomic::add_usize(self.strong_ptr(), 1, atomics::MemoryOrder::Relaxed as i32);
        if old > MAX_REFCOUNT {
            panic("Arc: reference count overflow");
        }
        return Arc::<T> { ptr: self.ptr };
    }
    /// Borrow the shared value. Valid while this handle is alive.
    pub fn get(self: &Arc<T>) &T {
        return unsafe &(*self.ptr).value;
    }
    /// The current strong count (a snapshot; other threads may change it immediately).
    pub fn strong_count(self: &Arc<T>) usize {
        return unsafe atomic::load_usize(self.strong_ptr(), atomics::MemoryOrder::Relaxed as i32);
    }
    /// The current number of `Weak` handles (a snapshot; other threads may change it immediately).
    pub fn weak_count(self: &Arc<T>) usize {
        let n = unsafe atomic::load_usize(self.weak_ptr(), atomics::MemoryOrder::Relaxed as i32);
        // Locked by a `get_mut` check, which locks it only at 1: no `Weak` exists.
        if n == WEAK_LOCKED {
            return 0;
        }
        return n - 1;
    }
    /// A new `Weak` handle to this block. Panics: the weak count passes `isize::MAX`.
    pub fn downgrade(self: &Arc<T>) Weak<T> {
        let w = self.weak_ptr();
        let mut n = unsafe atomic::load_usize(w, atomics::MemoryOrder::Relaxed as i32);
        // Lock-free: a failed exchange means another thread changed the count, and a `get_mut` check
        // holds the lock for two atomic operations only.
        loop {
            if n != WEAK_LOCKED {
                if n > MAX_REFCOUNT {
                    panic("Arc: reference count overflow");
                }
                // Acquire on success pairs with the Release store that ends a `get_mut` check, so a check
                // that saw the count at 1 is complete before this `Weak` exists.
                if unsafe atomic::cas_usize(
                    w,
                    n,
                    n + 1,
                    true,
                    atomics::MemoryOrder::Acquire as i32,
                    atomics::MemoryOrder::Relaxed as i32,
                ) {
                    return Weak::<T>::from_block(self.ptr);
                }
            }
            n = unsafe atomic::load_usize(w, atomics::MemoryOrder::Relaxed as i32);
        }
    }
    /// A mutable borrow of the value when this is the only handle of either kind, else `None`.
    pub fn get_mut(self: &mut Arc<T>) Option<&mut T> {
        if !self.is_unique() {
            return None;
        }
        return Some(&mut unsafe (*self.ptr).value);
    }
    /// The value, when this is the only strong handle; else this handle back as `Err`. `Weak` handles do
    /// not prevent it: they fail to upgrade afterwards.
    pub fn try_unwrap(self: Arc<T>) Result<T, Arc<T>> {
        // Acquire on success, where Rust has a Relaxed exchange then an Acquire fence (a fence is outside
        // TSan's model): every other handle's last use of the value, published by the Release half of its
        // AcqRel decrement, happens before the value moves out.
        if !unsafe atomic::cas_usize(
            self.strong_ptr(),
            1,
            0,
            false,
            atomics::MemoryOrder::Acquire as i32,
            atomics::MemoryOrder::Relaxed as i32,
        ) {
            return Err(self);
        }
        let p = self.ptr;
        forget(self);
        let value = unsafe (*p).value;
        // Releases the strong handles' weak reference: frees the block when no `Weak` remains.
        let _collective = Weak::<T>::from_block(p);
        return Ok(value);
    }
    /// True when both handles point at the same block.
    pub fn ptr_eq(self: &Arc<T>, other: &Arc<T>) bool {
        return self.ptr == other.ptr;
    }

    // True when this is the only handle of either kind. Locks the weak count at 1 so that no `downgrade`
    // can run between the two reads: a `Weak` made and its strong source dropped in that window would
    // otherwise read as unique.
    fn is_unique(self: &mut Arc<T>) bool {
        let w = self.weak_ptr();
        // Acquire pairs with the Release half of a `Weak`'s last decrement (`Weak::free`), so its uses of
        // the block happen before this handle takes the value as its own.
        if !unsafe atomic::cas_usize(
            w,
            1,
            WEAK_LOCKED,
            false,
            atomics::MemoryOrder::Acquire as i32,
            atomics::MemoryOrder::Relaxed as i32,
        ) {
            return false;
        }
        // Acquire pairs with the Release half of the strong decrements, so every other strong handle's
        // last use of the value happens before the caller writes it.
        let unique = unsafe atomic::load_usize(self.strong_ptr(), atomics::MemoryOrder::Acquire as i32) == 1;
        // Release: the read above happens before any `downgrade` that sees the unlocked count.
        unsafe atomic::store_usize(w, 1, atomics::MemoryOrder::Release as i32);
        return unique;
    }

    // A strong handle for block `p`, whose strong count already counts it.
    fn from_block(p: *mut ArcInner<T>) Arc<T> {
        return Arc::<T> { ptr: p };
    }

    // The counts as raw pointers for the atomic calls: other threads change them, so no reference to them
    // is held.
    fn strong_ptr(self: &Arc<T>) *mut usize {
        return unsafe &mut (*self.ptr).strong;
    }

    fn weak_ptr(self: &Arc<T>) *mut usize {
        return unsafe &mut (*self.ptr).weak;
    }
}

extend<T> Weak<T> {
    /// A handle to no block: `upgrade` returns `None`. Allocates nothing.
    pub fn new() Weak<T> {
        return Weak::<T> { ptr: null };
    }
    /// A new strong handle while the value lives, else `None`. Never makes a strong count of zero
    /// nonzero again, so a freed value stays freed. Panics: the count passes `isize::MAX`.
    pub fn upgrade(self: &Weak<T>) Option<Arc<T>> {
        if self.ptr == null {
            return None;
        }
        let s = (unsafe &mut (*self.ptr).strong) as *mut usize;
        let mut n = unsafe atomic::load_usize(s, atomics::MemoryOrder::Relaxed as i32);
        // Lock-free: a failed exchange means another thread changed the count.
        loop {
            if n == 0 {
                return None;
            }
            if n > MAX_REFCOUNT {
                panic("Arc: reference count overflow");
            }
            // Acquire on success, as in Rust, where it orders the read of a value that a cyclic
            // constructor stores after the `Weak` exists; Relaxed on failure, which only retries.
            if unsafe atomic::cas_usize(
                s,
                n,
                n + 1,
                true,
                atomics::MemoryOrder::Acquire as i32,
                atomics::MemoryOrder::Relaxed as i32,
            ) {
                return Some(Arc::<T>::from_block(self.ptr));
            }
            n = unsafe atomic::load_usize(s, atomics::MemoryOrder::Relaxed as i32);
        }
    }
    /// The current strong count: 0 once the value is freed, and for `Weak::new` (a snapshot).
    pub fn strong_count(self: &Weak<T>) usize {
        if self.ptr == null {
            return 0;
        }
        return unsafe atomic::load_usize(&(*self.ptr).strong, atomics::MemoryOrder::Relaxed as i32);
    }
    /// Another weak handle to the same block. Panics: the weak count passes `isize::MAX`.
    pub fn clone(self: &Weak<T>) Weak<T> {
        if self.ptr != null {
            // Relaxed, as `Arc::clone`: this handle keeps the weak count above zero. The count is never
            // locked here: a `get_mut` check locks it only at 1, a count no `Weak` handle leaves.
            let w = (unsafe &mut (*self.ptr).weak) as *mut usize;
            let old = unsafe atomic::add_usize(w, 1, atomics::MemoryOrder::Relaxed as i32);
            if old > MAX_REFCOUNT {
                panic("Arc: reference count overflow");
            }
        }
        return Weak::<T> { ptr: self.ptr };
    }

    // A weak handle for block `p`, whose weak count already counts it.
    fn from_block(p: *mut ArcInner<T>) Weak<T> {
        return Weak::<T> { ptr: p };
    }
}

// `Arc<T>` shares one value across threads, so it is `Send` and `Sync` exactly when its payload is safe to
// share: `T: Send + Sync`. The conformances are explicit (unsafe) assertions: the raw pointer inside would
// otherwise make `Arc` structurally neither. The atomic counts make the reference counting itself
// race-free. A `Weak` can become an `Arc` on another thread, so it takes the same bounds.
unsafe extend<T: Send + Sync> Arc<T> as Send {}

unsafe extend<T: Send + Sync> Arc<T> as Sync {}

unsafe extend<T: Send + Sync> Weak<T> as Send {}

unsafe extend<T: Send + Sync> Weak<T> as Sync {}

// Dropping a handle atomically decrements the strong count; the thread that observes the count fall to zero
// owns the teardown: it deep-frees the value, then releases the strong handles' weak reference.
extend<T> Arc<T> as Free {
    pub fn free(self: &mut Arc<T>) {
        // AcqRel, not Release + an Acquire fence on the zero path: the decrement chain is what orders every
        // handle's LAST payload access before the teardown (a `WaitGroup` doner is still inside the gate
        // after publishing zero, and only this drop orders that use before a free), and a standalone fence
        // is outside TSan's memory model, so the race gate could never check the fence form.
        let prev = unsafe atomic::sub_usize(self.strong_ptr(), 1, atomics::MemoryOrder::AcqRel as i32);
        if prev == 1 {
            // Free the value THROUGH a raw pointer (no-op if T isn't Free), like Box::free; freeing the
            // place directly would be a conditional move out of a dereference.
            let vp = (&mut unsafe (*self.ptr).value) as *mut T;
            vp.free();
            let _collective = Weak::<T>::from_block(self.ptr);
        }
        self.ptr = null;
    }
}

// The last weak release frees the block. AcqRel for the reason of `Arc::free`: the Release half publishes
// this handle's uses of the block (for the strong handles' reference, the value's teardown), and the
// Acquire half orders every other handle's uses before the dealloc, without a fence TSan cannot check.
extend<T> Weak<T> as Free {
    pub fn free(self: &mut Weak<T>) {
        let p = self.ptr;
        if p == null {
            return;
        }
        self.ptr = null;
        let prev = unsafe atomic::sub_usize(&mut (*p).weak, 1, atomics::MemoryOrder::AcqRel as i32);
        if prev == 1 {
            let mut g = Global {};
            unsafe g.dealloc(p, sizeof(ArcInner<T>), alignof(ArcInner<T>));
        }
    }
}
