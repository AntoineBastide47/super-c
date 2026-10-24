// The shared sequence algorithms of std/slice.spc (sorting, selection, heaps, searching, rearrangement),
// through the views of Vector, Array and StaticVector: results against simple references over many
// sizes and input patterns, stability, ownership of `Free` elements, scratch through a stateful
// allocator, and the comparison bounds of the complexity contract under adversarial input.

import std::math::random as random;

// Input patterns that defeat naive pivot rules: random, sorted, reversed, all equal, few distinct
// values, organ pipe, sawtooth, and sorted with a few swaps.
const PATTERNS: u32 = 8;

fn pattern(kind: u32, n: usize, seed: u64) Vector<i64> {
    let mut rng = random::Pcg32::new(seed, 7);
    let mut v = Vector::<i64>::with_capacity(n);
    for i in 0..n {
        let x = switch kind {
            0 => (rng.next_u32() % 1000000) as i64,
            1 => i as i64,
            2 => (n - i) as i64,
            3 => 5,
            4 => (rng.next_u32() % 4) as i64,
            5 => if i < n / 2 {
                i as i64;
            } else {
                (n - i) as i64;
            },
            6 => (i % 17) as i64,
            _ => i as i64,
        };
        v.push(x);
    }
    if kind == 7 && n > 2 {
        for _ in 0..3 {
            let a = rng.next_u32() as usize % n;
            let b = rng.next_u32() as usize % n;
            v.swap(a, b);
        }
    }
    return v;
}

// The reference order: insertion sort, obviously correct and stable.
fn reference_sorted(v: &Vector<i64>) Vector<i64> {
    let mut r = v.clone();
    for i in 1..r.len() {
        let mut j = i;
        while j > 0 && *r.at(j - 1) > *r.at(j) {
            r.swap(j - 1, j);
            j -= 1;
        }
    }
    return r;
}

const fn log2_ceil(n: usize) u64 {
    let mut b: u64 = 0;
    let mut p: usize = 1;
    while p < n {
        p = p * 2;
        b += 1;
    }
    return b;
}

fn vec_of(a: []i64) Vector<i64> {
    let mut v = Vector::<i64>::with_capacity(a.len);
    for x in a {
        v.push(x);
    }
    return v;
}

const SIZES: [usize; 14] = [0, 1, 2, 3, 7, 20, 21, 22, 49, 50, 51, 127, 300, 2000];

@test
fn sort_matches_reference_on_every_pattern() {
    for n in SIZES {
        for kind in 0..PATTERNS {
            let mut v = pattern(kind, n, 11 + n as u64);
            let want = reference_sorted(&v);
            v.sort();
            assert(v == want, "sort");
            let mut w = pattern(kind, n, 11 + n as u64);
            w.sort_by(|a: &i64, b: &i64| b.cmp(a));
            w.reverse();
            assert(w == want, "sort_by descending");
            let mut s = pattern(kind, n, 11 + n as u64);
            s.sort_stable();
            assert(s == want, "sort_stable");
        }
    }
}

// A pair sorted by key only: the stable sort keeps the original order of equal keys.
struct Tagged {
    pub key: u32,
    pub pos: u32,
}

@test
fn stable_sort_keeps_the_order_of_equal_keys() {
    let mut rng = random::Pcg32::new(5, 1);
    for n in [0usize, 1, 5, 20, 21, 64, 1000, 5000] {
        let mut v = Vector::<Tagged>::new();
        for i in 0..n {
            v.push(Tagged { key: rng.next_u32() % 13, pos: i as u32 });
        }
        v.sort_stable_by(|a: &Tagged, b: &Tagged| a.key.cmp(&b.key));
        for i in 1..n {
            let a = v.at(i - 1);
            let b = v.at(i);
            assert(a.key < b.key || a.key == b.key && a.pos < b.pos, "stable order");
        }
        let mut k = Vector::<Tagged>::new();
        for i in 0..n {
            k.push(Tagged { key: (n - i) as u32 % 7, pos: i as u32 });
        }
        k.sort_stable_by_key(|t: &Tagged| t.key);
        for i in 1..n {
            assert(
                k.at(i - 1).key < k.at(i).key || k.at(i - 1).key == k.at(i).key && k.at(i - 1).pos < k.at(i).pos,
                "stable by key",
            );
        }
    }
}

