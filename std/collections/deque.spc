// Double-ended queues over a ring of slots. `Deque<T, A = Global>` is a growable ring in one block from
// allocator `A`; `RingBuffer<T, const N: usize>` is a ring of N inline slots that never allocates. Both keep
// the slot of the front element and the length; the capacity is a power of two, so logical index `i` lives
// in slot `(head + i) & (capacity - 1)`.
//
// Complexity, with the C++ `std::deque` requirements ([deque.modifiers]) as the reference:
//   push_back, push_front: amortized O(1) for Deque (a growth copies every element once), O(1) for RingBuffer.
//   pop_back, pop_front, front, back, get, at, `[i]`, swap, swap_remove_back, swap_remove_front: O(1).
//   insert(i), remove(i): O(min(i, len - i)): the elements on the shorter side move by one slot.
//   rotate_left(k), rotate_right(k): O(min(k, len - k)).
//   append(other): O(other.len) amortized. make_contiguous: O(len), no allocation.
//   truncate, clear, retain, contains, clone, eq, hash, fmt, iteration and drain: O(len). binary_search: O(log len).
//   reserve, reserve_exact, shrink_to_fit: O(len) when they reallocate, O(1) otherwise.
//
// Invalidation (Deque). Unlike the segmented C++ deque, the ring is one block, so a growth (push_back,
// push_front, insert, append, reserve, reserve_exact) and shrink_to_fit move the block and invalidate every
// reference, slice and iterator. A push or pop at either end that does not grow moves no other element, so
// references to the other elements stay valid. insert, remove, swap_remove_*, retain, rotate_* and
// make_contiguous move elements and invalidate every reference. Safe code cannot observe a stale reference
// (the borrow rules reject it); the rules bind raw pointers taken from the deque. RingBuffer never moves
// its storage: an operation moves only the elements it names, and moving the RingBuffer value moves them all.
//
// Iteration runs front to back; `next_back` runs back to front. `drain` moves the elements out and leaves the
// deque empty with its block kept. `as_slices` and `[lo..hi]` give the elements as two contiguous parts, in order.
//
// Allocation: Deque holds one block of capacity * sizeof(T) bytes from `A` and no allocation per element;
// growth doubles the capacity (at least 8 slots), and every capacity rounds up to a power of two. A
// zero-sized T never calls the allocator. Thread safety: no internal synchronization; both types are Send and
// Sync when T (and A) are, so a shared reference allows concurrent reads and a mutation needs exclusive access.

extern "C" {
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
    fn memmove(dst: *mut void, src: *const void, n: usize) *mut void;
}

const USIZE_BITS: usize = sizeof(usize) * 8;
const MIN_CAP: usize = 8; // the first growth's capacity, as Vector's
const ZST_CAP: usize = 1 as usize << USIZE_BITS - 1; // the largest power of two in a usize

/// A growable double-ended queue: a ring buffer in one block from allocator A. The capacity is 0 or a power
/// of two; push and pop at both ends are amortized O(1).
pub struct Deque<T, A = Global> {
    ptr: *mut T, // the block; `dangling` while cap == 0 or for a zero-sized T, so a view's pointer is never null
    head: usize, // slot of the front element; 0 while cap == 0
    len: usize, // elements in use
    cap: usize, // slots in the block: 0 or a power of two
    alloc: A, // the allocator the block came from (zero-sized for Global)
}

// A Deque owns its elements, so it is Send / Sync when its elements and allocator are (the block pointer
// makes it structurally neither).
unsafe extend<T: Send, A: Send> Deque<T, A> as Send {}

unsafe extend<T: Sync, A: Sync> Deque<T, A> as Sync {}

/// A fixed-capacity double-ended queue: a ring of N inline slots, no allocation. N must be a power of two
/// (a build error otherwise). Send and Sync when T is.
pub struct RingBuffer<T, const N: usize> {
    data: [T; N], // inline slots; only the `len` slots from `head` around the ring hold live elements
    head: usize, // slot of the front element
    len: usize, // elements in use
}

/// A range of a Deque or a RingBuffer as its two contiguous parts, in order (`d[lo..hi]`).
pub type RingSlices<'a, T> = (Slice<'a, T>, Slice<'a, T>);

/// The writable form of `RingSlices` (`&mut d[lo..hi]`).
pub type RingSlicesMut<'a, T> = (SliceMut<'a, T>, SliceMut<'a, T>);

/// A borrowing iterator over a Deque or a RingBuffer, front to back; `next_back` takes from the back.
pub struct RingIter<'a, T> {
    data: *const T,
    mask: usize, // capacity - 1
    idx: usize, // slot of the next front element
    rem: usize, // elements left
}

/// A mutably borrowing iterator over a Deque, front to back; `next_back` takes from the back.
pub struct RingIterMut<'a, T> {
    data: *mut T,
    mask: usize,
    idx: usize,
    rem: usize,
}

/// The elements of a Deque moved out front to back (`next_back`: from the back). The deque is empty from
/// the `drain` call on; dropping the drain frees the elements it did not yield.
pub struct DequeDrain<'a, T> {
    data: *mut T,
    mask: usize,
    idx: usize,
    rem: usize,
}

// The smallest power of two at least `n`, for n <= ZST_CAP.
const fn next_pow2(n: usize) usize {
    if n <= 1 {
        return 1;
    }
    return 1 as usize << USIZE_BITS - (n - 1).leading_zeros();
}

// The end of range `r` over `len` elements, excluded. Panics when `r` does not lie in `0..len`.
const fn range_end(r: &Range<usize>, len: usize) usize {
    if r.inclusive && r.end >= len {
        panic("Deque: range out of bounds");
    }
    let hi = if r.inclusive {
        r.end + 1
    } else {
        r.end
    };
    if r.start > hi || hi > len {
        panic("Deque: range out of bounds");
    }
    return hi;
}

