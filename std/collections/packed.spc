// Packed enum sequences. `PackedEnums<E, A = Global>` stores the values of enum `E` back to back, each in the
// bytes of its own variant (its tag and that variant's payload: the variant binder's `v.size`) instead of
// `sizeof(E)`, so the largest variant no longer sets the cost of every value. An enum whose variants are of
// one size gains nothing, and neither does a niche enum (its payload holds the discriminant) or an enum
// without payloads: each of their values takes `sizeof(E)`.
//
// The values form a sequence, not an array: they are read in order, never by index, and a stored value
// never changes variant. A stored value sits at no particular alignment, so no reference to one exists:
// `for_each` lends each value from an aligned copy, `iter` (for a `Copy` enum) copies each one out, and
// `drain` moves them out.
//
// Complexity: push: amortized O(1) (a growth copies the bytes once). for_each, iter, drain, clear: O(len).
// Allocation: one block of bytes from `A`, grown geometrically (64 bytes first, then at least doubling); no
// allocation per value. Thread safety: no internal synchronization; Send and Sync when `E` and `A` are.

extern "C" {
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
}

const MIN_BYTES: usize = 64; // the first block

// Take ownership of `v`; it is freed on return.
fn release<T>(_: T) {}

/// Values of enum `E` stored back to back at the size of their own variant. Read in order; no indexing.
pub struct PackedEnums<E, A = Global> {
    ptr: *mut E, // the block of bytes (a value at any byte offset); null while cap == 0
    used: usize, // the bytes the values take
    cap: usize, // the bytes of the block
    count: usize, // the values
    alloc: A, // the allocator the block came from (zero-sized for Global)
}

// The container owns its values, so it is Send / Sync when they and the allocator are (the block pointer
// makes it structurally neither).
unsafe extend<E: Send, A: Send> PackedEnums<E, A> as Send {}

unsafe extend<E: Sync, A: Sync> PackedEnums<E, A> as Sync {}

/// The bytes enum value `e` takes in a `PackedEnums`: its variant's `v.size`.
pub const fn packed_size<E>(e: &E) usize {
    inline for v in variants(e) {
        if v.is_active {
            return v.size;
        }
    }
    return sizeof(E);
}

