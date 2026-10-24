// The prelude iterator adapters and consumers (std/iter.spc) and integer ranges as iterators
// (std/range.spc): every adapter forward and backward, size hints through chains of adapters, laziness
// (a source that counts the values it makes), owned String values through every adapter and early-stopping
// consumer under the leak check, ranges at the integer limits, a randomized double-ended differential test
// against index arithmetic, and the comparison bounds of the consumers.

import std::math::random as random;

// Owned Strings "s<lo>".."s<hi - 1>", made on demand from both ends; `made` counts every String made, so
// a test reads it while an adapter owns the source. Copy, so `cycle` restarts it.
struct Gen {
    pub lo: i32,
    pub hi: i32,
    pub made: *mut i32,
}

// A source whose size hint is the default `(0, None)`.
struct Vague {
    pub g: Gen,
}

// A source that owns its values: dropping it frees the ones it has not yielded.
struct Bag {
    pub v: Vector<Option<String>>,
    pub lo: usize,
    pub hi: usize,
}

// A source that is not fused: None on every second call.
struct Blink {
    pub k: i32,
}

// A key whose comparisons are counted.
struct Key {
    pub v: i32,
}

struct Counts {
    pub allocs: usize,
    pub deallocs: usize,
}

// Forwards to `Global` and counts the blocks.
struct Counting {
    pub c: *mut Counts,
}

static mut KEY_CMPS: usize = 0;

fn name(i: i32) String {
    let mut s = String::from_str("s");
    s.push_i64(i);
    return s;
}

const fn gen(lo: i32, hi: i32, made: &mut i32) Gen {
    return Gen { lo: lo, hi: hi, made: made };
}

fn bag(n: usize) Bag {
    let mut v = Vector::<Option<String>>::new();
    for i in 0..n {
        v.push(Option::<String>::Some(name(i as i32)));
    }
    return Bag { v: v, lo: 0, hi: n };
}

// The values of `it`, rendered and joined with ','.
fn show<I: Iterator<T>, T: Format>(it: I) String {
    let mut i = it;
    let mut s = String::new();
    let mut first = true;
    while let Some(x) = i.next() {
        if !first {
            s.push_str(",");
        }
        first = false;
        let f = x.fmt();
        s.push_string(&f);
    }
    return s;
}

// The values of `it` taken from its back.
fn show_back<I: DoubleEndedIterator<T>, T: Format>(it: I) String {
    return show(rev(it));
}

fn check(got: String, want: str) {
    assert_eq(got.as_str(), want);
}

fn hint_is<I: Iterator<T>, T>(it: &I, lo: usize, hi: Option<usize>) {
    let (l, h) = it.size_hint();
    assert_eq(l, lo);
    assert(h == hi);
}

fn exact_is<I: Iterator<T>, T>(it: &I, n: usize) {
    hint_is(it, n, Option::<usize>::Some(n));
}

// The same checks on an iterator the caller does not keep.
fn hint_of_value<I: Iterator<T>, T>(it: I, lo: usize, hi: Option<usize>) {
    hint_is(&it, lo, hi);
}

fn exact_of_value<I: Iterator<T>, T>(it: I, n: usize) {
    exact_is(&it, n);
}

fn ints(n: i32) Vector<i32> {
    let mut v = Vector::<i32>::new();
    for i in 0..n {
        v.push(i);
    }
    return v;
}

const fn is_even(x: &i32) bool {
    return *x % 2 == 0;
}

const fn long_name(s: &String) bool {
    return s.len() > 2;
}

extend Gen as Iterator<String> {
    pub fn next(self: &mut Gen) Option<String> {
        if self.lo >= self.hi {
            return Option::<String>::None;
        }
        unsafe *self.made += 1;
        self.lo += 1;
        return Option::<String>::Some(name(self.lo - 1));
    }

    pub fn size_hint(self: &Gen) (usize, Option<usize>) {
        let n: usize = if self.lo < self.hi {
            (self.hi - self.lo) as usize;
        } else {
            0;
        };
        return n, Option::<usize>::Some(n);
    }
}

extend Gen as DoubleEndedIterator<String> {
    pub fn next_back(self: &mut Gen) Option<String> {
        if self.lo >= self.hi {
            return Option::<String>::None;
        }
        unsafe *self.made += 1;
        self.hi -= 1;
        return Option::<String>::Some(name(self.hi));
    }
}

extend Vague as Iterator<String> {
    pub fn next(self: &mut Vague) Option<String> {
        return self.g.next();
    }
}

extend Vague as DoubleEndedIterator<String> {
    pub fn next_back(self: &mut Vague) Option<String> {
        return self.g.next_back();
    }
}

