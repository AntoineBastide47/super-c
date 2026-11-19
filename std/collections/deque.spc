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

import std::spec::seq as *;

extern "C" {
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
    fn memmove(dst: *mut void, src: *const void, n: usize) *mut void;
}

const USIZE_BITS: usize = sizeof(usize) * 8;
const MIN_CAP: usize = 8; // the first growth's capacity, as Vector's
const ZST_CAP: usize = 1 as usize << USIZE_BITS - 1; // the largest power of two in a usize

/// A growable double-ended queue: a ring buffer in one block from allocator A. The capacity is 0 or a power
/// of two; push and pop at both ends are amortized O(1).
pub struct Deque<T, A: Allocator = Global>
    invariant self.len <= self.cap && block(self.ptr).len() >= self.cap as int && self.head < self.cap.max(1)
    invariant self.cap == 0 || sizeof(T) == 0 || block(self.ptr).len() == self.cap as int
    invariant self.cap <= Deque::<T, A>::max_cap() && (sizeof(T) != 0 || self.cap == ZST_CAP) && (self.cap == 0 || (self.cap & self.cap - 1) == 0)
    invariant self.cap == 0 || sizeof(T) == 0 || A::owns(self.ptr, Deque::<T, A>::bytes(self.cap), alignof(T))
{
    @owned
    ptr: *mut T, // the block; `dangling` while cap == 0 or for a zero-sized T, so a view's pointer is never null
    head: usize, // slot of the front element; 0 while cap == 0
    len: usize, // elements in use
    cap: usize, // slots in the block: 0 or a power of two
    alloc: A, // the allocator the block came from (zero-sized for Global)
}

// A Deque owns its elements, so it is Send / Sync when its elements and allocator are (the block pointer
// makes it structurally neither).
unsafe extend<T: Send, A: Allocator + Send> Deque<T, A> as Send {}

unsafe extend<T: Sync, A: Allocator + Sync> Deque<T, A> as Sync {}

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

// The smallest power of two at least `n`, for `n` at most the power of two `limit`.
const fn next_pow2(n: usize, limit: usize) usize
    requires limit >= 1 && (limit & limit - 1) == 0 && n <= limit
    ensures |r| r >= n && r >= 1 && (r & r - 1) == 0 && r <= limit
{
    if n <= 1 {
        return 1;
    }
    return 1 as usize << USIZE_BITS - (n - 1).leading_zeros();
}

// The `n` elements of block `b` from slot `h` on, in order: element `k` is in slot `(h + k) & m`, for `m` a
// capacity less one. A deque's view.
spec fn ring<T>(b: Seq<T>, h: usize, m: usize, n: usize) Seq<T>
    requires m < ZST_CAP && h <= m && n <= m + 1 && b.len() > m as int
    decreases n
{
    return if n == 0 {
        Seq::<T>::empty()
    } else {
        ring(b, h, m, n - 1).push(b[(h + (n - 1) & m) as int])
    };
}

// The ring of `n` elements: the ring of `n - 1`, then the element in slot `h + n - 1`.
lemma ring_succ<T>(b: Seq<T>, h: usize, m: usize, n: usize)
    requires m < ZST_CAP && h <= m && 1 <= n && n <= m + 1 && b.len() > m as int
    ensures ring(b, h, m, n) == ring(b, h, m, n - 1).push(b[(h + (n - 1) & m) as int])
{}

lemma ring_len<T>(b: Seq<T>, h: usize, m: usize, n: usize)
    requires m < ZST_CAP && h <= m && n <= m + 1 && b.len() > m as int
    ensures ring(b, h, m, n).len() == n as int
    decreases n
{
    if n > 0 {
        ring_len(b, h, m, n - 1);
    }
}

// Element `k` of the ring: the block's element in slot `h + k`.
lemma ring_index<T>(b: Seq<T>, h: usize, m: usize, n: usize, k: usize)
    requires m < ZST_CAP && h <= m && n <= m + 1 && b.len() > m as int && k < n
    ensures ring(b, h, m, n)[k as int] == b[(h + k & m) as int]
    decreases n
{
    ring_len(b, h, m, n - 1);
    if k < n - 1 {
        ring_index(b, h, m, n - 1, k);
    }
}

// Offsets `i` and `j` up to `m`, a power of two less one, name the same slot only when they are equal.
lemma slots_differ(h: usize, i: usize, j: usize, m: usize)
    requires m < ZST_CAP && (m & m + 1) == 0 && h <= m && i <= m && j <= m && i != j
    ensures (h + i & m) != (h + j & m)
{}

// An offset `c` from a position `a` at most `m + 1` names the slot it names from `a`'s slot.
lemma mask_add(a: usize, c: usize, m: usize)
    requires m < ZST_CAP && (m & m + 1) == 0 && a <= m + 1 && c <= m
    ensures ((a & m) + c & m) == (a + c & m)
{}

// A write to slot `h + j`, `j` from `n` to `m`, leaves the ring of `n`.
lemma ring_upd_out<T>(b: Seq<T>, h: usize, m: usize, n: usize, j: usize, x: T)
    requires m < ZST_CAP && (m & m + 1) == 0 && h <= m && n <= j && j <= m && b.len() > m as int
    ensures ring(b.update((h + j & m) as int, x), h, m, n) == ring(b, h, m, n)
    decreases n
{
    if n > 0 {
        ring_upd_out(b, h, m, n - 1, j, x);
        slots_differ(h, n - 1, j, m);
    }
}

