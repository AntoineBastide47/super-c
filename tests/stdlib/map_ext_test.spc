// Map and Set beyond insert/get/remove: the hash-builder parameter, the entry API, key-value
// iteration in both directions, retain, drain, reserve, Clone/Eq/Format, and the set operations. A
// builder that sends every key to one slot forces the worst case: one cluster that wraps the table.

import std::math::random as random;

// Every key hashes to the same value: one probe cluster, through the end of the table and back.
@derive(Copy, Default)
struct OneSlot {}

extend OneSlot as BuildHasher {
    pub fn hash_one<K: Hash>(self: &OneSlot, key: &K) u64 {
        return 5;
    }
}

// A builder with state: the hash mixes in a seed, as a keyed builder does.
@derive(Copy)
struct Seeded {
    pub seed: u64,
}

extend Seeded as BuildHasher {
    pub fn hash_one<K: Hash>(self: &Seeded, key: &K) u64 {
        let h = (hash(key) ^ self.seed).wrapping_mul(0x9E3779B97F4A7C15);
        return h ^ h >> 29;
    }
}

fn s(x: i64) String {
    let mut out = String::from_str("v");
    out.push_i64(x);
    return out;
}

@test
fn default_map_keeps_its_hash_and_order() {
    // The default builder is the pre-existing mix: the same keys land in the same slots.
    let mut m = Map::<u64, u64>::new();
    for i in 0..100u64 {
        m.insert(i * 7, i);
    }
    let mut seen = Vector::<u64>::new();
    for k in m.keys() {
        seen.push(*k);
    }
    let mut again = Map::<u64, u64>::new();
    for i in 0..100u64 {
        again.insert(i * 7, i);
    }
    let mut j: usize = 0;
    for k in again.keys() {
        assert_eq(*k, *seen.at(j));
        j += 1;
    }
    let h = DefaultHash {};
    let x: u64 = 0x1234_5678_9abc_def0;
    let m1 = (x ^ x >> 32).wrapping_mul(0x9E3779B97F4A7C15);
    assert_eq(h.hash_one(&x), m1 ^ m1 >> 32);
}

@test
fn entry_api_inserts_once_and_modifies_in_place() {
    let mut m = Map::<String, i64>::new();
    for word in ["a", "b", "a", "c", "a", "b"] {
        *m.entry(String::from_str(word)).or_insert(0) += 1;
    }
    let ka = String::from_str("a");
    let kb = String::from_str("b");
    let ke = String::from_str("e");
    let kz = String::from_str("z");
    assert_eq(*m.get(&ka).unwrap(), 3);
    assert_eq(*m.get(&kb).unwrap(), 2);
    let k = String::from_str("c");
    let e = m.entry(String::from_str("c"));
    assert(e.key().as_str() == "c");
    let v = e.and_modify(
        |x: &mut i64| {
            *x = *x * 10;
        },
    ).or_default();
    assert_eq(*v, 10);
    assert_eq(*m.entry(String::from_str("d")).or_default(), 0);
    let mut calls = 0;
    let _ = m.entry(String::from_str("e")).or_insert_with(
        fn() i64 {
            calls += 1;
            return 42;
        },
    );
    let _ = m.entry(String::from_str("e")).or_insert_with(
        fn() i64 {
            calls += 1;
            return 43;
        },
    );
    assert_eq(calls, 1);
    assert_eq(*m.get(&ke).unwrap(), 42);
    switch m.entry(String::from_str("a")) {
        Occupied(o) => {
            assert_eq(*o.get(), 3);
            assert_eq(o.remove(), 3);
        },
        Vacant(_) => assert(false, "a is present"),
    };
    assert(!m.contains_key(&ka));
    switch m.entry(String::from_str("z")) {
        Occupied(_) => assert(false, "z is absent"),
        Vacant(v) => {
            let back = v.into_key();
            assert(back.as_str() == "z");
        },
    };
    assert(!m.contains_key(&kz));
    switch m.entry(String::from_str("b")) {
        Occupied(mut o) => {
            assert_eq(o.insert(7), 2);
            let (key, val) = o.remove_entry();
            assert(key.as_str() == "b");
            assert_eq(val, 7);
        },
        Vacant(_) => assert(false, "b is present"),
    };
    assert_eq(m.len(), 3);
    assert(k.as_str() == "c");
}