extend Bag as Iterator<String> {
    pub fn next(self: &mut Bag) Option<String> {
        if self.lo >= self.hi {
            return Option::<String>::None;
        }
        self.lo += 1;
        return self.v[self.lo - 1].take();
    }

    pub fn size_hint(self: &Bag) (usize, Option<usize>) {
        return self.hi - self.lo, Option::<usize>::Some(self.hi - self.lo);
    }
}

extend Bag as DoubleEndedIterator<String> {
    pub fn next_back(self: &mut Bag) Option<String> {
        if self.lo >= self.hi {
            return Option::<String>::None;
        }
        self.hi -= 1;
        return self.v[self.hi].take();
    }
}

extend Blink as Iterator<i32> {
    pub fn next(self: &mut Blink) Option<i32> {
        self.k += 1;
        if self.k % 2 == 0 {
            return Option::<i32>::None;
        }
        return Option::<i32>::Some(self.k);
    }
}

extend Key as Eq {
    pub fn eq(self: &Key, other: &Key) bool {
        unsafe KEY_CMPS += 1;
        return self.v == other.v;
    }
}

extend Key as Ord {
    pub fn cmp(self: &Key, other: &Key) i32 {
        unsafe KEY_CMPS += 1;
        return self.v.cmp(&other.v);
    }
}

extend Counting as Allocator {
    pub unsafe fn alloc(self: &mut Counting, size: usize, align: usize) *mut void {
        (*self.c).allocs += 1;
        let mut g = Global {};
        return g.alloc(size, align);
    }

    pub unsafe fn realloc(self: &mut Counting, ptr: *mut void, old_size: usize, new_size: usize, align: usize) *mut void {
        let mut g = Global {};
        return g.realloc(ptr, old_size, new_size, align);
    }

    pub unsafe fn dealloc(self: &mut Counting, ptr: *mut void, size: usize, align: usize) {
        (*self.c).deallocs += 1;
        let mut g = Global {};
        g.dealloc(ptr, size, align);
    }
}

@test
fn map_forward_backward_and_lazy() {
    let mut made = 0;
    let mut m = map(gen(0, 4, &mut made), |s: String| s.len());
    assert_eq(made, 0);
    exact_is(&m, 4);
    assert_eq(m.next().unwrap(), 2);
    assert_eq(made, 1);
    exact_is(&m, 3);
    assert_eq(m.next_back().unwrap(), 2);
    assert_eq(made, 2);
    check(show(m), "2,2");
    check(show_back(map(0..4, |x: i32| x * 10)), "30,20,10,0");
    let v = ints(3);
    check(show(map(v.iter(), |x: &i32| *x + 1)), "1,2,3");
}

@test
fn filter_forward_backward_and_hint() {
    let v = ints(10);
    let f = filter(v.iter(), |x: &&i32| **x % 3 == 0);
    hint_is(&f, 0, Option::<usize>::Some(10));
    check(show(copied(f)), "0,3,6,9");
    check(show_back(filter(0..10, is_even)), "8,6,4,2,0");
    let mut made = 0;
    check(show(filter(gen(8, 12, &mut made), long_name)), "s10,s11");
    assert_eq(made, 4);
    check(show_back(filter(bag(12), long_name)), "s11,s10");
}

@test
fn enumerate_counts_from_both_ends() {
    let mut made = 0;
    let mut e = enumerate(gen(0, 4, &mut made));
    exact_is(&e, 4);
    let (i, s) = e.next().unwrap();
    assert_eq(i, 0);
    check(s, "s0");
    let (j, t) = e.next_back().unwrap();
    assert_eq(j, 3);
    check(t, "s3");
    check(show(e), "(1, s1),(2, s2)");
    check(show_back(enumerate(10..13)), "(2, 12),(1, 11),(0, 10)");
}

@test(should_panic)
fn enumerate_next_back_needs_an_exact_hint() {
    let mut made = 0;
    let mut e = enumerate(Vague { g: gen(0, 3, &mut made) });
    let _ = e.next_back();
}

@test
fn zip_trims_the_longer_side_from_the_back() {
    let mut made = 0;
    let z = zip(0..3, gen(0, 5, &mut made));
    exact_is(&z, 3);
    check(show_back(z), "(2, s2),(1, s1),(0, s0)");
    assert_eq(made, 5);
    let v = ints(4);
    let mut z2 = zip(copied(v.iter()), bag(2));
    hint_is(&z2, 2, Option::<usize>::Some(2));
    let (a, s) = z2.next_back().unwrap();
    assert_eq(a, 1);
    check(s, "s1");
    check(show(z2), "(0, s0)");
    check(show(zip(0..10, 5..7)), "(0, 5),(1, 6)");
}

