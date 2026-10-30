// std::collections::deque: the growable ring `Deque` and the inline ring `RingBuffer`. Each operation is checked
// against its contract, at every head slot of the small capacities (wraparound and growth while wrapped), against a
// `Vector` reference under seeded random operations, with `String` elements under the leak check, with a counting
// allocator, with zero-sized elements, and against the written complexity bounds (allocator calls and element moves).
import std::collections::deque as *;
import std::math::random as rnd;

// What a `Counting` allocator saw; `moved` is the bytes a realloc had to keep (its old size).
struct Counts {
    pub allocs: usize,
    pub reallocs: usize,
    pub deallocs: usize,
    pub moved: usize,
}

// A stateful allocator: forwards to Global and counts through a pointer to the test's Counts.
@derive(Copy)
struct Counting {
    pub c: *mut Counts,
}

extend Counting as Allocator {
    pub unsafe fn alloc(self: &mut Counting, size: usize, align: usize) *mut void {
        (*self.c).allocs += 1;
        let mut g = Global {};
        return g.alloc(size, align);
    }

    pub unsafe fn realloc(self: &mut Counting, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        (*self.c).reallocs += 1;
        (*self.c).moved += old_size;
        let mut g = Global {};
        return g.realloc(ptr, old_size, new_size, align);
    }

    pub unsafe fn dealloc(self: &mut Counting, ptr: *mut void, size: usize, align: usize) {
        (*self.c).deallocs += 1;
        let mut g = Global {};
        g.dealloc(ptr, size, align);
    }
}

// A zero-sized element.
@derive(Eq, Clone)
struct Z {}

// A hasher that records the stream, so a test compares the bytes a value feeds.
struct Tape {
    pub bytes: Vector<u8>,
}

extend Tape as Hasher {
    pub fn write(self: &mut Tape, bytes: []u8) {
        for b in bytes {
            self.bytes.push(b);
        }
    }

    pub fn finish(self: &Tape) u64 {
        return self.bytes.len() as u64;
    }
}

const fn counts() Counts {
    return Counts { allocs: 0, reallocs: 0, deallocs: 0, moved: 0 };
}

fn tape_of<T: Hash>(v: &T) Vector<u8> {
    let mut t = Tape { bytes: Vector::<u8>::new() };
    v.hash_into(&mut t);
    return replace(&mut t.bytes, Vector::<u8>::new());
}

const fn need_send<X: Send>(_x: &X) bool {
    return true;
}

const fn need_sync<X: Sync>(_x: &X) bool {
    return true;
}

// A heap String (longer than the 23 inline bytes) that names `i`.
fn heap(i: i64) String {
    return format("element {} with a tail long enough for the heap", i);
}

// Every read path of `d` against `want`: at, get, front, back, both iteration directions with exact hints,
// and the two contiguous parts.
fn expect_seq<A: Allocator>(d: &Deque<i64, A>, want: &Vector<i64>) {
    let n = want.len();
    assert_eq(d.len(), n);
    assert_eq(d.is_empty(), n == 0);
    assert(d.capacity() >= n);
    assert(d.capacity() == 0 || d.capacity().is_power_of_two());
    for i in 0..n {
        assert_eq(*d.at(i), *want.at(i));
        assert_eq(*d.get(i).unwrap(), *want.at(i));
    }
    assert(d.get(n).is_none());
    if n > 0 {
        assert_eq(*d.front().unwrap(), *want.at(0));
        assert_eq(*d.back().unwrap(), *want.at(n - 1));
    } else {
        assert(d.front().is_none() && d.back().is_none());
    }
    let mut it = d.iter();
    let mut i: usize = 0;
    while let Some(x) = it.next() {
        assert_eq(*x, *want.at(i));
        i += 1;
        let (lo, hi) = it.size_hint();
        assert_eq(lo, n - i);
        assert_eq(hi.unwrap(), n - i);
    }
    assert_eq(i, n);
    let mut back = d.iter();
    let mut j = n;
    while let Some(x) = back.next_back() {
        j -= 1;
        assert_eq(*x, *want.at(j));
    }
    assert_eq(j, 0);
    let (a, b) = d.as_slices();
    assert_eq(a.len + b.len, n);
    for k in 0..a.len {
        assert_eq(*a.at(k), *want.at(k));
    }
    for k in 0..b.len {
        assert_eq(*b.at(k), *want.at(a.len + k));
    }
    if b.len > 0 {
        assert(a.len > 0);
    }
}

fn expect_vals<A: Allocator>(d: &Deque<i64, A>, xs: []i64) {
    let want = vec_of(xs);
    expect_seq(d, &want);
}

fn expect_iota<A: Allocator>(d: &Deque<i64, A>, n: usize) {
    let want = iota(n);
    expect_seq(d, &want);
}

