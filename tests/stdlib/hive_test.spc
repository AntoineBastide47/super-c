// std::collections::hive: the stable-address container `Hive`. Each operation is checked against its contract:
// addresses that never change, removed slots reused before new ones, iteration over every pattern of removed
// ranges of a three-block hive (whole blocks, first and last slots, every order of removal), the drop count of
// every element, a counting allocator, and seeded random operations against a Vector model for a narrow
// (u8 skipfield), a wide (u16 skipfield) and a zero-sized element type.
import std::collections::hive as *;
import std::math::random as rnd;

// What a `Counting` allocator saw.
struct Counts {
    pub allocs: usize,
    pub deallocs: usize,
    pub live_bytes: usize,
}

// A stateful allocator: forwards to Global and counts through a pointer to the test's Counts.
@derive(Copy)
struct Counting {
    pub c: *mut Counts,
}

extend Counting as Allocator {
    pub unsafe fn alloc(self: &mut Counting, size: usize, align: usize) *mut void {
        (*self.c).allocs += 1;
        (*self.c).live_bytes += size;
        let mut g = Global {};
        return g.alloc(size, align);
    }

    pub unsafe fn realloc(self: &mut Counting, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        panic("Hive never reallocates a block");
    }

    pub unsafe fn dealloc(self: &mut Counting, ptr: *mut void, size: usize, align: usize) {
        (*self.c).deallocs += 1;
        (*self.c).live_bytes -= size;
        let mut g = Global {};
        g.dealloc(ptr, size, align);
    }
}

// An element that counts its drops through a pointer to the test's counter.
struct Tracked {
    pub id: i64,
    pub drops: *mut usize,
}

extend Tracked as Free {
    pub fn free(self: &mut Tracked) {
        unsafe *self.drops += 1;
    }
}

// An element of 24 bytes: its slot takes u16 skipfield entries and blocks of up to 8192 slots.
struct Wide {
    pub v: i64,
    pub pad: [u64; 2],
}

// A zero-sized element.
@derive(Eq)
struct Z {}

// The element types of the model test: each stores an i64 it is made from.
interface Probe {
    fn make(v: i64) Self;
    fn val(self: &Self) i64;
}

extend i64 as Probe {
    pub fn make(v: i64) i64 {
        return v;
    }

    pub fn val(self: &i64) i64 {
        return *self;
    }
}

extend Wide as Probe {
    pub fn make(v: i64) Wide {
        return Wide { v: v, pad: [v as u64, ~(v as u64)] };
    }

    pub fn val(self: &Wide) i64 {
        assert_eq(self.pad[0], self.v as u64);
        assert_eq(self.pad[1], ~(self.v as u64));
        return self.v;
    }
}

extend u8 as Probe {
    pub fn make(v: i64) u8 {
        return v as u8;
    }

    pub fn val(self: &u8) i64 {
        return *self;
    }
}

