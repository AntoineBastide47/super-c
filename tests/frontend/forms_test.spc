// The newer forms: bare and qualified variants, value blocks, statement switches, call-site view
// coercion, deferred inference of locals and `_`, and tuples as results. Each run case's `main`
// returns 0 when every value is the expected one.
import tests::harness as h;

// A variant is written bare or qualified, in values and in patterns. A bare value resolves through
// the expected type (return, annotated let, argument, field, array element, `==`, assignment), and
// the prelude's `Some`, `None`, `Ok` and `Err` also without one.
@test
fn bare_and_qualified_variants() {
    let mut b = h::ExitBatch::new();
    b.add(
        "bare variants through every expected type",
        "enum Shape { Circle(i32), Rect { w: i32, h: i32 }, Unit }\nstruct H { pub s: Shape }\nfn mk(n: i32) Option<i32> { if n > 3 { return None; } return Some(n); }\nfn take(s: Shape) i32 { return switch s { Circle(r) => r, Shape::Rect { w, h } => w * h, Shape::Unit => 7, }; }\nfn main() i32 {\n    let a = Some(1);\n    let e: Result<i32, i32> = Err(4);\n    let h = H { s: Circle(2) };\n    let arr: [Shape; 2] = [Unit, Circle(3)];\n    let mut s: Shape = Unit;\n    s = Circle(4);\n    let eq = mk(1) == Some(1);\n    let q = switch a { Option::Some(x) => x, Option::None => 0, };\n    let r = switch e { Ok(x) => x, Result::Err(x) => x * 10, };\n    let t = take(s) + take(h.s) + take(Unit);\n    return q + r + t + (eq as i32) - 55;\n}\n",
        0,
    );
    b.run();
    h::expect_err_msg(
        "a local that a bare variant also names",
        "enum Shape { Circle(i32), Unit }\nfn f() Shape { let Unit = 3; let z: Shape = Unit; return z; }\n",
        "'Unit' names both a local and the variant 'Shape::Unit': rename one",
    );
    h::expect_err_msg(
        "a bare variant of another enum without an expected type",
        "enum Shape { Circle(i32), Unit }\nfn f() i32 { let w = Circle(1); return 0; }\n",
        "cannot find value 'Circle'",
    );
    h::expect_err_msg(
        "a bare None without an expected type",
        "fn f() i32 { let n = None; return 0; }\n",
        "cannot infer the generic argument 'T'",
    );
    h::expect_err_msg(
        "a qualified pattern of another enum",
        "enum E { A(i32), B }\nenum F { A(i32), B }\nfn f(e: E) i32 { return switch e { F::A(x) => x, E::B => 0, }; }\n",
        "pattern 'F::A' does not name a variant of the matched type 'E'",
    );
}

// A block is a value when its last expression has no `;` (and, as before, when it ends in an
// expression with one). A statement `switch` ends at its `}`, and its arms are statements, so arms
// of different types do not join. A value block's last `if` with an `else` and its last `switch` are
// its value. A function or closure body gives its result with `return`.
@test
fn value_blocks_and_statement_switches() {
    let mut b = h::ExitBatch::new();
    b.add(
        "value blocks and statement switches",
        "enum E { A, B }\nfn g(e: E) i32 {\n    switch e {\n        A => { return 1; },\n        B => { return 2; },\n    }\n}\nfn main() i32 {\n    let e = E::A;\n    let o: Option<usize> = None;\n    let mut n: usize = 0;\n    switch o {\n        Some(x) => { n + x; },\n        None => { n = 1; },\n    }\n    switch e { A => { n = n + 2; }, B => {}, };\n    let a = { 5 };\n    let c = unsafe { 6 };\n    let s = { let x = 2; let t = String::from_str(\"abc\"); x + t.len() as i32 };\n    let v = if true { let k = 5; if false { k } else { 2 } } else { 3 };\n    let w = { n = n + 1; switch e { A => 10, B => 20, } };\n    return a + c + s + v + w + g(e) + n as i32 - 33;\n}\n",
        0,
    );
    b.run();
    h::expect_err_msg(
        "a function body's last expression is no result",
        "fn k(x: i32) i32 { x + 1 }\n",
        "a function body gives its result with 'return': write 'return x + 1;'",
    );
    h::expect_err_msg(
        "a closure body's last expression is no result",
        "fn main() i32 { let c = |x: i32| { x + 1 }; return c(1); }\n",
        "a closure body gives its result with 'return': write 'return x + 1;'",
    );
}

