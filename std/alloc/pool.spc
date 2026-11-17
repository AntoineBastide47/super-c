// Pool<A = Global>: a size-class allocator, after C++ `std::pmr::unsynchronized_pool_resource`
// ([mem.res.pool]). Containers take its `PoolAlloc` handle: `Map::new_in(pool.allocator())`.
//
// A request of `size` bytes and alignment `align` goes to the class of the smallest power of two that is
// at least 16, `size` and `align`: 9 classes, 16 to 4096 bytes (`POOL_BLOCK_SIZE_MAX`). 4096 is one page:
// above it the power-of-two rounding wastes up to half of a multi-page block, each pooled class keeps a
// chunk of idle memory, and the C heap already serves page-sized blocks well. Larger requests go straight
// to the upstream allocator `A` and back to it in `dealloc`, which finds the class from the size and
// alignment it is told.
//
// Each class keeps an intrusive free list: a freed block holds the address of the next one in its first
// word. A class carves blocks from chunks it requests upstream, aligned to the block size: the first
// chunk holds 1 KiB (at least one block), each next one twice as many blocks, up to 64 KiB (at least one
// block). So N blocks take O(log N) upstream calls (then one per 64 KiB), and a class holds at most 64 KiB
// of uncarved memory. Blocks are carved on
// demand, so an unused part of a chunk is never touched. The pool owns its chunks as values in a `Vector`
// from `A` (one record of four words per chunk).
//
// - `alloc` and `dealloc`: O(1) for pooled sizes: a free-list pop or push, or a bump in the newest chunk;
//   amortized O(1) with the chunk requests. Above the largest class: the upstream's cost.
// - `realloc`: in place when the old and new sizes share a class; between two unpooled sizes, the
//   upstream `realloc`; otherwise a new block, a copy and a `dealloc`.
// - Alignment: a pooled block is aligned to its block size, so every alignment up to 4096 is pooled.
// - Overhead: no per-block header; the rounding up to the block size (less than half of the block above
//   16 bytes), and one record per chunk.
// - `release`: O(chunks). Returns every chunk, and the list of them, upstream; every pooled block becomes
//   invalid. Unpooled blocks are not tracked: their owners return them through `dealloc`.
// - Zero-size requests return a non-null pointer aligned to the request, with no memory behind it.
//
// Lifetimes: a `PoolAlloc<'a>` borrows its pool, so a container that holds one cannot outlive the pool,
// and `release` and a move of the pool wait until no handle is live. Thread safety: a `Pool` is `Send`
// when `A` is, never `Sync`; a handle is neither (`std::parallel::pool::SyncPool` is the shared form).
// Exhaustion: the upstream allocator decides (`Global` aborts, `NoAlloc` panics); the pool never returns
// null.

import std::alloc::block as blk;
import std::alloc::size_class as cls;
import std::mem::ptr;

extern "C" {
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
}

/// The smallest block size of a pool: every pooled block holds at least a free-list link.
pub const POOL_BLOCK_SIZE_MIN: usize = cls::BLOCK_SIZE_MIN;
/// The largest block size of a pool; a larger size or alignment is served by the upstream allocator.
pub const POOL_BLOCK_SIZE_MAX: usize = 4096;
const CLASS_COUNT: usize = cls::CLASS_COUNT;
const CLASS_SHIFT_MIN: usize = 4; // log2(POOL_BLOCK_SIZE_MIN)
const CHUNK_BYTES_MIN: usize = 1024; // data bytes of a class's first chunk, at least one block
const CHUNK_BYTES_MAX: usize = 65536; // data bytes past which a class's chunks stop growing
const USIZE_BITS: usize = 8 * sizeof(usize);

static_assert(POOL_BLOCK_SIZE_MIN << CLASS_COUNT - 1 == POOL_BLOCK_SIZE_MAX, "one class per power of two");
static_assert(1 << CLASS_SHIFT_MIN == POOL_BLOCK_SIZE_MIN, "the class index is log2(block size) - 4");

