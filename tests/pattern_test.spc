// The shared pattern compiler: matrix usefulness drives exhaustiveness and
// unreachable-arm verdicts, and the decision tree drives Core IR match lowering. The sequential walker's
// verdicts are pinned by tests/typechecker_test.spc::switch_exhaustiveness; this file pins the
// matrix's added precision and the engine's direct answers.
import tests::harness as h;
import driver_shim as shim;
import module::loader as loader;
import ast::ast as *;
import resolver::resolver as res;
import pattern::pattern as pat;

@test
fn deep_split_coverage_is_exhaustive() {
    // The sequential walker demanded a whole-variant cover per arm; the matrix proves the split
    // covers Some entirely. A reviewed precision improvement, kept deliberately.
    h::expect_ok(
        "payload split across arms covers the variant",
        "fn f(o: Option<bool>) i32 { return switch o { Some(true) => 1, Some(false) => 2, None => 0 }; }\nfn main() i32 { return f(Option::<bool>::None); }\n",
    );
    h::expect_ok(
        "nested variant split covers",
        "enum E { A(bool), B }\nfn f(e: E) i32 { return switch e { A(true) => 1, A(false) => 2, B => 0 }; }\nfn main() i32 { return f(E::B); }\n",
    );
}

// Constructor completeness has no variant cap: an enum with more than 256 variants is exhaustive once
// every variant has an arm.
@test
fn many_variant_enum_is_exhaustive() {
    let mut src = String::from_str("enum E { ");
    for i in 0..300 {
        src.push_str(format("V{}, ", i).as_str());
    }
    src.push_str("}\nfn f(e: E) i32 { return switch e { ");
    for i in 0..300 {
        src.push_str(format("V{} => {}, ", i, i).as_str());
    }
    src.push_str("}; }\nfn main() i32 { return f(E::V299) - 299; }\n");
    h::expect_ok("300-variant switch listing every variant", src.as_str());
}

@test
fn matrix_still_rejects_partial_covers() {
    h::expect_err_msg(
        "partial payload split stays non-exhaustive",
        "fn f(o: Option<bool>) i32 { return switch o { Some(true) => 1, None => 0 }; }\n",
        "not exhaustive",
    );
    h::expect_err_msg(
        "guarded arms cover nothing",
        "enum E { A, B }\nfn f(e: E) i32 { return switch e { A if true => 1, B => 0 }; }\n",
        "not exhaustive",
    );
}

// A literal or range sub-pattern under a reference scrutinee tests the referent (bool, integer,
// range, nested payload, struct field), and a binding under it borrows the matched place.
@test
fn literal_patterns_test_the_referent() {
    h::expect_exit(
        "literal and range patterns under references",
        "enum E { B(bool), Iv(i32), P(i32, bool), N }\nstruct S { pub x: i32, pub on: bool }\nfn by_enum(e: &E) i32 {\n    return switch e {\n        B(true) => 1,\n        B(false) => 2,\n        Iv(7) => 3,\n        Iv(0..=5) => 4,\n        Iv(_) => 5,\n        P(1, true) => 6,\n        P(_, _) => 7,\n        N => 8,\n    };\n}\nfn by_int(x: &i32) i32 {\n    return switch x {\n        7 => 1,\n        10..20 => 2,\n        _ => 3,\n    };\n}\nfn by_struct(s: &S) i32 {\n    return switch s {\n        S { x: 3, on: true } => 1,\n        S { x, on: false } => *x,\n        _ => 0,\n    };\n}\nfn nested(o: Option<&E>) i32 {\n    if let Some(B(true)) = o {\n        return 1;\n    }\n    if let Some(Iv(n)) = o {\n        return *n;\n    }\n    return 0;\n}\nfn bump(e: &mut E) {\n    switch e {\n        Iv(n) => {\n            *n += 1;\n        },\n        _ => {},\n    };\n}\nfn main() i32 {\n    let bt = E::B(true);\n    let bf = E::B(false);\n    let i7 = E::Iv(7);\n    let i4 = E::Iv(4);\n    let i9 = E::Iv(9);\n    let p1 = E::P(1, true);\n    let p2 = E::P(1, false);\n    let n = E::N;\n    if by_enum(&bt) != 1 || by_enum(&bf) != 2 || by_enum(&i7) != 3 || by_enum(&i4) != 4 {\n        return 1;\n    }\n    if by_enum(&i9) != 5 || by_enum(&p1) != 6 || by_enum(&p2) != 7 || by_enum(&n) != 8 {\n        return 2;\n    }\n    let seven = 7;\n    let fifteen = 15;\n    let other = 30;\n    if by_int(&seven) != 1 || by_int(&fifteen) != 2 || by_int(&other) != 3 {\n        return 3;\n    }\n    let s1 = S { x: 3, on: true };\n    let s2 = S { x: 9, on: false };\n    let s3 = S { x: 4, on: true };\n    if by_struct(&s1) != 1 || by_struct(&s2) != 9 || by_struct(&s3) != 0 {\n        return 4;\n    }\n    let k = E::Iv(42);\n    if nested(Option::<&E>::Some(&bt)) != 1 || nested(Option::<&E>::Some(&bf)) != 0 || nested(Option::<&E>::Some(&k)) != 42 {\n        return 5;\n    }\n    let mut m = E::Iv(1);\n    bump(&mut m);\n    if by_enum(&m) != 4 {\n        return 6;\n    }\n    return 0;\n}\n",
        0,
    );
}

