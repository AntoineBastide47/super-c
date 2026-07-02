// Vector<T, A = Global>: a growable, heap-backed contiguous array, monomorphized per (element type,
// allocator). The backing store is sized in bytes with `sizeof(T)`, aligned with `alignof(T)`, and obtained
// through allocator `A` (stored in the vector; zero bytes when it is the zero-sized `Global`). Peek accessors
// borrow the element (`at` -> `&T`, bounds-checked `get`/`first`/`last`/`find` -> `Option<&T>`); `set` is
// unchecked. Auto-`Free` (deep-frees every element and the buffer at scope exit). `new()`/`with_capacity()`
// use a default-constructed allocator; pass a stateful arena/pool with `new_in`/`with_capacity_in`, or pick a
// non-default zero-sized allocator with a turbofish: `Vector::<T, MyAlloc>::new()`.

pub struct Vector<T, A = Global> {
    ptr: *mut T, // owned storage; null while cap == 0 (private)
    len: usize,  // elements in use (private)
    cap: usize,  // elements allocated (private)
    alloc: A,    // the allocator the buffer was obtained through (private; zero-sized for Global)
}

extend<T, A: Allocator> Vector<T, A> {

    // Empty vector backed by an explicit allocator value (a stateful arena/pool handle, or a zero-sized tag).
    pub fn new_in(alloc: A) Vector<T, A> {
        return Vector::<T, A> { ptr: null, len: 0, cap: 0, alloc: alloc, };
    }

    pub fn with_capacity_in(alloc: A, cap: usize) Vector<T, A> {
        let mut v = Vector::<T, A> { ptr: null, len: 0, cap: 0, alloc: alloc, };
        if cap > 0 {
            v.ptr = v.alloc.alloc(cap * sizeof(T), alignof(T)) as *mut T;
            v.cap = cap;
        }
        return v;
    }

    pub fn len(self: &Vector<T, A>) usize {
        return self.len;
    }

    pub fn capacity(self: &Vector<T, A>) usize {
        return self.cap;
    }

    pub fn is_empty(self: &Vector<T, A>) bool {
        return self.len == 0;
    }

    pub fn reserve(self: &mut Vector<T, A>, additional: usize) {
        let needed = self.len + additional;
        if needed <= self.cap {
            return;
        }
        let mut new_cap = self.cap * 2;
        if new_cap == 0 {
            new_cap = 8;
        }
        if new_cap < needed {
            new_cap = needed;
        }
        let p = self.alloc.realloc(self.ptr as *mut void, self.cap * sizeof(T), new_cap * sizeof(T), alignof(T)) as *mut T;
        self.ptr = p;
        self.cap = new_cap;
    }

    pub fn push(self: &mut Vector<T, A>, value: T) {
        self.reserve(1);
        unsafe self.ptr[self.len] = value;
        self.len = self.len + 1;
    }

    pub fn pop(self: &mut Vector<T, A>) Option<T> {
        if self.len == 0 {
            return Option::<T>::None;
        }
        self.len = self.len - 1;
        return Option::<T>::Some(unsafe self.ptr[self.len]);
    }

    // Unchecked element access (caller guarantees `index < len`). Borrows the element in place.
    pub fn at(self: &Vector<T, A>, index: usize) &T {
        return &unsafe self.ptr[index];
    }

    // Bounds-checked element access -- borrows the element (`&T`) so the Vector keeps sole ownership.
    pub fn get(self: &Vector<T, A>, index: usize) Option<&T> {
        if index >= self.len {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&unsafe self.ptr[index]);
    }

    pub fn set(self: &mut Vector<T, A>, index: usize, value: T) {
        unsafe self.ptr[index].free(); // free the replaced element (no-op if T isn't Free), like Map::insert
        unsafe self.ptr[index] = value;
    }

    pub fn first(self: &Vector<T, A>) Option<&T> {
        return self.get(0);
    }

    pub fn last(self: &Vector<T, A>) Option<&T> {
        if self.len == 0 {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&unsafe self.ptr[self.len - 1]);
    }

    pub fn clear(self: &mut Vector<T, A>) {
        let mut i: usize = 0;
        while i < self.len {
            unsafe self.ptr[i].free();
            i = i + 1;
        }
        self.len = 0;
    }

    pub fn truncate(self: &mut Vector<T, A>, new_len: usize) {
        if new_len < self.len {
            let mut i = new_len;
            while i < self.len {
                unsafe self.ptr[i].free();
                i = i + 1;
            }
            self.len = new_len;
        }
    }

    pub fn as_ptr(self: &Vector<T, A>) *const T {
        return self.ptr;
    }

    // Insert `value` at `index`, shifting later elements right. `index` must be <= len.
    pub fn insert(self: &mut Vector<T, A>, index: usize, value: T) {
        self.reserve(1);
        let mut i = self.len;
        while i > index {
            unsafe self.ptr[i] = unsafe self.ptr[i - 1];
            i = i - 1;
        }
        unsafe self.ptr[index] = value;
        self.len = self.len + 1;
    }

    // Remove and return the element at `index`, shifting later elements left (`None` if out of range).
    pub fn remove(self: &mut Vector<T, A>, index: usize) Option<T> {
        if index >= self.len {
            return Option::<T>::None;
        }
        let removed = unsafe self.ptr[index];
        let mut i = index;
        while i + 1 < self.len {
            unsafe self.ptr[i] = unsafe self.ptr[i + 1];
            i = i + 1;
        }
        self.len = self.len - 1;
        return Option::<T>::Some(removed);
    }

    // Exchange the elements at `i` and `j` (both must be in range).
    pub fn swap(self: &mut Vector<T, A>, i: usize, j: usize) {
        let tmp = unsafe self.ptr[i];
        unsafe self.ptr[i] = unsafe self.ptr[j];
        unsafe self.ptr[j] = tmp;
    }

    // Remove the element at `index` by swapping in the last one (O(1), reorders; `None` if out of range).
    pub fn swap_remove(self: &mut Vector<T, A>, index: usize) Option<T> {
        if index >= self.len {
            return Option::<T>::None;
        }
        let removed = unsafe self.ptr[index];
        self.len = self.len - 1;
        unsafe self.ptr[index] = unsafe self.ptr[self.len];
        return Option::<T>::Some(removed);
    }

    // Reverse the elements in place.
    pub fn reverse(self: &mut Vector<T, A>) {
        if self.len == 0 {
            return;
        }
        let mut i: usize = 0;
        let mut j = self.len - 1;
        while i < j {
            let tmp = unsafe self.ptr[i];
            unsafe self.ptr[i] = unsafe self.ptr[j];
            unsafe self.ptr[j] = tmp;
            i = i + 1;
            j = j - 1;
        }
    }

    // A new vector (same allocator) with `f` applied to every element. `f` BORROWS each element (`&T`): this
    // map reads `self` and leaves it owning its elements, so it must not consume them (passing a Free element
    // by value would free the Vector's still-owned copy).
    pub fn map<U>(self: &Vector<T, A>, f: fn(&T) U) Vector<U, A> {
        let mut out = Vector::<U, A>::with_capacity_in(self.alloc, self.len);
        let mut i: usize = 0;
        while i < self.len {
            out.push(f(self.at(i)));
            i = i + 1;
        }
        return out;
    }

    // A borrow of the first element matching `pred`, or `None`. `pred` borrows (`&T`); it must not consume.
    pub fn find(self: &Vector<T, A>, pred: fn(&T) bool) Option<&T> {
        let mut i: usize = 0;
        while i < self.len {
            if pred(self.at(i)) {
                return Option::<&T>::Some(&unsafe self.ptr[i]);
            }
            i = i + 1;
        }
        return Option::<&T>::None;
    }

    // Keep only the elements matching `pred` (in place, preserving order). `pred` borrows (`&T`); rejected
    // elements are freed (no-op when T isn't Free) so nothing leaks.
    pub fn retain(self: &mut Vector<T, A>, pred: fn(&T) bool) {
        let mut w: usize = 0;
        let mut i: usize = 0;
        while i < self.len {
            if pred(&unsafe self.ptr[i]) {
                if w != i {
                    unsafe self.ptr[w] = unsafe self.ptr[i];
                }
                w = w + 1;
            } else {
                unsafe self.ptr[i].free();
            }
            i = i + 1;
        }
        self.len = w;
    }

}

