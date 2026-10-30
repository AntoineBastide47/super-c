// A binary max-heap priority queue over a Vector, and `Reverse`, which turns it into a min-heap. Import
// with `import std::collections::heap;`.
//
// `BinaryHeap<T: Ord, A = Global>` keeps its elements in one contiguous buffer through allocator `A` in
// heap order (every element not less than its children), with the shared heap operations of std/slice.spc.
// The largest element is the top. Another order is a wrapper type with its own `Ord` (`Reverse<T>` for
// the smallest first), as C++ `priority_queue` takes a comparator.
//
// Complexity (C++ [priority.queue] and the heap algorithms of [alg.heap.operations]): push is O(log n)
// comparisons (amortized O(1) element moves for the buffer growth), pop and a `peek_mut` change are
// O(log n), peek is O(1), `from` a Vector or slice is O(n) (Floyd's heap construction), and
// `into_sorted_vector` is O(n log n). Iteration (`iter`, `drain`) is in buffer order, not priority order.
//
// Invalidation: push, pop, append, retain and clear end every borrow of the heap (the borrow checker
// enforces it); `peek_mut` holds the heap mutably until its guard drops, then restores the order.
// Allocation: one buffer, grown geometrically, none per element. Thread safety: no internal
// synchronization; a heap is Send / Sync when its elements and allocator are.

/// A max-heap of T through allocator A.
pub struct BinaryHeap<T, A = Global> {
    data: Vector<T, A>,
}

/// `T` in the reverse order: a `BinaryHeap<Reverse<T>>` pops the smallest element first.
@derive(Clone, Eq, Hash, Format, Default)
pub struct Reverse<T> {
    pub v: T,
}

extend<T: Ord> Reverse<T> as Ord {
    pub fn cmp(self: &Reverse<T>, other: &Reverse<T>) i32 {
        return other.v.cmp(&self.v);
    }
}

/// A writable borrow of a heap's top (`BinaryHeap::peek_mut`); dropping it restores the heap order.
pub struct PeekMut<'a, T, A> {
    heap: &'a mut BinaryHeap<T, A>,
}

extend<T: Ord, A: Allocator> BinaryHeap<T, A> {
    /// An empty heap through `alloc`; no allocation until the first push.
    pub const fn new_in(alloc: A) BinaryHeap<T, A> {
        return BinaryHeap::<T, A> { data: Vector::<T, A>::new_in(alloc) };
    }

    /// An empty heap with room for `cap` elements through `alloc`.
    pub fn with_capacity_in(alloc: A, cap: usize) BinaryHeap<T, A> {
        return BinaryHeap::<T, A> { data: Vector::<T, A>::with_capacity_in(alloc, cap) };
    }

    /// The elements of `v` in heap order, built in place in O(n).
    pub fn from_vector(v: Vector<T, A>) BinaryHeap<T, A> {
        let mut data = v;
        data.as_mut_slice().heapify();
        return BinaryHeap::<T, A> { data: data };
    }

    /// Number of elements.
    pub const fn len(self: &BinaryHeap<T, A>) usize {
        return self.data.len();
    }

    /// True when the heap holds no element.
    pub const fn is_empty(self: &BinaryHeap<T, A>) bool {
        return self.data.is_empty();
    }

    /// Elements the buffer holds without growing.
    pub const fn capacity(self: &BinaryHeap<T, A>) usize {
        return self.data.capacity();
    }

    /// Room for `additional` more elements.
    pub fn reserve(self: &mut BinaryHeap<T, A>, additional: usize) {
        self.data.reserve(additional);
    }

    /// Add `value`. O(log n).
    pub fn push(self: &mut BinaryHeap<T, A>, value: T) {
        self.data.push(value);
        self.data.as_mut_slice().push_heap();
    }

    /// Remove and return the largest element, or `None` when empty. O(log n).
    pub fn pop(self: &mut BinaryHeap<T, A>) Option<T> {
        self.data.as_mut_slice().pop_heap();
        return self.data.pop();
    }

    /// The largest element, or `None` when empty. O(1).
    pub const fn peek(self: &BinaryHeap<T, A>) Option<&T> {
        return self.data.first();
    }

    /// A writable borrow of the largest element, or `None` when empty; the order is restored when the
    /// guard drops (O(log n)).
    pub const fn peek_mut(self: &mut BinaryHeap<T, A>) Option<PeekMut<T, A>> {
        if self.data.is_empty() {
            return None;
        }
        return Some(PeekMut::<T, A> { heap: self });
    }

    /// Move every element of `other` in, leaving it empty. O(m log(n + m)).
    pub fn append(self: &mut BinaryHeap<T, A>, other: &mut BinaryHeap<T, A>) {
        self.data.reserve(other.data.len());
        while let Some(x) = other.data.pop() {
            self.push(x);
        }
    }

    /// Keep only the elements for which `keep` holds; the others are freed. O(n).
    pub fn retain<F: fn(&T) bool>(self: &mut BinaryHeap<T, A>, keep: F) {
        self.data.retain(keep);
        self.data.as_mut_slice().heapify();
    }

    /// Free every element; the buffer is kept.
    pub fn clear(self: &mut BinaryHeap<T, A>) {
        self.data.clear();
    }

    /// A borrowing iterator over the elements in buffer order.
    pub const fn iter(self: &BinaryHeap<T, A>) VecIter<T> {
        return self.data.iter();
    }

    /// The elements as a slice, in heap order.
    pub const fn as_slice(self: &BinaryHeap<T, A>) []T {
        return self.data.as_slice();
    }

    /// The buffer, in heap order.
    pub fn into_vector(self: BinaryHeap<T, A>) Vector<T, A> {
        return switch self {
            BinaryHeap { data: data } => data,
        };
    }

    /// The elements in ascending order, sorted in place in O(n log n).
    pub fn into_sorted_vector(self: BinaryHeap<T, A>) Vector<T, A> {
        let mut v = self.into_vector();
        v.as_mut_slice().sort_heap();
        return v;
    }
}

