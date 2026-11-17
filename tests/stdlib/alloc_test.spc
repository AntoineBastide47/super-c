// std::alloc: Arena, Pool and NoAlloc. Containers with owning elements on each handle under the leak
// check, alignment of every block, free-list reuse, arena roll-back and in-place realloc, caller buffers,
// reset and release against a counting upstream, zero-size and unpooled requests, and a seeded random
// alloc, realloc and free sequence that checks block overlap and contents.
import std::alloc;
import std::math::random;

// What a `Counting` upstream saw. Every block it hands out comes from `Global`.
struct Counts {
    pub allocs: usize,
    pub deallocs: usize,
    pub reallocs: usize,
    pub live_bytes: usize,
}

// A stateful upstream allocator: a pointer to the counters of one test.
@derive(Copy)
struct Counting {
    pub c: *mut Counts,
}

extend Counting as Allocator {
    spec fn owns(ptr: *mut void, size: usize, align: usize) bool {
        return Global::owns(ptr, size, align);
    }

    pub unsafe fn alloc(self: &mut Counting, size: usize, align: usize) *mut void {
        unsafe (*self.c).allocs += 1;
        unsafe (*self.c).live_bytes += size;
        let mut g = Global {};
        return unsafe g.alloc(size, align);
    }

    // A `realloc` of null allocates.
    pub unsafe fn realloc(self: &mut Counting, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        if ptr == null {
            unsafe (*self.c).allocs += 1;
        } else {
            unsafe (*self.c).reallocs += 1;
        }
        unsafe (*self.c).live_bytes = (*self.c).live_bytes - old_size + new_size;
        let mut g = Global {};
        return unsafe g.realloc(ptr, old_size, new_size, align);
    }

    pub unsafe fn dealloc(self: &mut Counting, ptr: *mut void, size: usize, align: usize) {
        unsafe (*self.c).deallocs += 1;
        unsafe (*self.c).live_bytes -= size;
        let mut g = Global {};
        unsafe g.dealloc(ptr, size, align);
    }
}

const fn counting(c: &mut Counts) Counting {
    return Counting { c: c };
}

// A block that allocator `H` handed out, with the tag of the byte pattern written into it.
struct Block<H: Allocator>
    invariant self.align != 0 && (self.align & self.align - 1) == 0 && H::owns(self.ptr, self.size, self.align)
{
    ptr: *mut void,
    size: usize,
    align: usize,
    tag: u8,
}

fn take<H: Allocator>(h: &mut H, size: usize, align: usize, tag: u8) Block<H>
    requires size as int <= isize::MAX as int && align != 0 && (align & align - 1) == 0
    ensures |r| r.size == size && r.align == align && r.tag == tag
{
    let p = unsafe h.alloc(size, align);
    return Block::<H> { ptr: p, size: size, align: align, tag: tag };
}

fn give<H: Allocator>(h: &mut H, b: Block<H>) {
    unsafe h.dealloc(b.ptr, b.size, b.align);
}

// Block `b` resized to `size` bytes, tagged `tag`.
fn resize<H: Allocator>(h: &mut H, b: Block<H>, size: usize, tag: u8) Block<H>
    requires size as int <= isize::MAX as int
    ensures |r| r.size == size && r.align == old(b.align) && r.tag == tag
{
    let p = unsafe h.realloc(b.ptr, b.size, size, b.align);
    return Block::<H> { ptr: p, size: size, align: b.align, tag: tag };
}

const fn pattern(tag: u8, j: usize) u8 {
    return tag ^ j as u8 ^ (j >> 8) as u8;
}

const fn fill<H: Allocator>(b: &Block<H>) {
    let p = b.ptr as *mut u8;
    for j in 0..b.size {
        unsafe p[j] = pattern(b.tag, j);
    }
}

// Whether the first `n` bytes at `p` hold the pattern of `tag`.
const fn intact(p: *const void, n: usize, tag: u8) bool {
    let q = p as *const u8;
    for j in 0..n {
        if unsafe q[j] != pattern(tag, j) {
            return false;
        }
    }
    return true;
}

