// SyncPool<A = Global>: a `std::alloc::pool::Pool` that every thread and task can share, after C++
// `std::pmr::synchronized_pool_resource` ([mem.res.pool]). Each operation takes a `std::parallel::sync::Mutex`
// around the pool, so the size classes, complexity, alignment, overhead, lifetime rules and exhaustion
// behavior are the pool's (see std/alloc/pool.spc), plus one lock and one unlock per call. A contended lock
// parks a coroutine instead of blocking its worker. The handle `SyncPoolAlloc` is `Send` and `Sync` when
// `A` is `Send`, so containers that hold it can cross to other tasks while the pool lives.

import std::alloc::pool as apool;
import std::parallel::sync;

/// A size-class allocator shared by every thread and task, behind a task-aware lock. Owns its chunks and
/// returns them upstream when freed. Containers allocate through `allocator()`.
@no_const
pub struct SyncPool<A = Global> {
    pool: sync::Mutex<apool::Pool<A>>,
}

/// The `Allocator` handle of a `SyncPool`: one reference, `Copy`, valid while the pool is borrowed for
/// `'a`.
@no_const
@derive(Copy)
pub struct SyncPoolAlloc<'a, A = Global> {
    pool: &'a sync::Mutex<apool::Pool<A>>,
}

extend<A: Allocator> SyncPool<A> {
    /// An empty pool whose chunks come from `upstream`; it requests nothing before the first `alloc`.
    pub fn new_in(upstream: A) SyncPool<A> {
        return SyncPool::<A> { pool: sync::Mutex::<apool::Pool<A>>::new(apool::Pool::<A>::new_in(upstream)) };
    }

    /// The allocator handle for containers. Every copy borrows the pool: it cannot be released, moved or
    /// freed while a handle is live.
    pub fn allocator(self: &SyncPool<A>) SyncPoolAlloc<A> {
        return SyncPoolAlloc::<A> { pool: &self.pool };
    }

    /// Return every chunk upstream: every pooled block becomes invalid. No lock: `&mut self` excludes
    /// every handle.
    pub fn release(self: &mut SyncPool<A>) {
        self.pool.get_mut().release();
    }

    /// Bytes of the chunks the pool holds for its size classes, under the lock.
    pub fn bytes_reserved(self: &SyncPool<A>) usize {
        let g = self.pool.lock();
        return g.get().bytes_reserved();
    }

    /// Bytes of the live blocks above `POOL_BLOCK_SIZE_MAX`, under the lock.
    pub fn bytes_unpooled(self: &SyncPool<A>) usize {
        let g = self.pool.lock();
        return g.get().bytes_unpooled();
    }
}

extend<A: Allocator + Default> SyncPool<A> {
    /// An empty pool over a default-constructed upstream allocator.
    pub fn new() SyncPool<A> {
        return SyncPool::<A>::new_in(A::default());
    }
}

extend<'a, A: Allocator> SyncPoolAlloc<'a, A> as Allocator {
    pub unsafe fn alloc(self: &mut Self, size: usize, align: usize) *mut void {
        let g = self.pool.lock();
        let mut h = g.get().allocator();
        return unsafe h.alloc(size, align);
    }

    pub unsafe fn realloc(self: &mut Self, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        let g = self.pool.lock();
        let mut h = g.get().allocator();
        return unsafe h.realloc(ptr, old_size, new_size, align);
    }

    pub unsafe fn dealloc(self: &mut Self, ptr: *mut void, size: usize, align: usize) {
        let g = self.pool.lock();
        let mut h = g.get().allocator();
        unsafe h.dealloc(ptr, size, align);
    }
}

extend<A: Allocator + Default> SyncPool<A> as Default {
    pub fn default() SyncPool<A> {
        return SyncPool::<A>::new();
    }
}