fn vec_of(xs: []i64) Vector<i64> {
    let mut v = Vector::<i64>::new();
    for x in xs {
        v.push(x);
    }
    return v;
}

// A deque of capacity `cap` whose front sits in slot `head`, holding `n` values 0, 1, ..
fn ring_at(cap: usize, head: usize, n: usize) Deque<i64> {
    let mut d = Deque::<i64>::with_capacity(cap);
    for _ in 0..head {
        d.push_back(-1);
    }
    for _ in 0..head {
        let _ = d.pop_front();
    }
    for i in 0..n {
        d.push_back(i as i64);
    }
    assert_eq(d.capacity(), cap);
    return d;
}

fn iota(n: usize) Vector<i64> {
    let mut v = Vector::<i64>::new();
    for i in 0..n {
        v.push(i as i64);
    }
    return v;
}

fn rotate_left_ref(v: &mut Vector<i64>, k: usize) {
    for _ in 0..k {
        let x = v.remove(0).unwrap();
        v.push(x);
    }
}

fn rotate_right_ref(v: &mut Vector<i64>, k: usize) {
    for _ in 0..k {
        let x = v.pop().unwrap();
        v.insert(0, x);
    }
}

const fn below(rng: &mut rnd::Pcg32, n: usize) usize {
    return rng.next_u32() as usize % n;
}

const fn is_even(x: &i64) bool {
    return *x % 2 == 0;
}

const fn keeps_short(s: &String) bool {
    return s.len() % 2 == 0;
}

@test
fn new_deque_is_empty_and_allocates_nothing() {
    let mut c = counts();
    {
        let mut d = Deque::<i64, Counting>::new_in(Counting { c: &mut c });
        assert_eq(d.len(), 0);
        assert(d.is_empty());
        assert_eq(d.capacity(), 0);
        assert(d.pop_back().is_none());
        assert(d.pop_front().is_none());
        assert(d.front_mut().is_none());
        assert(d.back_mut().is_none());
        assert(d.get_mut(0).is_none());
        assert(d.remove(0).is_none());
        assert(d.swap_remove_back(0).is_none());
        assert(d.swap_remove_front(0).is_none());
        d.truncate(3);
        d.clear();
        d.shrink_to_fit();
        d.rotate_left(0);
        d.rotate_right(0);
        assert_eq(d.make_contiguous().len, 0);
        let (a, b) = d.as_mut_slices();
        assert_eq(a.len + b.len, 0);
        assert(d.iter().next().is_none());
        assert(d.iter_mut().next().is_none());
        assert(d.drain().next().is_none());
        assert(d.binary_search(&3).is_err());
        assert(!d.contains(&3));
        let empty = Vector::<i64>::new();
        expect_seq(&d, &empty);
    }
    assert_eq(c.allocs + c.reallocs + c.deallocs, 0);
}

@test
fn capacities_round_up_to_powers_of_two() {
    assert_eq(Deque::<i64>::with_capacity(0).capacity(), 0);
    assert_eq(Deque::<i64>::with_capacity(1).capacity(), 1);
    assert_eq(Deque::<i64>::with_capacity(5).capacity(), 8);
    assert_eq(Deque::<i64>::with_capacity(8).capacity(), 8);
    assert_eq(Deque::<i64>::with_capacity(9).capacity(), 16);
    let mut d = Deque::<i64>::new();
    d.push_back(1);
    assert_eq(d.capacity(), 8);
    d.reserve(8);
    assert_eq(d.capacity(), 16);
    d.reserve(15);
    assert_eq(d.capacity(), 16);
    let mut e = Deque::<i64>::new();
    e.reserve_exact(3);
    assert_eq(e.capacity(), 4);
    e.reserve_exact(4);
    assert_eq(e.capacity(), 4);
    e.push_back(1);
    e.reserve_exact(4);
    assert_eq(e.capacity(), 8);
}

@test(should_panic)
fn reserve_overflow_panics() {
    let mut d = Deque::<i64>::new();
    d.push_back(1);
    d.reserve(~(0 as usize));
}

@test(should_panic)
fn with_capacity_overflow_panics() {
    let _ = Deque::<i64>::with_capacity(~(0 as usize) / 4);
}

@test
fn ends_push_and_pop_in_queue_and_stack_order() {
    let mut d = Deque::<i64>::new();
    for i in 0..100 {
        d.push_back(i);
    }
    for i in 0..100 {
        assert_eq(d.pop_front().unwrap(), i as i64);
    }
    for i in 0..100 {
        d.push_front(i);
    }
    for i in 0..100 {
        assert_eq(d.pop_front().unwrap(), 99 - i as i64);
    }
    d.push_back(1);
    d.push_front(0);
    d.push_back(2);
    *d.front_mut().unwrap() = 10;
    *d.back_mut().unwrap() = 12;
    *d.get_mut(1).unwrap() = 11;
    let want = vec_of([10, 11, 12]);
    expect_seq(&d, &want);
    assert_eq(d.pop_back().unwrap(), 12);
    assert_eq(d.pop_back().unwrap(), 11);
    assert_eq(d.pop_back().unwrap(), 10);
    assert(d.pop_back().is_none());
}

