// StaticVector<T, const N: usize>: a fixed-capacity, stack-based vector, monomorphized per (element
// type, capacity). The backing store is N inline slots (no heap, no allocator); `len` tracks how many
// hold live elements, so the full length-mutating Vector API exists: `push`/`insert` panic when the
// N slots are exhausted (capacity can never grow). Same ownership semantics as Vector: peek accessors
// borrow (`at` -> `&T`, bounds-checked `get`/`first`/`last`/`find` -> `Option<&T>`), removers move the
// element out, `set` frees the replaced element. Conditionally `Free`: a StaticVector of a Free element
// type deep-frees its live elements at scope exit; one of plain values stays a plain value.
//
// Complexity: push, pop, at, get, set, swap and swap_remove are O(1); insert and remove are O(len -
// index); the sequence algorithms of `as_mut_slice()` keep the bounds std/slice.spc states. The storage
// is inline: push and pop never move it, so only moving the StaticVector or mutating it ends a borrow;
// iteration is in index order. No allocation; a StaticVector is Send / Sync when its elements are.

/// A vector with inline storage for at most N elements and no heap allocation; pushing past N panics.
pub struct StaticVector<T, const N: usize> {
    data: [T; N], // inline storage; only the first `len` slots hold live elements (private)
    len: usize, // elements in use (private)
}