fn numbered(n: usize, seed: u64) Vector<String> {
    let mut rng = random::Pcg32::new(seed, 3);
    let mut v = Vector::<String>::new();
    for _ in 0..n {
        let mut s = String::from_str("item-");
        s.push_i64(rng.next_u32() % 500);
        v.push(s);
    }
    return v;
}

const fn strings_sorted(v: &Vector<String>) bool {
    for i in 1..v.len() {
        if v.at(i - 1).as_str() > v.at(i).as_str() {
            return false;
        }
    }
    return true;
}

@test
fn owned_elements_survive_every_algorithm() {
    // Every algorithm moves `String`s bitwise; the leak gate proves none is lost or duplicated.
    for n in [0usize, 1, 2, 19, 21, 50, 300, 1500] {
        let mut a = numbered(n, n as u64);
        a.sort();
        assert(strings_sorted(&a), "sort strings");
        let mut b = numbered(n, n as u64 + 1);
        b.sort_stable();
        assert(strings_sorted(&b), "stable strings");
        let mut c = numbered(n, n as u64 + 2);
        if n > 0 {
            c.as_mut_slice().select_nth_unstable(n / 2);
            for i in 0..n {
                if i < n / 2 {
                    assert(c.at(i).as_str() <= c.at(n / 2).as_str(), "select left");
                } else {
                    assert(c.at(i).as_str() >= c.at(n / 2).as_str(), "select right");
                }
            }
        }
        let mut d = numbered(n, n as u64 + 3);
        d.as_mut_slice().heapify();
        d.as_mut_slice().sort_heap();
        assert(strings_sorted(&d), "heap strings");
        let mut e = numbered(n, n as u64 + 4);
        e.sort();
        e.dedup();
        for i in 1..e.len() {
            assert(e.at(i - 1).as_str() != e.at(i).as_str(), "dedup strings");
        }
        let mut f = numbered(n, n as u64 + 5);
        if n > 1 {
            f.as_mut_slice().rotate_left(n / 3);
            f.as_mut_slice().rotate_right(n / 3);
        }
        let g = numbered(n, n as u64 + 5);
        assert(f == g, "rotations cancel");
    }
}

// A large element: the partition moves it by the Hoare pass instead of the gap pass.
struct Big {
    pub key: i64,
    pub pad: [u64; 16],
}

@test
fn large_elements_take_the_hoare_partition() {
    let mut rng = random::Pcg32::new(9, 9);
    let mut v = Vector::<Big>::new();
    for _ in 0..3000 {
        let k = (rng.next_u32() % 1000) as i64;
        let mut pad: [u64; 16] = [0; 16];
        pad[0] = k as u64;
        v.push(Big { key: k, pad: pad });
    }
    v.sort_by(|a: &Big, b: &Big| a.key.cmp(&b.key));
    for i in 1..v.len() {
        assert(v.at(i - 1).key <= v.at(i).key, "big sorted");
        assert(v.at(i).pad[0] == v.at(i).key as u64, "payload moved with its key");
    }
}

@test
fn zero_sized_elements_sort_without_touching_memory() {
    let mut v = Vector::<Unit>::new();
    for _ in 0..100 {
        v.push(Unit {});
    }
    v.sort_by(|_a: &Unit, _b: &Unit| 0);
    v.sort_stable_by(|_a: &Unit, _b: &Unit| 0);
    assert_eq(v.len(), 100);
}

