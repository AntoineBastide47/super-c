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

/// The UTF-8 encoding of `c`, the bytes `String::push` appends: one byte below 0x80, two below 0x800,
/// three below 0x10000, four else; a single byte is `c` itself.
@trusted
pub spec fn utf8(c: char) Seq<u8>;

extend<T, A: Allocator> Vector<T, A> {
    /// Its elements in order: `v[i]` is `v.view()[i]`, `v.len()` its length. `push`, `pop`, `clear`, a
    /// write `v[i] = x`, `Vector::new` and `with_capacity` change the view as they change the vector.
    @trusted
    pub spec fn view(self: &Vector<T, A>) Seq<T>;
}

extend<A: Allocator> String<A> {
    /// Its bytes in order: `s.len()` is its length. `push`, `push_str`, `clear` and `String::new` change
    /// the view as they change the string.
    @trusted
    pub spec fn view(self: &String<A>) Seq<u8>;
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