// Convenience constructors for a default-constructible allocator (`Global`, or any zero-sized tag).
extend<T, A: Allocator + Default> Vector<T, A> {
    pub fn new() Vector<T, A> { return Vector::<T, A>::new_in(A::default()); }
    pub fn with_capacity(cap: usize) Vector<T, A> { return Vector::<T, A>::with_capacity_in(A::default(), cap); }
}

// Free the buffer (through `A`) AND deep-free every element. Auto-`Free`: the Vector is released at scope
// exit. Sound because the peek accessors (`at`/`get`/`first`/`last`/`find`/`iter`) borrow (`&T`) rather than
// hand out sharing copies, and the removers (`pop`/`remove`/`swap_remove`) move the element out -- so the
// buffer is the only owner of each live element. Each element `.free()` is a no-op when `T` isn't a Free type.
extend<T, A: Allocator> Vector<T, A> as Free {
    pub fn free(self: &mut Vector<T, A>) {
        let mut i: usize = 0;
        while i < self.len {
            unsafe self.ptr[i].free(); // free the element (no-op if T isn't Free)
            i = i + 1;
        }
        self.alloc.dealloc(self.ptr as *mut void, self.cap * sizeof(T), alignof(T));
        self.ptr = null;
        self.len = 0;
        self.cap = 0;
    }
}