// The compile-time evaluator runs the same lowering: literal tests read the referent and bindings
// borrow the matched place.
@test
fn reference_patterns_evaluate_at_compile_time() {
    h::expect_exit(
        "reference patterns in const fn",
        "enum E { B(bool), Iv(i32), N }\nstruct S { pub x: i32, pub e: E }\nconst fn cval(e: &E) i32 {\n    return switch e {\n        B(true) => 10,\n        Iv(3) => 30,\n        Iv(n) => *n,\n        _ => 0,\n    };\n}\nconst fn sval(s: &S) i32 {\n    return switch s {\n        S { x: 1, e: Iv(k) } => *k + 100,\n        S { x, e: _ } => *x,\n    };\n}\nconst EB: E = E::B(true);\nconst EI: E = E::Iv(3);\nconst EK: E = E::Iv(8);\nconst SS: S = S { x: 1, e: E::Iv(5) };\nstatic_assert(cval(&EB) == 10, \"bool\");\nstatic_assert(cval(&EI) == 30, \"int\");\nstatic_assert(cval(&EK) == 8, \"bind\");\nstatic_assert(sval(&SS) == 105, \"nested\");\nfn main() i32 {\n    return cval(&EK) - 8;\n}\n",
        0,
    );
}

fn t_resolve(p: &mut loader::Package, i: usize) bool {
    let pkg = p as *const loader::Package;
    let m = &mut p.modules[i];
    let src = m.source.as_str().ptr() as *const char;
    let len = m.source.len();
    let mut r = res::Resolver::new(unsafe &mut *((&mut m.ast) as *mut Ast), str::from_raw(src as *const u8, len), pkg);
    r.resolve();
    let had = r.has_errors();
    return !had;
}

// Resolve `src`, find its first switch, feed the unguarded arms to a PatCx, and answer one probe:
// `probe_arm` < 0 asks whether a wildcard is still useful (NOT exhaustive); otherwise whether that
// arm is still reachable behind its predecessors.
fn engine_over(src: str, probe_arm: i64) bool {
    let mut p = loader::package_from_source(src, "std", unsafe shim::sc_host_platform());
    assert(p.ok, "snippet parses");
    let n = p.modules.len();
    let mut ok = true;
    for i in 0..n {
        ok = t_resolve(&mut p, i) && ok;
    }
    assert(ok, "snippet resolves");
    let u = n - 1;
    let a = unsafe &*p.module_ast_const(u as ModuleId);
    let mut mid = NODE_NONE;
    for k in 0..a.nnodes() {
        if a.at_const(a.nth_id(k)).kind == NodeKind::NODE_MATCH && mid == NODE_NONE {
            mid = a.nth_id(k);
        }
    }
    assert(mid != NODE_NONE, "switch found");
    let src2 = p.modules.at(u).source.as_str();
    let mut cx = pat::PatCx::new(&p, a, src2);
    let arms = a.at_const(mid).as_data.match_expr.arms;
    for i in 0..arms.len {
        let arm = a.at_const(unsafe a.list(arms)[i as usize]).as_data.match_arm;
        if probe_arm >= 0 && i as i64 >= probe_arm {
            continue;
        }
        if arm.guard == NODE_NONE {
            cx.add_arm(arm.pattern, i);
        }
    }
    if probe_arm < 0 {
        return cx.wildcard_useful();
    }
    let ap = a.at_const(unsafe a.list(arms)[probe_arm as usize]).as_data.match_arm.pattern;
    return cx.arm_reachable(ap, probe_arm as u32);
}