@test(should_panic)
fn at_past_the_end_panics() {
    let mut d = Deque::<i64>::new();
    d.push_back(1);
    let _ = d.at(1);
}

@test(should_panic)
fn index_past_the_end_panics() {
    let mut d = Deque::<i64>::new();
    d.push_back(1);
    let _ = d[1];
}

@test(should_panic)
fn swap_past_the_end_panics() {
    let mut d = Deque::<i64>::new();
    d.push_back(1);
    d.swap(0, 1);
}

@test(should_panic)
fn insert_past_the_end_panics() {
    let mut d = Deque::<i64>::new();
    d.insert(1, 5);
}

@test(should_panic)
fn rotate_past_the_length_panics() {
    let mut d = Deque::<i64>::new();
    d.push_back(1);
    d.rotate_left(2);
}

@test(should_panic)
fn range_past_the_end_panics() {
    let mut d = Deque::<i64>::new();
    d.push_back(1);
    let _ = d[0..2];
}

// Every head slot of every small capacity: fill to the capacity without growth (the parts split where the ring
// wraps), then grow while wrapped. The growth moves the shorter part: the tail after the old end (one run) or
// the front part to the end of the new block (still two parts).
@test
fn wraparound_and_growth_at_every_head_slot() {
    let mut cap: usize = 1;
    while cap <= 32 {
        for head in 0..cap {
            let mut d = ring_at(cap, head, cap);
            let mut want = iota(cap);
            expect_seq(&d, &want);
            let (a, b) = d.as_slices();
            let head_len = a.len;
            let tail_len = b.len;
            assert_eq(head_len, cap - head);
            assert_eq(tail_len, head);
            d.push_back(cap as i64);
            want.push(cap as i64);
            let new_cap = if cap * 2 < 8 {
                8
            } else {
                cap * 2
            };
            assert_eq(d.capacity(), new_cap);
            expect_seq(&d, &want);
            let (a2, b2) = d.as_slices();
            if tail_len < head_len {
                assert_eq(b2.len, 0);
            } else {
                assert_eq(a2.len, head_len);
                assert_eq(b2.len, tail_len + 1);
            }
            // The same at the front end.
            let mut f = ring_at(cap, head, cap);
            f.push_front(-1);
            let mut fwant = iota(cap);
            fwant.insert(0, -1);
            expect_seq(&f, &fwant);
        }
        cap *= 2;
    }
}

// Insert and remove at every index of every layout of a small ring, against the reference.
@test
fn insert_and_remove_at_every_index_and_head() {
    for head in 0 as usize..16 {
        for n in 0 as usize..16 {
            for i in 0..n + 1 {
                let mut d = ring_at(16, head, n);
                let mut want = iota(n);
                d.insert(i, 100);
                want.insert(i, 100);
                expect_seq(&d, &want);
                let r = d.remove(i);
                let _ = want.remove(i);
                assert_eq(r.unwrap(), 100);
                expect_seq(&d, &want);
                if i < n {
                    assert_eq(d.remove(i).unwrap(), want.remove(i).unwrap());
                    expect_seq(&d, &want);
                }
            }
        }
    }
}

// The shorter side moves: the elements on the longer side keep their slots, so their addresses stay.
@test
fn insert_and_remove_move_only_the_shorter_side() {
    let mut d = ring_at(64, 60, 20);
    let mut before = Vector::<usize>::new();
    for i in 0 as usize..20 {
        before.push((d.at(i) as *const i64) as usize);
    }
    d.insert(3, 100);
    for i in 3 as usize..20 {
        assert_eq((d.at(i + 1) as *const i64) as usize, *before.at(i));
    }
    let _ = d.remove(3);
    for i in 3 as usize..20 {
        assert_eq((d.at(i) as *const i64) as usize, *before.at(i));
    }
    d.insert(17, 100);
    for i in 0 as usize..17 {
        assert_eq((d.at(i) as *const i64) as usize, *before.at(i));
    }
    let _ = d.remove(17);
    for i in 0 as usize..20 {
        assert_eq((d.at(i) as *const i64) as usize, *before.at(i));
    }
}

