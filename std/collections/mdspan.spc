// Multidimensional views over a slice, after C++ <mdspan>. `MdSpan<'a, T, R>` reads and `MdSpanMut<'a, T, R>`
// writes the elements of a `[]'a T` or `[]'a mut T` through R run-time extents and R strides in element units:
// index tuple (i0, .., iR-1) is element `i0 * stride(0) + .. + iR-1 * stride(R-1)` of the slice. A view owns
// nothing, never allocates, and borrows its slice for `'a`: the slice cannot be moved, resized or written
// elsewhere while a view of it lives, so a view never dangles and no operation invalidates another view.
//
// Layouts, with the C++ names: `row_major` is `layout_right` (the last index is contiguous, strides are the
// products of the later extents), `col_major` is `layout_left` (the first index is contiguous), `strided` is
// `layout_stride` with caller strides. Unlike `layout_stride`, a stride may be 0, which repeats one element
// along that dimension (broadcasting); such a view is not unique, and writes through two index tuples that
// differ only there reach one element.
//
// Validation: every constructor checks, once, that the element count, every stride and the required span
// size (the largest offset plus one) fit `usize`, and that the largest offset is below the slice length. A
// failure returns `MdSpanError`: extents often come from user data, so a bad shape is an expected error, not a
// panic. A view with a zero extent has no elements and needs no slice elements; `strided` then accepts any
// strides, while the strides that `row_major` and `col_major` compute must still fit `usize`. After
// construction an in-range index tuple always maps inside the slice, so access needs no overflow check.
//
// Complexity: construction, `get`, `get_checked`, `get_mut`, `set`, `size`, `slice_dim` and `fix` are O(R)
// (`get` is R compares and one multiply-add chain); `is_unique`, `is_exhaustive` and `is_contiguous` are
// O(R^2). Iteration visits the index tuples in row-major order (the last index fastest, whatever the layout)
// at O(1) amortized per element when every extent is at least 2, O(R) in the worst case; it is
// double-ended with an exact size. `as_slice` gives the fastest walk over a contiguous view.
//
// Thread safety: `MdSpan` and `MdIter` are `Send` and `Sync` when `T` is `Sync`, as `&T` is; `MdSpanMut` is
// `Send` when `T` is `Send` and `Sync` when `T` is `Sync`, as `&mut T` is. `MdSpan` is `Copy`; `MdSpanMut` is
// exclusive like `[]mut T`: it moves, and its sub-views reborrow it.

/// Why a constructor rejected a shape.
@derive(Eq, Format)
pub enum MdSpanError {
    /// The element count, a stride, or the required span size (the largest offset plus one) does not fit
    /// `usize`.
    Overflow,
    /// The slice has `len` elements; the largest offset needs `required` (C++ `required_span_size`).
    TooShort { required: usize, len: usize },
}

// Extents and strides of a view. Invariant, set by `checked_span`: the element count and every offset of an
// in-range index tuple fit `usize`.
@derive(Copy)
struct Shape<const R: usize> {
    pub(file) extents: [usize; R],
    pub(file) strides: [usize; R],
}

/// A read-only view of a slice with R dimensions. See the module comment for the layout rules.
@derive(Copy)
pub struct MdSpan<'a, T, const R: usize> {
    pub(file) data: Slice<'a, T>, // starts at the element of index (0, .., 0); len is the required span size
    pub(file) shape: Shape<R>,
}

/// A writable view of a slice with R dimensions; exclusive like `[]mut T`.
pub struct MdSpanMut<'a, T, const R: usize> {
    data: SliceMut<'a, T>, // starts at the element of index (0, .., 0); len is the required span size
    shape: Shape<R>,
}

/// The elements of an `MdSpan` in row-major index order (the last index fastest); double-ended, exact size.
pub struct MdIter<'a, T, const R: usize> {
    pub(file) ptr: *const T,
    pub(file) shape: Shape<R>,
    // A run is a sequence of elements one `step` apart: the last dimensions, fused while each stride is the
    // run's reach. `outer` dimensions remain, and their indices are the digits below.
    pub(file) step: usize,
    pub(file) run_len: usize,
    pub(file) outer: usize,
    pub(file) front: [usize; R], // indices of the outer dimensions at the front
    pub(file) front_offset: usize, // offset of the next element from the front
    pub(file) front_run: usize, // elements left in the front run
    pub(file) back: [usize; R], // indices of the outer dimensions at the back
    pub(file) back_offset: usize, // offset of the next element from the back
    pub(file) back_run: usize, // elements left in the back run
    pub(file) left: usize, // elements not yet yielded from either end
}

