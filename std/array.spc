// Array<T, const N: usize>: a fixed-size inline array, monomorphized per (element type, length). The N
// elements live directly in the value (no heap, no allocator) and every slot always holds a valid element,
// so the length-mutating parts of Vector's API (push/pop/insert/remove/clear/...) do not exist -- everything
// length-preserving does, with the same semantics: peek accessors borrow (`at` -> `&T`, bounds-checked
// `get`/`first`/`last`/`find` -> `Option<&T>`), `set` frees the replaced element. Construct with `new()`
// (every slot `T::default()`) or `filled(&x)` (every slot a clone of `x`). Conditionally `Free`: an Array of
// a Free element type deep-frees its elements at scope exit; an Array of plain values stays a plain value.

pub struct Array<T, const N: usize> {
    data: [T; N], // the N elements, all always initialized (private)
}

extern "C" {
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
}

extend<T, const N: usize> Array<T, N> {
    pub fn len(self: &Array<T, N>) usize {
        return N;
    }

    pub fn capacity(self: &Array<T, N>) usize {
        return N;
    }

    pub fn is_empty(self: &Array<T, N>) bool {
        return N == 0;
    }

    // Unchecked element access (caller guarantees `index < N`). Borrows the element in place.
    pub fn at(self: &Array<T, N>, index: usize) &T {
        return &self.data[index];
    }

    // Bounds-checked element access -- borrows the element (`&T`) so the Array keeps sole ownership.
    pub fn get(self: &Array<T, N>, index: usize) Option<&T> {
        if index >= N {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&self.data[index]);
    }

    pub fn set(self: &mut Array<T, N>, index: usize, value: T) {
        unsafe self.data[index].free(); // free the replaced element (no-op if T isn't Free), like Vector::set
        unsafe self.data[index] = value;
    }

    pub fn first(self: &Array<T, N>) Option<&T> {
        return self.get(0);
    }

    pub fn last(self: &Array<T, N>) Option<&T> {
        if N == 0 {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&self.data[N - 1]);
    }

    pub fn as_ptr(self: &Array<T, N>) *const T {
        return (&self.data[0]) as *const T;
    }

    // Raw byte copy into the array's storage: `memcpy(&data[0], src, n)`. Caller guarantees
    // `n <= N * sizeof(T)` and that the bytes form valid `T`s; overwritten elements are NOT
    // freed (raw overwrite, unlike `set`).
    pub fn copy_from(self: &mut Array<T, N>, src: *const void, n: usize) {
        unsafe memcpy((&mut self.data[0]) as *mut void, src, n);
    }

    // Exchange the elements at `i` and `j` (both must be in range).
    pub fn swap(self: &mut Array<T, N>, i: usize, j: usize) {
        let p = (&mut self.data[0]) as *mut T;
        let tmp = unsafe p[i];
        unsafe p[i] = unsafe p[j];
        unsafe p[j] = tmp;
    }

    // Reverse the elements in place.
    pub fn reverse(self: &mut Array<T, N>) {
        if N == 0 {
            return;
        }
        let mut i: usize = 0;
        let mut j = N - 1;
        while i < j {
            self.swap(i, j);
            i = i + 1;
            j = j - 1;
        }
    }

    // A new Array with `f` applied to every element. `f` BORROWS each element (`&T`): this map reads
    // `self` and leaves it owning its elements, so it must not consume them (passing a Free element by
    // value would free the Array's still-owned copy).
    pub fn map<U, F: fn(&T) U>(self: &Array<T, N>, f: F) Array<U, N> {
        let mut out = Array::<U, N> {};
        let p = (&mut out.data[0]) as *mut U;
        for i in 0..N {
            unsafe p[i] = f(self.at(i));
        }
        return out;
    }

    // A borrow of the first element matching `pred`, or `None`. `pred` borrows (`&T`); it must not consume.
    pub fn find<F: fn(&T) bool>(self: &Array<T, N>, pred: F) Option<&T> {
        for i in 0..N {
            if pred(self.at(i)) {
                return Option::<&T>::Some(&self.data[i]);
            }
        }
        return Option::<&T>::None;
    }

    pub fn iter(self: &Array<T, N>) VecIter<T> {
        return VecIter::<T> { data: self.as_ptr(), idx: 0, stop: N };
    }
}