@test
fn swap_and_swap_remove_at_both_ends() {
    let mut d = ring_at(8, 6, 6);
    d.swap(0, 5);
    d.swap(2, 2);
    let mut want = vec_of([5, 1, 2, 3, 4, 0]);
    expect_seq(&d, &want);
    assert_eq(d.swap_remove_back(1).unwrap(), 1);
    want = vec_of([5, 0, 2, 3, 4]);
    expect_seq(&d, &want);
    assert_eq(d.swap_remove_back(4).unwrap(), 4);
    want = vec_of([5, 0, 2, 3]);
    expect_seq(&d, &want);
    assert_eq(d.swap_remove_front(2).unwrap(), 2);
    want = vec_of([0, 5, 3]);
    expect_seq(&d, &want);
    assert_eq(d.swap_remove_front(0).unwrap(), 0);
    want = vec_of([5, 3]);
    expect_seq(&d, &want);
    assert(d.swap_remove_back(2).is_none());
    assert(d.swap_remove_front(2).is_none());
}

@test
fn truncate_clear_and_retain() {
    let mut d = ring_at(16, 12, 10);
    d.truncate(20);
    expect_iota(&d, 10);
    d.truncate(7);
    expect_iota(&d, 7);
    d.retain(is_even);
    let want = vec_of([0, 2, 4, 6]);
    expect_seq(&d, &want);
    let cap = d.capacity();
    d.clear();
    assert_eq(d.len(), 0);
    assert_eq(d.capacity(), cap);
    d.push_back(1);
    expect_vals(&d, [1]);
}

// Rotate by every count at every head slot, at a free slot count of 0 (full) and of 5.
@test
fn rotations_at_every_count_and_head() {
    for full in [true, false] {
        for head in 0 as usize..16 {
            let n: usize = if full {
                16
            } else {
                11
            };
            for k in 0..n + 1 {
                let mut d = ring_at(16, head, n);
                let mut want = iota(n);
                d.rotate_left(k);
                rotate_left_ref(&mut want, k);
                expect_seq(&d, &want);
                d.rotate_right(k);
                rotate_right_ref(&mut want, k);
                expect_seq(&d, &want);
                d.rotate_right(k);
                rotate_right_ref(&mut want, k);
                expect_seq(&d, &want);
                assert_eq(d.capacity(), 16);
            }
        }
    }
}

@test
fn append_moves_every_element_and_empties_the_source() {
    for h1 in [0 as usize, 5, 7] {
        for h2 in [0 as usize, 3, 7] {
            let mut a = ring_at(8, h1, 6);
            let mut b = ring_at(8, h2, 5);
            a.append(&mut b);
            let mut want = iota(6);
            for i in 0..5 {
                want.push(i);
            }
            expect_seq(&a, &want);
            assert_eq(b.len(), 0);
            assert_eq(b.capacity(), 8);
            b.push_back(9);
            expect_vals(&b, [9]);
        }
    }
    let mut s = Deque::<String>::new();
    let mut t = Deque::<String>::new();
    for i in 0..10 {
        s.push_front(heap(i));
        t.push_front(heap(i + 10));
    }
    s.append(&mut t);
    assert_eq(s.len(), 20);
    assert(*s.at(10) == heap(19));
    assert(t.is_empty());
}

// make_contiguous at every head slot and length of a ring of 8: all four layouts (enough free slots for the
// front part, for the tail, or for neither with either part shorter) plus the unwrapped ones.
@test
fn make_contiguous_at_every_layout() {
    for head in 0 as usize..8 {
        for n in 0 as usize..9 {
            let mut d = ring_at(8, head, n);
            let s = d.make_contiguous();
            assert_eq(s.len, n);
            for i in 0..n {
                assert_eq(*s.at(i), i as i64);
            }
            let (_, b) = d.as_slices();
            assert_eq(b.len, 0);
            expect_iota(&d, n);
            assert_eq(d.capacity(), 8);
        }
    }
}

@test
fn mutable_views_write_in_place() {
    let mut d = ring_at(8, 6, 5);
    {
        let (a, b) = d.as_mut_slices();
        assert_eq(a.len, 2);
        assert_eq(b.len, 3);
        a.set(0, 10);
        b.set(2, 14);
    }
    for x in d.iter_mut() {
        *x += 1;
    }
    expect_vals(&d, [11, 2, 3, 4, 15]);
    let mut it = d.iter_mut();
    *it.next_back().unwrap() = 0;
    *it.next().unwrap() = 0;
    let (lo, _) = it.size_hint();
    assert_eq(lo, 3);
    expect_vals(&d, [0, 2, 3, 4, 0]);
    d[2] = 30;
    assert_eq(d[2], 30);
    {
        let (x, y) = d[1..5];
        assert_eq(x.len, 1);
        assert_eq(y.len, 3);
        assert_eq(*x.at(0), 2);
        assert_eq(*y.at(2), 0);
    }
    let (p, q) = d[0..=1];
    assert_eq(p.len + q.len, 2);
    let (u, v) = d[3..];
    assert_eq(u.len + v.len, 2);
    {
        let parts = &mut d[0..5];
        parts.0.set(1, 21);
        parts.1.set(0, 22);
    }
    expect_vals(&d, [0, 21, 22, 4, 0]);
}

