// Self-hosted port of tests/borrow_gen_test.c: an auto-generating borrow-checker oracle. The borrow
// checker is a STATIC analysis, so each generated/fixed program carries a rule-derived VERDICT
// (accept vs reject); every program is compiled only through the typechecker (STAGE_TYPECHECK) and the
// oracle asserts the checker agrees. A rejection must come FROM the typechecker (a borrow/type error),
// never an unrelated earlier stage. Drives the real pipeline in-process through tests::harness.
import tests::harness as h;

// A scenario index list (there is no `[v; N]` repeat literal, so wrap the array in a struct and `{}`-zero it).
struct IdxBuf {
    pub b: [i32; 17],
}

// PRE/OWN and the per-family C `#define`s, each a full literal (Super-C does not concatenate consts, so
// SINK inlines OWN's text before the sink definition).
const PRE: str = "struct P { pub a: i32, pub b: i32 }\n";
const OWN: str = "struct Own { pub id: i32 }\nextend Own as Free { fn free(self: &mut Own) { } }\n";
const CDEF: str = "struct C { pub n: i32 }\nextend C { fn bump(self: &mut C) { self.n = self.n + 1; } fn get(self: &C) i32 { return self.n; } }\n";
const CDEF2: str = "struct H { pub v: i32 }\nextend H { fn geti(self: &H) &i32 { return &self.v; } fn seti(self: &mut H, n: i32) { self.v = n; } }\n";
const SINK: str = "struct Own { pub id: i32 }\nextend Own as Free { fn free(self: &mut Own) { } }\nfn sink(v: Own) i32 { return v.id; }\n";

// Two borrow-place overlap rules: whole `p` (index 0) overlaps everything; `p.a` (1) and `p.b` (2) are disjoint.
const fn overlap(i: i32, j: i32) bool {
    return i == j || i == 0 || j == 0;
}

// An i32-valued use of reference binding `name` that borrows place `pi`: `name.a` (whole, auto-deref) or `*name`.
fn use_ref(name: str, pi: i32) String {
    if pi == 0 {
        return format("{}.a", name);
    }
    return format("*{}", name);
}

// Compile through the typechecker only and assert the accept/reject verdict; a rejection must be a
// typecheck (borrow/type) error, not an earlier-stage failure.
fn check_case(label: str, src: str, expect_ok: bool) {
    let c = h::compile(src, h::STAGE_TYPECHECK);
    assert(c.ok() == expect_ok, label);
    // A reject comes from the borrow check: a type error in the snippet is a broken case, not a verdict
    // (`check_rejected_by_type_check` covers the rules the type checker owns).
    if !c.ok() && !expect_ok {
        if c.stage != h::STAGE_BORROWCK {
            eprintln("{}: stage {}: {}", label, c.stage, str::from_cstr(&c.first[0]));
        }
        assert(c.stage == h::STAGE_BORROWCK, label);
    }
}

// A rule the type checker owns (immutability, temporaries, Free-typed init): `src` fails the type check
// itself, before the borrow check, with a first message holding `needle`.
fn check_rejected_by_type_check(label: str, src: str, needle: str) {
    let c = h::compile(src, h::STAGE_TYPECHECK);
    let first = str::from_cstr(&c.first[0]);
    if c.ok() || c.stage != h::STAGE_TYPECHECK || !first.contains(needle) {
        eprintln("{}: stage {}: {}", label, c.stage, first);
    }
    assert(!c.ok() && c.stage == h::STAGE_TYPECHECK && first.contains(needle), label);
}

// Splice a prefix macro `pre` before a `body` snippet and check the verdict (the analog of the C
// `snprintf(PREFIX ...)` in the fixed-case families).
fn case_pre(pre: str, body: str, label: str, ok: bool) {
    let src = format("{}{}", pre, body);
    check_case(label, src.as_str(), ok);
}

// Family A: aliasing: two borrows of p, both kept live. Reject iff their places overlap and at least
// one is `&mut`.
@test
fn aliasing() {
    let kinds: []str = ["", "mut "];
    let places: []str = ["p", "p.a", "p.b"];
    for k1 in 0..2 {
        for k2 in 0..2 {
            for p1 in 0..3 {
                for p2 in 0..3 {
                    let src = format(
                        "{}fn main() i32 {{ let mut p = P {{ a: 1, b: 2 }};\n  let b1 = &{}{};\n  let b2 = &{}{};\n  let keep = {} + {}; return keep; }}\n",
                        PRE,
                        kinds[k1],
                        places[p1],
                        kinds[k2],
                        places[p2],
                        use_ref("b1", p1).as_str(),
                        use_ref("b2", p2).as_str(),
                    );
                    let want = !(overlap(p1, p2) && (k1 != 0 || k2 != 0));
                    check_case("aliasing", src.as_str(), want);
                }
            }
        }
    }
}