// Constructors. Fields are private, so these are the public way in: `new()` default-constructs every
// slot; `filled(&x)` clones `x` into every slot.
extend<T: Default, const N: usize> Array<T, N> {
    pub fn new() Array<T, N> {
        let mut a = Array::<T, N> {};
        let p = (&mut a.data[0]) as *mut T;
        for i in 0..N {
            unsafe p[i] = T::default();
        }
        return a;
    }
}

extend<T: Clone, const N: usize> Array<T, N> {
    pub fn filled(x: &T) Array<T, N> {
        let mut a = Array::<T, N> {};
        let p = (&mut a.data[0]) as *mut T;
        for i in 0..N {
            unsafe p[i] = x.clone();
        }
        return a;
    }
}

// Deep-free every element. Conditional: an Array is Free exactly when its element is, so an Array of
// plain values (i32, ...) stays a plain copyable value. Sound for the same reason as Vector: the peek
// accessors borrow (`&T`) rather than hand out sharing copies, so the Array is the only owner.
extend<T: Free, const N: usize> Array<T, N> as Free {
    pub fn free(self: &mut Array<T, N>) {
        for i in 0..N {
            unsafe self.data[i].free();
        }
    }
}

// Standard-interface conformances.
extend<T: Default, const N: usize> Array<T, N> as Default {
    pub fn default() Array<T, N> {
        return Array::<T, N>::new();
    }
}

// Equality-based algorithms (available when the element type is `Eq`).
extend<T: Eq, const N: usize> Array<T, N> {
    // True if any element equals `x` (per `Eq`); O(n) linear scan.
    pub fn contains(self: &Array<T, N>, x: &T) bool {
        for i in 0..N {
            if self.data[i] == *x {
                return true;
            }
        }
        return false;
    }

    // Index of the first element equal to `x`, or `None`.
    pub fn position(self: &Array<T, N>, x: &T) Option<usize> {
        for i in 0..N {
            if self.data[i] == *x {
                return Option::<usize>::Some(i);
            }
        }
        return Option::<usize>::None;
    }
}

