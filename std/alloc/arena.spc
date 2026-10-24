// Arena<'b, A = Global>: a monotonic bump allocator, after C++ `std::pmr::monotonic_buffer_resource`
// ([mem.res.monotonic.buffer]). Containers take its `ArenaAlloc` handle: `Vector::new_in(arena.allocator())`.
//
// Memory comes from an optional caller buffer (`with_buffer`), then from chunks requested from the upstream
// allocator `A`. The first chunk is 4 KiB (one page: a short-lived arena costs one small request, and the
// two-word chunk header is at most 0.4% of it); each next chunk doubles, as `Vector` capacity does, up to 64 MiB.
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

extern "C" {
    fn memcpy(dst: *mut void, src: *const void, n: usize) *mut void;
}

// The alignment of every chunk requested upstream, and of the data after its header: what `malloc` gives
// without an over-aligned request (16 bytes on 64-bit targets, 8 on wasm32).
const CHUNK_ALIGN: usize = 2 * sizeof(usize);
const CHUNK_SIZE_INITIAL: usize = 4096;
// The geometric chunk size stops growing here; a larger request still gets a chunk that fits it.
const CHUNK_SIZE_GROWTH_MAX: usize = 1 << 26;

// The header at the start of each upstream chunk. Its size keeps the data after it at `CHUNK_ALIGN`.
struct ArenaChunk {
    pub(file) next: *mut ArenaChunk, // older chunk in the same list
    pub(file) size: usize, // bytes requested upstream, header included
}

static_assert(sizeof(ArenaChunk) == CHUNK_ALIGN, "the chunk header keeps the data at CHUNK_ALIGN");

// The bump state. `cur <= end` always; `cur` and `end` are never null, so a null pointer with a zero size
// (an empty container's buffer) never ends at the cursor.
struct ArenaState<A> {
    pub(file) cur: *mut u8, // next free byte of the current region
    pub(file) end: *mut u8, // one past the current region
    pub(file) base: *mut u8, // start of the current region
    pub(file) used_closed: usize, // bytes used in the regions before the current one
    pub(file) chunks: *mut ArenaChunk, // chunks in use, newest first
    pub(file) spare: *mut ArenaChunk, // the chunk `reset` kept, not in use; null when none
    pub(file) buf: *mut u8, // the caller buffer
    pub(file) buf_len: usize, // its length; 0 when there is none
    pub(file) reserved: usize, // bytes of the chunks held, `spare` included
    pub(file) next_size: usize, // size of the next chunk requested upstream
    pub(file) upstream: A,
}

/// A monotonic bump allocator over an optional caller buffer and chunks from `A`. Owns its chunks and
/// returns them upstream when freed. Containers allocate through `allocator()`.
pub struct Arena<'b, A = Global> {
    state: UnsafeCell<ArenaState<A>>,
}

/// The `Allocator` handle of an `Arena`: one pointer, `Copy`, valid while the arena is borrowed for `'a`.
@derive(Copy)
pub struct ArenaAlloc<'a, A = Global> {
    pub(file) state: *mut ArenaState<A>,
}

// The address of an empty region: non-null and aligned, never dereferenced.
const fn empty_region() *mut u8 {
    return CHUNK_ALIGN as *mut u8;
}

// The chunk size after `n`: twice as large, up to `CHUNK_SIZE_GROWTH_MAX`.
const fn grown(n: usize) usize {
    if n >= CHUNK_SIZE_GROWTH_MAX / 2 {
        return CHUNK_SIZE_GROWTH_MAX;
    }
    return n * 2;
}

