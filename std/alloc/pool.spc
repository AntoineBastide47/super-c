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
// demand, so an unused part of a chunk is never touched. A chunk descriptor (two words) takes one 16-byte
// block of the smallest class.
//
// - `alloc` and `dealloc`: O(1) for pooled sizes: a free-list pop or push, or a bump in the newest chunk;
//   amortized O(1) with the chunk requests. Above the largest class: the upstream's cost.
// - `realloc`: in place when the old and new sizes share a class; between two unpooled sizes, the
//   upstream `realloc`; otherwise a new block, a copy and a `dealloc`.
// - Alignment: a pooled block is aligned to its block size, so every alignment up to 4096 is pooled.
// - Overhead: no per-block header; the rounding up to the block size (less than half of the block above
//   16 bytes), and one descriptor per chunk.
// - `release`: O(chunks). Returns every chunk upstream; every pooled block becomes invalid. Unpooled
//   blocks are not tracked: their owners return them through `dealloc`.
// - Zero-size requests return a non-null pointer aligned to the request, with no memory behind it.
//
// Lifetimes: a `PoolAlloc<'a>` borrows its pool, so a container that holds one cannot outlive the pool,
// and `release` and a move of the pool wait until no handle is live. Thread safety: a `Pool` is `Send`
// when `A` is, never `Sync`; a handle is neither (`std::parallel::pool::SyncPool` is the shared form).
// Exhaustion: the upstream allocator decides (`Global` aborts, `NoAlloc` panics); the pool never returns
// null.

extern "C" {
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
}

/// The smallest block size of a pool: every pooled block holds at least a free-list link.
pub const POOL_BLOCK_SIZE_MIN: usize = 16;
/// The largest block size of a pool; a larger size or alignment is served by the upstream allocator.
pub const POOL_BLOCK_SIZE_MAX: usize = 4096;
const CLASS_COUNT: usize = 9; // 16, 32, .., 4096
const CLASS_SHIFT_MIN: usize = 4; // log2(POOL_BLOCK_SIZE_MIN)
const CHUNK_BYTES_MIN: usize = 1024; // data bytes of a class's first chunk, at least one block
const CHUNK_BYTES_MAX: usize = 65536; // data bytes past which a class's chunks stop growing
const USIZE_BITS: usize = 8 * sizeof(usize);

static_assert(POOL_BLOCK_SIZE_MIN << CLASS_COUNT - 1 == POOL_BLOCK_SIZE_MAX, "one class per power of two");
static_assert(1 << CLASS_SHIFT_MIN == POOL_BLOCK_SIZE_MIN, "the class index is log2(block size) - 4");

// The record of one chunk, in a block of class 0 (for a class-0 chunk, its own first block). The chunk's
// size follows from its class and its position in the list (`chunk_blocks`).
struct PoolChunk {
    pub(file) next: *mut PoolChunk, // older chunk of the same class
    pub(file) base: *mut u8, // the chunk's address
}

static_assert(sizeof(PoolChunk) <= POOL_BLOCK_SIZE_MIN, "a chunk descriptor fits the smallest block");

// One size class. `cur <= end`; both null until the first chunk.
struct PoolClass {
    pub(file) free: *mut u8, // free-list head; null when empty
    pub(file) cur: *mut u8, // next uncarved block of the newest chunk
    pub(file) end: *mut u8, // one past the newest chunk
    pub(file) chunks: *mut PoolChunk, // descriptors, newest first
    pub(file) chunk_count: usize,
}

struct PoolState<A> {
    pub(file) classes: [PoolClass; CLASS_COUNT],
    pub(file) reserved: usize, // bytes of the chunks held
    pub(file) unpooled: usize, // bytes of the live unpooled blocks
    pub(file) upstream: A,
}

/// A size-class allocator over chunks from `A`, with O(1) pooled `alloc` and `dealloc`. Owns its chunks
/// and returns them upstream when freed. Containers allocate through `allocator()`.
pub struct Pool<A = Global> {
    state: UnsafeCell<PoolState<A>>,
}

/// The `Allocator` handle of a `Pool`: one pointer, `Copy`, valid while the pool is borrowed for `'a`.
@derive(Copy)
pub struct PoolAlloc<'a, A = Global> {
    pub(file) state: *mut PoolState<A>,
}

// The class of a request: log2 of the smallest power of two that is at least 16, `size` and `align`, minus
// 4. `CLASS_COUNT` or more means unpooled. `align` is a power of two, so the larger of the two rounds up to
// the same power.
@always_inline
const fn class_index(size: usize, align: usize) usize {
    let n = if size > align {
        size;
    } else {
        align;
    };
    return USIZE_BITS - (n - 1 | POOL_BLOCK_SIZE_MIN - 1).leading_zeros() - CLASS_SHIFT_MIN;
}

// The block count of chunk `k` (0 the oldest) of class `i`: 1 KiB of blocks (at least one), doubled per
// chunk up to 64 KiB (at least one block).
const fn chunk_blocks(i: usize, k: usize) usize {
    let size = POOL_BLOCK_SIZE_MIN << i;
    let mut n: usize = 1;
    if CHUNK_BYTES_MIN > size {
        n = CHUNK_BYTES_MIN / size;
    }
    let mut j: usize = 0;
    while j < k && n * size < CHUNK_BYTES_MAX {
        n = n * 2;
        j += 1;
    }
    return n;
}