@test
fn take_stops_pulling_the_source() {
    let mut made = 0;
    let mut t = take(gen(0, 100, &mut made), 3);
    exact_is(&t, 3);
    check(show(t), "s0,s1,s2");
    assert_eq(made, 3);
    check(show_back(take(gen(0, 10, &mut made), 3)), "s2,s1,s0");
    check(show_back(take(0..2, 5)), "1,0");
    exact_of_value(take(0..2, 5), 2);
    hint_of_value(take(Vague { g: gen(0, 1, &mut made) }, 4), 0, Option::<usize>::Some(4));
    exact_of_value(take(0..9, 0), 0);
    let mut b = take(bag(6), 4);
    check(b.next_back().unwrap(), "s3");
    check(b.next().unwrap(), "s0");
    check(show(b), "s1,s2");
    let mut z = 0;
    t = take(gen(0, 3, &mut z), 0);
    assert(t.next().is_none());
    assert_eq(z, 0);
}

@test
fn skip_drops_the_front_once() {
    let mut made = 0;
    let s = skip(gen(0, 6, &mut made), 4);
    exact_is(&s, 2);
    check(show(s), "s4,s5");
    assert_eq(made, 6);
    check(show_back(skip(0..6, 4)), "5,4");
    check(show(skip(0..3, 5)), "");
    exact_of_value(skip(0..3, 5), 0);
    let mut b = skip(bag(5), 2);
    check(b.next_back().unwrap(), "s4");
    check(b.next().unwrap(), "s2");
    check(b.next_back().unwrap(), "s3");
    assert(b.next_back().is_none());
}

@test
fn chain_joins_and_meets_in_the_middle() {
    let mut made = 0;
    let c = chain(gen(0, 2, &mut made), bag(3));
    exact_is(&c, 5);
    check(show(c), "s0,s1,s0,s1,s2");
    check(show_back(chain(0..2, 5..7)), "6,5,1,0");
    let mut m = chain(0..2, 5..7);
    assert_eq(m.next().unwrap(), 0);
    assert_eq(m.next_back().unwrap(), 6);
    assert_eq(m.next_back().unwrap(), 5);
    exact_is(&m, 1);
    assert_eq(m.next_back().unwrap(), 1);
    assert(m.next().is_none());
    assert(m.next_back().is_none());
    hint_of_value(chain(0..usize::MAX, 0usize..2), usize::MAX, Option::<usize>::None);
    let mut early = chain(bag(2), bag(2));
    check(early.next().unwrap(), "s0");
}

@test
fn rev_swaps_the_ends() {
    let v = ints(4);
    check(show(rev(copied(v.iter()))), "3,2,1,0");
    check(show(rev(rev(0..3))), "0,1,2");
    let mut r = rev(bag(3));
    exact_is(&r, 3);
    check(r.next_back().unwrap(), "s0");
    check(show(r), "s2,s1");
}

fn twice(s: String) Bag {
    let mut v = Vector::<Option<String>>::new();
    v.push(Option::<String>::Some(s.clone()));
    v.push(Option::<String>::Some(s));
    return Bag { v: v, lo: 0, hi: 2 };
}

@test
fn flat_map_and_flatten_walk_inner_iterators() {
    check(show(flat_map(0..4, |n: i32| 0..n)), "0,0,1,0,1,2");
    check(show_back(flat_map(0..4, |n: i32| 0..n)), "2,1,0,1,0,0");
    let mut m = flat_map(1..4, |n: i32| 0..n);
    hint_is(&m, 0, Option::<usize>::None);
    assert_eq(m.next().unwrap(), 0);
    assert_eq(m.next_back().unwrap(), 2);
    assert_eq(m.next_back().unwrap(), 1);
    assert_eq(m.next_back().unwrap(), 0);
    assert_eq(m.next().unwrap(), 0);
    exact_is(&m, 1);
    assert_eq(m.next().unwrap(), 1);
    assert(m.next().is_none());
    assert(m.next_back().is_none());
    let mut made = 0;
    let mut owned = flat_map(gen(0, 3, &mut made), twice);
    check(owned.next().unwrap(), "s0");
    check(owned.next_back().unwrap(), "s2");
    assert_eq(made, 2);
    check(show(take(owned, 3)), "s0,s1,s1");
    check(show(flatten(map(0..3, |n: i32| n..3))), "0,1,2,1,2,2");
    check(show_back(flatten(map(0..3, |n: i32| n..3))), "2,2,1,2,1,0");
    check(show(flatten(map(0..3, |_n: i32| 0..0))), "");
    made = 0;
    let mut fl = flatten(map(gen(0, 4, &mut made), twice));
    check(fl.next_back().unwrap(), "s3");
    check(fl.next().unwrap(), "s0");
    assert_eq(made, 2);
    check(show(take(fl, 2)), "s0,s1");
}