// Standard-interface conformances.
extend<T, A: Allocator + Default> Vector<T, A> as Default {
    pub fn default() Vector<T, A> { return Vector::<T, A>::new(); }
}

// Equality-based algorithms (available when the element type is `Eq`).
extend<T: Eq, A: Allocator> Vector<T, A> {
    // True if any element equals `x` (per `Eq`); O(n) linear scan.
    pub fn contains(self: &Vector<T, A>, x: &T) bool {
        let mut i: usize = 0;
        while i < self.len {
            if unsafe self.ptr[i].eq(x) { return true; }
            i = i + 1;
        }
        return false;
    }

    // Index of the first element equal to `x`, or `None`.
    pub fn position(self: &Vector<T, A>, x: &T) Option<usize> {
        let mut i: usize = 0;
        while i < self.len {
            if unsafe self.ptr[i].eq(x) { return Option::<usize>::Some(i); }
            i = i + 1;
        }
        return Option::<usize>::None;
    }

    // Remove consecutive runs of equal elements, keeping the first of each run. The dropped duplicates
    // are freed (no-op when T isn't Free). O(n); only adjacent equals are removed (sort first for global).
    pub fn dedup(self: &mut Vector<T, A>) {
        if self.len < 2 { return; }
        let mut w: usize = 1;
        let mut r: usize = 1;
        while r < self.len {
            if unsafe self.ptr[r].eq(&unsafe self.ptr[w - 1]) {
                unsafe self.ptr[r].free();
            } else {
                unsafe self.ptr[w] = unsafe self.ptr[r];
                w = w + 1;
            }
            r = r + 1;
        }
        self.len = w;
    }
}

