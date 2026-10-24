// Array<T, const N: usize>: a fixed-size inline array, monomorphized per (element type, length). The N
// elements live directly in the value (no heap, no allocator) and every slot always holds a valid element,
// so the length-mutating parts of Vector's API (push/pop/insert/remove/clear/...) do not exist: everything
// length-preserving does, with the same semantics: peek accessors borrow (`at` -> `&T`, bounds-checked
// `get`/`first`/`last`/`find` -> `Option<&T>`), `set` frees the replaced element. Construct with `new()`
// (every slot `T::default()`) or `filled(&x)` (every slot a clone of `x`). Conditionally `Free`: an Array of
// a Free element type deep-frees its elements at scope exit; an Array of plain values stays a plain value.
//
// Complexity: every access is O(1); swap is O(1); reverse, map, find and the sequence algorithms of
// `as_mut_slice()` keep the bounds std/slice.spc states. The storage never moves while the Array does not,
// so a borrow ends only when the Array is moved or mutated; iteration is in index order. No allocation; an
// Array is Send / Sync when its elements are.

/// A fixed-size inline array of N elements, always fully initialized. A distinct type from the builtin `[T; N]`.
pub struct Array<T, const N: usize> {
    data: [T; N], // the N elements, all always initialized (private)
}

// Zero is a valid array where it is a valid element: the zero-fill check reads `T` itself.
unsafe extend<T, const N: usize> Array<T, N> as Zeroable {}

extern "C" {
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
}

extend<T, const N: usize> Array<T, N> {
    /// Always N.
    pub const fn len(self: &Array<T, N>) usize {
        return N;
    }

    /// Always N.
    pub const fn capacity(self: &Array<T, N>) usize {
        return N;
    }

    /// True iff N is 0.
    pub const fn is_empty(self: &Array<T, N>) bool {
        return N == 0;
    }

    /// Bounds-checked element access: panics when `index >= N`. Borrows the element in place.
    pub const fn at(self: &Array<T, N>, index: usize) &T {
        if index >= N {
            panic("Array::at: index out of bounds");
        }
        return &unsafe self.data[index];
    }

    /// Unchecked element access: the caller PROVES `index < N` (hot loops with an established
    /// bound). Out of range is undefined behavior, hence `unsafe`.
    pub unsafe const fn get_unsafe(self: &Array<T, N>, index: usize) &T {
        return &self.data[index];
    }

    /// Bounds-checked element access: borrows the element (`&T`) so the Array keeps sole ownership.
    pub const fn get(self: &Array<T, N>, index: usize) Option<&T> {
        if index >= N {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&unsafe self.data[index]);
    }

    /// Panics when `index >= N`. Frees the replaced element, then takes ownership of `value`.
    pub const fn set(self: &mut Array<T, N>, index: usize, value: T) {
        if index >= N {
            panic("Array::set: index out of bounds");
        }
        unsafe self.data[index] = value;
    }

    /// The first element, None for an empty array.
    pub const fn first(self: &Array<T, N>) Option<&T> {
        return self.get(0);
    }

    /// The last element, None for an empty array.
    pub const fn last(self: &Array<T, N>) Option<&T> {
        if N == 0 {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&unsafe self.data[N - 1]);
    }

    /// Raw pointer to the inline elements; invalidated when the Array is moved.
    pub const fn as_ptr(self: &Array<T, N>) *const T {
        return &unsafe self.data[0];
    }

    /// A shared view of every element.
    pub const fn as_slice(self: &Array<T, N>) []T {
        return unsafe Slice::<T> { ptr: self.as_ptr(), len: N };
    }

    /// A writable view of every element: the shared slice algorithms run on it.
    pub const fn as_mut_slice(self: &mut Array<T, N>) []mut T {
        return unsafe SliceMut::<T> { ptr: &mut self.data[0], len: N };
    }

    /// Raw byte copy into the array's storage: `memcpy(&data[0], src, n)`. Unsafe: the caller
    /// promises `n` readable bytes at `src`, `n <= N * sizeof(T)`, and that the bytes form valid `T`s;
    /// overwritten elements are NOT freed (raw overwrite, unlike `set`).
    pub unsafe const fn copy_from(self: &mut Array<T, N>, src: *const void, n: usize) {
        memcpy(&mut self.data[0], src, n);
    }

    /// Exchange the elements at `i` and `j`: panics when either is out of range.
    pub const fn swap(self: &mut Array<T, N>, i: usize, j: usize) {
        if i >= N || j >= N {
            panic("Array::swap: index out of bounds");
        }
        let p = (&mut unsafe self.data[0]) as *mut T;
        let tmp = unsafe p[i];
        unsafe p[i] = unsafe p[j];
        unsafe p[j] = tmp;
    }

    /// Reverse the elements in place.
    pub const fn reverse(self: &mut Array<T, N>) {
        self.as_mut_slice().reverse();
    }

    /// A new Array with `f` applied to every element. `f` BORROWS each element (`&T`): this map reads
    /// `self` and leaves it owning its elements, so it must not consume them (passing a Free element by
    /// value would free the Array's still-owned copy).
    pub const fn map<U, F: fn(&T) U>(self: &Array<T, N>, f: F) Array<U, N> {
        let mut out = unsafe zeroed::<Array<U, N>>(); // every slot is written below before a read
        let p = (&mut unsafe out.data[0]) as *mut U;
        for i in 0..N {
            unsafe p[i] = f(self.at(i));
        }
        return out;
    }

    /// A borrow of the first element matching `pred`, or `None`. `pred` borrows (`&T`); it must not consume.
    pub const fn find<F: fn(&T) bool>(self: &Array<T, N>, pred: F) Option<&T> {
        for i in 0..N {
            if pred(self.at(i)) {
                return Option::<&T>::Some(&unsafe self.data[i]);
            }
        }
        return Option::<&T>::None;
    }

    /// A by-reference iterator over the elements in order.
    pub const fn iter(self: &Array<T, N>) VecIter<T> {
        return VecIter::<T> { data: self.as_ptr(), idx: 0, stop: N };
    }
}