// The first `k` elements of the ring of `n`: the ring of `k`.
lemma ring_take<T>(b: Seq<T>, h: usize, m: usize, n: usize, k: usize)
    requires m < ZST_CAP && h <= m && n <= m + 1 && b.len() > m as int && k <= n
    ensures ring(b, h, m, n).take(k as int) == ring(b, h, m, k)
    decreases n
{
    ring_len(b, h, m, n);
    if k < n {
        ring_len(b, h, m, n - 1);
        ring_take(b, h, m, n - 1, k);
    }
}

// A sequence of no element is the empty one.
lemma empty_of<T>(s: Seq<T>)
    requires s.len() == 0
    ensures s == Seq::<T>::empty()
{}

// The elements after the first of a sequence with `x` pushed: those of the sequence, then `x`.
lemma skip_push<T>(s: Seq<T>, x: T)
    requires s.len() >= 1
    ensures s.push(x).skip(1) == s.skip(1).push(x)
{}

// A sequence of at least one element: its first, then the others.
lemma head_skip<T>(s: Seq<T>)
    requires s.len() >= 1
    ensures s == Seq::<T>::empty().push(s[0]).concat(s.skip(1))
{}

lemma ring_skip_one<T>(b: Seq<T>, h: usize, m: usize)
    requires m < ZST_CAP && (m & m + 1) == 0 && h <= m && b.len() > m as int
    ensures ring(b, h, m, 1).skip(1) == ring(b, h + 1 & m, m, 0)
{
    ring_len(b, h, m, 1);
    empty_of(ring(b, h, m, 1).skip(1));
    assert ring(b, h + 1 & m, m, 0) == Seq::<T>::empty() by {};
}

lemma ring_skip_step<T>(b: Seq<T>, h: usize, m: usize, n: usize)
    requires m < ZST_CAP && (m & m + 1) == 0 && h <= m && 2 <= n && n <= m + 1 && b.len() > m as int
    requires ring(b, h, m, n - 1).skip(1) == ring(b, h + 1 & m, m, n - 2)
    ensures ring(b, h, m, n).skip(1) == ring(b, h + 1 & m, m, n - 1)
{
    ring_len(b, h, m, n - 1);
    mask_add(h + 1, n - 2, m);
    assert (h + (n - 1) & m) <= m by {};
    ring_succ(b, h, m, n);
    ring_succ(b, h + 1 & m, m, n - 1);
    skip_push(ring(b, h, m, n - 1), b[(h + (n - 1) & m) as int]);
}

// The elements after the front: the ring from the next slot.
lemma ring_skip<T>(b: Seq<T>, h: usize, m: usize, n: usize)
    requires m < ZST_CAP && (m & m + 1) == 0 && h <= m && 1 <= n && n <= m + 1 && b.len() > m as int
    ensures ring(b, h, m, n).skip(1) == ring(b, h + 1 & m, m, n - 1)
    decreases n
{
    if n == 1 {
        ring_skip_one(b, h, m);
    } else {
        ring_skip(b, h, m, n - 1);
        ring_skip_step(b, h, m, n);
    }
}

// A position at most `m`, a power of two less one, is its own slot.
lemma low_mask(x: usize, m: usize)
    requires m < ZST_CAP && (m & m + 1) == 0 && x <= m
    ensures (x & m) == x
{}

// A ring that does not wrap below `k`: the same over two blocks whose first `k` elements agree, under two
// masks at least `k - 1`.
lemma ring_same<T>(b: Seq<T>, c: Seq<T>, h: usize, m1: usize, m2: usize, n: usize, k: usize)
    requires m1 < ZST_CAP && m2 < ZST_CAP && (m1 & m1 + 1) == 0 && (m2 & m2 + 1) == 0 && h <= m1 && h <= m2
    requires k <= m1 + 1 && k <= m2 + 1 && h <= k && n <= k - h && b.len() > m1 as int && c.len() > m2 as int
    requires b.take(k as int) == c.take(k as int)
    ensures ring(b, h, m1, n) == ring(c, h, m2, n)
    decreases n
{
    if n > 0 {
        ring_same(b, c, h, m1, m2, n - 1, k);
        ring_succ(b, h, m1, n);
        ring_succ(c, h, m2, n);
        low_mask(h + (n - 1), m1);
        low_mask(h + (n - 1), m2);
        take_at(b, k as int, (h + (n - 1)) as int);
        take_at(c, k as int, (h + (n - 1)) as int);
    }
}

// A position from `m + 1` to `2m + 1` wraps once.
lemma wrap_slot(x: usize, m: usize)
    requires m < ZST_CAP && (m & m + 1) == 0 && m + 1 <= x && x <= 2 * m + 1
    ensures (x & m) == x - (m + 1)
{}

// Offset `k` from slot `nh`, `hl` slots below the end of `M + 1`, past them: it wraps to `k - hl`.
lemma wrap_slot_end(nh: usize, k: usize, hl: usize, m: usize)
    requires m < ZST_CAP && (m & m + 1) == 0 && hl <= m + 1 && nh == m + 1 - hl && hl <= k && k - hl <= m
    ensures (nh + k & m) == k - hl
{}

// The first `i + 1` elements: the first `i`, then element `i`.
lemma take_succ<T>(b: Seq<T>, i: int)
    requires 0 <= i && i < b.len()
    ensures b.take(i + 1) == b.take(i).push(b[i])
{}