// The two contiguous parts of logical range `lo..hi` of a ring of `cap` slots whose front is slot `head`.
const fn ring_parts<'a, T>(data: *const T, cap: usize, head: usize, lo: usize, hi: usize) (Slice<'a, T>, Slice<'a, T>) {
    let start = head + lo & cap.wrapping_sub(1);
    let first = (hi - lo).min(cap - start);
    return (unsafe Slice::<T> { ptr: data + start, len: first }, unsafe Slice::<T> { ptr: data, len: hi - lo - first });
}

// The writable form of `ring_parts`.
const fn ring_parts_mut<'a, T>(data: *mut T, cap: usize, head: usize, lo: usize, hi: usize) (
    SliceMut<'a, T>,
    SliceMut<'a, T>
) {
    let start = head + lo & cap.wrapping_sub(1);
    let first = (hi - lo).min(cap - start);
    return (
        unsafe SliceMut::<T> { ptr: data + start, len: first },
        unsafe SliceMut::<T> { ptr: data, len: hi - lo - first }
    );
}

// Rotate the `n` elements at `p` left by `k <= n` with three reversals: about n swaps, no allocation.
const fn rotate_raw<T>(p: *mut T, n: usize, k: usize) {
    reverse_raw(p, k);
    reverse_raw(unsafe (p + k), n - k);
    reverse_raw(p, n);
}

const fn reverse_raw<T>(p: *mut T, n: usize) {
    if n < 2 {
        return;
    }
    let mut i: usize = 0;
    let mut j = n - 1;
    while i < j {
        let t = unsafe p[i];
        unsafe p[i] = unsafe p[j];
        unsafe p[j] = t;
        i += 1;
        j -= 1;
    }
}

// The shared bodies of the Eq, Hash and Format conformances, over the elements in order.
fn ring_eq<T: Eq>(a: RingIter<T>, b: RingIter<T>) bool {
    let (na, _) = a.size_hint();
    let (nb, _) = b.size_hint();
    if na != nb {
        return false;
    }
    let mut ib = b;
    for x in a {
        if !x.eq(ib.next().unwrap()) {
            return false;
        }
    }
    return true;
}

fn ring_hash_into<T: Hash, H: Hasher>(it: RingIter<T>, h: &mut H) {
    let (n, _) = it.size_hint();
    h.write_u64(n as u64);
    for e in it {
        e.hash_into(h);
    }
}

fn ring_fmt<T: Format>(it: RingIter<T>) String {
    let mut s = String::from_str("[");
    let mut first = true;
    for e in it {
        if !first {
            s.push_str(", ");
        }
        first = false;
        let es = e.fmt();
        s.push_string(&es);
    }
    s.push_str("]");
    return s;
}