// The strides of a dense layout: `last_fastest` gives `layout_right`, else `layout_left`.
const fn dense_shape<const R: usize>(extents: [usize; R], last_fastest: bool) Result<Shape<R>, MdSpanError> {
    let mut strides: [usize; R] = [0; R];
    let mut step: usize = 1;
    for k in 0..R {
        let d = if last_fastest {
            R - 1 - k;
        } else {
            k;
        };
        unsafe {
            strides[d] = step;
        }
        if k + 1 < R {
            let (next, overflow) = step.overflowing_mul(unsafe extents[d]);
            if overflow {
                return Result::<Shape<R>, MdSpanError>::Err(MdSpanError::Overflow);
            }
            step = next;
        }
    }
    return Result::<Shape<R>, MdSpanError>::Ok(Shape::<R> { extents: extents, strides: strides });
}

// The required span size of `shape` over a slice of `len` elements, or why the shape does not fit it.
const fn checked_span<const R: usize>(shape: &Shape<R>, len: usize) Result<usize, MdSpanError> {
    if shape.is_empty() {
        // No index tuple exists: nothing is read, so neither the strides nor the slice matter.
        return Result::<usize, MdSpanError>::Ok(0);
    }
    let mut count: usize = 1;
    let mut last: usize = 0;
    for k in 0..R {
        let extent = unsafe shape.extents[k];
        let (c, count_overflow) = count.overflowing_mul(extent);
        let (term, term_overflow) = (extent - 1).overflowing_mul(unsafe shape.strides[k]);
        let (l, last_overflow) = last.overflowing_add(term);
        if count_overflow || term_overflow || last_overflow {
            return Result::<usize, MdSpanError>::Err(MdSpanError::Overflow);
        }
        count = c;
        last = l;
    }
    if last == usize::MAX {
        return Result::<usize, MdSpanError>::Err(MdSpanError::Overflow);
    }
    if last >= len {
        return Result::<usize, MdSpanError>::Err(MdSpanError::TooShort { required: last + 1, len: len });
    }
    return Result::<usize, MdSpanError>::Ok(last + 1);
}

// The dimensions of extent above 1 that move the offset (stride above 0), sorted by stride: (strides,
// extents, count). The other dimensions add nothing to the set of offsets.
const fn moving_dims<const R: usize>(shape: &Shape<R>) ([usize; R], [usize; R], usize) {
    let mut strides: [usize; R] = [0; R];
    let mut extents: [usize; R] = [0; R];
    let mut n: usize = 0;
    for k in 0..R {
        let (e, s) = unsafe (shape.extents[k], shape.strides[k]);
        if e > 1 && s > 0 {
            let mut j = n;
            while j > 0 && unsafe strides[j - 1] > s {
                unsafe {
                    strides[j] = strides[j - 1];
                    extents[j] = extents[j - 1];
                }
                j -= 1;
            }
            unsafe {
                strides[j] = s;
                extents[j] = e;
            }
            n += 1;
        }
    }
    return strides, extents, n;
}

