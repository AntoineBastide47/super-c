// std::collections::heap: BinaryHeap order and ownership, the PeekMut guard, Reverse as a min-heap, a
// stateful allocator, and the comparison bounds of C++ [alg.heap.operations].

import std::collections::heap as heap;
import std::math::random as random;

@test
fn pops_come_out_largest_first() {
    let mut rng = random::Pcg32::new(1, 2);
    let mut h = heap::BinaryHeap::<u32>::new();
    let mut all = Vector::<u32>::new();
    for _ in 0..1000 {
        let x = rng.next_u32() % 500;
        h.push(x);
        all.push(x);
    }
    assert_eq(h.len(), 1000);
    assert(h.as_slice().is_heap());
    all.sort();
    let mut i = all.len();
    while let Some(x) = h.pop() {
        i -= 1;
        assert_eq(x, *all.at(i));
    }
    assert_eq(i, 0);
    assert(h.pop().is_none());
    assert(h.peek().is_none());
}

@test
fn reverse_makes_a_min_heap() {
    let mut h = heap::BinaryHeap::<heap::Reverse<i64>>::new();
    for x in [5, 1, 9, 3, 7] {
        h.push(heap::Reverse::<i64> { v: x });
    }
    assert_eq(h.peek().unwrap().v, 1);
    let mut last: i64 = -1;
    while let Some(r) = h.pop() {
        assert(r.v > last);
        last = r.v;
    }
}

@test
fn peek_mut_restores_the_order_on_drop() {
    let mut h: heap::BinaryHeap<i64> = [4i64, 8, 2, 6].into();
    {
        let mut top = h.peek_mut().unwrap();
        assert_eq(*top, 8);
        *top = 1;
    }
    assert(h.as_slice().is_heap());
    assert_eq(*h.peek().unwrap(), 6);
    let top = h.peek_mut().unwrap();
    assert_eq(top.pop(), 6);
    assert_eq(h.len(), 3);
}

fn word(i: i64) String {
    let mut s = String::from_str("w");
    s.push_i64(i);
    return s;
}

@test
fn owned_elements_are_freed_exactly_once() {
    let mut h = heap::BinaryHeap::<String>::new();
    for i in 0..300 {
        h.push(word(i * 37 % 300));
    }
    let mut other = heap::BinaryHeap::<String>::new();
    for i in 0..10 {
        other.push(word(1000 + i));
    }
    h.append(&mut other);
    assert(other.is_empty());
    h.retain(|s: &String| s.len() > 2);
    assert(h.as_slice().is_heap());
    let c = h.clone();
    let sorted = c.into_sorted_vector();
    assert(sorted.as_slice().is_sorted());
    assert_eq(sorted.len(), h.len());
    let mut n: usize = 0;
    for _ in h.iter() {
        n += 1;
    }
    assert_eq(n, sorted.len());
    let _ = h.pop();
    h.clear();
    assert(h.is_empty());
}

struct Counts {
    pub live: i64,
}

@derive(Copy)
struct Counting {
    pub c: *mut Counts,
}

extend Counting as Allocator {
    pub unsafe fn alloc(self: &mut Counting, size: usize, align: usize) *mut void {
        unsafe (*self.c).live += 1;
        let mut g = Global {};
        return unsafe g.alloc(size, align);
    }
    pub unsafe fn realloc(self: &mut Counting, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        if ptr == null {
            unsafe (*self.c).live += 1;
        }
        let mut g = Global {};
        return unsafe g.realloc(ptr, old_size, new_size, align);
    }
    pub unsafe fn dealloc(self: &mut Counting, ptr: *mut void, size: usize, align: usize) {
        if ptr != null {
            unsafe (*self.c).live -= 1;
        }
        let mut g = Global {};
        unsafe g.dealloc(ptr, size, align);
    }
}

@test
fn the_buffer_comes_from_the_given_allocator() {
    let mut counts = Counts { live: 0 };
    let cp = (&mut counts) as *mut Counts;
    {
        let mut h = heap::BinaryHeap::<String, Counting>::new_in(Counting { c: cp });
        for i in 0..100 {
            h.push(word(i));
        }
        assert(unsafe (*cp).live > 0);
        let v = h.into_sorted_vector();
        assert_eq(v.len(), 100);
    }
    assert_eq(counts.live, 0);
}

// An i64 that counts its comparisons.
static mut CMPS: u64 = 0;

struct Key {
    pub v: i64,
}

extend Key as Eq {
    pub fn eq(self: &Key, other: &Key) bool {
        return self.v == other.v;
    }
}

extend Key as Ord {
    pub fn cmp(self: &Key, other: &Key) i32 {
        unsafe CMPS += 1;
        return self.v.cmp(&other.v);
    }
}

@test
fn operations_meet_the_comparison_bounds() {
    let n: usize = 1 << 14;
    let lg: u64 = 14;
    let mut rng = random::Pcg32::new(8, 8);
    let mut v = Vector::<Key>::new();
    for _ in 0..n {
        v.push(Key { v: rng.next_u32() % 1000 });
    }
    unsafe CMPS = 0;
    let mut h = heap::BinaryHeap::<Key>::from_vector(v);
    // make_heap: at most 3n comparisons.
    assert(unsafe CMPS <= 3 * n as u64);
    unsafe CMPS = 0;
    for i in 0..n {
        h.push(Key { v: i as i64 });
    }
    // push_heap: at most log2(n) comparisons each.
    assert(unsafe CMPS <= n as u64 * (lg + 1));
    unsafe CMPS = 0;
    while h.pop().is_some() {}
    // pop_heap: at most 2 log2(n) comparisons each.
    assert(unsafe CMPS <= 2 * n as u64 * 2 * (lg + 1));
}