extend<T, A: Allocator> Deque<T, A> {
    /// An empty deque that allocates through `alloc`; no allocation until the first push.
    pub const fn new_in(alloc: A) Deque<T, A> {
        return Deque::<T, A>::with_capacity_in(alloc, 0);
    }

    /// An empty deque with room for `cap` elements, rounded up to a power of two, allocated through `alloc`
    /// (no allocation when `cap` is 0). Panics when the byte size overflows a usize.
    pub const fn with_capacity_in(alloc: A, cap: usize) Deque<T, A> {
        let mut d = Deque::<T, A> { ptr: dangling::<T>(), head: 0, len: 0, cap: 0, alloc: alloc };
        if sizeof(T) == 0 {
            d.cap = ZST_CAP;
        } else if cap > 0 {
            if cap > Deque::<T, A>::max_cap() {
                panic("Deque: capacity overflow");
            }
            d.cap = next_pow2(cap);
            d.ptr = (unsafe d.alloc.alloc(d.cap * sizeof(T), alignof(T))) as *mut T;
        }
        return d;
    }

    // The largest power of two whose byte size fits a usize.
    const fn max_cap() usize {
        if sizeof(T) == 0 {
            return ZST_CAP;
        }
        let m = ~(0 as usize) / sizeof(T);
        return 1 as usize << USIZE_BITS - 1 - m.leading_zeros();
    }

    /// Number of elements.
    pub const fn len(self: &Deque<T, A>) usize {
        return self.len;
    }

    /// True when no element is stored.
    pub const fn is_empty(self: &Deque<T, A>) bool {
        return self.len == 0;
    }

    /// Elements the block holds without growing: 0 or a power of two.
    pub const fn capacity(self: &Deque<T, A>) usize {
        return self.cap;
    }

    // The slot of logical index `i`; needs cap > 0.
    const fn slot(self: &Deque<T, A>, i: usize) usize {
        return self.head + i & self.cap - 1;
    }

    /// Makes room for at least `additional` more elements. A growth sets the capacity to the smallest power of
    /// two that holds `len + additional` elements, and to at least 8. Panics when the byte size overflows a usize.
    pub fn reserve(self: &mut Deque<T, A>, additional: usize) {
        if additional > self.cap - self.len {
            self.grow_for(additional);
        }
    }

    // The growth path of `reserve` and the pushes, out of line so their check stays small.
    @noinline
    fn grow_for(self: &mut Deque<T, A>, additional: usize) {
        let max_cap = Deque::<T, A>::max_cap();
        if additional > max_cap - self.len {
            panic("Deque: capacity overflow");
        }
        let mut new_cap = next_pow2(self.len + additional);
        if new_cap < MIN_CAP && MIN_CAP <= max_cap {
            new_cap = MIN_CAP;
        }
        self.grow_to(new_cap);
    }

    /// Makes room for at least `additional` more elements with the smallest power-of-two capacity that holds
    /// them (no minimum of 8). Panics when the byte size overflows a usize.
    pub fn reserve_exact(self: &mut Deque<T, A>, additional: usize) {
        if additional <= self.cap - self.len {
            return;
        }
        if additional > Deque::<T, A>::max_cap() - self.len {
            panic("Deque: capacity overflow");
        }
        self.grow_to(next_pow2(self.len + additional));
    }

    // Reallocate to `new_cap` slots (a power of two above `cap`, T not zero-sized) and restore the ring: the
    // block keeps its slots, so a wrapped deque moves the shorter of its two parts into the new space. The
    // new capacity is at least twice the old, so the moved part lands clear of both parts.
    fn grow_to(self: &mut Deque<T, A>, new_cap: usize) {
        let old_cap = self.cap;
        if old_cap == 0 {
            self.ptr = (unsafe self.alloc.alloc(new_cap * sizeof(T), alignof(T))) as *mut T;
        } else {
            self.ptr = (unsafe self.alloc.realloc(self.ptr, old_cap * sizeof(T), new_cap * sizeof(T), alignof(T))) as *mut T;
        }
        self.cap = new_cap;
        if self.head + self.len > old_cap {
            let head_len = old_cap - self.head;
            let tail_len = self.len - head_len;
            if tail_len < head_len {
                unsafe memcpy(self.ptr + old_cap, self.ptr, tail_len * sizeof(T));
            } else {
                let new_head = new_cap - head_len;
                unsafe memcpy(self.ptr + new_head, self.ptr + self.head, head_len * sizeof(T));
                self.head = new_head;
            }
        }
    }

    /// Reallocates to the smallest power of two that holds the elements (frees the block when empty).
    pub fn shrink_to_fit(self: &mut Deque<T, A>) {
        if sizeof(T) == 0 || self.cap == 0 {
            return;
        }
        if self.len == 0 {
            unsafe self.alloc.dealloc(self.ptr, self.cap * sizeof(T), alignof(T));
            self.ptr = dangling::<T>();
            self.cap = 0;
            self.head = 0;
            return;
        }
        let target = next_pow2(self.len);
        if target == self.cap {
            return;
        }
        // Move the elements into slots 0..target first. A wrapped front part starts at or above `target`
        // (cap >= 2 * target), so it moves to the end of the new range without overlap.
        if self.head + self.len > self.cap {
            let head_len = self.cap - self.head;
            unsafe memcpy(self.ptr + (target - head_len), self.ptr + self.head, head_len * sizeof(T));
            self.head = target - head_len;
        } else if self.head + self.len > target {
            unsafe memmove(self.ptr, self.ptr + self.head, self.len * sizeof(T));
            self.head = 0;
        }
        self.ptr = (unsafe self.alloc.realloc(self.ptr, self.cap * sizeof(T), target * sizeof(T), alignof(T))) as *mut T;
        self.cap = target;
    }

    /// Appends `value` at the back; amortized O(1).
    pub fn push_back(self: &mut Deque<T, A>, value: T) {
        if self.len == self.cap {
            self.grow_for(1);
        }
        unsafe self.ptr[self.slot(self.len)] = value;
        self.len += 1;
    }

    /// Prepends `value` at the front; amortized O(1).
    pub fn push_front(self: &mut Deque<T, A>, value: T) {
        if self.len == self.cap {
            self.grow_for(1);
        }
        self.head = self.head.wrapping_sub(1) & self.cap - 1;
        unsafe self.ptr[self.head] = value;
        self.len += 1;
    }

    /// Removes the back element and moves it to the caller; None when empty.
    pub const fn pop_back(self: &mut Deque<T, A>) Option<T> {
        if self.len == 0 {
            return None;
        }
        self.len -= 1;
        return Some(unsafe self.ptr[self.slot(self.len)]);
    }

    /// Removes the front element and moves it to the caller; None when empty.
    pub const fn pop_front(self: &mut Deque<T, A>) Option<T> {
        if self.len == 0 {
            return None;
        }
        let v = unsafe self.ptr[self.head];
        self.head = self.head + 1 & self.cap - 1;
        self.len -= 1;
        return Some(v);
    }

    /// The front element; None when empty.
    pub const fn front(self: &Deque<T, A>) Option<&T> {
        return self.get(0);
    }

    /// The back element; None when empty.
    pub const fn back(self: &Deque<T, A>) Option<&T> {
        if self.len == 0 {
            return None;
        }
        return Some(&unsafe self.ptr[self.slot(self.len - 1)]);
    }

    /// The front element, writable; None when empty.
    pub const fn front_mut(self: &mut Deque<T, A>) Option<&mut T> {
        return self.get_mut(0);
    }

    /// The back element, writable; None when empty.
    pub const fn back_mut(self: &mut Deque<T, A>) Option<&mut T> {
        if self.len == 0 {
            return None;
        }
        return Some(&mut unsafe self.ptr[self.slot(self.len - 1)]);
    }

    /// The element at logical index `i` (0 is the front); None when `i >= len`.
    pub const fn get(self: &Deque<T, A>, i: usize) Option<&T> {
        if i >= self.len {
            return None;
        }
        return Some(&unsafe self.ptr[self.slot(i)]);
    }

    /// The element at logical index `i`, writable; None when `i >= len`.
    pub const fn get_mut(self: &mut Deque<T, A>, i: usize) Option<&mut T> {
        if i >= self.len {
            return None;
        }
        return Some(&mut unsafe self.ptr[self.slot(i)]);
    }

    /// The element at logical index `i`. Panics when `i >= len`.
    pub const fn at(self: &Deque<T, A>, i: usize) &T {
        if i >= self.len {
            panic("Deque::at: index out of bounds");
        }
        return &unsafe self.ptr[self.slot(i)];
    }

    /// Exchanges the elements at logical indexes `i` and `j`. Panics when either is `>= len`.
    pub const fn swap(self: &mut Deque<T, A>, i: usize, j: usize) {
        if i >= self.len || j >= self.len {
            panic("Deque::swap: index out of bounds");
        }
        let a = self.slot(i);
        let b = self.slot(j);
        let t = unsafe self.ptr[a];
        unsafe self.ptr[a] = unsafe self.ptr[b];
        unsafe self.ptr[b] = t;
    }

    // Move `n` elements from slot `src` to slot `dst`, each run read around the ring. With d the distance
    // from `src` forward to `dst`, the runs may overlap when `min(d, cap - d) + n <= cap`: a run whose
    // destination is ahead (d < n) copies from its back end, any other from its front end, so no element
    // is overwritten before it is read. Each step ends where `src` or `dst` wraps, so at most 3 steps run.
    const fn copy_ring(self: &mut Deque<T, A>, src: usize, dst: usize, n: usize) {
        if sizeof(T) == 0 || n == 0 || src == dst {
            return;
        }
        let cap = self.cap;
        let mask = cap - 1;
        let mut left = n;
        if (dst.wrapping_sub(src) & mask) >= n {
            let mut s = src;
            let mut t = dst;
            while left > 0 {
                let c = left.min(cap - s).min(cap - t);
                unsafe memmove(self.ptr + t, self.ptr + s, c * sizeof(T));
                s = s + c & mask;
                t = t + c & mask;
                left -= c;
            }
        } else {
            let mut s = src + n & mask;
            let mut t = dst + n & mask;
            while left > 0 {
                let se = if s == 0 {
                    cap
                } else {
                    s
                };
                let te = if t == 0 {
                    cap
                } else {
                    t
                };
                let c = left.min(se).min(te);
                unsafe memmove(self.ptr + (te - c), self.ptr + (se - c), c * sizeof(T));
                s = se - c;
                t = te - c;
                left -= c;
            }
        }
    }

    /// Inserts `value` at logical index `i`, moving the elements on the shorter side (before `i` or from `i`)
    /// by one slot: O(min(i, len - i)). Panics when `i > len`.
    pub fn insert(self: &mut Deque<T, A>, i: usize, value: T) {
        if i > self.len {
            panic("Deque::insert: index out of bounds");
        }
        if self.len == self.cap {
            self.grow_for(1);
        }
        let mask = self.cap - 1;
        if i < self.len - i {
            self.head = self.head.wrapping_sub(1) & mask;
            self.copy_ring(self.head + 1 & mask, self.head, i);
        } else {
            let at = self.slot(i);
            self.copy_ring(at, at + 1 & mask, self.len - i);
        }
        unsafe self.ptr[self.slot(i)] = value;
        self.len += 1;
    }

    /// Removes the element at logical index `i` and moves it to the caller, closing the gap from the shorter
    /// side: O(min(i, len - i)). None when `i >= len`.
    pub const fn remove(self: &mut Deque<T, A>, i: usize) Option<T> {
        if i >= self.len {
            return None;
        }
        let mask = self.cap - 1;
        let at = self.slot(i);
        let v = unsafe self.ptr[at];
        let after = self.len - 1 - i;
        if i < after {
            self.copy_ring(self.head, self.head + 1 & mask, i);
            self.head = self.head + 1 & mask;
        } else {
            self.copy_ring(at + 1 & mask, at, after);
        }
        self.len -= 1;
        return Some(v);
    }

    /// Removes the element at logical index `i` and moves the back element into its place: O(1), changes the
    /// order. None when `i >= len`.
    pub const fn swap_remove_back(self: &mut Deque<T, A>, i: usize) Option<T> {
        if i >= self.len {
            return None;
        }
        let at = self.slot(i);
        let v = unsafe self.ptr[at];
        self.len -= 1;
        if i != self.len {
            unsafe self.ptr[at] = unsafe self.ptr[self.slot(self.len)];
        }
        return Some(v);
    }

    /// Removes the element at logical index `i` and moves the front element into its place: O(1), changes the
    /// order. None when `i >= len`.
    pub const fn swap_remove_front(self: &mut Deque<T, A>, i: usize) Option<T> {
        if i >= self.len {
            return None;
        }
        let at = self.slot(i);
        let v = unsafe self.ptr[at];
        if i != 0 {
            unsafe self.ptr[at] = unsafe self.ptr[self.head];
        }
        self.head = self.head + 1 & self.cap - 1;
        self.len -= 1;
        return Some(v);
    }

    /// Keeps the first `n` elements and frees the others (no change when `n >= len`). Keeps the block.
    pub const fn truncate(self: &mut Deque<T, A>, n: usize) {
        let mut i = n;
        while i < self.len {
            unsafe self.ptr[self.slot(i)].free();
            i += 1;
        }
        if n < self.len {
            self.len = n;
        }
    }

    /// Frees every element and keeps the block.
    pub const fn clear(self: &mut Deque<T, A>) {
        self.truncate(0);
        self.head = 0;
    }

    /// Keeps the elements for which `pred` returns true, in order, and frees the others. `pred` borrows
    /// each element once, front to back.
    pub fn retain<F: fn(&T) bool>(self: &mut Deque<T, A>, pred: F) {
        let mut w: usize = 0;
        for r in 0..self.len {
            let at = self.slot(r);
            if pred(&unsafe self.ptr[at]) {
                if w != r {
                    unsafe self.ptr[self.slot(w)] = unsafe self.ptr[at];
                }
                w += 1;
            } else {
                unsafe self.ptr[at].free();
            }
        }
        self.len = w;
    }

    /// Moves the first `k` elements to the back, in order: O(min(k, len - k)). Panics when `k > len`.
    pub const fn rotate_left(self: &mut Deque<T, A>, k: usize) {
        if k > self.len {
            panic("Deque::rotate_left: count out of bounds");
        }
        if k == 0 || k == self.len {
            return;
        }
        if k <= self.len - k {
            self.copy_ring(self.head, self.slot(self.len), k);
            self.head = self.slot(k);
        } else {
            self.rotate_back(self.len - k);
        }
    }

    /// Moves the last `k` elements to the front, in order: O(min(k, len - k)). Panics when `k > len`.
    pub const fn rotate_right(self: &mut Deque<T, A>, k: usize) {
        if k > self.len {
            panic("Deque::rotate_right: count out of bounds");
        }
        if k == 0 || k == self.len {
            return;
        }
        if k <= self.len - k {
            self.rotate_back(k);
        } else {
            self.copy_ring(self.head, self.slot(self.len), self.len - k);
            self.head = self.slot(self.len - k);
        }
    }

    // Move the last `k` elements (0 < k < len) in front of the first.
    const fn rotate_back(self: &mut Deque<T, A>, k: usize) {
        self.head = self.head.wrapping_sub(k) & self.cap - 1;
        self.copy_ring(self.slot(self.len), self.head, k);
    }

    /// Moves every element of `other` to the back of this deque, in order; `other` is left empty with its
    /// block kept. O(other.len) amortized.
    pub fn append(self: &mut Deque<T, A>, other: &mut Deque<T, A>) {
        let n = other.len;
        if n == 0 {
            return;
        }
        self.reserve(n);
        let (a, b) = other.as_slices();
        self.copy_in(self.len, a);
        self.copy_in(self.len + a.len, b);
        self.len += n;
        other.len = 0;
        other.head = 0;
    }

    // Copy the elements of `src` bitwise to logical indexes `at..` (free slots, inside the capacity).
    const fn copy_in(self: &mut Deque<T, A>, at: usize, src: []T) {
        if sizeof(T) == 0 || src.len == 0 {
            return;
        }
        let start = self.slot(at);
        let first = src.len.min(self.cap - start);
        unsafe memcpy(self.ptr + start, src.ptr, first * sizeof(T));
        unsafe memcpy(self.ptr, src.ptr + first, (src.len - first) * sizeof(T));
    }

    /// The elements as two contiguous parts, front to back: the second is empty when the deque does not wrap.
    pub const fn as_slices(self: &Deque<T, A>) ([]T, []T) {
        return ring_parts(self.ptr, self.cap, self.head, 0, self.len);
    }

    /// The writable form of `as_slices`.
    pub const fn as_mut_slices(self: &mut Deque<T, A>) ([]mut T, []mut T) {
        return ring_parts_mut(self.ptr, self.cap, self.head, 0, self.len);
    }

    /// Moves the elements into one contiguous run, in order, and returns it: O(len), no allocation, no move
    /// when the deque does not wrap.
    pub const fn make_contiguous(self: &mut Deque<T, A>) []mut T {
        if self.head + self.len > self.cap {
            let p = self.ptr;
            let head_len = self.cap - self.head;
            let tail_len = self.len - head_len;
            let free = self.cap - self.len;
            if free >= head_len {
                // DEF..ABC -> ABCDEF..
                unsafe memmove(p + head_len, p, tail_len * sizeof(T));
                unsafe memcpy(p, p + self.head, head_len * sizeof(T));
                self.head = 0;
            } else if free >= tail_len {
                // EF..ABCD -> ..ABCDEF
                unsafe memmove(p + tail_len, p + self.head, head_len * sizeof(T));
                unsafe memcpy(p + self.len, p, tail_len * sizeof(T));
                self.head = tail_len;
            } else if head_len > tail_len {
                // FG.ABCDE -> .FGABCDE, then rotate the run left by the tail.
                unsafe memmove(p + free, p, tail_len * sizeof(T));
                rotate_raw(unsafe (p + free), self.len, tail_len);
                self.head = free;
            } else {
                // DEFG.ABC -> DEFGABC., then rotate the run right by the head part.
                unsafe memmove(p + tail_len, p + self.head, head_len * sizeof(T));
                rotate_raw(p, self.len, tail_len);
                self.head = 0;
            }
        }
        return unsafe SliceMut::<T> { ptr: self.ptr + self.head, len: self.len };
    }

    /// A borrowing iterator, front to back; double-ended, exact size.
    pub const fn iter(self: &Deque<T, A>) RingIter<T> {
        return RingIter::<T>::new(self.ptr, self.cap.wrapping_sub(1), self.head, self.len);
    }

    /// A mutably borrowing iterator, front to back; double-ended, exact size.
    pub const fn iter_mut(self: &mut Deque<T, A>) RingIterMut<T> {
        return RingIterMut::<T>::new(self.ptr, self.cap.wrapping_sub(1), self.head, self.len);
    }

    /// Moves every element out, front to back, through the returned iterator; the deque is empty from this
    /// call on and keeps its block. Dropping the drain frees the elements it did not yield.
    pub const fn drain(self: &mut Deque<T, A>) DequeDrain<T> {
        let d = DequeDrain::<T>::new(self.ptr, self.cap.wrapping_sub(1), self.head, self.len);
        self.len = 0;
        self.head = 0;
        return d;
    }
}