// A power of two above another is at least its double.
lemma pow2_double(a: usize, c: usize)
    requires 0 < a && a < c && c <= ZST_CAP && (a & a - 1) == 0 && (c & c - 1) == 0
    ensures a <= c / 2
{}

// A ring under mask `m` reads only the first `m + 1` elements of its block.
lemma ring_prefix<T>(b: Seq<T>, c: Seq<T>, h: usize, m: usize, n: usize)
    requires m < ZST_CAP && (m & m + 1) == 0 && h <= m && n <= m + 1 && b.len() > m as int && c.len() > m as int
    requires b.take(m as int + 1) == c.take(m as int + 1)
    ensures ring(b, h, m, n) == ring(c, h, m, n)
    decreases n
{
    if n > 0 {
        ring_prefix(b, c, h, m, n - 1);
        ring_succ(b, h, m, n);
        ring_succ(c, h, m, n);
        assert (h + (n - 1) & m) <= m by {};
        take_at(b, m as int + 1, (h + (n - 1) & m) as int);
        take_at(c, m as int + 1, (h + (n - 1) & m) as int);
    }
}

// A ring of mask `m` that wraps past `m + 1` by up to `t` elements, whose wrapped part block `c` holds again
// from slot `m + 1`: the same ring from `h` under the larger mask `mm`.
lemma ring_wrap_tail<T>(b: Seq<T>, c: Seq<T>, h: usize, m: usize, mm: usize, n: usize, t: usize)
    requires m < ZST_CAP && mm < ZST_CAP && (m & m + 1) == 0 && (mm & mm + 1) == 0 && h <= m && t <= m
    requires m + 1 + t <= mm + 1 && n <= m + 1 && h + n <= m + 1 + t && b.len() > m as int && c.len() > mm as int
    requires c.take(m as int + 1) == b.take(m as int + 1)
    requires c.subrange(m as int + 1, m as int + 1 + t as int) == b.take(t as int)
    ensures ring(c, h, mm, n) == ring(b, h, m, n)
    decreases n
{
    if h + n <= m + 1 {
        ring_same(c, b, h, mm, m, n, m + 1);
        return;
    }
    ring_wrap_tail(b, c, h, m, mm, n - 1, t);
    ring_succ(c, h, mm, n);
    ring_succ(b, h, m, n);
    low_mask(h + (n - 1), mm);
    wrap_slot(h + (n - 1), m);
    sub_at(c, m as int + 1, m as int + 1 + t as int, (h + (n - 1) - (m + 1)) as int);
    take_at(b, t as int, (h + (n - 1) - (m + 1)) as int);
}

// A ring of mask `m` from `h` whose first `hl = m + 1 - h` elements block `c` holds again in its last `hl`
// slots under mask `mm`, and whose wrapped part `c` keeps in its first `t` slots: the ring from `nh`.
lemma ring_wrap_head<T>(b: Seq<T>, c: Seq<T>, h: usize, nh: usize, m: usize, mm: usize, n: usize, t: usize)
    requires m < ZST_CAP && mm < ZST_CAP && (m & m + 1) == 0 && (mm & mm + 1) == 0 && h <= m && m <= mm
    requires t <= m && nh == mm + 1 - (m + 1 - h) && n <= m + 1 && n <= m + 1 - h + t && t <= nh && b.len() > m as int
    requires c.len() > mm as int
    requires c.subrange(nh as int, mm as int + 1) == b.subrange(h as int, m as int + 1)
    requires c.take(t as int) == b.take(t as int)
    ensures ring(c, nh, mm, n) == ring(b, h, m, n)
    decreases n
{
    if n == 0 {
        return;
    }
    ring_wrap_head(b, c, h, nh, m, mm, n - 1, t);
    ring_succ(c, nh, mm, n);
    ring_succ(b, h, m, n);
    let hl = m + 1 - h;
    if n - 1 < hl {
        low_mask(nh + (n - 1), mm);
        low_mask(h + (n - 1), m);
        sub_at(c, nh as int, mm as int + 1, (n - 1) as int);
        sub_at(b, h as int, m as int + 1, (n - 1) as int);
    } else {
        wrap_slot_end(nh, n - 1, hl, mm);
        wrap_slot(h + (n - 1), m);
        take_at(c, t as int, (n - 1 - hl) as int);
        take_at(b, t as int, (n - 1 - hl) as int);
    }
}