// Family B: use-while-borrowed: a stored `&[mut] p<P1>` kept live across a plain READ of p<P2>.
// Reject iff the read overlaps the borrow and the borrow is `&mut`.
@test
fn use_while_borrowed() {
    let kinds: []str = ["", "mut "];
    let places: []str = ["p", "p.a", "p.b"];
    for k in 0..2 {
        for p1 in 0..3 {
            for p2 in 0..3 {
                let src = format(
                    "{}fn main() i32 {{ let mut p = P {{ a: 1, b: 2 }};\n  let r = &{}{};\n  let y = {};\n  let keep = {}; return keep; }}\n",
                    PRE,
                    kinds[k],
                    places[p1],
                    places[p2],
                    use_ref("r", p1).as_str(),
                );
                let want = !(overlap(p1, p2) && k != 0);
                check_case("use while borrowed", src.as_str(), want);
            }
        }
    }
}

// Family C: NLL: identical to B but the reference's LAST use precedes the read, so EVERY case accepts.
@test
fn nll() {
    let kinds: []str = ["", "mut "];
    let places: []str = ["p", "p.a", "p.b"];
    for k in 0..2 {
        for p1 in 0..3 {
            for p2 in 0..3 {
                let src = format(
                    "{}fn main() i32 {{ let mut p = P {{ a: 1, b: 2 }};\n  let r = &{}{};\n  let used = {};\n  let y = {}; return used; }}\n",
                    PRE,
                    kinds[k],
                    places[p1],
                    use_ref("r", p1).as_str(),
                    places[p2],
                );
                check_case("nll", src.as_str(), true);
            }
        }
    }
}

// Family D: moves under a borrow on a Free type. Reject iff the move happens while the borrow is live.
@test
fn moves() {
    case_pre(
        OWN,
        "fn main() i32 { let s = Own { id: 1 }; let r = &s; let t = s; let keep = r.id; return t.id + keep; }\n",
        "move s while &s live",
        false,
    );
    case_pre(
        OWN,
        "fn main() i32 { let s = Own { id: 1 }; let r = &s; let keep = r.id; let t = s; return t.id + keep; }\n",
        "move s after &s dead (NLL)",
        true,
    );
}

// Family E: lifetimes / dangling returns and their safe counterparts (no prefix macro).
@test
fn lifetimes() {
    check_case("return &local", "fn f() &i32 { let x = 5; return &x; }\nfn main() i32 { return *f(); }\n", false);
    check_case(
        "return stored ref to local",
        "fn f() &i32 { let x = 5; let r = &x; return r; }\nfn main() i32 { return *f(); }\n",
        false,
    );
    check_case(
        "return ref chained to local",
        "fn f() &i32 { let x = 5; let r = &x; let s = r; return s; }\nfn main() i32 { return *f(); }\n",
        false,
    );
    check_case("return &by-value param", "fn f(x: i32) &i32 { return &x; }\nfn main() i32 { return *f(5); }\n", false);
    check_case(
        "return &field of local",
        "struct Q { pub a: i32 }\nfn f() &i32 { let q = Q { a: 1 }; return &q.a; }\nfn main() i32 { return *f(); }\n",
        false,
    );
    check_case(
        "return ref param",
        "fn f(x: &i32) &i32 { return x; }\nfn main() i32 { let v = 5; return *f(&v); }\n",
        true,
    );
    check_case(
        "return reborrow of ref param",
        "fn f(x: &i32) &i32 { let r = x; return r; }\nfn main() i32 { let v = 5; return *f(&v); }\n",
        true,
    );
}

// Family F: scope-scoped borrows and disjoint-field mutation: valid patterns the checker must ACCEPT.
@test
fn valid_patterns() {
    check_case(
        "scoped &mut released before use",
        "fn main() i32 { let mut x = 5; { let r = &mut x; *r = 1; } let y = x; return y; }\n",
        true,
    );
    case_pre(
        PRE,
        "fn add2(x: &mut i32, y: &mut i32) i32 { return *x + *y; }\nfn main() i32 { let mut p = P { a: 1, b: 2 }; return add2(&mut p.a, &mut p.b); }\n",
        "two disjoint &mut fields coexist",
        true,
    );
    check_case(
        "sequential borrows of x",
        "fn main() i32 { let mut x = 5; let a = &mut x; *a = 2; let b = &x; return *b; }\n",
        true,
    );
    check_case(
        "many shared borrows",
        "fn main() i32 { let x = 5; let a = &x; let b = &x; let c = &x; return *a + *b + *c; }\n",
        true,
    );
}

