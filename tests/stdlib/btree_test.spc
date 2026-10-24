// BTreeMap and BTreeSet (std::collections::btree): every public operation, the rebalance cases, String
// elements under the leak check, a counting allocator, a differential test against a sorted Vector, and
// the comparison bound of search, insert and remove.
import std::collections::btree as *;
import std::math::random as rnd;

const N_BOUND: u64 = 100000; // elements of the comparison-bound tests

// The allocation counts of a `CountAlloc`.
struct Counts {
    pub live: i64,
    pub allocs: i64,
}

// A stateful allocator: counts its live blocks, forwards to `Global`.
struct CountAlloc {
    pub c: *mut Counts,
}

extend CountAlloc as Allocator {
    pub unsafe fn alloc(self: &mut CountAlloc, size: usize, align: usize) *mut void {
        unsafe (*self.c).live += 1;
        unsafe (*self.c).allocs += 1;
        let mut g = Global {};
        return unsafe g.alloc(size, align);
    }

    pub unsafe fn realloc(self: &mut CountAlloc, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        let mut g = Global {};
        return unsafe g.realloc(ptr, old_size, new_size, align);
    }

    pub unsafe fn dealloc(self: &mut CountAlloc, ptr: *mut void, size: usize, align: usize) {
        unsafe (*self.c).live -= 1;
        let mut g = Global {};
        unsafe g.dealloc(ptr, size, align);
    }
}

static mut CMPS: u64 = 0; // comparisons made by `CKey`

// A key that counts its comparisons.
struct CKey {
    pub v: u64,
}

extend CKey as Eq {
    pub fn eq(self: &CKey, other: &CKey) bool {
        unsafe CMPS += 1;
        return self.v == other.v;
    }
}

extend CKey as Ord {
    pub fn cmp(self: &CKey, other: &CKey) i32 {
        unsafe CMPS += 1;
        if self.v < other.v {
            return -1;
        }
        if self.v > other.v {
            return 1;
        }
        return 0;
    }
}

// A zero-sized key: every value is equal.
@derive(Eq, Ord)
struct Zst {}

// The reference model: a sorted Vector of keys with the values beside them.
struct Model {
    pub keys: Vector<u64>,
    pub vals: Vector<u64>,
}

extend Model {
    fn new() Model {
        return Model { keys: Vector::<u64>::new(), vals: Vector::<u64>::new() };
    }

    fn insert(self: &mut Model, k: u64, v: u64) Option<u64> {
        switch self.keys.binary_search(&k) {
            Ok(i) => {
                let old = *self.vals.at(i);
                self.vals.set(i, v);
                return Option::<u64>::Some(old);
            },
            Err(i) => {
                self.keys.insert(i, k);
                self.vals.insert(i, v);
            },
        };
        return Option::<u64>::None;
    }

    fn remove(self: &mut Model, k: u64) Option<u64> {
        switch self.keys.binary_search(&k) {
            Ok(i) => {
                self.keys.remove(i);
                return self.vals.remove(i);
            },
            Err(_) => {},
        };
        return Option::<u64>::None;
    }

    fn get(self: &Model, k: u64) Option<u64> {
        switch self.keys.binary_search(&k) {
            Ok(i) => {
                return Option::<u64>::Some(*self.vals.at(i));
            },
            Err(_) => {},
        };
        return Option::<u64>::None;
    }

    // The keys that `lo` and `hi` admit, in order.
    fn range(self: &Model, lo: Bound<&u64>, hi: Bound<&u64>) Vector<u64> {
        let mut out = Vector::<u64>::new();
        for i in 0..self.keys.len() {
            let k = *self.keys.at(i);
            let above = switch lo {
                Included(x) => k >= *x,
                Excluded(x) => k > *x,
                Unbounded => true,
            };
            let below = switch hi {
                Included(x) => k <= *x,
                Excluded(x) => k < *x,
                Unbounded => true,
            };
            if above && below {
                out.push(k);
            }
        }
        return out;
    }
}

const fn copied(o: Option<&u64>) Option<u64> {
    if let Some(x) = o {
        return Option::<u64>::Some(*x);
    }
    return Option::<u64>::None;
}

fn key_str(i: u64) String {
    let mut s = String::from_str("key-with-a-heap-buffer-");
    let d = i.fmt();
    s.push_string(&d);
    return s;
}

fn ascending(n: u64) BTreeMap<u64, u64> {
    let mut m = BTreeMap::<u64, u64>::new();
    for i in 0..n {
        m.insert(i, i * 10);
    }
    return m;
}

// The keys of `m` in order, through `iter`.
fn keys_of<A: Allocator>(m: &BTreeMap<u64, u64, A>) Vector<u64> {
    let mut out = Vector::<u64>::new();
    for (k, _) in m.iter() {
        out.push(*k);
    }
    return out;
}

