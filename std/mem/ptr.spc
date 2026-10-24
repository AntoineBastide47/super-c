// Raw pointer operations (Rust's `core::ptr`; C++ `std::bit_cast`, `std::memcpy` and `std::memmove`):
// unaligned reads and writes, bulk copies, swaps, fills, pointer distance and bit casts.
//
// Every operation except `bit_cast` is `unsafe`: it reads or writes memory the type system cannot see.
// Each states its precondition; a violated one is undefined behavior. A pointer must be non-null and,
// where the operation reads or writes `T` in place (not an `_unaligned` form), aligned to `alignof(T)`,
// also when the count is 0 (`dangling::<T>()` qualifies). The copies move bits: a read hands out an
// owning bitwise copy, a write never frees the value it overwrites, so moving a `Free` value with them
// is the caller's ownership decision. `copy`, `copy_nonoverlapping`, `swap_nonoverlapping` and
// `write_bytes` are O(n) in the count; the others are O(1). Nothing allocates; every function is safe
// from every thread under the usual data-race rule for the memory it touches.
// Import with `import std::mem::ptr;`.

extern "C" {
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
    fn memmove(dst: *mut void, src: *const void, n: usize) *mut void;
    fn memset(dst: *mut void, value: i32, n: usize) *mut void;
}

// Both members are `Copy`, so the union owns nothing. A read of the member not written reinterprets the
// bytes, at run time and at compile time (references/operations.md).
union BitCast<T: Copy, U: Copy> {
    pub from: T,
    pub to: U,
}

/// The `T` stored at `p`, which may be unaligned. The result is a bitwise copy and owns what the bytes
/// own. Safety: `p` addresses `sizeof(T)` readable bytes that hold a valid `T`.
pub unsafe fn read_unaligned<T>(p: *const u8) T {
    let mut v = unsafe zeroed::<T>();
    unsafe memcpy((&mut v) as *mut T, p, sizeof(T));
    return v;
}

/// Store `v` at `p`, which may be unaligned. Takes ownership of `v` and frees nothing at `p`.
/// Safety: `p` addresses `sizeof(T)` writable bytes.
pub unsafe const fn write_unaligned<T>(p: *mut u8, v: T) {
    unsafe memcpy(p, (&v) as *const T, sizeof(T));
    forget(v);
}

/// Copy `n` `T`s from `src` to `dst`; the regions may overlap (C `memmove`).
/// Safety: `src` is readable and `dst` writable for `n` elements, both aligned.
pub unsafe const fn copy<T>(src: *const T, dst: *mut T, n: usize) {
    unsafe memmove(dst, src, n * sizeof(T));
}

/// Copy `n` `T`s from `src` to `dst` (C `memcpy`). Safety: as `copy`, and the regions do not overlap.
pub unsafe const fn copy_nonoverlapping<T>(src: *const T, dst: *mut T, n: usize) {
    unsafe memcpy(dst, src, n * sizeof(T));
}

/// Exchange the `T` at `a` with the `T` at `b`. The two may overlap: the overlapping bytes end with the
/// value that was at `a`. Safety: `a` and `b` are readable, writable and aligned.
pub unsafe const fn swap<T>(a: *mut T, b: *mut T) {
    let t = unsafe *a;
    unsafe memmove(a, b, sizeof(T));
    unsafe *b = t;
}

/// Exchange `n` consecutive `T`s at `a` with those at `b`.
/// Safety: both regions are readable, writable and aligned for `n` elements and do not overlap.
pub unsafe const fn swap_nonoverlapping<T>(a: *mut T, b: *mut T, n: usize) {
    for i in 0..n {
        unsafe {
            let t = a[i];
            a[i] = b[i];
            b[i] = t;
        }
    }
}

/// Set every byte of `n` `T`s at `dst` to `byte` (C `memset`). Frees nothing.
/// Safety: `dst` is writable and aligned for `n` elements; the bytes must form valid `T`s before a read.
pub unsafe const fn write_bytes<T>(dst: *mut T, byte: u8, n: usize) {
    // Through a named `i32`: the compiler emits a hex or suffixed literal `byte` passed straight to the
    // `i32` parameter as 0 once the call inlines.
    let value: i32 = byte;
    unsafe memset(dst, value, n * sizeof(T));
}

/// The distance from `b` to `a` in elements (`a - b`). Traps for a zero-sized `T`.
/// Safety: both point into, or one past, the same object, and their byte distance is a multiple of
/// `sizeof(T)`.
pub unsafe const fn offset_from<T>(a: *const T, b: *const T) isize {
    return unsafe (a - b);
}

/// The bits of `v` as a `U` (C++ `std::bit_cast`): `f32` to `u32`, `[u8; 8]` to `u64`, and back. A
/// compile error unless both have one size and `U` accepts every bit pattern: an integer, a float, a
/// complex, a `char`, a raw pointer, a `Simd`, or an array of one of these. Padding bytes of `T` give
/// unspecified bits. Evaluates at compile time.
pub const fn bit_cast<U: Copy, T: Copy>(v: T) U {
    static_assert(sizeof(U) == sizeof(T), "bit_cast: the two types differ in size");
    static_assert(every_pattern_valid(type_info::<U>()), "bit_cast: the target type does not accept every bit pattern");
    let c = BitCast::<T, U> { from: v };
    return c.to;
}

// True when every bit pattern of the size is a value of the type: a `bool`, an enum, a reference or a
// function pointer has invalid patterns. A nested array is refused, as its element is not described.
const fn every_pattern_valid(info: TypeInfo) bool {
    let tag = if info.kind == TypeTag::Array {
        info.elem;
    } else {
        info.kind;
    };
    return tag == TypeTag::Int || tag == TypeTag::Uint || tag == TypeTag::Float || tag == TypeTag::Complex || tag == TypeTag::Pointer || tag == TypeTag::Simd;
}
