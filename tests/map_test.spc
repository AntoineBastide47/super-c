// Self-hosted analog of tests/hashmap_test.c. The C suite tests the compiler's internal hashmap; the
// self-hosted world uses the prelude `Map<K,V>`, so this exercises that: insert/get/len, overwrite,
// contains_key, remove (present + absent), and growth/rehash across 100 keys.

@test
fn insert_get_len() {
    let mut m = Map::<i32, i32>::new();
    assert(m.is_empty(), "init is empty");
    m.insert(1, 10);
    m.insert(2, 20);
    m.insert(3, 30);
    assert_eq(m.len(), 3);
    let k1: i32 = 1;
    let g = m.get(&k1);
    assert(g.is_some() && *g.unwrap() == 10, "get present key");
    let k2: i32 = 2;
    assert(m.contains_key(&k2), "contains_key present");
    let k9: i32 = 99;
    assert(m.get(&k9).is_none(), "get missing key returns None");
}

@test
fn overwrite() {
    let mut m = Map::<i32, i32>::new();
    m.insert(1, 10);
    // Same key.
    m.insert(1, 111);
    // No growth on overwrite.
    assert_eq(m.len(), 1);
    let k1: i32 = 1;
    assert(*m.get(&k1).unwrap() == 111, "value overwritten");
}

@test
fn remove_present_and_absent() {
    let mut m = Map::<i32, i32>::new();
    m.insert(1, 10);
    m.insert(2, 20);
    let k2: i32 = 2;
    let r = m.remove(&k2);
    assert(r.is_some() && r.unwrap() == 20, "remove returns the value");
    assert(m.len() == 1 && !m.contains_key(&k2), "key gone after remove");
    assert(m.remove(&k2).is_none(), "remove of an absent key returns None");
}

@test
fn growth_rehash() {
    let mut m = Map::<i32, i32>::new();
    for i in 0..100 {
        m.insert(i, i * 2);
    }
    assert_eq(m.len(), 100);
    let mut ok = true;
    for i in 0..100 {
        let g = m.get(&i);
        if !(g.is_some() && *g.unwrap() == i * 2) {
            ok = false;
        }
    }
    assert(ok, "all 100 keys retrievable after growth/rehash");
}

// Strings longer than the 23-byte inline budget, so every value owns a heap buffer the leak gate sees.
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

// Overwriting a key frees the value it replaces.
@test
fn overwrite_frees_the_replaced_value() {
    let mut m = Map::<i32, String>::new();
    m.insert(1, long_str("old"));
    m.insert(1, long_str("new"));
    let k1: i32 = 1;
    assert(is_long(m.get(&k1).unwrap(), "new"), "value overwritten");
}

// Removing an entry frees its stored key; Set::remove frees the element through the same path.
@test
fn remove_frees_the_key() {
    let mut m = Map::<String, i32>::new();
    m.insert(long_str("a"), 1);
    m.insert(long_str("b"), 2);
    let a = long_str("a");
    let r = m.remove(&a);
    assert(r.is_some() && r.unwrap() == 1 && m.len() == 1, "removed");
    let mut s = Set::<String>::new();
    s.insert(long_str("x"));
    s.insert(long_str("y"));
    let x = long_str("x");
    let y = long_str("y");
    assert(s.remove(&x) && s.len() == 1 && s.contains(&y), "set remove");
}

// Default needs no Default key or value: an empty map holds neither.
struct NoDefault {
    pub n: i32,
}

extend NoDefault as Hash {}

extend NoDefault as Eq {}

@test
fn default_without_default_elements() {
    let mut m = Map::<NoDefault, NoDefault>::default();
    m.insert(NoDefault { n: 1 }, NoDefault { n: 2 });
    let s = Set::<NoDefault>::default();
    assert(m.len() == 1 && s.is_empty(), "defaulted containers");
}
