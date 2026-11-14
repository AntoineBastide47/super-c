// Vector<T, A = Global>: a growable, heap-backed contiguous array, monomorphized per (element type,
// allocator). The backing store is sized in bytes with `sizeof(T)`, aligned with `alignof(T)`, and obtained
// through allocator `A` (stored in the vector; zero bytes when it is the zero-sized `Global`). Peek accessors
// borrow the element (`at` -> `&T`, bounds-checked `get`/`first`/`last`/`find` -> `Option<&T>`); `set`
// panics out of range and frees the replaced element. Auto-`Free` (deep-frees every element and the buffer
// at scope exit). `new()`/`with_capacity()` use a default-constructed allocator; pass a stateful arena/pool with
// `new_in`/`with_capacity_in`, or pick a non-default zero-sized allocator with a turbofish:
// `Vector::<T, MyAlloc>::new()`.
//
// Complexity: push is amortized O(1) (the capacity doubles, so n pushes move O(n) elements); pop, at, get,
// set, swap and swap_remove are O(1); insert and remove are O(n - index); truncate, clear and retain are
// O(n). The sequence algorithms run on `as_mut_slice()` (std/slice.spc states their bounds). Invalidation:
// any growth (push, insert, reserve) may move the buffer, so it ends every element borrow, view and
// iterator, which the borrow checker enforces; raw pointers from `as_ptr` are not tracked. Iteration is in
// index order, double-ended, with an exact size. Thread safety: no internal synchronization; a Vector is
// Send / Sync when its elements and allocator are.

import std::spec::seq as *;

/// A growable heap array of T through allocator A; capacity grows geometrically, elements are freed
/// with the vector.
pub struct Vector<T, A = Global>
    invariant self.len <= self.cap && block(self.ptr).len() == self.cap as int && self.cap as int <= Vector::<T, A>::max_len() && (sizeof(T) != 0 || self.cap == 0 || self.cap == usize::MAX)
{
    @owned
    ptr: *mut T, // owned storage; null while cap == 0 (private)
    len: usize, // elements in use (private)
    cap: usize, // elements allocated (private)
    alloc: A, // the allocator the buffer was obtained through (private; zero-sized for Global)
}

// A Vector owns its elements, so it is Send / Sync when its elements and allocator are (the owned buffer
// pointer would otherwise make it structurally neither).
unsafe extend<T, A> Vector<T, A> as Zeroable {}
unsafe extend<T: Send, A: Send> Vector<T, A> as Send {}

unsafe extend<T: Sync, A: Sync> Vector<T, A> as Sync {}

extend<T, A> Vector<T, A> {
    /// The most elements a vector holds: as many as keep its block's byte size at most `isize::MAX`,
    /// `usize::MAX` zero-sized ones.
    pub spec fn max_len() int {
        return if sizeof(T) == 0 {
            usize::MAX as int
        } else {
            (isize::MAX as usize / sizeof(T)) as int
        };
    }
}

