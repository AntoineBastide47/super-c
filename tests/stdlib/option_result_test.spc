// The prelude value helpers of std/option.spc, std/result.spc and std/tuple.spc: every Option and Result
// method with owned String payloads under the leak check (no leak, no double free on either arm), the
// associated functions for nested instances (`Option::flatten`, `Result::transpose`, ..), ordering and
// hashing (`hash` and `hash_into` agree with `Eq`), the zero-or-one iterators, and the tuple conformances
// (`Map` keys, sorting, formatting).

// A hasher that records the stream, so a test compares the bytes a value feeds.
struct Tape {
    pub bytes: Vector<u8>,
}

fn s(text: str) String {
    return String::from_str(text);
}

fn some(text: str) Option<String> {
    return Some(s(text));
}

const fn none() Option<String> {
    return None;
}

fn ok(text: str) Result<String, String> {
    return Ok(s(text));
}

fn err(text: str) Result<String, String> {
    return Err(s(text));
}

fn tape_of<T: Hash>(v: T) Vector<u8> {
    let mut t = Tape { bytes: Vector::<u8>::new() };
    v.hash_into(&mut t);
    return replace(&mut t.bytes, Vector::<u8>::new());
}

fn check(got: String, want: str) {
    assert_eq(got.as_str(), want);
}