extend<E, A: Allocator> PackedEnums<E, A> {
    /// An empty sequence on allocator `alloc`; no allocation until the first push.
    pub const fn new_in(alloc: A) PackedEnums<E, A> {
        static_assert(type_info::<E>().kind == TypeTag::Enum, "a PackedEnums holds the values of an enum");
        return PackedEnums::<E, A> { ptr: null, used: 0, cap: 0, count: 0, alloc: alloc };
    }

    /// The number of values.
    pub const fn len(self: &PackedEnums<E, A>) usize {
        return self.count;
    }

    /// True when it holds no value.
    pub const fn is_empty(self: &PackedEnums<E, A>) bool {
        return self.count == 0;
    }

    /// The bytes the values take (`len() * sizeof(E)` in a `Vector<E>`).
    pub const fn byte_len(self: &PackedEnums<E, A>) usize {
        return self.used;
    }

    /// Appends `v` in the bytes of its variant; takes ownership of it.
    pub fn push(self: &mut PackedEnums<E, A>, v: E) {
        let n = packed_size(&v);
        if n > self.cap - self.used {
            self.grow(n);
        }
        unsafe memcpy(self.ptr as *mut u8 + self.used, (&v) as *const E, n);
        self.used += n;
        self.count += 1;
        forget(v);
    }

    /// Calls `f` on each value in order, lent from an aligned copy.
    pub fn for_each<F: fn(&E)>(self: &PackedEnums<E, A>, f: F) {
        let mut off: usize = 0;
        for _ in 0..self.count {
            let (v, n) = unsafe self.read_at(off);
            f(&v);
            // The copy owns nothing of its own: the stored bytes keep the value.
            forget(v);
            off += n;
        }
    }

    /// Moves each value in order into `f`, then holds no value; the block stays.
    pub fn drain<F: fn(E)>(self: &mut PackedEnums<E, A>, f: F) {
        let mut off: usize = 0;
        let n0 = self.count;
        self.count = 0;
        for _ in 0..n0 {
            let (v, n) = unsafe self.read_at(off);
            off += n;
            f(v);
        }
        self.used = 0;
    }

    /// Frees every value; the block stays.
    pub fn clear(self: &mut PackedEnums<E, A>) {
        let mut off: usize = 0;
        let n0 = self.count;
        self.count = 0;
        for _ in 0..n0 {
            // The copy owns the value: it is freed at the end of the iteration.
            let (v, n) = unsafe self.read_at(off);
            off += n;
            release(v);
        }
        self.used = 0;
    }

    // The value at byte `off`, a bitwise copy that owns what the bytes own, and the bytes it takes. Its
    // variant's bytes all lie below `used`, so a copy of at most `used - off` bytes holds them.
    unsafe fn read_at(self: &PackedEnums<E, A>, off: usize) (E, usize) {
        let mut v = unsafe zeroed::<E>();
        let n = (self.used - off).min(sizeof(E));
        unsafe memcpy((&mut v) as *mut E, self.ptr as *const u8 + off, n);
        let k = packed_size(&v);
        return v, k;
    }

    // Make room for `n` more bytes: at least double the block.
    @noinline
    fn grow(self: &mut PackedEnums<E, A>, n: usize) {
        if n > usize::MAX - self.used {
            panic("PackedEnums: capacity overflow");
        }
        let mut cap = self.cap.max(MIN_BYTES / 2);
        if cap > usize::MAX / 2 {
            cap = usize::MAX;
        } else {
            cap = cap * 2;
        }
        if cap < self.used + n {
            cap = self.used + n;
        }
        if self.cap == 0 {
            self.ptr = (unsafe self.alloc.alloc(cap, alignof(E))) as *mut E;
        } else {
            self.ptr = (unsafe self.alloc.realloc(self.ptr, self.cap, cap, alignof(E))) as *mut E;
        }
        self.cap = cap;
    }
}

extend<E, A: Allocator + Default> PackedEnums<E, A> {
    /// An empty sequence on the default allocator; no allocation until the first push.
    pub const fn new() PackedEnums<E, A> {
        return PackedEnums::<E, A>::new_in(A::default());
    }
}

extend<E: Copy, A: Allocator> PackedEnums<E, A> {
    /// The values in order, copied out.
    pub const fn iter(self: &PackedEnums<E, A>) PackedIter<E, A> {
        return PackedIter::<E, A> { s: self, off: 0, rem: self.count };
    }
}

/// An iterator over the values of a `PackedEnums` of a `Copy` enum, in order; exact size.
pub struct PackedIter<'a, E, A> {
    pub(module) s: &'a PackedEnums<E, A>,
    pub(module) off: usize, // the byte of the next value
    pub(module) rem: usize, // the values left
}

extend<'a, E: Copy, A: Allocator> PackedIter<'a, E, A> as Iterator<E> {
    pub fn next(self: &mut PackedIter<'a, E, A>) Option<E> {
        if self.rem == 0 {
            return Option::<E>::None;
        }
        let (v, n) = unsafe self.s.read_at(self.off);
        self.off += n;
        self.rem -= 1;
        return Option::<E>::Some(v);
    }

    pub const fn size_hint(self: &PackedIter<'a, E, A>) (usize, Option<usize>) {
        return self.rem, Option::<usize>::Some(self.rem);
    }
}

extend<E, A: Allocator> PackedEnums<E, A> as Free {
    pub fn free(self: &mut PackedEnums<E, A>) {
        self.clear();
        if self.cap > 0 {
            unsafe self.alloc.dealloc(self.ptr, self.cap, alignof(E));
        }
        self.ptr = null;
        self.cap = 0;
    }
}
