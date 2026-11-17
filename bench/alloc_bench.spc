// std::alloc throughput against `Global` (the C heap through the leak tracker's entry points, as every
// program calls it). A round allocates BLOCKS blocks of one size and frees them in reverse order; the
// figure is per operation, an `alloc` or a `dealloc`. The arena lane bumps BLOCKS blocks and resets.
// Every lane writes one byte per block and validates the bytes (`b.tally`), so no allocation folds away.

import std::alloc;
import std::testing::bench;

const BLOCKS: usize = 4096;

// A block that `h` gave for `size` bytes, aligned to 8.
struct Held<H: Allocator>
    invariant H::owns(self.ptr, self.size, 8)
{
    ptr: *mut void,
    size: usize,
}

// One round through `h`: BLOCKS allocations of `size` bytes, then their deallocations, newest first.
fn churn<H: Allocator>(mut h: H, held: &mut Vector<Held<H>>, size: usize) i64
    requires size as int <= isize::MAX as int
    panics if true
{
    for i in 0..BLOCKS {
        let p = unsafe h.alloc(size, 8);
        unsafe *(p as *mut u8) = i as u8;
        held.push(Held::<H> { ptr: p, size: size });
    }
    let mut ok: i64 = 0;
    while let Some(b) = held.pop() {
        ok += (unsafe *(b.ptr as *mut u8) == held.len() as u8) as i64;
        unsafe h.dealloc(b.ptr, b.size, 8);
    }
    return ok;
}

fn churn_lane<H: Allocator>(b: &mut bench::Bencher, h: H, size: usize)
    requires size as int <= isize::MAX as int
    panics if true
{
    let mut held = Vector::<Held<H>>::with_capacity(BLOCKS);
    b.each(2 * BLOCKS as i64);
    b.unit("op");
    while b.running() {
        let ok = churn(h, &mut held, size);
        b.tally(BLOCKS as i64, ok);
    }
}

@bench
pub fn global_16(b: &mut bench::Bencher) {
    churn_lane(b, Global {}, 16);
}

@bench
pub fn pool_16(b: &mut bench::Bencher) {
    let p = alloc::Pool::<Global>::new();
    churn_lane(b, p.allocator(), 16);
}

@bench
pub fn global_64(b: &mut bench::Bencher) {
    churn_lane(b, Global {}, 64);
}

@bench
pub fn pool_64(b: &mut bench::Bencher) {
    let p = alloc::Pool::<Global>::new();
    churn_lane(b, p.allocator(), 64);
}

@bench
pub fn global_256(b: &mut bench::Bencher) {
    churn_lane(b, Global {}, 256);
}

@bench
pub fn pool_256(b: &mut bench::Bencher) {
    let p = alloc::Pool::<Global>::new();
    churn_lane(b, p.allocator(), 256);
}

// BLOCKS bump allocations of 64 bytes, then one reset: the arena's use pattern. The figure is per alloc.
@bench
pub fn arena_bump_64(b: &mut bench::Bencher) {
    let mut a = alloc::Arena::<Global>::new();
    b.each(BLOCKS as i64);
    b.unit("alloc");
    while b.running() {
        let mut ok: i64 = 0;
        {
            let mut h = a.allocator();
            for i in 0..BLOCKS {
                let p = (unsafe h.alloc(64, 8)) as *mut u8;
                unsafe *p = i as u8;
                ok += (unsafe *p == i as u8) as i64;
            }
        }
        a.reset();
        b.tally(BLOCKS as i64, ok);
    }
}