const fn long_text(v: &String) bool {
    return v.len() > 2;
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
fn option_predicates_borrow_the_payload() {
    let a = some("abc");
    assert(a.is_some_and(long_text));
    assert(!a.is_none_or(|v: &String| v.len() == 1));
    assert(!none().is_some_and(long_text));
    assert(none().is_none_or(long_text));
    assert(some("ab").is_none_or(|v: &String| v.len() == 2));
    assert_eq(a.unwrap().as_str(), "abc");
}

@test
fn option_as_ref_and_as_mut_reach_the_payload() {
    let mut a = some("ab");
    assert_eq(a.as_ref().unwrap().len(), 2);
    a.as_mut().unwrap().push_str("cd");
    check(a.unwrap(), "abcd");
    let mut n = none();
    assert(n.as_ref().is_none());
    assert(n.as_mut().is_none());
}

@test
fn option_to_result() {
    check(some("x").ok_or(s("unused")).unwrap(), "x");
    check(none().ok_or(s("e")).unwrap_err(), "e");
    check(some("x").ok_or_else(|| s("unused")).unwrap(), "x");
    check(none().ok_or_else(|| s("lazy")).unwrap_err(), "lazy");
}

@test
fn option_alternatives_free_what_they_discard() {
    check(some("v").map_or_else(|| s("d"), |v: String| v), "v");
    check(none().map_or_else(|| s("d"), |v: String| v), "d");
    check(some("a").or_else(|| some("b")).unwrap(), "a");
    check(none().or_else(|| some("b")).unwrap(), "b");
    check(some("a").xor(none()).unwrap(), "a");
    check(none().xor(some("b")).unwrap(), "b");
    assert(some("a").xor(some("b")).is_none());
    assert(none().xor(none()).is_none());
    let (za, zb) = some("a").zip(Option::<i32>::Some(3)).unwrap();
    check(za, "a");
    assert_eq(zb, 3);
    assert(some("a").zip(Option::<i32>::None).is_none());
    assert(none().zip(Option::<String>::Some(s("b"))).is_none());
}

@test
fn option_nested_instances_through_associated_functions() {
    let (a, b) = Option::unzip(Option::<(String, i32)>::Some((s("x"), 4)));
    check(a.unwrap(), "x");
    assert_eq(b.unwrap(), 4);
    let (c, d) = Option::unzip(Option::<(String, i32)>::None);
    assert(c.is_none() && d.is_none());
    check(Option::flatten(Option::<Option<String>>::Some(some("in"))).unwrap(), "in");
    assert(Option::flatten(Option::<Option<String>>::Some(none())).is_none());
    assert(Option::flatten(Option::<Option<String>>::None).is_none());
    let t = Option::transpose(Option::<Result<String, String>>::Some(ok("v")));
    check(t.unwrap().unwrap(), "v");
    let u = Option::transpose(Option::<Result<String, String>>::Some(err("e")));
    check(u.unwrap_err(), "e");
    assert(Option::transpose(Option::<Result<String, String>>::None).unwrap().is_none());
    let x = 7;
    assert_eq(Option::copied(Option::<&i32>::Some(&x)).unwrap(), 7);
    assert(Option::copied(Option::<&i32>::None).is_none());
    let w = s("w");
    check(Option::cloned(Option::<&String>::Some(&w)).unwrap(), "w");
    assert_eq(w.as_str(), "w");
}

@test
fn option_in_place_updates() {
    let mut a = none();
    a.get_or_insert(s("first")).push_str("!");
    a.get_or_insert(s("ignored")).push_str("?");
    check(a.take().unwrap(), "first!?");
    let mut b = none();
    let mut calls = 0;
    let p = (&mut calls) as *mut i32;
    b.get_or_insert_with(
        fn() String {
            unsafe *p += 1;
            return s("made");
        },
    );
    b.get_or_insert_with(
        fn() String {
            unsafe *p += 1;
            return s("again");
        },
    );
    assert_eq(calls, 1);
    check(b.unwrap(), "made");
    let mut c = some("old");
    c.insert(s("new")).push_str("er");
    check(c.unwrap(), "newer");
    let mut d = some("keep");
    assert(d.take_if(|v: &String| v.len() > 9).is_none());
    check(d.take_if(long_text).unwrap(), "keep");
    assert(d.is_none());
    assert(d.take_if(long_text).is_none());
}

@test
fn option_inspect_iter_and_default() {
    let mut seen: usize = 0;
    let p = (&mut seen) as *mut usize;
    check(some("abc").inspect(|v: &String| unsafe *p += v.len()).unwrap(), "abc");
    assert(none().inspect(|v: &String| unsafe *p += v.len()).is_none());
    assert_eq(seen, 3);
    let a = some("x");
    let mut it = a.iter();
    let (lo, hi) = it.size_hint();
    assert_eq(lo, 1);
    assert(hi == Option::<usize>::Some(1));
    assert_eq(it.next_back().unwrap().as_str(), "x");
    assert(it.next().is_none());
    assert_eq(count(none().iter()), 0);
    check(none().unwrap_or_default(), "");
    check(some("v").unwrap_or_default(), "v");
    assert_eq(Option::<i32>::None.unwrap_or_default(), 0);
}

@test
fn option_orders_none_first_and_hashes_consistently() {
    assert(none() < some(""));
    assert(some("a") < some("b"));
    assert(some("b") > none());
    let (n1, n2) = (none(), none());
    assert_eq(n1.cmp(&n2), 0);
    let (q1, q2) = (some("q"), some("q"));
    assert_eq(q1.cmp(&q2), 0);
    let n0 = none();
    assert_eq(hash(&q1), hash(&q2));
    assert(hash(&q1) != hash(&n0));
    assert(tape_of(some("q")) == tape_of(some("q")));
    assert(tape_of(some("")) != tape_of(none()));
    let mut v = Vector::<Option<i32>>::new();
    v.push(Option::<i32>::Some(3));
    v.push(Option::<i32>::None);
    v.push(Option::<i32>::Some(1));
    v.sort();
    assert(v.at(0).is_none());
    assert_eq(v.at(2).unwrap(), 3);
}

@test
fn result_predicates_and_views() {
    let a = ok("abc");
    assert(a.is_ok_and(long_text));
    assert(!a.is_err_and(long_text));
    let e = err("bad!");
    assert(e.is_err_and(long_text));
    assert(!e.is_ok_and(long_text));
    assert_eq(a.as_ref().unwrap().len(), 3);
    assert_eq(e.as_ref().unwrap_err().len(), 4);
    let mut m = ok("x");
    m.as_mut().unwrap().push_str("y");
    check(m.unwrap(), "xy");
    let mut n = err("p");
    n.as_mut().unwrap_err().push_str("q");
    check(n.unwrap_err(), "pq");
}

@test
fn result_combinators_free_what_they_discard() {
    assert_eq(ok("abc").map_or(0, |v: String| v.len()), 3);
    assert_eq(err("e").map_or(9, |v: String| v.len()), 9);
    check(ok("v").map_or_else(|e: String| e, |v: String| v), "v");
    check(err("e").map_or_else(|e: String| e, |v: String| v), "e");
    check(ok("v").or_else(|e: String| Result::<String, i32>::Err(e.len() as i32)).unwrap(), "v");
    assert_eq(err("eee").or_else(|e: String| Result::<String, i32>::Err(e.len() as i32)).unwrap_err(), 3);
    check(err("e").or_else(|e: String| Result::<String, String>::Ok(e)).unwrap(), "e");
    check(ok("a").and(ok("b")).unwrap(), "b");
    check(ok("a").and(err("y")).unwrap_err(), "y");
    check(err("x").and(ok("b")).unwrap_err(), "x");
    check(err("x").expect_err("must fail"), "x");
    check(ok("v").unwrap_or_default(), "v");
    check(err("e").unwrap_or_default(), "");
}

@test(should_panic)
fn result_expect_err_panics_on_ok() {
    let _ = ok("v").expect_err("an error");
}

@test
fn result_inspect_iter_and_nested_instances() {
    let mut seen: usize = 0;
    let p = (&mut seen) as *mut usize;
    check(ok("ab").inspect(|v: &String| unsafe *p += v.len()).unwrap(), "ab");
    check(err("abc").inspect(|v: &String| unsafe *p += v.len()).unwrap_err(), "abc");
    assert_eq(seen, 2);
    check(err("abc").inspect_err(|e: &String| unsafe *p += e.len()).unwrap_err(), "abc");
    check(ok("ab").inspect_err(|e: &String| unsafe *p += e.len()).unwrap(), "ab");
    assert_eq(seen, 5);
    let a = ok("x");
    assert_eq(count(a.iter()), 1);
    assert_eq(a.iter().next().unwrap().as_str(), "x");
    assert_eq(count(err("e").iter()), 0);
    check(Result::flatten(Result::<Result<String, String>, String>::Ok(ok("in"))).unwrap(), "in");
    check(Result::flatten(Result::<Result<String, String>, String>::Ok(err("inner"))).unwrap_err(), "inner");
    check(Result::flatten(Result::<Result<String, String>, String>::Err(s("outer"))).unwrap_err(), "outer");
    check(Result::transpose(Result::<Option<String>, String>::Ok(some("v"))).unwrap().unwrap(), "v");
    assert(Result::transpose(Result::<Option<String>, String>::Ok(none())).is_none());
    check(Result::transpose(Result::<Option<String>, String>::Err(s("e"))).unwrap().unwrap_err(), "e");
    let x = 5;
    assert_eq(Result::copied(Result::<&i32, String>::Ok(&x)).unwrap(), 5);
    check(Result::copied(Result::<&i32, String>::Err(s("e"))).unwrap_err(), "e");
    let w = s("w");
    check(Result::cloned(Result::<&String, i32>::Ok(&w)).unwrap(), "w");
    assert_eq(Result::cloned(Result::<&String, i32>::Err(2)).unwrap_err(), 2);
}

@test
fn result_orders_ok_first_and_hashes_consistently() {
    assert(ok("z") < err("a"));
    assert(ok("a") < ok("b"));
    assert(err("a") < err("b"));
    let (e1, e2) = (err("q"), err("q"));
    assert_eq(e1.cmp(&e2), 0);
    let (o1, o2) = (ok("q"), ok("q"));
    assert_eq(hash(&o1), hash(&o2));
    assert(hash(&o1) != hash(&e1));
    assert(tape_of(ok("q")) == tape_of(ok("q")));
    assert(tape_of(ok("q")) != tape_of(err("q")));
    let mut m = Map::<Result<i32, String>, i32>::new();
    m.insert(Result::<i32, String>::Ok(1), 10);
    m.insert(Result::<i32, String>::Err(s("x")), 20);
    let kx = Result::<i32, String>::Err(s("x"));
    let k1 = Result::<i32, String>::Ok(1);
    assert_eq(*m.get(&kx).unwrap(), 20);
    assert_eq(*m.get(&k1).unwrap(), 10);
}

@test
fn tuples_compare_hash_clone_default_and_format() {
    let a = (1u32, s("b"));
    let b = (1u32, s("c"));
    assert(a == a.clone());
    assert(a != b);
    assert(a < b);
    assert((2u32, s("a")) > b);
    let same = (1u32, s("b"));
    assert_eq(hash(&a), hash(&same));
    assert(tape_of((s("ab"), s("c"))) != tape_of((s("a"), s("bc"))));
    let d: (i32, String, bool) = Default::default();
    assert_eq(d.0, 0);
    assert_eq(d.1.len(), 0);
    assert(!d.2);
    check(a.fmt(), "(1, b)");
    check((1, 2, 3).fmt(), "(1, 2, 3)");
    check((1, s("x"), 3, false).fmt(), "(1, x, 3, false)");
    let (t1, t2) = ((1, 2, 3), (1, 2, 4));
    assert_eq(t1.cmp(&t2), -1);
    assert((1, 2, 3, 4) == (1, 2, 3, 4));
    assert((1, 2, 3, 4) < (1, 2, 4, 0));
    let mut m = Map::<(u32, u32), String>::new();
    m.insert((1u32, 2u32), s("x"));
    m.insert((2u32, 1u32), s("y"));
    assert_eq(m.get(&(2u32, 1u32)).unwrap().as_str(), "y");
    assert(m.get(&(3u32, 1u32)).is_none());
    let mut v = Vector::<(i32, String)>::new();
    v.push((2, s("a")));
    v.push((1, s("z")));
    v.push((1, s("b")));
    v.sort();
    check(v.fmt(), "[(1, b), (1, z), (2, a)]");
    let mut w = Vector::<(i32, i32, i32, i32)>::new();
    w.push((0, 0, 0, 1));
    w.push((0, 0, 0, 0));
    w.sort();
    assert_eq(w.at(0)._3, 0);
}
