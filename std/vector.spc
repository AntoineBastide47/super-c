// Vector<T, A = Global>: a growable, heap-backed contiguous array, monomorphized per (element type,
// allocator). The backing store is sized in bytes with `sizeof(T)`, aligned with `alignof(T)`, and obtained
// through allocator `A` (stored in the vector; zero bytes when it is the zero-sized `Global`). Peek accessors
// borrow the element (`at` -> `&T`, bounds-checked `get`/`first`/`last`/`find` -> `Option<&T>`); `set`
// panics out of range and frees the replaced element. Auto-`Free` (deep-frees every element and the buffer
// at scope exit). `new()`/`with_capacity()` use a default-constructed allocator; pass a stateful arena/pool with
// `new_in`/`with_capacity_in`, or pick a non-default zero-sized allocator with a turbofish:
// `Vector::<T, MyAlloc>::new()`.

pub struct Vector<T, A = Global> {
    ptr: *mut T, // owned storage; null while cap == 0 (private)
    len: usize, // elements in use (private)
    cap: usize, // elements allocated (private)
    alloc: A, // the allocator the buffer was obtained through (private; zero-sized for Global)
}

// A Vector owns its elements, so it is Send / Sync when its elements and allocator are (the owned buffer
// pointer would otherwise make it structurally neither).
unsafe extend<T: Send, A: Send> Vector<T, A> as Send {}

unsafe extend<T: Sync, A: Sync> Vector<T, A> as Sync {}