extend<const R: usize> Shape<R> {
    const fn extent(self: &Shape<R>, d: usize) usize {
        if d >= R {
            panic("mdspan: dimension out of range");
        }
        return unsafe self.extents[d];
    }

    const fn stride(self: &Shape<R>, d: usize) usize {
        if d >= R {
            panic("mdspan: dimension out of range");
        }
        return unsafe self.strides[d];
    }

    // True when some extent is 0. Such a shape has no index tuple, and its strides may be any values.
    const fn is_empty(self: &Shape<R>) bool {
        for k in 0..R {
            if unsafe self.extents[k] == 0 {
                return true;
            }
        }
        return false;
    }

    const fn size(self: &Shape<R>) usize {
        if self.is_empty() {
            return 0;
        }
        let mut count: usize = 1;
        for k in 0..R {
            count *= unsafe self.extents[k];
        }
        return count;
    }

    // Offset of `idx`; panics unless every index is below its extent.
    const fn offset(self: &Shape<R>, idx: [usize; R]) usize {
        let mut offset: usize = 0;
        for k in 0..R {
            let i = unsafe idx[k];
            if i >= unsafe self.extents[k] {
                panic("mdspan: index out of bounds");
            }
            offset += i * unsafe self.strides[k];
        }
        return offset;
    }

    // Offset of `idx`, or None unless every index is below its extent.
    const fn offset_checked(self: &Shape<R>, idx: [usize; R]) Option<usize> {
        let mut offset: usize = 0;
        for k in 0..R {
            let i = unsafe idx[k];
            if i >= unsafe self.extents[k] {
                return Option::<usize>::None;
            }
            offset += i * unsafe self.strides[k];
        }
        return Option::<usize>::Some(offset);
    }

    // Offset of `idx` without bounds checks: the caller proves every index is below its extent.
    unsafe const fn offset_unchecked(self: &Shape<R>, idx: [usize; R]) usize {
        let mut offset: usize = 0;
        for k in 0..R {
            offset += idx[k] * self.strides[k];
        }
        return offset;
    }

    // C++ `[mdspan.layout.stride.cons]` uniqueness condition, over the dimensions that move the offset.
    const fn is_unique(self: &Shape<R>) bool {
        if self.is_empty() {
            return true;
        }
        for k in 0..R {
            if unsafe self.extents[k] > 1 && unsafe self.strides[k] == 0 {
                return false;
            }
        }
        let (strides, extents, n) = moving_dims(self);
        for k in 1..n {
            let (reach, overflow) = unsafe strides[k - 1].overflowing_mul(extents[k - 1]);
            if overflow || unsafe strides[k] < reach {
                return false;
            }
        }
        return true;
    }

    // A mixed-radix numbering of [0, span) by the dimensions that move the offset.
    const fn is_exhaustive(self: &Shape<R>) bool {
        if self.is_empty() {
            return true;
        }
        let (strides, extents, n) = moving_dims(self);
        let mut reach: usize = 1;
        for k in 0..n {
            if unsafe strides[k] != reach {
                return false;
            }
            reach = unsafe (strides[k] * extents[k]);
        }
        return true;
    }

    // `self` with dimension `d` narrowed to [lo, hi), and the offset of its first element (0 when empty).
    const fn sliced(self: &Shape<R>, d: usize, lo: usize, hi: usize) (Shape<R>, usize) {
        if d >= R {
            panic("mdspan::slice_dim: dimension out of range");
        }
        if lo > hi || hi > unsafe self.extents[d] {
            panic("mdspan::slice_dim: range out of bounds");
        }
        let mut out = *self;
        unsafe {
            out.extents[d] = hi - lo;
        }
        if out.is_empty() {
            return out, 0;
        }
        return out, lo * unsafe self.strides[d];
    }

    // `self` without dimension `d`, at index `i` of it, and the offset of that hyperplane (0 when empty).
    const fn fixed(self: &Shape<R>, d: usize, i: usize) (Shape<{R - 1}>, usize) {
        if d >= R {
            panic("mdspan::fix: dimension out of range");
        }
        if i >= unsafe self.extents[d] {
            panic("mdspan::fix: index out of bounds");
        }
        let mut out = Shape::<{R - 1}> { extents: [0; R - 1], strides: [0; R - 1] };
        let mut j: usize = 0;
        for k in 0..R {
            if k != d {
                unsafe {
                    out.extents[j] = self.extents[k];
                    out.strides[j] = self.strides[k];
                }
                j += 1;
            }
        }
        if out.is_empty() {
            return out, 0;
        }
        return out, i * unsafe self.strides[d];
    }

    // The required span size: 0 without elements, else the largest offset plus one. Fits `usize` by the
    // invariant.
    const fn span(self: &Shape<R>) usize {
        if self.is_empty() {
            return 0;
        }
        let mut last: usize = 0;
        for k in 0..R {
            last += (unsafe self.extents[k] - 1) * unsafe self.strides[k];
        }
        return last + 1;
    }
}

