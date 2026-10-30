// Set<T, A = Global, S = DefaultHash>: an owning hash set, implemented as a keys-only wrapper over
// Map<T, Present, A, S>. The zero-sized value type gives the map no value array. Elements must be
// `Hash + Eq`. The set owns its elements; `contains` borrows a lookup key, `insert` takes ownership of a
// value, and `remove` frees the stored element through Map's key-removal path. Complexity, invalidation,
// iteration order and the choice of hash builder are Map's (std/map.spc). The set operations
// (`set_union`, `intersection`, `difference`, `symmetric_difference`; `union` is a keyword) are lazy iterators over both sets:
// O(len(a) + len(b)) lookups in total.

/// A hash set of T (a Map<T, Present> underneath) through allocator A, hashed by S.
pub struct Set<T, A = Global, S = DefaultHash> {
    m: Map<T, Present, A, S>,
}

unsafe extend<T, A, S> Set<T, A, S> as Zeroable {}

// The zero-sized value every member maps to.
@derive(Clone)
struct Present {}

extend<T: Hash + Eq, A: Allocator, S: BuildHasher> Set<T, A, S> {
    /// Empty set backed by an explicit allocator and hash builder.
    pub const fn with_hasher_in(alloc: A, hasher: S) Set<T, A, S> {
        return Set::<T, A, S> { m: Map::<T, Present, A, S>::with_hasher_in(alloc, hasher) };
    }

    /// Number of elements.
    pub const fn len(self: &Set<T, A, S>) usize {
        return self.m.len();
    }

    /// True when no element is stored.
    pub const fn is_empty(self: &Set<T, A, S>) bool {
        return self.m.is_empty();
    }

    /// The number of elements the set holds before its next growth.
    pub const fn capacity(self: &Set<T, A, S>) usize {
        return self.m.capacity();
    }

    /// Room for `additional` more elements without a growth.
    pub fn reserve(self: &mut Set<T, A, S>, additional: usize) {
        self.m.reserve(additional);
    }

    /// Insert `value`. A duplicate (per Eq) is freed by Map::insert, and the stored element is kept.
    pub const fn insert(self: &mut Set<T, A, S>, value: T) {
        self.m.insert(value, Present {});
    }

    /// True when `value` is a member.
    pub const fn contains(self: &Set<T, A, S>, value: &T) bool {
        return self.m.contains_key(value);
    }

    /// The stored element equal to `value`, or `None`.
    pub const fn get(self: &Set<T, A, S>, value: &T) Option<&T> {
        return switch self.m.get_key_value(value) {
            Some(kv) => Some(kv._0),
            None => Option::<&T>::None,
        };
    }

    /// Remove `value`, freeing the stored element; reports whether it was present.
    pub const fn remove(self: &mut Set<T, A, S>, value: &T) bool {
        let removed = self.m.remove(value);
        return removed.is_some();
    }

    /// Remove `value` and hand the stored element back, or `None`.
    pub fn take(self: &mut Set<T, A, S>, value: &T) Option<T> {
        return switch self.m.remove_entry(value) {
            Some((k, _)) => Some(k),
            None => Option::<T>::None,
        };
    }

    /// Free every element; the storage is kept.
    pub fn clear(self: &mut Set<T, A, S>) {
        self.m.clear();
    }

    /// Keep only the elements for which `keep` holds; the others are freed.
    pub fn retain<F: fn(&T) bool>(self: &mut Set<T, A, S>, keep: F) {
        self.m.retain_with(KeyKeep::<F> { f: keep });
    }

    /// A borrowing cursor over the elements (`&T`); `for x in s.iter() { .. }`. Slot order.
    pub const fn iter(self: &Set<T, A, S>) MapKeys<T> {
        return self.m.keys();
    }

    /// True when every element of `self` is in `other`.
    pub fn is_subset(self: &Set<T, A, S>, other: &Set<T, A, S>) bool {
        if self.len() > other.len() {
            return false;
        }
        for x in self.iter() {
            if !other.contains(x) {
                return false;
            }
        }
        return true;
    }

    /// True when every element of `other` is in `self`.
    pub fn is_superset(self: &Set<T, A, S>, other: &Set<T, A, S>) bool {
        return other.is_subset(self);
    }

    /// True when the sets share no element.
    pub fn is_disjoint(self: &Set<T, A, S>, other: &Set<T, A, S>) bool {
        for x in self.iter() {
            if other.contains(x) {
                return false;
            }
        }
        return true;
    }

    /// The elements of `self` that are not in `other`.
    pub const fn difference<'b>(self: &'b Set<T, A, S>, other: &'b Set<T, A, S>) SetDifference<'b, T, A, S> {
        return SetDifference::<T, A, S> { it: self.iter(), other: other };
    }

    /// The elements in both sets.
    pub const fn intersection<'b>(self: &'b Set<T, A, S>, other: &'b Set<T, A, S>) SetIntersection<'b, T, A, S> {
        return SetIntersection::<T, A, S> { it: self.iter(), other: other };
    }

    /// The elements of `self`, then those of `other` that are not in `self`.
    pub const fn set_union<'b>(self: &'b Set<T, A, S>, other: &'b Set<T, A, S>) SetUnion<'b, T, A, S> {
        return SetUnion::<T, A, S> { first: self.iter(), rest: other.difference(self) };
    }

    /// The elements in exactly one of the sets.
    pub const fn symmetric_difference<'b>(self: &'b Set<T, A, S>, other: &'b Set<T, A, S>) SetSymmetricDifference<
        'b,
        T,
        A,
        S
    > {
        return SetSymmetricDifference::<T, A, S> { first: self.difference(other), rest: other.difference(self) };
    }
}