extend<T, const N: usize> StaticVector<T, N> {
    /// Empty vector. The unused slots hold no elements (they are never read or freed).
    pub const fn new() StaticVector<T, N> {
        let mut v = Uninit::<StaticVector<T, N>> { none: 0 }; // the slots hold no element
        let p = (&mut v.value.len) as *mut usize;
        unsafe *p = 0;
        return unsafe v.value;
    }

    /// Number of live elements.
    pub const fn len(self: &StaticVector<T, N>) usize {
        return self.len;
    }

    /// Always N.
    pub const fn capacity(self: &StaticVector<T, N>) usize {
        return N;
    }

    /// True when no element is stored.
    pub const fn is_empty(self: &StaticVector<T, N>) bool {
        return self.len == 0;
    }

    /// True when N elements are stored.
    pub const fn is_full(self: &StaticVector<T, N>) bool {
        return self.len == N;
    }

    /// Append `value`. Panics when the N slots are exhausted: the capacity is fixed.
    pub const fn push(self: &mut StaticVector<T, N>, value: T) {
        if self.len == N {
            panic("StaticVector::push on a full vector");
        }
        let p = (&mut unsafe self.data[0]) as *mut T;
        unsafe p[self.len] = value;
        self.len = self.len + 1;
    }

    /// Removes and returns the last element, moving ownership to the caller (`None` when empty).
    pub const fn pop(self: &mut StaticVector<T, N>) Option<T> {
        if self.len == 0 {
            return Option::<T>::None;
        }
        self.len = self.len - 1;
        let p = (&mut unsafe self.data[0]) as *mut T;
        return Option::<T>::Some(unsafe p[self.len]);
    }

    /// Bounds-checked element access: panics when `index >= len`. Borrows the element in place.
    pub const fn at(self: &StaticVector<T, N>, index: usize) &T {
        if index >= self.len {
            panic("StaticVector::at: index out of bounds");
        }
        return &unsafe self.data[index];
    }

    /// Unchecked element access: the caller PROVES `index < len` (hot loops with an established
    /// bound). Out of range is undefined behavior, hence `unsafe`.
    pub unsafe const fn get_unsafe(self: &StaticVector<T, N>, index: usize) &T {
        return &self.data[index];
    }

    /// Bounds-checked element access: borrows the element (`&T`) so the vector keeps sole ownership.
    pub const fn get(self: &StaticVector<T, N>, index: usize) Option<&T> {
        if index >= self.len {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&unsafe self.data[index]);
    }

    /// Panics when `index >= len`. Frees the replaced element, then takes ownership of `value`.
    pub const fn set(self: &mut StaticVector<T, N>, index: usize, value: T) {
        if index >= self.len {
            panic("StaticVector::set: index out of bounds");
        }
        let p = (&mut unsafe self.data[0]) as *mut T;
        // A store through the raw pointer frees nothing, so the replaced element is freed first.
        unsafe p[index].free();
        unsafe p[index] = value;
    }

    /// The first element, None when empty.
    pub const fn first(self: &StaticVector<T, N>) Option<&T> {
        return self.get(0);
    }

    /// The last element, None when empty.
    pub const fn last(self: &StaticVector<T, N>) Option<&T> {
        if self.len == 0 {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&unsafe self.data[self.len - 1]);
    }

    /// Frees every live element (len becomes 0); the inline slots themselves have nothing to release.
    pub const fn clear(self: &mut StaticVector<T, N>) {
        for i in 0..self.len {
            unsafe self.data[i].free();
        }
        self.len = 0;
    }

    /// Shortens to `new_len` elements, freeing the dropped tail (no-op when already shorter).
    pub const fn truncate(self: &mut StaticVector<T, N>, new_len: usize) {
        if new_len < self.len {
            for i in new_len..self.len {
                unsafe self.data[i].free();
            }
            self.len = new_len;
        }
    }

    /// Raw pointer into the inline storage; invalidated when the StaticVector is moved.
    pub const fn as_ptr(self: &StaticVector<T, N>) *const T {
        return &unsafe self.data[0];
    }

    /// Insert `value` at `index`, shifting later elements right. `index` must be <= len; panics when full.
    pub const fn insert(self: &mut StaticVector<T, N>, index: usize, value: T) {
        if self.len == N {
            panic("StaticVector::insert on a full vector");
        }
        if index > self.len {
            panic("StaticVector::insert: index out of bounds");
        }
        let p = (&mut unsafe self.data[0]) as *mut T;
        let mut i = self.len;
        while i > index {
            unsafe p[i] = unsafe p[i - 1];
            i = i - 1;
        }
        unsafe p[index] = value;
        self.len = self.len + 1;
    }

    /// Remove and return the element at `index`, shifting later elements left (`None` if out of range).
    pub const fn remove(self: &mut StaticVector<T, N>, index: usize) Option<T> {
        if index >= self.len {
            return Option::<T>::None;
        }
        let p = (&mut unsafe self.data[0]) as *mut T;
        let removed = unsafe p[index];
        let mut i = index;
        while i + 1 < self.len {
            unsafe p[i] = unsafe p[i + 1];
            i = i + 1;
        }
        self.len = self.len - 1;
        return Option::<T>::Some(removed);
    }

    /// Exchange the elements at `i` and `j`: panics when either is out of range.
    pub const fn swap(self: &mut StaticVector<T, N>, i: usize, j: usize) {
        if i >= self.len || j >= self.len {
            panic("StaticVector::swap: index out of bounds");
        }
        let p = (&mut unsafe self.data[0]) as *mut T;
        let tmp = unsafe p[i];
        unsafe p[i] = unsafe p[j];
        unsafe p[j] = tmp;
    }

    /// Remove the element at `index` by swapping in the last one (O(1), reorders; `None` if out of range).
    pub const fn swap_remove(self: &mut StaticVector<T, N>, index: usize) Option<T> {
        if index >= self.len {
            return Option::<T>::None;
        }
        let p = (&mut unsafe self.data[0]) as *mut T;
        let removed = unsafe p[index];
        self.len = self.len - 1;
        unsafe p[index] = unsafe p[self.len];
        return Option::<T>::Some(removed);
    }

    /// Reverse the elements in place.
    pub const fn reverse(self: &mut StaticVector<T, N>) {
        self.as_mut_slice().reverse();
    }

    /// A new vector (same capacity) with `f` applied to every element. `f` BORROWS each element (`&T`):
    /// this map reads `self` and leaves it owning its elements, so it must not consume them (passing a
    /// Free element by value would free the vector's still-owned copy).
    pub const fn map<U, F: fn(&T) U>(self: &StaticVector<T, N>, f: F) StaticVector<U, N> {
        let mut out = StaticVector::<U, N>::new();
        for i in 0..self.len {
            out.push(f(self.at(i)));
        }
        return out;
    }

    /// A borrow of the first element matching `pred`, or `None`. `pred` borrows (`&T`); it must not consume.
    pub const fn find<F: fn(&T) bool>(self: &StaticVector<T, N>, pred: F) Option<&T> {
        for i in 0..self.len {
            if pred(self.at(i)) {
                return Option::<&T>::Some(&unsafe self.data[i]);
            }
        }
        return Option::<&T>::None;
    }

    /// Keep only the elements matching `pred` (in place, preserving order). `pred` borrows (`&T`);
    /// rejected elements are freed (no-op when T isn't Free) so nothing leaks.
    pub const fn retain<F: fn(&T) bool>(self: &mut StaticVector<T, N>, pred: F) {
        let mut w: usize = 0;
        for i in 0..self.len {
            if pred(&unsafe self.data[i]) {
                if w != i {
                    unsafe self.data[w] = unsafe self.data[i];
                }
                w = w + 1;
            } else {
                unsafe self.data[i].free();
            }
        }
        self.len = w;
    }

    /// A by-reference iterator over the live elements in order.
    pub const fn iter(self: &StaticVector<T, N>) VecIter<T> {
        return VecIter::<T> { data: self.as_ptr(), idx: 0, stop: self.len };
    }
}