extend<T, A: Allocator + Default> Deque<T, A> {
    /// An empty deque on the default allocator; no allocation until the first push.
    pub const fn new() Deque<T, A> {
        return Deque::<T, A>::with_capacity_in(A::default(), 0);
    }

    /// An empty deque on the default allocator with room for `cap` elements, rounded up to a power of two.
    pub const fn with_capacity(cap: usize) Deque<T, A> {
        return Deque::<T, A>::with_capacity_in(A::default(), cap);
    }
}

extend<T: Eq, A: Allocator> Deque<T, A> {
    /// True when an element equals `x`; O(len).
    pub fn contains(self: &Deque<T, A>, x: &T) bool {
        for e in self.iter() {
            if e.eq(x) {
                return true;
            }
        }
        return false;
    }
}

extend<T: Ord, A: Allocator> Deque<T, A> {
    /// Binary search of a deque sorted in non-decreasing order: `Ok(i)` for an index of an element equal to
    /// `x`, else `Err(i)`, the index where inserting `x` keeps the order. O(log len); the result is
    /// unspecified when the deque is not sorted.
    pub fn binary_search(self: &Deque<T, A>, x: &T) Result<usize, usize> {
        let mut lo: usize = 0;
        let mut hi = self.len;
        while lo < hi {
            let mid = lo + (hi - lo) / 2;
            let c = (&unsafe self.ptr[self.slot(mid)]).cmp(x);
            if c == 0 {
                return Ok(mid);
            }
            if c < 0 {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return Err(lo);
    }
}

extend<T, const N: usize> RingBuffer<T, N> {
    /// An empty ring. A build error when N is not a power of two.
    pub const fn new() RingBuffer<T, N> {
        static_assert(N.is_power_of_two(), "RingBuffer capacity N must be a power of two");
        return unsafe zeroed::<RingBuffer<T, N>>(); // len 0: no slot is read or freed
    }

    /// Number of elements.
    pub const fn len(self: &RingBuffer<T, N>) usize {
        return self.len;
    }

    /// True when no element is stored.
    pub const fn is_empty(self: &RingBuffer<T, N>) bool {
        return self.len == 0;
    }

    /// True when N elements are stored.
    pub const fn is_full(self: &RingBuffer<T, N>) bool {
        return self.len == N;
    }

    /// Always N.
    pub const fn capacity(self: &RingBuffer<T, N>) usize {
        return N;
    }

    const fn ptr(self: &RingBuffer<T, N>) *const T {
        return &unsafe self.data[0];
    }

    const fn ptr_mut(self: &mut RingBuffer<T, N>) *mut T {
        return &mut unsafe self.data[0];
    }

    /// Appends `value` at the back; `Err(value)` gives it back when the ring is full.
    pub const fn push_back(self: &mut RingBuffer<T, N>, value: T) Result<Unit, T> {
        if self.len == N {
            return Err(value);
        }
        let p = self.ptr_mut();
        unsafe p[self.head + self.len & N - 1] = value;
        self.len += 1;
        return Ok(Unit {});
    }

    /// Appends `value` at the back. When the ring is full, the front element leaves to make room and moves
    /// to the caller; else None.
    pub const fn push_back_overwrite(self: &mut RingBuffer<T, N>, value: T) Option<T> {
        let p = self.ptr_mut();
        if self.len == N {
            let old = unsafe p[self.head];
            unsafe p[self.head] = value;
            self.head = self.head + 1 & N - 1;
            return Some(old);
        }
        unsafe p[self.head + self.len & N - 1] = value;
        self.len += 1;
        return None;
    }

    /// Prepends `value` at the front; `Err(value)` gives it back when the ring is full.
    pub const fn push_front(self: &mut RingBuffer<T, N>, value: T) Result<Unit, T> {
        if self.len == N {
            return Err(value);
        }
        self.head = self.head.wrapping_sub(1) & N - 1;
        let p = self.ptr_mut();
        unsafe p[self.head] = value;
        self.len += 1;
        return Ok(Unit {});
    }

    /// Removes the front element and moves it to the caller; None when empty.
    pub const fn pop_front(self: &mut RingBuffer<T, N>) Option<T> {
        if self.len == 0 {
            return None;
        }
        let p = self.ptr_mut();
        let v = unsafe p[self.head];
        self.head = self.head + 1 & N - 1;
        self.len -= 1;
        return Some(v);
    }

    /// Removes the back element and moves it to the caller; None when empty.
    pub const fn pop_back(self: &mut RingBuffer<T, N>) Option<T> {
        if self.len == 0 {
            return None;
        }
        self.len -= 1;
        let p = self.ptr_mut();
        return Some(unsafe p[self.head + self.len & N - 1]);
    }

    /// The front element; None when empty.
    pub const fn front(self: &RingBuffer<T, N>) Option<&T> {
        return self.get(0);
    }

    /// The back element; None when empty.
    pub const fn back(self: &RingBuffer<T, N>) Option<&T> {
        if self.len == 0 {
            return None;
        }
        return self.get(self.len - 1);
    }

    /// The element at logical index `i` (0 is the front); None when `i >= len`.
    pub const fn get(self: &RingBuffer<T, N>, i: usize) Option<&T> {
        if i >= self.len {
            return None;
        }
        return Some(&unsafe self.ptr()[self.head + i & N - 1]);
    }

    /// Frees every element.
    pub const fn clear(self: &mut RingBuffer<T, N>) {
        let p = self.ptr_mut();
        for i in 0..self.len {
            unsafe p[self.head + i & N - 1].free();
        }
        self.len = 0;
        self.head = 0;
    }

    /// A borrowing iterator, front to back; double-ended, exact size.
    pub const fn iter(self: &RingBuffer<T, N>) RingIter<T> {
        return RingIter::<T>::new(self.ptr(), N - 1, self.head, self.len);
    }
}

extend<'a, T> RingIter<'a, T> {
    const fn new(data: *const T, mask: usize, idx: usize, rem: usize) RingIter<'a, T> {
        return RingIter::<'a, T> { data: data, mask: mask, idx: idx, rem: rem };
    }
}

extend<'a, T> RingIter<'a, T> as Iterator<&'a T> {
    pub const fn next(self: &mut RingIter<'a, T>) Option<&'a T> {
        if self.rem == 0 {
            return None;
        }
        let r: &'a T = unsafe &*(self.data + self.idx);
        self.idx = self.idx + 1 & self.mask;
        self.rem -= 1;
        return Some(r);
    }

    pub const fn size_hint(self: &RingIter<'a, T>) (usize, Option<usize>) {
        return (self.rem, Option::<usize>::Some(self.rem));
    }
}

extend<'a, T> RingIter<'a, T> as DoubleEndedIterator<&'a T> {
    pub const fn next_back(self: &mut RingIter<'a, T>) Option<&'a T> {
        if self.rem == 0 {
            return None;
        }
        self.rem -= 1;
        return Some(unsafe &*(self.data + (self.idx + self.rem & self.mask)));
    }
}

extend<'a, T> RingIterMut<'a, T> {
    const fn new(data: *mut T, mask: usize, idx: usize, rem: usize) RingIterMut<'a, T> {
        return RingIterMut::<'a, T> { data: data, mask: mask, idx: idx, rem: rem };
    }
}

