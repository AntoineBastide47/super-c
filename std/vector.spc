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
        self.ptr[self.len] = value;
        self.len = self.len + 1;
    }

    pub fn pop(self: &mut Vector<T, A>) Option<T> {
        if self.len == 0 {
            return Option::<T>::None;
        }
        self.len = self.len - 1;
        return Option::<T>::Some(self.ptr[self.len]);
    }

    // Unchecked element access (caller guarantees `index < len`). Borrows the element in place.
    pub fn at(self: &Vector<T, A>, index: usize) &T {
        return &self.ptr[index];
    }

    // Bounds-checked element access -- borrows the element (`&T`) so the Vector keeps sole ownership.
    pub fn get(self: &Vector<T, A>, index: usize) Option<&T> {
        if index >= self.len {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&self.ptr[index]);
    }

    pub fn set(self: &mut Vector<T, A>, index: usize, value: T) {
        self.ptr[index] = value;
    }

    pub fn first(self: &Vector<T, A>) Option<&T> {
        return self.get(0);
    }

    pub fn last(self: &Vector<T, A>) Option<&T> {
        if self.len == 0 {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&self.ptr[self.len - 1]);
    }

    pub fn clear(self: &mut Vector<T, A>) {
        let mut i: usize = 0;
        while i < self.len {
            self.ptr[i].free();
            i = i + 1;
        }
        self.len = 0;
    }

    pub fn truncate(self: &mut Vector<T, A>, new_len: usize) {
        if new_len < self.len {
            let mut i = new_len;
            while i < self.len {
                self.ptr[i].free();
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
            self.ptr[i] = self.ptr[i - 1];
            i = i - 1;
        }
        self.ptr[index] = value;
        self.len = self.len + 1;
    }

    // Remove and return the element at `index`, shifting later elements left (`None` if out of range).
    pub fn remove(self: &mut Vector<T, A>, index: usize) Option<T> {
        if index >= self.len {
            return Option::<T>::None;
        }
        let removed = self.ptr[index];
        let mut i = index;
        while i + 1 < self.len {
            self.ptr[i] = self.ptr[i + 1];
            i = i + 1;
        }
        self.len = self.len - 1;
        return Option::<T>::Some(removed);
    }

    // Exchange the elements at `i` and `j` (both must be in range).
    pub fn swap(self: &mut Vector<T, A>, i: usize, j: usize) {
        let tmp = self.ptr[i];
        self.ptr[i] = self.ptr[j];
        self.ptr[j] = tmp;
    }

    // Remove the element at `index` by swapping in the last one (O(1), reorders; `None` if out of range).
    pub fn swap_remove(self: &mut Vector<T, A>, index: usize) Option<T> {
        if index >= self.len {
            return Option::<T>::None;
        }
        let removed = self.ptr[index];
        self.len = self.len - 1;
        self.ptr[index] = self.ptr[self.len];
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
            let tmp = self.ptr[i];
            self.ptr[i] = self.ptr[j];
            self.ptr[j] = tmp;
            i = i + 1;
            j = j - 1;
        }
    }

    // A new vector (same allocator) with `f` applied to every element.
    pub fn map<U>(self: &Vector<T, A>, f: fn(T) U) Vector<U, A> {
        let mut out = Vector::<U, A>::with_capacity_in(self.alloc, self.len);
        let mut i: usize = 0;
        while i < self.len {
            out.push(f(self.ptr[i]));
            i = i + 1;
        }
        return out;
    }

    // A borrow of the first element matching `pred`, or `None`.
    pub fn find(self: &Vector<T, A>, pred: fn(T) bool) Option<&T> {
        let mut i: usize = 0;
        while i < self.len {
            if pred(self.ptr[i]) {
                return Option::<&T>::Some(&self.ptr[i]);
            }
            i = i + 1;
        }
        return Option::<&T>::None;
    }

    // Keep only the elements matching `pred` (in place, preserving order).
    pub fn retain(self: &mut Vector<T, A>, pred: fn(T) bool) {
        let mut w: usize = 0;
        let mut i: usize = 0;
        while i < self.len {
            if pred(self.ptr[i]) {
                self.ptr[w] = self.ptr[i];
                w = w + 1;
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
            self.ptr[i].free(); // free the element (no-op if T isn't Free)
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
        let r = &self.data[self.idx];
        self.idx = self.idx + 1;
        return Option::<&T>::some(r);
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