@test
fn take_while_skip_while_map_while() {
    let mut made = 0;
    let t = take_while(gen(8, 20, &mut made), |s: &String| s.len() < 3);
    check(show(t), "s8,s9");
    assert_eq(made, 3);
    let mut tw = take_while(0..10, |x: &i32| *x < 2);
    assert_eq(tw.next().unwrap(), 0);
    assert_eq(tw.next().unwrap(), 1);
    assert(tw.next().is_none());
    exact_is(&tw, 0);
    let s = skip_while(gen(8, 12, &mut made), |s: &String| s.len() < 3);
    hint_is(&s, 0, Option::<usize>::Some(4));
    check(show(s), "s10,s11");
    let mut sw = skip_while(0..6, |x: &i32| *x < 3);
    assert_eq(sw.next().unwrap(), 3);
    exact_is(&sw, 2);
    check(
        show(
            map_while(
                0..10,
                |x: i32| if x < 3 {
                    Option::<i32>::Some(x * 2);
                } else {
                    Option::<i32>::None;
                },
            ),
        ),
        "0,2,4",
    );
    hint_of_value(map_while(0..10, |x: i32| Option::<i32>::Some(x)), 0, Option::<usize>::Some(10));
    check(
        show(
            map_while(
                bag(4),
                |s: String| if s.len() < 2 {
                    Option::<String>::Some(s);
                } else {
                    Option::<String>::None;
                },
            ),
        ),
        "",
    );
}

@test
fn step_by_keeps_the_grid_from_both_ends() {
    let s = step_by(0..10, 3);
    exact_is(&s, 4);
    check(show(s), "0,3,6,9");
    check(show_back(step_by(0..10, 3)), "9,6,3,0");
    check(show_back(step_by(0..9, 3)), "6,3,0");
    let mut m = step_by(0..10, 3);
    assert_eq(m.next().unwrap(), 0);
    exact_is(&m, 3);
    assert_eq(m.next_back().unwrap(), 9);
    assert_eq(m.next_back().unwrap(), 6);
    assert_eq(m.next().unwrap(), 3);
    assert(m.next().is_none());
    let mut z = step_by(0..2, 3);
    assert_eq(z.next().unwrap(), 0);
    assert(z.next_back().is_none());
    check(show(step_by(0..1, 5)), "0");
    exact_of_value(step_by(0..0, 5), 0);
    let mut made = 0;
    check(show(step_by(gen(0, 7, &mut made), 2)), "s0,s2,s4,s6");
    assert_eq(made, 7);
    check(show_back(step_by(bag(7), 4)), "s4,s0");
}

@test(should_panic)
fn step_by_zero_panics() {
    let _ = step_by(0..3, 0);
}

@test
fn peekable_shows_the_next_value() {
    let mut made = 0;
    let mut p = peekable(gen(0, 3, &mut made));
    exact_is(&p, 3);
    assert_eq(p.peek().unwrap().as_str(), "s0");
    assert_eq(p.peek().unwrap().as_str(), "s0");
    assert_eq(made, 1);
    exact_is(&p, 3);
    assert(p.next_if(|s: &String| s.len() > 5).is_none());
    check(p.next_if(|s: &String| s.len() == 2).unwrap(), "s0");
    assert_eq(p.peek().unwrap().as_str(), "s1");
    check(p.next_back().unwrap(), "s2");
    check(p.next_back().unwrap(), "s1");
    assert(p.next_back().is_none());
    assert(p.peek().is_none());
    exact_is(&p, 0);
    assert(p.next().is_none());
    let mut q = peekable(0..3);
    assert_eq(*q.peek().unwrap(), 0);
    check(show_back(q), "2,1,0");
    let mut held = peekable(bag(3));
    assert(held.peek().is_some());
}

@test
fn inspect_sees_each_value_once() {
    let mut seen = 0;
    let p = (&mut seen) as *mut i32;
    let mut it = inspect(bag(4), |s: &String| unsafe *p += s.len() as i32);
    check(it.next().unwrap(), "s0");
    check(it.next_back().unwrap(), "s3");
    assert_eq(seen, 4);
    exact_is(&it, 2);
    check(show(it), "s1,s2");
    assert_eq(seen, 8);
}

