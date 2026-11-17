// Arena<'b, A = Global>: a monotonic bump allocator, after C++ `std::pmr::monotonic_buffer_resource`
// ([mem.res.monotonic.buffer]). Containers take its `ArenaAlloc` handle: `Vector::new_in(arena.allocator())`.
//
// Memory comes from an optional caller buffer (`with_buffer`), then from chunks requested from the upstream
// allocator `A`. The first chunk is 4 KiB (one page: a short-lived arena costs one small request); each next
// chunk doubles, as `Vector` capacity does, up to 64 MiB. The arena owns its chunks as values in a `Vector`
// from `A` (one record of four words per chunk).
// So N bytes take O(log N) upstream calls (then one per 64 MiB), and for blocks small next to the chunks
// the chunks hold at most about twice the bytes handed out. After a caller buffer of n bytes, the first
// chunk is the larger of 4 KiB and 2n. A request that does not fit the current chunk gets a new chunk, of
// its own size when that is larger; the rest of the previous chunk stays unused.
//
// - `alloc`: O(1), a cursor bump; amortized O(1) with the chunk requests. Each block is aligned to its
//   request, any power of two. Overhead: no per-block header, only the padding to the alignment.
// - `dealloc`: O(1). It frees nothing, except a block that ends at the cursor (the most recent one): the
//   cursor moves back to the block's start, so blocks freed in reverse order are all reclaimed.
// - `realloc`: O(1) in place when the block ends at the cursor and the new size fits the chunk, or when the
//   size shrinks; otherwise a new block and a copy of the old bytes, and the old block stays used.
// - `reset`: O(chunks). Every block becomes invalid. The largest chunk stays for reuse, the others go back
//   upstream, and allocation starts again in the caller buffer.
// - Zero-size requests return a non-null pointer aligned to the request, with no memory behind it.
//
// Lifetimes: an `Arena<'b>` cannot outlive the buffer it borrows for `'b`; an `ArenaAlloc<'a>` borrows its
// arena, so a container that holds one cannot outlive the arena, and `reset` and a move of the arena wait
// until no handle is live. Thread safety: an `Arena` is `Send` when `A` is, never `Sync`; a handle is
// neither. Exhaustion: the upstream allocator decides (`Global` aborts, `NoAlloc` panics); a size whose
// chunk does not fit a `usize` panics. The arena never returns null.

import std::alloc::block as blk;
import std::mem::ptr;

extern "C" {
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
}

// The alignment of every chunk requested upstream, and of the data after its header: what `malloc` gives
// without an over-aligned request (16 bytes on 64-bit targets, 8 on wasm32).
const CHUNK_ALIGN: usize = 2 * sizeof(usize);
const CHUNK_SIZE_INITIAL: usize = 4096;
// The geometric chunk size stops growing here; a larger request still gets a chunk that fits it.
const CHUNK_SIZE_GROWTH_MAX: usize = 1 << 26;

// The first address at or after `p` that is a multiple of `mask + 1`, a power of two: at most `mask`
// bytes after it, in a region that holds `mask` bytes past `p` before `end`.
@always_inline
const fn round_up(p: *mut u8, end: *mut u8, mask: usize) *mut u8
    requires mask < usize::MAX && (mask & mask + 1) == 0 && (p as usize) as int + mask as int <= (end as usize) as int
    ensures |r| (r as usize & mask) == 0 && p as usize <= r as usize && r as usize - p as usize <= mask
{
    return unsafe (p + ((p as usize).wrapping_neg() & mask));
}

// The bump state. `base` is never null, so a null pointer (an empty container's buffer) never ends at the
// cursor.
struct ArenaState<A: Allocator>
    invariant self.base != null && self.base as usize <= self.cur as usize && self.cur as usize <= self.end as usize && (self.buf_len == 0 || self.buf != null) && self.next_size <= CHUNK_SIZE_GROWTH_MAX
{
    cur: *mut u8, // next free byte of the current region
    end: *mut u8, // one past the current region
    base: *mut u8, // start of the current region
    used_closed: usize, // bytes used in the regions before the current one
    chunks: Vector<blk::RawBlock<A>, A>, // chunks in use, oldest first
    spare: Option<blk::RawBlock<A>>, // the chunk `reset` kept, not in use
    buf: *mut u8, // the caller buffer
    buf_len: usize, // its length; 0 when there is none
    reserved: usize, // bytes of the chunks held, `spare` included
    next_size: usize, // size of the next chunk requested upstream
    upstream: A,
}

