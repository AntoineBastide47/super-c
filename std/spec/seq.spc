// Mathematical sequences for proofs: `Seq<T>`, and `view()`, the sequence a collection holds. Only ghost
// code calls these functions; no build runs them. The functions without a body are axioms, which the
// prover gives their meaning (`prove::prove`): each states it in its documentation, and nothing else holds
// of it.

/// A finite sequence of values of `T`, indexed from 0. Two sequences are equal when they have the same
/// length and the same element at each index.
@derive(Copy)
pub struct Seq<T> {
    _e: *const T,
}

extend<T> Seq<T> {
    /// The sequence with no element: its length is 0.
    @trusted
    pub spec fn empty() Seq<T>;

    /// The number of elements.
    @trusted
    pub spec fn len(self: Seq<T>) nat;

    /// The element at index `i`: `s[i]`.
    @trusted
    pub spec fn index(self: &Seq<T>, i: int) &T
        requires 0 <= i && i < self.len();

    /// The sequence with `x` after the last element: its length is one more, its element at the old length
    /// is `x`, and the other elements are the elements of `self`.
    @trusted
    pub spec fn push(self: Seq<T>, x: T) Seq<T>;

    /// The sequence with the element at index `i` replaced by `x`.
    @trusted
    pub spec fn update(self: Seq<T>, i: int, x: T) Seq<T>
        requires 0 <= i && i < self.len();

    /// The elements from index `lo` to before index `hi`: its length is `hi - lo`, its element at `i` the
    /// element of `self` at `lo + i`.
    @trusted
    pub spec fn subrange(self: Seq<T>, lo: int, hi: int) Seq<T>
        requires 0 <= lo && lo <= hi && hi <= self.len();

    /// The elements of `self`, then the elements of `t`.
    @trusted
    pub spec fn concat(self: Seq<T>, t: Seq<T>) Seq<T>;

    /// The first `n` elements.
    pub spec fn take(self: Seq<T>, n: int) Seq<T>
        requires 0 <= n && n <= self.len()
    {
        return self.subrange(0, n);
    }

    /// The elements after the first `n`.
    pub spec fn skip(self: Seq<T>, n: int) Seq<T>
        requires 0 <= n && n <= self.len()
    {
        return self.subrange(n, self.len());
    }
}

/// The elements of the block an `@owned` field points to, in order: `block(self.ptr)[i]` is
/// `self.ptr[i]`, and an index into the field below `block(self.ptr).len()` is inside the block. A write
/// through the field changes it; a write through another pointer, or a call that receives one, may.
/// The argument is the field itself: of another pointer the sequence is unknown.
@trusted
pub spec fn block<T>(p: *mut T) Seq<T>;

/// The UTF-8 encoding of scalar value `c`, the bytes `String::push` appends: one byte below 0x80, two
/// below 0x800, three below 0x10000, four else.
pub spec fn utf8(c: u32) Seq<u8> {
    let e = Seq::<u8>::empty();
    return if c < 0x80 {
        e.push(c as u8)
    } else if c < 0x800 {
        e.push((0xC0 | c >> 6) as u8).push((0x80 | c & 0x3F) as u8)
    } else if c < 0x10000 {
        e.push((0xE0 | c >> 12) as u8).push((0x80 | c >> 6 & 0x3F) as u8).push((0x80 | c & 0x3F) as u8)
    } else {
        e.push((0xF0 | c >> 18) as u8).push((0x80 | c >> 12 & 0x3F) as u8).push((0x80 | c >> 6 & 0x3F) as u8).push(
            (0x80 | c & 0x3F) as u8,
        )
    };
}

// The view after a push of `x` at index `n` of block `b1`, of length `m`: the elements before (`b0`), then `x`.
pub lemma push_view<T>(b0: Seq<T>, b1: Seq<T>, n: int, m: int, x: T)
    requires 0 <= n && n < b1.len() && m == n + 1 && b1.take(n) == b0
    ensures b1.update(n, x).take(m) == b0.push(x)
{}

// An update of an element among the first `n`, then the first `n`: the first `n`, then the update.
pub lemma upd_take<T>(b: Seq<T>, n: int, i: int, x: T)
    requires 0 <= i && i < n && n <= b.len()
    ensures b.update(i, x).take(n) == b.take(n).update(i, x)
{}

// An update of an element past the first `n`, then the first `n`: the first `n`.
pub lemma upd_take_out<T>(b: Seq<T>, n: int, i: int, x: T)
    requires 0 <= n && n <= i && i < b.len()
    ensures b.update(i, x).take(n) == b.take(n)
{}