// Constructors. Fields are private, so these are the public way in: `new()` default-constructs every
// slot; `filled(&x)` clones `x` into every slot.
extend<T: Default, const N: usize> Array<T, N> {
    /// An array of N default values.
    pub const fn new() Array<T, N> {
        let mut a = unsafe zeroed::<Array<T, N>>(); // every slot is written below before a read
        let p = (&mut unsafe a.data[0]) as *mut T;
        for i in 0..N {
            unsafe p[i] = T::default();
        }
        return a;
    }
}

extend<T: Clone, const N: usize> Array<T, N> {
    /// An array of N clones of `x`.
    pub const fn filled(x: &T) Array<T, N> {
        let mut a = unsafe zeroed::<Array<T, N>>(); // every slot is written below before a read
        let p = (&mut unsafe a.data[0]) as *mut T;
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
    pub const fn default() Array<T, N> {
        return Array::<T, N>::new();
    }
}

// Equality-based algorithms (available when the element type is `Eq`).
extend<T: Eq, const N: usize> Array<T, N> {
    /// True if any element equals `x` (per `Eq`); O(n) linear scan.
    pub const fn contains(self: &Array<T, N>, x: &T) bool {
        for i in 0..N {
            if unsafe self.data[i] == *x {
                return true;
            }
        }
        return false;
    }

    /// Index of the first element equal to `x`, or `None`.
    pub const fn position(self: &Array<T, N>, x: &T) Option<usize> {
        for i in 0..N {
            if unsafe self.data[i] == *x {
                return Option::<usize>::Some(i);
            }
        }
        return Option::<usize>::None;
    }
}

// Order-based algorithms: the shared slice algorithms (std/slice.spc) over the elements.
extend<T: Ord, const N: usize> Array<T, N> {
    /// True if the elements are in non-decreasing order (per `Ord`).
    pub const fn is_sorted(self: &Array<T, N>) bool {
        return self.as_slice().is_sorted();
    }

    /// Binary search of a sorted array: `Ok(i)` where an equal element lives (any one of several), or
    /// `Err(i)`, the index a missing element would be inserted at to keep order. O(log n); unspecified
    /// result if not sorted.
    pub const fn binary_search(self: &Array<T, N>, x: &T) Result<usize, usize> {
        return self.as_slice().binary_search(x);
    }

    /// Sort in place into non-decreasing order, unstable (pattern-defeating quicksort: O(n log n) worst
    /// case, no allocation).
    pub const fn sort(self: &mut Array<T, N>) {
        self.as_mut_slice().sort();
    }

    /// Sort in place into non-decreasing order, stable, with no allocation: O(n log n) comparisons and
    /// O(n log^2 n) moves (`SliceMut::sort_stable_in_place`).
    pub fn sort_stable_in_place(self: &mut Array<T, N>) {
        self.as_mut_slice().sort_stable_in_place();
    }
}

// Comparator-driven sorting (no `Ord` required: the closure decides the order).
extend<T, const N: usize> Array<T, N> {
    /// Sort in place by a comparator returning negative / zero / positive, unstable. O(n log n).
    pub const fn sort_by<F: fn(&T, &T) i32>(self: &mut Array<T, N>, cmp: F) {
        self.as_mut_slice().sort_by(cmp);
    }

    /// Stable `sort_by` with no allocation (`SliceMut::sort_stable_in_place_by`).
    pub fn sort_stable_in_place_by<F: fn(&T, &T) i32>(self: &mut Array<T, N>, cmp: F) {
        self.as_mut_slice().sort_stable_in_place_by(cmp);
    }

    /// Sort in place by a derived `Ord` key, unstable. O(n log n); the key is computed twice per
    /// comparison.
    pub const fn sort_by_key<K: Ord, F: fn(&T) K>(self: &mut Array<T, N>, key: F) {
        self.as_mut_slice().sort_by_key::<K, F>(key);
    }
}

// Index conformances: `a[i]` borrows the element in place (bounds-checked like `at`), and `a[lo..hi]`; any
// range form, `..=` including the end, an open end meaning `N`: is a borrowed `[]T` view of the
// elements. Views alias the inline buffer, so they are invalidated when the Array is moved.
extend<T, const N: usize> Array<T, N> as Index<T, []T> {
    pub const fn index(self: &Array<T, N>, i: usize) &T {
        if i >= N {
            panic_parts("Array<T, N>", "[i]: index out of bounds");
        }
        return &unsafe self.data[i];
    }
    pub const fn index_range(self: &Array<T, N>, r: Range<usize>) []T {
        if r.inclusive && r.end >= N {
            panic_parts("Array<T, N>", "[a..b]: range out of bounds");
        }
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        if r.start > hi || hi > N {
            panic_parts("Array<T, N>", "[a..b]: range out of bounds");
        }
        return unsafe Slice::<T> { ptr: self.as_ptr() + r.start, len: hi - r.start };
    }
}

// The writable counterpart: `a[i] = x` stores through the returned element pointer (a plain `=` over a
// Free element frees the replaced value first, compiler-inserted: same semantics as `set`);
// `index_range_mut` is an in-place writable view.
extend<T, const N: usize> Array<T, N> as IndexMut<T, []mut T> {
    pub const fn index_mut(self: &mut Array<T, N>, i: usize) &mut T {
        if i >= N {
            panic_parts("Array<T, N>", "[i]: index out of bounds");
        }
        return &mut unsafe self.data[i];
    }
    pub const fn index_range_mut(self: &mut Array<T, N>, r: Range<usize>) []mut T {
        if r.inclusive && r.end >= N {
            panic_parts("Array<T, N>", "[a..b]: range out of bounds");
        }
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        let p = (&mut unsafe self.data[0]) as *mut T;
        if r.start > hi || hi > N {
            panic_parts("Array<T, N>", "[a..b]: range out of bounds");
        }
        return unsafe SliceMut::<T> { ptr: p + r.start, len: hi - r.start };
    }
}

// Conditional conformances: an Array is Clone/Eq/Hash exactly when its element is. Each dispatches to
// the element's bound method (`e.clone()`, `a.eq(&b)`, `e.hash_into(h)`), monomorphized per element type.
extend<T: Clone, const N: usize> Array<T, N> as Clone {
    /// A deep copy whose elements are independent clones.
    pub const fn clone(self: &Array<T, N>) Array<T, N> {
        let mut out = unsafe zeroed::<Array<T, N>>(); // every slot is written below before a read
        let p = (&mut unsafe out.data[0]) as *mut T;
        for i in 0..N {
            let e = self.at(i);
            unsafe p[i] = e.clone();
        }
        return out;
    }
}

extend<T: Eq, const N: usize> Array<T, N> as Eq {
    pub const fn eq(self: &Array<T, N>, other: &Array<T, N>) bool {
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
    /// The length, then every element through its own `hash_into`: equal sequences feed equal streams.
    pub fn hash_into<H: Hasher>(self: &Array<T, N>, h: &mut H) {
        h.write_u64(self.len() as u64);
        for i in 0..self.len() {
            self.at(i).hash_into(h);
        }
    }
}

extend<T: Format, const N: usize> Array<T, N> as Format {
    /// `[e0, e1, ...]` with each element rendered through its own `fmt`.
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