@test
fn fuse_stops_at_the_first_none() {
    let mut b = Blink { k: 0 };
    assert(b.next().is_some());
    assert(b.next().is_none());
    assert(b.next().is_some());
    let mut f = fuse(Blink { k: 0 });
    assert_eq(f.next().unwrap(), 1);
    assert(f.next().is_none());
    assert(f.next().is_none());
    exact_is(&f, 0);
    let mut g = fuse(0..3);
    assert_eq(g.next_back().unwrap(), 2);
    exact_is(&g, 2);
    check(show(g), "0,1");
    let mut h = fuse(bag(3));
    check(h.next_back().unwrap(), "s2");
    check(h.next().unwrap(), "s0");
}

@test
fn cycle_restarts_a_copy() {
    let v = ints(3);
    check(show(take(cycle(copied(v.iter())), 7)), "0,1,2,0,1,2,0");
    let mut made = 0;
    check(show(take(cycle(gen(0, 2, &mut made)), 5)), "s0,s1,s0,s1,s0");
    assert_eq(made, 5);
    let mut e = cycle(0..0);
    assert(e.next().is_none());
    exact_is(&e, 0);
    hint_of_value(cycle(0..2), usize::MAX, Option::<usize>::None);
    hint_of_value(cycle(Blink { k: 0 }), 0, Option::<usize>::None);
}

@test
fn scan_threads_a_state() {
    check(
        show(
            scan(
                1..6,
                0,
                fn(acc: &mut i32, x: i32) Option<i32> {
                    *acc += x;
                    return Option::<i32>::Some(*acc);
                },
            ),
        ),
        "1,3,6,10,15",
    );
    let mut made = 0;
    let s = scan(
        gen(0, 9, &mut made),
        String::new(),
        fn(acc: &mut String, x: String) Option<String> {
            if acc.len() >= 4 {
                return Option::<String>::None;
            }
            acc.push_string(&x);
            return Option::<String>::Some(acc.clone());
        },
    );
    hint_is(&s, 0, Option::<usize>::Some(9));
    check(show(s), "s0,s0s1");
    assert_eq(made, 3);
}

@test
fn copied_and_cloned_borrowing_sources() {
    let v = ints(5);
    assert_eq(max(copied(v.iter())).unwrap(), 4);
    check(show_back(copied(v.iter())), "4,3,2,1,0");
    exact_of_value(copied(v.iter()), 5);
    let mut w = Vector::<String>::new();
    w.push(name(1));
    w.push(name(2));
    let c = collect(cloned(w.iter()));
    assert_eq(c.len(), 2);
    check(show_back(cloned(w.iter())), "s2,s1");
    assert_eq(w.at(0).as_str(), "s1");
}

@test
fn hints_stay_exact_through_chains_of_adapters() {
    let v = ints(100);
    let p = enumerate(rev(take(skip(map(v.iter(), |x: &i32| *x * 2), 10), 50)));
    exact_is(&p, 50);
    assert_eq(count(p), 50);
    let q = step_by(chain(zip(0..40, copied(v.iter())), zip(0..7, 0..9)), 4);
    exact_is(&q, 12);
    assert_eq(count(q), 12);
    let r = fuse(inspect(peekable(cloned(v.iter())), |x: &i32| assert(*x >= 0)));
    exact_is(&r, 100);
    let f = filter(take(0..usize::MAX, 9), |x: &usize| *x > 3);
    hint_is(&f, 0, Option::<usize>::Some(9));
}

@test
fn fold_reduce_for_each_count() {
    assert_eq(fold(0..5, 0, |a: i32, x: i32| a + x), 10);
    let mut made = 0;
    let joined = fold(
        gen(0, 3, &mut made),
        String::new(),
        fn(a: String, x: String) String {
            let mut s = a;
            s.push_string(&x);
            return s;
        },
    );
    check(joined, "s0s1s2");
    assert_eq(reduce(1..5, |a: i32, x: i32| a * x).unwrap(), 24);
    assert(reduce(0..0, |a: i32, x: i32| a + x).is_none());
    check(
        reduce(
            bag(3),
            |a: String, x: String| if a.len() >= x.len() {
                a;
            } else {
                x;
            },
        ).unwrap(),
        "s0",
    );
    let mut n = 0;
    let p = (&mut n) as *mut i32;
    for_each(bag(4), |s: String| unsafe *p += s.len() as i32);
    assert_eq(n, 8);
    assert_eq(count(bag(7)), 7);
    assert_eq(count(0..0), 0);
}