@test
fn iterators_meet_in_the_middle() {
    let d = ring_at(8, 5, 7);
    let mut it = d.iter();
    assert_eq(*it.next().unwrap(), 0);
    assert_eq(*it.next_back().unwrap(), 6);
    assert_eq(*it.next().unwrap(), 1);
    assert_eq(*it.next_back().unwrap(), 5);
    let (lo, hi) = it.size_hint();
    assert_eq(lo, 3);
    assert_eq(hi.unwrap(), 3);
    assert_eq(*it.next().unwrap(), 2);
    assert_eq(*it.next().unwrap(), 3);
    assert_eq(*it.next_back().unwrap(), 4);
    assert(it.next().is_none());
    assert(it.next_back().is_none());
    // A borrow from `next` outlives the next call: the items borrow the deque, not the iterator.
    let mut j = d.iter();
    let first = j.next().unwrap();
    let second = j.next().unwrap();
    assert_eq(*first + *second, 1);
}

@test
fn drain_moves_out_and_keeps_the_block() {
    let mut c = counts();
    {
        let mut d = Deque::<String, Counting>::new_in(Counting { c: &mut c });
        for i in 0..12 {
            d.push_front(heap(i));
        }
        {
            let mut dr = d.drain();
            let (lo, _) = dr.size_hint();
            assert_eq(lo, 12);
            assert(dr.next().unwrap() == heap(11));
            assert(dr.next_back().unwrap() == heap(0));
            assert(dr.next().unwrap() == heap(10));
            // The 9 elements left are freed with the drain.
        }
        assert_eq(d.len(), 0);
        assert_eq(d.capacity(), 16);
        d.push_back(heap(1));
        let mut n = 0;
        for s in d.drain() {
            assert(s == heap(1));
            n += 1;
        }
        assert_eq(n, 1);
        assert(d.is_empty());
    }
    assert_eq(c.allocs, 1);
    assert_eq(c.deallocs, 1);
}

@test
fn binary_search_and_contains_over_the_wrap() {
    let mut d = Deque::<i64>::with_capacity(16);
    for i in 0..8 {
        d.push_back(i * 2 + 20);
    }
    for i in 0..8 {
        d.push_front(18 - i * 2);
    }
    // 4, 6, .., 34 across the wrap.
    for i in 0..16 {
        let hit: i64 = 4 + i * 2;
        let miss: i64 = hit - 1;
        assert_eq(d.binary_search(&hit).unwrap(), i as usize);
        assert_eq(d.binary_search(&miss).unwrap_err(), i as usize);
        assert(d.contains(&hit));
        assert(!d.contains(&miss));
    }
    assert_eq(d.binary_search(&99).unwrap_err(), 16);
    let mut w = Deque::<String>::with_capacity(4);
    w.push_back(String::from_str("pear but long enough to live on the heap"));
    w.push_front(String::from_str("apple but long enough to live on the heap"));
    w.push_back(String::from_str("quince but long enough to live on the heap"));
    let key = String::from_str("pear but long enough to live on the heap");
    assert_eq(w.binary_search(&key).unwrap(), 1);
    assert(w.contains(&key));
}

@test
fn conformances_follow_the_logical_order() {
    let a = ring_at(8, 6, 5);
    let b = ring_at(8, 0, 5);
    let mut c = ring_at(16, 3, 5);
    assert(a == b);
    assert(a == c);
    assert_eq(hash(&a), hash(&b));
    assert_eq(hash(&a), hash(&c));
    let v = vec_of([0, 1, 2, 3, 4]);
    assert_eq(hash(&a), hash(&v));
    assert(tape_of(&a) == tape_of(&c));
    let v5 = vec_of([0, 1, 2, 3, 4]);
    assert(tape_of(&a) == tape_of(&v5));
    let _ = c.pop_back();
    assert(a != c);
    assert(hash(&a) != hash(&c));
    c.push_back(5);
    assert(a != c);
    assert(a.fmt() == String::from_str("[0, 1, 2, 3, 4]"));
    assert(Deque::<i64>::new().fmt() == String::from_str("[]"));
    let k = a.clone();
    assert(k == a);
    let (_, kb) = k.as_slices();
    assert_eq(kb.len, 0);
    let dflt: Deque<i64> = Deque::<i64>::default();
    assert(dflt.is_empty());
    let f = Deque::<i64>::from([0, 1, 2, 3, 4]);
    assert(f == a);
    let src: [i64; 2] = [7, 8];
    let g: Deque<i64> = src.into();
    expect_vals(&g, [7, 8]);
    assert(need_send(&a));
    assert(need_sync(&a));
}

