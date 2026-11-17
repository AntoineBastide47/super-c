// RawBlock<A>: one block of bytes from allocator `A`, of a size and alignment known at run time, which
// it owns: freeing the value returns the block. The arena's and the pool's chunks. Its own file holds
// its invariant, so a value elsewhere (an element of a `Vector`) holds its block as a `Box` does.

/// An owned block of `size` bytes aligned to `align`, from allocator `A`.
pub(package) struct RawBlock<A: Allocator>
    invariant self.ptr != null && self.size != 0 && self.align != 0 && (self.ptr as usize & self.align - 1) == 0
    invariant A::owns(self.ptr, self.size, self.align)
{
    ptr: *mut u8,
    size: usize,
    align: usize,
    alloc: A,
}

extend<A: Allocator> RawBlock<A> {
    /// A block of `size` bytes aligned to `align` from `alloc`.
    pub(package) fn new_in(alloc: A, size: usize, align: usize) RawBlock<A>
        requires size != 0 && size as int <= isize::MAX as int && align != 0 && (align & align - 1) == 0
        ensures |r| r.size == size && r.align == align
    {
        let mut a = alloc;
        let p = (unsafe a.alloc(size, align)) as *mut u8;
        return RawBlock::<A> { ptr: p, size: size, align: align, alloc: a };
    }

    /// Block `ptr` of `size` bytes aligned to `align`, which `alloc` gave: the value owns it.
    pub(package) unsafe const fn from_raw(alloc: A, ptr: *mut u8, size: usize, align: usize) RawBlock<A>
        requires ptr != null && size != 0 && align != 0 && (ptr as usize & align - 1) == 0
        requires A::owns(ptr, size, align)
    {
        return RawBlock::<A> { ptr: ptr, size: size, align: align, alloc: alloc };
    }

    /// The block's first byte: not null, aligned to the block's alignment.
    pub(package) const fn ptr(self: &RawBlock<A>) *mut u8
        ensures |r| r == self.ptr && r != null && (r as usize & self.align - 1) == 0
    {
        return self.ptr;
    }

    /// The block's bytes: not 0.
    pub(package) const fn size(self: &RawBlock<A>) usize
        ensures |r| r == self.size && r != 0
    {
        return self.size;
    }
}

extend<A: Allocator> RawBlock<A> as Free {
    fn free(self: &mut RawBlock<A>) {
        unsafe self.alloc.dealloc(self.ptr, self.size, self.align);
    }
}