extend<A: Allocator> ArenaState<A> {
    const fn new(buf: *mut u8, buf_len: usize, upstream: A) ArenaState<A> {
        let mut next_size = grown(buf_len);
        if next_size < CHUNK_SIZE_INITIAL {
            next_size = CHUNK_SIZE_INITIAL;
        }
        let mut s = ArenaState::<A> {
            cur: null,
            end: null,
            base: null,
            used_closed: 0,
            chunks: null,
            spare: null,
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
        if self.buf_len != 0 {
            self.base = self.buf;
            self.end = unsafe (self.buf + self.buf_len);
        } else {
            self.base = empty_region();
            self.end = self.base;
        }
        self.cur = self.base;
        self.used_closed = 0;
    }

    @always_inline
    unsafe fn alloc(self: &mut Self, size: usize, align: usize) *mut void {
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
    unsafe fn alloc_slow(self: &mut Self, size: usize, align: usize) *mut void {
        if size == 0 {
            return align as *mut void;
        }
        // The chunk data starts at `CHUNK_ALIGN`, so a larger alignment may need this much padding.
        let mut pad_max: usize = 0;
        if align > CHUNK_ALIGN {
            pad_max = align - CHUNK_ALIGN;
        }
        let need = switch size.checked_add(sizeof(ArenaChunk) + pad_max) {
            Some(n) => n,
            None => panic("Arena: allocation size overflow"),
        };
        self.used_closed += self.cur as usize - self.base as usize;
        let mut chunk = self.spare;
        if chunk != null && unsafe (*chunk).size >= need {
            self.spare = null;
        } else {
            let mut bytes = self.next_size;
            if bytes < need {
                bytes = need;
            }
            chunk = (unsafe self.upstream.alloc(bytes, CHUNK_ALIGN)) as *mut ArenaChunk;
            unsafe (*chunk).size = bytes;
            self.reserved += bytes;
            self.next_size = grown(self.next_size);
        }
        unsafe (*chunk).next = self.chunks;
        self.chunks = chunk;
        self.base = unsafe (chunk as *mut u8 + sizeof(ArenaChunk));
        self.end = unsafe (chunk as *mut u8 + (*chunk).size);
        let p = unsafe (self.base + ((self.base as usize).wrapping_neg() & align - 1));
        self.cur = unsafe (p + size);
        return p;
    }

    @always_inline
    unsafe const fn dealloc(self: &mut Self, ptr: *mut void, size: usize) {
        // Integer arithmetic: `ptr` may be null with a zero size.
        if ptr as usize + size == self.cur as usize {
            self.cur = ptr as *mut u8;
        }
    }

    unsafe fn realloc(self: &mut Self, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        let at = ptr as usize;
        if at + old_size == self.cur as usize && new_size <= self.end as usize - at {
            self.cur = unsafe (ptr as *mut u8 + new_size);
            return ptr;
        }
        if new_size <= old_size && old_size != 0 {
            return ptr;
        }
        let p = unsafe self.alloc(new_size, align);
        if old_size != 0 {
            unsafe memcpy(p, ptr, old_size);
        }
        return p;
    }

    // Return `chunk` and every older chunk of its list upstream.
    fn free_chunks(self: &mut Self, chunk: *mut ArenaChunk) {
        let mut c = chunk;
        while c != null {
            let next = unsafe (*c).next;
            unsafe self.upstream.dealloc(c, (*c).size, CHUNK_ALIGN);
            c = next;
        }
    }

    fn reset(self: &mut Self) {
        let mut keep = self.spare;
        let mut c = self.chunks;
        while c != null {
            let next = unsafe (*c).next;
            unsafe (*c).next = null;
            if keep == null || unsafe ((*c).size > (*keep).size) {
                self.free_chunks(keep);
                keep = c;
            } else {
                self.free_chunks(c);
            }
            c = next;
        }
        self.chunks = null;
        self.spare = keep;
        self.reserved = 0;
        if keep != null {
            self.reserved = unsafe (*keep).size;
        }
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

    /// Bytes the arena can hand out without new chunks, plus chunk headers: the caller buffer and every
    /// chunk it holds.
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

extend<'b, A: Allocator> Arena<'b, A> as Free {
    pub fn free(self: &mut Self) {
        let st = unsafe &mut *self.state.get();
        st.free_chunks(st.chunks);
        st.free_chunks(st.spare);
        st.chunks = null;
        st.spare = null;
        st.reserved = 0;
    }
}

extend<'b, A: Allocator + Default> Arena<'b, A> as Default {
    pub fn default() Arena<'b, A> {
        return Arena::<A>::new();
    }
}

// The arena owns its chunks, and a handle cannot outlive the borrow that pins it to one thread.
unsafe extend<'b, A: Send> Arena<'b, A> as Send {}