// `x` written in the slot before the front, the ring's new front: `x`, then the ring.
lemma ring_cons<T>(b: Seq<T>, h: usize, m: usize, n: usize, x: T)
    requires m < ZST_CAP && (m & m + 1) == 0 && h <= m && n <= m && b.len() > m as int
    ensures ring(b.update((h + m & m) as int, x), h + m & m, m, n + 1) == Seq::<T>::empty().push(x).concat(
        ring(b, h, m, n),
    )
{
    ghost let h1 = h + m & m;
    ghost let u = b.update(h1 as int, x);
    ring_len(u, h1, m, n + 1);
    ring_index(u, h1, m, n + 1, 0);
    ring_skip(u, h1, m, n + 1);
    assert (h1 + 1 & m) == h by {};
    ring_upd_out(b, h, m, n, m, x);
    head_skip(ring(u, h1, m, n + 1));
    assert ring(u, h1, m, n + 1).skip(1) == ring(b, h, m, n) by {};
    assert (h1 + 0 & m) == h1 by {};
    assert ring(u, h1, m, n + 1)[0] == x by {};
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
    // The largest power of two whose byte size fits a block (at most `isize::MAX` bytes).
    const fn max_cap() usize
        ensures |r| r >= 1 && r <= ZST_CAP && (r & r - 1) == 0
        ensures |r| sizeof(T) == 0 && r == ZST_CAP || sizeof(T) != 0 && r as int <= isize::MAX as int / sizeof(T) as int
    {
        if sizeof(T) == 0 {
            return ZST_CAP;
        }
        let m = isize::MAX as usize / sizeof(T);
        return 1 as usize << USIZE_BITS - 1 - m.leading_zeros();
    }

    // The byte size of `n` elements, for `n` at most `max_cap`.
    const fn bytes(n: usize) usize
        requires n <= Deque::<T, A>::max_cap()
        ensures |r| r as int == n as int * sizeof(T) as int && r as int <= isize::MAX as int
    {
        return n * sizeof(T);
    }
}

