// BTreeMap against a sorted Vector<(K, V)> with binary search (the C++ <flat_map> design), on u64 keys
// at 16, 256 and 65536 elements: insert, lookup hit, lookup miss, in-order iteration and remove. Every
// round does WORK operations (a small structure repeats its pass), so each figure is ns per operation.
// The keys arrive in a pseudo-random order; a lookup or remove visits them in another one.
import std::collections::btree as *;
import std::testing::bench as bench;

const WORK: usize = 65536; // operations per round

// Distinct keys in a pseudo-random order: an odd multiplier is a bijection on u64.
const fn key_of(i: usize) u64 {
    return (i as u64 + 1).wrapping_mul(0x9E3779B97F4A7C15u64);
}

// The visiting order of lookups and removes: 7919 is odd, so it permutes 0..n for a power-of-two n.
const fn probe_of(i: usize, n: usize) usize {
    return i * 7919 % n;
}

fn keys(n: usize) Vector<u64> {
    let mut v = Vector::<u64>::with_capacity(n);
    for i in 0..n {
        v.push(key_of(i));
    }
    return v;
}

fn tree_of(ks: &Vector<u64>) BTreeMap<u64, u64> {
    let mut m = BTreeMap::<u64, u64>::new();
    for i in 0..ks.len() {
        m.insert(*ks.at(i), i as u64);
    }
    return m;
}