// True when `b` shares no byte with any block of `live`. Zero-size blocks share none.
const fn disjoint<H: Allocator>(live: &Vector<Block<H>>, b: &Block<H>) bool {
    let (ba, bs) = (b.ptr as usize, b.size);
    for o in live.iter() {
        let (oa, os) = (o.ptr as usize, o.size);
        if bs != 0 && os != 0 && ba < oa + os && oa < ba + bs {
            return false;
        }
    }
    return true;
}

// A random power of two from 1 to 4096, mostly small.
const fn random_align(rng: &mut random::Pcg32) usize
    ensures |r| r != 0 && (r & r - 1) == 0
{
    let r = rng.next_u32();
    if r % 8 == 0 {
        return 1usize << ((r >> 3) % 13) as usize;
    }
    return 1usize << ((r >> 3) % 5) as usize;
}

// A random size: mostly pooled sizes, some unpooled ones, some zero.
const fn random_size(rng: &mut random::Pcg32) usize
    ensures |r| r <= 10096
{
    let r = rng.next_u32();
    if r % 16 == 0 {
        return 0;
    }
    if r % 16 == 1 {
        return 4097 + ((r >> 4) % 6000) as usize;
    }
    return 1 + ((r >> 4) % 600) as usize;
}

// The randomized sequence: 3000 steps of alloc, realloc or free through `h`, each block checked for
// alignment, overlap with every live block, and intact contents before it is reallocated or freed.
fn random_sequence<H: Allocator>(mut h: H, seed: u64) {
    let mut rng = random::Pcg32::new(seed, 7);
    let mut live = Vector::<Block<H>>::new();
    let mut tag: u8 = 1;
    for _step in 0..3000 {
        let r = rng.next_u32() % 8;
        if live.len() > 0 && (r < 2 || live.len() > 150) {
            let i = rng.next_u32() as usize % live.len();
            let b = live.swap_remove(i).unwrap();
            assert(intact(b.ptr, b.size, b.tag), "a block keeps its bytes until it is freed");
            give(&mut h, b);
        } else if live.len() > 0 && r < 4 {
            let i = rng.next_u32() as usize % live.len();
            let old = live.swap_remove(i).unwrap();
            assert(intact(old.ptr, old.size, old.tag), "a block keeps its bytes until it is reallocated");
            let (old_size, old_tag) = (old.size, old.tag);
            let size = random_size(&mut rng);
            let b = resize(&mut h, old, size, tag);
            let kept = if size < old_size {
                size
            } else {
                old_size
            };
            assert(intact(b.ptr, kept, old_tag), "realloc keeps the common prefix");
            assert(b.ptr != null, "realloc never returns null");
            assert_eq(b.ptr as usize % b.align, 0);
            assert(disjoint(&live, &b), "a reallocated block overlaps no live block");
            fill(&b);
            live.push(b);
            tag = tag.wrapping_add(1);
        } else {
            let size = random_size(&mut rng);
            let align = random_align(&mut rng);
            let b = take(&mut h, size, align, tag);
            assert(b.ptr != null, "alloc never returns null");
            assert_eq(b.ptr as usize % align, 0);
            assert(disjoint(&live, &b), "a new block overlaps no live block");
            fill(&b);
            live.push(b);
            tag = tag.wrapping_add(1);
        }
    }
    while let Some(b) = live.pop() {
        assert(intact(b.ptr, b.size, b.tag), "a block keeps its bytes until it is freed");
        give(&mut h, b);
    }
}

@test
fn arena_containers_with_owning_elements() {
    let a = alloc::Arena::<Global>::new();
    let h = a.allocator();
    let mut v = Vector::<String<alloc::ArenaAlloc<Global>>, alloc::ArenaAlloc<Global>>::new_in(h);
    for i in 0..200 {
        let mut s = String::<alloc::ArenaAlloc<Global>>::from_str_in(h, "an element longer than the inline buffer ");
        s.push_str(i.fmt().as_str());
        v.push(s);
    }
    assert_eq(v.len(), 200);
    assert(v.at(7).as_str().ends_with(" 7"), "element 7");
    let _ = v.pop();
    let mut m = Map::<i32, String, alloc::ArenaAlloc<Global>>::new_in(h);
    for i in 0..100 {
        m.insert(i, String::from_str("a heap string from Global, held by an arena map"));
    }
    assert_eq(m.len(), 100);
    let k: i32 = 42;
    assert(m.remove(&k).is_some(), "remove from an arena map");
    let b = Box::<Vector<i32>, alloc::ArenaAlloc<Global>>::new_in(h, Vector::<i32>::from([1, 2, 3]));
    assert_eq(b.get().len(), 3);
    assert(a.bytes_used() > 0, "the containers took arena memory");
    assert(a.bytes_reserved() >= a.bytes_used(), "used fits the reserve");
}

