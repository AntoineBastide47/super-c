// Raw pointer mutability: the one explicit conversion from `*const T` to `*mut T`. The `as` cast between
// them is an error everywhere else, as from `&T` to `*mut T`: a shared borrow never becomes a writer by a
// cast.

/// `p` as a `*mut` pointer. The conversion itself is allowed; a write through the result while a shared
/// borrow of that memory is live is undefined behavior, unless the memory is inside an `UnsafeCell` (the
/// optimizer keeps what a shared borrow promises). For C interfaces whose `const` is wrong: a C routine
/// that returns a mutable pointer into read-only input (`strchr`, `strerror`).
pub const fn cast_mut<T>(p: *const T) *mut T {
    return p as *mut T;
}

/// `p` as a `*const` pointer, what a `*mut T` also coerces to.
pub const fn cast_const<T>(p: *mut T) *const T {
    return p;
}