@test
fn string_elements_free_on_every_path() {
    let mut d = Deque::<String>::with_capacity(8);
    for i in 0..6 {
        d.push_back(heap(i));
    }
    for _ in 0..5 {
        let _ = d.pop_front();
    }
    for i in 6..13 {
        d.push_back(heap(i));
    }
    // Wrapped: 5 .. 12 in slots 5..7 then 0..4.
    d.truncate(6);
    assert(*d.back().unwrap() == heap(10));
    d.retain(keeps_short);
    d.insert(1, heap(100));
    d.push_front(heap(101));
    let _ = d.remove(2);
    let _ = d.swap_remove_back(0);
    let _ = d.swap_remove_front(1);
    d[0] = heap(102);
    let k = d.clone();
    assert(k == d);
    d.rotate_left(1);
    d.make_contiguous();
    d.shrink_to_fit();
    for i in 0..20 {
        d.push_front(heap(i));
    }
    d.clear();
    for i in 0..9 {
        d.push_back(heap(i));
        d.push_front(heap(i));
    }
    // Dropped while wrapped.
    let (_, b) = d.as_slices();
    assert(b.len > 0);
}

@test
fn stateful_allocator_gets_every_block_back() {
    let mut c = counts();
    {
        let a = Counting { c: &mut c };
        let mut d = Deque::<String, Counting>::with_capacity_in(a, 4);
        assert_eq(c.allocs, 1);
        for i in 0..40 {
            d.push_back(heap(i));
        }
        assert_eq(d.capacity(), 64);
        assert_eq(c.reallocs, 4);
        let k = d.clone();
        assert_eq(c.allocs, 2);
        assert(k == d);
        d.truncate(3);
        d.shrink_to_fit();
        assert_eq(d.capacity(), 4);
        assert_eq(c.reallocs, 5);
        d.clear();
        d.shrink_to_fit();
        assert_eq(d.capacity(), 0);
        assert_eq(c.deallocs, 1);
        d.push_back(heap(0));
        assert_eq(c.allocs, 3);
        let mut z = Deque::<i64, Counting>::new_in(a);
        z.reserve_exact(5);
        assert_eq(c.allocs, 4);
    }
    assert_eq(c.allocs, 4);
    assert_eq(c.deallocs, 4);
}

// The written bounds: n pushes at both ends take O(log n) allocator calls and O(n) element moves (amortized
// constant), counted as the bytes each realloc keeps plus the shorter part each growth moves.
@test
fn pushes_stay_within_the_complexity_bounds() {
    let n: usize = 1 << 14;
    let mut c = counts();
    let mut fixup: usize = 0;
    let mut growths: usize = 0;
    {
        let mut d = Deque::<i64, Counting>::new_in(Counting { c: &mut c });
        for i in 0..n {
            if d.len() == d.capacity() && d.len() > 0 {
                let (a, b) = d.as_slices();
                fixup += a.len.min(b.len);
                growths += 1;
            }
            if i % 3 == 0 {
                d.push_front(i as i64);
            } else {
                d.push_back(i as i64);
            }
        }
        assert_eq(d.len(), n);
        // 8, 16, .., n: one alloc and log2(n / 8) reallocs.
        assert_eq(c.allocs, 1);
        assert_eq(c.reallocs, 11);
        assert_eq(growths, 11);
        let moves = c.moved / sizeof(i64) + fixup;
        assert(moves <= 2 * n);
        assert(fixup <= n / 2);
    }
    assert_eq(c.deallocs, 1);
}

// At full capacity a push at one end after a pop at the other reuses the freed slot: no allocator call.
@test
fn alternating_ends_at_full_capacity_never_reallocate() {
    let mut c = counts();
    {
        let mut d = Deque::<i64, Counting>::with_capacity_in(Counting { c: &mut c }, 64);
        for i in 0..64 {
            d.push_back(i);
        }
        for i in 0..10000 {
            let x = d.pop_back().unwrap();
            d.push_front(x + i);
            let y = d.pop_front().unwrap();
            d.push_back(y);
            assert_eq(d.len(), 64);
        }
        assert_eq(d.capacity(), 64);
        assert_eq(c.allocs, 1);
        assert_eq(c.reallocs, 0);
    }
    assert_eq(c.deallocs, 1);
}

@test
fn zero_sized_elements_never_allocate() {
    let mut c = counts();
    {
        let mut d = Deque::<Z, Counting>::new_in(Counting { c: &mut c });
        assert_eq(d.capacity(), 1 as usize << sizeof(usize) * 8 - 1);
        for _ in 0..1000 {
            d.push_back(Z {});
            d.push_front(Z {});
        }
        d.insert(7, Z {});
        assert_eq(d.len(), 2001);
        assert(d.remove(3).is_some());
        d.rotate_left(5);
        d.make_contiguous();
        d.shrink_to_fit();
        let mut n: usize = 0;
        for _ in d.iter() {
            n += 1;
        }
        assert_eq(n, 2000);
        assert(d.contains(&Z {}));
        let k = d.clone();
        assert(k == d);
        let mut m = 0;
        while d.pop_front().is_some() {
            m += 1;
        }
        assert_eq(m, 2000);
    }
    assert_eq(c.allocs + c.reallocs + c.deallocs, 0);
}