// Constructors that default-construct the allocator or the hash builder.
extend<T: Hash + Eq, A: Allocator, S: BuildHasher + Default> Set<T, A, S> {
    /// Empty set backed by an explicit allocator value (a stateful arena/pool handle, or a zero-sized tag).
    pub const fn new_in(alloc: A) Set<T, A, S> {
        return Set::<T, A, S>::with_hasher_in(alloc, S::default());
    }
}

extend<T: Hash + Eq, A: Allocator + Default, S: BuildHasher> Set<T, A, S> {
    /// Empty set using the default allocator and the given hash builder.
    pub const fn with_hasher(hasher: S) Set<T, A, S> {
        return Set::<T, A, S>::with_hasher_in(A::default(), hasher);
    }
}

extend<T: Hash + Eq, A: Allocator + Default, S: BuildHasher + Default> Set<T, A, S> {
    /// An empty set using the default allocator.
    pub const fn new() Set<T, A, S> {
        return Set::<T, A, S>::with_hasher_in(A::default(), S::default());
    }
}

// Free the inner map, including every stored key.
extend<T: Hash + Eq, A: Allocator, S: BuildHasher> Set<T, A, S> as Free {
    pub fn free(self: &mut Set<T, A, S>) {
        self.m.free();
    }
}

extend<T: Hash + Eq, A: Allocator + Default, S: BuildHasher + Default> Set<T, A, S> as Default {
    pub const fn default() Set<T, A, S> {
        return Set::<T, A, S>::new();
    }
}

extend<T: Hash + Eq + Clone, A: Allocator, S: BuildHasher> Set<T, A, S> as Clone {
    pub fn clone(self: &Set<T, A, S>) Set<T, A, S> {
        return Set::<T, A, S> { m: self.m.clone() };
    }
}

// Equal when both hold the same elements, whatever their slot order.
extend<T: Hash + Eq, A: Allocator, S: BuildHasher> Set<T, A, S> as Eq {
    pub fn eq(self: &Set<T, A, S>, other: &Set<T, A, S>) bool {
        return self.len() == other.len() && self.is_subset(other);
    }
}

