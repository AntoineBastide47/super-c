// Slice<T> / SliceMut<T>: borrowed (ptr, len) views over a contiguous run of `T`. Non-owning; they
// never allocate or resize; the backing storage outlives them. `Slice<T>` is read-only; `SliceMut<T>`
// permits in-place writes and is exclusive like Rust's `&mut [T]` (not `Copy`). These are the prelude
// types `[]T` and `[]mut T` lower to (the `[]` sugar and array->slice coercion are wired separately);
// the two public fields make them plain fat pointers, so `s.ptr` / `s.len` read directly, with the
// methods mirroring the `str` / `Vector` surface. Building a view or writing a field needs `unsafe`.

/// A borrowed, read-only view over `len` consecutive `T` at `ptr`.
pub struct Slice<'a, T> {
    pub ptr: *const T, // first element
    pub len: usize, // number of elements
}

extend<T> Slice<T> {
    /// Number of elements (the field and this method are the same value).
    pub const fn len(self: &Slice<T>) usize {
        return self.len;
    }

    /// True when the view has no elements.
    pub const fn is_empty(self: &Slice<T>) bool {
        return self.len == 0;
    }

    /// Bounds-checked borrow of the element at `i`: panics when `i >= len`. Returns `&T` (not `T` by
    /// value): a by-value copy would duplicate ownership of a `Free` element and double-free it.
    pub const fn get(self: &Slice<T>, i: usize) &T {
        if i >= self.len {
            panic("Slice::get: index out of bounds");
        }
        return &unsafe self.ptr[i];
    }

    /// Bounds-checked borrow: panics when `i >= len`.
    pub const fn at(self: &Slice<T>, i: usize) &T {
        if i >= self.len {
            panic("Slice::at: index out of bounds");
        }
        return &unsafe self.ptr[i];
    }

    /// Unchecked borrow: the caller PROVES `i < len` (hot loops with an established bound). Out of
    /// range is undefined behavior, hence `unsafe`.
    pub unsafe const fn get_unsafe(self: &Slice<T>, i: usize) &T {
        return &self.ptr[i];
    }

    /// Bounds-checked borrow: `Some(&elem)` when `i < len`, else `None`.
    pub const fn get_checked(self: &Slice<T>, i: usize) Option<&T> {
        if i >= self.len {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&unsafe self.ptr[i]);
    }

    /// Borrows the first element; panics when the slice is empty.
    pub const fn first(self: &Slice<T>) &T {
        if self.len == 0 {
            panic("Slice::first on an empty slice");
        }
        return &unsafe self.ptr[0];
    }

    /// Borrows the last element; panics when the slice is empty.
    pub const fn last(self: &Slice<T>) &T {
        if self.len == 0 {
            panic("Slice::last on an empty slice");
        }
        return &unsafe self.ptr[self.len - 1];
    }

    /// A read-only pointer to the first element (the view's backing storage).
    pub const fn as_ptr(self: &Slice<T>) *const T {
        return self.ptr;
    }
}

/// A borrowed, writable view over `len` consecutive `T` at `ptr`.
pub struct SliceMut<'a, T> {
    pub ptr: *mut T, // first element
    pub len: usize, // number of elements
}

extend<T> SliceMut<T> {
    /// Number of elements in the view.
    pub const fn len(self: &SliceMut<T>) usize {
        return self.len;
    }

    pub const fn is_empty(self: &SliceMut<T>) bool {
        return self.len == 0;
    }

    /// Bounds-checked borrow: panics when `i >= len`. Returns `&T` (not `T` by value) so a `Free`
    /// element is never copied out into a second owner.
    pub const fn get(self: &SliceMut<T>, i: usize) &T {
        if i >= self.len {
            panic("SliceMut::get: index out of bounds");
        }
        return &unsafe self.ptr[i];
    }

    /// Bounds-checked borrow: panics when `i >= len`.
    pub const fn at(self: &SliceMut<T>, i: usize) &T {
        if i >= self.len {
            panic("SliceMut::at: index out of bounds");
        }
        return &unsafe self.ptr[i];
    }

    /// Unchecked borrow: the caller PROVES `i < len` (hot loops with an established bound). Out of
    /// range is undefined behavior, hence `unsafe`.
    pub unsafe const fn get_unsafe(self: &SliceMut<T>, i: usize) &T {
        return &self.ptr[i];
    }

    /// Bounds-checked shared borrow: `Some(&elem)` when `i < len`, else `None`.
    pub const fn get_checked(self: &SliceMut<T>, i: usize) Option<&T> {
        if i >= self.len {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&unsafe self.ptr[i]);
    }

    /// Overwrite the element at `i`, freeing the replaced one: panics when `i >= len`. Takes the view by
    /// value, as a call argument does: it is reborrowed for the call, so it needs no `mut` binding, and a
    /// live borrow of an element from `get` rejects the call, as it rejects `s[i] = v`.
    pub const fn set(self: SliceMut<T>, i: usize, value: T) {
        if i >= self.len {
            panic("SliceMut::set: index out of bounds");
        }
        // A store through the raw pointer frees nothing, so the replaced element is freed first.
        unsafe self.ptr[i].free();
        unsafe self.ptr[i] = value;
    }

    /// Borrows the first element; panics when the slice is empty.
    pub const fn first(self: &SliceMut<T>) &T {
        if self.len == 0 {
            panic("SliceMut::first on an empty slice");
        }
        return &unsafe self.ptr[0];
    }

    /// Borrows the last element; panics when the slice is empty.
    pub const fn last(self: &SliceMut<T>) &T {
        if self.len == 0 {
            panic("SliceMut::last on an empty slice");
        }
        return &unsafe self.ptr[self.len - 1];
    }

    /// Pointer to the first element; never dereferenced for an empty view.
    pub const fn as_ptr(self: &SliceMut<T>) *const T {
        return self.ptr;
    }

    /// Takes `&self` for the same reason as `set`: the mutable view exposes its `*mut T` without needing a
    /// mutable binding, so `[]mut T` value parameters can hand the pointer to FFI without a redundant `mut`.
    pub const fn as_mut_ptr(self: &SliceMut<T>) *mut T {
        return self.ptr;
    }
}

// Index conformances: the `[]` operator on a view calls them. Bounds-checked (panic) like the rest of
// the surface; `get_unsafe` is the unchecked tier. `index_range` honors the written bounds: `..=`
// includes `r.end`; an open end arrives as `len()`. A shared view's element and sub-view borrow what
// the view borrows, not the view itself.
extend<T> Slice<T> as Index<T, []T> {
    pub const fn index<'a>(self: &Slice<'a, T>, i: usize) &'a T {
        if i >= self.len {
            panic_parts(type_info::<Self>().qualified_name, "[i]: index out of bounds");
        }
        return &unsafe self.ptr[i];
    }
    @always_inline
    pub const fn index_range<'a>(self: &Slice<'a, T>, r: Range<usize>) []'a T {
        // An inclusive end validates before `end + 1`, so `end == usize::MAX` cannot wrap past the
        // check. One comparison per guard: the bounds-check pass removes each it proves.
        let hi = if r.inclusive {
            if r.end >= self.len {
                panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
            }
            r.end + 1;
        } else {
            r.end;
        };
        if hi > self.len {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        if r.start > hi {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        return unsafe Slice::<T> { ptr: self.ptr + r.start, len: hi - r.start };
    }
}