// The index of `k` in the sorted pairs, or the index where it would go.
const fn flat_find(v: &Vector<(u64, u64)>, k: u64) (bool, usize) {
    let p = v.as_ptr();
    let mut lo: usize = 0;
    let mut hi = v.len();
    while lo < hi {
        let mid = lo + (hi - lo) / 2;
        if unsafe p[mid]._0 < k {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return (lo < v.len() && unsafe p[lo]._0 == k, lo);
}

fn flat_insert(v: &mut Vector<(u64, u64)>, k: u64, val: u64) {
    let (found, i) = flat_find(v, k);
    if found {
        v.set(i, (k, val));
    } else {
        v.insert(i, (k, val));
    }
}

fn flat_of(ks: &Vector<u64>) Vector<(u64, u64)> {
    let mut v = Vector::<(u64, u64)>::with_capacity(ks.len());
    for i in 0..ks.len() {
        flat_insert(&mut v, *ks.at(i), i as u64);
    }
    return v;
}

fn setup(b: &mut bench::Bencher, n: usize) {
    b.each(WORK as i64);
    if n >= 65536 {
        // A sorted-vector insert or remove pass over 65536 keys is quadratic: fewer, longer rounds.
        b.set_rounds(5);
        b.set_diag_rounds(0);
    }
}

// Each round builds WORK / n structures from empty and drops them outside the clock.
fn btree_insert(b: &mut bench::Bencher, n: usize) {
    setup(b, n);
    let ks = keys(n);
    let mut maps = Vector::<BTreeMap<u64, u64>>::new();
    while b.running() {
        for _ in 0..WORK / n {
            let mut m = BTreeMap::<u64, u64>::new();
            for i in 0..n {
                m.insert(*ks.at(i), i as u64);
            }
            maps.push(m);
        }
        b.pause();
        b.tally(WORK as i64, (maps.len() * n) as i64);
        maps.clear();
        b.resume();
    }
}

fn flat_insert_lane(b: &mut bench::Bencher, n: usize) {
    setup(b, n);
    let ks = keys(n);
    let mut flats = Vector::<Vector<(u64, u64)>>::new();
    while b.running() {
        for _ in 0..WORK / n {
            let mut v = Vector::<(u64, u64)>::new();
            for i in 0..n {
                flat_insert(&mut v, *ks.at(i), i as u64);
            }
            flats.push(v);
        }
        b.pause();
        b.tally(WORK as i64, (flats.len() * n) as i64);
        flats.clear();
        b.resume();
    }
}

fn btree_lookup(b: &mut bench::Bencher, n: usize, hit: bool) {
    setup(b, n);
    let ks = keys(n);
    let m = tree_of(&ks);
    let delta: u64 = if hit {
        0
    } else {
        1
    };
    while b.running() {
        let mut found: i64 = 0;
        for _ in 0..WORK / n {
            for i in 0..n {
                if m.get(&(*ks.at(probe_of(i, n)) + delta)).is_some() {
                    found += 1;
                }
            }
        }
        let want = if hit {
            WORK as i64
        } else {
            0
        };
        b.tally(
            WORK as i64,
            if found == want {
                WORK as i64
            } else {
                0
            },
        );
    }
}

fn flat_lookup(b: &mut bench::Bencher, n: usize, hit: bool) {
    setup(b, n);
    let ks = keys(n);
    let v = flat_of(&ks);
    let delta: u64 = if hit {
        0
    } else {
        1
    };
    while b.running() {
        let mut found: i64 = 0;
        for _ in 0..WORK / n {
            for i in 0..n {
                let (f, _) = flat_find(&v, *ks.at(probe_of(i, n)) + delta);
                if f {
                    found += 1;
                }
            }
        }
        let want = if hit {
            WORK as i64
        } else {
            0
        };
        b.tally(
            WORK as i64,
            if found == want {
                WORK as i64
            } else {
                0
            },
        );
    }
}

fn btree_iterate(b: &mut bench::Bencher, n: usize) {
    setup(b, n);
    let ks = keys(n);
    let m = tree_of(&ks);
    while b.running() {
        let mut seen: i64 = 0;
        let mut sum: u64 = 0;
        for _ in 0..WORK / n {
            for (k, v) in m.iter() {
                sum = sum ^ *k ^ *v;
                seen += 1;
            }
        }
        bench::black_box(sum);
        b.tally(WORK as i64, seen);
    }
}

fn flat_iterate(b: &mut bench::Bencher, n: usize) {
    setup(b, n);
    let ks = keys(n);
    let v = flat_of(&ks);
    while b.running() {
        let mut seen: i64 = 0;
        let mut sum: u64 = 0;
        for _ in 0..WORK / n {
            for e in v.iter() {
                sum = sum ^ e._0 ^ e._1;
                seen += 1;
            }
        }
        bench::black_box(sum);
        b.tally(WORK as i64, seen);
    }
}

// Each round builds WORK / n full structures outside the clock, then empties them.
fn btree_remove(b: &mut bench::Bencher, n: usize) {
    setup(b, n);
    let ks = keys(n);
    let mut maps = Vector::<BTreeMap<u64, u64>>::new();
    while b.running() {
        b.pause();
        maps.clear();
        for _ in 0..WORK / n {
            maps.push(tree_of(&ks));
        }
        b.resume();
        let mut gone: i64 = 0;
        for j in 0..maps.len() {
            let m = &mut maps[j];
            for i in 0..n {
                if m.remove(ks.at(probe_of(i, n))).is_some() {
                    gone += 1;
                }
            }
        }
        b.tally(WORK as i64, gone);
    }
}

fn flat_remove(b: &mut bench::Bencher, n: usize) {
    setup(b, n);
    let ks = keys(n);
    let mut flats = Vector::<Vector<(u64, u64)>>::new();
    while b.running() {
        b.pause();
        flats.clear();
        for _ in 0..WORK / n {
            flats.push(flat_of(&ks));
        }
        b.resume();
        let mut gone: i64 = 0;
        for j in 0..flats.len() {
            let v = &mut flats[j];
            for i in 0..n {
                let (f, at) = flat_find(v, *ks.at(probe_of(i, n)));
                if f {
                    let _ = v.remove(at);
                    gone += 1;
                }
            }
        }
        b.tally(WORK as i64, gone);
    }
}

@bench
pub fn btree_insert_16(b: &mut bench::Bencher) {
    btree_insert(b, 16);
}

@bench
pub fn flat_insert_16(b: &mut bench::Bencher) {
    flat_insert_lane(b, 16);
}

@bench
pub fn btree_insert_256(b: &mut bench::Bencher) {
    btree_insert(b, 256);
}

@bench
pub fn flat_insert_256(b: &mut bench::Bencher) {
    flat_insert_lane(b, 256);
}

@bench
pub fn btree_insert_65536(b: &mut bench::Bencher) {
    btree_insert(b, 65536);
}

@bench
pub fn flat_insert_65536(b: &mut bench::Bencher) {
    flat_insert_lane(b, 65536);
}

@bench
pub fn btree_hit_16(b: &mut bench::Bencher) {
    btree_lookup(b, 16, true);
}

@bench
pub fn flat_hit_16(b: &mut bench::Bencher) {
    flat_lookup(b, 16, true);
}

@bench
pub fn btree_hit_256(b: &mut bench::Bencher) {
    btree_lookup(b, 256, true);
}

@bench
pub fn flat_hit_256(b: &mut bench::Bencher) {
    flat_lookup(b, 256, true);
}

@bench
pub fn btree_hit_65536(b: &mut bench::Bencher) {
    btree_lookup(b, 65536, true);
}

@bench
pub fn flat_hit_65536(b: &mut bench::Bencher) {
    flat_lookup(b, 65536, true);
}

@bench
pub fn btree_miss_16(b: &mut bench::Bencher) {
    btree_lookup(b, 16, false);
}

@bench
pub fn flat_miss_16(b: &mut bench::Bencher) {
    flat_lookup(b, 16, false);
}

@bench
pub fn btree_miss_256(b: &mut bench::Bencher) {
    btree_lookup(b, 256, false);
}

@bench
pub fn flat_miss_256(b: &mut bench::Bencher) {
    flat_lookup(b, 256, false);
}

@bench
pub fn btree_miss_65536(b: &mut bench::Bencher) {
    btree_lookup(b, 65536, false);
}

@bench
pub fn flat_miss_65536(b: &mut bench::Bencher) {
    flat_lookup(b, 65536, false);
}

@bench
pub fn btree_iter_16(b: &mut bench::Bencher) {
    btree_iterate(b, 16);
}

@bench
pub fn flat_iter_16(b: &mut bench::Bencher) {
    flat_iterate(b, 16);
}

@bench
pub fn btree_iter_256(b: &mut bench::Bencher) {
    btree_iterate(b, 256);
}

@bench
pub fn flat_iter_256(b: &mut bench::Bencher) {
    flat_iterate(b, 256);
}

@bench
pub fn btree_iter_65536(b: &mut bench::Bencher) {
    btree_iterate(b, 65536);
}

@bench
pub fn flat_iter_65536(b: &mut bench::Bencher) {
    flat_iterate(b, 65536);
}

@bench
pub fn btree_remove_16(b: &mut bench::Bencher) {
    btree_remove(b, 16);
}

@bench
pub fn flat_remove_16(b: &mut bench::Bencher) {
    flat_remove(b, 16);
}

@bench
pub fn btree_remove_256(b: &mut bench::Bencher) {
    btree_remove(b, 256);
}

@bench
pub fn flat_remove_256(b: &mut bench::Bencher) {
    flat_remove(b, 256);
}

@bench
pub fn btree_remove_65536(b: &mut bench::Bencher) {
    btree_remove(b, 65536);
}

@bench
pub fn flat_remove_65536(b: &mut bench::Bencher) {
    flat_remove(b, 65536);
}
