// `Rc<T, A>`: a reference-counted shared pointer for one thread, and `Weak<T, A>`, a handle that does
// not keep the value alive (C++ `shared_ptr` and `weak_ptr` semantics, Rust's `Rc` layout).
//
// Ownership: one allocation through `A` holds the strong count, the weak count and the value. `clone`
// adds a strong handle, `downgrade` a weak one. The strong handles together count as one weak reference,
// so the block lives while any handle lives. When the last strong handle drops, the value is freed;
// when the last handle of either kind drops after that, the block is freed. A `Weak` never resurrects a
// freed value: `upgrade` returns `None` from the moment the strong count reaches zero, also while the
// value's own `free` runs. A cycle of strong handles is never freed; break it with `Weak` (a child
// holds a `Weak` to its parent).
//
// Cost: every operation is O(1) except the value's own `free` and `clone` (`make_mut`). `new` and
// `make_mut` on a shared value allocate once through `A`; `Weak::new` allocates nothing. Each handle
// stores a copy of the allocator, which costs no space for `Global`, so an `Rc<T>` is one pointer. A
// count increment past `usize::MAX` panics.
//
// Thread safety: the counts are not atomic, so `Rc` and `Weak` are neither `Send` nor `Sync` (the raw
// pointer inside makes them structurally neither). Use `std::parallel::arc` across threads. Shared
// access is read-only (`get`, `Deref`); mutate through `get_mut` or `make_mut`, or put a
// `std::mem::cell` type inside. Import with `import std::mem::rc;`.

// The shared block, from allocator `A`. `weak` counts the `Weak` handles plus one for all strong
// handles together. An increment past `usize::MAX` panics: the count would wrap to zero and free a
// value still in use.
@no_const
struct RcInner<T, A: Allocator> {
    @counter("rc_value_guard")
    pub strong: usize,
    @counter("rc_block_guard")
    pub weak: usize,
    pub value: T,
}

// What the live strong count of block `p` holds: the strong handles' weak unit (and the value).
spec fn rc_value_guard<T, A: Allocator>(p: *mut RcInner<T, A>) bool {
    return rc_share(p, 1, 1);
}

// What the live weak count of block `p` holds: the block.
spec fn rc_block_guard<T, A: Allocator>(p: *mut RcInner<T, A>) bool {
    return A::owns(p, sizeof(RcInner<T, A>), alignof(RcInner<T, A>));
}

/// A shared, reference-counted handle to a `T` in a block from allocator `A`. Not thread-safe.
@no_const
pub struct Rc<T, A: Allocator = Global>
    invariant self.ptr == null || rc_share(self.ptr, 0, 1)
{
    ptr: *mut RcInner<T, A>, // null only in an all-zero seed
    alloc: A,
}

/// A handle to the block of an `Rc` that does not keep its value alive; `upgrade` gives an `Rc` while
/// the value lives. `Weak::new` points at nothing.
@no_const
pub struct Weak<T, A: Allocator = Global>
    invariant self.ptr == null || rc_share(self.ptr, 1, 1)
{
    ptr: *mut RcInner<T, A>, // null for `Weak::new`
    alloc: A,
}