const fn bound_of(kind: u32, k: &u64) Bound<&u64> {
    if kind == 0 {
        return Bound::<&u64>::Included(k);
    }
    if kind == 1 {
        return Bound::<&u64>::Excluded(k);
    }
    return Bound::<&u64>::Unbounded;
}

// Insert, remove, get, range and end operations on random keys below `universe`, checked against the
// model after each operation and the tree structure every few operations.
fn differential(seed: u64, universe: u32, ops: u64) {
    let mut rng = rnd::Pcg32::new(seed, 11);
    let mut m = BTreeMap::<u64, u64>::new();
    let mut r = Model::new();
    for step in 0..ops {
        let op = rng.next_u32() % 100;
        let k = (rng.next_u32() % universe) as u64;
        if op < 45 {
            assert_eq(m.insert(k, step), r.insert(k, step));
        } else if op < 80 {
            assert_eq(m.remove(&k), r.remove(k));
        } else if op < 88 {
            assert_eq(copied(m.get(&k)), r.get(k));
            assert_eq(m.contains_key(&k), r.get(k).is_some());
        } else if op < 94 {
            let k2 = (rng.next_u32() % universe) as u64;
            let (a, b) = if k <= k2 {
                (k, k2);
            } else {
                (k2, k);
            };
            let lk = rng.next_u32() % 3;
            let mut hk = rng.next_u32() % 3;
            if a == b && lk == 1 && hk == 1 {
                hk = 0;
            }
            let want = r.range(bound_of(lk, &a), bound_of(hk, &b));
            let mut got = Vector::<u64>::new();
            if step % 2 == 0 {
                for (x, _) in m.range(bound_of(lk, &a), bound_of(hk, &b)) {
                    got.push(*x);
                }
            } else {
                // Back to front, then reversed.
                let mut it = m.range(bound_of(lk, &a), bound_of(hk, &b));
                while let Some((x, _)) = it.next_back() {
                    got.push(*x);
                }
                got.reverse();
            }
            assert_eq(got, want);
        } else if op < 97 {
            if r.keys.len() > 0 {
                if op == 94 {
                    let fk = *r.keys.at(0);
                    let fv = *r.vals.at(0);
                    let (pk, pv) = m.pop_first().unwrap();
                    assert_eq(pk, fk);
                    assert_eq(pv, fv);
                    r.remove(fk);
                } else {
                    let lk = *r.keys.at(r.keys.len() - 1);
                    let lv = *r.vals.at(r.vals.len() - 1);
                    let (pk, pv) = m.pop_last().unwrap();
                    assert_eq(pk, lk);
                    assert_eq(pv, lv);
                    r.remove(lk);
                }
            } else {
                assert(m.pop_first().is_none());
                assert(m.pop_last().is_none());
            }
        } else {
            assert_eq(keys_of(&m), r.keys);
        }
        assert_eq(m.len(), r.keys.len());
        if step % 8 == 0 {
            m.check_invariants();
        }
    }
    m.check_invariants();
    assert_eq(keys_of(&m), r.keys);
    let mut vals = Vector::<u64>::new();
    for v in m.values() {
        vals.push(*v);
    }
    assert_eq(vals, r.vals);
}

@test
fn differential_small_universe() {
    differential(1, 64, 6000);
    differential(2, 300, 6000);
}

@test
fn differential_large_universe() {
    differential(3, 1500, 8000);
    differential(4, 5000, 12000);
}

@test
fn empty_map() {
    let mut m = BTreeMap::<u64, u64>::new();
    assert_eq(m.len(), 0);
    assert(m.is_empty());
    assert(m.get(&1).is_none());
    assert(m.get_mut(&1).is_none());
    assert(m.get_key_value(&1).is_none());
    assert(!m.contains_key(&1));
    assert(m.remove(&1).is_none());
    assert(m.remove_entry(&1).is_none());
    assert(m.first_key_value().is_none());
    assert(m.last_key_value().is_none());
    assert(m.pop_first().is_none());
    assert(m.pop_last().is_none());
    assert(m.iter().next().is_none());
    assert(m.iter().next_back().is_none());
    assert(m.keys().next().is_none());
    assert(m.values().next().is_none());
    assert(m.range(Bound::<&u64>::Unbounded, Bound::<&u64>::Unbounded).next().is_none());
    m.retain(|_k: &u64, _v: &mut u64| true);
    m.clear();
    assert_eq(m.check_invariants(), 0);
    let s = m.fmt();
    assert_eq(s.as_str(), "{}");
}

@test
fn one_element() {
    let mut m = BTreeMap::<u64, u64>::new();
    assert(m.insert(7, 70).is_none());
    assert_eq(m.len(), 1);
    assert_eq(*m.get(&7).unwrap(), 70);
    assert(m.get(&6).is_none());
    assert(m.get(&8).is_none());
    let (fk, fv) = m.first_key_value().unwrap();
    assert_eq(*fk, 7);
    assert_eq(*fv, 70);
    let (lk, lv) = m.last_key_value().unwrap();
    assert_eq(*lk, 7);
    assert_eq(*lv, 70);
    assert_eq(m.insert(7, 71).unwrap(), 70);
    assert_eq(m.len(), 1);
    assert_eq(m.remove(&7).unwrap(), 71);
    assert(m.is_empty());
    assert_eq(m.check_invariants(), 0);
}