extend<'a, T> RingIterMut<'a, T> as Iterator<&'a mut T> {
    pub const fn next(self: &mut RingIterMut<'a, T>) Option<&'a mut T> {
        if self.rem == 0 {
            return None;
        }
        let r: &'a mut T = unsafe &mut *(self.data + self.idx);
        self.idx = self.idx + 1 & self.mask;
        self.rem -= 1;
        return Some(r);
    }

    pub const fn size_hint(self: &RingIterMut<'a, T>) (usize, Option<usize>) {
        return (self.rem, Option::<usize>::Some(self.rem));
    }
}

extend<'a, T> RingIterMut<'a, T> as DoubleEndedIterator<&'a mut T> {
    pub const fn next_back(self: &mut RingIterMut<'a, T>) Option<&'a mut T> {
        if self.rem == 0 {
            return None;
        }
        self.rem -= 1;
        return Some(unsafe &mut *(self.data + (self.idx + self.rem & self.mask)));
    }
}

extend<'a, T> DequeDrain<'a, T> {
    const fn new(data: *mut T, mask: usize, idx: usize, rem: usize) DequeDrain<'a, T> {
        return DequeDrain::<'a, T> { data: data, mask: mask, idx: idx, rem: rem };
    }
}

extend<T> DequeDrain<T> as Iterator<T> {
    pub const fn next(self: &mut DequeDrain<T>) Option<T> {
        if self.rem == 0 {
            return None;
        }
        let v = unsafe self.data[self.idx];
        self.idx = self.idx + 1 & self.mask;
        self.rem -= 1;
        return Some(v);
    }

    pub const fn size_hint(self: &DequeDrain<T>) (usize, Option<usize>) {
        return (self.rem, Option::<usize>::Some(self.rem));
    }
}