// Family G: the gaps closed after the first audit: implicit method-receiver borrows, assign-while-borrowed,
// reborrows, returned-reference provenance, moves across a loop back-edge; each with its valid counterpart.
@test
fn closed_gaps() {
    case_pre(
        CDEF,
        "fn main() i32 { let mut c = C { n: 0 }; let r = &c; c.bump(); return r.n; }\n",
        "method &mut self while &c live",
        false,
    );
    case_pre(
        CDEF,
        "fn main() i32 { let mut c = C { n: 0 }; let r = &mut c; let v = c.get(); return v + r.n; }\n",
        "method &self read while &mut c live",
        false,
    );
    check_case(
        "two-phase v.push(v.len())",
        "fn main() i32 { let mut v = Vector::<i32>::new(); v.push(1); v.push(v.len() as i32); return v.len() as i32; }\n",
        true,
    );
    case_pre(
        CDEF,
        "fn main() i32 { let mut c = C { n: 0 }; let r = &c; let v = r.n; c.bump(); return v + c.get(); }\n",
        "method after ref dead (NLL)",
        true,
    );
    check_case("assign x while &x live", "fn main() i32 { let mut x = 5; let r = &x; x = 9; return *r; }\n", false);
    check_case(
        "assign x after &x dead",
        "fn main() i32 { let mut x = 5; let r = &x; let v = *r; x = 9; return x + v; }\n",
        true,
    );
    check_case(
        "mutate origin while reborrow live",
        "fn main() i32 { let mut x = 5; let r = &mut x; let s = &*r; x = 9; return *s; }\n",
        false,
    );
    check_case(
        "assign arg while call-result ref live",
        "fn pick(a: &i32) &i32 { return a; }\nfn main() i32 { let mut x = 5; let r = pick(&x); x = 9; return *r; }\n",
        false,
    );
    case_pre(
        SINK,
        "fn main() i32 { let s = Own { id: 1 }; let mut i = 0; while i < 3 { let k = sink(s); i = i + 1; } return 0; }\n",
        "move in loop, no reassign",
        false,
    );
    case_pre(
        SINK,
        "fn main() i32 { let mut s = Own { id: 1 }; let mut i = 0; while i < 3 { let k = sink(s); s = Own { id: 2 }; i = i + 1; } return 0; }\n",
        "move + reassign in loop",
        true,
    );
    case_pre(
        SINK,
        "fn main() i32 { let mut s = Own { id: 1 }; let a = sink(s); s = Own { id: 2 }; let b = sink(s); return a + b; }\n",
        "reassign then move again",
        true,
    );
    check_case(
        "read scrutinee while &mut payload binding live",
        "enum E { V(i32) }\nfn main() i32 { let mut e = E::V(1); let r = switch &mut e { V(y) => y, }; let z = switch &e { V(q) => *q, }; *r = 2; return z; }\n",
        false,
    );
    check_case(
        "match &e shared peek",
        "enum E { V(i32) }\nfn main() i32 { let e = E::V(1); let n = switch &e { V(y) => *y, }; return n; }\n",
        true,
    );
    check_case(
        "assign arg while tuple-destructured ref live",
        "fn split<'a>(a: &'a mut i32, b: &'a mut i32) (&'a i32, &'a i32) { return a, b; }\nfn main() i32 { let mut x = 5; let mut y = 6; let (r, s) = split(&mut x, &mut y); x = 9; return *r + *s; }\n",
        false,
    );
    check_case(
        "tuple refs scoped, then assign arg",
        "fn split<'a>(a: &'a mut i32, b: &'a mut i32) (&'a i32, &'a i32) { return a, b; }\nfn main() i32 { let mut x = 5; let mut y = 6; { let (r, s) = split(&mut x, &mut y); let v = *r + *s; } x = 9; return x; }\n",
        true,
    );
    check_case(
        "non-reference tuple destructure",
        "fn dm(a: i32, b: i32) (i32, i32) { return a / b, a % b; }\nfn main() i32 { let mut x = 5; let (q, r) = dm(17, 5); x = 9; return q + r + x; }\n",
        true,
    );
}