/// A monotonic bump allocator over an optional caller buffer and chunks from `A`. Owns its chunks and
/// returns them upstream when freed. Containers allocate through `allocator()`.
pub struct Arena<'b, A: Allocator = Global> {
    state: UnsafeCell<ArenaState<A>>,
}

/// The `Allocator` handle of an `Arena`: one pointer, `Copy`, valid while the arena is borrowed for `'a`.
@derive(Copy)
pub struct ArenaAlloc<'a, A: Allocator = Global> {
    state: *mut ArenaState<A>,
}

// The address of an empty region: non-null and aligned, never dereferenced.
const fn empty_region() *mut u8
    ensures |r| r != null
{
    return ptr::from_addr_mut::<u8>(CHUNK_ALIGN);
}

// The chunk size after `n`: twice as large, up to `CHUNK_SIZE_GROWTH_MAX`.
const fn grown(n: usize) usize
    ensures |r| r <= CHUNK_SIZE_GROWTH_MAX
{
    if n >= CHUNK_SIZE_GROWTH_MAX / 2 {
        return CHUNK_SIZE_GROWTH_MAX;
    }
    return n * 2;
}

extend<A: Allocator> ArenaState<A> {
    const fn new(buf: *mut u8, buf_len: usize, upstream: A) ArenaState<A>
        requires buf_len == 0 || buf != null
    {
        let mut next_size = grown(buf_len);
        if next_size < CHUNK_SIZE_INITIAL {
            next_size = CHUNK_SIZE_INITIAL;
        }
        let mut s = ArenaState::<A> {
            cur: empty_region(),
            end: empty_region(),
            base: empty_region(),
            used_closed: 0,
            chunks: Vector::<blk::RawBlock<A>, A>::new_in(upstream),
            spare: Option::<blk::RawBlock<A>>::none(),
            buf: buf,
            buf_len: buf_len,
            reserved: 0,
            next_size: next_size,
            upstream: upstream,
        };
        s.restart();
        return s;
    }

    // Point the cursor at the start of the caller buffer, or at an empty region when there is none.
    const fn restart(self: &mut Self) {
        let mut base = empty_region();
        let mut end = base;
        if self.buf_len != 0 {
            base = self.buf;
            end = unsafe (self.buf + self.buf_len);
        }
        self.base = base;
        self.end = end;
        self.cur = base;
        self.used_closed = 0;
    }

    @always_inline
    unsafe fn alloc(self: &mut Self, size: usize, align: usize) *mut void
        requires size as int <= isize::MAX as int && align != 0 && (align & align - 1) == 0
        panics if size as int + align as int + CHUNK_ALIGN as int > isize::MAX as int || self.used_closed as int + (self.cur as usize - self.base as usize) as int > usize::MAX as int || self.reserved as int + CHUNK_SIZE_GROWTH_MAX as int + size as int + align as int + CHUNK_ALIGN as int > usize::MAX as int || self.chunks.view().len() + 1 > Vector::<
            blk::RawBlock<A>,
            A
        >::max_len()
        ensures |r| r != null && (r as usize & align - 1) == 0
    {
        let at = self.cur as usize;
        let pad = at.wrapping_neg() & align - 1;
        let avail = self.end as usize - at;
        if likely(pad <= avail && size <= avail - pad) {
            let p = unsafe (self.cur + pad);
            self.cur = unsafe (p + size);
            return p;
        }
        return unsafe self.alloc_slow(size, align);
    }

    // The request does not fit the current region: take the spare chunk or a new one from upstream.
    @noinline
    unsafe fn alloc_slow(self: &mut Self, size: usize, align: usize) *mut void
        requires size as int <= isize::MAX as int && align != 0 && (align & align - 1) == 0
        panics if size as int + align as int + CHUNK_ALIGN as int > isize::MAX as int || self.used_closed as int + (self.cur as usize - self.base as usize) as int > usize::MAX as int || self.reserved as int + CHUNK_SIZE_GROWTH_MAX as int + size as int + align as int + CHUNK_ALIGN as int > usize::MAX as int || self.chunks.view().len() + 1 > Vector::<
            blk::RawBlock<A>,
            A
        >::max_len()
        ensures |r| r != null && (r as usize & align - 1) == 0
    {
        if size == 0 {
            return ptr::from_addr_mut::<void>(align);
        }
        // The padding that aligns the data at the chunk's start: at most `align - 1` bytes.
        let pad_max = align - 1;
        // No block is larger than `isize::MAX` bytes.
        let limit = isize::MAX as usize;
        if pad_max > limit || size > limit - pad_max {
            panic("Arena: allocation size overflow");
        }
        self.used_closed += self.cur as usize - self.base as usize;
        self.open_chunk(size + pad_max);
        let p = round_up(self.base, self.end, pad_max);
        self.cur = unsafe (p + size);
        return p;
    }

    // Make the spare chunk when it holds `need` bytes, else a new chunk of at least `need` bytes, the
    // current region, empty.
    fn open_chunk(self: &mut Self, need: usize)
        requires need != 0 && need as int <= isize::MAX as int
        panics if self.reserved as int + CHUNK_SIZE_GROWTH_MAX as int + need as int > usize::MAX as int || self.chunks.view().len() + 1 > Vector::<
            blk::RawBlock<A>,
            A
        >::max_len()
        ensures self.base == self.cur && (self.base as usize) as int + need as int <= (self.end as usize) as int
        ensures self.used_closed == old(self.used_closed)
    {
        if let Some(c) = self.spare.take() {
            if c.size() >= need {
                self.use_chunk(c);
                return;
            }
            self.spare = Some(c);
        }
        let mut bytes = self.next_size;
        if bytes < need {
            bytes = need;
        }
        let c = blk::RawBlock::<A>::new_in(self.upstream, bytes, CHUNK_ALIGN);
        self.reserved += bytes;
        self.next_size = grown(self.next_size);
        self.use_chunk(c);
    }

    // Keep chunk `c` in use and make it the current region, empty.
    fn use_chunk(self: &mut Self, c: blk::RawBlock<A>)
        panics if self.chunks.view().len() + 1 > Vector::<blk::RawBlock<A>, A>::max_len()
        ensures self.base == self.cur && (self.end as usize) as int - (self.base as usize) as int == old(c.size()) as int
        ensures self.used_closed == old(self.used_closed) && self.reserved == old(self.reserved)
    {
        let n = c.size();
        let base = c.ptr();
        let end = unsafe (base + n);
        self.base = base;
        self.end = end;
        self.cur = base;
        self.chunks.push(c);
    }

    // The block of the current region that ends at the cursor gives its bytes back. Integer arithmetic:
    // `ptr` may be null with a zero size.
    @always_inline
    unsafe const fn dealloc(self: &mut Self, ptr: *mut void, size: usize) {
        let at = ptr as usize;
        if at <= self.cur as usize && self.cur as usize - at == size && at >= self.base as usize {
            self.cur = ptr as *mut u8;
        }
    }

    unsafe fn realloc(self: &mut Self, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void
        requires new_size as int <= isize::MAX as int && align != 0 && (align & align - 1) == 0 && (ptr as usize & align - 1) == 0
        panics if new_size as int + align as int + CHUNK_ALIGN as int > isize::MAX as int || self.used_closed as int + (self.cur as usize - self.base as usize) as int > usize::MAX as int || self.reserved as int + CHUNK_SIZE_GROWTH_MAX as int + new_size as int + align as int + CHUNK_ALIGN as int > usize::MAX as int || self.chunks.view().len() + 1 > Vector::<
            blk::RawBlock<A>,
            A
        >::max_len()
        ensures |r| r != null && (r as usize & align - 1) == 0
    {
        let at = ptr as usize;
        if at <= self.cur as usize && self.cur as usize - at == old_size && at >= self.base as usize && new_size <= self.end as usize - at {
            self.cur = unsafe (ptr as *mut u8 + new_size);
            return ptr;
        }
        if new_size <= old_size && ptr != null {
            return ptr;
        }
        let p = unsafe self.alloc(new_size, align);
        if old_size != 0 {
            unsafe memcpy(p, ptr, old_size);
        }
        return p;
    }

    // Keep the largest chunk as the spare, return the others upstream.
    fn reset(self: &mut Self) {
        let mut keep = self.spare.take();
        while let Some(c) = self.chunks.pop() {
            let larger = switch keep.as_ref() {
                Some(k) => c.size() > k.size(),
                None => true,
            };
            if larger {
                keep = Some(c);
            }
        }
        self.reserved = (switch keep.as_ref() {
            Some(k) => k.size(),
            None => 0,
        });
        self.spare = keep;
        self.restart();
    }

    const fn bytes_used(self: &Self) usize {
        return self.used_closed + (self.cur as usize - self.base as usize);
    }
}

extend<'b, A: Allocator> Arena<'b, A> {
    /// An empty arena whose chunks come from `upstream`; it requests nothing before the first `alloc`.
    pub const fn new_in(upstream: A) Arena<'b, A> {
        return Arena::<A> { state: UnsafeCell::<ArenaState<A>>::new(ArenaState::<A>::new(null, 0, upstream)) };
    }

    /// An arena that allocates from `buf` first and from chunks of `upstream` once `buf` is full. It
    /// borrows `buf` for `'b` and never frees it.
    pub const fn with_buffer_in(buf: []'b mut u8, upstream: A) Arena<'b, A> {
        let st = ArenaState::<A>::new(buf.ptr, buf.len, upstream);
        return Arena::<A> { state: UnsafeCell::<ArenaState<A>>::new(st) };
    }

    /// The allocator handle for containers. Every copy borrows the arena: it cannot be reset, moved or
    /// freed while a handle is live.
    pub const fn allocator(self: &Self) ArenaAlloc<A> {
        return ArenaAlloc::<A> { state: self.state.get() };
    }

    /// Invalidate every block: keep the largest chunk for reuse, return the other chunks upstream, and
    /// start again at the caller buffer. O(chunks).
    pub fn reset(self: &mut Self) {
        unsafe (*self.state.get()).reset();
    }

    /// Bytes of the blocks handed out since construction or `reset`, with their alignment padding, minus
    /// the blocks rolled back by `dealloc` or a shrinking `realloc`.
    pub const fn bytes_used(self: &Self) usize {
        return self.state.get_ref().bytes_used();
    }

    /// Bytes the arena can hand out without new chunks: the caller buffer and every chunk it holds.
    pub const fn bytes_reserved(self: &Self) usize {
        let st = self.state.get_ref();
        return st.reserved + st.buf_len;
    }
}

extend<'b, A: Allocator + Default> Arena<'b, A> {
    /// An empty arena over a default-constructed upstream allocator.
    pub fn new() Arena<'b, A> {
        return Arena::<A>::new_in(A::default());
    }

    /// `with_buffer_in` with a default-constructed upstream allocator. `Arena::<NoAlloc>::with_buffer`
    /// never touches the heap: a request past the buffer panics.
    pub fn with_buffer(buf: []'b mut u8) Arena<'b, A> {
        return Arena::<A>::with_buffer_in(buf, A::default());
    }
}

// The handle reaches the state through a raw pointer while other handles exist: no method keeps a
// reference to the state past its return, and the borrow of the arena keeps the state alive.
extend<'a, A: Allocator> ArenaAlloc<'a, A> as Allocator {
    // A block of a chunk: not null, aligned as asked.
    pub spec fn owns(ptr: *mut void, size: usize, align: usize) bool {
        return ptr != null && align != 0 && (ptr as usize & align - 1) == 0;
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
        unsafe (*self.state).dealloc(ptr, size);
    }
}

extend<'b, A: Allocator + Default> Arena<'b, A> as Default {
    pub fn default() Arena<'b, A> {
        return Arena::<A>::new();
    }
}

// The arena owns its chunks, and a handle cannot outlive the borrow that pins it to one thread.
unsafe extend<'b, A: Allocator + Send> Arena<'b, A> as Send {}