extend<T> DequeDrain<T> as DoubleEndedIterator<T> {
    pub const fn next_back(self: &mut DequeDrain<T>) Option<T> {
        if self.rem == 0 {
            return None;
        }
        self.rem -= 1;
        return Some(unsafe self.data[self.idx + self.rem & self.mask]);
    }
}

extend<T> DequeDrain<T> as Free {
    pub fn free(self: &mut DequeDrain<T>) {
        while self.rem > 0 {
            unsafe self.data[self.idx].free();
            self.idx = self.idx + 1 & self.mask;
            self.rem -= 1;
        }
    }
}

// Deep-free the elements, then return the block to `A`. Sound because the accessors borrow and the removers
// move the element out, so the block is the only owner of each live element.
extend<T, A: Allocator> Deque<T, A> as Free {
    pub fn free(self: &mut Deque<T, A>) {
        self.clear();
        if sizeof(T) != 0 && self.cap > 0 {
            unsafe self.alloc.dealloc(self.ptr, self.cap * sizeof(T), alignof(T));
        }
        self.ptr = dangling::<T>();
        self.cap = 0;
    }
}

extend<T, A: Allocator + Default> Deque<T, A> as Default {
    pub const fn default() Deque<T, A> {
        return Deque::<T, A>::new();
    }
}