// Family J: reference-binding semantics (second-audit fixes): reassign rebinds (A1), &mut moves / & copies
// (A2), a reborrow freezes its origin (A3), field-through-&mut is tracked (A4), constant array slots are
// disjoint (B5). Each rejection must be a borrow error; each has a valid counterpart.
@test
fn ref_semantics() {
    check_case(
        "A1 reassigned ref aliases new target",
        "fn main() i32 { let mut x = 0; let mut y = 0; let mut r = &mut x; r = &mut y; let b = y; return *r + b; }\n",
        false,
    );
    check_case(
        "A1 reassigned ref frees old target",
        "fn main() i32 { let mut x = 0; let mut y = 0; let mut r = &mut x; r = &mut y; let a = x; return *r + a; }\n",
        true,
    );
    check_case(
        "A1 reassign ref that had no prior borrow",
        "fn g(p: &mut i32) i32 { let mut y = 0; let mut r = p; r = &mut y; let b = y; return *r + b; }\nfn main() i32 { let mut x = 0; return g(&mut x); }\n",
        false,
    );
    check_case(
        "A2 copy of &mut moves it",
        "fn main() i32 { let mut x = 0; let r1 = &mut x; let r2 = r1; *r1 = 1; *r2 = 2; return x; }\n",
        false,
    );
    check_case(
        "A2 copy of & duplicates it",
        "fn main() i32 { let x = 0; let r1 = &x; let r2 = r1; let a = *r1; let b = *r2; return a + b; }\n",
        true,
    );
    check_case(
        "A2 copied & keeps origin tracked",
        "fn main() i32 { let mut x = 0; let r1 = &x; let r2 = r1; x = 9; return *r1 + *r2; }\n",
        false,
    );
    check_case(
        "A3 use origin while reborrow live",
        "fn main() i32 { let mut x = 0; let r = &mut x; let r2 = &mut *r; *r = 1; return *r2; }\n",
        false,
    );
    check_case(
        "A3 reborrow scoped, then use origin",
        "fn main() i32 { let mut x = 0; let r = &mut x; { let r2 = &mut *r; *r2 = 1; } *r = 2; return *r; }\n",
        true,
    );
    case_pre(
        PRE,
        "fn main() i32 { let mut p = P { a: 1, b: 2 }; let r = &mut p; let x = &mut r.a; let y = &mut r.a; return *x + *y; }\n",
        "A4 two &mut same field through ref",
        false,
    );
    case_pre(
        PRE,
        "fn main() i32 { let mut p = P { a: 1, b: 2 }; let r = &mut p; let x = &mut r.a; let y = &mut r.b; return *x + *y; }\n",
        "A4 disjoint fields through ref",
        true,
    );
    case_pre(
        PRE,
        "fn main() i32 { let mut p = P { a: 1, b: 2 }; let r = &mut p; let x = &mut r.a; let v = r.a; return *x + v; }\n",
        "A4 read field through ref while &mut field live",
        false,
    );
    case_pre(
        PRE,
        "fn main() i32 { let mut p = P { a: 1, b: 2 }; let r = &mut p; let x = &mut r.a; let z = &mut *r; return *x + z.a; }\n",
        "A4 whole reborrow overlaps field reborrow",
        false,
    );
    check_case(
        "B5 distinct constant slots coexist",
        "fn main() i32 { let mut a = [1, 2, 3]; let x = &mut a[0]; let y = &mut a[1]; return *x + *y; }\n",
        true,
    );
    check_case(
        "B5 read disjoint slot while &mut other slot",
        "fn main() i32 { let mut a = [1, 2, 3]; let x = &mut a[0]; let v = a[1]; return *x + v; }\n",
        true,
    );
    check_case(
        "B5 same constant slot conflicts",
        "fn main() i32 { let mut a = [1, 2, 3]; let x = &mut a[0]; let y = &mut a[0]; return *x + *y; }\n",
        false,
    );
    check_case(
        "B5 variable indices conservative",
        "fn main() i32 { let mut a = [1, 2, 3]; let i = 0; let j = 1; let x = &mut unsafe a[i]; let y = &mut unsafe a[j]; return *x + *y; }\n",
        false,
    );
}