@test
fn pool_containers_with_owning_elements() {
    let p = alloc::Pool::<Global>::new();
    let h = p.allocator();
    let mut m = Map::<i32, String<alloc::PoolAlloc<Global>>, alloc::PoolAlloc<Global>>::new_in(h);
    for i in 0..300 {
        let mut s = String::<alloc::PoolAlloc<Global>>::from_str_in(h, "a pooled string past the inline buffer ");
        s.push_str(i.fmt().as_str());
        m.insert(i, s);
    }
    for i in 0..150 {
        assert(m.remove(&i).is_some(), "remove from a pool map");
    }
    assert_eq(m.len(), 150);
    let k: i32 = 299;
    assert(m.get(&k).unwrap().as_str().ends_with(" 299"), "value 299");
    let mut v = Vector::<String, alloc::PoolAlloc<Global>>::new_in(h);
    for _i in 0..1000 {
        v.push(String::from_str("a Global string in a pooled vector, long"));
    }
    assert(p.bytes_unpooled() > 0, "the vector grew past the largest class");
    let b = Box::<String, alloc::PoolAlloc<Global>>::new_in(h, String::from_str("boxed in a pool block, long text"));
    assert_eq(b.get().len(), 32);
}

@test
fn containers_return_every_chunk_upstream() {
    let mut counts = Counts {};
    {
        let a = alloc::Arena::<Counting>::new_in(counting(&mut counts));
        let mut v = Vector::<String, alloc::ArenaAlloc<Counting>>::new_in(a.allocator());
        for _i in 0..5000 {
            v.push(String::from_str("x"));
        }
        let p = alloc::Pool::<Counting>::new_in(counting(&mut counts));
        let mut m = Map::<u64, u64, alloc::PoolAlloc<Counting>>::new_in(p.allocator());
        for i in 0..5000 {
            m.insert(i as u64, i as u64);
        }
        assert(counts.allocs > 2, "both allocators asked upstream for chunks");
    }
    assert_eq(counts.deallocs, counts.allocs);
    assert_eq(counts.live_bytes, 0);
}

@test
fn arena_aligns_every_request() {
    let a = alloc::Arena::<Global>::new();
    let mut h = a.allocator();
    for k in 0usize..13 {
        let align = 1 as usize << k;
        let p = unsafe h.alloc(3, align);
        assert_eq(p as usize % align, 0);
        let q = unsafe h.alloc(align + 1, align);
        assert_eq(q as usize % align, 0);
        assert(q as usize >= p as usize + 3 || q as usize + align + 1 <= p as usize, "blocks do not overlap");
    }
}

@test
fn pool_aligns_every_request() {
    let p = alloc::Pool::<Global>::new();
    let mut h = p.allocator();
    for k in 0usize..13 {
        let align = 1 as usize << k;
        for size in [1, 16, 24, 100, 4096, 5000] {
            let s = size as usize;
            let b = unsafe h.alloc(s, align);
            assert_eq(b as usize % align, 0);
            unsafe h.dealloc(b, s, align);
        }
    }
}

// Two freed blocks of 64 bytes come back last freed first, and a freed block of 48 bytes serves a request
// of 60, its class.
fn reuses_freed_blocks<H: Allocator>(h: &mut H) {
    let mut held = Vector::<Block<H>>::new();
    held.push(take(h, 64, 8, 0));
    held.push(take(h, 64, 8, 0));
    let (pa, pb) = (held.at(0).ptr, held.at(1).ptr);
    // Frees b, then a.
    while let Some(b) = held.pop() {
        give(h, b);
    }
    held.push(take(h, 64, 8, 0));
    assert(held.at(0).ptr == pa, "the last freed block comes back first");
    held.push(take(h, 64, 8, 0));
    assert(held.at(1).ptr == pb, "then the one freed before it");
    let c = take(h, 48, 16, 0);
    let pc = c.ptr;
    give(h, c);
    held.push(take(h, 60, 4, 0));
    assert(held.at(2).ptr == pc, "a request of the same class takes the block");
    while let Some(b) = held.pop() {
        give(h, b);
    }
}