@test
fn iterators_visit_every_entry_once_from_either_end() {
    let mut m = Map::<i64, String>::new();
    for i in 0..50 {
        m.insert(i, s(i));
    }
    let mut it = m.iter();
    let (lo, hi) = it.size_hint();
    assert_eq(lo, 50);
    assert_eq(hi.unwrap(), 50);
    let mut sum: i64 = 0;
    let mut n = 0;
    loop {
        let a = it.next();
        let b = it.next_back();
        if a.is_none() && b.is_none() {
            break;
        }
        switch a {
            Some((k, v)) => {
                assert(v.as_str() == s(*k).as_str());
                sum += *k;
                n += 1;
            },
            None => {},
        };
        switch b {
            Some((k, _)) => {
                sum += *k;
                n += 1;
            },
            None => {},
        };
    }
    assert_eq(n, 50);
    assert_eq(sum, 49 * 50 / 2);
    for (_, v) in m.iter_mut() {
        v.push_str("!");
    }
    for v in m.values_mut() {
        v.push_str("?");
    }
    assert(m.get(&3).unwrap().as_str() == "v3!?");
    let mut kb: i64 = 0;
    let mut kit = m.keys();
    while let Some(k) = kit.next_back() {
        kb += *k;
    }
    assert_eq(kb, sum);
    assert_eq(m.get_key_value(&9).unwrap()._1.as_str(), "v9!?");
}

@test
fn one_cluster_survives_removal_retain_and_drain() {
    let mut rng = random::Pcg32::new(3, 3);
    let mut m = Map::<i64, String, Global, OneSlot>::new();
    let mut want = Vector::<i64>::new();
    for i in 0..40 {
        m.insert(i, s(i));
        want.push(i);
    }
    // Remove in a random order, checking every remaining key after each removal.
    while want.len() > 20 {
        let k = want.swap_remove(rng.next_u32() as usize % want.len()).unwrap();
        assert(m.remove(&k).unwrap().as_str() == s(k).as_str());
        for w in want.iter() {
            assert(m.get(w).unwrap().as_str() == s(*w).as_str());
        }
    }
    m.retain(
        fn(k: &i64, v: &mut String) bool {
            v.push_str("+");
            return *k % 3 != 0;
        },
    );
    for w in want.iter() {
        if *w % 3 == 0 {
            assert(!m.contains_key(w));
        } else {
            let mut e = s(*w);
            e.push_str("+");
            assert(m.get(w).unwrap().as_str() == e.as_str());
        }
    }
    let mut drained = 0;
    {
        let mut d = m.drain();
        let _ = d.next();
        drained += 1;
    }
    assert_eq(m.len(), 0);
    assert(drained == 1);
    m.insert(1, s(1));
    assert_eq(m.len(), 1);
}

@test
fn random_operations_match_a_reference() {
    let mut rng = random::Pcg32::new(77, 1);
    let mut m = Map::<u32, u32, Global, Seeded>::with_hasher(Seeded { seed: 99 });
    let mut keys = Vector::<u32>::new();
    let mut vals = Vector::<u32>::new();
    for step in 0..6000u32 {
        let k = rng.next_u32() % 300;
        let op = rng.next_u32() % 4;
        let mut pos: usize = keys.len();
        for i in 0..keys.len() {
            if *keys.at(i) == k {
                pos = i;
            }
        }
        if op == 0 || op == 1 {
            m.insert(k, step);
            if pos < keys.len() {
                vals.set(pos, step);
            } else {
                keys.push(k);
                vals.push(step);
            }
        } else if op == 2 {
            let r = m.remove(&k);
            assert(r.is_some() == pos < keys.len());
            if pos < keys.len() {
                assert_eq(r.unwrap(), *vals.at(pos));
                let _ = keys.swap_remove(pos);
                let _ = vals.swap_remove(pos);
            }
        } else {
            *m.entry(k).or_insert(0) += 1;
            if pos < keys.len() {
                vals.set(pos, *vals.at(pos) + 1);
            } else {
                keys.push(k);
                vals.push(1);
            }
        }
        assert_eq(m.len(), keys.len());
    }
    for i in 0..keys.len() {
        assert_eq(*m.get(keys.at(i)).unwrap(), *vals.at(i));
    }
    m.retain(
        fn(k: &u32, v: &mut u32) bool {
            return (*k + *v) % 2 == 0;
        },
    );
    for i in 0..keys.len() {
        let keep = (*keys.at(i) + *vals.at(i)) % 2 == 0;
        assert(m.contains_key(keys.at(i)) == keep);
    }
}