// Family K: third-audit fixes: binding-scoped borrow regions, dangling stored refs, method-returned ref
// tracking, flow-accurate return-escape, `move` transparency, loop-aware definite-init, free-through-ref,
// places through ref params, union aliasing, tuple-let roots, same-call double use, unaddressable temporaries,
// defer replay, sub-statement NLL, `&mut`-out-param init. Each rejection paired with its nearest valid program.
@test
fn third_audit() {
    check_case(
        "K1 inner-scope rebind keeps borrow",
        "fn main() i32 { let mut x = 1; let y = 2; let mut r = &y; { r = &x; } let m = &mut x; return *r + *m; }\n",
        false,
    );
    check_case(
        "K1 inner-scope rebind, ref dead",
        "fn main() i32 { let mut x = 1; let y = 2; let mut r = &y; { r = &x; } let v = *r; let m = &mut x; *m = 3; return v; }\n",
        true,
    );
    check_case(
        "K2 stored ref outlives referent",
        "fn main() i32 { let x = 1; let mut r = &x; { let y = 2; r = &y; } return *r; }\n",
        false,
    );
    check_case(
        "K2 stored ref to longer-lived value",
        "fn main() i32 { let y = 2; let x = 1; let mut r = &x; { r = &y; } return *r; }\n",
        true,
    );
    case_pre(
        CDEF2,
        "fn main() i32 { let mut h = H { v: 1 }; let r = h.geti(); h.seti(5); return *r; }\n",
        "K3 mutate while method-returned ref live",
        false,
    );
    case_pre(
        CDEF2,
        "fn main() i32 { let mut h = H { v: 1 }; let v = *h.geti(); h.seti(5); return v + h.v; }\n",
        "K3 method ref deref'd before mutate",
        true,
    );
    check_case(
        "K4 return ref reassigned to local",
        "fn f(p: &i32) &i32 { let mut r = p; let x = 1; r = &x; return r; }\nfn main() i32 { let v = 5; return *f(&v); }\n",
        false,
    );
    check_case(
        "K4 return ref reassigned to param",
        "fn f(p: &i32) &i32 { let x = 1; let mut r = &x; r = p; return r; }\nfn main() i32 { let v = 5; return *f(&v); }\n",
        true,
    );
    case_pre(
        OWN,
        "fn main() i32 { let s = Own { id: 1 }; let t = move s; let u = s; return t.id + u.id; }\n",
        "K5 move keyword still moves",
        false,
    );
    case_pre(
        OWN,
        "fn main() i32 { let s = Own { id: 1 }; let t = move s; return t.id; }\n",
        "K5 move keyword, no reuse",
        true,
    );
    check_case(
        "K6 init only inside while",
        "fn main() i32 { let mut x: i32; let c = false; while c { x = 1; } return x; }\n",
        false,
    );
    check_case(
        "K6 init inside do-while",
        "fn main() i32 { let mut x: i32; do { x = 1; } while false; return x; }\n",
        true,
    );
    case_pre(
        OWN,
        "fn main() i32 { let mut s = Own { id: 1 }; let r = &mut s; r.free(); return 0; }\n",
        "K7 free through local ref",
        false,
    );
    case_pre(
        OWN,
        "fn kill(o: &mut Own) { o.free(); }\nfn main() i32 { let mut s = Own { id: 1 }; kill(&mut s); return 0; }\n",
        "K7 free through param ref",
        true,
    );
    check_case(
        "K8 overlapping reborrows through param",
        "fn f(p: &mut i32) i32 { let a = &mut *p; let b = &mut *p; return *a + *b; }\nfn main() i32 { let mut x = 0; return f(&mut x); }\n",
        false,
    );
    case_pre(
        PRE,
        "fn f(p: &mut P) i32 { let a = &mut p.a; let b = &mut p.b; return *a + *b; }\nfn main() i32 { let mut q = P { a: 1, b: 2 }; return f(&mut q); }\n",
        "K8 disjoint fields through param",
        true,
    );
    check_case(
        "K9 union members alias",
        "union U { pub a: i32, pub b: f32 }\nfn main() i32 { let mut u = U { a: 1 }; let r = &u.a; let m = &mut u.b; *m = 2.0; return *r; }\n",
        false,
    );
    check_case(
        "K9 union shared+shared ok",
        "union U { pub a: i32, pub b: f32 }\nfn main() i32 { let u = U { a: 1 }; let r = &u.a; let s = &u.a; return *r + *s; }\n",
        true,
    );
    check_case(
        "K10 tuple element double &mut",
        "fn two() (i32, i32) { return 1, 2; }\nfn main() i32 { let mut (a, b) = two(); let r = &a; let m = &mut a; *m = 9; return *r + b; }\n",
        false,
    );
    check_case(
        "K10 tuple element sequential borrows",
        "fn two() (i32, i32) { return 1, 2; }\nfn main() i32 { let mut (a, b) = two(); let r = &a; let v = *r; let m = &mut a; *m = 9; return v + b; }\n",
        true,
    );
    case_pre(
        OWN,
        "fn g(v: Own, m: &mut Own) i32 { return v.id + m.id; }\nfn main() i32 { let mut s = Own { id: 1 }; return g(s, &mut s); }\n",
        "K11 move + &mut same value in one call",
        false,
    );
    case_pre(
        OWN,
        "fn g(v: Own, w: Own) i32 { return v.id + w.id; }\nfn main() i32 { let s = Own { id: 1 }; return g(s, s); }\n",
        "K11 move same value twice in one call",
        false,
    );
    case_pre(
        OWN,
        "fn g(v: Own, w: Own) i32 { return v.id + w.id; }\nfn main() i32 { let s = Own { id: 1 }; let u = Own { id: 2 }; return g(s, u); }\n",
        "K11 move two distinct values",
        true,
    );
    let k12 = format(
        "{}fn make() P {{ return P {{ a: 1, b: 2 }}; }}\nfn main() i32 {{ let r = &make(); return r.a; }}\n",
        PRE,
    );
    check_rejected_by_type_check(
        "K12 address of call result",
        k12.as_str(),
        "cannot take the address of a temporary value",
    );
    case_pre(PRE, "fn main() i32 { let r = &P { a: 1, b: 2 }; return r.a; }\n", "K12 address of struct literal", true);
    case_pre(
        OWN,
        "fn main() i32 { let mut s = Own { id: 1 }; defer s.free(); let v = s.id; return v; }\n",
        "K13 use before deferred free",
        true,
    );
    case_pre(
        OWN,
        "fn main() i32 { let mut s = Own { id: 1 }; defer s.free(); defer s.free(); return 0; }\n",
        "K13 two defers free one value",
        false,
    );
    check_case(
        "K14 last use before &mut in one call",
        "fn f(v: i32, m: &mut i32) { *m = v; }\nfn main() i32 { let mut x = 1; let r = &x; f(*r, &mut x); return x; }\n",
        true,
    );
    check_case(
        "K14 assign from own borrow",
        "fn main() i32 { let mut x = 5; let r = &x; x = *r + 1; return x; }\n",
        true,
    );
    check_case(
        "K14 use after keeps borrow live",
        "fn f(v: i32, m: &mut i32) i32 { *m = v; return *m; }\nfn main() i32 { let mut x = 1; let r = &x; let v = f(*r, &mut x); return v + *r; }\n",
        false,
    );
    check_case(
        "K15 out-param init via &mut",
        "fn init(p: &mut i32) { *p = 42; }\nfn main() i32 { let mut x: i32; init(&mut x); return x; }\n",
        true,
    );
    check_case(
        "K15 shared borrow does not init",
        "fn peek(p: &i32) i32 { return *p; }\nfn main() i32 { let mut x: i32; let v = peek(&x); return x + v; }\n",
        false,
    );
}