@test
fn pool_reuses_freed_blocks() {
    let p = alloc::Pool::<Global>::new();
    let mut h = p.allocator();
    reuses_freed_blocks(&mut h);
    let reserved = p.bytes_reserved();
    for _i in 0..1000 {
        let x = take(&mut h, 200, 8, 0);
        give(&mut h, x);
    }
    assert_eq(p.bytes_reserved(), reserved + 1024);
}

@test
fn arena_rolls_back_the_most_recent_block() {
    let a = alloc::Arena::<Global>::new();
    let mut h = a.allocator();
    let x = take(&mut h, 100, 8, 0);
    let px = x.ptr;
    let used = a.bytes_used();
    // No padding between the blocks: 100 and 150 are multiples of their successors' alignment.
    let y = take(&mut h, 50, 4, 0);
    let z = take(&mut h, 30, 2, 0);
    let pz = z.ptr;
    give(&mut h, z);
    let z2 = take(&mut h, 30, 2, 0);
    assert(z2.ptr == pz, "the cursor moved back to z");
    give(&mut h, z2);
    give(&mut h, y);
    assert_eq(a.bytes_used(), used);
    give(&mut h, x);
    assert_eq(a.bytes_used(), 0);
    let x2 = take(&mut h, 100, 8, 0);
    assert(x2.ptr == px, "every block freed in reverse order is reclaimed");
    // Freeing a block that is not the most recent frees nothing.
    let y2 = take(&mut h, 50, 4, 0);
    let z3 = take(&mut h, 30, 2, 0);
    give(&mut h, y2);
    assert(take(&mut h, 1, 1, 0).ptr as usize == z3.ptr as usize + 30, "y stays used");
}

@test
fn arena_reallocs_in_place() {
    let a = alloc::Arena::<Global>::new();
    let mut h = a.allocator();
    let p = (unsafe h.alloc(16, 8)) as *mut u8;
    for i in 0..16 {
        unsafe p[i] = i as u8;
    }
    let q = (unsafe h.realloc(p, 16, 400, 8)) as *mut u8;
    assert(q == p, "the most recent block grows in place");
    assert_eq(a.bytes_used(), 400);
    let r = (unsafe h.realloc(q, 400, 40, 8)) as *mut u8;
    assert(r == p, "and shrinks in place");
    assert_eq(a.bytes_used(), 40);
    let other = take(&mut h, 8, 8, 0);
    let s = (unsafe h.realloc(r, 40, 20, 8)) as *mut u8;
    assert(s == p, "a block that is not the most recent shrinks in place");
    let t = (unsafe h.realloc(s, 20, 64, 8)) as *mut u8;
    assert(t != p, "and grows into a new block");
    for i in 0..16 {
        assert_eq(unsafe t[i], i as u8);
    }
    let u = (unsafe h.realloc(t, 64, 8000, 8)) as *mut u8;
    assert(u != t, "a growth past the chunk moves the block");
    for i in 0..16 {
        assert_eq(unsafe u[i], i as u8);
    }
    give(&mut h, other);
}

@test
fn pool_reallocs_in_class_and_across() {
    let mut counts = Counts {};
    let pool = alloc::Pool::<Counting>::new_in(counting(&mut counts));
    let mut h = pool.allocator();
    let p = (unsafe h.alloc(40, 8)) as *mut u8;
    for i in 0..40 {
        unsafe p[i] = i as u8;
    }
    assert(unsafe h.realloc(p, 40, 64, 8) == p, "the same class keeps the block");
    let q = (unsafe h.realloc(p, 64, 3000, 8)) as *mut u8;
    assert(q != p, "a larger class moves the block");
    for i in 0..40 {
        assert_eq(unsafe q[i], i as u8);
    }
    let reallocs = counts.reallocs;
    let r = (unsafe h.realloc(q, 3000, 10000, 8)) as *mut u8;
    assert_eq(pool.bytes_unpooled(), 10000);
    let s = (unsafe h.realloc(r, 10000, 20000, 8)) as *mut u8;
    assert_eq(counts.reallocs, reallocs + 1);
    assert_eq(pool.bytes_unpooled(), 20000);
    for i in 0..40 {
        assert_eq(unsafe s[i], i as u8);
    }
    let t = unsafe h.realloc(s, 20000, 100, 8);
    assert_eq(pool.bytes_unpooled(), 0);
    unsafe h.dealloc(t, 100, 8);
}

