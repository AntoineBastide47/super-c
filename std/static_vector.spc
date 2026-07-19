// StaticVector<T, const N: usize>: a fixed-capacity, stack-based vector, monomorphized per (element
// type, capacity). The backing store is N inline slots (no heap, no allocator); `len` tracks how many
// hold live elements, so the full length-mutating Vector API exists -- `push`/`insert` panic when the
// N slots are exhausted (capacity can never grow). Same ownership semantics as Vector: peek accessors
// borrow (`at` -> `&T`, bounds-checked `get`/`first`/`last`/`find` -> `Option<&T>`), removers move the
// element out, `set` frees the replaced element. Conditionally `Free`: a StaticVector of a Free element
// type deep-frees its live elements at scope exit; one of plain values stays a plain value.

pub struct StaticVector<T, const N: usize> {
    data: [T; N], // inline storage; only the first `len` slots hold live elements (private)
    len: usize, // elements in use (private)
}

extend<T, const N: usize> StaticVector<T, N> {
    // Empty vector. The unused slots hold no elements (they are never read or freed).
    pub const fn new() StaticVector<T, N> {
        let mut v = StaticVector::<T, N> {};
        v.len = 0;
        return v;
    }

    pub const fn len(self: &StaticVector<T, N>) usize {
        return self.len;
    }

    pub const fn capacity(self: &StaticVector<T, N>) usize {
        return N;
    }

    pub const fn is_empty(self: &StaticVector<T, N>) bool {
        return self.len == 0;
    }

    pub const fn is_full(self: &StaticVector<T, N>) bool {
        return self.len == N;
    }

    // Append `value`. Panics when the N slots are exhausted -- the capacity is fixed.
    pub const fn push(self: &mut StaticVector<T, N>, value: T) {
        if self.len == N {
            panic("StaticVector::push on a full vector");
        }
        let p = (&mut unsafe self.data[0]) as *mut T;
        unsafe p[self.len] = value;
        self.len = self.len + 1;
    }

    pub const fn pop(self: &mut StaticVector<T, N>) Option<T> {
        if self.len == 0 {
            return Option::<T>::None;
        }
        self.len = self.len - 1;
        let p = (&mut unsafe self.data[0]) as *mut T;
        return Option::<T>::Some(unsafe p[self.len]);
    }

    // Bounds-checked element access: panics when `index >= len`. Borrows the element in place.
    pub const fn at(self: &StaticVector<T, N>, index: usize) &T {
        if index >= self.len {
            panic("StaticVector::at: index out of bounds");
        }
        return &unsafe self.data[index];
    }

    // Unchecked element access -- the caller PROVES `index < len` (hot loops with an established
    // bound). Out of range is undefined behavior, hence `unsafe`.
    pub unsafe const fn get_unsafe(self: &StaticVector<T, N>, index: usize) &T {
        return &self.data[index];
    }

    // Bounds-checked element access -- borrows the element (`&T`) so the vector keeps sole ownership.
    pub const fn get(self: &StaticVector<T, N>, index: usize) Option<&T> {
        if index >= self.len {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&unsafe self.data[index]);
    }

    pub const fn set(self: &mut StaticVector<T, N>, index: usize, value: T) {
        if index >= self.len {
            panic("StaticVector::set: index out of bounds");
        }
        let p = (&mut unsafe self.data[0]) as *mut T;
        unsafe p[index] = value;
    }

    pub const fn first(self: &StaticVector<T, N>) Option<&T> {
        return self.get(0);
    }

    pub const fn last(self: &StaticVector<T, N>) Option<&T> {
        if self.len == 0 {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&unsafe self.data[self.len - 1]);
    }

    pub const fn clear(self: &mut StaticVector<T, N>) {
        for i in 0..self.len {
            unsafe self.data[i].free();
        }
        self.len = 0;
    }

    pub const fn truncate(self: &mut StaticVector<T, N>, new_len: usize) {
        if new_len < self.len {
            let mut i = new_len;
            while i < self.len {
                unsafe self.data[i].free();
                i = i + 1;
            }
            self.len = new_len;
        }
    }

    pub const fn as_ptr(self: &StaticVector<T, N>) *const T {
        return &unsafe self.data[0];
    }

    // Insert `value` at `index`, shifting later elements right. `index` must be <= len; panics when full.
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

    // Remove and return the element at `index`, shifting later elements left (`None` if out of range).
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

    // Exchange the elements at `i` and `j`: panics when either is out of range.
    pub const fn swap(self: &mut StaticVector<T, N>, i: usize, j: usize) {
        if i >= self.len || j >= self.len {
            panic("StaticVector::swap: index out of bounds");
        }
        let p = (&mut unsafe self.data[0]) as *mut T;
        let tmp = unsafe p[i];
        unsafe p[i] = unsafe p[j];
        unsafe p[j] = tmp;
    }

    // Remove the element at `index` by swapping in the last one (O(1), reorders; `None` if out of range).
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

    // Reverse the elements in place.
    pub const fn reverse(self: &mut StaticVector<T, N>) {
        if self.len == 0 {
            return;
        }
        let mut i: usize = 0;
        let mut j = self.len - 1;
        while i < j {
            self.swap(i, j);
            i = i + 1;
            j = j - 1;
        }
    }

    // A new vector (same capacity) with `f` applied to every element. `f` BORROWS each element (`&T`):
    // this map reads `self` and leaves it owning its elements, so it must not consume them (passing a
    // Free element by value would free the vector's still-owned copy).
    pub const fn map<U, F: fn(&T) U>(self: &StaticVector<T, N>, f: F) StaticVector<U, N> {
        let mut out = StaticVector::<U, N>::new();
        for i in 0..self.len {
            out.push(f(self.at(i)));
        }
        return out;
    }

    // A borrow of the first element matching `pred`, or `None`. `pred` borrows (`&T`); it must not consume.
    pub const fn find<F: fn(&T) bool>(self: &StaticVector<T, N>, pred: F) Option<&T> {
        for i in 0..self.len {
            if pred(self.at(i)) {
                return Option::<&T>::Some(&unsafe self.data[i]);
            }
        }
        return Option::<&T>::None;
    }

    // Keep only the elements matching `pred` (in place, preserving order). `pred` borrows (`&T`);
    // rejected elements are freed (no-op when T isn't Free) so nothing leaks.
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
    // True if any element equals `x` (per `Eq`); O(n) linear scan.
    pub const fn contains(self: &StaticVector<T, N>, x: &T) bool {
        for i in 0..self.len {
            if unsafe self.data[i] == *x {
                return true;
            }
        }
        return false;
    }

    // Index of the first element equal to `x`, or `None`.
    pub const fn position(self: &StaticVector<T, N>, x: &T) Option<usize> {
        for i in 0..self.len {
            if unsafe self.data[i] == *x {
                return Option::<usize>::Some(i);
            }
        }
        return Option::<usize>::None;
    }

    // Remove consecutive runs of equal elements, keeping the first of each run. The dropped duplicates
    // are freed (no-op when T isn't Free). O(n); only adjacent equals are removed (sort first for global).
    pub const fn dedup(self: &mut StaticVector<T, N>) {
        if self.len < 2 {
            return;
        }
        let mut w: usize = 1;
        let mut r: usize = 1;
        while r < self.len {
            if unsafe self.data[r] == unsafe self.data[w - 1] {
                unsafe self.data[r].free();
            } else {
                unsafe self.data[w] = unsafe self.data[r];
                w = w + 1;
            }
            r = r + 1;
        }
        self.len = w;
    }
}