// Seeded random operations on a Deque and on a Vector reference; every read path is compared after each one.
@test
fn random_operations_match_a_vector() {
    let mut rng = rnd::Pcg32::new(42, 54);
    let mut d = Deque::<i64>::new();
    let mut want = Vector::<i64>::new();
    let mut next: i64 = 0;
    for _ in 0..3000 {
        let n = want.len();
        let op = below(&mut rng, 20);
        next += 1;
        switch op {
            0 | 1 | 2 => {
                d.push_back(next);
                want.push(next);
            },
            3 | 4 | 5 => {
                d.push_front(next);
                want.insert(0, next);
            },
            6 => {
                let a = d.pop_back();
                let b = want.pop();
                assert(a == b);
            },
            7 => {
                let a = d.pop_front();
                let b = if n == 0 {
                    Option::<i64>::None
                } else {
                    want.remove(0)
                };
                assert(a == b);
            },
            8 => {
                let i = below(&mut rng, n + 1);
                d.insert(i, next);
                want.insert(i, next);
            },
            9 => {
                let i = below(&mut rng, n + 1);
                assert(d.remove(i) == want.remove(i));
            },
            10 => {
                if n > 0 {
                    let i = below(&mut rng, n);
                    let j = below(&mut rng, n);
                    d.swap(i, j);
                    want.swap(i, j);
                }
            },
            11 => {
                let i = below(&mut rng, n + 1);
                assert(d.swap_remove_back(i) == want.swap_remove(i));
            },
            12 => {
                let i = below(&mut rng, n + 1);
                let a = d.swap_remove_front(i);
                if i < n {
                    let x = *want.at(i);
                    let f = *want.at(0);
                    want.set(i, f);
                    let _ = want.remove(0);
                    assert_eq(a.unwrap(), x);
                } else {
                    assert(a.is_none());
                }
            },
            13 => {
                let k = below(&mut rng, n + 1);
                if below(&mut rng, 2) == 0 {
                    d.rotate_left(k);
                    rotate_left_ref(&mut want, k);
                } else {
                    d.rotate_right(k);
                    rotate_right_ref(&mut want, k);
                }
            },
            14 => {
                if n > 0 {
                    let i = below(&mut rng, n);
                    *d.get_mut(i).unwrap() = next;
                    want.set(i, next);
                }
            },
            15 => {
                let s = d.make_contiguous();
                assert_eq(s.len, n);
            },
            16 => {
                let k = below(&mut rng, 6);
                let mut o = Deque::<i64>::new();
                for j in 0..k {
                    o.push_front(next + j as i64);
                    want.push(next + (k - 1 - j) as i64);
                }
                d.append(&mut o);
            },
            17 => {
                if below(&mut rng, 4) == 0 {
                    let t = below(&mut rng, n + 1);
                    d.truncate(t);
                    want.truncate(t);
                } else {
                    d.reserve(below(&mut rng, 40));
                }
            },
            18 => {
                if below(&mut rng, 8) == 0 {
                    d.retain(is_even);
                    want.retain(is_even);
                } else {
                    d.shrink_to_fit();
                }
            },
            _ => {
                if below(&mut rng, 30) == 0 {
                    d.clear();
                    want.clear();
                }
            },
        }
        expect_seq(&d, &want);
    }
}

// RingBuffer: a full ring gives the value back, the overwriting push hands out the front, every head slot.
@test
fn ring_buffer_ends_and_full_ring() {
    let mut r = RingBuffer::<String, 4>::new();
    assert_eq(r.capacity(), 4);
    assert(r.is_empty());
    assert(r.pop_front().is_none());
    assert(r.pop_back().is_none());
    assert(r.front().is_none() && r.back().is_none());
    assert(r.push_back(heap(1)).is_ok());
    assert(r.push_front(heap(0)).is_ok());
    assert(r.push_back(heap(2)).is_ok());
    assert(r.push_back(heap(3)).is_ok());
    assert(r.is_full());
    let back = r.push_back(heap(4));
    assert(back.unwrap_err() == heap(4));
    assert(r.push_front(heap(5)).unwrap_err() == heap(5));
    assert(r.push_back_overwrite(heap(4)).unwrap() == heap(0));
    assert(r.push_back_overwrite(heap(5)).unwrap() == heap(1));
    assert(*r.front().unwrap() == heap(2));
    assert(*r.back().unwrap() == heap(5));
    assert(*r.get(1).unwrap() == heap(3));
    assert(r.get(4).is_none());
    assert(r.pop_back().unwrap() == heap(5));
    assert(r.push_back_overwrite(heap(6)).is_none());
    assert(r.pop_front().unwrap() == heap(2));
    assert_eq(r.len(), 3);
    r.clear();
    assert(r.is_empty());
    assert(r.push_back(heap(7)).is_ok());
}

