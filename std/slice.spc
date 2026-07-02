// Slice<T> / SliceMut<T>: borrowed (ptr, len) views over a contiguous run of `T`. Non-owning -- they
// never allocate or resize; the backing storage outlives them. `Slice<T>` is read-only; `SliceMut<T>`
// permits in-place writes. These are the prelude types `[]T` and `[]mut T` lower to (the `[]` sugar and
// array->slice coercion are wired separately); the two public fields make them plain fat pointers, so
// `s.ptr` / `s.len` are usable directly, with the methods mirroring the `str` / `Vector` surface.

// A borrowed, read-only view over `len` consecutive `T` at `ptr`.
pub struct Slice<T> {
    pub ptr: *const T, // first element
    pub len: usize,    // number of elements
}

extend<T> Slice<T> {
    // Number of elements (the field and this method are the same value).
    pub fn len(self: &Slice<T>) usize {
        return self.len;
    }

    pub fn is_empty(self: &Slice<T>) bool {
        return self.len == 0;
    }

    // The element at `i` (no bounds check -- the caller guarantees `i < len`).
    pub fn get(self: &Slice<T>, i: usize) T {
        return self.ptr[i];
    }

    pub fn at(self: &Slice<T>, i: usize) &T {
        return &self.ptr[i];
    }

    // Bounds-checked borrow: `Some(&elem)` when `i < len`, else `None`.
    pub fn get_checked(self: &Slice<T>, i: usize) Option<&T> {
        if i >= self.len {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&self.ptr[i]);
    }

    pub fn first(self: &Slice<T>) T {
        return self.ptr[0];
    }

    pub fn last(self: &Slice<T>) T {
        return self.ptr[self.len - 1];
    }

    // A read-only pointer to the first element (the view's backing storage).
    pub fn as_ptr(self: &Slice<T>) *const T {
        return self.ptr;
    }

}

// A borrowed, writable view over `len` consecutive `T` at `ptr`.
pub struct SliceMut<T> {
    pub ptr: *mut T, // first element
    pub len: usize,  // number of elements
}

extend<T> SliceMut<T> {
    pub fn len(self: &SliceMut<T>) usize {
        return self.len;
    }

    pub fn is_empty(self: &SliceMut<T>) bool {
        return self.len == 0;
    }

    pub fn get(self: &SliceMut<T>, i: usize) T {
        return self.ptr[i];
    }

    pub fn at(self: &SliceMut<T>, i: usize) &T {
        return &self.ptr[i];
    }

    // Bounds-checked shared borrow: `Some(&elem)` when `i < len`, else `None`.
    pub fn get_checked(self: &SliceMut<T>, i: usize) Option<&T> {
        if i >= self.len {
            return Option::<&T>::None;
        }
        return Option::<&T>::Some(&self.ptr[i]);
    }

    // Overwrite the element at `i` (no bounds check -- the caller guarantees `i < len`). Takes `&self`: a
    // `[]mut T` view grants element mutation through its internal `*mut T` regardless of the binding's
    // mutability, exactly like the `s[i] = v` index-assignment it mirrors.
    pub fn set(self: &SliceMut<T>, i: usize, value: T) {
        self.ptr[i] = value;
    }

    pub fn first(self: &SliceMut<T>) T {
        return self.ptr[0];
    }

    pub fn last(self: &SliceMut<T>) T {
        return self.ptr[self.len - 1];
    }

    pub fn as_ptr(self: &SliceMut<T>) *const T {
        return self.ptr;
    }

    // Takes `&self` for the same reason as `set`: the mutable view exposes its `*mut T` without needing a
    // mutable binding, so `[]mut T` value parameters can hand the pointer to FFI without a redundant `mut`.
    pub fn as_mut_ptr(self: &SliceMut<T>) *mut T {
        return self.ptr;
    }

}
