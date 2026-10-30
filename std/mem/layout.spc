// Memory layouts: the size and alignment of a block, with overflow-checked composition (Rust's
// `core::alloc::Layout`), alignment arithmetic, and allocator calls that take a `Layout`.
//
// Invariant of every `Layout`: `align` is a power of two and `size` rounded up to `align` fits in
// `isize::MAX`, so no arithmetic on a valid layout overflows. Every operation is O(1), allocates nothing
// except `alloc_layout`, and is a pure function of its arguments (safe from every thread). A failed
// construction returns `None`; an alignment that is not a power of two passed to a helper panics.
// Import with `import std::mem::layout;`.

const ISIZE_MAX: usize = isize::MAX as usize;

/// The size and alignment of a block of memory. Construct it with `new`, `array` or `from_size_align`;
/// every value satisfies the invariant above.
@derive(Copy, Eq, Hash, Format)
pub struct Layout {
    size: usize,
    align: usize,
}

/// `x` rounded up to a multiple of `align`.
/// Panics: `align` is not a power of two, or the result does not fit in `usize`.
pub const fn align_up(x: usize, align: usize) usize {
    if !align.is_power_of_two() {
        panic("align_up: align is not a power of two");
    }
    if x > ~(0 as usize) - (align - 1) {
        panic("align_up: result overflows usize");
    }
    return x + (align - 1) & ~(align - 1);
}

/// `x` rounded down to a multiple of `align`. Panics: `align` is not a power of two.
pub const fn align_down(x: usize, align: usize) usize {
    if !align.is_power_of_two() {
        panic("align_down: align is not a power of two");
    }
    return x & ~(align - 1);
}

/// True when the address of `p` is a multiple of `align`. Panics: `align` is not a power of two.
pub const fn is_aligned<T>(p: *const T, align: usize) bool {
    if !align.is_power_of_two() {
        panic("is_aligned: align is not a power of two");
    }
    return (p as usize & align - 1) == 0;
}

/// A block for `l` from `a`, aligned to `l.align()`. A zero-size layout returns a non-null pointer with
/// that alignment and calls no allocator; never dereference it. Safe: the layout proves the size and
/// alignment are valid. Release the block with `dealloc_layout` and the same layout.
// Inlined so the leak tracker records the allocation at the caller, as `Global`'s methods are.
@always_inline
pub fn alloc_layout<A: Allocator>(a: &mut A, l: Layout) *mut void {
    if l.size() == 0 {
        return l.align() as *mut void;
    }
    return unsafe a.alloc(l.size(), l.align());
}

/// Release a block that `alloc_layout(a, l)` returned. A zero-size layout calls no allocator.
/// Safety: `p` came from `alloc_layout` with an allocator that can release it (the same value or a copy
/// of it) and with this `l`, and it is not released yet.
@always_inline
pub unsafe fn dealloc_layout<A: Allocator>(a: &mut A, p: *mut void, l: Layout) {
    if l.size() == 0 {
        return;
    }
    unsafe a.dealloc(p, l.size(), l.align());
}

extend Layout {
    /// The layout of one `T`: `sizeof(T)` and `alignof(T)`.
    pub const fn new<T>() Layout {
        return Layout { size: sizeof(T), align: alignof(T) };
    }

    /// The layout of `size` bytes aligned to `align`, or `None` when `align` is not a power of two or
    /// `size` rounded up to `align` exceeds `isize::MAX`.
    pub const fn from_size_align(size: usize, align: usize) Option<Layout> {
        if !align.is_power_of_two() || size > ISIZE_MAX - (align - 1) {
            return None;
        }
        return Some(Layout { size: size, align: align });
    }

    /// The layout of `n` consecutive `T`s, or `None` when the size exceeds the `isize::MAX` limit.
    pub const fn array<T>(n: usize) Option<Layout> {
        // `sizeof(T)` is a multiple of `alignof(T)`, so `n * sizeof(T)` needs no padding.
        if sizeof(T) != 0 && n > (ISIZE_MAX - (alignof(T) - 1)) / sizeof(T) {
            return None;
        }
        return Some(Layout { size: n * sizeof(T), align: alignof(T) });
    }

    /// The size in bytes.
    pub const fn size(self: &Layout) usize {
        return self.size;
    }

    /// The alignment in bytes, a power of two.
    pub const fn align(self: &Layout) usize {
        return self.align;
    }

    /// The bytes to add after `size()` so that the end is a multiple of `align`.
    /// Panics: `align` is not a power of two.
    pub const fn padding_needed_for(self: &Layout, align: usize) usize {
        if !align.is_power_of_two() {
            panic("Layout::padding_needed_for: align is not a power of two");
        }
        // Wrapping: the result is the padding modulo 2^N; `followed_by` checks the sum it is added to.
        let rounded = self.size.wrapping_add(align - 1) & ~(align - 1);
        return rounded.wrapping_sub(self.size);
    }

    /// This layout with its size rounded up to its alignment: the stride of an array of it. Cannot
    /// overflow, by the invariant.
    pub const fn pad_to_align(self: &Layout) Layout {
        let size = self.size + (self.align - 1) & ~(self.align - 1);
        return Layout { size: size, align: self.align };
    }

    /// This layout with an alignment of at least `align`, or `None` when `align` is not a power of two or
    /// the size no longer fits.
    pub const fn align_to(self: &Layout, align: usize) Option<Layout> {
        if !align.is_power_of_two() {
            return None;
        }
        return Layout::from_size_align(self.size, self.align.max(align));
    }

    /// The layout of a C struct of this layout followed by `next`, and the byte offset of `next` in it,
    /// or `None` on overflow. The result is not padded at its end: call `pad_to_align` after the last
    /// field.
    pub const fn followed_by(self: &Layout, next: Layout) Option<(Layout, usize)> {
        // `self.size` and the padding are each below 2^(N-1), so the offset cannot wrap.
        let offset = self.size + self.padding_needed_for(next.align);
        if offset > ISIZE_MAX || next.size > ISIZE_MAX - offset {
            return None;
        }
        return switch Layout::from_size_align(offset + next.size, self.align.max(next.align)) {
            Some(l) => Some((l, offset)),
            None => Option::<(Layout, usize)>::None,
        };
    }
}