@test
fn get_mut_and_get_key_value() {
    let mut m = ascending(100);
    *m.get_mut(&42).unwrap() = 4242;
    assert_eq(*m.get(&42).unwrap(), 4242);
    let (k, v) = m.get_key_value(&42).unwrap();
    assert_eq(*k, 42);
    assert_eq(*v, 4242);
    let (rk, rv) = m.remove_entry(&42).unwrap();
    assert_eq(rk, 42);
    assert_eq(rv, 4242);
    assert(!m.contains_key(&42));
    assert_eq(m.len(), 99);
}

@test
fn sequential_and_reverse_insertion() {
    for n in [1u64, 15, 16, 17, 120, 127, 128, 2000] {
        let mut up = BTreeMap::<u64, u64>::new();
        let mut down = BTreeMap::<u64, u64>::new();
        for i in 0..n {
            assert(up.insert(i, i * 10).is_none());
            assert(down.insert(n - 1 - i, i).is_none());
            up.check_invariants();
            down.check_invariants();
        }
        assert_eq(up.len() as u64, n);
        assert_eq(down.len() as u64, n);
        let mut want: u64 = 0;
        for (k, _) in down.iter() {
            assert_eq(*k, want);
            want += 1;
        }
        assert_eq(want, n);
        let want_map = ascending(n);
        assert(up.eq(&want_map));
    }
}

// The rebalance cases at the leaf level, on trees whose shape the split rule fixes: 16 ascending keys
// split one full leaf of 15 into [0..8) and [9..16) under the root key 8.
@test
fn rebalance_steal_left() {
    let mut c = Counts { live: 0, allocs: 0 };
    let mut m = BTreeMap::<u64, u64, CountAlloc>::new_in(CountAlloc { c: &mut c });
    for i in 0..16u64 {
        m.insert(i, i);
    }
    assert_eq(m.check_invariants(), 1);
    assert_eq(c.live, 3);
    // The right leaf drops to 6 keys and takes one from the left leaf through the root.
    m.remove(&9);
    assert_eq(m.check_invariants(), 1);
    assert_eq(c.live, 3);
    let want: Vector<u64> = [0u64, 1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15].into();
    assert_eq(keys_of(&m), want);
}

@test
fn rebalance_merge_and_root_shrink() {
    let mut c = Counts { live: 0, allocs: 0 };
    let mut m = BTreeMap::<u64, u64, CountAlloc>::new_in(CountAlloc { c: &mut c });
    for i in 0..16u64 {
        m.insert(i, i);
    }
    // [0..8) (8 keys) [8] [9..16) (7 keys): removing 9 steals, then the left leaf has 7.
    m.remove(&9);
    // The left leaf drops to 6, its right sibling has only 7: they merge, and the empty root goes.
    m.remove(&0);
    assert_eq(m.check_invariants(), 0);
    assert_eq(c.live, 1);
    assert_eq(m.len(), 14);
}

@test
fn rebalance_steal_right() {
    let mut c = Counts { live: 0, allocs: 0 };
    let mut m = BTreeMap::<u64, u64, CountAlloc>::new_in(CountAlloc { c: &mut c });
    for i in 0..17u64 {
        m.insert(i, i);
    }
    // [0..8) (8 keys) [8] [9..17) (8 keys): the left leaf drops to 6 and takes the root key, and the
    // right leaf's first key moves up.
    m.remove(&0);
    m.remove(&1);
    assert_eq(m.check_invariants(), 1);
    assert_eq(c.live, 3);
    assert_eq(*m.first_key_value().unwrap().0, 2);
    assert_eq(m.len(), 15);
}

// Removal orders over a three-level tree reach the internal-node steals and merges and the root
// shrinks down to a leaf.
fn drain_in_order(order: u32) {
    let n: u64 = 1200;
    let mut c = Counts { live: 0, allocs: 0 };
    {
        let mut m = BTreeMap::<u64, u64, CountAlloc>::new_in(CountAlloc { c: &mut c });
        for i in 0..n {
            m.insert(i * 7 % n, i);
        }
        assert(m.check_invariants() >= 2);
        let mut live = c.live;
        for j in 0..n {
            let k = if order == 0 {
                j;
            } else if order == 1 {
                n - 1 - j;
            } else if j % 2 == 0 {
                n / 2 + j / 2;
            } else {
                n / 2 - 1 - j / 2;
            };
            assert(m.remove(&k).is_some());
            m.check_invariants();
            assert(c.live <= live);
            live = c.live;
            assert_eq(m.len() as u64, n - 1 - j);
        }
        assert_eq(c.live, 0);
    }
    assert_eq(c.live, 0);
}

