// Self-hosted analog of tests/vector_test.c. The C suite tests the compiler's internal VEC_DECLARE/
// VEC_DEFINE macros; the self-hosted world instead relies on the prelude `Vector<T>`, so this exercises
// that: push/pop LIFO + len, at/get/set bounds, first/last, insert/remove/swap/swap_remove/reverse,
// clear/truncate, capacity growth, and a non-i32 element type.

// `resize_default` is bounded on `Default` rather than taking a value to copy: a `Free` element cannot be
// duplicated into the new slots, so the element type has to be able to produce a fresh one.
@test
fn resize_default_grows_and_truncates() {
    let mut v = Vector::<u8>::new();
    v.resize_default(4);
    assert_eq(v.len(), 4);
    assert_eq(*v.at(3), 0u8);
    v.push(9u8);
    // Shrinking frees the tail.
    v.resize_default(2);
    assert_eq(v.len(), 2);
}

@test
fn push_pop_len() {
    let mut v = Vector::<i32>::new();
    assert(v.is_empty() && v.len() == 0, "init is empty");
    for i in 0..20 {
        v.push(i * i);
    }
    assert_eq(v.len(), 20);
    // Stored value preserved.
    assert_eq(*v.at(7), 49);
    let last = v.pop();
    assert(last.is_some() && last.unwrap() == 361 && v.len() == 19, "pop returns the last element (LIFO)");
    let mut empty = Vector::<i32>::new();
    assert(empty.pop().is_none(), "pop on empty returns None");
}

@test
fn capacity_growth() {
    let mut v = Vector::<i32>::new();
    // Init allocates nothing.
    assert_eq(v.capacity(), 0);
    v.reserve(10);
    assert(v.capacity() >= 10 && v.len() == 0, "reserve grows capacity, never len");
    for i in 0..200 {
        v.push(i);
    }
    assert(v.capacity() >= v.len(), "capacity always covers len after growth");
    assert_eq(v.len(), 200);
}

@test
fn at_get_set() {
    let mut v = Vector::<i32>::new();
    for i in 0..10 {
        v.push(i);
    }
    let g = v.get(3);
    assert(g.is_some() && *g.unwrap() == 3, "get in-bounds");
    assert(v.get(100).is_none(), "get out-of-bounds returns None");
    v.set(3, 99);
    assert_eq(*v.at(3), 99);
}

@test
fn insert_remove() {
    let mut v = Vector::<i32>::new();
    for i in 0..4 {
        v.push(i);
    } // [0,1,2,3]
    // [0,99,1,2,3].
    v.insert(1, 99);
    assert(v.len() == 5 && *v.at(1) == 99 && *v.at(2) == 1, "insert shifts right");
    let r = v.remove(1); // -> Some(99), [0,1,2,3]
    assert(r.is_some() && r.unwrap() == 99 && v.len() == 4 && *v.at(1) == 1, "remove returns value + shifts left");
}

@test
fn swap_reverse() {
    let mut v = Vector::<i32>::new();
    v.push(10);
    v.push(20);
    v.push(30);
    v.swap(0, 2);
    assert(*v.at(0) == 30 && *v.at(2) == 10, "swap exchanges elements");
    v.reverse();
    assert(*v.at(0) == 10 && *v.at(1) == 20 && *v.at(2) == 30, "reverse restores order");
    let sr = v.swap_remove(0); // moves last into slot 0 -> [30,20]
    assert(sr.is_some() && sr.unwrap() == 10 && v.len() == 2 && *v.at(0) == 30, "swap_remove pulls the tail in");
}

@test
fn first_last_clear_truncate() {
    let mut v = Vector::<i32>::new();
    v.push(1);
    v.push(2);
    v.push(3);
    assert(*v.first().unwrap() == 1 && *v.last().unwrap() == 3, "first/last");
    v.truncate(2);
    assert_eq(v.len(), 2);
    v.clear();
    assert(v.len() == 0 && v.is_empty(), "clear empties");
}

@test
fn bool_elements() {
    let mut b = Vector::<bool>::new();
    b.push(true);
    b.push(false);
    assert(b.len() == 2 && *b.at(0) == true, "stores values");
    let p = b.pop();
    assert(p.is_some() && p.unwrap() == false, "bool pop");
}

// Strings longer than the 23-byte inline budget, so every element owns a heap buffer the leak gate sees.
fn long_str(tag: str) String {
    let mut s = String::from_str(tag);
    s.push_str(" padded well past the inline string budget");
    return s;
}

// Equality through `equals` (borrowing): `==` between owned Strings does not release its operands.
fn is_long(s: &String, tag: str) bool {
    let w = long_str(tag);
    return s.equals(&w);
}

// The first element is compared with the kept prefix, never with itself: it stays intact, and each run
// of equals collapses to its first element (the dropped duplicates are freed).
@test
fn dedup_owned_elements() {
    let mut v = Vector::<String>::new();
    v.push(long_str("xx"));
    v.push(long_str("xx"));
    v.push(long_str("yy"));
    v.push(long_str("yy"));
    v.push(long_str("xx"));
    v.dedup();
    assert_eq(v.len(), 3);
    assert(is_long(v.at(0), "xx") && is_long(v.at(1), "yy") && is_long(v.at(2), "xx"), "runs collapse");
}