@test
fn collect_reserves_the_lower_hint() {
    let v = collect(map(0..37, |x: i32| x));
    assert_eq(v.len(), 37);
    assert_eq(v.capacity(), 37);
    let w = collect(bag(5));
    assert_eq(w.len(), 5);
    assert_eq(w.at(4).as_str(), "s4");
    let e = collect(0..0);
    assert_eq(e.len(), 0);
    let mut c = Counts { allocs: 0, deallocs: 0 };
    {
        let a = Counting { c: &mut c };
        let s = collect_in(take(bag(9), 6), a);
        assert_eq(s.len(), 6);
        assert_eq(s.at(5).as_str(), "s5");
        assert_eq(s.capacity(), 6);
    }
    assert_eq(c.allocs, 1);
    assert_eq(c.deallocs, 1);
}

const fn parse_digit(s: String) Result<i32, String> {
    let b = s.as_str().byte_at(1);
    if b >= b'0' && b <= b'4' {
        return Result::<i32, String>::Ok(b - b'0');
    }
    return Result::<i32, String>::Err(s);
}

@test
fn try_collect_stops_at_the_first_failure() {
    let mut made = 0;
    let ok = try_collect(map(gen(0, 5, &mut made), parse_digit));
    assert_eq(ok.unwrap().len(), 5);
    made = 0;
    let bad = try_collect(map(gen(2, 9, &mut made), parse_digit));
    check(bad.unwrap_err(), "s5");
    assert_eq(made, 4);
    let owned = try_collect(
        map(
            bag(8),
            |s: String| if s.as_str() != "s5" {
                Result::<String, i32>::Ok(s);
            } else {
                Result::<String, i32>::Err(7);
            },
        ),
    );
    assert_eq(owned.unwrap_err(), 7);
    let strs = try_collect(map(bag(3), |s: String| Result::<String, i32>::Ok(s)));
    assert_eq(strs.unwrap().len(), 3);
    let some = try_collect_option(map(0..4, |x: i32| Option::<i32>::Some(x)));
    assert_eq(some.unwrap().len(), 4);
    let none = try_collect_option(
        map(
            bag(6),
            |s: String| if s.as_str() != "s3" {
                Option::<String>::Some(s);
            } else {
                Option::<String>::None;
            },
        ),
    );
    assert(none.is_none());
}

@test
fn partition_and_unzip() {
    let (even, odd) = partition(0..7, is_even);
    assert_eq(even.len(), 4);
    assert_eq(odd.len(), 3);
    assert_eq(*odd.at(2), 5);
    let (long, short) = partition(bag(12), long_name);
    assert_eq(short.len(), 10);
    assert_eq(long.at(1).as_str(), "s11");
    let (a, b) = unzip(zip(0..3, bag(3)));
    assert_eq(*a.at(2), 2);
    assert_eq(b.at(2).as_str(), "s2");
    assert_eq(a.capacity(), 3);
}

@test
fn short_circuit_consumers_stop_and_drop_the_rest() {
    let mut made = 0;
    assert(any(gen(0, 100, &mut made), |s: &String| s.as_str() == "s3"));
    assert_eq(made, 4);
    made = 0;
    assert(!all(gen(0, 100, &mut made), |s: &String| s.len() == 2 && s.as_str() != "s1"));
    assert_eq(made, 2);
    assert(all(0..0, is_even));
    assert(!any(0..0, is_even));
    made = 0;
    check(find(gen(5, 100, &mut made), long_name).unwrap(), "s10");
    assert_eq(made, 6);
    assert(find(bag(3), long_name).is_none());
    assert(any(bag(30), |s: &String| s.as_str() == "s2"));
    made = 0;
    let fm = find_map(
        gen(0, 100, &mut made),
        |s: String| if s.as_str() == "s2" {
            Option::<String>::Some(s);
        } else {
            Option::<String>::None;
        },
    );
    check(fm.unwrap(), "s2");
    assert_eq(made, 3);
    made = 0;
    assert_eq(position(gen(0, 50, &mut made), |s: &String| s.as_str() == "s4").unwrap(), 4);
    assert_eq(made, 5);
    assert(position(0..3, |x: &i32| *x > 5).is_none());
    made = 0;
    check(nth(gen(0, 50, &mut made), 6).unwrap(), "s6");
    assert_eq(made, 7);
    assert(nth(bag(3), 3).is_none());
    check(nth(bag(9), 0).unwrap(), "s0");
    check(last(bag(4)).unwrap(), "s3");
    assert(last(0..0).is_none());
}

