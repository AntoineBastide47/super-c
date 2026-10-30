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
const fn overlap(i: usize, j: usize) bool {
    return i == j || i == 0 || j == 0;
}

// An i32-valued use of reference binding `name` that borrows place `pi`: `name.a` (whole, auto-deref) or `*name`.
fn use_ref(name: str, pi: usize) String {
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
            eprintln("{}: stage {}: {}", label, c.stage, str::from_cbuf(c.first));
        }
        assert(c.stage == h::STAGE_BORROWCK, label);
    }
}

// A rule the type checker owns (immutability, temporaries, Free-typed init): `src` fails the type check
// itself, before the borrow check, with a first message holding `needle`.
fn check_rejected_by_type_check(label: str, src: str, needle: str) {
    let c = h::compile(src, h::STAGE_TYPECHECK);
    let first = str::from_cbuf(c.first);
    if c.ok() || c.stage != h::STAGE_TYPECHECK || !first.contains(needle) {
        eprintln("{}: stage {}: {}", label, c.stage, first);
    }
    assert(!c.ok() && c.stage == h::STAGE_TYPECHECK && first.contains(needle), label);
}

// Splice a prefix macro `pre` before a `body` snippet and check the verdict (the analog of the C
// `snprintf(PREFIX ...)` in the fixed-case families).
fn case_pre(pre: str, body: str, label: str, ok: bool) {
    let src = format("{}{}", pre, body);
    check_case(label, &src, ok);
}