@test
fn usefulness_verdicts() {
    // The snippets are resolved, not checked, so no integer pattern has a recorded value: a literal
    // equals only a literal spelled alike, and the catch-all is reachable behind any literal set.
    assert(
        engine_over("fn f(n: i32) i32 { return switch n { 1 => 1, 2 => 2, _ => 0 }; }\n", 2),
        "catch-all reachable behind integer literals",
    );
    // A duplicate literal arm is not.
    assert(
        !engine_over("fn f(n: i32) i32 { return switch n { 1 => 1, 1 => 2, _ => 0 }; }\n", 1),
        "duplicate literal arm unreachable",
    );
    // An arm behind a complete or-cover is not.
    assert(
        !engine_over("enum E { A, B }\nfn f(e: E) i32 { return switch e { A | B => 1, B => 2 }; }\n", 1),
        "arm behind a complete or-cover unreachable",
    );
    // A complete variant switch leaves no wildcard useful.
    assert(
        !engine_over("enum E { A, B(i32), C }\nfn f(e: E) i32 { return switch e { A => 0, B(x) => x, C => 2 }; }\n", -1),
        "complete variant switch exhaustive",
    );
    // A catch-all row absorbs the wildcard probe.
    assert(
        engine_over("fn f(n: u8) i32 { return switch n { 0..=255 => 1, _ => 0 }; }\n", -1) == false,
        "a catch-all row absorbs the wildcard probe",
    );
}

// A qualified path in a pattern names a constant: a builtin limit reads as the literal of its value in
// the matched type; an associated constant (of a struct or an enum) and a named constant in a range
// bound keep their own type, the matched type or one that widens to it. Literal and range patterns,
// or-patterns, `if let` and tuple elements take them, at compile time too.
@test
fn constant_path_patterns() {
    h::expect_exit(
        "constant path patterns",
        M"(struct Lim { pub a: i32 }
extend Lim {
    pub const LO: u8 = 10;
    pub const HI: u8 = 20;
}
enum Lvl { Lo, Hi }
extend Lvl {
    pub const N: i32 = 3;
}
const MID: u8 = 15;
const fn band(x: u8) i32 {
    return switch x { 0..Lim::LO => 1, Lim::LO..=MID => 2, 16..=Lim::HI => 3, 21..=u8::MAX => 4 };
}
fn sign(x: i64) i32 {
    return switch x { i64::MIN..=-1 => -1, 0 => 0, 1..=i64::MAX => 1 };
}
fn half(x: u64) i32 {
    return switch x { 0..=i64::MAX => 1, 9223372036854775808..=u64::MAX => 2 };
}
fn choose(x: i32) i32 {
    return switch x { u8::MAX => 1, i32::MIN | i32::MAX => 2, Lvl::N => 3, _ => 4 };
}
fn wide(x: u16) i32 {
    if let Lim::HI = x {
        return 1;
    }
    return switch (x, x > 5) { (Lim::LO, true) => 2, (0..=Lim::HI, _) => 3, _ => 4 };
}
static_assert(band(0) == 1 && band(10) == 2 && band(15) == 2 && band(16) == 3 && band(255) == 4);
fn main() i32 {
    if sign(i64::MIN) != -1 || sign(0) != 0 || sign(i64::MAX) != 1 {
        return 1;
    }
    if half(9223372036854775807) != 1 || half(9223372036854775808) != 2 || half(u64::MAX) != 2 {
        return 2;
    }
    if choose(255) != 1 || choose(i32::MIN) != 2 || choose(i32::MAX) != 2 || choose(3) != 3 || choose(0) != 4 {
        return 3;
    }
    if wide(20) != 1 || wide(10) != 2 || wide(3) != 3 || wide(300) != 4 {
        return 4;
    }
    return band(12) - 2;
}
)",
        0,
    );
}