extend<T: Hash + Eq + Format, A: Allocator, S: BuildHasher> Set<T, A, S> as Format {
    /// `{a, b, ...}` in slot order.
    pub fn fmt(self: &Set<T, A, S>) String {
        let mut s = String::from_str("{");
        let mut first = true;
        for x in self.iter() {
            if !first {
                s.push_str(", ");
            }
            first = false;
            let xs = x.fmt();
            s.push_string(&xs);
        }
        s.push_str("}");
        return s;
    }
}

// Build from a list of elements: `let s: Set<i32> = [1, 2, 2, 3].into();` (duplicates collapse). The
// slice borrows, so each element is cloned in: see Vector's conversion for why.
extend<T: Hash + Eq + Clone, A: Allocator + Default, S: BuildHasher + Default> Set<T, A, S> as From<[]T> {
    pub fn from(value: []T) Set<T, A, S> {
        let mut out = Set::<T, A, S>::new();
        out.reserve(value.len());
        for i in 0..value.len() {
            out.insert(value.at(i).clone());
        }
        return out;
    }
}

/// The elements of one set that another lacks (`Set::difference`); borrows both.
pub struct SetDifference<'b, T, A, S> {
    it: MapKeys<'b, T>,
    other: &'b Set<T, A, S>,
}

/// The elements two sets share (`Set::intersection`); borrows both.
pub struct SetIntersection<'b, T, A, S> {
    it: MapKeys<'b, T>,
    other: &'b Set<T, A, S>,
}

/// Every element of either set once (`Set::set_union`); borrows both.
pub struct SetUnion<'b, T, A, S> {
    first: MapKeys<'b, T>,
    rest: SetDifference<'b, T, A, S>,
}

/// The elements in exactly one of two sets (`Set::symmetric_difference`); borrows both.
pub struct SetSymmetricDifference<'b, T, A, S> {
    first: SetDifference<'b, T, A, S>,
    rest: SetDifference<'b, T, A, S>,
}

extend<'b, T: Hash + Eq, A: Allocator, S: BuildHasher> SetDifference<'b, T, A, S> as Iterator<&'b T> {
    pub fn next(self: &mut SetDifference<'b, T, A, S>) Option<&'b T> {
        loop {
            switch self.it.next() {
                Some(x) => {
                    if !self.other.contains(x) {
                        return Some(x);
                    }
                },
                None => {
                    return Option::<&'b T>::None;
                },
            }
        }
    }

    pub fn size_hint(self: &SetDifference<'b, T, A, S>) (usize, Option<usize>) {
        let (_, hi) = self.it.size_hint();
        return (0, hi);
    }
}

extend<'b, T: Hash + Eq, A: Allocator, S: BuildHasher> SetIntersection<'b, T, A, S> as Iterator<&'b T> {
    pub fn next(self: &mut SetIntersection<'b, T, A, S>) Option<&'b T> {
        loop {
            switch self.it.next() {
                Some(x) => {
                    if self.other.contains(x) {
                        return Some(x);
                    }
                },
                None => {
                    return Option::<&'b T>::None;
                },
            }
        }
    }

    pub fn size_hint(self: &SetIntersection<'b, T, A, S>) (usize, Option<usize>) {
        let (_, hi) = self.it.size_hint();
        return (0, hi);
    }
}

extend<'b, T: Hash + Eq, A: Allocator, S: BuildHasher> SetUnion<'b, T, A, S> as Iterator<&'b T> {
    pub fn next(self: &mut SetUnion<'b, T, A, S>) Option<&'b T> {
        switch self.first.next() {
            Some(x) => {
                return Some(x);
            },
            None => {},
        }
        return self.rest.next();
    }
}

extend<'b, T: Hash + Eq, A: Allocator, S: BuildHasher> SetSymmetricDifference<'b, T, A, S> as Iterator<&'b T> {
    pub fn next(self: &mut SetSymmetricDifference<'b, T, A, S>) Option<&'b T> {
        switch self.first.next() {
            Some(x) => {
                return Some(x);
            },
            None => {},
        }
        return self.rest.next();
    }
}
