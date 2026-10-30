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
    pub unsafe fn alloc(self: &mut Counting, size: usize, align: usize) *mut void {
        unsafe (*self.c).allocs += 1;
        unsafe (*self.c).live_bytes += size;
        let mut g = Global {};
        return unsafe g.alloc(size, align);
    }

    pub unsafe fn realloc(self: &mut Counting, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        unsafe (*self.c).reallocs += 1;
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

// A block handed out by the allocator under test, with the byte pattern written into it.
struct Live {
    pub addr: usize,
    pub size: usize,
    pub align: usize,
    pub tag: u8,
}

const fn pattern(tag: u8, j: usize) u8 {
    return tag ^ j as u8 ^ (j >> 8) as u8;
}

const fn fill(b: &Live) {
    let p = b.addr as *mut u8;
    for j in 0..b.size {
        unsafe p[j] = pattern(b.tag, j);
    }
}

const fn intact(b: &Live, n: usize) bool {
    let p = b.addr as *const u8;
    for j in 0..n {
        if unsafe p[j] != pattern(b.tag, j) {
            return false;
        }
    }
    return true;
}

// True when `b` shares no byte with any block of `live`. Zero-size blocks share none.
const fn disjoint(live: &Vector<Live>, b: &Live) bool {
    for o in live.iter() {
        if b.size != 0 && o.size != 0 && b.addr < o.addr + o.size && o.addr < b.addr + b.size {
            return false;
        }
    }
    return true;
}

// A random power of two from 1 to 4096, mostly small.
const fn random_align(rng: &mut random::Pcg32) usize {
    let r = rng.next_u32();
    if r % 8 == 0 {
        return 1usize << ((r >> 3) % 13) as usize;
    }
    return 1usize << ((r >> 3) % 5) as usize;
}

// A random size: mostly pooled sizes, some unpooled ones, some zero.
const fn random_size(rng: &mut random::Pcg32) usize {
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
    let mut live = Vector::<Live>::new();
    let mut tag: u8 = 1;
    for _step in 0..3000 {
        let r = rng.next_u32() % 8;
        if live.len() > 0 && (r < 2 || live.len() > 150) {
            let i = rng.next_u32() as usize % live.len();
            let b = live.swap_remove(i).unwrap();
            assert(intact(&b, b.size), "a block keeps its bytes until it is freed");
            unsafe h.dealloc(b.addr as *mut void, b.size, b.align);
        } else if live.len() > 0 && r < 4 {
            let i = rng.next_u32() as usize % live.len();
            let old = live.swap_remove(i).unwrap();
            assert(intact(&old, old.size), "a block keeps its bytes until it is reallocated");
            let size = random_size(&mut rng);
            let p = unsafe h.realloc(old.addr as *mut void, old.size, size, old.align);
            let b = Live { addr: p as usize, size: size, align: old.align, tag: tag };
            let kept = if size < old.size {
                size
            } else {
                old.size
            };
            let moved = Live { addr: b.addr, size: kept, align: old.align, tag: old.tag };
            assert(intact(&moved, kept), "realloc keeps the common prefix");
            assert(p != null, "realloc never returns null");
            assert_eq(p as usize % old.align, 0);
            assert(disjoint(&live, &b), "a reallocated block overlaps no live block");
            fill(&b);
            live.push(b);
            tag = tag.wrapping_add(1);
        } else {
            let size = random_size(&mut rng);
            let align = random_align(&mut rng);
            let p = unsafe h.alloc(size, align);
            let b = Live { addr: p as usize, size: size, align: align, tag: tag };
            assert(p != null, "alloc never returns null");
            assert_eq(p as usize % align, 0);
            assert(disjoint(&live, &b), "a new block overlaps no live block");
            fill(&b);
            live.push(b);
            tag = tag.wrapping_add(1);
        }
    }
    while let Some(b) = live.pop() {
        assert(intact(&b, b.size), "a block keeps its bytes until it is freed");
        unsafe h.dealloc(b.addr as *mut void, b.size, b.align);
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

@test
fn pool_reuses_freed_blocks() {
    let p = alloc::Pool::<Global>::new();
    let mut h = p.allocator();
    let a = unsafe h.alloc(64, 8);
    let b = unsafe h.alloc(64, 8);
    let c = unsafe h.alloc(48, 16);
    unsafe h.dealloc(a, 64, 8);
    unsafe h.dealloc(b, 64, 8);
    assert(unsafe h.alloc(64, 8) == b, "the last freed block comes back first");
    assert(unsafe h.alloc(64, 8) == a, "then the one freed before it");
    // 48 bytes share the 64-byte class.
    unsafe h.dealloc(c, 48, 16);
    assert(unsafe h.alloc(60, 4) == c, "a request of the same class takes the block");
    let reserved = p.bytes_reserved();
    for _i in 0..1000 {
        let x = unsafe h.alloc(200, 8);
        unsafe h.dealloc(x, 200, 8);
    }
    assert_eq(p.bytes_reserved(), reserved + 1024);
}

@test
fn arena_rolls_back_the_most_recent_block() {
    let a = alloc::Arena::<Global>::new();
    let mut h = a.allocator();
    let x = unsafe h.alloc(100, 8);
    let used = a.bytes_used();
    // No padding between the blocks: 100 and 150 are multiples of their successors' alignment.
    let y = unsafe h.alloc(50, 4);
    let z = unsafe h.alloc(30, 2);
    // Freeing a block that is not the most recent frees nothing.
    unsafe h.dealloc(y, 50, 4);
    assert((unsafe h.alloc(1, 1)) as usize == z as usize + 30, "y stays used");
    unsafe h.dealloc((z as usize + 30) as *mut void, 1, 1);
    unsafe h.dealloc(z, 30, 2);
    assert(unsafe h.alloc(30, 2) == z, "the cursor moved back to z");
    unsafe h.dealloc(z, 30, 2);
    unsafe h.dealloc(y, 50, 4);
    assert_eq(a.bytes_used(), used);
    unsafe h.dealloc(x, 100, 8);
    assert_eq(a.bytes_used(), 0);
    assert(unsafe h.alloc(100, 8) == x, "every block freed in reverse order is reclaimed");
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
    let other = unsafe h.alloc(8, 8);
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
    unsafe h.dealloc(other, 8, 8);
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
        assert_eq(counts.allocs, 1);
        // The first chunk is twice the buffer.
        assert_eq(a.bytes_reserved(), 3000 + 6000);
    }
    assert_eq(counts.deallocs, 1);
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
        // Chunks of 4, 8, 16, 32 and 64 KiB hold 4, 8, 16, 32 and 65 blocks after their headers.
        assert_eq(counts.allocs, 5);
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
        assert_eq(counts.allocs, 5);
        assert_eq(a.bytes_used(), 65000);
        a.reset();
        assert_eq(counts.deallocs, 4);
    }
    assert_eq(counts.deallocs, 5);
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
        assert_eq(counts.live_bytes, p.bytes_reserved());
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
    let x = unsafe h.alloc(4097, 8);
    assert_eq(counts.allocs, 1);
    assert_eq(counts.live_bytes, 4097);
    assert_eq(p.bytes_unpooled(), 4097);
    assert_eq(p.bytes_reserved(), 0);
    let y = unsafe h.alloc(64, 8192);
    assert_eq(y as usize % 8192, 0);
    assert_eq(counts.allocs, 2);
    assert_eq(p.bytes_unpooled(), 4097 + 64);
    // The 4096 class takes a chunk, and class 16 a chunk for the chunk's descriptor.
    let z = unsafe h.alloc(4096, 4096);
    assert_eq(counts.allocs, 4);
    assert_eq(p.bytes_reserved(), 4096 + 1024);
    unsafe h.dealloc(x, 4097, 8);
    unsafe h.dealloc(y, 64, 8192);
    assert_eq(counts.deallocs, 2);
    assert_eq(p.bytes_unpooled(), 0);
    unsafe h.dealloc(z, 4096, 4096);
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