const fn counts() Counts {
    return Counts { allocs: 0, deallocs: 0, live_bytes: 0 };
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

const fn below(rng: &mut rnd::Pcg32, n: usize) usize {
    return rng.next_u32() as usize % n;
}

const fn is_even(x: &i64) bool {
    return *x % 2 == 0;
}

const fn addr<T, A: Allocator>(h: &Hive<T, A>, k: HiveHandle<T>) usize {
    return ((unsafe h.get(k)) as *const T) as usize;
}

// The live elements of `h` are exactly `want` (any order): the iteration, its exact size hints and `len`.
fn expect_elems<T: Probe, A: Allocator>(h: &Hive<T, A>, want: &Vector<i64>) {
    let n = want.len();
    assert_eq(h.len(), n);
    assert_eq(h.is_empty(), n == 0);
    assert(h.capacity() >= n);
    let mut got = Vector::<i64>::new();
    let mut it = h.iter();
    let mut left = n;
    while let Some(x) = it.next() {
        got.push(x.val());
        left -= 1;
        let (lo, hi) = it.size_hint();
        assert_eq(lo, left);
        assert_eq(hi.unwrap(), left);
    }
    assert(it.next().is_none());
    got.sort();
    let mut w = want.clone();
    w.sort();
    assert(got == w);
}

// A hive of the values 0..n inserted in order, and their handles.
fn filled(n: usize) (Hive<i64>, Vector<HiveHandle<i64>>) {
    let mut h = Hive::<i64>::new();
    let mut hs = Vector::<HiveHandle<i64>>::new();
    for i in 0..n {
        hs.push(h.insert(i as i64));
    }
    return h, hs;
}

@test
fn new_hive_is_empty_and_allocates_nothing() {
    let mut c = counts();
    {
        let mut h = Hive::<i64, Counting>::new_in(Counting { c: &mut c });
        assert_eq(h.len(), 0);
        assert(h.is_empty());
        assert_eq(h.capacity(), 0);
        assert(h.iter().next().is_none());
        assert(h.iter_mut().next().is_none());
        h.retain(is_even);
        h.clear();
        h.reserve(0);
        h.trim_capacity();
        let empty = Vector::<i64>::new();
        expect_elems(&h, &empty);
        let d: Hive<i64> = Hive::<i64>::default();
        assert(d.is_empty());
    }
    assert_eq(c.allocs + c.deallocs, 0);
}

// Every element keeps its address while the hive grows by many blocks and while other elements leave.
@test
fn addresses_stay_across_growth_and_removal() {
    let n: usize = 20000;
    let (mut h, hs) = filled(n);
    let mut at = Vector::<usize>::new();
    for i in 0..n {
        at.push(addr(&h, *hs.at(i)));
    }
    for i in 0..n {
        assert_eq(unsafe *h.get(*hs.at(i)), i as i64);
    }
    for i in 0..n {
        if i % 3 != 0 {
            assert_eq(unsafe h.remove(*hs.at(i)), i as i64);
        }
    }
    for i in 0..n * 2 {
        let _ = h.insert(-1);
        if i % 1000 == 0 {
            for j in 0..n / 3 {
                let k = *hs.at(j * 3);
                assert_eq(addr(&h, k), *at.at(j * 3));
            }
        }
    }
    for j in 0..n / 3 + 1 {
        let k = *hs.at(j * 3);
        assert_eq(unsafe *h.get(k), (j * 3) as i64);
        assert_eq(addr(&h, k), *at.at(j * 3));
    }
    unsafe *h.get_mut(*hs.at(0)) = 77;
    assert_eq(unsafe *h.get(*hs.at(0)), 77);
}

// After removals, the next inserts fill the removed slots, most recent skipblock first, before any new slot.
@test
fn removed_slots_are_reused_before_new_ones() {
    let mut c = counts();
    {
        let mut h = Hive::<i64, Counting>::new_in(Counting { c: &mut c });
        let mut hs = Vector::<HiveHandle<i64>>::new();
        for i in 0..1000 {
            hs.push(h.insert(i));
        }
        let cap = h.capacity();
        let allocs = c.allocs;
        let mut freed = Vector::<usize>::new();
        for i in 0 as usize..1000 {
            if i % 7 == 2 || i >= 400 && i < 700 {
                freed.push(addr(&h, *hs.at(i)));
                let _ = unsafe h.remove(*hs.at(i));
            }
        }
        let removed = freed.len();
        let mut reused = Vector::<usize>::new();
        for i in 0..removed {
            let k = h.insert(5000 + i as i64);
            reused.push(addr(&h, k));
        }
        assert_eq(h.capacity(), cap);
        assert_eq(c.allocs, allocs);
        freed.sort();
        reused.sort();
        assert(freed == reused);
        assert_eq(h.len(), 1000);
    }
    assert_eq(c.allocs, c.deallocs);
}

// Remove every range [a, b) of a hive of 100 elements (blocks of 32, 32 and 64 slots), in four orders that
// make each kind of skipfield update (a new skipblock, a growth to the left, to the right, a merge), then
// iterate, insert into the removed slots and iterate again.
@test
fn iteration_skips_every_removed_range() {
    let n: usize = 100;
    for a in 0..n + 1 {
        for b in a..n + 1 {
            for order in 0 as usize..4 {
                let (mut h, hs) = filled(n);
                let cap = h.capacity();
                let mut want = Vector::<i64>::new();
                for i in 0..a {
                    want.push(i as i64);
                }
                for i in b..n {
                    want.push(i as i64);
                }
                let k = b - a;
                for j in 0..k {
                    let i = switch order {
                        0 => a + j,
                        1 => b - 1 - j,
                        2 => if j < (k + 1) / 2 {
                            a + 2 * j;
                        } else {
                            a + 2 * (j - (k + 1) / 2) + 1;
                        },
                        _ => if j % 2 == 0 {
                            a + j / 2;
                        } else {
                            b - 1 - j / 2;
                        },
                    };
                    assert_eq(unsafe h.remove(*hs.at(i)), i as i64);
                }
                expect_elems(&h, &want);
                assert_eq(h.capacity(), cap);
                // Half the slots back: the skipblocks shrink from their front. Then remove both neighbors of
                // the range (next to an end of a skipblock) and the last slot filled (next to the new front).
                let half = k / 2;
                let mut back = Vector::<HiveHandle<i64>>::new();
                for j in 0..half {
                    back.push(h.insert(1000 + j as i64));
                    want.push(1000 + j as i64);
                }
                expect_elems(&h, &want);
                if b < n {
                    assert_eq(unsafe h.remove(*hs.at(b)), b as i64);
                    drop_val(&mut want, b as i64);
                    expect_elems(&h, &want);
                }
                if a > 0 {
                    assert_eq(unsafe h.remove(*hs.at(a - 1)), (a - 1) as i64);
                    drop_val(&mut want, (a - 1) as i64);
                    expect_elems(&h, &want);
                }
                if half > 0 {
                    let v = unsafe h.remove(*back.at(half - 1));
                    assert_eq(v, 1000 + (half - 1) as i64);
                    drop_val(&mut want, v);
                    expect_elems(&h, &want);
                }
                let room = n - h.len();
                for j in 0..room {
                    let _ = h.insert(2000 + j as i64);
                    want.push(2000 + j as i64);
                }
                assert_eq(h.capacity(), cap);
                expect_elems(&h, &want);
            }
        }
    }
}

// Remove value `v` from the model.
const fn drop_val(want: &mut Vector<i64>, v: i64) {
    for i in 0..want.len() {
        if *want.at(i) == v {
            let _ = want.swap_remove(i);
            return;
        }
    }
    panic("the model does not hold the value");
}

@test
fn iter_mut_writes_in_place() {
    let (mut h, hs) = filled(300);
    for i in 0 as usize..300 {
        if i % 4 == 1 {
            let _ = unsafe h.remove(*hs.at(i));
        }
    }
    for x in h.iter_mut() {
        *x += 10000;
    }
    for i in 0 as usize..300 {
        if i % 4 != 1 {
            assert_eq(unsafe *h.get(*hs.at(i)), 10000 + i as i64);
        }
    }
    let mut it = h.iter_mut();
    let (lo, hi) = it.size_hint();
    assert_eq(lo, 225);
    assert_eq(hi.unwrap(), 225);
    *it.next().unwrap() = -5;
    let (lo2, _) = it.size_hint();
    assert_eq(lo2, 224);
    // A borrow from `next` outlives the next call: the items borrow the hive, not the iterator.
    let mut j = h.iter();
    let first = j.next().unwrap();
    let second = j.next().unwrap();
    assert_eq(*first + *second, -5 + 10002);
}

@test
fn retain_keeps_the_matching_elements_in_place() {
    let (mut h, hs) = filled(1000);
    for i in 0 as usize..1000 {
        if i % 5 == 0 {
            let _ = unsafe h.remove(*hs.at(i));
        }
    }
    let mut at = Vector::<usize>::new();
    for i in 0 as usize..1000 {
        if i % 10 == 2 {
            at.push(addr(&h, *hs.at(i)));
        }
    }
    h.retain(is_even);
    let mut want = Vector::<i64>::new();
    for i in 0 as usize..1000 {
        if i % 2 == 0 && i % 5 != 0 {
            want.push(i as i64);
        }
    }
    expect_elems(&h, &want);
    let mut k: usize = 0;
    for i in 0 as usize..1000 {
        if i % 10 == 2 {
            assert_eq(addr(&h, *hs.at(i)), *at.at(k));
            k += 1;
        }
    }
    // Every block emptied while the walk passes it.
    h.retain(|_x: &i64| false);
    let empty = Vector::<i64>::new();
    expect_elems(&h, &empty);
    let _ = h.insert(3);
    let three = vec_of([3]);
    expect_elems(&h, &three);
}

fn vec_of(xs: []i64) Vector<i64> {
    let mut v = Vector::<i64>::new();
    for x in xs {
        v.push(x);
    }
    return v;
}

@test
fn clear_frees_the_elements_and_keeps_the_blocks() {
    let mut c = counts();
    {
        let mut h = Hive::<String, Counting>::new_in(Counting { c: &mut c });
        for i in 0..500 {
            let _ = h.insert(heap(i));
        }
        let cap = h.capacity();
        let allocs = c.allocs;
        h.clear();
        assert_eq(h.len(), 0);
        assert(h.iter().next().is_none());
        assert_eq(h.capacity(), cap);
        for i in 0..500 {
            let _ = h.insert(heap(i));
        }
        assert_eq(c.allocs, allocs);
        assert_eq(h.capacity(), cap);
        let mut n: usize = 0;
        for s in h.iter() {
            assert(s.len() > 23);
            n += 1;
        }
        assert_eq(n, 500);
    }
    assert_eq(c.allocs, c.deallocs);
    assert_eq(c.live_bytes, 0);
}

@test
fn reserve_and_trim_capacity_change_only_reserved_blocks() {
    let mut c = counts();
    {
        let mut h = Hive::<i64, Counting>::new_in(Counting { c: &mut c });
        h.reserve(1000);
        assert(h.capacity() >= 1000);
        let allocs = c.allocs;
        let mut hs = Vector::<HiveHandle<i64>>::new();
        for i in 0..1000 {
            hs.push(h.insert(i));
        }
        assert_eq(c.allocs, allocs);
        let mut at = Vector::<usize>::new();
        for i in 0 as usize..1000 {
            at.push(addr(&h, *hs.at(i)));
        }
        // Free slots in active blocks count toward the room.
        for i in 0 as usize..100 {
            let _ = unsafe h.remove(*hs.at(i * 2));
        }
        let cap = h.capacity();
        h.reserve(cap - h.len());
        assert_eq(h.capacity(), cap);
        h.reserve(cap - h.len() + 5000);
        assert(h.capacity() >= h.len() + cap - h.len() + 5000);
        h.trim_capacity();
        assert_eq(h.capacity(), cap);
        for i in 0 as usize..1000 {
            if i >= 200 || i % 2 == 1 {
                assert_eq(addr(&h, *hs.at(i)), *at.at(i));
                assert_eq(unsafe *h.get(*hs.at(i)), i as i64);
            }
        }
        // Blocks emptied by removal stay reserved until trimmed.
        for i in 0 as usize..1000 {
            if i >= 200 || i % 2 == 1 {
                let _ = unsafe h.remove(*hs.at(i));
            }
        }
        assert(h.is_empty());
        assert_eq(h.capacity(), cap);
        let live = c.allocs - c.deallocs;
        h.trim_capacity();
        assert_eq(h.capacity(), 0);
        assert_eq(c.allocs - c.deallocs, 0);
        assert(live > 1);
        let _ = h.insert(1);
        assert(h.capacity() > 0);
    }
    assert_eq(c.allocs, c.deallocs);
    assert_eq(c.live_bytes, 0);
}

@test(should_panic)
fn reserve_overflow_panics() {
    let mut h = Hive::<i64>::new();
    let _ = h.insert(1);
    h.reserve(~(0 as usize));
}

// Block sizes: the capacity doubles until blocks reach their limit, so n inserts take O(log n) allocations
// up to the limit and one per limit of slots after it.
@test
fn block_allocations_stay_within_the_growth_bound() {
    let mut c = counts();
    {
        let mut h = Hive::<i64, Counting>::new_in(Counting { c: &mut c });
        let mut w = Hive::<Wide, Counting>::new_in(Counting { c: &mut c });
        for i in 0..100000 {
            let _ = h.insert(i);
        }
        let narrow = c.allocs;
        assert(narrow <= 100000 / 255 + 8);
        assert(h.capacity() <= 100000 + 255);
        for i in 0..100000 {
            let _ = w.insert(Wide::make(i));
        }
        let wide = c.allocs - narrow;
        assert(wide <= 100000 / 8192 + 12);
        assert(w.capacity() <= 2 * 100000);
    }
    assert_eq(c.allocs, c.deallocs);
}

// Every element is dropped once: by the caller after `remove`, by `retain`, `clear` or the drop of the hive.
@test
fn every_element_drops_exactly_once() {
    let mut drops: usize = 0;
    let mut made: usize = 0;
    {
        let mut h = Hive::<Tracked>::new();
        let mut hs = Vector::<HiveHandle<Tracked>>::new();
        for i in 0..2000 {
            hs.push(h.insert(Tracked { id: i, drops: &mut drops }));
            made += 1;
        }
        for i in 0 as usize..2000 {
            if i % 3 == 0 {
                let t = unsafe h.remove(*hs.at(i));
                assert_eq(t.id, i as i64);
            }
        }
        assert_eq(drops, 667);
        h.retain(|t: &Tracked| t.id % 2 == 0);
        assert_eq(drops, 667 + 667);
        h.clear();
        assert_eq(drops, 2000);
        for i in 0..300 {
            let _ = h.insert(Tracked { id: i, drops: &mut drops });
            made += 1;
        }
    }
    assert_eq(drops, made);
}

@test
fn string_elements_free_on_every_path() {
    let mut h = Hive::<String>::new();
    let mut hs = Vector::<HiveHandle<String>>::new();
    for i in 0..600 {
        hs.push(h.insert(heap(i)));
    }
    for i in 0 as usize..600 {
        if i % 4 == 0 {
            let s = unsafe h.remove(*hs.at(i));
            assert(s == heap(i as i64));
        }
    }
    unsafe *h.get_mut(*hs.at(1)) = heap(-1);
    h.retain(|s: &String| s.len() % 2 == 0);
    for i in 0..100 {
        let _ = h.insert(heap(i));
    }
    // Dropped with removed slots, reserved blocks and live elements.
}

@test
fn zero_sized_elements_take_distinct_slots() {
    let mut h = Hive::<Z>::new();
    let a = h.insert(Z {});
    let b = h.insert(Z {});
    assert(addr(&h, a) != addr(&h, b));
    let _ = unsafe h.remove(a);
    let c = h.insert(Z {});
    assert(addr(&h, a) == addr(&h, c));
    let mut n: usize = 0;
    for z in h.iter() {
        assert(*z == Z {});
        n += 1;
    }
    assert_eq(n, 2);
}

@test
fn conformances() {
    let h = Hive::<i64>::new();
    assert(need_send(&h));
    assert(need_sync(&h));
}

// Seeded random operations on a Hive and on a Vector model of (handle, value, address); after each one every
// handle reads its value at its first address and the iteration holds exactly the model's values.
fn random_model<T: Probe>(seed: u64, steps: usize, check_every: usize) {
    let mut c = counts();
    {
        let mut rng = rnd::Pcg32::new(seed, 54);
        let mut h = Hive::<T, Counting>::new_in(Counting { c: &mut c });
        let mut hs = Vector::<HiveHandle<T>>::new();
        let mut vals = Vector::<i64>::new();
        let mut at = Vector::<usize>::new();
        let mut next: i64 = 0;
        for step in 0..steps {
            let n = hs.len();
            let op = below(&mut rng, 100);
            if op < 52 || n == 0 {
                // A run of inserts, so the hive grows over many blocks between the removals.
                let run = below(&mut rng, 8) + 1;
                for _ in 0..run {
                    next += 1;
                    let v = next % 200;
                    let free = h.capacity() - h.len();
                    let allocs = c.allocs;
                    let k = h.insert(T::make(v));
                    if free > 0 {
                        assert_eq(c.allocs, allocs);
                    }
                    hs.push(k);
                    vals.push(v);
                    at.push(addr(&h, k));
                }
            } else if op < 97 {
                let i = below(&mut rng, n);
                let k = *hs.at(i);
                assert_eq((unsafe h.remove(k)).val(), *vals.at(i));
                let _ = hs.swap_remove(i);
                let _ = vals.swap_remove(i);
                let _ = at.swap_remove(i);
            } else if op < 98 {
                h.reserve(below(&mut rng, 600));
            } else if op < 99 {
                h.trim_capacity();
            } else if below(&mut rng, 4) == 0 {
                h.clear();
                hs.clear();
                vals.clear();
                at.clear();
            }
            if step % check_every == 0 || step == steps - 1 {
                for j in 0..hs.len() {
                    let k = *hs.at(j);
                    assert_eq((unsafe h.get(k)).val(), *vals.at(j));
                    assert_eq(addr(&h, k), *at.at(j));
                }
                expect_elems(&h, &vals);
            }
        }
    }
    assert_eq(c.allocs, c.deallocs);
    assert_eq(c.live_bytes, 0);
}

@test
fn random_operations_match_a_model_narrow() {
    random_model::<i64>(42, 20000, 7);
}

@test
fn random_operations_match_a_model_wide() {
    random_model::<Wide>(7, 20000, 7);
}

@test
fn random_operations_match_a_model_small() {
    random_model::<u8>(9, 6000, 3);
}