@test
fn min_max_take_the_first_and_last_of_equals() {
    assert_eq(min(copied(ints(5).iter())).unwrap(), 0);
    assert_eq(max(rev(0..5)).unwrap(), 4);
    assert(min(0..0).is_none());
    check(max(bag(12)).unwrap(), "s9");
    let v: Vector<String> = [
        String::from_str("bb"),
        String::from_str("a"),
        String::from_str("cc"),
        String::from_str("d"),
    ].into();
    check(min_by_key(cloned(v.iter()), |s: &String| s.len()).unwrap(), "a");
    check(max_by_key(cloned(v.iter()), |s: &String| s.len()).unwrap(), "cc");
    check(min_by(cloned(v.iter()), |a: &String, b: &String| a.len() as i32 - b.len() as i32).unwrap(), "a");
    check(max_by(cloned(v.iter()), |a: &String, b: &String| a.len() as i32 - b.len() as i32).unwrap(), "cc");
    check(max_by_key(bag(3), |s: &String| s.len()).unwrap(), "s2");
}

@test
fn eq_cmp_is_sorted() {
    let v = ints(4);
    assert(eq(copied(v.iter()), 0..4));
    assert(!eq(copied(v.iter()), 0..3));
    assert(!eq(0..3, copied(v.iter())));
    assert(eq(bag(3), map(0..3, name)));
    assert_eq(cmp(0..3, 0..3), 0);
    assert(cmp(0..3, 0..4) < 0);
    assert(cmp(0..4, 0..3) > 0);
    assert(cmp(0..3, 1..2) < 0);
    assert(cmp(bag(2), bag(3)) < 0);
    assert(is_sorted(0..10));
    assert(is_sorted(0..0));
    assert(!is_sorted(rev(0..3)));
    assert(is_sorted(map(0..5, |x: i32| x / 2)));
    assert(!is_sorted(bag(11)));
}

@test
fn ranges_iterate_to_the_integer_limits() {
    check(show(rev(250u8..=255u8)), "255,254,253,252,251,250");
    exact_is(&(250u8..=255u8), 6);
    assert_eq(count(0u8..=255u8), 256);
    assert_eq(count(rev(-128i8..=127i8)), 256);
    assert_eq(count(i16::MIN..=i16::MAX), 65536);
    check(show(rev(u64::MAX - 2..=u64::MAX)), "18446744073709551615,18446744073709551614,18446744073709551613");
    check(show(i64::MAX - 1..=i64::MAX), "9223372036854775806,9223372036854775807");
    check(show(rev(i64::MIN..=i64::MIN + 1)), "-9223372036854775807,-9223372036854775808");
    hint_is(&(0u64..=u64::MAX), usize::MAX, Option::<usize>::None);
    exact_is(&(usize::MAX - 3..=usize::MAX), 4);
    // A count past usize::MAX saturates the lower bound and drops the upper one: on a 32-bit usize the
    // 2^64 - 1 and 2^32 element ranges do.
    if POINTER_WIDTH == 64 {
        exact_is(&(0u64..u64::MAX), usize::MAX);
        exact_is(&(i64::MIN..i64::MAX), usize::MAX);
        exact_is(&(i32::MIN..=i32::MAX), (1u64 << 32) as usize);
    } else {
        hint_is(&(0u64..u64::MAX), usize::MAX, Option::<usize>::None);
        hint_is(&(i64::MIN..i64::MAX), usize::MAX, Option::<usize>::None);
        hint_is(&(i32::MIN..=i32::MAX), usize::MAX, Option::<usize>::None);
    }
    exact_is(&(isize::MIN..isize::MIN + 2), 2);
    exact_is(&(u16::MAX..=u16::MAX), 1);
    exact_is(&(5u32..5u32), 0);
    exact_is(&(7..3), 0);
    exact_is(&(7..=3), 0);
    check(show(7..=3), "");
    let mut r = 0..=2;
    assert_eq(r.next().unwrap(), 0);
    assert_eq(r.next_back().unwrap(), 2);
    exact_is(&r, 1);
    assert_eq(r.next().unwrap(), 1);
    assert(r.next_back().is_none());
    assert(r.next().is_none());
    let mut top = u8::MAX..=u8::MAX;
    assert_eq(top.next_back().unwrap(), 255u8);
    assert(top.next().is_none());
    let v = ints(3);
    check(show(map(zip(10..20, v.iter()), |p: (i32, &i32)| p.0 * 10 + *p.1)), "100,111,122");
    check(show(step_by(0..10, 3)), "0,3,6,9");
    let kept = 0..4;
    let mut moved = kept;
    let _ = moved.next();
    assert_eq(kept.start, 0);
    let mut sum = 0;
    for x in kept {
        sum += x;
    }
    for x in rev(1..=3) {
        sum = sum * 10 + x;
    }
    assert_eq(sum, 6321);
}