@test
fn removal_orders_rebalance_every_level() {
    drain_in_order(0);
    drain_in_order(1);
    drain_in_order(2);
}

@test
fn counting_allocator_drop_and_clear() {
    let mut c = Counts { live: 0, allocs: 0 };
    {
        let mut m = BTreeMap::<u64, u64, CountAlloc>::new_in(CountAlloc { c: &mut c });
        for i in 0..5000u64 {
            m.insert(i * 31 % 5000, i);
        }
        assert(c.live > 300);
        m.clear();
        assert_eq(c.live, 0);
        assert(m.is_empty());
        for i in 0..1000u64 {
            m.insert(i, i);
        }
        assert(c.live > 0);
        let mut s = BTreeSet::<u64, CountAlloc>::new_in(CountAlloc { c: &mut c });
        for i in 0..1000u64 {
            s.insert(i);
        }
        let copy = m.clone();
        assert(copy.eq(&m));
    }
    assert_eq(c.live, 0);
    assert(c.allocs > 0);
}

@test
fn string_keys_and_values_do_not_leak() {
    let mut m = BTreeMap::<String, String>::new();
    for i in 0..400u64 {
        assert(m.insert(key_str(i * 13 % 400), key_str(i)).is_none());
    }
    // A duplicate key drops the argument key and returns the replaced value.
    let old = m.insert(key_str(5), key_str(9999)).unwrap();
    assert_eq(old.as_str(), key_str(5 * 277 % 400).as_str());
    let k5 = key_str(5);
    assert_eq(m.get(&k5).unwrap().as_str(), key_str(9999).as_str());
    for i in 0..200u64 {
        let k = key_str(i * 2);
        let v = m.remove(&k).unwrap();
        assert(v.len() > 0);
    }
    let (fk, _) = m.pop_first().unwrap();
    assert_eq(fk.as_str(), key_str(1).as_str());
    let (lk, _) = m.pop_last().unwrap();
    assert(lk.len() > 0);
    // A vacant entry dropped without insert drops its key.
    {
        let e = m.entry(key_str(100000));
        assert_eq(e.key().as_str(), key_str(100000).as_str());
    }
    let e1 = m.entry(key_str(100001));
    e1.or_insert(String::from_str("new"));
    let e2 = m.entry(key_str(3));
    e2.or_insert(String::from_str("unused"));
    m.retain(|k: &String, _v: &mut String| k.len() % 2 == 0);
    let copy = m.clone();
    assert(copy.eq(&m));
    let mut other = BTreeMap::<String, String>::new();
    other.insert(key_str(7), String::from_str("other"));
    other.insert(key_str(424242), String::from_str("other"));
    m.append(&mut other);
    assert(other.is_empty());
    m.check_invariants();
    let mut s = BTreeSet::<String>::new();
    for i in 0..100u64 {
        s.insert(key_str(i % 50));
    }
    assert_eq(s.len(), 50);
    let k3 = key_str(3);
    assert(s.remove(&k3));
    assert_eq(s.pop_first().unwrap().as_str(), key_str(0).as_str());
}

@test
fn entry_api() {
    let mut m = BTreeMap::<u64, u64>::new();
    // Word-count style updates through each vacant and occupied path.
    for i in 0..300u64 {
        let e = m.entry(i % 37);
        *e.or_insert(0) += 1;
    }
    assert_eq(m.len(), 37);
    assert_eq(*m.get(&0).unwrap(), 9);
    assert_eq(*m.get(&36).unwrap(), 8);
    let e100 = m.entry(100);
    assert_eq(*e100.or_insert_with(|| 5u64), 5);
    let e100b = m.entry(100);
    assert_eq(*e100b.or_insert_with(|| 6u64), 5);
    let e101 = m.entry(101);
    assert_eq(*e101.or_default(), 0);
    let e101b = m.entry(101).and_modify(|v: &mut u64| *v += 10);
    e101b.or_insert(77);
    assert_eq(*m.get(&101).unwrap(), 10);
    let e102 = m.entry(102).and_modify(|v: &mut u64| *v += 10);
    e102.or_insert(77);
    assert_eq(*m.get(&102).unwrap(), 77);
    let e5 = m.entry(5);
    assert_eq(*e5.key(), 5);
    switch m.entry(5) {
        Occupied(e) => {
            let mut o = e;
            assert_eq(*o.key(), 5);
            assert_eq(*o.get(), 8);
            *o.get_mut() = 50;
            assert_eq(o.insert(51), 50);
            assert_eq(o.remove(), 51);
        },
        Vacant(_) => {
            assert(false, "key 5 is present");
        },
    };
    assert(!m.contains_key(&5));
    switch m.entry(5) {
        Occupied(_) => {
            assert(false, "key 5 is gone");
        },
        Vacant(e) => {
            assert_eq(*e.key(), 5);
            *e.insert(500) += 1;
        },
    };
    assert_eq(*m.get(&5).unwrap(), 501);
    switch m.entry(6) {
        Occupied(e) => {
            *e.into_mut() = 600;
        },
        Vacant(_) => {
            assert(false, "key 6 is present");
        },
    };
    assert_eq(*m.get(&6).unwrap(), 600);
    m.check_invariants();
}