extend<T, A: Allocator> Vector<T, A> {
    /// Empty vector backed by an explicit allocator value (a stateful arena/pool handle, or a zero-sized tag).
    pub const fn new_in(alloc: A) Vector<T, A> {
        return Vector::<T, A> { ptr: null, len: 0, cap: 0, alloc: alloc };
    }

    /// Pre-allocates room for `cap` elements through an explicit allocator (no allocation when cap == 0).
    pub const fn with_capacity_in(alloc: A, cap: usize) Vector<T, A> {
        let mut v = Vector::<T, A> { ptr: null, len: 0, cap: 0, alloc: alloc };
        if cap > 0 {
            v.ptr = (unsafe v.alloc.alloc(cap * sizeof(T), alignof(T))) as *mut T;
            v.cap = cap;
        }
        return v;
    }

    pub const fn len(self: &Vector<T, A>) usize {
        return self.len;
    }

    pub const fn capacity(self: &Vector<T, A>) usize {
        return self.cap;
    }

    pub const fn is_empty(self: &Vector<T, A>) bool {
        return self.len == 0;
    }

    /// Guarantees room for `additional` more elements, growing by doubling (amortised O(1) append).
    pub const fn reserve(self: &mut Vector<T, A>, additional: usize) {
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
        let p = (unsafe self.alloc.realloc(self.ptr, self.cap * sizeof(T), new_cap * sizeof(T), alignof(T))) as *mut T;
        self.ptr = p;
        self.cap = new_cap;
    }

    /// Appends `value`, taking ownership of it; amortised O(1).
    pub const fn push(self: &mut Vector<T, A>, value: T) {
        self.reserve(1);
        unsafe self.ptr[self.len] = value;
        self.len = self.len + 1;
    }

    /// Removes and returns the last element, moving ownership to the caller (`None` when empty).
    pub const fn pop(self: &mut Vector<T, A>) Option<T> {
        if self.len == 0 {
            return Option::<T>::None;
        }
        self.len = self.len - 1;
        return Option::<T>::Some(unsafe self.ptr[self.len]);
    }

    /// Bounds-checked element access: panics when `index >= len`. Borrows the element in place.
    pub const fn at(self: &Vector<T, A>, index: usize) &T {
        if index >= self.len {
            panic("Vector::at: index out of bounds");
        }
        return &unsafe self.ptr[index];
    }

    /// Unchecked element access -- the caller PROVES `index < len` (hot loops with an established
    /// bound). Out of range is undefined behavior, hence `unsafe`.
    pub unsafe const fn get_unsafe(self: &Vector<T, A>, index: usize) &T {
        return &self.ptr[index];
    }

    /// Bounds-checked element access -- borrows the element (`&T`) so the Vector keeps sole ownership.
    pub const fn get(self: &Vector<T, A>, index: usize) Option<&T> {
        if index >= self.len {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&unsafe self.ptr[index]);
    }

    /// Panics when `index >= len`. Frees the replaced element, then takes ownership of `value`.
    pub const fn set(self: &mut Vector<T, A>, index: usize, value: T) {
        if index >= self.len {
            panic("Vector::set: index out of bounds");
        }
        unsafe self.ptr[index].free();
        unsafe self.ptr[index] = value;
    }

    pub const fn first(self: &Vector<T, A>) Option<&T> {
        return self.get(0);
    }

    pub const fn last(self: &Vector<T, A>) Option<&T> {
        if self.len == 0 {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&unsafe self.ptr[self.len - 1]);
    }

    /// Frees every element; keeps the buffer for reuse (capacity unchanged).
    pub const fn clear(self: &mut Vector<T, A>) {
        for i in 0..self.len {
            unsafe self.ptr[i].free();
        }
        self.len = 0;
    }

    /// Shortens to `new_len` elements, freeing the dropped tail (no-op when already shorter).
    pub const fn truncate(self: &mut Vector<T, A>, new_len: usize) {
        if new_len < self.len {
            let mut i = new_len;
            while i < self.len {
                unsafe self.ptr[i].free();
                i = i + 1;
            }
            self.len = new_len;
        }
    }

    /// Raw pointer to the buffer; invalidated by any reallocating mutation (push/reserve/insert).
    pub const fn as_ptr(self: &Vector<T, A>) *const T {
        return self.ptr;
    }

    /// Insert `value` at `index`, shifting later elements right. `index` must be <= len (not checked).
    pub const fn insert(self: &mut Vector<T, A>, index: usize, value: T) {
        self.reserve(1);
        let mut i = self.len;
        while i > index {
            unsafe self.ptr[i] = unsafe self.ptr[i - 1];
            i = i - 1;
        }
        unsafe self.ptr[index] = value;
        self.len = self.len + 1;
    }

    /// Remove and return the element at `index`, shifting later elements left (`None` if out of range).
    pub const fn remove(self: &mut Vector<T, A>, index: usize) Option<T> {
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

    /// Exchange the elements at `i` and `j` (both must be in range; not checked).
    pub const fn swap(self: &mut Vector<T, A>, i: usize, j: usize) {
        let tmp = unsafe self.ptr[i];
        unsafe self.ptr[i] = unsafe self.ptr[j];
        unsafe self.ptr[j] = tmp;
    }

    /// Remove the element at `index` by swapping in the last one (O(1), reorders; `None` if out of range).
    pub const fn swap_remove(self: &mut Vector<T, A>, index: usize) Option<T> {
        if index >= self.len {
            return Option::<T>::None;
        }
        let removed = unsafe self.ptr[index];
        self.len = self.len - 1;
        unsafe self.ptr[index] = unsafe self.ptr[self.len];
        return Option::<T>::Some(removed);
    }

    /// Reverse the elements in place.
    pub const fn reverse(self: &mut Vector<T, A>) {
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

    /// A new vector (same allocator) with `f` applied to every element. `f` BORROWS each element (`&T`): this
    /// map reads `self` and leaves it owning its elements, so it must not consume them (passing a Free element
    /// by value would free the Vector's still-owned copy).
    pub const fn map<U, F: fn(&T) U>(self: &Vector<T, A>, f: F) Vector<U, A> {
        let mut out = Vector::<U, A>::with_capacity_in(self.alloc, self.len);
        for i in 0..self.len {
            out.push(f(self.at(i)));
        }
        return out;
    }

    /// A borrow of the first element matching `pred`, or `None`. `pred` borrows (`&T`); it must not consume.
    pub const fn find<F: fn(&T) bool>(self: &Vector<T, A>, pred: F) Option<&T> {
        for i in 0..self.len {
            if pred(self.at(i)) {
                return Option::<&T>::Some(&unsafe self.ptr[i]);
            }
        }
        return Option::<&T>::None;
    }

    /// Keep only the elements matching `pred` (in place, preserving order). `pred` borrows (`&T`); rejected
    /// elements are freed (no-op when T isn't Free) so nothing leaks.
    pub const fn retain<F: fn(&T) bool>(self: &mut Vector<T, A>, pred: F) {
        let mut w: usize = 0;
        for i in 0..self.len {
            if pred(&unsafe self.ptr[i]) {
                if w != i {
                    unsafe self.ptr[w] = unsafe self.ptr[i];
                }
                w = w + 1;
            } else {
                unsafe self.ptr[i].free();
            }
        }
        self.len = w;
    }
}

// Convenience constructors for a default-constructible allocator (`Global`, or any zero-sized tag).
extend<T, A: Allocator + Default> Vector<T, A> {
    pub const fn new() Vector<T, A> {
        return Vector::<T, A>::new_in(A::default());
    }
    pub const fn with_capacity(cap: usize) Vector<T, A> {
        return Vector::<T, A>::with_capacity_in(A::default(), cap);
    }
}

// Free the buffer (through `A`) AND deep-free every element. Auto-`Free`: the Vector is released at scope
// exit. Sound because the peek accessors (`at`/`get`/`first`/`last`/`find`/`iter`) borrow (`&T`) rather than
// hand out sharing copies, and the removers (`pop`/`remove`/`swap_remove`) move the element out -- so the
// buffer is the only owner of each live element. Each element `.free()` is a no-op when `T` isn't a Free type.
// Resizing needs a value for the slots it adds, and a `Free` element cannot be copied into them (filling
// ten slots from one `String` would hand ten owners the same buffer) -- so it is available exactly for the
// element types that can produce a fresh value on demand.
extend<T: Default, A: Allocator> Vector<T, A> {
    /// Resize to exactly `n` elements: the tail beyond `n` is freed, and any new slot is `T::default()`.
    pub fn resize_default(self: &mut Vector<T, A>, n: usize) {
        if n < self.len {
            self.truncate(n);
            return;
        }
        self.reserve(n - self.len);
        while self.len < n {
            self.push(T::default());
        }
    }
}

extend<T, A: Allocator> Vector<T, A> as Free {
    pub fn free(self: &mut Vector<T, A>) {
        self.clear();
        unsafe self.alloc.dealloc(self.ptr, self.cap * sizeof(T), alignof(T));
        self.ptr = null;
        self.cap = 0;
    }
}

// Standard-interface conformances.
extend<T, A: Allocator + Default> Vector<T, A> as Default {
    pub const fn default() Vector<T, A> {
        return Vector::<T, A>::new();
    }
}

// Equality-based algorithms (available when the element type is `Eq`).
extend<T: Eq, A: Allocator> Vector<T, A> {
    /// True if any element equals `x` (per `Eq`); O(n) linear scan.
    pub const fn contains(self: &Vector<T, A>, x: &T) bool {
        for i in 0..self.len {
            if unsafe self.ptr[i] == *x {
                return true;
            }
        }
        return false;
    }

    /// Index of the first element equal to `x`, or `None`.
    pub const fn position(self: &Vector<T, A>, x: &T) Option<usize> {
        for i in 0..self.len {
            if unsafe self.ptr[i] == *x {
                return Option::<usize>::Some(i);
            }
        }
        return Option::<usize>::None;
    }

    /// Remove consecutive runs of equal elements, keeping the first of each run. The dropped duplicates
    /// are freed (no-op when T isn't Free). O(n); only adjacent equals are removed (sort first for global).
    pub const fn dedup(self: &mut Vector<T, A>) {
        if self.len < 2 {
            return;
        }
        let mut w: usize = 1;
        for r in 0..self.len {
            if unsafe self.ptr[r] == unsafe self.ptr[w - 1] {
                unsafe self.ptr[r].free();
            } else {
                unsafe self.ptr[w] = unsafe self.ptr[r];
                w = w + 1;
            }
        }
        self.len = w;
    }
}

// Order-based algorithms (available when the element type is `Ord`).
extend<T: Ord, A: Allocator> Vector<T, A> {
    /// True if the elements are in non-decreasing order (per `Ord`).
    pub const fn is_sorted(self: &Vector<T, A>) bool {
        if self.len < 2 {
            return true;
        }
        let mut i: usize = 0;
        while i + 1 < self.len {
            if unsafe self.ptr[i] > unsafe self.ptr[i + 1] {
                return false;
            }
            i = i + 1;
        }
        return true;
    }

    /// Binary search of a sorted vector: `Ok(i)` where an equal element lives, or `Err(i)` the index a
    /// missing element would be inserted at to keep order. Behaviour is unspecified if not sorted.
    pub const fn binary_search(self: &Vector<T, A>, x: &T) Result<usize, usize> {
        let mut lo: usize = 0;
        let mut hi: usize = self.len;
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            if unsafe self.ptr[mid] == *x {
                return Result::<usize, usize>::Ok(mid);
            } else if unsafe self.ptr[mid] < *x {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return Result::<usize, usize>::Err(lo);
    }

    // Restore the max-heap property at `root` over the prefix `[0, end)` by sifting it down.
    fn sift_down(self: &mut Vector<T, A>, root: usize, end: usize) {
        let mut r = root;
        let mut child = 2 * r + 1;
        while child < end {
            if child + 1 < end && unsafe self.ptr[child] < unsafe self.ptr[child + 1] {
                child = child + 1;
            }
            if unsafe self.ptr[r] >= unsafe self.ptr[child] {
                return;
            }
            self.swap(r, child);
            r = child;
            child = 2 * r + 1;
        }
    }

    /// Sort the elements in place into non-decreasing order (heapsort: O(n log n), no allocation).
    pub const fn sort(self: &mut Vector<T, A>) {
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
extend<T, A: Allocator> Vector<T, A> {
    /// Sort in place by a comparator returning negative / zero / positive (heapsort: O(n log n)).
    /// The sift is inlined: a generic method calling another generic method with its own F is not
    /// transitively instantiated yet, so the helper stays inside the one specialization.
    pub const fn sort_by<F: fn(&T, &T) i32>(self: &mut Vector<T, A>, cmp: F) {
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
                if child + 1 < lim && cmp(&unsafe self.ptr[child], &unsafe self.ptr[child + 1]) < 0 {
                    child = child + 1;
                }
                if cmp(&unsafe self.ptr[r], &unsafe self.ptr[child]) >= 0 {
                    break;
                }
                self.swap(r, child);
                r = child;
                child = 2 * r + 1;
            }
        }
    }

    /// Sort in place by a derived `Ord` key (`v.sort_by_key(|p: &P| p.age)`).
    pub const fn sort_by_key<K: Ord, F: fn(&T) K>(self: &mut Vector<T, A>, key: F) {
        let n = self.len;
        if n < 2 {
            return;
        }
        let mut i: usize = 1; // insertion sort through swaps: key extraction stays borrow-only
        while i < n {
            let mut j = i;
            while j > 0 {
                let prev = key(&unsafe self.ptr[j - 1]);
                let cur = key(&unsafe self.ptr[j]);
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

/// A borrowing cursor over a Vector's elements. `for x in v.iter()` yields a borrow `&T` of each element.
pub struct VecIter<'a, T> {
    pub data: *const T,
    pub idx: usize,
    pub stop: usize,
}

extend<T, A: Allocator> Vector<T, A> {
    pub const fn iter(self: &Vector<T, A>) VecIter<T> {
        return VecIter::<T> { data: self.as_ptr(), idx: 0, stop: self.len() };
    }
}

extend<T> VecIter<T> as Iterator<&T> {
    pub const fn next(self: &mut VecIter<T>) Option<&T> {
        if self.idx >= self.stop {
            return Option::<&T>::none();
        }
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
    pub const fn index(self: &Vector<T, A>, i: usize) &T {
        if i >= self.len {
            panic("Vector<T, A>[i]: index out of bounds");
        }
        return &unsafe self.ptr[i];
    }
    pub const fn index_range(self: &Vector<T, A>, r: Range<usize>) []T {
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        if r.start > hi || hi > self.len {
            panic("Vector<T, A>[a..b]: range out of bounds");
        }
        return Slice::<T> { ptr: unsafe (self.ptr + r.start), len: hi - r.start };
    }
}

// The writable counterpart: `v[i] = x` stores through the returned element pointer (a plain `=` over a
// Free element frees the replaced value first, compiler-inserted -- same semantics as `set`);
// `index_range_mut` is an in-place writable view.
extend<T, A: Allocator> Vector<T, A> as IndexMut<T, []mut T> {
    pub const fn index_mut(self: &mut Vector<T, A>, i: usize) &mut T {
        if i >= self.len {
            panic("Vector<T, A>[i]: index out of bounds");
        }
        return &mut unsafe self.ptr[i];
    }
    pub const fn index_range_mut(self: &mut Vector<T, A>, r: Range<usize>) []mut T {
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        if r.start > hi || hi > self.len {
            panic("Vector<T, A>[a..b]: range out of bounds");
        }
        return SliceMut::<T> { ptr: unsafe (self.ptr + r.start), len: hi - r.start };
    }
}

// Conditional conformances: a Vector is Clone/Eq/Hash exactly when its element is. Each dispatches to the
// element's bound method (`e.clone()`, `a.eq(&b)`, `e.hash()`), monomorphized per element type.
extend<T: Clone, A: Allocator> Vector<T, A> as Clone {
    /// A deep copy: a fresh backing store (same allocator) whose elements are independent clones.
    pub const fn clone(self: &Vector<T, A>) Vector<T, A> {
        let mut out = Vector::<T, A>::with_capacity_in(self.alloc, self.len());
        for i in 0..self.len() {
            let e = self.at(i);
            out.push(e.clone());
        }
        return out;
    }
}

extend<T: Eq, A: Allocator> Vector<T, A> as Eq {
    pub const fn eq(self: &Vector<T, A>, other: &Vector<T, A>) bool {
        if self.len() != other.len() {
            return false;
        }
        for i in 0..self.len() {
            let a = self.at(i);
            let b = other.at(i);
            if !a.eq(b) {
                // ERROR: a[i] != b[i] does not work
                return false;
            }
        }
        return true;
    }
}

extend<T: Hash, A: Allocator> Vector<T, A> as Hash {
    /// FNV-1a over the elements' own hashes.
    pub const fn hash(self: &Vector<T, A>) u64 {
        let mut h: u64 = 0xcbf29ce484222325;
        for i in 0..self.len() {
            let e = self.at(i);
            h = (h ^ e.hash()) * 0x100000001b3;
        }
        return h;
    }
}

extend<T: Format, A: Allocator> Vector<T, A> as Format {
    /// `[e0, e1, ...]` with each element rendered through its own `fmt`.
    pub fn fmt(self: &Vector<T, A>) String {
        let mut s = String::from_str("[");
        for i in 0..self.len() {
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