// McIlroy's adversary ("A Killer Adversary for Quicksort", 1999): values are assigned lazily, so every
// pivot the algorithm picks turns out to be among the smallest remaining. The comparison count of this
// run is the cost on the input it builds.
struct Adversary {
    pub val: Vector<i64>,
    pub gas: i64,
    pub nsolid: i64,
    pub candidate: i64,
    pub count: u64,
}

extend Adversary {
    fn new(n: usize) Adversary {
        let mut val = Vector::<i64>::with_capacity(n);
        for _ in 0..n {
            val.push(n as i64);
        }
        return Adversary { val: val, gas: n as i64, nsolid: 0, candidate: 0, count: 0 };
    }

    fn freeze(self: &mut Adversary, x: i64) {
        self.val.set(x as usize, self.nsolid);
        self.nsolid += 1;
    }

    fn cmp(self: &mut Adversary, x: i64, y: i64) i32 {
        self.count += 1;
        let gx = *self.val.at(x as usize) == self.gas;
        let gy = *self.val.at(y as usize) == self.gas;
        if gx && gy {
            if x == self.candidate {
                self.freeze(x);
            } else {
                self.freeze(y);
            }
        }
        if *self.val.at(x as usize) == self.gas {
            self.candidate = x;
        } else if *self.val.at(y as usize) == self.gas {
            self.candidate = y;
        }
        return self.val.at(x as usize).cmp(self.val.at(y as usize));
    }
}

@test
fn adversarial_input_stays_within_n_log_n() {
    for n in [100usize, 1000, 20000] {
        let mut adv = Adversary::new(n);
        let mut idx = Vector::<i64>::with_capacity(n);
        for i in 0..n {
            idx.push(i as i64);
        }
        idx.sort_by(
            fn(a: &i64, b: &i64) i32 {
                return adv.cmp(*a, *b);
            },
        );
        let bound = 3 * n as u64 * log2_ceil(n);
        assert(adv.count <= bound, "unstable sort comparisons under the adversary");
        for i in 1..n {
            assert(*adv.val.at((*idx.at(i - 1)) as usize) <= *adv.val.at((*idx.at(i)) as usize), "adversary order");
        }
    }
}

fn count_sort_cmps(kind: u32, n: usize, stable: bool) u64 {
    let mut v = pattern(kind, n, 99);
    let mut c: u64 = 0;
    if stable {
        v.sort_stable_by(
            fn(a: &i64, b: &i64) i32 {
                c += 1;
                return a.cmp(b);
            },
        );
    } else {
        v.sort_by(
            fn(a: &i64, b: &i64) i32 {
                c += 1;
                return a.cmp(b);
            },
        );
    }
    return c;
}

@test
fn comparison_counts_meet_the_contract() {
    let n: usize = 20000;
    let nlog = n as u64 * log2_ceil(n);
    for kind in 0..PATTERNS {
        assert(count_sort_cmps(kind, n, false) <= 2 * nlog, "unstable n log n");
        assert(count_sort_cmps(kind, n, true) <= 2 * nlog, "stable n log n");
    }
    // Sorted, reversed and all-equal input finish in linear time.
    for kind in [1u32, 2, 3] {
        assert(count_sort_cmps(kind, n, false) <= 4 * n as u64, "unstable linear on runs");
        assert(count_sort_cmps(kind, n, true) <= 2 * n as u64, "stable linear on runs");
    }
}

fn count_select_cmps(v: &mut Vector<i64>, k: usize) u64 {
    let mut c: u64 = 0;
    v.as_mut_slice().select_nth_unstable_by(
        k,
        fn(a: &i64, b: &i64) i32 {
            c += 1;
            return a.cmp(b);
        },
    );
    return c;
}