// Family H: THREE simultaneous borrows of one variable, all kept live. Valid iff every overlapping pair
// is shared+shared (no overlapping pair includes a `&mut`). The place triples are the ones a pairwise
// family cannot express (b1 and b3 overlapping around a disjoint b2, a whole-value borrow beside both
// parts, three borrows of one field), under every kind combination.
@test
fn aliasing3() {
    let kinds: []str = ["", "mut "];
    let places: []str = ["p", "p.a", "p.b"];
    let triples: [][i32; 3] = [[1, 2, 1], [2, 1, 2], [1, 2, 0], [0, 1, 2], [1, 1, 2], [2, 2, 2]];
    for k1 in 0..2 {
        for k2 in 0..2 {
            for k3 in 0..2 {
                for t in 0..triples.len() {
                    let p1 = triples[t][0];
                    let p2 = triples[t][1];
                    let p3 = triples[t][2];
                    let src = format(
                        "{}fn main() i32 {{ let mut p = P {{ a: 1, b: 2 }};\n  let b1 = &{}{};\n  let b2 = &{}{};\n  let b3 = &{}{};\n  let keep = {} + {} + {}; return keep; }}\n",
                        PRE,
                        kinds[k1],
                        places[p1],
                        kinds[k2],
                        places[p2],
                        kinds[k3],
                        places[p3],
                        use_ref("b1", p1).as_str(),
                        use_ref("b2", p2).as_str(),
                        use_ref("b3", p3).as_str(),
                    );
                    let bad = overlap(p1, p2) && (k1 != 0 || k2 != 0) || overlap(p1, p3) && (k1 != 0 || k3 != 0) || overlap(
                        p2,
                        p3,
                    ) && (k2 != 0 || k3 != 0);
                    check_case("aliasing3", src.as_str(), !bad);
                }
            }
        }
    }
}

// Self-contained scenario bodies (each a function body returning i32) with a known verdict, drawn from the
// tricky valid cases and the closed-gap rejections. N_SNIPPET = 16.
const fn snippet_body(i: i32) str<'static> {
    return switch i {
        0 => "let mut x = 0; let a = &x; let b = &x; return *a + *b;",
        1 => "let mut x = 0; let r = &mut x; *r = 1; let y = x; return y;",
        2 => "let mut p = P { a: 1, b: 2 }; let ra = &mut p.a; let rb = &mut p.b; return *ra + *rb;",
        3 => "let mut x = 0; { let r = &mut x; *r = 1; } let y = x; return y;",
        4 => "let mut v = Vector::<i32>::new(); v.push(1); v.push(v.len() as i32); return v.len() as i32;",
        5 => "let mut x = 0; let r = &x; let s = &mut x; return *r + *s;",
        6 => "let mut x = 0; let r = &mut x; let y = x; return *r + y;",
        7 => "let mut x = 0; let r = &x; x = 9; return *r;",
        8 => "let mut x = 0; let mut y = 0; let mut r = &mut x; r = &mut y; let a = x; return *r + a;",
        9 => "let x = 0; let r1 = &x; let r2 = r1; return *r1 + *r2;",
        10 => "let mut x = 0; let r = &mut x; { let r2 = &mut *r; *r2 = 1; } *r = 2; return *r;",
        11 => "let mut p = P { a: 1, b: 2 }; let r = &mut p; let x = &mut r.a; let y = &mut r.b; return *x + *y;",
        12 => "let mut a = [1, 2, 3]; let x = &mut a[0]; let y = &mut a[1]; return *x + *y;",
        13 => "let mut x = 0; let r1 = &mut x; let r2 = r1; *r1 = 1; return *r2;",
        14 => "let mut x = 0; let r = &mut x; let r2 = &mut *r; *r = 1; return *r2;",
        15 => "let mut p = P { a: 1, b: 2 }; let r = &mut p; let x = &mut r.a; let y = &mut r.a; return *x + *y;",
        _ => "",
    };
}

