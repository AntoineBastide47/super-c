// Box<T, A = Global>: a single heap-allocated, owned value, released through allocator `A`. Monomorphized
// per (element type, allocator); the allocation is sized with `sizeof(T)` and aligned with `alignof(T)`.
// Auto-`Free` (releases the allocation through `A` and deep-frees the value at scope exit). The allocator is
// stored in the box (zero bytes when it is the zero-sized `Global`, so a `Box<T>` is exactly one pointer).
// `new()` uses a default-constructed allocator; pass a stateful one (an arena/pool handle) with `new_in`, or
// pick a non-default zero-sized allocator with a turbofish: `Box::<T, MyAlloc>::new(v)`.

pub struct Box<T, A = Global> {
    ptr: *mut T, // owns one T (private)
    alloc: A, // the allocator the block was obtained through (private; zero-sized for Global)
}

extend<T, A: Allocator> Box<T, A> {
    // Allocate through an explicit allocator value (a stateful arena/pool handle, or a zero-sized tag).
    pub const fn new_in(alloc: A, value: T) Box<T, A> {
        let mut b = Box::<T, A> { ptr: null, alloc: alloc };
        b.ptr = b.alloc.alloc(sizeof(T), alignof(T)) as *mut T;
        unsafe b.ptr[0] = value;
        return b;
    }

    pub const fn get(self: &Box<T, A>) &T {
        return unsafe &self.ptr[0];
    }

    pub const fn set(self: &mut Box<T, A>, value: T) {
        unsafe self.ptr[0] = value;
    }

    // Overwrite the contents, returning the previous value.
    pub const fn replace(self: &mut Box<T, A>, value: T) T {
        let old = unsafe self.ptr[0];
        unsafe self.ptr[0] = value;
        return old;
    }

    pub const fn as_ptr(self: &Box<T, A>) *const T {
        return self.ptr;
    }

    // Allocate a new box (through a copy of the same allocator) holding `f` applied to this box's value.
    pub const fn map<U, F: fn(T) U>(self: &Box<T, A>, f: F) Box<U, A> {
        return Box::<U, A>::new_in(self.alloc, f(unsafe self.ptr[0]));
    }
}

// Convenience constructor for a default-constructible allocator (`Global`, or any zero-sized tag).
extend<T, A: Allocator + Default> Box<T, A> {
    pub const fn new(value: T) Box<T, A> {
        return Box::<T, A>::new_in(A::default(), value);
    }
}

// Auto-deref: `b.len()` on a `Box<String>` dispatches to `String::len` through `deref`; a `&mut self`
// method goes through `deref_mut` and needs a `mut` binding. Box's own methods (get/set/free/..) win.
extend<T, A: Allocator> Box<T, A> as Deref<T> {
    pub const fn deref(self: &Box<T, A>) &T {
        return unsafe &self.ptr[0];
    }
}

extend<T, A: Allocator> Box<T, A> as DerefMut<T> {
    pub const fn deref_mut(self: &mut Box<T, A>) &mut T {
        return &mut unsafe self.ptr[0];
    }
}

// Free the allocation AND deep-free the boxed value. Auto-`Free`: a `Box` is released at scope exit. Sound
// because `get` returns a borrow (`&T`) rather than a sharing copy, so the box is the only owner of the
// value. The inner `.free()` is a no-op when `T` isn't a Free type.
extend<T, A: Allocator> Box<T, A> as Free {
    pub fn free(self: &mut Box<T, A>) {
        unsafe self.ptr.free(); // free the boxed value (no-op if T isn't Free)
        self.alloc.dealloc(self.ptr, sizeof(T), alignof(T));
        self.ptr = null;
    }
}

// Conditional conformances: a Box is Clone/Eq/Hash exactly when its contents are.
extend<T: Clone, A: Allocator> Box<T, A> as Clone {
    // A fresh allocation (same allocator) holding an independent clone of the value.
    pub const fn clone(self: &Box<T, A>) Box<T, A> {
        let v = self.get();
        return Box::<T, A>::new_in(self.alloc, v.clone());
    }
}

extend<T: Eq, A: Allocator> Box<T, A> as Eq {
    pub const fn eq(self: &Box<T, A>, other: &Box<T, A>) bool {
        let a = self.get();
        let b = other.get();
        return *a == *b;
    }
}

extend<T: Hash, A: Allocator> Box<T, A> as Hash {
    pub const fn hash(self: &Box<T, A>) u64 {
        let v = self.get();
        return v.hash();
    }
}

extend<T: Default, A: Allocator + Default> Box<T, A> as Default {
    pub const fn default() Box<T, A> {
        return Box::<T, A>::new(T::default());
    }
}