// Deep-free the live elements. Conditional: a StaticVector is Free exactly when its element is (there
// is no buffer to release), so one of plain values (i32, ...) stays a plain copyable value. Sound for
// the same reason as Vector: the peek accessors borrow (`&T`) and the removers move the element out.
extend<T: Free, const N: usize> StaticVector<T, N> as Free {
    pub fn free(self: &mut StaticVector<T, N>) {
        for i in 0..self.len {
            unsafe self.data[i].free();
        }
        self.len = 0;
    }
}

// Standard-interface conformances.
extend<T, const N: usize> StaticVector<T, N> as Default {
    pub const fn default() StaticVector<T, N> {
        return StaticVector::<T, N>::new();
    }
}

// Equality-based algorithms (available when the element type is `Eq`).
extend<T: Eq, const N: usize> StaticVector<T, N> {
    /// True if any element equals `x` (per `Eq`); O(n) linear scan.
    pub const fn contains(self: &StaticVector<T, N>, x: &T) bool {
        for i in 0..self.len {
            if unsafe self.data[i] == *x {
                return true;
            }
        }
        return false;
    }

    /// Index of the first element equal to `x`, or `None`.
    pub const fn position(self: &StaticVector<T, N>, x: &T) Option<usize> {
        for i in 0..self.len {
            if unsafe self.data[i] == *x {
                return Option::<usize>::Some(i);
            }
        }
        return Option::<usize>::None;
    }

    /// Remove consecutive runs of equal elements, keeping the first of each run. The dropped duplicates
    /// are freed (no-op when T isn't Free). O(n); only adjacent equals are removed (sort first for global).
    pub const fn dedup(self: &mut StaticVector<T, N>) {
        let k = self.as_mut_slice().partition_dedup();
        self.truncate(k);
    }
}

// Order-based algorithms: the shared slice algorithms (std/slice.spc) over the live elements.
extend<T: Ord, const N: usize> StaticVector<T, N> {
    /// True if the elements are in non-decreasing order (per `Ord`).
    pub const fn is_sorted(self: &StaticVector<T, N>) bool {
        return self.as_slice().is_sorted();
    }

    /// Binary search of a sorted vector: `Ok(i)` where an equal element lives (any one of several), or
    /// `Err(i)`, the index a missing element would be inserted at to keep order. O(log n); unspecified
    /// result if not sorted.
    pub const fn binary_search(self: &StaticVector<T, N>, x: &T) Result<usize, usize> {
        return self.as_slice().binary_search(x);
    }

    /// Sort in place into non-decreasing order, unstable (pattern-defeating quicksort: O(n log n) worst
    /// case, no allocation).
    pub const fn sort(self: &mut StaticVector<T, N>) {
        self.as_mut_slice().sort();
    }

    /// Sort in place into non-decreasing order, stable, with no allocation: O(n log n) comparisons and
    /// O(n log^2 n) moves (`SliceMut::sort_stable_in_place`).
    pub fn sort_stable_in_place(self: &mut StaticVector<T, N>) {
        self.as_mut_slice().sort_stable_in_place();
    }
}

// Comparator-driven sorting (no `Ord` required: the closure decides the order).
extend<T, const N: usize> StaticVector<T, N> {
    /// Sort in place by a comparator returning negative / zero / positive, unstable. O(n log n).
    pub const fn sort_by<F: fn(&T, &T) i32>(self: &mut StaticVector<T, N>, cmp: F) {
        self.as_mut_slice().sort_by(cmp);
    }

    /// Stable `sort_by` with no allocation (`SliceMut::sort_stable_in_place_by`).
    pub fn sort_stable_in_place_by<F: fn(&T, &T) i32>(self: &mut StaticVector<T, N>, cmp: F) {
        self.as_mut_slice().sort_stable_in_place_by(cmp);
    }

    /// Sort in place by a derived `Ord` key, unstable. O(n log n); the key is computed twice per
    /// comparison.
    pub const fn sort_by_key<K: Ord, F: fn(&T) K>(self: &mut StaticVector<T, N>, key: F) {
        self.as_mut_slice().sort_by_key::<K, F>(key);
    }
}