// Order-based algorithms (available when the element type is `Ord`).
extend<T: Ord, A: Allocator> Vector<T, A> {
    // True if the elements are in non-decreasing order (per `Ord`).
    pub fn is_sorted(self: &Vector<T, A>) bool {
        if self.len < 2 { return true; }
        let mut i: usize = 0;
        while i + 1 < self.len {
            if unsafe self.ptr[i].cmp(&unsafe self.ptr[i + 1]) > 0 { return false; }
            i = i + 1;
        }
        return true;
    }

    // Binary search of a sorted vector: `Ok(i)` where an equal element lives, or `Err(i)` the index a
    // missing element would be inserted at to keep order. Behaviour is unspecified if not sorted.
    pub fn binary_search(self: &Vector<T, A>, x: &T) Result<usize, usize> {
        let mut lo: usize = 0;
        let mut hi: usize = self.len;
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            let c = unsafe self.ptr[mid].cmp(x);
            if c == 0 { return Result::<usize, usize>::Ok(mid); }
            if c < 0 { lo = mid + 1; } else { hi = mid; }
        }
        return Result::<usize, usize>::Err(lo);
    }

    // Restore the max-heap property at `root` over the prefix `[0, end)` by sifting it down.
    fn sift_down(self: &mut Vector<T, A>, root: usize, end: usize) {
        let mut r = root;
        let mut child = 2 * r + 1;
        while child < end {
            if child + 1 < end && unsafe self.ptr[child].cmp(&unsafe self.ptr[child + 1]) < 0 { child = child + 1; }
            if unsafe self.ptr[r].cmp(&unsafe self.ptr[child]) >= 0 { return; }
            self.swap(r, child);
            r = child;
            child = 2 * r + 1;
        }
    }

    // Sort the elements in place into non-decreasing order (heapsort: O(n log n), no allocation).
    pub fn sort(self: &mut Vector<T, A>) {
        let n = self.len;
        if n < 2 { return; }
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

// A borrowing cursor over a Vector's elements. `for x in v.iter()` yields a borrow `&T` of each element.
pub struct VecIter<T> {
    pub data: *const T,
    pub idx: usize,
    pub stop: usize,
}

extend<T, A: Allocator> Vector<T, A> {
    pub fn iter(self: &Vector<T, A>) VecIter<T> {
        return VecIter::<T> { data: self.as_ptr(), idx: 0, stop: self.len() };
    }
}

extend<T> VecIter<T> as Iterator<&T> {
    pub fn next(self: &mut VecIter<T>) Option<&T> {
        if self.idx >= self.stop { return Option::<&T>::none(); }
        let r = &unsafe self.data[self.idx];
        self.idx = self.idx + 1;
        return Option::<&T>::some(r);
    }
}

// Index conformances: `v[i]` borrows the element in place (unchecked, like `at` -- the caller keeps
// `i < len`), and `v[lo..hi]` -- any range form, `..=` including the end, an open end meaning the
// vector's `len()` -- is a borrowed `[]T` view of the elements. Views alias the buffer, so they are
// invalidated by any reallocating mutation (push/reserve).
extend<T, A: Allocator> Vector<T, A> as Index<T, []T> {
    pub fn index(self: &Vector<T, A>, i: usize) &T {
        return &unsafe self.ptr[i];
    }
    pub fn index_range(self: &Vector<T, A>, r: Range<usize>) []T {
        let hi = if r.inclusive { r.end + 1; } else { r.end; };
        return Slice::<T> { ptr: unsafe (self.ptr + r.start), len: hi - r.start, };
    }
}

// The writable counterpart: `v[i] = x` stores through the returned element pointer (a plain `=` over a
// Free element frees the replaced value first, compiler-inserted -- same semantics as `set`);
// `index_range_mut` is an in-place writable view.
extend<T, A: Allocator> Vector<T, A> as IndexMut<T, []mut T> {
    pub fn index_mut(self: &mut Vector<T, A>, i: usize) &mut T {
        return &mut unsafe self.ptr[i];
    }
    pub fn index_range_mut(self: &mut Vector<T, A>, r: Range<usize>) []mut T {
        let hi = if r.inclusive { r.end + 1; } else { r.end; };
        return SliceMut::<T> { ptr: unsafe (self.ptr + r.start), len: hi - r.start, };
    }
}

// Conditional conformances: a Vector is Clone/Eq/Hash exactly when its element is. Each dispatches to the
// element's bound method (`e.clone()`, `a.eq(&b)`, `e.hash()`), monomorphized per element type.
extend<T: Clone, A: Allocator> Vector<T, A> as Clone {
    // A deep copy: a fresh backing store (same allocator) whose elements are independent clones.
    pub fn clone(self: &Vector<T, A>) Vector<T, A> {
        let mut out = Vector::<T, A>::with_capacity_in(self.alloc, self.len());
        let mut i: usize = 0;
        while i < self.len() {
            let e = self.at(i);
            out.push(e.clone());
            i = i + 1;
        }
        return out;
    }
}

extend<T: Eq, A: Allocator> Vector<T, A> as Eq {
    pub fn eq(self: &Vector<T, A>, other: &Vector<T, A>) bool {
        if self.len() != other.len() { return false; }
        let mut i: usize = 0;
        while i < self.len() {
            let a = self.at(i);
            let b = other.at(i);
            if !a.eq(b) { return false; }
            i = i + 1;
        }
        return true;
    }
}

extend<T: Hash, A: Allocator> Vector<T, A> as Hash {
    // FNV-1a over the elements' own hashes.
    pub fn hash(self: &Vector<T, A>) u64 {
        let mut h: u64 = 0xcbf29ce484222325;
        let mut i: usize = 0;
        while i < self.len() {
            let e = self.at(i);
            h = (h ^ e.hash()) * 0x100000001b3;
            i = i + 1;
        }
        return h;
    }
}

extend<T: Format, A: Allocator> Vector<T, A> as Format {
    // `[e0, e1, ...]` with each element rendered through its own `fmt`.
    pub fn fmt(self: &Vector<T, A>) String {
        let mut s = String::from_str("[");
        let mut i: usize = 0;
        while i < self.len() {
            if i > 0 { s.push_str(", "); }
            let e = self.at(i);
            let mut es = e.fmt();
            s.push_string(&es);
            es.free();
            i = i + 1;
        }
        s.push_str("]");
        return s;
    }
}