@test
fn ring_buffer_at_every_head_slot() {
    for head in 0 as usize..8 {
        for n in 0 as usize..9 {
            let mut r = RingBuffer::<i64, 8>::new();
            for _ in 0..head {
                assert(r.push_back(-1).is_ok());
                let _ = r.pop_front();
            }
            for i in 0..n {
                assert(r.push_back(i as i64).is_ok());
            }
            assert_eq(r.len(), n);
            assert_eq(r.is_full(), n == 8);
            let mut i: usize = 0;
            for x in r.iter() {
                assert_eq(*x, i as i64);
                assert_eq(r[i], i as i64);
                i += 1;
            }
            assert_eq(i, n);
            let mut it = r.iter();
            let mut j = n;
            while let Some(x) = it.next_back() {
                j -= 1;
                assert_eq(*x, j as i64);
                let (lo, _) = it.size_hint();
                assert_eq(lo, j);
            }
            let (a, b) = r[0..n];
            assert_eq(a.len, n.min(8 - head));
            assert_eq(a.len + b.len, n);
            if n > 0 {
                r[n - 1] = 100;
                assert_eq(*r.back().unwrap(), 100);
                let parts = &mut r[0..n];
                parts.0.set(0, 50);
                assert_eq(*r.front().unwrap(), 50);
            }
        }
    }
}

@test
fn ring_buffer_conformances() {
    let mut a = RingBuffer::<i64, 4>::new();
    for i in 0..6 {
        let _ = a.push_back_overwrite(i);
    }
    // 2, 3, 4, 5 with the front in slot 2.
    let b = RingBuffer::<i64, 4>::from([2, 3, 4, 5]);
    assert(a == b);
    assert_eq(hash(&a), hash(&b));
    let v = vec_of([2, 3, 4, 5]);
    assert_eq(hash(&a), hash(&v));
    assert(tape_of(&a) == tape_of(&b));
    assert(a.fmt() == String::from_str("[2, 3, 4, 5]"));
    assert(RingBuffer::<i64, 2>::default().fmt() == String::from_str("[]"));
    let k = a.clone();
    assert(k == a);
    let _ = a.pop_front();
    assert(a != b);
    let nine: [i64; 1] = [9];
    let one: RingBuffer<i64, 1> = nine.into();
    assert_eq(*one.front().unwrap(), 9);
    assert(need_send(&a));
    assert(need_sync(&a));
    let mut s = RingBuffer::<String, 2>::new();
    let _ = s.push_back(heap(1));
    let _ = s.push_front(heap(0));
    let t = s.clone();
    assert(t == s);
    assert(s.fmt() == format("[{}, {}]", heap(0), heap(1)));
    s[1] = heap(3);
    assert(*s.back().unwrap() == heap(3));
}

@test(should_panic)
fn ring_buffer_from_a_longer_slice_panics() {
    let _ = RingBuffer::<i64, 2>::from([1, 2, 3]);
}

@test(should_panic)
fn ring_buffer_index_past_the_end_panics() {
    let mut r = RingBuffer::<i64, 4>::new();
    let _ = r.push_back(1);
    let _ = r[1];
}

// Seeded random operations on a RingBuffer and a Vector reference bounded at the capacity.
@test
fn ring_buffer_random_operations_match_a_vector() {
    let mut rng = rnd::Pcg32::new(7, 11);
    let mut r = RingBuffer::<i64, 16>::new();
    let mut want = Vector::<i64>::new();
    for step in 0..4000 {
        let v = step as i64;
        switch below(&mut rng, 6) {
            0 => {
                let res = r.push_back(v);
                if want.len() == 16 {
                    assert_eq(res.unwrap_err(), v);
                } else {
                    assert(res.is_ok());
                    want.push(v);
                }
            },
            1 => {
                let res = r.push_front(v);
                if want.len() == 16 {
                    assert_eq(res.unwrap_err(), v);
                } else {
                    assert(res.is_ok());
                    want.insert(0, v);
                }
            },
            2 => {
                let old = r.push_back_overwrite(v);
                if want.len() == 16 {
                    assert(old == want.remove(0));
                } else {
                    assert(old.is_none());
                }
                want.push(v);
            },
            3 => {
                assert(r.pop_back() == want.pop());
            },
            4 => {
                let b = if want.is_empty() {
                    Option::<i64>::None
                } else {
                    want.remove(0)
                };
                assert(r.pop_front() == b);
            },
            _ => {
                if below(&mut rng, 20) == 0 {
                    r.clear();
                    want.clear();
                }
            },
        }
        assert_eq(r.len(), want.len());
        let mut i: usize = 0;
        for x in r.iter() {
            assert_eq(*x, *want.at(i));
            assert_eq(*r.get(i).unwrap(), *want.at(i));
            i += 1;
        }
    }
}
