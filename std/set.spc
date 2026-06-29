// Set<T, A = Global>: an owning hash set, implemented as a keys-only wrapper over Map<T, bool, A>.
// Elements must be `Hash + Eq`. The set owns its elements; `contains` borrows a lookup key, `insert`
// takes ownership of a value, and `remove` frees the stored element through Map's key-removal path.

pub struct Set<T, A = Global> {
    m: Map<T, bool, A>,
}

extend<T: Hash + Eq, A: Allocator> Set<T, A> {

    // Empty set backed by an explicit allocator value (a stateful arena/pool handle, or a zero-sized tag).
    pub fn new_in(alloc: A) Set<T, A> {
        return Set::<T, A> { m: Map::<T, bool, A>::new_in(alloc), };
    }

    pub fn len(self: &Set<T, A>) usize {
        return self.m.len();
    }

    pub fn is_empty(self: &Set<T, A>) bool {
        return self.m.is_empty();
    }

    // Insert `value`. A duplicate (per Eq) is freed by Map::insert, and the stored element is kept.
    pub fn insert(self: &mut Set<T, A>, value: T) {
        self.m.insert(value, true);
    }

    pub fn contains(self: &Set<T, A>, value: &T) bool {
        return self.m.contains_key(value);
    }

    // Remove `value`, freeing the stored element; reports whether it was present.
    pub fn remove(self: &mut Set<T, A>, value: &T) bool {
        let removed = self.m.remove(value);
        return removed.is_some();
    }

    // A borrowing cursor over the elements (`&T`); `for x in s.iter() { .. }`. Arbitrary order.
    pub fn iter(self: &Set<T, A>) MapKeys<T> {
        return self.m.keys();
    }
}

// Convenience constructor for a default-constructible allocator (`Global`, or any zero-sized tag).
extend<T: Hash + Eq, A: Allocator + Default> Set<T, A> {
    pub fn new() Set<T, A> { return Set::<T, A>::new_in(A::default()); }
}

// Free the inner map, including every stored key.
extend<T: Hash + Eq, A: Allocator> Set<T, A> as Free {
    pub fn free(self: &mut Set<T, A>) {
        self.m.free();
    }
}

extend<T: Hash + Eq + Default, A: Allocator + Default> Set<T, A> as Default {
    pub fn default() Set<T, A> {
        return Set::<T, A>::new();
    }
}
