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
    v.resize_default(2); // shrinking frees the tail
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
    assert_eq(*v.at(7), 49); // stored value preserved
    let last = v.pop();
    assert(last.is_some() && last.unwrap() == 361 && v.len() == 19, "pop returns the last element (LIFO)");
    let mut empty = Vector::<i32>::new();
    assert(empty.pop().is_none(), "pop on empty returns None");
}

@test
fn capacity_growth() {
    let mut v = Vector::<i32>::new();
    assert_eq(v.capacity(), 0); // init allocates nothing
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
    v.insert(1, 99); // [0,99,1,2,3]
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