// A random pipeline over 0..n against the same values computed by index arithmetic, drained by a random
// mix of `next` and `next_back`, with the hint checked after every step.
@test
fn randomized_double_ended_pipelines_match_index_arithmetic() {
    let mut rng = random::Pcg32::new(41, 9);
    for _ in 0..300 {
        let n = (rng.next_u32() % 40) as i32;
        let skip_n = (rng.next_u32() % 8) as usize;
        let take_n = (rng.next_u32() % 40) as usize;
        let step = 1 + (rng.next_u32() % 4) as usize;
        let mut want = Vector::<i32>::new();
        let mut k: usize = 0;
        for i in 0..n {
            let pos = i as usize;
            if pos >= skip_n && pos - skip_n < take_n {
                if k % step == 0 {
                    want.push(i * 3);
                }
                k += 1;
            }
        }
        let kind = rng.next_u32() % 3;
        let mut lo: usize = 0;
        let mut hi = want.len();
        if kind == 0 {
            let mut it = step_by(take(skip(map(0..n, |x: i32| x * 3), skip_n), take_n), step);
            while lo < hi {
                exact_is(&it, hi - lo);
                if rng.next_u32() % 2 == 0 {
                    assert_eq(it.next().unwrap(), *want.at(lo));
                    lo += 1;
                } else {
                    assert_eq(it.next_back().unwrap(), *want.at(hi - 1));
                    hi -= 1;
                }
            }
            assert(it.next().is_none());
            assert(it.next_back().is_none());
        } else if kind == 1 {
            let mut it = rev(step_by(take(skip(rev(rev(map(0..n, |x: i32| x * 3))), skip_n), take_n), step));
            while lo < hi {
                exact_is(&it, hi - lo);
                if rng.next_u32() % 2 == 0 {
                    assert_eq(it.next_back().unwrap(), *want.at(lo));
                    lo += 1;
                } else {
                    assert_eq(it.next().unwrap(), *want.at(hi - 1));
                    hi -= 1;
                }
            }
            assert(it.next().is_none());
        } else {
            let split = (rng.next_u32() % 20) as i32;
            let mid = if split < n {
                split;
            } else {
                n;
            };
            let joined = chain(map(0..mid, |x: i32| x * 3), map(mid..n, |x: i32| x * 3));
            let mut it = peekable(fuse(step_by(take(skip(joined, skip_n), take_n), step)));
            while lo < hi {
                exact_is(&it, hi - lo);
                let r = rng.next_u32() % 3;
                if r == 0 {
                    assert_eq(it.next().unwrap(), *want.at(lo));
                    lo += 1;
                } else if r == 1 {
                    assert_eq(*it.peek().unwrap(), *want.at(lo));
                } else {
                    assert_eq(it.next_back().unwrap(), *want.at(hi - 1));
                    hi -= 1;
                }
            }
            assert(it.peek().is_none());
        }
    }
}

// Each source value is pulled once, whatever the adapter; the consumers compare as written.
@test
fn work_stays_within_the_written_bounds() {
    let mut made = 0;
    assert_eq(count(filter(gen(0, 50, &mut made), long_name)), 40);
    assert_eq(made, 50);
    made = 0;
    assert_eq(count(flat_map(gen(0, 10, &mut made), twice)), 20);
    assert_eq(made, 10);
    made = 0;
    assert_eq(count(step_by(gen(0, 30, &mut made), 7)), 5);
    assert_eq(made, 30);
    made = 0;
    assert_eq(count(skip_while(gen(0, 30, &mut made), |s: &String| s.len() == 2)), 20);
    assert_eq(made, 30);
    let mut keys = Vector::<Key>::new();
    for i in 0..64 {
        keys.push(Key { v: i * 37 % 64 });
    }
    unsafe KEY_CMPS = 0;
    assert_eq(min(map(keys.iter(), |k: &Key| Key { v: k.v })).unwrap().v, 0);
    assert_eq(unsafe KEY_CMPS, 63);
    unsafe KEY_CMPS = 0;
    assert_eq(max(map(keys.iter(), |k: &Key| Key { v: k.v })).unwrap().v, 63);
    assert_eq(unsafe KEY_CMPS, 63);
    unsafe KEY_CMPS = 0;
    assert(is_sorted(map(0..64, |i: i32| Key { v: i })));
    assert_eq(unsafe KEY_CMPS, 63);
    unsafe KEY_CMPS = 0;
    assert(eq(map(0..64, |i: i32| Key { v: i }), map(0..64, |i: i32| Key { v: i })));
    assert_eq(unsafe KEY_CMPS, 64);
    unsafe KEY_CMPS = 0;
    assert(cmp(map(0..64, |i: i32| Key { v: i }), map(0..64, |i: i32| Key { v: i / 32 })) > 0);
    assert_eq(unsafe KEY_CMPS, 2);
}