@test
fn selection_is_correct_and_linear() {
    for n in SIZES {
        if n == 0 {
            continue;
        }
        for kind in 0..PATTERNS {
            for k in [0usize, n / 3, n / 2, n - 1] {
                let mut v = pattern(kind, n, 3 + k as u64);
                let want = reference_sorted(&v);
                let cmps = count_select_cmps(&mut v, k);
                assert_eq(*v.at(k), *want.at(k));
                for i in 0..n {
                    if i < k {
                        assert(*v.at(i) <= *v.at(k), "nothing greater before k");
                    }
                    if i > k {
                        assert(*v.at(i) >= *v.at(k), "nothing less after k");
                    }
                }
                assert(cmps <= 12 * n as u64 + 64, "linear selection");
            }
        }
    }
    // Under the quicksort adversary, the median of medians keeps the selection linear.
    let n: usize = 20000;
    let mut adv = Adversary::new(n);
    let mut idx = Vector::<i64>::with_capacity(n);
    for i in 0..n {
        idx.push(i as i64);
    }
    idx.as_mut_slice().select_nth_unstable_by(
        n / 2,
        fn(a: &i64, b: &i64) i32 {
            return adv.cmp(*a, *b);
        },
    );
    assert(adv.count <= 40 * n as u64, "selection comparisons under the adversary");
}

@test
fn heap_operations_follow_the_cpp_contract() {
    let mut rng = random::Pcg32::new(17, 2);
    let mut v = Vector::<i64>::new();
    for _ in 0..500 {
        v.push(rng.next_u32() % 1000);
        v.as_mut_slice().push_heap();
        assert(v.as_slice().is_heap(), "push_heap keeps a heap");
    }
    let mut last: i64 = 1000000;
    while v.len() > 0 {
        v.as_mut_slice().pop_heap();
        let top = v.pop().unwrap();
        assert(top <= last, "pop_heap yields the maximum");
        last = top;
        assert(v.as_slice().is_heap(), "pop_heap keeps a heap");
    }
    let mut w = pattern(0, 1000, 4);
    w.as_mut_slice().heapify_by(|a: &i64, b: &i64| b.cmp(a));
    assert(w.as_slice().is_heap_by(|a: &i64, b: &i64| b.cmp(a)), "min-heap by a reversed order");
    w.as_mut_slice().sort_heap_by(|a: &i64, b: &i64| b.cmp(a));
    for i in 1..w.len() {
        assert(*w.at(i - 1) >= *w.at(i), "sort_heap_by descending");
    }
}

@test
fn searches_find_matches_and_insertion_points() {
    let v = vec_of([1, 3, 3, 3, 7, 9]);
    let s = v.as_slice();
    assert(s.binary_search(&3).is_ok());
    let k = s.binary_search(&3).unwrap();
    assert(k >= 1 && k <= 3);
    assert_eq(s.binary_search(&0).unwrap_err(), 0);
    assert_eq(s.binary_search(&4).unwrap_err(), 4);
    assert_eq(s.binary_search(&10).unwrap_err(), 6);
    assert_eq(s.partition_point(|x: &i64| *x < 3), 1);
    assert_eq(s.partition_point(|x: &i64| *x <= 3), 4);
    assert_eq(s.binary_search_by(|x: &i64| x.cmp(&7)).unwrap(), 4);
    assert_eq(s.binary_search_by_key(&18, |x: &i64| *x * 2).unwrap(), 5);
    assert(s.is_sorted());
    assert(s.is_sorted_by_key(|x: &i64| *x / 2));
    assert(!s.is_sorted_by(|a: &i64, b: &i64| b.cmp(a)));
    let empty = Vector::<i64>::new();
    assert_eq(empty.as_slice().binary_search(&1).unwrap_err(), 0);
    assert_eq(empty.as_slice().partition_point(|_x: &i64| true), 0);
    // Every insertion point of a random sorted sequence, against a linear scan.
    let mut r = pattern(4, 300, 8);
    r.sort();
    for t in -1..5 {
        let x = t as i64;
        let mut lin: usize = 0;
        while lin < r.len() && *r.at(lin) < x {
            lin += 1;
        }
        assert_eq(r.as_slice().partition_point(|e: &i64| *e < x), lin);
        switch r.as_slice().binary_search(&x) {
            Ok(i) => assert_eq(*r.at(i), x),
            Err(i) => assert_eq(i, lin),
        };
    }
}