// Index conformances: `v[i]` borrows the element in place (bounds-checked like `at`: it panics when
// `i >= len`), and `v[lo..hi]`: any range form, `..=` including the end, an open end meaning the
// vector's `len()`: is a borrowed `[]T` view of the elements. Views alias the inline buffer, so they
// are invalidated when the StaticVector is moved.
extend<T, const N: usize> StaticVector<T, N> as Index<T, []T> {
    pub const fn index(self: &StaticVector<T, N>, i: usize) &T {
        if i >= self.len {
            panic_parts(type_info::<Self>().qualified_name, "[i]: index out of bounds");
        }
        return &unsafe self.data[i];
    }
    pub const fn index_range(self: &StaticVector<T, N>, r: Range<usize>) []T {
        if r.inclusive && r.end >= self.len {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        if r.start > hi || hi > self.len {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        return unsafe Slice::<T> { ptr: self.as_ptr() + r.start, len: hi - r.start };
    }
}

// The writable counterpart: `v[i] = x` stores through the returned element pointer (a plain `=` over a
// Free element frees the replaced value first, compiler-inserted: same semantics as `set`);
// `index_range_mut` is an in-place writable view.
extend<T, const N: usize> StaticVector<T, N> as IndexMut<T, []mut T> {
    pub const fn index_mut(self: &mut StaticVector<T, N>, i: usize) &mut T {
        if i >= self.len {
            panic_parts(type_info::<Self>().qualified_name, "[i]: index out of bounds");
        }
        return &mut unsafe self.data[i];
    }
    pub const fn index_range_mut(self: &mut StaticVector<T, N>, r: Range<usize>) []mut T {
        if r.inclusive && r.end >= self.len {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        let p = (&mut unsafe self.data[0]) as *mut T;
        if r.start > hi || hi > self.len {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        return unsafe SliceMut::<T> { ptr: p + r.start, len: hi - r.start };
    }
}

// Conditional conformances: a StaticVector is Clone/Eq/Hash exactly when its element is. Each dispatches
// to the element's bound method (`e.clone()`, `a.eq(&b)`, `e.hash_into(h)`), monomorphized per element type.
extend<T: Clone, const N: usize> StaticVector<T, N> as Clone {
    /// A deep copy whose elements are independent clones.
    pub const fn clone(self: &StaticVector<T, N>) StaticVector<T, N> {
        let mut out = StaticVector::<T, N>::new();
        for i in 0..self.len {
            let e = self.at(i);
            out.push(e.clone());
        }
        return out;
    }
}

extend<T: Eq, const N: usize> StaticVector<T, N> as Eq {
    pub const fn eq(self: &StaticVector<T, N>, other: &StaticVector<T, N>) bool {
        if self.len != other.len {
            return false;
        }
        for i in 0..self.len {
            let a = self.at(i);
            let b = other.at(i);
            if *a != *b {
                return false;
            }
        }
        return true;
    }
}

extend<T: Hash, const N: usize> StaticVector<T, N> as Hash {
    /// The length, then every element through its own `hash_into`: equal sequences feed equal streams.
    pub fn hash_into<H: Hasher>(self: &StaticVector<T, N>, h: &mut H) {
        h.write_u64(self.len() as u64);
        for i in 0..self.len() {
            self.at(i).hash_into(h);
        }
    }
}

extend<T: Format, const N: usize> StaticVector<T, N> as Format {
    /// `[e0, e1, ...]` with each element rendered through its own `fmt`.
    pub fn fmt(self: &StaticVector<T, N>) String {
        let mut s = String::from_str("[");
        for i in 0..self.len {
            if i > 0 {
                s.push_str(", ");
            }
            let e = self.at(i);
            let es = e.fmt();
            s.push_string(&es);
        }
        s.push_str("]");
        return s;
    }
}

extend<T, const N: usize> StaticVector<T, N> as AsSlice<T> {
    /// A view of the live elements; invalidated when the StaticVector is moved.
    pub const fn as_slice(self: &StaticVector<T, N>) []T {
        return unsafe Slice::<T> { ptr: &self.data[0], len: self.len };
    }
}

extend<T, const N: usize> StaticVector<T, N> as AsSliceMut<T> {
    /// A writable view of the live elements: the shared slice algorithms run on it.
    pub const fn as_mut_slice(self: &mut StaticVector<T, N>) []mut T {
        return unsafe SliceMut::<T> { ptr: &mut self.data[0], len: self.len };
    }
}