// A vacant insert into a full leaf splits it; the returned reference is the new value's slot.
@test
fn entry_insert_into_full_leaves() {
    for at in 0..17u64 {
        let mut m = BTreeMap::<u64, u64>::new();
        for i in 0..15u64 {
            m.insert(i * 2 + 1, i);
        }
        let e = m.entry(at * 2);
        *e.or_insert(0) = 1000 + at;
        m.check_invariants();
        assert_eq(*m.get(&(at * 2)).unwrap(), 1000 + at);
        assert_eq(m.len(), 16);
    }
    let mut empty = BTreeMap::<u64, u64>::new();
    let e = empty.entry(3);
    *e.or_default() = 9;
    assert_eq(*empty.get(&3).unwrap(), 9);
}

@test
fn iterators_both_ends_and_size_hint() {
    let m = ascending(500);
    let mut it = m.iter();
    let (lo, hi) = it.size_hint();
    assert_eq(lo, 500);
    assert_eq(hi.unwrap(), 500);
    let mut front: u64 = 0;
    let mut back: u64 = 500;
    let mut seen: usize = 0;
    // Alternate the ends until they meet in the middle.
    loop {
        let r = if seen % 3 == 0 {
            it.next_back();
        } else {
            it.next();
        };
        if r.is_none() {
            break;
        }
        let (k, v) = r.unwrap();
        assert_eq(*v, *k * 10);
        if seen % 3 == 0 {
            back -= 1;
            assert_eq(*k, back);
        } else {
            assert_eq(*k, front);
            front += 1;
        }
        seen += 1;
        let (left, _) = it.size_hint();
        assert_eq(left, 500 - seen);
    }
    assert_eq(seen, 500);
    assert_eq(front, back);
    assert(it.next().is_none());
    assert(it.next_back().is_none());
    let mut keys = m.keys();
    assert_eq(*keys.next_back().unwrap(), 499);
    assert_eq(*keys.next().unwrap(), 0);
    let (keys_left, _) = keys.size_hint();
    assert_eq(keys_left, 498);
    let mut values = m.values();
    assert_eq(*values.next_back().unwrap(), 4990);
    assert_eq(*values.next().unwrap(), 0);
    let (values_left, _) = values.size_hint();
    assert_eq(values_left, 498);
}

@test
fn mutable_iterators() {
    let mut m = ascending(300);
    for (k, v) in m.iter_mut() {
        *v = *k + 1;
    }
    let mut it = m.iter_mut();
    let (k, v) = it.next_back().unwrap();
    assert_eq(*k, 299);
    *v = 0;
    let (it_left, _) = it.size_hint();
    assert_eq(it_left, 299);
    for v in m.values_mut() {
        *v *= 2;
    }
    let mut vm = m.values_mut();
    *vm.next_back().unwrap() += 7;
    let (vm_left, _) = vm.size_hint();
    assert_eq(vm_left, 299);
    assert_eq(*m.get(&10).unwrap(), 22);
    assert_eq(*m.get(&299).unwrap(), 7);
}

@test
fn range_bounds() {
    let mut m = BTreeMap::<u64, u64>::new();
    for i in 0..200u64 {
        m.insert(i * 2, i);
    }
    let mut r = Model::new();
    for i in 0..200u64 {
        r.insert(i * 2, i);
    }
    // Every bound kind on each side, at present and absent keys and past both ends.
    let points = [0u64, 1, 2, 3, 57, 58, 200, 397, 398, 399, 500];
    for a in points {
        for b in points {
            if a > b {
                continue;
            }
            for lk in 0..3u32 {
                for hk in 0..3u32 {
                    if a == b && lk == 1 && hk == 1 {
                        continue;
                    }
                    let mut got = Vector::<u64>::new();
                    for (k, _) in m.range(bound_of(lk, &a), bound_of(hk, &b)) {
                        got.push(*k);
                    }
                    assert_eq(got, r.range(bound_of(lk, &a), bound_of(hk, &b)));
                }
            }
        }
    }
    let mut it = m.range(Bound::<&u64>::Included(&10), Bound::<&u64>::Excluded(&20));
    let (k, _) = it.next_back().unwrap();
    assert_eq(*k, 18);
    let (k2, _) = it.next().unwrap();
    assert_eq(*k2, 10);
    let mut count = 0;
    while it.next().is_some() {
        count += 1;
    }
    assert_eq(count, 3);
    assert(it.next_back().is_none());
}

@test(should_panic)
fn range_start_above_end_panics() {
    let m = ascending(10);
    let _ = m.range(Bound::<&u64>::Included(&5), Bound::<&u64>::Included(&4));
}