// Integer values and ranges cover their type's domain: every limit and literal spelling takes part,
// u64 bounds past i64::MAX included, and the domain is the matched type's, not a narrower constant's.
@test
fn integer_patterns_cover_the_domain() {
    h::expect_ok(
        "exhaustive integer switches",
        M"(fn a(x: i64) i32 { return switch x { i64::MIN..=-1 => 1, 0..=i64::MAX => 2 }; }
fn b(x: u64) i32 { return switch x { 0..=u64::MAX => 1 }; }
fn c(x: u64) i32 { return switch x { 0..=9223372036854775807 => 1, 9223372036854775808..=18446744073709551615 => 2 }; }
fn d(x: u8) i32 { return switch x { 0..=0x7F => 1, 128..=255 => 2 }; }
fn e(x: i8) i32 { return switch x { ..0 => 1, 0.. => 2 }; }
fn f(x: char) i32 { return switch x { '\0'..='a' => 1, 'b'..='\xff' => 2 }; }
fn main() i32 { return a(0) + b(0) + c(0) + d(0) + e(0) + f('a') - 8; }
)",
    );
    h::expect_err_msg(
        "a u64 switch missing its largest value",
        "fn f(x: u64) i32 { return switch x { 0..=18446744073709551614 => 1 }; }\n",
        "error: switch is not exhaustive\n--> <harness>:1:34",
    );
    h::expect_err_msg(
        "a constant narrower than the matched type",
        "struct Lim { pub a: i32 }\nextend Lim { pub const HI: u8 = 255; }\nfn f(x: u16) i32 { return switch x { 0..=Lim::HI => 1 }; }\n",
        "error: switch is not exhaustive\n--> <harness>:3:34",
    );
}

// A decision-tree edge keeps every row its value reaches: overlapping ranges split into pieces, two
// spellings of one integer (hex, decimal) are one constructor, and so are strings spelled alike;
// strings whose escapes may spell one value keep the arm-order test.
@test
fn overlapping_constructors_match_in_arm_order() {
    h::expect_exit(
        "overlapping constructors",
        M"(fn r(x: i32, b: bool) i32 { return switch (x, b) { (0..=5, true) => 1, (3..=10, _) => 2, _ => 3 }; }
fn v(x: i32, b: bool) i32 { return switch (x, b) { (4, true) => 1, (3..=10, _) => 2, _ => 3 }; }
fn hx(x: i32, b: bool) i32 { return switch (x, b) { (0x10, true) => 1, (16, false) => 2, _ => 3 }; }
fn s(t: str, b: bool) i32 { return switch (t, b) { ("a", true) => 1, ("a", false) => 2, _ => 3 }; }
fn esc(t: str, b: bool) i32 { return switch (t, b) { ("\x61", true) => 1, ("a", false) => 2, _ => 3 }; }
fn main() i32 {
    if r(4, false) != 2 || r(4, true) != 1 || r(11, true) != 3 {
        return 1;
    }
    if v(4, false) != 2 || v(4, true) != 1 {
        return 2;
    }
    if hx(16, false) != 2 || hx(16, true) != 1 {
        return 3;
    }
    if s("a", false) != 2 || s("a", true) != 1 || s("b", true) != 3 {
        return 4;
    }
    if esc("a", false) != 2 || esc("a", true) != 1 {
        return 5;
    }
    return 0;
}
)",
        0,
    );
}