struct PoolState<A: Allocator> {
    c0: cls::PoolClass<0>,
    c1: cls::PoolClass<1>,
    c2: cls::PoolClass<2>,
    c3: cls::PoolClass<3>,
    c4: cls::PoolClass<4>,
    c5: cls::PoolClass<5>,
    c6: cls::PoolClass<6>,
    c7: cls::PoolClass<7>,
    c8: cls::PoolClass<8>,
    chunks: Vector<blk::RawBlock<A>, A>, // every class's chunks
    reserved: usize, // bytes of the chunks held
    unpooled: usize, // bytes of the live unpooled blocks
    upstream: A,
}

/// A size-class allocator over chunks from `A`, with O(1) pooled `alloc` and `dealloc`. Owns its chunks
/// and returns them upstream when freed. Containers allocate through `allocator()`.
pub struct Pool<A: Allocator = Global> {
    state: UnsafeCell<PoolState<A>>,
}

/// The `Allocator` handle of a `Pool`: one pointer, `Copy`, valid while the pool is borrowed for `'a`.
@derive(Copy)
pub struct PoolAlloc<'a, A: Allocator = Global> {
    state: *mut PoolState<A>,
}

// The class of a request: log2 of the smallest power of two that is at least 16, `size` and `align`, minus
// 4. `CLASS_COUNT` or more means unpooled. `align` is a power of two, so the larger of the two rounds up to
// the same power.
@always_inline
const fn class_index(size: usize, align: usize) usize
    requires size != 0 || align != 0
    ensures |r| r >= CLASS_COUNT || size <= POOL_BLOCK_SIZE_MIN << r && align <= POOL_BLOCK_SIZE_MIN << r
{
    let n = if size > align {
        size
    } else {
        align
    };
    let x = n - 1 | POOL_BLOCK_SIZE_MIN - 1;
    // Bits 0 to 3 of `x` are set: its highest set bit is at least bit 3.
    assert x >> 3 != 0 by {};
    return USIZE_BITS - x.leading_zeros() - CLASS_SHIFT_MIN;
}

/// Whether `ptr` is a block that a pool over `A` gave for `size` and `align`: a pooled block is aligned
/// to its class's block size, a larger one is `A`'s, and a zero-size one is an aligned address.
pub spec fn pool_owns<A: Allocator>(ptr: *mut void, size: usize, align: usize) bool {
    return if size == 0 {
        ptr != null && align != 0 && (ptr as usize & align - 1) == 0
    } else if class_index(size, align) >= CLASS_COUNT {
        A::owns(ptr, size, align)
    } else {
        ptr != null && (ptr as usize & (POOL_BLOCK_SIZE_MIN << class_index(size, align)) - 1) == 0
    };
}

// The bytes of chunk `k` (0 the oldest) of class `i`: 1 KiB of blocks (at least one block), doubled per
// chunk up to 64 KiB (at least one block).
const fn chunk_bytes(i: usize, k: usize) usize
    requires i < CLASS_COUNT
    ensures |r| r >= POOL_BLOCK_SIZE_MIN << i && r <= 2 * CHUNK_BYTES_MAX
{
    let mut n = POOL_BLOCK_SIZE_MIN << i;
    if n < CHUNK_BYTES_MIN {
        n = CHUNK_BYTES_MIN;
    }
    let mut j: usize = 0;
    while j < k && n < CHUNK_BYTES_MAX
        invariant n >= POOL_BLOCK_SIZE_MIN << i && n <= 2 * CHUNK_BYTES_MAX
    {
        n = n * 2;
        j += 1;
    }
    return n;
}