extend<T> SliceMut<T> as Index<T, []T> {
    pub const fn index(self: &SliceMut<T>, i: usize) &T {
        if i >= self.len {
            panic_parts(type_info::<Self>().qualified_name, "[i]: index out of bounds");
        }
        return &unsafe self.ptr[i];
    }
    @always_inline
    pub const fn index_range(self: &SliceMut<T>, r: Range<usize>) []T {
        // An inclusive end validates before `end + 1`, so `end == usize::MAX` cannot wrap past the
        // check. One comparison per guard: the bounds-check pass removes each it proves.
        let hi = if r.inclusive {
            if r.end >= self.len {
                panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
            }
            r.end + 1;
        } else {
            r.end;
        };
        if hi > self.len {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        if r.start > hi {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        return unsafe Slice::<T> { ptr: self.ptr + r.start, len: hi - r.start };
    }
}

extend<T> SliceMut<T> as IndexMut<T, []mut T> {
    pub const fn index_mut(self: &mut SliceMut<T>, i: usize) &mut T {
        if i >= self.len {
            panic_parts(type_info::<Self>().qualified_name, "[i]: index out of bounds");
        }
        return &mut unsafe self.ptr[i];
    }
    @always_inline
    pub const fn index_range_mut(self: &mut SliceMut<T>, r: Range<usize>) []mut T {
        // An inclusive end validates before `end + 1`, so `end == usize::MAX` cannot wrap past the
        // check. One comparison per guard: the bounds-check pass removes each it proves.
        let hi = if r.inclusive {
            if r.end >= self.len {
                panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
            }
            r.end + 1;
        } else {
            r.end;
        };
        if hi > self.len {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        if r.start > hi {
            panic_parts(type_info::<Self>().qualified_name, "[a..b]: range out of bounds");
        }
        return unsafe SliceMut::<T> { ptr: self.ptr + r.start, len: hi - r.start };
    }
}

// ---- Shared sequence algorithms ------------------------------------------------------------------------
//
// One implementation of sorting, selection, heaps, searching and rearrangement serves every contiguous
// container: `Vector`, `Array` and `StaticVector` call these through their views. The algorithms move
// elements bitwise through raw pointers and never copy one: a slot read hands its value to exactly one
// destination. A comparator that panics aborts the process (there is no unwinding), so no caller can
// observe a partly moved sequence.
//
// Complexity (n = length; the bounds are the C++ <algorithm> requirements or better):
//   sort, sort_by, sort_by_key        O(n log n) comparisons in the worst case, O(n) on sorted, reversed
//                                     or all-equal input; not stable; no allocation; O(log n) stack.
//   sort_stable*                      O(n log n) comparisons in the worst case, O(n) on sorted or
//                                     strictly reversed input; stable; one scratch block of n elements.
//                                     Builtin integers in their natural order: O(n) (radix).
//   sort_stable_in_place*             O(n log n) comparisons and O(n log^2 n) moves in the worst case,
//                                     O(n) on sorted or strictly reversed input; stable; no heap memory
//                                     (a 4 KiB stack buffer); O(log n) stack.
//   select_nth_unstable*              O(n) comparisons on average and in the worst case; no allocation.
//   heapify / push_heap / pop_heap    O(n) / O(log n) / O(log n); sort_heap O(n log n).
//   binary_search*, partition_point   O(log n) comparisons; the sequence must be ordered by the same key.
//   partition                         O(n) predicate calls, each element moved at most once; not stable.
//   partition_dedup*                  O(n) comparisons; keeps the first of each run of equal elements.
//   reverse, rotate_left, rotate_right   O(n) moves.
//
// Sorting is pattern-defeating quicksort (Peters, arXiv:2106.05123): insertion sort below 21 elements,
// a median-of-three or Tukey-ninther pivot, a branchless Lomuto partition with a moving gap for elements
// up to 96 bytes and a Hoare partition above, an equal-elements partition when the pivot equals the
// previous one, pattern breaking after an unbalanced partition, and heapsort once the bad partitions
// exceed log2(n), which bounds the worst case. The stable sort is a bottom-up merge sort between the
// input and a scratch block: insertion sorted blocks of 16, then passes that merge equal runs from both
// ends at once (two independent comparison chains), skip pairs already in order, and select every
// source without a branch; integers in their natural order take a least-significant-digit radix sort
// instead from 512 elements. The in-place stable sort is blitsort's rotate quicksort (van den Hoven):
// a stable partition through a 4 KiB stack buffer around a median of 9 or of about n^(1/3) samples,
// halves joined by one rotation when a run exceeds the buffer, rotations through the buffer when a side
// or the sides' difference fits it, and a strict split that ends every copy of a repeated pivot. Runs up
// to 96 elements, runs of mostly one key and runs past 2 log2(n) levels take an in-place merge sort
// whose long merges split by symmetric comparisons and rotate (Kim and Kutzner, ESA 2004). Selection is introselect: quickselect with the same partitions, falling back
// to the median of medians (Blum et al., 1973) for a linear
// worst case.

const SORT_INSERTION_MAX: usize = 20; // at or below this length, insertion sort
const SORT_NINTHER_MIN: usize = 50; // from this length the pivot is Tukey's ninther
const SORT_PIVOT_SWAPS_MAX: usize = 12; // every pivot comparison swapped: the input looks descending
const SORT_PARTIAL_STEPS: usize = 5; // out-of-order pairs a partial insertion sort fixes before giving up
const SORT_PARTIAL_SHIFT_MIN: usize = 50; // below this length a partial insertion sort does not shift
const SORT_LOMUTO_SIZE_MAX: usize = 96; // largest element the branchless partition moves twice per step
const STABLE_BLOCK: usize = 16; // the stable sort insertion sorts blocks of this length before merging
const STABLE_STACK_BYTES: usize = 4096; // the in-place stable sort's and rotations' stack buffer
const ROTATE_DIRECT_BYTES: usize = 256; // a rotation of at most this many bytes uses no buffer
const STABLE_QUICK_MIN: usize = 96; // at or below this length the in-place stable sort merges
const STABLE_SAMPLE_MIN: usize = 2048; // above this length the in-place pivot is a median of n^(1/3) samples
const SORT_RADIX_MIN: usize = 512; // from this length a stable sort of integers in their order is a radix sort
const SELECT_SMALL: usize = 10; // at or below this length, selection sorts

// The strict order a sort follows: `lt(a, b)` when `a` goes before `b`. Passed by value through the
// recursion, so every comparison is a direct call the C compiler inlines.
interface SortLess<T>: Copy {
    fn lt(self: Self, a: &T, b: &T) bool;
}

// The natural order of `Ord`.
@derive(Copy)
struct OrdLess {}

extend<T: Ord> OrdLess as SortLess<T> {
    @always_inline
    pub fn lt(self: OrdLess, a: &T, b: &T) bool {
        return *a < *b;
    }
}

// The order of a three-way comparator: negative means before.
struct CmpLess<F> {
    pub f: F,
}

extend<T, F: fn(&T, &T) i32> CmpLess<F> as SortLess<T> {
    @always_inline
    pub fn lt(self: CmpLess<F>, a: &T, b: &T) bool {
        return self.f(a, b) < 0;
    }
}

// The order of a key.
struct KeyLess<K, F> {
    pub f: F,
}

extend<T, K: Ord, F: fn(&T) K> KeyLess<K, F> as SortLess<T> {
    @always_inline
    pub fn lt(self: KeyLess<K, F>, a: &T, b: &T) bool {
        return self.f(a) < self.f(b);
    }
}

// The predicate a partition pass splits by: elements that pass go first.
interface SortPred<T>: Copy {
    fn test(self: Self, x: &T) bool;
}

// Less than the pivot.
struct BelowPivot<T, L> {
    pub p: *const T,
    pub less: L,
}

extend<T, L: SortLess<T>> BelowPivot<T, L> as SortPred<T> {
    @always_inline
    pub fn test(self: BelowPivot<T, L>, x: &T) bool {
        return self.less.lt(x, &unsafe self.p[0]);
    }
}

// Not greater than the pivot.
struct UpToPivot<T, L> {
    pub p: *const T,
    pub less: L,
}

extend<T, L: SortLess<T>> UpToPivot<T, L> as SortPred<T> {
    @always_inline
    pub fn test(self: UpToPivot<T, L>, x: &T) bool {
        return !self.less.lt(&unsafe self.p[0], x);
    }
}

// A caller's predicate.
struct FnPred<P> {
    pub f: P,
}

extend<T, P: fn(&T) bool> FnPred<P> as SortPred<T> {
    @always_inline
    pub fn test(self: FnPred<P>, x: &T) bool {
        return self.f(x);
    }
}

// Where an element lies from the target of a search: negative before it, zero on it, positive after.
interface SortProbe<T>: Copy {
    fn probe(self: Self, e: &T) i32;
}

// A caller's probe.
struct FnProbe<F> {
    pub f: F,
}

extend<T, F: fn(&T) i32> FnProbe<F> as SortProbe<T> {
    @always_inline
    pub fn probe(self: FnProbe<F>, e: &T) i32 {
        return self.f(e);
    }
}

// The target `x` in the natural order.
struct OrdProbe<T> {
    pub x: *const T,
}

extend<T: Ord> OrdProbe<T> as SortProbe<T> {
    @always_inline
    pub fn probe(self: OrdProbe<T>, e: &T) i32 {
        return e.cmp(&unsafe self.x[0]);
    }
}

// The target key in the order of a key.
struct KeyProbe<K, F> {
    pub key: *const K,
    pub f: F,
}

extend<T, K: Ord, F: fn(&T) K> KeyProbe<K, F> as SortProbe<T> {
    @always_inline
    pub fn probe(self: KeyProbe<K, F>, e: &T) i32 {
        return self.f(e).cmp(&unsafe self.key[0]);
    }
}

// Whether two adjacent elements belong to one run of a deduplication.
interface SortSame<T>: Copy {
    fn same(self: Self, earlier: &T, later: &T) bool;
}

// Equality of `Eq`.
@derive(Copy)
struct EqSame {}

extend<T: Eq> EqSame as SortSame<T> {
    @always_inline
    pub fn same(self: EqSame, earlier: &T, later: &T) bool {
        return *earlier == *later;
    }
}

// A caller's relation.
struct FnSame<F> {
    pub f: F,
}

extend<T, F: fn(&T, &T) bool> FnSame<F> as SortSame<T> {
    @always_inline
    pub fn same(self: FnSame<F>, earlier: &T, later: &T) bool {
        return self.f(earlier, later);
    }
}

// Equal keys.
struct KeySame<K, F> {
    pub f: F,
}

extend<T, K: Eq, F: fn(&T) K> KeySame<K, F> as SortSame<T> {
    @always_inline
    pub fn same(self: KeySame<K, F>, earlier: &T, later: &T) bool {
        return self.f(earlier) == self.f(later);
    }
}

// Exchange two slots.
const fn sort_swap<T>(a: *mut T, b: *mut T) {
    unsafe {
        let t = a[0];
        a[0] = b[0];
        b[0] = t;
    }
}

// Reverse `v[0..n)`.
const fn seq_reverse<T>(v: *mut T, n: usize) {
    if n < 2 {
        return;
    }
    let mut i: usize = 0;
    let mut j = n - 1;
    while i < j {
        sort_swap(unsafe (v + i), unsafe (v + j));
        i += 1;
        j -= 1;
    }
}

// Insert `v[i]` into the sorted prefix `v[0..i)`, after every element it does not precede (stable).
fn sort_insert_tail<T, L: SortLess<T>>(v: *mut T, i: usize, less: L) {
    unsafe {
        if !less.lt(&v[i], &v[i - 1]) {
            return;
        }
        let tmp = v[i];
        let mut j = i;
        v[j] = v[j - 1];
        j -= 1;
        while j > 0 && less.lt(&tmp, &v[j - 1]) {
            v[j] = v[j - 1];
            j -= 1;
        }
        v[j] = tmp;
    }
}

// Insert `v[0]` into the sorted suffix `v[1..n)`, before every element that does not precede it (stable).
fn sort_insert_head<T, L: SortLess<T>>(v: *mut T, n: usize, less: L) {
    unsafe {
        if n < 2 || !less.lt(&v[1], &v[0]) {
            return;
        }
        let tmp = v[0];
        v[0] = v[1];
        let mut j: usize = 1;
        while j + 1 < n && less.lt(&v[j + 1], &tmp) {
            v[j] = v[j + 1];
            j += 1;
        }
        v[j] = tmp;
    }
}

fn sort_insertion<T, L: SortLess<T>>(v: *mut T, n: usize, less: L) {
    for i in 1..n {
        sort_insert_tail(v, i, less);
    }
}

// Restore the max-heap order of `v[0..n)` below `root` by moving the hole down to a leaf along the
// larger children, then the value back up (Floyd): about log2(n) comparisons instead of 2 * log2(n).
fn heap_sift_down<T, L: SortLess<T>>(v: *mut T, n: usize, root: usize, less: L) {
    unsafe {
        let x = v[root];
        let mut i = root;
        let mut c = 2 * i + 1;
        while c < n {
            if c + 1 < n && less.lt(&v[c], &v[c + 1]) {
                c += 1;
            }
            v[i] = v[c];
            i = c;
            c = 2 * i + 1;
        }
        while i > root {
            let parent = (i - 1) / 2;
            if !less.lt(&v[parent], &x) {
                break;
            }
            v[i] = v[parent];
            i = parent;
        }
        v[i] = x;
    }
}

// Move `v[i]` up the max-heap `v[0..i]`.
fn heap_sift_up<T, L: SortLess<T>>(v: *mut T, i0: usize, less: L) {
    unsafe {
        let x = v[i0];
        let mut i = i0;
        while i > 0 {
            let parent = (i - 1) / 2;
            if !less.lt(&v[parent], &x) {
                break;
            }
            v[i] = v[parent];
            i = parent;
        }
        v[i] = x;
    }
}

fn heap_make<T, L: SortLess<T>>(v: *mut T, n: usize, less: L) {
    let mut i = n / 2;
    while i > 0 {
        i -= 1;
        heap_sift_down(v, n, i, less);
    }
}

// Move the largest element of the heap `v[0..n)` to `v[n - 1]`; `v[0..n - 1)` stays a heap.
fn heap_pop<T, L: SortLess<T>>(v: *mut T, n: usize, less: L) {
    if n < 2 {
        return;
    }
    sort_swap(v, unsafe (v + (n - 1)));
    heap_sift_down(v, n - 1, 0, less);
}

fn heap_sort<T, L: SortLess<T>>(v: *mut T, n: usize, less: L) {
    let mut end = n;
    while end > 1 {
        heap_pop(v, end, less);
        end -= 1;
    }
}

// Order three indices so `v[b]` is their median, counting the swaps of indices.
fn sort_order3<T, L: SortLess<T>>(v: *mut T, a: &mut usize, b: &mut usize, c: &mut usize, swaps: &mut usize, less: L) {
    if less.lt(&unsafe v[*b], &unsafe v[*a]) {
        let t = *a;
        *a = *b;
        *b = t;
        *swaps += 1;
    }
    if less.lt(&unsafe v[*c], &unsafe v[*b]) {
        let t = *b;
        *b = *c;
        *c = t;
        *swaps += 1;
    }
    if less.lt(&unsafe v[*b], &unsafe v[*a]) {
        let t = *a;
        *a = *b;
        *b = t;
        *swaps += 1;
    }
}

// A pivot index for `v[0..n)` and how many pivot comparisons swapped: none means the input looks
// ascending, SORT_PIVOT_SWAPS_MAX or more that it looks descending.
fn sort_choose_pivot<T, L: SortLess<T>>(v: *mut T, n: usize, less: L) (usize, usize) {
    let q = n / 4;
    let mut a = q;
    let mut b = q * 2;
    let mut c = q * 3;
    let mut swaps: usize = 0;
    if n >= 8 {
        if n >= SORT_NINTHER_MIN {
            // Tukey's ninther: each of the three becomes the median of itself and its neighbours.
            let mut lo = a - 1;
            let mut hi = a + 1;
            sort_order3(v, &mut lo, &mut a, &mut hi, &mut swaps, less);
            lo = b - 1;
            hi = b + 1;
            sort_order3(v, &mut lo, &mut b, &mut hi, &mut swaps, less);
            lo = c - 1;
            hi = c + 1;
            sort_order3(v, &mut lo, &mut c, &mut hi, &mut swaps, less);
        }
        sort_order3(v, &mut a, &mut b, &mut c, &mut swaps, less);
    }
    return b, swaps;
}

// Swap three elements at pseudo-random positions around the middle: after an unbalanced partition this
// breaks the patterns an adversary or a regular input built for the pivot rule.
const fn sort_break_patterns<T>(v: *mut T, n: usize) {
    if n < 8 {
        return;
    }
    let mut seed = n as u64;
    let mut mask: usize = 1;
    while mask < n {
        mask = mask << 1;
    }
    mask -= 1;
    let pos = n / 4 * 2;
    for i in 0..3usize {
        // xorshift64
        seed = seed ^ seed << 13;
        seed = seed ^ seed >> 7;
        seed = seed ^ seed << 17;
        let mut other = seed as usize & mask;
        if other >= n {
            other -= n;
        }
        sort_swap(unsafe (v + (pos - 1 + i)), unsafe (v + other));
    }
}

// Sort a nearly sorted `v[0..n)` by fixing at most a few out-of-order pairs: true when it is sorted.
fn sort_partial_insertion<T, L: SortLess<T>>(v: *mut T, n: usize, less: L) bool {
    let mut i: usize = 1;
    for _ in 0..SORT_PARTIAL_STEPS {
        while i < n && !less.lt(&unsafe v[i], &unsafe v[i - 1]) {
            i += 1;
        }
        if i == n {
            return true;
        }
        if n < SORT_PARTIAL_SHIFT_MIN {
            return false;
        }
        sort_swap(unsafe (v + (i - 1)), unsafe (v + i));
        if i >= 2 {
            sort_insert_tail(v, i - 1, less);
        }
        sort_insert_head(unsafe (v + i), n - i, less);
    }
    return false;
}

// Move the elements of `v[0..n)` that satisfy `left` before the others, by a branchless Lomuto pass:
// the slot of the first element is a gap that walks right, so each step is two moves and no branch.
// Returns how many satisfy `left`. `left` must not read `v`.
fn part_lomuto<T, P: SortPred<T>>(v: *mut T, n: usize, left: P) usize {
    if n == 0 {
        return 0;
    }
    unsafe {
        let first = v[0];
        let mut lt: usize = 0;
        for i in 1..n {
            let is_left = left.test(&v[i]);
            v[i - 1] = v[lt];
            v[lt] = v[i];
            lt += is_left as usize;
        }
        let is_left = left.test(&first);
        v[n - 1] = v[lt];
        v[lt] = first;
        lt += is_left as usize;
        return lt;
    }
}

// The same split by a Hoare pass that moves only misplaced elements: for large elements, where two
// moves per element cost more than the mispredicted branches.
fn part_hoare<T, P: SortPred<T>>(v: *mut T, n: usize, left: P) usize {
    let mut l: usize = 0;
    let mut r = n;
    loop {
        while l < r && left.test(&unsafe v[l]) {
            l += 1;
        }
        while l < r && !left.test(&unsafe v[r - 1]) {
            r -= 1;
        }
        if l >= r {
            return l;
        }
        r -= 1;
        sort_swap(unsafe (v + l), unsafe (v + r));
        l += 1;
    }
}

// The Hoare pass on a range whose first element does not satisfy `left` and whose last does (so n >= 2):
// each swap leaves a sentinel at both ends, so the scans need no bounds check.
fn part_hoare_unguarded<T, P: SortPred<T>>(v: *mut T, n: usize, left: P) usize {
    let mut l: usize = 0;
    let mut r = n;
    loop {
        r -= 1;
        sort_swap(unsafe (v + l), unsafe (v + r));
        l += 1;
        while left.test(&unsafe v[l]) {
            l += 1;
        }
        while !left.test(&unsafe v[r - 1]) {
            r -= 1;
        }
        if l >= r {
            return l;
        }
    }
}

// Partition `v[0..n)` around the pivot at `pi`: the elements less than it, the pivot at the returned
// index, the rest. Also reports whether the input was already partitioned.
// With `hoare`, the Hoare pass: on descending input it swaps mirror pairs, so both sides come out
// ascending, where the gap pass would move every element.
fn sort_partition_by<T, L: SortLess<T>>(v: *mut T, n: usize, pi: usize, less: L, hoare: bool) (usize, bool) {
    sort_swap(v, unsafe (v + pi));
    let rest = unsafe (v + 1);
    let m = n - 1;
    let mut l: usize = 0;
    while l < m && less.lt(&unsafe rest[l], &unsafe v[0]) {
        l += 1;
    }
    let mut r = m;
    while l < r && !less.lt(&unsafe rest[r - 1], &unsafe v[0]) {
        r -= 1;
    }
    // The scans above stopped at an element that belongs right and one that belongs left: the Hoare pass
    // runs unguarded between them.
    let pred = BelowPivot::<T, L> { p: v, less: less };
    let mut mid = l;
    if l < r {
        if hoare || sizeof(T) > SORT_LOMUTO_SIZE_MAX {
            mid = l + part_hoare_unguarded(unsafe (rest + l), r - l, pred);
        } else {
            mid = l + part_lomuto(unsafe (rest + l), r - l, pred);
        }
    }
    sort_swap(v, unsafe (v + mid));
    return mid, l >= r;
}

// Partition `v[0..n)` around the pivot at `pi` known to equal every element not greater than it (the
// previous pivot is not less than it): the elements equal to it first. Returns how many, pivot
// included.
fn sort_partition_equal<T, L: SortLess<T>>(v: *mut T, n: usize, pi: usize, less: L) usize {
    sort_swap(v, unsafe (v + pi));
    return 1 + part_lomuto(unsafe (v + 1), n - 1, UpToPivot::<T, L> { p: v, less: less });
}

// Pattern-defeating quicksort of `v[0..n)`. `pred` is null or the pivot just left of the range, which is
// not greater than any element in it. After `limit` unbalanced partitions the rest is heapsorted.
fn sort_pdq<T, L: SortLess<T>>(v0: *mut T, n0: usize, less: L, pred0: *const T, limit0: u32) {
    let mut v = v0;
    let mut n = n0;
    let mut pred = pred0;
    let mut limit = limit0;
    let mut was_balanced = true;
    let mut was_partitioned = true;
    loop {
        if n <= SORT_INSERTION_MAX {
            sort_insertion(v, n, less);
            return;
        }
        if limit == 0 {
            heap_make(v, n, less);
            heap_sort(v, n, less);
            return;
        }
        if !was_balanced {
            sort_break_patterns(v, n);
            limit -= 1;
        }
        let (pi0, swaps) = sort_choose_pivot(v, n, less);
        let mut pi = pi0;
        let mut likely_sorted = swaps == 0;
        if swaps >= SORT_PIVOT_SWAPS_MAX {
            // Descending input: reversed, it is ascending.
            seq_reverse(v, n);
            pi = n - 1 - pi0;
            likely_sorted = true;
        }
        if was_balanced && was_partitioned && likely_sorted && sort_partial_insertion(v, n, less) {
            return;
        }
        if pred != null && !less.lt(&unsafe pred[0], &unsafe v[pi]) {
            let k = sort_partition_equal(v, n, pi, less);
            v = unsafe (v + k);
            n -= k;
            continue;
        }
        let (mid, part) = sort_partition_by(v, n, pi, less, false);
        let right_n = n - mid - 1;
        was_balanced = mid.min(right_n) >= n / 8;
        was_partitioned = part;
        // Recurse into the shorter side and loop on the longer one: O(log n) stack.
        if mid < right_n {
            sort_pdq(v, mid, less, pred, limit);
            pred = unsafe (v + mid);
            v = unsafe (v + (mid + 1));
            n = right_n;
        } else {
            sort_pdq(unsafe (v + (mid + 1)), right_n, less, unsafe (v + mid), limit);
            n = mid;
        }
    }
}

fn sort_unstable<T, L: SortLess<T>>(v: *mut T, n: usize, less: L) {
    if sizeof(T) == 0 || n < 2 {
        return;
    }
    let limit = 64 - (n as u64).leading_zeros() as u32;
    sort_pdq(v, n, less, null, limit);
}

// Merge the equal-length runs `a[0..m)` and `b[0..m)` into `d[0..2m)`, stable, from both ends at once:
// the front takes the m smallest and the back the m largest, so neither side needs a bounds check and
// the two selections are independent chains the processor overlaps (the parity merge of quadsort).
fn stable_parity_merge<T, L: SortLess<T>>(a: *const T, b: *const T, m: usize, d: *mut T, less: L) {
    unsafe {
        let mut l: usize = 0;
        let mut r: usize = 0;
        let mut out: usize = 0;
        let mut tl = m as isize - 1;
        let mut tr = m as isize - 1;
        let mut tout = 2 * m - 1;
        for _ in 0..m {
            let take_b = less.lt(&b[r], &a[l]);
            let src = if take_b {
                b + r;
            } else {
                a + l;
            };
            memcpy(d + out, src, sizeof(T));
            r += take_b as usize;
            l += (!take_b) as usize;
            out += 1;
            let take_a = less.lt(&b[tr as usize], &a[tl as usize]);
            let tsrc = if take_a {
                a + tl as usize;
            } else {
                b + tr as usize;
            };
            memcpy(d + tout, tsrc, sizeof(T));
            tl -= take_a as isize;
            tr -= (!take_a) as isize;
            tout -= 1;
        }
    }
}

// Merge the runs `a[0..la)` and `b[0..lb)` into `d`, stable: an element of `b` goes first only when it
// is less. The loop selects its source without a branch.
fn stable_merge_into<T, L: SortLess<T>>(a: *const T, la: usize, b: *const T, lb: usize, d: *mut T, less: L) {
    unsafe {
        let mut l: usize = 0;
        let mut r: usize = 0;
        let mut out: usize = 0;
        while l < la && r < lb {
            let take_b = less.lt(&b[r], &a[l]);
            let src = if take_b {
                b + r;
            } else {
                a + l;
            };
            memcpy(d + out, src, sizeof(T));
            r += take_b as usize;
            l += (!take_b) as usize;
            out += 1;
        }
        memcpy(d + out, a + l, (la - l) * sizeof(T));
        memcpy(d + (out + la - l), b + r, (lb - r) * sizeof(T));
    }
}

// Merge the sorted runs `v[0..mid)` and `v[mid..n)` in place through `buf`, which holds the shorter run,
// stable: the shorter run moves to `buf`, then the merge fills `v` from the end the other run does not
// occupy. The loop selects its source without a branch.
fn stable_merge<T, L: SortLess<T>>(v: *mut T, n: usize, mid: usize, buf: *mut T, less: L) {
    unsafe {
        if mid <= n - mid {
            memcpy(buf, v, mid * sizeof(T));
            let mut out: usize = 0;
            let mut l: usize = 0;
            let mut r = mid;
            while l < mid && r < n {
                let take_r = less.lt(&v[r], &buf[l]);
                let src = if take_r {
                    v + r;
                } else {
                    buf + l;
                };
                memcpy(v + out, src, sizeof(T));
                r += take_r as usize;
                l += (!take_r) as usize;
                out += 1;
            }
            memcpy(v + out, buf + l, (mid - l) * sizeof(T));
        } else {
            let rn = n - mid;
            memcpy(buf, v + mid, rn * sizeof(T));
            let mut out = n;
            let mut l = mid;
            let mut r = rn;
            while l > 0 && r > 0 {
                let take_l = less.lt(&buf[r - 1], &v[l - 1]);
                let src = if take_l {
                    v + (l - 1);
                } else {
                    buf + (r - 1);
                };
                out -= 1;
                memcpy(v + out, src, sizeof(T));
                l -= take_l as usize;
                r -= (!take_l) as usize;
            }
            memcpy(v + l, buf, r * sizeof(T));
        }
    }
}

// Stable merge sort of `v[0..n)` with a scratch block of n elements from `alloc`. Input that is one
// ascending or strictly descending run finishes in n - 1 comparisons. Otherwise blocks of
// STABLE_BLOCK elements are insertion sorted, then merged bottom-up, each pass from one buffer into the
// other; a pair already in order is copied without comparisons.
fn sort_stable_impl<T, A: Allocator, L: SortLess<T>>(v: *mut T, n: usize, alloc0: A, less: L, natural: bool) {
    if sizeof(T) == 0 || n < 2 {
        return;
    }
    if n <= SORT_INSERTION_MAX {
        sort_insertion(v, n, less);
        return;
    }
    let mut asc: usize = 1;
    while asc < n && !less.lt(&unsafe v[asc], &unsafe v[asc - 1]) {
        asc += 1;
    }
    if asc == n {
        return;
    }
    if asc == 1 {
        let mut desc: usize = 1;
        while desc < n && less.lt(&unsafe v[desc], &unsafe v[desc - 1]) {
            desc += 1;
        }
        if desc == n {
            seq_reverse(v, n);
            return;
        }
    }
    let mut alloc = alloc0;
    let buf = (unsafe alloc.alloc(n * sizeof(T), alignof(T))) as *mut T;
    // The natural order of a builtin integer: radix sort, linear in n.
    let tag = type_info::<T>().kind;
    if natural && n >= SORT_RADIX_MIN && (tag == TypeTag::Int || tag == TypeTag::Uint) && sizeof(T) <= 8 {
        sort_radix(v, buf, n, tag == TypeTag::Int);
        unsafe alloc.dealloc(buf, n * sizeof(T), alignof(T));
        return;
    }
    let mut b: usize = 0;
    while b < n {
        sort_insertion(unsafe (v + b), STABLE_BLOCK.min(n - b), less);
        b += STABLE_BLOCK;
    }
    let mut src = v;
    let mut dst = buf;
    let mut w = STABLE_BLOCK;
    while w < n {
        let mut i: usize = 0;
        while i < n {
            let a = unsafe (src + i);
            let la = w.min(n - i);
            let lb = w.min(n - i - la);
            if lb == 0 || !less.lt(&unsafe a[la], &unsafe a[la - 1]) {
                unsafe memcpy(dst + i, a, (la + lb) * sizeof(T));
            } else if la == lb {
                stable_parity_merge(a, unsafe (a + la), la, unsafe (dst + i), less);
            } else {
                stable_merge_into(a, la, unsafe (a + la), lb, unsafe (dst + i), less);
            }
            i += la + lb;
        }
        let t = src;
        src = dst;
        dst = t;
        w = w * 2;
    }
    if src != v {
        unsafe memcpy(v, src, n * sizeof(T));
    }
    unsafe alloc.dealloc(buf, n * sizeof(T), alignof(T));
}

// Stable least-significant-digit radix sort of the builtin integers `v[0..n)` (`sizeof(T)` of 1, 2, 4
// or 8 bytes, little-endian, `signed` for a two's complement type) through `buf`, room for n: one
// counting pass for every byte, then one scatter pass per byte that does not hold one value for all
// keys. The natural order of integers is the order of their keys with the sign bit flipped.
fn sort_radix<T>(v: *mut T, buf: *mut T, n: usize, signed: bool) {
    // Folds per instance: a wider type emits no key reads at all.
    if sizeof(T) <= 8 {
        const SZ: usize = sizeof(T);
        let mut counts: [usize; 2048] = [0; 2048];
        let flip: u64 = if signed {
            1u64 << (SZ * 8 - 1) as u32;
        } else {
            0;
        };
        unsafe {
            for i in 0..n {
                let mut k: u64 = 0;
                memcpy(&mut k, v + i, SZ);
                k = k ^ flip;
                for d in 0..SZ {
                    counts[d * 256 + (k >> (d * 8) as u32 & 0xFF) as usize] += 1;
                }
            }
            let mut src = v;
            let mut dst = buf;
            for d in 0..SZ {
                let base = d * 256;
                let mut first: u64 = 0;
                memcpy(&mut first, src, SZ);
                first = first ^ flip;
                if counts[base + (first >> (d * 8) as u32 & 0xFF) as usize] == n {
                    continue;
                }
                let mut sum: usize = 0;
                for b in 0..256usize {
                    let c = counts[base + b];
                    counts[base + b] = sum;
                    sum += c;
                }
                for i in 0..n {
                    let mut k: u64 = 0;
                    memcpy(&mut k, src + i, SZ);
                    let slot = base + ((k ^ flip) >> (d * 8) as u32 & 0xFF) as usize;
                    memcpy(dst + counts[slot], src + i, SZ);
                    counts[slot] += 1;
                }
                let t = src;
                src = dst;
                dst = t;
            }
            if src != v {
                memcpy(v, src, n * SZ);
            }
        }
    }
}

// Merge the sorted runs `v[a..m)` and `v[m..b)` in place, stable, by symmetric comparisons and
// rotations (Kim and Kutzner, "Stable Minimum Storage Merging by Symmetric Comparisons", ESA 2004):
// O(m log(n / m + 1)) comparisons for the shorter run m, and no memory beyond O(log n) stack. A
// sub-merge whose shorter run fits `room` elements of `buf` is the buffered merge.
fn stable_symmerge<T, L: SortLess<T>>(v: *mut T, a: usize, m: usize, b: usize, less: L, buf: *mut T, room: usize) {
    if (m - a).min(b - m) <= room {
        stable_merge(unsafe (v + a), b - a, m - a, buf, less);
        return;
    }
    if m - a == 1 {
        // One element on the left: binary search its place in the right run, then shift it there.
        let mut lo = m;
        let mut hi = b;
        while lo < hi {
            let h = lo + (hi - lo) / 2;
            if less.lt(&unsafe v[h], &unsafe v[a]) {
                lo = h + 1;
            } else {
                hi = h;
            }
        }
        stable_rotate(unsafe (v + a), lo - a, 1, buf, room);
        return;
    }
    if b - m == 1 {
        // One element on the right: its place is after every left element not greater than it.
        let mut lo = a;
        let mut hi = m;
        while lo < hi {
            let h = lo + (hi - lo) / 2;
            if !less.lt(&unsafe v[m], &unsafe v[h]) {
                lo = h + 1;
            } else {
                hi = h;
            }
        }
        stable_rotate(unsafe (v + lo), m + 1 - lo, m - lo, buf, room);
        return;
    }
    let mid = a + (b - a) / 2;
    let n = mid + m;
    let mut start: usize = 0;
    let mut r: usize = 0;
    if m > mid {
        start = n - b;
        r = mid;
    } else {
        start = a;
        r = m;
    }
    let p = n - 1;
    while start < r {
        let c = start + (r - start) / 2;
        if !less.lt(&unsafe v[p - c], &unsafe v[c]) {
            start = c + 1;
        } else {
            r = c;
        }
    }
    let end = n - start;
    if start < m && m < end {
        stable_rotate(unsafe (v + start), end - start, m - start, buf, room);
    }
    if a < start && start < mid {
        stable_symmerge(v, a, start, mid, less, buf, room);
    }
    if mid < end && end < b {
        stable_symmerge(v, mid, end, b, less, buf, room);
    }
}

// Stable merge sort of `v[0..n)` with no heap memory: insertion sorted blocks of STABLE_BLOCK, then
// bottom-up merges. A merge whose shorter run fits `room` elements of `buf` is the buffered merge; a
// longer one merges in place by symmetric rotations. O(n log n) comparisons and O(n log^2 n) moves; a
// pair of runs already in order costs one comparison.
fn stable_merge_in_place<T, L: SortLess<T>>(v: *mut T, n: usize, buf: *mut T, room: usize, less: L) {
    let mut b: usize = 0;
    while b < n {
        sort_insertion(unsafe (v + b), STABLE_BLOCK.min(n - b), less);
        b += STABLE_BLOCK;
    }
    let mut w = STABLE_BLOCK;
    while w < n {
        let mut a: usize = 0;
        while a + w < n {
            let m = a + w;
            let e = (m + w).min(n);
            if less.lt(&unsafe v[m], &unsafe v[m - 1]) {
                stable_symmerge(v, a, m, e, less, buf, room);
            }
            a = e;
        }
        w = w * 2;
    }
}

// Rotate `v[0..n)` left by `left` (blitsort's trinity rotation). When the shorter side fits `room`
// elements of `buf`, it waits there while one `memmove` shifts the other side: n moves at memory speed.
// When the sides differ by at most `room`, that difference waits in `buf` while the sides trade places
// pairwise: about n moves. Otherwise a conjoined triple reversal: each element moves once, through
// four-element cycles.
const fn stable_rotate<T>(v: *mut T, n: usize, left: usize, buf: *mut T, room: usize) {
    let right = n - left;
    if left == 0 || right == 0 {
        return;
    }
    unsafe {
        if left <= right && left <= room {
            memcpy(buf, v, left * sizeof(T));
            memmove(v, v + left, right * sizeof(T));
            memcpy(v + right, buf, left * sizeof(T));
            return;
        }
        if right < left && right <= room {
            memcpy(buf, v + left, right * sizeof(T));
            memmove(v + right, v, left * sizeof(T));
            memcpy(v, buf, right * sizeof(T));
            return;
        }
        if left < right && right - left <= room {
            let bridge = right - left;
            memcpy(buf, v + left, bridge * sizeof(T));
            let mut b = left;
            let mut c = right;
            let mut d = n;
            for _ in 0..left {
                c -= 1;
                d -= 1;
                b -= 1;
                v[c] = v[d];
                v[d] = v[b];
            }
            memcpy(v, buf, bridge * sizeof(T));
            return;
        }
        if right < left && left - right <= room {
            let bridge = left - right;
            memcpy(buf, v + right, bridge * sizeof(T));
            let mut a: usize = 0;
            let mut b = left;
            let mut c = right;
            for _ in 0..right {
                v[c] = v[a];
                v[a] = v[b];
                a += 1;
                b += 1;
                c += 1;
            }
            memcpy(v + (n - bridge), buf, bridge * sizeof(T));
            return;
        }
        // Both sides and their difference exceed the buffer: reverse the two sides and the whole in
        // one interleaved pass, then finish the longer side's remainder.
        let mut a: usize = 0;
        let mut b = left;
        let mut c = left;
        let mut d = n;
        for _ in 0..left.min(right) / 2 {
            b -= 1;
            d -= 1;
            let t = v[b];
            v[b] = v[a];
            v[a] = v[c];
            v[c] = v[d];
            v[d] = t;
            a += 1;
            c += 1;
        }
        if left < right {
            for _ in 0..(d - c) / 2 {
                d -= 1;
                let t = v[c];
                v[c] = v[d];
                v[d] = v[a];
                v[a] = t;
                a += 1;
                c += 1;
            }
        } else {
            for _ in 0..(b - a) / 2 {
                b -= 1;
                d -= 1;
                let t = v[b];
                v[b] = v[a];
                v[a] = v[d];
                v[d] = t;
                a += 1;
            }
        }
        for _ in 0..(d - a) / 2 {
            d -= 1;
            let t = v[a];
            v[a] = v[d];
            v[d] = t;
            a += 1;
        }
    }
}

// Stable partition of `v[0..n)`: the elements that satisfy `left` keep their order at the front, the
// others theirs after them; returns how many satisfy `left`, which must not read `v`. A run of at most
// `room` elements takes one pass: each element is written both to its front slot and to its `buf` slot,
// and only the count of the side it belongs to advances, so the pass has no branch; the `buf` side then
// follows the front in one copy. A longer run partitions its halves, then one rotation joins the two
// middle pieces: O(n log(n / room)) moves.
fn stable_partition<T, P: SortPred<T>>(v: *mut T, n: usize, left: P, buf: *mut T, room: usize) usize {
    if n > room {
        let h = n / 2;
        let l = stable_partition(v, h, left, buf, room);
        let r = stable_partition(unsafe (v + h), n - h, left, buf, room);
        stable_rotate(unsafe (v + l), h - l + r, h - l, buf, room);
        return l + r;
    }
    let mut m: usize = 0;
    unsafe {
        for i in 0..n {
            let go = left.test(&v[i]);
            memcpy(buf + (i - m), v + i, sizeof(T));
            memcpy(v + m, buf + (i - m), sizeof(T));
            m += go as usize;
        }
        memcpy(v + m, buf, (n - m) * sizeof(T));
    }
    return m;
}

// Copy a pivot for `v[0..n)` to `piv`: the median of 9 spread samples up to STABLE_SAMPLE_MIN elements,
// else of about the cube root of n samples (32 up to `room`), sorted in `buf`. False when the larger
// sample's ends are equal: the run is then mostly one key, which a quicksort serves badly.
fn stable_pivot<T, L: SortLess<T>>(v: *const T, n: usize, piv: *mut T, buf: *mut T, room: usize, less: L) bool {
    let mut s: usize = 9;
    if n > STABLE_SAMPLE_MIN {
        s = 32;
        while s * s * s < n && s * 2 <= room {
            s = s * 2;
        }
    }
    let d = n / s;
    unsafe {
        for k in 0..s {
            memcpy(buf + k, v + k * d, sizeof(T));
        }
    }
    sort_unstable(buf, s, less);
    unsafe memcpy(piv, buf + s / 2, sizeof(T));
    return s == 9 || less.lt(&unsafe buf[0], &unsafe buf[s - 1]);
}

// Stable quicksort of `v[0..n)` in place (blitsort's rotate quicksort): split by a sampled pivot with
// `stable_partition`, recurse into the greater side, loop on the rest. When a later pivot equals the
// one before it (every element of the rest is at most that one), a strict split ends all its copies at
// once, so many equal keys cost linear time. A run of at most STABLE_QUICK_MIN elements, a run of mostly
// one key and a run past `depth` levels (pivots that keep missing) take the merge sort: O(n log n)
// comparisons in the worst case. Pivot copies live in this frame: elements of at most 64 bytes.
fn stable_quick<T, L: SortLess<T>>(v: *mut T, n0: usize, buf: *mut T, room: usize, less: L, depth0: u32) {
    let mut ps: [u64; 8] = [0; 8];
    let mut ms: [u64; 8] = [0; 8];
    let piv = ((&mut ps[0]) as *mut u64) as *mut T;
    let mx = ((&mut ms[0]) as *mut u64) as *mut T;
    let mut n = n0;
    let mut depth = depth0;
    let mut has_max = false;
    // Every pass ends the run or shrinks it by at least the pivot's element.
    while n > 1 {
        if n <= STABLE_QUICK_MIN || depth == 0 || !stable_pivot(v, n, piv, buf, room, less) {
            stable_merge_in_place(v, n, buf, room, less);
            return;
        }
        depth -= 1;
        if has_max && !less.lt(&unsafe *piv, &unsafe *mx) {
            n = stable_partition(v, n, BelowPivot::<T, L> { p: piv, less: less }, buf, room);
            has_max = false;
            continue;
        }
        let a = stable_partition(v, n, UpToPivot::<T, L> { p: piv, less: less }, buf, room);
        if a == n {
            // The pivot is the largest key: its copies end the run.
            n = stable_partition(v, n, BelowPivot::<T, L> { p: piv, less: less }, buf, room);
            has_max = false;
            continue;
        }
        stable_quick(unsafe (v + a), n - a, buf, room, less, depth);
        n = a;
        unsafe memcpy(mx, piv, sizeof(T));
        has_max = true;
    }
}

// Stable sort of `v[0..n)` with no heap memory: a STABLE_STACK_BYTES stack buffer serves the partitions,
// rotations and short merges. Sorted input and strictly descending input end after one pass.
fn sort_stable_in_place_impl<T, L: SortLess<T>>(v: *mut T, n: usize, less: L) {
    if sizeof(T) == 0 || n < 2 {
        return;
    }
    let mut i: usize = 1;
    while i < n && !less.lt(&unsafe v[i], &unsafe v[i - 1]) {
        i += 1;
    }
    if i == n {
        return;
    }
    if i == 1 {
        let mut j: usize = 2;
        while j < n && less.lt(&unsafe v[j], &unsafe v[j - 1]) {
            j += 1;
        }
        if j == n {
            seq_reverse(v, n);
            return;
        }
    }
    let mut stack: [u64; 512] = [0; 512];
    let buf = ((&mut stack[0]) as *mut u64) as *mut T;
    // The buffer holds whole elements of an alignment it meets, else none.
    let room: usize = if alignof(T) <= 8 {
        STABLE_STACK_BYTES / sizeof(T);
    } else {
        0;
    };
    if sizeof(T) <= 64 && room >= 64 && n > STABLE_QUICK_MIN {
        let depth = 2 * (64 - (n as u64).leading_zeros() as u32);
        stable_quick(v, n, buf, room, less, depth);
    } else {
        stable_merge_in_place(v, n, buf, room, less);
    }
}

// Median of medians: the k-th element of `v[0..n)` in linear time whatever the input.
fn select_mom<T, L: SortLess<T>>(v: *mut T, n0: usize, k0: usize, less: L) {
    let mut v2 = v;
    let mut n = n0;
    let mut k = k0;
    loop {
        if n <= SELECT_SMALL {
            sort_insertion(v2, n, less);
            return;
        }
        // The median of each group of five moves to the front.
        let groups = n / 5;
        for g in 0..groups {
            let gp = unsafe (v2 + g * 5);
            sort_insertion(gp, 5, less);
            sort_swap(unsafe (v2 + g), unsafe (gp + 2));
        }
        select_mom(v2, groups, groups / 2, less);
        let (mid, _) = sort_partition_by(v2, n, groups / 2, less, false);
        if k == mid {
            return;
        }
        if k < mid {
            n = mid;
        } else {
            v2 = unsafe (v2 + (mid + 1));
            n -= mid + 1;
            k -= mid + 1;
        }
    }
}

// Introselect: reorder `v[0..n)` so `v[k]` holds the element sorted order puts there, nothing before it
// greater and nothing after it less.
fn sort_select<T, L: SortLess<T>>(v0: *mut T, n0: usize, k0: usize, less: L) {
    let mut v = v0;
    let mut n = n0;
    let mut k = k0;
    let mut pred: *const T = null;
    let mut limit = 64 - (n as u64).leading_zeros() as u32;
    loop {
        if n <= SELECT_SMALL {
            sort_insertion(v, n, less);
            return;
        }
        if limit == 0 {
            select_mom(v, n, k, less);
            return;
        }
        let (pi, swaps) = sort_choose_pivot(v, n, less);
        if pred != null && !less.lt(&unsafe pred[0], &unsafe v[pi]) {
            let eq = sort_partition_equal(v, n, pi, less);
            if k < eq {
                return;
            }
            v = unsafe (v + eq);
            n -= eq;
            k -= eq;
            continue;
        }
        // Samples in order or all reversed: the Hoare pass, which moves nothing already on its side,
        // where the branchless pass writes every element.
        let (mid, _) = sort_partition_by(v, n, pi, less, swaps == 0 || swaps >= SORT_PIVOT_SWAPS_MAX);
        if mid.min(n - mid - 1) < n / 8 {
            limit -= 1;
        }
        if k == mid {
            return;
        }
        if k < mid {
            n = mid;
        } else {
            pred = unsafe (v + mid);
            v = unsafe (v + (mid + 1));
            n -= mid + 1;
            k -= mid + 1;
        }
    }
}

// Move the first element of every run that `same` joins to the front, in order: the kept length.
fn seq_dedup<T, S: SortSame<T>>(v: *mut T, n: usize, same: S) usize {
    if n < 2 {
        return n;
    }
    let mut w: usize = 1;
    for r in 1..n {
        if !same.same(&unsafe v[w - 1], &unsafe v[r]) {
            if r != w {
                sort_swap(unsafe (v + r), unsafe (v + w));
            }
            w += 1;
        }
    }
    return w;
}

// Rotate `v[0..n)` left by `mid`: `stable_rotate` through a stack buffer, or with none when the
// sequence is at most ROTATE_DIRECT_BYTES (zeroing the buffer would cost more than it saves).
const fn seq_rotate_left<T>(v: *mut T, n: usize, mid: usize) {
    if sizeof(T) == 0 {
        return;
    }
    if n * sizeof(T) <= ROTATE_DIRECT_BYTES || alignof(T) > 8 {
        stable_rotate(v, n, mid, null, 0);
        return;
    }
    let mut stack: [u64; 512] = [0; 512];
    stable_rotate(v, n, mid, ((&mut stack[0]) as *mut u64) as *mut T, STABLE_STACK_BYTES / sizeof(T));
}

// Binary search of `v[0..n)` ordered by `cmp`: `Ok` of a match or `Err` of the insertion point. The
// bisection keeps no early exit, so each halving is one comparison and a conditional move.
fn seq_bisect<T, P: SortProbe<T>>(v: *const T, n: usize, cmp: P) Result<usize, usize> {
    if n == 0 {
        return Result::<usize, usize>::Err(0);
    }
    let mut base: usize = 0;
    let mut size = n;
    while size > 1 {
        let half = size / 2;
        let mid = base + half;
        if cmp.probe(&unsafe v[mid]) <= 0 {
            base = mid;
        }
        size -= half;
    }
    let c = cmp.probe(&unsafe v[base]);
    if c == 0 {
        return Result::<usize, usize>::Ok(base);
    }
    return Result::<usize, usize>::Err(base + (c < 0) as usize);
}

extern "C" {
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
    fn memmove(dst: *mut void, src: *const void, n: usize) *mut void;
}

/// Restore the max-heap order of `v` after its first element changed (a heap's top, modified in
/// place): one sift down, O(log n). For `std::collections::heap`.
pub(package) fn heap_restore_top<T: Ord>(v: []mut T) {
    if v.len > 1 {
        heap_sift_down(v.ptr, v.len, 0, OrdLess {});
    }
}

extend<T> Slice<T> {
    /// A borrowing iterator over the elements in order, double-ended, with an exact size.
    pub const fn iter(self: &Slice<T>) VecIter<T> {
        return VecIter::<T> { data: self.ptr, idx: 0, stop: self.len };
    }

    /// The views `[0, mid)` and `[mid, len)`; panics when `mid > len`.
    pub const fn split_at(self: &Slice<T>, mid: usize) ([]T, []T) {
        if mid > self.len {
            panic("Slice::split_at: index out of bounds");
        }
        return unsafe Slice::<T> { ptr: self.ptr, len: mid }, unsafe Slice::<T> {
            ptr: self.ptr + mid,
            len: self.len - mid,
        };
    }

    /// Binary search of a sequence ordered by `cmp(element)` (negative: the element comes before the
    /// target): `Ok(i)` of a matching element (any one when several match), or `Err(i)`, where the
    /// target would be inserted to keep the order. O(log n).
    pub fn binary_search_by<F: fn(&T) i32>(self: &Slice<T>, cmp: F) Result<usize, usize> {
        return seq_bisect(self.ptr, self.len, FnProbe::<F> { f: cmp });
    }

    /// `binary_search_by` on a key that orders the sequence.
    pub fn binary_search_by_key<K: Ord, F: fn(&T) K>(self: &Slice<T>, key: &K, f: F) Result<usize, usize> {
        return seq_bisect(self.ptr, self.len, KeyProbe::<K, F> { key: key, f: f });
    }

    /// The index of the first element for which `pred` is false, in a sequence where every element
    /// that satisfies it comes first (C++ partition_point, lower_bound). O(log n).
    pub fn partition_point<P: fn(&T) bool>(self: &Slice<T>, pred: P) usize {
        let mut base: usize = 0;
        let mut size = self.len;
        while size > 0 {
            let half = size / 2;
            if pred(&unsafe self.ptr[base + half]) {
                base = base + half + 1;
                size = size - half - 1;
            } else {
                size = half;
            }
        }
        return base;
    }

    /// True when `cmp` orders every adjacent pair (`cmp(a, b) <= 0`).
    pub fn is_sorted_by<F: fn(&T, &T) i32>(self: &Slice<T>, cmp: F) bool {
        let mut i: usize = 1;
        while i < self.len {
            if cmp(&unsafe self.ptr[i - 1], &unsafe self.ptr[i]) > 0 {
                return false;
            }
            i += 1;
        }
        return true;
    }

    /// True when the keys of adjacent elements never decrease.
    pub fn is_sorted_by_key<K: Ord, F: fn(&T) K>(self: &Slice<T>, key: F) bool {
        let mut i: usize = 1;
        while i < self.len {
            if key(&unsafe self.ptr[i]) < key(&unsafe self.ptr[i - 1]) {
                return false;
            }
            i += 1;
        }
        return true;
    }

    /// True when every element that satisfies `pred` comes before every one that does not.
    pub fn is_partitioned<P: fn(&T) bool>(self: &Slice<T>, pred: P) bool {
        let mut i: usize = 0;
        while i < self.len && pred(&unsafe self.ptr[i]) {
            i += 1;
        }
        while i < self.len {
            if pred(&unsafe self.ptr[i]) {
                return false;
            }
            i += 1;
        }
        return true;
    }

    /// True when the sequence is a max-heap under `cmp` (every parent not less than its children).
    pub fn is_heap_by<F: fn(&T, &T) i32>(self: &Slice<T>, cmp: F) bool {
        let mut i: usize = 1;
        while i < self.len {
            if cmp(&unsafe self.ptr[(i - 1) / 2], &unsafe self.ptr[i]) < 0 {
                return false;
            }
            i += 1;
        }
        return true;
    }
}

extend<T: Ord> Slice<T> {
    /// Binary search of an ascending sequence for `x` (see `binary_search_by`). O(log n).
    pub const fn binary_search(self: &Slice<T>, x: &T) Result<usize, usize> {
        return seq_bisect(self.ptr, self.len, OrdProbe::<T> { x: x });
    }

    /// True when the elements never decrease.
    pub const fn is_sorted(self: &Slice<T>) bool {
        let mut i: usize = 1;
        while i < self.len {
            if unsafe self.ptr[i] < unsafe self.ptr[i - 1] {
                return false;
            }
            i += 1;
        }
        return true;
    }

    /// True when the sequence is a max-heap.
    pub const fn is_heap(self: &Slice<T>) bool {
        let mut i: usize = 1;
        while i < self.len {
            if unsafe self.ptr[(i - 1) / 2] < unsafe self.ptr[i] {
                return false;
            }
            i += 1;
        }
        return true;
    }
}

extend<T: Eq> Slice<T> {
    /// True when an element equals `x`. O(n).
    pub const fn contains(self: &Slice<T>, x: &T) bool {
        for i in 0..self.len {
            if unsafe self.ptr[i] == *x {
                return true;
            }
        }
        return false;
    }

    /// True when the sequence begins with `prefix`.
    pub const fn starts_with(self: &Slice<T>, prefix: []T) bool {
        if prefix.len > self.len {
            return false;
        }
        for i in 0..prefix.len {
            if unsafe self.ptr[i] != unsafe prefix.ptr[i] {
                return false;
            }
        }
        return true;
    }

    /// True when the sequence ends with `suffix`.
    pub const fn ends_with(self: &Slice<T>, suffix: []T) bool {
        if suffix.len > self.len {
            return false;
        }
        let off = self.len - suffix.len;
        for i in 0..suffix.len {
            if unsafe self.ptr[off + i] != unsafe suffix.ptr[i] {
                return false;
            }
        }
        return true;
    }
}

extend<T: Eq> Slice<T> as Eq {
    pub fn eq(self: &Slice<T>, other: &Slice<T>) bool {
        if self.len != other.len {
            return false;
        }
        for i in 0..self.len {
            if unsafe self.ptr[i] != unsafe other.ptr[i] {
                return false;
            }
        }
        return true;
    }
}

// Lexicographic: the first unequal element decides, then the length.
extend<T: Ord> Slice<T> as Ord {
    pub fn cmp(self: &Slice<T>, other: &Slice<T>) i32 {
        let n = self.len.min(other.len);
        for i in 0..n {
            let c = (unsafe self.ptr[i]).cmp(&unsafe other.ptr[i]);
            if c != 0 {
                return c;
            }
        }
        return self.len.cmp(&other.len);
    }
}

extend<T: Hash> Slice<T> as Hash {
    /// The length, then every element, as `Vector::hash_into`.
    pub fn hash_into<H: Hasher>(self: &Slice<T>, h: &mut H) {
        h.write_u64(self.len as u64);
        for i in 0..self.len {
            (unsafe self.ptr[i]).hash_into(h);
        }
    }
}

extend<T: Format> Slice<T> as Format {
    /// `[e0, e1, ...]` with each element rendered through its own `fmt`.
    pub fn fmt(self: &Slice<T>) String {
        let mut s = String::from_str("[");
        for i in 0..self.len {
            if i > 0 {
                s.push_str(", ");
            }
            let es = (unsafe self.ptr[i]).fmt();
            s.push_string(&es);
        }
        s.push_str("]");
        return s;
    }
}

/// A borrowing iterator over the elements of a `[]mut T`, yielding `&mut T` in order. Double-ended,
/// with an exact size.
pub struct SliceIterMut<'a, T> {
    pub(file) data: *mut T,
    pub(file) idx: usize,
    pub(file) stop: usize,
}

extend<'a, T> SliceIterMut<'a, T> as Iterator<&'a mut T> {
    pub const fn next(self: &mut SliceIterMut<'a, T>) Option<&'a mut T> {
        if self.idx >= self.stop {
            return Option::<&'a mut T>::None;
        }
        let r = unsafe &mut *(self.data + self.idx);
        self.idx += 1;
        return Option::<&'a mut T>::Some(r);
    }

    pub const fn size_hint(self: &SliceIterMut<'a, T>) (usize, Option<usize>) {
        let n = self.stop - self.idx;
        return n, Option::<usize>::Some(n);
    }
}

extend<'a, T> SliceIterMut<'a, T> as DoubleEndedIterator<&'a mut T> {
    pub const fn next_back(self: &mut SliceIterMut<'a, T>) Option<&'a mut T> {
        if self.idx >= self.stop {
            return Option::<&'a mut T>::None;
        }
        self.stop -= 1;
        return Option::<&'a mut T>::Some(unsafe &mut *(self.data + self.stop));
    }
}

// The mutating algorithms take the view by value: it is reborrowed for the call, as a `[]mut T`
// argument is, so they need no `mut` binding and conflict with any live borrow of an element.
extend<T> SliceMut<T> {
    /// The read-only view of the same elements.
    pub const fn as_slice(self: &SliceMut<T>) []T {
        return unsafe Slice::<T> { ptr: self.ptr, len: self.len };
    }

    /// A borrowing iterator over the elements, yielding `&mut T`.
    pub const fn iter_mut(self: SliceMut<T>) SliceIterMut<T> {
        return SliceIterMut::<T> { data: self.ptr, idx: 0, stop: self.len };
    }

    /// The writable views `[0, mid)` and `[mid, len)`; panics when `mid > len`.
    pub const fn split_at_mut(self: SliceMut<T>, mid: usize) ([]mut T, []mut T) {
        if mid > self.len {
            panic("SliceMut::split_at_mut: index out of bounds");
        }
        return unsafe SliceMut::<T> { ptr: self.ptr, len: mid }, unsafe SliceMut::<T> {
            ptr: self.ptr + mid,
            len: self.len - mid,
        };
    }

    /// Exchange the elements at `i` and `j`; panics when either is out of bounds.
    pub const fn swap(self: SliceMut<T>, i: usize, j: usize) {
        if i >= self.len || j >= self.len {
            panic("SliceMut::swap: index out of bounds");
        }
        sort_swap(unsafe (self.ptr + i), unsafe (self.ptr + j));
    }

    /// Reverse the order of the elements.
    pub const fn reverse(self: SliceMut<T>) {
        seq_reverse(self.ptr, self.len);
    }

    /// Rotate so the element at `mid` comes first; panics when `mid > len`. O(n).
    pub const fn rotate_left(self: SliceMut<T>, mid: usize) {
        if mid > self.len {
            panic("SliceMut::rotate_left: mid out of bounds");
        }
        seq_rotate_left(self.ptr, self.len, mid);
    }

    /// Rotate so the last `k` elements come first; panics when `k > len`. O(n).
    pub const fn rotate_right(self: SliceMut<T>, k: usize) {
        if k > self.len {
            panic("SliceMut::rotate_right: k out of bounds");
        }
        seq_rotate_left(self.ptr, self.len, self.len - k);
    }

    /// Exchange every element with the one at the same index of `other`; panics on a length mismatch.
    pub const fn swap_with_slice(self: SliceMut<T>, other: []mut T) {
        if self.len != other.len {
            panic("SliceMut::swap_with_slice: length mismatch");
        }
        for i in 0..self.len {
            sort_swap(unsafe (self.ptr + i), unsafe (other.ptr + i));
        }
    }

    /// Sort by `cmp` (negative: `a` before `b`), unstable: pattern-defeating quicksort, O(n log n)
    /// worst case, no allocation.
    pub const fn sort_by<F: fn(&T, &T) i32>(self: SliceMut<T>, cmp: F) {
        sort_unstable(self.ptr, self.len, CmpLess::<F> { f: cmp });
    }

    /// Sort by a key, unstable. The key is computed twice per comparison.
    pub const fn sort_by_key<K: Ord, F: fn(&T) K>(self: SliceMut<T>, key: F) {
        sort_unstable(self.ptr, self.len, KeyLess::<K, F> { f: key });
    }

    /// Stable sort by `cmp` with scratch for `len` elements from the C heap.
    pub fn sort_stable_by<F: fn(&T, &T) i32>(self: SliceMut<T>, cmp: F) {
        sort_stable_impl(self.ptr, self.len, Global {}, CmpLess::<F> { f: cmp }, false);
    }

    /// Stable sort by `cmp` with scratch for `len` elements from `alloc`, released before return.
    pub fn sort_stable_by_in<A: Allocator, F: fn(&T, &T) i32>(self: SliceMut<T>, alloc: A, cmp: F) {
        sort_stable_impl(self.ptr, self.len, alloc, CmpLess::<F> { f: cmp }, false);
    }

    /// Stable sort by a key. The key is computed twice per comparison.
    pub fn sort_stable_by_key<K: Ord, F: fn(&T) K>(self: SliceMut<T>, key: F) {
        sort_stable_impl(self.ptr, self.len, Global {}, KeyLess::<K, F> { f: key }, false);
    }

    /// Stable sort by `cmp` in place: no heap memory (a 4 KiB stack buffer), O(n log n) comparisons and
    /// O(n log^2 n) moves in the worst case. Slower than `sort_stable_by` (about 1.25x on a million
    /// random keys), which borrows a scratch block of `len` elements.
    pub fn sort_stable_in_place_by<F: fn(&T, &T) i32>(self: SliceMut<T>, cmp: F) {
        sort_stable_in_place_impl(self.ptr, self.len, CmpLess::<F> { f: cmp });
    }

    /// Stable sort by a key in place, as `sort_stable_in_place_by`.
    pub fn sort_stable_in_place_by_key<K: Ord, F: fn(&T) K>(self: SliceMut<T>, key: F) {
        sort_stable_in_place_impl(self.ptr, self.len, KeyLess::<K, F> { f: key });
    }

    /// Stable sort by a key with scratch from `alloc`.
    pub fn sort_stable_by_key_in<A: Allocator, K: Ord, F: fn(&T) K>(self: SliceMut<T>, alloc: A, key: F) {
        sort_stable_impl(self.ptr, self.len, alloc, KeyLess::<K, F> { f: key }, false);
    }

    /// Reorder so the element at `k` is the one sorted order puts there, with nothing greater before it
    /// and nothing less after it (C++ nth_element); panics when `k >= len`. O(n) worst case.
    pub const fn select_nth_unstable_by<F: fn(&T, &T) i32>(self: SliceMut<T>, k: usize, cmp: F) {
        if k >= self.len {
            panic("SliceMut::select_nth_unstable: index out of bounds");
        }
        sort_select(self.ptr, self.len, k, CmpLess::<F> { f: cmp });
    }

    /// `select_nth_unstable_by` on a key.
    pub const fn select_nth_unstable_by_key<K: Ord, F: fn(&T) K>(self: SliceMut<T>, k: usize, key: F) {
        if k >= self.len {
            panic("SliceMut::select_nth_unstable: index out of bounds");
        }
        sort_select(self.ptr, self.len, k, KeyLess::<K, F> { f: key });
    }

    /// Move every element that satisfies `pred` before every one that does not, and return how many
    /// satisfy it. Not stable; each element moves at most once. O(n).
    pub fn partition<P: fn(&T) bool>(self: SliceMut<T>, pred: P) usize {
        return part_hoare(self.ptr, self.len, FnPred::<P> { f: pred });
    }

    /// Keep the first element of every run of consecutive elements that `same(earlier, later)` joins,
    /// in order, at the front; move the others behind them. Returns the length of the kept prefix. O(n).
    pub fn partition_dedup_by<F: fn(&T, &T) bool>(self: SliceMut<T>, same: F) usize {
        return seq_dedup(self.ptr, self.len, FnSame::<F> { f: same });
    }

    /// `partition_dedup_by` on a key.
    pub fn partition_dedup_by_key<K: Eq, F: fn(&T) K>(self: SliceMut<T>, key: F) usize {
        return seq_dedup(self.ptr, self.len, KeySame::<K, F> { f: key });
    }

    /// Reorder into a max-heap under `cmp` (C++ make_heap). O(n).
    pub fn heapify_by<F: fn(&T, &T) i32>(self: SliceMut<T>, cmp: F) {
        heap_make(self.ptr, self.len, CmpLess::<F> { f: cmp });
    }

    /// Restore the heap after the last element was appended to the heap `[0, len - 1)` (C++ push_heap).
    /// O(log n).
    pub fn push_heap_by<F: fn(&T, &T) i32>(self: SliceMut<T>, cmp: F) {
        if self.len > 1 {
            heap_sift_up(self.ptr, self.len - 1, CmpLess::<F> { f: cmp });
        }
    }

    /// Move the largest element of the heap to the end; `[0, len - 1)` stays a heap (C++ pop_heap).
    /// O(log n).
    pub fn pop_heap_by<F: fn(&T, &T) i32>(self: SliceMut<T>, cmp: F) {
        heap_pop(self.ptr, self.len, CmpLess::<F> { f: cmp });
    }

    /// Sort a heap in ascending order (C++ sort_heap). O(n log n).
    pub fn sort_heap_by<F: fn(&T, &T) i32>(self: SliceMut<T>, cmp: F) {
        heap_sort(self.ptr, self.len, CmpLess::<F> { f: cmp });
    }
}

extend<T: Ord> SliceMut<T> {
    /// Sort in ascending order, unstable: pattern-defeating quicksort, O(n log n) worst case, no
    /// allocation.
    pub const fn sort(self: SliceMut<T>) {
        sort_unstable(self.ptr, self.len, OrdLess {});
    }

    /// Sort in ascending order, stable, with scratch for `len` elements from the C heap.
    pub fn sort_stable(self: SliceMut<T>) {
        sort_stable_impl(self.ptr, self.len, Global {}, OrdLess {}, true);
    }

    /// Stable ascending sort in place, as `sort_stable_in_place_by`: no allocation.
    pub fn sort_stable_in_place(self: SliceMut<T>) {
        sort_stable_in_place_impl(self.ptr, self.len, OrdLess {});
    }

    /// Stable ascending sort with scratch from `alloc`.
    pub fn sort_stable_in<A: Allocator>(self: SliceMut<T>, alloc: A) {
        sort_stable_impl(self.ptr, self.len, alloc, OrdLess {}, true);
    }

    /// `select_nth_unstable_by` in ascending order.
    pub fn select_nth_unstable(self: SliceMut<T>, k: usize) {
        if k >= self.len {
            panic("SliceMut::select_nth_unstable: index out of bounds");
        }
        sort_select(self.ptr, self.len, k, OrdLess {});
    }

    /// Reorder into a max-heap. O(n).
    pub fn heapify(self: SliceMut<T>) {
        heap_make(self.ptr, self.len, OrdLess {});
    }

    /// `push_heap_by` in the natural order.
    pub fn push_heap(self: SliceMut<T>) {
        if self.len > 1 {
            heap_sift_up(self.ptr, self.len - 1, OrdLess {});
        }
    }

    /// `pop_heap_by` in the natural order.
    pub fn pop_heap(self: SliceMut<T>) {
        heap_pop(self.ptr, self.len, OrdLess {});
    }

    /// `sort_heap_by` in the natural order.
    pub fn sort_heap(self: SliceMut<T>) {
        heap_sort(self.ptr, self.len, OrdLess {});
    }
}

extend<T: Eq> SliceMut<T> {
    /// `partition_dedup_by` with `==`.
    pub fn partition_dedup(self: SliceMut<T>) usize {
        return seq_dedup(self.ptr, self.len, EqSame {});
    }
}

extend<T: Clone> SliceMut<T> {
    /// Overwrite every element with a clone of `value` (the last takes `value` itself), freeing each
    /// replaced element.
    pub fn fill(self: SliceMut<T>, value: T) {
        if self.len == 0 {
            return;
        }
        // A store through the raw pointer frees nothing, so each replaced element is freed first.
        for i in 0..self.len - 1 {
            unsafe self.ptr[i].free();
            unsafe self.ptr[i] = value.clone();
        }
        unsafe self.ptr[self.len - 1].free();
        unsafe self.ptr[self.len - 1] = value;
    }

    /// Overwrite every element with a clone of the same element of `src`; panics on a length mismatch.
    pub fn clone_from_slice(self: SliceMut<T>, src: []T) {
        if self.len != src.len {
            panic("SliceMut::clone_from_slice: length mismatch");
        }
        for i in 0..self.len {
            unsafe self.ptr[i].free();
            unsafe self.ptr[i] = (unsafe src.ptr[i]).clone();
        }
    }
}

extend<T: Copy> SliceMut<T> {
    /// Copy every element of `src` in one block copy; panics on a length mismatch.
    pub const fn copy_from_slice(self: SliceMut<T>, src: []T) {
        if self.len != src.len {
            panic("SliceMut::copy_from_slice: length mismatch");
        }
        unsafe memcpy(self.ptr, src.ptr, self.len * sizeof(T));
    }
}
