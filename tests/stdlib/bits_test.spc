// std::collections::bits: BitSet, BitVec and BitField against a Vector<bool> reference. Every check also
// proves the high-bit invariant: no set bit past the length, seen through `ones`, `count_ones` and `words`.
import std::collections::bits as *;
import std::math::random as *;

// A hasher that records the stream, so a test compares the bytes a value feeds.
struct Tape {
    pub bytes: Vector<u8>,
}

extend Tape {
    fn new() Tape {
        return Tape { bytes: Vector::<u8>::new() };
    }
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

// Counts the calls and the live bytes of the blocks it forwards to Global.
struct Counts {
    pub allocs: usize,
    pub reallocs: usize,
    pub frees: usize,
    pub live: usize,
}

@derive(Copy)
struct Counting {
    pub c: *mut Counts,
}

extend Counting as Allocator {
    pub unsafe fn alloc(self: &mut Counting, size: usize, align: usize) *mut void {
        unsafe {
            (*self.c).allocs += 1;
            (*self.c).live += size;
        }
        let mut g = Global {};
        return unsafe g.alloc(size, align);
    }

    pub unsafe fn realloc(self: &mut Counting, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        unsafe {
            if ptr == null {
                (*self.c).allocs += 1;
            } else {
                (*self.c).reallocs += 1;
            }
            (*self.c).live = (*self.c).live - old_size + new_size;
        }
        let mut g = Global {};
        return unsafe g.realloc(ptr, old_size, new_size, align);
    }

    pub unsafe fn dealloc(self: &mut Counting, ptr: *mut void, size: usize, align: usize) {
        unsafe {
            (*self.c).frees += 1;
            (*self.c).live -= size;
        }
        let mut g = Global {};
        unsafe g.dealloc(ptr, size, align);
    }
}

const fn below(rng: &mut Pcg32, n: usize) usize {
    return rng.next_u32() as usize % n;
}

const fn coin(rng: &mut Pcg32) bool {
    return (rng.next_u32() & 1) != 0;
}

// A random set and its reference, each bit set with probability 1/2, 1/8 or 7/8 by `density`.
fn random_set<const N: usize>(rng: &mut Pcg32, r: &mut Vector<bool>) BitSet<N> {
    let mut s = BitSet::<N>::new();
    let density = rng.next_u32() % 3;
    r.clear();
    for i in 0..N {
        let x = rng.next_u32() % 8;
        let b = if density == 0 {
            x < 4
        } else if density == 1 {
            x == 0
        } else {
            x != 0
        };
        r.push(b);
        s.set(i, b);
    }
    return s;
}

// Every observable view of `s` agrees with `r`; no bit past N exists.
fn check_set<const N: usize>(s: &BitSet<N>, r: &Vector<bool>) {
    assert_eq(r.len(), N);
    let mut count: usize = 0;
    let mut first = Option::<usize>::None;
    let mut last = Option::<usize>::None;
    for i in 0..N {
        assert_eq(s.get(i), *r.at(i));
        assert_eq(s[i], *r.at(i));
        if *r.at(i) {
            count += 1;
            if first.is_none() {
                first = Some(i);
            }
            last = Some(i);
        }
    }
    assert_eq(s.count_ones(), count);
    assert_eq(s.any(), count > 0);
    assert_eq(s.all(), count == N);
    assert_eq(s.first_one(), first);
    assert_eq(s.last_one(), last);
    let mut seen: usize = 0;
    let mut prev: usize = 0;
    for i in s.ones() {
        assert(i < N, "a set bit past N");
        assert(*r.at(i));
        assert(seen == 0 || i > prev);
        prev = i;
        seen += 1;
    }
    assert_eq(seen, count);
}

fn check_vec<A: Allocator>(v: &BitVec<A>, r: &Vector<bool>) {
    assert_eq(v.len(), r.len());
    assert_eq(v.is_empty(), r.is_empty());
    let n = r.len();
    let w = v.words();
    assert_eq(w.len, (n + 63) / 64);
    if n % 64 != 0 {
        assert_eq(*w.at(w.len - 1) >> (n % 64) as u64, 0u64);
    }
    assert(v.capacity() >= n);
    let mut count: usize = 0;
    for i in 0..n {
        assert_eq(v.get(i), *r.at(i));
        assert_eq(v[i], *r.at(i));
        if *r.at(i) {
            count += 1;
        }
    }
    assert_eq(v.count_ones(), count);
    assert_eq(v.any(), count > 0);
    assert_eq(v.all(), count == n);
    let mut seen: usize = 0;
    for i in v.ones() {
        assert(i < n, "a set bit past len");
        assert(*r.at(i));
        seen += 1;
    }
    assert_eq(seen, count);
}

// The reference of `s << k` (`left`) or `s >> k`.
fn shifted(r: &Vector<bool>, k: usize, left: bool) Vector<bool> {
    let mut out = Vector::<bool>::new();
    let n = r.len();
    for i in 0..n {
        let b = if left {
            i >= k && *r.at(i - k)
        } else {
            k < n && i < n - k && *r.at(i + k)
        };
        out.push(b);
    }
    return out;
}

fn exercise_shifts<const N: usize>(rng: &mut Pcg32) {
    let mut r = Vector::<bool>::new();
    let s = random_set::<N>(rng, &mut r);
    let mut ks = Vector::<usize>::new();
    ks.push(0);
    ks.push(1);
    ks.push(63);
    ks.push(64);
    ks.push(65);
    if N > 0 {
        ks.push(N - 1);
    }
    ks.push(N);
    ks.push(N + 1);
    ks.push(N + 200);
    ks.push(usize::MAX);
    for j in 0..ks.len() {
        let k = *ks.at(j);
        let l = s << k;
        let lr = shifted(&r, k, true);
        check_set(&l, &lr);
        let rr = shifted(&r, k, false);
        let rs = s >> k;
        check_set(&rs, &rr);
        let mut m = s;
        m <<= k;
        assert(m == l);
    }
    // The bits shifted out of the top do not come back.
    let f = BitSet::<N>::full();
    if N > 0 {
        let g = f << 1 >> 1;
        assert_eq(g.count_ones(), N - 1);
        assert(!g.get(N - 1));
    }
}

// Random operations on a BitSet and its reference, then the shifts.
fn exercise_set<const N: usize>(seed: u64) {
    let mut rng = Pcg32::new(seed, N as u64);
    let mut r = Vector::<bool>::new();
    for _ in 0..N {
        r.push(false);
    }
    let mut s = BitSet::<N>::new();
    check_set(&s, &r);
    let mut o = Vector::<bool>::new();
    for _ in 0..200 {
        let op = rng.next_u32() % 12;
        if N > 0 && op < 4 {
            let i = below(&mut rng, N);
            if op == 0 {
                s.insert(i);
                r.set(i, true);
            } else if op == 1 {
                s.remove(i);
                r.set(i, false);
            } else if op == 2 {
                s.toggle(i);
                r.set(i, !*r.at(i));
            } else {
                let b = coin(&mut rng);
                s.set(i, b);
                r.set(i, b);
            }
        } else if op == 4 {
            let t = random_set::<N>(&mut rng, &mut o);
            let by_value = s | t;
            s.union_with(&t);
            assert(s == by_value);
            for i in 0..N {
                r.set(i, *r.at(i) || *o.at(i));
            }
        } else if op == 5 {
            let t = random_set::<N>(&mut rng, &mut o);
            let by_value = s & t;
            s.intersect_with(&t);
            assert(s == by_value);
            for i in 0..N {
                r.set(i, *r.at(i) && *o.at(i));
            }
        } else if op == 6 {
            let t = random_set::<N>(&mut rng, &mut o);
            let by_value = s & ~t;
            s.difference_with(&t);
            assert(s == by_value);
            for i in 0..N {
                r.set(i, *r.at(i) && !*o.at(i));
            }
        } else if op == 7 {
            let t = random_set::<N>(&mut rng, &mut o);
            let by_value = s ^ t;
            s.symmetric_difference_with(&t);
            assert(s == by_value);
            for i in 0..N {
                r.set(i, *r.at(i) != *o.at(i));
            }
        } else if op == 8 {
            let by_value = ~s;
            s.toggle_all();
            assert(s == by_value);
            for i in 0..N {
                r.set(i, !*r.at(i));
            }
        } else if op == 9 {
            s.set_all();
            for i in 0..N {
                r.set(i, true);
            }
        } else if op == 10 {
            s.clear_all();
            for i in 0..N {
                r.set(i, false);
            }
        } else {
            let k = below(&mut rng, N + 70);
            let left = coin(&mut rng);
            s = if left {
                s << k
            } else {
                s >> k
            };
            let next = shifted(&r, k, left);
            r = next;
        }
        check_set(&s, &r);
    }
    exercise_shifts::<N>(&mut rng);
}

@test
fn bitset_differential_at_every_size() {
    exercise_set::<0>(1);
    exercise_set::<1>(2);
    exercise_set::<63>(3);
    exercise_set::<64>(4);
    exercise_set::<65>(5);
    exercise_set::<127>(6);
    exercise_set::<128>(7);
    exercise_set::<129>(8);
    exercise_set::<1000>(9);
}

fn exercise_full<const N: usize>() {
    let f = BitSet::<N>::full();
    assert_eq(f.count_ones(), N);
    assert(f.all());
    assert_eq(f.any(), N > 0);
    let e = BitSet::<N>::new();
    assert(e == BitSet::<N>::default());
    assert(e.all() == (N == 0));
    assert(!e.any());
    assert(~f == e);
    assert(~e == f);
    let mut t = f;
    t.toggle_all();
    assert(t == e);
    t.set_all();
    assert(t == f);
    assert_eq(f.to_string().len(), N);
    assert(f.is_superset(&e) && e.is_subset(&f) && e.is_disjoint(&f));
    assert_eq(f.is_disjoint(&f), N == 0);
}

@test
fn bitset_full_and_complement_keep_the_high_bits_clear() {
    exercise_full::<0>();
    exercise_full::<1>();
    exercise_full::<63>();
    exercise_full::<64>();
    exercise_full::<65>();
    exercise_full::<127>();
    exercise_full::<128>();
    exercise_full::<129>();
    exercise_full::<1000>();
}

@test
fn bitset_subset_superset_disjoint() {
    let mut a = BitSet::<130>::new();
    let mut b = BitSet::<130>::new();
    a.insert(3);
    a.insert(129);
    b.insert(3);
    b.insert(129);
    b.insert(64);
    assert(a.is_subset(&b));
    assert(!b.is_subset(&a));
    assert(b.is_superset(&a));
    assert(!a.is_superset(&b));
    assert(a.is_subset(&a) && a.is_superset(&a));
    assert(!a.is_disjoint(&b));
    let mut c = BitSet::<130>::new();
    c.insert(64);
    c.insert(0);
    assert(a.is_disjoint(&c));
    assert(!c.is_disjoint(&b));
}

@test
fn bitset_next_one_scans_words() {
    let mut s = BitSet::<300>::new();
    s.insert(0);
    s.insert(64);
    s.insert(65);
    s.insert(299);
    assert_eq(s.next_one(0), Some(0));
    assert_eq(s.next_one(1), Some(64));
    assert_eq(s.next_one(65), Some(65));
    assert_eq(s.next_one(66), Some(299));
    assert_eq(s.next_one(299), Some(299));
    assert_eq(s.next_one(300), None);
    assert_eq(s.next_one(usize::MAX), None);
    s.remove(299);
    assert_eq(s.next_one(66), None);
    assert_eq(s.last_one(), Some(65));
    let e = BitSet::<300>::new();
    assert_eq(e.first_one(), None);
    assert_eq(e.last_one(), None);
    let z = BitSet::<0>::new();
    assert_eq(z.next_one(0), None);
    assert_eq(z.first_one(), None);
}

// Both ends of one iterator meet without losing or repeating an index.
fn ones_from_both_ends<const N: usize>(seed: u64) {
    let mut rng = Pcg32::new(seed, 99);
    let mut r = Vector::<bool>::new();
    for _ in 0..20 {
        let s = random_set::<N>(&mut rng, &mut r);
        let mut want = Vector::<usize>::new();
        for i in 0..N {
            if *r.at(i) {
                want.push(i);
            }
        }
        let mut front = Vector::<usize>::new();
        let mut back = Vector::<usize>::new();
        let mut it = s.ones();
        let mut done = false;
        while !done {
            let (lo, hi) = it.size_hint();
            let left = want.len() - front.len() - back.len();
            assert(lo <= left);
            assert(hi.unwrap() >= left);
            let x = if coin(&mut rng) {
                it.next()
            } else {
                it.next_back()
            };
            if let Some(i) = x {
                if front.len() + back.len() < want.len() && front.len() < want.len() && *want.at(front.len()) == i {
                    front.push(i);
                } else {
                    back.push(i);
                }
            } else {
                done = true;
            }
        }
        assert(it.next().is_none());
        assert(it.next_back().is_none());
        assert_eq(front.len() + back.len(), want.len());
        // `back` holds the tail in decreasing order.
        let mut k = front.len();
        while back.len() > 0 {
            assert_eq(back.pop().unwrap(), *want.at(k));
            k += 1;
        }
        let mut rev = Vector::<usize>::new();
        let mut it2 = s.ones();
        while let Some(i) = it2.next_back() {
            rev.push(i);
        }
        assert_eq(rev.len(), want.len());
        for j in 0..rev.len() {
            assert_eq(*rev.at(j), *want.at(want.len() - 1 - j));
        }
    }
}

@test
fn ones_is_double_ended() {
    ones_from_both_ends::<0>(1);
    ones_from_both_ends::<1>(2);
    ones_from_both_ends::<63>(3);
    ones_from_both_ends::<64>(4);
    ones_from_both_ends::<65>(5);
    ones_from_both_ends::<129>(6);
    ones_from_both_ends::<1000>(7);
}

@test
fn bitset_u64_round_trip() {
    let a = BitSet::<64>::from_u64(0x8000000000000001).unwrap();
    assert(a.get(0) && a.get(63));
    assert_eq(a.count_ones(), 2);
    assert_eq(a.to_u64(), 0x8000000000000001u64);
    assert_eq(BitSet::<64>::from_u64(u64::MAX).unwrap().to_u64(), u64::MAX);
    let b = BitSet::<63>::from_u64(0x7fffffffffffffff).unwrap();
    assert(b.all());
    assert(BitSet::<63>::from_u64(0x8000000000000000).is_none());
    assert(BitSet::<1>::from_u64(2).is_none());
    assert_eq(BitSet::<1>::from_u64(1).unwrap().to_u64(), 1u64);
    assert(BitSet::<0>::from_u64(1).is_none());
    assert_eq(BitSet::<0>::from_u64(0).unwrap().to_u64(), 0u64);
    assert_eq(BitSet::<10>::full().to_u64(), 1023u64);
}

@test
fn bitset_string_round_trip() {
    let mut s = BitSet::<10>::new();
    s.insert(0);
    s.insert(9);
    s.insert(3);
    assert(s.to_string().eq_str("1000001001"));
    assert(BitSet::<10>::parse("1000001001").unwrap() == s);
    // Fewer digits than N fill the low bits, as C++ does.
    let short = BitSet::<10>::parse("101").unwrap();
    assert_eq(short.to_u64(), 5u64);
    assert_eq(BitSet::<10>::parse("").unwrap().count_ones(), 0);
    assert(BitSet::<0>::parse("").unwrap() == BitSet::<0>::new());
    assert(BitSet::<0>::new().to_string().eq_str(""));
    assert(BitSet::<3>::parse("1x1").unwrap_err() == ParseBitsError::InvalidDigit(1));
    assert(BitSet::<3>::parse("2").unwrap_err() == ParseBitsError::InvalidDigit(0));
    assert(BitSet::<3>::parse("1111").unwrap_err() == ParseBitsError::TooLong);
    assert(BitSet::<0>::parse("0").unwrap_err() == ParseBitsError::TooLong);
    let mut rng = Pcg32::new(5, 5);
    let mut r = Vector::<bool>::new();
    for _ in 0..20 {
        let t = random_set::<1000>(&mut rng, &mut r);
        let text = t.to_string();
        assert_eq(text.len(), 1000);
        assert_eq(text.byte(0) == b'1', *r.at(999));
        assert_eq(text.byte(999) == b'1', *r.at(0));
        assert(BitSet::<1000>::parse(&text).unwrap() == t);
    }
}

@test
fn bitset_value_conformances() {
    let mut a = BitSet::<129>::new();
    a.insert(1);
    a.insert(128);
    let b = a.clone();
    assert(a == b);
    assert_eq(hash(&a), hash(&b));
    assert(a.fmt().eq_str("{1, 128}"));
    assert(BitSet::<5>::new().fmt().eq_str("{}"));
    let mut c = b;
    c.remove(128);
    assert(a != c);
    assert_ne(hash(&a), hash(&c));
    // Bits a .. b as an integer.
    let mut d = BitSet::<200>::new();
    d.insert(60);
    d.insert(63);
    d.insert(64);
    d.insert(70);
    assert_eq(d[60..71], 0b10000011001u64);
    assert_eq(d[60..=70], 0b10000011001u64);
    assert_eq(d[64..64], 0u64);
    assert_eq(d[0..64], 0x9000000000000000u64);
    assert_eq(d[136..200], 0u64);
    assert_eq(BitSet::<64>::full()[0..64], u64::MAX);
    assert_eq(BitSet::<64>::full()[32..64], u64::MAX >> 32);
}

// A BitSet and a BitVec with the same bits feed the same stream and hash equal.
@test
fn bitset_and_bitvec_hash_alike() {
    let mut s = BitSet::<70>::new();
    let mut v = BitVec::<Global>::with_len(70, false);
    s.insert(2);
    s.insert(69);
    v.set(2, true);
    v.set(69, true);
    assert_eq(hash(&s), hash(&v));
    let mut ts = Tape::new();
    s.hash_into(&mut ts);
    let mut tv = Tape::new();
    v.hash_into(&mut tv);
    assert(ts.bytes == tv.bytes);
    assert_eq(ts.bytes.len(), 8 + 2 * 8);
    assert_eq(*ts.bytes.at(0), 70u8);
    let w = BitVec::<Global>::with_len(71, false);
    let mut tw = Tape::new();
    w.hash_into(&mut tw);
    assert(tw.bytes != tv.bytes);
}

@test(should_panic)
fn bitset_get_out_of_range_panics() {
    let s = BitSet::<64>::new();
    let _ = s.get(64);
}

@test(should_panic)
fn bitset_insert_out_of_range_panics() {
    let mut s = BitSet::<0>::new();
    s.insert(0);
}

@test(should_panic)
fn bitset_range_wider_than_64_panics() {
    let s = BitSet::<200>::new();
    let _ = s[0..65];
}

@test(should_panic)
fn bitset_range_past_n_panics() {
    let s = BitSet::<10>::new();
    let _ = s[5..11];
}

// Random BitVec operations against a Vector<bool>, through a counting allocator.
@test
fn bitvec_differential_with_counting_allocator() {
    let mut counts = Counts { allocs: 0, reallocs: 0, frees: 0, live: 0 };
    let al = Counting { c: &mut counts };
    {
        let mut rng = Pcg32::new(77, 3);
        let mut v = BitVec::<Counting>::new_in(al);
        let mut r = Vector::<bool>::new();
        for _ in 0..3000 {
            let op = rng.next_u32() % 14;
            if op < 5 {
                let b = coin(&mut rng);
                v.push(b);
                r.push(b);
            } else if op == 5 {
                assert_eq(v.pop(), r.pop());
            } else if op == 6 && r.len() > 0 {
                let i = below(&mut rng, r.len());
                let b = coin(&mut rng);
                v.set(i, b);
                r.set(i, b);
            } else if op == 7 && r.len() > 0 {
                let i = below(&mut rng, r.len());
                v.toggle(i);
                r.set(i, !*r.at(i));
            } else if op == 8 {
                let n = below(&mut rng, 400);
                let b = coin(&mut rng);
                v.resize(n, b);
                while r.len() > n {
                    let _ = r.pop();
                }
                while r.len() < n {
                    r.push(b);
                }
            } else if op == 9 {
                let n = below(&mut rng, r.len() + 1);
                v.truncate(n);
                r.truncate(n);
            } else if op == 10 {
                v.set_all();
                for i in 0..r.len() {
                    r.set(i, true);
                }
            } else if op == 11 {
                v.toggle_all();
                for i in 0..r.len() {
                    r.set(i, !*r.at(i));
                }
            } else if op == 12 {
                // A set operation with a random vector of the same length.
                let mut o = BitVec::<Counting>::new_in(al);
                let mut ro = Vector::<bool>::new();
                for _ in 0..r.len() {
                    let b = coin(&mut rng);
                    o.push(b);
                    ro.push(b);
                }
                let k = rng.next_u32() % 4;
                let before = v.clone();
                assert(before == v);
                if k == 0 {
                    v.union_with(&o);
                    assert(before.is_subset(&v) && v.is_superset(&o));
                } else if k == 1 {
                    v.intersect_with(&o);
                    assert(v.is_subset(&o) && before.is_superset(&v));
                } else if k == 2 {
                    v.difference_with(&o);
                    assert(v.is_disjoint(&o));
                } else {
                    v.symmetric_difference_with(&o);
                }
                for i in 0..r.len() {
                    let a = *r.at(i);
                    let b = *ro.at(i);
                    let x = if k == 0 {
                        a || b
                    } else if k == 1 {
                        a && b
                    } else if k == 2 {
                        a && !b
                    } else {
                        a != b
                    };
                    r.set(i, x);
                }
            } else {
                v.clear_all();
                for i in 0..r.len() {
                    r.set(i, false);
                }
            }
            check_vec(&v, &r);
        }
        v.clear();
        r.clear();
        check_vec(&v, &r);
        assert(v.capacity() > 0);
        let c = unsafe &*al.c;
        assert(c.live > 0);
    }
    assert_eq(counts.live, 0);
    assert_eq(counts.allocs, counts.frees);
    assert(counts.allocs > 1);
}

// Pushes grow the words geometrically: O(log n) reallocations for n pushes.
@test
fn bitvec_push_grows_geometrically() {
    let mut counts = Counts { allocs: 0, reallocs: 0, frees: 0, live: 0 };
    let al = Counting { c: &mut counts };
    {
        let mut v = BitVec::<Counting>::new_in(al);
        assert_eq(v.capacity(), 0);
        for i in 0..100000 {
            v.push(i % 3 == 0);
        }
        assert_eq(v.len(), 100000);
        assert_eq(v.count_ones(), 33334);
        let c = unsafe &*al.c;
        assert_eq(c.allocs, 1);
        // 1563 words from 1 by doubling: at most 11 moves.
        assert(c.reallocs <= 11);
        assert(v.capacity() >= 100000);
    }
    assert_eq(counts.live, 0);
    assert_eq(counts.frees, 1);
}

@test
fn bitvec_empty_allocates_nothing() {
    let mut counts = Counts { allocs: 0, reallocs: 0, frees: 0, live: 0 };
    let al = Counting { c: &mut counts };
    {
        let v = BitVec::<Counting>::new_in(al);
        let w = BitVec::<Counting>::with_len_in(al, 0, true);
        assert(v == w);
        assert(v.clone() == w);
        assert_eq(v.count_ones(), 0);
        assert(v.all());
        assert(!v.any());
        assert_eq(v.first_one(), None);
        assert_eq(v.ones().next(), None);
        assert(v.fmt().eq_str("{}"));
    }
    assert_eq(counts.allocs, 0);
    assert_eq(counts.frees, 0);
}

fn exercise_vec_len(n: usize) {
    for k in 0..2 {
        let value = k == 1;
        let mut v = BitVec::<Global>::with_len(n, value);
        let mut r = Vector::<bool>::new();
        for _ in 0..n {
            r.push(value);
        }
        check_vec(&v, &r);
        v.toggle_all();
        for i in 0..n {
            r.set(i, !value);
        }
        check_vec(&v, &r);
        v.set_all();
        for i in 0..n {
            r.set(i, true);
        }
        check_vec(&v, &r);
        let c = v.clone();
        assert(c == v);
        assert_eq(hash(&c), hash(&v));
        v.resize(n + 1, false);
        r.push(false);
        check_vec(&v, &r);
        assert(c != v);
        v.push(true);
        r.push(true);
        check_vec(&v, &r);
        assert_eq(v.last_one(), Some(n + 1));
        assert_eq(v.pop(), Some(true));
        assert_eq(v.pop(), Some(false));
        let _ = r.pop();
        let _ = r.pop();
        check_vec(&v, &r);
        assert(c == v);
    }
}

@test
fn bitvec_at_every_size() {
    exercise_vec_len(0);
    exercise_vec_len(1);
    exercise_vec_len(63);
    exercise_vec_len(64);
    exercise_vec_len(65);
    exercise_vec_len(127);
    exercise_vec_len(128);
    exercise_vec_len(129);
    exercise_vec_len(1000);
}

@test
fn bitvec_from_bools_words_and_index() {
    let v: BitVec = [true, false, true, true].into();
    assert_eq(v.len(), 4);
    let vw = v.words();
    assert_eq(vw.len, 1);
    assert_eq(*vw.at(0), 0b1101u64);
    assert_eq(v[0..4], 0b1101u64);
    assert_eq(v[1..=2], 0b10u64);
    assert(v.fmt().eq_str("{0, 2, 3}"));
    assert_eq(v.next_one(1), Some(2));
    assert_eq(v.next_one(4), None);
    let mut w = BitVec::<Global>::with_len(130, false);
    let ww = w.words_mut();
    ww[1] = 0xF0;
    ww[2] = 1;
    assert_eq(w.count_ones(), 5);
    assert_eq(w.first_one(), Some(68));
    assert_eq(w.last_one(), Some(128));
    assert_eq(w[64..128], 0xF0u64);
    assert_eq(w[100..130], 1u64 << 28);
    let d = BitVec::<Global>::default();
    assert(d.is_empty());
    let mut e = BitVec::<Global>::new();
    e.reserve(65);
    assert(e.capacity() >= 65);
    assert(e.is_empty());
}

@test(should_panic)
fn bitvec_length_mismatch_panics() {
    let mut a = BitVec::<Global>::with_len(10, false);
    let b = BitVec::<Global>::with_len(11, false);
    a.union_with(&b);
}

@test(should_panic)
fn bitvec_subset_length_mismatch_panics() {
    let a = BitVec::<Global>::with_len(64, false);
    let b = BitVec::<Global>::with_len(65, false);
    let _ = a.is_subset(&b);
}

@test(should_panic)
fn bitvec_get_out_of_range_panics() {
    let mut v = BitVec::<Global>::new();
    v.push(true);
    let _ = v.get(1);
}

@test(should_panic)
fn bitvec_set_after_truncate_panics() {
    let mut v = BitVec::<Global>::with_len(100, true);
    v.truncate(50);
    v.set(50, true);
}

@test(should_panic)
fn bitvec_reserve_overflow_panics() {
    let mut v = BitVec::<Global>::with_len(1, true);
    v.reserve(usize::MAX);
}

// get(set(w, v)) == v, and the bits outside the field keep their value.
fn field_round_trip<const LO: u32, const WIDTH: u32, T: BitWord>(rng: &mut Pcg32) {
    let max = u64::MAX >> (64 - WIDTH) as u64;
    assert_eq(BitField::<LO, WIDTH>::MASK, max << LO as u64);
    let mut values = Vector::<u64>::new();
    values.push(0);
    values.push(1 & max);
    values.push(max);
    values.push(max >> 1);
    for _ in 0..16 {
        values.push((rng.next_u32() as u64 << 32 | rng.next_u32() as u64) & max);
    }
    for j in 0..values.len() {
        let v = T::word_from_u64(*values.at(j));
        let w = T::word_from_u64(rng.next_u32() as u64 << 32 | rng.next_u32() as u64);
        let u = BitField::<LO, WIDTH>::set(w, v);
        assert_eq(BitField::<LO, WIDTH>::get(u).word_to_u64(), *values.at(j));
        assert_eq(u.word_to_u64() & ~BitField::<LO, WIDTH>::MASK, w.word_to_u64() & ~BitField::<LO, WIDTH>::MASK);
        assert_eq(BitField::<LO, WIDTH>::get(w).word_to_u64(), w.word_to_u64() >> LO as u64 & max);
    }
}

@test
fn bitfield_round_trips_at_every_edge() {
    let mut rng = Pcg32::new(11, 13);
    field_round_trip::<0, 1, u8>(&mut rng);
    field_round_trip::<7, 1, u8>(&mut rng);
    field_round_trip::<0, 8, u8>(&mut rng);
    field_round_trip::<3, 5, u8>(&mut rng);
    field_round_trip::<1, 7, u8>(&mut rng);
    field_round_trip::<0, 16, u16>(&mut rng);
    field_round_trip::<15, 1, u16>(&mut rng);
    field_round_trip::<4, 12, u16>(&mut rng);
    field_round_trip::<0, 32, u32>(&mut rng);
    field_round_trip::<31, 1, u32>(&mut rng);
    field_round_trip::<1, 31, u32>(&mut rng);
    field_round_trip::<0, 64, u64>(&mut rng);
    field_round_trip::<63, 1, u64>(&mut rng);
    field_round_trip::<1, 63, u64>(&mut rng);
    field_round_trip::<32, 32, u64>(&mut rng);
    field_round_trip::<0, 1, usize>(&mut rng);
    field_round_trip::<0, 32, usize>(&mut rng);
    field_round_trip::<31, 1, usize>(&mut rng);
}

type Mode = BitField<4, 3>;

@test
fn bitfield_through_an_alias() {
    let reg: u32 = 0xFFFF_FF8F;
    assert_eq(Mode::get(reg), 0u32);
    let r2 = Mode::set(reg, 5u32);
    assert_eq(r2, 0xFFFF_FFDFu32);
    assert_eq(Mode::get(r2), 5u32);
    assert_eq(Mode::MASK, 0x70u64);
    assert_eq(sizeof(Mode), 0);
    assert_eq(BitField::<0, 8>::set(0u8, 255u8), 255u8);
    assert_eq(BitField::<0, 64>::set(0u64, u64::MAX), u64::MAX);
}

@test(should_panic)
fn bitfield_set_wider_value_panics() {
    let _ = Mode::set(0u8, 8u8);
}

@test(should_panic)
fn bitfield_set_value_one_bit_too_wide_panics() {
    let _ = BitField::<0, 7>::set(0u8, 128u8);
}