// The per-snippet verdict: only 5,6,7,13,14,15 are invalid.
const fn snippet_ok(i: i32) bool {
    return switch i {
        5 => false,
        6 => false,
        7 => false,
        13 => false,
        14 => false,
        15 => false,
        _ => true,
    };
}

// Bundle snippets idx[0..n) into one program (each its own function; main sums them) and assert the verdict:
// accepted iff EVERY bundled snippet is individually valid.
fn bundle(idx: *const i32, n: i32, label: str) {
    let mut src = String::from_str(PRE);
    let mut calls = String::new();
    let mut ok = true;
    for i in 0..n {
        let bi = unsafe idx[i as usize];
        src.format_into("fn s{}() i32 {{ {} }}\n", i, snippet_body(bi));
        if i != 0 {
            calls.push_str(" + ");
        }
        calls.format_into("s{}()", i);
        ok = ok && snippet_ok(bi);
    }
    if n == 0 {
        calls.push_str("0");
    }
    src.format_into("fn main() i32 {{ return {}; }}\n", calls.as_str());
    check_case(label, src.as_str(), ok);
}

// Family I: composition: independent scenarios must not interfere, an invalid one must not be masked by
// valids, and per-function borrow state must not leak between them.
@test
fn composition() {
    // All valids bundled -> accept.
    let mut av = IdxBuf {};
    let mut nv: i32 = 0;
    for i in 0..16 {
        if snippet_ok(i) {
            unsafe av.b[nv as usize] = i;
            nv = nv + 1;
        }
    }
    bundle(&av.b[0], nv, "bundle: all valid scenarios");

    // Every invalid snippet, surrounded by all the valids -> reject.
    for j in 0..16 {
        if !snippet_ok(j) {
            let mut idx = IdxBuf {};
            let mut k: i32 = 0;
            for t in 0..nv {
                unsafe idx.b[k as usize] = unsafe av.b[t as usize];
                k = k + 1;
            }
            unsafe idx.b[k as usize] = j;
            k = k + 1;
            bundle(&idx.b[0], k, format("bundle: valids + invalid #{}", j).as_str());
        }
    }

    // Every invalid snippet FIRST, then all the valids -> reject: the order does not mask it either.
    for j in 0..16 {
        if !snippet_ok(j) {
            let mut idx = IdxBuf {};
            idx.b[0] = j;
            for t in 0..nv {
                unsafe idx.b[(t + 1) as usize] = unsafe av.b[t as usize];
            }
            bundle(&idx.b[0], nv + 1, format("bundle: invalid #{} + valids", j).as_str());
        }
    }
}

// Split declaration/initialization of immutable bindings: `let x: T;` followed by exactly one
// assignment on every path. The borrow checker's late-init set enforces assign-once; loops and
// maybe-assigned paths reject; Free-typed bindings keep requiring an initializer (RAII).
@test
fn split_init() {
    check_case("split init once", "fn main() i32 { let x: i32; x = 5; return x - 5; }\n", true);
    check_case("split init assign twice", "fn main() i32 { let x: i32; x = 5; x = 6; return x; }\n", false);
    check_case(
        "split init both arms",
        "fn pick(c: bool) i32 { let x: i32; if c { x = 1; } else { x = 2; } return x; }\nfn main() i32 { return pick(true); }\n",
        true,
    );
    check_case(
        "split init maybe then assign",
        "fn f(c: bool) i32 { let x: i32; if c { x = 1; } x = 2; return x; }\nfn main() i32 { return f(false); }\n",
        false,
    );
    check_case(
        "split init inside loop",
        "fn main() i32 { let x: i32; let mut i = 0; while i < 3 { x = i; i = i + 1; } return x; }\n",
        false,
    );
    check_case("split decl use before init", "fn main() i32 { let x: i32; return x; }\n", false);
    check_case(
        "split init switch arms",
        "fn f(v: i32) i32 { let x: i32; switch v { 1 => { x = 10; }, _ => { x = 20; } }; return x; }\nfn main() i32 { return f(1); }\n",
        true,
    );
    check_rejected_by_type_check(
        "split init free-typed rejected",
        "fn main() i32 { let v: Vector<i64>; v = Vector::<i64>::new(); let _ = &v; return 0; }\n",
        "a Free-typed binding must be initialized when declared",
    );
    check_rejected_by_type_check(
        "assign to initialized immutable still rejected",
        "fn main() i32 { let x: i32 = 1; x = 2; return x; }\n",
        "cannot assign to this expression",
    );
}