@test
fn partition_dedup_and_rearrangement() {
    let mut v = vec_of([5, 1, 8, 2, 9, 3, 7]);
    let k = v.as_mut_slice().partition(|x: &i64| *x % 2 == 1);
    assert_eq(k, 5);
    assert(v.as_slice().is_partitioned(|x: &i64| *x % 2 == 1));
    let mut d = vec_of([1, 1, 2, 2, 2, 1, 3, 3]);
    let m = d.as_mut_slice().partition_dedup();
    assert_eq(m, 4);
    assert_eq(*d.at(0), 1);
    assert_eq(*d.at(1), 2);
    assert_eq(*d.at(2), 1);
    assert_eq(*d.at(3), 3);
    let mut e = vec_of([10, 11, 20, 21, 22, 30]);
    e.dedup_by_key(|x: &i64| *x / 10);
    assert_eq(e.len(), 3);
    assert_eq(*e.at(2), 30);
    let mut f = vec_of([1, 2, 4, 5, 9]);
    f.dedup_by(|a: &i64, b: &i64| *b - *a == 1);
    assert_eq(f.len(), 3);
    let mut r = vec_of([1, 2, 3, 4, 5]);
    r.as_mut_slice().rotate_left(2);
    assert_eq(*r.at(0), 3);
    assert_eq(*r.at(4), 2);
    r.as_mut_slice().rotate_right(2);
    assert_eq(*r.at(0), 1);
    r.as_mut_slice().rotate_left(0);
    r.as_mut_slice().rotate_left(5);
    assert_eq(*r.at(4), 5);
    r.as_mut_slice().fill(7);
    assert_eq(*r.at(3), 7);
    let src: [i64; 5] = [9, 8, 7, 6, 5];
    r.as_mut_slice().copy_from_slice(src);
    assert_eq(*r.at(0), 9);
    let (a, b) = r.as_slice().split_at(2);
    assert_eq(a.len, 2);
    assert_eq(b.len, 3);
    assert(r.as_slice().starts_with([9, 8]));
    assert(r.as_slice().ends_with([6, 5]));
    assert(r.as_slice().contains(&7));
    for x in r.as_mut_slice().iter_mut() {
        *x = *x + 1;
    }
    assert_eq(*r.at(4), 6);
    let mut back: i64 = 0;
    let mut it = r.as_slice().iter();
    switch it.next_back() {
        Some(x) => {
            back = *x;
        },
        None => {},
    };
    assert_eq(back, 6);
    let (lo, hi) = it.size_hint();
    assert_eq(lo, 4);
    assert(hi.unwrap() == 4);
}

@test
fn fixed_containers_share_the_algorithms() {
    let mut a = Array::<i64, 6>::new();
    a.set(0, 4);
    a.set(1, -2);
    a.set(2, 9);
    a.sort();
    assert(a.is_sorted());
    assert_eq(*a.at(5), 9);
    assert(a.binary_search(&9).is_ok());
    a.sort_by(|x: &i64, y: &i64| y.cmp(x));
    assert_eq(*a.at(0), 9);
    a.sort_by_key(|x: &i64| -*x);
    assert_eq(*a.at(0), 9);
    let mut s = StaticVector::<i64, 8>::new();
    s.push(3);
    s.push(3);
    s.push(1);
    s.push(2);
    s.sort();
    s.dedup();
    assert_eq(s.len(), 3);
    assert(s.binary_search(&2).is_ok());
    s.reverse();
    assert_eq(*s.at(0), 3);
}

// A stateful allocator that counts its blocks through a pointer to shared counters.
struct Counts {
    pub allocs: u64,
    pub frees: u64,
    pub live_bytes: i64,
}

@derive(Copy)
struct Counting {
    pub c: *mut Counts,
}