extend<T, A: Allocator> Deque<T, A> {
    /// Its elements in order, front first: element `i` lives in slot `(head + i) & (capacity - 1)` of the
    /// block, and `d.len()` is its length.
    pub spec fn view(self: &Deque<T, A>) Seq<T> {
        return if self.cap == 0 {
            Seq::<T>::empty()
        } else {
            ring(block(self.ptr), self.head, self.cap - 1, self.len)
        };
    }

    /// An empty deque that allocates through `alloc`; no allocation until the first push.
    pub const fn new_in(alloc: A) Deque<T, A>
        ensures |r| r.view() == Seq::<T>::empty()
    {
        return Deque::<T, A>::with_capacity_in(alloc, 0);
    }

    /// An empty deque with room for `cap` elements, rounded up to a power of two, allocated through `alloc`
    /// (no allocation when `cap` is 0). Panics when `cap` is past the largest capacity (the byte size
    /// overflows a usize, or 2^(N-1) zero-sized elements).
    pub const fn with_capacity_in(mut alloc: A, cap: usize) Deque<T, A>
        panics if cap > Deque::<T, A>::max_cap()
        ensures |r| r.len() == 0 && (sizeof(T) == 0 || r.capacity() >= cap) && cap <= Deque::<T, A>::max_cap()
        ensures |r| r.view() == Seq::<T>::empty()
    {
        if cap > Deque::<T, A>::max_cap() {
            panic("Deque: capacity overflow");
        }
        if sizeof(T) == 0 {
            return Deque::<T, A> { ptr: dangling::<T>(), head: 0, len: 0, cap: ZST_CAP, alloc: alloc };
        }
        if cap == 0 {
            return Deque::<T, A> { ptr: dangling::<T>(), head: 0, len: 0, cap: 0, alloc: alloc };
        }
        let c = next_pow2(cap, Deque::<T, A>::max_cap());
        let p = (unsafe alloc.alloc(c * sizeof(T), alignof(T))) as *mut T;
        return Deque::<T, A> { ptr: p, head: 0, len: 0, cap: c, alloc: alloc };
    }

    /// Number of elements.
    pub const fn len(self: &Deque<T, A>) usize
        ensures |r| r == self.len && r as int == self.view().len()
    {
        assert self.len as int == self.view().len() by {
            if self.cap > 0 {
                ring_len(block(self.ptr), self.head, self.cap - 1, self.len);
            }
        };
        return self.len;
    }

    /// True when no element is stored.
    pub const fn is_empty(self: &Deque<T, A>) bool
        ensures |r| r == (self.view().len() == 0)
    {
        return self.len() == 0;
    }

    /// Elements the block holds without growing: 0 or a power of two.
    pub const fn capacity(self: &Deque<T, A>) usize
        ensures |r| r == self.cap
    {
        return self.cap;
    }

    // The slot of logical index `i`.
    const fn slot(self: &Deque<T, A>, i: usize) usize
        requires self.cap > 0 && i <= self.cap
        ensures |r| r < self.cap && r == (self.head + i & self.cap - 1)
    {
        return self.wrap(self.head + i);
    }

    // `x` as a slot: its bits below the capacity, a power of two.
    const fn wrap(self: &Deque<T, A>, x: usize) usize
        requires self.cap > 0
        ensures |r| r < self.cap && r == (x & self.cap - 1)
    {
        return x & self.cap - 1;
    }

    /// Makes room for at least `additional` more elements. A growth sets the capacity to the smallest power of
    /// two that holds `len + additional` elements, and to at least 8. Panics when the byte size overflows a usize.
    pub fn reserve(self: &mut Deque<T, A>, additional: usize)
        panics if self.len as int + additional as int > Deque::<T, A>::max_cap() as int
        ensures self.len == old(self.len) && self.len as int + additional as int <= self.cap as int
        ensures self.view() == old(self.view())
    {
        if additional > self.cap - self.len {
            self.grow_for(additional);
        }
    }

    // The growth path of `reserve` and the pushes, out of line so their check stays small.
    @noinline
    fn grow_for(self: &mut Deque<T, A>, additional: usize)
        requires additional > self.cap - self.len
        panics if self.len as int + additional as int > Deque::<T, A>::max_cap() as int
        ensures self.len == old(self.len) && self.len as int + additional as int <= self.cap as int
        ensures self.view() == old(self.view())
    {
        let max_cap = Deque::<T, A>::max_cap();
        if additional > max_cap - self.len {
            panic("Deque: capacity overflow");
        }
        let mut new_cap = next_pow2(self.len + additional, max_cap);
        if new_cap < MIN_CAP && MIN_CAP <= max_cap {
            new_cap = MIN_CAP;
        }
        self.grow_to(new_cap);
    }

    /// Makes room for at least `additional` more elements with the smallest power-of-two capacity that holds
    /// them (no minimum of 8). Panics when the byte size overflows a usize.
    pub fn reserve_exact(self: &mut Deque<T, A>, additional: usize)
        panics if additional > self.cap - self.len && self.len as int + additional as int > Deque::<T, A>::max_cap() as int
        ensures self.len == old(self.len) && self.len as int + additional as int <= self.cap as int
    {
        if additional <= self.cap - self.len {
            return;
        }
        if additional > Deque::<T, A>::max_cap() - self.len {
            panic("Deque: capacity overflow");
        }
        self.grow_to(next_pow2(self.len + additional, Deque::<T, A>::max_cap()));
    }

    // Reallocate to `new_cap` slots (a power of two above `cap`, T not zero-sized) and restore the ring: the
    // block keeps its slots, so a wrapped deque moves the shorter of its two parts into the new space. The
    // new capacity is at least twice the old, so the moved part lands clear of both parts.
    fn grow_to(self: &mut Deque<T, A>, new_cap: usize)
        requires sizeof(T) != 0 && new_cap > self.cap && new_cap <= Deque::<T, A>::max_cap() && (new_cap & new_cap - 1) == 0
        ensures self.len == old(self.len) && self.cap == new_cap
        ensures self.view() == old(self.view())
    {
        let old_cap = self.cap;
        ghost let b0 = block(self.ptr);
        self.grow_block(new_cap);
        if old_cap == 0 {
            return;
        }
        if self.head + self.len <= old_cap {
            ring_same(b0, block(self.ptr), self.head, old_cap - 1, new_cap - 1, self.len, old_cap);
            return;
        }
        ring_prefix(b0, block(self.ptr), self.head, old_cap - 1, self.len);
        pow2_double(old_cap, new_cap);
        self.unwrap_grown(old_cap);
    }

    // After a growth from `oc` slots, a ring that wrapped past them: the shorter of its two parts moves into
    // the new slots, so that the ring is whole under the new capacity (at least twice `oc`).
    fn unwrap_grown(self: &mut Deque<T, A>, oc: usize)
        requires sizeof(T) != 0 && 0 < oc && oc <= self.cap / 2 && (oc & oc - 1) == 0 && self.len <= oc
        requires self.head < oc && self.head + self.len > oc
        ensures self.len == old(self.len) && self.cap == old(self.cap)
        ensures self.view() == ring(old(block(self.ptr)), old(self.head), oc - 1, self.len)
    {
        if self.len - (oc - self.head) < oc - self.head {
            self.move_tail(oc);
        } else {
            self.move_head(oc);
        }
    }

    // `unwrap_grown` where the wrapped part is the shorter: it moves to the slots from `oc`.
    fn move_tail(self: &mut Deque<T, A>, oc: usize)
        requires sizeof(T) != 0 && 0 < oc && oc <= self.cap / 2 && (oc & oc - 1) == 0 && self.len <= oc
        requires self.head < oc && self.head + self.len > oc
        ensures self.len == old(self.len) && self.cap == old(self.cap) && self.head == old(self.head)
        ensures self.view() == ring(old(block(self.ptr)), old(self.head), oc - 1, self.len)
    {
        ghost let b1 = block(self.ptr);
        let t = self.head + self.len - oc;
        let mut i: usize = 0;
        while i < t
            invariant self.invariant() && i <= t && t < oc && oc <= self.cap / 2 && block(self.ptr).len() == b1.len()
            invariant self.len == old(self.len) && self.cap == old(self.cap) && self.head == old(self.head)
            invariant block(self.ptr).take(oc as int) == b1.take(oc as int)
            invariant block(self.ptr).subrange(oc as int, oc as int + i as int) == b1.take(i as int)
        {
            ghost let bi = block(self.ptr);
            unsafe self.ptr[oc + i] = unsafe self.ptr[i];
            take_at(bi, oc as int, i as int);
            take_at(b1, oc as int, i as int);
            upd_take_out(bi, oc as int, (oc + i) as int, bi[i as int]);
            upd_sub_out(bi, (oc + i) as int, oc as int, (oc + i) as int, bi[i as int]);
            sub_tail(block(self.ptr), oc as int, (oc + i) as int);
            take_succ(b1, i as int);
            i += 1;
        }
        ring_wrap_tail(b1, block(self.ptr), self.head, oc - 1, self.cap - 1, self.len, t);
    }

    // `unwrap_grown` where the part before the wrap is the shorter: it moves to the last slots.
    fn move_head(self: &mut Deque<T, A>, oc: usize)
        requires sizeof(T) != 0 && 0 < oc && oc <= self.cap / 2 && (oc & oc - 1) == 0 && self.len <= oc
        requires self.head < oc && self.head + self.len > oc
        ensures self.len == old(self.len) && self.cap == old(self.cap)
        ensures self.view() == ring(old(block(self.ptr)), old(self.head), oc - 1, self.len)
    {
        ghost let b1 = block(self.ptr);
        let h = self.head;
        let hl = oc - h;
        let nh = self.cap - hl;
        let mut j: usize = 0;
        while j < hl
            invariant self.invariant() && j <= hl && hl == oc - h && nh == self.cap - hl && oc <= self.cap / 2
            invariant block(self.ptr).len() == b1.len() && self.head == h && h < oc
            invariant self.len == old(self.len) && self.cap == old(self.cap)
            invariant block(self.ptr).take(oc as int) == b1.take(oc as int)
            invariant block(self.ptr).subrange(nh as int, nh as int + j as int) == b1.subrange(
                h as int,
                h as int + j as int,
            )
        {
            ghost let bi = block(self.ptr);
            unsafe self.ptr[nh + j] = unsafe self.ptr[h + j];
            take_at(bi, oc as int, (h + j) as int);
            take_at(b1, oc as int, (h + j) as int);
            upd_take_out(bi, oc as int, (nh + j) as int, bi[(h + j) as int]);
            upd_sub_out(bi, (nh + j) as int, nh as int, (nh + j) as int, bi[(h + j) as int]);
            sub_tail(block(self.ptr), nh as int, (nh + j) as int);
            sub_tail(b1, h as int, (h + j) as int);
            j += 1;
        }
        let t = self.len - hl;
        take_take(block(self.ptr), oc as int, t as int);
        take_take(b1, oc as int, t as int);
        self.head = nh;
        ring_wrap_head(b1, block(self.ptr), h, nh, oc - 1, self.cap - 1, self.len, t);
    }

    /// Reallocates to the smallest power of two that holds the elements (frees the block when empty).
    pub fn shrink_to_fit(self: &mut Deque<T, A>)
        ensures self.len == old(self.len) && self.len <= self.cap
    {
        if sizeof(T) == 0 || self.cap == 0 {
            return;
        }
        if self.len == 0 {
            unsafe self.alloc.dealloc(self.ptr, Deque::<T, A>::bytes(self.cap), alignof(T));
            self.ptr = dangling::<T>();
            self.cap = 0;
            self.head = 0;
            return;
        }
        let target = next_pow2(self.len, Deque::<T, A>::max_cap());
        if target >= self.cap {
            return;
        }
        // Move the elements into slots 0..target first. A wrapped front part starts at or above `target`
        // (cap >= 2 * target), so it moves to the end of the new range without overlap.
        if self.head + self.len > self.cap {
            let head_len = self.cap - self.head;
            unsafe memcpy(self.ptr + (target - head_len), self.ptr + self.head, Deque::<T, A>::bytes(head_len));
            self.head = target - head_len;
        } else if self.head + self.len > target {
            unsafe memmove(self.ptr, self.ptr + self.head, Deque::<T, A>::bytes(self.len));
            self.head = 0;
        }
        self.resize_block(target);
    }

    // Reallocate the block to `new_cap` slots (`T` not zero-sized; a first block when `cap` is 0). The slots
    // below both capacities keep their elements: the ring moves after a growth and before a shrink.
    fn resize_block(self: &mut Deque<T, A>, new_cap: usize)
        requires sizeof(T) != 0 && new_cap > 0 && new_cap <= Deque::<T, A>::max_cap() && self.head < new_cap && self.len <= new_cap
        requires (new_cap & new_cap - 1) == 0
        ensures self.head == old(self.head) && self.len == old(self.len) && self.cap == new_cap
    {
        if self.cap == 0 {
            self.ptr = (unsafe self.alloc.alloc(Deque::<T, A>::bytes(new_cap), alignof(T))) as *mut T;
            self.cap = new_cap;
            return;
        }
        let p = (unsafe self.alloc.realloc(
            self.ptr,
            Deque::<T, A>::bytes(self.cap),
            Deque::<T, A>::bytes(new_cap),
            alignof(T),
        )) as *mut T;
        self.ptr = p;
        self.cap = new_cap;
    }

    // `resize_block` to a larger capacity: the slots of the old block keep their elements.
    const fn grow_block(self: &mut Deque<T, A>, new_cap: usize)
        requires sizeof(T) != 0 && new_cap > self.cap && new_cap <= Deque::<T, A>::max_cap() && (new_cap & new_cap - 1) == 0
        ensures self.head == old(self.head) && self.len == old(self.len) && self.cap == new_cap
        ensures old(self.cap) > 0 ==> block(self.ptr).take(old(self.cap) as int) == old(block(self.ptr)).take(
            old(self.cap) as int,
        )
    {
        if self.cap == 0 {
            self.ptr = (unsafe self.alloc.alloc(Deque::<T, A>::bytes(new_cap), alignof(T))) as *mut T;
            self.cap = new_cap;
            return;
        }
        let p = (unsafe self.alloc.realloc(
            self.ptr,
            Deque::<T, A>::bytes(self.cap),
            Deque::<T, A>::bytes(new_cap),
            alignof(T),
        )) as *mut T;
        self.ptr = p;
        self.cap = new_cap;
    }

    /// Appends `value` at the back; amortized O(1).
    pub fn push_back(self: &mut Deque<T, A>, value: T)
        panics if self.len as int + 1 > Deque::<T, A>::max_cap() as int
        ensures self.view() == old(self.view()).push(value) && self.len == old(self.len) + 1
    {
        if self.len() == self.cap {
            self.grow_for(1);
        }
        let n = self.len;
        let s = self.slot(n);
        ghost let b = block(self.ptr);
        ring_upd_out(b, self.head, self.cap - 1, n, n, value);
        ring_succ(b.update(s as int, value), self.head, self.cap - 1, n + 1);
        unsafe self.ptr[s] = value;
        self.len = n + 1;
    }

    /// Prepends `value` at the front; amortized O(1).
    pub fn push_front(self: &mut Deque<T, A>, value: T)
        panics if self.len as int + 1 > Deque::<T, A>::max_cap() as int
        ensures self.view() == Seq::<T>::empty().push(value).concat(old(self.view())) && self.len == old(self.len) + 1
    {
        if self.len() == self.cap {
            self.grow_for(1);
        }
        let n = self.len;
        let h = self.head;
        ghost let b = block(self.ptr);
        ring_cons(b, h, self.cap - 1, n, value);
        assert (h.wrapping_sub(1) & self.cap - 1) == (h + (self.cap - 1) & self.cap - 1) by {};
        self.head = self.wrap(h.wrapping_sub(1));
        unsafe self.ptr[self.head] = value;
        self.len = n + 1;
    }

    /// Removes the back element and moves it to the caller; None when empty.
    pub const fn pop_back(self: &mut Deque<T, A>) Option<T>
        ensures |r| old(self.view()).len() == 0 ==> r == Option::<T>::None && self.view() == old(self.view())
        ensures |r| old(self.view()).len() > 0 ==> r == Some(old(self.view())[old(self.view()).len() - 1])
        ensures old(self.view()).len() > 0 ==> self.view() == old(self.view()).take(old(self.view()).len() - 1)
    {
        if self.len == 0 {
            return None;
        }
        let n = self.len;
        ghost let b = block(self.ptr);
        ring_len(b, self.head, self.cap - 1, n);
        ring_index(b, self.head, self.cap - 1, n, n - 1);
        ring_take(b, self.head, self.cap - 1, n, n - 1);
        self.len = n - 1;
        return Some(unsafe self.ptr[self.slot(self.len)]);
    }

    /// Removes the front element and moves it to the caller; None when empty.
    pub const fn pop_front(self: &mut Deque<T, A>) Option<T>
        ensures |r| old(self.view()).len() == 0 ==> r == Option::<T>::None && self.view() == old(self.view())
        ensures |r| old(self.view()).len() > 0 ==> r == Some(old(self.view())[0])
        ensures old(self.view()).len() > 0 ==> self.view() == old(self.view()).skip(1)
    {
        if self.len == 0 {
            return None;
        }
        let n = self.len;
        ghost let b = block(self.ptr);
        ring_len(b, self.head, self.cap - 1, n);
        ring_index(b, self.head, self.cap - 1, n, 0);
        ring_skip(b, self.head, self.cap - 1, n);
        assert (self.head + 0 & self.cap - 1) == self.head by {};
        let v = unsafe self.ptr[self.head];
        self.head = self.wrap(self.head + 1);
        self.len = n - 1;
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
    const fn copy_ring(self: &mut Deque<T, A>, src: usize, dst: usize, n: usize)
        requires n == 0 || self.cap > 0 && src < self.cap && dst < self.cap && n <= self.cap
        ensures self.head == old(self.head) && self.len == old(self.len) && self.cap == old(self.cap)
    {
        if sizeof(T) == 0 || n == 0 || src == dst {
            return;
        }
        let cap = self.cap;
        let mask = cap - 1;
        let mut left = n;
        if (dst.wrapping_sub(src) & mask) >= n {
            let mut s = src;
            let mut t = dst;
            while left > 0
                invariant s < cap && t < cap && cap <= Deque::<T, A>::max_cap()
            {
                let c = left.min(cap - s.max(t));
                unsafe memmove(self.ptr + t, self.ptr + s, Deque::<T, A>::bytes(c));
                s = s + c & mask;
                t = t + c & mask;
                left -= c;
            }
        } else {
            // The ends of the runs, exclusive, in 1..=cap: a run ending at slot 0 ends at `cap`.
            let mut s = self.wrap(src + n - 1) + 1;
            let mut t = self.wrap(dst + n - 1) + 1;
            while left > 0
                invariant 0 < s && s <= cap && 0 < t && t <= cap && cap <= Deque::<T, A>::max_cap()
            {
                let c = left.min(s).min(t);
                unsafe memmove(self.ptr + (t - c), self.ptr + (s - c), Deque::<T, A>::bytes(c));
                s = self.wrap((s - c).wrapping_sub(1)) + 1;
                t = self.wrap((t - c).wrapping_sub(1)) + 1;
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
        if i < self.len - i {
            self.head = self.wrap(self.head.wrapping_sub(1));
            self.copy_ring(self.wrap(self.head + 1), self.head, i);
        } else {
            let at = self.slot(i);
            self.copy_ring(at, self.wrap(at + 1), self.len - i);
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
        let at = self.slot(i);
        let v = unsafe self.ptr[at];
        let after = self.len - 1 - i;
        if i < after {
            self.copy_ring(self.head, self.wrap(self.head + 1), i);
            self.head = self.wrap(self.head + 1);
        } else {
            self.copy_ring(self.wrap(at + 1), at, after);
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
        self.head = self.wrap(self.head + 1);
        self.len -= 1;
        return Some(v);
    }

    /// Keeps the first `n` elements and frees the others (no change when `n >= len`). Keeps the block.
    pub const fn truncate(self: &mut Deque<T, A>, n: usize)
        ensures self.len == old(self.len).min(n) && self.cap == old(self.cap) && self.head == old(self.head)
        ensures n as int >= old(self.view()).len() ==> self.view() == old(self.view())
        ensures n as int < old(self.view()).len() ==> self.view() == old(self.view()).take(n as int)
    {
        let len = self.len();
        if n >= len {
            return;
        }
        // The deque stops owning the tail before any `free` runs: one that panics leaks the rest.
        ghost let b0 = block(self.ptr);
        ring_len(b0, self.head, self.cap - 1, len);
        ring_take(b0, self.head, self.cap - 1, len, n);
        self.len = n;
        let mut i = n;
        while i < len
            invariant self.invariant() && self.len == n && n <= i && i <= len && len <= self.cap
            invariant self.cap == old(self.cap) && self.head == old(self.head) && block(self.ptr).len() == b0.len()
            invariant ring(block(self.ptr), self.head, self.cap - 1, n) == ring(b0, self.head, self.cap - 1, n)
        {
            ghost let bi = block(self.ptr);
            let s = self.slot(i);
            unsafe self.ptr[s].free();
            ring_upd_out(bi, self.head, self.cap - 1, n, i, block(self.ptr)[s as int]);
            i += 1;
        }
    }

    /// Frees every element and keeps the block.
    pub const fn clear(self: &mut Deque<T, A>)
        ensures self.len == 0 && self.cap == old(self.cap)
        ensures self.view() == Seq::<T>::empty()
    {
        self.truncate(0);
        self.head = 0;
    }

    /// Keeps the elements for which `pred` returns true, in order, and frees the others. `pred` borrows
    /// each element once, front to back.
    pub fn retain<F: fn(&T) bool>(self: &mut Deque<T, A>, pred: F) {
        let mut w: usize = 0;
        let n = self.len;
        for r in 0..n
            invariant self.invariant() && self.len == n && w <= r
        {
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
    const fn rotate_back(self: &mut Deque<T, A>, k: usize)
        requires 0 < k && k < self.len
    {
        self.head = self.wrap(self.head.wrapping_sub(k));
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
        // The two runs of `other`: from its head to the end of its block, then from the block's start.
        let first = n.min(other.cap - other.head);
        self.copy_in(self.len, unsafe (other.ptr + other.head), first);
        self.copy_in(self.len + first, other.ptr, n - first);
        self.len += n;
        other.len = 0;
        other.head = 0;
    }

    // Copy the `n` elements at `src` bitwise to logical indexes `at..` (free slots, inside the capacity).
    const fn copy_in(self: &mut Deque<T, A>, at: usize, src: *const T, n: usize)
        requires n == 0 || self.cap > 0 && at <= self.cap && n <= self.cap
        ensures self.head == old(self.head) && self.len == old(self.len) && self.cap == old(self.cap)
    {
        if sizeof(T) == 0 || n == 0 {
            return;
        }
        let start = self.slot(at);
        let first = n.min(self.cap - start);
        unsafe memcpy(self.ptr + start, src, Deque::<T, A>::bytes(first));
        unsafe memcpy(self.ptr, src + first, Deque::<T, A>::bytes(n - first));
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
                unsafe memmove(p + head_len, p, Deque::<T, A>::bytes(tail_len));
                unsafe memcpy(p, p + self.head, Deque::<T, A>::bytes(head_len));
                self.head = 0;
            } else if free >= tail_len {
                // EF..ABCD -> ..ABCDEF
                unsafe memmove(p + tail_len, p + self.head, Deque::<T, A>::bytes(head_len));
                unsafe memcpy(p + self.len, p, Deque::<T, A>::bytes(tail_len));
                self.head = tail_len;
            } else if head_len > tail_len {
                // FG.ABCDE -> .FGABCDE, then rotate the run left by the tail.
                unsafe memmove(p + free, p, Deque::<T, A>::bytes(tail_len));
                rotate_raw(unsafe (p + free), self.len, tail_len);
                self.head = free;
            } else {
                // DEFG.ABC -> DEFGABC., then rotate the run right by the head part.
                unsafe memmove(p + tail_len, p + self.head, Deque::<T, A>::bytes(head_len));
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
    pub const fn new() Deque<T, A>
        ensures |r| r.view() == Seq::<T>::empty()
    {
        return Deque::<T, A>::with_capacity_in(A::default(), 0);
    }

    /// An empty deque on the default allocator with room for `cap` elements, rounded up to a power of two.
    pub const fn with_capacity(cap: usize) Deque<T, A>
        panics if cap > Deque::<T, A>::max_cap()
        ensures |r| r.view() == Seq::<T>::empty() && cap <= Deque::<T, A>::max_cap()
    {
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
        while lo < hi
            invariant hi <= self.len
        {
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
            unsafe self.alloc.dealloc(self.ptr, Deque::<T, A>::bytes(self.cap), alignof(T));
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

// The slice borrows, so each element is cloned in. Panics when the slice holds more elements than the
// largest capacity.
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
        let n = self.len;
        let mut out = Deque::<T, A>::with_capacity_in(self.alloc, n);
        for i in 0..n
            invariant out.invariant() && out.len == i && n <= Deque::<T, A>::max_cap()
        {
            let e = self.at(i).clone();
            out.push_back(e);
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