// A pattern value is a constant: a qualified path naming a variant, a local, a limit outside the
// matched type, a constant of another type and a missing constant are errors, and so are a `mut`
// constant pattern and a range bound that is no value.
@test
fn constant_pattern_errors() {
    h::expect_err_msg(
        "a qualified unit variant",
        "enum E { A, B }\nfn f(e: E) i32 { return switch e { E::A => 1, _ => 2 }; }\n",
        "error: a pattern names a variant without its enum: write 'A', not 'E::A'\n--> <harness>:2:36",
    );
    h::expect_err_msg(
        "a local as a range bound",
        "fn f(x: i32, y: i32) i32 { return switch x { 0..=y => 1, _ => 2 }; }\n",
        "error: a pattern value must be a constant: 'y' is not one\n--> <harness>:1:50",
    );
    h::expect_err_msg(
        "a limit outside the matched type",
        "fn f(x: u64) i32 { return switch x { i64::MIN..=0 => 1, _ => 2 }; }\n",
        "error: integer literal is out of range for 'u64'\n--> <harness>:1:38",
    );
    h::expect_err_msg(
        "an associated constant of another type",
        "struct Foo { pub a: i32 }\nextend Foo { pub const K: i64 = 7; }\nfn f(x: i32) i32 { return switch x { Foo::K => 1, _ => 2 }; }\n",
        "error: mismatched types: expected 'i32', found 'i64'\n--> <harness>:3:38",
    );
    h::expect_err_msg(
        "a missing associated constant",
        "struct Foo { pub a: i32 }\nfn f(x: i32) i32 { return switch x { Foo::Q => 1, _ => 2 }; }\n",
        "error: no associated method or constant 'Q' on this type\n--> <harness>:2:43",
    );
    h::expect_err_msg(
        "a mut constant pattern",
        "struct Foo { pub a: i32 }\nextend Foo { pub const K: i32 = 7; }\nfn f(x: i32) i32 { return switch x { mut Foo::K => 1, _ => 2 }; }\n",
        "error: a constant pattern cannot be 'mut'",
    );
    h::expect_err_msg(
        "a wildcard range bound",
        "fn f(x: i32) i32 { return switch x { _..=5 => 1, _ => 2 }; }\n",
        "error: a range bound must be a constant",
    );
}

// A tuple pattern `(p0, p1, ..)` destructures a tuple in switch arms, `if let` and `while let`:
// nested patterns, `_`, `mut` bindings, literals, variant payloads and reference scrutinees (the
// bindings then borrow). A `String` element moves out once and is freed once (the fatal leak gate).
@test
fn tuple_patterns_destructure_tuples() {
    let r = h::compile_and_run_env(
        M"(enum E { A(i32), B }
fn heap(tag: str) String {
    let mut s = String::from_str("a heap string longer than twenty-three bytes: ");
    s.push_str(tag);
    return s;
}
fn peek(p: &(String, i32)) usize {
    return switch p {
        (s, 0) => s.len(),
        (_, n) => *n as usize,
    };
}
fn main() i32 {
    let t: (i32, (bool, i32)) = (4, (true, 5));
    let a = switch t {
        (4, (false, _)) => 1,
        (x, (true, mut y)) => {
            y += x;
            y;
        },
        (_, (false, _)) => 3,
    };
    let p = (E::A(3), 9);
    let b = switch p {
        (A(v), w) => v + w,
        (B, w) => w,
    };
    let q = (heap("q"), 0);
    let c = peek(&q) as i32;
    let moved = switch q {
        (s, 0) => s,
        (s, _) => s,
    };
    let o = Option::<(i32, String)>::Some((7, heap("o")));
    let mut d = 0;
    if let Some((n, mut st)) = o {
        st.push_str("!");
        d = n + st.len() as i32;
    }
    let mut v = Vector::<(i32, String)>::new();
    v.push((1, heap("one")));
    v.push((2, heap("two")));
    let mut e = 0;
    while let Some((k, s)) = v.pop() {
        e += k + s.len() as i32;
    }
    if a != 9 || b != 12 || c != 47 || moved.len() != 47 || d != 55 || e != 101 {
        return 1;
    }
    return 0;
}
)",
        "SC_LEAK_CHECK=fatal",
    );
    assert(r.built, "tuple patterns build");
    assert_eq(r.exit, 0);
}