extend Counting as Allocator {
    pub unsafe fn alloc(self: &mut Counting, size: usize, align: usize) *mut void {
        unsafe (*self.c).allocs += 1;
        unsafe (*self.c).live_bytes += size as i64;
        let mut g = Global {};
        return unsafe g.alloc(size, align);
    }
    pub unsafe fn realloc(self: &mut Counting, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        unsafe (*self.c).live_bytes += new_size as i64 - old_size as i64;
        if ptr == null {
            unsafe (*self.c).allocs += 1;
        }
        let mut g = Global {};
        return unsafe g.realloc(ptr, old_size, new_size, align);
    }
    pub unsafe fn dealloc(self: &mut Counting, ptr: *mut void, size: usize, align: usize) {
        unsafe (*self.c).frees += 1;
        unsafe (*self.c).live_bytes -= size as i64;
        let mut g = Global {};
        unsafe g.dealloc(ptr, size, align);
    }
}

@test
fn stable_sort_scratch_comes_from_the_given_allocator() {
    let mut counts = Counts { allocs: 0, frees: 0, live_bytes: 0 };
    let cp = (&mut counts) as *mut Counts;
    {
        let mut v = Vector::<String, Counting>::new_in(Counting { c: cp });
        for i in 0..200 {
            let mut s = String::from_str("k");
            s.push_i64(i * 7919 % 200);
            v.push(s);
        }
        let before = unsafe (*cp).allocs;
        v.sort_stable_by(|a: &String, b: &String| a.cmp(b));
        assert_eq(unsafe (*cp).allocs, before + 1);
        let mut x = pattern(0, 1000, 1);
        x.as_mut_slice().sort_stable_in(Counting { c: cp });
        assert(x.is_sorted());
    }
    assert_eq(counts.allocs, counts.frees);
    assert_eq(counts.live_bytes, 0);
}

// Sorting at compile time: the unstable sort moves typed elements only.
const fn sorted_five() i64 {
    let mut a = Array::<i64, 5>::new();
    a.set(0, 50);
    a.set(1, 10);
    a.set(2, 40);
    a.set(3, 20);
    a.set(4, 30);
    a.sort();
    return *a.at(0) * 10000 + *a.at(2) * 100 + *a.at(4);
}

const SORTED_FIVE: i64 = sorted_five();

@test
fn sort_runs_at_compile_time() {
    assert_eq(SORTED_FIVE, 103050);
    assert_eq(sorted_five(), SORTED_FIVE);
}

fn radix_case<T: Ord + Copy + Clone>(make: fn(u32) T) {
    let mut rng = random::Pcg32::new(21, 4);
    for n in [511usize, 512, 513, 4000] {
        let mut v = Vector::<T>::new();
        for _ in 0..n {
            v.push(make(rng.next_u32()));
        }
        let mut w = v.clone();
        v.sort_stable();
        w.sort();
        assert(v == w, "radix order equals the comparison order");
    }
}

@test
fn integer_stable_sort_takes_the_radix_path() {
    radix_case(|x: u32| x as i8);
    radix_case(|x: u32| x as u8);
    radix_case(|x: u32| x as i16);
    radix_case(|x: u32| x as u16);
    radix_case(|x: u32| x as i32);
    radix_case(|x: u32| x);
    radix_case(|x: u32| x as i64 * 1000003 - 2000000000000);
    radix_case(|x: u32| x as u64 << 32 | x as u64);
    radix_case(|x: u32| (x % 3) as isize - 1);
    radix_case(|x: u32| x as usize % 7);
}