@test(should_panic)
fn range_equal_excluded_panics() {
    let m = ascending(10);
    let _ = m.range(Bound::<&u64>::Excluded(&5), Bound::<&u64>::Excluded(&5));
}

@test
fn retain_matches_the_model() {
    let mut rng = rnd::Pcg32::new(17, 3);
    for round in 0..6u64 {
        let mut m = BTreeMap::<u64, u64>::new();
        let mut r = Model::new();
        let n = 50 + round * 300;
        for _ in 0..n {
            let k = (rng.next_u32() % 4000) as u64;
            m.insert(k, k);
            r.insert(k, k);
        }
        let modulus = round + 2;
        let mut calls: usize = 0;
        m.retain(
            fn(k: &u64, v: &mut u64) bool {
                calls += 1;
                *v += 1;
                return *k % modulus != 0;
            },
        );
        assert_eq(calls, r.keys.len());
        let mut want = Vector::<u64>::new();
        for i in 0..r.keys.len() {
            if *r.keys.at(i) % modulus != 0 {
                want.push(*r.keys.at(i));
            }
        }
        m.check_invariants();
        assert_eq(keys_of(&m), want);
        for (k, v) in m.iter() {
            assert_eq(*v, *k + 1);
        }
    }
    let mut all = ascending(1000);
    all.retain(|_k: &u64, _v: &mut u64| false);
    assert(all.is_empty());
    assert_eq(all.check_invariants(), 0);
}

@test
fn append_and_extend_from() {
    let mut c1 = Counts { live: 0, allocs: 0 };
    let mut c2 = Counts { live: 0, allocs: 0 };
    {
        let mut a = BTreeMap::<u64, u64, CountAlloc>::new_in(CountAlloc { c: &mut c1 });
        let mut b = BTreeMap::<u64, u64, CountAlloc>::new_in(CountAlloc { c: &mut c2 });
        let mut r = Model::new();
        for i in 0..3000u64 {
            a.insert(i * 3, 1);
            r.insert(i * 3, 1);
        }
        for i in 0..2000u64 {
            b.insert(i * 5, 2);
            r.insert(i * 5, 2);
        }
        a.append(&mut b);
        assert(b.is_empty());
        assert_eq(c2.live, 0);
        a.check_invariants();
        assert_eq(keys_of(&a), r.keys);
        let mut vals = Vector::<u64>::new();
        for v in a.values() {
            vals.push(*v);
        }
        assert_eq(vals, r.vals);
        // Into an empty map, and from an empty one.
        let mut e = BTreeMap::<u64, u64, CountAlloc>::new_in(CountAlloc { c: &mut c2 });
        e.append(&mut a);
        assert(a.is_empty());
        e.check_invariants();
        assert_eq(keys_of(&e), r.keys);
        e.append(&mut a);
        assert_eq(e.len(), r.keys.len());
        assert_eq(c1.live, 0);
        // A map of fewer than 1/16 of the entries goes in one insert at a time, with the same result.
        let mut few = BTreeMap::<u64, u64, CountAlloc>::new_in(CountAlloc { c: &mut c1 });
        for i in 0..40u64 {
            few.insert(i * 11, 3);
            r.insert(i * 11, 3);
        }
        e.append(&mut few);
        assert(few.is_empty());
        assert_eq(c1.live, 0);
        e.check_invariants();
        assert_eq(keys_of(&e), r.keys);
        let mut evals = Vector::<u64>::new();
        for v in e.values() {
            evals.push(*v);
        }
        assert_eq(evals, r.vals);
    }
    assert_eq(c2.live, 0);
    let mut m = ascending(10);
    let pairs: Vector<(u64, u64)> = [(3u64, 33u64), (20u64, 200u64), (0u64, 1u64)].into();
    m.extend_from(PairIter { v: pairs, i: 0 });
    assert_eq(m.len(), 11);
    assert_eq(*m.get(&3).unwrap(), 33);
    assert_eq(*m.get(&20).unwrap(), 200);
    assert_eq(*m.get(&0).unwrap(), 1);
}

// Yields the pairs of a vector by value.
struct PairIter {
    pub v: Vector<(u64, u64)>,
    pub i: usize,
}

extend PairIter as Iterator<(u64, u64)> {
    pub fn next(self: &mut PairIter) Option<(u64, u64)> {
        if self.i >= self.v.len() {
            return Option::<(u64, u64)>::None;
        }
        self.i += 1;
        return Option::<(u64, u64)>::Some(*self.v.at(self.i - 1));
    }
}