// The elements from `lo` to before `hi`: element `lo`, then the elements after it.
pub lemma sub_head<T>(b: Seq<T>, lo: int, hi: int)
    requires 0 <= lo && lo < hi && hi <= b.len()
    ensures b.subrange(lo, hi) == Seq::<T>::empty().push(b[lo]).concat(b.subrange(lo + 1, hi))
{}

// An update of element `i` that a subrange leaves out: the subrange.
pub lemma upd_sub_out<T>(b: Seq<T>, i: int, lo: int, hi: int, x: T)
    requires 0 <= i && i < b.len() && 0 <= lo && lo <= hi && hi <= b.len() && (i < lo || hi <= i)
    ensures b.update(i, x).subrange(lo, hi) == b.subrange(lo, hi)
{}

// A subrange of the first `n` elements: the subrange.
pub lemma take_sub<T>(b: Seq<T>, n: int, lo: int, hi: int)
    requires 0 <= lo && lo <= hi && hi <= n && n <= b.len()
    ensures b.take(n).subrange(lo, hi) == b.subrange(lo, hi)
{}

// The first `n + 1` elements, element `i` among them: the ones before it, it, then the ones after it.
pub lemma take_split<T>(f: Seq<T>, i: int, n: int)
    requires 0 <= i && i <= n && n < f.len()
    ensures f.take(n + 1) == f.take(i).push(f[i]).concat(f.subrange(i + 1, n + 1))
{}

// Element `j` of the first `n`: element `j`.
pub lemma take_at<T>(b: Seq<T>, n: int, j: int)
    requires 0 <= j && j < n && n <= b.len()
    ensures b.take(n)[j] == b[j]
{}

// A sequence and one element after it: the sequence with the element pushed.
pub lemma concat_one<T>(s: Seq<T>, x: T)
    ensures s.concat(Seq::<T>::empty().push(x)) == s.push(x)
{}

// The first `m` elements of the first `n`: the first `m`.
pub lemma take_take<T>(b: Seq<T>, n: int, m: int)
    requires 0 <= m && m <= n && n <= b.len()
    ensures b.take(n).take(m) == b.take(m)
{}

// The first `n` elements: the first `i`, then the ones from `i` to before `n`.
pub lemma take_cat<T>(b: Seq<T>, i: int, n: int)
    requires 0 <= i && i <= n && n <= b.len()
    ensures b.take(n) == b.take(i).concat(b.subrange(i, n))
{}

// The elements from `lo` to `hi`: the ones before `hi`, then element `hi`.
pub lemma sub_tail<T>(b: Seq<T>, lo: int, hi: int)
    requires 0 <= lo && lo <= hi && hi < b.len()
    ensures b.subrange(lo, hi + 1) == b.subrange(lo, hi).push(b[hi])
{}

// Element `j` of the elements from `lo` to before `hi`: element `lo + j`.
pub lemma sub_at<T>(b: Seq<T>, lo: int, hi: int, j: int)
    requires 0 <= lo && lo <= hi && hi <= b.len() && 0 <= j && j < hi - lo
    ensures b.subrange(lo, hi)[j] == b[lo + j]
{}

// A subrange of a subrange: the subrange of the shifted bounds.
pub lemma sub_sub<T>(b: Seq<T>, lo: int, hi: int, lo2: int, hi2: int)
    requires 0 <= lo && lo <= hi && hi <= b.len() && 0 <= lo2 && lo2 <= hi2 && hi2 <= hi - lo
    ensures b.subrange(lo, hi).subrange(lo2, hi2) == b.subrange(lo + lo2, lo + hi2)
{}

// Two equal subranges from `lo`: equal first elements, and equal subranges from `lo + 1`.
pub lemma sub_eq_head<T>(a: Seq<T>, b: Seq<T>, lo: int, hi: int)
    requires 0 <= lo && lo < hi && hi <= a.len() && hi <= b.len() && a.subrange(lo, hi) == b.subrange(lo, hi)
    ensures a[lo] == b[lo] && a.subrange(lo + 1, hi) == b.subrange(lo + 1, hi)
{
    sub_at(a, lo, hi, 0);
    sub_at(b, lo, hi, 0);
    sub_sub(a, lo, hi, 1, hi - lo);
    sub_sub(b, lo, hi, 1, hi - lo);
}

extend str {
    /// Its bytes in order.
    @trusted
    pub spec fn view(self: str) Seq<u8>;
}

extend<T> Slice<T> {
    /// Its elements in order: `s[i]` is `s.view()[i]`, `s.len()` its length.
    @trusted
    pub spec fn view(self: &Slice<T>) Seq<T>;
}

extend<T> SliceMut<T> {
    /// Its elements in order: `s[i]` is `s.view()[i]`, `s.len()` its length; a write `s[i] = x` changes it.
    @trusted
    pub spec fn view(self: &SliceMut<T>) Seq<T>;
}
