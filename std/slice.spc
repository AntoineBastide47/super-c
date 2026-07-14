// Slice<T> / SliceMut<T>: borrowed (ptr, len) views over a contiguous run of `T`. Non-owning -- they
// never allocate or resize; the backing storage outlives them. `Slice<T>` is read-only; `SliceMut<T>`
// permits in-place writes. These are the prelude types `[]T` and `[]mut T` lower to (the `[]` sugar and
// array->slice coercion are wired separately); the two public fields make them plain fat pointers, so
// `s.ptr` / `s.len` are usable directly, with the methods mirroring the `str` / `Vector` surface.

// A borrowed, read-only view over `len` consecutive `T` at `ptr`.
pub struct Slice<T> {
    pub ptr: *const T, // first element
    pub len: usize, // number of elements
}

extend<T> Slice<T> {
    // Number of elements (the field and this method are the same value).
    pub const fn len(self: &Slice<T>) usize {
        return self.len;
    }

    pub const fn is_empty(self: &Slice<T>) bool {
        return self.len == 0;
    }

    // The element at `i` (no bounds check -- the caller guarantees `i < len`).
    pub const fn get(self: &Slice<T>, i: usize) T {
        return unsafe self.ptr[i];
    }

    pub const fn at(self: &Slice<T>, i: usize) &T {
        return &unsafe self.ptr[i];
    }

    // Bounds-checked borrow: `Some(&elem)` when `i < len`, else `None`.
    pub const fn get_checked(self: &Slice<T>, i: usize) Option<&T> {
        if i >= self.len {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&unsafe self.ptr[i]);
    }

    pub const fn first(self: &Slice<T>) T {
        return unsafe self.ptr[0];
    }

    pub const fn last(self: &Slice<T>) T {
        return unsafe self.ptr[self.len - 1];
    }

    // A read-only pointer to the first element (the view's backing storage).
    pub const fn as_ptr(self: &Slice<T>) *const T {
        return self.ptr;
    }
}

// A borrowed, writable view over `len` consecutive `T` at `ptr`.
pub struct SliceMut<T> {
    pub ptr: *mut T, // first element
    pub len: usize, // number of elements
}

extend<T> SliceMut<T> {
    pub const fn len(self: &SliceMut<T>) usize {
        return self.len;
    }

    pub const fn is_empty(self: &SliceMut<T>) bool {
        return self.len == 0;
    }

    pub const fn get(self: &SliceMut<T>, i: usize) T {
        return unsafe self.ptr[i];
    }

    pub const fn at(self: &SliceMut<T>, i: usize) &T {
        return &unsafe self.ptr[i];
    }

    // Bounds-checked shared borrow: `Some(&elem)` when `i < len`, else `None`.
    pub const fn get_checked(self: &SliceMut<T>, i: usize) Option<&T> {
        if i >= self.len {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&unsafe self.ptr[i]);
    }

    // Overwrite the element at `i` (no bounds check -- the caller guarantees `i < len`). Takes `&self`: a
    // `[]mut T` view grants element mutation through its internal `*mut T` regardless of the binding's
    // mutability, exactly like the `s[i] = v` index-assignment it mirrors.
    pub const fn set(self: &SliceMut<T>, i: usize, value: T) {
        unsafe self.ptr[i] = value;
    }

    pub const fn first(self: &SliceMut<T>) T {
        return unsafe self.ptr[0];
    }

    pub const fn last(self: &SliceMut<T>) T {
        return unsafe self.ptr[self.len - 1];
    }

    pub const fn as_ptr(self: &SliceMut<T>) *const T {
        return self.ptr;
    }

    // Takes `&self` for the same reason as `set`: the mutable view exposes its `*mut T` without needing a
    // mutable binding, so `[]mut T` value parameters can hand the pointer to FFI without a redundant `mut`.
    pub const fn as_mut_ptr(self: &SliceMut<T>) *mut T {
        return self.ptr;
    }
}

// Index conformances. The `[]` operator on slice VALUES keeps its inline lowering (the compiler builds
// the `{ptr,len}` view directly), so these exist for interface bounds (`fn f<C: Index<i32, []i32>>`) and
// direct calls. Unchecked like the rest of the surface: the caller keeps `i`/the range within `len`.
// `index_range` honors the written bounds: `..=` includes `r.end`; an open end arrives as `len()`.
extend<T> Slice<T> as Index<T, []T> {
    pub const fn index(self: &Slice<T>, i: usize) &T {
        if i >= self.len {
            panic("Slice[i]: index out of bounds");
        }
        return &unsafe self.ptr[i];
    }
    pub const fn index_range(self: &Slice<T>, r: Range<usize>) []T {
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        if r.start > hi || hi > self.len {
            panic("Slice[a..b]: range out of bounds");
        }
        return Slice::<T> { ptr: unsafe (self.ptr + r.start), len: hi - r.start };
    }
}

extend<T> SliceMut<T> as Index<T, []T> {
    pub const fn index(self: &SliceMut<T>, i: usize) &T {
        if i >= self.len {
            panic("SliceMut[i]: index out of bounds");
        }
        return &unsafe self.ptr[i];
    }
    pub const fn index_range(self: &SliceMut<T>, r: Range<usize>) []T {
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        if r.start > hi || hi > self.len {
            panic("Slice[a..b]: range out of bounds");
        }
        return Slice::<T> { ptr: unsafe (self.ptr + r.start), len: hi - r.start };
    }
}

extend<T> SliceMut<T> as IndexMut<T, []mut T> {
    pub const fn index_mut(self: &mut SliceMut<T>, i: usize) &mut T {
        if i >= self.len {
            panic("SliceMut[i]: index out of bounds");
        }
        return &mut unsafe self.ptr[i];
    }
    pub const fn index_range_mut(self: &mut SliceMut<T>, r: Range<usize>) []mut T {
        let hi = if r.inclusive {
            r.end + 1;
        } else {
            r.end;
        };
        if r.start > hi || hi > self.len {
            panic("SliceMut[a..b]: range out of bounds");
        }
        return SliceMut::<T> { ptr: unsafe (self.ptr + r.start), len: hi - r.start };
    }
}