@test
fn reserve_clone_eq_and_format() {
    let mut m = Map::<i64, i64>::new();
    m.reserve(100);
    let cap = m.capacity();
    assert(cap >= 100);
    for i in 0..100 {
        m.insert(i, i * i);
    }
    assert_eq(m.capacity(), cap);
    let c = m.clone();
    assert(c == m);
    let mut d = c.clone();
    d.insert(5, 0);
    assert(d != m);
    let mut small = Map::<i64, i64>::new();
    small.insert(2, 3);
    assert(small.fmt().as_str() == "{2: 3}");
    let e = Map::<i64, i64>::new();
    assert(e.fmt().as_str() == "{}");
}

@test
fn sets_compute_relations_lazily() {
    let mut a = Set::<i64>::new();
    let mut b = Set::<i64>::new();
    for i in 0..10 {
        a.insert(i);
    }
    for i in 5..15 {
        b.insert(i);
    }
    let mut n = 0;
    for _ in a.intersection(&b) {
        n += 1;
    }
    assert_eq(n, 5);
    n = 0;
    for x in a.difference(&b) {
        assert(*x < 5);
        n += 1;
    }
    assert_eq(n, 5);
    n = 0;
    for _ in a.set_union(&b) {
        n += 1;
    }
    assert_eq(n, 15);
    n = 0;
    for x in a.symmetric_difference(&b) {
        assert(*x < 5 || *x >= 10);
        n += 1;
    }
    assert_eq(n, 10);
    let mut c = a.clone();
    c.retain(|x: &i64| *x >= 5);
    assert(c.is_subset(&b));
    assert(b.is_superset(&c));
    assert(!a.is_disjoint(&b));
    assert(a != b);
    assert_eq(*a.get(&3).unwrap(), 3);
    assert_eq(a.take(&3).unwrap(), 3);
    assert(!a.contains(&3));
    let mut t = Set::<String, Global, OneSlot>::new();
    t.insert(String::from_str("x"));
    t.insert(String::from_str("y"));
    t.insert(String::from_str("x"));
    assert_eq(t.len(), 2);
    let kx = String::from_str("x");
    assert(t.take(&kx).unwrap().as_str() == "x");
}

// A stateful allocator that counts its blocks through a pointer to shared counters.
struct Counts {
    pub live: i64,
    pub calls: u64,
}

@derive(Copy)
struct Counting {
    pub c: *mut Counts,
}

extend Counting as Allocator {
    pub unsafe fn alloc(self: &mut Counting, size: usize, align: usize) *mut void {
        unsafe (*self.c).live += 1;
        unsafe (*self.c).calls += 1;
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
fn maps_and_sets_use_the_given_allocator() {
    let mut counts = Counts { live: 0, calls: 0 };
    let cp = (&mut counts) as *mut Counts;
    {
        let mut m = Map::<String, String, Counting>::new_in(Counting { c: cp });
        for i in 0..200 {
            m.insert(s(i), s(i * 2));
        }
        let c = m.clone();
        assert_eq(c.len(), 200);
        let mut st = Set::<i64, Counting, Seeded>::with_hasher_in(Counting { c: cp }, Seeded { seed: 1 });
        for i in 0..50 {
            st.insert(i);
        }
        assert(unsafe (*cp).calls > 0);
    }
    assert_eq(counts.live, 0);
}

// A map built at compile time keeps working: the default builder folds.
const fn folded_lookup() i64 {
    let mut m = Map::<i64, i64>::new();
    for i in 0..20 {
        m.insert(i, i * 3);
    }
    *m.entry(4).or_insert(0) += 1;
    return *m.get(&7).unwrap() * 100 + *m.get(&4).unwrap();
}

const FOLDED: i64 = folded_lookup();

@test
fn maps_fold_at_compile_time() {
    assert_eq(FOLDED, 2113);
}