// sort_by_key orders by the extracted key (a heapsort, so a few hundred elements stay fast) and moves
// owned elements without freeing or duplicating them.
@test
fn sort_by_key_orders_by_key() {
    let mut v = Vector::<i32>::new();
    let mut x: i32 = 7;
    for _i in 0..300 {
        x = (x * 1103 + 12345) % 1009;
        v.push(x);
    }
    v.sort_by_key(|p: &i32| 0 - *p);
    for i in 1..v.len() {
        assert(*v.at(i - 1) >= *v.at(i), "descending by the negated key");
    }
    let mut s = Vector::<String>::new();
    s.push(long_str("ccc"));
    s.push(long_str("a"));
    s.push(long_str("bb"));
    s.sort_by_key(|t: &String| t.len());
    assert(is_long(s.at(0), "a") && is_long(s.at(1), "bb") && is_long(s.at(2), "ccc"), "by length");
}

@test(should_panic)
fn insert_past_len_panics() {
    let mut v = Vector::<i32>::new();
    v.push(1);
    v.insert(2, 5);
}

@test(should_panic)
fn swap_out_of_range_panics() {
    let mut v = Vector::<i32>::new();
    v.push(1);
    v.swap(0, 1);
}

// A byte size past usize must not wrap into a small allocation that the recorded capacity overruns.
@test(should_panic)
fn capacity_overflow_panics() {
    let _v = Vector::<u64>::with_capacity((1 as usize << 61) + 1);
}

@test(should_panic)
fn reserve_overflow_panics() {
    let mut v = Vector::<u64>::new();
    v.push(1);
    v.reserve(~(0 as usize));
}

// The raw-pointer stores in StaticVector::set and SliceMut::set free the element they replace.
@test
fn set_frees_the_replaced_element() {
    let mut sv = StaticVector::<String, 4>::new();
    sv.push(long_str("first"));
    sv.set(0, long_str("second"));
    assert(is_long(sv.at(0), "second"), "static vector set");
    let mut v = Vector::<String>::new();
    v.push(long_str("third"));
    let view = v.index_range_mut(0..1);
    view.set(0, long_str("fourth"));
    assert(is_long(v.at(0), "fourth"), "slice set");
}

// A value aligned above malloc's guarantee gets a block aligned for it through every growth.
@c.align(64)
struct Wide {
    pub v: u64,
}

@test
fn over_aligned_elements_are_aligned() {
    let mut v = Vector::<Wide>::new();
    for i in 0..40 {
        v.push(Wide { v: i as u64 });
        assert(v.as_ptr() as usize % 64 == 0, "64-byte aligned buffer");
    }
    let b = Box::<Wide>::new(Wide { v: 9 });
    assert(b.as_ptr() as usize % 64 == 0, "64-byte aligned box");
    assert_eq(b.get().v, 9u64);
}

// Box::map borrows the value, which the box keeps owning.
@test
fn box_map_borrows() {
    let b = Box::<String>::new(long_str("boxed"));
    let n = b.map(|s: &String| s.len());
    let want = long_str("boxed");
    assert_eq(*n.get(), want.len());
    assert(is_long(b.get(), "boxed"), "the box still owns its value");
}

// A zeroed Box (the seed the reflection constructors fill) owns nothing, so releasing it is a no-op.
@test
fn zeroed_box_releases_nothing() {
    let z = unsafe zeroed::<Box<String>>();
    assert(z.as_ptr() == null, "zeroed");
}

// Float formatting writes into the string's own spare capacity, so a long result is never cut short.
@test
fn float_formatting_is_not_truncated() {
    let s = format("{:.2}", 1e100);
    assert_eq(s.len(), 104 as usize);
    assert(s.as_str().starts_with("10000000000000000159") && s.as_str().ends_with(".00"), "full digits");
    let mut t = String::from_str("x=");
    t.push_f64(0.5);
    assert(t.as_str() == "x=0.5", "%g appended in place");
}

@test(should_panic)
fn substring_past_the_end_panics() {
    let s = long_str("abc");
    let _t = s.substring(3, s.len() + 1);
}

@test(should_panic)
fn str_slice_reversed_bounds_panic() {
    let s = "abcdef";
    let _t = s.slice(4, 2);
}

@test(should_panic)
fn remove_byte_past_the_end_panics() {
    let mut s = String::from_str("ab");
    let _b = s.remove_byte(2);
}

// Option::filter borrows the payload: a kept owned payload is freed exactly once, by its new owner.
@test
fn option_filter_borrows() {
    let kept = Option::<String>::Some(long_str("keep")).filter(|s: &String| s.len() > 10);
    assert(kept.is_some(), "kept");
}

// Error stores its message inline and derives Free; clones are independent.
@test
fn error_message_round_trip() {
    let e = Error::from_string(7, long_str("failure"));
    let c = e.clone();
    assert(c.code == 7 && is_long(c.message(), "failure"), "clone");
    let f = e.fmt();
    assert(f.as_str().starts_with("Error(7: failure"), "format");
}