extend<A: Allocator> PoolState<A> {
    @always_inline
    unsafe fn alloc(self: &mut Self, size: usize, align: usize) *mut void {
        let i = class_index(size, align);
        if unlikely(i >= CLASS_COUNT || size == 0) {
            return unsafe self.alloc_unpooled(size, align);
        }
        let c = unsafe &mut self.classes[i];
        let b = c.free;
        if likely(b != null) {
            c.free = unsafe *(b as *mut *mut u8);
            return b;
        }
        if c.cur != c.end {
            let p = c.cur;
            c.cur = unsafe (p + (POOL_BLOCK_SIZE_MIN << i));
            return p;
        }
        return unsafe self.refill(i);
    }

    @noinline
    unsafe fn alloc_unpooled(self: &mut Self, size: usize, align: usize) *mut void {
        if size == 0 {
            return align as *mut void;
        }
        self.unpooled += size;
        return unsafe self.upstream.alloc(size, align);
    }

    // Class `i` has no free or uncarved block: request its next chunk and hand out the chunk's first block.
    @noinline
    unsafe fn refill(self: &mut Self, i: usize) *mut void {
        let size = POOL_BLOCK_SIZE_MIN << i;
        let k = unsafe self.classes[i].chunk_count;
        let bytes = chunk_blocks(i, k) * size;
        let base = (unsafe self.upstream.alloc(bytes, size)) as *mut u8;
        self.reserved += bytes;
        let mut first = base;
        let mut desc = base as *mut PoolChunk;
        if i == 0 {
            first = unsafe (base + size);
        } else {
            desc = (unsafe self.alloc(sizeof(PoolChunk), alignof(PoolChunk))) as *mut PoolChunk;
        }
        let c = unsafe &mut self.classes[i];
        unsafe (*desc).next = c.chunks;
        unsafe (*desc).base = base;
        c.chunks = desc;
        c.chunk_count = k + 1;
        c.cur = unsafe (first + size);
        c.end = unsafe (base + bytes);
        return first;
    }

    @always_inline
    unsafe fn dealloc(self: &mut Self, ptr: *mut void, size: usize, align: usize) {
        let i = class_index(size, align);
        if unlikely(i >= CLASS_COUNT || size == 0) {
            unsafe self.dealloc_unpooled(ptr, size, align);
            return;
        }
        let c = unsafe &mut self.classes[i];
        unsafe *(ptr as *mut *mut u8) = c.free;
        c.free = ptr as *mut u8;
    }

    @noinline
    unsafe fn dealloc_unpooled(self: &mut Self, ptr: *mut void, size: usize, align: usize) {
        if size == 0 {
            return;
        }
        self.unpooled -= size;
        unsafe self.upstream.dealloc(ptr, size, align);
    }

    unsafe fn realloc(self: &mut Self, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        if old_size != 0 && new_size != 0 {
            let oi = class_index(old_size, align);
            let ni = class_index(new_size, align);
            if oi == ni && oi < CLASS_COUNT {
                return ptr;
            }
            if oi >= CLASS_COUNT && ni >= CLASS_COUNT {
                self.unpooled = self.unpooled - old_size + new_size;
                return unsafe self.upstream.realloc(ptr, old_size, new_size, align);
            }
        }
        let p = unsafe self.alloc(new_size, align);
        let n = if old_size < new_size {
            old_size;
        } else {
            new_size;
        };
        if n != 0 {
            unsafe memcpy(p, ptr, n);
        }
        unsafe self.dealloc(ptr, old_size, align);
        return p;
    }

    // Return every chunk of class `i` upstream. A class-0 descriptor lives in its own chunk, so it is read
    // before the chunk goes.
    fn release_class(self: &mut Self, i: usize) {
        let size = POOL_BLOCK_SIZE_MIN << i;
        let mut d = unsafe self.classes[i].chunks;
        let mut k = unsafe self.classes[i].chunk_count;
        while d != null {
            let next = unsafe (*d).next;
            let base = unsafe (*d).base;
            k -= 1;
            unsafe self.upstream.dealloc(base, chunk_blocks(i, k) * size, size);
            d = next;
        }
        unsafe self.classes[i] = PoolClass { free: null, cur: null, end: null, chunks: null, chunk_count: 0 };
    }

    fn release(self: &mut Self) {
        // The descriptors of classes 1 and up live in class-0 blocks: class 0 goes last.
        for i in 1..CLASS_COUNT {
            self.release_class(i);
        }
        self.release_class(0);
        self.reserved = 0;
    }
}

extend<A: Allocator> Pool<A> {
    /// An empty pool whose chunks come from `upstream`; it requests nothing before the first `alloc`.
    pub const fn new_in(upstream: A) Pool<A> {
        return Pool::<A> { state: UnsafeCell::<PoolState<A>>::new(PoolState::<A> { upstream: upstream }) };
    }

    /// The allocator handle for containers. Every copy borrows the pool: it cannot be released, moved or
    /// freed while a handle is live.
    pub const fn allocator(self: &Pool<A>) PoolAlloc<A> {
        return PoolAlloc::<A> { state: self.state.get() };
    }

    /// Return every chunk upstream: every pooled block becomes invalid. O(chunks).
    pub fn release(self: &mut Pool<A>) {
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

extend<A: Allocator> Pool<A> as Free {
    pub fn free(self: &mut Pool<A>) {
        self.release();
    }
}

extend<A: Allocator + Default> Pool<A> as Default {
    pub fn default() Pool<A> {
        return Pool::<A>::new();
    }
}

// The pool owns its chunks, and a handle cannot outlive the borrow that pins it to one thread.
unsafe extend<A: Send> Pool<A> as Send {}