@test
fn conformances() {
    let a = ascending(50);
    let mut b = BTreeMap::<u64, u64>::new();
    for i in 0..50u64 {
        b.insert(49 - i, (49 - i) * 10);
    }
    assert(a.eq(&b));
    assert_eq(hash(&a), hash(&b));
    let mut c = a.clone();
    c.check_invariants();
    assert(c.eq(&a));
    *c.get_mut(&3).unwrap() = 0;
    assert(!c.eq(&a));
    assert_ne(hash(&c), hash(&a));
    assert_eq(*a.get(&3).unwrap(), 30);
    let small: BTreeMap<u64, u64> = [(2u64, 20u64), (1u64, 10u64)].into();
    let s = small.fmt();
    assert_eq(s.as_str(), "{1: 10, 2: 20}");
    // Strictly increasing keys take the full-node path; a later duplicate wins on the other path.
    let sorted: BTreeMap<u64, u64> = [(1u64, 1u64), (2u64, 2u64), (3u64, 3u64)].into();
    sorted.check_invariants();
    assert_eq(sorted.len(), 3);
    let dup: BTreeMap<u64, u64> = [(1u64, 1u64), (1u64, 2u64)].into();
    assert_eq(dup.len(), 1);
    assert_eq(*dup.get(&1).unwrap(), 2);
    let d = BTreeMap::<u64, u64>::default();
    assert(d.is_empty());
    let none = Vector::<(u64, u64)>::new();
    let from_none = BTreeMap::<u64, u64>::from(none[0..]);
    assert(from_none.is_empty());
    assert_eq(from_none.check_invariants(), 0);
    let mut many = Vector::<(u64, u64)>::new();
    for i in 0..1000u64 {
        many.push((i, i));
    }
    let from_many = BTreeMap::<u64, u64>::from(many[0..]);
    assert_eq(from_many.len(), 1000);
    assert(from_many.check_invariants() >= 2);
    let mut want_keys = Vector::<u64>::new();
    for i in 0..1000u64 {
        want_keys.push(i);
    }
    assert_eq(keys_of(&from_many), want_keys);
    sendable::<BTreeMap<String, u64>>();
    sendable::<BTreeSet<String>>();
    let set: BTreeSet<u64> = [3u64, 1, 2, 3].into();
    let ss = set.fmt();
    assert_eq(ss.as_str(), "{1, 2, 3}");
    let set2 = set.clone();
    assert(set2.eq(&set));
    assert_eq(hash(&set2), hash(&set));
    assert(BTreeSet::<u64>::default().is_empty());
    let e = BTreeSet::<u64>::new();
    let es = e.fmt();
    assert_eq(es.as_str(), "{}");
}

@test
fn hash_into_feeds_the_sequence() {
    let a: BTreeMap<u64, u64> = [(1u64, 2u64), (3u64, 4u64)].into();
    let mut t = Tape { bytes: Vector::<u8>::new() };
    a.hash_into(&mut t);
    let mut want = Tape { bytes: Vector::<u8>::new() };
    want.write_u64(2);
    1u64.hash_into(&mut want);
    2u64.hash_into(&mut want);
    3u64.hash_into(&mut want);
    4u64.hash_into(&mut want);
    assert_eq(t.bytes, want.bytes);
    let s: BTreeSet<u64> = [5u64, 6].into();
    let mut ts = Tape { bytes: Vector::<u8>::new() };
    s.hash_into(&mut ts);
    let mut ws = Tape { bytes: Vector::<u8>::new() };
    ws.write_u64(2);
    5u64.hash_into(&mut ws);
    6u64.hash_into(&mut ws);
    assert_eq(ts.bytes, ws.bytes);
}

// A hasher that records the stream.
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

@test
fn zero_sized_keys() {
    let mut m = BTreeMap::<Zst, u64>::new();
    assert(m.insert(Zst {}, 1).is_none());
    assert_eq(m.insert(Zst {}, 2).unwrap(), 1);
    assert_eq(m.len(), 1);
    assert_eq(*m.get(&Zst {}).unwrap(), 2);
    assert_eq(m.remove(&Zst {}).unwrap(), 2);
    assert(m.is_empty());
}

// Compiles only for a type that is Send and Sync.
const fn sendable<T: Send + Sync>() {}

fn set_of(xs: []u64) BTreeSet<u64> {
    let mut s = BTreeSet::<u64>::new();
    for x in xs {
        s.insert(x);
    }
    return s;
}

fn collect<'a, I: Iterator<&'a u64>>(it: I) Vector<u64> {
    let mut v = Vector::<u64>::new();
    let mut i = it;
    while let Some(x) = i.next() {
        v.push(*x);
    }
    return v;
}