// `&x` and `&mut x` call arguments pass as the view the prelude view interface of `x`'s type gives:
// `str` (`AsStr`), `[]T` (`AsSlice<T>`, which also infers `T`), `[]mut T` (`AsSliceMut<T>`). The view
// borrows `x` as `x.as_str()` does; without `&` the argument stays an error naming the borrow.
@test
fn call_site_view_coercion() {
    let mut b = h::ExitBatch::new();
    b.add(
        "views of String, Vector and Array arguments",
        "fn count(s: str) usize { return s.len(); }\nfn total(xs: []i32) i32 { let mut t = 0; for x in xs { t += x; } return t; }\nfn bump(xs: []mut i32) { for i in 0..xs.len() { xs[i] += 1; } }\nfn first<T: Copy>(xs: []T) T { return xs[0]; }\nstruct W { pub s: String }\nextend W { fn take(self: &Self, s: str) usize { return s.len() + self.s.len(); } }\nfn main() i32 {\n    let s = String::from_str(\"hello\");\n    let mut v = Vector::<i32>::new();\n    v.push(1);\n    v.push(2);\n    bump(&mut v);\n    let a = Array::<i32, 3>::new();\n    let w = W { s: String::from_str(\"ab\") };\n    return (count(&s) + w.take(&s)) as i32 + total(&v) + total(&a) + first(&v) - 19;\n}\n",
        0,
    );
    b.run();
    h::expect_err_msg(
        "a view keeps its owner borrowed",
        "fn first(s: str) str { return s; }\nfn main() i32 { let mut s = String::from_str(\"x\"); let v = first(&s); s.push_str(\"y\"); return v.len() as i32; }\n",
        "cannot borrow this value as mutable while it is already borrowed as immutable",
    );
    h::expect_err_msg(
        "a container without '&' is a move",
        "fn count(s: str) usize { return s.len(); }\nfn main() i32 { let s = String::from_str(\"a\"); return count(s) as i32; }\n",
        "borrow it: write '&s' (passing it would move it)",
    );
}

// A local whose initializer leaves generic arguments open keeps them open: its later uses in the body
// fill them in, an unsuffixed literal only when no typed use does. A closure a let binds takes its
// parameter types from its first call. `_` leaves a type to inference in a local's annotation and a
// call's type arguments only.
@test
fn deferred_inference() {
    let mut b = h::ExitBatch::new();
    b.add(
        "locals typed by their later uses",
        "fn pair<A, B>(a: A, b: B) B { return b; }\nfn main() i32 {\n    let mut v = Vector::new();\n    let x: u8 = 3;\n    v.push(1);\n    v.push(x);\n    let c = |a| a + 1;\n    let n = c(2);\n    let mut w = Vector::new();\n    w.push(String::from_str(\"ab\"));\n    let mut o = None;\n    if o.is_none() { o = Some(3u8); }\n    let mut r = Ok(1);\n    r = Err(String::from_str(\"e\"));\n    let mut z: Vector<_> = Vector::new();\n    z.push(7u16);\n    let m = pair::<_, u8>(1, 2);\n    return v.len() as i32 + v[1] as i32 + n + w[0].len() as i32 + o.unwrap() as i32 + r.is_err() as i32 + z[0] as i32 + m as i32 - 23;\n}\n",
        0,
    );
    b.run();
    h::expect_err_msg(
        "two typed uses that disagree",
        "fn main() i32 { let mut v = Vector::new(); let a: u8 = 1; let b: i64 = 2; v.push(a); v.push(b); return 0; }\n",
        "conflicting types for 'T' of 'v': 'i64' here, 'u8' at its first use",
    );
    h::expect_err_msg(
        "a local no use fixes",
        "fn main() i32 { let w = Vector::new(); return 0; }\n",
        "cannot infer the generic argument 'T'",
    );
    h::expect_err_msg(
        "'_' in a signature",
        "fn f(x: Vector<_>) {}\n",
        "'_' leaves a type to inference only in a local's annotation or a call's type arguments",
    );
}

// A tuple of up to 8 elements is `Eq`, `Ord`, `Hash`, `Clone`, `Default` and `Format` when every
// element is: a result list returns one.
@test
fn tuple_conformances_at_every_arity() {
    let mut b = h::ExitBatch::new();
    b.add(
        "an 8-tuple's conformances",
        "fn eight() (i32, u8, i64, u16, i32, i32, i32, i32) { return 1, 2, 3, 4, 5, 6, 7, 8; }\nfn main() i32 {\n    let t = eight();\n    let u = t.clone();\n    let s = t.fmt();\n    let mut m = Map::<(i32, i32, i32, i32, i32), i32>::new();\n    m.insert((1, 2, 3, 4, 5), 9);\n    let d: (i32, i32, i32, i32, i32, i32) = Default::default();\n    let less = (1, 2, 3, 4, 5) < (1, 2, 3, 4, 6);\n    if t != u || !s.eq_str(\"(1, 2, 3, 4, 5, 6, 7, 8)\") || !less {\n        return 1;\n    }\n    return t.7 + *m.get(&(1, 2, 3, 4, 5)).unwrap() + d.5 - 17;\n}\n",
        0,
    );
    b.run();
}