// A `for` binding is an irrefutable pattern: a tuple (nested), `_`, `mut name` or a struct
// pattern. By-value elements move into the names; what no name takes (a `_` member, a member the
// pattern leaves out) is freed with the element, at the end of its iteration or at `break` (the
// fatal leak gate). Elements behind a reference bind by reference. `mut i` over a range is the
// induction variable itself: a write to it moves the loop.
@test
fn for_patterns_destructure_elements() {
    let r = h::compile_and_run_env(
        M"(struct Q {
    pub a: String,
    pub b: String,
    pub n: i32,
}
fn heap(tag: str) String {
    let mut s = String::from_str("a heap string longer than twenty-three bytes: ");
    s.push_str(tag);
    return s;
}
fn main() i32 {
    let ps: [(i32, i32); 3] = [(1, 2), (3, 4), (5, 6)];
    let mut s = 0;
    for (a, b) in ps {
        s += a * b;
    }
    let nest: [((i32, i32), i32); 2] = [((1, 2), 3), ((4, 5), 6)];
    for ((a, _), mut c) in nest {
        c += 1;
        s += a + c;
    }
    let ts: [(String, String); 2] = [(heap("a"), heap("b")), (heap("c"), heap("d"))];
    let mut t: usize = 0;
    for (x, _) in ts {
        t += x.len();
    }
    let qs: [Q; 3] = [Q { a: heap("1"), b: heap("2"), n: 1 }, Q { a: heap("3"), b: heap("4"), n: 2 }, Q { a: heap("5"), b: heap("6"), n: 3 }];
    for Q { b, n, .. } in qs {
        if n == 2 {
            break;
        }
        t += b.len();
    }
    let mut v = Vector::<(i32, String)>::new();
    v.push((1, heap("v")));
    for (k, name) in v.iter() {
        t += name.len() + *k as usize;
    }
    let mut w = 0;
    for mut i in 0..6 {
        w += i;
        i += 1;
    }
    for _ in 0..2 {
        w += 1;
    }
    if s != 60 || t != 189 || w != 8 {
        return 1;
    }
    return 0;
}
)",
        "SC_LEAK_CHECK=fatal",
    );
    assert(r.built, "for patterns build");
    assert_eq(r.exit, 0);
}

// A `for` pattern must match every element, and a name it binds without `mut` is not assignable.
@test
fn for_pattern_errors() {
    h::expect_err_msg(
        "a refutable for pattern",
        "fn main() i32 {\n    let os = [Option::<i32>::Some(1), Option::<i32>::None];\n    for Some(x) in os {\n        let _ = x;\n    }\n    return 0;\n}\n",
        "a 'for' pattern must match every element",
    );
    h::expect_err_msg(
        "an assignment to an immutable pattern name",
        "fn main() i32 {\n    let ps: [(i32, i32); 1] = [(1, 2)];\n    for (a, b) in ps {\n        a = b;\n    }\n    return 0;\n}\n",
        "cannot assign",
    );
}

@test
fn tuple_pattern_coverage_and_arity() {
    h::expect_ok(
        "tuple arms that cover every value",
        "fn f(t: (bool, bool)) i32 { return switch t { (true, _) => 1, (false, true) => 2, (false, false) => 3 }; }\nfn main() i32 { return f((true, false)) - 1; }\n",
    );
    h::expect_err_msg(
        "a tuple arm split that misses a value",
        "fn f(t: (bool, bool)) i32 { return switch t { (true, _) => 1, (false, true) => 2 }; }\n",
        "not exhaustive",
    );
    h::expect_err_msg(
        "a tuple pattern with the wrong element count",
        "fn f(t: (i32, bool)) i32 { return switch t { (a, b, c) => a, _ => 0 }; }\n",
        "a tuple pattern with 3 elements cannot match a value of type",
    );
    h::expect_err_msg(
        "a tuple pattern against a value that is not a tuple",
        "fn f(n: i32) i32 { return switch n { (a, b) => a, _ => 0 }; }\n",
        "a tuple pattern with 2 elements cannot match a value of type 'i32'",
    );
}

@test
fn tuple_patterns_evaluate_at_compile_time() {
    h::expect_exit(
        "tuple patterns in a const fn",
        "const fn f(a: i32, b: bool) i32 {\n    return switch (a, b) {\n        (0, _) => 1,\n        (x, true) => x * 2,\n        (x, false) => x,\n    };\n}\nstatic_assert(f(4, true) == 8);\nstatic_assert(f(0, false) == 1);\nstatic_assert(f(3, false) == 3);\nfn main() i32 {\n    return f(5, true) - 10;\n}\n",
        0,
    );
}