// Family A: aliasing: two borrows of p, both kept live. Reject iff their places overlap and at least
// one is `&mut`.
@test
fn aliasing() {
    let kinds: []str = ["", "mut "];
    let places: []str = ["p", "p.a", "p.b"];
    for k1 in 0..kinds.len() {
        for k2 in 0..kinds.len() {
            for p1 in 0..places.len() {
                for p2 in 0..places.len() {
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
                    check_case("aliasing", &src, want);
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
    for k in 0..kinds.len() {
        for p1 in 0..places.len() {
            for p2 in 0..places.len() {
                let src = format(
                    "{}fn main() i32 {{ let mut p = P {{ a: 1, b: 2 }};\n  let r = &{}{};\n  let y = {};\n  let keep = {}; return keep; }}\n",
                    PRE,
                    kinds[k],
                    places[p1],
                    places[p2],
                    use_ref("r", p1).as_str(),
                );
                let want = !(overlap(p1, p2) && k != 0);
                check_case("use while borrowed", &src, want);
            }
        }
    }
}

// Family C: NLL: identical to B but the reference's LAST use precedes the read, so EVERY case accepts.
@test
fn nll() {
    let kinds: []str = ["", "mut "];
    let places: []str = ["p", "p.a", "p.b"];
    for k in 0..kinds.len() {
        for p1 in 0..places.len() {
            for p2 in 0..places.len() {
                let src = format(
                    "{}fn main() i32 {{ let mut p = P {{ a: 1, b: 2 }};\n  let r = &{}{};\n  let used = {};\n  let y = {}; return used; }}\n",
                    PRE,
                    kinds[k],
                    places[p1],
                    use_ref("r", p1).as_str(),
                    places[p2],
                );
                check_case("nll", &src, true);
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
        "reassign a reference while a reborrow through it is live",
        "fn main() i32 { let x = 5; let y = 6; let mut r = &x; let s = &*r; r = &y; return *s + *r; }\n",
        true,
    );
    check_case(
        "reassign a &mut while a reborrow through it is live",
        "fn main() i32 { let mut x = 5; let mut y = 6; let mut r = &mut x; let s = &mut *r; r = &mut y; *s = 1; *r = 2; return x + y; }\n",
        true,
    );
    check_case(
        "assign the referent while a reborrow through a reassigned reference is live",
        "fn main() i32 { let mut x = 5; let y = 6; let mut r = &x; let s = &*r; r = &y; x = 9; return *s + *r; }\n",
        false,
    );
    check_case(
        "an overloaded index result borrowed across loop iterations",
        "struct N { pub v: Vector<String> }\nextend N as Index<String, []String> {\n    pub fn index(self: &Self, i: usize) &String { return &self.v[i]; }\n    pub fn index_range(self: &Self, r: Range<usize>) []String { return self.v[r.start..r.end]; }\n}\nfn main() i32 { let mut n = N { v: Vector::<String>::new() }; n.v.push(String::from_str(\"a\")); let mut ks = Vector::<str>::new(); for i in 0..n.v.len() { ks.push(n[i].as_str()); } return ks[0].len() as i32 - 1; }\n",
        true,
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
        "fn split<'a>(a: &'a mut i32, b: &'a mut i32) (&'a i32, &'a i32) { return (a, b); }\nfn main() i32 { let mut x = 5; let mut y = 6; let (r, s) = split(&mut x, &mut y); x = 9; return *r + *s; }\n",
        false,
    );
    check_case(
        "tuple refs scoped, then assign arg",
        "fn split<'a>(a: &'a mut i32, b: &'a mut i32) (&'a i32, &'a i32) { return (a, b); }\nfn main() i32 { let mut x = 5; let mut y = 6; { let (r, s) = split(&mut x, &mut y); let v = *r + *s; } x = 9; return x; }\n",
        true,
    );
    check_case(
        "non-reference tuple destructure",
        "fn dm(a: i32, b: i32) (i32, i32) { return (a / b, a % b); }\nfn main() i32 { let mut x = 5; let (q, r) = dm(17, 5); x = 9; return q + r + x; }\n",
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
        "fn two() (i32, i32) { return (1, 2); }\nfn main() i32 { let mut (a, b) = two(); let r = &a; let m = &mut a; *m = 9; return *r + b; }\n",
        false,
    );
    check_case(
        "K10 tuple element sequential borrows",
        "fn two() (i32, i32) { return (1, 2); }\nfn main() i32 { let mut (a, b) = two(); let r = &a; let v = *r; let m = &mut a; *m = 9; return v + b; }\n",
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
    check_rejected_by_type_check("K12 address of call result", &k12, "cannot take the address of a temporary value");
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
        "K15 &mut of an uninitialized value is a use",
        "fn init(p: &mut i32) { *p = 42; }\nfn main() i32 { let mut x: i32; init(&mut x); return x; }\n",
        false,
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
    let triples: [][usize; 3] = [[1, 2, 1], [2, 1, 2], [1, 2, 0], [0, 1, 2], [1, 1, 2], [2, 2, 2]];
    for k1 in 0..kinds.len() {
        for k2 in 0..kinds.len() {
            for k3 in 0..kinds.len() {
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
                    check_case("aliasing3", &src, !bad);
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
    check_case(label, &src, ok);
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
        "fn f(v: i32) i32 { let x: i32; switch v { 1 => { x = 10; }, _ => { x = 20; } } return x; }\nfn main() i32 { return f(1); }\n",
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
    h::expect_ok("100 live borrows across an if", &ok);
    let over = many_borrows_src(300);
    h::expect_err_msg("300 live borrows", &over, "exceeds the borrow checker's limit of 256 live borrows");
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
    h::expect_err_msg("W<W<String>> moved twice", &twice, "use of moved value");
    let mut twice_s = String::from_str(wdecl);
    twice_s.push_str(
        "fn take(w: S<String>) i32 { return w.a.a.len() as i32; }\nfn main() i32 { let x = S::<String> { a: W::<String> { a: String::from_str(\"abc\") } }; let n = take(x); return n + take(x); }\n",
    );
    h::expect_err_msg("S<String> moved twice", &twice_s, "use of moved value");
    let mut once = String::from_str(wdecl);
    once.push_str(
        "fn take(w: S<String>) i32 { return w.a.a.len() as i32; }\nfn main() i32 { let x = S::<String> { a: W::<String> { a: String::from_str(\"a string long enough to live on the heap\") } }; let y = W::<W<String>> { a: W::<String> { a: String::from_str(\"another string long enough for the heap\") } }; return take(x) + y.a.a.len() as i32; }\n",
    );
    let r = h::compile_and_run_env(&once, "SC_LEAK_CHECK=fatal");
    assert(r.built, "nested generic owners build");
    assert_eq(r.exit, 79);
}

// A `&mut` reference passed to a `&mut self` method whose result grants write is an exclusive
// reborrow of its pointee: the result's loan conflicts with every later use of the pointee while the
// result lives, as an autoref of the pointee (`(*src).index_mut(..)`) or a local's does. A use after
// the result's last use, and shared calls, stay accepted.
@test
fn reborrow_through_a_mut_reference_argument() {
    let pre = "fn main() i32 { let mut v = Vector::<i32>::new(); v.push(1); return f(&mut v); }\n";
    h::expect_err_msg(
        "index_mut then at",
        format(
            "{}fn f(src: &mut Vector<i32>) i32 {{ let d = src.index_mut(0); let r = src.at(0); *d = 5; return *r; }}\n",
            pre,
        ).as_str(),
        "cannot borrow this value as immutable while it is already borrowed as mutable",
    );
    h::expect_err_msg(
        "index_mut then len",
        format(
            "{}fn f(src: &mut Vector<i32>) i32 {{ let d = src.index_mut(0); let n = src.len(); *d = n as i32; return 0; }}\n",
            pre,
        ).as_str(),
        "cannot use this value while it is mutably borrowed",
    );
    h::expect_err_msg(
        "index_mut then push",
        format(
            "{}fn f(src: &mut Vector<i32>) i32 {{ let d = src.index_mut(0); src.push(2); *d = 3; return 0; }}\n",
            pre,
        ).as_str(),
        "cannot use this value while it is mutably borrowed",
    );
    let push = h::compile(
        format(
            "{}fn f(src: &mut Vector<i32>) i32 {{ let d = src.index_mut(0); src.push(2); *d = 3; return 0; }}\n",
            pre,
        ).as_str(),
        h::STAGE_TYPECHECK,
    );
    assert(!push.msg_has("immutable"), "the reborrow is named mutable");
    h::expect_err_msg(
        "explicit deref, index_mut then len",
        format(
            "{}fn f(src: &mut Vector<i32>) i32 {{ let d = (*src).index_mut(0); let n = src.len(); *d = n as i32; return 0; }}\n",
            pre,
        ).as_str(),
        "cannot use this value while it is mutably borrowed",
    );
    h::expect_err_msg(
        "local, index_mut then len",
        "fn main() i32 { let mut v = Vector::<i32>::new(); v.push(1); let d = v.index_mut(0); let n = v.len(); *d = n as i32; return 0; }\n",
        "cannot use this value while it is mutably borrowed",
    );
    check_case(
        "use after the reborrow's last use",
        format(
            "{}fn f(src: &mut Vector<i32>) i32 {{ let d = src.index_mut(0); *d = 3; src.push(2); return *src.at(0) + src.len() as i32; }}\n",
            pre,
        ).as_str(),
        true,
    );
    check_case(
        "shared calls through a mutable reference",
        format(
            "{}fn f(src: &mut Vector<i32>) i32 {{ let r = src.at(0); let n = src.len(); return *r + n as i32; }}\n",
            pre,
        ).as_str(),
        true,
    );
}

// Arguments evaluate left to right: a scalar read out of a place is taken at its own position when a
// later argument may write the place (`ir::lower` `pin_read`). So a field read through a `Box`'s
// `Deref` ends that borrow before a later argument's `&mut` (the plain-reference shape always
// compiled), and the call sees the value before a later argument changes it.
@test
fn argument_reads_take_their_position() {
    let def = "struct U { pub a: String, pub n: u64 }\nfn take(a: String, n: u64, b: String) u64 { return a.len() as u64 + n + b.len() as u64; }\n";
    h::expect_exit(
        "a field read through Box before a later &mut argument",
        format(
            "{}fn main() i32 {{ let mut v = Vector::<Box<U>>::new(); v.push(Box::<U>::new(U {{ a: String::new(), n: 3 }})); let u = v.index_mut(0); let r = take(replace(&mut u.a, String::new()), u.n, replace(&mut u.a, String::new())); return r as i32; }}\n",
            def,
        ).as_str(),
        3,
    );
    h::expect_exit(
        "a field read through a reference before a later &mut argument",
        format(
            "{}fn main() i32 {{ let mut v = Vector::<U>::new(); v.push(U {{ a: String::new(), n: 3 }}); let u = v.index_mut(0); let r = take(replace(&mut u.a, String::new()), u.n, replace(&mut u.a, String::new())); return r as i32; }}\n",
            def,
        ).as_str(),
        3,
    );
    h::expect_exit(
        "a field read before a later argument writes it",
        "struct U { pub n: u64 }\nfn set(u: &mut U) u64 { u.n = 5; return 0; }\nfn take2(a: u64, b: u64) u64 { return a * 10 + b; }\nfn main() i32 { let mut x = U { n: 3 }; let mut bx = Box::<U>::new(U { n: 3 }); let r = take2(x.n, set(&mut x)); let r2 = take2(bx.n, set(&mut *bx)); return (r + r2) as i32; }\n",
        60,
    );
    h::expect_exit(
        "a struct value read before a later argument writes it",
        "struct P { pub a: i64, pub b: i64 }\nfn set(p: &mut P) i64 { p.a = 5; return 0; }\nfn take(p: P, z: i64) i64 { return p.a * 10 + z; }\nfn main() i32 { let mut p = P { a: 3, b: 0 }; return take(p, set(&mut p)) as i32; }\n",
        30,
    );
    // An owned argument moves at its own position, so a later argument may no longer borrow it (the
    // call used to see the value that argument changed).
    h::expect_err_msg(
        "an owned argument borrowed by a later argument",
        "fn grow(s: &mut String) u64 { s.push_str(\"cd\"); return 0; }\nfn take(a: String, b: u64) u64 { return a.len() as u64 + b; }\nfn main() i32 { let mut s = String::from_str(\"ab\"); return take(s, grow(&mut s)) as i32; }\n",
        "use of moved value",
    );
    // The moved-out value is a scope temporary: an exit inside a later argument releases it.
    let r = h::compile_and_run_env(
        "fn take(a: String, b: u64) u64 { return a.len() as u64 * 10 + b; }\nfn f(c: bool) u64 { let s = String::from_str(\"abc\"); return take(s, switch c { true => { return 7; }, false => 2u64, }); }\nfn main() i32 { return (f(true) + f(false)) as i32; }\n",
        "SC_LEAK_CHECK=fatal",
    );
    assert(r.built, "an exit in a later argument builds");
    assert_eq(r.exit, 39);
}

// A by-value argument tied to a result only through tokens behind its references passes on what
// lies behind them, not what its own references borrow: `Option<&K>` tied through `K`, or
// `Option<&'a S<'b>>` tied through `'b`, adds no `'a` region and no loan on the `S`. A token at
// the argument's own level still ties its references, so every dangling case stays rejected.
@test
fn reference_levels_inside_by_value_arguments() {
    let hold = "struct Holder<'b> { pub r: &'b i32 }\n";
    let get = "fn get<'a, 'b>(o: Option<&'a Holder<'b>>) Option<&'b i32> { return switch o { Some(h) => Option::<&i32>::Some(h.r), None => Option::<&i32>::None, }; }\n";
    let id = "fn id<'a, 'b>(o: Option<&'a Holder<'b>>) Option<&'a Holder<'b>> { return o; }\n";
    let ret = "lifetime mismatch: the returned value's lifetime is not declared to outlive the return type's lifetime";
    let dead = "borrowed value does not live long enough: it is destroyed at the end of this block while a reference to it is still stored";
    h::expect_ok(
        "Option<&K> tied through K into a lifetime-generic result",
        "struct M<K> { pub x: K }\npub struct It<'a, K> { pub p: *const K }\nextend<K> M<K> { fn range<'s>(self: &'s M<K>, lo: Option<&K>) It<'s, K> { let _ = lo; return It::<K> { p: &self.x }; } }\nfn fwd<'s, K>(m: &'s M<K>, lo: Option<&K>) It<'s, K> { return m.range(lo); }\nfn main() i32 { return 0; }\n",
    );
    h::expect_ok(
        "Option<&'a S<'b>> forwarded to a 'b result",
        format(
            "{}{}fn fwd<'a, 'b>(o: Option<&'a Holder<'b>>) Option<&'b i32> {{ return get(o); }}\nfn main() i32 {{ return 0; }}\n",
            hold,
            get,
        ).as_str(),
    );
    h::expect_ok(
        "a 'b result holds no loan on the Holder its argument borrows",
        format(
            "{}{}fn main() i32 {{ let x = 5; let y = 6; let mut h = Holder {{ r: &x }}; let res = get(Option::<&Holder>::Some(&h)); h = Holder {{ r: &y }}; let _ = h.r; return switch res {{ Some(r) => *r - 5, None => 1, }}; }}\n",
            hold,
            get,
        ).as_str(),
    );
    let out = "struct Out<'x, 'b> { pub o: Option<&'x Holder<'b>> }\n";
    h::expect_ok(
        "an Option<&'x S<'b>> struct member forwarded to a 'b result",
        format(
            "{}{}{}fn f<'x, 'b>(s: Out<'x, 'b>) Option<&'b i32> {{ return get(s.o); }}\nfn l<'x, 'b>(o: Option<&'x Holder<'b>>) Option<&'b i32> {{ let s = Out {{ o: o }}; return get(s.o); }}\nfn main() i32 {{ let x = 5; let mut res = Option::<&i32>::None; {{ let h = Holder {{ r: &x }}; let s = Out {{ o: Option::<&Holder>::Some(&h) }}; res = get(s.o); }} return switch res {{ Some(r) => *r - 5, None => 1, }}; }}\n",
            hold,
            out,
            get,
        ).as_str(),
    );
    h::expect_ok(
        "Vector<&'a K> tied through K",
        "fn first<'a, K: Copy>(v: Vector<&'a K>) K { return *v[0]; }\nfn fwd<'a, 'b>(v: Vector<&'a &'b i32>) &'b i32 { return first(v); }\nfn main() i32 { return 0; }\n",
    );
    h::expect_ok(
        "a store of K out of an Option<&K> holds no loan of the Option's reference",
        "fn put<K: Copy>(v: &mut Vector<K>, x: Option<&K>) { switch x { Some(k) => { v.push(*k); }, None => {}, } }\nfn main() i32 { let a = 1; let b = 2; let mut v = Vector::<&i32>::new(); let mut k = &a; put(&mut v, Option::<&&i32>::Some(&k)); k = &b; let _ = *k; return *v[0] - 1; }\n",
    );
    h::expect_err_msg(
        "a returned Option's own 'a is not 'b",
        format(
            "{}fn bad<'a, 'b>(o: Option<&'a Holder<'b>>) Option<&'b Holder<'b>> {{ return o; }}\nfn main() i32 {{ return 0; }}\n",
            hold,
        ).as_str(),
        ret,
    );
    h::expect_err_msg(
        "a struct member's own 'x is not 'b",
        format(
            "{}{}fn g<'x, 'b>(s: Out<'x, 'b>) Option<&'b Holder<'b>> {{ return s.o; }}\nfn main() i32 {{ return 0; }}\n",
            hold,
            out,
        ).as_str(),
        ret,
    );
    h::expect_err_msg(
        "a call tied through the Option's own 'a returns it",
        format(
            "{}{}fn bad<'a, 'b>(o: Option<&'a Holder<'b>>) Option<&'b Holder<'b>> {{ return id(o); }}\nfn main() i32 {{ return 0; }}\n",
            hold,
            id,
        ).as_str(),
        ret,
    );
    h::expect_err_msg(
        "a Vector<&'a K> call tied through 'a returns it",
        "fn get0<'a, K>(v: Vector<&'a K>) &'a K { return v[0]; }\nfn bad<'a, 'b>(v: Vector<&'a &'b i32>) &'b &'b i32 { return get0(v); }\nfn main() i32 { return 0; }\n",
        ret,
    );
    h::expect_err_msg(
        "a result tied through the Option's own 'a borrows the Holder",
        format(
            "{}{}fn main() i32 {{ let x = 5; let y = 6; let mut h = Holder {{ r: &x }}; let res = id(Option::<&Holder>::Some(&h)); h = Holder {{ r: &y }}; let _ = h.r; return switch res {{ Some(r) => *r.r - 5, None => 1, }}; }}\n",
            hold,
            id,
        ).as_str(),
        "cannot assign to this value while it is borrowed",
    );
    h::expect_err_msg(
        "a 'b result outlives the value behind the reference",
        format(
            "{}{}fn main() i32 {{ let mut res = Option::<&i32>::None; {{ let x = 5; let h = Holder {{ r: &x }}; res = get(Option::<&Holder>::Some(&h)); }} return switch res {{ Some(r) => *r - 5, None => 1, }}; }}\n",
            hold,
            get,
        ).as_str(),
        dead,
    );
    h::expect_err_msg(
        "an elided output keeps the Option's own reference",
        "fn f<K>(o: Option<&K>) Option<&K> { return o; }\nfn main() i32 { let mut res = Option::<&i32>::None; { let k = 1; res = f(Option::<&i32>::Some(&k)); } return switch res { Some(r) => *r, None => 0, }; }\n",
        dead,
    );
    h::expect_err_msg(
        "a type argument at the own level keeps the reference",
        "fn h<T>(x: Option<T>) T { return x.unwrap(); }\nfn main() i32 { let mut r = &0; { let k = 1; r = h(Option::<&i32>::Some(&k)); } return *r; }\n",
        dead,
    );
    h::expect_err_msg(
        "a store tied through the Option's own 'a keeps the reference",
        "fn put<'a, K>(v: &mut Vector<Option<&'a K>>, x: Option<&'a K>) { v.push(x); }\nfn main() i32 { let mut v = Vector::<Option<&i32>>::new(); { let k = 1; put(&mut v, Option::<&i32>::Some(&k)); } return v.len() as i32 - 1; }\n",
        dead,
    );
}

// `&x` of a local that holds borrows (a reference, a struct with a lifetime) is a loan on x's own
// storage: it may neither outlive x nor leave the function.
@test
fn borrows_of_borrow_carrying_locals() {
    h::expect_err_msg(
        "a reference to a reference local outlives it",
        "fn main() i32 { let x = 5; let res: &&i32; { let h = &x; res = &h; } return **res - 5; }\n",
        "borrowed value does not live long enough: it is destroyed at the end of this block while a reference to it is still stored",
    );
    h::expect_err_msg(
        "an Option of a reference to a lifetime-generic struct local outlives it",
        "struct Holder<'b> { pub r: &'b i32 }\nfn main() i32 { let x = 5; let mut res = Option::<&Holder>::None; { let h = Holder { r: &x }; res = Option::<&Holder>::Some(&h); } return switch res { Some(r) => *r.r - 5, None => 1, }; }\n",
        "borrowed value does not live long enough: it is destroyed at the end of this block while a reference to it is still stored",
    );
    h::expect_err_msg(
        "a reference to a reference local is returned",
        "fn h<'a>(x: &'a i32) &'a &'a i32 { let a = x; return &a; }\nfn main() i32 { return 0; }\n",
        "returning a pointer/reference to a local variable, which does not outlive the call",
    );
}

// An element of a `[]T` or `[]mut T` view is the storage the view borrows, as `(*r)[i]` is: a borrow
// of it holds the view's loans, a store through it lands in that storage, and an array's or a
// vector's view holds a loan on the array or vector, whatever its elements hold.
@test
fn slice_views_of_local_storage() {
    let dead = "borrowed value does not live long enough: it is destroyed at the end of this block while a reference to it is still stored";
    let esc = "returning a value borrowing from a local, which does not outlive the call";
    h::expect_err_msg(
        "a view of a local array of references is returned",
        "const G: i32 = 7;\nfn h<'a>(x: &'a i32) []'a &'static i32 { let _ = x; let a = [&G, &G]; return a; }\nfn main() i32 { return 0; }\n",
        esc,
    );
    h::expect_err_msg(
        "a sub-view of a local array of references is returned",
        "const G: i32 = 7;\nfn h<'a>(x: &'a i32) []'a &'static i32 { let _ = x; let a = [&G, &G]; return a[0..2]; }\nfn main() i32 { return 0; }\n",
        esc,
    );
    h::expect_err_msg(
        "a borrow of a view's element outlives the array",
        "fn main() i32 { let s: []i32; let r: &i32; { let a = [1, 2]; s = a; r = &s[0]; } return *r - 1; }\n",
        dead,
    );
    h::expect_err_msg(
        "the array is written while a borrow of a view's element is live",
        "fn main() i32 { let mut a = [1, 2]; let s: []i32 = a; let r = &s[0]; a[0] = 9; return *r - 1; }\n",
        "cannot assign to this value while it is borrowed",
    );
    h::expect_err_msg(
        "a vector grows while a sub-view of its references is live",
        "fn main() i32 { let x = 1; let mut v = Vector::<&i32>::new(); v.push(&x); let t = v[0..1]; v.push(&x); return *t[0] - 1; }\n",
        "cannot borrow this value as mutable while it is already borrowed as immutable",
    );
    h::expect_err_msg(
        "a store through a []mut view lands in the array",
        "fn main() i32 { let g = 1; let mut a = [&g, &g]; { let s: []mut &i32 = a; let x = 5; s[0] = &x; } return *a[0] - 5; }\n",
        dead,
    );
    h::expect_ok(
        "a borrow of a view's element outlives the view",
        "fn main() i32 { let a = [1, 2]; let r: &i32; { let s: []i32 = a; r = &s[0]; } return *r - 1; }\n",
    );
    h::expect_ok(
        "elements and sub-views of a view parameter keep its lifetime",
        "fn first<'a>(s: []'a i32) &'a i32 { let t = s; return &t[0]; }\nfn tail<'a>(s: []'a &'static i32) &'static i32 { let t = s[1..]; return t[0]; }\nfn sub<'a>(s: []'a i32) []'a i32 { let t = s; return t[1..]; }\nfn pick(c: u32) str<'static> { let cmp: []str = [\"a\", \"b\"]; return cmp[c as usize]; }\nfn main() i32 { let a = [1, 2]; return *first(a) + sub(a)[0] + pick(1).len() as i32 - 4; }\n",
    );
    h::expect_ok(
        "a []mut view writes its array, and a vector grows once its sub-view is dead",
        "fn fill(s: []mut i32) { s[0] = 5; }\nfn main() i32 { let mut a = [1, 2]; { let s: []mut i32 = a; s[1] = 4; fill(s); } let mut v = Vector::<i32>::new(); v.push(1); let t = v[0..1]; let n = t[0]; v.push(2); return a[0] + a[1] + n - 10; }\n",
    );
}

// A loan keeps three reference levels (its own, behind one reference, behind two or more): a value
// read through two references, or a call tied through a position behind two, holds only what lies
// that deep, and a store through two references lands two levels down.
@test
fn three_reference_levels() {
    let ret = "lifetime mismatch: the returned value's lifetime is not declared to outlive the return type's lifetime";
    let asg = "cannot assign to this value while it is borrowed";
    let k = "fn k<'x, K: Copy>(r: &'x Option<&K>) K { return *r.unwrap(); }\n";
    h::expect_ok(
        "a call tied through K of &'x Option<&K> holds no loan on the inner reference",
        format(
            "{}fn main() i32 {{ let a = 1; let b = 2; let mut h = &a; let o = Option::<&&i32>::Some(&h); let r = k(&o); h = &b; let _ = *h; return *r - 1; }}\n",
            k,
        ).as_str(),
    );
    h::expect_ok(
        "a call tied through K of &'x Option<&'a &'b i32> returns the 'b region",
        format(
            "{}fn fwd<'x, 'a, 'b>(r: &'x Option<&'a &'b i32>) &'b i32 {{ return k(r); }}\nfn main() i32 {{ return 0; }}\n",
            k,
        ).as_str(),
    );
    h::expect_ok(
        "a copy read through two references holds only the innermost borrow",
        "fn main() i32 { let x = 1; let y = 2; let mut a = &x; let b = &a; let c = &b; let r: &i32 = **c; a = &y; let _ = *a; return *r - 1; }\n",
    );
    h::expect_ok(
        "a by-value Option<&'a &'b i32> tied through 'b holds no loan on the middle reference",
        "fn g<'a, 'b>(x: Option<&'a &'b i32>) &'b i32 { return *x.unwrap(); }\nfn main() i32 { let a = 1; let b = 2; let mut h = &a; let r = g(Option::<&&i32>::Some(&h)); h = &b; let _ = *h; return *r - 1; }\n",
    );
    h::expect_err_msg(
        "a value read through one of two references still borrows the middle one",
        "fn main() i32 { let x = 1; let y = 2; let mut a = &x; let b = &a; let c = &b; let r2: &&i32 = *c; a = &y; let _ = *a; return **r2 - 1; }\n",
        asg,
    );
    h::expect_err_msg(
        "a call returning the Option one level down borrows the inner reference",
        "fn k2<'x, 'y, K>(r: &'x Option<&'y K>) Option<&'y K> { return *r; }\nfn main() i32 { let a = 1; let b = 2; let mut h = &a; let o = Option::<&&i32>::Some(&h); let r = k2(&o); h = &b; let _ = *h; return **r.unwrap() - 1; }\n",
        asg,
    );
    h::expect_err_msg(
        "a call tied through 'a too borrows the middle reference",
        "fn g2<'a, 'b>(x: Option<&'a &'b i32>) &'a &'b i32 { return x.unwrap(); }\nfn main() i32 { let a = 1; let b = 2; let mut h = &a; let r = g2(Option::<&&i32>::Some(&h)); h = &b; let _ = *h; return **r - 1; }\n",
        asg,
    );
    h::expect_err_msg(
        "the innermost borrow still ends with its value",
        format(
            "{}fn main() i32 {{ let mut res = &0; {{ let x = 1; let h = &x; let o = Option::<&&i32>::Some(&h); res = k(&o); }} return *res; }}\n",
            k,
        ).as_str(),
        "borrowed value does not live long enough: it is destroyed at the end of this block while a reference to it is still stored",
    );
    h::expect_err_msg(
        "a store through two references lands in the outer local",
        "fn main() i32 { let g = 1; let mut q = &g; { let mut p1 = &mut q; let p2 = &mut p1; let y = 2; **p2 = &y; } return *q; }\n",
        "borrowed value does not live long enough: it is destroyed at the end of this block while a reference to it is still stored",
    );
    h::expect_err_msg(
        "returning the middle reference of &'x Option<&'a &'b i32> needs 'a",
        "fn k<'x, 'a, 'b>(r: &'x Option<&'a &'b i32>) &'b &'b i32 { return r.unwrap(); }\nfn main() i32 { return 0; }\n",
        ret,
    );
}

// The destruction of an owned carrier observes what it stores only where it may still hold a value:
// moved out on every path, it keeps no borrow alive to the end of its scope. A closure value moved
// into another passes its destruction on.
@test
fn moved_owned_carriers_observe_nothing() {
    let asg = "cannot assign to this value while it is borrowed";
    let sink = "fn sink(v: Vector<&&i32>) { let _ = v.len(); }\n";
    h::expect_ok(
        "a vector moved into a call",
        format(
            "{}fn main() i32 {{ let x = 1; let mut h = &x; let y = 2; let mut v = Vector::<&&i32>::new(); v.push(&h); sink(v); h = &y; let _ = *h; return 0; }}\n",
            sink,
        ).as_str(),
    );
    h::expect_ok(
        "a vector moved on every path of a branch",
        format(
            "{}fn f(c: bool) i32 {{ let x = 1; let mut h = &x; let y = 2; let mut v = Vector::<&&i32>::new(); v.push(&h); if c {{ sink(v); }} else {{ let u = v; let _ = u.len(); }} h = &y; let _ = *h; return 0; }}\nfn main() i32 {{ return f(true); }}\n",
            sink,
        ).as_str(),
    );
    h::expect_err_msg(
        "a vector moved on one path only",
        format(
            "{}fn f(c: bool) i32 {{ let x = 1; let mut h = &x; let y = 2; let mut v = Vector::<&&i32>::new(); v.push(&h); if c {{ sink(v); }} h = &y; let _ = *h; return 0; }}\nfn main() i32 {{ return f(true); }}\n",
            sink,
        ).as_str(),
        asg,
    );
    h::expect_err_msg(
        "a vector moved and given a new value",
        "fn main() i32 { let x = 1; let mut h = &x; let y = 2; let mut v = Vector::<&&i32>::new(); let w = v; let _ = w.len(); v = Vector::<&&i32>::new(); v.push(&h); h = &y; let _ = *h; return 0; }\n",
        asg,
    );
    h::expect_err_msg(
        "a closure moved into another local",
        "fn main() i32 { let mut y = 1; let mut v: Vector<&i32> = Vector::new(); v.push(&y); let mut n = 0; let k = || { n += v.len() as i32; }; let mut k2 = k; k2(); y = 2; return 0; }\n",
        asg,
    );
}

// A carrier whose every member is moved out one by one holds nothing at its storage end, as one moved
// whole does; a member left in place, or a member moved out on one path only, still holds a value.
@test
fn carriers_emptied_member_by_member_observe_nothing() {
    let asg = "cannot assign to this value while it is borrowed";
    let pair = "struct P<'a> { pub a: Vector<&'a &'a i32>, pub b: Vector<&'a &'a i32> }\nstruct Q<'a> { pub p: P<'a>, pub c: Vector<&'a &'a i32> }\n";
    let head = "let x = 1; let mut h = &x; let y = 2; let mut p = P { a: Vector::<&&i32>::new(), b: Vector::<&&i32>::new() }; p.a.push(&h);";
    h::expect_ok(
        "every field freed",
        format("{}fn main() i32 {{ {} p.a.free(); p.b.free(); h = &y; let _ = *h; return 0; }}\n", pair, head).as_str(),
    );
    h::expect_ok(
        "every tuple member freed",
        "fn main() i32 { let x = 1; let mut h = &x; let y = 2; let mut t = (Vector::<&&i32>::new(), Vector::<&&i32>::new()); t.0.push(&h); t.0.free(); t.1.free(); h = &y; let _ = *h; return 0; }\n",
    );
    h::expect_ok(
        "every field of a nested carrier freed",
        format(
            "{}fn main() i32 {{ {} let mut q = Q {{ p: p, c: Vector::<&&i32>::new() }}; q.p.a.free(); q.p.b.free(); q.c.free(); h = &y; let _ = *h; return 0; }}\n",
            pair,
            head,
        ).as_str(),
    );
    h::expect_err_msg(
        "one field left in place",
        format("{}fn main() i32 {{ {} p.a.free(); h = &y; let _ = *h; return 0; }}\n", pair, head).as_str(),
        asg,
    );
    h::expect_err_msg(
        "a field freed on one path only",
        format(
            "{}fn f(c: bool) i32 {{ {} if c {{ p.a.free(); }} p.b.free(); h = &y; let _ = *h; return 0; }}\nfn main() i32 {{ return f(true); }}\n",
            pair,
            head,
        ).as_str(),
        asg,
    );
    h::expect_err_msg(
        "a freed field given a new value",
        format(
            "{}fn main() i32 {{ {} p.a.free(); p.b.free(); p.a = Vector::<&&i32>::new(); p.a.push(&h); h = &y; let _ = *h; return 0; }}\n",
            pair,
            head,
        ).as_str(),
        asg,
    );
    h::expect_err_msg(
        "a nested carrier with one inner field left",
        format(
            "{}fn main() i32 {{ {} let mut q = Q {{ p: p, c: Vector::<&&i32>::new() }}; q.p.a.free(); q.c.free(); h = &y; let _ = *h; return 0; }}\n",
            pair,
            head,
        ).as_str(),
        asg,
    );
}

// A build-constant `if` or `switch` the early prune replaced by its taken arm keeps the extension
// the arm has: the temporaries its value borrows live to the end of the block around the whole
// expression, as they do under a run-time condition.
@test
fn pruned_arm_values_keep_their_temporaries() {
    h::expect_ok(
        "a build-constant if whose arm value views an arm literal",
        "fn pick() usize { let s: []str = if ARCH == Arch::AArch64 { [\"a\"] } else { [\"b\", \"c\"] }; let mut n: usize = 0; for x in s { n += x.len(); } return n; }\nfn main() i32 { return pick() as i32 - pick() as i32; }\n",
    );
    h::expect_ok(
        "a build-constant switch whose arm value views an arm literal",
        "fn pick() usize { let s: []str = switch ARCH { AArch64 => [\"a\"], _ => [\"b\", \"c\"], }; let mut n: usize = 0; for x in s { n += x.len(); } return n; }\nfn main() i32 { return pick() as i32 - pick() as i32; }\n",
    );
    h::expect_ok(
        "a build-constant if whose arm value views owned arm temporaries",
        "fn pick() usize { let s: []String = if ARCH == Arch::AArch64 { [String::from_str(\"a\")] } else { [String::from_str(\"bb\"), String::from_str(\"c\")] }; let mut n: usize = 0; for i in 0..s.len { n += s[i].len(); } return n; }\nfn main() i32 { return pick() as i32 - pick() as i32; }\n",
    );
    h::expect_err_msg(
        "the extension ends with the block around a build-constant if",
        "fn pick() usize { let s: []str; { s = if ARCH == Arch::AArch64 { [\"a\"] } else { [\"b\", \"c\"] }; } return s.len; }\nfn main() i32 { return pick() as i32; }\n",
        "borrowed value does not live long enough: it is destroyed at the end of this block while a reference to it is still stored",
    );
}

// A closure value holds a by-reference capture's place behind its reference, as `&p` does: called
// through a function-type bound, it returns what that place holds, and the bound's lifetimes tie
// the result to the closure argument.
@test
fn closure_values_called_through_bounds() {
    let call = "fn call<'a, F: fn() &'a i32>(f: F) &'a i32 { return f(); }\n";
    h::expect_err_msg(
        "a borrow inside a captured vector outlives its value",
        format(
            "{}fn main() i32 {{ let mut r = &0; {{ let x = 41; let mut v = Vector::<&i32>::new(); v.push(&x); let f = || v[0]; r = call(f); }} return *r; }}\n",
            call,
        ).as_str(),
        "borrowed value does not live long enough: it is destroyed at the end of this block while a reference to it is still stored",
    );
    h::expect_err_msg(
        "a borrow inside a captured struct is assigned over",
        format(
            "struct H<'a> {{ pub r: &'a i32, pub s: String }}\n{}fn main() i32 {{ let mut x = 1; let h = H {{ r: &x, s: String::new() }}; let f = || h.r; let r = call(f); x = 5; return *r; }}\n",
            call,
        ).as_str(),
        "cannot assign to this value while it is borrowed",
    );
    h::expect_ok(
        "the result of a direct closure call outlives the capture",
        "struct H<'a> { pub r: &'a i32, pub s: String }\nfn main() i32 { let mut x = 1; let mut r = &0; { let h = H { r: &x, s: String::new() }; let f = || h.r; r = f(); } let _ = *r; x = 5; return 0; }\n",
    );
}

// A shared reference a closure captures copies: passing it on moves nothing out of the closure, also
// when the closure owns a value of its own (the free rule asks whether the operand owns).
@test
fn a_captured_reference_passes_on_beside_an_owned_local() {
    let pre = "struct Pk { pub v: Vector<u32> }\nstruct O { pub sc: Vector<u32> }\nextend O { fn run(self: &mut Self, p: &Pk) { self.sc.push(p.v.len() as u32); } }\nfn take(o: &mut O, p: &Pk) { o.sc.push(p.v.len() as u32); }\nfn look(p: &Pk) u32 { return p.v.len() as u32; }\nfn call<F: fn()>(f: F) { f(); }\n";
    let cases: [](str, str) = [
        ("a method's argument", "let mut o = O { sc: Vector::<u32>::new() }; o.run(p); assert(o.sc.len() == 1, \"k\");"),
        ("a function's argument", "let mut o = O { sc: Vector::<u32>::new() }; take(&mut o, p);"),
        (
            "another call's argument",
            "let o = O { sc: Vector::<u32>::new() }; let n = look(p); assert(n == 0 && o.sc.len() == 0, \"n\");"
        ),
        (
            "an argument before the owned local",
            "let n = look(p); let o = O { sc: Vector::<u32>::new() }; assert(n == 0 && o.sc.len() == 0, \"n\");"
        ),
    ];
    for i in 0..cases.len() {
        let (label, body) = cases[i];
        h::expect_ok(
            label,
            format(
                "{}fn f(p: &Pk) {{ call(|| {{ {} }}); }}\nfn main() i32 {{ let pk = Pk {{ v: Vector::<u32>::new() }}; f(&pk); return 0; }}\n",
                pre,
                body,
            ).as_str(),
        );
    }
}

// A call through a closure value tied by a function-type bound keeps what the closure's results can
// hold (`Owner::res_deep`): a closure returning what a by-reference capture holds does not keep the
// capture's own storage borrowed; one returning a reference into a capture, or a by-value capture,
// does.
@test
fn closure_results_through_bounds() {
    let call = "fn call<'a, F: fn() &'a i32>(f: F) &'a i32 { return f(); }\n";
    let dead = "borrowed value does not live long enough: it is destroyed at the end of this block while a reference to it is still stored";
    h::expect_ok(
        "a copied element of a captured vector outlives the vector",
        format(
            "{}fn main() i32 {{ let x = 1; let mut r = &0; {{ let mut v = Vector::<&i32>::new(); v.push(&x); let f = || v[0]; r = call(f); }} return *r - 1; }}\n",
            call,
        ).as_str(),
    );
    h::expect_err_msg(
        "a copied element of a captured vector does not outlive its value",
        format(
            "{}fn main() i32 {{ let mut r = &0; {{ let x = 41; let mut v = Vector::<&i32>::new(); v.push(&x); let f = || v[0]; r = call(f); }} return *r; }}\n",
            call,
        ).as_str(),
        dead,
    );
    h::expect_err_msg(
        "a copied element of a captured vector keeps its value borrowed",
        format(
            "{}fn main() i32 {{ let mut x = 1; let mut r = &0; {{ let mut v = Vector::<&i32>::new(); v.push(&x); let f = || v[0]; r = call(f); }} x = 5; return *r; }}\n",
            call,
        ).as_str(),
        "cannot assign to this value while it is borrowed",
    );
    h::expect_err_msg(
        "a field of a captured struct keeps its value borrowed",
        format(
            "struct H<'a> {{ pub r: &'a i32, pub s: String }}\n{}fn main() i32 {{ let mut x = 1; let mut r = &0; {{ let h = H {{ r: &x, s: String::new() }}; let f = || h.r; r = call(f); }} x = 5; return *r; }}\n",
            call,
        ).as_str(),
        "cannot assign to this value while it is borrowed",
    );
    h::expect_err_msg(
        "a reference into a captured vector keeps the vector borrowed",
        format(
            "{}fn main() i32 {{ let x = 1; let mut r = &0; {{ let mut v = Vector::<i32>::new(); v.push(x); let f = || &v[0]; r = call(f); }} return *r; }}\n",
            call,
        ).as_str(),
        dead,
    );
    h::expect_err_msg(
        "a reference captured by value keeps its value borrowed",
        format(
            "{}fn main() i32 {{ let mut r = &0; {{ let x = 1; let h = &x; let f = move || h; r = call(f); }} return *r; }}\n",
            call,
        ).as_str(),
        dead,
    );
    h::expect_err_msg(
        "a generic returning the closure value keeps its captures borrowed",
        "fn keep<'a, F: fn() &'a i32>(f: F) F { return f; }\nfn main() i32 { let x = 1; let mut v = Vector::<&i32>::new(); v.push(&x); let g = keep(|| v[0]); v.push(&x); return *g() - 1; }\n",
        "cannot borrow this value as mutable while it is already borrowed as immutable",
    );
}

// A value read through a reference or a view's element carries the lifetimes behind it into a
// `'static` parameter; a `'static` element of a view of a local array leaves the array behind.
@test
fn static_reads_through_references_and_views() {
    let need = "fn need(x: &'static i32) {\n    let _ = x;\n}\n";
    let msg = "lifetime mismatch: this argument's lifetime is not declared to outlive 'static";
    h::expect_err_msg(
        "a reference read through a reference",
        format("{}fn f<'a>(r: &&'a i32) {{\n    need(*r);\n}}\nfn main() i32 {{\n    return 0;\n}}\n", need).as_str(),
        msg,
    );
    h::expect_err_msg(
        "a reference read through two references",
        format("{}fn f<'a>(r: &&&'a i32) {{\n    need(**r);\n}}\nfn main() i32 {{\n    return 0;\n}}\n", need).as_str(),
        msg,
    );
    h::expect_err_msg(
        "a reference element of a view",
        format("{}fn f<'a>(s: []&'a i32) {{\n    need(s[0]);\n}}\nfn main() i32 {{\n    return 0;\n}}\n", need).as_str(),
        msg,
    );
    h::expect_ok(
        "a 'static element of a view of a local array",
        "fn pick(c: u8) str<'static> {\n    let cmp: []str = [\"a\", \"b\"];\n    return cmp[c as usize];\n}\nfn main() i32 {\n    return pick(1).len() as i32 - 1;\n}\n",
    );
}

// A closure argument passes its captures out of a call through its results, and through a
// parameter of its own that can take a store (a `&mut`, a raw pointer, a shared reference to a
// cell); a counting closure over references stores nothing.
@test
fn closure_arguments_store_through_results_and_writable_parameters() {
    let msg = "borrowed value does not live long enough: it is stored into caller-visible data whose lifetime it is not declared to outlive";
    h::expect_ok(
        "a counting predicate over a parameter's vector of references",
        "pub fn f(v: &mut Vector<&i64>) u64 {\n    let mut c: u64 = 0;\n    v.retain(fn(x: &&i64) bool {\n        c += 1;\n        return **x > 0;\n    });\n    return c;\n}\nfn main() i32 {\n    return 0;\n}\n",
    );
    h::expect_ok(
        "a counting comparator over a view of references",
        "pub fn f(s: []mut &i64) u64 {\n    let mut c: u64 = 0;\n    s.sort_by(fn(x: &&i64, y: &&i64) i32 {\n        c += 1;\n        return (**x).cmp(*y);\n    });\n    return c;\n}\nfn main() i32 {\n    return 0;\n}\n",
    );
    h::expect_err_msg(
        "a closure writes a capture through its &mut parameter",
        "fn apply<T, F: fn(&mut T)>(x: &mut T, f: F) {\n    f(x);\n}\npub fn f(v: &mut &i64) {\n    let local: i64 = 1;\n    apply(v, fn(p: &mut &i64) {\n        *p = &local;\n    });\n}\nfn main() i32 {\n    return 0;\n}\n",
        msg,
    );
    h::expect_err_msg(
        "a closure writes a capture through a shared parameter's cell",
        "pub struct C<T> {\n    v: UnsafeCell<T>,\n}\nextend<T> C<T> {\n    pub fn set(self: &C<T>, x: T) {\n        unsafe *self.v.get() = x;\n    }\n}\nfn apply<T, F: fn(&T)>(x: &T, f: F) {\n    f(x);\n}\npub fn f(c: &C<&i64>) {\n    let local: i64 = 1;\n    apply(c, fn(p: &C<&i64>) {\n        p.set(&local);\n    });\n}\nfn main() i32 {\n    return 0;\n}\n",
        msg,
    );
    h::expect_err_msg(
        "the callee stores a closure's result",
        "fn fill<T, F: fn() T>(s: []mut T, f: F) {\n    s[0] = f();\n}\npub fn f(s: []mut &i64) {\n    let local: i64 = 1;\n    let r = &local;\n    fill(s, fn() &i64 {\n        return r;\n    });\n}\nfn main() i32 {\n    return 0;\n}\n",
        msg,
    );
}