@test
fn arena_buffer_comes_first() {
    let mut counts = Counts {};
    let mut buf: [u8; 3000] = [0; 3000];
    let lo = ((&buf[0]) as *const u8) as usize;
    {
        let a = alloc::Arena::<Counting>::with_buffer_in(buf, counting(&mut counts));
        let mut h = a.allocator();
        assert_eq(a.bytes_reserved(), 3000);
        // 180 blocks of 16 bytes and at most 15 bytes of padding fit the buffer.
        for _i in 0..180 {
            let p = unsafe h.alloc(16, 16);
            assert(p as usize >= lo && p as usize + 16 <= lo + 3000, "inside the buffer");
        }
        assert_eq(counts.allocs, 0);
        let big = unsafe h.alloc(200, 8);
        assert(big as usize >= lo + 3000 || big as usize + 200 <= lo, "outside the buffer");
        // A chunk, and the arena's list of chunks its first buffer.
        assert_eq(counts.allocs, 2);
        // The first chunk is twice the buffer.
        assert_eq(a.bytes_reserved(), 3000 + 6000);
    }
    assert_eq(counts.deallocs, 2);
    assert_eq(counts.live_bytes, 0);
}

@test
fn arena_no_alloc_buffer_serves_requests() {
    let mut buf: [u8; 512] = [0; 512];
    let a = alloc::Arena::<alloc::NoAlloc>::with_buffer(buf);
    let mut v = Vector::<u32, alloc::ArenaAlloc<alloc::NoAlloc>>::new_in(a.allocator());
    for i in 0..48 {
        v.push(i as u32);
    }
    assert_eq(*v.at(47), 47);
    // The vector grows in place at the cursor: 64 elements of 4 bytes and the padding.
    assert(a.bytes_used() <= 256 + 3, "the growth stayed in place");
}

@test(should_panic)
fn arena_no_alloc_panics_past_the_buffer() {
    let mut buf: [u8; 64] = [0; 64];
    let a = alloc::Arena::<alloc::NoAlloc>::with_buffer(buf);
    let mut h = a.allocator();
    let _ = unsafe h.alloc(65, 1);
}

@test
fn arena_reset_keeps_the_largest_chunk() {
    let mut counts = Counts {};
    {
        let mut a = alloc::Arena::<Counting>::new_in(counting(&mut counts));
        {
            let mut h = a.allocator();
            for _i in 0..100 {
                let _ = unsafe h.alloc(1000, 8);
            }
        }
        // Chunks of 4, 8, 16, 32 and 64 KiB hold 4, 8, 16, 32 and 65 blocks; the arena's list of chunks
        // takes a buffer.
        assert_eq(counts.allocs, 6);
        assert_eq(a.bytes_reserved(), 4096 + 8192 + 16384 + 32768 + 65536);
        a.reset();
        assert_eq(counts.deallocs, 4);
        assert_eq(a.bytes_used(), 0);
        assert_eq(a.bytes_reserved(), 65536);
        {
            let mut h = a.allocator();
            for _i in 0..65 {
                let _ = unsafe h.alloc(1000, 8);
            }
        }
        assert_eq(counts.allocs, 6);
        assert_eq(a.bytes_used(), 65000);
        a.reset();
        assert_eq(counts.deallocs, 4);
    }
    assert_eq(counts.deallocs, 6);
    assert_eq(counts.live_bytes, 0);
}

@test
fn arena_reset_restarts_in_the_buffer() {
    let mut buf: [u8; 128] = [0; 128];
    let lo = ((&buf[0]) as *const u8) as usize;
    let mut a = alloc::Arena::<Global>::with_buffer(buf);
    {
        let mut h = a.allocator();
        let _ = unsafe h.alloc(100, 1);
        let _ = unsafe h.alloc(100, 1);
    }
    a.reset();
    let mut h = a.allocator();
    assert((unsafe h.alloc(10, 1)) as usize == lo, "the buffer is used again first");
}