// Order-based algorithms (available when the element type is `Ord`).
extend<T: Ord, const N: usize> StaticVector<T, N> {
    // True if the elements are in non-decreasing order (per `Ord`).
    pub const fn is_sorted(self: &StaticVector<T, N>) bool {
        if self.len < 2 {
            return true;
        }
        let mut i: usize = 0;
        while i + 1 < self.len {
            if unsafe self.data[i] > unsafe self.data[i + 1] {
                return false;
            }
            i = i + 1;
        }
        return true;
    }

    // Binary search of a sorted vector: `Ok(i)` where an equal element lives, or `Err(i)` the index a
    // missing element would be inserted at to keep order. Behaviour is unspecified if not sorted.
    pub const fn binary_search(self: &StaticVector<T, N>, x: &T) Result<usize, usize> {
        let mut lo: usize = 0;
        let mut hi: usize = self.len;
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            if unsafe self.data[mid] == x {
                return Result::<usize, usize>::Ok(mid);
            } else if unsafe self.data[mid] < x {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return Result::<usize, usize>::Err(lo);
    }

    // Restore the max-heap property at `root` over the prefix `[0, end)` by sifting it down.
    fn sift_down(self: &mut StaticVector<T, N>, root: usize, end: usize) {
        let mut r = root;
        let mut child = 2 * r + 1;
        while child < end {
            if child + 1 < end && unsafe self.data[child] < unsafe self.data[child + 1] {
                child = child + 1;
            }
            if unsafe self.data[r] >= unsafe self.data[child] {
                return;
            }
            self.swap(r, child);
            r = child;
            child = 2 * r + 1;
        }
    }

    // Sort the elements in place into non-decreasing order (heapsort: O(n log n), no allocation).
    pub const fn sort(self: &mut StaticVector<T, N>) {
        let n = self.len;
        if n < 2 {
            return;
        }
        let mut start = n / 2;
        while start > 0 {
            start = start - 1;
            self.sift_down(start, n);
        }
        let mut end = n;
        while end > 1 {
            end = end - 1;
            self.swap(0, end);
            self.sift_down(0, end);
        }
    }
}

// Comparator-driven sorting (no `Ord` required: the closure decides the order).
extend<T, const N: usize> StaticVector<T, N> {
    // Sort in place by a comparator returning negative / zero / positive (heapsort: O(n log n)).
    // The sift is inlined for the same reason as Vector::sort_by: a generic method calling another
    // generic method with its own F is not transitively instantiated yet.
    pub const fn sort_by<F: fn(&T, &T) i32>(self: &mut StaticVector<T, N>, cmp: F) {
        let n = self.len;
        if n < 2 {
            return;
        }
        let mut phase: usize = 0; // 0: heapify roots n/2-1..0; 1: pop the max to the end, re-sift
        let mut start = n / 2;
        let mut end = n;
        loop {
            let mut r: usize = 0;
            if phase == 0 {
                if start == 0 {
                    phase = 1;
                    continue;
                }
                start = start - 1;
                r = start;
            } else {
                if end <= 1 {
                    break;
                }
                end = end - 1;
                self.swap(0, end);
            }
            let mut lim = n;
            if phase == 1 {
                lim = end;
            }
            let mut child = 2 * r + 1;
            while child < lim {
                if child + 1 < lim && cmp(&unsafe self.data[child], &unsafe self.data[child + 1]) < 0 {
                    child = child + 1;
                }
                if cmp(&unsafe self.data[r], &unsafe self.data[child]) >= 0 {
                    break;
                }
                self.swap(r, child);
                r = child;
                child = 2 * r + 1;
            }
        }
    }

    // Sort in place by a derived `Ord` key (`v.sort_by_key(|p: &P| p.age)`).
    pub const fn sort_by_key<K: Ord, F: fn(&T) K>(self: &mut StaticVector<T, N>, key: F) {
        let n = self.len;
        if n < 2 {
            return;
        }
        let mut i: usize = 1; // insertion sort through swaps: key extraction stays borrow-only
        while i < n {
            let mut j = i;
            while j > 0 {
                let prev = key(&unsafe self.data[j - 1]);
                let cur = key(&unsafe self.data[j]);
                if prev <= cur {
                    break;
                }
                self.swap(j - 1, j);
                j = j - 1;
            }
            i = i + 1;
        }
    }
}

// Index conformances: `v[i]` borrows the element in place (unchecked, like `at` -- the caller keeps
// `i < len`), and `v[lo..hi]` -- any range form, `..=` including the end, an open end meaning the
// vector's `len()` -- is a borrowed `[]T` view of the elements. Views alias the inline buffer, so they
// are invalidated when the StaticVector is moved.
extend<T, const N: usize> StaticVector<T, N> as Index<T, []T> {
    pub const fn index(self: &StaticVector<T, N>, i: usize) &T {
        if i >= self.len {
            panic("StaticVector<T, N>[i]: index out of bounds");
        }
        return &unsafe self.data[i];
    }
    pub const fn index_range(self: &StaticVector<T, N>, r: Range<usize>) []T {
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        if r.start > hi || hi > self.len {
            panic("StaticVector<T, N>[a..b]: range out of bounds");
        }
        return Slice::<T> { ptr: unsafe (self.as_ptr() + r.start), len: hi - r.start };
    }
}

// The writable counterpart: `v[i] = x` stores through the returned element pointer (a plain `=` over a
// Free element frees the replaced value first, compiler-inserted -- same semantics as `set`);
// `index_range_mut` is an in-place writable view.
extend<T, const N: usize> StaticVector<T, N> as IndexMut<T, []mut T> {
    pub const fn index_mut(self: &mut StaticVector<T, N>, i: usize) &mut T {
        if i >= self.len {
            panic("StaticVector<T, N>[i]: index out of bounds");
        }
        return &mut unsafe self.data[i];
    }
    pub const fn index_range_mut(self: &mut StaticVector<T, N>, r: Range<usize>) []mut T {
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        let p = (&mut unsafe self.data[0]) as *mut T;
        if r.start > hi || hi > self.len {
            panic("StaticVector<T, N>[a..b]: range out of bounds");
        }
        return SliceMut::<T> { ptr: unsafe (p + r.start), len: hi - r.start };
    }
}

// Conditional conformances: a StaticVector is Clone/Eq/Hash exactly when its element is. Each dispatches
// to the element's bound method (`e.clone()`, `a.eq(&b)`, `e.hash()`), monomorphized per element type.
extend<T: Clone, const N: usize> StaticVector<T, N> as Clone {
    // A deep copy whose elements are independent clones.
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
    // FNV-1a over the elements' own hashes.
    pub const fn hash(self: &StaticVector<T, N>) u64 {
        let mut h: u64 = 0xcbf29ce484222325;
        for i in 0..self.len {
            let e = self.at(i);
            h = (h ^ e.hash()) * 0x100000001b3;
        }
        return h;
    }
}

extend<T: Format, const N: usize> StaticVector<T, N> as Format {
    // `[e0, e1, ...]` with each element rendered through its own `fmt`.
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