extend<T: Ord, A: Allocator + Default> BinaryHeap<T, A> {
    /// An empty heap; no allocation until the first push.
    pub const fn new() BinaryHeap<T, A> {
        return BinaryHeap::<T, A> { data: Vector::<T, A>::new() };
    }

    /// An empty heap with room for `cap` elements.
    pub fn with_capacity(cap: usize) BinaryHeap<T, A> {
        return BinaryHeap::<T, A> { data: Vector::<T, A>::with_capacity(cap) };
    }
}

extend<'a, T: Ord, A: Allocator> PeekMut<'a, T, A> {
    /// Remove the top through the guard, returning it. The guard holds only a borrow, so forgetting it
    /// leaks nothing; it skips the order restore, which `pop` already did.
    pub fn pop(self: PeekMut<'a, T, A>) T {
        let top = self.heap.pop().unwrap();
        forget(self);
        return top;
    }
}

extend<'a, T: Ord, A: Allocator> PeekMut<'a, T, A> as Deref<T> {
    pub fn deref(self: &PeekMut<'a, T, A>) &T {
        return self.heap.data.at(0);
    }
}

extend<'a, T: Ord, A: Allocator> PeekMut<'a, T, A> as DerefMut<T> {
    pub fn deref_mut(self: &mut PeekMut<'a, T, A>) &mut T {
        return self.heap.data.index_mut(0);
    }
}

extend<'a, T: Ord, A: Allocator> PeekMut<'a, T, A> as Free {
    pub fn free(self: &mut PeekMut<'a, T, A>) {
        heap_restore_top(&mut self.heap.data);
    }
}

extend<T: Ord + Clone, A: Allocator> BinaryHeap<T, A> as Clone {
    pub fn clone(self: &BinaryHeap<T, A>) BinaryHeap<T, A> {
        return BinaryHeap::<T, A> { data: self.data.clone() };
    }
}

extend<T: Ord + Format, A: Allocator> BinaryHeap<T, A> as Format {
    /// `[e0, e1, ...]` in buffer order.
    pub fn fmt(self: &BinaryHeap<T, A>) String {
        return self.data.fmt();
    }
}

extend<T: Ord, A: Allocator + Default> BinaryHeap<T, A> as Default {
    pub const fn default() BinaryHeap<T, A> {
        return BinaryHeap::<T, A>::new();
    }
}

// Build from a list of elements (cloned in, then heapified in O(n)).
extend<T: Ord + Clone, A: Allocator + Default> BinaryHeap<T, A> as From<[]T> {
    pub fn from(value: []T) BinaryHeap<T, A> {
        let mut v = Vector::<T, A>::with_capacity(value.len);
        for i in 0..value.len {
            v.push((unsafe value.ptr[i]).clone());
        }
        return BinaryHeap::<T, A>::from_vector(v);
    }
}