// Order-based algorithms (available when the element type is `Ord`).
extend<T: Ord, const N: usize> Array<T, N> {
    // True if the elements are in non-decreasing order (per `Ord`).
    pub fn is_sorted(self: &Array<T, N>) bool {
        if N < 2 {
            return true;
        }
        let mut i: usize = 0;
        while i + 1 < N {
            if self.data[i] > self.data[i + 1] {
                return false;
            }
            i = i + 1;
        }
        return true;
    }

    // Binary search of a sorted array: `Ok(i)` where an equal element lives, or `Err(i)` the index a
    // missing element would be inserted at to keep order. Behaviour is unspecified if not sorted.
    pub fn binary_search(self: &Array<T, N>, x: &T) Result<usize, usize> {
        let mut lo: usize = 0;
        let mut hi: usize = N;
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            let c = self.data[mid].cmp(x);
            if c == 0 {
                return Result::<usize, usize>::Ok(mid);
            }
            if c < 0 {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return Result::<usize, usize>::Err(lo);
    }

    // Restore the max-heap property at `root` over the prefix `[0, end)` by sifting it down.
    fn sift_down(self: &mut Array<T, N>, root: usize, end: usize) {
        let mut r = root;
        let mut child = 2 * r + 1;
        while child < end {
            if child + 1 < end && self.data[child] < self.data[child + 1] {
                child = child + 1;
            }
            if self.data[r] >= self.data[child] {
                return;
            }
            self.swap(r, child);
            r = child;
            child = 2 * r + 1;
        }
    }

    // Sort the elements in place into non-decreasing order (heapsort: O(n log n), no allocation).
    pub fn sort(self: &mut Array<T, N>) {
        if N < 2 {
            return;
        }
        let mut start = N / 2;
        while start > 0 {
            start = start - 1;
            self.sift_down(start, N);
        }
        let mut end = N;
        while end > 1 {
            end = end - 1;
            self.swap(0, end);
            self.sift_down(0, end);
        }
    }
}

// Comparator-driven sorting (no `Ord` required: the closure decides the order).
extend<T, const N: usize> Array<T, N> {
    // Sort in place by a comparator returning negative / zero / positive (heapsort: O(n log n)).
    // The sift is inlined for the same reason as Vector::sort_by: a generic method calling another
    // generic method with its own F is not transitively instantiated yet.
    pub fn sort_by<F: fn(&T, &T) i32>(self: &mut Array<T, N>, cmp: F) {
        if N < 2 {
            return;
        }
        let mut phase: usize = 0; // 0: heapify roots N/2-1..0; 1: pop the max to the end, re-sift
        let mut start = N / 2;
        let mut end = N;
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
            let mut lim = N;
            if phase == 1 {
                lim = end;
            }
            let mut child = 2 * r + 1;
            while child < lim {
                if child + 1 < lim && cmp(&self.data[child], &self.data[child + 1]) < 0 {
                    child = child + 1;
                }
                if cmp(&self.data[r], &self.data[child]) >= 0 {
                    break;
                }
                self.swap(r, child);
                r = child;
                child = 2 * r + 1;
            }
        }
    }

    // Sort in place by a derived `Ord` key (`a.sort_by_key(|p: &P| p.age)`).
    pub fn sort_by_key<K: Ord, F: fn(&T) K>(self: &mut Array<T, N>, key: F) {
        if N < 2 {
            return;
        }
        let mut i: usize = 1; // insertion sort through swaps: key extraction stays borrow-only
        while i < N {
            let mut j = i;
            while j > 0 {
                let prev = key(&self.data[j - 1]);
                let cur = key(&self.data[j]);
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

// Index conformances: `a[i]` borrows the element in place (unchecked, like `at`), and `a[lo..hi]` -- any
// range form, `..=` including the end, an open end meaning `N` -- is a borrowed `[]T` view of the
// elements. Views alias the inline buffer, so they are invalidated when the Array is moved.
extend<T, const N: usize> Array<T, N> as Index<T, []T> {
    pub fn index(self: &Array<T, N>, i: usize) &T {
        if i >= N {
            panic("Array<T, N>[i]: index out of bounds");
        }
        return &self.data[i];
    }
    pub fn index_range(self: &Array<T, N>, r: Range<usize>) []T {
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        if r.start > hi || hi > N {
            panic("Array<T, N>[a..b]: range out of bounds");
        }
        return Slice::<T> { ptr: unsafe (self.as_ptr() + r.start), len: hi - r.start };
    }
}

// The writable counterpart: `a[i] = x` stores through the returned element pointer (a plain `=` over a
// Free element frees the replaced value first, compiler-inserted -- same semantics as `set`);
// `index_range_mut` is an in-place writable view.
extend<T, const N: usize> Array<T, N> as IndexMut<T, []mut T> {
    pub fn index_mut(self: &mut Array<T, N>, i: usize) &mut T {
        if i >= N {
            panic("Array<T, N>[i]: index out of bounds");
        }
        return &mut self.data[i];
    }
    pub fn index_range_mut(self: &mut Array<T, N>, r: Range<usize>) []mut T {
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        let p = (&mut self.data[0]) as *mut T;
        if r.start > hi || hi > N {
            panic("Array<T, N>[a..b]: range out of bounds");
        }
        return SliceMut::<T> { ptr: unsafe (p + r.start), len: hi - r.start };
    }
}

// Conditional conformances: an Array is Clone/Eq/Hash exactly when its element is. Each dispatches to
// the element's bound method (`e.clone()`, `a.eq(&b)`, `e.hash()`), monomorphized per element type.
extend<T: Clone, const N: usize> Array<T, N> as Clone {
    // A deep copy whose elements are independent clones.
    pub fn clone(self: &Array<T, N>) Array<T, N> {
        let mut out = Array::<T, N> {};
        let p = (&mut out.data[0]) as *mut T;
        for i in 0..N {
            let e = self.at(i);
            unsafe p[i] = e.clone();
        }
        return out;
    }
}

extend<T: Eq, const N: usize> Array<T, N> as Eq {
    pub fn eq(self: &Array<T, N>, other: &Array<T, N>) bool {
        for i in 0..N {
            let a = self.at(i);
            let b = other.at(i);
            if *a != *b {
                return false;
            }
        }
        return true;
    }
}

extend<T: Hash, const N: usize> Array<T, N> as Hash {
    // FNV-1a over the elements' own hashes.
    pub fn hash(self: &Array<T, N>) u64 {
        let mut h: u64 = 0xcbf29ce484222325;
        for i in 0..N {
            let e = self.at(i);
            h = (h ^ e.hash()) * 0x100000001b3;
        }
        return h;
    }
}

extend<T: Format, const N: usize> Array<T, N> as Format {
    // `[e0, e1, ...]` with each element rendered through its own `fmt`.
    pub fn fmt(self: &Array<T, N>) String {
        let mut s = String::from_str("[");
        for i in 0..N {
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