@test
fn pool_release_returns_every_chunk() {
    let mut counts = Counts {};
    {
        let mut p = alloc::Pool::<Counting>::new_in(counting(&mut counts));
        {
            let mut h = p.allocator();
            for k in 0usize..9 {
                let size = 16 as usize << k;
                for _i in 0..300 {
                    let _ = unsafe h.alloc(size, 8);
                }
            }
        }
        assert(p.bytes_reserved() > 0, "the classes hold chunks");
        assert(counts.live_bytes > p.bytes_reserved(), "the chunks and the list of them are live");
        p.release();
        assert_eq(p.bytes_reserved(), 0);
        assert_eq(counts.live_bytes, 0);
        assert_eq(counts.deallocs, counts.allocs);
        let mut h = p.allocator();
        let x = unsafe h.alloc(32, 8);
        unsafe h.dealloc(x, 32, 8);
    }
    assert_eq(counts.deallocs, counts.allocs);
    assert_eq(counts.live_bytes, 0);
}

@test
fn zero_size_requests_take_no_memory() {
    let mut counts = Counts {};
    let a = alloc::Arena::<Counting>::new_in(counting(&mut counts));
    let p = alloc::Pool::<Counting>::new_in(counting(&mut counts));
    let mut ha = a.allocator();
    let mut hp = p.allocator();
    for k in 0usize..13 {
        let align = 1 as usize << k;
        let x = unsafe ha.alloc(0, align);
        let y = unsafe hp.alloc(0, align);
        assert(x != null, "arena: non-null");
        assert(y != null, "pool: non-null");
        assert_eq(x as usize % align, 0);
        assert_eq(y as usize % align, 0);
        unsafe ha.dealloc(x, 0, align);
        unsafe hp.dealloc(y, 0, align);
    }
    // An empty container frees a null buffer of size 0.
    unsafe ha.dealloc(null, 0, 1);
    unsafe hp.dealloc(null, 0, 1);
    assert_eq(counts.allocs, 0);
    assert_eq(a.bytes_used(), 0);
    let m = Map::<i32, i32, alloc::PoolAlloc<Counting>>::new_in(hp);
    assert_eq(m.len(), 0);
}

@test
fn pool_sends_large_requests_upstream() {
    let mut counts = Counts {};
    let p = alloc::Pool::<Counting>::new_in(counting(&mut counts));
    let mut h = p.allocator();
    let x = take(&mut h, 4097, 8, 0);
    assert_eq(counts.allocs, 1);
    assert_eq(counts.live_bytes, 4097);
    assert_eq(p.bytes_unpooled(), 4097);
    assert_eq(p.bytes_reserved(), 0);
    give(&mut h, x);
    assert_eq(counts.deallocs, 1);
    assert_eq(p.bytes_unpooled(), 0);
    let y = take(&mut h, 64, 8192, 0);
    assert_eq(y.ptr as usize % 8192, 0);
    assert_eq(counts.allocs, 2);
    assert_eq(p.bytes_unpooled(), 64);
    give(&mut h, y);
    assert_eq(counts.deallocs, 2);
    assert_eq(p.bytes_unpooled(), 0);
    // The 4096 class takes a chunk, and the pool's list of chunks its first buffer.
    let z = take(&mut h, 4096, 4096, 0);
    assert_eq(counts.allocs, 4);
    assert_eq(p.bytes_reserved(), 4096);
    give(&mut h, z);
    assert_eq(counts.deallocs, 2);
}

@test
fn pool_random_sequence() {
    let p = alloc::Pool::<Global>::new();
    random_sequence(p.allocator(), 1);
    assert_eq(p.bytes_unpooled(), 0);
}

@test
fn arena_random_sequence() {
    let a = alloc::Arena::<Global>::new();
    random_sequence(a.allocator(), 2);
}

@test
fn arena_with_buffer_random_sequence() {
    let mut buf: [u8; 3000] = [0; 3000];
    let a = alloc::Arena::<Global>::with_buffer(buf);
    random_sequence(a.allocator(), 3);
}