extend Shape<2> {
    const fn transposed(self: &Shape<2>) Shape<2> {
        return Shape::<2> { extents: [self.extents[1], self.extents[0]], strides: [self.strides[1], self.strides[0]] };
    }
}

extend<'a, T, const R: usize> MdSpan<'a, T, R> {
    /// The `layout_right` view of `data`: the last index is contiguous. Err when the extents do not fit `data`.
    pub const fn row_major(data: []'a T, extents: [usize; R]) Result<MdSpan<'a, T, R>, MdSpanError> {
        let shape = dense_shape(extents, true)?;
        return MdSpan::<'a, T, R>::checked(data, shape);
    }

    /// The `layout_left` view of `data`: the first index is contiguous. Err when the extents do not fit `data`.
    pub const fn col_major(data: []'a T, extents: [usize; R]) Result<MdSpan<'a, T, R>, MdSpanError> {
        let shape = dense_shape(extents, false)?;
        return MdSpan::<'a, T, R>::checked(data, shape);
    }

    /// The `layout_stride` view of `data` with `strides` in elements; a stride may be 0 (broadcasting). Err
    /// when an index tuple maps outside `data` or a size overflows.
    pub const fn strided(data: []'a T, extents: [usize; R], strides: [usize; R]) Result<MdSpan<'a, T, R>, MdSpanError> {
        return MdSpan::<'a, T, R>::checked(data, Shape::<R> { extents: extents, strides: strides });
    }

    const fn checked(data: []'a T, shape: Shape<R>) Result<MdSpan<'a, T, R>, MdSpanError> {
        let span = checked_span(&shape, data.len)?;
        let view = unsafe Slice::<'a, T> { ptr: data.ptr, len: span };
        return Result::<MdSpan<'a, T, R>, MdSpanError>::Ok(MdSpan::<'a, T, R> { data: view, shape: shape });
    }

    // The view of `shape` whose first element is at `offset`; the caller proves it is a sub-view of `self`.
    const fn sub<const N: usize>(self: &MdSpan<'a, T, R>, shape: Shape<N>, offset: usize) MdSpan<'a, T, N> {
        let view = unsafe Slice::<'a, T> { ptr: self.data.ptr + offset, len: shape.span() };
        return MdSpan::<'a, T, N> { data: view, shape: shape };
    }

    /// The number of dimensions, R.
    pub const fn rank(self: &MdSpan<'a, T, R>) usize {
        return R;
    }

    /// The extent of dimension `d`. Panics: `d >= R`.
    pub const fn extent(self: &MdSpan<'a, T, R>, d: usize) usize {
        return self.shape.extent(d);
    }

    /// Every extent.
    pub const fn extents(self: &MdSpan<'a, T, R>) [usize; R] {
        return self.shape.extents;
    }

    /// The stride of dimension `d` in elements. Panics: `d >= R`.
    pub const fn stride(self: &MdSpan<'a, T, R>, d: usize) usize {
        return self.shape.stride(d);
    }

    /// Every stride, in elements.
    pub const fn strides(self: &MdSpan<'a, T, R>) [usize; R] {
        return self.shape.strides;
    }

    /// The number of index tuples: the product of the extents (1 for R = 0).
    pub const fn size(self: &MdSpan<'a, T, R>) usize {
        return self.shape.size();
    }

    /// True when some extent is 0.
    pub const fn is_empty(self: &MdSpan<'a, T, R>) bool {
        return self.data.len == 0;
    }

    /// True only when no two index tuples map to one element (C++ `is_unique`). Exact for the layouts that
    /// meet the C++ `layout_stride` condition (the strides, sorted, each reach the previous stride times its
    /// extent), false for a zero stride over an extent above 1, and false for some unique layouts with
    /// interleaved strides, which C++ allows: an exact answer is not feasible in general.
    pub const fn is_unique(self: &MdSpan<'a, T, R>) bool {
        return self.shape.is_unique();
    }

    /// True only when every element of the required span is reached (C++ `is_exhaustive`). Exact for unique
    /// layouts; false for some overlapping layouts that cover the span.
    pub const fn is_exhaustive(self: &MdSpan<'a, T, R>) bool {
        return self.shape.is_exhaustive();
    }

    /// True: every view of this module has a stride per dimension (C++ `is_strided`).
    pub const fn is_strided(self: &MdSpan<'a, T, R>) bool {
        return true;
    }

    /// True when the elements fill a slice of `size()` elements, each once: unique and exhaustive.
    pub const fn is_contiguous(self: &MdSpan<'a, T, R>) bool {
        return self.shape.is_unique() && self.shape.is_exhaustive();
    }

    /// The `size()` elements in memory order when `is_contiguous`, else None. Memory order is row-major
    /// index order only for a row-major layout.
    pub const fn as_slice(self: &MdSpan<'a, T, R>) Option<[]'a T> {
        if !self.is_contiguous() {
            return Option::<[]'a T>::None;
        }
        return Option::<[]'a T>::Some(self.data);
    }

    /// The element at `idx`. Panics: an index is not below its extent.
    pub const fn get(self: &MdSpan<'a, T, R>, idx: [usize; R]) &'a T {
        let offset = self.shape.offset(idx);
        return unsafe &*(self.data.ptr + offset);
    }

    /// The element at `idx`, or None when an index is not below its extent.
    pub const fn get_checked(self: &MdSpan<'a, T, R>, idx: [usize; R]) Option<&'a T> {
        if let Some(offset) = self.shape.offset_checked(idx) {
            return Option::<&'a T>::Some(unsafe &*(self.data.ptr + offset));
        }
        return Option::<&'a T>::None;
    }

    /// The element at `idx` without bounds checks. Safety: every index is below its extent.
    pub unsafe const fn get_unchecked(self: &MdSpan<'a, T, R>, idx: [usize; R]) &'a T {
        return &*(self.data.ptr + self.shape.offset_unchecked(idx));
    }

    /// The view with dimension `d` narrowed to the indices [lo, hi), renumbered from 0; same rank, no copy (C++
    /// `submdspan` with a range). Panics: `d >= R`, `lo > hi` or `hi > extent(d)`.
    pub const fn slice_dim(self: &MdSpan<'a, T, R>, d: usize, lo: usize, hi: usize) MdSpan<'a, T, R> {
        let (shape, offset) = self.shape.sliced(d, lo, hi);
        return self.sub(shape, offset);
    }

    /// The rank R - 1 view of the elements whose index in dimension `d` is `i`, no copy (C++ `submdspan` with
    /// an integer). `R = 0` is a compile error. Panics: `d >= R` or `i >= extent(d)`.
    pub const fn fix(self: &MdSpan<'a, T, R>, d: usize, i: usize) MdSpan<'a, T, {R - 1}> {
        let (shape, offset) = self.shape.fixed(d, i);
        return self.sub(shape, offset);
    }

    /// The elements in row-major index order, as `&'a T`.
    pub const fn iter(self: &MdSpan<'a, T, R>) MdIter<'a, T, R> {
        let left = self.shape.size();
        let mut back: [usize; R] = [0; R];
        let mut step: usize = 0;
        let mut run_len: usize = 1;
        let mut outer = R;
        if R > 0 && left > 0 {
            step = unsafe self.shape.strides[R - 1];
            while outer > 0 {
                let (e, s) = unsafe (self.shape.extents[outer - 1], self.shape.strides[outer - 1]);
                let (reach, overflow) = step.overflowing_mul(run_len);
                if e > 1 && (overflow || s != reach) {
                    break;
                }
                run_len *= e;
                outer -= 1;
            }
            for k in 0..outer {
                unsafe {
                    back[k] = self.shape.extents[k] - 1;
                }
            }
        }
        return MdIter::<'a, T, R> {
            ptr: self.data.ptr,
            shape: self.shape,
            step: step,
            run_len: run_len,
            outer: outer,
            front: [0; R],
            front_offset: 0,
            front_run: run_len,
            back: back,
            back_offset: if left > 0 {
                self.data.len - 1;
            } else {
                0;
            },
            back_run: run_len,
            left: left,
        };
    }
}

extend<'a, T> MdSpan<'a, T, 2> {
    /// The 2-D view with the two dimensions swapped: `t.get([j, i])` is `get([i, j])`. No copy.
    pub const fn transpose(self: &MdSpan<'a, T, 2>) MdSpan<'a, T, 2> {
        return MdSpan::<'a, T, 2> { data: self.data, shape: self.shape.transposed() };
    }
}

extend<'a, T, const R: usize> MdSpanMut<'a, T, R> {
    /// The `layout_right` view of `data`: the last index is contiguous. Err when the extents do not fit `data`.
    pub const fn row_major(data: []'a mut T, extents: [usize; R]) Result<MdSpanMut<'a, T, R>, MdSpanError> {
        let shape = dense_shape(extents, true)?;
        return MdSpanMut::<'a, T, R>::checked(data, shape);
    }

    /// The `layout_left` view of `data`: the first index is contiguous. Err when the extents do not fit `data`.
    pub const fn col_major(data: []'a mut T, extents: [usize; R]) Result<MdSpanMut<'a, T, R>, MdSpanError> {
        let shape = dense_shape(extents, false)?;
        return MdSpanMut::<'a, T, R>::checked(data, shape);
    }

    /// The `layout_stride` view of `data` with `strides` in elements; a stride may be 0, and then index tuples
    /// that differ only in that dimension write one element. Err when an index tuple maps outside `data` or a
    /// size overflows.
    pub const fn strided(data: []'a mut T, extents: [usize; R], strides: [usize; R]) Result<
        MdSpanMut<'a, T, R>,
        MdSpanError
    > {
        return MdSpanMut::<'a, T, R>::checked(data, Shape::<R> { extents: extents, strides: strides });
    }

    const fn checked(data: []'a mut T, shape: Shape<R>) Result<MdSpanMut<'a, T, R>, MdSpanError> {
        let span = checked_span(&shape, data.len)?;
        let view = unsafe SliceMut::<'a, T> { ptr: data.ptr, len: span };
        return Result::<MdSpanMut<'a, T, R>, MdSpanError>::Ok(MdSpanMut::<'a, T, R> { data: view, shape: shape });
    }

    // The view of `shape` whose first element is at `offset`; the caller proves it is a sub-view of `self`.
    const fn sub<'s, const N: usize>(self: &'s mut MdSpanMut<'a, T, R>, shape: Shape<N>, offset: usize) MdSpanMut<
        's,
        T,
        N
    > {
        let view = unsafe SliceMut::<'s, T> { ptr: self.data.ptr + offset, len: shape.span() };
        return MdSpanMut::<'s, T, N> { data: view, shape: shape };
    }

    /// The number of dimensions, R.
    pub const fn rank(self: &MdSpanMut<'a, T, R>) usize {
        return R;
    }

    /// The extent of dimension `d`. Panics: `d >= R`.
    pub const fn extent(self: &MdSpanMut<'a, T, R>, d: usize) usize {
        return self.shape.extent(d);
    }

    /// Every extent.
    pub const fn extents(self: &MdSpanMut<'a, T, R>) [usize; R] {
        return self.shape.extents;
    }

    /// The stride of dimension `d` in elements. Panics: `d >= R`.
    pub const fn stride(self: &MdSpanMut<'a, T, R>, d: usize) usize {
        return self.shape.stride(d);
    }

    /// Every stride, in elements.
    pub const fn strides(self: &MdSpanMut<'a, T, R>) [usize; R] {
        return self.shape.strides;
    }

    /// The number of index tuples: the product of the extents (1 for R = 0).
    pub const fn size(self: &MdSpanMut<'a, T, R>) usize {
        return self.shape.size();
    }

    /// True when some extent is 0.
    pub const fn is_empty(self: &MdSpanMut<'a, T, R>) bool {
        return self.data.len == 0;
    }

    /// The read-only view of the same elements; `self` cannot write while it lives. The layout queries,
    /// `get_checked`, `get_unchecked`, `as_slice` and iteration are there.
    pub const fn as_view<'s>(self: &'s MdSpanMut<'a, T, R>) MdSpan<'s, T, R> {
        let view = unsafe Slice::<'s, T> { ptr: self.data.ptr, len: self.data.len };
        return MdSpan::<'s, T, R> { data: view, shape: self.shape };
    }

    /// The elements in memory order when the view is contiguous (see `MdSpan::is_contiguous`), else None.
    pub const fn as_mut_slice<'s>(self: &'s mut MdSpanMut<'a, T, R>) Option<[]'s mut T> {
        if !(self.shape.is_unique() && self.shape.is_exhaustive()) {
            return Option::<[]'s mut T>::None;
        }
        return Option::<[]'s mut T>::Some(unsafe SliceMut::<'s, T> { ptr: self.data.ptr, len: self.data.len });
    }

    /// The element at `idx`. Panics: an index is not below its extent.
    pub const fn get(self: &MdSpanMut<'a, T, R>, idx: [usize; R]) &T {
        let offset = self.shape.offset(idx);
        return &unsafe self.data.ptr[offset];
    }

    /// The element at `idx`, writable. Panics: an index is not below its extent.
    pub const fn get_mut(self: &mut MdSpanMut<'a, T, R>, idx: [usize; R]) &mut T {
        let offset = self.shape.offset(idx);
        return &mut unsafe self.data.ptr[offset];
    }

    /// The element at `idx`, writable, or None when an index is not below its extent.
    pub const fn get_checked_mut(self: &mut MdSpanMut<'a, T, R>, idx: [usize; R]) Option<&mut T> {
        if let Some(offset) = self.shape.offset_checked(idx) {
            return Option::<&mut T>::Some(&mut unsafe self.data.ptr[offset]);
        }
        return Option::<&mut T>::None;
    }

    /// The element at `idx`, writable, without bounds checks. Safety: every index is below its extent.
    pub unsafe const fn get_unchecked_mut(self: &mut MdSpanMut<'a, T, R>, idx: [usize; R]) &mut T {
        return &mut self.data.ptr[self.shape.offset_unchecked(idx)];
    }

    /// Store `value` at `idx`, freeing the element it replaces. Panics: an index is not below its extent.
    pub const fn set(self: &mut MdSpanMut<'a, T, R>, idx: [usize; R], value: T) {
        *self.get_mut(idx) = value;
    }

    /// The writable view with dimension `d` narrowed to [lo, hi), renumbered from 0; it reborrows `self`.
    /// Panics: `d >= R`, `lo > hi` or `hi > extent(d)`.
    pub const fn slice_dim(self: &mut MdSpanMut<'a, T, R>, d: usize, lo: usize, hi: usize) MdSpanMut<T, R> {
        let (shape, offset) = self.shape.sliced(d, lo, hi);
        return self.sub(shape, offset);
    }

    /// The writable rank R - 1 view of the elements whose index in dimension `d` is `i`; it reborrows `self`.
    /// `R = 0` is a compile error. Panics: `d >= R` or `i >= extent(d)`.
    pub const fn fix(self: &mut MdSpanMut<'a, T, R>, d: usize, i: usize) MdSpanMut<T, {R - 1}> {
        let (shape, offset) = self.shape.fixed(d, i);
        return self.sub(shape, offset);
    }
}

extend<'a, T> MdSpanMut<'a, T, 2> {
    /// The writable 2-D view with the two dimensions swapped; it reborrows `self`. No copy.
    pub const fn transpose(self: &mut MdSpanMut<'a, T, 2>) MdSpanMut<T, 2> {
        let shape = self.shape.transposed();
        return self.sub(shape, 0);
    }
}

extend<'a, T, const R: usize> MdIter<'a, T, R> as Iterator<&'a T> {
    pub fn next(self: &mut MdIter<'a, T, R>) Option<&'a T> {
        if self.left == 0 {
            return Option::<&'a T>::None;
        }
        self.left -= 1;
        if unlikely(self.front_run == 0) {
            // Step the outer digits to the next run; `left > 0` proves it exists.
            let mut offset = self.front_offset.wrapping_sub(self.run_len.wrapping_mul(self.step));
            let mut d = self.outer;
            while d > 0 {
                d -= 1;
                let (i, e, s) = unsafe (self.front[d], self.shape.extents[d], self.shape.strides[d]);
                if i + 1 < e {
                    unsafe {
                        self.front[d] = i + 1;
                    }
                    offset += s;
                    break;
                }
                offset -= i * s;
                unsafe {
                    self.front[d] = 0;
                }
            }
            self.front_offset = offset;
            self.front_run = self.run_len;
        }
        self.front_run -= 1;
        let element = unsafe &*(self.ptr + self.front_offset);
        self.front_offset = self.front_offset.wrapping_add(self.step);
        return Option::<&'a T>::Some(element);
    }

    pub fn size_hint(self: &MdIter<'a, T, R>) (usize, Option<usize>) {
        return self.left, Option::<usize>::Some(self.left);
    }
}

extend<'a, T, const R: usize> MdIter<'a, T, R> as DoubleEndedIterator<&'a T> {
    pub fn next_back(self: &mut MdIter<'a, T, R>) Option<&'a T> {
        if self.left == 0 {
            return Option::<&'a T>::None;
        }
        self.left -= 1;
        if unlikely(self.back_run == 0) {
            // Step the outer digits to the previous run; `left > 0` proves it exists.
            let mut offset = self.back_offset.wrapping_add(self.run_len.wrapping_mul(self.step));
            let mut d = self.outer;
            while d > 0 {
                d -= 1;
                let (i, e, s) = unsafe (self.back[d], self.shape.extents[d], self.shape.strides[d]);
                if i > 0 {
                    unsafe {
                        self.back[d] = i - 1;
                    }
                    offset -= s;
                    break;
                }
                offset += (e - 1) * s;
                unsafe {
                    self.back[d] = e - 1;
                }
            }
            self.back_offset = offset;
            self.back_run = self.run_len;
        }
        self.back_run -= 1;
        let element = unsafe &*(self.ptr + self.back_offset);
        self.back_offset = self.back_offset.wrapping_sub(self.step);
        return Option::<&'a T>::Some(element);
    }
}

unsafe extend<'a, T: Sync, const R: usize> MdSpan<'a, T, R> as Send {}

unsafe extend<'a, T: Sync, const R: usize> MdSpan<'a, T, R> as Sync {}

unsafe extend<'a, T: Send, const R: usize> MdSpanMut<'a, T, R> as Send {}

unsafe extend<'a, T: Sync, const R: usize> MdSpanMut<'a, T, R> as Sync {}

unsafe extend<'a, T: Sync, const R: usize> MdIter<'a, T, R> as Send {}

unsafe extend<'a, T: Sync, const R: usize> MdIter<'a, T, R> as Sync {}

// Appends dimension `d` and the ones after it of the elements from `offset` as nested lists.
fn fmt_dim<T: Format>(out: &mut String, ptr: *const T, shape: []usize, strides: []usize, d: usize, offset: usize) {
    if d == shape.len {
        let s = unsafe ptr[offset].fmt();
        out.push_string(&s);
        return;
    }
    out.push_str("[");
    for i in 0..shape[d] {
        if i > 0 {
            out.push_str(", ");
        }
        fmt_dim(out, ptr, shape, strides, d + 1, offset + i * strides[d]);
    }
    out.push_str("]");
}

extend<'a, T: Format, const R: usize> MdSpan<'a, T, R> as Format {
    /// Nested lists in row-major index order, one level per dimension: `[[1, 2, 3], [4, 5, 6]]` for extents
    /// [2, 3]; the element alone for R = 0.
    pub fn fmt(self: &MdSpan<'a, T, R>) String {
        let mut out = String::new();
        // An empty view may hold any strides; with zero strides the walk computes no offset.
        let strides: [usize; R] = if self.data.len == 0 {
            [0; R];
        } else {
            self.shape.strides;
        };
        fmt_dim(&mut out, self.data.ptr, self.shape.extents, strides, 0, 0);
        return out;
    }
}

extend<'a, T: Format, const R: usize> MdSpanMut<'a, T, R> as Format {
    /// The `MdSpan` form of the same elements.
    pub fn fmt(self: &MdSpanMut<'a, T, R>) String {
        return self.as_view().fmt();
    }
}