extend<T, A: Allocator> Vector<T, A> {
    /// Its elements in order: `v[i]` is `v.view()[i]`, `v.len()` its length.
    pub spec fn view(self: &Vector<T, A>) Seq<T> {
        return block(self.ptr).take(self.len as int);
    }

    /// Empty vector backed by an explicit allocator value (a stateful arena/pool handle, or a zero-sized tag).
    pub const fn new_in(alloc: A) Vector<T, A>
        ensures |r| r.view() == Seq::<T>::empty()
    {
        return Vector::<T, A> { ptr: null, len: 0, cap: 0, alloc: alloc };
    }

    /// Pre-allocates room for `cap` elements through an explicit allocator (no allocation when cap == 0).
    pub const fn with_capacity_in(alloc: A, cap: usize) Vector<T, A>
        panics if cap as int > Vector::<T, A>::max_len()
        ensures |r| r.view() == Seq::<T>::empty()
    {
        let mut v = Vector::<T, A> { ptr: null, len: 0, cap: 0, alloc: alloc };
        if sizeof(T) == 0 {
            // Zero-sized elements occupy no bytes: an aligned sentinel and unbounded logical
            // capacity, with no allocator call (the branch folds away per instantiation).
            v.ptr = dangling::<T>();
            v.cap = ~(0 as usize);
            return v;
        }
        if cap > 0 {
            if cap > isize::MAX as usize / sizeof(T) {
                panic("Vector: capacity overflow");
            }
            v.ptr = (unsafe v.alloc.alloc(cap * sizeof(T), alignof(T))) as *mut T;
            v.cap = cap;
        }
        return v;
    }

    /// Number of elements.
    pub const fn len(self: &Vector<T, A>) usize
        ensures |r| r as int == self.view().len()
    {
        return self.len;
    }

    /// Elements the current allocation can hold without growing.
    pub const fn capacity(self: &Vector<T, A>) usize
        ensures |r| r as int >= self.view().len()
    {
        return self.cap;
    }

    /// True when no element is stored.
    pub const fn is_empty(self: &Vector<T, A>) bool
        ensures |r| r == (self.view().len() == 0)
    {
        return self.len == 0;
    }

    /// Guarantees room for `additional` more elements, growing by doubling (amortised O(1) append).
    pub const fn reserve(self: &mut Vector<T, A>, additional: usize)
        panics if self.view().len() + additional as int > Vector::<T, A>::max_len()
        ensures self.view() == old(self.view())
        ensures self.len == old(self.len) && self.cap as int >= self.len as int + additional as int
    {
        if sizeof(T) == 0 {
            assert(additional <= ~(0 as usize) - self.len, "Vector<ZST> length overflow");
            if self.cap == 0 {
                self.ptr = dangling::<T>();
                self.cap = ~(0 as usize);
            }
            return;
        }
        // `cap - len` cannot wrap, where `len + additional` could. The growth stays out of line where the
        // capacity is unknown (a rare block takes no copy bigger than its call).
        if unlikely(additional > self.cap - self.len) {
            self.grow_for(additional);
        }
    }

    // The growth path of `reserve`.
    const fn grow_for(self: &mut Vector<T, A>, additional: usize)
        requires sizeof(T) != 0 && additional as int > self.cap as int - self.len as int
        panics if self.len as int + additional as int > Vector::<T, A>::max_len()
        ensures self.view() == old(self.view())
        ensures self.len == old(self.len) && self.cap as int >= self.len as int + additional as int
    {
        // The most elements whose byte size fits an isize.
        let max_cap = isize::MAX as usize / sizeof(T);
        if additional > max_cap - self.len {
            panic("Vector: capacity overflow");
        }
        let needed = self.len + additional;
        let mut new_cap = max_cap;
        if self.cap <= max_cap / 2 {
            new_cap = self.cap * 2;
        }
        if new_cap == 0 {
            new_cap = if max_cap < 8 {
                max_cap
            } else {
                8
            };
        }
        if new_cap < needed {
            new_cap = needed;
        }
        self.grow_to(new_cap);
    }

    /// Like `reserve`, but grow to exactly `len + additional` elements (no doubling slack).
    pub const fn reserve_exact(self: &mut Vector<T, A>, additional: usize)
        panics if self.view().len() + additional as int > Vector::<T, A>::max_len()
        ensures self.view() == old(self.view())
    {
        if sizeof(T) == 0 || additional <= self.cap - self.len {
            self.reserve(additional);
            return;
        }
        if additional > isize::MAX as usize / sizeof(T) - self.len {
            panic("Vector: capacity overflow");
        }
        self.grow_to(self.len + additional);
    }

    // Reallocate to `new_cap` elements, at least the length (nonzero-sized `T`).
    const fn grow_to(self: &mut Vector<T, A>, new_cap: usize)
        requires sizeof(T) != 0 && new_cap > self.cap && new_cap as int <= Vector::<T, A>::max_len()
        ensures self.view() == old(self.view())
        ensures self.len == old(self.len) && self.cap == new_cap
    {
        let p = (unsafe self.alloc.realloc(self.ptr, self.cap * sizeof(T), new_cap * sizeof(T), alignof(T))) as *mut T;
        self.ptr = p;
        self.cap = new_cap;
    }

    /// Appends `value`, taking ownership of it; amortised O(1).
    pub const fn push(self: &mut Vector<T, A>, value: T)
        panics if self.view().len() + 1 > Vector::<T, A>::max_len()
        ensures self.view() == old(self.view()).push(value)
    {
        // Only a full vector grows (a zero-sized `T`'s first push sets the capacity to the maximum, so
        // `reserve` then sees only the length overflow). The growth keeps the length: read once.
        let n = self.len;
        if unlikely(n == self.cap) {
            self.reserve(1);
        }
        ghost let v0 = old(self.view());
        ghost let b1 = block(self.ptr);
        unsafe self.ptr[n] = value;
        self.len = n + 1;
        push_view(v0, b1, n as int, self.len as int, value);
    }

    /// Removes and returns the last element, moving ownership to the caller (`None` when empty).
    pub const fn pop(self: &mut Vector<T, A>) Option<T>
        ensures |r| old(self.view()).len() == 0 ==> r == Option::<T>::None
        ensures |r| old(self.view()).len() > 0 ==> r == Some(old(self.view())[old(self.view()).len() - 1])
        ensures old(self.view()).len() == 0 ==> self.view() == old(self.view())
        ensures old(self.view()).len() > 0 ==> self.view() == old(self.view()).take(old(self.view()).len() - 1)
    {
        if self.len == 0 {
            return None;
        }
        take_take(block(self.ptr), self.len as int, self.len as int - 1);
        self.len = self.len - 1;
        return Some(unsafe self.ptr[self.len]);
    }

    /// Bounds-checked element access: panics when `index >= len`. Borrows the element in place.
    pub const fn at(self: &Vector<T, A>, index: usize) &T
        panics if index as int >= self.view().len()
    {
        if index >= self.len {
            panic("Vector::at: index out of bounds");
        }
        return &unsafe self.ptr[index];
    }

    /// Unchecked element access: the caller PROVES `index < len` (hot loops with an established
    /// bound). Out of range is undefined behavior, hence `unsafe`.
    pub unsafe const fn get_unsafe(self: &Vector<T, A>, index: usize) &T {
        return &self.ptr[index];
    }

    /// Bounds-checked element access: borrows the element (`&T`) so the Vector keeps sole ownership.
    pub const fn get(self: &Vector<T, A>, index: usize) Option<&T> {
        if index >= self.len {
            return None;
        }
        return Some(&unsafe self.ptr[index]);
    }

    /// Panics when `index >= len`. Takes ownership of `value`, then frees the replaced element.
    pub const fn set(self: &mut Vector<T, A>, index: usize, value: T)
        panics if index as int >= self.view().len()
        ensures self.view() == old(self.view()).update(index as int, value)
    {
        if index >= self.len {
            panic("Vector::set: index out of bounds");
        }
        // The vector owns `value` before the old element's `free` runs, which may panic.
        let _replaced = unsafe self.ptr[index];
        unsafe self.ptr[index] = value;
    }

    /// The first element, None when empty.
    pub const fn first(self: &Vector<T, A>) Option<&T> {
        return self.get(0);
    }

    /// The last element, None when empty.
    pub const fn last(self: &Vector<T, A>) Option<&T> {
        if self.len == 0 {
            return None;
        }
        return Some(&unsafe self.ptr[self.len - 1]);
    }

    /// Frees every element; keeps the buffer for reuse (capacity unchanged).
    pub const fn clear(self: &mut Vector<T, A>)
        ensures self.view() == Seq::<T>::empty()
    {
        // The vector stops owning the elements before their `free` runs: one that panics leaks the
        // rest instead of leaving freed elements in the vector.
        let n = self.len;
        self.len = 0;
        for i in 0..n
            invariant self.invariant() && self.len == 0
        {
            unsafe self.ptr[i].free();
        }
    }

    /// Shortens to `new_len` elements, freeing the dropped tail (no-op when already shorter).
    pub const fn truncate(self: &mut Vector<T, A>, new_len: usize)
        ensures new_len as int >= old(self.view()).len() ==> self.view() == old(self.view())
        ensures new_len as int < old(self.view()).len() ==> self.view() == old(self.view()).take(new_len as int)
    {
        // One store, no branch around it, before any `free` runs: the vector stops owning the tail first
        // (`clear`), and keeps its length when already shorter.
        let n = self.len;
        ghost let b0 = block(self.ptr);
        self.len = new_len.min(n);
        if new_len < n {
            take_take(b0, n as int, new_len as int);
            let mut i = new_len;
            while i < n
                invariant self.invariant() && self.len == new_len && new_len <= i && i <= n
                invariant block(self.ptr).take(new_len as int) == b0.take(new_len as int)
            {
                ghost let bi = block(self.ptr);
                unsafe self.ptr[i].free();
                upd_take_out(bi, new_len as int, i as int, block(self.ptr)[i as int]);
                i = i + 1;
            }
        }
    }

    /// Raw pointer to the buffer; invalidated by any reallocating mutation (push/reserve/insert).
    pub const fn as_ptr(self: &Vector<T, A>) *const T {
        return self.ptr;
    }

    /// Raw mutable pointer to the buffer, from the exclusive borrow (`as_ptr`'s never writes); invalidated
    /// as `as_ptr`'s.
    pub const fn as_mut_ptr(self: &mut Vector<T, A>) *mut T {
        return self.ptr;
    }

    /// Insert `value` at `index`, shifting later elements right. Panics when `index > len`.
    pub const fn insert(self: &mut Vector<T, A>, index: usize, value: T)
        panics if index as int > self.view().len() || self.view().len() + 1 > Vector::<T, A>::max_len()
        ensures self.view() == old(self.view()).take(index as int).push(value).concat(
            old(self.view()).subrange(index as int, old(self.view()).len()),
        )
    {
        if index > self.len {
            panic("Vector::insert: index out of bounds");
        }
        self.reserve(1);
        let n = self.len;
        ghost let b0 = block(self.ptr);
        self.shift_right(index);
        ghost let bf = block(self.ptr);
        unsafe self.ptr[index] = value;
        self.len = n + 1;
        // The view: the first `index`, `value`, then the rest, as before the loop.
        take_split(block(self.ptr), index as int, n as int);
        upd_take_out(bf, index as int, index as int, value);
        take_take(b0, n as int, index as int);
        upd_sub_out(bf, index as int, index as int + 1, n as int + 1, value);
        take_sub(b0, n as int, index as int, n as int);
    }

    // Move the elements from `index` on one place right, into the room `reserve` made: the first `index`
    // stay, and the old element `j` is element `j + 1` from `index` to the length.
    const fn shift_right(self: &mut Vector<T, A>, index: usize)
        requires index <= self.len && self.len < self.cap
        ensures self.len == old(self.len) && self.cap == old(self.cap) && block(self.ptr).len() == old(block(self.ptr)).len()
        ensures block(self.ptr).take(index as int) == old(block(self.ptr)).take(index as int)
        ensures block(self.ptr).subrange(index as int + 1, self.len as int + 1) == old(block(self.ptr)).subrange(
            index as int,
            self.len as int,
        )
    {
        let n = self.len;
        ghost let b0 = block(self.ptr);
        assert n as int + 1 <= b0.len() by {};
        let mut i = n;
        while i > index
            invariant self.invariant() && self.len == n && index <= i && i <= n && n < self.cap && block(self.ptr).len() == b0.len()
            invariant block(self.ptr).take(i as int) == b0.take(i as int)
            invariant block(self.ptr).subrange(i as int + 1, n as int + 1) == b0.subrange(i as int, n as int)
        {
            ghost let bi = block(self.ptr);
            unsafe self.ptr[i] = unsafe self.ptr[i - 1];
            // The first `i - 1` stay; element `i` is element `i - 1` of `b0`.
            upd_take_out(bi, i as int - 1, i as int, bi[i as int - 1]);
            take_take(bi, i as int, i as int - 1);
            take_take(b0, i as int, i as int - 1);
            take_at(bi, i as int, i as int - 1);
            take_at(b0, i as int, i as int - 1);
            sub_head(block(self.ptr), i as int, n as int + 1);
            upd_sub_out(bi, i as int, i as int + 1, n as int + 1, bi[i as int - 1]);
            sub_head(b0, i as int - 1, n as int);
            i = i - 1;
        }
    }

    /// Remove and return the element at `index`, shifting later elements left (`None` if out of range).
    pub const fn remove(self: &mut Vector<T, A>, index: usize) Option<T>
        ensures |r| index as int >= old(self.view()).len() ==> r == Option::<T>::None
        ensures |r| index as int < old(self.view()).len() ==> r == Some(old(self.view())[index as int])
        ensures index as int >= old(self.view()).len() ==> self.view() == old(self.view())
        ensures index as int < old(self.view()).len() ==> self.view() == old(self.view()).take(index as int).concat(
            old(self.view()).subrange(index as int + 1, old(self.view()).len()),
        )
    {
        if index >= self.len {
            return None;
        }
        let n = self.len;
        ghost let b0 = block(self.ptr);
        let removed = unsafe self.ptr[index];
        let mut i = index;
        while i + 1 < n
            invariant self.invariant() && self.len == n && index <= i && i < n && block(self.ptr).len() == b0.len()
            invariant block(self.ptr).take(index as int) == b0.take(index as int)
            invariant block(self.ptr).subrange(index as int, i as int) == b0.subrange(index as int + 1, i as int + 1)
            invariant block(self.ptr).subrange(i as int + 1, n as int) == b0.subrange(i as int + 1, n as int)
        {
            unsafe self.ptr[i] = unsafe self.ptr[i + 1];
            i = i + 1;
        }
        self.len = n - 1;
        return Some(removed);
    }

    /// Exchange the elements at `i` and `j`. Panics when either is `>= len`.
    pub const fn swap(self: &mut Vector<T, A>, i: usize, j: usize)
        panics if i as int >= self.view().len() || j as int >= self.view().len()
        ensures self.view() == old(self.view()).update(i as int, old(self.view())[j as int]).update(
            j as int,
            old(self.view())[i as int],
        )
    {
        if i >= self.len || j >= self.len {
            panic("Vector::swap: index out of bounds");
        }
        ghost let b0 = block(self.ptr);
        let tmp = unsafe self.ptr[i];
        unsafe self.ptr[i] = unsafe self.ptr[j];
        ghost let b1 = block(self.ptr);
        unsafe self.ptr[j] = tmp;
        take_at(b0, self.len as int, i as int);
        take_at(b0, self.len as int, j as int);
        upd_take(b0, self.len as int, i as int, b0[j as int]);
        upd_take(b1, self.len as int, j as int, b0[i as int]);
    }

    /// Remove the element at `index` by swapping in the last one (O(1), reorders; `None` if out of range).
    pub const fn swap_remove(self: &mut Vector<T, A>, index: usize) Option<T>
        ensures |r| index as int >= old(self.view()).len() ==> r == Option::<T>::None
        ensures |r| index as int < old(self.view()).len() ==> r == Some(old(self.view())[index as int])
        ensures index as int >= old(self.view()).len() ==> self.view() == old(self.view())
        ensures index as int < old(self.view()).len() ==> self.view() == old(self.view()).update(
            index as int,
            old(self.view())[old(self.view()).len() - 1],
        ).take(old(self.view()).len() - 1)
    {
        if index >= self.len {
            return None;
        }
        let n = self.len;
        ghost let b0 = block(self.ptr);
        let removed = unsafe self.ptr[index];
        self.len = n - 1;
        unsafe self.ptr[index] = unsafe self.ptr[self.len];
        take_at(b0, n as int, n as int - 1);
        upd_take(b0, n as int, index as int, b0[n as int - 1]);
        take_take(block(self.ptr), n as int, n as int - 1);
        return Some(removed);
    }

    /// Reverse the elements in place.
    pub const fn reverse(self: &mut Vector<T, A>)
        ensures self.view().len() == old(self.view()).len()
    {
        self.as_mut_slice().reverse();
    }

    /// A new vector (same allocator) with `f` applied to every element. `f` BORROWS each element (`&T`): this
    /// map reads `self` and leaves it owning its elements, so it must not consume them (passing a Free element
    /// by value would free the Vector's still-owned copy).
    pub const fn map<U, F: fn(&T) U>(self: &Vector<T, A>, f: F) Vector<U, A>
        panics if self.view().len() > Vector::<U, A>::max_len()
        ensures |r| r.view().len() == self.view().len()
    {
        let mut out = Vector::<U, A>::with_capacity_in(self.alloc, self.len);
        for i in 0..self.len
            invariant out.invariant() && out.view().len() == i as int
        {
            out.push(f(self.at(i)));
        }
        return out;
    }

    /// A borrow of the first element matching `pred`, or `None`. `pred` borrows (`&T`); it must not consume.
    pub const fn find<F: fn(&T) bool>(self: &Vector<T, A>, pred: F) Option<&T> {
        for i in 0..self.len {
            if pred(self.at(i)) {
                return Some(&unsafe self.ptr[i]);
            }
        }
        return None;
    }

    /// Keep only the elements matching `pred` (in place, preserving order). `pred` borrows (`&T`); rejected
    /// elements are freed (no-op when T isn't Free) so nothing leaks.
    pub const fn retain<F: fn(&T) bool>(self: &mut Vector<T, A>, pred: F)
        ensures self.view().len() <= old(self.view()).len()
    {
        // The vector owns no element while `pred` and `free` run (`clear`): one that panics leaks the
        // elements instead of leaving moved or freed ones in the vector.
        let n = self.len;
        self.len = 0;
        let mut w: usize = 0;
        for i in 0..n
            invariant self.invariant() && self.len == 0 && w <= i && i <= n && n <= self.cap
        {
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

// The view after a push of `x` at index `n` of block `b1`, of length `m`: the elements before (`b0`), then `x`.
lemma push_view<T>(b0: Seq<T>, b1: Seq<T>, n: int, m: int, x: T)
    requires 0 <= n && n < b1.len() && m == n + 1 && b1.take(n) == b0
    ensures b1.update(n, x).take(m) == b0.push(x)
{}

// An update of an element among the first `n`, then the first `n`: the first `n`, then the update.
lemma upd_take<T>(b: Seq<T>, n: int, i: int, x: T)
    requires 0 <= i && i < n && n <= b.len()
    ensures b.update(i, x).take(n) == b.take(n).update(i, x)
{}

// An update of an element past the first `n`, then the first `n`: the first `n`.
lemma upd_take_out<T>(b: Seq<T>, n: int, i: int, x: T)
    requires 0 <= n && n <= i && i < b.len()
    ensures b.update(i, x).take(n) == b.take(n)
{}

// The elements from `lo` to before `hi`: element `lo`, then the elements after it.
lemma sub_head<T>(b: Seq<T>, lo: int, hi: int)
    requires 0 <= lo && lo < hi && hi <= b.len()
    ensures b.subrange(lo, hi) == Seq::<T>::empty().push(b[lo]).concat(b.subrange(lo + 1, hi))
{}

// An update of element `i` that a subrange leaves out: the subrange.
lemma upd_sub_out<T>(b: Seq<T>, i: int, lo: int, hi: int, x: T)
    requires 0 <= i && i < b.len() && 0 <= lo && lo <= hi && hi <= b.len() && (i < lo || hi <= i)
    ensures b.update(i, x).subrange(lo, hi) == b.subrange(lo, hi)
{}

// A subrange of the first `n` elements: the subrange.
lemma take_sub<T>(b: Seq<T>, n: int, lo: int, hi: int)
    requires 0 <= lo && lo <= hi && hi <= n && n <= b.len()
    ensures b.take(n).subrange(lo, hi) == b.subrange(lo, hi)
{}

// The first `n + 1` elements, element `i` among them: the ones before it, it, then the ones after it.
lemma take_split<T>(f: Seq<T>, i: int, n: int)
    requires 0 <= i && i <= n && n < f.len()
    ensures f.take(n + 1) == f.take(i).push(f[i]).concat(f.subrange(i + 1, n + 1))
{}

// Element `j` of the first `n`: element `j`.
lemma take_at<T>(b: Seq<T>, n: int, j: int)
    requires 0 <= j && j < n && n <= b.len()
    ensures b.take(n)[j] == b[j]
{}

// The first `m` elements of the first `n`: the first `m`.
lemma take_take<T>(b: Seq<T>, n: int, m: int)
    requires 0 <= m && m <= n && n <= b.len()
    ensures b.take(n).take(m) == b.take(m)
{}

// Convenience constructors for a default-constructible allocator (`Global`, or any zero-sized tag).
extend<T, A: Allocator + Default> Vector<T, A> {
    /// An empty vector using the default allocator; no allocation until the first push.
    pub const fn new() Vector<T, A>
        ensures |r| r.view() == Seq::<T>::empty()
    {
        return Vector::<T, A>::new_in(A::default());
    }
    /// An empty vector whose allocation already holds `cap` elements.
    pub const fn with_capacity(cap: usize) Vector<T, A>
        panics if cap as int > Vector::<T, A>::max_len()
        ensures |r| r.view() == Seq::<T>::empty()
    {
        return Vector::<T, A>::with_capacity_in(A::default(), cap);
    }
}

// Free the buffer (through `A`) AND deep-free every element. Auto-`Free`: the Vector is released at scope
// exit. Sound because the peek accessors (`at`/`get`/`first`/`last`/`find`/`iter`) borrow (`&T`) rather than
// hand out sharing copies, and the removers (`pop`/`remove`/`swap_remove`) move the element out, so the
// buffer is the only owner of each live element. Each element `.free()` is a no-op when `T` isn't a Free type.
// Resizing needs a value for the slots it adds, and a `Free` element cannot be copied into them (filling
// ten slots from one `String` would hand ten owners the same buffer), so it is available exactly for the
// element types that can produce a fresh value on demand.
extend<T: Default, A: Allocator> Vector<T, A> {
    /// Resize to exactly `n` elements: the tail beyond `n` is freed, and any new slot is `T::default()`.
    pub fn resize_default(self: &mut Vector<T, A>, n: usize)
        panics if n as int > Vector::<T, A>::max_len()
        ensures self.view().len() == n as int
    {
        if n < self.len {
            self.truncate(n);
            return;
        }
        self.reserve(n - self.len);
        // Straight stores into the reserved tail, the length set once: a zero default becomes one
        // memset instead of a length and capacity check per element.
        let m = self.len;
        ghost let b0 = block(self.ptr);
        let mut i = m;
        while i < n
            invariant self.invariant() && self.len == m && m <= i && i <= n && n <= self.cap && block(self.ptr).len() == b0.len()
        {
            unsafe self.ptr[i] = T::default();
            i += 1;
        }
        self.len = n;
    }
}

extend<T: Copy, A: Allocator> Vector<T, A> {
    /// Append a copy of every element of `src` with one byte copy.
    pub fn extend_copy(self: &mut Vector<T, A>, src: &Vector<T, A>)
        panics if self.view().len() + src.view().len() > Vector::<T, A>::max_len()
        ensures self.view().len() == old(self.view()).len() + src.view().len()
    {
        self.extend_from_slice(src.as_slice());
    }

    /// Append a copy of every element of `src` with one byte copy: one capacity check, no per-element
    /// work (the copy loop is one `memcpy` once optimized). `src` must not view this vector's own buffer
    /// (a growth would move it).
    pub fn extend_from_slice(self: &mut Vector<T, A>, src: []T)
        panics if self.view().len() + src.view().len() > Vector::<T, A>::max_len()
        ensures self.view().len() == old(self.view()).len() + src.view().len()
    {
        let n = src.len();
        self.reserve(n);
        let m = self.len;
        ghost let b0 = block(self.ptr);
        for j in 0..n
            invariant self.invariant() && self.len == m && m as int + n as int <= self.cap as int && block(self.ptr).len() == b0.len()
        {
            unsafe self.ptr[m + j] = src[j];
        }
        self.len = m + n;
    }
}

extend<T, A: Allocator> Vector<T, A> as Free {
    pub fn free(self: &mut Vector<T, A>) {
        self.clear();
        if sizeof(T) == 0 {
            self.ptr = null;
            self.cap = 0;
            // The sentinel was never allocated.
            return;
        }
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

// Build from a list of elements: `let v: Vector<i32> = [1, 2, 3].into();` (an array coerces to the
// slice). The slice BORROWS, so each element is cloned in: the source keeps its own copies and stays
// responsible for them. Hence `T: Clone`, which every scalar satisfies.
extend<T: Clone, A: Allocator + Default> Vector<T, A> as From<[]T> {
    pub fn from(value: []T) Vector<T, A>
        ensures |r| r.view().len() == value.view().len()
    {
        let mut out = Vector::<T, A>::with_capacity(value.len());
        for i in 0..value.len()
            invariant out.invariant() && out.view().len() == i as int
        {
            out.push(value.at(i).clone());
        }
        return out;
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
                return Some(i);
            }
        }
        return None;
    }

    /// Remove consecutive runs of equal elements, keeping the first of each run. The dropped duplicates
    /// are freed (no-op when T isn't Free). O(n); only adjacent equals are removed (sort first for global).
    pub const fn dedup(self: &mut Vector<T, A>)
        ensures self.view().len() <= old(self.view()).len()
    {
        let k = self.as_mut_slice().partition_dedup();
        self.truncate(k);
    }
}

// Order-based algorithms: the shared slice algorithms (std/slice.spc) over the elements.
extend<T: Ord, A: Allocator> Vector<T, A> {
    /// True if the elements are in non-decreasing order (per `Ord`).
    pub const fn is_sorted(self: &Vector<T, A>) bool {
        return self.as_slice().is_sorted();
    }

    /// Binary search of a sorted vector: `Ok(i)` where an equal element lives (any one of several), or
    /// `Err(i)`, the index a missing element would be inserted at to keep order. O(log n); unspecified
    /// result if not sorted.
    pub const fn binary_search(self: &Vector<T, A>, x: &T) Result<usize, usize> {
        return self.as_slice().binary_search(x);
    }

    /// Sort in place into non-decreasing order, unstable (pattern-defeating quicksort: O(n log n) worst
    /// case, no allocation).
    pub const fn sort(self: &mut Vector<T, A>)
        ensures self.view().len() == old(self.view()).len()
    {
        self.as_mut_slice().sort();
    }

    /// Sort in place into non-decreasing order, stable, with no allocation: O(n log n) comparisons and
    /// O(n log^2 n) moves (`SliceMut::sort_stable_in_place`).
    pub fn sort_stable_in_place(self: &mut Vector<T, A>)
        ensures self.view().len() == old(self.view()).len()
    {
        self.as_mut_slice().sort_stable_in_place();
    }

    /// Sort in place into non-decreasing order, stable, with scratch for `len` elements from the
    /// vector's allocator.
    pub fn sort_stable(self: &mut Vector<T, A>)
        ensures self.view().len() == old(self.view()).len()
    {
        let a = self.alloc;
        self.as_mut_slice().sort_stable_in(a);
    }
}

// Comparator-driven sorting (no `Ord` required: the closure decides the order).
extend<T, A: Allocator> Vector<T, A> {
    /// Sort in place by a comparator returning negative / zero / positive, unstable. O(n log n).
    pub const fn sort_by<F: fn(&T, &T) i32>(self: &mut Vector<T, A>, cmp: F)
        ensures self.view().len() == old(self.view()).len()
    {
        self.as_mut_slice().sort_by(cmp);
    }

    /// Stable `sort_by` with no allocation (`SliceMut::sort_stable_in_place_by`).
    pub fn sort_stable_in_place_by<F: fn(&T, &T) i32>(self: &mut Vector<T, A>, cmp: F)
        ensures self.view().len() == old(self.view()).len()
    {
        self.as_mut_slice().sort_stable_in_place_by(cmp);
    }

    /// Sort in place by a derived `Ord` key (`v.sort_by_key(|p: &P| p.age)`), unstable. O(n log n); the
    /// key is computed twice per comparison.
    pub const fn sort_by_key<K: Ord, F: fn(&T) K>(self: &mut Vector<T, A>, key: F)
        ensures self.view().len() == old(self.view()).len()
    {
        self.as_mut_slice().sort_by_key::<K, F>(key);
    }

    /// Stable `sort_by`, with scratch from the vector's allocator.
    pub fn sort_stable_by<F: fn(&T, &T) i32>(self: &mut Vector<T, A>, cmp: F)
        ensures self.view().len() == old(self.view()).len()
    {
        let a = self.alloc;
        self.as_mut_slice().sort_stable_by_in(a, cmp);
    }

    /// Stable `sort_by_key`, with scratch from the vector's allocator.
    pub fn sort_stable_by_key<K: Ord, F: fn(&T) K>(self: &mut Vector<T, A>, key: F)
        ensures self.view().len() == old(self.view()).len()
    {
        let a = self.alloc;
        self.as_mut_slice().sort_stable_by_key_in::<A, K, F>(a, key);
    }

    /// Remove consecutive elements that `same(earlier, later)` joins to the element kept before them,
    /// freeing them (no-op when T isn't Free). O(n).
    pub fn dedup_by<F: fn(&T, &T) bool>(self: &mut Vector<T, A>, same: F)
        ensures self.view().len() <= old(self.view()).len()
    {
        let k = self.as_mut_slice().partition_dedup_by(same);
        self.truncate(k);
    }

    /// Remove consecutive elements with equal keys, keeping the first of each run. O(n).
    pub fn dedup_by_key<K: Eq, F: fn(&T) K>(self: &mut Vector<T, A>, key: F)
        ensures self.view().len() <= old(self.view()).len()
    {
        let k = self.as_mut_slice().partition_dedup_by_key::<K, F>(key);
        self.truncate(k);
    }
}

/// A borrowing cursor over a Vector's elements. `for x in v.iter()` yields a borrow `&T` of each element.
pub struct VecIter<'a, T> {
    pub data: *const T,
    pub idx: usize,
    pub stop: usize,
}

extend<T, A: Allocator> Vector<T, A> {
    /// A by-reference iterator over the elements in order.
    pub const fn iter(self: &Vector<T, A>) VecIter<T> {
        return VecIter::<T> { data: self.as_ptr(), idx: 0, stop: self.len() };
    }
}

extend<'a, T> VecIter<'a, T> as Iterator<&'a T> {
    pub const fn next(self: &mut VecIter<'a, T>) Option<&'a T> {
        if self.idx >= self.stop {
            return Option::<&'a T>::none();
        }
        let r = unsafe &*(self.data + self.idx);
        self.idx = self.idx + 1;
        return Option::<&'a T>::some(r);
    }

    pub const fn size_hint(self: &VecIter<'a, T>) (usize, Option<usize>) {
        let n = self.stop - self.idx;
        return (n, Option::<usize>::Some(n));
    }
}

extend<'a, T> VecIter<'a, T> as DoubleEndedIterator<&'a T> {
    pub const fn next_back(self: &mut VecIter<'a, T>) Option<&'a T> {
        if self.idx >= self.stop {
            return Option::<&'a T>::none();
        }
        self.stop = self.stop - 1;
        return Option::<&'a T>::some(unsafe &*(self.data + self.stop));
    }
}

// Index conformances: `v[i]` borrows the element in place (bounds-checked like `at`: it panics when
// `i >= len`), and `v[lo..hi]`: any range form, `..=` including the end, an open end meaning the
// vector's `len()`: is a borrowed `[]T` view of the elements. Views alias the buffer, so they are
// invalidated by any reallocating mutation (push/reserve).
extend<T, A: Allocator> Vector<T, A> as Index<T, []T> {
    pub const fn index(self: &Vector<T, A>, i: usize) &T {
        if i >= self.len {
            panic_parts(type_info::<Self>().qualified_name, "[i]: index out of bounds");
        }
        return &unsafe self.ptr[i];
    }
    pub const fn index_range(self: &Vector<T, A>, r: Range<usize>) []T {
        if r.inclusive && r.end >= self.len {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        let hi = if r.inclusive {
            r.end + 1
        } else {
            r.end
        };
        if r.start > hi || hi > self.len {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        return unsafe Slice::<T> { ptr: self.ptr + r.start, len: hi - r.start };
    }
}

// The writable counterpart: `v[i] = x` stores through the returned element pointer (a plain `=` over a
// Free element frees the replaced value first, compiler-inserted: same semantics as `set`);
// `index_range_mut` is an in-place writable view.
extend<T, A: Allocator> Vector<T, A> as IndexMut<T, []mut T> {
    pub const fn index_mut(self: &mut Vector<T, A>, i: usize) &mut T {
        if i >= self.len {
            panic_parts(type_info::<Self>().qualified_name, "[i]: index out of bounds");
        }
        return &mut unsafe self.ptr[i];
    }
    pub const fn index_range_mut(self: &mut Vector<T, A>, r: Range<usize>) []mut T {
        if r.inclusive && r.end >= self.len {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        let hi = if r.inclusive {
            r.end + 1
        } else {
            r.end
        };
        if r.start > hi || hi > self.len {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        return unsafe SliceMut::<T> { ptr: self.ptr + r.start, len: hi - r.start };
    }
}

// Conditional conformances: a Vector is Clone/Eq/Hash exactly when its element is. Each dispatches to the
// element's bound method (`e.clone()`, `a.eq(&b)`, `e.hash_into(h)`), monomorphized per element type.
extend<T: Clone, A: Allocator> Vector<T, A> as Clone {
    /// A deep copy: a fresh backing store (same allocator) whose elements are independent clones.
    pub const fn clone(self: &Vector<T, A>) Vector<T, A>
        ensures |r| r.view().len() == self.view().len()
    {
        let mut out = Vector::<T, A>::with_capacity_in(self.alloc, self.len());
        for i in 0..self.len()
            invariant out.invariant() && out.view().len() == i as int
        {
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
                return false;
            }
        }
        return true;
    }
}

extend<T: Hash, A: Allocator> Vector<T, A> as Hash {
    /// The length, then every element through its own `hash_into`: equal sequences feed equal streams.
    pub fn hash_into<H: Hasher>(self: &Vector<T, A>, h: &mut H) {
        h.write_u64(self.len() as u64);
        for i in 0..self.len() {
            self.at(i).hash_into(h);
        }
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

extend<T, A: Allocator> Vector<T, A> as AsSlice<T> {
    /// A view of the elements; invalidated by any reallocating mutation.
    pub const fn as_slice(self: &Vector<T, A>) []T {
        return unsafe Slice::<T> { ptr: self.ptr, len: self.len };
    }
}

extend<T, A: Allocator> Vector<T, A> as AsSliceMut<T> {
    /// A writable view of the elements: the shared slice algorithms (`select_nth_unstable`,
    /// `rotate_left`, heap operations, ...) run on it.
    pub const fn as_mut_slice(self: &mut Vector<T, A>) []mut T {
        return unsafe SliceMut::<T> { ptr: self.ptr, len: self.len };
    }
}