@test
fn in_place_stable_sort_is_stable_and_allocation_free_by_design() {
    for n in SIZES {
        for kind in 0..PATTERNS {
            let mut v = pattern(kind, n, 31 + n as u64);
            let want = reference_sorted(&v);
            v.sort_stable_in_place();
            assert(v == want, "sort_stable_in_place");
        }
    }
    let mut rng = random::Pcg32::new(6, 6);
    for n in [0usize, 1, 2, 17, 33, 100, 1000, 5000] {
        let mut v = Vector::<Tagged>::new();
        for i in 0..n {
            v.push(Tagged { key: rng.next_u32() % 11, pos: i as u32 });
        }
        v.sort_stable_in_place_by(|a: &Tagged, b: &Tagged| a.key.cmp(&b.key));
        for i in 1..n {
            let a = v.at(i - 1);
            let b = v.at(i);
            assert(a.key < b.key || a.key == b.key && a.pos < b.pos, "in-place stable order");
        }
        let mut k = Vector::<Tagged>::new();
        for i in 0..n {
            k.push(Tagged { key: (n - i) as u32 % 5, pos: i as u32 });
        }
        k.as_mut_slice().sort_stable_in_place_by_key(|t: &Tagged| t.key);
        for i in 1..n {
            assert(
                k.at(i - 1).key < k.at(i).key || k.at(i - 1).key == k.at(i).key && k.at(i - 1).pos < k.at(i).pos,
                "in-place stable by key",
            );
        }
    }
    // Owned elements move by rotations only: none is lost or duplicated (the leak gate checks).
    for n in [0usize, 5, 21, 300, 1500] {
        let mut s = numbered(n, n as u64 + 9);
        s.sort_stable_in_place();
        assert(strings_sorted(&s), "in-place strings");
    }
    let mut a = Array::<i64, 5>::new();
    a.set(0, 3);
    a.set(1, 1);
    a.set(2, 2);
    a.sort_stable_in_place();
    assert(a.is_sorted());
    let mut sv = StaticVector::<i64, 4>::new();
    sv.push(2);
    sv.push(1);
    sv.sort_stable_in_place_by(|x: &i64, y: &i64| x.cmp(y));
    assert_eq(*sv.at(0), 1);
}

@test
fn in_place_stable_sort_meets_its_comparison_bound() {
    let n: usize = 20000;
    let nlog = n as u64 * log2_ceil(n);
    for kind in 0..PATTERNS {
        let mut v = pattern(kind, n, 77);
        let mut c: u64 = 0;
        v.sort_stable_in_place_by(
            fn(a: &i64, b: &i64) i32 {
                c += 1;
                return a.cmp(b);
            },
        );
        assert(c <= 3 * nlog, "in-place stable n log n comparisons");
        assert(v.is_sorted());
    }
}

// Every rotation shape: no buffer (short sequences), the shorter side through the buffer, the side
// difference through the buffer, and the conjoined reversal (both sides and their difference past it).
@test
fn rotations_of_every_shape_match_the_definition() {
    for n in [0usize, 1, 2, 3, 5, 8, 13, 31, 32, 33, 64, 100] {
        for mid in 0..n + 1 {
            let mut v = Vector::<u64>::new();
            for i in 0..n {
                v.push(i as u64);
            }
            v.as_mut_slice().rotate_left(mid);
            for i in 0..n {
                assert_eq(*v.at(i), ((i + mid) % n) as u64);
            }
        }
    }
    for p in [
        (600usize, 1usize),
        (600, 300),
        (600, 599),
        (1500, 700),
        (1500, 1200),
        (3000, 1000),
        (3000, 2100),
        (5000, 2400),
        (5000, 2501),
    ] {
        let (n, mid) = p;
        let mut v = Vector::<u64>::new();
        for i in 0..n {
            v.push(i as u64);
        }
        v.as_mut_slice().rotate_left(mid);
        for i in 0..n {
            assert_eq(*v.at(i), ((i + mid) % n) as u64);
        }
        v.as_mut_slice().rotate_right(mid);
        for i in 0..n {
            assert_eq(*v.at(i), i as u64);
        }
    }
    // Owned elements move bitwise: none is lost or doubled (the leak gate checks).
    let mut s = numbered(2000, 3);
    let first = s.at(0).clone();
    s.as_mut_slice().rotate_left(1300);
    assert(*s.at(700) == first, "owned rotation");
}