// The slice borrows, so each element is cloned in.
extend<T: Clone, A: Allocator + Default> Deque<T, A> as From<[]T> {
    pub fn from(value: []T) Deque<T, A> {
        let mut out = Deque::<T, A>::with_capacity(value.len);
        for i in 0..value.len {
            out.push_back(value.at(i).clone());
        }
        return out;
    }
}

extend<T: Clone, A: Allocator> Deque<T, A> as Clone {
    /// A deep copy on a copy of the allocator handle: the elements are cloned in order into one run.
    pub fn clone(self: &Deque<T, A>) Deque<T, A> {
        let mut out = Deque::<T, A>::with_capacity_in(self.alloc, self.len);
        for e in self.iter() {
            out.push_back(e.clone());
        }
        return out;
    }
}

extend<T: Eq, A: Allocator> Deque<T, A> as Eq {
    pub fn eq(self: &Deque<T, A>, other: &Deque<T, A>) bool {
        return ring_eq(self.iter(), other.iter());
    }
}

extend<T: Hash, A: Allocator> Deque<T, A> as Hash {
    /// The length, then every element through its own `hash_into`, front to back.
    pub fn hash_into<H: Hasher>(self: &Deque<T, A>, h: &mut H) {
        ring_hash_into(self.iter(), h);
    }
}