extend<A: Allocator> PoolState<A> {
    @always_inline
    unsafe fn alloc(self: &mut Self, size: usize, align: usize) *mut void
        requires size as int <= isize::MAX as int && align != 0 && (align & align - 1) == 0
        panics if true
        ensures |r| r != null && (r as usize & align - 1) == 0 && pool_owns::<A>(r, size, align)
    {
        let i = class_index(size, align);
        if unlikely(i >= CLASS_COUNT || size == 0) {
            return unsafe self.alloc_unpooled(size, align);
        }
        let b = unsafe self.take_class(i);
        if likely(b != null) {
            return b;
        }
        return unsafe self.refill(i);
    }

    @noinline
    unsafe fn alloc_unpooled(self: &mut Self, size: usize, align: usize) *mut void
        requires size as int <= isize::MAX as int && align != 0 && (align & align - 1) == 0
        panics if true
        ensures |r| r != null && (r as usize & align - 1) == 0 && (size == 0 || A::owns(r, size, align))
    {
        if size == 0 {
            return ptr::from_addr_mut::<void>(align);
        }
        self.unpooled += size;
        return unsafe self.upstream.alloc(size, align);
    }

    // Class `i` has no free or uncarved block: request its next chunk, keep it, and hand out its first
    // block.
    @noinline
    unsafe fn refill(self: &mut Self, i: usize) *mut void
        requires i < CLASS_COUNT
        panics if true
        ensures |r| r != null && (r as usize & (POOL_BLOCK_SIZE_MIN << i) - 1) == 0
    {
        let size = POOL_BLOCK_SIZE_MIN << i;
        let k = self.class_chunks(i);
        let bytes = chunk_bytes(i, k);
        let mut up = self.upstream;
        let base = (unsafe up.alloc(bytes, size)) as *mut u8;
        let c = unsafe blk::RawBlock::<A>::from_raw(up, base, bytes, size);
        let cur = unsafe (base + size);
        let end = unsafe (base + bytes);
        self.chunks.push(c);
        self.reserved += bytes;
        self.carve_class(i, k + 1, cur, end);
        return base;
    }

    // Class `i`'s next block, null when it has neither a free nor an uncarved one.
    @always_inline
    unsafe const fn take_class(self: &mut Self, i: usize) *mut u8
        requires i < CLASS_COUNT
        ensures |r| r == null || (r as usize & (POOL_BLOCK_SIZE_MIN << i) - 1) == 0
    {
        return switch i {
            0 => unsafe self.c0.take(),
            1 => unsafe self.c1.take(),
            2 => unsafe self.c2.take(),
            3 => unsafe self.c3.take(),
            4 => unsafe self.c4.take(),
            5 => unsafe self.c5.take(),
            6 => unsafe self.c6.take(),
            7 => unsafe self.c7.take(),
            _ => unsafe self.c8.take(),
        };
    }

    // Put block `p` of class `i` first on its free list.
    @always_inline
    unsafe const fn give_class(self: &mut Self, i: usize, p: *mut u8)
        requires i < CLASS_COUNT && p != null && (p as usize & (POOL_BLOCK_SIZE_MIN << i) - 1) == 0
    {
        switch i {
            0 => unsafe self.c0.give(p),
            1 => unsafe self.c1.give(p),
            2 => unsafe self.c2.give(p),
            3 => unsafe self.c3.give(p),
            4 => unsafe self.c4.give(p),
            5 => unsafe self.c5.give(p),
            6 => unsafe self.c6.give(p),
            7 => unsafe self.c7.give(p),
            _ => unsafe self.c8.give(p),
        }
    }

    // The chunks class `i` requested.
    const fn class_chunks(self: &Self, i: usize) usize {
        return switch i {
            0 => self.c0.chunk_count(),
            1 => self.c1.chunk_count(),
            2 => self.c2.chunk_count(),
            3 => self.c3.chunk_count(),
            4 => self.c4.chunk_count(),
            5 => self.c5.chunk_count(),
            6 => self.c6.chunk_count(),
            7 => self.c7.chunk_count(),
            _ => self.c8.chunk_count(),
        };
    }

    // Class `i`, with `count` chunks, carves its next blocks from `cur` to `end`.
    const fn carve_class(self: &mut Self, i: usize, count: usize, cur: *mut u8, end: *mut u8)
        requires i < CLASS_COUNT && cur as usize <= end as usize && (cur == end || cur != null && (cur as usize & (POOL_BLOCK_SIZE_MIN << i) - 1) == 0)
    {
        switch i {
            0 => self.c0.carve(count, cur, end),
            1 => self.c1.carve(count, cur, end),
            2 => self.c2.carve(count, cur, end),
            3 => self.c3.carve(count, cur, end),
            4 => self.c4.carve(count, cur, end),
            5 => self.c5.carve(count, cur, end),
            6 => self.c6.carve(count, cur, end),
            7 => self.c7.carve(count, cur, end),
            _ => self.c8.carve(count, cur, end),
        }
    }

    @always_inline
    unsafe fn dealloc(self: &mut Self, ptr: *mut void, size: usize, align: usize)
        requires ptr == null && size == 0 || pool_owns::<A>(ptr, size, align)
        panics if true
    {
        if size == 0 {
            return;
        }
        let i = class_index(size, align);
        if unlikely(i >= CLASS_COUNT) {
            unsafe self.dealloc_unpooled(ptr, size, align);
            return;
        }
        unsafe self.give_class(i, ptr as *mut u8);
    }

    @noinline
    unsafe fn dealloc_unpooled(self: &mut Self, ptr: *mut void, size: usize, align: usize)
        requires size == 0 || class_index(size, align) >= CLASS_COUNT && pool_owns::<A>(ptr, size, align)
        panics if true
    {
        if size == 0 {
            return;
        }
        self.unpooled -= size;
        unsafe self.upstream.dealloc(ptr, size, align);
    }

    // Both sizes are above the largest class: the upstream allocator resizes the block.
    @noinline
    unsafe fn realloc_unpooled(self: &mut Self, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void
        requires new_size != 0 && new_size as int <= isize::MAX as int && align != 0 && (align & align - 1) == 0
        requires old_size != 0 && class_index(new_size, align) >= CLASS_COUNT && A::owns(ptr, old_size, align)
        panics if true
        ensures |r| r != null && (r as usize & align - 1) == 0 && A::owns(r, new_size, align)
    {
        self.unpooled = self.unpooled - old_size + new_size;
        return unsafe self.upstream.realloc(ptr, old_size, new_size, align);
    }

    unsafe fn realloc(self: &mut Self, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void
        requires new_size as int <= isize::MAX as int && align != 0 && (align & align - 1) == 0
        requires ptr == null && old_size == 0 || pool_owns::<A>(ptr, old_size, align)
        panics if true
        ensures |r| r != null && (r as usize & align - 1) == 0 && pool_owns::<A>(r, new_size, align)
    {
        if old_size != 0 && new_size != 0 && ptr != null {
            let oi = class_index(old_size, align);
            let ni = class_index(new_size, align);
            if oi == ni && oi < CLASS_COUNT {
                return ptr;
            }
            if oi >= CLASS_COUNT && ni >= CLASS_COUNT {
                return unsafe self.realloc_unpooled(ptr, old_size, new_size, align);
            }
        }
        let p = unsafe self.alloc(new_size, align);
        let n = if old_size < new_size {
            old_size
        } else {
            new_size
        };
        if n != 0 {
            unsafe memcpy(p, ptr, n);
        }
        unsafe self.dealloc(ptr, old_size, align);
        // A step: `p` keeps `alloc`'s facts past the `dealloc`; stated here, the result's clause needs no
        // search over the cases of `dealloc`'s contract.
        assert pool_owns::<A>(p, new_size, align) by {};
        return p;
    }

    // Return every chunk upstream: every pooled block becomes invalid.
    const fn release(self: &mut Self)
        panics if true
    {
        self.c0 = cls::PoolClass::<0>::empty();
        self.c1 = cls::PoolClass::<1>::empty();
        self.c2 = cls::PoolClass::<2>::empty();
        self.c3 = cls::PoolClass::<3>::empty();
        self.c4 = cls::PoolClass::<4>::empty();
        self.c5 = cls::PoolClass::<5>::empty();
        self.c6 = cls::PoolClass::<6>::empty();
        self.c7 = cls::PoolClass::<7>::empty();
        self.c8 = cls::PoolClass::<8>::empty();
        self.chunks = Vector::<blk::RawBlock<A>, A>::new_in(self.upstream);
        self.reserved = 0;
    }
}

extend<A: Allocator> Pool<A> {
    /// An empty pool whose chunks come from `upstream`; it requests nothing before the first `alloc`.
    pub const fn new_in(upstream: A) Pool<A> {
        let st = PoolState::<A> {
            c0: cls::PoolClass::<0>::empty(),
            c1: cls::PoolClass::<1>::empty(),
            c2: cls::PoolClass::<2>::empty(),
            c3: cls::PoolClass::<3>::empty(),
            c4: cls::PoolClass::<4>::empty(),
            c5: cls::PoolClass::<5>::empty(),
            c6: cls::PoolClass::<6>::empty(),
            c7: cls::PoolClass::<7>::empty(),
            c8: cls::PoolClass::<8>::empty(),
            chunks: Vector::<blk::RawBlock<A>, A>::new_in(upstream),
            reserved: 0,
            unpooled: 0,
            upstream: upstream,
        };
        return Pool::<A> { state: UnsafeCell::<PoolState<A>>::new(st) };
    }

    /// The allocator handle for containers. Every copy borrows the pool: it cannot be released, moved or
    /// freed while a handle is live.
    pub const fn allocator(self: &Pool<A>) PoolAlloc<A> {
        return PoolAlloc::<A> { state: self.state.get() };
    }

    /// Return every chunk upstream: every pooled block becomes invalid. O(chunks).
    pub const fn release(self: &mut Pool<A>) {
        unsafe (*self.state.get()).release();
    }

    /// Bytes of the chunks the pool holds for its size classes.
    pub const fn bytes_reserved(self: &Pool<A>) usize {
        return self.state.get_ref().reserved;
    }

    /// Bytes of the live blocks above `POOL_BLOCK_SIZE_MAX`, which the upstream allocator serves.
    pub const fn bytes_unpooled(self: &Pool<A>) usize {
        return self.state.get_ref().unpooled;
    }
}

extend<A: Allocator + Default> Pool<A> {
    /// An empty pool over a default-constructed upstream allocator.
    pub fn new() Pool<A> {
        return Pool::<A>::new_in(A::default());
    }
}

// The handle reaches the state through a raw pointer while other handles exist: no method keeps a
// reference to the state past its return, and the borrow of the pool keeps the state alive.
extend<'a, A: Allocator> PoolAlloc<'a, A> as Allocator {
    pub spec fn owns(ptr: *mut void, size: usize, align: usize) bool {
        return pool_owns::<A>(ptr, size, align);
    }

    @always_inline
    pub unsafe fn alloc(self: &mut Self, size: usize, align: usize) *mut void {
        return unsafe (*self.state).alloc(size, align);
    }

    @always_inline
    pub unsafe fn realloc(self: &mut Self, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        return unsafe (*self.state).realloc(ptr, old_size, new_size, align);
    }

    @always_inline
    pub unsafe fn dealloc(self: &mut Self, ptr: *mut void, size: usize, align: usize) {
        unsafe (*self.state).dealloc(ptr, size, align);
    }
}

extend<A: Allocator + Default> Pool<A> as Default {
    pub fn default() Pool<A> {
        return Pool::<A>::new();
    }
}

// The pool owns its chunks, and a handle cannot outlive the borrow that pins it to one thread.
unsafe extend<A: Allocator + Send> Pool<A> as Send {}
