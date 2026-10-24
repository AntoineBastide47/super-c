// NoAlloc: the allocator that has no memory, after C++ `std::pmr::null_memory_resource` ([mem.res.global]).
// It is the upstream of an arena that must never touch the heap: `Arena::<NoAlloc>::with_buffer(buf)`
// serves requests from `buf` and panics once `buf` is full.

/// A zero-sized allocator whose `alloc` and `realloc` panic and whose `dealloc` does nothing (no block
/// can come from it). `Send` and `Sync`: it has no state.
@derive(Copy, Default)
pub struct NoAlloc {}

extend NoAlloc as Allocator {
    pub unsafe fn alloc(self: &mut NoAlloc, size: usize, align: usize) *mut void {
        panic("NoAlloc: allocation");
    }

    pub unsafe fn realloc(self: &mut NoAlloc, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        panic("NoAlloc: allocation");
    }

    pub unsafe fn dealloc(self: &mut NoAlloc, ptr: *mut void, size: usize, align: usize) {}
}