extend<T, A: Allocator> Rc<T, A> {
    /// A new block from `alloc` holding `value`, with one strong handle.
    pub fn new_in(alloc: A, value: T) Rc<T, A> {
        let mut a = alloc;
        let p = (unsafe a.alloc(sizeof(RcInner<T, A>), alignof(RcInner<T, A>))) as *mut RcInner<T, A>;
        unsafe *p = RcInner::<T, A> { strong: 1, weak: 1, value: value };
        return Rc::<T, A> { ptr: p, alloc: a };
    }

    /// A shared borrow of the value, valid while this handle lives.
    pub fn get(self: &Rc<T, A>) &T {
        return unsafe &(*self.ptr).value;
    }

    /// The number of strong handles, this one included.
    pub fn strong_count(self: &Rc<T, A>) usize {
        return unsafe (*self.ptr).strong;
    }

    /// The number of `Weak` handles.
    pub fn weak_count(self: &Rc<T, A>) usize {
        return unsafe (*self.ptr).weak - 1;
    }

    /// A new `Weak` handle to this block.
    pub fn downgrade(self: &Rc<T, A>) Weak<T, A> {
        let p = self.ptr;
        if unsafe (*p).weak == ~(0 as usize) {
            panic("Rc: reference count overflow");
        }
        unsafe (*p).weak = unsafe (*p).weak + 1;
        return Weak::<T, A>::from_block(p, self.alloc);
    }

    /// A mutable borrow of the value when this is the only handle of either kind, else `None`.
    pub fn get_mut(self: &mut Rc<T, A>) Option<&mut T> {
        if unsafe (*self.ptr).strong != 1 || unsafe (*self.ptr).weak != 1 {
            return None;
        }
        return Some(&mut unsafe (*self.ptr).value);
    }

    /// The value, when this is the only strong handle; else this handle back as `Err`. `Weak` handles
    /// do not prevent it: they fail to upgrade afterwards.
    pub fn try_unwrap(self: Rc<T, A>) Result<T, Rc<T, A>> {
        let p = self.ptr;
        if unsafe (*p).strong != 1 {
            return Err(self);
        }
        unsafe (*p).strong = 0;
        let alloc = self.alloc;
        forget(self);
        let value = unsafe (*p).value;
        // Releases the strong handles' weak reference: frees the block when no `Weak` remains.
        let _collective = Weak::<T, A>::from_block(p, alloc);
        return Ok(value);
    }

    /// The value, when this is the only strong handle; else `None`, and this handle is dropped.
    pub fn into_inner(self: Rc<T, A>) Option<T> {
        return self.try_unwrap().get_ok();
    }

    /// True when both handles point at the same block.
    pub fn ptr_eq(self: &Rc<T, A>, other: &Rc<T, A>) bool {
        return self.ptr == other.ptr;
    }

    // A strong handle for block `p`, whose strong count already counts it.
    fn from_block(p: *mut RcInner<T, A>, alloc: A) Rc<T, A>
        requires p == null || rc_share(p, 0, 1)
    {
        return Rc::<T, A> { ptr: p, alloc: alloc };
    }
}

extend<T, A: Allocator + Default> Rc<T, A> {
    /// A new block from `A::default()` holding `value`, with one strong handle.
    pub fn new(value: T) Rc<T, A> {
        return Rc::<T, A>::new_in(A::default(), value);
    }
}

extend<T: Clone, A: Allocator> Rc<T, A> {
    /// A mutable borrow of the value, cloned into a new block first when other strong handles share
    /// it (clone-on-write). When only `Weak` handles share it, the value moves to a new block without a
    /// clone and those handles no longer upgrade. A unique handle borrows in place.
    pub fn make_mut(self: &mut Rc<T, A>) &mut T {
        if unsafe (*self.ptr).strong != 1 {
            // The value's own borrow, not `get`'s result: the proofs end it with the clone.
            let v = (unsafe &(*self.ptr).value).clone();
            let fresh = Rc::<T, A>::new_in(self.alloc, v);
            *self = fresh;
        } else if unsafe (*self.ptr).weak != 1 {
            let old = self.ptr;
            let p = (unsafe self.alloc.alloc(sizeof(RcInner<T, A>), alignof(RcInner<T, A>))) as *mut RcInner<T, A>;
            // The allocator ran code: a `Weak` it upgraded shares the value now, which is cloned then.
            if unsafe (*old).strong != 1 {
                unsafe self.alloc.dealloc(p, sizeof(RcInner<T, A>), alignof(RcInner<T, A>));
                return self.make_mut();
            }
            // The value moves out: no strong handle remains, and the remaining `Weak` handles free the old
            // block.
            unsafe (*old).strong = 0;
            unsafe *p = RcInner::<T, A> { strong: 1, weak: 1, value: unsafe (*old).value };
            self.ptr = p;
            let _collective = Weak::<T, A>::from_block(old, self.alloc);
        }
        return &mut unsafe (*self.ptr).value;
    }
}

extend<T, A: Allocator> Weak<T, A> {
    /// A handle to no block, through allocator `alloc`: `upgrade` returns `None`. Allocates nothing.
    pub fn new_in(alloc: A) Weak<T, A> {
        return Weak::<T, A> { ptr: null, alloc: alloc };
    }

    /// A new strong handle while the value lives, else `None`.
    pub fn upgrade(self: &Weak<T, A>) Option<Rc<T, A>> {
        let p = self.ptr;
        if p == null || unsafe (*p).strong == 0 {
            return None;
        }
        if unsafe (*p).strong == ~(0 as usize) {
            panic("Rc: reference count overflow");
        }
        unsafe (*p).strong = unsafe (*p).strong + 1;
        return Some(Rc::<T, A>::from_block(p, self.alloc));
    }

    /// The number of strong handles: 0 once the value is freed, and for `Weak::new`.
    pub fn strong_count(self: &Weak<T, A>) usize {
        if self.ptr == null {
            return 0;
        }
        return unsafe (*self.ptr).strong;
    }

    /// The number of `Weak` handles, this one included: 0 once the value is freed, and for `Weak::new`.
    pub fn weak_count(self: &Weak<T, A>) usize {
        if self.ptr == null || unsafe (*self.ptr).strong == 0 {
            return 0;
        }
        return unsafe (*self.ptr).weak - 1;
    }

    // A weak handle for block `p`, whose weak count already counts it.
    fn from_block(p: *mut RcInner<T, A>, alloc: A) Weak<T, A>
        requires p == null || rc_share(p, 1, 1)
    {
        return Weak::<T, A> { ptr: p, alloc: alloc };
    }
}