@test
fn set_operations() {
    let mut s = BTreeSet::<u64>::new();
    assert(s.first().is_none());
    assert(s.last().is_none());
    assert(s.pop_first().is_none());
    assert(s.pop_last().is_none());
    for i in 0..100u64 {
        assert(s.insert(i * 3 % 100));
    }
    assert(!s.insert(5));
    assert_eq(s.len(), 100);
    assert(s.contains(&50));
    assert(s.remove(&50));
    assert(!s.remove(&50));
    assert(!s.contains(&50));
    assert_eq(*s.first().unwrap(), 0);
    assert_eq(*s.last().unwrap(), 99);
    assert_eq(s.pop_first().unwrap(), 0);
    assert_eq(s.pop_last().unwrap(), 99);
    assert_eq(s.check_invariants(), 1);
    let mut it = s.iter();
    let (it_left, _) = it.size_hint();
    assert_eq(it_left, 97);
    assert_eq(*it.next().unwrap(), 1);
    assert_eq(*it.next_back().unwrap(), 98);
    let mut r = s.range(Bound::<&u64>::Excluded(&40), Bound::<&u64>::Included(&52));
    assert_eq(*r.next().unwrap(), 41);
    assert_eq(*r.next_back().unwrap(), 52);
    let rest = collect(r);
    let want: Vector<u64> = [42u64, 43, 44, 45, 46, 47, 48, 49, 51].into();
    assert_eq(rest, want);
    s.clear();
    assert(s.is_empty());

    // The merge walks against brute force over random sets, empty ones included.
    let mut rng = rnd::Pcg32::new(5, 9);
    for round in 0..40u32 {
        let mut xa = Vector::<u64>::new();
        let mut xb = Vector::<u64>::new();
        for _ in 0..round * 7 % 60 {
            xa.push(rng.next_u32() % 80);
        }
        for _ in 0..round * 11 % 50 {
            xb.push(rng.next_u32() % 80);
        }
        let a = set_of(xa[0..]);
        let b = set_of(xb[0..]);
        let mut u = Vector::<u64>::new();
        let mut n = Vector::<u64>::new();
        let mut d = Vector::<u64>::new();
        let mut x = Vector::<u64>::new();
        for v in 0..80u64 {
            let ia = a.contains(&v);
            let ib = b.contains(&v);
            if ia || ib {
                u.push(v);
            }
            if ia && ib {
                n.push(v);
            }
            if ia && !ib {
                d.push(v);
            }
            if ia != ib {
                x.push(v);
            }
        }
        assert_eq(collect(a.union_with(&b)), u);
        assert_eq(collect(a.intersection(&b)), n);
        assert_eq(collect(a.difference(&b)), d);
        assert_eq(collect(a.symmetric_difference(&b)), x);
        assert_eq(a.is_subset(&b), d.len() == 0);
        assert_eq(b.is_superset(&a), d.len() == 0);
        assert_eq(a.is_disjoint(&b), n.len() == 0);
    }
    let small = set_of([2u64, 4]);
    let big = set_of([1u64, 2, 3, 4]);
    assert(small.is_subset(&big));
    assert(big.is_superset(&small));
    assert(!big.is_subset(&small));
    let odd = set_of([1u64, 3]);
    assert(small.is_disjoint(&odd));
    assert(BTreeSet::<u64>::new().is_subset(&small));
}

// The comparisons of each insert, get and remove stay within CAPACITY per node on the root-to-leaf
// path: at most 15 (h + 1) with h <= log_8((n + 1) / 2) <= 5 for n = 100000, so 90 comparisons. That
// is below 6 log2(n) = 99.6: per level at most 2B - 1 = 15 comparisons and log2(8) = 3 bits of the
// key, which is 5 comparisons per bit, plus one level for the root, which 6 log2(n) covers once
// log2(n) >= 15.
fn comparison_bound(order: u32) {
    let n = N_BOUND;
    let bound: u64 = 6 * 17; // 6 * ceil(log2(100000))
    let exact: u64 = 15 * 6;
    let mut keys = Vector::<u64>::with_capacity(n as usize);
    for i in 0..n {
        let k = if order == 0 {
            i;
        } else if order == 1 {
            n - 1 - i;
        } else {
            i.wrapping_mul(0x9E3779B97F4A7C15u64) % (n * 8);
        };
        keys.push(k);
    }
    let mut m = BTreeMap::<CKey, u64>::new();
    let mut worst: u64 = 0;
    for i in 0..n as usize {
        let before = unsafe CMPS;
        m.insert(CKey { v: *keys.at(i) }, 0);
        let used = unsafe CMPS - before;
        if used > worst {
            worst = used;
        }
    }
    let h = m.check_invariants() as u64;
    // A B-tree of minimum degree 8 holding n keys has height at most log_8((n + 1) / 2).
    assert(h <= 5);
    let mut probe = CKey { v: 0 };
    for i in 0..n as usize {
        probe.v = *keys.at(i);
        let before = unsafe CMPS;
        assert(m.get(&probe).is_some());
        let used = unsafe CMPS - before;
        if used > worst {
            worst = used;
        }
    }
    for i in 0..n as usize {
        probe.v = *keys.at(i * 7919 % n as usize);
        let before = unsafe CMPS;
        assert(m.remove(&probe).is_some());
        let used = unsafe CMPS - before;
        if used > worst {
            worst = used;
        }
    }
    assert(m.is_empty());
    assert(worst <= exact);
    assert(worst <= bound);
}

@test
fn comparison_bound_sequential() {
    comparison_bound(0);
}

@test
fn comparison_bound_reverse() {
    comparison_bound(1);
}

@test
fn comparison_bound_random() {
    comparison_bound(2);
}