// Specific rejection diagnostics by message. The generated oracle above proves accept-vs-reject
// verdicts; this batch pins the exact wording of the rules that the oracle does not name.
@test
fn rejection_messages() {
    h::expect_err_msg(
        "move out of const",
        "struct O { pub id: i32 }\nextend O as Free { fn free(self: &mut O) {} }\nconst S: O = O { id: 1 };\nfn take(v: O) i32 { return v.id; }\nfn main() i32 { return take(S); }\n",
        "cannot move a value out of a 'const' binding",
    );
    h::expect_err_msg(
        "free through a borrow",
        "struct O { pub id: i32 }\nextend O as Free { fn free(self: &mut O) {} }\nfn main() i32 { let mut o = O { id: 1 }; let r = &mut o; r.free(); return 0; }\n",
        "cannot free a borrowed value",
    );
    h::expect_err_msg(
        "immutable init inside a loop",
        "fn main() i32 { let x: i32; for _i in 0..2 { x = 1; } return 0; }\n",
        "cannot initialize an immutable binding inside a loop it was declared outside of",
    );
    h::expect_err_msg(
        "move a value captured by an enclosing closure",
        "struct O { pub id: i32 }\nextend O as Free { fn free(self: &mut O) {} }\nfn main() i32 { let o = O { id: 1 }; let f = || { let g = || { let t = o; let _ = t.id; }; g(); }; f(); return 0; }\n",
        "cannot take ownership of a value also captured by an enclosing closure",
    );
    h::expect_err_msg(
        "return lifetime cannot be inferred",
        "struct T { pub a: i32 }\nfn pick(x: &T, y: &T) &T { return x; }\nfn main() i32 { return 0; }\n",
        "missing lifetime specifier",
    );
    h::expect_err_msg(
        "mutable borrow while shared borrow is live",
        "fn main() i32 { let mut v = 1; let a = &v; let b = &mut v; *b = 2; let _ = *a; return 0; }\n",
        "cannot borrow this value as mutable while it is already borrowed as immutable",
    );
}

// A second live '&mut' to the same place while the first is still used: the many-vs-one borrow rule
// names the mutable-mutable conflict specifically.
@test
fn two_live_mutable_borrows() {
    h::expect_err_msg(
        "two mutable borrows of one place",
        "fn main() i32 { let mut x = 1; let a = &mut x; let b = &mut x; *a = 2; *b = 3; return 0; }\n",
        "cannot borrow this value as mutable while it is already borrowed as mutable",
    );
}

// `n` borrows of one local, all live across an `if` (every one is read after it).
fn many_borrows_src(n: i32) String {
    let mut s = String::from_str("fn main() i32 {\n    let x: i32 = 1;\n");
    for i in 0..n {
        s.push_str(format("    let r{} = &x;\n", i).as_str());
    }
    s.push_str("    let mut t = 0;\n    if x > 0 { t = 1; } else { t = 2; }\n");
    for i in 0..n {
        s.push_str(format("    t = t + *r{};\n", i).as_str());
    }
    s.push_str("    return t;\n}\n");
    return s;
}

// A branch snapshot holds every borrow the live state can hold; past the table's capacity the
// function is rejected with a named limit instead of losing borrows.
@test
fn many_live_borrows_across_a_branch() {
    let ok = many_borrows_src(100);
    h::expect_ok("100 live borrows across an if", ok.as_str());
    let over = many_borrows_src(300);
    h::expect_err_msg("300 live borrows", over.as_str(), "exceeds the borrow checker's limit of 256 live borrows");
}

// Ownership derived through nested generic instances: `W<W<String>>`, and `S<String>` whose member
// names `W<T>`, own their String, so a second move is an error and a single move frees it once.
@test
fn nested_generic_instances_own_their_members() {
    let wdecl = "struct W<T> { pub a: T }\nstruct S<T> { pub a: W<T> }\n";
    let mut twice = String::from_str(wdecl);
    twice.push_str(
        "fn take(w: W<W<String>>) i32 { return w.a.a.len() as i32; }\nfn main() i32 { let x = W::<W<String>> { a: W::<String> { a: String::from_str(\"abc\") } }; let n = take(x); return n + take(x); }\n",
    );
    h::expect_err_msg("W<W<String>> moved twice", twice.as_str(), "use of moved value");
    let mut twice_s = String::from_str(wdecl);
    twice_s.push_str(
        "fn take(w: S<String>) i32 { return w.a.a.len() as i32; }\nfn main() i32 { let x = S::<String> { a: W::<String> { a: String::from_str(\"abc\") } }; let n = take(x); return n + take(x); }\n",
    );
    h::expect_err_msg("S<String> moved twice", twice_s.as_str(), "use of moved value");
    let mut once = String::from_str(wdecl);
    once.push_str(
        "fn take(w: S<String>) i32 { return w.a.a.len() as i32; }\nfn main() i32 { let x = S::<String> { a: W::<String> { a: String::from_str(\"a string long enough to live on the heap\") } }; let y = W::<W<String>> { a: W::<String> { a: String::from_str(\"another string long enough for the heap\") } }; return take(x) + y.a.a.len() as i32; }\n",
    );
    let r = h::compile_and_run_env(once.as_str(), "SC_LEAK_CHECK=fatal");
    assert(r.built, "nested generic owners build");
    assert_eq(r.exit, 79);
}