extend<T, A: Allocator + Default> Weak<T, A> {
    /// A handle to no block: `upgrade` returns `None`. Allocates nothing.
    pub fn new() Weak<T, A> {
        return Weak::<T, A>::new_in(A::default());
    }
}

extend<T, A: Allocator> Rc<T, A> as Deref<T> {
    pub fn deref(self: &Rc<T, A>) &T {
        return unsafe &(*self.ptr).value;
    }
}

// Another strong handle to the same block: a count increment, no copy of the value.
extend<T, A: Allocator> Rc<T, A> as Clone {
    pub fn clone(self: &Rc<T, A>) Rc<T, A> {
        let p = self.ptr;
        if unsafe (*p).strong == ~(0 as usize) {
            panic("Rc: reference count overflow");
        }
        unsafe (*p).strong = unsafe (*p).strong + 1;
        return Rc::<T, A>::from_block(p, self.alloc);
    }
}

extend<T, A: Allocator> Weak<T, A> as Clone {
    pub fn clone(self: &Weak<T, A>) Weak<T, A> {
        let p = self.ptr;
        if p != null {
            if unsafe (*p).weak == ~(0 as usize) {
                panic("Rc: reference count overflow");
            }
            unsafe (*p).weak = unsafe (*p).weak + 1;
        }
        return Weak::<T, A>::from_block(p, self.alloc);
    }
}

// The last strong drop frees the value, then releases the strong handles' weak reference; the block is
// freed once the weak count reaches zero. A `Weak` the value's own `free` drops cannot reach zero first,
// because that weak reference is still held. A null pointer is an all-zero seed (a derived `clone` or
// `default` writes over one) and owns nothing.
extend<T, A: Allocator> Rc<T, A> as Free {
    pub fn free(self: &mut Rc<T, A>) {
        let p = self.ptr;
        if p == null {
            return;
        }
        self.ptr = null;
        unsafe {
            (*p).strong = (*p).strong - 1;
        }
        if unsafe (*p).strong != 0 {
            return;
        }
        // Through a raw pointer, as `Box::free` does: freeing the place would move out of a dereference.
        let vp = (&mut unsafe (*p).value) as *mut T;
        vp.free();
        let _collective = Weak::<T, A>::from_block(p, self.alloc);
    }
}

extend<T, A: Allocator> Weak<T, A> as Free {
    pub fn free(self: &mut Weak<T, A>) {
        let p = self.ptr;
        if p == null {
            return;
        }
        self.ptr = null;
        unsafe {
            (*p).weak = (*p).weak - 1;
        }
        if unsafe (*p).weak == 0 {
            unsafe self.alloc.dealloc(p, sizeof(RcInner<T, A>), alignof(RcInner<T, A>));
        }
    }
}

// The conformances below forward to the value.
extend<T: Eq, A: Allocator> Rc<T, A> as Eq {
    pub fn eq(self: &Rc<T, A>, other: &Rc<T, A>) bool {
        return self.get().eq(other.get());
    }
}

extend<T: Ord, A: Allocator> Rc<T, A> as Ord {
    pub fn cmp(self: &Rc<T, A>, other: &Rc<T, A>) i32 {
        return self.get().cmp(other.get());
    }
}

extend<T: Hash, A: Allocator> Rc<T, A> as Hash {
    pub fn hash_into<H: Hasher>(self: &Rc<T, A>, h: &mut H) {
        self.get().hash_into(h);
    }
}

extend<T: Format, A: Allocator> Rc<T, A> as Format {
    pub fn fmt(self: &Rc<T, A>) String {
        return self.get().fmt();
    }
}

extend<T: Default, A: Allocator + Default> Rc<T, A> as Default {
    pub fn default() Rc<T, A> {
        return Rc::<T, A>::new(T::default());
    }
}