extend<T: Format, A: Allocator> Deque<T, A> as Format {
    /// `[front, .., back]` with each element through its own `fmt`.
    pub fn fmt(self: &Deque<T, A>) String {
        return ring_fmt(self.iter());
    }
}

// `d[i]` borrows the element at logical index `i` and panics when `i >= len`. `d[lo..hi]` is the range as two
// contiguous parts, in order (the second is empty when the range does not wrap); it panics when the range
// does not lie in `0..len`.
extend<T, A: Allocator> Deque<T, A> as Index<T, RingSlices<T>> {
    pub const fn index(self: &Deque<T, A>, i: usize) &T {
        return self.at(i);
    }

    pub fn index_range(self: &Deque<T, A>, r: Range<usize>) RingSlices<T> {
        let hi = range_end(&r, self.len);
        let (a, b) = ring_parts(self.ptr, self.cap, self.head, r.start, hi);
        return (a, b);
    }
}

extend<T, A: Allocator> Deque<T, A> as IndexMut<T, RingSlicesMut<T>> {
    pub const fn index_mut(self: &mut Deque<T, A>, i: usize) &mut T {
        if i >= self.len {
            panic("Deque::at: index out of bounds");
        }
        return &mut unsafe self.ptr[self.slot(i)];
    }

    pub fn index_range_mut(self: &mut Deque<T, A>, r: Range<usize>) RingSlicesMut<T> {
        let hi = range_end(&r, self.len);
        let (a, b) = ring_parts_mut(self.ptr, self.cap, self.head, r.start, hi);
        return (a, b);
    }
}

// Deep-free the live elements. Conditional, as StaticVector's: there is no block to release, so a ring of
// plain values stays a plain value.
extend<T: Free, const N: usize> RingBuffer<T, N> as Free {
    pub fn free(self: &mut RingBuffer<T, N>) {
        self.clear();
    }
}

extend<T, const N: usize> RingBuffer<T, N> as Default {
    pub const fn default() RingBuffer<T, N> {
        return RingBuffer::<T, N>::new();
    }
}

// The slice borrows, so each element is cloned in. Panics when the slice holds more than N elements.
extend<T: Clone, const N: usize> RingBuffer<T, N> as From<[]T> {
    pub fn from(value: []T) RingBuffer<T, N> {
        if value.len > N {
            panic("RingBuffer::from: more than N elements");
        }
        let mut out = RingBuffer::<T, N>::new();
        let p = out.ptr_mut();
        for i in 0..value.len {
            unsafe p[i] = value.at(i).clone();
        }
        out.len = value.len;
        return out;
    }
}

extend<T: Clone, const N: usize> RingBuffer<T, N> as Clone {
    /// A deep copy: the elements are cloned in order, the front in slot 0.
    pub fn clone(self: &RingBuffer<T, N>) RingBuffer<T, N> {
        let mut out = RingBuffer::<T, N>::new();
        let p = out.ptr_mut();
        let mut i: usize = 0;
        for e in self.iter() {
            unsafe p[i] = e.clone();
            i += 1;
        }
        out.len = self.len;
        return out;
    }
}

extend<T: Eq, const N: usize> RingBuffer<T, N> as Eq {
    pub fn eq(self: &RingBuffer<T, N>, other: &RingBuffer<T, N>) bool {
        return ring_eq(self.iter(), other.iter());
    }
}

extend<T: Hash, const N: usize> RingBuffer<T, N> as Hash {
    /// The length, then every element through its own `hash_into`, front to back.
    pub fn hash_into<H: Hasher>(self: &RingBuffer<T, N>, h: &mut H) {
        ring_hash_into(self.iter(), h);
    }
}

extend<T: Format, const N: usize> RingBuffer<T, N> as Format {
    /// `[front, .., back]` with each element through its own `fmt`.
    pub fn fmt(self: &RingBuffer<T, N>) String {
        return ring_fmt(self.iter());
    }
}

// `r[i]` and `r[lo..hi]` as for Deque.
extend<T, const N: usize> RingBuffer<T, N> as Index<T, RingSlices<T>> {
    pub const fn index(self: &RingBuffer<T, N>, i: usize) &T {
        if i >= self.len {
            panic("RingBuffer[i]: index out of bounds");
        }
        return &unsafe self.ptr()[self.head + i & N - 1];
    }

    pub fn index_range(self: &RingBuffer<T, N>, r: Range<usize>) RingSlices<T> {
        let hi = range_end(&r, self.len);
        let (a, b) = ring_parts(self.ptr(), N, self.head, r.start, hi);
        return (a, b);
    }
}

extend<T, const N: usize> RingBuffer<T, N> as IndexMut<T, RingSlicesMut<T>> {
    pub const fn index_mut(self: &mut RingBuffer<T, N>, i: usize) &mut T {
        if i >= self.len {
            panic("RingBuffer[i]: index out of bounds");
        }
        let p = self.ptr_mut();
        return &mut unsafe p[self.head + i & N - 1];
    }

    pub fn index_range_mut(self: &mut RingBuffer<T, N>, r: Range<usize>) RingSlicesMut<T> {
        let hi = range_end(&r, self.len);
        let (a, b) = ring_parts_mut(self.ptr_mut(), N, self.head, r.start, hi);
        return (a, b);
    }
}
